#!/usr/bin/env bash
# The host-side refusal of tests/integration/update_migrate.sh (its container runs systemd as PID 1: on 2026-11-11 a privileged
# one ended the owner's live session three times). It FAILS CLOSED: before any docker call it refuses unless it runs in a virtual
# machine or on a CI runner (CI alone is not enough: GITHUB_ACTIONS and RUNNER_TEMP too), refuses beside any wayland, x11 or mir
# session that is not closing, however it is seen (loginctl or /run/systemd/sessions/*), and refuses when it cannot tell.
# Docker, systemd-detect-virt and loginctl are stubs on PATH (docker only records what it is asked: no container starts, anywhere);
# the session files are a fixture directory. Layer: logic (no root, no session, no docker).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
W=$(mktemp -d)
mdir=''
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W" ${mdir:+"$mdir"}' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
expect() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1: got '$2', want '$3'"; fi; }
has() { if grep -Fq -- "$2" "$3"; then pass "$1"; else fail "$1: '$2' not in $3"; fi; }
hasnt() { if grep -Fq -- "$2" "$3"; then fail "$1: '$2' found in $3"; else pass "$1"; fi; }

mkdir -p "$W/bin"
cat >"$W/bin/docker" <<'EOF'
#!/bin/bash
echo "call: $*" >>"$GF_STUB/calls"
exit 1
EOF
cat >"$W/bin/systemd-detect-virt" <<'EOF'
#!/bin/bash
v=$(cat "$GF_STUB/virt" 2>/dev/null || echo none)
echo "$v"
[[ $v != none ]]
EOF
cat >"$W/bin/loginctl" <<'EOF'
#!/bin/bash
[[ -e $GF_STUB/lc_fail ]] && exit 1
case $1 in
  list-sessions) cat "$GF_STUB/sessions" 2>/dev/null ;;
  show-session)
    id=$2
    case $4 in
      Type) cat "$GF_STUB/type.$id" 2>/dev/null || echo tty ;;
      State) cat "$GF_STUB/state.$id" 2>/dev/null || echo active ;;
    esac ;;
esac
EOF
chmod +x "$W/bin/"*

# run <name> [env assignments...]: the script as a bare command, the stubs first on PATH, the session files in the fixture folder
run() {
  : >"$W/calls"
  env -i PATH="$W/bin:$PATH" HOME="$W" TMPDIR="${TMPDIR:-/tmp}" GF_STUB="$W" GRASSFIELD_TEST_REFUSAL=1 GRASSFIELD_TEST_SESSIONS_DIR="$W/sess" "${@:2}" \
    bash "${SCRIPT:-$root/tests/integration/update_migrate.sh}" >"$W/out" 2>&1
  rc=$?
  calls=$(cat "$W/calls")
}
reset() { chmod -R u+rwx "$W/sess" 2>/dev/null; rm -rf "$W"/virt "$W"/sessions "$W"/type.* "$W"/state.* "$W"/lc_fail "$W/sess"; mkdir -p "$W/sess"; }
session_file() { printf 'UID=1000\nTYPE=%s\nSTATE=%s\n' "$2" "$3" >"$W/sess/$1"; }
CIENV=(CI=true GITHUB_ACTIONS=true RUNNER_TEMP=/tmp)
refused() { # <label>: exit 2, no engine call, a refusal that suggests no way round it
  expect "$1: refused (exit 2)" "$rc" 2
  expect "$1: the engine was never called" "$calls" ''
  hasnt "$1: the message suggests no override" 'GRASSFIELD_UPDATE' "$W/out"
  hasnt "$1: the message does not tell to set CI" 'CI=true' "$W/out"
}
proceeds() { # <label>
  expect "$1: goes on (SKIP without a daemon, exit 0)" "$rc" 0
  expect "$1: the only engine call is info" "$calls" 'call: info'
}

reset
run bare
refused 'a bare host'
run bare-ci-alone CI=true
refused 'CI=true alone on a bare host'
run bare-ci-half CI=true GITHUB_ACTIONS=true
refused 'CI and GITHUB_ACTIONS without RUNNER_TEMP'
run bare-override GRASSFIELD_UPDATE_MIGRATE_VM_SESSION_OK=1
refused 'an old override variable on a bare host'

reset; echo '1 1000 u seat0' >"$W/sessions"; echo wayland >"$W/type.1"
run bare-session
refused 'a bare host with a graphical session'

reset
run ci-clean "${CIENV[@]}"
proceeds 'a CI runner with its markers and no session'
session_file 1 wayland active
run ci-session-file "${CIENV[@]}"
refused 'a CI runner with a wayland session file'
reset; echo '1 1000 u seat0' >"$W/sessions"; echo x11 >"$W/type.1"
run ci-session-loginctl "${CIENV[@]}"
refused 'a CI runner with an x11 session in loginctl'

reset; echo kvm >"$W/virt"
run vm-clean
proceeds 'a VM without a graphical session'
echo '2 1000 u seat0' >"$W/sessions"; echo tty >"$W/type.2"
run vm-tty
proceeds 'a VM with a text session only'
reset; echo kvm >"$W/virt"; echo '1 1000 u seat0' >"$W/sessions"; echo wayland >"$W/type.1"
run vm-session
refused 'a VM with a wayland session (loginctl)'
run vm-session-override GRASSFIELD_UPDATE_MIGRATE_VM_SESSION_OK=1
refused 'a VM with a wayland session and the old override variable'
echo online >"$W/state.1"
run vm-online
refused 'a session that is online, not active'
echo closing >"$W/state.1"
run vm-closing
proceeds 'a session that is closing'

# loginctl failing, as in the agents' sandbox, while the session files say wayland
reset; echo kvm >"$W/virt"; : >"$W/lc_fail"
session_file 1 wayland active
run vm-lc-fail-wayland CI=true
refused 'loginctl failing with a wayland session file present (CI=true does not help)'
session_file 1 wayland online
run vm-lc-fail-online
refused 'loginctl failing, a wayland session file online'
session_file 1 mir opening
run vm-lc-fail-mir
refused 'loginctl failing, a mir session file opening'
session_file 1 wayland closing
run vm-lc-fail-closing
proceeds 'loginctl failing, the only session file closing'
reset; echo kvm >"$W/virt"; : >"$W/lc_fail"; printf 'UID=1000\nSTATE=active\n' >"$W/sess/1"
run vm-lc-fail-notype
refused 'a session file without a type'
reset; echo kvm >"$W/virt"; : >"$W/lc_fail"
run vm-lc-fail-empty
proceeds 'loginctl failing, the session folder readable and empty'
rm -rf "$W/sess"
run vm-lc-fail-nodir
refused 'loginctl failing and no session folder: it cannot tell'
if [[ $(id -u) != 0 ]]; then
  reset; echo kvm >"$W/virt"; : >"$W/lc_fail"; session_file 1 wayland active; chmod 000 "$W/sess"
  run vm-lc-fail-unreadable
  refused 'loginctl failing and the session folder unreadable'
  chmod 755 "$W/sess"
else
  echo "  note the unreadable-folder case needs a non-root user: SKIPPED here"
fi

# The fixture folder is honoured only with the test marker AND under $TMPDIR, and that is proved by BEHAVIOUR: a copy of the script
# whose "real" session folder is a stand-in holding a wayland session (so ignoring the fixture shows as a refusal) runs three
# scenarios with a fixture that holds only a text session: the fixture outside $TMPDIR (must be ignored: refused), inside with the
# marker (honoured: goes on), inside without the marker (ignored: refused). Then three mutants of that copy, each deleting a part
# of the rule, must each change one answer, so the test fails if :70's condition (or either half of it) is deleted.
mdir="$root/.dev/refusal-mutants.$$"
mkdir -p "$mdir" "$W/realdir" "$W/othertmp"
printf 'UID=1000\nTYPE=wayland\nSTATE=active\n' >"$W/realdir/1"
mutant() { # <name> <mode>: a copy of update_migrate.sh with the real session folder replaced, and (per mode) a part of the fixture rule deleted
  python3 -I - "$root/tests/integration/update_migrate.sh" "$mdir/$1.sh" "$W/realdir" "$2" <<'PY'
import sys
src, dst, real, mode = sys.argv[1:5]
s = open(src).read()
a = 'dir=/run/systemd/sessions'
assert a in s
s = s.replace(a, 'dir=' + real, 1)
if mode == 'no-tmpdir-check':
    a = '[[ $t == "$k"/* ]] && dir=$t'
    assert a in s
    s = s.replace(a, 'dir=$t', 1)
elif mode == 'no-marker':
    a = '${GRASSFIELD_TEST_REFUSAL:-} == 1 && '
    assert a in s
    s = s.replace(a, '', 1)
elif mode == 'no-block':
    i = s.index('  if [[ ${GRASSFIELD_TEST_REFUSAL:-}')
    j = s.index('  fi\n', i) + 5
    s = s[:i] + s[j:]
open(dst, 'w').write(s)
PY
}
scen() { # <script>: the exit codes of the three scenarios
  local a b c
  reset; echo kvm >"$W/virt"; : >"$W/lc_fail"; session_file 1 tty active
  SCRIPT=$1 run outside TMPDIR="$W/othertmp"; a=$rc
  SCRIPT=$1 run inside; b=$rc
  SCRIPT=$1 run nomarker GRASSFIELD_TEST_REFUSAL=0; c=$rc
  echo "$a $b $c"
}
mutant base none
mutant m1 no-tmpdir-check
mutant m2 no-marker
mutant m3 no-block
expect 'the fixture rule: outside $TMPDIR ignored, inside with the marker honoured, without the marker ignored' "$(scen "$mdir/base.sh")" '2 0 2'
expect 'mutant: the $TMPDIR check deleted is seen (a fixture outside $TMPDIR is honoured)' "$(scen "$mdir/m1.sh")" '0 0 2'
expect 'mutant: the marker check deleted is seen (a fixture without the marker is honoured)' "$(scen "$mdir/m2.sh")" '2 0 0'
expect 'mutant: the whole fixture block deleted is seen (a fixture is never honoured)' "$(scen "$mdir/m3.sh")" '2 2 2'

# The code path: the refusal is the first statement of the host branch, before git, the wrapper and any docker call.
first=$(awk '/^if \[\[ \$\{1:-\} != --inside \]\]; then/ { on = 1; next } on && NF { print; exit }' "$root/tests/integration/update_migrate.sh")
expect 'host_refusal is the first statement of the host branch' "$first" '  host_refusal || exit 2'

((fails == 0)) && echo "PASS: update_migrate host-side refusal" || { echo "FAIL: update_migrate host-side refusal ($fails)"; exit 1; }
