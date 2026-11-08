pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.lib
import Grassfield.Ui

// Software Update's checks (ADR-0033 d; docs/specs/updates.md U4, U7-U10, U18, U20, U22). The shell is the only checker:
// it runs grassfield-update-check as a one-shot child (no daemon) and keeps the last answer in
// $XDG_STATE_HOME/grassfield/software-update.json (0600, atomic; version 1 with the versions already announced, ADR-0020).
// Settings and Grassfield Store read that file and ask for a check over IPC (`update check user`); Omarchy's own update
// reaches it through the omarchy-shell shim (`update check omarchy`, U9).
//   - One check at a time: a request while one runs joins it. The answer `update-running` (omarchy update holds its lock)
//     starts one waiter (--after-update-lock), which checks once the lock is released (U4); a waiter that answers
//     `update-running` again starts the next one only after waitRetryMs. A file that still says `update-running` when the
//     shell starts (the waiter ended with the session: a reboot or a log out during the update, a crash) is checked at once.
//   - Automatic checks (updates.automaticCheck, default on): 10 minutes after the start, then every 6 hours, skipped while
//     offline, on a metered connection, or on battery at 30 % or less (U7; ADR-0050 6, Luma's download conditions: looked
//     at again when the computer is plugged in); a retry the checker asks for (retryAt, U3) comes earlier.
//   - Each newly found Grassfield or Omarchy version, and each `blocking` episode, is announced once (`announce`; shell.qml
//     posts the notification), never for a check the user started (U20, U22).
//   - Update Now's runs (ADR-0033 "Step 4", U33): the runner's state ($XDG_RUNTIME_DIR/grassfield/software-update-run.json,
//     replaced by rename) is watched; the end of a run this shell saw going on is announced once (`runEnded`; shell.qml posts
//     the notice, and holds GF-083's while the run goes on). A run found already ended (the shell started after it) is never
//     announced. The folder is made first (0700, as the runner makes it): a FileView sees no file in a missing folder.
//   - A dev session runs the checker read-only with its cache under the dev state, or answers from GRASSFIELD_UPDATE_FIXTURE,
//     and watches its own run folder (UPDATE_RUN_DIR, ADR-0019). The update actions are Settings'; nothing here starts one.
Singleton {
    id: root

    // software-update.json as last written (SoftwareUpdateLogic.normalize).
    property var file: SoftwareUpdateLogic.normalize(null)
    property bool loaded: false
    // Releases available (owner decision O3: Grassfield's and Omarchy's, 0 to 2): the Dock's Settings tile and the
    // Grassfield menu's "Settings…" show it (U18, U19).
    readonly property int count: SoftwareUpdateLogic.releases(file)
    // The Grassfield menu's text after "Settings…" (U19): "1 update", "2 updates", "" (singular and plural: the catalogs carry
    // no numerus forms).
    readonly property string menuDetail: count === 1 ? qsTr("1 update") : count > 1 ? qsTr("%1 updates").arg(count) : ""
    readonly property bool checking: checkProc.running
    readonly property bool waiting: waitProc.running
    // GF-083's updatePending, bound by shell.qml: written to the file for the pane's "Log out to finish updating" (U14).
    property bool logoutPending: false
    // ADR-0041 step 2b (U31): a toolkit package was replaced under this session (installed at or after the session's start,
    // whatever the build's record says); once due, a log out stays due until the session ends, through a restart of the
    // shell (re-read from the file at load). A test seam too.
    property bool toolkitLogout: false
    readonly property bool logoutDue: logoutPending || toolkitLogout

    // A newly found release ("grassfield" or "omarchy", its version and the installed one) or a `blocking` episode.
    signal announce(string kind, string version, string installed)
    // The end of an Update Now run this shell saw going on: SoftwareUpdateLogic.runNotice's kind, "" when it deserves no
    // notice (GF-083's notice, held while the run goes on, is then shown: shell.qml).
    signal runEnded(string kind)

    // Update Now's runner state (U33), "" without an absolute runtime folder; the operation this shell saw going on, "" when
    // none. A dev session watches its own folder (dev plumbing UPDATE_RUN_DIR, else under its state; ADR-0019), never the
    // real session's runs.
    readonly property string runFolder: {
        const runtime = String(Quickshell.env("XDG_RUNTIME_DIR") || "");
        const dir = Mode.dev ? (Mode.devValue("UPDATE_RUN_DIR") || Mode.stateDir + "/update-run") : (runtime !== "" ? runtime + "/grassfield" : "");
        return dir.startsWith("/") ? dir : "";
    }
    readonly property string runPath: runFolder !== "" ? runFolder + "/software-update-run.json" : ""
    property string runningOp: ""

    function readRun(text: string): void {
        const run = SoftwareUpdateLogic.parseRun(text);
        if (run === null)
            return;
        if (run.phase !== "done") {
            root.runningOp = run.op;
            return;
        }
        if (run.op !== root.runningOp)
            return;
        root.runningOp = "";
        const kind = SoftwareUpdateLogic.runNotice(run);
        // Its restart or log out covers the toolkit's log out in this session (U31): that notice is not posted after it.
        if ((kind === "restart" || kind === "logout") && root.loaded)
            root.save(SoftwareUpdateLogic.withToolkitCovered(root.file, root.sessionStartedAt));
        // ADR-0041 step 2a (R7-INS-03): the first refusal of a toolkit move starts the 7 days; an update that went through ends them.
        if (root.loaded) {
            if (kind === "incompatible" && !SoftwareUpdateLogic.holdWaitStarted(root.file))
                root.save(SoftwareUpdateLogic.withHoldRefused(root.file, Date.now()));
            else if ((run.result === "done" || run.result === "up-to-date") && SoftwareUpdateLogic.holdWaitStarted(root.file))
                root.save(SoftwareUpdateLogic.withoutHoldRefused(root.file));
        }
        root.runEnded(kind);
    }

    readonly property string statePath: Mode.stateDir + "/software-update.json"
    // The checker (GRASSFIELD_UPDATE_CHECK_CMD in a dev session; a test seam too).
    property string program: Mode.devValue("UPDATE_CHECK_CMD") || "/usr/lib/grassfield/grassfield-update-check"
    readonly property string fixture: Mode.devValue("UPDATE_FIXTURE")
    // The checker's cache ($XDG_CACHE_HOME/grassfield) under the dev state in a dev session (ADR-0033 "Dev sessions").
    readonly property var checkerEnv: Mode.dev ? {
        "XDG_CACHE_HOME": Mode.stateDir + "/cache"
    } : ({})
    readonly property double startedAt: Date.now()
    // The session's start (U31): Hyprland's, from HYPRLAND_INSTANCE_SIGNATURE, the same across a restart of the shell; the
    // shell's own start without a signature. A test seam too.
    property double sessionStartedAt: SoftwareUpdateLogic.sessionStart(Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE"), startedAt)
    // A user asked for the running check (Settings, the Store): its findings are not announced (U20).
    property bool userAsked: false
    // An automatic check waits for the connectivity to come back.
    property bool deferred: false
    // An automatic check waits for mains power (ADR-0050 6).
    property bool powerDeferred: false

    // Test seams (a command that does not exist, or one that hangs, and short timeouts); the defaults are the production
    // values.
    property var meteredCommand: ["nmcli", "-t", "-g", "GENERAL.METERED", "device", "show"]
    property int meteredTimeoutMs: Tokens.softwareUpdateMeteredTimeoutMs
    property int checkTimeoutMs: Tokens.softwareUpdateCheckTimeoutMs
    property int waitTimeoutMs: Tokens.softwareUpdateWaitTimeoutMs
    property int waitRetryMs: Tokens.softwareUpdateWaitRetryMs

    // The release in a sentence: "1.0.1", or "1.0.1-4" for a rebuild of the installed version (owner decision O7).
    function releaseName(version: string, installed: string): string {
        return SoftwareUpdateLogic.releaseName(version, installed);
    }

    // A check (U8, U9): joins the one running, or the waiter's. "user": Settings or the Store; "omarchy": the shim, from
    // inside `omarchy update`.
    function request(origin: string): void {
        if (origin === "user")
            userAsked = true;
        if (checkProc.running || waitProc.running)
            return;
        run(checkProc, false, checkTimeoutMs);
    }

    function command(waiter: bool): var {
        if (fixture !== "")
            return ["cat", fixture];
        return SoftwareUpdateLogic.checkerArgs(program, !Connectivity.fullyConnected, waiter);
    }

    function run(proc: var, waiter: bool, timeoutMs: int): void {
        proc.text = "";
        proc.gotOut = false;
        proc.gotExit = false;
        proc.didStart = false;
        proc.stopped = false;
        proc.command = command(waiter);
        proc.environment = checkerEnv;
        proc.running = true;
        (waiter ? waitTimeout : checkTimeout).interval = timeoutMs;
        (waiter ? waitTimeout : checkTimeout).restart();
    }

    // Every way a run ends (an answer, a start failure, a stop at its deadline) lands here once.
    function finished(proc: var, waiter: bool): void {
        if (!(proc.gotOut && proc.gotExit))
            return;
        proc.gotOut = false;
        proc.gotExit = false;
        (waiter ? waitTimeout : checkTimeout).stop();
        (waiter ? waitKill : checkKill).stop();
        let answer = SoftwareUpdateLogic.parse(proc.text);
        if (answer === null) {
            const why = proc.stopped ? "the check took too long" : !proc.didStart ? "the checker could not start" : "the checker gave no answer";
            console.warn("software update: " + why);
            answer = SoftwareUpdateLogic.noAnswer(Date.now(), why);
        }
        // A user who asked while the waiter ran waits for its answer too.
        const user = userAsked;
        userAsked = false;
        handle(answer, user, waiter);
    }

    // `fromWaiter`: the answer is the waiter's.
    function handle(answer: var, user: bool, fromWaiter: bool): void {
        if (answer.state === "busy") {
            // Another run of the checker holds its lock (Settings without a shell, U10): once more, later.
            if (!busyTimer.running)
                busyTimer.restart();
            return;
        }
        const items = SoftwareUpdateLogic.news(file, answer, sessionStartedAt);
        const replaced = SoftwareUpdateLogic.toolkitReplaced(answer, sessionStartedAt, SoftwareUpdateLogic.toolkitAsked(file));
        if (replaced.length > 0) {
            if (!toolkitLogout)
                console.info("software update: a toolkit package was replaced under this session (log out due): " + replaced.map(p => p.name + " " + p.installed + (p.moved ? " (not the version Grassfield was built with: " + p.built + ")" : "")).join(", "));
            toolkitLogout = true;
        }
        let next = SoftwareUpdateLogic.withAnnounced(SoftwareUpdateLogic.combine(file, answer), items);
        if (replaced.length > 0)
            next = SoftwareUpdateLogic.withToolkitAsked(next, replaced);
        save(SoftwareUpdateLogic.withLogoutPending(next, logoutPending, toolkitLogout));
        console.info("software update: " + answer.state + (answer.error ? " (" + answer.error + ")" : "") + (items.length > 0 ? ", new: " + items.map(n => n.id).join(", ") : ""));
        if (!user) {
            for (const n of items)
                announce(n.kind, n.version, n.installed);
        }
        // The waiter's own answer is update-running when its wait ended with the lock still held (or a dev fixture says
        // so): the next waiter starts later, never in a loop.
        if (answer.state === "update-running" && !waitProc.running) {
            if (fromWaiter)
                waitRetry.restart();
            else
                run(waitProc, true, waitTimeoutMs);
        }
        reschedule();
    }

    // Once the file is read: a stored `update-running` whose waiter did not survive is checked now (the check answers
    // update-running again, and starts a waiter, only while Omarchy's lock is still held).
    function resume(): void {
        if (file.state === "update-running" && !checkProc.running && !waitProc.running)
            run(checkProc, false, checkTimeoutMs);
    }

    // The 7 days after the first refused update of a toolkit move are over (R7-INS-03): the notice puts "Allow…" forward.
    function holdWaitOver(): bool {
        return SoftwareUpdateLogic.holdWaitOver(root.file, Date.now());
    }

    function save(next: var): void {
        file = next;
        if (stateFile.path !== "")
            stateFile.setText(JSON.stringify(next) + "\n");
    }

    onLogoutDueChanged: {
        if (loaded && ((file.logoutPending === true) !== logoutPending || (file.toolkitLogout === true) !== toolkitLogout))
            save(SoftwareUpdateLogic.withLogoutPending(file, logoutPending, toolkitLogout));
    }

    // At load: a log out an earlier shell found due for the toolkit (a crash and Restart=always in between) is still due
    // when the file's list, against the session's start (not this shell's), says so, or when the file says it was found due
    // in this very session (the announcement marked with this session's start: the install times may have been unreadable
    // and recorded as asked for); a previous session's flag is not (the integrator's reviews of 9043ac4, e03013d and
    // f8b0916). The caller saves the adopted file once.
    function adopt(f: var): var {
        const n = SoftwareUpdateLogic.normalize(f);
        const replaced = SoftwareUpdateLogic.toolkitReplaced(n, sessionStartedAt, SoftwareUpdateLogic.toolkitAsked(n));
        if (replaced.length > 0 || SoftwareUpdateLogic.toolkitDueFromFile(n, sessionStartedAt))
            toolkitLogout = true;
        return SoftwareUpdateLogic.withLogoutPending(replaced.length > 0 ? SoftwareUpdateLogic.withToolkitAsked(n, replaced) : n, logoutPending, toolkitLogout);
    }

    // ---- automatic checks (U7) ----
    function reschedule(): void {
        if (!loaded)
            return;
        const at = SoftwareUpdateLogic.nextAutomatic(startedAt, SoftwareUpdateLogic.timeOf(file.checkedAt), SoftwareUpdateLogic.timeOf(file.retryAt), Tokens.softwareUpdateFirstCheckMs, Tokens.softwareUpdateIntervalMs);
        autoTimer.interval = Math.max(1000, Math.min(at - Date.now(), 2147483647));
        autoTimer.restart();
    }

    function automatic(): void {
        if (!Settings.updatesAutomaticCheck || checkProc.running || waitProc.running)
            return;
        if (!Connectivity.fullyConnected) {
            deferred = true;
            later();
            return;
        }
        if (SoftwareUpdateLogic.lowBattery(Battery.onBattery, Battery.present, Battery.percent, Tokens.softwareUpdateMinimumBatteryPercent)) {
            console.info("software update: automatic check skipped (on battery at " + Battery.percent + " %)");
            powerDeferred = true;
            later();
            return;
        }
        meteredHandled = false;
        meteredProc.didStart = false;
        meteredProc.command = meteredCommand;
        meteredTimeout.interval = meteredTimeoutMs;
        meteredTimeout.restart();
        meteredProc.running = true;
    }

    // Skipped (offline, metered, low battery): looked at again later, or when the connectivity or the power source changes.
    function later(): void {
        autoTimer.interval = Tokens.softwareUpdateRecheckMs;
        autoTimer.restart();
    }

    property bool meteredHandled: true

    function meteredResolved(metered: bool): void {
        if (meteredHandled)
            return;
        meteredHandled = true;
        meteredTimeout.stop();
        if (metered) {
            console.info("software update: automatic check skipped (metered connection)");
            later();
            return;
        }
        if (!checkProc.running && !waitProc.running)
            run(checkProc, false, checkTimeoutMs);
    }

    Timer {
        id: autoTimer
        onTriggered: root.automatic()
    }

    Timer {
        id: waitRetry
        interval: root.waitRetryMs
        onTriggered: {
            if (!checkProc.running && !waitProc.running)
                root.run(waitProc, true, root.waitTimeoutMs);
        }
    }

    Timer {
        id: busyTimer
        interval: Tokens.softwareUpdateBusyRetryMs
        onTriggered: {
            if (!checkProc.running && !waitProc.running)
                root.run(checkProc, false, root.checkTimeoutMs);
        }
    }

    Connections {
        target: Settings

        function onUpdatesAutomaticCheckChanged(): void {
            root.reschedule();
        }
    }

    Connections {
        target: Connectivity

        function onFullyConnectedChanged(): void {
            if (Connectivity.fullyConnected && root.deferred) {
                root.deferred = false;
                root.automatic();
            }
        }
    }

    Connections {
        target: Battery

        function onOnBatteryChanged(): void {
            if (!Battery.onBattery && root.powerDeferred) {
                root.powerDeferred = false;
                root.automatic();
            }
        }
    }

    Process {
        id: meteredProc
        // Set by started: a run that ends without it never started (see onRunningChanged).
        property bool didStart: false
        stdout: StdioCollector {
            id: meteredOut
        }
        onStarted: meteredProc.didStart = true
        // An unreadable answer (no nmcli, no NetworkManager, a hang) is not metered: the connectivity gate already passed.
        onRunningChanged: {
            if (!meteredProc.running && !meteredProc.didStart)
                root.meteredResolved(false);
        }
        // qmllint disable signal-handler-parameters
        onExited: exitCode => root.meteredResolved(exitCode === 0 && SoftwareUpdateLogic.metered(meteredOut.text))
        // qmllint enable signal-handler-parameters
    }

    Timer {
        id: meteredTimeout
        onTriggered: {
            if (meteredProc.running)
                meteredProc.signal(9);
            root.meteredResolved(false);
        }
    }

    // ---- the two runs of the checker: a check, and the waiter of U4 ----
    Process {
        id: checkProc
        property string text: ""
        property bool gotOut: false
        property bool gotExit: false
        // Set by started: a run that ends without it never started (see onRunningChanged).
        property bool didStart: false
        property bool stopped: false
        stdout: StdioCollector {
            onStreamFinished: {
                checkProc.text = text;
                checkProc.gotOut = true;
                root.finished(checkProc, false);
            }
        }
        onStarted: checkProc.didStart = true
        // Quickshell sends no `exited` when a start fails, only running going back to false without a `started`.
        onRunningChanged: {
            if (!checkProc.running && !checkProc.didStart) {
                checkProc.gotOut = true;
                checkProc.gotExit = true;
                root.finished(checkProc, false);
            }
        }
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            checkProc.gotExit = true;
            checkJoin.start();
            root.finished(checkProc, false);
        }
        // qmllint enable signal-handler-parameters
    }

    Process {
        id: waitProc
        property string text: ""
        property bool gotOut: false
        property bool gotExit: false
        property bool didStart: false
        property bool stopped: false
        stdout: StdioCollector {
            onStreamFinished: {
                waitProc.text = text;
                waitProc.gotOut = true;
                root.finished(waitProc, true);
            }
        }
        onStarted: waitProc.didStart = true
        onRunningChanged: {
            if (!waitProc.running && !waitProc.didStart) {
                waitProc.gotOut = true;
                waitProc.gotExit = true;
                root.finished(waitProc, true);
            }
        }
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            waitProc.gotExit = true;
            waitJoin.start();
            root.finished(waitProc, true);
        }
        // qmllint enable signal-handler-parameters
    }

    // The output may never arrive when the process could not start at all.
    Timer {
        id: checkJoin
        interval: 150
        onTriggered: {
            checkProc.gotOut = true;
            root.finished(checkProc, false);
        }
    }

    Timer {
        id: waitJoin
        interval: 150
        onTriggered: {
            waitProc.gotOut = true;
            root.finished(waitProc, true);
        }
    }

    // The checker stops itself at 180 s (U1); past the deadline it gets SIGTERM, so it stops its children, then SIGKILL.
    Timer {
        id: checkTimeout
        onTriggered: {
            if (!checkProc.running)
                return;
            checkProc.stopped = true;
            checkProc.signal(15);
            checkKill.restart();
        }
    }

    Timer {
        id: checkKill
        interval: 5000
        onTriggered: {
            if (checkProc.running)
                checkProc.signal(9);
        }
    }

    Timer {
        id: waitTimeout
        onTriggered: {
            if (!waitProc.running)
                return;
            waitProc.stopped = true;
            waitProc.signal(15);
            waitKill.restart();
        }
    }

    Timer {
        id: waitKill
        interval: 5000
        onTriggered: {
            if (waitProc.running)
                waitProc.signal(9);
        }
    }

    // ---- the state file ----
    Process {
        id: prepare
        running: true
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 \"$1\"; chmod 700 \"$1\"; [ -e \"$2\" ] || install -m 600 /dev/null \"$2\"; chmod 600 \"$2\"", "sh", Mode.stateDir, root.statePath]
        onRunningChanged: {
            if (!running)
                stateFile.path = root.statePath;
        }
    }

    Process {
        id: prepareRun
        running: root.runFolder !== ""
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 -- \"$1\"", "sh", root.runFolder]
        onRunningChanged: {
            if (!running)
                runFile.path = root.runPath;
        }
    }

    FileView {
        id: runFile
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.readRun(runFile.text())
    }

    FileView {
        id: stateFile
        printErrors: false
        atomicWrites: true
        onLoaded: {
            if (root.loaded)
                return;
            let f = null;
            try {
                f = JSON.parse(stateFile.text() || "{}");
            } catch (e) {
                f = null;
            }
            root.file = root.adopt(f);
            root.loaded = true;
            root.save(root.file);
            root.reschedule();
            root.resume();
        }
        onLoadFailed: {
            if (root.loaded)
                return;
            root.file = root.adopt(null);
            root.loaded = true;
            root.reschedule();
        }
    }

    IpcHandler {
        target: "update"

        // ADR-0033 d.7, U9: a check, which joins one already running. "user": Settings or Grassfield Store (what it finds is
        // shown there, never announced); "omarchy": the omarchy-shell shim from inside `omarchy update` (its lock is held:
        // the checker answers update-running and the waiter checks once it is released); "system": grassfield-pacman-watch
        // (ADR-0041 step 2b, U31: pacman's local database changed, the transaction's burst settled; announced as a scheduled
        // check is). Answers "ok", or "refused" for another origin. It starts only Grassfield's own checker and returns
        // nothing it found.
        function check(origin: string): string {
            if (origin !== "user" && origin !== "omarchy" && origin !== "system")
                return "refused";
            root.request(origin);
            return "ok";
        }
    }
}
