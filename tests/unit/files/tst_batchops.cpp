// Files' multi-step commands (BatchOps; review of PR #98): Rename N Items, Make Alias and New Folder with Selection are applied
// all together or not at all, revert as one step, and never replace anything. Real files under GRASSFIELD_TEST_TMP (a
// directory inside .dev/; skipped without it).
#include "batchops.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>

#include <memory>

#include <gtest/gtest.h>

#include <sys/stat.h>
#include <unistd.h>

using namespace BatchOps;

namespace
{
std::unique_ptr<QTemporaryDir> sandbox(QString *why)
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    if (base.isEmpty() || !QDir::cleanPath(base).contains(QLatin1String("/.dev/"))) {
        *why = QStringLiteral("GRASSFIELD_TEST_TMP (a directory under .dev/) is not set");
        return nullptr;
    }
    QDir().mkpath(base);
    auto dir = std::make_unique<QTemporaryDir>(base + QStringLiteral("/batchops-XXXXXX"));
    if (!dir->isValid()) {
        *why = QStringLiteral("cannot create a directory in ") + base;
        return nullptr;
    }
    return dir;
}

void write(const QString &path, const QByteArray &bytes)
{
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(bytes);
}

QByteArray read(const QString &path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

bool present(const QString &path)
{
    return QFileInfo::exists(path) || QFileInfo(path).isSymLink();
}
} // namespace

TEST(BatchOps, RenamesApplyTogetherAndRevertAsOne)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString d = dir->path();
    for (const char *n : {"a", "b", "c"})
        write(d + QLatin1Char('/') + QLatin1String(n), n);
    const Steps steps{{Step::Kind::Rename, d + QStringLiteral("/a"), d + QStringLiteral("/x1")},
                      {Step::Kind::Rename, d + QStringLiteral("/b"), d + QStringLiteral("/x2")},
                      {Step::Kind::Rename, d + QStringLiteral("/c"), d + QStringLiteral("/x3")}};
    Failure f;
    ASSERT_TRUE(apply(steps, &f));
    EXPECT_EQ(read(d + QStringLiteral("/x2")), QByteArray("b"));
    EXPECT_FALSE(present(d + QStringLiteral("/a")));
    // One revert puts all three back.
    ASSERT_TRUE(apply(inverse(steps), &f));
    for (const char *n : {"a", "b", "c"})
        EXPECT_EQ(read(d + QLatin1Char('/') + QLatin1String(n)), QByteArray(n));
    EXPECT_FALSE(present(d + QStringLiteral("/x1")));
    // And apply() again is the redo.
    ASSERT_TRUE(apply(steps, &f));
    EXPECT_EQ(read(d + QStringLiteral("/x3")), QByteArray("c"));
}

TEST(BatchOps, AFailurePartWayPutsBackWhatWasDone)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString d = dir->path();
    for (const char *n : {"a", "b", "c"})
        write(d + QLatin1Char('/') + QLatin1String(n), n);
    write(d + QStringLiteral("/taken"), "mine");
    // The third target exists: the first two renames are put back and nothing is replaced.
    const Steps steps{{Step::Kind::Rename, d + QStringLiteral("/a"), d + QStringLiteral("/x1")},
                      {Step::Kind::Rename, d + QStringLiteral("/b"), d + QStringLiteral("/x2")},
                      {Step::Kind::Rename, d + QStringLiteral("/c"), d + QStringLiteral("/taken")}};
    Failure f;
    EXPECT_FALSE(apply(steps, &f));
    EXPECT_EQ(f.step, 2);
    EXPECT_EQ(f.path, d + QStringLiteral("/c"));
    EXPECT_EQ(f.error, EEXIST);
    for (const char *n : {"a", "b", "c"})
        EXPECT_EQ(read(d + QLatin1Char('/') + QLatin1String(n)), QByteArray(n)) << n;
    EXPECT_FALSE(present(d + QStringLiteral("/x1")));
    EXPECT_FALSE(present(d + QStringLiteral("/x2")));
    EXPECT_EQ(read(d + QStringLiteral("/taken")), QByteArray("mine")) << "never replaced";
    // A source that is gone fails the same way.
    EXPECT_FALSE(apply({{Step::Kind::Rename, d + QStringLiteral("/a"), d + QStringLiteral("/y1")}, {Step::Kind::Rename, d + QStringLiteral("/gone"), d + QStringLiteral("/y2")}}, &f));
    EXPECT_EQ(f.step, 1);
    EXPECT_EQ(read(d + QStringLiteral("/a")), QByteArray("a"));
}

TEST(BatchOps, AliasesAreLinksUndoneOnlyWhileTheyStillPointThere)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString d = dir->path();
    write(d + QStringLiteral("/report.txt"), "r");
    write(d + QStringLiteral("/other.txt"), "o");
    const Steps steps{{Step::Kind::Link, d + QStringLiteral("/report.txt"), d + QStringLiteral("/report.txt alias")},
                      {Step::Kind::Link, d + QStringLiteral("/other.txt"), d + QStringLiteral("/other.txt alias")}};
    Failure f;
    ASSERT_TRUE(apply(steps, &f));
    EXPECT_EQ(QFileInfo(d + QStringLiteral("/report.txt alias")).symLinkTarget(), d + QStringLiteral("/report.txt"));
    // A name that exists is never replaced: the whole command fails, the first link is removed again.
    EXPECT_FALSE(apply({{Step::Kind::Link, d + QStringLiteral("/report.txt"), d + QStringLiteral("/third")},
                        {Step::Kind::Link, d + QStringLiteral("/other.txt"), d + QStringLiteral("/other.txt alias")}}, &f));
    EXPECT_EQ(f.step, 1);
    EXPECT_FALSE(present(d + QStringLiteral("/third")));
    // The user replaced one alias by a file of the same name: undo stops, and leaves everything in place.
    ASSERT_TRUE(QFile::remove(d + QStringLiteral("/other.txt alias")));
    write(d + QStringLiteral("/other.txt alias"), "the user's own file");
    EXPECT_FALSE(apply(inverse(steps), &f));
    EXPECT_EQ(read(d + QStringLiteral("/other.txt alias")), QByteArray("the user's own file"));
    EXPECT_TRUE(QFileInfo(d + QStringLiteral("/report.txt alias")).isSymLink()) << "the first alias is still there: the revert failed as a whole";
    // Once the alias is the user's again as it was, undo works.
    ASSERT_TRUE(QFile::remove(d + QStringLiteral("/other.txt alias")));
    ASSERT_TRUE(QFile::link(d + QStringLiteral("/other.txt"), d + QStringLiteral("/other.txt alias")));
    ASSERT_TRUE(apply(inverse(steps), &f));
    EXPECT_FALSE(present(d + QStringLiteral("/report.txt alias")));
    EXPECT_FALSE(present(d + QStringLiteral("/other.txt alias")));
    EXPECT_EQ(read(d + QStringLiteral("/report.txt")), QByteArray("r")) << "the originals are never touched";
}

TEST(BatchOps, ANewFolderWithItemsIsOneCommand)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString d = dir->path();
    write(d + QStringLiteral("/a.txt"), "a");
    write(d + QStringLiteral("/b.txt"), "b");
    const QString folder = d + QStringLiteral("/New Folder With Items");
    const Steps steps{{Step::Kind::Mkdir, QString(), folder},
                      {Step::Kind::Rename, d + QStringLiteral("/a.txt"), folder + QStringLiteral("/a.txt")},
                      {Step::Kind::Rename, d + QStringLiteral("/b.txt"), folder + QStringLiteral("/b.txt")}};
    Failure f;
    ASSERT_TRUE(apply(steps, &f));
    EXPECT_EQ(read(folder + QStringLiteral("/b.txt")), QByteArray("b"));
    // One undo: the items out, then the folder removed.
    ASSERT_TRUE(apply(inverse(steps), &f));
    EXPECT_EQ(read(d + QStringLiteral("/a.txt")), QByteArray("a"));
    EXPECT_EQ(read(d + QStringLiteral("/b.txt")), QByteArray("b"));
    EXPECT_FALSE(present(folder));
    ASSERT_TRUE(apply(steps, &f)) << "redo";
    // The user put something else in the folder: undo takes the items out but never removes a folder that is not empty,
    // and puts everything back as it was.
    write(folder + QStringLiteral("/mine.txt"), "m");
    EXPECT_FALSE(apply(inverse(steps), &f));
    EXPECT_EQ(f.path, folder);
    EXPECT_EQ(f.error, ENOTEMPTY);
    EXPECT_EQ(read(folder + QStringLiteral("/a.txt")), QByteArray("a")) << "the items are back in the folder";
    EXPECT_EQ(read(folder + QStringLiteral("/mine.txt")), QByteArray("m"));
    // A name taken stops the command before anything moves.
    ASSERT_TRUE(QDir(folder).removeRecursively());
    write(d + QStringLiteral("/a.txt"), "a");
    write(d + QStringLiteral("/b.txt"), "b");
    write(folder, "a file in the way");
    EXPECT_FALSE(apply(steps, &f));
    EXPECT_EQ(f.step, 0);
    EXPECT_EQ(read(d + QStringLiteral("/a.txt")), QByteArray("a"));
    EXPECT_EQ(read(folder), QByteArray("a file in the way"));
}

namespace
{
// Puts the step hook and the fallback switch back whatever the test did.
struct Reset {
    ~Reset()
    {
        setStepHook({});
        forceNoReplaceFallback(false);
    }
};
} // namespace

TEST(BatchOps, ARevertThatFailsToo_ReportsWhatStayedDone)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    Reset reset;
    const QString d = dir->path();
    ASSERT_TRUE(QDir().mkpath(d + QStringLiteral("/one")));
    ASSERT_TRUE(QDir().mkpath(d + QStringLiteral("/two")));
    write(d + QStringLiteral("/one/a"), "a");
    write(d + QStringLiteral("/two/b"), "b");
    write(d + QStringLiteral("/two/taken"), "mine");
    const Steps steps{{Step::Kind::Rename, d + QStringLiteral("/one/a"), d + QStringLiteral("/one/a2")},
                      {Step::Kind::Rename, d + QStringLiteral("/two/b"), d + QStringLiteral("/two/taken")}};
    // The second step fails (the name exists); the revert of the first cannot write in its folder.
    setStepHook([&](int step) {
        if (step == 0)
            ::chmod(QFile::encodeName(d + QStringLiteral("/one")).constData(), 0500);
    });
    Failure f;
    EXPECT_FALSE(apply(steps, &f));
    ::chmod(QFile::encodeName(d + QStringLiteral("/one")).constData(), 0700);
    EXPECT_EQ(f.step, 1);
    ASSERT_EQ(f.applied.size(), 1) << "the first rename stayed done";
    EXPECT_EQ(f.applied.first().to, d + QStringLiteral("/one/a2"));
    EXPECT_EQ(read(d + QStringLiteral("/one/a2")), QByteArray("a"));
    EXPECT_EQ(read(d + QStringLiteral("/two/taken")), QByteArray("mine"));
    // The caller can put it back with the steps it was given.
    setStepHook({});
    Failure g;
    ASSERT_TRUE(apply(inverse(f.applied), &g));
    EXPECT_EQ(read(d + QStringLiteral("/one/a")), QByteArray("a"));
    // A complete revert reports nothing stayed.
    EXPECT_FALSE(apply(steps, &f));
    EXPECT_TRUE(f.applied.isEmpty());
}

TEST(BatchOps, WithoutRenameNoreplaceTheNameIsLookedAtFirst)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    Reset reset;
    forceNoReplaceFallback(true);
    const QString d = dir->path();
    write(d + QStringLiteral("/a"), "a");
    write(d + QStringLiteral("/b"), "b");
    write(d + QStringLiteral("/taken"), "mine");
    Failure f;
    // A name that exists is never replaced on this path either.
    EXPECT_FALSE(apply({{Step::Kind::Rename, d + QStringLiteral("/a"), d + QStringLiteral("/taken")}}, &f));
    EXPECT_EQ(f.error, EEXIST);
    EXPECT_EQ(read(d + QStringLiteral("/taken")), QByteArray("mine"));
    EXPECT_EQ(read(d + QStringLiteral("/a")), QByteArray("a"));
    // A free name works, and a dangling link in the way counts as taken.
    ASSERT_TRUE(QFile::link(d + QStringLiteral("/nowhere"), d + QStringLiteral("/dangling")));
    EXPECT_FALSE(apply({{Step::Kind::Rename, d + QStringLiteral("/b"), d + QStringLiteral("/dangling")}}, &f));
    EXPECT_EQ(read(d + QStringLiteral("/b")), QByteArray("b"));
    ASSERT_TRUE(apply({{Step::Kind::Rename, d + QStringLiteral("/b"), d + QStringLiteral("/b2")}}, &f));
    EXPECT_EQ(read(d + QStringLiteral("/b2")), QByteArray("b"));
}

// Audit F19: on a file system that ignores case (FAT, exFAT; actCaseInsensitive stands in for one) a case-only change in
// Rename N Items is a rename in place, and it is undone as one; nothing else that only looks like the new name is replaced.
TEST(BatchOps, ACaseOnlyRenameOnACaseInsensitiveFileSystem)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString d = dir->path();
    write(d + QStringLiteral("/photo.jpg"), "p");
    write(d + QStringLiteral("/notes.txt"), "n");
    write(d + QStringLiteral("/OTHER.txt"), "o");
    write(d + QStringLiteral("/other.txt.bak"), "b");
    actCaseInsensitive(true);
    const Steps steps = {{Step::Kind::Rename, d + QStringLiteral("/photo.jpg"), d + QStringLiteral("/Photo.JPG")},
                         {Step::Kind::Rename, d + QStringLiteral("/notes.txt"), d + QStringLiteral("/Notes.txt")}};
    Failure failure;
    const bool ok = apply(steps, &failure);
    EXPECT_TRUE(ok) << "a case-only change is no name taken (errno " << failure.error << ")";
    const QStringList names = QDir(d).entryList(QDir::Files | QDir::Hidden, QDir::Name);
    EXPECT_EQ(names, (QStringList{QStringLiteral("Notes.txt"), QStringLiteral("OTHER.txt"), QStringLiteral("Photo.JPG"), QStringLiteral("other.txt.bak")}))
        << "renamed in place, no hidden name left";
    EXPECT_EQ(read(d + QStringLiteral("/Photo.JPG")), "p");
    // Undone as one step.
    EXPECT_TRUE(apply(inverse(steps)));
    EXPECT_TRUE(QFileInfo::exists(d + QStringLiteral("/photo.jpg")));
    EXPECT_TRUE(QFileInfo::exists(d + QStringLiteral("/notes.txt")));
    // Another item spelt like the new name but for case is another file: refused, nothing moved.
    Failure taken;
    EXPECT_FALSE(apply({{Step::Kind::Rename, d + QStringLiteral("/other.txt.bak"), d + QStringLiteral("/other.txt")}}, &taken));
    EXPECT_EQ(taken.error, EEXIST);
    EXPECT_EQ(read(d + QStringLiteral("/OTHER.txt")), "o");
    EXPECT_EQ(read(d + QStringLiteral("/other.txt.bak")), "b");
    actCaseInsensitive(false);
}

// The in-place exception never takes a hard link of the item for the item itself: the exact name is another entry.
TEST(BatchOps, AHardLinkUnderTheNewNameIsATakenName)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString d = dir->path();
    write(d + QStringLiteral("/a"), "a");
    ASSERT_EQ(::link(QFile::encodeName(d + QStringLiteral("/a")).constData(), QFile::encodeName(d + QStringLiteral("/b")).constData()), 0);
    for (bool fallback : {false, true}) {
        forceNoReplaceFallback(fallback);
        Failure failure;
        EXPECT_FALSE(apply({{Step::Kind::Rename, d + QStringLiteral("/a"), d + QStringLiteral("/b")}}, &failure));
        EXPECT_EQ(failure.error, EEXIST);
        EXPECT_TRUE(QFileInfo::exists(d + QStringLiteral("/a"))) << "the item stays where it is";
        EXPECT_TRUE(QFileInfo::exists(d + QStringLiteral("/b")));
    }
    forceNoReplaceFallback(false);
}
