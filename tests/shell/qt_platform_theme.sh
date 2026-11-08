#!/usr/bin/env bash
# The Qt platform theme of the session and LibreOffice's toolkit (ADR-0054), without a compositor and without building:
#   - config/hypr/grassfield/qttheme.lua's choice: "xdgdesktopportal" only with the plugin installed AND stamped for the Qt
#     major.minor that is installed (a patch release is the same ABI), "gtk3" (Omarchy's value, the GTK look and GTK's chooser)
#     for every other case, each with its reason;
#   - config/hypr/session.lua applies it: the block is run with a stub of hl.env, for each case, and sets QT_QPA_PLATFORMTHEME
#     and SAL_USE_VCLPLUGIN=qt6 (only when LibreOffice's Qt 6 plugin exists) and nothing else; both variables are set only in
#     session.lua (the Omarchy session never loads it) and never in the user's LibreOffice profile;
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
  if plugin then t[q.plugin] = "ELF" end
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
  present[q.plugin] = true; present[q.libreoffice_plugin] = true
  texts[q.stamp] = "6.12.0\n"; texts[q.qt_version_file] = 'set(PACKAGE_VERSION "6.12.4")'
elseif scenario == "stale" then
  present[q.plugin] = true; present[q.libreoffice_plugin] = true
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
check "plugin installed for this Qt: QT_QPA_PLATFORMTHEME=xdgdesktopportal and SAL_USE_VCLPLUGIN=qt6, nothing else [$out]" \
  test "$out" = "QT_QPA_PLATFORMTHEME=xdgdesktopportal SAL_USE_VCLPLUGIN=qt6"
out=$(lua "$tmp/apply.lua" "$cfg" "$tmp/block.lua" stale 2>&1)
check "plugin built for another Qt minor: Omarchy's gtk3 stays (no QT_QPA_PLATFORMTHEME set), the reason is printed, LibreOffice still gets qt6 [$out]" \
  bash -c 'echo "$1" | grep -q "^grassfield: Qt platform theme: gtk3 kept: the plugin was built for Qt 6.12 and Qt 6.13 is installed" && echo "$1" | grep -qx "SAL_USE_VCLPLUGIN=qt6" && ! echo "$1" | grep -q "QT_QPA_PLATFORMTHEME="' _ "$out"
out=$(lua "$tmp/apply.lua" "$cfg" "$tmp/block.lua" bare 2>&1)
check "nothing installed: no variable is set, the reason is printed [$out]" \
  bash -c 'echo "$1" | grep -q "gtk3 kept: no platform-theme plugin installed" && ! echo "$1" | grep -q "SAL_USE_VCLPLUGIN=\|QT_QPA_PLATFORMTHEME="' _ "$out"
check "the block still runs when the module is missing (pcall): gtk3 stays, a line is printed" bash -c '
  printf "package.path = \"/nonexistent/?.lua\"\nhl = { env = function(k) print(\"ENV \" .. k) end }\ndofile(arg[1])\n" >"$2/missing.lua"
  out=$(lua "$2/missing.lua" "$1" 2>&1); echo "$out" | grep -q "gtk3 kept: module failed" && ! echo "$out" | grep -q "^ENV"' _ "$tmp/block.lua" "$tmp"
check "QT_QPA_PLATFORMTHEME and SAL_USE_VCLPLUGIN are set in session.lua only (never in the files the Omarchy session shares, nor in the uwsm env)" bash -c '
  cd "$1" && ! grep -rln "SAL_USE_VCLPLUGIN" config packaging/uwsm packaging/systemd packaging/session-bin shell 2>/dev/null | grep -v "config/hypr/grassfield/qttheme.lua\|config/hypr/session.lua" | grep . &&
  ! grep -rn "hl.env(\"QT_QPA_PLATFORMTHEME\"" config | grep -v "config/hypr/session.lua" | grep . &&
  ! grep -n "QT_QPA_PLATFORMTHEME=\|export SAL_USE\|SAL_USE_VCLPLUGIN" packaging/uwsm/env-grassfield | grep -v "^[0-9]*:#" | grep .' _ "$root"
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
check "the plugin links Qt's private GUI module and says why" bash -c 'grep -q "Qt6::GuiPrivate" "$1" && grep -q "QPA" "$1"' _ "$cmake"
check "the plugin source falls back with a warning, never silently (qCWarning on a missing gtk3 theme)" \
  grep -q 'qCWarning(lcGrassfieldTheme)' "$root/packaging/qt-platform-theme/src/GrassfieldThemePlugin.cpp"
check "the portal backend's unit still clears QT_QPA_PLATFORMTHEME (the backend must not ask itself)" \
  grep -qx 'UnsetEnvironment=GTK_USE_PORTAL QT_QPA_PLATFORMTHEME' "$root/packaging/systemd/grassfield-portal.service"
exit "$fail"
