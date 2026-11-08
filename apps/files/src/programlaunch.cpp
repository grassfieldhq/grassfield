#include "programlaunch.h"

#include "appscope.h"
#include "launchguard.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QRegularExpression>
#include <QSocketNotifier>
#include <QStandardPaths>
#include <QTimer>

#include <cerrno>
#include <csignal>
#include <fcntl.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <unistd.h>

extern char **environ;

namespace ProgramLaunch
{
namespace
{
constexpr int kFuseQueryMs = 5000;
constexpr int kReapPollMs = 2000;

bool contains(const QByteArray &errors, const char *text)
{
    return errors.contains(text);
}
} // namespace

QString missingLibrary(const QByteArray &errors)
{
    static const QRegularExpression loader(QStringLiteral(R"(error while loading shared libraries: ([^:\s/]{1,200}): cannot open shared object file)"));
    const QRegularExpressionMatch m = loader.match(QString::fromUtf8(errors));
    if (!m.hasMatch())
        return {};
    static const QRegularExpression plain(QStringLiteral(R"(\A[A-Za-z0-9._+-]{1,200}\z)"));
    const QString name = m.captured(1);
    return plain.match(name).hasMatch() ? name : QString();
}

Outcome classify(const Start &s)
{
    Outcome o;
    if (!s.spawned) {
        switch (s.spawnErrno) {
        case ENOEXEC:
            o.failure = Failure::ExecFormat;
            break;
        case ENOENT:
            // The program exists (it was just inspected): what is missing is its loader.
            if (!s.interpreter.isEmpty() && !QFileInfo::exists(s.interpreter)) {
                o.failure = Failure::MissingLibrary;
                o.library = QFileInfo(s.interpreter).fileName();
            } else {
                o.failure = Failure::StartFailed;
            }
            break;
        case EACCES:
        case EPERM:
            o.failure = Failure::CannotRunHere;
            break;
        default:
            o.failure = Failure::StartFailed;
            break;
        }
        return o;
    }
    // The AppImage runtimes' own words: the old runtime loads libfuse.so.2 ("dlopen(): error loading libfuse.so.2 ... AppImages
    // require FUSE to run"), the static one runs fusermount3 ("Cannot mount AppImage, please check your FUSE setup").
    if (contains(s.errors, "libfuse.so.2")) {
        o.failure = Failure::Fuse;
        return o;
    }
    if (s.appImage && (contains(s.errors, "AppImages require FUSE") || contains(s.errors, "check your FUSE setup") || contains(s.errors, "fusermount"))) {
        o.failure = Failure::Fuse;
        return o;
    }
    const QString library = missingLibrary(s.errors);
    if (!library.isEmpty()) {
        o.failure = Failure::MissingLibrary;
        o.library = library;
        return o;
    }
    // Through uwsm-app (a real session) the start is systemd-run's: "Failed to execute /path: Exec format error".
    if (contains(s.errors, "Failed to execute") || contains(s.errors, "failed to execute")) {
        if (contains(s.errors, "Exec format error")) {
            o.failure = Failure::ExecFormat;
            return o;
        }
        if (contains(s.errors, "Permission denied")) {
            o.failure = Failure::CannotRunHere;
            return o;
        }
        if (contains(s.errors, "No such file or directory") && !s.interpreter.isEmpty() && !QFileInfo::exists(s.interpreter)) {
            o.failure = Failure::MissingLibrary;
            o.library = QFileInfo(s.interpreter).fileName();
            return o;
        }
        o.failure = Failure::StartFailed;
        return o;
    }
    if (s.exited && s.signal == 0 && s.exitCode != 0) {
        o.failure = Failure::QuitAtOnce;
        o.exitCode = s.exitCode;
    }
    return o;
}

QString approve(const QString &path, quint64 inode, qint64 mtimeNs, qint64 size, bool allowRun)
{
    const QByteArray native = QFile::encodeName(path);
    const int fd = ::open(native.constData(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NOCTTY | O_NONBLOCK);
    if (fd < 0)
        return QString::fromLocal8Bit(strerror(errno));
    struct stat st{};
    auto same = [&] {
        return ::fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && quint64(st.st_ino) == inode
            && qint64(st.st_mtim.tv_sec) * 1000000000 + st.st_mtim.tv_nsec == mtimeNs && qint64(st.st_size) == size;
    };
    if (!same()) {
        ::close(fd);
        return QStringLiteral("changed");
    }
    if (allowRun) {
        if (st.st_uid != ::geteuid()) {
            ::close(fd);
            return QString::fromLocal8Bit(strerror(EPERM));
        }
        // The user's execute bit only: the permissions it has, without setuid and setgid, plus u+x.
        if (::fchmod(fd, (st.st_mode & 0777) | S_IXUSR) != 0) {
            const int error = errno;
            ::close(fd);
            return QString::fromLocal8Bit(strerror(error));
        }
        if (!same()) {
            ::close(fd);
            return QStringLiteral("changed");
        }
    }
    const QByteArray value = LaunchGuard::approvalValue(quint64(st.st_ino), qint64(st.st_mtim.tv_sec) * 1000000000 + st.st_mtim.tv_nsec, qint64(st.st_size));
    // No user extended attributes here (FAT, some network file systems): no approval kept, the next open asks again.
    ::fsetxattr(fd, "user.grassfield.approved", value.constData(), size_t(value.size()), 0);
    ::close(fd);
    return {};
}

QString applicationsFolder()
{
    const QString folder = QDir::homePath() + QStringLiteral("/Applications");
    const QFileInfo info(folder);
    if (info.isDir() && !info.isSymLink())
        return folder;
    if (info.exists() || info.isSymLink())
        return info.isDir() ? folder : QString();
    return QDir().mkpath(folder) ? folder : QString();
}

QString freeName(const QString &folder, const QString &name)
{
    const QDir dir(folder);
    if (!QFileInfo::exists(dir.filePath(name)) && !QFileInfo(dir.filePath(name)).isSymLink())
        return name;
    const qsizetype dot = name.lastIndexOf(QLatin1Char('.'));
    const QString base = dot > 0 ? name.left(dot) : name;
    const QString suffix = dot > 0 ? name.mid(dot) : QString();
    for (int n = 2; n < 10000; ++n) {
        const QString candidate = base + QLatin1Char(' ') + QString::number(n) + suffix;
        if (!QFileInfo::exists(dir.filePath(candidate)) && !QFileInfo(dir.filePath(candidate)).isSymLink())
            return candidate;
    }
    return {};
}

Run::Run(QObject *parent)
    : QObject(parent)
{
}

Run::~Run()
{
    closeErrors();
    if (m_pidfd >= 0)
        ::close(m_pidfd);
    // A program still running when Files goes: it is re-parented and reaped by the service manager (a subreaper).
}

QStringList Run::command(const QString &program, const QStringList &args)
{
    return grassfield::apps::scopedCommand(program, args, grassfield::apps::scopedLaunch());
}

void Run::start(const QString &program, const QStringList &args, const QString &workingDirectory, bool appImage, const QString &interpreter)
{
    m_start = Start{};
    m_start.appImage = appImage;
    m_start.interpreter = interpreter;
    const QStringList argv = command(program, args);

    int pair[2] = {-1, -1};
    if (::socketpair(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0, pair) == 0) {
        const int size = 256 * 1024;
        ::setsockopt(pair[0], SOL_SOCKET, SO_RCVBUF, &size, sizeof size);
        ::fcntl(pair[0], F_SETFL, ::fcntl(pair[0], F_GETFL) | O_NONBLOCK);
        m_errors = pair[0];
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    if (pair[1] >= 0)
        posix_spawn_file_actions_adddup2(&actions, pair[1], 2);
    else
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    const QByteArray directory = QFile::encodeName(workingDirectory);
    if (!directory.isEmpty())
        posix_spawn_file_actions_addchdir_np(&actions, directory.constData());
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    // Its own session (not Files' process group), no signal blocked, every signal at its default action.
    sigset_t none;
    sigemptyset(&none);
    sigset_t all;
    sigfillset(&all);
    posix_spawnattr_setsigmask(&attributes, &none);
    posix_spawnattr_setsigdefault(&attributes, &all);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);

    QList<QByteArray> bytes;
    for (const QString &a : argv)
        bytes << QFile::encodeName(a);
    QList<char *> pointers;
    for (QByteArray &b : bytes)
        pointers << b.data();
    pointers << nullptr;
    pid_t pid = -1;
    // posix_spawnp: the program is an absolute path, or uwsm-app / java found on the PATH. No shell, no ENOEXEC fallback.
    const int rc = ::posix_spawnp(&pid, pointers.first(), &actions, &attributes, pointers.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    if (pair[1] >= 0)
        ::close(pair[1]);
    if (rc != 0) {
        m_start.spawned = false;
        m_start.spawnErrno = rc;
        closeErrors();
        m_ended = true;
        QTimer::singleShot(0, this, [this] {
            report(classify(m_start));
        });
        return;
    }
    m_pid = pid;
    if (m_errors >= 0) {
        m_errorNotifier = new QSocketNotifier(m_errors, QSocketNotifier::Read, this);
        connect(m_errorNotifier, &QSocketNotifier::activated, this, &Run::readErrors);
    }
    // The end of the program: its pidfd turns readable (a child of Files, so the pid can't be reused before it is reaped);
    // without pidfd_open (a kernel older than 5.3) a poll.
    m_pidfd = int(::syscall(SYS_pidfd_open, pid, 0));
    if (m_pidfd >= 0) {
        m_endNotifier = new QSocketNotifier(m_pidfd, QSocketNotifier::Read, this);
        connect(m_endNotifier, &QSocketNotifier::activated, this, &Run::childEnded);
    } else {
        m_poll = new QTimer(this);
        m_poll->setInterval(100);
        connect(m_poll, &QTimer::timeout, this, &Run::childEnded);
        m_poll->start();
    }
    QTimer::singleShot(kWindowMs, this, &Run::windowEnded);
}

void Run::readErrors()
{
    if (m_errors < 0)
        return;
    char buffer[8192];
    for (;;) {
        const ssize_t n = ::recv(m_errors, buffer, sizeof buffer, MSG_DONTWAIT);
        if (n <= 0)
            break;
        const qint64 room = kMaxErrorBytes - m_start.errors.size();
        if (room > 0)
            m_start.errors.append(buffer, int(qMin<qint64>(room, n)));
    }
}

void Run::childEnded()
{
    if (m_ended || m_pid < 0)
        return;
    int status = 0;
    const pid_t r = ::waitpid(m_pid, &status, WNOHANG);
    if (r == 0)
        return; // still running (a poll, or a spurious wake-up)
    m_ended = true;
    delete m_endNotifier;
    m_endNotifier = nullptr;
    delete m_poll;
    m_poll = nullptr;
    if (m_reported) {
        deleteLater();
        return;
    }
    if (r == m_pid) {
        m_start.exited = true;
        if (WIFEXITED(status))
            m_start.exitCode = WEXITSTATUS(status);
        else if (WIFSIGNALED(status))
            m_start.signal = WTERMSIG(status);
    }
    readErrors(); // what it wrote before it ended is still queued
    closeErrors();
    const Outcome outcome = classify(m_start);
    if (outcome.failure == Failure::Fuse)
        checkFuse(outcome);
    else
        report(outcome);
}

void Run::windowEnded()
{
    if (m_reported || m_ended)
        return;
    // It runs: whatever it says from now on is its own business. Stop reading (later writes fail, they never block it) and
    // only wait to reap it.
    closeErrors();
    report(Outcome{});
    if (!m_endNotifier && !m_poll) {
        deleteLater();
        return;
    }
    if (m_poll)
        m_poll->setInterval(kReapPollMs);
}

void Run::checkFuse(Outcome outcome)
{
    // The old AppImage runtime needs FUSE 2 (Arch's fuse2 package). pacman's read-only query says whether it is installed; no
    // pacman (another distribution), no answer: the alert says only that FUSE could not be used.
    if (QStandardPaths::findExecutable(QStringLiteral("pacman")).isEmpty()) {
        report(outcome);
        return;
    }
    auto *query = new QProcess(this);
    query->setProgram(QStringLiteral("pacman"));
    query->setArguments({QStringLiteral("-Qq"), QStringLiteral("fuse2")});
    query->setStandardInputFile(QProcess::nullDevice());
    query->setStandardOutputFile(QProcess::nullDevice());
    query->setStandardErrorFile(QProcess::nullDevice());
    connect(query, &QProcess::finished, this, [this, query, outcome](int code, QProcess::ExitStatus status) mutable {
        outcome.componentMissing = status == QProcess::NormalExit && code == 1;
        query->deleteLater();
        report(outcome);
    });
    connect(query, &QProcess::errorOccurred, this, [this, query, outcome](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            query->deleteLater();
            report(outcome);
        }
    });
    QTimer::singleShot(kFuseQueryMs, query, [query] {
        if (query->state() != QProcess::NotRunning)
            query->kill();
    });
    query->start();
}

void Run::report(const Outcome &outcome)
{
    if (m_reported)
        return;
    m_reported = true;
    emit finished(outcome);
    if (m_ended)
        deleteLater();
}

void Run::closeErrors()
{
    delete m_errorNotifier;
    m_errorNotifier = nullptr;
    if (m_errors >= 0) {
        ::close(m_errors);
        m_errors = -1;
    }
}

} // namespace ProgramLaunch
