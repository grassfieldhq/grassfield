#!/usr/bin/env bash
# The compositor extension after a Hyprland update (ADR-0009 options 1 and 3, "Amendment 2026-10-23"; audit GF-033), without
# a compositor and without building anything:
#   - the ABI string of a Hyprland version.h, computed the same way by compositor/abi-stamp.cmake (the build's own stamp),
#     packaging/arch/grassfield-compositor-rebuild (bash) and config/hypr/grassfield/compositor.lua (Lua), as Hyprland's
#     PluginAPI.hpp computes it (the formula is checked in the installed header when present);
#   - the session's choice (offline part of the C2 mismatch test, plan 1.8): the packaged build, the user's build only as
#     --vetted vouches for it, on a mismatch NO build (degraded mode); a build of another Grassfield version (its stamp's
#     `source` line) is a mismatch too, even for the right Hyprland; a config reload keeps the build of the first parse
#     (runtime note), even when a package update replaced its files; Hyprland updated under the session;
#   - the vetting (one checker, used by the loader through --vetted and by the script itself): every directory from the
#     cache root down, the plugin and its stamp are no symlinks and not writable by group or others (a foreign owner
#     cannot be made without root: private_entry compares stat's owner with id -u, the same code path);
#   - the user rebuild: refuses root, refuses symlinks, installs into the user's cache with 0700 directories and the
#     build's own stamp last, --status and --session answers for the shell (which turns them into translated notices),
#     the load into the running Hyprland only on an exact "ok", a missing toolchain, a stale build.
# Layer logic (scripts/dev/test.sh). Writes only under a temporary directory; hyprctl is replaced.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
script=$root/packaging/arch/grassfield-compositor-rebuild
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/compositor-rebuild.XXXXXX")
trap 'chmod -R u+rwX "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
pass() { echo "PASS: compositor_rebuild: $1"; }
bad() { echo "FAIL: compositor_rebuild: $1"; fail=1; }
expect() { if [[ $2 == "$3" ]]; then pass "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

command -v lua >/dev/null || { echo "SKIP: compositor_rebuild: lua is not installed"; exit 0; }
luamod() { # <lua chunk using `c` (the module)>
  lua -e "package.path = '$root/config/hypr/?.lua;' .. package.path; local c = require('grassfield.compositor'); $1"
}

# ---- the ABI string ----
cat >"$tmp/version.h" <<'EOF'
#pragma once
#define GIT_COMMIT_HASH    "0123456789abcdef0123456789abcdef01234567"
#define GIT_BRANCH         "v0.57.0"
#define GIT_TAG            "v0.57.0"
#define AQUAMARINE_VERSION "0.16.2"
// clang-format off
#define AQUAMARINE_VERSION_MAJOR 0
#define AQUAMARINE_VERSION_MINOR 16
// clang-format on
#define HYPRLANG_VERSION     "0.7.0"
#define HYPRUTILS_VERSION    "0.15.10"
#define HYPRCURSOR_VERSION   "0.1.13"
#define HYPRGRAPHICS_VERSION "1"
EOF
want=0123456789abcdef0123456789abcdef01234567_aq_0.16_hu_0.15_hg_1_hc_0.1_hlg_0.7
other=fedcba9876543210fedcba9876543210fedcba98_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6
expect "bash: the ABI of a version.h" "$("$script" --print-abi "$tmp/version.h")" "$want"
expect "lua: the same ABI" "$(luamod "local f = io.open('$tmp/version.h'); print(c.abi(f:read('a')))")" "$want"
grep -v HYPRLANG_VERSION "$tmp/version.h" >"$tmp/partial.h"
"$script" --print-abi "$tmp/partial.h" >/dev/null 2>&1 && bad "bash: a missing field is an error" || pass "bash: a missing field is an error"
expect "lua: a missing field gives nil" "$(luamod "local f = io.open('$tmp/partial.h'); print(c.abi(f:read('a')))")" "nil"
if command -v cmake >/dev/null; then
  cmake -DVERSION_H="$tmp/version.h" -DOUT="$tmp/cmake.abi" -P "$root/compositor/abi-stamp.cmake" >/dev/null 2>&1
  expect "cmake: the build's own stamp is the same ABI" "$(cat "$tmp/cmake.abi" 2>/dev/null)" "$want"
  cmake -DVERSION_H="$tmp/partial.h" -DOUT="$tmp/partial.abi" -P "$root/compositor/abi-stamp.cmake" >/dev/null 2>&1 \
    && bad "cmake: a missing field fails the build" || pass "cmake: a missing field fails the build"
  [[ ! -e $tmp/partial.abi ]] && pass "cmake: no stamp for a partial version.h" || bad "cmake: no stamp for a partial version.h"
fi
real=/usr/include/hyprland/src/version.h
if [[ -r $real ]]; then
  expect "bash and lua agree on the installed Hyprland" "$("$script" --print-abi "$real")" "$(luamod "local f = io.open('$real'); print(c.abi(f:read('a')))")"
  if command -v cmake >/dev/null; then
    cmake -DVERSION_H="$real" -DOUT="$tmp/real.abi" -P "$root/compositor/abi-stamp.cmake" >/dev/null 2>&1
    expect "bash and cmake agree on the installed Hyprland" "$(cat "$tmp/real.abi" 2>/dev/null)" "$("$script" --print-abi "$real")"
  fi
fi
api=/usr/include/hyprland/src/plugins/PluginAPI.hpp
if [[ -r $api ]]; then
  formula=$(tr -d ' \n' <"$api")
  [[ $formula == *'GIT_COMMIT_HASH}+"_aq_"+stripPatch(AQUAMARINE_VERSION)+"_hu_"+stripPatch(HYPRUTILS_VERSION)+"_hg_"+stripPatch(HYPRGRAPHICS_VERSION)+"_hc_"+stripPatch(HYPRCURSOR_VERSION)+"_hlg_"+stripPatch(HYPRLANG_VERSION)'* ]] \
    && pass "Hyprland's PluginAPI.hpp still computes the hash this way" \
    || bad "Hyprland's PluginAPI.hpp computes its client hash differently: update abi_of, abi-stamp.cmake and compositor.lua"
fi

# ---- the session's choice (compositor.lua), every file and the --vetted answer simulated ----
cat >"$tmp/choose.lua" <<'EOF'
-- arg: <version.h> <packaged stamp | - (no packaged build) | EMPTY> <ABIs --vetted vouches for, comma-separated | ->
--      <instance signature | -> <runtime note content | -> [packaged file missing: gone]
-- env: GF_PKG_SOURCE the packaged stamp's source line (default 1.0.0-1; "none": no second line), GF_SRC_VERSION the
-- installed sources' VERSION (default 1.0.0-1; "none": no file), GF_SHOW_CALLS=1 prints the --vetted calls too,
-- GF_VETTED_TIMEOUT=1 a check that vouches for nothing was cut off (not a refusal).
package.path = os.getenv("GF_ROOT") .. "/config/hypr/?.lua;" .. package.path
local c = require("grassfield.compositor")
local f = io.open(arg[1]); local vh = f:read("a"); f:close()
local pkg_source = os.getenv("GF_PKG_SOURCE") or "1.0.0-1"
local src_version = os.getenv("GF_SRC_VERSION") or "1.0.0-1"
local vars = { HOME = "/home/u", XDG_RUNTIME_DIR = "/run/user/1000" }
if arg[4] ~= "-" then vars.HYPRLAND_INSTANCE_SIGNATURE = arg[4] end
local getenv = function(n) return vars[n] end
local vouched = {}
for a in (arg[3] ~= "-" and arg[3] or ""):gmatch("[^,]+") do vouched[a] = true end
local note = c.note_path(getenv)
local calls = {}
local env = {
  read = function(p)
    if p == c.version_h then return vh end
    if p == "/usr/lib/grassfield/grassfield-compositor.abi" and arg[2] ~= "-" then
      local first = arg[2] == "EMPTY" and "" or arg[2]
      return pkg_source == "none" and (first .. "\n") or (first .. "\nsource " .. pkg_source .. "\n")
    end
    if p == c.source_version and src_version ~= "none" then return src_version .. "\n" end
    return nil
  end,
  line = function(p)
    if p == note and arg[5] ~= "-" then return arg[5] end
    if p == "/usr/lib/grassfield/grassfield-compositor.abi" and arg[2] ~= "-" then return arg[2] == "EMPTY" and "" or arg[2] end
    return nil
  end,
  exists = function(p) return p == c.packaged and arg[2] ~= "-" and arg[6] ~= "gone" end,
  getenv = getenv,
  vetted = function(abi, loaded)
    calls[#calls + 1] = (abi or "installed") .. (loaded and "+loaded" or "")
    local a = abi or c.abi(vh)
    if vouched[a] then return c.user_build(a, getenv) end
    if os.getenv("GF_VETTED_TIMEOUT") == "1" then return nil, "timeout" end
    return nil
  end,
}
local path, why = c.choose(env)
print(why .. " " .. tostring(path) .. (os.getenv("GF_SHOW_CALLS") == "1" and (" [" .. table.concat(calls, ",") .. "]") or ""))
EOF
choose() { GF_ROOT=$root lua "$tmp/choose.lua" "$tmp/version.h" "$@"; }
sig=0123456789abcdef0123456789abcdef01234567_1792717195_16028387
old_sig=fedcba9876543210fedcba9876543210fedcba98_1792717195_1
packaged=/usr/lib/grassfield/grassfield-compositor.so
userpath=/home/u/.cache/grassfield/compositor/$want/grassfield-compositor.so
olduser=/home/u/.cache/grassfield/compositor/$other/grassfield-compositor.so
expect "choice: the packaged build matches" "$(choose "$want" "$want" "$sig" -)" "packaged $packaged"
expect "choice: the user's build, vouched for by --vetted" "$(choose "$other" "$want" "$sig" -)" "user $userpath"
expect "choice: mismatch -> nothing is loaded (degraded mode)" "$(choose "$other" - "$sig" -)" "no-match nil"
expect "choice: a user build --vetted does not vouch for is not loaded" "$(choose "$other" "$other" "$sig" -)" "no-match nil"
expect "choice: no extension installed" "$(choose - - "$sig" -)" "none nil"
expect "choice: a packaged build with an empty stamp is not loaded blind" "$(choose EMPTY - "$sig" -)" "no-match nil"
expect "choice: no signature: the installed headers decide" "$(choose "$other" "$want" - -)" "user $userpath"
# The packaged build of another Grassfield version than the installed sources (review of c3cb01b): never loaded.
expect "choice: a packaged build of another Grassfield version is not loaded" \
  "$(GF_PKG_SOURCE=0.9.0-1 choose "$want" - "$sig" -)" "no-match nil"
expect "choice: a packaged stamp without its source line is not loaded" "$(GF_PKG_SOURCE=none choose "$want" - "$sig" -)" "no-match nil"
expect "choice: no installed sources version: the packaged build is not loaded" "$(GF_SRC_VERSION=none choose "$want" - "$sig" -)" "no-match nil"
expect "choice: a packaged build of another version gives way to the user's build --vetted vouches for" \
  "$(GF_PKG_SOURCE=0.9.0-1 choose "$want" "$want" "$sig" -)" "user $userpath"
# A config reload: the build of the first parse stays, as the runtime note names it.
expect "reload: the packaged build stays" "$(choose "$want" - "$sig" "$packaged")" "kept $packaged"
expect "reload: the packaged build stays after a package update replaced it in the same transaction" \
  "$(choose "$want" - "$old_sig" "$packaged")" "kept $packaged"
expect "reload: the packaged file is gone: not kept" "$(choose "$want" - "$old_sig" "$packaged" gone)" "updated nil"
expect "reload: the user's build of the running commit stays while --vetted vouches for it" \
  "$(choose "$want" "$other" "$old_sig" "$olduser")" "kept $olduser"
expect "reload: the kept user build is vetted as the loaded one (--loaded: its source version may have moved on)" \
  "$(GF_SHOW_CALLS=1 choose "$want" "$other" "$old_sig" "$olduser")" "kept $olduser [$other+loaded]"
expect "reload: a user build --vetted no longer vouches for is dropped (nothing until the next login)" \
  "$(choose "$want" - "$old_sig" "$olduser")" "updated nil"
# CIO-04: a check that could not finish must not unload the build the session runs; a first parse still loads nothing.
expect "reload: a loaded user build stays when its check was cut off (not refused)" \
  "$(GF_VETTED_TIMEOUT=1 choose "$want" - "$old_sig" "$olduser")" "kept $olduser"
expect "choice: a check that was cut off loads nothing at a first parse" "$(GF_VETTED_TIMEOUT=1 choose "$other" - "$sig" -)" "no-match nil"
expect "reload: a user build of another commit is not kept" "$(choose "$other" "$other,$want" "$sig" "$olduser")" "user $userpath"
expect "reload: a note naming any other path is ignored" "$(choose "$want" - "$sig" /tmp/evil/grassfield-compositor.so)" "packaged $packaged"
expect "reload: a note with a path that climbs out is ignored" \
  "$(choose "$other" "x" "$sig" "/home/u/.cache/grassfield/compositor/x/../../../../evil/grassfield-compositor.so")" "no-match nil"
expect "updated under the session, no note: nothing until the next login" "$(choose "$want" "$want" "$old_sig" -)" "updated nil"
expect "lua: the running commit" "$(luamod "print(c.running_commit('efb50993780079460b0cbed1363e2166a2de1d9f_1792717195_16028387'))")" "efb50993780079460b0cbed1363e2166a2de1d9f"
expect "lua: no commit in a bad signature" "$(luamod "print(c.running_commit('nothing'), c.running_commit(nil))")" "nil	nil"
expect "lua: XDG_CACHE_HOME wins" "$(luamod "print(c.user_build('A', function(n) return ({XDG_CACHE_HOME = '/x', HOME = '/h'})[n] end))")" "/x/grassfield/compositor/A/grassfield-compositor.so"
expect "lua: the ABI of a user build path, nothing else" \
  "$(luamod "local g = function(n) return ({HOME = '/h'})[n] end; print(c.user_build_abi('/h/.cache/grassfield/compositor/abc_1/grassfield-compositor.so', g), c.user_build_abi('/h/.cache/grassfield/compositor/a/b/grassfield-compositor.so', g), c.user_build_abi('/h/.cache/grassfield/compositor/.x/grassfield-compositor.so', g), c.user_build_abi('/other/grassfield-compositor.so', g))")" \
  "abc_1	nil	nil	nil"
expect "lua: the runtime note path, the signature reduced to letters, digits and _" \
  "$(luamod "print(c.note_path(function(n) return ({XDG_RUNTIME_DIR = '/run/user/1', HYPRLAND_INSTANCE_SIGNATURE = 'ab_1/../x'})[n] end))")" \
  "/run/user/1/grassfield-compositor-ab_1x"
mkdir -p "$tmp/run"
luamod "c.remember('$packaged', function(n) return ({XDG_RUNTIME_DIR = '$tmp/run', HYPRLAND_INSTANCE_SIGNATURE = '$sig'})[n] end)"
expect "lua: remember writes the runtime note of this instance" "$(cat "$tmp/run/grassfield-compositor-$sig" 2>/dev/null)" "$packaged"
expect "lua: --vetted is never asked with an ABI the shell would expand" "$(luamod "c.rebuild = '/bin/echo'; print(c.vetted('a;b'), c.vetted('\$(x)'))")" "nil	nil"
# The check runs on Hyprland's main thread during the parse (review of b0d347e): bounded, and only an answer of a check
# that succeeded counts.
printf '#!/bin/sh\nsleep 30\necho /never\n' >"$tmp/slow-vetted"
printf '#!/bin/sh\necho /some/path\nexit 1\n' >"$tmp/failing-vetted"
printf '#!/bin/sh\necho "/ok/$*"\n' >"$tmp/ok-vetted"
chmod +x "$tmp/slow-vetted" "$tmp/failing-vetted" "$tmp/ok-vetted"
started=$SECONDS
expect "lua: a --vetted check that hangs is cut off and vouches for nothing" \
  "$(luamod "c.rebuild = '$tmp/slow-vetted'; c.vetted_seconds = 1; print(c.vetted())")" "nil	timeout"
((SECONDS - started <= 4)) && pass "lua: the hanging check was cut off within its bound" || bad "lua: the hanging check took $((SECONDS - started)) s"
expect "lua: a --vetted check that fails vouches for nothing" "$(luamod "c.rebuild = '$tmp/failing-vetted'; print(c.vetted())")" "nil"
expect "lua: a --vetted check that succeeds is read" "$(luamod "c.rebuild = '$tmp/ok-vetted'; print(c.vetted(), c.vetted('A_1'))")" "/ok/--vetted	/ok/--vetted A_1"
expect "lua: the loaded build is vetted with --loaded, only with an ABI" \
  "$(luamod "c.rebuild = '$tmp/ok-vetted'; print(c.vetted('A_1', true), c.vetted(nil, true))")" "/ok/--vetted A_1 --loaded	/ok/--vetted"
expect "lua: the stamp's source line and the installed version" \
  "$(luamod "local t = {['/a/p.abi'] = 'X\nsource 1.0.0rc1-1\n', [c.source_version] = '1.0.0rc1-1\n'}; local r = function(p) return t[p] end; print(c.stamp_source('/a/p.so', r), c.installed_source(r), c.stamp_source('/b/p.so', r))")" \
  "1.0.0rc1-1	1.0.0rc1-1	nil"
expect "lua: no timeout tool, no check" "$(luamod "c.rebuild = '$tmp/ok-vetted'; c.timeout = '$tmp/none'; print(c.vetted())")" "nil"
# Verify mode (just check runs Hyprland --verify-config with the session config): the loader writes no runtime note.
expect "lua: verify mode is read from the command line" \
  "$(luamod "print(c.verifying(function() return 'Hyprland\\0--verify-config\\0--config\\0x.lua\\0' end), c.verifying(function() return 'Hyprland\\0--config\\0x.lua\\0' end), c.verifying(function() return nil end))")" \
  "true	false	false"
expect "lua: a plain lua process is not in verify mode" "$(luamod "print(c.verifying())")" "false"
if command -v Hyprland >/dev/null; then
  mkdir -p "$tmp/rt"
  printf 'package.path = "%s/config/hypr/?.lua;" .. package.path\nprint("gf-probe verifying=" .. tostring(require("grassfield.compositor").verifying()))\n' "$root" >"$tmp/probe.lua"
  out=$(env -u HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR="$tmp/rt" Hyprland --verify-config --config "$tmp/probe.lua" 2>&1)
  [[ $out == *"gf-probe verifying=true"* ]] && pass "Hyprland --verify-config: the loader knows it is verifying" \
    || bad "Hyprland --verify-config: the loader knows it is verifying ($(grep -m1 gf-probe <<<"$out"))"
fi

# ---- session.lua's runtime note (review of dac8e71): a start writes it, verify mode writes nothing ----
# session.lua itself under plain Lua: hl and the other session modules are stubs, the choice is fixed to a plugin file
# that exists; remember() and verifying() are the real ones. Verify mode is the real detection: the interpreter runs
# with --verify-config on its command line, as Hyprland --verify-config does (/proc/self/cmdline).
cat >"$tmp/session-harness.lua" <<'EOF'
local root = os.getenv("GF_ROOT")
package.path = root .. "/config/hypr/?.lua;" .. package.path
for _, name in ipairs({ "grassfield.core", "grassfield.autostart", "grassfield.system" }) do
  package.preload[name] = function() return {} end
end
package.preload["grassfield.omarchy"] = function()
  return { ok = true, monitors = true, problems = {}, guard_path = function() end }
end
-- session.lua starts its parse with Grassfield's modules unloaded (package.loaded): the real module, its choice fixed,
-- comes from package.preload.
local compositor = dofile(root .. "/config/hypr/grassfield/compositor.lua")
compositor.choose = function() return os.getenv("GF_TEST_PLUGIN"), "packaged" end
package.preload["grassfield.compositor"] = function() return compositor end
local loaded = {}
hl = {
  plugin = { load = function(p) loaded[#loaded + 1] = p end },
  env = function() end, on = function() end, config = function() end, monitor = function() end, exec_cmd = function() end,
}
dofile(root .. "/config/hypr/session.lua")
print("loaded=" .. tostring(loaded[1]))
EOF
printf 'plugin\n' >"$tmp/session-plugin.so"
mkdir -p "$tmp/rt-start" "$tmp/rt-verify"
out=$(GF_ROOT=$root GRASSFIELD_CONFIG_DIR=$root/config/hypr GF_TEST_PLUGIN=$tmp/session-plugin.so XDG_RUNTIME_DIR=$tmp/rt-start \
  HYPRLAND_INSTANCE_SIGNATURE=$sig lua "$tmp/session-harness.lua" 2>&1)
expect "session.lua: a start loads the chosen build" "$(grep '^loaded=' <<<"$out")" "loaded=$tmp/session-plugin.so"
expect "session.lua: a start writes the runtime note of its instance" "$(cat "$tmp/rt-start/grassfield-compositor-$sig" 2>/dev/null)" "$tmp/session-plugin.so"
out=$(GF_ROOT=$root GRASSFIELD_CONFIG_DIR=$root/config/hypr GF_TEST_PLUGIN=$tmp/session-plugin.so XDG_RUNTIME_DIR=$tmp/rt-verify \
  HYPRLAND_INSTANCE_SIGNATURE=$sig lua "$tmp/session-harness.lua" --verify-config 2>&1)
expect "session.lua: verify mode still parses the loader" "$(grep '^loaded=' <<<"$out")" "loaded=$tmp/session-plugin.so"
expect "session.lua: verify mode writes no runtime note" "$(ls -A "$tmp/rt-verify")" ""

# ---- the user rebuild and the vetting, on temporary directories ----
lib=$tmp/lib src=$tmp/src tools=$tmp/tools cache=$tmp/cache
mkdir -p "$lib" "$src" "$tools"
printf 'cmake_minimum_required(VERSION 3.27)\n' >"$src/CMakeLists.txt"
echo "0.5.0-1" >"$src/VERSION"
printf 'plugin\n' >"$lib/grassfield-compositor.so"
echo "$other" >"$lib/grassfield-compositor.abi"
for t in cmake g++ make pkg-config hyprwayland-scanner; do printf '#!/bin/sh\nexit 0\n' >"$tools/$t"; chmod +x "$tools/$t"; done
printf '#!/bin/sh\necho "$@" >>"%s/hyprctl.log"\necho ok\n' "$tmp" >"$tmp/hyprctl-ok"
printf '#!/bin/sh\necho "$@" >>"%s/hyprctl.log"\nprintf "ok\\nerror: plugin refused\\n"\n' "$tmp" >"$tmp/hyprctl-okish"
printf '#!/bin/sh\necho "error: plugin refused"\nexit 1\n' >"$tmp/hyprctl-no"
chmod +x "$tmp/hyprctl-ok" "$tmp/hyprctl-okish" "$tmp/hyprctl-no"
testenv=(GF_VERSION_H="$tmp/version.h" GF_LIB_DIR="$lib" GF_SRC_DIR="$src" GF_TOOLS_PATH="$tools" XDG_CACHE_HOME="$cache")
run() { # [env ...] -- args: the script with the test environment; stdout in $tmp/out, stderr in $tmp/err
  env "${testenv[@]}" GF_TEST_FAKE_BUILD=1 HYPRLAND_INSTANCE_SIGNATURE= "$@" >"$tmp/out" 2>"$tmp/err"
}
dest=$cache/grassfield/compositor/$want
so=$dest/grassfield-compositor.so

run GF_TEST_UID=0 "$script"; rc=$?
expect "root: refused" "$rc $(grep -c 'refusing to run as root' "$tmp/err")" "1 1"
[[ ! -e $cache ]] && pass "root: nothing written" || bad "root: nothing written"
run GF_TEST_UID=0 "$script" --session; rc=$?
expect "root: --session refused too" "$rc" 1
expect "root: --print-abi still answers (it only reads)" "$(GF_TEST_UID=0 "$script" --print-abi "$tmp/version.h")" "$want"
run GF_TEST_UID=0 "$script" --status; rc=$?
expect "root: --status still answers (it only reads)" "$rc $(head -n 1 "$tmp/out")" "0 state=mismatch"
if command -v fakeroot >/dev/null; then
  # makepkg's package() runs under fakeroot (uid 0): the PKGBUILD's stamp check still reads the installed ABI; a build
  # never runs there, and the test override cannot lift the refusal.
  expect "fakeroot: --print-abi (the PKGBUILD's stamp check)" "$(fakeroot -- "$script" --print-abi "$tmp/version.h")" "$want"
  run fakeroot -- env GF_TEST_UID=1000 "$script"; rc=$?
  expect "fakeroot: a build is refused, GF_TEST_UID cannot lift it" "$rc $(grep -c 'refusing to run as root' "$tmp/err")" "1 1"
fi

run "$script" --check; rc=$?
expect "--check: no build matches -> exit 1" "$rc" 1
run "$script" --status; rc=$?
expect "--status: a mismatch names the version and the ABI" "$rc $(tr '\n' ' ' <"$tmp/out")" "0 state=mismatch version=v0.57.0 abi=$want "
run "$script" --vetted; rc=$?
expect "--vetted: no build -> exit 1, nothing on stdout" "$rc [$(cat "$tmp/out")]" "1 []"

run "$script"; rc=$?
expect "build: exit 0" "$rc" 0
[[ -f $so && ! -L $so ]] && pass "build: installed in the user's cache" || bad "build: installed in the user's cache ($(cat "$tmp/err"))"
expect "build: the build's own stamp, then the source" "$(head -n 1 "$dest/grassfield-compositor.abi" 2>/dev/null) / $(sed -n 2p "$dest/grassfield-compositor.abi" 2>/dev/null)" "$want / source 0.5.0-1"
expect "build: 0700 directories, 0700 plugin, 0600 stamp" \
  "$(stat -c %a "$cache/grassfield" "$cache/grassfield/compositor" "$dest" "$so" "$dest/grassfield-compositor.abi" | tr '\n' ' ')" "700 700 700 700 600 "
expect "build: no temporary file left" "$(find "$cache/grassfield/compositor" -name '.*' -not -name .lock | wc -l)" 0
grep -q "Log out and back in" "$tmp/err" && pass "build: says how to use it" || bad "build: says how to use it"
run "$script" --vetted; rc=$?
expect "--vetted: vouches for the user's build" "$rc $(cat "$tmp/out")" "0 $so"
run "$script" --vetted "$want"; rc=$?
expect "--vetted ABI: the same build" "$rc $(cat "$tmp/out")" "0 $so"
run "$script" --vetted "$other"; rc=$?
expect "--vetted another ABI: no build there" "$rc [$(cat "$tmp/out")]" "1 []"
run "$script" --vetted ../x; rc=$?
expect "--vetted: not an ABI" "$rc $(grep -c 'not an ABI' "$tmp/err")" "1 1"
run "$script" --status; rc=$?
expect "--status: the user's build matches" "$(head -n 1 "$tmp/out") $(grep '^path=' "$tmp/out")" "state=match path=$so"
run "$script" --check; rc=$?
expect "--check: the user's build matches -> exit 0" "$rc $(tail -n 1 "$tmp/out")" "0 match: $so"
run "$script"; rc=$?
expect "build again: nothing to build" "$rc $(grep -c 'nothing to build' "$tmp/err")" "0 1"
# The loader asks the script (Lua cannot look at owners, modes or symlinks): the real module, the real script.
expect "lua: M.vetted asks the script and gets the user's build" \
  "$(env "${testenv[@]}" lua -e "package.path = '$root/config/hypr/?.lua;' .. package.path; local c = require('grassfield.compositor'); c.rebuild = '$script'; print(c.vetted(), c.vetted('$want'), c.vetted('$other'))")" \
  "$so	$so	nil"

# The vetting: each entry from the cache root down, the plugin and the stamp. Each case is undone after it.
vetted_refuses() { # <name> <what the reason says>
  run "$script" --vetted; local rc=$?
  expect "vetting: $1 -> refused" "$rc [$(cat "$tmp/out")] $(grep -c "$2" "$tmp/err")" "1 [] 1"
  run "$script" --status
  expect "vetting: $1 -> --status says mismatch" "$(head -n 1 "$tmp/out")" "state=mismatch"
}
for d in "$cache" "$cache/grassfield" "$cache/grassfield/compositor" "$dest"; do
  mode=$(stat -c %a "$d")
  chmod g+w "$d"
  vetted_refuses "group-writable ${d#"$tmp"/}" "writable by group or others"
  chmod "$mode" "$d"
  chmod o+w "$d"
  vetted_refuses "world-writable ${d#"$tmp"/}" "writable by group or others"
  chmod "$mode" "$d"
done
chmod 0666 "$so"
vetted_refuses "a plugin others can write" "writable by group or others"
chmod 0700 "$so"
chmod 0622 "$dest/grassfield-compositor.abi"
vetted_refuses "a stamp others can write" "writable by group or others"
chmod 0600 "$dest/grassfield-compositor.abi"
mv "$so" "$tmp/real.so" && ln -s "$tmp/real.so" "$so"
vetted_refuses "a symlinked plugin" "is a symlink"
rm -f "$so" && mv "$tmp/real.so" "$so"
mv "$dest/grassfield-compositor.abi" "$tmp/real.abi" && ln -s "$tmp/real.abi" "$dest/grassfield-compositor.abi"
vetted_refuses "a symlinked stamp" "is a symlink"
rm -f "$dest/grassfield-compositor.abi" && mv "$tmp/real.abi" "$dest/grassfield-compositor.abi"
mv "$cache/grassfield" "$tmp/moved" && ln -s "$tmp/moved" "$cache/grassfield"
vetted_refuses "a symlinked directory on the way" "is a symlink"
rm -f "$cache/grassfield" && mv "$tmp/moved" "$cache/grassfield"
mv "$cache" "$tmp/cache-real" && ln -s "$tmp/cache-real" "$cache"
vetted_refuses "a symlinked cache root" "not a canonical path"
rm -f "$cache" && mv "$tmp/cache-real" "$cache"
# The cache root itself (review of b0d347e): only an absolute, canonical path; a trailing slash after a symlink used to
# pass the symlink test (test -L follows "link/").
vetted_refuses_as() { # <name> <what the reason says> <XDG_CACHE_HOME>
  run XDG_CACHE_HOME="$3" "$script" --vetted; local rc=$?
  expect "cache root: $1 -> refused" "$rc [$(cat "$tmp/out")] $(grep -c "$2" "$tmp/err")" "1 [] 1"
}
ln -s "$cache" "$tmp/cache-link"
vetted_refuses_as "a symlink given with a trailing slash" "not a canonical path" "$tmp/cache-link/"
vetted_refuses_as "a trailing slash" "not a canonical path" "$cache/"
vetted_refuses_as "a path through .." "not a canonical path" "$tmp/lib/../cache"
vetted_refuses_as "a relative path" "not an absolute path" "cache"
rm -f "$tmp/cache-link"
echo "$other" >"$tmp/stamp" && cp "$dest/grassfield-compositor.abi" "$tmp/good.abi" && cat "$tmp/stamp" >"$dest/grassfield-compositor.abi"
vetted_refuses "a stamp for another ABI" "its stamp is not"
cat "$tmp/good.abi" >"$dest/grassfield-compositor.abi"
run "$script" --vetted; rc=$?
expect "vetting: every case undone -> vouched for again" "$rc $(cat "$tmp/out")" "0 $so"

# A build in the cache made from older sources, for the right Hyprland (a Grassfield upgrade without a Hyprland update;
# review of c3cb01b, MAJOR 1): never used; the user's rebuild (or the shell's --session) builds it again.
echo "0.6.0-1" >"$src/VERSION"
vetted_refuses "a build from another Grassfield version" "built from Grassfield 0.5.0-1, the installed version is 0.6.0-1"
run "$script" --status
expect "stale build: --status gives the reason" "$(grep -c '^reason=stale-build$' "$tmp/out")" 1
run "$script" --vetted "$want" --loaded; rc=$?
expect "stale build: --loaded (the build a running session keeps on a reload) still vouches for it" "$rc $(cat "$tmp/out")" "0 $so"
run "$script" --vetted "$want" --bogus; rc=$?
expect "--vetted: an unknown option is refused" "$rc [$(cat "$tmp/out")]" "1 []"
run "$script" --check; rc=$?
expect "stale build: --check exit 1" "$rc" 1
run "$script"; rc=$?
expect "stale build: built again" "$rc $(grep -c 'nothing to build' "$tmp/err")" "0 0"
expect "stale build: the new stamp names the installed version" "$(sed -n 2p "$dest/grassfield-compositor.abi")" "source 0.6.0-1"
run "$script" --vetted; rc=$?
expect "stale build: rebuilt -> vouched for" "$rc $(cat "$tmp/out")" "0 $so"
mv "$src/VERSION" "$tmp/VERSION.saved"
vetted_refuses "installed sources without a VERSION" "have no VERSION"
mv "$tmp/VERSION.saved" "$src/VERSION"

# Above the cache root: every ancestor root's or the user's, not writable by group or others unless sticky (/tmp). A
# foreign owner cannot be made without root; the mode cases go through the same check.
mkdir -p "$tmp/anc"
run XDG_CACHE_HOME="$tmp/anc/cache" "$script"; rc=$?
expect "ancestors: a build under a private parent" "$rc" 0
run XDG_CACHE_HOME="$tmp/anc/cache" "$script" --vetted; rc=$?
expect "ancestors: vouched for" "$rc $(cat "$tmp/out")" "0 $tmp/anc/cache/grassfield/compositor/$want/grassfield-compositor.so"
chmod 0777 "$tmp/anc"
run XDG_CACHE_HOME="$tmp/anc/cache" "$script" --vetted; rc=$?
expect "ancestors: a parent others can write -> refused" "$rc [$(cat "$tmp/out")] $(grep -c 'above the cache directory, is writable' "$tmp/err")" "1 [] 1"
chmod 0775 "$tmp/anc"
run XDG_CACHE_HOME="$tmp/anc/cache" "$script" --vetted; rc=$?
expect "ancestors: a parent the group can write -> refused" "$rc $(grep -c 'above the cache directory, is writable' "$tmp/err")" "1 1"
chmod 1777 "$tmp/anc"
run XDG_CACHE_HOME="$tmp/anc/cache" "$script" --vetted; rc=$?
expect "ancestors: a sticky parent (like /tmp) is fine" "$rc $(cat "$tmp/out")" "0 $tmp/anc/cache/grassfield/compositor/$want/grassfield-compositor.so"
chmod 0777 "$tmp/anc"
rm -rf "$tmp/anc/cache"
run XDG_CACHE_HOME="$tmp/anc/cache" "$script"; rc=$?
expect "ancestors: no build under a parent others can write" "$rc $([[ -e $tmp/anc/cache ]] && echo created || echo untouched)" "1 untouched"
chmod 0755 "$tmp/anc"

# The build refuses a cache it could not vouch for afterwards, and its own odd results.
rm -rf "$cache" && mkdir -p "$cache" && chmod 0777 "$cache"
run "$script"; rc=$?
expect "build: a cache root others can write -> refused" "$rc $(grep -c 'writable by group or others' "$tmp/err")" "1 1"
[[ -z $(ls -A "$cache") ]] && pass "build: nothing written into it" || bad "build: nothing written into it"
rm -rf "$cache" && mkdir -p "$cache" "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$cache/grassfield"
run "$script"; rc=$?
expect "build: a symlinked cache directory -> refused" "$rc $(grep -c 'is a symlink' "$tmp/err")" "1 1"
[[ -z $(ls -A "$tmp/elsewhere") ]] && pass "build: nothing written through it" || bad "build: nothing written through it"
rm -rf "$cache" && mkdir -p "$cache/grassfield/compositor" && chmod -R 0700 "$cache/grassfield"
ln -s "$tmp/lockfile" "$cache/grassfield/compositor/.lock"
run "$script"; rc=$?
expect "build: a symlinked lock -> refused" "$rc $(grep -c 'lock is a symlink' "$tmp/err") $([[ -e $tmp/lockfile ]] && echo written || echo untouched)" "1 1 untouched"
rm -rf "$cache"
run GF_TEST_FAKE_BUILD=symlink "$script"; rc=$?
expect "build: its result is a symlink -> refused" "$rc $(grep -c 'not a regular file' "$tmp/err")" "1 1"
[[ ! -e $so ]] && pass "build: a symlink result installs nothing" || bad "build: a symlink result installs nothing"
rm -rf "$cache"
run GF_TEST_FAKE_BUILD=stale "$script"; rc=$?
expect "build: its own stamp is another ABI -> refused" "$rc $(grep -c "built for 'stale'" "$tmp/err")" "1 1"
[[ ! -e $so ]] && pass "build: a stale result installs nothing" || bad "build: a stale result installs nothing"

# The sources replaced during the build (a system upgrade while the opt-in background build runs; re-review of
# b60bc3a..85aaab9, the reviewer's fake-cmake repro): the real build path with a fake cmake that "compiles" from the
# sources' VERSION, writes the build's stamp, and installs newer sources meanwhile. The result is refused, never stamped
# with the new version; an empty VERSION is refused before anything is built.
cp "$tools/cmake" "$tmp/cmake-stub"
cat >"$tools/cmake" <<EOF
#!/bin/sh
# fake cmake (shell builtins only: the rebuild runs it with PATH=<tools> alone)
if [ "\$1" = "--build" ]; then
  out=\${2%/work}
  read -r src <"\$out/.fake-src"
  read -r ver <"\$src/VERSION"
  printf 'plugin compiled from %s\n' "\$ver" >"\$out/grassfield-compositor.so"
  printf '%s\n' "$want" >"\$out/grassfield-compositor.abi"
  printf '0.9.0-1\n' >"\$src/VERSION"
  exit 0
fi
src="" out=""
while [ \$# -gt 0 ]; do
  case \$1 in
    -S) src=\$2; shift ;;
    -DGRASSFIELD_OUTPUT_DIR=*) out=\${1#*=} ;;
  esac
  shift
done
printf '%s\n' "\$src" >"\$out/.fake-src"
printf 'configured\n' >>"$tmp/fake-cmake.log"
EOF
chmod +x "$tools/cmake"
echo "0.8.0-1" >"$src/VERSION"
rm -rf "$cache" "$tmp/fake-cmake.log"
run GF_TEST_FAKE_BUILD= "$script"; rc=$?
expect "sources replaced during the build -> the result is refused" "$rc $(grep -c 'the installed sources changed during the build (from 0.8.0-1 to 0.9.0-1)' "$tmp/err")" "1 1"
[[ ! -e $so && ! -e $dest/grassfield-compositor.abi ]] && pass "sources replaced during the build: nothing installed, no stamp" \
  || bad "sources replaced during the build: nothing installed, no stamp ($(cat "$dest/grassfield-compositor.abi" 2>/dev/null))"
echo "0.8.0-1" >"$src/VERSION"
rm -rf "$cache"
mv "$src/VERSION" "$tmp/VERSION.away"
run GF_TEST_FAKE_BUILD= "$script"; rc=$?
expect "no VERSION: refused before building" "$rc $(grep -c 'the sources have no VERSION' "$tmp/err") $(grep -c configured "$tmp/fake-cmake.log" 2>/dev/null || echo 0)" "1 1 1"
mv "$tmp/VERSION.away" "$src/VERSION"
rm -rf "$cache"
# The same fake build with sources that stay put: installed, stamped with the version it was built from.
cat >"$tools/cmake" <<EOF
#!/bin/sh
if [ "\$1" = "--build" ]; then
  out=\${2%/work}
  printf 'plugin\n' >"\$out/grassfield-compositor.so"
  printf '%s\n' "$want" >"\$out/grassfield-compositor.abi"
  exit 0
fi
exit 0
EOF
chmod +x "$tools/cmake"
run GF_TEST_FAKE_BUILD= "$script"; rc=$?
expect "real build path, sources unchanged: installed and stamped with their version" "$rc $(sed -n 2p "$dest/grassfield-compositor.abi" 2>/dev/null)" "0 source 0.8.0-1"
cp "$tmp/cmake-stub" "$tools/cmake"
rm -rf "$cache"

# R5b (re-review of e186bd9): an install stopped between the plugin and its stamp (a kill, a crash). The previous build in
# the cache came from 0.6.0-1; the owner went back to 0.5.0-1 and rebuilds; the install stops after the plugin. The old
# stamp must not stay next to the new plugin: after a re-upgrade to 0.6.0-1, --vetted would vouch for a 0.5.0-1 plugin.
echo "0.6.0-1" >"$src/VERSION"
run "$script"; rc=$?
expect "R5b: a build from 0.6.0-1 in the cache" "$rc $(sed -n 2p "$dest/grassfield-compositor.abi")" "0 source 0.6.0-1"
echo "0.5.0-1" >"$src/VERSION"
run GF_TEST_INTERRUPT=after-plugin "$script"; rc=$?
expect "R5b: the install stops after the plugin" "$rc $([[ -f $so ]] && echo plugin) $([[ -e $dest/grassfield-compositor.abi ]] && echo stamp || echo no-stamp)" "1 plugin no-stamp"
echo "0.6.0-1" >"$src/VERSION"
run "$script" --vetted; rc=$?
expect "R5b: re-upgraded to 0.6.0-1, the half install is not vouched for" "$rc [$(cat "$tmp/out")] $(grep -c 'grassfield-compositor.abi is missing' "$tmp/err")" "1 [] 1"
run "$script" --status
expect "R5b: --status says mismatch (a rebuild fixes it)" "$(head -n 1 "$tmp/out")" "state=mismatch"
run "$script"; rc=$?
expect "R5b: the rebuild completes it" "$rc $(sed -n 2p "$dest/grassfield-compositor.abi")" "0 source 0.6.0-1"
echo "0.8.0-1" >"$src/VERSION"
rm -rf "$cache"

# --session (the shell, opt-in setting): build when needed, load into the running Hyprland on an exact "ok".
rm -rf "$cache" "$tmp/hyprctl.log"
run HYPRLAND_INSTANCE_SIGNATURE="$sig" GF_HYPRCTL="$tmp/hyprctl-ok" "$script" --session; rc=$?
expect "--session: built and loaded" "$rc $(tr '\n' ' ' <"$tmp/out")" "0 result=loaded path=$so "
expect "--session: hyprctl got the vetted build" "$(cat "$tmp/hyprctl.log" 2>/dev/null)" "plugin load $so"
rm -f "$tmp/hyprctl.log" "$cache/grassfield/compositor/build.log"
run HYPRLAND_INSTANCE_SIGNATURE="$sig" GF_HYPRCTL="$tmp/hyprctl-ok" "$script" --session; rc=$?
expect "--session: a build that matches already is loaded, not rebuilt" \
  "$rc $(head -n 1 "$tmp/out") $([[ -e $cache/grassfield/compositor/build.log ]] && echo rebuilt || echo kept)" "0 result=loaded kept"
echo "0.7.0-1" >"$src/VERSION"
rm -f "$tmp/hyprctl.log" "$cache/grassfield/compositor/build.log"
run HYPRLAND_INSTANCE_SIGNATURE="$sig" GF_HYPRCTL="$tmp/hyprctl-ok" "$script" --session; rc=$?
expect "--session: a build from older Grassfield sources is rebuilt and loaded" \
  "$rc $(head -n 1 "$tmp/out") $([[ -e $cache/grassfield/compositor/build.log ]] && echo rebuilt || echo kept) $(sed -n 2p "$dest/grassfield-compositor.abi")" \
  "0 result=loaded rebuilt source 0.7.0-1"
rm -rf "$cache" "$tmp/hyprctl.log"
run HYPRLAND_INSTANCE_SIGNATURE="$old_sig" GF_HYPRCTL="$tmp/hyprctl-ok" "$script" --session; rc=$?
expect "--session: another Hyprland runs: built, not loaded" "$rc $(head -n 1 "$tmp/out") $([[ -e $tmp/hyprctl.log ]] && echo called || echo untouched)" "0 result=built untouched"
rm -rf "$cache"
run HYPRLAND_INSTANCE_SIGNATURE="$sig" GF_HYPRCTL="$tmp/hyprctl-no" "$script" --session; rc=$?
expect "--session: Hyprland refuses the load: built" "$rc $(head -n 1 "$tmp/out")" "0 result=built"
rm -rf "$cache"
run HYPRLAND_INSTANCE_SIGNATURE="$sig" GF_HYPRCTL="$tmp/hyprctl-okish" "$script" --session; rc=$?
expect "--session: an answer that is not exactly ok is not a load" "$rc $(head -n 1 "$tmp/out")" "0 result=built"
rm -rf "$cache"
run GF_TEST_FAKE_BUILD=stale "$script" --session; rc=$?
expect "--session: the build fails" "$rc $(tr '\n' ' ' <"$tmp/out")" "1 result=failed reason=build-failed "
rm -rf "$cache"
rm -f "$tools/hyprwayland-scanner"
run "$script" --session; rc=$?
expect "--session: missing toolchain" "$rc $(tr '\n' ' ' <"$tmp/out")" "1 result=failed reason=cannot-build "
printf '#!/bin/sh\nexit 0\n' >"$tools/hyprwayland-scanner" && chmod +x "$tools/hyprwayland-scanner"

# The packaged build matches: --check and --status say so; a symlink in its place is not a packaged build; a packaged
# stamp of another Grassfield version, or without its source line, does not match.
printf '%s\nsource %s\n' "$want" "$(head -n 1 "$src/VERSION")" >"$lib/grassfield-compositor.abi"
rm -rf "$cache"
run "$script" --check; rc=$?
expect "packaged build matches: --check exit 0" "$rc $(tail -n 1 "$tmp/out")" "0 match: $lib/grassfield-compositor.so"
run "$script" --status
expect "packaged build matches: --status" "$(head -n 1 "$tmp/out") $(grep '^path=' "$tmp/out")" "state=match path=$lib/grassfield-compositor.so"
cp "$lib/grassfield-compositor.abi" "$tmp/pkg.abi"
printf '%s\nsource 0.1.0-1\n' "$want" >"$lib/grassfield-compositor.abi"
run "$script" --status
expect "a packaged build of another Grassfield version does not match" "$(head -n 1 "$tmp/out")" "state=mismatch"
echo "$want" >"$lib/grassfield-compositor.abi"
run "$script" --status
expect "a packaged stamp without its source line does not match" "$(head -n 1 "$tmp/out")" "state=mismatch"
cp "$tmp/pkg.abi" "$lib/grassfield-compositor.abi"
mv "$lib/grassfield-compositor.so" "$tmp/pkg.so" && ln -s "$tmp/pkg.so" "$lib/grassfield-compositor.so"
run "$script" --status
expect "a symlink in the packaged place is not a build" "$(head -n 1 "$tmp/out")" "state=mismatch"
rm -f "$lib/grassfield-compositor.so"
run "$script" --status
expect "--status: no extension installed" "$(head -n 2 "$tmp/out" | tr '\n' ' ')" "state=unknown reason=not-installed "
run GF_VERSION_H="$tmp/none.h" "$script" --status
expect "--status: no Hyprland headers" "$(tr '\n' ' ' <"$tmp/out")" "state=unknown reason=no-headers "

run "$script" --bogus; rc=$?
expect "unknown option: usage, exit 2" "$rc" 2

((fail == 0)) && echo "PASS: compositor_rebuild"
exit "$fail"
