#!/usr/bin/env bash
# Keyboard launch keys (XF86Calculator, XF86Mail, ...): config/hypr/grassfield/bindings.lua binds each to
# packaging/bin/grassfield-launch-key (or the Spotlight IPC), which resolves the target from desktop entries and the
# user's default apps at press time. bindings.lua runs under a stub of `hl`; the launcher runs in dry-run mode against
# fixture desktop entries and a fixture mimeapps.list: no app is started. Needs `lua` and xdg-mime for the full run.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/launch-keys.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

if command -v lua >/dev/null; then
  cat >"$tmp/run.lua" <<'LUA'
local repo = arg[1]
local binds = {}
local function proxy(path)
  return setmetatable({}, { __index = function(_, k) return proxy(path .. "." .. k) end,
                            __call = function(_, ...) return { dsp = path, args = { ... } } end })
end
hl = setmetatable({ bind = function(keys, d, opts) binds[keys] = { d = d, opts = opts or {} } end },
  { __index = function() return function() end end })
hl.dsp = proxy("dsp")
dofile(repo .. "/config/hypr/grassfield/bindings.lua")
for _, k in ipairs({ "XF86Calculator", "XF86Mail", "XF86WWW", "XF86HomePage", "XF86Search", "XF86Explorer", "XF86MyComputer",
                     "XF86Tools", "XF86AudioMedia", "CTRL + SHIFT + ESCAPE" }) do
  local b = binds[k]
  if not b then print(k .. "\tMISSING") else
    print(k .. "\t" .. tostring(b.d.args[1]) .. "\tlocked=" .. tostring(b.opts.locked))
  end
end
LUA
  out=$(GRASSFIELD_LAUNCH_KEY=/usr/lib/grassfield/grassfield-launch-key lua "$tmp/run.lua" "$root")
  desc="every launch key has a bind, not active on the lock screen (locked = false)"
  check bash -c '! grep -q MISSING <<<"$1" && [ "$(grep -c "locked=false" <<<"$1")" = 10 ]' _ "$out"
  desc="each key reaches its target: Calculator, Mail, web (twice), Files (twice), Settings, Music, Activity Monitor (Ctrl+Shift+Esc) through the launcher; Search through Spotlight"
  check bash -c 'l=/usr/lib/grassfield/grassfield-launch-key
    grep -q "^XF86Calculator.*launch-key. calculator" <<<"$1" && grep -q "^XF86Mail.*launch-key. mail" <<<"$1" &&
    grep -q "^XF86WWW.*launch-key. web" <<<"$1" && grep -q "^XF86HomePage.*launch-key. web" <<<"$1" &&
    grep -q "^XF86Explorer.*launch-key. files" <<<"$1" && grep -q "^XF86MyComputer.*launch-key. files" <<<"$1" &&
    grep -q "^XF86Tools.*launch-key. settings" <<<"$1" && grep -q "^XF86AudioMedia.*launch-key. music" <<<"$1" &&
    grep -q "^CTRL + SHIFT + ESCAPE.*launch-key. activity" <<<"$1" &&
    grep -q "^XF86Search.*ipc.* call search toggle" <<<"$1"' _ "$out"
else
  echo "SKIP: no Lua interpreter (bind checks)"
fi

# The launcher against fixtures.
fx=$tmp/share/applications
mkdir -p "$fx" "$tmp/cfg" "$tmp/home"
entry() { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\nCategories=%s\n' "$2" "$3" "$4" >"$fx/$1"; }
entry mailer.desktop Mailer mailer 'Network;Email;'
entry browser.desktop Browser browser 'Network;WebBrowser;'
entry player.desktop Player player 'AudioVideo;Audio;'
entry zcalc.desktop ZCalc zcalc 'Utility;Calculator;'
entry acalc.desktop ACalc acalc 'Utility;Calculator;'
printf '[Default Applications]\nx-scheme-handler/mailto=mailer.desktop\nx-scheme-handler/https=browser.desktop\naudio/mpeg=player.desktop\n' >"$tmp/cfg/mimeapps.list"
printf '[Desktop Entry]\nType=Application\nName=Files\nExec=files\n' >"$fx/org.grassfield.Files.desktop"
printf '[Desktop Entry]\nType=Application\nName=Settings\nExec=settings\n' >"$fx/org.grassfield.Settings.desktop"
printf '[Desktop Entry]\nType=Application\nName=Activity Monitor\nExec=grassfield-activity\n' >"$fx/org.grassfield.Activity.desktop"
resolve() {
  env -i PATH="$PATH" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/cfg" XDG_DATA_HOME="$tmp/none" XDG_DATA_DIRS="$tmp/share" \
    GRASSFIELD_LAUNCH_DRY_RUN=1 sh "$root/packaging/bin/grassfield-launch-key" "$1"
}
desc="calculator: the first installed entry with Categories=Calculator when Omarchy's omacalc is absent"
check test "$(resolve calculator)" = acalc.desktop
entry omacalc.desktop Omacalc omacalc 'Utility;Calculator;'
desc="calculator: Omarchy's omacalc wins when installed"
check test "$(resolve calculator)" = omacalc.desktop
desc="files and settings resolve to the Grassfield apps"
check test "$(resolve files)" = org.grassfield.Files.desktop -a "$(resolve settings)" = org.grassfield.Settings.desktop
desc="activity (Ctrl+Shift+Esc, AM64) resolves to Activity Monitor"
check test "$(resolve activity)" = org.grassfield.Activity.desktop
# ADR-0055 D-6: the session's own list (XDG_CURRENT_DESKTOP names Grassfield) is read before mimeapps.list, so the web key follows a
# browser chosen in Settings or seeded at the start; Omarchy's routing entry is never the handler.
entry sanaga.desktop Sanaga sanaga 'Network;WebBrowser;'
entry omarchy-browser.desktop Browser omarchy-launch-browser 'Network;WebBrowser;'
printf '[Default Applications]\nx-scheme-handler/https=sanaga.desktop;\n' >"$tmp/cfg/grassfield-mimeapps.list"
printf '[Default Applications]\nx-scheme-handler/https=omarchy-browser.desktop\n' >"$tmp/cfg/hyprland-mimeapps.list"
resolve_session() {
  env -i PATH="$PATH" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/cfg" XDG_DATA_HOME="$tmp/none" XDG_DATA_DIRS="$tmp/share" \
    XDG_CURRENT_DESKTOP="$2" GRASSFIELD_LAUNCH_DRY_RUN=1 sh "$root/packaging/bin/grassfield-launch-key" "$1"
}
desc="web (session): the session's own list is read first: Sanaga"
check test "$(resolve_session web Grassfield:Hyprland)" = sanaga.desktop
desc="web (Omarchy session, no Grassfield item): mimeapps.list, the session list is not read"
check test "$(resolve_session web Hyprland)" = browser.desktop
rm -f "$tmp/cfg/grassfield-mimeapps.list"
desc="web (session) with no session list: mimeapps.list; the routing entry of the desktop list is never the handler"
check test "$(resolve_session web Grassfield:Hyprland)" = browser.desktop
rm -f "$tmp/cfg/hyprland-mimeapps.list"
if command -v xdg-mime >/dev/null; then
  desc="mail, web and music resolve to the user's default handlers, not a package name"
  check test "$(resolve mail)" = mailer.desktop -a "$(resolve web)" = browser.desktop -a "$(resolve music)" = player.desktop
  rm "$fx/mailer.desktop" "$fx/player.desktop"
  desc="a default whose desktop entry is not installed gives no target (the key does nothing)"
  check test -z "$(resolve mail)" -a -z "$(resolve music)"
else
  echo "SKIP: xdg-mime missing (default handler resolution)"
fi
desc="an unknown target is a usage error"
status=0; resolve bogus >/dev/null 2>&1 || status=$?
check test "$status" = 2
desc="run-mode rule: in a dev session (GRASSFIELD_DEV=1, no GRASSFIELD_SESSION) the launcher refuses (exit 3) and resolves nothing"
status=0; out=$(env -i PATH="$PATH" HOME="$tmp/home" XDG_DATA_DIRS="$tmp/share" GRASSFIELD_DEV=1 GRASSFIELD_LAUNCH_DRY_RUN=1 sh "$root/packaging/bin/grassfield-launch-key" files 2>&1) || status=$?
check test "$status" = 3 -a "${out#*refused in a dev session}" != "$out"
desc="run-mode rule: a packaged session (GRASSFIELD_SESSION=1) is not dev even when GRASSFIELD_DEV=1 leaks into it"
check test "$(env -i PATH="$PATH" HOME="$tmp/home" XDG_DATA_DIRS="$tmp/share" GRASSFIELD_DEV=1 GRASSFIELD_SESSION=1 GRASSFIELD_LAUNCH_DRY_RUN=1 sh "$root/packaging/bin/grassfield-launch-key" files)" = org.grassfield.Files.desktop
exit "$fail"
