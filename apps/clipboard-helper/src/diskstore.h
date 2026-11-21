// The clipboard stores on disk (ADR-0034 §5): $XDG_STATE_HOME/grassfield/clipboard/pinned (always) and .../history (opt-in).
// Each is a directory (0700) holding index.json and one <id>.item per item (0600). Read only with bounds: the directory and
// every file must belong to the user, not be links, have exactly these modes and sizes; a directory or an index that breaks a
// rule makes the whole store deleted, an item file that does only that item. Files are written atomically (QSaveFile) and
// explicitly 0600 whatever the umask.
#pragma once

#include "cliplogic.h"

#include <QByteArray>
#include <QList>
#include <QString>

class DiskStore
{
public:
    explicit DiskStore(const QString &dir);

    enum class Status { Empty, Loaded, Deleted, Newer };
    struct Loaded {
        Status status = Status::Empty;
        QList<ClipLogic::Item> items;
        int dropped = 0; // item files that broke a rule (deleted)
        int orphans = 0; // the store's files the index does not name (deleted)
    };
    Loaded load();

    // Writes the item's file (if absent) and the index of `items` (the store's whole content). False on any failure.
    bool save(const ClipLogic::Item &item, const QList<ClipLogic::Item> &items);
    bool saveIndex(const QList<ClipLogic::Item> &items);
    bool removeItem(const QByteArray &id, const QList<ClipLogic::Item> &items);
    // The item's file alone (written again when `rewrite`, else only if absent) / removed alone: the caller writes the index once
    // for a whole change (the history's: a copy and the items it pushes out, the switch turned on with 100 items), not once per
    // file. A file the index does not name yet is an orphan if the helper ends before: deleted at the next load.
    bool saveItemFile(const ClipLogic::Item &item, bool rewrite = false);
    bool removeItemFile(const QByteArray &id);
    // Deletes the store's own files (index.json, *.item and their temporary files) and the directory; never follows a link.
    void deleteAll();
    bool readOnly() const { return m_readOnly; }
    QString dir() const { return m_dir; }

    // The clears last carried out (ClipLogic::clearAction): <stateDir>/clears, "GFCLEARS1 <history ms> <pinned ms>\n", 0600, read
    // with the stores' rules (the user's regular file, not a link, that mode, a few bytes). `known` is false when it is missing
    // or breaks a rule (such a file is deleted).
    struct Clears {
        qint64 history = 0;
        qint64 pinned = 0;
        bool known = false;
    };
    static Clears readClears(const QString &stateDir);
    static bool writeClears(const QString &stateDir, const Clears &clears);

    // Item files (exposed for tests).
    static QByteArray encodeItem(const ClipLogic::Item &item);
    static bool decodeItem(const QByteArray &bytes, ClipLogic::Kind kind, ClipLogic::Item *item);
    static bool validId(const QByteArray &id);
    static constexpr qint64 kMaxIndexBytes = 1024 * 1024;
    static constexpr qint64 kMaxItemBytes = ClipLogic::kImageCap + 4096;

private:
    bool ensureDir();
    bool writeFile(const QString &name, const QByteArray &bytes);
    QString m_dir;
    bool m_readOnly = false; // an index of a newer version, or a store that could not be opened: left as it is, never written
};
