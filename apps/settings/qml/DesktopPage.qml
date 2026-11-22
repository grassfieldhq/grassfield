pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Dialogs
import Grassfield.Ui
import "DefaultBrowser.js" as DefaultBrowser
import "DefaultApps.js" as DefaultApps

// Settings > Desktop & Dock as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Desktop & Dock): Dock (Size
// and Magnification side by side; the Dock's position, the minimize animation, the title bar's double click and minimizing
// into the app's icon; then how the Dock behaves), the folders kept in the Dock (Grassfield's own), Desktop & Stages,
// Windows, and the Screen Corners… sheet (macOS: Hot Corners…; screenCornersRequested, Main opens it).
SettingsPage {
    id: root

    required property var store
    // The Settings backend (files and folders); null in a test of the rest of the page: the browser row is then not shown.
    property var backend: null

    signal screenCornersRequested

    title: qsTr("Desktop & Dock")

    // Magnification as one slider (macOS 27): Off at its start, then Small (dockMagnificationSmallAt of the knob's travel) to
    // Large, the largest magnification the schema allows. A position between Off and Small goes to the nearer of the two.
    readonly property real magnificationLarge: SettingsContract.RULES["dock.magnification"].max
    readonly property real magnificationPosition: {
        if (!root.store.value("dock.magnificationEnabled"))
            return 0;
        const m = Math.max(Tokens.settingsDockMagnificationSmall, root.store.value("dock.magnification"));
        return Tokens.settingsDockMagnificationSmallAt + (1 - Tokens.settingsDockMagnificationSmallAt) * (m - Tokens.settingsDockMagnificationSmall) / (root.magnificationLarge - Tokens.settingsDockMagnificationSmall);
    }

    function setMagnification(position: real): void {
        const small = Tokens.settingsDockMagnificationSmallAt;
        if (position < small / 2) {
            root.store.setManySoon({"dock.magnificationEnabled": false});
            return;
        }
        const t = Math.max(0, (position - small) / (1 - small));
        const m = Math.round((Tokens.settingsDockMagnificationSmall + t * (root.magnificationLarge - Tokens.settingsDockMagnificationSmall)) * 100) / 100;
        root.store.setManySoon({"dock.magnificationEnabled": true, "dock.magnification": m});
    }

    SettingsGroup {
        caption: qsTr("Dock")

        Item {
            width: parent.width
            height: Tokens.settingsDockSlidersHeight

            DockSlider {
                x: Tokens.settingsRowInset
                width: Tokens.settingsDockSizeSliderWidth
                title: qsTr("Size")
                labels: [{text: qsTr("Small"), at: 0}, {text: qsTr("Large"), at: 1}]
                slider.from: Tokens.dockSizeMin
                slider.to: Tokens.dockSizeMax
                slider.stepSize: 1 / (Tokens.dockSizeMax - Tokens.dockSizeMin)
                slider.ticks: 2
                slider.value: root.store.value("dock.size")
                slider.onMoved: v => root.store.setSoon("dock.size", Math.round(v))
                slider.onReleased: root.store.flush()
            }

            DockSlider {
                x: Tokens.settingsDockMagnificationX
                width: parent.width - x - Tokens.settingsRowInset
                title: qsTr("Magnification")
                labels: [{text: qsTr("Off"), at: 0}, {text: qsTr("Small"), at: Tokens.settingsDockMagnificationSmallAt}, {text: qsTr("Large"), at: 1}]
                slider.from: 0
                slider.to: 1
                slider.stepSize: 0.05
                slider.tickValues: [Tokens.settingsDockMagnificationSmallAt, 1]
                slider.value: root.magnificationPosition
                slider.onMoved: v => root.setMagnification(v)
                slider.onReleased: root.store.flush()
            }
        }
    }

    SettingsGroup {
        SettingsRow {
            title: qsTr("Dock position on screen")
            ComboBox {
                inline: true
                accessibleName: qsTr("Dock position on screen")
                model: [{id: "left", text: qsTr("Left")}, {id: "bottom", text: qsTr("Bottom")}, {id: "right", text: qsTr("Right")}]
                value: root.store.value("dock.position")
                onPicked: id => root.store.set("dock.position", id)
            }
        }

        SettingsRow {
            title: qsTr("Minimized window animation")
            ComboBox {
                inline: true
                accessibleName: qsTr("Minimized window animation")
                model: [{id: "funnel", text: qsTr("Funnel")}, {id: "shrink", text: qsTr("Shrink")}]
                value: root.store.value("dock.minimizeEffect")
                onPicked: id => root.store.set("dock.minimizeEffect", id)
            }
        }

        SettingsRow {
            title: qsTr("Window title bar double-click action")
            ComboBox {
                inline: true
                accessibleName: qsTr("Window title bar double-click action")
                // Fill (TL32; the default, ADR-0036 D78): the window takes the whole usable area of its display, tiled with
                // the margins, and a second double-click brings back its size. Zoom does the same since D78 (TL35).
                model: [{id: "fill", text: qsTr("Fill")}, {id: "zoom", text: qsTr("Zoom")}, {id: "minimize", text: qsTr("Minimize")}, {id: "none", text: qsTr("No Action")}]
                value: root.store.value("windows.titlebarDoubleClick")
                onPicked: id => root.store.set("windows.titlebarDoubleClick", id)
            }
        }

        SettingsRow {
            title: qsTr("Minimize windows into application icon")
            Toggle {
                accessibleName: qsTr("Minimize windows into application icon")
                checked: root.store.value("dock.minimizeIntoApp")
                onToggled: c => root.store.set("dock.minimizeIntoApp", c)
            }
        }
    }

    SettingsGroup {
        SettingsRow {
            title: qsTr("Automatically hide and show the Dock")
            Toggle {
                accessibleName: qsTr("Automatically hide and show the Dock")
                checked: root.store.value("dock.autohide")
                onToggled: c => root.store.set("dock.autohide", c)
            }
        }

        SettingsRow {
            title: qsTr("Click an open app’s icon to minimize its windows")
            Toggle {
                accessibleName: qsTr("Click an open app’s icon to minimize its windows")
                checked: root.store.value("dock.clickMinimizes")
                onToggled: c => root.store.set("dock.clickMinimizes", c)
            }
        }

        SettingsRow {
            title: qsTr("Animate opening applications")
            Toggle {
                accessibleName: qsTr("Animate opening applications")
                checked: root.store.value("dock.animateOpening")
                onToggled: c => root.store.set("dock.animateOpening", c)
            }
        }

        SettingsRow {
            title: qsTr("Show indicators for open applications")
            Toggle {
                accessibleName: qsTr("Show indicators for open applications")
                checked: root.store.value("dock.showIndicators")
                onToggled: c => root.store.set("dock.showIndicators", c)
            }
        }

        // Whether apps stay in the Dock after they quit (the owner's question, 2026-11-07): the macOS switch, which says so under
        // its title. Off, an app that is not kept in the Dock leaves it when it quits; the Dock follows the switch at once.
        SettingsRow {
            title: qsTr("Show recent apps in Dock")
            subtitle: qsTr("Apps you quit that are not kept in the Dock stay in their own section until newer ones replace them.")
            Toggle {
                accessibleName: qsTr("Show recent apps in Dock")
                checked: root.store.value("dock.showRecents")
                onToggled: c => root.store.set("dock.showRecents", c)
            }
        }

        // Windows' End Task (owner AQ5, ADR-0038 AM63): the Dock menu of a running app gains End Task, its Option + Force Quit.
        SettingsRow {
            title: qsTr("Show End Task in Dock menus")
            Toggle {
                accessibleName: qsTr("Show End Task in Dock menus")
                checked: root.store.value("dock.endTask")
                onToggled: c => root.store.set("dock.endTask", c)
            }
        }
    }

    // Folders kept in the Dock as stacks (dock.folders). Dragging a folder onto the Dock's right section adds one too.
    readonly property var dockFolders: store.value("dock.folders")

    function urlToPath(u: url): string {
        const s = u.toString();
        return s.indexOf("file://") === 0 ? decodeURIComponent(s.substring(7)) : "";
    }

    function addDockFolder(path: string): void {
        if (path === "" || dockFolders.indexOf(path) >= 0 || dockFolders.length >= 12)
            return;
        store.set("dock.folders", dockFolders.concat([path]));
    }

    function openAddFolder(): void {
        addFolderDialog.open();
    }

    function removeDockFolder(path: string): void {
        store.set("dock.folders", dockFolders.filter(f => f !== path));
    }

    FolderDialog {
        id: addFolderDialog
        title: qsTr("Choose a folder for the Dock")
        onAccepted: root.addDockFolder(root.urlToPath(selectedFolder))
    }

    SettingsGroup {
        caption: qsTr("Folders in the Dock")
        footnote: qsTr("A folder in the Dock opens as a stack. You can also drag a folder to the right of the divider in the Dock.")

        Repeater {
            model: root.dockFolders

            delegate: SettingsRow {
                id: folderRow
                required property string modelData
                title: modelData
                Button {
                    push: true
                    text: qsTr("Remove")
                    Accessible.name: qsTr("Remove %1 from the Dock").arg(folderRow.modelData)
                    onClicked: root.removeDockFolder(folderRow.modelData)
                }
            }
        }

        SettingsRow {
            title: qsTr("Add a folder")
            Button {
                push: true
                text: qsTr("Add Folder…")
                onClicked: root.openAddFolder()
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Desktop & Stages")

        SettingsRow {
            title: qsTr("Show items")
            CheckBox {
                text: qsTr("On Desktop")
                accessibleName: qsTr("Show items on the desktop")
                checked: root.store.value("desktop.showIcons")
                onToggled: root.store.set("desktop.showIcons", checked)
            }
        }
    }

    SettingsGroup {
        footnote: qsTr("Needs the Grassfield compositor extension. The Stages switch is also in Quick Settings.")

        SettingsRow {
            title: qsTr("Stages")
            subtitle: qsTr("Keep the windows of one app in the centre and the other recent apps as thumbnails on the left edge.")
            Toggle {
                accessibleName: qsTr("Stages")
                checked: root.store.value("windows.stages")
                onToggled: c => root.store.set("windows.stages", c)
            }
        }
    }

    // TL32: the tiling switches in this order; each reaches the plugin once it offers the feature (Compositor.pushPluginConfig).
    // Default web browser (macOS 27, ADR-0055 D-6): the installed browsers, never Omarchy's routing entry nor a launcher that
    // resolves the default again. The choice is written to the session's own list and recorded as the user's (DefaultBrowser.js).
    property var browserChoices: []
    property string browserCurrent: ""
    // A short sentence under the row when the last choice could not be kept ("" otherwise).
    property string browserError: ""

    function entriesOf(dir: string): var {
        return root.backend.desktopEntries(dir).map(f => ({file: f, text: root.backend.readText(dir + "/" + f).text}));
    }

    // The text of the user's own lists (the configuration folder's desktop lists and mimeapps.list), in lookup order; null when one
    // exists and cannot be read as UTF-8 (nothing is decided on a list that is not understood).
    function ownListTexts(): var {
        const texts = [];
        for (const name of DefaultBrowser.ownListNames(root.backend.currentDesktops)) {
            const file = root.backend.readText(root.backend.xdgConfigDir + "/" + name);
            if (file.exists && !file.ok)
                return null;
            texts.push(file.text);
        }
        return texts;
    }

    // The applications folders are read off the GUI thread (Backend.readDesktopEntries: only the entries that name WebBrowser,
    // and every copy of such a name); a backend without that door (a test's) is read here.
    function readBrowsers(): void {
        if (!root.backend || (typeof root.backend.desktopEntries !== "function" && typeof root.backend.readDesktopEntries !== "function")) {
            root.browserChoices = [];
            return;
        }
        if (typeof root.backend.readDesktopEntries === "function") {
            root.backend.readDesktopEntries(root.backend.applicationDirs, "desktop.browsers", "WebBrowser");
            return;
        }
        let all = [];
        for (const dir of root.backend.applicationDirs)
            all = all.concat(root.entriesOf(dir));
        root.takeBrowsers(all);
    }

    function takeBrowsers(all: var): void {
        root.browserChoices = DefaultBrowser.browsers(all, Qt.locale().name, program => root.backend.programExists(program));
        const own = root.ownListTexts();
        const session = root.backend.readText(root.backend.xdgConfigDir + "/" + DefaultBrowser.LIST_NAME);
        // Always the browser links open in now (never blank while a browser is installed); a list that cannot be read is left out.
        root.browserCurrent = DefaultBrowser.effective([session.text].concat(own === null ? [] : own), root.browserChoices);
    }

    function failBrowser(): bool {
        root.browserError = qsTr("The default web browser could not be changed.");
        return false;
    }

    // Records the choice as the user's first (with what the user's own lists name now, the baseline a later change is seen against),
    // then writes the session's list: a failure of the first leaves the list as it was. Neither goes through any other path than the
    // backend's guarded writer (a dev session writes only under .dev). A failure shows a short sentence under the row.
    function setBrowser(id: string): bool {
        root.browserError = "";
        if (!root.backend || !root.browserChoices.some(b => b.id === id))
            return root.failBrowser();
        const own = root.ownListTexts();
        if (own === null)
            return root.failBrowser();
        const listPath = root.backend.xdgConfigDir + "/" + DefaultBrowser.LIST_NAME;
        const list = root.backend.readText(listPath);
        if (list.exists && !list.ok)
            return root.failBrowser();
        const next = DefaultBrowser.withBrowser(list.text, id);
        if (next === null)
            return root.failBrowser();
        const statePath = root.backend.grassfieldStateDir + "/" + DefaultBrowser.STATE_NAME;
        const record = root.backend.readText(statePath);
        if (record.exists && !record.ok)
            return root.failBrowser();
        if (root.backend.writeDefaultAppsFile(statePath, DefaultBrowser.stateWithUser(record.text, id, DefaultBrowser.baseline(own))) !== "")
            return root.failBrowser();
        if (root.backend.writeDefaultAppsFile(listPath, next) !== "")
            return root.failBrowser();
        root.browserCurrent = id;
        return true;
    }

    // ---- Default Apps (owner report 2026-11-22): Mail, Terminal and the kinds of documents under the browser -----------------
    // Every installed, runnable application (DefaultApps.applications), read off the GUI thread as the browsers are.
    property var allApps: []
    // The rows: {id, title, types, choices: [{id, text}], current}. Mail and the kinds write the session list through the backend's
    // setDefaultApps (Files' Change All… writer); Terminal writes grassfield-xdg-terminals.list (setDefaultTerminal).
    property var mailRow: null
    property var terminalRow: null
    property var kindRows: []
    // A short sentence under a row whose last choice could not be kept: {rowId: text}.
    property var rowErrors: ({})
    // The terminal xdg-terminal-exec opens now ("" until it answered, or when it could not say).
    property string printedTerminal: ""

    // Other… in a row: Main opens its application picker over the window and calls `chosen(app)` with the one picked
    // ({file, name, icon}).
    signal appPickerRequested(var apps, var texts, var chosen)

    readonly property var kindTitles: ({
        documents: qsTr("Documents"), spreadsheets: qsTr("Spreadsheets"), presentations: qsTr("Presentations"), pdf: qsTr("PDF documents"),
        pictures: qsTr("Pictures"), music: qsTr("Music"), videos: qsTr("Videos"), archives: qsTr("Archives"), text: qsTr("Text and code")
    })

    function readApps(): void {
        if (!root.backend)
            return;
        if (typeof root.backend.readDesktopEntries === "function") {
            root.backend.readDesktopEntries(root.backend.applicationDirs, "desktop.apps");
        } else if (typeof root.backend.desktopEntries === "function") {
            let all = [];
            for (const dir of root.backend.applicationDirs)
                all = all.concat(root.entriesOf(dir));
            root.takeApps(all);
        }
        if (typeof root.backend.readOnlyQuery === "function")
            root.backend.readOnlyQuery(["xdg-terminal-exec", "--print-id"], "desktop.terminal");
    }

    // The lists the rows read, in lookup order: the session's own list first, then the user's and the applications folders'.
    function lookupTexts(): var {
        const texts = [root.backend.readText(root.backend.xdgConfigDir + "/" + DefaultBrowser.LIST_NAME).text];
        for (const path of DefaultApps.lookupPaths(root.backend.xdgConfigDir, root.backend.applicationDirs, root.backend.currentDesktops)) {
            const file = root.backend.readText(path);
            if (file.ok)
                texts.push(file.text);
        }
        return texts;
    }

    function takeApps(entries: var): void {
        root.allApps = DefaultApps.applications(entries, Qt.locale().name, program => root.backend.programExists(program));
        root.refreshRows();
    }

    function refreshRows(): void {
        if (!root.backend)
            return;
        const texts = root.lookupTexts();
        const none = qsTr("None");
        const other = qsTr("Other…");
        const row = (id, title, types, capableApps, current) => ({id: id, title: title, types: types, current: current,
                                                                  choices: DefaultApps.choices(capableApps, root.allApps, current, none, other)});
        root.mailRow = row("mail", qsTr("Default email reader"), DefaultApps.MAIL_TYPES, DefaultApps.capable(root.allApps, DefaultApps.MAIL_TYPES),
                           DefaultApps.current(texts, DefaultApps.MAIL_TYPES));
        const terms = DefaultApps.terminals(root.allApps);
        const own = DefaultApps.listedTerminal(root.backend.readText(root.backend.xdgConfigDir + "/" + DefaultApps.TERMINAL_LIST).text);
        const termCurrent = root.printedTerminal !== "" ? root.printedTerminal : own !== "" ? own : terms.length > 0 ? terms[0].id : "";
        // Terminals only: Other… would let any application be started as a terminal.
        const terminal = row("terminal", qsTr("Default terminal"), [], terms, termCurrent);
        terminal.choices = terminal.choices.filter(c => c.id !== DefaultApps.OTHER);
        root.terminalRow = terminal;
        root.kindRows = DefaultApps.KINDS.map(k => row(k.id, root.kindTitles[k.id], k.types, DefaultApps.capable(root.allApps, k.types),
                                                        DefaultApps.current(texts, k.types)));
    }

    function failRow(rowId: string): bool {
        const next = Object.assign({}, root.rowErrors);
        next[rowId] = qsTr("The default app could not be changed.");
        root.rowErrors = next;
        return false;
    }

    // A choice in a row: Other… asks for any application first; "" (None) and the shown one change nothing.
    function pick(r: var, id: string): void {
        if (id === DefaultApps.OTHER) {
            root.appPickerRequested(root.allApps.map(a => ({file: a.id, name: a.name, icon: a.icon})),
                                    {title: qsTr("Choose an App"), message: qsTr("Choose the app for “%1”.").arg(r.title), confirm: qsTr("Choose")},
                                    app => root.choose(r, app.file));
            return;
        }
        if (id !== "" && id !== r.current)
            root.choose(r, id);
    }

    function choose(r: var, id: string): bool {
        const next = Object.assign({}, root.rowErrors);
        delete next[r.id];
        root.rowErrors = next;
        const app = root.allApps.find(a => a.id === id);
        if (!root.backend || !app)
            return root.failRow(r.id);
        const error = r.id === "terminal" ? root.backend.setDefaultTerminal(id) : root.backend.setDefaultApps(DefaultApps.typesFor(app, r.types), id);
        if (error !== "")
            return root.failRow(r.id);
        if (r.id === "terminal")
            root.printedTerminal = id;
        root.refreshRows();
        return true;
    }

    Component.onCompleted: {
        root.readBrowsers();
        root.readApps();
    }

    Connections {
        target: root.backend
        ignoreUnknownSignals: true

        function onDesktopEntriesRead(tag: string, entries: var): void {
            if (tag === "desktop.browsers")
                root.takeBrowsers(entries);
            else if (tag === "desktop.apps")
                root.takeApps(entries);
        }

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag !== "desktop.terminal")
                return;
            root.printedTerminal = ok ? DefaultApps.printedTerminal(output) : "";
            root.refreshRows();
        }
    }

    component DefaultAppRow: SettingsRow {
        id: appRow
        required property var row
        visible: appRow.row !== null && appRow.row.choices.length > 1
        title: appRow.row ? appRow.row.title : ""
        subtitle: appRow.row ? (root.rowErrors[appRow.row.id] ?? "") : ""
        ComboBox {
            inline: true
            accessibleName: appRow.title
            model: appRow.row ? appRow.row.choices : []
            value: appRow.row ? appRow.row.current : ""
            onPicked: id => root.pick(appRow.row, id)
        }
    }

    SettingsGroup {
        visible: root.browserChoices.length > 0 || root.allApps.length > 0
        caption: qsTr("Default Apps")

        SettingsRow {
            visible: root.browserChoices.length > 0
            title: qsTr("Default web browser")
            subtitle: root.browserError
            ComboBox {
                inline: true
                accessibleName: qsTr("Default web browser")
                model: root.browserChoices.map(b => ({id: b.id, text: b.name}))
                value: root.browserCurrent
                onPicked: id => root.setBrowser(id)
            }
        }

        DefaultAppRow {
            row: root.mailRow
        }

        DefaultAppRow {
            row: root.terminalRow
        }
    }

    SettingsGroup {
        visible: root.allApps.length > 0
        caption: qsTr("Open Documents With")
        footnote: qsTr("You can also choose the app for one kind of document in Files: Get Info > Open with > Change All…")

        Repeater {
            model: root.kindRows

            delegate: DefaultAppRow {
                required property var modelData
                row: modelData
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Windows")
        footnote: qsTr("Needs the Grassfield compositor extension.")

        SettingsRow {
            title: qsTr("Drag windows to left or right edge of screen to tile")
            Toggle {
                accessibleName: qsTr("Drag windows to left or right edge of screen to tile")
                checked: root.store.value("windows.tilingEdges")
                onToggled: c => root.store.set("windows.tilingEdges", c)
            }
        }

        SettingsRow {
            title: qsTr("Drag windows to menu bar to fill screen")
            Toggle {
                accessibleName: qsTr("Drag windows to menu bar to fill screen")
                checked: root.store.value("windows.tilingMenuBar")
                onToggled: c => root.store.set("windows.tilingMenuBar", c)
            }
        }

        // The key as the menus name it (keyboard.shortcutStyle, owner decision 2026-10-26): its symbol in the macOS style,
        // the PC key's name otherwise (parity matrix M38).
        SettingsRow {
            id: optionDragRow
            title: Appearance.shortcutStyle === "mac" ? qsTr("Hold ⌥ key while dragging windows to tile") : qsTr("Hold Alt key while dragging windows to tile")
            Toggle {
                accessibleName: optionDragRow.title
                checked: root.store.value("windows.tilingOptionDrag")
                onToggled: c => root.store.set("windows.tilingOptionDrag", c)
            }
        }

        SettingsRow {
            title: qsTr("Tiled windows have margins")
            Toggle {
                accessibleName: qsTr("Tiled windows have margins")
                checked: root.store.value("windows.tilingMargins")
                onToggled: c => root.store.set("windows.tilingMargins", c)
            }
        }

        SettingsRow {
            title: qsTr("Show layouts when hovering over the green button")
            Toggle {
                accessibleName: qsTr("Show layouts when hovering over the green button")
                checked: root.store.value("windows.tilingLayouts")
                onToggled: c => root.store.set("windows.tilingLayouts", c)
            }
        }

        SettingsRow {
            title: qsTr("Suggest windows to fill the rest of a layout")
            Toggle {
                accessibleName: qsTr("Suggest windows to fill the rest of a layout")
                checked: root.store.value("windows.tilingSuggestions")
                onToggled: c => root.store.set("windows.tilingSuggestions", c)
            }
        }

        SettingsRow {
            title: qsTr("Bring tile groups forward together")
            Toggle {
                accessibleName: qsTr("Bring tile groups forward together")
                checked: root.store.value("windows.tilingGroups")
                onToggled: c => root.store.set("windows.tilingGroups", c)
            }
        }

        // ADR-0009 amendment 2026-10-23 (audit GF-033): opt-in; off, a Hyprland update leaves the extension off until the
        // user runs grassfield-compositor-rebuild (the session's notice says so).
        SettingsRow {
            title: qsTr("Rebuild the compositor extension after Hyprland updates")
            subtitle: qsTr("Window titlebars, minimize and global menus need it. After an update of Hyprland, Grassfield builds it again in the background.")
            Toggle {
                accessibleName: qsTr("Rebuild the compositor extension after Hyprland updates")
                checked: root.store.value("windows.rebuildExtension")
                onToggled: c => root.store.set("windows.rebuildExtension", c)
            }
        }
    }

    // macOS 27: the push buttons under the last group, right-aligned (Screen Corners…, macOS's Hot Corners…, opens its sheet).
    Item {
        width: parent.width
        height: screenCornersButton.height

        Button {
            id: screenCornersButton
            anchors.right: parent.right
            push: true
            text: qsTr("Screen Corners…")
            onClicked: root.screenCornersRequested()
        }
    }
}
