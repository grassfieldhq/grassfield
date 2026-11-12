# Testing: layers and the test inventory

Every test of the repository belongs to exactly one **layer**, and `tests/inventory.json` lists all of them.
Nested Hyprland sessions reset the shared GPU, so a test goes in the lowest layer that can catch its bug.

| Layer | Needs | Examples | How it runs |
|---|---|---|---|
| `data` | nothing but files and system tools | docs vs. JSON tables, packaged fontconfig/icon theme/dconf profile, source guards | `scripts/dev/test.sh` |
| `logic` | no Qt GUI | gtest suites, Python tool tests, shell scripts under test (`hidden-entries.sh`, `open-policy.sh`) | `scripts/dev/test.sh` |
| `headless` | the real QML/Quickshell code on `QT_QPA_PLATFORM=offscreen`, no compositor, no `WAYLAND_DISPLAY`, isolated HOME/XDG | `tests/unit/tst_*.qml`, `tests/shell/*/shell.qml`, `tests/shell/settings_apply.sh`, `tests/integration/menu_bridge_memory.sh`, `tests/integration/launcher_entry.sh` (private bus) | `scripts/dev/test.sh` (a few are bare commands) |
| `nested` | the nested Hyprland instance (`just nested-up`): compositor behaviour, real input, the plugin | `tests/compositor/*.sh`, `tests/integration/global_menus.sh`, `tests/shell/apps_nested.sh` | bare commands (ask the owner) |
| `visual` | the nested session and screen captures | `just visual` scenarios, `tests/visual/*` capture scripts, `contrast.sh` | bare commands (ask the owner) |

The offscreen pattern (headless): link the real `shell/*` modules into a temporary config directory, copy the test's
`shell.qml` over, run `qs -p DIR` with `QT_QPA_PLATFORM=offscreen`, `env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE`,
`HOME`, `XDG_RUNTIME_DIR` and `GRASSFIELD_STATE_HOME` under a scratch directory. See `tests/shell/desktop_new_folder.sh` and
`tests/shell/folder_styles_apply.sh`.

## `tests/inventory.json`

```json
{
"version": 1,
"layers": ["data", "logic", "headless", "nested", "visual"],
"discover": ["tests/shell/*.sh", "..."],
"ignore": [{"path": "tests/visual/lib.sh", "reason": "helper sourced by the visual scripts"}],
"tests": [{"path": "tests/shell/hidden_entries.sh", "layer": "logic"},
          {"path": "tests/compositor/overview.sh", "layer": "nested", "runner": "bare"}]
}
```

- `path`: repository-relative file of the entry point (a `shell.qml` for a Quickshell test directory, a `tst_*.cpp`
  for a gtest source, a `*Test.cpp` for the compositor unit tests).
- `layer`: exactly one of `layers`. A `layers` key, a second entry for the same path or an unknown name is an error.
- `runner`: `test.sh` (default; `scripts/dev/test.sh` runs it) or `bare` (a bare command run by hand: nested session,
  captures). `bare` entries are counted as "manual" in the summary and never started by `test.sh`.
- `enabled`: omit it. `false` fails the gate: a required test is not switched off, it is removed or fixed.
- `discover`: globs of files that look like tests. A match that is neither in `tests` nor in `ignore` fails the gate.
- `ignore`: helpers and runners that match a glob but are not tests; each needs a `reason`.

New test file: add one line to `tests` (or to `ignore` with a reason). Helpers and fixtures outside the globs need nothing.

## No container may share the host's devices

`python3 -I tests/ci/no_privileged_containers.py` (`just check-containers`, part of `just check-quick`; `--selftest` runs it on
about a hundred and fifty bad spellings, each of which must be refused; it is also a `logic` test) is an allowlist, not a list of
bad flags. **It is a lint against accidental reintroduction, by people or agents; it is not a sandbox against deliberately
written code** (ADR-0057). The real boundaries are at run time: the wrapper refuses anything dangerous it is handed
(`tests/shell/container_wrapper.sh`, with a stub docker: every refusal fires before docker is called), `update_migrate.sh` fails
closed outside a VM (`tests/shell/update_migrate_refusal.sh`), and the VM itself.

- Every tracked text file is read, whatever its extension (shell, python, lua, `.service`, `.desktop`, zsh, extensionless
  executables, QML, C++, JS), except `docs/` and markdown. Outside the wrapper, EVERY non-comment occurrence of `docker`, `podman`,
  `nerdctl`, `buildah`, `distrobox`, `toolbox` or `systemd-nspawn` as a whole token, hyphenated forms included (`ctr`, `runc`,
  `incus`, `lxc` and `machinectl` count only when a command follows them, so a variable named `ctr` passes)
  (`docker-compose`, `podman-compose`, `podman-remote`, `distrobox-enter` ...), is refused, in any position and in any file type:
  a command, a `${X:-docker}` default, a case arm, a for-list, after `&`, a variable, a python `os.system` or `subprocess` string
  (or a list, an f-string, a triple-quoted script), a `$(command -v docker)` or `$(which docker)` lookup that is then run, behind
  a runner (`env exec command nice ionice timeout xargs flock unshare systemd-run` and the privilege wrappers). A `compose`
  subcommand is refused too. The only forms that pass are `docker info`, `command -v docker`, and text inside echo or printf (not
  `printf -v` in any form, not echo piped into the common shells (`sh`, `bash`, `zsh`, `ash`, `/bin/bash`, `env bash`, `exec sh`, a privilege
  wrapper before them; rarer forms such as `| env FOO=1 bash`, `|& bash` or `| busybox sh` are not caught: the lint targets
  accidents, see ADR-0057), not evaluated, not read by `bash <(...)`
  or `. <(...)`). A line that names one without running a container (a test stub, a unit
  name, a message) is waived by exact file and line text in `ALLOW`: seven today, each one visible. A compose file, a Dockerfile,
  a Containerfile and a yaml `options:` line are refused too.
- `tests/integration/container.sh` is the one wrapper every integration test and gate uses (`gf_container_init`, `gf_mount`,
  `gf_network`, `gf_standard`, `omarchy_mounts`, `gf_container_run`). Inside it, each docker call is one of five exact
  spellings and each statement that adds an option is one of a short list. A flag held in a variable or an array, or one the
  guard cannot resolve, fails the check. Mount sources are checked when the test runs: the repository (read-only), its `.dev/`, an
  Omarchy tree registered by `omarchy_mounts` and its staged `bin/`, one regular file under the repository, a CA `*.crt`, `*.pem` or
  `*.cer` only under `.dev/` or a documented CA folder (`/etc/ssl/certs`, `/etc/ca-certificates`, `/usr/share/ca-certificates`,
  `/usr/local/share/ca-certificates`, `/etc/pki`; never `/run`, `/dev`, `/proc`, `/sys`, `~/.ssh`, `~/.gnupg`, `~/.config`), and,
  read-write, a folder of the caller's own one level under `/tmp` or one level under `$TMPDIR` (only when `$TMPDIR` is inside
  `/tmp`; no other place named by the environment), or under the repository's `.dev/` at any depth (its own scratch
  area; `.dev` is resolved, and a link out of the repository is refused). A source that is, is inside, or CONTAINS a forbidden
  place (`/`, `/dev`, `/proc`, `/sys`, `/run`, `/boot`, `/root`, `~/.ssh`, `~/.gnupg`, `~/.config`, `~/.local/share/keyrings`,
  `~/.password-store`) is refused, so neither `~` nor `~/.local` can be mounted. Every `docker run` line of the wrapper carries `--cap-drop NET_RAW`
  itself, so no path can skip it. The repository
  root is derived from the wrapper's own location and read-only; so is the proxy list. The image is
  the first argument, pinned by `@sha256:` (a local image only by an exact name in `GF_LOCAL_IMAGES`); an argument before it that
  starts with `-` is refused; `gf_container_exec` runs only in the container id the wrapper started. In a git worktree, the common
  git folder is mounted read-only at the same path (a `git archive` copy would lose the history some tests read).
  `--network host` is used only when an HTTP(S) proxy URL names the host's loopback (`NO_PROXY` never counts);
  `scripts/gates/rc-toolkit.sh` asks the wrapper (`gf_proxy_network`), so both agree.
- `CAP_SYS_ADMIN` is only in `gf_container_systemd_start`, which only `tests/integration/update_migrate.sh` may call.

Why: `tests/integration/update_migrate.sh` used to run `docker run --privileged` with systemd as PID 1. A privileged container
shares the host's `/dev`, so its systemd ran `systemd-vconsole-setup` and udev on the host's devices: the kernel logged
"fbcon: Taking over console", the Hyprland session received SIGHUP, SDDM could not take `/dev/tty1` and went into
start-limit-hit. It ended the owner's live session three times on 2026-11-11 (16:47, 19:13, 20:28).

### Running update_migrate.sh

**Never on a machine with a live graphical session, and never on the machine you work on.** Its container runs systemd as PID 1.
It now has `CAP_SYS_ADMIN` minus `MKNOD`, no `--device`, no host path mounted, a tmpfs `/run`, and every unit that touches a tty or `/dev` masked (udev,
vconsole, gettys, console password and mute units, logind, hwdb, device and module setup, the FUSE control mount); a user namespace
is not available per run with docker (`userns-remap` is a daemon setting), so the virtual machine is the real boundary. Be plain
about what the container does not contain: with `CAP_SYS_ADMIN`, docker's default seccomp profile allows `mount(2)` and an Arch
host has no AppArmor profile, so code inside can mount a fresh `/proc` or `/sys` and reach `sysrq-trigger` or `power/state`.
Only the refusal and the VM contain that. The script
enforces that itself and fails closed: before any docker call it refuses unless it runs in a VM (`systemd-detect-virt --vm`) or on
a CI runner (`CI=true`, `GITHUB_ACTIONS=true` and `RUNNER_TEMP` together; `CI=true` alone is not enough), refuses beside any
wayland, x11 or mir session that is not closing (read from `loginctl` and from `/run/systemd/sessions/*`), and refuses when it
cannot tell. There is no override. `tests/shell/update_migrate_refusal.sh` proves it with a stub docker (no container is ever
started), including loginctl failing beside a wayland session file.

In the GF-010 VM (`scripts/gates/vm-drill.sh`, qemu/KVM, 4 vCPUs, 6 GB, user networking, started only at host load <= 8):

```
scripts/gates/vm-drill.sh update-migrate --repo .      # boots the VM, ships `git archive HEAD` of the repository, runs it there
```

It runs `tests/integration/update_migrate_in_vm.sh` as the VM's root: it refuses outside a VM, stops the VM's display manager (the
test refuses beside a graphical session) and starts it again afterwards, starts docker, runs the test, and
prints the VM's own kernel log and journal lines about the console, VTs, fbcon, vconsole, gettys, udev or SIGHUP during the
run, the console binding before and after, and the PASS and FAIL counts. A clean run shows none of those lines.

Anything else that needs a real device or a real console is run in the VM too, never on the host.

## The gate

`python3 -I tests/ci/inventory.py` (Python standard library only; part of `just check` as `check-inventory`, and the first
step of `scripts/dev/test.sh`) fails when

1. a test file matched by `discover` is not registered or ignored;
2. a registered test (or an ignored path) does not exist;
3. a registered test is disabled;
4. a test has no layer, an unknown layer, or two layers;
5. with `--results FILE --layers a,b`: a layer reports no result in the run, or only skips (nothing verified).
   `scripts/dev/test.sh` writes the results file and runs this check on the layers it covered.

`python3 -I tests/ci/inventory.py --selftest` runs these cases on temporary fixtures (it is also a `logic` test).
`--map` prints `path<TAB>layer<TAB>runner` for the enabled tests (`test.sh` reads it).

Limits: the batch runners (`qmltestrunner` over `tests/unit`, a gtest binary) report one result for their group, so
the run check is per layer, not per file. Which layer a test is in is a judgement the reviewer checks.

## User-reported regressions

Every failure a person using Grassfield reports gets a stable ID (`URR-NNN`) in
[`user-reported-regressions.md`](user-reported-regressions.md): the report date and version, the reproduction, the cause,
the fix with its regression test, the verification and the first shipped version. A source fix is not a shipped fix: an
entry stays open until a released version carries it. Beta testers attach the file `grassfield-report` writes (Settings >
General > About > Create Diagnostic Report…, ADR-0053); the report stays private, the ledger cites only the version.

## `scripts/dev/test.sh`

```
scripts/dev/test.sh                     data, logic, headless, and the tests/shell scripts of the nested layer (they SKIP themselves without a session)
scripts/dev/test.sh --layer headless    one layer, or several: --layer data,logic
```

The end of every run prints one line per selected layer: `pass fail skip manual`. An explicitly requested layer that
reports nothing but skips fails the run (`--layer nested` without a session). In the default run the nested layer is not
gated (its scripts SKIP without a session by design); a layer with only bare commands (`visual`) is reported, not gated.

## Moving a test down a layer

A test that starts a nested session only to drive shell QML logic (no compositor behaviour, no capture, no real input)
belongs in `headless`. Move it, then prove it still catches its bug: apply a temporary mutant of the code under test,
see it fail, revert it. Record the layer change in `tests/inventory.json`.

## Nested tests that stay nested (reviewed 2026-10-22)

| Test | Why it needs a session |
|---|---|
| `tests/shell/apps_nested.sh` | `AppsWindow` is a layer-shell `PanelWindow` with exclusive keyboard focus; under `QT_QPA_PLATFORM=offscreen` Quickshell has no PanelWindow backend ("No PanelWindow backend loaded"). The controller logic is already headless (`tst_appspanel.qml`, `tst_exclusivesurfaces.qml`). |
| `tests/shell/overview_two_outputs.sh`, `tests/visual/overview-highlight.sh`, `tests/compositor/*.sh`, `tests/integration/global_menus.sh`, `tests/security/reload_locked.sh` | compositor behaviour: plugin, real input, outputs, focus, session lock. |
| `tests/visual/degraded-notice.sh` | the notice itself is posted by `shell/shell.qml` (not loadable alone) and the test loads and unloads the real plugin. A headless test of `Capabilities` alone would not cover it. |
| `tests/visual/icon-a2.sh`, `icon-shader-cold.sh`, `icon-modes*-perf.sh`, `icon-modes-switch-memory.sh`, `folder-glyph-perf.sh`, `dock-*` | GPU scene graph (ShaderEffect), frame timing, memory of a live shell. |
| `tests/apps/files_sandbox.sh` | real keyboard and pointer input into the Files window. |

Moved down: `tests/apps/files_registrar.sh` (nested to headless): the nested session only supplied a Wayland socket; the app
now runs on the offscreen platform. It needs a private D-Bus daemon (Unix socket), so it SKIPs inside the Claude Code
sandbox and stays a bare command (`runner: bare`) until it has run on the owner's machine.

## Gate tools with honest verdicts (GF-008 residual)

`scripts/gates/` holds measurement tools whose verdict says what was measured: `PASS`/`FAIL` only from the real thing, `PROXY`
for a lower bound (a part of the path), `NOT VERIFIED` when nothing could be measured.

- `scripts/gates/p4-search-latency.sh` (gate P4): builds a 100k-file fixture under `.dev/p4-fixture`, indexes it with user-mode
  `updatedb` and times the same `plocate` argv the Search provider uses: `PROXY` (provider only, a lower bound, not the gate: 47 ms
  median, 82 ms p95 on the loaded dev machine, archived in the project's run reports; the report's
  verdict line says "exit 0 with caveats"). `--shell-log-apps FILE` judges app results per keystroke against 50 ms from the shell's own log
  (`PASS`/`FAIL`); file results stay `PROXY` until the shell timestamps them end to end.
- `scripts/gates/r1-restart.sh` (gate R1): `--journal` reads the real unit's journal (read-only) and times every restart the
  unit made itself (a logout is not one) and checks that the lock state came back; `--nested` times a nested shell restart
  (`PROXY`: the dev launcher, not the unit). Without a crash in the journal it says `NOT VERIFIED`.

Test: `tests/shell/gate_tools.sh` (fixtures only).

## Gate run reports (GF-036)

Run artefacts used to disappear with removed worktrees, so a result could not be re-audited. Every gate run can leave a dated
report with the commit, the build id, the exit code and the log path:

```bash
just gate check just check                       # any command: runs it, tees the log, writes the report, keeps its exit code
just gate nested-overview tests/compositor/overview.sh   # a bare nested command (ask the owner first)
scripts/dev/gate-run.sh --record NAME EXIT LOG   # a script that ended on its own summary line records itself
just gate-archive                                # copy .dev/gate-runs/* into docs/testing/runs/ (then review and commit)
```

Reports live in `.dev/gate-runs/<UTC stamp>-<name>.md` (git-ignored); `just gate-archive` copies reports and logs (a log over
256 KiB as its last 2000 lines) into `docs/testing/runs/`, which the repository keeps. A report counts `PASS`, `FAIL`, `SKIP`,
`NOT VERIFIED` and `PROXY` lines and says so when a run is not a plain pass: cite the report, not a remembered result.
Release checks and nested gate runs are started through the same helper (`just gate release-check just release-check`), so
there is one format; a script that prints its own summary line can call `--record` at its end. Test: `tests/shell/gate_run.sh`.

## Functional flows and the nested smoke set (GF-009, GF-094)

`tests/visual/flow-<module>.sh` (bare, nested only; `tests/visual/flow-lib.sh` is the shared helper): one script per module,
used the way a user does, asserting the shell's own state over its dev IPC, the shared `grassfield.json`, files on disk and the
windows the compositor reports, with a screenshot per step in `.dev/visual/shots/flow-<module>-*.en.png`. Pixels only prove that
something appeared or went away. Modules: `search`, `quicksettings`, `widgets`, `settings`, `files`, `preview`, `notifications`.
Each starts a nested session when none is up (`vs_session`), refuses any other instance (`dev_nested_target`) and ends the windows,
banners, widgets and settings it changed. Where a control has no IPC (the Tab position of a Quick Settings tile, the row of a context menu) the flow
finds it by trying and asserting the effect, so a changed layout still passes and a broken control fails with the step named.
Not driven: the Lock Screen command of Search (it would lock the nested session for good; only its presence is asserted), the
devices behind the Quick Settings toggles (the dev guard answers; the flow asserts the guard), the transparency slider's drag
(the IPC hook calls the slider's setter).

`tests/shell/smoke_nested.sh` (run it bare; a `smoke-nested` just recipe is a one-line wrapper): the nested smoke set, eight checks in about 20 s on a nested session that is
ALREADY up: compositor lists, shell IPC and unlocked, plugin handshake, Quick Settings state and a menu, Search, Apps (and their
mutual exclusion), the notification server and Center, and no QML error in `.dev/shell.log`. It starts nothing and opens no window,
and it SKIPs without a session, so `scripts/dev/test.sh` (nested layer) carries it whenever a session happens to be up.

## Test-only tools and their build dependencies

Two small C tools drive the NESTED compositor from tests, built on first use into `.dev/` (never installed, never in the package):

- `tests/tools/vkbd` (scripted keyboard): `wayland-scanner`, libwayland-client, libxkbcommon.
- `tests/tools/xdgact` (a window that activates itself through `xdg_activation_v1`, for the real activation order of Show Desktop): `wayland-scanner`, libwayland-client and `wayland-protocols` (the `xdg-shell` and `xdg-activation` XML files).

All of them are installed as dependencies of Hyprland and Quickshell, so they are build-time requirements of the tests only: they do not belong in the PKGBUILD `depends` (runtime) array. A machine without a C toolchain runs the offline layers; the nested scripts that need a tool say so and stop with exit 2. `tests/tools/hypr-events.py` (python3 standard library) reads Hyprland's event socket for `tests/shell/show_desktop_record.sh`.

## Fuzzing (ADR-0041 step 5)

Every reader of text another process, a file or the compositor hands to Grassfield has a mutation fuzz test next to its
unit tests, in the tree, with no dependency beyond gtest and Python: a corpus of valid inputs is mutated (bit flips, special
bytes, JSON tokens, number extremes, escapes, invalid UTF-8, nesting, growth past the payload cap, splices of two entries)
from a seed, for a budget of iterations, and each parser is held to its contract: no crash or hang, the same answer when
the same text is read twice, a bounded CPU time per call (wall-clock time would flake on a loaded machine), and every
invariant its header promises on an accepted input. The same seed gives the same inputs (the runner proves it with two
runs of one seed); a finding prints the seed and the iteration, so it reproduces.

| Harness | Readers | Run |
|---|---|---|
| `compositor/tests/ParserFuzzTest.cpp` (gtest, in the compositor suite) | the gfc/1 requests (`overview`, `overview_focus`, `stages`, `arrange`), the config key/value readers, the window address and D-Bus address validators, `json::CReader`, `jsonEscape` (round trip), `stages::sanitizedText`, and the name readers `isGrassfieldNamespace`, `classifyLayer`, `splitZone`, `capabilityCandidate` | with the suite (2000 iterations per parser); `compositor/build-direct.sh tests-asan` then `GF_FUZZ_ITERATIONS=50000 compositor/build/grassfield-compositor-tests-asan` for the long budget under ASan and UBSan (`scripts/gates/release-check.sh` step `comp-asan`); `GF_FUZZ_SEED` picks another seed |
| `tests/fuzz/helpers_fuzz.sh` (logic layer; `tests/fuzz/fuzz_helpers.py` and the mutator `tests/fuzz/mutate.py`) | `grassfield-crash-watch` (journal entries, desktop entries, cgroup.events, locale names), `grassfield-session-end` (`hyprctl -j clients`), `grassfield-battery-watch` (sysfs), the ANR stand-in's client matcher, the `omarchy-shell lock status` filter (needs jq), `sleep-lock-gate` (the socket and instance names) and `grassfield-update-check` (checkupdates' and pacman's output, its own time files, the release notes, pacman.conf) | `scripts/dev/test.sh` (1500 iterations in process, 300 per scenario that starts a process); `GF_FUZZ_ITERATIONS=20000 tests/fuzz/helpers_fuzz.sh [scenario...]` for the long budget. The runner starts the harness without the caller's session variables (`HYPRLAND_INSTANCE_SIGNATURE`, `WAYLAND_DISPLAY`, `DISPLAY`, D-Bus) and with every home under its scratch directory: the owner's session is never reachable from a test |

A finding is fixed in its own commit with a deterministic regression case in the reader's unit test (the seed and the
iteration name it); the harness is not weakened to pass. Still to cover (ADR-0041 step 5): the shell's QML and JS readers
(the gfc/1 event parser, the Apps model's desktop entries, every state file of the ADR-0020 table), the menu bridge's
DBusMenu layouts, Activity Monitor's `/proc` readers, the Store's catalog and pacman output readers; they need Qt and
Quickshell offscreen, which the first harnesses do not.
