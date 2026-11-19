// The Store window's backend (ADR-0037 steps 2 and 3; spec SR1-SR23, SR24 read-only, SR26-SR29): what the QML reads, and the
// work behind it off the GUI thread. Each load builds one immutable Snapshot in a worker (pacman's lists, Arch's AppStream,
// the cached catalog checked again, the web apps' launchers, the merged model) and the window swaps it in whole; a fetch
// (the catalog when its copy is older than 6 hours or on Ctrl+R, its icons, Arch's AppStream package when none is
// installed) runs only online, and never on a metered connection without Ctrl+R. Get and Uninstall… plan first (the plan
// check, plancheck.h, on a worker), then queue an operation (operations.h) once the sheet's default button is pressed;
// Open starts the app (ADR-0011). A link opens in the browser, https only, never in a dev session.
#pragma once

#include "appstreamsource.h"
#include "aur.h"
#include "catalogstore.h"
#include "channel.h"
#include "flatpak.h"
#include "ongoing.h"
#include "operations.h"
#include "pacman.h"
#include "plancheck.h"
#include "removal.h"
#include "storemodel.h"
#include "storeview.h"

#include <QDateTime>
#include <QFileSystemWatcher>
#include <QLocale>
#include <QObject>
#include <QSet>
#include <QThreadPool>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

#include <atomic>
#include <functional>
#include <memory>
#include <optional>

namespace grassfield::store {

// "Get Flatpak…" (step 3c part 3, SD24): the operation's app id (no app of a source takes a colon after "store").
inline const QString kGetFlatpakApp = QStringLiteral("store:flatpak");
// Update All of the Flatpak group (step 4): the operation of all the Flathub updates at once.
inline const QString kFlatpakUpdatesApp = QStringLiteral("store:flatpak-updates");

// Everything one load read and made; never changed once built (StoreApp::entry points into `catalog`).
struct Snapshot {
    std::optional<Catalog> catalog;
    Catalog fallback; // the built-in categories, while there is no catalog
    QString channel;               // stable or beta
    bool catalogConfigured = false; // false while this build has no hosting (a .invalid base) and no dev plumbing
    CatalogStore::Outcome catalogOutcome = CatalogStore::Outcome::Missing;
    QString catalogReason;
    QDateTime catalogFetchedAt;
    QString fetchProblem; // "" or why the last fetch of the catalog was not used: untrusted, refused, unavailable
    AppStreamData appstream;
    QString appstreamProblem; // "" or download, unverified, unavailable
    QList<SyncPackage> sync;
    QSet<QString> syncNames; // the names of `sync`, for the buttons' look-ups (SU-12: no scan of ~15k packages per button)
    QSet<QString> explicitPackages;
    QSet<QString> foreign;          // packages no repository has (pacman -Qm)
    QSet<QString> foreignWithEntry; // those of them that own an application entry
    QHash<QString, QStringList> entries; // package -> the desktop ids of its entries in /usr/share/applications
    DenyList deny;                       // what is never removed (removal.h)
    QList<view::WebAppEntry> webApps;
    // Flathub (step 3c), while its switch is on and flatpak is there: its AppStream in the user's installation, the apps
    // installed there (flatpak list --user --app), whether that installation has Flathub, and why Flathub's apps are not
    // there when they are not: "" | added (remote-add or its AppStream failed: offline, Flathub unreachable) | dev (a dev
    // session adds nothing to the user's installation).
    AppStreamData flathub;
    QSet<QString> flatpaks;
    bool flathubAdded = false;
    QString flathubProblem;
    // The catalog's first pinned Omarchy file that differs in the installed Omarchy ("" when they all match, ADR-0037 g):
    // no setup runs then (b.2).
    QString omarchyDiffers;
    QList<StoreApp> apps;
    QHash<QString, int> index; // app id -> apps
    QHash<QString, QString> tints; // app id -> hero tint (#rrggbb)
    bool pacmanRead = false;
    const QList<CatalogCategory> &categories() const { return catalog ? catalog->categories : fallback.categories; }
};

class StoreBackend : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString language READ language CONSTANT)
    Q_PROPERTY(bool devSession READ devSession CONSTANT)
    // Appearance, from grassfield.json (read only), as the other apps.
    Q_PROPERTY(bool dark READ dark NOTIFY appearanceChanged)
    Q_PROPERTY(bool reduceMotion READ reduceMotion NOTIFY appearanceChanged)
    Q_PROPERTY(bool increaseContrast READ increaseContrast NOTIFY appearanceChanged)
    Q_PROPERTY(qreal textScale READ textScale NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentColor READ accentColor NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentHighlight READ accentHighlight NOTIFY appearanceChanged)
    Q_PROPERTY(QString shortcutStyle READ shortcutStyle NOTIFY appearanceChanged)
    Q_PROPERTY(QString titlebarDoubleClick READ titlebarDoubleClick NOTIFY appearanceChanged)
    Q_PROPERTY(bool canMinimize READ canMinimize NOTIFY appearanceChanged)
    // Bumped each time a new snapshot is in place (dataChanged: the pages read their data again, in place), and when only the
    // buttons' state moved (an update checked or planned: revisionChanged alone, SU-06).
    Q_PROPERTY(int revision READ revision NOTIFY revisionChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(bool refreshing READ refreshing NOTIFY loadingChanged)
    Q_PROPERTY(bool online READ online NOTIFY networkChanged)
    Q_PROPERTY(bool metered READ metered NOTIFY networkChanged)
    // {inUse, channel, date, old, problem}: problem is "", "unconfigured" (no hosting yet), "untrusted" (no trusted key),
    // "refused" (a bad signature, a rule, a replay) or "unavailable" (not fetched).
    Q_PROPERTY(QVariantMap catalog READ catalogStatus NOTIFY dataChanged)
    // {origin: installed | fetched | none, problem: "" | download (the package file or its signature could not be
    // downloaded: a package database older than the mirror, most often) | unverified (its signature fails pacman's rule) |
    // unavailable (pacman names no file, or it could not be unpacked or cached)}
    Q_PROPERTY(QVariantMap appData READ appDataStatus NOTIFY dataChanged)
    // {name, initials, picture}: the local user (passwd, AccountsService's picture).
    Q_PROPERTY(QVariantMap user READ user CONSTANT)
    // {aur, flathub, flatpak, flathubReady, flathubProblem, screenshots}: the optional sources (off until turned on) and the
    // switch of the screenshots (owner ST6: on), read from grassfield.json's "store" keys (the settings window writes them,
    // SD20); flatpak: the program is there; flathubReady: Flathub is in the user's installation and its apps are read;
    // flathubProblem: Snapshot::flathubProblem.
    Q_PROPERTY(QVariantMap sources READ sources NOTIFY sourcesChanged)
    // The key window (QGuiApplication::focusWindow), null while no window of the Store has the keyboard. Qt matches a
    // window's Shortcuts and its global menu's keys while one of its transient children has the keyboard too, so a key
    // belongs to the key window alone (as Files' FilesApp.focusWindow).
    Q_PROPERTY(QObject *focusWindow READ focusWindow NOTIFY focusWindowChanged)
    // The queue (spec SR18): [{id, app, name, kind, state, blocked, done, total}], the running one first.
    Q_PROPERTY(QVariantList operations READ operations NOTIFY operationsChanged)
    // How the last operation of an app ended, while it says something: app id -> {kind, name, outcome, present, total,
    // details, source ("aur" for the AUR's commands, "flatpak" for a Flatpak's)}.
    Q_PROPERTY(QVariantMap results READ results NOTIFY operationsChanged)
    // pacman stopped mid-way and left its lock (db.lck there, no pacman running): SR20's explanation, then Arch's recovery.
    Q_PROPERTY(bool staleLock READ staleLock NOTIFY operationsChanged)
    // Updates (SR24, SR25; step 4): see updates() below.
    Q_PROPERTY(QVariantMap updates READ updates NOTIFY updatesChanged)

public:
    explicit StoreBackend(QObject *parent = nullptr);
    ~StoreBackend() override;

    QString language() const { return m_language; }
    bool devSession() const;
    bool dark() const { return m_dark; }
    bool reduceMotion() const { return m_reduceMotion; }
    bool increaseContrast() const { return m_increaseContrast; }
    qreal textScale() const { return m_textScale; }
    QString accentColor() const { return m_accentColor; }
    QString accentHighlight() const { return m_accentHighlight; }
    QString shortcutStyle() const { return m_shortcutStyle; }
    QString titlebarDoubleClick() const { return m_titlebarDoubleClick; }
    bool canMinimize() const { return m_canMinimize; }
    int revision() const { return m_revision; }
    bool loading() const { return m_loading; }
    bool refreshing() const { return m_refreshing; }
    bool online() const { return m_online; }
    bool metered() const { return m_metered; }
    QVariantMap catalogStatus() const;
    QVariantMap appDataStatus() const;
    QVariantMap user() const { return m_user; }
    QVariantMap sources() const;
    QObject *focusWindow() const;
    QVariantList operations() const;
    QVariantMap results() const;
    bool staleLock() const { return m_staleLock; }

    // Discover (the catalog's, else the built-in one) and the catalog's other sections, in order.
    Q_INVOKABLE QVariantList sections() const;
    // {id, title, symbol, count}, the catalog's (else the built-in ones), those without apps left out.
    Q_INVOKABLE QVariantList categories() const;
    // A category's apps, by name; kind "" for all, else only that source.
    Q_INVOKABLE QVariantList categoryApps(const QString &id, const QString &kind = QString()) const;
    Q_INVOKABLE QVariantList search(const QString &query) const;
    // The search off the GUI thread (SR6, SU-06 note): the snapshot's model searched on a worker, answered by searchResults
    // with the same query; an answer to a query asked before the latest one is dropped (never shown over a newer one).
    Q_INVOKABLE void searchAsync(const QString &query);
    // The product page, {} when the app is not offered.
    Q_INVOKABLE QVariantMap app(const QString &id) const;
    // pacman -Si for the Information list, answered by packageInfo().
    Q_INVOKABLE void requestPackageInfo(const QString &package);
    // Installed (SR23): [{group, apps}], groups in a fixed order, apps by name; "aur" holds the packages installed explicitly
    // from outside the repositories that the AUR knows (asked once the AUR is on), "foreign" the others that own an entry,
    // "flatpak" the apps of the user's Flatpak installation (while Flathub is on; one Flathub's AppStream does not have is
    // "flatpak:<id>", opened and removed as the others).
    Q_INVOKABLE QVariantList installed() const;
    // The AUR (step 3b2; spec SR7, SR11), each asked only while the AUR is on and the Store online, answered by a signal:
    // a search by name after Return (aurResults: the results' summaries with votes and outOfDate, the most voted first, a
    // repository's names left out; problem "" | off | offline | short | tooMany | unavailable), the AUR's facts of an AUR
    // page (aurInfo: read app(id) again), and its build script (buildScript: the PKGBUILD as plain text). `id` is an AUR
    // page's ("aur:<name>") or a catalog app whose source is the AUR.
    Q_INVOKABLE void searchAur(const QString &term);
    Q_INVOKABLE void requestAur(const QString &id);
    Q_INVOKABLE void requestBuildScript(const QString &id);
    // A Flatpak's facts for the Information list (SR11), answered by flatpakInfo: {version, license, download, installed
    // (sizes as the locale writes them), access (flatpak.h flatpakAccess's keys), permissions (view::permissions: the
    // product page's cards, ADR-0049)}, from `remote-info` while it is not installed (online only), else from `info --user`;
    // {} when flatpak could not say.
    Q_INVOKABLE void requestFlatpakInfo(const QString &id);
    // Updates (SR24, SR25; step 4): software-update.json as view::updates reads it, with: checking (the shell was asked for a
    // check, not answered yet), askFailed (no shell answered), running (Omarchy's update lock held by another program, or
    // the checker says an update runs), unfinished (pacman -Qu's packages while no update runs: the last system update did
    // not finish, S12), flatpak {on, state: "" | checking | failed, apps (summaries with ref), runtimes (their count),
    // block ("" or why no Flatpak update can run now)}, and count (the apps with an update, Flatpaks included: the
    // sidebar's number). A Flatpak app, once its update is reviewed (ADR-0049): asksForMore, permissionsUnknown,
    // permissionChanges (view::permissionChanges).
    QVariantMap updates() const;
    // Check Now (SR24): the shell's check (ADR-0033 d.7), pacman -Qu, and the Flatpaks' (remote-ls --updates, S31).
    Q_INVOKABLE void checkUpdates();
    // The Updates page shown or left: shown, it checks as Settings' pane does (the shell, unless a check finished less
    // than a minute ago; the Flatpaks, unless checked less than a minute ago) and follows the update lock every 2 s.
    Q_INVOKABLE void updatesShown(bool shown);
    // The search by document type (ADR-0035 5c-3; `--page=type:<type>`): {type, description (the MIME database's), apps
    // (summaries, those that open the type first, then a parent type)}; {} for a malformed type.
    Q_INVOKABLE QVariantMap typeSearch(const QString &type) const;
    // Ctrl+R: everything read again and the catalog fetched, metered or not.
    Q_INVOKABLE void refresh();
    // grassfield.json for the settings window's switches (SD20, as the Settings app writes its keys, ADR-0020): {exists, ok,
    // text}, at most 1 MiB of a regular file; and its text written back whole (QSaveFile), "" or why it was not.
    Q_INVOKABLE QVariantMap readConfig() const;
    Q_INVOKABLE QString writeConfig(const QString &text) const;
    // A product page's Homepage or Bug tracker: https only, never in a dev session; false when not opened.
    Q_INVOKABLE bool openLink(const QString &url);
    // The image source of a screenshot ("" while screenshots are off or the Store is offline).
    Q_INVOKABLE QString screenshotSource(const QString &url) const;
    // Get and Uninstall… (SR14, SR22): what the operation would do, answered by planReady(app, kind, plan): {refusal: "" |
    // busy | unfinished | outdated | offline | dependency | protected | failed | unavailable, packages [{name, version, repo,
    // size}], download, installed, unfinished, upgrades, dependents, protected, detail}. kind: install or remove; update for
    // a Flatpak with an update or kFlatpakUpdatesApp (step 4): {refusal: "" | unavailable, detail ("held" when Update All
    // has nothing it may do alone), refs (their count), asks (the sheet must ask: the app's update asks for more or could
    // not be read), changed [{name, asks, changes (view::permissionChanges)}], unknown [names whose metadata could not be
    // read], held [names Update All leaves out: they ask for more or could not be read]} (ADR-0049). A Flatpak's install
    // plan also gives permissions (view::permissions).
    Q_INVOKABLE void plan(const QString &id, const QString &kind);
    // What the app's buttons may do now: {installed, launcher, get: "" or why not, uninstall: "" or why not} (getBlock,
    // uninstallBlock). Read again with `revision` and `operations`.
    Q_INVOKABLE QVariantMap actions(const QString &id) const;
    // The installed apps by application entry, for the launcher and Files (ADR-0046 D1): {"<desktop id>.desktop": {app, name,
    // block}}, block "" when "Uninstall…" is offered (uninstallBlock). An app the Store's model does not know is not listed.
    // `withPlans` also runs each removable repository app's -Rs plan (a pacman run each) and says "dependency", "protected" or "plan"
    // for one that would be refused: `--removable` asks, so that a delete badge never ends in a refusal.
    Q_INVOKABLE QVariantMap removalByEntry(bool withPlans = false) const;
    // The app an application entry ("x" or "x.desktop") belongs to, as `actions` takes it: "" when the Store does not know it.
    Q_INVOKABLE QString appForEntry(const QString &desktopId) const;
    // The sheet's default button: the operation joins the queue, with the plan made last for this app (false when there is
    // none, or the app cannot be installed or removed).
    Q_INVOKABLE bool install(const QString &id);
    // The running operation as an ongoing activity in the menu bar (ADR-0052): "op-<id>" -> "Installing “App”", its count
    // ("2 of 5") and bar, and Stop while it can be stopped; none while nothing runs (a waiting queue shows nothing).
    static QHash<QString, apps::OngoingActivity> ongoingActivities(const QVariantList &operations);
    Q_INVOKABLE bool uninstall(const QString &id);
    // A Flatpak's Update, or Update All of the group (kFlatpakUpdatesApp), with the plan made last for it: the refs it checked.
    Q_INVOKABLE bool update(const QString &id);
    Q_INVOKABLE bool removeWaiting(const QString &operationId);
    // The running Flatpak install stops (the ring's square, SD26); false when it cannot.
    Q_INVOKABLE bool stopOperation(const QString &operationId);
    Q_INVOKABLE void dismiss(const QString &id);
    // Open (SR21): the app's entry through uwsm (ADR-0011), a web app by omarchy-launch-webapp; false when it did not start.
    Q_INVOKABLE bool open(const QString &id);
    // Ctrl+Q: quits at once, or once the running operation ended (the window closes meanwhile; waiting ones are dropped).
    Q_INVOKABLE void quitWhenIdle();
    // The Store asked for again (a second launch handed over its page, SD35): the window is back, so the quit Ctrl+Q or the
    // closed window asked for is off; the running operation ends with the window still there.
    void reopened();
    // A quit waits for the running operation to end (quitWhenIdle, not reopened since).
    bool quitPending() const { return m_quitWhenIdle; }
    // "Open Software Update" of a refused plan (SR15): Settings at General, where Software Update lives (ADR-0033); false
    // when it did not start (in a dev session only through the fake program).
    Q_INVOKABLE bool openSoftwareUpdate();

    // The first load; the window calls it once its first frame is up.
    void start();
    // Only the read of what is on this computer (no fetch, no recovery of an earlier operation, no lock check): `--removable`
    // runs beside a Store that may be running an operation (ADR-0046 D1). loadingChanged says when it is done.
    void loadOnly()
    {
        m_loadOnly = true;
        run(Job{});
    }

    // Screenshots on and the Store online: screenshotSource's answer, and the provider's gate (kept current for it, since
    // it fetches off the GUI thread and a page may still ask after the Store went offline).
    bool screenshotsAllowed() const { return m_screenshots && m_online; }
    std::shared_ptr<const std::atomic_bool> screenshotGate() const { return m_screenshotGate; }

    // SU-07: the quit. Every job is told to stop (their fetches abort, their children are ended) and the pools are waited
    // for, `ms` at most; false when a job still runs then (the caller leaves without waiting for it: _exit).
    bool drain(int ms);
    // `--removable` (SU-02): removalByEntry(true) with each repository app's -Rs plan run on the workers, several at once,
    // the GUI thread free meanwhile; `done` runs here with the map once every plan answered.
    void removalByEntryAsync(std::function<void(const QVariantMap &)> done);

signals:
    void appearanceChanged();
    void sourcesChanged();
    void dataChanged();
    void revisionChanged();
    void loadingChanged();
    void networkChanged();
    void focusWindowChanged();
    void packageInfo(const QString &name, const QVariantMap &facts); // "package" is a reserved word in QML
    void planReady(const QString &app, const QString &kind, const QVariantMap &plan);
    void operationsChanged();
    void aurResults(const QString &term, const QVariantList &apps, const QString &problem);
    void aurInfo(const QString &id);
    void buildScript(const QString &id, const QString &text, bool ok);
    void flatpakInfo(const QString &id, const QVariantMap &facts);
    void updatesChanged();
    void searchResults(const QString &query, const QVariantList &apps);

protected:
    // The snapshot in use from now on. Protected for the unit tests (tst_storebackend), which hand it states a load
    // builds only from a signed catalog (its keys are tests/integration/store_catalog.sh's) or only for a moment.
    void apply(std::shared_ptr<const Snapshot> snapshot);

private:
    struct Job {
        bool fetchCatalog = false;
        bool forced = false; // Ctrl+R
        bool fetchAppData = false;
        bool fetchFlathub = false; // Flathub's AppStream fetched again (older than 6 hours, Ctrl+R)
    };
    void run(Job job);
    void readAppearance();
    void readNetwork();
    bool catalogStale() const;
    QLocale formats() const { return m_formats; }
    const StoreApp *storeApp(const QString &id) const;
    // A web app of Installed that our catalog does not list ("webapp:<its launcher's file name>"): opened and removed too.
    std::optional<view::WebAppEntry> otherWebApp(const QString &id) const;
    // A Flatpak of the user's installation that Flathub's AppStream does not have ("flatpak:<app id>"): its app id, or "".
    QString otherFlatpak(const QString &id) const;
    // Why a Flatpak cannot be installed or removed now, or "": dev (no fake flatpak in a dev session), noFlatpak, flathubOff.
    QString flatpakBlock() const;
    FlatpakTools flatpakTools() const;
    // Why `a` cannot be installed now, or "": dev (no fake program in a dev session), missing (Omarchy's commands or the
    // helper are not there), offline, icon (a web app's icon not cached yet), omarchyChanged (a setup: the installed
    // Omarchy differs from the catalog's pins), source (its source cannot install yet); for the AUR, aurOff, repository,
    // aurProtected (a name of the deny list), listsMissing, aurUnchecked (the catalog does not pin its command).
    QString getBlock(const StoreApp &a) const;
    // "" when "Uninstall…" is offered for `a`, else why not (SR22): system, omarchy, grassfield, dependency, notApp,
    // notFromRepository, listsMissing, notInstalled, source, dev, missing, omarchyChanged.
    QString uninstallBlock(const StoreApp &a) const;
    // A setup's path (b.2): "" when Omarchy's terminal and grassfield-store-run can run it now, else dev, missing or
    // omarchyChanged.
    QString terminalBlock() const;
    SetupCheck setupCheck(const StoreApp &a, bool install) const;
    // An Omarchy command of the terminal path (the AUR's kAurAdd, kAurDrop; Get Flatpak's kFlatpakAdd) with the catalog's
    // pins, checked as a setup's recipe.
    SetupCheck aurCheck(const QString &command) const;
    // An AUR operation's path (b.2): terminalBlock(), then aurUnchecked when the catalog's pins do not name the command.
    QString aurBlock(const QString &command) const;
    // terminalBlock(), then `unchecked` when the catalog's pins do not name `command` (and what it calls).
    QString pinnedBlock(const QString &command, const QString &unchecked) const;
    // Why "Get Flatpak…" cannot run now, or "" (SD24): installed (flatpak is there), the terminal's blocks, flatpakUnchecked
    // (the catalog does not pin omarchy-pkg-add).
    QString getFlatpakBlock() const;
    // Get Flatpak's plan (SD24): the flatpak package and what pacman adds with it, checked as a setup's (the pins, the
    // update lock, an unfinished update, the mirror), on a worker.
    void planGetFlatpak();
    // The AUR package an id names: an AUR page's, or a catalog app's whose source is the AUR ("" otherwise).
    QString aurName(const QString &id) const;
    AurConfig aurConfig() const;
    // What the AUR answered, kept for this run (full: an info answer, with its dependencies; a search's has none).
    void rememberAur(const QList<AurPackage> &packages, bool full);
    // The AUR pages' apps again, from what the AUR answered and what pacman says is installed.
    void rebuildAurApps();
    // The packages installed from outside the repositories, asked of the AUR once (Installed's "AUR" group).
    void askAurForForeign();
    QVariantMap withActions(QVariantMap map, const StoreApp &a) const;
    // Updates (step 4): the shell asked for a check (ADR-0033 d.7), pacman -Qu read, Flathub's updates listed, the file and
    // the update lock read again (updatesChanged when what the page shows moved).
    void askShellToCheck();
    void readUnfinished();
    void checkFlatpakUpdates();
    // What each listed app's update changes in what it may reach (ADR-0049), read after a check for the Updates list's
    // "Asks for more"; the update's own plan reads it again (planFlatpakUpdate).
    void reviewFlatpakUpdates();
    void followUpdates();
    // The installed Flathub app `flatpakId` names (an AppStream app of Flathub, else ""), and the update of an app id.
    const StoreApp *flatpakApp(const QString &flatpakId) const;
    std::optional<FlatpakUpdate> flatpakUpdateOf(const QString &id) const;
    // Why no Flatpak update can run now, or "": flatpakBlock()'s reasons, offline.
    QString flatpakUpdateBlock() const;
    void planFlatpakUpdate(const QString &id);
    PlanTools planTools() const;
    // pacman's lock read on a worker (its /proc walk, SU-12); staleLock follows when the answer comes.
    void checkStaleLock();
    // SU-12: what the buttons ask at each revision, cached until the next snapshot: whether a tool is executable, and the
    // parsed software-update.json until the file changes (its size and time).
    bool executable(const QString &path) const;
    mutable QHash<QString, bool> m_executable;
    struct UpdatesFileCache {
        qint64 size = -1;
        QDateTime modified;
        int revision = -1; // the snapshot's (m_revision)
        QVariantMap parsed;
    };
    mutable UpdatesFileCache m_updatesFile_;
    bool m_staleChecking = false;
    std::atomic_int m_searchGeneration{0}; // read by the search's worker

    QString m_language = QStringLiteral("en");
    QLocale m_formats;
    bool m_dark = false;
    bool m_reduceMotion = false;
    bool m_increaseContrast = false;
    qreal m_textScale = 1;
    QString m_accentColor = QStringLiteral("multicolor");
    QString m_accentHighlight = QStringLiteral("automatic");
    QString m_shortcutStyle = QStringLiteral("pc");
    QString m_titlebarDoubleClick = QStringLiteral("zoom");
    bool m_canMinimize = true;
    bool m_autoAppearance = false;
    bool m_macDevice = false;
    QFileSystemWatcher m_watcher;
    QTimer m_autoTimer;

    int m_revision = 0;
    bool m_loading = true;
    bool m_refreshing = false;
    bool m_online = true;
    bool m_metered = false;
    bool m_screenshots = true;
    bool m_aur = false;
    bool m_flathub = false;
    QVariantMap m_user;
    std::shared_ptr<const Snapshot> m_snapshot;
    bool m_jobRunning = false;
    // loadOnly(): the first load is the only job (no follow-up fetch, no AUR or Flatpak question after it).
    bool m_loadOnly = false;
    std::optional<Job> m_pendingJob;
    std::shared_ptr<std::atomic_bool> m_cancel;
    std::shared_ptr<std::atomic_bool> m_screenshotGate = std::make_shared<std::atomic_bool>(true);
    std::unique_ptr<Operations> m_operations;
    apps::OngoingPublisher *m_ongoing = nullptr; // ADR-0052: the running operation in the menu bar
    void publishOngoing();
    QHash<QString, InstallPlan> m_installPlans; // app id -> the plan its sheet showed
    QHash<QString, RemovePlan> m_removePlans;
    QHash<QString, AurPackage> m_aurPackages; // name -> what the AUR answered this run
    QSet<QString> m_aurFull;                  // the names an info answer gave (with their dependencies)
    QSet<QString> m_aurUnknown;               // the names an info answer did not know
    QSet<QString> m_aurAsked;                 // the installed foreign names asked of the AUR already
    QHash<QString, StoreApp> m_aurApps;       // "aur:<name>" -> its app
    bool m_staleLock = false;
    // Updates (step 4).
    QList<FlatpakUpdate> m_flatpakUpdates; // Flathub's only
    QString m_flatpakUpdatesState;          // "", checking, failed
    struct FlatpakReview {
        bool asks = false, unknown = false; // it asks for more; its metadata could not be read
        QVariantList changes;               // view::permissionChanges
    };
    QHash<QString, FlatpakReview> m_flatpakReview; // an app's ref -> what its listed update changes
    int m_reviewGeneration = 0;                    // a newer check's review replaces an older one's
    QDateTime m_flatpakCheckedAt;
    bool m_systemChecking = false;
    bool m_askFailed = false;
    QString m_askedCheckedAt; // the file's checkedAt when the shell was asked: a new one is its answer
    int m_unfinished = 0;
    bool m_lockHeld = false;
    QByteArray m_updatesFile; // what the page showed last
    QTimer m_checkDeadline;   // the checker's 200 s backstop (ADR-0033 d.7)
    QTimer m_updatesPoll;     // while the page is shown
    QFileSystemWatcher m_stateWatcher;
    // An update's plan (SD33): the refs it checked and, for each, the commit it checked ("" when unread: a runtime, or an
    // app the sheet said it could not check) and the commit installed then ("" unread): another one by the update's turn
    // means it was updated outside the Store, and it is left as it is (never downgraded).
    struct UpdatePlan {
        QStringList refs, commits, fromCommits;
    };
    QHash<QString, UpdatePlan> m_updatePlans;              // app id or kFlatpakUpdatesApp -> its last plan
    QHash<QString, std::pair<int, int>> m_updatePlanning; // a plan running: the apps checked, of how many
    bool m_quitWhenIdle = false;
    // SU-14: what every worker posts its answer to. Declared before the pools, so it outlives them: a job that ends while the
    // backend is destroyed posts to a live object, and the answer is dropped with it (never delivered to a dead backend). A
    // worker never reads a QPointer of the backend's (only safe on the backend's own thread).
    QObject m_context;
    QThreadPool m_searchPool; // the search's one thread (searchAsync): never behind a load's fetch
    QThreadPool m_updatePool; // Updates' jobs (step 4); with m_pool, after every other member: they wait for their jobs,
    QThreadPool m_pool;       // last member: waits for the jobs while the rest is still there; m_cancel stops their children
};

} // namespace grassfield::store
