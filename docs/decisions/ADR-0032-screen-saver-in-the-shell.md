# ADR-0032: The screen saver is a shell surface, after inactivity, that never stands in for the lock
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (cloud session, owner brief 2026-10-26 "Économiseur d'écran", owner choices of 2026-10-26 recorded in
the maintainers' project log) · Date: 2026-10-26 · Decider: owner (brief and choices), integrator (merge after review) · Number: 0032

## Context
The Settings brief asks for Screen Saver among the Desktop panes. On macOS 27 it is a sheet opened from Wallpaper > Screen
Saver…; macOS 15 had a pane of its own (`15-Sequoia-Settings-Screen-Saver.png`: the chosen saver, a note "Display will sleep
before screen saver starts. You can manage the timing in Lock Screen Settings." with a Lock Screen Settings… button, then
sections of tiles). macOS starts the screen saver after a time without input, ends it at the first input and consumes that
input (the key or click that wakes the Mac does not reach the window under the saver). The display going to sleep and the
password are separate timers.

Grassfield has no screen saver today. Omarchy 4's own (`omarchy-launch-screensaver`, a terminal showing text effects) is not
started in a Grassfield session: Omarchy's shell and hypridle are not running there
(`docs/audits/final-1.0/02-omarchy-compatibility.md` § 3, § 5.4); idle, the lock and display power are Grassfield's
(`shell/security/idle`, ADR-0010).

The owner chose (2026-10-26): four savers, all Grassfield drawings with no Apple visuals: the Grassfield artwork drifting
slowly, the wallpaper with a clock, a folder's pictures as a slideshow (the Pictures folder by default), a clock alone on
black; and the waking key or click consumed, as on macOS.

## Decision
- **A feature module `qs.saver`** (`shell/saver/`, ADR-0021 features layer): `Saver.qml` (a Scope instantiated in
  `shell.qml`), `SaverModel.js` (pure: arming, the slideshow's order, the clock's drift) and `SaverView.qml` (the four
  drawings). It is not a security module and does not import one for anything but reading `Lock.locked`. Under
  `shell/security/` only the polkit agent changes, and only to hold a request while the saver shows (Consequences:
  `SessionState.saverShown`, which can hold a request, never release one; opus-reviewed); the lock, the idle module and
  their timers are untouched.
- **New keys** (their own schema commit): `screensaver.idleMinutes` (integer 0-240, 0 = never, default 0: a session that
  never set it behaves as today), `screensaver.kind` (`artwork` | `wallpaperClock` | `slideshow` | `clock`, default
  `artwork`), `screensaver.folder` (the slideshow's folder: rule `wallpaperPath`, "" = the user's Pictures folder).
- **When it starts**: an `IdleMonitor` with `respectInhibitors: true` (a Wayland idle inhibitor, such as a playing video,
  keeps it off) after `idleMinutes` without input, armed only while the session is unlocked, no application holds an
  org.freedesktop.ScreenSaver inhibitor (the same `MenuBridge.screenSaverInhibited` the idle lock reads) and the delay is
  above 0. It re-arms when the delay changes (Quickshell's monitor keeps the timeout it was enabled with, as `Idle.qml`
  does).
- **What it is**: one full-screen `PanelWindow` per screen on the overlay layer (namespace `grassfield-saver`,
  `exclusionMode: Ignore`), opaque, input over the whole surface and keyboard focus `Exclusive` while shown. Any input ends
  it: the compositor reports activity to the monitor, which hides the surfaces. Because the surfaces hold the pointer and the
  keyboard, the waking click or key lands on them and goes no further (consumed, the owner's choice). Pointer motion ends it
  too, as on macOS.
- **Never in place of the lock**: the lock and its timers are untouched; `idleMinutes` does not delay or replace
  `lock.idleMinutes`, the display power-off while unlocked or the dim before the lock. While `Lock.locked` the saver is
  hidden (the session-lock surfaces are shown instead of every layer anyway, ext-session-lock-v1), and it does not come back
  after the unlock until the delay passes again. It shows no field, no prompt and no window content: only the artwork, the
  user's wallpaper or pictures and the time.
- **The savers**: the artwork (`GrassfieldArtwork`, slowly panned and scaled); the wallpaper with a clock (the picture each
  display shows, read as the lock reads it, `WallpaperState.lockStill`: ready and under the helper's folders; or its colour, or
  the artwork, under a dimming scrim, the time and date large); a
  slideshow (the folder's pictures, jpg/png/webp, shuffled without repeat, a crossfade every few seconds, decoded at the
  screen's size; an empty or missing folder shows the artwork; while the idle module has switched the displays off it
  prepares nothing more, and each display's cache pruning keeps the other displays' slides); the clock alone (the time and
  date on black, moving to a new place every minute so no pixel stays lit). Reduce Motion: no drift or pan, crossfades only.
- **Settings**: Wallpaper > Screen Saver… opens a sheet: "Start screen saver when inactive" (Never, 1 to 30 minutes, 1
  hour), the four savers as tiles, the slideshow's folder with Choose…, and macOS's note when the display turns off or the
  session locks before the saver would start, with Lock Screen Settings….
- **Dev session**: off unless a test sets a delay (`saver devDelay <s>`) or shows it (`saver devShow`; `saver status`), dev
  only, as the idle module's dev hooks; no effect on the owner's session.

## Consequences
- A new shell module and three keys; Settings gains a sheet. No new service, dependency or language.
- The saver takes the keyboard while shown. It is never up while the session is locked. A polkit request that arrives
  while it shows, or is open when it comes up, is held as behind the lock (owner decision 2026-10-26, opus review of
  0231b44 M1): the sheet shows over the saver without the keyboard, its field empty, says it waited while the screen saver
  was on, and takes the keyboard only after a click that comes at least `heldGuardMs` after the saver ended (a click before
  that still reaches the control it hits: Cancel at worst); a press or the wheel on the sheet while the saver shows goes
  nowhere. Opus review of f513b3b: PASS; its findings (the lint did not check the saver's Binding; a second request
  inherited the first one's hold and focus, pre-existing; every button and the wheel) fixed in b5d7657. Its re-check:
  PASS; its findings (a request right after another ended was not held; a replacement while typing let the rest of a
  password reach the window underneath, new in b5d7657; lint gaps) fixed in 38dbfe8 (a key sink). Its check: PASS with
  two mediums, both from the fix: anything that moved the focus defeated the sink (MEDIUM-A), and a request that ended
  while keys were sunk handed the rest to the window underneath (MEDIUM-B); lows: no Esc on the sink, lint gaps only a
  behavioural test caught, a wrong upstream note. Two fixes of the same hazard having failed review, the owner decided
  (2026-10-26, "Corriger A et B"): the sink takes back any focus and Esc cancels, and a request ending while keys are sunk
  leaves the sink lingering, clear, for up to 1 s after the last key (3 s at most); the reviewers' harness is in the
  repository (tests/security/authagent_flows.sh), fixed in c1ca44f. Its check: PASS, but both fixes held only in the
  harness: in Quickshell's PanelWindow the window was made again when a request ended (an intermediate binding went false
  for a moment) and a focus given while the window had no keyboard went to the field; and the stronger tests showed that
  the linger's timers never started. Fixed in the commit after: `visible`, `takesKeys` and the linger's start from the base
  state, the sheet's input disabled while the sink has the keys and its focus handed back, a harness window that behaves
  like PanelWindow (docs/specs/security.md).
  `SessionState.saverShown` (shell/services, a Binding in shell.qml) carries the saver's state to `shell/security/polkit`,
  the one change there (docs/specs/security.md § Nothing opens over the lock); it can only hold a request, never release
  one. An opus review covers this input handling before merge.
- Only the waking key or click is consumed: the keys typed after it reach the focused window, as on macOS (owner decision
  2026-10-26, opus review of 0231b44 M2: the wallpaper-with-clock saver uses the lock screen's clock, and a password typed
  out of habit after the first key goes to that window; the owner kept macOS's behaviour).
- The `saver` IPC target is in `docs/specs/security.md` § IPC surface (checked by `tests/security/ipc_inventory.sh`);
  `SaverModel.js` has unit tests.

## To verify in a nested session (owner checks before merge)
1. Set a delay of 1 minute; wait: the saver starts on every display; move the mouse: it ends and the window under it gets
   nothing; press a key: same; click: same. With the saver up, run `pkexec true` in a terminal started before: the sheet
   shows over the saver without the keyboard; the waking key ends the saver and reaches nothing; the sheet takes the
   keyboard only after a click on it.
2. Play a video in a browser (an idle inhibitor): the saver does not start.
3. Lock delay shorter than the saver's: the lock comes first and the saver never shows over or after it until the next
   delay; unlock with the saver running: it is gone.
4. Each of the four savers on a real display (the slideshow with the Pictures folder and with an empty folder).

## Alternatives rejected
- Omarchy's `omarchy-launch-screensaver`: a terminal window made full screen through hyprctl, Omarchy's look rather than
  Grassfield's, and not one of the owner's four savers.
- The saver inside `shell/security/idle`: it is not a security function; the security modules stay small and reviewed.
- Letting the waking input through to the window: the owner chose macOS's behaviour.
