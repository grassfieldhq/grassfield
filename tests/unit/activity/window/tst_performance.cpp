// A-S15 (docs/specs/activity.md AM66, AM71, AM72; step 4 and 5): the Performance window's data. The histories follow the
// samples whether a window shows them or not; the sidebar (CPU, Memory, each disk, each interface, each GPU) and the
// selection's details are built only while one does; each logical processor's shares and history; Clear CPU History; a
// selection that went away falls back to CPU; a GPU without clients idles.
#include "../fixture.h"
#include "format.h"
#include "performance.h"

#include <QCoreApplication>

#include <gtest/gtest.h>

using namespace activity;
using activity_test::Fixture;

namespace
{

Snapshot sample(double user, double system, std::vector<double> perBusy, std::vector<double> perUser)
{
    Snapshot s;
    s.system.cpuOk = true;
    s.system.userShare = user;
    s.system.systemShare = system;
    s.system.perCpuBusy = std::move(perBusy);
    s.system.perCpuUser = std::move(perUser);
    s.system.processes = 321;
    s.system.tasks = 1234;
    s.system.memory.ok = true;
    s.system.memory.physical = 16ull << 30;
    s.system.memory.used = 4ull << 30;
    s.system.memory.compressed = 1ull << 30;
    s.system.memory.cached = 2ull << 30;
    s.system.memory.available = 10ull << 30;
    s.system.memory.committed = 6ull << 30;
    s.system.memory.commitLimit = 24ull << 30;
    s.system.memory.inUse = 0.25;
    DiskSnapshot disk;
    disk.name = "nvme0n1";
    disk.activeTime = 0.1;
    disk.readBytesPerSec = 1e6;
    disk.writeBytesPerSec = 2e6;
    disk.responseMs = 0.4;
    s.system.disks.push_back(disk);
    NetSnapshot net;
    net.name = "wlan0";
    net.bytesInPerSec = 3000;
    net.bytesOutPerSec = 1000;
    s.system.interfaces.push_back(net);
    return s;
}

QStringList keys(const QVariantList &resources)
{
    QStringList out;
    for (const QVariant &r : resources)
        out << r.toMap().value(QStringLiteral("key")).toString();
    return out;
}

QString figureOf(const QVariantMap &detail, const QString &label)
{
    for (const QVariant &f : detail.value(QStringLiteral("figures")).toList()) {
        if (f.toMap().value(QStringLiteral("label")).toString() == label)
            return f.toMap().value(QStringLiteral("value")).toString();
    }
    return QStringLiteral("<none>");
}

} // namespace

TEST(Performance, UpTime)
{
    EXPECT_EQ(formatUptime(0), QStringLiteral("0:00:00:00"));
    EXPECT_EQ(formatUptime(350735.47), QStringLiteral("4:01:25:35"));
    EXPECT_EQ(formatUptime(-1), QStringLiteral("—"));
}

TEST(Performance, TheSidebarAndTheDetailsWhileShown)
{
    Fixture f;
    f.write("proc/uptime", "3661.5 1.0\n");
    f.write("proc/cpuinfo", "model name\t: Test CPU\n");
    f.write("sys/devices/system/cpu/cpu0/topology/core_id", "0\n");
    f.write("sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "2000000\n");
    f.write("sys/block/nvme0n1/size", "1000\n");
    f.write("sys/block/nvme0n1/queue/rotational", "0\n");
    f.write("sys/class/net/wlan0/wireless/.keep", "");
    f.write("proc/net/wireless", "wlan0: 0000   58.  -52.  -256 0 0 0 0 0 0\n");
    Performance p(f.proc(), f.sys());
    p.setLocale(QLocale(QLocale::English, QLocale::UnitedStates));
    p.setWifiName([](const QString &i, std::function<void(const QString &)> done) {
        done(i == QLatin1String("wlan0") ? QStringLiteral("Home") : QString());
    });
    p.take(sample(0.2, 0.1, {0.5}, {0.4}));
    EXPECT_TRUE(p.resources().isEmpty()); // nothing built while no window shows it
    p.setSelected(QStringLiteral("memory"));
    EXPECT_TRUE(p.resources().isEmpty()); // not by a setter either
    EXPECT_TRUE(p.detail().isEmpty());
    p.setSelected(QStringLiteral("cpu"));
    p.setShown(QStringLiteral("performance"), true);
    // Audit A3: the speed and the uptime come with the sample, read on the sampler's thread (ReadSystemSpeed, asked while
    // Performance shows CPU), never by the window.
    EXPECT_TRUE(p.wantsSpeed());
    Snapshot withSpeed = sample(0.3, 0.1, {0.6}, {0.2});
    withSpeed.system.speedGhz = meanCurrentGhz(f.sys());
    withSpeed.system.uptime = readUptime(f.proc());
    p.take(withSpeed);
    EXPECT_EQ(keys(p.resources()), (QStringList{"cpu", "memory", "disk:nvme0n1", "net:wlan0"}));
    const QVariantMap cpu = p.resources().at(0).toMap();
    EXPECT_EQ(cpu.value(QStringLiteral("value")).toString(), QStringLiteral("40%"));
    EXPECT_EQ(cpu.value(QStringLiteral("subtitle")).toString(), QStringLiteral("2.00 GHz"));
    const QVariantList series = cpu.value(QStringLiteral("graph")).toMap().value(QStringLiteral("series")).toList();
    ASSERT_EQ(series.size(), 2);
    EXPECT_EQ(series.at(0).toMap().value(QStringLiteral("values")).toList().size(), 2); // both samples were kept
    EXPECT_EQ(p.resources().at(2).toMap().value(QStringLiteral("subtitle")).toString(), QStringLiteral("SSD"));
    EXPECT_EQ(p.resources().at(3).toMap().value(QStringLiteral("title")).toString(), QStringLiteral("Wi-Fi"));

    QVariantMap d = p.detail();
    EXPECT_EQ(d.value(QStringLiteral("subtitle")).toString(), QStringLiteral("Test CPU"));
    EXPECT_EQ(figureOf(d, QStringLiteral("Up Time:")), QStringLiteral("0:01:01:01"));
    EXPECT_EQ(figureOf(d, QStringLiteral("Threads:")), QStringLiteral("1,234"));
    EXPECT_EQ(figureOf(d, QStringLiteral("Logical Processors:")), QStringLiteral("1"));
    EXPECT_EQ(figureOf(d, QStringLiteral("Base Speed:")), QStringLiteral("<none>")); // absent, not made up

    p.setSelected(QStringLiteral("memory"));
    d = p.detail();
    const QLocale en(QLocale::English, QLocale::UnitedStates);
    EXPECT_EQ(figureOf(d, QStringLiteral("Committed:")),
              QStringLiteral("%1 of %2").arg(formatBytes(6.0 * (1ull << 30), en), formatBytes(24.0 * (1ull << 30), en)));
    const QVariantList bar = d.value(QStringLiteral("bar")).toList();
    ASSERT_EQ(bar.size(), 4);
    double sum = 0;
    for (const QVariant &part : bar)
        sum += part.toMap().value(QStringLiteral("fraction")).toDouble();
    EXPECT_NEAR(sum, 1.0, 1e-9); // In Use, Compressed, Cached and Free make the whole

    p.setSelected(QStringLiteral("net:wlan0"));
    d = p.detail();
    EXPECT_EQ(figureOf(d, QStringLiteral("Network:")), QStringLiteral("—")); // asked, never waited for (review of 5bfd4419)
    QCoreApplication::processEvents();                                     // its answer, later
    d = p.detail();
    EXPECT_EQ(figureOf(d, QStringLiteral("Network:")), QStringLiteral("Home"));
    EXPECT_EQ(figureOf(d, QStringLiteral("Signal:")), QStringLiteral("-52 dBm"));
    EXPECT_EQ(figureOf(d, QStringLiteral("Connection Type:")), QStringLiteral("Wi-Fi"));

    p.setSelected(QStringLiteral("disk:nvme0n1"));
    d = p.detail();
    EXPECT_EQ(figureOf(d, QStringLiteral("Type:")), QStringLiteral("SSD"));
    EXPECT_EQ(figureOf(d, QStringLiteral("Average Response Time:")), QStringLiteral("0.4 ms"));
    EXPECT_EQ(d.value(QStringLiteral("graphs")).toList().size(), 2); // Active Time and the transfer rate

    // The disk went away: back to CPU.
    Snapshot without = sample(0.1, 0.1, {0.2}, {0.1});
    without.system.disks.clear();
    p.take(without);
    EXPECT_EQ(p.selected(), QStringLiteral("cpu"));
}

TEST(Performance, ProcessorsClearAndGpus)
{
    Fixture f;
    Performance p(f.proc(), f.sys());
    p.setShown(QStringLiteral("cpuUsage"), true);
    p.take(sample(-1, -1, {-1, -1}, {-1, -1})); // the first sample: no share yet
    p.take(sample(0.3, 0.1, {0.6, 0.2}, {0.5, 0.05}));
    ASSERT_EQ(p.processors().size(), 2);
    const QVariantMap first = p.processors().at(0).toMap();
    EXPECT_DOUBLE_EQ(first.value(QStringLiteral("user")).toDouble(), 0.5);
    EXPECT_NEAR(first.value(QStringLiteral("system")).toDouble(), 0.1, 1e-12);
    const auto historyLength = [&] {
        return p.processors().at(0).toMap().value(QStringLiteral("graph")).toMap().value(QStringLiteral("series")).toList().at(0).toMap()
            .value(QStringLiteral("values")).toList().size();
    };
    EXPECT_EQ(historyLength(), 2);
    const QVariantList systemHistory = p.processors().at(0).toMap().value(QStringLiteral("graph")).toMap().value(QStringLiteral("series"))
                                           .toList().at(0).toMap().value(QStringLiteral("values")).toList();
    EXPECT_LT(systemHistory.at(0).toDouble(), 0);         // the first sample: a gap
    EXPECT_NEAR(systemHistory.at(1).toDouble(), 0.1, 1e-12); // System: the share less the user part
    p.clearCpuHistory();
    EXPECT_EQ(historyLength(), 0);
    EXPECT_TRUE(p.detail().isEmpty()); // the Performance window is not shown: no details built

    Snapshot gpu = sample(0.1, 0.1, {0.1, 0.1}, {0.1, 0.1});
    GpuDevice dev;
    dev.pdev = "0000:00:02.0";
    dev.driver = "i915";
    dev.engines = {{"render", 40}, {"video", 10}};
    dev.memoryRegions = {{"system", 1 << 20}};
    gpu.gpus.push_back(dev);
    p.setGpuNames({{QStringLiteral("0000:00:02.0"), QStringLiteral("Intel UHD Graphics")}});
    p.take(gpu);
    ASSERT_EQ(p.gpus().size(), 1);
    EXPECT_EQ(p.gpus().at(0).toMap().value(QStringLiteral("title")).toString(), QStringLiteral("Intel UHD Graphics"));
    p.take(sample(0.1, 0.1, {0.1, 0.1}, {0.1, 0.1})); // no client this sample: it idles, still listed
    ASSERT_EQ(p.gpus().size(), 1);
    const QVariantList values = p.gpus().at(0).toMap().value(QStringLiteral("graph")).toMap().value(QStringLiteral("series")).toList().at(0)
                                    .toMap().value(QStringLiteral("values")).toList();
    ASSERT_EQ(values.size(), 2);
    EXPECT_DOUBLE_EQ(values.at(0).toDouble(), 0.4);
    EXPECT_DOUBLE_EQ(values.at(1).toDouble(), 0.0);
    p.setShown(QStringLiteral("performance"), true);
    p.setSelected(QStringLiteral("gpu:0000:00:02.0"));
    const QVariantMap d = p.detail();
    EXPECT_EQ(figureOf(d, QStringLiteral("Driver:")), QStringLiteral("i915"));
    EXPECT_EQ(figureOf(d, QStringLiteral("Memory (system):")).isEmpty(), false);
    EXPECT_EQ(d.value(QStringLiteral("graphs")).toList().size(), 2); // one per engine
}

TEST(Performance, EachProcessorsGraphsOnlyWhileAWindowDrawsThem)
{
    // Audit A3: two series per logical processor were boxed into QVariantLists at each sample whatever the window showed.
    Fixture f;
    Performance p(f.proc(), f.sys());
    p.setShown(QStringLiteral("performance"), true);
    p.take(sample(0.3, 0.1, {0.6, 0.2}, {0.5, 0.05}));
    EXPECT_TRUE(p.processors().isEmpty()) << "Performance on its overall graph";
    p.setCpuMode(QStringLiteral("logical"));
    EXPECT_EQ(p.processors().size(), 2);
    p.setCpuMode(QStringLiteral("overall"));
    EXPECT_TRUE(p.processors().isEmpty());
    p.setShown(QStringLiteral("cpuHistory"), true);
    p.take(sample(0.3, 0.1, {0.6, 0.2}, {0.5, 0.05}));
    EXPECT_EQ(p.processors().size(), 2);
}
