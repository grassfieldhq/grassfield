#!/bin/sh
# process-health.sh <pid>: one line of key=value pairs about process <pid> (the shell's own qs; ShellHealth.qml runs it, never
# through a shell string: the pid is its one argument). Read-only, /proc only:
#   VmRSS VmHWM RssAnon RssFile RssShmem (kB) Threads   from /proc/<pid>/status
#   Pss (kB)                                           from /proc/<pid>/smaps_rollup
#   RtTimeSoft RtTimeHard (us or "unlimited")           RLIMIT_RTTIME, from /proc/<pid>/limits
#   CgCurrent CgPeak CgAnon CgFile CgShmem CgKernel (kB) the unit's cgroup (below)
#   Rt                                                  the threads under a realtime policy (SCHED_FIFO 1, SCHED_RR 2,
#                                                       SCHED_DEADLINE 6): name:policy:priority,... or "none"
# Owner's report of 2026-11-21: the shell was killed by SIGKILL twice with nothing in the journal saying who. A thread under a
# realtime policy with RLIMIT_RTTIME set (PipeWire's module-rt through RTKit sets 200 ms) is killed by the kernel itself,
# silently, with the whole process, when it runs that long without sleeping: this line says whether the shell has one.
pid=$1
case $pid in '' | *[!0-9]*) exit 2 ;; esac
# GRASSFIELD_PROC_ROOT: a test seam (tests/shell/shell_health.sh reads a fixture tree), honoured only in a dev session
# (GRASSFIELD_DEV exactly "1", GRASSFIELD_SESSION not "1"); /proc otherwise.
proc=/proc
if [ "${GRASSFIELD_DEV:-}" = 1 ] && [ "${GRASSFIELD_SESSION:-}" != 1 ] && [ -n "${GRASSFIELD_PROC_ROOT:-}" ]; then
  proc=$GRASSFIELD_PROC_ROOT
fi
d=$proc/$pid
[ -r "$d/status" ] || exit 1
awk '$1 ~ /^(VmRSS|VmHWM|RssAnon|RssFile|RssShmem|Threads):$/ { sub(/:$/, "", $1); printf "%s=%s ", $1, $2 }' "$d/status"
awk '$1 == "Pss:" { printf "Pss=%s ", $2 }' "$d/smaps_rollup" 2>/dev/null
awk '/^Max realtime timeout/ { printf "RtTimeSoft=%s RtTimeHard=%s ", $4, $5 }' "$d/limits" 2>/dev/null
# The unit's cgroup (what systemd's "memory peak" counts: every process of the unit, page cache, shared memory and the GPU
# buffers the driver keeps in shared memory, which the process's RSS does not show), in kB: CgCurrent CgPeak CgAnon CgFile
# CgShmem CgKernel.
cg=$(sed -n 's/^0:://p' "$d/cgroup" 2>/dev/null | head -n 1)
case $cg in
  /*[!A-Za-z0-9@._/:\-]* | '') ;;
  /*)
    c=${GRASSFIELD_CGROUP_ROOT:-/sys/fs/cgroup}$cg
    [ "$proc" = /proc ] && c=/sys/fs/cgroup$cg
    awk '{ printf "CgCurrent=%d ", $1 / 1024 }' "$c/memory.current" 2>/dev/null
    awk '{ printf "CgPeak=%d ", $1 / 1024 }' "$c/memory.peak" 2>/dev/null
    awk '$1 == "anon" { a = $2 } $1 == "file" { f = $2 } $1 == "shmem" { s = $2 } $1 == "kernel" { k = $2 }
      END { if (a != "") printf "CgAnon=%d CgFile=%d CgShmem=%d CgKernel=%d ", a / 1024, f / 1024, s / 1024, k / 1024 }' "$c/memory.stat" 2>/dev/null
    ;;
esac
for t in "$d"/task/*; do
  [ -r "$t/stat" ] || continue
  # The thread's name may hold spaces and parentheses: the fields are counted from the last ") ".
  awk -v comm="$(tr -d '\n' <"$t/comm" 2>/dev/null | tr -c 'A-Za-z0-9._-' '_' | cut -c1-16)" '{
    s = $0; sub(/.*\) /, "", s); n = split(s, f, " ")
    if (n >= 39 && (f[39] == 1 || f[39] == 2 || f[39] == 6)) printf "%s:%s:%s\n", comm, f[39], f[38]
  }' "$t/stat" 2>/dev/null
done | awk 'BEGIN { out = "" } { out = out (out == "" ? "" : ",") $0 } END { printf "Rt=%s\n", out == "" ? "none" : out }'
