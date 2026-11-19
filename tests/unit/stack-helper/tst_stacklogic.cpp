// Unit tests for apps/stack-helper/src/stacklogic.{h,cpp} (gtest). Built and run by scripts/dev/test.sh. The process itself
// (watching, the line protocol, death with the parent) is tests/shell/stack_helper.sh.
#include "stacklogic.h"

#include <QDir>
#include <QFile>
#include <QRandomGenerator>
#include <QTemporaryDir>

#include <algorithm>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <gtest/gtest.h>

using namespace StackLogic;

namespace
{
Entry make(const QString &name, bool dir = false, double modified = 0, double added = 0, double created = 0)
{
    Entry e;
    e.raw = name.toUtf8();
    e.se.name = name;
    e.se.isDir = dir;
    e.modified = modified;
    e.added = added;
    e.created = created;
    e.kind = kindKey(name, dir);
    return e;
}

QStringList names(const std::vector<Entry> &entries)
{
    QStringList out;
    for (const Entry &e : entries)
        out.append(e.se.name);
    return out;
}

void touch(const QString &path, double seconds = -1)
{
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write("x");
    f.close();
    if (seconds >= 0) {
        struct timespec ts[2];
        ts[0].tv_sec = time_t(seconds);
        ts[0].tv_nsec = 0;
        ts[1] = ts[0];
        ASSERT_EQ(utimensat(AT_FDCWD, path.toUtf8().constData(), ts, 0), 0);
    }
}
} // namespace

TEST(StackLogic, ParsesTheFiveOrders)
{
    Sort s;
    EXPECT_TRUE(parseSort("name", &s) && s == Sort::Name);
    EXPECT_TRUE(parseSort("dateAdded", &s) && s == Sort::DateAdded);
    EXPECT_TRUE(parseSort("dateModified", &s) && s == Sort::DateModified);
    EXPECT_TRUE(parseSort("dateCreated", &s) && s == Sort::DateCreated);
    EXPECT_TRUE(parseSort("kind", &s) && s == Sort::Kind);
    EXPECT_FALSE(parseSort("size", &s));
    EXPECT_FALSE(parseSort("", &s));
}

TEST(StackLogic, NameOrderIsFilesOrder)
{
    // "file2" before "file10", "a" with "A", accents after their letters, ties by the raw names: FileLogic::compareEntries itself
    const QCollator c = makeCollator();
    Window w(Sort::Name, 50, &c);
    for (const QString &n : QStringList{"file10", "file2", "File1", "Zebra", "apple", "École", "ecole", "Apple", "10", "9", "_x", "ß"})
        w.offer(make(n));
    EXPECT_EQ(names(w.entries()), (QStringList{"_x", "9", "10", "Apple", "apple", "ecole", "École", "File1", "file2", "file10", "ß", "Zebra"}));
}

TEST(StackLogic, KindIsFoldersThenExtension)
{
    const QCollator c = makeCollator();
    Window w(Sort::Kind, 50, &c);
    w.offer(make("b.txt"));
    w.offer(make("a.PDF"));
    w.offer(make("noext"));
    w.offer(make("Sub", true));
    w.offer(make("c.pdf"));
    EXPECT_EQ(names(w.entries()), (QStringList{"Sub", "a.PDF", "c.pdf", "b.txt", "noext"}));
}

TEST(StackLogic, DatesAreNewestFirstTiesByName)
{
    const QCollator c = makeCollator();
    Window w(Sort::DateModified, 10, &c);
    w.offer(make("b", false, 5));
    w.offer(make("a", false, 5));
    w.offer(make("new", false, 9));
    w.offer(make("old", false, 1));
    EXPECT_EQ(names(w.entries()), (QStringList{"new", "a", "b", "old"}));
}

// the window is the first K of a full sort, for every order, whatever the order the entries come in, ties included
TEST(StackLogic, WindowEqualsAFullSort)
{
    const QCollator c = makeCollator();
    QRandomGenerator rng(7);
    const QStringList bases = {"a", "B", "é", "E", "file", "File", "x1", "x10", "x2", "ß", "😀", "中", "Ａ", "z"};
    for (Sort sort : {Sort::Name, Sort::DateAdded, Sort::DateModified, Sort::DateCreated, Sort::Kind}) {
        std::vector<Entry> all;
        QSet<QString> seen;
        for (int i = 0; i < 1500; i++) {
            const QString name = bases[int(rng.bounded(bases.size()))] + (rng.bounded(2) ? QString() : QStringLiteral(".") + QStringList{"txt", "PDF", "tar.gz"}[int(rng.bounded(3))]) + QString::number(rng.bounded(300));
            if (seen.contains(name))
                continue;
            seen.insert(name);
            all.push_back(make(name, rng.bounded(5) == 0, double(rng.bounded(8)), double(rng.bounded(8)), double(rng.bounded(6))));
        }
        std::vector<Entry> sorted = all;
        std::stable_sort(sorted.begin(), sorted.end(), [&](const Entry &a, const Entry &b) { return compare(a, b, sort, c) < 0; });
        for (int k : {3, 30, 300}) {
            Window w(sort, k, &c);
            for (const Entry &e : all)
                w.offer(e);
            std::vector<Entry> first(sorted.begin(), sorted.begin() + std::min<size_t>(size_t(k), sorted.size()));
            EXPECT_EQ(names(w.entries()), names(first)) << "order " << int(sort) << " K " << k;
        }
    }
}

TEST(StackLogic, RemoveAndShrink)
{
    const QCollator c = makeCollator();
    Window w(Sort::Name, 5, &c);
    for (const QString &n : QStringList{"a", "b", "c", "d", "e", "f"})
        w.offer(make(n));
    EXPECT_EQ(names(w.entries()), (QStringList{"a", "b", "c", "d", "e"}));
    EXPECT_TRUE(w.remove("c"));
    EXPECT_FALSE(w.remove("c"));
    EXPECT_FALSE(w.full());
    w.setLimit(2);
    EXPECT_EQ(names(w.entries()), (QStringList{"a", "b"}));
}

TEST(StackLogic, NamesCannotForgeALine)
{
    // line breaks, returns, US and backslashes are escaped: a name never ends the line or starts a field
    const QCollator c = makeCollator();
    Window w(Sort::Name, 10, &c);
    for (const QString &n : QStringList{QStringLiteral("x\nW\x1f""1"), QStringLiteral("a\\nb"), QStringLiteral("cr\r"), QStringLiteral("us\x1f""sep"), QStringLiteral("plain")})
        w.offer(make(n));
    const QByteArray line = encodeWindow(3, 5, w.entries());
    EXPECT_EQ(line.count('\n'), 1);
    EXPECT_TRUE(line.endsWith('\n'));
    EXPECT_EQ(line.left(1), "W");
    // 4 header fields and 5 per entry, so US separates exactly those
    EXPECT_EQ(line.count('\x1f'), 3 + 5 * 5);
    EXPECT_FALSE(line.contains('\r'));
}

// Audit F22: a name that is not UTF-8 (a Latin-1 name from an old disk) is written byte for byte (\xHH for each byte that is
// not part of valid UTF-8), so that the shell can name the file again; valid UTF-8 is written as it is.
TEST(StackLogic, NamesAreWrittenByteForByte)
{
    EXPECT_EQ(escapeName(QByteArray("caf\xe9.txt")), QByteArray("caf\\xe9.txt"));
    EXPECT_EQ(escapeName(QByteArray("caf\xc3\xa9.txt")), QByteArray("caf\xc3\xa9.txt")) << "UTF-8 as it is";
    EXPECT_EQ(escapeName(QByteArray("\xf0\x9f\x93\x81 emoji")), QByteArray("\xf0\x9f\x93\x81 emoji"));
    EXPECT_EQ(escapeName(QByteArray("a\\xe9")), QByteArray("a\\\\xe9")) << "a backslash in the name never reads as an escape";
    EXPECT_EQ(escapeName(QByteArray("\xc0\x80")), QByteArray("\\xc0\\x80")) << "an overlong form is no character";
    EXPECT_EQ(escapeName(QByteArray("\xed\xa0\x80")), QByteArray("\\xed\\xa0\\x80")) << "nor a surrogate";
    EXPECT_EQ(escapeName(QByteArray("cut\xc3")), QByteArray("cut\\xc3")) << "nor a sequence cut short";
    EXPECT_EQ(escapeName(QByteArray("x\ny\rz\x1f")), QByteArray("x\\ny\\rz\\u"));
    // The window carries the raw name, not the decoded one (U+FFFD named no file).
    Entry e;
    e.raw = QByteArray("old\xe9");
    e.se.name = QFile::decodeName(e.raw);
    const QByteArray line = encodeWindow(1, 1, {e});
    EXPECT_TRUE(line.contains("old\\xe9")) << line.constData();
    // The folder argument: a path, or a file: URI whose escapes are bytes.
    EXPECT_EQ(folderArgument("/home/u/Old"), QByteArray("/home/u/Old"));
    EXPECT_EQ(folderArgument("file:///home/u/Vieux%E9"), QByteArray("/home/u/Vieux\xe9"));
    EXPECT_TRUE(folderArgument("relative").isEmpty());
    EXPECT_TRUE(folderArgument("file://host-less%00").isEmpty());
}

TEST(StackLogic, ScanSkipsHiddenAndDoesNotFollowLinks)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString d = tmp.path();
    touch(d + "/b.txt", 1000);
    touch(d + "/A.pdf", 2000);
    touch(d + "/.hidden", 3000);
    ASSERT_TRUE(QDir(d).mkdir("Sub"));
    ASSERT_TRUE(QFile::link("Sub", d + "/linktosub"));
    ASSERT_TRUE(QFile::link("nowhere", d + "/broken"));
    touch(QString::fromUtf8("%1/café.txt").arg(d), 500);
    const QCollator c = makeCollator();
    for (Sort sort : {Sort::Name, Sort::DateModified}) {
        Window w(sort, 30, &c);
        const ScanResult r = scanFolder(d.toUtf8(), &w);
        ASSERT_TRUE(r.ok);
        EXPECT_EQ(r.total, 6) << "hidden names are not entries";
        EXPECT_EQ(w.entries().size(), size_t(6));
        for (const Entry &e : w.entries()) {
            EXPECT_NE(e.se.name, ".hidden");
            if (e.se.name == "linktosub") {
                EXPECT_FALSE(e.se.isDir) << "a link is an item with its own type";
            }
            if (e.se.name == "Sub") {
                EXPECT_TRUE(e.se.isDir);
            }
            if (e.se.name == "A.pdf") {
                EXPECT_NEAR(e.modified, 2000, 1);
            }
        }
    }
    Window byDate(Sort::DateModified, 3, &c);
    scanFolder(d.toUtf8(), &byDate);
    // the folder and the two links were made now, the files carry old dates: they are the three newest
    QStringList newest;
    for (const Entry &e : byDate.entries())
        newest.append(e.se.name);
    newest.sort();
    EXPECT_EQ(newest, (QStringList{"Sub", "broken", "linktosub"}));
}

TEST(StackLogic, NamesThatAreNotUtf8AreListed)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QByteArray path = tmp.path().toUtf8() + "/caf\xe9.txt";
    const int fd = ::open(path.constData(), O_CREAT | O_WRONLY, 0600);
    ASSERT_GE(fd, 0);
    ::close(fd);
    const QCollator c = makeCollator();
    Window w(Sort::Name, 5, &c);
    const ScanResult r = scanFolder(tmp.path().toUtf8(), &w);
    ASSERT_TRUE(r.ok);
    ASSERT_EQ(w.entries().size(), size_t(1));
    EXPECT_TRUE(w.entries()[0].se.name.contains(QChar(0xfffd))) << "shown with U+FFFD for the bad byte, as Files shows it";
    EXPECT_EQ(w.entries()[0].raw, QByteArray("caf\xe9.txt"));
}

// the race of the review: files that vanish between the listing and the statx are skipped and the window is still full (2,010
// files, the 30 newest deleted while the scan runs: an empty pile once)
TEST(StackLogic, VanishingFilesAreSkippedAndTheWindowIsStillFull)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString d = tmp.path();
    for (int i = 0; i < 2010; i++)
        touch(QStringLiteral("%1/f%2").arg(d).arg(i, 4, 10, QLatin1Char('0')), 1000000 + i);
    const QCollator c = makeCollator();
    for (Sort sort : {Sort::DateModified, Sort::DateAdded, Sort::Name, Sort::Kind}) {
        // the files to lose: the 30 newest, deleted when the scan has stat'ed 100 entries (so most are still ahead of it)
        QStringList doomed;
        for (int i = 1980; i < 2010; i++)
            doomed.append(QStringLiteral("f%1").arg(i, 4, 10, QLatin1Char('0')));
        int seen = 0;
        bool deleted = false;
        Window w(sort, 30, &c);
        const ScanResult r = scanFolder(d.toUtf8(), &w, [&](const QByteArray &) {
            if (++seen == 100 && !deleted) {
                deleted = true;
                for (const QString &n : doomed)
                    QFile::remove(d + "/" + n);
            }
        });
        ASSERT_TRUE(r.ok);
        EXPECT_EQ(w.entries().size(), size_t(30)) << "order " << int(sort) << ": a vanished file must not shorten the window";
        for (const Entry &e : w.entries())
            EXPECT_FALSE(doomed.contains(e.se.name)) << "order " << int(sort) << ": " << e.se.name.toStdString() << " is gone";
        // put them back for the next order
        for (int i = 1980; i < 2010; i++)
            touch(QStringLiteral("%1/f%2").arg(d).arg(i, 4, 10, QLatin1Char('0')), 1000000 + i);
    }
}

TEST(StackLogic, AMissingFolderIsNotOk)
{
    const QCollator c = makeCollator();
    Window w(Sort::Name, 5, &c);
    EXPECT_FALSE(scanFolder("/nonexistent/folder/for/the/stack/helper", &w).ok);
}
