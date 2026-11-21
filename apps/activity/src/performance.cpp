#include "performance.h"

#include "format.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusObjectPath>
#include <QDBusVariant>
#include <QFile>
#include <QPointer>

#include <algorithm>
#include <cmath>
#include <iterator>
#include <set>

namespace activity
{

namespace
{

const QString kStacked = QStringLiteral("stacked"), kMirrored = QStringLiteral("mirrored"), kArea = QStringLiteral("area");

QVariantMap series(const History &history, const QString &color)
{
    return QVariantMap{{QStringLiteral("values"), history.toList()}, {QStringLiteral("color"), color}};
}

QVariantMap figure(const QString &label, const QString &value)
{
    return QVariantMap{{QStringLiteral("label"), label}, {QStringLiteral("value"), value}};
}

double scaleFor(double peak)
{
    return peak > 0 ? peak * 1.1 : 1.0;
}

} // namespace

QString formatUptime(double seconds)
{
    if (seconds < 0)
        return dash();
    const qint64 s = static_cast<qint64>(seconds);
    return QStringLiteral("%1:%2:%3:%4")
        .arg(s / 86400)
        .arg((s / 3600) % 24, 2, 10, QLatin1Char('0'))
        .arg((s / 60) % 60, 2, 10, QLatin1Char('0'))
        .arg(s % 60, 2, 10, QLatin1Char('0'));
}

Performance::Performance(std::string procRoot, std::string sysRoot, QObject *parent)
    : QObject(parent)
    , m_procRoot(std::move(procRoot))
    , m_sysRoot(std::move(sysRoot))
    , m_wifiName(&Performance::networkManagerSsid)
{
    m_cpuSystem.setCapacity(m_capacity);
    m_cpuUser.setCapacity(m_capacity);
    m_memory.setCapacity(m_capacity);
}

void Performance::setCapacity(int capacity)
{
    const size_t c = static_cast<size_t>(std::max(1, capacity));
    if (c == m_capacity)
        return;
    m_capacity = c;
    for (History *h : {&m_cpuSystem, &m_cpuUser, &m_memory})
        h->setCapacity(c);
    for (History &h : m_perCpuSystem)
        h.setCapacity(c);
    for (History &h : m_perCpuUser)
        h.setCapacity(c);
    for (auto &[name, p] : m_diskRates) {
        p.a.setCapacity(c);
        p.b.setCapacity(c);
    }
    for (auto &[name, h] : m_diskActive)
        h.setCapacity(c);
    for (auto &[name, p] : m_netRates) {
        p.a.setCapacity(c);
        p.b.setCapacity(c);
    }
    for (auto &[pdev, g] : m_gpus) {
        g.overall.setCapacity(c);
        for (auto &[engine, h] : g.engines)
            h.setCapacity(c);
    }
    rebuild();
}

void Performance::setLocale(const QLocale &locale)
{
    m_locale = locale;
    rebuild();
}

void Performance::setSelected(const QString &key)
{
    if (key == m_selected)
        return;
    m_selected = key;
    m_wifiFor.clear(); // a Wi-Fi interface's name is asked again when it is selected
    rebuild();
}

void Performance::setCpuMode(const QString &mode)
{
    if ((mode != QLatin1String("overall") && mode != QLatin1String("logical")) || mode == m_cpuMode)
        return;
    m_cpuMode = mode;
    rebuild();
}

void Performance::setShown(const QString &kind, bool shown)
{
    const bool before = m_shown.contains(kind);
    if (shown == before)
        return;
    if (shown)
        m_shown.insert(kind);
    else
        m_shown.remove(kind);
    if (shown) {
        m_wifiFor.clear();
        rebuild();
    }
}

void Performance::clearCpuHistory()
{
    for (History &h : m_perCpuSystem)
        h = History();
    for (History &h : m_perCpuUser)
        h = History();
    for (History &h : m_perCpuSystem)
        h.setCapacity(m_capacity);
    for (History &h : m_perCpuUser)
        h.setCapacity(m_capacity);
    rebuild();
}

void Performance::take(const Snapshot &snapshot)
{
    const SystemSnapshot &s = snapshot.system;
    if (s.cpuOk) {
        const bool known = s.userShare >= 0 && s.systemShare >= 0;
        m_cpuSystem.add(known ? s.systemShare : -1);
        m_cpuUser.add(known ? s.userShare : -1);
        if (m_perCpuSystem.size() != s.perCpuBusy.size()) { // processors came or went: their histories start again
            m_perCpuSystem.assign(s.perCpuBusy.size(), History());
            m_perCpuUser.assign(s.perCpuBusy.size(), History());
            for (size_t i = 0; i < s.perCpuBusy.size(); ++i) {
                m_perCpuSystem[i].setCapacity(m_capacity);
                m_perCpuUser[i].setCapacity(m_capacity);
            }
        }
        for (size_t i = 0; i < s.perCpuBusy.size(); ++i) {
            const double busy = s.perCpuBusy[i];
            const double user = i < s.perCpuUser.size() ? s.perCpuUser[i] : -1;
            m_perCpuUser[i].add(busy >= 0 && user >= 0 ? user : -1);
            m_perCpuSystem[i].add(busy >= 0 && user >= 0 ? std::max(0.0, busy - user) : -1);
        }
    }
    if (s.memory.ok)
        m_memory.add(s.memory.inUse);
    std::set<std::string> disks, nets, gpus;
    for (const DiskSnapshot &d : s.disks) {
        disks.insert(d.name);
        Pair &p = m_diskRates[d.name];
        History &active = m_diskActive[d.name];
        p.a.setCapacity(m_capacity);
        p.b.setCapacity(m_capacity);
        active.setCapacity(m_capacity);
        p.a.add(d.readBytesPerSec);
        p.b.add(d.writeBytesPerSec);
        active.add(d.activeTime);
    }
    for (const NetSnapshot &n : s.interfaces) {
        nets.insert(n.name);
        Pair &p = m_netRates[n.name];
        p.a.setCapacity(m_capacity);
        p.b.setCapacity(m_capacity);
        p.a.add(n.bytesInPerSec);
        p.b.add(n.bytesOutPerSec);
    }
    for (const GpuDevice &g : snapshot.gpus) {
        gpus.insert(g.pdev);
        Gpu &gpu = m_gpus[g.pdev];
        gpu.overall.setCapacity(m_capacity);
        double top = 0;
        std::set<std::string> engines;
        for (const GpuEngine &e : g.engines) {
            History &h = gpu.engines[e.name];
            h.setCapacity(m_capacity);
            h.add(std::min(1.0, e.percent / 100.0));
            engines.insert(e.name);
            top = std::max(top, e.percent / 100.0);
        }
        for (auto &[name, h] : gpu.engines) {
            if (!engines.count(name))
                h.add(0);
        }
        gpu.overall.add(std::min(1.0, top));
    }
    // A GPU without clients this sample idles; a disk or an interface that went away is forgotten.
    for (auto &[pdev, gpu] : m_gpus) {
        if (gpus.count(pdev))
            continue;
        gpu.overall.add(0);
        for (auto &[name, h] : gpu.engines)
            h.add(0);
    }
    if (s.cpuOk || s.memory.ok) {
        const auto forget = [](auto &map, const std::set<std::string> &keep) {
            for (auto it = map.begin(); it != map.end();)
                it = keep.count(it->first) ? std::next(it) : map.erase(it);
        };
        forget(m_diskRates, disks);
        forget(m_diskActive, disks);
        forget(m_netRates, nets);
    }
    m_system = s;
    // A GPU without clients this sample keeps its driver (its clients named it) and shows no memory in use.
    std::map<std::string, std::string> drivers;
    for (const GpuDevice &g : m_gpuDevices)
        drivers[g.pdev] = g.driver;
    m_gpuDevices = snapshot.gpus;
    for (const auto &[pdev, gpu] : m_gpus) {
        if (gpus.count(pdev))
            continue;
        GpuDevice idle;
        idle.pdev = pdev;
        idle.driver = drivers[pdev];
        m_gpuDevices.push_back(idle);
    }
    std::sort(m_gpuDevices.begin(), m_gpuDevices.end(), [](const GpuDevice &a, const GpuDevice &b) { return a.pdev < b.pdev; });
    m_haveSample = true;
    if (!m_shown.isEmpty()) {
        // Read by the sampler (ReadSystemSpeed, asked while Performance shows CPU: wantsSpeed()), never here.
        if (s.speedGhz > 0 || s.uptime >= 0) {
            m_speedGhz = s.speedGhz;
            m_uptime = s.uptime;
        }
        rebuild();
    }
}

QVariantMap Performance::graph(const QString &style, double max, const QVariantList &list) const
{
    return QVariantMap{{QStringLiteral("style"), style}, {QStringLiteral("max"), max}, {QStringLiteral("series"), list}};
}

QString Performance::percentText(double fraction) const
{
    return fraction < 0 ? dash() : m_locale.toString(std::lround(std::clamp(fraction, 0.0, 1.0) * 100)) + QStringLiteral("%");
}

QString Performance::rateText(double bytesPerSec) const
{
    return bytesPerSec < 0 ? dash() : tr("%1/s").arg(formatBytes(bytesPerSec, m_locale));
}

const DiskFacts &Performance::diskFacts(const std::string &name) const
{
    auto it = m_diskFacts.find(name);
    if (it == m_diskFacts.end())
        it = m_diskFacts.emplace(name, readDiskFacts(m_sysRoot, name)).first;
    return it->second;
}

const std::string &Performance::kindOf(const std::string &interface) const
{
    auto it = m_netKinds.find(interface);
    if (it == m_netKinds.end())
        it = m_netKinds.emplace(interface, netKind(m_sysRoot, interface)).first;
    return it->second;
}

QString Performance::netTitle(const std::string &interface) const
{
    const std::string &kind = kindOf(interface);
    if (kind == "wifi")
        return tr("Wi-Fi");
    if (kind == "ethernet")
        return tr("Ethernet");
    return QString::fromStdString(interface);
}

QString Performance::gpuTitle(const std::string &pdev, int index) const
{
    Q_UNUSED(pdev);
    return tr("GPU %1").arg(index);
}

void Performance::rebuild()
{
    if (m_shown.isEmpty() || !m_haveSample) {
        emit changed();
        return;
    }
    const SystemSnapshot &s = m_system;
    const double busy = s.userShare >= 0 && s.systemShare >= 0 ? s.userShare + s.systemShare : -1;
    QVariantList resources;
    const auto resource = [](const QString &key, const QString &kind, const QString &title, const QString &subtitle,
                             const QString &value, const QVariantMap &g) {
        return QVariantMap{{QStringLiteral("key"), key},           {QStringLiteral("kind"), kind},
                           {QStringLiteral("title"), title},       {QStringLiteral("subtitle"), subtitle},
                           {QStringLiteral("value"), value},       {QStringLiteral("graph"), g}};
    };
    const QVariantMap cpuGraph = graph(kStacked, 1, {series(m_cpuSystem, QStringLiteral("activityGraphSystem")),
                                                     series(m_cpuUser, QStringLiteral("activityGraphUser"))});
    resources << resource(QStringLiteral("cpu"), QStringLiteral("cpu"), tr("CPU"),
                          m_speedGhz > 0 ? tr("%1 GHz").arg(m_locale.toString(m_speedGhz, 'f', 2)) : QString(), percentText(busy), cpuGraph);
    const MemorySummary &m = s.memory;
    const QVariantMap memoryGraph = graph(kArea, 1, {series(m_memory, QStringLiteral("activityGraphUser"))});
    resources << resource(QStringLiteral("memory"), QStringLiteral("memory"), tr("Memory"),
                          m.ok ? tr("%1 of %2").arg(formatBytes(static_cast<double>(m.used), m_locale), formatBytes(static_cast<double>(m.physical), m_locale)) : QString(),
                          m.ok ? percentText(m.inUse) : dash(), memoryGraph);
    int diskIndex = 0;
    for (const DiskSnapshot &d : s.disks) {
        const DiskFacts &facts = diskFacts(d.name);
        const QString type = facts.rotational == 0 ? tr("SSD") : facts.rotational == 1 ? tr("HDD") : QString();
        resources << resource(QStringLiteral("disk:") + QString::fromStdString(d.name), QStringLiteral("disk"),
                              tr("Disk %1 (%2)").arg(diskIndex++).arg(QString::fromStdString(d.name)), type, percentText(d.activeTime),
                              graph(kArea, 1, {series(m_diskActive[d.name], QStringLiteral("activityGraphRead"))}));
    }
    for (const NetSnapshot &n : s.interfaces) {
        const Pair &p = m_netRates[n.name];
        resources << resource(QStringLiteral("net:") + QString::fromStdString(n.name), QStringLiteral("network"), netTitle(n.name),
                              QString::fromStdString(n.name),
                              tr("Send %1 · Receive %2").arg(rateText(n.bytesOutPerSec), rateText(n.bytesInPerSec)),
                              graph(kMirrored, scaleFor(std::max(p.a.peak(), p.b.peak())),
                                    {series(p.a, QStringLiteral("activityGraphIn")), series(p.b, QStringLiteral("activityGraphOut"))}));
    }
    int gpuIndex = 0;
    QVariantList gpuList;
    for (const GpuDevice &g : m_gpuDevices) {
        const Gpu &gpu = m_gpus[g.pdev];
        const QString title = gpuTitle(g.pdev, gpuIndex++);
        const QString model = m_gpuNames.value(QString::fromStdString(g.pdev), QString::fromStdString(g.pdev));
        const double now = gpu.overall.values().empty() ? -1 : gpu.overall.values().back();
        const QVariantMap g1 = graph(kArea, 1, {series(gpu.overall, QStringLiteral("activityGraphUser"))});
        resources << resource(QStringLiteral("gpu:") + QString::fromStdString(g.pdev), QStringLiteral("gpu"), title, model, percentText(now), g1);
        gpuList << QVariantMap{{QStringLiteral("title"), model}, {QStringLiteral("graph"), g1}};
    }
    m_resources = resources;
    m_gpuList = gpuList;

    // Each logical processor's two series (about 15 000 values on a 64-thread machine) are boxed only while a window draws
    // them: CPU Usage, CPU History, Performance's "Logical processors" (A3 of the 2026-11 audit).
    const bool perCpu = m_shown.contains(QStringLiteral("cpuUsage")) || m_shown.contains(QStringLiteral("cpuHistory"))
        || (m_shown.contains(QStringLiteral("performance")) && m_cpuMode == QLatin1String("logical"));
    QVariantList processors;
    for (size_t i = 0; perCpu && i < m_perCpuSystem.size(); ++i) {
        const double b = i < s.perCpuBusy.size() ? s.perCpuBusy[i] : -1;
        const double u = i < s.perCpuUser.size() ? s.perCpuUser[i] : -1;
        processors << QVariantMap{{QStringLiteral("busy"), b},
                                  {QStringLiteral("user"), u},
                                  {QStringLiteral("system"), b >= 0 && u >= 0 ? std::max(0.0, b - u) : -1.0},
                                  {QStringLiteral("graph"), graph(kStacked, 1, {series(m_perCpuSystem[i], QStringLiteral("activityGraphSystem")),
                                                                                series(m_perCpuUser[i], QStringLiteral("activityGraphUser"))})}};
    }
    m_processors = processors;

    if (m_shown.contains(QStringLiteral("performance"))) {
        // A selection that went away (a disk unplugged): back to CPU.
        bool known = false;
        for (const QVariant &r : std::as_const(m_resources))
            known = known || r.toMap().value(QStringLiteral("key")).toString() == m_selected;
        if (!known)
            m_selected = QStringLiteral("cpu");
        const std::string rest = m_selected.section(QLatin1Char(':'), 1).toStdString();
        if (m_selected == QLatin1String("cpu"))
            m_detail = cpuDetail();
        else if (m_selected == QLatin1String("memory"))
            m_detail = memoryDetail();
        else if (m_selected.startsWith(QLatin1String("disk:")))
            m_detail = diskDetail(rest);
        else if (m_selected.startsWith(QLatin1String("net:"))) {
            askWifiName(rest);
            m_detail = netDetail(rest);
        } else
            m_detail = gpuDetail(rest);
    }
    emit changed();
}

QVariantMap Performance::cpuDetail() const
{
    if (!m_cpuFacts)
        m_cpuFacts = readCpuFacts(m_sysRoot, m_procRoot);
    const CpuFacts &f = *m_cpuFacts;
    const SystemSnapshot &s = m_system;
    const double busy = s.userShare >= 0 && s.systemShare >= 0 ? s.userShare + s.systemShare : -1;
    const auto ghz = [this](double v) { return v > 0 ? tr("%1 GHz").arg(m_locale.toString(v, 'f', 2)) : dash(); };
    const auto cache = [this](uint64_t bytes) { return bytes > 0 ? formatBytes(static_cast<double>(bytes), m_locale) : dash(); };
    QVariantList figures;
    figures << figure(tr("Utilization:"), percentText(busy)) << figure(tr("Speed:"), ghz(m_speedGhz));
    if (f.baseGhz > 0)
        figures << figure(tr("Base Speed:"), ghz(f.baseGhz));
    figures << figure(tr("Processes:"), m_locale.toString(s.processes))
            << figure(tr("Threads:"), s.tasks >= 0 ? m_locale.toString(s.tasks) : dash())
            << figure(tr("Up Time:"), formatUptime(m_uptime))
            << figure(tr("Sockets:"), m_locale.toString(f.sockets)) << figure(tr("Cores:"), m_locale.toString(f.cores))
            << figure(tr("Logical Processors:"), m_locale.toString(f.logical)) << figure(tr("L1 Cache:"), cache(f.l1))
            << figure(tr("L2 Cache:"), cache(f.l2)) << figure(tr("L3 Cache:"), cache(f.l3));
    QVariantList graphs;
    graphs << QVariantMap{{QStringLiteral("title"), tr("% Utilization")},
                          {QStringLiteral("graph"), graph(kStacked, 1, {series(m_cpuSystem, QStringLiteral("activityGraphSystem")),
                                                                        series(m_cpuUser, QStringLiteral("activityGraphUser"))})}};
    return QVariantMap{{QStringLiteral("key"), QStringLiteral("cpu")},
                       {QStringLiteral("title"), tr("CPU")},
                       {QStringLiteral("subtitle"), QString::fromStdString(f.model)},
                       {QStringLiteral("graphs"), graphs},
                       {QStringLiteral("logical"), m_cpuMode == QLatin1String("logical")},
                       {QStringLiteral("figures"), figures}};
}

QVariantMap Performance::memoryDetail() const
{
    const MemorySummary &m = m_system.memory;
    const auto bytes = [this](uint64_t b) { return formatBytes(static_cast<double>(b), m_locale); };
    QVariantList figures;
    QVariantList bar;
    if (m.ok) {
        figures << figure(tr("In Use:"), bytes(m.used)) << figure(tr("Available:"), bytes(m.available))
                << figure(tr("Committed:"), tr("%1 of %2").arg(bytes(m.committed), bytes(m.commitLimit)))
                << figure(tr("Cached:"), bytes(m.cached)) << figure(tr("Compressed:"), bytes(m.compressed))
                << figure(tr("Swap Used:"), bytes(m.swapUsed));
        const double total = static_cast<double>(std::max<uint64_t>(1, m.physical));
        const uint64_t inUse = m.used > m.compressed ? m.used - m.compressed : m.used;
        const uint64_t taken = std::min<uint64_t>(m.physical, inUse + m.compressed + m.cached);
        const auto part = [&](const QString &label, uint64_t b, const QString &color) {
            return QVariantMap{{QStringLiteral("label"), label}, {QStringLiteral("fraction"), static_cast<double>(b) / total},
                               {QStringLiteral("color"), color}};
        };
        // Four colours apart (the graphs' tested ones), Free the plate's.
        bar << part(tr("In Use"), inUse, QStringLiteral("activityGraphUser")) << part(tr("Compressed"), m.compressed, QStringLiteral("activityPressureYellow"))
            << part(tr("Cached"), m.cached, QStringLiteral("activityGraphBattery")) << part(tr("Free"), m.physical - taken, QString());
    }
    QVariantList graphs;
    graphs << QVariantMap{{QStringLiteral("title"), tr("Memory Usage")},
                          {QStringLiteral("graph"), graph(kArea, 1, {series(m_memory, QStringLiteral("activityGraphUser"))})}};
    return QVariantMap{{QStringLiteral("key"), QStringLiteral("memory")},
                       {QStringLiteral("title"), tr("Memory")},
                       {QStringLiteral("subtitle"), m.ok ? formatBytes(static_cast<double>(m.physical), m_locale) : QString()},
                       {QStringLiteral("graphs"), graphs},
                       {QStringLiteral("figures"), figures},
                       {QStringLiteral("bar"), bar}};
}

QVariantMap Performance::diskDetail(const std::string &name) const
{
    const DiskFacts &facts = diskFacts(name);
    const DiskSnapshot *d = nullptr;
    int index = 0;
    for (const DiskSnapshot &x : m_system.disks) {
        if (x.name == name) {
            d = &x;
            break;
        }
        ++index;
    }
    QVariantList figures;
    if (d) {
        figures << figure(tr("Active Time:"), percentText(d->activeTime)) << figure(tr("Read Speed:"), rateText(d->readBytesPerSec))
                << figure(tr("Write Speed:"), rateText(d->writeBytesPerSec))
                << figure(tr("Average Response Time:"), d->responseMs >= 0 ? tr("%1 ms").arg(m_locale.toString(d->responseMs, 'f', 1)) : dash());
    }
    figures << figure(tr("Capacity:"), facts.capacity > 0 ? formatBytes(static_cast<double>(facts.capacity), m_locale) : dash())
            << figure(tr("Type:"), facts.rotational == 0 ? tr("SSD") : facts.rotational == 1 ? tr("HDD") : dash());
    const auto active = m_diskActive.find(name);
    const auto rates = m_diskRates.find(name);
    QVariantList graphs;
    if (active != m_diskActive.end())
        graphs << QVariantMap{{QStringLiteral("title"), tr("Active Time")},
                              {QStringLiteral("graph"), graph(kArea, 1, {series(active->second, QStringLiteral("activityGraphRead"))})}};
    if (rates != m_diskRates.end())
        graphs << QVariantMap{{QStringLiteral("title"), tr("Disk Transfer Rate")},
                              {QStringLiteral("graph"), graph(kMirrored, scaleFor(std::max(rates->second.a.peak(), rates->second.b.peak())),
                                                              {series(rates->second.a, QStringLiteral("activityGraphRead")),
                                                               series(rates->second.b, QStringLiteral("activityGraphWrite"))})}};
    return QVariantMap{{QStringLiteral("key"), QStringLiteral("disk:") + QString::fromStdString(name)},
                       {QStringLiteral("title"), tr("Disk %1 (%2)").arg(index).arg(QString::fromStdString(name))},
                       {QStringLiteral("subtitle"), QString::fromStdString(facts.model)},
                       {QStringLiteral("graphs"), graphs},
                       {QStringLiteral("figures"), figures}};
}

QVariantMap Performance::netDetail(const std::string &name) const
{
    const QString interface = QString::fromStdString(name);
    const bool wifi = kindOf(name) == "wifi";
    if (wifi) {
        QFile f(QString::fromStdString(m_procRoot + "/net/wireless"));
        m_signal = f.open(QIODevice::ReadOnly) ? wirelessSignal(f.read(64 * 1024).toStdString(), name) : 0;
    }
    const NetSnapshot *n = nullptr;
    for (const NetSnapshot &x : m_system.interfaces) {
        if (x.name == name)
            n = &x;
    }
    QVariantList figures;
    if (n)
        figures << figure(tr("Send:"), rateText(n->bytesOutPerSec)) << figure(tr("Receive:"), rateText(n->bytesInPerSec));
    figures << figure(tr("Interface:"), interface)
            << figure(tr("Connection Type:"), wifi ? tr("Wi-Fi") : kindOf(name) == "ethernet" ? tr("Ethernet") : tr("Other"));
    if (wifi) {
        figures << figure(tr("Network:"), m_wifi.isEmpty() ? dash() : m_wifi)
                << figure(tr("Signal:"), m_signal != 0 ? tr("%1 dBm").arg(m_signal) : dash());
    }
    const Addresses addresses = interfaceAddresses(name);
    QStringList v4, v6;
    for (const std::string &a : addresses.v4)
        v4 << QString::fromStdString(a);
    for (const std::string &a : addresses.v6)
        v6 << QString::fromStdString(a);
    figures << figure(tr("IPv4 Address:"), v4.isEmpty() ? dash() : v4.join(QLatin1Char('\n')))
            << figure(tr("IPv6 Address:"), v6.isEmpty() ? dash() : v6.join(QLatin1Char('\n')));
    QVariantList graphs;
    const auto rates = m_netRates.find(name);
    if (rates != m_netRates.end())
        graphs << QVariantMap{{QStringLiteral("title"), tr("Throughput")},
                              {QStringLiteral("graph"), graph(kMirrored, scaleFor(std::max(rates->second.a.peak(), rates->second.b.peak())),
                                                              {series(rates->second.a, QStringLiteral("activityGraphIn")),
                                                               series(rates->second.b, QStringLiteral("activityGraphOut"))})}};
    return QVariantMap{{QStringLiteral("key"), QStringLiteral("net:") + interface},
                       {QStringLiteral("title"), netTitle(name)},
                       {QStringLiteral("subtitle"), wifi && !m_wifi.isEmpty() ? m_wifi : interface},
                       {QStringLiteral("graphs"), graphs},
                       {QStringLiteral("figures"), figures}};
}

QVariantMap Performance::gpuDetail(const std::string &pdev) const
{
    int index = 0;
    const GpuDevice *device = nullptr;
    for (const GpuDevice &g : m_gpuDevices) {
        if (g.pdev == pdev) {
            device = &g;
            break;
        }
        ++index;
    }
    const auto it = m_gpus.find(pdev);
    QVariantList graphs, figures;
    if (it != m_gpus.end()) {
        for (const auto &[engine, h] : it->second.engines) {
            graphs << QVariantMap{{QStringLiteral("title"), QString::fromStdString(engine)},
                                  {QStringLiteral("graph"), graph(kArea, 1, {series(h, QStringLiteral("activityGraphUser"))})}};
        }
    }
    if (device) {
        for (const auto &[region, bytes] : device->memoryRegions)
            figures << figure(tr("Memory (%1):").arg(QString::fromStdString(region)), formatBytes(static_cast<double>(bytes), m_locale));
        figures << figure(tr("Driver:"), device->driver.empty() ? dash() : QString::fromStdString(device->driver));
    }
    figures << figure(tr("Location:"), QString::fromStdString(pdev));
    return QVariantMap{{QStringLiteral("key"), QStringLiteral("gpu:") + QString::fromStdString(pdev)},
                       {QStringLiteral("title"), gpuTitle(pdev, index)},
                       {QStringLiteral("subtitle"), m_gpuNames.value(QString::fromStdString(pdev), QString::fromStdString(pdev))},
                       {QStringLiteral("graphs"), graphs},
                       {QStringLiteral("figures"), figures}};
}

void Performance::askWifiName(const std::string &name)
{
    const QString interface = QString::fromStdString(name);
    if (kindOf(name) != "wifi" || m_wifiFor == interface)
        return; // asked once each time the interface is selected or the window shows
    m_wifiFor = interface;
    m_wifi.clear();
    if (!m_wifiName)
        return;
    QPointer<Performance> self(this);
    m_wifiName(interface, [self, interface](const QString &answer) {
        // Always later, on this object's thread: the details are built again with it.
        QMetaObject::invokeMethod(
            self.data(),
            [self, interface, answer] {
                if (!self || self->m_wifiFor != interface)
                    return;
                self->m_wifi = answer;
                self->rebuild();
            },
            Qt::QueuedConnection);
    });
}

namespace
{

// One asynchronous property read on the system bus; `done` gets the value, or an invalid QVariant.
void getProperty(const QString &path, const QString &interface, const QString &property, std::function<void(const QVariant &)> done)
{
    const QString service = QStringLiteral("org.freedesktop.NetworkManager");
    QDBusMessage call = QDBusMessage::createMethodCall(service, path, QStringLiteral("org.freedesktop.DBus.Properties"),
                                                       QStringLiteral("Get"));
    call << interface << property;
    auto *watcher = new QDBusPendingCallWatcher(QDBusConnection::systemBus().asyncCall(call, 1000));
    QObject::connect(watcher, &QDBusPendingCallWatcher::finished, watcher, [watcher, done](QDBusPendingCallWatcher *) {
        const QDBusPendingReply<QDBusVariant> reply = *watcher;
        done(reply.isError() ? QVariant() : reply.value().variant());
        watcher->deleteLater();
    });
}

} // namespace

void Performance::networkManagerSsid(const QString &interface, std::function<void(const QString &)> done)
{
    // Read-only, on the system bus, never blocking: the device of that interface, its active access point, the point's
    // SSID, each asked when the last answered.
    QDBusConnection bus = QDBusConnection::systemBus();
    if (!bus.isConnected()) {
        done(QString());
        return;
    }
    const QString service = QStringLiteral("org.freedesktop.NetworkManager");
    QDBusMessage call = QDBusMessage::createMethodCall(service, QStringLiteral("/org/freedesktop/NetworkManager"), service,
                                                       QStringLiteral("GetDeviceByIpIface"));
    call << interface;
    auto *watcher = new QDBusPendingCallWatcher(bus.asyncCall(call, 1000));
    QObject::connect(watcher, &QDBusPendingCallWatcher::finished, watcher, [watcher, done, service](QDBusPendingCallWatcher *) {
        const QDBusPendingReply<QDBusObjectPath> device = *watcher;
        watcher->deleteLater();
        if (device.isError()) {
            done(QString());
            return;
        }
        getProperty(device.value().path(), service + QStringLiteral(".Device.Wireless"), QStringLiteral("ActiveAccessPoint"),
                    [done, service](const QVariant &point) {
                        const QString path = point.value<QDBusObjectPath>().path();
                        if (path.isEmpty() || path == QLatin1String("/")) {
                            done(QString());
                            return;
                        }
                        getProperty(path, service + QStringLiteral(".AccessPoint"), QStringLiteral("Ssid"), [done](const QVariant &ssid) {
                            // An SSID is bytes: shown as UTF-8, its control characters dropped (plain text).
                            QString name = QString::fromUtf8(ssid.toByteArray());
                            name.removeIf([](QChar c) { return c.category() == QChar::Other_Control || c.category() == QChar::Other_Format; });
                            done(name.left(64));
                        });
                    });
    });
}

} // namespace activity
