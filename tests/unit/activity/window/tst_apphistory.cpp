// A-S14 (docs/specs/activity.md AM67; ADR-0038 g, AD31; step 4): App History. systemd's unit resource records of the launches
// uwsm named (anything else skipped), summed per app with the live units, the period's start, the caption, the sort, and
// "not available" when journalctl fails.
#include "apphistory.h"

#include <QSignalSpy>
#include <QTest>
#include <QThread>

#include <atomic>

#include <gtest/gtest.h>

using namespace activity;

namespace
{

QByteArray record(const char *unit, const char *cpu, const char *peak, qint64 timeUs, const char *id = kUnitResourcesMessage)
{
    QByteArray line = QByteArray("{\"__REALTIME_TIMESTAMP\":\"") + QByteArray::number(timeUs) + "\",\"MESSAGE_ID\":\"" + id
        + "\",\"USER_UNIT\":\"" + unit + "\"";
    if (cpu)
        line += QByteArray(",\"CPU_USAGE_NSEC\":\"") + cpu + "\"";
    if (peak)
        line += QByteArray(",\"MEMORY_PEAK\":\"") + peak + "\"";
    return line + "}\n";
}

constexpr qint64 kNow = 1'800'000'000'000'000; // µs
constexpr qint64 kHour = 3'600'000'000;

} // namespace

TEST(AppHistory, TheLaunchesRecordsOnly)
{
    QByteArray text = record("app-Hyprland-foot-1a2b3c4d.scope", "2000000000", "50000000", kNow - kHour);
    text += record("app-Hyprland-org.gnome.Nautilus@0011aabb.service", "500", nullptr, kNow - 2 * kHour);
    text += record("pipewire.service", "9", "9", kNow);                                  // not a launch
    text += record("app-Hyprland-foot-99aa88bb.scope", "1", "1", kNow, "0123456789abcdef0123456789abcdef"); // another message
    text += record("app-Hyprland-foot-1a2b3c4e.scope", "x", "y", kNow);                  // no number
    text += "not json\n";
    text += "{\"USER_UNIT\":\"app-Hyprland-foot-1a2b3c4f.scope\",\"CPU_USAGE_NSEC\":\"1\"}\n"; // no time
    const std::vector<UnitRecord> records = parseUnitRecords(text);
    ASSERT_EQ(records.size(), 2u);
    EXPECT_EQ(records[0].unit, QStringLiteral("app-Hyprland-foot-1a2b3c4d.scope"));
    EXPECT_EQ(records[0].cpuNs, 2000000000u);
    EXPECT_EQ(records[0].memoryPeak, 50000000u);
    EXPECT_TRUE(records[1].hasCpu);
    EXPECT_FALSE(records[1].hasMemory);
    EXPECT_EQ(records[1].timeUs, kNow - 2 * kHour);
}

TEST(AppHistory, SummedPerAppWithTheLiveUnits)
{
    const std::vector<UnitRecord> records{
        {QStringLiteral("app-Hyprland-foot-1a2b3c4d.scope"), 2'000'000'000, true, 50, true, kNow - kHour},
        {QStringLiteral("app-Hyprland-foot-99aa88bb.scope"), 1'000'000'000, true, 80, true, kNow - 3 * kHour},
        {QStringLiteral("app-Hyprland-mpv-00000001.scope"), 7, true, 7, true, kNow - 13 * kHour}, // before the period
        {QStringLiteral("app-Hyprland-foot-1a2b3c4d.scope"), 9, true, 9, true, kNow - kHour},     // the same unit twice
    };
    const std::vector<LiveUnit> live{{QStringLiteral("app-Hyprland-foot-aaaaaaaa.scope"), 500'000'000, 120},
                                     {QStringLiteral("app-Hyprland-foot-1a2b3c4d.scope"), 1, 1}, // ended meanwhile: its record
                                     {QStringLiteral("app-Hyprland-org.gnome.Nautilus@0011aabb.service"), 3, 4}};
    const std::vector<AppUsage> apps = aggregateUsage(records, live, kNow - 12 * kHour, kNow);
    ASSERT_EQ(apps.size(), 2u);
    EXPECT_EQ(apps[0].app, QStringLiteral("foot"));
    EXPECT_EQ(apps[0].cpuNs, 3'500'000'000u);
    EXPECT_EQ(apps[0].memoryPeak, 120u);
    EXPECT_EQ(apps[0].launches, 3);
    EXPECT_EQ(apps[0].lastUsedUs, kNow); // running
    EXPECT_EQ(apps[1].app, QStringLiteral("org.gnome.Nautilus"));
    EXPECT_EQ(apps[1].launches, 1);

    quint64 ns = 0;
    EXPECT_TRUE(parseCpuStatUsage("usage_usec 1234\nuser_usec 1000\nsystem_usec 234\n", ns));
    EXPECT_EQ(ns, 1'234'000u);
    EXPECT_FALSE(parseCpuStatUsage("user_usec 1000\n", ns));
}

TEST(AppHistory, TheModelItsCaptionAndSort)
{
    AppHistory history(
        [](const QString &app) {
            return app == QLatin1String("foot") ? AppHistory::App{QStringLiteral("Foot"), QStringLiteral("foot")}
                                                : AppHistory::App{app, QString()};
        },
        [] { return AppHistory::LiveReader([] { return std::vector<LiveUnit>{}; }); });
    history.setUser(QStringLiteral("alice"));
    history.setLocale(QLocale(QLocale::English, QLocale::UnitedStates));
    QByteArray text = record("app-Hyprland-foot-1a2b3c4d.scope", "2000000000", "52428800", kNow - kHour);
    text += record("app-Hyprland-zed-1a2b3c4d.scope", "5000000000", "1048576", kNow - 2 * kHour);
    text += record("app-Hyprland-zed-1a2b3c4e.scope", "1000000000", "2097152", kNow - 3 * kHour);
    QSignalSpy loaded(&history, &AppHistory::loaded);
    history.setAnswer(text, true, kNow);
    EXPECT_EQ(loaded.count(), 1);
    EXPECT_FALSE(history.unavailable());
    EXPECT_TRUE(history.caption().startsWith(QStringLiteral("Resource use since ")));
    EXPECT_TRUE(history.caption().endsWith(QStringLiteral(" for alice")));
    ASSERT_EQ(history.count(), 2);
    const auto name = [&](int row) { return history.data(history.index(row), AppHistory::NameRole).toString(); };
    EXPECT_EQ(name(0), QStringLiteral("zed")); // CPU Time, largest first
    EXPECT_EQ(history.data(history.index(0), AppHistory::LaunchesRole).toString(), QStringLiteral("2"));
    EXPECT_EQ(history.data(history.index(1), AppHistory::IconRole).toString(), QStringLiteral("foot"));
    history.sortBy(QStringLiteral("memory"));
    EXPECT_EQ(name(0), QStringLiteral("Foot"));
    history.sortBy(QStringLiteral("memory"));
    EXPECT_EQ(name(0), QStringLiteral("zed"));
    history.sortBy(QStringLiteral("name"));
    EXPECT_EQ(name(0), QStringLiteral("Foot"));
    EXPECT_FALSE(history.sortDescending());
    history.sortBy(QStringLiteral("nonsense"));
    EXPECT_EQ(history.sortKey(), QStringLiteral("name"));

    history.setAnswer({}, false, kNow); // AM67: no journal, nothing else
    EXPECT_TRUE(history.unavailable());
    EXPECT_EQ(history.count(), 0);
    EXPECT_EQ(history.caption(), QString());
}

TEST(AppHistory, ThreePeriods)
{
    AppHistory history(nullptr, nullptr);
    EXPECT_EQ(history.period(), QStringLiteral("12h"));
    // The period remembered (AM74) comes back without a read and without a signal; anything else is ignored.
    QSignalSpy restored(&history, &AppHistory::periodChanged);
    history.restorePeriod(QStringLiteral("30d"));
    EXPECT_EQ(history.period(), QStringLiteral("30d"));
    EXPECT_FALSE(history.loading());
    history.restorePeriod(QStringLiteral("1y"));
    EXPECT_EQ(history.period(), QStringLiteral("30d"));
    EXPECT_EQ(restored.count(), 0);
    history.restorePeriod(QStringLiteral("12h"));
    ASSERT_EQ(history.periods().size(), 3);
    EXPECT_EQ(history.periods().at(2).toMap().value(QStringLiteral("title")).toString(), QStringLiteral("Last 30 Days"));
    // A record 13 hours old counts in the last 7 days, not in the last 12 hours.
    const QByteArray text = record("app-Hyprland-foot-1a2b3c4d.scope", "1", "1", kNow - 13 * kHour);
    history.setAnswer(text, true, kNow);
    EXPECT_EQ(history.count(), 0);
    QSignalSpy period(&history, &AppHistory::periodChanged);
    history.setPeriod(QStringLiteral("bogus"));
    EXPECT_EQ(period.count(), 0);
    history.setPeriod(QStringLiteral("7d")); // reads again; the test's answer takes the read's place
    EXPECT_EQ(period.count(), 1);
    history.setAnswer(text, true, kNow);
    EXPECT_FALSE(history.loading());
    EXPECT_EQ(history.count(), 1);
}

TEST(AppHistory, TheJournalIsReadOnTheWorker)
{
    // Audit A2: up to 16 MiB of journal lines were parsed on the window's thread inside a model reset, with the live
    // units' cgroups read there too. They are read on the worker; the window's thread only swaps the rows in.
    QThread thread;
    QObject worker;
    worker.moveToThread(&thread);
    thread.start();
    QThread *gui = QThread::currentThread();
    std::atomic<QThread *> resolvedOn{nullptr}, liveOn{nullptr}, liveMadeOn{nullptr};
    AppHistory history(
        [&](const QString &app) {
            resolvedOn = QThread::currentThread();
            return AppHistory::App{app, QString()};
        },
        [&] {
            liveMadeOn = QThread::currentThread();
            return AppHistory::LiveReader([&] {
                liveOn = QThread::currentThread();
                return std::vector<LiveUnit>{{QStringLiteral("app-Hyprland-zed-99999999.scope"), 1000, 10}};
            });
        });
    history.setWorker(&worker);
    QByteArray text;
    for (int i = 0; i < 2000; ++i)
        text += record("app-Hyprland-foot-1a2b3c4d.scope", "2000000000", "52428800", kNow - kHour);
    QSignalSpy loaded(&history, &AppHistory::loaded);
    history.setAnswer(text, true, kNow);
    EXPECT_TRUE(history.loading()) << "the answer is being read";
    EXPECT_EQ(history.count(), 0);
    ASSERT_TRUE(QTest::qWaitFor([&] { return !history.loading(); }, 5000));
    EXPECT_EQ(history.count(), 2);
    EXPECT_EQ(liveMadeOn.load(), gui) << "the candidates are taken on the window's thread";
    EXPECT_EQ(liveOn.load(), &thread);
    EXPECT_EQ(resolvedOn.load(), &thread);
    // A read made again before the first answer is in: only the newest answer is installed.
    history.setAnswer(text, true, kNow);
    history.setAnswer({}, false, kNow);
    ASSERT_TRUE(QTest::qWaitFor([&] { return !history.loading(); }, 5000));
    QTest::qWait(100);
    EXPECT_TRUE(history.unavailable());
    EXPECT_EQ(history.count(), 0);
    thread.quit();
    thread.wait();
}
