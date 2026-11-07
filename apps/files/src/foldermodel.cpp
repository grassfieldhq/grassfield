#include "foldermodel.h"

#include "applicationslogic.h"
#include "filelogic.h"
#include "filesearch.h"
#include "folderstylestore.h"
#include "imageproviders.h"
#include "imagesize.h"
#include "recents.h"
#include "runmode.h"
#include "searchlogic.h"
#include "taglogic.h"
#include "tagsearch.h"
#include "tagstore.h"

#include <QAbstractListModel>
#include <QDBusConnection>
#include <QDeadlineTimer>
#include <QDir>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QLoggingCategory>
#include <QIcon>
#include <QImage>
#include <QMimeDatabase>
#include <QMimeType>
#include <QPointer>
#include <QScopedValueRollback>
#include <QStandardPaths>
#include <memory>
#include <QThread>

#include <KApplicationTrader>
#include <KDirLister>
#include <KDirModel>
#include <KDirNotify>
#include <KIO/FileSystemFreeSpaceJob>
#include <KIO/Job>
#include <KIO/PreviewJob>
#include <KIO/UDSEntry>

#include <sys/stat.h>

// QT_LOGGING_RULES="grassfield.files.debug=true": listing times, selection and expectation traces.
Q_LOGGING_CATEGORY(lcFiles, "grassfield.files", QtInfoMsg)

// The matches of a tag search, or the recent files: a flat list of items (the proxy reads them through FolderModel::sourceItem).
class ItemListModel : public QAbstractListModel
{
public:
    using QAbstractListModel::QAbstractListModel;

    int rowCount(const QModelIndex &parent = QModelIndex()) const override { return parent.isValid() ? 0 : int(m_items.size()); }
    QVariant data(const QModelIndex &index, int role) const override
    {
        if (role != Qt::DisplayRole || index.row() < 0 || index.row() >= m_items.size())
            return {};
        return m_items.at(index.row()).text();
    }

    KFileItem item(int row) const { return row >= 0 && row < m_items.size() ? m_items.at(row) : KFileItem(); }
    int rowOf(const QUrl &url) const { return m_rows.value(url, -1); }
    const KFileItemList &items() const { return m_items; }

    void append(const KFileItemList &items)
    {
        KFileItemList fresh;
        for (const KFileItem &item : items) {
            if (!m_rows.contains(item.url()))
                fresh.append(item);
        }
        if (fresh.isEmpty())
            return;
        const int first = int(m_items.size());
        beginInsertRows(QModelIndex(), first, first + int(fresh.size()) - 1);
        for (const KFileItem &item : std::as_const(fresh)) {
            m_rows.insert(item.url(), int(m_items.size()));
            m_items.append(item);
        }
        endInsertRows();
    }

    void remove(const QUrl &url)
    {
        const int row = rowOf(url);
        if (row < 0)
            return;
        beginRemoveRows(QModelIndex(), row, row);
        m_items.removeAt(row);
        reindex();
        endRemoveRows();
    }

    void replace(const QUrl &url, const KFileItem &item)
    {
        const int row = rowOf(url);
        if (row < 0)
            return;
        m_items[row] = item;
        reindex();
        emit dataChanged(index(row), index(row));
    }

    void clear()
    {
        if (m_items.isEmpty())
            return;
        beginResetModel();
        m_items.clear();
        m_rows.clear();
        endResetModel();
    }

private:
    void reindex()
    {
        m_rows.clear();
        for (int i = 0; i < m_items.size(); ++i)
            m_rows.insert(m_items.at(i).url(), i);
    }

    KFileItemList m_items;
    QHash<QUrl, int> m_rows;
};

namespace
{
constexpr int kSelectionBulkThreshold = 64;
constexpr int kPreviewBatchDelayMs = 30;
// One PreviewJob never holds more than this many items, and at most this many thumbnails are kept
// (a 128 px thumbnail is ~64 KB: 512 of them stay below ~32 MB).
constexpr int kPreviewBatchSize = 32;
// An expected item that has not appeared by then (failed or slow job) no longer steers the selection.
constexpr int kExpectationLifetimeMs = 10000;

// An application's icon: a theme icon name as is; an absolute path only when it passes the shell's rules for an Icon= file
// (ApplicationsLogic::safeIconFile: a regular file within the size cap under the allowed roots, never a FIFO or a device,
// which the image provider would block the GUI thread on); anything else (a missing or unknown icon) the generic application
// icon.
QString applicationIconName(const QString &name)
{
    static const QStringList roots = ApplicationsLogic::iconRoots();
    if (name.startsWith(QLatin1Char('/'))) {
        const QString file = ApplicationsLogic::safeIconFile(name, roots);
        if (!file.isEmpty())
            return file;
    } else if (!name.isEmpty() && QIcon::hasThemeIcon(name)) {
        return name;
    }
    return QIcon::hasThemeIcon(QStringLiteral("application-x-executable")) ? QStringLiteral("application-x-executable") : QStringLiteral("text-x-generic");
}

QString resolvedIconName(const KFileItem &item)
{
    // Cache per icon name: QIcon::hasThemeIcon walks the theme directories.
    static QHash<QString, QString> cache;
    const QString name = item.iconName();
    const auto it = cache.constFind(name);
    if (it != cache.cend())
        return *it;
    QString resolved = name;
    if (name.isEmpty() || !QIcon::hasThemeIcon(name)) {
        const QString generic = item.currentMimeType().genericIconName();
        if (!generic.isEmpty() && QIcon::hasThemeIcon(generic))
            resolved = generic;
        else
            resolved = item.isDir() ? QStringLiteral("folder") : QStringLiteral("text-x-generic");
    }
    cache.insert(name, resolved);
    return resolved;
}

// Only the fields the active key compares: lessThan runs O(n log n) times while a folder is listed,
// and the MIME comment is a database lookup.
// An item's MIME type name without sniffing its content on the GUI thread: the lister resolves types lazily
// (setDelayedMimeTypes); until an item's type is known, the extension/name guess (memoized per file name: the glob lookup
// is ~100 us and sorting asks O(n log n) times).
QString mimeNameOf(const KFileItem &item)
{
    if (item.isMimeTypeKnown())
        return item.mimetype();
    static QHash<QString, QString> guesses;
    static const QMimeDatabase db;
    const QString name = item.name();
    auto it = guesses.constFind(name);
    if (it == guesses.cend()) {
        if (guesses.size() > 50000)
            guesses.clear();
        it = guesses.insert(name, db.mimeTypeForFile(name, QMimeDatabase::MatchExtension).name());
    }
    return *it;
}

// A MIME type's comment, its name followed by its ancestors, and the name of the application that opens it by
// default: memoized per type (KApplicationTrader reads the service database).
struct MimeFacts {
    QString comment;
    QStringList lineage;
    QString application;
};

const MimeFacts &mimeFacts(const QString &name)
{
    static QHash<QString, MimeFacts> facts;
    auto it = facts.constFind(name);
    if (it == facts.cend()) {
        static const QMimeDatabase db;
        const QMimeType type = db.mimeTypeForName(name);
        MimeFacts f;
        f.comment = type.comment();
        f.lineage = QStringList{type.name()} + type.allAncestors();
        const KService::Ptr service = KApplicationTrader::preferredService(type.name());
        f.application = service ? service->name() : QString();
        it = facts.insert(name, f);
    }
    return *it;
}

struct PreviewMimes {
    QSet<QString> exact;
    QStringList prefixes; // "image/" for "image/*"
};

const PreviewMimes &previewMimes()
{
    static const PreviewMimes mimes = [] {
        PreviewMimes m;
        const QStringList all = KIO::PreviewJob::supportedMimeTypes();
        for (const QString &mime : all) {
            if (mime.endsWith(QLatin1String("/*")))
                m.prefixes << mime.chopped(1);
            else
                m.exact.insert(mime);
        }
        return m;
    }();
    return mimes;
}

const QStringList &previewPlugins()
{
    // Every installed thumbnailer (kf6/thumbcreator plugins and freedesktop .thumbnailer entries).
    static const QStringList plugins = KIO::PreviewJob::availablePlugins();
    return plugins;
}
} // namespace

FolderModel::FolderModel(QObject *parent)
    : QSortFilterProxyModel(parent)
{
    m_dirModel = new KDirModel(this);
    m_lister = m_dirModel->dirLister();
    m_lister->setAutoErrorHandlingEnabled(false);
    m_lister->setDelayedMimeTypes(true);
    m_results = new ItemListModel(this);
    m_appsTimer.setSingleShot(true);
    m_appsTimer.setInterval(400);
    connect(&m_appsWatcher, &QFileSystemWatcher::directoryChanged, this, [this] { m_appsTimer.start(); });
    connect(&m_appsTimer, &QTimer::timeout, this, [this] {
        if (isApplications())
            loadApplications();
    });

    // Before the proxy's own connections (setSourceModel): the items that changed are grouped afresh when they are sorted
    // again (KDirModel reports each item whose type it found, one by one).
    connect(m_dirModel, &QAbstractItemModel::dataChanged, this, [this](const QModelIndex &topLeft, const QModelIndex &bottomRight) {
        for (int row = topLeft.row(); row <= bottomRight.row(); row++)
            m_groupCache.remove(m_dirModel->itemForIndex(topLeft.siblingAtRow(row)).url());
    });
    connect(m_results, &QAbstractItemModel::dataChanged, this, [this](const QModelIndex &topLeft, const QModelIndex &bottomRight) {
        for (int row = topLeft.row(); row <= bottomRight.row(); row++)
            m_groupCache.remove(m_results->item(row).url());
    });
    // Items that go, and the old names of renamed ones, leave the cache too: a new item at the same URL is grouped afresh.
    connect(m_dirModel, &QAbstractItemModel::rowsAboutToBeRemoved, this, [this](const QModelIndex &parent, int first, int last) {
        for (int row = first; row <= last; row++)
            m_groupCache.remove(m_dirModel->itemForIndex(m_dirModel->index(row, 0, parent)).url());
    });
    connect(m_results, &QAbstractItemModel::rowsAboutToBeRemoved, this, [this](const QModelIndex &, int first, int last) {
        for (int row = first; row <= last; row++)
            m_groupCache.remove(m_results->item(row).url());
    });
    connect(m_lister, &KCoreDirLister::refreshItems, this, [this](const QList<QPair<KFileItem, KFileItem>> &items) {
        for (const auto &change : items)
            m_groupCache.remove(change.first.url());
    });
    m_dayTimer.setSingleShot(true);
    connect(&m_dayTimer, &QTimer::timeout, this, &FolderModel::regroupForNewDay);
    setSourceModel(m_dirModel);
    setDynamicSortFilter(true);

    // The C locale collator has no numeric ("file2" < "file10") mode.
    QLocale locale;
    if (locale.language() == QLocale::C)
        locale = QLocale(QLocale::English, QLocale::UnitedStates);
    m_collator = QCollator(locale);
    m_collator.setNumericMode(true);
    m_collator.setCaseSensitivity(Qt::CaseInsensitive);
    sort(0, Qt::AscendingOrder);
    // Rows that come, go or change may change the groups (the list view's sections follow GroupRole by themselves).
    connect(this, &QAbstractItemModel::rowsInserted, this, &FolderModel::groupsDirty);
    connect(this, &QAbstractItemModel::rowsRemoved, this, &FolderModel::groupsDirty);
    connect(this, &QAbstractItemModel::modelReset, this, &FolderModel::groupsDirty);
    connect(this, &QAbstractItemModel::layoutChanged, this, &FolderModel::groupsDirty);
    connect(this, &QAbstractItemModel::dataChanged, this, [this](const QModelIndex &, const QModelIndex &, const QList<int> &roles) {
        // Selection, thumbnails, picture sizes and folder looks do not move an item to another group.
        if (m_groupBy != 0 && !roles.contains(SelectedRole) && !roles.contains(ThumbnailRole) && !roles.contains(LargeThumbnailRole)
            && !roles.contains(DimensionsRole))
            groupsDirty();
    });

    connect(m_lister, &KCoreDirLister::started, this, [this] {
        m_loading = true;
        m_listTimer.start();
        emit loadingChanged();
    });
    connect(m_lister, qOverload<>(&KCoreDirLister::completed), this, [this] {
        qCDebug(lcFiles) << "listed" << m_url.toDisplayString() << rowCount() << "items in" << m_listTimer.elapsed() << "ms";
        m_loading = false;
        emit loadingChanged();
        emit rootChanged();
        refreshFreeSpace();
    });
    connect(m_lister, qOverload<>(&KCoreDirLister::canceled), this, [this] {
        m_loading = false;
        emit loadingChanged();
    });
    connect(m_lister, &KCoreDirLister::itemsDeleted, this, &FolderModel::onItemsDeleted);
    connect(m_lister, &KCoreDirLister::refreshItems, this, [this](const QList<QPair<KFileItem, KFileItem>> &items) {
        // Changed files get a fresh thumbnail, and their tags are read again.
        for (const auto &pair : items) {
            const QUrl url = pair.second.url();
            forgetThumbnail(m_small, url, true);
            forgetThumbnail(m_large, url, true);
            dropTags(url);
        }
    });
    connect(m_lister, &KCoreDirLister::jobError, this, [this](KIO::Job *job) {
        if (job)
            setError(job->errorString());
    });
    connect(m_lister, qOverload<const QUrl &, const QUrl &>(&KCoreDirLister::redirection), this, [this](const QUrl &, const QUrl &to) {
        if (to != m_url) {
            m_url = to;
            emit urlChanged();
        }
    });

    // Everything that reacts to a structural change runs after the views have processed it. These
    // connections are made before any view connects, so a synchronous reaction would reach QML
    // (count, currentRow -> GridView.currentIndex, selection dataChanged) while the views still hold
    // the previous rows, which shows up as duplicated or stale delegates.
    m_expectTimer.setSingleShot(true);
    m_expectTimer.setInterval(0);
    connect(&m_expectTimer, &QTimer::timeout, this, &FolderModel::checkExpected);
    const auto queueCheck = [this] {
        if ((!m_expected.isEmpty() || !m_expectedAlone.isEmpty()) && !m_checkingExpected)
            m_expectTimer.start();
    };
    m_attrTimer.setSingleShot(true);
    connect(&m_attrTimer, &QTimer::timeout, this, &FolderModel::revalidateStyles);
    // 200 ms of quiet, at the latest kAttrMaxWaitMs after the first change of a burst: steady activity in the folder (a
    // change every 50 ms) must not postpone showing a look set from outside for ever.
    connect(&m_attrTimer, &QTimer::timeout, this, [this] { m_attrBurst.invalidate(); });
    connect(&m_attrWatcher, &QFileSystemWatcher::directoryChanged, this, [this] {
        if (!m_attrBurst.isValid())
            m_attrBurst.start();
        m_attrTimer.start(FolderStyleLogic::debounceDelay(kAttrQuietMs, kAttrMaxWaitMs, m_attrBurst.elapsed()));
    });
    m_structureTimer.setSingleShot(true);
    m_structureTimer.setInterval(0);
    connect(&m_structureTimer, &QTimer::timeout, this, [this] {
        emit countChanged();
        emit currentRowChanged();
    });
    const auto queueStructure = [this, queueCheck] {
        m_structureTimer.start();
        queueCheck();
    };
    connect(this, &QAbstractItemModel::rowsInserted, this, queueStructure);
    connect(this, &QAbstractItemModel::rowsRemoved, this, queueStructure);
    connect(this, &QAbstractItemModel::rowsMoved, this, queueStructure);
    connect(this, &QAbstractItemModel::modelReset, this, queueStructure);
    connect(this, &QAbstractItemModel::layoutChanged, this, queueStructure);
    // A renamed item is refreshed in place (no insertion) and may move when re-sorted.
    connect(this, &QAbstractItemModel::dataChanged, this, queueCheck);

    for (ThumbChannel *channel : {&m_small, &m_large}) {
        channel->timer.setSingleShot(true);
        channel->timer.setInterval(kPreviewBatchDelayMs);
        connect(&channel->timer, &QTimer::timeout, this, [this, channel] { startPreviews(*channel); });
    }

    // Tags seen on shown rows are reported in one batch per event loop turn (data() is const and runs per delegate).
    m_seenTimer.setSingleShot(true);
    m_seenTimer.setInterval(0);
    connect(&m_seenTimer, &QTimer::timeout, this, [this] {
        const QStringList tags(m_seenPending.cbegin(), m_seenPending.cend());
        m_seenPending.clear();
        if (!tags.isEmpty())
            emit tagsSeen(tags);
    });

    // The tag search of a search location; the runner drops every batch of a superseded search.
    m_search = new SearchRunner(this);
    connect(m_search, &SearchRunner::found, this, &FolderModel::addResults);
    connect(m_search, &SearchRunner::done, this, [this](bool limited, int visited) {
        qCDebug(lcFiles) << "tag search" << m_url.toDisplayString() << rowCount() << "matches," << visited << "entries visited, limited" << limited << "in" << m_listTimer.elapsed() << "ms";
        m_searchLimited = limited;
        m_loading = false;
        emit loadingChanged();
    });
    // The search of a search location (ADR-0027), the same way.
    m_fileSearch = new FileSearchRunner(this);
    connect(m_fileSearch, &FileSearchRunner::found, this, &FolderModel::addResults);
    connect(m_fileSearch, &FileSearchRunner::done, this, [this](int backend, bool limited, bool contentsUnavailable) {
        qCDebug(lcFiles) << "search" << m_url.toDisplayString() << rowCount() << "matches, backend" << backend << "limited" << limited << "in" << m_listTimer.elapsed() << "ms";
        m_searchLimited = limited;
        m_searchBackend = backend;
        m_searchContentsUnavailable = contentsUnavailable;
        m_loading = false;
        emit loadingChanged();
    });
}

FolderModel::~FolderModel()
{
    stopSearch();
    clearAllPreviews();
    // A walk of the applications still running needs no wait here (it owns its data and its answer is dropped through the
    // QPointer); main.cpp joins it at quit.
    // The views go first; nothing may reach them while this object is half destroyed.
    m_seenTimer.stop();
}

void FolderModel::setUrl(const QUrl &url)
{
    const bool search = TagLogic::isSearchUrl(url) || Recents::isRecentsUrl(url) || SearchLogic::isSearchUrl(url);
    const bool applications = ApplicationsLogic::isLocationUrl(url);
    const QUrl clean = search ? url : applications ? ApplicationsLogic::locationUrl() : url.adjusted(QUrl::StripTrailingSlash | QUrl::NormalizePathSegments);
    if (clean == m_url && (search || applications || m_lister->url().isValid()))
        return;
    m_url = clean;
    applySelection({});
    m_current.clear();
    m_anchor.clear();
    m_expected.clear();
    m_expectedAlone.clear();
    m_renameUrl.clear();
    clearAllPreviews();
    m_tags.clear();
    m_styles.clear();
    m_dimensions.clear();
    clearGroupCache();
    setError(QString());
    m_freeSpace = -1;
    emit freeSpaceChanged();
    stopSearch();
    stopRecents();
    ++m_appsGeneration; // an Applications build still running is of no use now
    if (search) {
        // The folder listing stops; the matches of the search (or the recent files) are the rows.
        m_lister->stop();
        m_results->clear();
        if (sourceModel() != m_results)
            setSourceModel(m_results);
        if (Recents::isRecentsUrl(m_url))
            startRecents();
        else
            startSearch();
    } else if (applications) {
        // The folder listing stops; the installed applications are the rows.
        m_lister->stop();
        m_results->clear();
        if (sourceModel() != m_results)
            setSourceModel(m_results);
        loadApplications();
    } else {
        if (sourceModel() != m_dirModel)
            setSourceModel(m_dirModel);
        m_results->clear();
        m_apps.clear();
        m_dirModel->openUrl(m_url);
    }
    watchApplications();
    watchShownFolder();
    emit urlChanged();
    emit rootChanged();
    emit currentRowChanged();
}

bool FolderModel::isSearch() const
{
    return TagLogic::isSearchUrl(m_url) || isRecents() || isFileSearch();
}

bool FolderModel::isFileSearch() const
{
    return SearchLogic::isSearchUrl(m_url);
}

QUrl FolderModel::searchBase() const
{
    if (isFileSearch()) {
        const auto query = SearchLogic::fromUrl(m_url);
        if (query && !query->inComputer())
            return query->folder;
        const QString root = grassfield::apps::runmode::devValue("SEARCH_ROOT");
        return QUrl::fromLocalFile(root.isEmpty() ? QDir::homePath() : root);
    }
    return TagLogic::searchFolder(m_url);
}

bool FolderModel::isRecents() const
{
    return Recents::isRecentsUrl(m_url);
}

void FolderModel::startRecents()
{
    const quint64 generation = ++m_recentsGeneration;
    if (!m_recentsWatcher) {
        m_recentsWatcher = new QFileSystemWatcher(this);
        // Applications rewrite the file (a new inode): the folder is watched too. A burst of changes reads it once.
        m_recentsTimer.setSingleShot(true);
        m_recentsTimer.setInterval(300);
        connect(&m_recentsTimer, &QTimer::timeout, this, [this] {
            if (isRecents())
                startRecents();
        });
        connect(m_recentsWatcher, &QFileSystemWatcher::fileChanged, &m_recentsTimer, qOverload<>(&QTimer::start));
        connect(m_recentsWatcher, &QFileSystemWatcher::directoryChanged, &m_recentsTimer, qOverload<>(&QTimer::start));
    }
    const QString file = Recents::xbelPath();
    m_recentsWatcher->removePaths(m_recentsWatcher->files() + m_recentsWatcher->directories());
    if (QFileInfo::exists(file))
        m_recentsWatcher->addPath(file);
    if (QFileInfo::exists(QFileInfo(file).absolutePath()))
        m_recentsWatcher->addPath(QFileInfo(file).absolutePath());
    watchChanges();
    m_listTimer.start();
    m_loading = true;
    emit loadingChanged();
    auto *loader = new RecentsLoader(generation, file, Recents::renamed());
    connect(loader, &RecentsLoader::loaded, this, [this](quint64 gen, const QStringList &paths, const QVariantList &used) {
        if (gen != m_recentsGeneration || !isRecents())
            return;
        m_recentTimes.clear();
        for (int i = 0; i < paths.size() && i < used.size(); ++i)
            m_recentTimes.insert(QUrl::fromLocalFile(paths.at(i)), used.at(i).toDateTime());
        // The list as it is now: files that left it go, new ones come (the selection keeps what is still listed).
        QList<QUrl> gone;
        const QSet<QString> now(paths.cbegin(), paths.cend());
        for (const KFileItem &item : m_results->items()) {
            if (!now.contains(item.localPath()))
                gone.append(item.url());
        }
        removeResults(gone);
        QStringList fresh;
        for (const QString &path : paths) {
            if (m_results->rowOf(QUrl::fromLocalFile(path)) < 0)
                fresh.append(path);
        }
        addResults(fresh);
        clearGroupCache();
        invalidate();
        qCDebug(lcFiles) << "recents" << rowCount() << "files in" << m_listTimer.elapsed() << "ms";
        m_loading = false;
        emit loadingChanged();
    });
    connect(loader, &QThread::finished, loader, &QObject::deleteLater);
    loader->start();
}

void FolderModel::stopRecents()
{
    // A load in flight finishes on its own; its result is dropped (generation).
    ++m_recentsGeneration;
    m_recentTimes.clear();
    m_recentsTimer.stop();
    if (m_recentsWatcher)
        m_recentsWatcher->removePaths(m_recentsWatcher->files() + m_recentsWatcher->directories());
}

void FolderModel::setSortKey(int key)
{
    key = qBound(0, key, FileLogic::kSortKeyCount - 1);
    if (key == m_sortKey)
        return;
    m_sortKey = key;
    QElapsedTimer sortTimer;
    sortTimer.start();
    invalidate();
    qCDebug(lcFiles) << "sorted by key" << key << rowCount() << "items in" << sortTimer.elapsed() << "ms";
    emit sortChanged();
}

void FolderModel::setSortDescending(bool descending)
{
    if (descending == m_descending)
        return;
    m_descending = descending;
    invalidate();
    emit sortChanged();
}

void FolderModel::setFoldersFirst(bool on)
{
    if (on == m_foldersFirst)
        return;
    m_foldersFirst = on;
    invalidate();
    emit sortChanged();
}

bool FolderModel::showHidden() const
{
    return m_lister->showHiddenFiles();
}

void FolderModel::setShowHidden(bool on)
{
    if (on == m_lister->showHiddenFiles())
        return;
    m_lister->setShowHiddenFiles(on);
    m_lister->emitChanges();
    emit showHiddenChanged();
}

void FolderModel::setFilterText(const QString &text)
{
    if (text == m_filterText)
        return;
    beginFilterChange();
    m_filterText = text;
    endFilterChange(QSortFilterProxyModel::Direction::Rows);
    emit filterTextChanged();
}

int FolderModel::currentRow() const
{
    return m_current.isEmpty() ? -1 : rowForUrl(m_current);
}

bool FolderModel::writable() const
{
    // Nothing can be created in a trash or a tag search (its items keep their own folders).
    if (isTrash() || isSearch() || isApplications())
        return false;
    const KFileItem root = m_lister->rootItem();
    return !root.isNull() && root.isWritable();
}

QString FolderModel::title() const
{
    if (isApplications())
        return tr("Applications");
    if (isRecents())
        return tr("Recents");
    if (isFileSearch()) {
        // The Finder's "Searching “This Mac”": the scope in the title (F-12: "This Computer").
        const auto query = SearchLogic::fromUrl(m_url);
        if (query && !query->inComputer())
            return tr("Searching “%1”").arg(FileLogic::displayName(QFileInfo(query->folder.toLocalFile()).fileName()));
        return tr("Searching “%1”").arg(tr("This Computer"));
    }
    if (isSearch())
        return TagLogic::displayName(TagLogic::searchTag(m_url));
    const QList<FileLogic::Segment> segments = FileLogic::pathSegments(m_url, QDir::homePath(), tr("Computer"), tr("Trash"));
    return segments.isEmpty() ? m_url.toDisplayString() : segments.last().label;
}

void FolderModel::setPreviewSize(int size)
{
    size = qBound(32, size, 512);
    if (size == m_small.size)
        return;
    m_small.size = size;
    clearPreviews(m_small);
    emit previewSizeChanged();
    if (rowCount() > 0)
        emit dataChanged(index(0, 0), index(rowCount() - 1, 0), {ThumbnailRole});
}

void FolderModel::setLargePreviewSize(int size)
{
    // 1024 px is the largest freedesktop thumbnail cache size (xx-large).
    size = qBound(128, size, 1024);
    if (size == m_large.size)
        return;
    m_large.size = size;
    clearPreviews(m_large);
    emit previewSizeChanged();
    if (rowCount() > 0)
        emit dataChanged(index(0, 0), index(rowCount() - 1, 0), {LargeThumbnailRole});
}

QHash<int, QByteArray> FolderModel::roleNames() const
{
    return {
        {NameRole, "name"},
        {UrlRole, "url"},
        {IconNameRole, "iconName"},
        {IsDirRole, "isDir"},
        {SizeRole, "size"},
        {SizeTextRole, "sizeText"},
        {ModifiedRole, "modified"},
        {ModifiedTextRole, "modifiedText"},
        {KindRole, "kind"},
        {ThumbnailRole, "thumbnail"},
        {SelectedRole, "selected"},
        {HiddenRole, "hidden"},
        {CanPreviewRole, "canPreview"},
        {EmblemRole, "emblem"},
        {LargeThumbnailRole, "largeThumbnail"},
        {TagsRole, "tags"},
        {TagColorsRole, "tagColors"},
        {FolderColorRole, "folderColor"},
        {FolderGlyphRole, "folderGlyph"},
        {GroupRole, "group"},
        {DimmedRole, "dimmed"},
        {CutRole, "cut"},
    };
}

QVariant FolderModel::data(const QModelIndex &index, int role) const
{
    if (role < NameRole)
        return QSortFilterProxyModel::data(index, role);
    const KFileItem item = sourceItem(mapToSource(index));
    if (item.isNull())
        return {};
    if (isApplications()) {
        switch (role) {
        case IconNameRole:
            return applicationIconName(item.iconName());
        case SizeTextRole:
        case ModifiedTextRole:
            return QString();
        case KindRole:
            return tr("Application");
        }
    }
    // Lazy refinement: the lister only guessed the type from the name (setDelayedMimeTypes). A row a
    // view actually shows reads its content once (a few hundred bytes); sorting never does.
    if ((role == IconNameRole || role == KindRole || role == CanPreviewRole) && !item.isMimeTypeKnown())
        item.determineMimeType();
    switch (role) {
    case NameRole:
        return item.text();
    case UrlRole:
        return item.url();
    case IconNameRole:
        return resolvedIconName(item);
    case IsDirRole:
        return item.isDir();
    case SizeRole:
        return item.isDir() ? qint64(-1) : qint64(item.size());
    case SizeTextRole:
        return FileLogic::formatSize(item.isDir() ? -1 : qint64(item.size()));
    case ModifiedRole:
        return item.time(KFileItem::ModificationTime);
    case ModifiedTextRole:
        return FileLogic::formatDate(item.time(KFileItem::ModificationTime), QDateTime::currentDateTime());
    case KindRole:
        return item.mimeComment();
    case ThumbnailRole:
        return thumbnailFor(m_small, item.url());
    case LargeThumbnailRole:
        return thumbnailFor(m_large, item.url());
    case SelectedRole:
        return m_selected.contains(item.url());
    case HiddenRole:
        return item.isHidden();
    case DimmedRole:
        return dimmed(item);
    case CutRole:
        return !m_cut.isEmpty() && m_cut.contains(item.url().adjusted(QUrl::StripTrailingSlash));
    case CanPreviewRole:
        return previewSupported(item);
    case EmblemRole:
        return item.isLink() ? QStringLiteral("emblem-symbolic-link") : QString();
    case TagsRole:
        return TagLogic::displayOrder(tagsOf(item));
    case FolderColorRole:
        return styleOf(item).color;
    case FolderGlyphRole:
        return styleOf(item).glyph;
    case GroupRole:
        return groupFor(item).title;
    case TagColorsRole: {
        QVariantList colors;
        const QList<int> indices = TagLogic::colorIndices(tagsOf(item));
        for (int c : indices)
            colors.append(c);
        return colors;
    }
    }
    return {};
}

KFileItem FolderModel::sourceItem(const QModelIndex &source) const
{
    if (sourceModel() == m_results)
        return m_results->item(source.row());
    return m_dirModel->itemForIndex(source);
}

QModelIndex FolderModel::sourceIndexForUrl(const QUrl &url) const
{
    if (sourceModel() == m_results) {
        const int row = m_results->rowOf(url);
        return row < 0 ? QModelIndex() : m_results->index(row);
    }
    return m_dirModel->indexForUrl(url);
}

QStringList FolderModel::tagsOf(const KFileItem &item) const
{
    const QUrl url = item.url();
    const auto it = m_tags.constFind(url);
    if (it != m_tags.cend())
        return *it;
    // Local items only (trash items have a local path too); links carry no user attributes (TagStore).
    const QString path = item.localPath();
    const QStringList tags = path.isEmpty() || item.isLink() ? QStringList() : TagStore::read(path);
    m_tags.insert(url, tags);
    bool fresh = false;
    for (const QString &tag : tags) {
        if (!m_seenPending.contains(tag)) {
            m_seenPending.insert(tag);
            fresh = true;
        }
    }
    if (fresh && !m_seenTimer.isActive())
        m_seenTimer.start();
    return tags;
}

FolderStyleLogic::Style FolderModel::styleOf(const KFileItem &item) const
{
    if (!m_styleStore || !item.isDir() || item.isLink())
        return {};
    const QUrl url = item.url();
    const auto it = m_styles.constFind(url);
    if (it != m_styles.cend())
        return *it;
    const QString path = item.localPath();
    const FolderStyleLogic::Style style = path.isEmpty() ? FolderStyleLogic::Style() : m_styleStore->read(path);
    m_styles.insert(url, style);
    return style;
}

void FolderModel::watchShownFolder()
{
    const QStringList old = m_attrWatcher.directories();
    if (!old.isEmpty())
        m_attrWatcher.removePaths(old);
    m_attrTimer.stop();
    m_attrBurst.invalidate();
    // A local folder only (a watch on a network mount is KIO's business), and only when looks are shown at all.
    if (m_styleStore && m_url.isLocalFile() && !TagLogic::isSearchUrl(m_url))
        m_attrWatcher.addPath(m_url.toLocalFile());
}

// The rows whose look was read: read again, and only the ones that changed are announced.
void FolderModel::revalidateStyles()
{
    if (!m_styleStore)
        return;
    for (auto it = m_styles.begin(); it != m_styles.end(); ++it) {
        const FolderStyleLogic::Style now = m_styleStore->read(it.key().toLocalFile());
        if (now != *it) {
            *it = now;
            emitRowChanged(it.key(), {FolderColorRole, FolderGlyphRole});
        }
    }
}

void FolderModel::folderStylesChanged(const QList<QUrl> &urls)
{
    for (const QUrl &url : urls) {
        m_styles.remove(url);
        emitRowChanged(url, {FolderColorRole, FolderGlyphRole});
    }
}

void FolderModel::allFolderStylesChanged()
{
    m_styles.clear();
    if (rowCount() > 0)
        emit dataChanged(index(0, 0), index(rowCount() - 1, 0), {FolderColorRole, FolderGlyphRole});
}

void FolderModel::dropTags(const QUrl &url)
{
    if (m_styles.remove(url))
        emitRowChanged(url, {FolderColorRole, FolderGlyphRole});
    if (m_tags.remove(url))
        emitRowChanged(url, {TagsRole, TagColorsRole});
}

void FolderModel::emitRowChanged(const QUrl &url, const QList<int> &roles)
{
    const int r = rowForUrl(url);
    if (r >= 0)
        emit dataChanged(index(r, 0), index(r, 0), roles);
}

void FolderModel::tagsChanged(const QList<QUrl> &urls)
{
    const QString tag = TagLogic::searchTag(m_url);
    const QUrl folder = TagLogic::searchFolder(m_url);
    QList<QUrl> gone;
    QStringList joined;
    for (const QUrl &url : urls) {
        m_tags.remove(url);
        m_styles.remove(url);
        // Only a tag search's rows depend on tags; Recents lists its files whatever their tags, and a search shows what
        // its Tags rows matched when it ran (Reload asks again).
        if (!isSearch() || isRecents() || isFileSearch()) {
            emitRowChanged(url, {TagsRole, TagColorsRole});
            continue;
        }
        // A tag search follows the changes made in Files: an item that lost the tag leaves it, a local item in the
        // searched folder that got it joins it.
        const bool listed = m_results->rowOf(url) >= 0;
        const bool matches = url.isLocalFile() && TagLogic::hasTag(TagStore::read(url.toLocalFile()), tag);
        if (listed && !matches)
            gone.append(url);
        else if (!listed && matches && (folder == url || folder.isParentOf(url)))
            joined.append(url.toLocalFile());
        else
            emitRowChanged(url, {TagsRole, TagColorsRole});
    }
    if (!gone.isEmpty())
        removeResults(gone);
    if (!joined.isEmpty())
        addResults(joined);
    // Tags are read by the proxy, not its source: a sort or grouping by tags is redone here.
    if (m_sortKey == int(FileLogic::SortKey::Tags) || m_groupBy == int(FileLogic::GroupBy::Tags)) {
        for (const QUrl &url : urls)
            m_groupCache.remove(url);
        invalidate();
    }
}

FileLogic::SortEntry FolderModel::sortEntry(const KFileItem &item, FileLogic::SortKey key) const
{
    using FileLogic::GroupBy;
    using FileLogic::SortKey;
    const auto by = GroupBy(m_groupBy);
    FileLogic::SortEntry e;
    e.name = item.text();
    e.isDir = item.isDir();
    const bool typed = key == SortKey::Kind || key == SortKey::Application || by == GroupBy::Kind || by == GroupBy::Application;
    if (typed && !e.isDir) {
        const MimeFacts facts = mimeFacts(mimeNameOf(item));
        e.kind = facts.comment;
        e.mimeTypes = facts.lineage;
        e.application = facts.application;
    } else if (key == SortKey::Kind) {
        e.kind = item.mimeComment();
    }
    if (key == SortKey::Date || by == GroupBy::Modified)
        e.modified = item.time(KFileItem::ModificationTime);
    if (key == SortKey::Created || by == GroupBy::Created)
        e.created = item.time(KFileItem::CreationTime);
    if (key == SortKey::Opened || by == GroupBy::Opened)
        e.opened = isRecents() ? m_recentTimes.value(item.url()) : item.time(KFileItem::AccessTime);
    if (key == SortKey::Size || by == GroupBy::Size)
        e.size = e.isDir ? -1 : qint64(item.size());
    if (key == SortKey::Tags || by == GroupBy::Tags)
        e.tags = TagLogic::displayOrder(tagsOf(item));
    return e;
}

FileLogic::Group FolderModel::groupFor(const KFileItem &item) const
{
    if (m_groupBy == 0)
        return {};
    const QUrl url = item.url();
    const auto it = m_groupCache.constFind(url);
    if (it != m_groupCache.cend())
        return *it;
    if (!m_groupClock.isValid() || m_groupClock.elapsed() > 60000) {
        m_groupNow = QDateTime::currentDateTime();
        m_groupClock.restart();
        if (!m_groupDay.isValid()) {
            m_groupDay = m_groupNow.date();
        } else if (m_groupNow.date() != m_groupDay && !m_newDayQueued) {
            // Not now: this may be in the middle of a sort.
            m_newDayQueued = true;
            QTimer::singleShot(0, const_cast<FolderModel *>(this), &FolderModel::regroupForNewDay);
        }
    }
    const FileLogic::Group g = FileLogic::groupOf(sortEntry(item, FileLogic::SortKey::Name), FileLogic::GroupBy(m_groupBy), m_groupNow);
    m_groupCache.insert(url, g);
    return g;
}

void FolderModel::groupsDirty()
{
    m_groupsValid = false;
    if (m_groupsNotifyQueued || m_groupBy == 0)
        return;
    m_groupsNotifyQueued = true;
    QTimer::singleShot(0, this, [this] {
        m_groupsNotifyQueued = false;
        emit groupsChanged();
    });
}

void FolderModel::clearGroupCache()
{
    m_groupCache.clear();
    m_groupDay = QDate();
}

void FolderModel::regroupForNewDay()
{
    m_newDayQueued = false;
    if (m_groupBy == 0)
        return;
    clearGroupCache();
    m_groupClock.invalidate();
    armDayTimer();
    // Sorted again: the layout change marks the groups dirty.
    invalidate();
}

void FolderModel::armDayTimer()
{
    if (m_groupBy == 0) {
        m_dayTimer.stop();
        return;
    }
    const QDateTime now = QDateTime::currentDateTime();
    // A second past midnight (a timer may fire a little early); a suspended machine is caught by groupFor on wake.
    m_dayTimer.start(int(qMax<qint64>(1000, now.msecsTo(QDateTime(now.date().addDays(1), QTime(0, 0))) + 1000)));
}

QVariantList FolderModel::groups() const
{
    if (m_groupsValid)
        return m_groups;
    m_groups.clear();
    m_groupsValid = true;
    if (m_groupBy == 0)
        return m_groups;
    const int n = rowCount();
    QString title;
    int first = 0;
    for (int row = 0; row < n; row++) {
        const QString t = groupFor(sourceItem(mapToSource(index(row, 0)))).title;
        if (row > 0 && t != title) {
            m_groups.append(QVariantMap{{QStringLiteral("title"), title}, {QStringLiteral("first"), first}, {QStringLiteral("count"), row - first}});
            first = row;
        }
        title = t;
    }
    if (n > 0)
        m_groups.append(QVariantMap{{QStringLiteral("title"), title}, {QStringLiteral("first"), first}, {QStringLiteral("count"), n - first}});
    return m_groups;
}

void FolderModel::setGroupBy(int by)
{
    by = qBound(0, by, FileLogic::kGroupByCount - 1);
    if (by == m_groupBy)
        return;
    m_groupBy = by;
    clearGroupCache();
    armDayTimer();
    m_groupsValid = false;
    invalidate();
    emit sortChanged();
    emit groupsChanged();
}

bool FolderModel::lessThan(const QModelIndex &left, const QModelIndex &right) const
{
    const KFileItem a = sourceItem(left);
    const KFileItem b = sourceItem(right);
    if (m_groupBy != 0) {
        // Groups first, in their own order whatever the sort direction (Finder).
        const int g = FileLogic::compareGroups(groupFor(a), groupFor(b), m_collator);
        if (g != 0)
            return g < 0;
    }
    const auto key = FileLogic::SortKey(m_sortKey);
    return FileLogic::compareEntries(sortEntry(a, key), sortEntry(b, key), key, m_descending, m_foldersFirst, m_collator) < 0;
}

bool FolderModel::filterAcceptsRow(int sourceRow, const QModelIndex &sourceParent) const
{
    const KFileItem item = sourceItem(sourceModel()->index(sourceRow, 0, sourceParent));
    // Only remote:/ entries can be hidden; the target is looked up for those alone.
    if (item.url().scheme() == QLatin1String("remote") && FileLogic::hiddenNetworkEntry(item.url(), item.targetUrl()))
        return false;
    if (m_filterText.isEmpty())
        return true;
    return FileLogic::nameMatchesFilter(item.text(), m_filterText);
}

void FolderModel::select(int row, int modifiers, bool pointer)
{
    // A panel that takes one item: a click with Shift or Ctrl is a plain click.
    if (m_chooserSingle)
        modifiers = 0;
    const QUrl url = urlAt(row);
    qCDebug(lcFiles) << "select" << row << url.fileName() << "modifiers" << modifiers;
    if (url.isEmpty())
        return;
    dropAloneWish();
    QSet<QUrl> next = m_selected;
    if (modifiers & Qt::ShiftModifier) {
        int anchorRow = rowForUrl(m_anchor);
        if (anchorRow < 0) {
            anchorRow = row;
            m_anchor = url;
        }
        if (!(modifiers & Qt::ControlModifier))
            next.clear();
        for (int r = qMin(row, anchorRow); r <= qMax(row, anchorRow); ++r)
            next.insert(urlAt(r));
    } else if (modifiers & Qt::ControlModifier) {
        if (!next.remove(url))
            next.insert(url);
        m_anchor = url;
    } else {
        // A click on a panel's dimmed item does nothing (macOS: a disabled item takes no click; integrator nested pass of
        // f9a25ce, NIT: it cleared the preselected application). A key that lands there selects nothing, as before: no
        // selection left out of sight for Return to take (review of step 5c, MINOR 2).
        if (pointer && !m_chooser.isEmpty() && dimmed(itemAt(row)))
            return;
        next = {url};
        m_anchor = url;
    }
    applySelection(next);
    setCurrent(url);
}

void FolderModel::selectAll()
{
    if (m_chooserSingle)
        return;
    dropAloneWish();
    QSet<QUrl> next;
    for (int r = 0; r < rowCount(); ++r)
        next.insert(urlAt(r));
    applySelection(next);
}

void FolderModel::clearSelection()
{
    dropAloneWish();
    applySelection({});
}

void FolderModel::selectUrls(const QList<QUrl> &urls)
{
    dropAloneWish();
    QSet<QUrl> next;
    for (const QUrl &u : urls) {
        if (rowForUrl(u) >= 0 && !(m_chooserSingle && !next.isEmpty()))
            next.insert(u);
    }
    applySelection(next);
    if (!urls.isEmpty()) {
        m_anchor = urls.first();
        setCurrent(urls.first());
    }
}

QList<QUrl> FolderModel::selectedUrls() const
{
    QList<QUrl> out;
    for (int r : selectedRows())
        out.append(urlAt(r));
    return out;
}

bool FolderModel::isSelected(int row) const
{
    return m_selected.contains(urlAt(row));
}

QList<int> FolderModel::selectedRows() const
{
    QList<int> rows;
    rows.reserve(m_selected.size());
    for (const QUrl &u : m_selected) {
        const int r = rowForUrl(u);
        if (r >= 0)
            rows.append(r);
    }
    std::sort(rows.begin(), rows.end());
    return rows;
}

void FolderModel::setChooser(const QVariantMap &chooser)
{
    if (chooser == m_chooser)
        return;
    m_chooser = chooser;
    m_chooserGlobs = chooser.value(QStringLiteral("globs")).toStringList();
    m_chooserMimeTypes = chooser.value(QStringLiteral("mimeTypes")).toStringList();
    m_chooserFoldersOnly = chooser.value(QStringLiteral("foldersOnly")).toBool();
    m_chooserSingle = chooser.value(QStringLiteral("single")).toBool();
    const QStringList applications = chooser.value(QStringLiteral("applications")).toStringList();
    m_chooserApplications = QSet<QString>(applications.cbegin(), applications.cend());
    m_chooserAllApplications = chooser.value(QStringLiteral("allApplications")).toBool();
    const QStringList listed = chooser.value(QStringLiteral("listed")).toStringList();
    const QSet<QString> nextListed(listed.cbegin(), listed.cend());
    if (nextListed != m_chooserListed) {
        m_chooserListed = nextListed;
        // The Applications location lists them too (a listing made before the panel named them is made again).
        if (isApplications())
            loadApplications();
    }
    if (rowCount() > 0)
        emit dataChanged(index(0, 0), index(rowCount() - 1, 0), {DimmedRole});
    // What the panel can no longer take leaves the selection.
    applySelection(m_selected);
    emit chooserChanged();
}

bool FolderModel::dimmed(const KFileItem &item) const
{
    if (m_chooser.isEmpty() || item.isNull())
        return false;
    // An application of the Applications location is a launcher, not a file an application can open; Choose Application takes
    // the applications it names, or every one.
    if (isApplications())
        return !m_chooserAllApplications && !m_chooserApplications.contains(ApplicationsLogic::entryId(item.url()));
    if (item.isDir())
        return false;
    if (m_chooserFoldersOnly)
        return true;
    if (m_chooserGlobs.isEmpty() && m_chooserMimeTypes.isEmpty())
        return false;
    QStringList types;
    if (!m_chooserMimeTypes.isEmpty()) {
        const QMimeType type = item.currentMimeType();
        types = QStringList{type.name()} + type.allAncestors();
    }
    return !FileLogic::passesFilter(item.text(), types, m_chooserGlobs, m_chooserMimeTypes);
}

void FolderModel::applySelection(QSet<QUrl> next)
{
    if (!m_chooser.isEmpty()) {
        for (auto it = next.begin(); it != next.end();) {
            const int row = rowForUrl(*it);
            it = row >= 0 && dimmed(itemAt(row)) ? next.erase(it) : std::next(it);
        }
        if (m_chooserSingle && next.size() > 1) {
            const QUrl keep = next.contains(m_current) ? m_current : *next.cbegin();
            next = {keep};
        }
    }
    if (next == m_selected)
        return;
    QSet<QUrl> changed = m_selected;
    changed.unite(next);
    changed.subtract(QSet<QUrl>(m_selected).intersect(next));
    m_selected = next;
    qCDebug(lcFiles) << "selection" << m_selected.size() << "changed" << changed.size();
    if (changed.size() > kSelectionBulkThreshold) {
        if (rowCount() > 0)
            emit dataChanged(index(0, 0), index(rowCount() - 1, 0), {SelectedRole});
    } else {
        for (const QUrl &u : std::as_const(changed)) {
            const int r = rowForUrl(u);
            if (r >= 0)
                emit dataChanged(index(r, 0), index(r, 0), {SelectedRole});
        }
    }
    emit selectionChanged();
}

void FolderModel::setCurrent(const QUrl &url)
{
    if (url == m_current)
        return;
    m_current = url;
    emit currentRowChanged();
}

KFileItem FolderModel::itemAt(int row) const
{
    if (row < 0 || row >= rowCount())
        return KFileItem();
    return sourceItem(mapToSource(index(row, 0)));
}

KFileItem FolderModel::rootItem() const
{
    // A tag search or a search stands for its folder (Get Info without a selection).
    if (isSearch() && !isRecents())
        return KFileItem(searchBase());
    return m_lister->rootItem();
}

QUrl FolderModel::urlAt(int row) const
{
    const KFileItem item = itemAt(row);
    return item.isNull() ? QUrl() : item.url();
}

QString FolderModel::nameAt(int row) const
{
    const KFileItem item = itemAt(row);
    return item.isNull() ? QString() : item.text();
}

bool FolderModel::isDirAt(int row) const
{
    const KFileItem item = itemAt(row);
    return !item.isNull() && item.isDir();
}

int FolderModel::rowForUrl(const QUrl &url) const
{
    if (url.isEmpty())
        return -1;
    const QModelIndex source = sourceIndexForUrl(url);
    if (!source.isValid())
        return -1;
    const QModelIndex proxy = mapFromSource(source);
    return proxy.isValid() ? proxy.row() : -1;
}

int FolderModel::findPrefix(const QString &prefix, int from) const
{
    const int n = rowCount();
    if (prefix.isEmpty() || n == 0)
        return -1;
    from = qBound(0, from, n - 1);
    for (int i = 0; i < n; ++i) {
        const int r = (from + i) % n;
        if (nameAt(r).startsWith(prefix, Qt::CaseInsensitive))
            return r;
    }
    return -1;
}

QVariantMap FolderModel::info(int row) const
{
    if (isApplications()) {
        QVariantMap a;
        if (row < 0) {
            a[QStringLiteral("name")] = title();
            a[QStringLiteral("url")] = m_url;
            a[QStringLiteral("iconName")] = QStringLiteral("folder");
            a[QStringLiteral("thumbnail")] = QString();
            a[QStringLiteral("kind")] = tr("Applications");
            a[QStringLiteral("isDir")] = true;
            a[QStringLiteral("readable")] = true;
            a[QStringLiteral("writable")] = false;
            return a;
        }
        const KFileItem shown = itemAt(row);
        const auto it = m_apps.constFind(shown.url());
        if (shown.isNull() || it == m_apps.cend())
            return a;
        a[QStringLiteral("name")] = it->name;
        a[QStringLiteral("url")] = shown.url();
        a[QStringLiteral("iconName")] = applicationIconName(it->icon);
        a[QStringLiteral("thumbnail")] = QString();
        a[QStringLiteral("kind")] = tr("Application");
        a[QStringLiteral("isApplication")] = true;
        a[QStringLiteral("genericName")] = it->genericName;
        a[QStringLiteral("comment")] = it->comment;
        a[QStringLiteral("where")] = QFileInfo(it->path).absolutePath();
        a[QStringLiteral("desktopEntry")] = it->path;
        a[QStringLiteral("command")] = it->exec;
        a[QStringLiteral("categories")] = it->categories.join(QStringLiteral(", "));
        a[QStringLiteral("readable")] = true;
        a[QStringLiteral("writable")] = false;
        a[QStringLiteral("isDir")] = false;
        a[QStringLiteral("size")] = qint64(-1);
        return a;
    }
    const KFileItem item = row < 0 ? rootItem() : itemAt(row);
    QVariantMap m;
    if (item.isNull())
        return m;
    const QDateTime now = QDateTime::currentDateTime();
    const qint64 size = item.isDir() ? -1 : qint64(item.size());
    // A folder's own info carries its title ("Computer", "Trash", the home folder's name); a tag search shows its folder.
    m[QStringLiteral("name")] = row < 0 && !isSearch() ? title() : item.text();
    m[QStringLiteral("url")] = item.url();
    m[QStringLiteral("iconName")] = resolvedIconName(item);
    m[QStringLiteral("thumbnail")] = thumbnailFor(m_small, item.url());
    m[QStringLiteral("largeThumbnail")] = thumbnailFor(m_large, item.url());
    m[QStringLiteral("kind")] = item.mimeComment();
    m[QStringLiteral("mimeType")] = item.mimetype();
    m[QStringLiteral("isDir")] = item.isDir();
    m[QStringLiteral("size")] = size;
    m[QStringLiteral("sizeText")] = FileLogic::formatSize(size);
    m[QStringLiteral("bytes")] = QLocale().toString(size);
    const QUrl parent = item.url().adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash);
    m[QStringLiteral("where")] = parent.isLocalFile() ? parent.toLocalFile() : parent.toDisplayString();
    m[QStringLiteral("created")] = FileLogic::formatDate(item.time(KFileItem::CreationTime), now);
    m[QStringLiteral("modified")] = FileLogic::formatDate(item.time(KFileItem::ModificationTime), now);
    m[QStringLiteral("accessed")] = FileLogic::formatDate(item.time(KFileItem::AccessTime), now);
    m[QStringLiteral("permissions")] = item.permissionsString();
    m[QStringLiteral("owner")] = item.user();
    m[QStringLiteral("group")] = item.group();
    m[QStringLiteral("readable")] = item.isReadable();
    m[QStringLiteral("writable")] = item.isWritable();
    m[QStringLiteral("linkDest")] = item.isLink() ? item.linkDest() : QString();
    // Tags in display order, by their shown names, and the colour dots.
    const QStringList tags = TagLogic::displayOrder(tagsOf(item));
    QStringList names;
    for (const QString &tag : tags)
        names.append(TagLogic::displayName(tag));
    m[QStringLiteral("tags")] = names;
    m[QStringLiteral("tagKeys")] = tags;
    QVariantList colors;
    const QList<int> indices = TagLogic::colorIndices(tags);
    for (int c : indices)
        colors.append(c);
    m[QStringLiteral("tagColors")] = colors;
    const FolderStyleLogic::Style style = styleOf(item);
    m[QStringLiteral("folderColor")] = style.color;
    m[QStringLiteral("folderGlyph")] = style.glyph;
    return m;
}

QString FolderModel::dimensionsAt(int row)
{
    const KFileItem item = itemAt(row);
    // What the listing already knows decides, nothing is looked at here: a local regular file (the listing's mode, links
    // followed) whose type says picture. ImageSize::check() looks again on the worker before anything is opened.
    if (item.isNull() || !item.isLocalFile() || item.isDir() || !item.isRegularFile() || !item.currentMimeType().name().startsWith(QLatin1String("image/")))
        return QString();
    const QString path = item.localPath();
    if (path.isEmpty())
        return QString();
    const QDateTime modified = item.time(KFileItem::ModificationTime);
    const qint64 size = qint64(item.size());
    const auto it = m_dimensions.constFind(path);
    if (it != m_dimensions.cend() && it->modified == modified && it->size == size)
        return it->pending || !it->pixels.isValid() ? QString() : tr("%1 × %2").arg(it->pixels.width()).arg(it->pixels.height());
    if (m_dimensions.size() >= kMaxDimensions)
        m_dimensions.clear();
    m_dimensions.insert(path, {item.url(), modified, size, true, QSize()});
    if (!m_sizeReader)
        m_sizeReader = std::make_unique<ImageSize::Reader>(this, [this](const QString &p, QSize pixels) { dimensionsReady(p, pixels); });
    m_sizeReader->request(path);
    return QString();
}

void FolderModel::dimensionsReady(const QString &path, QSize pixels)
{
    const auto it = m_dimensions.find(path);
    // Dropped meanwhile (another folder, the cache full): a later dimensionsAt asks again.
    if (it == m_dimensions.end() || !it->pending)
        return;
    it->pending = false;
    it->pixels = pixels;
    // A file changed while it was read is asked again by the next dimensionsAt (its time or size no longer match).
    const int r = rowForUrl(it->url);
    if (r >= 0)
        emit dataChanged(index(r, 0), index(r, 0), {DimensionsRole});
}

void FolderModel::requestPreview(int row, bool large)
{
    const KFileItem item = itemAt(row);
    if (item.isNull() || !previewSupported(item))
        return;
    ThumbChannel &c = large ? m_large : m_small;
    if (c.queue.request(item.url()) && !c.timer.isActive())
        c.timer.start();
}

void FolderModel::cancelPreview(const QUrl &url, bool large)
{
    (large ? m_large : m_small).queue.cancel(url);
}

void FolderModel::startPreviews(ThumbChannel &c)
{
    if (c.job || c.queue.isEmpty())
        return;
    KFileItemList batch;
    const QList<QUrl> urls = c.queue.takeBatch(kPreviewBatchSize);
    for (const QUrl &url : urls) {
        const KFileItem item = itemAt(rowForUrl(url));
        if (item.isNull())
            c.queue.forget(url);
        else
            batch.append(item);
    }
    ThumbChannel *channel = &c;
    if (batch.isEmpty()) {
        if (!c.queue.isEmpty())
            QTimer::singleShot(0, this, [this, channel] { startPreviews(*channel); });
        return;
    }
    auto *job = KIO::filePreview(batch, QSize(c.size, c.size), &previewPlugins());
    c.job = job;
    connect(job, &KIO::PreviewJob::generated, this, [this, channel](const KFileItem &item, const QImage &image) {
        if (image.isNull())
            return;
        ThumbChannel &c = *channel;
        const QUrl url = item.url();
        qCDebug(lcFiles) << "thumbnail" << item.name() << c.size << "px, stored" << c.thumbs.size() + 1;
        const QString old = c.thumbs.value(url);
        if (!old.isEmpty())
            ThumbnailStore::remove(old);
        c.thumbs.insert(url, ThumbnailStore::insert(image));
        const int r = rowForUrl(url);
        if (r >= 0)
            emit dataChanged(index(r, 0), index(r, 0), {c.role});
        // Least recently loaded thumbnails go first; they may be asked for again when shown.
        const QList<QUrl> evicted = c.lru.add(url);
        for (const QUrl &gone : evicted)
            forgetThumbnail(c, gone, false);
    });
    connect(job, &KJob::result, this, [this, channel] {
        // The finished job is only deleteLater()'d: release the slot now so the next batch can start.
        channel->job.clear();
        if (!channel->queue.isEmpty())
            QTimer::singleShot(0, this, [this, channel] { startPreviews(*channel); });
    });
}

void FolderModel::forgetThumbnail(ThumbChannel &c, const QUrl &url, bool again)
{
    const QString key = c.thumbs.take(url);
    if (!key.isEmpty())
        ThumbnailStore::remove(key);
    c.lru.remove(url);
    const bool wasAsked = c.queue.asked(url);
    c.queue.cancel(url);
    c.queue.forget(url);
    const int r = rowForUrl(url);
    if (again && wasAsked && r >= 0) {
        // The delegate keeps showing the old picture until the new one replaces it (no flicker).
        requestPreview(r, &c == &m_large);
    } else if (r >= 0 && !key.isEmpty()) {
        emit dataChanged(index(r, 0), index(r, 0), {c.role});
    }
}

void FolderModel::clearPreviews(ThumbChannel &c)
{
    c.timer.stop();
    if (c.job) {
        c.job->kill(KJob::Quietly);
        c.job.clear();
    }
    for (const QString &key : std::as_const(c.thumbs))
        ThumbnailStore::remove(key);
    c.thumbs.clear();
    c.lru.clear();
    c.queue.clear();
}

void FolderModel::clearAllPreviews()
{
    clearPreviews(m_small);
    clearPreviews(m_large);
}

QString FolderModel::thumbnailFor(const ThumbChannel &c, const QUrl &url) const
{
    const QString key = c.thumbs.value(url);
    return key.isEmpty() ? QString() : QStringLiteral("image://thumbnail/") + key;
}

bool FolderModel::previewSupported(const KFileItem &item) const
{
    if (item.isNull() || item.isDir() || item.size() == 0)
        return false;
    const PreviewMimes &mimes = previewMimes();
    const QMimeType type = item.currentMimeType();
    QStringList names = {type.name()};
    names += type.allAncestors();
    for (const QString &name : std::as_const(names)) {
        if (mimes.exact.contains(name))
            return true;
        for (const QString &prefix : mimes.prefixes) {
            if (name.startsWith(prefix))
                return true;
        }
    }
    return false;
}

void FolderModel::reload()
{
    m_tags.clear();
    if (isApplications()) {
        loadApplications();
        return;
    }
    if (isSearch()) {
        clearAllPreviews();
        stopSearch();
        applySelection({});
        m_current.clear();
        m_results->clear();
        startSearch();
        return;
    }
    // Thumbnails stay: KIO refreshes the rows of a listed folder in place (the delegates are not recreated and would
    // not ask again), and refreshItems renews the thumbnails of the files that changed. Tags are read again.
    if (rowCount() > 0)
        emit dataChanged(index(0, 0), index(rowCount() - 1, 0), {TagsRole, TagColorsRole});
    m_styles.clear();
    m_dirModel->openUrl(m_url, KDirModel::Reload);
}

void FolderModel::loadApplications()
{
    const quint64 generation = ++m_appsGeneration;
    if (!m_loading && m_apps.isEmpty()) {
        m_loading = true;
        emit loadingChanged();
    }
    QPointer<FolderModel> self(this);
    ApplicationsLogic::Environment env = ApplicationsLogic::processEnvironment();
    env.alsoListed = m_chooserListed;
    ApplicationsLogic::startListing(env, [self, generation](const QList<ApplicationsLogic::Entry> &entries) {
        if (self && generation == self->m_appsGeneration && self->isApplications())
            self->applyApplications(entries);
    });
}

void FolderModel::applyApplications(const QList<ApplicationsLogic::Entry> &entries)
{
    // The location's own list (Get Info's count, Copy, the name of a launch failure): never a Choose Application panel's,
    // which adds the candidates the grid hides (review of fac5bff3: Get Info counted imv once a panel had listed it).
    if (m_chooserListed.isEmpty()) {
        QVariantMap paths, names;
        for (const ApplicationsLogic::Entry &e : entries) {
            paths.insert(e.id, e.path);
            names.insert(e.id, e.name);
        }
        emit applicationsListed(paths, names);
    }
    // Rows that stay keep their selection; the others go.
    QHash<QUrl, ApplicationsLogic::Entry> next;
    KFileItemList items;
    for (const ApplicationsLogic::Entry &e : entries) {
        const QUrl url = ApplicationsLogic::entryUrl(e.id);
        KIO::UDSEntry entry;
        entry.fastInsert(KIO::UDSEntry::UDS_NAME, e.id);
        entry.fastInsert(KIO::UDSEntry::UDS_DISPLAY_NAME, e.name);
        entry.fastInsert(KIO::UDSEntry::UDS_ICON_NAME, e.icon);
        entry.fastInsert(KIO::UDSEntry::UDS_FILE_TYPE, S_IFREG);
        entry.fastInsert(KIO::UDSEntry::UDS_ACCESS, 0444);
        entry.fastInsert(KIO::UDSEntry::UDS_SIZE, 0);
        entry.fastInsert(KIO::UDSEntry::UDS_MIME_TYPE, QStringLiteral("application/x-desktop"));
        items.append(KFileItem(entry, url, true, false));
        next.insert(url, e);
    }
    m_apps = next;
    m_results->clear();
    m_results->append(items);
    // A selected row that is gone leaves the selection.
    QSet<QUrl> keep;
    for (const QUrl &url : std::as_const(m_selected)) {
        if (next.contains(url))
            keep.insert(url);
    }
    if (keep != m_selected)
        applySelection(keep);
    if (m_loading) {
        m_loading = false;
        emit loadingChanged();
    }
    emit countChanged();
}

// New and removed applications show without a reload (a package installed while the window is open).
void FolderModel::watchApplications()
{
    const QStringList old = m_appsWatcher.directories();
    if (!old.isEmpty())
        m_appsWatcher.removePaths(old);
    m_appsTimer.stop();
    if (!isApplications())
        return;
    for (const QString &dir : ApplicationsLogic::processEnvironment().applicationDirs) {
        if (QDir(dir).exists())
            m_appsWatcher.addPath(dir);
    }
}

void FolderModel::startSearch()
{
    if (isFileSearch()) {
        startFileSearch();
        return;
    }
    const QString tag = TagLogic::searchTag(m_url);
    const QUrl folder = TagLogic::searchFolder(m_url);
    m_searchLimited = false;
    if (!folder.isLocalFile()) {
        // FilesApp only builds searches of local folders; a typed location may name anything.
        setError(tr("Tags are only searched in local folders."));
        m_loading = false;
        emit loadingChanged();
        return;
    }
    watchChanges();
    m_listTimer.start();
    m_loading = true;
    emit loadingChanged();
    m_search->start(folder.toLocalFile(), tag, showHidden());
}

void FolderModel::startFileSearch()
{
    m_searchLimited = false;
    m_searchContentsUnavailable = false;
    const auto query = SearchLogic::fromUrl(m_url);
    if (!query) {
        setError(tr("This search can’t be read."));
        m_loading = false;
        emit loadingChanged();
        return;
    }
    if (!SearchLogic::hasTerms(*query)) {
        // Nothing asked yet (a new smart folder, a cleared field with no rows): nothing listed.
        m_loading = false;
        emit loadingChanged();
        return;
    }
    const QUrl base = searchBase();
    if (!QFileInfo(base.toLocalFile()).isDir()) {
        setError(tr("The folder of this search can’t be found."));
        m_loading = false;
        emit loadingChanged();
        return;
    }
    FileSearch::Settings settings;
    settings.query = *query;
    settings.root = base.toLocalFile();
    settings.showHidden = showHidden();
    settings.localsearch = QStandardPaths::findExecutable(QStringLiteral("localsearch"));
    settings.plocate = QStandardPaths::findExecutable(QStringLiteral("plocate"));
    settings.plocateDb = grassfield::apps::runmode::devValue("SEARCH_PLOCATE_DB");
    watchChanges();
    m_listTimer.start();
    m_loading = true;
    emit loadingChanged();
    m_fileSearch->start(settings);
}

void FolderModel::stopSearch()
{
    m_search->stop();
    m_fileSearch->stop();
}

void FolderModel::watchChanges()
{
    if (m_notify)
        return;
    // KIO announces every change made through it (this app's jobs and other KIO applications') on the session bus.
    m_notify = new OrgKdeKDirNotifyInterface(QString(), QString(), QDBusConnection::sessionBus(), this);
    connect(m_notify, &OrgKdeKDirNotifyInterface::FileRenamedWithLocalPath, this, [this](const QString &src, const QString &dst, const QString &) {
        if (isSearch())
            renameResult(QUrl(src), QUrl(dst));
    });
    connect(m_notify, &OrgKdeKDirNotifyInterface::FileRenamed, this, [this](const QString &src, const QString &dst) {
        if (isSearch())
            renameResult(QUrl(src), QUrl(dst));
    });
    connect(m_notify, &OrgKdeKDirNotifyInterface::FileMoved, this, [this](const QString &src, const QString &dst) {
        if (isSearch())
            renameResult(QUrl(src), QUrl(dst));
    });
    connect(m_notify, &OrgKdeKDirNotifyInterface::FilesRemoved, this, [this](const QStringList &files) {
        if (!isSearch())
            return;
        QList<QUrl> urls;
        for (const QString &f : files)
            urls.append(QUrl(f));
        removeResults(urls);
    });
    connect(m_notify, &OrgKdeKDirNotifyInterface::FilesChanged, this, [this](const QStringList &files) {
        if (!isSearch())
            return;
        for (const QString &f : files) {
            const QUrl url(f);
            if (m_results->rowOf(url) < 0)
                continue;
            m_results->replace(url, KFileItem(url, KFileItem::SkipMimeTypeFromContent));
            forgetThumbnail(m_small, url, true);
            forgetThumbnail(m_large, url, true);
            dropTags(url);
        }
    });
}

void FolderModel::addResults(const QStringList &paths)
{
    KFileItemList items;
    items.reserve(paths.size());
    for (const QString &path : paths) {
        // The type is guessed from the name here; rows that are shown refine it from content (data()).
        const KFileItem item(QUrl::fromLocalFile(path), KFileItem::SkipMimeTypeFromContent);
        if (!item.isNull())
            items.append(item);
    }
    m_results->append(items);
}

void FolderModel::removeResults(const QList<QUrl> &urls)
{
    bool selectionTouched = false;
    for (const QUrl &url : urls) {
        if (m_results->rowOf(url) < 0)
            continue;
        selectionTouched |= m_selected.remove(url);
        if (url == m_current)
            m_current.clear();
        forgetThumbnail(m_small, url, false);
        forgetThumbnail(m_large, url, false);
        m_tags.remove(url);
        m_styles.remove(url);
        m_results->remove(url);
    }
    if (selectionTouched)
        emit selectionChanged();
}

void FolderModel::renameResult(const QUrl &from, const QUrl &to)
{
    if (m_results->rowOf(from) < 0)
        return;
    if (isRecents()) {
        // Still a recent file under its new name; to the Trash, it leaves Recents.
        if (!to.isLocalFile()) {
            removeResults({from});
            return;
        }
        Recents::noteRenamed(from.toLocalFile(), to.toLocalFile());
        m_recentTimes.insert(to, m_recentTimes.take(from));
    } else {
        // Moved out of the searched folder (or to the Trash): it leaves the results.
        const QUrl folder = searchBase();
        if (!to.isLocalFile() || !(folder == to || folder.isParentOf(to))) {
            removeResults({from});
            return;
        }
    }
    const bool selected = m_selected.remove(from);
    m_groupCache.remove(from);
    forgetThumbnail(m_small, from, false);
    forgetThumbnail(m_large, from, false);
    m_tags.remove(from);
    m_styles.remove(from);
    m_results->replace(from, KFileItem(to, KFileItem::SkipMimeTypeFromContent));
    if (selected)
        m_selected.insert(to);
    if (m_current == from)
        m_current = to;
    if (m_anchor == from)
        m_anchor = to;
    if (selected)
        emit selectionChanged();
}

void FolderModel::refreshFreeSpace()
{
    if (m_freeSpaceJob)
        return;
    QUrl target = m_url;
    if (isTrash())
        target = QUrl::fromLocalFile(QDir::homePath());
    if (!target.isLocalFile())
        return;
    auto *job = KIO::fileSystemFreeSpace(target);
    m_freeSpaceJob = job;
    connect(job, &KJob::result, this, [this, job] {
        const qint64 value = job->error() ? -1 : qint64(job->availableSize());
        if (value != m_freeSpace) {
            m_freeSpace = value;
            emit freeSpaceChanged();
        }
    });
}

void FolderModel::expect(const QUrl &url, bool rename)
{
    const QUrl clean = url.adjusted(QUrl::StripTrailingSlash);
    dropExpiredExpectations();
    // A new batch (nothing pending) replaces the selection with its first item.
    if (m_expected.isEmpty())
        m_expectFresh = true;
    m_expected.insert(clean, QDeadlineTimer(kExpectationLifetimeMs));
    qCDebug(lcFiles) << "expect" << clean.fileName() << "rename" << rename << "fresh" << m_expectFresh << "row now" << rowForUrl(clean);
    if (rename)
        m_renameUrl = clean;
    checkExpected();
}

void FolderModel::expectAlone(const QUrl &url)
{
    m_expectedAlone = url.isEmpty() ? QUrl() : url.adjusted(QUrl::StripTrailingSlash);
    qCDebug(lcFiles) << "expect alone" << m_expectedAlone.fileName() << "row now" << (m_expectedAlone.isEmpty() ? -1 : rowForUrl(m_expectedAlone));
    if (!m_expectedAlone.isEmpty())
        checkExpected();
}

void FolderModel::setCutUrls(const QSet<QUrl> &urls)
{
    if (urls == m_cut)
        return;
    QSet<QUrl> changed = m_cut;
    changed.unite(urls);
    changed.subtract(QSet<QUrl>(m_cut).intersect(urls));
    m_cut = urls;
    if (changed.size() > kSelectionBulkThreshold) {
        if (rowCount() > 0)
            emit dataChanged(index(0, 0), index(rowCount() - 1, 0), {CutRole});
        return;
    }
    for (const QUrl &u : std::as_const(changed)) {
        const int r = rowForUrl(u);
        if (r >= 0)
            emit dataChanged(index(r, 0), index(r, 0), {CutRole});
    }
}

void FolderModel::dropAloneWish()
{
    // The selection checkExpected makes for the wish itself is not a choice of the user's.
    if (!m_checkingExpected)
        m_expectedAlone.clear();
}

void FolderModel::dropExpiredExpectations()
{
    for (auto it = m_expected.begin(); it != m_expected.end();) {
        if (it.value().hasExpired())
            it = m_expected.erase(it);
        else
            ++it;
    }
    if (!m_renameUrl.isEmpty() && !m_expected.contains(m_renameUrl))
        m_renameUrl.clear();
}

void FolderModel::checkExpected()
{
    // select() emits dataChanged, which calls back here.
    if ((m_expected.isEmpty() && m_expectedAlone.isEmpty()) || m_checkingExpected)
        return;
    const QScopedValueRollback<bool> guard(m_checkingExpected, true);
    if (!m_expectedAlone.isEmpty()) {
        const int r = rowForUrl(m_expectedAlone);
        if (r >= 0) {
            qCDebug(lcFiles) << "reveal alone" << r << m_expectedAlone.fileName();
            m_expectedAlone.clear();
            select(r, 0);
            emit revealRequested(r, false);
        }
    }
    dropExpiredExpectations();
    const QList<QUrl> pending = m_expected.keys();
    for (const QUrl &url : pending) {
        const int r = rowForUrl(url);
        if (r < 0)
            continue;
        m_expected.remove(url);
        // The first item of a batch replaces the selection, the others join it.
        if (m_expectFresh) {
            select(r, 0);
            m_expectFresh = false;
        } else if (!m_selected.contains(url)) {
            select(r, Qt::ControlModifier);
        }
        const bool rename = url == m_renameUrl;
        if (rename)
            m_renameUrl.clear();
        qCDebug(lcFiles) << "reveal" << r << url.fileName() << "rename" << rename << "row check" << rowForUrl(url);
        emit revealRequested(r, rename);
    }
}

void FolderModel::onItemsDeleted(const KFileItemList &items)
{
    bool selectionTouched = false;
    for (const KFileItem &item : items) {
        const QUrl url = item.url();
        if (url.adjusted(QUrl::StripTrailingSlash) == m_url) {
            emit redirected(m_url.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash));
            continue;
        }
        selectionTouched |= m_selected.remove(url);
        if (url == m_current)
            m_current.clear();
        forgetThumbnail(m_small, url, false);
        forgetThumbnail(m_large, url, false);
        m_tags.remove(url);
        m_styles.remove(url);
    }
    if (selectionTouched)
        emit selectionChanged();
    m_structureTimer.start();
    refreshFreeSpace();
}

void FolderModel::setError(const QString &error)
{
    if (error == m_error)
        return;
    m_error = error;
    emit errorChanged();
}
