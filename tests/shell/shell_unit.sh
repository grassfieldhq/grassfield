#!/usr/bin/env bash
# grassfield-shell.service: the shell loads only from the system location (GF-115), 255 stays a failure so OnFailure= still
# fires (the logout case is the sleep-lock gate, GF-081) and the resource guard is set (GF-040). Static checks of the unit and of
# every `qs`/`quickshell` ipc/kill/log caller in the shipped tree, with mutations proving the scan; `systemd-analyze verify` runs
# when the environment allows it (the Claude Code sandbox does not: then it is reported, not counted).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
unit=$root/packaging/systemd/grassfield-shell.service
SYSTEM_PATH=/usr/share/grassfield/shell
fail=0
mut=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/shell-unit.XXXXXX")
trap 'rm -rf "$mut"' EXIT
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
exec_line=$(grep -E '^ExecStart=' "$unit")

desc="ExecStart loads the shell by path from $SYSTEM_PATH (qs -n -p), never by name"
check test "$exec_line" = "ExecStart=/usr/bin/qs -n -p $SYSTEM_PATH"
# Known limits of these scans (the cheap forms are covered, the rest is documented): an argument list split over several lines
# (a QML array with "qs", then "ipc" on the next line), a command assembled from variables or systemd specifiers (%t), and a
# path built at run time are not seen; review such a caller by hand.
# named_qs DIR...: qs/quickshell started or addressed by NAME (-c/--config grassfield), as a command line or as an array.
named_qs() {
  grep -rnIHE "(qs|quickshell)[^#]*[[:space:],\"'](-c|--config)[\"']?[[:space:]]*,?[[:space:]]*[\"']?grassfield" "$@" 2>/dev/null |
    grep -vE '^[^:]*:[0-9]*:[[:space:]]*(#|--|//|\*)'
}
export -f named_qs
desc="no shipped file selects the shell by name (-c/--config grassfield, command line or array): that also searches the user-writable ~/.config/quickshell"
# Only what git tracks is shipped: an untracked makepkg tree (packaging/arch/pkg, src) or a stale build is not scanned.
mapfile -t shipped < <(git -C "$root" ls-files -- apps bridges packaging config shell ui scripts/dev/gate-run.sh | sed "s|^|$root/|")
check bash -c 'out=$(named_qs "$@"); [ -z "$out" ] || { echo "$out"; exit 1; }' _ "${shipped[@]}"
mut=${mut:-$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/shell-unit.XXXXXX")}
printf 'command: ["qs", "-c", "grassfield", "ipc"]\n' >"$mut/n1.qml"
printf "x = ['quickshell', '--config', 'grassfield']\n" >"$mut/n2.js"
printf 'exec qs -c grassfield call a b\n' >"$mut/n3"
for f in n1.qml n2.js n3; do
  desc="mutation: selecting the shell by name in $f is caught"
  check bash -c '[ -n "$(named_qs "$1")" ]' _ "$mut/$f"
done
printf '# qs -c grassfield in a comment\nqs -n -p /usr/share/grassfield/shell\n' >"$mut/n4"
desc="a comment naming the old form and a -p start are not flagged"
check bash -c '[ -z "$(named_qs "$1")" ]' _ "$mut/n4"
# bare_qs DIR...: qs/quickshell ipc|kill|log callers (any quoting, /usr/bin/ prefix) that do not select the instance by pid
# (--pid), by the system path (-p /usr/share/grassfield/shell), through bindings.lua's shell_selector (itself checked below)
# or through the hyprland-dialog stand-in's shell_dir (ADR-0035 D-3), the screen-sharing picker stand-in's SHELL_DIR
# template (D-6), or grassfield-security-status's path, the security unit's own system path (ADR-0041 S1); since S2 the
# security root's system path itself (-p /usr/share/grassfield/shell/security.qml: grassfield-lid, the stand-in),
# bindings.lua's security_selector, and the UI's argv builder shell/services/LockClient.js (its root is the security root
# next to the UI's own, Client.securityRoot(Quickshell.shellDir)); all checked below too.
# Comment lines are skipped. A -p with any other path, a -c name, or no selector is reported.
bare_qs() {
  grep -rnIHE "([\"']?(/usr/bin/)?(qs|quickshell)[\"']?([[:space:]]*,[[:space:]]*|[[:space:]]+)[\"']?(ipc|kill|log)[\"']?([^[:alnum:]_]|$))" "$@" 2>/dev/null |
    grep -vE '^[^:]*:[0-9]*:[[:space:]]*(#|--|//|\*)' |
    grep -vE "(--pid|[\"']--pid[\"']|(-p|[\"']-p[\"'][[:space:]]*,)[[:space:]]+[\"']?/usr/share/grassfield/shell(/security\.qml)?([\"' ]|$))" | grep -v shell_selector | grep -v security_selector |
    grep -vE '/shell/services/LockClient\.js:[0-9]+:    var argv = \["env", "-u", "QS_CONFIG_PATH", "-u", "QS_CONFIG_NAME", "-u", "QS_MANIFEST", "qs", "ipc", "-p", root, "call", target\[0\], target\[1\]\];$' |
    grep -vE '/packaging/session-bin/hyprland-dialog:[0-9]+:answer=\$\(timeout -k 1 10 qs ipc -p "\$shell_dir" call anr report ' |
    grep -vE '/packaging/bin/grassfield-security-status:[0-9]+:(state|beat)=\$\(timeout -k 0\.2 2 qs ipc \$display -p "\$path" call security (state|heartbeat) ' |
    grep -vE '/packaging/bin/grassfield-security-status:[0-9]+:lock=\$\(timeout -k 0\.2 2 qs ipc \$display -p "\$path" call lock state ' |
    grep -vE '/packaging/session-bin/hyprland-share-picker:[0-9]+:    command = "qs ipc -p SHELL_DIR call picker request"\.split\(\)$'
}
export -f bare_qs
desc="every shipped qs ipc/kill/log caller (the whole of apps, bridges, packaging, config, shell and ui) selects an instance by the system path (-p) or by pid (--pid), never by name or bare"
check bash -c 'out=$(bare_qs "$@"); [ -z "$out" ] || { echo "$out"; exit 1; }' _ "${shipped[@]}"
# Mutation: the scan must catch a bare caller anywhere in a tree (a JS list, a QML command, a shell script, a Lua exec).
mkdir -p "$mut/shell/services" "$mut/packaging/bin" "$mut/config"
printf 'var c = ["qs", "ipc", "call", "lock", "lock"];\n' >"$mut/shell/services/X.js"
printf 'command: ["qs", "kill", "-c", "other"]\n' >"$mut/shell/services/Y.qml"
printf 'qs ipc call lock lock\n' >"$mut/packaging/bin/z"
printf "x = ['qs', 'ipc', 'call', 'a', 'b']\n" >"$mut/shell/services/S.js"
printf 'exec /usr/bin/qs ipc call lock lock\n' >"$mut/packaging/bin/u"
printf 'quickshell ipc call lock lock\n' >"$mut/packaging/bin/q"
printf 'qs ipc -p /home/someone/shell call lock lock\n' >"$mut/packaging/bin/wp"
printf 'command: ["qs", "ipc", "-p", "/tmp/x", "call", "a", "b"]\n' >"$mut/shell/services/W.qml"
printf 'hl.exec_cmd("qs ipc call lock lock")\n' >"$mut/config/w.lua"
for f in shell/services/X.js shell/services/Y.qml packaging/bin/z config/w.lua shell/services/S.js packaging/bin/u packaging/bin/q packaging/bin/wp shell/services/W.qml; do
  desc="mutation: a bare qs caller in $f is caught"
  check bash -c '[ -n "$(bare_qs "$1")" ]' _ "$mut/$f"
done
printf 'var c = ["qs", "ipc", "--pid", String(pid), "call", "a", "b"];\n// qs ipc call documented in a comment\nqs ipc -p /usr/share/grassfield/shell call a b\ncmd = ['qs', 'ipc', '--pid', 1]\n/usr/bin/qs ipc -p /usr/share/grassfield/shell call a b\n' >"$mut/ok.txt"
printf 'answer=$(timeout -k 1 10 qs ipc -p "$shell_dir" call anr report "$$"\n' >"$mut/packaging/bin/anr"
desc="mutation: the stand-in's shell_dir form anywhere but the stand-in is caught"
check bash -c '[ -n "$(bare_qs "$1")" ]' _ "$mut/packaging/bin/anr"
printf 'state=$(timeout -k 0.2 2 qs ipc $display -p "$path" call security state 2>/dev/null)\n' >"$mut/packaging/bin/sec"
desc="mutation: the security status form anywhere but grassfield-security-status is caught"
check bash -c '[ -n "$(bare_qs "$1")" ]' _ "$mut/packaging/bin/sec"
printf 'var argv = ["env", "-u", "QS_CONFIG_PATH", "-u", "QS_CONFIG_NAME", "-u", "QS_MANIFEST", "qs", "ipc", "-p", root, "call", target[0], target[1]];\n' >"$mut/shell/services/L.js"
desc="mutation: the UI's argv builder anywhere but shell/services/LockClient.js is caught"
check bash -c '[ -n "$(bare_qs "$1")" ]' _ "$mut/shell/services/L.js"
desc="LockClient's root is the security root next to the UI's own root (Quickshell.shellDir: the system path in a real session), never a name or another path (ADR-0041 S2)"
check bash -c 'grep -qx "    readonly property string securityRoot: Client.securityRoot(Quickshell.shellDir)" "$1/shell/services/LockClient.qml" && grep -q "return dir === \"\" ? \"\" : dir + \"/security.qml\";" "$1/shell/services/LockClient.js"' _ "$root"
desc="bindings.lua's security_selector is the security root's system path, the dev tree's only through the dev-gated shell_dir"
check bash -c 'grep -qx "local security_selector = (shell_dir and shell_dir ~= \"\") and (\"-p '"'"'\" .. shell_dir .. \"/security.qml'"'"'\") or \"-p '"'"'/usr/share/grassfield/shell/security.qml'"'"'\"" "$1/config/hypr/grassfield/bindings.lua"' _ "$root"
desc="grassfield-security-status's path is the security unit's system path, set once"
check bash -c 'f=$1; [[ $(grep -c "^path=" "$f") == 1 ]] && grep -qx "path=/usr/share/grassfield/shell/security.qml" "$f"' _ "$root/packaging/bin/grassfield-security-status"
desc="a --pid caller, a -p caller and a comment are not flagged"
check bash -c '[ -z "$(bare_qs "$1")" ]' _ "$mut/ok.txt"
desc="every installed qs ipc caller names the system path of its unit: the lock's (lid, the stand-in's lock lock, the lock key) the security root next to the shell's (ADR-0041 S2), the stand-in's update check the shell's"
check bash -c 'grep -q "ipc -p $1/security.qml call lock lid" "$2/packaging/bin/grassfield-lid" && grep -q "ipc -p $1/security.qml call lock lock" "$2/packaging/shims/omarchy-shell" && grep -q "ipc -p $1 call update check" "$2/packaging/shims/omarchy-shell" && grep -q "$1/security.qml" "$2/config/hypr/grassfield/bindings.lua" && grep -q "$1" "$2/config/hypr/grassfield/bindings.lua"' _ "$SYSTEM_PATH" "$root"
desc="the hyprland-dialog stand-in's shell_dir is the system path, replaced by GRASSFIELD_SHELL_DIR only inside its dev-session gate (tests/shell/hyprland_dialog.sh runs both)"
check bash -c 'f=$1; [[ $(grep -c "shell_dir=" "$f") == 2 ]] && grep -qx "shell_dir=/usr/share/grassfield/shell" "$f" &&
  [[ $(grep -B1 -x "  shell_dir=\$GRASSFIELD_SHELL_DIR" "$f" | head -1) == "if [ \"\${GRASSFIELD_DEV:-}\" = 1 ] && [ \"\${GRASSFIELD_SESSION:-}\" != 1 ] && [ -n \"\${GRASSFIELD_SHELL_DIR:-}\" ]; then" ]]' _ "$root/packaging/session-bin/hyprland-dialog"
desc="the screen-sharing picker stand-in's SHELL_DIR is the system path, its template's only replacement is shell_dir(), which returns GRASSFIELD_SHELL_DIR only inside the dev-session gate (tests/shell/share_picker.sh runs both)"
check bash -c 'f=$1; grep -qx "SHELL_DIR = \"/usr/share/grassfield/shell\"" "$f" && [[ $(grep -c "GRASSFIELD_SHELL_DIR" "$f") == 3 ]] &&
  grep -qx "    if env.get(\"GRASSFIELD_DEV\") == \"1\" and env.get(\"GRASSFIELD_SESSION\") != \"1\" and env.get(\"GRASSFIELD_SHELL_DIR\"):" "$f" &&
  [[ $(grep -A1 -x "    if env.get(\"GRASSFIELD_DEV\") == \"1\" and env.get(\"GRASSFIELD_SESSION\") != \"1\" and env.get(\"GRASSFIELD_SHELL_DIR\"):" "$f" | tail -1) == "        return env[\"GRASSFIELD_SHELL_DIR\"]" ]] &&
  grep -qx "    argv = \[shell_dir() if a == \"SHELL_DIR\" else a for a in command\] + \[request_id, path\]" "$f"' _ "$root/packaging/session-bin/hyprland-share-picker"
printf 'command = "qs ipc -p SHELL_DIR call picker request".split()\n' >"$mut/packaging/bin/pk"
desc="mutation: the picker stand-in's template anywhere but the stand-in is caught"
check bash -c '[ -n "$(bare_qs "$1")" ]' _ "$mut/packaging/bin/pk"
desc="255 stays a failure (qs exits 255 on a config error and a missing path too): no SuccessExitStatus, so OnFailure= still fires; the logout case is the sleep-lock gate (tests/security/sleep_lock_units.sh)"
check bash -c '! grep -q "^SuccessExitStatus=" "$1" && grep -q "/sleep-lock-gate" "$2/packaging/systemd/omarchy-sleep-lock.service.d/10-grassfield.conf" && grep -q "compositor is gone" "$2/packaging/systemd/sleep-lock-gate"' _ "$unit" "$root"
desc="the sleep lock for real crashes (D-12) is armed by the security unit since ADR-0041 S2 (it holds the inhibitor); the UI's unit keeps the failure counter and its restart policy"
check bash -c 'grep -qx "OnFailure=grassfield-shell-failed.service" "$1" && grep -qx "OnFailure=omarchy-sleep-lock.service" "$2" && grep -qx "Restart=always" "$1"' _ "$unit" "$root/packaging/systemd/grassfield-security.service"
desc="resource guard: MemoryHigh=1536M, MemoryMax=3G, CPUQuota=150% (GF-040, ADR-0006 amendment)"
check bash -c 'grep -qx "MemoryHigh=1536M" "$1" && grep -qx "MemoryMax=3G" "$1" && grep -qx "CPUQuota=150%" "$1"' _ "$unit"
desc="the soft memory limit stays below the hard one and above the P2 gate (608 MB)"
check python3 -I -c '
import re,sys
t=open(sys.argv[1]).read()
def mb(k):
    v=re.search("^"+k+"=(\\d+)([MG])$",t,re.M); return int(v[1])*(1024 if v[2]=="G" else 1)
assert 608 < mb("MemoryHigh") < mb("MemoryMax")' "$unit"
if command -v systemd-analyze >/dev/null; then
  if out=$(systemd-analyze --user verify "$unit" 2>&1); then
    echo "PASS: systemd-analyze verify accepts the unit"
  elif grep -q "Failed to setup working directory\|Read-only file system\|Operation not permitted\|Failed to lookup RuntimeDirectory path" <<<"$out"; then
    echo "NOTE: systemd-analyze verify NOT VERIFIED here (environment refuses it: $(head -n1 <<<"$out"))"
  else
    echo "FAIL: systemd-analyze verify: $out"; fail=1
  fi
fi
exit "$fail"
