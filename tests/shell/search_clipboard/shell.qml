pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.platform
import qs.search
import qs.services
import "services/ClipboardLogic.js" as Logic

// Search's Clipboard view on the REAL Search controller and the REAL Clipboard service (ADR-0034 step 2; scripts/dev/test.sh:
// `qs -p tests/shell/search_clipboard`, offscreen, a dev session; prints "search-clipboard: PASS" or the failures). No helper
// runs: the dev session has no GRASSFIELD_CLIPBOARD_DISPLAY (state "dev-off"), so the helper's lines are handed to
// Clipboard.handle() as the helper would print them, and nothing touches a real clipboard or compositor.
// - entering and leaving the view (⌘4 / the button, Backspace, Super+Ctrl+V's toggle), the first-use prompt, Not Now, Allow;
// - the rows (pinned first), the helper's search answers (stale ones ignored), Copy (the row says Copied once the helper owns
//   the item; a refusal says so), Delete (the next row takes the selection), the pin-full and pin-failed notices, a copy
//   cleared soon by its app (K: forgotten while the app has a window), the preview;
// - the paste never lands where the user did not just ask for it: Search closes only once the helper owns the item; closing
//   Search first (Esc, a click outside) drops it, so a late confirmation pastes nothing; once copied it is dropped when this
//   shell or another program locks the session, another surface opens, the target closes, Search opens again or the 1 s
//   deadline passes; with no target the item is only copied; a refused or unanswered copy keeps Search open with a notice.
ShellRoot {
    id: root

    property var failures: []
    // The scenario: [what to run, how long to wait before the next one (ms)]. The waits let the paste's 50 ms checks and its
    // 1 s timers run, as they do in a session.
    property var script: []
    property int next: 0

    readonly property var ids: ["00000000000000a1", "00000000000000a2", "00000000000000a3", "00000000000000a4"]
    readonly property string target: "abcdef12"

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function item(id: string, pinnedAt: int, copiedAt: int, title: string): string {
        return Logic.line(["I", id, "text", "text/plain;charset=utf-8", String(title.length), String(copiedAt), String(pinnedAt), "0", "0", title, title, "", "kitty"]);
    }

    function owned(id: string): void {
        Clipboard.handle(Logic.line(["A", id]));
    }

    function keys(): string {
        return search.rows.map(r => r.item.clip.id.slice(-1)).join("");
    }

    // Search open on its Clipboard view over the target window, the first row selected, and a paste of it chosen: the helper
    // has not answered yet.
    function choosePaste(): void {
        if (!search.open || !search.clipboardView)
            search.toggleClipboard();
        Clipboard.watchTarget("0x" + root.target.toUpperCase());
        search.selected = 0;
        search.clipPaste(search.selectedClip(), false);
    }

    // As choosePaste, then the helper owns the item: Search closes and the service waits for the target.
    function pasteCopied(): void {
        choosePaste();
        owned(root.ids[2]);
    }

    Search {
        id: search
    }

    function steps(): var {
        const ids = root.ids;
        return [[() => {
                    // grassfield.json does not exist yet here: nothing ran on the settings' defaults (review of f7cd664).
                    check("nothing runs before the settings are read", !Clipboard.initialized && !Clipboard.historyClear.running && !Clipboard.clearsApply.running);
                    check("history off by default", !Clipboard.enabled);
                    search.show("");
                    check("Search opens on the results", search.open && search.view === "" && !search.clipboardView);
                    search.setQuery("abc");
                    search.enterClipboard();
                    check("⌘4 enters the view with an empty field", search.clipboardView && search.query === "");
                    check("the view asks first while the history is off", search.clipPrompt && search.rows.length === 0);
                    search.clipNotNow();
                    check("Not Now leaves the view, Search stays open", search.open && !search.clipboardView && !Clipboard.enabled);
                    // The sticky notice of a refused script row (Search.say(text, true)): it goes with a query change, with entering or
                    // leaving the Clipboard view, and with closing; a timed notice after it is a timed one again.
                    search.say("refused", true);
                    check("a sticky notice is set and stays (no timer)", search.clipNotice === "refused" && search.noticeSticky);
                    search.setQuery("abcd");
                    check("a query change clears the sticky notice", search.clipNotice === "" && !search.noticeSticky);
                    search.say("refused", true);
                    search.enterClipboard();
                    check("entering the Clipboard view clears the sticky notice", search.clipNotice === "" && !search.noticeSticky);
                    search.say("timed", false);
                    check("a timed notice is not sticky", search.clipNotice === "timed" && !search.noticeSticky);
                    search.setQuery("x");
                    check("a timed notice survives typing in the view (its own timer ends it)", search.clipNotice === "timed");
                    search.say("refused", true);
                    check("a sticky notice replaces a timed one and stops its timer", search.clipNotice === "refused" && search.noticeSticky);
                    search.leaveClipboard();
                    check("leaving the Clipboard view clears the sticky notice", search.clipNotice === "" && !search.noticeSticky);
                    search.say("refused", true);
                    search.say("timed", false);
                    check("a timed notice after a sticky one is not sticky", search.clipNotice === "timed" && !search.noticeSticky);
                    search.setQuery("abcde");
                    check("typing does not end a timed notice", search.clipNotice === "timed");
                    search.say("refused", true);
                    search.hide();
                    check("closing clears the sticky notice", search.clipNotice === "" && !search.noticeSticky);
                    search.show("");
                    search.toggleClipboard();
                    check("Super+Ctrl+V over open Search enters the view", search.open && search.clipboardView);
                    search.toggleClipboard();
                    // The view resets once the panel is unmapped after its fade-out (SearchPanel -> released(), U9), not at hide().
                    check("Super+Ctrl+V in the view closes Search, the view kept during the fade", !search.open && search.clipboardView);
                    search.released();
                    check("Super+Ctrl+V in the view closes Search", !search.open && search.view === "");
                    search.toggleClipboard();
                    check("Super+Ctrl+V opens Search in the view", search.open && search.clipboardView);
                    search.clipAllow();
                    check("Allow before the file is read back: nothing starts yet (" + Clipboard.state + ")", Clipboard.initialized || Clipboard.state === "off");
                }, -1] // waits for the setting (below)
            , [() => {
                    check("Allow turns the history on", Clipboard.enabled && !search.clipPrompt);
                    check("the settings read, the service decided", Clipboard.initialized);
                    const given = command => {
                        const i = command.indexOf("--cleared-at");
                        const j = command.indexOf("--pinned-cleared-at");
                        return i > 0 && command[i + 1] === Logic.clearTimeArg(Clipboard.clearedAt) && j > 0 && command[j + 1] === Logic.clearTimeArg(Clipboard.pinnedClearedAt);
                    };
                    check("the helper is given the settings' clears", given(Clipboard.helper.command));
                    check("--apply-clears is given them too", Clipboard.clearsApply.command.indexOf("--apply-clears") > 0 && given(Clipboard.clearsApply.command));
                    check("no helper in a dev session without the display", Clipboard.state === "dev-off");
                    Clipboard.handle(item(ids[0], 0, 1000, "alpha"));
                    Clipboard.handle(item(ids[1], 0, 2000, "bravo"));
                    Clipboard.handle(item(ids[2], 5000, 1500, "charlie"));
                    Clipboard.handle(item(ids[3], 0, 3000, "delta"));
                    check("rows: pinned first, then newest copy first (" + keys() + ")", keys() === "3421");
                    check("a new item leaves the selection on its row", search.selectedClip().clip.id === ids[0]);
                    search.leaveClipboard();
                    search.enterClipboard();
                    check("entering the view selects the first row", search.selected === 0 && search.selectedClip().clip.id === ids[2]);
                    check("rows are clipboard rows", search.rows.every(r => r.item.kind === "clip" && r.item.key === "clip:" + r.item.clip.id));

                    search.setQuery("br");
                    const seq = search.clipSeq;
                    Clipboard.handle(Logic.line(["R", String(seq - 1), ids[0]]));
                    check("a stale search answer is ignored", keys() === "3421");
                    Clipboard.handle(Logic.line(["R", String(seq), ids[1]]));
                    check("the helper's answer filters the rows", keys() === "2");
                    search.setQuery("zz");
                    Clipboard.handle(Logic.line(["R", String(search.clipSeq)]));
                    check("no match, no rows", search.rows.length === 0 && search.selected === -1);
                    search.setQuery("");
                    check("an empty query lists every item again", keys() === "3421");

                    // Copy: the row says Copied once the helper owns the item, and Search stays.
                    search.selected = 1;
                    search.clipCopy(search.selectedClip());
                    check("Copy waits for the helper", search.clipCopiedKey === "" && Clipboard.pendingCopy === ids[3]);
                    owned(ids[3]);
                    check("Copy keeps Search open and the row says Copied", search.open && search.clipCopiedKey === "clip:" + ids[3]);
                    search.clipCopy(search.selectedClip());
                    owned("");
                    check("a refused copy says so", search.open && search.clipNotice === "The item could not be copied" && Clipboard.pendingCopy === "");

                    search.clipDelete(search.selectedClip());
                    Clipboard.handle(Logic.line(["X", ids[3]]));
                    check("Delete: the next row takes the selection (" + keys() + ", " + search.selected + ")", keys() === "321" && search.selected === 1);
                    search.selected = 2;
                    search.clipDelete(search.selectedClip());
                    Clipboard.handle(Logic.line(["X", ids[0]]));
                    check("Delete of the last row: the new last row", keys() === "32" && search.selected === 1);

                    Clipboard.handle(Logic.line(["N", "pin-full", ids[1]]));
                    check("pin-full shows the notice", search.clipNotice === "Pinned items are full");
                    // B-09: the pin could not be written (an `I` line with pinnedAt 0 precedes it): its own notice.
                    Clipboard.handle(Logic.line(["N", "pin-failed", ids[1]]));
                    check("pin-failed shows its notice", search.clipNotice === "Couldn't pin the item");
                    // B-10: `K` (cleared soon after the copy): forgotten when the app it came from still has a window, else kept;
                    // a pinned item is the user's and stays.
                    const hasWindow = Clipboard.hasWindow;
                    Clipboard.hasWindow = app => false;
                    Clipboard.handle(Logic.line(["K", ids[1]]));
                    check("K with the app's windows gone: kept (" + keys() + ")", keys() === "32");
                    Clipboard.hasWindow = app => app === "kitty";
                    Clipboard.handle(Logic.line(["K", ids[2]]));
                    check("K on a pinned item: kept", keys() === "32");
                    Clipboard.handle(Logic.line(["K", ids[1]]));
                    check("K with the app's window open: forgotten (" + keys() + ")", keys() === "3");
                    Clipboard.hasWindow = hasWindow;
                    Clipboard.handle(item(ids[1], 0, 2000, "bravo"));

                    search.selected = 0;
                    search.clipTogglePreview();
                    check("Space previews the selected item", search.clipPreview !== null && search.clipPreview.id === ids[2]);
                    Clipboard.handle(Logic.line(["V", ids[1], "", "late"]));
                    check("another item's preview is ignored", search.clipPreviewText === "");
                    Clipboard.handle(Logic.line(["V", ids[2], "", "charlie\nline 2"]));
                    check("the preview shows the helper's text", search.clipPreviewReady && search.clipPreviewText === "charlie\nline 2");
                    search.selected = 1;
                    check("the preview follows the selection", search.clipPreview !== null && search.clipPreview.id === ids[1] && !search.clipPreviewReady);
                    search.clipTogglePreview();
                    check("Space again closes the preview", search.clipPreview === null);

                    search.leaveClipboard();
                    check("Backspace in the empty field leaves the view", search.open && !search.clipboardView && search.clipNotice === "");

                    // No window to paste into: Search waits for the helper, then closes; the item is only copied.
                    search.enterClipboard();
                    Clipboard.watchTarget("");
                    search.clipPaste(search.selectedClip(), false);
                    check("no target: Search waits for the helper", search.open && Clipboard.pendingPaste !== null && Clipboard.pendingPaste.target === "");
                    owned(ids[2]);
                    check("no target: copied only, then Search closes", !search.open && Clipboard.lastPaste === "copied only" && Clipboard.pendingPaste === null);
                    search.toggleClipboard();
                    Clipboard.watchTarget("");
                    search.clipPaste(search.selectedClip(), false);
                    owned("");
                    check("no target, refused: Search stays and says so", search.open && Clipboard.lastPaste === "not copied" && search.clipNotice === "The item could not be copied");

                    // The target closed while Search was open (a new window may take its address): the choice only copies.
                    Clipboard.watchTarget(root.target);
                    Compositor.windowClosed(root.target);
                    search.selected = 0;
                    search.clipPaste(search.selectedClip(), false);
                    check("a target closed before the choice is never pasted into", Clipboard.pendingPaste !== null && Clipboard.pendingPaste.target === "");
                    owned(ids[2]);
                    check("a target closed before the choice: copied only", !search.open && Clipboard.lastPaste === "copied only");

                    // A target: kept with the paste; Search waits for the helper.
                    choosePaste();
                    check("the target is kept as lower-case hex, with the paste", Clipboard.pasteTarget === root.target && Clipboard.pendingPaste.target === root.target && Clipboard.pendingPaste.plain === false);
                    owned(ids[1]);
                    check("the helper owns another item: nothing yet", search.open && !Clipboard.pendingPaste.copied);
                    // Esc (or a click outside) before the helper confirms: the paste ends with Search.
                    search.hide();
                    check("closing Search drops an unconfirmed paste", Clipboard.pendingPaste === null && Clipboard.lastPaste === "Search closed");
                    owned(ids[2]);
                    check("a late confirmation pastes nothing", !search.open && Clipboard.pendingPaste === null && Clipboard.lastPaste === "Search closed" && !Clipboard.pasteWatch.running);

                    // This shell's lock while a confirmed paste waits for the target.
                    pasteCopied();
                    check("the helper owns the item: Search closes, the paste waits", !search.open && Clipboard.pendingPaste !== null && Clipboard.pendingPaste.copied && Clipboard.pasteWatch.running);
                    SessionState.locked = true;
                }, 4 * Logic.PASTE_POLL_MS], [() => {
                    check("this shell's lock drops the paste (" + Clipboard.lastPaste + ")", Clipboard.pendingPaste === null && Clipboard.lastPaste === "locked");
                    SessionState.locked = false;
                    // Another program's lock (the helper's notifier).
                    pasteCopied();
                    Clipboard.handle(Logic.line(["L", "1"]));
                }, 4 * Logic.PASTE_POLL_MS], [() => {
                    check("another program's lock drops the paste (" + Clipboard.lastPaste + ")", Clipboard.pendingPaste === null && Clipboard.lastPaste === "locked");
                    Clipboard.handle(Logic.line(["L", "0"]));
                    // A full-attention surface opens before the target is back.
                    pasteCopied();
                    FocusReturn.opened("test-surface");
                }, 4 * Logic.PASTE_POLL_MS], [() => {
                    check("another surface drops the paste (" + Clipboard.lastPaste + ")", Clipboard.pendingPaste === null && Clipboard.lastPaste === "another surface opened");
                    FocusReturn.closed("test-surface", false);
                    // The target closes (its address could be reused); another window closing changes nothing.
                    pasteCopied();
                    Compositor.windowClosed("abcdef13");
                    check("another window closing changes nothing", Clipboard.pendingPaste !== null && !Clipboard.pendingPaste.closed);
                    Compositor.windowClosed(root.target);
                }, 4 * Logic.PASTE_POLL_MS], [() => {
                    check("the target closing drops the paste (" + Clipboard.lastPaste + ")", Clipboard.pendingPaste === null && Clipboard.lastPaste === "the window closed");
                    // Search opens again while a paste waits: the paste is dropped.
                    pasteCopied();
                    search.show("");
                    check("Search opening again drops the paste", Clipboard.pendingPaste === null && Clipboard.lastPaste === "Search opened again");
                    search.hide();
                    // The paste keeps its own target: a live pasteTarget that differs changes nothing it checks.
                    pasteCopied();
                    Clipboard.pasteTarget = "11111111";
                    check("a check reads the paste's own target", Logic.pasteStep(Clipboard.pasteState(Clipboard.pendingPaste, "0x" + root.target)) === "send" && Logic.pasteStep(Clipboard.pasteState(Clipboard.pendingPaste, "0x11111111")) === "wait");
                    Compositor.windowClosed(root.target);
                }, 4 * Logic.PASTE_POLL_MS], [() => {
                    check("the paste's own target closing drops it, whatever pasteTarget says (" + Clipboard.lastPaste + ")", Clipboard.pendingPaste === null && Clipboard.lastPaste === "the window closed");
                    // Another app takes the clipboard (the helper's empty A) while the paste waits: Ctrl+V would paste its item.
                    pasteCopied();
                    owned("");
                }, 4 * Logic.PASTE_POLL_MS], [() => {
                    check("the clipboard taken by another app drops the paste (" + Clipboard.lastPaste + ")", Clipboard.pendingPaste === null && Clipboard.lastPaste === "the clipboard changed");
                    // Return, then Copy on another row before the helper answers: the paste is dropped, the copy goes on.
                    choosePaste();
                    search.selected = 1;
                    search.clipCopy(search.selectedClip());
                    check("a Copy right after Return drops the paste", Clipboard.pendingPaste === null && Clipboard.lastPaste === "another item copied" && Clipboard.pendingCopy === root.ids[1]);
                    owned(root.ids[2]);
                    check("the late confirmation of the paste pastes nothing", search.open && Clipboard.pendingPaste === null && !Clipboard.pasteWatch.running);
                    owned(root.ids[1]);
                    check("the copy is confirmed", search.open && search.clipCopiedKey === "clip:" + root.ids[1]);
                    search.hide();
                    // Nothing happens: the deadline drops the paste (the target never became active here).
                    pasteCopied();
                }, Logic.PASTE_WAIT_MS + 6 * Logic.PASTE_POLL_MS], [() => {
                    check("the 1 s deadline drops the paste (" + Clipboard.lastPaste + ")", Clipboard.pendingPaste === null && Clipboard.lastPaste === "the window did not come back" && !Clipboard.pasteWatch.running);
                    // The helper never answers a paste: Search stays open and says so.
                    choosePaste();
                }, Logic.PASTE_WAIT_MS + 6 * Logic.PASTE_POLL_MS], [() => {
                    check("an unanswered paste: Search stays and says so (" + Clipboard.lastPaste + ")", search.open && Clipboard.pendingPaste === null && Clipboard.lastPaste === "not copied in time" && search.clipNotice === "The item could not be copied");
                    Clipboard.handle(Logic.line(["L", "1"]));
                    check("the helper's lock closes Search", !search.open);
                    search.released(); // the panel's fade-out ended (U9)
                    search.toggleClipboard();
                    check("locked by another program: Super+Ctrl+V opens nothing", !search.open && !search.clipboardView);
                    Clipboard.handle(Logic.line(["L", "0"]));
                    search.toggleClipboard();
                    check("unlocked: the view opens again", search.open && search.clipboardView);
                    search.hide();
                }, 0]];
    }

    function finish(): void {
        if (failures.length === 0) {
            console.log("search-clipboard: PASS");
            Qt.exit(0);
        } else {
            console.log("search-clipboard: FAIL " + failures.join(", "));
            Qt.exit(1);
        }
    }

    // Runs the scenario: a wait of -1 waits for Allow's setting to apply and be read back (at most 5 s).
    Timer {
        id: runner
        interval: 200
        running: true
        onTriggered: {
            if (root.script.length === 0)
                root.script = root.steps();
            // Allow writes grassfield.json; the service decides once the file is read back (it never acts on the defaults).
            if (root.next > 0 && root.script[root.next - 1][1] === -1 && !(Clipboard.enabled && Clipboard.initialized)) {
                root.waitedForSetting += interval;
                if (root.waitedForSetting > 5000) {
                    root.check("Allow applied the setting within 5 s", false);
                    root.finish();
                    return;
                }
                interval = 50;
                restart();
                return;
            }
            if (root.next >= root.script.length) {
                root.finish();
                return;
            }
            const step = root.script[root.next++];
            step[0]();
            interval = Math.max(1, step[1]);
            restart();
        }
    }

    property int waitedForSetting: 0
}
