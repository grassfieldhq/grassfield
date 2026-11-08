import QtQuick
import QtTest
import "../../shell/dock/DockModel.js" as DockModel

TestCase {
    name: "DockModel"

    readonly property var entries: ({
        "foot": {id: "foot", name: "Foot", icon: "foot"},
        "chromium": {id: "chromium", name: "Chromium", icon: "chromium"},
        "org.gnome.Nautilus": {id: "org.gnome.Nautilus", name: "Files", icon: "nautilus"}
    })

    function lookup(id) {
        // Case-insensitive like the heuristic lookup of desktop entries.
        for (const key in entries) {
            if (key.toLowerCase() === id.toLowerCase())
                return entries[key];
        }
        return null;
    }

    // ADR-0036 D66: in full screen the Dock hides and comes back at its edge, over the window.
    function test_hidesInFullScreen() {
        verify(!DockModel.hides(false, true, false, false), "setting off, the Dock's output, settled, no full screen");
        verify(DockModel.hides(true, true, false, false), "the setting");
        verify(DockModel.hides(false, false, false, false), "an output without the Dock");
        verify(DockModel.hides(false, true, true, false), "a Dock that just moved here");
        verify(DockModel.hides(false, true, false, true), "a full-screen window or a Split View Desktop");
        compare(DockModel.hides(0, 1, 0, undefined), false, "a boolean");
        verify(DockModel.overlayLayer(true));
        verify(!DockModel.overlayLayer(false));
        compare(DockModel.overlayLayer(undefined), false, "a boolean");
    }

    function test_pinnedKeepOrderAndSkipUnknown() {
        const list = DockModel.merge(["chromium", "ghost", "foot"], [], lookup);
        compare(list.map(i => i.key).join(","), "chromium,foot");
        verify(list.every(i => i.pinned && i.windows.length === 0));
    }

    function test_runningPinnedAppAttachesWindows() {
        const list = DockModel.merge(["foot"], [{appId: "foot", ref: "w1"}, {appId: "Foot", ref: "w2"}], lookup);
        compare(list.length, 1);
        compare(list[0].windows.join(","), "w1,w2");
        verify(list[0].pinned);
    }

    function test_runningUnpinnedAppsAppendedAfterPinned() {
        const list = DockModel.merge(["foot"], [{appId: "chromium", ref: "c"}, {appId: "mystery", ref: "m"}], lookup);
        compare(list.map(i => i.key).join(","), "foot,chromium,mystery");
        verify(!list[1].pinned);
        compare(list[2].name, "mystery");
        compare(list[2].entry, null);
    }

    function test_emptyAppIdIgnoredAndPinsDeduplicated() {
        const list = DockModel.merge(["foot", "FOOT", "foot"], [{appId: "", ref: "x"}], lookup);
        compare(list.length, 1);
        compare(list[0].windows.length, 0);
    }

    // `dock reopen <id>` (ADR-0038 AD34): the windows of the app's tile, the fixed Files tile included; none for an app the
    // Dock has no tile for, or an empty id.
    function test_windowsOfAnApp() {
        const split = DockModel.splitFiles(DockModel.merge(["chromium"], [{appId: "foot", ref: "f1"}, {appId: "org.grassfield.Files", ref: "x1"}], lookup), lookup);
        const items = DockModel.withFixed(split.files, split.rest);
        compare(DockModel.windowsOf(items, "foot").join(","), "f1");
        compare(DockModel.windowsOf(items, "Foot.desktop").join(","), "f1");
        compare(DockModel.windowsOf(items, "org.grassfield.Files").join(","), "x1");
        compare(DockModel.windowsOf(items, "ORG.grassfield.files.desktop").join(","), "x1"); // without case, as every id
        compare(DockModel.windowsOf(items, "Foot.DESKTOP").join(","), "f1"); // the suffix too (review of 91dcb63)
        compare(DockModel.windowsOf(items, "org.grassfield.Files.Desktop").join(","), "x1");
        compare(DockModel.windowsOf(items, "chromium").length, 0); // pinned, not running
        compare(DockModel.windowsOf(items, "ghost").length, 0);
        compare(DockModel.windowsOf(items, "").length, 0);
        compare(DockModel.windowsOf(items, "grid").length, 0); // the Apps tile's key is no app
    }

    function test_tailIsSeparatorThenTrash() {
        const list = DockModel.withTail(DockModel.merge(["foot"], [], lookup));
        compare(list.map(i => i.kind).join(","), "app,separator,trash");
        compare(DockModel.withTail([]).map(i => i.kind).join(","), "separator,trash");
    }

    function test_pinUnpin() {
        compare(DockModel.pin(["a"], "b").join(","), "a,b");
        compare(DockModel.pin(["a"], "a").join(","), "a");
        compare(DockModel.pin(undefined, "a").join(","), "a");
        compare(DockModel.unpin(["a", "b"], "a").join(","), "b");
        // Pin written as an alias still unpins by resolved key.
        compare(DockModel.unpinKey(["FOOT", "chromium"], "foot", lookup).join(","), "chromium");
    }

    // ADR-0018: the app's own count (LauncherEntry) is authoritative for its tile while it is known.
    function test_launcherBadgeOverridesNotifications() {
        const item = {kind: "app", key: "chromium", name: "Chromium", entry: {id: "chromium"}};
        const history = [{appName: "Chromium"}, {appName: "chromium"}, {appName: "Chromium"}];
        compare(DockModel.tileBadge(history, item, {}), 3, "no state: the notification count");
        compare(DockModel.tileBadge(history, item, undefined), 3);
        compare(DockModel.tileBadge(history, item, {chromium: {count: 7, urgent: false}}), 7);
        compare(DockModel.tileBadge(history, item, {chromium: {count: 0, urgent: false}}), 0, "count 0 hides the badge");
        compare(DockModel.tileBadge(history, item, {chromium: {progress: 0.5, urgent: false}}), 3, "no count of its own: notifications");
        compare(DockModel.tileBadge(history, item, {other: {count: 9, urgent: false}}), 3, "another app's count is not used");
        compare(DockModel.tileBadge(history, {kind: "trash"}, {trash: {count: 4}}), 0);
        // Matched on the tile key or the desktop entry id, whatever the case.
        compare(DockModel.tileBadge([], {kind: "app", key: "Chromium", entry: {id: "Chromium"}}, {chromium: {count: 2, urgent: false}}), 2);
        compare(DockModel.tileBadge([], {kind: "app", key: "ChromiumWin", entry: {id: "chromium"}}, {chromium: {count: 2, urgent: false}}), 2);
        compare(DockModel.tileBadge([], {kind: "files", key: "files"}, {files: {count: 2}}), 0, "only app tiles");
    }

    // ADR-0033 U18: the shell sets Grassfield Settings' count itself (Software Update's releases), kept over what the app set.
    function test_theShellsOwnCountForSettings() {
        const settings = {kind: "app", key: "org.grassfield.Settings", entry: {id: "org.grassfield.Settings"}};
        const id = "org.grassfield.settings";
        compare(DockModel.tileBadge([{appName: "Settings"}], settings, DockModel.withCount({}, id, 2)), 2);
        const launcher = {chromium: {count: 3, urgent: false}, "org.grassfield.settings": {progress: 0.5, urgent: true}};
        const merged = DockModel.withCount(launcher, id, 1);
        compare(merged[id], {progress: 0.5, urgent: true, count: 1}, "the app's own progress and urgency stay");
        compare(merged.chromium.count, 3, "other apps untouched");
        compare(launcher[id].count, undefined, "the launcher state itself is not changed");
        verify(DockModel.withCount(launcher, id, 0) === launcher, "0: nothing set, the state as it is");
        verify(DockModel.isApp(settings, id));
        verify(DockModel.isApp({kind: "app", key: "x", entry: {id: "ORG.GRASSFIELD.SETTINGS"}}, id));
        verify(!DockModel.isApp({kind: "app", key: "chromium", entry: {id: "chromium"}}, id));
        verify(!DockModel.isApp({kind: "trash", key: "org.grassfield.settings"}, id));
        verify(!DockModel.isApp(null, id));
    }

    function test_launcherProgress() {
        const item = {kind: "app", key: "firefox", entry: {id: "firefox"}};
        compare(DockModel.tileProgress({}, item), -1);
        compare(DockModel.tileProgress(undefined, item), -1);
        compare(DockModel.tileProgress({firefox: {urgent: false}}, item), -1);
        compare(DockModel.tileProgress({firefox: {progress: 0, urgent: false}}, item), 0);
        compare(DockModel.tileProgress({firefox: {progress: 0.25, urgent: false}}, item), 0.25);
        compare(DockModel.tileProgress({firefox: {progress: 1, urgent: false}}, item), 1);
        compare(DockModel.tileProgress({firefox: {progress: 2, urgent: false}}, item), -1, "out of range: no bar");
        compare(DockModel.tileProgress({firefox: {progress: 0.5}}, {kind: "trash"}), -1);
    }

    function test_badgeCounts() {
        const item = {kind: "app", key: "org.gnome.Nautilus", name: "Files"};
        const history = [{appName: "files"}, {appName: "Files"}, {appName: "org.gnome.nautilus"}, {appName: "Other"}];
        compare(DockModel.badgeCount(history, item), 3);
        compare(DockModel.badgeCount(history, {kind: "trash"}), 0);
        compare(DockModel.badgeCount(undefined, item), 0);
        compare(DockModel.badgeText(0), "");
        compare(DockModel.badgeText(7), "7");
        compare(DockModel.badgeText(120), "99+");
    }

    function test_recents() {
        compare(DockModel.pushRecent(["a", "b", "c"], "b", 3).join(","), "b,a,c");
        compare(DockModel.pushRecent(["a", "b", "c"], "d", 3).join(","), "d,a,b");
        const apps = DockModel.merge(["foot"], [{appId: "chromium", ref: "c"}], lookup);
        const out = DockModel.withRecents(apps, ["foot", "chromium", "ghost", "org.gnome.Nautilus"], lookup, 3);
        // macOS: the recent applications are their own section, after a divider.
        compare(out.map(i => i.kind === "separator" ? "|" : i.key).join(","), "foot,chromium,|,org.gnome.Nautilus");
        verify(out[2].divider === true);
        verify(out[3].recent === true && !out[3].pinned && out[3].windows.length === 0);
        compare(DockModel.withRecents(apps, ["org.gnome.Nautilus"], lookup, 0).length, 2);
        // No recent to show: no divider either.
        compare(DockModel.withRecents(apps, ["foot", "chromium"], lookup, 3).length, 2);
        // NoDisplay / hidden entries are never shown as recents.
        const listed = e => e.id !== "org.gnome.Nautilus";
        compare(DockModel.withRecents(apps, ["org.gnome.Nautilus"], lookup, 3, listed).length, 2);
    }

    // A fake Dock: the same logic as Dock.qml rebuild() (running set -> recents update -> write only when it differs).
    function simulate(runningSets, pinned, max, start) {
        let stored = start ? start.slice() : [];
        let previous = null;
        let writes = 0;
        const shown = [];
        for (const running of runningSets) {
            // Rebuilds repeat until the stored list stops changing (as onDockRecentChanged re-runs rebuild()).
            for (let pass = 0; pass < 6; pass++) {
                const next = DockModel.recentsAfter(stored, previous, running, pinned, max);
                previous = running;
                if (next.join(",") === stored.join(","))
                    continue;
                stored = next;
                writes++;
            }
            shown.push(stored.join(","));
        }
        return {writes: writes, stored: stored, shown: shown};
    }

    function test_recentsStayStableWithManyUnpinnedRunning() {
        // 0..8 unpinned running apps, repeated rebuilds with the same set: never a write, whatever the cap.
        for (let n = 0; n <= 8; n++) {
            const running = [];
            for (let i = 0; i < n; i++)
                running.push("app" + i);
            const r = simulate([running, running, running, running, running, running], [], 3, []);
            compare(r.writes, 0, n + " unpinned running apps: no write while none quit");
        }
    }

    function test_recentsWriteOncePerRealChange() {
        const four = ["a", "b", "c", "d"];
        // all four run for a while, then they quit one after the other: one write per quit (the cap of 3 holds)
        const r = simulate([four, four, ["b", "c", "d"], ["b", "c", "d"], ["c", "d"], ["d"], []], [], 3, []);
        compare(r.writes, 4);
        compare(r.stored.join(","), "d,c,b");
        // a re-run of the same sets writes nothing more
        const again = simulate([four, ["b", "c", "d"], ["b", "c", "d"], ["b", "c", "d"]], [], 3, []);
        compare(again.writes, 1);
        compare(again.stored.join(","), "a");
        // an app that the cap evicted while it is still running is not re-added (it shows as a running tile)
        const full = simulate([four, four, four], [], 3, ["x", "y", "z"]);
        compare(full.writes, 0);
        compare(full.stored.join(","), "x,y,z");
    }

    function test_recentsIgnorePinnedAndHandleShellRestart() {
        // a pinned app that quits is not a recent; neither is one pinned meanwhile
        compare(DockModel.recentsAfter([], ["a", "b"], ["b"], ["a"], 3).join(","), "");
        // the first rebuild (previous = null) has nothing to compare: no change
        compare(DockModel.recentsAfter(["x"], null, ["a", "b"], [], 3).join(","), "x");
        // newest first, no duplicates, cap
        compare(DockModel.recentsAfter(["x", "y"], ["a", "x"], [], [], 3).join(","), "x,a,y");
    }

    // A hidden entry (OnlyShowIn / NotShowIn) looks listed until the hidden list loads, then not: it must not count as an
    // app that quit and take a recent slot. Nothing is evaluated before the entries and the hidden list are loaded.
    function test_recentsWaitForHiddenListAndEntries() {
        let stored = ["x"];
        let previous = null;
        const rebuild = (ready, running) => {
            const step = DockModel.recentsStep(ready, stored, previous, running, [], 3);
            previous = step.previous;
            stored = step.recent;
        };
        rebuild(false, ["hidden", "foot"]);   // startup: entries / hidden list not loaded, the hidden app looks listed
        compare(previous, null);
        rebuild(false, ["foot"]);
        compare(stored.join(","), "x");
        rebuild(true, ["foot"]);              // loaded: the hidden app is excluded, the first ready step only records
        compare(stored.join(","), "x");
        compare(previous.join(","), "foot");
        rebuild(true, []);                    // a real quit afterwards is remembered
        compare(stored.join(","), "foot,x");
        // without the gate the same sequence takes a slot for the hidden app
        let naive = DockModel.recentsAfter(["x"], ["hidden", "foot"], ["foot"], [], 3);
        compare(naive.join(","), "hidden,x");
    }

    function items3() {
        return DockModel.withTail(DockModel.merge(["foot", "chromium"], [{appId: "org.gnome.Nautilus", ref: "n"}], lookup));
    }

    function test_reorderPinned() {
        const r = DockModel.reorder(items3(), 0, 1);
        verify(r.changed);
        compare(r.pinned.join(","), "chromium,foot");
        verify(!DockModel.reorder(items3(), 1, 1).changed);
    }

    function test_reorderUnpinnedBecomesPinnedOnlyBeforePinned() {
        const a = DockModel.reorder(items3(), 2, 0);
        compare(a.pinned.join(","), "org.gnome.Nautilus,foot,chromium");
        verify(a.changed);
        const b = DockModel.reorder(items3(), 2, 2);
        verify(!b.changed);
        compare(DockModel.reorder(items3(), 9, 0).changed, false);
    }

    function test_dropSlotAndDragOut() {
        compare(DockModel.dropSlot([30, 90, 150, 220], [0, 1, 2], 100), 1);
        compare(DockModel.dropSlot([30, 90, 150, 220], [0, 1, 2], 400), 2);
        // the divider of the recent applications is not a slot: positions count app tiles only
        compare(DockModel.dropSlot([30, 90, 120, 150, 220], [0, 1, 3], 125), 2);
        compare(DockModel.appIndices([{kind: "app"}, {kind: "app"}, {kind: "separator", divider: true}, {kind: "app"}, {kind: "separator"}, {kind: "trash"}]).join(","), "0,1,3");
        verify(DockModel.draggedOut(-70, 60));
        verify(!DockModel.draggedOut(-20, 60));
    }

    function test_commandsForFiles() {
        // %F: one command with every file; %U: URIs
        compare(JSON.stringify(DockModel.commandsForFiles(["gimp", "%F"], ["/a", "/b c"])), JSON.stringify([["gimp", "/a", "/b c"]]));
        compare(JSON.stringify(DockModel.commandsForFiles(["gimp", "%U"], ["/a", "/b c"])), JSON.stringify([["gimp", "file:///a", "file:///b%20c"]]));
        // %f: one launch per file (Desktop Entry spec)
        compare(JSON.stringify(DockModel.commandsForFiles(["viewer", "%f"], ["/a", "/b"])), JSON.stringify([["viewer", "/a"], ["viewer", "/b"]]));
        // embedded and other codes
        compare(JSON.stringify(DockModel.commandsForFiles(["a", "%i", "--open=%f", "100%%"], ["/a"])), JSON.stringify([["a", "--open=/a", "100%"]]));
        // no file field code: nothing is ever appended (a file dropped on `foot` must not become `foot /path`)
        compare(DockModel.commandsForFiles(["foot", "--x"], ["/a"]).length, 0);
        compare(DockModel.commandsForFiles(["foot", "--x", "%i", "%c"], ["/a"]).length, 0);
        compare(DockModel.commandsForFiles(["foot", "100%%"], ["/a"]).length, 0);
        compare(DockModel.commandsForFiles(["viewer", "%f"], []).length, 0);
    }

    readonly property string mimeText: [
        "G\t50:text/plain:*.txt", "G\t50:text/x-python:*.py", "G\t50:image/png:*.png", "G\t50:application/x-compressed-tar:*.tar.gz",
        "G\t50:application/gzip:*.gz", "G\t50:text/x-makefile:Makefile", "G\t50:image/jpeg:*.jpg:cs", "G\t50:text/markdown:*.md",
        "S\ttext/x-python text/plain", "S\tapplication/x-compressed-tar application/gzip", "A\ttext/x-markdown text/markdown",
        "E\tedit\ttext/plain;", "E\tview\timage/*;", "E\tgz\tapplication/gzip;", "E\tmd\ttext/x-markdown;", "E\tbare\t"
    ].join("\n")

    function test_dropAcceptance() {
        const data = DockModel.parseMimeData(mimeText);
        verify(data.ready);
        const open = (id, cmd) => ({id: id, command: cmd});
        // MimeType matches the type, its parents and aliases
        verify(DockModel.acceptsFiles(open("edit", ["edit", "%F"]), ["/x/a.txt"], data));
        verify(DockModel.acceptsFiles(open("edit", ["edit", "%f"]), ["/x/a.py"], data));
        verify(DockModel.acceptsFiles(open("edit", ["edit", "%u"]), ["/x/Makefile"], data));
        verify(DockModel.acceptsFiles(open("view", ["view", "%f"]), ["/x/a.PNG"], data));
        verify(DockModel.acceptsFiles(open("gz", ["gz", "%f"]), ["/x/a.tar.gz"], data));
        verify(DockModel.acceptsFiles(open("md", ["md", "%f"]), ["/x/a.md"], data));
        // wrong type, unknown type, every file must match
        verify(!DockModel.acceptsFiles(open("edit", ["edit", "%F"]), ["/x/a.png"], data));
        verify(!DockModel.acceptsFiles(open("edit", ["edit", "%F"]), ["/x/a.txt", "/x/a.png"], data));
        verify(!DockModel.acceptsFiles(open("edit", ["edit", "%F"]), ["/x/noextension"], data));
        // no file field code in Exec: refused whatever the MimeType (foot)
        verify(!DockModel.acceptsFiles(open("edit", ["edit", "--new"]), ["/x/a.txt"], data));
        // no MimeType (or an empty one): refused
        verify(!DockModel.acceptsFiles(open("foot", ["foot", "%F"]), ["/x/a.txt"], data));
        verify(!DockModel.acceptsFiles(open("bare", ["bare", "%F"]), ["/x/a.txt"], data));
        // no database yet / nothing dropped
        verify(!DockModel.acceptsFiles(open("edit", ["edit", "%F"]), ["/x/a.txt"], DockModel.parseMimeData("")));
        verify(!DockModel.acceptsFiles(open("edit", ["edit", "%F"]), [], data));
    }

    // Quickshell's DesktopEntry.command has the field codes stripped: the drop logic reads the raw execString.
    function test_execArgsKeepsFieldCodes() {
        compare(DockModel.execArgs("foot").join("|"), "foot");
        compare(DockModel.execArgs("viewer --open %U").join("|"), "viewer|--open|%U");
        compare(DockModel.execArgs("  env  A=1   viewer %f ").join("|"), "env|A=1|viewer|%f");
        compare(DockModel.execArgs('sh -c "echo \\"$@\\"" x %F').join("|"), 'sh|-c|echo "$@"|x|%F');
        compare(DockModel.execArgs("sh -c 'echo \"$@\" >> /tmp/log' gfdroptest %F").join("|"), 'sh|-c|echo "$@" >> /tmp/log|gfdroptest|%F');
        compare(DockModel.execArgs('"/opt/My App/run" %F').join("|"), "/opt/My App/run|%F");
        compare(DockModel.execArgs("a\\ b %f").join("|"), "a b|%f");
        compare(DockModel.execArgs('empty "" end').join("|"), "empty||end");
        compare(DockModel.execArgs("broken 'quote").length, 0);
        compare(DockModel.execArgs('broken "quote').length, 0);
        compare(DockModel.execArgs("").length, 0);
        // a real entry object: command stripped, execString raw
        const real = {id: "viewer", command: ["viewer", "--open"], execString: "viewer --open %U"};
        compare(DockModel.entryArgs(real).join("|"), "viewer|--open|%U");
        const data = DockModel.parseMimeData(mimeText);
        verify(DockModel.acceptsFiles({id: "edit", command: ["edit"], execString: "edit %F"}, ["/a/b.txt"], data));
        verify(!DockModel.acceptsFiles({id: "edit", command: ["edit"], execString: "edit"}, ["/a/b.txt"], data));
        compare(DockModel.commandsForFiles(DockModel.entryArgs({command: ["x"], execString: "x --file=%f"}), ["/a b/c.txt"]).map(c => c.join(" ")).join("|"), "x --file=/a b/c.txt");
        compare(DockModel.commandsForFiles(DockModel.entryArgs({command: ["x"], execString: "x %F"}), ["/a", "/b"]).length, 1);
    }

    // Folders and extensionless files: the name tells nothing, the real type is resolved at drop time (dock/file-types.sh).
    function test_dropResolvesRealTypes() {
        const data = DockModel.parseMimeData(mimeText + "\nE\tfiles\tinode/directory;\nE\tsh\ttext/x-shellscript;\nS\ttext/x-shellscript text/plain");
        const files = {id: "files", command: ["files", "%U"]};
        const edit = {id: "edit", command: ["edit", "%F"]};
        const dir = "/home/u/Photos", bare = "/home/u/run";
        // names alone decide nothing for a folder: refused strictly, "pending" while its type is looked up
        verify(!DockModel.acceptsFiles(files, [dir], data));
        compare(DockModel.dropVerdict(files, [dir], data, {}), "pending");
        compare(DockModel.dropVerdict({id: "files", command: ["files"]}, [dir], data, {}), "no");  // no field code
        compare(DockModel.dropVerdict({id: "bare", command: ["bare", "%f"]}, [dir], data, {}), "no");  // no MimeType
        compare(DockModel.unknownPaths([dir, bare, "/home/u/a.txt"], {[dir]: "inode/directory"}).join(","), bare + ",/home/u/a.txt");
        // resolved: a folder goes to the file manager only, a text file without extension to the editor
        const resolved = DockModel.parseResolved([dir, bare], "inode/directory\ntext/x-shellscript\n");
        compare(resolved[dir], "inode/directory");
        verify(DockModel.acceptsFiles(files, [dir], data, resolved));
        verify(!DockModel.acceptsFiles(edit, [dir], data, resolved));
        verify(DockModel.acceptsFiles(edit, [bare], data, resolved));  // text/x-shellscript is a text/plain subclass
        verify(!DockModel.acceptsFiles(files, [bare], data, resolved));
        // a mix with a known name still has to match every file; unknown ("-") stays refused
        verify(!DockModel.acceptsFiles(edit, [bare, "/home/u/a.png"], data, resolved));
        verify(!DockModel.acceptsFiles(files, [dir], data, DockModel.parseResolved([dir], "-\n")));
        verify(!DockModel.acceptsFiles(files, [dir], data, DockModel.parseResolved([dir], "")));
    }

    // An unpinned running app that quits joins the recents section: its tile glides there (no jump), the others close the gap.
    function test_layoutTransitionFollowsTheKeys() {
        const lk = id => entries[id];
        const before = DockModel.withTail(DockModel.merge(["foot"], [{appId: "chromium", ref: "c"}, {appId: "org.gnome.Nautilus", ref: "n"}], lk), []);
        // chromium quits: it is a recent app now (after a divider), nautilus keeps running
        const apps = DockModel.merge(["foot"], [{appId: "org.gnome.Nautilus", ref: "n"}], lk);
        const after = DockModel.withTail(DockModel.withRecents(apps, ["chromium"], lk, 3), []);
        const xs = (items, widths) => {
            const out = {};
            let x = 0;
            items.forEach(it => {
                out[DockModel.tileKey(it)] = x;
                x += (it.kind === "separator" ? 9 : 48) + 4;
            });
            return out;
        };
        const plan = DockModel.layoutTransition(xs(before), xs(after), 1);
        compare(DockModel.tileKey(before[1]), "app:chromium");
        compare(Object.keys(plan.slide).sort().join(","), "app:chromium,app:org.gnome.Nautilus,sep,trash");
        compare(plan.slide["app:chromium"], -65);  // it glides in from the left: its old place is 65 px left of the new one
        compare(plan.slide["app:org.gnome.Nautilus"], 52);
        compare(plan.enter.join(","), "sep:divider");
        // first build and unchanged layouts animate nothing
        compare(Object.keys(DockModel.layoutTransition({}, xs(after), 1).slide).length, 0);
        compare(DockModel.layoutTransition({}, xs(after), 1).enter.length, 0);
        const same = DockModel.layoutTransition(xs(after), xs(after), 1);
        compare(Object.keys(same.slide).length + same.enter.length, 0);
    }

    function test_bounceKeys() {
        const items = DockModel.merge(["foot", "chromium"], [{appId: "chromium", ref: "c"}], lookup);
        const out = DockModel.bounceKeys({foot: 1000, chromium: 1000, old: 0}, items, 5000, 10000);
        compare(Object.keys(out).join(","), "foot");
        compare(Object.keys(DockModel.bounceKeys({foot: 1000}, items, 20000, 10000)).length, 0);
    }

    // A folder whose name has an extension is a folder (the stat type wins over the name), a file keeps its name type.
    function test_folderWithExtensionIsAFolder() {
        const data = DockModel.parseMimeData(mimeText + "\nE\tfiles\tinode/directory;");
        const files = {id: "files", command: ["files", "%U"]};
        const view = {id: "view", command: ["view", "%f"]};
        const dir = "/home/u/Photos.png";
        const types = {[dir]: "inode/directory"};
        compare(DockModel.mimeTypesOf(dir, data, null).indexOf("inode/directory"), -1);  // by name alone it is a PNG
        compare(DockModel.mimeTypesOf(dir, data, types).join(","), "inode/directory");
        compare(DockModel.dropVerdict(files, [dir], data, types), "yes");
        compare(DockModel.dropVerdict(view, [dir], data, types), "no");
        // a real file keeps its name type even when the lookup says something generic
        compare(DockModel.dropVerdict(view, ["/home/u/a.png"], data, {"/home/u/a.png": "application/octet-stream"}), "yes");
        // verdicts: a known refusal wins over pending paths
        compare(DockModel.dropVerdict(view, [dir, "/home/u/b"], data, types), "no");
        compare(DockModel.dropVerdict(files, [dir, "/home/u/b"], data, types), "pending");
    }

    // Keyed model updates: applying the steps turns the old keys into the new ones, removals first.
    function test_diffKeysTurnsOldIntoNew() {
        const apply = (from, ops) => {
            const l = from.slice();
            ops.forEach(o => {
                if (o.op === "remove")
                    l.splice(o.at, 1);
                else if (o.op === "insert")
                    l.splice(o.at, 0, o.key);
                else
                    l.splice(o.to, 0, l.splice(o.from, 1)[0]);
            });
            return l;
        };
        const cases = [
            [["a", "b", "c", "sep", "trash"], ["a", "b", "c", "sep", "trash"]],
            [["a", "b", "sep", "trash"], ["a", "b", "c", "sep", "trash"]],
            [["a", "b", "c", "sep", "trash"], ["a", "c", "sep", "trash"]],
            [["a", "b", "c", "sep", "trash"], ["c", "a", "b", "sep", "trash"]],
            [["a", "b", "sep", "trash"], ["a", "sep", "div", "b", "trash"]],
            [["a", "b", "c", "d"], ["d", "x", "c", "b"]],
            [[], ["a", "b"]],
            [["a", "b"], []]
        ];
        cases.forEach(c => {
            const ops = DockModel.diffKeys(c[0], c[1]);
            compare(apply(c[0], ops).join(","), c[1].join(","));
            const firstOther = ops.findIndex(o => o.op !== "remove");
            verify(firstOther < 0 || ops.slice(firstOther).every(o => o.op !== "remove"));
        });
        // duplicates are tolerated at the boundary (never produced today): no stale row is left behind
        const applyList = (from, to) => apply(from, DockModel.diffKeys(from, to));
        compare(applyList(["a", "b", "a", "c"], ["a", "b", "c"]).join(","), "a,b,c");
        compare(applyList(["a", "a", "a"], ["a"]).join(","), "a");
        compare(applyList(["a", "b", "b", "c"], ["c", "b"]).join(","), "c,b");
        compare(applyList(["a", "b"], ["a", "b", "a", "b"]).join(","), "a,b");
        compare(applyList(["x", "x", "y"], ["y", "x", "x", "z"]).join(","), "y,x,z");
        let seed = 12345;
        const rnd = n => {
            seed = (seed * 1103515245 + 12345) % 2147483648;
            return seed % n;
        };
        const dedup = l => l.filter((k, i) => l.indexOf(k) === i);
        for (let n = 0; n < 2000; n++) {
            const mk = () => Array.from({length: rnd(8)}, () => "k" + rnd(5));
            const from = mk();
            const to = mk();
            compare(applyList(from, to).join(","), dedup(to).join(","), "from " + from + " to " + to);
        }
        compare(DockModel.diffKeys(["a", "b"], ["a", "b"]).length, 0);  // nothing to do: delegates untouched
        // a tile that changes section is one move, not a remove and an insert (its delegate survives)
        const moved = DockModel.diffKeys(["app:x", "app:y", "sep", "trash"], ["app:y", "sep", "app:x", "trash"]);
        verify(moved.every(o => o.op === "move"));
    }

    // ---- the two fixed tiles: Files, then Apps ----

    readonly property var filesEntry: ({id: "org.grassfield.Files", name: "Files", icon: "org.grassfield.Files"})

    function lookupWithFiles(id) {
        return DockModel.isFilesId(id) ? filesEntry : lookup(id);
    }

    function kinds(items) {
        return items.map(i => i.kind === "app" || i.kind === "files" ? i.kind + ":" + i.key : i.kind).join(",");
    }

    function build(pinned, running, minimized) {
        const apps = DockModel.merge(DockModel.withoutFiles(pinned), running, lookupWithFiles);
        const split = DockModel.splitFiles(apps, lookupWithFiles);
        return DockModel.withFixed(split.files, DockModel.withTail(split.rest, minimized ? minimized : []));
    }

    function test_filesAndAppsAreTheFirstTwoTiles() {
        const items = build(["chromium", "foot"], []);
        compare(kinds(items), "files:files,apps,app:chromium,app:foot,separator,trash");
        compare(items[0].fixed, true);
        compare(items[0].pinned, true);
        compare(items[0].name, "Files");
        compare(items[0].icon, "org.grassfield.Files");
        compare(items[0].entry.id, "org.grassfield.Files");
    }

    function test_filesTileCannotBeRemovedOrDuplicated() {
        // A stored Files id (with or without .desktop) gives no second tile and the tile stays when the list is emptied.
        compare(kinds(build(["org.grassfield.Files", "foot", "org.grassfield.Files.desktop"], [])), "files:files,apps,app:foot,separator,trash");
        compare(kinds(build([], [])), "files:files,apps,separator,trash");
        // Whatever its case (review of PR #53: as windowsOf and the entry lookup compare ids).
        compare(DockModel.withoutFiles(["org.grassfield.Files", "foot", "ORG.grassfield.Files", "org.grassfield.files.DESKTOP"]).join(","), "foot");
        verify(DockModel.isFilesId("ORG.GRASSFIELD.FILES.desktop"));
        verify(!DockModel.isFilesId("org.grassfield.Filesystem"));
        verify(!DockModel.isFilesId(undefined));
        const split = DockModel.splitFiles([{kind: "app", key: "Org.Grassfield.Files", windows: ["w1"]}], id => null);
        compare(split.files.windows.join(","), "w1");
        compare(split.rest.length, 0);
        compare(DockModel.withoutFiles(undefined).length, 0);
        // The tile is not an app tile: reorder, drag slots and unpin never see it.
        const items = build(["chromium", "foot"], []);
        compare(DockModel.appIndices(items).join(","), "2,3");
        const r = DockModel.reorder(items, 0, 1);
        compare(r.pinned.join(","), "foot,chromium");
        compare(DockModel.unpin(["org.grassfield.Files", "foot"], "foot").join(","), "org.grassfield.Files");
    }

    function test_filesTileCarriesTheWindows() {
        const items = build(["foot"], [{appId: "org.grassfield.Files", ref: "f1"}, {appId: "foot", ref: "t1"}, {appId: "org.grassfield.Files", ref: "f2"}]);
        compare(kinds(items), "files:files,apps,app:foot,separator,trash");
        compare(items[0].windows.join(","), "f1,f2");
        compare(items[2].windows.join(","), "t1");
    }

    function test_filesTileWithoutDesktopEntry() {
        const split = DockModel.splitFiles([], id => null);
        compare(split.files.entry, null);
        compare(split.files.name, "Files");
        compare(split.files.icon, "org.grassfield.Files");
        compare(split.files.kind, "files");
    }

    function test_filesTileKeepsMinimizedTilesAndTrashAfterIt() {
        const min = [{kind: "minimized", key: "min:1"}];
        compare(kinds(build(["foot"], [], min)), "files:files,apps,app:foot,separator,minimized,trash");
    }

    function test_tileKeysAndBounce() {
        compare(DockModel.tileKey({kind: "files", key: "files"}), "files:files");
        compare(DockModel.tileKey({kind: "apps", key: "grid"}), "apps:grid");
        const items = build(["foot"], []);
        const kept = DockModel.bounceKeys({files: Date.now(), foot: Date.now()}, items, Date.now(), 10000);
        compare(Object.keys(kept).sort().join(","), "files,foot");
        const running = build(["foot"], [{appId: "org.grassfield.Files", ref: "f"}]);
        compare(Object.keys(DockModel.bounceKeys({files: Date.now()}, running, Date.now(), 10000)).length, 0);
    }

    function test_defaultPinsMigrate() {
        compare(DockModel.migratePinned(["foot", "chromium", "org.gnome.Nautilus"]).join(","), "chromium,foot,org.grassfield.Settings");
        // A customised list, even a small variation of the old default, is not touched.
        compare(DockModel.migratePinned(["foot", "chromium", "org.gnome.Nautilus", "kate"]).join(","), "foot,chromium,org.gnome.Nautilus,kate");
        compare(DockModel.migratePinned(["chromium", "foot"]).join(","), "chromium,foot");
        compare(DockModel.migratePinned([]).length, 0);
        compare(DockModel.migratePinned(undefined).length, 0);
        compare(DockModel.DEFAULT_PINNED.join(","), "chromium,foot,org.grassfield.Settings");
    }

    // Owner report 2026-11-08: foot could not be removed from the Dock while it ran.
    function test_runningAppIsRemovable() {
        const running = DockModel.merge(["foot"], [{appId: "foot", ref: "w"}], lookup)[0];
        verify(running.pinned && running.windows.length === 1);
        verify(DockModel.removable(running), "a running pinned app is dragged out (macOS)");
        verify(DockModel.removable({kind: "app", pinned: false, recent: true, windows: []}));
        verify(!DockModel.removable({kind: "app", pinned: false, windows: ["w"]}), "a running app that is not kept has nothing to remove");
        verify(!DockModel.removable({kind: "files", pinned: true, fixed: true, windows: []}), "Files is fixed");
        verify(!DockModel.removable({kind: "apps"}));
        verify(!DockModel.removable({kind: "trash"}));
        verify(!DockModel.removable(null));
    }

    function test_removeKeepsTileWhileRunning() {
        const run = [{appId: "foot", ref: "w"}];
        const after = DockModel.unpinKey(["chromium", "foot", "Foot.desktop"], "foot", lookup);
        compare(after.join(","), "chromium");
        const tiles = DockModel.merge(after, run, lookup);
        compare(tiles.map(t => t.key + ":" + t.pinned + ":" + t.windows.length).join(","), "chromium:true:0,foot:false:1");
    }

    function test_keepInDockToggle() {
        // Keep in Dock on a running tile pins its key; checked again, it unpins.
        const pinned = DockModel.pin(DockModel.pin(["chromium"], "foot", lookup), "Foot.desktop", lookup);
        compare(pinned.join(","), "chromium,foot");
        compare(DockModel.unpinKey(pinned, "foot", lookup).join(","), "chromium");
    }

    function test_removalFindsEveryIdSpelling() {
        compare(DockModel.normId("Foot.DESKTOP"), "foot");
        compare(DockModel.unpinKey(["foot.desktop", "chromium"], "foot", lookup).join(","), "chromium", "stored with the suffix");
        compare(DockModel.unpinKey(["Org.Gnome.nautilus"], "org.gnome.Nautilus", lookup).length, 0, "case");
        compare(DockModel.unpinKey(["chromium", "foot"], "foot.desktop", lookup).join(","), "chromium", "the tile key with the suffix");
        compare(DockModel.unpinKey(["foot.desktop", "FOOT", "foot"], "foot", lookup).length, 0, "every duplicate goes");
        // An id no entry resolves (a Flatpak or Electron app id) is still removed by the same spelling rule.
        compare(DockModel.unpinKey(["com.example.App.desktop", "foot"], "com.example.app", lookup).join(","), "foot");
        compare(DockModel.unpinKey(["foot"], "foot", null).length, 0, "no lookup function");
        compare(DockModel.pin(["foot.desktop"], "foot", lookup).join(","), "foot", "a stored spelling that resolves is rewritten to the entry id, never a duplicate");
        compare(DockModel.pin(["ghost.desktop"], "ghost", lookup).join(","), "ghost.desktop,ghost", "ids that resolve to nothing never refuse a pin");
        compare(DockModel.unpin(["Foot", "kate"], "foot.desktop").join(","), "kate");
    }

    // Review of f27fbcb1: the lookup matches exactly, then without case, and does not strip ".desktop".
    function exactLookup(id) {
        const all = {"foot": {id: "foot"}, "Foot": {id: "Foot"}, "chromium": {id: "chromium"}};
        if (all[id])
            return all[id];
        for (const k in all) {
            if (k.toLowerCase() === String(id).toLowerCase())
                return all[k];
        }
        return null;
    }

    function test_pinIdentifiesByResolvedEntry() {
        // A stored "foot.desktop" resolves only after the suffix goes: Keep in Dock on foot must pin, not do nothing.
        compare(DockModel.pin(["chromium", "foot.desktop"], "foot", exactLookup).join(","), "chromium,foot");
        // Two installed entries that differ only by case stay distinct.
        compare(DockModel.pin(["Foot"], "foot", exactLookup).join(","), "Foot,foot");
        compare(DockModel.unpinKey(["Foot", "foot"], "foot", exactLookup).join(","), "Foot");
        compare(DockModel.unpinKey(["Foot", "foot"], "Foot", exactLookup).join(","), "foot");
        verify(DockModel.sameApp("foot.desktop", "foot", exactLookup));
        verify(!DockModel.sameApp("Foot", "foot", exactLookup));
        // A stored id that resolves to nothing never blocks a pin of an unrelated id.
        compare(DockModel.pin(["foot.desktop"], "chromium", function (id) { return null; }).join(","), "foot.desktop,chromium");
    }

    function test_removalNeverReseeds() {
        // A list shrunk by a removal is never rewritten by the Dock rules: not to the default, not when it empties.
        compare(DockModel.migratePinned(DockModel.unpinKey(["foot", "chromium", "org.gnome.Nautilus"], "org.gnome.Nautilus", lookup)).join(","), "foot,chromium");
        compare(DockModel.migratePinned(DockModel.unpinKey(["foot", "foot.desktop"], "foot", lookup)).length, 0, "an emptied list stays empty");
        compare(DockModel.migratePinned(["chromium", "foot"]).join(","), "chromium,foot");
    }

    function test_oldWithAppsStillWorks() {
        compare(DockModel.withApps([{kind: "app", key: "a"}])[0].kind, "apps");
    }

    function test_opensDocumentsNeedsAFileFieldCode() {
        verify(DockModel.opensDocuments({id: "e", execString: "gedit %U"}));
        verify(DockModel.opensDocuments({id: "e", execString: "viewer --file %f"}));
        verify(DockModel.opensDocuments({id: "e", command: ["app", "%F"]}));
        verify(!DockModel.opensDocuments({id: "e", execString: "foot"}));
        verify(!DockModel.opensDocuments({id: "e", execString: "app --name %c"}));
        verify(!DockModel.opensDocuments({id: "e", execString: "app 100%%"}));
        verify(!DockModel.opensDocuments(null));
    }
}
