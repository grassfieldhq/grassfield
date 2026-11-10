#!/usr/bin/env bash
# The deferred surfaces lose no early request (ADR-0056 amendment, R1): Search, Overview, Apps, the OSD window and the app
# switcher's window are built right after "started"; a request that reaches the shell before its surface exists (key binding or
# hot corner by IPC, the menu bar and Dock buttons) is remembered by shell.qml's `early` and performed once the surface is built,
# the last request winning (open then close = closed).
#
# Deterministic: the nested shell is restarted with GRASSFIELD_DEFER_HOLD=1 (dev session only), which keeps the loaders from
# building until `qs ipc call deferred release`; requests are sent meanwhile, then the surfaces are built and read back.
#   case 1  search open needle; apps toggle twice            -> after the release Search is open on "needle", Apps closed
#   case 2  apps open; search open x then search close       -> after the release Apps is open, Search closed
# and the shell log holds no "Handler was registered but will not be used" (two handlers for one target) and no QML TypeError,
# ReferenceError or binding loop. The shell is restarted normally at the end.
#
# Uses the nested session of this tree that is up (just nested-up) and restarts only its shell; without one it SKIPs (exit 0).
# Run (bare command):  tests/shell/deferred_early.sh      Expected: "deferred_early: 0 failure(s)"; exit 0.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
if ! dev_nested_target "$dev" 2>/dev/null || ! dev_live_pid "$dev/shell.pid" >/dev/null; then
  echo "SKIP deferred_early: no nested session of this tree (scripts/dev/nested-up.sh, as a bare command)"
  exit 0
fi
unset GRASSFIELD_SESSION QT_QPA_PLATFORMTHEME
fails=0
check() { if [[ $2 == 0 ]]; then echo "PASS deferred_early $1"; else echo "FAIL deferred_early $1"; fails=1; fi; }
ipc() { "$root/tests/visual/ipc.sh" "$@" 2>/dev/null; }
until_ok() { local n=$(( $1 * 5 )) i; shift; for i in $(seq 1 "$n"); do "$@" && return 0; sleep 0.2; done; return 1; }
st() { ipc "$1" status | jq -r "$2" 2>/dev/null; }
is() { [[ $(st "$1" "$2") == "$3" ]]; }

flags=()
# The packaged form when the session runs it (the stamped tree), the source otherwise.
if tr '\0' '\n' <"/proc/$(awk '{print $1}' "$dev/shell.pid")/cmdline" 2>/dev/null | grep -q "/migrated-"; then flags=(--migrated); fi

# restart_held HOLD: restart the nested shell (HOLD=1: the deferred surfaces stay unbuilt) and wait for its "started" line.
restart_held() {
  GRASSFIELD_DEFER_HOLD=$1 "$root/scripts/dev/shell-run.sh" "${flags[@]}" >/dev/null 2>&1 || return 1
  until_ok 60 grep -q "grassfield-shell: started" "$dev/shell.log"
}
held() { [[ $(ipc deferred status | jq -r .held 2>/dev/null) == true ]]; }
# The shell's main thread is busy for a few seconds after "started" and answers IPC slowly meanwhile; a request older than
# Tokens.deferredRequestMaxAgeMs (5 s) is dropped on purpose, so the requests are sent once it answers quickly and released at once.
settle() { sleep 6; }

# case 1
restart_held 1; check "case 1: the shell started with the deferred surfaces held" $?
until_ok 20 held; check "case 1: the surfaces are held (deferred status)" $?
settle
ipc search open needle >/dev/null; ipc apps toggle >/dev/null; ipc apps toggle >/dev/null
[[ $(ipc deferred status | jq -r '.pending.search.open') == true ]]; check "case 1: the early Search open is pending" $?
ipc deferred release >/dev/null
until_ok 20 is search .open true; check "case 1: Search is open once built" $?
is search .query needle; check "case 1: Search kept the text of the early open" $?
is apps .open false; check "case 1: two early Apps toggles end closed" $?

# case 2
restart_held 1; check "case 2: the shell started with the deferred surfaces held" $?
until_ok 20 held
settle
ipc apps open >/dev/null; ipc search open x >/dev/null; ipc search close >/dev/null
ipc deferred release >/dev/null
until_ok 20 is apps .open true; check "case 2: Apps is open once built" $?
is search .open false; check "case 2: an early Search open then close ends closed" $?

# the log of the last held run
! grep -q "will not be used because another handler" "$dev/shell.log"; check "log: no two IPC handlers for one target" $?
! grep -qE "TypeError|ReferenceError|Binding loop" "$dev/shell.log"; check "log: no QML TypeError, ReferenceError or binding loop" $?

# leave the session as found
restart_held 0; check "the shell is restarted normally" $?
echo "deferred_early: $fails failure(s)"
exit "$fails"
