// Compress and Expand (ADR-0029): the Finder's names, bsdtar's command lines, and real round trips with bsdtar on files
// under GRASSFIELD_TEST_TMP (a directory inside .dev/; skipped without it or without bsdtar), with a hostile archive that
// must write nothing outside its folder.
#include "archivejob.h"
#include "archivelogic.h"

#include <QCoreApplication>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QProcess>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTimer>

#include <memory>

#include <gtest/gtest.h>

using namespace ArchiveLogic;

namespace
{
void ensureApp()
{
    static int argc = 1;
    static char name[] = "tst_archive";
    static char *argv[] = {name, nullptr};
    if (!QCoreApplication::instance())
        new QCoreApplication(argc, argv);
}

std::unique_ptr<QTemporaryDir> sandbox(QString *why)
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    if (base.isEmpty() || !QDir::cleanPath(base).contains(QLatin1String("/.dev/"))) {
        *why = QStringLiteral("GRASSFIELD_TEST_TMP (a directory under .dev/) is not set");
        return nullptr;
    }
    QDir().mkpath(base);
    // ArchiveJob records its staging names in the state folder (ArchiveJob::stagingRegistry): the test's own, never the
    // session's (a job that can't record its name doesn't start).
    qputenv("GRASSFIELD_STATE_HOME", QFile::encodeName(base + QStringLiteral("/archive-state")));
    auto dir = std::make_unique<QTemporaryDir>(base + QStringLiteral("/archive-XXXXXX"));
    if (!dir->isValid()) {
        *why = QStringLiteral("cannot create a directory in ") + base;
        return nullptr;
    }
    return dir;
}

void write(const QString &path, const QByteArray &bytes)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(bytes);
}

QByteArray read(const QString &path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

struct Result {
    bool ok = false;
    QString error;
    QString path;
};

Result runJob(ArchiveJob *job)
{
    Result r;
    bool done = false;
    QEventLoop loop;
    QObject::connect(job, &ArchiveJob::finished, &loop, [&](bool ok, const QString &error, const QString &path) {
        r = {ok, error, path};
        done = true;
        loop.quit();
    });
    QTimer::singleShot(20000, &loop, &QEventLoop::quit);
    job->start();
    // A job refused at once (no bsdtar) has finished before the loop runs.
    if (!done)
        loop.exec();
    delete job;
    return r;
}

QStringList hiddenLeftovers(const QString &folder)
{
    return QDir(folder).entryList({QStringLiteral(".grassfield-*")}, QDir::AllEntries | QDir::Hidden | QDir::System);
}
} // namespace

TEST(ArchiveNames, FinderNames)
{
    QStringList taken;
    const auto exists = [&taken](const QString &n) { return taken.contains(n); };
    EXPECT_EQ(compressName({QStringLiteral("report.txt")}, exists), QStringLiteral("report.txt.zip"));
    EXPECT_EQ(compressName({QStringLiteral("a"), QStringLiteral("b")}, exists), QStringLiteral("Archive.zip"));
    taken = {QStringLiteral("Archive.zip")};
    EXPECT_EQ(compressName({QStringLiteral("a"), QStringLiteral("b")}, exists), QStringLiteral("Archive 2.zip"));

    taken.clear();
    EXPECT_EQ(expandName(QStringLiteral("photos.tar.gz"), {QStringLiteral("a"), QStringLiteral("b")}, exists), QStringLiteral("photos"));
    EXPECT_EQ(expandName(QStringLiteral("photos.zip"), {QStringLiteral("Trip")}, exists), QStringLiteral("Trip")) << "one item keeps its name";
    taken = {QStringLiteral("notes.txt"), QStringLiteral("photos")};
    EXPECT_EQ(expandName(QStringLiteral("x.zip"), {QStringLiteral("notes.txt")}, exists), QStringLiteral("notes 2.txt"));
    EXPECT_EQ(expandName(QStringLiteral("photos.7z"), {QStringLiteral("a"), QStringLiteral("b")}, exists), QStringLiteral("photos 2"));

    EXPECT_TRUE(isArchive(QStringLiteral("A.ZIP")));
    EXPECT_TRUE(isArchive(QStringLiteral("x.tar.zst")));
    EXPECT_TRUE(isArchive(QStringLiteral("x.tgz")));
    EXPECT_FALSE(isArchive(QStringLiteral("x.gz"))) << "a lone gzip is left to the applications";
    EXPECT_FALSE(isArchive(QStringLiteral(".zip")));
    EXPECT_EQ(stripArchiveExtension(QStringLiteral("a.b.tar.xz")), QStringLiteral("a.b"));
}

TEST(ArchiveCommands, ArgumentsAndListing)
{
    EXPECT_EQ(compressArgs(QStringLiteral("/d/.t.zip"), QStringLiteral("/d"), {QStringLiteral("@notes"), QStringLiteral("-rf")}),
              (QStringList{QStringLiteral("--format"), QStringLiteral("zip"), QStringLiteral("-s"), QStringLiteral(",^\\./,,S"), QStringLiteral("-cf"),
                           QStringLiteral("/d/.t.zip"), QStringLiteral("-C"), QStringLiteral("/d"), QStringLiteral("--"), QStringLiteral("./@notes"),
                           QStringLiteral("./-rf")}))
        << "every name behind ./ (an @name is an archive to bsdtar)";
    const QStringList x = expandArgs(QStringLiteral("/d/a.zip"), QStringLiteral("/d/.t"));
    EXPECT_FALSE(x.contains(QStringLiteral("-P"))) << "absolute members and .. refused by bsdtar";
    EXPECT_TRUE(x.contains(QStringLiteral("--no-same-owner")));
    EXPECT_TRUE(x.contains(QStringLiteral("--no-same-permissions")));
    EXPECT_EQ(listedSize(QStringLiteral("-rw-r--r--  0 u g    1200 Oct 26 12:00 a\ndrwxr-xr-x  0 u g       0 Oct 26 12:00 d/\n")), qint64(1200));
    EXPECT_FALSE(listedSize(QStringLiteral("-rw-r--r--  0 a user g 12 Oct 26 12:00 a\n")).has_value()) << "an owner with a space";
    EXPECT_EQ(failureOf(QStringLiteral("bsdtar: Passphrase required for this entry")), Failure::Encrypted);
    EXPECT_EQ(failureOf(QStringLiteral("bsdtar: Error opening archive")), Failure::Other);
}

TEST(ArchiveJobs, CompressThenExpandRoundTrip)
{
    ensureApp();
    const QString bsdtar = QStandardPaths::findExecutable(QStringLiteral("bsdtar"));
    if (bsdtar.isEmpty())
        GTEST_SKIP() << "bsdtar is not installed";
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString src = dir->path() + QStringLiteral("/src");
    write(src + QStringLiteral("/@notes"), "at sign");
    write(src + QStringLiteral("/Folder/inner.txt"), "inner");
    ASSERT_TRUE(QFile::link(QStringLiteral("./@notes"), src + QStringLiteral("/link")));

    Result r = runJob(ArchiveJob::compress(bsdtar, src, {QStringLiteral("@notes"), QStringLiteral("Folder"), QStringLiteral("link")}));
    ASSERT_TRUE(r.ok) << r.error.toStdString();
    EXPECT_EQ(QFileInfo(r.path).fileName(), QStringLiteral("Archive.zip"));
    EXPECT_TRUE(hiddenLeftovers(src).isEmpty());

    // Expanded next to itself: several items go into a folder named after the archive.
    r = runJob(ArchiveJob::expand(bsdtar, src + QStringLiteral("/Archive.zip")));
    ASSERT_TRUE(r.ok) << r.error.toStdString();
    EXPECT_EQ(r.path, src + QStringLiteral("/Archive"));
    EXPECT_EQ(read(src + QStringLiteral("/Archive/@notes")), QByteArray("at sign"));
    EXPECT_EQ(read(src + QStringLiteral("/Archive/Folder/inner.txt")), QByteArray("inner"));
    EXPECT_EQ(QFileInfo(src + QStringLiteral("/Archive/link")).symLinkTarget(), src + QStringLiteral("/Archive/@notes")) << "a link stays a link, its target untouched";
    EXPECT_TRUE(hiddenLeftovers(src).isEmpty());

    // Again: the name is taken, " 2".
    r = runJob(ArchiveJob::expand(bsdtar, src + QStringLiteral("/Archive.zip")));
    ASSERT_TRUE(r.ok);
    EXPECT_EQ(QFileInfo(r.path).fileName(), QStringLiteral("Archive 2"));

    // Compress again with "Archive.zip" taken: the new archive is "Archive 2.zip" and the existing one is left exactly as it
    // was (Compress never replaces an archive).
    const QByteArray before = read(src + QStringLiteral("/Archive.zip"));
    ASSERT_FALSE(before.isEmpty());
    write(src + QStringLiteral("/@notes"), "changed since");
    r = runJob(ArchiveJob::compress(bsdtar, src, {QStringLiteral("@notes"), QStringLiteral("Folder"), QStringLiteral("link")}));
    ASSERT_TRUE(r.ok) << r.error.toStdString();
    EXPECT_EQ(QFileInfo(r.path).fileName(), QStringLiteral("Archive 2.zip"));
    EXPECT_EQ(read(src + QStringLiteral("/Archive.zip")), before) << "the existing archive is untouched";
    EXPECT_NE(read(src + QStringLiteral("/Archive 2.zip")), before);
    EXPECT_TRUE(hiddenLeftovers(src).isEmpty());

    // One item: it keeps its name.
    r = runJob(ArchiveJob::compress(bsdtar, src, {QStringLiteral("Folder")}));
    ASSERT_TRUE(r.ok);
    EXPECT_EQ(QFileInfo(r.path).fileName(), QStringLiteral("Folder.zip"));
    QDir(src + QStringLiteral("/Folder")).removeRecursively();
    r = runJob(ArchiveJob::expand(bsdtar, src + QStringLiteral("/Folder.zip")));
    ASSERT_TRUE(r.ok);
    EXPECT_EQ(r.path, src + QStringLiteral("/Folder"));
    EXPECT_EQ(read(src + QStringLiteral("/Folder/inner.txt")), QByteArray("inner"));
}

TEST(ArchiveJobs, HostileArchivesWriteNothingOutside)
{
    ensureApp();
    const QString bsdtar = QStandardPaths::findExecutable(QStringLiteral("bsdtar"));
    if (bsdtar.isEmpty())
        GTEST_SKIP() << "bsdtar is not installed";
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString work = dir->path() + QStringLiteral("/work");
    write(dir->path() + QStringLiteral("/payload"), "escaped");
    QDir().mkpath(work);
    // A member named "../payload-out" (bsdtar's -s writes it so).
    QProcess p;
    p.setWorkingDirectory(dir->path());
    p.start(bsdtar, {QStringLiteral("-cf"), work + QStringLiteral("/evil.tar"), QStringLiteral("-s"), QStringLiteral(",^payload$,../payload-out,"), QStringLiteral("payload")});
    ASSERT_TRUE(p.waitForFinished(10000));
    ASSERT_EQ(p.exitCode(), 0) << p.readAllStandardError().toStdString();

    const Result r = runJob(ArchiveJob::expand(bsdtar, work + QStringLiteral("/evil.tar")));
    // An escape lands one level above the temporary folder, which is inside the archive's own folder: `work`. Without
    // bsdtar's refusal of ".." (it is the absence of -P that keeps it) "payload-out" would be written right here.
    EXPECT_FALSE(QFileInfo::exists(work + QStringLiteral("/payload-out"))) << "nothing in the archive's own folder from a ../ member";
    EXPECT_FALSE(QFileInfo::exists(dir->path() + QStringLiteral("/payload-out"))) << "nor two folders up";
    EXPECT_TRUE(hiddenLeftovers(work).isEmpty()) << "no temporary folder left behind";
    if (r.ok) {
        EXPECT_TRUE(r.path.startsWith(work + QLatin1Char('/')));
    }

    // An absolute member name (written with -P, which only the archive's author has): extracting must not follow it.
    const QString absolute = dir->path() + QStringLiteral("/absolute-out");
    p.start(bsdtar, {QStringLiteral("-cPf"), work + QStringLiteral("/abs.tar"), QStringLiteral("-s"), QStringLiteral(",^payload$,") + absolute + QStringLiteral(",") , QStringLiteral("payload")});
    ASSERT_TRUE(p.waitForFinished(10000));
    ASSERT_EQ(p.exitCode(), 0) << p.readAllStandardError().toStdString();
    const Result abs = runJob(ArchiveJob::expand(bsdtar, work + QStringLiteral("/abs.tar")));
    EXPECT_FALSE(QFileInfo::exists(absolute)) << "an absolute member name is not written where it says";
    EXPECT_TRUE(hiddenLeftovers(work).isEmpty());
    if (abs.ok) {
        EXPECT_TRUE(abs.path.startsWith(work + QLatin1Char('/')));
    }

    // Not an archive at all: a failure, the temporary folder removed.
    write(work + QStringLiteral("/broken.zip"), "not a zip");
    const Result broken = runJob(ArchiveJob::expand(bsdtar, work + QStringLiteral("/broken.zip")));
    EXPECT_FALSE(broken.ok);
    EXPECT_FALSE(broken.error.isEmpty());
    EXPECT_TRUE(hiddenLeftovers(work).isEmpty());

    // bsdtar missing: refused at once.
    const Result missing = runJob(ArchiveJob::expand(QString(), work + QStringLiteral("/evil.tar")));
    EXPECT_FALSE(missing.ok);
}

TEST(ArchiveJobs, CancelRemovesTheTemporaryName)
{
    ensureApp();
    const QString bsdtar = QStandardPaths::findExecutable(QStringLiteral("bsdtar"));
    if (bsdtar.isEmpty())
        GTEST_SKIP() << "bsdtar is not installed";
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    write(dir->path() + QStringLiteral("/a"), QByteArray(1024 * 1024, 'x'));
    auto *job = ArchiveJob::compress(bsdtar, dir->path(), {QStringLiteral("a")});
    bool done = false;
    QString error = QStringLiteral("unset");
    QObject::connect(job, &ArchiveJob::finished, [&](bool ok, const QString &e, const QString &) {
        done = !ok;
        error = e;
    });
    job->start();
    job->cancel();
    EXPECT_TRUE(done);
    EXPECT_TRUE(error.isEmpty()) << "a cancel is no error";
    delete job;
    EXPECT_TRUE(hiddenLeftovers(dir->path()).isEmpty());
    EXPECT_FALSE(QFileInfo::exists(dir->path() + QStringLiteral("/a.zip")));
}
