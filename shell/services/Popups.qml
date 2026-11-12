pragma Singleton
import QtQuick
import qs.platform
import "../platform/ScreenChoice.js" as ScreenChoice
import "PopupKinds.js" as PopupKinds
import Quickshell
import Quickshell.Io

// Which shell popup is open, where, and with which payload. One at a time. The Overlay window
// of the matching screen renders it; menus, status items and the Dock only call open()/close().
//
// kind: "" or one of PopupKinds.kinds: "system" | "app" | "appfile" | "appwindow" | "appbridge" | "tray" | "nowplaying" | "volume"
//       | "network" | "battery" | "controlcenter" | "dock" | "dockstack" | "forcequit" | "confirm" | "appabout" | "notice" | "tiling"
//       | "tilingSuggest" | "sharePicker" | "screenshare" | "input" | "emoji"; open() refuses any other kind.
Singleton {
    id: root

    property string kind: ""
    property string screenName: ""
    // Anchor in screen coordinates. align: "left" (popup's left edge at x, top at y),
    // "right" (right edge at x), "above" (centered on x, bottom edge at y), "rightOf" (left edge at x, centered on y: the Dock on
    // the left edge) and "leftOf" (right edge at x, centered on y: the Dock on the right edge), "center" (screen centre),
    // "below" (left edge at x, top edge at y; its bottom edge at data.flipY instead when the screen has no room below: the
    // tiling popover under a zoom light, docs/specs/tiling.md TL22), "zone" (the box data.width x data.height at x, y: the
    // tiling suggestions fill an empty zone of a layout, TL28).
    property real anchorX: 0
    property real anchorY: 0
    property string align: "left"
    property var data: ({})

    // Bumped by verify(): `active` and every binding built on it (the Overlay's `open`) read it, so a value left stale by a
    // binding loop is computed again (integrator PASS on 8316ed2: an overlay mapped with no popup must never stay).
    property int revision: 0
    readonly property bool active: kind !== "" && revision >= 0

    // The open folder stack (shell/overlay/StackPopup.qml publishes these) for the test hooks below.
    property string stackView: ""
    property var stackNames: []
    property int stackDepth: 0
    signal stackCommand(string command, string argument)

    // Test hooks (fixtures only) of the folder stack popup: tests/visual/dock-stacks.sh. Here, not in the popup, so that the
    // target exists whether or not a stack is open ("" and "refused" then).
    IpcHandler {
        target: "dockstack"

        // "view|name,name,..." of the open stack.
        function state(): string {
            if (!VisualFixtures.active || root.kind !== "dockstack")
                return "";
            return root.stackView + "|" + root.stackNames.join(",");
        }

        // How many folders deep the stack is opened in place (0: the stack itself).
        function depth(): string {
            if (!VisualFixtures.active || root.kind !== "dockstack")
                return "";
            return String(root.stackDepth);
        }

        // Opens the folder `name` of the listing in place (a click on a Grid or List item).
        function enter(name: string): string {
            if (!VisualFixtures.active || root.kind !== "dockstack")
                return "refused";
            root.stackCommand("enter", name);
            return "ok";
        }

        function back(): void {
            if (VisualFixtures.active && root.kind === "dockstack")
                root.stackCommand("back", "");
        }
    }

    // The menu bar of each output, by output name. While a popup holds the keyboard (Exclusive) Hyprland sends the pointer
    // to the overlay even over the bar strip (its input mask leaves the strip out), so the overlay hands the strip to the
    // bar: trackAt(x) and pressAt(x) in output coordinates.
    property var bars: ({})

    function registerBar(screen: string, bar: var): void {
        const all = Object.assign({}, root.bars);
        all[screen] = bar;
        root.bars = all;
    }

    function unregisterBar(screen: string, bar: var): void {
        if (root.bars[screen] !== bar)
            return;
        const all = Object.assign({}, root.bars);
        delete all[screen];
        root.bars = all;
    }

    // A menu asked for the next (+1) or previous (-1) menu bar title (Left/Right, macOS); the bar of `screen` answers.
    signal menuStepRequested(string screen, int direction)

    function stepMenu(direction: int): void {
        root.menuStepRequested(root.screenName, direction);
    }

    // Press, drag, release (macOS): the button that opened a menu is still down, so the pointer stays with the surface it
    // was pressed on (the bar, or the overlay's strip over it, by the implicit grab) and the open menu gets no pointer
    // events. That surface reports the pointer and the release in output coordinates; the overlay of `screen` relays them to
    // the open PopupMenu (trackPointer, releasePointer).
    // True while the button of a press on the bar is down. The overlay then maps without the keyboard: an Exclusive layer
    // mapping makes Hyprland release the held buttons and take the pointer from the pressed surface (measured: the bar got
    // a release 15 ms after the press and the real release reached no surface), which ends the drag. The overlay takes the
    // keyboard when the button is up.
    property bool pointerHeld: false

    // True while the open popup's Overlay window is the one the compositor gave the keyboard to (the Wayland window is active:
    // wl_keyboard.enter). Written by the Overlay of the popup's output; read only by the dev hook `menubar keyboardHolder`
    // (tests/visual/menubar-macos.sh), which tells the overlay from the focused client window.
    property bool overlayHasKeyboard: false

    // How the open popup was opened: true by the pointer (a press on the bar, the pointer moving onto another title or a
    // press on one while a menu is open, a click on a menu item), false by the keyboard (a shortcut, Left/Right in a menu,
    // Return on an item). A surface that gives an item the focus when it opens hands it to that item's KeyFocus (`pointer`),
    // so that the item's ring shows after a key only (ADR-0039 step 8; the owner's decision of 2026-10-31).
    property bool openedByPointer: false
    // True while withPointer() runs a pointer's action: the opens it makes are the pointer's.
    property bool pointerActing: false

    // Runs `action`; when `pointer` is true, a popup it opens counts as opened by the pointer (openedByPointer). For the
    // pointer paths that do not hold the button down (pointerHeld): the overlay's share of the bar strip, a menu item's click.
    function withPointer(pointer: bool, action: var): void {
        const was = root.pointerActing;
        root.pointerActing = pointer;
        try {
            action();
        } finally {
            root.pointerActing = was;
        }
    }

    signal pointerTracked(string screen, real x, real y)
    signal pointerReleased(string screen, real x, real y)

    function trackPointer(screen: string, x: real, y: real): void {
        if (root.active && root.screenName === screen)
            root.pointerTracked(screen, x, y);
    }

    function releasePointer(screen: string, x: real, y: real): void {
        if (root.active && root.screenName === screen)
            root.pointerReleased(screen, x, y);
    }

    // An open in progress: its content is created inside the change of `kind` (the Overlay's Loader), and the popup that
    // closes itself at once does so inside it. Such a close waits for the end of the open (closeLater): made there, it re-entered
    // the bindings still updating for the open (`active`, the Overlay's `open`), which then kept their stale value: the overlay
    // stayed mapped with no popup, swallowing every click and key (#48 nested pass, BLOCKER A).
    property bool opening: false
    // One more at each open: a close deferred for an open does not close a later one.
    property int openCount: 0

    function open(popupKind: string, screen: string, x: real, y: real, alignment: string, payload: var): void {
        // Nothing opens over the lock screen (GF-116): menus, Control Center, panels and sheets included. The Grassfield menu
        // and its confirmation (Lock Screen, Log Out, Restart, Shut Down) are refused only while the lock is confirmed: while
        // the UI reads locked only because the security process is down, Lock Screen must still reach it (ADR-0041 S2).
        if (PopupKinds.endsOrLocks(popupKind, payload) ? SessionState.refusesConfirmed("popup " + popupKind) : SessionState.refuses("popup " + popupKind))
            return;
        // Only a kind the Overlay draws: another would map an empty overlay that takes the keyboard (review of ce69dc6).
        if (!PopupKinds.known(popupKind)) {
            console.warn("grassfield: refused a popup of unknown kind:", popupKind);
            return;
        }
        root.openCount++;
        root.opening = true;
        try {
            data = payload ? payload : {};
            screenName = ScreenChoice.pick(screen, Compositor.activeScreenName, Quickshell.screens.map(s => s.name));
            anchorX = x;
            anchorY = y;
            align = alignment;
            // Before `kind`: the surface reads it when the Overlay creates it.
            openedByPointer = root.pointerHeld || root.pointerActing;
            kind = popupKind;
        } finally {
            root.opening = false;
        }
    }

    // Opens on the screen of the current popup, or the active display (IPC and keyboard use).
    // `screen` (optional): the display of the panel that asked for it (a confirm opens where its asker is).
    function openCentered(popupKind: string, payload: var, screen: string): void {
        const name = ScreenChoice.centered(active, screenName, Compositor.activeScreenName, screen);
        open(popupKind, name, 0, 0, "center", payload);
    }

    // The screen of the open popup went away (a display unplugged): the popup moves to a live screen.
    Connections {
        target: Quickshell

        function onScreensChanged(): void {
            const next = ScreenChoice.afterScreensChanged(root.kind, root.screenName, Compositor.focusedScreenName, Quickshell.screens.map(s => s.name));
            if (next.close)
                root.close(); // what it offered is not on any output that remains
            else
                root.screenName = next.screen;
        }
    }

    // Toggle: the same kind at the same screen closes it.
    function toggle(popupKind: string, screen: string, x: real, y: real, alignment: string, payload: var): void {
        if (kind === popupKind && screenName === screen)
            close();
        else
            open(popupKind, screen, x, y, alignment, payload);
    }

    function confirm(title: string, message: string, confirmLabel: string, action: string, args: var, destructive: bool, screen: string): void {
        openCentered("confirm", {title: title, message: message, confirmLabel: confirmLabel, action: action, args: args, destructive: destructive}, screen);
    }

    // `symbol`: the glyph of the notice's subject (power, moon, document, ...): a shell dialog shows its subject's symbol, never
    // the Grassfield mark (ADR-0040 IQ-B1 B, tests/ci/mark_places.py); none given, the information symbol
    // (PopupKinds.noticeSymbol). Untyped: a string-typed parameter turns a missing one into "undefined".
    function notice(title: string, message: string, symbol): void {
        openCentered("notice", {title: title, message: message, symbol: PopupKinds.noticeSymbol(symbol)});
    }

    function close(): void {
        if (root.opening) {
            root.closeLater(root.openCount);
            return;
        }
        kind = "";
        data = {};
    }

    // A popup is open on the output `screen`: the Overlay's `open` (a binding on this reads `revision` too: verifyOpen can
    // compute a stale one again).
    function openOn(screen: string): bool {
        return root.active && root.screenName === screen && root.revision >= 0;
    }

    // `shown`, a binding on openOn(screen) (the Overlay's `open`), disagrees with it now: computed again, logged. True when they
    // agree.
    function verifyOpen(shown: bool, screen: string): bool {
        if (shown === root.openOn(screen))
            return true;
        console.warn("grassfield: overlay on \"" + screen + "\": open (" + shown + ") disagreed with Popups; computed again");
        root.revision++;
        return false;
    }

    // True when `active` agrees with `kind`; else it is computed again, logged (the Overlay asks too for its own `open`).
    function verify(): bool {
        if (root.active === (root.kind !== ""))
            return true;
        console.warn("grassfield: popups: active (" + root.active + ") disagreed with kind \"" + root.kind + "\"; computed again");
        root.revision++;
        return false;
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.active || root.kind !== ""
        onTriggered: root.verify()
    }

    function closeLater(count: int): void {
        Qt.callLater(() => {
            if (root.openCount === count)
                root.close();
        });
    }

    // The session locks: whatever is open closes (GF-116; the lock lives in the security process since ADR-0041 S2 and closes
    // nothing of the UI itself).
    Connections {
        target: SessionState

        function onLockedChanged(): void {
            if (SessionState.locked)
                root.close();
        }

        // A menu opened while the lock was unconfirmed (the security process down) closes once the lock is confirmed.
        function onLockConfirmedChanged(): void {
            if (SessionState.locked && SessionState.lockConfirmed)
                root.close();
        }
    }
}
