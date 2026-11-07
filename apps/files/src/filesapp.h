#pragma once

#include "runmode.h"
#include "shortcutstyle.h"

#include <QCoreApplication>
#include <QFileSystemWatcher>
#include <QHash>
#include <QJSValue>
#include <QList>
#include <QMimeData>
#include <QObject>
#include <QPointF>
#include <QDateTime>
#include <QPointer>
#include <QProcess>
#include <QSettings>
#include <QThreadPool>
#include <QTimer>
#include <QUrl>
#include <QVariantList>

#include "folderstylestore.h"
#include "folderviews.h"
#include "savedsearches.h"
#include "archivejob.h"
#include "batchops.h"
#include "tagstore.h"

#include <functional>

class FolderModel;
class KJob;
namespace grassfield::apps {
class OngoingPublisher;
}
class PlacesModel;
class KioPrompts;

// Application services for the QML windows. Every file operation is a KIO job (copy, move, trash,
// restore, mkdir, rename, delete, empty trash, paste), recorded in KIO::FileUndoManager where KIO
// supports undo. Opening uses KIO::OpenUrlJob / ApplicationLauncherJob (MIME associations from
// KService). Nothing here reimplements KIO: names and selection are the only app-side logic.
class FilesApp : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QObject *places READ places CONSTANT)
    // KIO's questions (conflicts, skips, certificates…), shown as sheets by the browser window (ADR-0035 D-12 a).
    Q_PROPERTY(QObject *prompts READ prompts CONSTANT)
    // Files' Choose Application panels (Open With > Other…, KIO's question when a type has no application; ADR-0035 D-5,
    // step 5c): qml/Main.qml makes each one.
    Q_PROPERTY(QObject *applicationChooser READ applicationChooser CONSTANT)
    // The Store's answer to `grassfield-store --removable` (JSON text, "" until it came): which applications of the Applications
    // location it may uninstall (ADR-0046). The QML reads it with UninstallLogic.parse and removes nothing itself.
    Q_PROPERTY(QString removableText READ removableText NOTIFY removableTextChanged)
    Q_PROPERTY(QString homePath READ homePath CONSTANT)
    Q_PROPERTY(QList<QUrl> initialUrls READ initialUrls CONSTANT)
    Q_PROPERTY(bool dark READ dark NOTIFY appearanceChanged)
    Q_PROPERTY(bool devSession READ devSession CONSTANT)
    Q_PROPERTY(bool reduceMotion READ reduceMotion NOTIFY appearanceChanged)
    // accessibility.increaseContrast and accessibility.textSize (1 to 1.3), as the Store reads them (ADR-0039 step 23).
    Q_PROPERTY(bool increaseContrast READ increaseContrast NOTIFY appearanceChanged)
    Q_PROPERTY(qreal textScale READ textScale NOTIFY appearanceChanged)
    // windows.titlebarDoubleClick of grassfield.json: zoom (default), minimize or none (the toolbar's double-click).
    Q_PROPERTY(QString titlebarDoubleClick READ titlebarDoubleClick NOTIFY appearanceChanged)
    // False when the shell says the compositor plugin is absent: the minimize light is greyed (ADR-0015 Q4b, chromecaps.h).
    Q_PROPERTY(bool canMinimize READ canMinimize NOTIFY appearanceChanged)
    // accent.color: multicolor (the Grassfield green), blue, purple, pink, red, orange, yellow, green or graphite.
    Q_PROPERTY(QString accentColor READ accentColor NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentHighlight READ accentHighlight NOTIFY appearanceChanged)
    // keyboard.shortcutStyle resolved for this device: "mac" (macOS symbols in menus) or "pc" (text), shortcutstyle.h.
    Q_PROPERTY(QString shortcutStyle READ shortcutStyle NOTIFY appearanceChanged)
    Q_PROPERTY(QString iconMode READ iconMode NOTIFY appearanceChanged)
    Q_PROPERTY(QString iconTint READ iconTint NOTIFY appearanceChanged)
    // icons.folderColor: "theme", "accent" or "#rrggbb" (every folder icon).
    Q_PROPERTY(QString folderColor READ folderColor NOTIFY appearanceChanged)
    Q_PROPERTY(bool canUndo READ canUndo NOTIFY undoChanged)
    Q_PROPERTY(QString undoText READ undoText NOTIFY undoChanged)
    Q_PROPERTY(bool canRedo READ canRedo NOTIFY undoChanged)
    Q_PROPERTY(QString redoText READ redoText NOTIFY undoChanged)
    Q_PROPERTY(bool canPaste READ canPaste NOTIFY clipboardChanged)
    Q_PROPERTY(int clipboardCount READ clipboardCount NOTIFY clipboardChanged)
    // The clipboard holds items cut and not pasted yet (by Files or another file manager; decision F-18).
    Q_PROPERTY(bool cutPending READ cutPending NOTIFY clipboardChanged)
    Q_PROPERTY(QString activity READ activity NOTIFY activityChanged)
    Q_PROPERTY(int activityPercent READ activityPercent NOTIFY activityChanged)
    // The progress window (FP-68, Finder-Copy): [{id, title, detail, percent}] of the running copies, moves and deletions,
    // the newest last; cancelJob(id) stops one (KIO undoes nothing of what is done).
    Q_PROPERTY(QVariantList jobs READ jobs NOTIFY jobsChanged)
    // Persisted preferences (QSettings "Grassfield/Files").
    Q_PROPERTY(QString viewMode READ viewMode WRITE setViewMode NOTIFY prefsChanged)
    Q_PROPERTY(int sortKey READ sortKey WRITE setSortKey NOTIFY prefsChanged)
    Q_PROPERTY(bool sortDescending READ sortDescending WRITE setSortDescending NOTIFY prefsChanged)
    Q_PROPERTY(bool foldersFirst READ foldersFirst WRITE setFoldersFirst NOTIFY prefsChanged)
    Q_PROPERTY(bool showHidden READ showHidden WRITE setShowHidden NOTIFY prefsChanged)
    // The gallery view shows its info panel (name, kind, dates, tags of the shown item).
    Q_PROPERTY(bool galleryInfo READ galleryInfo WRITE setGalleryInfo NOTIFY prefsChanged)
    // View > Show Preview (Shift+Cmd+P) in the icon and list views (view/preview) and the column view's preview column
    // (view/columnPreview); the gallery's is galleryInfo.
    Q_PROPERTY(bool previewPane READ previewPane WRITE setPreviewPane NOTIFY prefsChanged)
    Q_PROPERTY(bool columnPreview READ columnPreview WRITE setColumnPreview NOTIFY prefsChanged)
    // View > Show Tab Bar (Finder, Shift+Cmd+T): the tab bar stays visible with one tab (view/tabBar, every window).
    Q_PROPERTY(bool tabBarShown READ tabBarShown WRITE setTabBarShown NOTIFY prefsChanged)
    // View > Show Path Bar (Alt+Cmd+P), Show Status Bar (Cmd+/), Show Sidebar (Ctrl+Cmd+S): hidden, hidden and shown by
    // default, as in the Finder (decision F-11; view/pathBar, view/statusBar, view/sidebar, every window).
    Q_PROPERTY(bool pathBarShown READ pathBarShown WRITE setPathBarShown NOTIFY prefsChanged)
    Q_PROPERTY(bool statusBarShown READ statusBarShown WRITE setStatusBarShown NOTIFY prefsChanged)
    Q_PROPERTY(bool sidebarShown READ sidebarShown WRITE setSidebarShown NOTIFY prefsChanged)
    // The size of the last browser window resized or closed (ADR-0026 part 1), 0 when none was kept yet. Read when a
    // window opens only: a window never follows another one's size.
    Q_PROPERTY(int windowWidth READ windowWidth NOTIFY windowSizeChanged)
    Q_PROPERTY(int windowHeight READ windowHeight NOTIFY windowSizeChanged)
    // Where new windows and tabs open (Finder's "New Finder windows show"): the home folder.
    Q_PROPERTY(QUrl newWindowUrl READ newWindowUrl CONSTANT)
    // This process (a dragged tab names it: a tab dropped into another Files process is refused).
    Q_PROPERTY(qint64 processId READ processId CONSTANT)
    // The key window (QGuiApplication::focusWindow), null while no window of Files has the keyboard. A window's own
    // `active` cannot tell: Qt reports a window and its transient children active together.
    Q_PROPERTY(QObject *focusWindow READ focusWindow NOTIFY focusWindowChanged)
    // Translated names of the seven colour tags, in palette order (tokens files.tagRed ... files.tagGray).
    Q_PROPERTY(QStringList colorTagNames READ colorTagNames CONSTANT)
    // Changes whenever Files writes tags (bindings that show tag states re-read them).
    Q_PROPERTY(int tagRevision READ tagRevision NOTIFY tagRevisionChanged)
    // Tags removed from the sidebar (stored names), for the Tags section's menu that lists them again.
    Q_PROPERTY(QStringList hiddenTags READ hiddenTags NOTIFY hiddenTagsChanged)

public:
    explicit FilesApp(const QList<QUrl> &initialUrls, QObject *parent = nullptr);
    // Writes the view settings still pending (the only wait for another process's lock, bounded), and waits for the
    // pictures being turned.
    ~FilesApp() override;

    QObject *places() const;
    QObject *prompts() const;
    QObject *applicationChooser() const;
    QString homePath() const;
    QList<QUrl> initialUrls() const { return m_initialUrls; }
    bool dark() const { return m_dark; }
    // A dev session (runmode.h): never offers anything that touches the owner's real trash (ADR-0011).
    bool devSession() const { return grassfield::apps::runmode::dev(); }
    bool reduceMotion() const { return m_reduceMotion; }
    bool increaseContrast() const { return m_increaseContrast; }
    qreal textScale() const { return m_textScale; }
    QString titlebarDoubleClick() const { return m_titlebarDoubleClick; }
    bool canMinimize() const { return m_canMinimize; }
    // Icon appearance (ADR-0014): default | dark | clear | tinted, and "accent" or #rrggbb.
    QString accentColor() const { return m_accentColor; }
    QString accentHighlight() const { return m_accentHighlight; }
    QString shortcutStyle() const { return m_shortcutStyle; }
    QString iconMode() const { return m_iconMode; }
    QString iconTint() const { return m_iconTint; }
    QString folderColor() const { return m_folderColor; }
    bool canUndo() const;
    QString undoText() const;
    bool canRedo() const;
    QString redoText() const;
    bool canPaste() const;
    int clipboardCount() const;
    bool cutPending() const { return !m_cutUrls.isEmpty(); }
    QString activity() const { return m_activity; }
    int activityPercent() const { return m_activityPercent; }
    QVariantList jobs() const { return m_jobList; }
    Q_INVOKABLE void cancelJob(int id);
    // The Copy window's rows wait this long before they are published (the Finder shows the window for copies that last).
    static constexpr int kProgressDelayMs = 250;
    // Tests only: a shorter wait (0 restores the default), so a copy that ends within 250 ms on a fast disk still publishes.
    void setProgressDelayForTests(int ms);
    // Open With > Change All… (FP-65): `storageId` becomes the default application of the item's type (mimeapps.list).
    Q_INVOKABLE QString mimeTypeOf(const QUrl &url) const;
    Q_INVOKABLE QString defaultApplication(const QString &mimeType) const;
    Q_INVOKABLE bool setDefaultApplication(const QString &mimeType, const QString &storageId);

    QString viewMode() const;
    void setViewMode(const QString &mode);
    int sortKey() const;
    void setSortKey(int key);
    bool sortDescending() const;
    void setSortDescending(bool on);
    bool foldersFirst() const;
    void setFoldersFirst(bool on);
    bool showHidden() const;
    void setShowHidden(bool on);
    bool galleryInfo() const;
    void setGalleryInfo(bool on);
    bool tabBarShown() const;
    void setTabBarShown(bool on);
    bool pathBarShown() const;
    void setPathBarShown(bool on);
    bool statusBarShown() const;
    void setStatusBarShown(bool on);
    bool sidebarShown() const;
    void setSidebarShown(bool on);
    bool previewPane() const;
    void setPreviewPane(bool on);
    bool columnPreview() const;
    void setColumnPreview(bool on);
    int windowWidth() const;
    int windowHeight() const;
    QUrl newWindowUrl() const;
    qint64 processId() const { return QCoreApplication::applicationPid(); }
    QObject *focusWindow() const;
    QStringList colorTagNames() const;
    int tagRevision() const { return m_tagRevision; }
    QStringList hiddenTags() const { return m_hiddenTags; }

    // Keeps the size of a browser window for the next one (bounded; nothing is written for an unchanged size).
    Q_INVOKABLE void rememberWindowSize(int width, int height);
    // Per-folder view settings (FolderViews, docs/specs/files.md F-3): {mode, sortKey, sortDescending} with only the
    // fields set for `url`; an empty map when the folder uses the defaults.
    Q_INVOKABLE QVariantMap folderView(const QUrl &url) const;
    // Sets the given fields (mode, sortKey, sortDescending) for `url`; other fields stay as stored.
    Q_INVOKABLE void setFolderView(const QUrl &url, const QVariantMap &fields);

    // Quick actions of the preview pane (ImageRotate): the local pictures among `urls` that Files can turn without a loss
    // (JPEG through its orientation tag; PNG, BMP), none for a selection of more than kMaxQuickActionItems (each is looked
    // at on disk as the selection changes); and the turn itself, on a thread of its own (errors in the banner).
    static constexpr int kMaxQuickActionItems = 100;
    Q_INVOKABLE QList<QUrl> rotatableImages(const QList<QUrl> &urls) const;
    Q_INVOKABLE void rotateImages(const QList<QUrl> &urls, bool clockwise);

    // Makes `parent` the owner of `object` (QObject parent). A tab moved to another window must belong to it: setting an
    // item's visual parent in QML keeps its first owner, whose destruction would take the tab along.
    Q_INVOKABLE void reparent(QObject *object, QObject *parent);

    // A new folder listing owned by `parent` (a QML item: the listing dies with its view).
    Q_INVOKABLE QObject *createFolderModel(QObject *parent);

    // Pure helpers (FileLogic) for QML.
    Q_INVOKABLE QVariantList pathSegments(const QUrl &url) const;
    Q_INVOKABLE QString formatSize(qint64 bytes) const;
    Q_INVOKABLE bool isValidFileName(const QString &name) const;
    Q_INVOKABLE int baseNameLength(const QString &name, bool isDir) const;
    Q_INVOKABLE bool defaultDescending(int sortKey) const;
    Q_INVOKABLE QString uriList(const QList<QUrl> &urls) const;
    // URL comparisons for QML: QML's url-to-string conversion is not canonical (a QUrl may print
    // percent-encoded or not depending on where it came from), so equality is decided on parsed QUrls.
    Q_INVOKABLE bool sameUrl(const QUrl &a, const QUrl &b) const;
    Q_INVOKABLE bool isDirectChild(const QUrl &parent, const QUrl &child) const;
    // "Go to Folder": "~", "~/x", absolute paths, paths relative to `base`, or URLs. Invalid if no such folder.
    Q_INVOKABLE QUrl resolveLocation(const QString &text, const QUrl &base) const;
    // The address resolveLocation reads, without reading the disk (a local URL whether or not a folder is there; invalid for
    // empty text): the panels ask the disk off the GUI thread (grassfield-portal's FileChooser::probe).
    Q_INVOKABLE QUrl locationUrl(const QString &text, const QUrl &base) const;

    // Opening.
    Q_INVOKABLE void open(const QList<QUrl> &urls);
    // [{id, name}] of the applications registered for the first item's MIME type, preferred first.
    Q_INVOKABLE QVariantList applicationsFor(const QList<QUrl> &urls) const;
    Q_INVOKABLE void openWith(const QString &storageId, const QList<QUrl> &urls);
    // Open With > Other…: the Choose Application panel for `urls`; the application chosen opens them (openWith).
    Q_INVOKABLE void chooseApplication(const QList<QUrl> &urls);
    // The Applications location (grassfield-apps:/): the installed applications as Finder's Applications folder shows them.
    // launchApplication starts the application of a grassfield-app:/<id> item (nothing else) the way the shell's
    // Apps grid does (ApplicationsLogic::launchCommand: xdg-terminal-exec for Terminal=true, uwsm-app scope in a session).
    Q_INVOKABLE QUrl applicationsUrl() const;
    // An application's item in that location (grassfield-app:/<desktop id>), and the desktop id of such an item ("" for any
    // other URL): grassfield-portal's Choose Application panel answers with it.
    Q_INVOKABLE QUrl applicationUrl(const QString &id) const;
    Q_INVOKABLE QString applicationId(const QUrl &url) const;
    // True (and operationFailed with the permission message) when `urls` hold an item of the Applications location or the
    // location itself: nothing can be done to them but opening.
    bool refuseApplicationItems(const QList<QUrl> &urls);
    QList<QUrl> applicationFiles(const QList<QUrl> &urls) const;
    Q_INVOKABLE bool isApplicationUrl(const QUrl &url) const;
    // How many applications the Applications location lists (Get Info on the location: macOS shows the size of the folder).
    Q_INVOKABLE int applicationsCount() const;
    Q_INVOKABLE void launchApplication(const QUrl &url);
    // Asks the Store which applications it may uninstall (one run at a time, again at most once a minute), then removableText.
    Q_INVOKABLE void loadRemovableApplications();
    // Move to Trash on an application: `grassfield-store --page=uninstall:<id>.desktop`. The Store opens its own alert and removes
    // only after Delete there; Files asks nothing and runs nothing else. `id` is an Applications-location id; anything that is not one is refused.
    Q_INVOKABLE void uninstallApplication(const QString &id);
    QString removableText() const { return m_removableText; }
    // Glance: starts `grassfield-preview --glance` (detached) for the local regular files among `urls`.
    Q_INVOKABLE void glance(const QList<QUrl> &urls);

    // Operations. `folder` (a FolderModel, may be null) selects the created items when they appear.
    // Copy, or Cut (decision F-18, owner request 2026-11-07): the items fade in every listing until Paste moves them; the
    // clipboard says "cut" the KDE way (application/x-kde-cutselection) and the GNOME way (x-special/gnome-copied-files).
    Q_INVOKABLE void copyToClipboard(const QList<QUrl> &urls, bool cut);
    // Esc after Cut: the clipboard is emptied when it still holds the cut items (nothing moves; they no longer fade).
    Q_INVOKABLE void cancelCut();
    Q_INVOKABLE void paste(const QUrl &destination, QObject *folder);
    // Move Item Here (⌥⌘V, decision F-6): the copied items moved into `destination` (undoable); Files has no Cut.
    Q_INVOKABLE void moveHere(const QUrl &destination, QObject *folder);
    Q_INVOKABLE void trash(const QList<QUrl> &urls);
    Q_INVOKABLE void restore(const QList<QUrl> &urls);
    // Delete Immediately: any item (the UI confirms first).
    Q_INVOKABLE void deletePermanently(const QList<QUrl> &urls);
    // The UI confirms first. Never called by automated tests.
    Q_INVOKABLE void emptyTrash();
    Q_INVOKABLE void newFolder(const QUrl &directory, QObject *folder);
    // New Folder of the Save panel (grassfield-portal): a folder named `name` in `directory`, then callback(url, error): the
    // new folder's URL, or "" and why it was not made (an invalid name at once; a taken name or KIO's error when KIO answers,
    // never from a look at the disk on the GUI thread).
    Q_INVOKABLE void makeFolder(const QUrl &directory, const QString &name, const QJSValue &callback);
    Q_INVOKABLE void rename(const QUrl &url, const QString &newName, QObject *folder);

    // File commands (docs/specs/files.md FP-54..FP-59, FP-64, FP-79). Make Alias: a symbolic link "<name> alias" next to
    // each local item, to its absolute path (a macOS alias survives a move; a link does not: limit). Show Original: the
    // item a local link points to (invalid when it is no link or its target is gone).
    Q_INVOKABLE void makeAlias(const QList<QUrl> &urls, QObject *folder);
    Q_INVOKABLE QUrl linkTarget(const QUrl &url) const;
    // New Folder with Selection: "New Folder With Items" in `directory` (every item must be in it), the items moved into
    // it (local folder: all or nothing, ONE undo step; a server's folder: KIO jobs, two steps), then the new folder
    // renamed in place.
    Q_INVOKABLE void newFolderWithItems(const QList<QUrl> &urls, const QUrl &directory, QObject *folder);
    // Copy as Pathname: the local paths, one per line, as text.
    Q_INVOKABLE void copyPaths(const QList<QUrl> &urls);
    // New Terminal at Folder (decision F-7): the session's terminal (xdg-terminal-exec) opened in a local folder. Nothing
    // of the folder is run: the terminal is an application the user chose.
    Q_INVOKABLE void openTerminal(const QUrl &folder);
    // Share > Send with LocalSend… (ADR-0045 OC-13): whether LocalSend (and systemd-run, which starts it) is on PATH now, and
    // the send. `argv` is ShareLogic.js's vector, Omarchy's own invocation followed by the items; anything else is refused.
    Q_INVOKABLE bool localSendAvailable() const;
    Q_INVOKABLE void sendWithLocalSend(const QStringList &argv);
    // Rename N Items (RenameLogic): options {mode, find, replaceWith, addText, where, format, customFormat, startAt}. The
    // preview is the new names; renameItems returns "" or why nothing was renamed. Local items: all renamed or none (a
    // failure part-way puts back what was done), ONE undo step; items on a server are renamed one by one through KIO.
    Q_INVOKABLE QStringList renamePreview(const QList<QUrl> &urls, const QVariantMap &options) const;
    Q_INVOKABLE QString renameItems(const QList<QUrl> &urls, const QVariantMap &options, QObject *folder);
    // Compress and Expand (ADR-0029, ArchiveJob): local items of one folder into a zip there; an archive next to itself.
    Q_INVOKABLE bool isArchive(const QUrl &url) const;
    Q_INVOKABLE void compress(const QList<QUrl> &urls, QObject *folder);
    Q_INVOKABLE void expand(const QUrl &archive, QObject *folder);
    Q_INVOKABLE void cancelArchives();
    // Get Info's Sharing & Permissions (ADR-0028 option 1: the user's own items, no privilege). permissionsOf gives
    // {valid, mode, modeText, owner, group, isDir, editable, reason, groups (the user's groups), access: [owner, group,
    // others] (PermissionLogic::Access)}. A symbolic link, an item off the local disks or under /proc, /sys or /dev, and an
    // item someone else owns are shown and not editable, `reason` says why (the administrator path waits for its review).
    // Changes go through the item pinned by an O_PATH descriptor (its /proc/self/fd entry), never a path looked up again;
    // permissionsChanged(url) then asks the window to read the item again (what the system reports, not what was asked).
    Q_INVOKABLE QVariantMap permissionsOf(const QUrl &url) const;
    Q_INVOKABLE void setAccess(const QUrl &url, int who, int access);
    Q_INVOKABLE void setGroup(const QUrl &url, const QString &group);
    // Apply to enclosed items (confirmed by the window): the folder's privileges to everything in it, with chmod's + and -
    // operators (ADR-0028 probe 12: special bits kept); items of other users are left as they are and counted.
    Q_INVOKABLE void applyToEnclosed(const QUrl &url);
    Q_INVOKABLE void duplicate(const QList<QUrl> &urls, QObject *folder);
    // Drag and drop: move on the same filesystem, copy across filesystems or with Ctrl/Alt held.
    Q_INVOKABLE void drop(const QList<QUrl> &urls, const QUrl &destination, QObject *folder);
    Q_INVOKABLE void undo();
    Q_INVOKABLE void redo();
    // Recursive size through KIO::directorySize; callback(bytes, files, folders), bytes -1 on error.
    Q_INVOKABLE void directorySize(const QUrl &url, const QJSValue &callback);

    // Tags (user.xdg.tags, TagLogic/TagStore). Only local files and folders on filesystems with user extended
    // attributes carry tags; tagsUnavailable() is "" when every item of `urls` can be tagged, else the reason shown in
    // place of the tag controls.
    Q_INVOKABLE QString tagsUnavailable(const QList<QUrl> &urls) const;
    // Per colour (palette order): 0 no item has it, 1 some do, 2 all do.
    Q_INVOKABLE QVariantList colorTagStates(const QList<QUrl> &urls) const;
    // The tags of one local item by their shown names, in display order (colour tags first); empty for anything else.
    // Read now: callers depend on tagRevision to read again after Files' own writes.
    Q_INVOKABLE QStringList tagNamesOf(const QUrl &url) const;
    // macOS behaviour: removes colour `index` from every item when all have it, else adds it to those without.
    Q_INVOKABLE void toggleColorTag(const QList<QUrl> &urls, int index);
    // Adds `tag` (a stored tag name) to the local items among `urls` (a drop on a sidebar tag).
    Q_INVOKABLE void addTag(const QList<QUrl> &urls, const QString &tag);
    // Adds a tag the user typed (TagLogic::typedTag: a colour's shown name is that colour tag).
    Q_INVOKABLE void addTypedTag(const QList<QUrl> &urls, const QString &typed);
    // Removes `tag` (a stored tag name) from the local items among `urls`.
    Q_INVOKABLE void removeTag(const QList<QUrl> &urls, const QString &tag);
    // A tag's shown name (colour tags translated).
    Q_INVOKABLE QString tagName(const QString &tag) const;
    // Palette index of a colour tag, -1 for other tags.
    Q_INVOKABLE int tagColor(const QString &tag) const;
    // The location listing the items tagged `tag` in the folder shown at `from` and below: `from` itself when it is a
    // local folder, the folder of a tag search, else the home folder.
    Q_INVOKABLE QUrl tagSearchUrl(const QString &tag, const QUrl &from) const;
    Q_INVOKABLE bool isTagSearch(const QUrl &url) const;
    // Recents (Go > Recents, the sidebar's first place; docs/specs/files.md "Views and selection").
    Q_INVOKABLE bool isRecents(const QUrl &url) const;
    Q_INVOKABLE QUrl recentsUrl() const;
    // Recents is sorted by when the files were last opened unless chosen otherwise for it (Finder).
    Q_PROPERTY(int recentsSortKey READ recentsSortKey CONSTANT)
    int recentsSortKey() const;
    // A spring-loaded folder replaced the view under a drag that has not moved since: the window gets its last drag
    // move again, so the new view under the pointer becomes the drop target (a drop without moving lands in the opened
    // folder, as in the Finder). Nothing happens when no drag is over `window`.
    Q_INVOKABLE void refreshDrag(QObject *window);
    Q_INVOKABLE QString searchedTag(const QUrl &url) const;

    // Search (ADR-0027, SearchLogic): a query is {valid, text, folder (a local folder URL, empty for this computer),
    // criteria: [{attribute, op, value, unit}]}, a search location its URL.
    Q_INVOKABLE bool isFileSearch(const QUrl &url) const;
    Q_INVOKABLE QVariantMap searchQuery(const QUrl &url) const;
    Q_INVOKABLE QUrl searchUrl(const QVariantMap &query) const;
    // The criteria rows' pop-ups, labels translated: [{key, label}] of the attributes; the operators of an attribute
    // [{key, label, value}] (value: "none" | "text" | "number" | "date" | "kind" | "tag"); the units of an attribute
    // [{key, label}] (days… for dates, KB… for sizes, none otherwise); the kinds [{key, label}] ("any" first).
    Q_INVOKABLE QVariantList searchAttributes() const;
    Q_INVOKABLE QVariantList searchOperators(const QString &attribute) const;
    Q_INVOKABLE QVariantList searchUnits(const QString &attribute) const;
    Q_INVOKABLE QVariantList searchKinds() const;
    // A new row for an attribute: its first operator and a usable value (Kind: any; dates: within the last 7 days).
    Q_INVOKABLE QVariantMap searchCriterion(const QString &attribute) const;
    // A date row's value is an ISO day ("2026-10-31"); the field shows it in the locale's short format and reads it back
    // from that format or ISO ("" when it is no date).
    Q_INVOKABLE QString searchDateText(const QString &iso) const;
    Q_INVOKABLE QString searchDateValue(const QString &text) const;
    Q_INVOKABLE QString searchToday() const;
    // Saved searches (the Finder's smart folders): [{name, url, sidebar, file}] by name.
    Q_PROPERTY(QVariantList savedSearches READ savedSearches NOTIFY savedSearchesChanged)
    QVariantList savedSearches() const;
    // Saves the search location `search` as `name` ("" or why not; a search of that name is replaced).
    Q_INVOKABLE QString saveSearch(const QString &name, const QUrl &search, bool sidebar);
    Q_INVOKABLE bool hasSavedSearch(const QString &name) const;
    Q_INVOKABLE void removeSavedSearch(const QString &file);
    Q_INVOKABLE void setSavedSearchInSidebar(const QString &file, bool on);

    // The Go menu (FP-75..FP-77, NavLogic). The Finder's shortcut of a sidebar place ("" for none).
    Q_INVOKABLE QString placeShortcut(const QString &kind, const QUrl &url) const;
    // The Go menu's standard places: "desktop", "documents", "downloads" (XDG user folders), "computer" (the root folder),
    // "network" (remote:/, invalid without a KIO network worker).
    Q_INVOKABLE QUrl standardFolder(const QString &which) const;
    // Go to Folder: lists the local folders matching `text` (relative text in `base`) off the GUI thread, so a slow mount
    // never freezes the window; folderCompletions(text, matches) answers the latest request only, matches
    // [{name, url, parts}] (parts: the path's folder names), at most kMaxCompletions.
    static constexpr int kMaxCompletions = 50;
    static constexpr int kMaxCompletionScan = 5000;
    Q_INVOKABLE void completeFolder(const QString &text, const QUrl &base);
    // The text once `match` completes it ("~/D" + "Downloads" -> "~/Downloads/").
    Q_INVOKABLE QString completedText(const QString &text, const QUrl &base, const QString &match) const;
    // Go to Folder's destination for the typed text (NavLogic::goToTarget): {folder, select}; a file opens its folder
    // with the file selected; an empty folder when nothing is there.
    Q_INVOKABLE QVariantMap goToTarget(const QString &text, const QUrl &base) const;
    // Go > Recent Folders and Go to Folder's list while its field is empty: the folders shown last, newest first
    // ([{url}], at most kMaxRecentFolders; local folders and servers, never a search, the Trash or Recents).
    static constexpr int kMaxRecentFolders = 10;
    Q_PROPERTY(QVariantList recentFolders READ recentFolders NOTIFY recentFoldersChanged)
    QVariantList recentFolders() const;
    Q_INVOKABLE void noteFolder(const QUrl &url);
    Q_INVOKABLE void clearRecentFolders();
    // Connect to Server (decision F-9): an address's URL (invalid: refused), the servers connected to lately and the
    // favourite servers, kept in QSettings servers/* without any password.
    static constexpr int kMaxServers = 20;
    Q_INVOKABLE QUrl serverUrl(const QString &text) const;
    Q_PROPERTY(QStringList recentServers READ recentServers NOTIFY serversChanged)
    Q_PROPERTY(QStringList favoriteServers READ favoriteServers NOTIFY serversChanged)
    QStringList recentServers() const;
    QStringList favoriteServers() const;
    Q_INVOKABLE void noteServer(const QUrl &url);
    Q_INVOKABLE bool addFavoriteServer(const QString &text);
    Q_INVOKABLE void removeFavoriteServer(int index);
    Q_INVOKABLE void clearRecentServers();
    // Remove from Sidebar (macOS): hides the tag from the sidebar's Tags section for good (tags/hidden); files keep it
    // and it stays usable. Setting that tag in Files again lists it again.
    Q_INVOKABLE void forgetTag(const QString &tag);
    // The way back: lists a tag removed from the sidebar again (Tags section's menu).
    Q_INVOKABLE void showTag(const QString &tag);

    // Sidebar Favorites (FP-27; owner report 2026-11-07, "there is no way to pin a folder in the sidebar"). Add to Sidebar
    // (File > Add to Sidebar Ctrl+Super+T, the item menu, a drag between Favorites rows): the folders among `urls` (asked of
    // KIO, never read here; a file is refused with a banner) join the user's own folders at `position` (-1: after them), a
    // standard place the user removed is listed again, one already listed stays where it is. Kept in QSettings
    // sidebar/favorites and sidebar/hidden (Files' and the Open and Save panels' sidebar).
    Q_INVOKABLE void addToSidebar(const QList<QUrl> &urls, int position = -1);
    // Remove from Sidebar: a folder of the user's leaves the list; a standard place (Home, Applications, a user folder) is
    // hidden until Add to Sidebar lists it again. The folder itself is never touched.
    Q_INVOKABLE void removeFromSidebar(const QUrl &url);
    // A folder of the user's moved to the gap `position` of their list (0: first).
    Q_INVOKABLE void moveInSidebar(const QUrl &url, int position);
    // Whether `url` is in Favorites now (Add to Sidebar is offered for the others).
    Q_INVOKABLE bool inSidebar(const QUrl &url) const;

    // Customize Folder (FolderStyleLogic, FolderStyleStore): a folder's own colour and symbol. Only local folders
    // carry one. folderStyleUnavailable() is "" when every item of `urls` is such a folder, else the reason shown in
    // place of the controls (the menu item is disabled for it).
    Q_INVOKABLE QString folderStyleUnavailable(const QList<QUrl> &urls) const;
    // {color, glyph} of one folder, read now ("" fields: none). Callers depend on folderStyleRevision.
    Q_INVOKABLE QVariantMap folderStyleOf(const QUrl &url) const;
    // Sets the look of the folders among `urls` to exactly `color` ("theme", "accent", "#rrggbb" or "" = follow the
    // global setting) and `glyph` ("" = none). Returns {ok, fellBack, error}: fellBack when a folder's volume can't
    // hold the attribute and the choice went to the per-user store (documented in docs/specs/files.md).
    Q_INVOKABLE QVariantMap applyFolderStyle(const QList<QUrl> &urls, const QString &color, const QString &glyph);
    // Back to the global colour and no symbol.
    Q_INVOKABLE QVariantMap resetFolderStyle(const QList<QUrl> &urls);
    // The shown folders' own looks follow Files' writes and the per-user store's changes.
    Q_PROPERTY(int folderStyleRevision READ folderStyleRevision NOTIFY folderStyleRevisionChanged)
    int folderStyleRevision() const { return m_folderStyleRevision; }

signals:
    // The cut items changed (listings fade them).
    void cutUrlsChanged();
    void removableTextChanged();
    void appearanceChanged();
    void undoChanged();
    void clipboardChanged();
    void prefsChanged();
    void windowSizeChanged();
    void focusWindowChanged();
    void activityChanged();
    void operationFailed(const QString &message);
    // Files wrote the tags of `urls` (every listing reads them again).
    void tagsChanged(const QList<QUrl> &urls);
    void tagRevisionChanged();
    void hiddenTagsChanged();
    // Files wrote the folder looks of `urls`; allFolderStylesChanged: the per-user store changed under us.
    void folderStylesChanged(const QList<QUrl> &urls);
    void allFolderStylesChanged();
    void folderStyleRevisionChanged();
    // A drag from another application ended over `window`: it left or was canceled (`dropped` false: what it
    // spring-loaded goes back) or was dropped there (it stays, whichever view took the drop).
    void outsideDragEnded(QObject *window, bool dropped);
    void savedSearchesChanged();
    void folderCompletions(const QString &text, const QVariantList &matches);
    void recentFoldersChanged();
    void serversChanged();
    void permissionsChanged(const QUrl &url);
    void jobsChanged();

protected:
    // Remembers the last drag move over each window (refreshDrag).
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    // `verb` ("Copying"), `sources` and `destination` (the folder they go to) name the job in the Copy window: "Copying 12
    // items to “Docs”". A job tracked without them is named by KIO's own descriptions.
    void track(KJob *job, const QString &activity, const QString &verb = QString(), const QList<QUrl> &sources = {}, const QUrl &destination = QUrl());
    // The progress window's rows (FP-68): what each tracked job did so far.
    struct JobProgress {
        quint64 id = 0;
        QString activity;
        // KIO's own words for what it does now ("Copying", "Moving", "Deleting": its translation) and on what.
        QString verb;
        QString item;
        QString destination;
        // What the user asked for (set by track() when known): the title then names these, not the file KIO copies now.
        int count = 0;
        qulonglong processed = 0;
        qulonglong total = 0;
        qulonglong speed = 0;
        int percent = -1;
    };
    QHash<KJob *, JobProgress> m_progress;
    quint64 m_nextJobId = 1;
    QTimer m_progressTimer;
    // Each job of the Copy window is also an ongoing activity in the menu bar, with Stop (ADR-0052).
    grassfield::apps::OngoingPublisher *m_ongoing = nullptr;
    void publishJobs();
    // `source`'s amounts, speed and percent are `tracked`'s (the same job, or the copy a paste runs inside).
    void followAmounts(KJob *tracked, KJob *source);
    void forwardSubjobAmounts(const QPointer<KJob> &job, int tries);
    void readAppearance();
    QString configFile() const;
    // Adds `tag` to, or removes it from, each item (TagLogic::applyTag keeps every other entry as stored); reports
    // failures; announces the changed items.
    void rewriteTags(const QList<QUrl> &urls, const QString &tag, bool on);
    void unhideTag(const QString &tag);
    // Why `url` can't be tagged, "" when it can (`support`: what TagStore found).
    QString tagsReason(const QUrl &url, TagStore::Support support) const;
    QString schemeReason(const QUrl &url) const;
    void styleMoved(const QUrl &from, const QUrl &to);
    // Every folder pair a job moved, in one call (each pair protected before any is handled); and the registration of the
    // sources while the job runs, so a prune that looks at the disk after the rename cannot drop their entries.
    void styleMovedAll(const QList<QPair<QUrl, QUrl>> &pairs);
    QStringList beginStyleMoves(const QList<QUrl> &sources);
    void endStyleMoves(const QStringList &paths);
    QVariantMap changeFolderStyles(const QList<QUrl> &urls, const FolderStyleLogic::Style &style);
    // Tags in use, for the sidebar (kept across sessions, at most kMaxKnownTags).
    void noteTags(const QStringList &tags);
    void publishKnownTags();
    // After a FolderViews write: Busy schedules another try (growing pause), Refused is logged.
    void folderViewsWritten(FolderViews::WriteResult result, const QString &error);

    QList<QUrl> m_initialUrls;
    // Before m_places: Grassfield's KIO delegate is in place before the first job (the Trash listing) starts.
    KioPrompts *m_prompts = nullptr;
    PlacesModel *m_places = nullptr;
    SavedSearches *m_savedSearches = nullptr;
    quint64 m_completionGeneration = 0;
    // Stored lists read back: valid URLs only, bounded.
    QStringList storedUrls(const QString &key, int max) const;
    void publishSavedSearches();
    QSettings m_settings;
    QFileSystemWatcher m_watcher;
    bool m_dark = true;
    bool m_autoAppearance = false;
    QTimer m_autoTimer;
    bool m_reduceMotion = false;
    bool m_increaseContrast = false;
    qreal m_textScale = 1;
    QString m_titlebarDoubleClick = QStringLiteral("zoom");
    bool m_canMinimize = true;
    QString m_accentColor = QStringLiteral("multicolor");
    QString m_accentHighlight = QStringLiteral("automatic");
    const bool m_macDevice = grassfield::apps::macDeviceHere();
    QString m_shortcutStyle = QStringLiteral("pc");
    QString m_iconMode = QStringLiteral("default");
    QString m_iconTint = QStringLiteral("accent");
    QString m_folderColor = QStringLiteral("theme");
    QString m_activity;
    int m_activityPercent = -1;
    // Commands made of several local operations (BatchOps) that are one undo step, kept by Files and ordered against KIO's
    // own commands by serial number (KIO::FileUndoManager::newCommandSerialNumber); m_redoKinds is which of the two the
    // newest undone command belongs to (true: ours), so redo goes back in the order undo went.
    struct CustomCommand {
        quint64 serial = 0;
        QString text;
        BatchOps::Steps steps;
    };
    void recordCustom(const QString &text, const BatchOps::Steps &steps);
    bool customUndoIsNext() const;
    QList<CustomCommand> m_undoCustom;
    QList<CustomCommand> m_redoCustom;
    QList<bool> m_redoKinds;
    QList<QPointer<KJob>> m_jobs;
    QList<QPointer<ArchiveJob>> m_archiveJobs;
    QVariantList m_jobList;
    void startArchiveJob(ArchiveJob *job, const QString &activity, QObject *folder);
    void archiveActivityEnded();
    QStringList m_knownTags;
    // Tags removed from the sidebar (not listed again when seen), persisted as tags/hidden.
    QStringList m_hiddenTags;
    // The items the clipboard holds cut (read on each clipboard change), told to every listing.
    QSet<QUrl> m_cutUrls;
    void readClipboardCut();
    // Favorites as the user edited them: their own folders (sidebar/favorites) and the standard places removed
    // (sidebar/hidden).
    QList<QUrl> m_sidebarFolders;
    QList<QUrl> m_sidebarHidden;
    void publishSidebar();
    // Tag state of the items asked about by the menus (selection), probed once per few seconds.
    mutable TagStore::Cache m_tagCache;
    int m_tagRevision = 0;

    // id -> .desktop path of the rows the Applications location listed last (built by a FolderModel on its thread).
    QVariantMap m_applicationPaths;
    QVariantMap m_applicationNames; // id -> the name the Applications location shows (the disambiguated one)
    QString m_removableText;
    QPointer<QProcess> m_removableProcess;
    QDateTime m_removableAt;
    FolderStyleStore m_folderStyles;
    int m_folderStyleRevision = 0;
    // Read on first use and again when it changes (the state directory may not exist before a view is chosen).
    mutable FolderViews m_folderViews;
    // The last drag move over each window (refreshDrag); dropped when the drag leaves or drops.
    struct DragState {
        QPointF position;
        Qt::DropActions actions;
        QPointer<const QMimeData> mime;
        Qt::MouseButtons buttons;
        Qt::KeyboardModifiers modifiers;
        // The drag started in Files (its end reaches the views by Drag.onDragFinished).
        bool local = false;
    };
    QHash<QObject *, DragState> m_drags;
    // Pictures are turned here, one batch at a time and in order (two turns of one picture never overlap).
    QThreadPool m_rotations;
    // A view setting that found the lock taken by another Files process is written again by this timer, never waited for
    // on the UI thread; the pause doubles from kFolderViewsRetryFirstMs up to kFolderViewsRetryMaxMs.
    QTimer m_folderViewsRetry;
    int m_folderViewsRetryMs = 0;
    // The last refusal logged: the same reason is logged once until a write succeeds (every view choice tries again).
    QString m_folderViewsRefusal;
};
