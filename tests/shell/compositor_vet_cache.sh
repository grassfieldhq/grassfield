#!/usr/bin/env bash
# CIO-03: the session loader's --vetted check (a bash script of some 40 processes, forked on Hyprland's main thread) runs once
# per build and Hyprland instance. config/hypr/grassfield/compositor.lua M.vetted_once, run by a plain Lua interpreter with a
# probe that answers like the plugin's (lstat identities, regular-file reads) on real files: a second ask with nothing changed
# does not run the check; a rebuild (a new file renamed in), a chmod of the plugin, a directory made writable by others or
# another installed Grassfield version runs it again; the cheap refusals (no build, a stamp for another ABI or source) never
# run it; a check that was cut off is not kept; verify mode keeps nothing; without the plugin's probe the check runs each time,
# as before. Needs `lua` and coreutils `stat`.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
if ! command -v lua >/dev/null; then echo "SKIP: no Lua interpreter"; exit 0; fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/vet-cache.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
expect() { if [[ $2 == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1: got [$2], want [$3]"; fail=1; fi; }

abi=abc1234_aq_0.15_hu_0.14_hg_0.5_hc_0.7_hlg_0.6
mkdir -p "$tmp/runtime" "$tmp/cache/grassfield/compositor/$abi" "$tmp/src"
chmod 700 "$tmp/runtime"
build=$tmp/cache/grassfield/compositor/$abi
printf 'plugin\n' >"$build/grassfield-compositor.so"
printf '%s\nsource 1.0.0-1\n' "$abi" >"$build/grassfield-compositor.abi"
printf '1.0.0-1\n' >"$tmp/src/VERSION"

cat >"$tmp/run.lua" <<'LUA'
local root, tmp, abi, steps = arg[1], arg[2], arg[3], arg[4]
package.path = root .. "/config/hypr/?.lua;" .. package.path
local c = require("grassfield.compositor")
c.source_version = tmp .. "/src/VERSION"
local env_vars = { XDG_CACHE_HOME = tmp .. "/cache", XDG_RUNTIME_DIR = tmp .. "/runtime", HYPRLAND_INSTANCE_SIGNATURE = "abc1234_1_2" }
local calls = 0
local mode = "ok"
local function stat(path)
  local p = io.popen("stat -c '%F|%d:%i:%a:%u:%s:%.9Y:%.9Z' -- '" .. path .. "' 2>/dev/null")
  local line = p:read("l"); p:close()
  if not line then return nil end
  local kind, rest = line:match("^([^|]*)|(.*)$")
  if kind == "directory" then return "d:" .. rest end -- with its times: the fingerprint must leave them out itself
  return (kind == "regular file" and "f:" or "o:") .. rest
end
local function readf(path) local f = io.open(path, "r"); if not f then return nil end; local t = f:read("a"); f:close(); return t end
local probe = {
  available = function() return true end,
  identity = function(p) return stat(p), false end,
  read_file = function(p) return readf(p), false end,
}
local function env(extra)
  local e = { probe = probe, getenv = function(k) return env_vars[k] end, verifying = false,
              vetted = function() calls = calls + 1; if mode == "timeout" then return nil, "timeout" end
                                  return tmp .. "/cache/grassfield/compositor/" .. abi .. "/grassfield-compositor.so" end }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end
for step in steps:gmatch("[^,]+") do
  local before = calls
  if step == "ask" then c.vetted_once(abi, false, env())
  elseif step == "kept" then c.vetted_once(abi, true, env())
  elseif step == "timeout" then mode = "timeout"; c.vetted_once(abi, false, env()); mode = "ok"
  elseif step == "verify" then c.vetted_once(abi, false, env({ verifying = true }))
  elseif step == "noprobe" then c.vetted_once(abi, false, env({ probe = false }))
  elseif step == "other" then c.vetted_once("zzz9999_aq_1", false, env())
  else os.execute(step) end
  io.write(calls - before)
end
print()
LUA
run() { lua "$tmp/run.lua" "$root" "$tmp" "$abi" "$1"; }
reset() { rm -f "$tmp/runtime/"*; }

expect "asked twice with nothing changed: one check" "$(run ask,ask,ask)" "100"
reset
expect "the kept (loaded) build has its own entry" "$(run kept,kept,ask)" "101"
reset
expect "a rebuild (a new file renamed into place) checks again" \
  "$(run "ask,cp $build/grassfield-compositor.so $build/n && mv $build/n $build/grassfield-compositor.so,ask,ask")" "1010"
reset
expect "a chmod of the plugin checks again" "$(run "ask,chmod 0644 $build/grassfield-compositor.so,ask")" "101"
reset
expect "a directory above made writable by others checks again; a file made in it does not" \
  "$(run "ask,touch $tmp/cache/x,ask,chmod 0777 $tmp/cache,ask,chmod 0755 $tmp/cache")" "100010"
reset
expect "another installed Grassfield version: the stamp's source no longer matches, refused without a check" \
  "$(run "ask,echo 1.0.1-1 >$tmp/src/VERSION,ask,echo 1.0.0-1 >$tmp/src/VERSION,ask")" "10000"
reset
expect "no build for that ABI: refused without a check" "$(run other,other)" "00"
expect "a check cut off is not kept" "$(run timeout,ask)" "11"
reset
expect "a kept verdict naming another path than the build is not trusted: checked again, then kept" \
  "$(run "ask,sed -i 's|\t[^\t]*\$|\t/elsewhere/evil.so|' $tmp/runtime/*.vetted,ask,ask")" "1010"
reset
expect "verify mode keeps nothing" "$(run verify,ask)" "11"
reset
expect "without the plugin's probe the check runs each time (the first parse of a login)" "$(run noprobe,noprobe)" "11"
expect "the cache lives next to the runtime note of the instance" "$(ls "$tmp/runtime")" ""
run ask >/dev/null
expect "... named after it" "$(ls "$tmp/runtime")" "grassfield-compositor-abc1234_1_2.vetted"
exit $fail
