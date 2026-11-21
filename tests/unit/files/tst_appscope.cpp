// Unit tests for apps/appscope.h (gtest). Built and run by scripts/dev/test.sh.
#include "appscope.h"
#include "chromecaps.h"

#include <QDir>
#include <QFileSystemWatcher>
#include <QTemporaryDir>

#include <gtest/gtest.h>

using grassfield::apps::scopedCommand;

TEST(AppScope, RealSessionStartsTheApplicationThroughUwsmApp)
{
    const QStringList c = scopedCommand(QStringLiteral("grassfield-preview"), {QStringLiteral("--glance"), QStringLiteral("--"), QStringLiteral("/a b.png")}, true);
    EXPECT_EQ(c, (QStringList{QStringLiteral("uwsm-app"), QStringLiteral("--"), QStringLiteral("grassfield-preview"), QStringLiteral("--glance"), QStringLiteral("--"), QStringLiteral("/a b.png")}));
}

TEST(AppScope, UnscopedSessionKeepsTheCommand)
{
    const QStringList c = scopedCommand(QStringLiteral("p"), {QStringLiteral("x")}, false);
    EXPECT_EQ(c, (QStringList{QStringLiteral("p"), QStringLiteral("x")}));
}

TEST(AppScope, DevSessionIsNeverScoped)
{
    qunsetenv("GRASSFIELD_SESSION"); // not inherited from the environment the tests run in
    qputenv("GRASSFIELD_DEV", "1");
    EXPECT_FALSE(grassfield::apps::scopedLaunch());
    qunsetenv("GRASSFIELD_DEV");
    EXPECT_FALSE(grassfield::apps::scopedLaunch());
}

// ADR-0019: a GRASSFIELD_DEV=1 that leaked into a packaged session (GRASSFIELD_SESSION=1) changes nothing there.
TEST(AppScope, ALeakedDevValueInARealSessionChangesNothing)
{
    qputenv("GRASSFIELD_SESSION", "1");
    qunsetenv("GRASSFIELD_DEV");
    const bool plain = grassfield::apps::scopedLaunch();
    qputenv("GRASSFIELD_DEV", "1");
    EXPECT_EQ(grassfield::apps::scopedLaunch(), plain);
    qunsetenv("GRASSFIELD_SESSION");
    qunsetenv("GRASSFIELD_DEV");
}

// ADR-0015 Q4(b): the minimize light is greyed only when the shell says the plugin is absent or has no minimize feature.
TEST(ChromeCaps, MinimizeIsAvailableWithThePlugin)
{
    EXPECT_TRUE(grassfield::apps::minimizeAvailable(R"({"v":1,"pluginPresent":true,"features":["decorations","minimize"]})"));
}

TEST(ChromeCaps, NoPluginOrNoMinimizeFeatureGreysTheLight)
{
    EXPECT_FALSE(grassfield::apps::minimizeAvailable(R"({"v":1,"pluginPresent":false,"features":[]})"));
    EXPECT_FALSE(grassfield::apps::minimizeAvailable(R"({"v":1,"pluginPresent":true,"features":["decorations"]})"));
}

TEST(ChromeCaps, UnknownStateKeepsTheLightEnabled)
{
    EXPECT_TRUE(grassfield::apps::minimizeAvailable(""));
    EXPECT_TRUE(grassfield::apps::minimizeAvailable("not json"));
    EXPECT_TRUE(grassfield::apps::minimizeAvailable("[]"));
    EXPECT_TRUE(grassfield::apps::minimizeAvailable(R"({"v":2,"pluginPresent":false})"));
    EXPECT_TRUE(grassfield::apps::minimizeAvailable(R"({"v":1,"pluginPresent":"no"})"));
    EXPECT_TRUE(grassfield::apps::minimizeAvailable(R"({"v":1,"pluginPresent":true})"));
}

TEST(ChromeCaps, FileLocationFollowsTheDevStateHomeThenTheRuntimeDir)
{
    qputenv("GRASSFIELD_STATE_HOME", "/s");
    EXPECT_EQ(grassfield::apps::capabilitiesFile(), QStringLiteral("/s/capabilities.json"));
    qunsetenv("GRASSFIELD_STATE_HOME");
    qputenv("XDG_RUNTIME_DIR", "/run/user/1");
    EXPECT_EQ(grassfield::apps::capabilitiesFile(), QStringLiteral("/run/user/1/grassfield/capabilities.json"));
}

// apps-misc H1 for the capabilities file: the readers watch Grassfield's runtime folder, not all of $XDG_RUNTIME_DIR; its
// parent only while the folder is missing.
TEST(ChromeCaps, WatchesGrassfieldsRuntimeFolderNotTheWholeRuntimeDir)
{
    QTemporaryDir runtime;
    ASSERT_TRUE(runtime.isValid());
    qunsetenv("GRASSFIELD_STATE_HOME");
    qputenv("XDG_RUNTIME_DIR", QFile::encodeName(runtime.path()));
    const QString folder = runtime.path() + QStringLiteral("/grassfield");
    QFileSystemWatcher watcher;

    // No folder yet (the shell has not written): the runtime dir, to see the folder appear.
    EXPECT_EQ(grassfield::apps::watchCapabilities(watcher), QStringList{runtime.path()});
    EXPECT_EQ(watcher.directories(), QStringList{runtime.path()});

    // The shell made it and wrote the file: the folder and the file only, the runtime dir let go.
    ASSERT_TRUE(QDir().mkdir(folder));
    QFile f(folder + QStringLiteral("/capabilities.json"));
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(R"({"v":1,"pluginPresent":false,"features":[]})");
    f.close();
    EXPECT_EQ(grassfield::apps::watchCapabilities(watcher), QStringList{folder});
    EXPECT_EQ(watcher.directories(), QStringList{folder});
    EXPECT_EQ(watcher.files(), QStringList{f.fileName()});
    EXPECT_FALSE(grassfield::apps::minimizeAvailableInFile());
    // Called again on every event: nothing doubles.
    grassfield::apps::watchCapabilities(watcher);
    EXPECT_EQ(watcher.directories().size(), 1);
    EXPECT_EQ(watcher.files().size(), 1);
    qunsetenv("XDG_RUNTIME_DIR");
}

// A runtime dir watched for its own sake is never let go by the helper.
TEST(ChromeCaps, KeepsAParentWatchedByItsOwner)
{
    QTemporaryDir runtime;
    ASSERT_TRUE(runtime.isValid());
    qunsetenv("GRASSFIELD_STATE_HOME");
    qputenv("XDG_RUNTIME_DIR", QFile::encodeName(runtime.path()));
    ASSERT_TRUE(QDir().mkdir(runtime.path() + QStringLiteral("/grassfield")));
    QFileSystemWatcher watcher;
    watcher.addPath(runtime.path());
    grassfield::apps::watchCapabilities(watcher);
    EXPECT_TRUE(watcher.directories().contains(runtime.path()));
    qunsetenv("XDG_RUNTIME_DIR");
}
