#!/usr/bin/env bash
# Gate P3: frame pacing while the Dock magnifies and the Overview and Apps open and close (ADR-0006 as amended on 2026-11-19:
# at least 95 % of the frames within 1.2 refresh periods of the previous one, the output's own rate, Balanced profile).
#
#   scripts/gates/frame-pacing.sh [--nested | --real | --proxy] [--output NAME] [--out DIR] [dock|overview|apps|all] [N]
#     N = repetitions, default 20 (the gate's count)
#     --nested  (default) this tree's NESTED session, started or reused through tests/visual/lib.sh: the Dock swept N times
#               by the scripted pointer (magnification on), the Overview and Apps opened and closed N times through the dev
#               IPC. Judged on nested terms: "NESTED, NOT VERIFIED" (exit 2) or "NESTED FAIL" (exit 1, indicative); the
#               nested output is paced by its host compositor, so it is never a PASS.
#     --real    the owner's REAL session (this terminal's WAYLAND_DISPLAY; run by the owner, bare). The Overview and Apps
#               are opened and closed N times through the running grassfield-shell's IPC (`qs ipc --pid`), on the focused
#               display; the Dock is swept BY HAND for 10 s when the script asks (Dock magnification on in Settings). The
#               only mode that can PASS (exit 0).
#     --proxy   the former L1 proxy, kept as the fallback where the probe cannot run: the nested shell's render-thread time
#               (GRASSFIELD_RENDER_TIMING=1, "frame rendered in R ms" lines of .dev/shell.log), never a PASS. --nested falls
#               back to it by itself when the probe cannot be built or the compositor lacks wp_presentation.
#     --output  the output the probe's surface goes on (wl_output name; nested default GF-REF, real default the focused one)
#     --out DIR where the records go (default .dev/gates/frame-pacing; the probe is built into DIR/tools then, else .dev/tools)
#
# The probe (tests/tools/presentprobe, built into .dev/tools/) is a 1x1, almost transparent overlay layer surface with an
# empty input region that commits on every frame callback and records the wp_presentation feedback of every commit: when it
# reached the screen, the refresh period, the vblank counter. The compositor presents every surface of an output in the same
# frame, so a frame the shell's animation makes it miss is missed by the probe too. The harness marks each request
# ("<label> <realtime_ns> <window_ms>"); scripts/gates/frame_pacing.py judges the frames in each window against the
# output's own refresh rate (60, 120, 144, 240 Hz ...) and prints the share on time, p50/p95/p99, the worst stall and the
# missed frames. Windows: from the request to the request + 250 ms (the qs ipc process and the shell's reaction) + the
# animation's token duration (ui/tokens/tokens.json: Overview motion.slow, Apps motion.normal) + 100 ms of settle; the Dock:
# its whole sweep + motion.fast.
# The power profile in force is printed (powerprofilesctl get); the gate asks for Balanced, the script does not change it.
# Output: .dev/gates/frame-pacing/<surface>.<timestamp>.{presented,presented.err,marks} (or .log for the proxy).
# Exit: 0 PASS (--real only), 1 any FAIL (indicative in nested and proxy modes), 2 otherwise (not verified, too few frames,
# the probe itself too late, an environment error).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel) || exit 2

mode=nested output="" what="" n="" out=$root/.dev/gates/frame-pacing tools=$root/.dev/tools
while (($#)); do
  case $1 in
    --nested) mode=nested ;;
    --real) mode=real ;;
    --proxy) mode=proxy ;;
    --output) [[ -n ${2:-} ]] || { echo "frame-pacing: --output needs a name" >&2; exit 2; }; output=$2; shift ;;
    --out) [[ -n ${2:-} ]] || { echo "frame-pacing: --out needs a directory" >&2; exit 2; }; out=$2 tools=$2/tools; shift ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "frame-pacing: unknown option $1 (--help)" >&2; exit 2 ;;
    *) if [[ -z $what ]]; then what=$1; elif [[ -z $n ]]; then n=$1; else echo "frame-pacing: too many arguments" >&2; exit 2; fi ;;
  esac
  shift
done
what=${what:-all}
n=${n:-20}
[[ $what == dock || $what == overview || $what == apps || $what == all ]] || { echo "usage: frame-pacing.sh [--nested|--real|--proxy] [--output NAME] [--out DIR] [dock|overview|apps|all] [N]" >&2; exit 2; }
[[ $n =~ ^[1-9][0-9]*$ ]] || { echo "frame-pacing: N is a positive integer" >&2; exit 2; }
mkdir -p "$out" || exit 2
stamp=$(date +%Y%m%d-%H%M%S)
judge=$root/scripts/gates/frame_pacing.py

rc=0
worst() { (($1 == 1)) && rc=1; (($1 == 2 && rc == 0)) && rc=2; return 0; }
tok() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["motion"][sys.argv[2]]["value"])' "$root/ui/tokens/tokens.json" "$1"; }
request_ms=250 settle_ms=100
overview_ms=$((request_ms + $(tok slow) + settle_ms))
apps_ms=$((request_ms + $(tok normal) + settle_ms))
fast_ms=$(tok fast)
now_ns() { date +%s%N; }
mark() { echo "$1 $(now_ns) $2" >>"$marks"; } # <label> <window_ms>

echo "P3 ($mode): power profile: $(powerprofilesctl get 2>/dev/null || echo 'unknown (powerprofilesctl not available)'); commit $(git -C "$root" rev-parse --short HEAD)"

# --- the probe ---------------------------------------------------------------------------------------------------------------
probe_bin=""
if [[ $mode != proxy ]]; then
  if ! probe_bin=$("$root/tests/tools/presentprobe/build.sh" "$tools" 2>"$out/build.$stamp.err"); then
    if [[ $mode == real ]]; then
      echo "P3: INCONCLUSIVE: the probe did not build ($(tail -n 1 "$out/build.$stamp.err")): wayland-scanner, wayland-protocols, a C compiler"
      exit 2
    fi
    echo "P3: the probe did not build ($(tail -n 1 "$out/build.$stamp.err")): falling back to the render-thread proxy"
    exec "$0" --proxy --out "$out" "$what" "$n"
  fi
fi
probe_pid=""
probe_real="" # --real: the probe may connect to the owner's own socket (it refuses wayland-1 otherwise)
[[ $mode == real ]] && probe_real=1
stop_probe() { if [[ -n $probe_pid ]]; then kill -INT "$probe_pid" 2>/dev/null; wait "$probe_pid" 2>/dev/null || true; fi; probe_pid=""; }
trap stop_probe EXIT
# start_probe <record> <command prefix...>: starts the probe, waits for its first presented frame (5 s). 1 when it ended or
# never presented (the reason is in <record>.err).
start_probe() {
  local rec=$1 i
  shift
  "$@" "$probe_bin" --seconds 0 ${output:+--output "$output"} ${probe_real:+--real} >"$rec" 2>"$rec.err" &
  probe_pid=$!
  for i in $(seq 1 50); do
    grep -q '^p ' "$rec" 2>/dev/null && return 0
    kill -0 "$probe_pid" 2>/dev/null || break
    sleep 0.1
  done
  stop_probe
  return 1
}
judge_surface() { # <surface> <session>
  python3 -I "$judge" --presented "$out/$1.$stamp.presented" --marks "$out/$1.$stamp.marks" --surface "$1 (n=$n)" --session "$2"
}

# --- the owner's real session ------------------------------------------------------------------------------------------------
if [[ $mode == real ]]; then
  [[ -n ${WAYLAND_DISPLAY:-} ]] || { echo "P3: INCONCLUSIVE: no WAYLAND_DISPLAY (run --real in a terminal of the Grassfield session)"; exit 2; }
  pid=$(systemctl --user show -p MainPID --value grassfield-shell.service 2>/dev/null)
  [[ $pid =~ ^[1-9][0-9]*$ ]] || pid=$(pgrep -u "$(id -u)" -f -- '^/usr/bin/qs -n -p /usr/share/grassfield/shell$' 2>/dev/null | head -n 1)
  [[ $pid =~ ^[1-9][0-9]*$ ]] || { echo "P3: INCONCLUSIVE: no running grassfield-shell (grassfield-shell.service MainPID)"; exit 2; }
  ipc() { qs ipc --pid "$pid" call "$@" >/dev/null; }
  echo "P3: the real session ($WAYLAND_DISPLAY, grassfield-shell pid $pid), $what: the Overview and Apps open and close $n times each through the IPC; keep the pointer and keyboard still until asked"
  real_surface() { # <surface> <function>
    local rec=$out/$1.$stamp.presented
    marks=$out/$1.$stamp.marks
    : >"$marks"
    if ! start_probe "$rec" env; then
      echo "P3 $1: INCONCLUSIVE: the probe could not measure ($(tail -n 1 "$rec.err" 2>/dev/null)): the compositor needs wp_presentation and wlr-layer-shell"
      worst 2
      return
    fi
    "$2"
    sleep 0.3
    stop_probe
    judge_surface "$1" real || worst $?
  }
  overview_real() { local i; for i in $(seq 1 "$n"); do mark open "$overview_ms"; ipc overview open; sleep 1.2; mark close "$overview_ms"; ipc overview close; sleep 1; done; }
  apps_real() { local i; for i in $(seq 1 "$n"); do mark open "$apps_ms"; ipc apps open; sleep 1.2; mark close "$apps_ms"; ipc apps close; sleep 1; done; }
  dock_real() {
    local i
    echo "P3 dock: with Dock magnification on, sweep the pointer slowly along the Dock and back, for 10 s from GO"
    for i in 3 2 1; do echo "  $i"; sleep 1; done
    echo "  GO"
    mark sweep 10000
    sleep 10
    echo "  stop"
  }
  if [[ $what == overview || $what == all ]]; then real_surface overview overview_real; fi
  if [[ $what == apps || $what == all ]]; then real_surface apps apps_real; fi
  if [[ $what == dock || $what == all ]]; then real_surface dock dock_real; fi
  echo "P3: records in $out (*.$stamp.*)"
  exit "$rc"
fi

# --- the nested session (the probe, or the proxy) ----------------------------------------------------------------------------
source "$root/tests/visual/lib.sh"
[[ $mode == proxy ]] && export GRASSFIELD_RENDER_TIMING=1
vs_session en
vs_reset dark 0.25
vs_ipc controlcenter reduceMotion false >/dev/null
output=${output:-$VS_OUTPUT}

dock_once() {
  local args=() x t0
  for x in $(seq 700 20 1220); do args+=(abs "$x" 1045 sleep 30); done
  t0=$(now_ns)
  vs_pointer "${args[@]}" >/dev/null
  # The sweep's own length (the pointer tool's pace) + the Dock's settle: the window starts at the sweep's start.
  [[ -n ${marks:-} ]] && echo "sweep $t0 $((($(now_ns) - t0) / 1000000 + fast_ms))" >>"$marks"
  vs_pointer abs 960 600 sleep 400 >/dev/null
}
overview_once() {
  [[ -n ${marks:-} ]] && mark open "$overview_ms"
  vs_ipc overview open >/dev/null; vs_sleep 1.2
  [[ -n ${marks:-} ]] && mark close "$overview_ms"
  vs_ipc overview close >/dev/null; vs_sleep 1
}
apps_once() {
  [[ -n ${marks:-} ]] && mark open "$apps_ms"
  vs_ipc apps open >/dev/null; vs_sleep 1.2
  [[ -n ${marks:-} ]] && mark close "$apps_ms"
  vs_ipc apps close >/dev/null; vs_sleep 1
}

run_surface() { # <surface> <function exercising it once>
  local surface=$1 fn=$2 m0 i rec
  if [[ $mode == proxy ]]; then
    marks=""
    m0=$(wc -l <"$VS_DEV/shell.log")
    for i in $(seq 1 "$n"); do "$fn"; done
    tail -n +"$((m0 + 1))" "$VS_DEV/shell.log" >"$out/$surface.$stamp.log"
    python3 -I "$judge" --surface "$surface (n=$n)" "$out/$surface.$stamp.log"
    return
  fi
  rec=$out/$surface.$stamp.presented
  marks=$out/$surface.$stamp.marks
  : >"$marks"
  # Like vs_spawn (the nested socket only, an isolated environment) but with the output kept.
  if ! start_probe "$rec" "$VS_ROOT/scripts/dev/isolated.sh" --name presentprobe -- env WAYLAND_DISPLAY="$(vs_nested_wayland)"; then
    echo "P3 $surface: the probe could not measure ($(tail -n 1 "$rec.err" 2>/dev/null)); this surface falls back to the proxy: scripts/gates/frame-pacing.sh --proxy $surface $n"
    return 2
  fi
  vs_track "$probe_pid"
  for i in $(seq 1 "$n"); do "$fn"; done
  sleep 0.3
  stop_probe
  judge_surface "$surface" nested
}

vs_ipc dock magnify 1.6 true >/dev/null
vs_park
vs_sleep 1.5
if [[ $what == dock || $what == all ]]; then run_surface dock dock_once || worst $?; fi
if [[ $what == overview || $what == all ]]; then run_surface overview overview_once || worst $?; fi
if [[ $what == apps || $what == all ]]; then run_surface apps apps_once || worst $?; fi
vs_park
echo "P3: records in $out (*.$stamp.*)"
exit "$rc"
