#pragma once

#include "diskprobe.h"
#include "volumelogic.h"

#include <QAbstractListModel>
#include <QDBusMessage>
#include <QFileSystemWatcher>
#include <QHash>
#include <QSet>
#include <QTimer>
#include <QList>
#include <QStringList>
#include <QUrl>


// Sidebar entries: Favorites (Home, Applications, the standard user folders that exist), Locations (the system volume and
// Solid storage volumes, Network only when a KIO smb/sftp worker is installed, Trash) and Tags (the tags in use,
// FilesApp: colour tags first; a tag entry has no URL of its own, the sidebar searches it in the shown folder).
// Mount and eject go through Solid::StorageAccess (udisks2 + polkit); nothing is mounted by hand. Solid leaves out the other
// internal drives' filesystems (and any not mounted): those come from udisks2 itself (VolumeLogic: label or size name,
// no swap, EFI, recovery or the system's own mounts), and a click mounts them with udisks2's Filesystem.Mount (polkit asks
// through the session's agent when the disk is a system one). Nothing is formatted, partitioned or written. Whether each standard
// folder exists is asked off the GUI thread (DiskProbe, ADR-0035 4b-18): the list comes at once, a folder that is not there
// leaves it when the disk answers, and one that does not answer is listed dimmed ("unavailable"), as the Finder shows a
// server that went away, until its read returns (DiskProbe::answeredLate); Files and grassfield-portal's panels never wait on
// a hung mount for their sidebar.
class PlacesModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(bool trashEmpty READ trashEmpty NOTIFY trashEmptyChanged)
    Q_PROPERTY(bool networkAvailable READ networkAvailable CONSTANT)
    // Favorites editing (FP-27): the row where the user's own folders start (right after the standard places, also when
    // there are none) and how many there are.
    Q_PROPERTY(int firstPinnedRow READ firstPinnedRow NOTIFY favoritesChanged)
    Q_PROPERTY(int pinnedCount READ pinnedCount NOTIFY favoritesChanged)

public:
    enum Roles {
        SectionRole = Qt::UserRole + 1,
        NameRole,
        UrlRole,
        IconNameRole,
        KindRole,
        UdiRole,
        MountedRole,
        EjectableRole,
        BusyRole,
        // Tag entries: the stored tag and its palette index (-1 for a tag without a colour).
        TagRole,
        TagColorRole,
        // A standard folder whose disk does not answer (a hung mount): listed, dimmed.
        UnavailableRole,
    };
    Q_ENUM(Roles)

    // `disk`: how the standard folders are asked about (the tests give a slow disk).
    explicit PlacesModel(QObject *parent = nullptr, const DiskProbe::Options &disk = {});

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    bool trashEmpty() const { return m_trashEmpty; }
    bool networkAvailable() const;
    int firstPinnedRow() const { return m_firstPinnedRow; }
    int pinnedCount() const { return int(m_pinned.size()); }

    // Row whose URL is `url` or its closest ancestor among the entries (for the sidebar highlight), else -1.
    Q_INVOKABLE int rowForUrl(const QUrl &url) const;
    // Mount an unmounted volume; mounted(url) follows on success, error(message) on failure.
    Q_INVOKABLE void mount(int row);
    // Unmount (and eject when the drive supports it) a removable volume.
    Q_INVOKABLE void eject(int row);

    // The udisks2 volumes Solid does not list (the tests and PlacesModel's own read of the bus give them).
    void setUdisksVolumes(const QList<VolumeLogic::Volume> &volumes);
    // The tree udisks2 returned, filtered by VolumeLogic::volumes.
    void setUdisksTree(const VolumeLogic::ObjectMap &tree);

    // The Tags section (stored tag names, display order).
    void setTags(const QStringList &tags);
    // Saved searches shown in Favorites (the Finder's smart folders added to the sidebar): {name, search location, file}.
    struct SavedSearch {
        QString name;
        QUrl url;
        QString file;
    };
    void setSavedSearches(const QList<SavedSearch> &searches);
    // Favorites as the user edited them (NavLogic's lists): their own folders ("pinned" places, after the standard ones, in
    // this order) and the standard places they removed (Home, Applications, a user folder: by URL).
    void setFavorites(const QList<QUrl> &pinned, const QList<QUrl> &hidden);
    // Whether `url` is listed in Favorites now (a standard place not removed, or a folder of the user's).
    bool inFavorites(const QUrl &url) const;
    // Whether a change the trash watch reported at `path` is one of the trash itself (the home trash's files folder, the Trash
    // folder that holds it, KIO's record trashrc), which the listings of trash:/ follow; a change elsewhere in the configuration
    // folder (watched only for trashrc being replaced) is not.
    static bool trashListingPath(const QString &path, const QString &trashFiles, const QString &trashStatus);

signals:
    void trashEmptyChanged();
    // The home trash or KIO's record of the trashes changed (a debounced watch; never in a dev session): the listings of
    // trash:/ list it again (FolderModel::trashChanged).
    void trashChanged();
    void favoritesChanged();
    void mounted(const QUrl &url);
    void error(const QString &message);

private slots:
    // udisks2's ObjectManager and Properties signals: a disk came, went, mounted or unmounted (event driven, no polling).
    void onUdisksSignal(const QDBusMessage &message);

private:
    struct Place {
        QString section; // "recents" | "favorites" | "locations" | "tags"
        QString name;
        QUrl url;
        QString iconName;
        QString kind; // "recents" | "folder" | "applications" | "pinned" | "savedSearch" | "volume" | "network" | "trash" | "tag"
        QString udi;
        bool mounted = true;
        bool ejectable = false;
        bool busy = false;
        QString tag;
        int tagColor = -1;
        bool unavailable = false;
        bool udisks = false; // listed from udisks2 (VolumeLogic), mounted through its Filesystem.Mount
        bool operator==(const Place &o) const
        {
            return section == o.section && name == o.name && url == o.url && iconName == o.iconName && kind == o.kind && udi == o.udi
                && mounted == o.mounted && ejectable == o.ejectable && busy == o.busy && tag == o.tag && tagColor == o.tagColor
                && unavailable == o.unavailable && udisks == o.udisks;
        }
    };
    // Which entry a row is (its section, kind, URL, tag, device): kept across lists, so a new list is applied as the rows that
    // came, went, moved or changed (audit F18), never as a reset: the sidebar keeps its delegates, hover and drop target.
    static QString identity(const Place &p);
    void apply(const QList<Place> &places);

    // The list again, then the standard folders asked about.
    void rebuild();
    // The list from what is known of the standard folders (no disk read).
    void relist();
    void setBusy(const QString &udi, bool busy);
    // Asks udisks2 for its objects (asynchronously; no udisks2 on the bus leaves the list as it is) and relists.
    void refreshUdisks();
    void mountUdisks(const QString &path);
    QList<Place> devicePlaces();

    QList<Place> m_places;
    QStringList m_tags;
    QList<SavedSearch> m_savedSearches;
    QList<QUrl> m_pinned;
    QList<QUrl> m_hidden;
    int m_firstPinnedRow = 0;
    // The Trash's full or empty state without listing it (a listing of trash:/ in every Files and panel process held every
    // item of the Trash): KIO's own record ([Status] Empty of trashrc, which kio_trash keeps for every trash folder) and the
    // home trash's files folder (a tool that bypasses KIO), read on a worker when either changes.
    QFileSystemWatcher m_trashWatcher;
    QTimer m_trashTimer;
    // Throttles trashChanged (the listings of trash:/), started only by a change of the trash itself (trashListingPath).
    QTimer m_trashListTimer;
    QString m_trashStatus;
    QString m_trashFiles;
    void checkTrash();
    void setTrashEmpty(bool empty);
    bool m_trashEmpty = true;
    DiskProbe m_disk;
    // What the disk last said of each standard folder (DiskProbe kinds); a folder not asked yet is listed.
    QHash<QString, int> m_folderKinds;
    QSet<int> m_folderTokens;
    QList<VolumeLogic::Volume> m_udisks;
    QTimer m_udisksTimer;
    bool m_udisksFake = false; // GRASSFIELD_FILES_FAKE_VOLUMES (dev session only): a file, no bus
};
