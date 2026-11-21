#include "operations.h"

#include "childprocess.h"
#include "flatpak.h"
#include "statefile.h"

#include <QDeadlineTimer>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QThreadPool>

#include "storeview.h"

#include <csignal>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <unistd.h>

namespace grassfield::store {

namespace {

constexpr qint64 kMaxDetails = 64 * 1024;
const QString kOperationKey = QStringLiteral("operation");

QByteArray readTail(const QString &path, qint64 max)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return {};
    if (f.size() > max)
        f.seek(f.size() - max);
    return f.read(max);
}

bool isName(const QString &name)
{
    static const QRegularExpression re(QStringLiteral(R"(\A[a-z0-9@_+][a-z0-9@._+-]{0,127}\z)"));
    return re.match(name).hasMatch();
}

// The web app launchers of `dir` whose Exec is `omarchy-launch-webapp <url>` (storeview.h's reading), by file name.
QHash<QString, QString> webAppUrls(const QString &dir)
{
    QHash<QString, QString> out;
    QDirIterator it(dir, {QStringLiteral("*.desktop")}, QDir::Files);
    int seen = 0;
    while (it.hasNext() && seen++ < 2000) {
        const QString path = it.next();
        QFile f(path);
        if (!f.open(QIODevice::ReadOnly) || f.size() > 64 * 1024)
            continue;
        if (const auto entry = view::parseWebAppEntry(f.readAll()))
            out.insert(QFileInfo(path).completeBaseName(), entry->url);
    }
    return out;
}

} // namespace

QJsonObject OperationRecord::toJson() const
{
    QJsonArray planned;
    for (const PlannedPackage &p : plan)
        planned.append(QJsonObject{{QStringLiteral("name"), p.name}, {QStringLiteral("version"), p.version}});
    return {{QStringLiteral("id"), id},
            {QStringLiteral("kind"), kind},
            {QStringLiteral("path"), path},
            {QStringLiteral("app"), app},
            {QStringLiteral("name"), name},
            {QStringLiteral("packages"), QJsonArray::fromStringList(packages)},
            {QStringLiteral("plan"), planned},
            {QStringLiteral("recipe"), recipe},
            {QStringLiteral("args"), QJsonArray::fromStringList(args)},
            {QStringLiteral("webName"), webName},
            {QStringLiteral("webUrl"), webUrl},
            {QStringLiteral("flatpak"), flatpak},
            {QStringLiteral("commits"), QJsonArray::fromStringList(commits)},
            {QStringLiteral("fromCommits"), QJsonArray::fromStringList(fromCommits)},
            {QStringLiteral("startedAt"), startedAt.toUTC().toString(Qt::ISODate)}};
}

std::optional<OperationRecord> OperationRecord::fromJson(const QJsonObject &o)
{
    OperationRecord r;
    r.id = o.value(QStringLiteral("id")).toString();
    r.kind = o.value(QStringLiteral("kind")).toString();
    r.path = o.value(QStringLiteral("path")).toString();
    r.app = o.value(QStringLiteral("app")).toString().left(255);
    r.name = o.value(QStringLiteral("name")).toString().left(80);
    for (const QJsonValue &v : o.value(QStringLiteral("packages")).toArray())
        r.packages.append(v.toString());
    for (const QJsonValue &v : o.value(QStringLiteral("plan")).toArray()) {
        PlannedPackage p;
        p.name = v.toObject().value(QStringLiteral("name")).toString();
        p.version = v.toObject().value(QStringLiteral("version")).toString().left(128);
        // A Flatpak's plan names refs' ids (org.gnome.Platform), the others packages.
        if (!(r.path == QLatin1String("flatpak") ? isFlatpakId(p.name) : isName(p.name)))
            return std::nullopt;
        r.plan.append(p);
    }
    r.recipe = o.value(QStringLiteral("recipe")).toString();
    for (const QJsonValue &v : o.value(QStringLiteral("args")).toArray())
        r.args.append(v.toString());
    r.webName = o.value(QStringLiteral("webName")).toString();
    r.webUrl = o.value(QStringLiteral("webUrl")).toString();
    r.flatpak = o.value(QStringLiteral("flatpak")).toString();
    for (const QJsonValue &v : o.value(QStringLiteral("commits")).toArray())
        r.commits.append(v.toString());
    for (const QJsonValue &v : o.value(QStringLiteral("fromCommits")).toArray())
        r.fromCommits.append(v.toString());
    r.startedAt = QDateTime::fromString(o.value(QStringLiteral("startedAt")).toString(), Qt::ISODate);
    const bool update = r.kind == QLatin1String("update");
    const bool kindOk = r.kind == QLatin1String("install") || r.kind == QLatin1String("remove") || (update && r.path == QLatin1String("flatpak"));
    const bool namesOk = !r.packages.isEmpty() && r.packages.size() <= 64 && std::all_of(r.packages.cbegin(), r.packages.cend(), isName);
    const bool helperOk = r.path == QLatin1String("helper") && namesOk;
    // A setup's recipe of the operation's own kind (e.5), or the AUR's command of that kind with the package names (b.2).
    const bool install = r.kind == QLatin1String("install");
    const bool setupOk = isRecipe(r.recipe) && isRecipeArgs(r.args)
        && r.recipe.startsWith(install ? QLatin1String("omarchy-install-") : QLatin1String("omarchy-remove-"));
    const bool aurOk = r.recipe == (install ? kAurAdd : kAurDrop) && isAurNames(r.args);
    // Get Flatpak… (SD24): omarchy-pkg-add flatpak, an install of the flatpak package and nothing else.
    const bool flatpakGetOk = install && r.recipe == kFlatpakAdd && r.args == QStringList{kFlatpakPackage}
        && r.packages == QStringList{kFlatpakPackage};
    const bool terminalOk = r.path == QLatin1String("terminal") && namesOk && (setupOk || aurOk || flatpakGetOk);
    const bool webOk = r.path == QLatin1String("webapp") && isWebAppName(r.webName);
    // An install takes Flathub's ref, a removal the app id (b.3); an update its refs (step 4: as many as a check lists),
    // with its app's alone when it updates one app, and a commit (or "") for each, a pinned one only on an app's ref.
    const bool refsOk = !r.packages.isEmpty() && r.packages.size() <= kMaxFlatpakUpdates
        && std::all_of(r.packages.cbegin(), r.packages.cend(), isFlatpakRef) && r.commits.size() == r.packages.size();
    // Each pinned ref's installed commit at plan time, when read ("" else); none without a pin. An older record has none.
    bool commitsOk = refsOk && (r.fromCommits.isEmpty() || r.fromCommits.size() == r.packages.size());
    for (qsizetype i = 0; commitsOk && i < r.commits.size(); ++i) {
        const QString from = r.fromCommits.value(i);
        commitsOk = (r.commits.at(i).isEmpty() || (isFlatpakCommit(r.commits.at(i)) && isFlatpakAppRef(r.packages.at(i))))
            && (from.isEmpty() || (isFlatpakCommit(from) && !r.commits.at(i).isEmpty()));
    }
    if (!update && (!r.commits.isEmpty() || !r.fromCommits.isEmpty()))
        return std::nullopt;
    const bool flatpakOk = r.path == QLatin1String("flatpak")
        && (update ? commitsOk && (r.flatpak.isEmpty() || (isFlatpakAppRef(r.flatpak) && r.packages == QStringList{r.flatpak}))
            : install ? isFlatpakAppRef(r.flatpak)
                      : isFlatpakId(r.flatpak));
    if (!isOperationId(r.id) || !kindOk || !(helperOk || terminalOk || webOk || flatpakOk))
        return std::nullopt;
    return r;
}

QList<QStringList> flatpakUpdateCommands(const OperationRecord &record)
{
    const QStringList base{QStringLiteral("update"), QStringLiteral("--user"), QStringLiteral("--noninteractive")};
    QList<QStringList> out;
    QStringList rest;
    for (qsizetype i = 0; i < record.packages.size(); ++i) {
        const QString commit = record.commits.value(i);
        if (commit.isEmpty())
            rest.append(record.packages.at(i));
        else
            out.append(base + QStringList{QStringLiteral("--commit=") + commit, QStringLiteral("--"), record.packages.at(i)});
    }
    // The rest after the pinned apps: a runtime an app's update already brought is "Nothing to update." (S31c, exit 0).
    if (!rest.isEmpty())
        out.append(base + QStringList{QStringLiteral("--")} + rest);
    return out;
}

QList<std::pair<QString, QString>> flatpakUpdateGuards(const OperationRecord &record)
{
    // The pinned commands come first, in the refs' order (flatpakUpdateCommands), then at most one for the rest.
    QList<std::pair<QString, QString>> out;
    bool rest = false;
    for (qsizetype i = 0; i < record.packages.size(); ++i) {
        if (record.commits.value(i).isEmpty())
            rest = true;
        else
            out.append({record.packages.at(i), record.fromCommits.value(i)});
    }
    if (rest)
        out.append({QString(), QString()});
    return out;
}

QString newOperationId()
{
    quint32 words[4];
    QRandomGenerator::system()->fillRange(words);
    QString id;
    for (quint32 w : words)
        id += QStringLiteral("%1").arg(w, 8, 16, QLatin1Char('0'));
    return id;
}

bool isOperationId(const QString &id)
{
    static const QRegularExpression re(QStringLiteral(R"(\A[0-9a-f]{32}\z)"));
    return re.match(id).hasMatch();
}

bool isAurNames(const QStringList &names)
{
    return !names.isEmpty() && names.size() <= 4 && std::all_of(names.cbegin(), names.cend(), [](const QString &n) { return isName(n); });
}

QString terminalKind(const QString &recipe, const QStringList &args)
{
    if (isRecipe(recipe) && isRecipeArgs(args))
        return QStringLiteral("setup");
    if ((recipe == kAurAdd || recipe == kAurDrop) && isAurNames(args))
        return QStringLiteral("aur");
    if (recipe == kFlatpakAdd && args == QStringList{kFlatpakPackage})
        return QStringLiteral("flatpak");
    return {};
}

bool isRecipe(const QString &recipe)
{
    static const QRegularExpression re(QStringLiteral(R"(\Aomarchy-(install|remove)-[a-z0-9-]+\z)"));
    return recipe.size() <= 128 && re.match(recipe).hasMatch();
}

bool isRecipeArgs(const QStringList &args)
{
    static const QRegularExpression re(QStringLiteral(R"(\A[a-z0-9][a-z0-9.-]{0,63}\z)"));
    return args.size() <= 4 && std::all_of(args.cbegin(), args.cend(), [](const QString &a) { return re.match(a).hasMatch(); });
}

QString terminalCommand(const QString &run, const QString &id, qint64 deadline, const QString &recipe, const QStringList &args)
{
    // The launcher runs it with `bash -c`: every token is one of e.5's patterns, none of them holds a character the shell
    // reads (the script checks them again).
    static const QRegularExpression path(QStringLiteral(R"(\A(/[a-z0-9._-]+)+\z)"));
    const QString kind = terminalKind(recipe, args);
    if (!path.match(run).hasMatch() || !isOperationId(id) || deadline <= 0 || kind.isEmpty())
        return {};
    return (QStringList{run, id, QString::number(deadline), kind, recipe} + args).join(QLatin1Char(' '));
}

std::optional<int> helperExitCode(const QString &statusDir, const QString &id)
{
    if (!isOperationId(id))
        return std::nullopt;
    QFile f(statusDir + QLatin1Char('/') + id + QStringLiteral(".exit"));
    if (!f.open(QIODevice::ReadOnly))
        return std::nullopt;
    bool ok = false;
    const int code = f.read(16).trimmed().toInt(&ok);
    return ok && code >= 0 && code <= 255 ? std::optional<int>(code) : std::nullopt;
}

bool helperRunning(const QString &statusDir, const QString &id)
{
    if (!isOperationId(id))
        return false;
    QFile f(statusDir + QLatin1Char('/') + id + QStringLiteral(".started"));
    if (!f.open(QIODevice::ReadOnly))
        return false;
    const QList<QByteArray> fields = f.read(64).trimmed().split(' ');
    if (fields.size() != 2)
        return false;
    bool ok = false;
    const qint64 pid = fields.at(0).toLongLong(&ok);
    if (!ok || pid <= 1)
        return false;
    QFile stat(QStringLiteral("/proc/%1/stat").arg(pid));
    if (!stat.open(QIODevice::ReadOnly))
        return false;
    const QByteArray line = stat.read(4096);
    const int close = line.lastIndexOf(") ");
    if (close < 0)
        return false;
    const QList<QByteArray> rest = line.mid(close + 2).split(' ');
    // Field 3 (state) is rest[0], so field 22 (the start time) is rest[19].
    return rest.size() > 19 && rest.at(19) == fields.at(1);
}

int countLogged(const QByteArray &logTail, const QString &verb, const QStringList &names)
{
    const QByteArray marker = "[ALPM] " + verb.toLatin1() + ' ';
    int count = 0;
    for (const QByteArray &line : logTail.split('\n')) {
        const int at = line.indexOf(marker);
        if (at < 0)
            continue;
        const QByteArray rest = line.mid(at + marker.size());
        const int space = rest.indexOf(' ');
        if (space > 0 && names.contains(QString::fromUtf8(rest.left(space))))
            ++count;
    }
    return count;
}

Outcome judge(std::optional<int> exitCode, int present, int total)
{
    if (exitCode && *exitCode == 0 && present == total)
        return Outcome::Done;
    return present > 0 ? Outcome::Interrupted : Outcome::NotFinished;
}

Operations::Operations(const OperationsConfig &config, QObject *parent)
    : QObject(parent)
    , m_config(config)
{
    m_poll.setInterval(m_config.pollMs);
    connect(&m_poll, &QTimer::timeout, this, &Operations::poll);
    m_retry.setSingleShot(true);
    m_retry.setInterval(2000);
    connect(&m_retry, &QTimer::timeout, this, &Operations::startNext);
    m_writer.setMaxThreadCount(1);
    m_pool.setMaxThreadCount(2);
}

bool Operations::drain(int ms)
{
    QDeadlineTimer deadline(ms);
    const bool written = m_writer.waitForDone(int(qMax<qint64>(0, deadline.remainingTime())));
    return m_pool.waitForDone(int(qMax<qint64>(0, deadline.remainingTime()))) && written;
}

Operations::~Operations()
{
    // A running pkexec or helper is left to finish (it ends in pacman); QProcess would kill what it still owns.
    if (m_process) {
        m_process->disconnect(this);
        m_process->setParent(nullptr);
        m_process.clear();
    }
    releaseUpdateLock();
}

void Operations::enqueue(const OperationRecord &record)
{
    Item item;
    item.record = record;
    m_results.remove(record.app);
    m_queue.append(item);
    emit changed();
    startNext();
}

bool Operations::removeWaiting(const QString &id)
{
    for (qsizetype i = 0; i < m_queue.size(); ++i) {
        if (m_queue.at(i).record.id == id) {
            m_queue.removeAt(i);
            emit changed();
            return true;
        }
    }
    return false;
}

void Operations::dismiss(const QString &app)
{
    if (m_results.remove(app))
        emit changed();
}

namespace {
// What the user may stop (SD26, SU-09): a Flatpak's install or update while it runs; never a removal (it ends on its own, or
// at the idle limit), never pacman's or Omarchy's paths.
bool stoppable(const OperationRecord &r)
{
    return r.path == QLatin1String("flatpak") && (r.kind == QLatin1String("install") || r.kind == QLatin1String("update"));
}
} // namespace

bool Operations::stop(const QString &id)
{
    if (!m_current || m_current->record.id != id || !stoppable(m_current->record) || m_current->state != State::Running || !m_process
        || m_stopping)
        return false;
    m_stopping = true;
    // An update's commands still to run do not run.
    m_flatpakSteps.clear();
    m_flatpakGuards.clear();
    // SIGTERM: flatpak ends at once; what it finished stays, what it was downloading waits in its own folder for the next
    // install, which takes it up (S25, store_flatpak.sh).
    m_process->terminate();
    emit changed();
    return true;
}

bool Operations::queued(const QString &app) const
{
    if (m_current && m_current->record.app == app)
        return true;
    return std::any_of(m_queue.cbegin(), m_queue.cend(), [&app](const Item &i) { return i.record.app == app; });
}

QList<Operations::Item> Operations::items() const
{
    QList<Item> out;
    if (m_current)
        out.append(*m_current);
    out.append(m_queue);
    return out;
}

QVariantList Operations::list() const
{
    QVariantList out;
    for (const Item &i : items()) {
        static const char *states[] = {"waiting", "authorizing", "opening", "running", "checking"};
        out.append(QVariantMap{{QStringLiteral("id"), i.record.id},
                               {QStringLiteral("app"), i.record.app},
                               {QStringLiteral("name"), i.record.name},
                               {QStringLiteral("kind"), i.record.kind},
                               {QStringLiteral("path"), i.record.path},
                               {QStringLiteral("state"), QString::fromLatin1(states[int(i.state)])},
                               {QStringLiteral("blocked"), i.blocked},
                               {QStringLiteral("done"), i.done},
                               {QStringLiteral("total"), int(i.record.kind == QLatin1String("update") ? i.record.packages.size() : i.record.plan.size())},
                               {QStringLiteral("stoppable"), stoppable(i.record) && i.state == State::Running && !m_stopping
                                                                 && m_current && i.record.id == m_current->record.id && m_process}});
    }
    return out;
}

bool Operations::takeUpdateLock()
{
    if (m_lockFd >= 0)
        return true;
    // Omarchy's update lock (omarchy-update-lock: the same file): close-on-exec, so pkexec and pacman never hold it.
    const int fd = ::open(QFile::encodeName(m_config.updateLock).constData(), O_WRONLY | O_CREAT | O_CLOEXEC | O_NOCTTY, 0600);
    if (fd < 0)
        return false;
    if (::flock(fd, LOCK_EX | LOCK_NB) != 0) {
        ::close(fd);
        return false;
    }
    m_lockFd = fd;
    return true;
}

void Operations::releaseUpdateLock()
{
    if (m_lockFd >= 0) {
        ::close(m_lockFd);
        m_lockFd = -1;
    }
}

void Operations::writeRecord(const OperationRecord &record, std::function<void()> then)
{
    const QString file = m_config.stateFile;
    const QJsonObject json = record.toJson();
    m_writer.start([this, file, json, then] {
        updateStoreState(file, [&json](QJsonObject &state) { state.insert(kOperationKey, json); });
        if (then)
            QMetaObject::invokeMethod(&m_context, then, Qt::QueuedConnection);
    });
}

void Operations::clearRecord()
{
    const QString file = m_config.stateFile;
    m_writer.start([file] { updateStoreState(file, [](QJsonObject &state) { state.remove(kOperationKey); }); });
}

void Operations::startNext()
{
    if (m_current || m_queue.isEmpty())
        return;
    Item &next = m_queue.first();
    // Only when pacman is not running and Omarchy's update lock is free: taken here for the helper (held until it ends);
    // for the terminal, grassfield-store-run takes it (b.2), so the Store only reads it.
    const bool helper = next.record.path == QLatin1String("helper");
    const bool terminal = next.record.path == QLatin1String("terminal");
    if ((helper || terminal) && (QFileInfo::exists(m_config.dbLock) || (helper ? !takeUpdateLock() : lockHeld(m_config.updateLock)))) {
        if (!next.blocked) {
            next.blocked = true;
            emit changed();
        }
        m_retry.start();
        return;
    }
    m_current = m_queue.takeFirst();
    m_current->blocked = false;
    m_current->record.startedAt = QDateTime::currentDateTimeUtc();
    m_output.clear();
    m_followOnly = false;
    m_stopping = false;
    m_firstExit.reset();
    m_flatpakOutput.clear();
    m_flatpakSteps.clear();
    m_flatpakGuards.clear();
    m_idleStopped = false;
    // The record first, on the writer's thread (off the click path); the operation starts once it is on disk.
    m_current->state = helper ? State::Authorizing : terminal ? State::Opening : State::Running;
    const QString id = m_current->record.id;
    writeRecord(m_current->record, [this, id] {
        if (m_current && m_current->record.id == id && !m_concluding)
            begin();
    });
    emit changed();
}

void Operations::begin()
{
    const bool helper = m_current->record.path == QLatin1String("helper");
    const bool terminal = m_current->record.path == QLatin1String("terminal");
    if (helper) {
        startHelper(*m_current);
    } else if (terminal) {
        startTerminal(*m_current);
    } else if (m_current->record.path == QLatin1String("flatpak")) {
        m_current->state = State::Running;
        const OperationRecord &r = m_current->record;
        if (r.kind == QLatin1String("update")) {
            // Its refs only (S31b: an app's runtime comes with it when the app needs the newer one), each pinned app on its
            // own (S32), one command after the other.
            m_flatpakSteps = flatpakUpdateCommands(r);
            m_flatpakGuards = flatpakUpdateGuards(r);
            startUpdateStep();
        } else {
            startFlatpak(r.kind == QLatin1String("install")
                             ? QStringList{QStringLiteral("install"), QStringLiteral("--user"), QStringLiteral("--noninteractive"), kFlathubRemote, r.flatpak}
                             : QStringList{QStringLiteral("uninstall"), QStringLiteral("--user"), QStringLiteral("--noninteractive"), QStringLiteral("--"), r.flatpak});
        }
    } else {
        startWebApp(*m_current);
    }
    emit changed();
}

void Operations::startHelper(Item &item)
{
    item.state = State::Authorizing;
    m_logOffset = QFileInfo(m_config.pacmanLog).size();
    auto *p = new QProcess(this);
    m_process = p;
    p->setProgram(m_config.pkexec);
    p->setArguments(QStringList{m_config.helper, item.record.kind, item.record.id} + item.record.packages);
    p->setStandardInputFile(QProcess::nullDevice());
    p->setStandardOutputFile(QProcess::nullDevice());
    // A session of its own: a terminal the Store was started from never sends pacman a signal (S6).
    p->setChildProcessModifier([] { ::setsid(); });
    connect(p, &QProcess::readyReadStandardError, this, [this, p] {
        const QByteArray err = p->readAllStandardError();
        if (m_output.size() < kMaxDetails)
            m_output += err.left(kMaxDetails - m_output.size());
    });
    connect(p, &QProcess::finished, this, &Operations::processEnded);
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart && m_process == p)
            conclude(std::nullopt, QStringLiteral("%1: %2").arg(m_config.pkexec, p->errorString()));
    });
    m_runningSince = QDateTime();
    p->start();
    m_poll.start();
}

void Operations::startWebApp(Item &item)
{
    item.state = State::Running;
    const OperationRecord &r = item.record;
    const QStringList argv = r.kind == QLatin1String("install")
        ? m_config.omarchy(QStringLiteral("omarchy-webapp-install"), {r.webName, r.webUrl, r.webIcon})
        : m_config.omarchy(QStringLiteral("omarchy-webapp-remove"), {r.webName});
    auto *p = new QProcess(this);
    m_process = p;
    p->setProgram(argv.value(0));
    p->setArguments(argv.mid(1));
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("OMARCHY_REMOVE_NOTIFY"), QStringLiteral("false")); // no notification of its own
    p->setProcessEnvironment(env);
    p->setStandardInputFile(QProcess::nullDevice());
    p->setProcessChannelMode(QProcess::MergedChannels);
    p->setChildProcessModifier([] { ::setpgid(0, 0); });
    connect(p, &QProcess::readyReadStandardOutput, this, [this, p] {
        const QByteArray out = p->readAllStandardOutput();
        if (m_output.size() < kMaxDetails)
            m_output += out.left(kMaxDetails - m_output.size());
    });
    connect(p, &QProcess::finished, this, &Operations::processEnded);
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart && m_process == p)
            conclude(std::nullopt, p->errorString());
    });
    m_runningSince = QDateTime::currentDateTimeUtc();
    p->start();
    m_poll.start();
}

void Operations::startFlatpak(const QStringList &args)
{
    if (m_config.flatpak.isEmpty()) {
        conclude(std::nullopt, QStringLiteral("flatpak is not there"));
        return;
    }
    auto *p = new QProcess(this);
    m_process = p;
    p->setProgram(m_config.flatpak);
    p->setArguments(args);
    QProcessEnvironment env;
    env.insert(QStringLiteral("PATH"), QStringLiteral("/usr/bin:/bin"));
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C"));
    for (const QString &key : m_config.flatpakEnv.keys())
        env.insert(key, m_config.flatpakEnv.value(key));
    p->setProcessEnvironment(env);
    p->setStandardInputFile(QProcess::nullDevice());
    p->setProcessChannelMode(QProcess::MergedChannels);
    // Its own group (no terminal's signal reaches it), and it stops with the Store: SIGTERM, which flatpak handles cleanly
    // (S25), where the SIGKILL QProcess would send leaves a staging folder.
    p->setChildProcessModifier([] {
        ::setpgid(0, 0);
        ::prctl(PR_SET_PDEATHSIG, SIGTERM);
    });
    const bool install = m_current && m_current->record.kind != QLatin1String("remove"); // "Installing" or "Updating" lines
    connect(p, &QProcess::readyReadStandardOutput, this, [this, p, install] {
        const QByteArray out = p->readAllStandardOutput();
        m_lastOutput = QDateTime::currentDateTimeUtc();
        if (m_output.size() < kMaxDetails)
            m_output += out.left(kMaxDetails - m_output.size());
        if (m_flatpakOutput.size() < 1024 * 1024)
            m_flatpakOutput += out;
        if (m_current && !m_firstExit) {
            const int steps = m_current->record.kind == QLatin1String("update") ? int(m_current->record.packages.size())
                                                                                 : int(m_current->record.plan.size());
            const int done = qMin(flatpakSteps(m_flatpakOutput, install), steps);
            if (done != m_current->done) {
                m_current->done = done;
                emit changed();
            }
        }
    });
    connect(p, &QProcess::finished, this, &Operations::processEnded);
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart && m_process == p)
            conclude(std::nullopt, p->errorString());
    });
    m_runningSince = QDateTime::currentDateTimeUtc();
    m_lastOutput = m_runningSince;
    p->start();
    m_poll.start(); // the idle limit (SU-09)
}

void Operations::startUpdateStep()
{
    if (!m_current || m_flatpakSteps.isEmpty())
        return;
    const QStringList args = m_flatpakSteps.takeFirst();
    const std::pair<QString, QString> guard = m_flatpakGuards.isEmpty() ? std::pair<QString, QString>() : m_flatpakGuards.takeFirst();
    const QString ref = guard.first;
    const QString from = guard.second; // C++17: a structured binding is not captured by a lambda
    if (from.isEmpty()) {
        startFlatpak(args);
        return;
    }
    // Its installed commit first (off the window's thread): another one than its plan read means it was updated outside the
    // Store since (a terminal, another store), and the pinned commit may be older: it is left as it is, never downgraded.
    FlatpakTools tools;
    tools.flatpak = m_config.flatpak;
    tools.env = m_config.flatpakEnv;
    const QString id = m_current->record.id;
    Operations *const self = this; // its pool ends before it is gone; the answer goes to m_context (SU-14)
    m_pool.start([self, tools, args, ref, from, id] {
        const QString installed = flatpakInstalledCommit(tools, ref);
        QMetaObject::invokeMethod(&self->m_context, [self, args, ref, from, id, installed] {
            if (!self->m_current || self->m_current->record.id != id || self->m_stopping)
                return;
            if (installed == from) {
                self->startFlatpak(args);
                return;
            }
            self->m_output += (ref + QStringLiteral(": updated outside the Store since its plan; left as it is.\n")).toUtf8();
            if (!self->m_flatpakSteps.isEmpty())
                self->startUpdateStep();
            else
                self->conclude(0, QString());
        });
    });
}

void Operations::startTerminal(Item &item)
{
    item.state = State::Opening;
    m_logOffset = QFileInfo(m_config.pacmanLog).size();
    m_runningSince = QDateTime();
    const OperationRecord &r = item.record;
    const QString dir = m_config.runDir;
    // Nothing ran: the installation failed (its folder or its pins), or the terminal did not open. Queued: conclude() must
    // not run inside startNext(), which still changes m_current.
    const auto fail = [this](const QString &why, bool launcher) {
        m_output += why.toUtf8();
        QMetaObject::invokeMethod(this, [this, launcher] {
            if (launcher)
                conclude(std::nullopt, QStringLiteral("terminalDidNotOpen"));
            else
                conclude(1, QString());
        }, Qt::QueuedConnection);
    };
    // Its folder: the user's own, 0700, as grassfield-store-run wants it.
    const bool made = !dir.isEmpty() && QDir().mkpath(dir);
    const QFileInfo info(dir);
    if (!made || info.isSymLink() || !info.isDir() || info.ownerId() != ::getuid()
        || !QFile::setPermissions(dir, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner)) {
        fail(QStringLiteral("%1: not a folder of the user's own").arg(dir), false);
        return;
    }
    // The catalog's pins, "<sha256>  <path>" per line (sha256sum's form), written whole then renamed.
    QByteArray pins;
    for (const auto &[path, digest] : r.pins)
        pins += digest.toLatin1() + "  " + QFile::encodeName(path) + '\n';
    const QByteArray temp = QFile::encodeName(dir + QStringLiteral("/.") + r.id + QStringLiteral(".pins"));
    const int fd = ::open(temp.constData(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NOCTTY, 0600);
    const bool written = fd >= 0 && ::write(fd, pins.constData(), size_t(pins.size())) == pins.size();
    if (fd >= 0)
        ::close(fd);
    if (r.pins.isEmpty() || !written || ::rename(temp.constData(), QFile::encodeName(dir + QLatin1Char('/') + r.id + QStringLiteral(".pins")).constData()) != 0) {
        ::unlink(temp.constData());
        fail(QStringLiteral("%1: the pins could not be written").arg(dir), false);
        return;
    }
    // The script refuses to start once this deadline has passed (the terminal opened too late).
    const qint64 deadline = QDateTime::currentSecsSinceEpoch() + qMax(1, m_config.terminalStartMs / 1000);
    const QString command = terminalCommand(m_config.run, r.id, deadline, r.recipe, r.args);
    const QStringList argv = command.isEmpty() ? QStringList()
                                               : m_config.omarchy(QStringLiteral("omarchy-launch-floating-terminal-with-presentation"), {command});
    QProcess launcher;
    launcher.setProgram(argv.value(0));
    launcher.setArguments(argv.mid(1));
    launcher.setStandardInputFile(QProcess::nullDevice());
    launcher.setStandardOutputFile(QProcess::nullDevice());
    launcher.setStandardErrorFile(QProcess::nullDevice());
    if (argv.isEmpty() || !launcher.startDetached()) {
        fail(QStringLiteral("omarchy-launch-floating-terminal-with-presentation did not start"), true);
        return;
    }
    m_poll.start();
}

void Operations::countProgress(Item &item)
{
    const QByteArray tail = [this] {
        QFile f(m_config.pacmanLog);
        if (!f.open(QIODevice::ReadOnly) || f.size() < m_logOffset)
            return QByteArray();
        f.seek(m_logOffset);
        return f.read(8 * 1024 * 1024);
    }();
    QStringList names;
    for (const PlannedPackage &p : item.record.plan)
        names.append(p.name);
    // Never past the plan's count: a name logged twice (a reinstall by a hook, an older line) is still one package.
    const int done = qMin(int(names.size()),
                          countLogged(tail, item.record.kind == QLatin1String("install") ? QStringLiteral("installed") : QStringLiteral("removed"), names));
    if (done != item.done) {
        item.done = done;
        emit changed();
    }
}

void Operations::pollTerminal(Item &item, qint64 elapsed)
{
    const QString dir = m_config.runDir;
    const QString &id = item.record.id;
    if (item.state == State::Opening) {
        // An exit file before the started file: the script refused before running anything (too late, busy).
        if (const auto code = helperExitCode(dir, id)) {
            conclude(code, QString());
            return;
        }
        if (!QFileInfo::exists(dir + QLatin1Char('/') + id + QStringLiteral(".started"))) {
            if (elapsed > qint64(m_config.terminalStartMs) + m_config.terminalGraceMs)
                conclude(std::nullopt, QStringLiteral("terminalDidNotOpen"));
            return;
        }
        item.state = State::Running;
        m_runningSince = QDateTime::currentDateTimeUtc();
        emit changed();
    }
    countProgress(item);
    // Whether it runs first, then its exit file: a script that ended before the first read wrote that file before it ended.
    const bool running = helperRunning(dir, id);
    if (const auto code = helperExitCode(dir, id)) {
        conclude(code, QString());
    } else if (!running) {
        // Gone without an exit file: the terminal was closed.
        conclude(std::nullopt, QString());
    } else if (m_runningSince.isValid() && m_runningSince.msecsTo(QDateTime::currentDateTimeUtc()) > m_config.terminalMs) {
        // Past 3 h: the Store stops waiting and reads the state; it never signals the terminal.
        m_output += "\n(the Store stopped waiting for it)";
        conclude(std::nullopt, QStringLiteral("lostTrack"));
    }
}

void Operations::pruneRunDir(const QString &keep)
{
    const QString dir = m_config.runDir;
    if (dir.isEmpty() || QFileInfo(dir).isSymLink())
        return;
    static const QRegularExpression name(QStringLiteral(R"(\A\.?([0-9a-f]{32})\.(pins|started|exit)\z)"));
    const QDateTime before = QDateTime::currentDateTimeUtc().addMSecs(-(m_config.terminalMs + 3600 * 1000));
    QDirIterator it(dir, QDir::Files | QDir::Hidden | QDir::NoDotAndDotDot);
    while (it.hasNext()) {
        it.next();
        const QRegularExpressionMatch m = name.match(it.fileName());
        if (m.hasMatch() && m.captured(1) != keep && it.fileInfo().lastModified() < before)
            QFile::remove(it.filePath());
    }
}

void Operations::poll()
{
    if (!m_current || m_concluding)
        return;
    Item &item = *m_current;
    const qint64 elapsed = item.record.startedAt.msecsTo(QDateTime::currentDateTimeUtc());
    if (item.record.path == QLatin1String("terminal")) {
        pollTerminal(item, elapsed);
        return;
    }
    if (item.record.path == QLatin1String("flatpak")) {
        // Waited for with no overall limit (b.3, SD26), but not past flatpakIdleMs without a line (SU-09): a stalled
        // network. SIGTERM (flatpak stops cleanly, S25), SIGKILL 10 s later if it is still there.
        if (m_process && !m_idleStopped && m_lastOutput.isValid()
            && m_lastOutput.msecsTo(QDateTime::currentDateTimeUtc()) > m_config.flatpakIdleMs) {
            m_idleStopped = true;
            m_flatpakSteps.clear();
            m_flatpakGuards.clear();
            m_output += "\n(stopped: flatpak printed nothing for a long time)";
            m_process->terminate();
            QTimer::singleShot(10000, this, [p = m_process] {
                if (p && p->state() != QProcess::NotRunning)
                    p->kill();
            });
            emit changed();
        }
        return;
    }
    if (item.record.path == QLatin1String("webapp")) {
        // Past its limit: SIGTERM to its group, SIGKILL 5 s later (it touches only the user's files).
        if (m_process && m_process->processId() > 0 && elapsed > m_config.webAppMs) {
            const pid_t pid = pid_t(m_process->processId());
            ::kill(-pid, SIGTERM);
            QTimer::singleShot(5000, this, [pid, p = m_process] {
                if (p && p->state() != QProcess::NotRunning)
                    ::kill(-pid, SIGKILL);
            });
            m_output += "\n(stopped after its time limit)";
        }
        return;
    }
    const QString dir = m_config.statusDir;
    const bool started = QFileInfo::exists(dir + QLatin1Char('/') + item.record.id + QStringLiteral(".started"));
    if (item.state == State::Authorizing) {
        if (started) {
            item.state = State::Running;
            m_runningSince = QDateTime::currentDateTimeUtc();
            emit changed();
        } else if (!m_followOnly && elapsed > m_config.authorizationMs && m_process && m_process->processId() > 0) {
            // Still waiting for the password: pkexec is the user's process until it starts the helper (a root process
            // then, which no user can signal).
            m_output += "\n(the request for permission timed out)";
            ::kill(pid_t(m_process->processId()), SIGTERM);
            return;
        }
    }
    if (item.state == State::Running) {
        countProgress(item);
        if (m_followOnly) {
            // A helper of an earlier run: it ends with its exit file, written before it ended (read after whether it runs).
            const bool running = helperRunning(dir, item.record.id);
            if (const auto code = helperExitCode(dir, item.record.id))
                conclude(code, QString());
            else if (!running)
                conclude(std::nullopt, QString());
            return;
        }
        if (m_runningSince.isValid() && m_runningSince.msecsTo(QDateTime::currentDateTimeUtc()) > m_config.helperMs) {
            // It still runs, past 2 h: the Store stops waiting and reads the state; it never signals it.
            m_output += "\n(the Store stopped waiting for it)";
            conclude(std::nullopt, QStringLiteral("lostTrack"));
        }
    }
}

void Operations::processEnded(int exitCode, QProcess::ExitStatus status)
{
    auto *p = qobject_cast<QProcess *>(sender());
    if (!p || p != m_process)
        return;
    std::optional<int> code;
    if (status == QProcess::NormalExit)
        code = exitCode;
    if (m_current && m_current->record.path == QLatin1String("helper")) {
        // The helper's own exit file is the code when there is one (pkexec's is the same; pkexec alone gives 126, 127).
        if (const auto fileCode = helperExitCode(m_config.statusDir, m_current->record.id)) {
            code = fileCode;
        } else if (helperRunning(m_config.statusDir, m_current->record.id)) {
            // pkexec ended but the helper's run goes on in its transient system unit (grassfield-store-helper.service,
            // SU-03): it is followed by its files from here, as after a restart of the Store, until its exit file comes.
            m_process->disconnect(this);
            m_process->deleteLater();
            m_process.clear();
            m_followOnly = true;
            if (m_current->state != State::Running) {
                m_current->state = State::Running;
                m_runningSince = QDateTime::currentDateTimeUtc();
                emit changed();
            }
            m_poll.start();
            return;
        }
    }
    if (m_current && m_current->record.path == QLatin1String("flatpak")) {
        if (m_firstExit) {
            code = m_firstExit; // `--unused` ran after the removal: the removal's own code is the operation's
        } else if (m_current->record.kind == QLatin1String("update") && code == 0 && !m_flatpakSteps.isEmpty() && !m_stopping && !m_idleStopped) {
            // The next of the update's commands; a failed one ends it, its code the operation's (S32d).
            m_process->disconnect(this);
            m_process->deleteLater();
            m_process.clear();
            m_output += "\n";
            startUpdateStep();
            return;
        } else if (m_current->record.kind == QLatin1String("remove") && code == 0 && !m_idleStopped) {
            // The app is gone: the runtimes no other app needs go too (SD27; a runtime installed by name stays, S26).
            m_firstExit = code;
            m_process->disconnect(this);
            m_process->deleteLater();
            m_process.clear();
            m_output += "\n";
            startFlatpak({QStringLiteral("uninstall"), QStringLiteral("--user"), QStringLiteral("--noninteractive"), QStringLiteral("--unused")});
            return;
        }
    }
    conclude(code, QString());
}

QString Operations::helperLog(const QString &id) const
{
    return QString::fromUtf8(readTail(m_config.statusDir + QLatin1Char('/') + id + QStringLiteral(".log"), kMaxDetails));
}

void Operations::readState(const OperationRecord &record, std::function<void(int, int)> then)
{
    Operations *const self = this; // its pool ends before it is gone; the answer goes to m_context (SU-14)
    const QString pacman = m_config.pacman;
    const QString applications = m_config.applications;
    FlatpakTools flatpak;
    flatpak.flatpak = m_config.flatpak;
    flatpak.env = m_config.flatpakEnv;
    m_pool.start([self, record, pacman, applications, flatpak, then] {
        int present = 0, total = 0;
        if (record.path == QLatin1String("flatpak") && record.kind == QLatin1String("update")) {
            // Never the exit code alone, which is 0 offline with nothing updated (S31d): a pinned ref is done when its
            // installed commit is the pinned one (a newer one may be listed already, S32e), the others when a new check no
            // longer lists them (S31). No answer from flatpak: none is.
            total = int(record.packages.size());
            const std::optional<QList<FlatpakUpdate>> left = flatpak.flatpak.isEmpty() ? std::nullopt : listFlatpakUpdates(flatpak);
            // A pinned ref installed with another commit than its plan read and than the pinned one was updated outside the
            // Store: it is up to date as far as this update goes.
            for (qsizetype i = 0; i < record.packages.size() && !flatpak.flatpak.isEmpty(); ++i) {
                const QString &ref = record.packages.at(i);
                const QString commit = record.commits.value(i);
                const QString from = record.fromCommits.value(i);
                if (!commit.isEmpty()) {
                    const QString installed = flatpakInstalledCommit(flatpak, ref);
                    if (!installed.isEmpty() && (installed == commit || (!from.isEmpty() && installed != from)))
                        ++present;
                } else if (left && std::none_of(left->cbegin(), left->cend(), [&ref](const FlatpakUpdate &u) { return u.ref == ref; })) {
                    ++present;
                }
            }
        } else if (record.path == QLatin1String("flatpak")) {
            // The app in the user's installation after an install, gone after a removal (flatpak info --user).
            total = 1;
            const QString id = record.kind == QLatin1String("install") ? flatpakRefId(record.flatpak) : record.flatpak;
            const bool there = !flatpak.flatpak.isEmpty() && flatpakInstalled(flatpak, id);
            present = record.kind == QLatin1String("install") ? there : !there;
        } else if (record.path == QLatin1String("helper") || record.path == QLatin1String("terminal")) {
            QStringList names;
            for (const PlannedPackage &p : record.plan)
                names.append(p.name);
            total = int(names.size());
            QHash<QString, QString> versions;
            if (!names.isEmpty()) {
                const ChildResult r = runChild(pacman, QStringList{QStringLiteral("-Q"), QStringLiteral("--")} + names);
                if (r.started && !r.timedOut && !r.overflow) {
                    for (const QByteArray &line : r.out.split('\n')) {
                        const QList<QByteArray> f = line.trimmed().split(' ');
                        if (f.size() == 2)
                            versions.insert(QString::fromUtf8(f.at(0)), QString::fromUtf8(f.at(1)));
                    }
                }
            }
            for (const PlannedPackage &p : record.plan) {
                // An AUR package's version is the one its build makes (a VCS package's pkgver moves): any, then.
                const bool there = versions.contains(p.name) && (p.version.isEmpty() || versions.value(p.name) == p.version);
                // An install wants each one there at its version; a removal wants each one gone.
                if (record.kind == QLatin1String("install") ? there : !versions.contains(p.name))
                    ++present;
            }
        } else {
            total = 1;
            const QHash<QString, QString> urls = webAppUrls(applications);
            const bool there = urls.value(record.webName) == record.webUrl;
            present = record.kind == QLatin1String("install") ? there : !urls.contains(record.webName);
        }
        QMetaObject::invokeMethod(&self->m_context, [then, present, total] { then(present, total); }, Qt::QueuedConnection);
    });
}

void Operations::conclude(std::optional<int> exitCode, const QString &output)
{
    if (!m_current || m_concluding)
        return;
    m_concluding = true;
    m_poll.stop();
    const bool lostTrack = output == QLatin1String("lostTrack");
    const bool didNotOpen = output == QLatin1String("terminalDidNotOpen");
    if (!output.isEmpty() && !lostTrack && !didNotOpen)
        m_output += output.toUtf8();
    if (m_process) {
        m_process->disconnect(this);
        if (m_process->state() == QProcess::NotRunning)
            m_process->deleteLater();
        else
            m_process->setParent(nullptr); // left to finish: QProcess must not kill it
        m_process.clear();
    }
    m_current->state = State::Checking;
    emit changed();
    const OperationRecord record = m_current->record;
    const bool stopped = m_stopping;
    const bool stalled = m_idleStopped;
    readState(record, [this, record, exitCode, lostTrack, didNotOpen, stopped, stalled](int present, int total) {
        releaseUpdateLock();
        Result result;
        result.app = record.app;
        result.kind = record.kind;
        result.record = record;
        result.present = present;
        result.total = total;
        QString details = QString::fromUtf8(m_output).trimmed();
        if (record.path == QLatin1String("helper")) {
            const QString log = helperLog(record.id).trimmed();
            details = log.isEmpty() ? details : (details.isEmpty() ? log : log + QLatin1Char('\n') + details);
        }
        result.details = details.right(kMaxDetails);
        // A Flatpak found installed with no exit code (the Store ended meanwhile, and flatpak with it): flatpak deploys the app
        // last and lists only what it deployed, so it is done.
        const bool flatpak = record.path == QLatin1String("flatpak");
        const Outcome outcome = flatpak && !exitCode && total > 0 && present == total ? Outcome::Done : judge(exitCode, present, total);
        if (outcome == Outcome::Done) {
            result.outcome.clear();
        } else if (lostTrack) {
            result.outcome = QStringLiteral("lostTrack");
        } else if (flatpak) {
            // Stopped by the user: what it finished stays (runtimes), nothing is half-installed; nothing to say but that. An
            // update whose commands did part of its refs before one failed or the Store ended: how many. Else flatpak's own
            // failure (its words in Details), or no exit code and nothing there.
            const bool partial = record.kind == QLatin1String("update") && present > 0 && present < total;
            // Stalled and stopped at the idle limit (SU-09): it did not finish (its words, and the limit's, in Details).
            result.outcome = stopped && present == 0 ? QStringLiteral("stopped")
                : partial                          ? QStringLiteral("interrupted")
                : stalled                          ? QStringLiteral("notFinished")
                : exitCode && *exitCode != 0       ? QStringLiteral("failed")
                                                   : QStringLiteral("notFinished");
        } else if (didNotOpen && present == 0) {
            result.outcome = QStringLiteral("terminalDidNotOpen");
        } else if (exitCode && present == 0 && record.path == QLatin1String("terminal")) {
            // grassfield-store-run's codes (b.2): nothing ran but for 1 and 130.
            switch (*exitCode) {
            case 3:
                result.outcome = QStringLiteral("busy");
                break;
            case 4:
                result.outcome = QStringLiteral("unfinished");
                break;
            case 5:
                result.outcome = QStringLiteral("omarchyChanged");
                break;
            case 6:
                result.outcome = QStringLiteral("terminalDidNotOpen");
                break;
            case 7:
                // The AUR's plan checked again (b.2): a repository has the package now, or it is protected or needed.
                result.outcome = QStringLiteral("refused");
                break;
            case 130:
                result.outcome = QStringLiteral("cancelled"); // Ctrl+C in the terminal: the user's own choice, nothing said
                break;
            default:
                result.outcome = QStringLiteral("failed");
            }
        } else if (exitCode && *exitCode == 1 && present == 0 && record.path == QLatin1String("helper") && downloadGone(details)) {
            // pacman could not download a planned file the mirror no longer has (the owner's rc1-7): the databases are older
            // than the mirror, so the system is updated first; pacman's lines stay in the helper's log, not on screen.
            result.outcome = QStringLiteral("outdated");
        } else if (exitCode && present == 0) {
            // Nothing happened: what the exit code says (the helper's codes, pkexec's 126 and 127).
            switch (*exitCode) {
            case 126:
                result.outcome = details.contains(QLatin1String("timed out")) ? QStringLiteral("timedOut") : QStringLiteral("cancelled");
                break;
            case 127:
                result.outcome = QStringLiteral("didNotStart");
                break;
            case 3:
                result.outcome = QStringLiteral("busy");
                break;
            case 4:
                result.outcome = QStringLiteral("unfinished");
                break;
            case 5:
                result.outcome = QStringLiteral("outdated");
                break;
            case 6:
                result.outcome = QStringLiteral("refused");
                break;
            case 7:
                result.outcome = QStringLiteral("notApp");
                break;
            default:
                result.outcome = QStringLiteral("failed");
            }
        } else if (!exitCode && present == 0 && details.contains(QLatin1String("timed out"))) {
            result.outcome = QStringLiteral("timedOut");
        } else {
            result.outcome = outcome == Outcome::Interrupted ? QStringLiteral("interrupted") : QStringLiteral("notFinished");
        }
        if (!result.outcome.isEmpty())
            m_results.insert(record.app, result);
        else
            m_results.remove(record.app);
        if (record.path == QLatin1String("terminal") && !m_config.runDir.isEmpty()) {
            for (const QString &suffix : {QStringLiteral(".pins"), QStringLiteral(".started"), QStringLiteral(".exit")})
                QFile::remove(m_config.runDir + QLatin1Char('/') + record.id + suffix);
        }
        clearRecord();
        m_current.reset();
        m_concluding = false;
        m_stopping = false;
        m_idleStopped = false;
        m_firstExit.reset();
        m_flatpakSteps.clear();
        m_flatpakGuards.clear();
        emit changed();
        emit finished(record.app);
        if (m_queue.isEmpty())
            emit idle();
        startNext();
    });
}

void Operations::recover()
{
    const auto record = OperationRecord::fromJson(readStoreState(m_config.stateFile).value(kOperationKey).toObject());
    pruneRunDir(record ? record->id : QString());
    if (!record) {
        clearRecord();
        return;
    }
    Item item;
    item.record = *record;
    item.state = State::Running;
    m_current = item;
    m_output.clear();
    if (record->path == QLatin1String("terminal")) {
        // The script still running is followed again; a terminal asked for moments ago may still open.
        const QString dir = m_config.runDir;
        const bool started = QFileInfo::exists(dir + QLatin1Char('/') + record->id + QStringLiteral(".started"));
        const qint64 since = record->startedAt.msecsTo(QDateTime::currentDateTimeUtc());
        if (!helperExitCode(dir, record->id)
            && ((started && helperRunning(dir, record->id)) || (!started && since >= 0 && since <= qint64(m_config.terminalStartMs) + m_config.terminalGraceMs))) {
            m_current->state = started ? State::Running : State::Opening;
            // From here on, as a fresh start does: the whole of pacman's log holds every earlier install of these names
            // (and is megabytes to read at each poll).
            m_logOffset = QFileInfo(m_config.pacmanLog).size();
            m_runningSince = QDateTime::currentDateTimeUtc();
            m_poll.start();
            emit changed();
            return;
        }
        conclude(helperExitCode(dir, record->id), QString());
        return;
    }
    if (record->path == QLatin1String("helper") && !helperExitCode(m_config.statusDir, record->id) && helperRunning(m_config.statusDir, record->id)) {
        // Still running: followed again until its exit file comes (its lock is taken when free).
        m_followOnly = true;
        m_logOffset = QFileInfo(m_config.pacmanLog).size(); // as above: only what pacman logs from now on
        m_runningSince = QDateTime::currentDateTimeUtc();
        takeUpdateLock();
        m_poll.start();
        emit changed();
        return;
    }
    conclude(record->path == QLatin1String("helper") ? helperExitCode(m_config.statusDir, record->id) : std::nullopt, QString());
}

} // namespace grassfield::store
