import QtQuick
import Grassfield.Ui
import "Prompter.js" as Prompter

// State of the secret sheet over one prompter/1 request (ADR-0035 D-9, step 9b; docs/specs/system-dialogs.md section 5):
// what the sheet shows and the holds of the polkit sheet's model (AuthDialogModel), the same rules and the same delays.
// Non-visual and free of Quickshell imports, so tests drive it without a socket (tests/security/tst_secretsheetmodel.qml).
//
// Never an answer of its own: the only ways out are submit() (the user's password or confirmation) and cancel(), each
// once per request; the agent sends the answer only for the request on screen (SecretAgent.respond).
//
// Who asks is the bridge's word, never the caller's (master-prompt R12): the sheet's title and its first row are
// Grassfield's own text built from `request.requester` (the role the bridge resolved from the caller's D-Bus credentials,
// and for an app the name of its desktop entry). The caller's own texts are shown under them, introduced as text sent by
// that program, in the secondary style, and for the programs that ask for others (Keyring, GnuPG, SSH: `onBehalf`) as
// another program's unverified text (spec SC3b). Its button labels are never shown (decision 9-16).
//
// A NetworkManager request (kind "nm", step 9c) is the macOS Wi-Fi alert: its title is Grassfield's sentence with the
// network's SSID as a quoted field ("The Wi-Fi network “%1” requires a WPA2 password."), under it who asked (NetworkManager),
// then the name field (enterprise), the password field, Show password, Cancel and Join. It has no caller text.
//
// A KIO request (kind "kio", step 9e) is the macOS server sheet: its title is Grassfield's sentence with the server as a quoted
// field ("Enter your name and password for the server “%1”."), a host name only (never free text, decision 9-42); under it
// who asked, from the bridge's requester (KIO's worker, an app, an unidentified program and its executable); the realm, the
// server's own words, framed as unverified text; the name field (editable, shown only, or absent), the password field,
// Remember this password (Grassfield's label) and, when the keyring that would keep it has no password, a line saying so
// (decision 9-45); Cancel and Connect. A retry after a failed login says so in Grassfield's words (the worker's message is
// never sent to the shell, decision 9-40).
//
// A BlueZ pairing step (kind "bluetooth", step 10) is macOS's "Connection Request from “Name”": the device's glyph, the title
// with the device's name as a quoted field (a remote device chooses its own name: never more than that field), its address
// under it, then Grassfield's sentence for the step: a field for a PIN or a passkey (Cancel / Connect), the code to compare
// (Cancel / Connect), the code to type on the device and how many digits were typed there (Cancel only), an incoming pairing
// or service to allow (Decline / Connect, the service named by its profile). No caller text.
QtObject {
    id: root

    // The request on screen or held (a parsed prompt, Prompter.parseBridgeLine, plus `waited` and `arrivedAt` from the
    // agent), or null.
    property var request: null

    readonly property bool active: !!request
    readonly property string id: request ? request.id : ""
    readonly property string kind: request ? request.kind : ""
    // NetworkManager's Wi-Fi secrets (step 9c).
    readonly property bool network: kind === "nm"
    // KIO's network passwords (step 9e).
    readonly property bool server: kind === "kio"
    // A BlueZ pairing step (step 10): its mode; a field for a PIN or a passkey (`asksCode`), a code shown on the screen to type
    // on the device (`displaysCode`: Cancel only), an incoming pairing or service to allow (`authorizes`: Decline / Connect).
    readonly property bool pairing: kind === "bluetooth"
    readonly property string pairingMode: pairing ? request.pairing.mode : ""
    readonly property bool asksCode: pairingMode === "pin" || pairingMode === "passkey"
    readonly property bool displaysCode: pairingMode === "display-pin" || pairingMode === "display-passkey"
    readonly property bool authorizes: pairingMode === "authorize" || pairingMode === "authorize-service"
    readonly property bool asksPassword: kind === "password" || network || server || asksCode
    readonly property bool passwordNew: asksPassword && request.passwordNew === true
    readonly property bool showsStrength: passwordNew && request.strength === true
    readonly property string role: request ? request.requester.role : ""
    readonly property bool onBehalf: !!request && request.requester.onBehalf === true

    // The requester row (only the bridge fills it): the name in Grassfield's words for the fixed roles, the desktop entry's
    // name for an app; the executable's path under it for an unidentified program.
    readonly property string requesterName: requesterNameOf(role, request ? request.requester.name : "")
    readonly property string requesterPath: role === "unidentified" && request ? Prompter.flatten(request.requester.path, Prompter.CAPS.path) : ""
    // The app's theme icon name (a plain name only, the notification icons' rule), "" otherwise: the sheet then draws the
    // role's glyph.
    readonly property string appIcon: role === "app" && request ? NotificationPrefs.safeIconName(request.requester.icon) : ""
    readonly property string glyph: role === "app" ? "apps" : role === "unidentified" ? "exclamationmark-triangle" : role === "network" ? "wifi-3" : role === "disk" ? "drive" : role === "kio" ? "globe" : role === "bluetooth" ? deviceGlyphOf(request.device.icon) : "key"
    // Who asked, under a NetworkManager request's title (the program the bridge checked the call came from) and a KIO
    // request's (the bridge's requester); "" otherwise.
    readonly property string requesterDetail: network ? qsTr("Requested by NetworkManager") : server ? serverRequesterOf(role, requesterName) : pairing ? qsTr("Bluetooth device %1").arg(deviceAddress) : ""

    // A KIO request's server (a host name and its port: a field of the title's sentence), its login: the name field's mode
    // ("edit", "fixed": shown only, "none": no name field), Remember this password ("none": not offered), the keyring's
    // protection, and whether the last name and password failed. The name typed (not a secret: the caller's name at
    // first); KIO's client takes it back from the reply, unlike NetworkManager (decision 9-33), so it is sent for "edit".
    readonly property string serverName: server ? request.server : ""
    readonly property string nameMode: server ? request.login.nameMode : ""
    readonly property bool asksName: server && nameMode !== "none"
    readonly property bool nameReadOnly: nameMode === "fixed"
    property string loginName: ""
    readonly property string keyringNotice: server && request.login.remember !== "none" && request.login.keyring === "unprotected" ? qsTr("Your keyring has no password: a password remembered here is stored unencrypted on this computer.") : ""

    // The network of an nm request: its SSID (plain, a field of the title's sentence), its security, and for WPA2 Enterprise
    // the connection's username, shown read-only: NetworkManager keeps only secrets from an agent's reply, so a name typed
    // here would be thrown away (opus review of step 9c, MAJOR; decision 9-33). Whether the password is shown as typed (Show
    // password; back to hidden for each request and whenever the fields are emptied).
    readonly property string networkSsid: network ? Prompter.flatten(request.network.ssid, Prompter.CAPS.ssid) : ""
    readonly property string networkSecurity: network ? request.network.security : ""
    readonly property bool showsIdentity: networkSecurity === "enterprise"
    readonly property string identity: showsIdentity ? Prompter.flatten(request.network.identity, Prompter.CAPS.identity) : ""
    property bool showPassword: false

    // The device of a pairing step: its name (plain, a field of the title's sentence), its address (the bridge's, from the
    // object path bluetoothd gave), the code to compare or to type on it, how many digits were typed there (a code shown:
    // SecretAgent.progress updates it), the service an incoming connection wants and its UUID when it has no name here.
    readonly property string deviceName: pairing ? Prompter.flatten(request.device.name, Prompter.CAPS.device) : ""
    readonly property string deviceAddress: pairing ? request.device.address : ""
    readonly property string pairingCode: pairingMode === "confirm" || displaysCode ? request.pairing.code : ""
    property int entered: 0
    readonly property string pairingMessage: pairing ? pairingMessageOf(pairingMode, request.pairing.service) : ""
    readonly property string pairingProgress: pairingMode === "display-passkey" ? qsTr("Digits typed on the device: %1 of %2").arg(root.entered).arg(Prompter.PASSKEY_DIGITS) : ""
    readonly property string serviceUuid: pairingMode === "authorize-service" && request.pairing.service === "other" ? request.pairing.uuid : ""

    // The sheet's own title, Grassfield's words: who asks, and for what.
    readonly property string title: server ? serverTitleOf(nameMode, serverName) : network ? networkTitleOf(networkSecurity, networkSsid) : pairing ? qsTr("Connection Request from “%1”").arg(deviceName) : titleOf(role, requesterName, kind, passwordNew)
    // The line that introduces the caller's text (spec SC3b): whose text it is.
    readonly property string callerIntro: server ? qsTr("The server describes this login as follows. It is not verified:") : callerIntroOf(role, requesterName)
    // The caller's own text: its title, message and description (plain lines, capped by the bridge and again here); for a
    // KIO request, its realm only.
    readonly property string callerTitle: server ? Prompter.flatten(request.login.realm, Prompter.CAPS.realm) : request ? Prompter.flatten(request.texts.title, Prompter.CAPS.title) : ""
    readonly property string callerMessage: request ? Prompter.flatten(request.texts.message, Prompter.CAPS.message) : ""
    readonly property string callerDescription: request ? Prompter.flatten(request.texts.description, Prompter.CAPS.description) : ""
    readonly property string callerWarning: request ? Prompter.flatten(request.texts.warning, Prompter.CAPS.warning) : ""
    readonly property bool hasCallerText: callerTitle !== "" || callerMessage !== "" || callerDescription !== "" || callerWarning !== ""
    // The check box (its label is the caller's text, attached to its control; a KIO request's Remember this password is
    // Grassfield's) and its state.
    readonly property bool hasChoice: server ? request.login.remember !== "none" : !!request && request.choice !== null
    readonly property string choiceLabel: !hasChoice ? "" : server ? qsTr("Remember this password") : Prompter.flatten(request.choice.label, Prompter.CAPS.choice)
    property bool choice: false
    // Our own message under the field (the passwords do not match, one is too long), else "".
    readonly property string error: priv.error
    // An answer to this request went out (the sheet then takes nothing more). Read from the request itself, never from a
    // flag a handler resets: bindings that follow `request` see a new request as unanswered whatever order they run in. The
    // key is its id and the agent's serial number (a bridge that restarts counts its ids from p1 again).
    readonly property bool answered: !!request && priv.answeredKey === keyOf(request)
    readonly property bool canSubmit: !!request && priv.answeredKey !== keyOf(request)

    // The same delays as the polkit sheet's (AuthDialogModel; tests/security/secret_sheets.sh checks they are equal).
    readonly property int heldGuardMs: 500
    readonly property int heldAfterUnlockMs: 1000
    readonly property int sinkLingerMaxMs: 3000
    // Timed by Timers (a monotonic clock), never by the wall clock.
    readonly property Timer unlockHold: Timer {
        interval: root.heldAfterUnlockMs
    }
    readonly property Timer clickGuard: Timer {
        interval: root.heldGuardMs
    }
    readonly property Timer afterRequest: Timer {
        interval: root.heldAfterUnlockMs
    }

    // The session was unlocked: requests shown in the next heldAfterUnlockMs are held.
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

    // The screen saver that covered a held sheet ended: a click counts only heldGuardMs from now.
    function noteUncovered(): void {
        clickGuard.restart();
    }

    // A sheet ended (this one, or the polkit sheet: SheetQueue.sheetEnded): one shown in the next heldAfterUnlockMs is held.
    function noteEnded(): void {
        afterRequest.restart();
    }

    function followsAnother(): bool {
        return afterRequest.running;
    }

    // Held when shown while the session is locked or the screen saver shows (`locked`), within heldAfterUnlockMs of the
    // last unlock or of the end of another sheet.
    function arrivesHeld(locked: bool): bool {
        return locked || unlockHold.running || afterRequest.running;
    }

    // What the held sheet says, with the time the request arrived. `why`: "locked", "saver", "starting" (the security process
    // had just started and had not seen the user active yet: SheetSession.starting), "waited" (another sheet was on screen
    // when it arrived), "queued" (right after another one), "confirm" (a confirmation: always held, decision 9-23) or
    // "unlock".
    function heldNotice(arrivedAt: var, why: string): string {
        const at = Qt.formatTime(new Date(arrivedAt), Qt.locale().timeFormat(Locale.ShortFormat));
        if (why === "locked")
            return qsTr("This request arrived at %1, while the screen was locked. Click the alert to answer it.").arg(at);
        if (why === "saver")
            return qsTr("This request arrived at %1 and waited while the screen saver was on. Click the alert to answer it.").arg(at);
        if (why === "starting")
            return qsTr("This request arrived at %1, while Grassfield was starting. Click the alert to answer it.").arg(at);
        if (why === "waited")
            return qsTr("This request arrived at %1, while another one was open. Click the alert to answer it.").arg(at);
        if (why === "queued")
            return qsTr("This request arrived at %1, right after another one. Click the alert to answer it.").arg(at);
        if (why === "confirm")
            return qsTr("This request arrived at %1. Click the alert to answer it: no key answers a confirmation before that.").arg(at);
        if (why === "network")
            return qsTr("This request arrived at %1. Click the alert to type the password: nothing typed elsewhere goes into it.").arg(at);
        if (why === "server")
            return qsTr("This request arrived at %1. Click the alert to type your name and password: nothing typed elsewhere goes into it.").arg(at);
        if (why === "pairing-code")
            return qsTr("This request arrived at %1. Click the alert to type the code: nothing typed elsewhere goes into it.").arg(at);
        if (why === "pairing-answer")
            return qsTr("This request arrived at %1. Click the alert to answer it: no key answers it before that.").arg(at);
        // A code shown has nothing to type in and no key to answer: no notice.
        if (why === "pairing-display")
            return "";
        return qsTr("This request arrived at %1, just as the screen was unlocked. Click the alert to answer it.").arg(at);
    }

    // Grassfield's names of the requesters the bridge resolves (prompter/1: the shell names them in its own words).
    function requesterNameOf(role: string, name: string): string {
        if (role === "app") {
            const n = Prompter.flatten(name, Prompter.CAPS.name);
            return n !== "" ? n : qsTr("Unidentified program");
        }
        if (role === "keyring")
            return qsTr("Keyring");
        if (role === "gnupg")
            return qsTr("GnuPG");
        if (role === "ssh")
            return qsTr("SSH");
        if (role === "disk")
            return qsTr("Disks");
        if (role === "network")
            return qsTr("Wi-Fi");
        if (role === "kio")
            return qsTr("KIO");
        if (role === "bluetooth")
            return qsTr("Bluetooth");
        return role === "" ? "" : qsTr("Unidentified program");
    }

    // Why a pairing step is held when nothing else holds it (decision 10-7): a code to type, a decision to make, or a code
    // shown (no notice: nothing to type in, nothing to answer but Cancel).
    function pairingHeldWhyOf(mode: string): string {
        if (mode === "pin" || mode === "passkey")
            return "pairing-code";
        if (mode === "display-pin" || mode === "display-passkey")
            return "pairing-display";
        return "pairing-answer";
    }

    // The device's glyph from the bridge's icon key (each key is a Grassfield glyph's name), else Bluetooth's.
    function deviceGlyphOf(icon: string): string {
        return Prompter.DEVICE_ICONS.indexOf(icon) > 0 ? icon : "bluetooth";
    }

    // Grassfield's sentence for a pairing step, under the title that names the device.
    function pairingMessageOf(mode: string, service: string): string {
        if (mode === "pin")
            return qsTr("Enter the device's PIN code.");
        if (mode === "passkey")
            return qsTr("Enter the code shown on the device.");
        if (mode === "display-pin" || mode === "display-passkey")
            return qsTr("Type this code on the device, then press Return on it.");
        if (mode === "confirm")
            return qsTr("Connect only if the device shows the same code.");
        if (mode === "authorize")
            return qsTr("The device wants to pair with this computer.");
        if (mode === "authorize-service")
            return qsTr("The device wants to use %1 on this computer.").arg(serviceLabelOf(service));
        return "";
    }

    // The profile an incoming connection wants, in Grassfield's words (the bridge's fixed keys, BtPairing.h serviceKey).
    function serviceLabelOf(key: string): string {
        if (key === "audio")
            return qsTr("audio streaming");
        if (key === "remote-control")
            return qsTr("media remote control");
        if (key === "headset")
            return qsTr("headset audio");
        if (key === "hands-free")
            return qsTr("hands-free calling");
        if (key === "file-transfer")
            return qsTr("file transfer");
        if (key === "object-push")
            return qsTr("sending files");
        if (key === "network")
            return qsTr("network sharing");
        if (key === "input")
            return qsTr("keyboard or mouse input");
        if (key === "phonebook")
            return qsTr("phonebook access");
        if (key === "messages")
            return qsTr("message access");
        if (key === "serial")
            return qsTr("a serial port");
        if (key === "dial-up")
            return qsTr("dial-up networking");
        return qsTr("a Bluetooth service");
    }

    // Connect may be pressed for a PIN or a passkey: read as a length, never as text (the form is checked when it is sent).
    function pairingReady(codeLength: int): bool {
        return asksCode && canSubmit && Prompter.pairingLengthOk(pairingMode, codeLength);
    }

    // The server sheet's sentence (macOS's): the server is a field inside Grassfield's words.
    function serverTitleOf(mode: string, name: string): string {
        if (mode === "none")
            return qsTr("Enter your password for the server “%1”.").arg(name);
        return qsTr("Enter your name and password for the server “%1”.").arg(name);
    }

    // Who asked a KIO request, in Grassfield's words from the bridge's requester: KIO's worker asks for an app (and any
    // program can make it ask), an app names itself, anything else is an unidentified program (its path under it).
    function serverRequesterOf(role: string, name: string): string {
        if (role === "kio")
            return qsTr("Requested by KIO for an app");
        if (role === "unidentified")
            return qsTr("Requested by an unidentified program");
        return qsTr("Requested by %1").arg(name);
    }

    // Connect may be pressed: a password (read as a length, never as text) and, when the sheet asks for one, a name.
    function serverReady(passwordLength: int, nameLength: int): bool {
        return server && canSubmit && passwordLength > 0 && (nameMode !== "edit" || nameLength > 0);
    }

    // The Wi-Fi alert's sentence (macOS's): the SSID is a field inside Grassfield's words, never the title itself.
    function networkTitleOf(security: string, ssid: string): string {
        if (security === "wpa3")
            return qsTr("The Wi-Fi network “%1” requires a WPA3 password.").arg(ssid);
        if (security === "wep")
            return qsTr("The Wi-Fi network “%1” requires a WEP password.").arg(ssid);
        if (security === "enterprise")
            return qsTr("The Wi-Fi network “%1” requires WPA2 enterprise credentials.").arg(ssid);
        return qsTr("The Wi-Fi network “%1” requires a WPA2 password.").arg(ssid);
    }

    // Join may be pressed: a password of an acceptable length for the network (read as a length, never as text).
    function networkReady(passwordLength: int): bool {
        return network && canSubmit && Prompter.networkLengthOk(networkSecurity, passwordLength);
    }

    function titleOf(role: string, name: string, kind: string, isNew: bool): string {
        if (role === "")
            return "";
        if (role === "unidentified")
            return kind === "confirm" ? qsTr("An unidentified program asks you to confirm") : isNew ? qsTr("An unidentified program asks for a new password") : qsTr("An unidentified program asks for a password");
        if (kind === "confirm")
            return qsTr("%1 asks you to confirm").arg(name);
        return isNew ? qsTr("%1 asks for a new password").arg(name) : qsTr("%1 asks for a password").arg(name);
    }

    function callerIntroOf(role: string, name: string): string {
        // A network request and a pairing step carry no caller text at all.
        if (role === "" || role === "network" || role === "bluetooth")
            return "";
        if (role === "keyring" || role === "gnupg" || role === "ssh" || role === "disk" || role === "kio")
            return qsTr("Another program sent this message through %1. It is not verified:").arg(name);
        if (role === "app")
            return qsTr("%1 sent this message:").arg(name);
        return qsTr("The program sent this message. It is not verified:");
    }

    // What tells one request from another: its id and the serial number the agent gave it when it arrived.
    function keyOf(r: var): string {
        return r ? r.id + "#" + r.serial : "";
    }

    // The strength meter of a new password, from its length only (decision 9-17: the meter never reads the password itself,
    // so no copy of it is made for the meter): 0 empty, 1 weak (under 8), 2 fair (under 12), 3 strong.
    function strengthOf(length: int): int {
        return length <= 0 ? 0 : length < 8 ? 1 : length < 12 ? 2 : 3;
    }

    // The dialog must empty its fields (after every attempt and outcome).
    signal clearRequested
    // An answer for the agent to send (SecretAgent.respond): `ok`, the password for a password or nm request answered ok,
    // the check box's state, the name for an enterprise network (else null). The agent calls noteAnswered when it sent it (a
    // cancellation or a confirmation gives the keyboard back at once; a password sent keeps it on the agent's key sink a
    // moment: its caller often asks again at once).
    signal answerRequested(bool ok, var password, bool choice, var identity)

    component Private: QtObject {
        property string answeredKey: ""
        property bool shown: false
        property string error: ""
    }

    readonly property Private priv: Private {}

    // The user's password (a password request; for a new password, `verify` is the second field: both must be equal) or
    // confirmation (a confirm request: password null). True when the answer went out.
    function submit(password: var, verify: var): bool {
        if (!canSubmit) {
            clearRequested();
            return false;
        }
        if (pairing) {
            // A code shown is only ever cancelled (decision 10-6).
            if (displaysCode) {
                clearRequested();
                return false;
            }
            if (asksCode && !Prompter.pairingCodeOk(pairingMode, password)) {
                priv.error = pairingMode === "pin" ? qsTr("A PIN has 1 to 16 letters or digits.") : qsTr("Type the 6 digits of the code.");
                clearRequested();
                return false;
            }
        }
        if (server) {
            if (typeof password !== "string" || password.length === 0) {
                clearRequested();
                return false;
            }
            if (Prompter.utf8Length(password) > Prompter.MAX_PASSWORD_BYTES) {
                priv.error = qsTr("This password is too long.");
                clearRequested();
                return false;
            }
            if (nameMode === "edit" && root.loginName === "") {
                priv.error = qsTr("Type your name.");
                clearRequested();
                return false;
            }
        }
        if (network) {
            if (typeof password !== "string" || password.length === 0) {
                clearRequested();
                return false;
            }
            if (!Prompter.networkLengthOk(networkSecurity, password.length)) {
                priv.error = qsTr("A WPA2 password has 8 to 63 characters, or 64 hexadecimal digits.");
                clearRequested();
                return false;
            }
            if (Prompter.utf8Length(password) > Prompter.MAX_PASSWORD_BYTES) {
                priv.error = qsTr("This password is too long.");
                clearRequested();
                return false;
            }
        }
        if (asksPassword && !network && !server) {
            if (typeof password !== "string" || (password.length === 0 && !passwordNew)) {
                clearRequested();
                return false;
            }
            if (passwordNew && password !== verify) {
                priv.error = qsTr("The passwords do not match. Type the new password again in both fields.");
                clearRequested();
                return false;
            }
            if (Prompter.utf8Length(password) > Prompter.MAX_PASSWORD_BYTES) {
                priv.error = qsTr("This password is too long.");
                clearRequested();
                return false;
            }
        }
        priv.error = "";
        root.answerRequested(true, asksPassword ? password : null, root.choice, nameMode === "edit" ? root.loginName : null);
        clearRequested();
        return answered;
    }

    function cancel(): void {
        clearRequested();
        if (canSubmit)
            root.answerRequested(false, null, root.choice, null);
    }

    // The agent sent the answer: nothing more is taken for this request.
    function noteAnswered(): void {
        if (request)
            priv.answeredKey = keyOf(request);
    }

    // Whenever the fields are emptied (an attempt, a hold, the lock, the screen saver), the password is hidden again.
    onClearRequested: root.showPassword = false

    // A new request (or none): nothing typed or chosen carries over.
    onRequestChanged: {
        // A KIO request after a failed login says so in Grassfield's words (decision 9-40).
        priv.error = request && request.kind === "kio" && request.login.retry === true ? qsTr("The name or password was not accepted. Try again.") : "";
        if (request)
            root.choice = request.kind === "kio" ? request.login.remember === "on" : request.choice !== null && request.choice.chosen === true;
        root.loginName = request && request.kind === "kio" ? request.login.name : "";
        root.entered = request && request.kind === "bluetooth" ? request.pairing.entered : 0;
        clearRequested();
    }
}
