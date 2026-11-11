import QtQuick
import QtTest
import "../../shell/security/secret"

// The secret sheet's model (shell/security/secret/SecretSheetModel.qml; ADR-0035 D-9, step 9b): who asks is the bridge's
// requester in Grassfield's words, never the caller's text (master-prompt R12, spec SC3, SC3b); the answers it hands to the
// agent (once, never an empty unlock password, a new password typed twice alike); the holds of the polkit sheet; step 9c:
// the Wi-Fi alert of a NetworkManager request (its sentence, who asked, Join's length rule, the name, Show password) and the
// disk role of grassfield-askpass; step 9e: the server sheet of a KIO request (its sentence, who asked, the realm framed as
// unverified, the name field's modes, Remember this password and the keyring's line, retry, Connect's rule); step 10: a BlueZ
// pairing step (macOS's connection request: the device's name as a field, its address, each mode's sentence and code, the
// digits typed on the device, Connect's rule and the code's form, a code shown never answered ok, the hold reasons).
TestCase {
    id: test
    name: "SecretSheetModel"

    Component {
        id: modelC
        SecretSheetModel {}
    }

    property int serial: 0

    function request(over) {
        test.serial++;
        const r = {
            id: "p7",
            serial: test.serial,
            kind: "password",
            requester: {role: "keyring", name: "", desktopId: "", icon: "", path: "/usr/bin/gnome-keyring-daemon", identified: true, onBehalf: true},
            texts: {title: "Authentication required", message: "Unlock the login keyring", description: "", warning: "", continueLabel: "Allow", cancelLabel: "Deny"},
            choice: null,
            passwordNew: false,
            strength: false,
            waited: false,
            arrivedAt: new Date()
        };
        return Object.assign(r, over || {});
    }

    // An answering agent: records what the model hands it and notes it as sent.
    function wired(m) {
        const sent = [];
        m.answerRequested.connect((ok, password, choice, identity) => {
            const one = {ok: ok, password: password, choice: choice};
            if (identity !== null && identity !== undefined)
                one.identity = identity;
            sent.push(one);
            m.noteAnswered();
        });
        return sent;
    }

    function test_requesterInGrassfieldWords_data() {
        return [
            {tag: "keyring", req: {role: "keyring", name: "", identified: true, onBehalf: true}, name: "Keyring", glyph: "key", intro: "Another program sent this message through Keyring. It is not verified:"},
            {tag: "gnupg", req: {role: "gnupg", name: "", identified: true, onBehalf: true}, name: "GnuPG", glyph: "key", intro: "Another program sent this message through GnuPG. It is not verified:"},
            {tag: "ssh", req: {role: "ssh", name: "", identified: true, onBehalf: true}, name: "SSH", glyph: "key", intro: "Another program sent this message through SSH. It is not verified:"},
            {tag: "disk", req: {role: "disk", name: "", identified: true, onBehalf: true}, name: "Disks", glyph: "drive", intro: "Another program sent this message through Disks. It is not verified:"},
            {tag: "app", req: {role: "app", name: "Firefox", icon: "firefox", identified: true, onBehalf: false}, name: "Firefox", glyph: "apps", intro: "Firefox sent this message:"},
            {tag: "unidentified", req: {role: "unidentified", name: "", path: "/home/u/evil", identified: false, onBehalf: false}, name: "Unidentified program", glyph: "exclamationmark-triangle", intro: "The program sent this message. It is not verified:"}
        ];
    }
    function test_requesterInGrassfieldWords(d) {
        const m = createTemporaryObject(modelC, test, {request: request({requester: Object.assign({desktopId: "", icon: "", path: "/usr/bin/x"}, d.req)})});
        compare(m.requesterName, d.name);
        compare(m.glyph, d.glyph);
        compare(m.callerIntro, d.intro);
        verify(m.title.indexOf("Authentication required") < 0, "the caller's title is never the sheet's");
        verify(m.title.indexOf(d.tag === "unidentified" ? "unidentified program" : d.name) >= 0, m.title);
        compare(m.callerTitle, "Authentication required", "the caller's title is shown as the caller's text");
        compare(m.requesterPath, d.tag === "unidentified" ? "/home/u/evil" : "");
        compare(m.appIcon, d.tag === "app" ? "firefox" : "");
    }

    function test_titles() {
        const m = createTemporaryObject(modelC, test, {request: request()});
        compare(m.title, "Keyring asks for a password");
        m.request = request({kind: "confirm"});
        compare(m.title, "Keyring asks you to confirm");
        m.request = request({passwordNew: true, strength: true});
        compare(m.title, "Keyring asks for a new password");
        verify(m.showsStrength);
    }

    function test_iconNameIsPlain() {
        const m = createTemporaryObject(modelC, test, {request: request({requester: {role: "app", name: "X", desktopId: "x.desktop", icon: "/home/u/fake-lock.png", path: "/usr/bin/x", identified: true, onBehalf: false}})});
        compare(m.appIcon, "", "a path is never an icon name: the glyph shows");
    }

    function test_unlockAnsweredOnce() {
        const m = createTemporaryObject(modelC, test, {request: request()});
        const sent = wired(m);
        verify(!m.submit("", null), "an empty unlock password is not sent");
        compare(sent.length, 0);
        verify(m.submit("pw", null));
        compare(sent, [{ok: true, password: "pw", choice: false}]);
        verify(m.answered);
        verify(!m.canSubmit);
        verify(!m.submit("pw2", null), "never a second answer");
        m.cancel();
        compare(sent.length, 1, "nor a cancellation after it");
    }

    function test_cancelGivesKeysBack() {
        const m = createTemporaryObject(modelC, test, {request: request()});
        const sent = wired(m);
        let cleared = 0;
        m.clearRequested.connect(() => cleared++);
        m.cancel();
        compare(sent, [{ok: false, password: null, choice: false}]);
        verify(m.answered);
        verify(cleared > 0, "the field is emptied");
    }

    function test_confirmation() {
        const m = createTemporaryObject(modelC, test, {request: request({kind: "confirm", choice: {label: "Always", chosen: true}})});
        const sent = wired(m);
        compare(m.choice, true, "the check box starts as the caller set it");
        m.choice = false;
        verify(m.submit(null, null));
        compare(sent, [{ok: true, password: null, choice: false}]);
    }

    function test_newPassword() {
        const m = createTemporaryObject(modelC, test, {request: request({passwordNew: true, strength: true})});
        const sent = wired(m);
        verify(!m.submit("abc", "abd"), "two different passwords");
        verify(m.error !== "");
        compare(sent.length, 0);
        verify(m.submit("", ""), "an empty new password is a choice (gcr then offers unencrypted storage)");
        compare(sent, [{ok: true, password: "", choice: false}]);
        compare(m.error, "");
    }

    function test_tooLong() {
        const m = createTemporaryObject(modelC, test, {request: request()});
        const sent = wired(m);
        verify(!m.submit("x".repeat(4097), null));
        compare(sent.length, 0);
        verify(m.error !== "");
        verify(!m.answered, "still open: it can be typed again");
    }

    function test_refusedByTheAgent() {
        const m = createTemporaryObject(modelC, test, {request: request()});
        m.answerRequested.connect(() => {}); // the agent refused (not on screen): no noteAnswered
        verify(!m.submit("pw", null));
        verify(!m.answered);
    }

    function test_newRequestStartsFresh() {
        const m = createTemporaryObject(modelC, test, {request: request()});
        wired(m);
        m.submit("pw", null);
        m.request = request({id: "p7", choice: {label: "x", chosen: true}});
        verify(!m.answered && m.canSubmit && m.error === "", "a new request is unanswered at once, even with the same id (a restarted bridge)");
        compare(m.choice, true);
    }

    function test_strength() {
        const m = createTemporaryObject(modelC, test);
        compare(m.strengthOf(0), 0);
        compare(m.strengthOf(7), 1);
        compare(m.strengthOf(8), 2);
        compare(m.strengthOf(11), 2);
        compare(m.strengthOf(12), 3);
    }

    // The polkit sheet's holds, the same delays (AuthDialogModel).
    function test_holds() {
        const m = createTemporaryObject(modelC, test);
        compare([m.heldGuardMs, m.heldAfterUnlockMs, m.sinkLingerMaxMs], [500, 1000, 3000]);
        verify(!m.heldClickAccepted(), "never shown: no click counts");
        m.noteShown();
        verify(!m.heldClickAccepted(), "within the guard");
        wait(600);
        verify(m.heldClickAccepted());
        m.noteUncovered();
        verify(!m.heldClickAccepted(), "the saver ended: the guard starts over");
        verify(!m.arrivesHeld(false));
        verify(m.arrivesHeld(true), "locked or under the saver");
        m.noteUnlock();
        verify(m.arrivesHeld(false), "right after an unlock");
        wait(1100);
        verify(!m.arrivesHeld(false));
        m.noteEnded();
        verify(m.followsAnother() && m.arrivesHeld(false), "right after another sheet");
    }

    function test_heldNotice() {
        const m = createTemporaryObject(modelC, test);
        verify(m.heldNotice(new Date(), "waited").indexOf("while another one was open") >= 0);
        verify(m.heldNotice(new Date(), "locked").indexOf("locked") >= 0);
        verify(m.heldNotice(new Date(), "confirm").indexOf("no key answers a confirmation") >= 0);
        verify(m.heldNotice(new Date(), "network").indexOf("nothing typed elsewhere goes into it") >= 0);
        // The opus delta review of S3, LOW: held for the security process's start alone, it says so, not the saver.
        verify(m.heldNotice(new Date(), "saver").indexOf("while the screen saver was on") >= 0);
        const starting = m.heldNotice(new Date(), "starting");
        verify(starting.indexOf("while Grassfield was starting. Click the alert to answer it.") >= 0, starting);
        verify(starting.indexOf("screen saver") < 0, starting);
    }

    // --- step 9c: NetworkManager's Wi-Fi alert ------------------------------------------------------------------------

    function network(security, identity, ssid) {
        return request({kind: "nm", requester: {role: "network", name: "", desktopId: "", icon: "", path: "", identified: true, onBehalf: false},
                        texts: {title: "", message: "", description: "", warning: "", continueLabel: "", cancelLabel: ""},
                        network: {ssid: ssid === undefined ? "Home" : ssid, security: security, identity: identity || ""}});
    }

    function test_networkAlert_data() {
        return [
            {tag: "wpa", title: "The Wi-Fi network “Home” requires a WPA2 password."},
            {tag: "wpa3", title: "The Wi-Fi network “Home” requires a WPA3 password."},
            {tag: "wep", title: "The Wi-Fi network “Home” requires a WEP password."},
            {tag: "enterprise", title: "The Wi-Fi network “Home” requires WPA2 enterprise credentials."}
        ];
    }
    function test_networkAlert(d) {
        const m = createTemporaryObject(modelC, test, {request: network(d.tag)});
        verify(m.network);
        verify(m.asksPassword);
        compare(m.title, d.title);
        compare(m.requesterName, "Wi-Fi");
        compare(m.requesterDetail, "Requested by NetworkManager");
        compare(m.glyph, "wifi-3");
        verify(!m.hasCallerText, "no caller text");
        compare(m.callerIntro, "");
        compare(m.showsIdentity, d.tag === "enterprise");
    }

    function test_networkSsidStaysAField() {
        const m = createTemporaryObject(modelC, test, {request: network("wpa", "", "Keyring asks for a password\u202e")});
        compare(m.title, "The Wi-Fi network “Keyring asks for a password” requires a WPA2 password.", "the SSID inside Grassfield's sentence, flattened");
    }

    function test_networkJoinRule() {
        const m = createTemporaryObject(modelC, test, {request: network("wpa")});
        verify(!m.networkReady(7), "WPA2: 8 characters at least");
        verify(m.networkReady(8));
        verify(!m.networkReady(65));
        const sent = wired(m);
        verify(!m.submit("short", null), "a WPA2 password too short is not sent");
        verify(m.error !== "");
        compare(sent.length, 0);
        verify(m.submit("correct horse", null));
        compare(sent, [{ok: true, password: "correct horse", choice: false}]);
        verify(!m.submit("again horse", null), "once");
        m.request = network("wep");
        verify(m.networkReady(1), "WEP: any length (NetworkManager checks the key)");
        verify(!m.networkReady(0));
    }

    // The connection's username is shown, read-only; the answer is the password only (NetworkManager keeps nothing else of a
    // reply: opus review of step 9c, MAJOR).
    function test_networkEnterprise() {
        const m = createTemporaryObject(modelC, test, {request: network("enterprise", "alice\u202e")});
        compare(m.identity, "alice", "the connection's username, flattened");
        verify(m.showsIdentity);
        verify(!m.asksName, "no name field: the server sheet's only");
        compare(m.loginName, "");
        verify(m.networkReady(1));
        const sent = wired(m);
        verify(m.submit("pw", null));
        compare(sent, [{ok: true, password: "pw", choice: false}], "no name in the answer");
        m.request = network("wpa");
        compare(m.identity, "");
        verify(!m.showsIdentity);
    }

    function test_networkCancelAndShowPassword() {
        const m = createTemporaryObject(modelC, test, {request: network("wpa")});
        const sent = wired(m);
        m.showPassword = true;
        m.clearRequested();
        verify(!m.showPassword, "emptying the fields hides the password again");
        m.showPassword = true;
        m.request = network("wpa3");
        verify(!m.showPassword, "a new request starts hidden");
        m.cancel();
        compare(sent, [{ok: false, password: null, choice: false}]);
    }

    // --- step 9e: KIO's server sheet ---------------------------------------------------------------------------------------

    function server(login, requester, serverName) {
        test.serial++;
        return {
            id: "p9",
            serial: test.serial,
            kind: "kio",
            requester: Object.assign({role: "kio", name: "", desktopId: "", icon: "", path: "/usr/lib/kf6/kioworker", identified: true, onBehalf: true}, requester || {}),
            texts: {title: "", message: "", description: "", warning: "", continueLabel: "", cancelLabel: ""},
            choice: null,
            passwordNew: false,
            strength: false,
            waited: false,
            arrivedAt: new Date(),
            server: serverName || "example.org",
            login: Object.assign({name: "", nameMode: "edit", realm: "", retry: false, remember: "off", keyring: "protected"}, login || {})
        };
    }

    function test_serverSheet() {
        const m = createTemporaryObject(modelC, test, {request: server()});
        verify(m.server);
        verify(m.asksPassword);
        verify(!m.network);
        compare(m.title, "Enter your name and password for the server “example.org”.");
        compare(m.requesterName, "KIO");
        compare(m.requesterDetail, "Requested by KIO for an app");
        compare(m.glyph, "globe");
        verify(!m.hasCallerText, "no realm: no caller text");
        verify(m.asksName);
        verify(!m.nameReadOnly);
        verify(!m.showsIdentity, "no network username line");
        compare(m.identity, "");
        verify(m.hasChoice);
        compare(m.choiceLabel, "Remember this password", "Grassfield's label");
        verify(!m.choice, "off at first");
        compare(m.keyringNotice, "");
        compare(m.error, "");
    }

    function test_serverRequesterIsTheBridges() {
        const app = createTemporaryObject(modelC, test, {request: server({}, {role: "app", name: "Files", icon: "system-file-manager", onBehalf: false})});
        compare(app.requesterDetail, "Requested by Files");
        compare(app.glyph, "apps");
        const stranger = createTemporaryObject(modelC, test, {request: server({}, {role: "unidentified", path: "/home/u/evil", identified: false, onBehalf: false})});
        compare(stranger.requesterDetail, "Requested by an unidentified program");
        compare(stranger.requesterPath, "/home/u/evil");
        compare(stranger.glyph, "exclamationmark-triangle");
        compare(stranger.title, "Enter your name and password for the server “example.org”.", "the server stays a field of Grassfield's sentence");
    }

    function test_serverRealmIsTheServersUnverifiedText() {
        const m = createTemporaryObject(modelC, test, {request: server({realm: "Authentication required"})});
        verify(m.hasCallerText);
        compare(m.callerTitle, "Authentication required");
        compare(m.callerIntro, "The server describes this login as follows. It is not verified:");
        compare(m.title, "Enter your name and password for the server “example.org”.", "never the realm in the title's place");
    }

    function test_serverNameModes() {
        const m = createTemporaryObject(modelC, test, {request: server({name: "alice", nameMode: "fixed"})});
        verify(m.asksName);
        verify(m.nameReadOnly);
        compare(m.loginName, "alice");
        verify(m.serverReady(1, 0), "a name shown only is not typed");
        const sent = wired(m);
        verify(m.submit("pw", null));
        compare(sent, [{ok: true, password: "pw", choice: false}], "no name in the answer: the caller's stays");
        m.request = server({nameMode: "none"});
        verify(!m.asksName);
        compare(m.title, "Enter your password for the server “example.org”.");
        compare(m.loginName, "");
    }

    function test_serverConnectRule() {
        const m = createTemporaryObject(modelC, test, {request: server({name: "alice", remember: "on"})});
        compare(m.loginName, "alice", "the caller's name (or the keyring's) as the name's first text");
        verify(m.choice, "Remember on: the keyring holds one already");
        verify(!m.serverReady(0, 5), "a password is needed");
        verify(!m.serverReady(3, 0), "a name is needed");
        verify(m.serverReady(1, 1));
        const sent = wired(m);
        m.loginName = "";
        verify(!m.submit("pw", null), "no name: nothing sent");
        verify(m.error !== "");
        verify(!m.submit("", null), "no password: nothing sent");
        compare(sent.length, 0);
        m.loginName = "bob";
        m.choice = false;
        verify(m.submit("pw", null));
        compare(sent, [{ok: true, password: "pw", choice: false, identity: "bob"}]);
        verify(!m.submit("pw", null), "once");
    }

    function test_serverRetryAndKeyring() {
        const m = createTemporaryObject(modelC, test, {request: server({retry: true, keyring: "unprotected"})});
        compare(m.error, "The name or password was not accepted. Try again.", "Grassfield's words, never the worker's");
        compare(m.keyringNotice, "Your keyring has no password: a password remembered here is stored unencrypted on this computer.");
        m.request = server({keyring: "unknown"});
        compare(m.error, "");
        compare(m.keyringNotice, "", "nothing said when it cannot be known");
        m.request = server({remember: "none", keyring: "unknown"});
        verify(!m.hasChoice, "Remember not offered");
        compare(m.choiceLabel, "");
        const sent = wired(m);
        m.loginName = "bob";
        m.cancel();
        compare(sent, [{ok: false, password: null, choice: false}]);
    }

    function test_serverHeldNotice() {
        const m = createTemporaryObject(modelC, test, {request: server()});
        verify(m.heldNotice(new Date(), "server").indexOf("Click the alert to type your name and password: nothing typed elsewhere goes into it.") >= 0);
    }

    // Step 10: a BlueZ pairing step as the agent holds it (a confirmation by default).
    function pairing(p, device) {
        return request({
            kind: "bluetooth",
            requester: {role: "bluetooth", name: "", desktopId: "", icon: "", path: "", identified: true, onBehalf: false},
            texts: {title: "", message: "", description: "", warning: "", continueLabel: "", cancelLabel: ""},
            device: Object.assign({name: "Desk Keyboard", address: "AA:BB:CC:DD:EE:01", icon: "keyboard"}, device || {}),
            pairing: Object.assign({mode: "confirm", code: "000042", entered: 0, service: "", uuid: ""}, p || {})
        });
    }

    function test_pairingSheet_data() {
        return [
            {tag: "pin", p: {mode: "pin", code: ""}, message: "Enter the device's PIN code.", code: "", field: true, display: false, authorizes: false},
            {tag: "passkey", p: {mode: "passkey", code: ""}, message: "Enter the code shown on the device.", code: "", field: true, display: false, authorizes: false},
            {tag: "display-pin", p: {mode: "display-pin", code: "482913"}, message: "Type this code on the device, then press Return on it.", code: "482913", field: false, display: true, authorizes: false},
            {tag: "display-passkey", p: {mode: "display-passkey", code: "000042", entered: 2}, message: "Type this code on the device, then press Return on it.", code: "000042", field: false, display: true, authorizes: false},
            {tag: "confirm", p: {}, message: "Connect only if the device shows the same code.", code: "000042", field: false, display: false, authorizes: false},
            {tag: "authorize", p: {mode: "authorize", code: ""}, message: "The device wants to pair with this computer.", code: "", field: false, display: false, authorizes: true},
            {tag: "authorize-service", p: {mode: "authorize-service", code: "", service: "audio", uuid: "0000110b-0000-1000-8000-00805f9b34fb"}, message: "The device wants to use audio streaming on this computer.", code: "", field: false, display: false, authorizes: true}
        ];
    }
    function test_pairingSheet(d) {
        const m = createTemporaryObject(modelC, test, {request: pairing(d.p)});
        compare(m.pairing, true);
        compare(m.title, "Connection Request from “Desk Keyboard”", "the device's name is a field of Grassfield's sentence");
        compare(m.requesterDetail, "Bluetooth device AA:BB:CC:DD:EE:01");
        compare(m.requesterName, "Bluetooth");
        compare(m.glyph, "keyboard");
        compare(m.pairingMessage, d.message);
        compare(m.pairingCode, d.code);
        compare(m.asksCode, d.field);
        compare(m.asksPassword, d.field, "the field is the PIN's or the passkey's");
        compare(m.displaysCode, d.display);
        compare(m.authorizes, d.authorizes);
        compare(m.hasCallerText, false, "no caller text");
        compare(m.callerIntro, "");
        compare(m.hasChoice, false);
        compare(m.entered, d.tag === "display-passkey" ? 2 : 0);
        compare(m.pairingProgress, d.tag === "display-passkey" ? "Digits typed on the device: 2 of 6" : "");
        compare(m.serviceUuid, "", "a named service shows no UUID");
        compare(m.pairingHeldWhyOf(d.p.mode || "confirm"), d.field ? "pairing-code" : d.display ? "pairing-display" : "pairing-answer");
    }

    function test_pairingNameAndGlyph() {
        const m = createTemporaryObject(modelC, test, {request: pairing({}, {name: "Key\nboard\u202e", icon: ""})});
        compare(m.title, "Connection Request from “Key board”", "the name flattened again");
        compare(m.glyph, "bluetooth", "no icon: the Bluetooth glyph");
        m.request = pairing({}, {icon: "lock"});
        compare(m.glyph, "bluetooth", "never a glyph outside the bridge's list");
        m.request = pairing({mode: "authorize-service", code: "", service: "other", uuid: "03b80e5a-ede8-4b33-a751-6ce34ec4c700"});
        compare(m.pairingMessage, "The device wants to use a Bluetooth service on this computer.");
        compare(m.serviceUuid, "03b80e5a-ede8-4b33-a751-6ce34ec4c700", "an unnamed service shows its UUID");
        for (const key of ["remote-control", "headset", "hands-free", "file-transfer", "object-push", "network", "input", "phonebook", "messages", "serial", "dial-up"])
            verify(m.serviceLabelOf(key) !== m.serviceLabelOf("other"), key);
    }

    function test_pairingCodeRules() {
        const m = createTemporaryObject(modelC, test, {request: pairing({mode: "passkey", code: ""})});
        const sent = wired(m);
        verify(!m.pairingReady(5));
        verify(m.pairingReady(6), "a passkey at 6 characters");
        verify(!m.pairingReady(7));
        verify(!m.submit("12345a", null), "6 characters that are not digits");
        compare(m.error, "Type the 6 digits of the code.");
        compare(sent.length, 0);
        verify(m.submit("012345", null));
        compare(sent, [{ok: true, password: "012345", choice: false}]);
        m.request = pairing({mode: "pin", code: ""});
        const pins = wired(m);
        verify(m.pairingReady(1));
        verify(m.pairingReady(16));
        verify(!m.pairingReady(17));
        verify(!m.submit("12-34", null));
        compare(m.error, "A PIN has 1 to 16 letters or digits.");
        verify(m.submit("0000", null));
        compare(pins, [{ok: true, password: "0000", choice: false}]);
    }

    function test_pairingAnswers() {
        const m = createTemporaryObject(modelC, test, {request: pairing()});
        let sent = wired(m);
        verify(!m.pairingReady(6), "a confirmation has no field");
        verify(m.submit(null, null));
        compare(sent, [{ok: true, password: null, choice: false}], "Connect carries nothing");
        m.request = pairing({mode: "authorize", code: ""});
        sent = wired(m);
        m.cancel();
        compare(sent, [{ok: false, password: null, choice: false}], "Decline");
        m.request = pairing({mode: "display-passkey", code: "000042"});
        sent = wired(m);
        verify(!m.submit(null, null), "a code shown is never answered ok");
        verify(!m.submit("000042", null));
        compare(sent.length, 0);
        m.cancel();
        compare(sent, [{ok: false, password: null, choice: false}], "only Cancel");
    }

    function test_pairingEnteredFollowsTheRequest() {
        const m = createTemporaryObject(modelC, test, {request: pairing({mode: "display-passkey", code: "000042", entered: 3})});
        compare(m.entered, 3);
        m.entered = 5;
        compare(m.pairingProgress, "Digits typed on the device: 5 of 6");
        m.request = pairing({mode: "display-passkey", code: "000043", entered: 0});
        compare(m.entered, 0, "a new request starts from its own count");
        m.request = pairing();
        compare(m.entered, 0);
        compare(m.pairingProgress, "");
    }

    function test_pairingHeldNotice() {
        const m = createTemporaryObject(modelC, test, {request: pairing({mode: "pin", code: ""})});
        const at = new Date(2026, 10, 1, 9, 30);
        verify(m.heldNotice(at, "pairing-code").indexOf("Click the alert to type the code: nothing typed elsewhere goes into it.") >= 0);
        verify(m.heldNotice(at, "pairing-answer").indexOf("no key answers it before that") >= 0);
        compare(m.heldNotice(at, "pairing-display"), "", "a code shown needs no click to be read");
    }
}
