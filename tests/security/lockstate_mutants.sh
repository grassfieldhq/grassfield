#!/usr/bin/env bash
# Mutation check of the lock state across processes (ADR-0041 step 1, S2; tests/security/tst_lockstate.qml): every mutant
# below makes one of the UI's fail-closed readings fail open (no state, a stale beat, a missed push with the compositor's
# lock signal, a stopped security process, a state being acquired) or loosens the reader, and must make the offscreen test
# FAIL; the unmutated sources must PASS. Offscreen, no Quickshell, no compositor.
#
#   tests/security/lockstate_mutants.sh     one line per mutant: "PASS: mutant <name> caught" or "FAIL: ...", exit 0 when
#                                           the control passes and every mutant is caught
#
# Mutants are applied to a scratch copy of shell/lib, shell/services/LockClient.js, shell/security (LockMachine.js,
# idle/IdleModel.js) and the test under .dev/ (removed on exit); the working tree is never edited.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
scratch=$(mktemp -d "$root/.dev/lockstate-mutants.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
unset QT_QPA_PLATFORMTHEME
export QT_QPA_PLATFORM=offscreen
fail=0

fresh() {
  rm -rf "$scratch/src"
  mkdir -p "$scratch/src/tests/security" "$scratch/src/shell/lib" "$scratch/src/shell/services" "$scratch/src/shell/security/idle"
  cp "$root/shell/lib/LockState.js" "$scratch/src/shell/lib/"
  cp "$root/shell/services/LockClient.js" "$scratch/src/shell/services/"
  cp "$root/shell/security/LockMachine.js" "$scratch/src/shell/security/"
  cp "$root/shell/security/idle/IdleModel.js" "$scratch/src/shell/security/idle/"
  cp "$root/tests/security/tst_lockstate.qml" "$scratch/src/tests/security/"
}

# mutate <file under src> <text to find> <replacement>: fails unless the text occurs exactly once. A literal \\n in the table
# below stands for a line break.
mutate() {
  python3 -I - "$scratch/src/$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
old, new = old.replace("\\n", "\n"), new.replace("\\n", "\n")
text = open(path).read()
if text.count(old) != 1:
    sys.exit(3)
open(path, 'w').write(text.replace(old, new))
PY
}

passes() {
  local out
  out=$(cd "$scratch/src" && /usr/lib/qt6/bin/qmltestrunner -input tests/security/tst_lockstate.qml 2>&1)
  ! grep -q '^FAIL' <<<"$out" && grep -qE '^Totals: [0-9]+ passed, 0 failed' <<<"$out"
}

fresh
if passes; then echo "PASS: control: the unmutated sources pass"; else echo "FAIL: control: the unmutated sources fail"; exit 1; fi

# name | file | find | replace
while IFS='|' read -r name file find replace; do
  [[ -n $name ]] || continue
  fresh
  if ! mutate "$file" "$find" "$replace"; then
    echo "FAIL: mutant $name: its text is not in $file exactly once (the mutant is stale)"
    fail=1
    continue
  fi
  if passes; then
    echo "FAIL: mutant $name survived (tst_lockstate.qml does not see it)"
    fail=1
  else
    echo "PASS: mutant $name caught"
  fi
done <<'EOF'
no-state-reads-unlocked|shell/lib/LockState.js|if (known !== true || stale !== false)|if (stale === true)
stale-reads-unlocked|shell/lib/LockState.js|if (known !== true || stale !== false)|if (known !== true)
compositor-signal-ignored|shell/lib/LockState.js|    if (compositorLocked === true)\n        return true;\n|
locking-reads-unlocked|shell/lib/LockState.js|    return state !== "unlocked";|    return state === "locked";
unknown-state-reads-unlocked|shell/lib/LockState.js|    return state !== "unlocked";|    return state === "locked" || state === "locking";
public-locking-as-unlocked|shell/lib/LockState.js|    return holding === true ? "locked" : "locking";|    return holding === true ? "locked" : "unlocked";
stale-never|shell/lib/LockState.js|sinceBeatMs < STALE_MS);|sinceBeatMs < STALE_MS * 1000);
same-beat-counts|shell/lib/LockState.js|    return read.writer !== last.writer || read.seq !== last.seq;|    return true;
restart-not-a-beat|shell/lib/LockState.js|    return read.writer !== last.writer || read.seq !== last.seq;|    return read.seq !== last.seq;
unreadable-is-a-beat|shell/lib/LockState.js|    if (read === null || read === undefined || read.ok !== true)\n        return false;|    if (read === null || read === undefined)\n        return false;
parse-any-state|shell/lib/LockState.js|    if (o.state !== "unlocked" && o.state !== "locking" && o.state !== "locked")\n        return bad;|
parse-no-length-bound|shell/lib/LockState.js|    if (s.length === 0 || s.length > MAX_BYTES)|    if (s.length === 0)
parse-loose-seq|shell/lib/LockState.js|    if (!isCount(o.seq) || !isCount(o.writer))|    if (o.seq === undefined || o.writer === undefined)
heartbeat-too-slow|shell/lib/LockState.js|var HEARTBEAT_MS = 2000;|var HEARTBEAT_MS = 3000;
no-runtime-dir-path|shell/lib/LockState.js|    if (dir === "" || dir.charAt(0) !== "/")|    if (dir.charAt(0) !== "/" && dir !== "")
lease-unbounded|shell/security/idle/IdleModel.js|    return Math.min(seconds, INHIBIT_MAX_SECONDS) * 1000;|    return seconds * 1000;
client-extra-call|shell/services/LockClient.js|    inhibit: ["idle", "inhibit"]|    inhibit: ["idle", "inhibit"],\n    unlock: ["lock", "unlock"]
EOF
exit "$fail"
