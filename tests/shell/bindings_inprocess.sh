#!/usr/bin/env bash
# CIO-01: the shell's keys and gestures reach it in-process. config/hypr/grassfield/bindings.lua, run by a plain Lua
# interpreter against a stub of Hyprland's `hl` table, binds every shell key to Hyprland's `event` dispatcher
# (`gfkey/1 <target> <function> [argument...]` on socket2, read by shell/platform/shortcuts) and no shell key starts a
# process any more; the lock key alone stays a `qs ipc` call to the security process with its stand-in (it must lock with the
# UI process dead); the Overview and Apps gestures send their progress (begin, updates of at least 1 %, an end that says
# commit or back); a Hyprland without the event dispatcher gets the `qs ipc` path of before. Whether Hyprland delivers the
# event is the owner's real-session check. Needs `lua`.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
if ! command -v lua >/dev/null; then echo "SKIP: no Lua interpreter"; exit 0; fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/bindings-inprocess.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

cat >"$tmp/run.lua" <<'LUA'
local repo, with_event = arg[1], arg[2] == "event"
local binds, gestures, dispatched = {}, {}, {}
local function proxy(path)
  return setmetatable({}, { __index = function(_, k)
                              if k == "event" and not with_event then return nil end
                              return proxy(path .. "." .. k)
                            end,
                            __call = function(_, ...) return { dsp = path, args = { ... } } end })
end
hl = setmetatable({
  bind = function(keys, d, opts) binds[#binds + 1] = { keys = keys, d = d, opts = opts or {} } end,
  dispatch = function(d) dispatched[#dispatched + 1] = d end,
  gesture = function(spec) gestures[#gestures + 1] = spec end,
  get_layers = function() return {} end,
  get_config = function() return nil end,
}, { __index = function() return function() end end })
hl.dsp = proxy("dsp")
local module = dofile(repo .. "/config/hypr/grassfield/bindings.lua")

print("in_process " .. tostring(module.in_process))
-- Every bind: its keys, the dispatcher it runs (functions are pressed once and report what they dispatched).
for _, b in ipairs(binds) do
  local d = b.d
  if type(d) == "function" then
    dispatched = {}
    d()
    d = dispatched[1] or { dsp = "none", args = {} }
  end
  print("bind\t" .. b.keys .. "\t" .. d.dsp .. "\t" .. tostring(d.args[1]))
end
-- Every gesture: its action kind; a tracked one is run through a swipe or pinch.
for _, g in ipairs(gestures) do
  local a = g.action
  if type(a) == "table" then
    dispatched = {}
    local pinch = g.direction:find("pinch") ~= nil
    local up = g.direction == "up" or g.direction == "pinchin"
    local function ev(i, extra)
      local e = { time_ms = 1000 + i * 10 }
      if pinch then e.scale = up and (1 - i * 0.02) or (1 + i * 0.04) elseif i > 0 then e.delta = { x = 0, y = up and -15 or 9 } end
      for k, v in pairs(extra or {}) do e[k] = v end
      return e
    end
    a.start(ev(0))
    for i = 1, 20 do a.update(ev(i)) end
    a["end"]({ time_ms = 1300, cancelled = false })
    local out = {}
    for _, d in ipairs(dispatched) do out[#out + 1] = d.args[1] end
    print("gesture\t" .. g.fingers .. " " .. g.direction .. "\t" .. #dispatched .. "\t" .. out[1] .. "\t" .. out[#out - 1] .. "\t" .. out[#out])
    -- A short, slow gesture goes back; a cancelled one says so.
    dispatched = {}
    a.start(ev(0)); a.update(ev(1)); a["end"]({ time_ms = 5000, cancelled = false })
    print("short\t" .. g.direction .. "\t" .. dispatched[#dispatched].args[1])
    dispatched = {}
    a.start(ev(0)); a.update(ev(1)); a["end"]({ time_ms = 5000, cancelled = true })
    print("cancel\t" .. g.direction .. "\t" .. dispatched[#dispatched].args[1])
  else
    print("gesture\t" .. g.fingers .. " " .. g.direction .. "\t" .. type(a))
  end
end
print("format " .. module.tracked.format(0) .. " " .. module.tracked.format(0.12345) .. " " .. module.tracked.format(0.5) .. " " .. module.tracked.format(1.2) .. " " .. module.tracked.format(0.00001))
LUA

on=$(env -i PATH="$PATH" lua "$tmp/run.lua" "$root" event)
off=$(env -i PATH="$PATH" lua "$tmp/run.lua" "$root" none)
echo "$on" | sed 's/^/    /'

desc="with Hyprland's event dispatcher the bindings deliver in-process"
check grep -qx "in_process true" <<<"$on"
desc="every shell key sends a gfkey/1 event: Search, Overview, the switcher (with its hold id), tiling, volume (held key), the menu bar (no '' argument)"
check bash -c 'for want in "SUPER + SPACE	dsp.event	gfkey/1 search toggle" "CTRL + UP	dsp.event	gfkey/1 overview toggle" \
    "SUPER + CTRL + LEFT	dsp.event	gfkey/1 windows tile left" "XF86AudioRaiseVolume	dsp.event	gfkey/1 volume up" \
    "CTRL + F8	dsp.event	gfkey/1 menubar open status" "SUPER + ALT + ESCAPE	dsp.event	gfkey/1 menubar panel forcequit" \
    "SUPER + M	dsp.event	gfkey/1 windows minimize" "SUPER + ALT + 3	dsp.event	gfkey/1 stages activate 3"; do
    grep -qxF "bind	$want" <<<"$1" || { echo "missing: $want"; exit 1; }; done
  grep -qE "^bind	SUPER \+ TAB	dsp.event	gfkey/1 switcher next [0-9]+$" <<<"$1" &&
  grep -qE "^bind	SUPER \+ Q	dsp.event	gfkey/1 switcher quit$|^bind	SUPER \+ Q	dsp.window.close" <<<"$1"' _ "$on"
desc="no shell key starts a process: the only qs ipc command of the bindings is the lock key's (security process, then its stand-in)"
check bash -c '[[ $(grep -P "^bind\t" <<<"$1" | grep -c "qs ipc") == 1 ]] &&
  grep -P "^bind\tSUPER \+ CTRL \+ Q\tdsp.exec_cmd\t" <<<"$1" | grep -q "qs ipc -p .*security.qml.* call lock lock" &&
  grep -P "^bind\tSUPER \+ CTRL \+ Q\t" <<<"$1" | grep -q "omarchy-shell lock lock"' _ "$on"
desc="Overview (3 fingers up/down) and Apps (4-finger pinch in/out) follow the fingers: begin at 0, updates, an end that commits after a full swipe"
check bash -c 'for g in "3 up	.*	gfgesture/1 overview-open begin 0	gfgesture/1 overview-open update 1	gfgesture/1 overview-open end 1 commit" \
    "3 down	.*	gfgesture/1 overview-close begin 0	gfgesture/1 overview-close update 0.6	gfgesture/1 overview-close end 0.6 commit" \
    "4 pinchin	.*	gfgesture/1 apps-open begin 0	gfgesture/1 apps-open update 0.8	gfgesture/1 apps-open end 0.8 commit" \
    "4 pinchout	.*	gfgesture/1 apps-close begin 0	gfgesture/1 apps-close update 0.8	gfgesture/1 apps-close end 0.8 commit"; do
    grep -qP "^gesture\t$g$" <<<"$1" || { echo "missing: $g"; exit 1; }; done' _ "$on"
desc="a gesture's updates are throttled to 1 % steps (22 events for 20 motions, not one per motion when nothing changed)"
check bash -c 'n=$(grep -P "^gesture\t3 up\t" <<<"$1" | cut -f3); (( n >= 3 && n <= 22 ))' _ "$on"
desc="a short slow gesture goes back, a cancelled one says cancel"
check bash -c 'grep -qP "^short\tup\tgfgesture/1 overview-open end 0.05 back$" <<<"$1" && grep -qP "^cancel\tup\tgfgesture/1 overview-open cancel 0.05$" <<<"$1"' _ "$on"
desc="progress is written as the shell parses it: 0, 1 or 0.xxxx"
check grep -qx "format 0 0.1235 0.5 1 0" <<<"$on"
desc="without the event dispatcher (an older Hyprland) every shell key and gesture uses qs ipc as before"
check bash -c 'grep -qx "in_process false" <<<"$1" &&
  grep -qP "^bind\tSUPER \+ SPACE\tdsp.exec_cmd\t.*qs ipc -p .* call search toggle$" <<<"$1" &&
  ! grep -qP "^bind\t.*\tdsp.event\t" <<<"$1" && grep -qP "^gesture\t3 up\tfunction$" <<<"$1"' _ "$off"
exit $fail
