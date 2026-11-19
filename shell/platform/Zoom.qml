pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.platform.shortcuts
import qs.services // layering-exception: GF-087
import "Zoom.js" as ZoomLogic

// Screen magnification (Settings > Accessibility > Zoom, GF-064). The stored state (accessibility.zoom, zoomLevel) is
// sent to Hyprland as `cursor:zoom_factor` whenever it changes and once when the settings are read; the keyboard
// (Super+Alt+8 toggle, Super+Alt+= / Super+Alt+- level, config/hypr/grassfield/bindings.lua) goes through the `zoom` IPC
// target and changes the stored state, so the Settings page follows. The zoom stays on at the lock screen (macOS keeps
// accessibility Zoom there: whoever needs it must be able to read the password field); the compositor magnifies around the
// pointer and the keyboard focus, so the field stays reachable. Reduce Motion turns the compositor's zoom animation off
// (Minimized.js motionLeaves) and a config reload sends the factor again. Degrades quietly: outside Hyprland (no IPC) nothing is
// sent; a Hyprland that rejects the call leaves the screen unmagnified (the Lua call is under pcall). Event-driven.
Singleton {
    id: root

    // Set by shell.qml once the settings are read (a default state is never sent before that).
    property bool ready: false
    readonly property real factor: ZoomLogic.factor(Settings.zoomOn, Settings.zoomLevel)

    function apply(): void {
        if (!root.ready)
            return;
        const request = ZoomLogic.request(root.factor);
        if (request !== "")
            Hyprland.dispatch(request);
    }

    // A config reload resets the compositor's options: the zoom is sent again (as Pointer does for its theme).
    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "configreloaded")
                root.apply();
        }
    }

    onFactorChanged: root.apply()
    onReadyChanged: root.apply()

    IpcHandler {
        target: "zoom"
        // A key binding calls it: it answers the key in-process (platform/shortcuts, CIO-01).
        Component.onCompleted: Shortcuts.attach(this)

        function toggle(): void {
            Settings.setZoom(!Settings.zoomOn);
        }

        // Zooming in while off turns zoom on at the stored level.
        function zoomIn(): void {
            if (!Settings.zoomOn)
                Settings.setZoom(true);
            else
                Settings.setZoomLevel(ZoomLogic.step(Settings.zoomLevel, 1));
        }

        function zoomOut(): void {
            if (Settings.zoomOn)
                Settings.setZoomLevel(ZoomLogic.step(Settings.zoomLevel, -1));
        }
    }
}
