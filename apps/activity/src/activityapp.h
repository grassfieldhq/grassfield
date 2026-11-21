// Backend of the activity monitor's window (ADR-0038 step 2a; spec AM1 to AM19, AM74): the sampler on its thread at the
// update frequency while the window is shown (AM8, AM9), the table of the tab, view and search, the columns and the sort of
// each tab, appearance from grassfield.json (read only, as every Grassfield app), and activity.json for what the window
// remembers.
#pragma once

#include "actions.h"
#include "apphistory.h"
#include "performance.h"
#include "efficiency.h"
#include "activitystate.h"
#include "battery.h"
#include "desktopapps.h"
#include "inhibitors.h"
#include "inspection.h"
#include "processtable.h"
#include "runtimefiles.h"
#include "samplerworker.h"
#include "summary.h"

#include <QDBusConnection>
#include <QElapsedTimer>
#include <QFileSystemWatcher>
#include <QHash>
#include <QLocale>
#include <QObject>
#include <QWindow>
#include <QProcessEnvironment>
#include <QThread>
#include <QTimer>
#include <QVariantList>

namespace activity {

class ActivityApp : public QObject
{
    Q_OBJECT
    // Appearance (grassfield.json), as the Store reads it.
    Q_PROPERTY(bool dark READ dark NOTIFY appearanceChanged)
    Q_PROPERTY(bool reduceMotion READ reduceMotion NOTIFY appearanceChanged)
    Q_PROPERTY(bool increaseContrast READ increaseContrast NOTIFY appearanceChanged)
    Q_PROPERTY(qreal textScale READ textScale NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentColor READ accentColor NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentHighlight READ accentHighlight NOTIFY appearanceChanged)
    Q_PROPERTY(QString titlebarDoubleClick READ titlebarDoubleClick NOTIFY appearanceChanged)
    Q_PROPERTY(bool canMinimize READ canMinimize NOTIFY appearanceChanged)
    Q_PROPERTY(QString shortcutStyle READ shortcutStyle NOTIFY appearanceChanged)
    // The tab ("cpu", "memory", "energy", "disk", "network") and the five tabs' keys and titles, in order (AM3, AM4).
    Q_PROPERTY(QString tab READ tab WRITE setTab NOTIFY tabChanged)
    Q_PROPERTY(QVariantList tabs READ tabs CONSTANT)
    // The view (AM12) and the views of the View menu, with their titles; the title is the toolbar's subtitle.
    Q_PROPERTY(QString view READ view WRITE setView NOTIFY viewChanged)
    Q_PROPERTY(QString viewTitle READ viewTitle NOTIFY viewChanged)
    Q_PROPERTY(QVariantList views READ views CONSTANT)
    Q_PROPERTY(QString search READ search WRITE setSearch NOTIFY searchChanged)
    // AM9: 1, 2 or 5 seconds.
    Q_PROPERTY(int interval READ interval WRITE setInterval NOTIFY intervalChanged)
    // AM62: View > Dock Icon: "icon" (the application icon) or the graph the Dock draws on the tile, and the menu's choices
    // ({key, title}).
    Q_PROPERTY(QString dockIcon READ dockIcon WRITE setDockIcon NOTIFY dockIconChanged)
    Q_PROPERTY(QVariantList dockIcons READ dockIcons CONSTANT)
    Q_PROPERTY(QObject *table READ table CONSTANT)
    // The summary under the table: the tab's figures and graphs (AM5).
    Q_PROPERTY(QObject *summary READ summary CONSTANT)
    // Quit, Force Quit and Send Signal on the selection (step 2c, AM50 to AM56).
    Q_PROPERTY(QObject *actions READ actions CONSTANT)
    // AM66, AM71, AM72: the Performance window's and the CPU and GPU windows' data.
    Q_PROPERTY(QObject *performance READ performance CONSTANT)
    // AM67: App History's rows (read when its window opens).
    Q_PROPERTY(QObject *appHistory READ appHistory CONSTANT)
    // AM68: Efficiency Mode of the selected process.
    Q_PROPERTY(QObject *efficiency READ efficiency CONSTANT)
    // AM68: the first time's sheet shows (until "Don't ask again").
    Q_PROPERTY(bool askEfficiency READ askEfficiency WRITE setAskEfficiency NOTIFY askEfficiencyChanged)
    // Inspect (step 2d, AM57): one process selected, not the Kernel row.
    Q_PROPERTY(bool canInspect READ canInspect NOTIFY inspectChanged)
    // The key window (QGuiApplication::focusWindow), null while no window of the app has the keyboard: a key belongs to the
    // key window alone (as Files: Qt reports a window active while one of its Inspect windows has the keyboard).
    Q_PROPERTY(QObject *focusWindow READ focusWindow NOTIFY focusWindowChanged)
    // Every column of the tab, in the table's order ({key, title, shown, optional, numeric, width}): View > Columns and the
    // header's menu (AM15). `shownColumns` is the shown ones alone, in order; a width of 0 is the token width.
    Q_PROPERTY(QVariantList columns READ columns NOTIFY columnsChanged)
    Q_PROPERTY(QVariantList shownColumns READ shownColumns NOTIFY columnsChanged)
    Q_PROPERTY(QString sortKey READ sortKey NOTIFY columnsChanged)
    Q_PROPERTY(bool sortDescending READ sortDescending NOTIFY columnsChanged)
    // The size the window had when it last closed (AM2); 0 for the token size.
    Q_PROPERTY(int savedWidth READ savedWidth CONSTANT)
    Q_PROPERTY(int savedHeight READ savedHeight CONSTANT)
    // The first sample has come (until then the table is empty and says nothing).
    Q_PROPERTY(bool ready READ ready NOTIFY sampled)
    // AM-P3's dev counter: the samples that read the processes since the app started.
    Q_PROPERTY(int processSamples READ processSamples NOTIFY sampled)
    // The Network tab's line under the table (AM43).
    Q_PROPERTY(bool devSession READ devSession CONSTANT)

public:
    // `options`: the sampler's (defaultOptions(), or a fixture's in a dev session, AM79). `statePath`: activity.json.
    ActivityApp(Options options, QString statePath, QObject *parent = nullptr);
    ~ActivityApp() override;

    bool dark() const { return m_dark; }
    bool reduceMotion() const { return m_reduceMotion; }
    bool increaseContrast() const { return m_increaseContrast; }
    qreal textScale() const { return m_textScale; }
    QString accentColor() const { return m_accentColor; }
    QString accentHighlight() const { return m_accentHighlight; }
    QString titlebarDoubleClick() const { return m_titlebarDoubleClick; }
    bool canMinimize() const { return m_canMinimize; }
    QString shortcutStyle() const { return m_shortcutStyle; }

    QString tab() const { return tabKey(m_state.tab); }
    void setTab(const QString &key);
    QVariantList tabs() const;
    QString view() const { return viewKey(m_state.view); }
    void setView(const QString &key);
    QString viewTitle() const { return activity::viewTitle(m_state.view); }
    QVariantList views() const;
    QString search() const { return m_search; }
    void setSearch(const QString &text);
    int interval() const { return m_state.interval; }
    void setInterval(int seconds);
    QString dockIcon() const { return m_state.dockIcon; }
    void setDockIcon(const QString &key);
    QVariantList dockIcons() const;
    QObject *table() { return &m_table; }
    ProcessTable &processTable() { return m_table; }
    QObject *summary() { return &m_summary; }
    QObject *actions() { return &m_actions; }
    ProcessActions &processActions() { return m_actions; }
    QObject *efficiency() { return &m_efficiency; }
    QObject *appHistory() { return &m_appHistory; }
    QObject *performance() { return &m_performance; }
    Performance &performanceModel() { return m_performance; }
    AppHistory &appHistoryModel() { return m_appHistory; }
    Efficiency &efficiencyMode() { return m_efficiency; }
    bool askEfficiency() const { return m_state.askEfficiency; }
    void setAskEfficiency(bool ask);
    bool canInspect() const;
    QObject *focusWindow() const;
    Inspectors &inspectors() { return m_inspectors; }
    Summary &summaryModel() { return m_summary; }
    QVariantList columns() const;
    QVariantList shownColumns() const;
    QString sortKey() const { return columnKey(tabState().sort); }
    bool sortDescending() const { return tabState().descending; }
    int savedWidth() const { return m_state.width; }
    int savedHeight() const { return m_state.height; }
    bool ready() const { return m_ready; }
    int processSamples() const { return m_processSamples; }
    bool devSession() const;

    // AM8: the window is on screen (visible, not minimized, exposed). While it is not, no sample is taken.
    Q_INVOKABLE void setWindowShown(bool shown);
    // AM66, AM71, AM72: one of the app's other windows that draw live data ("performance", "cpuUsage", "cpuHistory",
    // "gpuHistory") is on screen or not. While one is, the system's files are read (and the GPU clients for Performance and
    // GPU History) even if the main window is not.
    Q_INVOKABLE void setAuxShown(const QString &kind, bool shown);
    // That window's state followed (visible, exposed, not minimized, as the main window's), and its end.
    Q_INVOKABLE void watchAux(QWindow *window, const QString &kind);
    // AM15: a column of the tab shown or hidden (never the name), its width.
    Q_INVOKABLE void setColumnShown(const QString &key, bool shown);
    Q_INVOKABLE void setColumnWidth(const QString &key, int width);
    // AM10: a header clicked sorts by its column; the same header again reverses.
    Q_INVOKABLE void sortBy(const QString &key);
    // AM19: the selected rows to the clipboard.
    Q_INVOKABLE void copySelection();
    // AM2: the window's size as it closes.
    Q_INVOKABLE void saveSize(int width, int height);
    // AM74: another window's size (windowKinds()) as it closes, and the size it opens at (0 × 0: its token size).
    Q_INVOKABLE void saveWindowSize(const QString &kind, int width, int height);
    Q_INVOKABLE QSize savedWindowSize(const QString &kind) const;
    // AM42, AM44: the pop-up above the Disk graph ("io" or "data") or the Network graph ("packets" or "data"), remembered.
    Q_INVOKABLE void setGraphMode(const QString &graph, const QString &mode);
    // AM57: the selected process's Inspect window (the Info button, View > Inspect Process, Ctrl+I), or a row's (a
    // double-click): made, or brought forward when it is open (inspectRequested). Nothing for the Kernel row, a group's
    // header, or a process that ended.
    Q_INVOKABLE void inspectSelection();
    Q_INVOKABLE void inspectRow(int row);
    // Its window closed.
    Q_INVOKABLE void closeInspection(QObject *inspection);
    // AM69 (step 4): Settings on General > Login Items, a link and not a copy (the owner's brief); false when it could not
    // be started.
    Q_INVOKABLE bool openLoginItems();

    // The rows of a snapshot as the table shows them (the tests feed snapshots through it).
    std::vector<TableRow> tableRows(const Snapshot &snapshot);
    void takeSnapshot(const SnapshotPtr &snapshot, unsigned reads, const AppNamesPtr &names);

signals:
    void appearanceChanged();
    void tabChanged();
    void viewChanged();
    void searchChanged();
    void intervalChanged();
    void dockIconChanged();
    void askEfficiencyChanged();
    void columnsChanged();
    void sampled();
    // Asked by the worker's thread; queued.
    void sampleRequested(unsigned reads, double interval, bool forget);
    // An Inspect window to make, or to bring forward when one shows this inspection (AM57).
    void inspectRequested(QObject *inspection);
    void inspectChanged();
    void focusWindowChanged();

private:
    const TabState &tabState() const;
    TabState &tabState();
    void applyTab();
    void requestSample();
    void scheduleSave();
    void readAppearance();
    void updateActionTargets();
    // AM60: the shell's projection read again: the actions, the inspections, the sampler and the table follow it.
    void applyProjection();
    // AM62: the Dock tile's graph from the last sample, or no file for the application icon.
    void writeDockTile();
    // AM47: the GPUs' names, for the table and the Performance windows.
    void nameGpus(const Snapshot &snapshot);
    QString userName(uint32_t uid);
    // AM67: the live app units of the last sample, their cgroup's CPU time and memory peak now.
    // App History's live units: the candidates taken now, the reader that reads their cgroups (on the worker).
    AppHistory::LiveReader liveUnits() const;

    Options m_options;
    QString m_statePath;
    ActivityState m_state;
    ProcessTable m_table;
    Summary m_summary;
    ProcessActions m_actions;
    Efficiency m_efficiency;
    AppHistory m_appHistory;
    Performance m_performance;
    Inspectors m_inspectors;
    QString m_runtimeFolder;
    bool m_tileWritten = false; // AM62: this app wrote dock-tile.json (it removes no other)
    ProjectionWatch m_projection;
    SnapshotPtr m_lastSnapshot;   // the table's last sample, for a projection that changes between two
    bool m_inSnapshot = false;
    QSet<int> m_hung;             // the pids the projection marked last
    // AM57: each pid's marks since the app opened, with the start time of the process they were for (0 while its row was not
    // sampled yet: the first mark can come before the first sample).
    struct Hangs {
        quint64 start = 0;
        int count = 0;
    };
    QHash<int, Hangs> m_hangs;
    BatteryWatch m_battery;
    QThread m_thread;
    SamplerWorker *m_worker = nullptr; // lives on m_thread
    QTimer m_timer, m_saveTimer, m_autoTimer;
    bool m_shown = false, m_busy = false, m_again = false, m_forget = false, m_quick = false, m_sampledOnce = false;
    bool m_ready = false;
    bool m_inspectable = false;
    int m_processSamples = 0;
    QString m_search;
    bool m_swapped = false;
    // Every app id's desktop entry resolved so far (by the sampler's thread, with each sample).
    AppNames m_names;
    InhibitorWatch m_inhibitors;
    QHash<uint32_t, QString> m_users;
    QHash<QString, QString> m_gpuNames; // AM47: every GPU seen since the app started, by drm-pdev
    QFileSystemWatcher m_watcher;
    bool m_autoAppearance = false, m_macDevice = false;
    bool m_dark = true, m_reduceMotion = false, m_increaseContrast = false, m_canMinimize = true;
    qreal m_textScale = 1;
    QString m_accentColor = QStringLiteral("multicolor"), m_accentHighlight = QStringLiteral("automatic");
    QString m_titlebarDoubleClick = QStringLiteral("zoom"), m_shortcutStyle;
    QLocale m_formats;
};

// AD34: launched again while its window is not on screen, the app asks the shell's Dock to bring it back, as a click on
// its tile does (`qs ipc -p <shell> call dock reopen org.grassfield.Activity`): xdg-activation switches to another
// Desktop but leaves a window on special:minimized. Empty when there is no shell to call (a dev session that names none:
// the installed shell is never driven from it, apps/runmode.h).
QStringList reopenCommand();
// Runs reopenCommand() without the QS_* variables (the shell is named by its directory) or a spent token, killed after
// runmode.h's kShellIpcMs, as Settings' shell calls are (the shell answers at once; review of PR #47).
void askShellToReopen(QObject *parent);
// Runs `command` (program, arguments) with `env`, its output dropped; killed after `timeoutMs`; the process deletes itself
// when it ends. nullptr for an empty command.
class QProcess *runWithTimeout(const QStringList &command, const QProcessEnvironment &env, int timeoutMs, QObject *parent);

// AM1: one instance. The running app owns org.grassfield.Activity on the session bus (".Dev" in a dev session, which
// shares the owner's bus); a second launch calls Activate with its activation token and leaves.
class ActivityService;
enum class Launch { Run, Leave };
// A launch takes the bus name (Run), or hands its activation token over to the app that holds it and leaves (Leave). The
// running app answers once its window exists, which a slow start delays (the review of PR #47: a launch that gave up after
// 2 s ran a second window and a second sampler): a launch leaves whatever the answer, and runs only when the name has
// no owner left, after taking it. `answerMs` bounds the wait for the token's delivery.
Launch claimOrHandOver(QDBusConnection &bus, ActivityService *service, const QString &token, int answerMs = 25000);

class ActivityService : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.grassfield.Activity")

public:
    using QObject::QObject;
    static QString serviceName();

public slots:
    Q_SCRIPTABLE void Activate(const QString &token);

signals:
    void activateRequested(const QString &token);
};

} // namespace activity
