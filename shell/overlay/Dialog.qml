import QtQuick
import QtQuick.Window
import Grassfield.Ui

// Dialog frame on the material, in one of two shapes (measured on macOS 27, ADR-0039 step 10):
// - alert (default): radius.alert, an icon in a 64 frame at the top left, bold title and message left-aligned under it,
//   28-pt capsule buttons of one width filling the row;
// - sheet (sheet: true): radius.sheet (the window's corner), title, message and custom content, then a full-width hairline
//   above a 64-pt footer whose 24-pt sheet buttons (rounded rectangles, Button.sheet) sit 20 from the right and bottom edges.
// Esc emits rejected(). Hosts focus the preferred button themselves.
FocusScope {
    id: root

    property string title: ""
    property string message: ""
    property int panelWidth: Tokens.panelAlertWidth
    // Sheet shape (see above).
    property bool sheet: false
    // Alert icon: a glyph name of the Ui icon set; none, no icon.
    property string icon: ""
    property alias content: contentColumn.data
    property alias buttons: buttonRow.data

    signal rejected

    readonly property real cornerRadius: sheet ? Tokens.radiusSheet : Tokens.radiusAlert
    readonly property real pad: sheet ? Tokens.panelSheetPadding : Tokens.spacingLg
    // An alert's icon and text sit 24 from its edges, its buttons 16; a sheet has one padding.
    readonly property real textInset: sheet ? pad : Tokens.panelAlertTextInset
    readonly property Item surface: material

    width: panelWidth
    height: sheet ? pad + column.implicitHeight + pad + Tokens.panelSheetFooterHeight : pad + column.implicitHeight + Tokens.spacingLg + buttonRow.implicitHeight + pad
    Accessible.role: Accessible.Dialog
    Accessible.name: root.title
    Accessible.description: root.message

    Keys.onEscapePressed: root.rejected()

    Material {
        id: material
        glassClass: "menu"
        anchors.fill: parent
        radius: root.cornerRadius
    }

    Column {
        id: column
        x: root.textInset
        y: root.pad
        width: root.width - 2 * root.textInset
        spacing: Tokens.spacingMd

        Item {
            visible: root.icon !== "" && !root.sheet
            width: Tokens.panelAlertIconFrame
            height: visible ? Tokens.panelAlertIconFrame : 0

            Icon {
                anchors.centerIn: parent
                size: Tokens.panelAlertIconGlyph
                name: root.icon
                color: Appearance.colors.accentGlass
            }
        }

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.title
            visible: text !== ""
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographyMenuBoldWeight
            wrapMode: Text.WordWrap
        }

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.message
            visible: text !== ""
            color: root.sheet ? Appearance.colors.textSecondary : Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographySmallWeight
            wrapMode: Text.WordWrap
        }

        Column {
            id: contentColumn
            width: parent.width
            spacing: Tokens.spacingSm
        }
    }

    // Sheet footer: the hairline spans the whole sheet.
    Rectangle {
        visible: root.sheet
        x: 0
        y: root.height - Tokens.panelSheetFooterHeight
        width: root.width
        // One device pixel at every scale (UI audit 2026-11-05 U37).
        height: 1 / Math.max(1, Screen.devicePixelRatio)
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    // Buttons. Alert: capsules of one width filling the row (two of them are half each), never narrower than the widest
    // label; when they do not fit side by side (long labels, French), they stack full width, the default (last) one on
    // top, as macOS stacks an alert's buttons (UI audit 2026-11-05 U2). Sheet: 24-pt sheet buttons of one width (a pair is
    // equal width), right-aligned in the footer. Laid out by hand (not a positioner): a stack reverses the order.
    Item {
        id: buttonRow

        readonly property real spacing: Tokens.controlAlertButtonGap
        property bool stacked: false

        x: root.sheet ? root.width - root.pad - width : root.pad
        y: root.sheet ? root.height - Tokens.panelSheetFooterHeight + (Tokens.panelSheetFooterHeight - height) / 2 : root.pad + column.implicitHeight + Tokens.spacingLg
        width: implicitWidth
        height: implicitHeight

        function equalize(): void {
            const kids = buttonRow.children;
            const shown = [];
            let widest = 0;
            for (let i = 0; i < kids.length; i++) {
                if (!("capsule" in kids[i]))
                    continue;
                kids[i]["capsule"] = !root.sheet;
                kids[i]["push"] = false;
                kids[i]["sheet"] = root.sheet;
                if (!kids[i].visible)
                    continue;
                widest = Math.max(widest, kids[i].implicitWidth);
                shown.push(kids[i]);
            }
            const count = shown.length;
            const room = root.width - 2 * root.pad;
            buttonRow.stacked = !root.sheet && count > 1 && count * widest + (count - 1) * buttonRow.spacing > room;
            if (buttonRow.stacked) {
                let y = 0;
                for (let i = count - 1; i >= 0; i--) {
                    shown[i].width = room;
                    shown[i].x = 0;
                    shown[i].y = y;
                    y += shown[i].height + buttonRow.spacing;
                }
                buttonRow.implicitWidth = room;
                buttonRow.implicitHeight = y - buttonRow.spacing;
                return;
            }
            const fill = root.sheet || count === 0 ? 0 : (room - (count - 1) * buttonRow.spacing) / count;
            const wanted = Math.max(widest, fill);
            let x = 0;
            let tallest = 0;
            for (let i = 0; i < count; i++) {
                shown[i].width = wanted;
                shown[i].x = x;
                shown[i].y = 0;
                x += wanted + buttonRow.spacing;
                tallest = Math.max(tallest, shown[i].height);
            }
            buttonRow.implicitWidth = count > 0 ? x - buttonRow.spacing : 0;
            buttonRow.implicitHeight = tallest;
        }

        Component.onCompleted: equalize()
        onChildrenChanged: Qt.callLater(equalize)
    }

    onWidthChanged: Qt.callLater(buttonRow.equalize)
    onSheetChanged: Qt.callLater(buttonRow.equalize)
}
