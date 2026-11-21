#!/usr/bin/env bash
# The lock state's heartbeat and its stale bound hold in real time whatever the processes draw (owner's report of 2026-11-21:
# "no beat from the security process for 5 s ... the session reads locked" after each shell restart and while the idle dim
# faded in, the security process being healthy; the idle lock announced "in 10 s" came after 17 s).
# Cause: a QML Timer is synchronized with the scene graph's animation clock; with the threaded render loop (every Wayland
# session) that clock advances one vsync per frame and never catches up a late frame, so in a process that draws late frames a
# 2 s Timer fires every ~9 s. The beat (LockPublisher) and the UI's stale check (LockClient) now run on shell/security/lock/RealTimer.qml /
# a 250 ms Timer tick with a monotonic ElapsedTimer (never Quickshell's SystemClock).
#   A  the REAL LockPublisher in a process with late frames (Stall.qml, QSG_RENDER_LOOP=threaded): read from outside, the
#      longest real gap between two beats stays well under LockState.STALE_MS (5 s): at most 3.5 s. Before: about 9 s.
#   B  the REAL LockClient in a process with late frames, beats written from outside every 2 s for 12 s: never stale (no false
#      "locked"); then the beats stop: stale (locked) within STALE_MS + 1.5 s of the last beat in real time (fail closed).
#      Before: the stale check came about 20 s after the last beat.
# Offscreen, XDG_RUNTIME_DIR in a scratch directory under .dev/, no compositor. PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/lock-beat.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
d=tests/security/lock_beat_realtime.d
# The shell tree under test (LOCK_BEAT_SHELL: another checkout's shell/, to show the failure before the fix).
shell_root=${LOCK_BEAT_SHELL:-$root/shell}

tree() { # <dir> <probe>
  local dir=$1 entry name
  mkdir -p "$dir/runtime" "$dir/home" "$dir/cfg"
  chmod 700 "$dir/runtime"
  # Every module of the shell (Quickshell's scanner follows the services' imports), the shell's two roots aside.
  for entry in "$shell_root"/*; do
    name=$(basename "$entry")
    [[ $name == shell.qml || $name == security.qml ]] || ln -s "$entry" "$dir/cfg/$name"
  done
  cp "$d/Stall.qml" "$dir/cfg/Stall.qml"
  cp "$d/$2" "$dir/cfg/shell.qml"
}

start() { # <dir>: the probe in the background, its pid in $qs_pid
  local dir=$1
  env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION \
    GRASSFIELD_DEV=1 HOME="$dir/home" XDG_RUNTIME_DIR="$dir/runtime" XDG_CACHE_HOME="$dir/home/.cache" \
    GRASSFIELD_STATE_HOME="$dir/home/state" GRASSFIELD_CONFIG_HOME="$dir/home/config" \
    QT_QPA_PLATFORM=offscreen QSG_RENDER_LOOP=threaded QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
    timeout 60 qs -p "$dir/cfg" --no-color >"$dir/log" 2>&1 &
  qs_pid=$!
}

# ---- A: the publisher ----
tree "$tmp/pub" publisher.qml
start "$tmp/pub"
state="$tmp/pub/runtime/grassfield-lock-state-default"
gap=$(python3 -I - "$state" <<'PY'
import json, sys, time
path = sys.argv[1]
deadline = time.monotonic() + 20
seen, last_seq, first = [], None, None
while time.monotonic() < deadline:
    try:
        with open(path) as f:
            seq = json.loads(f.read()).get("seq")
    except (OSError, ValueError):
        seq = None
    if seq is not None and seq != last_seq:
        now = time.monotonic()
        if first is None:
            first = now
        seen.append(now)
        last_seq = seq
    time.sleep(0.05)
# The first 3 s are the start (the window's first frames); the gaps after it are the beat.
beats = [t for t in seen if first is not None and t - first > 3]
gaps = [b - a for a, b in zip(beats, beats[1:])]
print("%d %d" % (round(max(gaps) * 1000) if gaps else -1, len(beats)))
PY
)
kill "$qs_pid" 2>/dev/null || true
wait "$qs_pid" 2>/dev/null || true
max=${gap% *} count=${gap#* }
if [[ $max -gt 0 && $max -le 3500 && $count -ge 5 ]]; then
  echo "PASS: lock beat: the security process's beat stays on time while it draws late frames (longest gap ${max} ms over $count beats, bound 3500 ms; LockState.STALE_MS 5000)"
else
  echo "FAIL: lock beat: the beat falls behind while the process draws late frames (longest gap ${max} ms over $count beats; it must stay under 3500 ms, the UI reads locked past 5000)"
  grep -E "ERROR|WARN" "$tmp/pub/log" | grep -v -E 'quickshell\.(ipc|paths|tooling|logging)|window masks' | head -n 5 || true
  fail=1
fi

# ---- B: the client ----
tree "$tmp/cli" client.qml
state="$tmp/cli/runtime/grassfield-lock-state-default"
start "$tmp/cli"
result=$(python3 -I - "$state" <<'PY'
import json, os, sys, time
path = sys.argv[1]
def write(seq):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(json.dumps({"v": 1, "state": "unlocked", "seq": seq, "writer": 4242, "displaysOff": False, "motion": {}}) + "\n")
    os.replace(tmp, path)
seq = 0
time.sleep(2)
start = time.monotonic()
while time.monotonic() - start < 12:
    seq += 1
    write(seq)
    last = time.time()
    time.sleep(2)
print("%d" % round(last * 1000))
time.sleep(14)
PY
)
kill "$qs_pid" 2>/dev/null || true
wait "$qs_pid" 2>/dev/null || true
last=$result
# The stale changes the client saw, in its own wall time: "lock-beat: stale <bool> at <ms>".
mapfile -t changes < <(grep -oE 'lock-beat: stale (true|false) at [0-9]+' "$tmp/cli/log" || true)
fresh_at="" false_stale="" stale_at=""
for c in "${changes[@]}"; do
  v=$(awk '{print $3}' <<<"$c") at=$(awk '{print $5}' <<<"$c")
  if [[ $v == false ]]; then
    fresh_at=${fresh_at:-$at}
  elif [[ -n $fresh_at && $at -le $((last + 2000)) ]]; then
    false_stale=$at
  elif [[ -n $fresh_at && -z $stale_at ]]; then
    stale_at=$at
  fi
done
if [[ -z $fresh_at ]]; then
  echo "FAIL: lock beat: the client never read the beats as fresh ($(grep -E 'ERROR|WARN' "$tmp/cli/log" | head -n 3 | tr '\n' ' '))"
  fail=1
elif [[ -n $false_stale ]]; then
  echo "FAIL: lock beat: the client read a healthy writer as stale while it drew late frames (at $((false_stale - last)) ms from the last beat)"
  fail=1
elif [[ -z $stale_at ]]; then
  echo "FAIL: lock beat: the beats stopped and the client never read stale within 14 s (fail closed)"
  fail=1
elif [[ $((stale_at - last)) -le 6500 ]]; then
  echo "PASS: lock beat: no false stale while beats came; stale $((stale_at - last)) ms after the last beat (bound 6500 ms) while the client drew late frames"
else
  echo "FAIL: lock beat: the client read stale only $((stale_at - last)) ms after the last beat (bound 6500 ms): the stale check follows the animation clock"
  fail=1
fi
exit "$fail"
