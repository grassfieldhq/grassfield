-- Which build of the compositor extension the session loads (ADR-0009 option 1 and option 3, "Amendment 2026-10-23";
-- audit GF-033). Reads small text files (Hyprland's version.h, the builds' stamps, this session's runtime note) and the
-- environment; session.lua writes the runtime note.
--
-- A plugin only hooks into the Hyprland build it was compiled for: Hyprland compares its own hash with the plugin's (the
-- commit and the Hypr library minors, PluginAPI.hpp __hyprland_api_get_client_hash). Each build has a stamp next to it
-- (<name>.abi, first line: that ABI string, written by the build itself; second line: `source <id>`, the Grassfield
-- version it was built from). The shell and the plugin of one release speak one protocol (ADR-0007), so a build is used
-- only when its source is the installed Grassfield version (the first line of /usr/src/grassfield-compositor/VERSION,
-- the same package as the packaged build, which needs the desktop of exactly its version). At the first parse of a
-- Hyprland instance the session loads the first build whose stamp is the ABI of the Hyprland that runs and that version:
--   1. the packaged one (/usr/lib/grassfield/grassfield-compositor.so, root's);
--   2. the one the user built with grassfield-compositor-rebuild ($XDG_CACHE_HOME/grassfield/compositor/<abi>/), only as
--      `grassfield-compositor-rebuild --vetted` vouches for it: Lua cannot look at owners, modes or symlinks, the script
--      checks every directory from the cache root down and both files (not symlinks, the user's, not writable by others).
-- None: no extension is loaded (degraded mode, gate C2); the shell tells the user, translated, with the Hyprland version
-- and the recovery. A config reload in the same Hyprland instance keeps the build loaded at its first parse (the runtime
-- note, even when a package update has replaced its files since): a Hyprland updated under the session is only
-- reconsidered at the next login.

local M = {}

M.packaged = "/usr/lib/grassfield/grassfield-compositor.so"
M.version_h = "/usr/include/hyprland/src/version.h"
M.source_version = "/usr/src/grassfield-compositor/VERSION"
M.rebuild = "/usr/lib/grassfield/grassfield-compositor-rebuild"

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function first_line(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local line = f:read("l")
  f:close()
  return line
end

local function exists(path)
  local f = io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

-- "0.15.0" -> "0.15", "1" -> "1": what follows the last dot goes (PluginAPI.hpp stripPatch).
function M.strip_patch(v)
  return v:match("^(.*)%.[^.]*$") or v
end

local function define(text, name)
  local v = text:match("#define%s+" .. name .. '%s+"([^"\n]*)"')
  if v == "" then return nil end
  return v
end

-- The ABI string of the Hyprland whose version.h text is `text`, or nil when a field is missing.
function M.abi(text)
  if type(text) ~= "string" then return nil end
  local commit = define(text, "GIT_COMMIT_HASH")
  local aq, hu, hg = define(text, "AQUAMARINE_VERSION"), define(text, "HYPRUTILS_VERSION"), define(text, "HYPRGRAPHICS_VERSION")
  local hc, hlg = define(text, "HYPRCURSOR_VERSION"), define(text, "HYPRLANG_VERSION")
  if not (commit and aq and hu and hg and hc and hlg) then return nil end
  return string.format("%s_aq_%s_hu_%s_hg_%s_hc_%s_hlg_%s", commit, M.strip_patch(aq), M.strip_patch(hu), M.strip_patch(hg),
    M.strip_patch(hc), M.strip_patch(hlg))
end

-- The commit of the Hyprland that runs: HYPRLAND_INSTANCE_SIGNATURE starts with it (<commit>_<time>_<random>), or nil.
function M.running_commit(signature)
  if type(signature) ~= "string" then return nil end
  local commit = signature:match("^(%x+)_")
  if commit and #commit >= 7 then return commit end
  return nil
end

-- The user's build path for an ABI (grassfield-compositor-rebuild installs there; --vetted checks it).
function M.user_build(abi, getenv)
  local g = getenv or os.getenv
  local base = g("XDG_CACHE_HOME")
  if not base or base == "" then
    local home = g("HOME")
    if not home or home == "" then return nil end
    base = home .. "/.cache"
  end
  return base .. "/grassfield/compositor/" .. abi .. "/grassfield-compositor.so"
end

-- The ABI directory of a user build path (any ABI), or nil when `path` has another shape.
function M.user_build_abi(path, getenv)
  local any = M.user_build("ABI", getenv)
  if type(path) ~= "string" or not any then return nil end
  local prefix = any:sub(1, #any - #"ABI/grassfield-compositor.so")
  if path:sub(1, #prefix) ~= prefix then return nil end
  return path:sub(#prefix + 1):match("^(%w[%w%._%-]*)/grassfield%-compositor%.so$")
end

-- The runtime note of this Hyprland instance (the build its first parse loaded), in the user's runtime directory.
function M.note_path(getenv)
  local g = getenv or os.getenv
  local dir, sig = g("XDG_RUNTIME_DIR"), g("HYPRLAND_INSTANCE_SIGNATURE")
  if not dir or dir == "" or type(sig) ~= "string" then return nil end
  local id = sig:gsub("[^%w_]", "")
  if id == "" then return nil end
  return dir .. "/grassfield-compositor-" .. id
end

-- The stamp of a build: the first line of <path without .so>.abi, or nil.
function M.stamp(path, line)
  return (line or first_line)((path:gsub("%.so$", ".abi")))
end

-- The Grassfield version a build was made from: its stamp's second line, `source <id>`, or nil.
function M.stamp_source(path, read_text)
  local text = (read_text or read)((path:gsub("%.so$", ".abi")))
  if type(text) ~= "string" then return nil end
  return text:match("^[^\n]*\nsource ([^\n]+)")
end

-- The installed Grassfield version (the first line of the sources' VERSION, written by the PKGBUILD), or nil.
function M.installed_source(read_text)
  local text = (read_text or read)(M.source_version)
  if type(text) ~= "string" then return nil end
  local v = text:match("^([^\n]*)"):gsub("[^%w%._%+:~%-]", "")
  if v == "" then return nil end
  return v
end

-- The check runs while Hyprland parses its config, on its main thread: bounded (coreutils timeout, then a kill one second
-- later). A check that times out, fails or cannot run vouches for nothing.
M.timeout = "/usr/bin/timeout"
M.vetted_seconds = 5

-- What grassfield-compositor-rebuild --vetted vouches for (the user's build for `abi`, default the installed Hyprland's),
-- or nil (and "timeout" when the check was cut off rather than refused). `abi` comes from M.user_build_abi (letters, digits, dots, dashes, underscores): nothing for the shell to expand.
-- `loaded` (with an ABI): the build this Hyprland instance loaded at its first parse, kept on a reload until the next
-- login: every check but the source version (a package update in the session may have moved it on).
function M.vetted(abi, loaded)
  if not exists(M.rebuild) or not exists(M.timeout) or type(io.popen) ~= "function" then return nil end
  if abi and not abi:match("^%w[%w%._%-]*$") then return nil end
  local command = string.format("%s -k 1 %d %s --vetted%s%s 2>/dev/null", M.timeout, M.vetted_seconds, M.rebuild,
    abi and (" '" .. abi .. "'") or "", (abi and loaded) and " --loaded" or "")
  local ok, p = pcall(io.popen, command)
  if not ok or not p then return nil end
  local line = p:read("l")
  -- Lua 5.4+: true only for exit status 0 (a timeout exits 124, 137 after the kill). A check that was cut off says so
  -- (second value "timeout"): it vouches for nothing, and it refused nothing either (M.choose, on a reload).
  local done, _, code = p:close()
  if not done then
    if code == 124 or code == 137 then return nil, "timeout" end
    return nil
  end
  return line
end

-- Hyprland --verify-config runs this config too, with the caller's environment (a running instance's signature
-- included): in verify mode the loader writes nothing. `read` (tests) returns the process command line.
function M.verifying(read_cmdline)
  local cmdline = (read_cmdline or function() return read("/proc/self/cmdline") end)()
  if type(cmdline) ~= "string" then return false end
  for arg in cmdline:gmatch("[^\0]+") do
    if arg == "--verify-config" then return true end
  end
  return false
end

-- The build to load, and why: path and "packaged" | "user" | "kept" (a config reload keeps the build of the first parse);
-- or nil and "no-match" (no build for this Hyprland and this Grassfield version: degraded mode, the shell's notice),
-- "updated" (the running Hyprland is not the installed one: nothing until the next login), "none" (no extension
-- installed).
-- `env` (tests): { read = fn(path) -> text|nil, line = fn(path) -> first line|nil, exists = fn(path) -> bool,
-- getenv = fn(name) -> string|nil, vetted = fn(abi|nil, loaded|nil) -> path|nil[, "timeout"] }.
function M.choose(env)
  env = env or {}
  local present = env.exists or exists
  local getenv = env.getenv or os.getenv
  local line = env.line or first_line
  local vetted = env.vetted or M.vetted
  -- A reload in the same Hyprland instance keeps the build of its first parse: Hyprland keeps a plugin that is loaded
  -- from a path the list still names and unloads the others, and a package update in the same transaction may have
  -- replaced the files since (the stamps then name the new Hyprland). The note is a hint, never trusted more: the packaged
  -- path (root's), or a user build of the commit that runs that --vetted still vouches for.
  local running = M.running_commit(getenv("HYPRLAND_INSTANCE_SIGNATURE"))
  local note = M.note_path(getenv)
  local kept = note and line(note)
  if kept and kept == M.packaged and present(kept) then return kept, "kept" end
  local kept_abi = kept and running and M.user_build_abi(kept, getenv)
  if kept_abi and kept_abi:sub(1, #running + 1) == running .. "_" then
    -- A check that was cut off (a heavy package transaction is exactly when the reload comes) is not a refusal: the
    -- build is already loaded, and naming no plugin would make Hyprland unload it mid-session.
    local path, why = vetted(kept_abi, true)
    if path == kept or (path == nil and why == "timeout") then return kept, "kept" end
  end
  local read_text = env.read or read
  local installed = M.abi(read_text(M.version_h))
  if not installed then return nil, present(M.packaged) and "no-match" or "none" end
  if running and installed:sub(1, #running + 1) ~= running .. "_" then return nil, "updated" end
  local source = M.installed_source(read_text)
  if present(M.packaged) and M.stamp(M.packaged, line) == installed and source
      and M.stamp_source(M.packaged, read_text) == source then
    return M.packaged, "packaged"
  end
  local user = M.user_build(installed, getenv)
  if user and vetted() == user then return user, "user" end
  return nil, present(M.packaged) and "no-match" or "none"
end

-- After a successful load at the first parse: the runtime note of this instance names the build.
function M.remember(path, getenv)
  local note = M.note_path(getenv)
  if not note then return end
  local f = io.open(note, "w")
  if not f then return end
  f:write(path, "\n")
  f:close()
end

return M
