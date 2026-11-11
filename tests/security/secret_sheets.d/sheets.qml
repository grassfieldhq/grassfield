import QtQuick
import QtTest
import qs.security

// The secret sheets and the one queue (tests/security/secret_sheets.sh runs this as tst_sheets.qml beside the generated
// agents): the real SecretAgent and AuthAgent (Quickshell types replaced, logic untouched), the real SecretSheet,
// SecretSheetModel, AuthDialog, AuthDialogModel and SheetQueue, wired as shell.qml wires them; a fake prompter client and
// mock polkit flows. Real key and mouse events. ADR-0035 D-9, master-prompt R12. Step 9c: NetworkManager's Wi-Fi alert. Step
// 9e: KIO's server sheet. Step 10: BlueZ's pairing sheets.
Item {
    id: top
    width: 800
    height: 600

    readonly property Component secretC: Qt.createComponent(Qt.resolvedUrl("secret/AgentUnderTest.qml"))
    readonly property Component polkitC: Qt.createComponent(Qt.resolvedUrl("polkit/AgentUnderTest.qml"))

    // shell.qml's wiring: one queue, the polkit sheet's place bound to the agent's.
    Component {
        id: rigC
        Item {
            id: rig
            width: 800
            height: 600
            property var polkit: null
            property var secret: null
            readonly property SheetQueue queue: q

            SheetQueue {
                id: q
                polkitPresent: rig.polkit !== null && rig.polkit.queuePresent
            }
        }
    }

    Component {
        id: flowC
        QtObject {
            property string message: "msg"
            property string actionId: "org.example.action"
            property string iconName: ""
            property var identities: []
            property var selectedIdentity: null
            property bool isResponseRequired: true
            property string inputPrompt: "Password:"
            property bool responseVisible: false
            property string supplementaryMessage: ""
            property bool supplementaryIsError: false
            property int cancels: 0
            property var submits: []
            function submit(p) {
                submits.push(p);
            }
            function cancelAuthenticationRequest() {
                cancels++;
            }
        }
    }

    TestCase {
        name: "SecretSheets"
        when: windowShown

        property var rig: null
        property var client: null
        property var shownIds: []

        function init() {
            SheetSession.locked = false;
            SheetSession.saverShown = false;
            SheetSession.displaysOff = false;
            SheetSession.starting = false;
            SheetSession.sleeping = false;
            compare(top.secretC.status, Component.Ready, top.secretC.errorString());
            compare(top.polkitC.status, Component.Ready, top.polkitC.errorString());
            rig = createTemporaryObject(rigC, top);
            verify(rig);
            rig.polkit = top.polkitC.createObject(rig, {queue: rig.queue});
            rig.secret = top.secretC.createObject(rig, {queue: rig.queue});
            verify(rig.secret && rig.polkit);
            client = rig.secret.clientMock;
            shownIds = [];
            const seen = shownIds;
            const agent = rig.secret;
            agent.model.requestChanged.connect(() => {
                if (agent.model.request)
                    seen.push(agent.model.request.id);
            });
        }

        function find(item, pred) {
            if (!item)
                return null;
            if (pred(item))
                return item;
            for (let i = 0; i < item.children.length; i++) {
                const r = find(item.children[i], pred);
                if (r)
                    return r;
            }
            return null;
        }
        function sheet() {
            return rig.secret.holderItem.item;
        }
        function named(name) {
            return find(sheet(), i => i.objectName === name);
        }
        function polkitField() {
            return find(rig.polkit.holderItem.item, i => i.submitted !== undefined && i.clear !== undefined && i.empty !== undefined);
        }
        function typeText(t) {
            for (const c of t)
                keyClick(c);
        }
        function polkitArrives(msg) {
            const f = createTemporaryObject(flowC, top, {message: msg});
            rig.polkit.agentMock.isActive = true;
            rig.polkit.agentMock.flow = f;
            return f;
        }
        function polkitEnds() {
            rig.polkit.agentMock.isActive = false;
            rig.polkit.agentMock.flow = null;
        }
        function shown(id) {
            tryVerify(() => rig.secret.model.active && rig.secret.model.id === id, 3000, id + " on screen");
        }

        // A gcr password request: the bridge's requester row and the caller's text under it, never as the sheet's own; the
        // password typed goes back once, the field is then empty, and the keys stay on the sink a moment (gcr asks again
        // at once after a wrong password).
        function test_01_passwordOnce() {
            client.prompt("p1", {});
            shown("p1");
            compare(rig.secret.heldByLock, false);
            compare(rig.secret.sheet.shown, true);
            compare(rig.secret.sheet.takesKeys, true);
            compare(named("secretTitle").text, "Keyring asks for a password");
            compare(named("secretCallerIntro").text, "Another program sent this message through Keyring. It is not verified:");
            compare(named("secretCaller_title").text, "Authentication required", "the caller's title, in the caller's block");
            compare(named("secretCaller_message").text, "Unlock the login keyring");
            compare(named("secretGlyph").name, "key");
            verify(find(sheet(), i => i.name === "lock" || i.name === "lock-fill" || i.name === "shield") === null, "no lock or shield glyph");
            compare(named("secretOk").text, "OK", "Grassfield's label, not the caller's (Allow)");
            tryVerify(() => named("secretField").activeFocus);
            const field = named("secretField");
            let emptyAtAnswer = false;
            rig.secret.model.answerRequested.connect(() => emptyAtAnswer = field.empty);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1);
            compare([client.answers[0].id, client.answers[0].ok, client.answers[0].password], ["p1", true, "pw"]);
            verify(emptyAtAnswer, "the field is emptied before the answer goes out");
            tryVerify(() => !rig.secret.model.active);
            compare(rig.secret.lingering, true, "the keys stay on the sink a moment");
            compare(rig.secret.lingerWhy, "sent");
            verify(rig.secret.sink.activeFocus);
            typeText("more");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1, "nothing more is sent");
            tryVerify(() => !rig.secret.sheet.visible, 3000);
            tryVerify(() => rig.queue.secretCount === 0);
        }

        // Esc answers "cancel" and gives the keyboard back at once (no linger).
        function test_02_cancel() {
            client.prompt("p1", {});
            shown("p1");
            tryVerify(() => named("secretField").activeFocus);
            typeText("x");
            keyClick(Qt.Key_Escape); // the field's own Esc empties it first
            keyClick(Qt.Key_Escape);
            compare(client.answers.length, 1);
            compare([client.answers[0].ok, client.answers[0].password], [false, null]);
            tryVerify(() => !rig.secret.model.active);
            compare(rig.secret.lingering, false);
            compare(rig.secret.sheet.visible, false);
            tryVerify(() => rig.queue.secretCount === 0);
        }

        // The caller gives up: a queued request leaves the queue without ever showing; the shown one ends under the user's
        // typing and the rest of the password goes nowhere.
        function test_03_withdrawn() {
            client.prompt("p1", {});
            client.prompt("p2", {});
            shown("p1");
            compare(rig.queue.secretCount, 2);
            client.withdraw("p2");
            compare(rig.queue.secretCount, 1, "p2 left the queue");
            tryVerify(() => named("secretField").activeFocus);
            typeText("sec");
            client.withdraw("p1");
            tryVerify(() => !rig.secret.model.active);
            compare(rig.secret.lingering, true);
            compare(rig.secret.lingerWhy, "cancelled");
            verify(rig.secret.sink.activeFocus);
            compare(rig.secret.notice.visible, true);
            typeText("ret");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0, "a withdrawn request is never answered");
            tryVerify(() => !rig.secret.sheet.visible, 3000);
            wait(50);
            compare(shownIds, ["p1"], "p2 was never shown");
            compare(rig.queue.secretCount, 0);
        }

        // At most 8 secret requests: the ninth is answered "cancelled" at once and never shown.
        function test_04_ninth() {
            for (let i = 1; i <= 9; i++)
                client.prompt("p" + i, {});
            compare(rig.secret.requestCount, 8);
            compare(client.answers.length, 1);
            compare([client.answers[0].id, client.answers[0].ok], ["p9", false]);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p9", result: "refused"}, "the shell's refusal, never a user's cancel");
            compare(rig.queue.secretCount, 8);
        }

        // A request that waited in the queue is held when its turn comes: no keyboard until a click past the guard.
        function test_05_queuedIsHeld() {
            client.prompt("p1", {});
            client.prompt("p2", {texts: {title: "", message: "second", description: "", warning: "", "continue": "", cancel: ""}});
            shown("p1");
            tryVerify(() => named("secretField").activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            shown("p2");
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "waited");
            compare(rig.secret.sheet.takesKeys, false);
            verify(named("secretHeldNotice").text.indexOf("while another one was open") >= 0);
            mouseClick(rig.secret.sheet, 5, 5);
            compare(rig.secret.userFocused, false, "a click within the guard gives nothing");
            wait(600);
            mouseClick(rig.secret.sheet, 5, 5);
            compare(rig.secret.userFocused, true);
            compare(rig.secret.sheet.takesKeys, true);
            tryVerify(() => named("secretField").activeFocus);
        }

        // The polkit sheet keeps the keyboard while a gcr request arrives: the gcr sheet waits and is shown after, held.
        function test_06_polkitKeepsTheKeyboard() {
            const f = polkitArrives("A");
            tryVerify(() => polkitField() && polkitField().activeFocus);
            typeText("adm");
            client.prompt("p1", {});
            wait(100);
            compare(rig.secret.model.active, false, "the gcr request waits");
            compare(rig.secret.sheet.visible, false);
            compare(rig.secret.sheet.takesKeys, false);
            verify(polkitField().activeFocus, "the polkit field keeps the keyboard");
            typeText("in");
            keyClick(Qt.Key_Return);
            compare(f.submits, ["admin"]);
            polkitEnds();
            shown("p1");
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "waited");
            compare(rig.secret.sheet.takesKeys, false);
            compare(client.answers.length, 0);
        }

        // The reverse: a polkit request that arrives while a secret sheet is typed into waits (no flow handed to the
        // polkit sheet), also through the secret sheet's linger, then shows held.
        function test_07_secretKeepsTheKeyboard() {
            client.prompt("p1", {});
            shown("p1");
            tryVerify(() => named("secretField").activeFocus);
            typeText("sec");
            const f = polkitArrives("A");
            compare(rig.polkit.waiting, true);
            compare(rig.polkit.model.active, false, "no request handed to the polkit sheet");
            compare(rig.polkit.sheet.visible, false);
            compare(rig.polkit.sheet.takesKeys, false);
            verify(named("secretField").activeFocus, "the secret field keeps the keyboard");
            typeText("ret");
            keyClick(Qt.Key_Return);
            compare(client.answers[0].password, "secret");
            tryVerify(() => rig.secret.lingering);
            compare(rig.polkit.waiting, true, "the linger keeps the secret sheet's place");
            compare(rig.polkit.sheet.visible, false);
            tryVerify(() => rig.polkit.model.active, 3000);
            compare(rig.polkit.heldByLock, true, "held: right after another sheet");
            compare(rig.polkit.heldWhy, "queued");
            compare(rig.polkit.sheet.takesKeys, false);
            compare(rig.secret.sheet.visible, false, "one sheet on screen at a time");
            compare(f.submits.length, 0);
        }

        // Nothing over the lock: a request that arrives while locked is neither mapped nor given the keyboard; after the
        // unlock it is held until a click past the guard.
        function test_08_locked() {
            SheetSession.locked = true;
            client.prompt("p1", {});
            shown("p1");
            compare(rig.secret.sheet.shown, false);
            compare(rig.secret.sheet.visible, false);
            compare(rig.secret.sheet.takesKeys, false);
            SheetSession.locked = false;
            compare(rig.secret.sheet.shown, true);
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "locked");
            compare(rig.secret.sheet.takesKeys, false);
            mouseClick(rig.secret.sheet, 5, 5);
            compare(rig.secret.userFocused, false);
            wait(600);
            mouseClick(rig.secret.sheet, 5, 5);
            compare(rig.secret.userFocused, true);
            tryVerify(() => named("secretField").activeFocus);
        }

        // Never a password for a request not on screen with the keyboard: behind the lock, or held within the guard, an
        // "ok" is not sent (a new password may be empty, so a stray click on OK must not answer); Cancel still cancels.
        function test_09_noAnswerOffScreen() {
            SheetSession.locked = true;
            client.prompt("p1", {passwordNew: true, strength: true});
            shown("p1");
            compare(rig.secret.model.submit("x", "x"), false, "behind the lock: nothing sent");
            compare(client.answers.length, 0);
            SheetSession.locked = false;
            mouseClick(named("secretOk"));
            compare(client.answers.length, 0, "OK on a held sheet within the guard sends nothing");
            compare(rig.secret.model.submit("y", "y"), false, "held, no keyboard: nothing sent");
            compare(client.answers.length, 0);
            mouseClick(named("secretCancel"));
            compare(client.answers.length, 1);
            compare(client.answers[0].ok, false, "Cancel at worst");
        }

        // Shown after an unlock: held ("just as the screen was unlocked").
        function test_10_afterUnlock() {
            SheetSession.locked = true;
            SheetSession.locked = false;
            client.prompt("p1", {});
            shown("p1");
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "unlock");
            compare(rig.secret.sheet.takesKeys, false);
        }

        // The opus delta review of S3, LOW: a request held because the security process had just started (the saver counted for
        // the start alone, SheetSession.starting) says so, not that it waited for the screen saver.
        function test_11b_heldWhileStarting() {
            SheetSession.saverShown = true;
            SheetSession.starting = true;
            client.prompt("p1", {});
            shown("p1");
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "starting");
            verify(sheet().heldNotice.indexOf("while Grassfield was starting") >= 0, sheet().heldNotice);
            SheetSession.starting = false;
            SheetSession.saverShown = false;
        }

        // The screen saver holds an open request; its waking click answers nothing; the guard starts over at its end.
        function test_11_saver() {
            client.prompt("p1", {});
            shown("p1");
            SheetSession.saverShown = true;
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "saver");
            wait(600);
            mouseClick(named("secretCancel"));
            compare(client.answers.length, 0, "the saver swallows the click");
            SheetSession.saverShown = false;
            compare(rig.secret.model.heldClickAccepted(), false, "guard restarted");
        }

        // A lost connection drops every request: the queued ones leave unseen, the shown one ends.
        function test_12_lost() {
            client.prompt("p1", {});
            client.prompt("p2", {});
            shown("p1");
            client.drop();
            tryVerify(() => !rig.secret.model.active);
            tryVerify(() => rig.queue.secretCount === 0, 3000);
            compare(rig.secret.requestCount, 0);
            wait(50);
            compare(shownIds, ["p1"]);
        }

        // A new password: typed twice alike (Return in New moves on to Verify, Return in Verify takes both); different,
        // nothing is sent, both fields are emptied and the sheet says why; the strength meter follows the length.
        function test_13_newPassword() {
            client.prompt("p1", {passwordNew: true, strength: true});
            shown("p1");
            tryVerify(() => named("secretNewField").activeFocus);
            compare(named("secretStrength").level, 0);
            typeText("abcdefgh");
            compare(named("secretStrength").level, 2);
            named("secretVerifyField").forceActiveFocus();
            typeText("abcdefgX");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0);
            verify(named("secretError").text !== "");
            verify(named("secretNewField").empty && named("secretVerifyField").empty);
            named("secretNewField").forceActiveFocus();
            typeText("same");
            keyClick(Qt.Key_Return);
            verify(named("secretVerifyField").activeFocus, "Return in New moves on to Verify");
            compare(named("secretNewField").length, 4, "and keeps what New holds");
            typeText("same");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1);
            compare(client.answers[0].password, "same");
        }

        // A confirmation (no field) with the caller's check box; an unidentified program shows its path under the title. A
        // confirmation is always held (decision 9-23): a click past the guard gives it the keyboard, then OK answers.
        function test_14_confirmUnidentified() {
            client.prompt("p1", {kind: "confirm", choice: {label: "Remember", chosen: false},
                                 requester: {role: "unidentified", name: "", desktopId: "", icon: "", path: "/home/u/.local/bin/tool", identified: false, onBehalf: false}});
            shown("p1");
            compare(named("secretTitle").text, "An unidentified program asks you to confirm");
            compare(named("secretPath").text, "/home/u/.local/bin/tool");
            compare(named("secretGlyph").name, "exclamationmark-triangle");
            compare(named("secretField").visible, false);
            compare(rig.secret.heldByLock, true, "a confirmation is held");
            compare(rig.secret.heldWhy, "confirm");
            compare(rig.secret.sheet.takesKeys, false);
            const box = named("secretChoice");
            // The alert lays out at the next polish (a Column), and the check box moves down once it has: click it there.
            waitForItemPolished(box.parent);
            waitForRendering(rig.secret.sheet);
            wait(600);
            mouseClick(box);
            compare(rig.secret.model.choice, true);
            compare(rig.secret.sheet.takesKeys, true, "the click past the guard gives it the keyboard");
            named("secretOk").forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "ok", choice: true});
            tryVerify(() => !rig.secret.sheet.visible);
            compare(rig.secret.lingering, false, "a confirmation gives the keyboard back");
        }

        // A gcr request that arrives right after the polkit sheet was answered (the user may still be typing) is held.
        function test_16_rightAfterPolkit() {
            const f = polkitArrives("A");
            tryVerify(() => polkitField() && polkitField().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(f.submits, ["pw"]);
            polkitEnds();
            client.prompt("p1", {});
            shown("p1");
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "queued");
            compare(rig.secret.sheet.takesKeys, false);
        }

        // A polkit request is never refused by the bound of 8 (ADR-0035 D-9): with eight secret requests held it queues,
        // and its sheet comes once the secret sheets before it are gone.
        function test_17_polkitNeverRefused() {
            for (let i = 1; i <= 8; i++)
                client.prompt("p" + i, {});
            shown("p1");
            const f = polkitArrives("A");
            compare(rig.polkit.waiting, true);
            compare(f.cancels, 0, "queued, not refused");
            for (let i = 2; i <= 8; i++)
                client.withdraw("p" + i);
            keyClick(Qt.Key_Escape);
            compare(client.answers.length, 1);
            tryVerify(() => rig.polkit.model.active, 3000);
            compare(rig.polkit.model.message, "A");
            compare(f.cancels, 0);
        }

        // A bridge that restarted counts its ids from p1 again: an earlier answer to "p1" (a cancellation, which gives the
        // keyboard back) never stands for the new p1, withdrawn under the user's typing: the keys stay on the sink.
        function test_18_restartedBridgeReusesIds() {
            client.prompt("p1", {});
            shown("p1");
            tryVerify(() => named("secretField").activeFocus);
            keyClick(Qt.Key_Escape);
            compare(client.answers.length, 1);
            tryVerify(() => !rig.secret.model.active);
            client.drop();
            tryVerify(() => rig.queue.secretCount === 0);
            wait(1100); // past the hold that follows another sheet: the new p1 takes the keyboard at once
            client.prompt("p1", {});
            shown("p1");
            compare(rig.secret.model.canSubmit, true, "the new p1 is unanswered");
            compare(rig.secret.sheet.takesKeys, true);
            tryVerify(() => named("secretField").activeFocus);
            typeText("sec");
            client.withdraw("p1");
            tryVerify(() => !rig.secret.model.active);
            compare(rig.secret.lingering, true, "the rest of the password goes to the sink");
            compare(rig.secret.lingerWhy, "cancelled");
        }

        // Opus review of step 9b, MAJOR-1: a confirmation with no other reason to be held is held all the same; Space, Return
        // and Enter, whatever has the focus in it, answer nothing; a click within the guard gives nothing; past it, a key may.
        function test_19_confirmNeverByAKey() {
            client.prompt("p1", {kind: "confirm"});
            shown("p1");
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "confirm");
            verify(named("secretHeldNotice").text.indexOf("no key answers a confirmation") >= 0);
            compare(rig.secret.sheet.takesKeys, false, "the window does not ask for the keyboard");
            named("secretOk").forceActiveFocus();
            keyClick(Qt.Key_Space);
            keyClick(Qt.Key_Return);
            keyClick(Qt.Key_Enter);
            compare(client.answers.length, 0, "no key answers it, even with OK focused");
            mouseClick(rig.secret.sheet, 5, 5);
            compare(rig.secret.userFocused, false, "a click within the guard gives nothing");
            keyClick(Qt.Key_Space);
            compare(client.answers.length, 0);
            wait(600);
            mouseClick(rig.secret.sheet, 5, 5);
            compare(rig.secret.sheet.takesKeys, true);
            tryVerify(() => named("secretOk").activeFocus);
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1, "a deliberate click, then OK");
            compare(client.answers[0].ok, true);
        }

        // Decided by the integrator on 2026-11-01 (closest to macOS: a pairing sheet's Connect button): one click on OK, past
        // the guard, confirms a confirmation sheet; within the guard the same click gives nothing.
        function test_27_confirmByOneClickOnOk() {
            client.prompt("p1", {kind: "confirm"});
            shown("p1");
            compare(rig.secret.heldByLock, true);
            waitForItemPolished(named("secretOk").parent);
            waitForRendering(rig.secret.sheet);
            mouseClick(named("secretOk"));
            compare(client.answers.length, 0, "a click on OK within the guard answers nothing");
            compare(rig.secret.userFocused, false);
            wait(600);
            mouseClick(named("secretOk"));
            compare(client.answers.length, 1, "one click on OK past the guard confirms");
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "ok"});
        }

        // Opus review of step 9b, MINOR-1: an empty new password is never sent by a stray Return. Return in New moves on to
        // Verify; Return in Verify with both fields empty sends nothing; OK (a click) may send an empty new password.
        function test_20_emptyNewPasswordNotByReturn() {
            client.prompt("p1", {passwordNew: true, strength: true});
            shown("p1");
            compare(rig.secret.heldByLock, false);
            tryVerify(() => named("secretNewField").activeFocus);
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0, "Return in New sends nothing");
            verify(named("secretVerifyField").activeFocus);
            keyClick(Qt.Key_Return);
            keyClick(Qt.Key_Enter);
            compare(client.answers.length, 0, "Return in Verify with both fields empty sends nothing");
            mouseClick(named("secretOk"));
            compare(client.answers.length, 1, "OK, clicked, may");
            compare(client.answers[0].password, "");
        }

        // Step 9c: a click past the guard on a held sheet.
        function clickPastGuard() {
            wait(600);
            mouseClick(rig.secret.sheet, 5, 5);
            compare(rig.secret.userFocused, true);
        }

        // Step 9c (decision 9-28): a NetworkManager request is the Wi-Fi alert, always held; after a click past the guard
        // the password field has the keys; Join takes only a WPA2 password of 8 characters or more (a shorter one stays in
        // the field); Show password shows the characters while checked; Join sends the password once.
        function test_21_networkHeldThenJoin() {
            client.promptNetwork("p1", {ssid: "Café"});
            shown("p1");
            compare(rig.secret.heldByLock, true, "always held");
            compare(rig.secret.heldWhy, "network");
            compare(rig.secret.sheet.takesKeys, false, "the keys stay where the user was typing");
            verify(named("secretHeldNotice").text.indexOf("nothing typed elsewhere goes into it") >= 0);
            compare(named("secretTitle").text, "The Wi-Fi network “Café” requires a WPA2 password.");
            compare(named("secretRequester").text, "Requested by NetworkManager");
            compare(named("secretGlyph").name, "wifi-3");
            compare(named("secretCallerBlock").visible, false, "no caller text");
            compare(named("secretIdentity").visible, false, "no name for WPA2");
            compare(named("secretShowPassword").visible, true);
            compare(named("secretOk").text, "Join");
            // Offscreen, keys reach the field even while held (the compositor withholds them in a session: takesKeys is
            // false): even a password of a valid length is not sent before the click.
            named("secretField").forceActiveFocus();
            typeText("longenough");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0, "no answer before the click past the guard");
            verify(named("secretField").empty, "and the field is emptied");
            clickPastGuard();
            tryVerify(() => named("secretField").activeFocus);
            const field = named("secretField");
            typeText("short");
            compare(named("secretOk").enabled, false, "Join waits for 8 characters");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0, "Return with a WPA2 password too short sends nothing");
            compare(field.length, 5, "...and keeps what was typed");
            typeText("pass");
            compare(named("secretOk").enabled, true);
            compare(field.reveal, false, "hidden at first");
            mouseClick(named("secretShowPassword"));
            compare(rig.secret.model.showPassword, true);
            compare(field.reveal, true, "Show password shows the characters");
            let emptyAtAnswer = false;
            rig.secret.model.answerRequested.connect(() => emptyAtAnswer = field.empty);
            field.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "ok", password: "shortpass"});
            verify(emptyAtAnswer, "the field is emptied before the answer goes out");
            tryVerify(() => !rig.secret.model.active);
            compare(rig.secret.lingerWhy, "sent", "the keys stay on the sink a moment after a password");
            compare(rig.secret.model.showPassword, false, "hidden again");
        }

        // Step 9c: WPA2 Enterprise: the connection's username is shown, read-only (NetworkManager keeps only secrets from a
        // reply: opus review of step 9c, MAJOR); Join sends the password only.
        function test_22_networkEnterprise() {
            client.promptNetwork("p1", {ssid: "Office", security: "enterprise", identity: "alice"});
            shown("p1");
            compare(named("secretTitle").text, "The Wi-Fi network “Office” requires WPA2 enterprise credentials.");
            const name = named("secretIdentity");
            compare(name.visible, true);
            compare(name.text, "Username: alice");
            compare(named("secretName").visible, false, "no name field: the server sheet's only");
            verify(name.textFormat === Text.PlainText && name.cursorPosition === undefined, "plain text, not a field");
            clickPastGuard();
            tryVerify(() => named("secretField").activeFocus);
            typeText("p");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "ok", password: "p"});
        }

        // Step 9c: NetworkManager cancels (CancelGetSecrets) while the user types: the sheet ends, the rest of the password
        // goes to the sink, nothing is answered.
        function test_23_networkCancelledWhileTyping() {
            client.promptNetwork("p1", {});
            shown("p1");
            clickPastGuard();
            tryVerify(() => named("secretField").activeFocus);
            typeText("half");
            client.withdraw("p1");
            tryVerify(() => !rig.secret.model.active);
            compare(rig.secret.lingering, true);
            compare(rig.secret.lingerWhy, "cancelled");
            verify(rig.secret.sink.activeFocus);
            typeText("rest");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0);
        }

        // Step 9c: one queue with the polkit sheet and gcr: the polkit sheet keeps the keyboard while an nm request and a gcr
        // request arrive; after it, the nm request (first in) is shown held; cancelled (Esc on its held sheet), the gcr
        // request comes next, held.
        function test_24_networkInTheQueue() {
            const f = polkitArrives("A");
            tryVerify(() => polkitField() && polkitField().activeFocus);
            typeText("adm");
            client.promptNetwork("p1", {});
            client.prompt("p2", {});
            wait(100);
            compare(rig.secret.model.active, false, "both wait");
            verify(polkitField().activeFocus, "the polkit field keeps the keyboard");
            typeText("in");
            keyClick(Qt.Key_Return);
            compare(f.submits, ["admin"]);
            polkitEnds();
            shown("p1");
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.sheet.takesKeys, false);
            compare(named("secretOk").text, "Join");
            keyClick(Qt.Key_Escape);
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "cancel"});
            shown("p2");
            compare(rig.secret.heldByLock, true, "the gcr request waited: held");
            compare(named("secretOk").text, "OK");
        }

        // Step 9c: the lock hides a sheet whose password was shown: shown again after the unlock, held, and hidden.
        function test_25_showPasswordHiddenAgainByTheLock() {
            client.promptNetwork("p1", {});
            shown("p1");
            clickPastGuard();
            tryVerify(() => named("secretField").activeFocus);
            mouseClick(named("secretShowPassword"));
            compare(named("secretField").reveal, true);
            SheetSession.locked = true;
            SheetSession.locked = false;
            compare(rig.secret.heldByLock, true);
            compare(named("secretField").reveal, false, "hidden again");
        }

        // Step 9e (decision 9-38): a KIO request is the server sheet, always held; after a click past the guard the empty name
        // field has the keys; Return in it moves on to the password; Connect needs both; the answer carries the name, the
        // password and Remember, once.
        function test_26_serverHeldThenConnect() {
            client.promptServer("p1", {});
            shown("p1");
            compare(rig.secret.heldByLock, true, "always held");
            compare(rig.secret.heldWhy, "server");
            compare(rig.secret.sheet.takesKeys, false, "the keys stay where the user was typing");
            verify(named("secretHeldNotice").text.indexOf("type your name and password: nothing typed elsewhere goes into it") >= 0);
            compare(named("secretTitle").text, "Enter your name and password for the server “example.org”.");
            compare(named("secretRequester").text, "Requested by KIO for an app");
            compare(named("secretGlyph").name, "globe");
            compare(named("secretCallerBlock").visible, false, "no realm, no caller text");
            compare(named("secretName").visible, true);
            compare(named("secretIdentity").visible, false, "no network username line");
            compare(named("secretShowPassword").visible, false, "no Show password for a server");
            compare(named("secretField").copyable, false, "the guard waits there too: a shown password is never copyable");
            compare(named("secretChoice").visible, true);
            compare(named("secretChoice").text, "Remember this password");
            compare(named("secretKeyringNotice").visible, false, "a protected keyring: nothing said");
            compare(named("secretOk").text, "Connect");
            compare(named("secretOk").enabled, false);
            // Offscreen, keys reach the fields even while held (the compositor withholds them in a session): even a name and
            // a password are not sent before the click.
            named("secretName").forceActiveFocus();
            typeText("x");
            named("secretField").forceActiveFocus();
            typeText("early");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0, "no answer before the click past the guard");
            verify(named("secretField").empty, "and the password field is emptied");
            clickPastGuard();
            tryVerify(() => named("secretField").activeFocus, 3000, "a name is there: the password field first");
            const name = named("secretName");
            name.forceActiveFocus();
            name.selectAll();
            typeText("alice");
            compare(rig.secret.model.loginName, "alice");
            keyClick(Qt.Key_Return);
            verify(named("secretField").activeFocus, "Return in the name moves on to the password");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0, "Return with no password sends nothing");
            typeText("pw");
            compare(named("secretOk").enabled, true);
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "ok", identity: "alice", password: "pw", choice: false});
            tryVerify(() => !rig.secret.model.active);
            compare(rig.secret.lingerWhy, "sent");
        }

        // Step 9e (decision 9-45): Remember already on (the keyring holds an item), the keyring without a password said under
        // it; the name prefilled, so the password field has the keys; Remember unchecked by a click goes back as false.
        function test_27_serverRememberAndKeyring() {
            client.promptServer("p1", {name: "bob", remember: "on", keyring: "unprotected"});
            shown("p1");
            compare(named("secretChoice").checked, true);
            compare(named("secretKeyringNotice").visible, true);
            compare(named("secretKeyringNotice").text, "Your keyring has no password: a password remembered here is stored unencrypted on this computer.");
            compare(named("secretName").text, "bob");
            clickPastGuard();
            tryVerify(() => named("secretField").activeFocus, 3000, "the name is there: the password field first");
            typeText("pw2");
            mouseClick(named("secretChoice"));
            compare(rig.secret.model.choice, false);
            mouseClick(named("secretOk"));
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "ok", identity: "bob", password: "pw2", choice: false});
        }

        // Step 9e: a name the caller fixed is shown and cannot be changed, and goes back unsaid; the realm is the server's
        // unverified text, plain, in the caller's block; the title stays Grassfield's sentence.
        function test_28_serverFixedNameAndRealm() {
            client.promptServer("p1", {name: "alice", nameMode: "fixed", realm: "Staff <b>Area</b>", remember: "none", keyring: "unknown"});
            shown("p1");
            compare(named("secretTitle").text, "Enter your name and password for the server “example.org”.");
            compare(named("secretCallerBlock").visible, true);
            compare(named("secretCallerIntro").text, "The server describes this login as follows. It is not verified:");
            compare(named("secretCaller_title").text, "Staff <b>Area</b>");
            compare(named("secretCaller_title").textFormat, Text.PlainText);
            compare(named("secretChoice").visible, false, "Remember not offered");
            clickPastGuard();
            tryVerify(() => named("secretField").activeFocus);
            const name = named("secretName");
            name.forceActiveFocus();
            typeText("eve");
            compare(name.text, "alice", "a fixed name cannot be changed");
            named("secretField").forceActiveFocus();
            typeText("pw3");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "ok", password: "pw3"});
        }

        // Step 9e (decision 9-40): a retry says so in Grassfield's words; no name field when the caller asks for none.
        function test_29_serverRetryWithoutName() {
            client.promptServer("p1", {nameMode: "none", retry: true});
            shown("p1");
            compare(named("secretTitle").text, "Enter your password for the server “example.org”.");
            compare(named("secretError").visible, true);
            compare(named("secretError").text, "The name or password was not accepted. Try again.");
            compare(named("secretName").visible, false);
            clickPastGuard();
            tryVerify(() => named("secretField").activeFocus);
            typeText("pin");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "ok", password: "pin", choice: false});
        }

        // Step 9e: a program the bridge cannot name: the warning glyph, its executable, the server still a field.
        function test_30_serverUnidentified() {
            client.promptServer("p1", {}, {role: "unidentified", path: "/home/u/.local/bin/evil", identified: false, onBehalf: false});
            shown("p1");
            compare(named("secretGlyph").name, "exclamationmark-triangle");
            compare(named("secretRequester").text, "Requested by an unidentified program");
            compare(named("secretPath").text, "/home/u/.local/bin/evil");
            keyClick(Qt.Key_Escape);
            compare(client.answers.length, 1, "Esc on the held sheet cancels");
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "cancel"});
        }

        // Step 9e: an empty name field takes the keys first after the click; Cancel answers "cancel" and nothing else.
        function test_32_serverEmptyNameFirstAndCancel() {
            client.promptServer("p1", {});
            shown("p1");
            clickPastGuard();
            tryVerify(() => named("secretName").activeFocus, 3000, "the empty name first");
            typeText("carol");
            mouseClick(named("secretCancel"));
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "cancel"});
        }

        // Step 9e (decision 9-42): a server that is not a host name never reaches a sheet (the client closes the connection on
        // such a line: here the parser refuses it).
        function test_31_serverFreeTextRefused() {
            for (const bad of ["Your Bank", "example.org/login", "Example.org"]) {
                let refused = false;
                try {
                    client.promptServer("p1", {}, {}, bad);
                } catch (e) {
                    refused = true;
                }
                verify(refused, bad);
            }
            wait(50);
            compare(rig.secret.model.active, false);
        }

        // Opus review of step 9c, MINOR: a password shown by Show password is never selectable or copyable: Select All and
        // Copy (and Cut) put nothing on the clipboard, a mouse drag selects nothing; the text stays in the field.
        function test_33_shownPasswordNotCopyable() {
            client.promptNetwork("p1", {});
            shown("p1");
            clickPastGuard();
            tryVerify(() => named("secretField").activeFocus);
            const field = named("secretField");
            typeText("secretpass");
            mouseClick(named("secretShowPassword"));
            compare(field.reveal, true);
            const input = find(field, i => i.echoMode !== undefined);
            verify(input !== null);
            compare(input.echoMode, TextInput.Normal, "shown as typed");
            const other = createTemporaryQmlObject("import QtQuick; TextInput { width: 100; height: 20; text: \"marker\" }", top);
            other.selectAll();
            other.copy();
            field.forceActiveFocus();
            keySequence(StandardKey.SelectAll);
            compare(input.selectedText, "", "Select All selects nothing");
            input.select(0, 4);
            compare(input.selectedText, "", "no selection can stay");
            keySequence(StandardKey.Copy);
            keySequence(StandardKey.Cut);
            compare(field.length, 10, "Cut takes nothing away");
            mouseDrag(input, 1, input.height / 2, input.width - 2, 0);
            compare(input.selectedText, "", "a mouse drag selects nothing");
            other.text = "";
            other.paste();
            compare(other.text, "marker", "the clipboard never got the password");
        }

        // Merge of step 9c into 9e: a KIO request past the bound of 8 is refused like any secret request, "refused" (never a
        // user's "cancel": the bridge then gives KIO's client nothing and caches no cancellation, decision 9-31), never shown.
        function test_34_serverNinthRefused() {
            for (let i = 1; i <= 8; i++)
                client.prompt("p" + i, {});
            client.promptServer("p9", {});
            compare(rig.secret.requestCount, 8);
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p9", result: "refused"}, "the shell's refusal, never a user's cancel");
            compare(rig.queue.secretCount, 8);
            tryVerify(() => shownIds.length > 0, 3000, "the first request is shown");
            wait(50);
            compare(shownIds.indexOf("p9"), -1, "the server sheet was never shown");
        }

        // The caller's text is plain: markup is shown as typed, never rendered.
        function test_15_plainText() {
            client.prompt("p1", {texts: {title: "<b>Admin</b> password", message: "<img src=x>", description: "", warning: "Wrong!", "continue": "", cancel: ""}});
            shown("p1");
            compare(named("secretCaller_title").text, "<b>Admin</b> password");
            compare(named("secretCaller_title").textFormat, Text.PlainText);
            compare(named("secretCaller_message").textFormat, Text.PlainText);
            compare(named("secretCaller_warning").text, "Wrong!");
            compare(named("secretTitle").text, "Keyring asks for a password");
        }

        // Step 10 (decision 10-7): a pairing confirmation is held; no key answers it, OK focused or not; after a click past
        // the guard, Connect (Return) answers it with nothing but "ok".
        function test_35_pairingConfirmHeld() {
            client.promptPairing("p1", {});
            shown("p1");
            compare(rig.secret.heldByLock, true, "always held");
            compare(rig.secret.heldWhy, "pairing-answer");
            compare(rig.secret.sheet.takesKeys, false);
            verify(named("secretHeldNotice").text.indexOf("no key answers it before that") >= 0);
            compare(named("secretTitle").text, "Connection Request from “Desk Keyboard”");
            compare(named("secretRequester").text, "Bluetooth device AA:BB:CC:DD:EE:01");
            compare(named("secretGlyph").name, "keyboard");
            compare(named("secretPairingMessage").text, "Connect only if the device shows the same code.");
            compare(named("secretPairingCode").text, "000042");
            compare(named("secretPairingCode").visible, true);
            compare(named("secretField").visible, false, "no field for a confirmation");
            compare(named("secretCallerBlock").visible, false, "no caller text");
            compare(named("secretOk").text, "Connect");
            compare(named("secretCancel").text, "Cancel");
            named("secretOk").forceActiveFocus();
            keyClick(Qt.Key_Space);
            keyClick(Qt.Key_Return);
            keyClick(Qt.Key_Enter);
            compare(client.answers.length, 0, "no key answers it before the click");
            clickPastGuard();
            tryVerify(() => named("secretOk").activeFocus);
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "ok"});
        }

        // Step 10: an incoming pairing or service: Decline / Connect; Esc on the held sheet declines.
        function test_36_pairingAuthorizeDecline() {
            client.promptPairing("p1", {mode: "authorize-service", code: "", service: "file-transfer", uuid: "00001106-0000-1000-8000-00805f9b34fb"}, {name: "Phone", icon: "phone"});
            shown("p1");
            compare(rig.secret.heldByLock, true);
            compare(named("secretCancel").text, "Decline");
            compare(named("secretOk").text, "Connect");
            compare(named("secretGlyph").name, "phone");
            compare(named("secretPairingMessage").text, "The device wants to use file transfer on this computer.");
            compare(named("secretPairingCode").visible, false);
            keyClick(Qt.Key_Escape);
            compare(client.answers.length, 1, "Esc declines");
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "cancel"});
        }

        // Step 10: a passkey field: nothing before the click; Connect waits for 6 characters; 6 that are not digits are not
        // sent; 6 digits go once, then the keys stay a moment on the sink ("Code sent").
        function test_37_pairingPasskey() {
            client.promptPairing("p1", {mode: "passkey", code: ""});
            shown("p1");
            compare(rig.secret.heldWhy, "pairing-code");
            verify(named("secretHeldNotice").text.indexOf("Click the alert to type the code") >= 0);
            compare(named("secretPairingMessage").text, "Enter the code shown on the device.");
            named("secretField").forceActiveFocus();
            typeText("123456");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0, "no answer before the click past the guard");
            clickPastGuard();
            tryVerify(() => named("secretField").activeFocus);
            compare(named("secretField").length, 0, "emptied");
            typeText("12345");
            compare(named("secretOk").enabled, false, "Connect waits for 6 characters");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0);
            compare(named("secretField").length, 5, "Return with too few characters keeps what was typed");
            typeText("a");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0, "six characters that are not all digits");
            compare(named("secretError").text, "Type the 6 digits of the code.");
            clickPastGuard();
            tryVerify(() => named("secretField").activeFocus);
            typeText("012345");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "ok", password: "012345"});
            tryVerify(() => !rig.secret.model.active);
            compare(rig.secret.lingering, true, "the keys stay on the sink a moment");
            compare(rig.secret.lingerWhy, "code");
            compare(find(rig.secret.notice, i => i.text === "Code sent") !== null, true);
        }

        // Step 10 (decision 10-8): a code shown: held without a notice, no OK, Cancel alone across the row; the digits typed on
        // the device update the sheet and nothing else (no arrival, no hold change, no focus moved, no keyboard taken); a
        // queued code shown keeps its own count; Cancel (a click, even within the guard) answers "cancel".
        function test_38_pairingDisplayProgress() {
            client.promptPairing("p1", {mode: "display-passkey", code: "000042", entered: 0});
            client.promptPairing("p2", {mode: "display-passkey", code: "000777", entered: 0}, {name: "Other"});
            shown("p1");
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "pairing-display");
            compare(named("secretHeldNotice").visible, false, "nothing to click for: no notice");
            compare(named("secretOk").visible, false, "no OK for a code shown");
            compare(named("secretCancel").visible, true);
            compare(named("secretCancel").width, sheet().width - 2 * sheet().pad, "Cancel alone fills the row");
            compare(named("secretPairingCode").text, "000042");
            compare(named("secretPairingProgress").text, "Digits typed on the device: 0 of 6");
            const focused = top.Window.activeFocusItem;
            const seen = shownIds.length;
            client.progress("p1", 3);
            compare(named("secretPairingProgress").text, "Digits typed on the device: 3 of 6");
            compare(top.Window.activeFocusItem, focused, "the focus did not move");
            compare(rig.secret.sheet.takesKeys, false, "the keyboard is not taken");
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.userFocused, false);
            compare(shownIds.length, seen, "the request did not arrive again");
            client.progress("p2", 5);
            compare(named("secretPairingProgress").text, "Digits typed on the device: 3 of 6", "another request's count is its own");
            mouseClick(named("secretCancel"));
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "cancel"});
            shown("p2");
            compare(named("secretPairingCode").text, "000777");
            compare(named("secretPairingProgress").text, "Digits typed on the device: 5 of 6", "the queued request's count, kept while it waited");
        }

        // Step 10: the device's name is a field of Grassfield's sentence, plain; a PIN field takes letters and digits only.
        function test_39_pairingNamePlainAndPin() {
            client.promptPairing("p1", {mode: "pin", code: ""}, {name: "<b>Admin</b> keyboard", icon: ""});
            shown("p1");
            compare(named("secretTitle").text, "Connection Request from “<b>Admin</b> keyboard”");
            compare(named("secretTitle").textFormat, Text.PlainText);
            compare(named("secretGlyph").name, "bluetooth");
            clickPastGuard();
            tryVerify(() => named("secretField").activeFocus);
            typeText("00-00");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0);
            compare(named("secretError").text, "A PIN has 1 to 16 letters or digits.");
            clickPastGuard();
            tryVerify(() => named("secretField").activeFocus);
            typeText("0000");
            mouseClick(named("secretOk"));
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "ok", password: "0000"});
        }
    }
}
