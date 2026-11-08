import QtQuick
import QtTest
import "../../shell/services/ClipboardLogic.js" as Logic
import "../../shell/search/ClipboardView.js" as View

// The clipboard history on the shell side (ADR-0034): when a copy may be recorded, which display the helper is given, the
// helper's lines and items, when the paste may be sent and the Lua function sent for it. Pure logic of
// shell/services/ClipboardLogic.js; the helper itself is tests/unit/clipboard-helper and tests/shell/clipboard_helper.sh.
TestCase {
    name: "Clipboard"

    readonly property string us: "\x1f"

    function readRepo(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        return xhr.responseText;
    }

    function open(over) {
        const s = {
            enabled: true,
            locked: false,
            helperLocked: false,
            authorizing: false,
            authorizingGrace: false,
            activeClass: "org.gnome.TextEditor"
        };
        for (const k in over)
            s[k] = over[k];
        return s;
    }

    function test_recordOnlyWhenEverythingAllows() {
        verify(Logic.mayRecord(open({})));
        verify(!Logic.mayRecord(open({enabled: false})), "the history off");
        verify(!Logic.mayRecord(open({locked: true})), "the shell's lock (or its locking phase)");
        verify(!Logic.mayRecord(open({helperLocked: true})), "a lock by another program (the compositor's notifier)");
        verify(!Logic.mayRecord(open({authorizing: true})), "an authorization request open");
        verify(!Logic.mayRecord(open({authorizingGrace: true})), "an authorization request ended less than 2 s ago");
        compare(Logic.AUTH_GRACE_MS, 2000);
        verify(!Logic.mayRecord(open({activeClass: "1Password"})), "a protected password manager in front");
        verify(!Logic.mayRecord(open({activeClass: "Bitwarden"})));
        verify(!Logic.mayRecord(open({activeClass: "chrome-nngceckbapebfimnlniiiahkandclblb-Default"})));
        verify(Logic.mayRecord(open({activeClass: ""})), "no window in front");
        // Anything that is not exactly the open value is a refusal (fail closed).
        verify(!Logic.mayRecord(open({locked: undefined})));
        verify(!Logic.mayRecord(open({authorizingGrace: undefined})));
        verify(!Logic.mayRecord(open({enabled: "true"})));
        verify(!Logic.mayRecord(null));
    }

    function test_protectedClassesAreThoseOfPrivacyLua() {
        const lua = readRepo("config/hypr/grassfield/privacy.lua");
        const block = lua.slice(lua.indexOf("local BUILTIN = {"), lua.indexOf("}\n", lua.indexOf("local BUILTIN = {")) + 1);
        const found = [];
        const re = /class = "([^"]+)"/g;
        let m;
        while ((m = re.exec(block)) !== null)
            found.push(m[1].replace(/\\(.)/g, "$1")); // the Lua string's value: "\\." is "\."
        compare(found.join(" "), Logic.PROTECTED_CLASSES.join(" "));
    }

    // R7-SEC-03: the list is Omarchy 4.5.0's (1Password 8.12's reverse-DNS app id, Bitwarden either case, the Bitwarden
    // extension in any browser and profile), and still covers every class Omarchy 4.0.6's list matched.
    function test_protectedClassesFollowOmarchy45() {
        for (const cls of ["1Password", "1password", "com.onepassword.OnePassword", "Bitwarden", "bitwarden",
                           "chrome-nngceckbapebfimnlniiiahkandclblb-Default", "chrome-nngceckbapebfimnlniiiahkandclblb-Profile_1",
                           "brave-nngceckbapebfimnlniiiahkandclblb-Default", "msedge-nngceckbapebfimnlniiiahkandclblb-Default"]) {
            verify(Logic.isProtectedClass(cls), cls + " is a protected password manager");
            verify(!Logic.mayRecord(open({activeClass: cls})), "no copy is recorded while " + cls + " is in front");
        }
        for (const cls of ["org.gnome.TextEditor", "com.onepassword.OnePasswordX", "xcom.onepassword.OnePassword", "1Passwords",
                           "Bitwardens", "firefox", "chromium"])
            verify(!Logic.isProtectedClass(cls), cls + " is not a password manager");
    }

    function test_terminalTestIsForwardingLuas() {
        const lua = readRepo("config/hypr/grassfield/forwarding.lua");
        const line = lua.split("\n").find(l => l.startsWith("local TERMINAL_CLASSES = {"));
        const classes = [];
        const re = /"([^"]+)"/g;
        let m;
        while ((m = re.exec(line)) !== null)
            classes.push(m[1]);
        compare(classes.join(" "), Logic.TERMINAL_CLASSES.join(" "));
        verify(lua.indexOf("class:find(\"^org%.omarchy%.\")") >= 0 && lua.indexOf("class:find(\"^tui%.\")") >= 0, "the prefixes are forwarding.lua's");
        compare(Logic.TERMINAL_PREFIXES.join(" "), "org.omarchy. tui.");
        verify(Logic.isTerminalClass("Alacritty"));
        verify(Logic.isTerminalClass("org.omarchy.terminal"));
        verify(Logic.isTerminalClass("TUI.float"));
        verify(!Logic.isTerminalClass("org.gnome.TextEditor"));
        verify(!Logic.isTerminalClass("kittyish"));
    }

    function test_displayIsOnlyTheOneGiven() {
        // A dev session: only GRASSFIELD_CLIPBOARD_DISPLAY, absolute; never the session's WAYLAND_DISPLAY.
        compare(Logic.displayPath(true, "", "/run/user/1000", "wayland-1"), "");
        compare(Logic.displayPath(true, "wayland-2", "/run/user/1000", "wayland-1"), "");
        compare(Logic.displayPath(true, "/run/user/1000/wayland-2", "/run/user/1000", "wayland-1"), "/run/user/1000/wayland-2");
        // A real session: the session's socket.
        compare(Logic.displayPath(false, "/tmp/x", "/run/user/1000", "wayland-1"), "/run/user/1000/wayland-1");
        compare(Logic.displayPath(false, "", "/run/user/1000/", "/abs/wayland-9"), "/abs/wayland-9");
        compare(Logic.displayPath(false, "", "", "wayland-1"), "");
        compare(Logic.displayPath(false, "", "relative", "wayland-1"), "");
        compare(Logic.displayPath(false, "", "/run/user/1000", "../wayland-1"), "");
        compare(Logic.runtimeDir("/run/user/1000", "/run/user/1000/wayland-1"), "/run/user/1000/grassfield/clipboard-wayland-1");
        compare(Logic.runtimeDir("/run/user/1000", "/tmp/a b"), "/run/user/1000/grassfield/clipboard-a_b");
        compare(Logic.runtimeDir("", "/run/user/1000/wayland-1"), "");
    }

    // The clear times given to the helper (--cleared-at, CH <ms>): whole milliseconds, digits only, 0 for anything else.
    function test_clearTimeArg() {
        compare(Logic.clearTimeArg(1792832460000), "1792832460000");
        compare(Logic.clearTimeArg(5000.7), "5000");
        compare(Logic.clearTimeArg(0), "0");
        compare(Logic.clearTimeArg(-5), "0");
        compare(Logic.clearTimeArg(NaN), "0");
        compare(Logic.clearTimeArg("x"), "0");
        compare(Logic.clearTimeArg(1e21), "0", "never 1e+21");
        compare(Logic.clearTimeArg(undefined), "0");
    }

    function test_retention() {
        compare(Logic.retentionMs("30m"), 1800000);
        compare(Logic.retentionMs("8h"), 28800000);
        compare(Logic.retentionMs("7d"), 604800000);
        compare(Logic.retentionMs("forever"), 28800000);
        const schema = JSON.parse(readRepo("config/schema/grassfield.schema.json"));
        const r = schema.properties.search.properties.clipboard.properties.retention;
        compare(r.enum.join(","), "30m,8h,7d");
        compare(r["default"], "8h");
    }

    function test_linesAndItems() {
        const raw = "a\\b\nc\rd" + us + "e";
        compare(Logic.unescapeField(Logic.escapeField(raw)), raw);
        verify(Logic.line(["Q", "1", raw]).split(us).length === 3);
        const f = Logic.parseLine(["I", "00000000000000a1", "text", "text/plain,text/html", "23", "100", "0", "1", "0",
            Logic.escapeField("Hello\nworld"), "Hello", "", "org.example.App"].join(us));
        const item = Logic.parseItem(f);
        compare(item.id, "00000000000000a1");
        compare(item.title, "Hello\nworld");
        compare(item.mimes.length, 2);
        verify(item.formatted);
        verify(!item.pinned);
        compare(Logic.parseItem(["I", "../../etc", "text"]), null);
        let items = [];
        items = Logic.upsert(items, {id: "a", pinned: false, pinnedAt: 0, copiedAt: 1});
        items = Logic.upsert(items, {id: "b", pinned: false, pinnedAt: 0, copiedAt: 3});
        items = Logic.upsert(items, {id: "c", pinned: true, pinnedAt: 5, copiedAt: 0});
        items = Logic.upsert(items, {id: "a", pinned: false, pinnedAt: 0, copiedAt: 9});
        compare(items.map(i => i.id).join(""), "cab", "pins first, then newest copy first; an update moves the item");
        compare(Logic.removeId(items, "a").map(i => i.id).join(""), "cb");
    }

    function test_pasteOnlyIntoTheRememberedWindow() {
        const ok = {
            locked: false,
            helperLocked: false,
            rememberedAddress: "0x55d0c0ffee",
            activeAddress: "0x55d0c0ffee",
            closedSinceOpen: false,
            otherSurfaceOpen: false,
            ownsItem: true,
            expired: false
        };
        verify(Logic.mayPaste(ok));
        const refuse = {
            locked: true,
            helperLocked: true,
            activeAddress: "0x1",
            closedSinceOpen: true,
            otherSurfaceOpen: true,
            ownsItem: false,
            expired: true
        };
        for (const k in refuse) {
            const s = Object.assign({}, ok);
            s[k] = refuse[k];
            verify(!Logic.mayPaste(s), k);
        }
        verify(!Logic.mayPaste(Object.assign({}, ok, {rememberedAddress: "", activeAddress: ""})), "no window was active at open");
        verify(Logic.mayPaste(Object.assign({}, ok, {rememberedAddress: "55d0c0ffee", activeAddress: "0x55D0C0FFEE"})),
            "the same window whichever form its address takes");
        verify(!Logic.mayPaste(Object.assign({}, ok, {expired: undefined})), "no deadline state: no paste");
    }

    // Each check of a waiting paste: send only into the remembered window; a lock, the target closing or another surface
    // opening drops it at once, whatever window is active; otherwise it waits until the deadline.
    function test_pasteStep() {
        const ok = {
            locked: false,
            helperLocked: false,
            rememberedAddress: "55d0c0ffee",
            activeAddress: "0x55d0c0ffee",
            closedSinceOpen: false,
            otherSurfaceOpen: false,
            ownsItem: true,
            expired: false
        };
        compare(Logic.pasteStep(ok), "send");
        const at = changes => Logic.pasteStep(Object.assign({}, ok, changes));
        compare(at({locked: true}), "locked", "this shell's lock, the target active");
        compare(at({helperLocked: true}), "locked", "another program's lock, the target active");
        compare(at({ownsItem: false}), "the clipboard changed", "a Copy since, or another app took the clipboard");
        compare(at({ownsItem: undefined}), "the clipboard changed");
        compare(at({closedSinceOpen: true}), "the window closed");
        compare(at({otherSurfaceOpen: true}), "another surface opened", "the target active behind a surface");
        compare(at({expired: true}), "the window did not come back", "the target came back too late");
        compare(at({activeAddress: "0x1"}), "wait", "another window active: wait for the target");
        compare(at({activeAddress: ""}), "wait");
        compare(at({activeAddress: "0x1", expired: true}), "the window did not come back");
        compare(at({locked: true, closedSinceOpen: true, otherSurfaceOpen: true}), "locked", "a lock is named first");
        compare(Logic.pasteStep(null), "locked");
    }

    function test_pasteRequest() {
        compare(Logic.pasteRequest("0x1; os.exit()"), "");
        compare(Logic.pasteRequest(""), "");
        compare(Logic.pasteRequest("55d0c0ffee"), Logic.pasteRequest("0x55D0C0FFEE"), "one request whichever form the address takes");
        const r = Logic.pasteRequest("0x55d0c0ffee");
        verify(r.startsWith("function() local w = hl.get_active_window(); if not w or (string.lower(tostring(w.address or \"\")):gsub(\"^0x\", \"\")) ~= \"55d0c0ffee\" then return end;"),
            "the window is checked first, in the same call, on its address without 0x");
        // The key down and the key up both go to the address; the up's timer is armed first, in the same function, and checks
        // nothing.
        const check = r.indexOf("get_active_window");
        const timer = r.indexOf("hl.timer(function()");
        const up = r.indexOf("state = \"up\", window = \"address:0x55d0c0ffee\"");
        const down = r.indexOf("state = \"down\", window = \"address:0x55d0c0ffee\"");
        verify(check > 0 && timer > check && up > timer && down > up, "check, then the key up's timer, then the key down");
        compare(r.slice(timer).indexOf("get_active_window"), -1, "the key up never checks the active window again");
        verify(r.indexOf("mods = terminal and \"CTRL SHIFT\" or \"CTRL\"") > 0);
        verify(r.indexOf("\"org%.omarchy%.\"") > 0, "the Lua pattern escapes the prefixes' dots");
    }

    // ---- The Clipboard view (Search) ----

    function test_viewShowsTheHelpersOrderAndItsMatches() {
        const items = [{id: "p1", pinned: true}, {id: "h1"}, {id: "h2"}, {id: "h3"}];
        compare(View.visible(items, null).map(i => i.id).join(" "), "p1 h1 h2 h3", "an empty query shows every item, pins first");
        compare(View.visible(items, ["h3", "p1"]).map(i => i.id).join(" "), "p1 h3", "a query keeps the helper's order");
        compare(View.visible(items, []).length, 0);
        compare(View.visible(undefined, null).length, 0);
    }

    function test_rowKinds() {
        compare(View.kindKey({kind: "text", formatted: false}), "text");
        compare(View.kindKey({kind: "text", formatted: true}), "formatted");
        compare(View.kindKey({kind: "image"}), "image");
        compare(View.kindKey({kind: "files", files: 1}), "files");
        compare(View.kindKey({kind: "files", files: 3}), "items");
        compare(View.imageFormat({mimes: ["image/png"]}), "PNG");
        compare(View.imageFormat({mimes: ["image/jpeg"]}), "JPEG");
        compare(View.imageFormat({mimes: ["image/webp"]}), "WebP");
        compare(View.imageFormat({mimes: []}), "");
        verify(View.hasPlainVariant({kind: "text", formatted: true}));
        verify(!View.hasPlainVariant({kind: "text", formatted: false}));
        verify(!View.hasPlainVariant({kind: "image", formatted: true}));
    }

    function test_keysOfTheView() {
        const K = View.KEY;
        compare(View.keyAction(K.ret, 0, false, false), "paste");
        compare(View.keyAction(K.enter, 0, true, false), "paste");
        compare(View.keyAction(K.ret, Qt.ShiftModifier, false, false), "pastePlain");
        compare(View.keyAction(K.ret, Qt.ControlModifier, false, false), "");
        compare(View.keyAction(K.c, Qt.ControlModifier, false, false), "copy");
        compare(View.keyAction(K.c, Qt.ControlModifier, false, true), "", "a selected query text is the field's to copy");
        compare(View.keyAction(K.p, Qt.ControlModifier, false, false), "pin");
        compare(View.keyAction(K.menu, 0, false, false), "menu");
        compare(View.keyAction(K.f10, Qt.ShiftModifier, false, false), "menu");
        compare(View.keyAction(K.f10, 0, false, false), "");
        compare(View.keyAction(K.backspace, Qt.ControlModifier, true, false), "delete");
        compare(View.keyAction(K.backspace, Qt.ControlModifier, false, false), "", "Ctrl+Backspace edits a query");
        compare(View.keyAction(K.backspace, 0, true, false), "leave", "Backspace in the empty field leaves the view");
        compare(View.keyAction(K.backspace, 0, false, false), "");
        compare(View.keyAction(K.space, 0, true, false), "preview");
        compare(View.keyAction(K.space, 0, false, false), "", "Space types into a query");
        compare(View.keyAction(K.y, Qt.ControlModifier, false, false), "preview");
        compare(View.keyAction(K.up, 0, false, false), "up");
        compare(View.keyAction(K.down, 0, false, false), "down");
        compare(View.keyAction(K.escape, 0, false, false), "escape");
        compare(View.keyAction(K.tab, 0, true, false), "more");
        compare(View.keyAction(0x41, 0, true, false), "", "a letter types");
        // The constants are Qt's.
        compare(K.ret, Qt.Key_Return);
        compare(K.backspace, Qt.Key_Backspace);
        compare(K.menu, Qt.Key_Menu);
        compare(K.f10, Qt.Key_F10);
        compare(View.CTRL, Qt.ControlModifier);
        compare(View.META, Qt.MetaModifier);
        verify(View.opensView(Qt.Key_4, Qt.ControlModifier), "⌘4 (Super+4 forwarded as Ctrl+4)");
        verify(View.opensView(Qt.Key_4, Qt.MetaModifier));
        verify(!View.opensView(Qt.Key_4, 0), "a typed 4");
        // French AZERTY: the forwarded 4 key types an apostrophe; its place (scan code 13) still opens the view.
        verify(View.opensView(Qt.Key_Apostrophe, Qt.ControlModifier, 13), "⌘4 on AZERTY");
        verify(View.opensView(Qt.Key_4, Qt.ControlModifier, 13));
        verify(!View.opensView(Qt.Key_Apostrophe, Qt.ControlModifier, 48), "Ctrl+apostrophe elsewhere on the keyboard");
        verify(!View.opensView(Qt.Key_Apostrophe, 0, 13), "a typed apostrophe");
        verify(!View.opensView(Qt.Key_Apostrophe, Qt.ControlModifier | Qt.ShiftModifier, 13));
    }

    function test_selectionAfterDelete() {
        compare(View.selectionAfterRemove(3, 0), 0, "the next row takes the place");
        compare(View.selectionAfterRemove(3, 2), 1, "the last row: the new last one");
        compare(View.selectionAfterRemove(1, 0), -1, "nothing left");
    }

    function test_rowMenu() {
        compare(View.menuIds({kind: "text", formatted: true, pinned: false}).join(" "), "paste pastePlain copy - pin - delete");
        compare(View.menuIds({kind: "image", pinned: true}).join(" "), "paste copy - unpin - delete");
        compare(View.menuIds(null).length, 0);
    }
}
