import QtQuick
import Grassfield.Ui

// State of the authorization dialog over one polkit AuthFlow (Quickshell.Services.Polkit).
// Non-visual and free of Quickshell imports so tests drive it with a mock flow
// (tests/security/tst_authdialogmodel.qml). Grassfield.Ui gives it the shared icon name rule (pure JS).
//
// Never auto-approve: the only call that answers polkit is submit(), and only with a non-empty
// password typed by the user while polkit asks for a response. Nothing here calls submit() on
// its own, and cancel() is always available. The one answer given on its own is a refusal: a
// request the user cannot answer is cancelled as soon as PAM talks without asking (refusesUnseen).
QtObject {
    id: root

    // The active AuthFlow, or null. Properties used: message, actionId, iconName (sanitized), identities,
    // selectedIdentity, isResponseRequired, inputPrompt, responseVisible, supplementaryMessage,
    // supplementaryIsError; methods submit(string), cancelAuthenticationRequest().
    property var flow: null

    // Length caps of the requester/polkit strings once flattened to one line (the dialog also caps
    // their rendered lines): a long or multi-line message cannot push the action ID and the buttons
    // away, nor draw a fake "Action:" line of its own.
    readonly property int maxMessageLength: 400
    readonly property int maxDetailLength: 200

    // Every binding tests `flow` itself: the flow object can disappear between two updates.
    readonly property bool active: !!flow
    // Grassfield Store's request (ADR-0037 b.1, SD2), {verb: "install" | "remove", packages: [names]}, else null: the message
    // says it in plain words ("Install …", "Remove …") and the sheet adds the program's path under the action ID.
    readonly property var storeRequest: flow ? storeRequestOf(flow.actionId, flow.message) : null
    readonly property string message: storeRequest ? storeMessage(storeRequest) : flow ? plainLine(flow.message, maxMessageLength) : ""
    readonly property string actionId: flow ? plainLine(flow.actionId, maxDetailLength) : ""
    // The program polkit will run, when the request names it in a form this sheet reads (Grassfield Store's helper), else "".
    readonly property string program: storeRequest ? storeHelper : ""
    // The action's theme icon (polkit `icon_name` of the root-installed .policy file, AuthFlow.iconName), shown with a lock
    // badge (D-4: macOS shows an icon for the request). It describes the action, not the program that asked: Quickshell
    // 0.3.1's AuthFlow exposes no subject, process or command line; the message (pkexec names the program there), the
    // action ID and this icon are all it offers. Only a plain theme icon name is accepted, by the one rule the notification
    // icons use (NotificationPrefs.safeIconName: no path, URL, leading "." or ".."; review of 2dfd992), else "".
    readonly property string iconName: flow ? NotificationPrefs.safeIconName(flow.iconName) : ""
    readonly property var identities: flow && flow.identities ? flow.identities : []
    readonly property var selectedIdentity: flow ? flow.selectedIdentity : null
    readonly property string identityName: identityLabel(selectedIdentity)
    readonly property bool responseRequired: !!flow && flow.isResponseRequired === true
    readonly property bool responseVisible: !!flow && flow.responseVisible === true
    readonly property string prompt: flow ? cleanPrompt(plainLine(flow.inputPrompt, maxDetailLength)) : ""
    // Polkit/PAM feedback, or our own message after a failed attempt. While a device is awaited (awaitingDevice) the line is
    // PAM's own (the device's instruction, or pam_faillock's notice), never the previous round's "Incorrect password": the
    // intro says to follow the instruction below (counter-review of ADR-0045, LOW-2). Once a prompt comes, our own message
    // comes back whenever a failure set it (priv.error is cleared only by submit, cancel or a new flow): a PAM notice that
    // came after the failure (pam_faillock's "account is locked", only from a stack whose preauth is not silent: Omarchy's
    // is) is then replaced by it. Open item, final counter-review LOW-A (see docs/specs/security.md).
    readonly property string feedback: awaitingDevice ? plainLine(flow.supplementaryMessage, maxDetailLength)
                                                      : priv.error !== "" ? priv.error : (flow ? plainLine(flow.supplementaryMessage, maxDetailLength) : "")
    readonly property bool feedbackIsError: awaitingDevice ? flow.supplementaryIsError === true
                                                           : priv.error !== "" || (!!flow && flow.supplementaryIsError === true)
    // An answer was sent and polkit has not asked again yet.
    readonly property bool submitted: priv.submitted
    readonly property bool canSubmit: responseRequired && !priv.submitted
    // PAM said something and asks nothing (ADR-0045 OC-6: pam_fprintd's "Place your finger…", pam_u2f's "Please touch the FIDO
    // authenticator."): a device is awaited, the password field waits. Only while a message is shown, never for a bare
    // !responseRequired: between two prompts, or before pam_unix's first, a fast typist's first keys must not be dropped (a
    // password typed short is a wrong one, and pam_faillock counts it).
    readonly property bool awaitingDevice: !!flow && !responseRequired && !priv.submitted && plainLine(flow.supplementaryMessage, maxDetailLength) !== ""

    // No device answers a request the user cannot see and answer (ADR-0045 OC-6, security review of e3542510, MAJOR-2; macOS:
    // a request made while locked is shown after the unlock, never answered by the unlock gesture). Quickshell starts PAM the
    // moment polkit asks, whether or not a sheet shows the request: AuthFlow's constructor runs polkit-agent-helper-1 (0.3.2
    // flow.cpp setupSession, polkit_agent_session_initiate), again after each failure, and its API has nothing to defer or
    // pause it. With pam_fprintd or pam_u2f in /etc/pam.d/polkit-1, a request held behind the lock, the screen saver or
    // another sheet would hold the reader, and a touch meant for the lock screen (or for the request before) would approve
    // it. So `request`, the flow Quickshell has open (the agent's own, also while this model is handed none: a secret sheet
    // came first), is refused (polkit's "cancelled": the requester is told no) as soon as PAM says something without asking
    // (pamTalks: a device's instruction, or any other line: when in doubt, no), whenever `answerable` is false (the agent's
    // rule: its sheet is not on screen in front: locked, under the screen saver, the displays off, waiting behind another
    // sheet, or held other than "right after another one" and not clicked), an answer sent or not. PAM asking for a password
    // ends nothing: that request waits for the user, its sheet after the unlock. It assumes a device module announces itself
    // before it waits (pam_fprintd always, pam_u2f with `cue`, which Omarchy sets); a silent one would defeat it.
    // Defaults fail closed (not answerable); with no request nothing happens. The cancel runs from the event loop, never inside
    // this binding's own change: Quickshell ends the request inside cancelAuthenticationRequest, which changes what the binding
    // reads, and QML would report a binding loop and keep a stale value (the next request then unguarded; authagent_flows.d
    // flows.qml test_27). It runs as soon as control returns to the event loop (Qt.callLater), within the same turn.
    property var request: null
    property bool answerable: false
    readonly property bool refusesUnseen: !answerable && pamTalks(request)
    onRefusesUnseenChanged: if (refusesUnseen)
        Qt.callLater(root.refuseUnseen)

    // Still unanswerable and PAM still talking when the event loop gets here: refused.
    function refuseUnseen(): void {
        if (refusesUnseen)
            request.cancelAuthenticationRequest();
    }

    // Replaced requests (opus re-review of the ADR-0045 security fixes, MAJOR-1). Quickshell 0.3.2 replaces an open request
    // instead of queuing it (agentimpl.cpp initiateAuthentication activates a new one while another is active) and leaves the
    // replaced one running, its PAM included, with no sheet: a device could answer it unseen, for up to pam_fprintd's 30 s,
    // and keep the lock screen's own fingerprint check from the reader. Every request replaced before it completed is watched
    // (`priv.replaced`); as soon as one of them talks without asking (at once if it already did), the request Quickshell has
    // open is refused first, then every replaced one: refusing a replaced one ends whatever request is current (its
    // completion is still connected to agentimpl's finishAuthenticationRequest), which would leave the current one unanswered.
    // A replaced request asking for a password is left as Quickshell leaves it (nobody can type into it). From the event loop,
    // as above.
    readonly property bool replacedTalks: liveReplaced().some(f => pamTalks(f))
    onReplacedTalksChanged: if (replacedTalks)
        Qt.callLater(root.refuseReplaced)
    onRequestChanged: {
        const before = priv.seen;
        priv.seen = request;
        if (before && request && before !== request && before.isCompleted !== true)
            priv.replaced = liveReplaced().concat([before]);
    }

    // The replaced requests still running (a destroyed flow reads null).
    function liveReplaced(): var {
        return priv.replaced.filter(f => !!f && f.isCompleted !== true);
    }

    function refuseReplaced(): void {
        if (!replacedTalks)
            return;
        const replaced = liveReplaced();
        priv.replaced = [];
        if (request && request.isCompleted !== true && replaced.indexOf(request) < 0)
            request.cancelAuthenticationRequest();
        for (const f of replaced)
            f.cancelAuthenticationRequest();
    }

    // PAM said something and asks nothing (Quickshell keeps the last line until another one comes).
    function pamTalks(f: var): bool {
        return !!f && f.isResponseRequired !== true && plainLine(f.supplementaryMessage, maxDetailLength) !== "";
    }

    // The user answered the request in the sheet (sent a password or cancelled it) and polkit has not asked again since: a
    // request that ends now ends on the user's answer, not under the user's typing (AuthAgent lingers only for the latter;
    // security counter-review of f9e24e1, LOW-1). Set by submit() and cancel(), cleared when polkit asks again (a failure, a
    // new prompt) and when another request comes; never when the request ends, so it still reads true when the agent asks.
    readonly property bool answered: priv.answered

    // A request held behind the lock (review of 1d2c856, macOS model: the authorization sheet appears once the user is
    // back, and nothing typed before the user turns to it reaches it). After the unlock the sheet is shown WITHOUT the
    // keyboard: keys typed right after the unlock (the end of the lock password, a Return) cannot land in its field. It
    // takes the keyboard only after a click on the sheet, and a click counts only heldGuardMs after the sheet appeared.
    readonly property int heldGuardMs: 500
    // A request that arrives this soon after an unlock is held too (review of d8e654c): keys typed right after the unlock
    // must not land in a sheet that appeared a moment later.
    readonly property int heldAfterUnlockMs: 1000
    // Both delays are timed by Timers (a monotonic clock), never by Date.now() (review of 6e24d36: a wall-clock step back
    // would hold a request for hours, a step forward would end the hold at once).
    readonly property Timer unlockHold: Timer {
        interval: root.heldAfterUnlockMs
    }
    readonly property Timer clickGuard: Timer {
        interval: root.heldGuardMs
    }
    // A request that arrives this soon after the previous one ended is held too (re-check of b5d7657, MEDIUM-1: `pkexec a;
    // pkexec b` passes through no request between the two): keys typed after answering the first, or a password typed
    // again, must not land in the next one's field.
    readonly property Timer afterRequest: Timer {
        interval: root.heldAfterUnlockMs
    }
    // The longest the agent keeps the keyboard on its key sink after a request ended while the user typed (AuthAgent
    // `lingering`): their keys go nowhere meanwhile, then to the window underneath again.
    readonly property int sinkLingerMaxMs: 3000

    // The session was unlocked: requests arriving in the next heldAfterUnlockMs are held.
    function noteUnlock(): void {
        unlockHold.restart();
    }

    // The sheet appeared: a click counts only heldGuardMs from now.
    function noteShown(): void {
        priv.shown = true;
        clickGuard.restart();
    }

    // When in doubt, no: a click before the sheet was ever noted as shown does not count either.
    function heldClickAccepted(): bool {
        return priv.shown && !clickGuard.running;
    }

    // The screen saver that covered a held sheet ended: a click counts only heldGuardMs from now, so the click that woke the
    // screen never answers the sheet (ADR-0032).
    function noteUncovered(): void {
        clickGuard.restart();
    }

    // The request in the sheet ended (answered, cancelled or replaced by none): one arriving in the next heldAfterUnlockMs is
    // held.
    function noteEnded(): void {
        afterRequest.restart();
    }

    // Whether a request arriving now comes right after another one ended.
    function followsAnother(): bool {
        return afterRequest.running;
    }

    // A request is held when it arrives while the session is locked or the screen saver shows (`locked`), within
    // heldAfterUnlockMs of the last unlock, or within as long after the previous request ended.
    function arrivesHeld(locked: bool): bool {
        return locked || unlockHold.running || afterRequest.running;
    }

    // What the held sheet says, with the time the request arrived (the message names the program for pkexec).
    // `arrivedAt`: a Date (or milliseconds), only formatted. `why`: "locked", "saver" (the screen saver showed), "starting"
    // (the security process had just started and had not seen the user active yet: SheetSession.starting), "queued" (it
    // followed another request in the same sheet) or "unlock".
    function heldNotice(arrivedAt: var, why: string): string {
        const at = Qt.formatTime(new Date(arrivedAt), Qt.locale().timeFormat(Locale.ShortFormat));
        if (why === "locked")
            return qsTr("This request arrived at %1, while the screen was locked. Click the sheet to answer it.").arg(at);
        if (why === "saver")
            return qsTr("This request arrived at %1 and waited while the screen saver was on. Click the sheet to answer it.").arg(at);
        if (why === "starting")
            return qsTr("This request arrived at %1, while Grassfield was starting. Click the sheet to answer it.").arg(at);
        if (why === "queued")
            return qsTr("This request arrived at %1, right after another one. Click the sheet to answer it.").arg(at);
        return qsTr("This request arrived at %1, just as the screen was unlocked. Click the sheet to answer it.").arg(at);
    }

    // The dialog must empty its password field (after every attempt and outcome).
    signal clearRequested
    // A wrong password: shake.
    signal failed

    component Private: QtObject {
        property bool submitted: false
        property string error: ""
        property bool shown: false
        property bool answered: false
        // The request last seen and the replaced ones still watched (refuseReplaced).
        property var seen: null
        property var replaced: []
    }

    readonly property Private priv: Private {}

    function identityLabel(identity: var): string {
        if (!identity)
            return "";
        return plainLine(identity.displayName || identity.string, maxDetailLength);
    }

    // Untrusted text as one plain line: C0/C1 control characters (newlines, tabs, escapes) and
    // line/paragraph separators become spaces, bidirectional overrides/isolates and marks are
    // removed (no reordered or spoofed text), whitespace runs collapse, and the result is capped
    // at maxLength characters with an ellipsis.
    function plainLine(text: var, maxLength: int): string {
        let t = String(text === undefined || text === null ? "" : text);
        t = t.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ");
        t = t.replace(/[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "");
        t = t.replace(/\s+/g, " ").trim();
        if (maxLength > 0 && t.length > maxLength)
            t = t.slice(0, maxLength - 1).trim() + "\u2026";
        return t;
    }

    // Grassfield Store's action (ADR-0037 b.1, SD2). Its policy's message ends with $(command_line), which polkitd expands
    // with the helper's argument vector as pkexec reports it, so the package names come from polkit, not from the program
    // that asked. Read only for this action id, and only when the whole message is one of the policy's two messages
    // (English, French) followed by the helper's path, install or remove, an operation id and 1 to 64 package names of
    // ADR-0037 e.5: anything else (another language, a character more) is shown as polkit gives it.
    readonly property string storeActionId: "org.grassfield.store.manage-packages"
    readonly property string storeHelper: "/usr/lib/grassfield/grassfield-store-helper"
    readonly property var storePattern: /^(?:Authentication is required to install or remove apps:|Une authentification est nécessaire pour installer ou supprimer des apps :) \/usr\/lib\/grassfield\/grassfield-store-helper (install|remove) [0-9a-f]{32}((?: [a-z0-9@_+][a-z0-9@._+-]{0,127}){1,64})$/

    function storeRequestOf(actionId: var, message: var): var {
        if (actionId !== root.storeActionId || typeof message !== "string")
            return null;
        const m = root.storePattern.exec(message);
        if (!m)
            return null;
        return {verb: m[1], packages: m[2].slice(1).split(" ")};
    }

    function storeMessage(request: var): string {
        const names = request.packages.join(", ");
        return request.verb === "install" ? qsTr("Install %1").arg(names) : qsTr("Remove %1").arg(names);
    }

    // "Password: " → "Password"
    function cleanPrompt(text: string): string {
        return text.replace(/[:\s]+$/, "");
    }

    function submit(password: string): bool {
        if (!active || !canSubmit || password.length === 0) {
            clearRequested();
            return false;
        }
        priv.submitted = true;
        priv.answered = true;
        priv.error = "";
        clearRequested();
        flow.submit(password);
        return true;
    }

    function cancel(): void {
        clearRequested();
        priv.submitted = false;
        priv.answered = true;
        priv.error = "";
        if (active)
            flow.cancelAuthenticationRequest();
    }

    function selectIdentity(identity: var): void {
        if (active && identity && !priv.submitted)
            flow.selectedIdentity = identity;
    }

    // `answered` is cleared only for a new request, never when the flow goes (the agent reads it at the end, in whichever order
    // the end reaches this handler and the agent).
    onFlowChanged: {
        priv.submitted = false;
        priv.error = "";
        if (flow)
            priv.answered = false;
        clearRequested();
    }

    readonly property Connections flowConnections: Connections {
        target: root.flow ? root.flow : null
        ignoreUnknownSignals: true

        function onIsResponseRequiredChanged(): void {
            if (root.flow && root.flow.isResponseRequired) {
                root.priv.submitted = false;
                root.priv.answered = false;
            }
        }

        function onAuthenticationFailed(): void {
            root.priv.submitted = false;
            root.priv.answered = false;
            root.priv.error = qsTr("Incorrect password. Try again.");
            root.clearRequested();
            root.failed();
        }

        function onAuthenticationSucceeded(): void {
            root.priv.submitted = false;
            root.clearRequested();
        }

        function onAuthenticationRequestCancelled(): void {
            root.priv.submitted = false;
            root.clearRequested();
        }
    }
}
