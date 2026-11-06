-- Window behavior (ADR-0002): floating-first, centered, opaque application windows.

-- Every new window floats. Users can still tile a window explicitly.
hl.window_rule({ name = "gf-float-all", match = { class = ".*" }, float = true })

-- Don't let apps maximize themselves into a tiled state; Zoom is a Grassfield action.
-- Only a client-chrome window (ADR-0015, apps/windowchrome.h; the gf-client-chrome matches below) is exempt: its own zoom
-- control sends the request, and it is the only one that window has. Hyprland toggles the maximized mode on any maximize
-- request, so one request per press zooms and unzooms. Every other window, tagged by its toolkit or not, keeps the
-- suppression. Two rules make the negation of those matches (any class but Grassfield's and the third-party list below;
-- or no xdg tag and not in that list) without reading the tag itself: the tag is a dynamic effect, the suppression a
-- static one read at map. tests/shell/client_chrome_rules.sh checks that both negations are built from the two lists.
hl.window_rule({ name = "gf-no-maximize-event", match = { class = "negative:^(org\\.grassfield\\.(Files|Settings|Preview|Store|Activity|Memos)|chromium|firefox|org\\.mozilla\\.firefox|md\\.obsidian\\.Obsidian|org\\.gnome\\.Evince|org\\.gnome\\.Nautilus)$" }, suppress_event = "maximize" })
hl.window_rule({ name = "gf-no-maximize-event-untagged", match = { class = "negative:^(chromium|firefox|org\\.mozilla\\.firefox|md\\.obsidian\\.Obsidian|org\\.gnome\\.Evince|org\\.gnome\\.Nautilus)$", xdg_tag = "negative:.+" }, suppress_event = "maximize" })

-- Client chrome (ADR-0015): Grassfield apps that draw their own lights and toolbar are tagged
-- `grassfield-client-chrome`; the compositor plugin draws no titlebar on them (plugin work item P1, docs/specs/compositor.md)
-- and Overview and Stages leave no band above them. The tag is set at map (the xdg tag comes with the first commit). The
-- class list is the apps that set a tag; KIO and widget dialogs set none and keep the plugin titlebar. The plugin and the
-- shell read the same tag name: keep it in step with shell/overview/ClientChrome.js. Never `decorate = false`: it also
-- drops Hyprland's border and shadow.
-- Grassfield Memos (ADR-0051) draws a memo's strip instead of lights; its tag is the memo's (`memo:<id>...`, any tag matches).
hl.window_rule({ name = "gf-client-chrome", match = { class = "^org\\.grassfield\\.(Files|Settings|Preview|Store|Activity|Memos)$", xdg_tag = ".+" }, tag = "+grassfield-client-chrome" })

-- Third-party apps that draw their own window controls (GF-056; ADR-0015 amendment 2026-10-25). macOS: a window has one
-- set of traffic lights, close, minimize, zoom, top-left; an app that draws its own title bar gets no second bar from the
-- system. Hyprland 0.56.2 gives a plugin no per-window decoration signal it could use instead (the xdg-decoration request
-- is kept in a private map, and header-bar toolkits never negotiate), so the list is by Wayland app id. Only apps whose
-- own close, minimize and zoom were seen to work in the nested session with the session's GTK button layout
-- (close,minimize,maximize: on the left, packaging/dconf/grassfield.d/20-window-buttons.conf;
-- tests/compositor/third_party_chrome.sh): Chromium's browser window (its --app web apps draw no frame and keep the
-- plugin's titlebar), Obsidian (its controls top right, in its own order), Evince (GTK3 header bar) and Nautilus
-- (GTK4/libadwaita). Firefox (`firefox`; `org.mozilla.firefox` for the Flatpak) was added on the owner's rc1-22 screenshot,
-- 2026-11-04: with the plugin's bar it showed a second set of controls (Firefox's own, from the session's GTK button layout,
-- in its tab strip); that its own close, minimize and zoom work here, and that they draw as traffic lights with the
-- Grassfield GTK theme, is NOT VERIFIED (not installed on the dev machine; the owner checks it on the second machine).
-- The one entry that breaks the rule above (controls seen to work here), on the owner's evidence alone. Known risk: with
-- Firefox's "Title Bar" option on (Customize Toolbar), Firefox draws no controls and no plugin bar appears either, a window
-- with none (checked with a stand-in window: tagged, no strip). Firefox's default is its own frame (CSD), the case the
-- screenshot shows; a user who turns "Title Bar" on gets no controls until they turn it off again (or the list drops it).
-- Google Chrome is left out: its Wayland app id (google-chrome is expected, from its desktop file) is not evidenced here.
-- The traffic lights themselves come from the Grassfield GTK themes (ui/tools/gen-gtk-themes.py, window.* tokens), which
-- GTK 3 and plain GTK 4 apps and Chromium's GTK appearance read (measured nested at 1.25: tests/compositor/gtk_lights.sh;
-- a fresh Chromium profile is "Classic" and draws plain grey buttons); libadwaita apps (Nautilus) ignore gtk-theme
-- (ADR-0015 amendment 2026-11-04). Their zoom needs the exemption below (untagged, Evince's zoom request was suppressed), and GTK4's
-- minimize button needs the plugin to offer minimize in xdg wm_capabilities (plugin work item P8; without the plugin
-- Hyprland offers no minimize and GTK4 greys it). Others join only once verified. Same tag as Grassfield's apps: no
-- plugin titlebar, no band in Overview and Stages, the app's own minimize and zoom work (exempt from the maximize
-- suppression above). An app set to use the system title bar (Chromium's "Use system title bar and borders") draws no
-- controls: take it out of this list. Known limit (ADR-0015 amendment 2026-10-25): the GTK apps and Chromium draw the
-- buttons of the GTK button layout, so a user layout without minimize or zoom leaves them a partial set (none without
-- any button).
hl.window_rule({ name = "gf-client-chrome-third-party", match = { class = "^(chromium|firefox|org\\.mozilla\\.firefox|md\\.obsidian\\.Obsidian|org\\.gnome\\.Evince|org\\.gnome\\.Nautilus)$" }, tag = "+grassfield-client-chrome" })

-- The Open and Save panels (grassfield-portal, ADR-0035 D-4) draw a sheet's frame and no lights; a panel takes the Wayland app
-- id of the application it belongs to (its Dock tile, its menu bar), so its xdg tag alone says it is one: no plugin
-- titlebar on it.
hl.window_rule({ name = "gf-client-chrome-panel", match = { xdg_tag = "^file-panel$" }, tag = "+grassfield-client-chrome" })

-- The permission alerts (grassfield-portal, ADR-0035 D-5) draw the alert shape, its own buttons and no lights: no plugin
-- titlebar. Their radius is every window's (17, ADR-0024 C-1): a rule cannot go past decoration.rounding (ADR-0035 5a-4).
hl.window_rule({ name = "gf-client-chrome-alert", match = { xdg_tag = "^access-alert$" }, tag = "+grassfield-client-chrome" })

-- Get Info and Customize Folder draw the titlebar-only style (role "info"). macOS 27 has one radius for every window
-- (ADR-0024 C-1, replacing ADR-0015 Q5's 26 / 12): 17, the global decoration.rounding (looknfeel.lua).
hl.window_rule({ name = "gf-client-chrome-info-rounding", match = { class = "^org\\.grassfield\\.Files$", xdg_tag = "^info$" }, rounding = 17 })

-- Corner radius (ADR-0024 C-1, one radius for every window as in macOS 27): Grassfield's windows take 17 from
-- decoration.rounding (looknfeel.lua: 16.7 pt circle-equivalent on screen, macOS 27's 16.5 to 16.7); every other window,
-- matched by a negated class regex (also a window without a class), gets the same 17 from this rule. Rule regexes match
-- the whole class: the pattern must cover all of it (a bare prefix never matches, so its negation would match every
-- window).
hl.window_rule({ name = "gf-third-party-rounding", match = { class = "negative:^org\\.grassfield\\..*$" }, rounding = 17 })

-- Grassfield Memos: a memo window has square corners, as macOS's desktop notes (its paper and strip are rectangles, and the
-- resize grip sits in the bottom-right corner, which a rounded window cuts). Only the corner radius is taken from the app id,
-- a name any client could claim: the worst a claim gets is square corners (ADR-0051 D-6).
hl.window_rule({ name = "gf-memos-square", match = { class = "^org\\.grassfield\\.Memos$" }, rounding = 0 })

-- Glance (quick look of Preview): a floating panel centered on the screen, without the plugin titlebar.
hl.window_rule({ name = "gf-glance", match = { class = "^org\\.grassfield\\.Preview\\.Glance$" }, float = true, center = true, decorate = false })

-- Grassfield shell surfaces (layer-shell namespaces start with "grassfield-").
-- Blur behind them comes from BackgroundEffect when available; this rule is the fallback (§5.5).
hl.layer_rule({ name = "gf-shell-blur", match = { namespace = "^grassfield-(menubar|dock|overlay|overview|search|switcher|banners|notification-center|apps|osd|polkit|secret|widgets|widgets-menu|stages|capture|capture-countdown)$" }, blur = true, ignore_alpha = 0.01 })
-- The desktop's context menu is an xdg popup of the icons layer; Hyprland 0.56.2 left it unblurred with
-- BackgroundEffect alone. Only its popups blur (never the icons layer itself), limited to the menu's own pixels.
hl.layer_rule({ name = "gf-desktop-menu-blur", match = { namespace = "^grassfield-desktop-icons$" }, blur_popups = true, ignore_alpha = 0.01 })

-- The menu bar and dock must appear instantly; panels fade.
hl.layer_rule({ name = "gf-bar-no-anim", match = { namespace = "^grassfield-(menubar|dock)$" }, no_anim = true })
-- The wallpaper maps with its final first frame and changes by the shell's own crossfade (ADR-0040 ID-3, ID-4): the
-- compositor never fades it in under that.
hl.layer_rule({ name = "gf-wallpaper-no-anim", match = { namespace = "^grassfield-wallpaper$" }, no_anim = true })
-- The icons' surface (and its desktop menu) is above the wallpaper of its output whatever the mapping order: both are on the
-- Background layer and Hyprland stacks a layer by map order unless a rule gives an order, so a display plugged in after the
-- session started (its icons surface maps before its wallpaper's first frame) would be covered by the picture. Measured on
-- Hyprland 0.56.2 (nested, 1.25, hotplugged outputs): the LOWER order is stacked above, so the icons get -10 and the wallpaper
-- 10 (the other way round left the icons under the wallpaper); tests/visual/desktop-hotplug.sh checks it.
hl.layer_rule({ name = "gf-wallpaper-order", match = { namespace = "^grassfield-wallpaper$" }, order = 10 })
hl.layer_rule({ name = "gf-desktop-icons-order", match = { namespace = "^grassfield-desktop-icons$" }, order = -10 })
-- The exit cover fades itself (ADR-0040 ID-10, one owner of motion: ID-4); the compositor adds no fade in or out.
hl.layer_rule({ name = "gf-exit-cover-no-anim", match = { namespace = "^grassfield-exit-cover$" }, no_anim = true })
-- The screenshot crosshair (slurp's layer, namespace "selection") goes at once: grim takes the picture as slurp ends, and a
-- fade would put slurp's veil and outline in it (ADR-0035 D-10, fourth review of step 8; Omarchy ships the same rule).
hl.layer_rule({ name = "gf-capture-selection-no-anim", match = { namespace = "^selection$" }, no_anim = true })
-- The capture timer's countdown plate (ADR-0045 OC-1) goes at once too: the picture is taken half a second after the shell drops
-- it, and a fade would put the plate in the picture.
hl.layer_rule({ name = "gf-capture-countdown-no-anim", match = { namespace = "^grassfield-capture-countdown$" }, no_anim = true })
-- The capture toolbar's per-display surfaces are re-mapped when the keyboard follows the pointer to another display (a mapped
-- layer set to Exclusive does not get the focus); Hyprland's layer fade made the bar blink for about half a second each time.
-- macOS shows and hides the screenshot toolbar at once, so its surfaces map and unmap without the compositor's fade.
hl.layer_rule({ name = "gf-capture-toolbar-no-anim", match = { namespace = "^grassfield-capture$" }, no_anim = true })
