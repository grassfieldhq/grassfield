-- Screen-share protection (GF-AUDIT-001 SEC-01 / GF-028): windows Omarchy hides from screen sharing and screencopy
-- (`no_screen_share`: 1Password, Bitwarden and its browser extension window, and whatever Omarchy adds) stay hidden in
-- the Grassfield session, which does not load Omarchy's window rules.
--
-- Omarchy's own rule files (default/hypr/apps/*.lua) are read, not copied: each file is evaluated as data in an empty
-- environment where `o.window(match, rules)` records the rules with `no_screen_share = true`, with their match, and
-- every other `o.*` or `hl.*` call does nothing. Nothing else of those files applies (Omarchy's tiling, opacity and tag
-- rules would fight Grassfield's look), and no other code can run: `os`, `io`, `require`, `load` and the rest of the
-- standard library are absent, so a file that uses them stops there (the protection rules it declared before still
-- count; the stop is printed to Hyprland's log). A new protected app in a later Omarchy release
-- is picked up without a Grassfield change; tests/security/screenshare_rules.sh compares both sets.
--
-- The matches Omarchy 4.5.0 ships are always applied as well (duplicates dropped), so a file that stops early, moves or
-- disappears never leaves 1Password or Bitwarden unprotected (fail safe). They also are the clipboard history's list of
-- password managers (shell/services/ClipboardLogic.js PROTECTED_CLASSES, the same strings: tests/unit/tst_clipboard.qml),
-- and tests/security/screenshare_rules.sh fails when the installed Omarchy protects a window they do not name (R7-SEC-03).
-- Loaded by core.lua in both the real and the
-- nested session. Returns { source = "omarchy"|"builtin" (nothing read from Omarchy), matches = { <match table>... },
-- skipped = { "<file>: <error>"... }, layers = { <namespace regex>... } (the shell's sheets, below) }.

local M = { source = "omarchy", matches = {}, skipped = {} }

local omarchy_path = os.getenv("OMARCHY_PATH")
if not omarchy_path or omarchy_path == "" then
  omarchy_path = "/usr/share/omarchy"
end
local apps_dir = omarchy_path .. "/default/hypr/apps"

-- Omarchy 4.5.0 default/hypr/apps/1password.lua and bitwarden.lua, always applied: 1Password before and after 8.12 (app id
-- com.onepassword.OnePassword), Bitwarden, and its browser extension's window in any browser and profile. Each covers the
-- 4.0.6 match it replaces (^(1[p|P]assword)$, ^(Bitwarden)$, chrome-nngceckbapebfimnlniiiahkandclblb-Default).
local BUILTIN = {
  { class = "^(1[pP]assword|com\\.onepassword\\.OnePassword)$" },
  { class = "^([bB]itwarden)$" },
  { class = ".*nngceckbapebfimnlniiiahkandclblb.*" },
}

-- Copy of a match: a string is a class regex (Omarchy's o.window), a table keeps its plain string/number/boolean fields.
local function copy_match(match)
  if type(match) == "string" then
    return { class = match }
  end
  if type(match) ~= "table" then
    return nil
  end
  local out, any = {}, false
  for key, value in pairs(match) do
    local kind = type(value)
    if type(key) == "string" and (kind == "string" or kind == "number" or kind == "boolean") then
      out[key] = value
      any = true
    end
  end
  return any and out or nil
end

-- Stable text of a match, to drop duplicates.
local function key_of(match)
  local keys = {}
  for key in pairs(match) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = key .. "=" .. tostring(match[key])
  end
  return table.concat(parts, ";")
end

local seen = {}
local function add(match)
  local k = key_of(match)
  if not seen[k] then
    seen[k] = true
    M.matches[#M.matches + 1] = match
  end
end

-- Absorbs every other Omarchy helper and `hl` call of those files (layer rules, tags, binds): indexing or calling it
-- returns itself and does nothing, so a file that also declares other rules is read to its end.
local sink = {}
setmetatable(sink, {
  __index = function()
    return sink
  end,
  __call = function()
    return sink
  end,
})

-- Evaluate one Omarchy rule file as data (see the header).
local function read_rules(path)
  local o = setmetatable({
    window = function(match, rules)
      if type(rules) == "table" and rules.no_screen_share == true then
        local m = copy_match(match)
        if m then
          add(m)
        end
      end
    end,
  }, { __index = function()
    return sink
  end })
  local env = { o = o, hl = sink }
  local chunk, err = loadfile(path, "t", env)
  if not chunk then
    M.skipped[#M.skipped + 1] = path .. ": " .. tostring(err)
    return
  end
  local ok, run_err = pcall(chunk)
  if not ok then
    M.skipped[#M.skipped + 1] = path .. ": " .. tostring(run_err)
  end
end

-- File names in sorted order (same listing as Omarchy's require_all.lua); plain names only.
local function rule_files(dir)
  local files = {}
  local quoted = "'" .. dir:gsub("'", "'\\''") .. "'"
  local handle = io.popen("find " .. quoted .. " -maxdepth 1 -type f -name '*.lua' -printf '%f\\n' 2>/dev/null | sort")
  if handle then
    for name in handle:lines() do
      if name:match("^[%w._-]+%.lua$") then
        files[#files + 1] = dir .. "/" .. name
      end
    end
    handle:close()
  end
  return files
end

for _, path in ipairs(rule_files(apps_dir)) do
  read_rules(path)
end

if #M.matches == 0 then
  M.source = "builtin"
  print("grassfield: no screen-share rule read from " .. apps_dir .. "; the built-in password-manager rules still apply")
end
for _, match in ipairs(BUILTIN) do
  add(copy_match(match))
end
for _, skipped in ipairs(M.skipped) do
  print("grassfield: screen-share rules: stopped reading " .. skipped)
end

for i, match in ipairs(M.matches) do
  hl.window_rule({ name = "gf-no-screen-share-" .. i, match = match, no_screen_share = true })
end

-- The shell's password sheets and its authorization sheet (ADR-0035 D-9, step 9b): their layer surfaces are hidden from
-- screen sharing and screencopy (Hyprland 0.56.2 accepts no_screen_share for layers,
-- src/desktop/rule/layerRule/LayerRuleEffectContainer.cpp:23, and draws such a layer black in a capture). Both layers cover
-- the output while a sheet is up (the dimmed backdrop), so a capture is black meanwhile. Fixed names, nothing read.
M.layers = { "^grassfield-secret$", "^grassfield-polkit$" }
hl.layer_rule({ name = "gf-no-screen-share-secret", match = { namespace = M.layers[1] }, no_screen_share = true })
hl.layer_rule({ name = "gf-no-screen-share-polkit", match = { namespace = M.layers[2] }, no_screen_share = true })

return M
