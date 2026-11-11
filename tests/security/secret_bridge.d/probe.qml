pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.security
import qs.security.secret

// The shell's real prompter/1 client in Quickshell (tests/security/secret_bridge.sh copies this as shell.qml next to links
// to the real shell modules; offscreen, no compositor). PROBE_MODE:
//   client  PrompterClient on PROBE_SOCKET, answering as a user would by the request's title: "answer-ok" (the password
//           "pw-<id>", or ok for a confirmation), "answer-cancel", "answer-twice" (a second answer must be refused),
//           "answer-late" (after the bridge withdrew it: refused), "leave" (no answer); an nm request (step 9c) by its SSID,
//           "answer-ok" (the password "pw-<id>"; for enterprise a name "user-<id>" too, which the client must not send) or
//           "answer-cancel"; a kio request (step 9e) by its server, "answer-ok.example" (the name "user-<id>" when asked, the
//           password "pw-<id>", Remember checked when offered) or "answer-cancel.example"; a bluetooth request (step 10) by its
//           device's name, "answer-ok" (a passkey "123456", or Connect; a code shown cannot be answered ok, which is tried),
//           and a code shown is cancelled once two digits are typed (`progressed`);
//   agent   the real SecretAgent with a SheetQueue, its dev socket PROBE_SOCKET; prints its dev state (devState) when it
//           changes.
// Prints "probe: <event>" lines; the test reads them and the fake bridge's PASS/FAIL lines.
ShellRoot {
    id: root

    settings.watchFiles: false

    readonly property string mode: Quickshell.env("PROBE_MODE")
    property var client: null
    property var agent: null
    property string lastState: ""

    function log(text: string): void {
        console.info("probe: " + text);
    }

    function answerAs(request: var): void {
        const c = root.client;
        if (request.kind === "bluetooth") {
            const mode = request.pairing.mode;
            root.log("prompted " + request.id + " bluetooth " + mode);
            if (request.device.name === "answer-ok")
                root.log("answer " + request.id + " " + c.answer(request.id, true, mode === "passkey" ? "123456" : null, false, null));
            return;
        }
        if (request.kind === "kio") {
            root.log("prompted " + request.id + " kio " + request.requester.role + " " + request.server + " " + request.login.nameMode + " " + request.login.remember + " " + request.login.keyring);
            if (request.server === "answer-ok.example")
                root.log("answer " + request.id + " " + c.answer(request.id, true, "pw-" + request.id, request.login.remember !== "none", request.login.nameMode === "edit" ? "user-" + request.id : null));
            else if (request.server === "answer-cancel.example")
                root.log("answer " + request.id + " " + c.answer(request.id, false, null, false, null));
            return;
        }
        if (request.kind === "nm") {
            const ssid = request.network.ssid;
            root.log("prompted " + request.id + " nm " + request.network.security);
            if (ssid === "answer-ok")
                root.log("answer " + request.id + " " + c.answer(request.id, true, "pw-" + request.id, false, request.network.security === "enterprise" ? "user-" + request.id : null));
            else if (ssid === "answer-cancel")
                root.log("answer " + request.id + " " + c.answer(request.id, false, null, false, null));
            return;
        }
        const title = request.texts.title;
        const password = request.kind === "password" ? "pw-" + request.id : null;
        const choice = request.choice !== null && request.choice.chosen;
        root.log("prompted " + request.id + " " + request.kind + " " + request.requester.role + " " + title);
        if (title === "answer-ok")
            root.log("answer " + request.id + " " + c.answer(request.id, true, password, choice, null));
        else if (title === "answer-cancel")
            root.log("answer " + request.id + " " + c.answer(request.id, false, null, choice, null));
        else if (title === "answer-twice")
            root.log("answer " + request.id + " " + c.answer(request.id, true, password, choice, null) + " second=" + c.answer(request.id, true, "again", choice, null));
        else if (title === "answer-late")
            lateTimer.pending = request;
    }

    Timer {
        id: lateTimer
        property var pending: null
        interval: 300
        running: pending !== null
        onTriggered: {
            const r = pending;
            pending = null;
            root.log("late answer " + r.id + " " + root.client.answer(r.id, true, "pw-" + r.id, false, null));
        }
    }

    Component {
        id: clientC
        PrompterClient {
            path: Quickshell.env("PROBE_SOCKET")
            shellVersion: "probe"
            onPrompted: request => root.answerAs(request)
            onWithdrawn: id => root.log("withdrawn " + id)
            onProgressed: (id, entered) => {
                root.log("progressed " + id + " " + entered);
                if (entered === 2)
                    root.log("answer " + id + " " + root.client.answer(id, false, null, false, null));
            }
            onLost: root.log("lost")
            onStateChanged: root.log("state " + state)
        }
    }

    SheetQueue {
        id: sheetQueue
    }

    Component {
        id: agentC
        SecretAgent {
            queue: sheetQueue
            devSocket: Quickshell.env("PROBE_SOCKET")
            shellVersion: "probe"
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: root.agent !== null
        onTriggered: {
            const s = root.agent.devState();
            if (s !== root.lastState) {
                root.lastState = s;
                root.log("devState " + s);
            }
        }
    }

    Component.onCompleted: {
        if (root.mode === "client")
            root.client = clientC.createObject(root);
        else if (root.mode === "agent") {
            // An unlocked session with the displays on, as the security process's host binds them from its lock and idle
            // (ADR-0041 S3; SheetSession fails closed without them: locked, displays off).
            SheetSession.locked = false;
            SheetSession.displaysOff = false;
            root.agent = agentC.createObject(root);
        }
        root.log("started " + root.mode);
    }
}
