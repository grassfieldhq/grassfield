#include "backend.h"
#include <QStringDecoder>

#include <algorithm>
#include <numeric>

#include "runmode.h"

#include <QCollator>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSaveFile>
#include <QScreen>
#include <QSet>
#include <QStandardPaths>
#include <QStorageInfo>
#include <QTimeZone>
#include <QDateTime>
#include <QLocale>
#include <QTimer>

#include "busjobs.h"
#include "qtbuscaller.h"
#include "systemguard.h"


#ifndef GRASSFIELD_DEV_BINDINGS
#define GRASSFIELD_DEV_BINDINGS ""
#endif

namespace {
constexpr qint64 kMaxRead = 4 * 1024 * 1024;
constexpr int kRunTimeoutMs = 3000;
constexpr int kMaxReason = 160;
constexpr int kQueryJobMs = 10000;  // a D-Bus state read: past this the page gets "timed out"
constexpr int kActionJobMs = 60000; // a D-Bus action: its look-ups are 3 s reads (kReadMs), then exactly one call of up to kActMs (30 s)
constexpr int kPrivilegedJobMs = 370000; // three calls that may each wait for the polkit dialog (kPrivilegedMs, 120 s): Add Printer, ADR-0030
constexpr int kUpdateCheckMs = 200000;   // the checker stops itself after 180 s (SIGTERM, then SIGKILL 5 s later): U1
// fprintd's enrolment (ADR-0045 OC-0.7): it ends itself after a minute without a status from the reader (the person left), and
// the job gets room for Claim and EnrollStart, which may each wait for the polkit dialog (120 s), and for a slow enrolment.
// It also ends 300 s after EnrollStart answered whatever the reader sends (someone else's touches cannot keep it going), well
// before the job's own limit, so a job the jobs gave up on has always ended by itself (security review of ADR-0045, L-5).
constexpr int kEnrollIdleMs = 60000;
constexpr int kEnrollTotalMs = 300000;
constexpr int kEnrollJobMs = 600000;

// Every tool runs in the C locale: the parsers (qml/System.js) read the English, untranslated output.
QProcessEnvironment cLocaleEnvironment()
{
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C"));
    env.remove(QStringLiteral("LANGUAGE"));
    return env;
}

// One short line explaining a failure: first non-empty line of stderr, else of stdout (bluetoothctl reports errors there).
QString reasonOf(const QByteArray &err, const QByteArray &out)
{
    for (const QByteArray &src : {err, out}) {
        for (const QString &line : QString::fromUtf8(src).split(QLatin1Char('\n'))) {
            QString t = line.simplified();
            t.remove(QRegularExpression(QStringLiteral("[\\x00-\\x1f\\x7f]")));
            if (!t.isEmpty())
                return t.left(kMaxReason);
        }
    }
    return QString();
}

QString resolveConfigFile()
{
    // GRASSFIELD_CONFIG_HOME wins, like the shell; else $XDG_CONFIG_HOME/grassfield (runmode.h).
    return grassfield::apps::runmode::configDir() + "/grassfield.json";
}

QString resolveBindingsFile()
{
    // Installed file first; GRASSFIELD_CONFIG_DIR (set in the dev session) and the build-time
    // repository path serve a repo session.
    const QString installed = QStringLiteral("/usr/share/grassfield/hypr/grassfield/bindings.lua");
    if (QFile::exists(installed))
        return installed;
    const QString dir = qEnvironmentVariable("GRASSFIELD_CONFIG_DIR");
    const QStringList dev = {dir.isEmpty() ? QString() : dir + "/grassfield/bindings.lua", QStringLiteral(GRASSFIELD_DEV_BINDINGS)};
    for (const QString &c : dev) {
        if (!c.isEmpty() && QFile::exists(c))
            return c;
    }
    return installed;
}
} // namespace

Backend::Backend(QObject *parent)
    : QObject(parent)
    , m_configFile(resolveConfigFile())
    , m_bindingsFile(resolveBindingsFile())
    , m_dev(grassfield::settings::devSession())
{
    grassfield::settings::registerBusTypes();
    m_bus = std::make_unique<Bus>();
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, &Backend::onPath);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, &Backend::onPath);
    if (m_dev) {
        // The dev binary sits in <worktree>/.dev/build: the helper next to it, the cache and the pictures under .dev.
        const QString dev = QDir(QCoreApplication::applicationDirPath() + QStringLiteral("/..")).canonicalPath();
        m_devRoot = QFileInfo(dev).dir().absolutePath();
        m_wallpaperTool = QCoreApplication::applicationDirPath() + QStringLiteral("/grassfield-wallpaper");
        m_wallpaperCache = dev + QStringLiteral("/cache/wallpapers");
        const QString pictures = grassfield::apps::runmode::devValue("PICTURES_DIR");
        m_picturesDir = pictures.isEmpty() ? dev + QStringLiteral("/wallpapers") : pictures;
        // Under .dev, where the dev guard lets a wallpaper be (the package installs them under /usr/share).
        m_wallpaperPhotosDir = dev + QStringLiteral("/photos");
    } else {
        m_wallpaperTool = QStringLiteral("/usr/lib/grassfield/grassfield-wallpaper");
        const QString xdg = qEnvironmentVariable("XDG_CACHE_HOME");
        m_wallpaperCache = (xdg.isEmpty() ? QDir::homePath() + QStringLiteral("/.cache") : xdg) + QStringLiteral("/grassfield/wallpapers");
        const QString pictures = grassfield::apps::runmode::devValue("PICTURES_DIR");
        m_picturesDir = pictures.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::PicturesLocation) : pictures;
        m_wallpaperPhotosDir = QStringLiteral("/usr/share/grassfield/wallpapers/photos");
    }
}

QString Backend::wallpaperStatusFile() const
{
    return QFileInfo(m_configFile).absolutePath() + QStringLiteral("/wallpaper-state.json");
}

QString Backend::wallpaperRecentFile() const
{
    return QFileInfo(m_configFile).absolutePath() + QStringLiteral("/wallpaper-recent.json");
}

struct Backend::Bus {
    grassfield::settings::SystemBusConnection connection;
    grassfield::settings::BusJobs jobs{[this] { return connection.caller(); }};
    // The session bus: the user's own service manager (Login Items).
    grassfield::settings::SystemBusConnection sessionConnection{QDBusConnection::SessionBus, QStringLiteral("gf-settings-session-bus")}; // i18n-ignore: a connection name
    grassfield::settings::BusJobs sessionJobs{[this] { return sessionConnection.caller(); }};
};

Backend::~Backend()
{
    // Never destroy a running QProcess. This comes first: the D-Bus jobs below may abandon the process (_Exit), which skips every
    // destructor, and a wpctl or the wallpaper helper still running would be left behind.
    const auto procs = findChildren<QProcess *>(QString(), Qt::FindDirectChildrenOnly);
    for (QProcess *p : procs) {
        p->disconnect(this);
        if (p->state() != QProcess::NotRunning) {
            p->kill();
            p->waitForFinished(1000);
        }
    }
    // An enrolment under way stops at its next quarter-second wait and releases the reader (fprintd would anyway once this
    // process leaves the bus).
    stopEnroll();
    m_bus.reset(); // waits for a D-Bus job a moment at most, then abandons it (busjobs.h): the window closes promptly
}

void Backend::start(const QStringList &argv, const QString &tag, int timeoutMs, Track track)
{
    start(argv, tag, timeoutMs, track, cLocaleEnvironment());
}

void Backend::start(const QStringList &argv, const QString &tag, int timeoutMs, Track track, const QProcessEnvironment &env)
{
    auto *p = new QProcess(this);
    // Once, whichever way the process ends: the query or action it held is over.
    const auto settle = [this, tag, track] {
        if (track == Track::Query)
            m_queries.end(tag);
        else if (track == Track::Action)
            endAction(tag);
    };
    p->setProcessEnvironment(env);
    auto *timer = new QTimer(p);
    timer->setSingleShot(true);
    connect(timer, &QTimer::timeout, p, [p] {
        p->setProperty("timedOut", true);
        p->kill();
    });
    connect(p, &QProcess::errorOccurred, this, [this, p, tag, settle](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart) {
            settle();
            emit failed(tag, p->errorString().left(kMaxReason));
            emit finished(tag, false, QString());
            p->deleteLater();
        }
    });
    connect(p, &QProcess::finished, this, [this, p, tag, settle](int code, QProcess::ExitStatus status) {
        settle();
        const bool ok = status == QProcess::NormalExit && code == 0;
        const QByteArray out = p->readAllStandardOutput();
        if (!ok)
            emit failed(tag, p->property("timedOut").toBool() ? QCoreApplication::translate("SystemBus", "timed out") : reasonOf(p->readAllStandardError(), out));
        emit finished(tag, ok, QString::fromUtf8(out));
        p->deleteLater();
    });
    p->start(argv.first(), argv.mid(1), QIODevice::ReadOnly);
    timer->start(timeoutMs);
}

// A command that names the wallpaper helper runs only as one of the vectors of systemguard.h::isWallpaperQuery, with the
// helper at its exact path, in every session.
bool Backend::wallpaperAllowed(const QStringList &argv) const
{
    return grassfield::settings::isWallpaperQuery(argv, {m_wallpaperTool, m_wallpaperCache, m_devRoot});
}

void Backend::query(const QStringList &argv, const QString &tag, int timeoutMs, bool shared)
{
    const bool helper = !argv.isEmpty() && grassfield::settings::namesWallpaperTool(argv.first());
    if (argv.isEmpty() || (helper ? !wallpaperAllowed(argv) : (m_dev && !grassfield::settings::isReadOnlyQuery(argv)))) {
        if (!argv.isEmpty())
            qWarning().noquote() << "dev guard: refused a command that is not a read-only query:" << argv.first();
        emit finished(tag, false, QString());
        return;
    }
    // Only by opt-in: a caller that counts its requests needs one answer each (counter-review of PR #6: a thumbnail asked for
    // again while in flight left WallpaperPage's count one too high, and after two such requests no thumbnail loaded).
    if (!shared) {
        start(argv, tag, timeoutMs, Track::None);
        return;
    }
    // A page shown again asks for what still runs (Storage's counts, up to two minutes each): it gets that answer.
    const QString key = argv.join(QChar(0x1f));
    if (m_queries.runs(tag, key))
        return;
    start(argv, tag, timeoutMs, m_queries.begin(tag, key) ? Track::Query : Track::None);
}

void Backend::readOnlyQuery(const QStringList &argv, const QString &tag, int timeoutMs, bool shared)
{
    // A query whose answer is a secret (systemguard.h isPrivateQuery: Share Network's QR code) runs in a real session only.
    if (!grassfield::settings::isReadOnlyQuery(argv) && (m_dev || !grassfield::settings::isPrivateQuery(argv))) {
        if (!argv.isEmpty())
            qWarning().noquote() << (m_dev && grassfield::settings::isPrivateQuery(argv) ? "dev guard: refused a query that answers with a secret:"
                                                                                         : "refused a read-only query that is not one:")
                                 << argv.first();
        emit finished(tag, false, QString());
        return;
    }
    query(argv, tag, timeoutMs, shared);
}

bool Backend::beginAction(const QString &tag, const QString &what)
{
    if (!m_actions.begin(tag, what)) {
        qWarning().noquote() << "refused" << what << "while the previous action of" << tag << "still runs";
        return false;
    }
    emit pendingActionsChanged();
    return true;
}

void Backend::endAction(const QString &tag)
{
    m_actions.end(tag);
    emit pendingActionsChanged();
}

bool Backend::act(const QString &what, const QStringList &argv, const QString &tag, int timeoutMs)
{
    if (m_dev) {
        qInfo().noquote() << "dev guard:" << what << "suppressed";
        emit suppressed(what);
        return false;
    }
    if (!grassfield::settings::isAllowedAction(argv)) {
        qWarning().noquote() << "refused an action with an unknown program:" << what;
        return false;
    }
    // One at a time per tag when it may wait for a password (a page shown again cannot start a second prompt).
    const bool latch = grassfield::settings::asksForPassword(argv);
    if (latch && !beginAction(tag, what))
        return false;
    start(argv, tag, grassfield::settings::actionTimeoutMs(argv, timeoutMs), latch ? Track::Action : Track::None);
    return true;
}

bool Backend::launch(const QString &what, const QStringList &argv)
{
    if (m_dev) {
        qInfo().noquote() << "dev guard:" << what << "suppressed";
        emit suppressed(what);
        return false;
    }
    if (!grassfield::settings::isLaunch(argv) && !grassfield::settings::isRevealInFiles(argv, homeDir())) {
        qWarning().noquote() << "refused a launch that is not one of Settings':" << what;
        return false;
    }
    // Omarchy's terminal and grassfield-session-end speak to the user: the session's own language, not the C locale.
    QProcess p;
    p.setProgram(argv.first());
    p.setArguments(argv.mid(1));
    p.setStandardInputFile(QProcess::nullDevice());
    p.setStandardOutputFile(QProcess::nullDevice());
    p.setStandardErrorFile(QProcess::nullDevice());
    if (!p.startDetached()) {
        qWarning().noquote() << "could not start" << what;
        return false;
    }
    return true;
}

bool Backend::omarchyUpdate() const
{
    return !QStandardPaths::findExecutable(QStringLiteral("omarchy-launch-floating-terminal-with-presentation")).isEmpty()
        && !QStandardPaths::findExecutable(QStringLiteral("omarchy-update")).isEmpty();
}

bool Backend::reportTool() const
{
    return QFileInfo(QStringLiteral("/usr/lib/grassfield/grassfield-report")).isExecutable();
}

bool Backend::updateRunner() const
{
    return QFileInfo(QStringLiteral("/usr/lib/grassfield/grassfield-update-run")).isExecutable()
        && QFileInfo(QStringLiteral("/usr/lib/grassfield/grassfield-update-helper")).isExecutable()
        && QFileInfo(QStringLiteral("/usr/bin/pkexec")).isExecutable();
}

QString Backend::softwareUpdateFile() const
{
    return grassfield::apps::runmode::stateDir() + QStringLiteral("/software-update.json");
}

void Backend::askShellToCheck(const QString &tag)
{
    const QStringList ipc = grassfield::apps::runmode::shellIpcArgs();
    if (ipc.isEmpty()) {
        // Answered on the next turn of the event loop, like a run: the pane asks while it is being built (its Component.onCompleted),
        // before its connections to this signal exist, and a refusal emitted at once was lost and left it on "Checking" for good.
        const QString reason = grassfield::apps::runmode::shellIpcRefusal().left(kMaxReason);
        QTimer::singleShot(0, this, [this, tag, reason] {
            emit failed(tag, reason);
            emit finished(tag, false, QString());
        });
        return;
    }
    // The running shell is named by its directory (-p), never by a configuration Quickshell would look up from QS_*.
    QProcessEnvironment env = cLocaleEnvironment();
    for (const QString &key : env.keys()) {
        if (key.startsWith(QLatin1String("QS_")))
            env.remove(key);
    }
    start(QStringList{QStringLiteral("qs")} + ipc + QStringList{QStringLiteral("update"), QStringLiteral("check"), QStringLiteral("user")}, tag,
          grassfield::apps::runmode::kShellIpcMs, Track::None, env);
}

QString Backend::updateCheckerProgram()
{
    const QString command = grassfield::apps::runmode::devValue("UPDATE_CHECK_CMD");
    return command.isEmpty() ? QStringLiteral("/usr/lib/grassfield/grassfield-update-check") : command;
}

QString Backend::updateFixture()
{
    return grassfield::apps::runmode::devValue("UPDATE_FIXTURE");
}

QString Backend::powerFixture()
{
    return grassfield::apps::runmode::devValue("POWER_FIXTURE");
}

void Backend::runUpdateChecker(const QString &tag)
{
    using namespace grassfield::apps;
    // A dev session's canned answer (ADR-0019 dev plumbing): read here, answered on the next turn of the event loop like a run.
    const QString fixture = updateFixture();
    if (!fixture.isEmpty()) {
        const QVariantMap r = readText(fixture);
        const bool ok = r.value(QStringLiteral("ok")).toBool();
        const QString text = r.value(QStringLiteral("text")).toString();
        QTimer::singleShot(0, this, [this, tag, ok, text] {
            if (!ok)
                emit failed(tag, QCoreApplication::translate("SystemBus", "the answer file cannot be read"));
            emit finished(tag, ok, ok ? text : QString());
        });
        return;
    }
    QProcessEnvironment env = cLocaleEnvironment();
    // A dev session's checker keeps its cache under the dev state (ADR-0033 "Dev sessions"), as the shell's does.
    if (m_dev)
        env.insert(QStringLiteral("XDG_CACHE_HOME"), runmode::stateDir() + QStringLiteral("/cache"));
    start({updateCheckerProgram()}, tag, kUpdateCheckMs, Track::None, env);
}

// One D-Bus job on a worker thread, on the app's one connection to the system bus (a blocked service never blocks the window, and
// nothing a job holds outlives the Backend: busjobs.h). `job` returns "" on success, else the reason; its second argument
// receives the output (JSON) of a query.
void Backend::runBus(const QString &tag, std::function<QString(grassfield::settings::BusCaller &, QString *)> job, int timeoutMs, bool session,
                     bool action)
{
    const bool dev = m_dev;
    (session ? m_bus->sessionJobs : m_bus->jobs).start(
        [dev, job = std::move(job)](grassfield::settings::BusCaller &real, QString *output) {
            grassfield::settings::GuardedCaller guarded(real, dev);
            return job(guarded, output);
        },
        [this, tag, action](const QString &reason, const QString &output) {
            if (action)
                endAction(tag);
            if (!reason.isEmpty()) {
                emit failed(tag, reason);
                emit finished(tag, false, QString());
            } else {
                emit finished(tag, true, output);
            }
        },
        timeoutMs);
}

void Backend::busQuery(const QString &what, const QString &tag)
{
    using namespace grassfield::settings;
    static const QStringList known{QStringLiteral("wifi.state"),    QStringLiteral("bt.state"),      QStringLiteral("host.state"),    QStringLiteral("time.state"),
                                   QStringLiteral("time.zones"),    QStringLiteral("locale.state"),  QStringLiteral("user.units"),    QStringLiteral("net.state"),
                                   QStringLiteral("power.state"),   QStringLiteral("privacy.state"), QStringLiteral("sharing.state"), QStringLiteral("disk.state"),
                                   QStringLiteral("fprint.state")};
    if (!known.contains(what)) {
        qWarning().noquote() << "refused a bus query that is not known:" << what;
        emit finished(tag, false, QString());
        return;
    }
    // A dev session's canned battery (ADR-0019 dev plumbing): read here, answered on the next turn of the event loop like a bus
    // answer. The pages check it as they check UPower's (Power.js parseState).
    const QString fixture = what == QLatin1String("power.state") ? powerFixture() : QString();
    if (!fixture.isEmpty()) {
        const QVariantMap r = readText(fixture);
        const bool ok = r.value(QStringLiteral("ok")).toBool();
        const QString text = r.value(QStringLiteral("text")).toString().trimmed();
        QTimer::singleShot(0, this, [this, tag, ok, text] {
            if (!ok)
                emit failed(tag, QCoreApplication::translate("SystemBus", "the answer file cannot be read"));
            emit finished(tag, ok, ok ? text : QString());
        });
        return;
    }
    const QStringList own = userUnitDirs();
    runBus(tag, [what, own](BusCaller &bus, QString *output) {
        const StateResult r = what == QLatin1String("wifi.state") ? wifiState(bus)
            : what == QLatin1String("bt.state")                  ? bluetoothState(bus)
            : what == QLatin1String("host.state")                ? hostState(bus)
            : what == QLatin1String("time.state")                ? timeState(bus)
            : what == QLatin1String("time.zones")                ? timeZones(bus)
            : what == QLatin1String("locale.state")              ? localeState(bus)
            : what == QLatin1String("net.state")                 ? networkState(bus)
            : what == QLatin1String("power.state")               ? powerState(bus)
            : what == QLatin1String("privacy.state")             ? privacyState(bus)
            : what == QLatin1String("sharing.state")             ? sharingState(bus)
            : what == QLatin1String("disk.state")                ? diskState(bus)
            : what == QLatin1String("fprint.state")              ? fingerprintState(bus)
                                                                 : userUnits(bus, own);
        if (!r.ok)
            return r.error.isEmpty() ? QCoreApplication::translate("SystemBus", "no answer") : r.error;
        *output = QString::fromUtf8(QJsonDocument(r.json).toJson(QJsonDocument::Compact));
        return QString();
    }, kQueryJobMs, what == QLatin1String("user.units") || what == QLatin1String("privacy.state"));
}

QStringList Backend::userUnitDirs() const
{
    // The user's own unit directories (systemd.unit(5), the user manager's search path): config, then data.
    using grassfield::settings::xdgHome;
    const QString config = xdgHome(qEnvironmentVariable("XDG_CONFIG_HOME"), QDir::homePath() + QStringLiteral("/.config"));
    const QString data = xdgHome(qEnvironmentVariable("XDG_DATA_HOME"), QDir::homePath() + QStringLiteral("/.local/share"));
    return {QDir::cleanPath(config + QStringLiteral("/systemd/user")), QDir::cleanPath(data + QStringLiteral("/systemd/user"))};
}

bool Backend::busAct(const QString &what, const QVariantMap &op, const QString &tag)
{
    using namespace grassfield::settings;
    if (m_dev) {
        qInfo().noquote() << "dev guard:" << what << "suppressed";
        emit suppressed(what);
        return false;
    }
    if (!validAction(op)) {
        qWarning().noquote() << "refused a bus action that is not well formed:" << what;
        return false;
    }
    // A polkit action runs one at a time per tag: a page shown again while the dialog is up cannot send a second one, and
    // blocked calls cannot fill the jobs' kMaxInFlight (integrator review of PR #6).
    const bool latch = privilegedAction(op);
    if (latch && !beginAction(tag, what))
        return false;
    // fprintd's enrolment (ADR-0045 OC-0.7): each status reaches the page as it comes (progress), through the jobs' mailbox, so
    // the functor that emits it runs on this thread and only while the jobs live (busjobs.h poster); the job keeps no pointer
    // it would follow. The sheet closed or the window going ends it between two waits (stopEnroll).
    if (op.value(QStringLiteral("op")).toString() == QLatin1String("fprint.enroll")) {
        // An older enrolment that may still run (its job timed out for the jobs, not for itself) stops first: no stop flag is
        // ever left without a way to set it (security review of ADR-0045, L-5).
        stopEnroll();
        const auto stop = std::make_shared<std::atomic<bool>>(false);
        m_enrollStop = stop;
        const BusJobs::Post post = m_bus->jobs.poster();
        const QString finger = op.value(QStringLiteral("finger")).toString();
        const auto emitProgress = [this, tag](const QString &status) { emit progress(tag, status); };
        runBus(tag, [finger, stop, post, emitProgress](BusCaller &bus, QString *) {
            return enrollFinger(bus, finger, [post, emitProgress](const QString &status) { post([emitProgress, status] { emitProgress(status); }); },
                                [stop] { return stop->load(); }, kEnrollIdleMs, kEnrollTotalMs);
        }, kEnrollJobMs, false, true);
        return true;
    }
    const QStringList own = userUnitDirs();
    runBus(tag, [op, own](BusCaller &bus, QString *) { return runAction(bus, op, own); }, latch ? kPrivilegedJobMs : kActionJobMs, sessionAction(op), latch);
    return true;
}

void Backend::stopEnroll()
{
    if (m_enrollStop)
        m_enrollStop->store(true);
}

bool Backend::hasCommand(const QString &name) const
{
    static const QRegularExpression plain(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9][A-Za-z0-9._+-]{0,63}")));
    return plain.match(name).hasMatch() && !QStandardPaths::findExecutable(name).isEmpty();
}

QVariantList Backend::screens() const
{
    QVariantList out;
    const QScreen *primary = QGuiApplication::primaryScreen();
    for (const QScreen *s : QGuiApplication::screens()) {
        const QRect g = s->geometry();
        const qreal dpr = s->devicePixelRatio();
        out.append(QVariantMap{{"name", s->name()},
                               {"model", s->model()},
                               {"manufacturer", s->manufacturer()},
                               {"serial", s->serialNumber()},
                               {"x", g.x()},
                               {"y", g.y()},
                               {"width", g.width()},
                               {"height", g.height()},
                               {"scale", dpr},
                               {"pixelWidth", qRound(g.width() * dpr)},
                               {"pixelHeight", qRound(g.height() * dpr)},
                               {"refreshRate", s->refreshRate()},
                               // The panel's size in millimetres as the output reports it (About: the diagonal in inches).
                               {"physicalWidth", s->physicalSize().width()},
                               {"physicalHeight", s->physicalSize().height()},
                               {"primary", s == primary}});
    }
    return out;
}

QVariantList Backend::volumes() const
{
    // Local volumes only (systemguard.h isLocalVolume): this runs on the GUI thread, and the statfs of a network or FUSE mount
    // whose server or daemon does not answer would block the window. The mount table is /proc/self/mounts (reading it stats
    // nothing); the volume of the home is found in it, not by a statfs of the home. The start-up volume first, then the others
    // by mount point; a btrfs subvolume mounted twice is one volume.
    using namespace grassfield::settings;
    QFile table(QStringLiteral("/proc/self/mounts"));
    QList<Mount> mounts = table.open(QIODevice::ReadOnly) ? parseMounts(table.readAll()) : QList<Mount>{};
    const QString homeMount = mountPointOf(mounts, QDir::homePath());
    QVariantList out;
    QStringList seen;
    auto entry = [&homeMount](const QStorageInfo &v) {
        return QVariantMap{{"root", v.rootPath()},
                           {"name", v.name()},
                           {"device", QString::fromUtf8(v.device())},
                           {"type", QString::fromUtf8(v.fileSystemType())},
                           {"total", double(v.bytesTotal())},
                           {"available", double(v.bytesAvailable())},
                           {"free", double(v.bytesFree())},
                           {"readOnly", v.isReadOnly()},
                           {"isRoot", v.isRoot()},
                           {"holdsHome", v.rootPath() == homeMount}};
    };
    const QStorageInfo root = QStorageInfo::root();
    if (root.isValid() && root.isReady()) {
        out.append(entry(root));
        seen << QString::fromUtf8(root.device());
    }
    std::sort(mounts.begin(), mounts.end(), [](const Mount &a, const Mount &b) { return a.mountPoint < b.mountPoint; });
    for (const Mount &m : mounts) {
        if (!isLocalVolume(m.device, m.type) || seen.contains(m.device) || m.mountPoint == QLatin1String("/") || m.mountPoint.startsWith(QLatin1String("/boot")))
            continue;
        const QStorageInfo v(m.mountPoint);
        if (!v.isValid() || !v.isReady() || v.bytesTotal() <= 0)
            continue;
        seen << m.device;
        out.append(entry(v));
    }
    return out;
}

QVariantMap Backend::zoneInfo(const QString &zone) const
{
    // Names of a time zone in the UI language (Date & Time: "Central European Summer Time", "France", "UTC+02:00"); pure, no
    // privilege: Qt's own time zone data.
    const QTimeZone tz(zone.toUtf8());
    if (zone.isEmpty() || !tz.isValid())
        return {};
    const QDateTime now = QDateTime::currentDateTime();
    const QLocale locale;
    const QLocale::Territory territory = tz.territory();
    return {{"longName", tz.displayName(now, QTimeZone::LongName, locale)},
            {"shortName", tz.displayName(now, QTimeZone::ShortName, locale)},
            {"offset", tz.displayName(now, QTimeZone::OffsetName, locale)},
            {"offsetSeconds", tz.offsetFromUtc(now)},
            {"territory", territory == QLocale::AnyTerritory ? QString() : QLocale::territoryToString(territory)}};
}

QVariantList Backend::regionLocales() const
{
    // The default locale is the UI language (translationloader.h). A region's name carries the script only when it is not
    // the one the language and territory imply ("sr_Latn_RS", but "fr_CH").
    const QLocale ui;
    QList<QLocale> found;
    QStringList names;
    for (const QLocale &l : QLocale::matchingLocales(ui.language(), QLocale::AnyScript, QLocale::AnyTerritory)) {
        if (l.territory() == QLocale::AnyTerritory)
            continue;
        const QString base = QLocale::languageToCode(l.language()) + QLatin1Char('_') + QLocale::territoryToCode(l.territory());
        const QString name = QLocale(base).script() == l.script() ? base
            : QLocale::languageToCode(l.language()) + QLatin1Char('_') + QLocale::scriptToCode(l.script()) + QLatin1Char('_') + QLocale::territoryToCode(l.territory());
        if (names.contains(name))
            continue;
        names << name;
        found << l;
    }
    QCollator collator(ui);
    QList<int> order(found.size());
    std::iota(order.begin(), order.end(), 0);
    std::sort(order.begin(), order.end(), [&](int a, int b) { return collator.compare(found[a].nativeTerritoryName(), found[b].nativeTerritoryName()) < 0; });
    QVariantList out;
    for (int i : order)
        out << QVariantMap{{"name", names[i]}, {"territory", found[i].nativeTerritoryName()}};
    return out;
}

bool Backend::omarchyLanguage() const
{
    return !QStandardPaths::findExecutable(QStringLiteral("omarchy-language")).isEmpty();
}

QString Backend::autostartDir() const
{
    const QString config = grassfield::settings::xdgHome(qEnvironmentVariable("XDG_CONFIG_HOME"), QDir::homePath() + QStringLiteral("/.config"));
    return QDir::cleanPath(config + QStringLiteral("/autostart"));
}

QStringList Backend::systemAutostartDirs() const
{
    // $XDG_CONFIG_DIRS (default /etc/xdg), each with autostart/ (the XDG Autostart specification).
    QStringList out;
    for (const QString &d : grassfield::settings::xdgDirs(qEnvironmentVariable("XDG_CONFIG_DIRS"), QStringLiteral("/etc/xdg")))
        out << QDir::cleanPath(d + QStringLiteral("/autostart"));
    return out;
}

QString Backend::xdgConfigDir() const
{
    return QDir::cleanPath(grassfield::settings::xdgHome(qEnvironmentVariable("XDG_CONFIG_HOME"), QDir::homePath() + QStringLiteral("/.config")));
}

QString Backend::grassfieldStateDir() const
{
    return QDir::cleanPath(grassfield::apps::runmode::stateDir());
}

QStringList Backend::applicationDirs() const
{
    // The XDG Base Directory folders of the desktop entries: $XDG_DATA_HOME (default ~/.local/share) first, then $XDG_DATA_DIRS
    // (default /usr/local/share:/usr/share), each with applications/.
    using namespace grassfield::settings;
    const QString home = xdgHome(qEnvironmentVariable("XDG_DATA_HOME"), QDir::homePath() + QStringLiteral("/.local/share"));
    QStringList out;
    for (const QString &d : QStringList{home} + xdgDirs(qEnvironmentVariable("XDG_DATA_DIRS"), QStringLiteral("/usr/local/share:/usr/share"))) {
        const QString dir = QDir::cleanPath(d + QStringLiteral("/applications"));
        if (!out.contains(dir))
            out << dir;
    }
    return out;
}

QStringList Backend::currentDesktops() const
{
    return qEnvironmentVariable("XDG_CURRENT_DESKTOP").split(QLatin1Char(':'), Qt::SkipEmptyParts);
}

QStringList Backend::desktopEntries(const QString &dir) const
{
    // The .desktop files of one folder (no recursion, regular files only), sorted.
    QDir d(dir);
    if (!dir.startsWith(QLatin1Char('/')) || !d.exists())
        return {};
    return d.entryList({QStringLiteral("*.desktop")}, QDir::Files | QDir::Readable, QDir::Name);
}

bool Backend::autostartWriteAllowed(const QString &path) const
{
    // systemguard.h: a plain <name>.desktop of the user's autostart folder, never a symlink, under <worktree>/.dev in a dev
    // session (the isolated XDG_CONFIG_HOME of isolated.sh).
    return grassfield::settings::isAutostartWrite(path, autostartDir(), m_devRoot, m_dev);
}

QString Backend::writeAutostart(const QString &path, const QString &text) const
{
    if (!autostartWriteAllowed(path))
        return QStringLiteral("refused"); // i18n-ignore: a reason the page maps to its own sentence
    return writeText(path, text);
}

QString Backend::writeDefaultAppsFile(const QString &path, const QString &text) const
{
    if (!grassfield::settings::isDefaultAppsWrite(path, xdgConfigDir(), grassfieldStateDir(), m_devRoot, m_dev))
        return QStringLiteral("refused"); // i18n-ignore: a reason the page maps to its own sentence
    return writeText(path, text);
}

QString Backend::removeAutostart(const QString &path) const
{
    if (!autostartWriteAllowed(path))
        return QStringLiteral("refused"); // i18n-ignore: a reason the page maps to its own sentence
    QFile f(path);
    if (!f.exists())
        return QString();
    return f.remove() ? QString() : f.errorString();
}

QString Backend::qtVersion() const
{
    return QString::fromLatin1(qVersion());
}

QString Backend::appVersion() const
{
    return QCoreApplication::applicationVersion();
}

QVariantMap Backend::readText(const QString &path) const
{
    QVariantMap out{{"exists", false}, {"ok", false}, {"text", QString()}};
    QFile f(path);
    if (!f.exists())
        return out;
    out["exists"] = true;
    if (!f.open(QIODevice::ReadOnly))
        return out;
    // Strictly UTF-8: a file in another encoding is not read and rewritten as replacement characters (ok stays false).
    QStringDecoder utf8(QStringDecoder::Utf8, QStringConverter::Flag::Stateless);
    const QString text = utf8(f.read(kMaxRead));
    if (utf8.hasError())
        return out;
    out["text"] = text;
    out["ok"] = true;
    return out;
}

QString Backend::writeText(const QString &path, const QString &text) const
{
    if (!QDir().mkpath(QFileInfo(path).absolutePath()))
        return QCoreApplication::translate("SystemBus", "cannot create the directory of %1").arg(path);
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly))
        return f.errorString();
    f.write(text.toUtf8());
    if (!f.commit())
        return f.errorString();
    return QString();
}

namespace {
// An absolute directory from the environment, cleaned; "" otherwise.
QString envDir(const char *name)
{
    const QString v = qEnvironmentVariable(name);
    return v.startsWith(QLatin1Char('/')) ? QDir::cleanPath(v) : QString();
}

constexpr int kMaxDisplayLines = 16;
constexpr qint64 kMaxTrialSeconds = 60;
} // namespace

QString Backend::softwareUpdateRunFile() const
{
    const QString run = envDir("XDG_RUNTIME_DIR");
    return run.isEmpty() ? QString() : run + QStringLiteral("/grassfield/software-update-run.json");
}

QString Backend::displaysStateFile() const
{
    if (m_dev) {
        const QString state = envDir("GRASSFIELD_STATE_HOME");
        return state.isEmpty() ? QString() : state + QStringLiteral("/displays.json");
    }
    const QString run = envDir("XDG_RUNTIME_DIR");
    return run.isEmpty() ? QString() : run + QStringLiteral("/grassfield-displays.json");
}

QString Backend::displaysConfFile() const
{
    if (m_dev) {
        const QString config = envDir("GRASSFIELD_CONFIG_HOME");
        return config.isEmpty() ? QString() : config + QStringLiteral("/displays.conf");
    }
    return QFileInfo(m_configFile).absolutePath() + QStringLiteral("/displays.conf");
}

QString Backend::displayTrialFile() const
{
    if (m_dev) {
        const QString state = envDir("GRASSFIELD_STATE_HOME");
        return state.isEmpty() ? QString() : state + QStringLiteral("/display-trial.conf");
    }
    const QString run = envDir("XDG_RUNTIME_DIR");
    return run.isEmpty() ? QString() : run + QStringLiteral("/grassfield-display-trial.conf");
}

QString Backend::displayLinesProblem(const QStringList &lines) const
{
    if (lines.size() > kMaxDisplayLines)
        return QCoreApplication::translate("SystemBus", "too many displays");
    QSet<QString> seen;
    for (const QString &line : lines) {
        if (!grassfield::settings::isDisplayLine(line))
            return QCoreApplication::translate("SystemBus", "a display line is not well formed");
        const QString desc = line.section(QLatin1Char('\t'), 1, 1);
        if (seen.contains(desc))
            return QCoreApplication::translate("SystemBus", "a display appears twice");
        seen.insert(desc);
    }
    return QString();
}

QStringList Backend::displaysConf() const
{
    const QString path = displaysConfFile();
    QStringList out;
    if (path.isEmpty())
        return out;
    const QVariantMap r = readText(path);
    for (const QString &line : r.value(QStringLiteral("text")).toString().split(QLatin1Char('\n'))) {
        if (grassfield::settings::isDisplayLine(line) && out.size() < kMaxDisplayLines)
            out.append(line);
    }
    return out;
}

QString Backend::writeDisplaysConf(const QStringList &lines) const
{
    const QString path = displaysConfFile();
    if (path.isEmpty())
        return QCoreApplication::translate("SystemBus", "no folder for the display settings in this session");
    const QString problem = displayLinesProblem(lines);
    if (!problem.isEmpty())
        return problem;
    const QString head = QStringLiteral("# Grassfield displays (Settings > Displays, ADR-0031): one display per line.\n"); // i18n-ignore: a file comment
    return writeText(path, head + lines.join(QLatin1Char('\n')) + (lines.isEmpty() ? QString() : QStringLiteral("\n")));
}

QString Backend::writeDisplayTrial(const QString &id, qint64 until, const QStringList &lines) const
{
    const QString path = displayTrialFile();
    if (path.isEmpty())
        return QCoreApplication::translate("SystemBus", "no folder for a display trial in this session");
    const qint64 now = QDateTime::currentSecsSinceEpoch();
    if (!grassfield::settings::isDisplayTrialId(id) || until <= now || until > now + kMaxTrialSeconds)
        return QCoreApplication::translate("SystemBus", "the trial is not well formed");
    const QString problem = displayLinesProblem(lines);
    if (!problem.isEmpty())
        return problem;
    return writeText(path, QStringLiteral("trial %1 until %2\n").arg(id).arg(until) + lines.join(QLatin1Char('\n'))
                               + (lines.isEmpty() ? QString() : QStringLiteral("\n")));
}

QString Backend::markDisplayTrial(const QString &state, const QString &id) const
{
    const QString path = displayTrialFile();
    if (path.isEmpty())
        return QCoreApplication::translate("SystemBus", "no folder for a display trial in this session");
    if ((state != QLatin1String("kept") && state != QLatin1String("revert")) || !grassfield::settings::isDisplayTrialId(id))
        return QCoreApplication::translate("SystemBus", "the trial is not well formed");
    return writeText(path, state + QLatin1Char(' ') + id + QLatin1Char('\n'));
}

QString Backend::run(const QStringList &argv) const
{
    // Same allow-list as query(), in every session: nothing else runs through this door.
    const bool helper = !argv.isEmpty() && grassfield::settings::namesWallpaperTool(argv.first());
    if (argv.isEmpty() || !(helper ? wallpaperAllowed(argv) : grassfield::settings::isReadOnlyQuery(argv))) {
        if (!argv.isEmpty())
            qWarning().noquote() << "refused run() of a command that is not a read-only query:" << argv.first();
        return QString();
    }
    QProcess p;
    p.setProcessEnvironment(cLocaleEnvironment());
    p.start(argv.first(), argv.mid(1), QIODevice::ReadOnly);
    if (!p.waitForFinished(kRunTimeoutMs) || p.exitStatus() != QProcess::NormalExit || p.exitCode() != 0) {
        // Never destroy a running QProcess: terminate, then kill, each with a bounded wait.
        if (p.state() != QProcess::NotRunning) {
            p.terminate();
            if (!p.waitForFinished(500)) {
                p.kill();
                p.waitForFinished(1000);
            }
        }
        return QString();
    }
    return QString::fromUtf8(p.readAllStandardOutput());
}

bool Backend::watch(const QString &path)
{
    // The file is replaced by rename on every atomic write, so its directory is watched too.
    const QString dir = QFileInfo(path).absolutePath();
    m_watched.append(path);
    QDir().mkpath(dir);
    m_watcher.addPath(dir);
    if (QFile::exists(path))
        m_watcher.addPath(path);
    return true;
}

void Backend::onPath(const QString &path)
{
    for (const QString &w : std::as_const(m_watched)) {
        // After a rename the old inode is gone from the watcher: add the new file.
        if (QFile::exists(w) && !m_watcher.files().contains(w))
            m_watcher.addPath(w);
        if (path == w || path == QFileInfo(w).absolutePath())
            emit fileChanged(w);
    }
}
