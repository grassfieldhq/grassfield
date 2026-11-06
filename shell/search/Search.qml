pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.lib
import Quickshell.Io
import Grassfield.Ui
import qs.platform
import qs.services
import "../platform/ScreenChoice.js" as ScreenChoice
import "Calc.js" as Calc
import "ClipboardView.js" as ClipView
import "Files.js" as Files
import "Filters.js" as Filters
import "Ranking.js" as Ranking
import "SettingsPages.js" as SettingsPages
import "Units.js" as Units
import "../launchpad/Model.js" as Model // layering-exception: GF-087

// Search (spec docs/specs/search.md): a centered floating field with grouped results.
// This Scope owns the state and all providers; SearchPanel renders it, one overlay window per
// screen, shown on the focused screen only.
//
// Providers: apps (DesktopEntries + Ranking.js), calculator (Calc.js), conversion (Units.js),
// commands (Power service), files (`localsearch search`, falling back to `plocate`, argv only,
// asynchronous, stale queries ignored) and recent documents (recently-used.xbel, read only).
// The Clipboard view (ADR-0034, docs/specs/clipboard.md CB-5 to CB-12, CB-15) shows the clipboard history instead: the items
// of the Clipboard service, filtered by the helper's search, pasted, copied, pinned, deleted or previewed (ClipboardView.js).
// Untrusted strings (desktop entries, file names, copied text) are only ever rendered as plain text.
Scope {
    id: root

    property bool open: false
    // Key focus returns to the window that was active when this opened (FocusReturn), as on macOS.
    onOpenChanged: {
        if (open)
            FocusReturn.opened("search");
        else
            FocusReturn.closed("search", true);
    }
    property string query: ""
    property string screenName: ""
    // Groups [{id, title, items}], the flat rows for the list ({item, itemIndex, groupId}: no header rows, as macOS 27 Spotlight;
    // the groups still order the list and Tab moves between them)
    // and the flat items (actionable entries). `selected` indexes `items`.
    property var groups: []
    property var rows: []
    property var items: []
    property int selected: -1
    property var fileHits: []
    // Filter chips under the field: the chip ids the unfiltered results offer, and the selected one ("" = all).
    // File search still running or about to start: the "No Results" notice waits for it.
    readonly property bool filesPending: fileTimer.running || liveSearches.length > 0
    property var chips: []
    property string filter: ""
    // Chips need something to choose between; a lone category is the list itself.
    readonly property bool chipsShown: query.trim() !== "" && chips.length > 1
    // Keyboard reach of the chips: the field keeps the text focus; in the "chips" zone the ring is on chip `chipIndex`.
    property string zone: "field"
    property int chipIndex: -1

    // The view: "" for the results, "clipboard" for the clipboard history (⌘4, the Clipboard button, Super+Ctrl+V).
    property string view: ""
    readonly property bool clipboardView: view === "clipboard"
    // The history is off: the view asks first (CB-6, macOS 27's prompt) instead of showing rows.
    readonly property bool clipPrompt: clipboardView && !Clipboard.enabled
    // The ids the helper's search returned for the query (null: every item, as for an empty query) and the request they answer.
    property var clipMatch: null
    property int clipSeq: 0
    // After a delete, the row that takes the selection (ClipView.selectionAfterRemove), -1 when none is pending.
    property int clipSelectAfter: -1
    // The row that says "Copied" for a moment (CB-8), and a short notice under the rows ("Pinned items are full").
    property string clipCopiedKey: ""
    property string clipNotice: ""
    // The preview panel (CB-11): the item it shows and what the helper made for it (a picture path or the plain text).
    property var clipPreview: null
    property string clipPreviewPath: ""
    property string clipPreviewText: ""
    property bool clipPreviewReady: false

    // The panel's field shows `query` again (the view changed it).
    signal queryReset
    readonly property var chipLabels: ({
            "apps": qsTr("Applications"),
            "commands": qsTr("Commands"),
            "settings": qsTr("Settings"),
            "documents": qsTr("Documents")
        })

    // Lock Screen: the lock module (shell/security/lock) exposes the `lock` IPC target and the Lock singleton the System
    // menu already calls; the command locks through it (SessionState.requestLock, wired to Lock.lock in shell.qml;
    // REQ-SRCH-PRV-d2). It is always on offer: a failed lock stays locked.
    readonly property bool lockAvailable: true

    // The pages of Grassfield Settings the provider offers (REQ-SRCH-PRV-d1); ids are the Settings sections.
    readonly property var settingsPageList: [
        {id: "wifi", title: qsTr("Wi-Fi"), keywords: [qsTr("wireless"), qsTr("network"), qsTr("internet")]},
        {id: "bluetooth", title: qsTr("Bluetooth"), keywords: [qsTr("devices"), qsTr("headphones"), qsTr("pair")]},
        {id: "sound", title: qsTr("Sound"), keywords: [qsTr("volume"), qsTr("output"), qsTr("input"), qsTr("microphone"), qsTr("mute")]},
        {id: "displays", title: qsTr("Displays"), keywords: [qsTr("monitor"), qsTr("screen"), qsTr("resolution"), qsTr("scale")]},
        {id: "appearance", title: qsTr("Appearance"), keywords: [qsTr("dark"), qsTr("light"), qsTr("auto"), qsTr("theme"), qsTr("accent"), qsTr("transparency"), qsTr("icons")]},
        {id: "wallpaper", title: qsTr("Wallpaper"), keywords: [qsTr("background"), qsTr("picture"), qsTr("shuffle")]},
        {id: "accessibility", title: qsTr("Accessibility"), keywords: [qsTr("pointer"), qsTr("cursor"), qsTr("contrast"), qsTr("reduce motion"), qsTr("text size")]},
        {id: "desktop", title: qsTr("Desktop & Dock"), keywords: [qsTr("dock"), qsTr("magnification"), qsTr("screen corners"), qsTr("tile"), qsTr("tiling"), qsTr("layouts")]},
        {id: "menubar", title: qsTr("Menu Bar"), keywords: [qsTr("clock"), qsTr("menu bar background"), qsTr("status items"), qsTr("hide menu bar"), qsTr("battery percentage")]},
        {id: "search", title: qsTr("Search"), keywords: [qsTr("search results"), qsTr("search history")]},
        {id: "notifications", title: qsTr("Notifications"), keywords: [qsTr("do not disturb"), qsTr("previews"), qsTr("banners")]},
        {id: "focus", title: qsTr("Focus"), keywords: [qsTr("do not disturb"), qsTr("silence")]},
        {id: "lock", title: qsTr("Lock Screen", "Settings page"), keywords: [qsTr("idle"), qsTr("password")]},
        {id: "privacy", title: qsTr("Privacy & Security"), keywords: [qsTr("permissions"), qsTr("location"), qsTr("camera"), qsTr("screen sharing"), qsTr("disk encryption"), qsTr("disk password")]},
        {id: "fingerprint", title: qsTr("Fingerprint & Key"), keywords: [qsTr("fingerprint"), qsTr("security key"), qsTr("unlock"), qsTr("sign in")]},
        {id: "sharing", title: qsTr("Sharing"), keywords: [qsTr("remote login"), qsTr("ssh")]},
        {id: "mouse", title: qsTr("Mouse"), keywords: [qsTr("pointer"), qsTr("tracking speed"), qsTr("scrolling")]},
        {id: "trackpad", title: qsTr("Trackpad"), keywords: [qsTr("touchpad"), qsTr("tracking speed"), qsTr("tap to click"), qsTr("gestures")]},
        {id: "printers", title: qsTr("Printers"), keywords: [qsTr("printer"), qsTr("paper size"), qsTr("print")]},
        {id: "keyboard", title: qsTr("Keyboard"), keywords: [qsTr("shortcuts"), qsTr("keys"), qsTr("dictation")]},
        {id: "about", title: qsTr("About"), keywords: [qsTr("version"), qsTr("system"), qsTr("hardware")]},
        {id: "software-update", title: qsTr("Software Update"), keywords: [qsTr("update"), qsTr("upgrade"), qsTr("new version"), qsTr("beta")]}
    ].map(p => Object.assign({icon: SettingsPages.PAGES.find(d => d.id === p.id).icon}, p))

    // Latency log (P4): timestamps taken at the IPC call and at the keystroke.
    property real openStartMs: 0
    property real keyStartMs: 0

    property var appRecords: []
    property var usage: Ranking.newUsage()
    property var recentList: []

    readonly property string home: Quickshell.env("HOME")
    // Dev/test knobs: file results are limited to this root ($HOME; in a dev session GRASSFIELD_SEARCH_ROOT or the dev apps-home's
    // files folder, Apps.searchRoot) and plocate can use
    // another database, so tests do not depend on the owner's index.
    readonly property string filesRoot: Apps.searchRoot
    readonly property string plocateDb: Mode.devValue("SEARCH_PLOCATE_DB")
    // Dev session: the dev apps-home, never the owner's recent files.
    readonly property string dataHome: Apps.dataHome
    // GRASSFIELD_STATE_HOME (dev) wins; otherwise $XDG_STATE_HOME/grassfield.
    readonly property string stateDir: Mode.stateDir
    readonly property string usagePath: stateDir + "/search-usage.json"

    // The kinds of results shown (Settings > Search > Search Results; tests set them directly).
    property bool showApps: Settings.searchShowApps
    property bool showDocuments: Settings.searchShowDocuments
    property bool showRecents: Settings.searchShowRecents
    property bool showCalculator: Settings.searchShowCalculator
    property bool showConversions: Settings.searchShowConversions
    property bool showSettings: Settings.searchShowSettings
    property bool showCommands: Settings.searchShowCommands
    // Delete Search History: the results picked before this time are forgotten, in memory and in search-usage.json.
    property real historyResetAt: Settings.searchHistoryResetAt
    onHistoryResetAtChanged: forgetHistory()
    onShowDocumentsChanged: {
        if (!showDocuments) {
            fileTimer.stop();
            cancelFiles();
            fileHits = [];
        }
    }

    function forgetHistory(): void {
        const kept = Ranking.forgetUsageBefore(usage, historyResetAt);
        if (Object.keys(kept).length === Object.keys(usage).length)
            return;
        usage = kept;
        if (usageFile.path !== "")
            usageFile.setText(Ranking.serializeUsage(usage));
    }

    // ---- state changes -------------------------------------------------------------------

    function focusedScreenName(): string {
        return Compositor.activeScreenName;
    }

    // The display the Search panel is on went away (unplugged): the panel moves to a live one.
    Connections {
        target: Quickshell

        function onScreensChanged(): void {
            root.screenName = ScreenChoice.replacement(root.screenName, Compositor.focusedScreenName, Quickshell.screens.map(s => s.name));
        }
    }

    function show(text: string): void {
        // Nothing opens over the lock screen (GF-116): SUPER+SPACE, the menu bar item and IPC alike.
        if (SessionState.refuses("search"))
            return;
        openStartMs = Date.now();
        if (Popups.active)
            Popups.close();
        // The window a paste may go to: the one active now, never the desktop (FocusReturn remembers the same one).
        const target = DesktopState.holdsKeyboard ? null : Compositor.activeWindow();
        Clipboard.watchTarget(target ? target.address : "");
        screenName = focusedScreenName();
        recentFile.reload();
        // Opened again during the fade-out of a Clipboard view: it opens on the results, as after the release.
        released();
        setQuery(text);
        open = true;
    }

    function hide(): void {
        open = false;
        // A paste the helper has not confirmed yet ends with Search: a late confirmation pastes nothing (ADR-0034 §4).
        Clipboard.searchClosed();
        leaveChips();
        fileTimer.stop();
        cancelFiles();
        fileHits = [];
    }

    // The panel is gone (its fade-out and keyboard release ran, SearchPanel): the Clipboard view, its preview and notice reset
    // only now, so the glyph, the placeholder and the preview never change while the panel fades out (UI audit 2026-11-05 U9).
    function released(): void {
        if (open)
            return;
        closePreview();
        view = "";
        clipNotice = "";
    }

    function toggle(): void {
        if (open)
            hide();
        else
            show("");
    }

    function setQuery(text: string): void {
        if (clipboardView) {
            setClipQuery(text);
            return;
        }
        if (text === query && groups.length > 0)
            return;
        query = text;
        filter = "";
        leaveChips();
        fileHits = [];
        cancelFiles();
        compute();
        const q = text.trim();
        if (showDocuments && q.length >= 2 && !q.startsWith("-"))
            fileTimer.restart();
        else
            fileTimer.stop();
    }

    // ---- providers -----------------------------------------------------------------------

    function rebuildApps(): void {
        const out = [];
        const list = DesktopEntries.applications.values;
        for (const e of list) {
            if (!Apps.isListed(e))
                continue;
            // Name, generic name, comment and keywords in the shell's language (Apps.localized).
            out.push({id: e.id, name: Apps.displayName(e), genericName: Apps.displayGenericName(e), comment: Apps.displayComment(e),
                keywords: Apps.displayKeywords(e), icon: e.icon, entry: e});
        }
        // Two apps of one name are told apart (Files and Files (GNOME)), as in Apps; nothing is hidden.
        appRecords = Model.disambiguate(out);
    }

    function commandList(): var {
        const list = [];
        if (lockAvailable)
            list.push({id: "lock", title: qsTr("Lock Screen"), words: [qsTr("lock")], glyph: "lock"});
        list.push({id: "sleep", title: qsTr("Sleep"), words: [qsTr("suspend")], glyph: "moon"});
        list.push({id: "restart", title: qsTr("Restart"), words: [qsTr("reboot")], glyph: "power"});
        list.push({id: "shutdown", title: qsTr("Shut Down"), words: [qsTr("power off"), qsTr("poweroff")], glyph: "power"});
        list.push({id: "logout", title: qsTr("Log Out"), words: [qsTr("sign out"), qsTr("log off")], glyph: "person"});
        return list;
    }

    function commandScore(cmd: var, q: string): real {
        let s = Ranking.textScore(Ranking.norm(cmd.title), q);
        for (const w of cmd.words)
            s = Math.max(s, Ranking.textScore(Ranking.norm(w), q) * 0.8);
        return s >= 50 ? s : 0;
    }

    function mkApp(r: var): var {
        return {kind: "app", key: "app:" + r.app.id, title: r.app.name, subtitle: r.app.genericName !== "" ? r.app.genericName : qsTr("Application"),
            iconSource: "", appIcon: r.app.icon, entry: r.app.entry, appId: r.app.id};
    }

    function mkCommand(c: var): var {
        return {kind: "command", key: "cmd:" + c.id, title: c.title, subtitle: qsTr("System command"), glyph: c.glyph, command: c.id};
    }

    function mkSetting(h: var): var {
        return {kind: "setting", key: "setting:" + h.page.id, title: h.page.title, subtitle: qsTr("Settings"), glyph: h.page.icon, page: h.page.id};
    }

    function mkPath(kind: string, path: string): var {
        return {kind: kind, key: kind + ":" + path, title: Files.baseName(path), subtitle: Files.tildePath(Files.dirName(path), filesRoot),
            iconSource: Quickshell.iconPath("text-x-generic", true), path: path};
    }

    function compute(): void {
        if (clipboardView) {
            computeClip();
            return;
        }
        const q = query.trim();
        // Each kind of result only when Settings > Search shows it.
        const calc = showCalculator && q !== "" ? Calc.answer(q, Qt.locale()) : null;
        const unit = showConversions && q !== "" ? Units.answer(q, Qt.locale()) : null;
        const lq = Ranking.norm(q);

        let apps = showApps && q !== "" ? Ranking.rank(appRecords, q, usage, 8) : [];
        let cmds = [];
        if (showCommands && q !== "") {
            for (const c of commandList()) {
                const s = commandScore(c, lq);
                if (s > 0)
                    cmds.push({cmd: c, score: s});
            }
            cmds.sort((a, b) => b.score - a.score);
        }
        let pages = showSettings && q !== "" ? SettingsPages.match(settingsPageList, q) : [];
        // A command and a Settings page that read the same are one row, the command (the action wins; the page is one click
        // away in Settings). In French the page is "Écran verrouillé" and the command "Verrouiller l’écran": both stay.
        const commandTitles = new Set(cmds.map(c => Ranking.norm(c.cmd.title)));
        pages = pages.filter(p => !commandTitles.has(Ranking.norm(p.page.title)));
        const seen = {};
        let docs = [];
        for (const p of showDocuments ? fileHits : []) {
            seen[p] = true;
            docs.push(mkPath("file", p));
        }
        // macOS: an empty field shows no results; documents (recent included) appear from the first keystroke.
        let recents = [];
        for (const r of q === "" || !showRecents ? [] : recentList) {
            if (recents.length >= Tokens.searchRecentCount)
                break;
            if (seen[r.path])
                continue;
            if (Ranking.norm(Files.baseName(r.path)).indexOf(lq) >= 0)
                recents.push(mkPath("recent", r.path));
        }
        if (lq !== "")
            recents = recents.filter(r => docs.every(d => d.path !== r.path));

        // Top Hit: best app or command, else a document. Never when an inline answer exists.
        let top = null;
        if (q !== "" && !calc && !unit) {
            const appScore = apps.length > 0 ? apps[0].score : 0;
            const cmdScore = cmds.length > 0 ? cmds[0].score : 0;
            const pageScore = pages.length > 0 ? pages[0].score : 0;
            if (appScore > 0 && appScore >= cmdScore && appScore >= pageScore) {
                top = mkApp(apps[0]);
                apps = apps.slice(1);
            } else if (cmdScore > 0 && cmdScore >= pageScore) {
                top = mkCommand(cmds[0].cmd);
                cmds = cmds.slice(1);
            } else if (pageScore > 0) {
                top = mkSetting(pages[0]);
                pages = pages.slice(1);
            } else if (recents.length > 0) {
                top = recents[0];
                recents = recents.slice(1);
            } else if (docs.length > 0) {
                top = docs[0];
                docs = docs.slice(1);
            }
        }

        let g = [];
        if (calc)
            g.push({id: "calc", title: qsTr("Calculator"), items: [{kind: "calc", key: "calc", title: calc.text, subtitle: q + " " + qsTr("(Return copies the result)"), badge: "=", text: calc.text}]});
        if (unit)
            g.push({id: "units", title: qsTr("Conversion"), items: [{kind: "calc", key: "unit", title: unit.text, subtitle: q + " " + qsTr("(Return copies the result)"), badge: "↔", text: unit.text}]});
        if (top)
            g.push({id: "top", title: qsTr("Top Hit"), items: [top]});
        if (apps.length > 0)
            g.push({id: "apps", title: qsTr("Applications"), items: apps.map(r => mkApp(r))});
        if (cmds.length > 0)
            g.push({id: "commands", title: qsTr("Commands"), items: cmds.map(c => mkCommand(c.cmd))});
        if (pages.length > 0)
            g.push({id: "settings", title: qsTr("Settings"), items: pages.map(h => mkSetting(h))});
        if (docs.length > 0)
            g.push({id: "files", title: qsTr("Documents"), items: docs});
        if (recents.length > 0)
            g.push({id: "recent", title: qsTr("Recent"), items: recents});

        // Chips come from the unfiltered results; a chip that no longer has results is dropped with its filter.
        chips = Filters.chipsOf(g);
        if (zone === "chips" && (chips.length < 2 || query.trim() === ""))
            leaveChips();
        if (filter !== "" && chips.indexOf(filter) < 0)
            filter = "";
        g = Filters.apply(g, filter, filter !== "" ? chipLabels[filter] : "");

        const flat = [];
        const rowList = [];
        let sel = -1;
        const prevKey = selected >= 0 && selected < items.length ? items[selected].key : "";
        for (const grp of g) {
            for (const it of grp.items) {
                if (prevKey !== "" && it.key === prevKey && fileHitsOnly)
                    sel = flat.length;
                rowList.push({item: it, itemIndex: flat.length, groupId: grp.id});
                flat.push(Object.assign({groupId: grp.id}, it));
            }
        }
        groups = g;
        items = flat;
        rows = rowList;
        selected = flat.length === 0 ? -1 : (sel >= 0 ? sel : 0);
        if (keyStartMs > 0)
            console.info("grassfield-shell: search keystroke->results", Date.now() - keyStartMs, "ms,", flat.length, "results");
    }

    // True while only async file results changed: keep the user's selection.
    property bool fileHitsOnly: false

    // ---- files (localsearch, plocate fallback) -------------------------------------------

    property int fileSeq: 0
    property var liveSearches: []

    Timer {
        id: fileTimer
        interval: 100
        onTriggered: root.startFiles()
    }

    Component {
        id: searchProc

        Process {
            id: proc
            // `localsearch` first, then `plocate` when it yields nothing or is unusable.
            property int seq: 0
            property string term: ""
            property string stage: "localsearch"
            stdout: StdioCollector {
                onStreamFinished: root.filesFinished(proc, text)
            }
        }
    }

    function spawnSearch(seq: int, term: string, stage: string): void {
        const argv = stage === "localsearch"
            ? ["timeout", "2", "localsearch", "search", "-f", "-l", String(Tokens.searchMaxFiles), "--", term]
            : ["timeout", "2", "plocate", "-i", "-b", "-l", "1500"].concat(plocateDb !== "" ? ["-d", plocateDb] : [], ["--", term]);
        const p = searchProc.createObject(root, {seq: seq, term: term, stage: stage, command: argv});
        // Reassigned, not pushed: a mutated array does not notify, and filesPending must see the search start.
        liveSearches = liveSearches.concat([p]);
        p.running = true;
    }

    function startFiles(): void {
        const term = query.trim();
        if (!showDocuments || term.length < 2 || term.startsWith("-"))
            return;
        fileSeq++;
        spawnSearch(fileSeq, term, "localsearch");
    }

    function cancelFiles(): void {
        fileSeq++;
        for (const p of liveSearches) {
            if (p && p.running)
                p.running = false;
        }
        liveSearches = [];
    }

    function filesFinished(proc: var, text: string): void {
        liveSearches = liveSearches.filter(p => p !== proc);
        proc.destroy(200);
        if (proc.seq !== fileSeq)
            return;
        const limit = Tokens.searchMaxFiles;
        const paths = proc.stage === "localsearch" ? Files.parseLocalsearch(text, filesRoot, limit) : Files.parsePlocate(text, proc.term, filesRoot, limit);
        if (paths.length === 0 && proc.stage === "localsearch") {
            spawnSearch(proc.seq, proc.term, "plocate");
            return;
        }
        fileHits = paths;
        const t0 = Date.now();
        fileHitsOnly = true;
        compute();
        fileHitsOnly = false;
        console.info("grassfield-shell: search files via", proc.stage, paths.length, "results, merge", Date.now() - t0, "ms");
    }

    // ---- activation ----------------------------------------------------------------------

    function activate(item: var, reveal: bool): void {
        if (!item)
            return;
        switch (item.kind) {
        case "app":
            bumpUsage(item.appId);
            hide();
            Apps.launch(item.entry);
            return;
        case "calc":
            hide();
            Quickshell.execDetached(["wl-copy", "--", item.text]);
            return;
        case "command":
            hide();
            runCommand(item.command);
            return;
        case "setting":
            hide();
            if (SettingsPages.known(item.page))
                SettingsApp.openSection(item.page);
            return;
        case "file":
        case "recent":
            hide();
            if (reveal)
                Apps.openDetached(["gio", "open", Files.dirName(item.path)]);
            else
                Apps.openDetached(["xdg-open", item.path]);
            return;
        case "clip":
            clipPaste(item, false);
            return;
        }
    }

    function activateSelected(reveal: bool): void {
        if (selected >= 0 && selected < items.length)
            activate(items[selected], reveal);
    }

    function runCommand(id: string): void {
        switch (id) {
        case "lock":
            SessionState.requestLock("search");
            return;
        case "sleep":
            Power.sleepNow();
            return;
        // Restart, Shut Down and Log Out: no message, the dialog shows its countdown (ADR-0040 ID-21).
        case "restart":
            Popups.confirm(qsTranslate("Search", "Are you sure you want to restart your computer now?"), "", qsTranslate("Search", "Restart"), "restart", {}, true, screenName);
            return;
        case "shutdown":
            Popups.confirm(qsTranslate("Search", "Are you sure you want to shut down your computer now?"), "", qsTranslate("Search", "Shut Down"), "shutdown", {}, true, screenName);
            return;
        case "logout":
            Popups.confirm(qsTranslate("Search", "Are you sure you want to quit all applications and log out %1?").arg(SystemInfo.user), "", qsTranslate("Search", "Log Out"), "logout", {}, true, screenName);
            return;
        }
    }

    // Click on a chip: select it, or clear the filter when it is the selected one.
    function leaveChips(): void {
        zone = "field";
        chipIndex = -1;
    }

    // A key of the field's handler while the chips hold the keyboard reach. Returns whether the key was consumed.
    function chipKey(action: string): bool {
        const r = Filters.chipKey(zone, chipIndex, chips.length, action);
        zone = r.zone;
        chipIndex = r.index;
        if (r.toggle && chipIndex >= 0 && chipIndex < chips.length)
            toggleFilter(chips[chipIndex]);
        return r.handled;
    }

    function toggleFilter(id: string): void {
        filter = filter === id ? "" : id;
        compute();
    }

    function move(delta: int): void {
        if (items.length === 0)
            return;
        selected = (selected + delta + items.length) % items.length;
    }

    // Tab / Shift+Tab: first item of the next / previous group.
    function moveGroup(delta: int): void {
        if (items.length === 0 || groups.length === 0)
            return;
        const current = selected >= 0 ? items[selected].groupId : groups[0].id;
        let gi = groups.findIndex(g => g.id === current);
        if (chipsShown && Filters.leavesForChips(gi, groups.length, delta)) {
            zone = "chips";
            chipIndex = delta > 0 ? 0 : chips.length - 1;
            return;
        }
        gi = (gi + delta + groups.length) % groups.length;
        const target = groups[gi].id;
        selected = items.findIndex(it => it.groupId === target);
    }

    // ---- the Clipboard view (ADR-0034) ----------------------------------------------------

    // Super+Ctrl+V: Search opens in the Clipboard view, or closes when that view is shown (CB-5). Opening goes through show()
    // (refused while locked, GF-116); while another program holds the session locked (the helper's notifier), nothing opens.
    function toggleClipboard(): void {
        if (open && clipboardView) {
            hide();
            return;
        }
        if (Clipboard.locked)
            return;
        if (!open)
            show("");
        if (open)
            enterClipboard();
    }

    // ⌘4, the Clipboard button and Super+Ctrl+V. Never while either lock source says locked (PV-9).
    function enterClipboard(): void {
        if (!open || SessionState.refuses("search") || Clipboard.locked)
            return;
        fileTimer.stop();
        cancelFiles();
        fileHits = [];
        leaveChips();
        filter = "";
        view = "clipboard";
        query = "";
        clipMatch = null;
        clipSelectAfter = -1;
        selected = -1;
        compute();
        queryReset();
    }

    // Backspace in the empty field, and "Not Now": back to the results.
    function leaveClipboard(): void {
        closePreview();
        clipNotice = "";
        view = "";
        zone = "field";
        query = "";
        compute();
        queryReset();
    }

    function setClipQuery(text: string): void {
        query = text;
        const q = text.trim();
        if (q === "") {
            clipMatch = null;
            compute();
            return;
        }
        // The helper searches the full text (it never leaves it); the rows follow its answer, stale answers are ignored.
        clipSeq++;
        Clipboard.search(clipSeq, q);
    }

    function computeClip(): void {
        const prevKey = selected >= 0 && selected < items.length ? items[selected].key : "";
        const list = ClipView.visible(Clipboard.items, query.trim() === "" ? null : clipMatch);
        const flat = list.map(it => ({
                    kind: "clip",
                    key: "clip:" + it.id,
                    groupId: "clip",
                    title: it.title,
                    subtitle: "",
                    clip: it
                }));
        let sel = flat.findIndex(it => it.key === prevKey);
        if (sel < 0 && clipSelectAfter >= 0 && flat.length > 0)
            sel = Math.min(clipSelectAfter, flat.length - 1);
        clipSelectAfter = -1;
        chips = [];
        groups = flat.length > 0 ? [{id: "clip", title: qsTr("Clipboard"), items: flat}] : [];
        items = flat;
        rows = flat.map((it, i) => ({item: it, itemIndex: i, groupId: "clip"}));
        selected = flat.length === 0 ? -1 : (sel >= 0 ? sel : 0);
    }

    function selectedClip(): var {
        return clipboardView && selected >= 0 && selected < items.length ? items[selected] : null;
    }

    // Return, Enter, a click, the menu's Paste: copies the item and pastes it into the window Search opened over (Q9, CB-8);
    // `plain` (Shift+Return, Paste as Plain Text) offers its plain text only.
    function clipPaste(item: var, plain: bool): void {
        if (!item || !item.clip)
            return;
        Clipboard.paste(item.clip.id, plain && ClipView.hasPlainVariant(item.clip));
    }

    // The copy button, Ctrl+C, the menu's Copy: copies only; Search stays open and the row says "Copied" once the helper owns
    // the item (Apple's flow, CB-8), or the view says it could not be copied.
    function clipCopy(item: var): void {
        if (!item || !item.clip)
            return;
        Clipboard.copyItem(item.clip.id);
    }

    function clipTogglePin(item: var): void {
        if (!item || !item.clip)
            return;
        if (item.clip.pinned)
            Clipboard.unpin(item.clip.id);
        else
            Clipboard.pin(item.clip.id);
    }

    // The menu's Delete Item, Ctrl+Backspace: the next row takes the selection (CB-9).
    function clipDelete(item: var): void {
        if (!item || !item.clip)
            return;
        const index = items.findIndex(it => it.key === item.key);
        clipSelectAfter = ClipView.selectionAfterRemove(items.length, index);
        if (clipPreview && clipPreview.id === item.clip.id)
            closePreview();
        Clipboard.remove(item.clip.id);
    }

    // Space (empty field), Ctrl+Y: the preview panel shows the selected item, and follows the selection (CB-11).
    function clipTogglePreview(): void {
        if (clipPreview) {
            closePreview();
            return;
        }
        previewItem(selectedClip());
    }

    function previewItem(item: var): void {
        if (clipPreview)
            Clipboard.dropPreview(clipPreview.id);
        if (!item || !item.clip) {
            clipPreview = null;
            return;
        }
        clipPreview = item.clip;
        clipPreviewPath = "";
        clipPreviewText = "";
        clipPreviewReady = false;
        Clipboard.preview(item.clip.id);
    }

    function closePreview(): void {
        if (!clipPreview)
            return;
        Clipboard.dropPreview(clipPreview.id);
        clipPreview = null;
        clipPreviewPath = "";
        clipPreviewText = "";
        clipPreviewReady = false;
    }

    onSelectedChanged: {
        if (clipPreview) {
            const item = selectedClip();
            if (!item)
                closePreview();
            else if (item.clip.id !== clipPreview.id)
                previewItem(item);
        }
    }

    // The More menu's Clear History: every unpinned item, at once (CB-10, the 26.0 menu has no confirmation).
    function clipClearHistory(): void {
        closePreview();
        Clipboard.clearHistory();
    }

    // The More menu's Settings…: Settings > Search.
    function clipOpenSettings(): void {
        hide();
        SettingsApp.openSection("search");
    }

    // The first-use prompt (CB-6): "Allow" turns the history on (recording starts with the next copy), "Not Now" leaves it off.
    function clipAllow(): void {
        Settings.setClipboardEnabled(true);
    }

    function clipNotNow(): void {
        leaveClipboard();
    }

    Timer {
        id: copiedTimer
        interval: Tokens.searchClipCopiedMs
        onTriggered: root.clipCopiedKey = ""
    }

    Timer {
        id: noticeTimer
        interval: 2 * Tokens.searchClipCopiedMs
        onTriggered: root.clipNotice = ""
    }

    Connections {
        target: Clipboard

        function onItemsChanged(): void {
            if (root.open && root.clipboardView)
                root.compute();
        }

        function onSearched(seq: int, ids: var): void {
            if (seq !== root.clipSeq || !root.clipboardView)
                return;
            root.clipMatch = ids;
            root.compute();
        }

        function onCopyConfirmed(id: string): void {
            if (!root.open || !root.clipboardView)
                return;
            root.clipCopiedKey = "clip:" + id;
            copiedTimer.restart();
        }

        // The helper could not take the clipboard (locked by another program, the item gone, no answer): nothing was copied or
        // pasted, and Search stays open to say so (ADR-0034 Q23).
        function onCopyRefused(): void {
            if (!root.open || !root.clipboardView)
                return;
            root.clipNotice = qsTr("The item could not be copied");
            noticeTimer.restart();
        }

        function onPinFull(id: string): void {
            root.clipNotice = qsTr("Pinned items are full");
            noticeTimer.restart();
        }

        function onPreviewReady(id: string, path: string, text: string): void {
            if (!root.clipPreview || root.clipPreview.id !== id)
                return;
            root.clipPreviewPath = path;
            root.clipPreviewText = text;
            root.clipPreviewReady = true;
        }

        // The helper owns the chosen item: Search closes and the keyboard goes back to the window the paste goes to.
        function onPasteCopied(): void {
            if (root.open)
                root.hide();
        }

        // Either lock source (this shell's lock or another program's, the helper's notifier): Search closes and drops what was
        // typed, as below (PV-9). This handler may run before SessionState's, which then finds Search closed.
        function onLockedChanged(): void {
            if (Clipboard.locked && root.open) {
                root.hide();
                root.setQuery("");
            }
        }
    }

    // ---- usage boost persistence (0600, like the notification history) -------------------

    function bumpUsage(id: string): void {
        Ranking.bumpUsage(usage, id, Date.now());
        if (usageFile.path !== "")
            usageFile.setText(Ranking.serializeUsage(usage));
    }

    Process {
        id: prepare
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 \"$1\"; chmod 700 \"$1\"; [ -e \"$2\" ] || install -m 600 /dev/null \"$2\"; chmod 600 \"$2\"", "sh", root.stateDir, root.usagePath]
        onRunningChanged: {
            if (!running)
                usageFile.path = root.usagePath;
        }
    }

    FileView {
        id: usageFile
        printErrors: false
        atomicWrites: true
        // A history deleted while the shell was not running is forgotten now, on disk too.
        onLoaded: {
            root.usage = Ranking.parseUsage(usageFile.text());
            root.forgetHistory();
        }
    }

    // Recent documents, read only.
    FileView {
        id: recentFile
        path: root.dataHome + "/recently-used.xbel"
        printErrors: false
        onLoaded: {
            root.recentList = Files.parseXbel(recentFile.text(), root.filesRoot);
            if (root.open)
                root.compute();
        }
    }

    Connections {
        target: Apps

        function onListChanged(): void {
            root.rebuildApps();
            if (root.open)
                root.compute();
        }
    }

    // The session locks: Search closes (and drops what was typed).
    Connections {
        target: SessionState

        function onLockedChanged(): void {
            if (SessionState.locked && root.open) {
                root.hide();
                root.setQuery("");
            }
        }
    }

    // qs ipc call search <toggle|open|close|query|status>. toggle is the SUPER+SPACE binding; the others are test hooks,
    // refused outside a dev session (VisualFixtures.dev, SEC-04: `status` returns what the user types).
    IpcHandler {
        target: "search"

        function toggle(): void {
            root.toggle();
        }

        // Super+Ctrl+V (bindings.lua): Search in the Clipboard view, or closed when that view is shown (CB-5).
        function clipboard(): void {
            root.toggleClipboard();
        }

        function open(text: string): void {
            if (VisualFixtures.dev)
                root.show(text);
        }

        function close(): void {
            if (VisualFixtures.dev)
                root.hide();
        }

        // Sets the query without opening the window (provider tests).
        function query(text: string): void {
            if (!VisualFixtures.dev)
                return;
            root.keyStartMs = Date.now();
            root.setQuery(text);
            root.keyStartMs = 0;
        }

        // Selects (or clears, with the selected chip's id or "") a filter chip (tests).
        function filter(id: string): void {
            if (!VisualFixtures.active)
                return;
            root.toggleFilter(id);
        }

        // JSON of the visible groups.
        function status(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return JSON.stringify({
                open: root.open,
                query: root.query,
                screen: root.screenName,
                selected: root.selected,
                chips: root.chips,
                filter: root.filter,
                zone: root.zone,
                view: root.view,
                prompt: root.clipPrompt,
                notice: root.clipNotice,
                copied: root.clipCopiedKey,
                preview: root.clipPreview ? root.clipPreview.id : "",
                groups: root.groups.map(g => ({id: g.id, title: g.title, items: g.items.map(i => ({kind: i.kind, title: i.title, subtitle: i.subtitle}))}))
            });
        }
    }

    Component.onCompleted: {
        if (Apps.hiddenReady)
            rebuildApps();
        prepare.running = true;
    }

    SearchPanel {
        controller: root
    }
}
