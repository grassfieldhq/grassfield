#!/usr/bin/env bash
# Screen sharing from a browser asks once (bug report on rc6: "the selection prompt comes back several times"; ADR-0035 D-6 as
# amended; docs/specs/system-dialogs.md section 3). Nested scenario (L1), bare command: the real xdg-desktop-portal and
# xdg-desktop-portal-hyprland of this machine on a private D-Bus, a private PipeWire and WirePlumber, captures of this tree's
# nested Hyprland, and a recording picker in place of the stand-in (custom_picker_binary of a scratch xdph.conf, with
# allow_token_by_default as Omarchy's has it). The client (screencast_restore.d/client.py) captures as Chromium does: once for
# its own picker's preview, then again to share, the second with the restore token the first one got.
#   1 the picker answers without the token flag (the Grassfield panel with Remember this choice unticked, as before the fix):
#     no restore token, and the second capture runs the picker again (the reported bug);
#   2 the picker answers with the token flag (Remember this choice, ticked when xdph passes --allow-token): a restore token,
#     the second capture is restored without the picker, and both captures stream pictures that are not blank;
#   3 an app that asks for no persistence (persist_mode 0): no token, the picker runs each time, whatever the flag;
#   4 an app that asks to persist (persist_mode 2, OBS's way): its token is kept in the permission store (Settings > Privacy >
#     Screen Sharing lists and removes it; known limitation: the picker cannot tell the two kinds of apps apart);
#   and xdph passed --allow-token to the picker each time.
# Never the owner's session: a private bus with its own service directory (only the permission store, on a scratch data home),
# a runtime directory of the test's own (the nested instance's Hyprland socket linked into it), the nested Wayland socket; a
# foot window (isolated.sh) on the captured display gives it something to draw; the one dispatch (the focus on that display)
# goes through scripts/nestctl.
# Needs: a nested session of this tree (scripts/dev/nested-up.sh), dbus-daemon, pipewire, wireplumber, busctl, jq, foot,
# /usr/lib/xdg-desktop-portal, /usr/lib/xdg-desktop-portal-hyprland, python3 with dbus-python and PyGObject (GStreamer with
# pipewiresrc for the pictures; without it case 2 checks the token only). SKIPs without them.
# Expected: "screencast_restore: 0 failure(s)". Exit 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || { echo "SKIP screencast_restore: no nested session of this tree (scripts/dev/nested-up.sh, as a bare command)"; exit 0; }
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG
for tool in dbus-daemon pipewire wireplumber busctl jq foot /usr/lib/xdg-desktop-portal /usr/lib/xdg-desktop-portal-hyprland; do
  command -v "$tool" >/dev/null || { echo "SKIP screencast_restore: $tool is missing"; exit 0; }
done
python3 -I -c 'import dbus, gi' 2>/dev/null || { echo "SKIP screencast_restore: python3 needs dbus-python and PyGObject"; exit 0; }
real_runtime=${XDG_RUNTIME_DIR:?}
# Short: the bus and PipeWire sockets live in it (a Unix socket path has 107 bytes).
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-/tmp}/scr.XXXXXX")
pids=()
foot_pid=""
cleanup() {
  [[ -n $foot_pid ]] && kill "$foot_pid" 2>/dev/null
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  sleep 0.3
  for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null; done
  [[ -n ${SCREENCAST_KEEP:-} ]] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
hq() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$@"; }

# The captured display: GF-REF, the nested session's headless output, which draws on its own (the nested window's output
# draws only while the host shows it). Something to draw there: a foot window that writes a line every 50 ms (frames come with
# damage), opened on GF-REF once it has the focus (scripts/nestctl: this tree's nested instance only).
output=GF-REF
for ((n = 0; n < 40; n++)); do
  hq monitors | jq -e --arg o "$output" 'any(.[]; .name == $o)' >/dev/null && break
  sleep 0.25
done
timeout 10 "$root/scripts/nestctl" dispatch "hl.dsp.focus({ monitor = '$output' })" >/dev/null 2>&1 || true
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" foot --app-id gf-screencast --title "Screencast" \
  sh -c 'while :; do date +%s.%N; sleep 0.05; done' >/dev/null 2>&1 </dev/null &
foot_pid=$!
on=""
for ((n = 0; n < 30; n++)); do
  sleep 0.2
  monitor=$(hq clients | jq -r '[.[] | select(.class == "gf-screencast") | .monitor] | first // empty')
  [[ -n $monitor ]] && on=$(hq monitors | jq -r --argjson id "$monitor" '.[] | select(.id == $id) | .name') && break
done
[[ $on == "$output" ]] || { echo "screencast_restore: the foot window is not on $output [${on:-not shown}]"; exit 2; }

run_stack() { # <picker flags: "" or r> <persist_mode>: one private stack, the client's two captures; sets `first`, `second`, `runs`
  local flags=$1 persist=$2 p
  p=$(mktemp -d "$tmp/s.XXXXXX")
  mkdir -m 700 -p "$p/run/hypr" "$p/config/hypr" "$p/config/xdg-desktop-portal" "$p/data" "$p/state" "$p/services"
  ln -s "$real_runtime/hypr/$sig" "$p/run/hypr/$sig"
  printf '#!/bin/sh\necho "$*" >>"%s/picker.log"\nprintf "[SELECTION]%s/screen:%s\\n"\n' "$p" "$flags" "$output" >"$p/picker"
  chmod +x "$p/picker"
  printf 'screencopy {\n    allow_token_by_default = true\n    custom_picker_binary = %s\n}\n' "$p/picker" >"$p/config/hypr/xdph.conf"
  printf '[preferred]\ndefault=hyprland\n' >"$p/config/xdg-desktop-portal/hyprland-portals.conf"
  cat >"$p/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=$p/run/bus</listen>
  <servicedir>$p/services</servicedir>
  <policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy>
</busconfig>
EOF
  printf '[D-BUS Service]\nName=org.freedesktop.impl.portal.PermissionStore\nExec=/usr/lib/xdg-permission-store\n' \
    >"$p/services/org.freedesktop.impl.portal.PermissionStore.service"
  local stack=()
  (
    for v in $(compgen -e); do
      case $v in GRASSFIELD_* | QS_* | GTK_USE_PORTAL | GDK_DEBUG | PIPEWIRE_* | DBUS_SESSION_BUS_ADDRESS) unset "$v" ;; esac
    done
    export XDG_RUNTIME_DIR=$p/run XDG_CONFIG_HOME=$p/config XDG_DATA_HOME=$p/data XDG_STATE_HOME=$p/state
    export WAYLAND_DISPLAY=$real_runtime/$sock HYPRLAND_INSTANCE_SIGNATURE=$sig XDG_CURRENT_DESKTOP=Hyprland XDG_DATA_DIRS=/usr/share
    export DBUS_SESSION_BUS_ADDRESS=unix:path=$p/run/bus
    dbus-daemon --config-file="$p/bus.conf" --nofork --nopidfile >"$p/dbus.log" 2>&1 & stack+=($!)
    for _ in $(seq 50); do [[ -S $p/run/bus ]] && break; sleep 0.1; done
    pipewire >"$p/pipewire.log" 2>&1 & stack+=($!)
    for _ in $(seq 50); do [[ -S $p/run/pipewire-0 ]] && break; sleep 0.1; done
    wireplumber >"$p/wireplumber.log" 2>&1 & stack+=($!)
    /usr/lib/xdg-desktop-portal-hyprland >"$p/xdph.log" 2>&1 & stack+=($!)
    for _ in $(seq 50); do busctl --user status org.freedesktop.impl.portal.desktop.hyprland >/dev/null 2>&1 && break; sleep 0.1; done
    /usr/lib/xdg-desktop-portal >"$p/frontend.log" 2>&1 & stack+=($!)
    for _ in $(seq 100); do busctl --user status org.freedesktop.portal.Desktop >/dev/null 2>&1 && break; sleep 0.1; done
    timeout 90 python3 -I "$root/tests/integration/screencast_restore.d/client.py" "$persist" >"$p/client.out" 2>"$p/client.err"
    for s in "${stack[@]}"; do kill "$s" 2>/dev/null; done
    sleep 0.3
    for s in "${stack[@]}"; do kill -9 "$s" 2>/dev/null; done
  )
  first=$(sed -n 1p "$p/client.out") second=$(sed -n 2p "$p/client.out")
  runs=$(wc -l <"$p/picker.log" 2>/dev/null || echo 0)
  allow=$(grep -c -x -- "--allow-token" "$p/picker.log" 2>/dev/null || echo 0)
  store=$p/data/flatpak/db/screencast
  [[ -n $first && -n $second ]] || { echo "screencast_restore: the client did not finish [$(tail -3 "$p/client.err" "$p/frontend.log" "$p/xdph.log" 2>/dev/null | tr '\n' ' ')]"; exit 2; }
}
field() { jq -r "$2" <<<"$1"; }
# Pictures that are not blank: at least one frame with a spread (a white or empty picture has none).
pictures() { jq -e 'has("frames") | not' <<<"$1" >/dev/null || jq -e '[.frames[] | select(.spread > 4 and .mean < 250)] | length > 0' <<<"$1" >/dev/null; }

# 1.
run_stack "" 1
if [[ $(field "$first" .token) == null && $runs == 2 ]]; then
  pass "1 without the token flag: no restore token, and the browser's second capture runs the picker again [runs $runs]"
else
  fail "1 without the token flag [runs $runs, $first]"
fi
[[ $allow == "$runs" ]] && pass "1 xdph passed --allow-token to the picker" || fail "1 --allow-token [$allow of $runs]"

# 2.
run_stack r 1
token=$(field "$first" .token)
if [[ $token != null && $(field "$second" .token_given) == true && $(field "$second" .streams) == 1 && $runs == 1 ]]; then
  pass "2 with the token flag: a restore token, and the browser's second capture is restored without the picker [runs $runs]"
else
  fail "2 with the token flag [runs $runs, $first, $second]"
fi
if jq -e 'has("frames")' <<<"$first" >/dev/null; then
  if pictures "$first" && pictures "$second"; then
    pass "2 both captures stream pictures that are not blank [$(field "$first" '.frames | tostring') $(field "$second" '.frames | tostring')]"
  else
    fail "2 a capture streamed no picture, or a blank one [$first $second]"
  fi
else
  echo "SKIP: 2 the pictures (GStreamer's Python bindings or pipewiresrc are missing)"
fi
[[ ! -s $store ]] && pass "2 a browser's token is kept only while it runs (nothing in the permission store)" || fail "2 the permission store holds a token"

# 3.
run_stack r 0
if [[ $(field "$first" .token) == null && $runs == 2 ]]; then
  pass "3 an app that asks for no persistence gets no token and is asked each time [runs $runs]"
else
  fail "3 persist_mode 0 [runs $runs, $first]"
fi

# 4.
run_stack r 2
if [[ $(field "$first" .token) != null && $runs == 1 && -s $store ]]; then
  pass "4 an app that asks to persist keeps its token in the permission store (Settings > Privacy > Screen Sharing) [runs $runs]"
else
  fail "4 persist_mode 2 [runs $runs, store $(ls -s "$store" 2>/dev/null), $first]"
fi

echo "screencast_restore: $fails failure(s)"
((fails == 0))
