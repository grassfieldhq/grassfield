import QtQuick
import QtTest
import "../../shell/lib/LockState.js" as LockState
import "../../shell/services/LockClient.js" as Client
import "../../shell/security/LockMachine.js" as Machine
import "../../shell/security/idle/IdleModel.js" as IdleModel

// ADR-0041 step 1, S2: the lock state across processes (shell/lib/LockState.js, written by the security process's
// LockPublisher, read by the UI's LockClient), the UI's calls into the security process (shell/services/LockClient.js) and
// the screen saver inhibitors' lease (IdleModel.inhibitLeaseMs). Every UI refusal reads LockState.uiLocked: it must read
// locked with no state, a stale beat, a missed push while the compositor reports a lock, and a stopped security process
// (no beat: stale). tests/security/lockstate_mutants.sh plants mutants in LockState.js and expects this file to fail on each.
TestCase {
    name: "LockState"

    function line(state, seq, writer, displaysOff, motion) {
        return LockState.format(state, seq, writer, displaysOff, motion);
    }

    // ---- the refusals (every UI surface reads this) ----
    function test_uiLockedTruthTable() {
        // Known, fresh, "unlocked", no compositor lock: the only unlocked reading.
        verify(!LockState.uiLocked(true, false, "unlocked", false));
        // No state yet (the UI started before the security process published; a file that cannot be read).
        verify(LockState.uiLocked(false, false, "unlocked", false), "no state");
        verify(LockState.uiLocked(false, true, "", false), "no state, stale");
        // A stale beat: the security process is stopped, restarting, at its start limit or hung.
        verify(LockState.uiLocked(true, true, "unlocked", false), "stale");
        // A lost push: the file still says unlocked, the compositor reports a lock.
        verify(LockState.uiLocked(true, false, "unlocked", true), "compositor lock with a missed push");
        // Being acquired or held.
        verify(LockState.uiLocked(true, false, "locking", false), "locking");
        verify(LockState.uiLocked(true, false, "locked", false), "locked");
        // Only exact booleans count as fresh and known: anything odd reads locked.
        verify(LockState.uiLocked(1, false, "unlocked", false), "known must be exactly true");
        verify(LockState.uiLocked(true, 0, "unlocked", false), "stale must be exactly false");
        verify(LockState.uiLocked(true, undefined, "unlocked", false), "stale undefined");
        verify(LockState.uiLocked(true, false, "UNLOCKED", false), "an unknown state");
        verify(LockState.uiLocked(true, false, "", false), "an empty state");
        verify(LockState.uiLocked(true, false, undefined, false), "no state field");
        // The compositor's signal only ever adds a lock.
        verify(!LockState.uiLocked(true, false, "unlocked", "true"), "only an exact true counts as the compositor's lock");
        verify(LockState.uiLocked(true, false, "locked", false));
    }

    // ADR-0041 S2 (the opus review of 77a0ceb3, MAJOR-1): the lock is confirmed only by the compositor's signal or a last
    // published state of "locking" or "locked" (fresh or stale); with no state, an unreadable one, or a stale "unlocked" (the
    // security process stopped while the session was unlocked), the paths that only lock stay open so a lock request goes out.
    function test_uiLockConfirmed() {
        verify(LockState.uiLockConfirmed(true, "locked", false));
        verify(LockState.uiLockConfirmed(true, "locking", false));
        verify(!LockState.uiLockConfirmed(true, "unlocked", false), "a stale or fresh unlocked: not confirmed");
        verify(!LockState.uiLockConfirmed(false, "", false), "no state: not confirmed");
        verify(!LockState.uiLockConfirmed(false, "locked", false), "an unreadable file: not confirmed");
        verify(LockState.uiLockConfirmed(false, "", true), "the compositor's signal confirms it");
        verify(LockState.uiLockConfirmed(true, "unlocked", true));
        verify(!LockState.uiLockConfirmed(1, "locked", false), "known must be exactly true");
        verify(!LockState.uiLockConfirmed(true, "LOCKED", false), "an unknown state");
        verify(!LockState.uiLockConfirmed(false, "", "true"), "only an exact true is the compositor's signal");
        // Whenever the lock is confirmed the UI also reads locked (a confirmed lock never opens anything).
        for (const known of [true, false])
            for (const stale of [true, false])
                for (const state of ["unlocked", "locking", "locked", ""])
                    for (const comp of [true, false])
                        if (LockState.uiLockConfirmed(known, state, comp))
                            verify(LockState.uiLocked(known, stale, state, comp), [known, stale, state, comp].join(","));
    }

    function test_uiLockStarting() {
        verify(LockState.uiLockStarting(true, false, "locking"));
        verify(!LockState.uiLockStarting(true, false, "locked"));
        verify(!LockState.uiLockStarting(true, false, "unlocked"));
        verify(!LockState.uiLockStarting(true, true, "locking"), "stale");
        verify(!LockState.uiLockStarting(false, false, "locking"), "unknown");
    }

    // ---- what the security process publishes ----
    function test_publicState() {
        compare(LockState.publicState(false, false), "unlocked");
        compare(LockState.publicState(false, true), "unlocked");
        compare(LockState.publicState(true, false), "locking");
        compare(LockState.publicState(true, true), "locked");
        // Only an exact true locks the published state; a lock reads "locked" only when held.
        compare(LockState.publicState(1, true), "unlocked");
        compare(LockState.publicState(true, 1), "locking");
        compare(LockState.ipcState("unlocked"), "unlocked");
        compare(LockState.ipcState("locking"), "locked");
        compare(LockState.ipcState("locked"), "locked");
        compare(LockState.ipcState("anything"), "locked");
    }

    // Every state of the lock's machine maps to the published state the UI needs: anything but UNLOCKED reads locked there.
    function test_machineStatesAllLockTheUi() {
        for (const st of [Machine.LOCKING, Machine.LOCKED, Machine.AUTHENTICATING, Machine.RELEASING]) {
            const pub = LockState.publicState(Machine.isLocked(st), Machine.isHolding(st));
            verify(pub !== "unlocked", st);
            verify(LockState.uiLocked(true, false, pub, false), st);
        }
        compare(LockState.publicState(Machine.isLocked(Machine.UNLOCKED), Machine.isHolding(Machine.UNLOCKED)), "unlocked");
    }

    // ---- the file ----
    function test_fileName() {
        compare(LockState.fileName("abc_123", "wayland-1"), "grassfield-lock-state-abc_123");
        compare(LockState.fileName("", "wayland-1"), "grassfield-lock-state-wayland-1");
        compare(LockState.fileName("", ""), "grassfield-lock-state-default");
        compare(LockState.fileName("a/b c", ""), "grassfield-lock-state-a_b_c");
        // The same instance id as the crash-recovery marker (one per compositor instance).
        for (const pair of [["sig_1_2", "w"], ["", "wayland-9"], ["", ""], ["../x y", ""]])
            compare(LockState.fileName(pair[0], pair[1]).replace("grassfield-lock-state-", ""), Machine.markerName(pair[0], pair[1]).replace("grassfield-lock-", ""));
        compare(LockState.filePath("/run/user/1000", "s", ""), "/run/user/1000/grassfield-lock-state-s");
        compare(LockState.filePath("", "s", ""), "", "no runtime directory: no state (the UI reads locked)");
        compare(LockState.filePath("relative/dir", "s", ""), "", "a relative runtime directory is refused");
        compare(LockState.filePath(undefined, "s", ""), "");
    }

    function test_roundTrip() {
        const t = line("locked", 42, 1234, true, {"eDP-1": 1500, "DP-2": 0});
        verify(t.indexOf("\n") < 0, "one line");
        const r = LockState.parse(t);
        verify(r.ok);
        compare(r.state, "locked");
        compare(r.seq, 42);
        compare(r.writer, 1234);
        compare(r.displaysOff, true);
        compare(r.motion["eDP-1"], 1500);
        compare(r.motion["DP-2"], 0);
        verify(LockState.parse(t + "\n").ok, "a trailing newline is whitespace to JSON");
        verify(LockState.parse(line("unlocked", 0, 0, false, {})).ok, "sequence and writer 0 are whole numbers");
    }

    function test_parseRefusesAnythingElse() {
        const bad = ["", " ", "null", "[]", "42", "\"locked\"", "{}", "{\"v\":1}",
            "{\"v\":2,\"state\":\"unlocked\",\"seq\":1,\"writer\":1,\"displaysOff\":false}",
            "{\"v\":1,\"state\":\"open\",\"seq\":1,\"writer\":1,\"displaysOff\":false}",
            "{\"v\":1,\"state\":\"unlocked\",\"seq\":-1,\"writer\":1,\"displaysOff\":false}",
            "{\"v\":1,\"state\":\"unlocked\",\"seq\":1.5,\"writer\":1,\"displaysOff\":false}",
            "{\"v\":1,\"state\":\"unlocked\",\"seq\":\"1\",\"writer\":1,\"displaysOff\":false}",
            "{\"v\":1,\"state\":\"unlocked\",\"seq\":1,\"writer\":\"1\",\"displaysOff\":false}",
            "{\"v\":1,\"state\":\"unlocked\",\"seq\":1,\"writer\":1,\"displaysOff\":\"false\"}",
            "{\"v\":1,\"state\":\"unlocked\",\"seq\":1,\"writer\":1}",
            "{\"v\":\"1\",\"state\":\"unlocked\",\"seq\":1,\"writer\":1,\"displaysOff\":false}",
            "{\"v\":1,\"state\":\"unlocked\",\"seq\":1e300,\"writer\":1,\"displaysOff\":false}",
            "not json", "{\"v\":1,"];
        for (const t of bad)
            verify(!LockState.parse(t).ok, t);
        verify(!LockState.parse(undefined).ok);
        verify(!LockState.parse(null).ok);
        // Too long: never a state, whatever it holds.
        const long = line("unlocked", 1, 1, false, {}) + " ".repeat(LockState.MAX_BYTES);
        verify(!LockState.parse(long).ok, "longer than MAX_BYTES");
    }

    function test_motionCleaned() {
        const m = {"eDP-1": 10, "bad name": 5, "DP-1": -1, "HDMI-A-1": NaN, "x": "12", "": 3};
        const r = LockState.parse(line("unlocked", 1, 1, false, m));
        verify(r.ok, "an invalid motion entry never refuses the state");
        compare(JSON.stringify(r.motion), JSON.stringify({"eDP-1": 10}));
        const many = {};
        for (let i = 0; i < 40; i++)
            many["O-" + (i < 10 ? "0" + i : i)] = i;
        compare(Object.keys(LockState.cleanMotion(many)).length, LockState.MAX_OUTPUTS);
        compare(JSON.stringify(LockState.cleanMotion([1, 2])), "{}");
        compare(JSON.stringify(LockState.cleanMotion(null)), "{}");
        // A motion that is not an object in the file: the state still parses, with no motion.
        const t = "{\"v\":1,\"state\":\"locked\",\"seq\":3,\"writer\":7,\"displaysOff\":false,\"motion\":\"x\"}";
        verify(LockState.parse(t).ok);
        compare(JSON.stringify(LockState.parse(t).motion), "{}");
    }

    // ---- the heartbeat ----
    function test_newBeat() {
        const a = LockState.parse(line("unlocked", 5, 100, false, {}));
        const sameAgain = LockState.parse(line("unlocked", 5, 100, false, {}));
        const next = LockState.parse(line("unlocked", 6, 100, false, {}));
        const restarted = LockState.parse(line("unlocked", 5, 200, false, {}));
        verify(!LockState.isNewBeat(null, a), "the first read is no beat: only a second write proves a live writer");
        verify(!LockState.isNewBeat({ok: false}, a), "nor a read after an unreadable one");
        verify(!LockState.isNewBeat(a, sameAgain), "the same sequence of the same writer is no beat (a hung process)");
        verify(LockState.isNewBeat(a, next), "the next sequence");
        verify(LockState.isNewBeat(a, restarted), "a restarted writer with the same sequence is a beat");
        verify(!LockState.isNewBeat(a, {ok: false}), "an unreadable state is never a beat");
        verify(!LockState.isNewBeat(a, null));
    }

    function test_stale() {
        verify(!LockState.isStale(0));
        verify(!LockState.isStale(LockState.STALE_MS - 1));
        verify(LockState.isStale(LockState.STALE_MS));
        verify(LockState.isStale(-1));
        verify(LockState.isStale(NaN));
        verify(LockState.isStale(undefined));
        // The heartbeat comes well within the stale bound (two beats may be missed before the UI reads locked).
        verify(LockState.HEARTBEAT_MS * 2 < LockState.STALE_MS);
    }

    // ---- the UI's calls into the security process ----
    function test_securityRoot() {
        compare(Client.securityRoot("/usr/share/grassfield/shell"), "/usr/share/grassfield/shell/security.qml");
        compare(Client.securityRoot("/usr/share/grassfield/shell/"), "/usr/share/grassfield/shell/security.qml");
        compare(Client.securityRoot(""), "");
        compare(Client.securityRoot(undefined), "");
    }

    function test_commands() {
        // Bounded: a hung security process answers nothing within 5 s (the request is tried again, then handed to the stand-in).
        compare(Client.command("lock", "/r/security.qml", []).join(" "), "env -u QS_CONFIG_PATH -u QS_CONFIG_NAME -u QS_MANIFEST timeout -k 1 5 qs ipc -p /r/security.qml call lock lock");
        compare(Client.command("inhibit", "/r/security.qml", [150]).join(" "), "env -u QS_CONFIG_PATH -u QS_CONFIG_NAME -u QS_MANIFEST timeout -k 1 5 qs ipc -p /r/security.qml call idle inhibit 150");
        compare(Client.command("lock", "", []), null, "no root, no call");
        compare(Client.command("unlock", "/r/security.qml", []), null, "no other call exists");
        compare(JSON.stringify(Client.IPC), JSON.stringify({lock: ["lock", "lock"], inhibit: ["idle", "inhibit"]}), "the only calls: lock and the lease");
    }

    function test_lockAnswered() {
        verify(Client.lockAnswered("ok\n"));
        verify(Client.lockAnswered("already-locked"));
        verify(Client.lockAnswered("refused: missing-pam"));
        verify(!Client.lockAnswered(""));
        verify(!Client.lockAnswered("Not ready to accept queries yet."));
        verify(!Client.lockAnswered("docked"), "docked answers the lid only");
        verify(!Client.lockAnswered(undefined));
    }

    // ---- the screen saver inhibitors' lease ----
    function test_inhibitLease() {
        compare(Client.inhibitSeconds(true), Client.INHIBIT_SECONDS);
        compare(Client.inhibitSeconds(false), 0);
        compare(Client.inhibitSeconds("true"), 0, "only an exact true asks for a lease");
        compare(IdleModel.inhibitLeaseMs(0), 0);
        compare(IdleModel.inhibitLeaseMs(-5), 0);
        compare(IdleModel.inhibitLeaseMs(1.5), 0);
        compare(IdleModel.inhibitLeaseMs("150"), 0);
        compare(IdleModel.inhibitLeaseMs(NaN), 0);
        compare(IdleModel.inhibitLeaseMs(30), 30000);
        compare(IdleModel.inhibitLeaseMs(150), 150000);
        compare(IdleModel.inhibitLeaseMs(100000), IdleModel.INHIBIT_MAX_SECONDS * 1000, "bounded: a crashed UI keeps the idle lock off one lease at most");
        // The UI renews well before the lease ends, and asks for no more than the security side grants.
        verify(Client.INHIBIT_RENEW_MS < Client.INHIBIT_SECONDS * 1000);
        verify(Client.INHIBIT_SECONDS <= IdleModel.INHIBIT_MAX_SECONDS);
        compare(Client.INHIBIT_RENEW_MS, IdleModel.INHIBIT_RENEW_MS);
    }
}
