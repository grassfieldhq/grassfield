#!/usr/bin/env bash
# R7-OMA-01 and R7-FUN-04 (owner decisions 2026-11-08): Chromium and Google Chrome draw Grassfield's traffic lights in the
# Grassfield session only. The stand-in packaging/session-bin/chromium seeds a NEW profile with the GTK appearance and hides
# Omarchy's colour policy (color.json) from the browser; nothing is installed machine-wide, so the Omarchy session runs the
# browser as shipped. Logic with a fake browser and a fake bubblewrap, static checks of the package that must agree, and one
# runtime check with the real Chromium (headless, scratch profile) that is NOT VERIFIED when it cannot start (the Claude
# sandbox forbids its singleton socket; run it bare).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/browser-session.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
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
desc="Google Chrome's session entry is installed under the session-only XDG directory, names the stand-in, and hides itself without Chrome"
check bash -c 'f=$1/xdg/applications/google-chrome.desktop; grep -qF "usr/share/grassfield/xdg/applications/google-chrome.desktop" "$1/arch/PKGBUILD" \
  && [[ $(grep -c "^Exec=/usr/lib/grassfield/session-bin/google-chrome-stable" "$f") == 3 ]] && grep -q "^TryExec=/usr/bin/google-chrome-stable$" "$f" && ! grep -q "^Exec=/usr/bin/" "$f"' _ "$pk"
desc="that directory comes first in XDG_DATA_DIRS and the stand-ins first in PATH in the Grassfield session's environment"
check bash -c 'grep -qF "/usr/share/grassfield/xdg:\${XDG_DATA_DIRS" "$1/uwsm/env-grassfield" && grep -qF "/usr/lib/grassfield/session-bin:\$PATH" "$1/uwsm/env-grassfield"' _ "$pk"
desc="nothing the package installs changes the Omarchy session's browser launch: no chromium-flags.conf, no wrapper outside session-bin"
check bash -c '! grep -qE "chromium-flags|usr/bin/(chromium|google-chrome)|/etc/chromium" <<<"$1"' _ "$body"
desc="the scriptlet does not edit /etc by hand (the upgrade from rc7 removes the old policy files through the package's own file list)"
check bash -c '! grep -qE "policies|zz-grassfield-gtk|rm .*/etc/" "$1/arch/grassfield-desktop.install"' _ "$pk"
# The rc7 package held both files in backup=; with that in the OLD package and neither in the new one, pacman deletes an
# unmodified file on upgrade and keeps an edited one as .pacsave. Read from the history when it is present.
old=$(git -C "$root" show 64debeef:packaging/arch/PKGBUILD 2>/dev/null || true)
if [[ -n $old ]]; then
  desc="upgrade from rc7: the old package tracked both policy files in backup=, the new one holds neither"
  check bash -c 'o=$(sed -n "/^  backup=(/,/)/p" <<<"$1" | tr "()\n" "   "); [[ $o == *etc/chromium/policies/managed/zz-grassfield-gtk.json* && $o == *etc/opt/chrome/policies/managed/zz-grassfield-gtk.json* ]]' _ "$old"
else
  echo "SKIP: upgrade from rc7 (commit 64debeef not in this clone)"
fi

# --- logic: the stand-in with a fake browser and a fake bubblewrap ----------------------------------------------------------
mkdir -p "$tmp/bin" "$tmp/root/etc/chromium/policies/managed" "$tmp/root/etc/opt/chrome/policies/managed"
printf '#!/bin/sh\necho "real $*" >>"$FAKE_LOG"\n' >"$tmp/bin/real"
printf '#!/bin/sh\necho "bwrap $*" >>"$FAKE_LOG"\n[ "$1 $2 $3 $4" = "--dev-bind / / true" ] && exit "${FAKE_BWRAP_PROBE:-0}"\nexit 0\n' >"$tmp/bin/bwrap"
chmod +x "$tmp/bin/real" "$tmp/bin/bwrap"
export FAKE_LOG=$tmp/log
run() { # <name> <args...>: the stand-in as `<name>`, in a clean scratch home
  local n=$1; shift
  : >"$FAKE_LOG"
  mkdir -p "$tmp/link"; ln -sf "$stand" "$tmp/link/$n"
  env -u CHROME_CONFIG_HOME XDG_CONFIG_HOME="$tmp/cfg" HOME="$tmp/home" GRASSFIELD_BROWSER_REAL="$tmp/bin/real" \
    GRASSFIELD_BROWSER_BWRAP="$tmp/bin/bwrap" GRASSFIELD_BROWSER_POLICY_ROOT="$tmp/root" bash "$tmp/link/$n" "$@"
}
seed='{"extensions":{"theme":{"system_theme":1}}}'

rm -rf "$tmp/cfg"; run chromium --foo >/dev/null
desc="a fresh Chromium profile gets the GTK appearance (Default/Preferences), the browser gets its arguments unchanged"
check bash -c '[[ $(cat "$1/cfg/chromium/Default/Preferences") == "$2" ]] && grep -qx "real --foo" "$3"' _ "$tmp" "$seed" "$FAKE_LOG"
rm -rf "$tmp/cfg"; run google-chrome-stable >/dev/null
desc="a fresh Google Chrome profile is seeded under google-chrome"
check bash -c '[[ $(cat "$1/cfg/google-chrome/Default/Preferences") == "$2" ]]' _ "$tmp" "$seed"
mkdir -p "$tmp/cfg/chromium/Default"; printf '{"extensions":{"theme":{"system_theme":0}}}\n' >"$tmp/cfg/chromium/Default/Preferences"
run chromium >/dev/null
desc="an existing profile is never rewritten (the user's choice wins), no stray temp file is left"
check bash -c '[[ $(cat "$1/cfg/chromium/Default/Preferences") == "{\"extensions\":{\"theme\":{\"system_theme\":0}}}" && -z $(ls -A "$1/cfg/chromium/Default" | grep -v "^Preferences$") ]]' _ "$tmp"
rm -rf "$tmp/cfg" "$tmp/data"; run chromium --user-data-dir="$tmp/data" --profile-directory="Profile 2" >/dev/null
desc="--user-data-dir and --profile-directory (joined form) are the profile that is seeded, nothing under the default directory"
check bash -c '[[ $(cat "$1/data/Profile 2/Preferences") == "$2" && ! -e $1/cfg ]]' _ "$tmp" "$seed"
rm -rf "$tmp/data"; run chromium --user-data-dir "$tmp/data" >/dev/null
desc="--user-data-dir as two words is read too"
check bash -c '[[ $(cat "$1/data/Default/Preferences") == "$2" ]]' _ "$tmp" "$seed"
rm -rf "$tmp/cfg"; run chromium --profile-directory=../x >/dev/null
desc="a profile directory that leaves the data directory is not seeded"
check bash -c '[[ ! -e $1/cfg/x && ! -e $1/cfg/chromium/../x/Preferences ]]' _ "$tmp"
rm -rf "$tmp/cfg"; env -u CHROME_CONFIG_HOME CHROME_CONFIG_HOME="$tmp/ch" XDG_CONFIG_HOME="$tmp/cfg" HOME="$tmp/home" GRASSFIELD_BROWSER_REAL="$tmp/bin/real" bash "$tmp/link/chromium" >/dev/null
desc="CHROME_CONFIG_HOME moves the default data directory, as in Chromium"
check bash -c '[[ -f $1/ch/chromium/Default/Preferences && ! -e $1/cfg ]]' _ "$tmp"

rm -rf "$tmp/cfg"
printf '{"BrowserThemeColor": "#1a1b26"}\n' >"$tmp/root/etc/chromium/policies/managed/color.json"
printf '{"X": 1}\n' >"$tmp/root/etc/chromium/policies/managed/other.json"
run chromium --x >/dev/null
d=$tmp/root/etc/chromium/policies/managed
desc="with Omarchy's color.json present the browser runs in bubblewrap: the directory is a tmpfs, every other file is bound back, color.json is not"
check bash -c 'grep -qxF "bwrap --dev-bind / / --tmpfs $1 --ro-bind $1/other.json $1/other.json -- $2 --x" "$3" && ! grep -q "color.json" "$3"' _ "$d" "$tmp/bin/real" "$FAKE_LOG"
desc="the files on disk are left as they were"
check bash -c '[[ -f $1/color.json && $(cat $1/color.json) == "{\"BrowserThemeColor\": \"#1a1b26\"}" ]]' _ "$d"
printf '{"BrowserThemeColor": "#1a1b26"}\n' >"$tmp/root/etc/opt/chrome/policies/managed/color.json"
run google-chrome-stable >/dev/null
desc="both policy directories are handled (Chrome's too), the real binary is the one named like the stand-in"
check bash -c 'grep -q -- "--tmpfs $1/etc/chromium/policies/managed" "$2" && grep -q -- "--tmpfs $1/etc/opt/chrome/policies/managed" "$2" && grep -q -- "-- .*/real$" "$2"' _ "$tmp/root" "$FAKE_LOG"
FAKE_BWRAP_PROBE=1 run chromium --y >/dev/null || true
desc="where bubblewrap cannot run (user namespaces off), the browser starts as it is: only the probe ran, then the real browser"
check bash -c '[[ $(wc -l <"$1") == 2 ]] && sed -n 1p "$1" | grep -qx "bwrap --dev-bind / / true" && sed -n 2p "$1" | grep -qx "real --y"' _ "$FAKE_LOG"
rm -f "$tmp/root/etc/chromium/policies/managed/color.json" "$tmp/root/etc/opt/chrome/policies/managed/color.json"
run chromium --z >/dev/null
desc="without color.json there is nothing to hide: bubblewrap is not started"
check bash -c '[[ $(cat "$1") == "real --z" ]]' _ "$FAKE_LOG"
desc="a missing bubblewrap binary degrades the same way"
printf '{"BrowserThemeColor": "#1a1b26"}\n' >"$tmp/root/etc/chromium/policies/managed/color.json"
: >"$FAKE_LOG"
env XDG_CONFIG_HOME="$tmp/cfg" HOME="$tmp/home" GRASSFIELD_BROWSER_REAL="$tmp/bin/real" GRASSFIELD_BROWSER_BWRAP="$tmp/bin/nope" GRASSFIELD_BROWSER_POLICY_ROOT="$tmp/root" bash "$tmp/link/chromium" --w >/dev/null
check bash -c '[[ $(cat "$1") == "real --w" ]]' _ "$FAKE_LOG"

# --- runtime: the real Chromium, a scratch profile, launched through the stand-in ------------------------------------------
# What it proves: through the stand-in (bubblewrap included when this machine has an Omarchy color.json) a real Chromium
# starts, and a new profile comes out of the run with the GTK appearance pref, neither dropped nor reset by Chromium. The
# lights themselves are a pixel measurement: tests/compositor/gtk_lights.sh (nested).
if command -v chromium >/dev/null && command -v bwrap >/dev/null; then
  prof=$tmp/real-profile
  mkdir -p "$tmp/home"
  if env -u WAYLAND_DISPLAY HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/cfg2" XDG_CACHE_HOME="$tmp/cache" timeout 60 \
    bash "$stand" --headless=new --no-sandbox --disable-gpu --disable-crash-reporter --no-first-run --disable-background-networking \
    --user-data-dir="$prof" --dump-dom about:blank >"$tmp/real.out" 2>&1; then
    desc="runtime: the fresh scratch profile keeps the GTK appearance pref after a real Chromium run"
    check python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["extensions"]["theme"]["system_theme"] == 1 else 1)' "$prof/Default/Preferences"
  else
    echo "NOT VERIFIED: runtime (Chromium did not run here: $(tail -n1 "$tmp/real.out" | cut -c1-160)); run this script bare"
  fi
else
  echo "NOT VERIFIED: runtime (chromium or bwrap is not installed)"
fi

exit $fail
