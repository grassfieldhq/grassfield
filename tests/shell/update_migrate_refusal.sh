#!/usr/bin/env bash
# The host-side refusal of tests/integration/update_migrate.sh (its container runs systemd as PID 1: on 2026-11-11 a privileged
# one ended the owner's live session three times). The script must refuse BEFORE any docker call, unless it runs in a virtual
# machine (systemd-detect-virt --vm) or on a CI runner, and never beside an active graphical session. Docker, systemd-detect-virt
# and loginctl are stubs on PATH: docker only records what it is asked, so this test starts no container, anywhere.
# Layer: logic (no root, no session, no docker).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
expect() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1: got '$2', want '$3'"; fi; }
has() { if grep -Fq -- "$2" "$3"; then pass "$1"; else fail "$1: '$2' not in $3"; fi; }

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

# run <name> [env assignments...]: the script as a bare command with the stubs first on PATH
run() {
  rm -f "$W/calls"
  : >"$W/calls"
  env -i PATH="$W/bin:$PATH" HOME="$W" GF_STUB="$W" "${@:2}" bash "$root/tests/integration/update_migrate.sh" >"$W/out" 2>&1
  rc=$?
  calls=$(cat "$W/calls")
}
reset() { rm -f "$W"/virt "$W"/sessions "$W"/type.* "$W"/state.*; }

reset
run bare-host
expect 'a bare host: refused (exit 2)' "$rc" 2
has 'a bare host: says why' 'may only run in a virtual machine' "$W/out"
expect 'a bare host: docker was never called' "$calls" ''

reset; echo '1 1000 u seat0' >"$W/sessions"; echo wayland >"$W/type.1"
run bare-host-session
expect 'a bare host with a graphical session: refused' "$rc" 2
expect 'a bare host with a graphical session: no docker call' "$calls" ''
run override-on-bare GRASSFIELD_UPDATE_MIGRATE_VM_SESSION_OK=1
expect 'the session override does not open a bare host' "$rc" 2
expect 'the session override on a bare host: no docker call' "$calls" ''

reset; echo kvm >"$W/virt"; echo '1 1000 u seat0' >"$W/sessions"; echo wayland >"$W/type.1"
run vm-session
expect 'a VM with an active graphical session: refused' "$rc" 2
has 'a VM with a session: says so' 'a graphical session is active' "$W/out"
expect 'a VM with a session: no docker call' "$calls" ''
echo x11 >"$W/type.1"
run vm-x11
expect 'an x11 session counts too' "$rc" 2
expect 'an x11 session: no docker call' "$calls" ''
run vm-session-ok GRASSFIELD_UPDATE_MIGRATE_VM_SESSION_OK=1
expect 'a VM, session acknowledged as disposable: goes on (SKIP without a daemon, exit 0)' "$rc" 0
has 'a VM, session acknowledged: the SKIP line' 'SKIP: no docker daemon' "$W/out"
expect 'a VM, session acknowledged: the only call to docker is info' "$calls" 'call: info'
echo closing >"$W/state.1"
run vm-closing
expect 'a closing session is not active: goes on' "$rc" 0

reset; echo kvm >"$W/virt"
run vm-clean
expect 'a VM without a graphical session: goes on (exit 0)' "$rc" 0
expect 'a VM without a session: the only call to docker is info' "$calls" 'call: info'
echo '2 1000 u seat0' >"$W/sessions"; echo tty >"$W/type.2"
run vm-tty
expect 'a text session is not graphical: goes on' "$rc" 0

reset
run ci CI=true
expect 'a CI runner without a session: goes on' "$rc" 0
expect 'a CI runner: the only call to docker is info' "$calls" 'call: info'
echo '1 1000 u seat0' >"$W/sessions"; echo wayland >"$W/type.1"
run ci-session CI=true
expect 'a CI runner with a graphical session: refused' "$rc" 2
expect 'a CI runner with a session: no docker call' "$calls" ''
run ci-session-ok CI=true GRASSFIELD_UPDATE_MIGRATE_VM_SESSION_OK=1
expect 'the override does not open a CI runner that has a session' "$rc" 2

# Read the code path too: the refusal is the first statement of the host branch, before git, the wrapper and any docker call.
first=$(awk '/^if \[\[ \$\{1:-\} != --inside \]\]; then/ { on = 1; next } on && NF { print; exit }' "$root/tests/integration/update_migrate.sh")
expect 'host_refusal is the first statement of the host branch' "$first" '  host_refusal || exit 2'

((fails == 0)) && echo "PASS: update_migrate host-side refusal" || { echo "FAIL: update_migrate host-side refusal ($fails)"; exit 1; }
