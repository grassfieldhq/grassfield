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
#   4 a host app the portal cannot name that asks to persist (persist_mode 2, OBS's way): xdg-desktop-portal 1.22 names a host
#     app after its app-*.scope or app-*.service unit only when a desktop entry of that name exists (src/xdp-app-info-host.c),
#     so this run's frontend sees no desktop entry at all (its XDG_DATA_DIRS holds its portal files and GLib's schemas only) and the client gets the
#     app id "", whatever unit runs the test: its token is kept in the permission store under the app id "" (Settings > Privacy >
#     Screen Sharing lists it as Other Apps and removes it; known limitation: the picker cannot tell the two kinds of apps apart);
#   and xdph passed --allow-token to the picker each time.
# Isolation (checked in every run): the stack's processes see no X display (no module-x11-bell), no system bus
# (DBUS_SYSTEM_BUS_ADDRESS names a socket that does not exist: no BlueZ, logind or RealtimeKit), a cache, configuration, data and
# state home of their own; WirePlumber runs its "policy" profile (no ALSA, Bluetooth, V4L2 or libcamera monitor) and PipeWire
# loads neither the X11 bell, the JACK detection nor the realtime module; GStreamer loads only the four plugins the client uses,
# with a registry of its own. After each run: the private PipeWire graph has no device, no audio or camera node and no X11
# module (pw-dump), and no process of the stack holds a sound, video or media device open. Its one device is the GPU's render
# node, which xdph's capture uses as the nested compositor does.
# Never the owner's session: a private bus with its own service directory (only the permission store, on a scratch data home),
# a runtime directory of the test's own (the nested instance's Hyprland socket linked into it), the nested Wayland socket; a
# foot window (isolated.sh) on the captured display gives it something to draw; the one dispatch (the focus on that display)
# goes through scripts/nestctl. Every process the test starts is recorded and stopped on exit, Ctrl-C and SIGTERM included.
# Needs: a nested session of this tree (scripts/dev/nested-up.sh), dbus-daemon, pipewire, wireplumber, pw-dump, busctl, jq, foot,
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
for tool in dbus-daemon pipewire wireplumber pw-dump busctl jq foot /usr/lib/xdg-desktop-portal /usr/lib/xdg-desktop-portal-hyprland; do
  command -v "$tool" >/dev/null || { echo "SKIP screencast_restore: $tool is missing"; exit 0; }
done
python3 -I -c 'import dbus, gi' 2>/dev/null || { echo "SKIP screencast_restore: python3 needs dbus-python and PyGObject"; exit 0; }
real_runtime=${XDG_RUNTIME_DIR:?}
# Short: the bus and PipeWire sockets live in it (a Unix socket path has 107 bytes).
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-/tmp}/scr.XXXXXX")
# Every process the test starts (the stack, its subshell, the client, foot), one PID per line.
pidfile=$tmp/pids
: >"$pidfile"
cleanup() {
  local p
  while read -r p; do kill "$p" 2>/dev/null; done <"$pidfile"
  sleep 0.3
  while read -r p; do kill -9 "$p" 2>/dev/null; done <"$pidfile"
  [[ -n ${SCREENCAST_KEEP:-} ]] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
hq() { HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j "$@"; }

# GStreamer for the client: the four plugins it uses, nothing that would probe a device (v4l2's plugin opens /dev/video* when a
# registry is built), and a registry of the test's own.
mkdir -p "$tmp/gst-plugins"
for plugin in libgstpipewire.so libgstapp.so libgstvideoconvertscale.so libgstcoreelements.so; do
  [[ -e /usr/lib/gstreamer-1.0/$plugin ]] && ln -s "/usr/lib/gstreamer-1.0/$plugin" "$tmp/gst-plugins/$plugin"
done

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
echo $! >>"$pidfile"
on=""
for ((n = 0; n < 30; n++)); do
  sleep 0.2
  monitor=$(hq clients | jq -r '[.[] | select(.class == "gf-screencast") | .monitor] | first // empty')
  [[ -n $monitor ]] && on=$(hq monitors | jq -r --argjson id "$monitor" '.[] | select(.id == $id) | .name') && break
done
[[ $on == "$output" ]] || { echo "screencast_restore: the foot window is not on $output [${on:-not shown}]"; exit 2; }

run_stack() { # <picker flags: "" or r> <persist_mode> [nameless: the frontend finds no desktop entry]: one private stack, the
  # client's two captures; sets `first`, `second`, `runs`, `allow`, `store_apps` and `p` (the run's directory)
  local flags=$1 persist=$2 nameless=${3-}
  p=$(mktemp -d "$tmp/s.XXXXXX")
  mkdir -m 700 -p "$p/run/hypr" "$p/config/hypr" "$p/config/xdg-desktop-portal" "$p/config/pipewire/pipewire.conf.d" \
    "$p/data" "$p/state" "$p/cache" "$p/services" "$p/share"
  ln -s "$real_runtime/hypr/$sig" "$p/run/hypr/$sig"
  # The nameless frontend's data: its portal files and GLib's schemas (it aborts without them), no applications folder.
  ln -s /usr/share/xdg-desktop-portal "$p/share/xdg-desktop-portal"
  ln -s /usr/share/glib-2.0 "$p/share/glib-2.0"
  printf '#!/bin/sh\necho "$*" >>"%s/picker.log"\nprintf "[SELECTION]%s/screen:%s\\n"\n' "$p" "$flags" "$output" >"$p/picker"
  chmod +x "$p/picker"
  printf 'screencopy {\n    allow_token_by_default = true\n    custom_picker_binary = %s\n}\n' "$p/picker" >"$p/config/hypr/xdph.conf"
  printf '[preferred]\ndefault=hyprland\n' >"$p/config/xdg-desktop-portal/hyprland-portals.conf"
  printf 'context.properties = {\n    module.x11.bell = false\n    module.jackdbus-detect = false\n    module.rt = false\n}\n' \
    >"$p/config/pipewire/pipewire.conf.d/10-test-no-host.conf"
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
  (
    stack=()
    for v in $(compgen -e); do
      case $v in GRASSFIELD_* | QS_* | GTK_USE_PORTAL | GDK_DEBUG | PIPEWIRE_* | DBUS_SESSION_BUS_ADDRESS | DISPLAY | GST_*) unset "$v" ;; esac
    done
    export XDG_RUNTIME_DIR=$p/run XDG_CONFIG_HOME=$p/config XDG_DATA_HOME=$p/data XDG_STATE_HOME=$p/state XDG_CACHE_HOME=$p/cache
    export WAYLAND_DISPLAY=$real_runtime/$sock HYPRLAND_INSTANCE_SIGNATURE=$sig XDG_CURRENT_DESKTOP=Hyprland XDG_DATA_DIRS=/usr/share
    export DBUS_SESSION_BUS_ADDRESS=unix:path=$p/run/bus DBUS_SYSTEM_BUS_ADDRESS=unix:path=/nonexistent
    started() { stack+=("$1"); echo "$1" >>"$pidfile"; }
    descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }
    # The processes connected to the private bus, by the bus's own record (its socket is in this run's directory: every peer
    # is the test's).
    bus_peers() {
      busctl --user -j call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ListNames 2>/dev/null |
        jq -r '.data[0][] | select(startswith(":"))' 2>/dev/null | while read -r name; do
          busctl --user -j call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetConnectionUnixProcessID s "$name" \
            2>/dev/null | jq -r '.data[0]' 2>/dev/null
        done
    }
    dbus-daemon --config-file="$p/bus.conf" --nofork --nopidfile >"$p/dbus.log" 2>&1 & started $!
    for _ in $(seq 50); do [[ -S $p/run/bus ]] && break; sleep 0.1; done
    pipewire >"$p/pipewire.log" 2>&1 & started $!
    for _ in $(seq 50); do [[ -S $p/run/pipewire-0 ]] && break; sleep 0.1; done
    wireplumber -p policy >"$p/wireplumber.log" 2>&1 & started $!
    /usr/lib/xdg-desktop-portal-hyprland >"$p/xdph.log" 2>&1 & started $!
    for _ in $(seq 50); do busctl --user status org.freedesktop.impl.portal.desktop.hyprland >/dev/null 2>&1 && break; sleep 0.1; done
    if [[ -n $nameless ]]; then
      XDG_DATA_DIRS=$p/share /usr/lib/xdg-desktop-portal >"$p/frontend.log" 2>&1 & started $!
    else
      /usr/lib/xdg-desktop-portal >"$p/frontend.log" 2>&1 & started $!
    fi
    for _ in $(seq 100); do busctl --user status org.freedesktop.portal.Desktop >/dev/null 2>&1 && break; sleep 0.1; done
    GST_REGISTRY=$p/gst-registry.bin GST_PLUGIN_SYSTEM_PATH_1_0=$tmp/gst-plugins GST_PLUGIN_PATH_1_0="" \
      timeout 90 python3 -I "$root/tests/integration/screencast_restore.d/client.py" "$persist" >"$p/client.out" 2>"$p/client.err" &
    started $!
    wait $!
    # The permission store's screencast entries: one line per token, the app ids that hold it (JSON).
    busctl --user -j call org.freedesktop.impl.portal.PermissionStore /org/freedesktop/impl/portal/PermissionStore \
      org.freedesktop.impl.portal.PermissionStore List s screencast 2>/dev/null | jq -r '.data[0][]' 2>/dev/null |
      while read -r token; do
        busctl --user -j call org.freedesktop.impl.portal.PermissionStore /org/freedesktop/impl/portal/PermissionStore \
          org.freedesktop.impl.portal.PermissionStore Lookup ss screencast "$token" 2>/dev/null | jq -c '.data[0] | keys'
      done >"$p/store-apps"
    # The isolation, while the stack still runs: its graph, the devices its processes hold, their environment. "Its processes":
    # the ones started above; every descendant of each, found recursively (a service dbus-daemon runs under a babysitter
    # process that stays its parent, anything the others spawned and left running); and every process connected to the private
    # bus, by the bus's record (GetConnectionUnixProcessID). The last takes in the services the private bus activated even when
    # they are no descendant: on this machine dbus-daemon 1.16's babysitter exits and xdg-permission-store is reparented to the
    # session's subreaper (systemd --user). Each is recorded, checked and stopped like the rest; names in stack-procs.
    for s in "${stack[@]}"; do
      for c in $(descendants "$s"); do started "$c"; done
    done
    for c in $(bus_peers); do
      [[ $c =~ ^[0-9]+$ && $c != 0 && -e /proc/$c && " ${stack[*]} " != *" $c "* ]] && started "$c"
    done
    for s in "${stack[@]}"; do
      [[ -r /proc/$s/comm ]] && echo "$s $(<"/proc/$s/comm")"
    done >"$p/stack-procs"
    pw-dump >"$p/pw-dump.json" 2>/dev/null
    for s in "${stack[@]}"; do
      for fd in /proc/"$s"/fd/*; do readlink "$fd"; done 2>/dev/null | sed "s|^|$s |"
    done >"$p/fds"
    for s in "${stack[@]}"; do
      [[ -r /proc/$s/environ ]] || continue
      tr '\0' '\n' <"/proc/$s/environ" | grep -E '^(DISPLAY|DBUS_SYSTEM_BUS_ADDRESS)=' | sed "s|^|$s |"
    done >"$p/envs"
    for s in "${stack[@]}"; do kill "$s" 2>/dev/null; done
    sleep 0.3
    for s in "${stack[@]}"; do kill -9 "$s" 2>/dev/null; done
  ) &
  echo $! >>"$pidfile"
  wait $!
  first=$(sed -n 1p "$p/client.out") second=$(sed -n 2p "$p/client.out")
  runs=$(wc -l <"$p/picker.log" 2>/dev/null || echo 0)
  allow=$(grep -c -x -- "--allow-token" "$p/picker.log" 2>/dev/null || echo 0)
  store_apps=$(paste -sd' ' "$p/store-apps" 2>/dev/null)
  [[ -n $first && -n $second ]] || { echo "screencast_restore: the client did not finish [$(tail -3 "$p/client.err" "$p/frontend.log" "$p/xdph.log" 2>/dev/null | tr '\n' ' ')]"; exit 2; }
}
field() { jq -r "$2" <<<"$1"; }
# Pictures that are not blank: at least one frame with a spread (a white or empty picture has none).
pictures() { jq -e 'has("frames") | not' <<<"$1" >/dev/null || jq -e '[.frames[] | select(.spread > 4 and .mean < 250)] | length > 0' <<<"$1" >/dev/null; }
# The run touched no device of the machine: no device object, no audio or camera node and no X11 module in its PipeWire graph; no
# sound, camera or media device open in its processes; no X display and no system bus in their environment.
isolated() {
  local why=""
  jq -e '[.[] | select(.type == "PipeWire:Interface:Device")] | length == 0' "$p/pw-dump.json" >/dev/null || why+=" a device object;"
  jq -e '[.[] | select(.type == "PipeWire:Interface:Node") | .info.props | select(((.["factory.name"] // "") | test("^api\\."))
    or ((.["media.class"] // "") | test("^Audio/")) or has("device.id"))] | length == 0' "$p/pw-dump.json" >/dev/null || why+=" a device or audio node;"
  jq -e '[.[] | select(.type == "PipeWire:Interface:Module") | .info.name | select(test("x11|jack|bluez|alsa|v4l2|libcamera"))] | length == 0' \
    "$p/pw-dump.json" >/dev/null || why+=" a host module;"
  jq -e '[.[] | select(.type == "PipeWire:Interface:Module")] | length > 0' "$p/pw-dump.json" >/dev/null || why+=" no graph read;"
  ! grep -q -E ' /dev/(snd/|video|media|v4l|bus/usb)' "$p/fds" || why+=" a device open ($(grep -E ' /dev/(snd/|video|media|v4l|bus/usb)' "$p/fds" | head -2 | tr '\n' ' '));"
  [[ -s $p/fds ]] || why+=" no file descriptors read;"
  ! grep -q ' DISPLAY=' "$p/envs" || why+=" an X display;"
  [[ $(grep -c ' DBUS_SYSTEM_BUS_ADDRESS=unix:path=/nonexistent$' "$p/envs") -ge 5 ]] || why+=" a system bus;"
  [[ -z $why ]] || { echo "$why"; return 1; }
}
check_isolated() { local why; if why=$(isolated); then pass "$1 the run reached no device of the machine (pw-dump, open files, environment)"; else fail "$1 isolation:$why"; fi; }

# 1.
run_stack "" 1
if [[ $(field "$first" .token) == null && $runs == 2 ]]; then
  pass "1 without the token flag: no restore token, and the browser's second capture runs the picker again [runs $runs]"
else
  fail "1 without the token flag [runs $runs, $first]"
fi
[[ $allow == "$runs" ]] && pass "1 xdph passed --allow-token to the picker" || fail "1 --allow-token [$allow of $runs]"
check_isolated 1

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
[[ -z $store_apps ]] && pass "2 a browser's token is kept only while it runs (nothing in the permission store)" || fail "2 the permission store holds a token [$store_apps]"
check_isolated 2

# 3.
run_stack r 0
if [[ $(field "$first" .token) == null && $runs == 2 ]]; then
  pass "3 an app that asks for no persistence gets no token and is asked each time [runs $runs]"
else
  fail "3 persist_mode 0 [runs $runs, $first]"
fi
check_isolated 3

# 4.
run_stack r 2 nameless
if [[ $(field "$first" .token) != null && $runs == 1 && $store_apps == '[""]' ]]; then
  pass "4 a host app the portal cannot name keeps its lasting token in the permission store under the app id \"\" [runs $runs, store $store_apps]"
else
  fail "4 persist_mode 2 [runs $runs, store ${store_apps:-empty}, $first]"
fi
check_isolated 4

echo "screencast_restore: $fails failure(s)"
((fails == 0))
