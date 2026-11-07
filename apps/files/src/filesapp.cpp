#include "filesapp.h"
#include "applicationslogic.h"
#include "archivelogic.h"
#include "appscope.h"
#include "chromecaps.h"
#include "autoappearance.h"

#include "filelogic.h"
#include "ongoing.h"
#include "launchguard.h"
#include "navlogic.h"
#include "permissionlogic.h"
#include "foldermodel.h"
#include "folderstylelogic.h"
#include "imagerotate.h"
#include "kioprompts.h"
#include "placesmodel.h"
#include "recents.h"
#include "renamelogic.h"
#include "searchlogic.h"
#include "taglogic.h"
#include "tagstore.h"

#include <QClipboard>
#include <QDateTime>
#include <QLocale>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QDropEvent>
#include <QMimeData>
#include <QMimeDatabase>
#include <QProcess>
#include <QPair>
#include <QPointer>
#include <QRegularExpression>
#include <QSet>
#include <QStandardPaths>
#include <QStorageInfo>
#include <QThread>
#include <QTimer>
#include <QWindow>

#include <memory>

#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>

#include <KApplicationTrader>
#include <KDirNotify>
#include <KIO/ApplicationLauncherJob>
#include <KIO/CopyJob>
#include <KIO/DeleteJob>
#include <KIO/DirectorySizeJob>
#include <KIO/EmptyTrashJob>
#include <KIO/FileUndoManager>
#include <KIO/JobUiDelegateFactory>
#include <KIO/MkdirJob>
#include <KIO/DesktopExecParser>
#include <KIO/OpenUrlJob>
#include <KIO/Paste>
#include <KIO/PasteJob>
#include <KIO/RestoreJob>
#include <KIO/SimpleJob>
#include <KIO/StatJob>

namespace
{
const QString kGnomeCopied = QStringLiteral("x-special/gnome-copied-files");

FolderModel *asFolder(QObject *object)
{
    return qobject_cast<FolderModel *>(object);
}

// Grassfield's delegate asks KIO's questions (a name that exists, an item to skip, a certificate…) as the window's sheets
// (ADR-0035 D-12 a, kioprompts.h); errors are shown by the app itself (operationFailed), so automatic error dialogs stay off.
void attachDelegate(KJob *job)
{
    job->setUiDelegate(KioDialogs::createDelegate(KJobUiDelegate::AutoHandlingDisabled));
}

QUrl childUrl(const QUrl &directory, const QString &name)
{
    QUrl u = directory.adjusted(QUrl::StripTrailingSlash);
    u.setPath(u.path() + QLatin1Char('/') + name);
    return u;
}

bool localExists(const QUrl &url)
{
    return url.isLocalFile() && QFileInfo::exists(url.toLocalFile());
}

// Whether `directory` (local) holds an entry named `name` or a canonically equivalent one (NFC/NFD), other than `except`.
bool nameTaken(const QUrl &directory, const QString &name, const QString &except = QString())
{
    if (!directory.isLocalFile())
        return false;
    const QStringList entries = QDir(directory.toLocalFile()).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System);
    for (const QString &entry : entries) {
        if (entry != except && FileLogic::sameName(entry, name))
            return true;
    }
    return false;
}

// True (after saying why) when an item of `sources` would land next to a name that only differs from its own by Unicode
// normalization in the local folder `destination`: the file system would keep both, the person sees two of the same name.
// An exact match is left to the file operation (its conflict handling asks).
bool refuseTwin(FilesApp *app, const QUrl &destination, const QList<QUrl> &sources)
{
    if (!destination.isLocalFile())
        return false;
    const QStringList entries = QDir(destination.toLocalFile()).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System);
    for (const QUrl &u : sources) {
        const QString twin = FileLogic::equivalentName(entries, u.fileName());
        if (!twin.isEmpty() && !entries.contains(u.fileName())) {
            emit app->operationFailed(FilesApp::tr("“%1” can’t be copied or moved here: the folder has “%2”, which has the same name once accents are composed. Rename one of them first.")
                                          .arg(FileLogic::displayName(u.fileName()), FileLogic::displayName(twin)));
            return true;
        }
    }
    return false;
}

// Scripted scenarios set GRASSFIELD_FILES_NO_LAUNCH=1: opening reports an error instead of starting
// applications (a test must never launch the owner's apps). Logged so the scenario can assert it.
bool launchingBlocked()
{
    if (qEnvironmentVariableIntValue("GRASSFIELD_FILES_NO_LAUNCH") != 1)
        return false;
    qInfo("grassfield-files: launch blocked (GRASSFIELD_FILES_NO_LAUNCH=1)");
    return true;
}

// Files handed to one Glance at most.
constexpr int kMaxGlanceFiles = 50;

// Tags listed in the sidebar's Tags section at most.
constexpr int kMaxKnownTags = 64;
constexpr int kMaxHiddenTags = 256;

// View settings that found another Files process writing (FolderViews Busy): the first retry, the longest pause, and the
// one bounded wait, at exit.
constexpr int kFolderViewsRetryFirstMs = 50;
constexpr int kFolderViewsRetryMaxMs = 5000;
constexpr int kFolderViewsExitWaitMs = 500;

// Singular/plural pair (no translation catalogs with numerus forms yet, like the Settings app).
QString countText(const QString &one, const QString &many, qsizetype n)
{
    return n == 1 ? one : many.arg(n);
}

} // namespace

FilesApp::FilesApp(const QList<QUrl> &initialUrls, QObject *parent)
    : QObject(parent)
    , m_initialUrls(initialUrls)
    , m_prompts(KioDialogs::install(new KioPrompts(this),
                                    [this](const QString &message) {
                                        emit operationFailed(message);
                                    }))
    , m_places(new PlacesModel(this))
    , m_settings(QStringLiteral("Grassfield"), QStringLiteral("Files"))
    , m_folderViews(grassfield::apps::runmode::stateDir() + QStringLiteral("/files-views.json"))
{
    m_rotations.setMaxThreadCount(1);
    auto *undo = KIO::FileUndoManager::self();
    connect(undo, &KIO::FileUndoManager::undoAvailable, this, &FilesApp::undoChanged);
    connect(undo, &KIO::FileUndoManager::redoAvailable, this, &FilesApp::undoChanged);
    connect(undo, &KIO::FileUndoManager::undoTextChanged, this, &FilesApp::undoChanged);
    connect(undo, &KIO::FileUndoManager::redoTextChanged, this, &FilesApp::undoChanged);
    // A new command of KIO's ends the redo history, ours included (KIO clears its own).
    connect(undo, &KIO::FileUndoManager::jobRecordingStarted, this, [this] {
        m_redoCustom.clear();
        m_redoKinds.clear();
        emit undoChanged();
    });
    connect(QGuiApplication::clipboard(), &QClipboard::dataChanged, this, &FilesApp::clipboardChanged);
    connect(qGuiApp, &QGuiApplication::focusWindowChanged, this, &FilesApp::focusWindowChanged);
    connect(m_places, &PlacesModel::error, this, &FilesApp::operationFailed);
    m_savedSearches = new SavedSearches(QString(), this);
    connect(m_savedSearches, &SavedSearches::changed, this, &FilesApp::publishSavedSearches);
    publishSavedSearches();
    // The progress window's rows are published at most four times a second (KIO reports every few kilobytes).
    m_progressTimer.setSingleShot(true);
    m_progressTimer.setInterval(kProgressDelayMs);
    connect(&m_progressTimer, &QTimer::timeout, this, &FilesApp::publishJobs);
    // The jobs in the menu bar (ADR-0052): Stop there stops the job as the Copy window's button does.
    m_ongoing = new grassfield::apps::OngoingPublisher(this);
    connect(m_ongoing, &grassfield::apps::OngoingPublisher::actionInvoked, this, [this](const QString &id, const QString &action) {
        bool ok = false;
        const int job = id.startsWith(QLatin1String("copy-")) ? id.mid(5).toInt(&ok) : 0;
        if (action == QLatin1String("stop") && ok)
            cancelJob(job);
    });
    qApp->installEventFilter(this);

    // Appearance follows grassfield.json like every Grassfield surface (read only).
    const QString file = configFile();
    // Never create the directory: this app only reads the file (defaults apply until it exists).
    const QString configDir = QFileInfo(file).absolutePath();
    if (QFileInfo(configDir).isDir())
        m_watcher.addPath(configDir);
    if (QFileInfo::exists(file))
        m_watcher.addPath(file);
    // The shell's capabilities file (chromecaps.h, ADR-0015 Q4b) is watched the same way: it may not exist yet, so its directory too.
    const auto watchCapabilities = [this] {
        const QString caps = grassfield::apps::capabilitiesFile();
        if (caps.isEmpty())
            return;
        const QString capsDir = QFileInfo(caps).absolutePath();
        if (QFileInfo(capsDir).isDir() && !m_watcher.directories().contains(capsDir))
            m_watcher.addPath(capsDir);
        if (QFileInfo::exists(caps) && !m_watcher.files().contains(caps))
            m_watcher.addPath(caps);
    };
    watchCapabilities();
    const auto reread = [this, watchCapabilities] {
        const QString f = configFile();
        if (QFileInfo::exists(f) && !m_watcher.files().contains(f))
            m_watcher.addPath(f);
        watchCapabilities();
        const QString styles = m_folderStyles.fallbackFile();
        if (QFileInfo::exists(styles) && !m_watcher.files().contains(styles))
            m_watcher.addPath(styles);
        readAppearance();
        // The per-user folder style store (same directory) changed under us: every listing reads its folders again.
        if (m_folderStyles.reload()) {
            ++m_folderStyleRevision;
            emit folderStyleRevisionChanged();
            emit allFolderStylesChanged();
        }
    };
    if (QFileInfo::exists(m_folderStyles.fallbackFile()))
        m_watcher.addPath(m_folderStyles.fallbackFile());
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, reread);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, reread);
    readAppearance();
    // Auto appearance: the schedule is re-evaluated each minute while the setting is "auto".
    m_autoTimer.setInterval(grassfield::apps::kAutoRecheckMs);
    connect(&m_autoTimer, &QTimer::timeout, this, [this] {
        if (m_autoAppearance)
            readAppearance();
    });
    m_autoTimer.start();

    // The sidebar's Tags section: the tags seen in use (on shown items, set or searched in Files), kept across sessions.
    m_knownTags = TagLogic::displayOrder(m_settings.value(QStringLiteral("tags/known")).toStringList()).mid(0, kMaxKnownTags);
    m_hiddenTags = m_settings.value(QStringLiteral("tags/hidden")).toStringList().mid(0, kMaxHiddenTags);
    publishKnownTags();
    // The sidebar's Favorites as the user edited them (FP-27).
    m_sidebarFolders = NavLogic::sidebarList(m_settings.value(QStringLiteral("sidebar/favorites")).toStringList());
    for (const QString &text : m_settings.value(QStringLiteral("sidebar/hidden")).toStringList().mid(0, NavLogic::kMaxSidebarFavorites)) {
        const QUrl url = NavLogic::sidebarUrl(QUrl(text));
        if (url.isValid() && !url.scheme().isEmpty() && !m_sidebarHidden.contains(url))
            m_sidebarHidden.append(url);
    }
    m_places->setFavorites(m_sidebarFolders, m_sidebarHidden);

    m_folderViewsRetry.setSingleShot(true);
    connect(&m_folderViewsRetry, &QTimer::timeout, this, [this] {
        QString error;
        const FolderViews::WriteResult result = m_folderViews.flush(&error);
        folderViewsWritten(result, error);
    });
}

FilesApp::~FilesApp()
{
    // A picture being turned is finished before Files goes (its replacement is written whole or not at all).
    m_rotations.waitForDone();
    if (!m_folderViews.hasPending())
        return;
    QString error;
    if (m_folderViews.flush(&error, kFolderViewsExitWaitMs) != FolderViews::WriteResult::Written && !error.isEmpty())
        qWarning("grassfield-files: view settings not kept: %s", qUtf8Printable(error));
}

QString FilesApp::configFile() const
{
    return grassfield::apps::runmode::configDir() + QStringLiteral("/grassfield.json");
}

void FilesApp::readAppearance()
{
    QFile f(configFile());
    QJsonObject root;
    if (f.open(QIODevice::ReadOnly))
        root = QJsonDocument::fromJson(f.read(4 * 1024 * 1024)).object();
    // Same rule as the shell and Settings: "light" is light, "auto" follows the local schedule, anything else renders dark.
    const QString setting = root.value(QStringLiteral("appearance")).toString();
    m_autoAppearance = setting == QLatin1String("auto");
    const bool dark = grassfield::apps::isDarkAppearance(setting, QTime::currentTime());
    const QJsonObject a11y = root.value(QStringLiteral("accessibility")).toObject();
    const bool reduce = a11y.value(QStringLiteral("reduceMotion")).toBool(false);
    // Increase Contrast and Text size, read as the Store and Settings read them (ADR-0039 step 23).
    const bool contrast = a11y.value(QStringLiteral("increaseContrast")).toBool(false);
    const qreal scale = qBound(1.0, a11y.value(QStringLiteral("textSize")).toDouble(1), 1.3);
    // Icon appearance: the same validation as the shell (unknown values fall back to the defaults).
    const QJsonObject icons = root.value(QStringLiteral("icons")).toObject();
    QString mode = icons.value(QStringLiteral("mode")).toString();
    if (!QStringList{QStringLiteral("dark"), QStringLiteral("clear"), QStringLiteral("tinted")}.contains(mode))
        mode = QStringLiteral("default");
    QString tint = icons.value(QStringLiteral("tint")).toString();
    static const QRegularExpression hex(QStringLiteral("^#[0-9a-fA-F]{6}$"));
    if (!hex.match(tint).hasMatch())
        tint = QStringLiteral("accent");
    QString folderColor = icons.value(QStringLiteral("folderColor")).toString();
    static const QRegularExpression folderHex(QStringLiteral("^(theme|accent|#[0-9a-fA-F]{6})$"));
    if (!folderHex.match(folderColor).hasMatch())
        folderColor = QStringLiteral("theme");
    // Accent colour: same names as ui/Grassfield/Ui/Accent.js; anything else reads as the default.
    QString accent = root.value(QStringLiteral("accent")).toObject().value(QStringLiteral("color")).toString();
    if (!QStringList{QStringLiteral("blue"), QStringLiteral("purple"), QStringLiteral("pink"), QStringLiteral("red"), QStringLiteral("orange"),
                     QStringLiteral("yellow"), QStringLiteral("green"), QStringLiteral("graphite")}.contains(accent))
        accent = QStringLiteral("multicolor");
    // Text highlight colour: "automatic" or one of the same names (ui/Grassfield/Ui/Accent.js highlight).
    QString highlight = root.value(QStringLiteral("accent")).toObject().value(QStringLiteral("highlight")).toString();
    if (!QStringList{QStringLiteral("blue"), QStringLiteral("purple"), QStringLiteral("pink"), QStringLiteral("red"), QStringLiteral("orange"),
                     QStringLiteral("yellow"), QStringLiteral("green"), QStringLiteral("graphite")}.contains(highlight))
        highlight = QStringLiteral("automatic");
    const QString shortcuts = grassfield::apps::shortcutStyle(root.value(QStringLiteral("keyboard")).toObject().value(QStringLiteral("shortcutStyle")).toString(), m_macDevice);
    // Same rule as the compositor plugin: anything but "minimize" and "none" is the default, "zoom".
    QString doubleClick = root.value(QStringLiteral("windows")).toObject().value(QStringLiteral("titlebarDoubleClick")).toString();
    if (doubleClick != QLatin1String("minimize") && doubleClick != QLatin1String("none"))
        doubleClick = QStringLiteral("zoom");
    const bool canMinimize = grassfield::apps::minimizeAvailableInFile();
    if (doubleClick != m_titlebarDoubleClick || canMinimize != m_canMinimize) {
        m_titlebarDoubleClick = doubleClick;
        m_canMinimize = canMinimize;
        emit appearanceChanged();
    }
    if (dark != m_dark || reduce != m_reduceMotion || contrast != m_increaseContrast || scale != m_textScale || mode != m_iconMode || tint != m_iconTint
        || folderColor != m_folderColor || accent != m_accentColor || highlight != m_accentHighlight || shortcuts != m_shortcutStyle) {
        m_accentColor = accent;
        m_accentHighlight = highlight;
        m_shortcutStyle = shortcuts;
        m_folderColor = folderColor;
        m_dark = dark;
        m_reduceMotion = reduce;
        m_increaseContrast = contrast;
        m_textScale = scale;
        m_iconMode = mode;
        m_iconTint = tint;
        emit appearanceChanged();
    }
}

QObject *FilesApp::focusWindow() const
{
    return QGuiApplication::focusWindow();
}

QObject *FilesApp::places() const
{
    return m_places;
}

QObject *FilesApp::prompts() const
{
    return m_prompts;
}

QObject *FilesApp::applicationChooser() const
{
    return m_prompts->applications();
}

QString FilesApp::homePath() const
{
    return QDir::homePath();
}

// Whether Undo would take Files' own newest command rather than KIO's (the newer of the two by serial number).
bool FilesApp::customUndoIsNext() const
{
    auto *kio = KIO::FileUndoManager::self();
    return !m_undoCustom.isEmpty() && (!kio->isUndoAvailable() || m_undoCustom.last().serial > kio->currentCommandSerialNumber());
}

namespace
{
// What the user is told after a command stopped part-way: all was put back, or these items stayed changed (and Undo, which
// the caller keeps for them, puts them back).
QString rollbackNote(const BatchOps::Steps &stayed)
{
    if (stayed.isEmpty())
        return FilesApp::tr("Nothing was changed.");
    QStringList names;
    for (const BatchOps::Step &step : stayed) {
        if (names.size() < 3)
            names << QStringLiteral("“%1”").arg(FileLogic::displayName(QFileInfo(step.to).fileName()));
    }
    QString list = names.join(QStringLiteral(", "));
    if (stayed.size() > names.size())
        list += FilesApp::tr(" and %1 more").arg(stayed.size() - names.size());
    return FilesApp::tr("These stayed changed: %1. Undo puts them back.").arg(list);
}
} // namespace

bool FilesApp::canUndo() const
{
    return !m_undoCustom.isEmpty() || KIO::FileUndoManager::self()->isUndoAvailable();
}

QString FilesApp::undoText() const
{
    if (customUndoIsNext())
        return tr("Undo %1").arg(m_undoCustom.last().text);
    return KIO::FileUndoManager::self()->undoText();
}

bool FilesApp::canRedo() const
{
    // The redo history is the undone commands of Files (m_redoKinds): a command made after an undo ends it, whatever KIO
    // still keeps on its own redo stack.
    if (m_redoKinds.isEmpty())
        return false;
    return m_redoKinds.last() ? !m_redoCustom.isEmpty() : KIO::FileUndoManager::self()->isRedoAvailable();
}

QString FilesApp::redoText() const
{
    if (m_redoKinds.isEmpty())
        return {};
    if (m_redoKinds.last())
        return m_redoCustom.isEmpty() ? QString() : tr("Redo %1").arg(m_redoCustom.last().text);
    return KIO::FileUndoManager::self()->redoText();
}

void FilesApp::recordCustom(const QString &text, const BatchOps::Steps &steps)
{
    if (steps.isEmpty())
        return;
    // A new command ends the redo history; KIO's own redo stack stays but is never reached again (m_redoKinds is empty).
    m_redoCustom.clear();
    m_redoKinds.clear();
    m_undoCustom.append({KIO::FileUndoManager::self()->newCommandSerialNumber(), text, steps});
    emit undoChanged();
}

bool FilesApp::canPaste() const
{
    return !KioDialogs::pastableItems(QGuiApplication::clipboard()->mimeData()).isEmpty();
}

int FilesApp::clipboardCount() const
{
    return int(KioDialogs::pastableItems(QGuiApplication::clipboard()->mimeData()).size());
}

QString FilesApp::viewMode() const
{
    const QString mode = m_settings.value(QStringLiteral("view/mode"), QStringLiteral("icons")).toString();
    return mode == QLatin1String("list") || mode == QLatin1String("columns") || mode == QLatin1String("gallery") ? mode : QStringLiteral("icons");
}

void FilesApp::setViewMode(const QString &mode)
{
    if (mode == viewMode())
        return;
    m_settings.setValue(QStringLiteral("view/mode"), mode);
    emit prefsChanged();
}

int FilesApp::sortKey() const
{
    return qBound(0, m_settings.value(QStringLiteral("view/sortKey"), 0).toInt(), FileLogic::kSortKeyCount - 1);
}

void FilesApp::setSortKey(int key)
{
    if (key == sortKey())
        return;
    m_settings.setValue(QStringLiteral("view/sortKey"), key);
    emit prefsChanged();
}

bool FilesApp::sortDescending() const
{
    return m_settings.value(QStringLiteral("view/sortDescending"), false).toBool();
}

void FilesApp::setSortDescending(bool on)
{
    if (on == sortDescending())
        return;
    m_settings.setValue(QStringLiteral("view/sortDescending"), on);
    emit prefsChanged();
}

bool FilesApp::foldersFirst() const
{
    return m_settings.value(QStringLiteral("view/foldersFirst"), true).toBool();
}

void FilesApp::setFoldersFirst(bool on)
{
    if (on == foldersFirst())
        return;
    m_settings.setValue(QStringLiteral("view/foldersFirst"), on);
    emit prefsChanged();
}

bool FilesApp::showHidden() const
{
    return m_settings.value(QStringLiteral("view/showHidden"), false).toBool();
}

void FilesApp::setShowHidden(bool on)
{
    if (on == showHidden())
        return;
    m_settings.setValue(QStringLiteral("view/showHidden"), on);
    emit prefsChanged();
}

bool FilesApp::galleryInfo() const
{
    return m_settings.value(QStringLiteral("view/galleryInfo"), true).toBool();
}

void FilesApp::setGalleryInfo(bool on)
{
    if (on == galleryInfo())
        return;
    m_settings.setValue(QStringLiteral("view/galleryInfo"), on);
    emit prefsChanged();
}

bool FilesApp::tabBarShown() const
{
    return m_settings.value(QStringLiteral("view/tabBar"), false).toBool();
}

void FilesApp::setTabBarShown(bool on)
{
    if (on == tabBarShown())
        return;
    m_settings.setValue(QStringLiteral("view/tabBar"), on);
    emit prefsChanged();
}

bool FilesApp::pathBarShown() const
{
    return m_settings.value(QStringLiteral("view/pathBar"), false).toBool();
}

void FilesApp::setPathBarShown(bool on)
{
    if (on == pathBarShown())
        return;
    m_settings.setValue(QStringLiteral("view/pathBar"), on);
    emit prefsChanged();
}

bool FilesApp::statusBarShown() const
{
    return m_settings.value(QStringLiteral("view/statusBar"), false).toBool();
}

void FilesApp::setStatusBarShown(bool on)
{
    if (on == statusBarShown())
        return;
    m_settings.setValue(QStringLiteral("view/statusBar"), on);
    emit prefsChanged();
}

bool FilesApp::sidebarShown() const
{
    return m_settings.value(QStringLiteral("view/sidebar"), true).toBool();
}

void FilesApp::setSidebarShown(bool on)
{
    if (on == sidebarShown())
        return;
    m_settings.setValue(QStringLiteral("view/sidebar"), on);
    emit prefsChanged();
}

bool FilesApp::previewPane() const
{
    return m_settings.value(QStringLiteral("view/preview"), false).toBool();
}

void FilesApp::setPreviewPane(bool on)
{
    if (on == previewPane())
        return;
    m_settings.setValue(QStringLiteral("view/preview"), on);
    emit prefsChanged();
}

bool FilesApp::columnPreview() const
{
    return m_settings.value(QStringLiteral("view/columnPreview"), true).toBool();
}

void FilesApp::setColumnPreview(bool on)
{
    if (on == columnPreview())
        return;
    m_settings.setValue(QStringLiteral("view/columnPreview"), on);
    emit prefsChanged();
}

QList<QUrl> FilesApp::rotatableImages(const QList<QUrl> &urls) const
{
    QList<QUrl> out;
    if (urls.size() > kMaxQuickActionItems)
        return out;
    static const QMimeDatabase mimes;
    for (const QUrl &url : urls) {
        if (!url.isLocalFile())
            continue;
        const QFileInfo fi(url.toLocalFile());
        if (fi.isSymLink() || !fi.isFile() || !fi.isWritable())
            continue;
        if (ImageRotate::methodFor(mimes.mimeTypeForFile(fi).name().toLatin1()) != ImageRotate::Method::None)
            out.append(url);
    }
    return out;
}

void FilesApp::rotateImages(const QList<QUrl> &urls, bool clockwise)
{
    const QList<QUrl> todo = rotatableImages(urls);
    if (todo.isEmpty())
        return;
    // A large picture or a slow disk must not stop the windows: the files are read and written on m_rotations' thread.
    m_rotations.start([this, todo, clockwise] {
        const QMimeDatabase mimes;
        QStringList failures;
        QList<QUrl> changed;
        for (const QUrl &url : todo) {
            const QString path = url.toLocalFile();
            const QString error = ImageRotate::rotate(path, mimes.mimeTypeForFile(path).name().toLatin1(), clockwise);
            if (error.isEmpty())
                changed.append(url);
            else
                failures.append(tr("“%1” couldn’t be turned: %2.").arg(FileLogic::displayName(QFileInfo(path).fileName()), error));
        }
        QMetaObject::invokeMethod(this, [this, failures, changed] {
            for (const QString &failure : failures)
                emit operationFailed(failure);
            // Listings and thumbnails follow (KDirLister refreshes the items, the thumbnails are made again).
            if (!changed.isEmpty())
                org::kde::KDirNotify::emitFilesChanged(changed);
        }, Qt::QueuedConnection);
    });
}

int FilesApp::windowWidth() const
{
    return FileLogic::keptWindowSide(m_settings.value(QStringLiteral("window/width")));
}

int FilesApp::windowHeight() const
{
    return FileLogic::keptWindowSide(m_settings.value(QStringLiteral("window/height")));
}

void FilesApp::rememberWindowSize(int width, int height)
{
    if (!FileLogic::keepsWindowSize(width, height))
        return;
    if (width == windowWidth() && height == windowHeight())
        return;
    m_settings.setValue(QStringLiteral("window/width"), width);
    m_settings.setValue(QStringLiteral("window/height"), height);
    emit windowSizeChanged();
}

QUrl FilesApp::newWindowUrl() const
{
    return QUrl::fromLocalFile(homePath());
}

QVariantMap FilesApp::folderView(const QUrl &url) const
{
    // Another Files process may have written the file since (one stat when nothing changed).
    m_folderViews.refresh();
    const FolderViews::Entry e = m_folderViews.entry(FolderViews::keyFor(url));
    QVariantMap out;
    if (!e.mode.isEmpty())
        out.insert(QStringLiteral("mode"), e.mode);
    if (e.sortKey >= 0)
        out.insert(QStringLiteral("sortKey"), e.sortKey);
    if (e.descending >= 0)
        out.insert(QStringLiteral("sortDescending"), e.descending == 1);
    if (e.groupBy >= 0)
        out.insert(QStringLiteral("groupBy"), e.groupBy);
    return out;
}

void FilesApp::setFolderView(const QUrl &url, const QVariantMap &fields)
{
    FolderViews::Entry e;
    if (fields.contains(QStringLiteral("mode")))
        e.mode = fields.value(QStringLiteral("mode")).toString();
    if (fields.contains(QStringLiteral("sortKey")))
        e.sortKey = fields.value(QStringLiteral("sortKey")).toInt();
    if (fields.contains(QStringLiteral("sortDescending")))
        e.descending = fields.value(QStringLiteral("sortDescending")).toBool() ? 1 : 0;
    if (fields.contains(QStringLiteral("groupBy")))
        e.groupBy = fields.value(QStringLiteral("groupBy")).toInt();
    QString error;
    const FolderViews::WriteResult result = m_folderViews.set(FolderViews::keyFor(url), e, &error);
    folderViewsWritten(result, error);
}

void FilesApp::folderViewsWritten(FolderViews::WriteResult result, const QString &error)
{
    switch (result) {
    case FolderViews::WriteResult::Written:
        m_folderViewsRetryMs = 0;
        m_folderViewsRetry.stop();
        m_folderViewsRefusal.clear();
        return;
    case FolderViews::WriteResult::Busy:
        // Another Files process is writing (a few ms): try again shortly, then less and less often (a lock held by a
        // stopped process is taken over by QLockFile after 30 s).
        m_folderViewsRetryMs = qBound(kFolderViewsRetryFirstMs, m_folderViewsRetryMs * 2, kFolderViewsRetryMaxMs);
        m_folderViewsRetry.start(m_folderViewsRetryMs);
        return;
    case FolderViews::WriteResult::Refused:
        // The file can't be written (not a regular file, too large, unreadable, a newer version's, a lock path that is
        // not a lock file): the choice holds in this process and is written with the next one once the file is usable.
        // The view itself already changed; the failure is logged once per reason, not shown, and never retried by timer.
        m_folderViewsRetryMs = 0;
        m_folderViewsRetry.stop();
        if (!error.isEmpty() && error != m_folderViewsRefusal) {
            m_folderViewsRefusal = error;
            qWarning("grassfield-files: view settings not kept: %s", qUtf8Printable(error));
        }
        return;
    }
}

void FilesApp::reparent(QObject *object, QObject *parent)
{
    if (object && parent && object != parent)
        object->setParent(parent);
}

QObject *FilesApp::createFolderModel(QObject *parent)
{
    auto *model = new FolderModel(parent ? parent : this);
    connect(model, &FolderModel::tagsSeen, this, &FilesApp::noteTags);
    connect(model, &FolderModel::applicationsListed, this, [this](const QVariantMap &paths, const QVariantMap &names) { m_applicationPaths = paths; m_applicationNames = names; });
    connect(this, &FilesApp::tagsChanged, model, &FolderModel::tagsChanged);
    model->setStyleStore(&m_folderStyles);
    connect(this, &FilesApp::folderStylesChanged, model, &FolderModel::folderStylesChanged);
    connect(this, &FilesApp::allFolderStylesChanged, model, &FolderModel::allFolderStylesChanged);
    return model;
}

QVariantList FilesApp::pathSegments(const QUrl &url) const
{
    QVariantList out;
    if (ApplicationsLogic::isLocationUrl(url)) {
        out.append(QVariantMap{{QStringLiteral("label"), tr("Applications")}, {QStringLiteral("url"), ApplicationsLogic::locationUrl()}});
        return out;
    }
    if (Recents::isRecentsUrl(url)) {
        out.append(QVariantMap{{QStringLiteral("label"), tr("Recents")}, {QStringLiteral("url"), url}});
        return out;
    }
    // A search: one segment, its title (the path bar shows the selected result's path instead: BrowserWindow).
    if (SearchLogic::isSearchUrl(url)) {
        const auto query = SearchLogic::fromUrl(url);
        const QString scope = query && !query->inComputer() ? QFileInfo(query->folder.toLocalFile()).fileName() : tr("This Computer");
        out.append(QVariantMap{{QStringLiteral("label"), tr("Searching “%1”").arg(FileLogic::displayName(scope))}, {QStringLiteral("url"), url}});
        return out;
    }
    // A tag search: the segments of its folder, then the tag.
    const bool search = TagLogic::isSearchUrl(url);
    const QUrl folder = search ? TagLogic::searchFolder(url) : url;
    const QList<FileLogic::Segment> segments = FileLogic::pathSegments(folder, QDir::homePath(), tr("Computer"), tr("Trash"));
    for (const FileLogic::Segment &s : segments)
        out.append(QVariantMap{{QStringLiteral("label"), s.label}, {QStringLiteral("url"), s.url}});
    if (search)
        out.append(QVariantMap{{QStringLiteral("label"), TagLogic::displayName(TagLogic::searchTag(url))}, {QStringLiteral("url"), url}});
    return out;
}

QString FilesApp::formatSize(qint64 bytes) const
{
    return FileLogic::formatSize(bytes);
}

bool FilesApp::isValidFileName(const QString &name) const
{
    return FileLogic::isValidFileName(name);
}

int FilesApp::baseNameLength(const QString &name, bool isDir) const
{
    return FileLogic::baseNameLength(name, isDir);
}

bool FilesApp::defaultDescending(int sortKey) const
{
    return FileLogic::defaultDescending(FileLogic::SortKey(qBound(0, sortKey, FileLogic::kSortKeyCount - 1)));
}

QString FilesApp::uriList(const QList<QUrl> &urls) const
{
    QStringList lines;
    for (const QUrl &u : urls)
        lines << QString::fromUtf8(u.toEncoded());
    return lines.join(QStringLiteral("\r\n")) + QStringLiteral("\r\n");
}

bool FilesApp::sameUrl(const QUrl &a, const QUrl &b) const
{
    return a.isValid() && a.adjusted(QUrl::StripTrailingSlash | QUrl::NormalizePathSegments) == b.adjusted(QUrl::StripTrailingSlash | QUrl::NormalizePathSegments);
}

bool FilesApp::isDirectChild(const QUrl &parent, const QUrl &child) const
{
    return child.isValid() && sameUrl(child.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash), parent);
}

QUrl FilesApp::resolveLocation(const QString &text, const QUrl &base) const
{
    const QUrl url = locationUrl(text, base);
    if (!url.isLocalFile())
        return url;
    const QFileInfo info(url.toLocalFile());
    return info.isDir() ? QUrl::fromLocalFile(info.absoluteFilePath()) : QUrl();
}

QUrl FilesApp::locationUrl(const QString &text, const QUrl &base) const
{
    const QString t = text.trimmed();
    if (t.isEmpty())
        return {};
    QString path;
    if (t == QLatin1String("~"))
        path = QDir::homePath();
    else if (t.startsWith(QLatin1String("~/")))
        path = QDir::homePath() + t.mid(1);
    else if (t.startsWith(QLatin1Char('/')))
        path = t;
    else if (t.contains(QLatin1String(":/")) || t.endsWith(QLatin1Char(':'))) {
        QUrl url(t.endsWith(QLatin1Char(':')) ? t + QLatin1Char('/') : t);
        if (url.isLocalFile())
            path = url.toLocalFile();
        else
            return url.isValid() ? url : QUrl();
    } else if (base.isLocalFile())
        path = QDir(base.toLocalFile()).filePath(t);
    else {
        QUrl url = base.adjusted(QUrl::StripTrailingSlash);
        url.setPath(url.path() + QLatin1Char('/') + t);
        return url;
    }
    return QUrl::fromLocalFile(QDir::cleanPath(path));
}

void FilesApp::open(const QList<QUrl> &urls)
{
    // macOS Gatekeeper model (GF-070, DT-10): opening never runs a program, a script or an app launcher; they are refused
    // here, before KIO sees them, whatever KIO would do. Decided before the test switch below so a scripted test sees it.
    QList<QUrl> allowed;
    QList<QUrl> webLinks; // addresses of web-link files, for the default web browser only
    QString refusedName;
    LaunchGuard::Verdict refusedKind = LaunchGuard::Verdict::Open;
    int refused = 0;
    for (const QUrl &url : urls) {
        const LaunchGuard::Facts facts = LaunchGuard::inspect(url);
        const LaunchGuard::Verdict v = LaunchGuard::verdict(facts);
        if (v == LaunchGuard::Verdict::Open) {
            allowed << url;
            continue;
        }
        if (v == LaunchGuard::Verdict::OpenWebLinkInBrowser) {
            webLinks << LaunchGuard::webLink(facts);
            continue;
        }
        qInfo("grassfield-files: open refused (%s)", v == LaunchGuard::Verdict::RefuseLauncher ? "app launcher" : "program or script");
        if (refused++ == 0) {
            refusedName = url.fileName();
            refusedKind = v;
        }
    }
    if (refused == 1 && refusedKind == LaunchGuard::Verdict::RefuseLauncher)
        emit operationFailed(tr("“%1” was not opened: it is an app launcher, and Files never starts apps from a folder. Open apps from the Dock, Apps or Search.").arg(FileLogic::displayName(refusedName)));
    else if (refused == 1)
        emit operationFailed(tr("“%1” was not opened: it is a program or script, and Files never runs programs from a folder. To run it on purpose, use a terminal.").arg(FileLogic::displayName(refusedName)));
    else if (refused > 1)
        emit operationFailed(tr("%1 items were not opened: Files never runs programs, scripts or app launchers from a folder.").arg(refused));
    // An archive opens by expanding next to itself (the Finder's Archive Utility, ADR-0029); Open With still offers the
    // applications that read it.
    for (auto it = allowed.begin(); it != allowed.end();) {
        if (isArchive(*it) && QFileInfo(it->toLocalFile()).isFile()) {
            expand(*it, nullptr);
            it = allowed.erase(it);
        } else {
            ++it;
        }
    }
    if (allowed.isEmpty() && webLinks.isEmpty())
        return;
    if (launchingBlocked()) {
        emit operationFailed(tr("Opening files is disabled in this session (GRASSFIELD_FILES_NO_LAUNCH)."));
        return;
    }
    // A web link file opens its address in the user's default web browser and nowhere else (macOS: a .webloc opens in the
    // browser): never through KIO, which would fetch the address and run whatever handles the type the server announces,
    // and never with the application the file names (X-KDE-LastOpenedWith).
    for (const QUrl &address : std::as_const(webLinks)) {
        const KService::Ptr browser = KApplicationTrader::preferredService(QStringLiteral("x-scheme-handler/") + address.scheme().toLower());
        if (!browser) {
            emit operationFailed(tr("The web link was not opened: no default web browser is set."));
            continue;
        }
        qInfo("grassfield-files: web link opened in the default web browser");
        auto *job = new KIO::ApplicationLauncherJob(browser, this);
        job->setUrls({address});
        attachDelegate(job);
        connect(job, &KJob::result, this, [this, job] {
            if (job->error() && job->error() != KIO::ERR_USER_CANCELED)
                emit operationFailed(job->errorString());
        });
        job->start();
    }
    for (const QUrl &url : std::as_const(allowed)) {
        auto *job = new KIO::OpenUrlJob(url, this);
        attachDelegate(job);
        // Never run programs or scripts from the file manager: they open in their associated app.
        job->setRunExecutables(false);
        connect(job, &KJob::result, this, [this, job] {
            if (job->error() && job->error() != KIO::ERR_USER_CANCELED)
                emit operationFailed(job->errorString());
        });
        job->start();
    }
}

QVariantList FilesApp::applicationsFor(const QList<QUrl> &urls) const
{
    QVariantList out;
    if (urls.isEmpty())
        return out;
    const QUrl &first = urls.first();
    if (first.scheme() == QLatin1String("grassfield-app") || ApplicationsLogic::isLocationUrl(first))
        return out; // an application of the Applications location is no file: nothing opens it "with"
    QMimeDatabase db;
    const QMimeType type = first.isLocalFile() ? db.mimeTypeForFile(first.toLocalFile()) : db.mimeTypeForUrl(first);
    const KService::List services = KApplicationTrader::queryByMimeType(type.name());
    for (const KService::Ptr &s : services) {
        if (s->desktopEntryName() == QLatin1String("org.grassfield.files"))
            continue;
        out.append(QVariantMap{{QStringLiteral("id"), s->storageId()}, {QStringLiteral("name"), s->name()}});
    }
    return out;
}

void FilesApp::openWith(const QString &storageId, const QList<QUrl> &urls)
{
    for (const QUrl &u : urls) {
        if (u.scheme() == QLatin1String("grassfield-app") || ApplicationsLogic::isLocationUrl(u)) {
            emit operationFailed(tr("An application is not a file: it cannot be opened with another application."));
            return;
        }
    }
    const KService::Ptr service = KService::serviceByStorageId(storageId);
    if (!service) {
        emit operationFailed(tr("The application is no longer installed."));
        return;
    }
    if (launchingBlocked()) {
        emit operationFailed(tr("Opening files is disabled in this session (GRASSFIELD_FILES_NO_LAUNCH)."));
        return;
    }
    // A terminal application (Terminal=true: nvim, htop…) runs in the session's terminal (decision F-7, FP-80):
    // KIO would look for KDE's terminal setting (konsole, absent on Omarchy). Its command line is KIO's own (the field
    // codes filled with the items), behind xdg-terminal-exec, in the application scope the Apps grid uses.
    if (service->terminal()) {
        KService::Ptr plain(new KService(*service));
        plain->setTerminal(false);
        KIO::DesktopExecParser parser(*plain, urls);
        const QStringList command = parser.resultingArguments();
        if (command.isEmpty()) {
            emit operationFailed(tr("“%1” could not be started.").arg(FileLogic::displayName(service->name())));
            return;
        }
        const QStringList argv = grassfield::apps::scopedCommand(QStringLiteral("xdg-terminal-exec"), command, grassfield::apps::scopedLaunch());
        QProcess process;
        process.setProgram(argv.first());
        process.setArguments(argv.mid(1));
        if (!urls.isEmpty() && urls.first().isLocalFile())
            process.setWorkingDirectory(QFileInfo(urls.first().toLocalFile()).absolutePath());
        if (!process.startDetached())
            emit operationFailed(tr("“%1” could not be started.").arg(FileLogic::displayName(service->name())));
        return;
    }
    auto *job = new KIO::ApplicationLauncherJob(service, this);
    job->setUrls(urls);
    attachDelegate(job);
    connect(job, &KJob::result, this, [this, job] {
        if (job->error() && job->error() != KIO::ERR_USER_CANCELED)
            emit operationFailed(job->errorString());
    });
    job->start();
}

void FilesApp::chooseApplication(const QList<QUrl> &urls)
{
    if (urls.isEmpty())
        return;
    for (const QUrl &u : urls) {
        if (u.scheme() == QLatin1String("grassfield-app") || ApplicationsLogic::isLocationUrl(u)) {
            emit operationFailed(tr("An application is not a file: it cannot be opened with another application."));
            return;
        }
    }
    m_prompts->applications()->ask(urls, {}, nullptr, [this, urls](const QString &id) {
        if (!id.isEmpty())
            openWith(id + QLatin1String(".desktop"), urls);
    });
}

QUrl FilesApp::applicationsUrl() const
{
    return ApplicationsLogic::locationUrl();
}

QUrl FilesApp::applicationUrl(const QString &id) const
{
    return ApplicationsLogic::entryUrl(id);
}

QString FilesApp::applicationId(const QUrl &url) const
{
    return ApplicationsLogic::entryId(url);
}

int FilesApp::applicationsCount() const
{
    return int(m_applicationPaths.size()); // the location lists them (FolderModel::applicationsListed); never walked here
}

bool FilesApp::isApplicationUrl(const QUrl &url) const
{
    return !ApplicationsLogic::entryId(url).isEmpty();
}

void FilesApp::launchApplication(const QUrl &url)
{
    const QString id = ApplicationsLogic::entryId(url);
    if (id.isEmpty())
        return;
    KService::Ptr service = KService::serviceByStorageId(id + QStringLiteral(".desktop"));
    if (!service)
        service = KService::serviceByDesktopName(id);
    if (!service) {
        emit operationFailed(tr("The application is no longer installed."));
        return;
    }
    if (launchingBlocked()) {
        emit operationFailed(tr("Opening files is disabled in this session (GRASSFIELD_FILES_NO_LAUNCH)."));
        return;
    }
    // The way the shell's Apps grid starts it (Apps.launchNow): the Exec line without its field codes, behind xdg-terminal-exec
    // for Terminal=true (KIO would ask KDE's terminal setting: konsole, not installed on Omarchy), in the scope uwsm-app gives a
    // real session. An entry without an Exec line (D-Bus activation only) is left to KIO.
    const QStringList command = ApplicationsLogic::launchCommand(service->exec(), service->terminal());
    if (!command.isEmpty()) {
        const QStringList argv = grassfield::apps::scopedCommand(command.first(), command.mid(1), grassfield::apps::scopedLaunch());
        QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
        if (qEnvironmentVariable("GRASSFIELD_APPS_GTK_USE_PORTAL") == QLatin1String("1"))
            environment.insert(QStringLiteral("GTK_USE_PORTAL"), QStringLiteral("1")); // shell/services/AppLaunch.js portalEnvironment
        QProcess process;
        process.setProgram(argv.first());
        process.setArguments(argv.mid(1));
        process.setProcessEnvironment(environment);
        if (!service->workingDirectory().isEmpty())
            process.setWorkingDirectory(service->workingDirectory());
        if (!process.startDetached())
            emit operationFailed(tr("“%1” could not be started.").arg(FileLogic::displayName(m_applicationNames.value(id).toString().isEmpty() ? service->name() : m_applicationNames.value(id).toString())));
        return;
    }
    auto *job = new KIO::ApplicationLauncherJob(service, this);
    attachDelegate(job);
    connect(job, &KJob::result, this, [this, job] {
        if (job->error() && job->error() != KIO::ERR_USER_CANCELED)
            emit operationFailed(job->errorString());
    });
    job->start();
}

namespace {

// Grassfield Store, when it is there: in a dev session the grassfield-store beside this binary (a dev build, ADR-0019), else the
// PATH's; "" without one.
QString storeProgram()
{
    const QString sibling = QCoreApplication::applicationDirPath() + QStringLiteral("/grassfield-store");
    if (grassfield::apps::runmode::dev() && QFileInfo(sibling).isExecutable())
        return sibling;
    return QStandardPaths::findExecutable(QStringLiteral("grassfield-store"));
}

constexpr qint64 kMaxRemovableBytes = 4 * 1024 * 1024; // the Store's answer is far smaller; anything longer is not its answer
constexpr int kRemovableTimeoutMs = 120000;
constexpr int kRemovableFreshSeconds = 60;

} // namespace

void FilesApp::loadRemovableApplications()
{
    // Dev plumbing (honoured only in a dev session, runmode.h): the Store's answer as given, for captures without pacman.
    const QString given = grassfield::apps::runmode::devValue("FILES_REMOVABLE_JSON");
    if (!given.isEmpty()) {
        if (given != m_removableText) {
            m_removableText = given;
            emit removableTextChanged();
        }
        return;
    }
    if (m_removableProcess || (m_removableAt.isValid() && m_removableAt.secsTo(QDateTime::currentDateTime()) < kRemovableFreshSeconds))
        return;
    const QString program = storeProgram();
    if (program.isEmpty())
        return; // no Store: nothing is offered for removal
    auto *process = new QProcess(this);
    m_removableProcess = process;
    process->setProgram(program);
    process->setArguments({QStringLiteral("--removable")});
    process->setProcessChannelMode(QProcess::SeparateChannels);
    connect(process, &QProcess::finished, this, [this, process](int code, QProcess::ExitStatus status) {
        const QByteArray out = process->readAllStandardOutput();
        const bool ok = status == QProcess::NormalExit && code == 0 && out.size() <= kMaxRemovableBytes;
        m_removableAt = QDateTime::currentDateTime();
        const QString text = ok ? QString::fromUtf8(out) : QString();
        if (text != m_removableText) {
            m_removableText = text;
            emit removableTextChanged();
        }
        process->deleteLater();
    });
    connect(process, &QProcess::errorOccurred, this, [process](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            process->deleteLater();
    });
    QTimer::singleShot(kRemovableTimeoutMs, process, [process] {
        if (process->state() != QProcess::NotRunning)
            process->kill();
    });
    process->start();
}

void FilesApp::uninstallApplication(const QString &id)
{
    // An id of the Applications location: what the Store keys an entry by, nothing an option or a path could ride on.
    static const QRegularExpression valid(QStringLiteral(R"(\A[A-Za-z0-9][A-Za-z0-9._+@-]{0,200}\z)"));
    const QString program = storeProgram();
    if (!valid.match(id).hasMatch() || program.isEmpty() || launchingBlocked()) {
        emit operationFailed(tr("The Store can’t uninstall this application."));
        return;
    }
    if (!grassfield::apps::startApplication(program, {QStringLiteral("--page"), QStringLiteral("uninstall:") + id + QStringLiteral(".desktop")}))
        emit operationFailed(tr("The Store could not be started."));
}

void FilesApp::glance(const QList<QUrl> &urls)
{
    // Glance shows local regular files only (it validates them again): folders and remote items are skipped.
    QStringList paths;
    for (const QUrl &url : urls) {
        if (url.isLocalFile() && QFileInfo(url.toLocalFile()).isFile() && paths.size() < kMaxGlanceFiles)
            paths << url.toLocalFile();
    }
    if (paths.isEmpty() || launchingBlocked())
        return;
    // GRASSFIELD_PREVIEW_CMD (dev plumbing: honoured only in a dev session, runmode.h) wins, then a grassfield-preview next
    // to this binary, then the PATH.
    QStringList command = grassfield::apps::runmode::devValue("PREVIEW_CMD").split(QLatin1Char(' '), Qt::SkipEmptyParts);
    if (command.isEmpty()) {
        const QString sibling = QCoreApplication::applicationDirPath() + QStringLiteral("/grassfield-preview");
        command << (QFileInfo(sibling).isExecutable() ? sibling : QStringLiteral("grassfield-preview"));
    }
    const QString program = command.takeFirst();
    command.removeAll(QStringLiteral("--glance"));
    const QStringList args = command + QStringList{QStringLiteral("--glance"), QStringLiteral("--")} + paths;
    if (!grassfield::apps::startApplication(program, args))
        emit operationFailed(tr("Glance could not be started: grassfield-preview was not found."));
}

// The Applications location is read-only (Finder: the apps of /Applications cannot be renamed, moved or deleted by the
// user): its items are never copied, moved, trashed or renamed, nothing is dropped or pasted into it, and the reason is
// the one Finder gives (no permission).
bool FilesApp::refuseApplicationItems(const QList<QUrl> &urls)
{
    for (const QUrl &u : urls) {
        if (u.scheme() == QLatin1String("grassfield-app") || ApplicationsLogic::isLocationUrl(u)) {
            emit operationFailed(tr("The operation can’t be completed because you don’t have permission to access some of the items."));
            return true;
        }
    }
    return false;
}

// Copy of an application: the Finder copies the app, and pasting elsewhere makes a copy of it. Here the application is its desktop
// entry, so Copy puts the entry's file on the clipboard (a launcher to paste somewhere); Cut is refused like a move.
QList<QUrl> FilesApp::applicationFiles(const QList<QUrl> &urls) const
{
    const QVariantMap &paths = m_applicationPaths; // the rows on show: Copy is only possible from the location
    QList<QUrl> files;
    for (const QUrl &u : urls) {
        const QString id = ApplicationsLogic::entryId(u);
        if (id.isEmpty() || !paths.contains(id))
            return {};
        files << QUrl::fromLocalFile(paths.value(id).toString());
    }
    return files;
}

void FilesApp::copyToClipboard(const QList<QUrl> &urlsIn, bool cut)
{
    QList<QUrl> urls = urlsIn;
    if (!cut && !urls.isEmpty() && ApplicationsLogic::entryId(urls.first()).size() > 0) {
        urls = applicationFiles(urlsIn);
        if (urls.isEmpty())
            return;
    } else if (refuseApplicationItems(urls)) {
        return;
    }
    if (urls.isEmpty())
        return;
    auto *data = new QMimeData;
    data->setUrls(urls);
    KIO::setClipboardDataCut(data, cut);
    // GNOME file managers read their own format.
    QStringList gnome{cut ? QStringLiteral("cut") : QStringLiteral("copy")};
    for (const QUrl &u : urls)
        gnome << QString::fromUtf8(u.toEncoded());
    data->setData(kGnomeCopied, gnome.join(QLatin1Char('\n')).toUtf8());
    QGuiApplication::clipboard()->setMimeData(data);
}

void FilesApp::paste(const QUrl &destination, QObject *folder)
{
    if (refuseApplicationItems({destination}))
        return;
    const QMimeData *data = QGuiApplication::clipboard()->mimeData();
    // Items only, as the Finder: text or an image would go to KIO's own file-name dialogs (KioDialogs::pastableItems).
    // The checks below and KIO::paste see the same list: KIO's own (local URLs first, valid ones).
    const QList<QUrl> urls = KioDialogs::pastableItems(data);
    if (urls.isEmpty())
        return;
    const bool cut = KIO::isClipboardDataCut(data);
    // Copying items into their own folder makes "name copy" duplicates instead of a conflict.
    if (!cut && !urls.isEmpty()) {
        bool sameFolder = true;
        for (const QUrl &u : urls)
            sameFolder &= u.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash) == destination.adjusted(QUrl::StripTrailingSlash);
        if (sameFolder) {
            duplicate(urls, folder);
            return;
        }
    }
    if (refuseTwin(this, destination, urls))
        return;
    // KIO::paste records the copy or move in FileUndoManager itself.
    // KIO::paste reads its data when the job starts, after this returns: the items checked above, owned by the job, not
    // the clipboard's data, which may change or go meanwhile.
    auto *items = new QMimeData;
    items->setUrls(urls);
    KIO::setClipboardDataCut(items, cut);
    KIO::PasteJob *job = KIO::paste(items, destination, KIO::HideProgressInfo);
    if (!job) {
        delete items;
        return;
    }
    items->setParent(job);
    attachDelegate(job);
    QPointer<QObject> target = folder;
    // What the job really created: a Rename or Skip answer in the conflict dialog puts a folder elsewhere than
    // destination/name, or nowhere, and a look must not land on a different folder that happens to have that name.
    auto created = std::make_shared<QSet<QUrl>>();
    connect(job, &KIO::PasteJob::itemCreated, this, [target, created](const QUrl &url) {
        created->insert(url);
        if (auto *f = asFolder(target))
            f->expect(url, false);
    });
    if (cut) {
        const QStringList pending = beginStyleMoves(urls);
        connect(job, &KJob::result, this, [this, job, urls, destination, created, pending] {
            // A cut selection is consumed by its paste.
            if (!job->error())
                QGuiApplication::clipboard()->clear();
            // What the job really created is listed in `created` whatever its verdict (a cancelled conflict or one failed item
            // leaves the other folders moved): their entries follow them before the protection is lifted.
            QList<QPair<QUrl, QUrl>> pairs;
            for (const auto &pair : FolderStyleLogic::followingPaste(urls, destination, *created))
                pairs.append({pair.first, pair.second});
            styleMovedAll(pairs);
            endStyleMoves(pending);
        });
    }
    track(job, countText(cut ? tr("Moving 1 item…") : tr("Copying 1 item…"), cut ? tr("Moving %1 items…") : tr("Copying %1 items…"), urls.size()),
          cut ? tr("Moving") : tr("Copying"), urls, destination);
}

void FilesApp::trash(const QList<QUrl> &urls)
{
    if (refuseApplicationItems(urls))
        return;
    if (urls.isEmpty())
        return;
    KIO::CopyJob *job = KIO::trash(urls, KIO::HideProgressInfo);
    attachDelegate(job);
    KIO::FileUndoManager::self()->recordJob(KIO::FileUndoManager::Trash, urls, QUrl(QStringLiteral("trash:/")), job);
    track(job, countText(tr("Moving 1 item to the Trash…"), tr("Moving %1 items to the Trash…"), urls.size()));
}

void FilesApp::restore(const QList<QUrl> &urls)
{
    QList<QUrl> trashed;
    for (const QUrl &u : urls) {
        if (u.scheme() == QLatin1String("trash"))
            trashed << u;
    }
    if (trashed.isEmpty())
        return;
    // Put Back also refuses to land next to an NFC/NFD twin of the original name (the home trash keeps the original path).
    const QString infoDir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/Trash/info/");
    for (const QUrl &u : std::as_const(trashed)) {
        QFile info(infoDir + u.fileName() + QStringLiteral(".trashinfo"));
        if (!info.open(QIODevice::ReadOnly))
            continue;
        const QString original = FileLogic::trashInfoOriginalPath(info.read(4096));
        if (original.isEmpty())
            continue;
        const QUrl parent = QUrl::fromLocalFile(QFileInfo(original).absolutePath());
        if (refuseTwin(this, parent, {QUrl::fromLocalFile(original)}))
            return;
    }
    KIO::RestoreJob *job = KIO::restoreFromTrash(trashed, KIO::HideProgressInfo);
    attachDelegate(job);
    track(job, countText(tr("Putting back 1 item…"), tr("Putting back %1 items…"), trashed.size()));
}

void FilesApp::deletePermanently(const QList<QUrl> &urls)
{
    if (refuseApplicationItems(urls))
        return;
    // Delete Immediately (⌥⌘⌫, FP-52): any item, in the Trash or not (the window confirmed first); never undoable.
    if (urls.isEmpty())
        return;
    KIO::DeleteJob *job = KIO::del(urls, KIO::HideProgressInfo);
    attachDelegate(job);
    track(job, countText(tr("Deleting 1 item…"), tr("Deleting %1 items…"), urls.size()));
}

void FilesApp::emptyTrash()
{
    // Dev sessions never touch the real trash (trash:/ is the owner's), even when reached by typing the URL.
    if (devSession())
        return;
    KIO::EmptyTrashJob *job = KIO::emptyTrash();
    attachDelegate(job);
    track(job, tr("Emptying the Trash…"));
}

void FilesApp::newFolder(const QUrl &directory, QObject *folder)
{
    if (refuseApplicationItems({directory}))
        return;
    const QString name = FileLogic::uniqueName(tr("untitled folder"), [&directory](const QString &n) { return nameTaken(directory, n); });
    const QUrl url = childUrl(directory, name);
    KIO::MkdirJob *job = KIO::mkdir(url);
    attachDelegate(job);
    KIO::FileUndoManager::self()->recordJob(KIO::FileUndoManager::Mkdir, {}, url, job);
    QPointer<QObject> target = folder;
    connect(job, &KJob::result, this, [this, job, url, target] {
        if (job->error()) {
            emit operationFailed(job->errorString());
            return;
        }
        // A look left at this path by a folder that went away outside Files must not apply to the new folder.
        if (url.isLocalFile())
            m_folderStyles.dropEntry(url.toLocalFile());
        if (auto *f = asFolder(target))
            f->expect(url, true);
    });
}

void FilesApp::makeAlias(const QList<QUrl> &urls, QObject *folder)
{
    if (refuseApplicationItems(urls))
        return;
    QPointer<QObject> target = folder;
    // One command, one undo step: the aliases made are kept together (one that cannot be made is told, the others stay).
    BatchOps::Steps made;
    for (const QUrl &url : urls) {
        if (!url.isLocalFile()) {
            emit operationFailed(tr("Aliases can only be made of items on this computer."));
            continue;
        }
        const QFileInfo info(url.toLocalFile());
        const QString dir = info.absolutePath();
        // The Finder's "report.txt alias", "report.txt alias 2"… The new file's own name (not a message: kept exactly as the
        // original's, never cleaned for display).
        const QString original = info.fileName();
        const QString name = FileLogic::uniqueName(tr("%1 alias").arg(original), [&dir](const QString &n) {
            return QFileInfo::exists(dir + QLatin1Char('/') + n) || QFileInfo(dir + QLatin1Char('/') + n).isSymLink();
        });
        const QString link = dir + QLatin1Char('/') + name;
        const BatchOps::Step step{BatchOps::Step::Kind::Link, info.absoluteFilePath(), link};
        if (!BatchOps::apply({step})) {
            emit operationFailed(tr("The alias of “%1” couldn’t be made here.").arg(FileLogic::displayName(info.fileName())));
            continue;
        }
        made.append(step);
        if (auto *f = asFolder(target))
            f->expect(QUrl::fromLocalFile(link), false);
    }
    recordCustom(made.size() == 1 ? tr("Make Alias") : tr("Make Aliases"), made);
}

QUrl FilesApp::linkTarget(const QUrl &url) const
{
    if (!url.isLocalFile())
        return {};
    const QFileInfo info(url.toLocalFile());
    if (!info.isSymLink())
        return {};
    const QString target = info.symLinkTarget();
    return !target.isEmpty() && QFileInfo::exists(target) ? QUrl::fromLocalFile(target) : QUrl();
}

void FilesApp::newFolderWithItems(const QList<QUrl> &urls, const QUrl &directory, QObject *folder)
{
    if (urls.isEmpty() || refuseApplicationItems(urls) || refuseApplicationItems({directory}))
        return;
    for (const QUrl &url : urls) {
        if (!sameUrl(url.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash), directory)) {
            emit operationFailed(tr("New Folder with Selection needs items of the shown folder."));
            return;
        }
    }
    const QString name = FileLogic::uniqueName(tr("New Folder With Items"), [&directory](const QString &n) { return nameTaken(directory, n); });
    const QUrl url = childUrl(directory, name);
    QPointer<QObject> target = folder;
    bool local = directory.isLocalFile();
    for (const QUrl &u : urls)
        local = local && u.isLocalFile();
    if (local) {
        // The folder and the moves are ONE command: made together or not at all, undone with one step (the Finder's).
        BatchOps::Steps steps{{BatchOps::Step::Kind::Mkdir, QString(), url.toLocalFile()}};
        QList<QPair<QUrl, QUrl>> pairs;
        for (const QUrl &u : urls) {
            const QUrl to = childUrl(url, u.fileName());
            steps.append({BatchOps::Step::Kind::Rename, u.toLocalFile(), to.toLocalFile()});
            pairs.append({u, to});
        }
        // A look left at this path by a folder that went away outside Files must not apply to the new folder.
        m_folderStyles.dropEntry(url.toLocalFile());
        const QStringList pending = beginStyleMoves(urls);
        BatchOps::Failure failure;
        if (!BatchOps::apply(steps, &failure)) {
            // A revert that failed leaves part of it done: the folders that did move keep their look, and that part is a command
            // of its own, so Undo can put it back.
            QList<QPair<QUrl, QUrl>> kept;
            for (const auto &pair : std::as_const(pairs)) {
                for (const BatchOps::Step &step : std::as_const(failure.applied)) {
                    if (step.from == pair.first.toLocalFile())
                        kept.append(pair);
                }
            }
            styleMovedAll(kept);
            endStyleMoves(pending);
            recordCustom(tr("New Folder with Selection"), failure.applied);
            emit operationFailed(tr("“%1” couldn’t be moved into a new folder.").arg(FileLogic::displayName(QFileInfo(failure.path).fileName())) + QLatin1Char(' ') + rollbackNote(failure.applied));
            return;
        }
        styleMovedAll(pairs);
        endStyleMoves(pending);
        recordCustom(tr("New Folder with Selection"), steps);
        if (auto *f = asFolder(target))
            f->expect(url, true);
        return;
    }
    KIO::MkdirJob *mkdir = KIO::mkdir(url);
    attachDelegate(mkdir);
    KIO::FileUndoManager::self()->recordJob(KIO::FileUndoManager::Mkdir, {}, url, mkdir);
    connect(mkdir, &KJob::result, this, [this, mkdir, urls, url, target] {
        if (mkdir->error()) {
            emit operationFailed(mkdir->errorString());
            return;
        }
        if (url.isLocalFile())
            m_folderStyles.dropEntry(url.toLocalFile());
        KIO::CopyJob *move = KIO::move(urls, url);
        attachDelegate(move);
        KIO::FileUndoManager::self()->recordCopyJob(move);
        track(move, tr("Moving…"));
        connect(move, &KJob::result, this, [move, url, target] {
            if (!move->error()) {
                if (auto *f = asFolder(target))
                    f->expect(url, true);
            }
        });
    });
}

void FilesApp::copyPaths(const QList<QUrl> &urls)
{
    QStringList paths;
    for (const QUrl &url : urls)
        paths << (url.isLocalFile() ? url.toLocalFile() : url.toDisplayString(QUrl::RemovePassword | QUrl::PreferLocalFile));
    if (!paths.isEmpty())
        QGuiApplication::clipboard()->setText(paths.join(QLatin1Char('\n')));
}

void FilesApp::openTerminal(const QUrl &folder)
{
    if (!folder.isLocalFile() || !QFileInfo(folder.toLocalFile()).isDir()) {
        emit operationFailed(tr("A terminal can only open in a folder on this computer."));
        return;
    }
    if (launchingBlocked()) {
        emit operationFailed(tr("Opening files is disabled in this session (GRASSFIELD_FILES_NO_LAUNCH)."));
        return;
    }
    // Decision F-7: the session's terminal, never KIO's konsole lookup; the folder is only its working directory.
    const QStringList argv = grassfield::apps::scopedCommand(QStringLiteral("xdg-terminal-exec"), {}, grassfield::apps::scopedLaunch());
    QProcess process;
    process.setProgram(argv.first());
    process.setArguments(argv.mid(1));
    process.setWorkingDirectory(folder.toLocalFile());
    if (!process.startDetached())
        emit operationFailed(tr("The terminal couldn’t be started (xdg-terminal-exec)."));
}

namespace
{
// Omarchy's invocation (bin/omarchy-menu-share of Omarchy v4.0.6): LocalSend on its send page, in a transient unit of the
// user's service manager. ShareLogic.js (LOCALSEND_ARGV) builds the same vector; the items follow it.
const QStringList kLocalSendArgv = {QStringLiteral("systemd-run"), QStringLiteral("--user"), QStringLiteral("--quiet"), QStringLiteral("--collect"),
                                    QStringLiteral("localsend"), QStringLiteral("--headless"), QStringLiteral("send")};
}

bool FilesApp::localSendAvailable() const
{
    // At each use (OC-0.3): LocalSend installed or removed while Files runs shows or hides the Share menu's item.
    return !QStandardPaths::findExecutable(QStringLiteral("localsend")).isEmpty() && !QStandardPaths::findExecutable(QStringLiteral("systemd-run")).isEmpty();
}

void FilesApp::sendWithLocalSend(const QStringList &argv)
{
    // The vector is checked again here, whatever QML gave: exactly Omarchy's program and options, then at least one item,
    // each an absolute path (so never read as an option: LocalSend takes no `--`) with no NUL that exists on this computer.
    if (argv.size() <= kLocalSendArgv.size() || argv.mid(0, kLocalSendArgv.size()) != kLocalSendArgv) {
        emit operationFailed(tr("These items can’t be sent with LocalSend."));
        return;
    }
    const QStringList paths = argv.mid(kLocalSendArgv.size());
    for (const QString &path : paths) {
        if (!path.startsWith(QLatin1Char('/')) || path.contains(QChar(u'\0')) || !QFileInfo::exists(path)) {
            emit operationFailed(tr("These items can’t be sent with LocalSend: only files and folders on this computer can."));
            return;
        }
    }
    // A dev session sends nothing: `systemd-run --user` starts LocalSend in the user's service manager, with its environment,
    // so it would open on the owner's real desktop with the files (security review of OC-13, LOW 2; as Preview's openLink).
    if (devSession()) {
        emit operationFailed(tr("Not sent: a development session doesn’t start LocalSend (it would open on the real desktop)."));
        return;
    }
    if (!localSendAvailable()) {
        emit operationFailed(tr("LocalSend isn’t installed."));
        return;
    }
    if (launchingBlocked()) {
        emit operationFailed(tr("Opening files is disabled in this session (GRASSFIELD_FILES_NO_LAUNCH)."));
        return;
    }
    QProcess process;
    process.setProgram(argv.first());
    process.setArguments(argv.mid(1));
    process.setStandardInputFile(QProcess::nullDevice());
    if (!process.startDetached())
        emit operationFailed(tr("LocalSend couldn’t be started."));
}

namespace
{
RenameLogic::Options renameOptions(const QVariantMap &map)
{
    RenameLogic::Options o;
    o.mode = RenameLogic::Mode(qBound(0, map.value(QStringLiteral("mode")).toInt(), 2));
    o.find = map.value(QStringLiteral("find")).toString();
    o.replaceWith = map.value(QStringLiteral("replaceWith")).toString();
    o.addText = map.value(QStringLiteral("addText")).toString();
    o.where = RenameLogic::Where(qBound(0, map.value(QStringLiteral("where")).toInt(), 1));
    o.format = RenameLogic::Format(qBound(0, map.value(QStringLiteral("format")).toInt(), 2));
    o.customFormat = map.value(QStringLiteral("customFormat")).toString();
    o.startAt = qBound(0, map.value(QStringLiteral("startAt"), 1).toInt(), 1000000000);
    return o;
}
} // namespace

QStringList FilesApp::renamePreview(const QList<QUrl> &urls, const QVariantMap &options) const
{
    QStringList names;
    QList<bool> dirs;
    for (const QUrl &url : urls) {
        names << url.fileName();
        dirs << (url.isLocalFile() && QFileInfo(url.toLocalFile()).isDir());
    }
    return RenameLogic::newNames(names, dirs, renameOptions(options), QDateTime::currentDateTime());
}

QString FilesApp::renameItems(const QList<QUrl> &urls, const QVariantMap &options, QObject *folder)
{
    if (refuseApplicationItems(urls))
        return tr("Applications can’t be renamed here.");
    QStringList names;
    QStringList folders;
    for (const QUrl &url : urls) {
        names << url.fileName();
        folders << url.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash).toString();
    }
    const QStringList next = renamePreview(urls, options);
    QString which;
    switch (RenameLogic::check(names, next, folders, &which)) {
    case RenameLogic::Problem::None:
        break;
    case RenameLogic::Problem::InvalidName:
        return tr("The name “%1” can’t be used. Names can’t be empty, “.” or “..”, contain “/”, or be longer than 255 bytes.").arg(FileLogic::displayName(which));
    case RenameLogic::Problem::Duplicate:
        return tr("Two items would both be named “%1”.").arg(FileLogic::displayName(which));
    case RenameLogic::Problem::TakenInBatch:
        return tr("The name “%1” is taken by another item being renamed. Rename them in two steps.").arg(FileLogic::displayName(which));
    case RenameLogic::Problem::NothingChanges:
        return tr("No name would change.");
    }
    QList<int> changed;
    bool local = true;
    for (int i = 0; i < urls.size(); ++i) {
        if (next.at(i) == names.at(i))
            continue;
        changed << i;
        local = local && urls.at(i).isLocalFile();
    }
    if (changed.size() < 2 || !local) {
        // One item: the single rename (one KIO step). Items on a server: one KIO job each (no all-or-nothing there).
        for (int i : std::as_const(changed))
            rename(urls.at(i), next.at(i), folder);
        return QString();
    }
    // Every target is looked at first: a name already taken on the disk refuses the whole command.
    BatchOps::Steps steps;
    QList<QPair<QUrl, QUrl>> pairs;
    for (int i : std::as_const(changed)) {
        const QUrl parent = urls.at(i).adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash);
        const QUrl to = childUrl(parent, next.at(i));
        if (QFileInfo(to.toLocalFile()).isSymLink() || localExists(to) || nameTaken(parent, next.at(i), names.at(i)))
            return tr("The name “%1” is already taken. Please choose a different name.").arg(FileLogic::displayName(next.at(i)));
        steps.append({BatchOps::Step::Kind::Rename, urls.at(i).toLocalFile(), to.toLocalFile()});
        pairs.append({urls.at(i), to});
    }
    // All renamed or none (a failure part-way puts back what was done), and one undo step.
    QList<QUrl> sources;
    for (const auto &pair : std::as_const(pairs))
        sources << pair.first;
    const QStringList pending = beginStyleMoves(sources);
    BatchOps::Failure failure;
    if (!BatchOps::apply(steps, &failure)) {
        // The folders that did move keep their look (as in a complete rename), and what stayed renamed is one undo step.
        QList<QPair<QUrl, QUrl>> kept;
        for (const auto &pair : std::as_const(pairs)) {
            for (const BatchOps::Step &step : std::as_const(failure.applied)) {
                if (step.from == pair.first.toLocalFile())
                    kept.append(pair);
            }
        }
        styleMovedAll(kept);
        endStyleMoves(pending);
        recordCustom(countText(tr("Rename 1 Item"), tr("Rename %1 Items"), failure.applied.size()), failure.applied);
        return tr("“%1” couldn’t be renamed: %2.").arg(FileLogic::displayName(QFileInfo(failure.path).fileName()), QString::fromLocal8Bit(strerror(failure.error))) + QLatin1Char(' ') + rollbackNote(failure.applied);
    }
    styleMovedAll(pairs);
    endStyleMoves(pending);
    recordCustom(countText(tr("Rename 1 Item"), tr("Rename %1 Items"), changed.size()), steps);
    QPointer<QObject> target = folder;
    for (const auto &pair : std::as_const(pairs)) {
        if (auto *f = asFolder(target))
            f->expect(pair.second, false);
    }
    return QString();
}

bool FilesApp::isArchive(const QUrl &url) const
{
    return url.isLocalFile() && ArchiveLogic::isArchive(url.fileName());
}

void FilesApp::startArchiveJob(ArchiveJob *job, const QString &activity, QObject *folder)
{
    m_archiveJobs.append(job);
    m_activity = activity;
    m_activityPercent = -1;
    emit activityChanged();
    QPointer<QObject> target = folder;
    connect(job, &ArchiveJob::finished, this, [this, job, target](bool ok, const QString &error, const QString &result) {
        if (!ok && !error.isEmpty())
            emit operationFailed(error);
        if (ok) {
            if (auto *f = asFolder(target))
                f->expect(QUrl::fromLocalFile(result), false);
        }
        m_archiveJobs.removeAll(job);
        job->deleteLater();
        archiveActivityEnded();
    });
    job->start();
}

void FilesApp::archiveActivityEnded()
{
    m_archiveJobs.removeIf([](const QPointer<ArchiveJob> &p) { return p.isNull(); });
    if (m_jobs.isEmpty() && m_archiveJobs.isEmpty()) {
        m_activity.clear();
        m_activityPercent = -1;
        emit activityChanged();
    }
}

void FilesApp::compress(const QList<QUrl> &urls, QObject *folder)
{
    if (urls.isEmpty() || refuseApplicationItems(urls))
        return;
    const QString dir = urls.first().isLocalFile() ? QFileInfo(urls.first().toLocalFile()).absolutePath() : QString();
    QStringList names;
    for (const QUrl &url : urls) {
        if (!url.isLocalFile() || QFileInfo(url.toLocalFile()).absolutePath() != dir) {
            emit operationFailed(dir.isEmpty() || !url.isLocalFile() ? tr("Only items on this computer can be compressed.")
                                                                    : tr("Items of several folders can’t be compressed together."));
            return;
        }
        names << QFileInfo(url.toLocalFile()).fileName();
    }
    auto *job = ArchiveJob::compress(QStandardPaths::findExecutable(QStringLiteral("bsdtar")), dir, names, this);
    startArchiveJob(job, tr("Compressing “%1”…").arg(FileLogic::displayName(job->subject())), folder);
}

void FilesApp::expand(const QUrl &archive, QObject *folder)
{
    if (!isArchive(archive) || !QFileInfo(archive.toLocalFile()).isFile()) {
        emit operationFailed(tr("Only archives on this computer can be expanded."));
        return;
    }
    auto *job = ArchiveJob::expand(QStandardPaths::findExecutable(QStringLiteral("bsdtar")), archive.toLocalFile(), this);
    startArchiveJob(job, tr("Expanding “%1”…").arg(FileLogic::displayName(job->subject())), folder);
}

void FilesApp::cancelArchives()
{
    const auto jobs = m_archiveJobs;
    for (const QPointer<ArchiveJob> &job : jobs) {
        if (job)
            job->cancel();
    }
}

namespace
{
QString userName(uid_t uid)
{
    const passwd *pw = getpwuid(uid);
    return pw ? QString::fromLocal8Bit(pw->pw_name) : QString::number(uid);
}

QString groupName(gid_t gid)
{
    const group *gr = getgrgid(gid);
    return gr ? QString::fromLocal8Bit(gr->gr_name) : QString::number(gid);
}

// The groups the user belongs to (by name), the item's group first when it is one of them.
QStringList userGroups()
{
    QStringList out;
    const int n = getgroups(0, nullptr);
    std::vector<gid_t> ids(std::max(n, 0));
    if (n > 0 && getgroups(n, ids.data()) == n) {
        for (gid_t id : ids)
            out << groupName(id);
    }
    const QString primary = groupName(getegid());
    if (!out.contains(primary))
        out.prepend(primary);
    out.removeDuplicates();
    return out;
}

bool systemPath(const QString &path)
{
    for (const char *root : {"/proc", "/sys", "/dev"}) {
        const QString r = QString::fromLatin1(root);
        if (path == r || path.startsWith(r + QLatin1Char('/')))
            return true;
    }
    return false;
}

// The item pinned (O_PATH | O_NOFOLLOW): -1 when it is gone, a link, or no folder or regular file.
int pinItem(const QString &path, struct stat *st)
{
    const int fd = ::open(QFile::encodeName(path).constData(), O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0)
        return -1;
    if (::fstat(fd, st) != 0 || !(S_ISDIR(st->st_mode) || S_ISREG(st->st_mode))) {
        ::close(fd);
        return -1;
    }
    return fd;
}

QByteArray procName(int fd)
{
    return QByteArrayLiteral("/proc/self/fd/") + QByteArray::number(fd);
}
} // namespace

QVariantMap FilesApp::permissionsOf(const QUrl &url) const
{
    if (!url.isLocalFile())
        return {{QStringLiteral("valid"), false}};
    const QString path = url.toLocalFile();
    struct stat st{};
    if (::lstat(QFile::encodeName(path).constData(), &st) != 0)
        return {{QStringLiteral("valid"), false}};
    const unsigned mode = st.st_mode & 07777;
    const bool isDir = S_ISDIR(st.st_mode);
    QString reason;
    if (S_ISLNK(st.st_mode))
        reason = tr("An alias (a symbolic link) keeps its own permissions: change the original item’s.");
    else if (systemPath(path))
        reason = tr("System items can’t be changed here.");
    else if (!isDir && !S_ISREG(st.st_mode))
        reason = tr("Only files and folders can be changed here.");
    else if (st.st_uid != geteuid())
        reason = tr("You can only change the permissions of items you own. Changing others’ items needs an administrator, which Files doesn’t offer yet.");
    QVariantList access;
    for (int who = 0; who < 3; ++who)
        access << int(PermissionLogic::accessOf(mode, PermissionLogic::Who(who)));
    return {{QStringLiteral("valid"), true},
            {QStringLiteral("mode"), int(mode)},
            {QStringLiteral("modeText"), PermissionLogic::modeText(mode)},
            {QStringLiteral("owner"), userName(st.st_uid)},
            {QStringLiteral("group"), groupName(st.st_gid)},
            {QStringLiteral("ownedByMe"), st.st_uid == geteuid()},
            {QStringLiteral("isDir"), isDir},
            {QStringLiteral("editable"), reason.isEmpty()},
            {QStringLiteral("reason"), reason},
            {QStringLiteral("groups"), reason.isEmpty() ? userGroups() : QStringList()},
            {QStringLiteral("access"), access}};
}

void FilesApp::setAccess(const QUrl &url, int who, int access)
{
    if (!permissionsOf(url).value(QStringLiteral("editable")).toBool() || who < 0 || who > 2 || access < 0 || access > 3)
        return;
    struct stat st{};
    const int fd = pinItem(url.toLocalFile(), &st);
    if (fd < 0 || st.st_uid != geteuid()) {
        if (fd >= 0)
            ::close(fd);
        emit operationFailed(tr("The permissions of “%1” couldn’t be changed.").arg(FileLogic::displayName(url.fileName())));
        emit permissionsChanged(url);
        return;
    }
    const unsigned mode = PermissionLogic::withAccess(st.st_mode & 07777, PermissionLogic::Who(who), PermissionLogic::Access(access), S_ISDIR(st.st_mode));
    const int rc = ::chmod(procName(fd).constData(), mode);
    const int error = errno;
    ::close(fd);
    if (rc != 0)
        emit operationFailed(tr("The permissions of “%1” couldn’t be changed: %2").arg(FileLogic::displayName(url.fileName()), QString::fromLocal8Bit(strerror(error))));
    org::kde::KDirNotify::emitFilesChanged({url});
    emit permissionsChanged(url);
}

void FilesApp::setGroup(const QUrl &url, const QString &groupNameText)
{
    if (!permissionsOf(url).value(QStringLiteral("editable")).toBool() || !userGroups().contains(groupNameText))
        return;
    const group *gr = getgrnam(QFile::encodeName(groupNameText).constData());
    if (!gr)
        return;
    const gid_t gid = gr->gr_gid;
    struct stat st{};
    const int fd = pinItem(url.toLocalFile(), &st);
    if (fd < 0 || st.st_uid != geteuid()) {
        if (fd >= 0)
            ::close(fd);
        emit permissionsChanged(url);
        return;
    }
    // The owner stays (-1); a user may give their item to a group they belong to.
    const int rc = ::chown(procName(fd).constData(), uid_t(-1), gid);
    const int error = errno;
    ::close(fd);
    if (rc != 0)
        emit operationFailed(tr("The group of “%1” couldn’t be changed: %2").arg(FileLogic::displayName(url.fileName()), QString::fromLocal8Bit(strerror(error))));
    org::kde::KDirNotify::emitFilesChanged({url});
    emit permissionsChanged(url);
}

void FilesApp::applyToEnclosed(const QUrl &url)
{
    const QVariantMap p = permissionsOf(url);
    if (!p.value(QStringLiteral("editable")).toBool() || !p.value(QStringLiteral("isDir")).toBool())
        return;
    const QVariantList access = p.value(QStringLiteral("access")).toList();
    const QString ops = PermissionLogic::recursiveOperators(PermissionLogic::Access(access.value(0).toInt()), PermissionLogic::Access(access.value(1).toInt()),
                                                            PermissionLogic::Access(access.value(2).toInt()));
    // The system's chmod (ADR-0028 probe 12): it never follows the links it meets inside the folder; the folder itself was
    // checked above to be no link. The user's own rights only: items of others fail and are reported.
    auto *process = new QProcess(this);
    process->setProgram(QStringLiteral("/usr/bin/chmod"));
    process->setArguments({QStringLiteral("-R"), QStringLiteral("--"), ops, url.toLocalFile()});
    process->setStandardInputFile(QProcess::nullDevice());
    process->setStandardOutputFile(QProcess::nullDevice());
    connect(process, &QProcess::finished, this, [this, process, url](int code, QProcess::ExitStatus status) {
        if (status != QProcess::NormalExit || code != 0)
            emit operationFailed(tr("Some items in “%1” weren’t changed: they belong to someone else or can’t be changed.").arg(FileLogic::displayName(url.fileName())));
        org::kde::KDirNotify::emitFilesChanged({url});
        emit permissionsChanged(url);
        process->deleteLater();
    });
    connect(process, &QProcess::errorOccurred, this, [this, process](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            emit operationFailed(tr("The permissions couldn’t be changed: chmod can’t be started."));
            process->deleteLater();
        }
    });
    process->start();
}

void FilesApp::setProgressDelayForTests(int ms)
{
    m_progressTimer.setInterval(ms > 0 ? ms : kProgressDelayMs);
}

void FilesApp::publishJobs()
{
    QHash<QString, grassfield::apps::OngoingActivity> activities;
    QVariantList list;
    QList<JobProgress> rows = m_progress.values();
    std::sort(rows.begin(), rows.end(), [](const JobProgress &a, const JobProgress &b) { return a.id < b.id; });
    for (const JobProgress &p : std::as_const(rows)) {
        // Finder-Copy: "Copying “name” to “Desktop”", then "41.9 MB of 111.6 MB – About 10 seconds".
        QString title = FileLogic::copyTitle(p.verb, p.item, p.count, p.destination);
        if (title.isEmpty())
            title = p.activity;
        const QString detail = FileLogic::copyDetail(p.processed, p.total, p.speed, p.percent);
        const int percent = FileLogic::copyPercent(p.processed, p.total, p.percent);
        list.append(QVariantMap{{QStringLiteral("id"), int(p.id)}, {QStringLiteral("title"), title}, {QStringLiteral("detail"), detail}, {QStringLiteral("percent"), percent}});
        // The same row as an ongoing activity (ADR-0052): the bar sweeps while the job tells no amount.
        grassfield::apps::OngoingActivity a;
        a.kind = QStringLiteral("transfer");
        a.title = title;
        a.subtitle = detail;
        a.progress = percent >= 0 ? qBound(0, percent, 100) / 100.0 : -1;
        a.actions = {{QStringLiteral("stop"), tr("Stop")}};
        activities.insert(QStringLiteral("copy-%1").arg(p.id), a);
    }
    if (m_ongoing)
        m_ongoing->sync(activities);
    if (list == m_jobList)
        return;
    m_jobList = list;
    emit jobsChanged();
}

void FilesApp::cancelJob(int id)
{
    for (auto it = m_progress.cbegin(); it != m_progress.cend(); ++it) {
        if (int(it->id) == id) {
            // A stopped job reports ERR_USER_CANCELED, which track() never shows as an error.
            it.key()->kill(KJob::EmitResult);
            return;
        }
    }
}

void FilesApp::moveHere(const QUrl &destination, QObject *folder)
{
    if (refuseApplicationItems({destination}))
        return;
    const QList<QUrl> urls = KioDialogs::pastableItems(QGuiApplication::clipboard()->mimeData());
    if (urls.isEmpty() || refuseApplicationItems(urls) || refuseTwin(this, destination, urls))
        return;
    KIO::CopyJob *job = KIO::move(urls, destination, KIO::HideProgressInfo);
    attachDelegate(job);
    KIO::FileUndoManager::self()->recordCopyJob(job);
    track(job, countText(tr("Moving 1 item…"), tr("Moving %1 items…"), urls.size()), tr("Moving"), urls, destination);
    QPointer<QObject> target = folder;
    connect(job, &KIO::CopyJob::copyingDone, this, [target](KIO::Job *, const QUrl &, const QUrl &to, const QDateTime &, bool, bool) {
        if (auto *f = asFolder(target))
            f->expect(to, false);
    });
}

QString FilesApp::mimeTypeOf(const QUrl &url) const
{
    return QMimeDatabase().mimeTypeForUrl(url).name();
}

QString FilesApp::defaultApplication(const QString &mimeType) const
{
    const KService::Ptr service = KApplicationTrader::preferredService(mimeType);
    return service ? service->storageId() : QString();
}

bool FilesApp::setDefaultApplication(const QString &mimeType, const QString &storageId)
{
    const KService::Ptr service = KService::serviceByStorageId(storageId);
    if (!service || mimeType.isEmpty() || !QMimeDatabase().mimeTypeForName(mimeType).isValid())
        return false;
    // The user's mimeapps.list (XDG): the Finder's Change All… for every document of this type.
    KApplicationTrader::setPreferredService(mimeType, service);
    return true;
}

void FilesApp::makeFolder(const QUrl &directory, const QString &name, const QJSValue &callback)
{
    QJSValue cb = callback;
    auto answer = [cb](const QUrl &url, const QString &error) mutable {
        if (cb.isCallable())
            cb.call({QJSValue(url.toString()), QJSValue(error)});
    };
    if (!FileLogic::isValidFileName(name)) {
        answer({}, tr("The name “%1” can’t be used. Names can’t be empty, “.” or “..”, contain “/”, or be longer than 255 bytes.").arg(FileLogic::displayName(name)));
        return;
    }
    // No look at the folder first: the panels never read the disk on the GUI thread (a hung mount would stall every panel,
    // ADR-0035 4b-11); KIO's mkdir says when the name is taken.
    const QUrl url = childUrl(directory, name);
    KIO::MkdirJob *job = KIO::mkdir(url);
    attachDelegate(job);
    connect(job, &KJob::result, this, [this, job, url, name, answer]() mutable {
        if (job->error() == KIO::ERR_DIR_ALREADY_EXIST || job->error() == KIO::ERR_FILE_ALREADY_EXIST) {
            answer({}, tr("The name “%1” is already taken. Please choose a different name.").arg(FileLogic::displayName(name)));
            return;
        }
        if (job->error()) {
            answer({}, job->errorString());
            return;
        }
        if (url.isLocalFile())
            m_folderStyles.dropEntry(url.toLocalFile());
        answer(url, {});
    });
}

void FilesApp::rename(const QUrl &url, const QString &newName, QObject *folder)
{
    if (refuseApplicationItems({url}))
        return;
    if (newName == url.fileName())
        return;
    if (!FileLogic::isValidFileName(newName)) {
        emit operationFailed(tr("The name “%1” can’t be used. Names can’t be empty, “.” or “..”, contain “/”, or be longer than 255 bytes.").arg(FileLogic::displayName(newName)));
        return;
    }
    const QUrl destination = childUrl(url.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash), newName);
    // A case-only change on a case-sensitive filesystem is a different name and fine.
    const QUrl parent = url.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash);
    if ((localExists(destination) && QFileInfo(destination.toLocalFile()).canonicalFilePath() != QFileInfo(url.toLocalFile()).canonicalFilePath())
        || nameTaken(parent, newName, url.fileName())) {
        emit operationFailed(tr("The name “%1” is already taken. Please choose a different name.").arg(FileLogic::displayName(newName)));
        return;
    }
    // KIO::moveAs (a CopyJob) rather than KIO::rename: FileUndoManager records CopyJob operations only.
    KIO::CopyJob *job = KIO::moveAs(url, destination, KIO::HideProgressInfo);
    attachDelegate(job);
    KIO::FileUndoManager::self()->recordJob(KIO::FileUndoManager::Rename, {url}, destination, job);
    QPointer<QObject> target = folder;
    const QStringList pending = beginStyleMoves({url});
    connect(job, &KJob::result, this, [this, job, url, destination, target, pending] {
        if (job->error()) {
            endStyleMoves(pending);
            emit operationFailed(job->errorString());
            return;
        }
        styleMoved(url, destination);
        endStyleMoves(pending);
        if (auto *f = asFolder(target))
            f->expect(destination, false);
    });
}

// Files moved or renamed a folder: its look follows (the attribute travels by itself; the per-user entry is keyed by path).
void FilesApp::styleMoved(const QUrl &from, const QUrl &to)
{
    if (!from.isLocalFile() || !to.isLocalFile() || m_folderStyles.fallbackCount() == 0)
        return;
    if (m_folderStyles.moveEntries(from.toLocalFile(), to.toLocalFile())) {
        ++m_folderStyleRevision;
        emit folderStyleRevisionChanged();
        emit allFolderStylesChanged();
    }
}

void FilesApp::styleMovedAll(const QList<QPair<QUrl, QUrl>> &pairs)
{
    if (m_folderStyles.fallbackCount() == 0)
        return;
    QList<QPair<QString, QString>> local;
    for (const auto &pair : pairs) {
        if (pair.first.isLocalFile() && pair.second.isLocalFile())
            local.append({pair.first.toLocalFile(), pair.second.toLocalFile()});
    }
    if (m_folderStyles.moveEntries(local)) {
        ++m_folderStyleRevision;
        emit folderStyleRevisionChanged();
        emit allFolderStylesChanged();
    }
}

QStringList FilesApp::beginStyleMoves(const QList<QUrl> &sources)
{
    QStringList paths;
    for (const QUrl &u : sources) {
        if (u.isLocalFile())
            paths.append(u.toLocalFile());
    }
    m_folderStyles.beginMoves(paths);
    return paths;
}

void FilesApp::endStyleMoves(const QStringList &paths)
{
    m_folderStyles.endMoves(paths);
}

void FilesApp::duplicate(const QList<QUrl> &urls, QObject *folder)
{
    if (refuseApplicationItems(urls))
        return;
    QPointer<QObject> target = folder;
    for (const QUrl &url : urls) {
        if (url.scheme() == QLatin1String("trash"))
            continue;
        const QUrl directory = url.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash);
        const bool isDir = url.isLocalFile() && QFileInfo(url.toLocalFile()).isDir();
        const QString name = FileLogic::duplicateName(url.fileName(), isDir, tr("copy"), [&directory](const QString &n) { return nameTaken(directory, n); });
        const QUrl destination = childUrl(directory, name);
        KIO::CopyJob *job = KIO::copyAs(url, destination, KIO::HideProgressInfo);
        attachDelegate(job);
        KIO::FileUndoManager::self()->recordCopyJob(job);
        connect(job, &KJob::result, this, [job, destination, target] {
            if (!job->error()) {
                if (auto *f = asFolder(target))
                    f->expect(destination, false);
            }
        });
        track(job, tr("Duplicating “%1”…").arg(FileLogic::displayName(url.fileName())));
    }
}

void FilesApp::drop(const QList<QUrl> &urls, const QUrl &destination, QObject *folder)
{
    if (urls.isEmpty() || !destination.isValid())
        return;
    if (refuseApplicationItems(urls) || refuseApplicationItems({destination}))
        return;
    if (destination.scheme() == QLatin1String("trash")) {
        trash(urls);
        return;
    }
    // Recents and search results are lists, not places: nothing can be dropped into them.
    if (Recents::isRecentsUrl(destination) || SearchLogic::isSearchUrl(destination))
        return;
    // A drop on a tag search (its background, its path segment) tags the items, like a drop on the sidebar tag.
    if (TagLogic::isSearchUrl(destination)) {
        addTag(urls, TagLogic::searchTag(destination));
        return;
    }
    const QUrl dest = destination.adjusted(QUrl::StripTrailingSlash);
    QList<QUrl> sources;
    for (const QUrl &u : urls) {
        const QUrl clean = u.adjusted(QUrl::StripTrailingSlash);
        if (clean == dest || clean.isParentOf(dest)) {
            emit operationFailed(tr("“%1” can’t be moved or copied into itself.").arg(FileLogic::displayName(clean.fileName())));
            return;
        }
        // Dropping an item on the folder it is already in does nothing.
        if (clean.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash) != dest)
            sources << clean;
    }
    if (sources.isEmpty() || refuseTwin(this, dest, sources))
        return;
    const Qt::KeyboardModifiers mods = QGuiApplication::queryKeyboardModifiers();
    // Across filesystems a drop copies, like the macOS file manager (unless a modifier says otherwise).
    const QString destDevice = dest.isLocalFile() ? QString::fromUtf8(QStorageInfo(dest.toLocalFile()).device()) : QString();
    bool sameVolume = !destDevice.isEmpty();
    for (const QUrl &u : std::as_const(sources)) {
        if (!u.isLocalFile() || QString::fromUtf8(QStorageInfo(u.toLocalFile()).device()) != destDevice)
            sameVolume = false;
    }
    const FileLogic::DropAction action = FileLogic::dropAction(mods & Qt::ControlModifier, mods & Qt::AltModifier, sameVolume);
    if (action == FileLogic::DropAction::Link) {
        // Make Alias (decision: an alias is a symbolic link); one per item, named after it.
        KIO::CopyJob *link = KIO::link(sources, dest, KIO::HideProgressInfo);
        attachDelegate(link);
        KIO::FileUndoManager::self()->recordJob(KIO::FileUndoManager::Link, sources, dest, link);
        connect(link, &KJob::result, this, [this, link] {
            if (link->error() && link->error() != KIO::ERR_USER_CANCELED)
                emit operationFailed(link->errorString());
        });
        return;
    }
    const bool copy = action == FileLogic::DropAction::Copy;
    KIO::CopyJob *job = copy ? KIO::copy(sources, dest, KIO::HideProgressInfo) : KIO::move(sources, dest, KIO::HideProgressInfo);
    attachDelegate(job);
    if (copy)
        KIO::FileUndoManager::self()->recordCopyJob(job);
    else
        KIO::FileUndoManager::self()->recordJob(KIO::FileUndoManager::Move, sources, dest, job);
    QPointer<QObject> target = folder;
    for (const QUrl &u : std::as_const(sources)) {
        if (auto *f = asFolder(target))
            f->expect(childUrl(dest, u.fileName()), false);
    }
    if (!copy) {
        // The look follows the folder to where the job really put it (copyingDone names the actual destination: a Rename
        // answer in the conflict dialog gives another name, a Skip answer gives nothing, an Overwrite the same one).
        auto done = std::make_shared<QList<QPair<QUrl, QUrl>>>();
        connect(job, &KIO::CopyJob::copyingDone, this, [done](KIO::Job *, const QUrl &from, const QUrl &to, const QDateTime &, bool directory, bool renamed) {
            // A folder moved by a rename is reported as renamed (not as a directory); files are of no interest.
            if (directory || renamed)
                done->append({from, to});
        });
        const QStringList pending = beginStyleMoves(sources);
        connect(job, &KJob::result, this, [this, job, done, pending] {
            // The folders KIO really moved are listed in `done` whatever the job's verdict: a conflict the user cancelled, or one
            // item that failed, leaves the others moved, and their entries must follow them before the protection is lifted.
            QList<QPair<QUrl, QUrl>> pairs;
            for (const auto &pair : *done)
                pairs.append({pair.first, pair.second});
            styleMovedAll(pairs);
            endStyleMoves(pending);
        });
    }
    track(job, countText(copy ? tr("Copying 1 item…") : tr("Moving 1 item…"), copy ? tr("Copying %1 items…") : tr("Moving %1 items…"), sources.size()),
          copy ? tr("Copying") : tr("Moving"), sources, dest);
}

void FilesApp::undo()
{
    auto *kio = KIO::FileUndoManager::self();
    if (!customUndoIsNext()) {
        if (kio->isUndoAvailable()) {
            m_redoKinds.append(false);
            kio->undo();
        }
        return;
    }
    // One of Files' own commands (Rename N Items, Make Alias, New Folder with Selection): all its steps revert, or none.
    const CustomCommand command = m_undoCustom.last();
    BatchOps::Failure failure;
    if (!BatchOps::apply(BatchOps::inverse(command.steps), &failure)) {
        // The command stays on the stack. When a revert failed too, part of it is undone: what is still done stays its steps.
        const int undone = int(failure.applied.size());
        if (undone > 0)
            m_undoCustom.last().steps = command.steps.mid(0, command.steps.size() - undone);
        emit operationFailed(tr("“%1” can’t be undone: something has changed since.").arg(FileLogic::displayName(QFileInfo(failure.path).fileName())) + QLatin1Char(' ')
                             + (undone > 0 ? tr("Part of it was undone; Undo again after fixing the items.") : tr("Nothing was changed.")));
        emit undoChanged();
        return;
    }
    m_undoCustom.removeLast();
    m_redoCustom.append(command);
    m_redoKinds.append(true);
    emit undoChanged();
}

void FilesApp::redo()
{
    if (m_redoKinds.isEmpty())
        return;
    auto *kio = KIO::FileUndoManager::self();
    if (!m_redoKinds.last()) {
        m_redoKinds.removeLast();
        if (kio->isRedoAvailable())
            kio->redo();
        emit undoChanged();
        return;
    }
    if (m_redoCustom.isEmpty()) {
        m_redoKinds.removeLast();
        emit undoChanged();
        return;
    }
    const CustomCommand command = m_redoCustom.last();
    BatchOps::Failure failure;
    if (!BatchOps::apply(command.steps, &failure)) {
        QString note = tr("Nothing was changed.");
        if (!failure.applied.isEmpty()) {
            // Part of it is done and stays: it is a command of its own now (Undo puts it back) and the rest of the redo is gone.
            m_redoCustom.removeLast();
            m_redoKinds.removeLast();
            m_undoCustom.append({KIO::FileUndoManager::self()->newCommandSerialNumber(), command.text, failure.applied});
            note = rollbackNote(failure.applied);
        }
        emit operationFailed(tr("“%1” can’t be redone: something has changed since.").arg(FileLogic::displayName(QFileInfo(failure.path).fileName())) + QLatin1Char(' ') + note);
        emit undoChanged();
        return;
    }
    m_redoCustom.removeLast();
    m_redoKinds.removeLast();
    m_undoCustom.append(command);
    emit undoChanged();
}

void FilesApp::directorySize(const QUrl &url, const QJSValue &callback)
{
    KIO::DirectorySizeJob *job = KIO::directorySize(url);
    QJSValue cb = callback;
    connect(job, &KJob::result, this, [job, cb]() mutable {
        if (!cb.isCallable())
            return;
        if (job->error())
            cb.call({QJSValue(-1), QJSValue(0), QJSValue(0)});
        else
            cb.call({QJSValue(double(job->totalSize())), QJSValue(double(job->totalFiles())), QJSValue(double(job->totalSubdirs()))});
    });
}

QStringList FilesApp::colorTagNames() const
{
    QStringList names;
    for (int i = 0; i < TagLogic::kColorCount; ++i)
        names.append(TagLogic::displayName(TagLogic::colorKey(i)));
    return names;
}

QString FilesApp::tagsReason(const QUrl &url, TagStore::Support support) const
{
    switch (support) {
    case TagStore::Support::Supported:
        break;
    case TagStore::Support::Missing:
        return tr("“%1” is no longer there.").arg(FileLogic::displayName(url.fileName()));
    case TagStore::Support::Link:
        return tr("Links can’t carry tags.");
    case TagStore::Support::NotRegular:
        return tr("Only files and folders can be tagged.");
    case TagStore::Support::ReadOnly:
        return tr("Read-only items can’t be tagged.");
    case TagStore::Support::NoXattr:
        return tr("This volume can’t store tags.");
    }
    return QString();
}

QString FilesApp::schemeReason(const QUrl &url) const
{
    if (url.scheme() == QLatin1String("trash"))
        return tr("Items in the Trash can’t be tagged.");
    if (!url.isLocalFile())
        return tr("Tags are available for files on this computer only.");
    return QString();
}

QString FilesApp::tagsUnavailable(const QList<QUrl> &urls) const
{
    // Answered from the short-lived cache (the selection is asked on every selection change); a write decides afresh.
    for (const QUrl &url : urls) {
        const QString scheme = schemeReason(url);
        if (!scheme.isEmpty())
            return scheme;
        const QString why = tagsReason(url, m_tagCache.info(url.toLocalFile()).support);
        if (!why.isEmpty())
            return why;
    }
    return QString();
}

QVariantList FilesApp::colorTagStates(const QList<QUrl> &urls) const
{
    QList<QStringList> lists;
    for (const QUrl &url : urls) {
        if (url.isLocalFile())
            lists.append(m_tagCache.info(url.toLocalFile()).tags);
    }
    QVariantList out;
    const QList<int> states = TagLogic::colorStates(lists);
    for (int s : states)
        out.append(s);
    return out;
}

QStringList FilesApp::tagNamesOf(const QUrl &url) const
{
    QStringList names;
    if (!url.isLocalFile())
        return names;
    const QStringList tags = TagLogic::displayOrder(TagStore::read(url.toLocalFile()));
    for (const QString &tag : tags)
        names.append(TagLogic::displayName(tag));
    return names;
}

void FilesApp::toggleColorTag(const QList<QUrl> &urls, int index)
{
    const QString key = TagLogic::colorKey(index);
    if (key.isEmpty() || urls.isEmpty())
        return;
    // The same rule as the menu's checkmark (colour names match without regard to case: another application's "red" is
    // Red), read afresh. A read that fails stops everything: nothing is written from a guess.
    bool all = true;
    for (const QUrl &url : urls) {
        if (!url.isLocalFile()) {
            all = false;
            continue;
        }
        QByteArray stored;
        QString error;
        if (!TagStore::readRawChecked(url.toLocalFile(), &stored, &error)) {
            emit operationFailed(tr("The tags of “%1” couldn’t be read: %2").arg(FileLogic::displayName(url.fileName()), error));
            return;
        }
        all = all && TagLogic::ownsTag(stored, key);
    }
    rewriteTags(urls, key, !all);
}

void FilesApp::addTag(const QList<QUrl> &urls, const QString &tag)
{
    if (tag.trimmed().isEmpty())
        return;
    rewriteTags(urls, tag, true);
}

void FilesApp::addTypedTag(const QList<QUrl> &urls, const QString &typed)
{
    addTag(urls, TagLogic::typedTag(typed));
}

void FilesApp::removeTag(const QList<QUrl> &urls, const QString &tag)
{
    if (!tag.trimmed().isEmpty())
        rewriteTags(urls, tag, false);
}

void FilesApp::rewriteTags(const QList<QUrl> &urls, const QString &tag, bool on)
{
    QList<QUrl> changed;
    QStringList failed;
    QString reason;
    QStringList written;
    for (const QUrl &url : urls) {
        QString why = schemeReason(url);
        if (why.isEmpty())
            why = tagsReason(url, TagStore::support(url.toLocalFile()));
        if (!why.isEmpty()) {
            failed.append(url.fileName());
            reason = why;
            continue;
        }
        const QString path = url.toLocalFile();
        m_tagCache.invalidate(path);
        // A failed read must not become "no tags": the write would replace what other applications stored.
        QByteArray before;
        QString readError;
        if (!TagStore::readRawChecked(path, &before, &readError)) {
            failed.append(url.fileName());
            reason = readError;
            continue;
        }
        const QByteArray after = TagLogic::applyTag(before, tag, on);
        if (after == before)
            continue;
        QString error;
        if (!TagStore::writeRaw(path, after, &error)) {
            failed.append(url.fileName());
            reason = error;
            continue;
        }
        changed.append(url);
        written += TagLogic::parse(after);
        m_tagCache.invalidate(path);
    }
    if (!changed.isEmpty()) {
        // Tagging again is the way back to the sidebar for a tag removed from it (there is no Tags settings pane).
        if (on)
            unhideTag(tag);
        noteTags(written);
        ++m_tagRevision;
        emit tagRevisionChanged();
        emit tagsChanged(changed);
    }
    if (failed.size() == 1)
        emit operationFailed(tr("The tags of “%1” couldn’t be changed: %2").arg(FileLogic::displayName(failed.first()), reason));
    else if (failed.size() > 1)
        emit operationFailed(tr("The tags of %1 items couldn’t be changed: %2").arg(failed.size()).arg(reason));
}

QString FilesApp::folderStyleUnavailable(const QList<QUrl> &urls) const
{
    if (urls.isEmpty())
        return tr("Nothing is selected.");
    for (const QUrl &url : urls) {
        if (url.scheme() == QLatin1String("trash"))
            return tr("Folders in the Trash can’t be customized.");
        if (!url.isLocalFile())
            return tr("Folders can be customized on this computer only.");
        const QFileInfo info(url.toLocalFile());
        if (info.isSymLink())
            return tr("Links can’t be customized.");
        if (!info.isDir())
            return tr("Only folders can be customized.");
    }
    return QString();
}

QVariantMap FilesApp::folderStyleOf(const QUrl &url) const
{
    QVariantMap m;
    FolderStyleLogic::Style style;
    if (folderStyleUnavailable({url}).isEmpty())
        style = m_folderStyles.read(url.toLocalFile());
    m[QStringLiteral("color")] = style.color;
    m[QStringLiteral("glyph")] = style.glyph;
    return m;
}

QVariantMap FilesApp::applyFolderStyle(const QList<QUrl> &urls, const QString &color, const QString &glyph)
{
    FolderStyleLogic::Style style;
    style.color = FolderStyleLogic::normalizeColor(color);
    style.glyph = FolderStyleLogic::normalizeGlyph(glyph);
    return changeFolderStyles(urls, style);
}

QVariantMap FilesApp::resetFolderStyle(const QList<QUrl> &urls)
{
    return changeFolderStyles(urls, {});
}

QVariantMap FilesApp::changeFolderStyles(const QList<QUrl> &urls, const FolderStyleLogic::Style &style)
{
    QVariantMap out;
    out[QStringLiteral("ok")] = false;
    out[QStringLiteral("fellBack")] = false;
    const QString why = folderStyleUnavailable(urls);
    if (!why.isEmpty()) {
        out[QStringLiteral("error")] = why;
        return out;
    }
    QList<QUrl> changed;
    QStringList failed;
    QString reason;
    bool fellBack = false;
    for (const QUrl &url : urls) {
        const FolderStyleStore::Result r = m_folderStyles.write(url.toLocalFile(), style);
        if (!r.ok) {
            failed.append(url.fileName());
            reason = r.error;
            // A failed reset can still have dropped the entry saved for this account: the views show it.
            if (r.changed)
                changed.append(url);
            continue;
        }
        fellBack = fellBack || r.fellBack;
        if (r.changed)
            changed.append(url);
    }
    if (!changed.isEmpty()) {
        ++m_folderStyleRevision;
        emit folderStyleRevisionChanged();
        emit folderStylesChanged(changed);
    }
    out[QStringLiteral("ok")] = failed.isEmpty();
    out[QStringLiteral("fellBack")] = fellBack;
    if (failed.size() == 1)
        out[QStringLiteral("error")] = tr("The look of “%1” couldn’t be changed: %2").arg(FileLogic::displayName(failed.first()), reason);
    else if (failed.size() > 1)
        out[QStringLiteral("error")] = tr("The look of %1 folders couldn’t be changed: %2").arg(failed.size()).arg(reason);
    return out;
}

QString FilesApp::tagName(const QString &tag) const
{
    return TagLogic::displayName(tag);
}

int FilesApp::tagColor(const QString &tag) const
{
    return TagLogic::colorIndex(tag);
}

QUrl FilesApp::tagSearchUrl(const QString &tag, const QUrl &from) const
{
    QUrl folder;
    if (TagLogic::isSearchUrl(from))
        folder = TagLogic::searchFolder(from);
    else if (from.isLocalFile() && QFileInfo(from.toLocalFile()).isDir())
        folder = from;
    else
        folder = QUrl::fromLocalFile(QDir::homePath());
    return TagLogic::searchUrl(tag, folder);
}

bool FilesApp::isTagSearch(const QUrl &url) const
{
    return TagLogic::isSearchUrl(url);
}

bool FilesApp::isFileSearch(const QUrl &url) const
{
    return SearchLogic::isSearchUrl(url);
}

QVariantMap FilesApp::searchQuery(const QUrl &url) const
{
    const auto query = SearchLogic::fromUrl(url);
    if (!query)
        return {{QStringLiteral("valid"), false}};
    QVariantList criteria;
    for (const SearchLogic::Criterion &c : query->criteria) {
        criteria.append(QVariantMap{{QStringLiteral("attribute"), SearchLogic::attributeKey(c.attribute)},
                                    {QStringLiteral("op"), SearchLogic::opKey(c.op)},
                                    {QStringLiteral("value"), c.value},
                                    {QStringLiteral("unit"), c.unit}});
    }
    return {{QStringLiteral("valid"), true},
            {QStringLiteral("text"), query->text},
            {QStringLiteral("folder"), query->folder},
            {QStringLiteral("criteria"), criteria}};
}

QUrl FilesApp::searchUrl(const QVariantMap &map) const
{
    SearchLogic::Query query;
    query.text = map.value(QStringLiteral("text")).toString();
    const QUrl folder = map.value(QStringLiteral("folder")).toUrl();
    if (folder.isLocalFile())
        query.folder = folder.adjusted(QUrl::StripTrailingSlash | QUrl::NormalizePathSegments);
    for (const QVariant &v : map.value(QStringLiteral("criteria")).toList()) {
        const QVariantMap row = v.toMap();
        const auto attribute = SearchLogic::attributeFromKey(row.value(QStringLiteral("attribute")).toString());
        const auto op = SearchLogic::opFromKey(row.value(QStringLiteral("op")).toString());
        if (!attribute || !op || !SearchLogic::takesOp(*attribute, *op))
            continue;
        query.criteria.append({*attribute, *op, row.value(QStringLiteral("value")).toString(), row.value(QStringLiteral("unit")).toString()});
    }
    return SearchLogic::toUrl(query);
}

QVariantList FilesApp::searchAttributes() const
{
    using SearchLogic::Attribute;
    // The Finder's order of the first pop-up.
    const QList<QPair<Attribute, QString>> labels = {
        {Attribute::Kind, tr("Kind")},           {Attribute::Opened, tr("Last opened date")}, {Attribute::Modified, tr("Last modified date")},
        {Attribute::Created, tr("Created date")}, {Attribute::Name, tr("Name")},              {Attribute::Contents, tr("Contents")},
        {Attribute::Size, tr("File size")},      {Attribute::Tags, tr("Tags")},
    };
    QVariantList out;
    for (const auto &[a, label] : labels)
        out.append(QVariantMap{{QStringLiteral("key"), SearchLogic::attributeKey(a)}, {QStringLiteral("label"), label}});
    return out;
}

QVariantList FilesApp::searchOperators(const QString &attribute) const
{
    using SearchLogic::Attribute;
    using SearchLogic::Op;
    const auto a = SearchLogic::attributeFromKey(attribute);
    if (!a)
        return {};
    auto label = [&](Op op) -> QString {
        switch (op) {
        case Op::Is:
            return tr("is");
        case Op::IsNot:
            return tr("is not");
        case Op::Contains:
            return tr("contains");
        case Op::BeginsWith:
            return tr("begins with");
        case Op::EndsWith:
            return tr("ends with");
        case Op::WithinLast:
            return tr("is within last");
        case Op::Exactly:
            return tr("is exactly");
        case Op::Before:
            return tr("is before");
        case Op::After:
            return tr("is after");
        case Op::Today:
            return tr("is today");
        case Op::Yesterday:
            return tr("is yesterday");
        case Op::ThisWeek:
            return tr("is this week");
        case Op::ThisMonth:
            return tr("is this month");
        case Op::ThisYear:
            return tr("is this year");
        case Op::Greater:
            return tr("is greater than");
        case Op::Less:
            return tr("is less than");
        }
        return QString();
    };
    auto valueKind = [&](Op op) -> QString {
        switch (*a) {
        case Attribute::Kind:
            return QStringLiteral("kind");
        case Attribute::Tags:
            return QStringLiteral("tag");
        case Attribute::Size:
            return QStringLiteral("number");
        case Attribute::Opened:
        case Attribute::Modified:
        case Attribute::Created:
            return op == Op::WithinLast ? QStringLiteral("number")
                   : (op == Op::Exactly || op == Op::Before || op == Op::After) ? QStringLiteral("date")
                                                                               : QStringLiteral("none");
        case Attribute::Name:
        case Attribute::Contents:
            return QStringLiteral("text");
        }
        return QStringLiteral("none");
    };
    QVariantList out;
    for (const Op op : SearchLogic::operatorsFor(*a))
        out.append(QVariantMap{{QStringLiteral("key"), SearchLogic::opKey(op)}, {QStringLiteral("label"), label(op)}, {QStringLiteral("value"), valueKind(op)}});
    return out;
}

QVariantList FilesApp::searchUnits(const QString &attribute) const
{
    const auto a = SearchLogic::attributeFromKey(attribute);
    if (!a)
        return {};
    auto unit = [](const char *key, const QString &label) { return QVariantMap{{QStringLiteral("key"), QString::fromLatin1(key)}, {QStringLiteral("label"), label}}; };
    switch (*a) {
    case SearchLogic::Attribute::Opened:
    case SearchLogic::Attribute::Modified:
    case SearchLogic::Attribute::Created:
        return {unit("days", tr("days")), unit("weeks", tr("weeks")), unit("months", tr("months")), unit("years", tr("years"))};
    case SearchLogic::Attribute::Size:
        return {unit("KB", tr("KB")), unit("MB", tr("MB")), unit("GB", tr("GB"))};
    default:
        return {};
    }
}

QVariantList FilesApp::searchKinds() const
{
    using FileLogic::KindCategory;
    // The Finder's Kind pop-up, in its order (Linux types: Executable and Text are Application and Document here).
    const QList<QPair<QString, QString>> kinds = {
        {QStringLiteral("any"), tr("Any")},
        {SearchLogic::kindKey(KindCategory::Application), tr("Application")},
        {SearchLogic::kindKey(KindCategory::Archive), tr("Archive")},
        {SearchLogic::kindKey(KindCategory::Document), tr("Document")},
        {SearchLogic::kindKey(KindCategory::Folder), tr("Folder")},
        {SearchLogic::kindKey(KindCategory::Image), tr("Image")},
        {SearchLogic::kindKey(KindCategory::Movie), tr("Movie")},
        {SearchLogic::kindKey(KindCategory::Music), tr("Music")},
        {SearchLogic::kindKey(KindCategory::Pdf), tr("PDF")},
        {SearchLogic::kindKey(KindCategory::Presentation), tr("Presentation")},
        {SearchLogic::kindKey(KindCategory::Spreadsheet), tr("Spreadsheet")},
        {SearchLogic::kindKey(KindCategory::Other), tr("Other")},
    };
    QVariantList out;
    for (const auto &[key, label] : kinds)
        out.append(QVariantMap{{QStringLiteral("key"), key}, {QStringLiteral("label"), label}});
    return out;
}

QVariantMap FilesApp::searchCriterion(const QString &attribute) const
{
    const auto a = SearchLogic::attributeFromKey(attribute);
    if (!a)
        return {};
    const SearchLogic::Op op = SearchLogic::operatorsFor(*a).constFirst();
    QString value;
    QString unit;
    switch (*a) {
    case SearchLogic::Attribute::Kind:
        value = QStringLiteral("any");
        break;
    case SearchLogic::Attribute::Opened:
    case SearchLogic::Attribute::Modified:
    case SearchLogic::Attribute::Created:
        value = QStringLiteral("7");
        unit = QStringLiteral("days");
        break;
    case SearchLogic::Attribute::Size:
        unit = QStringLiteral("KB");
        break;
    default:
        break;
    }
    return {{QStringLiteral("attribute"), attribute}, {QStringLiteral("op"), SearchLogic::opKey(op)}, {QStringLiteral("value"), value}, {QStringLiteral("unit"), unit}};
}

QString FilesApp::searchDateText(const QString &iso) const
{
    const QDate day = QDate::fromString(iso.trimmed(), Qt::ISODate);
    return day.isValid() ? QLocale().toString(day, QLocale::ShortFormat) : QString();
}

QString FilesApp::searchDateValue(const QString &text) const
{
    const QString t = text.trimmed();
    QDate day = QLocale().toDate(t, QLocale::ShortFormat);
    if (!day.isValid())
        day = QDate::fromString(t, Qt::ISODate);
    // A two-digit year reads as this century (Qt reads "31/10/26" as 1926).
    if (day.isValid() && day.year() < 1970 && !t.contains(QString::number(day.year())))
        day = day.addYears(100);
    return day.isValid() ? day.toString(Qt::ISODate) : QString();
}

QString FilesApp::searchToday() const
{
    return QDate::currentDate().toString(Qt::ISODate);
}

QString FilesApp::placeShortcut(const QString &kind, const QUrl &url) const
{
    const QStringList xdg = {QStandardPaths::writableLocation(QStandardPaths::DesktopLocation),
                             QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation),
                             QStandardPaths::writableLocation(QStandardPaths::DownloadLocation)};
    return NavLogic::placeShortcut(kind, url.isLocalFile() ? url.toLocalFile() : QString(), QDir::homePath(), xdg);
}

QUrl FilesApp::standardFolder(const QString &which) const
{
    if (which == QLatin1String("desktop"))
        return QUrl::fromLocalFile(QStandardPaths::writableLocation(QStandardPaths::DesktopLocation));
    if (which == QLatin1String("documents"))
        return QUrl::fromLocalFile(QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation));
    if (which == QLatin1String("downloads"))
        return QUrl::fromLocalFile(QStandardPaths::writableLocation(QStandardPaths::DownloadLocation));
    if (which == QLatin1String("computer"))
        return QUrl::fromLocalFile(QStringLiteral("/"));
    if (which == QLatin1String("network") && m_places && m_places->networkAvailable())
        return QUrl(QStringLiteral("remote:/"));
    return {};
}

void FilesApp::completeFolder(const QString &text, const QUrl &base)
{
    const quint64 generation = ++m_completionGeneration;
    const NavLogic::CompletionTarget target = NavLogic::completionTarget(text, base.isLocalFile() ? base.toLocalFile() : QString(), QDir::homePath());
    if (target.folder.isEmpty()) {
        emit folderCompletions(text, {});
        return;
    }
    const bool hidden = showHidden();
    const QPointer<FilesApp> self(this);
    // Listed on a thread of its own: a folder on a slow or hung mount never blocks the window (the answer is then
    // dropped by the next request's generation).
    QThread *thread = QThread::create([self, generation, text, target, hidden]() {
        QStringList names;
        QDirIterator it(target.folder, QDir::Dirs | QDir::NoDotAndDotDot | QDir::Hidden);
        for (int seen = 0; it.hasNext() && seen < kMaxCompletionScan; ++seen) {
            it.next();
            names.append(it.fileName());
        }
        const QStringList matches = NavLogic::folderMatches(names, target.prefix, hidden, kMaxCompletions);
        QMetaObject::invokeMethod(
            qApp,
            [self, generation, text, target, matches]() {
                if (!self || generation != self->m_completionGeneration)
                    return;
                QVariantList out;
                const QStringList parts = target.folder.split(QLatin1Char('/'), Qt::SkipEmptyParts);
                for (const QString &name : matches) {
                    const QString path = target.folder == QStringLiteral("/") ? QLatin1Char('/') + name : target.folder + QLatin1Char('/') + name;
                    out.append(QVariantMap{{QStringLiteral("name"), name},
                                           {QStringLiteral("url"), QUrl::fromLocalFile(path)},
                                           {QStringLiteral("parts"), QStringList(parts) << name}});
                }
                emit self->folderCompletions(text, out);
            },
            Qt::QueuedConnection);
    });
    connect(thread, &QThread::finished, thread, &QObject::deleteLater);
    thread->start();
}

QString FilesApp::completedText(const QString &text, const QUrl &base, const QString &match) const
{
    return NavLogic::completedText(NavLogic::completionTarget(text, base.isLocalFile() ? base.toLocalFile() : QString(), QDir::homePath()), match);
}

QVariantMap FilesApp::goToTarget(const QString &text, const QUrl &base) const
{
    const NavLogic::GoToTarget target = NavLogic::goToTarget(locationUrl(text, base));
    return {{QStringLiteral("folder"), target.folder}, {QStringLiteral("select"), target.select}};
}

QStringList FilesApp::storedUrls(const QString &key, int max) const
{
    QStringList out;
    for (const QString &s : m_settings.value(key).toStringList()) {
        const QUrl url(s, QUrl::StrictMode);
        if (url.isValid() && !url.scheme().isEmpty() && !out.contains(s))
            out.append(s);
        if (out.size() >= max)
            break;
    }
    return out;
}

QVariantList FilesApp::recentFolders() const
{
    QVariantList out;
    for (const QString &s : storedUrls(QStringLiteral("go/recentFolders"), kMaxRecentFolders))
        out.append(QVariantMap{{QStringLiteral("url"), QUrl(s)}});
    return out;
}

void FilesApp::noteFolder(const QUrl &url)
{
    // Folders one goes back to: local folders and servers; never a search, the Trash, Recents or the Applications list.
    const QString scheme = url.scheme();
    if (scheme != QLatin1String("file") && !NavLogic::serverUrl(url.toString()).isValid())
        return;
    const QString clean = url.adjusted(QUrl::StripTrailingSlash | QUrl::NormalizePathSegments | QUrl::RemovePassword).toString();
    const QStringList before = storedUrls(QStringLiteral("go/recentFolders"), kMaxRecentFolders);
    const QStringList after = NavLogic::pushRecent(before, clean, kMaxRecentFolders);
    if (after == before)
        return;
    m_settings.setValue(QStringLiteral("go/recentFolders"), after);
    emit recentFoldersChanged();
}

void FilesApp::clearRecentFolders()
{
    m_settings.remove(QStringLiteral("go/recentFolders"));
    emit recentFoldersChanged();
}

QUrl FilesApp::serverUrl(const QString &text) const
{
    return NavLogic::serverUrl(text);
}

QStringList FilesApp::recentServers() const
{
    return storedUrls(QStringLiteral("servers/recent"), kMaxServers);
}

QStringList FilesApp::favoriteServers() const
{
    return storedUrls(QStringLiteral("servers/favorites"), kMaxServers);
}

void FilesApp::noteServer(const QUrl &url)
{
    const QUrl clean = NavLogic::serverUrl(url.toString());
    if (!clean.isValid())
        return;
    m_settings.setValue(QStringLiteral("servers/recent"), NavLogic::pushRecent(recentServers(), clean.toString(), kMaxServers));
    emit serversChanged();
}

bool FilesApp::addFavoriteServer(const QString &text)
{
    const QUrl url = NavLogic::serverUrl(text);
    if (!url.isValid())
        return false;
    QStringList favorites = favoriteServers();
    if (!favorites.contains(url.toString()) && favorites.size() < kMaxServers)
        favorites.append(url.toString());
    m_settings.setValue(QStringLiteral("servers/favorites"), favorites);
    emit serversChanged();
    return true;
}

void FilesApp::removeFavoriteServer(int index)
{
    QStringList favorites = favoriteServers();
    if (index < 0 || index >= favorites.size())
        return;
    favorites.removeAt(index);
    m_settings.setValue(QStringLiteral("servers/favorites"), favorites);
    emit serversChanged();
}

void FilesApp::clearRecentServers()
{
    m_settings.remove(QStringLiteral("servers/recent"));
    emit serversChanged();
}

QVariantList FilesApp::savedSearches() const
{
    QVariantList out;
    for (const SavedSearches::Entry &e : m_savedSearches->entries()) {
        out.append(QVariantMap{{QStringLiteral("name"), e.saved.name},
                               {QStringLiteral("url"), SearchLogic::toUrl(e.saved.query)},
                               {QStringLiteral("sidebar"), e.saved.sidebar},
                               {QStringLiteral("file"), e.file}});
    }
    return out;
}

QString FilesApp::saveSearch(const QString &name, const QUrl &search, bool sidebar)
{
    const auto query = SearchLogic::fromUrl(search);
    if (!query)
        return tr("This search can’t be read.");
    return m_savedSearches->save({name, *query, sidebar});
}

bool FilesApp::hasSavedSearch(const QString &name) const
{
    const QString wanted = name.trimmed();
    for (const SavedSearches::Entry &e : m_savedSearches->entries()) {
        if (FileLogic::sameName(e.saved.name, wanted))
            return true;
    }
    return false;
}

void FilesApp::removeSavedSearch(const QString &file)
{
    if (!m_savedSearches->remove(file))
        emit operationFailed(tr("The saved search couldn’t be moved to the Trash."));
}

void FilesApp::setSavedSearchInSidebar(const QString &file, bool on)
{
    if (!m_savedSearches->setSidebar(file, on))
        emit operationFailed(tr("The saved search couldn’t be changed."));
}

void FilesApp::publishSavedSearches()
{
    QList<PlacesModel::SavedSearch> sidebar;
    for (const SavedSearches::Entry &e : m_savedSearches->entries()) {
        if (e.saved.sidebar)
            sidebar.append({e.saved.name, SearchLogic::toUrl(e.saved.query), e.file});
    }
    m_places->setSavedSearches(sidebar);
    emit savedSearchesChanged();
}

bool FilesApp::eventFilter(QObject *watched, QEvent *event)
{
    if (!watched->isWindowType())
        return false;
    switch (event->type()) {
    case QEvent::DragEnter:
    case QEvent::DragMove: {
        const auto *e = static_cast<QDragMoveEvent *>(event);
        m_drags.insert(watched, {e->position(), e->possibleActions(), e->mimeData(), e->buttons(), e->modifiers(), e->source() != nullptr});
        break;
    }
    case QEvent::DragLeave:
    case QEvent::Drop: {
        const auto it = m_drags.constFind(watched);
        const bool outside = it != m_drags.cend() && !it->local;
        m_drags.remove(watched);
        if (outside)
            emit outsideDragEnded(watched, event->type() == QEvent::Drop);
        break;
    }
    default:
        break;
    }
    return false;
}

void FilesApp::refreshDrag(QObject *window)
{
    const auto it = m_drags.constFind(window);
    if (!window || it == m_drags.cend() || !it->mime)
        return;
    // Qt 6.11's QDragMoveEvent takes a whole-pixel position.
    QDragMoveEvent move(it->position.toPoint(), it->actions, it->mime, it->buttons, it->modifiers);
    QCoreApplication::sendEvent(window, &move);
}

bool FilesApp::isRecents(const QUrl &url) const
{
    return Recents::isRecentsUrl(url);
}

QUrl FilesApp::recentsUrl() const
{
    return Recents::locationUrl();
}

int FilesApp::recentsSortKey() const
{
    return int(FileLogic::SortKey::Opened);
}

QString FilesApp::searchedTag(const QUrl &url) const
{
    return TagLogic::searchTag(url);
}

void FilesApp::noteTags(const QStringList &tags)
{
    // A tag removed from the sidebar stays off it (macOS: Remove from Sidebar hides it; files keep the tag).
    const QStringList next = TagLogic::mergeKnown(m_knownTags, m_hiddenTags, tags, kMaxKnownTags);
    if (next == m_knownTags)
        return;
    m_knownTags = next;
    m_settings.setValue(QStringLiteral("tags/known"), m_knownTags);
    publishKnownTags();
}

void FilesApp::forgetTag(const QString &tag)
{
    if (tag.trimmed().isEmpty())
        return;
    if (!TagLogic::hasTag(m_hiddenTags, tag)) {
        m_hiddenTags = TagLogic::withTag(m_hiddenTags, tag, true);
        // The oldest entries go first when the list is full.
        while (m_hiddenTags.size() > kMaxHiddenTags)
            m_hiddenTags.removeFirst();
        m_settings.setValue(QStringLiteral("tags/hidden"), m_hiddenTags);
        emit hiddenTagsChanged();
    }
    const QStringList next = TagLogic::withTag(m_knownTags, tag, false);
    if (next == m_knownTags)
        return;
    m_knownTags = next;
    m_settings.setValue(QStringLiteral("tags/known"), m_knownTags);
    publishKnownTags();
}

void FilesApp::unhideTag(const QString &tag)
{
    if (!TagLogic::hasTag(m_hiddenTags, tag))
        return;
    m_hiddenTags = TagLogic::withTag(m_hiddenTags, tag, false);
    m_settings.setValue(QStringLiteral("tags/hidden"), m_hiddenTags);
    emit hiddenTagsChanged();
}

void FilesApp::showTag(const QString &tag)
{
    unhideTag(tag);
    // Listed at once, not only when an item holding it is shown next.
    noteTags({tag});
}

void FilesApp::publishKnownTags()
{
    m_places->setTags(m_knownTags);
}

void FilesApp::publishSidebar()
{
    m_settings.setValue(QStringLiteral("sidebar/favorites"), NavLogic::sidebarStored(m_sidebarFolders));
    m_settings.setValue(QStringLiteral("sidebar/hidden"), NavLogic::sidebarStored(m_sidebarHidden));
    m_places->setFavorites(m_sidebarFolders, m_sidebarHidden);
}

void FilesApp::addToSidebar(const QList<QUrl> &urls, int position)
{
    QList<QUrl> asked;
    bool unhidden = false;
    for (const QUrl &raw : urls) {
        const QUrl url = NavLogic::sidebarUrl(raw);
        if (m_sidebarHidden.removeAll(url) > 0) {
            unhidden = true; // a standard place removed before: listed again where it belongs
            continue;
        }
        if (m_places->inFavorites(url) || !NavLogic::sidebarCandidate(url) || asked.contains(url))
            continue;
        asked.append(url);
    }
    if (unhidden)
        publishSidebar();
    if (asked.isEmpty())
        return;
    // Only folders join Favorites: KIO says which items are (a link to a folder is one); nothing is read on this thread.
    struct Pending {
        QList<QUrl> urls;
        QList<bool> folders;
        int left = 0;
    };
    auto pending = std::make_shared<Pending>();
    pending->urls = asked;
    pending->folders = QList<bool>(asked.size(), false);
    pending->left = int(asked.size());
    for (int i = 0; i < asked.size(); ++i) {
        KIO::StatJob *job = KIO::stat(asked.at(i), KIO::StatJob::SourceSide, KIO::StatBasic | KIO::StatResolveSymlink, KIO::HideProgressInfo);
        attachDelegate(job); // Grassfield's delegate, no automatic error dialog: a failed stat is "not a folder"
        connect(job, &KJob::result, this, [this, job, pending, i, position] {
            pending->folders[i] = !job->error() && job->statResult().isDir();
            if (--pending->left > 0)
                return;
            QList<QUrl> folders;
            for (int k = 0; k < pending->urls.size(); ++k) {
                if (pending->folders.at(k))
                    folders.append(pending->urls.at(k));
            }
            if (folders.size() < pending->urls.size())
                emit operationFailed(tr("Only folders can be added to the sidebar."));
            const QList<QUrl> next = NavLogic::withSidebarFolders(m_sidebarFolders, folders, position);
            if (next == m_sidebarFolders)
                return;
            m_sidebarFolders = next;
            publishSidebar();
        });
    }
}

void FilesApp::removeFromSidebar(const QUrl &raw)
{
    const QUrl url = NavLogic::sidebarUrl(raw);
    if (m_sidebarFolders.removeAll(url) > 0) {
        publishSidebar();
        return;
    }
    // A standard place: hidden (the folder and its contents are never touched).
    if (m_places->inFavorites(url) && !m_sidebarHidden.contains(url) && m_sidebarHidden.size() < NavLogic::kMaxSidebarFavorites) {
        m_sidebarHidden.append(url);
        publishSidebar();
    }
}

void FilesApp::moveInSidebar(const QUrl &url, int position)
{
    const QList<QUrl> next = NavLogic::movedInSidebar(m_sidebarFolders, url, position);
    if (next == m_sidebarFolders)
        return;
    m_sidebarFolders = next;
    publishSidebar();
}

bool FilesApp::inSidebar(const QUrl &url) const
{
    return m_places->inFavorites(url);
}

void FilesApp::followAmounts(KJob *tracked, KJob *source)
{
    connect(source, &KJob::processedAmountChanged, this, [this, tracked](KJob *, KJob::Unit unit, qulonglong amount) {
        auto it = m_progress.find(tracked);
        if (it != m_progress.end() && unit == KJob::Bytes) {
            it->processed = amount;
            if (!m_progressTimer.isActive())
                m_progressTimer.start();
        }
    });
    connect(source, &KJob::totalAmountChanged, this, [this, tracked](KJob *, KJob::Unit unit, qulonglong amount) {
        auto it = m_progress.find(tracked);
        if (it != m_progress.end() && unit == KJob::Bytes)
            it->total = amount;
    });
    connect(source, &KJob::speed, this, [this, tracked](KJob *, unsigned long speed) {
        auto it = m_progress.find(tracked);
        if (it != m_progress.end())
            it->speed = speed;
    });
    connect(source, &KJob::percentChanged, this, [this, tracked](KJob *, unsigned long percent) {
        auto it = m_progress.find(tracked);
        if (it != m_progress.end()) {
            it->percent = int(percent);
            if (!m_progressTimer.isActive())
                m_progressTimer.start();
        }
    });
}

void FilesApp::forwardSubjobAmounts(const QPointer<KJob> &job, int tries)
{
    // The paste starts its copy or move from the event loop: look for it for two seconds (a paste that is a rename ends
    // before and has none).
    if (!job || !m_progress.contains(job))
        return;
    // KCompositeJob::addSubjob makes the subjob its child.
    const auto subs = job->findChildren<KIO::CopyJob *>(Qt::FindDirectChildrenOnly);
    if (!subs.isEmpty()) {
        followAmounts(job, subs.first());
        return;
    }
    if (tries > 0)
        QTimer::singleShot(50, this, [this, job, tries] { forwardSubjobAmounts(job, tries - 1); });
}

void FilesApp::track(KJob *job, const QString &activity, const QString &verb, const QList<QUrl> &sources, const QUrl &destination)
{
    m_jobs.append(job);
    m_activity = activity;
    m_activityPercent = -1;
    emit activityChanged();
    JobProgress progress;
    progress.id = m_nextJobId++;
    progress.activity = activity;
    // The Copy window names what the user asked for and where it goes; KIO's own item and destination change with every
    // file of a folder ("Copying “faaabgd” to “big”" while it copies the folder “big” to “Docs”).
    progress.count = int(sources.size());
    if (!sources.isEmpty() && !verb.isEmpty()) {
        progress.verb = verb;
        progress.item = sources.first().fileName();
        progress.destination = destination.adjusted(QUrl::StripTrailingSlash).fileName();
    }
    m_progress.insert(job, progress);
    m_progressTimer.start();
    connect(job, &KJob::description, this, [this, job](KJob *, const QString &title, const QPair<QString, QString> &source, const QPair<QString, QString> &destination) {
        auto it = m_progress.find(job);
        if (it == m_progress.end())
            return;
        // A job that was given its words keeps them (KIO's change with each step: "Creating directory", each file).
        if (it->count == 0) {
            it->verb = title;
            it->item = QUrl(source.second).fileName();
            const QUrl to(destination.second);
            it->destination = to.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash).fileName();
        }
        if (!m_progressTimer.isActive())
            m_progressTimer.start();
    });
    followAmounts(job, job);
    // A paste is a job of its own that forwards no amounts (KIO::PasteJob): the copy or move it runs inside does.
    if (!qobject_cast<KIO::CopyJob *>(job))
        forwardSubjobAmounts(job, 40);
    connect(job, &QObject::destroyed, this, [this, job] {
        m_progress.remove(job);
        publishJobs();
    });
    connect(job, &KJob::percentChanged, this, [this, job](KJob *, unsigned long percent) {
        if (!m_jobs.isEmpty() && m_jobs.last() == job) {
            m_activityPercent = int(percent);
            emit activityChanged();
        }
    });
    connect(job, &KJob::result, this, [this, job] {
        if (job->error() && job->error() != KIO::ERR_USER_CANCELED)
            emit operationFailed(job->errorString());
        m_jobs.removeAll(job);
        m_jobs.removeIf([](const QPointer<KJob> &p) { return p.isNull(); });
        m_activity = m_jobs.isEmpty() && m_archiveJobs.isEmpty() ? QString() : m_activity;
        m_activityPercent = -1;
        emit activityChanged();
        m_progress.remove(job);
        publishJobs();
    });
}
