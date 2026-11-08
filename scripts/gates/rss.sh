#!/usr/bin/env bash
# Gate P2: resident memory of grassfield-shell against the omarchy-shell baseline: PASS when the RSS of the measured
# processes is at most <baseline> + 150 MB (master-prompt §10 P2; MB = 1000 kB, the unit of ADR-0006: 458 824 kB = 458 MB). RSS is VmRSS of /proc/<pid>/status; PSS from
# smaps_rollup is reported too when readable. Read-only.
#
#   scripts/gates/rss.sh [--nested | --real | --pid PID[=label]]... [options]
#     --nested | --real | --pid   as in idle-cpu.sh (the shell only counts for the verdict: processes named
#                      grassfield-menu-bridge are listed but not summed, P2 is "grassfield-shell RSS"; since ADR-0041
#                      step 1, S1 the security process counts with it: --nested measures this tree's .dev/security.pid
#                      too, summed with the shell, and --pid takes it as one more process)
#     --baseline-pid PID   the omarchy-shell process (e.g. `pgrep -f 'quickshell.*omarchy/shell' | head -1` in the
#                          Omarchy session), measured now
#     --baseline-mb N      a baseline measured earlier in the Omarchy session (MB of RSS)
#     --max-delta-mb N     allowed excess, default 150
#     --samples N --interval S   N samples S seconds apart (default 1); the verdict uses the LAST sample, the line
#                          reports min / mean / max (use after hovering the Dock, one menu, one Overview, 10 min idle:
#                          docs/audits/final-1.0/15-remediation-plan.md L2-2)
# Without a baseline the numbers are printed and the verdict is INCONCLUSIVE (exit 2): a size alone proves nothing.
# Exit: 0 PASS, 1 FAIL, 2 INCONCLUSIVE or usage error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# shellcheck source=lib.sh
. "$root/scripts/gates/lib.sh"

delta=150 samples=1 interval=10 baseline_mb="" baseline_pid="" nested=0 real=0
pids=() labels=()
while (($#)); do
  case $1 in
    --nested) nested=1 ;;
    --real) real=1 ;;
    --pid) shift; pids+=("${1%%=*}"); labels+=("${1#*=}"); [[ $1 == *=* ]] || labels[-1]="" ;;
    --baseline-pid) shift; baseline_pid=$1 ;;
    --baseline-mb) shift; baseline_mb=$1 ;;
    --max-delta-mb) shift; delta=$1 ;;
    --samples) shift; samples=$1 ;;
    --interval) shift; interval=$1 ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "rss: unknown argument $1 (--help)" >&2; exit 2 ;;
  esac
  shift
done
[[ $samples =~ ^[1-9][0-9]*$ && $interval =~ ^[1-9][0-9]*$ ]] || { echo "rss: --samples and --interval are positive integers" >&2; exit 2; }
if ((nested)); then
  # shellcheck source=../dev/pidfile.sh
  . "$root/scripts/dev/pidfile.sh"
  for rec in shell:grassfield-shell menu-bridge:grassfield-menu-bridge; do
    if p=$(dev_live_pid "$root/.dev/${rec%%:*}.pid"); then pids+=("$p"); labels+=("${rec#*:} (nested)"); else echo "rss: no live ${rec#*:} of this tree's nested session" >&2; exit 2; fi
  done
  # The security process (ADR-0041 S2: the lock, idle and the sleep inhibitor; scripts/dev/shell-run.sh starts it): P2
  # counts both Quickshell processes.
  if p=$(dev_live_pid "$root/.dev/security.pid"); then pids+=("$p"); labels+=("grassfield-security (nested)"); else echo "rss: no live grassfield-security of this tree's nested session (P2 counts both processes)" >&2; exit 2; fi
fi
if ((real)); then
  while read -r p; do [[ -n $p ]] && { pids+=("$p"); labels+=("grassfield-shell (real session)"); }; done < <(gate_find 'qs -n -c grassfield')
  while read -r p; do [[ -n $p ]] && { pids+=("$p"); labels+=("grassfield-menu-bridge (real session)"); }; done < <(pgrep -u "$(id -u)" -x grassfield-menu-bridge 2>/dev/null)
  ((${#pids[@]} > 0)) || { echo "rss: no grassfield-shell found in this user's processes (run as a bare command)" >&2; exit 2; }
fi
((${#pids[@]} > 0)) || { echo "rss: nothing to measure (--nested, --real or --pid)" >&2; exit 2; }

pss_mb() { awk '/^Pss:/ {printf "%.1f", $2 / 1000}' "/proc/$1/smaps_rollup" 2>/dev/null; }
declare -A lo=() hi=() sum=() cur=()
for ((n = 1; n <= samples; n++)); do
  ((n > 1)) && sleep "$interval"
  for p in "${pids[@]}"; do
    r=$(gate_rss_kb "$p")
    [[ $r =~ ^[0-9]+$ ]] || { echo "rss: process $p vanished during the measurement" >&2; exit 1; }
    cur[$p]=$r
    sum[$p]=$((${sum[$p]:-0} + r))
    if [[ -z ${lo[$p]:-} ]] || ((r < lo[$p])); then lo[$p]=$r; fi
    if ((r > ${hi[$p]:-0})); then hi[$p]=$r; fi
  done
done
ours_kb=0
for i in "${!pids[@]}"; do
  p=${pids[$i]}
  name=${labels[$i]:-$(gate_comm "$p")}
  mean=$((sum[$p] / samples))
  pss=$(pss_mb "$p")
  printf 'P2: %s (pid %s): RSS %d MB now (min %d, mean %d, max %d MB over %d sample(s))%s\n' "$name" "$p" $((cur[$p] / 1000)) $((lo[$p] / 1000)) $((mean / 1000)) $((hi[$p] / 1000)) "$samples" "${pss:+, PSS $pss MB}"
  [[ $name == *menu-bridge* ]] || ours_kb=$((ours_kb + cur[$p]))
done
ours_mb=$((ours_kb / 1000))
base_mb=""
if [[ -n $baseline_pid ]]; then
  b=$(gate_rss_kb "$baseline_pid")
  [[ $b =~ ^[0-9]+$ ]] || { echo "P2: baseline process $baseline_pid is not readable: INCONCLUSIVE" >&2; exit 2; }
  base_mb=$((b / 1000))
  echo "P2: baseline $(gate_comm "$baseline_pid") (pid $baseline_pid): RSS $base_mb MB"
elif [[ -n $baseline_mb ]]; then
  base_mb=$baseline_mb
fi
if [[ -z $base_mb ]]; then
  echo "P2: INCONCLUSIVE: grassfield-shell RSS $ours_mb MB, no baseline (--baseline-pid or --baseline-mb: measure the omarchy-shell in the Omarchy session)"
  exit 2
fi
bound=$((base_mb + delta))
if ((ours_mb <= bound)); then
  echo "P2: PASS: grassfield-shell RSS $ours_mb MB <= $bound MB (baseline $base_mb + $delta), $samples sample(s)"
  exit 0
fi
echo "P2: FAIL: grassfield-shell RSS $ours_mb MB > $bound MB (baseline $base_mb + $delta), $samples sample(s)"
exit 1
