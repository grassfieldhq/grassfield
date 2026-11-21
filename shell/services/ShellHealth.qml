pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "ProcessHealth.js" as Health

// The shell's own health in the journal (owner's report of 2026-11-21: the shell was killed by SIGKILL twice, at 11:16:55 and
// 11:25:09, with nothing naming the sender, and its memory peaked at 1.3 GB, once 8 minutes after a start, 30 s after a display
// was unplugged and plugged back). One line, "grassfield-shell: health <why>: rss ... realtime threads ...", a minute after the
// start, ten seconds after every change of the displays, and every five minutes; the last one is kept in
// $XDG_RUNTIME_DIR/grassfield-shell-health, which the unit's ExecStopPost (services/shell-stopped.sh) prints after a SIGKILL.
// A thread under a realtime policy with a realtime CPU limit (PipeWire's module-rt through RTKit sets 200 ms) gets a warning
// of its own: the kernel kills the whole process with SIGKILL, silently, when such a thread runs that long without sleeping.
// Read-only (/proc), one short process per sample (services/process-health.sh, the pid its one argument).
Singleton {
    id: root

    readonly property string recordPath: Health.recordPath(Quickshell.env("XDG_RUNTIME_DIR"))
    // The last sample (ProcessHealth.parse), null before the first.
    property var last: null
    property string pendingWhy: ""
    property bool rtWarned: false

    function sample(why: string): void {
        if (probe.running) {
            root.pendingWhy = why;
            return;
        }
        probe.why = why;
        probe.running = true;
    }

    function take(why: string, text: string): void {
        const s = Health.parse(text);
        if (s === null)
            return;
        root.last = s;
        console.info("grassfield-shell: health " + why + ": " + Health.describe(s));
        if (Health.rtKillable(s) && !root.rtWarned) {
            root.rtWarned = true;
            console.warn("grassfield-shell: realtime thread(s) " + s.rt.map(t => t.name).join(", ") + " under a realtime CPU limit of " + s.rtHard + " us: the kernel kills the whole shell with SIGKILL, without a log line, if one of them runs that long without sleeping");
        }
        if (root.recordPath !== "")
            recordFile.setText(Health.record(s, why, Date.now()) + "\n");
    }

    Process {
        id: probe
        property string why: ""
        command: ["sh", Quickshell.shellPath("services/process-health.sh"), String(Quickshell.processId)]
        stdout: StdioCollector {
            onStreamFinished: root.take(probe.why, text)
        }
        onRunningChanged: {
            if (!running && root.pendingWhy !== "") {
                const why = root.pendingWhy;
                root.pendingWhy = "";
                Qt.callLater(() => root.sample(why));
            }
        }
    }

    FileView {
        id: recordFile
        path: root.recordPath
        preload: false
        atomicWrites: true
        printErrors: false
    }

    Timer {
        id: first
        interval: 60000
        running: true
        onTriggered: root.sample("start")
    }

    Timer {
        interval: 300000
        repeat: true
        running: true
        onTriggered: root.sample("periodic")
    }

    // Ten seconds after the displays settle (a hotplug brings several changes): what the change cost.
    Timer {
        id: afterDisplays
        interval: 10000
        onTriggered: root.sample("displays (" + Quickshell.screens.length + ")")
    }

    Connections {
        target: Quickshell
        function onScreensChanged(): void {
            afterDisplays.restart();
        }
    }
}
