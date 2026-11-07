import QtQuick

// One row of a PopupMenu. Highlight is driven by the owning menu (hover and keyboard share it).
Item {
    id: root

    property string text: ""
    // An item's name for the label's "%1" (Compress “%1”, Glance at “%1”): drawn shortened in its middle to menu.nameMaxWidth,
    // its start and its end kept, so that a long file name never widens the menu (macOS Finder; owner report 2026-11-07). The
    // accessible name keeps the whole name. Empty: the label is `text` as it is.
    property string name: ""
    property string shortcut: ""
    // Plain text in the right-hand column, before the shortcut: the Grassfield menu's "Settings…  1 update" (ADR-0033 U19).
    property string detail: ""
    property string iconName: ""
    // A tiling glyph ({zones, own}: TileGlyph) in the icon's place, or null (Window > Move & Resize, docs/specs/tiling.md TL25).
    property var glyph: null
    property bool highlighted: false
    property bool checked: false
    property bool hasSubmenu: false
    property bool destructive: false
    // The row's section holds a checkable row (set by the menu): the label starts after the check column, the check is drawn
    // in it. An icon shifts only its own row (macOS 27 keeps icons on the rows that have one).
    property bool checkColumn: false

    signal clicked
    signal hovered

    readonly property color foreground: !enabled ? Appearance.withAlpha(Appearance.colors.text, Tokens.materialDisabledOpacity)
        : highlighted ? Appearance.colors.selectionText
        : destructive ? Appearance.colors.danger
        : Appearance.colors.text

    // Where the icon (if any) and the label start: the check column or the plain inset, then the icon and its gap.
    readonly property real iconX: root.checkColumn || root.checked ? Tokens.menuCheckInset : Tokens.menuItemPadding
    readonly property real labelX: root.iconX + (root.iconName !== "" || root.glyph ? Tokens.menuIconSize + Tokens.spacingSm : 0)

    // The shortcut and the chevron sit in their own right-aligned column (macOS model, docs/specs/ui.md); the
    // minimum gap to the label is unchanged. Whole pixels, so that the menu's edges and right-aligned shortcuts are sharp.
    readonly property real trailRoom: trail.implicitWidth > 0 ? Tokens.menuShortcutGap + 2 * Tokens.spacingSm + trail.implicitWidth : 0
    implicitWidth: Math.ceil(root.labelX + label.implicitWidth + root.trailRoom + Tokens.menuItemPadding)
    implicitHeight: Tokens.menuItemHeight
    // The label as drawn, and as told to assistive technologies (the whole name).
    readonly property string shownText: root.name !== "" ? root.text.arg(nameMetrics.elidedText(root.name, Qt.ElideMiddle, Tokens.menuNameMaxWidth)) : root.text
    Accessible.role: Accessible.MenuItem
    Accessible.name: root.name !== "" ? root.text.arg(root.name) : root.text
    Accessible.description: root.detail !== "" && root.shortcut !== "" ? root.detail + ", " + root.shortcut : root.detail + root.shortcut
    Accessible.checkable: root.checked
    Accessible.checked: root.checked
    Accessible.focusable: true
    // An assistive technology's press (AT-SPI) acts only like the pointer and the keys would: never hidden or disabled (R12).
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.clicked()

    // The highlight is concentric with the menu: its radius is the menu's less the menu padding around the rows.
    Rectangle {
        anchors.fill: parent
        radius: Tokens.radiusMenu - Tokens.menuPadding
        color: Appearance.colors.selection
        visible: root.highlighted && root.enabled
    }

    // The check, centred in the check column.
    Icon {
        visible: root.checked
        x: Math.round((Tokens.menuCheckInset - Tokens.menuIconSize) / 2)
        y: Math.round((root.height - height) / 2)
        size: Tokens.menuIconSize
        name: "checkmark"
        color: root.foreground
    }

    Icon {
        visible: root.iconName !== ""
        x: root.iconX
        y: Math.round((root.height - height) / 2)
        size: Tokens.menuIconSize
        name: root.iconName
        color: root.foreground
    }

    TileGlyph {
        visible: !!root.glyph
        x: root.iconX
        y: Math.round((root.height - height) / 2)
        width: Tokens.menuIconSize
        zones: root.glyph ? root.glyph.zones : []
        own: root.glyph && root.glyph.own !== undefined ? root.glyph.own : 0
        color: root.foreground
    }

    Text {
        textFormat: Text.PlainText
        id: label
        x: root.labelX
        // A row narrower than its label (a menu at menu.maxWidth, the Sound menu's fixed width) shortens it in the middle, so a
        // long file or device name keeps its start and its end (macOS; UI audit 2026-11-05 U10).
        width: Math.max(0, root.width - root.labelX - root.trailRoom - Tokens.menuItemPadding)
        elide: Text.ElideMiddle
        anchors.verticalCenter: parent.verticalCenter
        text: root.shownText
        color: root.foreground
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
        font.weight: Tokens.typographySmallWeight
    }

    FontMetrics {
        id: nameMetrics
        font: label.font
    }

    Row {
        id: trail
        anchors {
            right: parent.right
            rightMargin: Tokens.menuItemPadding
            verticalCenter: parent.verticalCenter
        }
        spacing: Tokens.spacingSm

        Text {
            textFormat: Text.PlainText
            visible: root.detail !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: root.detail
            color: root.highlighted && root.enabled ? root.foreground : Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyMenuSize
            font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
            font.weight: Tokens.typographySmallWeight
        }

        Text {
            textFormat: Text.PlainText
            visible: root.shortcut !== ""
            anchors.verticalCenter: parent.verticalCenter
            // In the device's style: the text on a PC, the macOS symbols on a Mac (MenuShortcut.label).
            text: MenuShortcut.label(root.shortcut, Appearance.shortcutStyle)
            color: root.highlighted && root.enabled ? root.foreground : Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyMenuSize
            font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
            font.weight: Tokens.typographySmallWeight
        }

        Icon {
            visible: root.hasSubmenu
            anchors.verticalCenter: parent.verticalCenter
            size: Tokens.menuIconSize
            name: "chevron-right"
            color: root.foreground
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.enabled
        onEntered: root.hovered()
        onPositionChanged: root.hovered()
        onClicked: root.clicked()
    }
}
