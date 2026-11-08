# Gate tooling (GF-008, D-6)

How each measurable gate of master-prompt section 10 is run. Every tool prints numbers, sample counts and the threshold,
and ends with a verdict. Exit codes: 0 PASS, 1 FAIL, 2 INCONCLUSIVE or usage error (no valid evidence is never a pass).
All of them are registered in `tests/inventory.json`; the pure logic is tested offline by `tests/shell/gates.sh`
(part of `just test`). Bare commands (outside the Claude sandbox) are marked.

| Gate | Command | Notes |
|---|---|---|
| P1† idle CPU, <= baseline + 0.5 pt | `just gate-idle --nested` (this tree's nested session) or `just gate-idle --real [--baseline-pid PID]` (the owner's session, read only) | utime + stime from `/proc/<pid>/stat` of grassfield-shell and the menu bridge over 600 s (`--seconds`); the desktop must be idle; `--nested` and windows shorter than 600 s are "PROXY, NOT VERIFIED" (exit 2): PASS only for the owner's real session over 600 s; bare |
| P2 memory, <= baseline + 150 MB | `just gate-rss --real --baseline-pid PID` (omarchy-shell in the Omarchy session) or `--baseline-mb 458` (ADR-0006's measured omarchy-shell RSS) | VmRSS (and PSS); without a baseline the verdict is INCONCLUSIVE; bare |
| P3† frames < 16.7 ms, >= 95 % | `just gate-frames [dock, overview, apps or all] [N=20]` | **L1 proxy only, never a PASS**: nested session, shell render-thread time, 100 frames minimum; prints "PROXY, NOT VERIFIED" or "PROXY FAIL". The gate needs wp_presentation timestamps (ADR-0006) on the owner's real session: no probe client exists yet (open); bare |
| P5† session to usable, <= 2 s | `just gate-startup [--boots N]` | journal: uwsm start line to the shell's `grassfield-shell: usable` line (menu bar and Dock of every output drew a frame); a shell without the marker is INCONCLUSIVE; bare |
| Q1 lint | `just check` (qmllint and `scripts/dev/tidy.sh`) | tidy runs over every compositor translation unit; a passing run is stamped, `scripts/dev/tidy.sh --force` re-runs |
| Q3 coverage >= 70 % | `just coverage` | gcov JSON summary (`scripts/gates/coverage_report.py`) of `compositor/src/core` and the menu bridge logic; the Hyprland glue and the bridge's Bridge/main/LauncherWatcher are listed as not measured |
| local CI | `just release-check [--rc-headers ROOT] [--rc]` | clean build of `git archive HEAD`: `just check`, `just test`, coverage, gitleaks of the history, plugin build (and against rc-channel headers when given; with `--rc` the rc-channel gate below too); the summary lists the skipped cases of `just test`; bare |
| T-5, T-10, C3 rc-channel toolkit | `just gate-rc [--only lint,test,plugin] [--channel rc\|stable]` | a throwaway Arch container set up as an Omarchy machine of the channel (`[omarchy]` first, Omarchy's own Quickshell build; Arch's repositories from the channel's dated mirror; ADR-0041 step 2c): the QML lint against the rc Quickshell's qmltypes, the offscreen suites (data, logic, headless) on the rc Qt, Quickshell and KDE Frameworks, the plugin build and its unit tests against the rc Hyprland headers; the report (`.dev/rc-toolkit/<timestamp>/`, `summary.json` for the watch job of ADR-0033 f) names the toolkit and what moved against this machine; INCONCLUSIVE without docker; bare |
| C1 soak | `tests/compositor/soak.sh [seconds] [stages]` | aims at each window's real titlebar; counts effective actions; FAIL on a shell restart, an RSS slope above `SOAK_MAX_RSS_MB_H` (10), an unreadable log; HARNESS ERROR (exit 2) when an action type never took effect; bare, nested |
| GF-013 version agreement | `just gate-version --nested` or `--installed` | VERSION is the reference; PASS needs every source of the mode (nested: menu bridge and plugin; installed: About file, pacman for both packages, bridge, plugin from `hyprctl grassfield`); a missing one is INCONCLUSIVE (exit 2), a differing one FAIL; bare |
| off-machine copy | `just backup DIR` | git bundle of every ref, verified, with its SHA-256 |

P4 (Search latency), R1 to R3 and A1 have no tool yet (GF-008 remains open for them).

## P2 and the security process (ADR-0041 step 1; S2 of 2026-11-08)
P2 counts both Quickshell processes of the session: the UI (`grassfield-shell`) and the security process
(`grassfield-security`, the lock, idle and the sleep inhibitor since S2). `just gate-rss --nested` sums the security
process (this tree's `.dev/security.pid`, started beside the shell by `scripts/dev/shell-run.sh`) with the shell; with
`--pid` give both. Measurements so far:

| When | Where | Security process | UI | Notes |
|---|---|---|---|---|
| S1, 2026-10-31 (#72) | nested, the integrator | 157 MB RSS at idle (root hosting one IPC handler) | not taken | sets `MemoryHigh=320M`, `MemoryMax=640M` |
| S1 (main 8b04383c), 2026-11-08 | offscreen proxy in the agent's container, 15 s after start, three runs | 64.9-65.1 MB RSS, 27.2-27.5 MB PSS | cannot load offscreen (layer-shell windows) | `qs -p` of the root, `QT_QPA_PLATFORM=offscreen`, isolated homes and runtime directory, `/proc/<pid>/smaps_rollup` |
| S2 (feat/safe-mode-s2), 2026-11-08 | the same proxy, three runs | 108.4-117.0 MB RSS (median 110.2), 66.3-75.8 MB PSS (median 68.2), lock and idle loaded, unlocked | cannot load offscreen | about +45 MB RSS, +41 MB PSS (medians) moved out of the UI with the lock, idle and the inhibitor; nothing is drawn offscreen (no lock surfaces, no stills) |
| S2, nested | NOT VERIFIED (the integrator, bare) | expected about 202 MB unlocked; about 268 MB locked on two 4K outputs (stills about 33 MB each) | expected lower than before S2 by the lock module and its stills | `scripts/dev/nested-up.sh`, then `scripts/gates/rss.sh --nested --baseline-mb 458 --samples 6 --interval 10` unlocked, then `tests/visual/ipc.sh lock lock` and the same command locked |

The offscreen rows are a proxy of the QML objects and JavaScript only (no GPU or Wayland buffers); P2's verdict needs the
nested and real-session rows.
