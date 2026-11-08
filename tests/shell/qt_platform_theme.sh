#!/usr/bin/env bash
# The Qt platform theme of the session and LibreOffice's toolkit (ADR-0054), without a compositor and without building:
#   - config/hypr/grassfield/qttheme.lua's choice: "xdgdesktopportal" only with the plugin installed AND stamped for the Qt
#     major.minor that is installed (a patch release is the same ABI), "gtk3" (Omarchy's value, the GTK look and GTK's chooser)
#     for every other case, each with its reason;
#   - config/hypr/session.lua applies it: the block is run with a stub of hl.env, for each case, and sets QT_QPA_PLATFORMTHEME
#     and nothing else (never SAL_USE_VCLPLUGIN, which is the uwsm env's, set when LibreOffice's Qt 6 plugin exists and tested
#     by running that snippet); every Qt GUI unit pins gtk3 or clears the variable; nothing touches the user's LibreOffice profile;
#   - the session environment, the plugin's CMake and the PKGBUILD agree: the plugin file name, Qt's plugin directory, the
#     stamp's path, the plugin's key against the first item of XDG_CURRENT_DESKTOP, the build in the PKGBUILD's build() and
#     package(), BUILD-DEPS recording qt6-base, the project in check-cmake.sh.
# Layer logic (scripts/dev/test.sh). Writes nothing.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
pass() { echo "PASS: qt_platform_theme: $1"; }
bad() { echo "FAIL: qt_platform_theme: $1"; fail=1; }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else bad "$desc"; fi; }
command -v lua >/dev/null || { echo "SKIP: qt_platform_theme: lua is not installed"; exit 0; }
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/qt-platform-theme.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cfg=$root/config/hypr
session=$cfg/session.lua
cmake=$root/packaging/qt-platform-theme/CMakeLists.txt
pkgbuild=$root/packaging/arch/PKGBUILD

# --- the choice ------------------------------------------------------------------------------------------------------------
cat >"$tmp/choose.lua" <<'LUA'
package.path = arg[1] .. "/?.lua;" .. package.path
local q = require("grassfield.qttheme")
local files = {}
local function reader(path) return files[path] end
local function exists(path) return files[path] ~= nil end
local function case(name, set, want, why)
  files = set
  local theme, reason = q.choose(reader, exists)
  local ok = theme == want and ((why == nil and reason == nil) or (why ~= nil and type(reason) == "string" and reason:find(why, 1, true) ~= nil))
  print((ok and "PASS " or "FAIL ") .. name .. " -> " .. tostring(theme) .. " " .. tostring(reason))
end
local qt = function(v) return 'set(PACKAGE_VERSION "' .. v .. '")\nif(1)\nendif()\n' end
local function installed(plugin, stamp, qtv)
  local t = {}
  if plugin then t[q.plugin] = (plugin == "short" and "\127ELF" or plugin == "magic" and string.rep("x", 6000) or "\127ELF" .. string.rep("x", 6000)) end
  if stamp then t[q.stamp] = stamp .. "\n" end
  if qtv then t[q.qt_version_file] = qt(qtv) end
  return t
end
case("same minor", installed(true, "6.12.0", "6.12.0"), "xdgdesktopportal", nil)
case("same minor, other patch", installed(true, "6.12.0", "6.12.3"), "xdgdesktopportal", nil)
case("a newer minor", installed(true, "6.12.0", "6.13.0"), "gtk3", "built for Qt 6.12")
case("an older minor", installed(true, "6.12.1", "6.11.2"), "gtk3", "Qt 6.11 is installed")
case("minor 6.1 is not 6.12", installed(true, "6.1.0", "6.12.0"), "gtk3", "built for Qt 6.1 ")
case("a newer major", installed(true, "6.12.0", "7.0.0"), "gtk3", "Qt 7.0 is installed")
case("a truncated plugin (ELF magic, 4 bytes)", installed("short", "6.12.0", "6.12.0"), "gtk3", "not a complete shared object")
case("a plugin that is not an ELF file", installed("magic", "6.12.0", "6.12.0"), "gtk3", "not a complete shared object")
case("no plugin", installed(false, "6.12.0", "6.12.0"), "gtk3", "no platform-theme plugin")
case("no stamp", installed(true, nil, "6.12.0"), "gtk3", "stamp is missing")
case("a stamp with garbage", installed(true, "banana", "6.12.0"), "gtk3", "stamp is missing")
case("Qt's version unreadable", installed(true, "6.12.0", nil), "gtk3", "installed Qt release cannot be read")
files = {}
print((q.libreoffice(function() return true end) == "qt6" and "PASS " or "FAIL ") .. "LibreOffice's qt6 plugin present -> qt6")
print((q.libreoffice(function() return false end) == nil and "PASS " or "FAIL ") .. "LibreOffice's qt6 plugin absent -> nothing")
print(((q.minor('set(PACKAGE_VERSION "6.12.0")') == "6.12") and "PASS " or "FAIL ") .. "minor() reads Qt's own file")
LUA
while IFS= read -r line; do
  case $line in
    PASS*) pass "choice: ${line#PASS }" ;;
    *) bad "choice: ${line#FAIL }" ;;
  esac
done < <(lua "$tmp/choose.lua" "$cfg" 2>&1 || echo "FAIL the choice script crashed")

# --- session.lua applies it ------------------------------------------------------------------------------------------------
# The block of session.lua between its ADR-0054 marker and the closing `end` at column 0, run with hl.env recorded.
awk '/^-- ADR-0054/ { on = 1 } on { print } on && /^end$/ { exit }' "$session" >"$tmp/block.lua"
check "session.lua holds the ADR-0054 block (a do ... end)" bash -c 'head -n 20 "$1" | grep -q "^do$" && tail -n 1 "$1" | grep -qx end' _ "$tmp/block.lua"
cat >"$tmp/apply.lua" <<'LUA'
package.path = arg[1] .. "/?.lua;" .. package.path
local scenario = arg[3]
local q = require("grassfield.qttheme")
local present = {}
local function exists(p) return present[p] == true end
local texts = {}
local function read(p) return texts[p] end
if scenario == "ok" then
  present[q.plugin] = true; texts[q.plugin] = "\127ELF" .. string.rep("x", 6000)
  texts[q.stamp] = "6.12.0\n"; texts[q.qt_version_file] = 'set(PACKAGE_VERSION "6.12.4")'
elseif scenario == "stale" then
  present[q.plugin] = true; texts[q.plugin] = "\127ELF" .. string.rep("x", 6000)
  texts[q.stamp] = "6.12.0\n"; texts[q.qt_version_file] = 'set(PACKAGE_VERSION "6.13.0")'
elseif scenario == "bare" then
  -- nothing installed
end
local real_choose, real_lo = q.choose, q.libreoffice
q.choose = function() return real_choose(read, exists) end
q.libreoffice = function() return real_lo(exists) end
local env = {}
hl = { env = function(k, v) env[#env + 1] = k .. "=" .. v end }
dofile(arg[2])
table.sort(env)
print(table.concat(env, " "))
LUA
out=$(lua "$tmp/apply.lua" "$cfg" "$tmp/block.lua" ok 2>&1)
check "plugin installed for this Qt: QT_QPA_PLATFORMTHEME=xdgdesktopportal and its copy for the shell's launches, nothing else (SAL_USE_VCLPLUGIN is the uwsm env's) [$out]" \
  test "$out" = "GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME=xdgdesktopportal QT_QPA_PLATFORMTHEME=xdgdesktopportal"
out=$(lua "$tmp/apply.lua" "$cfg" "$tmp/block.lua" stale 2>&1)
check "plugin built for another Qt minor: Omarchy's gtk3 stays (no QT_QPA_PLATFORMTHEME set), the reason is printed [$out]" \
  bash -c 'echo "$1" | grep -q "^grassfield: Qt platform theme: gtk3 kept: the plugin was built for Qt 6.12 and Qt 6.13 is installed" && ! echo "$1" | grep -q "\(^\| \)QT_QPA_PLATFORMTHEME="' _ "$out"
out=$(lua "$tmp/apply.lua" "$cfg" "$tmp/block.lua" bare 2>&1)
check "nothing installed: no variable is set, the reason is printed [$out]" \
  bash -c 'echo "$1" | grep -q "gtk3 kept: no platform-theme plugin installed" && ! echo "$1" | grep -q "\(^\| \)QT_QPA_PLATFORMTHEME="' _ "$out"
check "the block still runs when the module is missing (pcall): gtk3 stays, a line is printed" bash -c '
  printf "package.path = \"/nonexistent/?.lua\"\nhl = { env = function(k) print(\"ENV \" .. k) end }\ndofile(arg[1])\n" >"$2/missing.lua"
  out=$(lua "$2/missing.lua" "$1" 2>&1); echo "$out" | grep -q "gtk3 kept: module failed" && ! echo "$out" | grep -q "^ENV QT_QPA_PLATFORMTHEME"' _ "$tmp/block.lua" "$tmp"
check "QT_QPA_PLATFORMTHEME is set by hl.env in session.lua only, and never by the uwsm env (the Omarchy session shares neither)" bash -c '
  cd "$1" && ! grep -rn "hl.env(\"QT_QPA_PLATFORMTHEME\"" config | grep -v "config/hypr/session.lua" | grep . &&
  ! grep -n "QT_QPA_PLATFORMTHEME=" packaging/uwsm/env-grassfield | grep -v "^[0-9]*:#" | grep .' _ "$root"
check "SAL_USE_VCLPLUGIN is set in packaging/uwsm/env-grassfield (the environment the systemd user manager and D-Bus activation get, which the Dock, Launchpad and Open With launch from) and nowhere else that runs" bash -c '
  cd "$1" && grep -q "^    export SAL_USE_VCLPLUGIN=qt6$" packaging/uwsm/env-grassfield &&
  ! grep -rn "SAL_USE_VCLPLUGIN" config shell packaging/systemd packaging/session-bin | grep -v "^config/hypr/grassfield/qttheme.lua:[0-9]*:--\|^config/hypr/session.lua:[0-9]*:--" | grep .' _ "$root"
# The env-grassfield snippet, run with the plugin's path replaced: exported when the file is readable, absent otherwise.
sed -n '/^if \[ -r \/usr\/lib\/libreoffice\/program\/libvclplug_qt6lo.so \]; then$/,/^fi$/p' "$root/packaging/uwsm/env-grassfield" >"$tmp/sal.sh"
touch "$tmp/vclplug.so"
sed -i "s|/usr/lib/libreoffice/program/libvclplug_qt6lo.so|$tmp/vclplug.so|" "$tmp/sal.sh"
check "env-grassfield: with LibreOffice's Qt 6 plugin installed, SAL_USE_VCLPLUGIN=qt6 is exported ($(wc -l <"$tmp/sal.sh") lines)" \
  test "$(env -u SAL_USE_VCLPLUGIN sh -c '. "$1"; echo "${SAL_USE_VCLPLUGIN:-unset}"' _ "$tmp/sal.sh")" = qt6
rm -f "$tmp/vclplug.so"
check "env-grassfield: without it, SAL_USE_VCLPLUGIN is not set (LibreOffice keeps its own choice)" \
  test "$(env -u SAL_USE_VCLPLUGIN sh -c '. "$1"; echo "${SAL_USE_VCLPLUGIN:-unset}"' _ "$tmp/sal.sh")" = unset
check "no file of the user's LibreOffice profile is touched (no registrymodifications, no user/config path in the session files)" bash -c '
  cd "$1" && ! grep -rn "registrymodifications\|\.config/libreoffice" config/hypr packaging/uwsm packaging/session-bin shell/services 2>/dev/null | grep -v "^[^:]*:[0-9]*:\s*--\|ADR-0054" | grep .' _ "$root"

# --- the session environment, the CMake and the PKGBUILD agree --------------------------------------------------------------
target=$(sed -n 's/^qt_add_plugin(\([^ ]*\) .*/\1/p' "$cmake")
dest=$(sed -n 's/^install(TARGETS [^ ]* LIBRARY DESTINATION \(.*\))$/\1/p' "$cmake")
stamp_dest=$(sed -n 's/^install(FILES .*qt-version DESTINATION \(.*\))$/\1/p' "$cmake")
lua_path() { sed -n "s|^M\.$1 = \"\(.*\)\"|\1|p" "$cfg/grassfield/qttheme.lua"; }
check "the plugin the session looks for is the target the CMake installs under Qt's plugin directory [/usr/$dest/lib$target.so]" \
  test "$(lua_path plugin)" = "/usr/$dest/lib$target.so"
check "the stamp the session reads is the file the CMake installs [/usr/$stamp_dest/qt-version]" \
  test "$(lua_path stamp)" = "/usr/$stamp_dest/qt-version"
if [[ -x /usr/lib/qt6/bin/qtpaths ]]; then
  qtplug=$(/usr/lib/qt6/bin/qtpaths --plugin-dir 2>/dev/null)
  check "the install directory is the installed Qt's platformthemes directory [$qtplug/platformthemes]" test "/usr/$dest" = "$qtplug/platformthemes"
else
  echo "SKIP: qt_platform_theme: qtpaths is not installed (Qt's plugin directory not compared)"
fi
check "Qt's version file the session reads exists in qt6-base (when Qt is installed)" bash -c '[[ ! -d /usr/lib/cmake/Qt6Core ]] || [[ -r $1 ]]' _ "$(lua_path qt_version_file)"
check "the plugin's key is grassfield, the first item of XDG_CURRENT_DESKTOP lower-cased" bash -c '
  grep -q "\"Keys\": *\[ *\"grassfield\" *\]" "$1/packaging/qt-platform-theme/grassfield-theme.json" &&
  grep -q "^hl.env(\"XDG_CURRENT_DESKTOP\", \"Grassfield:Hyprland\")" "$1/config/hypr/session.lua"' _ "$root"
check "the PKGBUILD builds the plugin from packaging/qt-platform-theme in build() and installs it in package_grassfield-desktop" bash -c '
  p=$1/packaging/arch/PKGBUILD
  grep -q "cmake -S \"\$(_root)/packaging/qt-platform-theme\" -B \"\$srcdir/qt-platform-theme-build\"" "$p" &&
  grep -q "cmake --build \"\$srcdir/qt-platform-theme-build\"" "$p" &&
  grep -q "DESTDIR=\"\$pkgdir\" cmake --install \"\$srcdir/qt-platform-theme-build\"" "$p" &&
  awk "/^build\\(\\)/ {b=1} /^check\\(\\)/ {b=0} b && /qt-platform-theme-build/ {n++} END {exit !(n>=2)}" "$p" &&
  awk "/^package_grassfield-desktop\\(\\)/ {b=1} /^package_grassfield-compositor/ {b=0} b && /qt-platform-theme-build/ {n++} END {exit !(n>=1)}" "$p"' _ "$root"
check "BUILD-DEPS records qt6-base (the plugin is built against it; ADR-0033, the update hold pairs on its major.minor)" \
  grep -q 'pacman -Q qt6-base ' "$pkgbuild"
check "check-cmake.sh configures the plugin's project (just check)" grep -q "packaging/qt-platform-theme" "$root/scripts/dev/check-cmake.sh"
# Every Grassfield unit that runs a Qt GUI process (qs for the shell and the security process, and the apps whose main.cpp makes a
# QGuiApplication or QApplication): Qt's portal theme blocks on the portal at start (gate P5), so each pins gtk3 or clears the variable.
gui_units=0
for unit in "$root"/packaging/systemd/*.service; do
  name=$(basename "$unit" .service)
  exec_line=$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$unit" | head -n 1)
  gui=0
  [[ $exec_line == /usr/bin/qs ]] && gui=1
  bin=$(basename "${exec_line:-x}")
  app=${bin#grassfield-}
  for src in "$root/apps/$app/src/main.cpp" "$root/bridges/$app/src/main.cpp"; do
    [[ -f $src ]] && grep -qE 'Q(Gui)?Application app|QGuiApplication|QApplication' "$src" && ! grep -q 'QCoreApplication app' "$src" && gui=1
  done
  ((gui)) || continue
  gui_units=$((gui_units + 1))
  check "$name.service (a Qt GUI process) pins QT_QPA_PLATFORMTHEME=gtk3 or clears it, so it never waits on the portal at start" \
    bash -c 'grep -qx "Environment=QT_QPA_PLATFORMTHEME=gtk3" "$1" || grep -E "^UnsetEnvironment=.*\bQT_QPA_PLATFORMTHEME\b" "$1" >/dev/null' _ "$unit"
done
check "the check found the shell, the security process and the portal backend among the Qt GUI units ($gui_units found)" test "$gui_units" -ge 3
check "the settings portal backend (QtCore only) clears it as well" grep -qx 'UnsetEnvironment=GTK_USE_PORTAL QT_QPA_PLATFORMTHEME' "$root/packaging/systemd/grassfield-portal-settings.service"
# The apps the shell starts: the shell's unit pins gtk3 for itself and an app inherits the shell's environment (uwsm-app's default is a
# scope, which runs the command in its caller's environment), so the session's choice travels in GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME
# (compositor environment, named in the finalize list so that the systemd user manager gets it) and Apps.launchEnvironment gives it back.
out=$(lua "$tmp/apply.lua" "$cfg" "$tmp/block.lua" stale 2>&1)
check "gtk3 kept: GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME is still defined, empty, so a stale value in the user manager is overwritten [$out]" \
  bash -c 'echo "$1" | grep -qx "GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME="' _ "$out"
out=$(lua "$tmp/apply.lua" "$cfg" "$tmp/block.lua" bare 2>&1)
check "nothing installed: the same, empty [$out]" bash -c 'echo "$1" | grep -qx "GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME="' _ "$out"
check "the module missing: the variable is defined empty as well" bash -c '
  printf "package.path = \"/nonexistent/?.lua\"\nhl = { env = function(k, v) print(\"ENV \" .. k .. \"=\" .. v) end }\ndofile(arg[1])\n" >"$2/missing2.lua"
  lua "$2/missing2.lua" "$1" 2>&1 | grep -qx "ENV GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME="' _ "$tmp/block.lua" "$tmp"
check "autostart.lua's finalize list names GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME (the user manager, where the shell's unit reads it)" \
  grep -q 'GRASSFIELD_SESSION GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME"' "$cfg/grassfield/autostart.lua"
check "no unit clears GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME, and the shell's unit pins gtk3 without touching it" bash -c '
  ! grep -h "^UnsetEnvironment=.*GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME" "$1"/packaging/systemd/*.service | grep . &&
  grep -qx "Environment=QT_QPA_PLATFORMTHEME=gtk3" "$1/packaging/systemd/grassfield-shell.service"' _ "$root"
check "Apps.qml: launchEnvironment() and ownAppEnvironment() both carry the session's theme (so every launch path of the shell has it)" bash -c '
  f=$1/shell/services/Apps.qml
  grep -q "readonly property var themeEnvironment: AppLaunch.themeEnvironment(Mode.appsQtTheme)" "$f" &&
  grep -qF "RunMode.appsQtTheme(Quickshell.env(\"GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME\"))" "$1/shell/lib/Mode.qml" &&
  awk "/function launchEnvironment\(\)/ {a=1} a && /themeEnvironment/ {n++} /function ownAppEnvironment\(\)/ {b=1} b && /themeEnvironment/ {m++} END {exit !(n>=1 && m>=1)}" "$f"' _ "$root"
check "every launch path of Apps.qml (launchNow, runCommands, openDetached, runHelper, devOpen) takes its environment from launchEnvironment()" bash -c '
  f=$1/shell/services/Apps.qml
  [[ $(grep -c "launchEnvironment()" "$f") -ge 7 ]]' _ "$root"
exit "$fail"
