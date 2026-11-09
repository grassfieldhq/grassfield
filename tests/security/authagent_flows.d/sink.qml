import QtQuick
import QtTest
import qs.security

// The polkit agent's key sink (AuthAgent.qml in the harness authagent_flows.sh generates; it runs this file as tst_sink.qml).
// When a request replaces the one the user was typing into, the keyboard stays with the window, on the sink: nothing typed
// reaches the new request's field, whatever moves the focus (re-check of b5d7657, MEDIUM-2; check of 38dbfe8, MEDIUM-A), until
// a click past the guard. A request that ends while the sink has the keys leaves it lingering, so the rest of a password never
// reaches the window underneath (check of 38dbfe8, MEDIUM-B). Also the hold after a request (afterRequest).
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
            signal authenticationFailed
            signal authenticationSucceeded
            signal authenticationRequestCancelled
            function submit(p) {
                submits.push(p);
            }
            function cancelAuthenticationRequest() {
                cancels++;
            }
        }
    }

    // The generated agent, beside this file once authagent_flows.sh copied it (loaded by URL: in the tree there is none).
    readonly property Component agentC: Qt.createComponent(Qt.resolvedUrl("polkit/AgentUnderTest.qml"))

    TestCase {
        name: "Sink"
        when: windowShown

        property var ag: null

        function init() {
            SheetSession.locked = false;
            SheetSession.saverShown = false;
            SheetSession.displaysOff = false;
            compare(top.agentC.status, Component.Ready, top.agentC.errorString());
            ag = createTemporaryObject(top.agentC, top);
            verify(ag);
        }

        function mkflow(msg, extra) {
            return createTemporaryObject(flowC, top, Object.assign({message: msg}, extra || {}));
        }
        function arriveFlow(f) {
            ag.agentMock.isActive = true;
            ag.agentMock.flow = f;
        }
        function switchTo(f) {
            ag.agentMock.flow = f;
        }
        function endAll() {
            ag.agentMock.isActive = false;
            ag.agentMock.flow = null;
        }
        function dialog() {
            return ag.holderItem.item;
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
        function field() {
            return find(dialog(), i => i.submitted !== undefined && i.clear !== undefined && i.empty !== undefined);
        }
        function button(label) {
            return find(dialog(), i => i.text === label && i.clicked !== undefined);
        }
        // The card that says a request ended while the sink lingers (security counter-review of f9e24e1, LOW-3).
        function notice() {
            return find(ag.sheet, i => i.objectName === "polkitEndedNotice");
        }
        function typeText(t) {
            for (const c of t)
                keyClick(c);
        }
        // A was replaced by B while the user typed into it: the keys on the sink.
        function sinkB(extraB) {
            const a = mkflow("A"), b = mkflow("B", extraB);
            arriveFlow(a);
            tryVerify(() => field() && field().activeFocus);
            typeText("sec");
            switchTo(b);
            compare(ag.sinkingKeys, true);
            compare(ag.sheet.takesKeys, true);
            verify(ag.sink.activeFocus, "the sink has the focus");
            verify(!field().activeFocus);
            return [a, b];
        }
        // Typed now, then Return: nothing reaches B, and the sink still has the focus.
        function expectNothingReaches(b, why) {
            typeText("ret");
            keyClick(Qt.Key_Return);
            verify(field().empty, why + ": the field stays empty");
            compare(b.submits.length, 0, why + ": nothing submitted");
            verify(ag.sink.activeFocus, why + ": the sink has the focus");
        }

        // MEDIUM-A: a press on the dim backdrop within the guard.
        function test_01_backdropClickWithinGuard() {
            const [a, b] = sinkB();
            compare(ag.model.heldClickAccepted(), false, "guard running");
            mouseClick(ag.sheet, 5, 5);
            compare(ag.sinkingKeys, true);
            expectNothingReaches(b, "a backdrop click within the guard");
        }

        // MEDIUM-A: a press on the field itself within the guard (the field takes the focus on a press).
        function test_02_fieldPressWithinGuard() {
            const [a, b] = sinkB();
            mouseClick(field(), 10, 5);
            expectNothingReaches(b, "a press on the field within the guard");
        }

        // A press on Allow within the guard: nothing submitted; Esc then cancels B (it fails closed).
        function test_03_allowPressWithinGuard() {
            const [a, b] = sinkB();
            mouseClick(button("Allow"));
            expectNothingReaches(b, "a press on Allow within the guard");
            keyClick(Qt.Key_Escape);
            compare(b.cancels, 1);
        }

        // MEDIUM-A: B fails on its own (its helper died, PAM failed); the sheet focuses its field after a failure.
        function test_04_failedWhileSinking() {
            const [a, b] = sinkB();
            b.authenticationFailed();
            expectNothingReaches(b, "B's own failure");
        }

        // Tab, Backtab and Space on an identity row change nothing.
        function test_05_tabSpaceIdentity() {
            const i1 = {displayName: "alice"}, i2 = {displayName: "root"};
            const [a, b] = sinkB({identities: [i1, i2], selectedIdentity: i1});
            keyClick(Qt.Key_Tab);
            keyClick(Qt.Key_Space);
            keyClick(Qt.Key_Backtab);
            keyClick(Qt.Key_Space);
            compare(b.selectedIdentity, i1, "no identity change");
            verify(!field().activeFocus);
            compare(b.cancels, 0);
            compare(b.submits.length, 0);
        }

        // MEDIUM-B: B ends while the keys are sunk: the window stays mapped and keeps them, then lets go a second after the last.
        function test_06_endWhileSinkingLingers() {
            const [a, b] = sinkB();
            endAll();
            compare(ag.lingering, true);
            compare(ag.sheet.visible, true, "still mapped");
            compare(ag.sheet.takesKeys, true, "the keyboard kept: the rest of a password reaches nothing underneath");
            verify(ag.sink.activeFocus);
            typeText("word");
            keyClick(Qt.Key_Return);
            compare(ag.lingering, true);
            tryCompare(ag, "lingering", false, 2000);
            compare(ag.sheet.takesKeys, false);
            compare(ag.sheet.visible, false);
            compare(ag.sinkingKeys, false);
        }

        // Each key keeps the linger, which ends anyway sinkLingerMaxMs after the request ended, while keys still come (check of
        // c1ca44f, L1: typing stopped at 2.4 s let the idle timer end it within the same bound).
        function test_06b_lingerCapped() {
            const [a, b] = sinkB();
            const start = Date.now();
            endAll();
            let endedAt = -1;
            for (let i = 0; i < 20 && endedAt < 0; i++) {
                wait(250);
                if (!ag.lingering)
                    endedAt = Date.now() - start;
                else
                    keyClick("x");
            }
            verify(endedAt >= 0, "the linger ended while a key came every 250 ms");
            verify(endedAt >= ag.model.sinkLingerMaxMs - 250 && endedAt <= ag.model.sinkLingerMaxMs + 600,
                   "at sinkLingerMaxMs, not before: " + endedAt + " ms");
        }

        // With no key after the request ended, the linger ends after heldAfterUnlockMs (its timers start with it).
        function test_06f_lingerEndsWithoutKeys() {
            const [a, b] = sinkB();
            endAll();
            compare(ag.lingering, true);
            tryCompare(ag, "lingering", false, ag.model.heldAfterUnlockMs + 500, "no key: the linger ends a second later");
            compare(ag.sheet.visible, false);
        }

        // A click, the lock or the screen saver ends the linger.
        function test_06c_clickEndsLinger() {
            const [a, b] = sinkB();
            endAll();
            mouseClick(ag.sheet, 5, 5);
            compare(ag.lingering, false);
            compare(ag.sheet.takesKeys, false);
        }
        function test_06d_lockEndsLinger() {
            const [a, b] = sinkB();
            endAll();
            SheetSession.locked = true;
            compare(ag.lingering, false);
            compare(ag.sheet.takesKeys, false);
            SheetSession.locked = false;
            compare(ag.lingering, false, "not back after the unlock");
            compare(ag.sheet.visible, false);
        }
        function test_06e_saverEndsLinger() {
            const [a, b] = sinkB();
            endAll();
            SheetSession.saverShown = true;
            compare(ag.lingering, false);
            compare(ag.sheet.takesKeys, false);
        }

        // A third request while sinking keeps sinking, its guard started over.
        function test_07_thirdWhileSinking() {
            const [a, b] = sinkB();
            const c = mkflow("C");
            switchTo(c);
            compare(ag.sinkingKeys, true);
            compare(ag.sheet.takesKeys, true);
            expectNothingReaches(c, "C");
            compare(ag.model.heldClickAccepted(), false, "guard restarted");
        }

        // MEDIUM-A: a click within the guard, then a third request: the sink still has the keys.
        function test_08_thirdAfterClickWithinGuard() {
            const [a, b] = sinkB();
            mouseClick(ag.sheet, 5, 5);
            const c = mkflow("C");
            switchTo(c);
            expectNothingReaches(c, "C after a click within the guard");
        }

        // The lock takes the sink's keys; after the unlock B is held without the keyboard, answered after a click.
        function test_09_lockWhileSinking() {
            const [a, b] = sinkB();
            SheetSession.locked = true;
            compare(ag.sinkingKeys, false);
            compare(ag.sheet.shown, false);
            SheetSession.locked = false;
            compare(ag.sheet.takesKeys, false);
            compare(ag.heldByLock, true);
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, true);
            compare(ag.sheet.takesKeys, true);
            tryVerify(() => field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(b.submits, ["pw"]);
        }

        // The screen saver takes the sink's keys; after it, a click past the guard gives the keyboard.
        function test_10_saverWhileSinking() {
            const [a, b] = sinkB();
            SheetSession.saverShown = true;
            compare(ag.sinkingKeys, false);
            compare(ag.sheet.takesKeys, false);
            SheetSession.saverShown = false;
            compare(ag.sheet.takesKeys, false);
            compare(ag.model.heldClickAccepted(), false);
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.sheet.takesKeys, true);
        }

        // After a click past the guard the field has the keys: Esc cancels as usual. Cancel within the guard works too.
        function test_11_escapeAfterClick() {
            const [a, b] = sinkB();
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.sinkingKeys, false);
            compare(ag.userFocused, true);
            tryVerify(() => field().activeFocus);
            keyClick(Qt.Key_Escape);
            compare(b.cancels, 1);
        }
        function test_12_cancelWithinGuard() {
            const [a, b] = sinkB();
            mouseClick(button("Cancel"));
            compare(b.cancels, 1);
        }

        // A key pressed into A and released after B replaced it, then autorepeat: nothing in B's field.
        function test_13_keyHeldAcrossSwitch() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a);
            tryVerify(() => field() && field().activeFocus);
            keyPress("k");
            switchTo(b);
            keyRelease("k");
            keyPress("k", Qt.NoModifier, -1);
            keyPress("k", Qt.NoModifier, -1);
            keyRelease("k");
            verify(field().empty);
        }

        // afterRequest: held within a second after another ended (answered), not after; no keyboard, its own notice.
        function test_14_afterRequestHold() {
            const a = mkflow("A"), b = mkflow("B"), c = mkflow("C");
            arriveFlow(a);
            compare(ag.heldByLock, false);
            tryVerify(() => field() && field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(a.submits, ["pw"]);
            endAll();
            compare(ag.lingering, false, "answered: no linger");
            arriveFlow(b);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "queued");
            compare(ag.sheet.takesKeys, false);
            compare(ag.sinkingKeys, false);
            endAll();
            wait(1200);
            arriveFlow(c);
            compare(ag.heldByLock, false, "after a second: not held");
            compare(ag.sheet.takesKeys, true);
        }

        // The hold after a request never lifts a lock's and keeps its reason.
        function test_15_afterRequestWithLock() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a);
            endAll();
            SheetSession.locked = true;
            arriveFlow(b);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "locked");
            SheetSession.locked = false;
            compare(ag.sheet.takesKeys, false);
        }

        function test_16_firstArrivalNotHeld() {
            arriveFlow(mkflow("A"));
            compare(ag.heldByLock, false);
            compare(ag.model.followsAnother(), false);
        }

        // Sinking, then a click past the guard: B gets only what is typed after the click.
        function test_17_answerAfterClick() {
            const [a, b] = sinkB();
            typeText("lost");
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.sinkingKeys, false);
            tryVerify(() => field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(b.submits, ["pw"], "only what was typed after the click");
            compare(a.submits.length, 0);
        }

        // B ends while sinking and C arrives during the linger: C is held and the sink keeps the keys.
        function test_18_nextDuringLinger() {
            const [a, b] = sinkB();
            endAll();
            compare(ag.lingering, true);
            const c = mkflow("C");
            arriveFlow(c);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "queued");
            compare(ag.sinkingKeys, true);
            compare(ag.sheet.takesKeys, true);
            tryVerify(() => field() !== null);
            expectNothingReaches(c, "C arrived during the linger");
            wait(ag.model.sinkLingerMaxMs + 300);
            compare(ag.sinkingKeys, true, "neither of the linger's timers touches a request's sink");
        }

        // C arrives during the linger more than a second after B ended (the hold after a request is over): still held, with
        // the sink, so a click past its guard gives it the keyboard.
        function test_18b_nextLateInLinger() {
            const [a, b] = sinkB();
            endAll();
            for (let i = 0; i < 4; i++) {
                wait(300);
                keyClick("x");
            }
            compare(ag.lingering, true);
            compare(ag.model.followsAnother(), false, "the hold after a request is over");
            const c = mkflow("C");
            arriveFlow(c);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "queued");
            compare(ag.sinkingKeys, true);
            tryVerify(() => field() !== null);
            expectNothingReaches(c, "C arrived late in the linger");
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, true);
            tryVerify(() => field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(c.submits, ["pw"]);
        }

        // The sink still holds once the event loop ran (no deferred reset).
        function test_19_sinkHoldsOverTime() {
            const [a, b] = sinkB();
            wait(50);
            compare(ag.sinkingKeys, true);
            compare(ag.sheet.takesKeys, true);
            typeText("x");
            verify(field().empty);
        }

        // LOW-1: Esc on the sink cancels the held request (fail closed); the sink then lingers.
        function test_20_escapeCancelsHeld() {
            const [a, b] = sinkB();
            keyClick(Qt.Key_Escape);
            compare(b.cancels, 1);
            compare(a.cancels, 0);
        }

        // M1: whatever order the request's end arrives in, the window is never unmapped nor lets the keyboard go for a moment
        // (a hidden PanelWindow is destroyed and made again; check of c1ca44f).
        function transitionsDuring(change) {
            const log = [];
            const onVisible = () => log.push("visible=" + ag.sheet.visible);
            const onKeys = () => log.push("takesKeys=" + ag.sheet.takesKeys);
            ag.sheet.visibleChanged.connect(onVisible);
            ag.sheet.takesKeysChanged.connect(onKeys);
            change();
            ag.sheet.visibleChanged.disconnect(onVisible);
            ag.sheet.takesKeysChanged.disconnect(onKeys);
            return log;
        }
        function test_22_endNeverUnmaps_data() {
            return [{tag: "isActive first", first: true}, {tag: "flow first", first: false}];
        }
        function test_22_endNeverUnmaps(d) {
            sinkB();
            const log = transitionsDuring(() => {
                if (d.first) {
                    ag.agentMock.isActive = false;
                    ag.agentMock.flow = null;
                } else {
                    ag.agentMock.flow = null;
                    ag.agentMock.isActive = false;
                }
            });
            compare(ag.lingering, true);
            compare(log, [], "neither visible nor takesKeys changed");
        }
        function test_23_arrivalInLingerNeverUnmaps_data() {
            return [{tag: "isActive first", first: true}, {tag: "flow first", first: false}];
        }
        function test_23_arrivalInLingerNeverUnmaps(d) {
            sinkB();
            endAll();
            const c = mkflow("C");
            const log = transitionsDuring(() => {
                if (d.first) {
                    ag.agentMock.isActive = true;
                    ag.agentMock.flow = c;
                } else {
                    ag.agentMock.flow = c;
                    ag.agentMock.isActive = true;
                }
            });
            compare(log, [], "neither visible nor takesKeys changed");
        }

        // M2: the sheet's field and identity rows take no focus while the sink has the keys, and get it back after the click.
        function test_24_inputDisabledWhileSinking() {
            const i1 = {displayName: "alice"}, i2 = {displayName: "root"};
            const [a, b] = sinkB({identities: [i1, i2], selectedIdentity: i1});
            compare(dialog().inputEnabled, false);
            compare(field().enabled, false);
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(dialog().inputEnabled, true);
            tryVerify(() => field().activeFocus);
        }

        // A request answered as usual (not sinking) leaves no linger: sent, cancelled with Esc, or with Cancel.
        function test_21_noLingerAfterAnAnswer_data() {
            return [{tag: "sent", how: "send"}, {tag: "Esc", how: "escape"}, {tag: "Cancel", how: "button"}];
        }
        function test_21_noLingerAfterAnAnswer(d) {
            const a = mkflow("A");
            arriveFlow(a);
            tryVerify(() => field() && field().activeFocus);
            typeText("pw");
            if (d.how === "send") {
                keyClick(Qt.Key_Return);
                compare(a.submits, ["pw"]);
                // The usual end of a sent password: polkit says it succeeded, then the request ends (no linger either way).
                a.authenticationSucceeded();
            } else if (d.how === "escape") {
                keyClick(Qt.Key_Escape);
                compare(a.cancels, 0, "the first Esc empties the field (PasswordField)");
                compare(ag.model.answered, false);
                keyClick(Qt.Key_Escape);
                compare(a.cancels, 1);
            } else {
                mouseClick(button("Cancel"));
                compare(a.cancels, 1);
            }
            compare(ag.model.answered, true);
            endAll();
            compare(ag.lingering, false);
            compare(ag.sheet.visible, false);
            compare(ag.sheet.takesKeys, false);
        }

        // Security counter-review of f9e24e1 (LOW-1): A ends unanswered while the user types into its own field (its requester
        // gave up): the window stays mapped and keeps the keyboard on the sink, A's field is gone, nothing typed reaches
        // anything, and a notice says the request ended (LOW-3); the linger ends as any other: no key for a second, a click, the
        // lock, the screen saver.
        function test_25_endWhileTypingOwnField_data() {
            return [{tag: "no key", how: "idle"}, {tag: "click", how: "click"}, {tag: "click on the notice", how: "noticeClick"},
                    {tag: "lock", how: "lock"}, {tag: "saver", how: "saver"}];
        }
        function test_25_endWhileTypingOwnField(d) {
            const a = mkflow("A");
            arriveFlow(a);
            tryVerify(() => field() && field().activeFocus);
            compare(notice().visible, false, "no notice while the sheet shows");
            typeText("sec");
            endAll();
            compare(ag.lingering, true, "the sink lingers");
            compare(ag.sheet.visible, true, "still mapped");
            compare(ag.sheet.takesKeys, true, "the keyboard kept");
            verify(ag.sink.activeFocus, "the sink has the keys");
            compare(dialog(), null, "A's sheet is gone");
            compare(notice().visible, true, "the notice shows");
            verify(find(notice(), i => i.text === "Request cancelled") !== null, "it says the request is gone");
            verify(find(notice(), i => i.text === "What you type is ignored for a moment.") !== null, "and that typing goes nowhere");
            verify(find(notice(), i => i.activeFocusOnTab === true || i.focus === true) === null, "it takes no focus");
            typeText("ret");
            keyClick(Qt.Key_Return);
            keyClick(Qt.Key_Escape);
            compare(a.submits.length, 0);
            compare(a.cancels, 0, "Esc on the lingering sink answers nothing");
            compare(ag.lingering, true);
            if (d.how === "idle") {
                tryCompare(ag, "lingering", false, ag.model.heldAfterUnlockMs + 500);
            } else if (d.how === "click") {
                mouseClick(ag.sheet, 5, 5);
            } else if (d.how === "noticeClick") {
                mouseClick(notice());
            } else if (d.how === "lock") {
                SheetSession.locked = true;
            } else {
                SheetSession.saverShown = true;
            }
            compare(ag.lingering, false, "the linger ended");
            compare(ag.sheet.takesKeys, false);
            compare(notice().visible, false, "the notice goes with it");
            SheetSession.locked = false;
            SheetSession.saverShown = false;
            compare(ag.sheet.visible, false, "nothing mapped after it");
        }

        // The window never unmaps nor lets the keyboard go for a moment when A ends under the typing, whichever order its end
        // arrives in (a hidden PanelWindow is destroyed and made again; check of c1ca44f, M1).
        function test_25b_endWhileTypingNeverUnmaps_data() {
            return [{tag: "isActive first", first: true}, {tag: "flow first", first: false}];
        }
        function test_25b_endWhileTypingNeverUnmaps(d) {
            const a = mkflow("A");
            arriveFlow(a);
            tryVerify(() => field() && field().activeFocus);
            typeText("sec");
            const log = transitionsDuring(() => {
                if (d.first) {
                    ag.agentMock.isActive = false;
                    ag.agentMock.flow = null;
                } else {
                    ag.agentMock.flow = null;
                    ag.agentMock.isActive = false;
                }
            });
            compare(ag.lingering, true);
            compare(log, [], "neither visible nor takesKeys changed");
        }

        // A wrong password, then the user types again and the requester gives up: the answer counted only until polkit asked
        // again, so the sink lingers.
        function test_26_failedThenEndedWhileTyping() {
            const a = mkflow("A");
            arriveFlow(a);
            tryVerify(() => field() && field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(ag.model.answered, true);
            a.authenticationFailed();
            compare(ag.model.answered, false, "polkit asks again");
            tryVerify(() => field().activeFocus);
            typeText("pw2");
            endAll();
            compare(ag.lingering, true);
            typeText("x");
            compare(a.submits, ["pw"]);
        }

        // A held request the user never clicked (it never had the keyboard) ends: no linger, nothing mapped.
        function test_27_heldUnclickedEndsWithoutLinger() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a);
            tryVerify(() => field() && field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            endAll();
            arriveFlow(b);
            compare(ag.heldByLock, true);
            compare(ag.sheet.takesKeys, false);
            endAll();
            compare(ag.lingering, false);
            compare(ag.sheet.visible, false);
        }

        // The notice shows only while the sink lingers: not with a held request's sink, not once the next request came.
        function test_28_noticeOnlyWhileLingering() {
            const [a, b] = sinkB();
            compare(notice().visible, false, "a held request's sink shows the sheet, no notice");
            endAll();
            compare(notice().visible, true);
            const c = mkflow("C");
            arriveFlow(c);
            compare(ag.sinkingKeys, true);
            compare(notice().visible, false, "C's sheet replaces the notice");
            tryVerify(() => field() !== null);
        }
    }
}
