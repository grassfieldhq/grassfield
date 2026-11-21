#!/bin/sh
# ExecStopPost of grassfield-shell.service (owner's report of 2026-11-21): when the shell's process died of SIGKILL, one journal
# line with the last health sample it wrote (ShellHealth.qml: memory, realtime threads and their CPU limit) and how long before
# the kill it was taken. systemd's own stop, the liveness probe (grassfield-shell-watchdog) and the kernel's OOM killer each log
# their kill; a SIGKILL with none of those lines came from another process or from the kernel's realtime CPU limit
# (RLIMIT_RTTIME): docs/specs/security.md "A shell killed by SIGKILL" says how to name the sender. Prints nothing otherwise.
[ "${EXIT_CODE:-}" = killed ] && [ "${EXIT_STATUS:-}" = KILL ] || exit 0
f=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/grassfield-shell-health
if [ -r "$f" ] && line=$(head -c 1024 "$f" | head -n 1 | tr -cd '[:print:]') && [ -n "$line" ]; then
  at=${line#at=}
  at=${at%% *}
  case $at in '' | *[!0-9]*) age="?" ;; *) age=$(($(date +%s) - at)) ;; esac
  echo "grassfield-shell: the shell was killed by SIGKILL (result ${SERVICE_RESULT:-?}); its last health sample, ${age} s before: ${line#at=* }"
else
  echo "grassfield-shell: the shell was killed by SIGKILL (result ${SERVICE_RESULT:-?}); no health sample was written"
fi
