pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.platform

// Regeneration of the pointer cursor theme (shell/platform/PointerTheme.qml). Run by scripts/dev/test.sh:
// `qs -p tests/shell/pointer_theme` (offscreen). Prints "pointer-theme: PASS" and exits 0, or the failures and exits 1.
// With the fake builder (fake-build.sh, same arguments as branding/cursors/build.sh): a burst of colour changes makes
// one build for the last colour (debounce); colours that change while a build runs terminate it and the newest wins
// (never two builds at once); a failing build shows its reason, is not retried in a loop and leaves the state failed
// until the colours change; a missing script and a missing icons directory fail without a process; the default colours
// build nothing and Reset removes the theme; the status file for the Settings app follows. With the real build.sh (when
// hyprcursor-util, rsvg-convert and python3 are installed): a build under the test's temporary directory, checked by
// check_theme.py (manifest, archives, XCursor files, recoloured pixels), its time, and a build superseded mid-way that
// leaves no work directory behind.
ShellRoot {
    id: root

    readonly property string tmp: (Quickshell.env("TMPDIR") || "/tmp") + "/gfpt-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)
    readonly property string fake: Quickshell.shellPath("fake-build.sh")
    readonly property string realScript: Quickshell.shellPath("../../../branding/cursors/build.sh")
    readonly property string checker: Quickshell.shellPath("check_theme.py")
    readonly property string status: root.tmp + "/status.json"
    property var failures: []
    property int step: -1
    property double deadline: 0
    property var wait: null
    property double t0: 0
    property string out: ""
    property int code: -1
    property bool haveTools: false

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function log(): string {
        return root.out;
    }

    function lines(): var {
        return root.out.split("\n").filter(l => l !== "");
    }

    function count(prefix: string): int {
        return root.lines().filter(l => l.indexOf(prefix) === 0).length;
    }

    // Reads $tmp/icons/fake.log (the fake builder's log) into `out`, then continues.
    function readLog(next: var): void {
        root.run(["sh", "-c", "cat \"$1\" 2>/dev/null; exit 0", "sh", root.tmp + "/icons/fake.log"], next);
    }

    // Runs a command, keeps its stdout in `out` and its exit code in `code`, then continues.
    function run(argv: var, next: var): void {
        runner.next = next;
        runner.exited = false;
        runner.drained = false;
        runner.command = argv;
        runner.running = true;
    }

    PointerTheme {
        id: theme
        script: root.fake
        iconsDir: root.tmp + "/icons"
        statusPath: root.status
        debounceMs: 250
        timeoutMs: 20000
        killMs: 2000
    }

    // A second builder for the startup and stamp scenarios (its own icons directory, set when the scenario starts).
    PointerTheme {
        id: theme2
        script: root.fake
        iconsDir: ""
        debounceMs: 250
        timeoutMs: 20000
        killMs: 1500
    }

    function statusJson(next: var): void {
        root.run(["sh", "-c", "cat \"$1\" 2>/dev/null; exit 0", "sh", root.status], function () {
            let parsed = {};
            try {
                parsed = JSON.parse(root.out);
            } catch (e) {
                parsed = {};
            }
            next(parsed);
        });
    }

    readonly property var steps: [
        function () {
            // Burst: five colour changes in 200 ms make one build, for the last colour.
            theme.outline = "#aa0000";
            theme.fill = "#0000aa";
            burst.n = 0;
            burst.start();
            root.waitFor(() => theme.ready, 5000);
        },
        function () {
            root.check("burst: one build", theme.started === 1);
            root.check("burst: ready for the last colour only", theme.wantedKey === "#ffeedd|#112233" && theme.ready);
            root.readLog(() => root.advance());
        },
        function () {
            root.check("burst: the builder ran once, with the last colours", root.count("start") === 1 && root.lines()[0] === "start #ffeedd #112233");
            root.check("burst: command is argv without a shell", theme.lastCommand[0] === "setsid" && theme.lastCommand[1] === "bash" && theme.lastCommand.indexOf("--fill") > 0 && theme.lastCommand[theme.lastCommand.indexOf("--fill") + 1] === "#112233");
            root.statusJson(parsed => {
                root.check("burst: status ready for those colours", parsed.state === "ready" && parsed.outline === "#ffeedd" && parsed.fill === "#112233");
                root.advance();
            });
        },
        function () {
            // Supersede: a slow build is cancelled by newer colours, the newest wins, never two at once.
            theme.fill = "#00ff00";
            root.waitFor(() => theme.building && theme.started === 2, 3000);
        },
        function () {
            theme.fill = "#223344";
            root.waitFor(() => theme.ready && theme.wantedKey === "#ffeedd|#223344", 8000);
        },
        function () {
            root.check("supersede: the slow build was cancelled once", theme.cancelled === 1);
            root.check("supersede: two more builds started (slow one, then the newest)", theme.started === 3);
            root.readLog(() => root.advance());
        },
        function () {
            const l = root.lines();
            // Sequence: the first build, the slow start, its termination, the newest build: never two overlapping.
            const seq = l.map(x => x.split(" ")[0]).join(",");
            root.check("supersede: log sequence start,done,start,term,start,done (got " + seq + ")", seq === "start,done,start,term,start,done");
            root.check("supersede: the slow build was terminated, not completed", l.indexOf("term #00ff00") >= 0 && l.indexOf("done #ffeedd #00ff00") < 0);
            // Failure: the reason shows, no retry loop, the state is failed.
            theme.fill = "#ff0000";
            root.waitFor(() => theme.error !== "", 5000);
        },
        function () {
            root.check("failure: the reason is the tool's message", theme.error === "cursors: rsvg-convert not found");
            root.check("failure: not ready", !theme.ready);
            root.mark = theme.started;
            idle.start();
        },
        function () {
            root.check("failure: not retried while the colours stay", theme.started === root.mark);
            root.statusJson(parsed => {
                root.check("failure: status failed with the reason", parsed.state === "failed" && parsed.reason === "cursors: rsvg-convert not found" && parsed.fill === "#ff0000");
                root.advance();
            });
        },
        function () {
            theme.fill = "#334455";
            root.waitFor(() => theme.ready, 5000);
        },
        function () {
            root.check("failure: new colours build again and clear the reason", theme.error === "" && theme.ready);
            // Missing script: bash reports 127, the builder is "not installed".
            theme.script = "/nonexistent/grassfield/build.sh";
            theme.fill = "#445566";
            root.waitFor(() => theme.error !== "", 5000);
        },
        function () {
            root.check("missing script: reason", theme.error === "the cursor builder is not installed");
            theme.script = root.fake;
            // No icons directory (a dev session without the isolated one): nothing is started.
            theme.iconsDir = "";
            root.mark = theme.started;
            theme.fill = "#556677";
            root.waitFor(() => theme.error !== "" && theme.error.indexOf("no folder") === 0, 3000);
        },
        function () {
            root.check("no directory: nothing started", theme.started === root.mark);
            theme.iconsDir = root.tmp + "/icons";
            // Reset: the default colours, nothing to build, the theme is removed on request.
            theme.outline = "#ffffff";
            theme.fill = "#000000";
            root.mark = theme.started;
            root.waitFor(() => theme.wantedKey === "" && !theme.building, 2000);
        },
        function () {
            root.check("reset: no build for the default colours", theme.started === root.mark && !theme.ready && theme.error === "");
            root.run(["sh", "-c", "test -e \"$1\"/icons/grassfield-cursors-custom/colors; echo $?", "sh", root.tmp], () => root.advance());
        },
        function () {
            root.check("reset: the theme was there before the removal", root.out.trim() === "0");
            theme.removeTheme();
            root.waitFor(() => theme.removals === 1 && !theme.removing, 3000);
        },
        function () {
            root.run(["sh", "-c", "test -e \"$1\"/icons/grassfield-cursors-custom; echo $?", "sh", root.tmp], () => root.advance());
        },
        function () {
            root.check("reset: the custom theme is gone", root.out.trim() === "1");
            theme.removeTheme();
            idle.start();
        },
        function () {
            root.check("reset: nothing left to remove, no second removal", theme.removals === 1);
            root.statusJson(parsed => {
                root.check("reset: status default", parsed.state === "default");
                root.advance();
            });
        },
        function () {
            // The colours that were built before the reset, chosen again: the theme is gone, so it is built again.
            root.mark = theme.started;
            theme.outline = "#ffeedd";
            theme.fill = "#334455";
            root.waitFor(() => theme.ready, 5000);
        },
        function () {
            root.check("choosing the same colours after a reset builds again", theme.started === root.mark + 1);
            root.run(["sh", "-c", "test -e \"$1\"/icons/grassfield-cursors-custom/colors; echo $?", "sh", root.tmp], () => root.advance());
        },
        function () {
            root.check("the rebuilt theme is on disk", root.out.trim() === "0");
            theme.outline = "#ffffff";
            theme.fill = "#000000";
            theme.removeTheme();
            root.waitFor(() => theme.removals === 2 && !theme.removing, 3000);
        },
        function () {
            // Stubborn build: ignores SIGTERM, its child too. Superseded: killed after killMs, as a group.
            theme.fill = "#123456";
            root.waitFor(() => theme.building, 3000);
        },
        function () {
            root.run(["sh", "-c", "i=0; while [ ! -s \"$1\"/icons/grandchild.pid ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done; cat \"$1\"/icons/grandchild.pid", "sh", root.tmp], () => {
                root.child = root.out.trim();
                root.check("stubborn: the build's child runs (pid " + root.child + ")", /^[0-9]+$/.test(root.child));
                theme.fill = "#778899";
                root.waitFor(() => theme.ready && theme.wantedKey === "#ffffff|#778899", 12000);
            });
        },
        function () {
            root.check("stubborn: superseded build was cancelled", theme.cancelled >= 1);
            // Gone = no such process, or a zombie: it has exited, and reaping it is its new parent's job (PID 1 of a container
            // or a chroot may never reap, and kill -0 still succeeds on a zombie).
            root.run(["sh", "-c", "kill -0 \"$1\" 2>/dev/null || { echo 1; exit; }; s=$(sed 's/.*) //' /proc/\"$1\"/stat 2>/dev/null | cut -d' ' -f1); [ \"$s\" = Z ] && echo 1 || echo 0", "sh", root.child], () => root.advance());
        },
        function () {
            root.check("stubborn: its child (SIGTERM ignored) is gone after the group kill (gone -> " + root.out.trim() + ")", root.out.trim() === "1");
            root.check("stubborn: the newest colours were built next", theme.ready);
            // Startup in a real session: the icons directory holds the custom theme of an earlier session (stamp for
            // key K) and a work directory of a build that was killed. Colours are K: nothing is built, the stale
            // directory goes, the theme counts as ready.
            root.run(["sh", "-c", "d=\"$1\"/icons2; mkdir -p \"$d/grassfield-cursors-custom\" \"$d/.grassfield-cursors-custom.build.999999.stale\"; touch \"$d/grassfield-cursors-custom/manifest.hl\"; echo '#ffeedd #112233' > \"$d/grassfield-cursors-custom/colors\"", "sh", root.tmp], () => {
                theme2.outline = "#ffeedd";
                theme2.fill = "#112233";
                theme2.iconsDir = root.tmp + "/icons2";
                root.waitFor(() => theme2.ready && theme2.idle, 4000);
            });
        },
        function () {
            root.check("startup: a theme whose stamp matches the colours is used as it is, nothing built", theme2.started === 0 && theme2.ready);
            root.check("startup: clean-up ran once", theme2.cleanups === 1);
            root.run(["sh", "-c", "ls -A \"$1\"/icons2 | grep -v clean.log", "sh", root.tmp], () => {
                // Membership, not the first line: ls sorts by the locale (C puts the dot directories first, en_US ignores the dot).
                root.check("startup: the theme stays (" + root.out.trim() + ")", root.out.split("\n").indexOf("grassfield-cursors-custom") >= 0);
                // Colours differ from the stamp: a rebuild, then ready.
                theme2.fill = "#445566";
                root.waitFor(() => theme2.ready && theme2.started === 1, 5000);
            });
        },
        function () {
            root.check("startup: a stale stamp is rebuilt", theme2.started === 1 && theme2.ready);
            // A (built) -> B (cancelled before it replaced anything) -> A: the stamp still says A, nothing is rebuilt.
            theme2.fill = "#00ff00";
            root.waitFor(() => theme2.building, 3000);
        },
        function () {
            theme2.fill = "#445566";
            root.waitFor(() => theme2.ready && theme2.idle, 8000);
        },
        function () {
            root.check("A, B cancelled, A: A is ready again from the stamp, no rebuild (started " + theme2.started + ")", theme2.started === 2 && theme2.ready);
            // A -> B (installed, then cancelled): the stamp says B, so A is built again, never taken for built.
            theme2.fill = "#0000ff";
            root.waitFor(() => theme2.building, 3000);
        },
        function () {
            root.run(["sh", "-c", "i=0; while ! grep -q 0000ff \"$1\"/icons2/grassfield-cursors-custom/colors && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done; cat \"$1\"/icons2/grassfield-cursors-custom/colors", "sh", root.tmp], () => {
                root.check("B installed before the cancel (stamp " + root.out.trim() + ")", root.out.indexOf("#0000ff") > 0);
                theme2.fill = "#445566";
                root.waitFor(() => theme2.ready && theme2.idle, 8000);
            });
        },
        function () {
            root.check("A, B installed and cancelled, A: A is built again (started " + theme2.started + ")", theme2.started === 4 && theme2.ready);
            root.run(["cat", root.tmp + "/icons2/grassfield-cursors-custom/colors"], () => {
                root.check("A, B installed and cancelled, A: the theme on disk is A (" + root.out.trim() + ")", root.out.trim() === "#ffeedd #445566");
                root.advance();
            });
        },
        function () {
            // Real build.sh.
            root.run(["sh", "-c", "for t in hyprcursor-util rsvg-convert python3; do command -v $t >/dev/null || exit 1; done; exit 0", "sh"], () => {
                root.haveTools = root.code === 0;
                if (!root.haveTools)
                    console.log("pointer-theme: SKIP real build (hyprcursor-util, rsvg-convert or python3 not installed)");
                root.advance();
            });
        },
        function () {
            if (!root.haveTools) {
                root.finish();
                return;
            }
            theme.script = root.realScript;
            theme.iconsDir = root.tmp + "/real";
            theme.debounceMs = 100;
            // The real builder gets the product's own limit (Tokens.settingsPointerBuildTimeoutMs, 60 s), not the 20 s
            // meant for the fake one: on a loaded machine a real build takes longer than 20 s and was killed (exit 9).
            theme.timeoutMs = 60000;
            root.t0 = Date.now();
            theme.outline = "#ffff00";
            theme.fill = "#ff0000";
            root.waitFor(() => theme.ready || theme.error !== "", 90000);
        },
        function () {
            const ms = Date.now() - root.t0;
            console.log("pointer-theme: real build (debounce 100 ms included) took " + ms + " ms");
            root.check("real: built (error: " + theme.error + ")", theme.ready && theme.error === "");
            root.run(["python3", "-I", root.checker, root.tmp + "/real/grassfield-cursors-custom", "#ffff00", "#ff0000"], () => {
                console.log("pointer-theme: " + root.out.trim());
                root.check("real: theme content (" + root.out.trim() + ")", root.code === 0);
                root.advance();
            });
        },
        function () {
            // A real build superseded mid-way: terminated, the work directory is cleaned up, the newest colours are built.
            root.mark = theme.cancelled;
            theme.fill = "#00ff00";
            root.waitFor(() => theme.building, 3000);
        },
        function () {
            theme.outline = "#0000ff";
            root.waitFor(() => theme.ready && theme.wantedKey === "#0000ff|#00ff00", 90000);
        },
        function () {
            root.check("real supersede: cancelled once and the newest colours built", theme.cancelled === root.mark + 1 && theme.ready);
            root.run(["sh", "-c", "ls -A \"$1\"/real | grep -c '\\.build\\.' ; exit 0", "sh", root.tmp], () => root.advance());
        },
        function () {
            root.check("real supersede: no work directory left behind (" + root.out.trim() + ")", root.out.trim() === "0");
            root.run(["python3", "-I", root.checker, root.tmp + "/real/grassfield-cursors-custom", "#0000ff", "#00ff00"], () => {
                root.check("real supersede: theme has the newest colours (" + root.out.trim() + ")", root.code === 0);
                root.advance();
            });
        },
        function () {
            // Reset through the real script: --remove deletes only the theme.
            theme.outline = "#ffffff";
            theme.fill = "#000000";
            root.waitFor(() => theme.wantedKey === "" && !theme.building, 3000);
        },
        function () {
            theme.removeTheme();
            root.waitFor(() => theme.removals >= 1 && !theme.removing, 5000);
        },
        function () {
            root.run(["sh", "-c", "test -e \"$1\"/real/grassfield-cursors-custom; echo $?", "sh", root.tmp], () => {
                root.check("real remove: theme deleted", root.out.trim() === "1");
                root.finish();
            });
        }
    ]
    property int mark: 0
    property string child: ""

    function waitFor(predicate: var, ms: int): void {
        wait = predicate;
        deadline = Date.now() + ms;
        poll.start();
    }

    function advance(): void {
        step++;
        if (step < steps.length)
            steps[step]();
    }

    function finish(): void {
        poll.stop();
        cleanup.running = true;
    }

    Timer {
        id: poll
        interval: 40
        repeat: true
        onTriggered: {
            if (root.wait()) {
                poll.stop();
                root.advance();
            } else if (Date.now() > root.deadline) {
                poll.stop();
                root.check("step " + root.step + " timed out", false);
                root.finish();
            }
        }
    }

    // Five changes, 40 ms apart.
    Timer {
        id: burst
        property int n: 0
        interval: 40
        repeat: true
        onTriggered: {
            n++;
            const shade = ["#bb0000", "#cc0000", "#dd0000", "#ee0000"];
            if (n < 5) {
                theme.outline = shade[n - 1];
                theme.fill = "#00" + n + "0ff";
            } else {
                theme.outline = "#ffeedd";
                theme.fill = "#112233";
                burst.stop();
            }
        }
    }

    Timer {
        id: idle
        interval: 900
        onTriggered: root.advance()
    }

    // Runs one command at a time; the next step continues when the process ended and its stdout is complete.
    Process {
        id: runner
        property var next: null
        property bool exited: false
        property bool drained: false
        stdout: StdioCollector {
            id: runnerOut
            onStreamFinished: {
                runner.drained = true;
                runner.maybe();
            }
        }
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            // qmllint enable signal-handler-parameters
            root.code = exitCode;
            runner.exited = true;
            runner.maybe();
        }
        function maybe(): void {
            if (!exited || !drained)
                return;
            exited = false;
            drained = false;
            root.out = runnerOut.text;
            const continuation = next;
            next = null;
            continuation();
        }
    }

    Process {
        id: setup
        command: ["mkdir", "-p", root.tmp + "/icons"]
        onRunningChanged: {
            if (!running)
                root.advance();
        }
    }

    Process {
        id: cleanup
        command: ["rm", "-rf", root.tmp]
        onRunningChanged: {
            if (running)
                return;
            if (root.failures.length === 0) {
                console.log("pointer-theme: PASS");
                Qt.exit(0);
            } else {
                console.log("pointer-theme: FAIL " + root.failures.join("; "));
                Qt.exit(1);
            }
        }
    }

    Component.onCompleted: setup.running = true
}
