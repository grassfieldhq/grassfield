# grassfield-compositor

Hyprland plugin for the Grassfield session (master-prompt §5.6):

- titlebars on floating windows: close / minimize / zoom buttons on the left, centered title,
  drag to move (a maximized window un-zooms under the pointer), double-click per Settings (zoom by default);
- the dark appearance's inner rim (FR57, ADR-0024 note 2026-11-03): 1 pt of white just inside every window's frame (its
  titlebar included), continuous round the rounded corners, drawn over the content with Hyprland's border shader;
- minimize / restore with a funnel (default) or shrink animation into / out of the Dock tile the shell sends (M2,
  FR44-FR46), hidden state `special:minimized` (shared with the shell's fallback);
- appmenu protocol (feature 3, D4): the `org_kde_kwin_appmenu_manager` global (version 2); each window's
  DBusMenu address (service, object path) is validated and posted to the shell as a gfc/1 `appmenu` event;
- overview v2 (feature 4, Mission Control): the real windows of the current workspace drawn live, scaled and moved
  into the layout the shell sends, through Hyprland's window transformers (`Render::IWindowTransformer`); the clients
  are never resized (`docs/specs/overview.md` "v2 spike" and "Shell contract"); only while the shell's chrome
  (`grassfield-overview`) is mapped on their monitors and one Exclusive chrome holds the keyboard;
- desktop focus policy (features `desktop-focus` and `desktop-focus-v2`, ADR-0012): click-to-focus for the shell's
  desktop surface (`grassfield-desktop-icons`) on pointer presses: a click on a window while the desktop holds the
  keyboard gives that window the keyboard (Hyprland's focus rules apply), a left click on the desktop gives it the keyboard
  on its `on_demand` commit unless something else moved the keyboard first, nothing on hover; a click without motion
  after a popup closed is classified by what is under the cursor (`docs/specs/desktop.md` "Compositor focus policy");
- Stages (M5 prototype, behind the flag `config("stagesEnabled", "true")`, features `stages-available` / `stages`,
  ADR-0013): strip stages' windows stay mapped and live, drawn into the shell's strip tiles, their input blocked; swaps
  animated (`docs/specs/stages.md`);
- cursor refresh (feature `cursor-refresh`, ADR-0014): after the shell's `setcursor <theme> <size>`, a pointer that does
  not move is drawn again at the new size, same shape, same place (FR39-FR40);
- overview close focus (feature `overview-focus`, owner decision 2026-10-19 batch 5): the shell names what gets the
  keyboard when the Overview closes (the window or Desktop chosen, the window remembered at open, or none); the plugin
  focuses it once no Exclusive layer surface is left, checked again then, through Hyprland's own focus path; a press after
  the request wins; outcome events (FR41-FR43, `docs/specs/overview.md` "Close focus"); the deferred-focus decisions are
  shared with Stages (`DeferredFocus.*`);
- layer pointer focus (feature `layer-pointer`, FR51-FR52): when a shell layer (`grassfield-*`) maps or takes the keyboard
  under a resting pointer, Hyprland's pointer focus is re-run at the cursor (what one pixel of motion does), so a click
  without motion reaches it at the right place (Hyprland 0.56.2 places the pointer wrongly on an output away from the
  layout origin);
- toplevel drag (feature `toplevel-drag`, FR58, ADR-0036 amendment 2026-11-08, URR-030): the `xdg_toplevel_drag_manager_v1`
  global (version 1), so a browser tab torn off follows the pointer, drops back into a tab strip (the dragged window is never
  the drag's target) and tiles like any dragged window; Hyprland's own drag and drop is observed through libwayland's protocol
  logger, never patched;
- shell IPC `gfc/1`: capabilities event on Hyprland's socket2, `hl.plugin.grassfield.{hello, minimize,
  restore, config, appmenu, overview, stages, cursor_refresh, overview_focus}()`, `hyprctl grassfield`.

Spec: [`docs/specs/compositor.md`](../docs/specs/compositor.md).

**Load it only into the nested dev instance** (R13). Loading it into a real session is an owner action.

## Requirements

- Hyprland **0.56.2** headers (`pkg-config --modversion hyprland`), built with the same compiler (GCC).
- C++23 (the 0.56.2 headers use `std::expected` and `std::string_view::contains`).
- Lua 5.5 headers (`pkg-config lua`); Lua symbols resolve at load time from Hyprland's own `liblua`.
- `hyprwayland-scanner` (0.4.6 tested): generates the appmenu server code from `protocols/appmenu.xml`, and the toplevel-drag
  server code from the installed wayland-protocols' `staging/xdg-toplevel-drag/xdg-toplevel-drag-v1.xml` (`pkg-config
  --variable=pkgdatadir wayland-protocols`; without it the plugin builds without that global).
- Tests: GoogleTest (`gtest`).

## Build

CMake (`cmake` and `ninja` are installed now; same outputs, protocol code generated in the CMake build dir):

```sh
just plugin-build      # = cmake -S compositor -B compositor/build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo && cmake --build compositor/build
```

Direct build (no CMake): `compositor/build-direct.sh [plugin|tests|tests-asan|compdb|all|tidy]` (default `all` =
plugin + tests + compdb; `tests-asan` builds the unit tests again with `-fsanitize=address,undefined` into
`build/grassfield-compositor-tests-asan`, the build `scripts/gates/release-check.sh` runs the parsers' mutation fuzzing on,
ADR-0041 step 5; `tests` and `tests-asan` need gtest only, not Hyprland's headers). The exact commands it runs, from `compositor/`:

```sh
hyprwayland-scanner protocols/appmenu.xml build/protocols     # when an output is missing, empty or older than the XML
FLAGS="-std=c++23 -O2 -g -DNDEBUG -fPIC -Wall -Wextra -Ibuild $(pkg-config --cflags hyprland pixman-1 libdrm) $(pkg-config --cflags lua)"
g++ $FLAGS -fvisibility=hidden -w -c build/protocols/appmenu.cpp -o build/protocols/appmenu.o
g++ $FLAGS -shared \
  src/main.cpp src/Titlebar.cpp src/Ipc.cpp src/Minimize.cpp src/AppmenuServer.cpp src/Overview.cpp src/DesktopFocus.cpp src/Surfaces.cpp \
  src/core/Protocol.cpp src/core/TitlebarLayout.cpp src/core/PointerGesture.cpp src/core/Minimize.cpp src/core/Appmenu.cpp \
  src/core/EventThrottle.cpp src/core/Overview.cpp src/core/DesktopFocus.cpp build/protocols/appmenu.o $(pkg-config --libs hyprland pixman-1 libdrm) -o build/grassfield-compositor.so

g++ -std=c++23 -O0 -g -Wall -Wextra -Isrc $(pkg-config --cflags gtest_main) \
  tests/ProtocolTest.cpp tests/TitlebarLayoutTest.cpp tests/PointerGestureTest.cpp tests/MinimizeTest.cpp tests/AppmenuTest.cpp \
  tests/EventThrottleTest.cpp tests/OverviewTest.cpp tests/DesktopFocusTest.cpp \
  src/core/Protocol.cpp src/core/TitlebarLayout.cpp src/core/PointerGesture.cpp src/core/Minimize.cpp src/core/Appmenu.cpp \
  src/core/EventThrottle.cpp src/core/Overview.cpp src/core/DesktopFocus.cpp $(pkg-config --libs gtest_main) -o build/grassfield-compositor-tests
```

`compdb` writes `build/compile_commands.json` (one entry per translation unit, same flags as above, via `jq`).

Outputs: `compositor/build/grassfield-compositor.so`, `compositor/build/grassfield-compositor-tests`,
`compositor/build/compile_commands.json` (`compositor/build/` is gitignored). `-DGRASSFIELD_OUTPUT_DIR=<dir>` writes them
elsewhere (the rebuild on the target builds from read-only sources).

## After a Hyprland update (ADR-0009, "Amendment 2026-10-23")

A plugin only hooks into the Hyprland build it was compiled for; the `hyprland` version is never constrained. The
`grassfield-compositor` package ships, next to the plugin, its ABI stamp (`grassfield-compositor.abi`, Hyprland's own
client-hash formula, written by the build itself: `abi-stamp.cmake`, target `grassfield-compositor-abi`), the plugin
sources (`/usr/src/grassfield-compositor`) and `grassfield-compositor-rebuild` (on PATH). The session
(`config/hypr/grassfield/compositor.lua`) loads the packaged build when its stamp is the ABI of the Hyprland that runs,
else the user's own build (`$XDG_CACHE_HOME/grassfield/compositor/<abi>/`) when `grassfield-compositor-rebuild --vetted`
vouches for it (the cache root canonical, its ancestors root's or the user's and not writable by others unless sticky;
every directory from it down, the plugin and its stamp: no symlinks, the user's, not writable by group or others; the
stamp is the ABI; the check is bounded to 5 s), else nothing: degraded mode (gate C2) and one translated notice from the shell
naming the Hyprland version and the recovery (`--status`). A config reload keeps the build of the first parse (runtime
note). The stamp's second line, `source <pkgver-pkgrel>`, is the Grassfield version of the build: a build is loaded only
when it is the installed sources' VERSION (a cached build from older sources is stale even for the right Hyprland and is
rebuilt; `--status` says `reason=stale-build`), and the package depends on exactly its own `grassfield-desktop`
version: the shell and the plugin of one release speak one protocol (ADR-0007, ADR-0009). `grassfield-compositor-rebuild` (run as the user; it refuses root) builds the shipped sources with CMake and the
compiler in a private temporary directory (nice, at most 4 compilers, 15 min bound per step) and installs the result in
the user's cache (0700 directories, symlinks refused, the build's own stamp written last); log out and back in to use it.
With the opt-in setting `windows.rebuildExtension` (Settings > Desktop & Dock, off by default) the shell runs that build
itself in the background on a mismatch (`--session`) and loads the result into the running Hyprland when its ABI
matches. Nothing is compiled as root or by a pacman hook. `--check` tells which build matches. Tests:
`tests/shell/compositor_rebuild.sh`, `tests/unit/tst_extensionstatus.qml`, and nested `tests/compositor/abi_mismatch.sh`
(a build against another commit loaded by hand: it refuses itself, the session stays usable).

## Test

```sh
compositor/build/grassfield-compositor-tests     # pure logic: protocol JSON, button layout, hit-testing,
                                                 # double-click, drag threshold, pointer press ownership,
                                                 # minimize validation / easing / frames / texture boxes,
                                                 # appmenu name/path validation and registrations,
                                                 # event coalescing and log rate limits (FR24),
                                                 # overview payload parsing / interpolation / chrome rule /
                                                 # damage steps (FR25-FR29), desktop focus decisions (FR30),
                                                 # client chrome P1-P7 (ADR-0015), presented-frame ring (FR54)
```

Windows that draw their own chrome (ADR-0015, feature `client-chrome`): nested `tests/compositor/client_chrome.sh` (with
and without the plugin) and case 6 of `tests/compositor/zoom_restore.sh` (Alt+click full screen). Presented-frame times
(gate P3, feature `frame-times`): `hyprctl grassfield-frames` through `scripts/nestctl`, used by
`tests/visual/presented-frames.sh`.

## Lint (gate Q1)

Config: `compositor/.clang-tidy` (`clang-analyzer-*`, `bugprone-*`, `performance-*` minus
`bugprone-easily-swappable-parameters`; analyzer findings are errors; only `compositor/src` and
`compositor/tests` headers are reported). Exact command (writes the compile database first):

```sh
compositor/build-direct.sh tidy
# = compositor/build-direct.sh compdb && cd compositor && \
#   clang-tidy -p build --quiet src/main.cpp src/Titlebar.cpp src/Ipc.cpp src/Minimize.cpp \
#     src/core/Protocol.cpp src/core/TitlebarLayout.cpp src/core/PointerGesture.cpp src/core/Minimize.cpp \
#     tests/ProtocolTest.cpp tests/TitlebarLayoutTest.cpp tests/PointerGestureTest.cpp tests/MinimizeTest.cpp
```

Clean = exit code 0 and no diagnostics. It takes several minutes (Hyprland headers).

## Run (nested only)

`scripts/dev/nested-up.sh` passes the built `.so` to the nested config (`GRASSFIELD_PLUGIN`), and
`config/hypr/dev.lua` loads it with `hl.plugin.load` at parse time (a load requested from a `hyprland.start`
callback would be ignored: Hyprland applies the config's plugin list right after parsing).
`GRASSFIELD_PLUGIN=/path/to.so` loads another build; `GRASSFIELD_NO_PLUGIN=1` starts without it (C2).

```sh
scripts/dev/nested-up.sh
WAYLAND_DISPLAY=$(cat .dev/nested.wayland) setsid foot >/dev/null 2>&1 &
scripts/dev/shot.sh titlebar GF-REF
scripts/dev/pointer.sh output GF-REF abs 960 250 down drag 700 400 up   # drag a titlebar
```

Startup log line (in `$XDG_RUNTIME_DIR/hypr/<nested instance>/hyprland.log`):
`[grassfield] grassfield-compositor 0.8.2-clickfocus initialised on Hyprland v0.56.2 (commit …), ABI hash match`.
Hyprland buffers this log file: later lines can take a long time to appear.

## Soak (gate C1, nested only)

```sh
scripts/dev/nested-up.sh
tests/compositor/soak.sh 3600     # duration in seconds; log: .dev/soak-<timestamp>.log
```

Window churn (short-lived and long-lived foot windows) with titlebar drags (some abandoned mid-drag),
zoom, close and cancelled clicks, and minimize + restore from the Dock (when the plugin advertises
`minimize` and the shell runs) through the virtual pointer. PASS (exit 0) = nested Hyprland alive, no
`coredumpctl list Hyprland` entry for its PID since the start (dumps of other Hyprland instances, e.g. other
worktrees' nested sessions, are listed but not counted), no grassfield exception in the nested log.

Input consistency (FR13 regression, nested only): `tests/compositor/input_consistency.sh [rounds]` — fast
titlebar drags and close-button cancels on one mouse-reporting foot window, each followed by a click inside
another; PASS (exit 0) = every click reached the clicked window and none reached the dragged one.

Minimize (nested only, plugin + shell): `tests/compositor/minimize.sh [repeats]` — minimize with the titlebar
button, restore from the Dock tile, repeated (some restores interrupt the minimize animation), windows closed
mid-animation, screenshots of the animation; PASS (exit 0) = window hidden on `special:minimized` with a
`minimized` event and a Dock tile, restored at its geometry and focused with a `restored` event, every round
completed, Hyprland alive without core dump.

Minimize effects (nested only, plugin + shell): `tests/compositor/genie.sh [timing N | c2 [X Y]]` — funnel, shrink and
Reduce Motion (fade) through the dev settings file, slow-motion (Shift) captures classified by
`tests/compositor/genie_shape.py`, a frame timing verdict that prints every stall with the host load, plugin
unload / load mid-animation, the funnel shader failure (dev fault injection); `c2` in a session started with
`nested-up.sh --no-plugin` checks the shell's fallback. Run it bare, with the relative path.

Double-click setting (nested only, plugin + shell): `tests/compositor/double_click_setting.sh` — rewrites the dev
settings file (`.dev/config/grassfield.json`, restored at exit) to `minimize`, `none`, `zoom` and double-clicks a
titlebar; PASS (exit 0) = minimized, unchanged, maximized then restored.

Appmenu and spike S5 (nested only; every variant on its own private D-Bus bus without service activation):
`tests/compositor/appmenu.sh [variant...]` — runs the Qt reference app `tests/fixtures/menu-demo` (and
Chromium) with or without the test registrar `tests/fixtures/fake-registrar` (built by
`tests/fixtures/build.sh`), records the client's `org_kde_kwin_appmenu` requests (`WAYLAND_DEBUG`), the plugin's
`appmenu` events, the DBusMenu introspection and layout, triggers real app actions through DBusMenu and checks
the clear event at close; PASS (exit 0) = the `qt-registrar` checks all pass and Hyprland is alive.
Never start the registrar fixture on the owner's bus: Qt/KDE apps of the real session would hide their menus.

Overview v2 (nested only, FR25-FR29): `tests/compositor/overview.sh` — 6 foot windows (one ticker, one that reports
mouse buttons and keys), the stand-in `tests/compositor/overview-fixture` for the shell's v2 surfaces (Bottom-layer
backdrop, Overlay chrome holding pointer and keyboard), the verb through `scripts/nestctl`; checks events, unchanged
client geometry, the layout on screen, live content, input routing, restoration, refusal without the chrome (or with a
chrome that does not hold the keyboard), retarget when the active window closes, full screen while open, the damage of a
surface resized while open, the failsafes (chrome unmapped, keyboard leaving the chrome, process exit), refused payloads,
a flood and a plugin unload / load through `scripts/nestctl` during an open overview; prints `PASS (n/N checks)` (29
checks). `tests/compositor/overview.sh perf [seconds]` measures the CPU of the nested Hyprland, the shell and the fixture
with 9 windows.

Desktop focus (nested only, FR30-FR32): `tests/compositor/desktop_focus.sh` — the stand-in
`tests/compositor/desktop-focus-fixture` (desktop surface `grassfield-desktop-icons` on both outputs, behaving as the shell
does with the capability; Dock and menu bar with keyboard None; a right-press menu with a popup grab) and two probe foot
windows (typed bytes captured); cases: click on the last active foot while the desktop holds the keyboard, click the
desktop and type at once, hover and presses on the Dock / menu bar, the last active foot on the other output, popup grab
untouched, a click without motion after the menu closed, a slow `on_demand` commit losing to a focus dispatch or a new
window, unload while the desktop is focused and load again (26 checks). `desktop_focus.sh baseline` runs the same
presses with the plugin unloaded (the Hyprland behaviour the policy fixes) and loads it again; `race` and `stale` run
cases 7 and 8 alone against whatever build is loaded.

Stages (nested only, FR33-FR37): `tests/compositor/stages.sh` — 9 foot windows of three app ids, the strip stand-in
`tests/compositor/stages-fixture` (transparent Top-layer `grassfield-stages` surface over four tiles), the flag, grouping,
live thumbnails, input blocking at real places, an animated swap, regrouping, new / closed windows, focus by dispatch,
hidden strip, workspace switch, minimize, full screen, overlap, strip surface gone, invalid payloads, a 1000-request flood,
unload and reload. `stages.sh perf [seconds]` measures Hyprland's CPU with 3 stages × 3 windows and the
special-workspace alternative.

Cursor refresh (nested only, FR39-FR40, needs `just cursors` once): `tests/compositor/cursor_refresh.sh` — a still arrow
over the desktop and a still I-beam over foot, 24 → 48 → 96 → 24 px through the dev settings file (the shell's
`setcursor` + refresh): size, shape, place, a pointer foot hides while typing stays hidden, a flood, unload/load.
`cursor_refresh.sh baseline` on `nested-up.sh --no-plugin` (C2); `cursor_refresh.sh stress [seconds]` next to `soak.sh`.

Overview close focus (nested only, FR41-FR43): `tests/compositor/overview_focus.sh` — the headless pair GF-REF + GF-REF2
(WAYLAND-1 disabled for the run), foot capture windows, the stand-in `tests/compositor/overview-focus-fixture` (an
Exclusive Overlay chrome per output released in a given order, a polkit-like dialog; Quickshell IPC target `ovf`) and the
foreign locker: the window active at open, a window on the other output, the current Desktop, a Desktop on the other
output, another Desktop, closed and minimized targets, a press beside the remaining chrome, a dialog during the close,
invalid payloads and a flood, unload while waiting, the lock (nothing typed). `overview_focus.sh baseline` against an older
build or a `--no-plugin` session (C2); `--plugin PATH` names the build loaded.

Zoom restore (FR8 regression, nested only): `tests/compositor/zoom_restore.sh` — double-click, click + zoom
button and a drag on a maximized titlebar; PASS (exit 0) = the zoom toggle always restores the floating
geometry and a drag un-zooms the window under the pointer.

## Pointer input

A titlebar consumes left presses on its bar. Press ownership and gesture lifetime are pure logic
(`src/core/PointerGesture.*`, unit-tested); `Titlebar.cpp` feeds it Hyprland's events:

- no button event is cancelled on the event bus: Hyprland records every press as held, also one a
  titlebar consumes, and only a release it processes clears it (a stale held button pins pointer focus,
  so the next click on another window went to the dragged one);
- the release of a press a titlebar consumed is consumed by a titlebar when Hyprland routes it there
  (pointer over a bar); elsewhere it reaches the seat, which drops it because the client never got the
  press (Hyprland logs `sendButton release on a non-pressed button`). A release whose press went to a
  client is never consumed, even over a bar;
- a drag or armed button ends on its release, on any new press (the release was lost), or on a motion
  when Hyprland reports no held button or a pointer device present at the press has disappeared
  (Hyprland 0.56.2 does not release the buttons of a removed pointer device).

## Unload

`PLUGIN_EXIT` removes the titlebars of visible windows through `HyprlandAPI::removeWindowDecoration` and
destroys the others (unmapped or hidden windows, for which Hyprland 0.56.2 defers the removal) directly:
erase from `CWindow::m_decosToRemove`, `CDecorationPositioner::uncacheDecoration`, erase from
`CWindow::m_windowDecorations`. Each titlebar also removes itself from the plugin's
`CPlugin::m_registeredDecorations`, which Hyprland walks with `removeWindowDecoration` after `PLUGIN_EXIT`.
Before that, `minimizer::stop()` removes the minimize render hooks, completes running animations (a restoring
window is made visible; minimized windows stay on `special:minimized`), drops the snapshots and its timer,
`overviewer::stop()` removes every window transformer it attached (an open overview ends at once, with a `closed`
event whose reason is `unavailable`), `desktopFocus::stop()` (first, with the listeners) removes the button, layer and
commit listeners and any pending desktop grant, and
`appmenuServer::stop()` makes sure no Wayland object points into the library after `dlclose`: at compositor
shutdown it destroys every appmenu resource and the global; on a runtime unload with client objects still alive
it pins the library in memory (`dlopen(RTLD_NOLOAD | RTLD_NODELETE)`), removes the global and leaves those
objects inert, because destroying them would make libwayland disconnect the client at its next request on them.
Last, a capabilities event with an empty feature list is posted so the shell returns to its fallbacks.

The library is never really unloaded at runtime, appmenu objects or not: the `.so` holds GNU_UNIQUE symbols (264 in
the 0.56.2 build; `readelf -sW grassfield-compositor.so | grep -c UNIQUE`: inline variables and template statics), which
glibc's `dlclose` never drops, so the image stays mapped after `PLUGIN_EXIT`, and a later load of the same path gets
that same image back (no new copy is read from disk; static and function-local state is not initialized again, so each
module's `stop()` leaves its state as its `start()` expects it). What it means:
- Testing a rebuilt plugin: unload and load run the old code. Restart the nested session instead
  (`scripts/dev/nested-down.sh`, then `scripts/dev/nested-up.sh`), which loads the new build at start. Observed with
  GF-056 P8: a rebuilt plugin loaded after an unload kept the previous build's behaviour until the restart.
- C2 (and the unload and reload cases of the nested tests): what an unload checks is real, since Hyprland calls nothing in
  the library after `PLUGIN_EXIT` and every hook, decoration, listener and Wayland object has been removed or made
  inert; the mapped image is only dead code. A reload checks that `start()` works again after `stop()` on the same
  image, not a fresh load from disk.

## IPC (gfc/1)

| Direction | How | Payload |
|---|---|---|
| plugin → shell | socket2 event, posted at load and on `hello` | `grassfield>>{"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu","overview","desktop-focus"]}` (each feature only when registered) |
| plugin → shell | socket2 event, minimize button or double-click set to minimize | `grassfield>>{"v":"gfc/1","type":"minimize-request","address":"<hex>"}` |
| plugin → shell | socket2 event, end of a minimize / restore | `grassfield>>{"v":"gfc/1","type":"minimized","address":"<hex>"}`, `..."restored"...` |
| plugin → shell | socket2 event: a mapped window's appmenu registration changed, the window was mapped with one, got focus, or on `appmenu(address)`; empty strings when it has none (any more), then `pid` is the window's Wayland client pid (0 for X11/XWayland and clears) | `grassfield>>{"v":"gfc/1","type":"appmenu","address":"<hex>","service":"<bus name>","path":"<object path>","pid":N}` |
| plugin → shell | socket2 event: the seat's keyboard focus entered a mapped window (feature `keyboard-focus`, with appmenu); the menu bar sends a chosen item's action once its window has the keyboard back | `grassfield>>{"v":"gfc/1","type":"keyboard-focus","address":"<hex>"}` |
| shell → plugin | `Hyprland.dispatch("hl.plugin.grassfield.hello()")` (Quickshell) | re-posts capabilities |
| shell → plugin | `hl.plugin.grassfield.minimize("0x<hex>", x, y, w, h)` / `restore(...)` | Dock tile in layout px; validated |
| shell → plugin | `hl.plugin.grassfield.config("titlebarDoubleClick", "zoom"\|"minimize"\|"fill"\|"none")` | allowlisted |
| shell → plugin | `hl.plugin.grassfield.appmenu("0x<hex>")` | re-posts that window's `appmenu` event (shell restart) |
| shell → plugin | `hl.plugin.grassfield.overview("<json>")` | `{"on":bool,"durationMs":int,"curve":[…]?,"windows":[{"address","x","y","w","h"}…]}`; validated |
| plugin → shell | socket2 event, overview state | `grassfield>>{"v":"gfc/1","type":"overview","state":"opening\|open\|closing\|closed","windows":N}` (+ `"reason"`: invalid, no-windows, no-chrome, unavailable, interrupted, fullscreen) |
| plugin → shell | socket2 event at unload | `grassfield>>{"v":"gfc/1","type":"capabilities","features":[]}` |
| (no verb) | feature `desktop-focus` | click-to-focus policy for `grassfield-desktop-icons` on pointer presses |
| shell → plugin | `hl.plugin.grassfield.cursor_refresh()` (feature `cursor-refresh`) after `setcursor` answered `ok` | the pointer drawn again at the new size, same shape, same place; rate-limited |
| shell → plugin | `hl.plugin.grassfield.overview_focus("<json>")` (feature `overview-focus`) when the Overview starts closing | `{"target":"window","address":"0x…"}`, `{"target":"workspace","workspace":N}`, `{"target":"remembered","address":"0x…","workspace":N?}`, `{"target":"none"}`, each with `"id":N?`; validated |
| plugin → shell | socket2 event, overview focus outcome | `grassfield>>{"v":"gfc/1","type":"overview-focus","outcome":"pending\|focused\|fallback\|timeout\|refused\|superseded\|unavailable\|invalid","target":"…","id":N}` (+ `"address"`, `"workspace"`, `"reason"`) |
| query | `hyprctl grassfield` | capabilities JSON |

There is no `grassfield:hello` dispatcher: under Hyprland's Lua config every dispatch is evaluated as
`return hl.dispatch(<arg>)`, so legacy plugin dispatchers (`HyprlandAPI::addDispatcherV2`) are unreachable.

## Layout

- `src/core/` — plain C++ without Hyprland includes (unit-tested): `Theme.hpp` (all visual constants),
  `TitlebarLayout.*` (geometry, hit-testing, double-click, drag threshold), `PointerGesture.*` (press
  ownership, gesture end), `Protocol.*` (gfc/1 JSON, features, config allowlist), `Minimize.*` (argument
  validation, easing, frames, snapshot texture boxes), `Appmenu.*` (D-Bus name / object path validation,
  per-surface registrations and the events they produce), `Overview.*` (strict payload reader and validation,
  interpolation, overview event JSON, chrome rule, focus causes, damage steps), `DesktopFocus.*` (desktop focus
  decision table, layer classification, pending grant), `CursorRefresh.*` (cursor refresh decision, request rate gate),
  `DeferredFocus.*` (focus reasons, press records and the refusal gate shared by Stages and the overview focus),
  `OverviewFocus.*` (overview focus request parsing, gate, target plan, front window order, outcome events).
- `src/` — Hyprland glue: `main.cpp` (entry points, ABI check, event bus listeners, unload), `Titlebar.*`
  (decoration, drawing, input), `Ipc.*` (socket2 events, Lua functions, hyprctl command), `Minimize.*`
  (hidden state, snapshots, render hooks), `AppmenuServer.*` (the `org_kde_kwin_appmenu_manager` global, its
  resources, window listeners, unload policy), `Overview.*` (window transformers, damage, failsafes), `DesktopFocus.*`
  (button and layer commit listeners, keyboard focus moves), `Surfaces.*` (wl_surface -> window / layer owner),
  `CursorRefresh.*` (re-applies Hyprland's last named cursor shape with force, trailing-refresh timer),
  `DeferredFocus.*` (Hyprland's refusal checks, keyboard holder, press context, reason mapping, coalesced event-loop
  attempt; shared by Stages and the overview focus), `OverviewFocus.*` (the overview focus request, layer commit watches,
  bound timer, focus through Hyprland's path), `TopClamp.*` (a window's titlebar never under the menu bar, FR56: the
  plugin's own titlebar drags at every step, the end of Hyprland's drags after the release).
- `protocols/appmenu.xml` — KDE's appmenu protocol, version 2 (LGPL-2.1-or-later, upstream notice kept).
- `tests/` — GoogleTest unit tests for `src/core/`. Nested scenarios (repository root):
  `tests/compositor/soak.sh`, `tests/compositor/input_consistency.sh`, `tests/compositor/zoom_restore.sh`,
  `tests/compositor/minimize.sh`, `tests/compositor/double_click_setting.sh`, `tests/compositor/appmenu.sh`,
  `tests/compositor/event_flood.sh`, `tests/compositor/overview.sh`, `tests/compositor/desktop_focus.sh`,
  `tests/compositor/stages.sh`, `tests/compositor/cursor_refresh.sh`, `tests/compositor/overview_focus.sh`.
