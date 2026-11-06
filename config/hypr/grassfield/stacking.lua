-- Stacking (macOS model): the window that takes focus comes to the front, whole, above every other window.
--
-- Hyprland 0.56 focuses a floating window on a click but does not raise it, so clicking the visible part of a
-- window that sits behind another one left the front window on top. The Grassfield titlebar already raises on its
-- own press (compositor/src/Titlebar.cpp focusAndRaise); this covers a press anywhere else in the window, and every
-- other way a window becomes active (Dock click, switcher, a program asking for focus).
--
-- Windows that are not floating cannot overlap, and a full-screen window (or any window on a workspace that shows one)
-- is left alone: raising there would draw a window over the full-screen one. A zoomed window (Grassfield Zoom is
-- Hyprland's maximized mode) is an ordinary window on macOS: it is raised when it takes focus, and a window activated
-- over it comes in front of it (owner report 2026-10-23: a zoomed Spotify clicked behind Chrome took the focus and
-- stayed behind). Hyprland's fullscreen value is a mode mask: 1 maximized, 2 full screen, 3 both.

local function full_screen(window)
  return window ~= nil and (window.fullscreen or 0) >= 2
end

-- Grassfield Memos has no Float on Top (ADR-0051 D-6): a rule keyed on the app id and a tag would trust names any Wayland
-- client can claim. It returns with a compositor-plugin check of the client's real credentials.

local function raise(window)
  if not window then
    return
  end
  if not window.floating or full_screen(window) then
    return
  end
  local workspace = window.workspace
  if workspace and full_screen(workspace.fullscreen_window) then
    return
  end
  local ok, err = pcall(function()
    -- Hyprland draws the zoomed (maximized) window of a workspace in its own pass: a floating window raised over it
    -- (allowed_over_fullscreen) stays drawn above it whatever the order. When the zoomed window itself takes focus,
    -- those windows go behind it, top one first so that they keep their order among themselves; activating one of
    -- them later raises it over the zoomed window again. Pinned windows stay above everything.
    if window.fullscreen == 1 and workspace then
      local others = workspace:get_windows() or {}
      for i = #others, 1, -1 do
        local other = others[i]
        if other.address ~= window.address and other.floating and other.allowed_over_fullscreen and not other.pinned then
          hl.dispatch(hl.dsp.window.alter_zorder({ mode = "bottom", window = "address:" .. other.address }))
        end
      end
    end
    hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = window }))
  end)
  if not ok then
    print("grassfield: raise on focus failed: " .. tostring(err))
  end
end

hl.on("window.active", function(window)
  raise(window or hl.get_active_window())
end)
