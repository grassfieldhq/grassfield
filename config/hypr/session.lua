-- Grassfield Desktop session (ADR-0001). Installed to /usr/share/grassfield/hypr/session.lua and started by
-- /usr/share/wayland-sessions/grassfield.desktop through uwsm. The Omarchy session stays untouched.

-- The modules come from this file's own directory, never from the environment: a stray GRASSFIELD_CONFIG_DIR (a developer
-- setting leaked into the session) would have loaded another bindings.lua and system.lua, or none, and with them the lock
-- key and the lid lock (follow-up of the re-review of bf9e280). --verify-config runs on a copy pass that copy's path.
local self_path = debug and debug.getinfo and debug.getinfo(1, "S").source or ""
local config_dir = self_path:match("^@(.+)/[^/]+$") or "/usr/share/grassfield/hypr"
package.path = config_dir .. "/?.lua;" .. package.path

-- ADR-0001 amendment 2026-10-29: Hyprland's file watcher is off in the real session. A package upgrade unlinks and
-- recreates the installed files; the watcher reloaded in that window and failed ("cannot open ...session.lua", an error
-- the files coming back do not clear, or Grassfield's bindings and plugin dropped for a missing module). The installed
-- files are read again only at the next login or at an explicit reload (the shell's, grassfield-lid's, Omarchy's tools'
-- and Omarchy's own pacman hook after an omarchy-settings transaction). Set first: a reload resets every option before
-- it runs this file, so a parse that stops at a missing module still leaves the watcher off. dev.lua keeps the watcher.
hl.config({ misc = { disable_autoreload = true } })

-- A parse starts with none of Grassfield's modules loaded, so each one runs again on a reload (should Hyprland keep
-- package.loaded) and a module loaded before core.lua stays loaded for the rest of this parse: bindings.lua reads the
-- Trackpad gestures from grassfield.input, which omarchy.lua loads.
for module in pairs(package.loaded) do
  if module == "grassfield" or module:sub(1, 11) == "grassfield." then
    package.loaded[module] = nil
  end
end

-- Hardware/env from Omarchy (read-only). Grassfield defaults apply if it fails.
local omarchy = require("grassfield.omarchy")
if not omarchy.ok then
  print("grassfield: Omarchy include skipped: " .. tostring(omarchy.reason))
end
-- GF-066: the pointer defaults normally went in before the user's input.lua (omarchy.lua); without that include they apply here.
-- Optional, like every module before core.lua: a failure is logged and costs the pointer defaults and the Settings
-- choices, never the bindings, the lock key or the lid handling below.
if not omarchy.input_applied then
  local input_ok, input_err = pcall(require, "grassfield.input")
  if not input_ok then
    print("grassfield: input: " .. tostring(input_err))
  end
end
if not omarchy.ok or not omarchy.monitors then
  hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
end
-- ADR-0031: the displays set in Settings > Displays, after the user's monitors.lua (a display Settings never touched keeps
-- the user's rule). A failure costs only these rules.
local displays_ok, displays_err = pcall(require, "grassfield.displays")
if not displays_ok then
  print("grassfield: displays: " .. tostring(displays_err))
end
-- ADR-0001: a failed include is announced once (details in the journal, lines start with "grassfield: Omarchy include").
if not omarchy.ok or #omarchy.problems > 0 then
  hl.on("hyprland.start", function()
    hl.exec_cmd("sleep 8; notify-send -a Grassfield -u critical Grassfield "
      .. "'Some Omarchy settings (keyboard, monitors, environment) could not be loaded. "
      .. "See: journalctl --user -b | grep grassfield:'")
  end)
end
-- GF-032: the Omarchy shell must never start inside this session (updates, theme and font changes try to start it).
-- The stand-ins' directory is fixed: a stray GRASSFIELD_SHIM_DIR would have let Omarchy's sleep-lock call Omarchy's own
-- omarchy-shell instead of the stand-in that asks grassfield-shell to lock (the sleep-lock fallback, D-12).
-- ADR-0035 D-3: Hyprland's "not responding" dialog goes through Grassfield's stand-in (session-bin/hyprland-dialog).
omarchy.guard_path("/usr/lib/grassfield/omarchy-shims", "/usr/lib/grassfield/session-bin")

hl.env("XDG_SESSION_DESKTOP", "Grassfield")
-- Omarchy's envs.lua (above) sets XDG_CURRENT_DESKTOP=Hyprland; uwsm finalize exports the compositor's value. Grassfield first,
-- Hyprland kept: the colon list is read item by item (the portals' UseIn=Hyprland, xdg-desktop-portal's
-- <item>-portals.conf, OnlyShowIn/NotShowIn, Qt, GTK and Chromium take the first item they know), and the frontend then reads
-- the user's grassfield-portals.conf (a link made by grassfield-portal-config) before Omarchy 4.5.0's hyprland-portals.conf,
-- which Grassfield never touches. Only here: the Omarchy session keeps "Hyprland", and the nested dev session its own value.
hl.env("XDG_CURRENT_DESKTOP", "Grassfield:Hyprland")
hl.env("GRASSFIELD_SESSION", "1")

-- ADR-0054 (amends Q3 of ADR-0035): Qt apps get Grassfield's Open and Save panels and keep the GTK look. Omarchy's envs.lua
-- (above) set QT_QPA_PLATFORMTHEME=gtk3; here the "xdgdesktopportal" theme replaces it when the "grassfield" platform-theme
-- plugin is installed for the Qt that runs, and gtk3 stays otherwise (the reason goes to the journal). LibreOffice uses its Qt 6
-- plugin in this session only (its GTK 3 plugin never calls the portal), through an environment variable: no file of the user's
-- LibreOffice profile is read or written.
do
  local ok, qttheme = pcall(require, "grassfield.qttheme")
  if ok then
    local chosen, theme, why = pcall(qttheme.choose)
    if chosen and theme == "xdgdesktopportal" then
      hl.env("QT_QPA_PLATFORMTHEME", theme)
    elseif chosen then
      print("grassfield: Qt platform theme: gtk3 kept: " .. tostring(why))
    else
      print("grassfield: Qt platform theme: gtk3 kept: " .. tostring(theme))
    end
    local lo = select(2, pcall(qttheme.libreoffice))
    if lo == "qt6" then
      hl.env("SAL_USE_VCLPLUGIN", lo)
    end
  else
    print("grassfield: Qt platform theme: gtk3 kept: module failed: " .. tostring(qttheme))
  end
end

require("grassfield.core")
require("grassfield.autostart")
require("grassfield.system")

-- Hyprland would write cursor-theme/cursor-size into the owner's dconf (org.gnome.desktop.interface), a database shared
-- with the Omarchy session. Never touch it from this session; the theme reaches clients through XCURSOR_* (cursor.lua).
-- GTK applications keep whatever theme dconf already holds.
hl.config({ cursor = { sync_gsettings_theme = false } })

-- Optional compositor extension (ADR-0009, "Amendment 2026-10-23"). Loaded at parse time (Hyprland applies the plugin
-- list right after parsing). grassfield.compositor picks the build made for the Hyprland that runs: the packaged one, else
-- the one the user built (grassfield-compositor-rebuild, vouched for by its --vetted check). With none, nothing is loaded:
-- the shell runs in degraded mode (§5.6, gate C2) and tells the user, translated, with the Hyprland version and the
-- recovery (it builds the extension itself when the user turned on Settings windows.rebuildExtension). A config reload in
-- the same Hyprland keeps the build its first parse loaded.
local plugin, why = nil, "no choice"
local chose, compositor = pcall(require, "grassfield.compositor")
if chose then
  local ok, path, reason = pcall(compositor.choose)
  if ok then
    plugin, why = path, reason
  else
    why = "choice failed: " .. tostring(path)
  end
else
  why = "module failed: " .. tostring(compositor)
end
if why:find("failed", 1, true) then
  -- A loader defect must not cost the extension: the packaged build checks Hyprland's hash itself and refuses another
  -- build with a notice.
  print("grassfield: compositor extension: " .. why)
  plugin = "/usr/lib/grassfield/grassfield-compositor.so"
end
local f = plugin and io.open(plugin, "r")
if f then
  f:close()
  local ok, err = pcall(hl.plugin.load, plugin)
  -- The runtime note is this instance's: never written by Hyprland --verify-config (`just check`), which inherits the
  -- signature of the instance it was started from.
  local verifying = chose and select(2, pcall(compositor.verifying)) == true
  if ok and chose and why ~= "kept" and not verifying then
    pcall(compositor.remember, plugin)
  elseif not ok then
    print("grassfield: compositor extension not loaded: " .. tostring(err))
  end
elseif why == "no-match" then
  print("grassfield: no compositor extension built for this Hyprland: degraded mode (grassfield-compositor-rebuild --check)")
elseif why == "updated" then
  print("grassfield: Hyprland was updated under this session: the compositor extension is reconsidered at the next login")
end
