import QtQuick

// The Store window's backend for the QML tests (apps/store/src/storebackend.h's API): made-up apps, sections and
// categories, nothing read from a system, a network or a file. Calls are recorded for the tests to read.
QtObject {
    id: root

    property string language: "en"
    property bool devSession: true
    property bool dark: false
    property bool reduceMotion: false
    property bool increaseContrast: false
    property real textScale: 1
    property string accentColor: "multicolor"
    property string accentHighlight: "automatic"
    property string shortcutStyle: "pc"
    property string titlebarDoubleClick: "zoom"
    property bool canMinimize: true
    property int revision: 1
    property bool loading: false
    property bool refreshing: false
    property bool online: true
    property bool metered: false
    property var catalog: ({inUse: true, problem: "", channel: "stable", date: "October 27", old: false})
    property var appData: ({origin: "installed", problem: ""})
    property var user: ({name: "Ada Lovelace", initials: "AL", picture: ""})
    property var sources: ({aur: false, flathub: false, flatpak: false, screenshots: true})
    // The key window: the tests set it (the real backend follows QGuiApplication::focusWindow).
    property var focusWindow: null

    property var calls: []
    property var links: []

    // Step 3 (StoreBackend's operations): the queue, the results, pacman's lock; what each app may do; the plans the sheet
    // gets (set by a test before it asks: {appId: plan}); the apps the tests opened, installed or removed.
    property var operations: []
    property var results: ({})
    property bool staleLock: false
    property var plans: ({})
    property var blocks: ({}) // appId -> {get, uninstall}
    property var entries: ({"photo.desktop": "org.example.Photo"}) // application entry -> app id (appForEntry)
    property var opened: []
    property bool openWorks: true

    signal appearanceChanged
    signal dataChanged
    signal networkChanged
    signal packageInfo(string name, var facts)
    signal planReady(string app, string kind, var plan)
    // The AUR (step 3b2): the tests emit the answers.
    signal aurResults(string term, var apps, string problem)
    signal aurInfo(string id)
    signal buildScript(string id, string text, bool ok)
    property bool aurRead: false
    // Flathub (step 3c): the tests emit flatpak's facts.
    signal flatpakInfo(string id, var facts)

    function requestFlatpakInfo(id) {
        calls.push("flatpakInfo:" + id);
    }

    function stopOperation(opId) {
        calls.push("stop:" + opId);
        operations = operations.filter(o => o.id !== opId || !o.stoppable);
        return true;
    }

    // The search on the backend's worker (SU-06 note): answered after the call returns, as the real one is.
    signal searchResults(string query, var apps)
    property string pendingSearch: ""
    function searchAsync(query) {
        calls.push("searchAsync:" + query);
        pendingSearch = query;
        Qt.callLater(root.answerSearch);
    }
    function answerSearch() {
        searchResults(pendingSearch, search(pendingSearch));
    }

    function searchAur(term) {
        calls.push("searchAur:" + term);
    }

    function requestAur(id) {
        calls.push("requestAur:" + id);
    }

    function requestBuildScript(id) {
        calls.push("buildScript:" + id);
    }

    // grassfield.json for the settings window (Preferences.js): the text the tests set, and what it wrote last.
    property var config: ({exists: false, ok: false, text: ""})
    property string written: ""

    function readConfig() {
        return config;
    }

    function writeConfig(text) {
        written = text;
        return "";
    }

    function actions(id) {
        const a = find(id);
        const b = blocks[id] || {};
        const installed = a ? a.installed : id.startsWith("webapp:") || flatpakUpdates[id] !== undefined;
        return {installed: installed, launcher: a ? a.launcher : installed,
                get: installed ? "installed" : (b.get !== undefined ? b.get : ""), uninstall: b.uninstall !== undefined ? b.uninstall : (installed ? "" : "notInstalled"),
                update: flatpakUpdates[id] !== undefined ? flatpakUpdates[id] : "none"};
    }

    function appForEntry(entry) {
        calls.push("appForEntry:" + entry);
        const key = entry.endsWith(".desktop") ? entry : entry + ".desktop";
        return entries[key] || "";
    }

    function plan(id, kind) {
        calls.push("plan:" + kind + ":" + id);
        if (plans[id] !== undefined)
            planReady(id, kind, plans[id]);
    }

    function install(id) {
        calls.push("install:" + id);
        operations = operations.concat([{id: "op" + operations.length, app: id, name: (find(id) || {}).name || id, kind: "install",
                                         state: operations.length === 0 ? "authorizing" : "waiting", blocked: false, done: 0, total: 2}]);
        return true;
    }

    function uninstall(id) {
        calls.push("uninstall:" + id);
        operations = operations.concat([{id: "op" + operations.length, app: id, name: (find(id) || {}).name || id, kind: "remove",
                                         state: operations.length === 0 ? "running" : "waiting", blocked: false, done: 0, total: 1}]);
        return true;
    }

    function removeWaiting(opId) {
        calls.push("removeWaiting:" + opId);
        operations = operations.filter(o => o.id !== opId || o.state !== "waiting");
        return true;
    }

    function dismiss(id) {
        calls.push("dismiss:" + id);
        const r = Object.assign({}, results);
        delete r[id];
        results = r;
    }

    function open(id) {
        opened.push(id);
        return openWorks;
    }

    function openSoftwareUpdate() {
        calls.push("openSoftwareUpdate");
        return true;
    }

    function quitWhenIdle() {
        calls.push("quitWhenIdle");
    }

    function app_(id, name, kind, installed, launcher) {
        return {id: id, name: name, summary: name + " does one thing well", icon: "", kind: kind, repo: kind === "repo" ? "extra" : "",
            installed: installed, launcher: launcher};
    }

    readonly property var apps: [
        app_("org.example.Paint", "Paint", "repo", false, true),
        app_("org.example.Photo", "Photo Lab", "repo", true, true),
        app_("org.example.Games", "Game Hub", "setup", false, true),
        app_("org.example.Mail", "Mail Web", "webapp", false, true),
        app_("org.example.Tool", "Pack Tool", "repo", true, false),
        app_("aur:example-app-bin", "example-app-bin", "aur", false, false),
        Object.assign(app_("org.example.Notes", "Notes", "flatpak", false, true), {flatpakId: "org.example.Notes"})
    ]

    function find(id) {
        return root.apps.find(a => a.id === id);
    }

    property var sectionList: [
        {id: "discover", title: "Discover", symbol: "discover", blocks: [
            {kind: "hero", items: [{app: find("org.example.Paint"), eyebrow: "Drawing", title: "Paint anything", text: "Brushes for everyone", tint: "#22446A"},
                                   {app: find("org.example.Photo"), eyebrow: "Photos", title: "Develop your photos", text: "Light and colour", tint: ""}]},
            {kind: "cards", items: [{app: find("org.example.Games"), eyebrow: "Games", title: "Your library", text: "All your games", tint: ""},
                                    {app: find("org.example.Mail"), eyebrow: "Mail", title: "Mail in a window", text: "A web app", tint: ""}]},
            {kind: "row", title: "Make something", apps: [find("org.example.Paint"), find("org.example.Photo")]}
        ]},
        {id: "play", title: "Play", symbol: "play", blocks: [{kind: "row", title: "Games", apps: [find("org.example.Games")]}]}
    ]

    function sections() {
        calls.push("sections");
        return root.sectionList;
    }

    // A large category (SU-06): the tests fill it.
    property var manyApps: []

    function categories() {
        return [{id: "graphics", title: "Graphics", symbol: "category-graphics", count: 2},
                {id: "games", title: "Games", symbol: "category-games", count: 1}];
    }

    function categoryApps(id, kind) {
        calls.push("categoryApps:" + id);
        const list = id === "graphics" ? [find("org.example.Paint"), find("org.example.Photo")] : id === "games" ? [find("org.example.Games")]
            : id === "many" ? root.manyApps : [];
        return kind ? list.filter(a => a.kind === kind) : list;
    }

    function search(query) {
        calls.push("search:" + query);
        const q = query.trim().toLowerCase();
        // The local search never holds an AUR page (the AUR answers after Return, searchAur).
        return q === "" ? [] : root.apps.filter(a => a.kind !== "aur" && a.name.toLowerCase().indexOf(q) >= 0);
    }

    function app(id) {
        calls.push("app:" + id);
        const a = find(id);
        if (!a)
            return {};
        return Object.assign({}, a, {description: "A description.\n• A point", developer: "Example Developers", license: "GPL-3.0-or-later",
            homepage: "https://example.org/" + id, bugtracker: "", package: "paint", packages: ["paint"], desktopId: "paint.desktop",
            inCatalog: true, screenshots: ["https://example.org/1.png"], captions: ["The main window"], categories: ["Graphics"],
            releases: [{version: "2.0", date: "October 1, 2026", notes: "Faster."}], languages: ["Deutsch", "français"],
            rated: true, rating: {social: 3}, webUrl: a.kind === "webapp" ? "https://mail.example.com/" : "", flatpakId: a.flatpakId || "",
            runtime: a.kind === "flatpak" ? "org.gnome.Platform 50" : "", verified: a.kind === "flatpak",
            aur: a.kind !== "aur" ? ({}) : {version: "2.4.1-1", maintainer: "alice", orphaned: false, votes: 120, popularity: "1.53",
                lastModified: "September 21, 2026", outOfDate: root.aurRead, outOfDateSince: root.aurRead ? "October 3, 2026" : "",
                base: "example-app-bin", depends: root.aurRead ? ["gtk3", "example-lib"] : []},
            aurRead: root.aurRead, aurUnknown: false,
            setup: a.kind !== "setup" ? ({}) : {install: "omarchy-install-gaming-hub", remove: "omarchy-remove-gaming-hub",
                changes: "Installs Game Hub and the 32-bit graphics drivers for your graphics card.",
                removes: "Game Hub's folders in your home folder, with the games."}});
    }

    function requestPackageInfo(name) {
        calls.push("info:" + name);
    }

    function installed() {
        return [{group: "arch", apps: [Object.assign({page: true}, find("org.example.Photo")), Object.assign({page: true}, find("org.example.Tool"))]},
                {group: "webapp", apps: [{id: "webapp:Notes", name: "Notes", summary: "notes.example.org", icon: "", kind: "webapp",
                    installed: true, launcher: true, page: false}]}];
    }

    // StoreBackend::updates (step 4): Software Update's answer, the shell's check, the Flatpaks' updates, the sidebar's count.
    property var updates: ({state: "available", checkedAt: "10/27/26 9:12 AM", grassfield: {installed: "1.0.0-1", available: "1.0.1-1"},
            omarchy: {installed: "", available: ""}, others: 3, listed: true, truncated: false,
            apps: [Object.assign({from: "1.0-1", to: "1.1-1"}, find("org.example.Photo"))], otherCount: 2,
            checking: false, askFailed: false, running: false, unfinished: 0,
            flatpak: {on: true, state: "", runtimes: 1, block: "",
                      apps: [{id: "flatpak:org.example.Draw", name: "Draw", summary: "", icon: "", kind: "flatpak", installed: true,
                              launcher: true, page: false, ref: "app/org.example.Draw/x86_64/stable"}]},
            count: 2})
    // The Flatpak ids actions() says have an update ("" when it runs now, else why not).
    property var flatpakUpdates: ({})

    function checkUpdates() {
        calls.push("checkUpdates");
    }

    function updatesShown(shown) {
        calls.push("updatesShown:" + shown);
    }

    function update(id) {
        calls.push("update:" + id);
        operations = operations.concat([{id: "op" + operations.length, app: id, name: (find(id) || {}).name || id, kind: "update",
                                         path: "flatpak", state: "running", blocked: false, done: 0, total: 1}]);
        return true;
    }

    function typeSearch(type) {
        calls.push("typeSearch:" + type);
        return type === "image/png" ? {type: type, description: "PNG image", apps: [find("org.example.Photo")]}
                                    : {type: type, description: type, apps: []};
    }

    function refresh() {
        calls.push("refresh");
    }

    function openLink(url) {
        links.push(url);
        return false;
    }

    function screenshotSource(url) {
        return "";
    }
}
