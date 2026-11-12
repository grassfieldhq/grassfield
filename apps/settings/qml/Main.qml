pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "MouseTrackpad.js" as MouseTrackpad
import "NavHistory.js" as NavHistory
import "Power.js" as Power

// Grassfield Settings: sidebar with search and sections on the left, detail pane on the right (macOS 27 layout, ADR-0024).
// App windows are opaque (master-prompt 5.5): the sidebar is a flat, slightly darker surface edge to edge, not the shell material.
Window {
    id: root

    // Set by the launcher (src/main.cpp).
    required property var backend
    // The registrar is there (kept up to date by src/main.cpp): the window exports its menus to the global menu bar.
    required property bool globalMenu
    // Section to open first (--section=<id> on the command line); "" opens Appearance.
    property string startSection: ""
    // Drawn as key (ADR-0039 step 17): active, or held while a shell menu or the Control Center is open (Appearance.looksKey).
    readonly property bool keyLook: Appearance.looksKey(root, root.active)
    readonly property alias searchField: search
    // ADR-0015: this window draws its own chrome (lights and toolbar below); the apps' tagger (apps/windowchrome.h)
    // names its role for the compositor, whose plugin then draws no titlebar on it.
    property string gfChromeRole: "settings"
    // False when the shell says the compositor plugin is absent: the minimize light is greyed (ADR-0015 Q4b).
    property bool canMinimize: true
    // Colour of each section's icon tile: a vivid color.tile family name (a soft vertical gradient, TileGradient), white glyph on it.
    readonly property var tileColors: ({
            wifi: "blue", bluetooth: "blue", network: "blue", vpn: "blue", battery: "green", energy: "green", sound: "pink", displays: "blue", appearance: "black", wallpaper: "cyan",
            accessibility: "blue", desktop: "black", menubar: "graphite", search: "blue", notifications: "red", focus: "purple", lock: "black",
            mouse: "graphite", trackpad: "graphite", printers: "graphite", keyboard: "graphite", general: "graphite", about: "graphite", storage: "graphite",
            "software-update": "graphite",
            datetime: "blue", language: "blue", login: "graphite", privacy: "blue", fingerprint: "red", sharing: "graphite",
            "accessibility-zoom": "graphite", "accessibility-display": "blue", "accessibility-motion": "green", "accessibility-keyboard": "graphite",
            "privacy-location": "blue", "privacy-background": "graphite", "privacy-camera": "graphite", "privacy-remote-desktop": "blue",
            "privacy-screen-sharing": "purple"
        })
    // The title of the shown section (the toolbar's title; the page itself repeats nothing). A hub shows its own header card
    // instead, so the toolbar has no title there (macOS 27 General).
    readonly property string sectionTitle: {
        if (root.selectedId === "general")
            return "";
        if (root.notificationApp !== "")
            return root.notificationApp;
        for (const e of root.sections) {
            if (e.id === root.selectedId)
                return e.title;
        }
        return qsTr("Appearance");
    }

    // The sidebar in the macOS 27 order and groups (`group`: a gap before each new one), without the panes Grassfield has no
    // counterpart for (docs/specs/settings.md § macOS 27 parity inventory). Sub-panes name their hub (`parent`): they are not in
    // the sidebar, the hub's rows open them, and the search finds them.
    readonly property var sections: [
        {id: "wifi", group: 1, title: qsTr("Wi-Fi"), icon: "wifi-3", keywords: qsTr("wireless network internet networkmanager")},
        {id: "bluetooth", group: 1, title: qsTr("Bluetooth"), icon: "bluetooth", keywords: qsTr("devices headphones pair connect")},
        {id: "network", group: 1, title: qsTr("Network"), icon: "globe", keywords: qsTr("ethernet wired ip address router dns firewall")},
        {id: "vpn", group: 1, title: qsTr("VPN"), icon: "vpn", keywords: qsTr("vpn wireguard openvpn tunnel")},
        {id: "battery", group: 1, title: qsTr("Battery"), icon: "battery", keywords: qsTr("battery power low power mode energy health charging charge limit hibernation hibernate swap")},
        // A computer without a battery shows Energy in its place (macOS 27): Energy Mode and Prevent automatic sleeping.
        {id: "energy", group: 1, title: qsTr("Energy"), icon: "bolt", keywords: qsTr("energy power mode low power high power performance sleep prevent automatic sleeping display off hibernation hibernate swap")},
        {id: "general", group: 2, title: qsTr("General"), icon: "gear", keywords: qsTr("about software update storage date time language region login items startup")},
        {id: "accessibility", group: 2, title: qsTr("Accessibility"), icon: "person", keywords: qsTr("vision physical motor zoom display motion keyboard")},
        {id: "appearance", group: 2, title: qsTr("Appearance"), icon: "sun", keywords: qsTr("dark light theme transparency material motion icons tint terminal")},
        {id: "desktop", group: 2, title: qsTr("Desktop & Dock"), icon: "overview", keywords: qsTr("dock magnification autohide desktop icons items screen corners titlebar window tile tiling layouts suggestions margins")},
        {id: "displays", group: 2, title: qsTr("Displays"), icon: "display", keywords: qsTr("monitor screen resolution refresh scale arrangement brightness external display ddc")},
        {id: "menubar", group: 2, title: qsTr("Menu Bar"), icon: "control-center", keywords: qsTr("menu bar clock date time seconds 24-hour hide status items battery percentage wifi sound focus now playing background transparent")},
        {id: "search", group: 2, title: qsTr("Search"), icon: "search", keywords: qsTr("search results history calculator conversions documents commands clipboard copy paste")},
        {id: "wallpaper", group: 2, title: qsTr("Wallpaper"), icon: "wallpaper", keywords: qsTr("background picture photo image folder slideshow shuffle colour color desktop picture")},
        {id: "notifications", group: 3, title: qsTr("Notifications"), icon: "bell", keywords: qsTr("do not disturb previews banners")},
        {id: "sound", group: 3, title: qsTr("Sound"), icon: "volume-3", keywords: qsTr("volume output input speakers microphone mute audio alert sound effects beep feedback")},
        {id: "focus", group: 3, title: qsTr("Focus"), icon: "moon", keywords: qsTr("do not disturb silence quiet banners")},
        {id: "lock", group: 4, title: qsTr("Lock Screen"), icon: "lock", keywords: qsTr("idle inactivity password")},
        {id: "privacy", group: 4, title: qsTr("Privacy & Security"), icon: "hand", keywords: qsTr("privacy permissions location camera background screen sharing remote desktop apps flatpak portal security encryption disk password disk encryption luks")},
        // ADR-0045 OC-6: in the place of macOS 27's Touch ID & Password.
        {id: "fingerprint", group: 4, title: qsTr("Fingerprint & Key"), icon: "fingerprint", keywords: qsTr("fingerprint reader enrol finger security key fido2 sudo administrator unlock password")},
        {id: "keyboard", group: 5, title: qsTr("Keyboard"), icon: "keyboard", keywords: qsTr("shortcuts keys bindings dictation voice typing speech model voxtype")},
        {id: "mouse", group: 5, title: qsTr("Mouse"), icon: "mouse", keywords: qsTr("pointer tracking speed scrolling natural wheel bluetooth")},
        {id: "trackpad", group: 5, title: qsTr("Trackpad"), icon: "trackpad", keywords: qsTr("touchpad pointer tracking speed scrolling natural tap click secondary right click gestures swipe pinch")},
        {id: "printers", group: 5, title: qsTr("Printers"), icon: "printer", keywords: qsTr("printer printing print queue cups paper size default printer add remove airprint ipp everywhere")},
        {id: "about", parent: "general", title: qsTr("About"), icon: "laptop", keywords: qsTr("version system hardware processor memory computer name graphics serial")},
        {id: "software-update", parent: "general", title: qsTr("Software Update"), icon: "gear", keywords: qsTr("software update upgrade new version release notes beta omarchy packages automatic")},
        {id: "storage", parent: "general", title: qsTr("Storage"), icon: "drive", keywords: qsTr("disk space volume free used documents downloads pictures music videos trash")},
        {id: "datetime", parent: "general", title: qsTr("Date & Time"), icon: "clock", keywords: qsTr("clock time zone city automatic network time ntp 24-hour")},
        {id: "login", parent: "general", title: qsTr("Login Items"), icon: "list", keywords: qsTr("login items startup autostart open at login background services")},
        {id: "language", parent: "general", title: qsTr("Language & Region"), icon: "globe", keywords: qsTr("language region formats locale date number first day of week calendar text in images text recognition qr code")},
        {id: "sharing", parent: "general", title: qsTr("Sharing"), icon: "remote-desktop", keywords: qsTr("sharing remote login ssh server")},
        {id: "dnd", parent: "focus", title: qsTr("Do Not Disturb"), icon: "moon", keywords: qsTr("focus silence quiet banners notifications")},
        {id: "accessibility-zoom", parent: "accessibility", title: qsTr("Zoom"), icon: "zoom-in", keywords: qsTr("accessibility magnify magnifier zoom level larger screen")},
        {id: "accessibility-display", parent: "accessibility", title: qsTr("Display"), icon: "display", keywords: qsTr("accessibility contrast transparency text size larger pointer cursor size mouse large color colour outline fill")},
        {id: "accessibility-motion", parent: "accessibility", title: qsTr("Motion"), icon: "motion", keywords: qsTr("accessibility reduce motion animations")},
        {id: "accessibility-keyboard", parent: "accessibility", title: qsTr("Keyboard"), icon: "keyboard", keywords: qsTr("accessibility sticky keys slow keys")},
        {id: "privacy-location", parent: "privacy", title: qsTr("Location Services"), icon: "location", keywords: qsTr("privacy location where apps allow")},
        {id: "privacy-background", parent: "privacy", title: qsTr("Background Apps"), icon: "background", keywords: qsTr("privacy background apps running allow")},
        {id: "privacy-camera", parent: "privacy", title: qsTr("Camera"), icon: "camera", keywords: qsTr("privacy camera webcam video apps allow")},
        {id: "privacy-remote-desktop", parent: "privacy", title: qsTr("Remote Desktop"), icon: "remote-desktop", keywords: qsTr("privacy remote desktop control saved choices")},
        {id: "privacy-screen-sharing", parent: "privacy", title: qsTr("Screen Sharing"), icon: "screen-share", keywords: qsTr("privacy screen sharing recording window saved choices")}
    ]
    // An app's sub-pane of Notifications: "notifications/<app name>" (the name as the shell saw it).
    readonly property string notificationAppPrefix: "notifications/"
    readonly property string notificationApp: root.selectedId.indexOf(root.notificationAppPrefix) === 0 ? root.selectedId.substring(root.notificationAppPrefix.length) : ""
    property string selectedId: root.startSection !== "" ? root.pointerPane(root.paneOf(root.startSection)) : "appearance"
    property string query: ""
    // The state a pane shows under its title in the toolbar (Battery), "" for none.
    readonly property string pageSubtitle: (page.item as BatteryPage)?.subtitle ?? ""
    // Battery is there only on a computer with a laptop battery (macOS shows it on a laptop only); Energy on the others (UPower
    // reports no battery, or does not answer).
    property bool hasBattery: false
    // The pane shown follows the battery (Power.paneFor): the sidebar's selection moves to Battery or Energy without a new
    // history entry.
    onHasBatteryChanged: {
        const shown = root.pointerPane(root.selectedId);
        if (shown === root.selectedId)
            return;
        root.navState = Object.assign({}, root.navState, {current: shown});
        root.selectedId = shown;
    }
    // Mouse while a mouse is connected and Trackpad where there is one (macOS): MouseTrackpad.pointers of the kernel's input
    // devices, read again with the system state while the window is active.
    property bool hasMouse: false
    property bool hasTouchpad: false
    readonly property var available: root.sections.filter(s => (s.id !== "battery" || root.hasBattery) && (s.id !== "energy" || !root.hasBattery)
        && (s.id !== "mouse" || root.hasMouse) && (s.id !== "trackpad" || root.hasTouchpad))
    readonly property var filtered: {
        const q = root.query.trim().toLowerCase();
        if (q === "")
            return root.available.filter(s => s.parent === undefined);
        return root.available.filter(s => s.title.toLowerCase().indexOf(q) >= 0 || s.keywords.toLowerCase().indexOf(q) >= 0);
    }

    // The hub a sub-pane belongs to ("" for a sidebar section): the sidebar keeps the hub selected while one of its sub-panes is open.
    function parentOf(id: string): string {
        if (id.indexOf(root.notificationAppPrefix) === 0)
            return "notifications";
        for (const e of root.sections) {
            if (e.id === id)
                return e.parent !== undefined ? e.parent : "";
        }
        return "";
    }
    // The reasons are sentence fragments; a trailing full stop (a JavaScript engine message) is dropped so that the
    // sentences around them never show two.
    readonly property string bannerText: cfg.blocked
        ? qsTr("grassfield.json cannot be used: %1. Settings are read-only until the file is fixed; the file has not been changed.").arg(root.fragment(cfg.error))
        : cfg.writeError !== "" ? qsTr("The change could not be saved: %1.").arg(root.fragment(cfg.writeError)) : ""

    function fragment(reason: string): string {
        return reason.trim().replace(/[.\s]+$/, "");
    }

    title: qsTr("Grassfield Settings")
    width: Tokens.settingsWindowWidth
    height: Tokens.settingsWindowHeight
    minimumWidth: Tokens.settingsWindowMinWidth
    minimumHeight: Tokens.settingsWindowMinHeight
    visible: true
    color: Appearance.colors.windowBackground

    function readCapabilities(): void {
        const file = root.backend.readText(root.backend.capabilitiesFile);
        root.canMinimize = WindowActions.minimizeAvailable(file.exists && file.ok ? file.text : "");
    }

    // The window goes away, closed (Ctrl+W, its close light: src/main.cpp only hides it, and the app lives on while About This
    // Computer shows) or hidden any other way: what a sheet holds that must not outlive it ends now (security review of
    // ADR-0045, M-1). A fingerprint enrolment stops (fprintd releases the reader: nobody else's finger can be enrolled as the
    // owner's), the disk password's fields are emptied, the Wi-Fi code (it encodes the password) is dropped.
    function endPrivateSheets(): void {
        if (fingerprintEnroll.shown)
            fingerprintEnroll.cancel();
        root.backend.stopEnroll();
        if (diskPassword.shown)
            diskPassword.cancel();
        diskPassword.clearFields();
        if (shareNetwork.shown)
            shareNetwork.close();
    }

    onClosing: root.endPrivateSheets()
    onVisibleChanged: {
        if (!root.visible)
            root.endPrivateSheets();
    }

    Component.onCompleted: {
        root.readPointers();
        root.navState = NavHistory.start(root.selectedId);
        root.backend.watch(root.backend.capabilitiesFile);
        root.readCapabilities();
        root.backend.busQuery("power.state", "main.power");
    }

    Connections {
        target: root.backend
        function onFileChanged(path: string): void {
            if (path === root.backend.capabilitiesFile)
                root.readCapabilities();
        }
        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "main.power") {
                const power = ok ? Power.parseState(output) : null;
                root.hasBattery = power !== null && power.present;
            }
        }
    }

    ConfigStore {
        id: cfg
        backend: root.backend
    }

    SystemService {
        id: sys
        backend: root.backend
    }

    // Software Update (ADR-0033): what the shell found, for the pane and the badges of the General rows (U19).
    SoftwareUpdateState {
        id: updateState
        backend: root.backend
        system: sys
    }

    // Appearance from grassfield.json, live (shared with the About This Computer window).
    SettingsAppearance {
        backend: root.backend
        config: cfg
    }

    // Back and forward through the panes (the toolbar's capsule): NavHistory.js.
    property var navState: ({back: [], forward: [], current: ""})

    // A section id may carry a display: "wallpaper@DP-2" opens Wallpaper on that output (the desktop's Change Wallpaper…).
    function paneOf(id: string): string {
        const i = id.indexOf("@");
        return i < 0 ? id : id.substring(0, i);
    }

    function displayOf(id: string): string {
        const i = id.indexOf("@");
        return i < 0 ? "" : id.substring(i + 1);
    }

    // The output Wallpaper is asked to show; set again, to the same name too, at each request.
    property string wallpaperDisplay: root.displayOf(root.startSection)

    function select(id: string): void {
        const shown = root.pointerPane(root.paneOf(id));
        root.wallpaperDisplay = "";
        root.wallpaperDisplay = root.paneOf(id) === "wallpaper" ? root.displayOf(id) : "";
        root.navState = NavHistory.visit(root.navState, shown);
        root.selectedId = shown;
    }

    // Asked for Mouse without a mouse, or for Trackpad without a touchpad, the other is shown when it is there; asked for
    // Battery without a battery, Energy, and the other way round (Power.paneFor).
    function pointerPane(id: string): string {
        return Power.paneFor(MouseTrackpad.paneFor(id, {mouse: root.hasMouse, touchpad: root.hasTouchpad}), root.hasBattery);
    }

    function readPointers(): void {
        const found = MouseTrackpad.pointers(root.backend.readText("/proc/bus/input/devices").text);
        root.hasMouse = found.mouse;
        root.hasTouchpad = found.touchpad;
        if (root.pointerPane(root.selectedId) !== root.selectedId)
            root.select(root.selectedId);
    }

    Timer {
        interval: Tokens.settingsSystemRefreshMs
        running: root.active
        repeat: true
        onTriggered: root.readPointers()
    }

    function navBack(): void {
        root.navState = NavHistory.back(root.navState);
        root.selectedId = root.pointerPane(root.navState.current);
    }

    function navForward(): void {
        root.navState = NavHistory.forward(root.navState);
        root.selectedId = root.pointerPane(root.navState.current);
    }

    // Return in the search field: the first result opens and the list takes the keyboard.
    function pickFirstResult(event: var): void {
        list.keyboardRing = true;
        if (root.filtered.length > 0)
            root.select(root.filtered[0].id);
        list.forceActiveFocus();
        event.accepted = true;
    }

    function focusSearch(): void {
        search.forceActiveFocus();
        search.selectAll();
    }

    // Global menu (T1). Its shortcuts duplicate the two below; see GlobalMenu.qml for the single dispatch.
    Loader {
        active: root.globalMenu
        sourceComponent: GlobalMenu {
            win: root
        }
    }

    Shortcut {
        sequence: "Ctrl+F"
        onActivated: root.focusSearch()
        onActivatedAmbiguously: root.focusSearch()
    }

    Shortcut {
        sequence: "Ctrl+W"
        onActivated: root.close()
        onActivatedAmbiguously: root.close()
    }

    function stepSection(direction: int): void {
        let index = -1;
        const hub = root.parentOf(root.selectedId);
        for (let i = 0; i < root.filtered.length; i++) {
            if (root.filtered[i].id === root.selectedId || (index < 0 && root.filtered[i].id === hub))
                index = i;
        }
        const next = Math.max(0, Math.min(root.filtered.length - 1, index + direction));
        if (root.filtered.length > 0)
            root.select(root.filtered[next].id);
    }

    Item {
        id: sidebar
        z: 1 // above the detail pane: the panel's shadow falls on it
        width: Tokens.settingsSidebarWidth
        height: parent.height

        // The floating panel: inset from the window's left, top and bottom edges, the detail pane straight beside it (macOS 26;
        // ADR-0024 amendment 2026-11-03). Everything below keeps window coordinates, so the lights sit at the macOS position.
        SidebarPanel {
            id: panel
            anchors {
                fill: parent
                leftMargin: Tokens.windowSidebarPanelInset
                topMargin: Tokens.windowSidebarPanelInset
                bottomMargin: Tokens.windowSidebarPanelInset
            }
        }

        // The window lights, in the corner of the sidebar panel (ADR-0015); the toolbar over the detail pane holds the title.
        UnifiedToolbar {
            id: sidebarToolbar
            width: parent.width
            window: root
            showTitle: false
            canMinimize: root.canMinimize
            doubleClickAction: cfg.value("windows.titlebarDoubleClick")
        }

        // The search field, as wide as the selection: the shared SearchField (macOS 27's rimmed capsule, with a clear button;
        // ADR-0039 step 14). Tab, Shift+Tab, Down and Return hand the focus to the list by the keyboard.
        SearchField {
            id: search
            x: panel.x + Tokens.settingsSidebarInset
            y: sidebarToolbar.height + Tokens.spacingSm
            width: panel.width - 2 * Tokens.settingsSidebarInset
            activeFocusOnTab: true
            accessibleName: qsTr("Search settings")
            onTextChanged: root.query = text

            Keys.onTabPressed: event => {
                list.keyboardRing = true;
                event.accepted = false;
            }
            Keys.onBacktabPressed: event => {
                list.keyboardRing = true;
                event.accepted = false;
            }
            Keys.onDownPressed: event => {
                list.keyboardRing = true;
                list.forceActiveFocus();
                event.accepted = true;
            }
            Keys.onReturnPressed: event => root.pickFirstResult(event)
            Keys.onEnterPressed: event => root.pickFirstResult(event)
        }

        ListView {
            id: list
            anchors {
                top: search.bottom
                topMargin: Tokens.spacingMd
                left: parent.left
                right: parent.right
                bottom: panel.bottom
                leftMargin: panel.x + Tokens.settingsSidebarInset
                rightMargin: Tokens.settingsSidebarInset
            }
            model: root.filtered
            spacing: 0
            // Room for the focus ring outside the first and last rows (the list clips).
            topMargin: Tokens.controlFocusOutline
            bottomMargin: Tokens.controlFocusOutline
            clip: true
            // The wheel and two-finger scrolling move the list (macOS), stopping at the ends; the mouse never drags it, so a
            // click on a row always selects it. The shared overlay scroll bar sits on the right edge (faint when idle).
            acceptedButtons: Qt.NoButton
            boundsBehavior: Flickable.StopAtBounds
            keyNavigationEnabled: false
            activeFocusOnTab: true
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Sections")
            ScrollBar.vertical: ScrollBar {}

            // The selected row stays in view whoever selected it: keys, a click, search, a deep link, back and forward.
            // Its focus ring (outside the row) stays inside the clipped list too, which positionViewAtIndex does not allow for.
            function showSelected(): void {
                const hub = root.parentOf(root.selectedId);
                for (let i = 0; i < root.filtered.length; i++) {
                    if (root.filtered[i].id === root.selectedId || root.filtered[i].id === hub) {
                        list.positionViewAtIndex(i, ListView.Contain);
                        const item = list.itemAtIndex(i);
                        if (item) {
                            const ring = Tokens.controlFocusOutline;
                            const top = item.y + item.height - Tokens.settingsSidebarItemHeight - ring;
                            const bottom = item.y + item.height + ring;
                            if (top < list.contentY)
                                list.contentY = top;
                            else if (bottom > list.contentY + list.height)
                                list.contentY = bottom - list.height;
                        }
                        return;
                    }
                }
            }

            // Search results (macOS) start at the top; clearing the search brings the selected section back into view.
            function showResults(): void {
                if (root.query.trim() === "") {
                    list.showSelected();
                } else {
                    list.positionViewAtBeginning();
                    list.contentY = list.originY - list.topMargin;
                }
            }

            Connections {
                target: root
                function onSelectedIdChanged(): void {
                    list.showSelected();
                }
                function onFilteredChanged(): void {
                    Qt.callLater(list.showResults);
                }
            }

            Component.onCompleted: Qt.callLater(list.showSelected)

            // The focus ring is for the keyboard (macOS): it appears with the first key that moves the focus or the selection
            // (Tab, Down, Return in the search field; the arrows here) and goes with the focus, so a click on a row or the focus
            // coming back when the window is activated again shows none.
            property bool keyboardRing: false
            onActiveFocusChanged: if (!activeFocus)
                keyboardRing = false

            Keys.onPressed: event => {
                keyboardRing = true;
                if (event.key === Qt.Key_Up) {
                    root.stepSection(-1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Down) {
                    root.stepSection(1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Home && root.filtered.length > 0) {
                    root.select(root.filtered[0].id);
                    event.accepted = true;
                } else if (event.key === Qt.Key_End && root.filtered.length > 0) {
                    root.select(root.filtered[root.filtered.length - 1].id);
                    event.accepted = true;
                }
            }

            delegate: Item {
                id: entry

                required property var modelData
                required property int index
                readonly property bool selected: entry.modelData.id === root.selectedId || entry.modelData.id === root.parentOf(root.selectedId)
                // The first row of a new sidebar group: a gap above it (macOS 27). Search results are one list, without gaps.
                readonly property real gap: root.query.trim() === "" && entry.index > 0 && root.filtered[entry.index - 1].group !== entry.modelData.group
                    ? Tokens.settingsSidebarGroupGap : 0

                width: ListView.view.width
                height: Tokens.settingsSidebarItemHeight + entry.gap
                Accessible.role: Accessible.ListItem
                Accessible.name: countBadge.count > 0 ? entry.modelData.title + ", " + countBadge.spoken : entry.modelData.title
                Accessible.selectable: true
                Accessible.selected: entry.selected
                Accessible.onPressAction: root.select(entry.modelData.id)

                // The row itself, below the group gap.
                Item {
                    y: entry.gap
                    width: parent.width
                    height: Tokens.settingsSidebarItemHeight

                    Rectangle {
                        anchors.fill: parent
                        radius: Tokens.settingsSidebarItemRadius
                        // The accent while the window is key; neutral, the hover ink, while it is not (macOS 27; ADR-0039 step 17).
                        color: entry.selected ? (root.keyLook ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.hover, Appearance.inactiveSelectionOpacity)) : (hover.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent")
                    }

                    // Keyboard focus ring: outside the selected row, accent and translucent (as macOS).
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -Tokens.controlFocusOutline
                        radius: Tokens.settingsSidebarItemRadius + Tokens.controlFocusOutline
                        visible: entry.selected && list.activeFocus && list.keyboardRing
                        color: "transparent"
                        border.width: Tokens.controlFocusOutline
                        border.color: Appearance.focusRingColor
                    }

                    // The section's coloured tile with a white glyph (macOS 27); it keeps its colour when the row is selected.
                    Rectangle {
                        id: glyph
                        // The tile sits on whole device pixels in WINDOW coordinates (the row itself does not: the panel, the list and
                        // the row heights are fractional at 1.25), so its 1-pixel rim and its edge are crisp. `origin` is the row's
                        // place in the window; it is read again when the row moves (scrolling, a group gap).
                        readonly property real pixelRatio: Math.max(1, glyph.Window.window ? glyph.Window.window.devicePixelRatio : Screen.devicePixelRatio)
                        readonly property point origin: {
                            entry.y;
                            entry.gap;
                            list.contentY;
                            list.y;
                            list.x;
                            search.height;
                            return glyph.parent.mapToItem(null, 0, 0);
                        }
                        x: Math.round((glyph.origin.x + Tokens.spacingSm) * glyph.pixelRatio) / glyph.pixelRatio - glyph.origin.x
                        y: Math.round((glyph.origin.y + (glyph.parent.height - height) / 2) * glyph.pixelRatio) / glyph.pixelRatio - glyph.origin.y
                        width: Tokens.settingsSidebarIconSize
                        height: Tokens.settingsSidebarIconSize
                        radius: Tokens.settingsSidebarTileRadius
                        // A mid grey while the window is not key, as macOS greys its sidebar tiles; the white glyph keeps 3:1.
                        // Key: the vivid gradient (no flat fill); not key: the flat grey.
                        readonly property bool lit: root.keyLook
                        color: glyph.lit ? "transparent" : (Appearance.dark ? Tokens.settingsSidebarTileInactiveDark : Tokens.settingsSidebarTileInactiveLight)
                        gradient: glyph.lit ? tileGradient : null

                        TileGradient {
                            id: tileGradient
                            name: root.tileColors[entry.modelData.id] || "graphite"
                        }

                        // A lit tile in the dark appearance has a 1-device-pixel inner rim, so it reads off the dark panel.
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "transparent"
                            border.width: 1 / glyph.pixelRatio
                            border.color: Appearance.withAlpha(Tokens.settingsSidebarTileGlyph, Tokens.settingsSidebarTileRimOpacityDark)
                            visible: glyph.lit && Appearance.dark
                        }

                        Icon {
                            anchors.centerIn: parent
                            name: entry.modelData.icon
                            size: Tokens.settingsSidebarGlyphSize
                            color: Tokens.settingsSidebarTileGlyph
                        }
                    }

                    Text {
                        textFormat: Text.PlainText
                        anchors {
                            left: glyph.right
                            leftMargin: Tokens.spacingSm
                            right: countBadge.visible ? countBadge.left : parent.right
                            rightMargin: Tokens.spacingSm
                            verticalCenter: parent.verticalCenter
                        }
                        text: entry.modelData.title
                        elide: Text.ElideRight
                        color: entry.selected && root.keyLook ? Appearance.colors.selectionText : Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                        font.weight: Tokens.typographyMenuWeight
                    }

                    // Available updates (U19): a red count on General, and on Software Update among search results.
                    CountBadge {
                        id: countBadge
                        anchors.right: parent.right
                        // Clear of the overlay scroll bar (its width plus the gap it keeps).
                        anchors.rightMargin: Tokens.controlScrollbarWidth + Tokens.spacingXs
                        anchors.verticalCenter: parent.verticalCenter
                        count: entry.modelData.id === "general" || entry.modelData.id === "software-update" ? updateState.count : 0
                    }

                    MouseArea {
                        id: hover
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            list.keyboardRing = false;
                            list.forceActiveFocus();
                            root.select(entry.modelData.id);
                        }
                    }
                }
            }
        }
    }

    Item {
        id: detail
        x: sidebar.width
        width: parent.width - sidebar.width
        height: parent.height

        UnifiedToolbar {
            id: detailToolbar
            width: parent.width
            window: root
            showControls: false
            title: root.sectionTitle
            canMinimize: root.canMinimize
            doubleClickAction: cfg.value("windows.titlebarDoubleClick")

            // Back and forward: one 72 x 36 glass capsule with a hairline between them (macOS 27).
            leading: RimmedCapsule {
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
                        enabled: NavHistory.canBack(root.navState)
                        accessibleName: qsTr("Back")
                        onClicked: root.navBack()
                    }

                    ToolButton {
                        capsule: true
                        buttonSize: Tokens.toolbarGroupButton
                        navigation: "forward"
                        enabled: NavHistory.canForward(root.navState)
                        accessibleName: qsTr("Forward")
                        onClicked: root.navForward()
                    }
                }
            }

            // A pane with a state to show under its title (macOS 27 Battery: "Fully Charged" with the battery glyph): the title
            // moves up and the state goes under it.
            showTitle: root.pageSubtitle === ""

            Item {
                visible: root.pageSubtitle !== ""
                x: detailToolbar.titleStart
                width: detailToolbar.titleEnd - x
                height: detailToolbar.height
                Accessible.role: Accessible.Heading
                Accessible.name: root.sectionTitle + ", " + root.pageSubtitle

                Text {
                    textFormat: Text.PlainText
                    y: Tokens.settingsToolbarSubtitleTitleBaseline - baselineOffset
                    width: parent.width
                    elide: Text.ElideRight
                    text: root.sectionTitle
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.windowTitleSize
                    font.weight: Tokens.typographyTitleWeight
                }

                Icon {
                    id: subtitleGlyph
                    anchors.verticalCenter: subtitleText.verticalCenter
                    name: "battery"
                    size: Tokens.settingsWifiGlyphSize
                    color: Appearance.windowSecondary
                }

                Text {
                    id: subtitleText
                    textFormat: Text.PlainText
                    x: subtitleGlyph.width + Tokens.settingsToolbarSubtitleGlyphGap
                    y: Tokens.settingsToolbarSubtitleBaseline - baselineOffset
                    width: parent.width - x
                    elide: Text.ElideRight
                    text: root.pageSubtitle
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }
            }
        }

        Rectangle {
            id: banner
            visible: root.bannerText !== ""
            x: Tokens.spacingLg
            y: detailToolbar.height + Tokens.spacingLg
            width: parent.width - 2 * Tokens.spacingLg
            height: visible ? bannerLabel.implicitHeight + 2 * Tokens.spacingMd : 0
            radius: Tokens.radiusGroup
            // Destructive colour: the file is refused (or a change failed), nothing is written.
            color: Appearance.colors.destructive
            Accessible.role: Accessible.AlertMessage
            Accessible.name: root.bannerText

            Text {
                id: bannerLabel
                textFormat: Text.PlainText
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    margins: Tokens.spacingMd
                }
                text: root.bannerText
                wrapMode: Text.Wrap
                color: Appearance.colors.destructiveText
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        }

        // The toolbar's edge: a hairline once the page's content has scrolled under the toolbar (ADR-0039 D3, Files' behaviour;
        // until ADR-0024's scroll-edge glass), above the page.
        Rectangle {
            id: toolbarRule
            objectName: "toolbarRule"
            readonly property Flickable flick: page.item as Flickable
            anchors.top: detailToolbar.bottom
            width: parent.width
            height: Tokens.appsBorderWidth
            z: 1
            visible: !banner.visible && toolbarRule.flick !== null && toolbarRule.flick.contentY > toolbarRule.flick.originY
            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }

        Loader {
            id: page
            anchors {
                top: banner.visible ? banner.bottom : detailToolbar.bottom
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            // A malformed file makes every control inert (nothing is written).
            enabled: !cfg.blocked
            opacity: cfg.blocked ? Tokens.materialDisabledOpacity : 1
            sourceComponent: {
                if (root.notificationApp !== "")
                    return notificationAppPage;
                switch (root.selectedId) {
                case "wifi":
                    return wifiPage;
                case "bluetooth":
                    return bluetoothPage;
                case "network":
                    return networkPage;
                case "vpn":
                    return vpnPage;
                case "battery":
                case "energy":
                    return root.hasBattery ? batteryPage : energyPage;
                case "sound":
                    return soundPage;
                case "displays":
                    return displaysPage;
                case "wallpaper":
                    return wallpaperPage;
                case "accessibility":
                    return accessibilityPage;
                case "accessibility-zoom":
                    return accessibilityZoomPage;
                case "accessibility-display":
                    return accessibilityDisplayPage;
                case "accessibility-motion":
                    return accessibilityMotionPage;
                case "accessibility-keyboard":
                    return accessibilityKeyboardPage;
                case "desktop":
                    return desktopPage;
                case "menubar":
                    return menuBarPage;
                case "search":
                    return searchPage;
                case "notifications":
                    return notificationsPage;
                case "focus":
                    return focusPage;
                case "dnd":
                    return dndPage;
                case "lock":
                    return lockPage;
                case "privacy":
                    return privacyPage;
                case "fingerprint":
                    return fingerprintPage;
                case "privacy-location":
                case "privacy-background":
                case "privacy-camera":
                case "privacy-remote-desktop":
                case "privacy-screen-sharing":
                    return privacyCategoryPage;
                case "mouse":
                    return mousePage;
                case "trackpad":
                    return trackpadPage;
                case "printers":
                    return printersPage;
                case "keyboard":
                    return keyboardPage;
                case "general":
                    return generalPage;
                case "about":
                    return aboutPage;
                case "software-update":
                    return softwareUpdatePage;
                case "storage":
                    return storagePage;
                case "datetime":
                    return dateTimePage;
                case "language":
                    return languagePage;
                case "login":
                    return loginItemsPage;
                case "sharing":
                    return sharingPage;
                }
                return appearancePage;
            }
        }
    }

    Component {
        id: wifiPage
        WifiPage {
            backend: root.backend
            system: sys
            onPasswordRequested: net => wifiPassword.openFor(net)
            onForgetRequested: net => forgetNetwork.openFor(net)
            onDetailsRequested: (net, device) => networkDetails.openFor(net, device)
        }
    }

    Component {
        id: networkPage
        NetworkPage {
            backend: root.backend
            system: sys
            onOpenRequested: id => root.select(id)
            onDetailsRequested: (name, device) => networkDetails.openForService(name, device)
        }
    }

    Component {
        id: vpnPage
        VpnPage {
            backend: root.backend
            system: sys
        }
    }

    Component {
        id: batteryPage
        BatteryPage {
            backend: root.backend
            system: sys
            onInfoRequested: (topic, power) => batteryInfo.openFor(topic, power)
            onSetupRequested: id => terminalSetup.openFor(id)
            onOptionsRequested: powerOptionsSheet.open()
        }
    }

    // A computer without a battery (macOS 27 Energy): Energy Mode and Prevent automatic sleeping when the display is off.
    Component {
        id: energyPage
        EnergyPage {
            backend: root.backend
            system: sys
            store: cfg
            onSetupRequested: id => terminalSetup.openFor(id)
        }
    }

    // Battery > Options…: Prevent automatic sleeping when the display is off (on battery and on the power adapter).
    PowerOptionsSheet {
        id: powerOptionsSheet
        store: cfg
    }

    // Battery > (i): Battery Health, Charging (the charge limit goes back to the page).
    BatteryInfoSheet {
        id: batteryInfo
        onLimitRequested: on => {
            (page.item as BatteryPage)?.setLimit(on);
            batteryInfo.close();
        }
    }

    // Wi-Fi: a secured network's password, Details…, Forget This Network…: sheets over the whole window; the page acts on the
    // answers. Network shows an Ethernet service's addresses in the same details sheet.
    WifiPasswordSheet {
        id: wifiPassword
        onJoin: (net, psk) => (page.item as WifiPage)?.join(net, psk)
    }

    NetworkDetailsSheet {
        id: networkDetails
        onForgetRequested: net => forgetNetwork.openFor(net)
        onShareRequested: net => shareNetwork.openFor(net)
        // Share Network… where Omarchy's omarchy-network-qr is installed, looked for when the sheet opens (ADR-0045 OC-10); never
        // in a dev session, whose Wi-Fi pane shows the owner's real network (its code would draw the owner's password into the
        // evidence screenshots; the Backend refuses the query there too: security review of ADR-0045, M-2).
        onShownChanged: {
            if (networkDetails.shown)
                networkDetails.canShare = !sys.dev && root.backend.hasCommand("omarchy-network-qr");
        }
    }

    // Wi-Fi > Details > Share Network…: the current network's QR code (ADR-0045 OC-10).
    ShareNetworkSheet {
        id: shareNetwork
        backend: root.backend
    }

    ForgetNetworkSheet {
        id: forgetNetwork
        onForget: net => (page.item as WifiPage)?.forget(net)
    }

    Component {
        id: bluetoothPage
        BluetoothPage {
            backend: root.backend
            system: sys
            onInfoRequested: device => bluetoothDevice.openFor(device)
            onForgetRequested: device => forgetDevice.openFor(device)
        }
    }

    // Bluetooth: a device's sheet and Forget This Device…; the page acts on the answers.
    BluetoothDeviceSheet {
        id: bluetoothDevice
        onConnectRequested: device => (page.item as BluetoothPage)?.connectDevice(device)
        onForgetRequested: device => forgetDevice.openFor(device)
    }

    ForgetDeviceSheet {
        id: forgetDevice
        onForget: device => (page.item as BluetoothPage)?.forget(device)
    }

    Component {
        id: soundPage
        SoundPage {
            backend: root.backend
            system: sys
            store: cfg
        }
    }

    Component {
        id: displaysPage
        DisplaysPage {
            backend: root.backend
            system: sys
            store: cfg
            onKeepRequested: until => displayKeep.openFor(until)
            onTrialEnded: displayKeep.close()
            onArrangeRequested: monitors => {
                displayArrange.mainName = mainName;
                displayArrange.openFor(monitors);
            }
        }
    }

    // Displays (ADR-0031): keep or revert a change while the shell counts down; Arrange… for several displays.
    DisplayKeepSheet {
        id: displayKeep
        canKeep: (page.item as DisplaysPage)?.trialApplied ?? false
        onKeep: (page.item as DisplaysPage)?.keep()
        onRevert: (page.item as DisplaysPage)?.revert()
    }

    ArrangeSheet {
        id: displayArrange
        onArranged: positions => (page.item as DisplaysPage)?.arrange(positions)
        // The menu bar dragged to another display (ADR-0044): that display becomes the main one, at once.
        onMainChosen: name => (page.item as DisplaysPage)?.makeMain(name)
    }

    Component {
        id: appearancePage
        AppearancePage {
            store: cfg
            backend: root.backend
            system: sys
        }
    }

    Component {
        id: wallpaperPage
        WallpaperPage {
            store: cfg
            requestedDisplay: root.wallpaperDisplay
            backend: root.backend
            onScreenSaverRequested: screenSaverSheet.open()
        }
    }

    Component {
        id: accessibilityPage
        AccessibilityPage {
            onOpen: id => root.select(id)
        }
    }

    Component {
        id: accessibilityZoomPage
        AccessibilityZoomPage {
            store: cfg
        }
    }

    Component {
        id: accessibilityDisplayPage
        AccessibilityDisplayPage {
            store: cfg
        }
    }

    Component {
        id: accessibilityMotionPage
        AccessibilityMotionPage {
            store: cfg
        }
    }

    Component {
        id: accessibilityKeyboardPage
        AccessibilityKeyboardPage {}
    }

    Component {
        id: desktopPage
        DesktopPage {
            store: cfg
            backend: root.backend
            onScreenCornersRequested: screenCornersSheet.open()
        }
    }

    Component {
        id: menuBarPage
        MenuBarPage {
            store: cfg
            hasBattery: root.hasBattery
            backend: root.backend
            onClockOptionsRequested: clockSheet.open()
            onBatteryOptionsRequested: batteryOptionsSheet.open()
        }
    }

    Component {
        id: notificationsPage
        NotificationsPage {
            store: cfg
            backend: root.backend
            onAppRequested: name => root.select(root.notificationAppPrefix + name)
        }
    }

    Component {
        id: searchPage
        SearchPage {
            store: cfg
            onHistoryDeleteRequested: deleteSearchHistory.open()
            onClipboardClearRequested: {
                alsoPinned.checked = false;
                clearClipboardHistory.open();
            }
        }
    }

    Component {
        id: notificationAppPage
        NotificationAppPage {
            store: cfg
            app: root.notificationApp
        }
    }

    Component {
        id: focusPage
        FocusPage {
            store: cfg
            onOpen: id => root.select(id)
        }
    }

    Component {
        id: dndPage
        DoNotDisturbPage {
            store: cfg
        }
    }

    Component {
        id: lockPage
        LockPage {
            store: cfg
            hasBattery: root.hasBattery
            onMessageRequested: lockMessageSheet.open()
        }
    }

    Component {
        id: privacyPage
        PrivacyPage {
            backend: root.backend
            system: sys
            onOpen: id => root.select(id)
            onDiskPasswordRequested: diskPassword.openSheet()
            onSetupRequested: id => terminalSetup.openFor(id)
        }
    }

    // Privacy & Security > Disk Encryption > Change Password… through UDisks2 (ADR-0045 OC-8).
    DiskPasswordSheet {
        id: diskPassword
        system: sys
        backend: root.backend
    }

    // Fingerprint & Security Key (ADR-0045 OC-6): the pane, the enrolment sheet and the deletion's confirmation.
    Component {
        id: fingerprintPage
        FingerprintPage {
            backend: root.backend
            system: sys
            onSetupRequested: id => terminalSetup.openFor(id)
            onEnrollRequested: (finger, stages) => fingerprintEnroll.openFor(finger, stages)
            onDeleteRequested: finger => deleteFingerprint.openFor(finger)
        }
    }

    FingerprintEnrollSheet {
        id: fingerprintEnroll
        backend: root.backend
        system: sys
        onEnded: (page.item as FingerprintPage)?.refresh()
    }

    // Delete…: asked first, as macOS asks before it deletes a fingerprint.
    Sheet {
        id: deleteFingerprint
        property string finger: ""
        title: qsTr("Delete the fingerprint “%1”?").arg(fingerprintEnroll.fingerText(deleteFingerprint.finger))
        message: qsTr("This finger will no longer unlock this computer, approve administrator prompts or run sudo.")
        confirmText: qsTr("Delete")
        destructive: true

        function openFor(finger: string): void {
            deleteFingerprint.finger = finger;
            deleteFingerprint.open();
        }

        onAccepted: sys.act("delete fingerprint", {op: "fprint.delete", finger: deleteFingerprint.finger}, "fprint.act")
    }

    // The setups only Omarchy's terminal can do, behind the sheet that says why (ADR-0045 OC-0.4, OC-0.7): Keyboard's
    // Dictation, Battery's Hibernation, Privacy & Security's disk password without UDisks2, Fingerprint & Security Key, Sharing's
    // first Remote Login.
    TerminalSetupSheet {
        id: terminalSetup
        system: sys
        backend: root.backend
    }

    // A category of Privacy & Security: the section id names its key in the permission state (Privacy.js).
    Component {
        id: privacyCategoryPage
        PrivacyCategoryPage {
            backend: root.backend
            system: sys
            key: ({"privacy-location": "location", "privacy-background": "background", "privacy-camera": "camera",
                    "privacy-remote-desktop": "remoteDesktop", "privacy-screen-sharing": "screencast"})[root.selectedId] ?? "location"
        }
    }

    Component {
        id: mousePage
        MousePage {
            backend: root.backend
            onOpenRequested: id => root.select(id)
        }
    }

    Component {
        id: trackpadPage
        TrackpadPage {
            backend: root.backend
            onOpenRequested: id => root.select(id)
        }
    }

    Component {
        id: printersPage
        PrintersPage {
            backend: root.backend
            system: sys
            onDetailsRequested: printer => printerSheet.openFor(printer)
            onAddRequested: {
                (page.item as PrintersPage)?.startSearching();
                addPrinter.openWith();
            }
        }
    }

    // Printers: a printer's sheet, Remove Printer…'s confirmation and Add Printer…; the page acts on the answers.
    PrinterSheet {
        id: printerSheet
        onRemoveRequested: printer => removePrinter.openFor(printer)
        onResumeRequested: name => (page.item as PrintersPage)?.resume(name)
    }

    RemovePrinterSheet {
        id: removePrinter
        onRemove: name => (page.item as PrintersPage)?.remove(name)
    }

    AddPrinterSheet {
        id: addPrinter
        found: (page.item as PrintersPage)?.found ?? []
        answered: (page.item as PrintersPage)?.foundAnswered ?? false
        onPicked: printer => (page.item as PrintersPage)?.add(printer)
        onShownChanged: {
            if (!addPrinter.shown)
                (page.item as PrintersPage)?.stopSearching();
        }
    }

    Component {
        id: keyboardPage
        KeyboardPage {
            backend: root.backend
            store: cfg
            onShortcutsRequested: list => keyboardShortcuts.openWith(list, root.backend.bindingsFile)
            onSourcesRequested: (sources, layouts) => inputSources.openWith(sources, layouts)
            onSetupRequested: id => terminalSetup.openFor(id)
        }
    }

    // Keyboard: the shortcuts, read-only; Input Sources and the layout to add (the page writes each change).
    KeyboardShortcutsSheet {
        id: keyboardShortcuts
    }

    InputSourcesSheet {
        id: inputSources
        onChanged: list => (page.item as KeyboardPage)?.setSources(list)
        onAddRequested: (layouts, used) => layoutPicker.openWith(layouts, used)
    }

    LayoutPickerSheet {
        id: layoutPicker
        onPicked: source => inputSources.add(source)
    }

    Component {
        id: generalPage
        GeneralPage {
            updateCount: updateState.count
            onOpen: id => root.select(id)
        }
    }

    Component {
        id: softwareUpdatePage
        SoftwareUpdatePage {
            updates: updateState
            store: cfg
            system: sys
            onInfoRequested: topic => updateSheet.openFor(topic)
            onEndSessionRequested: action => (action === "restart" ? restartSheet : logOutSheet).open()
        }
    }

    // Software Update's (i) sheets, More Info… and the other updates.
    SoftwareUpdateSheet {
        id: updateSheet
        updates: updateState
        store: cfg
    }

    // Software Update > Log Out…, Restart… (U14): asked first, in the words of the Grassfield menu; then the session ends the way
    // that menu ends it (grassfield-session-end: every application may keep its window to save its work).
    Sheet {
        id: logOutSheet
        title: qsTr("Are you sure you want to quit all applications and log out now?")
        message: qsTr("Open applications will be closed.")
        confirmText: qsTr("Log Out")
        onAccepted: updateState.endSession("logout")
    }

    Sheet {
        id: restartSheet
        title: qsTr("Are you sure you want to restart your computer now?")
        message: qsTr("Open applications will be closed.")
        confirmText: qsTr("Restart")
        onAccepted: updateState.endSession("restart")
    }

    // Update Now's end (U29, owner decision SU-M1): when the run this window watched asks for a restart or a log out, it asks
    // once, as macOS does; Later keeps the pane's row. Nothing restarts by itself.
    Sheet {
        id: finishSheet
        property string action: "restart"
        title: finishSheet.action === "restart" ? qsTr("Restart your computer to finish updating") : qsTr("Log out to finish updating Grassfield")
        message: finishSheet.action === "restart" ? qsTr("The updates are installed. Open applications will be closed when the computer restarts.")
            : qsTr("The new version of Grassfield starts when you log in again. Open applications will be closed.")
        cancelText: finishSheet.action === "restart" ? qsTr("Restart Later") : qsTr("Log Out Later")
        confirmText: finishSheet.action === "restart" ? qsTr("Restart") : qsTr("Log Out")
        onAccepted: updateState.endSession(finishSheet.action)
    }

    Connections {
        target: updateState
        function onRunFinished(result: string, restart: string): void {
            if (result === "done" && (restart === "restart" || restart === "logout") && !updateState.restartBlocked) {
                finishSheet.action = restart;
                finishSheet.open();
            }
        }
    }

    Component {
        id: aboutPage
        AboutPage {
            backend: root.backend
            system: sys
        }
    }

    Component {
        id: dateTimePage
        DateTimePage {
            backend: root.backend
            system: sys
            store: cfg
            onSetRequested: wall => timeSheet.openAt(wall)
        }
    }

    Component {
        id: storagePage
        StoragePage {
            backend: root.backend
            onAllVolumesRequested: volumesSheet.open()
        }
    }

    // Storage > All Volumes…: a sheet over the whole window.
    VolumesSheet {
        id: volumesSheet
        backend: root.backend
    }

    Component {
        id: loginItemsPage
        LoginItemsPage {
            backend: root.backend
            system: sys
            onAddRequested: apps => appPicker.openWith(apps)
        }
    }

    // General > Sharing: Remote Login (ADR-0045 OC-7).
    Component {
        id: sharingPage
        SharingPage {
            backend: root.backend
            system: sys
            onSetupRequested: id => terminalSetup.openFor(id)
        }
    }

    // Login Items > +: a sheet over the whole window; the page writes the choice.
    AppPickerSheet {
        id: appPicker
        onChosen: app => (page.item as LoginItemsPage)?.add(app)
    }

    Component {
        id: languagePage
        LanguagePage {
            backend: root.backend
            system: sys
            store: cfg
        }
    }

    // Date & Time > Set…: a sheet over the whole window; the page sends the answer to timedate1.
    SetDateTimeSheet {
        id: timeSheet
        onChosen: wall => (page.item as DateTimePage)?.setWallClock(wall)
    }

    // Menu Bar > Clock Options…: a sheet over the whole window.
    ClockOptionsSheet {
        id: clockSheet
        store: cfg
    }

    // Search > Delete Search History…: asked first, as macOS does; Search forgets the results picked before now.
    Sheet {
        id: deleteSearchHistory
        title: qsTr("Delete your search history?")
        message: qsTr("Search forgets the results you picked, so it no longer puts them first.")
        confirmText: qsTr("Delete")
        destructive: true
        onAccepted: cfg.set("search.historyResetAt", Date.now())
    }

    // Search > Clear Clipboard History…: asked first (macOS 27: Clear Clipboard History, then Clear). The shell's clipboard
    // history deletes the items not pinned; with "Also delete pinned items" the pinned ones too, from memory and the disk
    // (ADR-0034 §6). SearchPage.clearClipboard writes both keys at once.
    Sheet {
        id: clearClipboardHistory
        title: qsTr("Clear your clipboard history?")
        message: qsTr("The items you copied are deleted from Search. Pinned items stay unless you delete them too.")
        confirmText: qsTr("Clear")
        destructive: true
        onAccepted: (page.item as SearchPage)?.clearClipboard(alsoPinned.checked)

        CheckBox {
            id: alsoPinned
            text: qsTr("Also delete pinned items")
        }
    }

    // Wallpaper > Screen Saver… (ADR-0032); Lock Screen Settings… in its note opens the Lock Screen pane.
    ScreenSaverSheet {
        id: screenSaverSheet
        store: cfg
        hasBattery: root.hasBattery
        onLockScreenRequested: {
            screenSaverSheet.close();
            root.select("lock");
        }
    }

    // Lock Screen > Show message when locked > Set…
    LockMessageSheet {
        id: lockMessageSheet
        store: cfg
    }

    // Menu Bar > Battery Options…
    BatteryOptionsSheet {
        id: batteryOptionsSheet
        store: cfg
    }

    // Desktop & Dock > Screen Corners…
    ScreenCornersSheet {
        id: screenCornersSheet
        store: cfg
    }

    // Every sheet of the window. Each gives the keyboard focus back, when it closes, to what had it as the sheet appeared (the
    // page's button that opened it; Sheet.open shows the sheet before it moves the focus into its panel): focusBack.
    readonly property list<Item> sheets: [batteryInfo, wifiPassword, networkDetails, forgetNetwork, bluetoothDevice, forgetDevice,
        displayKeep, displayArrange, printerSheet, removePrinter, addPrinter, keyboardShortcuts, inputSources, layoutPicker,
        volumesSheet, appPicker, timeSheet, clockSheet, deleteSearchHistory, clearClipboardHistory, screenSaverSheet,
        lockMessageSheet, batteryOptionsSheet, powerOptionsSheet, screenCornersSheet, updateSheet, logOutSheet, restartSheet, finishSheet,
        shareNetwork, diskPassword, fingerprintEnroll, deleteFingerprint, terminalSetup]

    Instantiator {
        model: root.sheets

        delegate: Connections {
            id: opener
            required property Sheet modelData
            target: opener.modelData

            function onShownChanged(): void {
                if (opener.modelData.shown)
                    opener.modelData.focusBack = root.activeFocusItem;
            }
        }
    }
}
