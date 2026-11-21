pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.lib
import qs.platform
import "NotResponding.js" as Logic

// Apps that do not respond (ADR-0035 D-3, step 3; spec system-dialogs.md section 4). Hyprland runs `hyprland-dialog` when
// an app misses its pings; in the Grassfield session that is the stand-in packaging/session-bin/hyprland-dialog, which
// reports the app's process here (`anr report`) and then waits, silently, until Hyprland kills it (the app answered or
// closed). While it waits the app is marked: "(Not Responding)" in Force Quit, "Application Not Responding" in its Dock menu
// (the macOS model, owner decision Q2: no alert). The mark goes when the stand-in ends. The decisions are NotResponding.js.
Singleton {
    id: root

    // {standin, pid, cls, title}: one per stand-in that waits (a process may have several).
    property var marks: []
    // The compositor this shell belongs to: a report from another (a nested session's stand-in) is refused.
    readonly property string ownInstance: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") ?? ""

    function isMarked(pid: int): bool {
        return Logic.isMarked(root.marks, pid);
    }

    function markedAmong(pids: var): var {
        return Logic.markedAmong(root.marks, pids);
    }

    // Force Quit, at the confirmation: the pid still owns a window of that class, or of one of those classes (it was not
    // reused in between).
    function stillOwns(pid: int, cls: var): bool {
        return Logic.stillOwns(Compositor.knownWindows(), pid, cls);
    }

    function initialIndex(rowPids: var): int {
        return Logic.initialIndex(rowPids, root.marks);
    }

    function selectionAfterChange(userMoved: bool, kept: int, preferred: int, preferredMarked: bool): int {
        return Logic.selectionAfterChange(userMoved, kept, preferred, preferredMarked);
    }

    // The stand-ins that ended: their marks go (Hyprland killed them when the app answered or closed, or Force Quit killed the
    // app and Hyprland its dialog), within a second (NR3). Waited for, never polled (audit SC-20: a `kill -0` child every 250 ms
    // while an app stayed marked, for hours): one util-linux `waitpid` on every stand-in (a pidfd each, no wake while they live)
    // reports the one that ended ("PID n finished", "could not open PID n" for one already gone) and is started again on the
    // others; a new mark starts it again with the new list. Where waitpid is missing (exit 127) the earlier check stands in: a
    // `kill -0` of the stand-ins every 250 ms while there is a mark.
    property bool waiterMissing: false
    // The waiter's starts (tests: one per change of the marks, none while nothing changes).
    property int waiterRuns: 0

    onMarksChanged: root.watchStandins()

    function standinList(): string {
        const out = [];
        for (const m of root.marks) {
            if (out.indexOf(String(m.standin)) < 0)
                out.push(String(m.standin));
        }
        return out.sort().join(" ");
    }

    function watchStandins(): void {
        if (root.waiterMissing)
            return;
        const want = root.standinList();
        if (waiter.running) {
            // A mark came or went: the waiter is started again on the new list once this one has ended.
            if (waiter.watching !== want && !waiter.stopping) {
                waiter.stopping = true;
                waiter.running = false;
            }
            return;
        }
        if (want === "" || waiterRetry.running)
            return;
        waiter.watching = want;
        waiter.reported = false;
        waiter.stopping = false;
        waiter.command = ["sh", "-c", "command -v waitpid >/dev/null 2>&1 || exit 127; exec waitpid -v -c 1 \"$@\"", "sh"].concat(want.split(" "));
        root.waiterRuns++;
        waiter.running = true;
    }

    function standinEnded(line: string): void {
        const m = /PID ([0-9]+)/.exec(line);
        if (!m)
            return;
        const pid = parseInt(m[1], 10);
        waiter.reported = true;
        root.marks = Logic.withoutStandin(root.marks, pid);
    }

    Process {
        id: waiter
        property string watching: ""
        property bool reported: false
        property bool stopping: false
        stdout: SplitParser {
            onRead: line => root.standinEnded(line)
        }
        stderr: SplitParser {
            onRead: line => {
                if (line.indexOf("could not open PID") >= 0)
                    root.standinEnded(line);
            }
        }
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            if (code === 127 && !waiter.stopping) {
                root.waiterMissing = true;
                console.info("grassfield: waitpid (util-linux) is missing: the not-responding marks are checked every 250 ms instead");
                return;
            }
            // Ended without naming a stand-in and not by us (an error of its own): after a pause, so a waiter that fails at once
            // never spins; the pause is NR3's bound.
            if (!waiter.reported && !waiter.stopping) {
                waiterRetry.start();
                return;
            }
            Qt.callLater(root.watchStandins);
        }
    }

    Timer {
        id: waiterRetry
        interval: 250
        onTriggered: {
            // One look at the stand-ins (the waiter could not tell), then wait again.
            if (!alive.running && root.marks.length > 0) {
                alive.command = ["sh", "-c", "for p; do kill -0 \"$p\" 2>/dev/null || echo \"$p\"; done", "sh"].concat(root.marks.map(m => String(m.standin)));
                alive.running = true;
            }
            root.watchStandins();
        }
    }

    // The check without waitpid.
    Timer {
        interval: 250
        repeat: true
        running: root.waiterMissing && root.marks.length > 0 && !alive.running
        onTriggered: {
            alive.command = ["sh", "-c", "for p; do kill -0 \"$p\" 2>/dev/null || echo \"$p\"; done", "sh"].concat(root.marks.map(m => String(m.standin)));
            alive.running = true;
        }
    }

    Process {
        id: alive
        stdout: StdioCollector {
            onStreamFinished: {
                const gone = text.split("\n").filter(s => s !== "").map(s => parseInt(s, 10));
                if (gone.length > 0)
                    root.marks = root.marks.filter(m => gone.indexOf(m.standin) < 0);
            }
        }
    }

    IpcHandler {
        target: "anr"

        // The stand-in's report (security.md "IPC surface": an action of packaging/session-bin/hyprland-dialog). It only
        // marks an app in the UI; nothing is killed without the user's Force Quit and its confirmation. "ok" or "refused"
        // (the stand-in then runs the stock dialog); the reason goes to the journal only, never to the caller (it would
        // tell whether another process has a window of that class and title).
        function report(standin: int, pid: int, cls: string, title: string, instance: string): string {
            const c = Logic.unprefix(cls, "c:");
            const t = Logic.unprefix(title, "t:");
            const i = Logic.unprefix(instance, "i:");
            const d = Logic.decide(standin, pid, c, t, i, root.ownInstance, Compositor.knownWindows());
            if (!d.ok) {
                console.info("grassfield: not-responding report refused: " + d.reason);
                return "refused";
            }
            root.marks = Logic.withMark(root.marks, {
                standin: standin,
                pid: pid,
                cls: c,
                title: t
            });
            return "ok";
        }

        // Test hook: the marks (window titles: dev only).
        function status(): string {
            if (!Mode.dev)
                return Mode.refused;
            return Logic.statusJson(root.marks);
        }
    }
}
