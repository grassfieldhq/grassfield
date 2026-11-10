pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Grassfield.Ui
import qs.security
import "../../lib/RunMode.js" as RunMode
import "Prompter.js" as Prompter

// The secret sheets (ADR-0035 D-9, step 9b; owner decisions Q1 and Q12; docs/specs/system-dialogs.md section 5): the
// requests grassfield-prompter hands over prompter/1 (PrompterClient), shown one at a time in the one queue they share with
// the polkit sheet (SheetQueue, master-prompt R12), each in a secret sheet (SecretSheet, layer namespace
// `grassfield-secret`, hidden from screen sharing by config/hypr/grassfield/privacy.lua).
//
// The window follows the polkit agent's reviewed rules (shell/security/polkit/AuthAgent.qml), the same code shape so the
// two can be read side by side: nothing over the lock (a request waits behind it, and behind the screen saver); a request
// shown right after an unlock, the saver, another sheet, or after waiting in the queue is held, shown without the keyboard
// until a click past the guard; the field is emptied after each attempt and whenever the sheet hides; a key sink keeps the
// keys while a held request has them and lingers a moment after a request ended under the user's typing, so the rest of a
// password reaches neither another sheet nor the window underneath. Two differences: a request never replaces the one on
// screen (the queue holds it until that one is gone), and a password sent keeps the keys on the sink a moment too (gcr's
// caller asks again at once after a wrong password, as a new request). A confirmation, a NetworkManager request, a KIO
// request and a Bluetooth pairing step are always held (decisions 9-23, 9-28, 9-38 and 10-7); a Bluetooth code shown on the
// screen follows the digits typed on the device without touching the keyboard (10-8).
// Process (ADR-0041 step 1, S3; ADR-0035 decision 9-7): the secret sheets share one queue with the polkit sheet, so they live
// in the polkit agent's process, the security process (../host/SheetHost.qml), where they read the lock in process
// (SheetSession); grassfield-prompter accepts a peer of grassfield-security.service only (`--peer-unit`). The UI never
// instantiates this file.
Scope {
    id: root

    // The one queue (the host's SheetQueue, shared with the polkit agent). Without one no request is taken: each is
    // answered "cancelled".
    property SheetQueue queue: null
    // The test socket of a dev session (the host passes the dev plumbing value PROMPTER_SOCKET); never read outside one.
    property string devSocket: ""
    // The shell's version, for the bridge's log.
    property string shellVersion: ""
    // The URL of a plain theme icon name for the sheet ("" for none: the sheet's generic icon). The host gives the security
    // process's lookup (the system theme only, whose directories the user cannot change); a harness gives none.
    property var iconSource: name => ""

    // Test hooks and the dev socket (ADR-0019): a dev session only.
    readonly property bool dev: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))
    readonly property string socketPath: Prompter.socketPath(root.dev, Quickshell.env("XDG_RUNTIME_DIR"), root.devSocket)

    // A secret sheet is open (shown, or held behind the lock or the saver). Published by the host with the lock state for the
    // UI's SessionState.authorizing.
    readonly property bool requestActive: sheetModel.active

    // The requests this shell holds (shown or waiting), by id; the request whose sheet occupies the window (shown, or its
    // linger), "" for none.
    property var requests: ({})
    property int requestCount: 0
    property string shownId: ""
    // The last request answered from its sheet, and whether that answer gives the keyboard back at once (a cancellation or
    // a confirmation; a password sent keeps it on the sink a moment, its caller often asking again at once after a wrong
    // one). Read by arrive at the request's end.
    property string answeredId: ""
    // The last serial number given to a request.
    property int serial: 0
    property bool answeredKeysBack: false
    // That answer sent a Bluetooth code (a PIN or a passkey), not a password: the linger says so.
    property bool answeredCode: false

    PrompterClient {
        id: client
        path: root.socketPath
        shellVersion: root.shellVersion
        onPrompted: request => root.enqueue(request)
        onWithdrawn: id => root.withdraw(id)
        onProgressed: (id, entered) => root.progress(id, entered)
        onLost: root.dropAll()
    }

    // A request from the bridge: queued (ADR-0035 D-9: at most 8 secret requests; the ninth is refused, and so is any
    // without a queue: "refused", which the bridge answers "cancelled" to gcr and NoSecrets to NetworkManager).
    function enqueue(request: var): void {
        if (root.queue === null || root.requestCount >= Prompter.MAX_REQUESTS || !root.queue.addSecret(request.id)) {
            console.warn("grassfield-secret: request " + request.id + " answered \"cancelled\": " + root.requestCount + " requests held");
            client.refuse(request.id);
            return;
        }
        request.arrivedAt = new Date();
        // Never reused while the shell runs (the bridge's ids start again from p1 when it restarts).
        root.serial++;
        request.serial = root.serial;
        // Another sheet was before it (the polkit sheet, another secret request, or a sheet's linger): shown held.
        request.waited = root.queue.secretHead !== request.id;
        const all = root.requests;
        all[request.id] = request;
        root.requests = all;
        root.requestCount = Object.keys(all).length;
        Qt.callLater(root.sync);
    }

    // The bridge withdrew a request (its caller stopped prompting, left the bus, or answered wrong): a waiting one leaves
    // the queue unseen, the one on screen ends there.
    function withdraw(id: string): void {
        if (!root.forget(id))
            return;
        if (id === root.shownId && sheetModel.active && sheetModel.id === id)
            sheetModel.request = null;
        else if (id !== root.shownId && root.queue !== null)
            root.queue.removeSecret(id);
    }

    // The digits typed on a device for a Bluetooth code the shell shows (decision 10-8): the request's count, and the sheet's
    // when it is on screen. Nothing else: no arrival, no hold, no focus, no field touched.
    function progress(id: string, entered: int): void {
        if (!Object.prototype.hasOwnProperty.call(root.requests, id))
            return;
        const request = root.requests[id];
        if (request.kind !== "bluetooth" || request.pairing.mode !== "display-passkey")
            return;
        request.pairing.entered = entered;
        if (sheetModel.active && sheetModel.id === id)
            sheetModel.entered = entered;
    }

    // The connection ended: every request is gone (the bridge answered them "cancelled").
    function dropAll(): void {
        const ids = Object.keys(root.requests);
        for (let i = 0; i < ids.length; i++)
            root.withdraw(ids[i]);
    }

    function forget(id: string): bool {
        if (!Object.prototype.hasOwnProperty.call(root.requests, id))
            return false;
        const all = root.requests;
        delete all[id];
        root.requests = all;
        root.requestCount = Object.keys(all).length;
        return true;
    }

    // The queue's first secret request goes on screen when the window is free (no request, no linger). Run a turn after
    // the queue changes, never from inside another sheet's state change.
    function sync(): void {
        if (root.queue === null || sheetModel.active || root.shownId !== "")
            return;
        const head = root.queue.secretHead;
        if (head === "" || !Object.prototype.hasOwnProperty.call(root.requests, head))
            return;
        root.shownId = head;
        // A bridge that restarted counts its ids from p1 again: an earlier answer never stands for this request.
        root.answeredId = "";
        sheetModel.request = root.requests[head];
    }

    // The window is free again (the request ended and no linger keeps it): its place in the queue goes, a turn later.
    function release(): void {
        if (sheetModel.active || root.sinkingKeys || root.shownId === "")
            return;
        const id = root.shownId;
        root.shownId = "";
        if (root.queue !== null)
            root.queue.removeSecret(id);
        Qt.callLater(root.sync);
    }

    // The user's answer to the request on screen (SecretSheetModel.answerRequested). Sent only for that request, once
    // (PrompterClient.answer), and an "ok" only while its sheet is shown with the keyboard (not held, not behind the lock):
    // never a password for a request that is not on screen. A cancellation goes out whenever the sheet is open.
    function respond(ok: bool, password: var, choice: bool, identity: var): void {
        const id = sheetModel.id;
        if (id === "" || id !== root.shownId || (ok && !(win.shown && win.takesKeys && !root.sinkingKeys)))
            return;
        if (!client.answer(id, ok, password, choice, identity))
            return;
        root.answeredId = id;
        root.answeredKeysBack = !ok || !sheetModel.asksPassword;
        root.answeredCode = ok && sheetModel.asksCode;
        sheetModel.noteAnswered();
        root.forget(id);
        Qt.callLater(root.finish, id);
    }

    // The answered request leaves the sheet (a turn later, out of the sheet's own call).
    function finish(id: string): void {
        if (sheetModel.active && sheetModel.id === id)
            sheetModel.request = null;
    }

    SecretSheetModel {
        id: sheetModel

        // A request was put on screen (sync), or none is left.
        onActiveChanged: root.arrive()
        onAnswerRequested: (ok, password, choice, identity) => root.respond(ok, password, choice, identity)
    }

    Connections {
        target: root.queue

        // The polkit sheet left the screen: a request shown now comes right after another one ended (held).
        function onSheetEnded(kind: string): void {
            if (kind === "polkit")
                sheetModel.noteEnded();
        }

        // The polkit sheet or a secret one went: the next request may be shown (a turn later).
        function onSecretHeadChanged(): void {
            Qt.callLater(root.sync);
        }
    }

    // A request was put on screen, or the one on screen ended: whether it is held and why, the keyboard not given yet, the
    // time its notice prints (AuthAgent.arrive, without a request replacing another). The keys stay on the sink when the
    // sink already had them, and when the request ended while the window had the keyboard and the user's answer did not
    // give it back (withdrawn under the user's typing, or a password sent: answeredKeysBack). `typing` is read first,
    // before this function changes what takesKeys reads. The writes keep the window mapped and its keyboard steady: the
    // sink first, `requestOpen` false before the hold changes at an end and true only after it at an arrival. What it reads
    // of the request is read from the request itself, never from a binding of the model that may not have followed yet.
    function arrive(): void {
        const answered = root.shownId !== "" && root.answeredId === root.shownId;
        const typing = root.sinkingKeys || (!sheetModel.active && win.takesKeys && !(answered && root.answeredKeysBack));
        const waited = sheetModel.active && sheetModel.request.waited === true;
        // A confirmation is always held (opus review of step 9b, MAJOR-1; decision 9-23): with the keyboard, one stray Space,
        // Return or Enter would activate OK and grant it (a key use asked for at a moment of another program's choosing).
        // Only a click on the alert past the guard gives it the keyboard; until then the keys stay with the window the user
        // was typing in.
        const confirm = sheetModel.active && sheetModel.request.kind === "confirm";
        // A NetworkManager request too (decision 9-28): it comes when NetworkManager decides (a known network whose
        // password changed, an activation any program can start), and what reaches its field may be stored with the
        // connection, so nothing the user is typing elsewhere may land in it.
        const network = sheetModel.active && sheetModel.request.kind === "nm";
        // A KIO request too (decision 9-38): a KIO worker asks when it decides (a job any program of the user can start, with
        // a server of its own), and what reaches its fields goes to that worker.
        const server = sheetModel.active && sheetModel.request.kind === "kio";
        // A Bluetooth pairing step too (decision 10-7): bluetoothd asks when a device decides (an incoming pairing, a
        // service it wants), an authorization is a security decision no key may answer, a code typed goes to the device, and
        // a code shown needs no keyboard at all.
        const pairing = sheetModel.active && sheetModel.request.kind === "bluetooth";
        const queued = typing || (sheetModel.active && sheetModel.followsAnother());
        root.sinkingKeys = typing;
        if (!sheetModel.active)
            root.requestOpen = false;
        root.heldWhy = SheetSession.locked ? "locked" : SheetSession.saverShown ? (SheetSession.starting ? "starting" : "saver") : waited ? "waited" : queued ? "queued" : network && !sheetModel.arrivesHeld(false) ? "network" : server && !sheetModel.arrivesHeld(false) ? "server" : pairing && !sheetModel.arrivesHeld(false) ? sheetModel.pairingHeldWhyOf(sheetModel.request.pairing.mode) : confirm && !sheetModel.arrivesHeld(false) ? "confirm" : "unlock";
        root.heldByLock = sheetModel.active && (typing || waited || confirm || network || server || pairing || sheetModel.arrivesHeld(SheetSession.locked || SheetSession.saverShown));
        root.userFocused = false;
        if (sheetModel.active)
            root.requestOpen = true;
        root.requestStartedAt = sheetModel.active ? sheetModel.request.arrivedAt : null;
        if (!sheetModel.active)
            sheetModel.noteEnded();
        // The linger starts: from the base state, never `lingering`.
        if (typing && !sheetModel.active && !SheetSession.locked) {
            root.lingerWhy = answered ? (root.answeredCode ? "code" : "sent") : "cancelled";
            sinkIdle.restart();
            sinkCap.restart();
        }
        if (!sheetModel.active)
            Qt.callLater(root.release);
    }

    // Held: shown without the keyboard until a click past the guard (`heldWhy` says why in the sheet).
    property bool heldByLock: false
    property string heldWhy: "unlock"
    // A request is in the sheet, as arrive last saw it (written only there): what the window's `visible` and `takesKeys`
    // read instead of the model's `active`.
    property bool requestOpen: false
    // The window keeps the keyboard on the key sink: a held request's keys, or a linger after a request ended.
    property bool sinkingKeys: false
    onSinkingKeysChanged: {
        if (sinkingKeys)
            keySink.forceActiveFocus();
        else
            Qt.callLater(root.release);
    }
    // The request ended while the sink or the sheet had the keys: the window stays mapped, the keyboard on the sink and a
    // notice where the sheet was, until no key came for heldAfterUnlockMs, at most sinkLingerMaxMs, or a click, the lock or
    // the screen saver ends it. Its place in the queue is kept meanwhile: no other sheet shows during a linger.
    readonly property bool lingering: root.sinkingKeys && !sheetModel.active && !SheetSession.locked
    // Why the window lingers: "cancelled" (the request ended unanswered), "sent" (a password was sent) or "code" (a Bluetooth
    // code was sent).
    property string lingerWhy: "cancelled"
    property bool userFocused: false
    property var requestStartedAt: null

    Connections {
        target: SheetSession

        // The lock has the keyboard now: the sink lets go (a linger ends), and an open request is held.
        function onLockedChanged(): void {
            if (!SheetSession.locked) {
                sheetModel.noteUnlock();
                return;
            }
            root.sinkingKeys = false;
            if (sheetModel.active) {
                root.heldByLock = true;
                root.heldWhy = "locked";
                root.userFocused = false;
            }
        }

        // The screen saver came up: it holds the keyboard, so the sink lets go; an open request is held as by the lock, its
        // fields emptied. It ended over a held one: the click guard starts over.
        function onSaverShownChanged(): void {
            if (SheetSession.saverShown)
                root.sinkingKeys = false;
            if (!sheetModel.active || SheetSession.locked)
                return;
            if (SheetSession.saverShown) {
                if (!root.heldByLock || root.userFocused)
                    root.heldWhy = SheetSession.starting ? "starting" : "saver";
                root.heldByLock = true;
                root.userFocused = false;
                sheetModel.clearRequested();
            } else if (root.heldByLock) {
                sheetModel.noteUncovered();
            }
        }
    }

    Timer {
        id: sinkIdle
        interval: sheetModel.heldAfterUnlockMs
        onTriggered: if (root.lingering)
            root.sinkingKeys = false
    }
    Timer {
        id: sinkCap
        interval: sheetModel.sinkLingerMaxMs
        onTriggered: if (root.lingering)
            root.sinkingKeys = false
    }

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        // A request that arrives while the session is locked waits behind the lock: mapped, and given the keyboard, only
        // after the unlock. Nothing is answered meanwhile.
        readonly property bool shown: sheetModel.active && !SheetSession.locked
        // The window holds the keyboard: the sheet is shown and not a held request the user has not clicked yet, or the keys
        // are on the sink. Both this and `visible` read the base state only (AuthAgent's rule).
        readonly property bool takesKeys: !SheetSession.locked && ((root.requestOpen && (!root.heldByLock || root.userFocused)) || root.sinkingKeys)

        visible: !SheetSession.locked && (root.requestOpen || root.sinkingKeys)
        // Hidden by the lock: whatever was typed is dropped. Shown again: a request that was not held takes the keys at
        // once; a held one waits for a click with empty fields.
        onShownChanged: {
            if (shown)
                sheetModel.noteShown();
            const sheet = holder.item as SecretSheet;
            if (!sheet)
                return;
            if (shown && !root.heldByLock)
                sheet.focusField();
            else if (sheetModel.active)
                sheetModel.clearRequested();
        }
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: win.shown ? Appearance.withAlpha(Appearance.colors.shadow, Tokens.shadowOpacity) : "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: win.takesKeys ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-secret"
        // qmllint disable missing-type
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && (win.shown || root.lingering) ? blurRegion : null
        // qmllint enable missing-type

        Region {
            id: blurRegion
            item: root.lingering ? endedNotice : holder
            radius: root.lingering ? Tokens.radiusDialog : Tokens.radiusAlert
        }

        // The keys the window keeps stop here: no field, nothing underneath. Esc cancels a held request; a key while the
        // sink lingers keeps it a while longer.
        Item {
            id: keySink
            Keys.onPressed: event => {
                event.accepted = true;
                if (root.lingering)
                    sinkIdle.restart();
                else if (event.key === Qt.Key_Escape)
                    sheetModel.cancel();
            }
            Keys.onReleased: event => event.accepted = true
        }

        // Clicks outside the sheet do nothing (no click-outside cancel) but give the field the focus when the sheet has the
        // keyboard for it; one while the sink lingers ends the linger.
        MouseArea {
            anchors.fill: parent
            onPressed: {
                if (root.lingering) {
                    root.sinkingKeys = false;
                    return;
                }
                const sheet = holder.item as SecretSheet;
                if (sheet && win.takesKeys && !root.sinkingKeys)
                    sheet.focusField();
            }
        }

        Loader {
            id: holder
            active: sheetModel.active
            anchors.centerIn: parent
            sourceComponent: SecretSheet {
                model: sheetModel
                // An app's theme icon (a plain name, SecretSheetModel.appIcon), only when the system theme has it (the host's
                // lookup, as the polkit sheet's icon).
                appIconSource: root.iconSource(sheetModel.appIcon)
                heldNotice: root.heldByLock ? sheetModel.heldNotice(root.requestStartedAt, root.heldWhy) : ""
                inputEnabled: !root.sinkingKeys
                // The sheet got the focus while the sink has the keys: the sink takes it back.
                onActiveFocusChanged: if (activeFocus && root.sinkingKeys)
                    keySink.forceActiveFocus()
            }
        }

        // The linger made visible: the request is gone (or the password was sent) and typing goes nowhere for a moment.
        // Fixed text, nothing of the requester's; no control and no focus.
        Material {
            id: endedNotice
            objectName: "secretEndedNotice"
            visible: root.lingering
            anchors.centerIn: parent
            width: Tokens.panelAlertWidth
            height: endedColumn.implicitHeight + 2 * Tokens.spacingLg
            radius: Tokens.radiusDialog

            Column {
                id: endedColumn
                x: Tokens.spacingLg
                y: Tokens.spacingLg
                width: endedNotice.width - 2 * Tokens.spacingLg
                spacing: Tokens.spacingSm

                Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: root.lingerWhy === "sent" ? qsTr("Password sent") : root.lingerWhy === "code" ? qsTr("Code sent") : qsTr("Request cancelled")
                    horizontalAlignment: Text.AlignHCenter
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyTitleSize
                    font.weight: Tokens.typographyMenuBoldWeight
                    wrapMode: Text.Wrap
                    Accessible.role: Accessible.AlertMessage
                    Accessible.name: text
                }

                Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: qsTr("What you type is ignored for a moment.")
                    horizontalAlignment: Text.AlignHCenter
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                    font.weight: Tokens.typographySmallWeight
                    wrapMode: Text.Wrap
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }
            }
        }

        // A held request: the first click on the sheet (anywhere) gives it the keyboard, once SecretSheetModel.heldGuardMs
        // passed since it appeared; the press goes on to what is under it.
        MouseArea {
            anchors.fill: parent
            enabled: root.heldByLock && !root.userFocused
            onPressed: mouse => {
                mouse.accepted = false;
                if (!sheetModel.heldClickAccepted())
                    return;
                root.userFocused = true;
                root.sinkingKeys = false;
                const sheet = holder.item as SecretSheet;
                if (sheet)
                    sheet.focusField();
            }
        }

        // While the screen saver shows, a press (any button) or the wheel on the sheet goes nowhere.
        MouseArea {
            anchors.fill: parent
            enabled: SheetSession.saverShown
            acceptedButtons: Qt.AllButtons
            onPressed: mouse => mouse.accepted = true
            onWheel: wheel => wheel.accepted = true
        }
    }

    // What the agent holds, for tests: "<connection> <name> shown=<0|1> held=<0|1> waiting=<n> linger=<0|1>". Counts and
    // states only, never a requester or a text.
    function devState(): string {
        if (!root.dev)
            return RunMode.REFUSED;
        const waiting = root.requestCount - (sheetModel.active ? 1 : 0);
        return client.state + " " + (client.nameState === "" ? "-" : client.nameState) + " shown=" + (win.shown ? 1 : 0) + " held=" + (root.heldByLock && !root.userFocused ? 1 : 0) + " waiting=" + waiting + " linger=" + (root.lingering ? 1 : 0);
    }

    IpcHandler {
        target: "secrets"

        // Test hook (dev session only, else "refused"): devState().
        function state(): string {
            return root.devState();
        }
    }
}
