#include "storebackend.h"

#include "appscope.h"
#include "autoappearance.h"
#include "catalog.h"
#include "childprocess.h"
#include "chromecaps.h"
#include "fetch.h"
#include "runmode.h"
#include "shortcutstyle.h"
#include "storeenv.h"
#include "translationloader.h"

#include <QCoreApplication>
#include <QRegularExpression>

#include <QCollator>
#include <QDir>
#include <QDeadlineTimer>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QWindow>
#include <QImageReader>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMimeDatabase>
#include <QNetworkInformation>
#include <QPointer>
#include <QProcessEnvironment>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUrl>

#include <pwd.h>
#include <unistd.h>

namespace grassfield::store {

namespace {

constexpr int kStaleHours = 6;       // SR26: the catalog is fetched again when its copy is older
constexpr int kOldDays = 30;         // SR29: a catalog older than this is used with a note
constexpr qint64 kSignatureMax = 64 * 1024;
constexpr int kFetchMs = 15000;      // ADR-0037 c
constexpr int kHeadsMs = 20000;      // a plan's HEADs, all of them (ADR-0037 e.4)
constexpr qint64 kAppStreamPackageMax = 64 * 1024 * 1024;
constexpr int kAppStreamDownloadMs = 120000;
constexpr int kMaxWebApps = 500;
constexpr qint64 kConfigMax = 1024 * 1024; // grassfield.json (ADR-0020: a real one is a few KiB)

QString configFile()
{
    return apps::runmode::configDir() + QStringLiteral("/grassfield.json");
}

// The application when it is a QGuiApplication (the window's), else null (the unit tests' QCoreApplication).
QGuiApplication *guiApp()
{
    return qobject_cast<QGuiApplication *>(QCoreApplication::instance());
}

QByteArray readSmall(const QString &path, qint64 max)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly) || f.size() > max)
        return {};
    return f.read(max);
}

QString dataHome()
{
    const QString xdg = qEnvironmentVariable("XDG_DATA_HOME");
    return xdg.isEmpty() ? QDir::homePath() + QStringLiteral("/.local/share") : xdg;
}

// Where the catalog comes from, decided once per job (channel.h): the dev plumbing's URL, else the channel's.
struct Source {
    QString channel = QStringLiteral("stable");
    QUrl catalog;       // invalid: nothing to fetch (no hosting yet)
    bool devPlumbing = false;
    std::optional<Channel> base;
};

Source catalogSource()
{
    Source s;
    const std::optional<Channel> conf = channelFromConf(readSmall(env::grassfieldConf(), 64 * 1024));
    // A channel set up through grassfield.conf needed the key; the build's own base counts only when the build names a key
    // (ADR-0033 b.3): without one the catalog cannot be verified, so nothing is requested from the host.
    const QByteArray repository = readSmall(env::repositoryConf(), 64 * 1024);
    const QByteArray version = readSmall(env::versionFile(), 256);
    const Channel channel = conf ? *conf : buildChannel(repository, version);
    s.channel = channel.name;
    const QUrl override = env::catalogUrlOverride();
    if (override.isValid()) {
        s.catalog = override;
        s.devPlumbing = true;
    } else if (fetchable(channel)) {
        s.catalog = catalogUrl(channel);
        s.base = channel;
    }
    return s;
}

QUrl iconSource(const Source &s, const QString &sha256)
{
    if (s.devPlumbing)
        return s.catalog.resolved(QUrl(QStringLiteral("catalog/%1.png").arg(sha256)));
    return s.base ? iconUrl(*s.base, sha256) : QUrl();
}

// The launcher icon of a web app: a file, or an icon name looked up where omarchy-webapp-install puts them.
QString webAppIcon(const QString &value)
{
    if (value.isEmpty())
        return {};
    if (value.startsWith(QLatin1Char('/')))
        return QFileInfo(value).isFile() ? value : QString();
    if (value.contains(QLatin1Char('/')) || value.startsWith(QLatin1Char('.')))
        return {};
    for (const QString &root : {dataHome() + QStringLiteral("/icons/hicolor"), QStringLiteral("/usr/share/icons/hicolor")}) {
        for (const QString &file : {QStringLiteral("/256x256/apps/%1.png"), QStringLiteral("/scalable/apps/%1.svg")}) {
            const QString path = root + file.arg(value);
            if (QFileInfo(path).isFile())
                return path;
        }
    }
    return {};
}

QList<view::WebAppEntry> readWebApps()
{
    QList<view::WebAppEntry> out;
    QDirIterator it(dataHome() + QStringLiteral("/applications"), {QStringLiteral("*.desktop")}, QDir::Files);
    int seen = 0;
    while (it.hasNext() && seen++ < kMaxWebApps) {
        const QString path = it.next();
        const auto entry = view::parseWebAppEntry(readSmall(path, 64 * 1024));
        if (entry) {
            view::WebAppEntry e = *entry;
            e.icon = webAppIcon(e.icon);
            e.file = QFileInfo(path).completeBaseName();
            out.append(e);
        }
    }
    return out;
}

// The packages no repository has that own an application entry (`pacman -Ql`, as the user).
QSet<QString> foreignWithEntry(const QString &pacman, const QSet<QString> &foreign)
{
    QSet<QString> out;
    QStringList names;
    for (const QString &n : foreign) {
        if (isPackageName(n) && !n.startsWith(QLatin1String("grassfield"))) // Grassfield's own local builds are never listed
            names.append(n);
    }
    if (names.isEmpty())
        return out;
    names.sort();
    const ChildResult r = runChild(pacman, QStringList{QStringLiteral("-Ql"), QStringLiteral("--")} + names);
    if (!r.ok())
        return out;
    for (const QByteArray &line : r.out.split('\n')) {
        const int space = line.indexOf(' ');
        if (space <= 0)
            continue;
        const QByteArray path = line.mid(space + 1);
        if (path.startsWith("/usr/share/applications/") && path.endsWith(".desktop"))
            out.insert(QString::fromUtf8(line.left(space)));
    }
    return out;
}

// The application entries of /usr/share/applications and the packages that own them (pacman -Qo, as the user): package ->
// desktop ids, sorted. An entry no package owns is left out.
QHash<QString, QStringList> readEntries(const QString &pacman, const QString &dir)
{
    QHash<QString, QStringList> out;
    QStringList files;
    for (const QString &name : QDir(dir).entryList({QStringLiteral("*.desktop")}, QDir::Files, QDir::Name)) {
        if (isDesktopId(name))
            files.append(dir + QLatin1Char('/') + name);
        if (files.size() >= 4000)
            break;
    }
    if (files.isEmpty())
        return out;
    // pacman -Qo exits 1 when a file has no owner; the others are still listed.
    const ChildResult r = runChild(pacman, QStringList{QStringLiteral("-Qo"), QStringLiteral("--")} + files);
    if (!r.started || r.timedOut || r.overflow)
        return out;
    static const QRegularExpression owned(QStringLiteral("^(\\S+) is owned by (\\S+) \\S+$"));
    for (const QByteArray &line : r.out.split('\n')) {
        const QRegularExpressionMatch m = owned.match(QString::fromUtf8(line).trimmed());
        if (!m.hasMatch() || !isPackageName(m.captured(2)))
            continue;
        out[m.captured(2)].append(QFileInfo(m.captured(1)).fileName());
    }
    for (QStringList &ids : out)
        ids.sort();
    return out;
}

// What the Store never removes (removal.h): Omarchy's two package lists, read where Omarchy installs them, and pacman's
// HoldPkg (pacman-conf; pacman's own default when it cannot be read).
DenyList readDenyList()
{
    DenyList deny;
    for (const QString &list : {QStringLiteral("/omarchy-base.packages"), QStringLiteral("/omarchy-other.packages")})
        deny.omarchy.unite(parsePackageList(readSmall(env::omarchyLists() + list, 1024 * 1024)));
    const ChildResult hold = runChild(env::pacmanConf(), {QStringLiteral("HoldPkg")});
    if (hold.ok())
        deny.holdPkg = parsePackageList(hold.out);
    if (deny.holdPkg.isEmpty())
        deny.holdPkg = {QStringLiteral("pacman"), QStringLiteral("glibc")};
    // What Grassfield's own packages list as optional dependencies (ADR-0046 D3): pacman -Qi of the installed grassfield-*.
    // Unreadable: nothing is removable (the lists are cleared, as when Omarchy's cannot be read).
    const ChildResult installed = runChild(env::pacman(), {QStringLiteral("-Qq")});
    QStringList own;
    for (const QByteArray &line : installed.out.split('\n')) {
        const QString name = QString::fromUtf8(line).trimmed();
        if (installed.ok() && isPackageName(name) && (name == QLatin1String("grassfield") || name.startsWith(QLatin1String("grassfield-"))))
            own.append(name);
    }
    if (!own.isEmpty()) {
        own.sort();
        const ChildResult qi = runChild(env::pacman(), QStringList{QStringLiteral("-Qi"), QStringLiteral("--")} + own);
        if (qi.ok())
            deny.grassfieldOptional = parseOptionalDeps(qi.out);
        else
            deny.omarchy.clear();
    }
    return deny;
}

struct JobInput {
    bool fetchCatalog = false;
    bool fetchAppData = false;
    bool online = true;
    bool aur = false; // the AUR source is on: the catalog's AUR apps are offered
    bool flathub = false;      // the Flathub source is on: Flathub is added to the user's installation, its apps offered
    bool fetchFlathub = false; // and its AppStream fetched again
};

// Flathub's AppStream in the user's installation is older than the catalog's 6 hours (or not there).
bool flathubStale()
{
    const QFileInfo f(env::flathubAppStream(flatpakArch()) + QStringLiteral("/appstream.xml.gz"));
    return !f.exists() || f.lastModified().secsTo(QDateTime::currentDateTime()) > kStaleHours * 3600;
}

std::shared_ptr<const Snapshot> buildSnapshot(const JobInput &in, const std::atomic_bool &cancel)
{
    auto snap = std::make_shared<Snapshot>();
    snap->fallback.categories = view::builtInCategories();

    // pacman's lists, as the user (no root, no lock).
    const Pacman pacman(env::pacman());
    snap->sync = pacman.syncList();
    for (const SyncPackage &p : std::as_const(snap->sync))
        snap->syncNames.insert(p.name);
    snap->pacmanRead = !snap->sync.isEmpty();
    snap->explicitPackages = pacman.explicitlyInstalled();
    if (cancel)
        return snap;
    for (const QString &n : pacman.foreign()) {
        if (isPackageName(n))
            snap->foreign.insert(n);
    }
    snap->foreignWithEntry = foreignWithEntry(env::pacman(), snap->foreign);
    snap->entries = readEntries(env::pacman(), env::systemApplications());
    snap->deny = readDenyList();

    // Arch's AppStream: installed, else the copy fetched before (refreshed first when asked and online).
    const QString root = env::swcatalogRoot();
    if (QDir(root + QStringLiteral("/xml")).exists()) {
        snap->appstream = readAppStream(root, AppStreamData::Origin::Installed);
    } else {
        if (in.fetchAppData && in.online) {
            AppStreamTools tools;
            tools.pacman = env::pacman();
            tools.gpg = env::gpg();
            tools.pacmanGnupg = env::pacmanGnupg();
            tools.bsdtar = env::bsdtar;
            const bool devPlumbing = !env::fixture().isEmpty();
            tools.download = [devPlumbing](const QString &url, const QString &file, qint64 maxBytes, int timeoutMs) {
                return downloadTo(QUrl(url), file, FetchLimits{maxBytes, timeoutMs}, devPlumbing);
            };
            // Each reason has its own words (the integrator's note on PR #36): a file the mirror no longer has (a package
            // database older than the mirror, most often) is "download", never "unverified".
            QString detail;
            switch (refreshFetched(env::cacheDir(), tools, &detail)) {
            case RefreshProblem::None:
                break;
            case RefreshProblem::Download:
            case RefreshProblem::SignatureDownload:
                snap->appstreamProblem = QStringLiteral("download");
                break;
            case RefreshProblem::Unverified:
                snap->appstreamProblem = QStringLiteral("unverified");
                break;
            case RefreshProblem::NoPackageFile:
            case RefreshProblem::Unpack:
            case RefreshProblem::Cache:
                snap->appstreamProblem = QStringLiteral("unavailable");
                break;
            }
            if (!snap->appstreamProblem.isEmpty())
                qInfo("grassfield-store: Arch's app data: %s", qPrintable(detail));
        }
        snap->appstream = readFetched(env::cacheDir());
    }
    if (cancel)
        return snap;

    // The catalog: fetched when asked (its copy stale, or Ctrl+R), else the cached copy, checked again either way.
    const Source source = catalogSource();
    snap->channel = source.channel;
    snap->catalogConfigured = source.catalog.isValid();
    CatalogStore store(env::cacheDir(), env::stateFile(), env::gpgv, env::keyringDir());
    CatalogStore::Result result;
    bool loaded = false;
    // A catalog on disk (dev plumbing) needs no network.
    const bool reachable = in.online || (source.devPlumbing && source.catalog.isLocalFile());
    if (in.fetchCatalog && reachable && source.catalog.isValid()) {
        const FetchResult json = fetch(source.catalog, FetchLimits{kCatalogMaxBytes, kFetchMs}, store.cachedEtag(source.channel), source.devPlumbing);
        if (json.status == FetchResult::Status::NotModified) {
            store.touch(source.channel);
        } else if (json.status == FetchResult::Status::Ok) {
            const FetchResult sig = fetch(signatureUrl(source.catalog), FetchLimits{kSignatureMax, kFetchMs}, {}, source.devPlumbing);
            if (sig.status == FetchResult::Status::Ok) {
                result = store.accept(source.channel, json.body, sig.body, json.etag);
                loaded = result.outcome == CatalogStore::Outcome::Accepted;
                if (!loaded) {
                    snap->fetchProblem = result.outcome == CatalogStore::Outcome::NoTrustedKey ? QStringLiteral("untrusted") : QStringLiteral("refused");
                    snap->catalogReason = result.reason;
                }
            } else {
                snap->fetchProblem = QStringLiteral("unavailable");
            }
        } else {
            snap->fetchProblem = QStringLiteral("unavailable");
        }
    }
    if (!loaded)
        result = store.loadCached(source.channel); // the previous accepted copy stays in use
    snap->catalogOutcome = result.outcome;
    if (snap->catalogReason.isEmpty())
        snap->catalogReason = result.reason;
    snap->catalogFetchedAt = store.fetchedAt(source.channel);
    if (result.outcome == CatalogStore::Outcome::Accepted && result.catalog)
        snap->catalog = std::move(result.catalog);

    // The catalog's icons for apps without metadata, fetched once each (the cache keeps only those matching their hash).
    if (snap->catalog && reachable && (in.fetchCatalog || in.fetchAppData)) {
        for (const CatalogApp &a : snap->catalog->apps) {
            if (cancel)
                break;
            if (!a.icon || !store.iconPath(*a.icon).isEmpty())
                continue;
            const QUrl url = iconSource(source, a.icon->sha256);
            if (!url.isValid())
                continue;
            const FetchResult icon = fetch(url, FetchLimits{kIconMaxBytes, kFetchMs}, {}, source.devPlumbing);
            if (icon.status == FetchResult::Status::Ok)
                store.storeIcon(*a.icon, icon.body);
        }
    }

    snap->webApps = readWebApps();

    // Flathub (step 3c): added to the user's installation when its switch is turned on (S21), its AppStream fetched again
    // on the catalog's schedule; a dev session changes the user's installation only through the fixture's fake flatpak.
    if (in.flathub && !env::flatpak().isEmpty()) {
        FlatpakTools flatpak;
        flatpak.flatpak = env::flatpak();
        flatpak.env = flatpakEnvironment();
        snap->flathubAdded = flathubAdded(flatpak);
        const bool mayWrite = !apps::runmode::dev() || !env::fixture().isEmpty();
        if (!mayWrite && !snap->flathubAdded) {
            snap->flathubProblem = QStringLiteral("dev");
        } else if (mayWrite && in.online && (!snap->flathubAdded || in.fetchFlathub) && !cancel) {
            const QString problem = snap->flathubAdded ? refreshFlathubAppStream(flatpak) : addFlathub(flatpak);
            if (!snap->flathubAdded)
                snap->flathubAdded = flathubAdded(flatpak);
            if (!problem.isEmpty()) {
                snap->flathubProblem = QStringLiteral("added");
                qInfo("grassfield-store: Flathub: %s", qPrintable(problem));
            }
        } else if (!snap->flathubAdded) {
            snap->flathubProblem = QStringLiteral("added"); // offline: added once online
        }
        if (snap->flathubAdded) {
            snap->flathub = readFlathubAppStream(env::flathubAppStream(flatpakArch()));
            if (const auto installed = listFlatpakApps(flatpak))
                snap->flatpaks = *installed;
        }
    }

    ModelInputs model;
    model.catalog = snap->catalog ? &*snap->catalog : &snap->fallback;
    model.appstream = snap->appstream.components;
    model.appstreamRoot = snap->appstream.root;
    model.sync = snap->sync;
    model.aurOn = in.aur;
    model.flathubOn = in.flathub && snap->flathubAdded;
    model.flathub = snap->flathub.components;
    model.flathubRoot = snap->flathub.root;
    model.flatpaks = snap->flatpaks;
    model.foreign = snap->foreign;
    model.catalogIcon = [&store](const CatalogIcon &icon) { return store.iconPath(icon); };
    snap->apps = buildModel(model);
    // Repository apps the user installed that neither our catalog nor Arch's AppStream describe (Omarchy's own repository
    // has no AppStream data: Aether, Cliamp, Omacut…): listed by their package, so that Uninstall… reaches them from the
    // product page, the launcher and Files (ADR-0046 F1). Only a package installed explicitly that owns an application entry.
    {
        QSet<QString> listed, ids;
        for (const StoreApp &a : std::as_const(snap->apps)) {
            ids.insert(a.id);
            listed.insert(a.package);
            for (const QString &p : a.packages)
                listed.insert(p);
        }
        QHash<QString, SyncPackage> byName;
        for (const SyncPackage &p : std::as_const(snap->sync)) {
            if (isStoreRepository(p.repo) && !byName.contains(p.name))
                byName.insert(p.name, p);
        }
        QStringList names = snap->entries.keys();
        names.sort();
        for (const QString &pkg : std::as_const(names)) {
            const auto it = byName.constFind(pkg);
            if (it == byName.constEnd() || !it->installed || !snap->explicitPackages.contains(pkg) || listed.contains(pkg) || ids.contains(pkg)
                || !isPackageName(pkg))
                continue;
            StoreApp a;
            a.id = pkg;
            a.repo = it->repo;
            a.package = pkg;
            a.packages = {pkg};
            a.installed = true;
            a.name = LocalizedText{pkg, {}};
            a.desktopId = snap->entries.value(pkg).value(0);
            snap->apps.append(a);
        }
    }
    // A setup runs from the installed Omarchy (b.2): hidden when Omarchy has no such recipe (spec, "Refusals"), and none
    // runs while a pinned file differs.
    const QString omarchy = env::omarchyRoot();
    snap->apps.removeIf([&omarchy](const StoreApp &a) {
        if (a.source != CatalogSource::Kind::OmarchySetup || !a.entry)
            return false;
        const QFileInfo install(omarchy + QStringLiteral("/bin/") + a.entry->source.install);
        const QFileInfo remove(omarchy + QStringLiteral("/bin/") + a.entry->source.remove);
        return !install.isFile() || !install.isExecutable() || !remove.isFile() || !remove.isExecutable();
    });
    if (snap->catalog && snap->catalog->omarchy)
        snap->omarchyDiffers = omarchyDifference(omarchy, snap->catalog->omarchy->files);
    QSet<QString> webUrls;
    for (const view::WebAppEntry &w : snap->webApps)
        webUrls.insert(w.url);
    for (int i = 0; i < snap->apps.size(); ++i) {
        StoreApp &a = snap->apps[i];
        if (a.source == CatalogSource::Kind::WebApp && a.entry)
            a.installed = webUrls.contains(a.entry->source.url);
        // Open's entry when neither our catalog nor AppStream names one: the package's own (the first by name, f); a
        // setup's, its first package's that has one.
        if (a.desktopId.isEmpty() && (a.source == CatalogSource::Kind::Repo || a.source == CatalogSource::Kind::Aur) && a.installed)
            a.desktopId = snap->entries.value(a.package).value(0);
        for (const QString &p : a.packages) {
            if (a.desktopId.isEmpty() && a.source == CatalogSource::Kind::OmarchySetup && a.installed)
                a.desktopId = snap->entries.value(p).value(0);
        }
        snap->index.insert(a.id, i);
    }
    // The tints of the hero and card artwork: the app's icon decoded here, off the GUI thread.
    if (snap->catalog) {
        for (const CatalogSection &section : snap->catalog->sections) {
            for (const CatalogBlock &block : section.blocks) {
                for (const CatalogItem &item : block.items) {
                    const int i = snap->index.value(item.app, -1);
                    if (i < 0 || snap->tints.contains(item.app) || snap->apps.at(i).icon.isEmpty())
                        continue;
                    QImageReader reader(snap->apps.at(i).icon);
                    reader.setScaledSize(QSize(48, 48));
                    const QColor tint = view::heroTint(reader.read(), 6.0); // 6:1 with white: the 80 % lines hold 4.5:1 (A2)
                    snap->tints.insert(item.app, tint.isValid() ? tint.name() : QString());
                }
            }
        }
    }
    return snap;
}

} // namespace

StoreBackend::StoreBackend(QObject *parent)
    : QObject(parent)
    , m_cancel(std::make_shared<std::atomic_bool>(false))
{
    m_pool.setMaxThreadCount(2); // one load and one product page's pacman -Si at a time
    m_updatePool.setMaxThreadCount(3); // Updates: a check (the shell, pacman -Qu, Flathub's), its review and an update's plan at once
    // qGuiApp casts whatever application there is: the unit tests' is a QCoreApplication.
    if (auto *gui = guiApp())
        connect(gui, &QGuiApplication::focusWindowChanged, this, &StoreBackend::focusWindowChanged);
    const QString system = i18n::systemLanguage();
    m_language = system.startsWith(QLatin1String("fr")) ? QStringLiteral("fr") : QStringLiteral("en");
    m_macDevice = apps::macDeviceHere();

    const QString file = configFile();
    const QString dir = QFileInfo(file).absolutePath();
    if (QFileInfo(dir).isDir())
        m_watcher.addPath(dir);
    if (QFileInfo::exists(file))
        m_watcher.addPath(file);
    const QString caps = apps::capabilitiesFile();
    if (!caps.isEmpty() && QFileInfo(QFileInfo(caps).absolutePath()).isDir())
        m_watcher.addPath(QFileInfo(caps).absolutePath());
    const auto reread = [this] {
        const QString f = configFile();
        if (QFileInfo::exists(f) && !m_watcher.files().contains(f))
            m_watcher.addPath(f);
        readAppearance();
    };
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, reread);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, reread);
    readAppearance();
    m_autoTimer.setInterval(apps::kAutoRecheckMs);
    connect(&m_autoTimer, &QTimer::timeout, this, [this] {
        if (m_autoAppearance)
            readAppearance();
    });
    m_autoTimer.start();

    // The local user (SR1): the full name of passwd, its initials, and AccountsService's picture when there is one.
    if (const passwd *pw = getpwuid(getuid())) {
        const QString login = QString::fromLocal8Bit(pw->pw_name);
        QString name = QString::fromLocal8Bit(pw->pw_gecos).section(QLatin1Char(','), 0, 0).trimmed();
        if (name.isEmpty())
            name = login;
        name = cleanPlainText(name, 64, false);
        const QString picture = QStringLiteral("/var/lib/AccountsService/icons/") + login;
        const QFileInfo info(picture);
        m_user = {{QStringLiteral("name"), name},
                  {QStringLiteral("initials"), view::initials(name)},
                  {QStringLiteral("picture"), info.isFile() && info.isReadable() && info.size() < 1024 * 1024
                                                  ? QUrl::fromLocalFile(picture).toString() : QString()}};
    }
    readNetwork();

    // The queue (operations.h): the system's programs, or in a dev session the fake ones (ADR-0019; none: nothing runs).
    OperationsConfig ops;
    ops.pkexec = env::pkexec();
    ops.helper = env::helperPath;
    ops.statusDir = env::statusDir();
    ops.updateLock = env::updateLock();
    ops.dbLock = env::dbLock();
    ops.pacmanLog = env::pacmanLog();
    ops.pacman = env::pacman();
    ops.stateFile = env::stateFile();
    ops.applications = dataHome() + QStringLiteral("/applications");
    ops.run = env::runPath;
    ops.runDir = env::runDir();
    ops.omarchy = [](const QString &command, const QStringList &args) {
        const QString fake = env::installer();
        if (apps::runmode::dev())
            return fake.isEmpty() ? QStringList() : QStringList{fake, command} + args;
        return QStringList{env::omarchyCommand(command)} + args;
    };
    ops.flatpak = env::flatpak();
    if (apps::runmode::dev() && env::fixture().isEmpty())
        ops.flatpak.clear(); // a dev session runs no real flatpak operation (SR30)
    ops.flatpakEnv = flatpakEnvironment();
    m_operations = std::make_unique<Operations>(ops);
    // Every new snapshot moves the buttons' revision too; revisionChanged alone is a change of the buttons' state only.
    connect(this, &StoreBackend::dataChanged, this, &StoreBackend::revisionChanged);
    connect(m_operations.get(), &Operations::changed, this, &StoreBackend::operationsChanged);
    // The running operation in the menu bar (ADR-0052); its Stop is the ring's square (SD26).
    m_ongoing = new apps::OngoingPublisher(this);
    connect(this, &StoreBackend::operationsChanged, this, &StoreBackend::publishOngoing);
    connect(m_ongoing, &apps::OngoingPublisher::actionInvoked, this, [this](const QString &id, const QString &action) {
        if (action == QLatin1String("stop") && id.startsWith(QLatin1String("op-")))
            stopOperation(id.mid(3));
    });
    connect(m_operations.get(), &Operations::finished, this, [this](const QString &app) {
        m_installPlans.remove(app);
        m_removePlans.remove(app);
        m_updatePlans.remove(app);
        checkStaleLock();
        run(Job{}); // the system changed: read it again
        // A Flatpak's install, removal or update: its updates listed again.
        const StoreApp *a = storeApp(app);
        if (app == kFlatpakUpdatesApp || app.startsWith(QLatin1String("flatpak:")) || (a && a->source == CatalogSource::Kind::Flatpak))
            checkFlatpakUpdates();
    });

    // Updates (step 4): the checker's 200 s backstop, the page's 2 s look at the update lock and the file, and the file's
    // folder watched for the sidebar's count.
    m_checkDeadline.setSingleShot(true);
    m_checkDeadline.setInterval(200 * 1000);
    connect(&m_checkDeadline, &QTimer::timeout, this, [this] {
        m_systemChecking = false;
        emit updatesChanged();
    });
    m_updatesPoll.setInterval(2000);
    connect(&m_updatesPoll, &QTimer::timeout, this, &StoreBackend::followUpdates);
    const QString stateDir = QFileInfo(env::softwareUpdateFile()).absolutePath();
    if (QFileInfo(stateDir).isDir())
        m_stateWatcher.addPath(stateDir);
    connect(&m_stateWatcher, &QFileSystemWatcher::directoryChanged, this, &StoreBackend::followUpdates);
    connect(m_operations.get(), &Operations::idle, this, [this] {
        // A window shown again since (the Dock, a second launch's hand-over) keeps the Store: the user is using it.
        bool shown = false;
        if (guiApp()) {
            for (QWindow *w : QGuiApplication::topLevelWindows())
                shown = shown || w->isVisible();
        }
        if (m_quitWhenIdle && !shown)
            QCoreApplication::quit();
        m_quitWhenIdle = false;
    });
}

StoreBackend::~StoreBackend()
{
    *m_cancel = true;
    // Jobs not started yet never start (each would only run to post an answer no one reads).
    m_searchPool.clear();
    m_pool.clear();
    m_updatePool.clear();
}

bool StoreBackend::devSession() const
{
    return apps::runmode::dev();
}

void StoreBackend::readAppearance()
{
    bool dark = true, reduce = false, contrast = false;
    qreal scale = 1;
    QString accent = QStringLiteral("multicolor"), highlight = QStringLiteral("automatic"), doubleClick = QStringLiteral("zoom");
    QString shortcutSetting, formats = QStringLiteral("auto");
    bool aur = false, flathub = false, screenshots = true; // the schema's defaults (store.*)
    const QByteArray bytes = readSmall(configFile(), 1024 * 1024);
    if (!bytes.isEmpty()) {
        const QJsonObject root = QJsonDocument::fromJson(bytes).object();
        const QString setting = root.value(QStringLiteral("appearance")).toString();
        m_autoAppearance = setting == QLatin1String("auto");
        dark = apps::isDarkAppearance(setting, QTime::currentTime());
        const QJsonObject a11y = root.value(QStringLiteral("accessibility")).toObject();
        reduce = a11y.value(QStringLiteral("reduceMotion")).toBool(false);
        contrast = a11y.value(QStringLiteral("increaseContrast")).toBool(false);
        scale = qBound(1.0, a11y.value(QStringLiteral("textSize")).toDouble(1), 1.3);
        const QString d = root.value(QStringLiteral("windows")).toObject().value(QStringLiteral("titlebarDoubleClick")).toString();
        if (d == QLatin1String("minimize") || d == QLatin1String("none"))
            doubleClick = d;
        static const QStringList names{QStringLiteral("blue"), QStringLiteral("purple"), QStringLiteral("pink"), QStringLiteral("red"),
                                       QStringLiteral("orange"), QStringLiteral("yellow"), QStringLiteral("green"), QStringLiteral("graphite")};
        const QJsonObject accentObject = root.value(QStringLiteral("accent")).toObject();
        if (names.contains(accentObject.value(QStringLiteral("color")).toString()))
            accent = accentObject.value(QStringLiteral("color")).toString();
        if (names.contains(accentObject.value(QStringLiteral("highlight")).toString()))
            highlight = accentObject.value(QStringLiteral("highlight")).toString();
        shortcutSetting = root.value(QStringLiteral("keyboard")).toObject().value(QStringLiteral("shortcutStyle")).toString();
        const QString f = root.value(QStringLiteral("region")).toObject().value(QStringLiteral("formats")).toString();
        if (!f.isEmpty())
            formats = f;
        // The Store's own keys (SD20): a value that is not a boolean reads as the default, as every reader of the contract.
        const QJsonObject store = root.value(QStringLiteral("store")).toObject();
        const QJsonObject sources = store.value(QStringLiteral("sources")).toObject();
        aur = sources.value(QStringLiteral("aur")).toBool(false);
        flathub = sources.value(QStringLiteral("flathub")).toBool(false);
        screenshots = store.value(QStringLiteral("screenshots")).toBool(true);
    } else {
        m_autoAppearance = false;
    }
    m_formats = i18n::formatsLocale(i18n::systemLanguage(), formats);
    if (aur != m_aur || flathub != m_flathub || screenshots != m_screenshots) {
        const bool sourcesMoved = aur != m_aur || flathub != m_flathub;
        m_aur = aur;
        m_flathub = flathub;
        m_screenshots = screenshots;
        *m_screenshotGate = screenshotsAllowed();
        emit sourcesChanged();
        if (sourcesMoved && m_snapshot)
            run(Job{}); // the sources' apps come or go: the model is built again
    }
    const QString shortcuts = apps::shortcutStyle(shortcutSetting, m_macDevice);
    const bool canMinimize = apps::minimizeAvailableInFile();
    if (dark != m_dark || reduce != m_reduceMotion || contrast != m_increaseContrast || scale != m_textScale || accent != m_accentColor
        || highlight != m_accentHighlight || doubleClick != m_titlebarDoubleClick || canMinimize != m_canMinimize || shortcuts != m_shortcutStyle) {
        m_dark = dark;
        m_reduceMotion = reduce;
        m_increaseContrast = contrast;
        m_textScale = scale;
        m_accentColor = accent;
        m_accentHighlight = highlight;
        m_titlebarDoubleClick = doubleClick;
        m_canMinimize = canMinimize;
        m_shortcutStyle = shortcuts;
        emit appearanceChanged();
    }
}

void StoreBackend::readNetwork()
{
    if (env::offlineForced()) { // dev plumbing (ADR-0019)
        m_online = false;
        *m_screenshotGate = screenshotsAllowed();
        return;
    }
    if (env::meteredForced() || env::onlineForced()) { // dev plumbing (ADR-0019): online, metered or not
        m_online = true;
        m_metered = env::meteredForced();
        *m_screenshotGate = screenshotsAllowed();
        return;
    }
    // Without a reachability backend (no NetworkManager) the Store counts as online: a fetch that fails says so.
    if (!QNetworkInformation::instance() && !QNetworkInformation::loadBackendByFeatures(QNetworkInformation::Feature::Reachability))
        return;
    QNetworkInformation *info = QNetworkInformation::instance();
    const auto update = [this, info] {
        const auto reach = info->reachability();
        const bool online = reach == QNetworkInformation::Reachability::Online || reach == QNetworkInformation::Reachability::Unknown;
        const bool metered = info->supports(QNetworkInformation::Feature::Metered) && info->isMetered();
        if (online != m_online || metered != m_metered) {
            const bool cameOnline = online && !m_online;
            m_online = online;
            m_metered = metered;
            *m_screenshotGate = screenshotsAllowed();
            emit networkChanged();
            // Flathub turned on while offline is added now; its AppStream is fetched again when stale.
            const bool flathub = m_flathub && (!m_snapshot || !m_snapshot->flathubAdded || flathubStale());
            if (cameOnline && m_snapshot && !m_metered
                && ((m_snapshot->catalogConfigured && catalogStale()) || m_snapshot->appstream.origin == AppStreamData::Origin::None || flathub))
                run(Job{m_snapshot->catalogConfigured && catalogStale(), false, true, flathub});
            askAurForForeign(); // what waited for an unmetered connection (it asks nothing otherwise)
        }
    };
    connect(info, &QNetworkInformation::reachabilityChanged, this, update);
    connect(info, &QNetworkInformation::isMeteredChanged, this, update);
    update();
}

bool StoreBackend::catalogStale() const
{
    const QDateTime at = m_snapshot ? m_snapshot->catalogFetchedAt : QDateTime();
    return !at.isValid() || at.secsTo(QDateTime::currentDateTimeUtc()) > kStaleHours * 3600;
}

void StoreBackend::start()
{
    // A first load from what is on this computer, at once; then the fetches it calls for. An operation an earlier run left
    // in store.json is compared with what is there (SR20), and pacman's lock read.
    run(Job{});
    m_operations->recover();
    checkStaleLock();
}

void StoreBackend::refresh()
{
    run(Job{true, true, true, true});
}

void StoreBackend::run(Job job)
{
    if (m_jobRunning) {
        // One job at a time; the next one does the most any waiting request asked for.
        if (m_pendingJob) {
            job.fetchCatalog = job.fetchCatalog || m_pendingJob->fetchCatalog;
            job.forced = job.forced || m_pendingJob->forced;
            job.fetchAppData = job.fetchAppData || m_pendingJob->fetchAppData;
            job.fetchFlathub = job.fetchFlathub || m_pendingJob->fetchFlathub;
        }
        m_pendingJob = job;
        return;
    }
    m_jobRunning = true;
    const bool fetching = job.fetchCatalog || job.fetchAppData || job.fetchFlathub;
    if (fetching != m_refreshing) {
        m_refreshing = fetching;
        emit loadingChanged();
    }
    // SR26: never on a metered connection unless asked (Ctrl+R), never offline.
    JobInput in{job.fetchCatalog && (job.forced || !m_metered), job.fetchAppData && (job.forced || !m_metered), m_online, m_aur,
                m_flathub, job.fetchFlathub && (job.forced || !m_metered)};
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    m_pool.start([this, in, cancel] {
        const FetchCancelScope fetchScope(cancel); // SU-07: a quit aborts its transfers
        std::shared_ptr<const Snapshot> snapshot = buildSnapshot(in, *cancel);
        if (*cancel)
            return;
        QMetaObject::invokeMethod(&m_context, [this, snapshot] { apply(snapshot); }, Qt::QueuedConnection);
    });
}

void StoreBackend::apply(std::shared_ptr<const Snapshot> snapshot)
{
    const bool first = !m_snapshot;
    m_snapshot = std::move(snapshot);
    m_jobRunning = false;
    m_executable.clear(); // per snapshot (SU-12): a tool installed or removed meanwhile is seen with the system's new state
    rebuildAurApps();
    // `--removable` prints and leaves: nothing asks the network after its one read (no AUR, no Flatpak check, no fetch).
    if (!m_loadOnly)
        askAurForForeign();
    ++m_revision;
    const bool wasLoading = m_loading, wasRefreshing = m_refreshing;
    m_loading = false;
    m_refreshing = false;
    emit dataChanged();
    emit sourcesChanged(); // Flathub added, flatpak installed: what the settings say comes from the system read again
    emit updatesChanged(); // the apps the updates name, Flathub on or off
    // The Flatpaks' updates, when the Store opens and once Flathub is on (SR24); then on Check Now and after an operation.
    if (m_flathub && !m_flatpakCheckedAt.isValid() && !m_loadOnly)
        checkFlatpakUpdates();
    if (wasLoading != m_loading || wasRefreshing != m_refreshing)
        emit loadingChanged();
    if (m_pendingJob) {
        const Job next = *m_pendingJob;
        m_pendingJob.reset();
        run(next);
    } else if (first && !m_loadOnly) {
        // After the first load: the catalog when its copy is stale, Arch's AppStream when none is installed or fetched,
        // Flathub's when it is on and its copy is stale.
        const bool catalog = m_snapshot->catalogConfigured && catalogStale();
        const bool appData = m_snapshot->appstream.origin != AppStreamData::Origin::Installed;
        const bool flathub = m_flathub && m_snapshot->flathubAdded && flathubStale();
        if ((catalog || appData || flathub) && m_online)
            run(Job{catalog, false, appData, flathub});
    }
}

QVariantMap StoreBackend::catalogStatus() const
{
    QVariantMap out{{QStringLiteral("inUse"), false}, {QStringLiteral("problem"), QString()}, {QStringLiteral("channel"), QString()},
                    {QStringLiteral("date"), QString()}, {QStringLiteral("old"), false}};
    if (!m_snapshot)
        return out;
    const Snapshot &s = *m_snapshot;
    out.insert(QStringLiteral("channel"), s.channel);
    QString problem;
    if (!s.catalogConfigured)
        problem = QStringLiteral("unconfigured");
    else if (s.catalogOutcome == CatalogStore::Outcome::NoTrustedKey)
        problem = QStringLiteral("untrusted");
    else if (!s.fetchProblem.isEmpty())
        problem = s.fetchProblem;
    else if (s.catalogOutcome == CatalogStore::Outcome::BadSignature || s.catalogOutcome == CatalogStore::Outcome::Refused
             || s.catalogOutcome == CatalogStore::Outcome::Replayed)
        problem = QStringLiteral("refused");
    else if (!s.catalog)
        problem = QStringLiteral("unavailable");
    out.insert(QStringLiteral("problem"), problem);
    if (s.catalog) {
        const QDate made = QDateTime::fromString(s.catalog->generated, Qt::ISODate).date();
        out.insert(QStringLiteral("inUse"), true);
        out.insert(QStringLiteral("date"), view::dayText(made, m_formats, false));
        out.insert(QStringLiteral("old"), made.isValid() && made.daysTo(QDate::currentDate()) > kOldDays);
    }
    return out;
}

QVariantMap StoreBackend::appDataStatus() const
{
    QString origin = QStringLiteral("none");
    if (m_snapshot && m_snapshot->appstream.origin == AppStreamData::Origin::Installed)
        origin = QStringLiteral("installed");
    else if (m_snapshot && m_snapshot->appstream.origin == AppStreamData::Origin::Fetched)
        origin = QStringLiteral("fetched");
    return {{QStringLiteral("origin"), origin}, {QStringLiteral("problem"), m_snapshot ? m_snapshot->appstreamProblem : QString()}};
}

QVariantMap StoreBackend::sources() const
{
    return {{QStringLiteral("aur"), m_aur},
            {QStringLiteral("flathub"), m_flathub},
            {QStringLiteral("flatpak"), !env::flatpak().isEmpty()},
            {QStringLiteral("flathubReady"), m_flathub && m_snapshot && m_snapshot->flathubAdded},
            {QStringLiteral("flathubProblem"), m_flathub && m_snapshot ? m_snapshot->flathubProblem : QString()},
            // Why "Get Flatpak…" cannot run now, or "" (SD24); "installed" once flatpak is there.
            {QStringLiteral("getFlatpak"), m_snapshot ? getFlatpakBlock() : QStringLiteral("loading")},
            // Whether this session's launcher sees the Flatpaks' entries (from the login after flatpak's install, S20).
            {QStringLiteral("flatpakSession"), env::flatpakExportsSeen()},
            {QStringLiteral("screenshots"), m_screenshots}};
}

QVariantMap StoreBackend::readConfig() const
{
    QVariantMap out{{QStringLiteral("exists"), false}, {QStringLiteral("ok"), false}, {QStringLiteral("text"), QString()}};
    const QFileInfo info(configFile());
    if (!info.exists())
        return out;
    out.insert(QStringLiteral("exists"), true);
    // A regular file (a link to one is followed) of at most 1 MiB, read whole; anything else is not used, nothing written.
    if (!info.isFile() || info.size() > kConfigMax)
        return out;
    QFile f(info.filePath());
    if (!f.open(QIODevice::ReadOnly))
        return out;
    const QByteArray text = f.read(kConfigMax + 1);
    if (text.size() != info.size())
        return out;
    out.insert(QStringLiteral("text"), QString::fromUtf8(text));
    out.insert(QStringLiteral("ok"), true);
    return out;
}

QString StoreBackend::writeConfig(const QString &text) const
{
    const QByteArray bytes = text.toUtf8();
    if (bytes.size() > kConfigMax)
        return QStringLiteral("too large");
    const QString file = configFile();
    if (!QDir().mkpath(QFileInfo(file).absolutePath()))
        return QStringLiteral("cannot create its folder");
    QSaveFile f(file);
    if (!f.open(QIODevice::WriteOnly) || f.write(bytes) != bytes.size())
        return f.errorString();
    return f.commit() ? QString() : f.errorString();
}

QObject *StoreBackend::focusWindow() const
{
    return guiApp() ? QGuiApplication::focusWindow() : nullptr;
}

QVariantList StoreBackend::sections() const
{
    if (!m_snapshot)
        return {};
    const Snapshot &s = *m_snapshot;
    QVariantList out = s.catalog ? view::sections(*s.catalog, s.apps, s.index, s.tints, m_language) : QVariantList();
    const bool hasDiscover = !out.isEmpty() && out.constFirst().toMap().value(QStringLiteral("id")) == QLatin1String("discover");
    if (!hasDiscover)
        out.prepend(view::builtInDiscover(s.apps, s.categories(), m_language));
    return out;
}

QVariantList StoreBackend::categories() const
{
    QVariantList out;
    if (!m_snapshot)
        return out;
    for (const CatalogCategory &c : m_snapshot->categories()) {
        const int count = int(appsInCategory(m_snapshot->apps, c.id).size());
        if (count == 0)
            continue;
        out.append(QVariantMap{{QStringLiteral("id"), c.id},
                               {QStringLiteral("title"), c.title.pick(m_language)},
                               {QStringLiteral("symbol"), c.symbol},
                               {QStringLiteral("count"), count}});
    }
    return out;
}

QVariantList StoreBackend::categoryApps(const QString &id, const QString &kind) const
{
    QVariantList out;
    if (!m_snapshot)
        return out;
    for (const int i : appsInCategory(m_snapshot->apps, id)) {
        const StoreApp &a = m_snapshot->apps.at(i);
        if (kind.isEmpty() || view::sourceKind(a.source) == kind)
            out.append(view::summary(a, m_language));
    }
    return out;
}

QVariantList StoreBackend::search(const QString &query) const
{
    QVariantList out;
    if (!m_snapshot)
        return out;
    for (const int i : searchApps(m_snapshot->apps, query, m_language))
        out.append(view::summary(m_snapshot->apps.at(i), m_language));
    return out;
}

void StoreBackend::searchAsync(const QString &query)
{
    const int generation = ++m_searchGeneration;
    const std::shared_ptr<const Snapshot> snapshot = m_snapshot;
    const QString language = m_language;
    StoreBackend *const self = this;
    // Only the latest query matters: one that waits for the thread is replaced (the pool's queue keeps its last job only).
    m_searchPool.clear();
    m_searchPool.start([self, generation, snapshot, language, query] {
        QVariantList out;
        if (snapshot && generation == self->m_searchGeneration.load()) {
            for (const int i : searchApps(snapshot->apps, query, language))
                out.append(view::summary(snapshot->apps.at(i), language));
        }
        QMetaObject::invokeMethod(&self->m_context, [self, generation, query, out] {
            if (generation == self->m_searchGeneration.load())
                emit self->searchResults(query, out);
        }, Qt::QueuedConnection);
    });
}

QVariantMap StoreBackend::app(const QString &id) const
{
    const StoreApp *a = storeApp(id);
    if (!m_snapshot || !a)
        return {};
    const QList<AppStreamComponent> &components = a->source == CatalogSource::Kind::Flatpak ? m_snapshot->flathub.components
                                                                                            : m_snapshot->appstream.components;
    const AppStreamComponent *c = a->component >= 0 && a->component < components.size() ? &components.at(a->component) : nullptr;
    QVariantMap out = view::detail(*a, c, m_snapshot->categories(), m_language, m_formats);
    // The AUR's facts (SR11): those of its info answer once asked (requestAur), a search's until then.
    if (a->source == CatalogSource::Kind::Aur) {
        const auto it = m_aurPackages.constFind(a->package);
        out.insert(QStringLiteral("aur"), it == m_aurPackages.cend() ? QVariantMap() : view::aurFacts(*it, m_formats));
        out.insert(QStringLiteral("aurRead"), m_aurFull.contains(a->package));
        out.insert(QStringLiteral("aurUnknown"), m_aurUnknown.contains(a->package));
    }
    return out;
}

void StoreBackend::requestPackageInfo(const QString &package)
{
    if (!isPackageName(package))
        return;
    const QLocale locale = m_formats;
    const QString program = env::pacman();
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    m_pool.start([this, package, program, locale, cancel] {
        const FetchCancelScope fetchScope(cancel); // SU-07: a quit aborts its transfers
        const std::optional<PackageInfo> info = Pacman(program).info(package);
        if (*cancel)
            return;
        const QVariantMap facts = info ? view::packageFacts(*info, locale) : QVariantMap();
        QMetaObject::invokeMethod(&m_context, [this, package, facts] { emit packageInfo(package, facts); }, Qt::QueuedConnection);
    });
}

QVariantList StoreBackend::installed() const
{
    QVariantList out;
    if (!m_snapshot)
        return out;
    const Snapshot &s = *m_snapshot;
    QVariantList arch, omarchy, setups, webApps, foreign, flatpaks;
    QSet<QString> catalogWebUrls;
    for (const StoreApp &a : s.apps) {
        if (!a.installed)
            continue;
        QVariantMap m = view::summary(a, m_language);
        m.insert(QStringLiteral("page"), true);
        if (a.source == CatalogSource::Kind::Repo && s.explicitPackages.contains(a.package))
            (a.repo == QLatin1String("omarchy") ? omarchy : arch).append(m);
        else if (a.source == CatalogSource::Kind::OmarchySetup)
            setups.append(m);
        else if (a.source == CatalogSource::Kind::WebApp && a.entry) {
            webApps.append(m);
            catalogWebUrls.insert(a.entry->source.url);
        } else if (a.source == CatalogSource::Kind::Flatpak) {
            flatpaks.append(m);
        }
    }
    // The user's Flatpaks Flathub's AppStream does not have (another remote's, or gone from Flathub): opened, removed.
    if (m_flathub) {
        QStringList others;
        for (const QString &app : s.flatpaks) {
            if (!s.index.contains(app))
                others.append(app);
        }
        others.sort();
        for (const QString &app : others) {
            flatpaks.append(QVariantMap{{QStringLiteral("id"), QStringLiteral("flatpak:") + app},
                                        {QStringLiteral("name"), app},
                                        {QStringLiteral("flatpakId"), app},
                                        {QStringLiteral("summary"), QString()},
                                        {QStringLiteral("icon"), QString()},
                                        {QStringLiteral("kind"), QStringLiteral("flatpak")},
                                        {QStringLiteral("installed"), true},
                                        {QStringLiteral("launcher"), true},
                                        {QStringLiteral("page"), false}});
        }
    }
    for (const view::WebAppEntry &w : s.webApps) {
        if (catalogWebUrls.contains(w.url))
            continue;
        webApps.append(QVariantMap{{QStringLiteral("id"), QStringLiteral("webapp:") + w.file},
                                   {QStringLiteral("name"), w.name},
                                   {QStringLiteral("summary"), QUrl(w.url).host()},
                                   {QStringLiteral("icon"), w.icon.isEmpty() ? QString() : QUrl::fromLocalFile(w.icon).toString()},
                                   {QStringLiteral("kind"), QStringLiteral("webapp")},
                                   {QStringLiteral("installed"), true},
                                   {QStringLiteral("launcher"), true},
                                   {QStringLiteral("page"), false}});
    }
    // Installed explicitly from outside the repositories and known to the AUR (asked once it is on): "AUR", with their page.
    QVariantList aur;
    QSet<QString> shown;
    if (m_aur) {
        for (const QString &n : s.foreign) {
            const auto it = m_aurApps.constFind(QStringLiteral("aur:") + n);
            if (it == m_aurApps.cend() || !s.explicitPackages.contains(n) || n.startsWith(QLatin1String("grassfield")))
                continue;
            QVariantMap m = view::summary(*it, m_language);
            m.insert(QStringLiteral("page"), true);
            aur.append(m);
            shown.insert(n);
        }
    }
    QStringList names(s.foreignWithEntry.cbegin(), s.foreignWithEntry.cend());
    names.removeIf([&shown](const QString &n) { return shown.contains(n); });
    names.sort();
    for (const QString &n : names) {
        foreign.append(QVariantMap{{QStringLiteral("id"), QStringLiteral("package:") + n},
                                   {QStringLiteral("name"), n},
                                   {QStringLiteral("summary"), QString()},
                                   {QStringLiteral("icon"), QString()},
                                   {QStringLiteral("kind"), QStringLiteral("foreign")},
                                   {QStringLiteral("installed"), true},
                                   {QStringLiteral("launcher"), true},
                                   {QStringLiteral("page"), false}});
    }
    const QCollator collator(m_formats); // our own, as view::detail's (storeview.cpp)
    const auto byName = [&collator](QVariantList &list) {
        std::stable_sort(list.begin(), list.end(), [&collator](const QVariant &a, const QVariant &b) {
            return collator.compare(a.toMap().value(QStringLiteral("name")).toString(),
                                    b.toMap().value(QStringLiteral("name")).toString()) < 0;
        });
    };
    for (auto [group, list] : {std::pair{QStringLiteral("arch"), &arch}, std::pair{QStringLiteral("omarchy"), &omarchy},
                               std::pair{QStringLiteral("setup"), &setups}, std::pair{QStringLiteral("webapp"), &webApps},
                               std::pair{QStringLiteral("flatpak"), &flatpaks}, std::pair{QStringLiteral("aur"), &aur},
                               std::pair{QStringLiteral("foreign"), &foreign}}) {
        if (list->isEmpty())
            continue;
        byName(*list);
        out.append(QVariantMap{{QStringLiteral("group"), group}, {QStringLiteral("apps"), *list}});
    }
    return out;
}

QVariantMap StoreBackend::updates() const
{
    // The shell's file parsed once per change of it (its size and time) and per snapshot (SU-12): the page's bindings read
    // this at every updatesChanged.
    const QFileInfo file(env::softwareUpdateFile());
    const qint64 size = file.exists() ? file.size() : -2;
    // Its change time too: the shell writes it by rename (a new inode, a new change time even at the same size and second).
    const QDateTime modified = file.exists() ? qMax(file.lastModified(), file.fileTime(QFileDevice::FileMetadataChangeTime)) : QDateTime();
    if (m_updatesFile_.size != size || m_updatesFile_.modified != modified || m_updatesFile_.revision != m_revision) {
        const QByteArray json = readSmall(env::softwareUpdateFile(), 512 * 1024);
        m_updatesFile_.parsed = view::updates(json, m_snapshot ? m_snapshot->apps : QList<StoreApp>(), m_language, m_formats);
        m_updatesFile_.size = size;
        m_updatesFile_.modified = modified;
        m_updatesFile_.revision = m_revision;
    }
    QVariantMap u = m_updatesFile_.parsed;
    const QString state = u.value(QStringLiteral("state")).toString();
    // Omarchy's update lock held by another program (Software Update's run, omarchy update; the Store's own operation holds
    // it too, and is not an update), or the checker saw one.
    const bool running = m_lockHeld || state == QLatin1String("update-running") || state == QLatin1String("busy");
    u.insert(QStringLiteral("checking"), m_systemChecking);
    u.insert(QStringLiteral("askFailed"), m_askFailed);
    u.insert(QStringLiteral("running"), running);
    u.insert(QStringLiteral("unfinished"), running ? 0 : m_unfinished);
    QVariantList apps;
    int runtimes = 0;
    const bool on = m_flathub && flatpakBlock() != QLatin1String("noFlatpak");
    for (const FlatpakUpdate &f : on ? m_flatpakUpdates : QList<FlatpakUpdate>()) {
        if (!f.app) {
            ++runtimes;
            continue;
        }
        const StoreApp *a = flatpakApp(f.id);
        QVariantMap m = a ? view::summary(*a, m_language)
                          : QVariantMap{{QStringLiteral("id"), QStringLiteral("flatpak:") + f.id}, {QStringLiteral("name"), f.id},
                                        {QStringLiteral("summary"), QString()}, {QStringLiteral("icon"), QString()},
                                        {QStringLiteral("kind"), QStringLiteral("flatpak")}, {QStringLiteral("installed"), true},
                                        {QStringLiteral("launcher"), true}};
        m.insert(QStringLiteral("ref"), f.ref);
        m.insert(QStringLiteral("page"), a != nullptr);
        // What its update changes (ADR-0049), once read: an update that asks for more, or could not be read, waits for its
        // own Update.
        if (const auto r = m_flatpakReview.constFind(f.ref); r != m_flatpakReview.cend()) {
            m.insert(QStringLiteral("asksForMore"), r->asks || r->unknown);
            m.insert(QStringLiteral("permissionsUnknown"), r->unknown);
            m.insert(QStringLiteral("permissionChanges"), r->changes);
        }
        apps.append(m);
    }
    // An update's plan running (each app's commit and access read, SD33): how many apps it checked, of how many.
    QVariant planning;
    if (!m_updatePlanning.isEmpty()) {
        int done = 0, total = 0;
        for (const auto &p : m_updatePlanning) {
            done += p.first;
            total += p.second;
        }
        planning = QVariantMap{{QStringLiteral("done"), done}, {QStringLiteral("total"), total}};
    }
    u.insert(QStringLiteral("flatpak"), QVariantMap{{QStringLiteral("on"), on},
                                                    {QStringLiteral("state"), m_flatpakUpdatesState},
                                                    {QStringLiteral("apps"), apps},
                                                    {QStringLiteral("runtimes"), runtimes},
                                                    {QStringLiteral("planning"), planning},
                                                    {QStringLiteral("block"), m_updatePlanning.contains(kFlatpakUpdatesApp) ? QStringLiteral("checking")
                                                                                                                             : flatpakUpdateBlock()}});
    u.insert(QStringLiteral("count"), int(u.value(QStringLiteral("apps")).toList().size() + apps.size()));
    return u;
}

void StoreBackend::checkUpdates()
{
    askShellToCheck();
    readUnfinished();
    checkFlatpakUpdates();
}

void StoreBackend::updatesShown(bool shown)
{
    if (!shown) {
        m_updatesPoll.stop();
        return;
    }
    // As Settings' pane (ADR-0033 U8): a check when it opens, unless one finished less than a minute ago.
    const QJsonObject file = QJsonDocument::fromJson(readSmall(env::softwareUpdateFile(), 512 * 1024)).object();
    const QDateTime checked = QDateTime::fromString(file.value(QStringLiteral("checkedAt")).toString(), Qt::ISODate);
    if (!checked.isValid() || checked.secsTo(QDateTime::currentDateTimeUtc()) > 60)
        askShellToCheck();
    readUnfinished();
    if (!m_flatpakCheckedAt.isValid() || m_flatpakCheckedAt.secsTo(QDateTime::currentDateTimeUtc()) > 60)
        checkFlatpakUpdates();
    followUpdates();
    m_updatesPoll.start();
}

void StoreBackend::askShellToCheck()
{
    if (m_systemChecking)
        return;
    const QStringList ipc = apps::runmode::shellIpcArgs();
    if (ipc.isEmpty()) {
        m_askFailed = true; // a dev session that names no shell: the installed one is never driven from it
        emit updatesChanged();
        return;
    }
    m_systemChecking = true;
    m_askFailed = false;
    m_askedCheckedAt = QJsonDocument::fromJson(readSmall(env::softwareUpdateFile(), 512 * 1024)).object().value(QStringLiteral("checkedAt")).toString();
    m_checkDeadline.start();
    emit updatesChanged();
    // `qs ipc -p <shell> call update check user` (ADR-0033 d.7; the shell's IPC names the Store a caller, docs/specs/security.md),
    // the shell named by its directory, never by QS_* (runChild passes none); the shell's check writes the file.
    ChildOptions options;
    options.timeoutMs = apps::runmode::kShellIpcMs;
    options.maxOut = 64 * 1024;
    const QProcessEnvironment system = QProcessEnvironment::systemEnvironment();
    for (const char *key : {"HOME", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
                            "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY"}) {
        if (system.contains(QLatin1String(key)))
            options.extraEnv.insert(QLatin1String(key), system.value(QLatin1String(key)));
    }
    const QString program = env::shellProgram();
    const QStringList args = ipc + QStringList{QStringLiteral("update"), QStringLiteral("check"), QStringLiteral("user")};
    options.cancel = m_cancel;
    StoreBackend *const self = this; // its jobs end before it is gone (SU-14: m_context)
    m_updatePool.start([self, program, args, options] {
        const ChildResult r = runChild(program, args, options);
        const bool asked = r.ok() && r.out.trimmed() == "ok";
        QMetaObject::invokeMethod(&self->m_context, [self, asked] {
            if (!self || asked)
                return; // the shell checks: its answer is the file
            self->m_systemChecking = false;
            self->m_askFailed = true;
            self->m_checkDeadline.stop();
            emit self->updatesChanged();
        });
    });
}

void StoreBackend::readUnfinished()
{
    // pacman -Qu while no update runs (S12): packages the last system update did not install (exit 1 when there are none).
    const QString pacman = env::pacman();
    ChildOptions options;
    options.cancel = m_cancel;
    StoreBackend *const self = this; // its jobs end before it is gone (SU-14: m_context)
    m_updatePool.start([self, pacman, options] {
        const ChildResult r = runChild(pacman, {QStringLiteral("-Qu")}, options);
        const int count = r.started && !r.timedOut && !r.overflow && (r.exitCode == 0 || r.exitCode == 1)
            ? int(unfinishedUpdates(r.out).size())
            : 0;
        QMetaObject::invokeMethod(&self->m_context, [self, count] {
            if (!self || self->m_unfinished == count)
                return;
            self->m_unfinished = count;
            emit self->updatesChanged();
        });
    });
}

void StoreBackend::checkFlatpakUpdates()
{
    if (!m_flathub || !flatpakBlock().isEmpty() || m_flatpakUpdatesState == QLatin1String("checking"))
        return;
    m_flatpakUpdatesState = QStringLiteral("checking");
    emit updatesChanged();
    const FlatpakTools tools = flatpakTools();
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    StoreBackend *const self = this; // its jobs end before it is gone (SU-14: m_context)
    m_updatePool.start([self, tools, cancel] {
        const FetchCancelScope fetchScope(cancel); // SU-07: a quit aborts its transfers
        const std::optional<QList<FlatpakUpdate>> all = listFlatpakUpdates(tools);
        if (*cancel)
            return;
        QMetaObject::invokeMethod(&self->m_context, [self, all] {
            if (!self)
                return;
            self->m_flatpakCheckedAt = QDateTime::currentDateTimeUtc();
            if (all) {
                // Flathub's only: the Store updates what it installs (another remote's apps are the user's own).
                self->m_flatpakUpdates.clear();
                for (const FlatpakUpdate &u : *all) {
                    if (u.origin == kFlathubRemote)
                        self->m_flatpakUpdates.append(u);
                }
            }
            self->m_flatpakUpdatesState = all ? QString() : QStringLiteral("failed");
            ++self->m_revision; // the buttons' Update
            emit self->updatesChanged();
            emit self->revisionChanged(); // the buttons only: no page reads its data again (SU-06)
            if (all)
                self->reviewFlatpakUpdates();
        });
    });
}

void StoreBackend::reviewFlatpakUpdates()
{
    // The reviews of refs no longer listed go; the others stay until this review replaces them.
    QSet<QString> listed;
    QStringList refs;
    for (const FlatpakUpdate &u : std::as_const(m_flatpakUpdates)) {
        listed.insert(u.ref);
        if (u.app && isFlatpakAppRef(u.ref))
            refs.append(u.ref);
    }
    for (auto it = m_flatpakReview.begin(); it != m_flatpakReview.end();) {
        if (listed.contains(it.key()))
            ++it;
        else
            it = m_flatpakReview.erase(it);
    }
    if (refs.isEmpty() || !flatpakUpdateBlock().isEmpty())
        return;
    const int generation = ++m_reviewGeneration;
    const FlatpakTools tools = flatpakTools();
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    StoreBackend *const self = this; // its jobs end before it is gone (SU-14: m_context)
    m_updatePool.start([self, generation, refs, tools, cancel] {
        const FetchCancelScope fetchScope(cancel); // SU-07: a quit aborts its transfers
        for (const QString &ref : refs) {
            if (*cancel)
                return;
            const QString commit = flatpakRemoteCommit(tools, ref);
            const std::optional<QList<FlatpakPermissionChange>> changes = commit.isEmpty() ? std::nullopt
                                                                                           : flatpakPermissionChanges(tools, ref, commit);
            FlatpakReview review;
            review.unknown = !changes;
            review.asks = changes && asksForMore(*changes);
            if (changes)
                review.changes = view::permissionChanges(*changes);
            QMetaObject::invokeMethod(&self->m_context, [self, generation, ref, review] {
                if (!self || generation != self->m_reviewGeneration)
                    return;
                if (std::none_of(self->m_flatpakUpdates.cbegin(), self->m_flatpakUpdates.cend(), [&ref](const FlatpakUpdate &u) { return u.ref == ref; }))
                    return; // no longer listed
                self->m_flatpakReview.insert(ref, review);
                emit self->updatesChanged();
            });
        }
    });
}

void StoreBackend::followUpdates()
{
    const QByteArray json = readSmall(env::softwareUpdateFile(), 512 * 1024);
    const bool held = !m_operations->running() && lockHeld(env::updateLock());
    bool moved = json != m_updatesFile || held != m_lockHeld;
    m_updatesFile = json;
    m_lockHeld = held;
    // The shell's answer: a checkedAt other than the one before the question.
    if (m_systemChecking && QJsonDocument::fromJson(json).object().value(QStringLiteral("checkedAt")).toString() != m_askedCheckedAt) {
        m_systemChecking = false;
        m_checkDeadline.stop();
        moved = true;
    }
    if (moved)
        emit updatesChanged();
}

const StoreApp *StoreBackend::flatpakApp(const QString &flatpakId) const
{
    if (!m_snapshot)
        return nullptr;
    for (const StoreApp &a : m_snapshot->apps) {
        if (a.source == CatalogSource::Kind::Flatpak && flatpakRefId(a.flatpakRef) == flatpakId)
            return &a;
    }
    return nullptr;
}

std::optional<FlatpakUpdate> StoreBackend::flatpakUpdateOf(const QString &id) const
{
    // An app id: a Flathub app of the model, or "flatpak:<app id>" for one its AppStream does not have.
    QString flatpakId = id.startsWith(QLatin1String("flatpak:")) ? id.mid(8) : QString();
    if (flatpakId.isEmpty()) {
        const StoreApp *a = storeApp(id);
        if (!a || a->source != CatalogSource::Kind::Flatpak)
            return std::nullopt;
        flatpakId = flatpakRefId(a->flatpakRef);
    }
    if (!m_flathub)
        return std::nullopt;
    for (const FlatpakUpdate &u : m_flatpakUpdates) {
        if (u.app && u.id == flatpakId)
            return u;
    }
    return std::nullopt;
}

QString StoreBackend::flatpakUpdateBlock() const
{
    if (const QString block = flatpakBlock(); !block.isEmpty())
        return block;
    return m_online ? QString() : QStringLiteral("offline");
}

void StoreBackend::planFlatpakUpdate(const QString &id)
{
    const QString kind = QStringLiteral("update");
    if (m_updatePlanning.contains(id))
        return; // its plan runs: its answer goes to the sheet that waits
    QStringList refs;
    if (id == kFlatpakUpdatesApp) {
        for (const FlatpakUpdate &u : m_flatpakUpdates)
            refs.append(u.ref); // all of them (kMaxFlatpakUpdates at most, as the check lists them): one operation
    } else if (const std::optional<FlatpakUpdate> u = flatpakUpdateOf(id)) {
        refs.append(u->ref);
    }
    const QString block = refs.isEmpty() ? QStringLiteral("none") : flatpakUpdateBlock();
    if (!block.isEmpty() || m_operations->queued(id)) {
        m_updatePlans.remove(id);
        emit planReady(id, kind, {{QStringLiteral("refusal"), QStringLiteral("unavailable")}, {QStringLiteral("detail"), block.isEmpty() ? QStringLiteral("queued") : block}});
        return;
    }
    // What each app's update changes in what it may reach (SD25 for an update, ADR-0049): flatpak's --noninteractive accepts
    // more silently, so an update that asks for more (or whose metadata could not be read) is never applied unasked: its
    // own Update says it first, and Update All leaves it out ("Asks for more" on the list). Narrower or removed grants
    // apply as any update. The commit read is the one checked and the one the update deploys (S32: a newer commit
    // published meanwhile is listed again and asked about again, never taken silently).
    QList<std::pair<QString, QString>> apps; // ref, name
    for (const QString &ref : refs) {
        if (!isFlatpakAppRef(ref))
            continue;
        const StoreApp *a = flatpakApp(flatpakRefId(ref));
        apps.append({ref, a ? a->name.pick(m_language) : flatpakRefId(ref)});
    }
    const bool all = id == kFlatpakUpdatesApp;
    m_updatePlanning.insert(id, {0, int(apps.size())});
    ++m_revision; // its button says it is checked
    emit updatesChanged();
    emit revisionChanged();
    const FlatpakTools tools = flatpakTools();
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    StoreBackend *const self = this; // its jobs end before it is gone (SU-14: m_context)
    m_updatePool.start([self, id, kind, refs, apps, all, tools, cancel] {
        const FetchCancelScope fetchScope(cancel); // SU-07: a quit aborts its transfers
        QVariantList changed;
        QStringList unknown, held;
        QSet<QString> heldRefs;
        bool asks = false;
        QHash<QString, QString> pinned, installedThen;
        int done = 0;
        for (const auto &[ref, name] : apps) {
            if (*cancel)
                return;
            const QString commit = flatpakRemoteCommit(tools, ref);
            const std::optional<QList<FlatpakPermissionChange>> changes = commit.isEmpty() ? std::nullopt
                                                                                           : flatpakPermissionChanges(tools, ref, commit);
            const bool more = !changes || asksForMore(*changes);
            if (!changes)
                unknown.append(name);
            else if (!changes->isEmpty())
                changed.append(QVariantMap{{QStringLiteral("name"), name},
                                           {QStringLiteral("asks"), more},
                                           {QStringLiteral("changes"), view::permissionChanges(*changes)}});
            if (more && all) {
                held.append(name); // Update All never takes it: its own Update asks
                heldRefs.insert(ref);
            } else if (more) {
                asks = true;
            }
            if (!commit.isEmpty()) {
                pinned.insert(ref, commit);
                installedThen.insert(ref, flatpakInstalledCommit(tools, ref));
            }
            QMetaObject::invokeMethod(&self->m_context, [self, id, done = ++done] {
                if (!self || !self->m_updatePlanning.contains(id))
                    return;
                self->m_updatePlanning[id].first = done;
                emit self->updatesChanged();
            });
        }
        if (*cancel)
            return;
        UpdatePlan plan;
        for (const QString &ref : refs) {
            if (heldRefs.contains(ref))
                continue;
            plan.refs.append(ref);
            plan.commits.append(pinned.value(ref));
            plan.fromCommits.append(installedThen.value(ref));
        }
        // Update All with every app held and no runtime left: nothing it may do alone.
        const bool nothing = plan.refs.isEmpty();
        const QVariantMap out{{QStringLiteral("refusal"), nothing ? QStringLiteral("unavailable") : QString()},
                              {QStringLiteral("detail"), nothing ? QStringLiteral("held") : QString()},
                              {QStringLiteral("refs"), int(plan.refs.size())},
                              {QStringLiteral("asks"), asks},
                              {QStringLiteral("changed"), changed},
                              {QStringLiteral("unknown"), unknown},
                              {QStringLiteral("held"), held}};
        QMetaObject::invokeMethod(&self->m_context, [self, id, kind, plan, out, nothing] {
            if (!self)
                return;
            self->m_updatePlanning.remove(id);
            if (nothing)
                self->m_updatePlans.remove(id);
            else
                self->m_updatePlans.insert(id, plan);
            ++self->m_revision;
            emit self->updatesChanged();
            emit self->revisionChanged();
            emit self->planReady(id, kind, out);
        });
    });
}

bool StoreBackend::update(const QString &id)
{
    // The refs its plan checked, each with the commit it checked, still listed (a check since may have found them updated),
    // and nothing queued for it.
    const auto it = m_updatePlans.constFind(id);
    if (it == m_updatePlans.cend() || m_operations->queued(id) || !flatpakUpdateBlock().isEmpty())
        return false;
    QStringList refs, commits, fromCommits;
    for (qsizetype i = 0; i < it->refs.size(); ++i) {
        const QString &ref = it->refs.at(i);
        if (std::any_of(m_flatpakUpdates.cbegin(), m_flatpakUpdates.cend(), [&ref](const FlatpakUpdate &u) { return u.ref == ref; })) {
            refs.append(ref);
            commits.append(it->commits.value(i));
            fromCommits.append(it->fromCommits.value(i));
        }
    }
    m_updatePlans.remove(id);
    if (refs.isEmpty())
        return false;
    OperationRecord r;
    r.id = newOperationId();
    r.kind = QStringLiteral("update");
    r.app = id;
    r.path = QStringLiteral("flatpak");
    r.packages = refs;
    r.commits = commits;
    r.fromCommits = fromCommits;
    if (id == kFlatpakUpdatesApp) {
        r.name = QCoreApplication::translate("StoreBackend", "Flatpak apps");
    } else {
        r.flatpak = refs.first();
        const StoreApp *a = storeApp(id);
        r.name = a ? a->name.pick(m_language) : flatpakRefId(r.flatpak);
    }
    m_operations->enqueue(r);
    return true;
}

QVariantMap StoreBackend::typeSearch(const QString &type) const
{
    const QString asked = type.trimmed().toLower();
    if (!isMediaType(asked))
        return {};
    // The type, then its parents as the MIME database orders them (a C file: text/x-csrc, then text/plain); never
    // application/octet-stream (any file).
    QMimeDatabase db;
    const QMimeType mime = db.mimeTypeForName(asked);
    QStringList types{asked};
    if (mime.isValid()) {
        for (const QString &parent : mime.allAncestors()) {
            const QString p = parent.toLower();
            if (p != QLatin1String("application/octet-stream") && isMediaType(p) && !types.contains(p))
                types.append(p);
        }
    }
    QVariantList apps;
    if (m_snapshot) {
        for (const int i : appsForType(m_snapshot->apps, types))
            apps.append(view::summary(m_snapshot->apps.at(i), m_language));
    }
    return {{QStringLiteral("type"), asked},
            {QStringLiteral("description"), mime.isValid() && !mime.comment().isEmpty() ? cleanPlainText(mime.comment(), 128, false) : asked},
            {QStringLiteral("apps"), apps}};
}

bool StoreBackend::openLink(const QString &url)
{
    // A product page's links (SR11): https only, through the user's browser; never from a dev session (ADR-0019).
    if (!isHttpsUrl(url) || devSession())
        return false;
    return apps::startApplication(QStringLiteral("xdg-open"), {url});
}

QString StoreBackend::screenshotSource(const QString &url) const
{
    if (!screenshotsAllowed() || !isHttpsUrl(url))
        return {};
    return QStringLiteral("image://screenshot/") + QString::fromLatin1(QUrl::toPercentEncoding(url));
}

QVariantList StoreBackend::operations() const
{
    return m_operations->list();
}

QVariantMap StoreBackend::results() const
{
    QVariantMap out;
    const auto all = m_operations->results();
    for (auto it = all.cbegin(); it != all.cend(); ++it) {
        out.insert(it.key(), QVariantMap{{QStringLiteral("kind"), it->kind},
                                         {QStringLiteral("name"), it->record.name},
                                         {QStringLiteral("outcome"), it->outcome},
                                         {QStringLiteral("present"), it->present},
                                         {QStringLiteral("total"), it->total},
                                         {QStringLiteral("details"), it->details},
                                         // "aur" for the AUR's commands: their messages say so (Store.js).
                                         {QStringLiteral("source"), it->record.recipe == kAurAdd || it->record.recipe == kAurDrop ? QStringLiteral("aur")
                                                                    : it->record.recipe == kFlatpakAdd                         ? QStringLiteral("getFlatpak")
                                                                    : it->record.path == QLatin1String("flatpak")              ? QStringLiteral("flatpak")
                                                                                                                                : QString()}});
    }
    return out;
}

void StoreBackend::checkStaleLock()
{
    // db.lck there and no pacman running (its process name, /proc/<pid>/comm): pacman stopped mid-way (S6). The walk of
    // /proc runs on a worker (SU-12); a lock that is not there is answered at once.
    const QString lock = env::dbLock();
    if (!QFileInfo::exists(lock)) {
        if (m_staleLock) {
            m_staleLock = false;
            emit operationsChanged();
        }
        return;
    }
    if (m_staleChecking)
        return;
    m_staleChecking = true;
    const bool walk = env::fixture().isEmpty();
    m_pool.start([this, lock, walk] {
        bool stale = QFileInfo::exists(lock);
        if (stale && walk) {
            QDirIterator it(QStringLiteral("/proc"), QDir::Dirs | QDir::NoDotAndDotDot);
            while (stale && it.hasNext()) {
                const QString dir = it.next();
                if (QFileInfo(dir).fileName().toLongLong() > 0 && readSmall(dir + QStringLiteral("/comm"), 64).trimmed() == "pacman")
                    stale = false;
            }
        }
        QMetaObject::invokeMethod(&m_context, [this, stale] {
            m_staleChecking = false;
            if (stale != m_staleLock) {
                m_staleLock = stale;
                emit operationsChanged();
            }
        }, Qt::QueuedConnection);
    });
}

bool StoreBackend::executable(const QString &path) const
{
    const auto it = m_executable.constFind(path);
    if (it != m_executable.cend())
        return *it;
    const bool can = QFileInfo(path).isExecutable();
    m_executable.insert(path, can);
    return can;
}

bool StoreBackend::drain(int ms)
{
    *m_cancel = true;
    QDeadlineTimer deadline(ms);
    const auto left = [&deadline] { return int(qMax<qint64>(0, deadline.remainingTime())); };
    m_searchPool.clear();
    m_pool.clear();
    m_updatePool.clear();
    bool done = m_pool.waitForDone(left());
    done = m_updatePool.waitForDone(left()) && done;
    done = m_searchPool.waitForDone(left()) && done;
    if (m_operations)
        done = m_operations->drain(left()) && done;
    return done;
}

void StoreBackend::removalByEntryAsync(std::function<void(const QVariantMap &)> done)
{
    QVariantMap out = removalByEntry(false);
    if (!m_snapshot) {
        done(out);
        return;
    }
    // The entries of each repository app offered for removal, by package: one -Rs plan each, on the workers.
    QHash<QString, QStringList> byPackage;
    for (auto it = out.cbegin(); it != out.cend(); ++it) {
        const QVariantMap e = it.value().toMap();
        if (!e.value(QStringLiteral("block")).toString().isEmpty())
            continue;
        const StoreApp *a = storeApp(e.value(QStringLiteral("app")).toString());
        if (a && a->source == CatalogSource::Kind::Repo)
            byPackage[a->package].append(it.key());
    }
    if (byPackage.isEmpty()) {
        done(out);
        return;
    }
    struct Pending {
        QVariantMap out;
        int left = 0;
        std::function<void(const QVariantMap &)> done;
    };
    auto pending = std::make_shared<Pending>();
    pending->out = out;
    pending->left = int(byPackage.size());
    pending->done = std::move(done);
    const DenyList deny = m_snapshot->deny;
    const PlanTools tools = planTools();
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    for (auto it = byPackage.cbegin(); it != byPackage.cend(); ++it) {
        const QString package = it.key();
        const QStringList entries = it.value();
        m_pool.start([this, package, entries, deny, tools, cancel, pending] {
            QString block;
            if (!*cancel) {
                const RemovePlan plan = checkRemove({package}, deny, tools, false);
                if (plan.refusal == Refusal::Dependency)
                    block = QStringLiteral("dependency");
                else if (plan.refusal == Refusal::Protected)
                    block = QStringLiteral("protected");
                else if (plan.refusal == Refusal::Failed)
                    block = QStringLiteral("plan");
            }
            QMetaObject::invokeMethod(&m_context, [pending, entries, block] {
                if (!block.isEmpty()) {
                    for (const QString &entry : entries) {
                        QVariantMap e = pending->out.value(entry).toMap();
                        e.insert(QStringLiteral("block"), block);
                        pending->out.insert(entry, e);
                    }
                }
                if (--pending->left == 0)
                    pending->done(pending->out);
            }, Qt::QueuedConnection);
        });
    }
}

std::optional<view::WebAppEntry> StoreBackend::otherWebApp(const QString &id) const
{
    if (!m_snapshot || !id.startsWith(QLatin1String("webapp:")))
        return std::nullopt;
    const QString file = id.mid(7);
    for (const view::WebAppEntry &w : m_snapshot->webApps) {
        if (w.file == file && isWebAppName(w.file) && isHttpsUrl(w.url))
            return w;
    }
    return std::nullopt;
}

const StoreApp *StoreBackend::storeApp(const QString &id) const
{
    if (id.startsWith(QLatin1String("aur:"))) {
        const auto it = m_aurApps.constFind(id);
        return m_aur && it != m_aurApps.cend() ? &*it : nullptr;
    }
    if (!m_snapshot || !m_snapshot->index.contains(id))
        return nullptr;
    return &m_snapshot->apps.at(m_snapshot->index.value(id));
}

QString StoreBackend::getBlock(const StoreApp &a) const
{
    switch (a.source) {
    case CatalogSource::Kind::Repo:
        if (env::pkexec().isEmpty())
            return QStringLiteral("dev");
        if (!apps::runmode::dev() && (!executable(env::helperPath) || !executable(env::pkexec())))
            return QStringLiteral("missing");
        break;
    case CatalogSource::Kind::WebApp:
        if (apps::runmode::dev() && env::installer().isEmpty())
            return QStringLiteral("dev");
        if (!apps::runmode::dev() && !executable(env::omarchyCommand(QStringLiteral("omarchy-webapp-install"))))
            return QStringLiteral("missing");
        if (!a.entry)
            return QStringLiteral("source");
        if (a.icon.isEmpty())
            return QStringLiteral("icon"); // its icon is not cached yet (fetched with the catalog)
        break;
    case CatalogSource::Kind::OmarchySetup:
        if (const QString block = terminalBlock(); !block.isEmpty())
            return block;
        break;
    case CatalogSource::Kind::Aur:
        if (!m_aur)
            return QStringLiteral("aurOff");
        if (m_snapshot && m_snapshot->syncNames.contains(a.package))
            return QStringLiteral("repository"); // yay would install the repository's: the Store does, from its page
        // Never a name of the deny list (b.1): what the Store could not remove it does not build, and the AUR is anyone's.
        if (m_snapshot && protection(a.package, m_snapshot->deny) != Protection::None)
            return QStringLiteral("aurProtected");
        if (m_snapshot && !m_snapshot->deny.omarchyRead())
            return QStringLiteral("listsMissing");
        if (const QString block = aurBlock(kAurAdd); !block.isEmpty())
            return block;
        break;
    case CatalogSource::Kind::Flatpak:
        // The ref is the model's (storemodel installableFlatpak): an app of a bad ref is never offered, and the plan
        // refuses one again (checkFlatpakInstall).
        if (const QString block = flatpakBlock(); !block.isEmpty())
            return block;
        break;
    }
    return m_online ? QString() : QStringLiteral("offline");
}

QString StoreBackend::flatpakBlock() const
{
    if (env::flatpak().isEmpty())
        return QStringLiteral("noFlatpak");
    if (apps::runmode::dev() && env::fixture().isEmpty())
        return QStringLiteral("dev");
    if (!m_flathub)
        return QStringLiteral("flathubOff");
    return {};
}

FlatpakTools StoreBackend::flatpakTools() const
{
    FlatpakTools tools;
    tools.flatpak = env::flatpak();
    tools.env = flatpakEnvironment();
    tools.cancel = m_cancel;
    return tools;
}

QString StoreBackend::otherFlatpak(const QString &id) const
{
    if (!m_snapshot || !m_flathub || !id.startsWith(QLatin1String("flatpak:")))
        return {};
    const QString app = id.mid(8);
    return m_snapshot->flatpaks.contains(app) && !m_snapshot->index.contains(app) ? app : QString();
}

QString StoreBackend::terminalBlock() const
{
    const QString launcher = QStringLiteral("omarchy-launch-floating-terminal-with-presentation");
    if (apps::runmode::dev() && env::installer().isEmpty())
        return QStringLiteral("dev");
    if (!apps::runmode::dev() && (!executable(env::omarchyCommand(launcher)) || !executable(env::runPath)))
        return QStringLiteral("missing");
    if (env::runDir().isEmpty())
        return QStringLiteral("missing");
    if (!m_snapshot || !m_snapshot->catalog || !m_snapshot->catalog->omarchy || !m_snapshot->omarchyDiffers.isEmpty())
        return QStringLiteral("omarchyChanged");
    return {};
}

QString StoreBackend::aurBlock(const QString &command) const
{
    // The catalog does not vouch for the AUR's command: grassfield-packages pins it.
    return pinnedBlock(command, QStringLiteral("aurUnchecked"));
}

QString StoreBackend::pinnedBlock(const QString &command, const QString &unchecked) const
{
    if (const QString block = terminalBlock(); !block.isEmpty())
        return block;
    const auto &pins = m_snapshot->catalog->omarchy->files;
    for (const QString &path : requiredPins(command)) {
        if (std::none_of(pins.cbegin(), pins.cend(), [&path](const auto &pin) { return pin.first == path; }))
            return unchecked;
    }
    return {};
}

QString StoreBackend::getFlatpakBlock() const
{
    if (!env::flatpak().isEmpty())
        return QStringLiteral("installed");
    return pinnedBlock(kFlatpakAdd, QStringLiteral("flatpakUnchecked"));
}

SetupCheck StoreBackend::aurCheck(const QString &command) const
{
    SetupCheck check;
    check.root = env::omarchyRoot();
    check.recipe = command;
    if (m_snapshot && m_snapshot->catalog && m_snapshot->catalog->omarchy)
        check.pins = m_snapshot->catalog->omarchy->files;
    return check;
}

QString StoreBackend::aurName(const QString &id) const
{
    if (id.startsWith(QLatin1String("aur:")))
        return isPackageName(id.mid(4)) ? id.mid(4) : QString();
    const StoreApp *a = storeApp(id);
    return a && a->source == CatalogSource::Kind::Aur ? a->package : QString();
}

AurConfig StoreBackend::aurConfig() const
{
    return grassfield::store::aurConfig(env::cacheDir());
}

void StoreBackend::rememberAur(const QList<AurPackage> &packages, bool full)
{
    for (const AurPackage &p : packages) {
        // A search's answer has no dependencies: it never replaces an info answer.
        if (!full && m_aurFull.contains(p.name))
            continue;
        if (m_aurPackages.size() >= 2000 && !m_aurPackages.contains(p.name))
            break;
        m_aurPackages.insert(p.name, p);
        if (full) {
            m_aurFull.insert(p.name);
            m_aurUnknown.remove(p.name);
        }
    }
    rebuildAurApps();
}

void StoreBackend::rebuildAurApps()
{
    m_aurApps.clear();
    for (auto it = m_aurPackages.cbegin(); it != m_aurPackages.cend(); ++it) {
        const bool installed = m_snapshot && m_snapshot->foreign.contains(it.key());
        const QString entry = m_snapshot ? m_snapshot->entries.value(it.key()).value(0) : QString();
        m_aurApps.insert(QStringLiteral("aur:") + it.key(), view::aurApp(*it, installed, entry));
    }
}

void StoreBackend::askAurForForeign()
{
    // Asked by no click of the user's: never on a metered connection (ADR-0037 c), as the catalog's own fetch.
    if (!m_aur || !m_online || m_metered || !m_snapshot)
        return;
    QStringList names;
    for (const QString &n : m_snapshot->foreign) {
        if (!m_aurAsked.contains(n) && !n.startsWith(QLatin1String("grassfield")) && m_snapshot->explicitPackages.contains(n))
            names.append(n);
    }
    if (names.isEmpty())
        return;
    names.sort();
    names = names.mid(0, 150);
    for (const QString &n : names)
        m_aurAsked.insert(n);
    const AurConfig config = aurConfig();
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    m_pool.start([this, config, names, cancel] {
        const FetchCancelScope fetchScope(cancel); // SU-07: a quit aborts its transfers
        const AurAnswer answer = grassfield::store::aurInfo(config, names);
        if (*cancel)
            return;
        QMetaObject::invokeMethod(&m_context, [this, answer] {
            rememberAur(answer.packages, true);
            ++m_revision;
            emit dataChanged(); // Installed's "AUR" group
        }, Qt::QueuedConnection);
    });
}

void StoreBackend::searchAur(const QString &term)
{
    if (!m_aur) {
        emit aurResults(term, {}, QStringLiteral("off"));
        return;
    }
    if (!m_online) {
        emit aurResults(term, {}, QStringLiteral("offline"));
        return;
    }
    if (!isAurSearchTerm(term)) {
        emit aurResults(term, {}, QStringLiteral("short"));
        return;
    }
    const AurConfig config = aurConfig();
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    m_pool.start([this, config, term, cancel] {
        const FetchCancelScope fetchScope(cancel); // SU-07: a quit aborts its transfers
        const AurAnswer answer = aurSearch(config, term);
        if (*cancel)
            return;
        QMetaObject::invokeMethod(&m_context, [this, term, answer] {
            rememberAur(answer.packages, false);
            QSet<QString> repository;
            if (m_snapshot) {
                for (const SyncPackage &p : m_snapshot->sync)
                    repository.insert(p.name);
            }
            QVariantList list;
            for (const AurPackage &p : answer.packages) {
                if (repository.contains(p.name))
                    continue; // a repository's package of that name is the one the Store offers
                QVariantMap m = view::summary(m_aurApps.value(QStringLiteral("aur:") + p.name), m_language);
                m.insert(QStringLiteral("votes"), p.votes);
                m.insert(QStringLiteral("outOfDate"), p.outOfDate.isValid());
                list.append(m);
            }
            QString problem;
            if (!answer.ok)
                problem = answer.error.startsWith(QLatin1String("Too many")) ? QStringLiteral("tooMany") : QStringLiteral("unavailable");
            emit aurResults(term, list, problem);
        }, Qt::QueuedConnection);
    });
}

void StoreBackend::requestAur(const QString &id)
{
    const QString name = aurName(id);
    if (name.isEmpty() || !m_aur || !m_online)
        return;
    const AurConfig config = aurConfig();
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    m_pool.start([this, config, id, name, cancel] {
        const FetchCancelScope fetchScope(cancel); // SU-07: a quit aborts its transfers
        const AurAnswer answer = grassfield::store::aurInfo(config, {name});
        if (*cancel)
            return;
        QMetaObject::invokeMethod(&m_context, [this, id, name, answer] {
            if (answer.ok && answer.packages.isEmpty())
                m_aurUnknown.insert(name);
            rememberAur(answer.packages, true);
            emit aurInfo(id);
        }, Qt::QueuedConnection);
    });
}

void StoreBackend::requestBuildScript(const QString &id)
{
    const QString name = aurName(id);
    if (name.isEmpty() || !m_aur || !m_online) {
        emit buildScript(id, QString(), false);
        return;
    }
    const QString base = m_aurPackages.contains(name) ? m_aurPackages.value(name).base : name;
    const AurConfig config = aurConfig();
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    m_pool.start([this, config, id, base, cancel] {
        const FetchCancelScope fetchScope(cancel); // SU-07: a quit aborts its transfers
        const std::optional<QString> text = aurPkgbuild(config, base);
        if (*cancel)
            return;
        QMetaObject::invokeMethod(&m_context, [this, id, text] { emit buildScript(id, text.value_or(QString()), text.has_value()); },
                                  Qt::QueuedConnection);
    });
}

SetupCheck StoreBackend::setupCheck(const StoreApp &a, bool install) const
{
    SetupCheck check;
    check.root = env::omarchyRoot();
    if (a.entry)
        check.recipe = install ? a.entry->source.install : a.entry->source.remove;
    if (m_snapshot && m_snapshot->catalog && m_snapshot->catalog->omarchy)
        check.pins = m_snapshot->catalog->omarchy->files;
    return check;
}

QString StoreBackend::uninstallBlock(const StoreApp &a) const
{
    if (!a.installed)
        return QStringLiteral("notInstalled");
    if (a.source == CatalogSource::Kind::WebApp) {
        if (apps::runmode::dev() && env::installer().isEmpty())
            return QStringLiteral("dev");
        if (!apps::runmode::dev() && !executable(env::omarchyCommand(QStringLiteral("omarchy-webapp-remove"))))
            return QStringLiteral("missing");
        return {};
    }
    if (a.source == CatalogSource::Kind::OmarchySetup && m_snapshot) {
        // The recipe removes its packages (omarchy-pkg-drop, pacman -Rns): never one the deny list names (b.1's list).
        for (const QString &p : a.packages) {
            switch (protection(p, m_snapshot->deny)) {
            case Protection::None:
                break;
            case Protection::System:
                return QStringLiteral("system");
            case Protection::Omarchy:
                return QStringLiteral("omarchy");
            case Protection::Grassfield:
                return QStringLiteral("grassfield");
            }
        }
        if (!m_snapshot->deny.omarchyRead())
            return QStringLiteral("listsMissing");
        return terminalBlock();
    }
    if (a.source == CatalogSource::Kind::Aur && m_snapshot) {
        // Installed explicitly from outside the repositories (no application entry needed: the user installed it from the
        // AUR, b.2), never a package of the deny list; removed through the AUR's omarchy-pkg-drop in Omarchy's terminal.
        if (!m_aur)
            return QStringLiteral("aurOff");
        if (!m_snapshot->explicitPackages.contains(a.package))
            return QStringLiteral("dependency");
        switch (protection(a.package, m_snapshot->deny)) {
        case Protection::None:
            break;
        case Protection::System:
            return QStringLiteral("system");
        case Protection::Omarchy:
            return QStringLiteral("omarchy");
        case Protection::Grassfield:
            return QStringLiteral("grassfield");
        }
        if (!m_snapshot->deny.omarchyRead())
            return QStringLiteral("listsMissing");
        return aurBlock(kAurDrop);
    }
    if (a.source == CatalogSource::Kind::Flatpak)
        return flatpakBlock(); // the user's own installation: whatever the Store installed there, it removes
    if (a.source != CatalogSource::Kind::Repo || !m_snapshot)
        return QStringLiteral("source");
    RemovalFacts facts;
    facts.installed = a.installed;
    facts.explicitlyInstalled = m_snapshot->explicitPackages.contains(a.package);
    facts.inRepository = m_snapshot->syncNames.contains(a.package);
    facts.ownsEntry = m_snapshot->entries.contains(a.package);
    switch (removal(a.package, facts, m_snapshot->deny)) {
    case Removal::Removable:
        break;
    case Removal::NotInstalled:
        return QStringLiteral("notInstalled");
    case Removal::PartOfSystem:
        return QStringLiteral("system");
    case Removal::PartOfOmarchy:
        return QStringLiteral("omarchy");
    case Removal::PartOfGrassfield:
        return QStringLiteral("grassfield");
    case Removal::Dependency:
        return QStringLiteral("dependency");
    case Removal::NotAnApp:
        return QStringLiteral("notApp");
    case Removal::NotFromRepository:
        return QStringLiteral("notFromRepository");
    case Removal::ListsMissing:
        return QStringLiteral("listsMissing");
    }
    if (env::pkexec().isEmpty())
        return QStringLiteral("dev");
    if (!apps::runmode::dev() && (!executable(env::helperPath) || !executable(env::pkexec())))
        return QStringLiteral("missing");
    return {};
}

QVariantMap StoreBackend::actions(const QString &id) const
{
    if (const auto w = otherWebApp(id)) {
        const bool can = apps::runmode::dev() ? !env::installer().isEmpty()
                                              : executable(env::omarchyCommand(QStringLiteral("omarchy-webapp-remove")));
        return {{QStringLiteral("installed"), true}, {QStringLiteral("launcher"), true}, {QStringLiteral("get"), QStringLiteral("installed")},
                {QStringLiteral("uninstall"), can ? QString() : (apps::runmode::dev() ? QStringLiteral("dev") : QStringLiteral("missing"))}};
    }
    // A Flatpak with an update (SR13): "update" is "" when its Update runs now, else why not; "none" without one.
    const QString update = !flatpakUpdateOf(id)            ? QStringLiteral("none")
        : m_updatePlanning.contains(id)                         ? QStringLiteral("checking")
                                                                : flatpakUpdateBlock();
    if (!otherFlatpak(id).isEmpty()) {
        return {{QStringLiteral("installed"), true}, {QStringLiteral("launcher"), true}, {QStringLiteral("get"), QStringLiteral("installed")},
                {QStringLiteral("uninstall"), flatpakBlock()}, {QStringLiteral("update"), update}};
    }
    const StoreApp *a = storeApp(id);
    if (!a)
        return {{QStringLiteral("installed"), false}, {QStringLiteral("launcher"), false},
                {QStringLiteral("get"), QStringLiteral("source")}, {QStringLiteral("uninstall"), QStringLiteral("source")},
                {QStringLiteral("update"), QStringLiteral("none")}};
    const bool launcher = a->source == CatalogSource::Kind::WebApp ? a->installed : !a->desktopId.isEmpty();
    return {{QStringLiteral("installed"), a->installed},
            {QStringLiteral("launcher"), launcher},
            {QStringLiteral("get"), a->installed ? QStringLiteral("installed") : getBlock(*a)},
            {QStringLiteral("uninstall"), uninstallBlock(*a)},
            {QStringLiteral("update"), a->installed ? update : QStringLiteral("none")}};
}

QVariantMap StoreBackend::removalByEntry(bool withPlans) const
{
    QVariantMap out;
    if (!m_snapshot)
        return out;
    const Snapshot &s = *m_snapshot;
    const auto add = [&out](const QString &desktop, const QString &id, const QString &name, const QString &block) {
        if (isDesktopId(desktop) && !out.contains(desktop))
            out.insert(desktop, QVariantMap{{QStringLiteral("app"), id}, {QStringLiteral("name"), name}, {QStringLiteral("block"), block}});
    };
    for (const StoreApp &a : s.apps) {
        // Installed repository and Flatpak apps (web apps and recipes keep their Installed page: not a launcher's business).
        if (!a.installed || (a.source != CatalogSource::Kind::Repo && a.source != CatalogSource::Kind::Flatpak))
            continue;
        const QString name = view::summary(a, m_language).value(QStringLiteral("name")).toString();
        QString block = uninstallBlock(a);
        // The badge must never lead to a refusal (ADR-0046 D3): a package whose -Rs plan hits a dependency or a protected package
        // is "not removable" before it is offered. The launcher's one-shot asks for this (a pacman run each); the pages do not.
        if (withPlans && block.isEmpty() && a.source == CatalogSource::Kind::Repo) {
            const RemovePlan plan = checkRemove({a.package}, s.deny, planTools(), false);
            if (plan.refusal == Refusal::Dependency)
                block = QStringLiteral("dependency");
            else if (plan.refusal == Refusal::Protected)
                block = QStringLiteral("protected");
            else if (plan.refusal == Refusal::Failed)
                block = QStringLiteral("plan");
        }
        QStringList ids = a.source == CatalogSource::Kind::Repo ? s.entries.value(a.package) : QStringList{};
        if (!a.desktopId.isEmpty())
            ids.prepend(a.desktopId);
        for (const QString &desktop : std::as_const(ids))
            add(desktop, a.id, name, block);
    }
    // The user's Flatpaks Flathub's AppStream does not have: removed as "flatpak:<app id>".
    for (const QString &app : s.flatpaks) {
        if (!s.index.contains(app) && isFlatpakId(app))
            add(app + QStringLiteral(".desktop"), QStringLiteral("flatpak:") + app, app, flatpakBlock());
    }
    return out;
}

QString StoreBackend::appForEntry(const QString &desktopId) const
{
    const QString key = desktopId.endsWith(QLatin1String(".desktop")) ? desktopId : desktopId + QStringLiteral(".desktop");
    return removalByEntry().value(key).toMap().value(QStringLiteral("app")).toString();
}

PlanTools StoreBackend::planTools() const
{
    PlanTools tools;
    tools.pacman = env::pacman();
    tools.dbLock = env::dbLock();
    tools.updateLock = env::updateLock();
    tools.devPlumbing = !env::fixture().isEmpty();
    const bool dev = tools.devPlumbing;
    tools.heads = [dev](const QList<QUrl> &urls) { return headStatuses(urls, kFetchMs, kHeadsMs, dev); };
    // Software Update's answer against pacman's last sync (ADR-0037 e.4, SD29): the system first.
    tools.behind = databasesBehind(readSmall(apps::runmode::stateDir() + QStringLiteral("/software-update.json"), 512 * 1024),
                                   lastSync(env::syncDir()));
    return tools;
}

namespace {

QVariantList packageList(const QList<PlannedPackage> &packages, const QLocale &locale)
{
    QVariantList out;
    for (const PlannedPackage &p : packages)
        out.append(QVariantMap{{QStringLiteral("name"), p.name},
                               {QStringLiteral("version"), p.version},
                               {QStringLiteral("repo"), p.repo},
                               {QStringLiteral("size"), view::sizeText(p.downloadSize, locale)}});
    return out;
}

QString refusalName(Refusal r)
{
    switch (r) {
    case Refusal::None:
        return {};
    case Refusal::Busy:
        return QStringLiteral("busy");
    case Refusal::Unfinished:
        return QStringLiteral("unfinished");
    case Refusal::Outdated:
        return QStringLiteral("outdated");
    case Refusal::Offline:
        return QStringLiteral("offline");
    case Refusal::Dependency:
        return QStringLiteral("dependency");
    case Refusal::Protected:
        return QStringLiteral("protected");
    case Refusal::OmarchyChanged:
        return QStringLiteral("omarchyChanged");
    case Refusal::Repository:
        return QStringLiteral("repository");
    case Refusal::NotOnAur:
        return QStringLiteral("notOnAur");
    case Refusal::Failed:
        return QStringLiteral("failed");
    }
    return QStringLiteral("failed");
}

} // namespace

void StoreBackend::planGetFlatpak()
{
    const QString kind = QStringLiteral("install");
    if (const QString block = getFlatpakBlock(); !block.isEmpty()) {
        emit planReady(kGetFlatpakApp, kind, {{QStringLiteral("refusal"), QStringLiteral("unavailable")}, {QStringLiteral("detail"), block}});
        return;
    }
    const PlanTools tools = planTools();
    const SetupCheck check = aurCheck(kFlatpakAdd);
    const bool online = m_online;
    const bool own = m_operations->running();
    const QLocale locale = m_formats;
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    m_pool.start([this, kind, check, tools, online, own, locale, cancel] {
        const FetchCancelScope fetchScope(cancel); // SU-07: a quit aborts its transfers
        const InstallPlan p = checkSetupInstall({kFlatpakPackage}, check, tools, online, own);
        const QVariantMap out{{QStringLiteral("refusal"), refusalName(p.refusal)},
                              {QStringLiteral("packages"), packageList(p.packages, locale)},
                              {QStringLiteral("download"), view::sizeText(p.downloadSize, locale)},
                              {QStringLiteral("installed"), view::sizeText(p.installedSize, locale)},
                              {QStringLiteral("unfinished"), p.unfinished},
                              {QStringLiteral("upgrades"), p.upgrades},
                              {QStringLiteral("detail"), p.detail}};
        if (*cancel)
            return;
        QMetaObject::invokeMethod(&m_context, [this, kind, out, p] {
            if (p.refusal == Refusal::None)
                m_installPlans.insert(kGetFlatpakApp, p);
            else
                m_installPlans.remove(kGetFlatpakApp);
            emit planReady(kGetFlatpakApp, kind, out);
        }, Qt::QueuedConnection);
    });
}

void StoreBackend::plan(const QString &id, const QString &kind)
{
    if (kind == QLatin1String("update")) {
        planFlatpakUpdate(id);
        return;
    }
    if (id == kGetFlatpakApp) {
        if (kind == QLatin1String("install"))
            planGetFlatpak();
        else
            emit planReady(id, kind, {{QStringLiteral("refusal"), QStringLiteral("unavailable")}});
        return;
    }
    if (otherWebApp(id)) {
        const bool ok = kind == QLatin1String("remove") && actions(id).value(QStringLiteral("uninstall")).toString().isEmpty();
        emit planReady(id, kind, ok ? QVariantMap{{QStringLiteral("refusal"), QString()}, {QStringLiteral("packages"), QVariantList()}}
                                    : QVariantMap{{QStringLiteral("refusal"), QStringLiteral("unavailable")}});
        return;
    }
    if (const QString other = otherFlatpak(id); !other.isEmpty()) {
        // A Flatpak of the user's installation Flathub's AppStream does not have: removed as the others (SD27).
        if (kind != QLatin1String("remove") || !flatpakBlock().isEmpty()) {
            emit planReady(id, kind, {{QStringLiteral("refusal"), QStringLiteral("unavailable")}, {QStringLiteral("detail"), flatpakBlock()}});
            return;
        }
        RemovePlan p;
        p.packages = {PlannedPackage{other, {}, kFlathubRemote, -1, {}}};
        m_removePlans.insert(id, p);
        emit planReady(id, kind, {{QStringLiteral("refusal"), QString()}, {QStringLiteral("packages"), packageList(p.packages, m_formats)}});
        return;
    }
    const StoreApp *a = storeApp(id);
    const bool install = kind == QLatin1String("install");
    if (!a || (!install && kind != QLatin1String("remove"))) {
        emit planReady(id, kind, {{QStringLiteral("refusal"), QStringLiteral("unavailable")}});
        return;
    }
    const QString block = install ? getBlock(*a) : uninstallBlock(*a);
    if (!block.isEmpty() && !(install && block == QLatin1String("offline"))) {
        emit planReady(id, kind, {{QStringLiteral("refusal"), QStringLiteral("unavailable")}, {QStringLiteral("detail"), block}});
        return;
    }
    if (a->source == CatalogSource::Kind::WebApp) {
        // The sheet alone (owner, ST3): nothing pacman plans; a launcher and its icon, in the user's own files.
        emit planReady(id, kind, {{QStringLiteral("refusal"), block == QLatin1String("offline") ? QStringLiteral("offline") : QString()},
                                  {QStringLiteral("packages"), QVariantList()}});
        return;
    }
    if (a->source == CatalogSource::Kind::Flatpak) {
        if (!install) {
            // The app goes, its data in ~/.var/app/<id> stays, and so do runtimes another app needs (SD27): nothing to ask.
            RemovePlan p;
            p.packages = {PlannedPackage{flatpakRefId(a->flatpakRef), {}, kFlathubRemote, -1, {}}};
            m_removePlans.insert(id, p);
            emit planReady(id, kind, {{QStringLiteral("refusal"), QString()}, {QStringLiteral("packages"), packageList(p.packages, m_formats)}});
            return;
        }
        // flatpak's own plan on a pseudo-terminal, and what the app's metadata grants it (SD25), on a worker.
        const FlatpakTools tools = flatpakTools();
        const QString ref = a->flatpakRef;
        const bool online = m_online;
        const QLocale locale = m_formats;
        const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
        m_pool.start([this, id, kind, ref, tools, online, locale, cancel] {
        const FetchCancelScope fetchScope(cancel); // SU-07: a quit aborts its transfers
            const InstallPlan p = checkFlatpakInstall(ref, tools, online);
            const QVariantMap out{{QStringLiteral("refusal"), refusalName(p.refusal)},
                                  {QStringLiteral("packages"), packageList(p.packages, locale)},
                                  {QStringLiteral("download"), view::sizeText(p.downloadSize, locale)},
                                  {QStringLiteral("installed"), QString()},
                                  {QStringLiteral("access"), p.access},
                                  {QStringLiteral("permissions"), view::permissions(p.permissions, p.morePermissions)},
                                  {QStringLiteral("detail"), p.detail}};
            if (p.refusal != Refusal::None)
                qInfo("grassfield-store: %s: flatpak's plan: %s", qPrintable(id), qPrintable(p.detail));
            if (*cancel)
                return;
            QMetaObject::invokeMethod(&m_context, [this, id, kind, out, p] {
                if (p.refusal == Refusal::None)
                    m_installPlans.insert(id, p);
                else
                    m_installPlans.remove(id);
                emit planReady(id, kind, out);
            }, Qt::QueuedConnection);
        });
        return;
    }
    const PlanTools tools = planTools();
    const bool aur = a->source == CatalogSource::Kind::Aur;
    const bool setup = a->source == CatalogSource::Kind::OmarchySetup;
    const QStringList packages = setup ? a->packages : QStringList{a->package};
    const SetupCheck check = setup ? setupCheck(*a, install) : aur ? aurCheck(install ? kAurAdd : kAurDrop) : SetupCheck{};
    const AurConfig aurService = aurConfig();
    const bool online = m_online;
    const bool own = m_operations->running();
    const DenyList deny = m_snapshot->deny;
    const QLocale locale = m_formats;
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    m_pool.start([this, id, kind, install, aur, setup, packages, check, aurService, tools, online, own, deny, locale, cancel] {
        const FetchCancelScope fetchScope(cancel); // SU-07: a quit aborts its transfers
        QVariantMap out;
        if (install) {
            const auto info = [&aurService](const QStringList &names) { return grassfield::store::aurInfo(aurService, names); };
            InstallPlan p = aur     ? checkAurInstall(packages.value(0), check, info, deny, tools, online, own)
                            : setup ? checkSetupInstall(packages, check, tools, online, own)
                                    : checkInstall(packages, tools, online, own);
            out = {{QStringLiteral("refusal"), refusalName(p.refusal)},
                   {QStringLiteral("built"), packageList(p.built, locale)},
                   {QStringLiteral("incomplete"), p.incomplete},
                   {QStringLiteral("packages"), packageList(p.packages, locale)},
                   {QStringLiteral("download"), view::sizeText(p.downloadSize, locale)},
                   {QStringLiteral("installed"), view::sizeText(p.installedSize, locale)},
                   {QStringLiteral("unfinished"), p.unfinished},
                   {QStringLiteral("upgrades"), p.upgrades},
                   {QStringLiteral("protected"), p.protectedPackage},
                   {QStringLiteral("detail"), p.detail}};
            if (p.refusal == Refusal::Outdated) // the sheet says it in plain words: pacman's, the mirror's are for the log
                qInfo("grassfield-store: %s: update the system first: %s", qPrintable(id), qPrintable(p.detail));
            if (*cancel)
                return;
            QMetaObject::invokeMethod(&m_context, [this, id, kind, out, p] {
                if (p.refusal == Refusal::None)
                    m_installPlans.insert(id, p);
                else
                    m_installPlans.remove(id);
                emit planReady(id, kind, out);
            }, Qt::QueuedConnection);
        } else {
            RemovePlan p = setup || aur ? checkSetupRemove(packages, check, deny, tools, own) : checkRemove(packages, deny, tools, own);
            out = {{QStringLiteral("refusal"), refusalName(p.refusal)},
                   {QStringLiteral("packages"), packageList(p.packages, locale)},
                   {QStringLiteral("dependents"), p.dependents},
                   {QStringLiteral("protected"), p.protectedPackage},
                   {QStringLiteral("detail"), p.detail}};
            if (*cancel)
                return;
            QMetaObject::invokeMethod(&m_context, [this, id, kind, out, p] {
                if (p.refusal == Refusal::None)
                    m_removePlans.insert(id, p);
                else
                    m_removePlans.remove(id);
                emit planReady(id, kind, out);
            }, Qt::QueuedConnection);
        }
    });
}

bool StoreBackend::install(const QString &id)
{
    if (id == kGetFlatpakApp) {
        // Omarchy's omarchy-pkg-add flatpak in its terminal (SD24), the plan its sheet showed; grassfield-store-run checks it
        // all again.
        const auto it = m_installPlans.constFind(id);
        if (m_operations->queued(id) || !getFlatpakBlock().isEmpty() || it == m_installPlans.cend() || it->packages.isEmpty())
            return false;
        OperationRecord r;
        r.id = newOperationId();
        r.kind = QStringLiteral("install");
        r.app = id;
        r.name = QStringLiteral("Flatpak");
        r.path = QStringLiteral("terminal");
        r.packages = {kFlatpakPackage};
        r.recipe = kFlatpakAdd;
        r.args = {kFlatpakPackage};
        r.pins = aurCheck(kFlatpakAdd).pins;
        r.plan = it->packages;
        m_installPlans.remove(id);
        m_operations->enqueue(r);
        return true;
    }
    const StoreApp *a = storeApp(id);
    if (!a || a->installed || m_operations->queued(id) || !getBlock(*a).isEmpty())
        return false;
    OperationRecord r;
    r.id = newOperationId();
    r.kind = QStringLiteral("install");
    r.app = a->id;
    r.name = a->name.pick(m_language);
    if (a->source == CatalogSource::Kind::WebApp) {
        r.path = QStringLiteral("webapp");
        r.webName = a->name.pick(m_language);
        r.webUrl = a->entry->source.url;
        r.webIcon = a->icon;
        if (!isWebAppName(r.webName) || !isHttpsUrl(r.webUrl))
            return false;
    } else {
        // The plan its sheet showed (planReady); the helper, or grassfield-store-run for a setup, checks it all again.
        const auto it = m_installPlans.constFind(id);
        if (it == m_installPlans.cend() || (it->packages.isEmpty() && it->built.isEmpty()))
            return false;
        if (a->source == CatalogSource::Kind::OmarchySetup) {
            const SetupCheck check = setupCheck(*a, true);
            r.path = QStringLiteral("terminal");
            r.packages = a->packages;
            r.recipe = check.recipe;
            r.args = a->entry->source.args;
            r.pins = check.pins;
            r.plan = it->packages;
        } else if (a->source == CatalogSource::Kind::Flatpak) {
            // flatpak installs what its own plan showed (b.3): the app's ref and what it needs.
            r.path = QStringLiteral("flatpak");
            r.flatpak = a->flatpakRef;
            r.plan = it->packages;
        } else if (a->source == CatalogSource::Kind::Aur) {
            // yay builds the AUR's (whatever version its build makes: none asked) and pacman adds the repositories'.
            const SetupCheck check = aurCheck(kAurAdd);
            r.path = QStringLiteral("terminal");
            r.packages = {a->package};
            r.recipe = kAurAdd;
            r.args = {a->package};
            r.pins = check.pins;
            for (PlannedPackage p : it->built) {
                p.version.clear();
                r.plan.append(p);
            }
            r.plan += it->packages;
        } else {
            r.path = QStringLiteral("helper");
            r.packages = {a->package};
            r.plan = it->packages;
        }
    }
    m_installPlans.remove(id);
    m_operations->enqueue(r);
    return true;
}

bool StoreBackend::uninstall(const QString &id)
{
    if (const auto w = otherWebApp(id)) {
        if (m_operations->queued(id) || !actions(id).value(QStringLiteral("uninstall")).toString().isEmpty())
            return false;
        OperationRecord r;
        r.id = newOperationId();
        r.kind = QStringLiteral("remove");
        r.path = QStringLiteral("webapp");
        r.app = id;
        r.name = w->name;
        r.webName = w->file;
        r.webUrl = w->url;
        m_operations->enqueue(r);
        return true;
    }
    if (const QString other = otherFlatpak(id); !other.isEmpty()) {
        if (m_operations->queued(id) || !flatpakBlock().isEmpty() || !m_removePlans.contains(id))
            return false;
        OperationRecord r;
        r.id = newOperationId();
        r.kind = QStringLiteral("remove");
        r.path = QStringLiteral("flatpak");
        r.app = id;
        r.name = other;
        r.flatpak = other;
        r.plan = m_removePlans.take(id).packages;
        m_operations->enqueue(r);
        return true;
    }
    const StoreApp *a = storeApp(id);
    if (!a || m_operations->queued(id) || !uninstallBlock(*a).isEmpty())
        return false;
    OperationRecord r;
    r.id = newOperationId();
    r.kind = QStringLiteral("remove");
    r.app = a->id;
    r.name = a->name.pick(m_language);
    if (a->source == CatalogSource::Kind::WebApp) {
        // The launcher's own name: the file Omarchy wrote for this address.
        QString file;
        for (const view::WebAppEntry &w : m_snapshot->webApps) {
            if (a->entry && w.url == a->entry->source.url)
                file = w.file;
        }
        if (!isWebAppName(file))
            return false;
        r.path = QStringLiteral("webapp");
        r.webName = file;
        r.webUrl = a->entry->source.url;
    } else {
        const auto it = m_removePlans.constFind(id);
        if (it == m_removePlans.cend() || it->packages.isEmpty())
            return false;
        if (a->source == CatalogSource::Kind::OmarchySetup) {
            const SetupCheck check = setupCheck(*a, false);
            r.path = QStringLiteral("terminal");
            r.packages = a->packages;
            r.recipe = check.recipe;
            r.args = a->entry->source.removeArgs;
            r.pins = check.pins;
        } else if (a->source == CatalogSource::Kind::Aur) {
            const SetupCheck check = aurCheck(kAurDrop);
            r.path = QStringLiteral("terminal");
            r.packages = {a->package};
            r.recipe = kAurDrop;
            r.args = {a->package};
            r.pins = check.pins;
        } else if (a->source == CatalogSource::Kind::Flatpak) {
            r.path = QStringLiteral("flatpak");
            r.flatpak = flatpakRefId(a->flatpakRef);
        } else {
            r.path = QStringLiteral("helper");
            r.packages = {a->package};
        }
        r.plan = it->packages;
    }
    m_removePlans.remove(id);
    m_operations->enqueue(r);
    return true;
}

bool StoreBackend::removeWaiting(const QString &operationId)
{
    return m_operations->removeWaiting(operationId);
}

QHash<QString, apps::OngoingActivity> StoreBackend::ongoingActivities(const QVariantList &operations)
{
    QHash<QString, apps::OngoingActivity> out;
    if (operations.isEmpty())
        return out;
    const QVariantMap op = operations.first().toMap(); // the running one first (SR18)
    const QString state = op.value(QStringLiteral("state")).toString();
    const QString id = op.value(QStringLiteral("id")).toString();
    if (state == QLatin1String("waiting") || !isOperationId(id))
        return out;
    const QString kind = op.value(QStringLiteral("kind")).toString();
    const QString name = op.value(QStringLiteral("name")).toString();
    const int done = op.value(QStringLiteral("done")).toInt();
    const int total = op.value(QStringLiteral("total")).toInt();
    apps::OngoingActivity a;
    a.kind = QStringLiteral("install");
    if (kind == QLatin1String("remove"))
        a.title = QCoreApplication::translate("StoreOngoing", "Uninstalling “%1”").arg(name);
    else if (kind == QLatin1String("update"))
        a.title = name.isEmpty() ? QCoreApplication::translate("StoreOngoing", "Updating Apps") : QCoreApplication::translate("StoreOngoing", "Updating “%1”").arg(name);
    else
        a.title = QCoreApplication::translate("StoreOngoing", "Installing “%1”").arg(name);
    if (state == QLatin1String("authorizing"))
        a.subtitle = QCoreApplication::translate("StoreOngoing", "Waiting for permission…");
    else if (state == QLatin1String("opening"))
        a.subtitle = QCoreApplication::translate("StoreOngoing", "Opening Terminal…");
    else if (state == QLatin1String("checking"))
        a.subtitle = QCoreApplication::translate("StoreOngoing", "Finishing…");
    else if (total > 0)
        a.subtitle = QCoreApplication::translate("StoreOngoing", "%1 of %2").arg(done).arg(total);
    if (state == QLatin1String("running") && total > 0)
        a.progress = qBound(0.0, double(done) / double(total), 1.0);
    if (op.value(QStringLiteral("stoppable")).toBool())
        a.actions = {{QStringLiteral("stop"), QCoreApplication::translate("StoreOngoing", "Stop")}};
    out.insert(QStringLiteral("op-") + id, a);
    return out;
}

void StoreBackend::publishOngoing()
{
    if (m_ongoing && m_operations)
        m_ongoing->sync(ongoingActivities(m_operations->list()));
}

bool StoreBackend::stopOperation(const QString &operationId)
{
    return m_operations->stop(operationId);
}

void StoreBackend::requestFlatpakInfo(const QString &id)
{
    const StoreApp *a = storeApp(id);
    const QString other = otherFlatpak(id);
    if ((!a || a->source != CatalogSource::Kind::Flatpak) && other.isEmpty())
        return;
    const bool installed = !other.isEmpty() || a->installed;
    // Before an install Flathub answers (online only); after it, the user's installation does.
    if (!installed && !m_online) {
        emit flatpakInfo(id, {});
        return;
    }
    const FlatpakTools tools = flatpakTools();
    if (tools.flatpak.isEmpty())
        return;
    const QString target = !other.isEmpty() ? other : installed ? flatpakRefId(a->flatpakRef) : a->flatpakRef;
    const QLocale locale = m_formats;
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    m_pool.start([this, id, target, installed, tools, locale, cancel] {
        const FetchCancelScope fetchScope(cancel); // SU-07: a quit aborts its transfers
        const std::optional<FlatpakFacts> facts = flatpakFacts(tools, target, installed);
        if (*cancel)
            return;
        QVariantMap out;
        if (facts) {
            out = {{QStringLiteral("version"), facts->version},
                   {QStringLiteral("license"), facts->license},
                   {QStringLiteral("download"), view::sizeText(facts->download, locale)},
                   {QStringLiteral("installed"), view::sizeText(facts->installed, locale)}};
            if (facts->access) // unread: the page says nothing rather than "only its own window and files"
                out.insert(QStringLiteral("access"), *facts->access);
            if (facts->permissions)
                out.insert(QStringLiteral("permissions"), view::permissions(facts->permissions->grants, facts->permissions->more));
        }
        QMetaObject::invokeMethod(&m_context, [this, id, out] { emit flatpakInfo(id, out); }, Qt::QueuedConnection);
    });
}

void StoreBackend::dismiss(const QString &id)
{
    m_operations->dismiss(id);
}

bool StoreBackend::open(const QString &id)
{
    const StoreApp *a = storeApp(id);
    const auto other = otherWebApp(id);
    const QString otherApp = otherFlatpak(id);
    if (!other && otherApp.isEmpty() && (!a || !a->installed))
        return false;
    QStringList argv;
    // A web app the catalog does not list has no StoreApp (a is null): it is answered before anything reads a.
    if (other) {
        argv = {QStringLiteral("omarchy-launch-webapp"), other->url};
    } else if (!otherApp.isEmpty() || (a && a->source == CatalogSource::Kind::Flatpak)) {
        // Its exported entry when the session sees flatpak's export folder (from the login after flatpak's own install,
        // S20); else `flatpak run <app id>`, in its own scope as well (ADR-0037 f).
        const QString appId = otherApp.isEmpty() ? flatpakRefId(a->flatpakRef) : otherApp;
        const QString desktop = otherApp.isEmpty() ? a->desktopId : otherApp + QStringLiteral(".desktop");
        const QString exports = env::flatpakExports();
        if (!isFlatpakId(appId))
            return false;
        if (env::flatpakExportsSeen() && isDesktopId(desktop) && QFileInfo::exists(exports + QStringLiteral("/applications/") + desktop))
            argv = {QStringLiteral("uwsm-app"), QStringLiteral("--"), desktop};
        else
            argv = {QStringLiteral("uwsm-app"), QStringLiteral("--"), QStringLiteral("/usr/bin/flatpak"), QStringLiteral("run"), appId};
    } else if (!a) {
        return false;
    } else if (a->source == CatalogSource::Kind::WebApp) {
        // Omarchy's own launcher, which scopes the browser itself (S14: the entry's file name has spaces uwsm refuses).
        if (!a->entry || !isHttpsUrl(a->entry->source.url))
            return false;
        argv = {QStringLiteral("omarchy-launch-webapp"), a->entry->source.url};
    } else {
        if (!isDesktopId(a->desktopId))
            return false;
        argv = {QStringLiteral("uwsm-app"), QStringLiteral("--"), a->desktopId};
    }
    if (apps::runmode::dev()) {
        // Only through the fake program (ADR-0011's dev open policy: a dev session starts nothing of the owner's).
        const QString fake = env::installer();
        return !fake.isEmpty() && QProcess::startDetached(fake, argv);
    }
    if (argv.constFirst() == QLatin1String("omarchy-launch-webapp"))
        return QProcess::startDetached(env::omarchyCommand(argv.constFirst()), argv.mid(1));
    const QString uwsm = QStandardPaths::findExecutable(QStringLiteral("uwsm-app"));
    return !uwsm.isEmpty() && QProcess::startDetached(uwsm, argv.mid(1));
}

bool StoreBackend::openSoftwareUpdate()
{
    const QStringList argv{QStringLiteral("grassfield-settings"), QStringLiteral("--section=general")};
    if (apps::runmode::dev()) {
        const QString fake = env::installer();
        return !fake.isEmpty() && QProcess::startDetached(fake, argv);
    }
    return apps::startApplication(argv.constFirst(), argv.mid(1));
}

void StoreBackend::reopened()
{
    m_quitWhenIdle = false;
}

void StoreBackend::quitWhenIdle()
{
    if (!m_operations->running()) {
        QCoreApplication::quit();
        return;
    }
    // The running operation ends in pacman or Omarchy's command: the Store waits for it (it holds Omarchy's lock and keeps
    // the result), without a window; the waiting ones are dropped.
    for (const Operations::Item &i : m_operations->items()) {
        if (i.state == Operations::State::Waiting)
            m_operations->removeWaiting(i.record.id);
    }
    m_quitWhenIdle = true;
    if (guiApp()) {
        for (QWindow *w : QGuiApplication::topLevelWindows())
            w->close();
    }
}

} // namespace grassfield::store
