pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.launchpad
import qs.notifications
import qs.overview
import qs.platform
import qs.search
import qs.services

// GF-AUDIT-001 GF-116 (DT-08), on the REAL controllers (scripts/dev/test.sh: `qs -p tests/security/lock_surfaces`,
// offscreen, a dev session without the D-Bus server; the layer-shell windows are stubs): while the session is locked
// nothing but the lock screen opens.
//  - control: unlocked, every surface opens (so the refusals below are not a broken open path);
//  - lock: SessionState.locked (what shell.qml binds to Lock.locked) closes every open surface: Search (and drops its
//    query), Apps, the Notification Center, the Overview, any Popups kind (Control Center, menus, sheets);
//  - refusal: while locked, every way into each surface stays closed: Search show/toggle, Apps show/toggle, Notification
//    Center toggle and the widget gallery, Overview show/toggle, Popups open/toggle/openCentered/confirm/notice, Emoji &
//    Symbols toggle;
//  - unlock: the surfaces open again.
// The IPC functions, bindings, screen corners and gestures all end in these entry points (tests/security/lock_surfaces.sh
// checks that statically, with the Dock keyboard mode, window commands and the polkit sheet). Prints
// "lock-surfaces: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    property int checks: 0

    function check(name: string, ok: bool): void {
        checks++;
        if (!ok)
            failures.push(name);
    }

    Search {
        id: search
    }

    AppsController {
        id: apps
    }

    Overview {
        id: overview
        // shell.qml: locked: Lock.lockState !== "unlocked" (the same state SessionState.locked mirrors).
        locked: SessionState.locked
    }

    function openAll(): void {
        search.show("secret query");
        apps.show();
        Notifications.toggleCenter("");
        overview.show();
        Popups.open("controlcenter", "", 0, 0, "right", {});
    }

    function closeAll(): void {
        search.hide();
        apps.hide();
        if (Notifications.centerOpen)
            Notifications.closeCenter();
        overview.hide();
        Popups.close();
    }

    function anyOpen(): string {
        const open = [];
        if (search.open)
            open.push("search");
        if (apps.open)
            open.push("apps");
        if (Notifications.centerOpen)
            open.push("notification center");
        if (overview.open)
            open.push("overview");
        if (Popups.active)
            open.push("popup " + Popups.kind);
        return open.join(", ");
    }

    function run(): void {
        SessionState.locked = false;

        // Control: unlocked, each surface opens.
        search.show("");
        check("control: search opens unlocked", search.open);
        search.hide();
        apps.show();
        check("control: apps opens unlocked", apps.open);
        apps.hide();
        // The tiling popover's own guard, unlocked (integrator re-review of c92ccb2): never over Search, Apps, the polkit sheet or
        // the Dock's keyboard mode, and another window's popover closes before a new one opens while the same window's stays.
        // TilingHover.show says why it did not open (the harness has no plugin). Before the Overview, whose keyboard release is
        // not immediate (it would still be a FocusReturn holder).
        const hover = (address, state) => ({address: address, state: state, light: {x: 0, y: 0, w: 14, h: 14}, tileable: true});
        let why = "";
        search.show("");
        why = TilingHover.show(hover("b", "enter"));
        check("tiling: no popover over Search (" + why + ")", why === "search" && !Popups.active);
        search.hide();
        apps.show();
        why = TilingHover.show(hover("b", "enter"));
        check("tiling: no popover over Apps (" + why + ")", why === "apps" && !Popups.active);
        apps.hide();
        SessionState.authorizing = true;
        why = TilingHover.show(hover("b", "open"));
        check("tiling: no popover over the polkit sheet (" + why + ")", why === "authorization" && !Popups.active);
        SessionState.authorizing = false;
        TilingHover.dockKeyboard = true;
        why = TilingHover.show(hover("b", "enter"));
        check("tiling: no popover over the Dock's keyboard mode (" + why + ")", why === "dock" && !Popups.active);
        TilingHover.dockKeyboard = false;
        why = TilingHover.show(hover("b", "enter"));
        check("tiling: control, nothing refuses it (" + why + ": no plugin here)", why === "unavailable");
        Popups.open("tiling", "", 0, 0, "below", {address: "a"});
        TilingHover.show(hover("a", "open"));
        check("tiling: the same window's popover stays", Popups.kind === "tiling" && Popups.data.address === "a");
        TilingHover.show(hover("b", "open"));
        check("tiling: another window's popover closes first", !Popups.active);
        Popups.close();
        // The suggestions' own guard (tiling step 4a, TL28): the same surfaces refuse them, and they never take the place of
        // another popup than the tiling popover. TilingSuggest.show says why it did not open.
        const screenName = Quickshell.screens.length > 0 ? Quickshell.screens[0].name : "";
        const suggestion = {gen: 1, address: "a", layout: "thirds", output: screenName, zones: [{zone: 1, x: 0, y: 0, w: 600, h: 400}], windows: ["b"]};
        search.show("");
        why = TilingSuggest.show(suggestion);
        check("tiling suggestions: not over Search (" + why + ")", why === "search" && !Popups.active);
        search.hide();
        apps.show();
        why = TilingSuggest.show(suggestion);
        check("tiling suggestions: not over Apps (" + why + ")", why === "apps" && !Popups.active);
        apps.hide();
        SessionState.authorizing = true;
        why = TilingSuggest.show(suggestion);
        check("tiling suggestions: not over the polkit sheet (" + why + ")", why === "authorization" && !Popups.active);
        SessionState.authorizing = false;
        TilingHover.dockKeyboard = true;
        why = TilingSuggest.show(suggestion);
        check("tiling suggestions: not over the Dock's keyboard mode (" + why + ")", why === "dock" && !Popups.active);
        TilingHover.dockKeyboard = false;
        Popups.open("controlcenter", "", 0, 0, "left", {});
        why = TilingSuggest.show(suggestion);
        check("tiling suggestions: not in place of another popup (" + why + ")", why === "busy" && Popups.kind === "controlcenter");
        Popups.open("tiling", "", 0, 0, "below", {address: "a"});
        why = TilingSuggest.show(suggestion);
        check("tiling suggestions: control, after the popover (" + why + ")", why === (Quickshell.screens.length > 0 ? "opened" : "no output"));
        why = TilingSuggest.show(null);
        check("tiling suggestions: no suggestion closes them (" + why + ")", why === "none" && Popups.kind !== "tilingSuggest");
        Popups.close();
        // The lock ends the suggestion (TilingSuggest drops it when its popup closes): nothing reopens it after the unlock.
        TilingLink.suggestion = suggestion;
        check("tiling suggestions: the link's suggestion opens them", Popups.kind === (Quickshell.screens.length > 0 ? "tilingSuggest" : ""));
        SessionState.locked = true;
        check("tiling suggestions: the lock closes them and drops the suggestion", Popups.kind !== "tilingSuggest" && TilingLink.suggestion === null);
        SessionState.locked = false;
        check("tiling suggestions: nothing reopens after the unlock", Popups.kind !== "tilingSuggest" && TilingLink.suggestion === null);
        Notifications.toggleCenter("");
        check("control: notification center opens unlocked", Notifications.centerOpen);
        Notifications.closeCenter();
        overview.show();
        check("control: overview opens unlocked", overview.open);
        overview.hide();
        Popups.open("controlcenter", "", 0, 0, "right", {});
        check("control: control center opens unlocked", Popups.kind === "controlcenter");
        Popups.close();
        // A kind the Overlay does not draw stays closed, unlocked too: the retired "about" mapped an empty overlay that took the
        // keyboard (review of ce69dc6).
        for (const k of ["about", "nonsense"]) {
            Popups.open(k, "", 0, 0, "center", {});
            check("control: the unknown popup kind '" + k + "' is refused", !Popups.active);
            Popups.close();
        }

        // Lock with everything open (Popups last: opening Search or Apps closes a popup, as on macOS).
        openAll();
        check("setup: everything open before the lock (" + anyOpen() + ")", search.open && apps.open && Notifications.centerOpen && overview.open && Popups.kind === "controlcenter");
        SessionState.locked = true;
        check("lock: search closes", !search.open);
        check("lock: search drops its query", search.query === "");
        check("lock: apps closes", !apps.open);
        check("lock: notification center closes", !Notifications.centerOpen);
        check("lock: overview starts closing (releases the keyboard first)", overview.stage !== "open");
        check("lock: popups close", !Popups.active);
    }

    // After the overview's keyboard release (Tokens.overviewReleaseBoundMs).
    function runLocked(): void {
        check("lock: overview closed", !overview.open);

        // Every entry point while locked.
        // Each entry point on its own (a toggle after a wrongly opened surface would close it again and hide the defect).
        search.show("x");
        check("locked: search.show stays closed", !search.open);
        search.toggle();
        check("locked: search.toggle stays closed", !search.open);
        search.toggleClipboard();
        check("locked: search.toggleClipboard stays closed", !search.open && search.view === "");
        apps.show();
        check("locked: apps.show stays closed", !apps.open);
        apps.toggle();
        check("locked: apps.toggle stays closed", !apps.open);
        Notifications.toggleCenter("");
        check("locked: Notifications.toggleCenter stays closed", !Notifications.centerOpen);
        Notifications.openWidgetGallery("");
        check("locked: the widget gallery stays closed", !Notifications.centerOpen);
        check("locked: the widget gallery is not queued for the next open", !Notifications.galleryWanted);
        overview.show();
        check("locked: overview.show stays closed", !overview.open);
        overview.toggle();
        check("locked: overview.toggle stays closed", !overview.open);
        const kinds = ["system", "app", "appfile", "appwindow", "appbridge", "tray", "volume", "network", "battery", "controlcenter", "dock", "dockstack", "forcequit", "appabout", "notice", "confirm", "tiling", "tilingSuggest", "sharePicker", "screenshare", "emoji"];
        const opened = [];
        for (const k of kinds) {
            Popups.open(k, "", 0, 0, "left", {});
            if (Popups.active)
                opened.push("open " + k);
            Popups.toggle(k, "", 0, 0, "left", {});
            if (Popups.active)
                opened.push("toggle " + k);
            Popups.openCentered(k, {});
            if (Popups.active)
                opened.push("openCentered " + k);
            Popups.close();
        }
        Popups.confirm("t", "m", "OK", "logout", {}, true);
        if (Popups.active)
            opened.push("confirm");
        Popups.notice("t", "m");
        if (Popups.active)
            opened.push("notice");
        check("locked: no popup kind opens (" + opened.join(", ") + ")", opened.length === 0);
        // ADR-0045 OC-3: Ctrl+Super+Space (IPC emoji toggle) asks Hyprland nothing and opens nothing.
        Emoji.toggle();
        check("locked: Emoji.toggle stays closed and places nothing", !Popups.active && !Emoji.placing);
        // Tiling step 3 (integrator review of 4ead6fb): the plugin's tile-hover event and Super+Ctrl+L go through here.
        TilingHover.show({address: "1", state: "open", light: {x: 0, y: 0, w: 14, h: 14}, tileable: true});
        TilingHover.show({address: "1", state: "enter", light: {x: 0, y: 0, w: 14, h: 14}, tileable: true});
        check("locked: the tiling popover does not open (TilingHover.show)", !Popups.active);
        const lockedWhy = TilingSuggest.show({gen: 1, address: "a", layout: "thirds", output: "", zones: [{zone: 1, x: 0, y: 0, w: 600, h: 400}], windows: ["b"]});
        check("locked: the tiling suggestions do not open (" + lockedWhy + ")", lockedWhy === "lock" && !Popups.active);
        check("locked: nothing is open at all (" + anyOpen() + ")", anyOpen() === "");

        // ADR-0041 S2 (the opus review of 77a0ceb3, MAJOR-1): the UI reads locked only because the security process is down
        // (no state, or a stale "unlocked"): the paths that lock or end the session open, so that a lock request reaches it
        // (LockClient hands it to the stand-in, which starts the unit); every other surface stays refused.
        SessionState.lockConfirmed = false;
        let requested = "";
        const onRequest = reason => requested = reason;
        SessionState.lockRequested.connect(onRequest);
        Popups.open("system", "", 0, 0, "left", {});
        check("unconfirmed: the Grassfield menu opens (its Lock Screen reaches the security process)", Popups.kind === "system");
        Popups.close();
        Popups.confirm("t", "m", "OK", "logout", {}, true);
        check("unconfirmed: the session confirmation opens", Popups.kind === "confirm");
        Popups.close();
        Popups.confirm("t", "m", "Empty Trash", "emptytrash", {}, true);
        check("unconfirmed: another confirmation (Empty Trash) stays refused", !Popups.active);
        Popups.close();
        search.show("");
        check("unconfirmed: Search opens (its Lock Screen command)", search.open);
        search.enterClipboard();
        check("unconfirmed: Search's clipboard view stays refused", !search.clipboardView);
        SessionState.requestLock("probe");
        check("unconfirmed: a lock request goes out", requested === "probe");
        SessionState.lockRequested.disconnect(onRequest);
        SessionState.lockConfirmed = true;
        check("unconfirmed -> confirmed: Search closes", !search.open);
        SessionState.lockConfirmed = false;
        Popups.open("system", "", 0, 0, "left", {});
        SessionState.lockConfirmed = true;
        check("unconfirmed -> confirmed: the menu closes", !Popups.active);
        SessionState.lockConfirmed = false;
        const still = [];
        for (const k of kinds) {
            if (k === "system" || k === "confirm")
                continue;
            Popups.open(k, "", 0, 0, "left", {});
            if (Popups.active)
                still.push(k);
            Popups.close();
        }
        apps.show();
        overview.show();
        Notifications.toggleCenter("");
        Emoji.toggle();
        check("unconfirmed: every other surface stays refused (" + still.join(", ") + (anyOpen() ? "; " + anyOpen() : "") + ")", still.length === 0 && anyOpen() === "" && !Emoji.placing);
        SessionState.lockConfirmed = true;

        // Unlock: back to normal.
        SessionState.locked = false;
        openAll();
        check("unlock: everything opens again (" + anyOpen() + ")", search.open && apps.open && Notifications.centerOpen && overview.open && Popups.kind === "controlcenter");
        closeAll();
    }

    Timer {
        interval: 300
        running: true
        onTriggered: {
            root.run();
            lockedStep.start();
        }
    }

    Timer {
        id: lockedStep
        interval: 1000
        onTriggered: {
            root.runLocked();
            if (root.failures.length === 0) {
                console.log("lock-surfaces: PASS (" + root.checks + " checks)");
                Qt.exit(0);
            } else {
                console.log("lock-surfaces: FAIL: " + root.failures.join("; "));
                Qt.exit(1);
            }
        }
    }
}
