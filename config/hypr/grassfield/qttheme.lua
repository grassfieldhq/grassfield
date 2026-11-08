-- The Qt platform theme of the Grassfield session (ADR-0054, which amends owner decision Q3 of ADR-0035), and LibreOffice's
-- toolkit plugin. Pure decisions over small text files; session.lua applies them with hl.env.
--
-- Omarchy's environment sets QT_QPA_PLATFORMTHEME=gtk3: Qt apps get the GTK look, and GTK 3's own file chooser. This session
-- sets "xdgdesktopportal" instead, which sends QFileDialog to the desktop portal (Grassfield's Open and Save panels), and
-- ships a platform-theme plugin keyed "grassfield" (the session's first XDG_CURRENT_DESKTOP item, lower-cased) that gives
-- Qt's xdgdesktopportal theme the gtk3 theme as its base, so the look is unchanged.
-- The plugin is built on Qt's private API (QPA) and is only known to work with the Qt minor release it was built against
-- (packaging/qt-platform-theme/CMakeLists.txt writes that release next to it). Anything else, or no plugin at all, keeps
-- Omarchy's "gtk3": Qt apps look as before and keep GTK 3's chooser, and the reason is printed once (journal).

local M = {}

M.plugin = "/usr/lib/qt6/plugins/platformthemes/libgrassfield-qt-theme.so"
M.stamp = "/usr/share/grassfield/qt-platform-theme/qt-version"
M.qt_version_file = "/usr/lib/cmake/Qt6Core/Qt6CoreConfigVersionImpl.cmake"
M.min_size = 4096
M.libreoffice_plugin = "/usr/lib/libreoffice/program/libvclplug_qt6lo.so"

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function exists(path)
  local f = io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

-- "6.12" from Qt's own file (`set(PACKAGE_VERSION "6.12.0")`) or from the plugin's stamp ("6.12.0"): the major.minor pair.
function M.minor(text)
  if type(text) ~= "string" then return nil end
  local v = text:match('PACKAGE_VERSION%s+"([%d%.]+)"') or text:match("^%s*([%d%.]+)%s*$")
  if not v then return nil end
  local major, minor = v:match("^(%d+)%.(%d+)")
  if not major then return nil end
  return major .. "." .. minor
end

-- choose(read_text, file_exists) -> theme, reason. reason is nil when the plugin is used.
function M.choose(read_text, file_exists)
  read_text = read_text or read
  file_exists = file_exists or exists
  if not file_exists(M.plugin) then return "gtk3", "no platform-theme plugin installed (" .. M.plugin .. ")" end
  -- A file that is not a whole shared object (a truncated or empty download) would make Qt fall back to Fusion for every app.
  local binary = read_text(M.plugin)
  if type(binary) ~= "string" or binary:sub(1, 4) ~= "\127ELF" or #binary < M.min_size then
    return "gtk3", "the platform-theme plugin is not a complete shared object (" .. M.plugin .. ")"
  end
  local built = M.minor(read_text(M.stamp))
  if not built then return "gtk3", "the plugin's Qt release stamp is missing or unreadable (" .. M.stamp .. ")" end
  local running = M.minor(read_text(M.qt_version_file))
  if not running then return "gtk3", "the installed Qt release cannot be read (" .. M.qt_version_file .. ")" end
  if built ~= running then
    return "gtk3", "the plugin was built for Qt " .. built .. " and Qt " .. running .. " is installed (rebuild grassfield-desktop)"
  end
  return "xdgdesktopportal", nil
end

-- LibreOffice's Qt 6 VCL plugin, only where it is installed (SAL_USE_VCLPLUGIN names a plugin LibreOffice then must find). The
-- variable itself is set by packaging/uwsm/env-grassfield (every launch path sees it); this function is the same test in Lua.
function M.libreoffice(file_exists)
  file_exists = file_exists or exists
  if file_exists(M.libreoffice_plugin) then return "qt6" end
  return nil
end

return M
