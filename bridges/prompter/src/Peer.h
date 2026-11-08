#pragma once

// The shell's socket: where it lives and who may connect (ADR-0035 D-9). Linux only. The parsing and the decisions are pure
// and unit-tested in tests/unit/prompter/; checkSocketPeer reads the kernel.
//
// A peer is accepted when SO_PEERCRED says it runs as this user, its cgroup is the expected unit's
// (grassfield-shell.service by default, from --peer-unit in the systemd unit) and, in a session, systemd names it that unit's
// main process (the user may write the unit's cgroup.procs, so the cgroup alone does not tell the shell from a process that
// moved itself there: rc7 security review of R7-SEC-02; a development run checks the cgroup's last component only). The cgroup is read race-free: the kernel
// hands out a pidfd of the peer (SO_PEERPIDFD, Linux 6.5), the PID comes from that pidfd's fdinfo, /proc/<pid>/cgroup is
// read, then the pidfd is checked again: when the process still runs, the PID was not reused between. Only a kernel that
// does not know SO_PEERPIDFD at all (ENOPROTOOPT, before 6.5) makes the bridge read the PID of SO_PEERCRED instead, and a
// peer that exits and whose PID is reused by a process of the expected unit in between would pass there (the residual
// race, documented in the spec). Any other failure refuses the peer: Linux 6.5 to 6.15 answer EINVAL when the peer has
// exited and been reaped, which is exactly when its PID may already belong to another process (security review of
// step 9a, MINOR-3).

#include <QByteArray>
#include <QString>

#include <functional>

#include <sys/types.h>

namespace gf::prompter {

    // The path of the unified (cgroup v2) hierarchy in the text of /proc/<pid>/cgroup: the "0::<path>" line; empty when
    // there is none.
    QString unifiedCgroupPath(const QByteArray& procCgroup);

    // `path` is the cgroup of the unit `unit`: its last component is exactly `unit` and, when `requireUserManager`, an
    // earlier component is exactly "user@<uid>.service" (the unit runs under this user's own systemd manager) and every
    // component between the two is a slice ("<name>.slice"), so a cgroup nested in another unit or scope that merely ends
    // with the unit's name never matches (security review of step 9a, NIT-1). A removed cgroup (" (deleted)") or a
    // relative path never matches.
    bool cgroupIsUnit(const QString& path, const QString& unit, uid_t uid, bool requireUserManager);

    // A --peer-unit value: in a session a systemd service name ("<name>.service", "<name>@<instance>.service"; letters,
    // digits and ":_.\-" only); in a development run any single path component (a container has no user manager, and the
    // tests name their own cgroup).
    bool validPeerUnit(const QString& unit, bool dev);

    // The PID of the "Pid:" line of a pidfd's /proc/self/fdinfo text: > 0, -1 when the process has exited, 0 when the
    // line is missing, not a number, or the process is in another PID namespace.
    qint64 pidFromFdinfo(const QByteArray& fdinfo);

    // The process behind the pidfd still runs (a pidfd turns readable when its process exits).
    bool pidfdAlive(int pidfd);

    // The PID behind `pidfd` (pidFromFdinfo of /proc/self/fdinfo/<pidfd>).
    qint64 pidOfPidfd(int pidfd);

    struct PeerCheck {
        bool    accepted = false;
        QString reason;   // why it was refused, for the journal
        qint64  pid      = 0;
        QString cgroup;
        bool    raceFree = false; // the cgroup was read through SO_PEERPIDFD
        qint64  mainPid  = 0;     // what systemd named as the unit's main process (session runs)
    };

    // The main process of a unit as the user's systemd manager says it now: > 0, 0 when it names none (a stopped unit, a
    // scope), -1 when it could not be asked. The bridge asks over the session bus (org.freedesktop.systemd1, GetUnit, then
    // the Service's MainPID); the tests pass their own.
    using MainPidQuery = std::function<qint64(const QString& unit)>;

    // What getsockopt(SO_PEERPIDFD) answered: rc 0 with a pidfd, or -1 with errno in `error`.
    struct PidfdAnswer {
        int rc    = -1;
        int error = 0;
        int pidfd = -1;
    };
    using PidfdQuery = PidfdAnswer (*)(int fd);

    // The decision for the connected socket `fd`. `query` stands for getsockopt(SO_PEERPIDFD) in the tests. When
    // `requireUserManager` (a session run), the peer must also be the unit's main process by `mainPid` (none given: refused);
    // the pidfd is checked alive after that answer, so the PID compared is still the peer's.
    PeerCheck checkSocketPeer(int fd, uid_t uid, const QString& unit, bool requireUserManager, PidfdQuery query = nullptr,
                              const MainPidQuery& mainPid = {});

    // One journal line per `windowMs` for a kind of repeated event (refused connections), with the count of those not
    // written since (security review of step 9a, NIT-2).
    class LogThrottle {
      public:
        explicit LogThrottle(qint64 windowMs) : m_windowMs(windowMs) {}
        // True when the event may be written now; *suppressed then holds how many were not written before it.
        bool allow(qint64 nowMs, qint64* suppressed);
        // The events not written so far, now counted as reported (the bridge writes them when its window ends, so a burst
        // followed by silence is reported too: counter-review of step 9a, NIT).
        qint64 takeSuppressed();
        qint64 windowMs() const {
            return m_windowMs;
        }

      private:
        qint64 m_windowMs;
        qint64 m_last       = 0;
        bool   m_any        = false;
        qint64 m_suppressed = 0;
    };

    // --- the socket's place ------------------------------------------------------------------------------------------

    // <runtimeDir>/grassfield/prompter.sock, or `overridePath` when set; empty when neither is an absolute path.
    QString socketPath(const QString& overridePath, const QString& runtimeDir);

    // An AF_UNIX path fits sockaddr_un.sun_path with its terminating NUL.
    bool fitsSocketPath(const QString& path);

    // The socket's directory: created with mode 0700 when missing (its parent must exist, be a real directory of this
    // user and not be writable by group or others); an existing one must be a real directory (lstat: never a symlink)
    // owned by this user, and its group and other bits are removed. Returns an error text, empty on success.
    QString prepareSocketDirectory(const QString& socketPath);

} // namespace gf::prompter
