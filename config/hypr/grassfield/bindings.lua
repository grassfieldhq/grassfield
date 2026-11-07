-- Grassfield keyboard and pointer bindings (ADR-0002). SUPER plays the role of Command.
-- Shell actions go through `qs ipc` into the running grassfield-shell instance.

-- The dev session runs the shell from the repository (-p $GRASSFIELD_SHELL_DIR); the installed session always from the
-- system location, never by name (`-c` would also search the user-writable ~/.config/quickshell, GF-115).
-- GRASSFIELD_SHELL_DIR is dev plumbing (ADR-0019): honoured only in a dev session (GRASSFIELD_DEV exactly "1" and
-- GRASSFIELD_SESSION not "1"; session.lua sets GRASSFIELD_SESSION=1 before this file loads), so a stray value in a real
-- session cannot send the lock key's request to another shell (follow-up of the re-review of bf9e280).
local dev_session = os.getenv("GRASSFIELD_DEV") == "1" and os.getenv("GRASSFIELD_SESSION") ~= "1"
local shell_dir = dev_session and os.getenv("GRASSFIELD_SHELL_DIR") or nil
local shell_selector = (shell_dir and shell_dir ~= "") and ("-p '" .. shell_dir .. "'") or "-p '/usr/share/grassfield/shell'"

-- Every request runs with Quickshell's option variables cleared: a stray QS_MANIFEST or QS_CONFIG_NAME in the session
-- made `qs ipc -p` exit 108 ("--path excludes --manifest"), so the lock key did nothing (re-review of bf9e280, M1;
-- the list is the one grassfield-shell.service clears; tests/security/lock_request_env.sh).
local qs_ipc = "env -u QS_CONFIG_PATH -u QS_CONFIG_NAME -u QS_MANIFEST qs ipc " .. shell_selector

local function shell(target, fn)
  return hl.dsp.exec_cmd(qs_ipc .. " call " .. target .. " " .. fn)
end

local function bind(keys, description, dispatcher, opts)
  opts = opts or {}
  opts.description = description
  hl.bind(keys, dispatcher, opts)
end

-- App switcher (macOS Cmd+Tab, shell/switcher; docs/specs/switcher.md, Key handling). No key map (submap) is used: the
-- shell takes the keyboard with an exclusive layer surface when SUPER+TAB fires, so no global mode can get stuck.
-- Hyprland records the key map that was active when a key went DOWN and checks only that map's binds on release
-- (KeybindManager.cpp, efb5099), so a release bind inside a map entered after SUPER went down never fires; the release
-- bind below lives in the default map, where SUPER went down.
--
-- Every request carries a hold id (one per physical hold of SUPER): `next` and `release` are separate `qs ipc`
-- processes that can arrive in either order after a quick tap, and the shell orders them by id.
-- Ids start from the clock, so that a config reload (a new Lua state) never reuses ids the shell has already seen.
local switcher_id = os.time()
local switcher_held = false

local function switcher_request(request)
  return function()
    if not switcher_held then
      switcher_held = true
      switcher_id = switcher_id + 1
    end
    hl.dispatch(shell("switcher", request .. " " .. switcher_id))
  end
end

-- SUPER released: tell the shell once per hold (a stale request is ignored by the shell).
local function switcher_release()
  if not switcher_held then
    return
  end
  switcher_held = false
  hl.dispatch(shell("switcher", "release " .. switcher_id))
end

-- True while the switcher surface (exclusive keyboard grab) is mapped: SUPER+Q and SUPER+H then act on the selected app.
local function switcher_mapped()
  for _, layer in ipairs(hl.get_layers({ namespace = "grassfield-switcher" })) do
    if layer.mapped then
      return true
    end
  end
  return false
end

local function in_switcher_else(request, otherwise)
  return function()
    hl.dispatch(switcher_mapped() and shell("switcher", request) or otherwise)
  end
end

-- Full Screen and Zoom keys, as the Window menu has them (ADR-0040 step 1b's review): a window of fixed size is left alone
-- (only Exit Full Screen and Unzoom act on it). The compositor plugin decides at each press: hl.plugin.grassfield.window_size
-- returns Hyprland's own dispatcher, or a no-op for such a window. Without the plugin (or if it fails), Hyprland's dispatcher
-- as before (gate C2).
local function window_size(mode)
  local plain = hl.dsp.window.fullscreen({ mode = mode })
  return function()
    local ok, decided = pcall(function()
      return hl.plugin.grassfield.window_size(mode)
    end)
    hl.dispatch((ok and decided) or plain)
  end
end

-- Windows
bind("SUPER + Q", "Close window", in_switcher_else("quit", hl.dsp.window.close()))
bind("SUPER + W", "Close window", hl.dsp.window.close())
bind("SUPER + CTRL + F", "Full screen", window_size("fullscreen"))
bind("SUPER + ALT + F", "Zoom (fill the screen)", window_size("maximized"))
-- Window tiling (macOS 15+ Globe+Ctrl+arrows; Super plays Command here): halves, and back to the size from before. The
-- compositor plugin places the window (window-tiling); the Window menu's Move & Resize shows the same keys
-- (docs/specs/tiling.md TL26). The quarters are bound by key position (code: keycodes 30, 31, 44 and 45: U, I, J and K, in
-- the same place on QWERTY and AZERTY), the arrangements take the window and the next ones of its output (tiling-arrange),
-- Super+Ctrl+Alt+Left/Right move it to the next display and Super+Ctrl+L (keycode 46, by position too, T2a) opens its tiling
-- popover with the keyboard (tile-hover).
bind("SUPER + CTRL + LEFT", "Tile the window to the left half", shell("windows", "tile left"))
bind("SUPER + CTRL + RIGHT", "Tile the window to the right half", shell("windows", "tile right"))
bind("SUPER + CTRL + UP", "Tile the window to the top half", shell("windows", "tile top"))
bind("SUPER + CTRL + DOWN", "Tile the window to the bottom half", shell("windows", "tile bottom"))
bind("SUPER + CTRL + R", "Return the window to its previous size", shell("windows", "tile previous"))
bind("SUPER + CTRL + code:30", "Tile the window to the top-left quarter", shell("windows", "tile top-left"))
bind("SUPER + CTRL + code:31", "Tile the window to the top-right quarter", shell("windows", "tile top-right"))
bind("SUPER + CTRL + code:44", "Tile the window to the bottom-left quarter", shell("windows", "tile bottom-left"))
bind("SUPER + CTRL + code:45", "Tile the window to the bottom-right quarter", shell("windows", "tile bottom-right"))
bind("SUPER + CTRL + RETURN", "Fill the screen with the window", shell("windows", "tile fill"))
bind("SUPER + CTRL + C", "Center the window", shell("windows", "tile center"))
bind("SUPER + CTRL + SHIFT + LEFT", "Arrange the windows left and right", shell("windows", "arrange left-right"))
bind("SUPER + CTRL + SHIFT + RIGHT", "Arrange the windows right and left", shell("windows", "arrange right-left"))
bind("SUPER + CTRL + SHIFT + UP", "Arrange the windows top and bottom", shell("windows", "arrange top-bottom"))
bind("SUPER + CTRL + SHIFT + DOWN", "Arrange the windows bottom and top", shell("windows", "arrange bottom-top"))
bind("SUPER + CTRL + ALT + SHIFT + LEFT", "Arrange the windows left and in quarters", shell("windows", "arrange left-quarters"))
bind("SUPER + CTRL + ALT + SHIFT + RIGHT", "Arrange the windows right and in quarters", shell("windows", "arrange right-quarters"))
bind("SUPER + CTRL + ALT + SHIFT + UP", "Arrange the windows top and in quarters", shell("windows", "arrange top-quarters"))
bind("SUPER + CTRL + ALT + SHIFT + DOWN", "Arrange the windows bottom and in quarters", shell("windows", "arrange bottom-quarters"))
bind("SUPER + CTRL + ALT + LEFT", "Move the window to the display on the left", shell("windows", "nextOutput left"))
bind("SUPER + CTRL + ALT + RIGHT", "Move the window to the display on the right", shell("windows", "nextOutput right"))
bind("SUPER + CTRL + code:46", "Show the tiling options of the window", shell("windows", "tilePopover"))
bind("SUPER + T", "Toggle floating/tiling", hl.dsp.window.float({ action = "toggle" }))
bind("SUPER + M", "Minimize window", shell("windows", "minimize"))
bind("SUPER + H", "Hide app", in_switcher_else("hide", shell("windows", "hide")))
bind("SUPER + mouse:272", "Move window", hl.dsp.window.drag(), { mouse = true })
bind("SUPER + mouse:273", "Resize window", hl.dsp.window.resize(), { mouse = true })

-- Application switcher: Tab (and its key repeat) moves the selection; arrows and Esc reach the shell through its grab.
bind("SUPER + TAB", "Switch application", switcher_request("next"), { repeating = true })
bind("SUPER + SHIFT + TAB", "Switch to the previous application", switcher_request("previous"), { repeating = true })
for _, key in ipairs({ "SUPER + Super_L", "SUPER + Super_R", "Super_L", "Super_R" }) do
  -- transparent: Hyprland shadows every bind whose key is still down once another bind fired (shadowKeybinds), so
  -- without it the SUPER release would be ignored after SUPER+TAB.
  bind(key, "Activate the selected application", switcher_release, { release = true, non_consuming = true, transparent = true })
end
-- The key above Tab (grave on a US layout, ² on AZERTY): bound by keycode, so it works on every layout.
bind("SUPER + code:49", "Next window of the application", shell("windows", "cycleApp"))

-- Window cycling inside the active Stage (Hyprland cycle_next; docs/specs/stages.md ST10).
bind("ALT + TAB", "Next window", hl.dsp.window.cycle_next())
bind("ALT + TAB", "Raise window", hl.dsp.window.bring_to_top())
bind("ALT + SHIFT + TAB", "Previous window", hl.dsp.window.cycle_next({ next = false }))
bind("ALT + SHIFT + TAB", "Raise window", hl.dsp.window.bring_to_top())

-- Spaces
bind("CTRL + LEFT", "Previous Space", hl.dsp.focus({ workspace = "r-1" }))
bind("CTRL + RIGHT", "Next Space", hl.dsp.focus({ workspace = "r+1" }))
for space = 1, 9 do
  bind("CTRL + code:" .. tostring(space + 9), "Switch to Space " .. space, hl.dsp.focus({ workspace = tostring(space) }))
end

-- Input sources (macOS: Ctrl+Space selects the previous input source, Ctrl+Option+Space the next one). Hyprland 0.56 has no Lua
-- dispatcher for it (only `hyprctl switchxkblayout`), and an xkb group option would switch only the keyboard being typed on,
-- so both go through hyprctl with "all": every keyboard follows. Bound from two layouts only: with one, Ctrl+Space stays with
-- the applications (completion in an editor), as on a Mac with a single input source. Settings > Keyboard writes the layouts and
-- reloads, which parses this file again: the keys appear and disappear with that reload (the count is the kb_layout this parse
-- has reached, read with hl.get_config: the layout of Omarchy, Settings or the user's own input.lua). They are `locked`: the
-- password of the lock screen must be typeable in either layout (the old xkb option worked there too).
-- (Omarchy binds no CTRL+SPACE nor CTRL+ALT+SPACE; its SPACE binds all hold SUPER.)
local kb_layout = hl.get_config("input.kb_layout")
local layouts = 0
if type(kb_layout) == "string" and kb_layout ~= "" then
  for _ in (kb_layout .. ","):gmatch("([^,]*),") do layouts = layouts + 1 end
end
if layouts >= 2 then
  bind("CTRL + SPACE", "Previous input source", hl.dsp.exec_cmd("hyprctl switchxkblayout all prev"), { locked = true })
  bind("CTRL + ALT + SPACE", "Next input source", hl.dsp.exec_cmd("hyprctl switchxkblayout all next"), { locked = true })
end

-- Dictation (ADR-0045 OC-5, Settings > Keyboard > Dictation): Ctrl-Super-X starts and stops Omarchy's voxtype. Omarchy 4.0.6's own
-- binding (default/hypr/bindings/voxtype.lua) runs `voxtype record toggle`; 4.5 removed that file and toggles the configured
-- backend from default/hypr/bindings/dictation.lua (`omarchy-dictation toggle`, Alt-Space). The key follows both: where `omarchy-default-dictation` names a backend (4.5)
-- it runs `omarchy-dictation toggle`, else (4.0.6, or 4.5 with no backend chosen) `voxtype record toggle`. Its push-to-talk on plain F9 is not
-- bound, the function keys stay the applications'. The key exists only where voxtype is installed when this file is read
-- (Omarchy's voxtype install and removal both read the configuration again: `hyprctl reload`), and never in a dev session (the
-- owner's voxtype daemon would type into the owner's session). The switch, keyboard.dictation of grassfield.json, is read when
-- the key is pressed, by the command the key starts (so it needs no reload when it changes, and nothing is read on the
-- compositor's thread): a regular file only, through `timeout` (a FIFO in its place never blocks it), matched on the key
-- `"dictation": true` (the contract names no other key dictation, and a JSON string cannot hold that text unescaped). While
-- voxtype is installed the key is Grassfield's even with the switch off; it then does nothing.
local function command_present(name)
  if type(io.popen) ~= "function" then return false end
  local ok, p = pcall(io.popen, "command -v " .. name .. " 2>/dev/null", "r")
  if not ok or not p then return false end
  local found = p:read("a") or ""
  p:close()
  return found ~= ""
end

local function settings_file()
  local dev = os.getenv("GRASSFIELD_CONFIG_HOME")
  if dev and dev ~= "" then return dev .. "/grassfield.json" end
  local xdg = os.getenv("XDG_CONFIG_HOME")
  local base = (xdg and xdg ~= "") and xdg or ((os.getenv("HOME") or "") .. "/.config")
  return base .. "/grassfield/grassfield.json"
end

if not dev_session and command_present("voxtype") then
  local file = settings_file()
  if not file:find("%c") then
    local q = "'" .. file:gsub("'", "'\\''") .. "'"
    bind("SUPER + CTRL + X", "Start or stop dictation", hl.dsp.exec_cmd("[ -f " .. q .. " ] && timeout 2 grep -Eq '\"dictation\"[[:space:]]*:[[:space:]]*true' -- "
      .. q .. " && { if command -v omarchy-dictation >/dev/null 2>&1 && omarchy-default-dictation >/dev/null 2>&1; then"
      .. " exec omarchy-dictation toggle; else exec voxtype record toggle; fi; }"))
  end
end

-- Apps
bind("SUPER + RETURN", "Terminal", hl.dsp.exec_cmd("xdg-terminal-exec"))

-- Shell surfaces (handled by grassfield-shell IPC targets)
bind("SUPER + SPACE", "Search", shell("search", "toggle"))
-- The clipboard history in Search (ADR-0034, docs/specs/clipboard.md CB-5): opens Search in its Clipboard view; again closes it.
bind("SUPER + CTRL + V", "Clipboard history", shell("search", "clipboard"))
-- Emoji & Symbols (macOS Control-Command-Space; ADR-0045 OC-3, docs/specs/clipboard.md ES-1): the panel at the pointer; again
-- closes it. The shell refuses it while the session is locked.
bind("SUPER + CTRL + SPACE", "Emoji & Symbols", shell("emoji", "toggle"))
-- Apps (the dedicated Apps / Launchpad media key; plain F4 stays with the applications, docs/specs/apps.md A11).
bind("XF86LaunchA", "Apps", shell("apps", "toggle"))
bind("CTRL + UP", "Overview", shell("overview", "toggle"))
bind("SUPER + CTRL + Q", "Lock screen", shell("lock", "lock"))
-- The lid switch is bound once, in system.lua (real session only): /usr/lib/grassfield/grassfield-lid calls `lock lid`.
bind("SUPER + N", "Notification Center", shell("notifications", "toggleCenter"))
-- The capture toolbar (macOS Shift-Command-5; ADR-0045 OC-1): a shell surface, so it opens in the nested session too, where it
-- runs no capture (shell/services/CaptureState.qml). Bound by keycode (digits need Shift on some layouts). The screenshot keys
-- and the stop key are system.lua's (real session only).
bind("SUPER + SHIFT + code:14", "Screenshot and recording options", shell("capture", "toggle"))
-- The numeric keypad's 5 does the same (<KP5>, keycode 84: KP_5 with NumLock on, KP_Begin without; a keycode is the same in
-- both states). hl.bind, not bind(): Settings > Keyboard lists the literal bind() lines, and this is the same shortcut.
hl.bind("SUPER + SHIFT + code:84", shell("capture", "toggle"), { description = "Screenshot and recording options" })
bind("SUPER + ALT + ESCAPE", "Force Quit Applications", shell("menubar", "panel forcequit ''"))

-- Keyboard access to the menu bar and the Dock (gate A1), like Ctrl+F2 / Ctrl+F3.
bind("CTRL + F2", "Focus the menu bar", shell("menubar", "open system ''"))
bind("CTRL + F3", "Focus the Dock", shell("dock", "keyboard"))
-- Show Desktop (macOS F11 / Command-F3): hides the windows of the Space and gives the desktop icons the keyboard; again, they return.
bind("SUPER + F3", "Show Desktop", shell("windows", "showDesktop"))
-- Screen zoom (macOS Option-Command-8, -= and --; GF-064). Bound by keycode (8, =, - keys) so it works on every layout.
bind("SUPER + ALT + code:17", "Turn screen zoom on or off", shell("zoom", "toggle"))
bind("SUPER + ALT + code:21", "Zoom in", shell("zoom", "zoomIn"), { repeating = true })
bind("SUPER + ALT + code:20", "Zoom out", shell("zoom", "zoomOut"), { repeating = true })
-- Turn Dock hiding on or off (macOS Option-Command-D).
bind("SUPER + ALT + D", "Turn Dock hiding on or off", shell("dock", "toggleAutohide"))
-- Stages (only does anything while Stages is on): bring the n-th recent stage forward, make the focused window a stage of its own.
for n = 1, 4 do
  bind("SUPER + ALT + " .. tostring(n), "Bring Stage " .. n .. " forward", shell("stages", "activate " .. tostring(n)))
end
bind("SUPER + ALT + S", "Move the window to a stage of its own", shell("stages", "newStage"))

-- Keyboard launch keys: each opens the user's default app, resolved at press time by grassfield-launch-key (desktop entries
-- and xdg-mime, no package names). Search is Spotlight. Keys with no target here stay unbound.
local launch_key = os.getenv("GRASSFIELD_LAUNCH_KEY") or "/usr/lib/grassfield/grassfield-launch-key"
local function launch(kind)
  return hl.dsp.exec_cmd("'" .. launch_key .. "' " .. kind)
end
bind("XF86Calculator", "Calculator", launch("calculator"), { locked = false })
bind("XF86Mail", "Mail", launch("mail"), { locked = false })
bind("XF86WWW", "Web browser", launch("web"), { locked = false })
bind("XF86HomePage", "Web browser", launch("web"), { locked = false })
bind("XF86Search", "Search", shell("search", "toggle"), { locked = false })
bind("XF86Explorer", "Files", launch("files"), { locked = false })
bind("XF86MyComputer", "Files", launch("files"), { locked = false })
bind("XF86Tools", "Grassfield Settings", launch("settings"), { locked = false })
bind("XF86AudioMedia", "Music", launch("music"), { locked = false })
-- Ctrl+Shift+Esc opens Activity Monitor from anywhere (Windows' Task Manager key; owner AQ6, ADR-0038 AM64).
bind("CTRL + SHIFT + ESCAPE", "Activity Monitor", launch("activity"), { locked = false })

-- Hardware keys: real volume/brightness changes plus the OSD (shell/osd).
bind("XF86AudioRaiseVolume", "Volume up", shell("volume", "up"), { repeating = true, locked = true })
bind("XF86AudioLowerVolume", "Volume down", shell("volume", "down"), { repeating = true, locked = true })
bind("XF86AudioMute", "Mute", shell("volume", "mute"), { locked = true })
bind("XF86MonBrightnessUp", "Brightness up", shell("brightness", "up"), { repeating = true, locked = true })
bind("XF86MonBrightnessDown", "Brightness down", shell("brightness", "down"), { repeating = true, locked = true })
bind("XF86KbdBrightnessUp", "Keyboard brightness up", shell("keyboard", "up"), { repeating = true, locked = true })
bind("XF86KbdBrightnessDown", "Keyboard brightness down", shell("keyboard", "down"), { repeating = true, locked = true })

-- Trackpad gestures (L2: verified by the owner on real hardware; nested sessions have no touchpad). Settings > Trackpad > More
-- Gestures turns each off (mouse-trackpad.lua, read by grassfield.input, which the session loads first; without it, all on).
local input = package.loaded["grassfield.input"]
local gestures = (type(input) == "table" and input.settings) and input.settings() or { gesture_spaces = true, gesture_overview = true, gesture_apps = true }
if gestures.gesture_spaces then
  hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
end
if gestures.gesture_overview then
  hl.gesture({ fingers = 3, direction = "up", action = function() hl.exec_cmd(qs_ipc .. " call overview open") end })
  hl.gesture({ fingers = 3, direction = "down", action = function() hl.exec_cmd(qs_ipc .. " call overview close") end })
end
-- Apps: pinch with the thumb and three fingers opens it, spreading them closes it (macOS 26, docs/specs/apps.md A11).
if gestures.gesture_apps then
  hl.gesture({ fingers = 4, direction = "pinchin", action = function() hl.exec_cmd(qs_ipc .. " call apps open") end })
  hl.gesture({ fingers = 4, direction = "pinchout", action = function() hl.exec_cmd(qs_ipc .. " call apps close") end })
end
