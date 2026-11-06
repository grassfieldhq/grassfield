-- Placement (macOS model): an application's first window opens large and centred, never smaller than the application's
-- usual default, and a window that arrives with a size of its own keeps it.
--
-- Every new window floats (windows.lua) and Hyprland gives a floating window the size its client committed. A browser
-- that has no stored geometry commits a small one, so it opened as a small window.
--   * Hyprland already centres a new floating window (over its parent for a dialog); no rule overrides that.
--   * The first window of a browser that is smaller than the default below is grown to it. Size is only ever raised, so
--     a size the browser restores from its own state is kept. Popups (empty title), dialogs and any later window of an
--     application (a sibling already mapped), Picture-in-Picture and pinned or xdg-tagged windows are skipped.
-- Other applications decide their own size (Grassfield apps, terminals, dialogs, panels).
--   * Every new floating window is then fitted (macOS model): its title bar opens below the menu bar and the window on its
--     screen, made smaller when it is larger than the free area. See `fit`.

-- Fraction of the monitor's usable area. The window never covers the whole screen.
local DEFAULT_WIDTH = 0.72
local DEFAULT_HEIGHT = 0.82

-- Window classes (lower case) whose main window is grown to the default size.
local LARGE_CLASSES = {
  ["chromium"] = true, ["google-chrome"] = true, ["google-chrome-stable"] = true, ["google-chrome-beta"] = true,
  ["google-chrome-unstable"] = true, ["brave-browser"] = true, ["microsoft-edge"] = true, ["vivaldi-stable"] = true,
  ["helium"] = true, ["firefox"] = true, ["zen"] = true, ["zen-browser"] = true, ["librewolf"] = true,
  ["org.mozilla.firefox"] = true, ["org.chromium.chromium"] = true,
}

local function xy(value)
  if type(value) ~= "table" then
    return nil
  end
  local x, y = value.x or value[1], value.y or value[2]
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  return x, y
end

local function usable_size(monitor)
  local width, height = monitor.width, monitor.height
  if type(width) ~= "number" or type(height) ~= "number" then
    return nil
  end
  local scale = type(monitor.scale) == "number" and monitor.scale > 0 and monitor.scale or 1
  width, height = width / scale, height / scale
  local reserved = monitor.reserved
  if type(reserved) == "table" then
    -- Reserved area (menu bar, dock): { top, bottom, left, right } or the same names as fields.
    local top = reserved.top or reserved[1] or 0
    local bottom = reserved.bottom or reserved[2] or 0
    local left = reserved.left or reserved[3] or 0
    local right = reserved.right or reserved[4] or 0
    height = height - top - bottom
    width = width - left - right
  end
  return width, height
end

-- Titlebar that grassfield-compositor draws above a window's surface (compositor/src/core/Theme.hpp kTitlebarHeight,
-- tests/compositor/titlebar_geometry.sh). Kept without the plugin: the window then opens 32 px below the menu bar.
local TITLEBAR = 32

-- Free area of a monitor in layout coordinates (the menu bar and the Dock left out): x, y, width, height.
local function work_area(monitor)
  if not monitor or type(monitor.x) ~= "number" or type(monitor.y) ~= "number" then
    return nil
  end
  local width, height = usable_size(monitor)
  if not width then
    return nil
  end
  local reserved = type(monitor.reserved) == "table" and monitor.reserved or {}
  local top = reserved.top or reserved[1] or 0
  local left = reserved.left or reserved[3] or 0
  return monitor.x + left, monitor.y + top, width, height
end

-- Hyprland's Lua window object exposes no parent, transient-for or modal field (hl.meta.lua), so "not a dialog" is
-- inferred: a dialog, a popup or a second window belongs to an application that already has a mapped window.
local function has_sibling(window)
  local class = (window.class or ""):lower()
  for _, other in ipairs(hl.get_windows({ mapped = true }) or {}) do
    if other.address ~= window.address and (other.class or ""):lower() == class then
      return true
    end
  end
  return false
end

-- Picture-in-Picture, utility and tagged windows keep the size they ask for.
local function is_auxiliary(window)
  local title = ((window.title or "") .. " " .. (window.initial_title or "")):lower()
  if title:find("picture[- ]in[- ]picture") then
    return true
  end
  return window.pinned == true or (window.xdg_tag or "") ~= ""
end

local function grow(window)
  if not window or not window.floating or window.fullscreen ~= 0 then
    return
  end
  if not LARGE_CLASSES[(window.class or ""):lower()] or (window.title or "") == "" then
    return
  end
  if is_auxiliary(window) or has_sibling(window) then
    return
  end
  local monitor = window.monitor
  local usable_w, usable_h
  if monitor then
    usable_w, usable_h = usable_size(monitor)
  end
  local w, h = xy(window.size)
  if not usable_w or not w then
    return
  end
  local want_w, want_h = math.floor(usable_w * DEFAULT_WIDTH), math.floor(usable_h * DEFAULT_HEIGHT)
  if w >= want_w and h >= want_h then
    return
  end
  want_w, want_h = math.max(w, want_w), math.max(h, want_h)
  hl.dispatch(hl.dsp.window.resize({ x = want_w, y = want_h, window = window }))
  hl.dispatch(hl.dsp.window.center({ window = window }))
end

-- macOS model: a window opens with its title bar below the menu bar and on its screen, never under the bar or off the
-- screen, and a window larger than the free area is made to fit it. Hyprland centres a floating window that is taller
-- than the free area over it (a 1080-px window on a 1080-px screen opened at y -29) and keeps the position an X11 client
-- asks for (an application restoring a stored geometry at the top-left corner opened under the bar): either way the
-- title bar was out of reach and the window could not be moved (owner defect 2026-10-22, Spotify).
-- tests/compositor/window_reachable.sh.
local function fit(window)
  if not window or not window.floating or window.fullscreen ~= 0 or window.pinned then
    return
  end
  local area_x, area_y, area_w, area_h = work_area(window.monitor)
  local x, y = xy(window.at)
  local w, h = xy(window.size)
  if not area_x or not x or not w then
    return
  end
  local new_w = math.min(w, area_w)
  local new_h = math.min(h, area_h - TITLEBAR)
  local new_x = math.max(area_x, math.min(x, area_x + area_w - new_w))
  local new_y = math.max(area_y + TITLEBAR, math.min(y, area_y + area_h - new_h))
  if new_w ~= w or new_h ~= h then
    hl.dispatch(hl.dsp.window.resize({ x = new_w, y = new_h, exact = true, window = window }))
  end
  if new_x ~= x or new_y ~= y then
    hl.dispatch(hl.dsp.window.move({ x = new_x, y = new_y, window = window }))
  end
end

-- Grassfield Memos (ADR-0051 D-6): a memo window names the position it had in its xdg-toplevel tag,
-- "memo:<32 hex>@<x>,<y>" (layout coordinates, as Hyprland's window list gave them to the app); it opens there, kept
-- inside the free area of the display it opens on (the same bounds as `fit`). A tag without a position (a memo never seen by
-- the compositor) leaves Hyprland's placement. Known limit: a memo whose display is gone comes back on the one it opens on.
local function memo_place(window)
  if not window or not window.floating or window.fullscreen ~= 0 then
    return
  end
  -- The app id exactly (case-sensitive, as Memos sets it) and the tag exactly: 32 lowercase hex digits,
  -- then the position (review of the memos slice: any client could pass a loose match).
  if window.class ~= "org.grassfield.Memos" then
    return
  end
  local tag = window.xdg_tag or ""
  local id = "^memo:" .. string.rep("[0-9a-f]", 32)
  -- The tag may end with "!<w>x<h>" (a collapse or an expand sent it later, memo_resize below): not a position's concern.
  local hx, hy = tag:match(id .. "@(%-?%d+),(%-?%d+)$")
  if not hx then
    hx, hy = tag:match(id .. "@(%-?%d+),(%-?%d+)!%d+x%d+$")
  end
  if not hx then
    return
  end
  local area_x, area_y, area_w, area_h = work_area(window.monitor)
  local w, h = xy(window.size)
  if not area_x or not w then
    return
  end
  local x = math.max(area_x, math.min(tonumber(hx), area_x + area_w - w))
  local y = math.max(area_y + TITLEBAR, math.min(tonumber(hy), area_y + area_h - h))
  hl.dispatch(hl.dsp.window.move({ x = x, y = y, window = window }))
end

-- Grassfield Memos' collapse (ADR-0051 D-6): a Wayland client cannot resize its own floating window, and Hyprland 0.56 keeps a
-- floating window at the size it has when the client only commits a smaller or larger surface (a collapsed memo sat on an empty
-- rectangle). So a memo that collapses or expands sends its tag again with the size it wants, "...!<w>x<h>"; when that suffix
-- changes, the window is resized to it with its top-left corner kept (macOS's notes shrink to their strip in place). The
-- request is only ever for the window that sent it, and the size is bounded: nothing here gives a client more than it could
-- take by resizing its own window. Only a change of the suffix acts, so a resize by the user is never undone.
local MEMO_SIZE_MAX = 16384
local memo_sizes = {}

local function memo_resize(window)
  if not window or not window.mapped or not window.floating or window.fullscreen ~= 0 or window.class ~= "org.grassfield.Memos" then
    return
  end
  local tag = window.xdg_tag or ""
  local id = "^memo:" .. string.rep("[0-9a-f]", 32)
  -- The tag also carries the position the memo had when it asked ("@x,y": the app read it from Hyprland just before the
  -- change); Hyprland moves a window whose surface grows or shrinks, so the corner is put back there.
  local hx, hy, w, h = tag:match(id .. "@(%-?%d+),(%-?%d+)!(%d+)x(%d+)$")
  if not w then
    w, h = tag:match(id .. "!(%d+)x(%d+)$")
  end
  if not w then
    return
  end
  w, h = tonumber(w), tonumber(h)
  local key = tostring(window.address)
  local want = w .. "x" .. h
  if memo_sizes[key] == want then
    return
  end
  memo_sizes[key] = want
  local x, y = tonumber(hx), tonumber(hy)
  if not x then
    x, y = xy(window.at)
  end
  if not x or w < 1 or h < 1 or w > MEMO_SIZE_MAX or h > MEMO_SIZE_MAX then
    return
  end
  -- The corner is kept inside the free area of the display, as memo_place does.
  local area_x, area_y, area_w, area_h = work_area(window.monitor)
  if area_x then
    x = math.max(area_x, math.min(x, area_x + area_w - w))
    y = math.max(area_y + TITLEBAR, math.min(y, area_y + area_h - h))
  end
  hl.dispatch(hl.dsp.window.resize({ x = w, y = h, exact = true, window = window }))
  hl.dispatch(hl.dsp.window.move({ x = x, y = y, window = window }))
end

hl.on("window.update_rules", function(window)
  local ok, err = pcall(memo_resize, window)
  if not ok then
    print("grassfield: resizing the memo failed: " .. tostring(err))
  end
end)

hl.on("window.close", function(window)
  if window then
    memo_sizes[tostring(window.address)] = nil
  end
end)

hl.on("window.open", function(window)
  local ok, err = pcall(memo_place, window)
  if not ok then
    print("grassfield: placing the memo failed: " .. tostring(err))
  end
  ok, err = pcall(grow, window)
  if not ok then
    print("grassfield: default size failed: " .. tostring(err))
  end
  ok, err = pcall(fit, window)
  if not ok then
    print("grassfield: fitting the window failed: " .. tostring(err))
  end
end)
