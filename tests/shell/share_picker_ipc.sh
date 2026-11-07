#!/usr/bin/env bash
# ADR-0035 D-6 end to end without a compositor: the stand-in (packaging/session-bin/hyprland-share-picker, a scratch copy
# whose stock picker is a recorder) asks the real SharePicker service through the real `qs ipc`, under the real Quickshell
# (tests/shell/share_picker_ipc.d/probe.qml, offscreen), and the shell answers on the one-time socket. A fake hyprctl gives
# the stand-in Hyprland's displays (the shell's own); the shell's Hyprland socket is a fake that knows nothing.
#   1 the shell accepts, connects, gets xdph's two windows and opens the panel (popup kind sharePicker); the user's choice
#     of the display with Remember this choice reaches xdph as `[SELECTION]r/screen:<display>`;
#   2 a window's choice reaches xdph as `[SELECTION]/window:<handle>`; a second request meanwhile is "busy";
#   3 the shell keeps the stand-in waiting past 15 s while the panel is open (its `wait` lines);
#   4 the stand-in ends while the panel is open: the panel and the request go within 1 s;
#   5 another popup in the panel's place: cancelled (nothing reaches xdph), the stand-in ends;
#   6 the session locks while the panel is open: cancelled; a request while locked: "locked", nothing shows;
#   7 requests not of the stand-in's form (an id that is not 128-bit hex, a socket elsewhere): "refused", nothing shows.
#   8 a request whose socket is not there (a stand-in that gave up): accepted, the connection fails, no panel ever shows,
#     and its socket is gone;
#  13 a failed connection does not poison the next request (review of PR #83, MAJOR 2: on Quickshell 0.3.1 one long-lived
#     Socket never connected again after a failed connection): after case 8, after a socket file nobody listens on, and after
#     a stand-in that gave up because the shell's answer took over 1 s (a slow `qs ipc`: it ran its stock picker), the next
#     request shows its panel and its answer reaches xdph; each request has its own socket, and none is left once it ended.
# The panel's defaults (review of PR #83, MINOR 1; ADR-0035 7-8; owner decision Q14 as amended after the rc6 bug report): in
# case 1 the panel, as the probe loads it, opens with Remember this choice unticked though xdph passed --allow-token (owner
# decision Q14 stands until its amendment is agreed: SharePickerPanel.followAllowToken) and unarmed (Share disabled), and is
# armed after panel.alertArmMs with Remember still unticked; in case 2 (no --allow-token) it opens unticked too.
# Step 7b:
#   9 Selection: an area past its display's logical size is not answered; one inside is `[SELECTION]/region:<display>@x,y,w,h`;
#  10 a window that hides itself from capture (Hyprland's getprop, faked) is greyed and never answered, another window is;
#  12 a request shown while the last one's getprop query is held (gate files): no window is answered while its own answers
#     are not in (not even when the last one's arrive: they are not its), its own query runs when that one ends, then its
#     windows are answered;
#  11 the indicator: with a private PipeWire, a stream made as xdph makes it (share_picker_ipc.d/fake-xdph-stream.c, built
#     as a program of xdph's name) makes the shell count a share, labelled by the one choice it answered just before (older
#     ones expired after 3 s); another program's video node and an audio node of xdph's name are not; the stream ended, the
#     share is gone (skipped without pipewire, pw-cli, a C compiler or libpipewire's headers).
# The probe runs as a dev session (status and choose are dev hooks) and the stand-in reaches it through GRASSFIELD_SHELL_DIR
# (honoured in a dev session only). Nothing here can reach a real Hyprland or shell: HYPRLAND_INSTANCE_SIGNATURE and
# XDG_RUNTIME_DIR point at the test's own directory. Prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
for v in $(compgen -e); do
  case $v in GRASSFIELD_* | QS_*) unset "$v" ;; esac
done
cd "$root"
unset QT_QPA_PLATFORMTHEME
command -v qs >/dev/null || { echo "SKIP: share_picker_ipc: Quickshell (qs) is not installed"; exit 0; }
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
tmp=$(mktemp -d "$root/.dev/share-picker-ipc.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/share-picker-ipc.XXXXXX"; })
fake="" shell="" standin="" runtime=""
cleanup() {
  local p
  for p in $fake $shell $standin ${xdph:-} ${pw:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp" "$runtime"
}
trap cleanup EXIT
sig=gf-share-picker
# The runtime directory is short and of its own: a Unix socket's path holds at most 107 bytes (the picker's channel is
# <runtime>/grassfield/picker/<32 hex>.sock), and the test's directory can be deep in the tree. Under TMPDIR when that is short
# enough (a sandbox may keep /tmp read-only), else /tmp.
runtime_base=${TMPDIR:-/tmp}
((${#runtime_base} + 13 + 56 <= 107)) || runtime_base=/tmp
runtime=$(mktemp -d "$runtime_base/gfspi.XXXXXX")
mkdir -p "$runtime/hypr/$sig" "$tmp/cache" "$tmp/state" "$tmp/config" "$tmp/cfg" "$tmp/bin" "$tmp/fake" "$tmp/stock"
chmod 700 "$runtime" "$tmp/cache"
((${#runtime} + 56 <= 107)) || { echo "FAIL: share_picker_ipc: the runtime directory $runtime is too long for a socket"; exit 1; }
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/share_picker_ipc.d/probe.qml "$tmp/cfg/shell.qml"

# The shell's Hyprland: requests answered with nothing, events held.
cat >"$tmp/fake.py" <<'PY'
import os, socket, sys, threading
base = sys.argv[1]
held = []
def answer(c):
    data = c.recv(65536).decode(errors="replace")
    c.sendall(b"[]" if "j/" in data[:8] else b"ok")
    held.append(c)
def serve(name, handler):
    s = socket.socket(socket.AF_UNIX)
    s.bind(os.path.join(base, name))
    s.listen(16)
    while True:
        c, _ = s.accept()
        threading.Thread(target=handler, args=(c,), daemon=True).start()
threading.Thread(target=serve, args=(".socket2.sock", held.append), daemon=True).start()
serve(".socket.sock", answer)
PY
python3 -I "$tmp/fake.py" "$runtime/hypr/$sig" &
fake=$!
for _ in $(seq 50); do [[ -S $runtime/hypr/$sig/.socket.sock && -S $runtime/hypr/$sig/.socket2.sock ]] && break; sleep 0.1; done

# A private PipeWire, for the indicator (case 11), when it is installed.
pw=""
if command -v pipewire >/dev/null && command -v pw-cli >/dev/null; then
  XDG_RUNTIME_DIR="$runtime" pipewire >"$tmp/pipewire.log" 2>&1 &
  pw=$!
  for _ in $(seq 50); do [[ -S $runtime/pipewire-0 ]] && break; sleep 0.1; done
fi
# hyprctl for the shell and the stand-in: the displays, unlocked; getprop says the window at 0x2000 hides from capture.
mkdir -p "$tmp/fake"
cat >"$tmp/fake/hyprctl" <<'SH'
#!/bin/sh
# Case 12: a getprop that starts while the file gateA (else gateB) is there answers when that file goes, then logs its address.
d=$(dirname "$0")
if [ "$2" = getprop ]; then
  for g in gateA gateB; do
    if [ -e "$d/$g" ]; then
      while [ -e "$d/$g" ]; do sleep 0.05; done
      echo "$3" >>"$d/getprop.done"
      break
    fi
  done
fi
case "$1 $2 $3 $4" in
"-j monitors  ") cat "$(dirname "$0")/monitors.json" ;;
"-j getprop address:0x2000 no_screen_share") echo '{"no_screen_share": true}' ;;
"-j getprop address:0x"*" no_screen_share") echo '{"no_screen_share": false}' ;;
*) exit 1 ;;
esac
SH
chmod +x "$tmp/fake/hyprctl"
# The shell's `timeout 1` on each getprop: no limit while a gate holds them (case 12).
cat >"$tmp/fake/timeout" <<'SH'
#!/bin/sh
d=$(dirname "$0")
if [ -e "$d/gateA" ] || [ -e "$d/gateB" ]; then shift; exec "$@"; fi
exec /usr/bin/timeout "$@"
SH
chmod +x "$tmp/fake/timeout"

base_env=(-u WAYLAND_DISPLAY -u GRASSFIELD_SESSION -u DBUS_SESSION_BUS_ADDRESS -u QS_CONFIG_PATH -u QS_CONFIG_NAME -u QS_MANIFEST
  GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" HYPRLAND_INSTANCE_SIGNATURE="$sig"
  XDG_RUNTIME_DIR="$runtime" XDG_CACHE_HOME="$tmp/cache")
# Qt's offscreen platform names its screen only through its configuration file: two displays, as Hyprland names them.
printf '{"screens": [{"name": "DP-1", "x": 0, "y": 0, "width": 800, "height": 600, "logicalDpi": 96, "dpr": 1},
  {"name": "HDMI-A-1", "x": 800, "y": 0, "width": 640, "height": 480, "logicalDpi": 96, "dpr": 1}]}\n' >"$tmp/screens.json"
env "${base_env[@]}" PATH="$tmp/fake:$PATH" QT_QPA_PLATFORM="offscreen:configfile=$tmp/screens.json" \
  QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" timeout 300 qs -p "$tmp/cfg" --no-color >"$tmp/shell.log" 2>&1 &
shell=$!
for _ in $(seq 150); do grep -q 'picker-probe: ready' "$tmp/shell.log" && break; sleep 0.1; done
ready=$(grep -o 'picker-probe: ready .*' "$tmp/shell.log" | head -1 || true)
display=$(python3 -I -c 'import json, sys; o = json.loads(sys.argv[1].split(" ")[2]); print(o[-1] if o else "")' "$ready" 2>/dev/null || true)
if [[ $ready != 'picker-probe: ready ["DP-1","HDMI-A-1"] idle' ]]; then
  echo "FAIL: share_picker_ipc: the probe shell did not come up idle with a display [$ready]"
  tail -20 "$tmp/shell.log"
  exit 1
fi
ipc() { env "${base_env[@]}" timeout 5 qs ipc -p "$tmp/cfg" call "$@" 2>&1; }
state() { ipc picker status | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(sys.argv[1] % d)' "$1"; }

# The stand-in: its stock pickers are recorders; its hyprctl lists the shell's display, unlocked.
sed "s|^STOCK_DIR = \"/usr/bin\"\$|STOCK_DIR = \"$tmp/stock\"|" packaging/session-bin/hyprland-share-picker >"$tmp/bin/hyprland-share-picker"
chmod +x "$tmp/bin/hyprland-share-picker"
printf '#!/bin/sh\necho ran >"%s/stock.ran"\n' "$tmp" >"$tmp/stock/hyprland-share-picker"
printf '[{"name": "DP-1", "width": 800, "height": 600, "scale": 1, "transform": 0, "solitaryBlockedBy": []},
  {"name": "HDMI-A-1", "width": 640, "height": 480, "scale": 1, "transform": 0, "solitaryBlockedBy": []}]\n' >"$tmp/fake/monitors.json"
chmod +x "$tmp/stock/hyprland-share-picker"
# Two windows with Hyprland addresses (4096 = 0x1000, 8192 = 0x2000: the one that hides from capture).
windows='123456[HC>]org.gnome.TextEditor[HT>]notes.txt[HE>]4096[HA>]777[HC>]firefox[HT>]A page[HE>]8192[HA>]'
share() { # runs the stand-in as xdph does (with --allow-token, as Omarchy's xdph.conf has it, unless told 'no-token'); sets `standin`
  local token=--allow-token
  [[ ${1:-} != no-token ]] || token=""
  rm -f "$tmp/stock.ran" "$tmp/standin.out"
  env "${base_env[@]}" GRASSFIELD_SHELL_DIR="$tmp/cfg" PATH="$tmp/fake:$PATH" XDPH_WINDOW_SHARING_LIST="$windows" \
    "$tmp/bin/hyprland-share-picker" ${token:+"$token"} >"$tmp/standin.out" 2>"$tmp/standin.err" &
  standin=$!
}
shown_within() { local i; for ((i = 0; i < 60; i++)); do [[ $(state '%(shown)s %(popup)s') == "True sharePicker" ]] && return 0; sleep 0.05; done; return 1; }
# No request open and no request socket left (a Socket per request, destroyed with it), within 3 s (the 2 s connection deadline).
gone_within() { local i; for ((i = 0; i < 60; i++)); do [[ $(state '%(open)s %(channels)s') == "False 0" ]] && return 0; sleep 0.05; done; return 1; }
# The panel the probe loaded, as it opened (atOpen) or now: "remember=… armed=… box=… share=…", or "none".
panel() { ipc probe panel | python3 -I -c 'import json, sys; t = sys.stdin.read().strip(); d = None if t == "none" else json.loads(t)[sys.argv[1]]; print("none" if d is None else "remember=%(remember)s armed=%(armed)s box=%(box)s share=%(share)s" % d)' "$1"; }
armed_within() { local i; for ((i = 0; i < 40; i++)); do [[ $(panel now) == *" armed=True "* ]] && return 0; sleep 0.05; done; return 1; }
# No window is answered before Hyprland has said which hide from capture.
known_within() { local i; for ((i = 0; i < 60; i++)); do [[ $(state '%(blocked)s') != None ]] && return 0; sleep 0.05; done; return 1; }
ended_within() { local i; for ((i = 0; i < $2 * 20; i++)); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.05; done; return 1; }
idle_within() { local i; for ((i = 0; i < 20; i++)); do [[ $(state '%(open)s %(shown)s %(popup)s') == "False False " ]] && return 0; sleep 0.05; done; return 1; }

# 1.
share
desc="1 the shell accepts, connects, gets xdph's two windows and opens the panel"
check shown_within
desc="1 the request has its own socket, the only one"
check test "$(state '%(channels)s')" == 1
desc="1 the panel opens with Remember this choice unticked though xdph passed --allow-token (owner decision Q14 until its amendment is agreed), and unarmed, Share disabled"
check test "$(panel atOpen)" == "remember=False armed=False box=False share=False"
desc="1 the panel is armed after panel.alertArmMs, Remember this choice still unticked"
check armed_within
check test "$(panel now)" == "remember=False armed=True box=False share=False"
desc="1 the windows the shell holds are xdph's, with their handles"
check test "$(state '%(windows)s')" == "[{'handle': '123456', 'appId': 'org.gnome.TextEditor', 'title': 'notes.txt', 'address': '1000'}, {'handle': '777', 'appId': 'firefox', 'title': 'A page', 'address': '2000'}]"
desc="1 the user's choice of the display with Remember this choice reaches xdph"
check test "$(ipc picker choose screen "$display" remember)" == ok
ended_within "$standin" 3 || true
check test "$(cat "$tmp/standin.out")" == "[SELECTION]r/screen:$display"
desc="1 the request and the panel are gone, the stock picker never ran, nothing on stderr"
check idle_within
check gone_within
check bash -c '[[ ! -e $1/stock.ran && ! -s $1/standin.err ]]' _ "$tmp"

# 2.
share no-token
shown_within || true
desc="2 without --allow-token the panel opens with Remember this choice unticked and unarmed"
check test "$(panel atOpen)" == "remember=False armed=False box=False share=False"
desc="2 a second request while the panel is open: busy"
check test "$(ipc picker request "$(printf '%032x' 1)" "$runtime/grassfield/picker/$(printf '%032x' 2).sock")" == busy
desc="2 a window's choice reaches xdph as its handle, once Hyprland has said which windows hide from capture"
check known_within
check test "$(ipc picker choose window 123456 no)" == ok
ended_within "$standin" 3 || true
check test "$(cat "$tmp/standin.out")" == "[SELECTION]/window:123456"

# 3.
share
shown_within || true
sleep 16.5
desc="3 the panel open for 16.5 s: the stand-in still waits (the shell's wait lines), the panel still open"
check bash -c 'kill -0 "$1" && [[ ! -s $2/standin.out ]]' _ "$standin" "$tmp"
check test "$(state '%(shown)s %(popup)s')" == "True sharePicker"

# 4.
kill -TERM "$standin"
wait "$standin" 2>/dev/null || true
desc="4 the stand-in ends while the panel is open: the panel and the request go within 1 s"
check idle_within

# 5.
share
shown_within || true
desc="5 another popup in the panel's place: cancelled, nothing reaches xdph, the stand-in ends"
check test "$(ipc probe popup forcequit)" == forcequit
check bash -c 'for ((i = 0; i < 60; i++)); do kill -0 "$1" 2>/dev/null || break; sleep 0.05; done; ! kill -0 "$1" 2>/dev/null && [[ ! -s $2/standin.out && ! -e $2/stock.ran ]]' _ "$standin" "$tmp"
check test "$(state '%(open)s %(shown)s')" == "False False"
ipc probe popup "" >/dev/null || true

# 6.
share
shown_within || true
desc="6 the session locks while the panel is open: cancelled, the panel goes, nothing reaches xdph"
check test "$(ipc probe lock on)" == ok
check bash -c 'for ((i = 0; i < 60; i++)); do kill -0 "$1" 2>/dev/null || break; sleep 0.05; done; ! kill -0 "$1" 2>/dev/null && [[ ! -s $2/standin.out ]]' _ "$standin" "$tmp"
check test "$(state '%(open)s %(shown)s %(popup)s')" == "False False "
desc="6 a request while locked: locked, nothing shows"
check test "$(ipc picker request "$(printf '%032x' 3)" "$runtime/grassfield/picker/$(printf '%032x' 4).sock")" == locked
check test "$(state '%(open)s')" == False
ipc probe lock off >/dev/null

# 7.
desc="7 requests not of the stand-in's form are refused and nothing shows: an id that is not 128-bit hex, a socket elsewhere, a name that is not 128-bit hex"
check test "$(ipc picker request "$(printf '%031x' 5)" "$runtime/grassfield/picker/$(printf '%032x' 6).sock")" == refused
check test "$(ipc picker request "$(printf '%032x' 5)" "$tmp/elsewhere/$(printf '%032x' 6).sock")" == refused
check test "$(ipc picker request "$(printf '%032x' 5)" "$runtime/grassfield/picker/../$(printf '%032x' 6).sock")" == refused
check test "$(ipc picker request "$(printf '%032X' 171)" "$runtime/grassfield/picker/$(printf '%032x' 6).sock")" == refused
check test "$(state '%(open)s')" == False

# 8.
desc="8 a request whose socket is not there (the stand-in gave up): accepted, the connection fails, the panel never shows"
check test "$(ipc picker request "$(printf '%032x' 7)" "$runtime/grassfield/picker/$(printf '%032x' 8).sock")" == accepted
check test "$(state '%(popup)s')" == ""
check idle_within
check test "$(state '%(popup)s')" == ""
desc="8 the failed connection's socket is gone"
check gone_within

# 13.
answered_screen() { # a request after a failed connection: its own socket, its panel, its answer
  share
  shown_within && [[ $(state '%(channels)s') == 1 && $(ipc picker choose screen DP-1 no) == ok ]] || return 1
  ended_within "$standin" 3 || true
  [[ $(cat "$tmp/standin.out") == "[SELECTION]/screen:DP-1" ]] && gone_within
}
desc="13 after case 8's failed connection, the next request shows its panel and its answer reaches xdph; no socket left"
check answered_screen
desc="13 a socket file nobody listens on: accepted, the connection is refused, nothing shows, no socket left"
refused_sock="$runtime/grassfield/picker/$(printf '%032x' 9).sock"
python3 -I -c 'import socket, sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$refused_sock"
check test "$(ipc picker request "$(printf '%032x' 9)" "$refused_sock")" == accepted
check gone_within
check test "$(state '%(shown)s %(popup)s')" == "False "
rm -f "$refused_sock"
desc="13 then a request shows its panel and its answer reaches xdph; no socket left"
check answered_screen
desc="13 a stand-in whose request took over 1 s (a slow qs ipc) runs its stock picker; the shell's late connection leaves nothing"
mkdir -p "$tmp/slow"
printf '#!/bin/sh
%q "$@"
rc=$?
[ "$2" = -p ] && [ "$5" = picker ] && exec sleep 1.5
exit $rc
' "$(command -v qs)" >"$tmp/slow/qs"
chmod +x "$tmp/slow/qs"
rm -f "$tmp/stock.ran" "$tmp/standin.out"
env "${base_env[@]}" GRASSFIELD_SHELL_DIR="$tmp/cfg" PATH="$tmp/slow:$tmp/fake:$PATH" XDPH_WINDOW_SHARING_LIST="$windows" \
  "$tmp/bin/hyprland-share-picker" --allow-token >"$tmp/standin.out" 2>"$tmp/standin.err" &
standin=$!
ended_within "$standin" 5 || true
check bash -c '[[ -e $1/stock.ran && ! -s $1/standin.out ]]' _ "$tmp"
check gone_within
check test "$(state '%(shown)s %(popup)s')" == "False "
desc="13 then a request shows its panel and its answer reaches xdph; no socket left"
check answered_screen

# 9.
share
shown_within || true
desc="9 Selection: an area past its display's logical size (640 x 480) is not answered, the panel stays"
check test "$(ipc picker choose region "HDMI-A-1@0,0,700,500" no)" == ok
sleep 0.5
check bash -c 'kill -0 "$1" && [[ ! -s $2/standin.out ]]' _ "$standin" "$tmp"
check test "$(state '%(shown)s')" == True
desc="9 an area inside it reaches xdph as the region of that display"
check test "$(ipc picker choose region "HDMI-A-1@10,20,300,200" no)" == ok
ended_within "$standin" 3 || true
check test "$(cat "$tmp/standin.out")" == "[SELECTION]/region:HDMI-A-1@10,20,300,200"

# 10.
blocked_within() { local i; for ((i = 0; i < 60; i++)); do [[ $(state '%(blocked)s') == "['777']" ]] && return 0; sleep 0.05; done; return 1; }
share
shown_within || true
desc="10 the window at 0x2000 hides itself from capture (Hyprland's getprop): the shell marks it"
check blocked_within
desc="10 its choice is not answered; another window's is"
check test "$(ipc picker choose window 777 no)" == ok
sleep 0.5
check bash -c 'kill -0 "$1" && [[ ! -s $2/standin.out ]]' _ "$standin" "$tmp"
check test "$(ipc picker choose window 123456 no)" == ok
ended_within "$standin" 3 || true
check test "$(cat "$tmp/standin.out")" == "[SELECTION]/window:123456"

# 12.
done_count() { if [[ -e $tmp/fake/getprop.done ]]; then wc -l <"$tmp/fake/getprop.done"; else echo 0; fi; }
not_answered() { sleep 0.5; kill -0 "$standin" && [[ ! -s $tmp/standin.out ]]; }
rm -f "$tmp/fake/getprop.done"
touch "$tmp/fake/gateA" "$tmp/fake/gateB"
share
shown_within || true
ipc picker choose screen DP-1 no >/dev/null
ended_within "$standin" 3 || true
share
shown_within || true
desc="12 a request shown while the last one's query is held: its windows are not known"
check test "$(state '%(blocked)s')/$(done_count)" == "None/0"
desc="12 a window chosen meanwhile is not answered, the protected one or not"
check test "$(ipc picker choose window 777 no)/$(ipc picker choose window 123456 no)" == ok/ok
check not_answered
desc="12 the last request's answers arrive: they are not this one's, its windows are still not known"
rm -f "$tmp/fake/gateA"
for ((i = 0; i < 60; i++)); do (($(done_count) >= 2)) && break; sleep 0.05; done
sleep 0.3
check test "$(state '%(blocked)s')/$(done_count)" == "None/2"
check test "$(ipc picker choose window 123456 no)" == ok
check not_answered
desc="12 its own query runs after that one, and marks its windows"
rm -f "$tmp/fake/gateB"
known_within || true
check test "$(state '%(blocked)s')/$(done_count)" == "['777']/4"
check test "$(ipc picker choose window 123456 no)" == ok
ended_within "$standin" 3 || true
check test "$(cat "$tmp/standin.out")" == "[SELECTION]/window:123456"

# 11.
# The stream as xdph makes it, from a program of xdph's name (share_picker_ipc.d/fake-xdph-stream.c): PipeWire gives its node
# the program's name and keeps the stream's own name in media.name.
xdph_bin=""
if [[ -n $pw ]] && command -v cc >/dev/null && pkg-config --exists libpipewire-0.3 2>/dev/null; then
  mkdir -p "$tmp/xdph"
  # shellcheck disable=SC2046 # pkg-config's flags are words
  cc -O1 -o "$tmp/xdph/xdg-desktop-portal-hyprland" tests/shell/share_picker_ipc.d/fake-xdph-stream.c \
    $(pkg-config --cflags --libs libpipewire-0.3) 2>"$tmp/xdph/cc.log" && xdph_bin="$tmp/xdph/xdg-desktop-portal-hyprland"
fi
if [[ -n $xdph_bin ]]; then
  streams_are() { local i; for ((i = 0; i < 60; i++)); do [[ $(state '%(streams)s') == "$1" ]] && return 0; sleep 0.05; done; return 1; }
  pwcli() { XDG_RUNTIME_DIR="$runtime" timeout 5 pw-cli "$@" 2>&1; }
  desc="11 no stream of xdph: no share"
  check streams_are 0
  desc="11 another program's video node and an audio node are no share"
  pwcli create-node adapter '{ factory.name=support.null-audio-sink node.name=chromium media.class=Video/Source object.linger=true }' >/dev/null
  pwcli create-node adapter '{ factory.name=support.null-audio-sink node.name=xdg-desktop-portal-hyprland media.class=Audio/Sink object.linger=true }' >/dev/null
  sleep 0.5
  check streams_are 0
  desc="11 a stream made as xdph makes it: one share, labelled by the one choice answered just before it (older ones expired)"
  sleep 3.5
  share
  shown_within || true
  ipc picker choose screen DP-1 no >/dev/null
  ended_within "$standin" 3 || true
  XDG_RUNTIME_DIR="$runtime" "$xdph_bin" xdph-streaming-test1 >"$tmp/xdph/run.log" 2>&1 &
  xdph=$!
  check streams_are 1
  check test "$(ipc picker status | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(list(d["labels"].values()))')" == "[{'kind': 'screen', 'value': 'DP-1', 'title': ''}]"
  desc="11 the stream ends: no share, no label"
  kill "$xdph"
  wait "$xdph" 2>/dev/null || true
  check streams_are 0
  check test "$(state '%(labels)s')" == "{}"
else
  echo "SKIP: 11 the indicator needs pipewire, pw-cli, a C compiler and libpipewire's headers"
fi

if ((fail)); then tail -20 "$tmp/shell.log"; fi
exit $fail
