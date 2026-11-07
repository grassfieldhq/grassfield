#pragma once

#include <QDateTime>
#include <QList>
#include <QLocale>
#include <QString>
#include <QUrl>
#include <QVariant>

#include <functional>

class QCollator;

// Pure presentation logic of Grassfield Files (Qt Core only, no KIO): sort keys, size and date
// formatting, path bar segmentation and file name rules. Unit tested in tests/unit/files/.
namespace FileLogic
{

// The Finder's Sort By keys that Linux can serve (docs/specs/files.md, FP-40): Date Added has no source on Linux files.
// Date is the modification date; Opened is the last access time (kept by the file system, coarse under relatime).
enum class SortKey { Name = 0, Kind = 1, Date = 2, Size = 3, Created = 4, Opened = 5, Tags = 6, Application = 7 };
constexpr int kSortKeyCount = 8;

// The Finder's Group By (FP-39), without Date Added.
enum class GroupBy { None = 0, Name = 1, Kind = 2, Application = 3, Opened = 4, Modified = 5, Created = 6, Size = 7, Tags = 8 };
constexpr int kGroupByCount = 9;

struct SortEntry {
    QString name;
    QString kind; // MIME comment, e.g. "PNG image"
    QDateTime modified;
    QDateTime created;
    QDateTime opened;
    qint64 size = -1; // -1 for folders (unknown)
    bool isDir = false;
    // The item's tags in display order (TagLogic::displayOrder: colour keys first, in palette order).
    QStringList tags;
    // The name of the application that opens it by default, empty when none.
    QString application;
    // Its MIME type followed by every type it inherits from (the Kind groups).
    QStringList mimeTypes;
};

// Negative when a sorts before b. With foldersFirst, folders precede files in both directions.
// `descending` reverses the primary key only; ties are broken by name (ascending), then by code points. Items without
// the key's value (no tag, no application, an unknown date) come last in either direction.
int compareEntries(const SortEntry &a, const SortEntry &b, SortKey key, bool descending, bool foldersFirst, const QCollator &collator);

// What a drop of files does (Finder, with Cmd as Ctrl and Option as Alt, decision F-1): Option copies, Cmd moves, both
// make aliases (symbolic links); without a modifier a drop on the same volume moves and on another volume copies.
enum class DropAction { Move, Copy, Link };
DropAction dropAction(bool ctrl, bool alt, bool sameVolume);

// Default direction when a column is chosen: names, kinds, tags and applications ascending, dates and sizes descending.
bool defaultDescending(SortKey key);

// A group of Group By: `rank` orders the groups (lowest first), the title breaks ties (collator) and heads the group.
struct Group {
    int rank = 0;
    QString title;
};

// The Kind categories of Group By and of the search's Kind filter (Finder's kinds that Linux types can serve), matched
// against a MIME type and the types it inherits from, in that order; folders are Folder whatever their type.
enum class KindCategory { Other = 0, Folder, Pdf, Presentation, Spreadsheet, Image, Movie, Music, Application, Archive, Document };
KindCategory kindCategoryOf(const QStringList &mimeTypes, bool isDir);
// The category's plural title ("Images"; "Other" for Other).
QString kindCategoryTitle(KindCategory category);

// The group of an entry: Name by first letter ("#" for digits and symbols, first); Kind by category (Applications,
// Archives, Documents, Folders, Images, Movies, Music, PDF Documents, Presentations, Spreadsheets, then Other); Application
// by name (folders first, Other last); dates newest first (Today, Yesterday, Previous 7 Days, Previous 30 Days, the months
// of this year, then the years; Unknown last); Size largest first in decimal bands (folders last); Tags by the first tag
// (colours in palette order, then the others; No Tags last). `now` and `locale` serve the date groups.
Group groupOf(const SortEntry &e, GroupBy by, const QDateTime &now, const QLocale &locale = QLocale());

// Negative when group a comes before b.
int compareGroups(const Group &a, const Group &b, const QCollator &collator);

// Decimal (SI) sizes like the macOS file manager: "Zero bytes", "1 byte", "999 bytes", "12 KB",
// "1.23 MB", "12.3 GB", "123 TB". Negative sizes (folders) give "--".
QString formatSize(qint64 bytes, const QLocale &locale = QLocale());

// The Copy window's lines (FP-68, Finder-Copy). The title names what the user asked for and where it goes, not the file KIO
// copies at the moment: `verb` is KIO's word ("Copying"), `firstItem` the first item's name, `count` the items asked for
// (0 when unknown), `destination` the folder's name. "Copying “a.txt” to “Docs”", "Copying 12 items to “Docs”"; with no
// destination "Copying “a.txt”"; "" when there is no verb or no item to name (the caller keeps its own activity text).
QString copyTitle(const QString &verb, const QString &firstItem, int count, const QString &destination);

// "About 1 second", "About 40 seconds", "About 1 minute", "About 5 minutes" for `seconds` still to go.
QString remainingText(qulonglong seconds);

// The line under the bar: "41.9 MB of 111.6 MB – About 10 seconds" (no estimate while the speed is unknown), "Preparing…"
// while the job tells no amount yet (it is still looking through the folders to copy), else "" (a job that only counts:
// `percent` of 0..100, -1 when none).
QString copyDetail(qulonglong processed, qulonglong total, qulonglong bytesPerSecond, int percent);

// The bar's fill in percent: the bytes when the total is known, else the job's own percent; -1 when neither (the bar then
// has no fill but a sweep: indeterminate).
int copyPercent(qulonglong processed, qulonglong total, int percent);

// "Today at 14:05", "Yesterday at 09:10", otherwise "<short date> at <short time>". Invalid gives "--".
QString formatDate(const QDateTime &when, const QDateTime &now, const QLocale &locale = QLocale());

struct Segment {
    QString label;
    QUrl url;
};

// Path bar and column view segments from the first visible ancestor to `url`:
// inside the home folder the first segment is the home folder (labelled with its name),
// other local paths start at the root (`rootLabel`), trash:/ starts with `trashLabel`,
// other schemes start at "<scheme>:/".
QList<Segment> pathSegments(const QUrl &url, const QString &homePath, const QString &rootLabel, const QString &trashLabel);

// A file name as shown in a message or a label: line breaks become a return symbol and the bidirectional override,
// embedding and isolate controls are written out ("<U+202E>"). The twin of ui/Grassfield/Ui/DisplayName.js (GF-105).
QString displayName(const QString &name);

// Names that differ only by Unicode normalization (NFC "e acute" and NFD "e" + combining acute) are the same name to a
// person: macOS compares them equal (GF-105). The file system keeps them apart, so Files checks collisions with this.
bool sameName(const QString &a, const QString &b);

// The entry of `names` that is the same name as `name` to a person but not the same string (an NFC/NFD twin), or "".
// Copying, moving or dropping an item next to such a twin would make two entries that look alike (GF-105).
QString equivalentName(const QStringList &names, const QString &name);

// The original path of a trashed item from its .trashinfo (the `Path=` line of the [Trash Info] group, percent-decoded), or ""
// (no such line, or a relative path: a trash outside the home volume, left to the system).
QString trashInfoOriginalPath(const QByteArray &trashinfo);
// Whether GNOME file managers' clipboard list (x-special/gnome-copied-files: "cut" or "copy" on its first line, then the URLs)
// says the items were cut (decision F-18: a cut made in Nautilus pastes as a move in Files, and fades meanwhile).
bool gnomeCopiedFilesCut(const QByteArray &list);

// Match text for the folder filter: canonically decomposed, combining marks dropped, case folded ("resume" finds
// "Résumé.txt" in either normalization form).
QString foldForMatch(const QString &text);

// Whether `name` contains the filter text under foldForMatch.
bool nameMatchesFilter(const QString &name, const QString &filter);

// The filters of the Open and Save panels (grassfield-portal, ADR-0035 D-4): whether an item named `name`, whose MIME types are
// `mimeTypes` (its own first, then every type it inherits from), passes a filter of `globs` and `mimeRules`. A glob matches
// the whole name without regard to case (a "*.PDF" is a PDF, as the Finder sees it); a MIME rule matches the type, a type it
// inherits from, or "major/*". A filter without globs and rules passes everything.
bool passesFilter(const QString &name, const QStringList &mimeTypes, const QStringList &globs, const QStringList &mimeRules);

// A name a single file can take: not empty, not "." or "..", no '/', no NUL, at most 255 UTF-8 bytes.
bool isValidFileName(const QString &name);

// Characters to preselect when renaming: the name without its last extension; whole name for folders
// and for dot files without another dot.
int baseNameLength(const QString &name, bool isDir);

// First free name among "base", "base 2", "base 3", ... (`exists` tells whether a name is taken).
QString uniqueName(const QString &base, const std::function<bool(const QString &)> &exists);

// Name of a duplicate: "report copy.txt", then "report copy 2.txt"... `copyWord` is the translated "copy".
QString duplicateName(const QString &name, bool isDir, const QString &copyWord, const std::function<bool(const QString &)> &exists);

// Entries of KIO's Network place (remote:/) that Files does not show: the kio-extras "afc:" link to Apple mobile
// devices (an Apple trademark in its name, master-prompt §14). `item` is the entry's URL, `target` its link target.
bool hiddenNetworkEntry(const QUrl &item, const QUrl &target);

// The browser window size kept for the next window (ADR-0026 part 1, QSettings window/width and window/height): a side
// outside kMinKeptWindowSide..kMaxKeptWindowSide is never kept nor used, so a corrupt value never opens a giant or an
// invisible window (the window minimum then applies in QML, Main.qml newWindow).
constexpr int kMinKeptWindowSide = 200;
constexpr int kMaxKeptWindowSide = 16384;
// A stored side (any QSettings value): the side when it is an integer in bounds, else 0 (none kept).
int keptWindowSide(const QVariant &value);
// Whether a window of this size is kept (both sides in bounds).
bool keepsWindowSize(int width, int height);

} // namespace FileLogic
