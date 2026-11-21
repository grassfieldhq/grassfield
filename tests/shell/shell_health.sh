#!/usr/bin/env bash
# The shell's health sample and its after-SIGKILL line (owner's report of 2026-11-21: two SIGKILLs with nothing naming the
# sender). shell/services/process-health.sh against a fixture /proc (GRASSFIELD_PROC_ROOT, a dev seam): memory, the threads
# under a realtime policy (a thread name with spaces and parentheses included) and RLIMIT_RTTIME; against the real /proc of
# this shell; refused without a numeric pid. shell/services/shell-stopped.sh (the unit's ExecStopPost): one line with the
# last sample after a SIGKILL, nothing after any other end; the unit runs it. PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # <description> <command...>
  local desc=$1
  shift
  if "$@"; then echo "PASS: shell health: $desc"; else echo "FAIL: shell health: $desc"; fail=1; fi
}
probe=shell/services/process-health.sh
stopped=shell/services/shell-stopped.sh

# A fixture process 4242: two ordinary threads, a SCHED_FIFO one (policy 1, priority 83) and a SCHED_RR one whose name holds
# spaces and parentheses.
p=$tmp/proc/4242
mkdir -p "$p/task/1" "$p/task/2" "$p/task/3" "$p/task/4"
printf 'Name:\tqs\nThreads:\t4\nVmHWM:\t 1363148 kB\nVmRSS:\t  905216 kB\nRssAnon:\t  640000 kB\nRssFile:\t  200000 kB\nRssShmem:\t   65216 kB\n' >"$p/status"
printf 'Rss:              905216 kB\nPss:              880000 kB\n' >"$p/smaps_rollup"
printf 'Limit                     Soft Limit           Hard Limit           Units     \nMax realtime timeout      200000               200000               us        \n' >"$p/limits"
echo "0::/user.slice/user-1000.slice/user@1000.service/session.slice/grassfield-shell.service" >"$p/cgroup"
c=$tmp/cg/user.slice/user-1000.slice/user@1000.service/session.slice/grassfield-shell.service
mkdir -p "$c"
echo 1288491008 >"$c/memory.current"
echo 1395864371 >"$c/memory.peak"
printf 'anon 716800000\nfile 153600000\nkernel 28971008\nshmem 389120000\n' >"$c/memory.stat"
stat() { # <tid> <comm> <rt_priority> <policy>: a stat line with 52 fields
  local f=() i
  for ((i = 3; i <= 52; i++)); do f+=(0); done
  f[0]=S
  f[37]=$3
  f[38]=$4
  echo "$1 ($2) ${f[*]}"
}
stat 1 qs 0 0 >"$p/task/1/stat"; echo qs >"$p/task/1/comm"
stat 2 "QSGRenderThread" 0 0 >"$p/task/2/stat"; echo QSGRenderThread >"$p/task/2/comm"
stat 3 data-loop.0 83 1 >"$p/task/3/stat"; echo data-loop.0 >"$p/task/3/comm"
stat 4 "a (b) c" 5 2 >"$p/task/4/stat"; echo "a (b) c" >"$p/task/4/comm"
out=$(GRASSFIELD_DEV=1 GRASSFIELD_SESSION= GRASSFIELD_PROC_ROOT="$tmp/proc" GRASSFIELD_CGROUP_ROOT="$tmp/cg" sh "$probe" 4242)
want="Threads=4 VmHWM=1363148 VmRSS=905216 RssAnon=640000 RssFile=200000 RssShmem=65216 Pss=880000 RtTimeSoft=200000 RtTimeHard=200000 CgCurrent=1258292 CgPeak=1363148 CgAnon=700000 CgFile=150000 CgShmem=380000 CgKernel=28292 Rt=data-loop.0:1:83,a__b__c:2:5"
check "the fixture's memory, realtime threads and realtime CPU limit ($out)" test "$out" = "$want"
out=$(GRASSFIELD_DEV= GRASSFIELD_SESSION=1 GRASSFIELD_PROC_ROOT="$tmp/proc" sh "$probe" 4242 || true)
check "the /proc seam is ignored outside a dev session" test -z "$out"
out=$(sh "$probe" $$)
check "the real /proc of this shell ($out)" bash -c '[[ $1 =~ ^VmHWM=[0-9]+\ VmRSS=[0-9]+\ .*Threads=[0-9]+\ .*Rt=none$ ]]' _ "$out"
check "refused without a numeric pid" bash -c '! sh "$1" "1;id" && ! sh "$1" ""' _ "$probe"

# The ExecStopPost line.
mkdir -m 700 "$tmp/run"
printf 'at=%s periodic: rss 884 MB, realtime threads data-loop.0 (FIFO 83)\n' "$(($(date +%s) - 3))" >"$tmp/run/grassfield-shell-health"
out=$(XDG_RUNTIME_DIR=$tmp/run EXIT_CODE=killed EXIT_STATUS=KILL SERVICE_RESULT=signal sh "$stopped")
check "after a SIGKILL: the last sample and its age ($out)" bash -c '[[ $1 =~ ^grassfield-shell:\ the\ shell\ was\ killed\ by\ SIGKILL\ \(result\ signal\)\;\ its\ last\ health\ sample,\ [34]\ s\ before:\ periodic:\ rss\ 884\ MB ]]' _ "$out"
for end in "exited 0 x" "killed TERM signal" "exited 255 exit-code" "killed SEGV core-dump"; do
  read -r code status result <<<"$end"
  out=$(XDG_RUNTIME_DIR=$tmp/run EXIT_CODE=$code EXIT_STATUS=$status SERVICE_RESULT=$result sh "$stopped")
  check "nothing after $code/$status" test -z "$out"
done
rm "$tmp/run/grassfield-shell-health"
out=$(XDG_RUNTIME_DIR=$tmp/run EXIT_CODE=killed EXIT_STATUS=KILL SERVICE_RESULT=signal sh "$stopped")
check "after a SIGKILL without a sample ($out)" test "$out" = "grassfield-shell: the shell was killed by SIGKILL (result signal); no health sample was written"
check "the unit runs it after every end" grep -qx 'ExecStopPost=-/bin/sh /usr/share/grassfield/shell/services/shell-stopped.sh' packaging/systemd/grassfield-shell.service
exit "$fail"
