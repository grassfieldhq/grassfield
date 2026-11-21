// The store of Grassfield Memos (ADR-0051 D-3): one JSON file, private, written atomically, migrated forward only.
//
//   $XDG_DATA_HOME/grassfield/memos/memos.json   (~/.local/share/grassfield/memos when XDG_DATA_HOME is empty or relative)
//   {"schema": 1, "memos": [{"id", "color", "html", "width", "height", "x", "y", "collapsed", "translucent",
//                            "created", "modified"}]}
//
// Rules (the mechanism of Project Luma's sticky-notes store, Apache-2.0, reimplemented; no code copied):
//   * the directory is 0700 and the file 0600, re-asserted at every open and every write;
//   * a write goes through QSaveFile (temporary file, flush, rename): a reader sees the old file or the new one, never half;
//   * a file at an older schema is migrated in memory step by step, its original kept once beside it; a file at a newer
//     schema is refused and never rewritten (the store is read only until a newer Memos runs);
//   * a file that is not a JSON object is set aside (memos.json.unreadable-<time>) and the store starts empty;
//   * no memo text ever reaches a log or an error string: messages name the file, the schema or an id.
// Plain Qt Core: the app links it, and so do the unit tests (tests/unit/memos/tst_memostore.cpp).
#pragma once

#include <QDateTime>
#include <QJsonObject>
#include <QList>
#include <QLockFile>
#include <QString>
#include <QStringList>

#include <functional>
#include <map>
#include <memory>

namespace memos {

// The schema this build reads and writes.
inline constexpr int kSchema = 1;
// A larger file is refused (read only), as an I/O error is.
inline constexpr qint64 kMaxFileBytes = 16 * 1024 * 1024;
// The sides a memo may have (the window minimum is the QML's; this only keeps nonsense out of the file).
inline constexpr int kMinSide = 60;
inline constexpr int kMaxSide = 16384;

// The six paper colours, in Color menu order; the first is the default.
QStringList colorNames();
bool isColorName(const QString &name);
QString defaultColor();

// A new random id: 32 lowercase hex digits.
QString newId();
bool isId(const QString &id);

struct Memo
{
    QString id;
    QString color;
    QString html;
    int width = 0;
    int height = 0;
    bool hasPosition = false;
    int x = 0;
    int y = 0;
    bool collapsed = false;
    bool translucent = false;
    QDateTime created;
    QDateTime modified;

    QJsonObject toJson() const;
    // A memo from a file's entry, checked and repaired (an id, a colour, sides in range); `defaultWidth`/`defaultHeight` stand
    // in for missing sides.
    static Memo fromJson(const QJsonObject &o, int defaultWidth, int defaultHeight);
    bool operator==(const Memo &other) const;
};

// What opening the store found.
enum class OpenState {
    Ok,         // read (or no file yet): writes allowed
    Migrated,   // read at an older schema, migrated and written back; the original kept as memos.json.schema-<n>
    SetAside,   // not a JSON object: kept as memos.json.unreadable-<time>, the store starts empty, writes allowed
    Newer,      // a newer schema: refused, read only, the file untouched
    Unreadable, // an I/O error or a file above kMaxFileBytes: read only, the file untouched
};

// Why the last write failed (MemoStore::writeFailure): the app turns it into the sentence the memos show (MemosApp::saveError).
enum class WriteFailure {
    None,
    TooLarge, // the memos would pass kMaxFileBytes (the file open() would refuse): nothing written
    NoSpace,  // the disk (or the user's quota) is full
    ReadOnly, // the file system is mounted read only
    Denied,   // the directory or the file cannot be written (permissions)
    Other,    // any other I/O error
};

// The store's lock (M4 of the 2026-11 audit): `memos.lock` in the store directory, held for the process's life, so two
// Memos processes never both rewrite the file (the D-Bus single-instance name is not there without a session bus). A lock
// left by a process that is gone (a crash, a SIGKILL) is stale and taken over. Returns null when another live process
// holds it; `holder` then names that process's pid.
std::unique_ptr<QLockFile> lockStore(const QString &dir, qint64 *holder = nullptr);

// One forward step: the document of schema n (the key) made into schema n + 1. A step returns false when it cannot.
using Migrations = std::map<int, std::function<bool(QJsonObject &)>>;
// The steps of the real schemas (none yet: schema 1 is the first).
const Migrations &migrations();

class MemoStore
{
public:
    // `dir` is the store's directory (dataDir() in the app). `schema` and `steps` are the target schema and the steps that
    // lead to it (the tests inject a schema 2 and its step).
    explicit MemoStore(const QString &dir, int schema = kSchema, const Migrations &steps = migrations());

    // $XDG_DATA_HOME/grassfield/memos (or ~/.local/share/grassfield/memos).
    static QString dataDir();
    static QString dataDir(const QString &xdgDataHome, const QString &home);

    // Makes the directory (0700), reads the file. Never writes except for a migration or a set-aside.
    OpenState open(int defaultWidth, int defaultHeight);
    OpenState state() const { return m_state; }
    bool readOnly() const { return m_state == OpenState::Newer || m_state == OpenState::Unreadable; }
    // The memos read, oldest first.
    const QList<Memo> &memos() const { return m_memos; }

    // Writes these memos (atomically, 0600); false when read only or on an error (errorString(), no memo text).
    bool save(const QList<Memo> &memos);
    QString errorString() const { return m_error; }
    WriteFailure writeFailure() const { return m_failure; }

    QString filePath() const;
    QString dir() const { return m_dir; }
    int foundSchema() const { return m_foundSchema; }

    // The directory 0700 and the file (when it exists) 0600; called by open() and save().
    void assertPrivate() const;

    // Tests only: called once the temporary file is written and flushed, before its rename; false makes the write fail there
    // (the old file must stay). The tests also read the temporary file's mode from it.
    void setBeforeCommitHook(std::function<bool()> hook) { m_beforeCommit = std::move(hook); }
    void injectWriteFault(bool fault)
    {
        if (fault)
            m_beforeCommit = [] { return false; };
        else
            m_beforeCommit = nullptr;
    }

private:
    bool writeDocument(const QJsonObject &doc);
    WriteFailure classify(qint64 bytes) const;
    bool keepCopy(const QString &suffix, const QByteArray &bytes);

    QString m_dir;
    int m_schema;
    Migrations m_steps;
    OpenState m_state = OpenState::Ok;
    int m_foundSchema = 0;
    QList<Memo> m_memos;
    QString m_error;
    WriteFailure m_failure = WriteFailure::None;
    std::function<bool()> m_beforeCommit;
};

} // namespace memos
