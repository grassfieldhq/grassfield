// The activity monitor's sampler on fake /proc and /sys trees (apps/activity/src/sampler.cpp; ADR-0038 b to d;
// docs/specs/activity.md AM17, AM20 to AM29, AM41 to AM49, acceptance A-S1, A-S2, A-S9): owners and names, the Kernel row,
// rates, a pid reused, a process that ends, the turns of the costly reads, GPU clients, the AM29 shares, disks and
// interfaces, the kept-descriptor budget.
#include "fixture.h"
#include "sampler.h"

#include <algorithm>
#include <filesystem>

#include <sys/stat.h>
#include <unistd.h>

#include <gtest/gtest.h>

using namespace activity;
using activity_test::Fixture;

namespace
{

constexpr uint32_t kMe = 1000;
const std::string user = "/user.slice/user-1000.slice/user@1000.service";

Options options(const Fixture &f, uint32_t uid = kMe)
{
    Options o;
    o.procRoot = f.proc();
    o.sysRoot = f.sys();
    o.uid = uid;
    o.uidMin = 1000;
    o.clockTicks = 100;
    o.maxKeptFiles = 4096;
    o.pciIds = f.sys() + "/../hwdata/pci.ids"; // the fixture's, when a test writes one
    return o;
}

const ProcessRow *row(const Snapshot &s, int pid)
{
    for (const ProcessRow &r : s.rows) {
        if (r.pid == pid)
            return &r;
    }
    return nullptr;
}

std::string nul(std::initializer_list<const char *> words)
{
    std::string s;
    for (const char *w : words) {
        s += w;
        s += '\0';
    }
    return s;
}

} // namespace

TEST(Sampler, OwnersNamesKindsAndTheKernelRow)
{
    Fixture f;
    f.process(100, "foot", kMe, 10, 5000, nul({"/usr/bin/foot", "--server"}), user + "/app.slice/app-graphical.slice/app-Hyprland-foot-1a2b3c4d.scope");
    // Another person's process rewrote its argv[0] into a title: its name must be the kernel's short name (AD25).
    f.process(200, "sshd", 1001, 10, 5000, nul({"sshd: bob@pts/0"}), "/user.slice/user-1001.slice/session-4.scope");
    f.process(300, "systemd-journal", 0, 10, 100, nul({"/usr/lib/systemd/systemd-journald"}), "/system.slice/systemd-journald.service");
    f.process(2, "kthreadd", 0, 40, 1, "", "/", kPfKthread);
    f.process(3, "kworker/0:1", 0, 60, 2, "", "/", kPfKthread);
    // An own process whose name carries a right-to-left override and a control character.
    f.process(400, "evil", kMe, 0, 6000, nul({"/tmp/evil\u202Etxt.exe\x1b"}), user + "/app.slice/x.service");
    f.link("/tmp/evil\u202Etxt.exe\x1b", "proc/400/exe");
    f.process(500, "qs", kMe, 0, 7000, nul({"/usr/bin/qs", "-p", "/usr/share/grassfield/shell"}), user + "/session.slice/grassfield-shell.service");
    Sampler s(options(f));
    const Snapshot snap = s.sample(ReadProcesses | ReadStatus | ReadCommand, 10.0);

    ASSERT_EQ(snap.rows.size(), 5u); // the two kernel threads are summed, not listed
    EXPECT_EQ(snap.kernel.threads, 2);
    EXPECT_EQ(snap.kernel.cpuTicks, 100u);
    EXPECT_LT(snap.kernel.cpuPercent, 0); // no rate at the first sample

    const ProcessRow *foot = row(snap, 100);
    ASSERT_NE(foot, nullptr);
    EXPECT_TRUE(foot->own);
    EXPECT_EQ(foot->name, "foot");
    EXPECT_EQ(foot->command, "/usr/bin/foot --server");
    EXPECT_EQ(foot->kind, Kind::App);
    EXPECT_TRUE(foot->efficiencyEligible);
    EXPECT_FALSE(foot->session);
    EXPECT_TRUE(foot->hasMemory);
    EXPECT_EQ(foot->memory, 1000u * 1024); // RssAnon + VmSwap (AD6)

    const ProcessRow *sshd = row(snap, 200);
    ASSERT_NE(sshd, nullptr);
    EXPECT_FALSE(sshd->own);
    EXPECT_FALSE(sshd->systemAccount);
    EXPECT_EQ(sshd->kind, Kind::OtherUser);
    EXPECT_EQ(sshd->name, "sshd");
    EXPECT_EQ(sshd->command, ""); // never read for another owner
    EXPECT_FALSE(sshd->session);  // the session tests apply to the user's own processes only
    EXPECT_FALSE(sshd->efficiencyEligible);

    const ProcessRow *journald = row(snap, 300);
    ASSERT_NE(journald, nullptr);
    EXPECT_TRUE(journald->systemAccount);
    EXPECT_EQ(journald->kind, Kind::System);
    EXPECT_EQ(journald->name, "systemd-journal");

    const ProcessRow *evil = row(snap, 400);
    ASSERT_NE(evil, nullptr);
    EXPECT_EQ(evil->name, "eviltxt.exe"); // AM17: the override and the escape are gone
    EXPECT_EQ(evil->kind, Kind::Background);

    const ProcessRow *shell = row(snap, 500);
    ASSERT_NE(shell, nullptr);
    EXPECT_EQ(shell->name, "qs");
    EXPECT_TRUE(shell->session);
    EXPECT_EQ(shell->kind, Kind::Session);
    EXPECT_FALSE(shell->efficiencyEligible);
    EXPECT_EQ(snap.counters.cmdlineReads, 3u); // the own processes only
    EXPECT_EQ(snap.counters.cgroupReads, 3u);  // the own processes only: another owner's unit is never read (AD25)
}

TEST(Sampler, WithoutStatusTheDirectoryOwnerDecidesAndNoCmdlineIsReadForOthers)
{
    Fixture f;
    f.process(100, "foot", kMe, 10, 5000, nul({"/usr/bin/foot"}), user + "/app.slice/x.service");
    // The fixture's directories belong to whoever runs the test: with a uid of the app other than theirs, every process is
    // another owner's and is named from stat.
    const uint32_t runner = getuid();
    Sampler other(options(f, runner + 1));
    const Snapshot a = other.sample(ReadProcesses, 1.0);
    ASSERT_EQ(a.rows.size(), 1u);
    if (runner != 0) { // as root, a directory owned by root makes the sampler read status, which names uid 1000
        EXPECT_FALSE(a.rows[0].own);
        EXPECT_EQ(a.counters.cmdlineReads, 0u);
        EXPECT_EQ(a.counters.statusReads, 0u);
    }
    Sampler mine(options(f, runner));
    const Snapshot b = mine.sample(ReadProcesses, 1.0);
    if (runner != 0) {
        EXPECT_TRUE(b.rows[0].own);
        EXPECT_EQ(b.rows[0].name, "foot");
        EXPECT_EQ(b.counters.statusReads, 0u); // the CPU tab reads no status where the directory owner is not root
    }
}

TEST(Sampler, CpuRateAndTheKernelRowRate)
{
    Fixture f;
    f.process(100, "busy", kMe, 1000, 5000, nul({"busy"}), user + "/app.slice/x.service");
    f.process(2, "kworker", 0, 10, 1, "", "/", kPfKthread);
    Sampler s(options(f));
    const Snapshot first = s.sample(ReadProcesses, 10.0);
    EXPECT_LT(row(first, 100)->cpuPercent, 0);
    f.write("proc/100/stat", Fixture::statLine(100, "busy", 'R', 1, 0, 1150, 50, 4, 5000));
    f.write("proc/2/stat", Fixture::statLine(2, "kworker", 'I', 0, kPfKthread, 30, 0, 1, 1));
    const Snapshot second = s.sample(ReadProcesses, 12.0);
    // 200 ticks over 2 s at 100 ticks a second: one core's share is 100 % (AM20).
    EXPECT_DOUBLE_EQ(row(second, 100)->cpuPercent, 100.0);
    EXPECT_EQ(row(second, 100)->threads, 4);
    EXPECT_EQ(row(second, 100)->cpuTicks, 1200u);
    EXPECT_DOUBLE_EQ(second.kernel.cpuPercent, 10.0);
}

TEST(Sampler, APidReusedIsAnotherProcess)
{
    Fixture f;
    f.process(100, "old", kMe, 500, 5000, nul({"/usr/bin/old"}), user + "/app.slice/x.service");
    Sampler s(options(f));
    s.sample(ReadProcesses, 1.0);
    // Same pid, another start time: another process (row identity, the spec's Terms).
    f.process(100, "new", kMe, 10, 9000, nul({"/usr/bin/new"}), user + "/app.slice/app-graphical.slice/app-Hyprland-new-1a2b3c4d.scope");
    const Snapshot snap = s.sample(ReadProcesses, 2.0);
    const ProcessRow *r = row(snap, 100);
    ASSERT_NE(r, nullptr);
    EXPECT_EQ(r->start, 9000u);
    EXPECT_EQ(r->name, "new");
    EXPECT_LT(r->cpuPercent, 0);   // no rate from the old process's ticks
    EXPECT_EQ(r->kind, Kind::App); // its own unit, read again
}

TEST(Sampler, ANameFollowsAnExec)
{
    // sh -c 'sleep 1; exec sleep 30': the same pid and start time, another image (review of 949fc98).
    Fixture f;
    f.process(100, "sh", kMe, 1, 5000, nul({"sh", "-c", "sleep 1; exec sleep 30"}), user + "/app.slice/x.service");
    f.link("/usr/bin/bash", "proc/100/exe");
    Sampler s(options(f));
    const unsigned reads = ReadProcesses | ReadStatus | ReadCommand;
    EXPECT_EQ(row(s.sample(reads, 1.0), 100)->name, "sh"); // argv[0] "sh" is stat's name: a symbolic link to bash
    f.write("proc/100/stat", Fixture::statLine(100, "sleep", 'S', 1, 0, 1, 0, 1, 5000));
    f.write("proc/100/cmdline", nul({"sleep", "30"}));
    f.link("/usr/bin/sleep", "proc/100/exe");
    const Snapshot snap = s.sample(reads, 2.0);
    EXPECT_EQ(row(snap, 100)->name, "sleep");
    EXPECT_EQ(row(snap, 100)->command, "sleep 30");
    EXPECT_GE(row(snap, 100)->cpuPercent, 0); // the same process: its rate goes on
}

TEST(Sampler, AnExecThatKeepsStatsNameIsSeenByItsCodeAddresses)
{
    Fixture f;
    f.process(100, "app", kMe, 1, 5000, nul({"/opt/v1/app"}), user + "/app.slice/x.service");
    f.write("proc/100/stat", Fixture::statLine(100, "app", 'S', 1, 0, 1, 0, 1, 5000, 0, 0x55550000));
    f.link("/opt/v1/app", "proc/100/exe");
    Sampler s(options(f));
    const unsigned reads = ReadProcesses | ReadStatus | ReadCommand;
    EXPECT_EQ(row(s.sample(reads, 1.0), 100)->command, "/opt/v1/app");
    const Snapshot same = s.sample(reads, 2.0); // nothing changed: nothing read again
    EXPECT_EQ(same.counters.cmdlineReads, 0u);
    EXPECT_EQ(same.counters.exeLinks, 0u);
    f.write("proc/100/stat", Fixture::statLine(100, "app", 'S', 1, 0, 1, 0, 1, 5000, 0, 0x56660000)); // a new image
    f.write("proc/100/cmdline", nul({"/opt/v2/app", "--new"}));
    f.link("/opt/v2/app", "proc/100/exe");
    const Snapshot snap = s.sample(reads, 3.0);
    EXPECT_EQ(row(snap, 100)->command, "/opt/v2/app --new");
    EXPECT_EQ(snap.counters.exeLinks, 1u);
}

TEST(Sampler, AVeryLongCommandLineIsCutForTheTable)
{
    // Audit A1: a 1 MiB argv was kept whole in every row and laid out by the Command column at each sample.
    Fixture f;
    // Two-byte characters across the limit: the cut falls between characters, never inside one.
    std::string longArg = "x";
    while (longArg.size() < 3 * kCommandMax)
        longArg += "\u00e9";
    f.process(100, "make", kMe, 1, 5000, nul({"/usr/bin/make", longArg.c_str()}), user + "/app.slice/x.service");
    Sampler s(options(f));
    const ProcessRow *r = row(s.sample(ReadProcesses | ReadStatus | ReadCommand, 1.0), 100);
    ASSERT_NE(r, nullptr);
    EXPECT_LE(r->command.size(), kCommandMax);
    EXPECT_GE(r->command.size(), kCommandMax - 4);
    EXPECT_EQ(r->command.rfind("/usr/bin/make x", 0), 0u);
    EXPECT_EQ(r->command.find("\uFFFD"), std::string::npos);
}

TEST(Sampler, ATitleWrittenOverArgv0NeverNamesTheProcess)
{
    // Chromium's and Electron's helpers write a title over argv[0] (review of 949fc98).
    Fixture f;
    f.process(100, "chrome", kMe, 1, 5000,
              nul({"/usr/lib/fakechrome/chrome --type=renderer --user-data-dir=/home/u/.config/myapp --lang=en-US"}),
              user + "/app.slice/x.service");
    f.link("/usr/lib/fakechrome/chrome", "proc/100/exe");
    f.process(101, "bash", kMe, 1, 5000, nul({"-bash"}), user + "/app.slice/x.service"); // a login shell
    f.link("/usr/bin/bash", "proc/101/exe");
    f.process(102, "python3", kMe, 1, 5000, nul({"/usr/bin/python3", "tool.py"}), user + "/app.slice/x.service");
    f.link("/usr/bin/python3.13", "proc/102/exe"); // python3 is a symbolic link: the invoked name stays
    Sampler s(options(f));
    const Snapshot snap = s.sample(ReadProcesses | ReadStatus, 1.0);
    EXPECT_EQ(row(snap, 100)->name, "chrome");
    EXPECT_EQ(row(snap, 101)->name, "bash");
    EXPECT_EQ(row(snap, 102)->name, "python3");
}

TEST(Sampler, AProcessThatEndsGoesAndItsDescriptorsClose)
{
    Fixture f;
    f.process(100, "a", kMe, 1, 1, nul({"a"}), "/");
    f.process(101, "b", kMe, 1, 1, nul({"b"}), "/");
    Sampler s(options(f));
    s.sample(ReadProcesses | ReadStatus, 1.0);
    EXPECT_EQ(s.keptFiles(), 4u); // stat and status of two processes
    f.remove("proc/101");
    const Snapshot snap = s.sample(ReadProcesses | ReadStatus, 2.0);
    EXPECT_EQ(snap.rows.size(), 1u);
    EXPECT_EQ(row(snap, 101), nullptr);
    EXPECT_EQ(s.keptFiles(), 2u);
}

TEST(Sampler, TheKeptDescriptorBudgetHolds)
{
    Fixture f;
    for (int pid = 100; pid < 110; ++pid)
        f.process(pid, "p", kMe, 1, 1, nul({"p"}), "/");
    Options o = options(f);
    o.maxKeptFiles = 3;
    Sampler s(o);
    const Snapshot snap = s.sample(ReadProcesses | ReadStatus, 1.0);
    EXPECT_EQ(snap.rows.size(), 10u);
    EXPECT_EQ(s.keptFiles(), 3u);
    for (int pid = 100; pid < 110; ++pid)
        f.write("proc/" + std::to_string(pid) + "/stat", Fixture::statLine(pid, "p", 'S', 1, 0, 101, 0, 1, 1));
    const Snapshot again = s.sample(ReadProcesses | ReadStatus, 2.0);
    for (const ProcessRow &r : again.rows)
        EXPECT_DOUBLE_EQ(r.cpuPercent, 100.0); // read through kept and unkept files alike
}

TEST(Sampler, DiskBytesOfOwnProcessesOnly)
{
    Fixture f;
    f.process(100, "writer", kMe, 1, 1, nul({"writer"}), "/");
    f.process(200, "theirs", 1001, 1, 1, nul({"theirs"}), "/");
    f.write("proc/100/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: 1000\nwrite_bytes: 2000\ncancelled_write_bytes: 0\n");
    f.write("proc/200/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: 5\nwrite_bytes: 5\ncancelled_write_bytes: 0\n");
    Sampler s(options(f));
    s.sample(ReadProcesses | ReadStatus | ReadIo, 1.0);
    f.write("proc/100/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: 5000\nwrite_bytes: 2000\ncancelled_write_bytes: 0\n");
    const Snapshot snap = s.sample(ReadProcesses | ReadStatus | ReadIo, 3.0);
    const ProcessRow *w = row(snap, 100);
    ASSERT_TRUE(w->hasIo);
    EXPECT_EQ(w->bytesRead, 5000u);
    EXPECT_EQ(w->bytesWritten, 2000u);
    EXPECT_DOUBLE_EQ(w->readRate, 2000.0);
    EXPECT_DOUBLE_EQ(w->writeRate, 0.0);
    EXPECT_FALSE(row(snap, 200)->hasIo); // another owner's io is never read (the kernel would refuse it, A1)
    EXPECT_EQ(snap.counters.ioReads, 1u);
}

TEST(Sampler, EnergyImpactFormula)
{
    EXPECT_DOUBLE_EQ(energyImpact(10, -1, 50, 2e6, 1e6), 14.0); // 10 + 0 + 0.02 × 50 + 1.0 × 3 MB/s (AM36)
    EXPECT_DOUBLE_EQ(energyImpact(0, 30, 0, 0, 0), 30.0);
    EXPECT_DOUBLE_EQ(energyImpact(-1, -1, -1, -1, -1), 0.0); // unknown terms count as 0
}

TEST(Sampler, EnergyImpactOfOwnProcessesWithItsAverage)
{
    Fixture f;
    f.process(100, "app", kMe, 0, 1, nul({"app"}), "/");
    f.write("proc/100/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: 0\nwrite_bytes: 0\ncancelled_write_bytes: 0\n");
    f.write("proc/100/task/100/status", Fixture::statusText("app", kMe, 1, 0, 0));
    f.process(200, "theirs", 1001, 0, 1, nul({"theirs"}), "/");
    Options o = options(f);
    o.threadTurns = 1; // every process's wake-ups at every sample
    Sampler s(o);
    const unsigned reads = readsForTab(Tab::Energy) | ReadStatus;
    const Snapshot first = s.sample(reads, 10.0);
    EXPECT_LT(row(first, 100)->energyImpact, 0); // no CPU share at a process's first sample
    EXPECT_LT(first.energyImpact, 0);
    // Over 2 s: 100 ticks (50 % of one core), 1 000 wake-ups (500 a second), 4 MB read and 2 MB written (3 MB a second).
    f.write("proc/100/stat", Fixture::statLine(100, "app", 'S', 1, 0, 100, 0, 1, 1));
    f.write("proc/100/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: 4000000\nwrite_bytes: 2000000\ncancelled_write_bytes: 0\n");
    f.write("proc/100/task/100/status", Fixture::statusText("app", kMe, 1, 0, 1000));
    f.write("proc/200/stat", Fixture::statLine(200, "theirs", 'S', 1, 0, 100, 0, 1, 1));
    const Snapshot second = s.sample(reads, 12.0);
    // 50 + 0 (no GPU client) + 0.02 × 500 + 1.0 × 3 = 63 (AM36).
    EXPECT_DOUBLE_EQ(row(second, 100)->energyImpact, 63.0);
    EXPECT_DOUBLE_EQ(row(second, 100)->averageEnergyImpact, 63.0);
    EXPECT_DOUBLE_EQ(row(second, 200)->cpuPercent, 50.0);
    EXPECT_LT(row(second, 200)->energyImpact, 0); // another owner's: its io and descriptors are refused, so "—"
    EXPECT_DOUBLE_EQ(second.energyImpact, 63.0);  // the graph sums the user's own processes (AM39)
    // Then 6 s idle: 0, and the average weighted by time is (63 × 2 + 0 × 6) ÷ 8 (AM37).
    const Snapshot third = s.sample(reads, 18.0);
    EXPECT_DOUBLE_EQ(row(third, 100)->energyImpact, 0.0);
    EXPECT_DOUBLE_EQ(row(third, 100)->averageEnergyImpact, 63.0 * 2 / 8);
}

TEST(Sampler, ThreadsAreReadInTurnsOfFive)
{
    Fixture f;
    for (int pid = 1000; pid < 1010; ++pid) {
        f.process(pid, "t", kMe, 1, 1, nul({"t"}), "/");
        f.write("proc/" + std::to_string(pid) + "/task/" + std::to_string(pid) + "/status", Fixture::statusText("t", kMe, 1, 0, 100));
        f.write("proc/" + std::to_string(pid) + "/task/" + std::to_string(pid + 50000) + "/status", Fixture::statusText("t", kMe, 1, 0, 100));
    }
    Options o = options(f);
    o.threadTurns = 5;
    Sampler s(o);
    const unsigned reads = ReadProcesses | ReadStatus | ReadThreads;
    const Snapshot first = s.sample(reads, 0.0);
    EXPECT_EQ(first.counters.threadStatusReads, 20u); // every new process at once (two threads each)
    std::vector<int> readAt(10, -1);
    Snapshot snap;
    for (int i = 1; i <= 6; ++i) {
        for (int pid = 1000; pid < 1010; ++pid) // +100 voluntary switches per thread and second
            for (int t : {pid, pid + 50000})
                f.write("proc/" + std::to_string(pid) + "/task/" + std::to_string(t) + "/status", Fixture::statusText("t", kMe, 1, 0, 100 + 100 * i));
        snap = s.sample(reads, static_cast<double>(i));
        EXPECT_EQ(snap.counters.threadStatusReads, 4u) << i; // a fifth of the ten processes, two threads each
        for (const ProcessRow &r : snap.rows) {
            if (r.wakeRate >= 0 && readAt[r.pid - 1000] < 0)
                readAt[r.pid - 1000] = i;
        }
    }
    for (int pid = 1000; pid < 1010; ++pid) { // every process covered within five samples (A-S9)
        EXPECT_GE(readAt[pid - 1000], 1) << pid;
        EXPECT_LE(readAt[pid - 1000], 5) << pid;
    }
    // Two threads, +100 each per second: 200 switches a second, whatever the length of the process's turn.
    for (const ProcessRow &r : snap.rows)
        EXPECT_NEAR(r.wakeRate, 200.0, 1e-9) << r.pid;
}

TEST(Sampler, DescriptorsAreReadInTurnsOfTenAndClassified)
{
    Fixture f;
    for (int pid = 2000; pid < 2010; ++pid) {
        f.process(pid, "d", kMe, 1, 1, nul({"d"}), "/");
        const std::string fd = "proc/" + std::to_string(pid) + "/fd/";
        f.link("socket:[" + std::to_string(700000 + pid) + "]", fd + "3");
        f.link("/dev/dri/renderD128", fd + "4");
        f.link("/etc/hosts", fd + "5");
    }
    Options o = options(f);
    o.descriptorTurns = 10;
    Sampler s(o);
    const unsigned reads = ReadProcesses | ReadStatus | ReadDescriptors;
    const Snapshot first = s.sample(reads, 0.0);
    EXPECT_EQ(first.counters.fdListReads, 10u);
    EXPECT_EQ(first.counters.fdLinks, 30u);
    for (const ProcessRow &r : first.rows)
        EXPECT_EQ(r.openFiles, 3);
    for (int i = 1; i < 10; ++i) {
        const Snapshot snap = s.sample(reads, static_cast<double>(i));
        EXPECT_EQ(snap.counters.fdListReads, 1u) << i; // one tenth of the ten processes
        EXPECT_EQ(snap.counters.cgroupReads, 1u) << i; // its unit read again in its first turns
    }
    for (int i = 10; i < 30; ++i)
        s.sample(reads, static_cast<double>(i));
    EXPECT_EQ(s.sample(reads, 30.0).counters.cgroupReads, 0u); // after two turns, never again
}

TEST(Sampler, TheOwnerIsReadOnArrivalAfterAnExecAndInItsTurn)
{
    // Not six hundred fstatat a sample (review of 949fc98): a process's directory owner when it is first seen, after an
    // exec, and in its turn, a tenth of the processes per sample.
    Fixture f;
    for (int pid = 100; pid < 110; ++pid)
        f.process(pid, "o", kMe, 0, 1, nul({"o"}), "/");
    Options o = options(f);
    o.descriptorTurns = 10;
    Sampler s(o);
    EXPECT_EQ(s.sample(ReadProcesses, 0.0).counters.ownerStats, 10u);
    for (int i = 1; i <= 9; ++i)
        EXPECT_EQ(s.sample(ReadProcesses, static_cast<double>(i)).counters.ownerStats, 1u) << i;
    f.write("proc/105/stat", Fixture::statLine(105, "other", 'S', 1, 0, 0, 0, 1, 1)); // an exec
    const Snapshot snap = s.sample(ReadProcesses, 10.0);
    EXPECT_EQ(snap.counters.ownerStats, 2u); // its turn's process and the one that exec'd
    EXPECT_EQ(row(snap, 105)->name, "other");
}

TEST(Sampler, AKernelThreadsNewNameIsNoExec)
{
    Fixture f;
    f.process(3, "kworker/0:1", 0, 10, 2, "", "/", kPfKthread);
    Sampler s(options(f));
    EXPECT_EQ(s.sample(ReadProcesses, 0.0).counters.ownerStats, 0u); // a kernel thread's owner is root: never looked up
    f.write("proc/3/stat", Fixture::statLine(3, "kworker/0:1-events", 'I', 0, kPfKthread, 20, 0, 1, 2));
    const Snapshot snap = s.sample(ReadProcesses, 1.0);
    EXPECT_EQ(snap.counters.ownerStats, 0u);
    EXPECT_EQ(snap.counters.cmdlineReads, 0u);
    EXPECT_EQ(snap.kernel.threads, 1);
    EXPECT_DOUBLE_EQ(snap.kernel.cpuPercent, 10.0); // the same thread, its rate goes on
}

TEST(Sampler, TheTurnsAreAsFullWhateverThePids)
{
    // Twenty processes whose pids are all multiples of ten: turns by pid would read all twenty at one sample and none at
    // the nine others (review of 949fc98); by place of arrival, two each time.
    Fixture f;
    for (int i = 0; i < 20; ++i) {
        const int pid = 3000 + 10 * i;
        f.process(pid, "d", kMe, 1, 1, nul({"d"}), "/");
        f.write("proc/" + std::to_string(pid) + "/task/" + std::to_string(pid) + "/status", Fixture::statusText("d", kMe, 1, 0, 1));
    }
    Options o = options(f);
    o.descriptorTurns = 10;
    o.threadTurns = 5;
    Sampler s(o);
    const unsigned reads = ReadProcesses | ReadStatus | ReadDescriptors | ReadThreads;
    s.sample(reads, 0.0);
    for (int i = 1; i <= 10; ++i) {
        const Snapshot snap = s.sample(reads, static_cast<double>(i));
        EXPECT_EQ(snap.counters.fdListReads, 2u) << i;
        EXPECT_EQ(snap.counters.threadStatusReads, 4u) << i;
    }
}

TEST(Sampler, GpuSharesPerProcessAndPerDevice)
{
    Fixture f;
    auto client = [&](int pid, int fd, int clientId, unsigned long long render, unsigned long long video) {
        f.write("proc/" + std::to_string(pid) + "/fdinfo/" + std::to_string(fd),
                "pos:\t0\ndrm-driver:\ti915\ndrm-pdev:\t0000:00:02.0\ndrm-client-id:\t" + std::to_string(clientId)
                    + "\ndrm-engine-render:\t" + std::to_string(render) + " ns\ndrm-engine-video:\t" + std::to_string(video)
                    + " ns\ndrm-engine-capacity-video:\t2\ndrm-memory-system0:\t4 MiB\n");
    };
    f.process(100, "game", kMe, 1, 1, nul({"game"}), "/");
    f.process(200, "Hyprland", kMe, 1, 1, nul({"Hyprland"}), user + "/session.slice/wayland-wm@hyprland.desktop.service");
    f.link("/dev/dri/renderD128", "proc/100/fd/7");
    f.link("/dev/dri/renderD128", "proc/100/fd/8"); // the same client through a second descriptor: counted once
    f.link("/dev/dri/card1", "proc/200/fd/9");
    f.process(300, "helper", kMe, 1, 1, nul({"helper"}), "/");
    f.link("/dev/dri/renderD128", "proc/300/fd/5"); // the game's client, inherited: counted once, with the game
    client(100, 7, 1, 0, 0);
    client(100, 8, 1, 0, 0);
    client(200, 9, 2, 0, 0);
    client(300, 5, 1, 0, 0);
    Options o = options(f);
    o.descriptorTurns = 1;
    Sampler s(o);
    const unsigned reads = ReadProcesses | ReadStatus | ReadDescriptors | ReadGpu;
    const Snapshot first = s.sample(reads, 1.0);
    EXPECT_LT(row(first, 100)->gpuPercent, 0); // no rate yet
    client(100, 7, 1, 500000000, 1000000000); // render 0.5 s in 1 s: 50 %; video 1 s on a capacity of 2: 50 %
    client(100, 8, 1, 500000000, 1000000000);
    client(200, 9, 2, 300000000, 0);
    client(300, 5, 1, 500000000, 1000000000);
    const Snapshot snap = s.sample(reads, 2.0);
    const ProcessRow *game = row(snap, 100);
    ASSERT_TRUE(game->hasGpu);
    EXPECT_EQ(game->gpuDevices, std::vector<std::string>{"0000:00:02.0"}); // Processes, by GPU (AM49)
    EXPECT_DOUBLE_EQ(game->gpuPercent, 50.0); // the busiest engine (AM46)
    EXPECT_EQ(game->gpuNs, 1500000000u);       // every engine's time
    EXPECT_DOUBLE_EQ(row(snap, 200)->gpuPercent, 30.0);
    EXPECT_FALSE(row(snap, 300)->hasGpu);
    ASSERT_EQ(snap.gpus.size(), 1u);
    const GpuDevice &gpu = snap.gpus[0];
    EXPECT_EQ(gpu.pdev, "0000:00:02.0");
    EXPECT_EQ(gpu.driver, "i915");
    double render = -1, video = -1;
    for (const GpuEngine &e : gpu.engines) {
        if (e.name == "render")
            render = e.percent;
        if (e.name == "video")
            video = e.percent;
    }
    EXPECT_DOUBLE_EQ(render, 80.0); // the two clients summed (AM47)
    EXPECT_DOUBLE_EQ(video, 50.0);
    EXPECT_EQ(snap.counters.fdinfoReads, 4u);
    EXPECT_EQ(gpu.card, -1); // no /sys/class/drm in this fixture: no card, no name
    EXPECT_EQ(gpu.model, "");
}

// AM47: a GPU's name is its card's PCI ids looked up in pci.ids, read once; another card's links and the connectors
// (card1-eDP-1) are not it.
TEST(Sampler, AGpuIsNamedFromItsCardsPciIds)
{
    Fixture f;
    f.process(100, "game", kMe, 1, 1, nul({"game"}), "/");
    f.link("/dev/dri/renderD129", "proc/100/fd/7");
    f.write("proc/100/fdinfo/7", "pos:\t0\ndrm-driver:\ti915\ndrm-pdev:\t0000:00:02.0\ndrm-client-id:\t3\ndrm-engine-render:\t5 ns\n");
    f.link("../../../devices/pci0000:00/0000:03:00.0", "sys/class/drm/card0/device");
    f.link("../../../devices/pci0000:00/0000:00:02.0", "sys/class/drm/card1/device");
    f.link("../../../devices/pci0000:00/0000:00:02.0", "sys/class/drm/card1-eDP-1/device");
    f.write("sys/devices/pci0000:00/0000:00:02.0/vendor", "0x8086\n");
    f.write("sys/devices/pci0000:00/0000:00:02.0/device", "0x9bc4\n");
    f.write("hwdata/pci.ids", "# comment\n8086  Intel Corporation\n\t9bc4  CometLake-H GT2 [UHD Graphics]\n\t\t1028 09be  "
                              "Subsystem\n");
    Options o = options(f);
    o.descriptorTurns = 1;
    Sampler s(o);
    const unsigned reads = readsForTab(Tab::Cpu);
    const Snapshot first = s.sample(reads, 1.0);
    ASSERT_EQ(first.gpus.size(), 1u);
    EXPECT_EQ(first.gpus[0].card, 1);
    EXPECT_EQ(first.gpus[0].model, "Intel UHD Graphics");
    const uint64_t once = first.counters.systemReads;
    f.write("hwdata/pci.ids", "8086  Intel Corporation\n\t9bc4  Renamed\n");
    const Snapshot again = s.sample(reads, 2.0);
    EXPECT_EQ(again.gpus[0].model, "Intel UHD Graphics"); // read once
    EXPECT_EQ(again.counters.systemReads + 3, once);      // vendor, device and pci.ids, the first time only
}

// AM47: a connector (card1-eDP-1) is not a card, even one whose device link ends in the GPU's pdev.
TEST(Sampler, AConnectorIsNotACard)
{
    Fixture f;
    f.process(100, "game", kMe, 1, 1, nul({"game"}), "/");
    f.link("/dev/dri/renderD129", "proc/100/fd/7");
    f.write("proc/100/fdinfo/7", "pos:\t0\ndrm-driver:\ti915\ndrm-pdev:\t0000:00:02.0\ndrm-client-id:\t3\ndrm-engine-render:\t5 ns\n");
    f.link("../../../devices/pci0000:00/0000:00:02.0", "sys/class/drm/card7-eDP-1/device");
    f.write("sys/devices/pci0000:00/0000:00:02.0/vendor", "0x8086\n");
    f.write("sys/devices/pci0000:00/0000:00:02.0/device", "0x9bc4\n");
    f.write("hwdata/pci.ids", "8086  Intel Corporation\n\t9bc4  CometLake-H GT2 [UHD Graphics]\n");
    Options o = options(f);
    o.descriptorTurns = 1;
    Sampler s(o);
    const Snapshot snap = s.sample(readsForTab(Tab::Cpu), 1.0);
    ASSERT_EQ(snap.gpus.size(), 1u);
    EXPECT_EQ(snap.gpus[0].card, -1);
    EXPECT_EQ(snap.gpus[0].model, "");
}

// 2b: every tab reads the four system groups, so each tab's graph keeps its history whichever tab is shown (macOS).
TEST(Sampler, EveryTabReadsTheSystemFiles)
{
    for (Tab tab : {Tab::Cpu, Tab::Memory, Tab::Energy, Tab::Disk, Tab::Network}) {
        const unsigned reads = readsForTab(tab);
        for (unsigned r : {ReadSystemCpu, ReadSystemMemory, ReadSystemDisk, ReadSystemNet})
            EXPECT_TRUE(reads & r) << static_cast<int>(tab) << " " << r;
    }
}

// AM45: a client is read through one of its descriptors between two descriptor turns (the integrator's AM-P2 run of
// f68789c: the CPU tab at 0.5 ms from its limit on the i5). Mesa duplicates its DRM descriptor; a duplicate is the same
// client.
TEST(Sampler, ADrmClientIsReadThroughOneOfItsDescriptors)
{
    Fixture f;
    auto client = [&](int fd, int clientId, unsigned long long render) {
        f.write("proc/100/fdinfo/" + std::to_string(fd), "pos:\t0\ndrm-driver:\ti915\ndrm-pdev:\t0000:00:02.0\ndrm-client-id:\t"
                    + std::to_string(clientId) + "\ndrm-engine-render:\t" + std::to_string(render) + " ns\n");
    };
    f.process(100, "game", kMe, 1, 1, nul({"game"}), "/");
    for (int fd : {7, 8, 9})
        f.link("/dev/dri/renderD128", "proc/100/fd/" + std::to_string(fd));
    client(7, 1, 0);
    client(8, 1, 0); // 7 duplicated: the same client
    client(9, 2, 0);
    Options o = options(f);
    o.descriptorTurns = 3; // pid 100 arrives first: its turns are samples 1, 4, 7...
    Sampler s(o);
    const unsigned reads = readsForTab(Tab::Cpu);
    EXPECT_EQ(s.sample(reads, 1.0).counters.fdinfoReads, 3u); // the turn: every descriptor
    client(7, 1, 200000000);
    client(8, 1, 200000000);
    client(9, 2, 100000000);
    Snapshot snap = s.sample(reads, 2.0);
    EXPECT_EQ(snap.counters.fdinfoReads, 2u); // one per client
    EXPECT_DOUBLE_EQ(row(snap, 100)->gpuPercent, 30.0); // render: 20 % + 10 %
    EXPECT_EQ(row(snap, 100)->gpuNs, 300000000u);

    // Descriptor 7 closed and its number taken by another client: every descriptor is read again at once.
    client(7, 3, 0);
    client(8, 1, 400000000);
    client(9, 2, 200000000);
    snap = s.sample(reads, 3.0);
    EXPECT_EQ(snap.counters.fdinfoReads, 4u); // 7, which no longer gives client 1; then 7, 8 and 9
    EXPECT_DOUBLE_EQ(row(snap, 100)->gpuPercent, 30.0); // client 1 through 8, client 2; client 3 has no rate yet
    EXPECT_EQ(row(snap, 100)->gpuNs, 600000000u);

    // A client opened since, through two descriptors: found at the next turn, which reads every descriptor again.
    for (int fd : {10, 11}) {
        f.link("/dev/dri/renderD128", "proc/100/fd/" + std::to_string(fd));
        client(fd, 4, 0);
    }
    snap = s.sample(reads, 4.0); // the turn
    EXPECT_EQ(snap.counters.fdinfoReads, 5u);
    client(7, 3, 100000000);
    client(8, 1, 600000000);
    client(9, 2, 300000000);
    client(10, 4, 100000000);
    client(11, 4, 100000000);
    snap = s.sample(reads, 5.0);
    EXPECT_EQ(snap.counters.fdinfoReads, 4u); // 7 to 10
    EXPECT_DOUBLE_EQ(row(snap, 100)->gpuPercent, 50.0); // 10 % + 20 % + 10 % + 10 %
}

// amdgpu writes no engine line for an engine a client has not used: a client idle at its turn is still picked, and its
// work shows at once, not at the next turn (the integrator's review of 983b7de).
TEST(Sampler, AClientIdleAtItsTurnIsPickedAndItsWorkShows)
{
    Fixture f;
    auto client = [&](int fd, const std::string &engines) {
        f.write("proc/100/fdinfo/" + std::to_string(fd),
                "pos:\t0\ndrm-driver:\tamdgpu\ndrm-client-id:\t5\ndrm-pdev:\t0000:03:00.0\npasid:\t32770\n" + engines);
    };
    f.process(100, "game", kMe, 1, 1, nul({"game"}), "/");
    for (int fd : {7, 8})
        f.link("/dev/dri/renderD128", "proc/100/fd/" + std::to_string(fd));
    client(7, "");
    client(8, ""); // 7 duplicated
    Options o = options(f);
    o.descriptorTurns = 10; // pid 100's turn is sample 1
    Sampler s(o);
    const unsigned reads = readsForTab(Tab::Cpu);
    Snapshot snap = s.sample(reads, 1.0);
    EXPECT_EQ(snap.counters.fdinfoReads, 2u); // the turn
    EXPECT_LT(row(snap, 100)->gpuPercent, 0); // no engine used: "—"
    snap = s.sample(reads, 2.0);
    EXPECT_EQ(snap.counters.fdinfoReads, 1u); // through the descriptor picked at the turn
    EXPECT_LT(row(snap, 100)->gpuPercent, 0); // still none
    client(7, "drm-engine-gfx:\t0 ns\n");
    client(8, "drm-engine-gfx:\t0 ns\n");
    snap = s.sample(reads, 3.0);
    EXPECT_EQ(snap.counters.fdinfoReads, 1u);
    client(7, "drm-engine-gfx:\t500000000 ns\n");
    client(8, "drm-engine-gfx:\t500000000 ns\n");
    snap = s.sample(reads, 4.0);
    EXPECT_EQ(snap.counters.fdinfoReads, 1u);
    EXPECT_DOUBLE_EQ(row(snap, 100)->gpuPercent, 50.0);
}

// 2b, the Disk tab's cost: a stat or io line identical to the last one is not parsed again, and the row is the same; a
// changed line is, whatever its length, and so is a line whose code addresses are wanted again.
// 2b: the rows of the last sample are emptied and filled again in place; a row takes nothing from the one it reuses.
TEST(Sampler, ARowTakesNothingFromTheRowItReuses)
{
    Fixture f;
    f.process(100, "foot", kMe, 10, 5000, nul({"/usr/bin/foot", "--server"}),
              user + "/app.slice/app-graphical.slice/app-Hyprland-org.codeberg.dnkl.foot-1a2b3c4d.scope");
    f.write("proc/100/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: 4096\nwrite_bytes: 0\ncancelled_write_bytes: 0\n");
    f.process(300, "a-process-with-a-long-name", kMe, 10, 5000, nul({"/usr/bin/a-process-with-a-long-name"}), "/");
    Sampler s(options(f));
    const unsigned reads = ReadProcesses | ReadStatus | ReadCommand | ReadIo;
    const Snapshot first = s.sample(reads, 1.0);
    ASSERT_EQ(first.rows.size(), 2u);
    EXPECT_EQ(first.rows[0].command, "/usr/bin/foot --server");
    EXPECT_FALSE(first.rows[0].appId.empty());
    EXPECT_TRUE(first.rows[0].hasIo);

    f.remove("proc/100");
    f.process(50, "sshd", 1001, 10, 6000, nul({"sshd: bob@pts/0"}), "/user.slice/user-1001.slice/session-4.scope");
    const Snapshot second = s.sample(reads, 2.0);
    ASSERT_EQ(second.rows.size(), 2u);
    const ProcessRow &other = second.rows[0]; // the slot foot's row had
    EXPECT_EQ(other.pid, 50);
    EXPECT_FALSE(other.own);
    EXPECT_EQ(other.name, "sshd");
    EXPECT_EQ(other.command, "");
    EXPECT_EQ(other.appId, "");
    EXPECT_EQ(other.kind, Kind::OtherUser);
    EXPECT_FALSE(other.hasIo);
    EXPECT_EQ(other.bytesRead, 0u);
    EXPECT_LT(other.cpuPercent, 0);
    EXPECT_TRUE(other.gpuDevices.empty());
    EXPECT_EQ(second.rows[1].name, "a-process-with-a-long-name");

    f.remove("proc/50");
    const Snapshot third = s.sample(reads, 3.0);
    ASSERT_EQ(third.rows.size(), 1u); // the rows that went are dropped
    EXPECT_EQ(third.rows[0].pid, 300);
}

TEST(Sampler, AnUnchangedLineIsNotParsedAgain)
{
    Fixture f;
    f.process(100, "mine", kMe, 100, 1, nul({"mine"}), "/");
    f.process(101, "other", kMe + 1, 50, 1, nul({"other"}), "/");
    auto io = [&](unsigned long long read, unsigned long long written) {
        f.write("proc/100/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: " + std::to_string(read)
                                   + "\nwrite_bytes: " + std::to_string(written) + "\ncancelled_write_bytes: 0\n");
    };
    io(1000, 3000);
    Sampler s(options(f));
    const unsigned reads = readsForTab(Tab::Disk);
    Snapshot first = s.sample(reads, 1.0);
    EXPECT_EQ(first.counters.statParses, 2u);
    EXPECT_EQ(first.counters.ioParses, 1u);
    Snapshot same = s.sample(reads, 2.0);
    EXPECT_EQ(same.counters.statParses, 0u);
    EXPECT_EQ(same.counters.ioParses, 0u);
    ASSERT_NE(row(same, 100), nullptr);
    EXPECT_EQ(row(same, 100)->name, "mine");
    // A cache hit gives both counters back, so both rates are 0, not "—" (review of PR #53: the write side).
    EXPECT_EQ(row(same, 100)->bytesRead, 1000u);
    EXPECT_EQ(row(same, 100)->bytesWritten, 3000u);
    EXPECT_DOUBLE_EQ(row(same, 100)->readRate, 0.0);
    EXPECT_DOUBLE_EQ(row(same, 100)->writeRate, 0.0);
    EXPECT_EQ(row(same, 101)->name, "other");

    // Same lengths, other bytes: parsed, and the rates follow.
    f.write("proc/100/stat", Fixture::statLine(100, "mine", 'S', 1, 0, 200, 0, 1, 1));
    io(5000, 4000);
    Snapshot changed = s.sample(reads, 3.0);
    EXPECT_EQ(changed.counters.statParses, 1u);
    EXPECT_EQ(changed.counters.ioParses, 1u);
    EXPECT_DOUBLE_EQ(row(changed, 100)->readRate, 4000.0);
    EXPECT_DOUBLE_EQ(row(changed, 100)->writeRate, 1000.0);
    EXPECT_DOUBLE_EQ(row(changed, 100)->cpuPercent, 100.0);
}

// Review of PR #53 (surviving mutants of the line cache): the start time is part of the cached line, so a pid reused by a
// process whose stat differs only there is another process; the reuse stores its line, so the sample after it parses
// nothing; the code-address flag is part of the cache.
TEST(Sampler, AReusedPidWithTheSameLineButItsStartIsAnotherProcess)
{
    Fixture f;
    f.process(100, "same", kMe, 500, 5000, nul({"same"}), "/");
    Sampler s(options(f));
    s.sample(ReadProcesses, 1.0);
    EXPECT_GE(row(s.sample(ReadProcesses, 2.0), 100)->cpuPercent, 0);
    f.write("proc/100/stat", Fixture::statLine(100, "same", 'S', 1, 0, 500, 0, 1, 9000)); // only the start time differs
    const Snapshot reused = s.sample(ReadProcesses, 3.0);
    EXPECT_EQ(row(reused, 100)->start, 9000u);
    EXPECT_LT(row(reused, 100)->cpuPercent, 0); // another process: no rate from the old one's ticks
    const Snapshot after = s.sample(ReadProcesses, 4.0);
    EXPECT_EQ(after.counters.statParses, 0u); // the reuse kept its line
    EXPECT_EQ(row(after, 100)->start, 9000u);
    EXPECT_GE(row(after, 100)->cpuPercent, 0);
}

// The processes that ended are swept when some did, a kernel thread among those listed (its entry counts as seen).
TEST(Sampler, AnEndedProcessIsSweptBesideAKernelThread)
{
    Fixture f;
    f.process(2, "kthreadd", 0, 40, 1, "", "/", kPfKthread);
    f.process(100, "a", kMe, 1, 5000, nul({"a"}), "/");
    f.process(101, "b", kMe, 1, 5000, nul({"b"}), "/");
    Sampler s(options(f));
    EXPECT_EQ(s.sample(ReadProcesses, 1.0).counters.keptFiles, 3u); // each one's stat
    EXPECT_EQ(s.sample(ReadProcesses, 2.0).counters.keptFiles, 3u);
    f.remove("proc/101");
    const Snapshot after = s.sample(ReadProcesses, 3.0);
    EXPECT_EQ(after.counters.keptFiles, 2u); // b's descriptor closed
    EXPECT_EQ(after.rows.size(), 1u);
}

// AM8: back on screen after a time hidden, no rate is drawn across the gap; the next sample starts every rate again.
TEST(Sampler, NoRateIsDrawnAcrossAGap)
{
    Fixture f;
    f.process(100, "mine", kMe, 100, 1, nul({"mine"}), "/");
    auto io = [&](unsigned long long read) {
        f.write("proc/100/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: " + std::to_string(read)
                                   + "\nwrite_bytes: 0\ncancelled_write_bytes: 0\n");
    };
    io(0);
    f.write("proc/stat", "cpu  1000 0 1000 8000 0 0 0 0 0 0\ncpu0 1000 0 1000 8000 0 0 0 0 0 0\n");
    Sampler s(options(f));
    const unsigned reads = ReadProcesses | ReadIo | ReadSystemCpu;
    s.sample(reads, 1.0);
    f.write("proc/100/stat", Fixture::statLine(100, "mine", 'S', 1, 0, 200, 0, 1, 1));
    f.write("proc/stat", "cpu  1100 0 1000 8900 0 0 0 0 0 0\ncpu0 1100 0 1000 8900 0 0 0 0 0 0\n");
    io(1000);
    Snapshot snap = s.sample(reads, 2.0);
    EXPECT_DOUBLE_EQ(row(snap, 100)->cpuPercent, 100.0);
    EXPECT_DOUBLE_EQ(row(snap, 100)->readRate, 1000.0);
    EXPECT_GE(snap.system.userShare, 0);

    // Hidden for an hour: whatever happened meanwhile draws no rate.
    s.forgetRates();
    f.write("proc/100/stat", Fixture::statLine(100, "mine", 'S', 1, 0, 90000, 0, 1, 1));
    f.write("proc/stat", "cpu  91000 0 1000 360000 0 0 0 0 0 0\ncpu0 91000 0 1000 360000 0 0 0 0 0 0\n");
    io(500000);
    snap = s.sample(reads, 3602.0);
    EXPECT_LT(row(snap, 100)->cpuPercent, 0);
    EXPECT_LT(row(snap, 100)->readRate, 0);
    EXPECT_EQ(row(snap, 100)->bytesRead, 500000u); // totals are no rates: they show
    EXPECT_LT(snap.system.userShare, 0);

    // The next sample's rates are over the interval since that one.
    f.write("proc/100/stat", Fixture::statLine(100, "mine", 'S', 1, 0, 90050, 0, 1, 1));
    f.write("proc/stat", "cpu  91050 0 1000 360050 0 0 0 0 0 0\ncpu0 91050 0 1000 360050 0 0 0 0 0 0\n");
    io(502000);
    snap = s.sample(reads, 3603.0);
    EXPECT_DOUBLE_EQ(row(snap, 100)->cpuPercent, 50.0);
    EXPECT_DOUBLE_EQ(row(snap, 100)->readRate, 2000.0);
    EXPECT_GE(snap.system.userShare, 0);
}

// AM10, AM17: an own process in a launch's unit (A7) names its app, from which the window takes the app's icon.
TEST(Sampler, AnAppUnitNamesTheRowsApp)
{
    Fixture f;
    f.process(100, "firefox", kMe, 1, 1, nul({"firefox"}), user + "/app.slice/app-Hyprland-org.mozilla.firefox-1a2b3c4d.scope");
    f.process(101, "foot", kMe, 1, 1, nul({"foot"}), user + "/app.slice/app-Hyprland-foot@0a1b2c3d.service");
    f.process(102, "agent", kMe, 1, 1, nul({"agent"}), user + "/app.slice/ssh-agent.service");
    f.process(200, "theirs", 1001, 1, 1, nul({"theirs"}), "/user.slice/user-1001.slice/user@1001.service/app.slice/app-Hyprland-x-1a2b3c4d.scope");
    Sampler s(options(f));
    // ReadStatus: a fixture's directories are all the test user's, so status's real uid tells the other owner.
    const Snapshot snap = s.sample(readsForTab(Tab::Cpu) | ReadStatus, 1.0);
    EXPECT_EQ(row(snap, 100)->appId, "org.mozilla.firefox");
    EXPECT_EQ(row(snap, 101)->appId, "foot");
    EXPECT_EQ(row(snap, 102)->appId, "");
    EXPECT_EQ(row(snap, 200)->appId, ""); // another owner's cgroup is never read (AD25)
}

TEST(Sampler, UserAndSystemAsMacOSMeansThem)
{
    Fixture f;
    f.process(100, "mine", kMe, 100, 1, nul({"mine"}), "/");
    f.process(200, "theirs", 1001, 100, 1, nul({"theirs"}), "/");
    f.write("proc/stat", "cpu  1000 0 1000 8000 0 0 0 0 0 0\ncpu0 1000 0 1000 8000 0 0 0 0 0 0\n");
    f.write("proc/loadavg", "0.10 0.20 0.30 1/321 999\n");
    Sampler s(options(f));
    const unsigned reads = ReadProcesses | ReadStatus | ReadSystemCpu;
    const Snapshot first = s.sample(reads, 1.0);
    EXPECT_EQ(first.system.tasks, 321);
    EXPECT_LT(first.system.userShare, 0);
    // 1000 ticks pass: 400 busy (300 user mode, 100 kernel mode), 600 idle; the user's process used 100, another's 250.
    f.write("proc/stat", "cpu  1300 0 1100 8600 0 0 0 0 0 0\ncpu0 1300 0 1100 8600 0 0 0 0 0 0\n");
    f.write("proc/100/stat", Fixture::statLine(100, "mine", 'S', 1, 0, 200, 0, 1, 1));
    f.write("proc/200/stat", Fixture::statLine(200, "theirs", 'S', 1, 0, 350, 0, 1, 1));
    const Snapshot snap = s.sample(reads, 11.0);
    ASSERT_TRUE(snap.system.sharesByOwner);
    EXPECT_DOUBLE_EQ(snap.system.userShare, 0.1);   // the user's processes (AD5)
    EXPECT_DOUBLE_EQ(snap.system.systemShare, 0.3); // everything else that was busy
    EXPECT_DOUBLE_EQ(snap.system.idleShare, 0.6);
    ASSERT_EQ(snap.system.perCpuBusy.size(), 1u);
    EXPECT_DOUBLE_EQ(snap.system.perCpuBusy[0], 0.4);
    ASSERT_EQ(snap.system.perCpuUser.size(), 1u);
    EXPECT_DOUBLE_EQ(snap.system.perCpuUser[0], 0.3); // AM71: the kernel's split per processor (user mode)
    EXPECT_LT(first.system.perCpuUser.at(0), 0);

    // Without the processes (the Dock's graph while the window is hidden), the kernel's split stays.
    f.write("proc/stat", "cpu  1600 0 1200 9200 0 0 0 0 0 0\ncpu0 1600 0 1200 9200 0 0 0 0 0 0\n");
    const Snapshot hidden = s.sample(ReadSystemCpu, 21.0);
    EXPECT_FALSE(hidden.system.sharesByOwner);
    EXPECT_DOUBLE_EQ(hidden.system.userShare, 0.3);
    EXPECT_DOUBLE_EQ(hidden.system.systemShare, 0.1);
    EXPECT_TRUE(hidden.rows.empty());
    EXPECT_EQ(hidden.counters.statReads, 0u);
}

TEST(Sampler, TheUserShareIsNeverAboveTheBusyShare)
{
    // The user's processes' ticks and /proc/stat's are read a moment apart: their ratio can pass what /proc/stat counted
    // busy. User is capped there, System at 0 (AM29).
    Fixture f;
    f.process(100, "mine", kMe, 100, 1, nul({"mine"}), "/");
    f.write("proc/stat", "cpu  1000 0 1000 8000 0 0 0 0 0 0\ncpu0 1000 0 1000 8000 0 0 0 0 0 0\n");
    Sampler s(options(f));
    const unsigned reads = ReadProcesses | ReadStatus | ReadSystemCpu;
    s.sample(reads, 1.0);
    f.write("proc/stat", "cpu  1100 0 1000 8900 0 0 0 0 0 0\ncpu0 1100 0 1000 8900 0 0 0 0 0 0\n"); // 100 busy of 1000
    f.write("proc/100/stat", Fixture::statLine(100, "mine", 'S', 1, 0, 250, 0, 1, 1));       // 150 of the user's
    const Snapshot snap = s.sample(reads, 11.0);
    ASSERT_TRUE(snap.system.sharesByOwner);
    EXPECT_DOUBLE_EQ(snap.system.userShare, 0.1);
    EXPECT_DOUBLE_EQ(snap.system.systemShare, 0.0);
}

TEST(Sampler, TheClockTickIsTheMachines)
{
    Fixture f;
    f.process(100, "busy", kMe, 0, 1, nul({"busy"}), "/");
    Options o = options(f);
    o.clockTicks = 250;
    Sampler s(o);
    s.sample(ReadProcesses, 1.0);
    f.write("proc/100/stat", Fixture::statLine(100, "busy", 'R', 1, 0, 250, 0, 1, 1));
    EXPECT_DOUBLE_EQ(row(s.sample(ReadProcesses, 3.0), 100)->cpuPercent, 50.0); // 250 ticks in 2 s at 250 a second
}

TEST(Sampler, MemoryColumnsFromStatus)
{
    Fixture f;
    f.process(100, "m", kMe, 0, 1, nul({"m"}), "/");
    f.write("proc/100/status", Fixture::statusText("m", kMe, 3000, 700)); // RssAnon 3000, VmSwap 700, RssFile 4000, RssShmem 1000 kB
    Sampler s(options(f));
    const ProcessRow r = *row(s.sample(ReadProcesses | ReadStatus, 1.0), 100);
    EXPECT_EQ(r.memory, (3000u + 700u) * 1024);      // AM30: RssAnon + VmSwap
    EXPECT_EQ(r.privateMemory, 3000u * 1024);        // AM31: RssAnon
    EXPECT_EQ(r.sharedMemory, (4000u + 1000u) * 1024); // AM31: RssFile + RssShmem
    EXPECT_EQ(r.swapped, 700u * 1024);
    EXPECT_EQ(r.realMemory, (3000u + 5000u) * 1024); // VmRSS
}

TEST(Sampler, TheMemoryTabReadsStatmAndStatusInTurns)
{
    // AD32: statm every sample (resident - shared = RssAnon), VmSwap and VmHWM from status, a fifth of the processes per
    // sample and every new one at once.
    Fixture f;
    for (int pid = 100; pid < 110; ++pid) {
        f.process(pid, "m", kMe, 0, 1, nul({"m"}), "/");
        f.write("proc/" + std::to_string(pid) + "/status", Fixture::statusText("m", kMe, 3000, 700));
        f.write("proc/" + std::to_string(pid) + "/statm", "50000 2000 750 10 0 900 0\n"); // pages
    }
    Options o = options(f);
    o.pageSize = 4096;
    Sampler s(o);
    const unsigned reads = readsForTab(Tab::Memory);
    const Snapshot first = s.sample(reads, 1.0);
    EXPECT_EQ(first.counters.statusReads, 10u);
    EXPECT_EQ(first.counters.statmReads, 10u);
    const ProcessRow r = *row(first, 100);
    ASSERT_TRUE(r.hasMemory);
    EXPECT_EQ(r.realMemory, 2000u * 4096);
    EXPECT_EQ(r.sharedMemory, 750u * 4096);
    EXPECT_EQ(r.privateMemory, 1250u * 4096);
    EXPECT_EQ(r.swapped, 700u * 1024);
    EXPECT_EQ(r.memory, 1250u * 4096 + 700u * 1024); // AM30: RssAnon + VmSwap
    EXPECT_EQ(r.peakMemory, 9000u * 1024);           // VmHWM, never below the resident set read since
    EXPECT_EQ(r.virtualMemory, 50000u * 4096);
    for (int i = 2; i <= 6; ++i) {
        const Snapshot snap = s.sample(reads, static_cast<double>(i));
        EXPECT_EQ(snap.counters.statusReads, 2u) << i; // a fifth of the ten
        EXPECT_EQ(snap.counters.statmReads, 10u) << i;
    }
    // Swap grows: seen at the process's next status turn, within five samples.
    for (int pid = 100; pid < 110; ++pid)
        f.write("proc/" + std::to_string(pid) + "/status", Fixture::statusText("m", kMe, 3000, 900));
    for (int i = 7; i <= 11; ++i)
        s.sample(reads, static_cast<double>(i));
    for (const ProcessRow &x : s.sample(reads, 12.0).rows)
        EXPECT_EQ(x.swapped, 900u * 1024) << x.pid;
}

// Review of 19f5d4c: a full read left the measured interval at 0, so a pause right after it (the window hidden after one
// Memory sample) went unseen. A pause is told by the interval set (AM9).
TEST(Sampler, APauseRightAfterTheFirstMemorySampleIsSeen)
{
    Fixture f;
    for (int pid = 100; pid < 110; ++pid) {
        f.process(pid, "m", kMe, 0, 1, nul({"m"}), "/");
        f.write("proc/" + std::to_string(pid) + "/statm", "50000 2000 750 10 0 900 0\n");
    }
    auto swap = [&](unsigned long kb) {
        for (int pid = 100; pid < 110; ++pid)
            f.write("proc/" + std::to_string(pid) + "/status", Fixture::statusText("m", kMe, 3000, kb));
    };
    swap(0);
    Sampler s(options(f)); // Normally (5 sec)
    const unsigned memory = readsForTab(Tab::Memory);
    EXPECT_EQ(s.sample(memory, 5.0).counters.statusReads, 10u); // the first: every process
    swap(4000);
    const Snapshot back = s.sample(memory, 3605.0); // an hour hidden
    EXPECT_EQ(back.counters.statusReads, 10u);
    for (const ProcessRow &r : back.rows)
        EXPECT_EQ(r.swapped, 4000u * 1024) << r.pid;
    EXPECT_EQ(s.sample(memory, 3610.0).counters.statusReads, 2u); // one interval: the turns
    EXPECT_EQ(s.sample(memory, 3618.0).counters.statusReads, 2u); // under two intervals: still the turns
    s.setInterval(1); // Very Often (1 sec)
    EXPECT_EQ(s.sample(memory, 3621.0).counters.statusReads, 10u); // three seconds: more than two intervals
}

TEST(Sampler, TheMemoryTabReadsEveryStatusAfterAnotherTabOrAPause)
{
    // Review of f68789c: back on the Memory tab after an hour on another, four fifths of the rows showed the old swap.
    Fixture f;
    for (int pid = 100; pid < 110; ++pid) {
        f.process(pid, "m", kMe, 0, 1, nul({"m"}), "/");
        f.write("proc/" + std::to_string(pid) + "/statm", "50000 2000 750 10 0 900 0\n");
    }
    auto swap = [&](unsigned long kb) {
        for (int pid = 100; pid < 110; ++pid)
            f.write("proc/" + std::to_string(pid) + "/status", Fixture::statusText("m", kMe, 3000, kb));
    };
    swap(0);
    Sampler s(options(f));
    const unsigned memory = readsForTab(Tab::Memory);
    for (int i = 1; i <= 3; ++i)
        s.sample(memory, static_cast<double>(i));
    swap(4000);
    for (int i = 1; i <= 7; ++i)
        s.sample(ReadProcesses, 3.0 + 0.1 * i); // another tab, briefly: no pause to tell it by
    const Snapshot back = s.sample(memory, 4.0);
    EXPECT_EQ(back.counters.statusReads, 10u); // every process once
    for (const ProcessRow &r : back.rows)
        EXPECT_EQ(r.swapped, 4000u * 1024) << r.pid;
    EXPECT_EQ(s.sample(memory, 5.0).counters.statusReads, 2u); // then the turns again
    swap(8000);
    const Snapshot later = s.sample(memory, 100.0); // the window was hidden: a pause of many intervals
    EXPECT_EQ(later.counters.statusReads, 10u);
    for (const ProcessRow &r : later.rows)
        EXPECT_EQ(r.swapped, 8000u * 1024) << r.pid;
}

TEST(Sampler, ThePeakIsNeverBelowTheResidentSet)
{
    Fixture f;
    f.process(100, "m", kMe, 0, 1, nul({"m"}), "/"); // status: VmHWM 7000 kB
    f.write("proc/100/statm", "50000 5000 750 10 0 900 0\n"); // resident 5000 pages, 20000 kB: grown since status was read
    Sampler s(options(f));
    const ProcessRow r = *row(s.sample(readsForTab(Tab::Memory), 1.0), 100);
    EXPECT_EQ(r.realMemory, 5000u * 4096);
    EXPECT_EQ(r.peakMemory, 5000u * 4096);
}

TEST(Sampler, AProcessThatRenamesItselfKeepsItsName)
{
    // prctl(PR_SET_NAME) changes stat's name without an exec: the user's own process keeps its name and command, as on
    // macOS (review of f68789c: python3 became python3.13).
    Fixture f;
    f.process(100, "python3", kMe, 1, 5000, nul({"/usr/bin/python3", "tool.py"}), "/");
    f.write("proc/100/stat", Fixture::statLine(100, "python3", 'S', 1, 0, 1, 0, 1, 5000, 0, 0x55550000));
    f.link("/usr/bin/python3.13", "proc/100/exe");
    Sampler s(options(f));
    const unsigned reads = ReadProcesses | ReadStatus | ReadCommand;
    EXPECT_EQ(row(s.sample(reads, 1.0), 100)->name, "python3");
    f.write("proc/100/stat", Fixture::statLine(100, "worker", 'S', 1, 0, 1, 0, 1, 5000, 0, 0x55550000));
    const Snapshot snap = s.sample(reads, 2.0);
    EXPECT_EQ(row(snap, 100)->name, "python3");
    EXPECT_EQ(snap.counters.cmdlineReads, 0u);
}

TEST(Sampler, AnExecIsSeenByItsCodeEndAlone)
{
    // A non-position-independent executable loads at the same address: another one is told by where its code ends.
    Fixture f;
    f.process(100, "app", kMe, 1, 5000, nul({"/opt/a/app"}), "/");
    f.write("proc/100/stat", Fixture::statLine(100, "app", 'S', 1, 0, 1, 0, 1, 5000, 0, 0x400000, 0x480000));
    Sampler s(options(f));
    const unsigned reads = ReadProcesses | ReadStatus | ReadCommand;
    s.sample(reads, 1.0);
    f.write("proc/100/stat", Fixture::statLine(100, "app", 'S', 1, 0, 1, 0, 1, 5000, 0, 0x400000, 0x4a0000));
    f.write("proc/100/cmdline", nul({"/opt/b/app", "--b"}));
    EXPECT_EQ(row(s.sample(reads, 2.0), 100)->command, "/opt/b/app --b");
}

namespace
{
bool rootOwnsPid100(int dir, const char *name, uint32_t &uid)
{
    struct stat st{};
    if (fstatat(dir, name, &st, 0) != 0)
        return false;
    uid = std::string(name) == "100" ? 0 : static_cast<uint32_t>(st.st_uid);
    return true;
}
} // namespace

TEST(Sampler, TheRealUidBehindARootDirectoryIsReadAgainInItsTurn)
{
    // A non-dumpable process's directory is root's: its owner is status's real uid, which can change without an exec
    // (setuid). Read again in the owner's turn (review of f68789c, mutant N10).
    Fixture f;
    f.process(100, "agent", kMe, 0, 1, nul({"agent"}), "/");
    Options o = options(f);
    o.dirOwner = rootOwnsPid100;
    o.descriptorTurns = 1; // every sample is the owner's turn
    Sampler s(o);
    EXPECT_TRUE(row(s.sample(ReadProcesses, 1.0), 100)->own);
    f.write("proc/100/status", Fixture::statusText("agent", 1001, 1000, 0));
    const ProcessRow r = *row(s.sample(ReadProcesses, 2.0), 100);
    EXPECT_FALSE(r.own);
    EXPECT_EQ(r.uid, 1001u);
}

TEST(Sampler, ACounterThatWentBackGivesNoRate)
{
    Fixture f;
    f.process(100, "w", kMe, 0, 1, nul({"w"}), "/");
    f.write("proc/100/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: 5000\nwrite_bytes: 5000\ncancelled_write_bytes: 0\n");
    Sampler s(options(f));
    s.sample(ReadProcesses | ReadStatus | ReadIo, 1.0);
    f.write("proc/100/io", "rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: 1000\nwrite_bytes: 6000\ncancelled_write_bytes: 0\n");
    const ProcessRow r = *row(s.sample(ReadProcesses | ReadStatus | ReadIo, 2.0), 100);
    EXPECT_LT(r.readRate, 0); // "—", not a wrapped number
    EXPECT_DOUBLE_EQ(r.writeRate, 1000.0);
}

namespace
{
std::vector<TcpCounters> fakeTcp;
bool fakeTcpOk = true;
bool fakeDump(std::vector<TcpCounters> &out)
{
    if (!fakeTcpOk)
        return false;
    out = fakeTcp;
    return true;
}
} // namespace

TEST(Sampler, AFailedTcpDumpChangesNoTotal)
{
    // One failed dump (EMFILE) read as "every socket closed" doubled the totals once the sockets came back (review of
    // 949fc98): 100001 became 200002.
    Fixture f;
    f.process(100, "net", kMe, 0, 1, nul({"net"}), "/");
    f.link("socket:[4242]", "proc/100/fd/3");
    Options o = options(f);
    o.descriptorTurns = 1;
    o.tcpDump = fakeDump;
    fakeTcp = {TcpCounters{4242, kMe, 100001, 50, 10, 5}};
    fakeTcpOk = true;
    Sampler s(o);
    const unsigned reads = ReadProcesses | ReadStatus | ReadDescriptors | ReadSockets;
    EXPECT_EQ(row(s.sample(reads, 1.0), 100)->tcpSent, 100001u);
    fakeTcpOk = false;
    EXPECT_EQ(row(s.sample(reads, 2.0), 100)->tcpSent, 100001u);
    fakeTcpOk = true;
    EXPECT_EQ(row(s.sample(reads, 3.0), 100)->tcpSent, 100001u);
    fakeTcp.clear(); // the socket closed: its bytes stay with the process (AM43)
    EXPECT_EQ(row(s.sample(reads, 4.0), 100)->tcpSent, 100001u);
}

TEST(Sampler, ASocketCountsForTheProcessThatHoldsIt)
{
    // Audit A7: a socket was only let go when it left the dump, never when it left the process's own descriptors: a socket
    // handed to another process kept counting for the first one, and one inherited across a fork counted in both.
    Fixture f;
    f.process(100, "parent", kMe, 0, 1, nul({"parent"}), "/");
    f.process(101, "child", kMe, 0, 100, nul({"child"}), "/");
    f.link("socket:[4242]", "proc/100/fd/3");
    f.link("socket:[4242]", "proc/101/fd/3"); // inherited: both hold it
    Options o = options(f);
    o.descriptorTurns = 1;
    o.tcpDump = fakeDump;
    fakeTcpOk = true;
    fakeTcp = {TcpCounters{4242, kMe, 1000, 50, 10, 5}};
    Sampler s(o);
    const unsigned reads = ReadProcesses | ReadStatus | ReadDescriptors | ReadSockets;
    Snapshot snap = s.sample(reads, 1.0);
    EXPECT_EQ(row(snap, 100)->tcpSent + row(snap, 101)->tcpSent, 1000u) << "counted once";
    EXPECT_EQ(row(snap, 100)->tcpSent, 1000u) << "for the first holder";

    // The parent closes its copy; the child keeps the socket and sends 500 more: the parent keeps its 1000, the child
    // counts the 500 from the hand-over.
    std::filesystem::remove(f.proc() + "/100/fd/3");
    fakeTcp = {TcpCounters{4242, kMe, 1500, 60, 12, 6}};
    snap = s.sample(reads, 2.0);
    EXPECT_EQ(row(snap, 100)->tcpSent, 1000u);
    EXPECT_EQ(row(snap, 101)->tcpSent, 500u);
    EXPECT_EQ(row(snap, 101)->tcpReceived, 10u);

    // The child closes it: each keeps its share.
    fakeTcp.clear();
    snap = s.sample(reads, 3.0);
    EXPECT_EQ(row(snap, 100)->tcpSent, 1000u);
    EXPECT_EQ(row(snap, 101)->tcpSent, 500u);
}

TEST(Sampler, AFailedListingWipesNothing)
{
    Fixture f;
    f.process(100, "a", kMe, 0, 1, nul({"a"}), "/");
    Sampler s(options(f));
    s.sample(ReadProcesses | ReadStatus, 1.0);
    std::filesystem::rename(f.proc(), f.proc() + "-gone"); // /proc cannot be listed
    const Snapshot stale = s.sample(ReadProcesses | ReadStatus, 2.0);
    EXPECT_TRUE(stale.processesStale);
    ASSERT_EQ(stale.rows.size(), 1u); // the previous sample's rows
    EXPECT_EQ(stale.rows[0].name, "a");
    std::filesystem::rename(f.proc() + "-gone", f.proc());
    f.write("proc/100/stat", Fixture::statLine(100, "a", 'R', 1, 0, 100, 0, 1, 1));
    const Snapshot back = s.sample(ReadProcesses | ReadStatus, 3.0);
    EXPECT_FALSE(back.processesStale);
    EXPECT_DOUBLE_EQ(row(back, 100)->cpuPercent, 50.0); // its state was kept: a rate over the 2 s since the last good read
}

TEST(Sampler, WholePhysicalDisksAndInterfacesButLo)
{
    Fixture f;
    f.link("../../../devices/pci0000:00/nvme0", "sys/block/nvme0n1/device"); // a link, as sysfs has it (dangling here)
    f.write("sys/block/loop0/size", "0\n"); // no device link: not counted (AM42)
    f.write("proc/diskstats", " 259 0 nvme0n1 100 0 2000 50 200 0 4000 100 0 300 150 0 0 0 0\n"
                              " 259 1 nvme0n1p1 100 0 2000 50 200 0 4000 100 0 300 150 0 0 0 0\n"
                              "   7 0 loop0 999 0 999 0 0 0 0 0 0 0 0 0 0 0 0\n");
    f.write("proc/net/dev", "Inter-| Receive | Transmit\n face |bytes packets\n    lo: 500 5 0 0 0 0 0 0 500 5 0 0 0 0 0 0\n"
                            " wlan0: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0\n");
    Sampler s(options(f));
    const unsigned reads = ReadSystemDisk | ReadSystemNet;
    s.sample(reads, 1.0);
    f.write("proc/diskstats", " 259 0 nvme0n1 300 0 6000 150 400 0 8000 300 0 1300 450 0 0 0 0\n"
                              " 259 1 nvme0n1p1 300 0 6000 150 400 0 8000 300 0 1300 450 0 0 0 0\n"
                              "   7 0 loop0 999 0 999 0 0 0 0 0 0 0 0 0 0 0 0\n");
    f.write("proc/net/dev", "Inter-| Receive | Transmit\n face |bytes packets\n    lo: 900 9 0 0 0 0 0 0 900 9 0 0 0 0 0 0\n"
                            " wlan0: 3000 30 0 0 0 0 0 0 2500 25 0 0 0 0 0 0\n");
    const Snapshot snap = s.sample(reads, 3.0);
    ASSERT_EQ(snap.system.disks.size(), 1u);
    const DiskSnapshot &d = snap.system.disks[0];
    EXPECT_EQ(d.name, "nvme0n1");
    EXPECT_EQ(d.reads, 300u);
    EXPECT_EQ(d.bytesRead, 6000u * 512);
    EXPECT_DOUBLE_EQ(d.readsPerSec, 100.0);
    EXPECT_DOUBLE_EQ(d.writesPerSec, 100.0);
    EXPECT_DOUBLE_EQ(d.readBytesPerSec, 2000.0 * 512);
    EXPECT_DOUBLE_EQ(d.activeTime, 0.5);   // 1000 ms of I/O in 2 s
    EXPECT_DOUBLE_EQ(d.responseMs, 300.0 / 400.0); // (100 + 200) ms over 400 requests
    EXPECT_EQ(snap.system.diskTotal.reads, 300u);
    ASSERT_EQ(snap.system.interfaces.size(), 1u);
    EXPECT_EQ(snap.system.interfaces[0].name, "wlan0");
    EXPECT_EQ(snap.system.netTotal.packetsIn, 30u);
    EXPECT_DOUBLE_EQ(snap.system.netTotal.bytesInPerSec, 1000.0);
    EXPECT_DOUBLE_EQ(snap.system.netTotal.packetsOutPerSec, 2.5);
    // Audit A8: an interface new since the last sample has no rate yet; the total keeps the others' (no gap in the graph).
    f.write("proc/net/dev", "Inter-| Receive | Transmit\n face |bytes packets\n    lo: 900 9 0 0 0 0 0 0 900 9 0 0 0 0 0 0\n"
                            " wlan0: 4000 40 0 0 0 0 0 0 2500 25 0 0 0 0 0 0\n"
                            " veth0: 7000 70 0 0 0 0 0 0 7000 70 0 0 0 0 0 0\n");
    const Snapshot more = s.sample(reads, 4.0);
    ASSERT_EQ(more.system.interfaces.size(), 2u);
    EXPECT_DOUBLE_EQ(more.system.netTotal.bytesInPerSec, 1000.0);
}

TEST(Sampler, TheSpeedIsReadOnlyWhenAsked)
{
    // Audit A3: the processors' current speed was read by the window at each sample; the sampler reads it when asked.
    Fixture f;
    f.write("sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "2000000\n");
    f.write("sys/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq", "3000000\n");
    f.write("proc/uptime", "100.5 1.0\n");
    Sampler s(options(f));
    const Snapshot without = s.sample(ReadSystemCpu, 1.0);
    EXPECT_LT(without.system.speedGhz, 0);
    EXPECT_LT(without.system.uptime, 0);
    const Snapshot with = s.sample(ReadSystemCpu | ReadSystemSpeed, 2.0);
    EXPECT_DOUBLE_EQ(with.system.speedGhz, 2.5);
    EXPECT_DOUBLE_EQ(with.system.uptime, 100.5);
}

TEST(Sampler, TotalsKeepTheCountersOfDevicesThatWent)
{
    // Audit A8 (round 2): "Data read", "Packets in" and the other totals were sums over the devices there now, so they went
    // back when a USB disk, a VPN or a container's veth went away. The last counters of a gone device stay in them, and so
    // do those of a device that restarted from zero.
    Fixture f;
    f.link("../../../devices/pci0000:00/nvme0", "sys/block/nvme0n1/device");
    f.link("../../../devices/usb1/sdb", "sys/block/sdb/device");
    const auto disks = [&f](const std::string &text) { f.write("proc/diskstats", text); };
    const auto net = [&f](const std::string &text) {
        f.write("proc/net/dev", "Inter-| Receive | Transmit\n face |bytes packets\n" + text);
    };
    disks(" 259 0 nvme0n1 100 0 2000 0 200 0 4000 0 0 0 0 0 0 0 0\n   8 16 sdb 50 0 1000 0 10 0 100 0 0 0 0 0 0 0 0\n");
    net(" wlan0: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0\n  tun0: 500 5 0 0 0 0 0 0 600 6 0 0 0 0 0 0\n");
    Sampler s(options(f));
    const unsigned reads = ReadSystemDisk | ReadSystemNet;
    const Snapshot first = s.sample(reads, 1.0);
    EXPECT_EQ(first.system.diskTotal.reads, 150u);
    EXPECT_EQ(first.system.netTotal.bytesIn, 1500u);

    // The USB disk and the VPN go.
    disks(" 259 0 nvme0n1 110 0 2200 0 200 0 4000 0 0 0 0 0 0 0 0\n");
    net(" wlan0: 1100 11 0 0 0 0 0 0 2000 20 0 0 0 0 0 0\n");
    const Snapshot gone = s.sample(reads, 2.0);
    EXPECT_EQ(gone.system.diskTotal.reads, 160u);
    EXPECT_EQ(gone.system.diskTotal.bytesRead, (2200u + 1000u) * 512);
    EXPECT_EQ(gone.system.diskTotal.writes, 210u);
    EXPECT_EQ(gone.system.netTotal.bytesIn, 1600u);
    EXPECT_EQ(gone.system.netTotal.packetsOut, 26u);
    EXPECT_DOUBLE_EQ(gone.system.netTotal.bytesInPerSec, 100.0) << "the rate is the devices' there now";

    // The VPN comes back from zero, and the Wi-Fi restarted (its counters went back): nothing goes back in the totals.
    net(" wlan0: 30 1 0 0 0 0 0 0 40 1 0 0 0 0 0 0\n  tun0: 7 1 0 0 0 0 0 0 9 1 0 0 0 0 0 0\n");
    const Snapshot back = s.sample(reads, 3.0);
    EXPECT_EQ(back.system.netTotal.bytesIn, 1100u + 500u + 30u + 7u);
    EXPECT_GE(back.system.netTotal.packetsIn, gone.system.netTotal.packetsIn);
}

TEST(Sampler, AWindowOwnerIsAnApp)
{
    Fixture f;
    f.process(100, "zed", kMe, 1, 1, nul({"zed"}), user + "/app.slice/zed.service");
    Sampler s(options(f));
    EXPECT_EQ(s.sample(ReadProcesses | ReadStatus, 1.0).rows[0].kind, Kind::Background);
    s.setWindowOwners({100});
    EXPECT_EQ(s.sample(ReadProcesses | ReadStatus, 2.0).rows[0].kind, Kind::App);
}

TEST(Sampler, TheRealProcIsReadable)
{
    // This test's own process, through the real /proc: its row, its owner, a sane CPU share.
    Options o = defaultOptions();
    Sampler s(o);
    s.sample(ReadProcesses | ReadStatus | ReadIo | ReadSystemCpu | ReadSystemMemory);
    volatile double x = 0;
    for (int i = 0; i < 2000000; ++i)
        x += i * 0.5;
    EXPECT_GT(x, 0.0);
    const Snapshot snap = s.sample(ReadProcesses | ReadStatus | ReadIo | ReadSystemCpu | ReadSystemMemory);
    const ProcessRow *me = row(snap, getpid());
    ASSERT_NE(me, nullptr);
    EXPECT_TRUE(me->own);
    EXPECT_TRUE(me->hasMemory);
    EXPECT_GT(me->realMemory, 0u);
    EXPECT_TRUE(me->hasIo);
    EXPECT_GE(me->cpuPercent, 0.0);
    EXPECT_TRUE(snap.system.memory.ok);
    EXPECT_GT(snap.system.processes, 0);
    EXPECT_GE(snap.cpuMs, 0.0);
}

// Review of PR #53: the code-address flag is part of the line cache.
TEST(Sampler, TheCodeAddressFlagIsPartOfTheCache)
{
    // A directory owned by root (a non-dumpable process): its stat is read without code addresses after the first sample.
    Fixture f;
    f.process(100, "agent", kMe, 1, 5000, nul({"agent"}), "/");
    f.write("proc/100/stat", Fixture::statLine(100, "agent", 'S', 1, 0, 1, 0, 1, 5000, 0, 4096, 8192));
    Options o = options(f);
    o.dirOwner = rootOwnsPid100;
    Sampler s(o);
    EXPECT_EQ(s.sample(ReadProcesses, 1.0).counters.statParses, 1u); // new: with its code addresses
    EXPECT_EQ(s.sample(ReadProcesses, 2.0).counters.statParses, 1u); // the same line, read without them now
    EXPECT_EQ(s.sample(ReadProcesses, 3.0).counters.statParses, 0u);
}

// AM65, AM68: an own process in a launch's unit has the unit's number (the same for the unit's processes, another for another
// launch, 0 outside such a unit); ReadEfficiency reads each eligible unit's cgroup once: cpu.idle 1 (CPUWeight=idle) or a
// cpu.weight of 1 is Efficiency Mode, whoever set it; nothing is read without the flag, or for a unit it does not apply to.
TEST(Sampler, AppUnitsAndTheirEfficiencyMode)
{
    Fixture f;
    const std::string slice = user + "/app.slice/app-graphical.slice/";
    f.process(100, "foot", kMe, 10, 5000, nul({"/usr/bin/foot"}), slice + "app-Hyprland-foot-1a2b3c4d.scope");
    f.process(101, "foot-helper", kMe, 10, 5001, nul({"/usr/bin/foot"}), slice + "app-Hyprland-foot-1a2b3c4d.scope");
    f.process(200, "foot", kMe, 10, 5002, nul({"/usr/bin/foot"}), slice + "app-Hyprland-foot-99aa88bb.scope");
    f.process(300, "mpv", kMe, 10, 5003, nul({"/usr/bin/mpv"}), slice + "app-Hyprland-mpv\\x2dplayer@0011aabb.service");
    f.process(400, "pipewire", kMe, 10, 5004, nul({"/usr/bin/pipewire"}), user + "/app.slice/pipewire.service");
    const std::string cg = "sys/fs/cgroup" + slice;
    f.write(cg + "app-Hyprland-foot-1a2b3c4d.scope/cpu.idle", "1\n");
    f.write(cg + "app-Hyprland-foot-99aa88bb.scope/cpu.idle", "0\n");
    f.write(cg + "app-Hyprland-foot-99aa88bb.scope/cpu.weight", "100\n");
    f.write(cg + "app-Hyprland-mpv\\x2dplayer@0011aabb.service/cpu.weight", "1\n");
    f.write("sys/fs/cgroup" + user + "/app.slice/pipewire.service/cpu.weight", "1\n");
    Sampler s(options(f));
    Snapshot snap = s.sample(ReadProcesses, 10.0);
    EXPECT_NE(row(snap, 100)->unitKey, 0u);
    EXPECT_EQ(row(snap, 100)->unitKey, row(snap, 101)->unitKey);
    EXPECT_NE(row(snap, 100)->unitKey, row(snap, 200)->unitKey);
    EXPECT_NE(row(snap, 300)->unitKey, 0u);
    EXPECT_EQ(row(snap, 300)->appId, "mpv-player");
    EXPECT_EQ(row(snap, 400)->unitKey, 0u);
    EXPECT_EQ(snap.counters.weightReads, 0u);
    EXPECT_FALSE(row(snap, 100)->efficient);

    snap = s.sample(ReadProcesses | ReadEfficiency, 12.0);
    EXPECT_TRUE(row(snap, 100)->efficient);
    EXPECT_TRUE(row(snap, 101)->efficient); // the whole unit
    EXPECT_FALSE(row(snap, 200)->efficient);
    EXPECT_TRUE(row(snap, 300)->efficient);
    EXPECT_FALSE(row(snap, 400)->efficient); // not an app unit (AM68): never read
    // foot's first unit: cpu.idle; its second: cpu.idle then cpu.weight; mpv's: no cpu.idle, then cpu.weight.
    EXPECT_EQ(snap.counters.weightReads, 5u);

    f.write(cg + "app-Hyprland-foot-1a2b3c4d.scope/cpu.idle", "0\n"); // turned off elsewhere
    snap = s.sample(ReadProcesses | ReadEfficiency, 14.0);
    EXPECT_FALSE(row(snap, 100)->efficient);
}
