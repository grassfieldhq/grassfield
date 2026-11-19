import QtQuick
import QtTest
import "../../shell/platform/DisplaysFile.js" as DisplaysFile

// ADR-0031: the runtime files between the shell and Settings > Displays. Paths of a real and of a dev session, the state the
// shell publishes (only typed fields, monitors without a name left out), the trial file's first line, and what the shell does
// with it: apply a new trial, keep or take back the one it runs, take back any trial it finds when it starts or past its
// deadline, and ignore what is not its trial.
TestCase {
    name: "DisplaysFile"

    function test_paths() {
        compare(DisplaysFile.statePath(false, "/dev/state", "/run/user/1000"), "/run/user/1000/grassfield-displays.json");
        compare(DisplaysFile.trialPath(false, "/dev/state", "/run/user/1000"), "/run/user/1000/grassfield-display-trial.conf");
        compare(DisplaysFile.statePath(true, "/dev/state", "/run/user/1000"), "/dev/state/displays.json");
        compare(DisplaysFile.trialPath(true, "/dev/state", "/run/user/1000"), "/dev/state/display-trial.conf");
        // A dev session without its state directory never falls back to the real runtime directory.
        compare(DisplaysFile.trialPath(true, "", "/run/user/1000"), "");
        compare(DisplaysFile.statePath(false, "", ""), "");
    }

    function test_same() {
        const a = DisplaysFile.payload([{name: "eDP-1"}], null, null);
        verify(!DisplaysFile.same("", a), "nothing written yet: write");
        verify(!DisplaysFile.same(undefined, a));
        verify(DisplaysFile.same(a, DisplaysFile.payload([{name: "eDP-1"}], null, null)), "the same description is not written again");
        verify(!DisplaysFile.same(a, DisplaysFile.payload([{name: "eDP-1"}, {name: "DP-2"}], null, null)), "a new monitor is");
        verify(!DisplaysFile.same(a, DisplaysFile.payload([{name: "eDP-1"}], null, {id: "a1", state: "applying"})), "a trial state is");
    }

    function test_payload() {
        const ipc = {name: "eDP-1", description: "BOE 0x0BCA", make: "BOE", model: "0x0BCA", serial: "", width: 2880, height: 1800,
            physicalWidth: 300, physicalHeight: 190, refreshRate: 120.0, x: 0, y: 0, scale: 1.6, transform: 0, disabled: false, focused: true,
            availableModes: ["2880x1800@120.00Hz", "2880x1800@60.00Hz", 42]};
        const j = JSON.parse(DisplaysFile.payload([ipc, null, {width: 10}], {device: "intel_backlight", level: 1.7}, {id: "a1b2", state: "applied"}));
        compare(j.v, 1);
        compare(j.monitors.length, 1);
        compare(j.monitors[0], {name: "eDP-1", description: "BOE 0x0BCA", make: "BOE", model: "0x0BCA", serial: "", width: 2880, height: 1800,
            physicalWidth: 300, physicalHeight: 190, refreshRate: 120, x: 0, y: 0, scale: 1.6, transform: 0, disabled: false,
            availableModes: ["2880x1800@120.00Hz", "2880x1800@60.00Hz"]});
        compare(j.backlight, {device: "intel_backlight", level: 1});
        compare(j.trial, {id: "a1b2", state: "applied"});
        const none = JSON.parse(DisplaysFile.payload(undefined, {device: ""}, {id: "a b", state: "applied"}));
        compare(none.monitors, []);
        compare(none.backlight, null);
        compare(none.trial, null);
    }

    function test_parseTrial() {
        compare(DisplaysFile.parseTrial("trial a1b2 until 1793022747\nv1\t..."), {state: "trial", id: "a1b2", until: 1793022747});
        compare(DisplaysFile.parseTrial("kept a1b2\n"), {state: "kept", id: "a1b2"});
        compare(DisplaysFile.parseTrial("revert a1b2"), {state: "revert", id: "a1b2"});
        for (const bad of ["", "trial a1b2", "trial a-b until 1", "trial a1b2 until soon", "keep a1b2", " kept a1b2", "kept", "trial " + "x".repeat(33) + " until 1"])
            compare(DisplaysFile.parseTrial(bad), null, bad);
    }

    function test_action() {
        const now = 1000;
        const trial = (id, until) => ({state: "trial", id: id, until: until});
        // A new trial is applied; the one already running is left alone; at start or past its deadline it is taken back.
        compare(DisplaysFile.action(trial("a", 1015), "", false, now), "apply");
        compare(DisplaysFile.action(trial("b", 1015), "a", false, now), "apply");
        compare(DisplaysFile.action(trial("a", 1015), "a", false, now), "");
        compare(DisplaysFile.action(trial("a", 1015), "", true, now), "revert");
        compare(DisplaysFile.action(trial("a", 1000), "", false, now), "revert");
        // Keep and Revert count only for the trial the shell runs.
        compare(DisplaysFile.action({state: "kept", id: "a"}, "a", false, now), "keep");
        compare(DisplaysFile.action({state: "revert", id: "a"}, "a", false, now), "revert");
        compare(DisplaysFile.action({state: "kept", id: "a"}, "b", false, now), "");
        compare(DisplaysFile.action({state: "revert", id: "a"}, "", false, now), "");
        // An empty or unreadable file: nothing, unless a trial runs (its rules are gone from the file: read the config again).
        compare(DisplaysFile.action(null, "", false, now), "");
        compare(DisplaysFile.action(null, "", true, now), "");
        compare(DisplaysFile.action(null, "a", false, now), "revert");
        // A deadline further ahead than the longest trial Settings writes (60 s) is taken back, as displays.lua refuses it.
        compare(DisplaysFile.MAX_TRIAL_SECONDS, 60);
        compare(DisplaysFile.action(trial("a", now + 60), "", false, now), "apply");
        compare(DisplaysFile.action(trial("a", now + 61), "", false, now), "revert");
        compare(DisplaysFile.action(trial("a", 999999999999), "a", false, now), "revert");
    }

    function test_countdown() {
        // The deadline Timer's interval: the time left, never below 0, never above 60 s (a far deadline cannot overflow its int).
        compare(DisplaysFile.countdownMs(1015, 1000000), 15000);
        compare(DisplaysFile.countdownMs(1000, 1000500), 0);
        compare(DisplaysFile.countdownMs(999999999999, 1000000), 60000);
        verify(DisplaysFile.countdownMs(999999999999, 1000000) <= 2147483647);
    }

    function test_answered() {
        // Hyprland answered "ok" to the reload that applies the trial being run: it is applied.
        const applying = {id: "a", state: "applying"};
        compare(DisplaysFile.answered(applying, "a", 2, 2, true), {id: "a", state: "applied"});
        // The answer to another reload (one asked for earlier: the previous trial taken back, the input files), a refusal, or
        // an answer that comes after the trial ended changes nothing.
        verify(DisplaysFile.answered(applying, "a", 2, 1, true) === applying);
        verify(DisplaysFile.answered(applying, "a", 2, 2, false) === applying);
        verify(DisplaysFile.answered(applying, "a", 0, 0, true) === applying);
        verify(DisplaysFile.answered(applying, "", 2, 2, true) === applying);
        verify(DisplaysFile.answered(applying, "b", 2, 2, true) === applying);
        for (const t of [null, {id: "a", state: "applied"}, {id: "a", state: "kept"}, {id: "a", state: "reverted"}])
            verify(DisplaysFile.answered(t, "a", 2, 2, true) === t, JSON.stringify(t));
    }

    // A display that came back without a mode: Hyprland lists it enabled at 0x0 (a monitor asleep or switched off when it was
    // probed answers a partial EDID with no video modes, and powering it on fires no hot-plug). Omarchy's session recovers it
    // (omarchy-hyprland-monitor-watch: omarchy-hyprland-monitor-modeless, then a reload); Grassfield's did not, so the display
    // stayed black until it was unplugged and plugged back (the owner's rc6 report after sleep).
    function test_modeless() {
        compare(DisplaysFile.modeless([]), []);
        compare(DisplaysFile.modeless(null), []);
        compare(DisplaysFile.modeless([{name: "eDP-1", width: 1920, height: 1080, disabled: false}]), []);
        compare(DisplaysFile.modeless([{name: "DP-1", width: 0, height: 0, disabled: false}, {name: "DP-2", width: 2560, height: 1440}]), ["DP-1"]);
        compare(DisplaysFile.modeless([{name: "DP-1", width: 2560, height: 0}]), ["DP-1"]);
        // A display the user switched off (disabled) is not one; nor an answer without a name or without sizes (in flight).
        compare(DisplaysFile.modeless([{name: "eDP-1", width: 0, height: 0, disabled: true}]), []);
        compare(DisplaysFile.modeless([{width: 0, height: 0}, {name: "DP-3"}, {name: "DP-4", width: "0", height: "0"}, null]), []);
    }

    // A display arriving or leaving goes to the journal by its connector only (the event's description holds the serial).
    function test_eventOutput() {
        compare(DisplaysFile.eventOutput("1,DP-1,Dell Inc. DELL U2723QE ABC123"), "DP-1");
        compare(DisplaysFile.eventOutput("0,HDMI-A-1,"), "HDMI-A-1");
        compare(DisplaysFile.eventOutput("DP-1"), "(unnamed)");
        compare(DisplaysFile.eventOutput(""), "(unnamed)");
        compare(DisplaysFile.eventOutput(undefined), "(unnamed)");
        compare(DisplaysFile.eventOutput("2,bad name\n,x"), "(unnamed)");
    }

    // Asked again with a growing wait, as Omarchy's watcher does: 3 s, doubled after each reload, at most a minute (a display
    // switched off at its own button can stay without a mode all night).
    function test_recoveryDelay() {
        compare(DisplaysFile.recoveryDelayMs(0), 3000);
        compare(DisplaysFile.recoveryDelayMs(1), 6000);
        compare(DisplaysFile.recoveryDelayMs(2), 12000);
        compare(DisplaysFile.recoveryDelayMs(4), 48000);
        compare(DisplaysFile.recoveryDelayMs(5), 60000);
        compare(DisplaysFile.recoveryDelayMs(7), 60000);
        // Audit SC-05: after the back-off no reload on a timer while someone may look; one every 10 minutes while quiet.
        compare(DisplaysFile.recoveryDelayMs(8), 0);
        compare(DisplaysFile.recoveryDelayMs(500), 0);
        compare(DisplaysFile.recoveryDelayMs(500, false), 0);
        compare(DisplaysFile.recoveryDelayMs(8, true), 600000);
        compare(DisplaysFile.recoveryDelayMs(3, true), 24000);
        // A nudge asks for one reload past the back-off only.
        compare(DisplaysFile.nudgeDelayMs(0), -1);
        compare(DisplaysFile.nudgeDelayMs(7), -1);
        compare(DisplaysFile.nudgeDelayMs(8), 3000);
        compare(DisplaysFile.nudgeDelayMs(NaN), -1);
        // Over a night with a display switched off at its button and the session in use: eight reloads, then none.
        let total = 0, n = 0;
        while (n < 1000) {
            const wait = DisplaysFile.recoveryDelayMs(n, false);
            if (wait <= 0)
                break;
            total += wait;
            n++;
        }
        compare(n, 8);
        verify(total < 300000, "the back-off ends within five minutes (" + total + " ms)");
        compare(DisplaysFile.recoveryDelayMs(-1), 3000);
        compare(DisplaysFile.recoveryDelayMs(NaN), 3000);
    }
}
