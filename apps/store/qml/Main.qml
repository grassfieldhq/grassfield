pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Store.js" as Store
import "StoreNav.js" as StoreNav

// Grassfield Store (ADR-0037, spec SR1-SR12, SR23, SR24): the sidebar (search, Discover, the catalog's sections, Categories,
// Updates, the local user's row for Installed) and the page on the right, with Back and Forward in the toolbar. App windows
// are opaque (master-prompt 5.5). Step 2 reads only: no app is installed, removed or opened from here yet.
Window {
    id: root

    // Set by the launcher (src/main.cpp).
    required property var backend
    // The registrar is there (kept up to date by src/main.cpp): the window exports its menus to the global menu bar.
    required property bool globalMenu
    // --page: the page to open first (discover, section:<id>, categories, category:<id>, app:<id>, search:<words>,
    // installed, updates).
    property string startPage: ""
    // ADR-0015: this window draws its own chrome (the lights over the sidebar, the toolbar over the page).
    property string gfChromeRole: "store"
    readonly property alias searchField: sidebar.search
    // The page shown and its kind (section, categories, category, app, search, installed, updates); the tests read them.
    readonly property alias page: pageLoader.item
    readonly property alias pageKind: pageLoader.page

    title: qsTr("Grassfield Store")
    width: Tokens.storeWindowWidth
    height: Tokens.storeWindowHeight
    minimumWidth: Tokens.storeWindowMinWidth
    minimumHeight: Tokens.storeWindowMinHeight
    visible: true
    color: Appearance.colors.windowBackground

    // ---- Data, read again at each new snapshot (StoreBackend::dataChanged).
    property var sections: []
    property var categories: []

    readonly property var sidebarItems: root.sections.map(s => ({
                key: "section:" + s.id,
                page: "section",
                id: s.id,
                title: s.builtIn ? qsTr("Discover") : s.title,
                icon: Store.symbolIcon(s.symbol)
            })).concat([{key: "categories", page: "categories", id: "", title: qsTr("Categories"), icon: "grid"},
                {key: "updates", page: "updates", id: "", title: qsTr("Updates"), icon: "arrow-down-circle", count: root.backend.updates.count || 0}])

    // A new snapshot (SU-06): the page shown is not made again; its data bindings read the backend again (dataRevision),
    // and its lists change in place (AppGrid's keyed model), so nothing under the pointer is re-created and the scroll stays.
    property int dataRevision: 0

    function reload(): void {
        root.sections = root.backend.sections();
        root.categories = root.backend.categories();
        root.dataRevision++;
        if (pageLoader.page === "search" && pageLoader.item)
            root.requestSearch((pageLoader.item as SearchPage).query, true);
        // --page waits for the first data: a section's row exists only then.
        if (root.waitingPage !== "" && root.backend.revision > 0) {
            const page = root.waitingPage;
            root.waitingPage = "";
            root.openPage(page);
        }
    }

    property string waitingPage: ""

    Connections {
        target: root.backend
        function onDataChanged(): void {
            root.reload();
        }
    }

    // ---- Navigation (StoreNav.js): pages with their scroll, the sidebar row each belongs to.
    property var nav: StoreNav.start({page: "section", id: "discover", tab: "section:discover"})
    readonly property bool canBack: StoreNav.canBack(root.nav)
    readonly property bool canForward: StoreNav.canForward(root.nav)
    // Read in handlers through root.nav.current: a handler of navChanged may run before this binding is updated.
    readonly property var current: root.nav.current

    function currentScroll(): real {
        return (pageLoader.item as ScrollPage)?.scroll ?? 0;
    }

    function visit(entry: var): void {
        root.nav = StoreNav.visit(root.nav, entry, root.currentScroll());
    }

    function pick(key: string): void {
        const item = root.sidebarItems.find(i => i.key === key);
        if (!item)
            return;
        sidebar.search.text = "";
        root.visit({page: item.page, id: item.id, tab: key});
    }

    function openApp(id: string): void {
        root.visit({page: "app", id: id, tab: root.nav.current.tab});
    }

    function openCategory(id: string): void {
        sidebar.search.text = "";
        root.visit({page: "category", id: id, tab: "categories"});
    }

    function openInstalled(): void {
        sidebar.search.text = "";
        root.visit({page: "installed", id: "", tab: ""});
    }

    function goBack(): void {
        root.nav = StoreNav.back(root.nav, root.currentScroll());
        root.syncSearchField();
    }

    function goForward(): void {
        root.nav = StoreNav.forward(root.nav, root.currentScroll());
        root.syncSearchField();
    }

    // The field shows the query of a search page and is empty elsewhere.
    function syncSearchField(): void {
        sidebar.search.text = root.nav.current.page === "search" ? root.nav.current.query : "";
    }

    // Typing searches at once (SR6): the first key opens the results page, the next ones change it in place; clearing the
    // field goes back to the page before it.
    function search(text: string): void {
        if (text.trim() === "") {
            if (root.nav.current.page === "search")
                root.goBack();
            return;
        }
        const entry = {page: "search", id: "", query: text, tab: root.nav.current.tab};
        root.nav = root.nav.current.page === "search" ? StoreNav.replace(root.nav, entry) : StoreNav.visit(root.nav, entry, root.currentScroll());
    }

    function focusSearch(): void {
        sidebar.search.forceActiveFocus(Qt.ShortcutFocusReason);
        sidebar.search.selectAll();
    }

    // ---- Get, Open and Uninstall… (spec SR13-SR22): the sheet asks first (OperationSheet), the backend's queue runs
    // (operations.h). An app's button, its product page and its context menu call these.
    function requestGet(app: var): void {
        opSheet.show(Object.assign({}, app, root.backend.app(app.id)), "install");
    }

    function requestUninstall(app: var): void {
        opSheet.show(Object.assign({}, app, root.backend.app(app.id)), "remove");
    }

    // "--page=uninstall:<application entry>" (ADR-0046 D1): the launcher or Files asks, from another process, so this only OPENS the
    // Store's own alert (OperationSheet, handedOver): the app by its Store name and icon, the packages -Rns takes, Cancel the
    // default. Nothing runs until Delete is pressed here. An entry the Store does not know is said in the notice bar.
    function uninstallEntry(entry: string): void {
        // A sheet already open keeps its app: a second hand-over (any peer can send one) must not switch what the user is about
        // to confirm. The window still comes forward (main.cpp), and the user asks again once the alert is answered.
        if (opSheet.visible)
            return;
        const id = root.backend.appForEntry(entry);
        const app = id === "" ? null : root.backend.app(id);
        if (!app || app.id === undefined) {
            root.transientNotice = qsTr("The Store can't uninstall this app.");
            return;
        }
        opSheet.show(Object.assign({}, app, root.backend.app(id)), "remove", true);
    }

    // A Flatpak's Update, and Update All of the Flatpak group (step 4): the sheet asks only when an update lets an app reach
    // more than before (OperationSheet.showUpdate).
    function requestUpdate(app: var): void {
        opSheet.showUpdate(Object.assign({}, app, root.backend.app(app.id)));
    }

    function updateAllFlatpaks(): void {
        opSheet.showUpdate({id: "store:flatpak-updates", name: qsTr("Flatpak apps"), kind: "flatpak"});
    }

    // The search by document type (ADR-0035 5c-3): Files' "Search the Store" opens it (--page=type:<type>).
    function openType(type: string): void {
        sidebar.search.text = "";
        root.visit({page: "type", id: type, tab: ""});
    }

    function launchApp(app: var): void {
        if (!root.backend.open(app.id))
            root.transientNotice = qsTr("“%1” could not be opened.").arg(app.name || "");
    }

    // The search runs on the backend's worker (SU-06 note): typing waits for a pause of a few keys before it asks; the answer
    // fills the results page when its query is still the one shown (searchResults). `now`: asked at once (a page opened on
    // a query, a new snapshot).
    property string pendingQuery: ""
    function requestSearch(query: string, now: bool): void {
        if (pageLoader.page === "search" && pageLoader.item)
            (pageLoader.item as SearchPage).searching = true;
        root.pendingQuery = query;
        if (now) {
            searchDelay.stop();
            root.backend.searchAsync(query);
        } else {
            searchDelay.restart();
        }
    }

    Timer {
        id: searchDelay
        interval: 120 // a pause between keys (logic, not a design value: ADR-0039 D7)
        onTriggered: root.backend.searchAsync(root.pendingQuery)
    }

    // pacman's message and what to do, for the last operation of an app (SR19).
    // The AUR (SR7): Return on the search field asks it for the query on the page; its answer fills that page's section
    // when the query has not changed meanwhile.
    function searchAur(): void {
        if (pageLoader.page !== "search" || !pageLoader.item || !root.backend.sources.aur)
            return;
        const results = pageLoader.item as SearchPage;
        results.aurState = "asking";
        results.aurResults = [];
        root.backend.searchAur(results.query);
    }

    Connections {
        target: root.backend
        function onAurResults(term: string, apps: var, problem: string): void {
            if (pageLoader.page !== "search" || !pageLoader.item)
                return;
            const results = pageLoader.item as SearchPage;
            if (results.query !== term)
                return;
            results.aurResults = apps;
            results.aurState = problem === "" ? "done" : problem;
        }
        function onSearchResults(query: string, apps: var): void {
            if (pageLoader.page !== "search" || !pageLoader.item)
                return;
            const results = pageLoader.item as SearchPage;
            if (results.query !== query)
                return;
            results.results = apps;
            results.searching = false;
        }
        function onBuildScript(id: string, text: string, ok: bool): void {
            if (id === root.buildScriptFor && textSheet.visible)
                textSheet.text = ok ? text : qsTr("The build script could not be fetched. Try again later.");
        }
    }

    // An AUR package's build script (its PKGBUILD, SR11), fetched when asked, shown as plain text (ADR-0037 e.6).
    property string buildScriptFor: ""
    function showBuildScript(app: var): void {
        root.buildScriptFor = app.id;
        textSheet.show(qsTr("Build Script of “%1”").arg(app.name),
                       qsTr("The script yay runs to build this package, as the AUR has it now. Read it before you install it: yay fetches it again when it builds, and the package's other files, such as a script run with administrator rights when it is installed, are not shown here."),
                       qsTr("Loading…"));
        root.backend.requestBuildScript(app.id);
    }

    function showDetails(id: string): void {
        const r = root.backend.results[id];
        if (r)
            textSheet.show(Store.resultText(r) || qsTr("Details"), r.name || "", r.details || qsTr("No message was recorded."));
    }

    // The context menu of an installed app's item (SR22), at (x, y) in `item`'s coordinates.
    function showAppMenu(app: var, item: Item, x: real, y: real): void {
        const actions = root.backend.actions(app.id);
        if (!actions.installed)
            return;
        const items = [];
        if (actions.launcher)
            items.push({id: "open", text: qsTr("Open")});
        if (app.page !== false)
            items.push({id: "page", text: qsTr("Show in Store")});
        items.push({separator: true});
        items.push({id: "uninstall", text: qsTr("Uninstall…"), enabled: actions.uninstall === "" && !root.backend.operations.some(o => o.app === app.id)});
        appMenu.app = app;
        appMenu.items = items;
        appMenu.focusBack = item;
        const p = item.mapToItem(root.contentItem, x, y);
        appMenu.openAt(p.x, p.y);
    }

    // A notice that goes after a while (an app that could not be opened).
    property string transientNotice: ""
    Timer {
        running: root.transientNotice !== ""
        interval: Tokens.storeNoticeLifetime
        onTriggered: root.transientNotice = ""
    }
    // How an operation ended, while it says something (the latest one first), and a lock pacman left (SR19, SR20).
    readonly property var resultIds: Object.keys(root.backend.results || {}).filter(id => Store.resultText(root.backend.results[id]) !== "")

    onNavChanged: root.showPage()

    // The page of `current`: a search page that only changes its query keeps its item (its results come from the worker
    // once typing pauses); anything else is made again, and gets back the scroll it was left at. A new snapshot never comes
    // here (reload: the page is updated in place).
    function showPage(): void {
        const c = root.nav.current;
        if (c.page === "search" && pageLoader.item && pageLoader.page === "search") {
            const results = pageLoader.item as SearchPage;
            if (results.query !== c.query) {
                results.aurState = "";
                results.aurResults = [];
            }
            results.query = c.query;
            root.requestSearch(c.query, false);
            return;
        }
        const scroll = c.scroll || 0;
        pageLoader.page = c.page;
        // The page reads this copy, not `current`: a page being replaced never sees the next page's entry.
        pageLoader.entry = c;
        pageLoader.sourceComponent = null;
        pageLoader.sourceComponent = c.page === "section" ? sectionPage : c.page === "categories" ? categoriesPage
            : c.page === "category" ? categoryPage : c.page === "app" ? productPage : c.page === "search" ? searchPage
            : c.page === "installed" ? installedPage : c.page === "updates" ? updatesPage : c.page === "type" ? typePage : null;
        if (pageLoader.item && scroll > 0)
            (pageLoader.item as ScrollPage).restoreScroll(scroll);
        if (c.page === "search")
            root.requestSearch(c.query || "", true);
    }

    function openPage(page: string): void {
        const colon = page.indexOf(":");
        const kind = colon < 0 ? page : page.substring(0, colon);
        const arg = colon < 0 ? "" : page.substring(colon + 1);
        if (kind === "section" || kind === "categories" || kind === "updates")
            root.pick(kind === "section" ? "section:" + arg : kind);
        else if (kind === "category")
            root.openCategory(arg);
        else if (kind === "app")
            root.openApp(arg);
        else if (kind === "installed")
            root.openInstalled();
        else if (kind === "uninstall")
            root.uninstallEntry(arg);
        else if (kind === "type" && /^[a-z0-9][a-z0-9!#$&^_.+-]{0,126}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,126}$/.test(arg.toLowerCase()))
            root.openType(arg.toLowerCase());
        else if (kind === "search") {
            sidebar.search.text = arg;
            root.search(arg);
        }
    }

    Component.onCompleted: {
        root.waitingPage = root.startPage;
        root.reload();
    }

    // ---- Settings window (Ctrl+,).
    property var settingsWindow: null

    function openSettings(): void {
        if (!root.settingsWindow)
            root.settingsWindow = settingsComponent.createObject(root, {backend: root.backend, transientParent: root});
        root.settingsWindow.show();
        root.settingsWindow.raise();
        root.settingsWindow.requestActivate();
    }

    Component {
        id: settingsComponent
        SettingsWindow {}
    }

    // ---- Appearance (grassfield.json, read by the backend) and the window's own surface.
    Binding {
        target: Appearance
        property: "windowSurface"
        value: true
    }

    Binding {
        target: Appearance
        property: "transparency"
        value: 0
    }

    Binding {
        target: Appearance
        property: "dark"
        value: root.backend.dark
    }

    Binding {
        target: Appearance
        property: "reduceMotion"
        value: root.backend.reduceMotion
    }

    Binding {
        target: Appearance
        property: "increaseContrast"
        value: root.backend.increaseContrast
    }

    Binding {
        target: Appearance
        property: "textScale"
        value: root.backend.textScale
    }

    Binding {
        target: Appearance
        property: "accentSetting"
        value: root.backend.accentColor
    }

    Binding {
        target: Appearance
        property: "highlightSetting"
        value: root.backend.accentHighlight
    }

    Binding {
        target: Appearance
        property: "shortcutStyle"
        value: root.backend.shortcutStyle
    }

    // ---- Keyboard (spec "Keyboard"). The global menu's items carry the same shortcuts; each acts once. The window keeps its
    // own Shortcuts beside the menu's (as Files), so every key works whatever the menu path: with the global menu bar, without
    // its registrar, and when the shell shows the menu bar but not the app's menus.
    Loader {
        active: root.globalMenu
        sourceComponent: GlobalMenu {
            win: root
        }
        // One log line per change, as Files (the menu bar exists only while the registrar does).
        onItemChanged: console.info("grassfield: global menu " + (item ? "created" : "destroyed"))
    }

    // The settings window is the key window (the backend's focusWindow; never `active`: Qt reports a window and its transient
    // children active together). Qt still matches this window's Shortcuts and its global menu's keys then, so they wait: Ctrl+W
    // typed in the settings would close the Store (Files' BrowserWindow.childIsKey). The settings window's own keys wait while
    // this one is the key window.
    readonly property bool childIsKey: root.settingsWindow !== null && root.backend.focusWindow === root.settingsWindow

    component Key: Shortcut {
        property var run: null
        enabled: !root.childIsKey
        onActivated: run()
        onActivatedAmbiguously: run()
    }

    Key {
        sequence: "Ctrl+F"
        run: root.focusSearch
    }
    Key {
        sequence: "Ctrl+R"
        run: () => root.backend.refresh()
    }
    Key {
        sequences: ["Ctrl+[", "Alt+Left"]
        run: root.goBack
    }
    Key {
        sequences: ["Ctrl+]", "Alt+Right"]
        run: root.goForward
    }
    Key {
        sequence: "Ctrl+,"
        run: root.openSettings
    }
    Key {
        sequence: "Ctrl+W"
        run: () => root.close()
    }
    // A running operation goes on (ADR-0037 f): the Store quits once it ended.
    Key {
        sequence: "Ctrl+Q"
        run: () => root.backend.quitWhenIdle()
    }

    // Ctrl+1 … Ctrl+9: the sidebar's items in order.
    Repeater {
        model: 9

        delegate: Item {
            id: digit
            required property int index

            Shortcut {
                sequence: "Ctrl+" + (digit.index + 1)
                enabled: !root.childIsKey && digit.index < root.sidebarItems.length
                onActivated: root.pick(root.sidebarItems[digit.index].key)
                onActivatedAmbiguously: root.pick(root.sidebarItems[digit.index].key)
            }
        }
    }

    // ---- Layout.
    Sidebar {
        id: sidebar
        height: parent.height
        win: root
        items: root.sidebarItems
        selectedKey: root.current.tab || ""
        user: root.backend.user
        installedShown: root.current.page === "installed"
        onPicked: key => root.pick(key)
        onAccountPicked: root.openInstalled()
        onQueryEdited: text => root.search(text)
        onQueryAccepted: {
            if (pageLoader.page === "search" && pageLoader.item) {
                root.searchAur();
                (pageLoader.item as SearchPage).focusFirst();
            }
        }
    }

    Item {
        id: detail
        x: sidebar.width
        width: parent.width - sidebar.width
        height: parent.height

        Loader {
            id: pageLoader
            property string page: ""
            property var entry: ({})
            anchors.fill: parent
            focus: true
        }

        // The catalogue still loading: the shared spinner over its line once nothing has shown for store.loadingDelay, as Files'
        // loading note (UI audit 2026-11-05, LOW: the line flashed at every quick start).
        Item {
            id: loadingNote
            readonly property bool waiting: root.backend.loading && root.sections.length === 0
            property bool delayed: false

            anchors.fill: parent
            visible: loadingNote.waiting && loadingNote.delayed
            onWaitingChanged: if (!loadingNote.waiting)
                loadingNote.delayed = false

            Timer {
                interval: Tokens.storeLoadingDelay
                running: loadingNote.waiting && !loadingNote.delayed
                onTriggered: loadingNote.delayed = true
            }

            Column {
                anchors.centerIn: parent
                spacing: Tokens.spacingSm

                Spinner {
                    anchors.horizontalCenter: parent.horizontalCenter
                    running: loadingNote.visible
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    textFormat: Text.PlainText
                    text: qsTr("Loading apps…")
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.storeBodySize
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }
            }
        }

        // How an operation ended (the latest result that says something), pacman's lock left behind, an app that could not
        // be opened (SR19, SR20): one line above the offline notice, with what can be done.
        NoticeBar {
            id: operationNotice
            objectName: "operationNotice"
            // The app whose page is shown has the line under its button (ProductPage.qml): not twice.
            readonly property var others: root.resultIds.filter(id => !(pageLoader.page === "app" && pageLoader.entry.id === id))
            readonly property string resultId: others.length > 0 ? others[others.length - 1] : ""
            readonly property var result: resultId !== "" ? root.backend.results[resultId] : null
            width: Math.min(implicitWidth, parent.width - 2 * Tokens.storeContentMargin)
            x: Math.round((parent.width - width) / 2)
            y: offlineNotice.y - height - (offlineNotice.visible ? Tokens.spacingSm : 0)
            text: {
                if (root.transientNotice !== "")
                    return root.transientNotice;
                if (result)
                    return "“" + (result.name || resultId) + "”: " + Store.resultText(result);
                return root.backend.staleLock ? qsTr("A package manager stopped mid-way and left its lock: nothing installs until it goes.") : "";
            }
            actions: {
                if (root.transientNotice !== "")
                    return [];
                if (result && Store.needsUpdate(result))
                    return [{id: "update", text: qsTr("Update Now…")}, {id: "close", text: qsTr("Close")}];
                if (result)
                    return (Store.canTryAgain(result) ? [{id: "again", text: qsTr("Try Again")}] : [])
                        .concat([{id: "details", text: qsTr("Details…")}, {id: "close", text: qsTr("Close")}]);
                return root.backend.staleLock ? [{id: "lock", text: qsTr("Details…")}] : [];
            }
            onActed: id => {
                const r = result;
                const app = resultId;
                if (id === "again") {
                    root.backend.dismiss(app);
                    const a = Object.assign({id: app, name: r.name}, root.backend.app(app));
                    if (r.kind === "remove")
                        root.requestUninstall(a);
                    else if (r.kind === "update" && app === "store:flatpak-updates")
                        root.updateAllFlatpaks();
                    else if (r.kind === "update")
                        root.requestUpdate(a);
                    else
                        root.requestGet(a);
                } else if (id === "details") {
                    root.showDetails(app);
                } else if (id === "update") {
                    root.backend.dismiss(app); // its page offers Get again once the system is up to date
                    root.backend.openSoftwareUpdate();
                } else if (id === "close") {
                    root.backend.dismiss(app);
                } else if (id === "lock") {
                    textSheet.show(qsTr("A package manager stopped mid-way"),
                                   qsTr("pacman's lock file is still there, but no pacman is running. If nothing is installing or updating (Software Update included), remove the lock in a terminal, then try again:"),
                                   "sudo rm /var/lib/pacman/db.lck");
                }
            }
        }

        // Offline, or a catalog older than 30 days (SR29): one line at the bottom of the page.
        NoticeBar {
            id: offlineNotice
            objectName: "offlineNotice"
            width: Math.min(implicitWidth, parent.width - 2 * Tokens.storeContentMargin)
            x: Math.round((parent.width - width) / 2)
            y: parent.height - height - Tokens.storeNoticeBottom
            text: {
                const c = root.backend.catalog;
                if (!root.backend.online)
                    return c.inUse ? qsTr("You're offline. The catalog is from %1.").arg(c.date) : qsTr("You're offline.");
                if (c.inUse && c.old)
                    return qsTr("The catalog is from %1 and may be out of date.").arg(c.date);
                // No catalog, Discover from Arch's app data alone (ADR-0037 "Offline"); an empty page says it itself.
                if (!c.inUse && root.sections.length > 0 && (root.sections[0].blocks || []).length > 0)
                    return qsTr("The Grassfield catalog isn't available: Arch's apps are shown.");
                return "";
            }
        }

        UnifiedToolbar {
            id: toolbar
            width: parent.width
            window: root
            showControls: false
            showTitle: false
            canMinimize: root.backend.canMinimize
            doubleClickAction: root.backend.titlebarDoubleClick

            // Back and forward: one glass capsule with a hairline between them (macOS 27), shown once there is somewhere to go.
            leading: RimmedCapsule {
                visible: root.canBack || root.canForward
                width: navRow.width + Tokens.spacingXs
                height: Tokens.toolbarCapsule
                fillOpacity: Tokens.toolbarCapsuleFillOpacity
                Accessible.role: Accessible.Grouping
                Accessible.name: qsTr("Navigation")

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.hairline
                    height: Tokens.toolbarDividerHeight
                    color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.toolbarDividerOpacity)
                }

                Row {
                    id: navRow
                    anchors.centerIn: parent

                    ToolButton {
                        capsule: true
                        buttonSize: Tokens.toolbarGroupButton
                        navigation: "back"
                        enabled: root.canBack
                        accessibleName: qsTr("Back")
                        onClicked: root.goBack()
                    }

                    ToolButton {
                        capsule: true
                        buttonSize: Tokens.toolbarGroupButton
                        navigation: "forward"
                        enabled: root.canForward
                        accessibleName: qsTr("Forward")
                        onClicked: root.goForward()
                    }
                }
            }

            trailing: Row {
                spacing: Tokens.spacingXs

                // The queue (SR18): what runs and what waits; a waiting operation can leave it, a running Flatpak install stop.
                ToolButton {
                    id: queueButton
                    visible: root.backend.operations.length > 0
                    iconName: "arrow-down-circle"
                    accessibleName: qsTr("Installations: %1").arg(root.backend.operations.length)
                    onClicked: {
                        const items = [];
                        for (const op of root.backend.operations) {
                            items.push({id: "", text: (op.name || op.app) + " — " + Store.operationText(op), enabled: false});
                            if (op.state === "waiting")
                                items.push({id: op.id, text: op.kind === "remove" ? qsTr("Don't Uninstall “%1”").arg(op.name) : qsTr("Don't Install “%1”").arg(op.name)});
                            else if (op.stoppable)
                                items.push({id: "stop:" + op.id, text: op.kind === "update" ? qsTr("Stop Updating “%1”").arg(op.name)
                                                                                         : qsTr("Stop Installing “%1”").arg(op.name)});
                        }
                        queueMenu.items = items;
                        queueMenu.focusBack = queueButton;
                        const p = queueButton.mapToItem(root.contentItem, 0, queueButton.height + Tokens.spacingXs);
                        queueMenu.openAt(Math.min(p.x, root.width - queueMenu.width - Tokens.spacingSm), p.y);
                    }
                }

                // Without a global menu bar (no registrar), the way to the settings that File > Settings… gives.
                ToolButton {
                    visible: !root.globalMenu
                    iconName: "gear"
                    accessibleName: qsTr("Store Settings")
                    onClicked: root.openSettings()
                }
            }
        }
    }

    // ---- The pages.
    Component {
        id: sectionPage
        SectionPage {
            section: root.sections.find(s => s.id === pageLoader.entry.id) || root.sections[0] || ({id: "discover", builtIn: true, blocks: []})
            loading: root.backend.loading
            catalog: root.backend.catalog
            appData: root.backend.appData
            online: root.backend.online
            onOpened: id => root.openApp(id)
            onCategoryRequested: id => root.openCategory(id)
            onRetry: root.backend.refresh()
            onSoftwareUpdateRequested: root.backend.openSoftwareUpdate()
        }
    }

    Component {
        id: categoriesPage
        CategoriesPage {
            categories: root.categories
            onCategoryRequested: id => root.openCategory(id)
        }
    }

    Component {
        id: categoryPage
        CategoryPage {
            categoryTitle: (root.categories.find(c => c.id === pageLoader.entry.id) || {title: ""}).title
            apps: root.dataRevision >= 0 ? root.backend.categoryApps(pageLoader.entry.id) : []
            kind: pageLoader.entry.kind || ""
            onOpened: id => root.openApp(id)
            onKindPicked: kind => root.nav = StoreNav.replace(root.nav, Object.assign({}, root.current, {kind: kind}))
        }
    }

    Component {
        id: productPage
        ProductPage {
            backend: root.backend
            app: root.dataRevision >= 0 ? root.backend.app(pageLoader.entry.id) : ({})
            onAppStale: root.dataRevision++
            onLinkRequested: url => root.backend.openLink(url)
            onBuildScriptRequested: app => root.showBuildScript(app)
            onUninstallRequested: app => root.requestUninstall(app)
            onDetailsRequested: id => root.showDetails(id)
            onSoftwareUpdateRequested: id => {
                root.backend.dismiss(id);
                root.backend.openSoftwareUpdate();
            }
            onTryAgainRequested: (app, kind) => {
                root.backend.dismiss(app.id);
                if (kind === "remove")
                    root.requestUninstall(app);
                else
                    root.requestGet(app);
            }
        }
    }

    Component {
        id: searchPage
        SearchPage {
            query: pageLoader.entry.query || ""
            searching: true
            aurOn: root.backend.sources.aur === true
            onOpened: id => root.openApp(id)
        }
    }

    Component {
        id: installedPage
        InstalledPage {
            groups: root.dataRevision >= 0 ? root.backend.installed() : []
            onOpened: id => root.openApp(id)
        }
    }

    Component {
        id: updatesPage
        UpdatesPage {
            updates: root.backend.updates
            onOpened: id => root.openApp(id)
            onCheckRequested: root.backend.checkUpdates()
            onSoftwareUpdateRequested: root.backend.openSoftwareUpdate()
            onFlatpakUpdateAllRequested: root.updateAllFlatpaks()
            Component.onCompleted: root.backend.updatesShown(true)
            Component.onDestruction: root.backend.updatesShown(false)
        }
    }

    Component {
        id: typePage
        TypePage {
            search: root.dataRevision >= 0 ? root.backend.typeSearch(pageLoader.entry ? pageLoader.entry.id : "") : ({})
            onOpened: id => root.openApp(id)
        }
    }

    // ---- Sheets and menus over the window.
    OperationSheet {
        id: opSheet
        backend: root.backend
    }

    TextSheet {
        id: textSheet
    }

    MenuPopup {
        id: appMenu
        property var app: null
        accessibleName: qsTr("App")
        onChosen: id => {
            if (id === "open")
                root.launchApp(appMenu.app);
            else if (id === "page")
                root.openApp(appMenu.app.id);
            else if (id === "uninstall")
                root.requestUninstall(appMenu.app);
        }
    }

    MenuPopup {
        id: queueMenu
        accessibleName: qsTr("Installations")
        onChosen: id => {
            if (id.startsWith("stop:"))
                root.backend.stopOperation(id.slice(5)); // a Flatpak install that runs (SD26)
            else if (id !== "")
                root.backend.removeWaiting(id);
        }
    }
}
