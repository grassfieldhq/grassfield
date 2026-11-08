# ADR-0052: Ongoing activities ("In Progress" items in the menu bar)
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (2026-11-05), applied provisionally (owner standing instruction: decide alone, macOS model first) ·
Date: 2026-11-05 · Decider: owner (revisit), integrator (merge) · Number: 0052

Inspired by Project Luma's Live Extensions (`src/luma-platform`: the semantics library, the Semantic Broker's `core.py`,
`identity.py`, `validation.py`, `docs/developer-platform/live-extensions.md`; Apache-2.0). Mechanism only, reimplemented in
C++/QML for Grassfield; no code copied, no Luma artwork, no Apple name: the UI says "In Progress" (French « En cours »).

## Context

macOS 26/27 shows something that is going on (a timer, a call, a download, a screen recording) as a compact item on the right of
the menu bar, near the status items; a click opens a small popover in the menu material with what the app published and a few
buttons. Grassfield had nothing between a notification (one-off) and a Dock progress bar (ADR-0018, no text, no actions).

Constraints:
- Quickshell cannot own a D-Bus name or serve methods to applications: its source (v0.3.2+, `src/`) registers only its own
  fixed services (`org.kde.StatusNotifierWatcher`/host in `services/status_notifier/`, `org.freedesktop.Notifications` in
  `services/notifications/server.cpp`); there is no QML type to export an object. ScreenSaver (GF-016) met the same wall.
- §5.8: `grassfield-menu-bridge` is the only planned daemon; another one needs its own ADR, unit, budget and security model.
- The publisher's identity must come from the kernel, never from a string the app sends (Luma: credentials → cgroup →
  desktop entry; Flatpak's `.flatpak-info`).

## Decision

### D1. Host: `org.grassfield.Ongoing1` inside grassfield-menu-bridge (no new daemon)
The bridge already is the session-bus side of the shell (ADR-0008): it serves `org.freedesktop.ScreenSaver` and watches
`com.canonical.Unity.LauncherEntry` for the shell and relays them over its menu/1 socket (ADR-0007/0008: the shell talks to the
compositor through gfc/1 and to the bus through the bridge). Ongoing activities are the same shape: apps call a bus service,
the bridge validates and forwards one JSON line per change, the shell draws. Hosting it there adds no process, no unit, no
socket, no dependency (QtCore + QtDBus are already linked) and inherits the unit's hardening and budget. Rejected: a new
`grassfield-ongoing` daemon (a second unit and socket for ~600 lines of logic); the Settings app (not always running).
A bridge that stops drops its socket: the shell clears every activity (fail closed: nothing stale is shown).

Bus name `org.grassfield.Ongoing1` (owned while the bridge runs, never taken over), object `/org/grassfield/Ongoing1`,
interface `org.grassfield.Ongoing1`, XML in `bridges/menu-bridge/dbus/org.grassfield.Ongoing1.xml` (installed to
`share/dbus-1/interfaces`, checked equal to the served introspection by a unit test). A breaking change is `Ongoing2`.
- `Publish(s id, a{sv} state)`: create or replace the caller's activity `id` (`[A-Za-z0-9_-]{1,64}`, the app's own key).
- `End(s id)`: end it (an unknown id is answered like a known one: nothing to learn).
- `Version() -> s`.
- signal `ActionInvoked(s id, s action)`: sent to the publisher's unique name only (a unicast signal), when the user clicks one
  of its buttons.
`state` keys (anything else is InvalidArgs): `kind` (s, required: `timer`, `transfer`, `recording`, `install`, `call`,
`progress`), `title` (s, required, 1-64 characters after cleaning), `subtitle` (s, 0-128), `progress` (d, 0..1; absent or
negative: indeterminate; NaN refused), `started` (x, Unix ms: elapsed time is shown; not more than 1 min ahead nor 7 days
back), `ends` (x, Unix ms: a countdown; not more than 1 min back nor 24 h ahead), `actions` (a(ss), at most 3, id
`[a-z][a-z0-9-]{0,31}` unique, label 1-24 characters). Text is plain: control and bidirectional formatting characters are
removed, white space collapsed; the shell draws it with `Text.PlainText`. Apps supply no markup and no image: the popover
shows the icon and name of the desktop entry the bridge verified.

### D2. Identity from the kernel
On a sender's first call the bridge asks the bus `GetConnectionCredentials` (uid, pid, and the pidfd when the bus gives one),
then reads `/proc/<pid>/root/.flatpak-info` and `/proc/<pid>/cgroup`:
1. uid other than the bridge's: AccessDenied.
2. `.flatpak-info` present: its `[Application] name` is the app id (a malformed file is AccessDenied, never a fallback).
3. Else the cgroup's app unit (ADR-0011's scope contract: `app-[<launcher>-]<id>-<random>.scope`, or
   `app-[<launcher>-]<id>@<random>.service`), systemd's `\xNN` escapes decoded; more than one `-` part before the instance is
   ambiguous: AccessDenied.
4. The id must name an installed desktop entry (`$XDG_DATA_HOME` and `$XDG_DATA_DIRS` `applications/`): `<id>.desktop`, else
   the one entry whose `Exec` binary is `<id>` (the Dock starts `uwsm-app -- <Exec argv>`, ADR-0011 addendum); none or several:
   AccessDenied ("not in a verified application scope", as Luma).
5. With a pidfd, its `/proc/self/fdinfo` Pid must still be the pid after the reads (the process cannot be swapped meanwhile).
Calls that arrive while the identity is looked up wait (at most 4 per sender, 2 s), then are answered.
Threat model: this stops misattribution and a sandboxed app posing as another; native code running as the same user can name
its own systemd scope, or fake a `/.flatpak-info` in a user namespace of its own, and is not contained (it can already do
anything the user can, as with Luma's native path).
Known limit (review of the first pass): the identity is the scope the process runs in, and a process started by another
application without a scope of its own inherits that application's scope. An app started from Alacritty's shell publishes as
Alacritty; Grassfield's own launches (the Dock, Search, Files opening an app: ADR-0011, `apps/appscope.h`) give each application
its scope, so this concerns apps started from a terminal or by a third-party launcher that does not use `uwsm-app`.
A refusal is remembered for 5 s per connection (no credential look-up per call of an unverified publisher), and the desktop
entries are read again at most every 30 s after a miss (60 s otherwise).

### D3. Limits and lifetime
At most 3 activities per verified app (not per connection: a second instance shares them), 16 in all, 64 senders tracked;
10 calls per second per sender, End exempt (more: LimitsExceeded; an End is never refused by the rate limit, so an activity
cannot be left behind); the cap of 64 connections counts those being looked up or holding an activity: a verified connection
holding none gives its place to a newcomer, and a connection refused at the cap leaves no state behind. The shared client
(`apps/ongoing.h`) publishes at most 3 activities per app (the first ones asked for; a fourth copy job waits for a place
instead of being refused at each update), sends at most 2 updates a second per activity and retries a failed End once.
An activity belongs to the connection that created it (another connection of the same app gets AccessDenied for
that id). An activity ends with `End`, when its publisher's unique name leaves the bus (NameOwnerChanged; watched before the
first reply, then confirmed with NameHasOwner as ScreenSaver does), or 10 minutes after its `ends` time.

### D4. Lock screen: redacted, no actions
The shell sends the bridge `{"type":"lock","locked":b}` (SessionState.locked). Until the first such line of a connection the
bridge counts the session as locked (fail closed). While locked, every activity is forwarded as `{"redacted":true}` with an
empty `app`, `title`, `subtitle` and no actions (kind, progress and times stay: "In Progress" with a symbol and a bar), and
`ongoing-action` is refused. The shell's model redacts on its own too while `SessionState.locked` (defence in depth); the menu
bar and its popovers are not shown over the lock surface anyway (GF-116), so this matters for any future lock-screen surface
and for what crosses the socket.

### D5. menu/1 (additive)
bridge → shell: `{"type":"ongoing","id":"<16 hex, the bridge's own key>","app":"<desktop id>","kind":"…","title":"…",
"subtitle":"…","progress":P|null,"started":ms|null,"ends":ms|null,"actions":[{"id":"…","label":"…"}],"redacted":b}` and
`{"type":"ongoing-end","id":"…"}`; the current set is replayed when a shell connects.
shell → bridge: `{"type":"lock","locked":b}`, `{"type":"ongoing-action","id":"<16 hex>","action":"<id>"}` (the bridge checks the
action was declared, then sends `ActionInvoked(<the app's id>, <action>)` to the owner).

### D6. UI (macOS 27 structure, macOS 26 glass)
- Menu bar: one compact item per activity, right of the third-party status items and left of Now Playing, at most 3 (the 3 most
  recently started; `ongoing.barMax`). The item is the kind's symbol (heavy bar glyph: `clock`, `transfer`, `record`,
  `download`, `phone`, `activity`) and, when there is one, a short text in tabular figures (the width stays while the digits
  change): remaining or elapsed time ("4:05", "1:02:03") or the percent ("42%", « 42 % »). Optional items: they give way when the bar
  is crowded, like Now Playing. Accessible name "<App>: <title>" ("In Progress" when redacted).
- Popover (popup kind `ongoing`, menu material and radius, `ongoing.popoverWidth` wide): the app's icon and name, the title,
  the subtitle, a progress bar (or the time), and the app's buttons (at most 3) in a row; a click sends the action and closes
  the popover. Esc closes, Left/Right step to the neighbouring status menu, as Now Playing. It closes when its activity ends.
- Strings: "In Progress", "%1%", kind names for the accessible text; en + fr.

### D7. Producers in this slice
- Files: each copy/move job (`FilesApp::publishJobs`) is a `transfer` activity: the Copy window's title and detail line, its
  percent (indeterminate while preparing), action "Stop" (`cancelJob`).
- Store: the running operation (install, update, removal) is an `install` activity: "Installing <App>", "N of M", a bar when
  the total is known, action "Stop" while the operation is stoppable (`stopOperation`).
- `grassfield-ongoing` (built with the bridge, QtDBus): `run [--kind K] --title T [--subtitle S] -- command…` (indeterminate
  while the command runs, a Stop button sends it SIGTERM, exits with its status), `progress --title T` (zenity's protocol on
  stdin: a number is the percent, `# text` the subtitle; ends at EOF), `timer --title T --seconds N` (a countdown). `run`
  exits with the command's status (128 + the signal that ended it, 127 when it cannot start; `tests/integration/ongoing_cli.sh`).
  Its identity is the scope it runs in (a script run from Terminal publishes as Terminal), never an argument.
Both apps use one shared client, `apps/ongoing.h` (header-only, QtDBus; coalesces to 2 updates a second; republishes when the
bridge's name comes back). Screen recording is deliberately not an ongoing activity: it already has its own menu bar item
(ADR-0045 OC-1, `CaptureState`: the stop glyph and the elapsed time, a click stops), which is the macOS model for it; a second
item would show the same thing twice. Software Update keeps its own notice and Settings pane (ADR-0033). A future producer
inside the shell would insert into the model directly, without D-Bus.

## Failure modes
No bridge, or the bridge without the name (another owner): no items; apps' calls fail (ServiceUnknown) and the helper retries
when the name appears. An app that hangs: its activity stays until its name leaves the bus (or `ends` + 10 min). A flood:
LimitsExceeded, the shell sees at most one line per accepted call. A shell that never reports the lock state: redacted items.

## Tests
- The D-Bus adapter (`OngoingObject`) makes no decision of its own: admission (refusal memory, connection cap, rate limit),
  the caller's judgement from its `/proc` reads (unreadable root, pidfd no longer pinning the pid) and the host (lock
  redaction, buttons only when unlocked and declared) are pure (`Admission`, `judgeCaller`, `Host` in `Ongoing.h`) and
  tested; each review mutant of the first pass is killed by a test.
- gtest (`tests/unit/menu-bridge/tst_ongoing.cpp`): validation of every field and limit, text cleaning, identity resolution
  (flatpak-info, scope names, escapes, ambiguous names, desktop lookup by id and by Exec, other uid), per-app and global
  caps, ownership, rate limit, sender gone, expiry, redaction, the menu/1 lines, the XML equal to the served introspection.
- QML TestCase (`tests/unit/tst_ongoing.qml`): the shell side's parsing, model, ordering, cap, compact text, lock redaction.
- NOT VERIFIED here (no Quickshell runtime, no session bus with systemd scopes): the menu bar items and popover rendering
  (visual NOT verified), the end-to-end flow app → bridge → shell → ActionInvoked, Files and Store publishing on a real
  session, Flatpak's `--talk-name=org.grassfield.Ongoing1`. Owner L2: copy a large folder in Files and start a Store install,
  check the items, the popover, Stop, and that locking hides the text.
