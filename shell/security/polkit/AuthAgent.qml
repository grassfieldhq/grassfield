pragma ComponentBehavior: Bound
// Portions adapted from Omarchy shell/plugins/polkit/PolkitAgent.qml (omacom/omarchy, branch
// quattro): PolkitAgent/AuthFlow wiring. Copyright (c) David Heinemeier Hansson, MIT License (upstream LICENSE,
// basecamp/omarchy v4.0.4; notice shipped as packaging/licenses/omarchy-MIT.txt).
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import Quickshell.Wayland
import Grassfield.Ui
import qs.security
import "../../lib/RunMode.js" as RunMode

// The session's polkit authentication agent (SEC6, ADR-0010): Quickshell.Services.Polkit,
// one instance per session. polkit allows one agent per session; when another one already owns
// the session (expected in the nested dev session, where the owner's shell has it), registration
// fails: that is logged once, no dialog is ever shown and nothing is approved — requests keep
// going to the other agent.
// Process (ADR-0041 step 1, S3): instantiated in the security process only (../host/SheetHost.qml, made by SecurityHost.qml),
// beside the lock it reads in process (SheetSession, fed there by Lock and Idle); the UI never instantiates it, so the
// session has one agent, and a crash of the UI leaves it registered. The sheet is drawn with Grassfield.Ui and qs.security
// only.
Scope {
    id: root

    readonly property bool registered: agent.isRegistered
    // A request is open: its sheet shown, or held (behind the lock or the screen saver, or queued). Published by the host with
    // the lock state for the UI's SessionState.authorizing (the clipboard history records nothing while it is true and 2 s
    // after, ADR-0034 Q11; the UI closes its menus when a sheet opens).
    readonly property bool requestActive: dialogModel.active

    // The one queue of the polkit sheet and the secret sheets (ADR-0035 D-9, step 9b; SheetQueue), given by the host; null
    // outside it (this agent's own harness), where nothing waits.
    property SheetQueue queue: null
    // A secret sheet came first: the request waits (ADR-0035 D-9: no sheet takes the keyboard from another). The model is
    // handed no request meanwhile (`flow` below), so nothing of it is mapped, focused or held until the queue lets it; it
    // then arrives as a request right after another one ended (SheetQueue.sheetEnded, below): held, its notice "right after
    // another one", without the keyboard until a click past the guard.
    readonly property bool waiting: root.queue !== null && root.queue.polkitWaits
    // The polkit sheet's place in the queue: from a request's arrival (while it waits too) until its sheet is gone, the key
    // sink's linger included (the host binds SheetQueue.polkitPresent to it).
    readonly property bool queuePresent: agent.isActive || root.requestOpen || root.sinkingKeys
    // The URL of a plain theme icon name for the sheet ("" for none: the sheet shows its lock alone). The host gives the
    // security process's lookup (the system theme only, whose directories the user cannot change); a harness gives none.
    property var iconSource: name => ""

    // Registration (ADR-0041 S3; the opus review of S3, MINOR-3). polkit takes one agent per session, and Quickshell asks once,
    // when the agent is made: a refusal only warns. After an upgrade, or a restart in the wrong order, the UI's earlier agent
    // may still hold the session when this one asks; it then asks again while it is not registered, after
    // registrationRetryMs, doubling to registrationRetryMaxMs: a new object path makes Quickshell register again (its
    // setPath). It only ever asks to be the session's agent; it never answers a request by itself. Never in a dev session:
    // the nested agent must not take the owner's session when the owner's own agent restarts (it asks once, as before).
    readonly property string agentPath: "/org/grassfield/PolkitAgent"
    readonly property bool devSession: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))
    property int registrationRetryMs: 3000
    readonly property int registrationRetryMaxMs: 60000
    // Asked again this many times since the start (the path's suffix).
    property int registrationTries: 0

    function retryRegistration(): void {
        if (agent.isRegistered || root.devSession)
            return;
        root.registrationTries += 1;
        if (root.registrationTries <= 5 || root.registrationTries % 10 === 0)
            console.warn("grassfield-polkit: not registered (another authentication agent owns this session); asking again (" + root.registrationTries + ")");
        agent.path = root.agentPath + "/" + root.registrationTries;
    }

    Timer {
        id: registrationRetry
        interval: Math.min(root.registrationRetryMaxMs, root.registrationRetryMs * Math.pow(2, Math.min(root.registrationTries, 10)))
        running: !agent.isRegistered && !root.devSession
        repeat: true
        onTriggered: root.retryRegistration()
    }

    PolkitAgent {
        id: agent
        path: root.agentPath

        onIsRegisteredChanged: {
            if (isRegistered)
                console.info("grassfield-polkit: authentication agent registered");
            else
                console.warn("grassfield-polkit: authentication agent unregistered");
        }
    }

    AuthDialogModel {
        id: dialogModel
        // Quickshell qmltypes name the AuthFlow property type without exporting it (metadata quirk).
        // qmllint disable unresolved-type
        flow: agent.isActive && !root.waiting ? agent.flow : null
        // The request Quickshell has open, handed over or not, and whether the user sees it now: its sheet is on screen and in
        // front (no lock, no screen saver, displays on, not waiting behind another sheet, in the sheet). Otherwise a device must
        // not answer it: it is refused as soon as PAM talks without asking (AuthDialogModel.refusesUnseen; ADR-0045 OC-6,
        // security review of e3542510, MAJOR-2). A held request may be answered by a touch only when it is held as "right
        // after another one" (integrator decision after the re-review, the macOS model: Settings' Remote Login and Add Printer
        // ask two or three times in a row) or once the user clicked past its guard. Held for any other reason (it arrived just
        // after an unlock, or while locked or under the saver) it may not: a finger left on the reader after unlocking would
        // answer it, and the lock marker tells any process of the user's when to ask (opus re-review, MINOR-1).
        request: agent.flow
        // qmllint enable unresolved-type
        answerable: !SheetSession.locked && !SheetSession.saverShown && !SheetSession.displaysOff && !root.waiting && root.requestOpen
                    && (!root.heldByLock || root.userFocused || root.heldWhy === "queued")

        // A request arrived, or none is left.
        onActiveChanged: root.arrive(false)
        // Another request replaces the one in the sheet: Quickshell 0.3.1 activates a new request at once, abandoning the open
        // one (agentimpl.cpp initiateAuthentication; re-check of b5d7657), so `active` does not change. It is a new arrival,
        // held (review of f513b3b, MEDIUM-2): keys typed for the first must not land in its field. One that arrives after the
        // first ended passes through no request and is held by AuthDialogModel.afterRequest. Whether a request was in the sheet
        // is a plain flag: Quickshell may destroy the flow it abandons before it hands over the next one, and a reference to a
        // destroyed flow reads null (the next one then passed for a first request, not held; review of 9ad4307..b38618f).
        onFlowChanged: {
            const follows = root.flowShown && flow !== null && flow !== root.shownFlow;
            root.flowShown = flow !== null;
            root.shownFlow = flow;
            if (follows)
                root.arrive(true);
        }
    }

    // A request is in the sheet; the last flow seen (null once destroyed), to tell the same one handed over again from the next.
    property bool flowShown: false
    property var shownFlow: null

    // A request arrives (`follows`: it replaced the one in the sheet) or none is left: whether it is held and why, the
    // keyboard not given yet, the time its notice prints. One that follows starts empty and its click guard starts over. The
    // keys keep going to the key sink when the request replaced the one that had the keyboard (the user was typing its
    // password; re-check of b5d7657, MEDIUM-2), when the request ended unanswered while the window had the keyboard (its
    // requester gave up, or Quickshell ended it, under the user's typing; security counter-review of f9e24e1, LOW-1: the rest
    // of the password went to the window underneath), and whenever the sink already had them: a request that ends meanwhile
    // leaves the sink lingering (`lingering`; check of 38dbfe8, MEDIUM-B), and one that arrives meanwhile keeps it and is
    // held, as right after another (only a click past its guard gives it the keyboard). So the rest of what is typed reaches
    // neither a field nor the window underneath. A request the user answered (sent or cancelled: AuthDialogModel.answered)
    // gives the keyboard back at once, as on macOS. `typing` is read first, before this function changes what takesKeys
    // reads: takesKeys and `visible` read `requestOpen`, which only this function writes, never `active`, so at a request's
    // end they still say whether the window had the keyboard, whichever binding saw the end first. The writes keep the window
    // mapped and its keyboard steady: the sink first (at an end the window keeps the keys through it before `requestOpen` lets
    // go), `requestOpen` false before the hold changes at an end and true only after it at an arrival (a held request never
    // asks for the keyboard on the way). No request left: the next one within heldAfterUnlockMs is held (noteEnded).
    function arrive(follows: bool): void {
        const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);
        const queued = follows || typing || (dialogModel.active && dialogModel.followsAnother());
        root.sinkingKeys = typing;
        if (!dialogModel.active)
            root.requestOpen = false;
        root.heldWhy = SheetSession.locked ? "locked" : SheetSession.saverShown ? "saver" : queued ? "queued" : "unlock";
        root.heldByLock = dialogModel.active && (follows || typing || dialogModel.arrivesHeld(SheetSession.locked || SheetSession.saverShown));
        root.userFocused = false;
        if (dialogModel.active)
            root.requestOpen = true;
        root.requestStartedAt = dialogModel.active ? new Date() : null;
        if (!dialogModel.active)
            dialogModel.noteEnded();
        // The linger starts: from the base state, never `lingering`, whose binding may not have seen this change of `active`
        // yet (check of c1ca44f: its timers then never started, and with no key after the end the linger never ended).
        if (typing && !dialogModel.active && !SheetSession.locked) {
            sinkIdle.restart();
            sinkCap.restart();
        }
        if (follows) {
            dialogModel.clearRequested();
            dialogModel.noteShown();
        }
    }

    // A secret sheet left the screen: a polkit request handed over now comes right after another one ended, and is held as
    // such (AuthDialogModel.followsAnother). The queue says so before it changes, so before the request can be handed over.
    Connections {
        target: root.queue

        function onSheetEnded(kind: string): void {
            if (kind === "secret")
                dialogModel.noteEnded();
        }
    }

    // The request arrived, or was open, while the session was locked (review of 1d2c856) or the screen saver showed (ADR-0032,
    // owner decision 2026-10-26: over the opaque saver the sheet looked like the lock's prompt and took the keys at once),
    // arrived within AuthDialogModel.heldAfterUnlockMs after an unlock (review of d8e654c), or followed another request in the
    // same sheet: the sheet is shown without the keyboard until the user clicks it (AuthDialogModel.heldGuardMs after it
    // appeared, after the saver ended or after the request before it), so keys typed right after the unlock, the wake or the
    // previous answer never reach its field; it says when the request arrived and why it waited (`heldWhy`). Both delays are timed by the model's Timers (monotonic, review of 6e24d36); requestStartedAt is only the
    // wall-clock time the notice prints (display, never compared).
    property bool heldByLock: false
    property string heldWhy: "unlock"
    // A request is in the sheet, as arrive last saw it (written only there): what the window's `visible` and `takesKeys`
    // read instead of the model's `active` (see arrive). False at the start: the agent has no request when it is made (it
    // registers asynchronously; the first request is an `active` change, so it goes through arrive).
    property bool requestOpen: false
    // The window keeps the keyboard on the key sink: a held request that replaced the one being typed into, or no request
    // left after one ended unanswered while the window had the keys or the sink had them (`lingering`).
    property bool sinkingKeys: false
    onSinkingKeysChanged: if (sinkingKeys)
        keySink.forceActiveFocus()
    // The request ended while the sink had the keys, or unanswered while the sheet had them (its requester gave up, or the
    // request it replaced completed): the window stays mapped, with the keyboard on the sink and a notice where the sheet was
    // (endedNotice), until no key came for heldAfterUnlockMs (sinkIdle), at most sinkLingerMaxMs (sinkCap), or a click, the
    // lock or the screen saver ends it (check of 38dbfe8, MEDIUM-B; security counter-review of f9e24e1, LOW-1 and LOW-3).
    readonly property bool lingering: root.sinkingKeys && !dialogModel.active && !SheetSession.locked
    property bool userFocused: false
    property var requestStartedAt: null

    Connections {
        target: SheetSession

        // The lock has the keyboard now: the sink lets go (a linger ends), and an open request is held.
        function onLockedChanged(): void {
            if (!SheetSession.locked) {
                dialogModel.noteUnlock();
                return;
            }
            root.sinkingKeys = false;
            if (dialogModel.active) {
                root.heldByLock = true;
                root.heldWhy = "locked";
                root.userFocused = false;
            }
        }

        // The screen saver came up: it holds the keyboard, so the sink lets go (a linger ends); an open request is held as by
        // the lock, its field emptied. It ended over a held one: the click guard starts over, so no click in the next
        // heldGuardMs gives the sheet the keyboard (such a click still reaches the control it hits, as after an unlock: Cancel
        // at worst).
        function onSaverShownChanged(): void {
            if (SheetSession.saverShown)
                root.sinkingKeys = false;
            if (!dialogModel.active || SheetSession.locked)
                return;
            if (SheetSession.saverShown) {
                if (!root.heldByLock || root.userFocused)
                    root.heldWhy = "saver";
                root.heldByLock = true;
                root.userFocused = false;
                dialogModel.clearRequested();
            } else if (root.heldByLock) {
                dialogModel.noteUncovered();
            }
        }
    }

    // The sink's linger ends when no key came for heldAfterUnlockMs, and at the latest sinkLingerMaxMs after the request
    // ended (both restarted by arrive; a key restarts sinkIdle). Neither touches a sink that holds a request's keys.
    Timer {
        id: sinkIdle
        interval: dialogModel.heldAfterUnlockMs
        onTriggered: if (root.lingering)
            root.sinkingKeys = false
    }
    Timer {
        id: sinkCap
        interval: dialogModel.sinkLingerMaxMs
        onTriggered: if (root.lingering)
            root.sinkingKeys = false
    }

    // Registration is asynchronous; report a refusal once, after it had time to complete.
    Timer {
        running: true
        interval: 3000
        onTriggered: {
            if (!agent.isRegistered)
                console.warn("grassfield-polkit: not registered (another authentication agent owns this session); no dialog will be shown, nothing is approved");
        }
    }

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        // A request that arrives while the session is locked waits behind the lock (macOS: the authorization sheet shows
        // once the user is back): the sheet is mapped, and takes the keyboard, only after the unlock (GF-116). The request
        // itself stays pending; nothing is answered or approved meanwhile.
        readonly property bool shown: dialogModel.active && !SheetSession.locked
        // The window holds the keyboard: the sheet is shown and not a held request the user has not clicked yet, or the keys
        // are on the sink (a held request's, or lingering after the request ended). Both this and `visible` read the base
        // state only, never `shown` or `lingering`: when a request ends while the sink has the keys, an intermediate binding
        // updated before the other went false for a moment, and a hidden PanelWindow is destroyed and made again, handing
        // the keyboard to the window underneath meanwhile (check of c1ca44f, M1). The request is `requestOpen`, not the
        // model's `active`: arrive alone moves it, after the sink, so a request that ends unanswered under the user's typing
        // never unmaps the window before the sink holds the keys (security counter-review of f9e24e1, LOW-1).
        readonly property bool takesKeys: !SheetSession.locked && ((root.requestOpen && (!root.heldByLock || root.userFocused)) || root.sinkingKeys)

        // Mapped with the sheet, and while the sink lingers (no sheet then, no dimming: the notice below says why).
        visible: !SheetSession.locked && (root.requestOpen || root.sinkingKeys)
        // Hidden by the lock: whatever was typed is dropped (as after every attempt). Shown again: a request that was not
        // held takes the keys at once; a held one waits for a click (takesKeys) with an empty field.
        onShownChanged: {
            if (shown)
                dialogModel.noteShown();
            const dialog = holder.item as AuthDialog;
            if (!dialog)
                return;
            if (shown && !root.heldByLock)
                dialog.focusField();
            else if (dialogModel.active)
                dialogModel.clearRequested();
        }
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: win.shown ? Appearance.withAlpha(Appearance.colors.shadow, Tokens.shadowOpacity) : "transparent"
        // The dim fades in with the sheet (UI audit 2026-11-05 U22). Display only: the window's mapping and keyboard
        // (visible, takesKeys) never read the colour.
        Behavior on color {
            ColorAnimation {
                duration: Appearance.duration(Tokens.motionFast)
            }
        }
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: win.takesKeys ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-polkit"
        // qmllint disable missing-type
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && (win.shown || root.lingering) ? blurRegion : null
        // qmllint enable missing-type

        Region {
            id: blurRegion
            item: root.lingering ? endedNotice : holder
            radius: Tokens.radiusDialog
        }

        // The keys the window keeps (sinkingKeys) stop here: no field, nothing underneath, until a click past the guard gives
        // the sheet its field, or the linger ends. Esc cancels a held request (it fails closed; check of 38dbfe8, LOW-1); a
        // key while the sink lingers keeps it a while longer. The sheet's items are the only others in this window that take
        // the focus: while the sink has the keys its field and identity rows are disabled, and the sheet hands any focus it
        // gets back to the sink (the Loader below; check of 38dbfe8, MEDIUM-A, and of c1ca44f, M2).
        Item {
            id: keySink
            Keys.onPressed: event => {
                event.accepted = true;
                if (root.lingering)
                    sinkIdle.restart();
                else if (event.key === Qt.Key_Escape)
                    dialogModel.cancel();
            }
            Keys.onReleased: event => event.accepted = true
        }

        // Clicks outside the sheet do nothing (no click-outside cancel for authentication) but give the field the focus when
        // the sheet has the keyboard for it; one while the sink lingers ends the linger.
        MouseArea {
            anchors.fill: parent
            onPressed: {
                if (root.lingering) {
                    root.sinkingKeys = false;
                    return;
                }
                const dialog = holder.item as AuthDialog;
                if (dialog && win.takesKeys && !root.sinkingKeys)
                    dialog.focusField();
            }
        }

        // A little above the middle and faded in, as the shell's centred alerts (Overlay.qml: panel.dialogRaise, motion.fast;
        // UI audit 2026-11-05 U22). Display only: the sheet takes its focus and keys at once whatever its opacity (opacity
        // stops no input, and no focus call waits for the fade).
        Loader {
            id: holder
            active: dialogModel.active
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -win.height * Tokens.panelDialogRaise
            opacity: item ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }

            sourceComponent: AuthDialog {
                model: dialogModel
                // The action's theme icon (sanitized by the model), only when the system theme has it (no broken image;
                // the host's lookup, review of 2dfd992).
                appIconSource: root.iconSource(dialogModel.iconName)
                heldNotice: root.heldByLock ? dialogModel.heldNotice(root.requestStartedAt, root.heldWhy) : ""
                inputEnabled: !root.sinkingKeys
                // The sheet got the focus while the sink has the keys (a press on one of its controls within the guard, its
                // own focusField, or its window activated with the sheet's scope focused): the sink takes it back. A focus
                // given while the window has no keyboard arrives here when the window gets it.
                onActiveFocusChanged: if (activeFocus && root.sinkingKeys)
                    keySink.forceActiveFocus()
            }
        }

        // The linger made visible (security counter-review of f9e24e1, LOW-3): while the window keeps the keyboard after a
        // request ended, a card where the sheet was says the request is gone and typing goes nowhere, so the user stops typing
        // and knows why keys do nothing for a moment (macOS removes the sheet at once; it has no linger to explain). Fixed
        // text, nothing of the requester's; no control and no focus: a press on it goes through to the backdrop, which ends
        // the linger, and the keys stay on the sink.
        Material {
            id: endedNotice
            objectName: "polkitEndedNotice"
            visible: root.lingering
            // Where the sheet was (holder).
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -win.height * Tokens.panelDialogRaise
            width: Tokens.panelDialogWidth
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
                    text: qsTr("Request cancelled")
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

        // A held request: the first click on the sheet (anywhere, the field included) gives it the keyboard, once
        // AuthDialogModel.heldGuardMs passed since it appeared; the press goes on to what is under it.
        MouseArea {
            anchors.fill: parent
            enabled: root.heldByLock && !root.userFocused
            onPressed: mouse => {
                mouse.accepted = false;
                if (!dialogModel.heldClickAccepted())
                    return;
                root.userFocused = true;
                root.sinkingKeys = false;
                const dialog = holder.item as AuthDialog;
                if (dialog)
                    dialog.focusField();
            }
        }

        // While the screen saver shows, a press (any button) or the wheel on the sheet goes nowhere: it is the input that wakes
        // the screen (the saver ends on it), never an answer, the field's focus or a middle-click paste into it.
        MouseArea {
            anchors.fill: parent
            enabled: SheetSession.saverShown
            acceptedButtons: Qt.AllButtons
            onPressed: mouse => mouse.accepted = true
            onWheel: wheel => wheel.accepted = true
        }
    }

    IpcHandler {
        target: "polkit"

        // Test hook (dev session only, else "refused"): "registered" | "unregistered". The real session's journal
        // has the same fact ("authentication agent registered").
        function status(): string {
            if (!RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION")))
                return RunMode.REFUSED;
            return agent.isRegistered ? "registered" : "unregistered";
        }
    }
}
