pragma ComponentBehavior: Bound
// Portions adapted from Omarchy shell/plugins/services/idle/Service.qml (omacom/omarchy, branch
// quattro): IdleMonitor with respectInhibitors. Copyright (c) David Heinemeier Hansson, MIT License (upstream
// LICENSE, basecamp/omarchy v4.0.4; notice shipped as packaging/licenses/omarchy-MIT.txt).
import QtQuick
import Quickshell
import Quickshell.Hyprland // layering-exception: ADR-0021 security
import Quickshell.Io
import Quickshell.Services.UPower
import Quickshell.Wayland
import Grassfield.Ui
import qs.services
import qs.security.lock
import "IdleModel.js" as IdleModel
import "../../lib/RunMode.js" as RunMode

// Idle handling (SEC7, ADR-0010): after T-10 s without input the screens dim, at T the session
// locks (T = lock.idleMinutes, default 5, 0 = never). Any input undims and cancels. Wayland idle
// inhibitors (video players, presentations) are respected by the compositor's idle-notify
// protocol. Display power-off on the lock screen (D-4, macOS): IdleModel.DISPLAY_OFF_SECONDS without input while
// locked switch the displays off (Hyprland DPMS); input or the unlock switch them on (the compositor also wakes them on
// a key press or pointer motion: misc.key_press_enables_dpms / mouse_move_enables_dpms, looknfeel.lua, so a shell that
// died meanwhile cannot leave the screen dark). While unlocked, lock.displayOffBattery / lock.displayOffPower minutes without
// input (the power source in use; 0 = never) also switch them off, without locking (macOS 27 Lock Screen: Turn display off when
// inactive); a lock that follows keeps them off until input. Also hosts the lock-before-sleep inhibitor, and the automatic
// sleep (macOS 27 Energy, Battery > Options…): IdleModel.AUTO_SLEEP_SECONDS after this module turned the displays off for
// lack of input, the computer sleeps, unless energy.preventSleep is on (default; battery and power adapter alike); only in
// the LOCKED state with the lock secure (an unlocked session is locked first: the one lock it can add), never in the nested
// dev session.
//
// Process (ADR-0041 step 1, S2): instantiated in the security process only (../host/SecurityHost.qml), with the lock and the sleep
// inhibitor, so that the idle lock and the lock before sleep keep working whatever the UI does. What the UI knows of it
// (the displays switched off, for the screen saver) goes out with the lock state (Lock.displaysOff, LockPublisher); the
// polkit and secret sheets beside it (S3) read `displayOff` and `saverShown` in process (SheetSession, bound by the host);
// what it needs from the UI (the applications' org.freedesktop.ScreenSaver inhibitors, which the menu bridge serves to the
// UI) comes in as a lease (`idle inhibit <seconds>`, below), which ends by itself when the UI stops renewing it: a UI that
// crashed while a video played cannot keep the idle lock off.
Scope {
    id: root

    readonly property var timing: IdleModel.timings(Settings.lockIdleMinutes)
    property bool dimmed: false
    // Dev session only (RunMode.dev through the relative import, which no QML import path can replace): the dev hooks
    // answer. Never in a real session (GRASSFIELD_SESSION=1), SEC-03.
    readonly property bool devHooks: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))
    // Seconds without input on the lock screen before the displays go off; 0 = never. Off in the nested dev session
    // unless a test sets it (`idle devDisplayOff <seconds>`): a dark nested output would spoil the lock tests' captures.
    property int displayOffSeconds: devHooks ? 0 : IdleModel.DISPLAY_OFF_SECONDS
    // This module switched the displays off (and must switch them on again).
    property bool displayOff: false
    // The lock's moving clouds hold while the displays are off (ADR-0040 step 9; display only, like Lock.fromDim).
    onDisplayOffChanged: Lock.displaysOff = root.displayOff
    // Seconds without input before the displays go off while unlocked, for the power source in use; 0 = never. Always off in
    // the nested dev session (a dark nested output would spoil every capture; no test needs it there).
    readonly property int inactiveOffSeconds: devHooks ? 0 : IdleModel.inactiveDisplayOffSeconds(Settings.lockDisplayOffBattery, Settings.lockDisplayOffPower, UPower.onBattery)
    // The unlocked monitor turned the displays off and no input came since.
    property bool offForInactivity: false
    property bool rearmingInactive: false

    // The compositor also switches the displays on at a key press or pointer motion, so "off" is sent whenever the state is
    // recomputed, never skipped as already done (a stale "off" would keep the next "off" from being sent); "on" only when this
    // module had them off (a repeated enable can flicker on some hardware), and always while a lock is being acquired: an
    // instance restarted with the displays dark starts with displayOff false, and the compositor confirms a lock only once it
    // has drawn it.
    function setDisplays(on: bool): void {
        if (on && !displayOff && !(Lock.locked && !Lock.holding))
            return;
        if (on === displayOff)
            console.info("grassfield-idle: displays " + (on ? "on" : (Lock.locked ? "off (locked, no input)" : "off (inactive)")));
        displayOff = !on;
        const action = on ? "enable" : "disable";
        Hyprland.dispatch(Hyprland.usingLua ? "hl.dsp.dpms({ action = \"" + action + "\" })" : "dpms " + (on ? "on" : "off"));
    }

    function updateDisplays(): void {
        setDisplays(!IdleModel.displaysOff(lockedMonitor.enabled && lockedMonitor.isIdle, root.offForInactivity && inactiveMonitor.enabled && inactiveMonitor.isIdle, Lock.locked, Lock.holding));
    }

    // A lock that starts lights the displays until it holds (IdleModel.displaysOff); an unlock without Wayland input (a
    // fingerprint) lights a session that went dark for inactivity. Later in the turn (Qt.callLater runs one call for all the
    // requests of a turn): once locked and holding have both settled, and after the lock request has been queued.
    Connections {
        target: Lock

        function onLockedChanged(): void {
            if (!Lock.locked) {
                root.offForInactivity = false;
                root.endDimUntilLock();
            }
            root.acquireOnTries = 0;
            Qt.callLater(root.updateDisplays);
        }

        function onHoldingChanged(): void {
            root.acquireOnTries = 0;
            // The lock holds: the dim that led to it goes (under the lock surfaces, unseen).
            if (Lock.holding) {
                root.endDimUntilLock();
                root.dimmed = false;
            }
            Qt.callLater(root.updateDisplays);
        }
    }

    // A lock restored at start (a restarted shell) may not change Lock.locked: light the displays it has to draw on.
    Component.onCompleted: updateDisplays()

    // While a lock is being acquired, "on" again until it holds (a lost request would leave it undrawn until input), a few
    // times only.
    property int acquireOnTries: 0
    Timer {
        interval: IdleModel.ACQUIRE_DISPLAYS_ON_MS
        repeat: true
        running: Lock.locked && !Lock.holding && root.acquireOnTries < IdleModel.ACQUIRE_DISPLAYS_ON_TRIES
        onTriggered: {
            root.acquireOnTries++;
            root.updateDisplays();
        }
    }

    // ---- ADR-0040 step 5 (ID-8): the dim stays until the lock it led to holds; the lock's content starts at the dim's level
    // (Lock.fromDim). The lock request is not delayed; when it fails, the dim lifts at once (as before). Display only. ----
    property bool dimUntilLock: false
    function endDimUntilLock(): void {
        if (!root.dimUntilLock)
            return;
        root.dimUntilLock = false;
        dimUntilLockBound.stop();
        Lock.fromDim = false;
        root.update();
    }
    Timer {
        id: dimUntilLockBound
        interval: IdleModel.DIM_UNTIL_LOCK_MAX_MS
        onTriggered: root.endDimUntilLock()
    }

    // ---- ADR-0040 step 5 (IQ-T4 A): a display that turns off for inactivity locks the session, at once (the displays stay
    // on until the lock holds, IdleModel.displaysOff, so the lock is drawn just before they go off) or after
    // lock.requirePasswordAfterDisplayOff without input, or never; lock.idleMinutes stays the ceiling. ----
    readonly property int requireAfterMs: IdleModel.requireAfterDisplayOffMs(Settings.lockRequirePasswordAfterDisplayOff)
    function displayOffLock(): void {
        const result = Lock.lock("display-off");
        if (result !== "ok" && result !== "already-locked")
            console.warn("grassfield-idle: display-off lock not engaged:", result);
    }
    Timer {
        id: displayOffLockTimer
        interval: Math.max(1, root.requireAfterMs)
        onTriggered: {
            if (root.offForInactivity && !Lock.locked)
                root.displayOffLock();
        }
    }

    function update(): void {
        // A lock that the dim led to is being acquired: the dim stays until it holds (ID-8).
        if (root.dimUntilLock)
            return;
        if (monitor.enabled && monitor.isIdle) {
            if (!dimmed)
                console.info("grassfield-idle: idle, dimming; lock in " + root.timing.lockDelayMs / 1000 + " s");
            dimmed = true;
            lockTimer.restart();
        } else {
            // Only real input counts as activity; a disabled monitor (locked, rearming) is not.
            if (dimmed && monitor.enabled)
                console.info("grassfield-idle: activity, idle lock cancelled");
            dimmed = false;
            lockTimer.stop();
        }
    }

    // Quickshell 0.3.1 IdleMonitor keeps the timeout it was enabled with (verified in nested:
    // a runtime change is ignored), and grassfield.json loads after startup. Re-enable it on
    // every timeout change so the new value applies.
    property bool rearming: false

    // Applications hold org.freedesktop.ScreenSaver idle inhibitors (GF-016: the menu bridge serves them to the UI, which
    // renews a lease here while one is held: `idle inhibit <seconds>`, IdleModel.inhibitLeaseMs). While true the screen
    // neither dims nor locks on idle, as on macOS while a video plays; a manual lock, the lid and the lock before sleep are
    // unaffected. The lease ends by itself (the UI renews it every IdleModel.INHIBIT_RENEW_MS while the inhibitor lasts), so
    // a UI that stopped or crashed cannot keep the idle lock off for longer than one lease.
    readonly property bool busInhibited: inhibitLease.running
    onBusInhibitedChanged: console.info("grassfield-idle: " + (busInhibited ? "idle inhibited by an application (org.freedesktop.ScreenSaver, through the shell)" : "no application inhibits idle (org.freedesktop.ScreenSaver)"))

    // Sets or ends the lease: `seconds` 0 ends it, anything else is bounded by IdleModel.inhibitLeaseMs.
    function inhibitFor(seconds: int): string {
        const ms = IdleModel.inhibitLeaseMs(seconds);
        if (ms === 0) {
            inhibitLease.stop();
            return "ok";
        }
        inhibitLease.interval = ms;
        inhibitLease.restart();
        return "ok";
    }

    Timer {
        id: inhibitLease
        onTriggered: console.info("grassfield-idle: the screen saver inhibitor lease ended without renewal")
    }

    // ---- The UI's screen saver, as this process counts it (ADR-0041 step 1, S3). The UI draws the saver (shell/saver,
    // ADR-0032) after screensaver.idleMinutes without input; the polkit sheet and the secret sheets, which run here, hold a
    // request while it may show (SheetSession.saverShown, bound by the host). This monitor counts the same idle time by the
    // same rule (IdleModel.saverArmed, SaverModel.armed's; the same Wayland inhibitors, and the applications' through the
    // lease above), so nothing the UI says is read. It differs from the saver only on the holding side: while the UI is down,
    // or for the moment between an input that dismisses the saver and the compositor's activity report. Off in a dev session,
    // as the saver's own delay (no test of the sheets needs it there; `saver devShow` is the UI's alone). It never locks,
    // unlocks or dims. ----
    readonly property int saverSeconds: devHooks ? 0 : IdleModel.saverSeconds(Settings.screenSaverIdleMinutes)
    property bool rearmingSaver: false
    readonly property bool saverShown: saverMonitor.enabled && saverMonitor.isIdle

    IdleMonitor {
        id: saverMonitor
        // Armed only once its timeout is the one wanted (Quickshell keeps the timeout it was enabled with, see `rearming`).
        enabled: timeout === Math.max(1, root.saverSeconds) && IdleModel.saverArmed(root.saverSeconds, Lock.locked, root.busInhibited, root.rearmingSaver)
        timeout: Math.max(1, root.saverSeconds)
        respectInhibitors: true
        onTimeoutChanged: {
            root.rearmingSaver = true;
            Qt.callLater(() => root.rearmingSaver = false);
        }
    }

    IdleMonitor {
        id: monitor
        enabled: IdleModel.idleArmed(root.timing.enabled, Lock.locked, root.rearming, root.busInhibited)
        timeout: root.timing.dimSeconds
        respectInhibitors: true
        onIsIdleChanged: root.update()
        onEnabledChanged: root.update()
        onTimeoutChanged: {
            root.rearming = true;
            Qt.callLater(() => root.rearming = false);
        }
    }

    Timer {
        id: lockTimer
        interval: root.timing.lockDelayMs
        onTriggered: {
            // The lock's content starts at the dim's level (ADR-0040 ID-8), and the dim stays until the lock holds. Set before
            // the request: Lock.lock() flips `locked` synchronously, which disables the monitor and runs update() at once
            // (opus review of 9a417967, MINOR 1).
            Lock.fromDim = true;
            root.dimUntilLock = true;
            dimUntilLockBound.restart();
            const result = Lock.lock("idle");
            if (result !== "ok") {
                // As before this step: the dim lifts at once, and no new attempt is scheduled (not through update()).
                root.dimUntilLock = false;
                dimUntilLockBound.stop();
                Lock.fromDim = false;
                root.dimmed = false;
                console.warn("grassfield-idle: idle lock not engaged:", result);
            }
        }
    }

    // No input while unlocked for inactiveOffSeconds: the displays go off; the session stays unlocked until the idle lock.
    IdleMonitor {
        id: inactiveMonitor
        // Armed only once its timeout is the one wanted, so that turning the setting on never arms it with the placeholder 1 s.
        enabled: timeout === root.inactiveOffSeconds && IdleModel.inactiveOffArmed(root.inactiveOffSeconds, Lock.locked, root.offForInactivity, root.rearmingInactive, root.busInhibited)
        timeout: Math.max(1, root.inactiveOffSeconds)
        respectInhibitors: true
        onIsIdleChanged: {
            root.offForInactivity = isIdle && enabled;
            // IQ-T4 A: the lock first (at once), or after the delay without input, or never.
            if (root.offForInactivity && !Lock.locked) {
                if (root.requireAfterMs === 0)
                    root.displayOffLock();
                else if (root.requireAfterMs > 0)
                    displayOffLockTimer.restart();
            } else {
                displayOffLockTimer.stop();
            }
            root.updateDisplays();
        }
        onEnabledChanged: {
            if (!enabled) {
                root.offForInactivity = false;
                displayOffLockTimer.stop();
            }
            Qt.callLater(root.updateDisplays);
        }
        // The power source changed (or the setting): re-enable so that the new timeout applies (see `rearming`).
        onTimeoutChanged: {
            root.rearmingInactive = true;
            Qt.callLater(() => root.rearmingInactive = false);
        }
    }

    // Input on the lock screen (respectInhibitors false: a video behind the lock is not being watched). Only while the lock
    // is secured (Lock.holding: the compositor confirmed it and the lock surfaces are up), never while it is still being
    // acquired: the displays never go dark over a session that is not locked yet.
    IdleMonitor {
        id: lockedMonitor
        enabled: Lock.holding && root.displayOffSeconds > 0 && !root.rearmingLocked
        timeout: Math.max(1, root.displayOffSeconds)
        respectInhibitors: false
        onIsIdleChanged: root.updateDisplays()
        onEnabledChanged: root.updateDisplays()
    }

    // ---- Automatic sleep (macOS 27 Energy and Battery > Options…: Prevent automatic sleeping when the display is off). The idle
    // lock, the display-off lock and the lock screen's power-off above never read any of this. The one lock it can cause is
    // the lock before an automatic sleep on a session not locked yet (autoSleepAction "lock"), which only ever adds a lock. On
    // battery and on the power adapter alike, the computer sleeps only when energy.preventSleep is false (default true:
    // Grassfield never put a computer to sleep by itself before, and a value that cannot be read keeps it awake;
    // IdleModel.sleepPrevented, integrator decision 2026-11-04). ----
    readonly property bool sleepPrevented: IdleModel.sleepPrevented(Settings.energyPreventSleep)
    readonly property bool autoSleepArmed: IdleModel.autoSleepArmed(root.displayOff, root.sleepPrevented, root.busInhibited)
    // Seconds the displays stay off without input before the sleep; a dev test shortens it (`idle devAutoSleep <seconds>`).
    property int autoSleepSeconds: IdleModel.AUTO_SLEEP_SECONDS
    // autoSleepSeconds passed since the displays went off (a monotonic Timer: the idle monitor below may count from the last
    // input, which came well before the displays went off).
    property bool autoSleepWaited: false
    // A lock or a suspend was asked for: not again until the retry Timer (IdleModel.AUTO_SLEEP_RETRY_MS) or a new display-off
    // period.
    property bool autoSleepAsked: false
    // Dev session: suspends that were due and not run (the dev session never suspends the owner's computer).
    property int autoSleepSuppressed: 0

    onAutoSleepArmedChanged: {
        root.autoSleepWaited = false;
        root.autoSleepAsked = false;
    }

    function autoSleepCheck(): void {
        if (!sleepMonitor.enabled || !IdleModel.autoSleepDue(root.autoSleepArmed, sleepMonitor.isIdle, root.autoSleepWaited, root.autoSleepAsked))
            return;
        // Read afresh at the moment of the decision (a binding that missed a change must not put the computer to sleep).
        if (IdleModel.sleepPrevented(Settings.energyPreventSleep) || root.busInhibited)
            return;
        const action = IdleModel.autoSleepAction(Lock.currentState(), Lock.currentlySecure());
        if (action === "wait")
            return;
        root.autoSleepAsked = true;
        if (action === "lock") {
            // The lock first: it lights the displays until it holds (IdleModel.displaysOff), they go off again, and the next
            // due time, with the lock LOCKED and secure, suspends.
            console.info("grassfield-idle: displays off for " + root.autoSleepSeconds + " s without input; locking before the automatic sleep");
            const result = Lock.lock("sleep");
            if (result !== "ok" && result !== "already-locked")
                console.warn("grassfield-idle: lock before the automatic sleep not engaged:", result, "; staying awake");
            return;
        }
        if (root.devHooks) {
            root.autoSleepSuppressed++;
            console.info("grassfield-idle: automatic sleep suppressed (dev session)");
            return;
        }
        // Read once more right before systemctl runs (review of 95dab794: an unlock that began meanwhile, a fingerprint just
        // before the due time, is in AUTHENTICATING or RELEASING and must not be put to sleep).
        if (IdleModel.autoSleepAction(Lock.currentState(), Lock.currentlySecure()) !== "suspend") {
            root.autoSleepAsked = false;
            return;
        }
        console.info("grassfield-idle: displays off for " + root.autoSleepSeconds + " s without input, locked; going to sleep (automatic)");
        autoSleepRequest.running = true;
    }

    // A change of the lock (IdleModel.autoSleepOnLockChange, read afresh): a lock that settled LOCKED and secure after the due
    // time decides again; an unlock ends the attempt (the delay starts over with the next display-off), so an unlock can never
    // lead to the lock-first path and undo itself (review of 2a19231d: a fingerprint touch over the due time); anything else
    // changes nothing.
    function autoSleepLockChanged(): void {
        const next = IdleModel.autoSleepOnLockChange(Lock.currentState(), Lock.currentlySecure());
        if (next === "end") {
            root.autoSleepWaited = false;
            root.autoSleepAsked = false;
        } else if (next === "recheck") {
            Qt.callLater(root.autoSleepCheck);
        }
    }

    Connections {
        target: Lock

        function onSecureChanged(): void {
            root.autoSleepLockChanged();
        }

        function onLockStateChanged(): void {
            root.autoSleepLockChanged();
        }
    }

    Timer {
        id: autoSleepDelay
        interval: root.autoSleepSeconds * 1000
        running: root.autoSleepArmed
        onTriggered: {
            root.autoSleepWaited = true;
            root.autoSleepCheck();
        }
    }

    // A request that did not end in a sleep (logind refused it: an application's sleep block inhibitor such as a download;
    // a refused lock; a wake without input) is asked again every IdleModel.AUTO_SLEEP_RETRY_MS while the displays stay off
    // (review of 95dab794: a laptop otherwise stays awake all night once the download ends). Never a tight loop; monotonic, so
    // the time asleep does not count; stopped by input (the displays come on, the monitor disarms).
    Timer {
        id: autoSleepRetry
        interval: IdleModel.AUTO_SLEEP_RETRY_MS
        repeat: true
        running: IdleModel.autoSleepRetryArmed(root.autoSleepArmed, root.autoSleepAsked)
        onTriggered: {
            root.autoSleepAsked = false;
            root.autoSleepCheck();
        }
    }

    // No input and no Wayland idle inhibitor (a video plays, even behind the lock) for autoSleepSeconds since the displays
    // went off. Enabled only then, so its timeout is the one wanted (see `rearming`).
    IdleMonitor {
        id: sleepMonitor
        enabled: root.autoSleepArmed
        timeout: Math.max(1, root.autoSleepSeconds)
        respectInhibitors: true
        onIsIdleChanged: root.autoSleepCheck()
    }

    // logind decides (an application's sleep block inhibitor refuses it) and runs the lock before sleep (SleepInhibitor).
    // --no-ask-password: an automatic sleep never asks for authorization (polkit's suspend-multiple-sessions, another user
    // logged in): refused, the computer stays awake; no authorization sheet waits behind the lock to suspend after unlock.
    Process {
        id: autoSleepRequest
        command: ["systemctl", "--no-ask-password", "suspend"]
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0)
                console.warn("grassfield-idle: automatic sleep refused by the system (systemctl suspend exit " + exitCode + "); staying awake, locked; asked again in " + IdleModel.AUTO_SLEEP_RETRY_MS / 60000 + " min while the displays stay off");
        }
    }

    // ---- A resume from sleep lights the lock screen (macOS: waking the computer lights its displays; without input they go off
    // again after the lock screen's delay; the owner's rc6 report: "waking from sleep is very slow"). The displays stay
    // off across a suspend that started with them off (Hyprland changes its DPMS state only on a dpms request or input; the
    // automatic sleep always starts that way) and the key that woke the computer is
    // usually not delivered as input: the displays stayed dark until a second input, and only then did each external display
    // start to sync. Here the lock screen's display-off countdown starts over: its idle monitor (and the unlocked one) is
    // re-armed, so the displays come on (updateDisplays) and go off again after displayOffSeconds without input. Display only:
    // nothing here locks, unlocks, releases or delays a lock; only a locked session with the displays turned off by this module
    // is lit, never while a new sleep is under way (IdleModel.wakeAtResume, read when the Timer fires; the Timer also stops when
    // a sleep starts). ----
    property bool rearmingLocked: false

    function wakeAfterResume(): void {
        if (!IdleModel.wakeAtResume(root.displayOff, Lock.locked, sleepInhibitor.sleeping))
            return;
        console.info("grassfield-idle: resumed with the displays off; lighting the lock screen");
        root.rearmingInactive = true;
        root.rearmingLocked = true;
        Qt.callLater(root.armAfterResume);
    }

    // One event-loop turn after wakeAfterResume: both monitors armed again, so the lock screen's countdown runs from now (without
    // this the lock screen's display-off would stay disarmed for the rest of the session: lit all night, no automatic sleep).
    function armAfterResume(): void {
        root.rearmingInactive = false;
        root.rearmingLocked = false;
    }

    Timer {
        id: resumeWake
        interval: IdleModel.RESUME_WAKE_MS
        onTriggered: root.wakeAfterResume()
    }

    // A sleep that starts before the wake was due: no wake from the previous resume (review of c94e3195).
    Connections {
        target: sleepInhibitor
        function onSleepingChanged(): void {
            if (sleepInhibitor.sleeping)
                resumeWake.stop();
        }
    }

    SleepInhibitor {
        id: sleepInhibitor
        onResumed: resumeWake.restart()
    }

    // Dim layer (IdleDim.qml): no input region, so pointer motion reaches the compositor and counts as activity. Its windows exist only
    // while the screens dim and for the fade that follows (ADR-0041 S2: no layer surface per output kept by the security
    // process the rest of the time; display only, nothing locks or waits for it).
    property bool dimShown: false
    onDimmedChanged: {
        if (root.dimmed) {
            dimHide.stop();
            root.dimShown = true;
        } else {
            dimHide.restart();
        }
    }
    Timer {
        id: dimHide
        interval: Appearance.duration(Tokens.motionFast) + 100
        onTriggered: root.dimShown = root.dimmed
    }

    LazyLoader {
        id: dimLayer
        active: root.dimShown
        source: Qt.resolvedUrl("IdleDim.qml")
    }
    // The dim's level follows `dimmed` once the windows exist (they are created at false: the dim fades in).
    Binding {
        target: dimLayer.item
        property: "dimmed"
        value: root.dimmed
        when: dimLayer.item !== null
    }

    // On the security instance only (ADR-0041 S2).
    IpcHandler {
        target: "idle"

        // The UI's lease of the applications' org.freedesktop.ScreenSaver inhibitors (shell/services/LockClient.js): `seconds`
        // bounded by IdleModel.inhibitLeaseMs, 0 ends it. Answers "ok". Only ever keeps the idle dim and lock from starting
        // for that long, as an application's own Wayland idle inhibitor does; a manual lock, the lid and the lock before sleep
        // are unaffected.
        function inhibit(seconds: int): string {
            return root.inhibitFor(seconds);
        }

        // Test hook (dev only, else "refused"): idle state as JSON.
        function status(): string {
            if (!root.devHooks)
                return RunMode.REFUSED;
            return JSON.stringify({
                enabled: monitor.enabled,
                idle: monitor.isIdle,
                dimmed: root.dimmed,
                dimSeconds: root.timing.dimSeconds,
                lockSeconds: root.timing.lockSeconds,
                sleepInhibitor: sleepInhibitor.inhibiting,
                sleepDegraded: sleepInhibitor.degraded,
                sleepBudgetMs: sleepInhibitor.budgetMs,
                displayOffSeconds: root.displayOffSeconds,
                displayOff: root.displayOff,
                inactiveOffSeconds: root.inactiveOffSeconds,
                inactiveOffArmed: inactiveMonitor.enabled,
                offForInactivity: root.offForInactivity,
                busInhibited: root.busInhibited,
                saverSeconds: root.saverSeconds,
                saver: root.saverShown,
                sleepPrevented: root.sleepPrevented,
                autoSleepArmed: root.autoSleepArmed,
                autoSleepSeconds: root.autoSleepSeconds,
                autoSleepSuppressed: root.autoSleepSuppressed,
                autoSleepRetrying: autoSleepRetry.running
            });
        }

        // Dev hook (dev only, else "refused"): run the before-sleep ("before") or after-resume ("after") path without
        // logind (tests/security/reload_locked.sh). The dev shell never holds a real inhibitor, so nothing is delayed.
        function devSleep(phase: string): string {
            if (!root.devHooks)
                return RunMode.REFUSED;
            if (phase === "before")
                sleepInhibitor.beforeSleep();
            else if (phase === "after")
                sleepInhibitor.afterResume();
            else
                return "unknown phase";
            return "ok";
        }

        // Dev hook (dev only, else "refused"): display power-off delay on the lock screen, 0..600 s (0 = never), for
        // tests/security/lock_privacy.sh `display-off`. Takes effect at the next lock.
        function devDisplayOff(seconds: int): string {
            if (!root.devHooks || seconds < 0 || seconds > 600)
                return RunMode.REFUSED;
            root.displayOffSeconds = seconds;
            return "ok";
        }

        // Dev hook (dev only, else "refused"): seconds the displays stay off before the automatic sleep, 1..600, for a nested
        // test of the sleep path (the dev session never suspends: it counts autoSleepSuppressed). Takes effect at the next
        // display-off.
        function devAutoSleep(seconds: int): string {
            if (!root.devHooks || seconds < 1 || seconds > 600)
                return RunMode.REFUSED;
            root.autoSleepSeconds = seconds;
            return "ok";
        }
    }
}
