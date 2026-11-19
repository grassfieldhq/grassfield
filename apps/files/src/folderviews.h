#pragma once

#include <QByteArray>
#include <QHash>
#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QUrl>

// Per-folder view settings (docs/specs/files.md FP-14, decision F-3): the view and the arrangement the user chose for a
// folder, kept in a per-user state file keyed by the folder's URL (`files-views.json` in the Grassfield state directory,
// 0600, written atomically). Files never writes into the folder itself (macOS keeps these in `.DS_Store`): read-only,
// remote, Trash and search locations work alike and other applications never see a stray file. At most kMaxEntries
// folders and kMaxFileSize bytes; the least recently set folders are dropped first. Several Files processes share the
// file: reads follow its changes, and each write takes a lock, reads the file again and merges into it.
//
// The file is read like the shell's settings store (shell/store/SettingsStore.qml): never opened unless the path leads to
// a regular file (a FIFO would block the UI thread in open(), a device such as /dev/zero would never end), at most
// kMaxFileSize + 1 bytes read, and used only when the read returned exactly the size the file had. A change on disk is
// noticed by the signature of what the path leads to: device, inode, size, mode and modification time (to the nanosecond).
//
// Nothing here waits for another process: a write that finds the lock taken stays pending (entry() already reads it) and
// flush() writes it later (FilesApp retries on a timer); only the final flush at exit waits, briefly.
class FolderViews
{
public:
    // A field that was never set for the folder reads as unset: the folder then uses the defaults.
    struct Entry {
        QString mode;        // icons | list | columns | gallery; empty: unset
        int sortKey = -1;    // FileLogic::SortKey (0 name, 1 kind, 2 date modified, 3 size, 4 created, 5 opened, 6 tags, 7 application); -1: unset
        int descending = -1; // 0 or 1; -1: unset
        int groupBy = -1;    // FileLogic::GroupBy (0: no groups); -1: unset

        bool isEmpty() const { return mode.isEmpty() && sortKey < 0 && descending < 0 && groupBy < 0; }
        bool operator==(const Entry &o) const
        {
            return mode == o.mode && sortKey == o.sortKey && descending == o.descending && groupBy == o.groupBy;
        }
    };

    // What the path leads to, as stat() sees it (a symlink is followed). Two equal signatures: the file did not change.
    struct Signature {
        int error = -1; // 0: the fields below are valid; else the errno of stat() (ENOENT: missing); -1: never looked at
        quint64 device = 0;
        quint64 inode = 0;
        qint64 size = 0;
        qint64 mtimeSec = 0;
        qint64 mtimeNsec = 0;
        // Type and permission bits: a file made readable again (chmod) is read again although its contents did not change.
        quint32 mode = 0;

        bool operator==(const Signature &o) const
        {
            return error == o.error && device == o.device && inode == o.inode && size == o.size && mtimeSec == o.mtimeSec
                && mtimeNsec == o.mtimeNsec && mode == o.mode;
        }
        bool operator!=(const Signature &o) const { return !(*this == o); }
    };

    // How the last load() found the file.
    enum class ReadStatus {
        Missing,    // no file: no entries, writable
        Ok,         // read in full and understood
        NotRegular, // a FIFO, a device, a directory, a socket (never opened)
        TooLarge,   // more than kMaxFileSize bytes (never read in full)
        Unreadable, // stat, open or read failed
        Incomplete, // the read did not return the size the file had (it changed while it was read)
        Invalid,    // not JSON this version can read back: malformed, a newer version, a `folders` value that is not a list
    };

    // The outcome of a write.
    enum class WriteResult {
        Written, // the file holds every change made so far
        Busy,    // another Files process holds the lock: the changes stay pending for flush()
        Refused, // the file cannot be written (the reason in `error`): the changes stay pending for a later write
    };

    static constexpr int kVersion = 1;
    static constexpr int kMaxEntries = 2000;
    // A larger file is refused as broken (never parsed, never overwritten); a write drops old folders to stay under it.
    static constexpr qint64 kMaxFileSize = 2 * 1024 * 1024;

    explicit FolderViews(const QString &file);

    QString file() const { return m_file; }
    // Reads the file again. Missing: no entries. Not a regular file, too large, not read completely, unparsable, a
    // `folders` value that is not a list, or written by a newer version: no entries and read-only until a later read
    // finds it usable (a file this version cannot read back is never overwritten).
    void load();
    // Reads the file again when its signature changed since it was last read (another Files process wrote it): one
    // stat() when nothing changed.
    void refresh();
    bool readOnly() const { return m_readOnly; }
    ReadStatus readStatus() const { return m_status; }
    // The folders stored in the file as last read or written (pending changes not counted).
    int count() const { return int(m_order.size()); }
    // The folder's settings: as stored, with the changes not written yet over them.
    Entry entry(const QString &key) const;
    // Merges the set fields of `fields` into the folder's entry (other keys of the entry are kept, a newer version's
    // fields too), makes it the most recently set and writes the file at once when the lock is free, dropping the oldest
    // folders past kMaxEntries or kMaxFileSize. Never waits for the lock: Busy keeps the change pending for flush().
    WriteResult set(const QString &key, const Entry &fields, QString *error = nullptr);
    // The same change kept pending only (entry() reads it at once): flush() writes it later. FilesApp writes a view or sort
    // click this way, after the click's frame and once for a burst of clicks.
    void keep(const QString &key, const Entry &fields);
    // Writes the pending changes (merged into the file as it is on disk now). `waitMs`: how long to wait for another
    // process's lock (0: not at all; only the exit flush waits).
    WriteResult flush(QString *error = nullptr, int waitMs = 0);
    bool hasPending() const { return !m_pendingOrder.isEmpty(); }

    // The key of a location: its URL with a trailing slash removed and "." / ".." segments resolved, fully encoded (the
    // query of a search location is kept). Empty for an invalid or empty URL.
    static QString keyFor(const QUrl &url);
    // One stored entry from JSON; invalid fields read as unset.
    static Entry parse(const QJsonObject &object);
    static QJsonObject serialize(const QString &key, const Entry &entry);
    // The fields of `fields` that are set, over `base`.
    static Entry merged(const Entry &base, const Entry &fields);
    // The signature of `path` now (stat, following a symlink).
    static Signature signatureOf(const QString &path);
    // Reads `path` the bounded way described above. On Ok, `bytes` holds the whole file; `signature` is what was read
    // (or what stat() saw when nothing was read).
    static ReadStatus readFile(const QString &path, QByteArray *bytes, Signature *signature);

private:
    QByteArray serialized() const;
    bool save(QString *error);
    void dropOldest(qsizetype count);

    QString m_file;
    // The stored objects (with keys this version does not know), by folder key.
    QHash<QString, QJsonObject> m_entries;
    // Keys from the least to the most recently set.
    QStringList m_order;
    // Changes not written yet: the fields set per folder, and the folders from the least to the most recently set.
    QHash<QString, Entry> m_pending;
    QStringList m_pendingOrder;
    bool m_readOnly = false;
    bool m_loaded = false;
    ReadStatus m_status = ReadStatus::Missing;
    Signature m_signature;
};
