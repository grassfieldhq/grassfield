import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/services/KeyWindowFile.js" as KeyWindowFile
import "../../shell/services/PopupKinds.js" as PopupKinds

// The key window's file (ADR-0039 step 17; the integrator's macOS decision on #88): the shell names the client whose window
// looks key, and keeps the menu's opener while a shell menu or the Control Center holds the keyboard; only another window taking
// the focus makes the window inactive. The rule is KeyWindowFile.js (pure); shell/services/KeyWindow.qml needs Quickshell and is
// read as source; the apps' side is tests/unit/activity/qml/tst_keywindow.cpp (apps/keywindow.h) and tst_inactivewindow.qml.
TestCase {
    name: "KeyWindowFile"

    readonly property var settings: KeyWindowFile.client(4242, "org.grassfield.Settings")
    readonly property var files: KeyWindowFile.client(5151, "org.grassfield.Files")

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    function test_thePathAndThePayload() {
        compare(KeyWindowFile.path("/tmp/state", "/run/user/1000"), "/tmp/state/keywindow.json", "a dev session");
        compare(KeyWindowFile.path("", "/run/user/1000"), "/run/user/1000/grassfield-keywindow.json");
        compare(KeyWindowFile.path("", ""), "");
        compare(KeyWindowFile.payload(settings), '{"v":1,"pid":4242,"appId":"org.grassfield.Settings"}\n');
        compare(KeyWindowFile.payload(KeyWindowFile.none), '{"v":1,"pid":0,"appId":""}\n');
        compare(KeyWindowFile.payload(null), '{"v":1,"pid":0,"appId":""}\n');
        // The apps read the same places (apps/keywindow.h).
        const header = source("apps/keywindow.h");
        verify(header.indexOf('dev + QStringLiteral("/keywindow.json")') > 0 && header.indexOf('runtime + QStringLiteral("/grassfield-keywindow.json")') > 0);
    }

    function test_aClient() {
        compare(KeyWindowFile.client(12.7, "a"), {pid: 12, appId: "a"});
        compare(KeyWindowFile.client(0, "a"), {pid: 0, appId: "a"}, "a pid Hyprland has not given yet");
        compare(KeyWindowFile.client(-3, null), KeyWindowFile.none);
        compare(KeyWindowFile.client(NaN, undefined), KeyWindowFile.none);
        verify(KeyWindowFile.isNone(KeyWindowFile.client(0, "")));
        verify(!KeyWindowFile.isNone(KeyWindowFile.client(0, "a")));
    }

    // The menus, the status menus, the Control Center and the popovers keep the look; a dialog, another shell surface, or a
    // menu with another surface does not.
    function test_whichSurfacesKeepTheLook() {
        const keeps = (holders, kind) => KeyWindowFile.keepsLook(holders, kind, PopupKinds.kinds, PopupKinds.dialogs);
        for (const kind of ["app", "appfile", "appwindow", "appbridge", "system", "tray", "controlcenter", "volume", "network",
                            "battery", "nowplaying", "dock", "dockstack", "tiling", "tilingSuggest", "screenshare", "input"])
            verify(keeps(["popup"], kind), kind);
        for (const kind of PopupKinds.dialogs)
            verify(!keeps(["popup"], kind), kind + ": a window of its own");
        verify(!keeps(["popup"], "nonsense"));
        verify(!keeps(["popup"], ""));
        for (const holder of ["search", "apps", "switcher", "notification-center", "overview", "widgets-menu-DP-1"])
            verify(!keeps([holder], "app"), holder);
        verify(!keeps(["popup", "search"], "app"), "a menu and Spotlight");
        verify(!keeps([], "app"));
        // Every kind is one or the other: a new kind is a menu unless it is a dialog.
        compare(PopupKinds.kinds.filter(k => !keeps(["popup"], k)).sort(), PopupKinds.dialogs.slice().sort());
    }

    function test_theKeyClient() {
        const key = s => KeyWindowFile.keyClient(Object.assign({locked: false, holders: [], keeps: false, front: settings,
                                                                opener: KeyWindowFile.none, returning: false}, s));
        compare(key({}), settings, "no shell surface: the focused window's client");
        compare(key({front: KeyWindowFile.none}), KeyWindowFile.none, "the desktop has the keyboard");
        compare(key({holders: ["popup"], keeps: true, opener: settings, front: KeyWindowFile.none}), settings, "a menu: its opener");
        compare(key({holders: ["popup"], keeps: false, opener: settings}), KeyWindowFile.none, "a dialog: nobody");
        compare(key({holders: ["search"], opener: settings}), KeyWindowFile.none, "Spotlight: nobody");
        compare(key({front: KeyWindowFile.none, opener: settings, returning: true}), settings, "closed, before the window is focused again");
        compare(key({front: files, opener: settings, returning: true}), files, "another window took the focus");
        compare(key({locked: true, holders: ["popup"], keeps: true, opener: settings}), KeyWindowFile.none, "the lock");
    }

    // The events, as KeyWindow.qml feeds them.
    function open(l, holders, front, kind) {
        return KeyWindowFile.holdersChanged(l, holders, front, kind, PopupKinds.kinds, PopupKinds.dialogs);
    }

    function kind(l, holders, k) {
        return KeyWindowFile.kindChanged(l, holders, k, PopupKinds.kinds, PopupKinds.dialogs);
    }

    function keyOf(l, holders, front) {
        return KeyWindowFile.keyClient({locked: false, holders: holders, keeps: l.kept, front: front, opener: l.opener, returning: l.returning});
    }

    function test_aMenuOpensAndClosesOnItsWindow() {
        const none = KeyWindowFile.none;
        // The app menu opens on Settings: the opener is taken before the compositor withdraws the activation.
        let l = open(KeyWindowFile.start, ["popup"], settings, "app");
        compare(l, {opener: settings, kept: true, returning: false});
        compare(keyOf(l, ["popup"], none), settings, "Hyprland reports no focused window meanwhile: Settings stays key");
        // The pointer moves along the bar to the Control Center.
        l = kind(l, ["popup"], "controlcenter");
        compare(keyOf(l, ["popup"], none), settings, "the Control Center too");
        // Escape: the kind is cleared first, then the holder released; nobody is focused yet.
        l = kind(l, ["popup"], "");
        compare(l.kept, true, "a closing popup keeps the value it had");
        l = open(l, [], none, "");
        compare(l, {opener: settings, kept: true, returning: true});
        compare(keyOf(l, [], none), settings, "until the window is focused again");
        l = KeyWindowFile.frontChanged(l, settings, false);
        compare(l, KeyWindowFile.start);
        compare(keyOf(l, [], settings), settings, "focused again: the focused window's client");
    }

    function test_anotherWindowTakesTheFocus() {
        const none = KeyWindowFile.none;
        let l = open(KeyWindowFile.start, ["popup"], settings, "app");
        // A click on a Files window closes the menu and focuses it.
        l = kind(l, ["popup"], "");
        l = open(l, [], none, "");
        l = KeyWindowFile.frontChanged(l, files, false);
        compare(keyOf(l, [], files), files, "Files is key, Settings inactive");
        // Or nobody is focused within the bound: nobody.
        l = open(KeyWindowFile.start, ["popup"], settings, "app");
        l = open(kind(l, ["popup"], ""), [], none, "");
        l = KeyWindowFile.frontChanged(l, none, true);
        compare(keyOf(l, [], none), none, "the bound ran out");
        compare(KeyWindowFile.frontChanged(l, none, false), l, "no return: nothing changes");
    }

    function test_aDialogOrAnotherSurfaceIsNotAMenu() {
        const none = KeyWindowFile.none;
        // System menu > Log Out…: the menu becomes the confirmation alert.
        let l = open(KeyWindowFile.start, ["popup"], settings, "system");
        l = kind(l, ["popup"], "confirm");
        compare(keyOf(l, ["popup"], none), none, "an alert is a window of its own: Settings inactive");
        l = open(kind(l, ["popup"], ""), [], none, "");
        compare(l, KeyWindowFile.start, "closed without a menu: no return kept");
        // Spotlight opens over Settings, then a menu while it is open: nobody.
        l = open(KeyWindowFile.start, ["search"], settings, "");
        compare(keyOf(l, ["search"], none), none);
        l = open(l, ["search", "popup"], none, "app");
        compare(keyOf(l, ["search", "popup"], none), none);
        compare(l.opener, settings, "the opener stays the first surface's");
    }

    function test_aMenuReopenedBeforeTheReturnKeepsItsOpener() {
        const none = KeyWindowFile.none;
        let l = open(KeyWindowFile.start, ["popup"], settings, "app");
        l = open(kind(l, ["popup"], ""), [], none, "");
        compare(l.returning, true);
        l = open(l, ["popup"], none, "tray");
        compare(l, {opener: settings, kept: true, returning: false}, "the second menu belongs to the same window");
        compare(keyOf(l, ["popup"], none), settings);
    }

    // KeyWindow.qml (Quickshell: read as source) feeds those events and writes the file once per turn, atomically.
    function test_theShellWritesIt() {
        const q = source("shell/services/KeyWindow.qml");
        verify(q.indexOf("readonly property var front: DesktopState.holdsKeyboard ? KeyWindowFile.none : KeyWindowFile.client(Compositor.pidOf(Compositor.focusedToplevel), Compositor.focusedAppId)") > 0);
        verify(q.indexOf("readonly property var holders: Object.keys(FocusReturn.holders)") > 0);
        verify(q.indexOf("onHoldersChanged: root.latch = KeyWindowFile.holdersChanged(root.latch, root.holders, root.front, Popups.kind, PopupKinds.kinds, PopupKinds.dialogs)") > 0);
        verify(q.indexOf("onFrontChanged: root.latch = KeyWindowFile.frontChanged(root.latch, root.front, false)") > 0);
        verify(/function onKindChanged\(\): void \{\s*root\.latch = KeyWindowFile\.kindChanged\(/.test(q));
        verify(/interval: Tokens\.focusReturnMenuActionWaitMs\s*running: root\.latch\.returning\s*onTriggered: root\.latch = KeyWindowFile\.frontChanged\(root\.latch, root\.front, true\)/.test(q));
        verify(/locked: FocusReturn\.locked,\s*holders: root\.holders,\s*keeps: root\.latch\.kept,/.test(q));
        verify(q.indexOf("onTextChanged: Qt.callLater(root.write)") > 0 && /atomicWrites: true\s*blockWrites: true/.test(q));
        verify(source("shell/services/qmldir").indexOf("singleton KeyWindow 1.0 KeyWindow.qml") >= 0);
        verify(source("shell/shell.qml").indexOf('"key window", KeyWindow.path') > 0, "instantiated at start");
        // The Overlay is the "popup" holder; its popups are Popups' kinds.
        verify(/if \(Popups\.active\)\s*FocusReturn\.opened\("popup"\);/.test(source("shell/overlay/Overlay.qml")));
    }

    // Every window look of step 17 reads Appearance.looksKey, and every app holds its window key from the file.
    function test_theAppsDrawIt() {
        for (const path of ["ui/Grassfield/Ui/UnifiedToolbar.qml", "ui/Grassfield/Ui/ToolButton.qml", "apps/store/qml/Sidebar.qml", "apps/preview/qml/Thumbnails.qml"]) {
            const text = source(path);
            verify(text.indexOf("Appearance.looksKey(root.Window.window, root.Window.active)") > 0, path);
            compare(text.indexOf("root.Window.active ?"), -1, path + ": no bare Window.active left");
        }
        verify(source("ui/Grassfield/Ui/WindowControls.qml").indexOf("property bool active: root.window ? Appearance.looksKey(root.window, root.window.active) : true") > 0, "the lights");
        const settings = source("apps/settings/qml/Main.qml");
        verify(settings.indexOf("readonly property bool keyLook: Appearance.looksKey(root, root.active)") > 0);
        compare(settings.split("root.keyLook").length - 1, 3, "the sidebar's selection, its label and its tile");
        const viewer = source("apps/preview/qml/Viewer.qml");
        verify(viewer.indexOf("readonly property bool keyLook: Appearance.looksKey(viewerWin, viewerWin.active)") > 0);
        compare(viewer.split("viewerWin.keyLook ?").length - 1, 3, "the title, the file plate and its name");
        verify(viewer.indexOf("viewerWin.keyLook ? Appearance.colors.selection : Appearance.unemphasizedSelection") > 0, "the plate keeps the key look");
        compare(viewer.indexOf("viewerWin.active ?"), -1);
        for (const app of ["activity", "files", "preview", "settings", "store"]) {
            const main = source("apps/" + app + "/src/main.cpp");
            verify(/QQmlApplicationEngine engine;\n[^\n]*\n\s*new grassfield::apps::KeyWindow\(&engine\);/.test(main), app);
        }
    }
}
