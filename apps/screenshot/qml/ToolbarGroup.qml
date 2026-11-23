import QtQuick
import Grassfield.Ui

// A capsule of toolbar buttons, as every app window's toolbar draws it (macOS 27): the rimmed glass capsule (RimmedCapsule,
// toolbar.capsule tall, the back / forward capsule's fill) around a row of its 34-pt group buttons (toolbar.groupButton). It
// was a floating Material capsule with a shadow and a white plate around 28-pt buttons, macOS 26's toolbar groups
// (ADR-0039 step 16).
RimmedCapsule {
    id: root

    default property alias buttons: row.data

    implicitWidth: row.implicitWidth + 2 * Tokens.spacingXs
    implicitHeight: Tokens.toolbarCapsule
    width: implicitWidth
    height: implicitHeight
    fillOpacity: Tokens.toolbarCapsuleFillOpacity

    // Every button of the group takes the group's size.
    function sizeButtons(): void {
        for (let i = 0; i < row.children.length; i++) {
            const button = row.children[i];
            if ("buttonSize" in button)
                button["buttonSize"] = Tokens.toolbarGroupButton;
        }
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 0
        onChildrenChanged: root.sizeButtons()
        Component.onCompleted: root.sizeButtons()
    }
}
