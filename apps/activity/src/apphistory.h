// App History (Windows 11's, ADR-0038 g, AD31; spec AM67): each app's resource use over a period, from systemd's records
// of the units that ended (`journalctl --user -o json MESSAGE_ID=ae8f7b866b0347b9af31fe1c80b127c0`, the user manager's
// "unit resources" record: USER_UNIT, CPU_USAGE_NSEC, MEMORY_PEAK) and the live app units' cgroups. Read when the window
// opens and when the period changes; nothing is kept or deleted (the journal is the system's record).
#pragma once

#include <QAbstractListModel>
#include <QByteArray>
#include <QDateTime>
#include <QLocale>
#include <QPointer>
#include <QProcess>
#include <QString>

#include <functional>
#include <vector>

namespace activity
{

// SD_MESSAGE_UNIT_RESOURCES (systemd's sd-messages.h).
inline constexpr const char *kUnitResourcesMessage = "ae8f7b866b0347b9af31fe1c80b127c0";
// The most journal output read (about 50 000 records, newest first); a longer answer loses its oldest records.
constexpr qint64 kHistoryOutputMax = 16 * 1024 * 1024;

// One record: a unit that ended, what it used and when (µs since the epoch).
struct UnitRecord {
    QString unit;
    quint64 cpuNs = 0;
    bool hasCpu = false;
    quint64 memoryPeak = 0;
    bool hasMemory = false;
    qint64 timeUs = 0;
};

// journalctl's JSON lines: the records of a user unit uwsm named for one launch (AM65's names); anything else (another
// message, a system unit, a value that is not a number, a broken line) is skipped.
std::vector<UnitRecord> parseUnitRecords(const QByteArray &jsonLines);

// A live app unit (its cgroup now): it counts as a launch used now.
struct LiveUnit {
    QString unit;
    quint64 cpuNs = 0;
    quint64 memoryPeak = 0;
};

// One app's row: AM65's name of the launch (a desktop id or a command's basename), its totals.
struct AppUsage {
    QString app;
    quint64 cpuNs = 0;
    quint64 memoryPeak = 0;
    int launches = 0;
    qint64 lastUsedUs = 0;
};

// The rows, one per app: CPU time summed, the highest memory peak, a launch per unit (a live unit's record, if one comes
// in the same read, counts once), the last record's time or `nowUs` for a live unit. Records before `sinceUs` are left out.
std::vector<AppUsage> aggregateUsage(const std::vector<UnitRecord> &records, const std::vector<LiveUnit> &live, qint64 sinceUs,
                                     qint64 nowUs);

// cpu.stat's usage_usec in ns, and memory.peak, of a cgroup's text; false when the file has no such line.
bool parseCpuStatUsage(const QByteArray &text, quint64 &ns);

class AppHistory : public QAbstractListModel
{
    Q_OBJECT
    // "12h" (the default), "7d" or "30d".
    Q_PROPERTY(QString period READ period WRITE setPeriod NOTIFY periodChanged)
    Q_PROPERTY(QVariantList periods READ periods CONSTANT)
    // "Resource use since <date> for <user>"; "" while nothing was read.
    Q_PROPERTY(QString caption READ caption NOTIFY loaded)
    // journalctl could not be run or failed (AM67: "Usage history isn't available." and nothing else).
    Q_PROPERTY(bool unavailable READ unavailable NOTIFY loaded)
    Q_PROPERTY(bool loading READ loading NOTIFY loaded)
    Q_PROPERTY(QString sortKey READ sortKey NOTIFY sorted)
    Q_PROPERTY(bool sortDescending READ sortDescending NOTIFY sorted)
    Q_PROPERTY(int count READ count NOTIFY loaded)

public:
    enum Role { NameRole = Qt::UserRole + 1, IconRole, CpuRole, MemoryRole, LaunchesRole, LastUsedRole, AccessibleRole };

    struct App {
        QString name;
        QString icon;
    };
    // `resolve`: an app's name and icon from AM65's name; `live`: called on the window's thread, it gives the reader of
    // the live units (what it needs copied in), which runs with `resolve` on the worker (setWorker).
    using Resolve = std::function<App(const QString &app)>;
    using LiveReader = std::function<std::vector<LiveUnit>()>;
    using Live = std::function<LiveReader()>;
    AppHistory(Resolve resolve, Live live, QObject *parent = nullptr);
    ~AppHistory() override;

    QString period() const { return m_period; }
    void setPeriod(const QString &period);
    // The period remembered (AM74), set at start: nothing is read until the window opens.
    void restorePeriod(const QString &period);
    QVariantList periods() const;
    QString caption() const { return m_caption; }
    bool unavailable() const { return m_unavailable; }
    bool loading() const { return m_process != nullptr || m_computing; }
    QString sortKey() const { return m_sortKey; }
    bool sortDescending() const { return m_descending; }
    int count() const { return static_cast<int>(m_rows.size()); }
    void setLocale(const QLocale &locale);
    // The login name for the caption.
    void setUser(const QString &user) { m_user = user; }

    // Reads again (the window opened; the period changed).
    Q_INVOKABLE void reload();
    // A header clicked: by its column, again reverses ("name", "cpu", "memory", "launches", "lastUsed").
    Q_INVOKABLE void sortBy(const QString &key);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    // Tests: the journal's answer instead of journalctl's (`ok` false: it failed), and the clock.
    void setAnswer(const QByteArray &output, bool ok, qint64 nowUs);
    // The thread the journal's answer is parsed on, with the live units read and the apps resolved (A2 of the 2026-11
    // audit: up to 16 MiB of JSON lines were parsed on the window's thread inside a model reset). Without one (the tests),
    // on the caller's thread.
    void setWorker(QObject *worker) { m_worker = worker; }

signals:
    void periodChanged();
    void loaded();
    void sorted();

private:
    struct Row {
        AppUsage usage;
        App app;
    };
    void finish(const QByteArray &output, bool ok, qint64 nowUs);
    void install(std::vector<Row> rows, bool ok);
    void sortRows();
    qint64 periodSeconds() const;

    QString m_user;
    Resolve m_resolve;
    Live m_live;
    QString m_period = QStringLiteral("12h");
    QString m_caption;
    bool m_unavailable = false;
    QString m_sortKey = QStringLiteral("cpu");
    bool m_descending = true;
    QLocale m_locale;
    std::vector<Row> m_rows;
    QPointer<QProcess> m_process;
    QObject *m_worker = nullptr;
    quint64 m_generation = 0; // the read whose answer counts (a newer reload makes an older answer go unused)
    bool m_computing = false;
    QByteArray m_output;
    qint64 m_sinceUs = 0;
};

} // namespace activity
