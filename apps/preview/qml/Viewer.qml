pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Grassfield Preview: floating toolbar (sidebar, title and "n of N", previous/next, zoom, rotate, info, search), thumbnail
// sidebar (the files of the folder when several are open, page thumbnails for PDF) and the view of the current file.
// Nothing is ever written: zoom, rotation and page are properties of the view.
Window {
    id: viewerWin
    // A rule or frame: one point (apps.borderWidth, ADR-0039 D5) in whole device pixels, 1 px at 1.25 where 1 pt drew a soft
    // 1.25 px (UI audit 2026-11-05 U37); 1 px at 1x and 2 px at 2x as before.
    readonly property real hairline: Math.max(1, Math.round(Tokens.appsBorderWidth * Screen.devicePixelRatio)) / Math.max(1, Screen.devicePixelRatio)

    // Set by the launcher (src/main.cpp).
    required property var backend
    // The registrar is there (kept up to date by src/main.cpp): the window exports its menus to the global menu bar.
    required property bool globalMenu

    // Drawn as key (ADR-0039 step 17): active, or held while a shell menu or the Control Center is open (Appearance.looksKey).
    readonly property bool keyLook: Appearance.looksKey(viewerWin, viewerWin.active)
    property int current: viewerWin.backend.startIndex
    // Several files named on the command line show their list at once; the folder of a single image starts without it.
    property bool sidebarOpen: !viewerWin.backend.browsing
    property bool searchOpen: false
    property bool infoOpen: false
    property bool slideshow: false
    property bool slideshowPaused: false
    // ADR-0015: the window draws its own chrome (the unified toolbar below); the apps' tagger (apps/windowchrome.h) names
    // its role for the compositor, whose plugin then draws no titlebar on it.
    property string gfChromeRole: "viewer"
    readonly property int fileCount: viewerWin.backend.files.length
    readonly property bool canGoPrevious: viewerWin.current > 0
    readonly property bool canGoNext: viewerWin.current < viewerWin.fileCount - 1
    readonly property var view: content.view
    readonly property bool isPdf: content.info.kind === "pdf" && content.info.ok === true
    readonly property bool hasSidebar: viewerWin.fileCount > 1 || viewerWin.isPdf
    // What the toolbar needs beside the sidebar: its inset, the toggle, the tools and their margins. A window narrower than the
    // sidebar plus this collapses the sidebar by itself (as macOS) and shows it again when it widens, if it was open; the
    // toolbar's items never overlap.
    // The open search counts with its least width (preview.searchMinWidth), not its full one: opening it keeps the thumbnails
    // wherever that fits, and the field takes what room is left up to its own width (UI audit 2026-11-05, LOW).
    readonly property real toolsClosedWidth: {
        let w = 0;
        let n = 0;
        for (const c of tools.children) {
            if (!c.visible)
                continue;
            w += c === searchBox ? Tokens.toolbarCapsule : c.width;
            n++;
        }
        return w + Math.max(0, n - 1) * tools.spacing;
    }
    readonly property real searchExtra: searchBox.visible && viewerWin.searchOpen ? Tokens.previewSearchMinWidth - Tokens.toolbarCapsule : 0
    readonly property real toolbarRest: (sidebarGroup.visible ? sidebarGroup.width + Tokens.spacingMd : 0) + viewerWin.toolsClosedWidth + viewerWin.searchExtra + Tokens.spacingMd
    readonly property real toolbarNeed: Tokens.windowItemsInset + viewerWin.toolbarRest
    // The narrowest window: the toolbar with the lights in it (the sidebar hidden), so its items never overlap.
    readonly property real toolbarMin: Math.max(toolbar.controls.contentStart, Tokens.windowItemsInset) + viewerWin.toolbarRest
    readonly property bool roomForSidebar: viewerWin.width >= Tokens.previewSidebarWidth + viewerWin.toolbarNeed
    readonly property bool showSidebar: viewerWin.sidebarOpen && viewerWin.hasSidebar && viewerWin.roomForSidebar
    // The sidebar toggle (button and shortcut) is off while the window is too narrow for the sidebar: a client cannot resize its
    // own window on Wayland, so Preview never writes its width; widening the window brings the sidebar back if it is wanted.
    readonly property bool canToggleSidebar: viewerWin.hasSidebar && viewerWin.roomForSidebar
    // A text file's first lines for its sidebar plate: read on the backend's worker (snippetFor, never on this thread while
    // the list scrolls); a backend without it (the tests' doubles) answers at once. `revision` only makes a binding read
    // it again when a snippet comes in.
    function snippetOf(index: int, revision: var): string {
        if (typeof viewerWin.backend.snippetFor === "function")
            return viewerWin.backend.snippetFor(index);
        return viewerWin.backend.textSnippet ? viewerWin.backend.textSnippet(index) : "";
    }

    function toggleSidebar(): void {
        if (viewerWin.canToggleSidebar)
            viewerWin.sidebarOpen = !viewerWin.sidebarOpen;
    }
    readonly property int pages: viewerWin.view ? viewerWin.view.pageCount : 1
    readonly property bool onImage: content.info.kind === "image" && content.info.ok === true
    // Second line of the title: the position among the files, then the page of a document.
    readonly property string subtitle: {
        const parts = [];
        if (viewerWin.fileCount > 1)
            parts.push(qsTr("%1 of %2").arg(viewerWin.current + 1).arg(viewerWin.fileCount));
        if (viewerWin.pages > 1)
            parts.push(qsTr("Page %1 of %2").arg((viewerWin.view?.currentPage ?? 0) + 1).arg(viewerWin.pages));
        return parts.join("  ·  ");
    }

    title: content.info.name ? DisplayName.text(content.info.name) : qsTr("Preview")
    width: Tokens.previewWindowWidth
    height: Tokens.previewWindowHeight
    minimumWidth: Math.max(Tokens.previewWindowMinWidth, Math.ceil(viewerWin.toolbarMin))
    minimumHeight: Tokens.previewWindowMinHeight
    visible: true
    color: Appearance.windowFill

    Theme {
        backend: viewerWin.backend
    }

    // Previous or next file of the list (no wrap, like a file manager); a slideshow keeps its own timer.
    function go(delta: int): void {
        const next = Math.max(0, Math.min(viewerWin.fileCount - 1, viewerWin.current + delta));
        if (next !== viewerWin.current)
            viewerWin.current = next;
    }

    function openSearch(): void {
        viewerWin.searchOpen = true;
        searchInput.forceActiveFocus();
        searchInput.selectAll();
    }

    function closeSearch(): void {
        viewerWin.searchOpen = false;
        searchInput.text = "";
        content.forceActiveFocus();
        if (viewerWin.view)
            viewerWin.view.forceActiveFocus();
    }

    function toggleSlideshow(): void {
        if (viewerWin.slideshow) {
            viewerWin.endSlideshow();
            return;
        }
        if (viewerWin.fileCount < 2)
            return;
        viewerWin.slideshowPaused = false;
        viewerWin.slideshow = true;
        viewerWin.visibility = Window.FullScreen;
    }

    function endSlideshow(): void {
        viewerWin.slideshow = false;
        viewerWin.visibility = Window.Windowed;
    }

    onCurrentChanged: {
        if (viewerWin.searchOpen)
            viewerWin.closeSearch();
    }

    // Global menu (T1). Its shortcuts repeat some of the ones below: every Shortcut whose key is also a menu shortcut
    // acts on activatedAmbiguously too (Qt hands such a key to one of the two per press, see GlobalMenu.qml).
    Loader {
        active: viewerWin.globalMenu
        sourceComponent: GlobalMenu {
            win: viewerWin
        }
    }

    // A slideshow shows each file for a while, then stops after the last one.
    Timer {
        interval: Tokens.previewSlideshowInterval
        repeat: true
        running: viewerWin.slideshow && !viewerWin.slideshowPaused
        onTriggered: {
            if (viewerWin.canGoNext)
                viewerWin.go(1);
            else
                viewerWin.endSlideshow();
        }
    }

    // Keys: plain keys are ignored while the search field has the focus.
    Shortcut {
        sequence: "Ctrl+W"
        onActivated: viewerWin.close()
        onActivatedAmbiguously: viewerWin.close()
    }
    Shortcut {
        sequence: "Ctrl+Q"
        onActivated: Qt.quit()
    }
    Shortcut {
        sequence: "Ctrl+F"
        enabled: viewerWin.view?.canSearch ?? false
        onActivated: viewerWin.openSearch()
        onActivatedAmbiguously: viewerWin.openSearch()
    }
    Shortcut {
        sequence: "Ctrl+G"
        enabled: (viewerWin.view?.canSearch ?? false) && viewerWin.searchOpen
        onActivated: viewerWin.view.nextMatch()
        onActivatedAmbiguously: viewerWin.view.nextMatch()
    }
    Shortcut {
        sequence: "Ctrl+Shift+G"
        enabled: (viewerWin.view?.canSearch ?? false) && viewerWin.searchOpen
        onActivated: viewerWin.view.previousMatch()
        onActivatedAmbiguously: viewerWin.view.previousMatch()
    }
    Shortcut {
        sequences: ["Ctrl+Alt+2", "Ctrl+Shift+S"]
        enabled: viewerWin.canToggleSidebar
        onActivated: viewerWin.toggleSidebar()
        onActivatedAmbiguously: viewerWin.toggleSidebar()
    }
    Shortcut {
        sequence: "Ctrl+I"
        onActivated: viewerWin.infoOpen = !viewerWin.infoOpen
        onActivatedAmbiguously: viewerWin.infoOpen = !viewerWin.infoOpen
    }
    Shortcut {
        sequence: "Ctrl+Shift+F"
        enabled: viewerWin.fileCount > 1
        onActivated: viewerWin.toggleSlideshow()
        onActivatedAmbiguously: viewerWin.toggleSlideshow()
    }
    Shortcut {
        sequence: "Ctrl+R"
        enabled: viewerWin.view?.canRotate ?? false
        onActivated: viewerWin.view.rotate(1)
        onActivatedAmbiguously: viewerWin.view.rotate(1)
    }
    Shortcut {
        sequence: "Ctrl+L"
        enabled: viewerWin.view?.canRotate ?? false
        onActivated: viewerWin.view.rotate(-1)
        onActivatedAmbiguously: viewerWin.view.rotate(-1)
    }
    Shortcut {
        sequences: ["+", "=", "Ctrl++", "Ctrl+="]
        enabled: (viewerWin.view?.canZoom ?? false) && !searchInput.activeFocus
        onActivated: viewerWin.view.zoomIn()
        onActivatedAmbiguously: viewerWin.view.zoomIn()
    }
    Shortcut {
        sequences: ["-", "Ctrl+-"]
        enabled: (viewerWin.view?.canZoom ?? false) && !searchInput.activeFocus
        onActivated: viewerWin.view.zoomOut()
        onActivatedAmbiguously: viewerWin.view.zoomOut()
    }
    Shortcut {
        sequences: ["0", "Ctrl+0"]
        enabled: (viewerWin.view?.canZoom ?? false) && !searchInput.activeFocus
        onActivated: viewerWin.view.actualSize()
        onActivatedAmbiguously: viewerWin.view.actualSize()
    }
    Shortcut {
        sequence: "Ctrl+9"
        enabled: viewerWin.view?.canZoom ?? false
        onActivated: viewerWin.view.fit()
        onActivatedAmbiguously: viewerWin.view.fit()
    }
    Shortcut {
        sequence: "Left"
        enabled: viewerWin.fileCount > 1 && !searchInput.activeFocus
        onActivated: viewerWin.go(-1)
        onActivatedAmbiguously: viewerWin.go(-1)
    }
    Shortcut {
        sequence: "Right"
        enabled: viewerWin.fileCount > 1 && !searchInput.activeFocus
        onActivated: viewerWin.go(1)
        onActivatedAmbiguously: viewerWin.go(1)
    }
    // Page Up and Down turn the pages of a multi-page image; on any other image they go to the previous and next file.
    Shortcut {
        sequence: "PgUp"
        enabled: viewerWin.onImage && !searchInput.activeFocus && (viewerWin.pages > 1 || viewerWin.fileCount > 1)
        onActivated: viewerWin.pages > 1 ? viewerWin.view.goToPage(viewerWin.view.currentPage - 1) : viewerWin.go(-1)
    }
    Shortcut {
        sequence: "PgDown"
        enabled: viewerWin.onImage && !searchInput.activeFocus && (viewerWin.pages > 1 || viewerWin.fileCount > 1)
        onActivated: viewerWin.pages > 1 ? viewerWin.view.goToPage(viewerWin.view.currentPage + 1) : viewerWin.go(1)
    }
    Shortcut {
        sequence: "Space"
        enabled: (content.info.kind === "audio" || content.info.kind === "video" || viewerWin.slideshow) && !searchInput.activeFocus
        onActivated: viewerWin.slideshow ? viewerWin.slideshowPaused = !viewerWin.slideshowPaused : viewerWin.view.togglePlay()
    }
    Shortcut {
        sequence: "Esc"
        enabled: viewerWin.searchOpen || viewerWin.infoOpen || viewerWin.slideshow
        onActivated: {
            if (viewerWin.slideshow)
                viewerWin.endSlideshow();
            else if (viewerWin.infoOpen)
                viewerWin.infoOpen = false;
            else
                viewerWin.closeSearch();
        }
    }

    // ---- toolbar ---------------------------------------------------------------------------------

    // The unified toolbar of grassfield-ui (ADR-0015): the lights, then the sidebar toggle, the two-line title block and the
    // tools; its layer for a layout of its own holds them.
    // The lights of a shown sidebar sit in the corner of its panel (as Files and Settings; macOS 26): this toolbar over the
    // sidebar holds them alone, the one over the view starts to its right.
    UnifiedToolbar {
        id: sidebarToolbar
        objectName: "sidebarToolbar"
        width: sidebar.width
        height: Tokens.previewToolbarHeight
        visible: sidebar.visible
        z: 2
        window: viewerWin
        showTitle: false
        doubleClickAction: viewerWin.backend.titlebarDoubleClick
        canMinimize: viewerWin.backend.canMinimize
    }

    UnifiedToolbar {
        id: toolbar
        x: sidebar.width
        width: parent.width - x
        height: viewerWin.slideshow ? 0 : Tokens.previewToolbarHeight
        visible: !viewerWin.slideshow
        z: 2
        window: viewerWin
        // The lights move here when the sidebar is hidden (View > Hide Sidebar), as Files.
        showControls: !sidebar.visible
        showTitle: false
        doubleClickAction: viewerWin.backend.titlebarDoubleClick
        canMinimize: viewerWin.backend.canMinimize

        ToolbarGroup {
            id: sidebarGroup
            x: toolbar.contentStart
            anchors.verticalCenter: parent.verticalCenter
            visible: viewerWin.hasSidebar

            ToolButton {
                capsule: true
                accessibleName: qsTr("Thumbnails")
                enabled: viewerWin.canToggleSidebar
                tooltip: viewerWin.canToggleSidebar ? qsTr("Thumbnails") : qsTr("Make the window wider to show the sidebar")
                checkable: true
                checked: viewerWin.showSidebar
                // One white disc, as macOS 27: the group's own capsule is the disc; a checked pill inside it would be a second one.
                checkedColor: "transparent"
                onClicked: viewerWin.toggleSidebar()

                Glyph {
                    anchors.centerIn: parent
                    kind: "sidebar"
                }
            }
        }

        // Title and subtitle ("3 of 12", "Page 2 of 8"): the same place as the macOS toolbar.
        Column {
            id: titleBlock
            anchors {
                left: sidebarGroup.visible ? sidebarGroup.right : parent.left
                // Without the sidebar toggle the title is the first item after the lights: it starts at the toolbar's
                // contentStart, as every app's leading items do, not at the window's edge under them.
                leftMargin: sidebarGroup.visible ? Tokens.spacingMd : toolbar.contentStart
                right: tools.left
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            visible: width > 0

            Text {
                width: parent.width
                elide: Text.ElideMiddle
                textFormat: Text.PlainText
                text: viewerWin.title
                // Dimmed while the window is not key (macOS 27; ADR-0039 step 17).
                color: viewerWin.keyLook ? Appearance.colors.text : Appearance.withAlpha(Appearance.colors.text, Appearance.inactiveTextOpacity)
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: Tokens.typographyTitleWeight
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }
            Text {
                width: parent.width
                visible: text !== ""
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: viewerWin.subtitle
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }

        Row {
            id: tools
            objectName: "toolsRow"
            anchors {
                right: parent.right
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            spacing: Tokens.spacingMd

            ToolbarGroup {
                visible: viewerWin.fileCount > 1

                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Previous")
                    enabled: viewerWin.canGoPrevious
                    onClicked: viewerWin.go(-1)

                    Glyph {
                        anchors.centerIn: parent
                        kind: "chevronLeft"
                    }
                }
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Next")
                    enabled: viewerWin.canGoNext
                    onClicked: viewerWin.go(1)

                    Glyph {
                        anchors.centerIn: parent
                        kind: "chevronRight"
                    }
                }
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Slideshow")
                    onClicked: viewerWin.toggleSlideshow()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "play"
                    }
                }
            }

            ToolbarGroup {
                visible: viewerWin.view?.canZoom ?? false

                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Zoom Out")
                    onClicked: viewerWin.view.zoomOut()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "zoomOut"
                    }
                }
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Zoom to Fit")
                    onClicked: viewerWin.view.fit()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "fit"
                    }
                }
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Zoom In")
                    onClicked: viewerWin.view.zoomIn()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "zoomIn"
                    }
                }
            }

            ToolbarGroup {
                visible: viewerWin.view?.canRotate ?? false

                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Rotate Left")
                    onClicked: viewerWin.view.rotate(-1)

                    Glyph {
                        anchors.centerIn: parent
                        kind: "rotateLeft"
                    }
                }
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Rotate Right")
                    onClicked: viewerWin.view.rotate(1)

                    Glyph {
                        anchors.centerIn: parent
                        kind: "rotateRight"
                    }
                }
            }

            ToolbarGroup {
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Info")
                    checkable: true
                    checked: viewerWin.infoOpen
                    onClicked: viewerWin.infoOpen = !viewerWin.infoOpen

                    Glyph {
                        anchors.centerIn: parent
                        kind: "info"
                    }
                }
            }

            // Search (PDF): a circle that opens into a field.
            Item {
                id: searchBox
                visible: viewerWin.view?.canSearch ?? false
                // Open: its own width where the toolbar has it, else the room the other items leave (the title yields), never
                // under preview.searchMinWidth (the window's minimum counts that much).
                readonly property real spare: toolbar.width - (sidebarGroup.visible ? sidebarGroup.x + sidebarGroup.width + Tokens.spacingMd : toolbar.contentStart)
                    - viewerWin.toolsClosedWidth - Tokens.spacingMd
                width: viewerWin.searchOpen ? Math.floor(Math.max(Tokens.previewSearchMinWidth, Math.min(Tokens.previewSearchWidth, Tokens.toolbarCapsule + searchBox.spare))) : Tokens.toolbarCapsule
                height: Tokens.toolbarCapsule

                // Closed: the toolbar's rimmed glass capsule, as the groups beside it (ADR-0039 step 16).
                RimmedCapsule {
                    anchors.fill: parent
                    visible: !viewerWin.searchOpen
                    fillOpacity: Tokens.toolbarCapsuleFillOpacity
                }

                ToolButton {
                    anchors.centerIn: parent
                    visible: !viewerWin.searchOpen
                    capsule: true
                    accessibleName: qsTr("Search in document")
                    onClicked: viewerWin.openSearch()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "search"
                    }
                }

                // Open: the shared toolbar search field (UI audit 2026-11-05 U34: its clear button, focus ring and window
                // states), the matches' count before the clear button.
                SearchField {
                    id: searchInput
                    visible: viewerWin.searchOpen
                    toolbar: true
                    width: parent.width
                    anchors.verticalCenter: parent.verticalCenter
                    rightPadding: Tokens.spacingSm + (searchInput.text !== "" ? Tokens.menuIconSize + Tokens.spacingSm + matches.implicitWidth + Tokens.spacingSm : 0)
                    Accessible.name: qsTr("Search in document")
                    Keys.onPressed: event => {
                        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && viewerWin.view) {
                            if (event.modifiers & Qt.ShiftModifier)
                                viewerWin.view.previousMatch();
                            else
                                viewerWin.view.nextMatch();
                            event.accepted = true;
                        }
                    }

                    Text {
                        id: matches
                        anchors {
                            right: parent.right
                            rightMargin: Tokens.menuIconSize + Tokens.spacingSm
                            verticalCenter: parent.verticalCenter
                        }
                        visible: searchInput.text !== ""
                        textFormat: Text.PlainText
                        text: viewerWin.view && viewerWin.view.matches !== undefined ? qsTr("%1 found").arg(viewerWin.view.matches) : ""
                        color: Appearance.windowSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }
                }
            }
        }
    }

    // ---- info -------------------------------------------------------------------------------------

    Item {
        id: info
        z: 3
        visible: viewerWin.infoOpen && !viewerWin.slideshow
        x: viewerWin.width - width - Tokens.spacingMd
        y: toolbar.height
        width: Tokens.previewInfoWidth
        height: infoRows.height + 2 * Tokens.spacingMd
        Accessible.role: Accessible.Pane
        Accessible.name: qsTr("Info")

        // A popover: the menus' class (ADR-0039 step 22).
        Material {
            glassClass: "menu"
            anchors.fill: parent
            radius: Tokens.radiusMenu
        }

        Column {
            id: infoRows
            x: Tokens.spacingMd
            y: Tokens.spacingMd
            width: parent.width - 2 * Tokens.spacingMd

            Repeater {
                model: {
                    const i = content.info;
                    const rows = [[qsTr("Name"), DisplayName.text(i.name)], [qsTr("Kind"), i.type ?? ""]];
                    if (i.width !== undefined && i.height !== undefined)
                        rows.push([qsTr("Dimensions"), qsTr("%1 × %2 pixels").arg(i.width).arg(i.height)]);
                    rows.push([qsTr("Size"), i.size ?? ""], [qsTr("Modified"), i.modified ?? ""], [qsTr("Where"), i.folder ?? ""]);
                    return rows;
                }

                Item {
                    id: infoRow

                    required property var modelData

                    width: infoRows.width
                    height: Tokens.previewInfoRowHeight
                    Accessible.role: Accessible.StaticText
                    Accessible.name: qsTr("%1: %2").arg(infoRow.modelData[0]).arg(infoRow.modelData[1])

                    Text {
                        id: infoLabel
                        width: Tokens.previewInfoWidth / 3
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: infoRow.modelData[0]
                        color: Appearance.colors.textSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }
                    Text {
                        anchors {
                            left: infoLabel.right
                            leftMargin: Tokens.spacingSm
                            right: parent.right
                            verticalCenter: parent.verticalCenter
                        }
                        elide: Text.ElideMiddle
                        textFormat: Text.PlainText
                        text: DisplayName.text(infoRow.modelData[1])
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }
                }
            }
        }
    }

    // The toolbar's edge: a hairline once the view's content has scrolled under the toolbar (ADR-0039 D3, as Files and
    // Settings; until ADR-0024's scroll-edge glass).
    Rectangle {
        id: toolbarRule
        objectName: "toolbarRule"
        anchors.top: toolbar.bottom
        x: toolbar.x
        width: toolbar.width
        height: viewerWin.hairline
        z: 2
        visible: !viewerWin.slideshow && viewerWin.view !== null && viewerWin.view.scrolled === true
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    // ---- sidebar -----------------------------------------------------------------------------------

    Item {
        id: sidebar
        anchors {
            top: parent.top
            bottom: parent.bottom
            left: parent.left
        }
        width: viewerWin.showSidebar && !viewerWin.slideshow ? Tokens.previewSidebarWidth : 0
        visible: width > 0
        // Above the view: the panel's shadow falls on it (not clipped, so it can).
        z: 1

        // The floating panel as Settings' and Files' (macOS 26; ADR-0024 amendment 2026-11-03): inset from the window's left, top and
        // bottom edges, the view straight beside it, the lights (sidebarToolbar) drawn over its corner.
        SidebarPanel {
            id: panel
            // Where the lists start: under the lights' row, as Files' sidebar rows.
            readonly property real contentTop: Math.max(sidebarToolbar.height - Tokens.windowSidebarPanelInset, 0) + Tokens.spacingSm
            anchors {
                fill: parent
                leftMargin: Tokens.windowSidebarPanelInset
                topMargin: Tokens.windowSidebarPanelInset
                bottomMargin: Tokens.windowSidebarPanelInset
            }

            // Files: thumbnails of the images, names of the other kinds. Beside the page thumbnails of a PDF they are
            // a short list of names.
            ListView {
                id: fileList

                readonly property bool compact: viewerWin.isPdf

                anchors {
                    top: parent.top
                    left: parent.left
                    right: parent.right
                    margins: Tokens.spacingSm
                    topMargin: panel.contentTop
                    // The picture plates leave the right gap to the scroll bar: the list runs to the panel's edge.
                    rightMargin: fileList.compact ? Tokens.spacingSm : 0
                }
                height: viewerWin.fileCount > 1 ? (fileList.compact ? Math.min(contentHeight, panel.height / 3) : panel.height - panel.contentTop - Tokens.spacingSm) : 0
                visible: viewerWin.fileCount > 1
                clip: true
                spacing: Tokens.spacingXs
                model: viewerWin.backend.files
                currentIndex: viewerWin.current
                highlightMoveDuration: 0
                Accessible.role: Accessible.List
                Accessible.name: qsTr("Files")

                onCurrentIndexChanged: fileList.positionViewAtIndex(fileList.currentIndex, ListView.Contain)
                Component.onCompleted: fileList.positionViewAtIndex(fileList.currentIndex, ListView.Center)

                // The overlay scroll bar every list of the apps shows (ADR-0039 step 16).
                ScrollBar.vertical: ScrollBar {}

                delegate: Item {
                    id: row

                    required property int index
                    required property var modelData
                    readonly property bool selected: row.index === viewerWin.current
                    // The picture's height over its width (3:4 until a picture is decoded, and for the other kinds): the plate
                    // hugs the picture with the same padding on all sides. A tall picture is fitted into a square.
                    readonly property real aspect: pic.visible && pic.implicitWidth > 0 && pic.implicitHeight > 0 ? pic.implicitHeight / pic.implicitWidth : 3 / 4
                    readonly property real cellHeight: Math.round(Math.min(Tokens.previewThumbnailWidth * row.aspect, Tokens.previewThumbnailWidth))
                    readonly property real cellWidth: Math.round(row.cellHeight / row.aspect)
                    // The name's strip under the picture, inside the plate.
                    readonly property real captionHeight: Math.max(Tokens.previewPlateCaption, labelText.implicitHeight + Tokens.spacingSm)
                    // The accent in the key window, the shared unemphasized grey otherwise (UI audit 2026-11-05 U16).
                    readonly property color plateColor: viewerWin.keyLook ? Appearance.colors.selection : Appearance.unemphasizedSelection
                    // The plate: the page thumbnails' (a fixed width, 8 in from the list's left edge, the right gap holding the scroll bar).
                    readonly property real plateSlot: Tokens.previewThumbnailWidth + 2 * Tokens.previewPlatePad
                    // The plate hugs the picture: the same padding on all sides, centred in the slot (a portrait one is narrower).
                    readonly property real plateWidth: row.cellWidth + 2 * Tokens.previewPlatePad
                    readonly property real plateX: Tokens.spacingSm + (row.plateSlot - row.plateWidth) / 2

                    width: fileList.width
                    height: fileList.compact ? Tokens.previewSidebarItemHeight : Tokens.previewPlatePad + row.cellHeight + row.captionHeight
                    Accessible.role: Accessible.ListItem
                    Accessible.name: DisplayName.text(row.modelData.name)
                    Accessible.selected: row.selected

                    // Selection (macOS Preview, as the page thumbnails): the picture and its name on a rounded plate, the accent
                    // for the current file (compact: the row filled the same way, as a macOS list); a light plate under the
                    // hovered one. The list never takes the keyboard, so no focus ring.
                    Rectangle {
                        anchors {
                            fill: parent
                            leftMargin: fileList.compact ? 0 : row.plateX
                            rightMargin: fileList.compact ? 0 : Math.max(0, row.width - row.plateX - row.plateWidth)
                        }
                        radius: fileList.compact ? Tokens.radiusControl : Tokens.previewPlateRadius
                        color: row.selected ? row.plateColor
                            : rowMouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
                    }

                    Item {
                        id: thumb
                        visible: !fileList.compact
                        x: row.plateX + Tokens.previewPlatePad
                        y: Tokens.previewPlatePad
                        width: row.cellWidth
                        height: row.cellHeight

                        Image {
                            id: pic
                            anchors.fill: parent
                            visible: row.modelData.kind === "image"
                            // Decoded at its size by the provider (image://preview/thumb), twice for a sharp edge.
                            // (by the file's token: an index names another file once the folder is listed, and the cache is on).
                            source: row.modelData.kind === "image" && !fileList.compact && row.modelData.token !== undefined ? "image://preview/thumb/" + row.modelData.token : ""
                            // A fixed box (the size follows the picture's own shape).
                            sourceSize: Qt.size(Tokens.previewThumbnailWidth * 2, Tokens.previewThumbnailWidth * 2)
                            asynchronous: true
                            cache: true
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                            mipmap: true
                        }
                        // Text file: its first lines on a sheet of paper, as the page it stands for.
                        Rectangle {
                            anchors.fill: parent
                            visible: row.modelData.kind === "text" && snippet.text !== ""
                            color: Tokens.previewPaper
                            clip: true

                            Text {
                                id: snippet
                                anchors {
                                    fill: parent
                                    margins: Tokens.spacingXs
                                }
                                textFormat: Text.PlainText
                                // Read on the backend's worker (snippetFor): "" until it is in; snippetRevision re-reads it then.
                                text: row.modelData.kind === "text" && !fileList.compact ? viewerWin.snippetOf(row.index, viewerWin.backend.snippetRevision) : ""
                                color: Tokens.previewPaperInk
                                font.family: Tokens.typographyMonoFamily
                                font.pixelSize: Tokens.previewThumbnailTextSize
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                            }
                        }
                        // Other kinds without a picture: a plain tile.
                        Rectangle {
                            anchors.fill: parent
                            visible: row.modelData.kind !== "image" && !(row.modelData.kind === "text" && snippet.text !== "")
                            radius: Tokens.radiusControl
                            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                        }
                    }

                    Text {
                        id: labelText
                        anchors {
                            left: parent.left
                            right: parent.right
                            leftMargin: fileList.compact ? Tokens.spacingSm * 2 : row.plateX + Tokens.spacingXs
                            rightMargin: fileList.compact ? Tokens.spacingSm : Math.max(Tokens.spacingXs, row.width - row.plateX - row.plateWidth + Tokens.spacingXs)
                            top: fileList.compact ? undefined : thumb.bottom
                            verticalCenter: fileList.compact ? parent.verticalCenter : undefined
                        }
                        height: fileList.compact ? implicitHeight : row.captionHeight
                        horizontalAlignment: fileList.compact ? Text.AlignLeft : Text.AlignHCenter
                        elide: Text.ElideMiddle
                        textFormat: Text.PlainText
                        maximumLineCount: 1
                        // A file name may contain line breaks: keep one line, shown as the return symbol.
                        text: DisplayName.text(row.modelData.name)
                        verticalAlignment: Text.AlignVCenter
                        color: row.selected && viewerWin.keyLook ? Appearance.colors.selectionText : Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: fileList.compact ? Tokens.typographyBodySize : Tokens.typographyCaptionSize
                    }
                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: viewerWin.current = row.index
                    }
                }
            }

            Loader {
                id: thumbs
                anchors {
                    top: fileList.bottom
                    topMargin: viewerWin.fileCount > 1 ? Tokens.spacingSm : 0
                    bottom: parent.bottom
                    left: parent.left
                    right: parent.right
                    margins: Tokens.spacingSm
                    rightMargin: 0
                }
                active: viewerWin.isPdf && viewerWin.view !== null
                source: "Thumbnails.qml"
            }

            Binding {
                target: thumbs.item
                property: "document"
                value: viewerWin.view?.document
                when: thumbs.item !== null && viewerWin.view !== null
            }
            Binding {
                target: thumbs.item
                property: "pdfView"
                value: viewerWin.view
                when: thumbs.item !== null && viewerWin.view !== null
            }
        }
    }

    Content {
        id: content
        anchors {
            top: toolbar.bottom
            bottom: parent.bottom
            left: sidebar.right
            right: parent.right
        }
        backend: viewerWin.backend
        fileIndex: viewerWin.current
        searchText: searchInput.text
        // A video or a sound opened in Preview plays at once, as in Quick Look; Play/Pause stays on the bar.
        autoplay: true
        focus: true
    }
}
