import QtQuick
import QtTest
import qs.security

// The polkit agent (AuthAgent.qml in the harness authagent_flows.sh generates; it runs this file as tst_flows.qml) through the
// request orders Quickshell 0.3.1 produces: a first request (isActive and flow set in either order), one replacing the open
// request (the flow changes, isActive stays true), back-to-back requests, the lock and the screen saver. Real key and mouse
// events.
Item {
    id: top
    width: 800
    height: 600

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
            // test_27: what Quickshell does inside a cancel (the request ends there), else nothing.
            property var onCancel: null
            function submit(p) {
                submits.push(p);
            }
            function cancelAuthenticationRequest() {
                cancels++;
                if (onCancel)
                    onCancel();
            }
        }
    }

    // The generated agent, beside this file once authagent_flows.sh copied it (loaded by URL: in the tree there is none).
    readonly property Component agentC: Qt.createComponent(Qt.resolvedUrl("polkit/AgentUnderTest.qml"))

    TestCase {
        name: "AgentFlows"
        when: windowShown

        property var ag: null

        function init() {
            SheetSession.locked = false;
            SheetSession.saverShown = false;
            SheetSession.displaysOff = false;
            SheetSession.starting = false;
            SheetSession.sleeping = false;
            compare(top.agentC.status, Component.Ready, top.agentC.errorString());
            ag = createTemporaryObject(top.agentC, top);
            verify(ag);
        }

        function mkflow(msg) {
            return createTemporaryObject(flowC, top, {message: msg});
        }
        function arriveFlow(f, isActiveFirst) {
            if (isActiveFirst) {
                ag.agentMock.isActive = true;
                ag.agentMock.flow = f;
            } else {
                ag.agentMock.flow = f;
                ag.agentMock.isActive = true;
            }
        }
        // Quickshell 0.3.1: the active flow goes from A to B at once, isActive stays true.
        function switchTo(f) {
            ag.agentMock.flow = f;
        }
        function endAll(isActiveFirst) {
            if (isActiveFirst) {
                ag.agentMock.isActive = false;
                ag.agentMock.flow = null;
            } else {
                ag.agentMock.flow = null;
                ag.agentMock.isActive = false;
            }
        }
        function dialog() {
            return ag.holderItem.item;
        }
        function find(item, pred) {
            if (pred(item))
                return item;
            for (let i = 0; i < item.children.length; i++) {
                const r = find(item.children[i], pred);
                if (r)
                    return r;
            }
            return null;
        }
        function field() {
            return find(dialog(), i => i.submitted !== undefined && i.clear !== undefined && i.empty !== undefined);
        }
        function button(label) {
            return find(dialog(), i => i.text === label && i.clicked !== undefined);
        }
        function typeText(t) {
            for (const c of t)
                keyClick(c);
        }

        // A first request, then its end. Answered (sent or cancelled) it leaves nothing mapped; ended by its requester while
        // the sheet has the keyboard, the sink keeps it a moment (the user may be typing its password; security
        // counter-review of f9e24e1, LOW-1).
        function test_00_firstArrival_data() {
            return [{tag: "isActive first, sent", first: true, answer: "send"}, {tag: "flow first, sent", first: false, answer: "send"},
                    {tag: "isActive first, cancelled", first: true, answer: "cancel"},
                    {tag: "isActive first, requester gave up", first: true, answer: ""},
                    {tag: "flow first, requester gave up", first: false, answer: ""}];
        }
        function test_00_firstArrival(d) {
            const a = mkflow("A");
            arriveFlow(a, d.first);
            verify(ag.model.active);
            compare(ag.shownFlow, a);
            compare(ag.heldByLock, false);
            compare(ag.sheet.takesKeys, true);
            tryVerify(() => field() && field().activeFocus);
            if (d.answer === "send") {
                typeText("pw");
                keyClick(Qt.Key_Return);
                compare(a.submits, ["pw"]);
            } else if (d.answer === "cancel") {
                keyClick(Qt.Key_Escape);
                compare(a.cancels, 1);
            }
            endAll(d.first);
            compare(ag.model.active, false);
            compare(ag.shownFlow, null);
            compare(ag.heldByLock, false);
            compare(ag.requestStartedAt, null);
            const lingers = d.answer === "";
            compare(ag.lingering, lingers, lingers ? "ended unanswered with the keyboard: the sink lingers" : "answered: no linger");
            compare(ag.sheet.visible, lingers, lingers ? "still mapped for the linger" : "a request answered as usual leaves nothing mapped");
            compare(ag.sheet.takesKeys, lingers);
        }

        // B replaces A while the user types A's password: held, emptied, the keys on the sink, the guard started over.
        function test_01_replacedWhileTyping() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            tryVerify(() => field() && field().activeFocus);
            typeText("secr");
            compare(field().empty, false);
            switchTo(b);
            compare(ag.model.message, "B");
            compare(ag.heldByLock, true, "B held");
            compare(ag.heldWhy, "queued");
            compare(ag.userFocused, false);
            compare(ag.sheet.takesKeys, true, "the keyboard kept, on the sink");
            compare(ag.sinkingKeys, true);
            compare(field().empty, true, "field emptied");
            compare(ag.model.heldClickAccepted(), false, "guard running");
            verify(dialog().heldNotice.indexOf("right after another one") !== -1);
            typeText("et");
            verify(field().empty, "keys typed after the switch reach no field");
            keyClick(Qt.Key_Return);
            compare(b.submits.length, 0, "and Return submits nothing");
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, false, "a click within the guard gives nothing");
            wait(600);
            verify(ag.model.heldClickAccepted());
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, true);
            compare(ag.sheet.takesKeys, true);
        }

        // Should Quickshell destroy the flow it abandons before it hands over the next one (0.3.1 overwrites it without deleting
        // it), the model's reference to it reads null and notifies: the open request ends there, under the user's typing, so
        // the sink lingers (security counter-review of f9e24e1, LOW-1: before, the rest of the password went to the window
        // underneath); B, handed over next, is held as one right after another, its field empty, and keeps the sink, as one
        // that arrives during a linger (sink.qml test_18). The agent's own state for a request in the sheet is a flag, never
        // the destroyed flow read back (review of 9ad4307..b38618f).
        function test_01b_oldFlowDestroyedBeforeTheNext() {
            const a = flowC.createObject(top, {message: "A"}), b = mkflow("B");
            arriveFlow(a, true);
            compare(ag.flowShown, true);
            tryVerify(() => field() && field().activeFocus);
            typeText("secr");
            a.destroy();
            wait(0);
            compare(ag.model.active, false, "the destroyed flow ends the open request");
            compare(ag.flowShown, false);
            compare(ag.shownFlow, null);
            compare(ag.lingering, true, "it ended under the typing: the sink keeps the keys");
            verify(ag.sink.activeFocus);
            typeText("et");
            switchTo(b);
            compare(ag.model.message, "B");
            compare(ag.flowShown, true);
            compare(ag.heldByLock, true, "B held");
            compare(ag.heldWhy, "queued");
            compare(ag.sinkingKeys, true, "B keeps the sink");
            compare(ag.sheet.takesKeys, true, "the keyboard stays on the sink, not B's field");
            tryVerify(() => field() !== null);
            compare(field().empty, true, "B's field starts empty");
            typeText("x");
            keyClick(Qt.Key_Return);
            verify(field().empty, "keys typed after B came reach no field");
            compare(b.submits.length, 0);
            compare(b.cancels, 0);
        }

        // A was held by the lock, the user clicked it; B replaces it: held again, on the sink, the guard started over.
        function test_02_replacedAfterClickThroughLockHold() {
            const a = mkflow("A"), b = mkflow("B");
            SheetSession.locked = true;
            arriveFlow(a, true);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "locked");
            compare(ag.sheet.shown, false);
            SheetSession.locked = false;
            compare(ag.sheet.shown, true);
            compare(ag.sheet.takesKeys, false);
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, true);
            switchTo(b);
            compare(ag.userFocused, false);
            compare(ag.heldByLock, true);
            compare(ag.sheet.takesKeys, true, "it had the keyboard: kept, on the sink");
            compare(ag.sinkingKeys, true);
            compare(ag.model.heldClickAccepted(), false);
        }

        // `pkexec a; pkexec b`: A answered, B comes right after A ended, through no request: held, without the keyboard.
        function test_03_endThenQuickNext() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            tryVerify(() => field() && field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(a.submits, ["pw"]);
            endAll(true);
            compare(ag.lingering, false, "answered: no linger");
            arriveFlow(b, true);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "queued");
            compare(ag.sheet.takesKeys, false);
        }

        // Within the guard, Cancel still cancels the held request (Cancel at worst), and Allow submits nothing.
        function test_04_cancelHeldWithinGuard() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            switchTo(b);
            mouseClick(button("Cancel"));
            compare(b.cancels, 1);
            compare(a.cancels, 0);
            compare(ag.userFocused, false);
        }
        function test_05_allowHeldWithinGuard() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            tryVerify(() => field() && field().activeFocus);
            typeText("pw");
            switchTo(b);
            mouseClick(button("Allow"));
            compare(b.submits.length, 0, "nothing submitted to B");
            compare(a.submits.length, 0);
        }

        // Past the guard, a click on the field gives it the keyboard: B is answered, then Esc cancels it.
        function test_06_answerHeldAfterClick() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            switchTo(b);
            wait(600);
            mouseClick(field());
            compare(ag.userFocused, true);
            tryVerify(() => field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(b.submits, ["pw"]);
            keyClick(Qt.Key_Escape);
            compare(b.cancels, 1);
        }

        // Replaced while locked: not mapped; after the unlock held, without the keyboard, the guard started when shown.
        function test_07_replacedWhileLocked() {
            const a = mkflow("A"), b = mkflow("B");
            SheetSession.locked = true;
            arriveFlow(a, true);
            switchTo(b);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "locked");
            compare(ag.sheet.shown, false);
            wait(600);
            SheetSession.locked = false;
            compare(ag.sheet.shown, true);
            compare(ag.model.heldClickAccepted(), false, "guard restarted when shown");
            compare(ag.sheet.takesKeys, false);
        }

        // Replaced under the screen saver: a click goes nowhere; when the saver ends the guard starts over.
        function test_08_replacedUnderSaver() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            SheetSession.saverShown = true;
            compare(ag.heldByLock, true);
            switchTo(b);
            compare(ag.heldByLock, true);
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, false, "the saver swallows the click");
            SheetSession.saverShown = false;
            compare(ag.model.heldClickAccepted(), false, "guard restarted at the saver's end");
            compare(ag.sheet.takesKeys, false);
        }

        // The same flow set again is not a new arrival.
        function test_10_sameFlowAgain() {
            const a = mkflow("A");
            arriveFlow(a, true);
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            switchTo(a);
            compare(ag.heldByLock, false);
            compare(ag.sheet.takesKeys, true);
        }

        // Under the saver, middle, right and left clicks on Cancel answer nothing.
        function test_11_buttonsSwallowedUnderSaver() {
            const a = mkflow("A");
            arriveFlow(a, true);
            SheetSession.saverShown = true;
            const c = button("Cancel");
            mouseClick(c, c.width / 2, c.height / 2, Qt.MiddleButton);
            mouseClick(c, c.width / 2, c.height / 2, Qt.RightButton);
            mouseClick(c);
            compare(a.cancels, 0);
        }

        // ADR-0045 OC-6 (security review of e3542510, MAJOR-2): no device answers a request the user cannot see and answer.
        // Quickshell runs PAM as soon as polkit asks; once pam_fprintd (or pam_u2f) talks without asking for a request whose
        // sheet is not on screen in front (locked away, under the saver, waiting behind a secret sheet) or that Quickshell
        // replaced, the agent refuses it (the requester is told no) before a touch meant for the lock screen or another request
        // can approve it. A sheet on screen in front may be answered by the reader, held or not (integrator decision after the
        // re-review, macOS model). PAM asking for a password ends nothing. The mock flow stays after a cancel unless the test
        // gives it Quickshell's end (onCancel): the tests count the cancels.
        function reader(f) {
            f.isResponseRequired = false;
            f.supplementaryMessage = "Place your right index finger on the fingerprint reader";
        }

        function test_20_shownRequestKeepsTheReaderUntilTheLock() {
            const a = mkflow("A");
            arriveFlow(a, true);
            compare(ag.heldByLock, false);
            reader(a);
            verify(ag.model.awaitingDevice);
            wait(1);
            compare(a.cancels, 0, "the user sees the sheet and may touch the reader");
            SheetSession.locked = true;
            tryCompare(a, "cancels", 1, 1000, "the lock came while the reader waited: refused at once");
            compare(a.submits.length, 0);
        }

        function test_21_arrivedLockedRefusedWhenPamReachesTheReader_data() {
            return [{tag: "isActive first", first: true}, {tag: "flow first", first: false}];
        }
        function test_21_arrivedLockedRefusedWhenPamReachesTheReader(d) {
            const a = mkflow("A");
            SheetSession.locked = true;
            arriveFlow(a, d.first);
            wait(1);
            compare(a.cancels, 0, "PAM said nothing yet");
            reader(a);
            tryCompare(a, "cancels", 1);
            compare(a.submits.length, 0);
        }

        // The macOS model kept for a password: PAM asks (pam_faillock's line above the prompt or not), the request waits
        // behind the lock and is shown, held, after the unlock.
        function test_22_passwordPromptWaitsBehindTheLock() {
            const a = mkflow("A");
            SheetSession.locked = true;
            arriveFlow(a, true);
            a.supplementaryMessage = "The account is locked due to 3 failed logins.";
            SheetSession.locked = false;
            compare(ag.sheet.shown, true);
            compare(ag.heldByLock, true);
            wait(1);
            compare(a.cancels, 0);
        }

        function test_23_underTheSaver() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            reader(a);
            SheetSession.saverShown = true;
            tryCompare(a, "cancels", 1, 1000, "open and awaiting the reader when the saver came");
            endAll(true);
            arriveFlow(b, true);
            reader(b);
            tryCompare(b, "cancels", 1, 1000, "arrived under the saver");
        }

        // Held and shown without the keyboard. Right after another request (Remote Login, Add Printer) the reader may answer it,
        // clicked or not. Just after an unlock it may not until the user clicks past its guard: a finger left on the reader
        // after unlocking would answer it, and the lock marker tells any process of the user's when to ask (opus re-review,
        // MINOR-1). The click hold keeps stray clicks and keys out either way.
        function test_24_heldShownReaderOnlyRightAfterAnother_data() {
            return [{tag: "just after the unlock", why: "unlock", refused: true}, {tag: "right after another one", why: "queued", refused: false}];
        }
        function test_24_heldShownReaderOnlyRightAfterAnother(d) {
            const a = mkflow("A"), b = mkflow("B"), c = mkflow("C");
            if (d.why === "unlock") {
                SheetSession.locked = true;
                SheetSession.locked = false;
            } else {
                arriveFlow(a, true);
                endAll(true);
            }
            arriveFlow(b, true);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, d.why);
            compare(ag.sheet.shown, true);
            compare(ag.userFocused, false);
            reader(b);
            if (d.refused) {
                tryCompare(b, "cancels", 1, 1000, "held just after the unlock: a finger left on the reader must not answer it");
            } else {
                wait(1);
                compare(b.cancels, 0, "held right after another one, on screen in front: a touch can only be meant for it");
            }
            compare(ag.sheet.takesKeys, ag.sinkingKeys, "the keys still wait for a click past the guard (or stay on the sink)");
            if (!d.refused)
                return;
            // Once the user clicked past its guard, the reader may answer a request held just after an unlock.
            endAll(true);
            wait(1100);
            SheetSession.locked = true;
            SheetSession.locked = false;
            arriveFlow(c, true);
            compare(ag.heldWhy, "unlock");
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, true);
            reader(c);
            wait(1);
            compare(c.cancels, 0, "clicked past its guard: the user turned to it");
        }

        // Settings' Remote Login asks twice in a row (systemd EnableUnitFiles, then StartUnit) and Add Printer up to three
        // times (cups-pk-helper PrinterAdd, PrinterSetEnabled, PrinterSetAcceptJobs), each request arriving right after the
        // previous one ended (held, "right after another one"): with a fingerprint reader every one is answered by a touch.
        function test_25_backToBackRequestsUseTheReader_data() {
            return [{tag: "Remote Login (enable, start)", count: 2}, {tag: "Add Printer (add, enable, accept jobs)", count: 3}];
        }
        function test_25_backToBackRequestsUseTheReader(d) {
            for (let i = 0; i < d.count; i++) {
                const f = mkflow("request " + i);
                arriveFlow(f, true);
                compare(ag.sheet.shown, true);
                compare(ag.heldByLock, i > 0, i > 0 ? "held: right after another one" : "the first one is not held");
                reader(f);
                wait(1);
                compare(f.cancels, 0, "request " + i + " is not refused");
                endAll(true); // the touch matched: polkit allowed it, Quickshell ends the request
            }
        }

        // Waiting behind a secret sheet (the model is handed nothing): the agent still guards the request Quickshell has open.
        function test_26_waitingBehindASecretSheet() {
            const q = createTemporaryObject(queueC, top);
            verify(q.addSecret("network"));
            ag.queue = q;
            compare(ag.waiting, true);
            const a = mkflow("A");
            arriveFlow(a, true);
            compare(ag.model.active, false, "not handed to the sheet");
            wait(1);
            compare(a.cancels, 0);
            reader(a);
            tryCompare(a, "cancels", 1);
        }

        // Quickshell ends the request inside cancelAuthenticationRequest (the session completes, the agent finishes it), so the
        // refusal's end runs inside the lock's or the saver's own change: the agent is left with no request, nothing mapped, no
        // sink, and the next request, still under the lock or the saver, is held and guarded as usual.
        function test_27_refusalEndsTheRequestInsideTheChange_data() {
            return [{tag: "lock", saver: false}, {tag: "saver", saver: true}];
        }
        function test_27_refusalEndsTheRequestInsideTheChange(d) {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            tryVerify(() => field() && field().activeFocus);
            typeText("pw");
            reader(a);
            a.onCancel = () => endAll(true);
            if (d.saver)
                SheetSession.saverShown = true;
            else
                SheetSession.locked = true;
            tryCompare(a, "cancels", 1);
            compare(a.submits.length, 0);
            compare(ag.model.active, false);
            compare(ag.requestOpen, false);
            compare(ag.sinkingKeys, false, "no sink left under the lock or the saver");
            compare(ag.sheet.visible, false);
            compare(ag.sheet.takesKeys, false);
            arriveFlow(b, true);
            compare(ag.heldByLock, true);
            compare(ag.sheet.takesKeys, false);
            wait(1);
            compare(b.cancels, 0, "PAM said nothing for B yet");
            reader(b);
            tryCompare(b, "cancels", 1, 1000, "the next request is guarded too (no binding left stale by the first end)");
            SheetSession.saverShown = false;
            SheetSession.locked = false;
        }

        // Opus re-review, MINOR-2: the displays are off for inactivity while the session is unlocked (SheetSession.displaysOff):
        // nobody sees the sheet, so the reader may not answer it (a reader in the power button pressed to wake the screen).
        function test_32_displaysOff() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            reader(a);
            wait(1);
            compare(a.cancels, 0, "on screen in front");
            SheetSession.displaysOff = true;
            tryCompare(a, "cancels", 1, 1000, "the displays went off while the reader waited");
            endAll(true);
            wait(1100);
            arriveFlow(b, true);
            compare(ag.heldByLock, false, "not held: the displays being off holds nothing");
            reader(b);
            tryCompare(b, "cancels", 1, 1000, "arrived while the displays were off");
        }

        // Held because it arrived while locked, its PAM asking for a password (nothing refused), shown after the unlock: should
        // its PAM then reach the reader, it is refused unless clicked (only "right after another one" counts).
        function test_33_heldLockedThenTheReader() {
            const a = mkflow("A");
            SheetSession.locked = true;
            arriveFlow(a, true);
            SheetSession.locked = false;
            compare(ag.sheet.shown, true);
            compare(ag.heldWhy, "locked");
            wait(1);
            compare(a.cancels, 0, "a password prompt waits for the user");
            reader(a);
            tryCompare(a, "cancels", 1);
        }

        // A request held right after another one keeps that reason when the screen saver comes over it (the notice keeps the
        // first reason): the saver itself must still refuse its reader prompt (`answerable` reads the saver, not only the hold).
        function test_34_heldRightAfterAnotherUnderTheSaver() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            endAll(true);
            arriveFlow(b, true);
            compare(ag.heldWhy, "queued");
            SheetSession.saverShown = true;
            compare(ag.heldWhy, "queued", "the first reason is kept");
            reader(b);
            tryCompare(b, "cancels", 1, 1000, "under the saver nobody sees the sheet");
        }

        // Opus re-review, MAJOR-1: Quickshell replaces an open request instead of queuing it and leaves the replaced one running,
        // its PAM included, with no sheet. The reviewer's probe: locked; A arrives; B replaces A; A then waits for the reader.
        // A must be refused, and B first (refusing A ends whatever request is current in Quickshell, B unanswered otherwise).
        function test_28_replacedRequestRefusedWhenItTalks_data() {
            return [{tag: "locked (the reviewer's probe)", locked: true}, {tag: "unlocked", locked: false}];
        }
        function test_28_replacedRequestRefusedWhenItTalks(d) {
            const a = mkflow("A"), b = mkflow("B"), order = [];
            a.onCancel = () => order.push("A");
            b.onCancel = () => order.push("B");
            SheetSession.locked = d.locked;
            arriveFlow(a, true);
            switchTo(b);
            compare(ag.model.message, "B");
            wait(1);
            compare(a.cancels + b.cancels, 0, "nothing refused while the replaced request says nothing");
            reader(a);
            tryCompare(a, "cancels", 1, 1000, "the replaced request is refused once its PAM reaches the reader");
            compare(b.cancels, 1, "with the request in the sheet");
            compare(order, ["B", "A"], "the current request first");
            compare(a.submits.length + b.submits.length, 0);
        }

        // Replaced while it already waited for the reader in the sheet the user saw: refused at once, with its replacement.
        function test_29_replacedWhileAwaitingTheReader() {
            const a = mkflow("A"), b = mkflow("B"), order = [];
            a.onCancel = () => order.push("A");
            b.onCancel = () => order.push("B");
            arriveFlow(a, true);
            reader(a);
            wait(1);
            compare(a.cancels, 0, "shown in front: the reader may answer it");
            switchTo(b);
            tryCompare(a, "cancels", 1);
            compare(order, ["B", "A"]);
        }

        // A replaced request that asks for a password is left as Quickshell leaves it (nobody can type into it): its
        // replacement is answered as usual, the reader included.
        function test_30_replacedAskingAPasswordEndsNothing() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            switchTo(b);
            a.supplementaryMessage = "The account is locked due to 3 failed logins.";
            reader(b);
            wait(1);
            compare(a.cancels + b.cancels, 0);
        }

        // With Quickshell's end: B's cancel ends the request in the sheet (the agent sees no request), A's ends nothing more.
        // Nothing is left mapped or on the sink, and the next request is guarded as usual.
        function test_31_replacedRefusalWithQuickshellsEnd() {
            const a = mkflow("A"), b = mkflow("B"), c = mkflow("C");
            SheetSession.locked = true;
            arriveFlow(a, true);
            switchTo(b);
            b.onCancel = () => endAll(true);
            reader(a);
            tryCompare(a, "cancels", 1);
            compare(b.cancels, 1);
            compare(ag.model.active, false);
            compare(ag.sinkingKeys, false);
            compare(ag.sheet.visible, false);
            arriveFlow(c, true);
            reader(c);
            tryCompare(c, "cancels", 1, 1000, "still locked: the next request is refused too");
            compare(a.cancels, 1, "A refused once");
        }

        // ADR-0041 S3, the opus review's MINOR-3 and its delta review's MAJOR-1: refused (another agent held the session: an
        // earlier UI after an upgrade, a restart in the wrong order), the agent is made again with a backoff, and the new one
        // asks again (Quickshell asks only when an agent is made; a later path is refused). Each one is made once the last one
        // is gone (none made inert: never two at once), and the asking stops once one is registered, which is kept. It
        // answers nothing meanwhile. tests/security/authagent_registration.sh counts the same on a real Quickshell.
        function test_36_registrationAskedAgainWhileRefused() {
            const a = createTemporaryObject(top.agentC, top, {mockRefused: true, registrationRetryMs: 100});
            verify(a);
            compare(a.mockRegistrations, 1, "asked once, when made");
            compare(a.registered, false);
            const first = a.agentMock;
            for (let n = 2; n <= 4; n++)
                tryCompare(a, "mockRegistrations", n, 5000, "made again: the new agent asks again");
            verify(a.agentMock !== first, "a new agent");
            compare(a.agentMock.path, "/org/grassfield/PolkitAgent");
            compare(a.mockInert, 0, "each one made once the last one was gone");
            compare(a.registrationTries, 3);
            // 100, 200 then 400 ms apart (a coarse timer may fire up to 5 % early).
            const t = a.mockTimes;
            verify(t[1] - t[0] >= 90, "first wait " + (t[1] - t[0]));
            verify(t[2] - t[1] >= 180, "second wait, doubled: " + (t[2] - t[1]));
            verify(t[3] - t[2] >= 360, "third wait, doubled: " + (t[3] - t[2]));
            a.mockRefused = false;
            tryVerify(() => a.registered, 5000, "the next one registers");
            const tries = a.registrationTries;
            const made = a.mockRegistrations;
            const kept = a.agentMock;
            wait(2 * a.registrationRetryInterval);
            compare(a.registrationTries, tries, "registered: no more asking");
            compare(a.mockRegistrations, made);
            verify(a.agentMock === kept, "the registered agent is kept");
            compare(a.mockInert, 0);
            compare(a.model.active, false, "nothing was answered or shown meanwhile");
        }

        // Never in a dev session: the nested agent asks once, and never takes the owner's session when the owner's agent restarts.
        function test_37_noAskingAgainInADevSession() {
            const a = createTemporaryObject(top.agentC, top, {mockRefused: true, devSession: true, registrationRetryMs: 40});
            verify(a);
            wait(400);
            compare(a.registrationTries, 0);
            compare(a.mockRegistrations, 1, "asked once, when made");
            a.retryRegistration();
            wait(50);
            compare(a.mockRegistrations, 1, "not even when asked directly");
            compare(a.registrationTries, 0);
        }

        // The delta review's MAJOR-1, item 2: the retry never lets go of a registered agent, nor of one with a request open
        // (polkit hands requests to a registered agent only; kept all the same).
        function test_38_aRegisteredAgentOrARequestIsNeverLetGo() {
            verify(ag.registered);
            const kept = ag.agentMock;
            ag.retryRegistration();
            wait(50);
            verify(ag.agentMock === kept, "registered: kept");
            compare(ag.mockRegistrations, 1);
            compare(ag.registrationTries, 0);
            const a = createTemporaryObject(top.agentC, top, {mockRefused: true, registrationRetryMs: 60000});
            verify(a);
            const f = mkflow("A");
            a.agentMock.isActive = true;
            a.agentMock.flow = f;
            const held = a.agentMock;
            a.retryRegistration();
            wait(50);
            verify(a.agentMock === held, "a request open: kept");
            compare(a.registrationTries, 0);
            compare(a.mockRegistrations, 1);
            compare(f.submits, []);
        }

        // The opus delta review of S3, LOW: held because the security process had just started (the saver counted for the start
        // alone, SheetSession.starting), the notice says so; held by the saver's own count, it still names the saver.
        function test_40_heldWhileStarting() {
            SheetSession.saverShown = true;
            SheetSession.starting = true;
            const a = mkflow("A");
            arriveFlow(a, true);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "starting");
            verify(dialog().heldNotice.indexOf("while Grassfield was starting") !== -1, dialog().heldNotice);
            endAll(true);
            SheetSession.starting = false;
            const b = mkflow("B");
            arriveFlow(b, true);
            compare(ag.heldWhy, "saver");
            verify(dialog().heldNotice.indexOf("while the screen saver was on") !== -1, dialog().heldNotice);
            SheetSession.saverShown = false;
        }

        // The backoff: registrationRetryMs (3 s) doubled at each try, at most 60 s.
        function test_39_registrationBackoff() {
            const waits = [];
            for (let n = 0; n <= 6; n++) {
                ag.periodTries = n;
                waits.push(ag.registrationRetryInterval);
            }
            ag.periodTries = 40;
            waits.push(ag.registrationRetryInterval);
            compare(waits, [3000, 6000, 12000, 24000, 48000, 60000, 60000, 60000]);
            compare(ag.registrationTriesMax, 4, "3, 6, 12 and 24 s, then not before the next unlock");
        }

        // The opus review of S3, round 2, MINOR-A: Quickshell asks polkitd with a synchronous call on the security process's
        // main thread, so the agent is never made again while the session is locked, the displays are off or a sleep is
        // under way (a hung polkitd would stop the lock, or the lock before a sleep). It asks again once that ends.
        function test_41_noRetryWhileQuiet_data() {
            return [{tag: "locked", key: "locked"}, {tag: "displays off", key: "displaysOff"}, {tag: "sleep under way", key: "sleeping"}];
        }
        function test_41_noRetryWhileQuiet(d) {
            const a = createTemporaryObject(top.agentC, top, {mockRefused: true, registrationRetryMs: 40});
            verify(a);
            SheetSession[d.key] = true;
            wait(400);
            compare(a.registrationTries, 0, "no try while " + d.tag);
            compare(a.mockRegistrations, 1, "the start's attempt only");
            SheetSession[d.key] = false;
            tryCompare(a, "mockRegistrations", 2, 3000, "asked again once that ends");
            compare(a.mockInert, 0);
        }

        // A try whose agent is due in the turn the session locks is dropped: no agent is made behind the lock; the next unlock
        // makes it, in a new period.
        function test_42_aTryAtTheLockIsDropped() {
            const a = createTemporaryObject(top.agentC, top, {mockRefused: true, registrationRetryMs: 60000});
            verify(a);
            a.retryRegistration();
            SheetSession.locked = true;
            wait(100);
            compare(a.agentMock, null, "no agent made while locked");
            compare(a.mockRegistrations, 1);
            a.registrationRetryMs = 40;
            SheetSession.locked = false;
            tryCompare(a, "mockRegistrations", 2, 3000, "the next unlock makes it");
            compare(a.periodTries, 1, "in a new period");
            compare(a.mockInert, 0);
        }

        // At most registrationTriesMax tries per unlock period, then none until the next unlock.
        function test_43_capPerUnlockPeriod() {
            const a = createTemporaryObject(top.agentC, top, {mockRefused: true, registrationRetryMs: 20});
            verify(a);
            tryCompare(a, "registrationTries", 4, 5000);
            wait(800);
            compare(a.registrationTries, 4, "four tries in the period (a fifth would have come 320 ms after the fourth)");
            compare(a.mockRegistrations, 5);
            SheetSession.locked = true;
            wait(100);
            compare(a.registrationTries, 4);
            SheetSession.locked = false;
            tryCompare(a, "registrationTries", 8, 5000, "an unlock starts a new period");
            wait(800);
            compare(a.registrationTries, 8, "four more, no more");
            compare(a.mockRegistrations, 9);
            compare(a.mockInert, 0);
        }

        // An attempt that stops the event loop (a hung polkitd: Quickshell's call is synchronous) stops the tries until the
        // next unlock, which starts again.
        function test_44_aStallStopsTheTries() {
            const a = createTemporaryObject(top.agentC, top, {mockRefused: true, registrationRetryMs: 300});
            verify(a);
            a.mockBlockMs = 1500;
            tryCompare(a, "mockRegistrations", 2, 3000);
            tryCompare(a, "registrationStalled", true, 5000, "the stall is seen");
            wait(1500);
            compare(a.registrationTries, 1, "no try after the stall (the next was due 600 ms after the first)");
            compare(a.mockRegistrations, 2);
            a.mockBlockMs = 0;
            SheetSession.locked = true;
            SheetSession.locked = false;
            compare(a.registrationStalled, false, "an unlock forgets the stall");
            tryCompare(a, "registrationTries", 2, 3000, "asked again after the next unlock");
            tryCompare(a, "mockRegistrations", 3, 3000);
        }

        // ADR-0041 S3: the agent runs in the security process, which restarts (Restart=always) after a crash or a stop. Its end
        // with a request open, a password half typed, answers nothing: no password goes out, nothing is approved; polkitd
        // then ends the request with the agent's bus name ("not authorized"), as when the UI restarted before S3. The agent
        // made again (the restarted process) starts with no request, no sheet and no keys, and the next request is held or
        // shown by the usual rules only.
        function test_35_theProcessEndsWithARequestOpen() {
            const a = mkflow("A");
            arriveFlow(a, true);
            tryVerify(() => field() && field().activeFocus);
            typeText("half");
            compare(field().empty, false);
            ag.destroy();
            wait(50);
            compare(a.submits, [], "nothing sent at the end");
            compare(a.cancels, 0, "nothing answered at all: polkitd ends the request with the agent's bus name");
            ag = createTemporaryObject(top.agentC, top);
            verify(ag);
            compare(ag.model.active, false, "the restarted agent has no request");
            compare(ag.sheet.visible, false);
            compare(ag.sinkingKeys, false);
            compare(ag.sheet.takesKeys, false);
            const b = mkflow("B");
            arriveFlow(b, true);
            compare(ag.model.message, "B");
            tryVerify(() => field() && field().activeFocus);
            compare(field().empty, true, "the new request's field is empty");
            keyClick(Qt.Key_Escape);
            compare(b.cancels, 1);
            compare(b.submits, []);
        }
    }

    Component {
        id: queueC
        SheetQueue {}
    }
}
