import QtQuick
import Grassfield.Ui

// Software Update as Settings sees it (ADR-0033 d, i; docs/specs/updates.md U8, U10-U14, U19), one per window: the badge of the
// sidebar and of General's row, and what the pane shows.
//   - software-update.json, which the shell alone writes, read whenever it changes (bounded: Backend.readText, then at most
//     1 MiB of JSON). Without a shell, the answer of the check Settings ran itself is kept here, in memory (U10).
//   - A check (U8: the pane opening, unless one finished less than a minute ago; Check Now): the shell is asked over its IPC
//     (`update check user`) and its answer reaches the file; when no shell answers, Settings runs the checker itself.
//   - The channel as `grassfield-channel-set` prints it, read again whenever /etc/pacman.d/grassfield.conf changes (U12: never
//     stored per user); whether this build can set updates up (repository.conf); Omarchy's reboot marker and the running
//     kernel's modules (U14, read only).
//   - The actions, through SystemService (never in a dev session): the channel changes (the polkit dialog: one at a time,
//     Backend.pendingActions), Update Now (U24-U30: grassfield-update-run, which owns the update without a terminal; when it
//     is not installed, Omarchy's terminal, then a check that waits for its update lock), Update in Terminal… and Finish in
//     Terminal… (Omarchy's terminal, for what needs a person), Log Out… and Restart… (grassfield-session-end, after the
//     window's confirmation sheet).
//   - The run of Update Now: the runner's state (Backend.softwareUpdateRunFile) and the root helper's progress
//     (/run/grassfield-update/<op>.progress), read every 500 ms while it runs and when the window opens: closing Settings
//     stops nothing, and opening it again shows the run where it is (ADR-0033 s3.5).
QtObject {
    id: root

    required property var backend
    required property var system

    // Read-only paths, a test seam (tests/unit/tst_settingssoftwareupdate.qml points them at its fixtures).
    property string includeFile: "/etc/pacman.d/grassfield.conf"
    property string repositoryFile: "/usr/share/grassfield/pacman/repository.conf"
    // The build's version (a prerelease sets up on beta, SoftwareUpdateLogic.defaultChannel).
    property string versionFile: "/usr/share/grassfield/VERSION"
    property string rebootMarker: root.backend.homeDir + "/.local/state/omarchy/reboot-required"
    property string kernelReleaseFile: "/proc/sys/kernel/osrelease"
    property string modulesDir: "/usr/lib/modules"
    property string runFile: root.backend.softwareUpdateRunFile
    property string helperDir: "/run/grassfield-update"
    property string procDir: "/proc"

    // software-update.json (SoftwareUpdateLogic.normalize), or Settings' own answer combined into it.
    property var file: SoftwareUpdateLogic.normalize(null)
    // Available releases (owner decision O3: Grassfield's and Omarchy's): the red badge.
    readonly property int count: SoftwareUpdateLogic.releases(root.file)
    readonly property var view: SoftwareUpdateLogic.view(root.file, root.checking)
    // A check runs: the shell's (asked by this window) or Settings' own.
    property bool checking: false
    // When this window last asked for a check (ms), 0 before.
    property double askedAt: 0
    // The file as it was when the shell was asked: its next answer ends `checking`.
    property var askedFile: null
    // stable, beta, custom, repair, off; "" until read or when it cannot be read.
    property string channel: ""
    // ADR-0041 step 2a: the hold on system updates Grassfield hasn't tested, SoftwareUpdateLogic.holdOf: held, allowed,
    // allowed-moved, none; "" until read or when it cannot be read (the pane then shows nothing about it).
    property string hold: ""
    readonly property bool buildReady: SoftwareUpdateLogic.buildReady(root.backend.readText(root.repositoryFile).text)
    // The channel Set Up… chooses: stable on a plain version, beta on a prerelease (-betaN, -rcN) and when it cannot be read.
    readonly property string defaultChannel: SoftwareUpdateLogic.defaultChannel(root.backend.readText(root.versionFile).text)
    // The installed version allows following stable (a plain X.Y.Z); otherwise "Off" in Beta Updates is unavailable, as in
    // grassfield-channel-set, which refuses `stable` then.
    readonly property bool stableAllowed: SoftwareUpdateLogic.stableAllowed(root.backend.readText(root.versionFile).text)
    // A Grassfield update in this session waits for a log out (GF-083, written to the file by the shell), or a toolkit
    // package replaced under it (ADR-0041 step 2b, U31: the shell writes the same flag; the list says which).
    readonly property bool logoutPending: root.file.logoutPending === true
    readonly property bool toolkitLogout: root.file.toolkitLogout === true
    // ...or the last run says so (s3.7: Grassfield's packages changed, nothing that asks for a restart). Grassfield's own
    // log out words the row with its name; the toolkit's alone (U31) without it.
    readonly property bool grassfieldLogout: root.logoutPending || (root.run.result === "done" && root.run.restart === "logout")
    readonly property bool logoutNeeded: root.grassfieldLogout || root.toolkitLogout
    // Omarchy's marker or the kernel's modules (readRestart), or the last run's own answer (s3.7); never while the run says
    // its startup files may be broken.
    property bool markerRestart: false
    readonly property bool restartNeeded: !root.restartBlocked && (root.markerRestart || (root.run.result === "done" && root.run.restart === "restart"))
    readonly property bool restartBlocked: root.run.result === "bootimage"
    // Update Now started Omarchy's terminal: the button waits for the check that follows (launchCheckMs), which waits for
    // Omarchy's update lock while the update runs, then for the answer after it.
    property bool launched: false
    // Update Now started the runner (ms; 0 when not): "Waiting for permission…" until its state names a run started since.
    property double runLaunchedAt: 0
    // The run of Update Now, SoftwareUpdateLogic.runView: state none | running | done, phase, done, total, percent, result,
    // restart, deferred.
    property var run: SoftwareUpdateLogic.runView(null, false, null, false)
    readonly property bool running: root.run.state === "running" || root.runLaunchedAt > 0
    readonly property bool updateRunning: root.launched || root.running || root.file.state === "update-running"
    // Update Now runs without a terminal (the runner, its helper and pkexec are installed), else in Omarchy's terminal.
    readonly property bool withoutTerminal: root.backend.updateRunner === true
    readonly property bool canUpdate: root.withoutTerminal || root.backend.omarchyUpdate === true
    readonly property bool canUseTerminal: root.backend.omarchyUpdate === true
    // A run ended while this window watched it (the pane offers the restart or log out it asks for).
    signal runFinished(string result, string restart)
    // The channel change that waits for the polkit dialog (Backend.pendingActions); "" when none.
    readonly property string channelTag: "update.channel.act"
    // The swap of the hold and its twin has its own tag: one polkit dialog per tag at a time.
    readonly property string holdTag: "update.hold.act"
    readonly property bool waitingForPermission: (root.backend.pendingActions ?? {})[root.channelTag] !== undefined
        || (root.backend.pendingActions ?? {})[root.holdTag] !== undefined
    // What the last channel change was for (its failure sentence names it): "setup", "beta", "repair", "off", "allow" or "holdagain".
    property string lastAction: ""
    readonly property string channelError: root.system.errors[root.channelTag] ?? ""
    readonly property string holdError: root.system.errors[root.holdTag] ?? ""

    function read(): void {
        const before = root.file;
        const r = root.backend.readText(root.backend.softwareUpdateFile);
        root.file = SoftwareUpdateLogic.fromText(r.ok ? r.text : "");
        if (root.askedFile !== null && SoftwareUpdateLogic.answered(root.askedFile, root.file))
            root.settle();
        if (root.launched && SoftwareUpdateLogic.answered(before, root.file) && root.file.state !== "update-running")
            root.launched = false;
    }

    function settle(): void {
        root.askedFile = null;
        root.checking = false;
        root.deadline.stop();
    }

    function readChannel(): void {
        root.system.query(["/usr/lib/grassfield/grassfield-channel-set"], "update.channel");
    }

    // The hold as grassfield-channel-set prints it (read-only: pacman's local database and the build's record).
    function readHold(): void {
        root.system.query(["/usr/lib/grassfield/grassfield-channel-set", "hold-state"], "update.hold");
    }

    // U14: Omarchy's marker, or the running kernel's modules folder gone (a kernel update): the reboot rule of Omarchy's
    // omarchy-update-restart, read only. An unreadable kernel release says nothing.
    function readRestart(): void {
        const release = root.backend.readText(root.kernelReleaseFile).text.trim();
        const modulesGone = release !== "" && release.indexOf("/") < 0 && !root.backend.readText(root.modulesDir + "/" + release).exists;
        root.markerRestart = root.backend.readText(root.rebootMarker).exists || modulesGone;
    }

    // The process `pid` is still the one that started at `startTime` (field 22 of its stat).
    function alive(pid: int, startTime: string): bool {
        return pid > 0 && startTime !== "" && SoftwareUpdateLogic.startTimeOf(root.backend.readText(root.procDir + "/" + pid + "/stat").text) === startTime;
    }

    // The runner's state and, while it runs, the helper's progress (s3.5).
    function readRun(): void {
        const r = root.runFile !== "" ? root.backend.readText(root.runFile) : { ok: false, text: "" };
        let state = SoftwareUpdateLogic.parseRun(r.ok ? r.text : "");
        // No runner's state (a log out ended the runner and its folder): the helper the last run started, while it runs.
        if (state === null && root.runLaunchedAt === 0) {
            const last = root.backend.readText(root.helperDir + "/last");
            state = SoftwareUpdateLogic.helperRun(last.ok ? last.text : "");
        }
        // Until the runner writes a run started since Update Now, the last one is not this one.
        if (root.runLaunchedAt > 0) {
            if (state !== null && state.startedAt >= root.runLaunchedAt - Tokens.softwareUpdateRunClockSlackMs)
                root.runLaunchedAt = 0;
            else if (Date.now() - root.runLaunchedAt > Tokens.softwareUpdateRunStartMs)
                root.runLaunchedAt = 0;
            else
                state = null;
        }
        let runnerAlive = false, progress = null, helperAlive = false;
        if (state !== null && state.phase !== "done") {
            runnerAlive = root.alive(state.pid, state.startTime);
            const p = root.backend.readText(root.helperDir + "/" + state.op + ".progress");
            progress = SoftwareUpdateLogic.parseProgress(p.ok ? p.text : "");
            const started = root.backend.readText(root.helperDir + "/" + state.op + ".started");
            if (started.ok && !root.backend.readText(root.helperDir + "/" + state.op + ".exit").exists) {
                const f = started.text.trim().split(" ");
                helperAlive = f.length === 2 && /^[0-9]{1,9}$/.test(f[0]) && root.alive(Number(f[0]), f[1]);
            }
        }
        const before = root.run.state;
        root.run = SoftwareUpdateLogic.runView(state, runnerAlive, progress, helperAlive);
        if (before === "running" && root.run.state === "done") {
            root.readRestart();
            root.readHold();
            root.runFinished(root.run.result, root.run.restart);
        }
        root.poll.running = root.running;
    }

    // U8: the pane opening checks unless a check finished less than paneFreshMs ago or one runs.
    // A stored `update-running` does not hold it back: its waiter may have ended with the session (a reboot or a log out
    // during the update), and a check while Omarchy's lock is still held only joins the waiter (integrator review of a9a5974).
    function checkIfStale(now: double): void {
        const last = Math.max(SoftwareUpdateLogic.timeOf(root.file.checkedAt), root.askedAt);
        if (!root.checking && now - last >= Tokens.softwareUpdatePaneFreshMs)
            root.check();
    }

    function check(): void {
        if (root.checking)
            return;
        root.checking = true;
        root.askedAt = Date.now();
        root.askedFile = root.file;
        root.deadline.restart();
        root.backend.askShellToCheck("update.ask");
    }

    // `verb`: stable, beta, repair or off (grassfield-channel-set); `action`: what it is for (lastAction).
    function setChannel(verb: string, action: string): bool {
        root.lastAction = action;
        return root.system.act("software update: " + action + " (grassfield-channel-set " + verb + ")", ["/usr/lib/grassfield/grassfield-channel-set", verb], root.channelTag);
    }

    // "Allow system updates Grassfield hasn't tested…" (`allow`) and "Hold again", ADR-0041 step 2a: one root transaction
    // through the channel helper's polkit action (grassfield-channel-set unhold | hold).
    function setHold(allow: bool): bool {
        root.lastAction = allow ? "allow" : "holdagain";
        const verb = allow ? "unhold" : "hold";
        return root.system.act("software update: " + (allow ? "allow untested system updates" : "hold untested system updates") + " (grassfield-channel-set " + verb + ")", ["/usr/lib/grassfield/grassfield-channel-set", verb], root.holdTag);
    }

    // Update Now (U24): the runner, which asks for the password and owns the run; without it, Omarchy's terminal (U11).
    function updateNow(): bool {
        if (!root.canUpdate || root.updateRunning || root.file.state === "blocking")
            return false;
        if (!root.withoutTerminal)
            return root.updateInTerminal();
        if (!root.system.launch("update now", ["/usr/lib/grassfield/grassfield-update-run"]))
            return false;
        root.runLaunchedAt = Date.now();
        root.run = SoftwareUpdateLogic.runView(null, false, null, false);
        root.poll.running = true;
        return true;
    }

    // Update in Terminal… (U28): Omarchy's own update, for an update that needs a person; then the check that waits for its lock.
    function updateInTerminal(): bool {
        if (!root.canUseTerminal || root.updateRunning)
            return false;
        if (!root.system.launch("update in terminal", ["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"]))
            return false;
        root.launched = true;
        root.launchCheck.restart();
        return true;
    }

    // Finish in Terminal… (U28): Omarchy's migrations a run could not finish, in Omarchy's terminal.
    function finishInTerminal(): bool {
        if (!root.canUseTerminal || root.updateRunning)
            return false;
        return root.system.launch("finish in terminal", ["omarchy-launch-floating-terminal-with-presentation", "omarchy-migrate"]);
    }

    function endSession(action: string): bool {
        return root.system.launch(action === "restart" ? "restart" : "log out", ["/usr/lib/grassfield/grassfield-session-end", action === "restart" ? "restart" : "logout"]);
    }

    Component.onCompleted: {
        root.backend.watch(root.backend.softwareUpdateFile);
        root.backend.watch(root.includeFile);
        root.read();
        root.readChannel();
        root.readHold();
        root.readRestart();
        root.readRun();
    }

    // While a run goes on: its files are replaced by rename, so they are read again rather than watched.
    readonly property Timer poll: Timer {
        interval: Tokens.softwareUpdateRunPollMs
        repeat: true
        onTriggered: root.readRun()
    }

    // The shell's check has no answer in time (it was busy, or it died): the pane stops waiting.
    readonly property Timer deadline: Timer {
        interval: Tokens.softwareUpdateCheckTimeoutMs
        onTriggered: root.settle()
    }

    // After Update Now: the check that finds Omarchy's update lock held, so the shell waits for the update to end (U4, U11).
    readonly property Timer launchCheck: Timer {
        interval: Tokens.softwareUpdateLaunchCheckMs
        onTriggered: {
            root.settle();
            root.check();
        }
    }

    readonly property Connections files: Connections {
        target: root.backend

        function onFileChanged(path: string): void {
            if (path === root.backend.softwareUpdateFile) {
                root.read();
                root.readRestart();
            } else if (path === root.includeFile) {
                root.readChannel();
            }
        }

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "update.channel") {
                root.channel = ok ? SoftwareUpdateLogic.channelOf(output) : "";
            } else if (tag === "update.hold") {
                root.hold = ok ? SoftwareUpdateLogic.holdOf(output) : "";
            } else if (tag === root.holdTag) {
                // The swap ended: the state is read again, and the pane checks (what Update Now refused may go through now).
                root.readHold();
                if (ok) {
                    root.settle();
                    root.check();
                }
            } else if (tag === "update.ask") {
                // The shell runs (or joins) a check: its answer comes through the file. Anything else: no shell (U10).
                if (!(ok && output.trim() === "ok")) {
                    root.askedFile = null;
                    root.backend.runUpdateChecker("update.run");
                }
            } else if (tag === "update.run") {
                const answer = SoftwareUpdateLogic.parse(output.trim());
                const next = SoftwareUpdateLogic.combine(root.file, answer !== null ? answer : SoftwareUpdateLogic.noAnswer(Date.now(), ok ? "the checker gave no answer" : "the checker could not run"));
                if (next !== null)
                    root.file = next;
                if (root.launched && root.file.state !== "update-running")
                    root.launched = false;
                root.checking = false;
                root.deadline.stop();
            } else if (tag === root.channelTag) {
                // Switching installs nothing (O2); the pane then checks (U12). The value follows the file, watched.
                root.readChannel();
                if (ok) {
                    root.settle();
                    root.check();
                }
            }
        }
    }
}
