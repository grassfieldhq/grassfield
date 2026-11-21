-- File probes without a fork (CIO-03, CIO-10). The config runs on Hyprland's main thread at every parse; a shell started there
-- (`[ -f ] && timeout head`, `find | sort`, the loader's --vetted check) stalls the whole session for its run. The compositor
-- plugin answers the same questions in-process (hl.plugin.grassfield.file_identity, read_file, list_files: lstat, a
-- non-blocking regular-file read, a plain listing; compositor/src/core/FileProbe.cpp). It is loaded from the second parse of a
-- login on (a reload: the shell's, the display trial's, Omarchy's pacman hook): those parses fork nothing. The first parse,
-- or a session without the plugin, uses each caller's own fallback. `api` (tests) replaces the plugin's table.

local M = {}

local function plugin_fn(name, api)
  if api then return api[name] end
  local ok, fn = pcall(function() return hl.plugin.grassfield[name] end)
  if ok and type(fn) == "function" then return fn end
  return nil
end

-- true when the plugin's probes answer (callers then fork nothing).
function M.available(api)
  return plugin_fn("read_file", api) ~= nil and plugin_fn("list_files", api) ~= nil and plugin_fn("file_identity", api) ~= nil
end

-- The probe's answer, or `unavailable` (the second value true) when the plugin cannot answer.
local function ask(name, api, ...)
  local fn = plugin_fn(name, api)
  if not fn then return nil, true end
  local ok, value = pcall(fn, ...)
  if not ok then return nil, true end
  return value, false
end

-- The contents of a regular file (at most `max` bytes): text|nil, unavailable.
function M.read_file(path, max, api)
  return ask("read_file", api, path, max)
end

-- The sorted names of the plain regular files of `dir` ending in `suffix`: {names}|nil, unavailable.
function M.list_files(dir, suffix, api)
  local names, unavailable = ask("list_files", api, dir, suffix)
  if unavailable then return nil, true end
  return type(names) == "table" and names or {}, false
end

-- lstat identity of `path`: string|nil, unavailable.
function M.identity(path, api)
  return ask("file_identity", api, path)
end

-- An executable found on PATH, by Lua alone (it replaced `command -v` in a shell): the first PATH entry holding a readable,
-- non-empty file of that name. A directory of that name does not count (its read fails).
function M.on_path(name, getenv)
  if type(name) ~= "string" or not name:match("^[%w._+-]+$") then return false end
  local path = (getenv or os.getenv)("PATH") or ""
  for dir in path:gmatch("[^:]+") do
    if dir:sub(1, 1) == "/" then
      local f = io.open(dir .. "/" .. name, "rb")
      if f then
        local byte = f:read(1)
        f:close()
        if byte ~= nil then return true end
      end
    end
  end
  return false
end

return M
