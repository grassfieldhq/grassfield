// A-W1 (spec "Acceptance criteria"; ADR-0038 step 2a): the window and its real backend on a fixture tree, offscreen. The
// rows of the tab, the tabs, a header click that sorts, the columns chooser, typing in the search field, the views, Copy as
// text, no sample while the window is hidden, suspended by the compositor or minimized (AM8, AD35), and the size it keeps
// (AM2). A-W2 (step 2c, AM50 to AM56; tests/apps/activity_actions.sh): the window on the real /proc and real children:
// Stop and its sheet's Quit send SIGTERM, Force Quit SIGKILL, a process that ends meanwhile is silent, a session process
// gets the warning first and no Stop, and the dev guard refuses a process outside its roots. A-W3 (step 2d, AM57 to
// AM59): the Info button's Inspect window on the real /proc, its reads, its Quit, another owner's process, and the windows
// closed with their process and with the main window.
#include "../fixture.h"
#include "activityapp.h"
#include "graphitem.h"
#include "format.h"
#include "iconprovider.h"
#include "shownwatch.h"

#include <QAccessible>
#include <QClipboard>
#include <QElapsedTimer>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlApplicationEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QtGui/private/qwindow_p.h>

#include <gtest/gtest.h>

#include <functional>
#include <memory>
#include <vector>

#include <csignal>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef ACTIVITY_ROOT
#error "ACTIVITY_ROOT: the repository's root (build-direct.sh and CMakeLists.txt define it)"
#endif

using namespace activity;
using activity_test::Fixture;

namespace {

constexpr unsigned kMe = 1000;

std::string nul(std::initializer_list<const char *> words)
{
    std::string s;
    for (const char *w : words) {
        s += w;
        s += '\0';
    }
    return s;
}

// From the window: items declared in a QML Window have the window as their QObject parent, not its content item.
QQuickItem *named(QQuickWindow *win, const char *name)
{
    return win->findChild<QQuickItem *>(QString::fromLatin1(name));
}

// The header delegates (the Repeater's items; the Repeater itself is a child too).
QList<QQuickItem *> headers(QQuickWindow *win)
{
    QList<QQuickItem *> list;
    if (QQuickItem *row = named(win, "columnHeaders")) {
        for (QQuickItem *child : row->childItems()) {
            if (child->property("modelData").isValid())
                list << child;
        }
    }
    return list;
}

QQuickItem *header(QQuickWindow *win, const QString &key)
{
    for (QQuickItem *h : headers(win)) {
        if (h->property("modelData").toMap().value(QStringLiteral("key")).toString() == key)
            return h;
    }
    return nullptr;
}

int rows(QQuickWindow *win)
{
    QQuickItem *list = named(win, "processRows");
    return list ? list->property("count").toInt() : -1;
}

QPoint centre(QQuickItem *item)
{
    return item->mapToScene(QPointF(item->width() / 2, item->height() / 2)).toPoint();
}

// A click once the window has laid out what changed: a Row positions its children, and a ListView its delegates, at the
// next polish, so a click sent at once can land where an item is not yet.
void settledClick(QQuickWindow *win, const std::function<QPoint()> &where)
{
    win->requestUpdate();
    QTest::qWait(100);
    const QPoint p = where();
    QTest::mouseMove(win, p);
    QTest::qWait(20);
    QTest::mouseClick(win, Qt::LeftButton, Qt::NoModifier, p);
}

// Waits until `value()` equals `want`. QtTest's retrying macros report a failure only inside a QtTest run: under gtest they
// return from the case silently, so every wait here goes through a gtest assertion.
template <typename F, typename T>
::testing::AssertionResult becomes(F value, T want, int ms = 3000)
{
    if (QTest::qWaitFor([&] { return value() == want; }, ms))
        return ::testing::AssertionSuccess();
    return ::testing::AssertionFailure() << "still " << value() << " after " << ms << " ms, wanted " << want;
}

// What Qt's Wayland client does when the compositor suspends the window (xdg_toplevel's `suspended` state, which Hyprland
// 0.56 sets on every window whose workspace is not shown: Grassfield's special:minimized, a Desktop not shown): the window
// stays visible, isExposed() turns false and an expose event comes (QWaylandXdgSurface::isExposed, then
// QWaylandWindow::updateExposure and QGuiApplicationPrivate::processExposeEvent). Offscreen windows are always exposed.
void suspend(QQuickWindow *win, bool suspended)
{
    QWindowPrivate::get(win)->exposed = !suspended;
    QExposeEvent e(suspended ? QRegion() : QRegion(QRect(QPoint(), win->size())));
    QCoreApplication::sendEvent(win, &e);
}

// Counts the events of one type a window receives.
struct EventCounter : QObject {
    EventCounter(QObject *target, QEvent::Type type, int &count)
        : m_type(type)
        , m_count(count)
    {
        target->installEventFilter(this);
    }
    bool eventFilter(QObject *, QEvent *event) override
    {
        if (event->type() == m_type)
            ++m_count;
        return false;
    }
    QEvent::Type m_type;
    int &m_count;
};

struct Window {
    Fixture f;
    QTemporaryDir config, state;
    std::unique_ptr<ActivityApp> backend; // outlives the engine (declared first, destroyed last), as in main.cpp
    std::unique_ptr<QQmlApplicationEngine> engine;
    QQuickWindow *win = nullptr;

    // `realProc`: the machine's /proc as the app reads it (A-W2), else the fixture tree.
    explicit Window(bool realProc = false)
    {
        f.process(100, "alpha", kMe, 300, 1, nul({"alpha"}), "/");
        f.process(101, "beta", kMe, 200, 1, nul({"beta"}), "/");
        f.process(102, "gamma", kMe, 100, 1, nul({"gamma"}), "/");
        // The system files of the summary (AM29, AM32).
        f.write("proc/stat", "cpu  100 0 50 1000 0 0 0 0 0 0\ncpu0 100 0 50 1000 0 0 0 0 0 0\nintr 1\n");
        f.write("proc/loadavg", "0.10 0.20 0.30 1/57 999\n");
        f.write("proc/meminfo", "MemTotal: 16000000 kB\nMemAvailable: 8000000 kB\nActive(file): 1000000 kB\nInactive(file): 500000 kB\n");
        qputenv("GRASSFIELD_CONFIG_HOME", config.path().toUtf8());
        Options o;
        o.procRoot = f.proc();
        o.sysRoot = f.sys();
        o.uid = kMe;
        o.clockTicks = 100;
        o.maxKeptFiles = 4096;
        if (realProc)
            o = defaultOptions();
        backend = std::make_unique<ActivityApp>(o, statePath());
        engine = std::make_unique<QQmlApplicationEngine>();
        engine->addImportPath(QStringLiteral(ACTIVITY_ROOT "/ui"));
        engine->addImageProvider(QStringLiteral("icon"), new IconProvider);
        engine->setInitialProperties({{QStringLiteral("backend"), QVariant::fromValue(backend.get())}, {QStringLiteral("globalMenu"), false}});
        engine->load(QUrl::fromLocalFile(QStringLiteral(ACTIVITY_ROOT "/apps/activity/qml/Main.qml")));
        if (!engine->rootObjects().isEmpty())
            win = qobject_cast<QQuickWindow *>(engine->rootObjects().constFirst());
        if (win) {
            new ShownWatch(win, backend.get());
            win->requestActivate();
        }
    }

    QString statePath() const { return state.path() + QStringLiteral("/activity.json"); }

    bool sampled()
    {
        QSignalSpy spy(backend.get(), &ActivityApp::sampled);
        return spy.wait(5000);
    }
};

} // namespace

TEST(ActivityWindow, TheTableTabsSortSearchViewsAndCopy)
{
    Window w;
    ASSERT_NE(w.win, nullptr);
    ASSERT_TRUE(QTest::qWaitForWindowExposed(w.win));
    ASSERT_TRUE(w.backend->ready() || w.sampled());
    ASSERT_TRUE(becomes([&] { return rows(w.win); }, 3, 3000));
    EXPECT_EQ(headers(w.win).size(), 8); // the CPU tab's defaults

    // A tab: its own columns (AM4).
    QQuickItem *tabs = named(w.win, "tabs");
    ASSERT_NE(tabs, nullptr);
    QMetaObject::invokeMethod(tabs, "picked", Q_ARG(QString, QStringLiteral("memory")));
    EXPECT_EQ(w.backend->tab(), "memory");
    ASSERT_TRUE(becomes([&] { return static_cast<int>(headers(w.win).size()); }, 5, 2000));
    QMetaObject::invokeMethod(tabs, "picked", Q_ARG(QString, QStringLiteral("cpu")));
    ASSERT_TRUE(becomes([&] { return static_cast<int>(headers(w.win).size()); }, 8, 2000));

    // A header clicked sorts by its column, numbers from the largest (AM10).
    ASSERT_NE(header(w.win, QStringLiteral("pid")), nullptr);
    settledClick(w.win, [&] { return centre(header(w.win, QStringLiteral("pid"))); });
    EXPECT_EQ(w.backend->sortKey(), "pid");
    EXPECT_TRUE(w.backend->sortDescending());
    EXPECT_EQ(w.backend->processTable().data(w.backend->processTable().index(0), ProcessTable::NameRole).toString(), "gamma");

    // The columns chooser (AM15).
    w.backend->setColumnShown(QStringLiteral("wakeUps"), true);
    ASSERT_TRUE(becomes([&] { return static_cast<int>(headers(w.win).size()); }, 9, 2000));
    ASSERT_NE(header(w.win, QStringLiteral("wakeUps")), nullptr);

    // Typing in the search field filters at once (AM14); Esc clears it.
    QTest::keyClick(w.win, Qt::Key_F, Qt::ControlModifier);
    for (char c : {'b', 'e', 't'})
        QTest::keyClick(w.win, c);
    EXPECT_EQ(w.backend->search(), "bet");
    ASSERT_TRUE(becomes([&] { return rows(w.win); }, 1, 2000));
    QTest::keyClick(w.win, Qt::Key_Escape);
    ASSERT_TRUE(becomes([&] { return rows(w.win); }, 3, 2000));

    // A view (AM12): no system process in the fixture.
    w.backend->setView(QStringLiteral("system"));
    ASSERT_TRUE(becomes([&] { return rows(w.win); }, 0, 2000));
    w.backend->setView(QStringLiteral("all"));
    ASSERT_TRUE(becomes([&] { return rows(w.win); }, 3, 2000));

    // A click on a row selects it; Ctrl+C copies it as text, the headers first (AM19).
    QQuickItem *list = named(w.win, "processRows");
    settledClick(w.win, [&] { return list->mapToScene(QPointF(40, 5)).toPoint(); });
    EXPECT_EQ(w.backend->processTable().selectedCount(), 1);
    QTest::keyClick(w.win, Qt::Key_C, Qt::ControlModifier);
    const QStringList copied = QGuiApplication::clipboard()->text().split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    ASSERT_EQ(copied.size(), 2);
    EXPECT_TRUE(copied[0].startsWith(QStringLiteral("Process Name\t% CPU")));
    EXPECT_TRUE(copied[1].startsWith(QStringLiteral("gamma\t")));
}

// Every visible text under `item`.
QStringList textsUnder(QQuickItem *item)
{
    QStringList out;
    if (!item || !item->isVisible())
        return out;
    const QVariant text = item->property("text");
    if (text.typeId() == QMetaType::QString && !text.toString().isEmpty())
        out << text.toString();
    for (QQuickItem *child : item->childItems())
        out << textsUnder(child);
    return out;
}

// AM5: the summary under the table holds the real backend's figures, from the fixture's system files, and its graphs keep
// the historySamples token's count.
TEST(ActivityWindow, TheSummaryShowsTheSystemFigures)
{
    Window w;
    ASSERT_NE(w.win, nullptr);
    ASSERT_TRUE(QTest::qWaitForWindowExposed(w.win));
    QQuickItem *summary = named(w.win, "summary");
    ASSERT_NE(summary, nullptr);
    ASSERT_TRUE(w.backend->ready() || w.sampled());
    EXPECT_GT(w.backend->summaryModel().capacity(), 1);
    ASSERT_TRUE(becomes([&] { return textsUnder(summary).contains(QStringLiteral("57")); }, true)); // Threads, from loadavg
    const QStringList cpu = textsUnder(summary);
    EXPECT_TRUE(cpu.contains(QStringLiteral("Processes:")));
    EXPECT_TRUE(cpu.contains(QStringLiteral("3")));
    EXPECT_TRUE(cpu.contains(QStringLiteral("CPU Load")));
    QMetaObject::invokeMethod(named(w.win, "tabs"), "picked", Q_ARG(QString, QStringLiteral("memory")));
    ASSERT_TRUE(becomes([&] { return textsUnder(summary).contains(QStringLiteral("16.4 GB")); }, true)); // 16 000 000 KiB
    EXPECT_TRUE(textsUnder(summary).contains(QStringLiteral("Memory Pressure")));
}

// AM13: All Processes, Hierarchically with the real table: a child one level in, its parent's triangle closes it.
TEST(ActivityWindow, HierarchicallyIndentsAndCollapses)
{
    Window w;
    ASSERT_NE(w.win, nullptr);
    ASSERT_TRUE(QTest::qWaitForWindowExposed(w.win));
    ASSERT_TRUE(w.backend->ready() || w.sampled());
    w.f.write("proc/103/stat", Fixture::statLine(103, "delta", 'S', 100, 0, 50, 0, 1, 2));
    w.f.write("proc/103/status", Fixture::statusText("delta", kMe, 1000, 0));
    w.f.write("proc/103/cmdline", nul({"delta"}));
    w.f.write("proc/103/cgroup", "0::/\n");
    w.backend->setView(QStringLiteral("tree"));
    w.backend->setInterval(1);
    ASSERT_TRUE(becomes([&] { return rows(w.win); }, 4, 4000));
    ProcessTable &t = w.backend->processTable();
    int alpha = -1;
    for (int i = 0; i < t.count(); ++i) {
        if (t.data(t.index(i), ProcessTable::NameRole).toString() == QLatin1String("alpha"))
            alpha = i;
    }
    ASSERT_GE(alpha, 0);
    EXPECT_TRUE(t.data(t.index(alpha), ProcessTable::ExpandableRole).toBool());
    EXPECT_EQ(t.data(t.index(alpha + 1), ProcessTable::NameRole).toString(), "delta");
    EXPECT_EQ(t.data(t.index(alpha + 1), ProcessTable::DepthRole).toInt(), 1);
    // The triangle of alpha's row, in the view: a click there closes it.
    QQuickItem *list = named(w.win, "processRows");
#if QT_VERSION >= QT_VERSION_CHECK(6, 12, 0)
    // A screen reader hears that alpha's row opens, and whether it is open (Qt 6.12; Qt 6.11.2 has no such state).
    const auto alphaState = [&] {
        for (QQuickItem *item : list->property("contentItem").value<QQuickItem *>()->childItems()) {
            QAccessibleInterface *a = QAccessible::queryAccessibleInterface(item);
            if (a && item->isVisible() && item->property("name").toString() == QLatin1String("alpha"))
                return a->state();
        }
        return QAccessible::State();
    };
    EXPECT_TRUE(alphaState().expandable);
    EXPECT_TRUE(alphaState().expanded);
#endif
    const qreal rowHeight = list->property("contentHeight").toReal() / t.count();
    settledClick(w.win, [&] {
        return list->mapToScene(QPointF(10, (alpha + 0.5) * rowHeight - list->property("contentY").toReal())).toPoint();
    });
    ASSERT_TRUE(becomes([&] { return rows(w.win); }, 3, 2000));
    EXPECT_FALSE(t.data(t.index(alpha), ProcessTable::ExpandedRole).toBool());
#if QT_VERSION >= QT_VERSION_CHECK(6, 12, 0)
    EXPECT_TRUE(alphaState().expandable);
    EXPECT_FALSE(alphaState().expanded);
#endif
}

TEST(ActivityWindow, HiddenItSamplesNothingAndItKeepsItsSize)
{
    Window w;
    ASSERT_NE(w.win, nullptr);
    ASSERT_TRUE(QTest::qWaitForWindowExposed(w.win));
    ASSERT_TRUE(w.backend->ready() || w.sampled());
    w.backend->setInterval(1);

    // AM8, AM-P3: hidden, no sample; shown again, one at once.
    w.win->hide();
    const int before = w.backend->processSamples();
    QTest::qWait(2500); // two intervals of Very Often
    EXPECT_EQ(w.backend->processSamples(), before);
    w.win->show();
    ASSERT_TRUE(QTest::qWaitForWindowExposed(w.win));
    ASSERT_TRUE(QTest::qWaitFor([&] { return w.backend->processSamples() > before; }, 3000));

    // AD35: suspended by the compositor (minimized, on a Desktop not shown), visible but not exposed: no sample.
    suspend(w.win, true);
    QTest::qWait(100);
    const int suspended = w.backend->processSamples();
    QTest::qWait(2500);
    EXPECT_EQ(w.backend->processSamples(), suspended);
    suspend(w.win, false);
    ASSERT_TRUE(QTest::qWaitFor([&] { return w.backend->processSamples() > suspended; }, 3000));

    // Minimized as Qt says it (a platform that keeps the state; offscreen does): no sample.
    w.win->showMinimized();
    QTest::qWait(100);
    const int minimized = w.backend->processSamples();
    QTest::qWait(2500);
    EXPECT_EQ(w.backend->processSamples(), minimized);
    w.win->showNormal();
    ASSERT_TRUE(QTest::qWaitFor([&] { return w.backend->processSamples() > minimized; }, 3000));

    // AD34: launched again while suspended (minimized, on another Desktop), the app asks the Dock to bring it back, and
    // Qt's next activation request takes the token; on screen, the token alone.
    int reopens = 0;
    suspend(w.win, true);
    activateWindow(w.win, QStringLiteral("token-1"), [&] { ++reopens; });
    EXPECT_EQ(reopens, 1);
    EXPECT_EQ(qgetenv("XDG_ACTIVATION_TOKEN"), "token-1");
    suspend(w.win, false);
    activateWindow(w.win, QString(), [&] { ++reopens; });
    EXPECT_EQ(reopens, 1);
    qunsetenv("XDG_ACTIVATION_TOKEN");

    // A second launch keeps the window's size and its maximized state: no state is asked of the platform (on Wayland a
    // maximize request toggles Hyprland's maximize; the integrator's check of f2ff9a0). The platform reports each request
    // with a WindowStateChange event, even an unchanged one.
    int stateRequests = 0;
    EventCounter counter(w.win, QEvent::WindowStateChange, stateRequests);
    for (const bool maximized : {false, true}) {
        if (maximized) {
            w.win->showMaximized();
            ASSERT_TRUE(becomes([&] { return w.win->visibility(); }, QWindow::Maximized, 2000));
        }
        QTest::qWait(50);
        stateRequests = 0;
        const QSize size = w.win->size();
        activateWindow(w.win, QString(), [&] { ++reopens; });
        QTest::qWait(50);
        EXPECT_EQ(stateRequests, 0) << (maximized ? "maximized" : "normal");
        EXPECT_EQ(w.win->size(), size);
        EXPECT_EQ(w.win->visibility(), maximized ? QWindow::Maximized : QWindow::Windowed);
    }
    EXPECT_EQ(reopens, 1); // on screen both times
    // Minimized as Qt says it (offscreen keeps the state): off screen, so the Dock is asked, and the state goes.
    w.win->showMinimized();
    ASSERT_TRUE(becomes([&] { return w.win->visibility(); }, QWindow::Minimized, 2000));
    activateWindow(w.win, QString(), [&] { ++reopens; });
    EXPECT_EQ(reopens, 2);
    ASSERT_TRUE(becomes([&] { return w.win->visibility() != QWindow::Minimized; }, true, 2000));
    w.win->showNormal();

    // AM2: the size it closes at is the one it opens at.
    w.win->resize(700, 400);
    w.win->close();
    w.engine.reset();
    w.backend.reset(); // writes what is pending
    QFile f(w.statePath());
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    const QJsonObject root = QJsonDocument::fromJson(f.readAll()).object();
    EXPECT_EQ(root.value(QStringLiteral("interval")).toInt(), 1);
    EXPECT_EQ(root.value(QStringLiteral("window")).toObject().value(QStringLiteral("width")).toInt(), 700);
    EXPECT_EQ(root.value(QStringLiteral("window")).toObject().value(QStringLiteral("height")).toInt(), 400);
}

int main(int argc, char **argv)
{
    // Review of 5bfd4419: no test reaches the live session's runtime files (its dock-tile.json, its projection): a private
    // runtime directory, and no display to name a folder by (a test that needs one sets its own).
    QTemporaryDir runtime;
    qputenv("XDG_RUNTIME_DIR", runtime.path().toUtf8());
    qunsetenv("WAYLAND_DISPLAY");
    // Always offscreen, whatever the session says: a test never opens a window on the owner's compositor. The one exception
    // is tst_graph.cpp's GPU run, which starts this binary again under its own Xvfb (GRASSFIELD_TEST_XCB, a display xvfb-run
    // made for it).
    const bool xvfbRun = qEnvironmentVariableIntValue("GRASSFIELD_TEST_XCB") == 1 && qEnvironmentVariableIsSet("DISPLAY");
    qputenv("QT_QPA_PLATFORM", xvfbRun ? "xcb" : "offscreen");
    qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");
    QGuiApplication app(argc, argv);
    // The app's own QML type (Graph.qml makes it), as main.cpp registers it.
    activity::registerGraphItem();
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}

// ---- A-W2 (step 2c) ------------------------------------------------------------------------------------------------------
namespace {

constexpr const char *kPlainUnit = "/user.slice/user-1000.slice/user@1000.service/app.slice/fixture.service";
constexpr const char *kSessionUnit = "/user.slice/user-1000.slice/user@1000.service/session.slice/wayland-wm@hyprland.desktop.service";

// A child that waits for a signal.
pid_t idleChild()
{
    const pid_t pid = fork();
    if (pid == 0) {
        activity_test::defaultSignals();
        for (;;)
            pause();
    }
    return pid;
}

// How a child ended: its signal, 0 for an exit; -1 while it still runs after `ms` (0: not waited for).
int ending(pid_t pid, int ms = 5000)
{
    int status = 0;
    pid_t r = 0;
    QElapsedTimer t;
    t.start();
    while ((r = waitpid(pid, &status, WNOHANG)) == 0 && t.elapsed() < ms)
        QTest::qWait(20);
    if (r != pid)
        return -1;
    return WIFSIGNALED(status) ? WTERMSIG(status) : 0;
}

// The test's children: whatever a failed case left running is killed and reaped when it ends (a child left alive keeps
// the test's output open). Only a child not reaped yet is signalled: waitpid answers 0 for it alone, so a pid the case
// already reaped, which another process may have taken since, is never hit (AM51's rule, in the tests too; the
// integrator's review of 1153365).
struct Children {
    pid_t add()
    {
        const pid_t pid = idleChild();
        pids.push_back(pid);
        return pid;
    }
    ~Children()
    {
        for (pid_t pid : pids) {
            if (waitpid(pid, nullptr, WNOHANG) == 0) {
                kill(pid, SIGKILL);
                waitpid(pid, nullptr, 0);
            }
        }
    }
    std::vector<pid_t> pids;
};

int rowOf(ProcessTable &t, pid_t pid)
{
    for (int i = 0; i < t.count(); ++i) {
        if (t.data(t.index(i), ProcessTable::PidRole).toInt() == pid)
            return i;
    }
    return -1;
}

// A visible button of a sheet, by its text, in the item tree (a Repeater's buttons are not the sheet's QObject children).
QQuickItem *button(QQuickItem *item, const QString &text)
{
    if (item->inherits("QQuickAbstractButton") && item->isVisible() && item->property("text").toString() == text)
        return item;
    for (QQuickItem *child : item->childItems()) {
        if (QQuickItem *found = button(child, text))
            return found;
    }
    return nullptr;
}

// A dev session whose one root is this test's process (the children descend from it), or none: restored after.
struct DevRoots {
    explicit DevRoots(bool rooted)
        : saved{qgetenv("GRASSFIELD_DEV"), qgetenv("GRASSFIELD_SESSION"), qgetenv("GRASSFIELD_ACTIVITY_DEV_ROOTS")}
    {
        qputenv("GRASSFIELD_DEV", "1");
        qunsetenv("GRASSFIELD_SESSION");
        QByteArray roots;
        if (rooted) {
            QFile stat(QStringLiteral("/proc/self/stat"));
            const QByteArray line = stat.open(QIODevice::ReadOnly) ? stat.readAll() : QByteArray();
            const QList<QByteArray> fields = line.mid(line.lastIndexOf(')') + 2).split(' ');
            const QString record = dir.filePath(QStringLiteral("test.pid"));
            QFile pid(record), start(record + QStringLiteral(".start"));
            if (pid.open(QIODevice::WriteOnly) && start.open(QIODevice::WriteOnly)) {
                pid.write(QByteArray::number(getpid()) + '\n');
                start.write(fields.value(19) + '\n'); // stat field 22
            }
            roots = record.toLocal8Bit();
        }
        qputenv("GRASSFIELD_ACTIVITY_DEV_ROOTS", roots);
    }
    ~DevRoots()
    {
        const char *names[] = {"GRASSFIELD_DEV", "GRASSFIELD_SESSION", "GRASSFIELD_ACTIVITY_DEV_ROOTS"};
        for (int i = 0; i < 3; ++i)
            saved[i].isNull() ? qunsetenv(names[i]) : qputenv(names[i], saved[i]);
    }
    QByteArray saved[3];
    QTemporaryDir dir;
};

// The window on the real /proc, sampling every second, every process in `unit` (a test's children are in the unit of
// whatever runs the tests); `children` shown in its table.
::testing::AssertionResult open(Window &w, const char *unit, std::initializer_list<pid_t> children)
{
    if (!w.win || !QTest::qWaitForWindowExposed(w.win))
        return ::testing::AssertionFailure() << "no window";
    const std::string path = unit;
    w.backend->processActions().setUnitReader([path](int) { return path; });
    w.backend->setInterval(1);
    return becomes(
        [&] {
            for (pid_t c : children) {
                if (rowOf(w.backend->processTable(), c) < 0)
                    return false;
            }
            return true;
        },
        true, 6000);
}

void select(Window &w, pid_t pid)
{
    ProcessTable &t = w.backend->processTable();
    t.click(rowOf(t, pid), Qt::NoModifier);
}

} // namespace

// AM50, AM52, AM53: Stop opens the sheet; Quit (Return) sends SIGTERM; View > Quit Process's key and Force Quit, SIGKILL.
TEST(ActivityActions, QuitAndForceQuitAWindowlessChild)
{
    DevRoots dev(true);
    Window w(true);
    Children kids;
    const pid_t a = kids.add(), b = kids.add();
    ASSERT_TRUE(open(w, kPlainUnit, {a, b}));
    QQuickItem *stop = named(w.win, "stopButton");
    QQuickItem *sheet = named(w.win, "quitSheet");
    ASSERT_TRUE(stop && sheet);
    select(w, a);
    ASSERT_TRUE(becomes([&] { return stop->isEnabled(); }, true));
    settledClick(w.win, [&] { return centre(stop); });
    ASSERT_TRUE(becomes([&] { return sheet->isVisible(); }, true));
    EXPECT_EQ(sheet->property("title").toString(), "Are you sure you want to quit this process?");
    QTest::keyClick(w.win, Qt::Key_Return);
    EXPECT_EQ(ending(a), SIGTERM);
    EXPECT_FALSE(sheet->isVisible());

    select(w, b);
    QTest::keyClick(w.win, Qt::Key_Q, Qt::ControlModifier | Qt::AltModifier);
    ASSERT_TRUE(becomes([&] { return sheet->isVisible(); }, true));
    QQuickItem *force = button(sheet, QStringLiteral("Force Quit"));
    ASSERT_NE(force, nullptr);
    settledClick(w.win, [&] { return centre(force); });
    EXPECT_EQ(ending(b), SIGKILL);
    EXPECT_FALSE(sheet->isVisible());
}

// AM51, AM53: the sheet's process ends and is reaped while the sheet is open: Force Quit is silent and closes the sheet.
TEST(ActivityActions, AProcessThatEndsMeanwhileIsSilent)
{
    DevRoots dev(true);
    Window w(true);
    Children kids;
    const pid_t c = kids.add();
    ASSERT_TRUE(open(w, kPlainUnit, {c}));
    select(w, c);
    QQuickItem *sheet = named(w.win, "quitSheet");
    ASSERT_TRUE(becomes([&] { return named(w.win, "stopButton")->isEnabled(); }, true));
    QTest::keyClick(w.win, Qt::Key_Q, Qt::ControlModifier | Qt::AltModifier);
    ASSERT_TRUE(becomes([&] { return sheet->isVisible(); }, true));
    kill(c, SIGKILL);
    ASSERT_EQ(ending(c), SIGKILL);
    QQuickItem *force = button(sheet, QStringLiteral("Force Quit"));
    ASSERT_NE(force, nullptr);
    settledClick(w.win, [&] { return centre(force); });
    EXPECT_FALSE(sheet->isVisible());
    EXPECT_EQ(sheet->property("errorText").toString(), "");
}

// AM54, AM55: Send Signal to a session process: the warning first (Continue), then the pop-up without Stop, Terminate first.
TEST(ActivityActions, ASessionProcessWarnsFirstAndOffersNoStop)
{
    DevRoots dev(true);
    Window w(true);
    Children kids;
    const pid_t c = kids.add();
    ASSERT_TRUE(open(w, kSessionUnit, {c}));
    select(w, c);
    QQuickItem *sheets = named(w.win, "actionSheets");
    QQuickItem *warning = named(w.win, "sessionSheet");
    QQuickItem *signalSheet = named(w.win, "signalSheet");
    QQuickItem *picker = named(w.win, "signalPicker");
    ASSERT_TRUE(sheets && warning && signalSheet && picker);
    ASSERT_TRUE(becomes([&] { return w.backend->processActions().canSignal(); }, true));
    QMetaObject::invokeMethod(sheets, "openSignal");
    ASSERT_TRUE(becomes([&] { return warning->isVisible(); }, true));
    EXPECT_TRUE(warning->property("title").toString().startsWith("Sending a signal to “"));
    QQuickItem *cont = button(warning, QStringLiteral("Continue"));
    ASSERT_NE(cont, nullptr);
    settledClick(w.win, [&] { return centre(cont); });
    ASSERT_TRUE(becomes([&] { return signalSheet->isVisible(); }, true));
    QStringList offered;
    for (const QVariant &v : picker->property("model").toList())
        offered << v.toMap().value(QStringLiteral("text")).toString();
    EXPECT_EQ(offered.size(), 10);
    EXPECT_FALSE(offered.contains(QStringLiteral("Stop (SIGSTOP)")));
    EXPECT_EQ(picker->property("displayText").toString(), "Terminate (SIGTERM)");
    QQuickItem *send = button(signalSheet, QStringLiteral("Send"));
    ASSERT_NE(send, nullptr);
    settledClick(w.win, [&] { return centre(send); });
    EXPECT_EQ(ending(c), SIGTERM);
    EXPECT_FALSE(signalSheet->isVisible());
}

// AM56: a dev session without a root for this process: the sheet says so and nothing is sent.
TEST(ActivityActions, TheDevGuardRefusesAProcessOutsideItsRoots)
{
    DevRoots dev(false);
    Window w(true);
    Children kids;
    const pid_t c = kids.add();
    ASSERT_TRUE(open(w, kPlainUnit, {c}));
    select(w, c);
    QQuickItem *sheet = named(w.win, "quitSheet");
    ASSERT_TRUE(becomes([&] { return named(w.win, "stopButton")->isEnabled(); }, true));
    QTest::keyClick(w.win, Qt::Key_Q, Qt::ControlModifier | Qt::AltModifier);
    ASSERT_TRUE(becomes([&] { return sheet->isVisible(); }, true));
    QTest::keyClick(w.win, Qt::Key_Return);
    EXPECT_TRUE(sheet->isVisible());
    EXPECT_EQ(sheet->property("errorText").toString(), "Development session: only the nested session's processes can be quit.");
    EXPECT_EQ(ending(c, 0), -1);
    QTest::keyClick(w.win, Qt::Key_Escape);
    EXPECT_FALSE(sheet->isVisible());
}

// ---- A-W3 (step 2d) ------------------------------------------------------------------------------------------------------
namespace {

QList<QQuickWindow *> inspectWindows(Window &w)
{
    QList<QQuickWindow *> out;
    for (const QVariant &v : w.win->property("ownWindows").toList()) {
        if (auto *iw = qobject_cast<QQuickWindow *>(v.value<QObject *>()))
            out << iw;
    }
    return out;
}

Inspection *inspectionOf(QQuickWindow *iw)
{
    return qobject_cast<Inspection *>(iw->property("inspection").value<QObject *>());
}

QString rowValue(const QVariantList &rows, const QString &label)
{
    for (const QVariant &r : rows) {
        if (r.toMap().value(QStringLiteral("label")).toString() == label)
            return r.toMap().value(QStringLiteral("value")).toString();
    }
    return QString();
}

} // namespace

// AM57 to AM59, AD45: the Info button opens the selected child's Inspect window; its header and tabs fill from the reads
// on the sampler's thread; a second request (Ctrl+I) brings the same window back; its Quit sends SIGTERM through AM51's
// path, and the window closes once the process has ended.
TEST(ActivityInspect, TheInfoButtonOpensAWindowThatReadsAndQuits)
{
    DevRoots dev(true);
    Window w(true);
    Children kids;
    const pid_t a = kids.add();
    ASSERT_TRUE(open(w, kPlainUnit, {a}));
    QQuickItem *info = named(w.win, "infoButton");
    ASSERT_NE(info, nullptr);
    select(w, a);
    ASSERT_TRUE(becomes([&] { return info->isEnabled(); }, true));
    settledClick(w.win, [&] { return centre(info); });
    ASSERT_TRUE(becomes([&] { return inspectWindows(w).size() == 1; }, true));
    QQuickWindow *iw = inspectWindows(w).constFirst();
    Inspection *ins = inspectionOf(iw);
    ASSERT_NE(ins, nullptr);
    EXPECT_TRUE(iw->title().endsWith(QStringLiteral(" (%1)").arg(a))) << iw->title().toStdString();
    ASSERT_TRUE(QTest::qWaitForWindowExposed(iw));
    ASSERT_TRUE(becomes([&] { return ins->ready(); }, true));
    EXPECT_TRUE(ins->parentText().endsWith(QStringLiteral(" (%1)").arg(getpid()))) << ins->parentText().toStdString();
    EXPECT_NE(rowValue(ins->memoryRows(), QStringLiteral("Real Memory Size:")), dash());
    EXPECT_NE(rowValue(ins->memoryRows(), QStringLiteral("Proportional Memory Size:")), dash()); // its own: smaps_rollup
    ins->setTab(QStringLiteral("statistics"));
    ASSERT_TRUE(becomes([&] { return rowValue(ins->statisticsRows(), QStringLiteral("Executable:")) != dash(); }, true));
    ins->setTab(QStringLiteral("files"));
    ASSERT_TRUE(becomes([&] { return !ins->files().isEmpty(); }, true));

    // A second request: the same window, no other.
    w.win->requestActivate();
    QTest::keyClick(w.win, Qt::Key_I, Qt::ControlModifier);
    QTest::qWait(200);
    EXPECT_EQ(inspectWindows(w).size(), 1);

    QQuickItem *quit = named(iw, "inspectQuit");
    QQuickItem *sheet = named(iw, "quitSheet");
    ASSERT_TRUE(quit && sheet);
    EXPECT_TRUE(quit->isEnabled());
    settledClick(iw, [&] { return centre(quit); });
    ASSERT_TRUE(becomes([&] { return sheet->isVisible(); }, true));
    QTest::keyClick(iw, Qt::Key_Return);
    EXPECT_EQ(ending(a), SIGTERM);
    ASSERT_TRUE(becomes([&] { return inspectWindows(w).isEmpty(); }, true)); // AD45
    EXPECT_TRUE(becomes([&] { return w.backend->inspectors().count(); }, 0)); // let go once its window is destroyed
}

// AM57: another owner's process (pid 1, root's): what stat and status give, "—" elsewhere, Open Files and Ports says why,
// and Quit is off. Every Inspect window closes with the main window (AD17).
TEST(ActivityInspect, AnotherOwnersProcessAndTheMainWindowsClose)
{
    if (geteuid() == 0)
        GTEST_SKIP() << "run as the app's user: root's own processes are its own";
    struct stat init{};
    if (stat("/proc/1", &init) != 0 || init.st_uid == geteuid()) // a container whose pid 1 is this user's (review of 5bfd4419)
        GTEST_SKIP() << "pid 1 is this user's here: no other owner's process to inspect";
    Window w(true);
    ASSERT_TRUE(open(w, kPlainUnit, {}));
    ProcessTable &t = w.backend->processTable();
    ASSERT_TRUE(becomes([&] { return rowOf(t, 1) >= 0; }, true));
    w.backend->inspectRow(rowOf(t, 1)); // a double-click
    ASSERT_TRUE(becomes([&] { return inspectWindows(w).size() == 1; }, true));
    QQuickWindow *iw = inspectWindows(w).constFirst();
    Inspection *ins = inspectionOf(iw);
    ASSERT_TRUE(QTest::qWaitForWindowExposed(iw));
    ASSERT_TRUE(becomes([&] { return ins->ready(); }, true));
    EXPECT_FALSE(ins->own());
    EXPECT_NE(rowValue(ins->memoryRows(), QStringLiteral("Real Memory Size:")), dash());
    EXPECT_EQ(rowValue(ins->memoryRows(), QStringLiteral("Proportional Memory Size:")), dash());
    ins->setTab(QStringLiteral("statistics"));
    ASSERT_TRUE(becomes([&] { return rowValue(ins->statisticsRows(), QStringLiteral("Threads:")) != dash(); }, true));
    EXPECT_EQ(rowValue(ins->statisticsRows(), QStringLiteral("Command:")), dash());
    EXPECT_EQ(rowValue(ins->statisticsRows(), QStringLiteral("Working Folder:")), dash());
    ins->setTab(QStringLiteral("files"));
    EXPECT_EQ(ins->filesNote(), QStringLiteral("The open files of another user's process can't be read."));
    EXPECT_FALSE(named(iw, "inspectQuit")->isEnabled());

    w.win->close();
    ASSERT_TRUE(becomes([&] { return inspectWindows(w).isEmpty(); }, true));
}
