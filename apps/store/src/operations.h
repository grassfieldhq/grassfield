// The Store's operations (ADR-0037 b, f; spec SR17-SR21): one at a time, in a queue the user fills (Get, Uninstall), each
// ending with an exit code the Store receives, and success being that code 0 AND the system's state matching the plan.
//   helper  repository packages: pkexec grassfield-store-helper <verb> <op-id> <names> (b.1), a direct, waited-for child
//           in a session of its own (no terminal's signal reaches it), while the Store holds Omarchy's update lock (opened
//           close-on-exec: neither pkexec nor pacman inherits it); the helper's files in /run/grassfield-store/ say when it
//           started and how it ended, and pacman's log gives the progress ("[ALPM] installed" lines against the plan)
//   terminal  an Omarchy setup's recipe: omarchy-launch-floating-terminal-with-presentation "grassfield-store-run <op-id>
//           <deadline> setup <recipe> [<arg>...]" (b.2), detached, or an AUR package's install or removal: "... aur
//           omarchy-pkg-aur-add <name>" or "... aur omarchy-pkg-drop <name>" (step 3b2); the script runs as the user in
//           Omarchy's terminal, takes Omarchy's update lock itself (the Store only checks it is free before), checks the
//           pins the Store wrote in $XDG_RUNTIME_DIR/grassfield/store/<op-id>.pins, and its <op-id>.started and
//           <op-id>.exit there say when it started and how it ended; pacman's log gives the progress as for the helper
//   webapp  Omarchy's omarchy-webapp-install / -remove as the Store's own child (b.3), 10 minutes at most
//   flatpak a Flatpak of Flathub (b.3, step 3c): `flatpak install --user --noninteractive flathub <ref>`, or `flatpak
//           uninstall --user --noninteractive <app id>` then `--unused` (the runtimes no app needs any more, SD27), as the
//           Store's own child (it dies with the Store: SIGTERM, which stops flatpak cleanly, S25); stopped when it prints
//           nothing for 30 minutes (a stalled network, SU-09), and an install or an update can be stopped (SIGTERM, SD26);
//           progress from its "Installing <ref>" lines against flatpak's own plan
// Before an operation starts, it is written to store.json; on the next start a record still there is compared with what is
// there (recover): done, still running (followed again), interrupted (a part there), or not finished. The Store never
// signals pacman, the helper, the terminal or Omarchy's commands, except a web app command past its limit, and pkexec while
// it still waits for the password (before the helper started, pkexec is the user's process), and flatpak when the user stops
// an install.
#pragma once

#include "plancheck.h"

#include <QDateTime>
#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QProcessEnvironment>
#include <QString>
#include <QStringList>
#include <QThreadPool>
#include <QTimer>
#include <QVariantList>

#include <functional>
#include <optional>

namespace grassfield::store {

// What store.json keeps of the operation in flight (version 1, key "operation").
struct OperationRecord {
    QString id;      // 32 lowercase hexadecimal digits
    QString kind;    // install, remove; update (a Flatpak's, step 4)
    QString path;    // helper, terminal, webapp
    QString app;     // the app's id
    QString name;    // the app's name, for the messages
    QStringList packages;         // helper: the names given to it; terminal: the setup's packages
    // helper, terminal: what must be there after an install (name, version: "" for any, an AUR package's), gone after a removal
    QList<PlannedPackage> plan;
    QString recipe;               // terminal: omarchy-install-… or omarchy-remove-…, the AUR's command (kAurAdd, kAurDrop) or kFlatpakAdd
    QStringList args;             // terminal: the recipe's arguments, or the AUR package's name
    // terminal: the catalog's pins (ADR-0037 g), written to <op-id>.pins when it starts; not kept in store.json.
    QList<std::pair<QString, QString>> pins;
    QString webName, webUrl, webIcon; // webapp: the launcher's name (its file's), its URL, the icon file given
    // flatpak: the ref an install takes (app/<id>/<arch>/<branch>), or the app id a removal takes; an update names its refs
    // (apps' and runtimes') in `packages` and its app's ref here when it updates one app ("" for all of them)
    QString flatpak;
    // flatpak update: the commit each ref of `packages` is pinned to (its plan checked that commit's access, SD33), "" for
    // a ref updated to whatever Flathub serves (a runtime, or an app whose commit could not be read: the sheet said so).
    QStringList commits;
    // flatpak update: each pinned ref's installed commit when its plan read it ("" unread). Installed with another commit
    // by the time its turn comes, the ref was updated outside the Store and is left as it is: never put back to an older one.
    QStringList fromCommits;
    QDateTime startedAt;

    QJsonObject toJson() const;
    static std::optional<OperationRecord> fromJson(const QJsonObject &o);
};

// A Flatpak update's commands, in order (S32): each pinned app on its own (`--commit` takes one ref, S32d), then the
// unpinned refs together; each `flatpak update --user --noninteractive [--commit=<c>] -- <refs>`.
QList<QStringList> flatpakUpdateCommands(const OperationRecord &record);
// For each of those commands, the ref it pins and the commit that ref must still have installed to run it ("" for the rest).
QList<std::pair<QString, QString>> flatpakUpdateGuards(const OperationRecord &record);

QString newOperationId();
bool isOperationId(const QString &id);

// A setup's recipe and its arguments as ADR-0037 e.5 allows them (the terminal's command string is built from them).
bool isRecipe(const QString &recipe);
bool isRecipeArgs(const QStringList &args);
// The AUR's two commands (b.2, step 3b2), run with 1 to 4 package names.
inline const QString kAurAdd = QStringLiteral("omarchy-pkg-aur-add");
inline const QString kAurDrop = QStringLiteral("omarchy-pkg-drop");
// Get Flatpak… (step 3c part 3, SD24): Omarchy's omarchy-pkg-add with the one argument flatpak, nothing else.
inline const QString kFlatpakAdd = QStringLiteral("omarchy-pkg-add");
inline const QString kFlatpakPackage = QStringLiteral("flatpak");
bool isAurNames(const QStringList &names);
// grassfield-store-run's kind for a terminal operation: "setup" (a recipe and its arguments), "aur" (one of the AUR's two
// commands and package names), "" when neither.
QString terminalKind(const QString &recipe, const QStringList &args);
// grassfield-store-run's command string, the one argument of Omarchy's terminal launcher (b.2): "" when a token is invalid.
QString terminalCommand(const QString &run, const QString &id, qint64 deadline, const QString &recipe, const QStringList &args);

// The helper's files (ADR-0037 b.1), and grassfield-store-run's (b.2, the same names): the exit code, when written.
std::optional<int> helperExitCode(const QString &statusDir, const QString &id);
// Its started file names a process that still runs: the pid with the same start time (/proc/<pid>/stat, field 22).
// (`statusDir` is grassfield-store-run's folder for a terminal operation.)
bool helperRunning(const QString &statusDir, const QString &id);
// pacman's log since `offset`: the "[ALPM] installed <name> (" (or "removed") lines of the plan's packages.
int countLogged(const QByteArray &logTail, const QString &verb, const QStringList &names);

// How an operation ended, from its exit code (nullopt: none came) and what is there now (`present` of `total` planned
// packages installed, for an install; removed, for a removal).
enum class Outcome { Done, Interrupted, NotFinished };
Outcome judge(std::optional<int> exitCode, int present, int total);

struct OperationsConfig {
    QString pkexec;     // /usr/bin/pkexec, or a fake one (dev plumbing GRASSFIELD_STORE_PKEXEC)
    QString helper;     // /usr/lib/grassfield/grassfield-store-helper
    QString statusDir;  // /run/grassfield-store
    QString updateLock; // ${XDG_RUNTIME_DIR:-/tmp}/omarchy-update.lock
    QString dbLock;     // /var/lib/pacman/db.lck
    QString pacmanLog;  // /var/log/pacman.log
    QString pacman;     // for the state after an operation
    QString stateFile;  // store.json
    QString applications; // ~/.local/share/applications: the web apps' launchers
    QString run;          // /usr/lib/grassfield/grassfield-store-run
    QString runDir;       // $XDG_RUNTIME_DIR/grassfield/store ("": no setup runs)
    // The argument vector that runs one of Omarchy's commands: its own program, or a fake one (GRASSFIELD_STORE_INSTALLER).
    std::function<QStringList(const QString &command, const QStringList &args)> omarchy;
    QString flatpak;                 // /usr/bin/flatpak, or the fixture's fake ("": no Flatpak operation runs)
    QProcessEnvironment flatpakEnv; // the user's HOME, XDG folders and proxy (flatpak.h flatpakEnvironment)
    // The limits (ADR-0037 b.1, b.3; spec SR19), shorter in the tests.
    int authorizationMs = 120 * 1000;
    qint64 helperMs = 2LL * 3600 * 1000;
    int webAppMs = 10 * 60 * 1000;
    // A Flatpak operation (install, update, removal) that prints nothing for this long is stalled (a network that stopped
    // answering, SU-09): flatpak gets SIGTERM, SIGKILL 10 s later, and the operation ends "not finished".
    qint64 flatpakIdleMs = 30LL * 60 * 1000;
    // The terminal (b.2): the script must start within terminalStartMs (its deadline; the Store waits 15 s more for its
    // started file, the script being past the deadline check by then), and is followed up to terminalMs.
    int terminalStartMs = 60 * 1000;
    int terminalGraceMs = 15 * 1000;
    qint64 terminalMs = 3LL * 3600 * 1000;
    int pollMs = 500;
};

class Operations : public QObject
{
    Q_OBJECT

public:
    enum class State { Waiting, Authorizing, Opening, Running, Checking }; // Opening: the terminal, before the script started

    struct Item {
        OperationRecord record;
        State state = State::Waiting;
        bool blocked = false; // waiting for the locks (another installation or an update)
        int done = 0;         // the plan's packages pacman's log counted so far
    };

    // How the last operation of an app ended, while it says something (a failure; "done" is said by the button).
    struct Result {
        QString app, kind;
        QString outcome; // cancelled, stopped, failed, interrupted, notFinished, lostTrack, timedOut, busy, unfinished,
                         // outdated, refused, notApp, didNotStart, omarchyChanged, terminalDidNotOpen
        int present = 0, total = 0;
        QString details; // pacman's message (the helper's log), pkexec's or Omarchy's output
        OperationRecord record;
    };

    explicit Operations(const OperationsConfig &config, QObject *parent = nullptr);
    ~Operations() override;

    void enqueue(const OperationRecord &record);
    // A waiting operation leaves the queue (the running one cannot: it ends in pacman, the helper or Omarchy's command).
    bool removeWaiting(const QString &id);
    // A failure's line goes (the user read it, or tries again).
    void dismiss(const QString &app);
    // The running Flatpak install or update stops (SD26, SU-09: SIGTERM, which ends flatpak at once and leaves nothing
    // half-installed, S25; an update's refs done so far stay); false for anything else, which cannot be stopped.
    bool stop(const QString &id);
    // SU-07: the quit waits for the workers (the state read after an operation, store.json's writes), `ms` at most.
    bool drain(int ms);
    // The record left in store.json by an earlier run of the Store, compared with what is there.
    void recover();

    bool running() const { return m_current.has_value(); }
    bool queued(const QString &app) const;
    QList<Item> items() const;
    QHash<QString, Result> results() const { return m_results; }
    // [{id, app, name, kind, path, state: waiting | authorizing | opening | running | checking, blocked, done, total,
    // stoppable}] for QML.
    QVariantList list() const;

signals:
    void changed();
    // An operation ended (whatever its outcome): the system changed, read it again.
    void finished(const QString &app);
    // The last running operation ended and nothing waits.
    void idle();

private:
    void startNext();
    void startHelper(Item &item);
    void startWebApp(Item &item);
    void startTerminal(Item &item);
    // flatpak with `args`, its output kept for Details and counted for the progress.
    void startFlatpak(const QStringList &args);
    void pollTerminal(Item &item, qint64 elapsed);
    // The plan's packages pacman's log counted since the operation started.
    void countProgress(Item &item);
    // The terminal's files of operations other than `keep`, older than its 3 h (an operation the Store concluded, or
    // one of an earlier run).
    void pruneRunDir(const QString &keep);
    void poll();
    void processEnded(int exitCode, QProcess::ExitStatus status);
    void conclude(std::optional<int> exitCode, const QString &output);
    // store.json's record, written on the writer's thread (never on the click path), in order; `then` runs here once it is
    // on disk (an operation starts only after its record is written: the recovery needs it).
    void writeRecord(const OperationRecord &record, std::function<void()> then = {});
    void clearRecord();
    QString helperLog(const QString &id) const;
    // The state after an operation, off the GUI thread; `then` runs back here with (present, total).
    void readState(const OperationRecord &record, std::function<void(int, int)> then);
    bool takeUpdateLock();
    void releaseUpdateLock();

    OperationsConfig m_config;
    QList<Item> m_queue;          // waiting, in order
    std::optional<Item> m_current; // running
    QHash<QString, Result> m_results;
    QPointer<QProcess> m_process;
    QByteArray m_output;
    QTimer m_poll;
    QTimer m_retry;
    QDateTime m_runningSince;
    qint64 m_logOffset = 0;
    int m_lockFd = -1;
    bool m_concluding = false;
    bool m_followOnly = false; // recover(): a helper of an earlier run is followed, not owned
    bool m_stopping = false;   // stop(): the running Flatpak install was asked to stop
    bool m_idleStopped = false; // the running Flatpak operation printed nothing for flatpakIdleMs and was stopped (SU-09)
    QDateTime m_lastOutput;     // flatpak's last output (or its start)
    std::optional<int> m_firstExit; // a Flatpak removal's own exit code, while `--unused` runs after it
    QByteArray m_flatpakOutput;     // what flatpak printed (1 MiB at most): its progress
    QList<QStringList> m_flatpakSteps; // an update's commands still to run, each after the one before succeeded
    QList<std::pair<QString, QString>> m_flatpakGuards; // with each, its ref and the commit it must still have ("" none)
    void startUpdateStep();
    void begin(); // startNext's second half, once the record is written
    // SU-14: the workers' answers go to this object, which outlives the pools (declared before them): never to a QPointer
    // read on a worker's thread. Its own pools, waited for when the Operations go (never the global one, which outlives it).
    QObject m_context;
    QThreadPool m_writer; // store.json's writes, one at a time, in order
    QThreadPool m_pool;   // the state after an operation, a Flatpak's installed commit
};

} // namespace grassfield::store
