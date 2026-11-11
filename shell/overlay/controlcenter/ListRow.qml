import QtQuick
import Grassfield.Ui

// Row of an expanded list (network, device): optional leading icon, text, trailing text and icon.
NavItem {
    id: root

    property string text: ""
    property string iconName: ""
    property string trailing: ""
    property string trailingIcon: ""
    property bool selected: false

    width: parent ? parent.width : implicitWidth
    height: Tokens.panelCcRowHeight
    accessibleName: trailing !== "" ? text + ", " + trailing : text
    checkable: true
    checked: selected

    // Lit under the pointer or with the keyboard focus only: a click gives the row the focus, and it stayed lit after one
    // (UI audit 2026-11-05 U26). Pressed: the shared pressed fill on top.
    Rectangle {
        anchors.fill: parent
        radius: Tokens.radiusControl
        color: hover.containsMouse || root.visualFocus ? Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity) : "transparent"
    }

    Rectangle {
        anchors.fill: parent
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.hover, Tokens.controlPressedOpacity)
        visible: hover.pressed
    }

    Row {
        anchors.fill: parent
        anchors.leftMargin: Tokens.spacingSm
        anchors.rightMargin: Tokens.spacingSm
        spacing: Tokens.spacingSm

        Icon {
            id: lead
            visible: root.iconName !== ""
            anchors.verticalCenter: parent.verticalCenter
            size: Tokens.menuIconSize
            name: root.iconName
        }

        Label {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - (lead.visible ? lead.width + parent.spacing : 0)
                - (trail.visible ? trail.width + parent.spacing : 0)
                - (trailGlyph.visible ? trailGlyph.width + parent.spacing : 0)
                - (mark.visible ? mark.width + parent.spacing : 0)
            text: root.text
        }

        Caption {
            id: trail
            visible: root.trailing !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: root.trailing
            elide: Text.ElideNone
        }

        Icon {
            id: trailGlyph
            visible: root.trailingIcon !== ""
            anchors.verticalCenter: parent.verticalCenter
            size: Tokens.panelCcChevron
            name: root.trailingIcon
            color: Appearance.colors.textSecondary
        }

        Icon {
            id: mark
            visible: root.selected
            anchors.verticalCenter: parent.verticalCenter
            size: Tokens.menuIconSize
            name: "checkmark"
            color: Appearance.colors.accentGlass
        }
    }

    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.ArrowCursor
        onClicked: {
            root.forceActiveFocus();
            root.activated();
        }
    }
}
