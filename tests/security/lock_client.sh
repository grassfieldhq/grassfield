#!/usr/bin/env bash
# ADR-0041 step 1, S2: the UI reads the lock state the security process publishes, fail closed. Runs
# tests/security/lock_client.d/probe.qml offscreen against the REAL LockClient and SessionState (shell/services), the
# probe playing the security process (it writes the state file as LockPublisher does): no state, a stale beat (a stopped
# security process), a missed push with the compositor's lock signal, "locking", a file that does not parse and a removed
# file each read locked, through SessionState.refuses as every UI surface asks; a fresh "unlocked" beat and a restarted
# writer read unlocked. Then the same probe against copies of LockClient.qml with one fail-closed input removed each
# (mutants): each must make it FAIL. XDG_RUNTIME_DIR is a scratch directory under .dev/; no compositor, no bus, no lock.
# Plain shell test: PASS/FAIL lines, non-zero on failure. LOCK_CLIENT_ONLY=control runs the control alone.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/lock-client.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0

# A config directory: the probe next to the modules of the real shell (qs.services, qs.lib, ...), the services either linked or
# a copy with one mutant (a literal \n in the mutant's texts is a line break).
tree() { # <dir> [<mutant find> <mutant replace>]
  local dir=$1
  mkdir -p "$dir/runtime" "$dir/home" "$dir/cfg"
  chmod 700 "$dir/runtime"
  local entry name
  # Links to every module of the real shell (Quickshell's scanner follows the services' imports), services aside.
  for entry in "$root"/shell/*; do
    name=$(basename "$entry")
    [[ $name == shell.qml || $name == security.qml || $name == services ]] || ln -s "$entry" "$dir/cfg/$name"
  done
  if [[ $# -ge 3 ]]; then
    cp -a "$root/shell/services" "$dir/cfg/services"
    python3 -I - "$dir/cfg/services/LockClient.qml" "$2" "$3" <<'PY' || return 3
import sys
path, old, new = sys.argv[1:4]
old, new = old.replace("\\n", "\n"), new.replace("\\n", "\n")
text = open(path).read()
if text.count(old) != 1:
    sys.exit(3)
open(path, 'w').write(text.replace(old, new))
PY
  else
    ln -s "$root/shell/services" "$dir/cfg/services"
  fi
  cp tests/security/lock_client.d/probe.qml "$dir/cfg/shell.qml"
}

run() { # <dir>: prints the probe's verdict line (the whole log stays in <dir>/log while the run lasts)
  local dir=$1
  env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION \
    GRASSFIELD_DEV=1 HOME="$dir/home" XDG_RUNTIME_DIR="$dir/runtime" XDG_CACHE_HOME="$dir/home/.cache" \
    GRASSFIELD_STATE_HOME="$dir/home/state" GRASSFIELD_CONFIG_HOME="$dir/home/config" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
    timeout 90 qs -p "$dir/cfg" --no-color >"$dir/log" 2>&1 || true
  grep -m1 -E "lock-client: (PASS|FAIL)" "$dir/log" ||
    echo "lock-client: no verdict ($(grep -E 'ERROR|WARN' "$dir/log" | grep -v -E 'quickshell\.(ipc|paths|tooling|logging)' | head -n 3 | tr '\n' ' '))"
}

tree "$tmp/control"
out=$(run "$tmp/control")
if [[ $out == *"lock-client: PASS"* ]]; then
  echo "PASS: lock client: every fail-closed input reads locked, a fresh unlocked beat reads unlocked (the real LockClient and SessionState)"
else
  echo "FAIL: lock client: $out"
  fail=1
fi
[[ ${LOCK_CLIENT_ONLY:-} == control ]] && exit "$fail"

# name | find | replace: each removes one fail-closed input of the real LockClient.qml.
while IFS='|' read -r name find replace; do
  [[ -n $name ]] || continue
  if ! tree "$tmp/$name" "$find" "$replace"; then
    echo "FAIL: lock client mutant $name: its text is not in LockClient.qml exactly once (the mutant is stale)"
    fail=1
    continue
  fi
  out=$(run "$tmp/$name")
  if [[ $out == *"lock-client: PASS"* ]]; then
    echo "FAIL: lock client mutant $name survived"
    fail=1
  else
    echo "PASS: lock client mutant $name caught (${out#lock-client: })"
  fi
done <<'EOF'
stale-never|        interval: LockState.STALE_MS|        interval: 600000
compositor-ignored|LockState.uiLocked(root.known, root.stale, root.state, root.compositorLocked)|LockState.uiLocked(root.known, root.stale, root.state, false)
garbage-keeps-last|            root.known = false;\n            return;\n        }\n        const fresh|            return;\n        }\n        const fresh
EOF
exit "$fail"
