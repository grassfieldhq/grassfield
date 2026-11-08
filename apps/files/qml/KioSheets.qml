pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "KioSheetsLogic.js" as KioSheetsLogic

// KIO's questions in Files as the window's sheets (ADR-0035 D-12 a; docs/specs/system-dialogs.md section 9): a name that
// already exists, an item the operation can't handle, a deletion, a worker's message, a certificate that can't be
// verified, a notice; and Files' own questions before it runs a program, explains a Windows or Java program or another
// system's app (ADR-0011 amendment 2026-11-08). src/kioprompts.h asks them one at a time (FilesApp.prompts.current); the window the user last worked
// in shows them (BrowserWindow.qml), and every answer goes back to the job that asked (FilesApp.prompts.reply). A question
// whose job ends while it is shown goes away by itself, unanswered.
Item {
    id: root

    // FilesApp.prompts (null: no questions, a stand-in app in the tests of other windows).
    required property var prompts
    // This window shows the questions.
    required property bool shown
    property Item focusBack: null

    // The question this window shows ({} for none), and the sheet for it (KioSheetsLogic.js).
    property var request: ({})
    readonly property var spec: KioSheetsLogic.sheet(root.request)
    property int shownId: -1
    // The question the choices below belong to: a question hidden a moment (another sheet, a menu) keeps them.
    property int choicesFor: -1
    property bool applyToAll: false
    property bool alwaysTrust: false
    property bool detailsShown: false

    anchors.fill: parent

    function answer(button: string): void {
        const id = root.shownId;
        if (id < 0)
            return;
        root.shownId = -1;
        root.prompts.reply(id, {
            button: button,
            applyToAll: root.applyToAll,
            alwaysTrust: root.alwaysTrust
        });
    }

    // The question on screen changed, or the window that shows it (the reply itself may bring the next one).
    function refresh(): void {
        const current = root.shown && root.prompts ? root.prompts.current : ({});
        const id = current && current.id !== undefined ? current.id : -1;
        if (id >= 0 && id === root.shownId)
            return;
        // Another question: the choices made on the last one don't carry over.
        if (id >= 0 && id !== root.choicesFor) {
            root.applyToAll = false;
            root.alwaysTrust = false;
            root.detailsShown = false;
            root.choicesFor = id;
        }
        root.request = current;
        if (id >= 0 && root.spec === null) {
            // A kind this version doesn't know: stop the operation rather than leave it waiting.
            root.shownId = id;
            root.answer("stop");
            return;
        }
        root.shownId = id;
        if (id >= 0) {
            // A question that follows another one at once (two jobs' conflicts): the second click of a double click, or
            // a repeated Return, meant for that one must not answer this one unseen.
            sheet.holdInput = true;
            inputHold.restart();
            sheet.open();
        } else if (sheet.shown) {
            sheet.close();
        }
    }

    Timer {
        id: inputHold
        interval: Application.styleHints.mouseDoubleClickInterval
        onTriggered: sheet.holdInput = false
    }

    // Shown again (another sheet or a menu closed): once what closed it has run (a menu's action may take the focus).
    onShownChanged: Qt.callLater(root.refresh)
    onPromptsChanged: root.refresh()
    Component.onCompleted: root.refresh()

    Connections {
        target: root.prompts
        function onCurrentChanged(): void {
            root.refresh();
        }
    }

    Sheet {
        id: sheet
        keepsKeyboard: true
        title: root.spec ? root.spec.title : ""
        message: root.spec ? root.spec.message : ""
        confirmText: root.spec ? root.spec.confirmText : ""
        destructive: root.spec ? root.spec.destructive : false
        showCancel: root.spec ? root.spec.showCancel : true
        cancelText: root.spec ? root.spec.cancelText : ""
        returnCancels: root.spec ? root.spec.returnCancels : false
        extraButtons: !root.spec ? [] : root.spec.extras.map(e => e.id === "certificate" && root.detailsShown ? {
                id: e.id,
                text: qsTr("Hide Certificate")
            } : e.id === "details" && root.detailsShown ? {
                id: e.id,
                text: qsTr("Hide Details")
            } : e)
        focusBack: root.focusBack

        // After the sheet has closed: the reply may bring the next question at once.
        onAccepted: root.answer(root.spec ? root.spec.confirmId : "stop")
        onCanceled: root.answer(root.spec ? root.spec.cancelId : "stop")
        onExtra: id => {
            if (id === "certificate" || id === "details") {
                root.detailsShown = !root.detailsShown;
                return;
            }
            sheet.close();
            root.answer(id);
        }

        CheckBox {
            visible: root.spec !== null && root.spec.applyToAll
            text: qsTr("Apply to All")
            checked: root.applyToAll
            onToggled: root.applyToAll = checked
        }

        // The worker's details (a message box), or the certificate chain and "Always trust".
        Text {
            visible: root.detailsShown && text !== ""
            width: parent ? parent.width : 0
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: {
                if (!root.detailsShown || !root.request)
                    return "";
                if (root.request.kind === "message")
                    return root.request.details || "";
                if (root.request.kind !== "certificate")
                    return "";
                const lines = root.request.error ? [root.request.error, ""] : [];
                // The locale's long date without the weekday ("1 January 2026", "January 1, 2026").
                const format = Qt.locale().dateFormat(Locale.LongFormat).replace(/d{4}[,\s]*/g, "").replace(/[,\s]+$/, "").trim();
                return lines.concat(KioSheetsLogic.chainLines(root.request.chain, d => {
                    const date = new Date(d);
                    return isNaN(date.getTime()) ? qsTr("unknown") : date.toLocaleDateString(Qt.locale(), format);
                })).join("\n");
            }
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }

        CheckBox {
            visible: root.detailsShown && root.request && root.request.kind === "certificate"
            text: qsTr("Always trust “%1”").arg(root.request && root.request.host ? root.request.host : "")
            checked: root.alwaysTrust
            onToggled: root.alwaysTrust = checked
        }
    }
}
