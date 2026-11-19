#!/usr/bin/env bash
# Gate P3 from presentation timestamps, offline (ADR-0006 as amended on 2026-11-19): the judge scripts/gates/frame_pacing.py
# on recorded probe runs, and the probe tests/tools/presentprobe itself (its build, its refusals and, when a weston is
# installed, a live run against a private headless weston). No session: never the owner's compositor.
#
# The records of tests/fixtures/frame-pacing/ are real runs of the probe (2026-11-19, the audit's Arch chroot, a loaded 4-core
# machine) against a headless Weston 15 (pixman, kiosk shell, --refresh-rate in mHz; Weston has no layer-shell, so the probe
# fell back to its toplevel):
#   weston-60.txt                   60 Hz, nothing done to it
#   weston-144.txt                  143.856 Hz (a 144 Hz panel's real mode), nothing done to it
#   weston-120-compositor-stops.*   120 Hz, the COMPOSITOR stopped (SIGSTOP) 40 ms about every 0.5 s; .marks: a 250 ms window
#                                   from 50 ms before each stop
#   weston-240-compositor-stops.txt 240 Hz, the compositor stopped 25 ms about every 0.5 s
#   weston-60-probe-stops.*         60 Hz, the PROBE stopped 50 ms about every 0.45 s: its own lateness, which the judge
#                                   must leave out (and call the run inconclusive when it is more than 5 % of the frames)
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fx=$root/tests/fixtures/frame-pacing
judge=$root/scripts/gates/frame_pacing.py
work=$(mktemp -d)
wpid=""
cleanup() { [[ -n $wpid ]] && kill "$wpid" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
fails=0
expect() { # <name> <got> <want>
  if [[ $2 == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}
# run <args...>: the judge's last line, and its exit code in $rc
run() { out=$(python3 -I "$judge" "$@" 2>&1); rc=$?; last=${out##*$'\n'}; }
has() { [[ $1 == *"$2"* ]] && echo yes || echo "no: $1"; }

python3 -I "$judge" --selftest || fails=$((fails + 1))

# The recorded runs, judged on the real session's terms (the only ones that can PASS).
run --presented "$fx/weston-60.txt" --surface w60 --session real
expect "60 Hz: PASS (exit 0)" "$rc" 0
expect "60 Hz: the period comes from the feedback" "$(has "$out" "refresh 60.00 Hz, period 16.667 ms from the presentation feedback")" yes
expect "60 Hz: 116 of 119 on time within 20 ms, nothing missed" "$(has "$last" "PASS: 116/119 frames on time (<= 1.2 periods = 20.00 ms) = 97.5 %")" yes
expect "60 Hz: the percentiles and the worst stall are printed" "$(has "$last" "p50 16.67 ms, p95 19.13 ms, p99 21.78 ms, worst stall 23.18 ms (1.4 periods), 0 missed")" yes
run --presented "$fx/weston-60.txt" --surface w60 --session nested
expect "60 Hz, nested: never a pass (exit 2, NOT VERIFIED)" "$rc:$(has "$last" "NESTED, NOT VERIFIED")" 2:yes

run --presented "$fx/weston-144.txt" --surface w144 --session real
expect "144 Hz: the real mode 143.86 Hz, named as 144" "$(has "$out" "refresh 143.86 Hz (~144 Hz), period 6.951 ms")" yes
expect "144 Hz: budget 8.34 ms; 89.7 % on time: FAIL" "$rc:$(has "$last" "244/272 frames on time (<= 1.2 periods = 8.34 ms) = 89.7 %")" 1:yes
expect "144 Hz: 18 missed, the probe's one late frame left out" "$(has "$last" "18 missed; 1 late frame of the probe's own left out")" yes

run --presented "$fx/weston-120-compositor-stops.txt" --surface w120 --session real
expect "120 Hz with compositor stops: FAIL" "$rc" 1
expect "120 Hz: the stops are the worst stall (84 ms, 10 periods) and 25 missed" "$(has "$last" "worst stall 84.32 ms (10.1 periods), 25 missed")" yes
expect "120 Hz: no frame is blamed on the probe" "$(has "$last" "late frame")" "no: $last"
run --presented "$fx/weston-120-compositor-stops.txt" --marks "$fx/weston-120-compositor-stops.marks" --surface w120 --session real --min-frames 10
expect "120 Hz, windows over the stops: per-label lines" "$(has "$out" "stall1 (2 windows): 24/30 frames on time")" yes
expect "120 Hz, windows over the stops: 36/47 = 76.6 %, 20 missed, FAIL" "$rc:$(has "$last" "36/47 frames on time (<= 1.2 periods = 10.00 ms) = 76.6 %")" 1:yes

run --presented "$fx/weston-240-compositor-stops.txt" --surface w240 --session real
expect "240 Hz with compositor stops: budget 5 ms, FAIL" "$rc:$(has "$last" "341/387 frames on time (<= 1.2 periods = 5.00 ms) = 88.1 %")" 1:yes
# The same record judged as if the output ran at 60 Hz passes: the budget follows the output's rate (the old fixed
# 16.7 ms threshold would have called this 240 Hz run smooth).
run --presented "$fx/weston-240-compositor-stops.txt" --surface w240 --session real --refresh-hz 60
expect "the 240 Hz record against a 60 Hz budget passes (the threshold is refresh-relative)" "$rc:$(has "$last" "393/397")" 0:yes

run --presented "$fx/weston-60-probe-stops.txt" --surface probe --session real
expect "probe stops: its 3 late frames are left out, not counted as misses" "$rc:$(has "$last" "0 missed; 3 late frames of the probe's own left out")" 0:yes
run --presented "$fx/weston-60-probe-stops.txt" --marks "$fx/weston-60-probe-stops.marks" --surface probe --session real --min-frames 10
expect "probe stops in the windows: the probe was late on 3 of 32: INCONCLUSIVE" "$rc:$(has "$last" "INCONCLUSIVE: the probe itself was late on 3 of 32 frames")" 2:yes

# Usage and unreadable input: never a pass.
run --presented "$work/none.txt" --surface x --session real
expect "an unreadable record: exit 2" "$rc" 2
printf '# presentprobe 1\n' >"$work/empty.txt"
run --presented "$work/empty.txt" --surface x --session real
expect "a record without frames: INCONCLUSIVE" "$rc:$(has "$last" "INCONCLUSIVE")" 2:yes

# The probe: it builds with -Werror against this machine's protocols, refuses the owner's socket, and measures a real compositor.
if command -v wayland-scanner >/dev/null && pkg-config --exists wayland-client wayland-protocols 2>/dev/null && command -v "${CC:-cc}" >/dev/null; then
  bin=$("$root/tests/tools/presentprobe/build.sh" "$work/tools" 2>"$work/build.err")
  expect "the probe builds (-Wall -Wextra -Werror)" "$([[ -x $bin ]] && echo yes || cat "$work/build.err")" yes
  if [[ -x $bin ]]; then
    expect "no WAYLAND_DISPLAY: exit 2" "$(env -u WAYLAND_DISPLAY "$bin" --seconds 1 >/dev/null 2>&1; echo $?)" 2
    expect "the owner's socket without --real: refused (exit 2) before any connection" \
      "$(XDG_RUNTIME_DIR=$work WAYLAND_DISPLAY=wayland-1 "$bin" --seconds 1 2>&1 >/dev/null; echo "rc $?")" \
      "presentprobe: refusing the owner's Wayland socket (wayland-1) without --real"$'\n'"rc 2"
    expect "a bad argument: exit 2" "$(WAYLAND_DISPLAY=none "$bin" --size 0 >/dev/null 2>&1; echo $?)" 2
    expect "no compositor on the socket: exit 1" "$(XDG_RUNTIME_DIR=$work WAYLAND_DISPLAY=gf-none "$bin" --seconds 1 >/dev/null 2>&1; echo $?)" 1
    # Live, when a weston is installed: a private headless weston at 120 Hz in this test's own runtime directory.
    if command -v weston >/dev/null; then
      mkdir -m 700 "$work/rt"
      XDG_RUNTIME_DIR=$work/rt weston --no-config -B headless --renderer=pixman --shell=kiosk --refresh-rate=120000 -S gf-probe-test \
        --log="$work/weston.log" >/dev/null 2>&1 &
      wpid=$!
      for _ in $(seq 1 50); do [[ -S $work/rt/gf-probe-test ]] && break; sleep 0.1; done
      if [[ -S $work/rt/gf-probe-test ]]; then
        XDG_RUNTIME_DIR=$work/rt WAYLAND_DISPLAY=gf-probe-test "$bin" --seconds 1.5 >"$work/live.txt" 2>"$work/live.err"
        expect "live: the probe ends cleanly" "$?" 0
        expect "live: the presentation clock and the output are recorded" \
          "$(grep -c -E '^# (clock|offset_ns|output headless 120000 )' "$work/live.txt")" 3
        expect "live: more than 100 frames presented in 1.5 s at 120 Hz" "$(awk '$1 == "p" { n++ } END { print (n > 100) ? "yes" : n }' "$work/live.txt")" yes
        run --presented "$work/live.txt" --surface live --session nested --min-frames 50
        expect "live: judged against 120 Hz from the feedback" "$(has "$out" "refresh 120.00 Hz, period 8.333 ms from the presentation feedback")" yes
        expect "live: a nested-terms verdict, never a pass" "$([[ $rc == 1 || $rc == 2 ]] && echo yes || echo "$rc")" yes
        # The harness's --real path end to end on this private weston: the probe started and stopped around the requests, one
        # mark per request, the shell's IPC called (a stub qs: no shell here), the record judged on the real session's terms.
        mkdir -p "$work/stub"
        printf '#!/bin/sh\necho "$*" >>"%s/ipc.log"\n' "$work" >"$work/stub/qs"
        printf '#!/bin/sh\necho %s\n' "$$" >"$work/stub/systemctl"
        printf '#!/bin/sh\necho balanced\n' >"$work/stub/powerprofilesctl"
        chmod +x "$work/stub/qs" "$work/stub/systemctl" "$work/stub/powerprofilesctl"
        harness=$(PATH=$work/stub:$PATH XDG_RUNTIME_DIR=$work/rt WAYLAND_DISPLAY=gf-probe-test "$root/scripts/gates/frame-pacing.sh" --real --out "$work/fp" overview 2 2>&1)
        hrc=$?
        expect "harness --real: the power profile is printed" "$(has "$harness" "P3 (real): power profile: balanced")" yes
        expect "harness --real: the Overview opened and closed twice through the shell's IPC" \
          "$(tr '\n' ';' <"$work/ipc.log")" "ipc --pid $$ call overview open;ipc --pid $$ call overview close;ipc --pid $$ call overview open;ipc --pid $$ call overview close;"
        rec=$(sed -n 's/^P3: records in \(.*\) (\*\.\(.*\)\.\*)$/\1\/overview.\2/p' <<<"$harness")
        win=$((250 + $(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["motion"]["slow"]["value"])' "$root/ui/tokens/tokens.json") + 100))
        expect "harness --real: four marks, each the Overview's window (250 ms + motion.slow + 100 ms = $win ms)" \
          "$(awk '{ print $1, $3 }' "$rec.marks" 2>/dev/null | tr '\n' ';')" "open $win;close $win;open $win;close $win;"
        expect "harness --real: the probe's record ends cleanly (SIGINT)" "$(grep -c '^# end presented' "$rec.presented" 2>/dev/null)" 1
        expect "harness --real: a verdict on the real session's terms" "$(has "$harness" "P3 overview (n=2) [real, wp_presentation]: ")" yes
        expect "harness --real: its exit code is the verdict's" "$hrc" "$(python3 -I "$judge" --presented "$rec.presented" --marks "$rec.marks" --surface x --session real >/dev/null; echo $?)"
      else
        echo "  SKIP live probe run (the headless weston did not start: $(tail -n 3 "$work/weston.log" 2>/dev/null | tr '\n' ' '))"
      fi
      kill "$wpid" 2>/dev/null
      wait "$wpid" 2>/dev/null
      wpid=""
    else
      echo "  SKIP live probe run (no weston installed: pacman -S weston runs it against a private headless compositor)"
    fi
  fi
else
  echo "  SKIP the probe's build (wayland-scanner, wayland-protocols or a C compiler missing)"
fi

if ((fails == 0)); then echo "PASS frame_pacing_probe"; else echo "FAIL frame_pacing_probe: $fails"; exit 1; fi
