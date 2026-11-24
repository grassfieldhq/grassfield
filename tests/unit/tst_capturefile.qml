import QtQuick
import QtTest
import "../../shell/services/CaptureFile.js" as CaptureFile

// The capture helper's private state as the shell reads it (ADR-0045 OC-1, docs/specs/system-dialogs.md "Screen recording"
// SC16): its path in a session and in a dev session, its reading (every malformed field refused), the countdown's seconds,
// the recording's elapsed time and where the countdown plate goes.
TestCase {
    name: "CaptureFile"

    function test_path() {
        compare(CaptureFile.statePath("", "/run/user/1000"), "/run/user/1000/grassfield/capture-state.json");
        compare(CaptureFile.statePath("/repo/.dev/state", "/run/user/1000"), "/repo/.dev/state/capture-state.json",
            "a dev session reads its own state, never the real session's");
        compare(CaptureFile.statePath("", ""), "");
    }

    function test_recording() {
        const s = CaptureFile.parse(JSON.stringify({v: 1, phase: "recording", kind: "recording", pid: 12, start: 3, recorder: 13,
            recorderStart: 4, started: 1793800000000, rect: {x: 0, y: 0, w: 1920, h: 1080}, output: "HDMI-A-1"}));
        compare(s.phase, "recording");
        compare(s.kind, "recording");
        compare(s.started, 1793800000000);
        compare(s.rect, {x: 0, y: 0, w: 1920, h: 1080});
        compare(s.output, "HDMI-A-1");
    }

    function test_countdown() {
        const s = CaptureFile.parse('{"v": 1, "phase": "countdown", "kind": "shot", "until": 1793800005000, "rect": {"x": 10, "y": 20, "w": 300, "h": 200}, "output": ""}');
        compare(s.phase, "countdown");
        compare(s.until, 1793800005000);
        compare(s.rect.w, 300);
    }

    function test_malformed() {
        for (const text of ["", "{", "[]", "null", "1", '{"phase": "recording", "started": 5}', '{"v": 2, "phase": "idle"}',
                 '{"v": 1, "phase": "dancing"}', '{"v": 1, "phase": "countdown"}', '{"v": 1, "phase": "recording", "started": "now"}',
                 '{"v": 1, "phase": "recording", "started": -5}'])
            compare(CaptureFile.parse(text).phase, "idle", text);
        const s = CaptureFile.parse('{"v": 1, "phase": "countdown", "until": 9, "kind": "evil", "output": "../x", "rect": {"x": 0, "y": 0, "w": 0, "h": 5}}');
        compare(s.kind, "");
        compare(s.output, "", "an output name that is not a connector's is dropped");
        compare(s.rect, null, "an empty area is dropped");
        compare(CaptureFile.parse('{"v": 1, "phase": "countdown", "until": 9, "rect": [1, 2, 3, 4]}').rect, null);
        compare(CaptureFile.parse('{"v": 1, "phase": "countdown", "until": 9, "rect": {"x": "0", "y": 0, "w": 5, "h": 5}}').rect, null);
    }

    function test_starting() {
        compare(CaptureFile.parse('{"v": 1, "phase": "starting", "kind": "recording", "pid": 12, "start": 3}').phase, "starting");
    }

    // The lock and the helper's state, in either order (security review of OC-1, MEDIUM): the shell stops the helper whenever
    // the session is locked and the state is not idle, also when the state becomes active only after the lock.
    // Hide Desktop Icons: hidden while the toolbar is open or has just started the helper, and while the helper is not idle.
    function test_desktopIconsHiddenWhileNotIdle() {
        verify(!CaptureFile.hidesIcons(false, true, "recording"), "the option off: never");
        verify(!CaptureFile.hidesIcons(undefined, true, "recording"), "only a boolean true turns it on");
        verify(!CaptureFile.hidesIcons(true, false, "idle"), "idle and no toolbar: shown");
        verify(CaptureFile.hidesIcons(true, true, "idle"), "the toolbar open: hidden");
        for (const phase of ["starting", "selecting", "countdown", "recording", "shooting", "frozen"])
            verify(CaptureFile.hidesIcons(true, false, phase), phase);
        verify(!CaptureFile.hidesIcons(true, false, "nonsense"), "an unknown phase is not a capture");
        verify(!CaptureFile.hidesIcons(true, false, CaptureFile.parse("{").phase), "an unreadable file reads idle");
    }

    function test_stopUnderTheLock() {
        verify(!CaptureFile.stopNeeded(false, "recording"), "unlocked: nothing to stop");
        verify(!CaptureFile.stopNeeded(true, "idle"), "locked and idle: nothing to stop");
        for (const phase of ["starting", "selecting", "countdown", "recording", "shooting", "frozen"])
            verify(CaptureFile.stopNeeded(true, phase), phase);
        verify(!CaptureFile.stopNeeded("yes", "recording"), "only a real lock state");
        // Replays of the two orders as CaptureState sees them: each change of either value asks stopNeeded again.
        const replay = events => {
            let locked = false;
            let phase = "idle";
            let stops = 0;
            for (const e of events) {
                if (e.locked !== undefined)
                    locked = e.locked;
                if (e.text !== undefined)
                    phase = CaptureFile.parse(e.text).phase;
                if (CaptureFile.stopNeeded(locked, phase))
                    stops++;
            }
            return stops;
        };
        const starting = '{"v": 1, "phase": "starting", "kind": "recording", "pid": 12, "start": 3}';
        const recording = '{"v": 1, "phase": "recording", "kind": "recording", "pid": 12, "start": 3, "started": 1793800000000}';
        verify(replay([{text: recording}, {locked: true}]) > 0, "the lock comes while recording");
        verify(replay([{locked: true}, {text: starting}]) > 0, "Record, then the lock, then the helper's first state: stopped");
        verify(replay([{locked: true}, {text: recording}]) > 0, "a shell restarted under the lock reads a recording late: stopped");
        compare(replay([{locked: true}, {text: '{"v": 1, "phase": "idle"}'}]), 0, "locked with nothing running: no stop");
        compare(replay([{text: recording}, {text: '{"v": 1, "phase": "idle"}'}, {locked: true}]), 0, "ended before the lock: no stop");
    }

    // ADR-0066 D-1: the helper's `shooting` (with its `seq`) and `frozen` (with its `token`) states.
    function test_shootingAndFrozen() {
        const s = CaptureFile.parse('{"v": 1, "phase": "shooting", "seq": "0123456789abcdef", "pid": 12, "start": 3}');
        compare(s.phase, "shooting");
        compare(s.seq, "0123456789abcdef");
        compare(s.token, "");
        const f = CaptureFile.parse('{"v": 1, "phase": "frozen", "token": "abababababababababababababababab", "frames": [], "pid": 12, "start": 3}');
        compare(f.phase, "frozen");
        compare(f.token, "abababababababababababababababab");
        compare(f.seq, "");
        compare(CaptureFile.parse('{"v": 1, "phase": "idle", "seq": "abc"}').seq, "", "only a shooting state carries a seq");
        compare(CaptureFile.parse('{"v": 1, "phase": "shooting", "seq": "abc", "token": "abc"}').token, "", "nor a token");
    }

    function test_shootingMalformed() {
        for (const text of ['{"phase": "shooting", "seq": "abc"}', '{"v": 2, "phase": "shooting", "seq": "abc"}',
                 '{"v": 1, "phase": "shoot", "seq": "abc"}', '{"v": 1, "phase": "Frozen"}', '{"v": 1, "phase": ["shooting"]}'])
            compare(CaptureFile.parse(text).phase, "idle", text);
        // A field that does not read is dropped, never acknowledged; the phase stays so the lock still stops it.
        for (const seq of ["", "xyz", "../x", "a b", "abc\n", 12, null, ["a"], "0".repeat(33)]) {
            const s = CaptureFile.parse(JSON.stringify({v: 1, phase: "shooting", seq: seq}));
            compare(s.phase, "shooting", JSON.stringify(seq));
            compare(s.seq, "", JSON.stringify(seq));
        }
        compare(CaptureFile.parse('{"v": 1, "phase": "frozen", "token": "../../x"}').token, "");
        compare(CaptureFile.parse('{"v": 1, "phase": "frozen", "token": 5}').phase, "frozen");
    }

    function test_stopShootingUnderTheLock() {
        verify(CaptureFile.stopNeeded(true, "shooting"), "a shooting state under the lock is stopped");
        verify(CaptureFile.stopNeeded(true, "frozen"), "a frozen state under the lock is stopped");
        verify(!CaptureFile.stopNeeded(false, "shooting"));
        verify(CaptureFile.stopNeeded(true, CaptureFile.parse('{"v": 1, "phase": "shooting", "seq": "zz"}').phase),
            "a shooting state with a bad seq is still stopped");
    }

    // Do Not Disturb while recording is a runtime silence only: the user's own setting decides alone otherwise, and is never an output.
    function test_silencedWhileRecording() {
        verify(CaptureFile.silenced(false, true, true), "recording with the option on: silenced");
        verify(!CaptureFile.silenced(false, false, true), "idle: not silenced");
        verify(!CaptureFile.silenced(false, true, false), "the option off: not silenced");
        verify(!CaptureFile.silenced(false, false, false));
        for (const recording of [true, false]) {
            for (const enabled of [true, false]) {
                verify(CaptureFile.silenced(true, recording, enabled), "the user's own Do Not Disturb always silences");
            }
        }
        verify(!CaptureFile.silenced(undefined, "yes", 1), "only booleans count");
        verify(!CaptureFile.silenced(false, undefined, undefined));
    }

    // Hide Desktop Icons and the acknowledgement: a key-started shot waits for the icons to be presented hidden, never for ever.
    function test_iconsReady() {
        verify(CaptureFile.iconsReady(false, false, 0, false), "the option off: nothing to wait for");
        verify(CaptureFile.iconsReady(undefined, true, 0, false), "only a boolean true turns it on");
        verify(!CaptureFile.iconsReady(true, true, 0, false), "hidden, no frame presented yet: wait");
        verify(!CaptureFile.iconsReady(true, true, 1, false), "the first frame may have been under way: wait");
        verify(CaptureFile.iconsReady(true, true, 2, false), "two frames since they were hidden");
        verify(CaptureFile.iconsReady(true, true, 0, true), "the bounded wait is over: go");
        verify(!CaptureFile.iconsReady(true, false, 5, false), "not hidden yet: wait whatever the frames");
        verify(CaptureFile.iconsReady(true, false, 0, true), "even then the wait ends");
        const shooting = CaptureFile.parse('{"v": 1, "phase": "shooting", "seq": "0123456789abcdef"}');
        compare(CaptureFile.ackNeeded(shooting, true, "", false), "", "the icons are not off the screen: no acknowledgement");
        compare(CaptureFile.ackNeeded(shooting, true, "", true), "0123456789abcdef");
        compare(CaptureFile.ackNeeded(shooting, true, ""), "0123456789abcdef", "without the argument: as before");
        compare(CaptureFile.ackNeeded(shooting, false, "", true), "", "a card is still mapped");
    }

    // The acknowledgement is asked for once per seq, only when the cards are hidden.
    function test_ackNeeded() {
        const shooting = CaptureFile.parse('{"v": 1, "phase": "shooting", "seq": "0123456789abcdef"}');
        compare(CaptureFile.ackNeeded(shooting, true, ""), "0123456789abcdef");
        compare(CaptureFile.ackNeeded(shooting, false, ""), "", "a card is still mapped: wait");
        compare(CaptureFile.ackNeeded(shooting, true, "0123456789abcdef"), "", "already acknowledged");
        compare(CaptureFile.ackNeeded(shooting, true, "ffff"), "0123456789abcdef", "a new seq");
        compare(CaptureFile.ackNeeded(CaptureFile.parse('{"v": 1, "phase": "shooting", "seq": "nope!"}'), true, ""), "");
        compare(CaptureFile.ackNeeded(CaptureFile.parse('{"v": 1, "phase": "frozen", "token": "ab"}'), true, ""), "");
        compare(CaptureFile.ackNeeded(CaptureFile.parse(""), true, ""), "");
        compare(CaptureFile.ackNeeded(shooting, 1, ""), "", "only a real true");
        compare(CaptureFile.ackNeeded(null, true, ""), "");
    }

    function test_secondsLeft() {
        compare(CaptureFile.secondsLeft(1000, 6000), 5);
        compare(CaptureFile.secondsLeft(1001, 6000), 5, "4.999 s left shows 5");
        compare(CaptureFile.secondsLeft(5001, 6000), 1);
        compare(CaptureFile.secondsLeft(6000, 6000), 0);
        compare(CaptureFile.secondsLeft(7000, 6000), 0);
        compare(CaptureFile.secondsLeft(NaN, 6000), 0);
    }

    function test_elapsed() {
        compare(CaptureFile.elapsed(0), "0:00");
        compare(CaptureFile.elapsed(12999), "0:12");
        compare(CaptureFile.elapsed(65000), "1:05");
        compare(CaptureFile.elapsed(3599000), "59:59");
        compare(CaptureFile.elapsed(3600000), "1:00:00");
        compare(CaptureFile.elapsed(3725000), "1:02:05");
        compare(CaptureFile.elapsed(-5000), "0:00", "a clock that went back");
        compare(CaptureFile.elapsed(undefined), "0:00");
    }

    function test_plate() {
        const screens = [{name: "DP-1", x: 0, y: 0, width: 2560, height: 1440}, {name: "HDMI-A-1", x: 2560, y: 0, width: 1920, height: 1080}];
        const onDp = {output: "", rect: {x: 100, y: 100, w: 400, h: 200}};
        compare(CaptureFile.plateScreen(onDp, screens), "DP-1");
        compare(CaptureFile.plateCentre(onDp, screens[0]), {x: 300, y: 200});
        const named = {output: "HDMI-A-1", rect: {x: 2560, y: 0, w: 1920, h: 1080}};
        compare(CaptureFile.plateScreen(named, screens), "HDMI-A-1");
        compare(CaptureFile.plateCentre(named, screens[1]), {x: 960, y: 540});
        compare(CaptureFile.plateScreen({output: "gone", rect: {x: 3000, y: 10, w: 20, h: 20}}, screens), "HDMI-A-1",
            "a display that went away: the one under the area");
        compare(CaptureFile.plateScreen({output: "", rect: null}, screens), "");
        compare(CaptureFile.plateCentre({output: "", rect: {x: 9000, y: 0, w: 10, h: 10}}, screens[0]), {x: 1280, y: 720},
            "an area off this display: its centre");
    }
}
