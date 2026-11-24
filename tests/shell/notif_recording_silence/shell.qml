pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import Grassfield.Ui
import qs.notifications
import qs.services

// Do Not Disturb while recording (capture suite A8, owner decision 2026-11-24) on the REAL Notifications and CaptureState singletons
// (scripts/dev/test.sh: `qs -p tests/shell/notif_recording_silence`, a dev session: see the dev-session marker file). The helper's
// state file is written here (a fake recording), the option capture.recordDnd is set, and a stand-in sender posts:
//  - a normal notification while recording with the option on gets no banner but lands in the Notification Center;
//  - a critical one still shows;
//  - the user's own Do Not Disturb (the saved setting, the indicators' `dnd`) stays off, and is never written;
//  - during a recording's countdown the same holds; a screenshot's countdown and the option off silence nothing;
//  - once the state is idle again, a notification gets its banner.
// Putting `dnd` back in place of `silenced` in Notifications.qml fails the first checks (tests/shell/notif_recording_silence is the
// proof of the wiring; the pure rule is in tests/unit/tst_capturefile.qml). Prints "notif-recording-silence: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    property string phase: "start"
    property int wrote: 0
    property int nextId: 100

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    component FakeNotification: QtObject {
        property int id: 7
        property bool tracked: false
        property string appName: "Mail"
        property string appIcon: ""
        property string summary: "hello"
        property string body: "world"
        property var actions: []
        property int urgency: NotificationUrgency.Normal
        property real expireTimeout: -1
        property string image: ""
        property bool resident: false
        property string desktopEntry: ""

        signal closed(int reason)

        function dismiss(): void {
        }
    }

    property var senders: ({})

    // Posts a notification and returns its key ("" when it was not accepted).
    function post(summary: string, urgency: int): string {
        const n = fakeComponent.createObject(root, {id: root.nextId++, summary: summary, urgency: urgency});
        root.senders[summary] = n;
        Notifications.accept(n);
        const e = Notifications.history.find(x => x.summary === summary);
        return e ? e.key : "";
    }

    function bannered(key: string): bool {
        for (let i = 0; i < Notifications.bannerModel.count; i++) {
            if (Notifications.bannerModel.get(i).key === key)
                return true;
        }
        return false;
    }

    function inCenter(key: string): bool {
        return Notifications.entryFor(key) !== null;
    }

    Component {
        id: fakeComponent

        FakeNotification {
        }
    }

    // The helper's state file, as the helper writes it (CaptureFile.parse reads it).
    Process {
        id: writer
    }

    function writeState(json: string): void {
        writer.command = ["sh", "-c", "mkdir -p \"$(dirname \"$1\")\" && printf '%s' \"$2\" > \"$1.tmp\" && mv -f \"$1.tmp\" \"$1\"", "sh", CaptureState.path, json];
        writer.running = true;
        root.wrote++;
    }

    readonly property string recording: '{"v": 1, "phase": "recording", "kind": "recording", "started": ' + Date.now() + '}'
    readonly property string idle: '{"v": 1, "phase": "idle"}'

    function finish(): void {
        if (failures.length === 0)
            console.log("notif-recording-silence: PASS");
        else
            console.log("notif-recording-silence: FAIL " + failures.join("; "));
        Qt.quit();
    }

    property string k1: ""
    property string k2: ""
    property string k3: ""
    property int waited: 0

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: root.step()
    }

    function step(): void {
        waited++;
        if (waited > 300) {
            failures.push("timed out in " + phase);
            finish();
            return;
        }
        if (phase === "start") {
            if (!Notifications.historyReady || !Settings.loaded || writer.running || CaptureState.path === "")
                return;
            Notifications.setDnd(false);
            Settings.setCaptureOption("recordDnd", true);
            writeState(recording);
            phase = "recording";
        } else if (phase === "recording") {
            if (writer.running || CaptureState.phase !== "recording" || !Settings.captureRecordDnd)
                return;
            root.k1 = post("normal", NotificationUrgency.Normal);
            root.k2 = post("critical", NotificationUrgency.Critical);
            check("accepted", k1 !== "" && k2 !== "");
            check("recording, option on: a normal notification has no banner", !bannered(k1));
            check("recording, option on: it is in the Notification Center", inCenter(k1));
            check("recording, option on: a critical one still shows", bannered(k2));
            check("the user's own Do Not Disturb stays off (the indicators' dnd)", Notifications.dnd === false && Settings.notificationsDnd === false);
            // The option off: the same state, a banner.
            Settings.setCaptureOption("recordDnd", false);
            phase = "optionOff";
        } else if (phase === "optionOff") {
            if (Settings.captureRecordDnd)
                return;
            root.k3 = post("optionoff", NotificationUrgency.Normal);
            check("recording, option off: a banner", bannered(k3));
            // A recording's countdown, the option on.
            Settings.setCaptureOption("recordDnd", true);
            writeState('{"v": 1, "phase": "countdown", "kind": "recording", "until": ' + (Date.now() + 600000) + '}');
            phase = "countdown";
        } else if (phase === "countdown") {
            if (writer.running || CaptureState.phase !== "countdown" || !Settings.captureRecordDnd)
                return;
            check("the state is a recording's countdown", CaptureState.kind === "recording");
            const k = post("countdown", NotificationUrgency.Normal);
            check("a recording's countdown: no banner", k !== "" && !bannered(k));
            check("a recording's countdown: it is in the centre", inCenter(k));
            check("the user's Do Not Disturb stays off", Notifications.dnd === false && Settings.notificationsDnd === false);
            writeState('{"v": 1, "phase": "countdown", "kind": "shot", "until": ' + (Date.now() + 600000) + '}');
            phase = "shotCountdown";
        } else if (phase === "shotCountdown") {
            if (writer.running || CaptureState.kind !== "shot")
                return;
            const k = post("shotcountdown", NotificationUrgency.Normal);
            check("a screenshot's countdown silences nothing", bannered(k));
            writeState(idle);
            phase = "idle";
        } else if (phase === "idle") {
            if (writer.running || CaptureState.phase !== "idle")
                return;
            const k = post("afterwards", NotificationUrgency.Normal);
            check("idle again: a banner", bannered(k));
            check("the saved Do Not Disturb was never written", Settings.notificationsDnd === false);
            Settings.setCaptureOption("recordDnd", false);
            phase = "done";
            finish();
        }
    }
}
