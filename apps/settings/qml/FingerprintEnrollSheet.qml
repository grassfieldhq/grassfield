pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import Grassfield.Ui
import "Fingerprint.js" as Fingerprint

// Fingerprint & Security Key > Add Fingerprint… (ADR-0045 OC-0.7), as macOS 27 enrols a finger: the fingerprint glyph in a
// ring that fills with each touch the reader accepted, one line that says what to do next, Cancel, and Done once fprintd said
// the print is complete. fprintd does the work over D-Bus (systembus.h enrollFinger: Claim, EnrollStart, each EnrollStatus as
// Backend.progress, EnrollStop, Release); it asks polkit first, so Grassfield's polkit sheet may come up before the reader
// listens. Cancel, Esc and the window closing stop it (Backend.stopEnroll). The state machine is Fingerprint.js. Through
// SystemService, so never in a dev session.
Sheet {
    id: root

    required property var backend
    required property var system

    // The enrolment ended (done or not): the pane reads the fingers again.
    signal ended

    property var enrolment: null
    readonly property string tag: "fprint.enroll"
    readonly property bool running: Fingerprint.running(root.enrolment)
    readonly property bool done: root.enrolment !== null && root.enrolment.phase === "done"
    readonly property bool failed: root.enrolment !== null && root.enrolment.phase === "failed"

    title: qsTr("Add a Fingerprint")
    confirmText: root.failed ? qsTr("Try Again") : qsTr("Done")
    confirmEnabled: root.done || root.failed
    showCancel: !root.done
    // Done closes; Try Again starts over with the same finger and keeps the sheet open.
    confirmHandler: () => {
        if (root.failed) {
            root.begin(root.enrolment.finger, root.enrolment.stages);
            return false;
        }
        return "";
    }

    function openFor(finger: string, stages: int): void {
        root.open();
        root.begin(finger, stages);
    }

    function begin(finger: string, stages: int): void {
        root.enrolment = Fingerprint.start(finger, stages);
        if (!root.system.act("add fingerprint", {op: "fprint.enroll", finger: finger}, root.tag))
            root.enrolment = Fingerprint.finish(root.enrolment, false, root.system.dev ? "" : qsTr("Another enrolment is still running."));
    }

    // "Right index finger".
    function fingerText(finger: string): string {
        return Fingerprint.NAMES[finger] !== undefined ? qsTranslate("Fingerprint", Fingerprint.NAMES[finger]) : finger;
    }

    // The line under the ring for a message key (Fingerprint.js); "the sensor" where macOS names its own (ADR-0045 OC-0.5).
    function messageText(state: var): string {
        if (state === null)
            return "";
        switch (state.message) {
        case "place":
            return state.phase === "starting" ? qsTr("Getting the fingerprint reader ready…") : qsTr("Place your %1 on the sensor.").arg(root.fingerText(state.finger).toLowerCase());
        case "again":
            return qsTr("Lift your finger and rest it on the sensor again, a little differently each time.");
        case "edges":
            return qsTr("Adjust your grip to capture the edges of your fingerprint.");
        case "retry":
            return qsTr("That touch was not read. Rest your finger on the sensor again.");
        case "short":
            return qsTr("Swipe your finger across the whole sensor.");
        case "center":
            return qsTr("Centre your finger on the sensor.");
        case "remove":
            return qsTr("Lift your finger, then rest it on the sensor again.");
        case "completed":
            return qsTr("Your fingerprint is ready.");
        case "full":
            return qsTr("The fingerprint reader has no room for another print.");
        case "disconnected":
            return qsTr("The fingerprint reader was disconnected.");
        case "duplicate":
            return qsTr("This finger is already enrolled.");
        case "failed":
        case "unknown":
            return qsTr("The fingerprint could not be enrolled.");
        case "error":
            return state.reason !== "" ? qsTr("The fingerprint could not be enrolled: %1.").arg(state.reason) : qsTr("The fingerprint could not be enrolled.");
        }
        return "";
    }

    // Cancel, Esc: fprintd stops at its next quarter-second wait and releases the reader.
    // Whatever closes the sheet stops fprintd's enrolment, also one this sheet thinks over (its job may outlive what the sheet
    // saw; a no-op when none runs): a reader left claimed would enrol whoever touches it next as the owner (security review of
    // ADR-0045, M-1). Main.qml cancels the sheet when the window closes.
    onCanceled: {
        root.backend.stopEnroll();
        root.enrolment = null;
        root.ended();
    }
    onAccepted: {
        root.backend.stopEnroll();
        root.enrolment = null;
        root.ended();
    }

    Connections {
        target: root.backend
        // Only while it waits for an answer: a Backend answer is not handed to every row and sheet of the window (the audit's notes).
        enabled: root.shown || root.lastReason !== ""
        // A backend without the enrolment's progress (a test's) leaves the sheet waiting for its end.
        ignoreUnknownSignals: true

        function onProgress(tag: string, status: string): void {
            if (tag === root.tag && root.shown)
                root.enrolment = Fingerprint.step(root.enrolment, status);
        }

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === root.tag && root.shown)
                root.enrolment = Fingerprint.finish(root.enrolment, ok, root.lastReason);
            if (tag === root.tag)
                root.lastReason = "";
        }

        function onFailed(tag: string, reason: string): void {
            if (tag === root.tag)
                root.lastReason = reason;
        }
    }
    // failed(tag, reason) comes just before finished(tag, false, …).
    property string lastReason: ""

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            Item {
                width: parent.width
                height: Tokens.settingsEnrollRingSize

                Shape {
                    id: ring
                    width: Tokens.settingsEnrollRingSize
                    height: Tokens.settingsEnrollRingSize
                    anchors.horizontalCenter: parent.horizontalCenter
                    preferredRendererType: Shape.CurveRenderer
                    readonly property real stroke: Tokens.settingsEnrollRingStroke

                    ShapePath {
                        fillColor: "transparent"
                        strokeColor: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                        strokeWidth: ring.stroke
                        capStyle: ShapePath.RoundCap

                        PathAngleArc {
                            centerX: ring.width / 2
                            centerY: ring.height / 2
                            radiusX: (ring.width - ring.stroke) / 2
                            radiusY: radiusX
                            startAngle: 0
                            sweepAngle: 360
                        }
                    }

                    ShapePath {
                        fillColor: "transparent"
                        strokeColor: root.failed ? Appearance.colors.danger : Appearance.colors.accent
                        strokeWidth: ring.stroke
                        capStyle: ShapePath.RoundCap

                        PathAngleArc {
                            centerX: ring.width / 2
                            centerY: ring.height / 2
                            radiusX: (ring.width - ring.stroke) / 2
                            radiusY: radiusX
                            startAngle: -90
                            sweepAngle: 360 * Fingerprint.progress(root.enrolment)

                            Behavior on sweepAngle {
                                NumberAnimation {
                                    duration: Appearance.duration(Tokens.motionNormal)
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }
                    }
                }

                Icon {
                    anchors.centerIn: ring
                    name: "fingerprint"
                    size: Tokens.settingsEnrollGlyphSize
                    color: root.done ? Appearance.colors.accentInk : Appearance.colors.textSecondary
                }

                Spinner {
                    visible: root.enrolment !== null && root.enrolment.phase === "starting"
                    anchors.right: ring.left
                    anchors.rightMargin: Tokens.spacingMd
                    anchors.verticalCenter: ring.verticalCenter
                }
            }

            Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: root.messageText(root.enrolment)
                color: root.failed ? Appearance.colors.danger : Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }
    }
}
