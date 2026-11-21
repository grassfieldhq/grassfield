-- Grassfield look and feel (master-prompt §5.5, ADR-0002, ADR-0003).
-- Values mirror ui/tokens/tokens.json ("window.*", "motion.*"); keep both in sync.

hl.config({
  general = {
    -- Floating-first desktop: gaps only matter for the rare tiled window.
    gaps_in = 4,
    gaps_out = 8,
    float_gaps = 0,
    border_size = 1,
    col = {
      -- The window's contact edge, macOS 27's dark device pixel outside the window: the dark appearance's (tokens
      -- window.edgeDark and window.edge*OpacityDark). The shell pushes the current appearance's pair at start, on a change
      -- and after a reload (fainter in the light appearance; ADR-0039 step 6, C-4; ADR-0024 note 2026-11-03;
      -- shell/platform/Compositor.qml pushEdge). At 1.25 the border is one device pixel (0.8 pt). The dark appearance's light
      -- inner rim is left to the plugin: Hyprland 0.56.2's inner glow (decoration.glow) has no window rule and skips the
      -- rounded corners, and it lit the client's top row under a third-party window's titlebar (ADR-0024 note 2026-11-03).
      active_border = "rgba(00000094)",
      inactive_border = "rgba(00000085)",
    },
    resize_on_border = true,
    extend_border_grab_area = 8,
    hover_icon_on_border = true,
    allow_tearing = false,
    layout = "dwindle",
    snap = {
      enabled = true,
      window_gap = 8,
      monitor_gap = 8,
    },
  },

  decoration = {
    -- One window radius for every window (macOS 27, ADR-0024 C-1): 16.5 to 16.7 pt circle-equivalent at 45 degrees in the
    -- release captures, 4.8 to 4.9 pt from both edges. Hyprland 0.56.2 draws a corner of CWindow::rounding() =
    -- rounding x rounding_power / 2 pt (22.1 here), cut to whole device pixels (27 at 1.25), as a superellipse of that
    -- power: its 45-degree point is that radius x (1 - 2^(-1/2.6)) in. Measured on GF-REF at 1.25 with the captures'
    -- method: 17 gives 4.88 to 4.89 pt (16.7 circle-equivalent), 16 gives 16.2, 18 gives 18.1, 20 gave 19.8. The rules
    -- gf-third-party-rounding and gf-client-chrome-info-rounding (windows.lua) set the same 17 (a rule's cap is 20).
    rounding = 17,
    rounding_power = 2.6,
    active_opacity = 1.0,
    inactive_opacity = 1.0,
    fullscreen_opacity = 1.0,
    dim_inactive = false,

    -- Diffused shadow fitted to the macOS 27 window shadow (ADR-0024 C-3, docs/audits/ui-finesse-2026-10-25.md 7.3:
    -- alpha = 0.25 x (1 - d / 68)^4, offset 16 down); inactive windows keep today's ratio to the active shadow (0.2 / 0.35).
    -- Measured on the GPU at 1.25 (ADR-0024 note 2026-11-03, tests/compositor/window_edge.sh): the render is this model within
    -- 0.023, and these values stay its least-squares fit to the 27 profile; one offset box cannot draw 27's slope under the
    -- window (0.34 at 1 pt to 0.21 at 16 pt), it holds 0.25 over those 16 pt.
    shadow = {
      enabled = true,
      range = 68,
      render_power = 4,
      sharp = false,
      color = "rgba(00000040)",
      color_inactive = "rgba(00000024)",
      offset = { 0, 16 },
      scale = 1.0,
    },

    -- Blur is used by Grassfield shell surfaces (layer rules); app windows stay opaque.
    blur = {
      enabled = true,
      size = 18,
      passes = 3,
      new_optimizations = true,
      ignore_opacity = true,
      xray = false,
      noise = 0.015,
      contrast = 1.0,
      brightness = 1.0,
      vibrancy = 0.18,
      vibrancy_darkness = 0.0,
      popups = true,
      special = false,
    },
  },

  animations = {
    enabled = true,
    workspace_wraparound = false,
  },

  -- VRR, direct scanout and tearing (CIO audit note, decision 2026-11-19, the macOS model): a full-screen game or video gets
  -- variable refresh (ProMotion / Adaptive-Sync on macOS apply to the frontmost full-screen content, never as a desktop-wide
  -- flicker risk on panels whose brightness wobbles at low refresh), and its surface goes straight to the display when it
  -- declares itself a game (content-type), which the plugin's decorations never defeat (none is drawn in full screen).
  -- Tearing stays off: macOS never tears, and an app that asks for it gets vsync. The desktop itself keeps a fixed refresh.
  -- The owner checks it on a VRR display (docs/specs/compositor.md, owner checks).
  render = {
    direct_scanout = 2, -- auto: full-screen surfaces with content-type game
  },

  misc = {
    -- 2: VRR on full-screen windows only (see above).
    vrr = 2,
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    disable_scale_notification = true,
    focus_on_activate = true,
    animate_manual_resizes = false,
    animate_mouse_windowdragging = false,
    allow_session_lock_restore = true,
    -- ADR-0040 IQ-T5 A (the owner's « Le retarder »): the red "lock screen died" screen waits past a normal shell restart
    -- (the shell is back with its lock in about 1 to 2 s); the session stays locked by the compositor meanwhile and the screen
    -- is black; a shell that does not come back still shows the red screen after the delay. VERIFY on 0.56.2 in the nested
    -- pass: only black is drawn during the delay (tests/security/reload_locked.sh).
    lockdead_screen_delay = 5000,
    session_lock_xray = false,
    -- The shell switches the displays off on an idle lock screen (D-4, shell/security/idle/Idle.qml); the compositor
    -- itself wakes them on any key or pointer motion, so a shell that is restarting can never leave the screen dark
    -- (same values as Omarchy's default/hypr/input.lua, which this session does not load).
    key_press_enables_dpms = true,
    mouse_move_enables_dpms = true,
    on_focus_under_fullscreen = 1,
    initial_workspace_tracking = 0,
    -- The ground behind every surface (ADR-0040 ID-2): the default artwork's (the dark Grassfield evening, session.ground);
    -- the shell sets the shown wallpaper's at its start and on each change (shell/platform/Compositor.qml).
    background_color = "rgba(2f6d5fff)",
    -- ADR-0035 D-3: an app is "not responding" after three missed pings, about 4.5 s (Omarchy's own value); the shell then
    -- marks it in Force Quit and its Dock menu (packaging/session-bin/hyprland-dialog).
    anr_missed_pings = 3,
  },

  cursor = {
    hide_on_key_press = false,
    -- The shell focuses windows explicitly (desktop keyboard handoff); never warp the pointer to them.
    no_warps = true,
  },

  -- Hyprland's own update and donation windows stay off in this session (ADR-0035 D-1). Set here, after the Omarchy
  -- include, so they stay off when that include fails or Omarchy's envs.lua drops its line. The welcome tour only runs for a
  -- config marked `autogenerated = true`, which no Grassfield file is (tests/shell/hyprland_screens.sh).
  -- enforce_permissions is left at Hyprland's default (off), so an opt-in to Hyprland's permission prompts (the user's
  -- input.lua, a future Omarchy) still wins. While it is off, apps that go through the screen-cast portal ask there, but a
  -- native Wayland client can capture the screen through wlr-screencopy or hyprland-toplevel-export without any prompt, as
  -- in the Omarchy session.
  ecosystem = {
    no_update_news = true,
    no_donation_nag = true,
  },
})

-- The ground of the owner's wallpaper (ADR-0040 ID-2, P-1, amended): before the shell has drawn, the screen shows the ground the
-- shell last gave the compositor (wallpaper.json `ground`, written when Hyprland accepted it: the mean colour of the picture,
-- the colour itself, the artwork's), not the default artwork's green. No file, no `ground` or anything but a plain file: the
-- static ground above stays. Read through `head` behind `test -f` and `timeout` (a FIFO or a symlink never blocks the
-- configuration, a directory is no file); Lua has no stat.
do
  local home = os.getenv("GRASSFIELD_STATE_HOME")
  if not home or home == "" then
    local xdg = os.getenv("XDG_STATE_HOME")
    local base = (xdg and xdg ~= "") and xdg or ((os.getenv("HOME") or "") .. "/.local/state")
    home = base .. "/grassfield"
  end
  local path = home .. "/wallpaper.json"
  -- From the second parse of a login on, the compositor plugin reads it in-process (a regular file only, never blocking,
  -- bounded: grassfield.probe, CIO-10); the first parse forks the guarded `head` below.
  local text, unavailable = nil, true
  if not path:find("%c") and path:sub(1, 1) == "/" then
    local probe_ok, probe = pcall(require, "grassfield.probe")
    if probe_ok then text, unavailable = probe.read_file(path, 65536) end
  end
  if unavailable and type(io.popen) == "function" and not path:find("%c") then
    local q = "'" .. path:gsub("'", "'\\''") .. "'"
    local cmd = "[ -f " .. q .. " ] && [ ! -L " .. q .. " ] && timeout 2 head -c 65536 -- " .. q .. " 2>/dev/null"
    local ok, p = pcall(io.popen, cmd, "r")
    if ok and p then
      text = p:read("a") or ""
      p:close()
    end
  end
  local ground = type(text) == "string" and text:match('"ground"%s*:%s*"#(%x%x%x%x%x%x)"')
  if ground then
    hl.config({ misc = { background_color = "rgba(" .. ground:lower() .. "ff)" } })
  end
end

-- Motion curves (tokens "motion.curve.*").
hl.curve("gfStandard", { type = "bezier", points = { { 0.2, 0.0 }, { 0.0, 1.0 } } })
hl.curve("gfDecelerate", { type = "bezier", points = { { 0.32, 0.72 }, { 0.0, 1.0 } } })
hl.curve("gfAccelerate", { type = "bezier", points = { { 0.4, 0.0 }, { 1.0, 1.0 } } })
hl.curve("gfLinear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } })

-- Speeds are in Hyprland units (1 = 100 ms).
hl.animation({ leaf = "global", enabled = true, speed = 3, bezier = "gfDecelerate" })
hl.animation({ leaf = "border", enabled = true, speed = 2, bezier = "gfStandard" })
-- macOS: a new window opens with a quick, subtle scale and fade (about 0.2 s); closing is the reverse and shorter (about 0.12 s).
hl.animation({ leaf = "windowsIn", enabled = true, speed = 2, bezier = "gfDecelerate", style = "popin 94%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.2, bezier = "gfAccelerate", style = "popin 96%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 3, bezier = "gfDecelerate" })
hl.animation({ leaf = "zoomFactor", enabled = true, speed = 3, bezier = "gfDecelerate" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 2, bezier = "gfDecelerate" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 1.2, bezier = "gfAccelerate" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 2, bezier = "gfDecelerate", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 1.6, bezier = "gfAccelerate", style = "fade" })
-- Spaces slide horizontally, like swiping between desktops.
hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "gfDecelerate", style = "slide" })
hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 3, bezier = "gfDecelerate", style = "fade" })
