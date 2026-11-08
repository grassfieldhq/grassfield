pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.lib
import qs.platform
import "ClipboardLogic.js" as Logic

// The clipboard history (ADR-0034): runs grassfield-clipboard-helper while Settings > Search > Results from Clipboard is on, with
// the display socket it may watch (never one it was not given: in a dev session only GRASSFIELD_CLIPBOARD_DISPLAY), answers each
// copy it announces (recorded only while the history is on, the session unlocked by both lock sources, no authorization request
// open or just ended, no protected password manager in front), pauses it while the session is locked, and passes on the settings
// (retention, the opt-in history store, Clear Clipboard History). It keeps the items' metadata for Search (titles, excerpts,
// thumbnails; never the full text, which stays in the helper). The view is Search's (step 2).
Singleton {
    id: root

    // Settings > Search > Results from Clipboard, as of grassfield.json's last usable read (takeSettings).
    property bool enabled: false
    // "off" (history off), "dev-off" (a dev session without GRASSFIELD_CLIPBOARD_DISPLAY), "starting", "ok", "unsupported" (no
    // ext-data-control-v1 or lock notifier: the view says so), "error" (retried with a growing pause)
    property string state: "off"
    // [{id, kind, mimes, size, copiedAt, pinnedAt, pinned, formatted, files, title, excerpt, thumbnail, app}]: pinned first, newest first
    property var items: []
    // The compositor's lock state as the helper reads it (hyprland_lock_notifier_v1): set by any locker, this shell's or another's.
    property bool helperLocked: false
    // Either lock source: what the view and the paste refuse on.
    readonly property bool locked: SessionState.locked || helperLocked
    // The item the clipboard holds through the helper ("" when another app owns it).
    property string ownedId: ""

    signal searched(int seq, var ids)
    signal pinFull(string id)
    signal previewReady(string id, string path, string text)

    // Dev: the helper built by apps/clipboard-helper/build-direct.sh (GRASSFIELD_CLIPBOARD_HELPER names another, for tests); the
    // session: the package's.
    readonly property string tool: Mode.dev ? (Mode.devValue("CLIPBOARD_HELPER") || Quickshell.shellPath("../.dev/build/grassfield-clipboard-helper")) : "/usr/lib/grassfield/grassfield-clipboard-helper"
    readonly property string display: Logic.displayPath(Mode.dev, Mode.devValue("CLIPBOARD_DISPLAY"), Quickshell.env("XDG_RUNTIME_DIR"), Quickshell.env("WAYLAND_DISPLAY"))
    readonly property string runtimeDir: Logic.runtimeDir(Quickshell.env("XDG_RUNTIME_DIR"), display)
    readonly property string storeDir: Mode.stateDir + "/clipboard"
    readonly property bool runnable: display !== "" && runtimeDir !== ""

    // The password managers whose copies are never recorded: the one list of shell/services/protected-classes.txt, which
    // config/hypr/grassfield/privacy.lua also applies as no_screen_share rules (rc7 audit R7-SEC-03). null until it is read, or
    // when it cannot be: then nothing is recorded (Logic.mayRecord).
    property var protectedClasses: null

    FileView {
        path: Quickshell.shellPath(Logic.PROTECTED_FILE)
        printErrors: false
        onLoaded: root.protectedClasses = Logic.parseProtected(text())
        onLoadFailed: root.protectedClasses = null
    }

    // No copy is recorded while an authorization request is open and for 2 s after it ended (Q11), timed by a Timer (monotonic: a
    // clock set back never lengthens it).
    readonly property bool authorizing: SessionState.authorizing
    property bool authorizingGrace: false
    onAuthorizingChanged: {
        if (root.authorizing)
            return;
        root.authorizingGrace = true;
        root.authGrace.restart();
    }
    readonly property Timer authGrace: Timer {
        interval: Logic.AUTH_GRACE_MS
        repeat: false
        onTriggered: root.authorizingGrace = false
    }

    // Whether the helper should run; `stopping`: turned off, it deletes its history store, then ends by itself (onEnabledChanged).
    property bool wanted: false
    property bool stopping: false
    property int retryMs: 2000
    property bool waiting: false
    // Nothing is decided on values grassfield.json did not give. Before its first read every key reads its default (the history
    // off, no clear asked); a malformed, unreadable or unsafe file reads the defaults or the last good values, a missing or an
    // empty one (what a cut write leaves) the defaults. Acting on those would delete a kept history (review of f7cd664) or skip
    // a clear, and an unreadable file must never delete anything (reviews of c1fc254 and 3f924d9). So the service takes the
    // file's values only from a usable read (valid and not empty), once the read is complete (the store sets validRead before
    // it takes the new values), and keeps the last usable ones otherwise. The first usable read makes the first decision
    // (init); with no usable file (a missing one included) nothing runs and nothing is deleted until Settings or Search's
    // Allow writes one.
    property bool initialized: false
    readonly property bool settingsUsable: Settings.validRead && !Settings.emptyFile
    readonly property string settingsRead: JSON.stringify([root.settingsUsable, Settings.clipboardEnabled, Settings.clipboardRetention,
        Settings.clipboardKeepOnDisk, Settings.clipboardClearedAt, Settings.clipboardPinnedClearedAt])
    onSettingsReadChanged: Qt.callLater(root.takeSettings)

    function takeSettings(): void {
        if (!root.settingsUsable)
            return;
        root.retention = Logic.retentionMs(Settings.clipboardRetention);
        root.keepOnDisk = Settings.clipboardKeepOnDisk;
        root.clearedAt = Settings.clipboardClearedAt;
        root.pinnedClearedAt = Settings.clipboardPinnedClearedAt;
        // Last: a helper it starts is given the values above.
        root.enabled = Settings.clipboardEnabled;
        root.init();
    }

    function send(fields: var): void {
        if (root.helper.running)
            root.helper.write(Logic.line(fields) + "\n");
    }

    function copy(id: string, plainOnly: bool): void {
        root.send(["C", id, plainOnly ? "1" : "0"]);
    }
    function pin(id: string): void {
        root.send(["PIN", id]);
    }
    function unpin(id: string): void {
        root.send(["UNPIN", id]);
    }
    function remove(id: string): void {
        root.send(["X", id]);
    }
    // Clear History: the running helper clears memory and its store; otherwise (off, or waiting to restart after a crash) the
    // store is deleted here, before any helper can load it again.
    function clearHistory(): void {
        if (root.helper.running)
            root.send(["CH"]);
        else
            root.clearHistoryStore();
    }
    function search(seq: int, query: string): void {
        root.send(["Q", String(seq), query]);
    }
    function preview(id: string): void {
        root.send(["V", id]);
    }
    function dropPreview(id: string): void {
        root.send(["VD", id]);
    }
    function expireNow(): void {
        root.send(["E"]);
    }

    function decide(seq: string): void {
        const yes = Logic.mayRecord({
            enabled: root.enabled,
            locked: SessionState.locked,
            helperLocked: root.helperLocked,
            authorizing: root.authorizing,
            authorizingGrace: root.authorizingGrace,
            activeClass: Compositor.focusedAppId,
            protectedClasses: root.protectedClasses
        });
        root.send(yes ? ["Y", seq, Compositor.focusedAppId] : ["N", seq]);
    }

    function handle(text: string): void {
        const f = Logic.parseLine(text);
        switch (f[0]) {
        case "S":
            root.state = f[1] === "ok" ? "ok" : f[1] === "unsupported" ? "unsupported" : "error";
            if (f[1] === "ok")
                root.retryMs = 2000;
            break;
        case "L":
            root.helperLocked = f[1] === "1";
            break;
        case "O":
            root.decide(f[1]);
            break;
        case "I": {
            const item = Logic.parseItem(f);
            if (item)
                root.items = Logic.upsert(root.items, item);
            break;
        }
        case "X":
            // The clipboard keeps the helper's copy of a deleted item (ownedId stays).
            root.items = Logic.removeId(root.items, f[1]);
            break;
        case "A":
            root.ownedId = f[1] || "";
            root.pasteOwned(root.ownedId);
            break;
        case "R":
            root.searched(Number(f[1]), f.slice(2));
            break;
        case "N":
            if (f[1] === "pin-full")
                root.pinFull(f[2] || "");
            break;
        case "V":
            root.previewReady(f[1] || "", f[2] || "", f[3] || "");
            break;
        }
    }

    function start(): void {
        if (!root.enabled) {
            root.state = "off";
            return;
        }
        if (!root.runnable) {
            // No helper can run: Settings' clears are carried out all the same.
            root.applyClears();
            root.state = Mode.dev ? "dev-off" : "error";
            if (Mode.dev)
                console.info("grassfield: clipboard history off in development (set GRASSFIELD_CLIPBOARD_DISPLAY to the nested socket)");
            return;
        }
        root.state = "starting";
        root.wanted = true;
    }

    onEnabledChanged: {
        if (!root.initialized)
            return;
        if (root.enabled) {
            root.start();
            return;
        }
        // Off: the unpinned items go (the helper deletes its history store, then ends; memory ends with it). Pins stay on disk.
        root.items = [];
        root.ownedId = "";
        root.state = "off";
        if (root.helper.running) {
            root.stopping = true;
            root.send(["D", "0"]);
            root.send(["QUIT"]);
        } else {
            root.clearHistoryStore();
        }
        root.wanted = false;
    }

    // The other settings, as of the last usable read (takeSettings).
    property real retention: Logic.retentionMs("")
    onRetentionChanged: root.send(["T", String(root.retention)])
    property bool keepOnDisk: false
    onKeepOnDiskChanged: root.send(["D", root.keepOnDisk ? "1" : "0"])
    // Settings' clears (Clear Clipboard History…, with or without the pinned items): the running helper clears and records the
    // setting's time; with the history off, --apply-clears carries them out now; a helper about to start is given them. The
    // helper records what it carried out, so a clear written while the shell was stopped is carried out at the next start.
    property real clearedAt: 0
    onClearedAtChanged: root.clearAsked(false)
    property real pinnedClearedAt: 0
    onPinnedClearedAtChanged: root.clearAsked(true)

    function clearAsked(pinned: bool): void {
        if (!root.initialized)
            return;
        if (root.helper.running)
            root.send([pinned ? "CP" : "CH", Logic.clearTimeArg(pinned ? root.pinnedClearedAt : root.clearedAt)]);
        else if (!root.wanted)
            root.applyClears();
    }

    // The store jobs run without a helper (--clear-history, --apply-clears), one after the other: a job asked while one runs
    // waits for it. Each Process is started before its flag is dropped, so the helper (which waits for both) never starts
    // between two of them.
    function clearHistoryStore(): void {
        if (root.historyClear.running || root.clearsApply.running)
            root.historyAgain = true;
        else
            root.historyClear.running = true;
    }
    function applyClears(): void {
        if (root.historyClear.running || root.clearsApply.running)
            root.clearsAgain = true;
        else
            root.startClearsApply();
    }
    // The times are read when it starts: a binding on them may not be updated yet inside onClearedAtChanged, which would carry
    // out the previous clear.
    function startClearsApply(): void {
        root.clearsApply.command = [root.tool, "--apply-clears", "--state", root.storeDir, "--cleared-at",
            Logic.clearTimeArg(root.clearedAt), "--pinned-cleared-at", Logic.clearTimeArg(root.pinnedClearedAt)];
        root.clearsApply.running = true;
    }
    function storeJobEnded(): void {
        if (root.historyClear.running || root.clearsApply.running)
            return;
        if (root.historyAgain) {
            root.historyClear.running = true;
            root.historyAgain = false;
        } else if (root.clearsAgain) {
            root.startClearsApply();
            root.clearsAgain = false;
        }
    }
    property bool historyAgain: false
    property bool clearsAgain: false

    // Capture follows the shell's own lock as well (SessionState.locked covers its "locking" phase).
    readonly property bool sessionLocked: SessionState.locked
    onSessionLockedChanged: root.send([root.sessionLocked ? "P" : "R"])

    readonly property Process helper: Process {
        // Never while a store is being cleared without it (it would load what is being deleted).
        running: (root.wanted || root.stopping) && !root.waiting && !root.historyClear.running && !root.clearsApply.running
            && !root.historyAgain && !root.clearsAgain
        command: [root.tool, "--display", root.display, "--state", root.storeDir, "--runtime", root.runtimeDir,
            "--retention", String(root.retention), "--history-store", root.keepOnDisk ? "1" : "0",
            "--cleared-at", Logic.clearTimeArg(root.clearedAt), "--pinned-cleared-at", Logic.clearTimeArg(root.pinnedClearedAt)]
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => root.handle(line)
        }
        onStarted: root.send([SessionState.locked ? "P" : "R"])
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            root.stopping = false;
            root.helperLocked = false;
            root.ownedId = "";
            root.items = [];
            if (!root.wanted || !root.enabled)
                return;
            if (code === 3) {
                root.state = "unsupported";
                root.wanted = false;
                return;
            }
            // Crashed, or lost the compositor: started again after a pause doubling up to 5 minutes.
            root.state = "error";
            console.warn("grassfield: the clipboard helper ended (" + code + "); started again in " + root.retryMs + " ms");
            root.waiting = true;
            root.retry.interval = root.retryMs;
            root.retry.restart();
            root.retryMs = Math.min(root.retryMs * 2, 300000);
        }
    }

    readonly property Timer retry: Timer {
        repeat: false
        onTriggered: root.waiting = false
    }

    // With the history off: the history store the helper would delete if it ran (a turned-off history keeps no unpinned item on
    // disk), and Settings' clears not carried out yet ("Also delete pinned items" deletes the pinned store).
    readonly property Process historyClear: Process {
        command: [root.tool, "--clear-history", "--state", root.storeDir]
        onRunningChanged: {
            if (!running)
                root.storeJobEnded();
        }
    }
    readonly property Process clearsApply: Process {
        // Set by startClearsApply.
        command: []
        onRunningChanged: {
            if (!running)
                root.storeJobEnded();
        }
    }

    // The first decision, on the first usable read: run the helper (it carries out the clears asked before anything is shown),
    // or, with the history off, delete the history store, then carry out the clears.
    function init(): void {
        if (root.initialized)
            return;
        root.initialized = true;
        if (root.enabled) {
            root.start();
        } else {
            root.clearHistoryStore();
            root.applyClears();
        }
    }

    // The settings may have been read before this service was created.
    Component.onCompleted: Qt.callLater(root.takeSettings)

    // ---- Paste on choice (ADR-0034 §4, Q9) ----

    // The window that was active when Search opened (lower-case hex without 0x, "" when none) and whether Hyprland closed it
    // since: a new window can take its address, so a closed target never gets the keys.
    property string pasteTarget: ""
    property bool pasteTargetClosed: false
    // The item being pasted while the helper takes the clipboard, then while the target comes back: {id, plain, copied, target,
    // closed}. The target (hex, "" for a copy only: no window to paste into) and whether it closed are kept with the paste, so a
    // later watchTarget never redirects it.
    property var pendingPaste: null
    // The PASTE_WAIT_MS after the helper owned the item have passed (pasteDeadline, a Qt timer: monotonic).
    property bool pasteExpired: false
    // The item Copy asked for (the copy button, Ctrl+C, the menu's Copy) until the helper confirms or refuses it, "" otherwise.
    property string pendingCopy: ""
    // The last paste's outcome for the dev status ("" none, "sent", or why it was dropped).
    property string lastPaste: ""

    // The helper owns the item to paste: Search closes and FocusReturn gives the keyboard back to the target.
    signal pasteCopied
    // The helper owns the item Copy asked for; or it could not take the clipboard for a copy or a paste (Search says so).
    signal copyConfirmed(string id)
    signal copyRefused

    // Search opened over `address` (Compositor.activeWindow()): a later paste may only ever go there. A paste still waiting
    // from an earlier opening is dropped.
    function watchTarget(address: string): void {
        root.cancelPaste("Search opened again");
        root.pasteTarget = Logic.addressHex(address);
        root.pasteTargetClosed = false;
    }

    // Copy: the item goes on the clipboard and nothing is pasted; copyConfirmed or copyRefused follows. A paste still waiting
    // is dropped: the clipboard is about to hold this item, which Ctrl+V would paste instead of the one chosen.
    function copyItem(id: string): void {
        root.cancelPaste("another item copied");
        root.pendingCopy = id;
        root.copy(id, false);
        root.copyWait.restart();
    }

    // Copies the item (all its parts, or the plain text only), then pastes it into the target once it is active again. With no
    // target (Search opened over the desktop, or the window closed) the item is only copied. Either way Search closes only once
    // the helper owns the item (pasteCopied); a refusal keeps it open (copyRefused).
    function paste(id: string, plain: bool): void {
        root.cancelPaste("");
        root.pendingPaste = {
            id: id,
            plain: plain,
            copied: false,
            target: root.pasteTargetClosed ? "" : root.pasteTarget,
            closed: root.pasteTargetClosed
        };
        root.copy(id, plain);
        root.copyWait.restart();
    }

    // Search closed (Esc, a click outside, a lock, another surface): a paste the helper has not confirmed yet is dropped, so a
    // late confirmation pastes nothing. A confirmed one (Search closed because of it) goes on.
    function searchClosed(): void {
        const p = root.pendingPaste;
        if (p !== null && !p.copied)
            root.cancelPaste("Search closed");
    }

    // The helper's `A`: the item it now owns, "" when it could not take the clipboard or lost it.
    function pasteOwned(id: string): void {
        let refused = false;
        if (root.pendingCopy !== "" && (id === root.pendingCopy || id === "")) {
            const asked = root.pendingCopy;
            root.pendingCopy = "";
            if (id === asked)
                root.copyConfirmed(id);
            else
                refused = true;
        }
        const p = root.pendingPaste;
        if (p !== null && !p.copied) {
            if (id === p.id) {
                if (p.target === "") {
                    root.pendingPaste = null;
                    root.lastPaste = "copied only";
                    root.pasteCopied();
                } else {
                    root.pendingPaste = Object.assign({}, p, {
                        copied: true
                    });
                    root.pasteExpired = false;
                    root.pasteDeadline.restart();
                    root.pasteCopied();
                    root.pasteWatch.restart();
                }
            } else if (id === "") {
                root.cancelPaste("not copied");
                refused = true;
            }
        }
        if (root.pendingCopy === "" && (root.pendingPaste === null || root.pendingPaste.copied))
            root.copyWait.stop();
        if (refused)
            root.copyRefused();
    }

    function cancelPaste(why: string): void {
        root.pasteWatch.stop();
        root.pasteDeadline.stop();
        if (root.pendingPaste !== null && why !== "") {
            root.lastPaste = why;
            console.info("grassfield: clipboard paste dropped:", why);
        }
        root.pendingPaste = null;
    }

    // What one check of a confirmed paste sees (Logic.pasteStep's input): the paste's own target and whether it closed, never
    // the live pasteTarget; whether the helper still owns the item chosen (`A` names the owned item, "" once another app took
    // the clipboard).
    function pasteState(p: var, activeAddress: string): var {
        return {
            locked: SessionState.locked,
            helperLocked: root.helperLocked,
            rememberedAddress: p.target,
            activeAddress: activeAddress,
            closedSinceOpen: p.closed,
            otherSurfaceOpen: FocusReturn.anyOpen(),
            ownsItem: root.ownedId === p.id,
            expired: root.pasteExpired
        };
    }

    function pasteTick(): void {
        const p = root.pendingPaste;
        if (p === null || !p.copied) {
            root.pasteWatch.stop();
            return;
        }
        const active = Compositor.activeWindow();
        const step = Logic.pasteStep(root.pasteState(p, active ? active.address : ""));
        if (step === "wait")
            return;
        if (step !== "send") {
            root.cancelPaste(step);
            return;
        }
        root.pasteWatch.stop();
        root.pasteDeadline.stop();
        root.pendingPaste = null;
        root.lastPaste = Compositor.dispatchRequest(Logic.pasteRequest(p.target)) ? "sent" : "not sent";
    }

    // The helper did not answer a copy or a paste in time (not running, or busy): nothing is pasted, and Search says so.
    readonly property Timer copyWait: Timer {
        interval: Logic.PASTE_WAIT_MS
        repeat: false
        onTriggered: {
            const p = root.pendingPaste;
            const waiting = root.pendingCopy !== "" || (p !== null && !p.copied);
            root.pendingCopy = "";
            if (p !== null && !p.copied)
                root.cancelPaste("not copied in time");
            if (waiting)
                root.copyRefused();
        }
    }
    // The paste's 1 s, from the helper owning the item: then one last check drops it.
    readonly property Timer pasteDeadline: Timer {
        interval: Logic.PASTE_WAIT_MS
        repeat: false
        onTriggered: {
            root.pasteExpired = true;
            root.pasteTick();
        }
    }
    // Checks every 50 ms whether the target is active again (FocusReturn's request lands after Search's surface is gone).
    readonly property Timer pasteWatch: Timer {
        interval: Logic.PASTE_POLL_MS
        repeat: true
        onTriggered: root.pasteTick()
    }

    Connections {
        target: Compositor

        function onWindowClosed(address: string): void {
            if (address === root.pasteTarget)
                root.pasteTargetClosed = true;
            const p = root.pendingPaste;
            if (p !== null && p.target !== "" && address === p.target)
                root.pendingPaste = Object.assign({}, p, {
                    closed: true
                });
        }
    }

    IpcHandler {
        target: "clipboard"

        // Test hook: the state and the items' metadata (titles and excerpts are what the user copied: dev only).
        function status(): string {
            if (!Mode.dev)
                return Mode.refused;
            return JSON.stringify({
                state: root.state,
                locked: root.locked,
                owned: root.ownedId,
                items: root.items,
                paste: {
                    target: root.pasteTarget,
                    closed: root.pasteTargetClosed,
                    pending: root.pendingPaste,
                    copy: root.pendingCopy,
                    last: root.lastPaste
                }
            });
        }
    }
}
