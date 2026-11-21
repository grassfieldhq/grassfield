# ADR-0058: the shell's keys and trackpad gestures reach it in-process, over socket2
Status: Accepted (audit fix round 2, CIO-01; lead to confirm) · Date: 2026-11-19 · Decider: integrator · Number: 0058 · Related: ADR-0002 (key bindings), ADR-0007 (gfc/1), ADR-0019 (run modes), ADR-0041 (security process), ADR-0056 (file: imports), GF-115

## Context

Every shell-directed key and gesture of `config/hypr/grassfield/bindings.lua` ran `hl.dsp.exec_cmd("env -u … qs ipc -p … call
<target> <fn>")`: a fork, `sh`, `env`, then a whole Quickshell client that loads, finds the instance and makes a socket round
trip. Search, Overview, the tiling keys and Cmd+Tab paid a process start before the shell saw the key; the volume, brightness
and zoom keys repeat, so a held volume key started about 40 Qt processes a second, which can arrive in any order (the switcher
already carried hold ids because `next` and `release` raced). The Overview and Apps gestures were discrete (one `qs ipc` at
the end), where macOS tracks the fingers.

Options:

1. Hyprland's global shortcuts (`hl.dsp.global("grassfield:<name>")`, hyprland-global-shortcuts-v1) received by Quickshell's
   `GlobalShortcut`. In-process, press and release, but one registered object per shortcut name, no argument (the switcher's
   hold id, a tile place, a Stage number each need their own name), duplicate app id + name pairs crash the client that
   registers last (a shell restart racing its predecessor), and no channel for a gesture's progress.
2. **A socket2 event**: Hyprland's `event` dispatcher (`hl.dsp.event(data)`, `Actions::event`: `custom>>data` on socket2 in
   0.56.2 and 0.57.2) read by the connection the shell already has (Quickshell.Hyprland `rawEvent`). Arguments are free text,
   socket2 is one ordered stream, nothing is registered, and gesture progress is just more events.
3. A plugin Lua function posting a gfc/1 event: same as 2 but only with the plugin loaded (gate C2: the keys must work without
   it).

## Decision

D-1 (option 2) bindings.lua's `shell(target, fn)` returns `hl.dsp.event("gfkey/1 <target> <fn> [argument...]")` (an empty `''`
argument is left out). The shell's `qs.platform.shortcuts` singleton (`shell/platform/shortcuts/Shortcuts.qml`, logic in
`Shortcuts.js`) reads `custom` events and calls the IpcHandler of that target, the same function `qs ipc call` reaches, so a
handler's own checks (a locked session refuses, SessionState.refuses) apply unchanged and there is one implementation per
request. Each IpcHandler a binding calls attaches itself (`Component.onCompleted: Shortcuts.attach(this)`); with several for
one target the enabled one answers (shell.qml's early forwarding handlers hand over to the built surface by `enabled`, as
Quickshell does for `qs ipc`).

D-2 The router accepts exactly the requests bindings.lua sends (`Shortcuts.js` `requests`: target, function, argument kinds
checked by pattern), no test hook and no other function: the payload comes from a socket any process of the user can write to
(`hyprctl dispatch event …`), the same trust as `qs ipc`, with a smaller surface. `tests/unit/tst_shortcuts.qml` reads
bindings.lua and fails when a binding sends a request the list lacks or the list holds one no binding sends.

D-3 The lock key alone stays a process: `qs ipc` to the security process and, when it does not answer, Grassfield's stand-in
(`omarchy-shell lock lock`). It must lock with the UI process dead or restarting, and an event delivered to no listener would be
a silent "no lock" (fail closed). One fork per lock request costs nothing.

D-4 Gestures (Overview: 3 fingers up / down; Apps: 4-finger pinch in / out) use Hyprland's Lua gesture callbacks (`action =
{ start, update, end }`, present in 0.56.0+) and send `gfgesture/1 <kind> <phase> <progress>` (kind overview-open,
overview-close, apps-open, apps-close; phase begin, update, end with `commit` or `back`, cancel; progress 0..1 written as 0, 1 or
0.xxxx). A swipe's progress is its distance over `gestures.workspace_swipe_distance` (the Spaces swipe's 1:1 length), a
pinch's its scale (1 → 0.5 in, 1 → 2 out). Updates are sent only per 1 % of progress (socket2 drops a client whose queue
overflows: the event_flood measurement of FR24). The end completes past half way, or at 2 lengths a second toward the goal from
10 %. A surface that follows the progress calls `Shortcuts.follow(kind, true)` and animates from `Shortcuts.gesture(...)`; while
none does, the router performs the discrete open or close at a committed end (the behaviour of before, without the fork).

D-5 A Hyprland without the `event` dispatcher (none known in the supported range) gets the `qs ipc` commands of before:
bindings.lua checks `hl.dsp.event` at parse. A target whose handler has not attached is still served by the router through
`qs ipc` (logged once): a missing attach costs the fork, never the key.

## Consequences

- No process per key or gesture; the order of keys is socket2's order. The switcher's hold ids stay (the fallback still races).
- Every IpcHandler that a binding calls must attach (the files listed in the audit request R1); `tst_shortcuts.qml` ties the
  router's list to bindings.lua, `tests/shell/bindings_inprocess.sh` checks what each bind and gesture sends,
  `tests/shell/shortcuts_router/shell.qml` checks the real router against attached handlers.
- Overview and Apps follow the fingers once their surfaces implement D-4's follower (request R2); until then the gesture still
  opens and closes at its end, now without a process.
- Settings > Keyboard reads the same literal `bind(..., shell("<target>", "<fn>"))` lines as before.
- Owner check (real session only): each key reaches the shell (`hyprctl dispatch event "gfkey/1 search toggle"` opens Search),
  and the gestures on a touchpad.
