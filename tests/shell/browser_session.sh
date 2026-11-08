#!/usr/bin/env bash
# R7-OMA-01 and R7-FUN-04 (owner decisions 2026-11-08): Chromium and Google Chrome draw Grassfield's traffic lights in the
# Grassfield session only. The stand-in packaging/session-bin/chromium seeds a NEW profile with the GTK appearance and masks
# Omarchy's colour policy (only color.json, with --ro-bind /dev/null) from the browser; nothing is installed machine-wide, so
# the Omarchy session runs the browser as shipped. Logic with a fake browser and a fake bubblewrap, runtime checks with the
# real bubblewrap (a scratch policy directory) and the real Chromium (scratch profile, its own sandbox on, no --no-sandbox),
# and static checks of the package that must agree. A runtime check that cannot start is NOT VERIFIED (the Claude sandbox
# forbids user namespaces and Chromium's singleton socket): run this script bare.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/browser-session.XXXXXX")
cleanup() { pkill -f -- "--user-data-dir=$tmp" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
unset GRASSFIELD_SESSION QT_QPA_PLATFORMTHEME CHROME_CONFIG_HOME
pk=$root/packaging
stand=$pk/session-bin/chromium

# --- static: the package -------------------------------------------------------------------------------------------------
body=$(grep -vE '^[[:space:]]*#' "$pk/arch/PKGBUILD")
desc="the package installs nothing under /etc/chromium or /etc/opt/chrome (the Omarchy session keeps its browsers as shipped)"
check bash -c '! grep -qE "etc/(chromium|opt/chrome|opt/edge|brave)|policies/managed|zz-grassfield-gtk" <<<"$1"' _ "$body"
desc="backup= holds the SDDM drop-in only (a removed file is not kept as a config file)"
check bash -c 'b=$(sed -n "/^  backup=(/,/)/p" "$1/arch/PKGBUILD" | tr "()\n" "   ") && [[ " $b " == *" etc/sddm.conf.d/grassfield.conf "* && $b != *policies* && $b != *zz-grassfield* ]]' _ "$pk"
desc="the stand-in is an executable regular file in session-bin, and the PKGBUILD links google-chrome-stable to it"
lnline='ln -s chromium "$pkgdir/usr/lib/grassfield/session-bin/google-chrome-stable"'
check bash -c '[[ -f $1 && -x $1 ]] && grep -qF "$3" "$2/arch/PKGBUILD"' _ "$stand" "$pk" "$lnline"
desc="grassfield-desktop depends on bubblewrap (the stand-in needs it where Omarchy's colour policy exists)"
check bash -c 'sed -n "/^package_grassfield-desktop()/,/^}/p" "$1/arch/PKGBUILD" | grep -qE "^  depends=\(.*[( ]bubblewrap[ )]"' _ "$pk"
desc="Google Chrome's session entry is installed under the session-only XDG directory, names the stand-in, and hides itself without Chrome"
check bash -c 'f=$1/xdg/applications/google-chrome.desktop; grep -qF "usr/share/grassfield/xdg/applications/google-chrome.desktop" "$1/arch/PKGBUILD" \
  && [[ $(grep -c "^Exec=/usr/lib/grassfield/session-bin/google-chrome-stable" "$f") == 3 ]] && grep -q "^TryExec=/usr/bin/google-chrome-stable$" "$f" && ! grep -q "^Exec=/usr/bin/" "$f"' _ "$pk"
desc="that directory comes first in XDG_DATA_DIRS and the stand-ins first in PATH in the Grassfield session's environment"
check bash -c 'grep -qF "/usr/share/grassfield/xdg:\${XDG_DATA_DIRS" "$1/uwsm/env-grassfield" && grep -qF "/usr/lib/grassfield/session-bin:\$PATH" "$1/uwsm/env-grassfield"' _ "$pk"
desc="nothing the package installs changes the Omarchy session's browser launch: no chromium-flags.conf, no wrapper outside session-bin"
check bash -c '! grep -qE "chromium-flags|usr/bin/(chromium|google-chrome)|/etc/chromium" <<<"$1"' _ "$body"
desc="the stand-in runs the browser and bubblewrap by absolute path, masks only color.json, and has no tmpfs over a policy directory"
check bash -c 'f=$1; grep -q "^real=/usr/bin/\$name$" "$f" && grep -q "^bwrap=/usr/bin/bwrap$" "$f" && grep -qF -- "--ro-bind /dev/null \"\$dir/color.json\"" "$f" && ! grep -qE "^[^#]*--tmpfs" "$f"' _ "$stand"
desc="the scriptlet never deletes an administrator's file: it only names the .pacsave and what to do (rc7 upgrade)"
check bash -c 'i=$1/arch/grassfield-desktop.install; grep -q "zz-grassfield-gtk.json" "$i" && grep -q "pacsave" "$i" && ! grep -vE "^[[:space:]]*#" "$i" | grep -qE "(^|[^a-z])rm[[:space:]]+(-[a-z]+[[:space:]]+)*[^\"]*(policies|zz-grassfield)" ' _ "$pk"
# The rc7 package held both files in backup=; with that in the OLD package and neither in the new one, pacman deletes an
# unmodified file on upgrade and keeps an edited one as .pacsave. Read from the history when it is present.
old=$(git -C "$root" show 64debeef:packaging/arch/PKGBUILD 2>/dev/null || true)
if [[ -n $old ]]; then
  desc="upgrade from rc7: the old package tracked both policy files in backup=, the new one holds neither"
  check bash -c 'o=$(sed -n "/^  backup=(/,/)/p" <<<"$1" | tr "()\n" "   "); [[ $o == *etc/chromium/policies/managed/zz-grassfield-gtk.json* && $o == *etc/opt/chrome/policies/managed/zz-grassfield-gtk.json* ]]' _ "$old"
else
  echo "SKIP: upgrade from rc7 (commit 64debeef not in this clone)"
fi
# The notice, run for real (post_upgrade of the scriptlet, with a fake root): an edited rc7 file as .pacsave is named, nothing is deleted.
inst=$pk/arch/grassfield-desktop.install
mkdir -p "$tmp/fakeroot"
sed -e "s|/etc/chromium|$tmp/fakeroot/etc/chromium|g" -e "s|/etc/opt/chrome|$tmp/fakeroot/etc/opt/chrome|g" "$inst" >"$tmp/install.sh"
mkdir -p "$tmp/fakeroot/etc/chromium/policies/managed" "$tmp/fakeroot/etc/opt/chrome/policies/managed"
printf '{"HomepageLocation": "https://example.org"}\n' >"$tmp/fakeroot/etc/chromium/policies/managed/zz-grassfield-gtk.json.pacsave"
notice=$(bash -c '. "$1"; post_upgrade 1.0.0rc8-1 1.0.0rc7-1' _ "$tmp/install.sh" 2>&1 | grep -F "pacsave" || true)
desc="post_upgrade names the kept .pacsave, says it still applies to the Omarchy session, and leaves the file in place"
check bash -c '[[ $1 == *"zz-grassfield-gtk.json.pacsave"* && $1 == *"Omarchy"* && -f $2/fakeroot/etc/chromium/policies/managed/zz-grassfield-gtk.json.pacsave ]]' _ "$notice" "$tmp"
desc="post_upgrade says nothing when no file is left (the unmodified case)"
rm -f "$tmp/fakeroot/etc/chromium/policies/managed/zz-grassfield-gtk.json.pacsave"
quiet=$(bash -c '. "$1"; post_upgrade 1.0.0rc8-1 1.0.0rc7-1' _ "$tmp/install.sh" 2>&1 | grep -cF "pacsave" || true)
check bash -c '[[ $1 == 0 ]]' _ "$quiet"

# --- logic: the stand-in with a fake browser and a fake bubblewrap ----------------------------------------------------------
mkdir -p "$tmp/bin" "$tmp/root/etc/chromium/policies/managed" "$tmp/root/etc/opt/chrome/policies/managed"
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "Chromium 155.0.8059.84 Arch Linux"; exit 0; }\necho "real $*" >>"$FAKE_LOG"\n' >"$tmp/bin/real"
printf '#!/bin/sh\necho "bwrap $*" >>"$FAKE_LOG"\n[ "$1 $2 $3 $4" = "--dev-bind / / true" ] && exit "${FAKE_BWRAP_PROBE:-0}"\nexit 0\n' >"$tmp/bin/bwrap"
chmod +x "$tmp/bin/real" "$tmp/bin/bwrap"
export FAKE_LOG=$tmp/log
run() { # <name> <args...>: the stand-in as `<name>`, in a clean scratch home, as a dev run
  local n=$1; shift
  : >"$FAKE_LOG"
  mkdir -p "$tmp/link"; ln -sf "$stand" "$tmp/link/$n"
  env -u CHROME_CONFIG_HOME GRASSFIELD_DEV=1 XDG_CONFIG_HOME="$tmp/cfg" HOME="$tmp/home" GRASSFIELD_BROWSER_REAL="$tmp/bin/real" \
    GRASSFIELD_BROWSER_BWRAP="$tmp/bin/bwrap" GRASSFIELD_BROWSER_POLICY_ROOT="$tmp/root" bash "$tmp/link/$n" "$@"
}
seed='{"profile":{"created_by_version":"155.0.8059.84"},"extensions":{"theme":{"system_theme":1}}}'

rm -rf "$tmp/cfg"; run chromium --foo >/dev/null
desc="a fresh Chromium profile gets the GTK appearance and the installed version as created_by_version; the browser gets its arguments unchanged"
check bash -c '[[ $(cat "$1/cfg/chromium/Default/Preferences") == "$2" ]] && grep -qx "real --foo" "$3"' _ "$tmp" "$seed" "$FAKE_LOG"
rm -rf "$tmp/cfg"; run google-chrome-stable >/dev/null
desc="a fresh Google Chrome profile is seeded under google-chrome"
check bash -c '[[ $(cat "$1/cfg/google-chrome/Default/Preferences") == "$2" ]]' _ "$tmp" "$seed"
mkdir -p "$tmp/cfg/chromium/Default"; printf '{"extensions":{"theme":{"system_theme":0}}}\n' >"$tmp/cfg/chromium/Default/Preferences"
run chromium >/dev/null
desc="an existing profile is never rewritten (the user's choice wins), no stray temp file is left"
check bash -c '[[ $(cat "$1/cfg/chromium/Default/Preferences") == "{\"extensions\":{\"theme\":{\"system_theme\":0}}}" && -z $(ls -A "$1/cfg/chromium/Default" | grep -v "^Preferences$") ]]' _ "$tmp"
rm -rf "$tmp/cfg" "$tmp/data"; mkdir -p "$tmp/data/Default" "$tmp/victim"
ln -s "$tmp/victim/target" "$tmp/data/Default/Preferences"
run chromium --user-data-dir="$tmp/data" >/dev/null
desc="a planted link named Preferences is not followed (nothing is written through it)"
check bash -c '[[ ! -e $1/victim/target ]]' _ "$tmp"
rm -rf "$tmp/data"; mkdir -p "$tmp/data/Default"
for p in 1 2 3; do ln -s "$tmp/victim/t$p" "$tmp/data/Default/.Preferences.grassfield.$p"; done
run chromium --user-data-dir="$tmp/data" >/dev/null
desc="a planted link where the temporary file would be is not followed either"
check bash -c '[[ -z $(ls "$1/victim") ]]' _ "$tmp"
rm -rf "$tmp/cfg" "$tmp/data"; run chromium --user-data-dir="$tmp/data" --profile-directory="Profile 2" >/dev/null
desc="--user-data-dir and --profile-directory (joined form) are the profile that is seeded, nothing under the default directory"
check bash -c '[[ $(cat "$1/data/Profile 2/Preferences") == "$2" && ! -e $1/cfg ]]' _ "$tmp" "$seed"
rm -rf "$tmp/data"; run chromium --user-data-dir "$tmp/data" >/dev/null
desc="--user-data-dir as two words is read too"
check bash -c '[[ $(cat "$1/data/Default/Preferences") == "$2" ]]' _ "$tmp" "$seed"
rm -rf "$tmp/cfg"; run chromium --profile-directory=../x >/dev/null
desc="a profile directory that leaves the data directory is not seeded"
check bash -c '[[ ! -e $1/cfg/x && ! -e $1/cfg/chromium/../x/Preferences ]]' _ "$tmp"
rm -rf "$tmp/cfg"; env -u CHROME_CONFIG_HOME GRASSFIELD_DEV=1 CHROME_CONFIG_HOME="$tmp/ch" XDG_CONFIG_HOME="$tmp/cfg" HOME="$tmp/home" GRASSFIELD_BROWSER_REAL="$tmp/bin/real" bash "$tmp/link/chromium" >/dev/null
desc="CHROME_CONFIG_HOME moves the default data directory, as in Chromium"
check bash -c '[[ -f $1/ch/chromium/Default/Preferences && ! -e $1/cfg ]]' _ "$tmp"

rm -rf "$tmp/cfg"
d=$tmp/root/etc/chromium/policies/managed
printf '{"BrowserThemeColor": "#1a1b26"}\n' >"$d/color.json"
printf '{"X": 1}\n' >"$d/other.json"; printf '{"Y": 1}\n' >"$d/.corp.json"
run chromium --x >/dev/null
desc="with Omarchy's color.json present the browser runs in bubblewrap with that one file bound to /dev/null: no tmpfs, no other file named"
check bash -c 'grep -qxF "bwrap --dev-bind / / --ro-bind /dev/null $1/color.json -- $2 --x" "$3" && ! grep -qE "tmpfs|other.json|corp" "$3"' _ "$d" "$tmp/bin/real" "$FAKE_LOG"
desc="the files on disk are left as they were"
check bash -c '[[ $(cat $1/color.json) == "{\"BrowserThemeColor\": \"#1a1b26\"}" && -f $1/.corp.json ]]' _ "$d"
printf '{"BrowserThemeColor": "#1a1b26"}\n' >"$tmp/root/etc/opt/chrome/policies/managed/color.json"
run google-chrome-stable >/dev/null
desc="both policy directories are handled (Chrome's too), the real binary is the one named like the stand-in"
check bash -c 'grep -q -- "--ro-bind /dev/null $1/etc/chromium/policies/managed/color.json" "$2" && grep -q -- "--ro-bind /dev/null $1/etc/opt/chrome/policies/managed/color.json" "$2" && grep -q -- "-- .*/real$" "$2"' _ "$tmp/root" "$FAKE_LOG"
FAKE_BWRAP_PROBE=1 run chromium --y >/dev/null || true
desc="where bubblewrap cannot run (user namespaces off), the browser starts as it is: only the probe ran, then the real browser"
check bash -c '[[ $(wc -l <"$1") == 2 ]] && sed -n 1p "$1" | grep -qx "bwrap --dev-bind / / true" && sed -n 2p "$1" | grep -qx "real --y"' _ "$FAKE_LOG"
rm -f "$d/color.json" "$tmp/root/etc/opt/chrome/policies/managed/color.json"
run chromium --z >/dev/null
desc="without color.json there is nothing to hide: bubblewrap (and its no_new_privs) is not started, not even probed"
check bash -c '[[ $(cat "$1") == "real --z" ]]' _ "$FAKE_LOG"
printf '{"BrowserThemeColor": "#1a1b26"}\n' >"$d/color.json"
: >"$FAKE_LOG"
env GRASSFIELD_DEV=1 XDG_CONFIG_HOME="$tmp/cfg" HOME="$tmp/home" GRASSFIELD_BROWSER_REAL="$tmp/bin/real" GRASSFIELD_BROWSER_BWRAP="$tmp/bin/nope" GRASSFIELD_BROWSER_POLICY_ROOT="$tmp/root" bash "$tmp/link/chromium" --w >/dev/null
desc="a missing bubblewrap binary degrades the same way"
check bash -c '[[ $(cat "$1") == "real --w" ]]' _ "$FAKE_LOG"
# In a real session (GRASSFIELD_SESSION=1) or without GRASSFIELD_DEV the overrides are ignored: the absolute paths run.
: >"$FAKE_LOG"
env GRASSFIELD_SESSION=1 GRASSFIELD_DEV=1 XDG_CONFIG_HOME="$tmp/cfg" HOME="$tmp/home" GRASSFIELD_BROWSER_REAL="$tmp/bin/real" GRASSFIELD_BROWSER_BWRAP="$tmp/bin/bwrap" GRASSFIELD_BROWSER_POLICY_ROOT="$tmp/root" bash "$tmp/link/chromium" --version >/dev/null 2>&1 || true
desc="the test variables are inert in a real session: the real /usr/bin/chromium answered, not the fake"
check bash -c '[[ ! -s $1 ]]' _ "$FAKE_LOG"
env -u GRASSFIELD_DEV GRASSFIELD_BROWSER_REAL="$tmp/bin/real" XDG_CONFIG_HOME="$tmp/cfg" HOME="$tmp/home" bash "$tmp/link/chromium" --version >/dev/null 2>&1 || true
desc="and without GRASSFIELD_DEV as well"
check bash -c '[[ ! -s $1 ]]' _ "$FAKE_LOG"
ln -sf "$stand" "$tmp/link/firefox"
desc="the stand-in refuses a name it does not know"
check bash -c '! GRASSFIELD_DEV=1 bash "$1" 2>/dev/null' _ "$tmp/link/firefox"

# --- runtime with the real bubblewrap, a scratch policy directory ------------------------------------------------------------
# A fake browser that reports what it sees through the mask; bubblewrap is the real one (needs user namespaces).
if command -v bwrap >/dev/null && /usr/bin/bwrap --dev-bind / / true 2>/dev/null; then
  rd=$tmp/rroot/etc/chromium/policies/managed
  mkdir -p "$rd"
  printf '{"BrowserThemeColor": "#1a1b26"}\n' >"$rd/color.json"
  printf '{"A": 1}\n' >"$rd/.corp.json"
  printf '{"B": 1}\n' >"$rd/other.json"
  cat >"$tmp/bin/probe" <<EOF
#!/bin/sh
[ "\$1" = --version ] && { echo "Chromium 155.0.8059.84 Arch Linux"; exit 0; }
echo "colorsize=\$(stat -c %s "$rd/color.json")" >"$tmp/probe.out"
echo "dot=\$(cat "$rd/.corp.json")" >>"$tmp/probe.out"
echo "fstype=\$(stat -f -c %T "$rd")" >>"$tmp/probe.out"
echo "mounts=\$(grep -c " $rd" /proc/self/mountinfo)" >>"$tmp/probe.out"
echo "nnp=\$(sed -n 's/^NoNewPrivs:[[:space:]]*//p' /proc/self/status)" >>"$tmp/probe.out"
touch "$tmp/probe.ready"
while [ ! -e "$tmp/probe.go" ]; do sleep 0.1; done
echo "new=\$(cat "$rd/added.json" 2>&1)" >>"$tmp/probe.out"
echo "replaced=\$(cat "$rd/other.json")" >>"$tmp/probe.out"
EOF
  chmod +x "$tmp/bin/probe"
  rm -f "$tmp/probe.ready" "$tmp/probe.go"
  (env GRASSFIELD_DEV=1 XDG_CONFIG_HOME="$tmp/cfg" HOME="$tmp/home" GRASSFIELD_BROWSER_REAL="$tmp/bin/probe" GRASSFIELD_BROWSER_POLICY_ROOT="$tmp/rroot" \
    bash "$tmp/link/chromium" >/dev/null 2>&1) &
  for _ in $(seq 1 100); do [[ -e $tmp/probe.ready ]] && break; sleep 0.1; done
  printf '{"C": 1}\n' >"$rd/added.json"; printf '{"B": 2}\n' >"$rd/other.json"   # an administrator's change while the browser runs
  touch "$tmp/probe.go"; wait
  desc="real bubblewrap: color.json is empty to the browser, the real file on disk is not"
  check bash -c 'grep -qx "colorsize=0" "$1/probe.out" && [[ -s $2/color.json ]]' _ "$tmp" "$rd"
  desc="real bubblewrap: a dot-named admin policy is still visible to the browser"
  check grep -qxF 'dot={"A": 1}' "$tmp/probe.out"
  desc="real bubblewrap: a policy file added and one replaced while the browser runs are seen"
  check bash -c 'grep -qxF "new={\"C\": 1}" "$1" && grep -qxF "replaced={\"B\": 2}" "$1"' _ "$tmp/probe.out"
  desc="real bubblewrap: the policy directory is the real one, not a tmpfs, and only color.json is a mount inside it"
  check bash -c '! grep -qx "fstype=tmpfs" "$1" && grep -qx "mounts=1" "$1"' _ "$tmp/probe.out"
  echo "NOTE: no_new_privs in the browser under bubblewrap: $(grep '^nnp=' "$tmp/probe.out")"
  desc="real bubblewrap: no_new_privs is set (the documented limit)"
  check grep -qx 'nnp=1' "$tmp/probe.out"
else
  echo "NOT VERIFIED: runtime with the real bubblewrap (user namespaces are not available here; run this script bare)"
fi

# --- runtime: the real Chromium, a scratch profile, launched through the stand-in ------------------------------------------
# Its own sandbox stays on (no --no-sandbox): a renderer must have seccomp 2. What it also proves: a new profile comes out of
# the run with the GTK appearance pref and created_by_version. The lights are a pixel measurement: tests/compositor/gtk_lights.sh.
if [[ -x /usr/bin/chromium ]]; then
  prof=$tmp/real-profile
  mkdir -p "$tmp/home"
  port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  env -u WAYLAND_DISPLAY GRASSFIELD_DEV=1 HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/cfg2" XDG_CACHE_HOME="$tmp/cache" \
    bash "$stand" --headless=new --disable-gpu --disable-crash-reporter --no-first-run --disable-background-networking \
    --remote-debugging-port="$port" --user-data-dir="$prof" about:blank >"$tmp/real.out" 2>&1 &
  seccomp=
  for _ in $(seq 1 150); do
    for pid in $(pgrep -f -- "--user-data-dir=$prof" 2>/dev/null || true); do
      if tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q -- "--type=renderer"; then
        seccomp=$(sed -n 's/^Seccomp:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null || true)
        [[ -n $seccomp ]] && break 2
      fi
    done
    sleep 0.2
  done
  if [[ -z $seccomp ]]; then
    echo "NOT VERIFIED: runtime (no Chromium renderer appeared: $(tail -n1 "$tmp/real.out" | cut -c1-160)); run this script bare"
  else
    desc="runtime: a renderer of the browser started through the stand-in has seccomp 2 (Chromium's own sandbox is on)"
    check test "$seccomp" = 2
    desc="runtime: the fresh scratch profile has the GTK appearance pref and created_by_version after a real run"
    check python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["extensions"]["theme"]["system_theme"] == 1 and d["profile"]["created_by_version"] else 1)' "$prof/Default/Preferences"
  fi
  pkill -f -- "--user-data-dir=$prof" 2>/dev/null || true
else
  echo "NOT VERIFIED: runtime (chromium is not installed)"
fi

exit $fail
