import QtQuick
import QtQuick.Window
import QtTest
import qs.security

// The polkit agent in a window that behaves like Quickshell's PanelWindow (FakePanel.qml: made again each time it is shown,
// given the keyboard only once mapped; authagent_flows.sh runs this file as tst_window.qml with the --panel harness), beside
// the window underneath: this test window, whose field `under` has the keyboard whenever the panel does not (check of
// c1ca44f, M1 and M2).
Item {
    id: top
    width: 800
    height: 600

    TextInput {
        id: under
        width: 300
        height: 30
        focus: true
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

    // The generated agent with the faithful panel, beside this file once authagent_flows.sh copied it.
    readonly property Component agentC: Qt.createComponent(Qt.resolvedUrl("panel/AgentUnderTest.qml"))

    TestCase {
        name: "Window"
        when: windowShown

        property var ag: null

        function init() {
            SheetSession.locked = false;
            SheetSession.saverShown = false;
            SheetSession.displaysOff = false;
            SheetSession.starting = false;
            SheetSession.sleeping = false;
            under.text = "";
            compare(top.agentC.status, Component.Ready, top.agentC.errorString());
            ag = createTemporaryObject(top.agentC, top);
            verify(ag);
            ag.sheet.underneath = top.Window.window;
            top.Window.window.requestActivate();
            under.forceActiveFocus();
            wait(20);
        }

        function mkflow(msg) {
            return createTemporaryObject(flowC, top, {message: msg});
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
            return find(ag.holderItem.item, i => i.submitted !== undefined && i.clear !== undefined && i.empty !== undefined);
        }
        function typeText(t) {
            for (const c of t)
                keyClick(c);
        }
        // A arrives, its surface maps, the user types; B replaces A: the keys on the sink, nothing underneath.
        function sinkB() {
            const a = mkflow("A"), b = mkflow("B");
            ag.agentMock.isActive = true;
            ag.agentMock.flow = a;
            tryVerify(() => ag.sheet.mapped && field() && field().activeFocus, 1000, "A mapped with its field focused");
            wait(20);
            typeText("sec");
            ag.agentMock.flow = b;
            compare(ag.sinkingKeys, true);
            wait(20);
            typeText("re");
            verify(field().empty, "B's field stays empty");
            compare(under.text, "", "nothing underneath");
            return [a, b];
        }

        // The emulation itself: a request answered as usual, then the keys reach the window underneath again.
        function test_00_answeredAsUsual() {
            const a = mkflow("A");
            ag.agentMock.isActive = true;
            ag.agentMock.flow = a;
            tryVerify(() => ag.sheet.mapped && field() && field().activeFocus, 1000);
            wait(20);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(a.submits, ["pw"]);
            ag.agentMock.isActive = false;
            ag.agentMock.flow = null;
            wait(20);
            typeText("ls");
            compare(under.text, "ls");
        }

        // M1: B ends while the user types; the window is never made again, nothing reaches the window underneath.
        function test_01_endWhileTyping_data() {
            return [{tag: "isActive first", first: true}, {tag: "flow first", first: false}];
        }
        function test_01_endWhileTyping(d) {
            sinkB();
            const before = ag.sheet.recreations;
            if (d.first) {
                ag.agentMock.isActive = false;
                ag.agentMock.flow = null;
            } else {
                ag.agentMock.flow = null;
                ag.agentMock.isActive = false;
            }
            compare(ag.lingering, true);
            for (const c of "word") {
                wait(15);
                keyClick(c);
            }
            keyClick(Qt.Key_Return);
            compare(under.text, "", "nothing typed reaches the window underneath during the linger");
            compare(ag.sheet.recreations - before, 0, "the window was not made again: " + JSON.stringify(ag.sheet.events.slice(-6)));
        }

        // M2: B ends and C arrives at once, before the window has the keyboard: C's sheet focuses its field when it loads.
        function test_02_endThenArriveBeforeMap() {
            sinkB();
            ag.agentMock.isActive = false;
            ag.agentMock.flow = null;
            const c = mkflow("C");
            ag.agentMock.isActive = true;
            ag.agentMock.flow = c;
            compare(ag.sinkingKeys, true, "C held with the sink");
            compare(ag.heldByLock, true);
            tryVerify(() => ag.sheet.mapped, 1000);
            wait(20);
            typeText("pass");
            keyClick(Qt.Key_Return);
            compare(c.submits.length, 0, "nothing typed for A is submitted to C");
            compare(under.text, "");
            verify(ag.sink.activeFocus, "the sink has the keys");
        }

        // Security counter-review of f9e24e1 (LOW-1): A ends unanswered while the user types its password into A's own field
        // (its requester gave up, in either order, or Quickshell destroyed the flow): the window is never made again and the
        // rest of the password reaches nothing underneath; once the linger ends the keys reach the window underneath again.
        // (A request answered first gives them back at once: test_00.)
        function test_04_endWhileTypingOwnField_data() {
            return [{tag: "isActive first", how: "isActive"}, {tag: "flow first", how: "flow"}, {tag: "flow destroyed", how: "destroy"}];
        }
        function test_04_endWhileTypingOwnField(d) {
            const a = d.how === "destroy" ? flowC.createObject(top, {message: "A"}) : mkflow("A");
            ag.agentMock.isActive = true;
            ag.agentMock.flow = a;
            tryVerify(() => ag.sheet.mapped && field() && field().activeFocus, 1000, "A mapped with its field focused");
            wait(20);
            typeText("sec");
            const before = ag.sheet.recreations;
            if (d.how === "destroy") {
                a.destroy();
                wait(0);
            } else if (d.how === "isActive") {
                ag.agentMock.isActive = false;
                ag.agentMock.flow = null;
            } else {
                ag.agentMock.flow = null;
                ag.agentMock.isActive = false;
            }
            compare(ag.model.active, false);
            for (const c of "ret") {
                wait(15);
                keyClick(c);
            }
            keyClick(Qt.Key_Return);
            compare(under.text, "", "nothing typed after the end reaches the window underneath");
            compare(ag.sheet.recreations - before, 0, "the window was not made again: " + JSON.stringify(ag.sheet.events.slice(-6)));
            verify(ag.sink.activeFocus, "the sink has the keys");
            tryCompare(ag, "lingering", false, ag.model.sinkLingerMaxMs + 500);
            tryVerify(() => !ag.sheet.mapped, 1000);
            wait(20);
            typeText("ls");
            compare(under.text, "ls", "after the linger the keys reach the window underneath again");
        }

        // M2: B fails on its own while another surface has the keyboard; the sheet focuses its field after a failure.
        function test_03_failedWhileUnfocused() {
            const [a, b] = sinkB();
            top.Window.window.requestActivate();
            wait(20);
            b.authenticationFailed();
            ag.sheet.backing.requestActivate();
            wait(20);
            typeText("pass");
            keyClick(Qt.Key_Return);
            compare(b.submits.length, 0, "nothing reaches B");
            verify(ag.sink.activeFocus, "the sink has the keys");
        }
    }
}
