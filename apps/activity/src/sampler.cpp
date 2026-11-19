#include "sampler.h"

#include "machine.h"

#include "textclean.h"

#include <algorithm>
#include <cerrno>
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <ctime>

#include <dirent.h>
#include <fcntl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

namespace activity
{
namespace
{

constexpr size_t kBufSize = 65536;

double monotonicNow()
{
    timespec t{};
    clock_gettime(CLOCK_MONOTONIC, &t);
    return static_cast<double>(t.tv_sec) + static_cast<double>(t.tv_nsec) / 1e9;
}

double threadCpuMs()
{
    timespec t{};
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
    return static_cast<double>(t.tv_sec) * 1e3 + static_cast<double>(t.tv_nsec) / 1e6;
}

bool isNumeric(const char *s)
{
    if (!*s)
        return false;
    for (; *s; ++s) {
        if (*s < '0' || *s > '9')
            return false;
    }
    return true;
}

// The command line kept for the table: cut to kCommandMax (at a character's first byte) before it is cleaned. A 1 MiB argv
// (a build, xargs) was copied into every row and laid out whole by the Command column at each sample; Inspect reads its own.
std::string tableCommand(std::string joined)
{
    if (joined.size() > kCommandMax) {
        size_t n = kCommandMax;
        while (n > 0 && (static_cast<unsigned char>(joined[n]) & 0xC0) == 0x80)
            --n;
        joined.resize(n);
    }
    return sanitizeDisplay(joined);
}

// A device's last counters, kept in the totals once it is gone.
void retire(DiskStat &gone, const DiskStat &d)
{
    gone.reads += d.reads;
    gone.writes += d.writes;
    gone.sectorsRead += d.sectorsRead;
    gone.sectorsWritten += d.sectorsWritten;
}

void retire(NetDev &gone, const NetDev &n)
{
    gone.rxPackets += n.rxPackets;
    gone.txPackets += n.txPackets;
    gone.rxBytes += n.rxBytes;
    gone.txBytes += n.txBytes;
}

double rate(uint64_t now, uint64_t before, double seconds)
{
    if (seconds <= 0 || now < before)
        return -1;
    return static_cast<double>(now - before) / seconds;
}

// lstat: /sys/block/<disk>/device is a link; its presence is what tells a whole physical disk.
bool exists(const std::string &path)
{
    struct stat st{};
    return lstat(path.c_str(), &st) == 0;
}

// A row of the last sample, emptied for this one: its values reset in one copy, its strings emptied with their buffers
// kept, so a name longer than the short-string buffer is not allocated and freed again at each sample (2b, the Disk tab's
// cost). Every field is the default one (sampler.h checks that ProcessRow has no other member).
ProcessRow &recycle(ProcessRow &r)
{
    static const ProcessValues blank{};
    static_cast<ProcessValues &>(r) = blank;
    r.name.clear();
    r.command.clear();
    r.appId.clear();
    r.gpuDevices.clear();
    return r;
}

// A whole file of at most 16 MiB (pci.ids is about 1.5 MiB), read once per GPU.
bool readWhole(const std::string &path, std::string &out)
{
    const int f = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (f < 0)
        return false;
    out.clear();
    char chunk[65536];
    ssize_t n = 0;
    while ((n = read(f, chunk, sizeof chunk)) > 0 && out.size() < (16u << 20))
        out.append(chunk, static_cast<size_t>(n));
    close(f);
    return n >= 0;
}

} // namespace

unsigned readsForTab(Tab tab)
{
    // Every tab reads the four system groups (2b): each tab's graph keeps its history whichever tab is shown, as macOS's
    // do (about 0.04 ms a sample on the cloud machine; A10's step-1 plans always counted them).
    constexpr unsigned system = ReadSystemCpu | ReadSystemMemory | ReadSystemDisk | ReadSystemNet;
    switch (tab) {
    case Tab::Cpu:
        return ReadProcesses | ReadDescriptors | ReadGpu | system;
    case Tab::Memory:
        return ReadProcesses | ReadMemory | system;
    case Tab::Energy:
        return ReadProcesses | ReadIo | ReadThreads | ReadDescriptors | ReadGpu | system;
    case Tab::Disk:
        return ReadProcesses | ReadIo | system;
    case Tab::Network:
        return ReadProcesses | ReadDescriptors | ReadSockets | system;
    }
    return ReadProcesses;
}

Options defaultOptions()
{
    Options o;
    o.uid = getuid();
    const long tick = sysconf(_SC_CLK_TCK);
    o.clockTicks = tick > 0 ? tick : 100;
    const long page = sysconf(_SC_PAGESIZE);
    o.pageSize = page > 0 ? page : 4096;
    std::string defs;
    if (FILE *f = std::fopen("/etc/login.defs", "re")) {
        char chunk[4096];
        size_t n = 0;
        while ((n = std::fread(chunk, 1, sizeof chunk, f)) > 0)
            defs.append(chunk, n);
        std::fclose(f);
    }
    o.uidMin = parseUidMin(defs);
    rlimit lim{};
    if (getrlimit(RLIMIT_NOFILE, &lim) == 0 && lim.rlim_cur != RLIM_INFINITY)
        o.maxKeptFiles = lim.rlim_cur > 256 ? static_cast<size_t>(lim.rlim_cur - 256) : 0;
    else
        o.maxKeptFiles = 4096;
    return o;
}

size_t raiseFileLimit()
{
    rlimit lim{};
    if (getrlimit(RLIMIT_NOFILE, &lim) != 0)
        return 0;
    const rlim_t wanted = lim.rlim_max == RLIM_INFINITY ? 16384 : std::min<rlim_t>(lim.rlim_max, 16384);
    if (lim.rlim_cur != RLIM_INFINITY && lim.rlim_cur < wanted) {
        rlimit raised = lim;
        raised.rlim_cur = wanted;
        if (setrlimit(RLIMIT_NOFILE, &raised) == 0)
            lim = raised;
    }
    return lim.rlim_cur == RLIM_INFINITY ? 16384 : static_cast<size_t>(lim.rlim_cur);
}

double energyImpact(double cpuPercent, double gpuPercent, double wakeRate, double readRate, double writeRate)
{
    const auto known = [](double v) { return v > 0 ? v : 0.0; };
    return known(cpuPercent) + known(gpuPercent) + 0.02 * known(wakeRate) + (known(readRate) + known(writeRate)) / 1e6;
}

PressureLevel pressureLevel(const Meminfo &m, const Pressure &p)
{
    // AM33 (provisional thresholds, pinned by tests/unit/activity/tst_memory.cpp).
    const double left = m.memTotal ? static_cast<double>(m.memAvailable) / static_cast<double>(m.memTotal) : 1.0;
    if ((p.ok && p.fullAvg10 >= 5.0) || left < 0.05)
        return PressureLevel::Critical;
    if ((p.ok && p.someAvg10 >= 10.0) || left < 0.15)
        return PressureLevel::Warning;
    return PressureLevel::Normal;
}

Sampler::Sampler(Options options)
    : opt_(std::move(options))
    , io_(new char[kBufSize]) // default-initialized: a 64 KiB clear at every read was most of a sample's cost (review of 949fc98)
{
    if (opt_.threadTurns < 1)
        opt_.threadTurns = 1;
    if (opt_.descriptorTurns < 1)
        opt_.descriptorTurns = 1;
    if (opt_.statusTurns < 1)
        opt_.statusTurns = 1;
    if (opt_.pageSize <= 0)
        opt_.pageSize = 4096;
    if (opt_.clockTicks <= 0)
        opt_.clockTicks = 100;
    if (!opt_.tcpDump)
        opt_.tcpDump = dumpTcpSockets;
}

Sampler::~Sampler()
{
    for (auto &[pid, p] : procs_)
        closeProc(p);
    if (procFd_ >= 0)
        close(procFd_);
}

void Sampler::setWindowOwners(std::unordered_set<int> pids)
{
    windowOwners_ = std::move(pids);
}

// "<procRoot>/<pid>/<file>" in path_, whose capacity stays: no allocation once the first path was built.
const std::string &Sampler::procPath(int pid, const char *file)
{
    char digits[16];
    char *end = std::to_chars(digits, digits + sizeof digits, pid).ptr; // snprintf costs ten times more (2b)
    path_.assign(opt_.procRoot);
    path_ += '/';
    path_.append(digits, static_cast<size_t>(end - digits));
    if (file && *file) {
        path_ += '/';
        path_ += file;
    }
    return path_;
}

// Reads /proc/<pid>/<file> into io_ (`out` views the bytes read) through a kept descriptor when the budget allows (AD10,
// A10: a pread at offset 0 of an open /proc file costs less than an open, a read and a close). A kept descriptor of a
// process that ended fails its read (ESRCH): it is closed and false returned, so a pid reused since is never read through
// it. Nothing is cleared or copied: the parsers look at the bytes read only.
bool Sampler::readKept(int &fd, int pid, const char *file, std::string_view &out, uint64_t &counter)
{
    ++counter;
    if (fd >= 0) {
        const ssize_t n = pread(fd, io_.get(), kBufSize, 0);
        if (n > 0) {
            out = std::string_view(io_.get(), static_cast<size_t>(n));
            return true;
        }
        close(fd);
        fd = -1;
        --kept_;
        return false;
    }
    const int f = open(procPath(pid, file).c_str(), O_RDONLY | O_CLOEXEC);
    if (f < 0)
        return false;
    const ssize_t n = read(f, io_.get(), kBufSize);
    if (n <= 0) {
        close(f);
        return false;
    }
    out = std::string_view(io_.get(), static_cast<size_t>(n));
    if (kept_ < opt_.maxKeptFiles) {
        fd = f;
        ++kept_;
    } else {
        close(f);
    }
    return true;
}

// `oneRecord`: a per-process file the kernel writes whole at each read (cmdline, cgroup, fdinfo): a read that does not fill
// the buffer had all of it, and no second read is made to see the end (one system call less per file, review of 949fc98).
// The system files are lists the kernel hands out a page at a time: they are read to the end.
bool Sampler::readFile(const std::string &path, std::string &buf, bool oneRecord)
{
    const int f = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (f < 0)
        return false;
    buf.clear();
    for (;;) {
        const ssize_t n = read(f, io_.get(), kBufSize);
        if (n < 0) {
            close(f);
            return false;
        }
        if (n == 0)
            break;
        buf.append(io_.get(), static_cast<size_t>(n));
        if ((oneRecord && static_cast<size_t>(n) < kBufSize) || buf.size() > (1u << 20)) // no file it reads is this long
            break;
    }
    close(f);
    return true;
}

// One read of a small file under the directory `dir` (a thread's status): openat, as A10 does, no path built.
bool Sampler::readAt(int dir, const char *name, std::string &buf)
{
    const int f = openat(dir, name, O_RDONLY | O_CLOEXEC);
    if (f < 0)
        return false;
    const ssize_t n = read(f, io_.get(), kBufSize);
    close(f);
    if (n <= 0)
        return false;
    buf.assign(io_.get(), static_cast<size_t>(n));
    return true;
}

void Sampler::closeProc(Proc &p)
{
    if (p.statFd >= 0) {
        close(p.statFd);
        p.statFd = -1;
        --kept_;
    }
    if (p.statusFd >= 0) {
        close(p.statusFd);
        p.statusFd = -1;
        --kept_;
    }
    if (p.ioFd >= 0) {
        close(p.ioFd);
        p.ioFd = -1;
        --kept_;
    }
    if (p.statmFd >= 0) {
        close(p.statmFd);
        p.statmFd = -1;
        --kept_;
    }
}

// Names a process (AM17) when it is first seen and again after an exec (stat's name or the exe link changed; review of
// 949fc98): another owner by stat's name only (AD25); one of the user's own from its argv[0], its stat name and its
// executable (processName), its command line read again.
void Sampler::identify(int pid, Proc &p, bool own, unsigned reads, const std::string &comm, Counters &c)
{
    p.comm = comm;
    p.command.clear();
    p.haveCommand = false;
    if (!own) {
        p.exe.clear();
        p.name = sanitizeDisplay(comm);
        return;
    }
    ++c.exeLinks;
    char target[4096];
    const ssize_t n = readlink(procPath(pid, "exe").c_str(), target, sizeof target - 1);
    p.exe.assign(target, n > 0 ? static_cast<size_t>(n) : 0);
    std::string argv0;
    ++c.cmdlineReads;
    if (readFile(procPath(pid, "cmdline"), buf_, true)) {
        argv0 = cmdlineFirstWord(buf_);
        if (reads & ReadCommand) {
            p.command = tableCommand(cmdlineJoined(buf_));
            p.haveCommand = true;
        }
    }
    p.name = sanitizeDisplay(processName(argv0, comm, p.exe));
}

// The user's own process's unit (AM54, AM65, AM68): read when it is first seen and again in its descriptor turn (moved
// into a scope); what the rows need of it is kept, the path itself never leaves the sampler.
void Sampler::readCgroup(int pid, Proc &p, Counters &c)
{
    ++c.cgroupReads;
    if (!readFile(procPath(pid, "cgroup"), buf_, true))
        return;
    std::string path = parseCgroupV2(buf_);
    if (path == p.cgroup && !p.cgroup.empty())
        return;
    p.cgroup = std::move(path);
    p.kindAlone = classify(p.cgroup, true, false, false);
    p.kindWithWindow = classify(p.cgroup, true, false, true);
    p.sessionUnit = isSessionProcess(p.cgroup);
    p.eligible = efficiencyEligible(p.cgroup);
    const std::optional<AppUnit> unit = parseAppUnit(unitOf(p.cgroup));
    p.appId = unit ? unit->name : std::string();
    p.unitKey = 0;
    if (unit) {
        const uint64_t h = std::hash<std::string_view>{}(unitOf(p.cgroup));
        p.unitKey = h != 0 ? h : 1;
    }
}

void Sampler::forgetRates()
{
    for (auto &[pid, p] : procs_) {
        p.haveTicks = false;
        p.haveIo = false;
        p.readRate = p.writeRate = -1;
        p.haveCtx = false;
        p.wakeRate = -1;
        p.haveGpu = false;
        p.gpuPercent = -1;
        p.engineNs.clear();
        p.enginePercent.clear();
    }
    haveCpu_ = false;
    lastProcessIndex_ = lastCpuIndex_ = UINT64_MAX - 1;
    lastDiskTime_ = lastNetTime_ = -1;
}

void Sampler::readThreads(int pid, Proc &p, double now, Counters &c)
{
    DIR *d = opendir(procPath(pid, "task").c_str());
    if (!d)
        return;
    uint64_t sum = 0;
    char name[sizeof(dirent::d_name) + 8];
    while (dirent *e = readdir(d)) {
        if (!isNumeric(e->d_name))
            continue;
        ++c.threadStatusReads;
        std::snprintf(name, sizeof name, "%s/status", e->d_name);
        if (!readAt(dirfd(d), name, buf_))
            continue;
        uint64_t switches = 0;
        if (parseVoluntarySwitches(buf_, switches))
            sum += switches;
    }
    closedir(d);
    // A thread that ended takes its switches with it: a sum below the last one gives no rate this turn, the baseline moves.
    if (p.haveCtx && sum >= p.ctx && now > p.ctxTime)
        p.wakeRate = rate(sum, p.ctx, now - p.ctxTime);
    p.ctx = sum;
    p.ctxTime = now;
    p.haveCtx = true;
}

void Sampler::scanDescriptors(int pid, Proc &p, Counters &c)
{
    DIR *d = opendir(procPath(pid, "fd").c_str());
    ++c.fdListReads;
    if (!d) {
        p.scanned = true; // refused (non-dumpable): "—", and the turn comes again
        p.openFiles = -1;
        return;
    }
    p.sockets.clear();
    p.drmFds.clear();
    p.drmRead.clear();
    p.drmKeys.clear();
    p.drmPicked = false;
    int count = 0;
    char target[512];
    while (dirent *e = readdir(d)) {
        if (!isNumeric(e->d_name))
            continue;
        ++count;
        ++c.fdLinks;
        const ssize_t n = readlinkat(dirfd(d), e->d_name, target, sizeof target - 1);
        if (n <= 0)
            continue;
        target[n] = '\0';
        if (std::strncmp(target, "socket:[", 8) == 0) {
            const uint64_t inode = std::strtoull(target + 8, nullptr, 10);
            if (inode)
                p.sockets.push_back(inode);
        } else if (std::strncmp(target, "/dev/dri/", 9) == 0) {
            p.drmFds.push_back(std::atoi(e->d_name));
        }
    }
    closedir(d);
    std::sort(p.drmFds.begin(), p.drmFds.end()); // /proc's order; a client's first descriptor is its lowest
    p.openFiles = count;
    p.scanned = true;
}

void Sampler::readGpu(int pid, Proc &p, double now, Counters &c, std::map<std::string, GpuDevice> &devices,
                      std::unordered_set<std::string> &clientsSeen)
{
    // One read per client (AM45). A client can show through several descriptors: Mesa's pipe loader and iris's buffer
    // manager each duplicate the descriptor they are given, and a duplicate is the same client; each fdinfo read has the
    // driver go over the client's objects. The first read after a descriptor turn reads every DRM descriptor and keeps
    // the first of each client; until the next turn only those are read, and one that fails or names another client (its
    // number closed and reused) brings the full read back at once (the integrator's AM-P2 run of f68789c on the i5). A
    // client is picked by its identity, engine lines or not: amdgpu writes none for an engine a client has not used yet,
    // and a client idle at its turn would go unread until the next one (the integrator's review of 983b7de).
    std::string fbuf;
    auto readClient = [&](int fd, DrmClient &client, std::string &key) {
        ++c.fdinfoReads;
        if (!readFile(procPath(pid, "fdinfo") + '/' + std::to_string(fd), fbuf, true) || !parseDrmFdinfo(fbuf, client))
            return false;
        key = client.pdev + '|' + std::to_string(client.clientId);
        return true;
    };
    std::vector<DrmClient> clients;
    std::vector<std::string> keys;
    bool picked = p.drmPicked;
    for (size_t i = 0; picked && i < p.drmRead.size(); ++i) {
        DrmClient client;
        std::string key;
        if (!readClient(p.drmRead[i], client, key) || key != p.drmKeys[i]) {
            picked = false;
            clients.clear();
            keys.clear();
            break;
        }
        clients.push_back(std::move(client));
        keys.push_back(std::move(key));
    }
    if (!picked) {
        p.drmRead.clear();
        p.drmKeys.clear();
        for (int fd : p.drmFds) {
            DrmClient client;
            std::string key;
            if (!readClient(fd, client, key) || std::find(keys.begin(), keys.end(), key) != keys.end())
                continue; // no client, or the same client through another descriptor
            p.drmRead.push_back(fd);
            p.drmKeys.push_back(key);
            clients.push_back(std::move(client));
            keys.push_back(std::move(key));
        }
        p.drmPicked = true;
    }

    std::map<std::string, uint64_t> nowNs;
    std::map<std::string, double> perEngine; // "<pdev>|<engine>" → this process's share
    uint64_t total = 0;
    bool any = false;
    const double dt = p.haveGpu ? now - p.gpuTime : 0;
    std::vector<std::string> pdevs;
    for (size_t i = 0; i < clients.size(); ++i) {
        const DrmClient &client = clients[i];
        const std::string &key = keys[i];
        if (client.engineNs.empty())
            continue; // no engine used yet: nothing to show
        if (!clientsSeen.insert(key).second)
            continue; // a client this sample already counted in another process (inherited or passed)
        any = true;
        if (std::find(pdevs.begin(), pdevs.end(), client.pdev) == pdevs.end())
            pdevs.push_back(client.pdev);
        GpuDevice &dev = devices[client.pdev];
        dev.pdev = client.pdev;
        dev.driver = client.driver;
        for (const auto &[region, bytes] : client.memoryBytes) {
            dev.memoryBytes += bytes;
            dev.memoryRegions[region] += bytes;
        }
        for (const auto &[engine, ns] : client.engineNs) {
            const std::string k = key + '|' + engine;
            nowNs[k] = ns;
            total += ns;
            auto last = p.engineNs.find(k);
            if (last == p.engineNs.end() || dt <= 0 || ns < last->second)
                continue;
            uint64_t cap = 1;
            auto capIt = client.engineCapacity.find(engine);
            if (capIt != client.engineCapacity.end() && capIt->second > 0)
                cap = capIt->second;
            const double share = static_cast<double>(ns - last->second) / (dt * 1e9 * static_cast<double>(cap)) * 100.0;
            perEngine[client.pdev + '|' + engine] += share;
        }
    }
    if (!any) {
        p.haveGpu = false;
        p.gpuPercent = -1;
        p.engineNs.clear();
        p.enginePercent.clear();
        p.gpuDevices.clear();
        return;
    }
    std::sort(pdevs.begin(), pdevs.end());
    p.gpuDevices = std::move(pdevs);
    double busiest = p.haveGpu ? 0.0 : -1.0;
    for (const auto &[k, share] : perEngine)
        busiest = std::max(busiest, std::min(share, 100.0));
    p.gpuPercent = busiest;
    p.enginePercent = perEngine;
    p.engineNs = std::move(nowNs);
    p.gpuNs = total;
    p.gpuTime = now;
    p.haveGpu = true;
}

const Snapshot &Sampler::sample(unsigned reads)
{
    return sample(reads, monotonicNow());
}

const Snapshot &Sampler::sample(unsigned reads, double now)
{
    const double cpu0 = threadCpuMs();
    Snapshot &s = snap_;
    s.system = SystemSnapshot{};
    s.gpus.clear();
    s.energyImpact = -1;
    s.counters = Counters{};
    s.processesStale = false;
    Counters &c = s.counters;
    uint64_t ownDelta = 0;
    std::map<std::string, GpuDevice> devices;
    std::unordered_set<std::string> clientsSeen;

    bool listed = false;
    if (!(reads & ReadProcesses)) {
        s.rows.clear(); // not asked for: no rows (the Dock's graph while the window is hidden, AM8)
        s.kernel = KernelRow{};
    } else {
        listing_.clear();
        if (procFd_ < 0)
            procFd_ = open(opt_.procRoot.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (DIR *d = procFd_ >= 0 ? opendir(opt_.procRoot.c_str()) : nullptr) {
            while (dirent *e = readdir(d)) {
                if (!isNumeric(e->d_name))
                    continue;
                int pid = 0;
                for (const char *ch = e->d_name; *ch; ++ch)
                    pid = pid * 10 + (*ch - '0');
                listing_.push_back(pid);
            }
            closedir(d);
            listed = true;
        } else {
            // A failed listing (out of descriptors, /proc gone) wipes nothing: the previous rows, the Kernel row and every
            // process's state stay until a listing succeeds (review of 949fc98).
            s.processesStale = true;
        }
    }

    // The Memory tab's turns hold while it is shown sample after sample; its first sample after another tab, or after a
    // pause longer than two intervals (a hidden window), reads every process's status, so no swap shows older than five
    // samples (AD32; review of f68789c). The interval is the one set (AM9), not the one measured, which a full read left
    // at 0 and a pause right after it went unseen (review of 19f5d4c).
    const bool memoryAll = (reads & ReadMemory)
        && (lastMemoryIndex_ + 1 != index_ || lastMemoryTime_ < 0 || now - lastMemoryTime_ > 2 * opt_.interval);

    if (listed) {
        const uint64_t mark = index_ + 1;
        c.listed = listing_.size();
        s.system.processes = static_cast<int>(listing_.size());
        if (!std::is_sorted(listing_.begin(), listing_.end())) // /proc lists pids in increasing order
            std::sort(listing_.begin(), listing_.end());
        size_t used = 0; // the last sample's rows are emptied and filled again in place (recycle)
        s.rows.reserve(listing_.size());
        s.kernel = KernelRow{};
        double kernelPercent = 0;
        bool kernelKnown = false;

        size_t seenCount = 0; // the processes this sample listed: when they are all of procs_, none ended
        for (const int pid : listing_) {
            auto [it, fresh] = procs_.try_emplace(pid);
            Proc &p = it->second;
            std::string_view text; // views io_: parsed before the next read
            if (!readKept(p.statFd, pid, "stat", text, c.statReads)) {
                if (fresh) {
                    procs_.erase(it);
                    continue;
                }
                // The kept descriptor's process ended; the pid may have a new one.
                closeProc(p);
                p = Proc{};
                fresh = true;
                if (!readKept(p.statFd, pid, "stat", text, c.statReads)) {
                    procs_.erase(it);
                    continue;
                }
            }
            // Parsed again only when the line changed: the same bytes give the same fields (2b).
            const StatFields &st = p.stat;
            const bool code = fresh || p.dirUid == opt_.uid; // code addresses: 0 for others (not traceable)
            if (!p.statParsed || p.statCode != code || text != p.statText) {
                p.statParsed = false;
                ++c.statParses;
                if (!parseStat(text, p.stat, code)) {
                    closeProc(p);
                    procs_.erase(it);
                    continue;
                }
                p.statText.assign(text.data(), text.size());
                p.statCode = code;
                p.statParsed = true;
            }
            if (!fresh && st.starttime != p.start) { // a pid reused, read by path: another process
                closeProc(p);
                p = Proc{};
                fresh = true;
                ++c.statParses;
                if (!readKept(p.statFd, pid, "stat", text, c.statReads) || !parseStat(text, p.stat)) {
                    closeProc(p);
                    procs_.erase(it);
                    continue;
                }
                p.statText.assign(text.data(), text.size());
                p.statCode = true;
                p.statParsed = true;
            }
            if (fresh)
                p.turn = nextTurn_++;
            p.kthread = (st.flags & kPfKthread) != 0;
            // A kernel thread's name changes with its work ("kworker/0:1-events"): never an exec, and its owner is root.
            // An exec: for the user's own processes, whose code addresses stat gives, those addresses changed (a new image);
            // a new stat name alone is then a prctl(PR_SET_NAME) rename, and the process keeps its name as on macOS
            // (review of f68789c: python3 became python3.13). For the others, whose addresses read 0, the name is all there is.
            const bool haveCode = st.startCode != 0 && p.startCode != 0;
            const bool exec = !fresh && !p.kthread
                && (haveCode ? (st.startCode != p.startCode || st.endCode != p.endCode) : st.comm != p.comm);
            if (!exec && haveCode)
                p.comm = st.comm;
            // The owner from the directory: read when the process is first seen, after an exec and in its turn (a tenth
            // per sample, for a process that changed its uid without one), not at every sample (review of 949fc98: six
            // hundred fstatat a sample, a fifth of the CPU tab's cost).
            if (!p.kthread
                && (fresh || exec || index_ % static_cast<uint64_t>(opt_.descriptorTurns) == p.turn % static_cast<uint64_t>(opt_.descriptorTurns))) {
                char name[16];
                *std::to_chars(name, name + sizeof name - 1, pid).ptr = '\0';
                ++c.ownerStats;
                uint32_t owner = 0;
                bool ownerOk = false;
                if (opt_.dirOwner) {
                    ownerOk = opt_.dirOwner(procFd_, name, owner);
                } else {
                    struct stat dirStat{};
                    ownerOk = fstatat(procFd_, name, &dirStat, 0) == 0;
                    owner = static_cast<uint32_t>(dirStat.st_uid);
                }
                if (!ownerOk) {
                    closeProc(p);
                    procs_.erase(it);
                    continue;
                }
                // Behind a directory owned by root (a non-dumpable process) the owner is status's real uid, which can change
                // without an exec: read again in the turn, as when the directory's owner changed (review of f68789c).
                if (!fresh && (p.dirUid != owner || owner == 0))
                    p.uidKnown = false;
                p.dirUid = owner;
            }
            const uint32_t dirUid = p.dirUid;
            p.seen = mark;
            ++seenCount;
            p.start = st.starttime;
            const uint64_t ticks = st.utime + st.stime;
            double percent = -1;
            const double cpuSeconds = now - p.ticksTime;
            if (p.haveTicks && now > p.ticksTime && ticks >= p.ticks)
                percent = static_cast<double>(ticks - p.ticks) / (cpuSeconds * static_cast<double>(opt_.clockTicks)) * 100.0;

            if (p.kthread) {
                s.kernel.threads += 1;
                s.kernel.cpuTicks += ticks;
                if (percent >= 0) {
                    kernelPercent += percent;
                    kernelKnown = true;
                }
                p.ticks = ticks;
                p.ticksTime = now;
                p.haveTicks = true;
                continue;
            }

            // The owner: the real uid of status when it is read; else the directory's owner (the effective uid), except
            // that a directory owned by root may hide a non-dumpable process of anyone: status tells (the spec's Terms).
            // The Memory tab reads status in turns (AD32): VmSwap and VmHWM change slowly, statm gives the rest each sample.
            StatusFields status;
            bool haveStatus = false;
            const bool memoryTurn = (reads & ReadMemory)
                && (!p.haveSwap || memoryAll
                    || index_ % static_cast<uint64_t>(opt_.statusTurns) == p.turn % static_cast<uint64_t>(opt_.statusTurns));
            if ((reads & ReadStatus) || memoryTurn || (dirUid == 0 && !p.uidKnown)) {
                std::string_view statusText;
                if (readKept(p.statusFd, pid, "status", statusText, c.statusReads))
                    haveStatus = parseStatus(statusText, status, false);
            }
            if (haveStatus && status.hasMemory) {
                p.vmSwapKb = status.vmSwapKb;
                p.vmHwmKb = status.vmHwmKb;
                p.haveSwap = true;
            }
            uint32_t uid = dirUid;
            if (haveStatus && status.hasUid) {
                uid = status.ruid;
                p.uid = uid;
                p.uidKnown = true;
            } else if (dirUid == 0 && p.uidKnown) {
                uid = p.uid;
            }
            const bool own = uid == opt_.uid;

            // Named when first seen and again after an exec (review of 949fc98): stat's name changed, or the code addresses
            // stat gives for the user's own processes did (a new image is mapped elsewhere, even under the same name). Both
            // come with the stat read every sample: nothing more is read to notice an exec.
            p.startCode = st.startCode;
            p.endCode = st.endCode;
            if (fresh) {
                if (own)
                    readCgroup(pid, p, c);
                identify(pid, p, own, reads, st.comm, c);
            } else if (exec) {
                identify(pid, p, own, reads, st.comm, c);
            } else if (own && (reads & ReadCommand) && !p.haveCommand) {
                ++c.cmdlineReads;
                if (readFile(procPath(pid, "cmdline"), buf_, true))
                    p.command = tableCommand(cmdlineJoined(buf_));
                p.haveCommand = true;
            }

            ProcessRow &row = used < s.rows.size() ? recycle(s.rows[used]) : s.rows.emplace_back(); // reserved: the reference holds
            ++used;
            row.pid = pid;
            row.start = st.starttime;
            row.ppid = st.ppid;
            row.pgrp = st.pgrp;
            row.uid = uid;
            row.own = own;
            row.systemAccount = uid < opt_.uidMin;
            row.state = st.state;
            row.nice = st.nice;
            row.threads = st.numThreads;
            row.name = p.name;
            if (own) {
                row.command = p.command;
                row.appId = p.appId;
                row.unitKey = p.unitKey;
                const bool ownsWindow = !windowOwners_.empty() && windowOwners_.count(pid) != 0;
                row.kind = ownsWindow ? p.kindWithWindow : p.kindAlone;
                row.session = p.sessionUnit;
                row.efficiencyEligible = p.eligible;
            } else {
                row.kind = classify({}, false, row.systemAccount, false);
            }
            row.cpuTicks = ticks;
            row.cpuPercent = percent;
            row.minorFaults = st.minflt;
            row.majorFaults = st.majflt;
            if (own && p.haveTicks && ticks >= p.ticks)
                ownDelta += ticks - p.ticks;
            p.ticks = ticks;
            p.ticksTime = now;
            p.haveTicks = true;

            if ((reads & ReadStatus) && haveStatus && status.hasMemory) {
                row.hasMemory = true;
                row.memory = (status.rssAnonKb + status.vmSwapKb) * 1024;
                row.realMemory = status.vmRssKb * 1024;
                row.privateMemory = status.rssAnonKb * 1024;
                row.sharedMemory = (status.rssFileKb + status.rssShmemKb) * 1024;
                row.swapped = status.vmSwapKb * 1024;
                row.peakMemory = status.vmHwmKb * 1024;
                row.virtualMemory = status.vmSizeKb * 1024;
            } else if (reads & ReadMemory) {
                // AM30 from statm (a sixth of status's cost, A10): resident - (file + shared memory) is RssAnon; VmSwap
                // is status's of the process's last turn (AD32).
                std::string_view statmText;
                Statm sm;
                if (p.haveSwap && readKept(p.statmFd, pid, "statm", statmText, c.statmReads) && parseStatm(statmText, sm)) {
                    const uint64_t page = static_cast<uint64_t>(opt_.pageSize);
                    row.hasMemory = true;
                    row.realMemory = sm.resident * page;
                    row.sharedMemory = std::min(sm.shared, sm.resident) * page;
                    row.privateMemory = row.realMemory - row.sharedMemory;
                    row.swapped = p.vmSwapKb * 1024;
                    row.memory = row.privateMemory + row.swapped;
                    row.peakMemory = std::max(p.vmHwmKb * 1024, row.realMemory);
                    row.virtualMemory = sm.size * page;
                }
            }

            if (own && (reads & ReadIo)) {
                IoFields io;
                std::string_view ioText; // kept and re-read with pread, as stat (the kernel checks the access at each read)
                bool ioOk = readKept(p.ioFd, pid, "io", ioText, c.ioReads);
                if (ioOk && p.ioParsed && ioText == p.ioText) { // unchanged: the counters last read (2b)
                    io.readBytes = p.ioRead;
                    io.writeBytes = p.ioWrite;
                } else if (ioOk) {
                    ++c.ioParses;
                    ioOk = parseIo(ioText, io);
                    p.ioParsed = ioOk;
                    if (ioOk)
                        p.ioText.assign(ioText.data(), ioText.size());
                }
                if (ioOk) {
                    if (p.haveIo && now > p.ioTime) {
                        p.readRate = rate(io.readBytes, p.ioRead, now - p.ioTime);
                        p.writeRate = rate(io.writeBytes, p.ioWrite, now - p.ioTime);
                    }
                    p.ioRead = io.readBytes;
                    p.ioWrite = io.writeBytes;
                    p.ioTime = now;
                    p.haveIo = true;
                    row.hasIo = true;
                    row.bytesRead = io.readBytes;
                    row.bytesWritten = io.writeBytes;
                    row.readRate = p.readRate;
                    row.writeRate = p.writeRate;
                } else {
                    p.haveIo = false;
                }
            }

            // The turns go by each process's place of arrival, not by its pid: as full at every sample whatever the pids
            // (review of 949fc98).
            if (own && (reads & ReadThreads)) {
                if (!p.haveCtx || index_ % static_cast<uint64_t>(opt_.threadTurns) == p.turn % static_cast<uint64_t>(opt_.threadTurns))
                    readThreads(pid, p, now, c);
                row.wakeRate = p.wakeRate;
            }

            if (own && (reads & ReadDescriptors)) {
                if (!p.scanned || index_ % static_cast<uint64_t>(opt_.descriptorTurns) == p.turn % static_cast<uint64_t>(opt_.descriptorTurns)) {
                    scanDescriptors(pid, p, c);
                    if (!fresh && p.cgroupTurns < 2) {
                        // A process listed in the moment before its launcher moved it into its unit: read again in its
                        // first two turns, after which a unit no longer changes (uwsm moves a launch before its exec).
                        ++p.cgroupTurns;
                        readCgroup(pid, p, c);
                        row.kind = !windowOwners_.empty() && windowOwners_.count(pid) ? p.kindWithWindow : p.kindAlone;
                        row.session = p.sessionUnit;
                        row.efficiencyEligible = p.eligible;
                        row.appId = p.appId;
                        row.unitKey = p.unitKey;
                    }
                }
                row.openFiles = p.openFiles;
            }

            if (own && (reads & ReadGpu) && !p.drmFds.empty()) {
                readGpu(pid, p, now, c, devices, clientsSeen);
                row.hasGpu = p.haveGpu;
                row.gpuNs = p.gpuNs;
                row.gpuPercent = p.gpuPercent;
                row.gpuDevices = p.gpuDevices;
            }

            if (own && (reads & ReadIo) && (reads & ReadThreads) && percent >= 0) {
                row.energyImpact = energyImpact(percent, row.gpuPercent, row.wakeRate, row.readRate, row.writeRate);
                p.energySum += row.energyImpact * cpuSeconds;
                p.energyTime += cpuSeconds;
                row.averageEnergyImpact = p.energySum / p.energyTime;
                s.energyImpact = (s.energyImpact < 0 ? 0 : s.energyImpact) + row.energyImpact;
            }
        }
        s.rows.resize(used);
        s.kernel.cpuPercent = kernelKnown ? kernelPercent : -1;

        // AM68: an app unit runs in Efficiency Mode while its cgroup is idle (CPUWeight=idle) or its weight is 1, whoever set
        // it; each unit read once.
        if (reads & ReadEfficiency) {
            efficientUnits_.clear();
            for (ProcessRow &row : s.rows) {
                if (!row.own || !row.efficiencyEligible || row.unitKey == 0)
                    continue;
                auto [unit, first] = efficientUnits_.try_emplace(row.unitKey, false);
                if (first) {
                    const std::string dir = opt_.sysRoot + "/fs/cgroup" + procs_.find(row.pid)->second.cgroup + '/';
                    ++c.weightReads;
                    if (readFile(dir + "cpu.idle", buf_, true) && buf_.compare(0, 1, "1") == 0) {
                        unit->second = true;
                    } else {
                        ++c.weightReads;
                        unit->second = readFile(dir + "cpu.weight", buf_, true) && (buf_ == "1" || buf_ == "1\n");
                    }
                }
                row.efficient = unit->second;
            }
        }

        // Processes that ended: their kept descriptors close. Swept only when some did: the sweep touches every process's
        // entry again (2b, the Disk tab's cost).
        if (seenCount != procs_.size()) {
            for (auto it = procs_.begin(); it != procs_.end();) {
                if (it->second.seen == mark) {
                    ++it;
                    continue;
                }
                closeProc(it->second);
                it = procs_.erase(it);
            }
        }

        if (reads & ReadSockets) {
            ++c.sockDumps;
            tcp_.clear();
            // A failed dump changes nothing: the last good totals show again. Read as "every socket closed", it doubled
            // each process's totals once the sockets came back (review of 949fc98).
            const bool dumped = opt_.tcpDump(tcp_);
            // Sorted by inode and searched: no table built (and allocated) at every sample.
            std::sort(tcp_.begin(), tcp_.end(), [](const TcpCounters &a, const TcpCounters &b) { return a.inode < b.inode; });
            auto inDump = [this](uint64_t inode) -> const TcpCounters * {
                auto f = std::lower_bound(tcp_.begin(), tcp_.end(), inode,
                                          [](const TcpCounters &t, uint64_t i) { return t.inode < i; });
                return f != tcp_.end() && f->inode == inode ? &*f : nullptr;
            };
            // A socket counts for one process: the one that holds it and held it first. A socket that left a process's own
            // descriptors (handed to another process, or closed by it while another keeps it) stops counting for it there:
            // its share so far stays with it, and the next holder counts from that point (A7 of the 2026-11 audit: it kept
            // counting for the first process, and an inherited socket counted in both).
            const auto share = [](const Proc::LiveSocket &l, SocketTotals &into) {
                into.sent += l.now.bytesAcked - std::min(l.now.bytesAcked, l.base.bytesAcked);
                into.received += l.now.bytesReceived - std::min(l.now.bytesReceived, l.base.bytesReceived);
                into.segsOut += l.now.segsOut - std::min(l.now.segsOut, l.base.segsOut);
                into.segsIn += l.now.segsIn - std::min(l.now.segsIn, l.base.segsIn);
            };
            const auto holds = [](const Proc &p, uint64_t inode) {
                return std::find(p.sockets.begin(), p.sockets.end(), inode) != p.sockets.end();
            };
            std::unordered_map<uint64_t, TcpCounters> handedOver; // the counters a socket had when its holder let it go
            if (dumped) {
                for (ProcessRow &row : s.rows) {
                    if (!row.own)
                        continue;
                    Proc &p = procs_.find(row.pid)->second;
                    if (!p.scanned)
                        continue;
                    for (auto it = p.live.begin(); it != p.live.end();) {
                        const TcpCounters *t = inDump(it->first);
                        if (t && holds(p, it->first)) {
                            it->second.now = *t;
                            ++it;
                            continue;
                        }
                        // Closed (gone from the dump), or no longer this process's: its share so far stays with it.
                        share(it->second, p.closed);
                        if (t) {
                            handedOver[it->first] = it->second.now;
                            const auto owner = socketOwner_.find(it->first);
                            if (owner != socketOwner_.end() && owner->second == row.pid)
                                socketOwner_.erase(owner);
                        }
                        it = p.live.erase(it);
                    }
                }
                // Owners that are gone, or hold the socket no more, give it up.
                for (auto it = socketOwner_.begin(); it != socketOwner_.end();) {
                    const auto owner = procs_.find(it->second);
                    if (!inDump(it->first) || owner == procs_.end() || !holds(owner->second, it->first))
                        it = socketOwner_.erase(it);
                    else
                        ++it;
                }
                for (ProcessRow &row : s.rows) {
                    if (!row.own)
                        continue;
                    Proc &p = procs_.find(row.pid)->second;
                    if (!p.scanned)
                        continue;
                    for (uint64_t inode : p.sockets) {
                        const TcpCounters *t = inDump(inode);
                        if (!t || p.live.count(inode))
                            continue;
                        auto [owner, fresh] = socketOwner_.try_emplace(inode, row.pid);
                        if (!fresh && owner->second != row.pid)
                            continue; // another process holds it too and counts it
                        const auto before = handedOver.find(inode);
                        p.live[inode] = Proc::LiveSocket{*t, before != handedOver.end() ? before->second : TcpCounters{}};
                    }
                }
            }
            for (ProcessRow &row : s.rows) {
                if (!row.own)
                    continue;
                Proc &p = procs_.find(row.pid)->second;
                if (!p.scanned)
                    continue;
                row.hasNet = true;
                SocketTotals total = p.closed;
                for (const auto &[inode, l] : p.live)
                    share(l, total);
                row.tcpSent = total.sent;
                row.tcpReceived = total.received;
                row.tcpSegsOut = total.segsOut;
                row.tcpSegsIn = total.segsIn;
            }
        }

        // The GPUs: each engine's share summed over the user's clients (the compositor among them), capped at 100 (AM47).
        if (reads & ReadGpu) {
            std::map<std::string, std::map<std::string, double>> engines;
            for (const ProcessRow &row : s.rows) {
                if (!row.hasGpu)
                    continue;
                for (const auto &[k, share] : procs_.find(row.pid)->second.enginePercent) {
                    const size_t bar = k.find('|');
                    engines[k.substr(0, bar)][k.substr(bar + 1)] += share;
                }
            }
            for (auto &[pdev, dev] : devices) {
                for (const auto &[engine, share] : engines[pdev])
                    dev.engines.push_back({engine, std::min(share, 100.0)});
                nameGpu(dev, c);
                s.gpus.push_back(dev);
            }
        }
    }

    readSystem(reads, now, s.system, c);

    // AM29: User = the user's processes, System = every other non-idle tick, Idle = the rest (macOS's meaning, AD5). Only
    // when this sample and the previous one both read the processes and /proc/stat, so both deltas span the same interval;
    // otherwise the kernel's split stays (sharesByOwner false: the Dock's CPU graph while the window is hidden, AM62).
    if (listed && cpuDeltaTicks_ > 0 && lastProcessIndex_ + 1 == index_ && lastCpuIndex_ + 1 == index_
        && s.system.userShare >= 0) {
        const double busy = s.system.userShare + s.system.systemShare;
        const double user = std::min(busy, static_cast<double>(ownDelta) / static_cast<double>(cpuDeltaTicks_));
        s.system.userShare = user;
        s.system.systemShare = std::max(0.0, busy - user);
        s.system.sharesByOwner = true;
    }
    if (listed)
        lastProcessIndex_ = index_;
    if (listed && (reads & ReadMemory)) {
        lastMemoryTime_ = now;
        lastMemoryIndex_ = index_;
    }
    if ((reads & ReadSystemCpu) && s.system.cpuOk)
        lastCpuIndex_ = index_;

    c.keptFiles = kept_;
    ++index_;
    s.cpuMs = threadCpuMs() - cpu0;
    return s;
}

// AM47: the card whose `device` link ends in the pdev, and the name pci.ids gives its vendor and device ids. Read once per
// pdev: a GPU's ids do not change while it is there.
void Sampler::nameGpu(GpuDevice &dev, Counters &c)
{
    auto it = gpuNames_.find(dev.pdev);
    if (it == gpuNames_.end()) {
        GpuName name;
        const std::string drm = opt_.sysRoot + "/class/drm";
        if (DIR *d = opendir(drm.c_str())) {
            while (dirent *e = readdir(d)) {
                if (std::strncmp(e->d_name, "card", 4) != 0 || !isNumeric(e->d_name + 4)) // card1, not card1-eDP-1
                    continue;
                const std::string device = drm + '/' + e->d_name + "/device";
                char target[4096];
                const ssize_t n = readlink(device.c_str(), target, sizeof target - 1);
                if (n <= 0)
                    continue;
                target[n] = '\0';
                const char *slash = std::strrchr(target, '/');
                if (dev.pdev != (slash ? slash + 1 : target))
                    continue;
                name.card = std::atoi(e->d_name + 4);
                int vendor = -1, id = -1;
                ++c.systemReads;
                if (readFile(device + "/vendor", buf_))
                    vendor = parsePciId(buf_);
                ++c.systemReads;
                if (readFile(device + "/device", buf_))
                    id = parsePciId(buf_);
                std::string ids;
                if (vendor >= 0 && id >= 0 && !opt_.pciIds.empty() && readWhole(opt_.pciIds, ids)) {
                    ++c.systemReads;
                    name.model = gpuModelName(lookupPciIds(ids, vendor, id));
                }
                break;
            }
            closedir(d);
        }
        it = gpuNames_.emplace(dev.pdev, std::move(name)).first;
    }
    dev.card = it->second.card;
    dev.model = it->second.model;
}

void Sampler::readSystem(unsigned reads, double now, SystemSnapshot &out, Counters &c)
{
    // A3 of the 2026-11 audit: read here, on the sampler's thread, not by the window at each sample (a cpufreq driver may
    // wake each core to answer).
    if (reads & ReadSystemSpeed) {
        ++c.systemReads;
        out.speedGhz = meanCurrentGhz(opt_.sysRoot);
        out.uptime = readUptime(opt_.procRoot);
    }
    if (now - devicesListedAt_ >= 10.0 && (reads & (ReadSystemMemory | ReadSystemDisk))) {
        physicalDisks_.clear();
        zramDevices_.clear();
        const std::string block = opt_.sysRoot + "/block";
        if (DIR *d = opendir(block.c_str())) {
            while (dirent *e = readdir(d)) {
                if (e->d_name[0] == '.')
                    continue;
                const std::string name = e->d_name;
                if (name.compare(0, 4, "zram") == 0)
                    zramDevices_.push_back(name);
                else if (exists(block + '/' + name + "/device")) // whole physical disks: no loop, zram, dm or md (AM42)
                    physicalDisks_.push_back(name);
            }
            closedir(d);
        }
        std::sort(physicalDisks_.begin(), physicalDisks_.end());
        std::sort(zramDevices_.begin(), zramDevices_.end());
        devicesListedAt_ = now;
    }

    if (reads & ReadSystemCpu) {
        ++c.systemReads;
        CpuTimes total;
        std::vector<CpuTimes> per;
        if (readFile(opt_.procRoot + "/stat", buf_) && parseProcStat(buf_, total, per)) {
            out.cpuOk = true;
            cpuDeltaTicks_ = 0;
            if (haveCpu_ && total.total() > lastCpu_.total()) {
                cpuDeltaTicks_ = total.total() - lastCpu_.total();
                const double dt = static_cast<double>(cpuDeltaTicks_);
                const double idle = static_cast<double>(total.idleAll() - std::min(total.idleAll(), lastCpu_.idleAll())) / dt;
                const double busy = static_cast<double>(total.busy() - std::min(total.busy(), lastCpu_.busy())) / dt;
                out.idleShare = std::min(1.0, idle);
                // The kernel's split (user mode against kernel mode); sample() replaces it by macOS's meaning when it read
                // the processes (AM29).
                out.userShare = static_cast<double>((total.user + total.nice) - std::min(total.user + total.nice, lastCpu_.user + lastCpu_.nice)) / dt;
                out.systemShare = std::max(0.0, busy - out.userShare);
            }
            out.perCpuBusy.assign(per.size(), -1);
            out.perCpuUser.assign(per.size(), -1);
            if (haveCpu_ && per.size() == lastPerCpu_.size()) {
                for (size_t i = 0; i < per.size(); ++i) {
                    const uint64_t t = per[i].total(), t0 = lastPerCpu_[i].total();
                    if (t <= t0)
                        continue;
                    const double dt = static_cast<double>(t - t0);
                    out.perCpuBusy[i] = static_cast<double>(per[i].busy() - std::min(per[i].busy(), lastPerCpu_[i].busy())) / dt;
                    const uint64_t user = per[i].user + per[i].nice, user0 = lastPerCpu_[i].user + lastPerCpu_[i].nice;
                    out.perCpuUser[i] = std::min(out.perCpuBusy[i], static_cast<double>(user - std::min(user, user0)) / dt);
                }
            }
            lastCpu_ = total;
            lastPerCpu_ = per;
            haveCpu_ = true;
        }
        ++c.systemReads;
        if (readFile(opt_.procRoot + "/loadavg", buf_))
            out.tasks = parseLoadavgTasks(buf_);
    }

    if (reads & ReadSystemMemory) {
        ++c.systemReads;
        Meminfo m;
        if (readFile(opt_.procRoot + "/meminfo", buf_) && parseMeminfo(buf_, m)) {
            Pressure pr;
            ++c.systemReads;
            if (readFile(opt_.procRoot + "/pressure/memory", buf_))
                parsePressure(buf_, pr);
            ++c.systemReads;
            std::vector<SwapDevice> swaps;
            if (readFile(opt_.procRoot + "/swaps", buf_))
                swaps = parseSwaps(buf_);
            uint64_t zram = 0;
            for (const std::string &z : zramDevices_) {
                ++c.systemReads;
                uint64_t used = 0;
                if (readFile(opt_.sysRoot + "/block/" + z + "/mm_stat", buf_) && parseZramMemUsed(buf_, used))
                    zram += used;
            }
            MemorySummary &ms = out.memory;
            ms.ok = true;
            ms.physical = m.memTotal * 1024;
            ms.available = m.memAvailable * 1024;
            ms.used = (m.memTotal - std::min(m.memTotal, m.memAvailable)) * 1024;
            ms.compressed = zram;
            ms.wired = (m.sUnreclaim + m.kernelStack + m.pageTables + m.unevictable) * 1024;
            ms.app = ms.used > ms.wired + ms.compressed ? ms.used - ms.wired - ms.compressed : 0;
            ms.cached = (m.activeFile + m.inactiveFile) * 1024;
            ms.swapUsed = 0;
            ms.swapIsZramOnly = true;
            for (const SwapDevice &sw : swaps) {
                if (sw.zram())
                    continue;
                ms.swapUsed += sw.usedKb * 1024;
                ms.swapIsZramOnly = false;
            }
            ms.inUse = m.memTotal ? static_cast<double>(m.memTotal - std::min(m.memTotal, m.memAvailable)) / static_cast<double>(m.memTotal) : 0;
            ms.hasPressure = pr.ok;
            ms.level = pressureLevel(m, pr);
            ms.committed = m.committedAs * 1024;
            ms.commitLimit = m.commitLimit * 1024;
        }
    }

    if (reads & ReadSystemDisk) {
        ++c.systemReads;
        if (readFile(opt_.procRoot + "/diskstats", buf_)) {
            const double dt = lastDiskTime_ >= 0 ? now - lastDiskTime_ : 0;
            std::map<std::string, DiskStat> nowDisks;
            for (DiskStat &d : parseDiskstats(buf_, &physicalDisks_)) {
                DiskSnapshot ds;
                ds.name = d.name;
                ds.reads = d.reads;
                ds.writes = d.writes;
                ds.bytesRead = d.sectorsRead * 512;
                ds.bytesWritten = d.sectorsWritten * 512;
                auto last = lastDisks_.find(d.name);
                if (last != lastDisks_.end() && dt > 0) {
                    const DiskStat &l = last->second;
                    ds.readsPerSec = rate(d.reads, l.reads, dt);
                    ds.writesPerSec = rate(d.writes, l.writes, dt);
                    ds.readBytesPerSec = rate(d.sectorsRead * 512, l.sectorsRead * 512, dt);
                    ds.writeBytesPerSec = rate(d.sectorsWritten * 512, l.sectorsWritten * 512, dt);
                    if (d.ioTicksMs >= l.ioTicksMs)
                        ds.activeTime = std::min(1.0, static_cast<double>(d.ioTicksMs - l.ioTicksMs) / (dt * 1000.0));
                    const uint64_t ops = (d.reads + d.writes) - std::min(d.reads + d.writes, l.reads + l.writes);
                    const uint64_t ms = (d.readTicksMs + d.writeTicksMs) - std::min(d.readTicksMs + d.writeTicksMs, l.readTicksMs + l.writeTicksMs);
                    ds.responseMs = ops ? static_cast<double>(ms) / static_cast<double>(ops) : 0;
                }
                // Counters that went back: the disk restarted from zero (removed and added again between two samples).
                if (last != lastDisks_.end() && (d.reads < last->second.reads || d.writes < last->second.writes
                                                 || d.sectorsRead < last->second.sectorsRead || d.sectorsWritten < last->second.sectorsWritten))
                    retire(goneDisks_, last->second);
                out.diskTotal.reads += ds.reads;
                out.diskTotal.writes += ds.writes;
                out.diskTotal.bytesRead += ds.bytesRead;
                out.diskTotal.bytesWritten += ds.bytesWritten;
                nowDisks[d.name] = d;
                out.disks.push_back(std::move(ds));
            }
            for (const auto &[name, l] : lastDisks_) {
                if (!nowDisks.count(name))
                    retire(goneDisks_, l);
            }
            out.diskTotal.reads += goneDisks_.reads;
            out.diskTotal.writes += goneDisks_.writes;
            out.diskTotal.bytesRead += goneDisks_.sectorsRead * 512;
            out.diskTotal.bytesWritten += goneDisks_.sectorsWritten * 512;
            if (dt > 0 && !out.disks.empty()) {
                out.diskTotal.readsPerSec = out.diskTotal.writesPerSec = out.diskTotal.readBytesPerSec = out.diskTotal.writeBytesPerSec = 0;
                for (const DiskSnapshot &ds : out.disks) {
                    if (ds.readsPerSec < 0) // a disk new since the last sample has no rate yet: the others still count
                        continue;
                    out.diskTotal.readsPerSec += ds.readsPerSec;
                    out.diskTotal.writesPerSec += ds.writesPerSec;
                    out.diskTotal.readBytesPerSec += ds.readBytesPerSec;
                    out.diskTotal.writeBytesPerSec += ds.writeBytesPerSec;
                }
            }
            out.diskTotal.name = "total";
            lastDisks_ = std::move(nowDisks);
            lastDiskTime_ = now;
        }
    }

    if (reads & ReadSystemNet) {
        ++c.systemReads;
        if (readFile(opt_.procRoot + "/net/dev", buf_)) {
            const double dt = lastNetTime_ >= 0 ? now - lastNetTime_ : 0;
            std::map<std::string, NetDev> nowNet;
            // A total rate as soon as one interface has one, as for the disks: an interface new since the last sample (a
            // container's veth, a VPN) has none yet, and left the whole total without a value for one sample (a gap in the graph).
            bool rates = false;
            for (NetDev &n : parseNetDev(buf_)) {
                if (n.name == "lo")
                    continue;
                NetSnapshot ns;
                ns.name = n.name;
                ns.packetsIn = n.rxPackets;
                ns.packetsOut = n.txPackets;
                ns.bytesIn = n.rxBytes;
                ns.bytesOut = n.txBytes;
                auto last = lastNet_.find(n.name);
                if (last != lastNet_.end() && dt > 0) {
                    ns.packetsInPerSec = rate(n.rxPackets, last->second.rxPackets, dt);
                    ns.packetsOutPerSec = rate(n.txPackets, last->second.txPackets, dt);
                    ns.bytesInPerSec = rate(n.rxBytes, last->second.rxBytes, dt);
                    ns.bytesOutPerSec = rate(n.txBytes, last->second.txBytes, dt);
                    rates = true;
                }
                if (last != lastNet_.end() && (n.rxPackets < last->second.rxPackets || n.txPackets < last->second.txPackets
                                               || n.rxBytes < last->second.rxBytes || n.txBytes < last->second.txBytes))
                    retire(goneNet_, last->second);
                out.netTotal.packetsIn += ns.packetsIn;
                out.netTotal.packetsOut += ns.packetsOut;
                out.netTotal.bytesIn += ns.bytesIn;
                out.netTotal.bytesOut += ns.bytesOut;
                nowNet[n.name] = n;
                out.interfaces.push_back(std::move(ns));
            }
            for (const auto &[name, l] : lastNet_) {
                if (!nowNet.count(name))
                    retire(goneNet_, l);
            }
            out.netTotal.packetsIn += goneNet_.rxPackets;
            out.netTotal.packetsOut += goneNet_.txPackets;
            out.netTotal.bytesIn += goneNet_.rxBytes;
            out.netTotal.bytesOut += goneNet_.txBytes;
            if (rates) {
                out.netTotal.packetsInPerSec = out.netTotal.packetsOutPerSec = out.netTotal.bytesInPerSec = out.netTotal.bytesOutPerSec = 0;
                for (const NetSnapshot &ns : out.interfaces) {
                    out.netTotal.packetsInPerSec += std::max(0.0, ns.packetsInPerSec);
                    out.netTotal.packetsOutPerSec += std::max(0.0, ns.packetsOutPerSec);
                    out.netTotal.bytesInPerSec += std::max(0.0, ns.bytesInPerSec);
                    out.netTotal.bytesOutPerSec += std::max(0.0, ns.bytesOutPerSec);
                }
            }
            out.netTotal.name = "total";
            lastNet_ = std::move(nowNet);
            lastNetTime_ = now;
        }
    }
}

} // namespace activity
