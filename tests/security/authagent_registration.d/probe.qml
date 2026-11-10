import QtQuick
import Quickshell

// tests/security/authagent_registration.sh copies this file as the shell.qml of a scratch config: the polkit agent's
// registration code as written (shell/security/polkit/AuthAgent.qml, its window an Item: make_harness.py --real, beside
// this file once copied, so loaded by URL), on the installed Quickshell, against the system bus the script gives. The first
// retry comes REGISTRATION_PROBE_RETRY_MS after the start; it quits after REGISTRATION_PROBE_RUN_MS, saying how many times
// the agent was made again and whether it is registered. Nothing else.
Scope {
    id: probe

    property var agent: null

    Component.onCompleted: {
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
        interval: Number(Quickshell.env("REGISTRATION_PROBE_RUN_MS"))
        running: true
        onTriggered: {
            console.warn("registration-probe: end tries=" + (probe.agent ? probe.agent.registrationTries : -1) + " registered=" + (probe.agent ? probe.agent.registered : false));
            Qt.quit();
        }
    }
}
