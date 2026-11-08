#pragma once

#include <QByteArray>
#include <QObject>
#include <QString>
#include <QStringList>

class QSocketNotifier;
class QTimer;
class QProcess;

// Running what Files opened the Gatekeeper way (LaunchGuard::RunProgram and OpenScript, ADR-0011 amendment 2026-11-08): the
// approval Files keeps on a file the user said Open to (user.grassfield.approved, bound to the file's inode, modification time
// and size: a changed file asks again), the user's execute bit set on that consent, and the start itself, watched for one
// second so that a program that cannot start gets a plain alert (another computer's program, a missing library, an AppImage
// without FUSE). Qt Core and POSIX only; never a shell, never elevated rights. Unit-tested in tst_programlaunch.cpp, run
// through FilesApp::open by tst_fileslaunch.cpp.
namespace ProgramLaunch
{

enum class Failure {
    None,           // it runs (or it ended well within the first second)
    ExecFormat,     // the kernel can't run it (another computer's program)
    MissingLibrary, // the dynamic loader can't find a library (or the program's loader itself)
    Fuse,           // an AppImage that can't mount itself (no FUSE 2 library, no fusermount)
    CannotRunHere,  // the start was refused where it is (noexec, permission)
    StartFailed,    // anything else that kept it from starting
    QuitAtOnce,     // it ended within the first second with an error code
};

struct Outcome {
    Failure failure = Failure::None;
    QString library;              // MissingLibrary: the library's file name
    int exitCode = 0;             // QuitAtOnce: its exit code
    bool componentMissing = false; // Fuse: the fuse2 package is not installed (pacman -Qq fuse2)
};

// What the first second told (the input of classify()).
struct Start {
    bool spawned = true; // false: the start itself failed with spawnErrno
    int spawnErrno = 0;
    bool exited = false; // it ended within the first second
    int exitCode = 0;
    int signal = 0;      // killed by this signal (a crash: grassfield-crash-watch tells the user, not Files)
    QByteArray errors;   // the first kMaxErrorBytes of its error output
    bool appImage = false;
    QString interpreter; // its PT_INTERP: a start that finds no such file while the program exists lacks its loader
};

constexpr int kWindowMs = 1000;
constexpr qint64 kMaxErrorBytes = 16 * 1024;
constexpr int kMaxErrorReads = 64; // datagrams read per wake-up at most

// Files runs as root (euid 0): it then starts nothing, on any path (programs, Terminal, Java, Wine).
bool filesRunsAsRoot();

// The failure the first second shows (pure).
Outcome classify(const Start &start);

// The library a dynamic loader message names ("error while loading shared libraries: libfoo.so.1: cannot open shared object
// file"), "" when there is none or it is not a plain file name.
QString missingLibrary(const QByteArray &errors);

enum class Approval {
    Approved,    // the execute bit (when asked) and the approval are written
    Changed,     // it is no longer the file the user decided on: nothing written
    NotOwner,    // allowRun on another user's file: nothing written
    ExecIgnored, // the file system ignored the execute bit (FAT, exFAT, NTFS with fixed modes): copy it elsewhere to run it
    Failed,      // it could not be opened or changed
};

// After the user said Open: through one descriptor of `path` (no symbolic link followed), and only while it is still the file
// the user decided on (inode, modification time, size): with allowRun, the user's execute bit (u+x; never setuid, setgid,
// group or others), checked afterwards with fstat (a FAT mount accepts the chmod and keeps its own modes); then Files'
// approval. A file system without user extended attributes keeps no approval (the next open asks again).
Approval approve(const QString &path, quint64 inode, qint64 mtimeNs, qint64 size, bool allowRun);

// ~/Applications (macOS: an app is copied to the Applications folder), made if missing; "" when it can't be.
QString applicationsFolder();

// A name not taken in `folder` for `name`: "Tool.AppImage", then "Tool 2.AppImage", "Tool 3.AppImage", ...
QString freeName(const QString &folder, const QString &name);

// One start, watched for its first second. The program runs in its own session with stdin and stdout on /dev/null, in
// `workingDirectory` (Files passes the home folder: an app does not start in the folder it was opened from, as macOS starts
// apps in "/"), through the Dock's launch path (grassfield::apps::scopedCommand: its own uwsm-app scope in a real
// session; a program uwsm would read as a desktop entry, LaunchGuard::uwsmReadsAsEntry, is refused), as the user only (never
// when Files runs as root), with Files' environment. Its error output goes to a datagram socket that Files reads for the first second and then
// closes: later writes fail without a signal (a GUI app's output goes nowhere, as on macOS), and Files never holds the program
// up. finished() comes once, after the first second, or after the program's end within it. The object stays until the program
// has ended (it reaps it) or Files quits, then deletes itself.
class Run : public QObject
{
    Q_OBJECT

public:
    explicit Run(QObject *parent = nullptr);
    ~Run() override;

    void start(const QString &program, const QStringList &args, const QString &workingDirectory, bool appImage = false,
               const QString &interpreter = QString());

    // The command a start runs (scopedCommand of program and args), for tests.
    static QStringList command(const QString &program, const QStringList &args);
    // Whether a command may be started at all: not when Files runs as root, and not an uwsm-app command whose main argument
    // uwsm would read as a desktop entry.
    static bool allowed(const QStringList &argv);

signals:
    void finished(const ProgramLaunch::Outcome &outcome);

private:
    void readErrors();
    void childEnded();
    void windowEnded();
    void report(const Outcome &outcome);
    void closeErrors();
    void checkFuse(Outcome outcome);

    Start m_start;
    int m_pid = -1;
    int m_pidfd = -1;
    int m_errors = -1;
    bool m_reported = false;
    bool m_ended = false;
    QSocketNotifier *m_errorNotifier = nullptr;
    QSocketNotifier *m_endNotifier = nullptr;
    QTimer *m_poll = nullptr;
};

} // namespace ProgramLaunch

Q_DECLARE_METATYPE(ProgramLaunch::Outcome)
