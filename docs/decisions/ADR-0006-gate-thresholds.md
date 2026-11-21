# ADR-0006: Gate thresholds
Status: Accepted (owner delegation D-5, 2026-10-23; status before acceptance: Proposed) · Date: 2026-10-17 · Decider: owner

## Context
§10 thresholds are provisional until confirmed with M0 baselines on the reference machine
(Precision 7550, UHD 630, 1080p60, scale 1).

## Baselines (spike S6, main session, read-only, 2026-10-17)
| Metric | omarchy-shell (pid 7971, `quickshell -n -p /usr/share/omarchy/shell`) | How |
|---|---|---|
| RSS | 458 824 kB (VmHWM 534 456 kB), 37 threads | `/proc/7971/status` |
| CPU, 60 s sample during agent activity | 0.27 % of one core | `/proc/7971/stat` utime+stime delta |
| CPU, lifetime average (6180 s, interactive use) | 0.95 % of one core | `ps -o time,etimes` |

The 60 s sample is not a 10-minute idle run (P1 needs an owner-run idle measurement in L2).

## Decision
| Gate | Threshold (confirmed / changed) |
|---|---|
| P1† | grassfield-shell + menu-bridge idle CPU ≤ omarchy-shell idle baseline + 0.5 pt of one core over 10 min (owner measures both in L2 with the same method) |
| P2 | grassfield-shell RSS ≤ 458 MB + 150 MB = **608 MB** after 10 min with Dock, menu bar, Overview opened once |
| P3† | unchanged (≥ 95 % frames < 16.7 ms, Balanced) — method fixed in M1 (Hyprland `debug.overlay` is visual only; use `wp_presentation` timestamps from a probe client) |
| P4 | unchanged |
| P5† | unchanged (≤ 2 s) |
| C1 | 8 h nested soak with scripted churn; a **1 h shortened soak** is acceptable for M1 exit if the full run is scheduled before M2 exit |
| others | unchanged from §10 |

## Consequences
- P2 is measured in the nested session (L1) since memory does not depend on DRM.
- Thresholds are revisited at each milestone gate with new measurements.

## Amendment 2026-10-23 (GF-017): governance record
Items 1 and 2 restate owner decisions (the maintainers' project log "Owner decisions", D-1 to D-13: the owner's delegation, rule used for
every choice: how macOS does it). Items 3 to 5 are **PROPOSED by the integrator, owner sign-off pending**: none of them is in
D-1 to D-13 (D-5 covers the acceptance of ADRs only), so they are not recorded as decided.

1. **ADR acceptance (D-5, decided).** All ADRs that were Proposed are Accepted on the owner's delegation; line 2 of each file
   says so and keeps the earlier status and every amendment. A later amendment still follows the usual rule: it is
   written at the end of the ADR with its date and decider.
2. **R3 and A1 (D-1 and D-7, decided; restated in docs/master-prompt.md section 10).**
   D-1: menu bar on every display, one Dock that follows the display whose bottom edge the pointer touches, a window
   restored from the Dock returns to the display and frame it was minimized from. D-7: keyboard access to Minimize,
   Zoom and Close through the Window menu for every window; Grassfield's own apps draw their controls; compositor-drawn
   controls of third-party windows are accepted given those equivalents.
3. **`docs/specs/alpha.md` waiver (PROPOSED, owner sign-off pending).** The M2 alpha acceptance list was replaced in
   practice by the per-surface specs in docs/specs/, their nested scenarios and the final audit (docs/audits/final-1.0/).
   Proposal: judge the 1.0 release candidate against those specs and the gate table, with no separate alpha list.
4. **M5 defect threshold, Q-18 (decided by the owner on 2026-10-27).** 0 blocker, 0 high-severity defect in security
   or data loss, and at most 5 other high-severity defects. (Same wording as master-prompt §1.1 and the M5 exit; it
   replaces the earlier proposal of zero open P0 and P1.)
5. **Milestone approvals (PROPOSED, owner sign-off pending).** M0 to M2 (with item 3), then M3 and M4 once the remediation
   programme (docs/audits/final-1.0/15-remediation-plan.md) closes and F1 is signed per surface; M5 and M6 keep the
   owner-only items (L2 gates, R2, R3, C1 7 days, 30-day dogfood, hardware matrix, legal review). No milestone is approved
   until the owner signs it off.

## Amendment 2026-10-23 (GF-040): resource guard of grassfield-shell.service
Measured: idle CPU 0.25 to 0.33 % of one core, RSS 530 MB growing about 6 MB/h (566 MB after 6 h), other real sessions up to
725 MB, one historical runaway of 118 % CPU and 9.5 GB (docs/audits/final-1.0/benchmarks/real-session-samples.md,
08-performance-audit.md PERF-04). The unit sets `MemoryHigh=1536M`, `MemoryMax=3G`, `CPUQuota=150%`: every limit is far
above any healthy figure (P2 stays 608 MB, a measured gate, not a limit) and below the runaway. Revisit when the long
nested slope test exists.

## Amendment 2026-10-24, integrator under owner delegation D-5 (P3 measurement window)
Owner rule: work as macOS does. What P3 judges is the smoothness of the animation itself: when nothing moves the screen is
static and owes no frames, so the sparse frames that arrive once an animation is over (a thumbnail refreshed, a late
repaint of the shell) are not misses. Measured on 2026-10-24 (nested run of part B): the Overview opened with no window was
95.7 % on time during its first 400 ms and 35.6 % after it; counted over a fixed 1.5 s after the request, the after-part
made it fail.

P3 is therefore measured per request over the animation's own window:
- start: the first frame presented after the request (the animation's first frame; the request's own latency, a process
  started by the harness and the shell's reaction, is printed, not judged);
- end: start + the animation's token duration (ui/tokens/tokens.json `motion.*`: Overview `motion.slow`, Launchpad
  `motion.normal`, Dock magnification the timed glide + `motion.fast`) + one refresh period; for the Overview, the plugin's
  end mark of the phase when later (its windows start moving once the chrome holds the keyboard; feature `frame-times`,
  marks `overview-open` / `overview-closed`).
- the tail, from the end to 1.5 s after the request, stays reported as information (its frames and its longest
  interval) and is attributed like the animation (`tests/visual/frame-attribution.py`), so a late stall stays visible; it
  never fails the gate.
Threshold unchanged: at least 95 % of the animation's frames within 1.2 refresh periods. Tools:
`tests/visual/presented-frames.sh`, `tests/visual/animation-windows.py`, `tests/visual/frame-stats.py`.

## Amendment 2026-11-19, integrator under owner delegation D-5 (P3: refresh-relative threshold, the presentation-time probe)
Owner rule: work as macOS does. A Mac with a 120 Hz ProMotion panel is judged against 120 Hz, not 60: an animation that
holds 60 fps there drops every second frame. The P3 line of the Decision table ("≥ 95 % frames < 16.7 ms") fixed the budget
of a 60 Hz output; on a 120, 144 or 240 Hz output a frame of 16 ms is one, two or three missed refreshes, and the old
threshold called it on time. Since 2026-10-23 the method was meant to be "`wp_presentation` timestamps from a probe client",
but the gate tool (`scripts/gates/frame-pacing.sh`) only had the shell's render-thread time, a proxy that could never pass.

Decision (replaces the P3 row of the table; the 2026-10-24 measurement-window amendment stands):
- **Threshold.** At least **95 %** of the frames presented during the animation's window arrive **within 1.2 refresh
  periods** of the previous one, the period being the output's own (the `refresh` of the presentation feedback, else the
  output's current mode): 20.0 ms at 60 Hz, 10.0 ms at 120 Hz, 8.3 ms at 144 Hz, 5.0 ms at 240 Hz. A missed frame shows as
  two periods. Balanced power profile, on the owner's real session (L2, †), the reference machine first and then each
  refresh rate of the hardware matrix. At least 100 frame intervals per surface, or the run is INCONCLUSIVE.
- **Reported with the verdict, not judged:** p50, p95 and p99 of the frame interval, the worst stall (ms and periods),
  the missed-frame count (the vblank counter's delta − 1 when the compositor reports it, else round(interval / period) − 1)
  and the discarded updates.
- **Method.** `tests/tools/presentprobe`: a Wayland client with a 1×1, almost transparent overlay layer surface (alpha
  1/255, empty input region, top-left corner of the output) that commits on every frame callback and records the
  `wp_presentation` feedback of every commit. A client only receives the feedback of its own surfaces; the compositor
  presents every surface of an output in the same frame, so a frame the shell's animation makes it miss is missed by the
  probe too. Because the probe damages its surface every frame, the compositor owes a frame at every refresh during the
  measurement: the window judged is the one of the 2026-10-24 amendment, approximated from the request (request + 250 ms for
  the `qs ipc` process and the shell's reaction + the animation's token duration + 100 ms of settle; the Dock: the sweep +
  `motion.fast`). The plugin's own presentation log (`tests/visual/presented-frames.sh`, feature `frame-times`) stays the
  attribution tool for the nested session.
- **The probe's own lateness is not the compositor's.** The probe records how late it handled each frame callback (against
  the callback's timestamp, the record's median lag as the compositor's convention). A late frame whose callback the probe
  handled more than max(2 ms, half a period) later than usual is left out and counted apart; when that is more than 5 % of
  the frames, the run is INCONCLUSIVE (a loaded machine: run again idle).
- **Verdicts.** Only the owner's real session can PASS (`just gate-frames --real`). The nested session gives "NESTED, NOT
  VERIFIED" or "NESTED FAIL (indicative)": its output is paced by the host compositor. The render-thread proxy
  (`--proxy`) stays as the fallback where the probe cannot run (no `wp_presentation` or layer-shell), never a PASS.

Consequences: the P3 row of docs/testing/gates.md and the gate tool say the same; `scripts/gates/frame_pacing.py` holds the
judge, tested offline on recorded probe runs at 60, 120, 144 and 240 Hz (tests/shell/frame_pacing_probe.sh,
tests/fixtures/frame-pacing/). Open: the owner's first real-session run on the reference machine (and on a high-refresh
display of the hardware matrix) gives the baseline the next milestone gate revisits.
