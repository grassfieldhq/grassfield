pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.lib
import qs.platform
import "SharePicker.js" as Logic

// The screen-sharing picker's channel (ADR-0035 D-6, step 7a; spec system-dialogs.md section 3). xdph runs the stand-in
// packaging/session-bin/hyprland-share-picker, which asks here with `picker request <id> <socket>`; the answer comes at
// once: "accepted", "busy" (a picker is open: one at a time), "locked" (owner decision Q15: nothing shows while the session
// is locked) or "refused" (not a request of the stand-in's form; it then runs the stock picker, as with no shell). Accepted,
// the shell connects to the stand-in's one-time socket with a Socket made for that request alone (destroyed when the request
// ends, whatever ends it) and shows the panel (SharePickerPanel, popup kind "sharePicker") only once the stand-in's window
// list has arrived on it; a connection that fails or a list that does not come within 2 s shows nothing. While the panel is open the shell writes `<id> wait` every 5 s, then one answer, `<id> <flags>/<choice>` or
// `<id> cancel`, and closes. The panel goes when the stand-in's end closes (it gave up, or xdph ended), when the session
// locks, or when another popup takes its place: each of those is "cancelled". Window titles are never logged.
Singleton {
    id: root

    // The request being answered, {id, path}, or null.
    property var current: null
    // Its channel: a Socket made for this request (channelComponent) and destroyed when it ends. Never one Socket for every
    // request: on Quickshell 0.3.1 a Socket whose connection failed once keeps its dead QLocalSocket and never connects again
    // (fixed upstream in 0.3.2, "io/socket: discard sockets which have failed to connect"), so after one stand-in that gave up
    // every later request was accepted, then cancelled after 2 s (review of PR #83, MAJOR 2).
    property Socket channel: null
    // The request Sockets alive (a test hook, in `picker status`): one while a request is open, none once it ended.
    property int channels: 0
    // The windows xdph listed ({handle, appId, title, address}), from the stand-in's list line.
    property var windows: []
    // xdph passed --allow-token (allow_token_by_default; Omarchy's xdph.conf sets it), from the stand-in's options line before
    // the list. The panel opens Remember this choice ticked from it only while SharePickerPanel.followAllowToken is true
    // (pending the owner's agreement to amend Q14); then xdph gives the app a restore token, and a browser that asks once for
    // its own preview and again to share (Chromium's WebRTC) is not asked twice (bug report on rc6). An older stand-in sends no
    // options line: false.
    property bool allowToken: false
    // The panel was shown for the current request.
    property bool shown: false
    // The handles of the listed windows that hide themselves from capture (no_screen_share; step 7b): greyed, never chosen.
    // No window is answered until Hyprland has said which (blockedKnown).
    property var blocked: []
    property bool blockedKnown: false
    // The windows' query: one per shown request (`blockedFor`, the request it runs for); Quickshell's Process does not start
    // again while it runs, so a newer request's query starts when the older one ends.
    property string blockedFor: ""
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") ?? ""

    // The recording indicator (step 7b): xdph's screen-sharing streams, and what each shares when the picker chose it.
    readonly property var streams: Logic.sharingStreams((Pipewire.nodes ? Pipewire.nodes.values : []).map(n => ({
                id: n.id,
                name: n.name,
                video: (n.type & PwNodeType.Video) !== 0
            })))
    readonly property bool sharing: root.streams.length > 0
    // Stream id -> {kind, value, title} or null; the choices answered that no stream has taken yet ({at, what}). An app starts
    // its stream as soon as the portal answers it: a choice older than labelWindowMs names no stream (it may never have
    // started one; decision 7-12: kept short, the label is best effort).
    property var labels: ({})
    property var pending: []
    readonly property int labelWindowMs: 3000

    onStreamsChanged: {
        const next = Logic.streamLabels(root.labels, root.streams, root.pending, Date.now(), root.labelWindowMs);
        root.labels = next.labels;
        root.pending = next.pending;
    }

    // The displays the panel offers: Hyprland's names, as xdph reads them, and their logical sizes.
    function outputs(): var {
        return Quickshell.screens.map(s => s.name);
    }

    function sizes(): var {
        const out = {};
        for (const s of Quickshell.screens)
            out[s.name] = {
                width: s.width,
                height: s.height
            };
        return out;
    }

    // The user's choice: a display's name, a window's handle or an area (`<display>@x,y,w,h`); `remember` for Remember this
    // choice.
    function share(kind: string, value: string, remember: bool): void {
        const line = Logic.selection(kind, value, remember, root.outputs(), root.windows, root.sizes(), root.blockedKnown ? root.blocked : null);
        if (line === "" || root.current === null)
            return;
        const w = kind === "window" ? root.windows.find(x => x.handle === value) : null;
        root.pending = root.pending.concat([{
                at: Date.now(),
                what: {
                    kind: kind,
                    value: kind === "region" ? Logic.parseRegion(value).output : value,
                    title: w ? w.title : ""
                }
            }]);
        root.finish(root.current.id + " " + line);
    }

    function cancel(): void {
        if (root.current !== null)
            root.finish(root.current.id + " cancel");
    }

    // One answer line (or none), then the channel closes and goes, and the panel closes. Never called from inside a Socket's
    // error signal (lost() runs later): a Socket closed or destroyed there crashes Quickshell 0.3.2 (tests/ci/socket_errors.py).
    function finish(line: string): void {
        const wasShown = root.shown;
        const sock = root.channel;
        root.channel = null;
        if (sock !== null) {
            if (line !== "" && sock.connected) {
                sock.write(line + "\n");
                sock.flush();
            }
            sock.connected = false;
            Qt.callLater(() => sock.destroy());
        }
        root.current = null;
        root.windows = [];
        root.allowToken = false;
        root.blocked = [];
        root.blockedKnown = false;
        root.shown = false;
        connectDeadline.stop();
        if (wasShown && Popups.kind === "sharePicker")
            Popups.close();
    }

    // A line on a request's channel; a channel that is not the current request's says nothing.
    function received(sock: Socket, line: string): void {
        if (sock === null || sock !== root.channel || root.current === null || root.shown)
            return;
        const options = Logic.parseOptions(line, root.current.id);
        if (options !== null) {
            root.allowToken = options.allowToken;
            return;
        }
        const listed = Logic.parseList(line, root.current.id);
        if (listed === null)
            return;
        root.windows = listed;
        root.shown = true;
        connectDeadline.stop();
        root.askBlocked();
        Popups.openCentered("sharePicker", {}, "");
        if (Popups.kind !== "sharePicker")
            root.cancel();
    }

    // Which listed windows hide themselves from capture: Hyprland's effective rule, one getprop per window with an address, 16
    // at a time (Hyprland's socket takes a backlog of 10), 1 s each at most, each answer on its own line after its address.
    function askBlocked(): void {
        if (root.current === null || !root.shown || blockedQuery.running)
            return;
        const addresses = root.windows.filter(w => w.address !== "").map(w => w.address);
        if (addresses.length === 0) {
            root.blocked = [];
            root.blockedKnown = true;
            return;
        }
        root.blockedFor = root.current.id;
        // Each answer goes out as one write of one line (under PIPE_BUF: atomic), so the parallel answers never interleave.
        blockedQuery.command = ["sh", "-c", "n=0; for a; do (r=$(timeout 1 hyprctl -j getprop \"address:0x$a\" no_screen_share 2>/dev/null | tr -d '\\n'); printf '%s %s\\n' \"$a\" \"$r\") & n=$((n + 1)); [ $((n % 16)) -ne 0 ] || wait; done; wait", "sh"].concat(addresses);
        blockedQuery.running = true;
    }

    // The request's connection failed, or ended: the stand-in gave up (2 s without a connection) or xdph ended. A channel that
    // is no longer the current request's (it ended, a newer one has its own) changes nothing.
    function lost(sock: Socket): void {
        if (sock !== null && sock === root.channel && root.current !== null && !sock.connected)
            root.finish("");
    }

    Process {
        id: blockedQuery
        stdout: StdioCollector {
            onStreamFinished: {
                if (root.current !== null && root.shown && root.blockedFor === root.current.id) {
                    root.blocked = Logic.blockedHandles(root.windows, text);
                    root.blockedKnown = true;
                }
            }
        }
        // A newer request's query waited for this one. A query that ended without an answer read (sh could not start: Quickshell
        // reports it only by stopping) leaves no window greyed, as an unreadable answer does: Hyprland still blacks out a
        // window that hides from capture in every capture (decision 7-13).
        onRunningChanged: {
            if (running || root.current === null || !root.shown || root.blockedKnown)
                return;
            if (root.blockedFor !== root.current.id) {
                Qt.callLater(root.askBlocked);
            } else {
                console.warn("SharePicker: the windows' capture rules could not be read; none is greyed");
                root.blocked = [];
                root.blockedKnown = true;
            }
        }
    }

    // One per request (request() makes it, finish() destroys it). Its error is judged once Quickshell's own error handler has
    // returned (the signal can fire inside createObject, and closing the Socket from inside it crashes Quickshell 0.3.2).
    Component {
        id: channelComponent

        Socket {
            id: sock

            function lost(): void {
                root.lost(sock);
            }

            parser: SplitParser {
                onRead: line => root.received(sock, line)
            }
            onConnectedChanged: Qt.callLater(sock.lost)
            Component.onCompleted: {
                root.channels++;
                sock.error.connect(() => Qt.callLater(sock.lost));
                sock.connected = true;
            }
            Component.onDestruction: root.channels--
        }
    }

    // Accepted: the connection and the window list within 2 s, as the stand-in waits for them; else nothing shows.
    Timer {
        id: connectDeadline
        interval: 2000
        onTriggered: {
            if (root.current !== null && !root.shown)
                root.finish("");
        }
    }

    // While the panel is open: the stand-in counts 15 s without a line as a shell that hangs.
    Timer {
        interval: 5000
        repeat: true
        running: root.shown && root.channel !== null && root.channel.connected
        onTriggered: {
            if (root.channel === null || root.current === null)
                return;
            root.channel.write(root.current.id + " wait\n");
            root.channel.flush();
        }
    }

    Connections {
        target: SessionState
        function onLockedChanged(): void {
            if (SessionState.locked)
                root.cancel();
        }
    }

    // Another popup in its place (a menu bar click, an IPC open) or a click outside closed the panel: cancelled.
    Connections {
        target: Popups
        function onKindChanged(): void {
            if (root.shown && Popups.kind !== "sharePicker")
                root.cancel();
        }
    }

    IpcHandler {
        target: "picker"

        // The stand-in's request (security.md "IPC surface": an action of packaging/session-bin/hyprland-share-picker).
        function request(id: string, socket: string): string {
            if (SessionState.refuses("picker"))
                return "locked";
            if (!Logic.validRequest(id, socket, root.runtimeDir)) {
                console.info("grassfield: share picker request refused: not the stand-in's form");
                return "refused";
            }
            if (root.current !== null)
                return "busy";
            root.current = {
                id: id,
                path: socket
            };
            root.windows = [];
            root.allowToken = false;
            root.shown = false;
            connectDeadline.restart();
            root.channel = channelComponent.createObject(root, {
                path: socket
            }) as Socket;
            return "accepted";
        }

        // Test hooks: the state (window titles: dev only), and the user's choice as the panel makes it.
        function status(): string {
            if (!Mode.dev)
                return Mode.refused;
            return JSON.stringify({
                open: root.current !== null,
                shown: root.shown,
                connected: root.channel !== null && root.channel.connected,
                channels: root.channels,
                popup: Popups.kind,
                outputs: root.outputs(),
                windows: root.windows,
                allowToken: root.allowToken,
                blocked: root.blockedKnown ? root.blocked : null,
                streams: root.streams.length,
                labels: root.labels,
                // The windows whose live thumbnail has a source (a toplevel Hyprland knows at that address).
                sources: root.windows.filter(w => w.address !== "" && Compositor.toplevelByAddress(w.address) !== null).length
            });
        }

        function choose(kind: string, value: string, remember: string): string {
            if (!Mode.dev)
                return Mode.refused;
            if (!root.shown)
                return "closed";
            root.share(kind, value, remember === "remember");
            return "ok";
        }
    }
}
