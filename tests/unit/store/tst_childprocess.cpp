// The Store's read-only child processes (ADR-0037 f): an argument vector, a fixed environment, stdin from /dev/null, a cap
// on output and a deadline that stops the whole process group.
#include "childprocess.h"

#include <QElapsedTimer>
#include <QFile>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <csignal>
#include <memory>
#include <thread>

using namespace grassfield::store;

TEST(ChildProcess, OutputAndExitCode)
{
    ChildResult r = runChild(QStringLiteral("/bin/sh"), {QStringLiteral("-c"), QStringLiteral("echo out; echo err >&2; exit 3")});
    EXPECT_TRUE(r.started);
    EXPECT_EQ(r.exitCode, 3);
    EXPECT_FALSE(r.ok());
    EXPECT_EQ(r.out, QByteArray("out\n"));
    EXPECT_EQ(r.err, QByteArray("err\n"));
    // Arguments are passed as they are: no shell sees them.
    r = runChild(QStringLiteral("/bin/echo"), {QStringLiteral("$HOME;"), QStringLiteral("`id`")});
    EXPECT_EQ(r.out, QByteArray("$HOME; `id`\n"));
    EXPECT_FALSE(runChild(QStringLiteral("/nonexistent/program"), {}).started);
}

TEST(ChildProcess, FixedEnvironmentAndNoInput)
{
    qputenv("STORE_TEST_LEAK", "leaked");
    ChildOptions o;
    o.extraEnv.insert(QStringLiteral("GNUPGHOME"), QStringLiteral("/tmp/x"));
    const ChildResult r = runChild(QStringLiteral("/bin/sh"), {QStringLiteral("-c"), QStringLiteral("echo \"$PATH|$LC_ALL|$GNUPGHOME|$STORE_TEST_LEAK\"; cat")}, o);
    qunsetenv("STORE_TEST_LEAK");
    EXPECT_TRUE(r.ok());
    EXPECT_EQ(r.out, QByteArray("/usr/bin:/bin|C|/tmp/x|\n")); // cat read /dev/null: no wait
}

TEST(ChildProcess, TheDeadlineStopsTheWholeGroup)
{
    QTemporaryDir dir;
    const QString pidFile = dir.filePath(QStringLiteral("grandchild"));
    ChildOptions o;
    o.timeoutMs = 300;
    QElapsedTimer clock;
    clock.start();
    const ChildResult r = runChild(QStringLiteral("/bin/sh"), {QStringLiteral("-c"), QStringLiteral("sleep 60 & echo $! > '%1'; wait").arg(pidFile)}, o);
    EXPECT_LT(clock.elapsed(), 6000);
    EXPECT_TRUE(r.timedOut);
    EXPECT_FALSE(r.ok());
    QFile f(pidFile);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    const pid_t grandchild = pid_t(f.readAll().trimmed().toInt());
    ASSERT_GT(grandchild, 0);
    // The background sleep got the group's SIGTERM too. Gone means it can no longer run: a zombie waiting for its new parent,
    // a task its new parent (the user's systemd, a subreaper) is releasing right now (state X, or a /proc read that returns
    // nothing, which a live task never does) or no task at all. The release passes through those readings at any moment, so
    // a zombie reading followed by an empty or X one is still the same death.
    auto alive = [&] {
        QFile stat(QStringLiteral("/proc/%1/stat").arg(grandchild));
        if (::kill(grandchild, 0) != 0 || !stat.open(QIODevice::ReadOnly))
            return false;
        const QByteArray s = stat.readAll();
        const int close = s.lastIndexOf(')');
        if (close < 0 || s.size() < close + 3)
            return false; // being released
        const char state = s.at(close + 2);
        return state != 'Z' && state != 'X' && state != 'x';
    };
    QElapsedTimer wait;
    wait.start();
    while (alive() && wait.elapsed() < 3000)
        ::usleep(20000);
    EXPECT_FALSE(alive());
}

// The cancel flag (the Store quitting): a child running is stopped within its 100 ms look, its group too, and its output is
// not used; set before, nothing starts.
TEST(ChildProcess, TheCancelFlagStopsIt)
{
    ChildOptions o;
    o.timeoutMs = 60000;
    auto cancel = std::make_shared<std::atomic_bool>(false);
    o.cancel = cancel;
    std::thread setter([cancel] {
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        *cancel = true;
    });
    QElapsedTimer clock;
    clock.start();
    const ChildResult r = runChild(QStringLiteral("/bin/sh"), {QStringLiteral("-c"), QStringLiteral("echo started; sleep 60")}, o);
    setter.join();
    EXPECT_LT(clock.elapsed(), 6000) << "not its 60 s deadline";
    EXPECT_TRUE(r.started);
    EXPECT_TRUE(r.cancelled);
    EXPECT_FALSE(r.timedOut);
    EXPECT_FALSE(r.ok());
    const ChildResult again = runChild(QStringLiteral("/bin/true"), {}, o);
    EXPECT_FALSE(again.started) << "the flag already set: nothing starts";
    EXPECT_TRUE(again.cancelled);
    EXPECT_FALSE(again.ok());
    *cancel = false;
    EXPECT_TRUE(runChild(QStringLiteral("/bin/true"), {}, o).ok());
}

TEST(ChildProcess, OutputOverTheCapIsNotUsed)
{
    ChildOptions o;
    o.maxOut = 4096;
    const ChildResult r = runChild(QStringLiteral("/usr/bin/yes"), {}, o);
    EXPECT_TRUE(r.overflow);
    EXPECT_FALSE(r.ok());
    EXPECT_TRUE(r.out.isEmpty());
}
