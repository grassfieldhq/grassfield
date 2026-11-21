import QtQuick
import QtQuick.Templates as T
import QtQuick.Window
import Grassfield.Ui
import "Store.js" as Store

// An app's button (spec SR13, SR17-SR19): "Get", "Open" or "Installed" on a grey capsule with the label in the accent
// colour, bold (macOS 27); while the app's operation runs or waits in the queue, a progress ring in its place (a square in
// it while it can still leave the queue, or stop: a Flatpak install that runs, SD26). Get asks the window for the confirmation sheet (Main.qml requestGet), Open starts
// the app (launchApp). A button that cannot act says why in its tooltip (the pointer is read by the item around it: a
// disabled control gets no hover). The backend is the window's (Main.qml): a button in a window without one shows its
// app's state, disabled.
Item {
    id: root

    property var app: null
    property bool large: false
    readonly property var host: root.Window.window
    readonly property var backend: root.host && root.host.backend !== undefined ? root.host.backend : null
    readonly property string appId: (root.app && root.app.id) || ""
    // What the button may do now (StoreBackend::actions), read again with every new snapshot.
    readonly property var actions: root.backend && root.appId !== "" && root.backend.revision >= 0 ? root.backend.actions(root.appId) : null
    readonly property var operation: root.backend ? (root.backend.operations || []).find(o => o.app === root.appId) || null : null
    readonly property string state_: Store.buttonState(root.app, root.actions, root.operation)
    readonly property string appName: (root.app && root.app.name) || ""
    readonly property string blockText: {
        if (!root.backend)
            return qsTr("Installing and opening apps work in the Store's window.");
        if (root.state_ === "get")
            return Store.getBlockText(root.actions ? root.actions.get : "source", root.app ? root.app.kind : "");
        if (root.state_ === "installed")
            return qsTr("This app has no window of its own.");
        if (root.state_ === "update")
            return Store.getBlockText(root.actions ? root.actions.update : "source", "flatpak");
        return "";
    }
    readonly property bool canAct: root.backend !== null && !!root.host
                                   && (((root.state_ === "get" || root.state_ === "update") && root.blockText === "") || root.state_ === "open")

    implicitWidth: root.state_ === "progress" ? ring.implicitWidth : button.implicitWidth
    implicitHeight: button.implicitHeight

    T.Button {
        id: button
        anchors.fill: parent
        visible: root.state_ !== "progress"
        text: Store.buttonText(root.state_)
        enabled: root.canAct
        implicitHeight: root.large ? Tokens.storeButtonLargeHeight : Tokens.storeButtonHeight
        implicitWidth: Math.max(root.large ? Tokens.storeButtonLargeMinWidth : Tokens.storeButtonMinWidth,
                                Math.ceil(label.implicitWidth + 2 * Tokens.storeButtonPadding))
        focusPolicy: Qt.StrongFocus
        hoverEnabled: true
        Accessible.role: Accessible.Button
        Accessible.name: root.state_ === "open" ? qsTr("Open %1").arg(root.appName)
                       : root.state_ === "installed" ? qsTr("%1 is installed").arg(root.appName)
                       : root.state_ === "update" ? qsTr("Update %1").arg(root.appName) : qsTr("Get %1").arg(root.appName)
        Accessible.description: root.blockText

        onClicked: {
            if (root.state_ === "get")
                root.host.requestGet(root.app);
            else if (root.state_ === "update")
                root.host.requestUpdate(root.app);
            else if (root.state_ === "open")
                root.host.launchApp(root.app);
        }

        // The shared push button's states (ADR-0039 step 24): the hover ink over the grey while hovered, denser while pressed;
        // the control outline under Increase Contrast.
        background: Rectangle {
            radius: height / 2
            color: Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
            border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
            border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)

            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: Appearance.withAlpha(Appearance.colors.hover, button.down ? Tokens.controlPressedOpacity : Tokens.materialHoverOpacity)
                visible: button.enabled && (button.hovered || button.down)
            }
        }

        contentItem: Text {
            id: label
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: button.text
            // Dimmed while disabled, at the shared controls' opacity (the label only: the capsule keeps its grey).
            color: Appearance.withAlpha(Appearance.colors.accentInk, button.enabled ? 1 : Tokens.materialDisabledOpacity)
            readonly property int size: root.large ? Tokens.storeButtonLargeTextSize : Tokens.storeButtonTextSize
            font.family: Appearance.fontFamily
            font.pixelSize: size
            font.weight: Tokens.typographyMenuBoldWeight
            font.letterSpacing: Appearance.tracking(size)
        }

        FocusRing {
            shapeRadius: button.height / 2
            visible: button.visualFocus
        }
    }

    // The operation's ring: its count from pacman's log (flatpak's lines) once there is one, else turning; a square while it
    // waits in the queue, which takes it out (SR18), or while a Flatpak install or update runs, which stops it (SD26, SU-09). Read once a
    // second at most by assistive technologies (the text changes with it).
    ProgressRing {
        id: ring
        anchors.verticalCenter: parent.verticalCenter
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.state_ === "progress"
        readonly property var op: root.operation
        indeterminate: !op || op.state !== "running" || op.total <= 0 || op.done <= 0
        value: op && op.total > 0 ? op.done / op.total : 0
        readonly property bool waiting: !!op && op.state === "waiting"
        stop: ring.waiting || (!!op && op.stoppable === true)
        activeFocusOnTab: visible && stop
        Accessible.role: stop ? Accessible.Button : Accessible.ProgressBar
        Accessible.name: ring.waiting ? qsTr("Remove %1 from the queue").arg(root.appName)
                       : ring.stop ? (ring.op && ring.op.kind === "update" ? qsTr("Stop updating %1").arg(root.appName) : qsTr("Stop installing %1").arg(root.appName))
                       : root.appName
        Accessible.description: Store.operationText(op)
        Accessible.onPressAction: ring.remove()

        function remove(): void {
            if (!ring.stop || !root.backend)
                return;
            if (ring.waiting)
                root.backend.removeWaiting(ring.op.id);
            else
                root.backend.stopOperation(ring.op.id);
        }

        Keys.onPressed: event => {
            if (ActivationKeys.activation(event.key)) {
                ring.remove();
                event.accepted = true;
            }
        }

        TapHandler {
            enabled: ring.stop
            onTapped: ring.remove()
        }

        // The ring for keyboard focus only (ADR-0039 step 24, G7).
        FocusRing {
            shapeRadius: ring.width / 2
            visible: ringFocus.active
        }

        KeyFocus {
            id: ringFocus
        }
    }

    HoverHandler {
        id: hover
    }

    Tooltip {
        id: tip
        text: root.state_ === "progress" ? Store.operationText(root.operation) : root.blockText
        shown: hover.hovered && text !== "" && (root.state_ === "progress" || !button.enabled)
        x: Math.round((root.width - width) / 2)
        y: root.height + Tokens.spacingXs
        z: 10
    }
}
