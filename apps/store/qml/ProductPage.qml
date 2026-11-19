pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Grassfield.Ui
import "Store.js" as Store

// An app's page (spec SR9-SR12): its icon, name, summary and developer, the button, the source and the licence, always;
// the screenshots (when AppStream has them and they are on, owner ST6: fetched when the page opens); the description;
// What's New (AppStream's releases, else the package's version and build date); and the Information list. An AUR app's
// page asks for the AUR's facts when it opens (maintainer or orphaned, votes, popularity, last update, the out-of-date
// flag; SR11) and offers its build script, fetched on click (ADR-0037 e.6: plain text, never run by the Store). A Flatpak's
// page asks flatpak for its version, sizes and what it can reach (Flathub's before an install, the user's installation's
// after), and shows its app id, runtime and Flathub's verified flag (SR11), then its Permissions as cards (ADR-0049).
ScrollPage {
    id: root

    required property var backend
    property var app: ({})
    // pacman -Si's facts, asked for when the page opens (version, sizes, build date); a Flatpak's from flatpak (version,
    // licence, download and installed sizes, access, permissions: the grants of view::permissions).
    property var facts: ({})
    readonly property string factsPackage: root.app.package ? root.app.package : (root.app.packages && root.app.packages.length > 0 ? root.app.packages[0] : "")

    signal linkRequested(string url)
    signal uninstallRequested(var app)
    signal detailsRequested(string id)
    // The system must be updated first (Store.needsUpdate): Software Update.
    signal softwareUpdateRequested(string id)
    signal tryAgainRequested(var app, string kind)
    signal buildScriptRequested(var app)
    // The AUR answered for this app: its data is read again (Main.qml's binding, never an assignment that would cut it).
    signal appStale

    // What the buttons may do (StoreBackend::actions), the app's operation and how its last one ended (spec SR13, SR19, SR22).
    readonly property var actions: root.app.id && root.backend.revision >= 0 ? root.backend.actions(root.app.id) : ({})
    readonly property bool busy: (root.backend.operations || []).some(o => o.app === root.app.id)
    readonly property var result: root.app.id ? (root.backend.results || {})[root.app.id] : undefined

    title: ""
    headerHeight: Tokens.storeProductTop
    Accessible.role: Accessible.Pane
    Accessible.name: root.app.name || ""

    readonly property var aur: root.app.aur || ({})

    function requestFacts(): void {
        if (root.factsPackage !== "" && (root.app.kind === "repo" || root.app.kind === "setup"))
            root.backend.requestPackageInfo(root.factsPackage);
        if (root.app.kind === "aur")
            root.backend.requestAur(root.app.id);
        if (root.app.kind === "flatpak")
            root.backend.requestFlatpakInfo(root.app.id);
    }

    Component.onCompleted: root.requestFacts()
    // The page stays across snapshots (SU-06): an app installed, removed or updated meanwhile has its facts asked again.
    readonly property bool installedNow: root.app.installed === true
    onInstalledNowChanged: root.requestFacts()

    Connections {
        target: root.backend
        function onPackageInfo(name: string, facts: var): void {
            if (name === root.factsPackage)
                root.facts = facts;
        }
        function onAurInfo(id: string): void {
            if (id === root.app.id)
                root.appStale();
        }
        function onFlatpakInfo(id: string, facts: var): void {
            if (id === root.app.id)
                root.facts = {version: facts.version, downloadSize: facts.download, installedSize: facts.installed,
                              licenses: facts.license, access: facts.access, permissions: facts.permissions};
        }
    }

    // Header: icon, texts, the button, source and licence.
    Item {
        width: root.contentWidth
        implicitHeight: Math.max(icon.height, texts.implicitHeight)

        AppIcon {
            id: icon
            size: Tokens.storeProductIconSize
            source: root.app.icon || ""
        }

        Column {
            id: texts
            anchors.left: icon.right
            anchors.leftMargin: Tokens.storeProductHeaderGap
            anchors.right: parent.right
            spacing: Tokens.storeProductLineGap

            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.app.name || ""
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                color: Appearance.colors.text
                font.family: Appearance.fontFamilyFor(Tokens.storeProductNameSize)
                font.pixelSize: Tokens.storeProductNameSize
                font.weight: Tokens.typographyMenuBoldWeight
                font.letterSpacing: Appearance.trackingFor(Tokens.storeProductNameSize)
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }

            Text {
                width: parent.width
                visible: text !== ""
                textFormat: Text.PlainText
                text: root.app.summary || ""
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.storeProductSummarySize
                font.letterSpacing: Appearance.tracking(Tokens.storeProductSummarySize)
            }

            Text {
                width: parent.width
                visible: text !== ""
                textFormat: Text.PlainText
                text: root.app.developer || ""
                elide: Text.ElideRight
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.storeBadgeSize
                font.letterSpacing: Appearance.tracking(Tokens.storeBadgeSize)
            }

            Item {
                width: 1
                height: Tokens.storeProductButtonGap
            }

            Row {
                spacing: Tokens.storeProductButtonRowGap

                StoreButton {
                    anchors.verticalCenter: parent.verticalCenter
                    app: root.app
                    large: true
                }

                // "…": Uninstall… for an installed app (SR22), dimmed with the reason when the Store may not remove it.
                Item {
                    id: more
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.actions.installed === true
                    width: Tokens.storeButtonLargeHeight
                    height: Tokens.storeButtonLargeHeight
                    activeFocusOnTab: visible
                    Accessible.role: Accessible.ButtonMenu
                    Accessible.name: qsTr("More for %1").arg(root.app.name || "")
                    Accessible.onPressAction: more.openMenu()

                    function openMenu(): void {
                        moreMenu.items = [{id: "uninstall", text: qsTr("Uninstall…"), destructive: true,
                                           enabled: root.actions.uninstall === "" && !root.busy}];
                        moreMenu.focusBack = more;
                        moreMenu.openAt(0, more.height + Tokens.spacingXs);
                    }

                    Keys.onPressed: event => {
                        if (ActivationKeys.activation(event.key)) {
                            more.openMenu();
                            event.accepted = true;
                        }
                    }

                    Icon {
                        anchors.centerIn: parent
                        name: "ellipsis-circle"
                        size: Tokens.storeButtonLargeHeight
                        color: Appearance.windowSecondary
                    }

                    // The keyboard's ring only: the menu gives the focus back after a click too (ADR-0039 step 24, G7).
                    FocusRing {
                        shapeRadius: more.width / 2
                        visible: moreFocus.active
                    }

                    KeyFocus {
                        id: moreFocus
                    }

                    TapHandler {
                        onTapped: more.openMenu()
                    }

                    MenuPopup {
                        id: moreMenu
                        accessibleName: more.Accessible.name
                        onChosen: id => {
                            if (id === "uninstall")
                                root.uninstallRequested(root.app);
                        }
                    }
                }

                // Never past the content's edge (UI audit 2026-11-05 U12): a long source is elided.
                SourceBadge {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, Math.max(0, texts.width - x))
                    kind: root.app.kind || ""
                    repo: root.app.repo || ""
                }
            }

            // The licence on its own line under the button (U12): a long SPDX expression is elided, never past the edge.
            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.app.license ? qsTr("Licence: %1").arg(root.app.license) : qsTr("Licence not stated")
                elide: Text.ElideRight
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.storeBadgeSize
                font.letterSpacing: Appearance.tracking(Tokens.storeBadgeSize)
            }

            // How its last operation ended (SR19), with Try Again and Details…, or Update Now… when the system must be updated
            // first.
            Row {
                visible: !!root.result && Store.resultText(root.result) !== ""
                width: parent.width
                spacing: Tokens.storeProductButtonRowGap
                topPadding: Tokens.storeResultGap

                Text {
                    width: Math.min(implicitWidth, parent.width - links.width - parent.spacing)
                    textFormat: Text.PlainText
                    text: Store.resultText(root.result)
                    wrapMode: Text.Wrap
                    color: Appearance.colors.danger
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.storeBadgeSize
                    Accessible.role: Accessible.AlertMessage
                    Accessible.name: text
                }

                Row {
                    id: links
                    spacing: Tokens.storeProductButtonRowGap

                    LinkText {
                        visible: Store.canTryAgain(root.result)
                        text: qsTr("Try Again")
                        onActivated: root.tryAgainRequested(root.app, root.result.kind)
                    }

                    LinkText {
                        visible: Store.needsUpdate(root.result)
                        text: qsTr("Update Now…")
                        onActivated: root.softwareUpdateRequested(root.app.id)
                    }

                    LinkText {
                        visible: !Store.needsUpdate(root.result) // pacman's output stays in the log then
                        text: qsTr("Details…")
                        onActivated: root.detailsRequested(root.app.id)
                    }
                }
            }

            // Why the Store does not offer to uninstall it (SR22: part of Omarchy, of Grassfield, of the system, …).
            Text {
                width: parent.width
                visible: root.actions.installed === true && text !== ""
                textFormat: Text.PlainText
                text: Store.uninstallReasonText(root.actions.uninstall || "", root.app.kind)
                wrapMode: Text.Wrap
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.storeBadgeSize
            }

            Text {
                width: parent.width
                visible: root.app.installed !== undefined && !root.app.launcher && root.app.kind === "repo"
                textFormat: Text.PlainText
                text: qsTr("This app has no window of its own: it runs in a terminal.")
                wrapMode: Text.Wrap
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.storeBadgeSize
            }
        }
    }

    // Screenshots (SR10): a gallery with arrows; third-party images, loaded only while they are on and the Store is online.
    Item {
        id: gallery
        width: root.contentWidth
        visible: (root.app.screenshots || []).length > 0
        implicitHeight: visible ? Tokens.storeScreenshotHeight : 0


        ListView {
            id: shots
            width: parent.width + Tokens.storeContentMargin
            height: parent.height
            orientation: ListView.Horizontal
            spacing: Tokens.storeScreenshotGap
            model: root.app.screenshots || []
            boundsBehavior: Flickable.StopAtBounds
            clip: false
            keyNavigationEnabled: false

            delegate: Item {
                id: shot
                required property string modelData
                required property int index
                readonly property string caption: (root.app.captions || [])[index] || ""
                // Read again when the Store goes offline or comes back (the provider refuses offline anyway).
                readonly property string source: root.backend.online && root.backend.sources.screenshots ? root.backend.screenshotSource(modelData) : ""
                height: shots.height
                width: picture.status === Image.Ready && picture.implicitHeight > 0
                    ? Math.min(shots.width, Math.round(picture.implicitWidth * height / picture.implicitHeight))
                    : Math.round(height * Tokens.storeScreenshotPlaceholderRatio)
                Accessible.role: Accessible.Graphic
                Accessible.name: caption !== "" ? caption
                    : qsTr("Screenshot %1 of %2 of %3").arg(index + 1).arg(shots.count).arg(root.app.name)

                Rectangle {
                    anchors.fill: parent
                    radius: Tokens.storeScreenshotRadius
                    color: Appearance.colors.groupFill
                    visible: picture.status !== Image.Ready

                    Text {
                        anchors.centerIn: parent
                        width: parent.width - 2 * Tokens.spacingLg
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: !root.backend.sources.screenshots ? qsTr("Screenshots are turned off.")
                            : !root.backend.online ? qsTr("Screenshots are not loaded while you're offline.")
                            : picture.status === Image.Error ? qsTr("This screenshot could not be loaded.") : ""
                        color: Appearance.windowSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.storeBadgeSize
                    }
                }

                Image {
                    id: picture
                    anchors.fill: parent
                    source: shot.source
                    sourceSize.height: shots.height * 2
                    asynchronous: true
                    fillMode: Image.PreserveAspectFit
                    visible: status === Image.Ready
                    smooth: true
                }
            }
        }

        HoverHandler {
            id: galleryHover
        }

        CarouselArrow {
            x: Tokens.storeCarouselArrowInset
            anchors.verticalCenter: parent.verticalCenter
            back: true
            shown: galleryHover.hovered && !shots.atXBeginning
            onClicked: shots.contentX = Math.max(shots.originX, shots.contentX - gallery.width + Tokens.storeScreenshotGap)
        }

        CarouselArrow {
            x: gallery.width - width - Tokens.storeCarouselArrowInset
            anchors.verticalCenter: parent.verticalCenter
            shown: galleryHover.hovered && !shots.atXEnd
            onClicked: shots.contentX = Math.min(shots.contentWidth - shots.width + shots.originX, shots.contentX + gallery.width - Tokens.storeScreenshotGap)
        }
    }

    // The description (plain text: paragraphs, and bullets as AppStream lists them).
    Text {
        width: Math.min(root.contentWidth, Tokens.storeTextMaxWidth)
        visible: text !== ""
        textFormat: Text.PlainText
        text: root.app.description || ""
        wrapMode: Text.Wrap
        lineHeight: Tokens.storeBodyLineHeight
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeBodySize
        font.letterSpacing: Appearance.tracking(Tokens.storeBodySize)
    }

    // What's New: the newest release AppStream lists, else the package's version and build day.
    Column {
        id: whatsNew
        readonly property var release: (root.app.releases || []).length > 0 ? root.app.releases[0] : null
        readonly property string version: whatsNew.release ? whatsNew.release.version : (root.facts.version || "")
        readonly property string date: whatsNew.release ? whatsNew.release.date : (root.facts.buildDate || "")
        width: Math.min(root.contentWidth, Tokens.storeTextMaxWidth)
        visible: whatsNew.version !== ""
        spacing: Tokens.storeProductLineGap

        SectionHeading {
            text: qsTr("What's New")
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            text: whatsNew.date !== "" ? qsTr("Version %1 · %2").arg(whatsNew.version).arg(whatsNew.date) : qsTr("Version %1").arg(whatsNew.version)
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.storeBadgeSize
        }

        Text {
            width: parent.width
            visible: text !== ""
            textFormat: Text.PlainText
            text: whatsNew.release ? whatsNew.release.notes : ""
            wrapMode: Text.Wrap
            lineHeight: Tokens.storeBodyLineHeight
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.storeBodySize
        }
    }

    // Information (SR11).
    Column {
        width: root.contentWidth
        spacing: Tokens.storeProductLineGap

        SectionHeading {
            text: qsTr("Information")
        }

        Grid {
            id: info
            width: parent.width
            columns: Math.max(1, Math.floor((width + columnSpacing) / (Tokens.storeInfoMinWidth + columnSpacing)))
            columnSpacing: Tokens.storeInfoColumnGap
            rowSpacing: Tokens.storeInfoRowGap
            readonly property real cellWidth: (width - (columns - 1) * columnSpacing) / columns
            readonly property var setup: root.app.setup || ({})
            readonly property var facts: [
                {label: qsTr("Source"), value: Store.sourceLabel(root.app.kind, root.app.repo)},
                {label: qsTr("Developer"), value: root.app.developer || ""},
                {label: root.app.kind === "setup" ? qsTr("Packages") : qsTr("Package"),
                 value: root.app.kind === "setup" ? (root.app.packages || []).join(", ") : (root.app.package || "")},
                {label: qsTr("App ID"), value: root.app.kind === "flatpak" ? (root.app.flatpakId || "") : ""},
                {label: qsTr("Runtime"), value: root.app.kind === "flatpak" ? (root.app.runtime || "") : ""},
                {label: qsTr("Verified Developer"), value: root.app.kind === "flatpak" && root.app.verified ? qsTr("Verified by Flathub") : ""},
                {label: qsTr("Version"), value: root.facts.version || root.aur.version || ""},
                {label: qsTr("Maintainer"), value: root.app.kind !== "aur" ? "" : root.aur.orphaned ? qsTr("Orphaned") : (root.aur.maintainer || "")},
                {label: qsTr("Votes"), value: root.aur.votes !== undefined ? String(root.aur.votes) : ""},
                {label: qsTr("Popularity"), value: root.aur.popularity || ""},
                {label: qsTr("Last Updated"), value: root.aur.lastModified || ""},
                {label: qsTr("Flagged Out of Date"), value: root.aur.outOfDate ? (root.aur.outOfDateSince || qsTr("Yes")) : ""},
                {label: qsTr("Download Size"), value: root.facts.downloadSize || ""},
                {label: qsTr("Installed Size"), value: root.facts.installedSize || ""},
                {label: qsTr("Category"), value: (root.app.categories || []).join(", ")},
                {label: qsTr("Languages"), value: Store.languagesText(root.app.languages)},
                {label: qsTr("Content Rating"), value: Store.ratingText(root.app.rated, root.app.rating)},
                {label: qsTr("Licence"), value: root.app.license || root.facts.licenses || qsTr("Not stated")},
                {label: qsTr("What This Setup Changes"), value: info.setup.changes || ""},
                {label: qsTr("Setup"), value: info.setup.install || ""},
                {label: qsTr("Address"), value: root.app.webUrl || ""},
                {label: qsTr("Homepage"), value: Store.hostOf(root.app.homepage), link: root.app.homepage || ""},
                {label: qsTr("Bug Tracker"), value: Store.hostOf(root.app.bugtracker), link: root.app.bugtracker || ""}
            ].filter(f => f.value !== "")

            Repeater {
                model: info.facts

                delegate: InfoItem {
                    required property var modelData
                    width: info.cellWidth
                    label: modelData.label
                    value: modelData.value
                    link: modelData.link || ""
                    onLinkActivated: url => root.linkRequested(url)
                }
            }
        }

        // The AUR: the package's build script, as the AUR has it, read before installing (SR11); as far below the facts as
        // their rows are from each other.
        Item {
            visible: root.app.kind === "aur"
            implicitWidth: buildScript.implicitWidth
            implicitHeight: buildScript.implicitHeight + Tokens.storeInfoRowGap - Tokens.storeProductLineGap

            Button {
                id: buildScript
                anchors.bottom: parent.bottom
                push: true
                text: qsTr("View Build Script")
                enabled: root.backend.online
                onClicked: root.buildScriptRequested(root.app)
            }
        }

        Text {
            width: parent.width
            visible: root.app.kind === "aur" && root.app.aurUnknown === true
            textFormat: Text.PlainText
            text: qsTr("The AUR doesn't have this package anymore.")
            wrapMode: Text.Wrap
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.storeBadgeSize
        }
    }

    // Permissions (ADR-0049): what a Flatpak can reach, as cards; nothing while its metadata is not read.
    PermissionCards {
        width: root.contentWidth
        visible: root.app.kind === "flatpak" && root.facts.permissions !== undefined && root.facts.permissions !== null
        grants: root.app.kind === "flatpak" && root.facts.permissions !== undefined ? root.facts.permissions : null
        appName: root.app.name || ""
    }
}
