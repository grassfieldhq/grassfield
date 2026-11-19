#include "activityapp.h"

#include "appscope.h"
#include "autoappearance.h"
#include "chromecaps.h"
#include "runmode.h"
#include "shortcutstyle.h"
#include "shownwatch.h"
#include "translationloader.h"
#include "signals.h"
#include "units.h"

#include <QClipboard>
#include <QDBusMessage>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QTime>
#include <QWindow>

#include <pwd.h>

#include <algorithm>

namespace activity {

namespace {

constexpr qint64 kConfigMax = 1024 * 1024; // grassfield.json (ADR-0020: a real one is a few KiB)

QString configFile()
{
    return grassfield::apps::runmode::configDir() + QStringLiteral("/grassfield.json");
}

const Tab kTabs[] = {Tab::Cpu, Tab::Memory, Tab::Energy, Tab::Disk, Tab::Network};

QString tabTitle(Tab tab)
{
    switch (tab) {
    case Tab::Cpu:
        return QCoreApplication::translate("ActivityApp", "CPU");
    case Tab::Memory:
        return QCoreApplication::translate("ActivityApp", "Memory");
    case Tab::Energy:
        return QCoreApplication::translate("ActivityApp", "Energy");
    case Tab::Disk:
        return QCoreApplication::translate("ActivityApp", "Disk");
    case Tab::Network:
        return QCoreApplication::translate("ActivityApp", "Network");
    }
    return QString();
}

} // namespace

ActivityApp::ActivityApp(Options options, QString statePath, QObject *parent)
    : QObject(parent)
    , m_options(std::move(options))
    , m_statePath(std::move(statePath))
    , m_state(readState(m_statePath))
    , m_actions(m_options.procRoot)
    , m_efficiency(m_options.procRoot)
    , m_appHistory(
          [this](const QString &app) {
              // AM65's naming, as the Apps sub-groups: the entry of that id, else the one whose Exec runs it, else the name.
              // Called on the sampler's thread (AppHistory::setWorker), with the worker's own entries.
              const DesktopApp entry = m_worker->resolveApp(app);
              return AppHistory::App{entry.name.isEmpty() ? app : entry.name, entry.icon};
          },
          [this] { return liveUnits(); })
    , m_performance(m_options.procRoot, m_options.sysRoot)
    , m_inspectors(m_options.procRoot, m_options.uid, m_options.clockTicks)
    , m_runtimeFolder(runtimeFolder())
    , m_projection(m_runtimeFolder, m_options.procRoot)
{
    qRegisterMetaType<SnapshotPtr>();
    qRegisterMetaType<AppNamesPtr>();
    m_worker = new SamplerWorker(m_options);
    m_worker->moveToThread(&m_thread);
    connect(&m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
    connect(this, &ActivityApp::sampleRequested, m_worker, &SamplerWorker::sample, Qt::QueuedConnection);
    connect(m_worker, &SamplerWorker::sampled, this, &ActivityApp::takeSnapshot, Qt::QueuedConnection);
    m_thread.setObjectName(QStringLiteral("activity-sampler"));
    m_thread.start(QThread::LowPriority);
    // A2: App History's journal is parsed, its live units read and its apps resolved there too.
    m_appHistory.setWorker(m_worker);

    // AM57: Inspect's reads run on the sampler's thread too (AD35), between its samples.
    m_inspectors.setWorker(m_worker);
    m_inspectors.setMainActions(&m_actions);
    m_inspectors.setInterval(m_state.interval);
    m_inspectors.setNames(
        [this](int pid, quint64 start) {
            const TableRow *row = m_table.processRow(pid, start);
            return row ? row->name : QString();
        },
        [this](uint32_t uid) { return userName(uid); });
    connect(&m_inspectors, &Inspectors::opened, this, &ActivityApp::inspectRequested);
    m_inspectors.setHangs([this](int pid, quint64 start) {
        // AM57: "—" until there is a projection (step 3), then the times it marked the process since the app opened.
        if (!m_projection.projection().valid)
            return -1;
        const auto it = m_hangs.constFind(pid);
        return it != m_hangs.constEnd() && (it->start == 0 || it->start == start) ? it->count : 0;
    });
    m_appHistory.setUser(userName(m_options.uid));
    // AM74: App History's period is remembered.
    m_appHistory.restorePeriod(m_state.appHistoryPeriod);
    connect(&m_appHistory, &AppHistory::periodChanged, this, [this] {
        m_state.appHistoryPeriod = m_appHistory.period();
        scheduleSave();
    });
    connect(&m_projection, &ProjectionWatch::changed, this, &ActivityApp::applyProjection);
    applyProjection();
    // Never qGuiApp: a static cast, undefined where the application is a QCoreApplication (the backend's tests; UBSan).
    if (auto *gui = qobject_cast<QGuiApplication *>(QCoreApplication::instance()))
        connect(gui, &QGuiApplication::focusWindowChanged, this, &ActivityApp::focusWindowChanged);

    m_timer.setInterval(m_state.interval * 1000);
    connect(&m_timer, &QTimer::timeout, this, [this] {
        if (m_quick) { // the second sample after a gap came one second after the first: back to the interval
            m_quick = false;
            m_timer.setInterval(m_state.interval * 1000);
        }
        requestSample();
    });
    m_saveTimer.setSingleShot(true);
    m_saveTimer.setInterval(500);
    connect(&m_saveTimer, &QTimer::timeout, this, [this] { writeState(m_statePath, m_state); });
    connect(&m_inhibitors, &InhibitorWatch::changed, this, [this] {
        if (m_state.tab == Tab::Energy)
            requestSample();
    });
    connect(&m_battery, &BatteryWatch::changed, this, [this] { m_summary.setBattery(m_battery.state()); });
    connect(&m_table, &ProcessTable::selectionChanged, this, &ActivityApp::updateActionTargets);
    // AM68: a unit that took its weight shows it at the next sample, taken now; AM76: asked once the window is up.
    connect(&m_efficiency, &Efficiency::finished, this, [this](const QString &error) {
        if (error.isEmpty())
            requestSample();
    });
    QTimer::singleShot(0, this, [this] { m_efficiency.setSupported(Efficiency::userManagerPresent()); });
    m_summary.setDiskMode(m_state.diskGraph);
    m_summary.setNetworkMode(m_state.networkGraph);

    // Appearance follows grassfield.json (read only), like every Grassfield surface (as Preview and the Store).
    m_macDevice = grassfield::apps::macDeviceHere();
    const QString file = configFile();
    const QString dir = QFileInfo(file).absolutePath();
    if (QFileInfo(dir).isDir())
        m_watcher.addPath(dir);
    if (QFileInfo::exists(file))
        m_watcher.addPath(file);
    // The shell's capabilities file (chromecaps.h: the minimize light) in Grassfield's runtime folder.
    grassfield::apps::watchCapabilities(m_watcher);
    const auto reread = [this] {
        const QString f = configFile();
        if (QFileInfo::exists(f) && !m_watcher.files().contains(f))
            m_watcher.addPath(f);
        grassfield::apps::watchCapabilities(m_watcher);
        readAppearance();
    };
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, reread);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, reread);
    readAppearance();
    m_autoTimer.setInterval(grassfield::apps::kAutoRecheckMs);
    connect(&m_autoTimer, &QTimer::timeout, this, [this] {
        if (m_autoAppearance)
            readAppearance();
    });
    m_autoTimer.start();

    m_table.setView(m_state.view);
    applyTab();
    m_summary.setTab(m_state.tab);
}

ActivityApp::~ActivityApp()
{
    // AM62: the tile shows the icon again once the app has quit; only a file this app wrote is removed (review of 5bfd4419).
    if (m_tileWritten)
        removeDockTile(m_runtimeFolder);
    if (m_saveTimer.isActive()) {
        m_saveTimer.stop();
        writeState(m_statePath, m_state);
    }
    m_thread.quit();
    m_thread.wait();
}

bool ActivityApp::devSession() const
{
    return grassfield::apps::runmode::dev();
}

const TabState &ActivityApp::tabState() const
{
    return m_state.tabs.at(m_state.tab);
}

TabState &ActivityApp::tabState()
{
    return m_state.tabs[m_state.tab];
}

void ActivityApp::applyTab()
{
    const TabState &t = tabState();
    m_table.setColumns(t.columns);
    m_table.setSort(t.sort, t.descending);
    emit columnsChanged();
}

void ActivityApp::setTab(const QString &key)
{
    const std::optional<Tab> tab = tabFromKey(key);
    if (!tab || *tab == m_state.tab)
        return;
    m_state.tab = *tab;
    applyTab();
    m_summary.setTab(*tab);
    emit tabChanged();
    scheduleSave();
    // The tab reads other files (ADR-0038 d): the next sample comes now, and the interval starts again from it.
    requestSample();
    if (m_shown && !m_quick)
        m_timer.start();
}

QVariantList ActivityApp::tabs() const
{
    QVariantList list;
    for (Tab t : kTabs)
        list << QVariantMap{{QStringLiteral("key"), tabKey(t)}, {QStringLiteral("title"), tabTitle(t)}};
    return list;
}

void ActivityApp::setView(const QString &key)
{
    const std::optional<View> view = viewFromKey(key);
    if (!view || (*view == m_state.view && *view != View::Selected))
        return;
    const unsigned readsBefore = readsForView(m_state.view);
    m_state.view = *view;
    m_table.setView(*view);
    emit viewChanged();
    scheduleSave();
    if (readsForView(*view) != readsBefore)
        requestSample(); // the GPU views read the GPU clients (AM49): a sample now fills them
}

QVariantList ActivityApp::views() const
{
    QVariantList list;
    for (View v : activity::views())
        list << QVariantMap{{QStringLiteral("key"), viewKey(v)}, {QStringLiteral("title"), activity::viewTitle(v)}};
    return list;
}

void ActivityApp::setSearch(const QString &text)
{
    if (text == m_search)
        return;
    m_search = text;
    m_table.setSearch(text);
    emit searchChanged();
}

void ActivityApp::setInterval(int seconds)
{
    if (seconds != 1 && seconds != 2 && seconds != 5)
        return;
    if (seconds == m_state.interval)
        return;
    m_state.interval = seconds;
    if (!m_quick)
        m_timer.setInterval(seconds * 1000);
    m_inspectors.setInterval(seconds);
    emit intervalChanged();
    scheduleSave();
}

QVariantList ActivityApp::columns() const
{
    const TabState &t = tabState();
    QVariantList list;
    const std::vector<Column> &defaults = tabColumns(m_state.tab).defaults;
    for (Column c : tabColumns(m_state.tab).all) {
        const QString key = columnKey(c);
        const bool shown = std::find(t.columns.begin(), t.columns.end(), c) != t.columns.end();
        const bool optional = std::find(defaults.begin(), defaults.end(), c) == defaults.end();
        list << QVariantMap{{QStringLiteral("key"), key},
                            {QStringLiteral("title"), columnTitle(c, m_swapped)},
                            {QStringLiteral("shown"), shown},
                            {QStringLiteral("optional"), optional},
                            {QStringLiteral("hideable"), c != Column::Name},
                            {QStringLiteral("numeric"), columnIsNumeric(c)},
                            {QStringLiteral("width"), t.widths.value(key, 0)}};
    }
    return list;
}

QVariantList ActivityApp::shownColumns() const
{
    const TabState &t = tabState();
    QVariantList list;
    for (Column c : t.columns) {
        const QString key = columnKey(c);
        list << QVariantMap{{QStringLiteral("key"), key},
                            {QStringLiteral("title"), columnTitle(c, m_swapped)},
                            {QStringLiteral("numeric"), columnIsNumeric(c)},
                            {QStringLiteral("width"), t.widths.value(key, 0)}};
    }
    return list;
}

void ActivityApp::setColumnShown(const QString &key, bool shown)
{
    const std::optional<Column> c = columnFromKey(key);
    const std::vector<Column> &all = tabColumns(m_state.tab).all;
    if (!c || *c == Column::Name || std::find(all.begin(), all.end(), *c) == all.end())
        return;
    TabState &t = tabState();
    auto it = std::find(t.columns.begin(), t.columns.end(), *c);
    if (shown == (it != t.columns.end()))
        return;
    if (shown) {
        // In its default place among the shown columns: after the shown column that precedes it in the tab's order.
        auto pos = t.columns.end();
        for (Column other : all) {
            if (other == *c)
                break;
            auto found = std::find(t.columns.begin(), t.columns.end(), other);
            if (found != t.columns.end())
                pos = found + 1;
        }
        t.columns.insert(pos, *c);
    } else {
        t.columns.erase(it);
        if (t.sort == *c) { // the sort column hidden: the tab's default sort again
            t.sort = tabColumns(m_state.tab).sort;
            t.descending = true;
        }
    }
    applyTab();
    scheduleSave();
    // A column may read more (Wake Ups, Command; AD10): a sample now fills it.
    requestSample();
}

void ActivityApp::setColumnWidth(const QString &key, int width)
{
    const std::optional<Column> c = columnFromKey(key);
    if (!c)
        return;
    TabState &t = tabState();
    const int w = std::clamp(width, 24, 4000);
    if (t.widths.value(key) == w)
        return;
    t.widths.insert(key, w);
    emit columnsChanged();
    scheduleSave();
}

void ActivityApp::sortBy(const QString &key)
{
    const std::optional<Column> c = columnFromKey(key);
    if (!c)
        return;
    TabState &t = tabState();
    if (t.sort == *c) {
        t.descending = !t.descending;
    } else {
        t.sort = *c;
        t.descending = columnIsNumeric(*c); // numbers start with the largest, text with A (AM10)
    }
    m_table.setSort(t.sort, t.descending);
    emit columnsChanged();
    scheduleSave();
}

void ActivityApp::copySelection()
{
    if (m_table.selectedCount() == 0)
        return;
    if (auto *app = qobject_cast<QGuiApplication *>(QCoreApplication::instance()))
        app->clipboard()->setText(m_table.copyText());
}

// AM50: the actions follow the selection, and the rows' owners as the last sample gave them.
void ActivityApp::updateActionTargets()
{
    const std::vector<TableRow> rows = m_table.selectedRows();
    std::vector<ProcessActions::Target> targets;
    for (const TableRow &r : rows)
        targets.push_back({r.process.pid, r.process.start, r.name, r.process.own, r.kernel});
    m_actions.setSelection(std::move(targets));
    // AM68: one of the processes, as the last sample gave it.
    std::optional<Efficiency::Target> efficiencyTarget;
    if (rows.size() == 1 && !rows.front().kernel) {
        const TableRow &r = rows.front();
        efficiencyTarget = Efficiency::Target{r.process.pid, r.process.start, r.appName.isEmpty() ? r.name : r.appName,
                                              r.process.own, r.process.efficiencyEligible, r.process.session, r.process.efficient};
    }
    m_efficiency.setTarget(std::move(efficiencyTarget));
    const bool inspectable = rows.size() == 1 && !rows.front().kernel; // AM3: the Info button, one row
    if (inspectable != m_inspectable) {
        m_inspectable = inspectable;
        emit inspectChanged();
    }
}

void ActivityApp::applyProjection()
{
    const Projection &projection = m_projection.projection();
    QSet<int> windowPids;
    QList<int> owners;
    for (auto it = projection.apps.cbegin(); it != projection.apps.cend(); ++it) {
        windowPids.insert(it.key());
        owners << it.key();
    }
    m_actions.setProjection(projection.valid, windowPids);
    m_inspectors.setProjection(projection.valid, windowPids);
    QStringList apps;
    for (const QString &id : projection.apps)
        if (!apps.contains(id))
            apps << id;
    if (m_worker)
        QMetaObject::invokeMethod(m_worker, [worker = m_worker, owners, apps] {
            worker->setWindowOwners(owners);
            worker->setWindowApps(apps);
        }, Qt::QueuedConnection);
    // AM57: Recent hangs counts each time the shell marks a process again.
    for (int pid : projection.notResponding) {
        if (m_hung.contains(pid))
            continue;
        const TableRow *row = m_table.processRow(pid, 0);
        const quint64 start = row ? row->process.start : 0;
        Hangs &h = m_hangs[pid];
        if (h.start != 0 && start != 0 && h.start != start)
            h = Hangs{}; // the pid is another process's now
        if (h.start == 0)
            h.start = start;
        ++h.count;
    }
    m_hung = projection.notResponding;
    m_inspectors.namesChanged();
    // Between two samples the table takes the new names and marks at once (in a sample it comes with the rows).
    if (!m_inSnapshot && m_lastSnapshot) {
        m_table.setRows(tableRows(*m_lastSnapshot));
        updateActionTargets();
    }
}

bool ActivityApp::canInspect() const
{
    return m_inspectable;
}

QObject *ActivityApp::focusWindow() const
{
    return QGuiApplication::focusWindow();
}

void ActivityApp::inspectSelection()
{
    const std::vector<TableRow> rows = m_table.selectedRows();
    if (rows.size() == 1 && !rows.front().kernel)
        m_inspectors.open(rows.front().process.pid, rows.front().process.start, rows.front().name);
}

void ActivityApp::inspectRow(int row)
{
    const TableRow *r = m_table.rowAt(row);
    if (r && !r->kernel)
        m_inspectors.open(r->process.pid, r->process.start, r->name);
}

bool ActivityApp::openLoginItems()
{
    // As every Grassfield app starts another: through uwsm's app launcher in a real session (its own scope), else directly
    // (a dev session's Settings reads the dev session's files).
    return grassfield::apps::startApplication(QStringLiteral("grassfield-settings"), {QStringLiteral("--section=login")});
}

void ActivityApp::closeInspection(QObject *inspection)
{
    m_inspectors.close(qobject_cast<Inspection *>(inspection));
}

void ActivityApp::saveSize(int width, int height)
{
    if (width == m_state.width && height == m_state.height)
        return;
    m_state.width = width;
    m_state.height = height;
    scheduleSave();
}

void ActivityApp::saveWindowSize(const QString &kind, int width, int height)
{
    if (!windowKinds().contains(kind) || width < 200 || height < 150 || width > 16384 || height > 16384)
        return;
    if (m_state.windows.value(kind) == QSize(width, height))
        return;
    m_state.windows.insert(kind, QSize(width, height));
    scheduleSave();
}

QSize ActivityApp::savedWindowSize(const QString &kind) const
{
    return m_state.windows.value(kind, QSize(0, 0));
}

void ActivityApp::setGraphMode(const QString &graph, const QString &mode)
{
    if (graph == QLatin1String("disk") && (mode == QLatin1String("io") || mode == QLatin1String("data")) && mode != m_state.diskGraph) {
        m_state.diskGraph = mode;
        m_summary.setDiskMode(mode);
        scheduleSave();
    } else if (graph == QLatin1String("network") && (mode == QLatin1String("packets") || mode == QLatin1String("data"))
               && mode != m_state.networkGraph) {
        m_state.networkGraph = mode;
        m_summary.setNetworkMode(mode);
        scheduleSave();
    }
}

QVariantList ActivityApp::dockIcons() const
{
    const char *const titles[] = {QT_TRANSLATE_NOOP("ActivityApp", "Show Application Icon"), QT_TRANSLATE_NOOP("ActivityApp", "Show Network Usage"),
                                  QT_TRANSLATE_NOOP("ActivityApp", "Show Disk Activity"), QT_TRANSLATE_NOOP("ActivityApp", "Show CPU Usage"),
                                  QT_TRANSLATE_NOOP("ActivityApp", "Show CPU History")};
    QVariantList list;
    for (int k = 0; k < dockIconKinds().size(); ++k)
        list << QVariantMap{{QStringLiteral("key"), dockIconKinds().at(k)},
                            {QStringLiteral("title"), QCoreApplication::translate("ActivityApp", titles[k])}};
    return list;
}

void ActivityApp::setAskEfficiency(bool ask)
{
    if (ask == m_state.askEfficiency)
        return;
    m_state.askEfficiency = ask;
    emit askEfficiencyChanged();
    scheduleSave();
}

void ActivityApp::setDockIcon(const QString &key)
{
    if (key == m_state.dockIcon || !dockIconKinds().contains(key))
        return;
    m_state.dockIcon = key;
    emit dockIconChanged();
    scheduleSave();
    writeDockTile();
    // Off screen, a Dock graph keeps the system's files read at the interval (AM-P3: no process is read); the icon stops it.
    if (!m_shown) {
        if (key == QLatin1String("icon")) {
            m_timer.stop();
        } else {
            m_timer.setInterval(m_state.interval * 1000);
            m_timer.start();
            requestSample();
        }
    }
}

void ActivityApp::writeDockTile()
{
    // Never a file this app did not write (another instance's, a test's): it removes only its own.
    if (m_state.dockIcon == QLatin1String("icon")) {
        if (m_tileWritten) {
            removeDockTile(m_runtimeFolder);
            m_tileWritten = false;
        }
        return;
    }
    const QVariantList samples = m_summary.dockTileSamples(m_state.dockIcon, kDockTileSamples);
    if (!samples.isEmpty()
        && activity::writeDockTile(m_runtimeFolder, dockTileText(QCoreApplication::applicationPid(), ownStartTime(), m_state.dockIcon, samples)))
        m_tileWritten = true;
}

void ActivityApp::setWindowShown(bool shown)
{
    if (shown == m_shown)
        return;
    m_shown = shown;
    // Off screen, the summary keeps its histories and builds its blocks again when the window shows (nothing draws them).
    m_summary.setLive(shown);
    if (!shown) {
        // AM8, AM-P3: no per-process sample while the window is not on screen; a Dock graph, or a Performance or CPU
        // window, keeps the system's files read.
        if (m_state.dockIcon == QLatin1String("icon") && !m_performance.anyShown())
            m_timer.stop();
        return;
    }
    // Back on screen: a sample at once, and no rate drawn across the gap (AM8). Its rates show "—", so the next sample
    // comes a second later rather than a whole interval.
    if (m_sampledOnce) {
        m_forget = true;
        m_quick = m_state.interval > 1;
        m_timer.setInterval(m_quick ? 1000 : m_state.interval * 1000);
    }
    requestSample();
    m_timer.start();
}

void ActivityApp::setAuxShown(const QString &kind, bool shown)
{
    const bool before = m_performance.anyShown();
    m_performance.setShown(kind, shown);
    if (m_shown)
        return; // the main window's samples carry everything
    if (m_performance.anyShown()) {
        if (!before || shown)
            requestSample(); // its graphs fill at once
        if (!m_timer.isActive())
            m_timer.start();
    } else if (m_state.dockIcon == QLatin1String("icon")) {
        m_timer.stop();
    }
}

void ActivityApp::watchAux(QWindow *window, const QString &kind)
{
    if (!window)
        return;
    new ShownWatch(window, [this, kind](bool shown) { setAuxShown(kind, shown); });
    connect(window, &QObject::destroyed, this, [this, kind] { setAuxShown(kind, false); });
}

void ActivityApp::requestSample()
{
    if (!m_shown && m_state.dockIcon == QLatin1String("icon") && !m_performance.anyShown())
        return;
    if (m_busy) {
        m_again = true; // one at a time: the next starts when this one is back
        return;
    }
    m_busy = true;
    if (m_state.tab == Tab::Energy) {
        m_inhibitors.refresh(); // AM38: asked at each sample while the Energy tab is shown
        m_battery.refresh();    // AM39: the battery's figures and graph, the same way
    }
    // Off screen with a Dock graph: the system's files alone (AM62, AM-P3); with a Performance or CPU window, every system
    // file, and the GPU clients for Performance and GPU History (AM66, AM72). AM68: the app units' weights while the main
    // window shows (the Status column and the View menu's checked item).
    unsigned reads = ReadSystemCpu | ReadSystemDisk | ReadSystemNet;
    const bool gpuWindow = m_performance.shown(QStringLiteral("performance")) || m_performance.shown(QStringLiteral("gpuHistory"));
    if (m_shown) {
        // AM68: the units' weights at every sample (the Status column and the menu item's check mark follow a change made
        // elsewhere at once; about 4 µs per app unit, step3-5.md).
        reads = readsForColumns(m_state.tab, tabState().columns) | readsForView(m_state.view) | ReadEfficiency;
        // AM66, AM72: the GPU clients for those windows whatever the tab.
        if (gpuWindow)
            reads |= ReadDescriptors | ReadGpu;
    } else if (m_performance.anyShown()) {
        reads |= ReadSystemMemory;
        if (gpuWindow)
            reads |= ReadProcesses | ReadDescriptors | ReadGpu;
    }
    if (m_performance.wantsSpeed())
        reads |= ReadSystemSpeed;
    emit sampleRequested(reads, m_state.interval, m_forget);
    m_forget = false;
}

void ActivityApp::nameGpus(const Snapshot &snapshot)
{
    // AM47: a GPU's name from pci.ids, else its card's place ("GPU 1" for card0), for the headers of Processes, by GPU and
    // the Performance and GPU History windows.
    bool named = false;
    for (const GpuDevice &gpu : snapshot.gpus) {
        const QString pdev = QString::fromStdString(gpu.pdev);
        const QString name = !gpu.model.empty() ? QString::fromStdString(gpu.model)
                             : gpu.card >= 0 ? QCoreApplication::translate("ActivityApp", "GPU %1").arg(gpu.card + 1)
                                             : pdev;
        if (m_gpuNames.value(pdev) != name) {
            m_gpuNames.insert(pdev, name);
            named = true;
        }
    }
    if (named) {
        m_table.setGpuNames(m_gpuNames);
        m_performance.setGpuNames(m_gpuNames);
    }
}

void ActivityApp::takeSnapshot(const SnapshotPtr &snapshot, unsigned reads, const AppNamesPtr &names)
{
    m_busy = false;
    if (names) {
        for (auto it = names->cbegin(); it != names->cend(); ++it)
            m_names.insert(it.key(), it.value());
    }
    nameGpus(*snapshot);
    // Off screen, for the Dock graph and the Performance and CPU windows: their histories alone. The table, the actions and
    // the inspections wait for the main window (a sample comes at once when it shows, AM8).
    if (!(reads & ReadProcesses) || !m_shown) {
        m_summary.addSample(*snapshot);
        m_performance.take(*snapshot);
        writeDockTile();
        if (m_again) {
            m_again = false;
            requestSample();
        }
        return;
    }
    m_lastSnapshot = snapshot;
    // The writer may have ended without a change to the file (a crashed shell): read again at each sample, one small file.
    m_inSnapshot = true;
    m_projection.recheck();
    m_inSnapshot = false;
    m_sampledOnce = true;
    if (reads & ReadProcesses)
        ++m_processSamples;
    if ((reads & ReadSystemMemory) && snapshot->system.memory.ok && m_swapped != !snapshot->system.memory.swapIsZramOnly) {
        m_swapped = !snapshot->system.memory.swapIsZramOnly; // AM34: Compressed or Swapped Memory
        m_table.setSwappedMemory(m_swapped);
        m_inspectors.setSwappedMemory(m_swapped);
        emit columnsChanged();
    }
    m_summary.addSample(*snapshot);
    m_performance.take(*snapshot);
    m_table.setRows(tableRows(*snapshot));
    updateActionTargets();
    m_inspectors.namesChanged(); // a parent's or a group leader's name may have come
    writeDockTile();
    m_ready = true;
    emit sampled();
    if (m_again) {
        m_again = false;
        requestSample();
    }
}

AppHistory::LiveReader ActivityApp::liveUnits() const
{
    // The candidates are taken from the table here (the window's thread); their cgroups are read by the reader, on the
    // worker (A2 of the 2026-11 audit: /proc and cgroup files per app unit on the window's thread).
    struct Candidate {
        int pid;
        quint64 start;
        quint64 unitKey;
    };
    std::vector<Candidate> candidates;
    QSet<quint64> seen;
    for (const TableRow &r : m_table.allRows()) {
        if (!r.process.own || r.process.unitKey == 0 || seen.contains(r.process.unitKey))
            continue;
        seen.insert(r.process.unitKey);
        candidates.push_back({r.process.pid, r.process.start, r.process.unitKey});
    }
    return [candidates, procRoot = m_options.procRoot, sysRoot = m_options.sysRoot] {
        std::vector<LiveUnit> out;
        QSet<quint64> done;
        for (const Candidate &c : candidates) {
            if (done.contains(c.unitKey))
                continue;
            // The unit now, through the process's descriptor (AD25: a row keeps no cgroup path).
            const ProcessHandle handle = ProcessHandle::open(procRoot, c.pid, c.start);
            const std::string cgroup = handle.valid() ? handle.cgroup() : std::string();
            if (cgroup.empty() || !parseAppUnit(unitOf(cgroup)))
                continue;
            done.insert(c.unitKey);
            const QString dir = QString::fromStdString(sysRoot + "/fs/cgroup" + cgroup + "/");
            LiveUnit live;
            live.unit = QString::fromStdString(std::string(unitOf(cgroup)));
            QFile stat(dir + QStringLiteral("cpu.stat"));
            if (stat.open(QIODevice::ReadOnly))
                parseCpuStatUsage(stat.read(64 * 1024), live.cpuNs);
            QFile peak(dir + QStringLiteral("memory.peak"));
            if (peak.open(QIODevice::ReadOnly))
                live.memoryPeak = peak.read(64).trimmed().toULongLong();
            out.push_back(live);
        }
        return out;
    };
}

std::vector<TableRow> ActivityApp::tableRows(const Snapshot &snapshot)
{
    const double ticks = m_options.clockTicks > 0 ? static_cast<double>(m_options.clockTicks) : 100.0;
    std::vector<TableRow> rows;
    rows.reserve(snapshot.rows.size() + 1);
    TableRow kernel;
    kernel.kernel = true;
    kernel.process.systemAccount = true;
    kernel.process.threads = snapshot.kernel.threads;
    kernel.process.cpuTicks = snapshot.kernel.cpuTicks;
    kernel.process.cpuPercent = snapshot.kernel.cpuPercent;
    kernel.cpuSeconds = static_cast<double>(snapshot.kernel.cpuTicks) / ticks;
    kernel.user = userName(0);
    if (snapshot.kernel.threads > 0) // a pid namespace without kernel threads (a container) has no Kernel row
        rows.push_back(std::move(kernel));
    const QSet<int> &sleepers = m_inhibitors.pids();
    for (const ProcessRow &p : snapshot.rows) {
        TableRow r;
        r.process = p;
        r.cpuSeconds = static_cast<double>(p.cpuTicks) / ticks;
        r.name = QString::fromStdString(p.name);
        r.user = userName(p.uid);
        if (p.own && !p.appId.empty()) {
            // AM65: the desktop entry whose id is the unit's name (a launch by entry), else the one whose Exec runs it.
            const DesktopApp app = m_names.value(QString::fromStdString(p.appId));
            r.appName = app.name;
            r.icon = app.icon;
        }
        // AM60: the shell's projection names the processes that own a window (their app's desktop entry name and icon,
        // AM17), those that inhibit idle (AM38) and those it marks as not responding (AM27).
        const Projection &projection = m_projection.projection();
        if (projection.valid && p.own) {
            const auto app = projection.apps.constFind(p.pid);
            r.windowed = app != projection.apps.constEnd();
            if (r.windowed) {
                const DesktopApp entry = m_names.value(*app); // resolved on the worker (setWindowApps)
                if (!entry.name.isEmpty()) {
                    r.name = entry.name;
                    r.appName = entry.name;
                }
                if (!entry.icon.isEmpty())
                    r.icon = entry.icon;
            }
            r.notResponding = projection.notResponding.contains(p.pid);
        }
        r.preventingSleep = sleepers.contains(p.pid) || (projection.valid && p.own && projection.idleInhibitors.contains(p.pid));
        rows.push_back(std::move(r));
    }
    return rows;
}

QString ActivityApp::userName(uint32_t uid)
{
    auto it = m_users.constFind(uid);
    if (it != m_users.constEnd())
        return *it;
    QString name = QString::number(uid);
    passwd pw{};
    passwd *found = nullptr;
    char buf[4096];
    if (getpwuid_r(uid, &pw, buf, sizeof buf, &found) == 0 && found && found->pw_name)
        name = QString::fromLocal8Bit(found->pw_name);
    return *m_users.insert(uid, name);
}

void ActivityApp::scheduleSave()
{
    m_saveTimer.start();
}

void ActivityApp::readAppearance()
{
    bool dark = true, reduce = false, contrast = false;
    qreal scale = 1;
    QString accent = QStringLiteral("multicolor"), highlight = QStringLiteral("automatic"), doubleClick = QStringLiteral("zoom");
    QString shortcutSetting, formats = QStringLiteral("auto");
    QFile f(configFile());
    if (f.open(QIODevice::ReadOnly) && f.size() <= kConfigMax) {
        const QJsonObject root = QJsonDocument::fromJson(f.read(kConfigMax)).object();
        const QString setting = root.value(QStringLiteral("appearance")).toString();
        m_autoAppearance = setting == QLatin1String("auto");
        dark = grassfield::apps::isDarkAppearance(setting, QTime::currentTime());
        const QJsonObject a11y = root.value(QStringLiteral("accessibility")).toObject();
        reduce = a11y.value(QStringLiteral("reduceMotion")).toBool(false);
        contrast = a11y.value(QStringLiteral("increaseContrast")).toBool(false);
        scale = qBound(1.0, a11y.value(QStringLiteral("textSize")).toDouble(1), 1.3);
        const QString d = root.value(QStringLiteral("windows")).toObject().value(QStringLiteral("titlebarDoubleClick")).toString();
        if (d == QLatin1String("minimize") || d == QLatin1String("none"))
            doubleClick = d;
        static const QStringList names{QStringLiteral("blue"), QStringLiteral("purple"), QStringLiteral("pink"), QStringLiteral("red"),
                                       QStringLiteral("orange"), QStringLiteral("yellow"), QStringLiteral("green"), QStringLiteral("graphite")};
        const QJsonObject accentObject = root.value(QStringLiteral("accent")).toObject();
        if (names.contains(accentObject.value(QStringLiteral("color")).toString()))
            accent = accentObject.value(QStringLiteral("color")).toString();
        if (names.contains(accentObject.value(QStringLiteral("highlight")).toString()))
            highlight = accentObject.value(QStringLiteral("highlight")).toString();
        shortcutSetting = root.value(QStringLiteral("keyboard")).toObject().value(QStringLiteral("shortcutStyle")).toString();
        const QString fm = root.value(QStringLiteral("region")).toObject().value(QStringLiteral("formats")).toString();
        if (!fm.isEmpty())
            formats = fm;
    } else {
        m_autoAppearance = false;
    }
    const QLocale locale = grassfield::i18n::formatsLocale(grassfield::i18n::systemLanguage(), formats);
    if (locale != m_formats) {
        m_formats = locale;
        m_table.setLocale(locale);
        m_summary.setLocale(locale);
        m_inspectors.setLocale(locale);
        m_appHistory.setLocale(locale);
        m_performance.setLocale(locale);
    }
    const QString shortcuts = grassfield::apps::shortcutStyle(shortcutSetting, m_macDevice);
    const bool canMinimize = grassfield::apps::minimizeAvailableInFile();
    if (dark != m_dark || reduce != m_reduceMotion || contrast != m_increaseContrast || scale != m_textScale || accent != m_accentColor
        || highlight != m_accentHighlight || doubleClick != m_titlebarDoubleClick || canMinimize != m_canMinimize || shortcuts != m_shortcutStyle) {
        m_dark = dark;
        m_reduceMotion = reduce;
        m_increaseContrast = contrast;
        m_textScale = scale;
        m_accentColor = accent;
        m_accentHighlight = highlight;
        m_titlebarDoubleClick = doubleClick;
        m_canMinimize = canMinimize;
        m_shortcutStyle = shortcuts;
        emit appearanceChanged();
    }
}

QStringList reopenCommand()
{
    const QStringList ipc = grassfield::apps::runmode::shellIpcArgs();
    if (ipc.isEmpty())
        return {};
    return QStringList{QStringLiteral("qs")} + ipc
        + QStringList{QStringLiteral("dock"), QStringLiteral("reopen"), QStringLiteral("org.grassfield.Activity")};
}

QProcess *runWithTimeout(const QStringList &command, const QProcessEnvironment &env, int timeoutMs, QObject *parent)
{
    if (command.isEmpty())
        return nullptr;
    auto *process = new QProcess(parent);
    process->setProcessEnvironment(env);
    process->setProgram(command.first());
    process->setArguments(command.mid(1));
    process->setStandardOutputFile(QProcess::nullDevice());
    process->setStandardErrorFile(QProcess::nullDevice());
    QObject::connect(process, &QProcess::finished, process, &QObject::deleteLater);
    QObject::connect(process, &QProcess::errorOccurred, process, [process](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            process->deleteLater();
    });
    QTimer::singleShot(timeoutMs, process, [process] { process->kill(); });
    process->start();
    return process;
}

void askShellToReopen(QObject *parent)
{
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    for (const QString &key : env.keys()) {
        if (key.startsWith(QLatin1String("QS_")))
            env.remove(key);
    }
    env.remove(QStringLiteral("XDG_ACTIVATION_TOKEN"));
    runWithTimeout(reopenCommand(), env, grassfield::apps::runmode::kShellIpcMs, parent);
}

Launch claimOrHandOver(QDBusConnection &bus, ActivityService *service, const QString &token, int answerMs)
{
    const QString name = ActivityService::serviceName();
    const QString path = QStringLiteral("/org/grassfield/Activity");
    bus.registerObject(path, service, QDBusConnection::ExportScriptableSlots);
    for (int attempt = 0; attempt < 2; ++attempt) {
        if (bus.registerService(name))
            return Launch::Run;
        QDBusMessage call = QDBusMessage::createMethodCall(name, path, QStringLiteral("org.grassfield.Activity"), QStringLiteral("Activate"));
        call << token;
        const QDBusMessage reply = bus.call(call, QDBus::Block, answerMs);
        if (reply.type() == QDBusMessage::ReplyMessage)
            return Launch::Leave;
        // Only a name left meanwhile is taken; a running app that answers late (still starting) or not at all keeps its
        // one window, as a busy app on macOS opens nothing more.
        const QString error = reply.errorName();
        if (error != QLatin1String("org.freedesktop.DBus.Error.ServiceUnknown")
            && error != QLatin1String("org.freedesktop.DBus.Error.NameHasNoOwner"))
            return Launch::Leave;
    }
    return Launch::Leave;
}

QString ActivityService::serviceName()
{
    return grassfield::apps::runmode::dev() ? QStringLiteral("org.grassfield.Activity.Dev") : QStringLiteral("org.grassfield.Activity");
}

void ActivityService::Activate(const QString &token)
{
    // An xdg-activation token is a short printable string; anything else is dropped (the window still comes forward).
    bool printable = token.size() <= 256;
    for (const QChar ch : token)
        printable = printable && ch.unicode() > 0x20 && ch.unicode() < 0x7f;
    emit activateRequested(printable ? token : QString());
}

} // namespace activity
