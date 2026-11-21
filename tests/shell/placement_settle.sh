#!/usr/bin/env bash
# CIO-17: a window that placement.lua resizes or moves in its window.open hook takes that box from its first frame (the
# plugin's hl.plugin.grassfield.settle warps it), instead of growing or sliding through the 300 ms windowsMove animation over
# its opening; a window the hook leaves alone keeps its opening animation (no settle). config/hypr/grassfield/placement.lua
# run by a plain Lua interpreter against a stub of Hyprland's `hl` table. Needs `lua`.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
if ! command -v lua >/dev/null; then echo "SKIP: no Lua interpreter"; exit 0; fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/placement-settle.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
expect() { if [[ $2 == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1: got [$2], want [$3]"; fail=1; fi; }

cat >"$tmp/run.lua" <<'LUA'
local repo, plugin = arg[1], arg[2] == "plugin"
local handlers, log = {}, {}
local function proxy(path)
  return setmetatable({}, { __index = function(_, k) return proxy(path .. "." .. k) end,
                            __call = function(_, ...) return { dsp = path } end })
end
hl = setmetatable({
  on = function(name, fn) handlers[name] = fn end,
  dispatch = function(d) log[#log + 1] = d.dsp:gsub("^dsp%.window%.", "") end,
  get_windows = function() return {} end,
  plugin = plugin and { grassfield = { settle = function(address) log[#log + 1] = "settle " .. address end } } or {},
}, { __index = function() return function() end end })
hl.dsp = proxy("dsp")
dofile(repo .. "/config/hypr/grassfield/placement.lua")
local monitor = { x = 0, y = 0, width = 1920, height = 1080, scale = 1, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
local function open(w)
  log = {}
  handlers["window.open"](w)
  return table.concat(log, ",")
end
local base = { floating = true, fullscreen = 0, class = "org.example.app", title = "x", monitor = monitor }
local function win(t) local w = {} for k, v in pairs(base) do w[k] = v end for k, v in pairs(t) do w[k] = v end return w end
print("tall " .. open(win({ address = "0xa1", at = { 10, 0 }, size = { 800, 1080 } })))
print("fits " .. open(win({ address = "0xa2", at = { 100, 200 }, size = { 800, 600 } })))
print("browser " .. open(win({ address = "0xa3", class = "firefox", at = { 100, 200 }, size = { 400, 300 } })))
LUA
on=$(lua "$tmp/run.lua" "$root" plugin)
off=$(lua "$tmp/run.lua" "$root" none)
printf '    %s\n' "$on"
expect "an oversized window is fitted and settled at once (no slide from under the menu bar)" "$(sed -n 's/^tall //p' <<<"$on")" "resize,move,settle 0xa1"
expect "a window the hook leaves alone keeps its opening animation (no settle)" "$(sed -n 's/^fits //p' <<<"$on")" ""
expect "a browser's first window grows to the default size at once" "$(sed -n 's/^browser //p' <<<"$on")" "resize,center,settle 0xa3"
expect "without the plugin the fit is dispatched as before" "$(sed -n 's/^tall //p' <<<"$off")" "resize,move"
exit $fail
