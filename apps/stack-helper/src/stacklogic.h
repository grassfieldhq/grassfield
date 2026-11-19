#pragma once

// The logic of grassfield-stack-helper (ADR-0025), Qt Core only so that it can be unit tested: the order of a folder stack, the
// bounded window of its first entries, the scan of a folder (readdir and statx, an entry that vanishes is skipped), and the
// line the helper writes. The Name order is Files' by construction: FileLogic::compareEntries (apps/files/src/filelogic.cpp,
// compiled in as it is) with the QCollator that FolderModel sets up.

#include "filelogic.h"

#include <QByteArray>
#include <QCollator>
#include <QList>
#include <QString>

#include <functional>
#include <vector>

namespace StackLogic
{

enum class Sort { Name, DateAdded, DateModified, DateCreated, Kind };

// "name", "dateAdded", "dateModified", "dateCreated", "kind".
bool parseSort(const QString &text, Sort *out);

// The user's locale (the C locale replaced by en_US, which has no numeric mode), numeric, case insensitive: as FolderModel.
QCollator makeCollator();

struct Entry {
    QByteArray raw; // the name as the file system has it (what stat is given)
    FileLogic::SortEntry se; // name (decoded; U+FFFD for bytes that are not UTF-8), isDir
    double modified = 0; // seconds
    double added = 0; // the inode's change time, or the birth time when later (Linux has no "date added")
    double created = 0; // the birth time, the modification time where the file system has none
    QString kind; // the Kind key: "" for a folder, the lower-case extension, "~" without one
};

// Negative when a goes before b in the stack's order: Name (Files' order), the three dates newest first, Kind (folders first, then
// by extension); ties by name as Files breaks them (the collator, then the raw names).
int compare(const Entry &a, const Entry &b, Sort sort, const QCollator &collator);

// The Kind key of a name.
QString kindKey(const QString &name, bool isDir);

// The first `limit` entries in the order of `sort`, kept sorted, one comparison for an entry that is not among them.
class Window
{
public:
    Window(Sort sort, int limit, const QCollator *collator);
    void setLimit(int limit);
    void setSort(Sort sort);
    void clear();
    // True when the entry is now in the window.
    bool offer(const Entry &entry);
    bool remove(const QByteArray &raw);
    bool contains(const QByteArray &raw) const;
    const std::vector<Entry> &entries() const { return m_entries; }
    int limit() const { return m_limit; }
    Sort sort() const { return m_sort; }
    bool full() const { return int(m_entries.size()) >= m_limit; }

private:
    Sort m_sort;
    int m_limit;
    const QCollator *m_collator;
    std::vector<Entry> m_entries;
};

// Test hook: called with each entry's name just before it is stat'ed (a test deletes files from it).
using BeforeStat = std::function<void(const QByteArray &)>;

// What a scan read: the number of entries listed (hidden names are not entries, one that vanishes is skipped).
struct ScanResult {
    qint64 total = 0;
    bool ok = false; // the folder could be opened
    // false when an entry of the window kept vanishing for four scans in a row: the window is not trustworthy, keep the old one
    bool complete = false;
    // the visible sub-folders (at most kMaxDirs) in the date orders, whose own dates move with what is created and removed inside
    std::vector<QByteArray> dirs;
    // more sub-folders than kMaxDirs: the ones past the cap are not in `dirs` and are not watched
    bool dirsOverflow = false;
};
constexpr size_t kMaxDirs = 1000;

// Reads the folder at `dir`: every name that does not start with a dot, links not followed, birth time from statx. Fills `window`
// (cleared first) with the first entries of its order. Name and Kind need no stat per entry (the type comes with readdir); the
// date orders stat every entry. An entry that vanishes before its statx is skipped and the scan goes on; the entries of the window
// are stat'ed once more at the end (dates for Name and Kind), and a vanished one makes the scan run again.
ScanResult scanFolder(const QByteArray &dir, Window *window, const BeforeStat &beforeStat = {});

// Fills the dates and the type of `raw` in `dir` by statx (links not followed). False when it is gone.
bool statEntry(const QByteArray &dir, const QByteArray &raw, Entry *entry);

// One line of the helper's output for a window: "W", the total, the entries, fields separated by US (0x1f), no line break inside
// (names are escaped, escapeName).
QByteArray encodeWindow(qint64 sequence, qint64 total, const std::vector<Entry> &entries);
// A name as the file system has it, written so that it can be told back byte for byte (audit F22): valid UTF-8 as it is, but
// backslash, line break, return and US as \\, \n, \r and \u, and each byte that is not part of valid UTF-8 as \xHH (two
// lower-case hex digits). A name that is not UTF-8 (a Latin-1 name from an old disk) then names its file again: the shell shows
// U+FFFD for each such byte and opens the file through a file: URI whose escapes are those bytes.
QByteArray escapeName(const QByteArray &raw);
// The folder of the command line: an absolute path, or a file: URI whose escapes are taken as bytes (the shell's way to name a
// folder whose name is not UTF-8). "" when it is neither.
QByteArray folderArgument(const QByteArray &argument);

} // namespace StackLogic
