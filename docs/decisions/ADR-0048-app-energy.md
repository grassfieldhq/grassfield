# ADR-0048: Apps the person cannot see get less CPU and I/O
Status: Proposed (2026-11-05), applied provisionally (owner rule: decide alone, recommended option, macOS model first) ·
Date: 2026-11-05 · Decider: owner (revisit), integrator (merge) · Number: 0048

Inspired by Project Luma's `luma-energy` service and its GNOME Shell extension (MPL-2.0); no code copied. The mechanism
(attention states, the ladder, the claims, the "when unsure, do not limit" rule) is reimplemented from its behaviour.

## Context

macOS slows down an app none of whose windows can be seen (per-app energy saving: timers coalesced, lower priority) and
never the app in front. A Wayland client is not told that it is covered or on another Desktop: a browser buried under a
zoomed window keeps painting and running timers. Only the compositor and the shell know what the person can see.

Facts (2026-11-05, main 78733ac):
- Apps run one per scope, `app-<launcher>-<id>-<random>.scope` under `app.slice/app-graphical.slice` of the user manager
  (ADR-0011 amendment 2026-10-20; the same contract `grassfield-crash-watch` reads). Flatpak apps move themselves to
  `app-flatpak-*.scope` directly under `app.slice`.
- `systemctl --user set-property --runtime <unit> CPUWeight=… IOWeight=…` changes a unit until it stops or the user manager
  ends (runtime drop-ins live in `$XDG_RUNTIME_DIR/systemd`); an empty value (`CPUWeight=`) puts the default back.
- Activity Monitor's Efficiency Mode (ADR-0038 g) sets CPUWeight to 1 (or idle) on the same units by hand.
- The shell knows windows, workspaces, the focused window, minimized windows (`special:minimized`, `Minimized.js`), hidden
  ones (`special:hidden`), Show Desktop's parking and the Stages strip (`grassfield-stages` state: `hidden`, `slot`).
- Stacking order: Hyprland's IPC has none and the compositor plugin exports none (`hyprctl clients` has no z-order;
  ADR-0007 has no stacking event). One fact is reliable: `config/hypr/grassfield/stacking.lua` raises the window that
  becomes active above every non-pinned window of its workspace when it is floating, not full screen, and its workspace
  shows no full-screen window.
- `cpu.uclamp.max` is a cgroup v2 file of the cpu controller (kernel `CONFIG_UCLAMP_TASK_GROUP`); systemd has no property
  for it. Whether a user may write it in a scope of its delegated user manager could not be checked here (this container
  runs cgroup v1 and no user manager): NOT VERIFIED, see D-5.
- PipeWire clients play through the PipeWire socket, not `/dev/snd`: an open `/dev/snd/*` descriptor catches only ALSA
  clients; the stream nodes (with `pipewire.sec.pid`) catch the others.

## Options
1. **A daemon** (Luma's model: a D-Bus service owning the policy). Cons: §5.8 asks for a versioned D-Bus interface, a
   hardened unit, a security model, for something that only needs to run when the shell asks; one more process all day.
2. **All in the shell (QML/JS)**: reading `/proc/*/fd` of every app process from QML (FileView per link) and running
   `systemctl` from the shell. Cons: no `readlink` in QML, hundreds of reads through the event loop, untestable fixtures.
3. **The shell decides what is seen, a short helper does the rest (chosen).** The shell computes one state per window and
   per process (pure JS), and runs `grassfield-energy` (Python, standard library, like `grassfield-crash-watch`) as an argv
   when the picture changes or a timer is due. The helper maps processes to scopes, checks the claims in `/proc`, applies or
   lifts the limits with `systemctl --user set-property --runtime` and keeps what it applied in a state file under
   `$XDG_RUNTIME_DIR` (the same lifetime as the runtime properties). No daemon, no D-Bus name, no new dependency.

## Decision

### D-1 States
Per window, most awake first: `focused` (the focused window), `visible`, `occluded`, `hidden` (`AppEnergyLogic.js`):
- hidden: minimized (the shell's record or `special:minimized`), hidden (`special:hidden`), parked by Show Desktop, unmapped
  or Hyprland-hidden, on a Desktop no display shows, or in a Stages strip that is hidden or beyond the tiles (a strip tile
  draws the window live: it counts as visible).
- occluded: entirely inside the focused window's rectangle, on the same Desktop, when the focused window is the known top
  (floating, not full screen, no full-screen window on that Desktop) and the window is not pinned. One window covers it
  outright or it is not occluded: regions are never summed. Every other case of overlap is "visible" (error direction).
- Special workspaces other than the three parking ones count as visible (a scratchpad may be shown).
- An app (a scope) takes the state of its most awake window; the shell merges per process, the helper per scope.
- While the overview or the app switcher is open, or when a window's process is not known yet (Hyprland gives the pid only
  after a refresh), every window counts as visible: nothing is limited, and a refresh is asked.

### D-2 The ladder, on battery only
| State | On battery | On the power adapter |
|---|---|---|
| focused, visible | nothing | nothing |
| occluded for 10 s | CPUWeight 40, IOWeight 60, uclamp max 60 % | nothing |
| hidden for 30 s | CPUWeight 20, IOWeight 30, uclamp max 40 % | nothing |

Amendment 2026-11-05 (review FAIL, integrator decision, macOS model): the first pass also applied milder weights on the
power adapter (60/80, 40/60), so a desktop without a battery limited apps by default with no switch it could reach (the
switch is in Battery > Options…, and it says "while on battery"). Now nothing is limited on the power adapter: plugging in
lifts everything at once, the shell runs no round there except to lift what is still held, and a computer without a battery
(UPower never on battery) never limits.

Weights only order the queue when something competes: an app alone on an idle machine runs at full speed. The uclamp
value is a hint to the frequency governor, not a quota. Nothing is ever frozen (Luma's freezing is not taken). A change to a
more awake state lifts the limit at once; a change to a less awake state waits for its delay; while it waits the app has
no limit.

### D-3 Claims (never limited) and protected units
Checked by the helper only for apps that would be limited or are limited:
- the person's choice to keep the app running (`--keep`, see Consequences: no UI in this slice);
- sound or video: a PipeWire stream node of one of its processes (the shell reads `pipewire.sec.pid`, the pid the PipeWire server saw on the socket, of the stream
  nodes it tracks; never the client-set `application.process.id`, which any app can set to another's pid) or an open `/dev/snd/*`, `/dev/video*`, `/dev/media*` descriptor in any process of its scope;
- an alarm: a timerfd on `CLOCK_REALTIME_ALARM` (8) or `CLOCK_BOOTTIME_ALARM` (9) (`clockid:` in `/proc/PID/fdinfo`);
- working: more than 0.5 % of one core over the last sampling window (`cpu.stat` `usage_usec` of the scope, a window of at
  least 10 s); the first sample of an app is not judged (counts as working);
- a weight set by someone else: the scope's `cpu.weight` is neither 100 nor the value Grassfield set, or `cpu.idle` is 1
  (Efficiency Mode, uresourced): CPUWeight is theirs and is left alone; what else Grassfield set (IOWeight, uclamp) is put
  back at once (amendment 2026-11-05, review BLOCKER: the first pass forgot them too, and they stayed until the scope ended).
Protected (never touched): any process whose cgroup is not exactly `…/user@UID.service/app.slice/app-graphical.slice/
app-*.scope` (the session, its services, Hyprland, portals, PipeWire, Flatpak scopes, anything outside the person's app
slice), and a scope holding a session process by name (the shell, Quickshell, Hyprland, portals, PipeWire, WirePlumber,
input methods, Omarchy's background tools, Grassfield's services).

### D-4 When the limits are lifted at once
Pre-emptive (`grassfield-energy wake`, no debounce): the overview opens, the app switcher opens, a window is focused or asks
for attention (its app), the Dock activates an app (its windows), the power adapter is plugged in (all, and nothing more is
limited until it is unplugged). The picture is
recomputed 250 ms after the last change (focus, windows, Desktops, Stages, battery, setting, streams) and the helper runs
only when its digest changed, or when the helper asked to be run again (`next`: an app waiting for its delay, at most 60 s
while anything is limited or claimed). At shell start (crash recovery) and when the setting is turned off the shell runs
`grassfield-energy reset`, which lifts every limit the state file records; `grassfield-shell.service` runs it again in
`ExecStopPost` (stop and crash).

### D-5 uclamp
Written straight into the scope's `cpu.uclamp.max` only when the file exists and is writable; a failed write marks uclamp
unavailable in the state file and it is never tried again in that session. `max` is written back on every release. Real-session behaviour (whether a delegated user scope exposes a writable
`cpu.uclamp.max`) is NOT VERIFIED (owner L2: `grassfield-energy status` prints `uclamp: available|unavailable`).

### D-5a Occlusion and stale geometry
Hyprland sends no event when a window moves or is resized, and the shell's geometry is its last read (`lastIpcObject`). A
picture with an occluded process is therefore acted on only when the window data was asked to be read again within the last
2 s (`AppEnergyLogic.needsFreshGeometry`): otherwise the shell asks for a refresh and judges again when it arrives. The helper
also asks the shell to run again (and so to refresh) at least every 60 s while anything is limited.

### D-6 Dev sessions
A nested dev session must never touch the owner's apps (its windows' processes live in the owner's scopes): the shell passes
`--dry-run` and a state file under the dev state directory whenever `Mode.dev` is true. The helper applies the same rule
itself (ADR-0019, as `grassfield-report`; review of the first pass): with `GRASSFIELD_DEV=1` and no `GRASSFIELD_SESSION=1`
every command is a dry run, unless the test seams replace both `/proc` and the cgroup tree (a test's fixture); the seams
(`GRASSFIELD_PROC_ROOT`, `GRASSFIELD_CGROUP_ROOT`, `GRASSFIELD_ENERGY_NOW`) are honoured only in a dev session. A dry run
without `--state` uses `app-energy.dry.json`, never the real file (a dry release must not hide real records from a reset). A dry run computes and records the
decisions (`status` explains them) and never runs `systemctl` nor writes a cgroup file. Tests run the helper against a fake
`/proc` and cgroup tree (`GRASSFIELD_PROC_ROOT`, `GRASSFIELD_CGROUP_ROOT`) with a `systemctl` stub.

### D-7 UI
- Settings > Battery > Options… (`PowerOptionsSheet.qml`, which already holds Prevent automatic sleeping when the display
  is off) gets a second group with one switch: "Slow down apps you can't see while on battery" (fr « Ralentir les apps que
  vous ne voyez pas sur batterie ») and its caption. Key `energy.slowHiddenApps` in the existing `energy` group (boolean,
  default true, schema-generated, ADR-0020). Off: every limit is lifted and nothing is limited. The caption says that
  nothing is slowed down on the power adapter. (Written
  first as its own sheet and `battery.*` key; moved here when the branch merged the base that had added the sheet.)
  The menu bar's "Battery Options…" sheet (`BatteryOptionsSheet.qml`, Show Percentage) is a different sheet and is unchanged.
- Activity Monitor: not changed in this slice (see Consequences). `grassfield-energy status` explains, per app, its state,
  what is applied and why it is or is not limited.

### D-8 Resource budget
- Shell: one recompute per settled change (a few hundred windows at most: well under 1 ms of JS), no polling while every app
  is visible and nothing is applied, and none on the power adapter.
- Helper: one Python start (about 20 ms of CPU) per changed picture, and at most one every 10 s while an app waits for its
  delay, then one every 60 s while anything is limited or claimed (claims can change: work, alarms). Per run: one read of
  `/proc/PID/cgroup` per window process; for each app that would be limited, its `cgroup.procs`, one `readlink` per open
  descriptor of its processes and one `fdinfo` read per timerfd, and its `cpu.stat`. Typical: under 30 ms of CPU per run,
  under 20 MB resident for its lifetime (well under a second). Average below 0.1 % of one core while limits are held.
- State file: a few kB in `$XDG_RUNTIME_DIR/grassfield/app-energy.json`, written atomically under an exclusive lock
  (`app-energy.lock`), so a `wake` and a round never interleave.

## Evidence
- L0: `tests/unit/tst_appenergy.qml` (states, occlusion, Stages strip, merge, uncertainty, digest, helper arguments),
  `tests/shell/app_energy.sh` (the helper against fake `/proc` and cgroup trees and a `systemctl` stub: scope contract,
  protection, ladder, nothing on mains, delays, CPU sampling, claims, foreign weights (IOWeight and uclamp put back), release,
  reset, dry run and its own file, the dev rule, wake, uclamp writable or not, failures, status), `tests/unit/tst_settingspower.qml` (Options… and the sheet), settings vectors and
  `tests/shell/settings_apply.d` for `energy.slowHiddenApps`.
- L1 written, not run: `tests/shell/app_energy_nested.sh` (two foot windows in their own scopes, one minimized: limited in
  the dev dry run after 30 s, woken when the overview opens, nothing applied for real).
- NOT VERIFIED (no Hyprland, Quickshell runtime, user manager or cgroup v2 in the agent's container): the shell wiring at
  run time, `systemctl set-property` with empty values on a real scope, uclamp writability, the battery gain, no stutter
  when switching back to an app (owner L2), the Settings sheet's rendering (visual NOT verified), and that the stream nodes' property
  maps in Quickshell carry `pipewire.sec.pid` (a private PipeWire instance could not be started in the sandbox; owner L2: `pw-dump`
  on a playing stream). A stream without it names no process: the helper's `/dev/snd` check still applies, and the person's
  choice to keep an app running (`--keep`) is the remedy until the field is confirmed.

## Consequences
- New: `packaging/bin/grassfield-energy` (installed with the other helpers in `/usr/lib/grassfield`),
  `shell/services/AppEnergy.qml` and `AppEnergyLogic.js`, `Compositor.energySnapshot()`, a group in the Battery
  Options… sheet, the schema key, an `ExecStopPost` line in `grassfield-shell.service`.
- Limits: only apps with a window are managed (an app whose windows are all closed is released and forgotten, even if it
  keeps running in the background); Flatpak apps (outside `app-graphical.slice`) are never limited; occlusion only by the
  focused window (a window covered by an unfocused one, or by a full-screen window, stays visible).
- Follow-ups: the person's per-app "keep running" choice (the helper honours `--keep`; the UI home to decide, macOS has it
  in the app's Get Info window, which is Files' territory); a plugin z-order export (`hyprctl grassfield-stacking`) for
  occlusion by any window and by full-screen ones; an "App Energy" column in Activity Monitor's Energy tab reading the state
  file; apps without windows.
- Revisit when the owner measures (L2) that the gain is negligible or that switching back stutters.
