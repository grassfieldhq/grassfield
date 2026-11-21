// Questions to the disk off the GUI thread (DiskProbe; ADR-0035 4b-18): Files' sidebar and grassfield-portal's panels never
// wait on a hung mount. A slow disk is a stat function that sleeps for paths under /hung (a read that hangs) or /slow (a
// share slow but answering). Part of files-kio-tests (a scratch home, its own main).
#include "diskprobe.h"
#include "placesmodel.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QMutex>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QThread>

#include <gtest/gtest.h>

#include <atomic>

namespace {

constexpr int kHungMs = 1500;
constexpr int kSlowMs = 150;
constexpr int kSharedMs = 400;
std::atomic<int> g_hungReads{0};
std::atomic<int> g_sharedReads{0};
std::atomic<int> g_countReads{0};
QMutex g_orderMutex;
QStringList g_order;

// /hung: a read that hangs (then answers a folder); /slow: a share slow but answering; /shared: a read long enough for a
// second call to ask the same path meanwhile; /count: counted, nothing there; /order: the order of the reads kept.
int slowDisk(const QString &path)
{
    if (path.startsWith(QLatin1String("/hung"))) {
        ++g_hungReads;
        QThread::msleep(kHungMs);
        return 2;
    }
    if (path.startsWith(QLatin1String("/slow"))) {
        QThread::msleep(kSlowMs);
        return 2;
    }
    if (path.startsWith(QLatin1String("/shared"))) {
        ++g_sharedReads;
        QThread::msleep(kSharedMs);
        return 2;
    }
    if (path.startsWith(QLatin1String("/count"))) {
        ++g_countReads;
        return 0;
    }
    if (path.startsWith(QLatin1String("/order"))) {
        const QMutexLocker lock(&g_orderMutex);
        g_order << path;
        return 0;
    }
    return DiskProbe::kindOf(path);
}

DiskProbe::Options options(int quietMs = 300, int totalMs = 2000)
{
    return {quietMs, totalMs, slowDisk};
}

bool waitFor(const std::function<bool()> &condition, int ms)
{
    QDeadlineTimer deadline(ms);
    while (!condition() && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        QThread::msleep(5);
    }
    return condition();
}

// One call's answer, waited for.
QHash<QString, int> ask(DiskProbe &probe, const QStringList &paths, qint64 *took = nullptr)
{
    QHash<QString, int> kinds;
    bool done = false;
    int token = -1;
    const auto connection = QObject::connect(&probe, &DiskProbe::answered, [&](int t, const QHash<QString, int> &k) {
        if (t == token) {
            kinds = k;
            done = true;
        }
    });
    QElapsedTimer clock;
    clock.start();
    token = probe.probe(paths);
    EXPECT_FALSE(done) << "never answered from inside the call";
    EXPECT_TRUE(waitFor([&] { return done; }, 10000));
    if (took)
        *took = clock.elapsed();
    QObject::disconnect(connection);
    return kinds;
}

} // namespace

TEST(DiskProbe, SaysWhatEachPathNames)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    QFile file(dir.filePath(QStringLiteral("file")));
    ASSERT_TRUE(file.open(QIODevice::WriteOnly));
    file.close();
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("folder")));
    ASSERT_TRUE(QFile::link(dir.filePath(QStringLiteral("missing")), dir.filePath(QStringLiteral("dangling"))));
    DiskProbe probe(options());
    const QHash<QString, int> kinds = ask(probe, {dir.filePath(QStringLiteral("file")), dir.filePath(QStringLiteral("folder")),
                                                  dir.filePath(QStringLiteral("dangling")), dir.filePath(QStringLiteral("missing"))});
    EXPECT_EQ(kinds.value(dir.filePath(QStringLiteral("file"))), 1);
    EXPECT_EQ(kinds.value(dir.filePath(QStringLiteral("folder"))), 2);
    EXPECT_EQ(kinds.value(dir.filePath(QStringLiteral("dangling"))), 1); // saving over it asks first
    EXPECT_EQ(kinds.value(dir.filePath(QStringLiteral("missing"))), 0);
}

// Each path's answer is its own (re-review of 65311e0, MAJOR 1): a healthy path queued behind a hung one is not responding
// for that call only; the next call reads it again; the hung path is not read again while its read hangs.
TEST(DiskProbe, AHealthyPathBehindAHungOneIsReadAgain)
{
    DiskProbe probe(options());
    const int before = g_hungReads;
    const QHash<QString, int> first = ask(probe, {QStringLiteral("/hung/a"), QStringLiteral("/tmp")});
    EXPECT_EQ(first.value(QStringLiteral("/hung/a")), DiskProbe::kNotResponding);
    EXPECT_EQ(first.value(QStringLiteral("/tmp")), DiskProbe::kNotResponding) << "queued behind the hung read";
    EXPECT_EQ(probe.stuck(), 1);
    for (int i = 0; i < 3; ++i) {
        qint64 took = 0;
        const QHash<QString, int> again = ask(probe, {QStringLiteral("/tmp"), QStringLiteral("/hung/a")}, &took);
        EXPECT_EQ(again.value(QStringLiteral("/tmp")), 2) << "read again, call " << i;
        EXPECT_EQ(again.value(QStringLiteral("/hung/a")), DiskProbe::kNotResponding);
        EXPECT_LT(took, 250) << "the stuck path is not waited for";
    }
    EXPECT_EQ(g_hungReads - before, 1) << "a stuck path is not read twice";
}

// The paths are read in the order given (re-review of 24bdf58, MAJOR 1: a hash's order changed from one process to the next).
TEST(DiskProbe, ReadsInTheOrderGiven)
{
    DiskProbe probe(options());
    const QStringList paths{QStringLiteral("/order/h"), QStringLiteral("/order/c"), QStringLiteral("/order/a"), QStringLiteral("/order/f"),
                            QStringLiteral("/order/b"), QStringLiteral("/order/g"), QStringLiteral("/order/e"), QStringLiteral("/order/d")};
    {
        const QMutexLocker lock(&g_orderMutex);
        g_order.clear();
    }
    ask(probe, paths);
    const QMutexLocker lock(&g_orderMutex);
    EXPECT_EQ(g_order, paths);
}

// A stuck read gives its place back when it returns (re-review of 65311e0, MINOR 5): the path is read again by the next call;
// its late answer is given (re-review of 24bdf58, MINOR 2: a dimmed place comes back).
TEST(DiskProbe, AStuckReadGivesItsPlaceBack)
{
    DiskProbe probe(options());
    QList<QPair<QString, int>> late;
    QObject::connect(&probe, &DiskProbe::answeredLate, [&](const QString &path, int kind) { late.append({path, kind}); });
    const int before = g_hungReads;
    EXPECT_EQ(ask(probe, {QStringLiteral("/hung/b")}).value(QStringLiteral("/hung/b")), DiskProbe::kNotResponding);
    EXPECT_EQ(probe.stuck(), 1);
    EXPECT_TRUE(late.isEmpty());
    ASSERT_TRUE(waitFor([&] { return probe.stuck() == 0; }, kHungMs + 1000)) << "the read returned";
    ASSERT_EQ(late.size(), 1);
    EXPECT_EQ(late.first().first, QStringLiteral("/hung/b"));
    EXPECT_EQ(late.first().second, 2);
    // Read again (and hung again): a second read.
    EXPECT_EQ(ask(probe, {QStringLiteral("/hung/b")}).value(QStringLiteral("/hung/b")), DiskProbe::kNotResponding);
    EXPECT_EQ(g_hungReads - before, 2);
    waitFor([&] { return probe.stuck() == 0; }, kHungMs + 1000);
}

// With kMaxThreads threads alive, a new path is not responding at once, healthy or not: hung reads cannot pile up threads.
TEST(DiskProbe, ThreadsAreBounded)
{
    DiskProbe probe(options(200));
    int ended = 0;
    const auto connection = QObject::connect(&probe, &DiskProbe::answered, [&] { ++ended; });
    for (int i = 0; i < DiskProbe::kMaxThreads; ++i)
        probe.probe({QStringLiteral("/hung/bound-%1").arg(i)});
    ASSERT_TRUE(waitFor([&] { return ended == DiskProbe::kMaxThreads; }, 1000)) << "all at once, well before the reads return";
    QObject::disconnect(connection);
    EXPECT_EQ(probe.stuck(), DiskProbe::kMaxThreads);
    EXPECT_EQ(probe.threads(), DiskProbe::kMaxThreads);
    qint64 took = 0;
    EXPECT_EQ(ask(probe, {QStringLiteral("/tmp")}, &took).value(QStringLiteral("/tmp")), DiskProbe::kNotResponding);
    EXPECT_LT(took, 150);
    EXPECT_EQ(probe.threads(), DiskProbe::kMaxThreads) << "no thread started";
    ASSERT_TRUE(waitFor([&] { return probe.stuck() == 0 && probe.threads() == 0; }, kHungMs + 2000));
    EXPECT_EQ(ask(probe, {QStringLiteral("/tmp")}).value(QStringLiteral("/tmp")), 2) << "the bound is given back";
}

// One read per path (re-review of 24bdf58, MINOR 3: 30 calls on one hung path left 30 threads): calls asking a path another
// call's thread is reading wait for that read; their threads end at once.
TEST(DiskProbe, OneReadPerPath)
{
    DiskProbe probe(options(200));
    const int before = g_hungReads;
    int ended = 0;
    QHash<QString, int> last;
    const auto connection = QObject::connect(&probe, &DiskProbe::answered, [&](int, const QHash<QString, int> &kinds) {
        ++ended;
        last = kinds;
    });
    for (int i = 0; i < 30; ++i)
        probe.probe({QStringLiteral("/hung/one")});
    EXPECT_TRUE(waitFor([&] { return probe.threads() == 1; }, 1000)) << probe.threads() << " threads";
    ASSERT_TRUE(waitFor([&] { return ended == 30; }, 1000));
    QObject::disconnect(connection);
    EXPECT_EQ(last.value(QStringLiteral("/hung/one")), DiskProbe::kNotResponding);
    EXPECT_EQ(probe.stuck(), 1);
    ASSERT_TRUE(waitFor([&] { return probe.threads() == 0; }, kHungMs + 1000));
    EXPECT_EQ(g_hungReads - before, 1);

    // A read that answers (400 ms, within the 1-s deadline): the second call waits for the first call's read and has its
    // answer.
    DiskProbe patient(options(1000));
    const int sharedBefore = g_sharedReads;
    QHash<int, QHash<QString, int>> answers;
    QObject::connect(&patient, &DiskProbe::answered, [&](int token, const QHash<QString, int> &kinds) { answers.insert(token, kinds); });
    const int first = patient.probe({QStringLiteral("/shared/x")});
    const int second = patient.probe({QStringLiteral("/shared/x")});
    ASSERT_TRUE(waitFor([&] { return answers.size() == 2; }, 3000));
    EXPECT_EQ(answers.value(first).value(QStringLiteral("/shared/x")), 2);
    EXPECT_EQ(answers.value(second).value(QStringLiteral("/shared/x")), 2);
    EXPECT_EQ(g_sharedReads - sharedBefore, 1);
}

// A call that ended reads nothing more: its thread, back from a hung read, does not go on to the paths queued behind it.
TEST(DiskProbe, AnEndedCallReadsNothingMore)
{
    DiskProbe probe(options());
    const int before = g_countReads;
    const QHash<QString, int> kinds = ask(probe, {QStringLiteral("/hung/ended"), QStringLiteral("/count/behind")});
    EXPECT_EQ(kinds.value(QStringLiteral("/count/behind")), DiskProbe::kNotResponding);
    ASSERT_TRUE(waitFor([&] { return probe.threads() == 0; }, kHungMs + 1000)) << "the hung read returned";
    EXPECT_EQ(g_countReads - before, 0);
}

// The deadline counts from the last answer, and a call ends after totalMs at most (re-review of 65311e0, MINOR 3): a share
// that answers every 150 ms is waited for past the 300-ms quiet deadline, up to the 1-s total.
TEST(DiskProbe, ASlowShareIsWaitedForUpToTheTotal)
{
    DiskProbe probe(options(300, 1000));
    QStringList paths;
    for (int i = 0; i < 12; ++i)
        paths << QStringLiteral("/slow/%1").arg(i);
    qint64 took = 0;
    const QHash<QString, int> kinds = ask(probe, paths, &took);
    EXPECT_EQ(kinds.value(QStringLiteral("/slow/0")), 2);
    EXPECT_EQ(kinds.value(QStringLiteral("/slow/4")), 2) << "past the quiet deadline, still answering";
    EXPECT_EQ(kinds.value(QStringLiteral("/slow/11")), DiskProbe::kNotResponding) << "past the total";
    EXPECT_GE(took, 950);
    EXPECT_LT(took, 1400);
    waitFor([&] { return probe.stuck() == 0; }, 1000);
}

// Files' sidebar (re-review of 65311e0, MAJOR 2): the standard folders are asked about off the GUI thread. The list comes
// at once; a folder that is not there leaves it; one that does not answer stays, unavailable (dimmed).
TEST(PlacesModelDisk, AHungStandardFolderIsListedUnavailable)
{
    const QString config = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    ASSERT_FALSE(config.isEmpty());
    QDir().mkpath(config);
    QFile dirs(config + QStringLiteral("/user-dirs.dirs"));
    ASSERT_FALSE(dirs.exists()) << "the scratch home has none";
    ASSERT_TRUE(dirs.open(QIODevice::WriteOnly));
    dirs.write("XDG_DOCUMENTS_DIR=\"/hung/Documents\"\nXDG_PICTURES_DIR=\"$HOME/No Pictures\"\n");
    dirs.close();
    QElapsedTimer clock;
    clock.start();
    PlacesModel places(nullptr, options());
    EXPECT_LT(clock.elapsed(), 200) << "the GUI thread did not wait on the disk";
    const auto row = [&](const QString &name) {
        for (int r = 0; r < places.rowCount(); ++r)
            if (places.data(places.index(r), PlacesModel::NameRole).toString() == name)
                return r;
        return -1;
    };
    ASSERT_GE(row(QStringLiteral("Documents")), 0) << "listed at once";
    EXPECT_FALSE(places.data(places.index(row(QStringLiteral("Documents"))), PlacesModel::UnavailableRole).toBool());
    ASSERT_TRUE(waitFor([&] { return row(QStringLiteral("Pictures")) < 0; }, 2000)) << "a folder that is not there leaves";
    // Documents' own call ends at its deadline: listed, unavailable.
    EXPECT_TRUE(waitFor([&] {
        const int r = row(QStringLiteral("Documents"));
        return r >= 0 && places.data(places.index(r), PlacesModel::UnavailableRole).toBool();
    }, 1000)) << "a folder that does not answer stays, dimmed";
    EXPECT_GE(row(QStringLiteral("Home")), 0);
    EXPECT_FALSE(places.data(places.index(row(QStringLiteral("Home"))), PlacesModel::UnavailableRole).toBool());
    // Its read returns (a folder): it is shown again (re-review of 24bdf58, MINOR 2).
    EXPECT_TRUE(waitFor([&] {
        const int r = row(QStringLiteral("Documents"));
        return r >= 0 && !places.data(places.index(r), PlacesModel::UnavailableRole).toBool();
    }, kHungMs + 1000)) << "back when its read returns";
    QFile::remove(dirs.fileName());
}

// The Locations list shows the internal drives' filesystems udisks2 knows (VolumeLogic): after Computer, by name, an
// unmounted one with no folder to open yet, none ejectable; they leave when udisks2 no longer lists them.
TEST(PlacesModelDisk, UdisksVolumesAreListedInLocations)
{
    PlacesModel places(nullptr, options());
    const auto rowOf = [&](const QString &udi) {
        for (int r = 0; r < places.rowCount(); ++r)
            if (places.data(places.index(r), PlacesModel::UdiRole).toString() == udi)
                return r;
        return -1;
    };
    VolumeLogic::Volume games;
    games.path = QStringLiteral("/org/freedesktop/UDisks2/block_devices/sda1");
    games.device = QStringLiteral("/dev/sda1");
    games.name = QStringLiteral("Games");
    games.icon = QStringLiteral("drive-harddisk");
    games.size = 2'000'000'000'000ULL;
    VolumeLogic::Volume data = games;
    data.path = QStringLiteral("/org/freedesktop/UDisks2/block_devices/sda2");
    data.device = QStringLiteral("/dev/sda2");
    data.name = QStringLiteral("500 GB Volume");
    data.mountPoint = QStringLiteral("/run/media/u/abc");
    places.setUdisksVolumes({games, data});
    const int g = rowOf(games.path);
    const int d = rowOf(data.path);
    ASSERT_GE(g, 0);
    ASSERT_GE(d, 0);
    EXPECT_EQ(places.data(places.index(g), PlacesModel::SectionRole).toString(), "locations");
    EXPECT_EQ(places.data(places.index(g), PlacesModel::KindRole).toString(), "volume");
    EXPECT_EQ(places.data(places.index(g), PlacesModel::NameRole).toString(), "Games");
    EXPECT_FALSE(places.data(places.index(g), PlacesModel::MountedRole).toBool());
    EXPECT_FALSE(places.data(places.index(g), PlacesModel::UrlRole).toUrl().isValid());
    EXPECT_FALSE(places.data(places.index(g), PlacesModel::EjectableRole).toBool());
    EXPECT_TRUE(places.data(places.index(d), PlacesModel::MountedRole).toBool());
    EXPECT_EQ(places.data(places.index(d), PlacesModel::UrlRole).toUrl(), QUrl::fromLocalFile(QStringLiteral("/run/media/u/abc")));
    EXPECT_EQ(places.rowForUrl(QUrl::fromLocalFile(QStringLiteral("/run/media/u/abc/Photos"))), -1);
    EXPECT_EQ(places.rowForUrl(QUrl::fromLocalFile(QStringLiteral("/run/media/u/abc"))), d);
    // A mounted one opens at once; Eject on an internal disk does nothing (never an unmount from the sidebar).
    QUrl opened;
    QObject::connect(&places, &PlacesModel::mounted, &places, [&](const QUrl &url) { opened = url; });
    places.mount(d);
    EXPECT_EQ(opened, QUrl::fromLocalFile(QStringLiteral("/run/media/u/abc")));
    places.eject(d);
    EXPECT_TRUE(places.data(places.index(d), PlacesModel::MountedRole).toBool());
    places.setUdisksVolumes({});
    EXPECT_EQ(rowOf(games.path), -1);
    EXPECT_EQ(rowOf(data.path), -1);
}

// Audit F18: a change of the sidebar's lists (a tag seen while scrolling, a favourite added) comes as the rows that came,
// went or changed, never as a reset: the sidebar keeps its delegates, its hover and its drop target meanwhile.
TEST(PlacesModelDiff, ListsChangeRowByRow)
{
    PlacesModel places(nullptr, options());
    int resets = 0;
    int inserted = 0;
    int removed = 0;
    QObject::connect(&places, &QAbstractItemModel::modelReset, [&resets] { ++resets; });
    QObject::connect(&places, &QAbstractItemModel::rowsInserted, [&inserted](const QModelIndex &, int first, int last) { inserted += last - first + 1; });
    QObject::connect(&places, &QAbstractItemModel::rowsRemoved, [&removed](const QModelIndex &, int first, int last) { removed += last - first + 1; });
    const auto rowOfTag = [&](const QString &tag) {
        for (int r = 0; r < places.rowCount(); ++r)
            if (places.data(places.index(r), PlacesModel::TagRole).toString() == tag)
                return r;
        return -1;
    };
    QPersistentModelIndex recents(places.index(0));
    ASSERT_TRUE(recents.isValid());
    const int before = places.rowCount();
    places.setTags({QStringLiteral("Red"), QStringLiteral("work")});
    EXPECT_EQ(places.rowCount(), before + 2);
    EXPECT_EQ(inserted, 2);
    places.setTags({QStringLiteral("Red"), QStringLiteral("home"), QStringLiteral("work")});
    EXPECT_EQ(inserted, 3) << "only the new tag came";
    EXPECT_GE(rowOfTag(QStringLiteral("home")), 0);
    places.setTags({QStringLiteral("work")});
    EXPECT_EQ(removed, 2);
    EXPECT_EQ(rowOfTag(QStringLiteral("Red")), -1);
    EXPECT_GE(rowOfTag(QStringLiteral("work")), 0);
    places.setFavorites({QUrl::fromLocalFile(QDir::homePath())}, {});
    EXPECT_EQ(resets, 0) << "no list change resets the model";
    EXPECT_TRUE(recents.isValid()) << "a row that stays keeps its index";
    EXPECT_EQ(recents.row(), 0);
}
