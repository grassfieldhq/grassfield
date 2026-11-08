pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.security.lock
import "IdleModel.js" as IdleModel
import "../../lib/RunMode.js" as RunMode

// Lock before sleep (SEC1, ADR-0010): a logind *delay* inhibitor on "sleep" is held while the
// session runs; on PrepareForSleep(true) the screen locks and the inhibitor is released as soon
// as Lock.currentlySecure() holds, so suspend continues; it is taken again on resume. Secure is a lock
// of this shell that the compositor confirmed AND, if it was already held, that Hyprland reported
// locked again after this sleep request (Lock.lock() re-verifies; a session found unlocked under
// a stale lock gets a fresh one first). The decision reads the lock state afresh (Omarchy v4.0.6 fix,
// basecamp/omarchy@237f1b4, see Lock.currentlyLocked()).
//
// Quickshell 0.3.1 has no D-Bus or logind API, so both halves are small child processes:
//   - inhibitor: `systemd-inhibit --mode=delay … sh -c 'echo held; exec cat'`; systemd-inhibit runs the command only
//     once it holds the lock, so "held" is the proof it was taken; `cat` reads this process's stdin pipe, so the
//     inhibitor dies with the shell (EOF) and can never outlive it;
//   - watcher: `gdbus monitor` on /org/freedesktop/login1 (signal subscription, no privileges).
// Both run under `setpriv --pdeathsig TERM` (util-linux): the kernel sends them SIGTERM when the
// shell dies, even by SIGKILL, so a crash leaves no orphan behind.
// A child that shows no progress within IdleModel.PROGRESS_BUDGET_MS (no "held", no subscription) is hung: it is stopped
// and counted as a failure like an early exit (review of eee45cc).
// Neither is ever given up (GF-AUDIT-001 SEC-02/GF-030): after IdleModel.MAX_FAST_FAILURES early exits in a row the
// user gets a notice ("The screen may not lock before sleep") and the child is retried every minute; the notice is
// withdrawn once it runs again. The notice goes through the notification server's public D-Bus interface (ADR-0041 S2:
// this module runs in the security process, the server in the UI): `busctl --user --auto-start=no call
// org.freedesktop.Notifications ... Notify`, never starting another notification daemon by D-Bus activation; while the UI
// is down the call fails and the journal line above is all there is. In a dev session it is posted only on the dev
// session's private bus (the rule of RunMode.ownBus), never on the owner's.
// The sleep delay lasts at most what logind allows (InhibitDelayMaxUSec, IdleModel.sleepBudgetMs).
// In the nested dev session (RunMode.dev through the relative import, which no QML import path can replace:
// GRASSFIELD_DEV=1 and no GRASSFIELD_SESSION=1) the inhibitor is never taken: it would delay the owner's real suspend.
// The watcher only listens and stays on. A GRASSFIELD_DEV=1 that leaks into a real session (GRASSFIELD_SESSION=1)
// changes nothing here (SEC-03).
Scope {
    id: root

    readonly property bool dev: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))
    readonly property bool inhibiting: inhibitor.running
    property bool sleeping: false
    // Consecutive early exits of a child (IdleModel.failuresAfterRun); reset once it has run FAST_EXIT_MS, which the
    // inhibitorHealthy/watcherHealthy Timers measure (monotonic; never the wall clock, review of 2dfd992).
    property int inhibitorFailures: 0
    property int watcherFailures: 0
    // Lock before sleep cannot be guaranteed: the user is told (notice) until both children run again.
    readonly property bool degraded: (!dev && IdleModel.degraded(inhibitorFailures)) || IdleModel.degraded(watcherFailures)
    // The notice's id from the notification server (0: none shown); "pending" while the Notify call runs.
    property int noticeId: 0
    property bool noticeWanted: false
    // May post on this session bus (always outside dev; in dev only on the private bus of the dev session).
    // The rule of RunMode.ownBus, from this file's own dev gate (a security module reads GRASSFIELD_DEV only through it).
    readonly property bool ownBus: !root.dev || Quickshell.env("GRASSFIELD_PRIVATE_BUS") === "1"
    // Longest wait for a confirmed lock before the sleep delay is released (logind's window, read at start).
    property int budgetMs: IdleModel.sleepBudgetMs("")
    // Prefix for long-lived children: die with the shell (PR_SET_PDEATHSIG, kept across exec).
    readonly property var dieWithShell: ["setpriv", "--pdeathsig", "TERM", "--"]

    // The computer resumed from sleep (after the lock decisions above): Idle lights the lock screen (Idle.wakeAfterResume).
    signal resumed

    function take(): void {
        if (dev || inhibitor.running)
            return;
        inhibitor.running = true;
    }

    function release(why: string): void {
        releaseTimer.stop();
        if (sleeping)
            console.info("grassfield-idle: ready for sleep (" + why + ", lock " + (Lock.currentlySecure() ? "confirmed" : "NOT confirmed") + ")");
        if (!inhibitor.running)
            return;
        inhibitor.running = false;
        console.info("grassfield-idle: sleep inhibitor released (" + why + ")");
    }

    function beforeSleep(): void {
        console.info("grassfield-idle: system is going to sleep, locking");
        sleeping = true;
        Lock.lock("sleep");
        if (Lock.currentlySecure())
            release("locked");
        else
            releaseTimer.restart();
    }

    function afterResume(): void {
        // Resumed from a sleep this instance never prepared for (it started, or its watcher came back, after
        // PrepareForSleep(true): a crash or restart right before the sleep): lock now, before anything else.
        if (!sleeping) {
            console.warn("grassfield-idle: resumed from a sleep this shell did not lock for; locking");
            Lock.lock("resume");
        } else {
            console.info("grassfield-idle: system resumed");
        }
        // The lock's clock (ADR-0040 ID-7, T-14: the time shown on waking is the time now).
        Lock.resumed();
        sleeping = false;
        releaseTimer.stop();
        take();
        root.resumed();
    }

    function handleLine(line: string): void {
        const value = IdleModel.prepareForSleep(line);
        if (value === true)
            beforeSleep();
        else if (value === false)
            afterResume();
    }

    onDegradedChanged: {
        if (degraded && !noticeWanted) {
            console.warn("grassfield-idle: lock before sleep is not guaranteed (inhibitor failures " + inhibitorFailures + ", watcher failures " + watcherFailures + "); user notified, retrying every " + IdleModel.SLOW_RETRY_MS / 1000 + " s");
            noticeWanted = true;
            root.postNotice(qsTr("The screen may not lock before sleep"), IdleModel.degraded(watcherFailures) ? qsTr("Grassfield cannot see when the computer goes to sleep. Lock the screen yourself (Super+Control+Q) before you leave the computer.") : qsTr("Grassfield cannot delay sleep until the screen is locked. Lock the screen yourself (Super+Control+Q) before you close the lid."));
        } else if (!degraded && noticeWanted) {
            console.info("grassfield-idle: lock before sleep available again");
            noticeWanted = false;
            root.closeNotice();
        }
    }

    // org.freedesktop.Notifications.Notify(app_name, replaces_id, app_icon, summary, body, actions, hints, timeout): no
    // actions, no hints, the server's default timeout. Argument vector, no shell; --auto-start=no: a session without the UI's
    // server answers with an error instead of starting another daemon that would then hold the name.
    function postNotice(summary: string, body: string): void {
        if (!root.ownBus) {
            console.info("grassfield-idle: notice not posted (dev session without its private bus): " + summary);
            return;
        }
        notify.command = ["busctl", "--user", "--auto-start=no", "--timeout=5", "call", "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", "susssasa{sv}i", "Grassfield", String(root.noticeId), "", summary, body, "0", "0", "-1"];
        notify.running = true;
    }

    function closeNotice(): void {
        if (root.noticeId === 0 || !root.ownBus)
            return;
        closer.command = ["busctl", "--user", "--auto-start=no", "--timeout=5", "call", "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "CloseNotification", "u", String(root.noticeId)];
        root.noticeId = 0;
        closer.running = true;
    }

    Process {
        id: notify
        stdout: StdioCollector {
            // "u <id>"
            onStreamFinished: {
                const m = String(text).trim().match(/^u ([0-9]{1,10})$/);
                root.noticeId = m ? Number(m[1]) : 0;
                if (!m)
                    console.warn("grassfield-idle: the notice could not be shown (no notification server answered: the shell may be restarting); the journal has it");
                // Lock before sleep came back while the notice was being posted: withdraw it at once.
                else if (!root.noticeWanted)
                    root.closeNotice();
            }
        }
    }

    Process {
        id: closer
    }

    Connections {
        target: Lock

        function onSecureChanged(): void {
            if (root.sleeping && Lock.currentlySecure())
                root.release("locked");
        }
    }

    // logind proceeds after its window (InhibitDelayMaxSec) regardless; let go just before.
    Timer {
        id: releaseTimer
        interval: root.budgetMs
        onTriggered: root.release("timeout")
    }

    Process {
        id: inhibitor

        // Set once this run lasted FAST_EXIT_MS and the lock is held; false from each start (and before any).
        property bool ranLong: false
        // "held" was printed: systemd-inhibit holds the lock.
        property bool progressed: false

        command: root.dieWithShell.concat(["systemd-inhibit", "--what=sleep", "--mode=delay", "--who=Grassfield", "--why=" + qsTr("Lock the screen before sleep"), "sh", "-c", "echo held; exec cat"])
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => {
                if (line === "held" && !inhibitor.progressed) {
                    inhibitor.progressed = true;
                    inhibitorProgress.stop();
                    console.info("grassfield-idle: sleep inhibitor taken");
                    if (inhibitor.running && !inhibitorHealthy.running) {
                        inhibitor.ranLong = true;
                        root.inhibitorFailures = 0;
                    }
                }
            }
        }
        onStarted: {
            ranLong = false;
            progressed = false;
            inhibitorHealthy.restart();
            inhibitorProgress.restart();
        }
        onRunningChanged: {
            if (running || root.sleeping || root.dev)
                return;
            inhibitorHealthy.stop();
            inhibitorProgress.stop();
            root.inhibitorFailures = IdleModel.failuresAfterRun(root.inhibitorFailures, ranLong);
            ranLong = false;
            inhibitorRestart.interval = IdleModel.retryDelayMs(root.inhibitorFailures);
            if (root.inhibitorFailures > 0)
                console.warn("grassfield-idle: sleep inhibitor exited early (" + root.inhibitorFailures + " in a row); retrying in " + inhibitorRestart.interval / 1000 + " s");
            inhibitorRestart.restart();
        }
    }

    // Ran long enough with the lock held: no longer failing.
    Timer {
        id: inhibitorHealthy
        interval: IdleModel.FAST_EXIT_MS
        onTriggered: {
            if (inhibitor.running && inhibitor.progressed) {
                inhibitor.ranLong = true;
                root.inhibitorFailures = 0;
            }
        }
    }

    // No "held" in time: systemd-inhibit hangs without the lock. Stopped; onRunningChanged counts the failure.
    Timer {
        id: inhibitorProgress
        interval: IdleModel.PROGRESS_BUDGET_MS
        onTriggered: {
            if (inhibitor.running && !inhibitor.progressed) {
                console.warn("grassfield-idle: sleep inhibitor shows no lock after " + interval / 1000 + " s; stopped, counted as a failure");
                inhibitor.running = false;
            }
        }
    }

    Timer {
        id: inhibitorRestart
        interval: IdleModel.FAST_RETRY_MS
        onTriggered: root.take()
    }

    Process {
        id: watcher

        // Set once this run lasted FAST_EXIT_MS and gdbus printed a line; false from each start (and before any).
        property bool ranLong: false
        // gdbus reported login1's owner, which it does only after subscribing (IdleModel.watcherSubscribed).
        property bool progressed: false

        running: true
        command: root.dieWithShell.concat(["gdbus", "monitor", "--system", "--dest", "org.freedesktop.login1", "--object-path", "/org/freedesktop/login1"])
        stdout: SplitParser {
            onRead: line => {
                if (!watcher.progressed && IdleModel.watcherSubscribed(line)) {
                    watcher.progressed = true;
                    watcherProgress.stop();
                    if (watcher.running && !watcherHealthy.running) {
                        watcher.ranLong = true;
                        root.watcherFailures = 0;
                    }
                }
                root.handleLine(line);
            }
        }
        onStarted: {
            ranLong = false;
            progressed = false;
            watcherHealthy.restart();
            watcherProgress.restart();
        }
        onRunningChanged: {
            if (running)
                return;
            watcherHealthy.stop();
            watcherProgress.stop();
            root.watcherFailures = IdleModel.failuresAfterRun(root.watcherFailures, ranLong);
            ranLong = false;
            watcherRestart.interval = IdleModel.retryDelayMs(root.watcherFailures);
            if (root.watcherFailures > 0)
                console.warn("grassfield-idle: PrepareForSleep watcher exited early (" + root.watcherFailures + " in a row); retrying in " + watcherRestart.interval / 1000 + " s");
            watcherRestart.restart();
        }
    }

    Timer {
        id: watcherHealthy
        interval: IdleModel.FAST_EXIT_MS
        onTriggered: {
            if (watcher.running && watcher.progressed) {
                watcher.ranLong = true;
                root.watcherFailures = 0;
            }
        }
    }

    // No line in time: gdbus hangs before it is subscribed. Stopped; onRunningChanged counts the failure.
    Timer {
        id: watcherProgress
        interval: IdleModel.PROGRESS_BUDGET_MS
        onTriggered: {
            if (watcher.running && !watcher.progressed) {
                console.warn("grassfield-idle: PrepareForSleep watcher shows no subscription after " + interval / 1000 + " s; stopped, counted as a failure");
                watcher.running = false;
            }
        }
    }

    Timer {
        id: watcherRestart
        interval: IdleModel.FAST_RETRY_MS
        onTriggered: watcher.running = true
    }

    // logind's delay window, read once (read-only property; no privileges). Not in dev: no inhibitor there.
    Process {
        id: budgetQuery
        command: ["busctl", "get-property", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "InhibitDelayMaxUSec"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.budgetMs = IdleModel.sleepBudgetMs(text);
                console.info("grassfield-idle: sleep delay budget " + root.budgetMs + " ms (logind InhibitDelayMaxUSec: " + String(text).trim() + ")");
            }
        }
    }

    Component.onCompleted: {
        if (dev) {
            console.info("grassfield-idle: inhibitor skipped (dev)");
        } else {
            budgetQuery.running = true;
            take();
        }
    }
}
