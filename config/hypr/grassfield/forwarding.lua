-- Keys forwarded to the focused window (macOS model, GF-024): word navigation on Alt+arrows, Command+number and Command+Up
-- on Super. Kept out of bindings.lua on purpose: the Settings Keyboard page parses that file's literal `bind("KEYS", "Description"`
-- lines and every description there needs an entry in apps/settings/qml/Bindings.js and the fr catalog (open item: list
-- these keys there). Loaded by core.lua for the real and the nested session.

local function bind(keys, description, dispatcher, opts)
  opts = opts or {}
  opts.description = description
  hl.bind(keys, dispatcher, opts)
end

-- Hyprland sends the chord to the focused surface itself (a window or a layer-shell panel such as Search) with explicit
-- modifiers, so the physically held Alt or Super does not merge into it, and the chord does not run through the binds again
-- (CTRL+LEFT in bindings.lua is a Spaces bind). The down/up split
-- follows Omarchy's universal clipboard (default/hypr/bindings/clipboard.lua): one send_shortcut can leave synthetic key
-- state stuck (https://github.com/hyprwm/Hyprland/discussions/14099).
local function forward(mods, key)
  return function()
    hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))
    hl.timer(function()
      hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" }))
    end, { timeout = 50, type = "oneshot" })
  end
end

-- Terminals (Omarchy's definition, default/hypr/apps/terminals.lua) keep Alt+arrows: tmux, vim and readline bind them.
local TERMINAL_CLASSES = { "alacritty", "kitty", "com.mitchellh.ghostty", "foot", "org.codeberg.dnkl.foot", "wezterm", "org.wezfurlong.wezterm" }
local function terminal_focused()
  local window = hl.get_active_window()
  local class = window and (window.class or ""):lower() or ""
  for _, name in ipairs(TERMINAL_CLASSES) do
    if class == name then
      return true
    end
  end
  return class:find("^org%.omarchy%.") ~= nil or class:find("^tui%.") ~= nil
end

-- Word navigation: on macOS Option+arrows move by word in every text field and Ctrl+arrows switch Spaces. Toolkits on
-- Linux use Ctrl for words, so Alt+Left/Right (with Shift: select, with Backspace/Delete: delete) reach the focused window
-- as the Ctrl chord they understand. Browsers lose Alt+Left/Right for history: Super+[ and Super+] send it (macOS Cmd+[ ]).
local function word_key(keys, description, mods, key)
  local to_ctrl = forward(mods, key)
  local unchanged = forward(keys:find("SHIFT", 1, true) and "ALT SHIFT" or "ALT", key)
  bind(keys, description, function()
    if terminal_focused() then
      unchanged()
    else
      to_ctrl()
    end
  end, { repeating = true })
end
word_key("ALT + LEFT", "Previous word", "CTRL", "Left")
word_key("ALT + RIGHT", "Next word", "CTRL", "Right")
word_key("ALT + SHIFT + LEFT", "Select to the previous word", "CTRL SHIFT", "Left")
word_key("ALT + SHIFT + RIGHT", "Select to the next word", "CTRL SHIFT", "Right")
word_key("ALT + BACKSPACE", "Delete the previous word", "CTRL", "BackSpace")
word_key("ALT + DELETE", "Delete the next word", "CTRL", "Delete")
bind("SUPER + bracketleft", "Back", forward("ALT", "Left"))
bind("SUPER + bracketright", "Forward", forward("ALT", "Right"))

-- Command+number and Command+Up: Ctrl+1..9 and Ctrl+Up are Spaces and Overview here, so the keys an application
-- advertises with Ctrl (Files views Ctrl+1..4, Preview Zoom to Fit Ctrl+9, Files Enclosing Folder Ctrl+Up) are sent by
-- Super+1..9 and Super+Up. Bound by keycode, so they work on every layout.
for number = 1, 9 do
  bind("SUPER + code:" .. tostring(number + 9), "Command+" .. number .. " in the application", forward("CTRL", "code:" .. tostring(number + 9)))
end

-- Command+arrows, the macOS text model: Left/Right go to the line start/end, Up/Down to the document start/end, with Shift
-- they select. Terminals receive the plain keys too. Grassfield Files keeps Finder's meaning: Command+Up is Enclosing Folder
-- (Ctrl+Up there) and Command+Down is Open (Ctrl+Down). Nothing else binds these chords (the tiling binds all carry Ctrl).
local function files_focused()
  local window = hl.get_active_window()
  return window ~= nil and (window.class or ""):lower() == "org.grassfield.files"
end
local function vertical(mods, key_in_files, key_elsewhere)
  local in_files, elsewhere = forward("CTRL", key_in_files), forward(mods, key_elsewhere)
  return function()
    if files_focused() then
      in_files()
    else
      elsewhere()
    end
  end
end
bind("SUPER + LEFT", "Beginning of the line", forward("", "Home"))
bind("SUPER + RIGHT", "End of the line", forward("", "End"))
bind("SUPER + SHIFT + LEFT", "Select to the beginning of the line", forward("SHIFT", "Home"))
bind("SUPER + SHIFT + RIGHT", "Select to the end of the line", forward("SHIFT", "End"))
bind("SUPER + UP", "Beginning of the document", vertical("CTRL", "Up", "Home"))
bind("SUPER + DOWN", "End of the document", vertical("CTRL", "Down", "End"))
bind("SUPER + SHIFT + UP", "Select to the beginning of the document", forward("CTRL SHIFT", "Home"))
bind("SUPER + SHIFT + DOWN", "Select to the end of the document", forward("CTRL SHIFT", "End"))

-- Command+Backspace deletes to the start of the line: select to it (Shift+Home), then Backspace, as two chords. The second
-- goes right after the first one's key-up (50 ms, forward above): a longer wait only lets typed keys land between the two.
bind("SUPER + BACKSPACE", "Delete to the beginning of the line", function()
  forward("SHIFT", "Home")()
  hl.timer(forward("", "BackSpace"), { timeout = 60, type = "oneshot" })
end)
