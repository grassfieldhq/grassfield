#include "Peer.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QStringList>

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#ifndef SO_PEERPIDFD
#define SO_PEERPIDFD 77 // Linux 6.5, asm-generic/socket.h
#endif

namespace gf::prompter {

    namespace {
        // A small /proc file, read whole (at most `limit` bytes).
        QByteArray readSmall(const QByteArray& path, qint64 limit = 16384) {
            QFile file(QString::fromLocal8Bit(path));
            if (!file.open(QIODevice::ReadOnly))
                return {};
            return file.read(limit);
        }
    } // namespace

    QString unifiedCgroupPath(const QByteArray& procCgroup) {
        for (const QByteArray& line : procCgroup.split('\n')) {
            if (line.startsWith("0::"))
                return QString::fromUtf8(line.mid(3));
        }
        return {};
    }

    bool cgroupIsUnit(const QString& path, const QString& unit, uid_t uid, bool requireUserManager) {
        if (unit.isEmpty() || !path.startsWith(u'/') || path.endsWith(QLatin1String(" (deleted)")))
            return false;
        const QStringList parts = path.split(u'/', Qt::SkipEmptyParts);
        if (parts.isEmpty() || parts.constLast() != unit)
            return false;
        if (!requireUserManager)
            return true;
        const qsizetype manager = parts.indexOf(QStringLiteral("user@%1.service").arg(uid));
        if (manager < 0 || manager + 1 >= parts.size())
            return false;
        for (qsizetype i = manager + 1; i + 1 < parts.size(); ++i) {
            if (!parts.at(i).endsWith(QLatin1String(".slice")) || parts.at(i) == QLatin1String(".slice"))
                return false;
        }
        return true;
    }

    bool validPeerUnit(const QString& unit, bool dev) {
        if (unit.isEmpty() || unit.size() > 255 || unit.contains(u'/') || unit == QLatin1String(".") || unit == QLatin1String(".."))
            return false;
        if (dev)
            return true;
        static const QRegularExpression service(QStringLiteral("^[A-Za-z0-9:_.\\\\-]+(@[A-Za-z0-9:_.\\\\-]*)?\\.service$"));
        return service.match(unit).hasMatch();
    }

    qint64 pidFromFdinfo(const QByteArray& fdinfo) {
        for (const QByteArray& line : fdinfo.split('\n')) {
            if (!line.startsWith("Pid:"))
                continue;
            bool         ok    = false;
            const qint64 value = line.mid(4).trimmed().toLongLong(&ok);
            if (!ok)
                return 0;
            return value > 0 ? value : (value == -1 ? -1 : 0);
        }
        return 0;
    }

    bool pidfdAlive(int pidfd) {
        if (pidfd < 0)
            return false;
        pollfd entry{pidfd, POLLIN, 0};
        return ::poll(&entry, 1, 0) == 0;
    }

    qint64 pidOfPidfd(int pidfd) {
        return pidfd < 0 ? 0 : pidFromFdinfo(readSmall(QByteArrayLiteral("/proc/self/fdinfo/") + QByteArray::number(pidfd)));
    }

    namespace {
        PidfdAnswer kernelPidfd(int fd) {
            PidfdAnswer answer;
            socklen_t   length = sizeof(answer.pidfd);
            answer.rc          = ::getsockopt(fd, SOL_SOCKET, SO_PEERPIDFD, &answer.pidfd, &length);
            answer.error       = answer.rc == 0 ? 0 : errno;
            if (answer.rc == 0 && answer.pidfd < 0) {
                answer.rc    = -1;
                answer.error = EINVAL;
            }
            return answer;
        }
    } // namespace

    PeerCheck checkSocketPeer(int fd, uid_t uid, const QString& unit, bool requireUserManager, PidfdQuery query,
                              const MainPidQuery& mainPid) {
        PeerCheck check;
        ucred     cred{};
        socklen_t length = sizeof(cred);
        if (::getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &length) != 0 || length != sizeof(cred)) {
            check.reason = QStringLiteral("no peer credentials");
            return check;
        }
        if (cred.uid != uid) {
            check.reason = QStringLiteral("peer runs as uid %1").arg(cred.uid);
            return check;
        }
        const PidfdAnswer answer = (query ? query : kernelPidfd)(fd);
        // The pidfd stays open until the last read below: its process still running then means the PID read at first
        // was not reused by another process meanwhile.
        int        pidfd = -1;
        QByteArray cgroupText;
        if (answer.rc == 0) {
            pidfd          = answer.pidfd;
            check.raceFree = true;
            check.pid      = pidOfPidfd(pidfd);
            if (check.pid > 0)
                cgroupText = readSmall(QByteArrayLiteral("/proc/") + QByteArray::number(check.pid) + QByteArrayLiteral("/cgroup"));
            if (check.pid <= 0 || !pidfdAlive(pidfd)) {
                ::close(pidfd);
                check.reason = QStringLiteral("peer process gone or in another PID namespace");
                return check;
            }
        } else if (answer.error == ENOPROTOOPT) {
            // A kernel without SO_PEERPIDFD (before Linux 6.5): the PID of SO_PEERCRED (the residual race of the header).
            check.pid = cred.pid;
            if (check.pid > 0)
                cgroupText = readSmall(QByteArrayLiteral("/proc/") + QByteArray::number(check.pid) + QByteArrayLiteral("/cgroup"));
        } else {
            // EINVAL on Linux 6.5 to 6.15: the peer has exited and been reaped. Never fall back to its PID then.
            check.reason = QStringLiteral("no pidfd for the peer: %1").arg(QString::fromLocal8Bit(std::strerror(answer.error)));
            return check;
        }
        const auto refuse = [&](const QString& reason) {
            if (pidfd >= 0)
                ::close(pidfd);
            check.reason = reason;
            return check;
        };
        check.cgroup = unifiedCgroupPath(cgroupText);
        if (!cgroupIsUnit(check.cgroup, unit, uid, requireUserManager))
            return refuse(QStringLiteral("peer is not in %1").arg(unit));
        // In a session the peer must also be the unit's main process: the user may write the unit's cgroup.procs, so a process
        // of theirs can move itself into the cgroup, but systemd's MainPID is the process the unit started (rc7 security
        // review of R7-SEC-02). Asked at check time; no query, no answer or another PID refuses.
        if (requireUserManager) {
            if (!mainPid)
                return refuse(QStringLiteral("no way to ask systemd for %1's main process").arg(unit));
            check.mainPid = mainPid(unit);
            if (check.mainPid <= 0)
                return refuse(QStringLiteral("systemd names no main process of %1").arg(unit));
            if (check.mainPid != check.pid)
                return refuse(QStringLiteral("peer is not %1's main process (pid %2)").arg(unit).arg(check.mainPid));
        }
        if (pidfd >= 0) {
            const bool alive = pidfdAlive(pidfd);
            ::close(pidfd);
            if (!alive) {
                check.reason = QStringLiteral("peer process exited during the check");
                return check;
            }
        }
        check.accepted = true;
        return check;
    }

    bool LogThrottle::allow(qint64 nowMs, qint64* suppressed) {
        if (m_any && nowMs - m_last < m_windowMs) {
            ++m_suppressed;
            return false;
        }
        *suppressed  = m_suppressed;
        m_suppressed = 0;
        m_last       = nowMs;
        m_any        = true;
        return true;
    }

    qint64 LogThrottle::takeSuppressed() {
        const qint64 n = m_suppressed;
        m_suppressed   = 0;
        return n;
    }

    QString socketPath(const QString& overridePath, const QString& runtimeDir) {
        if (!overridePath.isEmpty())
            return QDir::isAbsolutePath(overridePath) ? QDir::cleanPath(overridePath) : QString();
        if (runtimeDir.isEmpty() || !QDir::isAbsolutePath(runtimeDir))
            return {};
        return QDir::cleanPath(runtimeDir + QStringLiteral("/grassfield/prompter.sock"));
    }

    bool fitsSocketPath(const QString& path) {
        return !path.isEmpty() && QFile::encodeName(path).size() < static_cast<qsizetype>(sizeof(sockaddr_un::sun_path));
    }

    QString prepareSocketDirectory(const QString& socketPath) {
        const QString    dir   = QFileInfo(socketPath).absolutePath();
        const QByteArray local = QFile::encodeName(dir);
        struct stat      st{};
        if (::lstat(local.constData(), &st) != 0) {
            if (errno != ENOENT)
                return QStringLiteral("cannot inspect %1: %2").arg(dir, QString::fromLocal8Bit(std::strerror(errno)));
            // Only the last component is created, in a parent that is this user's alone.
            const QByteArray parent = QFile::encodeName(QFileInfo(dir).absolutePath());
            struct stat      pst{};
            if (::lstat(parent.constData(), &pst) != 0 || !S_ISDIR(pst.st_mode) || pst.st_uid != ::getuid() || (pst.st_mode & 022) != 0)
                return QStringLiteral("%1 is not a directory of this user alone").arg(QString::fromLocal8Bit(parent));
            if (::mkdir(local.constData(), 0700) != 0 && errno != EEXIST)
                return QStringLiteral("cannot create %1: %2").arg(dir, QString::fromLocal8Bit(std::strerror(errno)));
            if (::lstat(local.constData(), &st) != 0)
                return QStringLiteral("cannot inspect %1 after creating it").arg(dir);
        }
        if (!S_ISDIR(st.st_mode))
            return QStringLiteral("%1 is not a directory (symlinks are refused)").arg(dir);
        if (st.st_uid != ::getuid())
            return QStringLiteral("%1 is not owned by this user").arg(dir);
        if ((st.st_mode & 077) != 0 && ::chmod(local.constData(), 0700) != 0)
            return QStringLiteral("cannot restrict %1 to mode 0700").arg(dir);
        return {};
    }

} // namespace gf::prompter
