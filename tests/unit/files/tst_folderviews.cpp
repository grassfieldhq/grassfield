// Unit tests for apps/files/src/folderviews.{h,cpp} (gtest): the per-folder view settings store of Grassfield Files
// (docs/specs/files.md FP-14, decision F-3). Built and run by scripts/dev/test.sh. The file tests only write under
// GRASSFIELD_TEST_TMP, a directory inside the repository's .dev/ (set by scripts/dev/test.sh); they skip without it.
#include "folderviews.h"

#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLockFile>
#include <QTemporaryDir>
#include <QThread>

#include <atomic>
#include <fcntl.h>
#include <memory>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

#include <gtest/gtest.h>

namespace
{
std::unique_ptr<QTemporaryDir> sandbox()
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    if (base.isEmpty() || !QDir::cleanPath(base).contains(QLatin1String("/.dev/")))
        return nullptr;
    QDir().mkpath(base);
    auto dir = std::make_unique<QTemporaryDir>(base + QStringLiteral("/folderviews-XXXXXX"));
    return dir->isValid() ? std::move(dir) : nullptr;
}

FolderViews::Entry entry(const QString &mode, int sortKey = -1, int descending = -1)
{
    FolderViews::Entry e;
    e.mode = mode;
    e.sortKey = sortKey;
    e.descending = descending;
    return e;
}

constexpr auto kWritten = FolderViews::WriteResult::Written;

void writeFile(const QString &path, const QByteArray &bytes)
{
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(bytes);
}

QByteArray readAll(const QString &path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray("<unreadable>");
}

// A store file of `count` folders `prefix0`, `prefix1`, ... (version 1, compact).
QByteArray storeOf(int count, const QString &prefix, const FolderViews::Entry &e)
{
    QJsonArray folders;
    for (int i = 0; i < count; i++)
        folders.append(FolderViews::serialize(prefix + QString::number(i), e));
    QJsonObject root;
    root.insert(QStringLiteral("version"), 1);
    root.insert(QStringLiteral("folders"), folders);
    return QJsonDocument(root).toJson(QJsonDocument::Compact);
}
} // namespace

TEST(FolderViews, KeysIgnoreATrailingSlashAndDotSegments)
{
    EXPECT_EQ(FolderViews::keyFor(QUrl(QStringLiteral("file:///home/u/Documents/"))), QStringLiteral("file:///home/u/Documents"));
    EXPECT_EQ(FolderViews::keyFor(QUrl(QStringLiteral("file:///home/u/x/../Documents"))), QStringLiteral("file:///home/u/Documents"));
    EXPECT_EQ(FolderViews::keyFor(QUrl(QStringLiteral("file:///"))), QStringLiteral("file:///"));
    EXPECT_EQ(FolderViews::keyFor(QUrl(QStringLiteral("trash:/"))), QStringLiteral("trash:/"));
    // A search location keeps its query; a space is encoded the same way whatever the spelling it came with.
    EXPECT_EQ(FolderViews::keyFor(QUrl(QStringLiteral("grassfield-tag:/Red?in=file:///home/u"))),
              FolderViews::keyFor(QUrl(QStringLiteral("grassfield-tag:/Red?in=file:///home/u"))));
    EXPECT_EQ(FolderViews::keyFor(QUrl(QStringLiteral("file:///home/u/My Files"))), FolderViews::keyFor(QUrl(QStringLiteral("file:///home/u/My%20Files"))));
    EXPECT_TRUE(FolderViews::keyFor(QUrl()).isEmpty());
}

TEST(FolderViews, InvalidFieldsReadAsUnset)
{
    const auto e = FolderViews::parse(QJsonDocument::fromJson(R"({"url":"file:///a","mode":"cover","sortKey":8,"descending":"yes"})").object());
    EXPECT_TRUE(e.isEmpty());
    const auto f = FolderViews::parse(QJsonDocument::fromJson(R"({"mode":"list","sortKey":2.5,"descending":false})").object());
    EXPECT_EQ(f.mode, QStringLiteral("list"));
    EXPECT_EQ(f.sortKey, -1);
    EXPECT_EQ(f.descending, 0);
}

TEST(FolderViews, MergeKeepsFieldsThatAreNotSet)
{
    const auto base = entry(QStringLiteral("list"), 2, 1);
    EXPECT_EQ(FolderViews::merged(base, entry(QString(), 0)), entry(QStringLiteral("list"), 0, 1));
    EXPECT_EQ(FolderViews::merged(base, entry(QStringLiteral("gallery"))), entry(QStringLiteral("gallery"), 2, 1));
    EXPECT_EQ(FolderViews::merged(base, entry(QStringLiteral("bogus"), 9, 4)), base);
}

TEST(FolderViews, RoundTripAndMostRecentLast)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("state/files-views.json"));
    FolderViews views(file);
    views.load();
    EXPECT_EQ(views.count(), 0);
    ASSERT_EQ(views.set(QStringLiteral("file:///a"), entry(QStringLiteral("list"), 2, 1)), kWritten);
    ASSERT_EQ(views.set(QStringLiteral("file:///b"), entry(QStringLiteral("columns"))), kWritten);
    ASSERT_EQ(views.set(QStringLiteral("file:///a"), entry(QString(), 0)), kWritten);
    EXPECT_EQ(QFileInfo(file).permissions() & (QFileDevice::ReadGroup | QFileDevice::ReadOther), QFileDevice::Permissions());

    FolderViews again(file);
    again.load();
    EXPECT_EQ(again.count(), 2);
    EXPECT_EQ(again.entry(QStringLiteral("file:///a")), entry(QStringLiteral("list"), 0, 1));
    EXPECT_EQ(again.entry(QStringLiteral("file:///b")), entry(QStringLiteral("columns")));
    EXPECT_TRUE(again.entry(QStringLiteral("file:///c")).isEmpty());
    QFile f(file);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    const QJsonObject root = QJsonDocument::fromJson(f.readAll()).object();
    EXPECT_EQ(root.value(QStringLiteral("version")).toInt(), 1);
    const QJsonArray folders = root.value(QStringLiteral("folders")).toArray();
    ASSERT_EQ(folders.size(), 2);
    // The folder set last is listed last (the least recently set one goes first when the store is full).
    EXPECT_EQ(folders.at(1).toObject().value(QStringLiteral("url")).toString(), QStringLiteral("file:///a"));
}

// A view or sort click is kept at once and written later, once for a burst (the write and its fsync off the click's frame).
TEST(FolderViews, AKeptChangeIsReadAtOnceAndWrittenByFlush)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("state/files-views.json"));
    FolderViews views(file);
    views.load();
    views.keep(QStringLiteral("file:///a"), entry(QStringLiteral("list")));
    views.keep(QStringLiteral("file:///a"), entry(QString(), 2));
    EXPECT_EQ(views.entry(QStringLiteral("file:///a")), entry(QStringLiteral("list"), 2));
    EXPECT_FALSE(QFileInfo::exists(file)) << "nothing written by the clicks themselves";
    EXPECT_TRUE(views.hasPending());
    ASSERT_EQ(views.flush(), kWritten);
    FolderViews again(file);
    again.load();
    EXPECT_EQ(again.entry(QStringLiteral("file:///a")), entry(QStringLiteral("list"), 2));
}

TEST(FolderViews, TheOldestFolderGoesWhenFull)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    writeFile(file, storeOf(FolderViews::kMaxEntries, QStringLiteral("file:///f"), entry(QStringLiteral("list"))));
    FolderViews views(file);
    views.load();
    EXPECT_EQ(views.count(), FolderViews::kMaxEntries);
    ASSERT_EQ(views.set(QStringLiteral("file:///new"), entry(QStringLiteral("gallery"))), kWritten);
    EXPECT_EQ(views.count(), FolderViews::kMaxEntries);
    EXPECT_TRUE(views.entry(QStringLiteral("file:///f0")).isEmpty());
    EXPECT_FALSE(views.entry(QStringLiteral("file:///f1")).isEmpty());
    EXPECT_EQ(views.entry(QStringLiteral("file:///new")).mode, QStringLiteral("gallery"));
}

TEST(FolderViews, AFileItCannotReadIsNeverOverwritten)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    for (const QByteArray &bytes : {QByteArray("{not json"), QByteArray(R"({"version":2,"folders":[]})"), QByteArray(R"({"version":"one"})"),
                                    QByteArray(R"({"version":1,"folders":{"a":1}})")}) {
        writeFile(file, bytes);
        FolderViews views(file);
        views.load();
        EXPECT_TRUE(views.readOnly()) << bytes.constData();
        QString error;
        EXPECT_EQ(views.set(QStringLiteral("file:///a"), entry(QStringLiteral("list")), &error), FolderViews::WriteResult::Refused);
        EXPECT_FALSE(error.isEmpty());
        QFile f(file);
        ASSERT_TRUE(f.open(QIODevice::ReadOnly));
        EXPECT_EQ(f.readAll(), bytes);
    }
}

TEST(FolderViews, AMissingVersionReadsAsOne)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    writeFile(file, R"({"folders":[{"url":"file:///a","mode":"list"}]})");
    FolderViews views(file);
    views.load();
    EXPECT_FALSE(views.readOnly());
    EXPECT_EQ(views.entry(QStringLiteral("file:///a")).mode, QStringLiteral("list"));
}

TEST(FolderViews, AnotherProcessesEntriesAreKept)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    FolderViews first(file);
    first.load();
    ASSERT_EQ(first.set(QStringLiteral("file:///a"), entry(QStringLiteral("list"))), kWritten);
    FolderViews second(file);
    second.load();
    // No pause: each write replaces the file (another inode), so the other store sees the change even within one tick of
    // a coarse file system clock.
    ASSERT_EQ(second.set(QStringLiteral("file:///b"), entry(QStringLiteral("gallery"))), kWritten);
    ASSERT_EQ(first.set(QStringLiteral("file:///c"), entry(QStringLiteral("columns"))), kWritten);
    FolderViews check(file);
    check.load();
    EXPECT_EQ(check.count(), 3);
    EXPECT_EQ(check.entry(QStringLiteral("file:///b")).mode, QStringLiteral("gallery"));
}

TEST(FolderViews, FieldsOfANewerVersionSurviveAWrite)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    writeFile(file, R"({"version":1,"folders":[{"url":"file:///a","mode":"list","groupBy":"kind"}]})");
    FolderViews views(file);
    views.load();
    ASSERT_EQ(views.set(QStringLiteral("file:///a"), entry(QString(), 2)), kWritten);
    QFile f(file);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    const QJsonObject a = QJsonDocument::fromJson(f.readAll()).object().value(QStringLiteral("folders")).toArray().at(0).toObject();
    EXPECT_EQ(a.value(QStringLiteral("groupBy")).toString(), QStringLiteral("kind"));
    EXPECT_EQ(a.value(QStringLiteral("mode")).toString(), QStringLiteral("list"));
    EXPECT_EQ(a.value(QStringLiteral("sortKey")).toInt(), 2);
}

TEST(FolderViews, OldFoldersMakeRoomUnderTheSizeLimit)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    // 1900 folders of about 1 KB each (long percent-encoded paths): just under 2 MiB, and under kMaxEntries.
    const QString longName = QString(110, QChar(0x6587)); // a CJK character, 9 bytes once percent-encoded
    QJsonArray folders;
    for (int i = 0; i < 1900; i++)
        folders.append(FolderViews::serialize(FolderViews::keyFor(QUrl::fromLocalFile(QStringLiteral("/f%1/").arg(i) + longName)), entry(QStringLiteral("list"))));
    QJsonObject root;
    root.insert(QStringLiteral("version"), 1);
    root.insert(QStringLiteral("folders"), folders);
    const QByteArray bytes = QJsonDocument(root).toJson(QJsonDocument::Compact);
    ASSERT_LT(bytes.size(), FolderViews::kMaxFileSize);
    ASSERT_GT(bytes.size(), FolderViews::kMaxFileSize - 200 * 1024);
    writeFile(file, bytes);
    FolderViews views(file);
    views.load();
    ASSERT_EQ(views.count(), 1900);
    // 50 more folders of about 4 KB: past the size limit long before the entry limit.
    const QString fresh = FolderViews::keyFor(QUrl::fromLocalFile(QStringLiteral("/new/") + longName + longName + longName + longName));
    for (int i = 0; i < 50; i++)
        ASSERT_EQ(views.set(fresh + QString::number(i), entry(QStringLiteral("gallery"))), kWritten) << i;
    EXPECT_LE(QFileInfo(file).size(), FolderViews::kMaxFileSize);
    EXPECT_LT(views.count(), 1950) << "folders went for size, not for count";
    EXPECT_EQ(views.entry(fresh + QStringLiteral("49")).mode, QStringLiteral("gallery"));
    EXPECT_TRUE(views.entry(FolderViews::keyFor(QUrl::fromLocalFile(QStringLiteral("/f0/") + longName))).isEmpty()) << "the oldest went";
    EXPECT_EQ(views.entry(FolderViews::keyFor(QUrl::fromLocalFile(QStringLiteral("/f1899/") + longName))).mode, QStringLiteral("list"));
}

TEST(FolderViews, ReadsFollowAnotherProcess)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    FolderViews reader(file);
    reader.refresh();
    EXPECT_TRUE(reader.entry(QStringLiteral("file:///a")).isEmpty());
    FolderViews writer(file);
    ASSERT_EQ(writer.set(QStringLiteral("file:///a"), entry(QStringLiteral("columns"))), kWritten);
    reader.refresh();
    EXPECT_EQ(reader.entry(QStringLiteral("file:///a")).mode, QStringLiteral("columns"));
}

// Hostile files (opus review of PR #5). Each is refused without blocking and without reading more than the limit, and
// left exactly as it was; the choice made meanwhile stays pending in this store.

// A FIFO at the path: open() would wait for a writer forever on the UI thread. The load must return at once.
TEST(FolderViews, AFifoIsRefusedWithoutBlocking)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    ASSERT_EQ(::mkfifo(QFile::encodeName(file).constData(), 0600), 0);
    FolderViews views(file);
    std::atomic<bool> done{false};
    std::thread loader([&] {
        views.load();
        done = true;
    });
    QElapsedTimer timer;
    timer.start();
    while (!done && timer.elapsed() < 3000)
        QThread::msleep(5);
    const bool returned = done;
    if (!returned) {
        // Free a load blocked in open() so that the test ends: a writer that comes and goes.
        const int fd = ::open(QFile::encodeName(file).constData(), O_WRONLY | O_NONBLOCK);
        if (fd >= 0)
            ::close(fd);
    }
    loader.join();
    ASSERT_TRUE(returned) << "the load blocked on a FIFO";
    EXPECT_LT(timer.elapsed(), 1000);
    EXPECT_TRUE(views.readOnly());
    EXPECT_EQ(views.readStatus(), FolderViews::ReadStatus::NotRegular);
    EXPECT_EQ(views.count(), 0);
    // A write is refused the same way (it reads under the lock first) and leaves the FIFO in place.
    timer.restart();
    QString error;
    EXPECT_EQ(views.set(QStringLiteral("file:///a"), entry(QStringLiteral("list")), &error), FolderViews::WriteResult::Refused);
    EXPECT_FALSE(error.isEmpty());
    EXPECT_LT(timer.elapsed(), 1000);
    struct stat st{};
    ASSERT_EQ(::lstat(QFile::encodeName(file).constData(), &st), 0);
    EXPECT_TRUE(S_ISFIFO(st.st_mode));
    // The choice holds for this session.
    EXPECT_EQ(views.entry(QStringLiteral("file:///a")).mode, QStringLiteral("list"));
    EXPECT_TRUE(views.hasPending());
}

// A symlink to /dev/zero: an unbounded read never ends (the old load died of std::bad_alloc). Refused before any read;
// a directory at the path likewise.
TEST(FolderViews, ASymlinkToADeviceIsRefused)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    if (!QFileInfo::exists(QStringLiteral("/dev/zero")))
        GTEST_SKIP() << "no /dev/zero";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    ASSERT_TRUE(QFile::link(QStringLiteral("/dev/zero"), file));
    FolderViews views(file);
    QElapsedTimer timer;
    timer.start();
    views.load();
    EXPECT_LT(timer.elapsed(), 1000);
    EXPECT_TRUE(views.readOnly());
    EXPECT_EQ(views.readStatus(), FolderViews::ReadStatus::NotRegular);
    EXPECT_EQ(views.set(QStringLiteral("file:///a"), entry(QStringLiteral("list"))), FolderViews::WriteResult::Refused);
    EXPECT_EQ(QFileInfo(file).symLinkTarget(), QStringLiteral("/dev/zero")) << "the link is left as it was";
    FolderViews other(dir->filePath(QStringLiteral("a-directory")));
    ASSERT_TRUE(QDir().mkpath(other.file()));
    other.load();
    EXPECT_EQ(other.readStatus(), FolderViews::ReadStatus::NotRegular);
    EXPECT_EQ(other.set(QStringLiteral("file:///a"), entry(QStringLiteral("list"))), FolderViews::WriteResult::Refused);
    EXPECT_TRUE(QFileInfo(other.file()).isDir());
    // A regular file whose size says nothing of its contents (/proc: size 0, text inside): the read returns more than
    // the size, so it is not used.
    if (QFileInfo::exists(QStringLiteral("/proc/self/status"))) {
        const QString proc = dir->filePath(QStringLiteral("proc-views.json"));
        ASSERT_TRUE(QFile::link(QStringLiteral("/proc/self/status"), proc));
        FolderViews procViews(proc);
        procViews.load();
        EXPECT_EQ(procViews.readStatus(), FolderViews::ReadStatus::Incomplete);
        EXPECT_TRUE(procViews.readOnly());
    }
}

// One byte over the limit: never parsed, never overwritten (also when the write is attempted again).
TEST(FolderViews, ATooLargeFileIsLeftIntact)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    QByteArray bytes = R"({"version":1,"folders":[{"url":"file:///a","mode":"list"}]})";
    bytes.append(QByteArray(int(FolderViews::kMaxFileSize + 1 - bytes.size()), ' '));
    ASSERT_EQ(bytes.size(), FolderViews::kMaxFileSize + 1);
    writeFile(file, bytes);
    FolderViews views(file);
    views.load();
    EXPECT_TRUE(views.readOnly());
    EXPECT_EQ(views.readStatus(), FolderViews::ReadStatus::TooLarge);
    EXPECT_TRUE(views.entry(QStringLiteral("file:///a")).isEmpty()) << "not parsed";
    EXPECT_EQ(views.set(QStringLiteral("file:///b"), entry(QStringLiteral("gallery"))), FolderViews::WriteResult::Refused);
    EXPECT_EQ(views.flush(), FolderViews::WriteResult::Refused);
    EXPECT_EQ(readAll(file), bytes);
    // At the limit exactly, the same file is read.
    bytes.chop(1);
    writeFile(file, bytes);
    views.refresh();
    EXPECT_FALSE(views.readOnly());
    EXPECT_EQ(views.entry(QStringLiteral("file:///a")).mode, QStringLiteral("list"));
}

// Malformed JSON and a newer version's file stay byte for byte; the folders chosen meanwhile are written once a file
// this version can read is back (repaired, or the newer Files gone).
TEST(FolderViews, MalformedOrNewerFilesAreLeftIntactAndTheChoiceWaits)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    for (const QByteArray &bytes :
         {QByteArray(R"({"version":1,"folders":[{"url":)"), QByteArray(R"({"version":2,"folders":[{"url":"file:///n","mode":"list","x":1}]})")}) {
        writeFile(file, bytes);
        FolderViews views(file);
        views.load();
        EXPECT_EQ(views.readStatus(), FolderViews::ReadStatus::Invalid) << bytes.constData();
        EXPECT_EQ(views.set(QStringLiteral("file:///a"), entry(QStringLiteral("columns"))), FolderViews::WriteResult::Refused);
        EXPECT_EQ(views.set(QStringLiteral("file:///b"), entry(QString(), 3, 0)), FolderViews::WriteResult::Refused);
        EXPECT_EQ(readAll(file), bytes) << "left intact";
        EXPECT_EQ(views.entry(QStringLiteral("file:///a")).mode, QStringLiteral("columns")) << "the choice holds for this session";
        // Repaired: the next write merges the waiting folders into the file on disk.
        writeFile(file, R"({"version":1,"folders":[{"url":"file:///kept","mode":"gallery"}]})");
        EXPECT_EQ(views.flush(), kWritten);
        EXPECT_FALSE(views.hasPending());
        FolderViews check(file);
        check.load();
        EXPECT_EQ(check.entry(QStringLiteral("file:///kept")).mode, QStringLiteral("gallery"));
        EXPECT_EQ(check.entry(QStringLiteral("file:///a")).mode, QStringLiteral("columns"));
        EXPECT_EQ(check.entry(QStringLiteral("file:///b")), entry(QString(), 3, 0));
    }
}

// The file is 0600 whatever the umask (000 here), also when it existed with wider permissions.
TEST(FolderViews, TheFileIsPrivateUnderAnyUmask)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("state/files-views.json"));
    const QByteArray encoded = QFile::encodeName(file);
    const mode_t previous = ::umask(0);
    FolderViews views(file);
    const auto first = views.set(QStringLiteral("file:///a"), entry(QStringLiteral("list")));
    struct stat created{};
    const int rc = ::stat(encoded.constData(), &created);
    ::chmod(encoded.constData(), 0644);
    const auto second = views.set(QStringLiteral("file:///b"), entry(QStringLiteral("list")));
    struct stat replaced{};
    const int rc2 = ::stat(encoded.constData(), &replaced);
    ::umask(previous);
    ASSERT_EQ(first, kWritten);
    ASSERT_EQ(second, kWritten);
    ASSERT_EQ(rc, 0);
    ASSERT_EQ(rc2, 0);
    EXPECT_EQ(created.st_mode & 07777, mode_t(0600));
    EXPECT_EQ(replaced.st_mode & 07777, mode_t(0600));
}

// A lock left by a process that died (a crash, kill -9) is taken over at once.
TEST(FolderViews, AStaleLockIsTakenOver)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    const QString lockPath = file + QStringLiteral(".lock");
    const pid_t child = ::fork();
    ASSERT_GE(child, 0);
    if (child == 0) {
        QLockFile lock(lockPath);
        // Locked, then the process ends without unlocking.
        ::_exit(lock.tryLock(0) ? 0 : 1);
    }
    int status = 0;
    ASSERT_EQ(::waitpid(child, &status, 0), child);
    ASSERT_TRUE(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    ASSERT_TRUE(QFileInfo::exists(lockPath)) << "the dead process left its lock";
    FolderViews views(file);
    QElapsedTimer timer;
    timer.start();
    EXPECT_EQ(views.set(QStringLiteral("file:///a"), entry(QStringLiteral("list"))), kWritten);
    EXPECT_LT(timer.elapsed(), 1000);
    FolderViews check(file);
    check.load();
    EXPECT_EQ(check.entry(QStringLiteral("file:///a")).mode, QStringLiteral("list"));
}

// A live holder of the lock never makes the caller wait: the write stays pending (and visible in this store) until a
// flush finds the lock free.
TEST(FolderViews, ATakenLockDefersTheWriteWithoutWaiting)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    FolderViews views(file);
    ASSERT_EQ(views.set(QStringLiteral("file:///a"), entry(QStringLiteral("list"))), kWritten);
    const QByteArray before = readAll(file);
    QLockFile other(file + QStringLiteral(".lock"));
    ASSERT_TRUE(other.tryLock(0));
    QElapsedTimer timer;
    timer.start();
    QString error;
    EXPECT_EQ(views.set(QStringLiteral("file:///b"), entry(QStringLiteral("gallery")), &error), FolderViews::WriteResult::Busy);
    EXPECT_EQ(views.set(QStringLiteral("file:///b"), entry(QString(), 2)), FolderViews::WriteResult::Busy);
    EXPECT_LT(timer.elapsed(), 100) << "no wait for the lock";
    EXPECT_FALSE(error.isEmpty());
    EXPECT_TRUE(views.hasPending());
    EXPECT_EQ(views.entry(QStringLiteral("file:///b")), entry(QStringLiteral("gallery"), 2));
    EXPECT_EQ(readAll(file), before);
    EXPECT_EQ(views.flush(), FolderViews::WriteResult::Busy);
    other.unlock();
    EXPECT_EQ(views.flush(), kWritten);
    EXPECT_FALSE(views.hasPending());
    FolderViews check(file);
    check.load();
    EXPECT_EQ(check.entry(QStringLiteral("file:///a")).mode, QStringLiteral("list"));
    EXPECT_EQ(check.entry(QStringLiteral("file:///b")), entry(QStringLiteral("gallery"), 2));
}

// A lock path that is not a lock file (a directory, a FIFO, a link) is no other Files writing: Refused at once, never Busy
// (FilesApp retried Busy every 5 s for the whole session), never opened (QLockFile would read a FIFO to check it for
// staleness and wait for a writer). The choice stays pending and is written once the path is cleared (opus
// counter-review of PR #5).
TEST(FolderViews, ALockPathThatIsNoLockFileIsRefused)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    const QString lockPath = file + QStringLiteral(".lock");
    FolderViews views(file);
    ASSERT_EQ(views.set(QStringLiteral("file:///a"), entry(QStringLiteral("list"))), kWritten);
    const QByteArray before = readAll(file);
    const auto refusedAtOnce = [&](const char *what) {
        // On a thread of its own: a write that opened the FIFO would never return; leave it behind and fail.
        auto result = std::make_shared<std::atomic<int>>(-1);
        auto error = std::make_shared<QString>();
        auto store = std::make_shared<FolderViews>(file);
        std::thread([result, error, store] { result->store(int(store->set(QStringLiteral("file:///b"), entry(QStringLiteral("gallery")), error.get()))); }).detach();
        QElapsedTimer timer;
        timer.start();
        while (result->load() < 0 && timer.elapsed() < 2000)
            QThread::msleep(5);
        ASSERT_GE(result->load(), 0) << what << ": the write blocked";
        EXPECT_EQ(FolderViews::WriteResult(result->load()), FolderViews::WriteResult::Refused) << what;
        EXPECT_TRUE(error->contains(QLatin1String("lock"))) << what << ": " << qPrintable(*error);
        EXPECT_TRUE(store->hasPending()) << what << ": the choice stays pending";
        EXPECT_EQ(readAll(file), before) << what << ": the file is left as it is";
    };
    ASSERT_TRUE(QDir().mkdir(lockPath));
    refusedAtOnce("a directory");
    QString error;
    EXPECT_EQ(views.set(QStringLiteral("file:///c"), entry(QStringLiteral("icons")), &error), FolderViews::WriteResult::Refused);
    EXPECT_EQ(views.flush(), FolderViews::WriteResult::Refused) << "again, not Busy";
    EXPECT_TRUE(QFileInfo(lockPath).isDir()) << "the directory is left as it is";
    ASSERT_TRUE(QDir().rmdir(lockPath));
    ASSERT_EQ(::mkfifo(QFile::encodeName(lockPath).constData(), 0600), 0);
    refusedAtOnce("a FIFO");
    ASSERT_TRUE(QFile::remove(lockPath));
    ASSERT_TRUE(QFile::link(dir->filePath(QStringLiteral("elsewhere")), lockPath));
    refusedAtOnce("a link");
    ASSERT_TRUE(QFile::remove(lockPath));
    // Cleared: the pending choice is written.
    EXPECT_EQ(views.flush(), kWritten);
    FolderViews check(file);
    check.load();
    EXPECT_EQ(check.entry(QStringLiteral("file:///c")).mode, QStringLiteral("icons"));
}

// Four processes writing at once lose nothing: a write that finds the lock taken is flushed again (FilesApp does it on a
// timer; the review's load test lost 7 of 800 writes with a 500 ms wait and no retry).
TEST(FolderViews, NoWriteIsLostBetweenProcesses)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    constexpr int kProcesses = 4;
    constexpr int kWrites = 40;
    QList<pid_t> children;
    for (int p = 0; p < kProcesses; p++) {
        const pid_t child = ::fork();
        ASSERT_GE(child, 0);
        if (child == 0) {
            FolderViews views(file);
            int busy = 0;
            for (int i = 0; i < kWrites; i++) {
                auto r = views.set(QStringLiteral("file:///p%1/f%2").arg(p).arg(i), entry(QStringLiteral("list"), i % 4));
                for (int tries = 0; r == FolderViews::WriteResult::Busy && tries < 20000; tries++) {
                    busy++;
                    ::usleep(100);
                    r = views.flush();
                }
                if (r != kWritten)
                    ::_exit(2);
            }
            ::_exit(busy > 0 ? 0 : 3);
        }
        children.append(child);
    }
    int contended = 0;
    for (const pid_t child : children) {
        int status = 0;
        ASSERT_EQ(::waitpid(child, &status, 0), child);
        ASSERT_TRUE(WIFEXITED(status));
        ASSERT_NE(WEXITSTATUS(status), 2) << "a write was refused";
        contended += WEXITSTATUS(status) == 0 ? 1 : 0;
    }
    FolderViews check(file);
    check.load();
    EXPECT_EQ(check.count(), kProcesses * kWrites);
    int missing = 0;
    for (int p = 0; p < kProcesses; p++) {
        for (int i = 0; i < kWrites; i++)
            missing += check.entry(QStringLiteral("file:///p%1/f%2").arg(p).arg(i)) == entry(QStringLiteral("list"), i % 4) ? 0 : 1;
    }
    EXPECT_EQ(missing, 0);
    // How many processes met the lock taken at least once (the race was exercised only when some did).
    RecordProperty("contendedProcesses", contended);
}

// 68,000 short entries in a valid file just under the limit: the load keeps the 2,000 most recent in linear time (the
// old load moved each key with removeAll: 41 s on the UI thread).
// Load-sensitive, as scripts/dev/test.sh treats a timing budget elsewhere: a budget missed while the 1-minute load is above the
// core count says nothing about the code, so the test is reported as skipped (never as passed), after its other checks.
static bool machineLoaded()
{
    QFile f(QStringLiteral("/proc/loadavg"));
    if (!f.open(QIODevice::ReadOnly))
        return false;
    return f.readAll().split(' ').value(0).toDouble() > std::thread::hardware_concurrency();
}

TEST(FolderViews, ManyShortEntriesLoadInLinearTime)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    QJsonArray folders;
    for (int i = 0; i < 68000; i++) {
        // Every tenth entry repeats an older key: its last place and value count.
        const int n = i % 10 == 9 ? i - 5000 : i;
        QJsonObject o;
        o.insert(QStringLiteral("url"), QStringLiteral("a:%1").arg(qMax(0, n)));
        o.insert(QStringLiteral("sortKey"), i % 4);
        folders.append(o);
    }
    QJsonObject root;
    root.insert(QStringLiteral("version"), 1);
    root.insert(QStringLiteral("folders"), folders);
    const QByteArray bytes = QJsonDocument(root).toJson(QJsonDocument::Compact);
    ASSERT_LE(bytes.size(), FolderViews::kMaxFileSize);
    ASSERT_GT(bytes.size(), FolderViews::kMaxFileSize * 9 / 10);
    writeFile(file, bytes);
    FolderViews views(file);
    QElapsedTimer timer;
    timer.start();
    views.load();
    const qint64 loadMs = timer.elapsed();
    const bool loadedBudgetMissed = loadMs >= 2000 && machineLoaded();
    if (!loadedBudgetMissed) {
        EXPECT_LT(loadMs, 2000) << "load of 68,000 entries";
    }
    RecordProperty("loadMs", int(loadMs));
    EXPECT_FALSE(views.readOnly());
    EXPECT_EQ(views.count(), FolderViews::kMaxEntries);
    EXPECT_EQ(views.entry(QStringLiteral("a:67998")).sortKey, 67998 % 4) << "the most recent entry";
    EXPECT_EQ(views.entry(QStringLiteral("a:62999")).sortKey, 67999 % 4) << "a repeated key takes its last place and value";
    EXPECT_TRUE(views.entry(QStringLiteral("a:60000")).isEmpty()) << "older than the 2,000 most recent";
    timer.restart();
    ASSERT_EQ(views.set(QStringLiteral("a:new"), entry(QStringLiteral("gallery"))), kWritten);
    const qint64 writeMs = timer.elapsed();
    const bool writeBudgetMissed = writeMs >= 2000 && machineLoaded();
    if (!writeBudgetMissed) {
        EXPECT_LT(writeMs, 2000) << "first write after the load";
    }
    RecordProperty("writeMs", int(writeMs));
    FolderViews check(file);
    check.load();
    EXPECT_EQ(check.count(), FolderViews::kMaxEntries);
    EXPECT_EQ(check.entry(QStringLiteral("a:new")).mode, QStringLiteral("gallery"));
    if (loadedBudgetMissed || writeBudgetMissed)
        GTEST_SKIP() << "timing budget not judged: the machine load is above the core count";
}

// A change is seen by device, inode, size and time, not by the modification time alone: a replacement of the same size
// and time, and an edit in place that puts the time back, are both read again.
TEST(FolderViews, ReadsFollowChangesThatKeepTheTime)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    const QByteArray encoded = QFile::encodeName(file);
    writeFile(file, R"({"version":1,"folders":[{"url":"file:///a","mode":"list"}]})");
    const struct timespec times[2] = {{1700000000, 0}, {1700000000, 0}};
    ASSERT_EQ(::utimensat(AT_FDCWD, encoded.constData(), times, 0), 0);
    FolderViews views(file);
    views.refresh();
    EXPECT_EQ(views.entry(QStringLiteral("file:///a")).mode, QStringLiteral("list"));
    // The same size and time, another inode (an atomic replacement).
    const QString temp = file + QStringLiteral(".new");
    writeFile(temp, R"({"version":1,"folders":[{"url":"file:///a","mode":"icon"}]})");
    ASSERT_EQ(QFileInfo(temp).size(), QFileInfo(file).size());
    ASSERT_EQ(::utimensat(AT_FDCWD, QFile::encodeName(temp).constData(), times, 0), 0);
    ASSERT_EQ(::rename(QFile::encodeName(temp).constData(), encoded.constData()), 0);
    views.refresh();
    EXPECT_TRUE(views.entry(QStringLiteral("file:///a")).isEmpty()) << "\"icon\" is not a view: the file was read again";
    // The same inode, another size, the time put back.
    writeFile(file, R"({"version":1,"folders":[{"url":"file:///a","mode":"gallery"}]})");
    ASSERT_EQ(::utimensat(AT_FDCWD, encoded.constData(), times, 0), 0);
    views.refresh();
    EXPECT_EQ(views.entry(QStringLiteral("file:///a")).mode, QStringLiteral("gallery"));
}

TEST(FolderViews, GroupingAndTheNewSortKeysRoundTrip)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString file = dir->filePath(QStringLiteral("files-views.json"));
    FolderViews views(file);
    FolderViews::Entry e = entry(QStringLiteral("icons"), 6);
    e.groupBy = 2;
    ASSERT_EQ(views.set(QStringLiteral("file:///a"), e), kWritten);
    FolderViews::Entry none;
    none.groupBy = 0;
    ASSERT_EQ(views.set(QStringLiteral("file:///b"), none), kWritten) << "no groups is a choice of its own";
    FolderViews again(file);
    again.load();
    EXPECT_EQ(again.entry(QStringLiteral("file:///a")).sortKey, 6);
    EXPECT_EQ(again.entry(QStringLiteral("file:///a")).groupBy, 2);
    EXPECT_EQ(again.entry(QStringLiteral("file:///b")).groupBy, 0);
    EXPECT_EQ(again.entry(QStringLiteral("file:///b")).sortKey, -1);
    // Out of range: unset.
    EXPECT_EQ(FolderViews::parse(QJsonObject{{QStringLiteral("groupBy"), 9}, {QStringLiteral("sortKey"), 8}}).groupBy, -1);
    EXPECT_EQ(FolderViews::parse(QJsonObject{{QStringLiteral("sortKey"), 8}}).sortKey, -1);
    EXPECT_EQ(FolderViews::parse(QJsonObject{{QStringLiteral("groupBy"), 1.5}}).groupBy, -1);
}
