// Backend (apps/settings/src/backend.h): the glue between the pages and their processes (counter-review of PR #6). A request
// gets its own answer unless it opts in to reuse a command still running (Storage's counts); an action that may wait for a
// password runs one per tag. Nothing real runs: PATH holds only a scratch folder of fake commands, each of which records its
// starts, so omarchy-language, wpctl or any other tool of the machine cannot be reached; no test talks to a bus.
#include <gtest/gtest.h>

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMap>
#include <QTemporaryDir>
#include <QThread>

#include <algorithm>

#include "backend.h"

namespace {

// One application object per process: tst_busjobs.cpp, in the same binary, may have made it first.
QCoreApplication &app()
{
    if (QCoreApplication *existing = QCoreApplication::instance())
        return *existing;
    static int argc = 1;
    static char name[] = "tst_backend";
    static char *argv[] = {name, nullptr};
    static QCoreApplication instance(argc, argv);
    return instance;
}

template<typename Predicate>
bool spinUntil(Predicate done, int ms = 5000)
{
    QElapsedTimer t;
    t.start();
    while (!done() && t.elapsed() < ms) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        QThread::msleep(2);
    }
    return done();
}

// What a Backend answered: finished signals per tag (with the last answer and reason), pendingActionsChanged signals,
// suppressed actions. Declared before the Backend, so it outlives it.
struct Answers {
    QMap<QString, int> finished;
    QMap<QString, bool> ok;
    QMap<QString, QString> output;
    QMap<QString, QString> reason;
    QStringList suppressed;
    int pendingChanges = 0;

    void listen(Backend &backend)
    {
        QObject::connect(&backend, &Backend::finished, [this](const QString &tag, bool good, const QString &out) {
            ++finished[tag];
            ok[tag] = good;
            output[tag] = out;
        });
        QObject::connect(&backend, &Backend::failed, [this](const QString &tag, const QString &why) { reason[tag] = why; });
        QObject::connect(&backend, &Backend::pendingActionsChanged, [this] { ++pendingChanges; });
        QObject::connect(&backend, &Backend::suppressed, [this](const QString &what) { suppressed << what; });
    }
};

// Variables a test sets, put back as they were when it ends.
class EnvGuard
{
public:
    explicit EnvGuard(std::initializer_list<const char *> names)
    {
        for (const char *n : names)
            m_saved.append({n, qEnvironmentVariableIsSet(n), qgetenv(n)});
    }
    ~EnvGuard()
    {
        for (const Saved &s : std::as_const(m_saved)) {
            if (s.set)
                qputenv(s.name, s.value);
            else
                qunsetenv(s.name);
        }
    }

private:
    struct Saved {
        const char *name;
        bool set;
        QByteArray value;
    };
    QList<Saved> m_saved;
};

} // namespace

// A real (not dev) session, whose PATH is a scratch folder of fake commands; both restored afterwards.
class BackendTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        app();
        ASSERT_TRUE(m_dir.isValid());
        m_path = qgetenv("PATH");
        m_hadDev = qEnvironmentVariableIsSet("GRASSFIELD_DEV");
        m_dev = qgetenv("GRASSFIELD_DEV");
        // Only the scratch folder: the machine's own tools are never found, whatever the Backend is asked to run.
        qputenv("PATH", QFile::encodeName(m_dir.path()));
        qunsetenv("GRASSFIELD_DEV"); // a dev session would suppress every action
        for (const char *tool : {"gf-fake-query", "omarchy-language", "wpctl"})
            writeTool(QString::fromLatin1(tool));
    }

    void TearDown() override
    {
        qputenv("PATH", m_path);
        if (m_hadDev)
            qputenv("GRASSFIELD_DEV", m_dev);
        else
            qunsetenv("GRASSFIELD_DEV");
    }

    // How many times the fake `tool` started.
    int runs(const QString &tool) const
    {
        QFile f(m_dir.filePath(tool + QStringLiteral(".runs")));
        return f.open(QIODevice::ReadOnly) ? f.readAll().count('\n') : 0;
    }

    // A fake command that records its arguments, then the values of QS_CONFIG_PATH and XDG_CACHE_HOME, one line per start
    // (`recorded`), and prints `answer`.
    void writeRecorder(const QString &tool, const QByteArray &answer)
    {
        QFile f(m_dir.filePath(tool));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("#!/bin/sh\necho \"$*|${QS_CONFIG_PATH-unset}|${XDG_CACHE_HOME-unset}\" >> '" + QFile::encodeName(m_dir.filePath(tool + QStringLiteral(".args")))
                + "'\nprintf '%s\\n' '" + answer + "'\n");
        f.close();
        ASSERT_TRUE(f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner));
    }

    QStringList recorded(const QString &tool) const
    {
        QFile f(m_dir.filePath(tool + QStringLiteral(".args")));
        return f.open(QIODevice::ReadOnly) ? QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'), Qt::SkipEmptyParts) : QStringList{};
    }

    QString scratch(const QString &name) const { return m_dir.filePath(name); }

private:
    // A fake command: records its start, answers after a moment (long enough for a second request to find it running).
    void writeTool(const QString &tool)
    {
        QFile f(m_dir.filePath(tool));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("#!/bin/sh\necho run >> '" + QFile::encodeName(m_dir.filePath(tool + QStringLiteral(".runs"))) + "'\n/usr/bin/sleep 0.3\necho done\n");
        f.close();
        ASSERT_TRUE(f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner));
    }

    QTemporaryDir m_dir;
    QByteArray m_path;
    QByteArray m_dev;
    bool m_hadDev = false;
};

// ---- queries: one answer per request ----

// The regression of 0a336de: WallpaperPage counts one finished per thumbnail request (thumbBusy, two at a time). A click on a
// tile asks again for a thumbnail still in flight (it updates Recents); when that second request got no answer of its own, the
// count stayed one too high, and after two such clicks no thumbnail loaded until the page was opened again.
TEST_F(BackendTest, EveryRequestOfAThumbnailGetsItsOwnAnswer)
{
    const QString tag = QStringLiteral("wp.thumb:/pictures/a.jpg");
    const QStringList argv{QStringLiteral("gf-fake-query"), QStringLiteral("thumb"), QStringLiteral("--"), QStringLiteral("/pictures/a.jpg")};
    int busy = 0; // WallpaperPage.thumbBusy: up on each request, down (not below 0) on each answer
    Answers seen;
    Backend backend;
    seen.listen(backend);
    QObject::connect(&backend, &Backend::finished, [&busy, tag](const QString &t, bool, const QString &) {
        if (t == tag)
            busy = std::max(0, busy - 1);
    });
    ++busy;
    backend.query(argv, tag, 20000);
    ++busy;
    backend.query(argv, tag, 20000); // the same picture again while its thumbnail is the one in flight
    EXPECT_TRUE(spinUntil([&] { return busy == 0; })) << "the page waits for " << busy << " answer(s) that never come";
    spinUntil([] { return false; }, 200);
    EXPECT_EQ(seen.finished.value(tag), 2);
    EXPECT_EQ(busy, 0);
    EXPECT_EQ(runs(QStringLiteral("gf-fake-query")), 2);
}

// Storage shown again while its counts run (du and pacman -Qi, up to two minutes each) opts in: the command still running under
// the same tag is not started again, and its one answer reaches the new page, which counts one answer per count.
TEST_F(BackendTest, ASharedQueryStillRunningIsReused)
{
    const QString tag = QStringLiteral("storage.du");
    const QStringList argv{QStringLiteral("gf-fake-query"), QStringLiteral("-s"), QStringLiteral("/home/u/Documents")};
    Answers seen;
    Backend backend;
    seen.listen(backend);
    backend.query(argv, tag, 5000, true);
    backend.query(argv, tag, 5000, true); // the page shown again
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(tag) >= 1; }));
    spinUntil([] { return false; }, 200);
    EXPECT_EQ(seen.finished.value(tag), 1);
    EXPECT_EQ(runs(QStringLiteral("gf-fake-query")), 1);

    // Once it answered, the same query runs again; another command under a running tag is not that command: it runs too.
    backend.query(argv, tag, 5000, true);
    backend.query({QStringLiteral("gf-fake-query"), QStringLiteral("-s"), QStringLiteral("/home/u/Music")}, tag, 5000, true);
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(tag) >= 3; }));
    spinUntil([] { return false; }, 200);
    EXPECT_EQ(seen.finished.value(tag), 3);
    EXPECT_EQ(runs(QStringLiteral("gf-fake-query")), 3);
}

// About's lspci and pacman -Q (AboutFacts.qml, AboutPage.qml) are read-only queries (the re-review of c6cf328): held to
// systemguard.h's allow-list in a real session too, where query() alone runs whatever a page asks for, as run() did.
TEST_F(BackendTest, AReadOnlyQueryTakesOnlyTheAllowListInARealSession)
{
    writeRecorder(QStringLiteral("lspci"), "00:02.0 VGA compatible controller: Intel Corporation Device");
    Answers seen;
    Backend backend;
    seen.listen(backend);
    backend.readOnlyQuery({QStringLiteral("gf-fake-query")}, QStringLiteral("stray"));
    EXPECT_EQ(seen.finished.value(QStringLiteral("stray")), 1); // refused at once
    EXPECT_FALSE(seen.ok.value(QStringLiteral("stray")));
    backend.readOnlyQuery({QStringLiteral("lspci"), QStringLiteral("-vv")}, QStringLiteral("stray"));
    EXPECT_EQ(seen.finished.value(QStringLiteral("stray")), 2);
    backend.readOnlyQuery({QStringLiteral("lspci")}, QStringLiteral("facts.lspci"), 5000, true);
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(QStringLiteral("facts.lspci")) >= 1; }));
    EXPECT_TRUE(seen.ok.value(QStringLiteral("facts.lspci")));
    EXPECT_TRUE(seen.output.value(QStringLiteral("facts.lspci")).contains(QStringLiteral("VGA")));
    spinUntil([] { return false; }, 400);
    EXPECT_EQ(runs(QStringLiteral("gf-fake-query")), 0);
    EXPECT_EQ(recorded(QStringLiteral("lspci")).size(), 1); // the allowed form only, once

    // query() runs it in a real session: the backstop is readOnlyQuery's own.
    backend.query({QStringLiteral("gf-fake-query")}, QStringLiteral("plain"));
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(QStringLiteral("plain")) >= 1; }));
    EXPECT_EQ(runs(QStringLiteral("gf-fake-query")), 1);
}

// Share Network's QR code (ADR-0045 OC-10) encodes the Wi-Fi password: readOnlyQuery runs it in a real session only, a dev
// session (whose Wi-Fi pane reads the owner's real NetworkManager) never (security review of ADR-0045, M-2), and run() never.
TEST_F(BackendTest, TheWifiCodeRunsInARealSessionOnly)
{
    writeRecorder(QStringLiteral("omarchy-network-qr"), "meta");
    const QStringList code{QStringLiteral("omarchy-network-qr"), QStringLiteral("--meta")};
    Answers seen;
    Backend backend;
    seen.listen(backend);
    backend.readOnlyQuery(code, QStringLiteral("wifi.qr"));
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(QStringLiteral("wifi.qr")) >= 1; }));
    EXPECT_TRUE(seen.ok.value(QStringLiteral("wifi.qr")));
    EXPECT_EQ(backend.run(code), QString());
    backend.readOnlyQuery({QStringLiteral("omarchy-network-qr"), QStringLiteral("--meta"), QStringLiteral("wlan0")}, QStringLiteral("stray"));
    EXPECT_EQ(seen.finished.value(QStringLiteral("stray")), 1);
    EXPECT_FALSE(seen.ok.value(QStringLiteral("stray")));
    spinUntil([] { return false; }, 300);
    EXPECT_EQ(recorded(QStringLiteral("omarchy-network-qr")).size(), 1);

    EnvGuard env{"GRASSFIELD_DEV", "GRASSFIELD_SESSION"};
    qputenv("GRASSFIELD_DEV", "1");
    qunsetenv("GRASSFIELD_SESSION");
    Backend dev;
    Answers devSeen;
    devSeen.listen(dev);
    dev.readOnlyQuery(code, QStringLiteral("wifi.qr"));
    EXPECT_EQ(devSeen.finished.value(QStringLiteral("wifi.qr")), 1); // refused at once
    EXPECT_FALSE(devSeen.ok.value(QStringLiteral("wifi.qr")));
    dev.query(code, QStringLiteral("wifi.qr.plain"));
    EXPECT_EQ(devSeen.finished.value(QStringLiteral("wifi.qr.plain")), 1);
    EXPECT_FALSE(devSeen.ok.value(QStringLiteral("wifi.qr.plain")));
    spinUntil([] { return false; }, 300);
    EXPECT_EQ(recorded(QStringLiteral("omarchy-network-qr")).size(), 1) << "nothing more ran in the dev session";
}

// ---- actions: one per tag while it may wait for a password ----

// Language & Region shown again while Omarchy's prompt is up (omarchy-language may wait for pkexec) cannot start a second
// prompt: the waiting state is the Backend's (pendingActions), not the page's, which every visit creates anew.
TEST_F(BackendTest, AnActionThatMayAskForAPasswordIsRefusedWhileOneOfItsTagRuns)
{
    Answers seen;
    Backend backend;
    seen.listen(backend);
    const QString tag = QStringLiteral("language.act");
    const QString what = QStringLiteral("language");
    ASSERT_TRUE(backend.act(what, {QStringLiteral("omarchy-language"), QStringLiteral("fr")}, tag));
    EXPECT_EQ(backend.pendingActions(), (QVariantMap{{tag, what}}));
    EXPECT_EQ(seen.pendingChanges, 1);

    // Refused, whatever it asks: nothing starts, no answer comes for it, the first one stays pending.
    EXPECT_FALSE(backend.act(what, {QStringLiteral("omarchy-language"), QStringLiteral("fr")}, tag));
    EXPECT_FALSE(backend.act(QStringLiteral("other"), {QStringLiteral("omarchy-language"), QStringLiteral("de")}, tag));
    EXPECT_EQ(backend.pendingActions(), (QVariantMap{{tag, what}}));
    EXPECT_EQ(seen.pendingChanges, 1);

    // It ends: the tag is free again, and its one answer came.
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(tag) >= 1; }));
    EXPECT_TRUE(backend.pendingActions().isEmpty());
    EXPECT_EQ(seen.pendingChanges, 2);
    spinUntil([] { return false; }, 200);
    EXPECT_EQ(seen.finished.value(tag), 1);
    EXPECT_EQ(runs(QStringLiteral("omarchy-language")), 1);

    // The next change of that tag runs.
    EXPECT_TRUE(backend.act(what, {QStringLiteral("omarchy-language"), QStringLiteral("de")}, tag));
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(tag) >= 2; }));
    EXPECT_TRUE(backend.pendingActions().isEmpty());
    EXPECT_EQ(runs(QStringLiteral("omarchy-language")), 2);
}

TEST_F(BackendTest, AnotherTagIsAnotherAction)
{
    Answers seen;
    Backend backend;
    seen.listen(backend);
    EXPECT_TRUE(backend.act(QStringLiteral("language"), {QStringLiteral("omarchy-language"), QStringLiteral("fr")}, QStringLiteral("language.act")));
    EXPECT_TRUE(backend.act(QStringLiteral("language"), {QStringLiteral("omarchy-language"), QStringLiteral("de")}, QStringLiteral("other.act")));
    EXPECT_EQ(backend.pendingActions().size(), 2);
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(QStringLiteral("language.act")) == 1 && seen.finished.value(QStringLiteral("other.act")) == 1; }));
    EXPECT_TRUE(backend.pendingActions().isEmpty());
    EXPECT_EQ(runs(QStringLiteral("omarchy-language")), 2);
}

// An action that never asks for a password is not held back (the volume slider sends one wpctl per step) and is never pending.
TEST_F(BackendTest, AnActionWithoutAPasswordIsNotHeldBack)
{
    Answers seen;
    Backend backend;
    seen.listen(backend);
    const QString tag = QStringLiteral("audio.act");
    EXPECT_TRUE(backend.act(QStringLiteral("volume"), {QStringLiteral("wpctl"), QStringLiteral("set-volume"), QStringLiteral("52"), QStringLiteral("0.40")}, tag));
    EXPECT_TRUE(backend.act(QStringLiteral("volume"), {QStringLiteral("wpctl"), QStringLiteral("set-volume"), QStringLiteral("52"), QStringLiteral("0.50")}, tag));
    EXPECT_TRUE(backend.pendingActions().isEmpty());
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(tag) == 2; }));
    EXPECT_EQ(seen.pendingChanges, 0);
    EXPECT_EQ(runs(QStringLiteral("wpctl")), 2);
}

// ---- Software Update (ADR-0033; docs/specs/updates.md U8, U10-U14) ----

// Beta Updates, Set Up…, Repair…, Turn Off…: only the installed grassfield-channel-set with one verb is an action. The allowed
// form is never started here (it would ask the machine's polkit); its one-per-tag latch is the one omarchy-language's tests
// above hold (systemguard asksForPassword names both).
TEST_F(BackendTest, AChannelChangeIsOnlyTheInstalledCommand)
{
    writeRecorder(QStringLiteral("grassfield-channel-set"), "");
    Answers seen;
    Backend backend;
    seen.listen(backend);
    const QString tag = QStringLiteral("update.channel.act");
    EXPECT_FALSE(backend.act(QStringLiteral("beta updates"), {QStringLiteral("grassfield-channel-set"), QStringLiteral("beta")}, tag))
        << "a grassfield-channel-set found on PATH";
    EXPECT_FALSE(backend.act(QStringLiteral("custom"), {QStringLiteral("/usr/lib/grassfield/grassfield-channel-set"), QStringLiteral("custom")}, tag));
    EXPECT_TRUE(backend.pendingActions().isEmpty());
    spinUntil([] { return false; }, 200);
    EXPECT_TRUE(recorded(QStringLiteral("grassfield-channel-set")).isEmpty());
    EXPECT_TRUE(seen.finished.isEmpty());
}

// Update Now: Omarchy's launcher, started and left running (its terminal outlives Settings); only the exact vector.
TEST_F(BackendTest, UpdateNowStartsOmarchysLauncherDetached)
{
    const QString launcher = QStringLiteral("omarchy-launch-floating-terminal-with-presentation");
    writeRecorder(launcher, "");
    Answers seen;
    Backend backend;
    seen.listen(backend);
    EXPECT_FALSE(backend.launch(QStringLiteral("update now"), {launcher, QStringLiteral("omarchy-update"), QStringLiteral("-y")}));
    EXPECT_FALSE(backend.launch(QStringLiteral("update now"), {launcher, QStringLiteral("bash")}));
    EXPECT_TRUE(backend.launch(QStringLiteral("update now"), {launcher, QStringLiteral("omarchy-update")}));
    ASSERT_TRUE(spinUntil([&] { return !recorded(launcher).isEmpty(); }));
    spinUntil([] { return false; }, 200);
    ASSERT_EQ(recorded(launcher).size(), 1);
    EXPECT_TRUE(recorded(launcher).at(0).startsWith(QStringLiteral("omarchy-update|")));
    EXPECT_TRUE(seen.finished.isEmpty()) << "a launch is left running: no answer comes for it";

    // A dev session starts nothing: one suppressed line.
    EnvGuard env{"GRASSFIELD_DEV", "GRASSFIELD_SESSION"};
    qputenv("GRASSFIELD_DEV", "1");
    qunsetenv("GRASSFIELD_SESSION");
    Backend dev;
    Answers devSeen;
    devSeen.listen(dev);
    EXPECT_FALSE(dev.launch(QStringLiteral("update now"), {launcher, QStringLiteral("omarchy-update")}));
    // Nor the runner of the update without a terminal (never started by a test: it would ask for the root helper).
    EXPECT_FALSE(dev.launch(QStringLiteral("update now"), {QStringLiteral("/usr/lib/grassfield/grassfield-update-run")}));
    EXPECT_EQ(devSeen.suppressed, (QStringList{QStringLiteral("update now"), QStringLiteral("update now")}));
    spinUntil([] { return false; }, 300);
    EXPECT_EQ(recorded(launcher).size(), 1);
}

// ADR-0045 OC-0.4: a setup no system service offers opens Omarchy's terminal with Omarchy's command alone; the pane's sheet
// explains first. Any other command in that terminal is refused.
TEST_F(BackendTest, OmarchysSetupsStartInItsTerminalAndNothingElseDoes)
{
    const QString launcher = QStringLiteral("omarchy-launch-floating-terminal-with-presentation");
    writeRecorder(launcher, "");
    writeRecorder(QStringLiteral("omarchy-voxtype-model"), "");
    Backend backend;
    EXPECT_TRUE(backend.launch(QStringLiteral("hibernation setup"), {launcher, QStringLiteral("omarchy-hibernation-setup")}));
    EXPECT_TRUE(backend.launch(QStringLiteral("dictation model"), {QStringLiteral("omarchy-voxtype-model")}));
    EXPECT_FALSE(backend.launch(QStringLiteral("hibernation setup"), {launcher, QStringLiteral("omarchy-hibernation-setup"), QStringLiteral("--force")}));
    EXPECT_FALSE(backend.launch(QStringLiteral("remote login"), {launcher, QStringLiteral("omarchy-remove-security-sshd")}));
    ASSERT_TRUE(spinUntil([&] { return !recorded(launcher).isEmpty() && !recorded(QStringLiteral("omarchy-voxtype-model")).isEmpty(); }));
    spinUntil([] { return false; }, 200);
    ASSERT_EQ(recorded(launcher).size(), 1);
    EXPECT_TRUE(recorded(launcher).at(0).startsWith(QStringLiteral("omarchy-hibernation-setup|")));
}

// ADR-0045 OC-0.3: a pane asks whether a plain command is on PATH (nothing runs); a path, a relative name or an option is no
// command name.
TEST_F(BackendTest, ACommandIsLookedUpByItsPlainNameOnly)
{
    writeRecorder(QStringLiteral("voxtype"), "");
    Backend backend;
    EXPECT_TRUE(backend.hasCommand(QStringLiteral("voxtype")));
    EXPECT_FALSE(backend.hasCommand(QStringLiteral("fprintd-enroll")));
    EXPECT_FALSE(backend.hasCommand(scratch(QStringLiteral("voxtype"))));
    EXPECT_FALSE(backend.hasCommand(QStringLiteral("../voxtype")));
    EXPECT_FALSE(backend.hasCommand(QStringLiteral("-voxtype")));
    EXPECT_FALSE(backend.hasCommand(QString()));
    EXPECT_FALSE(backend.hasCommand(QString(65, QLatin1Char('v'))));
    spinUntil([] { return false; }, 100);
    EXPECT_TRUE(recorded(QStringLiteral("voxtype")).isEmpty()) << "a look-up runs nothing";
}

// Update Now's runner keeps its state in the session's runtime folder; without one there is no file to read.
TEST_F(BackendTest, TheRunnersStateIsInTheRuntimeFolder)
{
    EnvGuard env{"XDG_RUNTIME_DIR"};
    qputenv("XDG_RUNTIME_DIR", "/run/user/1000/");
    EXPECT_EQ(Backend().softwareUpdateRunFile(), QStringLiteral("/run/user/1000/grassfield/software-update-run.json"));
    qputenv("XDG_RUNTIME_DIR", "relative");
    EXPECT_EQ(Backend().softwareUpdateRunFile(), QString());
    qunsetenv("XDG_RUNTIME_DIR");
    EXPECT_EQ(Backend().softwareUpdateRunFile(), QString());
}

// The shell is asked by its directory (never a configuration found through QS_*): `update check user`; "ok" means it checks.
TEST_F(BackendTest, TheShellIsAskedToCheckByItsDirectory)
{
    EnvGuard env{"QS_CONFIG_PATH", "GRASSFIELD_SHELL_DIR"};
    writeRecorder(QStringLiteral("qs"), "ok");
    qputenv("QS_CONFIG_PATH", "/home/u/.config/quickshell/other");
    qputenv("GRASSFIELD_SHELL_DIR", "/work/shell"); // dev plumbing: inert outside a dev session
    Answers seen;
    Backend backend;
    seen.listen(backend);
    const QString tag = QStringLiteral("update.ask");
    backend.askShellToCheck(tag);
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(tag) >= 1; }));
    EXPECT_TRUE(seen.ok.value(tag));
    EXPECT_EQ(seen.output.value(tag).trimmed(), QStringLiteral("ok"));
    const QStringList calls = recorded(QStringLiteral("qs"));
    ASSERT_EQ(calls.size(), 1);
    EXPECT_TRUE(calls.at(0).startsWith(QStringLiteral("ipc -p /usr/share/grassfield/shell call update check user|unset|"))) << calls.at(0).toStdString();
}

// A dev session asks the shell GRASSFIELD_SHELL_DIR names, and no shell at all without it (never the installed one).
TEST_F(BackendTest, ADevSessionAsksOnlyItsOwnShell)
{
    EnvGuard env{"GRASSFIELD_DEV", "GRASSFIELD_SESSION", "GRASSFIELD_SHELL_DIR"};
    writeRecorder(QStringLiteral("qs"), "ok");
    qputenv("GRASSFIELD_DEV", "1");
    qunsetenv("GRASSFIELD_SESSION");
    qunsetenv("GRASSFIELD_SHELL_DIR");
    Answers seen;
    Backend backend;
    seen.listen(backend);
    backend.askShellToCheck(QStringLiteral("a"));
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(QStringLiteral("a")) >= 1; }));
    EXPECT_FALSE(seen.ok.value(QStringLiteral("a")));
    EXPECT_FALSE(seen.reason.value(QStringLiteral("a")).isEmpty());
    EXPECT_TRUE(recorded(QStringLiteral("qs")).isEmpty());

    qputenv("GRASSFIELD_SHELL_DIR", "/work/shell");
    backend.askShellToCheck(QStringLiteral("b"));
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(QStringLiteral("b")) >= 1; }));
    EXPECT_TRUE(seen.ok.value(QStringLiteral("b")));
    ASSERT_EQ(recorded(QStringLiteral("qs")).size(), 1);
    EXPECT_TRUE(recorded(QStringLiteral("qs")).at(0).startsWith(QStringLiteral("ipc -p /work/shell call update check user|")));
}

// A refusal comes on a later turn of the event loop, never from inside the call: the Software Update pane asks while it is
// being built, before its connections to finished() exist, and an answer emitted at once was lost (the pane stayed on
// "Checking for updates…" for good in a dev session with no shell).
TEST_F(BackendTest, TheRefusalToAskTheShellIsNeverImmediate)
{
    EnvGuard env{"GRASSFIELD_DEV", "GRASSFIELD_SESSION", "GRASSFIELD_SHELL_DIR"};
    qputenv("GRASSFIELD_DEV", "1");
    qunsetenv("GRASSFIELD_SESSION");
    qunsetenv("GRASSFIELD_SHELL_DIR");
    Answers seen;
    Backend backend;
    seen.listen(backend);
    const QString tag = QStringLiteral("update.ask");
    backend.askShellToCheck(tag);
    EXPECT_EQ(seen.finished.value(tag), 0) << "the answer came from inside askShellToCheck()";
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(tag) >= 1; }));
    EXPECT_FALSE(seen.ok.value(tag));
    EXPECT_FALSE(seen.reason.value(tag).isEmpty());
}

// The canned battery of a dev session (GRASSFIELD_POWER_FIXTURE, ADR-0019 dev plumbing): `power.state` is answered from the file
// without a bus; outside a dev session (or with GRASSFIELD_DEV=1 leaked into a packaged session) the variable is inert.
TEST_F(BackendTest, PowerFixtureOnlyInADevSession)
{
    EnvGuard env{"GRASSFIELD_DEV", "GRASSFIELD_SESSION", "GRASSFIELD_POWER_FIXTURE"};
    QFile fixture(scratch(QStringLiteral("power.json")));
    ASSERT_TRUE(fixture.open(QIODevice::WriteOnly));
    fixture.write("{\"present\":true,\"onBattery\":false,\"percent\":80,\"state\":1}\n");
    fixture.close();
    qputenv("GRASSFIELD_POWER_FIXTURE", QFile::encodeName(fixture.fileName()));
    for (const char *session : {"", "1"}) {
        if (*session) {
            qputenv("GRASSFIELD_DEV", "1");
            qputenv("GRASSFIELD_SESSION", session);
        } else {
            qunsetenv("GRASSFIELD_DEV");
            qunsetenv("GRASSFIELD_SESSION");
        }
        EXPECT_EQ(Backend::powerFixture(), QString()) << session;
    }
    qunsetenv("GRASSFIELD_SESSION");
    qputenv("GRASSFIELD_DEV", "1");
    EXPECT_EQ(Backend::powerFixture(), fixture.fileName());

    Answers seen;
    Backend backend;
    seen.listen(backend);
    backend.busQuery(QStringLiteral("power.state"), QStringLiteral("power"));
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(QStringLiteral("power")) >= 1; }));
    EXPECT_TRUE(seen.ok.value(QStringLiteral("power")));
    EXPECT_EQ(seen.output.value(QStringLiteral("power")), QStringLiteral("{\"present\":true,\"onBattery\":false,\"percent\":80,\"state\":1}"));

    // A file that cannot be read: a failed answer with its reason, never a battery.
    qputenv("GRASSFIELD_POWER_FIXTURE", QFile::encodeName(scratch(QStringLiteral("missing.json"))));
    backend.busQuery(QStringLiteral("power.state"), QStringLiteral("missing"));
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(QStringLiteral("missing")) >= 1; }));
    EXPECT_FALSE(seen.ok.value(QStringLiteral("missing")));
    EXPECT_EQ(seen.output.value(QStringLiteral("missing")), QString());
    EXPECT_FALSE(seen.reason.value(QStringLiteral("missing")).isEmpty());
}

// Without a shell Settings runs the checker itself (U10). In a dev session: the dev checker, its cache under the dev state, or
// the canned answer; outside one the dev plumbing is inert.
TEST_F(BackendTest, WithoutAShellTheCheckerRunsHere)
{
    EnvGuard env{"GRASSFIELD_DEV", "GRASSFIELD_SESSION", "GRASSFIELD_UPDATE_CHECK_CMD", "GRASSFIELD_UPDATE_FIXTURE", "GRASSFIELD_STATE_HOME"};
    const QByteArray answer = R"({"version":1,"state":"up-to-date"})";
    writeRecorder(QStringLiteral("fake-checker"), answer);
    qputenv("GRASSFIELD_UPDATE_CHECK_CMD", QFile::encodeName(scratch(QStringLiteral("fake-checker"))));
    qputenv("GRASSFIELD_STATE_HOME", QFile::encodeName(scratch(QStringLiteral("state"))));
    qunsetenv("GRASSFIELD_UPDATE_FIXTURE");
    qunsetenv("GRASSFIELD_SESSION");

    // Outside a dev session neither variable counts: the installed checker, no canned answer (checked without running it).
    // A GRASSFIELD_DEV=1 that leaked into a packaged session (GRASSFIELD_SESSION=1) is no dev session either.
    QFile planted(scratch(QStringLiteral("planted.json")));
    ASSERT_TRUE(planted.open(QIODevice::WriteOnly));
    planted.write(R"({"version":1,"state":"up-to-date"})");
    planted.close();
    qputenv("GRASSFIELD_UPDATE_FIXTURE", QFile::encodeName(planted.fileName()));
    for (const char *session : {"", "1"}) {
        if (*session) {
            qputenv("GRASSFIELD_DEV", "1");
            qputenv("GRASSFIELD_SESSION", session);
        } else {
            qunsetenv("GRASSFIELD_DEV");
        }
        EXPECT_EQ(Backend::updateCheckerProgram(), QStringLiteral("/usr/lib/grassfield/grassfield-update-check")) << session;
        EXPECT_EQ(Backend::updateFixture(), QString()) << session;
    }
    qunsetenv("GRASSFIELD_SESSION");
    qunsetenv("GRASSFIELD_UPDATE_FIXTURE");
    qputenv("GRASSFIELD_DEV", "1");
    EXPECT_EQ(Backend::updateCheckerProgram(), scratch(QStringLiteral("fake-checker")));

    Answers seen;
    Backend backend;
    seen.listen(backend);
    backend.runUpdateChecker(QStringLiteral("dev"));
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(QStringLiteral("dev")) >= 1; }));
    EXPECT_TRUE(seen.ok.value(QStringLiteral("dev")));
    EXPECT_EQ(seen.output.value(QStringLiteral("dev")).trimmed(), QString::fromUtf8(answer));
    EXPECT_EQ(recorded(QStringLiteral("fake-checker")), QStringList{QStringLiteral("|unset|") + scratch(QStringLiteral("state")) + QStringLiteral("/cache")});

    QFile fixture(scratch(QStringLiteral("fixture.json")));
    ASSERT_TRUE(fixture.open(QIODevice::WriteOnly));
    fixture.write(R"({"version":1,"state":"available"})");
    fixture.close();
    qputenv("GRASSFIELD_UPDATE_FIXTURE", QFile::encodeName(fixture.fileName()));
    backend.runUpdateChecker(QStringLiteral("fixture"));
    ASSERT_TRUE(spinUntil([&] { return seen.finished.value(QStringLiteral("fixture")) >= 1; }));
    EXPECT_TRUE(seen.ok.value(QStringLiteral("fixture")));
    EXPECT_EQ(seen.output.value(QStringLiteral("fixture")), QStringLiteral(R"({"version":1,"state":"available"})"));
    EXPECT_EQ(recorded(QStringLiteral("fake-checker")).size(), 1) << "the canned answer runs nothing";

    EXPECT_EQ(backend.softwareUpdateFile(), scratch(QStringLiteral("state")) + QStringLiteral("/software-update.json"));
}

// Default web browser (ADR-0055 D-6): the two files the row writes, nothing else; a dev session writes only under <worktree>/.dev
// (ADR-0019), never the owner's ~/.config or state folder (review of PR #38, MED-4); a file that is not valid UTF-8 is not read as text.
TEST_F(BackendTest, TheDefaultBrowserRowWritesItsTwoFilesAndNothingElse)
{
    EnvGuard env{"XDG_CONFIG_HOME", "GRASSFIELD_STATE_HOME", "GRASSFIELD_SESSION"};
    qputenv("XDG_CONFIG_HOME", QFile::encodeName(scratch(QStringLiteral("cfg"))));
    qputenv("GRASSFIELD_STATE_HOME", QFile::encodeName(scratch(QStringLiteral("state"))));
    Backend backend;
    const QString list = scratch(QStringLiteral("cfg")) + QStringLiteral("/grassfield-mimeapps.list");
    const QString record = scratch(QStringLiteral("state")) + QStringLiteral("/default-apps.state");
    EXPECT_EQ(backend.xdgConfigDir(), scratch(QStringLiteral("cfg")));
    EXPECT_EQ(backend.grassfieldStateDir(), scratch(QStringLiteral("state")));
    EXPECT_EQ(backend.writeDefaultAppsFile(list, QStringLiteral("[Default Applications]\n")), QString());
    EXPECT_EQ(backend.writeDefaultAppsFile(record, QStringLiteral("web.state=user\n")), QString());
    EXPECT_TRUE(QFileInfo::exists(list) && QFileInfo::exists(record));
    // nothing else: the user's own mimeapps.list, another name, a path out of the folder, a link
    for (const QString &other : {scratch(QStringLiteral("cfg")) + QStringLiteral("/mimeapps.list"), scratch(QStringLiteral("cfg")) + QStringLiteral("/../cfg/grassfield-mimeapps.list"),
                                 scratch(QStringLiteral("elsewhere")) + QStringLiteral("/grassfield-mimeapps.list"), scratch(QStringLiteral("cfg")) + QStringLiteral("/hyprland-mimeapps.list"),
                                 QStringLiteral("relative/default-apps.state")})
        EXPECT_EQ(backend.writeDefaultAppsFile(other, QStringLiteral("x")), QStringLiteral("refused")) << qPrintable(other);
    EXPECT_FALSE(QFileInfo::exists(scratch(QStringLiteral("cfg")) + QStringLiteral("/mimeapps.list")));
    QFile::remove(list);
    ASSERT_TRUE(QFile::link(scratch(QStringLiteral("dotfiles-list")), list));
    EXPECT_EQ(backend.writeDefaultAppsFile(list, QStringLiteral("x")), QStringLiteral("refused")) << "a link is never written through";
}

TEST_F(BackendTest, ADevSessionNeverWritesTheDefaultBrowserFilesOutsideDev)
{
    EnvGuard env{"GRASSFIELD_DEV", "GRASSFIELD_SESSION", "XDG_CONFIG_HOME", "GRASSFIELD_STATE_HOME"};
    qputenv("GRASSFIELD_DEV", "1");
    qunsetenv("GRASSFIELD_SESSION");
    // The owner's real folders (here: scratch ones that are not under the worktree's .dev): refused, nothing created.
    qputenv("XDG_CONFIG_HOME", QFile::encodeName(scratch(QStringLiteral("realcfg"))));
    qputenv("GRASSFIELD_STATE_HOME", QFile::encodeName(scratch(QStringLiteral("realstate"))));
    {
        Backend dev;
        EXPECT_EQ(dev.writeDefaultAppsFile(dev.xdgConfigDir() + QStringLiteral("/grassfield-mimeapps.list"), QStringLiteral("x")), QStringLiteral("refused"));
        EXPECT_EQ(dev.writeDefaultAppsFile(dev.grassfieldStateDir() + QStringLiteral("/default-apps.state"), QStringLiteral("x")), QStringLiteral("refused"));
        EXPECT_FALSE(QFileInfo::exists(scratch(QStringLiteral("realcfg"))));
        EXPECT_FALSE(QFileInfo::exists(scratch(QStringLiteral("realstate"))));
    }
    // The isolated ones, under <worktree>/.dev (the test binary sits in <worktree>/.dev/build): written.
    const QString root = QDir(QCoreApplication::applicationDirPath() + QStringLiteral("/../..")).canonicalPath();
    const QString inside = root + QStringLiteral("/.dev/default-browser-test-") + QString::number(QCoreApplication::applicationPid());
    ASSERT_TRUE(QDir().mkpath(inside));
    qputenv("XDG_CONFIG_HOME", QFile::encodeName(inside + QStringLiteral("/cfg")));
    qputenv("GRASSFIELD_STATE_HOME", QFile::encodeName(inside + QStringLiteral("/state")));
    {
        Backend dev;
        EXPECT_EQ(dev.writeDefaultAppsFile(dev.xdgConfigDir() + QStringLiteral("/grassfield-mimeapps.list"), QStringLiteral("x")), QString());
        EXPECT_EQ(dev.writeDefaultAppsFile(dev.grassfieldStateDir() + QStringLiteral("/default-apps.state"), QStringLiteral("x")), QString());
    }
    QDir(inside).removeRecursively();
}

TEST_F(BackendTest, ATextFileThatIsNotUtf8IsNotReadAsText)
{
    Backend backend;
    const QString good = scratch(QStringLiteral("good.list"));
    const QString bad = scratch(QStringLiteral("bad.list"));
    {
        QFile f(good);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("# caf\xc3\xa9\n[Default Applications]\n");
    }
    {
        QFile f(bad);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("# caf\xe9\n[Default Applications]\n");
    }
    const QVariantMap ok = backend.readText(good);
    EXPECT_TRUE(ok.value(QStringLiteral("ok")).toBool());
    EXPECT_EQ(ok.value(QStringLiteral("text")).toString(), QStringLiteral("# café\n[Default Applications]\n"));
    const QVariantMap refused = backend.readText(bad);
    EXPECT_TRUE(refused.value(QStringLiteral("exists")).toBool());
    EXPECT_FALSE(refused.value(QStringLiteral("ok")).toBool()) << "Latin-1 bytes are not decoded into replacement characters and rewritten";
    EXPECT_TRUE(refused.value(QStringLiteral("text")).toString().isEmpty());
}
