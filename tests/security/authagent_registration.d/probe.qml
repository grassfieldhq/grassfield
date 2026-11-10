import QtQuick
import Quickshell
import qs.security

// tests/security/authagent_registration.sh copies this file as the shell.qml of a scratch config: the polkit agent's
// registration code as written (shell/security/polkit/AuthAgent.qml, its window an Item: make_harness.py --real, beside
// this file once copied, so loaded by URL), on the installed Quickshell, against the system bus the script gives. It sets
// SheetSession as the security host's Bindings would: unlocked, displays on, no sleep (REGISTRATION_PROBE_LOCKED=1: locked
// throughout; REGISTRATION_PROBE_RELOCK_MS: locked at that time and unlocked 200 ms later). The first retry comes
// REGISTRATION_PROBE_RETRY_MS after the start; it quits after REGISTRATION_PROBE_RUN_MS, saying how many times the agent
// was made again and whether it is registered. Nothing else.
Scope {
    id: probe

    property var agent: null
    readonly property int relockMs: Number(Quickshell.env("REGISTRATION_PROBE_RELOCK_MS") || 0)

    Component.onCompleted: {
        SheetSession.locked = Quickshell.env("REGISTRATION_PROBE_LOCKED") === "1";
        SheetSession.displaysOff = false;
        SheetSession.sleeping = false;
        const c = Qt.createComponent(Qt.resolvedUrl("real/polkit/AgentUnderTest.qml"));
        if (c.status !== Component.Ready) {
            console.warn("registration-probe: not loaded: " + c.errorString());
            Qt.quit();
            return;
        }
        probe.agent = c.createObject(probe, {
            registrationRetryMs: Number(Quickshell.env("REGISTRATION_PROBE_RETRY_MS"))
        });
        probe.agent.registeredChanged.connect(() => console.warn("registration-probe: registered=" + probe.agent.registered));
    }

    Timer {
        interval: Math.max(1, probe.relockMs)
        running: probe.relockMs > 0
        onTriggered: {
            console.warn("registration-probe: lock");
            SheetSession.locked = true;
            unlock.start();
        }
    }

    Timer {
        id: unlock
        interval: 200
        onTriggered: {
            console.warn("registration-probe: unlock");
            SheetSession.locked = false;
        }
    }

    Timer {
        interval: Number(Quickshell.env("REGISTRATION_PROBE_RUN_MS"))
        running: true
        onTriggered: {
            console.warn("registration-probe: end tries=" + (probe.agent ? probe.agent.registrationTries : -1) + " registered=" + (probe.agent ? probe.agent.registered : false));
            Qt.quit();
        }
    }
}
