// Shared by the Grassfield apps (R5: one copy). ADR-0039 step 17 and the integrator's macOS decision on #88: a window keeps its
// key look while a shell menu or the Control Center holds the keyboard; only another window taking the focus makes it inactive.
// Hyprland withdraws the window's activation (xdg_toplevel activated, which Qt follows) as soon as a shell layer takes the
// keyboard, so an app cannot tell a menu from another window by itself. The shell writes the client of the window that looks
// key to one small file:
//
//   $GRASSFIELD_STATE_HOME/keywindow.json (a dev session) or $XDG_RUNTIME_DIR/grassfield/keywindow.json
//   {"v":1,"pid":1234,"appId":"org.grassfield.Settings"}   (pid 0 while Hyprland's window data does not have it: the app id)
//
// (shell/services/KeyWindow.qml; the format and the rule in shell/services/KeyWindowFile.js). KeyWindow holds the app's last
// focused window key (Appearance.heldKeyWindow, read by Appearance.looksKey) while the app has no focused window and the file
// names this process. A missing, unreadable or malformed file names nobody: Window.active alone, as before.
// The file lives in Grassfield's own runtime folder (H1 of the 2026-11 audit): its directory is watched, and any entry any
// program made or removed in all of $XDG_RUNTIME_DIR made every running app open and parse the file again. The parent is
// watched only while the folder does not exist yet (the shell makes it at its first write).
#pragma once

#include <QByteArray>
#include <QCoreApplication>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QQmlApplicationEngine>
#include <QString>
#include <QStringList>
#include <QVariant>
#include <QWindow>

#include "runmode.h"

namespace grassfield::apps {

inline QString keyWindowFile()
{
    const QString dev = runmode::stateHomeOverride();
    if (!dev.isEmpty())
        return dev + QStringLiteral("/keywindow.json");
    const QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    return runtime.isEmpty() ? QString() : runtime + QStringLiteral("/grassfield/keywindow.json");
}

// Whether the file's content names this client: its pid when the shell knows one, else its app id.
inline bool keyWindowNames(const QByteArray &json, qint64 pid, const QString &appId)
{
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return false;
    const QJsonObject o = doc.object();
    if (o.value(QStringLiteral("v")).toInt() != 1 || !o.value(QStringLiteral("pid")).isDouble() || !o.value(QStringLiteral("appId")).isString())
        return false;
    const qint64 filePid = o.value(QStringLiteral("pid")).toInteger();
    if (filePid > 0)
        return filePid == pid;
    const QString fileAppId = o.value(QStringLiteral("appId")).toString();
    return !fileAppId.isEmpty() && fileAppId == appId;
}

// The window that keeps its key look: the last focused one while none is focused and the shell names this client.
inline QWindow *heldKeyWindow(QWindow *focused, QWindow *last, bool named)
{
    return focused == nullptr && named ? last : nullptr;
}

// One per app, made with its engine: it watches the file and the app's focus, and sets Grassfield.Ui's
// Appearance.heldKeyWindow on every change (the singleton is looked up once the engine created a window: Appearance starts
// at null, which is what nothing held means).
class KeyWindow : public QObject
{
public:
    explicit KeyWindow(QQmlApplicationEngine *engine)
        : QObject(engine)
        , m_engine(engine)
        , m_path(keyWindowFile())
    {
        connect(qGuiApp, &QGuiApplication::focusWindowChanged, this, [this](QWindow *window) {
            if (window)
                m_last = window;
            update();
        });
        connect(engine, &QQmlApplicationEngine::objectCreated, this, [this] { update(); });
        // The shell replaces the file (an atomic write): the watch on the file goes with the old one, so the directory is
        // watched too, and the file is watched again whenever it exists.
        connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, [this] { reread(); });
        connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, [this] {
            watchFolder();
            reread();
        });
        watchFolder();
        m_last = QGuiApplication::focusWindow();
        reread();
    }

    // How often the file was read (tests: the churn of other programs' files must not read it).
    int reads() const { return m_reads; }
    // The directories watched now (tests).
    QStringList watchedDirectories() const { return m_watcher.directories(); }

private:
    // The file's folder when it exists; else its parent, until the folder appears (then the parent is let go).
    void watchFolder()
    {
        if (m_path.isEmpty())
            return;
        const QString dir = QFileInfo(m_path).absolutePath();
        const QString parent = QFileInfo(dir).absolutePath();
        const QStringList watched = m_watcher.directories();
        if (QFileInfo(dir).isDir()) {
            if (!watched.contains(dir))
                m_watcher.addPath(dir);
            if (watched.contains(parent))
                m_watcher.removePath(parent);
        } else if (!watched.contains(parent) && QFileInfo(parent).isDir()) {
            m_watcher.addPath(parent);
        }
    }

    void reread()
    {
        ++m_reads;
        bool named = false;
        if (!m_path.isEmpty()) {
            QFile f(m_path);
            if (f.open(QIODevice::ReadOnly)) {
                named = keyWindowNames(f.read(4096), QCoreApplication::applicationPid(), QGuiApplication::desktopFileName());
                if (!m_watcher.files().contains(m_path))
                    m_watcher.addPath(m_path);
            }
        }
        m_named = named;
        // Named nobody (or another client) while unfocused: the last window is no longer the key one, and never becomes it
        // again by a later file alone (another process of the same app id, a stale window).
        if (!named && !QGuiApplication::focusWindow())
            m_last = nullptr;
        update();
    }

    void update()
    {
        QWindow *held = heldKeyWindow(QGuiApplication::focusWindow(), m_last.data(), m_named);
        if (!m_appearance && m_engine && !m_engine->rootObjects().isEmpty())
            m_appearance = m_engine->singletonInstance<QObject *>("Grassfield.Ui", "Appearance");
        if (!m_appearance || held == m_pushed)
            return;
        m_pushed = held;
        m_appearance->setProperty("heldKeyWindow", QVariant::fromValue<QObject *>(held));
    }

    QPointer<QQmlApplicationEngine> m_engine;
    QString m_path;
    QFileSystemWatcher m_watcher;
    QPointer<QWindow> m_last;
    QPointer<QObject> m_appearance;
    QPointer<QWindow> m_pushed;
    bool m_named = false;
    int m_reads = 0;
};

} // namespace grassfield::apps
