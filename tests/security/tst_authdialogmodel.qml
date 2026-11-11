import QtQuick
import QtTest
import "../../shell/security/polkit"

// Polkit dialog model with a mock AuthFlow: cancel path, no auto-approve, password handling.
TestCase {
    id: test

    name: "AuthDialogModel"

    component MockFlow: QtObject {
        property string message: "Authentication is needed to run `/usr/bin/true' as the super user"
        property string actionId: "org.freedesktop.policykit.exec"
        property string iconName: ""
        property var identities: [{displayName: "ada"}]
        property var selectedIdentity: identities[0]
        property bool isResponseRequired: false
        property string inputPrompt: "Password: "
        property bool responseVisible: false
        property string supplementaryMessage: ""
        property bool supplementaryIsError: false
        property int submits: 0
        property int cancels: 0
        property var submitted: []
        property bool isCompleted: false

        signal authenticationFailed
        signal authenticationSucceeded
        signal authenticationRequestCancelled

        function submit(value: string): void {
            submits += 1;
            submitted = submitted.concat([value]);
        }

        function cancelAuthenticationRequest(): void {
            cancels += 1;
            authenticationRequestCancelled();
        }
    }

    Component {
        id: flowComponent
        MockFlow {}
    }

    Component {
        id: modelComponent
        AuthDialogModel {}
    }

    Component {
        id: spyComponent
        SignalSpy {}
    }

    property var flow: null
    property var model: null
    property var clearSpy: null

    function init() {
        flow = createTemporaryObject(flowComponent, test);
        model = createTemporaryObject(modelComponent, test);
        clearSpy = createTemporaryObject(spyComponent, test, {target: model, signalName: "clearRequested"});
        model.flow = flow;
    }

    function test_showsRequestDetails() {
        verify(model.active);
        compare(model.actionId, "org.freedesktop.policykit.exec");
        verify(model.message.indexOf("/usr/bin/true") !== -1);
        compare(model.identityName, "ada");
        compare(model.prompt, "Password");
    }

    // D-4: the action's theme icon is shown (with a lock badge); only a plain theme icon name passes.
    function test_iconNameIsAPlainThemeName() {
        compare(model.iconName, "");
        flow.iconName = "org.gnome.Software";
        compare(model.iconName, "org.gnome.Software");
        flow.iconName = "drive-harddisk_x-1";
        compare(model.iconName, "drive-harddisk_x-1");
        // The shared rule (NotificationPrefs.safeIconName, review of 2dfd992): also no leading ".", "-" or "_", no "..".
        const refused = ["/usr/share/icons/x.png", "file:///etc/passwd", "http://127.0.0.1:9/x.png", "../x", "a b", "image://icon/x", "x\ny", "‮x", "x".repeat(129),
            "..", ".hidden", "a..b", "-x", "_x"];
        for (let i = 0; i < refused.length; i++) {
            flow.iconName = refused[i];
            compare(model.iconName, "", JSON.stringify(refused[i]).slice(0, 40));
        }
        model.flow = null;
        compare(model.iconName, "");
    }

    function test_neverAutoApproves() {
        // Polkit asks, fails, asks again, sends info: the model never answers on its own.
        flow.isResponseRequired = true;
        flow.supplementaryMessage = "info";
        flow.authenticationFailed();
        flow.isResponseRequired = false;
        flow.isResponseRequired = true;
        compare(flow.submits, 0);
        compare(flow.cancels, 0);
    }

    function test_cancelCancelsAndClears() {
        flow.isResponseRequired = true;
        const clears = clearSpy.count;
        model.cancel();
        compare(flow.cancels, 1);
        compare(flow.submits, 0);
        verify(clearSpy.count > clears);
        verify(!model.submitted);
    }

    function test_cancelWithoutFlowIsSafe() {
        model.flow = null;
        verify(!model.active);
        model.cancel();
        compare(flow.cancels, 0);
    }

    function test_submitOnlyWhenAskedAndNonEmpty() {
        verify(!model.submit("pw")); // polkit did not ask
        flow.isResponseRequired = true;
        verify(!model.submit(""));
        compare(flow.submits, 0);
        verify(model.submit("pw"));
        compare(flow.submitted, ["pw"]);
        verify(model.submitted);
        verify(!model.submit("again")); // one answer per prompt
        compare(flow.submits, 1);
    }

    function test_failureClearsAndAllowsRetry() {
        flow.isResponseRequired = true;
        model.submit("wrong");
        const clears = clearSpy.count;
        flow.authenticationFailed();
        verify(clearSpy.count > clears);
        verify(!model.submitted);
        verify(model.feedbackIsError);
        compare(model.feedback, "Incorrect password. Try again.");
        verify(model.submit("second"));
        compare(flow.submits, 2);
    }

    // ADR-0045 OC-6 (security review): PAM said something and asks nothing (pam_fprintd's "Place your finger…", pam_u2f's
    // "Please touch…"): a device is awaited; the password field waits. Never for a bare "nothing asked" (keys typed before
    // pam_unix's first prompt must not be dropped), never once the answer was sent.
    function test_awaitingDeviceOnlyWhilePamTalksAndAsksNothing() {
        verify(!model.awaitingDevice, "nothing said, nothing asked: the field keeps the keys");
        flow.supplementaryMessage = "Place your right index finger on the fingerprint reader";
        verify(model.awaitingDevice);
        verify(!model.canSubmit);
        compare(model.feedback, "Place your right index finger on the fingerprint reader");
        flow.supplementaryMessage = " \n\t";
        verify(!model.awaitingDevice, "a message of blanks is no message");
        flow.supplementaryMessage = "Failed to match fingerprint";
        flow.supplementaryIsError = true;
        verify(model.awaitingDevice);
        // The password prompt comes: no longer awaiting, and the device's last line stays readable.
        flow.isResponseRequired = true;
        verify(!model.awaitingDevice);
        verify(model.canSubmit);
        compare(model.feedback, "Failed to match fingerprint");
        // Sent: never awaiting again until polkit asks or fails, whatever PAM then says.
        verify(model.submit("pw"));
        flow.isResponseRequired = false;
        flow.supplementaryMessage = "Please touch the FIDO authenticator.";
        verify(!model.awaitingDevice, "after the answer was sent");
        model.flow = null;
        verify(!model.awaitingDevice, "no request");
    }

    // A wrong password, then the next round waits for the fingerprint reader: the line under the intro is the device's
    // instruction, not the stale "Incorrect password" (counter-review of ADR-0045, LOW-2); the prompt brings it back.
    function test_theNextRoundsDeviceInstructionIsShownNotTheOldError() {
        flow.isResponseRequired = true;
        verify(model.submit("wrong"));
        flow.isResponseRequired = false;
        flow.authenticationFailed();
        compare(model.feedback, "Incorrect password. Try again.");
        flow.supplementaryMessage = "Place your right index finger on the fingerprint reader";
        verify(model.awaitingDevice);
        compare(model.feedback, "Place your right index finger on the fingerprint reader");
        verify(!model.feedbackIsError);
        flow.isResponseRequired = true;
        verify(!model.awaitingDevice);
        compare(model.feedback, "Incorrect password. Try again.");
        verify(model.feedbackIsError);
    }

    // pam_faillock's notice comes as information before the password prompt: it is not replaced when the prompt arrives.
    function test_aLockedAccountNoticeStaysUnderThePrompt() {
        flow.supplementaryMessage = "The account is locked due to 3 failed logins.";
        verify(model.awaitingDevice);
        flow.isResponseRequired = true;
        verify(!model.awaitingDevice);
        compare(model.feedback, "The account is locked due to 3 failed logins.");
        verify(!model.feedbackIsError);
    }

    // ADR-0045 OC-6 (security review of e3542510, MAJOR-2): a request the user cannot answer (`answerable` false, as the agent
    // sets it while locked, under the screen saver, waiting behind another sheet) is refused as soon as PAM talks
    // without asking: a device's instruction, a failed match, a security key's cue, any other line (when in doubt, no). The
    // request may be one this model is not handed (a secret sheet came first: `flow` null).
    function test_unansweredRequestRefusedWhenPamTalks() {
        const lines = [["Place your right index finger on the fingerprint reader", false], ["Failed to match fingerprint", true],
            ["Please touch the FIDO authenticator.", false], ["The account is locked due to 3 failed logins.", false]];
        model.flow = null;
        for (const [line, error] of lines) {
            const f = createTemporaryObject(flowComponent, test);
            model.request = f;
            verify(!model.answerable, "fails closed by default");
            verify(!model.refusesUnseen, "PAM said nothing yet: " + line);
            f.supplementaryIsError = error;
            f.supplementaryMessage = line;
            verify(model.refusesUnseen, line);
            tryCompare(f, "cancels", 1, 1000, line);
            compare(f.submits, 0, line);
            // Quickshell ends the refused request before it hands over the next one.
            f.isCompleted = true;
            model.request = null;
        }
        compare(flow.cancels, 0, "only the request PAM talks for");
    }

    // PAM asking for a password ends nothing (the sheet shows it after the unlock), with a line above the prompt or not; a
    // line of blanks is no line; no request, nothing to refuse.
    function test_passwordPromptWaitsForTheUser() {
        model.request = flow;
        flow.isResponseRequired = true;
        flow.supplementaryMessage = "The account is locked due to 3 failed logins.";
        verify(!model.refusesUnseen, "PAM asks: the request waits for the user");
        flow.supplementaryMessage = " \n\t";
        flow.isResponseRequired = false;
        verify(!model.refusesUnseen, "a line of blanks is no line");
        model.request = null;
        flow.supplementaryMessage = "Place your right index finger on the fingerprint reader";
        verify(!model.refusesUnseen, "no request");
        wait(1);
        compare(flow.cancels, 0);
    }

    // While the user can answer, the reader's instruction ends nothing; the moment that stops (the lock, the saver, a hold), the
    // request is refused, an answer sent or not (pam_unix before pam_fprintd: a wrong password, then the reader in the same
    // round), and it is refused once.
    function test_refusedWhenItStopsBeingAnswerable() {
        model.request = flow;
        model.answerable = true;
        flow.isResponseRequired = true;
        verify(model.submit("wrong"));
        flow.isResponseRequired = false;
        flow.supplementaryMessage = "Place your right index finger on the fingerprint reader";
        verify(!model.refusesUnseen);
        wait(1);
        compare(flow.cancels, 0);
        model.answerable = false;
        verify(model.refusesUnseen);
        compare(flow.cancels, 0, "from the event loop, not inside the binding's change");
        tryCompare(flow, "cancels", 1);
        flow.supplementaryMessage = "Failed to match fingerprint";
        wait(1);
        compare(flow.cancels, 1, "refused once while it stays unanswerable");
        compare(flow.submits, 1, "nothing sent but the user's own answer");
    }

    // Untrusted strings are flattened to one capped plain line (R12 review).
    function test_untrustedTextIsOneCappedLine() {
        compare(model.plainLine("a\nb\r\n\tc\u0007d\u009be", 100), "a b c d e");
        compare(model.plainLine("x\u2028y\u2029z", 100), "x y z");
        compare(model.plainLine("\u202eevil\u202c \u2066iso\u2069 \u200fmark\u200e", 100), "evil iso mark");
        compare(model.plainLine(undefined, 10), "");
        compare(model.plainLine(null, 10), "");
        compare(model.plainLine("abcdefghijkl", 5), "abcd\u2026");
        compare(model.plainLine("\u00e9 \u00fc \u65e5\u672c", 100), "\u00e9 \u00fc \u65e5\u672c");

        flow.message = "Run /usr/bin/true\n\nAction: org.example.fake\n" + "y".repeat(5000);
        verify(model.message.indexOf("\n") === -1);
        verify(model.message.length <= model.maxMessageLength);
        verify(model.message.endsWith("\u2026"));
        flow.actionId = "org.example\nAction: fake";
        compare(model.actionId, "org.example Action: fake");
        flow.supplementaryMessage = "line1\nline2";
        compare(model.feedback, "line1 line2");
        flow.selectedIdentity = {displayName: "root\n\u202eeve"};
        compare(model.identityName, "root eve");
    }

    // Grassfield Store's action (ADR-0037 b.1, SD2): the message polkit expands with the helper's argument vector is read by a
    // strict pattern, for this action id only, into "Install …" or "Remove …" and the program's path; anything else is shown
    // as polkit gives it.
    function test_storeRequestInPlainWords() {
        const helper = "/usr/lib/grassfield/grassfield-store-helper";
        const op = "0123456789abcdef0123456789abcdef";
        const en = "Authentication is required to install or remove apps: ";
        const fr = "Une authentification est n\u00e9cessaire pour installer ou supprimer des apps : ";
        flow.actionId = "org.grassfield.store.manage-packages";
        flow.message = en + helper + " install " + op + " xterm gimp";
        compare(model.storeRequest.verb, "install");
        compare(model.storeRequest.packages, ["xterm", "gimp"]);
        compare(model.message, "Install xterm, gimp");
        compare(model.program, helper);
        compare(model.actionId, "org.grassfield.store.manage-packages");

        flow.message = fr + helper + " remove " + op + " lib32-foo@1.2_x+y";
        compare(model.storeRequest.verb, "remove");
        compare(model.message, "Remove lib32-foo@1.2_x+y");

        const names = [];
        for (let i = 0; i < 64; i++)
            names.push("app" + i);
        flow.message = en + helper + " install " + op + " " + names.join(" ");
        compare(model.storeRequest.packages.length, 64);
        verify(model.message.length > model.maxMessageLength, "the names are not cut to the generic cap");

        // Not read: shown as polkit gives it, one capped line, and no program line.
        const refused = [
            en + helper + " install " + op + " " + names.concat(["app64"]).join(" "), // 65 names
            en + helper + " install " + op, // no name
            en + helper + " upgrade " + op + " xterm",
            en + helper + " install " + op.toUpperCase() + " xterm",
            en + helper + " install " + op + "0 xterm",
            en + helper + " install " + op + " xterm\nAction: org.example.fake",
            en + helper + " install " + op + " xterm ",
            en + helper + " install " + op + " -xterm",
            en + helper + " install " + op + " Xterm",
            en + "/usr/lib/grassfield/grassfield-store-helper2 install " + op + " xterm",
            en + "/tmp/grassfield-store-helper install " + op + " xterm",
            "Authentication is required: " + helper + " install " + op + " xterm",
            "x" + en + helper + " install " + op + " xterm",
            en + helper + " install " + op + " xterm\u202e",
            en + " " + helper + " install " + op + " xterm"
        ];
        for (const message of refused) {
            flow.message = message;
            compare(model.storeRequest, null, message);
            compare(model.program, "", message);
            compare(model.message, model.plainLine(message, model.maxMessageLength), message);
        }

        // Another action with the same message: not read.
        flow.actionId = "org.freedesktop.policykit.exec";
        flow.message = en + helper + " install " + op + " xterm";
        compare(model.storeRequest, null);
        compare(model.program, "");
        verify(model.message.indexOf(helper) !== -1);
    }

    // Review of 1d2c856: a held request takes the keyboard only through a click, and only heldGuardMs after it appeared.
    // Review of 6e24d36: both delays are timed by Timers (monotonic), not by the wall clock. The QML engine ignores writes
    // to Date.now, so a clock step cannot be faked here: tests/security/lock_surfaces.sh checks that the holds never read
    // Date (with mutants).
    function test_heldGuard() {
        compare(model.heldGuardMs, 500);
        verify(!model.heldClickAccepted(), "the sheet was never noted as shown: when in doubt, no");
        const start = Date.now();
        model.noteShown();
        verify(!model.heldClickAccepted(), "the instant it appeared");
        wait(250);
        verify(!model.heldClickAccepted(), "250 ms later");
        tryVerify(() => model.heldClickAccepted(), 3000, "the guard ends");
        verify(Date.now() - start >= 450, "not before about heldGuardMs (Qt coarse timers: 5%)");
        model.noteShown();
        verify(!model.heldClickAccepted(), "shown again: the guard starts over");
        const notice = model.heldNotice(new Date(2026, 9, 24, 14, 5).getTime(), "locked");
        verify(notice.indexOf("while the screen was locked") !== -1, notice);
        verify(notice.indexOf(Qt.formatTime(new Date(2026, 9, 24, 14, 5), Qt.locale().timeFormat(Locale.ShortFormat))) !== -1, notice);
        verify(model.heldNotice(Date.now(), "unlock").indexOf("just as the screen was unlocked") !== -1);
        // ADR-0032: held while the screen saver showed.
        verify(model.heldNotice(Date.now(), "saver").indexOf("while the screen saver was on") !== -1);
        // The opus delta review of S3, LOW: held for the security process's start alone, it says so, not the saver.
        const starting = model.heldNotice(Date.now(), "starting");
        verify(starting.indexOf("while Grassfield was starting. Click the sheet to answer it.") !== -1, starting);
        verify(starting.indexOf("screen saver") === -1, starting);
        // Review of f513b3b: a queued request that follows another in the same sheet is held too.
        verify(model.heldNotice(Date.now(), "queued").indexOf("right after another one") !== -1);
        // AuthAgent passes the arrival time as a Date (display only; shell/security reads no Date.now).
        compare(model.heldNotice(new Date(2026, 9, 24, 14, 5), "locked"), notice);
        // The screen saver ended over a held sheet: the guard starts over, so the click that woke the screen never counts.
        tryVerify(() => model.heldClickAccepted(), 3000, "the guard ended");
        model.noteUncovered();
        verify(!model.heldClickAccepted(), "uncovered: the guard starts over");
        tryVerify(() => model.heldClickAccepted(), 3000, "and ends again");
    }

    // Review of d8e654c: a request arriving within heldAfterUnlockMs after an unlock is held like one that arrived while locked.
    function test_heldJustAfterUnlock() {
        compare(model.heldAfterUnlockMs, 1000);
        verify(model.arrivesHeld(true), "while locked");
        verify(!model.arrivesHeld(false), "never unlocked since the start");
        const start = Date.now();
        model.noteUnlock();
        verify(model.arrivesHeld(false), "the instant of the unlock");
        verify(model.arrivesHeld(true), "while locked, whatever the last unlock");
        wait(500);
        verify(model.arrivesHeld(false), "half a second after the unlock");
        tryVerify(() => !model.arrivesHeld(false), 4000, "the hold ends");
        verify(Date.now() - start >= 900, "not before about heldAfterUnlockMs (Qt coarse timers: 5%)");
        verify(model.arrivesHeld(true), "locked again: held");
    }

    // Re-check of b5d7657 (MEDIUM-1): a request that arrives right after the previous one ended (`pkexec a; pkexec b`) is held
    // like one after an unlock, for heldAfterUnlockMs, timed by a Timer.
    function test_heldJustAfterAnotherRequest() {
        tryVerify(() => !model.arrivesHeld(false), 4000, "no hold left from an earlier test");
        verify(!model.followsAnother());
        const start = Date.now();
        model.noteEnded();
        verify(model.arrivesHeld(false), "the instant the previous one ended");
        verify(model.followsAnother());
        wait(500);
        verify(model.arrivesHeld(false), "half a second later");
        tryVerify(() => !model.arrivesHeld(false), 4000, "the hold ends");
        verify(!model.followsAnother());
        verify(Date.now() - start >= 900, "not before about heldAfterUnlockMs (Qt coarse timers: 5%)");
    }

    function test_newFlowResetsState() {
        flow.isResponseRequired = true;
        model.submit("pw");
        const other = createTemporaryObject(flowComponent, test);
        model.flow = other;
        verify(!model.submitted);
        compare(model.feedback, "");
        verify(!model.answered);
    }

    // Security counter-review of f9e24e1 (LOW-1): `answered` says the user sent or cancelled since polkit last asked. It
    // stays set when the request ends (the agent reads it then), and a refused submit (not asked, empty) is no answer.
    function test_answeredUntilAskedAgain() {
        verify(!model.answered);
        verify(!model.submit("pw"));
        verify(!model.answered, "a submit polkit did not ask for is no answer");
        flow.isResponseRequired = true;
        verify(!model.submit(""));
        verify(!model.answered, "nor an empty one");
        verify(model.submit("pw"));
        verify(model.answered);
        flow.isResponseRequired = false;
        verify(model.answered);
        flow.authenticationFailed();
        verify(!model.answered, "a failure asks again");
        flow.isResponseRequired = true;
        verify(model.submit("pw2"));
        verify(model.answered);
        flow.isResponseRequired = false;
        verify(model.answered);
        flow.isResponseRequired = true;
        verify(!model.answered, "a new prompt asks again");
        model.cancel();
        verify(model.answered);
        model.flow = null;
        verify(model.answered, "kept when the request ends");
        model.flow = createTemporaryObject(flowComponent, test);
        verify(!model.answered, "cleared for the next request");
    }
}
