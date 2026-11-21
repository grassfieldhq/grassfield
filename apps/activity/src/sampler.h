// The activity monitor's sampler (ADR-0038 b, c, d; docs/specs/activity.md AM20 to AM49, AM79): one sample reads the
// kernel's /proc and /sys files the tab shows and turns them into rows and summaries. Plain C++17 and POSIX, no Qt: it runs
// on a thread of its own in the app (step 2) and in `activity-sampler-bench` (tests/apps/activity_cost.sh). Every read it
// makes is counted, so the cost gates (AM-P2) can say which one went over.
//
// What it never does: read another owner's io, descriptors, command line or memory map; read environment variables; write
// anything; signal anything (step 2's actions live elsewhere).
#pragma once

#include "netdiag.h"
#include "procparse.h"
#include "units.h"

#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace activity
{

// What one sample reads (ADR-0038 d). The tabs combine them (readsForTab).
enum Read : unsigned {
    ReadProcesses = 1u << 0,   // the /proc listing and stat of every process
    ReadStatus = 1u << 1,      // status of every process (Memory tab; the real uid of every row)
    ReadIo = 1u << 2,          // io of own processes (Disk, Energy)
    ReadThreads = 1u << 3,     // the threads' status of one fifth of the own processes, in turn (Wake Ups)
    ReadDescriptors = 1u << 4, // the fd lists of one tenth of the own processes, in turn (sockets, GPU clients)
    ReadGpu = 1u << 5,         // fdinfo of the DRM descriptors found
    ReadSockets = 1u << 6,     // one TCP sock_diag dump
    ReadCommand = 1u << 7,     // the whole command line of own processes (the Command column)
    ReadSystemCpu = 1u << 8,   // /proc/stat, /proc/loadavg
    ReadSystemMemory = 1u << 9, // /proc/meminfo, /proc/pressure/memory, /proc/swaps, zram's mm_stat
    ReadSystemDisk = 1u << 10, // /proc/diskstats
    ReadSystemNet = 1u << 11,  // /proc/net/dev
    ReadMemory = 1u << 12,     // statm of every process, status of one fifth of them in turn (Memory tab, AD32)
    ReadEfficiency = 1u << 13, // AM68: cpu.idle and cpu.weight of each own app unit once (the window shown)
    ReadSystemSpeed = 1u << 14, // the processors' current speed (scaling_cur_freq) and the uptime (Performance on CPU, A3)
};

// The most bytes of a command line a table row keeps (the Command column and its search); Inspect shows the whole line.
inline constexpr size_t kCommandMax = 4096;

enum class Tab { Cpu, Memory, Energy, Disk, Network };

unsigned readsForTab(Tab tab);

struct Options {
    std::string procRoot = "/proc";
    std::string sysRoot = "/sys";
    uint32_t uid = 0;             // the app's uid (getuid() by default, see defaultOptions)
    uint32_t uidMin = 1000;       // UID_MIN of /etc/login.defs
    long clockTicks = 100;        // sysconf(_SC_CLK_TCK)
    size_t maxKeptFiles = 0;      // kept /proc descriptors at most (0 keeps none; defaultOptions sets it from RLIMIT_NOFILE)
    long pageSize = 4096;         // sysconf(_SC_PAGESIZE): statm counts pages
    int threadTurns = 5;          // AM23
    int statusTurns = 5;          // AM30, AD32: VmSwap and VmHWM from status, one fifth of the processes per sample
    int descriptorTurns = 10;     // AM43, AM45
    double interval = 5;          // AM9's Update Frequency in seconds (Normally by default); the window sets it
    // The TCP dump (AM43); tests put a function of their own here (a failed dump, the review of 949fc98).
    bool (*tcpDump)(std::vector<TcpCounters> &out) = dumpTcpSockets;
    // The owner of /proc/<name> under the directory `dir` (fstatat when null); tests give a root-owned directory here.
    bool (*dirOwner)(int dir, const char *name, uint32_t &uid) = nullptr;
    // hwdata's PCI names (AM47): a GPU's name; read once per GPU, "" reads none.
    std::string pciIds = "/usr/share/hwdata/pci.ids";
};

// Options for this machine: getuid(), /etc/login.defs, the clock tick, and a kept-descriptor budget from the soft
// RLIMIT_NOFILE minus a reserve of 256 for everything else the app opens.
Options defaultOptions();

// Raises the soft RLIMIT_NOFILE to the hard limit (at most 16384), so the kept /proc descriptors (about two per process)
// fit: the session's soft limit is 1024 (ADR-0038 d, spec AM-P2). Call it before defaultOptions(). Returns the soft limit in
// force afterwards.
size_t raiseFileLimit();

// Energy Impact (AM36, owner AQ3): %CPU + %GPU + 0.02 × wake-ups/s + 1.0 × disk MB/s (read and written, decimal MB), the
// provisional weights of the spec; an unknown term (-1) counts as 0.
double energyImpact(double cpuPercent, double gpuPercent, double wakeRate, double readRate, double writeRate);

// Memory pressure level (AM33).
enum class PressureLevel { Normal, Warning, Critical };

PressureLevel pressureLevel(const Meminfo &m, const Pressure &p);

// A row's numbers and flags: a plain value, so a row of the last sample is reset in one copy (2b, the Disk tab's cost).
struct ProcessValues {
    int pid = 0;
    uint64_t start = 0;  // stat field 22: with the pid, the row's identity
    int ppid = 0;
    int pgrp = 0;
    uint32_t uid = 0;
    bool own = false;
    bool systemAccount = false;
    char state = '?';
    long nice = 0;
    int threads = 0;
    // No cgroup path: another owner's is never read (AD25), and an action on one of the user's units reads it again at the
    // time of the action (step 4). What the table needs of it is below.
    Kind kind = Kind::Background;
    bool session = false;            // AM54
    bool efficiencyEligible = false; // AM68
    // AM65: the unit uwsm named for one launch (A7) as a number, the same for its processes, never 0; 0 outside such a unit.
    uint64_t unitKey = 0;
    // AM68: that unit's cpu.weight is the lowest (Efficiency Mode), read once per unit and sample (ReadEfficiency).
    bool efficient = false;
    // CPU (AM20 to AM22): ticks since start; the share of one core since the previous sample, -1 at the first.
    uint64_t cpuTicks = 0;
    double cpuPercent = -1;
    uint64_t minorFaults = 0, majorFaults = 0;
    // Memory (AM30, AM31), bytes, with ReadStatus.
    bool hasMemory = false;
    uint64_t memory = 0, realMemory = 0, privateMemory = 0, sharedMemory = 0, swapped = 0, peakMemory = 0, virtualMemory = 0;
    // Disk (AM41), own processes with ReadIo.
    bool hasIo = false;
    uint64_t bytesRead = 0, bytesWritten = 0;
    double readRate = -1, writeRate = -1;
    // Wake Ups (AM23): voluntary context switches per second over the process's last turn, -1 until known.
    double wakeRate = -1;
    // Descriptors (AM25): -1 until the process's descriptor list was read.
    int openFiles = -1;
    // GPU (AM45, AM46).
    bool hasGpu = false;
    uint64_t gpuNs = 0;
    double gpuPercent = -1;
    // Network (AM43): TCP only, since the app opened.
    bool hasNet = false;
    uint64_t tcpSent = 0, tcpReceived = 0, tcpSegsOut = 0, tcpSegsIn = 0;
    // Energy Impact (AM36, AM37): own processes on the Energy tab's reads, -1 until the CPU share is known and always for
    // another owner (its io and descriptors are refused, so its index would leave terms out). The average is weighted by
    // time over the samples that computed it.
    double energyImpact = -1, averageEnergyImpact = -1;
};

// One process of a sample: its values, then its texts.
struct ProcessRow : ProcessValues {
    std::string name;    // sanitized (AM17); refreshed after an exec
    std::string command; // own processes with ReadCommand, sanitized (AM28); "" otherwise
    // Own processes in a launch's unit (A7): its app, a desktop id without ".desktop" or a command's basename; the window
    // takes the app's icon from it (AM10, AM17). "" otherwise.
    std::string appId;
    std::vector<std::string> gpuDevices; // the GPUs it is a client of (drm-pdev, sorted), for Processes, by GPU (AM49)
};
// The sampler empties a row of the last sample to fill it again (recycle in sampler.cpp): a member added here is cleared
// there too.
static_assert(std::is_trivially_copyable_v<ProcessValues>);
static_assert(sizeof(ProcessRow) == sizeof(ProcessValues) + 3 * sizeof(std::string) + sizeof(std::vector<std::string>));

// Every kernel thread summed (AM20a, AD25).
struct KernelRow {
    int threads = 0;
    uint64_t cpuTicks = 0;
    double cpuPercent = -1;
};

struct MemorySummary {
    bool ok = false;
    uint64_t physical = 0, used = 0, app = 0, wired = 0, compressed = 0, cached = 0, swapUsed = 0; // bytes (AD7)
    bool swapIsZramOnly = true; // AM34: the Compressed Memory column keeps its name
    double inUse = 0;           // the Memory Pressure graph's height (AM33)
    PressureLevel level = PressureLevel::Normal;
    bool hasPressure = false;
    uint64_t committed = 0, commitLimit = 0, available = 0;
};

struct DiskSnapshot {
    std::string name;
    uint64_t reads = 0, writes = 0, bytesRead = 0, bytesWritten = 0;
    double readsPerSec = -1, writesPerSec = -1, readBytesPerSec = -1, writeBytesPerSec = -1;
    double activeTime = -1;      // fraction of the interval with I/O in flight
    double responseMs = -1;      // mean time per completed request in the interval
};

struct NetSnapshot {
    std::string name;
    uint64_t packetsIn = 0, packetsOut = 0, bytesIn = 0, bytesOut = 0;
    double packetsInPerSec = -1, packetsOutPerSec = -1, bytesInPerSec = -1, bytesOutPerSec = -1;
};

struct GpuEngine {
    std::string name;
    double percent = 0;
};

struct GpuDevice {
    std::string pdev;
    std::string driver;
    std::vector<GpuEngine> engines;
    uint64_t memoryBytes = 0;
    std::map<std::string, uint64_t> memoryRegions; // AM66: drm-memory-<region> summed over the clients, by region
    // AM47: the DRM card whose device is this pdev (/sys/class/drm/card<n>), -1 when none is; its name from pci.ids ("Intel
    // UHD Graphics"), "" when pci.ids does not name it.
    int card = -1;
    std::string model;
};

struct SystemSnapshot {
    bool cpuOk = false;
    double userShare = -1, systemShare = -1, idleShare = -1; // AM29, fractions of the whole machine
    bool sharesByOwner = false; // User and System as macOS means them (AD5), else the kernel's user/kernel split
    std::vector<double> perCpuBusy;                          // fractions, -1 at the first sample
    std::vector<double> perCpuUser;                          // AM71: the kernel's user-mode part of each (System is the rest)
    int tasks = -1;      // /proc/loadavg: every task, threads included
    int processes = 0;   // numeric entries of /proc
    MemorySummary memory;
    std::vector<DiskSnapshot> disks; // whole physical disks (AM42)
    DiskSnapshot diskTotal;
    std::vector<NetSnapshot> interfaces; // every interface but lo (AM44)
    NetSnapshot netTotal;
    double speedGhz = -1; // ReadSystemSpeed: the mean current speed of the processors, -1 when not read or unknown
    double uptime = -1;   // ReadSystemSpeed: seconds since boot
};

// What one sample read, for the cost gates (AM-P2) and the dev counters.
struct Counters {
    uint64_t listed = 0, statReads = 0, statusReads = 0, ioReads = 0, threadStatusReads = 0, fdListReads = 0, fdLinks = 0,
             fdinfoReads = 0, sockDumps = 0, cmdlineReads = 0, cgroupReads = 0, exeLinks = 0, systemReads = 0,
             statmReads = 0, ownerStats = 0, weightReads = 0;
    uint64_t statParses = 0, ioParses = 0; // lines parsed: an unchanged one is not (2b)
    size_t keptFiles = 0;
};

struct Snapshot {
    // Kernel threads excluded, in pid order. When /proc cannot be listed, the previous sample's rows stay and
    // processesStale is true (the review of 949fc98: a failed listing wipes nothing).
    std::vector<ProcessRow> rows;
    bool processesStale = false;
    KernelRow kernel;
    SystemSnapshot system;
    std::vector<GpuDevice> gpus;
    double energyImpact = -1; // AM39's graph: the sum over the user's processes, -1 when no row has one
    Counters counters;
    double cpuMs = 0; // the sample's own CPU time on this thread (CLOCK_THREAD_CPUTIME_ID)
};

class Sampler
{
public:
    explicit Sampler(Options options);
    ~Sampler();
    Sampler(const Sampler &) = delete;
    Sampler &operator=(const Sampler &) = delete;

    // One sample at CLOCK_MONOTONIC's time, or at `now` (seconds, tests). The snapshot is the sampler's own, valid until
    // the next sample: a caller that keeps it copies it.
    const Snapshot &sample(unsigned reads);
    const Snapshot &sample(unsigned reads, double now);

    // The pids that own a window (the shell's projection, AM60): their processes are Apps (AM65).
    void setWindowOwners(std::unordered_set<int> pids);

    // AM9's Update Frequency, in seconds: a gap of more than two intervals is a pause (AD32).
    void setInterval(double seconds) { opt_.interval = seconds; }

    // AM8: the window comes back after a time hidden. No rate is drawn across the gap: the next sample is the new start of
    // every rate (the processes' CPU, io, wake-ups and GPU; the system's CPU, disks and interfaces), which shows "—".
    void forgetRates();

    size_t keptFiles() const { return kept_; }

private:
    struct SocketTotals {
        uint64_t sent = 0, received = 0, segsOut = 0, segsIn = 0;
    };
    struct Proc {
        // Read or written at every sample, first: they share a few cache lines (the Disk tab's cost, 2b).
        uint64_t start = 0;
        uint64_t seen = 0; // index_ + 1 of the last sample that listed it
        uint64_t turn = 0; // its place in the turns (AM23, AM43): given in order of arrival, so every turn is as full
        int statFd = -1, statusFd = -1, ioFd = -1, statmFd = -1;
        uint32_t uid = 0;
        uint32_t dirUid = 0;   // the /proc/<pid> directory's owner, read again in its turn and after an exec
        bool kthread = false;
        bool uidKnown = false;
        bool haveTicks = false;
        bool haveIo = false;
        bool haveSwap = false;                // status read for the Memory tab (AD32): its last VmSwap and VmHWM
        bool sessionUnit = false, eligible = false;
        bool haveCommand = false;
        Kind kindAlone = Kind::Background, kindWithWindow = Kind::Background; // classify() of an own process
        uint64_t startCode = 0, endCode = 0; // stat's code addresses: a change is an exec (review of 949fc98)
        uint64_t ticks = 0;
        double ticksTime = 0;
        uint64_t ioRead = 0, ioWrite = 0;
        double ioTime = 0;
        double readRate = -1, writeRate = -1;
        std::string comm, name; // stat's name at the last identification; the name shown
        // The last stat and io read, and what they gave: a line identical to the last one is not parsed again (most
        // processes are idle between two samples; 2b, the Disk tab's cost).
        std::string statText, ioText;
        StatFields stat;
        bool statParsed = false, statCode = false, ioParsed = false;
        // The rest: read in turns, on some tabs, or once.
        uint64_t vmSwapKb = 0, vmHwmKb = 0;
        std::string exe; // the exe link at the last identification
        int cgroupTurns = 0;   // descriptor turns that read its unit again
        std::string command;
        std::string cgroup; // own processes only (AD25)
        std::string appId;  // parseAppUnit's name, own processes only
        uint64_t unitKey = 0; // AM65: a hash of the unit's name when parseAppUnit names it
        bool haveCtx = false;
        uint64_t ctx = 0;
        double ctxTime = 0;
        double wakeRate = -1;
        bool scanned = false;
        int openFiles = -1;
        std::vector<int> drmFds;
        // One descriptor per client, read between two descriptor turns (AM45), and the client each one gave.
        std::vector<int> drmRead;
        std::vector<std::string> drmKeys;
        bool drmPicked = false;
        std::vector<uint64_t> sockets;
        std::map<std::string, uint64_t> engineNs; // "<pdev>|<client>|<engine>" → ns at the last sample
        double gpuTime = 0;
        bool haveGpu = false;
        uint64_t gpuNs = 0;
        double gpuPercent = -1;
        double energySum = 0, energyTime = 0; // Σ EI × seconds, Σ seconds (AM37)
        std::map<std::string, double> enginePercent; // "<pdev>|<engine>" → this process's share, for the GPUs
        std::vector<std::string> gpuDevices;
        // Its sockets seen in the dump: their counters now, and what they held when this process took them over from another
        // one (zero for a socket of its own): its share is the difference (A7 of the 2026-11 audit).
        struct LiveSocket {
            TcpCounters now;
            TcpCounters base;
        };
        std::unordered_map<uint64_t, LiveSocket> live;
        SocketTotals closed;                            // sockets that went, their last counters
    };

    const std::string &procPath(int pid, const char *file);
    bool readKept(int &fd, int pid, const char *file, std::string_view &out, uint64_t &counter);
    bool readFile(const std::string &path, std::string &buf, bool oneRecord = false);
    bool readAt(int dir, const char *name, std::string &buf);
    void closeProc(Proc &p);
    void identify(int pid, Proc &p, bool own, unsigned reads, const std::string &comm, Counters &c);
    void readCgroup(int pid, Proc &p, Counters &c);
    void readThreads(int pid, Proc &p, double now, Counters &c);
    void scanDescriptors(int pid, Proc &p, Counters &c);
    void readGpu(int pid, Proc &p, double now, Counters &c, std::map<std::string, GpuDevice> &devices,
                 std::unordered_set<std::string> &clientsSeen);
    void readSystem(unsigned reads, double now, SystemSnapshot &out, Counters &c);
    void nameGpu(GpuDevice &dev, Counters &c);

    Options opt_;
    std::unordered_map<int, Proc> procs_;
    std::unordered_set<int> windowOwners_;
    size_t kept_ = 0;
    uint64_t index_ = 0;     // samples taken: the turns of AM23 and AM43
    uint64_t nextTurn_ = 0;  // the next process's place in the turns
    Snapshot snap_;          // the last sample, rebuilt in place (its vectors keep their capacity)
    std::vector<int> listing_; // the pids /proc lists
    int procFd_ = -1;          // opt_.procRoot, for fstatat
    std::vector<TcpCounters> tcp_;
    std::unordered_map<uint64_t, bool> efficientUnits_; // AM68: by unitKey, this sample's
    std::string buf_;        // whole files read by readFile
    std::string path_;       // the /proc path being built (its capacity kept: no allocation per read)
    std::unique_ptr<char[]> io_; // kept files' contents (kBufSize, never cleared: only the bytes read are looked at)
    // System state between samples.
    bool haveCpu_ = false;
    CpuTimes lastCpu_;
    std::vector<CpuTimes> lastPerCpu_;
    uint64_t cpuDeltaTicks_ = 0;                        // /proc/stat's total ticks between its last two reads
    uint64_t lastProcessIndex_ = UINT64_MAX - 1, lastCpuIndex_ = UINT64_MAX - 1;
    // The Memory tab's last samples (AD32): coming back to it after another tab or a pause reads every status once.
    uint64_t lastMemoryIndex_ = UINT64_MAX - 1;
    double lastMemoryTime_ = -1;
    // Which own process a socket's traffic counts for (inode → pid): one, while several hold it (inherited across a fork).
    std::unordered_map<uint64_t, int> socketOwner_;
    std::map<std::string, DiskStat> lastDisks_;
    std::map<std::string, NetDev> lastNet_;
    // The counters of the disks and interfaces that went away (or restarted from zero), added to the totals: "Data read",
    // "Packets in" and the others never go back when a USB disk, a VPN or a container's veth goes (A8 of the 2026-11 audit).
    DiskStat goneDisks_;
    NetDev goneNet_;
    double lastDiskTime_ = -1, lastNetTime_ = -1;
    std::vector<std::string> physicalDisks_, zramDevices_;
    double devicesListedAt_ = -1e9;
    struct GpuName {
        int card = -1;
        std::string model;
    };
    std::map<std::string, GpuName> gpuNames_; // by drm-pdev: read once (AM47)
};

} // namespace activity
