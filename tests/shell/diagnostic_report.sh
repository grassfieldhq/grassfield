#!/usr/bin/env bash
# ADR-0053: packaging/bin/grassfield-report, the diagnostic report for beta testers, against fakes of every command it runs
# (pacman, hyprctl, wpctl, coredumpctl, journalctl, systemctl, free, qs on PATH), a fake /proc, a fake Quickshell runtime
# folder and a fake home. Checks: one file in the user's own Downloads folder (user-dirs.dirs), mode 0600, never overwritten;
# every section; the displays without their serial; the home, the user name and secret-looking values removed (configuration
# and every log); bounded size; a missing tool is a line, not a failure; never as root; no sudo, no network and no writing
# verb of systemctl, qs, journalctl or coredumpctl in the source; the test hooks only in a dev session. The owner's report of
# 2026-11-21 (round 2): the journal without the liveness probe's routine runs, repeated lines folded, a time window; the
# kernel's and the OOM daemons' lines; units and Quickshell processes with their memory; the known killers around each
# signal; Quickshell's own logs; crash details; one time budget. Nothing here reads the session: the commands are stubs and
# HOME is a scratch folder. Run as root (a container), the script runs as nobody (setpriv).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/diag-report.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
script=$root/packaging/bin/grassfield-report
py=$(command -v python3)

home=$tmp/home/alice
dl="$home/Téléchargements"
mkdir -p "$tmp/nobin" "$tmp/log" "$tmp/bin" "$tmp/root/usr/share/grassfield" "$tmp/root/etc" "$home/.config/grassfield" "$dl" "$tmp/out"
printf '0.9.0-beta.3\n' >"$tmp/root/usr/share/grassfield/VERSION"
printf 'NAME="Omarchy"\nVERSION_ID=4.5.0\nBUILD_ID=rolling\nHOME_URL=x\n' >"$tmp/root/etc/os-release"
printf 'XDG_DESKTOP_DIR="$HOME/Bureau"\nXDG_DOWNLOAD_DIR="$HOME/T\303\251l\303\251chargements"\n' >"$home/.config/user-dirs.dirs"
cat >"$home/.config/grassfield/grassfield.json" <<EOF
{"version": 1, "wallpaper": {"source": "picture", "path": "$home/Pictures/a.jpg"},
 "online": {"apiKey": "SECRET-ONE", "token": "SECRET-TWO", "enabled": true},
 "keyboard": {"repeatRate": 30}, "password": "SECRET-THREE", "privateKey": "SECRET-SIX",
 "sshKey": "SECRET-EIGHT", "network": {"session_key": "SECRET-NINE"},
 "displays": {"main": [{"set": ["m:BOE|NE135|eDP-1", "s:Dell Inc.|U2723QE|SERIAL-MAIN-1"], "main": "s:Dell Inc.|U2723QE|SERIAL-MAIN-1"}]},
 "wallpaperOutputs": {"outputs": [{"display": {"name": "DP-3", "model": "U2723QE", "serial": "SERIAL-WP-2"}, "key": "s:U2723QE|SERIAL-WP-3"}]},
 "dock": {"folders": ["$home/Secret Plans/Divorce", "~/Other Secret"], "stackOptions": {"$home/Secret Plans/Divorce": {"sort": "name"}}, "showRecents": true},
 "screensaver": {"folder": "$home/Pictures/Family Album"},
 "lock": {"idleMinutes": 5, "showMessage": true, "message": "If found call FREE-TEXT-LOCK 0612345678"}}
EOF
printf '{"version": 1, "serial": 7, "folders": {"%s/Secret Plans/Divorce": {"color": "red"}, "%s/Photos/Trip": {"glyph": "star"}}}\n' "$home" "$home" >"$home/.config/grassfield/folder-styles.json"
printf '{"version": 1, "outputs": {"DP-3": {"file": "%s/Pictures/Private/beach.jpg"}}}\n' "$home" >"$home/.config/grassfield/wallpaper-state.json"
printf '{"version": 1, "current": "file://%s/Pictures/Private%%20Stuff/sunset.png"}\n' "$home" >"$home/.config/grassfield/wallpaper-url.json"
printf 'source = picture\npath = %s/Pictures/Hidden Folder/dune.jpg\n# see %s/Pictures/Hidden Folder/notes\n' "$home" "$home" >"$home/.config/grassfield/wallpaper.txt"
mkdir -p "$tmp/root/usr/share/grassfield/schema"
cp "$root/config/schema/grassfield.schema.json" "$tmp/root/usr/share/grassfield/schema/"
printf 'theme = dark\npassword = SECRET-FOUR\nauth_token: SECRET-FIVE\npsk '"'"'SECRET-SEVEN'"'"'\npass=SECRET-TEN\n' >"$home/.config/grassfield/notes.conf"
ln -s /etc/hostname "$home/.config/grassfield/linked.json"
# displays.conf (ADR-0031): the connected DP-3 (Hyprland's description ends with its serial), the built-in panel (no serial)
# and a display not connected now (R7-SEC-04).
printf 'v1\tdesc:Dell Inc. U2723QE SERIAL-XYZ-123\t3840x2160@60.00\t0x0\t1.5\t0\nv1\tdesc:BOE NE135\t2256x1504@60.00\t3840x0\t1.25\t0\nv1\tdesc:LG Electronics LG ULTRAFINE 012NTPC1A234\t5120x2880@60.00\t-5120x0\t2\t0\nv1\tdesc:Acme Corp AC27 AB12CD34 EF56\t2560x1440@60.00\t0x-1440\t1\t0\n' >"$home/.config/grassfield/displays.conf"

cat >"$tmp/bin/pacman" <<'SH'
#!/bin/sh
[ "$1" = "-Q" ] || exit 1
printf 'firefox 140.0-1\ngrassfield-desktop 0.9.0-1\ngrassfield-compositor 0.9.0-1\nhyprland 0.56.2-1\nomarchy 4.5.0-1\nqt6-base 6.10.1-1\nquickshell 0.3.2-1\nzsh 5.9-1\n'
SH
cat >"$tmp/bin/hyprctl" <<'SH'
#!/bin/sh
case "$*" in
  "-j monitors") [ "${FAKE_MONITORS:-ok}" = broken ] && { printf '[{"name":"DP-3","serial":"SERIAL-BROKEN-9","descr'; exit 0; }
    printf '[{"id":0,"name":"DP-3","description":"Dell Inc. U2723QE SERIAL-XYZ-123","make":"Dell Inc.","model":"U2723QE","serial":"SERIAL-XYZ-123","width":3840,"height":2160,"refreshRate":60.0,"x":0,"y":0,"scale":1.5,"transform":0,"focused":true,"dpmsStatus":true,"vrr":false,"disabled":false},{"name":"eDP-1","description":"BOE NE135","make":"BOE","model":"NE135","serial":"","width":2256,"height":1504}]\n' ;;
  "version") echo "Hyprland 0.56.2 built from branch at commit abc" ;;
  "grassfield") if [ "${FAKE_PLUGIN:-on}" = on ]; then echo "grassfield 0.9.0 gfc/1 ready"; else echo "unknown request"; fi ;;
  *) echo "unexpected hyprctl $*" >&2; exit 3 ;;
esac
SH
cat >"$tmp/bin/wpctl" <<'SH'
#!/bin/sh
[ "$1" = status ] || exit 1
printf 'Audio\n ├─ Sinks:\n │  *   52. Built-in Audio Analog Stereo [vol: 0.40]\n │      61. Marie’s AirPods [vol: 0.50]\n │      62. Paul'"'"'s Headphones [vol: 0.50]\n'
printf 'Settings\n └─ Default Configured Devices:\n         0. Audio/Sink    alsa_output.usb-Generic_USB-Audio-01_201405280001-00.analog-stereo\n         1. Audio/Source  alsa_input.usb-Blue_Microphones_Yeti_Stereo_Microphone_REV8-00.analog-stereo\n'
SH
# coredumpctl: a crash of a tool in the home (not Grassfield's), of the shell (no core kept: no stack) and of Hyprland (a
# stack of 12 frames); `info` prints identifiers and a command line that must not leave.
cat >"$tmp/bin/coredumpctl" <<'SH'
#!/bin/sh
echo "coredumpctl $*" >>"@LOG@/coredumpctl-args"
[ -n "${FAKE_SLOW:-}" ] && sleep 5
[ -n "${FAKE_EMPTY:-}" ] && { echo "No coredumps found." >&2; exit 1; }
case "$*" in
  *" list "*|*" list") echo "Thu 2026-11-05 10:00:00 UTC 4242 1000 1000 SIGSEGV present @HOME@/bin/tool 1.2M"
    echo "Thu 2026-11-05 10:05:00 UTC 5100 1000 1000 SIGSEGV none /usr/bin/quickshell -"
    echo "Thu 2026-11-05 10:06:00 UTC 6100 1000 1000 SIGABRT present /usr/bin/Hyprland 30.1M" ;;
  *" info "*)
    for a in "$@"; do pid=$a; done
    exe=/usr/bin/quickshell; [ "$pid" = 6100 ] && exe=/usr/bin/Hyprland
    printf '           PID: %s (x)\n           UID: 1000 (alice)\n        Signal: 11 (SEGV)\n     Timestamp: Thu 2026-11-05 10:05:00 UTC\n' "$pid"
    printf '  Command Line: %s -p @HOME@/Private/shell --title "Bank-Statement"\n    Executable: %s\n     User Unit: grassfield-shell.service\n' "$exe" "$exe"
    printf '       Boot ID: 0123456789abcdef0123456789abcdef\n    Machine ID: fedcba9876543210fedcba9876543210\n      Hostname: alice-laptop\n'
    printf '       Storage: /var/lib/systemd/coredump/core.x.1000.0123456789abcdef.%s.zst (present)\n       Package: hyprland/0.56.2\n' "$pid"
    printf '       Message: Process %s (x) of user 1000 dumped core.\n                \n                Module /usr/bin/x from deb x-1.0\n' "$pid"
    if [ "$pid" = 6100 ]; then
      printf '                Stack trace of thread %s:\n' "$pid"
      i=0; while [ $i -lt 12 ]; do printf '                #%d  0x00007f00000%04d frame_%d (libhyprutils.so.7 + 0x%04d)\n' $i $i $i $i; i=$((i+1)); done
      printf '                \n                Stack trace of thread 6101:\n                #0  0x00007f0000009999 other_thread (libc.so.6 + 0x9999)\n'
    fi ;;
  *) echo "unexpected coredumpctl $*" >&2; exit 3 ;;
esac
SH
# journalctl: this boot's Grassfield journal (the privacy cases, the liveness probe's routine runs, repeated lines, two kills of
# the shell: one by the probe, one by nobody known), the kernel's lines, systemd-oomd's and the journal around each kill.
cat >"$tmp/bin/journalctl" <<'SH'
#!/bin/sh
echo "journalctl $*" >>"@LOG@/journal-args"
home=@HOME@
case "$*" in
  *"--since @1793872855 --until @1793872866"*)
    case "$*" in
      *--user*) echo "2026-11-05T10:00:58+0000 vm grassfield-shell-watchdog[77]: grassfield-shell-watchdog: the shell (pid 5000) did not answer within 5 s 3 times in a row: SIGKILL, so that its unit fails and restarts it"
        echo "2026-11-05T10:01:00+0000 vm systemd[959]: grassfield-shell.service: Main process exited, code=killed, status=9/KILL" ;;
      *) echo "2026-11-05T10:00:59+0000 vm kernel: usb 1-1: USB disconnect, device number 4" ;;
    esac ;;
  *"--since @1793873095 --until @1793873106"*)
    case "$*" in
      *--user*) echo "2026-11-05T10:04:59+0000 vm app-browser-1234.scope[888]: window title=\"Holiday-Plans-Lisbon\" loaded from $home/Documents/plans.html"
        echo "2026-11-05T10:05:00+0000 vm systemd[959]: grassfield-shell.service: Main process exited, code=killed, status=9/KILL"
        echo "2026-11-05T10:05:01+0000 vm NetworkManager-applet[66]: wifi: connected to ssid HomeNet-Window-5G for alice" ;;
      *) echo "2026-11-05T10:05:02+0000 vm wpa_supplicant[500]: wlan0: CTRL-EVENT-CONNECTED ssid=\"HomeNet-System-5G\"" ;;
    esac ;;
  *"--since "*) echo "unexpected window $*" >&2; exit 3 ;;
  "-k "*)
    echo "2026-11-05T09:59:00+0000 vm kernel: usb 1-1: new high-speed USB device number 4"
    echo "2026-11-05T09:59:30+0000 vm kernel: Out of memory: Killed process 4321 (alice-indexer) total-vm:9000kB, anon-rss:8000kB"
    echo "2026-11-05T09:59:31+0000 vm kernel: tool[4242]: segfault at 0 ip 0000 sp 0000 error 4 in libfoo.so[1000+2000]"
    echo "2026-11-05T09:59:32+0000 vm kernel: wlan0: associated with ssid=\"HomeNet-Kernel-5G\" (segfault at 0 in its driver)" ;;
  *systemd-oomd.service*)
    echo "2026-11-05T09:58:00+0000 vm systemd-oomd[400]: Killed /user.slice/user-1000.slice/user@1000.service/app.slice/app-heavy.scope due to memory pressure" ;;
  *)
[ -n "${FAKE_EMPTY:-}" ] && { echo "Failed to add filter for units: No data available" >&2; exit 1; }
if [ -n "${FAKE_BIG:-}" ]; then i=0; while [ $i -lt 40000 ]; do echo "2026-11-05T10:00:00+0000 vm grassfield-shell[1]: line $i padding padding padding padding"; i=$((i+1)); done; exit 0; fi
i=0; while [ $i -lt 50 ]; do
  echo "2026-11-05T09:30:00+0000 vm systemd[959]: Starting Grassfield shell liveness probe: restart a shell that stopped answering..."
  echo "2026-11-05T09:30:01+0000 vm systemd[959]: Finished Grassfield shell liveness probe: restart a shell that stopped answering."
  i=$((i+1)); done
echo "2026-11-05T09:30:02+0000 vm systemd[959]: grassfield-shell-watchdog.service: Deactivated successfully."
echo "2026-11-05T09:30:03+0000 vm grassfield-shell-watchdog[70]: grassfield-shell-watchdog: the shell (pid 5000) did not answer within 5 s: 1 of 3"
echo "2026-11-05T09:30:04+0000 vm systemd[959]: grassfield-shell-watchdog.service: Failed with result 'exit-code'."
echo "2026-11-05T09:30:05+0000 vm grassfield-menu-bridge[3251]: grassfield-menu-bridge: window 55d3de: pid 9273 is not in the bridge's pid namespace: no registrar menu"
echo "2026-11-05T09:30:06+0000 vm grassfield-menu-bridge[3251]: grassfield-menu-bridge: window 55d3de: pid 9273 is not in the bridge's pid namespace: no registrar menu"
echo "2026-11-05T09:30:07+0000 vm grassfield-menu-bridge[3251]: grassfield-menu-bridge: window 55d3de: pid 9273 is not in the bridge's pid namespace: no registrar menu"
echo "2026-11-05T10:00:00+0000 vm grassfield-shell[1]: loaded $home/.config/grassfield/grassfield.json for alice"
echo "2026-11-05T10:00:01+0000 vm grassfield-shell[1]: request token=abcd1234zz Authorization: Bearer abcdefghijklmnopqrstu"
echo "2026-11-05T10:00:02+0000 vm grassfield-shell[1]: Alice opened Settings"
echo "2026-11-05T10:00:03+0000 vm grassfield-shell[1]: audio: default sink bluez_output.A0:B1:C2:D3:E4:F5.1"
echo "2026-11-05T10:00:04+0000 vm grassfield-shell[1]: audio: default output is now Marie’s AirPods"
echo "2026-11-05T10:00:05+0000 vm grassfield-shell[1]: the Dock's tile moved; Wayland's socket is back; Activity Monitor's list refreshed"
echo "2026-11-05T10:00:06+0000 vm grassfield-shell[1]: helper login pass=SECRET-ELEVEN pwd=SECRET-TWELVE"
echo "2026-11-05T10:00:07+0000 vm grassfield-shell[1]: Displays: DP-3 is Dell Inc. U2723QE SERIAL-XYZ-123"
echo "2026-11-05T10:00:08+0000 vm grassfield-shell[1]: audio: default sink alsa_output.usb-Focusrite_Scarlett_2i2_USB_Y8ABCDE12345-00.HiFi__Line__sink"
echo "2026-11-05T10:00:09+0000 vm grassfield-shell[1]: audio routing: connected USB Headset (usb:0x0d8c:0x0014:SN-7Y3K9QX2): personal"
echo "2026-11-05T10:00:10+0000 vm grassfield-shell[1]: grassfield: display desc:Iiyama PL2792Q 1173930A0284: no such mode"
echo "2026-11-05T10:00:11+0000 vm grassfield-shell[1]: displays: LG Electronics LG ULTRAFINE 012NTPC1A234 is back"
echo "2026-11-05T10:00:12+0000 vm grassfield-shell[1]: window title=\"Bank-Statement March\" moved to DP-3"
echo "2026-11-05T10:00:13+0000 vm grassfield-shell[1]: wifi: connected to ssid CafeLuna-Guest, strength 70"
echo "2026-11-05T10:00:14+0000 vm grassfield-shell[1]: notification from Mail: “Dinner with Bob tonight” (kind \"banner\")"
echo "2026-11-05T10:00:15+0000 vm grassfield-shell[1]: overlay on \"DP-1\": open with no popup"
echo "2026-11-05T10:01:00+0000 vm systemd[959]: grassfield-shell.service: Main process exited, code=killed, status=9/KILL"
echo "2026-11-05T10:01:00+0000 vm systemd[959]: grassfield-shell.service: Failed with result 'signal'."
echo "2026-11-05T10:05:00+0000 vm systemd[959]: grassfield-shell.service: Main process exited, code=killed, status=9/KILL"
echo "2026-11-05T10:05:00+0000 vm systemd[959]: grassfield-shell.service: Consumed 1min 24.648s CPU time over 8min 13.816s wall clock time, 1.3G memory peak."
;;
esac
SH
# systemctl: `show` of the Grassfield user units (the shell restarted twice, the security process, the probe); anything
# else fails (the report only reads).
cat >"$tmp/bin/systemctl" <<'SH'
#!/bin/sh
echo "systemctl $*" >>"@LOG@/systemctl-args"
case "$*" in
  "--user show --property="*" grassfield-*") ;;
  *) echo "unexpected systemctl $*" >&2; exit 3 ;;
esac
printf 'Id=grassfield-shell.service\nActiveState=active\nSubState=running\nResult=success\nMainPID=5101\nExecMainCode=2\nExecMainStatus=9\nNRestarts=2\nMemoryCurrent=436207616\nMemoryPeak=1395864371\nMemorySwapPeak=0\nMemoryMax=3221225472\nCPUUsageNSec=84648000000\nActiveEnterTimestamp=Thu 2026-11-05 10:05:01 UTC\n\n'
printf 'Id=grassfield-security.service\nActiveState=active\nSubState=running\nResult=success\nMainPID=5102\nExecMainCode=0\nExecMainStatus=0\nNRestarts=0\nMemoryCurrent=104857600\nMemoryPeak=157286400\nMemorySwapPeak=[not set]\nMemoryMax=3221225472\nCPUUsageNSec=1200000000\nActiveEnterTimestamp=Thu 2026-11-05 08:00:00 UTC\n\n'
printf 'Id=grassfield-shell-watchdog.service\nActiveState=inactive\nSubState=dead\nResult=success\nMainPID=0\nExecMainCode=1\nExecMainStatus=0\nNRestarts=0\nMemoryCurrent=[not set]\nMemoryPeak=[not set]\nMemorySwapPeak=[not set]\nMemoryMax=134217728\nCPUUsageNSec=[not set]\nActiveEnterTimestamp=\n'
SH
cat >"$tmp/bin/free" <<'SH'
#!/bin/sh
printf '               total        used        free      shared  buff/cache   available\nMem:           15712        9021        1203         812        6312        6691\nSwap:           4095         120        3975\n'
SH
# qs: only `qs log` of a log.qslog, whose lines name the instance (and carry a home path, the user name and a network name).
cat >"$tmp/bin/qs" <<'SH'
#!/bin/sh
echo "qs $*" >>"@LOG@/qs-args"
[ "$1" = log ] || { echo "unexpected qs $*" >&2; exit 3; }
[ "${FAKE_QS:-ok}" = broken ] && { echo "[READER] Failed to open log file" >&2; exit 255; }
for a in "$@"; do f=$a; done
id=$(basename "$(dirname "$f")")
echo "2026-11-05 10:05:02.000  INFO: Launching config: \"/usr/share/grassfield/shell/shell.qml\" instance $id"
echo "2026-11-05 10:05:03.000  WARN qml: grassfield: wallpaper @HOME@/Pictures/beach.jpg for alice ($id)"
echo "2026-11-05 10:05:04.000  INFO qml: wifi: joined ssid=\"HomeNet-QsLog-5G\" ($id)"
SH
sed -i "s|@HOME@|$home|g; s|@LOG@|$tmp/log|g" "$tmp/bin"/*
chmod 755 "$tmp/bin"/*

# As root (a container), the script runs as nobody: it refuses root by design.
as=()
runner=$(id -u)
[[ $runner == 0 ]] && runner=65534
# A fake /proc (the test hook prefixes it): the UI's and the security process's Quickshell (the runner's), another user's qs
# and a shell that is not Quickshell; the memory pressure.
fakeproc() { # pid comm uid unit rss-kB threads
  local d=$tmp/root/proc/$1
  mkdir -p "$d"
  printf '%s\n' "$2" >"$d/comm"
  printf 'Name:\t%s\nUid:\t%s\t%s\t%s\t%s\nVmHWM:\t%s kB\nVmRSS:\t%s kB\nThreads:\t%s\n' "$2" "$3" "$3" "$3" "$3" "$(($5 * 2))" "$5" "$6" >"$d/status"
  printf '0::/user.slice/user-1000.slice/user@1000.service/session.slice/%s\n' "$4" >"$d/cgroup"
  printf '55d000000000-7ffd00000000 ---p 00000000 00:00 0  [rollup]\nRss:  %s kB\nPss:  %s kB\nPss_Anon:  %s kB\nPss_File:  1024 kB\nPss_Shmem:  512 kB\nSwap:  0 kB\n' "$5" "$(($5 - 1000))" "$(($5 - 3000))" >"$d/smaps_rollup"
}
fakeproc 5101 qs "$runner" grassfield-shell.service 851968 42
fakeproc 5102 qs "$runner" grassfield-security.service 204800 17
fakeproc 5200 qs 4242 grassfield-shell.service 999999 9
fakeproc 5300 bash "$runner" grassfield-shell.service 4096 1
mkdir -p "$tmp/root/proc/pressure"
printf 'some avg10=12.50 avg60=3.10 avg300=0.80 total=123456\nfull avg10=4.00 avg60=1.00 avg300=0.20 total=45678\n' >"$tmp/root/proc/pressure/memory"
# Quickshell's runtime folder: the UI's running instance (aaaa), the one before it (bbbb, older), the security process's (cccc).
run=$tmp/run
qsr=$run/quickshell
mkdir -p "$qsr/by-id/aaaa" "$qsr/by-id/bbbb" "$qsr/by-id/cccc" "$qsr/by-pid" "$qsr/by-shell/shellui" "$qsr/by-shell/shellsec"
for i in aaaa bbbb cccc; do
  printf 'binary\n' >"$qsr/by-id/$i/log.qslog"
  printf '2026-11-05 10:05:02.000  INFO: plain log of %s for alice, ssid="HomeNet-Plain-5G"\n' "$i" >"$qsr/by-id/$i/log.log"
done
touch -d '2026-11-05 09:00' "$qsr/by-id/bbbb/log.qslog"
ln -s "$qsr/by-id/aaaa" "$qsr/by-pid/5101"
ln -s "$qsr/by-id/cccc" "$qsr/by-pid/5102"
ln -s "$qsr/by-id/aaaa" "$qsr/by-shell/shellui/aaaa"
ln -s "$qsr/by-id/bbbb" "$qsr/by-shell/shellui/bbbb"
ln -s "$qsr/by-id/cccc" "$qsr/by-shell/shellsec/cccc"
if [[ $(id -u) == 0 ]]; then
  chown -R 65534:65534 "$tmp/home" "$tmp/out" "$tmp/log" "$tmp/run"
  chmod 755 "$tmp" "$tmp/bin" "$tmp/root"
  as=("$(command -v setpriv)" --reuid=65534 --regid=65534 --clear-groups)
fi
report() { # report [env...] -- args: prints the path; FAKE_PATH replaces PATH
  local envs=()
  while [[ $# -gt 0 && $1 != -- ]]; do envs+=("$1"); shift; done
  shift || true
  env -i HOME="$home" USER=alice LOGNAME=alice PATH="$tmp/bin:/usr/bin:/bin" GRASSFIELD_DEV=1 GRASSFIELD_REPORT_ROOT="$tmp/root" \
    XDG_CURRENT_DESKTOP=Hyprland XDG_RUNTIME_DIR="$run" "${envs[@]}" "${as[@]}" "$py" -I "$script" "$@"
}

out=$(report --) && rc=0 || rc=$?
desc="it writes one file in the user's Downloads folder (from user-dirs.dirs, in the user's language) and prints its path"
check test "$rc" = 0 -a -f "$out" -a "$(dirname "$out")" = "$dl"
case $(basename "$out") in grassfield-report-[0-9]*-[0-9]*.txt) named=1 ;; *) named=0 ;; esac
desc="it is named grassfield-report-<date>-<time>.txt"
check test "$named" = 1
desc="the file is private: mode 0600"
check test "$(stat -c %a "$out")" = 600
r=$(cat "$out")

desc="every section is there"
check bash -c 'for s in "Packages" "Omarchy" "Compositor" "Compositor plugin" "Displays" "Audio devices" "Processes and units" "Units stopped by a signal (this boot)" "Crashes (last 7 days)" "Crash details of Quickshell, Hyprland and Grassfield programs (last 7 days)" "Kernel: out of memory and crashes (this boot)" "Memory killers: systemd-oomd and earlyoom (this boot)" "Journal of the Grassfield units (this boot)" "Quickshell'"'"'s own logs" "Configuration"; do grep -qF "== $s" "$1" || { echo "missing $s"; exit 1; }; done' _ "$out"
desc="versions: Grassfield's VERSION, the Grassfield, Omarchy, Hyprland, Quickshell and Qt packages, not the others"
check bash -c 'grep -q "Grassfield version: 0.9.0-beta.3" "$1" && grep -q "^grassfield-desktop 0.9.0-1" "$1" && grep -q "^grassfield-compositor" "$1" && grep -q "^hyprland 0.56.2-1" "$1" && grep -q "^omarchy 4.5.0-1" "$1" && grep -q "^qt6-base" "$1" && grep -q "^quickshell" "$1" && ! grep -q "firefox\|zsh" "$1"' _ "$out"
desc="Omarchy's version from os-release"
check bash -c 'grep -q "^VERSION_ID=4.5.0" "$1" && grep -q "^NAME=Omarchy" "$1" && ! grep -q HOME_URL "$1"' _ "$out"
desc="the plugin is reported loaded with its own reply; the compositor's version is there"
check bash -c 'grep -A1 "== Compositor plugin" "$1" | grep -q "^loaded" && grep -q "Hyprland 0.56.2" "$1"' _ "$out"
desc="displays: make, model and mode kept, the serial replaced by whether there is one, no description"
check bash -c 'grep -q "U2723QE" "$1" && grep -q "\"serial\": \"present\"" "$1" && grep -q "\"serial\": \"none\"" "$1" && ! grep -q "SERIAL-XYZ" "$1" && ! grep -q description "$1"' _ "$out"
desc="audio devices from wpctl status, crashes from coredumpctl"
check bash -c 'grep -q "Built-in Audio Analog Stereo" "$1" && grep -q "SIGSEGV" "$1"' _ "$out"
desc="the journal is this boot's, of every Grassfield user unit (grassfield-*: the security process, the menu bridge, the prompter, the portals...), a time window bounded by a memory cap in lines, not 3,000 lines"
check bash -c 'grep -qx -- "journalctl --user -b 0 -u grassfield-\* --no-pager -q -o short-iso -n 100000" "$1" && ! grep -q -- "-n 3000" "$1"' _ "$tmp/log/journal-args"
j=$(sed -n '/^== Journal of the Grassfield units/,/^== /p' "$out")
desc="item 1: the liveness probe's routine Starting/Finished pairs and its Deactivated line are left out (counted in the heading); its own miss line and its unit's failure are kept"
check bash -c '! grep -q "Starting Grassfield shell liveness probe\|Finished Grassfield shell liveness probe\|watchdog.service: Deactivated" <<<"$1" && grep -qF "50 routine runs of the liveness probe left out" <<<"$1" && grep -qF "did not answer within 5 s: 1 of 3" <<<"$1" && grep -qF "grassfield-shell-watchdog.service: Failed with result '"'"'exit-code'"'"'" <<<"$1"' _ "$j"
desc="item 1: identical consecutive lines are folded into one (×N, the last time); the heading names the window covered"
check bash -c '[[ $(grep -c "is not in the bridge" <<<"$1") == 1 ]] && grep -qF "no registrar menu (×3, last 2026-11-05T09:30:07+0000)" <<<"$1" && grep -qF "This boot, 2026-11-05T09:30:03+0000 to 2026-11-05T10:05:00+0000;" <<<"$1"' _ "$j"
k=$(sed -n '/^== Kernel: out of memory/,/^== /p' "$out")
desc="item 1: the kernel's lines of this boot (journalctl -k) about OOM and segfaults, the others left out; systemd-oomd and earlyoom lines"
check bash -c 'grep -q -- "^journalctl -k -b 0 " "$2" && grep -qF "Out of memory: Killed process 4321" <<<"$1" && grep -qF "tool[4242]: segfault at 0" <<<"$1" && ! grep -q "new high-speed USB" <<<"$1" && grep -q -- "-u systemd-oomd.service -u earlyoom.service" "$2" && grep -qF "systemd-oomd[400]: Killed /user.slice" "$3"' _ "$k" "$tmp/log/journal-args" "$out"
p=$(sed -n '/^== Processes and units/,/^== /p' "$out")
desc="item 2: every grassfield-* user unit from systemctl --user show with Result, ExecMainStatus, ExecMainCode, NRestarts, MemoryCurrent, MemoryPeak, MemorySwapPeak, CPUUsageNSec, ActiveEnterTimestamp; systemctl is only asked to show"
check bash -c 'grep -qF "grassfield-shell.service: active/running since Thu 2026-11-05 10:05:01 UTC, main pid 5101" <<<"$1" && grep -qF "Result=success ExecMainCode=2 (killed) ExecMainStatus=9 (SIGKILL) NRestarts=2 ActiveEnterTimestamp=Thu 2026-11-05 10:05:01 UTC" <<<"$1" && grep -qF "MemoryCurrent=416.0 MiB MemoryPeak=1.3 GiB MemorySwapPeak=0 B MemoryMax=3.0 GiB CPUUsageNSec=1min 24.6s" <<<"$1" && grep -q "^grassfield-security.service: active/running" <<<"$1" && grep -q "^grassfield-shell-watchdog.service: inactive/dead" <<<"$1" && for p in Result ExecMainStatus ExecMainCode NRestarts MemoryCurrent MemoryPeak MemorySwapPeak CPUUsageNSec ActiveEnterTimestamp; do grep -q "^systemctl --user show --property=.*$p" "$2" || exit 1; done && ! grep -v "^systemctl --user show " "$2"' _ "$p" "$tmp/log/systemctl-args"
desc="item 2: each of the user's Quickshell processes (the UI, the security process) with RSS and PSS from smaps_rollup and its thread count; another user's qs and a process that is not qs are not listed"
check bash -c 'grep -qF "pid 5101, the UI (grassfield-shell.service): RSS 832.0 MiB, PSS 831.0 MiB (anonymous 829.1 MiB, file 1.0 MiB, shared memory 512.0 KiB), swap 0 B; peak RSS 1.6 GiB; 42 threads" <<<"$1" && grep -qF "pid 5102, the security process (grassfield-security.service): RSS 200.0 MiB" <<<"$1" && grep -qF "; 17 threads" <<<"$1" && ! grep -q "pid 5200\|pid 5300" <<<"$1"' _ "$p"
desc="item 2: the system's memory (free) and memory pressure (/proc/pressure/memory)"
check bash -c 'grep -q "^Mem: *15712" <<<"$1" && grep -qF "some avg10=12.50 avg60=3.10" <<<"$1"' _ "$p"
w=$(sed -n '/^== Units stopped by a signal/,/^== /p' "$out")
desc="item 3: each kill of this boot with the user's and the system's journal 5 s around it (journalctl --since/--until in epoch seconds)"
check bash -c '[[ $(grep -c "^\*\*\* .*grassfield-shell.service: main process killed, status 9/KILL" <<<"$1") == 2 ]] && grep -qx -- "journalctl --user -b 0 --no-pager -q -o short-iso --since @1793872855 --until @1793872866 -n 150" "$2" && grep -qx -- "journalctl -b 0 --no-pager -q -o short-iso --since @1793873095 --until @1793873106 -n 150" "$2" && grep -qF "kernel: usb 1-1: USB disconnect" <<<"$1"' _ "$w" "$tmp/log/journal-args"
desc="item 3: the hint names the liveness probe when its kill line is there, and says no known killer left a trace when none did (a kill or pkill from outside)"
check bash -c 'grep -A1 "^\*\*\* 2026-11-05T10:01:00" <<<"$1" | grep -qF "Known killers with a trace: the liveness probe (grassfield-shell-watchdog)" && grep -A1 "^\*\*\* 2026-11-05T10:05:00" <<<"$1" | grep -qF "Known killers with a trace: none (not the liveness probe, a memory limit" && grep -qF "such as kill, pkill or killall" <<<"$1"' _ "$w"
q=$(sed -n "/^== Quickshell's own logs/,/^== /p" "$out")
desc="item 4: the last lines of the UI's and the security process's current Quickshell logs, decoded by qs log (bounded), and the UI instance before the running one (the one that ended)"
check bash -c 'grep -qF -- "--- the UI (grassfield-shell.service), the running instance, pid 5101 (aaaa)" <<<"$1" && grep -qF "instance aaaa" <<<"$1" && grep -qF -- "--- the UI (grassfield-shell.service), the instance before it (bbbb)" <<<"$1" && grep -qF -- "--- the security process (grassfield-security.service), the running instance, pid 5102 (cccc)" <<<"$1" && grep -qF "instance cccc" <<<"$1" && grep -qx "qs log --no-color --log-times --tail 150 $3/quickshell/by-id/aaaa/log.qslog" "$2"' _ "$q" "$tmp/log/qs-args" "$run"
c=$(sed -n '/^== Crash details/,/^== /p' "$out")
desc="item 5: coredumpctl info's first lines for Quickshell and Hyprland crashes (signal, executable, the first 8 frames), not for other programs; never the command line, the boot, machine or host identifiers or the core file's path"
check bash -c 'grep -qF -- "--- pid 6100" <<<"$1" && grep -qF -- "--- pid 5100" <<<"$1" && ! grep -q "pid 4242" <<<"$1" && grep -q "^Executable: /usr/bin/Hyprland" <<<"$1" && grep -q "^Signal: 11 (SEGV)" <<<"$1" && grep -qF "#7  0x00007f000000007 frame_7" <<<"$1" && ! grep -q "frame_8\|other_thread" <<<"$1" && grep -qF "[... 4 more frames left out ...]" <<<"$1" && grep -qF "(no stack: no core file was kept" <<<"$1" && ! grep -qi "Command Line\|Machine ID\|Boot ID\|Hostname\|laptop\|0123456789abcdef\|coredump/core\|Bank-Statement\|Private" <<<"$1" && grep -q "coredumpctl --no-pager --since=-7d -1 info 6100" "$2"' _ "$c" "$tmp/log/coredumpctl-args"
desc="privacy in the new sections: a home path, the user name and a network name (SSID) or window title in the kill windows, the kernel's lines and Quickshell's logs are replaced"
check bash -c 'n=$(sed -n "/^== Processes and units/,/^== Configuration/p" "$1"); ! grep -qi "alice" <<<"$n" && ! grep -qF "$2" <<<"$n" && ! grep -q "HomeNet\|Holiday-Plans" <<<"$n" && grep -qF "loaded from ~/Documents/plans.html" <<<"$n" && grep -qF "wallpaper ~/Pictures/beach.jpg for <user> (aaaa)" <<<"$n" && grep -qF "<user>-indexer" <<<"$n" && grep -qF "ssid=\"<text>\"" <<<"$n"' _ "$out" "$home"
desc="the home path is never in the report (shown as ~)"
check bash -c '! grep -qF "$2" "$1" && grep -qF "~/bin/tool" "$1" && grep -qF "~/.config/grassfield/grassfield.json" "$1"' _ "$out" "$home"
desc="the user name is never in the report, whatever its case"
check bash -c '! grep -qi "alice" "$1" && grep -q "<user> opened Settings" "$1"' _ "$out"
host=$(hostname 2>/dev/null || true)
if [[ ${#host} -ge 3 ]]; then
  desc="the host name is never in the report"
  check bash -c '! grep -qiw "$2" "$1"' _ "$out" "$host"
else
  echo "SKIP: the host name is too short to be replaced ($host)"
fi
desc="secret-looking values are removed from the configuration (JSON and key = value) and the journal; the rest is kept"
check bash -c '! grep -q "SECRET-\|abcd1234zz\|abcdefghijklmnopqrstu" "$1" && grep -q "\[redacted\]" "$1" && grep -q "\"repeatRate\": 30" "$1" && grep -q "^theme = dark" "$1" && grep -q "\"enabled\": true" "$1"' _ "$out"
desc="folder-styles.json is counted (2 entries), its folder paths are left out; a wallpaper path keeps only its file name"
check bash -c '! grep -q "Secret Plans\|Divorce\|Photos/Trip" "$1" && grep -q "2 entries" "$1" && ! grep -q "Pictures/Private\|Pictures/a.jpg" "$1" && grep -q "\"beach.jpg\"" "$1" && grep -q "\"a.jpg\"" "$1"' _ "$out"
desc="no folder path leaves: dock.folders (counted), stackOptions keys, screensaver.folder, a file:// wallpaper (file name only), a wallpaper file that is not JSON (file name only)"
check bash -c '! grep -q "Secret Plans\|Divorce\|Other Secret\|Family Album\|Private\|Stuff\|Hidden Folder" "$1" && grep -q "\"folders\": \"2 entries" "$1" && grep -q "(path 1, left out)" "$1" && grep -q "\"sunset.png\"" "$1" && grep -q "^path = dune.jpg" "$1"' _ "$out"
desc="in the Configuration section, no value is a /-path, a ~/ path or a file:// URL (the only paths are file names)"
check bash -c 'sed -n "/^== Configuration/,\$p" "$1" | grep -v "^--- " | grep -E "\"(/|~/|file://)|= *(/|~/|file://)|(^|[ =:])/[A-Za-z]" | grep -v "^ *//" ; test $? -eq 1' _ "$out"
desc="a symbolic link in the configuration folder is not followed"
check bash -c '! grep -q -- "--- linked.json" "$1"' _ "$out"
desc="monitor serials never leave through the configuration (displays.main keys, wallpaper outputs): replaced by present"
check bash -c '! grep -q "SERIAL-" "$1" && grep -qF "\"s:Dell Inc.|U2723QE|present\"" "$1" && grep -qF "\"m:BOE|NE135|eDP-1\"" "$1" && grep -qF "\"s:U2723QE|present\"" "$1" && grep -q "\"serial\": \"present\"" "$1"' _ "$out"
desc="R7-SEC-04: displays.conf keeps its lines without a serial: the connected display's cut from its description, the built-in panel (none) whole, a display not connected now without its last word; the rest of each line kept"
check bash -c 'c=$(sed -n "/^--- displays.conf/,/^--- /p" "$1"); ! grep -q "SERIAL-XYZ\|012NTPC1A234" "$1" && grep -qF "$(printf "v1\tdesc:Dell Inc. U2723QE [serial]\t3840x2160@60.00\t0x0\t1.5\t0")" <<<"$c" && grep -qF "$(printf "v1\tdesc:BOE NE135\t2256x1504@60.00")" <<<"$c" && grep -qF "$(printf "v1\tdesc:LG Electronics LG ULTRAFINE [serial]\t5120x2880@60.00\t-5120x0")" <<<"$c"' _ "$out"
desc="R7-SEC-04 (review): a display not connected now loses every word that could be a serial (a serial with a space in it), in displays.conf"
check bash -c '! grep -q "AB12CD34\|EF56" "$1" && grep -qF "$(printf "v1\tdesc:Acme Corp AC27 [serial] [serial]\t2560x1440@60.00")" "$1"' _ "$out"
desc="R7-SEC-04 (review): a display description anywhere in the journal loses its serial, the display connected or not"
check bash -c '! grep -q "1173930A0284" "$1" && grep -qF "display desc:Iiyama [serial] [serial]: no such mode" "$1"' _ "$out"
desc="R7-SEC-04 (second review): a disconnected display's serial written without desc: (its description in the journal) is removed too"
check bash -c '! grep -q "012NTPC1A234" "$1" && grep -qF "displays: LG Electronics LG ULTRAFINE [serial] is back" "$1"' _ "$out"
desc="R7-SEC-04 (review): the audio routing key of a USB device (usb:<vendor>:<product>:<serial>) loses its serial"
check bash -c '! grep -q "SN-7Y3K9QX2" "$1" && grep -qF "(usb:0x0d8c:0x0014:[serial]): personal" "$1"' _ "$out"
desc="R7-SEC-04: a connected display's serial is removed from the whole report (the journal too)"
check bash -c '! grep -q "SERIAL-XYZ" "$1" && grep -qF "Displays: DP-3 is Dell Inc. U2723QE [serial]" "$1"' _ "$out"
desc="R7-SEC-04: a USB device's ID_SERIAL in ALSA and PipeWire names (wpctl status, the journal) is removed, the rest of the name kept"
check bash -c '! grep -q "201405280001\|Y8ABCDE12345\|Focusrite\|Yeti_Stereo" "$1" && grep -qF "alsa_output.usb-[usb device]-00.analog-stereo" "$1" && grep -qF "alsa_input.usb-[usb device]-00.analog-stereo" "$1" && grep -qF "alsa_output.usb-[usb device]-00.HiFi__Line__sink" "$1"' _ "$out"
desc="the lock screen message (free text) is redacted, the lock settings are kept"
check bash -c '! grep -q "FREE-TEXT-LOCK\|0612345678" "$1" && grep -q "\"showMessage\": true" "$1" && grep -q "\"idleMinutes\": 5" "$1"' _ "$out"
desc="interface possessives in the journal keep their words (the Dock's tile, Wayland's socket, Activity Monitor's list); an audio line still loses the person's name"
check bash -c 'grep -qF "the Dock'"'"'s tile moved; Wayland'"'"'s socket is back; Activity Monitor'"'"'s list refreshed" "$1" && grep -qF "default output is now <name>’s AirPods" "$1"' _ "$out"
desc="SU-15: free text in the journal (a window title, a network name, a notification's text) is replaced by <text>; technical words and connectors stay"
check bash -c '! grep -q "Bank-Statement\|CafeLuna\|Dinner with Bob" "$1" && grep -qF "window title=\"<text>\" moved to DP-3" "$1" && grep -qF "wifi: <text>, strength 70" "$1" && grep -qF "notification from Mail: “<text>” (kind \"banner\")" "$1" && grep -qF "overlay on \"DP-1\": open with no popup" "$1"' _ "$out"
desc="people's names in device names (Marie’s AirPods, Paul's Headphones) and Bluetooth addresses are removed; the device kind stays"
check bash -c '! grep -q "Marie\|Paul" "$1" && grep -q "<name>’s AirPods" "$1" && grep -q "<name>'"'"'s Headphones" "$1" && ! grep -qi "A0:B1:C2:D3:E4:F5" "$1" && grep -q "bluez_output\." "$1"' _ "$out"
desc="the real name (GECOS) is replaced whole and word by word (3 characters or more, not generic); its other fields are not names"
check env -i PATH=/usr/bin:/bin "$py" -I -c '
import importlib.machinery, importlib.util, sys
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("report", sys.argv[1])
spec = importlib.util.spec_from_loader("report", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
names = m.identity_words("jdupont", "Jean Dupont,Room 4,555", "box")
words = [w for w, _ in names]
assert "Jean Dupont" in words and "Jean" in words and "Dupont" in words and "jdupont" in words, words
assert words.index("Jean Dupont") < words.index("Jean"), words  # the whole name first
assert "Room" not in words and "555" not in words, words
assert m.identity_words("user", "Al,Admin,,", "vm") == [], m.identity_words("user", "Al,Admin,,", "vm")
t = m.redact_identity("Jean’s AirPods; jean dupont; Jeanne stays; /h/x", "/h", names)
assert t == "<name>’s AirPods; <name>; Jeanne stays; ~/x", t
' "$script"

desc="item 3: each known killer is named from its own trace (the probe, the unit's memory limit, the kernel's OOM killer, systemd-oomd, earlyoom, a systemd timeout or watchdog), and an ordinary line names none"
check env -i PATH=/usr/bin:/bin "$py" -I -c '
import importlib.machinery, importlib.util, sys
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("report", sys.argv[1])
spec = importlib.util.spec_from_loader("report", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
def named(line):
    return [why for p, why in m.KILLERS if p.search(line)]
cases = {
    "x grassfield-shell-watchdog[7]: grassfield-shell-watchdog: the shell (pid 5) did not answer within 5 s 3 times in a row: SIGKILL, so": "the liveness probe",
    "x systemd[959]: grassfield-shell.service: A process of this unit has been killed by the OOM killer.": "a memory limit",
    "x systemd[959]: grassfield-shell.service: Failed with result \x27oom-kill\x27.": "a memory limit",
    "x kernel: Out of memory: Killed process 5101 (qs) total-vm:1kB": "the kernel\x27s OOM killer",
    "x kernel: Memory cgroup out of memory: Killed process 5101 (qs)": "the kernel\x27s OOM killer",
    "x systemd-oomd[400]: Killed /user.slice/user-1000.slice/user@1000.service/session.slice/grassfield-shell.service due to memory pressure": "systemd-oomd:",
    "x earlyoom[300]: sending SIGTERM to process 5101 uid 1000 \"qs\"": "earlyoom:",
    "x systemd[959]: grassfield-shell.service: State \x27stop-sigterm\x27 timed out. Killing.": "systemd: a stop",
    "x systemd[959]: grassfield-shell.service: Watchdog timeout (limit 30s)!": "systemd\x27s own watchdog",
}
for line, word in cases.items():
    got = named(line)
    assert any(w.startswith(word) for w in got), (line, got)
assert named("x grassfield-shell[1]: the Dock moved; a window was killed by the user in Activity Monitor") == [], "false alarm"
assert m.epoch("2026-11-21T11:16:55+01:00") == 1795256215, m.epoch("2026-11-21T11:16:55+01:00")
assert m.epoch("2026-11-05T10:01:00+0000") == 1793872860 and m.epoch("junk") is None
' "$script"

desc="item 3: the liveness probe is quiet in the journal: LogLevelMax=notice drops the user manager's routine Starting/Finished lines of its unit, SyslogLevel=notice keeps its own miss and kill lines (systemd.exec(5))"
check bash -c 'grep -qx "LogLevelMax=notice" "$1" && grep -qx "SyslogLevel=notice" "$1" && ! grep -q "^SyslogLevelPrefix=no" "$1" && grep -q "^say() { echo .* >&2; }" "$2"' _ "$root/packaging/systemd/grassfield-shell-watchdog.service" "$root/packaging/bin/grassfield-shell-watchdog"

sleep 1.1
out2=$(report --)
desc="a second report is a new file; the first is untouched"
check test "$out2" != "$out" -a -f "$out2" -a "$(cat "$out")" = "$r"

target=$tmp/out/mine.txt
out3=$(report -- --output "$target")
out4=$(report -- --output "$target")
desc="--output names the file; an existing one is never overwritten (-2), both 0600"
check test "$out3" = "$target" -a "$out4" = "$tmp/out/mine-2.txt" -a "$(stat -c %a "$out3")" = 600 -a "$(stat -c %a "$out4")" = 600
out5=$(report -- --output "$tmp/out")
desc="--output may name a folder"
check test "$(dirname "$out5")" = "$tmp/out"
nowhere=$(report -- --output /proc/nowhere/x.txt 2>/dev/null) && rc=0 || rc=$?
desc="a folder that cannot be written: exit 1, nothing printed"
check test "$rc" = 1 -a -z "$nowhere"
report -- --bogus >/dev/null 2>&1 && rc=0 || rc=$?
desc="an unknown argument is a usage error (exit 2)"
check test "$rc" = 2

outb=$(report FAKE_MONITORS=broken --)
desc="R7-SEC-04: an answer of hyprctl that is broken JSON is not copied into the report (it would carry the serials)"
check bash -c 'grep -A1 "== Displays" "$1" | grep -qx "(hyprctl'"'"'s answer is not JSON)" && ! grep -q "SERIAL-BROKEN" "$1"' _ "$outb"

out6=$(report FAKE_PLUGIN=off --)
desc="a plugin that is not loaded is said so"
check bash -c 'grep -A1 "== Compositor plugin" "$1" | grep -q "^not loaded"' _ "$out6"

out7=$(report PATH="$tmp/nobin" --)
desc="missing tools are one line each, never a failure"
check bash -c 'for t in pacman hyprctl wpctl coredumpctl journalctl systemctl free; do grep -qF "(not available: $t is not installed)" "$1" || exit 1; done' _ "$out7"

oute=$(report FAKE_EMPTY=1 --)
desc="no crash (coredumpctl exits 1) and no Grassfield unit in the journal yet (journalctl exits 1) read as none, not as errors"
check bash -c 'grep -qx "(no crash in the last 7 days)" "$1" && grep -qx "(no crash of Quickshell, Hyprland or a Grassfield program in the last 7 days)" "$1" && grep -A1 "^== Journal of the Grassfield units" "$1" | grep -qx "(no entry)" && grep -qx "(no Grassfield unit ended by a signal this boot)" "$1"' _ "$oute"

outq=$(report FAKE_QS=broken --)
desc="item 4: when qs cannot decode a log, the instance's plain log.log is shown instead (redacted)"
check bash -c 'grep -qF "INFO: plain log of aaaa for <user>, ssid=\"<text>\"" "$1" && grep -qF "plain log of cccc" "$1" && ! grep -q "HomeNet" "$1"' _ "$outq"

SECONDS=0
outt=$(report FAKE_SLOW=1 GRASSFIELD_REPORT_BUDGET=2 --)
took=$SECONDS
desc="the commands share one time budget (75 s; Settings waits 90 s): a slow command is cut at it and the later ones are one line each"
check bash -c '[[ $2 -lt 5 ]] && grep -qF "(left out: the report'"'"'s time budget of 2 s is spent)" "$1" && grep -q "^== Configuration" "$1"' _ "$outt" "$took"

out8=$(report FAKE_BIG=1 --)
desc="a long journal is cut to its last 512 KiB (the report stays under 1 MiB)"
check bash -c '[[ $(stat -c %s "$1") -lt 1048576 ]] && grep -q "bytes left out" "$1" && grep -q "line 39999" "$1"' _ "$out8"

out9=$(env -i HOME="$home" USER=alice PATH="$tmp/bin:/usr/bin:/bin" GRASSFIELD_REPORT_ROOT="$tmp/root" "${as[@]}" "$py" -I "$script")
desc="the file-root hook is a dev-session hook only (ADR-0019): ignored in any other session"
check bash -c '! grep -q "0.9.0-beta.3" "$1"' _ "$out9"
out10=$(env -i HOME="$home" USER=alice PATH="$tmp/bin:/usr/bin:/bin" GRASSFIELD_DEV=1 GRASSFIELD_SESSION=1 GRASSFIELD_REPORT_ROOT="$tmp/root" "${as[@]}" "$py" -I "$script")
check bash -c '! grep -q "0.9.0-beta.3" "$1"' _ "$out10"

if [[ $(id -u) == 0 ]]; then
  desc="run as root it refuses (exit 2) and writes nothing"
  before=$(find "$tmp" -name 'grassfield-report-*' | wc -l)
  check bash -c 'env -i HOME="$2" PATH="$3" "$4" -I "$1" >/dev/null 2>&1; rc=$?; [[ $rc == 2 ]]' _ "$script" "$home" "$tmp/bin:/usr/bin:/bin" "$py"
  check test "$(find "$tmp" -name 'grassfield-report-*' | wc -l)" = "$before"
else
  desc="it refuses root (source)"
  check grep -q "os.geteuid() == 0" "$script"
fi
# The source is read as a syntax tree: every call that starts a process (the report's run(), subprocess.*, os.system/popen,
# os.exec*, os.spawn*, os.posix_spawn*) is rejected when any string in its arguments (lists and tuples included, and every word
# of a command string) names a privilege or network tool; network modules are rejected outright. Negative controls prove that
# each form is caught.
cat >"$tmp/nocmd.py" <<'PY'
import ast, os, sys
BANNED = {"sudo", "su", "pkexec", "run0", "doas", "curl", "wget", "nc", "ncat", "netcat", "socat", "ssh", "scp", "sftp", "rsync",
          "ftp", "telnet", "aria2c", "busctl", "pactl", "pw-play", "pw-record", "pw-cat", "arecord", "aplay", "paplay",
          "parecord", "nmcli", "bluetoothctl", "hyprctl-dispatch", "loginctl", "kill", "pkill", "killall"}
SPAWN = {"run", "call", "check_call", "check_output", "Popen", "getoutput", "getstatusoutput", "system", "popen"}
NET_MODULES = {"urllib", "http", "requests", "ftplib", "smtplib", "telnetlib", "xmlrpc", "asyncio"}

def name_of(func):
    if isinstance(func, ast.Name):
        return func.id
    if isinstance(func, ast.Attribute):
        return func.attr
    return ""

def strings(node):
    for n in ast.walk(node):
        if isinstance(n, ast.Constant) and isinstance(n.value, str):
            yield n.value

# Read-only tools that also have verbs that change something: allowed only with a read verb in the same call and none of the
# writing ones (systemctl show; qs log; journalctl without vacuum/rotate/flush; coredumpctl without debug/dump/--output).
GUARDED = {
    "systemctl": ({"show"}, {"start", "stop", "restart", "try-restart", "reload", "reload-or-restart", "kill", "clean", "freeze",
                             "thaw", "enable", "disable", "reenable", "mask", "unmask", "link", "revert", "preset", "edit",
                             "set-property", "set-environment", "unset-environment", "import-environment", "daemon-reload",
                             "daemon-reexec", "reset-failed", "isolate", "bind", "mount-image", "default", "rescue",
                             "emergency", "halt", "poweroff", "reboot", "suspend", "hibernate", "kexec", "exit", "switch-root"}),
    "qs": ({"log"}, {"ipc", "kill", "msg", "-f", "--follow", "-p", "--path", "-c", "--config"}),
    "quickshell": ({"log"}, {"ipc", "kill", "msg", "-f", "--follow", "-p", "--path", "-c", "--config"}),
    "journalctl": (set(), {"--rotate", "--flush", "--sync", "--relinquish-var", "--smart-relinquish-var", "--setup-keys",
                           "--update-catalog", "-f", "--follow", "--vacuum-size", "--vacuum-time", "--vacuum-files"}),
    "coredumpctl": ({"list", "info"}, {"debug", "gdb", "dump", "-o", "--output", "--debugger", "-A", "--debugger-arguments"}),
}

def problems(source):
    out = []
    tree = ast.parse(source)
    for n in ast.walk(tree):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            mods = [a.name for a in n.names] if isinstance(n, ast.Import) else [n.module or ""]
            out += ["import %s" % m for m in mods if m.split(".")[0] in NET_MODULES]
        if isinstance(n, ast.Attribute) and n.attr in ("connect", "create_connection"):
            out.append("socket %s" % n.attr)
        if not isinstance(n, ast.Call):
            continue
        f = name_of(n.func)
        if not (f in SPAWN or f.startswith("exec") or f.startswith("spawn") or f.startswith("posix_spawn")):
            continue
        words = [w for a in list(n.args) + [k.value for k in n.keywords] for s in strings(a) for w in s.split()]
        for word in words:
            tool = os.path.basename(word)
            if tool in BANNED:
                out.append("%s(...%s...) line %d" % (f, word, n.lineno))
            if tool in GUARDED:
                need, never = GUARDED[tool]
                flags = {w.split("=", 1)[0] for w in words}
                if (need and not need & flags) or never & flags:
                    out.append("%s(...%s without a read verb or with a writing one...) line %d" % (f, word, n.lineno))
    return out

if sys.argv[1] == "--controls":
    bad = ['run(("sudo", "-n", "true"))', 'run(["timeout", "2", "curl", "https://x"])', 'os.system("curl https://x")',
           'subprocess.Popen(["/usr/bin/wget", "x"])', 'os.execvp("ssh", ["ssh", "h"])', 'os.spawnlp(os.P_WAIT, "scp", "scp", "systemd: a stop", "b")',
           'subprocess.check_output(args=["pkexec", "x"])', 'subprocess.run(["sh", "-c", "doas true"])', 'import urllib.request',
           'from http import client', 's.connect(("h", 1))', 'os.popen("nc -l 1")', 'os.posix_spawnp("su", ["su"], {})',
           'run(["systemctl", "--user", "kill", "--signal=SIGKILL", "grassfield-shell.service"])',
           'run(["systemctl", "--user", "show", "-p", "Id", "x"] + ["restart"])', 'run(["systemctl", "--user", "status", "x"])',
           'run(["qs", "ipc", "call", "x"])', 'run(["qs", "log", "-f", "x"])', 'run(["journalctl", "--user", "--vacuum-size=1M"])',
           'run(["journalctl", "--rotate"])', 'run(["coredumpctl", "debug", "1"])', 'run(["coredumpctl", "info", "-o", "/tmp/x", "1"])',
           'subprocess.run(["pkill", "qs"])', 'run(["loginctl", "lock-session"])']
    missed = [b for b in bad if not problems(b)]
    clean = problems('run(["hyprctl", "version"]); run(["pacman", "-Q"]); x = {"ssh", "session"}; print("sudo is never used");'
                     'run(["systemctl", "--user", "show", "--property=" + ",".join(P), "grassfield-*"]);'
                     'run(["qs", "log", "--no-color", "--tail", "150", f]); run(["journalctl", "-k", "-b", "0", "-n", "5"]);'
                     'run(["coredumpctl", "--no-pager", "-1", "info", pid])')
    if missed or clean:
        print("missed:", missed, "false alarms:", clean)
        sys.exit(1)
    sys.exit(0)
found = problems(open(sys.argv[1], encoding="utf-8").read())
if found:
    print("\n".join(found))
sys.exit(1 if found else 0)
PY
desc="the no-privilege/no-network check catches every spawning form (negative controls: tuples, wrapped argv, shell strings, exec, spawn, network imports) and nothing harmless"
check "$py" -I "$tmp/nocmd.py" --controls
desc="the source runs no sudo, pkexec, network, recording or playback tool and opens no connection (syntax tree)"
check "$py" -I "$tmp/nocmd.py" "$script"
desc="the PKGBUILD installs it from packaging/bin and puts it on PATH"
check bash -c 'grep -qF "find \"\$root/packaging/bin\" -maxdepth 1 -type f -exec install -m755" "$1" && grep -qE "for tool in .*grassfield-report" "$1"' _ "$root/packaging/arch/PKGBUILD"
desc="no __pycache__ left in packaging/bin"
check test ! -e "$root/packaging/bin/__pycache__"

exit $fail
