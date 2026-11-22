#!/usr/bin/env bash
# GF-024 / A11Y-04, macOS model: what the focused window receives for the forwarded keys of config/hypr/grassfield/forwarding.lua.
# NESTED only (scripts/dev/nested-up.sh); never the owner's session. Keys are typed with tests/tools/vkbd (real modifier presses, through
# the nested compositor's keybind path); a Qt window (tests/compositor/forward-keys-fixture) logs what it receives, a foot
# window (a terminal class) records the bytes it receives.
#
#   Alt+Left / Alt+Right                      -> Ctrl+Left / Ctrl+Right        (word navigation in an ordinary application)
#   Alt+Shift+Left                            -> Ctrl+Shift+Left               (select by word)
#   Alt+Backspace                             -> Ctrl+Backspace                (delete the previous word)
#   Super+1 .. Super+9                        -> Ctrl+1 .. Ctrl+9            (Command+number)
#   Super+Up/Down, Left/Right (+Shift), Backspace -> Ctrl+Home/End, Home/End (+Shift), Shift+Home then Backspace
#   Super+[ / Super+]                         -> Alt+Left / Alt+Right          (Back / Forward)
#   Super+C/V/X/A/Z, Super+Shift+Z            -> Ctrl+C/V/X/A/Z, Ctrl+Shift+Z  (Copy, Paste, Cut, Select All, Undo, Redo), end to end
#                                                in the fixture's text field with wl-copy / wl-paste on the nested display
#   Ctrl+Left, Ctrl+1                         -> consumed (Spaces): the application receives nothing
#   in a terminal (foot): Alt+Left stays Alt+Left (bytes ESC [ 1 ; 3 D)
# If a `code:` key (Super+digit) fails here but the Alt+arrow lines pass, Hyprland's send_key_state does not take keycodes.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "forward_keys: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
for tool in jq foot qs; do
  command -v "$tool" >/dev/null || { echo "forward_keys: $tool is needed" >&2; exit 2; }
done

nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
run=$dev/forward-keys/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
fixlog=$run/fixture.log
cap=$run/foot.cap
fail=0
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
check() { # <description> <expected line regex> <log-line-count-before>
  local got
  got=$(tail -n +"$(($3 + 1))" "$fixlog" | real_keys | tail -n 1)
  if [[ -n $got && $got =~ $2 ]]; then echo "PASS: $1 ($got)"; else echo "FAIL: $1 (expected $2, got: ${got:-nothing})"; fail=1; fi
}
nothing() { # <description> <log-line-count-before>
  if [[ -z $(tail -n +"$(($2 + 1))" "$fixlog" | real_keys) ]]; then echo "PASS: $1 (the application received nothing)"; else echo "FAIL: $1 (it received a key)"; fail=1; fi
}
# Keys come from the virtual keyboard tests/tools/vkbd with real modifier presses: wtype -M modifiers never run Hyprland binds in
# the nested session (docs/specs/compositor.md). The wtype-style arguments of the calls below are translated: -M MOD (down),
# -k KEY (tap), -m MOD (up).
keys() {
  local args=() mod
  while (($#)); do
    case $1 in
      -M | -m)
        case $2 in alt) mod=Alt_L ;; shift) mod=Shift_L ;; logo) mod=Super_L ;; ctrl) mod=Control_L ;; *) echo "keys: bad modifier $2" >&2; return 2 ;; esac
        if [[ $1 == -M ]]; then args+=(down "$mod"); else args+=(up "$mod"); fi
        shift 2 ;;
      -k) args+=(tap "$2"); shift 2 ;;
      *) echo "keys: bad argument $1" >&2; return 2 ;;
    esac
  done
  timeout 10 "$root/tests/tools/vkbd/vkbd.sh" "${args[@]}" >>"$run/keys.log" 2>&1
  sleep 0.4
}
# Key presses of the modifiers themselves (Shift, Control, Meta, Alt, AltGr, Super_L/R) are not what is being checked.
real_keys() { grep "\[fk-fixture\] key=" | grep -Ev "key=(1677724[89]|1677725[0-3]|1677729[89]|16777300|16781571) "; }
lines() { wc -l <"$fixlog"; }

WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig setsid "$root/scripts/dev/isolated.sh" --name forward-keys-fixture \
  qs -p "$root/tests/compositor/forward-keys-fixture" --no-color >"$fixlog" 2>&1 </dev/null &
pids+=($!)
for _ in $(seq 1 60); do grep -q "\[fk-fixture\] mapped" "$fixlog" && break; sleep 0.1; done
grep -q "\[fk-fixture\] mapped" "$fixlog" || { echo "forward_keys: the fixture window did not map (see $fixlog)" >&2; exit 2; }
sleep 0.8

ALT=134217728 CTRL=67108864 SHIFT=33554432
n=$(lines); keys -M alt -k Left -m alt;                      check "Alt+Left -> Ctrl+Left" "key=16777234 mods=$CTRL " "$n"
n=$(lines); keys -M alt -k Right -m alt;                     check "Alt+Right -> Ctrl+Right" "key=16777236 mods=$CTRL " "$n"
n=$(lines); keys -M alt -M shift -k Left -m shift -m alt;    check "Alt+Shift+Left -> Ctrl+Shift+Left" "key=16777234 mods=$((CTRL + SHIFT)) " "$n"
n=$(lines); keys -M alt -k BackSpace -m alt;                 check "Alt+Backspace -> Ctrl+Backspace" "key=16777219 mods=$CTRL " "$n"
n=$(lines); keys -M logo -k bracketleft -m logo;             check "Super+[ -> Alt+Left" "key=16777234 mods=$ALT " "$n"
n=$(lines); keys -M logo -k bracketright -m logo;            check "Super+] -> Alt+Right" "key=16777236 mods=$ALT " "$n"
n=$(lines); keys -M logo -k Up -m logo;                      check "Super+Up -> Ctrl+Home (not Files)" "key=16777232 mods=$CTRL " "$n"
n=$(lines); keys -M logo -k Down -m logo;                    check "Super+Down -> Ctrl+End" "key=16777233 mods=$CTRL " "$n"
n=$(lines); keys -M logo -k Left -m logo;                    check "Super+Left -> Home" "key=16777232 mods=0 " "$n"
n=$(lines); keys -M logo -k Right -m logo;                   check "Super+Right -> End" "key=16777233 mods=0 " "$n"
n=$(lines); keys -M logo -M shift -k Right -m shift -m logo; check "Super+Shift+Right -> Shift+End" "key=16777233 mods=$SHIFT " "$n"
n=$(lines); keys -M logo -M shift -k Up -m shift -m logo;    check "Super+Shift+Up -> Ctrl+Shift+Home" "key=16777232 mods=$((CTRL + SHIFT)) " "$n"
# Command+Backspace is two chords: Shift+Home, then Backspace (16777219, no modifier).
n=$(lines); keys -M logo -k BackSpace -m logo;               check "Super+Backspace ends with Backspace (after Shift+Home)" "key=16777219 mods=0 " "$n"
if [[ $(tail -n +"$((n + 1))" "$fixlog" | grep -c "key=16777232 mods=$SHIFT ") -ge 1 ]]; then echo "PASS: Super+Backspace first selected to the line start (Shift+Home)"; else echo "FAIL: Super+Backspace did not send Shift+Home first (sequencing unreliable: drop that bind)"; fail=1; fi
# Command+A/C/X/V/Z end to end: the fixture's text field is reset to "grass" first; the clipboard is the nested display's.
edit() { tail -n +"$(($1 + 1))" "$fixlog" | grep -F "[fk-fixture] edit=" | tail -n 1; }
clip() { WAYLAND_DISPLAY=$sock timeout 5 wl-paste --no-newline 2>/dev/null; }
keys -M logo -k a -m logo; for c in g r a s s; do keys -k "$c"; done  # the fixture field now reads "grass"
n=$(lines); keys -M logo -k a -m logo;                       check "Super+A -> Ctrl+A" "key=65 mods=$CTRL " "$n"
n=$(lines); keys -M logo -k c -m logo;                       check "Super+C -> Ctrl+C" "key=67 mods=$CTRL " "$n"
if [[ $(clip) == "grass" ]]; then echo "PASS: Super+A then Super+C copied the whole text to the clipboard"; else echo "FAIL: clipboard after Super+A, Super+C: '$(clip)'"; fail=1; fi
printf pasted | WAYLAND_DISPLAY=$sock wl-copy
n=$(lines); keys -M logo -k v -m logo;                       check "Super+V -> Ctrl+V" "key=86 mods=$CTRL " "$n"
if [[ $(edit "$n") == *'edit="pasted"'* ]]; then echo "PASS: Super+V replaced the selection with the clipboard (text is now 'pasted')"; else echo "FAIL: Super+V did not paste (edit: $(edit "$n"))"; fail=1; fi
n=$(lines); keys -M logo -k z -m logo;                       check "Super+Z -> Ctrl+Z" "key=90 mods=$CTRL " "$n"
if [[ $(edit "$n") == *'edit="grass"'* ]]; then echo "PASS: Super+Z undid the paste (text is 'grass' again)"; else echo "FAIL: Super+Z did not undo (edit: $(edit "$n"))"; fail=1; fi
n=$(lines); keys -M logo -M shift -k z -m shift -m logo;     check "Super+Shift+Z -> Ctrl+Shift+Z" "key=90 mods=$((CTRL + SHIFT)) " "$n"
if [[ $(edit "$n") == *'edit="pasted"'* ]]; then echo "PASS: Super+Shift+Z redid the paste"; else echo "FAIL: Super+Shift+Z did not redo (edit: $(edit "$n"))"; fail=1; fi
keys -M logo -k a -m logo
n=$(lines); keys -M logo -k x -m logo;                       check "Super+X -> Ctrl+X" "key=88 mods=$CTRL " "$n"
if [[ $(clip) == "pasted" && $(edit "$n") == *'edit=""'* ]]; then echo "PASS: Super+X moved the text to the clipboard"; else echo "FAIL: Super+X: clipboard '$(clip)', edit $(edit "$n")"; fail=1; fi
for d in 1 2 3 4 5 6 7 8 9; do
  n=$(lines); keys -M logo -k "$d" -m logo;                  check "Super+$d -> Ctrl+$d" "key=$((48 + d)) mods=$CTRL " "$n"
done
# Spaces keep Ctrl+arrows and Ctrl+digits: the window must not see them (and the Space is put back).
n=$(lines); keys -M ctrl -k Right -m ctrl;                   nothing "Ctrl+Right switches the Space, not delivered" "$n"
keys -M ctrl -k Left -m ctrl
n=$(lines); keys -M ctrl -k 2 -m ctrl;                       nothing "Ctrl+2 switches to Space 2, not delivered" "$n"
keys -M ctrl -k 1 -m ctrl

# A terminal keeps its Alt+arrows: foot writes the raw bytes it gets to a file.
: >"$cap"
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name forward-keys-foot foot -e sh -c 'stty raw -echo; exec cat -v >"$0"' "$cap" \
  >/dev/null 2>&1 </dev/null &
pids+=($!)
sleep 1.5
keys -M alt -k Left -m alt
if grep -qF '^[[1;3D' "$cap"; then echo "PASS: in a terminal Alt+Left stays Alt+Left ($(cat "$cap"))"; else echo "FAIL: terminal got: $(cat "$cap")"; fail=1; fi

# Paste in a terminal is Ctrl+Shift+V (foot's own paste): Super+V pastes the clipboard into it, as raw bytes.
: >"$cap"
printf 'from-clipboard' | WAYLAND_DISPLAY=$sock wl-copy
keys -M logo -k v -m logo
if grep -qF 'from-clipboard' "$cap"; then echo "PASS: in a terminal Super+V pastes the clipboard ($(cat "$cap"))"; else echo "FAIL: terminal Super+V got: $(cat "$cap")"; fail=1; fi
# Copy in a terminal is Ctrl+Shift+C (foot copies its selection): Ctrl+C must NOT reach it as an interrupt (byte ^C).
: >"$cap"
keys -M logo -k c -m logo
if grep -qF '^C' "$cap"; then echo "FAIL: terminal Super+C sent Ctrl+C ($(cat "$cap"))"; fail=1; else echo "PASS: in a terminal Super+C does not send Ctrl+C (interrupt)"; fi
# Cut, Select All, Undo and Redo do nothing in a terminal (macOS Terminal model): no ^X, ^A, ^Z reach it (the raw byte capture covers Ctrl+Z suspending a job: that is the byte ^Z)
: >"$cap"
keys -M logo -k x -m logo
keys -M logo -k a -m logo
keys -M logo -k z -m logo
keys -M logo -M shift -k z -m shift -m logo
if [[ -z $(tr -d '\0' <"$cap") ]]; then echo "PASS: in a terminal Super+X, A, Z and Super+Shift+Z send nothing"; else echo "FAIL: terminal got: $(tr -d '\0' <"$cap")"; fail=1; fi
alive=0; kill -0 "$hypr_pid" 2>/dev/null && alive=1
if ((alive)) && ! nestctl -j version >/dev/null 2>&1; then alive=0; fi
if ((alive)); then echo "PASS: nested Hyprland alive"; else echo "FAIL: nested Hyprland not responding"; fail=1; fi
echo "log: $run"
exit $fail
