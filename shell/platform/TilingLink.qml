pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import "WindowTiling.js" as WindowTiling

// The tiling suggestions' link to the compositor plugin (docs/specs/tiling.md TL28): after the `placed` notice of an
// arrangement the shell asked (Compositor.suggestionAsked: a layout or an arrangement from the popover, the Window menu or the
// keys, or a pick of the suggestions), the suggestion of the `grassfield-tiling` reply (asked on Hyprland's request socket in
// process, HyprQuery: what `hyprctl grassfield-tiling` asks, without a process per notice) when it fills that window's
// layout and belongs to that notice; any other change of the tile records ends it (a refusal changes nothing). One fetch at
// a time; services/TilingSuggest shows the suggestion. The same reply gives the tile groups (TL29) and the Split View
// Desktops (TL33): read again after every change of the tile records while the plugin offers tiling-groups or tiling-split.
// Without tiling-layouts, tiling-groups or tiling-split nothing is ever fetched.
Singleton {
    id: root

    // The suggestion to show (WindowTiling.parseSuggestion) or null.
    property var suggestion: null
    // The tile groups of the last reply (WindowTiling.parseGroups: the Dock menu's Show Tile Group, an Overview drop), or
    // null (no reply yet, a malformed one, no tiling-groups).
    property var groups: null
    // The Split View Desktops of the last reply (WindowTiling.parseSplits: the menu bar and the Dock hide on them, the Desktops
    // list each after the one it came from); [] without one, a malformed reply or tiling-split.
    property var splits: []
    // The windows that do not fit half of their output (WindowTiling.parseUnfit: the Window menu greys their Full Screen Tile,
    // ADR-0036 D57); [] without one, a malformed reply or tiling-split. Read again when the Window menu opens (refresh()).
    property var unfit: []
    // The windows of fixed size (WindowTiling.parseFixed: the Window menu greys their Zoom, Enter Full Screen and tiling items,
    // ADR-0040 step 1b); [] without one, a malformed reply or window-tiling. Read again when the Window menu opens.
    property var fixed: []
    // The windows filled by Zoom or Fill (WindowTiling.parseFilled: the Window menu says Unzoom for them, ADR-0036 D78); [] without
    // one, a malformed reply or window-tiling. Read again when the Window menu opens and after the tiling notices.
    property var filled: []
    // The zones and the places each window does not fit (WindowTiling.parseUnfitZones, ADR-0036 D69: the Window menu greys
    // those Halves, Quarters and Arrange items), keyed by address; {} without one, a malformed reply or window-tiling. Read
    // again when the Window menu opens.
    property var unfitZones: ({})
    // The generation whose suggestion the fetch waits for (-1: none).
    property real wantedGen: -1
    // A suggestion asked for is on its way (from the notice of its arrangement until its reply is read or the deadline passes):
    // a Split View's picker is pending meanwhile (services/TilingSuggest).
    property bool awaiting: false
    // A fetch was asked while the previous request was still out: start it when that one ends.
    property bool startPending: false
    // The request out (a HyprQuery) or null; the fetches started (tests).
    property var query: null
    property int queries: 0
    // The Split View picker the user dismissed ({address, gen} of its suggestion): a later reply does not show it again (its
    // window fills instead).
    property var declined: null
    // A fetch gave up at its deadline: one more is made shortly (the tile groups and the Split View Desktops would otherwise
    // wait for the next notice; re-review of e5bd9d2: a Split View learnt only through a timed-out fetch never filled).
    property bool retried: false

    // The suggestion ends (Esc, a click outside, the lock): nothing more is taken for that arrangement.
    function dismiss(): void {
        if (root.suggestion)
            root.declined = {address: root.suggestion.address, gen: root.suggestion.gen};
        root.wantedGen = -1;
        root.awaiting = false;
        root.suggestion = null;
        Compositor.suggestionAsked = null;
    }

    // The Window menu opens: what fits a half, and what is of fixed size, is read again (a window opened or changed its limits
    // since the last reply).
    function refresh(): void {
        if (Compositor.canSplit || Compositor.canTile)
            root.fetch();
    }

    function fetch(): void {
        fetchDeadline.restart();
        if (root.query !== null)
            root.startPending = true;
        else
            root.startQuery();
    }

    function startQuery(): void {
        root.queries++;
        const path = Hyprland.requestSocketPath || "";
        if (path === "") {
            // No Hyprland to ask: a reply that does not read (as a hyprctl that could not reach one).
            Qt.callLater(() => root.takeReply(""));
            return;
        }
        const q = hyprQuery.createObject(root, {path: path, line: "grassfield-tiling", answerMs: WindowTiling.suggestionWaitMs});
        root.query = q;
        q.answered.connect((text, ok) => {
            if (root.query !== q)
                return; // given up meanwhile
            root.query = null;
            if (root.startPending) {
                root.startPending = false; // a newer notice asks again
                root.startQuery();
                return;
            }
            root.takeReply(text);
        });
    }

    Component {
        id: hyprQuery
        HyprQuery {}
    }

    Connections {
        target: Compositor

        function onTilingNotice(notice: var): void {
            if (notice.reason === "invalid" || notice.reason === "locked")
                return; // a refused request changed nothing: what is shown stays
            const asked = Compositor.suggestionAsked;
            if (notice.reason === "placed" && asked !== null && Date.now() <= asked.until && Compositor.canLayouts) {
                // The shown suggestion stays until the reply says what follows (the next zone, or nothing).
                root.wantedGen = notice.gen;
                root.awaiting = true;
                root.fetch();
                return;
            }
            root.wantedGen = -1;
            root.awaiting = false;
            root.suggestion = null;
            if (Compositor.canGroups || Compositor.canSplit)
                root.fetch(); // the groups or the Split View Desktops may have changed
        }

        function onCanLayoutsChanged(): void {
            if (!Compositor.canLayouts)
                root.dismiss();
        }

        function onSuggestionsOnChanged(): void {
            if (!Compositor.suggestionsOn)
                root.dismiss();
        }

        function onCanGroupsChanged(): void {
            if (Compositor.canGroups)
                root.fetch();
            else
                root.groups = null;
        }

        function onCanSplitChanged(): void {
            if (Compositor.canSplit) {
                root.fetch();
            } else {
                root.splits = [];
                root.unfit = [];
            }
        }

        function onCanTileChanged(): void {
            if (Compositor.canTile) {
                root.fetch();
            } else {
                root.fixed = [];
                root.filled = [];
                root.unfitZones = {};
            }
        }
    }

    Component.onCompleted: {
        if (Compositor.canGroups || Compositor.canSplit || Compositor.canTile)
            root.fetch();
    }

    // A reply read (or one that does not read: an empty or malformed text).
    function takeReply(text: string): void {
        fetchDeadline.stop();
        if (Compositor.canGroups)
            root.groups = WindowTiling.parseGroups(text);
        // A reply that does not read (an empty or cut answer, no Hyprland to ask) keeps the last Split View
        // Desktops; a reply read lets a later deadline retry again.
        const splits = WindowTiling.parseSplits(text);
        const sg = WindowTiling.parseSuggestion(text);
        // A Split View the shell did not start still shows its picker (D48): its suggestion is taken as if asked, also
        // while an earlier ask is still open (WindowTiling.replyPicker; re-review of 29db357, MAJOR 1). Its member counts
        // as waiting for it from now (awaiting) so that it is not filled meanwhile (TilingSuggest).
        let adopted = Compositor.canLayouts && Compositor.canSplit ? WindowTiling.replyPicker(root.wantedGen, Compositor.suggestionAsked, splits, sg, root.declined) : null;
        if (adopted !== null && root.suggestion !== null && root.suggestion.address === adopted.address && root.suggestion.gen === adopted.gen)
            adopted = null; // already the one shown: kept as it is
        if (adopted !== null) {
            Compositor.suggestionAsked = {address: adopted.address, until: Date.now() + WindowTiling.suggestionWaitMs};
            root.awaiting = true;
        }
        if (Compositor.canSplit && splits !== null)
            root.splits = splits;
        const unfit = Compositor.canSplit ? WindowTiling.parseUnfit(text) : null;
        if (unfit !== null)
            root.unfit = unfit;
        const fixed = Compositor.canTile ? WindowTiling.parseFixed(text) : null;
        if (fixed !== null)
            root.fixed = fixed;
        const filled = Compositor.canTile ? WindowTiling.parseFilled(text) : null;
        if (filled !== null)
            root.filled = filled;
        const unfitZones = Compositor.canTile ? WindowTiling.parseUnfitZones(text) : null;
        if (unfitZones !== null)
            root.unfitZones = unfitZones;
        if (splits !== null)
            root.retried = false;
        if (adopted !== null) {
            root.suggestion = adopted;
            root.wantedGen = -1; // an earlier ask's notice is answered by this picker: a later read keeps it shown
            root.awaiting = false;
            return;
        }
        if (root.wantedGen < 0)
            return; // no suggestion wanted, or it ended meanwhile
        const asked = Compositor.suggestionAsked;
        root.suggestion = sg !== null && sg.gen === root.wantedGen && asked !== null && sg.address === asked.address ? sg : null;
        root.awaiting = false; // after the suggestion was shown (or refused): a Split View's picker is that one now
    }

    // A reply that does not come in this time: nothing is shown (a stale suggestion would offer zones that changed); the
    // groups and the Split View Desktops stay as last read (the plugin checks them again at each request), and one more fetch
    // reads them again shortly. Called by the deadline (and by tests/shell/split_view).
    function giveUp(): void {
        root.startPending = false;
        root.query = null;
        root.wantedGen = -1;
        root.awaiting = false; // a Split View's picker is not on its way any more: its member fills (TilingSuggest)
        root.suggestion = null;
        if (!root.retried && (Compositor.canGroups || Compositor.canSplit)) {
            root.retried = true;
            retry.restart();
        }
    }

    Timer {
        id: fetchDeadline

        interval: WindowTiling.suggestionWaitMs
        onTriggered: root.giveUp()
    }

    Timer {
        id: retry

        interval: WindowTiling.suggestionWaitMs / 3
        onTriggered: root.fetch()
    }
}
