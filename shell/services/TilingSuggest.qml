pragma Singleton
import QtQuick
import Quickshell
import qs.platform
import "../platform/WindowTiling.js" as WindowTiling

// Shows the tiling suggestions (docs/specs/tiling.md TL28): popup kind "tilingSuggest" over the first empty zone of the layout
// the window that asked is filling, offering the windows that can take it (platform/TilingLink's suggestion; live thumbnails
// in overlay/TilingSuggestions). A pick places that window there (Compositor.pickSuggestion) and the next empty zone follows
// with the plugin's next suggestion; Esc or a click outside ends it. Nothing opens over the lock (refused first, and by
// Popups.open), the polkit sheet, a full-attention surface or the Dock's keyboard mode (TilingHover.refusedBy), nor in place
// of another popup than the tiling popover or the suggestions themselves; it closes when the suggestion ends (another change
// of the tiles, the plugin gone).
Singleton {
    id: root

    readonly property bool shown: Popups.kind === "tilingSuggest"

    // What happened, for the lock-surfaces harness (it runs without the plugin): "opened", or why not: "lock", "none" (no
    // suggestion: an open one closes), "busy" (another popup is open), what refuses it (WindowTiling.hoverRefusedBy through
    // TilingHover.refusedBy) or "no output". The lock is refused first.
    function show(suggestion: var): string {
        if (SessionState.refuses("tiling suggestions"))
            return "lock";
        if (!suggestion) {
            if (root.shown)
                Popups.close();
            return "none";
        }
        if (Popups.active && Popups.kind !== "tiling" && Popups.kind !== "tilingSuggest")
            return "busy";
        const refused = TilingHover.refusedBy();
        if (refused !== "") {
            console.info("grassfield: tiling suggestions refused: " + refused + " is open");
            return refused;
        }
        const screen = Quickshell.screens.find(s => s.name === suggestion.output);
        if (!screen)
            return "no output";
        const zone = suggestion.zones[0];
        if (!root.shown)
            console.info("grassfield: tiling suggestions shown for " + suggestion.address + " (" + suggestion.windows.length + " windows, zone " + zone.zone + " of " + suggestion.layout + ")");
        Popups.open("tilingSuggest", screen.name, zone.x - screen.x, zone.y - screen.y, "zone", {
            suggestion: suggestion,
            width: zone.w,
            height: zone.h
        });
        return "opened";
    }

    // The window `address` into the zone the suggestions show (the first empty one). False when nothing was sent. The window
    // picked is focused once the suggestions close (macOS: the window just chosen becomes key; #48 nested pass, MINOR E), unless
    // the plugin refuses the pick.
    function pick(address: string): bool {
        const sg = root.shown ? Popups.data.suggestion : null;
        const sent = sg ? Compositor.pickSuggestion(address, sg.layout, sg.zones[0].zone, sg.address) : false;
        if (sent)
            FocusReturn.choose(address);
        return sent;
    }

    // Esc, or a click outside: the suggestions end for that arrangement (on a Split View Desktop the window then fills it
    // alone: lonely below).
    function dismiss(): void {
        TilingLink.dismiss();
        if (root.shown)
            Popups.close();
    }

    // TL33, ADR-0036 D43 (#48 review, MAJOR 3): a Split View Desktop never keeps an empty half. Its one member still waiting
    // for its second window fills it alone as soon as its picker is not pending: dismissed (Esc, a click outside, another
    // popup in its place), refused (the polkit sheet, Search, a full-attention surface), timed out, or ended by another
    // change. Not while locked (fillAlone refuses): at the unlock. Each window is sent once while it stays lonely.
    readonly property string pendingAddress: root.shown && Popups.data.suggestion ? Popups.data.suggestion.address : TilingLink.awaiting && Compositor.suggestionAsked ? Compositor.suggestionAsked.address : ""
    readonly property var lonely: SessionState.locked ? [] : WindowTiling.lonelyMembers(TilingLink.splits, root.pendingAddress)
    property var filled: ({})
    // The last window whose fill was sent ("" none; tests/shell/split_view).
    property string lastSent: ""

    // At the end of the event that changed it: the popups close, the picker with them, as the session reads locked (GF-116;
    // before ADR-0041 S2 the lock closed them just before its state changed), so a fill sent at once went out as the lock began
    // instead of at the unlock (#48 nested pass, MINOR B). Read then, `lonely` is empty under the lock.
    onLonelyChanged: Qt.callLater(root.fillLonely)

    function fillLonely(): void {
        const next = {};
        for (const address of root.lonely) {
            next[address] = true;
            if (root.filled[address] !== true) {
                root.lastSent = address;
                Compositor.fillAlone(address);
            }
        }
        root.filled = next;
    }

    // A fill the plugin refused because it still reported the lock (the shell's own lock state goes first at the unlock;
    // re-review of e5bd9d2, MAJOR A) is not done: sent again shortly. The plugin also fills a lonely member itself at the
    // unlock; this covers a refusal the plugin's own state did not.
    Connections {
        target: Compositor

        function onTilingNotice(notice: var): void {
            if (root.shown && (notice.reason === "invalid" || notice.reason === "locked"))
                FocusReturn.choose(""); // a refused pick: the window was not placed, nothing chosen
            if (notice.reason !== "locked" || Object.keys(root.filled).length === 0)
                return;
            root.filled = ({});
            resend.restart();
        }
    }

    Timer {
        id: resend

        interval: 500
        onTriggered: root.fillLonely()
    }

    Connections {
        target: TilingLink

        function onSuggestionChanged(): void {
            if (TilingLink.suggestion !== null || root.shown)
                root.show(TilingLink.suggestion);
        }
    }

    // The popup closed another way (a click outside, the lock, another popup in its place): nothing more is suggested.
    Connections {
        target: Popups

        function onKindChanged(): void {
            if (Popups.kind !== "tilingSuggest" && TilingLink.suggestion !== null)
                TilingLink.dismiss();
        }
    }
}
