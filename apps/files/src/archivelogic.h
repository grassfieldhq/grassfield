#pragma once

#include <QByteArray>
#include <QString>
#include <QStringList>

#include <functional>
#include <optional>

// Compress and Expand (ADR-0029, docs/specs/files.md FP-59, decision F-8): the Finder's names and bsdtar's command
// lines. Pure (ArchiveJob runs them); unit-tested in tests/unit/files/tst_archive.cpp.
namespace ArchiveLogic
{

// Whether Files expands a file of this name (zip, tar, tar.gz/tgz, tar.bz2/tbz2, tar.xz/txz, tar.zst/tzst, 7z).
bool isArchive(const QString &name);
// The name without its archive extension ("photos.tar.gz" -> "photos"); the name itself when it has none.
QString stripArchiveExtension(const QString &name);

// Compress's archive: "<name>.zip" for one item, "Archive.zip" for several; " 2", " 3"… while taken (`exists`).
QString compressName(const QStringList &names, const std::function<bool(const QString &)> &exists);
// Expand's result: one top-level item keeps its name, several go into a folder named after the archive; " 2"… while taken.
QString expandName(const QString &archiveName, const QStringList &topLevel, const std::function<bool(const QString &)> &exists);

// bsdtar's argument lists (ADR-0029). Compress: zip format, each name as "./name" (an operand starting with '@' is
// read as an archive to copy, even after "--"), stored without the "./" (-s with S: symbolic link targets untouched),
// links stored as links. Expand: no owner, ACL, flag or xattr from the archive, and no setuid, setgid or sticky bit
// (--no-same-permissions; the members' read, write and execute bits stay, less the umask: ArchiveJob copies the archive's
// download marks onto every extracted file, so a program from a downloaded archive still asks before it runs); never -P
// (bsdtar then refuses absolute members and ".." components). List: the verbose listing, for the size budget.
QStringList compressArgs(const QString &archivePath, const QString &folder, const QStringList &names);
QStringList expandArgs(const QString &archivePath, const QString &intoFolder);
QStringList listArgs(const QString &archivePath);

// The members' total size from `bsdtar -tvf`'s listing (its fifth column), or nothing when a line can't be read.
std::optional<qint64> listedSize(const QString &listing);

// The same count, fed the listing as it comes (audit F4): nothing of it is kept but the line being read, so an archive of
// any number of members, listed for as long as it takes, is counted in constant memory. A line longer than kMaxLine (only a
// member name could make it) makes the size unknown, as an unreadable line does.
class ListingTally
{
public:
    static constexpr int kMaxLine = 64 * 1024;
    void feed(const QByteArray &chunk);
    // The last line, when the listing does not end with a newline.
    void finish();
    std::optional<qint64> total() const { return m_known ? std::optional<qint64>(m_total) : std::nullopt; }
    qint64 entries() const { return m_entries; }

private:
    void line(const QByteArray &text);
    QByteArray m_partial;
    qint64 m_total = 0;
    qint64 m_entries = 0;
    bool m_known = true;
    bool m_skipping = false;
};

// What a failed bsdtar said, for the user: a password-protected archive, else the tool's own first line.
enum class Failure { Other = 0, Encrypted };
Failure failureOf(const QString &stderrText);

} // namespace ArchiveLogic
