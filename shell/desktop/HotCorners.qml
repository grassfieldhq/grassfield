pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.platform
import qs.platform.shortcuts
import qs.services
import qs.notifications
import "HotCornerActions.js" as Actions

// Hot corners (docs/specs/desktop.md): four trigger windows per screen; after the dwell time the
// action chosen in grassfield.json hotCorners.<corner> runs (none | overview | notifications | apps | lock).
// Actions reach the target surface's IpcHandler in process (platform/shortcuts, as the keys do).
Scope {
    id: root

    // The action of a corner of the display `screenName`: its own override (hotCorners.outputs) over the All Displays value.
    function actionFor(corner: string, screenName: string): string {
        return Settings.hotCornersForScreen(screenName)[corner] || "none";
    }

    // `screen`: output name of the corner that fired (surfaces that take a screen open there).
    function run(action: string, screen: string): void {
        if (Actions.isDirect(action)) {
            if (Actions.normalize(action) === "lock")
                SessionState.requestLock("corner");
            else
                Notifications.toggleCenter(screen);
            return;
        }
        // In process (audit A-20): the request goes to the target's IpcHandler in this shell, as a key binding's does
        // (platform/shortcuts). Overview and Apps answer it whether they are built or still being built (shell.qml's early
        // handlers keep the request), so no process is started and no `qs ipc show` probe is needed.
        const request = Actions.request(action);
        if (request)
            Shortcuts.deliver(request);
    }

    Variants {
        model: Quickshell.screens

        Scope {
            id: perScreen

            required property ShellScreen modelData

            Variants {
                model: ["topLeft", "topRight", "bottomLeft", "bottomRight"]

                HotCorner {
                    required property string modelData

                    screen: perScreen.modelData
                    corner: modelData
                    action: root.actionFor(modelData, perScreen.modelData ? perScreen.modelData.name : "")
                    blocked: Actions.isBlocked(action, Notifications.centerOpen, FocusReturn.locked, SessionState.lockConfirmed)
                    // Every full-attention shell surface reports to FocusReturn (Apps, Overview, Search, menus, the
                    // switcher, the Notification Center); FocusReturn.locked follows the session lock.
                    covered: FocusReturn.locked || Object.keys(FocusReturn.holders).length > 0
                    onFire: root.run(action, perScreen.modelData.name)
                }
            }
        }
    }
}
