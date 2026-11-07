// Unit tests for apps/files/src/filelogic.{h,cpp} (gtest). Built and run by scripts/dev/test.sh.
#include "filelogic.h"

#include <QCollator>
#include <QSet>

#include <gtest/gtest.h>

using namespace FileLogic;

namespace
{
QCollator naturalCollator()
{
    // The C locale collator has no numeric mode; the app also falls back to English for it.
    QCollator c(QLocale(QLocale::English, QLocale::UnitedStates));
    c.setNumericMode(true);
    c.setCaseSensitivity(Qt::CaseInsensitive);
    return c;
}

SortEntry file(const QString &name, qint64 size = 0, const QString &kind = QStringLiteral("Text"), const QDateTime &modified = {})
{
    SortEntry e;
    e.name = name;
    e.size = size;
    e.kind = kind;
    e.modified = modified;
    return e;
}

SortEntry folder(const QString &name)
{
    SortEntry e;
    e.name = name;
    e.isDir = true;
    e.kind = QStringLiteral("Folder");
    return e;
}

QStringList labels(const QList<Segment> &segments)
{
    QStringList out;
    for (const Segment &s : segments)
        out << s.label;
    return out;
}

QStringList urls(const QList<Segment> &segments)
{
    QStringList out;
    for (const Segment &s : segments)
        out << s.url.toString();
    return out;
}
} // namespace

TEST(SortKeys, NameIsNaturalAndCaseInsensitive)
{
    const QCollator c = naturalCollator();
    EXPECT_LT(compareEntries(file("file2"), file("file10"), SortKey::Name, false, false, c), 0);
    EXPECT_LT(compareEntries(file("apple"), file("Banana"), SortKey::Name, false, false, c), 0);
    EXPECT_GT(compareEntries(file("apple"), file("Banana"), SortKey::Name, true, false, c), 0);
}

TEST(SortKeys, FoldersFirstInBothDirections)
{
    const QCollator c = naturalCollator();
    EXPECT_LT(compareEntries(folder("zeta"), file("alpha"), SortKey::Name, false, true, c), 0);
    EXPECT_LT(compareEntries(folder("zeta"), file("alpha"), SortKey::Name, true, true, c), 0);
    // Without the option folders sort with files.
    EXPECT_GT(compareEntries(folder("zeta"), file("alpha"), SortKey::Name, false, false, c), 0);
}

TEST(SortKeys, SizeDateKindWithNameTieBreak)
{
    const QCollator c = naturalCollator();
    EXPECT_LT(compareEntries(file("b", 10), file("a", 20), SortKey::Size, false, false, c), 0);
    EXPECT_GT(compareEntries(file("b", 10), file("a", 20), SortKey::Size, true, false, c), 0);
    // Equal size: name ascending even when descending.
    EXPECT_LT(compareEntries(file("a", 10), file("b", 10), SortKey::Size, true, false, c), 0);

    const QDateTime older(QDate(2026, 1, 1), QTime(10, 0));
    const QDateTime newer(QDate(2026, 6, 1), QTime(10, 0));
    EXPECT_LT(compareEntries(file("x", 0, "Text", older), file("y", 0, "Text", newer), SortKey::Date, false, false, c), 0);
    EXPECT_LT(compareEntries(file("y", 0, "Text", newer), file("x", 0, "Text", older), SortKey::Date, true, false, c), 0);

    EXPECT_LT(compareEntries(file("z", 0, "Image"), file("a", 0, "Text"), SortKey::Kind, false, false, c), 0);
    EXPECT_LT(compareEntries(file("a", 0, "Text"), file("b", 0, "Text"), SortKey::Kind, false, false, c), 0);
}

TEST(SortKeys, TotalOrderForCaseVariants)
{
    const QCollator c = naturalCollator();
    const int ab = compareEntries(file("Readme"), file("readme"), SortKey::Name, false, false, c);
    const int ba = compareEntries(file("readme"), file("Readme"), SortKey::Name, false, false, c);
    EXPECT_NE(ab, 0);
    EXPECT_EQ(ab < 0, ba > 0);
}

TEST(SortKeys, DefaultDirections)
{
    EXPECT_FALSE(defaultDescending(SortKey::Name));
    EXPECT_FALSE(defaultDescending(SortKey::Kind));
    EXPECT_TRUE(defaultDescending(SortKey::Date));
    EXPECT_TRUE(defaultDescending(SortKey::Size));
}

TEST(SortKeys, NewKeysPutItemsWithoutAValueLast)
{
    const QCollator c = naturalCollator();
    const QDateTime older(QDate(2026, 1, 1), QTime(10, 0));
    const QDateTime newer(QDate(2026, 6, 1), QTime(10, 0));
    SortEntry a = file("a"), b = file("b"), none = file("c");
    a.created = older;
    b.created = newer;
    EXPECT_LT(compareEntries(a, b, SortKey::Created, false, false, c), 0);
    EXPECT_LT(compareEntries(b, a, SortKey::Created, true, false, c), 0);
    EXPECT_LT(compareEntries(a, none, SortKey::Created, false, false, c), 0) << "no creation date: last";
    EXPECT_LT(compareEntries(a, none, SortKey::Created, true, false, c), 0) << "last in both directions";
    a.opened = newer;
    EXPECT_LT(compareEntries(a, b, SortKey::Opened, false, false, c), 0) << "b has no last-opened date";

    SortEntry red = file("z"), work = file("y"), plain = file("x");
    red.tags = {QStringLiteral("Red"), QStringLiteral("Work")};
    work.tags = {QStringLiteral("Work")};
    EXPECT_LT(compareEntries(red, work, SortKey::Tags, false, false, c), 0) << "colour tags before the others";
    EXPECT_LT(compareEntries(work, plain, SortKey::Tags, false, false, c), 0) << "untagged last";
    EXPECT_LT(compareEntries(work, plain, SortKey::Tags, true, false, c), 0);

    SortEntry viewer = file("b"), editor = file("a"), nothing = file("c");
    viewer.application = QStringLiteral("Viewer");
    editor.application = QStringLiteral("Editor");
    EXPECT_LT(compareEntries(editor, viewer, SortKey::Application, false, false, c), 0);
    EXPECT_LT(compareEntries(viewer, nothing, SortKey::Application, false, false, c), 0);
    EXPECT_TRUE(defaultDescending(SortKey::Created));
    EXPECT_TRUE(defaultDescending(SortKey::Opened));
    EXPECT_FALSE(defaultDescending(SortKey::Tags));
    EXPECT_FALSE(defaultDescending(SortKey::Application));
}

TEST(Drops, FinderModifiers)
{
    EXPECT_EQ(dropAction(false, false, true), DropAction::Move) << "same volume: move";
    EXPECT_EQ(dropAction(false, false, false), DropAction::Copy) << "another volume: copy";
    EXPECT_EQ(dropAction(false, true, true), DropAction::Copy) << "Option copies";
    EXPECT_EQ(dropAction(true, false, false), DropAction::Move) << "Cmd moves, even to another volume";
    EXPECT_EQ(dropAction(true, true, true), DropAction::Link) << "Option-Cmd makes an alias";
    EXPECT_EQ(dropAction(true, true, false), DropAction::Link);
}

TEST(Groups, DatesNewestFirst)
{
    const QLocale en(QLocale::English, QLocale::UnitedStates);
    const QDateTime now(QDate(2026, 10, 26), QTime(15, 0));
    auto at = [](int y, int m, int d) {
        SortEntry e = file("f");
        e.modified = QDateTime(QDate(y, m, d), QTime(9, 0));
        return e;
    };
    EXPECT_EQ(groupOf(at(2026, 10, 26), GroupBy::Modified, now, en).title, QStringLiteral("Today"));
    EXPECT_EQ(groupOf(at(2026, 10, 25), GroupBy::Modified, now, en).title, QStringLiteral("Yesterday"));
    EXPECT_EQ(groupOf(at(2026, 10, 20), GroupBy::Modified, now, en).title, QStringLiteral("Previous 7 Days"));
    EXPECT_EQ(groupOf(at(2026, 10, 1), GroupBy::Modified, now, en).title, QStringLiteral("Previous 30 Days"));
    EXPECT_EQ(groupOf(at(2026, 3, 4), GroupBy::Modified, now, en).title, QStringLiteral("March"));
    EXPECT_EQ(groupOf(at(2024, 12, 31), GroupBy::Modified, now, en).title, QStringLiteral("2024"));
    EXPECT_EQ(groupOf(file("f"), GroupBy::Modified, now, en).title, QStringLiteral("Unknown"));
    const QCollator c = naturalCollator();
    const QList<SortEntry> order = {at(2026, 10, 26), at(2026, 10, 25), at(2026, 10, 20), at(2026, 10, 1), at(2026, 9, 1), at(2026, 3, 4),
                                    at(2025, 7, 1), at(2024, 12, 31), file("f")};
    for (int i = 1; i < order.size(); i++)
        EXPECT_LT(compareGroups(groupOf(order[i - 1], GroupBy::Modified, now, en), groupOf(order[i], GroupBy::Modified, now, en), c), 0) << i;
}

TEST(Groups, KindNameSizeTagsApplication)
{
    const QLocale en(QLocale::English, QLocale::UnitedStates);
    const QDateTime now(QDate(2026, 10, 26), QTime(15, 0));
    auto typed = [](const QStringList &types) {
        SortEntry e = file("f");
        e.mimeTypes = types;
        return e;
    };
    EXPECT_EQ(groupOf(folder("d"), GroupBy::Kind, now, en).title, QStringLiteral("Folders"));
    EXPECT_EQ(groupOf(typed({"image/png"}), GroupBy::Kind, now, en).title, QStringLiteral("Images"));
    EXPECT_EQ(groupOf(typed({"application/pdf"}), GroupBy::Kind, now, en).title, QStringLiteral("PDF Documents"));
    EXPECT_EQ(groupOf(typed({"application/x-shellscript", "application/x-executable", "text/plain"}), GroupBy::Kind, now, en).title,
              QStringLiteral("Applications"))
        << "the type's own match wins over its ancestors'";
    EXPECT_EQ(groupOf(typed({"text/markdown", "text/plain"}), GroupBy::Kind, now, en).title, QStringLiteral("Documents"));
    EXPECT_EQ(groupOf(typed({"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}), GroupBy::Kind, now, en).title,
              QStringLiteral("Spreadsheets"));
    const Group other = groupOf(typed({"application/octet-stream"}), GroupBy::Kind, now, en);
    EXPECT_EQ(other.title, QStringLiteral("Other"));
    const QCollator c = naturalCollator();
    EXPECT_LT(compareGroups(groupOf(typed({"image/png"}), GroupBy::Kind, now, en), other, c), 0) << "Other last";

    EXPECT_EQ(groupOf(file("apple"), GroupBy::Name, now, en).title, QStringLiteral("A"));
    EXPECT_EQ(groupOf(file("Éclair"), GroupBy::Name, now, en).title, QStringLiteral("E")) << "accents fold";
    EXPECT_EQ(groupOf(file("2026 notes"), GroupBy::Name, now, en).title, QStringLiteral("#"));
    EXPECT_LT(compareGroups(groupOf(file("2026"), GroupBy::Name, now, en), groupOf(file("a"), GroupBy::Name, now, en), c), 0);

    EXPECT_EQ(groupOf(file("f", 0), GroupBy::Size, now, en).title, QStringLiteral("Zero bytes"));
    EXPECT_EQ(groupOf(file("f", 5000), GroupBy::Size, now, en).title, QStringLiteral("Less than 100 KB"));
    EXPECT_EQ(groupOf(file("f", 500000), GroupBy::Size, now, en).title, QStringLiteral("100 KB to 1 MB"));
    EXPECT_EQ(groupOf(file("f", 5000000), GroupBy::Size, now, en).title, QStringLiteral("1 MB to 100 MB"));
    EXPECT_EQ(groupOf(file("f", 500000000), GroupBy::Size, now, en).title, QStringLiteral("100 MB to 1 GB"));
    EXPECT_EQ(groupOf(file("f", 5000000000LL), GroupBy::Size, now, en).title, QStringLiteral("More than 1 GB"));
    EXPECT_LT(compareGroups(groupOf(file("f", 5000000000LL), GroupBy::Size, now, en), groupOf(file("f", 0), GroupBy::Size, now, en), c), 0)
        << "largest first";

    SortEntry red = file("r"), work = file("w"), plain = file("p");
    red.tags = {QStringLiteral("Red"), QStringLiteral("Work")};
    work.tags = {QStringLiteral("Work")};
    EXPECT_EQ(groupOf(red, GroupBy::Tags, now, en).title, QStringLiteral("Red")) << "the first tag";
    EXPECT_EQ(groupOf(work, GroupBy::Tags, now, en).title, QStringLiteral("Work"));
    EXPECT_EQ(groupOf(plain, GroupBy::Tags, now, en).title, QStringLiteral("No Tags"));
    EXPECT_LT(compareGroups(groupOf(red, GroupBy::Tags, now, en), groupOf(work, GroupBy::Tags, now, en), c), 0);
    EXPECT_LT(compareGroups(groupOf(work, GroupBy::Tags, now, en), groupOf(plain, GroupBy::Tags, now, en), c), 0);

    SortEntry app = file("a");
    app.application = QStringLiteral("Viewer");
    EXPECT_EQ(groupOf(app, GroupBy::Application, now, en).title, QStringLiteral("Viewer"));
    EXPECT_EQ(groupOf(file("b"), GroupBy::Application, now, en).title, QStringLiteral("Other"));
    EXPECT_EQ(groupOf(folder("d"), GroupBy::Application, now, en).title, QStringLiteral("Folders"));
    EXPECT_TRUE(groupOf(file("x"), GroupBy::None, now, en).title.isEmpty());
}

TEST(SizeFormat, Bytes)
{
    const QLocale c = QLocale::c();
    EXPECT_EQ(formatSize(0, c), "Zero bytes");
    EXPECT_EQ(formatSize(1, c), "1 byte");
    EXPECT_EQ(formatSize(999, c), "999 bytes");
    EXPECT_EQ(formatSize(-1, c), "--");
}

TEST(SizeFormat, DecimalUnits)
{
    const QLocale c = QLocale::c();
    EXPECT_EQ(formatSize(1000, c), "1 KB");
    EXPECT_EQ(formatSize(1499, c), "1 KB");
    EXPECT_EQ(formatSize(1500, c), "2 KB");
    EXPECT_EQ(formatSize(12345, c), "12 KB");
    EXPECT_EQ(formatSize(999499, c), "999 KB");
    EXPECT_EQ(formatSize(999500, c), "1 MB");
    EXPECT_EQ(formatSize(1234567, c), "1.23 MB");
    EXPECT_EQ(formatSize(1200000, c), "1.2 MB");
    EXPECT_EQ(formatSize(12345678, c), "12.3 MB");
    EXPECT_EQ(formatSize(123456789, c), "123 MB");
    EXPECT_EQ(formatSize(465463709696LL, c), "465 GB");
    EXPECT_EQ(formatSize(2150000000000LL, c), "2.15 TB");
}

TEST(SizeFormat, LocaleDecimalSeparator)
{
    EXPECT_EQ(formatSize(1234567, QLocale(QLocale::French, QLocale::France)), "1,23 MB");
}

TEST(DateFormat, RelativeDays)
{
    const QLocale c = QLocale::c();
    const QDateTime now(QDate(2026, 10, 17), QTime(15, 0));
    EXPECT_EQ(formatDate(QDateTime(QDate(2026, 10, 17), QTime(9, 5)), now, c), "Today at " + c.toString(QTime(9, 5), QLocale::ShortFormat));
    EXPECT_EQ(formatDate(QDateTime(QDate(2026, 10, 16), QTime(23, 59)), now, c),
              "Yesterday at " + c.toString(QTime(23, 59), QLocale::ShortFormat));
    const QDateTime old(QDate(2025, 3, 2), QTime(8, 30));
    EXPECT_EQ(formatDate(old, now, c), c.toString(old.date(), QLocale::ShortFormat) + " at " + c.toString(old.time(), QLocale::ShortFormat));
    EXPECT_EQ(formatDate(QDateTime(), now, c), "--");
}

TEST(PathSegments, InsideHome)
{
    const QList<Segment> s = pathSegments(QUrl::fromLocalFile("/home/ana/Documents/Work"), "/home/ana", "Computer", "Trash");
    EXPECT_EQ(labels(s), QStringList({"ana", "Documents", "Work"}));
    EXPECT_EQ(urls(s), QStringList({"file:///home/ana", "file:///home/ana/Documents", "file:///home/ana/Documents/Work"}));
}

TEST(PathSegments, HomeItselfAndTrailingSlash)
{
    EXPECT_EQ(labels(pathSegments(QUrl::fromLocalFile("/home/ana/"), "/home/ana", "Computer", "Trash")), QStringList({"ana"}));
    // A sibling whose name starts like the home folder is not inside it.
    EXPECT_EQ(labels(pathSegments(QUrl::fromLocalFile("/home/anab"), "/home/ana", "Computer", "Trash")),
              QStringList({"Computer", "home", "anab"}));
}

TEST(PathSegments, OutsideHomeStartsAtRoot)
{
    const QList<Segment> s = pathSegments(QUrl::fromLocalFile("/usr/share"), "/home/ana", "Computer", "Trash");
    EXPECT_EQ(labels(s), QStringList({"Computer", "usr", "share"}));
    EXPECT_EQ(urls(s), QStringList({"file:///", "file:///usr", "file:///usr/share"}));
    EXPECT_EQ(labels(pathSegments(QUrl::fromLocalFile("/"), "/home/ana", "Computer", "Trash")), QStringList({"Computer"}));
}

TEST(PathSegments, TrashAndOtherSchemes)
{
    EXPECT_EQ(labels(pathSegments(QUrl("trash:/"), "/home/ana", "Computer", "Trash")), QStringList({"Trash"}));
    const QList<Segment> t = pathSegments(QUrl("trash:/0-old/sub"), "/home/ana", "Computer", "Trash");
    EXPECT_EQ(labels(t), QStringList({"Trash", "0-old", "sub"}));
    EXPECT_EQ(urls(t), QStringList({"trash:/", "trash:/0-old", "trash:/0-old/sub"}));
    EXPECT_EQ(labels(pathSegments(QUrl("ftp://host/pub/x"), "/home/ana", "Computer", "Trash")), QStringList({"host", "pub", "x"}));
}

TEST(PathSegments, SpecialCharactersRoundTrip)
{
    const QList<Segment> s = pathSegments(QUrl::fromLocalFile("/home/ana/a b#c%d"), "/home/ana", "Computer", "Trash");
    ASSERT_EQ(s.size(), 2);
    EXPECT_EQ(s[1].label, "a b#c%d");
    EXPECT_EQ(s[1].url.toLocalFile(), "/home/ana/a b#c%d");
}

TEST(FileNames, Validity)
{
    EXPECT_TRUE(isValidFileName("report.txt"));
    EXPECT_TRUE(isValidFileName(" spaced "));
    EXPECT_TRUE(isValidFileName(".hidden"));
    EXPECT_FALSE(isValidFileName(""));
    EXPECT_FALSE(isValidFileName("."));
    EXPECT_FALSE(isValidFileName(".."));
    EXPECT_FALSE(isValidFileName("a/b"));
    EXPECT_FALSE(isValidFileName(QString("a") + QChar(0) + "b"));
    EXPECT_TRUE(isValidFileName(QString(255, 'x')));
    EXPECT_FALSE(isValidFileName(QString(256, 'x')));
    // 128 two-byte characters = 256 bytes.
    EXPECT_FALSE(isValidFileName(QString(128, QChar(0x00E9))));
}

TEST(FileNames, BaseNameLength)
{
    EXPECT_EQ(baseNameLength("report.txt", false), 6);
    EXPECT_EQ(baseNameLength("archive.tar.gz", false), 11);
    EXPECT_EQ(baseNameLength("README", false), 6);
    EXPECT_EQ(baseNameLength(".bashrc", false), 7);
    EXPECT_EQ(baseNameLength(".config.old", false), 7);
    EXPECT_EQ(baseNameLength("photos.2026", true), 11);
}

TEST(FileNames, UniqueAndDuplicateNames)
{
    QSet<QString> taken{"untitled folder", "untitled folder 2", "a copy.txt"};
    const auto exists = [&taken](const QString &n) { return taken.contains(n); };
    EXPECT_EQ(uniqueName("untitled folder", exists), "untitled folder 3");
    EXPECT_EQ(uniqueName("fresh", exists), "fresh");
    EXPECT_EQ(duplicateName("a.txt", false, "copy", exists), "a copy 2.txt");
    EXPECT_EQ(duplicateName("b.txt", false, "copy", exists), "b copy.txt");
    EXPECT_EQ(duplicateName("photos.2026", true, "copy", exists), "photos.2026 copy");
    EXPECT_EQ(duplicateName(".bashrc", false, "copy", exists), ".bashrc copy");
}

TEST(UnicodeNames, CanonicallyEquivalentNamesAreTheSameName)
{
    const QString nfc = QString::fromUtf8("R\xc3\xa9sum\xc3\xa9.txt");
    const QString nfd = QString::fromUtf8("Re\xcc\x81sume\xcc\x81.txt");
    EXPECT_NE(nfc, nfd);
    EXPECT_TRUE(sameName(nfc, nfd));
    EXPECT_TRUE(sameName(nfc, nfc));
    EXPECT_FALSE(sameName(nfc, QStringLiteral("Resume.txt")));
    EXPECT_FALSE(sameName(nfc, nfc.toUpper()));
}

TEST(UnicodeNames, FilterIgnoresCaseAndAccentsInBothForms)
{
    const QString nfc = QString::fromUtf8("R\xc3\xa9sum\xc3\xa9.txt");
    const QString nfd = QString::fromUtf8("Re\xcc\x81sume\xcc\x81.txt");
    for (const QString &name : {nfc, nfd}) {
        EXPECT_TRUE(nameMatchesFilter(name, QStringLiteral("resume")));
        EXPECT_TRUE(nameMatchesFilter(name, QStringLiteral("RESUME")));
        EXPECT_TRUE(nameMatchesFilter(name, nfc.left(3)));
        EXPECT_TRUE(nameMatchesFilter(name, nfd.left(4)));
        EXPECT_FALSE(nameMatchesFilter(name, QStringLiteral("resumes")));
    }
    // Names with quotes and backslashes are plain text for the filter.
    EXPECT_TRUE(nameMatchesFilter(QStringLiteral("a\"b\\c"), QStringLiteral("\"b\\")));
}

TEST(UnicodeNames, EquivalentNameFindsOnlyTheTwin)
{
    const QString nfc = QString::fromUtf8("R\xc3\xa9sum\xc3\xa9.txt");
    const QString nfd = QString::fromUtf8("Re\xcc\x81sume\xcc\x81.txt");
    EXPECT_EQ(equivalentName({QStringLiteral("a.txt"), nfd}, nfc), nfd);
    EXPECT_TRUE(equivalentName({QStringLiteral("a.txt"), nfc}, nfc).isEmpty()); // the same string is a plain conflict
    EXPECT_TRUE(equivalentName({}, nfc).isEmpty());
    EXPECT_TRUE(equivalentName({QStringLiteral("Resume.txt")}, nfc).isEmpty());
}

TEST(UnicodeNames, TrashInfoGivesTheOriginalPath)
{
    EXPECT_EQ(trashInfoOriginalPath("[Trash Info]\nPath=/home/u/R%C3%A9sum%C3%A9.txt\nDeletionDate=2026-10-24T10:00:00\n"), QString::fromUtf8("/home/u/R\xc3\xa9sum\xc3\xa9.txt"));
    EXPECT_TRUE(trashInfoOriginalPath("[Trash Info]\nPath=relative/name\n").isEmpty());
    EXPECT_TRUE(trashInfoOriginalPath("[Other]\nPath=/x\n").isEmpty());
    EXPECT_TRUE(trashInfoOriginalPath("").isEmpty());
}

TEST(UnicodeNames, DisplayNameWritesOutBidiControlsAndBreaks)
{
    EXPECT_EQ(displayName(QString::fromUtf8("evil\xe2\x80\xaa" "fdp.exe")), QStringLiteral("evil<U+202A>fdp.exe"));
    EXPECT_EQ(displayName(QString(QChar(0x202E))), QStringLiteral("<U+202E>"));
    EXPECT_EQ(displayName(QStringLiteral("a") + QChar(0x2028) + QStringLiteral("b") + QChar(0x2029)), QStringLiteral("a<U+2028>b<U+2029>"));
    EXPECT_EQ(displayName(QString(QChar(0x2066)) + QChar(0x2069)), QStringLiteral("<U+2066><U+2069>"));
    EXPECT_EQ(displayName(QStringLiteral("two\r\nlines")), QString(QStringLiteral("two") + QChar(0x23CE) + QStringLiteral("lines")));
    EXPECT_EQ(displayName(QString(QChar(0x200E)) + QStringLiteral("kept")), QString(QChar(0x200E)) + QStringLiteral("kept"));
    EXPECT_EQ(displayName(QStringLiteral("say \"hi\" \\ there")), QStringLiteral("say \"hi\" \\ there"));
}

TEST(NetworkPlace, HidesTheAppleDevicesEntry)
{
    // kio-extras remoteview entries in remote:/ (afc-network.desktop links to afc:/).
    EXPECT_TRUE(hiddenNetworkEntry(QUrl("remote:/afc-network"), QUrl("afc:/")));
    EXPECT_TRUE(hiddenNetworkEntry(QUrl("remote:/afc-network.desktop"), QUrl()));
    EXPECT_TRUE(hiddenNetworkEntry(QUrl("remote:/something"), QUrl("afc:/")));
    EXPECT_FALSE(hiddenNetworkEntry(QUrl("remote:/smb-network"), QUrl("smb://")));
    EXPECT_FALSE(hiddenNetworkEntry(QUrl("remote:/mtp-network"), QUrl("mtp:/")));
    // Only the Network place: a local file of that name stays visible.
    EXPECT_FALSE(hiddenNetworkEntry(QUrl::fromLocalFile("/tmp/afc-network.desktop"), QUrl::fromLocalFile("/tmp/afc-network.desktop")));
}

// ADR-0026 part 1: the kept window size. QSettings returns what Files.conf holds (a string from the INI file, an int
// once written in this process); anything but an integer side in 200..16384 reads as none kept.
TEST(WindowSize, AKeptSideIsAnIntegerInBounds)
{
    EXPECT_EQ(keptWindowSide(QVariant(1000)), 1000);
    EXPECT_EQ(keptWindowSide(QVariant(QStringLiteral("640"))), 640);
    EXPECT_EQ(keptWindowSide(QVariant(kMinKeptWindowSide)), kMinKeptWindowSide);
    EXPECT_EQ(keptWindowSide(QVariant(kMaxKeptWindowSide)), kMaxKeptWindowSide);
    EXPECT_EQ(keptWindowSide(QVariant(kMinKeptWindowSide - 1)), 0) << "too small: an invisible window";
    EXPECT_EQ(keptWindowSide(QVariant(kMaxKeptWindowSide + 1)), 0) << "too large: a giant window";
    EXPECT_EQ(keptWindowSide(QVariant(-800)), 0);
    EXPECT_EQ(keptWindowSide(QVariant(QStringLiteral("99999999999"))), 0) << "past int";
    EXPECT_EQ(keptWindowSide(QVariant(QStringLiteral("wide"))), 0);
    EXPECT_EQ(keptWindowSide(QVariant(QStringLiteral(""))), 0);
    EXPECT_EQ(keptWindowSide(QVariant(QStringLiteral("640px"))), 0);
    EXPECT_EQ(keptWindowSide(QVariant()), 0) << "never kept";
}

TEST(WindowSize, OnlyASizeInBoundsIsKept)
{
    EXPECT_TRUE(keepsWindowSize(920, 560));
    EXPECT_TRUE(keepsWindowSize(kMinKeptWindowSide, kMaxKeptWindowSide));
    EXPECT_FALSE(keepsWindowSize(kMinKeptWindowSide - 1, 560));
    EXPECT_FALSE(keepsWindowSize(920, kMinKeptWindowSide - 1));
    EXPECT_FALSE(keepsWindowSize(kMaxKeptWindowSide + 1, 560));
    EXPECT_FALSE(keepsWindowSize(920, kMaxKeptWindowSide + 1));
    EXPECT_FALSE(keepsWindowSize(0, 0));
}

// The Open and Save panels' filters (grassfield-portal, ADR-0035 D-4): globs without regard to case, MIME types with their
// ancestors and "major/*"; an empty filter passes everything.
TEST(PanelFilter, GlobsAndMimeTypes)
{
    const QStringList text{QStringLiteral("text/plain")};
    const QStringList markdown{QStringLiteral("text/markdown"), QStringLiteral("text/plain")};
    const QStringList png{QStringLiteral("image/png")};
    EXPECT_TRUE(passesFilter(QStringLiteral("a.txt"), text, {}, {}));
    EXPECT_TRUE(passesFilter(QStringLiteral("REPORT.PDF"), {}, {QStringLiteral("*.pdf")}, {}));
    EXPECT_FALSE(passesFilter(QStringLiteral("report.pdf.zip"), {}, {QStringLiteral("*.pdf")}, {}));
    EXPECT_TRUE(passesFilter(QStringLiteral("photo.jpeg"), {}, {QStringLiteral("*.jpg"), QStringLiteral("*.jpeg")}, {}));
    // A glob matches the whole name, never a path ("*" stops at nothing but "/", which names never hold).
    EXPECT_TRUE(passesFilter(QStringLiteral("Makefile"), {}, {QStringLiteral("Makefile")}, {}));
    EXPECT_FALSE(passesFilter(QStringLiteral("Makefile.am"), {}, {QStringLiteral("Makefile")}, {}));
    EXPECT_TRUE(passesFilter(QStringLiteral("notes.md"), markdown, {}, {QStringLiteral("text/plain")}));
    EXPECT_TRUE(passesFilter(QStringLiteral("x.png"), png, {}, {QStringLiteral("image/*")}));
    EXPECT_FALSE(passesFilter(QStringLiteral("x.png"), png, {}, {QStringLiteral("text/*")}));
    EXPECT_FALSE(passesFilter(QStringLiteral("x.png"), png, {}, {QStringLiteral("image/jpeg")}));
    // Globs or MIME types: either passes.
    EXPECT_TRUE(passesFilter(QStringLiteral("x.png"), png, {QStringLiteral("*.txt")}, {QStringLiteral("image/png")}));
}

// The glob matcher (shell globs, one pass, no regular expression per item): '?', bracket expressions with negation and ranges,
// '\' quoting, '*' going back as far as it must, all without regard to case; a '[' that closes nowhere is a character.
TEST(PanelFilter, Globs)
{
    const auto matches = [](const char *glob, const char *name) {
        return passesFilter(QString::fromUtf8(name), {}, {QString::fromUtf8(glob)}, {});
    };
    EXPECT_TRUE(matches("*", "anything at all"));
    EXPECT_TRUE(matches("file?.txt", "file1.txt"));
    EXPECT_FALSE(matches("file?.txt", "file.txt"));
    EXPECT_FALSE(matches("file?.txt", "file12.txt"));
    EXPECT_TRUE(matches("*.[jJ][pP]g", "Photo.JPG"));
    EXPECT_TRUE(matches("*.[ch]", "main.c"));
    EXPECT_FALSE(matches("*.[ch]", "main.o"));
    EXPECT_TRUE(matches("*.[!o]", "main.c"));
    EXPECT_FALSE(matches("*.[!o]", "main.o"));
    EXPECT_TRUE(matches("*.[^o]", "main.c"));
    EXPECT_TRUE(matches("img[0-9].png", "img7.png"));
    EXPECT_FALSE(matches("img[0-9].png", "imgx.png"));
    EXPECT_TRUE(matches("[]]x", "]x"));
    // '\' in a bracket takes the next character as it is (GTK's fnmatch).
    EXPECT_TRUE(matches("[\\]]x", "]x"));
    EXPECT_FALSE(matches("[\\]]x", "\\]x"));
    EXPECT_TRUE(matches("[a\\-z]", "-"));
    EXPECT_FALSE(matches("[a\\-z]", "m"));
    EXPECT_TRUE(matches("a[b", "A[B"));
    EXPECT_TRUE(matches("\\*.txt", "*.txt"));
    EXPECT_FALSE(matches("\\*.txt", "a.txt"));
    EXPECT_TRUE(matches("a*b*c", "aXbYbZc"));
    EXPECT_FALSE(matches("a*b*c", "aXbYbZ"));
    EXPECT_TRUE(matches("*.tar.*", "backup.TAR.gz"));
    EXPECT_TRUE(matches("r\u00e9sum\u00e9*", "R\u00c9SUM\u00c9.pdf"));
    EXPECT_TRUE(matches("?.txt", "\U0001F600.txt"));
    EXPECT_FALSE(matches("", "a"));
}

// The Copy window's lines (FP-68, Finder-Copy). The title names what the user asked for, not the file KIO copies now.
TEST(FileLogicCopyWindow, TheTitleNamesTheItemsAskedForAndTheFolderTheyGoTo)
{
    EXPECT_EQ(copyTitle("Copying", "a.txt", 1, "Docs").toStdString(), "Copying “a.txt” to “Docs”");
    EXPECT_EQ(copyTitle("Moving", "a.txt", 12, "Docs").toStdString(), "Moving 12 items to “Docs”");
    EXPECT_EQ(copyTitle("Copying", "a.txt", 0, "Docs").toStdString(), "Copying “a.txt” to “Docs”") << "an unknown count names the item";
    EXPECT_EQ(copyTitle("Copying", "a.txt", 1, "").toStdString(), "Copying “a.txt”") << "no destination, no \"to\"";
    EXPECT_EQ(copyTitle("Copying", "", 3, "").toStdString(), "Copying 3 items");
}

TEST(FileLogicCopyWindow, NoVerbOrNothingToNameLeavesTheActivityText)
{
    EXPECT_TRUE(copyTitle("", "a.txt", 1, "Docs").isEmpty()) << "KIO has not described the job yet";
    EXPECT_TRUE(copyTitle("Copying", "", 0, "Docs").isEmpty());
}

TEST(FileLogicCopyWindow, ANameThatLooksLikeMarkupOrReversesTextIsWrittenOut)
{
    // Names go through displayName (GF-105): a right-to-left override is written out, a line break shown as a symbol.
    const QString title = copyTitle("Copying", QStringLiteral("a‮txt.exe"), 1, QStringLiteral("D\nocs"));
    EXPECT_FALSE(title.contains(QChar(0x202e)));
    EXPECT_FALSE(title.contains(QLatin1Char('\n')));
}

TEST(FileLogicCopyWindow, TheTimeLeftIsRoundedLikeTheFinder)
{
    EXPECT_EQ(remainingText(0).toStdString(), "About 1 second");
    EXPECT_EQ(remainingText(1).toStdString(), "About 1 second");
    EXPECT_EQ(remainingText(2).toStdString(), "About 2 seconds");
    EXPECT_EQ(remainingText(59).toStdString(), "About 59 seconds");
    EXPECT_EQ(remainingText(60).toStdString(), "About 1 minute");
    EXPECT_EQ(remainingText(119).toStdString(), "About 1 minute");
    EXPECT_EQ(remainingText(120).toStdString(), "About 3 minutes");
    EXPECT_EQ(remainingText(600).toStdString(), "About 11 minutes");
}

TEST(FileLogicCopyWindow, TheDetailLineShowsTheBytesAndTheTimeLeft)
{
    EXPECT_EQ(copyDetail(41900000, 111600000, 6970000, 37).toStdString(), "41.9 MB of 112 MB – About 10 seconds");
    EXPECT_EQ(copyDetail(41900000, 111600000, 0, 37).toStdString(), "41.9 MB of 112 MB") << "no estimate while the speed is unknown";
    EXPECT_EQ(copyDetail(111600000, 111600000, 6970000, 100).toStdString(), "112 MB of 112 MB") << "nothing left, nothing to wait for";
}

TEST(FileLogicCopyWindow, AJobThatTellsNoAmountYetIsPreparing)
{
    // KIO looks through every folder to copy before it knows the total: the window shows that, not an empty line and bar.
    EXPECT_EQ(copyDetail(0, 0, 0, -1).toStdString(), "Preparing…");
    EXPECT_EQ(copyDetail(0, 0, 0, 0).toStdString(), "Preparing…");
    EXPECT_TRUE(copyDetail(0, 0, 0, 40).isEmpty()) << "a job that only counts shows its bar";
}

TEST(FileLogicCopyWindow, TheBarFollowsTheBytesThenTheJobsOwnPercent)
{
    EXPECT_EQ(copyPercent(50, 200, -1), 25);
    EXPECT_EQ(copyPercent(300, 200, -1), 100) << "never past full";
    EXPECT_EQ(copyPercent(0, 200, 90), 0) << "the bytes win when the total is known";
    EXPECT_EQ(copyPercent(0, 0, 40), 40);
    EXPECT_EQ(copyPercent(0, 0, 400), 100);
    EXPECT_EQ(copyPercent(0, 0, 0), -1) << "no amount: the bar sweeps";
    EXPECT_EQ(copyPercent(0, 0, -1), -1);
}

// GNOME file managers' clipboard list (decision F-18): its first line says cut or copy.
TEST(FileLogicClipboard, GnomesListSaysWhetherTheItemsWereCut)
{
    EXPECT_TRUE(FileLogic::gnomeCopiedFilesCut("cut\nfile:///home/u/a.txt"));
    EXPECT_TRUE(FileLogic::gnomeCopiedFilesCut("cut\r\nfile:///home/u/a.txt\nfile:///home/u/b.txt"));
    EXPECT_TRUE(FileLogic::gnomeCopiedFilesCut("cut"));
    EXPECT_FALSE(FileLogic::gnomeCopiedFilesCut("copy\nfile:///home/u/a.txt"));
    EXPECT_FALSE(FileLogic::gnomeCopiedFilesCut("file:///home/u/cut"));
    EXPECT_FALSE(FileLogic::gnomeCopiedFilesCut(QByteArray()));
}
