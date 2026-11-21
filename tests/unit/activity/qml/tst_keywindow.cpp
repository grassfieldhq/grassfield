// apps/keywindow.h, shared by the five apps (ADR-0039 step 17; the integrator's macOS decision on #88): a window keeps its key
// look while a shell menu or the Control Center holds the keyboard, and only another window taking the focus makes it inactive.
// Here because this binary is the apps' offscreen QML suite with Qt's private window-system API, which is how a test takes the
// focus away as the compositor does when a shell layer takes the keyboard. The shell's side: tests/unit/tst_keywindowfile.qml.
#include "keywindow.h"

#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QtGui/qpa/qwindowsysteminterface.h>

#include <gtest/gtest.h>

#ifndef ACTIVITY_ROOT
#error "ACTIVITY_ROOT: the repository's root (build-direct.sh and CMakeLists.txt define it)"
#endif

namespace {

using grassfield::apps::heldKeyWindow;
using grassfield::apps::keyWindowNames;

void spin(int ms)
{
    QElapsedTimer t;
    t.start();
    while (t.elapsed() < ms)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
}

// As the shell writes it: a whole new file in its place (FileView's atomic write).
void replace(const QString &path, const QByteArray &text)
{
    QFile f(path + QStringLiteral(".tmp"));
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(text);
    f.close();
    QFile::remove(path);
    ASSERT_TRUE(QFile::rename(path + QStringLiteral(".tmp"), path));
}

QByteArray naming(qint64 pid, const char *appId)
{
    return "{\"v\":1,\"pid\":" + QByteArray::number(pid) + ",\"appId\":\"" + appId + "\"}\n";
}

TEST(KeyWindow, TheFileNamesAClientByItsPidElseItsAppId)
{
    const qint64 me = 4242;
    const QString app = QStringLiteral("org.grassfield.Settings");
    EXPECT_TRUE(keyWindowNames(naming(me, "org.other"), me, app)) << "the pid when the shell knows it";
    EXPECT_FALSE(keyWindowNames(naming(1, "org.grassfield.Settings"), me, app)) << "a known pid wins over the app id";
    EXPECT_TRUE(keyWindowNames(naming(0, "org.grassfield.Settings"), me, app)) << "the app id while the pid is not known";
    EXPECT_FALSE(keyWindowNames(naming(0, ""), me, QString())) << "nobody";
    EXPECT_FALSE(keyWindowNames("{\"v\":2,\"pid\":4242,\"appId\":\"\"}", me, app)) << "another version";
    EXPECT_FALSE(keyWindowNames("{\"v\":1,\"pid\":\"4242\",\"appId\":\"\"}", me, app)) << "a pid that is not a number";
    EXPECT_FALSE(keyWindowNames("{\"v\":1,\"pid\":4242}", me, app)) << "no app id";
    EXPECT_FALSE(keyWindowNames("not json", me, app));
    EXPECT_FALSE(keyWindowNames(QByteArray(), me, app)) << "no file";
}

TEST(KeyWindow, OnlyTheLastWindowWhileNoneIsFocused)
{
    auto *a = reinterpret_cast<QWindow *>(0x10);
    auto *b = reinterpret_cast<QWindow *>(0x20);
    EXPECT_EQ(heldKeyWindow(nullptr, a, true), a);
    EXPECT_EQ(heldKeyWindow(b, a, true), nullptr) << "a focused window is key by itself";
    EXPECT_EQ(heldKeyWindow(nullptr, a, false), nullptr) << "the shell names another client";
    EXPECT_EQ(heldKeyWindow(nullptr, nullptr, true), nullptr);
}

// The whole path: the file, the app's focus, Appearance.heldKeyWindow and Appearance.looksKey in a real Grassfield.Ui window.
TEST(KeyWindow, TheWindowStaysKeyWhileTheShellHoldsTheKeyboardForIt)
{
    ASSERT_NE(qGuiApp, nullptr);
    QTemporaryDir state;
    ASSERT_TRUE(state.isValid());
    qputenv("GRASSFIELD_STATE_HOME", state.path().toUtf8());
    const QString oldName = QGuiApplication::desktopFileName();
    QGuiApplication::setDesktopFileName(QStringLiteral("org.grassfield.Test"));
    const QString path = state.path() + QStringLiteral("/keywindow.json");
    EXPECT_EQ(grassfield::apps::keyWindowFile(), path);
    const qint64 me = QCoreApplication::applicationPid();

    {
        QQmlApplicationEngine engine;
        new grassfield::apps::KeyWindow(&engine);
        engine.addImportPath(QStringLiteral(ACTIVITY_ROOT "/ui"));
        engine.loadData("import QtQuick\nimport Grassfield.Ui\nWindow { visible: true; width: 100; height: 100\n"
                        "    readonly property bool keyLook: Appearance.looksKey(this, active) }");
        auto *win = qobject_cast<QQuickWindow *>(engine.rootObjects().value(0));
        ASSERT_NE(win, nullptr);
        const auto keyLook = [win] { return win->property("keyLook").toBool(); };
        const auto focus = [](QWindow *w) {
            QWindowSystemInterface::handleFocusWindowChanged(w, Qt::ActiveWindowFocusReason);
            QWindowSystemInterface::flushWindowSystemEvents();
            spin(50);
        };
        focus(win);
        EXPECT_TRUE(win->isActive() && keyLook()) << "focused";
        focus(nullptr);
        EXPECT_TRUE(!win->isActive() && !keyLook()) << "no file: Window.active alone, as before";

        focus(win);
        replace(path, naming(me, "org.grassfield.Test"));
        spin(150);
        focus(nullptr);
        EXPECT_TRUE(!win->isActive() && keyLook()) << "a shell menu holds the keyboard: the window stays key";
        replace(path, naming(1, "org.other"));
        spin(150);
        EXPECT_FALSE(keyLook()) << "another window took the focus: inactive";
        replace(path, naming(me, "org.grassfield.Test"));
        spin(150);
        EXPECT_FALSE(keyLook()) << "named again without the focus coming back (a stale window): not key";

        focus(win);
        focus(nullptr);
        EXPECT_TRUE(keyLook()) << "a menu again";
        replace(path, naming(0, ""));
        spin(150);
        EXPECT_FALSE(keyLook()) << "Spotlight, a dialog or the desktop: nobody";

        focus(win);
        replace(path, naming(0, "org.grassfield.Test"));
        spin(150);
        focus(nullptr);
        EXPECT_TRUE(keyLook()) << "the app id while the shell has no pid";
        QFile::remove(path);
        spin(150);
        EXPECT_FALSE(keyLook()) << "the file gone: nobody";
    }
    QGuiApplication::setDesktopFileName(oldName);
    qunsetenv("GRASSFIELD_STATE_HOME");
}

// H1 of the 2026-11 audit: outside a dev session the file was in $XDG_RUNTIME_DIR itself, whose every entry (any program's
// socket, lock or pid file) made each running app read and parse it again. It lives in $XDG_RUNTIME_DIR/grassfield now; the
// runtime directory is watched only until that folder exists.
TEST(KeyWindow, OnlyGrassfieldsRuntimeFolderIsWatched)
{
    ASSERT_NE(qGuiApp, nullptr);
    QTemporaryDir runtime;
    ASSERT_TRUE(runtime.isValid());
    const QByteArray oldRuntime = qgetenv("XDG_RUNTIME_DIR");
    qunsetenv("GRASSFIELD_STATE_HOME");
    qputenv("XDG_RUNTIME_DIR", runtime.path().toUtf8());
    const QString folder = runtime.path() + QStringLiteral("/grassfield");
    const QString path = folder + QStringLiteral("/keywindow.json");
    EXPECT_EQ(grassfield::apps::keyWindowFile(), path);
    const auto touch = [](const QString &file) {
        QFile f(file);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("x");
    };
    {
        QQmlApplicationEngine engine;
        auto *watch = new grassfield::apps::KeyWindow(&engine);
        // No folder yet (the shell has not written): the runtime directory, until it appears.
        EXPECT_EQ(watch->watchedDirectories(), QStringList{runtime.path()});
        ASSERT_TRUE(QDir().mkpath(folder));
        spin(200);
        EXPECT_EQ(watch->watchedDirectories(), QStringList{folder}) << "the folder there: the runtime directory let go";

        // Other programs' files in the runtime directory: not one read.
        const int reads = watch->reads();
        for (int i = 0; i < 20; ++i) {
            touch(runtime.path() + QStringLiteral("/other-%1.sock").arg(i));
            QFile::remove(runtime.path() + QStringLiteral("/other-%1.sock").arg(i));
        }
        spin(200);
        EXPECT_EQ(watch->reads(), reads);

        // The shell's file in the folder: read.
        replace(path, naming(QCoreApplication::applicationPid(), ""));
        spin(200);
        EXPECT_GT(watch->reads(), reads);
    }
    if (oldRuntime.isEmpty())
        qunsetenv("XDG_RUNTIME_DIR");
    else
        qputenv("XDG_RUNTIME_DIR", oldRuntime);
}

} // namespace
