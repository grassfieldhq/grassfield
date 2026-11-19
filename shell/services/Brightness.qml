pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import qs.lib
import Quickshell.Io
import "BrightnessLogic.js" as Logic

// Backlight of the first /sys/class/backlight device. Absent when there is none (desktops):
// available stays false and the OSD and IPC do nothing. Changes made by anyone (brightness keys,
// brightnessctl) are seen through the sysfs file; set() goes through brightnessctl.
//
// External displays (outputs without a backlight) over DDC/CI, ADR-0045 OC-4: see "External displays" below.
//
// In a GRASSFIELD_DEV session the hardware is never changed (the nested shell runs on the owner's
// machine): set() only logs.
Singleton {
    id: root

    property string device: ""
    property int max: 0
    property int value: 0
    // True after the first read; consumers ignore changes before that.
    property bool loaded: false

    // Visual-test fixture (GRASSFIELD_DEV and GRASSFIELD_VISUAL_FIXTURES): a backlight at 50 percent, no keyboard backlight.
    readonly property bool available: VisualFixtures.active || (device !== "" && max > 0)
    readonly property real level: VisualFixtures.active ? 0.5 : (available ? Math.max(0, Math.min(1, value / max)) : 0)
    // The real backlight, whatever the fixtures say (the IPC level hook reads these, never `available` or `level`).
    readonly property bool deviceAvailable: device !== "" && max > 0
    readonly property real deviceLevel: deviceAvailable ? Math.max(0, Math.min(1, value / max)) : 0
    readonly property bool devSession: Mode.dev

    signal commandFinished

    // delta: fraction of the range (0.05 = 5 percent). Returns false when nothing was changed.
    function adjust(delta: real): bool {
        if (devSession) {
            console.info("brightness: dev session, not changing the backlight (" + (delta > 0 ? "+" : "") + Math.round(delta * 100) + "%)");
            return false;
        }
        if (!available)
            return false;
        const pct = Math.round(Math.abs(delta) * 100) * (delta > 0 ? 1 : -1);
        // Starting a process that still runs does nothing: the step waits for the running one to end (setter.next).
        if (setter.running) {
            if (setter.pendingSet >= 0)
                setter.pendingSet = Math.max(0, Math.min(100, setter.pendingSet + pct));
            else
                setter.pendingStep += pct;
            return true;
        }
        setter.step(pct);
        return true;
    }

    // Absolute level 0..1 (a slider). Returns false when nothing was changed.
    function setLevel(fraction: real): bool {
        if (devSession) {
            console.info("brightness: dev session, not changing the backlight (set " + Math.round(fraction * 100) + "%)");
            return false;
        }
        if (!available)
            return false;
        const pct = Math.round(Math.max(0, Math.min(1, fraction)) * 100);
        // The same wait as adjust(); the last level asked wins over what waited.
        if (setter.running) {
            setter.pendingSet = pct;
            setter.pendingStep = 0;
            return true;
        }
        setter.set(pct);
        return true;
    }

    // Keyboard backlight (/sys/class/leds/*kbd_backlight). Absent on most desktops.
    property string kbdDevice: ""
    property int kbdMax: 0
    property int kbdValue: 0
    readonly property bool kbdAvailable: !VisualFixtures.active && kbdDevice !== "" && kbdMax > 0
    readonly property real kbdLevel: kbdAvailable ? Math.max(0, Math.min(1, kbdValue / kbdMax)) : 0

    function setKbdLevel(fraction: real): bool {
        if (devSession) {
            console.info("brightness: dev session, not changing the keyboard backlight");
            return false;
        }
        if (!kbdAvailable)
            return false;
        const raw = Math.round(Math.max(0, Math.min(1, fraction)) * root.kbdMax);
        // Starting a process that still runs does nothing: the level waits for the running one to end, the last one winning.
        if (kbdSetter.running) {
            kbdSetter.pending = raw;
            return true;
        }
        kbdSetter.set(raw);
        return true;
    }

    // ---- External displays: brightness over DDC/CI (ADR-0045 OC-4) ----
    // An output without a backlight is driven by Omarchy's `omarchy-brightness-display-ddc <monitor> [N%|+N%|N%-]` (ddcutil
    // behind it), run as an argument vector, never through a shell. Each connected external output is asked its level once when
    // it appears (the command with the monitor alone); one that answers is "ok" and the brightness keys (Osd.brightnessStep) and
    // Quick Settings' Display slider drive it. At most one command per output at a time: what comes meanwhile waits, merged, the
    // last value winning (BrightnessLogic.js), since a DDC write takes 50 to 200 ms. The level known is the one the command last
    // printed, moved at once by the requests made since. Nothing reads it again on its own (DDC/CI has no change event): a key
    // steps from the display's own level (`+5%`, `5%-`: the command reads it first), so a change made elsewhere (Settings, the
    // display's buttons) is never stepped over. No i2c access (the i2c-dev module or the permission on /dev/i2c-* missing),
    // a display without DDC/CI, or no command: no control for that output and one journal line. A dev session and the visual
    // fixtures never run it (their outputs are the nested compositor's; the displays are the owner's).
    readonly property bool ddcAllowed: !root.devSession && !VisualFixtures.active
    // The command exists (`command -v`, again whenever the outputs change: Omarchy may install or rename it meanwhile).
    property bool ddcCommand: false
    property bool ddcMissingLogged: false
    // Output name -> BrightnessLogic entry (status, level, the queue).
    property var ddc: ({})
    // Output name -> true while a command runs for it; the last entry number given (BrightnessLogic.sync).
    property var ddcJobs: ({})
    property int ddcSerial: 0
    readonly property var outputNames: Quickshell.screens.map(s => s.name)

    // The known level of external output `name` changed (a key, the slider, or the command's answer).
    signal outputLevelChanged(string name)

    // External output `name` answers DDC/CI.
    function outputAnswers(name: string): bool {
        return Logic.answers(root.ddc, name);
    }

    // Level 0..1 of external output `name`, -1 when it does not answer.
    function outputLevel(name: string): real {
        return Logic.answers(root.ddc, name) ? Math.max(0, Math.min(1, root.ddc[name].level / 100)) : -1;
    }

    // One brightness key on external output `name` ("up" or "down"). Returns the level it will have (0..1, what the OSD shows
    // at once; the command's answer corrects it), -1 when nothing was asked.
    function stepOutput(name: string, direction: string): real {
        if (direction !== "up" && direction !== "down")
            return -1;
        return root.ddcRequest(name, {kind: "step", steps: direction === "up" ? 1 : -1});
    }

    // Absolute level 0..1 of external output `name` (Quick Settings' slider; the last value wins). Returns false when nothing
    // was asked.
    function setOutputLevel(name: string, fraction: real): bool {
        if (!isFinite(fraction))
            return false;
        return root.ddcRequest(name, {kind: "set", percent: Math.round(Math.max(0, Math.min(1, fraction)) * 100)}) >= 0;
    }

    function ddcRequest(name: string, request: var): real {
        if (!root.ddcAllowed) {
            console.info("brightness: dev session, not changing " + name);
            return -1;
        }
        if (!Logic.answers(root.ddc, name))
            return -1;
        const r = Logic.request(root.ddc[name], name, request);
        root.ddcStore(name, r.entry);
        if (r.start !== null)
            root.ddcRun(name, r.entry.serial, r.start);
        return root.outputLevel(name);
    }

    function ddcStore(name: string, entry: var): void {
        const before = root.ddc[name] ? root.ddc[name].level : -1;
        const next = Object.assign({}, root.ddc);
        next[name] = entry;
        root.ddc = next;
        if (entry.level !== before)
            root.outputLevelChanged(name);
    }

    function ddcRun(name: string, serial: int, argv: var): void {
        const jobs = Object.assign({}, root.ddcJobs);
        jobs[name] = true;
        root.ddcJobs = jobs;
        const job = ddcJob.createObject(root, {output: name, serial: serial, argv: argv});
        if (job)
            job.start();
        else
            root.ddcFinished(name, serial, "");
    }

    // A command of output `name` (started for its display number `serial`) ended and printed `text`.
    function ddcFinished(name: string, serial: int, text: string): void {
        const jobs = Object.assign({}, root.ddcJobs);
        delete jobs[name];
        root.ddcJobs = jobs;
        // The output went away meanwhile: nothing to learn.
        if (!Object.prototype.hasOwnProperty.call(root.ddc, name))
            return;
        const entry = root.ddc[name];
        const r = entry.serial === serial ? Logic.finished(entry, name, text) : Logic.released(entry, name);
        root.ddcStore(name, r.entry);
        if (r.failed === true)
            console.info("brightness: " + name + " does not answer DDC/CI (" + Logic.COMMAND + "); its brightness is left to the display."
                + " It needs the i2c-dev module, access to /dev/i2c-* and DDC/CI on in the display's own menu");
        if (r.start !== null)
            root.ddcRun(name, r.entry.serial, r.start);
    }

    // The outputs changed (or the shell started): forget the outputs that went away at once (a display plugged back is asked
    // again), look for the command, then ask the new external outputs.
    function ddcSync(): void {
        if (!root.ddcAllowed)
            return;
        root.ddc = Logic.forget(root.ddc, root.outputNames);
        // A check still running is left to end (stopping it would start nothing and its empty answer would read as "no
        // command", forgetting every display): it runs once more after, and only that last answer is used.
        if (ddcCheck.running)
            ddcCheck.again = true;
        else
            ddcCheck.running = true;
    }

    function ddcProbe(): void {
        const s = Logic.sync(root.ddc, root.outputNames, root.ddcJobs, root.ddcSerial);
        root.ddcSerial = s.serial;
        if (!root.ddcCommand) {
            if (Object.keys(s.ddc).length > 0 && !root.ddcMissingLogged) {
                root.ddcMissingLogged = true;
                console.info("brightness: " + Logic.COMMAND + " (or coreutils' " + Logic.BOUND[0] + ") is missing; external displays keep their own brightness");
            }
            root.ddc = ({});
            return;
        }
        root.ddc = s.ddc;
        for (const name of s.ask) {
            const r = Logic.request(root.ddc[name], name, {kind: "query"});
            root.ddcStore(name, r.entry);
            if (r.start !== null)
                root.ddcRun(name, r.entry.serial, r.start);
        }
    }

    onOutputNamesChanged: root.ddcSync()

    function refresh(): void {
        current.reload();
        kbdCurrent.reload();
    }

    Component.onCompleted: {
        finder.running = true;
        if (root.ddcAllowed)
            root.ddcSync();
        else if (root.devSession)
            console.info("brightness: dev session, external displays are not asked over DDC/CI");
    }

    // A fixed command line, no data in it: the command's path, printed only when coreutils' timeout (its bound) is there too.
    Process {
        id: ddcCheck
        // Set when the outputs changed while the check was running: run it once more.
        property bool again: false
        command: ["sh", "-c", "command -v " + Logic.BOUND[0] + " >/dev/null && command -v " + Logic.COMMAND]
        stdout: StdioCollector {
            onStreamFinished: {
                // Another run follows: its answer is the one that counts.
                if (ddcCheck.again)
                    return;
                root.ddcCommand = text.trim() !== "";
                root.ddcProbe();
            }
        }
        onRunningChanged: {
            if (!running && again) {
                again = false;
                running = true;
            }
        }
    }

    // One run of the DDC command for one output: an argument vector under its bound (BrightnessLogic.BOUND: coreutils' timeout
    // ends the whole process group, ddcutil included), its output read once it has ended (a process that could not start has
    // none: the answer comes from its end alone, a moment later). It reports to ddcFinished exactly once, and only once its
    // process has really ended: until then the output stays busy and nothing else runs on its bus. A run still going after
    // BrightnessLogic.BACKSTOP_MS (past the bound and its kill) is asked to stop again and still waited for. Then it goes.
    Component {
        id: ddcJob

        Scope {
            id: job

            required property string output
            required property int serial
            required property var argv
            property string out: ""
            property int code: -1
            property bool gotOut: false
            // The process ended: its exit came, or it stopped running and no exit came within the join (one that could not
            // start never exits).
            property bool ended: false
            property bool stopped: false
            property bool timedOut: false
            property bool reported: false

            function start(): void {
                proc.running = true;
            }

            function check(): void {
                if (job.gotOut && job.ended)
                    job.done();
            }

            function end(): void {
                job.ended = true;
                join.start();
                job.check();
            }

            // Only a run that exited 0 within its time answers; its output is the level. Never before the process has ended.
            function done(): void {
                if (job.reported || !job.ended)
                    return;
                job.reported = true;
                root.ddcFinished(job.output, job.serial, job.code === 0 && !job.timedOut ? job.out : "");
                job.destroy();
            }

            Process {
                id: proc
                command: job.argv
                stdout: StdioCollector {
                    onStreamFinished: {
                        job.out = text;
                        job.gotOut = true;
                        job.check();
                    }
                }
                // qmllint disable signal-handler-parameters
                onExited: exitCode => {
                    // qmllint enable signal-handler-parameters
                    job.code = exitCode;
                    job.end();
                }
                // Not running any more: its exit (and output) may still be on the way; the join settles it.
                onRunningChanged: {
                    if (!proc.running) {
                        job.stopped = true;
                        join.start();
                    }
                }
            }

            Timer {
                id: join
                interval: 150
                onTriggered: {
                    if (job.stopped)
                        job.ended = true;
                    job.done();
                }
            }

            // TERM to timeout, which passes it to the command's group and kills the group 2 s later.
            Timer {
                interval: Logic.BACKSTOP_MS
                running: true
                onTriggered: {
                    job.timedOut = true;
                    if (proc.running) {
                        proc.signal(15);
                    } else {
                        job.stopped = true;
                        job.end();
                    }
                }
            }
        }
    }

    Process {
        id: kbdSetter
        // Raw level asked while a run was going (-1: none); started when that one is gone.
        property int pending: -1

        function set(raw: int): void {
            kbdSetter.command = ["brightnessctl", "-q", "-d", root.kbdDevice, "set", raw.toString()];
            kbdSetter.running = true;
        }

        onRunningChanged: {
            if (running)
                return;
            root.refresh();
            if (pending >= 0) {
                const raw = pending;
                pending = -1;
                kbdSetter.set(raw);
            }
        }
    }

    FileView {
        id: kbdMaximum
        path: root.kbdDevice !== "" ? "/sys/class/leds/" + root.kbdDevice + "/max_brightness" : ""
        printErrors: false
        onLoaded: root.kbdMax = parseInt(kbdMaximum.text().trim(), 10) || 0
    }

    FileView {
        id: kbdCurrent
        path: root.kbdDevice !== "" ? "/sys/class/leds/" + root.kbdDevice + "/brightness" : ""
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.kbdValue = parseInt(kbdCurrent.text().trim(), 10) || 0
    }

    // The backlight and the keyboard backlight, both found by one shell with its own globbing (no ls, grep or head child: one
    // process at start instead of two pipelines of three): line 1 the first /sys/class/backlight device, line 2 the first
    // /sys/class/leds/*kbd_backlight* (either empty when there is none).
    Process {
        id: finder
        command: ["sh", "-c", "b=; for d in /sys/class/backlight/*; do [ -e \"$d\" ] && { b=${d##*/}; break; }; done; k=; for d in /sys/class/leds/*kbd_backlight*; do [ -e \"$d\" ] && { k=${d##*/}; break; }; done; printf '%s\\n%s\\n' \"$b\" \"$k\""]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.split("\n");
                root.device = (lines[0] || "").trim();
                root.kbdDevice = (lines[1] || "").trim();
            }
        }
    }

    Process {
        id: setter
        // What was asked while a run was going, started when that one is gone: an absolute percent (-1: none, the last one
        // wins) or else the sum of the steps, in percent.
        property int pendingSet: -1
        property int pendingStep: 0

        function set(pct: int): void {
            setter.command = ["brightnessctl", "-q", "-d", root.device, "set", pct + "%"];
            setter.running = true;
        }

        function step(pct: int): void {
            setter.command = ["brightnessctl", "-q", "-d", root.device, "set", Math.abs(pct) + "%" + (pct > 0 ? "+" : "-")];
            setter.running = true;
        }

        function next(): void {
            if (setter.pendingSet >= 0) {
                const pct = setter.pendingSet;
                setter.pendingSet = -1;
                setter.pendingStep = 0;
                setter.set(pct);
            } else if (setter.pendingStep !== 0) {
                const pct = setter.pendingStep;
                setter.pendingStep = 0;
                setter.step(pct);
            }
        }

        onRunningChanged: {
            if (!running) {
                root.refresh();
                root.commandFinished();
                setter.next();
            }
        }
    }

    FileView {
        id: maximum
        path: root.device !== "" ? "/sys/class/backlight/" + root.device + "/max_brightness" : ""
        printErrors: false
        onLoaded: root.max = parseInt(maximum.text().trim(), 10) || 0
    }

    // The level is followed through events, never a timer (audit SC-08: a read every 1.5 s for the whole session). Two
    // sources: the backlight class notifies `actual_brightness` (sysfs_notify, which reaches inotify through kernfs) on every
    // change it makes, a hotkey handled by the firmware included; and any program that writes the level (brightnessctl,
    // logind's SetBrightness, a script) writes `brightness`, which raises a modify event on that file. Either one reads
    // `actual_brightness` again. The shell's own changes read it when brightnessctl ends (refresh()).
    FileView {
        id: current
        path: root.device !== "" ? "/sys/class/backlight/" + root.device + "/actual_brightness" : ""
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            root.value = parseInt(current.text().trim(), 10) || 0;
            root.loaded = true;
        }
    }

    FileView {
        id: written
        path: root.device !== "" ? "/sys/class/backlight/" + root.device + "/brightness" : ""
        preload: false
        printErrors: false
        watchChanges: true
        onFileChanged: current.reload()
    }
}
