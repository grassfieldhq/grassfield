#!/usr/bin/env bash
# GF-024 / A11Y-04 (macOS model): Ctrl+arrows and Ctrl+1..9 stay Spaces, Ctrl+Up stays Overview; every application still gets
# word navigation through Alt+arrows (forwarded as the Ctrl chord), terminals keep their Alt+arrows, and Super+1..9 /
# Super+Up reach the keys Grassfield Files and Preview advertise (Ctrl+1..4, Ctrl+9, Ctrl+Up). bindings.lua and forwarding.lua in config/hypr/grassfield
# run by a plain Lua interpreter against a stub of Hyprland's `hl` table: what each bind sends is checked, not whether
# Hyprland delivers it (that is the nested check in docs/owner-setup/real-session.md section 5). Needs `lua`.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
if ! command -v lua >/dev/null; then echo "SKIP: no Lua interpreter"; exit 0; fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/bindings-forward.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

cat >"$tmp/run.lua" <<'LUA'
local repo = arg[1]
local binds, dispatched, timers, active = {}, {}, {}, nil
local function proxy(path)
  return setmetatable({}, { __index = function(_, k) return proxy(path .. "." .. k) end,
                            __call = function(_, ...) return { dsp = path, args = { ... } } end })
end
hl = setmetatable({
  bind = function(keys, d, opts) binds[keys] = { d = d, opts = opts or {} } end,
  dispatch = function(d) dispatched[#dispatched + 1] = d end,
  timer = function(fn) timers[#timers + 1] = fn end,
  get_active_window = function() return active end,
  get_layers = function() return {} end,
  gesture = function() end,
}, { __index = function() return function() end end })
hl.dsp = proxy("dsp")
dofile(repo .. "/config/hypr/grassfield/bindings.lua")
dofile(repo .. "/config/hypr/grassfield/forwarding.lua")

local function press(keys, class)
  active = class and { class = class } or nil
  dispatched, timers = {}, {}
  local b = assert(binds[keys], "no bind for " .. keys)
  if type(b.d) == "function" then b.d() end
  for _, t in ipairs(timers) do t() end  -- the oneshot key-up
  local out = {}
  for _, d in ipairs(dispatched) do
    local a = d.args[1]
    out[#out + 1] = d.dsp:gsub("^dsp%.", "") .. "(" .. (a.mods or "") .. "," .. (a.key or "") .. "," .. (a.state or "") .. ")"
  end
  return table.concat(out, " ")
end
local function sent(keys, class, expect)
  local got = press(keys, class)
  print((got == expect and "ok" or "BAD") .. " " .. keys .. " [" .. tostring(class) .. "] -> " .. got)
end

-- Spaces and Overview are untouched.
local function dsp_of(keys) return type(binds[keys].d) == "table" and binds[keys].d.dsp or "function" end
print("spaces " .. dsp_of("CTRL + LEFT") .. " " .. dsp_of("CTRL + RIGHT") .. " " .. dsp_of("CTRL + code:10") .. " " .. dsp_of("CTRL + code:18") .. " " .. dsp_of("CTRL + UP"))

-- Word navigation in a normal application: the Ctrl chord, key down then up.
sent("ALT + LEFT", "firefox", "send_key_state(CTRL,Left,down) send_key_state(CTRL,Left,up)")
sent("ALT + RIGHT", "org.kde.kate", "send_key_state(CTRL,Right,down) send_key_state(CTRL,Right,up)")
sent("ALT + SHIFT + LEFT", "firefox", "send_key_state(CTRL SHIFT,Left,down) send_key_state(CTRL SHIFT,Left,up)")
sent("ALT + SHIFT + RIGHT", "firefox", "send_key_state(CTRL SHIFT,Right,down) send_key_state(CTRL SHIFT,Right,up)")
sent("ALT + BACKSPACE", "firefox", "send_key_state(CTRL,BackSpace,down) send_key_state(CTRL,BackSpace,up)")
sent("ALT + DELETE", "firefox", "send_key_state(CTRL,Delete,down) send_key_state(CTRL,Delete,up)")
sent("ALT + LEFT", nil, "send_key_state(CTRL,Left,down) send_key_state(CTRL,Left,up)")
-- Terminals keep Alt+arrows (tmux, vim, readline).
sent("ALT + LEFT", "kitty", "send_key_state(ALT,Left,down) send_key_state(ALT,Left,up)")
sent("ALT + SHIFT + RIGHT", "Alacritty", "send_key_state(ALT SHIFT,Right,down) send_key_state(ALT SHIFT,Right,up)")
sent("ALT + BACKSPACE", "com.mitchellh.ghostty", "send_key_state(ALT,BackSpace,down) send_key_state(ALT,BackSpace,up)")
sent("ALT + LEFT", "org.omarchy.btop", "send_key_state(ALT,Left,down) send_key_state(ALT,Left,up)")
-- History keys for browsers: Command+[ and ].
sent("SUPER + bracketleft", "firefox", "send_key_state(ALT,Left,down) send_key_state(ALT,Left,up)")
sent("SUPER + bracketright", "firefox", "send_key_state(ALT,Right,down) send_key_state(ALT,Right,up)")
-- Command+number and Command+Up reach the keys the Grassfield apps advertise with Ctrl (by keycode: every layout).
for n = 1, 9 do sent("SUPER + code:" .. (n + 9), "org.grassfield.Files", "send_key_state(CTRL,code:" .. (n + 9) .. ",down) send_key_state(CTRL,code:" .. (n + 9) .. ",up)") end
-- Command+arrows (macOS text model); Grassfield Files keeps Enclosing Folder / Open on Command+Up / Down.
local function both(mods, key) return "send_key_state(" .. mods .. "," .. key .. ",down) send_key_state(" .. mods .. "," .. key .. ",up)" end
sent("SUPER + UP", "org.grassfield.Files", both("CTRL", "Up"))
sent("SUPER + DOWN", "org.grassfield.Files", both("CTRL", "Down"))
sent("SUPER + UP", "firefox", both("CTRL", "Home"))
sent("SUPER + DOWN", "firefox", both("CTRL", "End"))
sent("SUPER + UP", "kitty", both("CTRL", "Home"))
sent("SUPER + LEFT", "firefox", both("", "Home"))
sent("SUPER + RIGHT", "kitty", both("", "End"))
sent("SUPER + SHIFT + LEFT", "firefox", both("SHIFT", "Home"))
sent("SUPER + SHIFT + RIGHT", "firefox", both("SHIFT", "End"))
sent("SUPER + SHIFT + UP", "firefox", both("CTRL SHIFT", "Home"))
sent("SUPER + SHIFT + DOWN", "org.grassfield.Files", both("CTRL SHIFT", "End"))
-- Command+Backspace: Shift+Home, then BackSpace from the timer (the stub runs timers in order, including ones they add).
sent("SUPER + BACKSPACE", "firefox", both("SHIFT", "Home") .. " " .. both("", "BackSpace"))
print("repeat " .. tostring(binds["ALT + LEFT"].opts.repeating) .. " " .. tostring(binds["ALT + BACKSPACE"].opts.repeating))
-- Keyboard access to the bar (gate A1, rc7 audit R7-A11Y-02): what Ctrl+F2 and Ctrl+F8 run, and their descriptions.
local function cmd_of(keys)
  local b = binds[keys]
  if not b or type(b.d) ~= "table" or b.d.dsp ~= "dsp.exec_cmd" then return "unbound" end
  return b.opts.description .. " | " .. tostring(b.d.args[1])
end
print("menubar-f2 " .. cmd_of("CTRL + F2"))
print("menubar-f8 " .. cmd_of("CTRL + F8"))
LUA

cat >"$tmp/sources.lua" <<'LUA'
-- Input sources: bindings.lua reads the layout count omarchy.lua left in package.loaded, once per parse.
local repo, kb_layout = arg[1], arg[2]
local binds, locks = {}, {}
local function proxy(path)
  return setmetatable({}, { __index = function(_, k) return proxy(path .. "." .. k) end,
                            __call = function(_, ...) return { dsp = path, args = { ... } } end })
end
hl = setmetatable({
  bind = function(keys, d, opts) binds[keys] = d; locks[keys] = opts and opts.locked end,
  get_layers = function() return {} end,
  get_config = function(key) if key == "input.kb_layout" then return kb_layout end end,
}, { __index = function() return function() end end })
hl.dsp = proxy("dsp")
dofile(repo .. "/config/hypr/grassfield/bindings.lua")
local function cmd(keys) return binds[keys] and binds[keys].args[1] or "unbound" end
print(kb_layout .. " " .. cmd("CTRL + SPACE") .. " | " .. cmd("CTRL + ALT + SPACE") .. " locked " .. tostring(locks["CTRL + SPACE"]) .. " " .. tostring(locks["CTRL + ALT + SPACE"]))
LUA

out=$(env -i PATH="$PATH" lua "$tmp/run.lua" "$root")
echo "$out" | sed 's/^/    /'
desc="Spaces and Overview binds are still dispatchers (CTRL+LEFT/RIGHT, CTRL+1..9 focus Spaces, CTRL+UP runs the Overview command): the macOS keys are kept"
check grep -q "^spaces dsp.focus dsp.focus dsp.focus dsp.focus dsp.exec_cmd$" <<<"$out"
desc="every forwarded key sends exactly the expected chord (no BAD line)"
check bash -c '! grep -q "^BAD" <<<"$1" && [[ $(grep -c "^ok " <<<"$1") == 34 ]]' _ "$out"
desc="word navigation repeats while the keys are held"
check grep -q "^repeat true true$" <<<"$out"

desc="Files and Preview advertise the keys that Super now delivers (Ctrl+1..4, Ctrl+Up; Ctrl+9)"
check bash -c 'grep -q "Ctrl+1" "$1/apps/files/qml/BrowserWindow.qml" && grep -q "Ctrl+Up" "$1/apps/files/qml/BrowserWindow.qml" && grep -q "Ctrl+9" "$1/apps/preview/qml/Viewer.qml"' _ "$root"

desc="Files and Preview menus show the chord the user presses (Super+1..4, Super+Up, Super+9; Open is Cmd+O, decision F-4), not the Ctrl one they accept"
check bash -c 'f="$1/apps/files/qml/GlobalMenu.qml"; p="$1/apps/preview/qml/GlobalMenu.qml"; for k in 1 2 3 4 Up; do grep -q "shortcut: \"Super+$k\"" "$f" || exit 1; done; grep -q "shortcut: \"Super+9\"" "$p" && grep -q "shortcut: \"Ctrl+O\"" "$f" && ! grep -q "shortcut: \"Ctrl+\(1\|2\|3\|4\|Up\|Down\|9\)\"" "$f" "$p"' _ "$root"

desc="Settings > Keyboard lists forwarding.lua (page reads it, parser accepts word_key lines)"
check bash -c 'grep -q "forwarding.lua" "$1/apps/settings/qml/KeyboardPage.qml" && grep -q "word_key" "$1/apps/settings/qml/Bindings.js"' _ "$root"

f2=$(sed -n 's/^menubar-f2 //p' <<<"$out")
f8=$(sed -n 's/^menubar-f8 //p' <<<"$out")
desc="R7-A11Y-02: Ctrl+F8 (macOS Move focus to status menus) is bound, and runs exactly Ctrl+F2's request with 'open status' for 'open system' (the shell's MenuBar.openFirstStatus)"
want=$(sed -e 's/^Focus the menu bar | /Focus the status menus | /' -e "s/ call menubar open system ''\$/ call menubar open status ''/" <<<"$f2")
check bash -c '[[ $1 == *" call menubar open system '"''"'" && $2 == *" call menubar open status '"''"'" && $2 == "$3" ]]' _ "$f2" "$f8" "$want"
desc="R7-A11Y-02: Settings > Keyboard lists Ctrl+F8 (a literal bind() line, its description listed for translation, with a French text)"
check bash -c 'grep -qx "bind(\"CTRL + F8\", \"Focus the status menus\", shell(\"menubar\", \"open status '"''"'\"))" "$1/config/hypr/grassfield/bindings.lua" && grep -qF "QT_TRANSLATE_NOOP(\"Bindings\", \"Focus the status menus\")" "$1/apps/settings/qml/Bindings.js" && grep -A1 -F "<source>Focus the status menus</source>" "$1/translations/grassfield_fr.ts" | grep -qF "<translation>Activer les menus d’état</translation>"' _ "$root"

desc="GF-106 / GF-064: Show Desktop on Super+F3 and the zoom keys (Super+Alt+8, =, -) reach the shell, and none of them clashes with another bind"
check bash -c 'f="$1/config/hypr/grassfield/bindings.lua"; for k in "SUPER + F3" "SUPER + ALT + code:17" "SUPER + ALT + code:21" "SUPER + ALT + code:20"; do [ "$(grep -c "^bind(\"$k\"" "$f")" = 1 ] || exit 1; done; grep -q "shell(\"windows\", \"showDesktop\")" "$f" && grep -q "shell(\"zoom\", \"toggle\")" "$f"' _ "$root"

desc="WezTerm (class org.wezfurlong.wezterm) is a terminal that keeps its Alt+arrows, with the other terminals of Omarchy's list"
check bash -c 'for c in alacritty kitty com.mitchellh.ghostty foot org.codeberg.dnkl.foot wezterm org.wezfurlong.wezterm; do grep -q "TERMINAL_CLASSES = {.*\"$c\"" "$1/config/hypr/grassfield/forwarding.lua" || exit 1; done' _ "$root"

desc="Input sources: with two layouts Ctrl+Space selects the previous and Ctrl+Option+Space the next one on ALL keyboards, and both are locked (they work at the lock screen)"
check grep -q "^fr,us hyprctl switchxkblayout all prev | hyprctl switchxkblayout all next locked true true$" <<<"$(env -i PATH="$PATH" lua "$tmp/sources.lua" "$root" fr,us)"
desc="Input sources: with one layout, none or an unreadable value Ctrl+Space stays free for the applications"
check grep -q "^us unbound | unbound locked nil nil$" <<<"$(env -i PATH="$PATH" lua "$tmp/sources.lua" "$root" us)"
check grep -q "^ unbound | unbound locked nil nil$" <<<"$(env -i PATH="$PATH" lua "$tmp/sources.lua" "$root" "")"
desc="Input sources: no xkb group option is set anywhere in config/"
check bash -c '! grep -rq "grp:ctrl_space_toggle" "$1/config"' _ "$root"

exit $fail
