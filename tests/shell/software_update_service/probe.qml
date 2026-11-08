import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.overlay

// SoftwareUpdate (ADR-0033 d; docs/specs/updates.md U4, U10, U20, A9) as the shell runs it, with a fake checker (run by
// tests/shell/software_update_service.sh: a dev session, GRASSFIELD_UPDATE_CHECK_CMD=<fake>, the state under the test's
// directory). The fake answers what $FAKE/answer holds (or $FAKE/answer-waiter for --after-update-lock), logs each call
// with its arguments and XDG_CACHE_HOME to $FAKE/calls, hangs while $FAKE/hang exists and prints junk while $FAKE/junk
// exists. Steps, one after the other:
//   a  a check the user asked for: 2 releases recorded and counted, nothing announced (U20), both versions marked
//   b  Omarchy's request with a newer Grassfield: that version announced once, the Omarchy one already marked is not
//   c  the same answer again: nothing announced
//   d  two requests at once: one run (U4: a request joins the running check)
//   e  update-running: the waiter (--after-update-lock) runs and its answer is recorded; the releases kept meanwhile
//   f  junk on stdout: failed/unavailable recorded, the last success kept, no crash
//   g  a checker that cannot start: failed ("could not start")
//   h  a checker that hangs: stopped at the deadline, failed ("took too long")
//   i  busy: the file is not changed
//   w  a waiter whose own answer is update-running again: the next one waits for waitRetryMs (no loop)
//   r  Update Now's runs (U33): a run found already ended is not announced; one seen going on is, once, by its outcome; a
//      cancelled one is not; a restart at the end covers the toolkit's log out in the session (U31), another end does not
//   j  GF-083's pending logout written to the file
//   t  ADR-0041 step 2b (U31): a toolkit package installed before the session's start asks for nothing; one installed
//      after it is announced once as "toolkit" and the pending log out is written with its reason and the list; a later
//      update in the same session announces nothing more and the log out stays due
//   k  IPC (the script calls `qs ipc ... update check bogus|user|system` once "ipc-ready" is printed): bogus refused,
//      user and system ran one check each
// Prints "software-update-service: PASS" or FAIL <why>.
ShellRoot {
    id: root

    readonly property string fake: Quickshell.env("FAKE")
    property string failure: ""
    property int announced: 0
    property var lastAnnounce: []
    property int step: 0
    property int callsAtIpc: 0
    property var runEnds: []
    // Step k: once ready, every run that ends is logged ("ipc-run-done <n>"), so the script sends its second request only
    // after the first run ended (a request made during a run joins it, U4, and k would count one run: round 2's nit).
    property bool ipcReady: false
    property int ipcRuns: 0

    function check(cond: bool, what: string): void {
        if (!cond && failure === "")
            failure = what;
        console.log((cond ? "ok  " : "BAD ") + what);
    }

    // gf, om: a version or null (typed `var`: a string parameter would turn null into "null").
    function answer(gf: var, om: var): string {
        return JSON.stringify({version: 1, state: "available", channel: "stable", checkedAt: new Date().toISOString(), grassfield: {installed: "1.0.0-1", available: gf, notes: [], notesError: null}, omarchy: {installed: "4.0.4-1", available: om}, others: 1, otherPackages: [{name: "linux", installed: "6.18.1-1", available: "6.18.2-1"}]});
    }

    // One writer per file, on a fixed path: a FileView whose path changes just before setText can lose the write.
    // The real Grassfield menu (shell/overlay/SystemMenu.qml): the detail of its Settings… item.
    Component {
        id: menuComponent
        SystemMenu {}
    }

    function menuSettingsDetail(): string {
        const menu = menuComponent.createObject(null);
        if (menu === null)
            return "<no menu>";
        const item = menu.model.find(i => i.id === "settings");
        const detail = item ? item.detail : "<no Settings item>";
        menu.destroy();
        return detail;
    }

    function put(name: string, text: string): void {
        (name === "answer-waiter" ? waiterWriter : writer).setText(text);
    }

    function calls(): var {
        callsFile.reload();
        const t = callsFile.text();
        return t === "" ? [] : t.trim().split("\n");
    }

    Connections {
        target: SoftwareUpdate

        function onCheckingChanged(): void {
            if (root.ipcReady && !SoftwareUpdate.checking) {
                root.ipcRuns++;
                console.log("software-update-service: ipc-run-done " + root.ipcRuns);
            }
        }

        function onAnnounce(kind: string, version: string, installed: string): void {
            root.announced++;
            root.lastAnnounce = [kind, version, installed];
        }

        function onRunEnded(kind: string): void {
            root.runEnds = root.runEnds.concat([kind]);
        }
    }

    // The runner's state, as grassfield-update-run writes it (by rename), in the folder the service made.
    FileView {
        id: runWriter
        path: SoftwareUpdate.runPath
        printErrors: false
        atomicWrites: true
        blockWrites: true
    }

    function run(op: string, phase: string, result: string, restart: string): void {
        runWriter.setText(JSON.stringify({version: 1, op: op, pid: 1, startTime: "1", phase: phase, result: result, restart: restart,
            snapshot: "made", synced: true, deferred: [], startedAt: Date.now(), finishedAt: phase === "done" ? Date.now() : 0}));
    }

    FileView {
        id: writer
        path: root.fake + "/answer"
        printErrors: false
        blockLoading: true
        blockWrites: true
    }

    FileView {
        id: waiterWriter
        path: root.fake + "/answer-waiter"
        printErrors: false
        blockLoading: true
        blockWrites: true
    }

    FileView {
        id: callsFile
        path: root.fake + "/calls"
        printErrors: false
        blockLoading: true
    }

    FileView {
        id: stateFile
        path: SoftwareUpdate.statePath
        printErrors: false
        blockLoading: true
    }

    function stateText(): string {
        stateFile.reload();
        return stateFile.text();
    }

    Process {
        id: sh
        property var done: null
        // qmllint disable signal-handler-parameters
        onExited: if (done)
            done()
        // qmllint enable signal-handler-parameters
    }

    function shell(cmd: string, then: var): void {
        sh.done = then;
        sh.command = ["sh", "-c", cmd];
        sh.running = true;
    }

    Timer {
        id: tick
        interval: 300
        repeat: true
        property int waited: 0
        property var until: null
        property var next: null
        onTriggered: {
            waited += interval;
            if (until() || waited > 8000) {
                stop();
                next();
            }
        }
    }

    function when(cond: var, then: var): void {
        tick.waited = 0;
        tick.until = cond;
        tick.next = then;
        tick.restart();
    }

    Component.onCompleted: Qt.callLater(stepA)

    function stepA(): void {
        put("answer", answer("1.0.1-1", "4.0.6-1"));
        when(() => SoftwareUpdate.loaded, () => {
            SoftwareUpdate.request("user");
            when(() => !SoftwareUpdate.checking && calls().length === 1, () => {
                const f = SoftwareUpdate.file;
                root.check(f.state === "available" && SoftwareUpdate.count === 2, "a: state " + f.state + ", count " + SoftwareUpdate.count);
                root.check(SoftwareUpdate.menuDetail === "2 updates", "a: the Grassfield menu says " + JSON.stringify(SoftwareUpdate.menuDetail));
                root.check(root.menuSettingsDetail() === "2 updates", "a: the Grassfield menu's own Settings… item shows it: " + JSON.stringify(root.menuSettingsDetail()));
                root.check(root.announced === 0, "a: a user's check announces nothing (" + root.announced + ")");
                root.check(JSON.stringify(f.announced) === JSON.stringify(["grassfield 1.0.1-1", "omarchy 4.0.6-1"]), "a: both versions marked: " + JSON.stringify(f.announced));
                const saved = JSON.parse(root.stateText() || "{}");
                root.check(saved.state === "available" && saved.otherPackages.length === 1, "a: software-update.json written: " + saved.state);
                const c = calls()[0];
                root.check(c.indexOf("args=|") >= 0, "a: no option while online: " + c);
                root.check(c.indexOf("cache=" + Quickshell.env("GRASSFIELD_STATE_HOME") + "/cache") >= 0, "a: the checker's cache under the dev state: " + c);
                stepB();
            });
        });
    }

    function stepB(): void {
        put("answer", answer("1.0.2-1", "4.0.6-1"));
        SoftwareUpdate.request("omarchy");
        when(() => !SoftwareUpdate.checking && calls().length === 2, () => {
            root.check(root.announced === 1 && root.lastAnnounce[0] === "grassfield" && root.lastAnnounce[1] === "1.0.2-1" && root.lastAnnounce[2] === "1.0.0-1", "b: Grassfield 1.0.2-1 announced once: " + root.announced + " " + JSON.stringify(root.lastAnnounce));
            root.check(SoftwareUpdate.releaseName("1.0.2-1", "1.0.0-1") === "1.0.2", "b: its name");
            SoftwareUpdate.request("omarchy");
            when(() => !SoftwareUpdate.checking && calls().length === 3, () => {
                root.check(root.announced === 1, "c: the same answer again announces nothing (" + root.announced + ")");
                stepD();
            });
        });
    }

    function stepD(): void {
        shell("touch '" + root.fake + "/hang'", stepD2);
    }

    function stepD2(): void {
        SoftwareUpdate.request("user");
        SoftwareUpdate.request("user");
        SoftwareUpdate.request("omarchy");
        when(() => calls().length >= 4, () => {
            shell("rm -f '" + root.fake + "/hang'", () => {
                when(() => !SoftwareUpdate.checking, () => {
                    root.check(calls().length === 4, "d: three requests at once ran one check (" + calls().length + " runs)");
                    stepE();
                });
            });
        });
    }

    function stepE(): void {
        put("answer", JSON.stringify({version: 1, state: "update-running", checkedAt: new Date().toISOString()}));
        put("answer-waiter", JSON.stringify({version: 1, state: "up-to-date", channel: "stable", checkedAt: new Date().toISOString(), grassfield: {installed: "1.0.2-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}, others: 0, otherPackages: []}));
        shell("touch '" + root.fake + "/hang-waiter'", stepE2);
    }

    function stepE2(): void {
        SoftwareUpdate.request("omarchy");
        when(() => SoftwareUpdate.waiting && calls().slice(-1)[0].indexOf("--after-update-lock") >= 0, () => {
            const f = SoftwareUpdate.file;
            root.check(f.state === "update-running" && SoftwareUpdate.count === 2, "e: update-running recorded, the releases kept meanwhile (" + f.state + ", " + SoftwareUpdate.count + ")");
            root.check(calls().slice(-1)[0].indexOf("--after-update-lock") >= 0, "e: the waiter runs with --after-update-lock: " + calls().slice(-1)[0]);
            SoftwareUpdate.request("user");
            shell("rm -f '" + root.fake + "/hang-waiter'", () => {
                when(() => !SoftwareUpdate.waiting && SoftwareUpdate.file.state === "up-to-date", () => {
                    root.check(calls().length === 6, "e: a request while the waiter runs joins it (" + calls().length + " runs)");
                    root.check(SoftwareUpdate.file.state === "up-to-date" && SoftwareUpdate.count === 0, "e: the waiter's answer recorded: " + SoftwareUpdate.file.state);
                    root.check(SoftwareUpdate.menuDetail === "", "e: nothing after Settings… without a release: " + JSON.stringify(SoftwareUpdate.menuDetail));
                    stepF();
                });
            });
        });
    }

    function stepF(): void {
        put("answer", answer("1.0.3-1", null));
        SoftwareUpdate.request("user");
        when(() => !SoftwareUpdate.checking && SoftwareUpdate.file.state === "available", () => {
            shell("touch '" + root.fake + "/junk'", () => SoftwareUpdate.request("user"));
            when(() => !SoftwareUpdate.checking && SoftwareUpdate.file.state === "failed", () => {
                const f = SoftwareUpdate.file;
                root.check(f.error === "unavailable" && f.message === "the checker gave no answer", "f: junk -> failed: " + f.error + " " + f.message);
                root.check(SoftwareUpdate.count === 1 && f.previous.grassfield.available === "1.0.3-1", "f: the last success kept (" + SoftwareUpdate.count + ")");
                root.check(SoftwareUpdate.menuDetail === "1 update", "f: the Grassfield menu says " + JSON.stringify(SoftwareUpdate.menuDetail));
                shell("rm -f '" + root.fake + "/junk'", stepG);
            });
        });
    }

    function stepG(): void {
        const real = SoftwareUpdate.program;
        SoftwareUpdate.program = "/nonexistent/grassfield-update-check";
        SoftwareUpdate.request("user");
        when(() => !SoftwareUpdate.checking && SoftwareUpdate.file.message === "the checker could not start", () => {
            root.check(SoftwareUpdate.file.state === "failed", "g: a checker that cannot start -> failed: " + SoftwareUpdate.file.message);
            SoftwareUpdate.program = real;
            stepH();
        });
    }

    function stepH(): void {
        shell("touch '" + root.fake + "/hang'", stepH2);
    }

    function stepH2(): void {
        SoftwareUpdate.checkTimeoutMs = 800;
        SoftwareUpdate.request("user");
        when(() => !SoftwareUpdate.checking && SoftwareUpdate.file.message === "the check took too long", () => {
            root.check(SoftwareUpdate.file.state === "failed", "h: a hung checker stopped at its deadline: " + SoftwareUpdate.file.message);
            SoftwareUpdate.checkTimeoutMs = 200000;
            shell("rm -f '" + root.fake + "/hang'", stepI);
        });
    }

    function stepI(): void {
        const before = JSON.stringify(SoftwareUpdate.file);
        const n = calls().length;
        put("answer", JSON.stringify({version: 1, state: "busy", checkedAt: new Date().toISOString()}));
        SoftwareUpdate.request("user");
        when(() => !SoftwareUpdate.checking && calls().length === n + 1, () => {
            root.check(JSON.stringify(SoftwareUpdate.file) === before, "i: busy changes nothing");
            stepW();
        });
    }

    function waiterRuns(): int {
        return calls().filter(c => c.indexOf("--after-update-lock") >= 0).length;
    }

    function stepW(): void {
        const running = JSON.stringify({version: 1, state: "update-running", checkedAt: new Date().toISOString()});
        put("answer", running);
        put("answer-waiter", running);
        const before = root.waiterRuns();
        SoftwareUpdate.request("omarchy");
        when(() => root.waiterRuns() > before && !SoftwareUpdate.waiting, () => {
            // Two seconds more: a waiter restarted without a pause would have run dozens of times by then.
            pause.next = () => {
                root.check(root.waiterRuns() === before + 1, "w: the waiter's own update-running starts no other at once (" + (root.waiterRuns() - before) + " runs)");
                root.check(SoftwareUpdate.file.state === "update-running", "w: the state stays update-running");
                put("answer-waiter", JSON.stringify({version: 1, state: "up-to-date", channel: "stable", checkedAt: new Date().toISOString(), grassfield: {installed: "1.0.3-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}, others: 0, otherPackages: []}));
                stepR();
            };
            pause.restart();
        });
    }

    function stepR(): void {
        const a = "a".repeat(32), b = "b".repeat(32), c = "c".repeat(32), d = "d".repeat(32);
        root.check(SoftwareUpdate.runPath !== "", "r: the runner's state is watched in the runtime folder");
        root.run(a, "done", "done", "restart");
        pause.next = () => {
            root.check(root.runEnds.length === 0, "r: a run found already ended is not announced (" + root.runEnds + ")");
            root.run(b, "authorizing", "", "");
            when(() => SoftwareUpdate.runningOp === b, () => {
                root.check(SoftwareUpdate.runningOp === b, "r: a run going on is seen");
                root.run(b, "done", "done", "restart");
                when(() => root.runEnds.length > 0, () => {
                    root.check(JSON.stringify(root.runEnds) === JSON.stringify(["restart"]), "r: its end is announced once, as a restart (" + root.runEnds + ")");
                    // The restart covers the toolkit's log out in this session (U31: its notice is not posted after it).
                    const covered = "toolkit " + SoftwareUpdate.sessionStartedAt;
                    root.check(SoftwareUpdate.file.announced.indexOf(covered) >= 0, "r: the restart covers the toolkit's log out in this session (" + covered + " marked)");
                    // Step t tests the toolkit's own notice in this same session: the mark is taken back (test plumbing).
                    SoftwareUpdate.save(Object.assign({}, SoftwareUpdate.file, {announced: SoftwareUpdate.file.announced.filter(id => id !== covered)}));
                    // The same end written again, read alone (the pause): no second notice.
                    root.run(b, "done", "done", "restart");
                    pause.next = () => {
                        root.check(JSON.stringify(root.runEnds) === JSON.stringify(["restart"]), "r: the same end written again says nothing (" + root.runEnds + ")");
                        root.run(c, "configuring", "", "");
                        when(() => SoftwareUpdate.runningOp === c, () => {
                            root.check(SoftwareUpdate.runningOp === c, "r: a run configuring is a run going on");
                            root.run(c, "done", "cancelled", "");
                            when(() => SoftwareUpdate.runningOp === "", () => {
                                root.check(SoftwareUpdate.runningOp === "", "r: a cancelled run ends");
                                root.check(JSON.stringify(root.runEnds) === JSON.stringify(["restart", ""]), "r: a cancelled run deserves no notice (" + JSON.stringify(root.runEnds) + ")");
                                root.run(d, "authorizing", "", "");
                                when(() => SoftwareUpdate.runningOp === d, () => {
                                    root.check(SoftwareUpdate.runningOp === d, "r: the next run going on is seen");
                                    root.run(d, "done", "incompatible", "");
                                    when(() => root.runEnds.length > 2, () => {
                                        root.check(JSON.stringify(root.runEnds) === JSON.stringify(["restart", "", "incompatible"]), "r: an incompatible one is announced (" + JSON.stringify(root.runEnds) + ")");
                                        root.check(typeof SoftwareUpdate.file.holdRefusedAt === "number" && Math.abs(Date.now() - SoftwareUpdate.file.holdRefusedAt) < 60000, "r: the first refused update starts the 7 days (" + SoftwareUpdate.file.holdRefusedAt + ")");
                                        root.check(!SoftwareUpdate.holdWaitOver(), "r: and they are not over");
                                        root.check(SoftwareUpdate.file.announced.indexOf("toolkit " + SoftwareUpdate.sessionStartedAt) < 0, "r: an end that asks for no restart covers nothing");
                                        stepJ();
                                    });
                                });
                            });
                        });
                    };
                    pause.restart();
                });
            });
        };
        pause.restart();
    }

    Timer {
        id: pause
        interval: 2000
        property var next: null
        onTriggered: next()
    }

    function stepJ(): void {
        SoftwareUpdate.logoutPending = true;
        when(() => (JSON.parse(root.stateText() || "{}").logoutPending === true), () => {
            root.check(JSON.parse(root.stateText() || "{}").logoutPending === true, "j: the pending logout written");
            stepT();
        });
    }

    // U31: an up-to-date answer whose toolkit lists qt6-base installed at `at` (a move away from the record too).
    function toolkitAnswer(at: string): string {
        return JSON.stringify({version: 1, state: "up-to-date", channel: "stable", checkedAt: new Date().toISOString(), grassfield: {installed: "1.0.3-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}, others: 0, otherPackages: [], toolkit: {record: true, packages: [{name: "qt6-base", installed: "6.12.0-1", installedAt: at, built: "6.11.2-1", moved: true}]}});
    }

    // The saved file, or {} while it is not valid JSON (it is rewritten atomically, but read here between writes).
    function saved(): var {
        try {
            return JSON.parse(root.stateText() || "{}");
        } catch (e) {
            return {};
        }
    }

    // The install time the saved file's toolkit list carries ("" before the service saved an answer with one): what a
    // step waits for, since the check's end is not the save's (the integrator's review of e03013d, major B).
    function savedToolkitAt(): string {
        const s = root.saved();
        return s.toolkit && s.toolkit.packages && s.toolkit.packages[0] ? String(s.toolkit.packages[0].installedAt) : "";
    }

    function stepT(): void {
        SoftwareUpdate.sessionStartedAt = Date.parse("2026-10-28T10:00:00Z");
        const before = root.announced;
        put("answer", toolkitAnswer("2026-10-28T09:00:00Z"));
        SoftwareUpdate.request("omarchy");
        when(() => !SoftwareUpdate.checking && root.savedToolkitAt() === "2026-10-28T09:00:00Z", () => {
            const saved1 = root.saved();
            root.check(root.announced === before && !SoftwareUpdate.toolkitLogout && saved1.toolkitLogout === undefined && saved1.logoutPending === true, "t1: a package installed before the session's start asks for nothing (" + (root.announced - before) + " announced, toolkit flag " + saved1.toolkitLogout + ", GF-083's own log out kept " + saved1.logoutPending + ")");
            put("answer", toolkitAnswer("2026-10-28T11:00:00Z"));
            SoftwareUpdate.request("omarchy");
            when(() => !SoftwareUpdate.checking && root.savedToolkitAt() === "2026-10-28T11:00:00Z" && root.saved().toolkitLogout === true, () => {
                const saved2 = root.saved();
                root.check(root.announced === before + 1 && root.lastAnnounce[0] === "toolkit" && SoftwareUpdate.toolkitLogout, "t2: a package installed after the session's start: announced once as toolkit (" + (root.announced - before) + ", " + JSON.stringify(root.lastAnnounce) + ")");
                root.check(saved2.logoutPending === true && saved2.toolkitLogout === true && saved2.announced.indexOf("toolkit " + SoftwareUpdate.sessionStartedAt) >= 0, "t2: the pending log out written with its reason and the announcement marked: " + JSON.stringify([saved2.logoutPending, saved2.toolkitLogout, saved2.announced]));
                put("answer", toolkitAnswer("2026-10-28T11:30:00Z"));
                SoftwareUpdate.request("omarchy");
                when(() => !SoftwareUpdate.checking && root.savedToolkitAt() === "2026-10-28T11:30:00Z", () => {
                    root.check(root.announced === before + 1 && SoftwareUpdate.toolkitLogout && root.saved().toolkitLogout === true, "t3: a later update in the same session announces nothing more, the log out stays due (" + (root.announced - before) + ")");
                    stepK();
                });
            });
        });
    }

    // The calls log is read again until two reads agree before step k's baseline is taken: the t-steps read it no more,
    // and the first reload after them can return the content before their three runs (the integrator's review of
    // f8b0916, round 3: k then counted their runs as its own).
    property int callsLast: -1

    function stepK(): void {
        put("answer", answer(null, null));
        root.callsLast = -1;
        when(() => {
            const n = calls().length;
            const stable = n === root.callsLast;
            root.callsLast = n;
            return stable;
        }, () => {
            root.callsAtIpc = root.callsLast;
            root.ipcReady = true;
            console.log("software-update-service: ipc-ready");
            // The script asks `bogus` (refused: no run), `user` and `system` (ADR-0041 U31): two runs.
            when(() => calls().length >= root.callsAtIpc + 2, finish);
        });
    }

    function finish(): void {
        root.check(calls().length === root.callsAtIpc + 2, "k: `update check user` and `update check system` over IPC ran one check each, `bogus` none (" + (calls().length - root.callsAtIpc) + ")");
        console.log(root.failure === "" ? "software-update-service: PASS" : "software-update-service: FAIL " + root.failure);
        Qt.quit();
    }
}
