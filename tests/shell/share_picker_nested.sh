#!/usr/bin/env bash
# Nested scenario (L1) for the screen-sharing picker (ADR-0035 D-6, step 7a; docs/specs/system-dialogs.md section 3). Bare
# command, nested session only. xdph is the real session's and is not run here: the test runs the repository's stand-in as
# xdph would (the window list in XDPH_WINDOW_SHARING_LIST: one foot window, app id gf-share, with its Hyprland address), with
# this nested instance's signature, and the stand-in asks the nested dev shell through GRASSFIELD_SHELL_DIR (dev plumbing).
# Checks:
#   1 the shell shows the panel on the nested display (`picker status`, a dev hook: shown, popup kind sharePicker, the window
#     listed); the test then waits SHARE_PICKER_LOOK seconds (default 0) for a screenshot (`just shot`) or a look;
#   2 the user's choice of the window (made with `picker choose`, as the panel's Share does) is what xdph reads:
#     `[SELECTION]/window:<handle>`;
#   3 Entire Screen with Remember this choice: `[SELECTION]r/screen:<the nested display>`;
#   4 the stand-in killed while the panel is open (xdph gave up): the panel goes within 1 s;
#   5 (step 7b) Selection: an area of the nested display is what xdph reads, `[SELECTION]/region:<display>@x,y,w,h`; an area
#     past the display is not answered.
# The panel's look (live thumbnails, both appearances, French), Esc, Return and a click, dragging an area on the Selection
# tab's preview, and the menu bar's screen-sharing indicator (a real share: Chromium's "Share screen") are the integrator's,
# by hand while step 1 waits. The test closes the window it opened. Only this tree's nested instance (scripts/dev/pidfile.sh); hyprctl is
# read-only; clients get the nested socket only.
# Never the live shell (review of PR #83, MINOR 3: run from a Grassfield session, the inherited GRASSFIELD_SESSION=1 made the
# stand-in ask /usr/share/grassfield/shell, the owner's live shell, and its stock pickers opened on the nested display): every
# GRASSFIELD_* and QS_* variable is dropped once the nested session is validated; the stand-in gets only GRASSFIELD_DEV=1 and
# GRASSFIELD_SHELL_DIR=<this tree>/shell; before each request the test refuses (exit 2) unless the one Quickshell instance of
# that config is this tree's nested shell, and the stand-in is a scratch copy whose stock picker only records that it ran
# (a check fails if it did).
# Expected: "share_picker: 0 failure(s)" after PASS lines for every check. Exit 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "SKIP share_picker_nested: no nested session of this tree (scripts/dev/nested-up.sh, as a bare command)"; exit 0; }
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
main=$(cat "$dev/main.instance" 2>/dev/null || true)
[[ $sig != "$main" && $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "share_picker: refusing the main session"; exit 2; }
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "share_picker: grassfield-shell is not running (scripts/dev/shell-run.sh)"; exit 2; }
command -v foot >/dev/null && command -v jq >/dev/null || { echo "share_picker: foot and jq are needed"; exit 2; }
# Nothing of the session this runs from routes a request: no GRASSFIELD_SESSION (the stand-in would ask the installed shell),
# no GRASSFIELD_SHELL_DIR of another tree, no Quickshell config variable.
for v in $(compgen -e); do
  case $v in GRASSFIELD_* | QS_*) unset "$v" ;; esac
done
target=$root/shell
# The stand-in asks `qs ipc -p <its shell directory>`, and Quickshell picks an instance of that config by path, on any
# display: the directory must be this tree's and its one instance this tree's nested shell.
guard() {
  local pids
  [[ $(realpath -m "$target") != "$(realpath -m /usr/share/grassfield/shell)" ]] || { echo "share_picker: refusing: $target is the installed shell"; exit 2; }
  # Every display's instances: Quickshell 0.3.2's `list -p` shows only those on the caller's display, and this runs from another
  # one (the nested shell's never showed, so the guard always refused).
  pids=$(qs list --all -j 2>/dev/null | python3 -I -c 'import json, os, sys; want = os.path.realpath(sys.argv[1]); print(" ".join(sorted({str(i["pid"]) for i in json.load(sys.stdin) if os.path.dirname(os.path.realpath(i.get("config_path", ""))) == want})))' "$target" 2>/dev/null)
  [[ $pids == "$shell_pid" ]] || { echo "share_picker: refusing: the stand-in would reach Quickshell instances [$pids] of $target, not only this tree's nested shell (PID $shell_pid)"; exit 2; }
}
guard

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
hq() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$@"; }
ipc() { WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 qs ipc --pid "$shell_pid" call picker "$@" 2>/dev/null; }
wait_for() { local secs=$1 n; shift; for ((n = 0; n < secs * 5; n++)); do "$@" && return 0; sleep 0.2; done; return 1; }
[[ $(ipc status) == "{"* ]] || { echo "share_picker: the dev shell has no picker target or refused its status (run this tree's shell)"; exit 2; }

foot_pid=""
standin=""
tmp=$(mktemp -d)
# A scratch copy of the stand-in whose stock picker only records that it ran: a request the nested shell did not answer never
# opens a real picker, on any display.
mkdir -p "$tmp/stock"
sed "s|^STOCK_DIR = \"/usr/bin\"\$|STOCK_DIR = \"$tmp/stock\"|" "$root/packaging/session-bin/hyprland-share-picker" >"$tmp/hyprland-share-picker"
grep -qx "STOCK_DIR = \"$tmp/stock\"" "$tmp/hyprland-share-picker" || { echo "share_picker: the stand-in's stock picker could not be diverted"; rm -rf "$tmp"; exit 2; }
chmod +x "$tmp/hyprland-share-picker"
for name in hyprland-share-picker hyprland-preview-share-picker; do
  printf '#!/bin/sh\necho %s >>"%s/stock.ran"\n' "$name" "$tmp" >"$tmp/stock/$name"
  chmod +x "$tmp/stock/$name"
done
cleanup() {
  [[ -n $standin ]] && kill "$standin" 2>/dev/null
  [[ -n $foot_pid ]] && kill "$foot_pid" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot --app-id gf-share --title "Shared window" >/dev/null 2>&1 </dev/null &
foot_pid=$!
address=""
for ((n = 0; n < 30; n++)); do
  sleep 0.2
  address=$(hq clients | jq -r '[.[] | select(.class == "gf-share") | .address] | first // empty')
  [[ -n $address ]] && break
done
[[ -n $address ]] || { echo "share_picker: the foot window did not appear"; exit 2; }
display=$(hq monitors | jq -r '.[0].name')
handle=4242
list="${handle}[HC>]gf-share[HT>]Shared window[HE>]$(printf '%d' "$address")[HA>]"

share() { # runs the stand-in as xdph does, at this tree's nested shell only; sets `standin`
  guard
  : >"$tmp/out"
  env -u GRASSFIELD_SESSION WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" GRASSFIELD_DEV=1 GRASSFIELD_SHELL_DIR="$target" \
    XDPH_WINDOW_SHARING_LIST="$list" "$tmp/hyprland-share-picker" --allow-token >"$tmp/out" 2>/dev/null &
  standin=$!
}
shown() { [[ $(ipc status | jq -r '"\(.shown) \(.popup) \(.windows | map(.handle) | join(","))"') == "true sharePicker $handle" ]]; }
sources() { ipc status | jq -r '.sources'; }
idle() { [[ $(ipc status | jq -r '"\(.open) \(.shown)"') == "false false" ]]; }
answered() { ! kill -0 "$standin" 2>/dev/null; }

# 1.
share
if wait_for 5 shown; then pass "1 the panel is shown on the nested display with the window xdph listed"; else fail "1 the panel did not show [$(ipc status)]"; fi
if [[ $(sources) == 1 ]]; then pass "1 the window's live thumbnail has its source (the toplevel at its address)"; else fail "1 no capture source for the window [$(ipc status)]"; fi
# The rc6 fix: xdph's --allow-token reaches the shell (the panel opens Remember this choice from it once followAllowToken is true).
if [[ $(ipc status | jq -r '.allowToken') == true ]]; then pass "1 the shell got xdph's --allow-token"; else fail "1 allowToken [$(ipc status | jq -c '.allowToken')]"; fi
sleep "${SHARE_PICKER_LOOK:-0}"

# 2. No window is answered before Hyprland has said which hide from capture (its getprop answers).
known() { ipc status | jq -e '.blocked != null' >/dev/null; }
wait_for 3 known || fail "2 Hyprland's answers on the windows did not arrive [$(ipc status)]"
[[ $(ipc choose window "$handle" no) == ok ]] && wait_for 3 answered
out=$(cat "$tmp/out")
if [[ $out == "[SELECTION]/window:$handle" ]]; then pass "2 the window's choice is what xdph reads [$out]"; else fail "2 the window's choice [$out]"; fi
wait_for 2 idle || fail "2 the panel stayed open"

# 3.
share
wait_for 5 shown
[[ $(ipc choose screen "$display" remember) == ok ]] && wait_for 3 answered
out=$(cat "$tmp/out")
if [[ $out == "[SELECTION]r/screen:$display" ]]; then pass "3 Entire Screen with Remember this choice [$out]"; else fail "3 Entire Screen [$out]"; fi

# 4.
share
wait_for 5 shown
kill -TERM "$standin"
if wait_for 1 idle; then pass "4 the stand-in killed while the panel is open: the panel goes within 1 s"; else fail "4 the panel stayed [$(ipc status)]"; fi
standin=""

# 5.
share
wait_for 5 shown
size=$(hq monitors | jq -r '.[0] | "\((.width / .scale) | floor) \((.height / .scale) | floor)"')
w=${size% *} h=${size#* }
[[ $(ipc choose region "$display@$((w - 1)),0,2,2" no) == ok ]]
sleep 0.5
if kill -0 "$standin" 2>/dev/null; then pass "5 an area past the display's edge is not answered"; else fail "5 an area past the display was answered [$(cat "$tmp/out")]"; fi
[[ $(ipc choose region "$display@10,10,$((w / 2)),$((h / 2))" no) == ok ]] && wait_for 3 answered
out=$(cat "$tmp/out")
if [[ $out == "[SELECTION]/region:$display@10,10,$((w / 2)),$((h / 2))" ]]; then pass "5 an area of the display is what xdph reads [$out]"; else fail "5 the area [$out]"; fi

if [[ -e $tmp/stock.ran ]]; then fail "a request reached no shell: the stand-in ran its stock picker [$(tr '\n' ' ' <"$tmp/stock.ran")]"; else pass "the stand-in never fell back to its stock picker"; fi

echo "share_picker: $fails failure(s)"
((fails == 0))
