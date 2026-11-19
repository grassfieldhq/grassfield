// The Performance window (Windows 11's, spec AM66) and the small windows of step 5 (CPU Usage, CPU History, GPU History,
// AM71, AM72): each resource's history from the samples, a sidebar of resources with a small graph and their value, the
// selected one's large graph and details, each logical processor's share and history, each GPU's. The facts that do not
// change (the processors' topology and caches, a disk's capacity, type and model, an interface's kind) are read once; the
// processors' speed, the uptime, the addresses and a Wi-Fi network's name and signal when the window shows them.
#pragma once

#include "machine.h"
#include "sampler.h"
#include "summary.h"

#include <QLocale>
#include <QObject>
#include <QSet>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace activity
{

// "d:hh:mm:ss" (Windows' Up Time), the days without padding.
QString formatUptime(double seconds);

class Performance : public QObject
{
    Q_OBJECT
    // The sidebar, in order (CPU, Memory, each physical disk, each interface but lo, each GPU with clients): {key, kind,
    // title, subtitle, value, graph} with `graph` as Graph.qml draws it ({style, max, series: [{values, color}]}).
    Q_PROPERTY(QVariantList resources READ resources NOTIFY changed)
    // The selected resource's key ("cpu" by default).
    Q_PROPERTY(QString selected READ selected WRITE setSelected NOTIFY changed)
    // Its title, subtitle (a model's name), its graphs [{title, graph}], its figures [{label, value}], and for Memory the
    // composition bar [{label, fraction, color}].
    Q_PROPERTY(QVariantMap detail READ detail NOTIFY changed)
    // CPU's pop-up: "overall" (one graph) or "logical" (one small graph per logical processor).
    Q_PROPERTY(QString cpuMode READ cpuMode WRITE setCpuMode NOTIFY changed)
    // AM71, AM72: each logical processor {busy, user, system, graph} (current shares and its history, System and User
    // stacked), in /proc/stat's order.
    Q_PROPERTY(QVariantList processors READ processors NOTIFY changed)
    // AM72: each GPU with clients {title, graph}.
    Q_PROPERTY(QVariantList gpus READ gpus NOTIFY changed)
    // Graphs keep this many samples (Tokens.activityHistorySamples, set by the window).
    Q_PROPERTY(int capacity READ capacity WRITE setCapacity NOTIFY changed)

public:
    explicit Performance(std::string procRoot, std::string sysRoot, QObject *parent = nullptr);

    QVariantList resources() const { return m_resources; }
    QString selected() const { return m_selected; }
    void setSelected(const QString &key);
    QVariantMap detail() const { return m_detail; }
    QString cpuMode() const { return m_cpuMode; }
    void setCpuMode(const QString &mode);
    QVariantList processors() const { return m_processors; }
    QVariantList gpus() const { return m_gpuList; }
    int capacity() const { return static_cast<int>(m_capacity); }
    void setCapacity(int capacity);
    void setLocale(const QLocale &locale);
    // The GPUs' names (AM47), by drm-pdev.
    void setGpuNames(const QHash<QString, QString> &names) { m_gpuNames = names; }

    // A window that shows this (`kind`: "performance", "cpuUsage", "cpuHistory", "gpuHistory") is on screen or not: the
    // texts and graphs are built only while one is.
    void setShown(const QString &kind, bool shown);
    bool anyShown() const { return !m_shown.isEmpty(); }
    bool shown(const QString &kind) const { return m_shown.contains(kind); }
    // The processors' speed and the uptime are shown (Performance on CPU): the samples read them (ReadSystemSpeed).
    bool wantsSpeed() const { return m_shown.contains(QStringLiteral("performance")) && m_selected == QLatin1String("cpu"); }

    // A sample: the histories take it; the texts follow while a window shows them.
    void take(const Snapshot &snapshot);
    // AM72: View > Clear CPU History.
    Q_INVOKABLE void clearCpuHistory();

    // Tests and the Wi-Fi name: the network's name of a Wi-Fi interface (by default NetworkManager on the system bus,
    // read-only); "" when none is known.
    // The answer comes later, never on the window's thread's time (review of 5bfd4419: the system bus asked without
    // blocking).
    using WifiName = std::function<void(const QString &interface, std::function<void(const QString &name)> done)>;
    void setWifiName(WifiName name) { m_wifiName = std::move(name); }
    static void networkManagerSsid(const QString &interface, std::function<void(const QString &name)> done);

signals:
    void changed();

private:
    struct Pair {
        History a, b;
    };
    struct Gpu {
        History overall;
        std::map<std::string, History> engines;
    };
    void rebuild();
    // A Wi-Fi interface selected: its network's name asked once (the answer rebuilds the details).
    void askWifiName(const std::string &interface);
    QVariantMap cpuDetail() const;
    QVariantMap memoryDetail() const;
    QVariantMap diskDetail(const std::string &name) const;
    QVariantMap netDetail(const std::string &name) const;
    QVariantMap gpuDetail(const std::string &pdev) const;
    QVariantMap graph(const QString &style, double max, const QVariantList &series) const;
    QString percentText(double fraction) const;
    QString rateText(double bytesPerSec) const;
    const DiskFacts &diskFacts(const std::string &name) const;
    const std::string &kindOf(const std::string &interface) const;
    QString netTitle(const std::string &interface) const;
    QString gpuTitle(const std::string &pdev, int index) const;

    std::string m_procRoot, m_sysRoot;
    size_t m_capacity = 120;
    QLocale m_locale;
    QSet<QString> m_shown;
    QString m_selected = QStringLiteral("cpu");
    QString m_cpuMode = QStringLiteral("overall");
    WifiName m_wifiName;
    QHash<QString, QString> m_gpuNames;

    // Histories.
    History m_cpuSystem, m_cpuUser, m_memory;
    std::vector<History> m_perCpuSystem, m_perCpuUser;
    std::map<std::string, Pair> m_diskRates; // read, written bytes/s
    std::map<std::string, History> m_diskActive;
    std::map<std::string, Pair> m_netRates; // received, sent bytes/s
    std::map<std::string, Gpu> m_gpus;

    // The last sample, for the texts.
    SystemSnapshot m_system;
    std::vector<GpuDevice> m_gpuDevices;
    bool m_haveSample = false;

    // Facts read once, and those of the window's last look.
    mutable std::optional<CpuFacts> m_cpuFacts;
    mutable std::map<std::string, DiskFacts> m_diskFacts;
    mutable std::map<std::string, std::string> m_netKinds;
    double m_speedGhz = -1;
    double m_uptime = -1;
    mutable QString m_wifi;    // the selected Wi-Fi interface's network
    mutable QString m_wifiFor; // its interface
    mutable int m_signal = 0;

    QVariantList m_resources, m_processors, m_gpuList;
    QVariantMap m_detail;
};

} // namespace activity
