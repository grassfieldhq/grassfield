#include "apphistory.h"

#include "format.h"
#include "units.h"

#include <QCollator>
#include <QCoreApplication>
#include <QHash>
#include <QMetaObject>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QTimer>

#include <algorithm>

namespace activity
{

namespace
{

// A journal field holding a decimal number (journalctl writes every value as a string).
bool numberField(const QJsonObject &o, const char *key, quint64 &out)
{
    const QJsonValue v = o.value(QLatin1String(key));
    if (!v.isString())
        return false;
    bool ok = false;
    out = v.toString().toULongLong(&ok);
    return ok;
}

// How long a read may take before the history counts as not available.
constexpr int kReadTimeoutMs = 30000;

} // namespace

std::vector<UnitRecord> parseUnitRecords(const QByteArray &jsonLines)
{
    std::vector<UnitRecord> out;
    qsizetype from = 0;
    while (from < jsonLines.size()) {
        qsizetype end = jsonLines.indexOf('\n', from);
        if (end < 0)
            end = jsonLines.size();
        const QByteArray line = jsonLines.mid(from, end - from);
        from = end + 1;
        const QJsonDocument doc = QJsonDocument::fromJson(line);
        if (!doc.isObject())
            continue;
        const QJsonObject o = doc.object();
        if (o.value(QLatin1String("MESSAGE_ID")).toString() != QLatin1String(kUnitResourcesMessage) && o.contains(QLatin1String("MESSAGE_ID")))
            continue;
        const QJsonValue unit = o.value(QLatin1String("USER_UNIT"));
        if (!unit.isString() || !parseAppUnit(unit.toString().toStdString()))
            continue;
        UnitRecord r;
        r.unit = unit.toString();
        quint64 time = 0;
        if (!numberField(o, "__REALTIME_TIMESTAMP", time))
            continue;
        r.timeUs = static_cast<qint64>(time);
        r.hasCpu = numberField(o, "CPU_USAGE_NSEC", r.cpuNs);
        r.hasMemory = numberField(o, "MEMORY_PEAK", r.memoryPeak);
        if (!r.hasCpu && !r.hasMemory)
            continue;
        out.push_back(r);
    }
    return out;
}

std::vector<AppUsage> aggregateUsage(const std::vector<UnitRecord> &records, const std::vector<LiveUnit> &live, qint64 sinceUs,
                                     qint64 nowUs)
{
    QHash<QString, AppUsage> apps;
    std::vector<QString> order;
    QSet<QString> units;
    const auto entry = [&](const QString &unit) -> AppUsage * {
        const std::optional<AppUnit> parsed = parseAppUnit(unit.toStdString());
        if (!parsed)
            return nullptr;
        const QString app = QString::fromStdString(parsed->name);
        auto it = apps.find(app);
        if (it == apps.end()) {
            it = apps.insert(app, AppUsage{app});
            order.push_back(app);
        }
        return &*it;
    };
    for (const UnitRecord &r : records) {
        if (r.timeUs < sinceUs || units.contains(r.unit))
            continue;
        AppUsage *a = entry(r.unit);
        if (!a)
            continue;
        units.insert(r.unit);
        a->cpuNs += r.cpuNs;
        a->memoryPeak = std::max(a->memoryPeak, r.memoryPeak);
        ++a->launches;
        a->lastUsedUs = std::max(a->lastUsedUs, r.timeUs);
    }
    for (const LiveUnit &l : live) {
        if (units.contains(l.unit))
            continue; // it ended while the journal was read: its record counts
        AppUsage *a = entry(l.unit);
        if (!a)
            continue;
        units.insert(l.unit);
        a->cpuNs += l.cpuNs;
        a->memoryPeak = std::max(a->memoryPeak, l.memoryPeak);
        ++a->launches;
        a->lastUsedUs = nowUs;
    }
    std::vector<AppUsage> out;
    out.reserve(order.size());
    for (const QString &app : order)
        out.push_back(apps.value(app));
    return out;
}

bool parseCpuStatUsage(const QByteArray &text, quint64 &ns)
{
    for (const QByteArray &line : text.split('\n')) {
        if (!line.startsWith("usage_usec "))
            continue;
        bool ok = false;
        const quint64 us = line.mid(11).trimmed().toULongLong(&ok);
        if (!ok)
            return false;
        ns = us * 1000;
        return true;
    }
    return false;
}

AppHistory::AppHistory(Resolve resolve, Live live, QObject *parent)
    : QAbstractListModel(parent)
    , m_resolve(std::move(resolve))
    , m_live(std::move(live))
{
}

AppHistory::~AppHistory()
{
    if (m_process) {
        m_process->disconnect(this);
        m_process->kill();
        m_process->waitForFinished(1000);
    }
}

QVariantList AppHistory::periods() const
{
    return {QVariantMap{{QStringLiteral("key"), QStringLiteral("12h")}, {QStringLiteral("title"), tr("Last 12 Hours")}},
            QVariantMap{{QStringLiteral("key"), QStringLiteral("7d")}, {QStringLiteral("title"), tr("Last 7 Days")}},
            QVariantMap{{QStringLiteral("key"), QStringLiteral("30d")}, {QStringLiteral("title"), tr("Last 30 Days")}}};
}

qint64 AppHistory::periodSeconds() const
{
    if (m_period == QLatin1String("7d"))
        return 7 * 86400;
    if (m_period == QLatin1String("30d"))
        return 30 * 86400;
    return 12 * 3600;
}

void AppHistory::setPeriod(const QString &period)
{
    if (period == m_period
        || (period != QLatin1String("12h") && period != QLatin1String("7d") && period != QLatin1String("30d")))
        return;
    m_period = period;
    emit periodChanged();
    reload();
}

void AppHistory::restorePeriod(const QString &period)
{
    if (period == QLatin1String("12h") || period == QLatin1String("7d") || period == QLatin1String("30d"))
        m_period = period;
}

void AppHistory::setLocale(const QLocale &locale)
{
    m_locale = locale;
}

void AppHistory::reload()
{
    if (m_process) {
        m_process->disconnect(this);
        m_process->kill();
        m_process->deleteLater();
        m_process = nullptr;
    }
    const qint64 nowUs = QDateTime::currentMSecsSinceEpoch() * 1000;
    m_sinceUs = nowUs - periodSeconds() * 1000000;
    m_output.clear();
    auto *process = new QProcess(this);
    m_process = process;
    process->setProgram(QStringLiteral("journalctl"));
    // Newest first (--reverse): an answer cut at kHistoryOutputMax loses the oldest records, not the last days'.
    process->setArguments({QStringLiteral("--user"), QStringLiteral("--output=json"), QStringLiteral("--no-pager"), QStringLiteral("--quiet"),
                           QStringLiteral("--reverse"),
                           QStringLiteral("--output-fields=MESSAGE_ID,USER_UNIT,CPU_USAGE_NSEC,MEMORY_PEAK"),
                           QStringLiteral("--since=@") + QString::number(m_sinceUs / 1000000),
                           QStringLiteral("MESSAGE_ID=") + QLatin1String(kUnitResourcesMessage)});
    process->setStandardInputFile(QProcess::nullDevice());
    process->setStandardErrorFile(QProcess::nullDevice());
    connect(process, &QProcess::readyReadStandardOutput, this, [this, process] {
        m_output += process->readAllStandardOutput();
        if (m_output.size() > kHistoryOutputMax) { // newest first: what was read is kept, cut at a whole line
            m_output.truncate(m_output.lastIndexOf('\n', kHistoryOutputMax) + 1);
            process->disconnect(this);
            process->kill();
            process->deleteLater();
            m_process = nullptr;
            finish(m_output, true, QDateTime::currentMSecsSinceEpoch() * 1000);
        }
    });
    connect(process, &QProcess::finished, this, [this, process](int code, QProcess::ExitStatus status) {
        m_output += process->readAllStandardOutput();
        process->deleteLater();
        m_process = nullptr;
        finish(m_output, status == QProcess::NormalExit && code == 0, QDateTime::currentMSecsSinceEpoch() * 1000);
    });
    connect(process, &QProcess::errorOccurred, this, [this, process](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart)
            return;
        process->deleteLater();
        m_process = nullptr;
        finish({}, false, 0);
    });
    QTimer::singleShot(kReadTimeoutMs, process, [this, process] {
        process->disconnect(this);
        process->kill();
        process->deleteLater();
        if (m_process == process) {
            m_process = nullptr;
            finish({}, false, 0);
        }
    });
    process->start();
    emit loaded(); // loading
}

void AppHistory::setAnswer(const QByteArray &output, bool ok, qint64 nowUs)
{
    if (m_process) {
        m_process->disconnect(this);
        m_process->kill();
        m_process->waitForFinished(1000);
        delete m_process;
    }
    m_sinceUs = nowUs - periodSeconds() * 1000000;
    finish(output, ok, nowUs);
}

void AppHistory::finish(const QByteArray &output, bool ok, qint64 nowUs)
{
    const quint64 generation = ++m_generation;
    // The journal's text is not kept once handed over (up to 16 MiB).
    m_output.clear();
    m_output.squeeze();
    const LiveReader live = ok && m_live ? m_live() : LiveReader{};
    const Resolve resolve = m_resolve;
    const qint64 sinceUs = m_sinceUs;
    const auto compute = [output, ok, nowUs, live, resolve, sinceUs] {
        std::vector<Row> rows;
        if (!ok)
            return rows;
        const std::vector<AppUsage> usage = aggregateUsage(parseUnitRecords(output), live ? live() : std::vector<LiveUnit>{}, sinceUs, nowUs);
        rows.reserve(usage.size());
        for (const AppUsage &u : usage)
            rows.push_back(Row{u, resolve ? resolve(u.app) : App{u.app, QString()}});
        return rows;
    };
    if (!m_worker) {
        install(compute(), ok);
        return;
    }
    m_computing = true;
    QMetaObject::invokeMethod(
        m_worker,
        [this, compute, generation, ok] {
            std::vector<Row> rows = compute();
            QMetaObject::invokeMethod(
                this,
                [this, rows = std::move(rows), generation, ok]() mutable {
                    if (generation != m_generation)
                        return; // read again meanwhile
                    m_computing = false;
                    install(std::move(rows), ok);
                },
                Qt::QueuedConnection);
        },
        Qt::QueuedConnection);
    emit loaded(); // loading
}

void AppHistory::install(std::vector<Row> rows, bool ok)
{
    // Only the rows' exchange happens inside the reset: they were made before (on the worker).
    beginResetModel();
    m_rows = std::move(rows);
    m_unavailable = !ok;
    m_caption.clear();
    if (ok) {
        m_caption = tr("Resource use since %1 for %2")
                        .arg(m_locale.toString(QDateTime::fromMSecsSinceEpoch(m_sinceUs / 1000), QLocale::ShortFormat), m_user);
        sortRows();
    }
    endResetModel();
    emit loaded();
}

void AppHistory::sortBy(const QString &key)
{
    static const QStringList keys{QStringLiteral("name"), QStringLiteral("cpu"), QStringLiteral("memory"), QStringLiteral("launches"),
                                  QStringLiteral("lastUsed")};
    if (!keys.contains(key))
        return;
    if (key == m_sortKey) {
        m_descending = !m_descending;
    } else {
        m_sortKey = key;
        m_descending = key != QLatin1String("name"); // names A to Z first, figures largest first (AM10)
    }
    beginResetModel();
    sortRows();
    endResetModel();
    emit sorted();
}

void AppHistory::sortRows()
{
    QCollator collator(m_locale);
    collator.setNumericMode(true);
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    const auto value = [this](const Row &r) -> double {
        if (m_sortKey == QLatin1String("memory"))
            return static_cast<double>(r.usage.memoryPeak);
        if (m_sortKey == QLatin1String("launches"))
            return r.usage.launches;
        if (m_sortKey == QLatin1String("lastUsed"))
            return static_cast<double>(r.usage.lastUsedUs);
        return static_cast<double>(r.usage.cpuNs);
    };
    std::stable_sort(m_rows.begin(), m_rows.end(), [&](const Row &a, const Row &b) {
        if (m_sortKey == QLatin1String("name")) {
            const int c = collator.compare(a.app.name, b.app.name);
            return m_descending ? c > 0 : c < 0;
        }
        const double va = value(a), vb = value(b);
        if (va != vb)
            return m_descending ? va > vb : va < vb;
        return collator.compare(a.app.name, b.app.name) < 0;
    });
}

int AppHistory::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : count();
}

QHash<int, QByteArray> AppHistory::roleNames() const
{
    return {{NameRole, "name"},         {IconRole, "icon"},         {CpuRole, "cpuTime"},          {MemoryRole, "memoryPeak"},
            {LaunchesRole, "launches"}, {LastUsedRole, "lastUsed"}, {AccessibleRole, "accessibleText"}};
}

QVariant AppHistory::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= count())
        return {};
    const Row &r = m_rows[static_cast<size_t>(index.row())];
    const auto cpu = [&] { return formatCpuTime(static_cast<double>(r.usage.cpuNs) / 1e9, m_locale); };
    const auto memory = [&] { return r.usage.memoryPeak > 0 ? formatBytes(static_cast<double>(r.usage.memoryPeak), m_locale) : QStringLiteral("—"); };
    const auto launches = [&] { return formatCount(r.usage.launches, m_locale); };
    const auto lastUsed = [&] {
        return m_locale.toString(QDateTime::fromMSecsSinceEpoch(r.usage.lastUsedUs / 1000), QLocale::ShortFormat);
    };
    switch (role) {
    case NameRole:
    case Qt::DisplayRole:
        return r.app.name;
    case IconRole:
        return r.app.icon;
    case CpuRole:
        return cpu();
    case MemoryRole:
        return memory();
    case LaunchesRole:
        return launches();
    case LastUsedRole:
        return lastUsed();
    case AccessibleRole:
        return tr("%1, CPU Time %2, Memory Peak %3, Launches %4, Last Used %5").arg(r.app.name, cpu(), memory(), launches(), lastUsed());
    default:
        return {};
    }
}

} // namespace activity
