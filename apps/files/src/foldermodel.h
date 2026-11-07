#pragma once

#include <QCollator>
#include <QDeadlineTimer>
#include <QFileSystemWatcher>
#include <QElapsedTimer>
#include <QHash>
#include <QPointer>
#include <QSet>
#include <QSize>
#include <QSortFilterProxyModel>
#include <QTimer>
#include <QUrl>
#include <QVariantMap>

#include "applicationslogic.h"
#include "filelogic.h"
#include "folderstylelogic.h"
#include "previewqueue.h"

#include <KFileItem>

#include <memory>

class FolderStyleStore;
class KDirLister;
class KDirModel;
class KJob;
class ItemListModel;
class OrgKdeKDirNotifyInterface;
class SearchRunner;
class FileSearchRunner;

namespace ImageSize
{
class Reader;
}

namespace KIO
{
class PreviewJob;
}

// One folder listing for QML: KIO's KDirModel (fed by a KDirLister) behind a sort/filter proxy.
// Adds flat roles for QML delegates, Finder-style sorting (FileLogic::compareEntries), a name filter,
// a URL-keyed selection that survives re-sorting, thumbnails through KIO::PreviewJob, tags (user.xdg.tags,
// TagStore) and free space through KIO::fileSystemFreeSpace. It never touches files: operations live in FilesApp.
//
// The Applications location (grassfield-apps:/) lists the installed applications the same way (the rows of the search
// list; one item per desktop entry, url grassfield-app:/<id>, never a file): read-only, nothing can be created, renamed,
// moved or deleted in it, and opening a row starts the application (FilesApp::launchApplication).
//
// A tag search location (grassfield-tag:/<tag>?in=<folder>, TagLogic) lists the matches of a TagSearch instead of a
// folder: the same roles, selection and thumbnails, over a flat list of items from several folders, kept up to date
// with KIO's change notifications (KDirNotify: renamed, moved, removed, changed) and FilesApp's tag changes.
class FolderModel : public QSortFilterProxyModel
{
    Q_OBJECT
    Q_PROPERTY(QUrl url READ url WRITE setUrl NOTIFY urlChanged)
    Q_PROPERTY(int sortKey READ sortKey WRITE setSortKey NOTIFY sortChanged)
    Q_PROPERTY(bool sortDescending READ sortDescending WRITE setSortDescending NOTIFY sortChanged)
    Q_PROPERTY(bool foldersFirst READ foldersFirst WRITE setFoldersFirst NOTIFY sortChanged)
    // View > Group By (FileLogic::GroupBy; 0: no groups). The rows are sorted group by group, then by sortKey.
    Q_PROPERTY(int groupBy READ groupBy WRITE setGroupBy NOTIFY sortChanged)
    // The groups in row order: [{title, first, count}] (empty without groups), for the grouped icon view.
    Q_PROPERTY(QVariantList groups READ groups NOTIFY groupsChanged)
    Q_PROPERTY(bool showHidden READ showHidden WRITE setShowHidden NOTIFY showHiddenChanged)
    Q_PROPERTY(QString filterText READ filterText WRITE setFilterText NOTIFY filterTextChanged)
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(int selectedCount READ selectedCount NOTIFY selectionChanged)
    Q_PROPERTY(int currentRow READ currentRow NOTIFY currentRowChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(qint64 freeSpace READ freeSpace NOTIFY freeSpaceChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(bool isTrash READ isTrash NOTIFY urlChanged)
    Q_PROPERTY(bool writable READ writable NOTIFY rootChanged)
    Q_PROPERTY(QString title READ title NOTIFY rootChanged)
    Q_PROPERTY(int previewSize READ previewSize WRITE setPreviewSize NOTIFY previewSizeChanged)
    // Edge of the large thumbnails (gallery view preview, role largeThumbnail), in pixels.
    Q_PROPERTY(int largePreviewSize READ largePreviewSize WRITE setLargePreviewSize NOTIFY previewSizeChanged)
    // A tag search location (see the class comment); searchLimited: a bound of TagSearch stopped it early.
    Q_PROPERTY(bool isSearch READ isSearch NOTIFY urlChanged)
    // Recents (Recents::locationUrl): a search-like flat list of the recently used files; isSearch is true too.
    Q_PROPERTY(bool isRecents READ isRecents NOTIFY urlChanged)
    Q_PROPERTY(bool searchLimited READ searchLimited NOTIFY loadingChanged)
    // A search location (SearchLogic, ADR-0027): the matches of a text and criteria in this computer or a folder; isSearch is
    // true too. searchBackend: FileSearch::Backend of the last search (0 the file index, 1 plocate's names, 2 a walk);
    // searchContentsUnavailable: a Contents row could not be answered (no file index).
    Q_PROPERTY(bool isFileSearch READ isFileSearch NOTIFY urlChanged)
    Q_PROPERTY(int searchBackend READ searchBackend NOTIFY loadingChanged)
    Q_PROPERTY(bool searchContentsUnavailable READ searchContentsUnavailable NOTIFY loadingChanged)
    // The Open and Save panels (grassfield-portal, ADR-0035 D-4): {globs, mimeTypes, foldersOnly, single}, empty in Files.
    // Files the panel cannot take (a folder panel: every file; else those its filter, FileLogic::passesFilter, refuses) are
    // dimmed (role "dimmed") and never selected, as macOS dims them; `single` keeps at most one item selected. Folders are
    // never dimmed: they open. Every item of the Applications location is dimmed in a panel (a launcher, not a file), except
    // in Choose Application: `applications` (desktop ids) names the ones it takes, `allApplications` takes every one, and
    // `listed` (desktop ids) the ones the location lists there even when the Apps grid hides them (NoDisplay=true: the
    // candidates the Open With submenu shows).
    Q_PROPERTY(QVariantMap chooser READ chooser WRITE setChooser NOTIFY chooserChanged)
    // The Applications location (grassfield-apps:/, ApplicationsLogic): the desktop entries the user sees, read-only.
    Q_PROPERTY(bool isApplications READ isApplications NOTIFY urlChanged)

public:
    enum Roles {
        NameRole = Qt::UserRole + 1,
        UrlRole,
        IconNameRole,
        IsDirRole,
        SizeRole,
        SizeTextRole,
        ModifiedRole,
        ModifiedTextRole,
        KindRole,
        ThumbnailRole,
        SelectedRole,
        HiddenRole,
        CanPreviewRole,
        EmblemRole,
        LargeThumbnailRole,
        // Stored tags in display order (colour tags first), and the palette indices of the colour tags (the dots).
        TagsRole,
        TagColorsRole,
        // A folder's own look (FolderStyleStore): its colour setting ("" = follows icons.folderColor) and its symbol.
        FolderColorRole,
        FolderGlyphRole,
        // The title of the item's group (Group By; "" without groups): the list view's sections.
        GroupRole,
        // Not a QML role (not in roleNames): only signalled by dataChanged when a picture's size arrives (dimensionsAt).
        DimensionsRole,
        // A file the panel cannot take (chooser).
        DimmedRole,
        // Cut and not pasted yet (FilesApp, from the clipboard): the views draw it faded (decision F-18).
        CutRole,
    };
    Q_ENUM(Roles)

    explicit FolderModel(QObject *parent = nullptr);
    ~FolderModel() override;

    QUrl url() const { return m_url; }
    void setUrl(const QUrl &url);
    int sortKey() const { return m_sortKey; }
    void setSortKey(int key);
    bool sortDescending() const { return m_descending; }
    void setSortDescending(bool descending);
    bool foldersFirst() const { return m_foldersFirst; }
    void setFoldersFirst(bool on);
    int groupBy() const { return m_groupBy; }
    void setGroupBy(int by);
    QVariantList groups() const;
    bool showHidden() const;
    void setShowHidden(bool on);
    QString filterText() const { return m_filterText; }
    void setFilterText(const QString &text);
    int count() const { return rowCount(); }
    int selectedCount() const { return int(m_selected.size()); }
    int currentRow() const;
    bool loading() const { return m_loading; }
    qint64 freeSpace() const { return m_freeSpace; }
    QString error() const { return m_error; }
    bool isTrash() const { return m_url.scheme() == QLatin1String("trash"); }
    bool writable() const;
    QString title() const;
    int previewSize() const { return m_small.size; }
    void setPreviewSize(int size);
    int largePreviewSize() const { return m_large.size; }
    void setLargePreviewSize(int size);
    bool isSearch() const;
    bool isRecents() const;
    bool searchLimited() const { return m_searchLimited; }
    bool isFileSearch() const;
    int searchBackend() const { return m_searchBackend; }
    bool searchContentsUnavailable() const { return m_searchContentsUnavailable; }
    // The folder a search stands for: a tag search's folder; a search's folder, or the root of "this computer".
    QUrl searchBase() const;
    QVariantMap chooser() const { return m_chooser; }
    void setChooser(const QVariantMap &chooser);
    bool isApplications() const { return ApplicationsLogic::isLocationUrl(m_url); }

    // Where folder looks are read from (FilesApp's store; null: no folder is customised).
    void setStyleStore(const FolderStyleStore *store) { m_styleStore = store; }
    // FilesApp changed the look of `urls` (Customize Folder): their rows read it again. All: the per-user store
    // changed under us.
    void folderStylesChanged(const QList<QUrl> &urls);
    void allFolderStylesChanged();

    // FilesApp changed the tags of `urls`: their rows read them again (and leave a tag search they no longer match).
    void tagsChanged(const QList<QUrl> &urls);

    QHash<int, QByteArray> roleNames() const override;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;

    // Selection. `modifiers` is a Qt.KeyboardModifiers value: Shift extends from the anchor, Ctrl toggles. `pointer`: a click
    // (the views' mouse handlers), which a panel's dimmed item does not take.
    Q_INVOKABLE void select(int row, int modifiers = 0, bool pointer = false);
    Q_INVOKABLE void selectAll();
    Q_INVOKABLE void clearSelection();
    Q_INVOKABLE void selectUrls(const QList<QUrl> &urls);
    Q_INVOKABLE QList<QUrl> selectedUrls() const;
    Q_INVOKABLE bool isSelected(int row) const;
    // Selected rows in view order (for Get Info and the context menu).
    Q_INVOKABLE QList<int> selectedRows() const;

    Q_INVOKABLE QUrl urlAt(int row) const;
    Q_INVOKABLE QString nameAt(int row) const;
    Q_INVOKABLE bool isDirAt(int row) const;
    Q_INVOKABLE int rowForUrl(const QUrl &url) const;
    // Type-to-select: first row at or after `from` (wrapping) whose name starts with `prefix`, or -1.
    Q_INVOKABLE int findPrefix(const QString &prefix, int from) const;
    // Get Info data of a row, or of the listed folder itself (row -1).
    Q_INVOKABLE QVariantMap info(int row) const;
    // A picture's size in pixels as "W × H" (the preview pane's Dimensions), "" until known or when it can't be known. Never
    // read here: the first call asks ImageSize::Reader (a worker thread; a local regular file only, never a FIFO, a device
    // or a network share), and the row's dataChanged (DimensionsRole) tells when the answer is in.
    Q_INVOKABLE QString dimensionsAt(int row);
    // Ask for a thumbnail (delegates call this when created); batched into one PreviewJob. `large`: the gallery
    // preview size (role largeThumbnail) instead of the icon size (role thumbnail).
    Q_INVOKABLE void requestPreview(int row, bool large = false);
    // Delegates call this when destroyed: a queued request that is not started yet is dropped.
    Q_INVOKABLE void cancelPreview(const QUrl &url, bool large = false);
    Q_INVOKABLE void reload();
    Q_INVOKABLE void refreshFreeSpace();
    // Select `url` (and ask the view to start renaming it) once it appears in the listing. Successive calls
    // before the items appear build one selection.
    Q_INVOKABLE void expect(const QUrl &url, bool rename);
    // The column view's wish for this listing (the folder its next column shows): `url` selected alone once it is listed,
    // as expect() would, but each call replaces the wish before it instead of adding to it, an empty URL drops it, and any
    // selection made in the listing meanwhile (a click, a key, Select All) drops it too. A wish still waiting for a slow
    // listing never comes back over the user's own choice (owner report 2026-11-07: "in Columns view the selection sometimes
    // goes back to the previous folder").
    Q_INVOKABLE void expectAlone(const QUrl &url);
    // The items the clipboard holds cut (FilesApp keeps every listing told; URLs without a trailing slash).
    void setCutUrls(const QSet<QUrl> &urls);

    KFileItem itemAt(int row) const;
    KFileItem rootItem() const;

signals:
    // The Applications location was built (id -> .desktop path of every row): FilesApp keeps it for Copy and Get Info.
    // The Applications location's own list: id -> .desktop path, id -> the name the row shows. Not sent by a listing with
    // chooser `listed` (a Choose Application panel's, which lists more).
    void applicationsListed(const QVariantMap &paths, const QVariantMap &names);
    void urlChanged();
    void sortChanged();
    void showHiddenChanged();
    void filterTextChanged();
    void countChanged();
    void selectionChanged();
    void currentRowChanged();
    void loadingChanged();
    void freeSpaceChanged();
    void errorChanged();
    void rootChanged();
    void previewSizeChanged();
    void groupsChanged();
    void chooserChanged();
    // The view should scroll to `row`, and start inline renaming when `rename` is true.
    void revealRequested(int row, bool rename);
    // The listed folder was deleted or the listing redirected elsewhere.
    void redirected(const QUrl &url);
    // Tags found on shown items (batched): FilesApp keeps the list of tags in use for the sidebar.
    void tagsSeen(const QStringList &tags);

protected:
    bool lessThan(const QModelIndex &left, const QModelIndex &right) const override;
    bool filterAcceptsRow(int sourceRow, const QModelIndex &sourceParent) const override;

private:
    // One thumbnail size: the requests of the delegates (newest first), the running job and the thumbnails kept
    // (ThumbnailStore keys, least recently loaded evicted beyond the LRU capacity). The icon size and the gallery
    // preview size share this pipeline.
    struct ThumbChannel {
        ThumbChannel(int role, int size, int capacity)
            : role(role)
            , size(size)
            , lru(capacity)
        {
        }
        const int role;
        int size;
        QHash<QUrl, QString> thumbs;
        PreviewQueue queue;
        ThumbnailLru lru;
        QTimer timer;
        QPointer<KIO::PreviewJob> job;
    };

    void applySelection(QSet<QUrl> next);
    // A file the panel cannot take (see chooser).
    bool dimmed(const KFileItem &item) const;
    void setCurrent(const QUrl &url);
    void setError(const QString &error);
    void checkExpected();
    void dropExpiredExpectations();
    // A selection made in the listing (not by checkExpected) ends expectAlone's wish.
    void dropAloneWish();
    void onItemsDeleted(const KFileItemList &items);
    void startPreviews(ThumbChannel &channel);
    void clearPreviews(ThumbChannel &channel);
    void clearAllPreviews();
    // The file changed or is gone: its thumbnail is dropped; `again` asks for a fresh one when it was asked for.
    void forgetThumbnail(ThumbChannel &channel, const QUrl &url, bool again);
    QString thumbnailFor(const ThumbChannel &channel, const QUrl &url) const;
    bool previewSupported(const KFileItem &item) const;

    // The item behind a source index and the source index of a url, for whichever source is active (the folder's
    // KDirModel or the search results).
    KFileItem sourceItem(const QModelIndex &source) const;
    QModelIndex sourceIndexForUrl(const QUrl &url) const;
    // Tags of an item (cached per url; read from user.xdg.tags of its local path).
    QStringList tagsOf(const KFileItem &item) const;
    // What sorting by `key` and grouping by m_groupBy read of an item (only those fields are filled).
    FileLogic::SortEntry sortEntry(const KFileItem &item, FileLogic::SortKey key) const;
    // An item's group (cached per url until the item, the folder, the grouping or the day changes).
    FileLogic::Group groupFor(const KFileItem &item) const;
    // The rows or their groups changed: groupsChanged follows (once per event loop turn).
    void groupsDirty();
    // Every cached group goes (the folder, the grouping or the day changed).
    void clearGroupCache();
    // A new day: the items are grouped and sorted again, outside any sort (its comparisons must see one grouping).
    void regroupForNewDay();
    // Arms m_dayTimer for the next midnight while the rows are grouped.
    void armDayTimer();
    void dropTags(const QUrl &url);
    // The look of a shown folder, read once per row (one lgetxattr, nothing for files and links).
    FolderStyleLogic::Style styleOf(const KFileItem &item) const;
    void emitRowChanged(const QUrl &url, const QList<int> &roles);

    // The Applications location: the rows are rebuilt from the desktop entries (and again when an applications directory changes).
    void loadApplications();
    void watchApplications();

    // Picture sizes by local path, for the file as it was listed (modification time and size): answers of the reader, or
    // pending. At most kMaxDimensions kept (all dropped beyond, and with the folder).
    struct Dimensions {
        QUrl url;
        QDateTime modified;
        qint64 size = -1;
        bool pending = true;
        QSize pixels;
    };
    static constexpr int kMaxDimensions = 256;
    QHash<QString, Dimensions> m_dimensions;
    std::unique_ptr<ImageSize::Reader> m_sizeReader;
    void dimensionsReady(const QString &path, QSize pixels);

    // Recents: read on a thread (RecentsLoader), again when the list changes on disk.
    void startRecents();
    void stopRecents();

    // Tag search.
    void startSearch();
    void startFileSearch();
    void stopSearch();
    void watchChanges();
    void addResults(const QStringList &paths);
    void removeResults(const QList<QUrl> &urls);
    void renameResult(const QUrl &from, const QUrl &to);

    KDirLister *m_lister = nullptr;
    KDirModel *m_dirModel = nullptr;
    QUrl m_url;
    int m_sortKey = 0;
    int m_groupBy = 0;
    // Recents: the load in flight is the current generation; when each file was last used (Date Last Opened there).
    quint64 m_recentsGeneration = 0;
    QHash<QUrl, QDateTime> m_recentTimes;
    QFileSystemWatcher *m_recentsWatcher = nullptr;
    QTimer m_recentsTimer;
    mutable QHash<QUrl, FileLogic::Group> m_groupCache;
    mutable QVariantList m_groups;
    mutable bool m_groupsValid = false;
    bool m_groupsNotifyQueued = false;
    // "Now" of the date groups, read again once a minute (a sort compares many times).
    mutable QDateTime m_groupNow;
    mutable QElapsedTimer m_groupClock;
    // The day the cached groups were made for; a new one (seen by groupFor, or the timer armed for midnight) regroups.
    mutable QDate m_groupDay;
    mutable bool m_newDayQueued = false;
    QTimer m_dayTimer;
    bool m_descending = false;
    bool m_foldersFirst = true;
    QString m_filterText;
    QCollator m_collator;
    bool m_loading = false;
    QElapsedTimer m_listTimer;
    qint64 m_freeSpace = -1;
    QString m_error;
    QSet<QUrl> m_selected;
    QUrl m_current;
    QUrl m_anchor;
    QHash<QUrl, QDeadlineTimer> m_expected;
    QSet<QUrl> m_cut;
    // expectAlone's wish (empty: none).
    QUrl m_expectedAlone;
    bool m_expectFresh = true;
    bool m_checkingExpected = false;
    QUrl m_renameUrl;

    // Thumbnails at the icon size (at most 512 kept, ~64 KB each at 128 px) and at the gallery preview size (a few,
    // up to 4 MB each at 1024 px: the shown item and its neighbours).
    ThumbChannel m_small{ThumbnailRole, 128, 512};
    ThumbChannel m_large{LargeThumbnailRole, 1024, 8};
    QTimer m_expectTimer;
    QTimer m_structureTimer;
    QPointer<KJob> m_freeSpaceJob;

    // Tags read for shown rows (url -> stored tags), and tags not yet reported through tagsSeen.
    mutable QHash<QUrl, QStringList> m_tags;
    mutable QSet<QString> m_seenPending;
    // Folder looks read for shown rows (url -> style, empty for folders without one).
    const FolderStyleStore *m_styleStore = nullptr;
    mutable QHash<QUrl, FolderStyleLogic::Style> m_styles;
    // The shown folder, watched for attribute changes of its entries (inotify IN_ATTRIB reaches a watch on the folder): a
    // look set by another tool shows without a reload. KIO's own update does not report an extended attribute change.
    QFileSystemWatcher m_attrWatcher;
    QTimer m_attrTimer;
    QElapsedTimer m_attrBurst; // the first change of the burst being debounced
    static constexpr int kAttrQuietMs = 200;
    static constexpr int kAttrMaxWaitMs = 500;
    void watchShownFolder();
    void revalidateStyles();
    mutable QTimer m_seenTimer;

    // Tag search: the matches (source model while searching), the running search and KIO's change notifications.
    ItemListModel *m_results = nullptr;
    // The shown applications by item url (Get Info, Kind) and the watch on the applications directories.
    QHash<QUrl, ApplicationsLogic::Entry> m_apps;
    // The list is built on a thread of its own (a slow or hostile applications folder never freezes the window); only the
    // newest build is applied.
    quint64 m_appsGeneration = 0;
    void applyApplications(const QList<ApplicationsLogic::Entry> &entries);
    QFileSystemWatcher m_appsWatcher;
    QTimer m_appsTimer;
    SearchRunner *m_search = nullptr;
    FileSearchRunner *m_fileSearch = nullptr;
    OrgKdeKDirNotifyInterface *m_notify = nullptr;
    bool m_searchLimited = false;
    int m_searchBackend = 0;
    bool m_searchContentsUnavailable = false;

    QVariantMap m_chooser;
    QStringList m_chooserGlobs;
    QStringList m_chooserMimeTypes;
    bool m_chooserFoldersOnly = false;
    bool m_chooserSingle = false;
    // Choose Application (grassfield-portal's AppChooser): the applications of the Applications location it can take (their
    // desktop ids), or every one.
    QSet<QString> m_chooserApplications;
    bool m_chooserAllApplications = false;
    // ...and the ones it lists although the Apps grid hides them (ApplicationsLogic::Environment::alsoListed).
    QSet<QString> m_chooserListed;
};
