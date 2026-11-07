# ADR-0015: Unified toolbar for Grassfield apps: the shared UI framework draws the window controls, the plugin steps aside per window
Status: Accepted 2026-10-22 after the nested spike, with integrator decisions on Q4, step 3 and Q5 (see the end) · Date: 2026-10-20 · Decider: owner

## Context

### Need (F1 gap 9)
`docs/testing/f1-reference-gaps.md` item 9 (:358-364) and the window chrome rows (:100-112):
- macOS toolbar windows use one 52 ± 1 pt row that holds both the traffic lights and the toolbar items (:107). The first
  light's centre is at (25.75, 25.75) ± 0.5 from the window's top-left corner, inside the floating sidebar (:106, :243).
- The items are 36-pt glass capsules: back/forward 72.5 x 36, grouped view and action capsules, and a search circle that
  opens to about 200 (:108).
- The title is about 15 pt bold, left-aligned after back/forward (:109). The corner radius is 26 ± 1.5 (:100). The lights
  are 14 ± 0.5 pt at a 23-pt pitch (:102-103).
- Grassfield today:
  - Files stacks the plugin's 28-px titlebar over its 52-px toolbar (:107, :215) and shows two titles (:109).
  - Settings has no toolbar; its title sits inside the page (:251).
  - Preview has a 44-px toolbar under the titlebar (:235).
- Item 9 calls this cross-module work (plugin + apps + ui), so it needs an ADR (R5, master-prompt.md:154).

### Grassfield today (VERIFIED: read in this session)
- **Which windows get a titlebar.**
  - The plugin adds its titlebar to every mapped window (compositor/src/main.cpp:61-66, :81).
  - It shows the titlebar when the window is floating, not full screen, not X11 override-redirect, and its `decorate`
    rule is true (compositor/src/Titlebar.cpp:233-244). It never looks at xdg-decoration, so CSD apps get a second
    titlebar (docs/specs/compositor.md:976).
- **How the titlebar looks.**
  - A 28-px STICKY strip above the surface (Titlebar.cpp:246-257; core/Theme.hpp:30).
  - Opaque and dark only (Theme.hpp:65-74; compositor.md:974).
  - 12-px lights, 8 px apart, the first 12 px from the edge (Theme.hpp:31-33), and a centred title.
  - No hover glyphs, no grey inactive state, no pressed state (compositor.md:973; Titlebar.cpp:368).
- **Input.**
  - Left button only (Titlebar.cpp:429); no right-click menu.
  - A light acts on release over the same light.
  - The drag is the plugin's own move: no snapping (compositor.md:975), and a maximized window is un-zoomed under the
    pointer (FR8; Titlebar.cpp:136-176).
  - A double-click does what `windows.titlebarDoubleClick` says (Titlebar.cpp:454-468).
- **Actions.**
  - Close is Hyprland's close (Titlebar.cpp:499-502).
  - Zoom toggles `FSMODE_MAXIMIZED` (Titlebar.cpp:122-129).
  - Minimize posts `minimize-request`; the shell answers with the Dock tile (Titlebar.cpp:112-119;
    shell/platform/Compositor.qml:151-170, :300-308). The shell handles no Hyprland `minimized` event
    (Compositor.qml:470-505).
- **gfc/1 capabilities.** `decorations` is always advertised; the other features only when they registered
  (compositor.md:75-81; core/Protocol.hpp:42-62). A degraded shell "keeps client-side decorations" (compositor.md:757).
- **Overview v2 and Stages** assume a 28-px band above every window:
  - Overview: shell/overview/OverviewWindow.qml:105-107 and :131; ui/tokens/tokens.json:337; docs/specs/overview.md:255.
  - Stages: compositor/src/core/Stages.cpp:486-489; core/Stages.hpp:49.
- **Session config.**
  - Every window floats (config/hypr/grassfield/windows.lua:4).
  - Every window has `suppress_event = "maximize"` (windows.lua:7), so a client's `set_maximized` is ignored in the
    Grassfield session.
  - Glance already opts out of the titlebar with `decorate = false` (windows.lua:10; docs/specs/preview.md:51).
  - Hyprland resizes every window from its border (looknfeel.lua:16-17). Rounding is 12 (looknfeel.lua:30).
- **Apps.**
  - The Files, Settings and Preview main windows are plain QtQuick `Window`s (apps/files/qml/BrowserWindow.qml:8-32,
    apps/settings/qml/Main.qml:7, apps/preview/qml/Viewer.qml:7). Their toolbar is an Item inside the window
    (BrowserWindow.qml:361-368, Viewer.qml:172-177) and does not drag the window.
  - Files is a `QApplication` because KIO's conflict, Open With and undo dialogs are widget windows
    (apps/files/src/main.cpp:21-22). These dialogs have the same app id, `org.grassfield.Files` (:29), so a rule keyed
    on the app id also hits them.
  - Files reads `grassfield.json` live (apps/files/src/filesapp.cpp:115, :154-156).
  - Without the plugin, the apps have no lights and no drag (docs/specs/files.md:207, docs/specs/settings.md:99).
- **Legal.** The lights are entry E18, "needs legal review" (docs/legal/visual-review.md:260-265). The owner keeps them
  as they are while legal advice is pending (the maintainers' project log).

### Hyprland 0.56.2 (VERIFIED from /usr/include/hyprland)
- **xdg-decoration.**
  - The per-toplevel objects live in a private map (src/protocols/XDGDecoration.hpp:40). The mode is chosen by private
    helpers (:19-21). `mostRecentlyRequested` is public (:13), but nothing public leads from a window to its object.
  - So a plugin cannot read the negotiated mode without private-member access.
  - Hyprland answers SERVER_SIDE and draws nothing (master-prompt.md:95; not re-measured here).
- **xdg-toplevel-tag-v1** is served (src/protocols/XDGTag.hpp).
  - Each window exposes `CWindow::xdgTag()` (src/desktop/view/Window.hpp:417), and window rules can match it
    (src/desktop/rule/Rule.hpp:31, `RULE_PROP_XDG_TAG`).
  - Hyprland also uses the tag as a key for its floating-size memory (src/desktop/state/FloatState.hpp:23-24).
  - The protocol says the tag should come with the initial commit (staging/xdg-toplevel-tag/xdg-toplevel-tag-v1.xml:61-63).
- **Window rules.**
  - The built-in `decorate` effect (src/desktop/rule/windowRule/WindowRuleApplicator.hpp:96) is honoured by the plugin.
  - A plugin can read the Hyprland window tags (`m_tagKeeper`, :141; src/helpers/TagKeeper.hpp).
  - A plugin can register its own rule effects (`m_otherProps`, :69; src/desktop/rule/effect/EffectContainer.hpp:28).
  - Upstream Lua uses `tag = "+name"` and `match = { tag = "name" }` (/usr/share/omarchy/default/hypr/windows.lua:6, :25;
    helpers.lua:142-153).
- **xdg_toplevel requests.**
  - `move` and `resize` reach `CWindow::onXDGMoveRequest` / `onXDGResizeRequest` (Window.hpp:459-460, :470-471)
    through the public signals `requestMove` / `requestResize` (src/protocols/XDGShell.hpp:131-132).
  - A client's `set_maximized` enters `FSMODE_MAXIMIZED` (Window.hpp:197-198), unless `SUPPRESS_MAXIMIZE` is set
    (:76-79, :194).
  - `set_minimized` is stored in `m_state.requestsMinimize` and announced on the public `stateChanged` signal
    (XDGShell.hpp:129, :140-144). What Hyprland does next is not in the headers, and the event bus has no minimize event
    (src/event/EventBus.hpp:76-93).
  - The toplevel has no window-menu signal (XDGShell.hpp:127-134), so the headers show no handler for `show_window_menu`.
- **Decorations** can draw over the surface (`DECORATION_LAYER_OVER`,
  src/render/decorations/IHyprWindowDecoration.hpp:20), be positioned absolutely
  (src/render/decorations/DecorationPositioner.hpp:11-14) and take mouse input (IHyprWindowDecoration.hpp:25).
- **No protocol** lets a client declare a toolbar height, or a region where the compositor should draw controls.

### Qt 6.11.2 client side (VERIFIED from /usr/include/qt6 and /usr/lib/qt6)
- **Window actions.**
  - `QWindow::startSystemMove()`, `startSystemResize(edges)`, `showMinimized()`, `showMaximized()` and `showNormal()`
    (QtGui/qwindow.h:267-276) are public slots.
  - On Wayland, `QWaylandWindow::startSystemMove/Resize` (QtWaylandClient/6.11.2/.../qwaylandwindow_p.h:229-230) call
    `QWaylandXdgSurface::move/resize`.
  - The xdg-shell plugin (/usr/lib/qt6/plugins/wayland-shell-integration/libxdg-shell.so, read with `strings`) contains
    the request names `set_minimized`, `unset_maximized` and `show_window_menu`.
- **xdg-decoration.** The same plugin contains `QWaylandXdgDecorationManagerV1` and
  `QWaylandXdgToplevelDecorationV1::requestMode`.
- **xdg-toplevel-tag.** Qt has no client for it: no header in QtWaylandClient/6.11.2/QtWaylandClient/private and no
  string in libxdg-shell.so.
  - A per-window Wayland handle exists only as private API: `QNativeInterface::Private::QWaylandWindow::surfaceRole<T>()`
    and the `surfaceRoleCreated()` signal (QtGui/6.11.2/QtGui/qpa/qplatformwindow_p.h:122-158).
  - The public `QNativeInterface::QWaylandApplication` gives only the display and the seat (QtGui/qguiapplication_platform.h:71-85).
  - `QWaylandClientExtensionTemplate` (public) binds a global.
- **Scaling.** Qt supports fractional scaling on Wayland (qwaylandfractionalscale_p.h:30).

### How macOS does it (from memory, no Apple document consulted: ASSUMPTION)
- **Who draws.** The macOS application framework draws the window frame and the three buttons inside the app's own
  process, as part of the window content. The window server does not draw them: it composites the window and casts the
  shadow.
  - The buttons are ordinary button views that the framework hands to the app (`standardWindowButton(_:)`). An app can
    hide them or offset them.
- **What the app declares.** The toolbar style (`toolbarStyle`: unified 52, unified compact, expanded) and whether the
  content runs under the toolbar. The framework sizes the row and centres the buttons in it, which puts them at 25.75 in
  the 52-pt row.
- **What the framework handles, for every app:**
  - glyphs when the pointer is over the group, grey when the window is not key, hidden in full screen;
  - a dot in close for unsaved changes, disabled while a sheet is shown;
  - empty toolbar space drags the window; a double-click follows the system setting;
  - a right-click on the toolbar opens the toolbar's own menu (no window menu);
  - the buttons are accessibility elements of the window.
- **Third-party toolkits** get the same buttons, because they all create the framework's windows.
- **Mapping to Grassfield.** On macOS the "system" that draws the lights is the shared framework running in the app; the
  app only declares. In Grassfield that role belongs to grassfield-ui for Grassfield apps, and to the plugin for
  third-party apps, which have no shared framework.

## Options

### A. Each app draws its own lights; the plugin skips its titlebar for those windows
- **How the plugin learns to skip.**
  - A1, xdg-decoration client mode: not readable by the plugin in 0.56.2 (XDGDecoration.hpp:40).
  - A2, an app-id list (in the plugin or as a session rule): also strips the titlebar from Files' KIO widget dialogs
    (main.cpp:21-22).
  - A3, a per-window tag: as in D.
- **Without the plugin:** the app still draws its lights. Minimize and zoom take the paths described under D.
- **Consistency:** three app copies plus the plugin make four renderers. Sizes, colours, glyphs and inactive states
  drift, and there is no single place to fix them.
- **Drag, double-click, right-click, keyboard, accessibility:** each app wires its own, so the result is uneven.
- **HiDPI and material:** Qt draws the lights crisply, on the app's material.
- **Overview and Stages:** as in D.
- **Tests:** per app. **Size:** small for the first app, then ×3, with high maintenance.
- **Verdict:** this is D without the shared component. Nothing justifies per-app drawing.

### B. The plugin draws the lights inside the app's toolbar row (compositor-side)
- **Mechanism.**
  - The app keeps the lights' area of its row empty.
  - The plugin draws three circles there, with a decoration on the OVER layer positioned absolutely on the surface
    (IHyprWindowDecoration.hpp:20, DecorationPositioner.hpp:11-14), and takes the presses there (:25).
- **What 0.56.2 offers for the app's declaration:** identity and config, not geometry or state.
  - Identity: an xdg toplevel tag plus a session rule (a window tag or a plugin rule effect). The plugin would then take
    a fixed geometry from the tokens: a 52 row with the centre at 25.75.
  - State that the macOS framework knows needs a new Wayland protocol, served by the plugin and bound by each app through
    private Qt API. Examples: a sheet is shown (lights disabled), the document is edited (dot), the toolbar is hidden in
    full screen, the sidebar is collapsed (the lights move over the toolbar). The plugin already serves one global, the
    appmenu one (compositor.md FR18).
- **Without the plugin:** Hyprland draws nothing (master-prompt.md:95), so the app must draw its own lights. B therefore
  contains D as its fallback, plus a switch:
  - The app must notice the plugin's global appear and vanish, also on a runtime unload or reload.
  - During the switch the window can show no lights, or two sets.
- **Consistency:** with the plugin there is one renderer for SSD windows and Grassfield apps. Glyphs, grey and the
  full-screen hide come from the same code, once the plugin has them (compositor.md:973). Without the plugin, the app's
  fallback draws.
- **Drag and double-click:** they stay in the app. The plugin cannot know which parts of the row are empty (the items are
  app content), so one row is split between two processes.
- **Right-click:** the app's toolbar menu, as in D.
- **Keyboard and accessibility:** controls drawn by the compositor are invisible to AT-SPI, like today's titlebars, so
  gate A1 (master-prompt.md:586) cannot be met for them.
- **HiDPI:** two renderers must align on one row. The plugin rounds boxes in device pixels at the monitor scale
  (Titlebar.cpp:347-373); Qt lays out at its fractional buffer scale. The circles and the app's reserved area can be one
  device pixel apart. The plugin was only tested at scale 1 (compositor.md:982).
- **Material:** no strip; the circles are drawn over the app's material.
- **Overview and Stages:**
  - The band above these windows is 0.
  - In live transforms the plugin draws the lights as part of the window.
  - The v1 thumbnails (screencopy of the surface) lose them.
- **Advantage:** the tiling popover on hover of the green light (gap 20, f1-reference-gaps.md:112, :405-408) becomes a
  plain plugin → shell event.
- **Tests:**
  - protocol unit tests;
  - press ownership over the surface: a press on a light never reaches the client (FR13);
  - fallback switching at load and unload;
  - two scales;
  - a heavy R13, C1-C3 load.
- **Size:** L. It needs a new protocol, an overlay decoration with input and hover, the app binding, and all of D for the
  fallback: about twice D.

### C. Keep two rows (status quo)
- **Without the plugin:** Grassfield apps have no lights and no drag (files.md:207).
- **Consistency:** one renderer, the plugin, but it has no glyphs and no grey inactive state.
- **Drag and double-click:** on the titlebar only; the toolbar does not move the window.
- **Right-click:** none. **Accessibility:** the lights are invisible to assistive technologies.
- **HiDPI:** the plugin is tested at scale 1 only.
- **Material:** an opaque dark strip sits above apps in the light appearance (Theme.hpp:65-74).
- **Overview and Stages:** unchanged; the 28-px band stays correct.
- **F1:** gap 9 stays "missing": 80 pt of chrome against 52, and two titles in Files.
- **Size:** 0.

### D. The shared UI framework draws the lights; the app declares (the macOS model)
- **ui (grassfield-ui).**
  - New components `WindowControls` (the three lights) and `UnifiedToolbar` (the row, drag, double-click, and the
    leading space for the lights when no sidebar holds them).
  - The app declares a style, `unified` (52) or `titlebar`, and places its items. It never draws or wires the lights.
  - The values come from new tokens `window.*`: diameter 14, gap 9, row 52, centre 25.75, and the titlebar-only height
    from gap 2.
  - The same tokens generate the plugin's light constants. `ui/tools/gen-tokens.py` already generates `Tokens.qml`, so
    one source of values serves both renderers.
- **Per-window declaration to the compositor.**
  - The chrome sets an xdg toplevel tag that names the window's role (e.g. `browser`, `settings`, `viewer`, `info`),
    which is what the protocol is for (xdg-toplevel-tag-v1.xml:48-63).
  - One helper in `apps/` does this (next to `apps/globalmenu.h`), with `QWaylandClientExtensionTemplate` and
    `QWaylandWindow::surfaceRole<xdg_toplevel>()` on `surfaceRoleCreated()`.
  - KIO's widget dialogs set no tag, so they keep the plugin titlebar.
- **Session rule** (the `xdg_tag` key is UNVERIFIED in Lua; spike step 1):

  ```lua
  hl.window_rule({ name = "gf-client-chrome",
    match = { class = "^org\\.grassfield\\.(Files|Settings|Preview)$", xdg_tag = ".+" },
    tag = "+grassfield-client-chrome" })
  ```

  Rounding per Q5 and the maximize exemption per Q4 are added to this rule.
- **Plugin.**
  - `shouldShow()` returns false for windows tagged `grassfield-client-chrome`. It is evaluated again on
    `window.updateRules` (main.cpp:84).
  - Stages uses that same predicate for the band above each window.
  - New capability `client-chrome`, additive within gfc/1 (ADR-0007).
  - The rule does not use `decorate = false`, which is assumed to drop Hyprland's own border and shadow as well. That is
    the upstream wiki's meaning of the effect, UNVERIFIED on 0.56.2 (spike step 2).
- **Actions.**
  - Close: `QWindow::close()`, which is what Hyprland's close asks the client to do.
  - Zoom: `set_maximized` puts the window in `FSMODE_MAXIMIZED`, the same state as the plugin's zoom
    (Titlebar.cpp:122-129). This needs one of two things: client-chrome windows exempt from `gf-no-maximize-event`
    (windows.lua:7), or the plugin applying the request it sees on `stateChanged` (XDGShell.hpp:129, :141).
  - Minimize: `set_minimized` goes into the shell's minimize path (Dock tile and animation; parking without the plugin).
    It gets there through Hyprland's own report if there is one, or through a plugin bridge to the existing
    `minimize-request` (FR6) (spike step 5, Q4).
  - Drag: `startSystemMove()` starts Hyprland's interactive move (Window.hpp:470).
  - Resize stays on the border (looknfeel.lua:16-17).
- **Without the plugin:**
  - The drawing is the same with and without the plugin: the app draws.
  - Drag and close never need the plugin; zoom does not either if exempted (Q4); minimize depends on spike step 5 and Q4.
  - This is better than today, where the apps have no lights at all.
  - An older plugin without `client-chrome` would draw its strip above the app's lights. Plugin and apps therefore ship
    from the same release (a packaging constraint next to ADR-0009).
- **Consistency.** Two renderers remain: grassfield-ui for Grassfield apps, the plugin for third-party SSD windows.
  - They are kept equal by one token source, a nested parity check (Test plan) and the plugin parity slice (Q2).
  - Full-screen hide: Hyprland syncs full screen to the client by default (WindowRuleApplicator.hpp:110). The app hides
    its lights when Qt reports full screen, as the plugin hides its strip (Titlebar.cpp:241-242).
  - Inactive state: the app follows Qt's `Window.active`, which comes from the xdg `activated` state (ASSUMPTION). The
    plugin parity slice would follow Hyprland's active window; the plugin has no inactive state today.
- **Drag.**
  - One owner holds the whole row, as on macOS.
  - Hyprland's interactive move may differ from the plugin's titlebar drag in two ways: snapping (compositor.md:975) and
    un-zooming a maximized window (FR8). Spike step 3 measures both. If Hyprland refuses to move a maximized window, the
    app un-zooms first (`showNormal()`).
- **Double-click:** the app reads `windows.titlebarDoubleClick`, the way Files already reads `grassfield.json`.
- **Right-click:** later, the toolbar's own menu, as on macOS. There is no window menu: the plugin has none, and Hyprland
  shows no handler for `show_window_menu`.
- **Keyboard and accessibility.**
  - The lights are QML buttons with an Accessible role, a name (Close, Minimize, Zoom) and a press action, so AT-SPI sees
    them.
  - They are not in the Tab chain, as on macOS (from memory). The keyboard equivalents are Ctrl+W and the Window menu (T1).
- **HiDPI:** one renderer, vector shapes, Qt's fractional scale.
- **Material:**
  - The row is drawn on the app's own material, with no opaque strip.
  - The lights follow the dark and light appearance; the plugin strip is dark only.
  - The window itself stays opaque (master-prompt.md:346).
- **Overview and Stages.**
  - Windows tagged `grassfield-client-chrome` get no band.
  - Overview: OverviewWindow.qml:105-107 and :131 read the window's tags from Hyprland's window data, when
    `client-chrome` is advertised. That the window data has this field is UNVERIFIED (spike step 2).
  - Stages: Stages.cpp:486-489 uses the plugin's own predicate.
  - The v1 thumbnails include the lights, because they are part of the surface.
- **Size:** M overall, about half of B. Rough, low confidence:
  - ui components plus tokens and the generator: M;
  - the tag helper plus three app adoptions: M;
  - plugin predicate, Stages band, capability and bridges: S-M, plus R13 and C1-C3;
  - Overview band in the shell: S;
  - the session rule: S.
  - The 36-pt capsule restyle of gap 9 is app work on top of this, not part of D.

### Summary
| Criterion | A | B | C | D |
|---|---|---|---|---|
| Lights without the plugin (C2) | app | app fallback + switch | none | app (same code) |
| One renderer for all lights | no (4) | yes with the plugin | yes | no (2, shared tokens + parity test) |
| Drag / double-click owner | each app | app (row split) | plugin strip | ui framework |
| Lights visible to AT-SPI (A1) | uneven | no | no | yes |
| HiDPI alignment | Qt | two renderers | plugin | Qt |
| New protocol | no | yes | no | no |
| Matches the macOS architecture | partly | no (macOS draws in the app) | no | yes |
| Size | M ×3 | L | 0 | M |

## Decision (proposed)
**Option D.**
- It is the macOS model: the shared framework inside the app draws the lights, and the app only declares a toolbar style.
- No hard constraint on Hyprland 0.56.2 prevents it.
- The constraints that hurt B do not apply to it:
  - C2 needs app-drawn lights anyway, so B contains D.
  - Hyprland offers no channel for client-declared geometry or state, so B needs a new protocol.
  - Compositor-drawn controls fail A1.
  - One row split across two processes risks misalignment, and a gap or double draw at plugin load and unload.
- B's single advantage, one renderer for every light, is recovered by three measures: one token source, a parity check,
  and the plugin parity slice (Q2).
- Implementation starts only after the spike below passes and the owner answers Q1-Q6.

### Owner answers (2026-10-20)
- Q1: (a) option D, grassfield-ui draws the lights inside the app.
- Q2: (a) the plugin parity slice ships before or with the first app.
- Q3: (a) every grassfield-ui window: the main windows of Files, Settings and Preview in the `unified` style, Get Info
  and Customize Folder in the `titlebar` style; KIO and widget dialogs keep the plugin titlebar.
- Q6: (a) Qt private API accepted, isolated in one helper header in `apps/`; the apps are rebuilt with each Qt minor.
- Q4: open until spike steps 4-6 report (native paths first).
- Q5: (a) radius 26 for unified-toolbar windows, 12 for titlebar-style windows, following the macOS model (integrator
  choice under the owner's "macOS model first" rule; judged at the F1 review).

## Test plan (option D)
- **L0.**
  - `tests/unit/tst_windowcontrols.qml`:
    - geometry per style: centre 25.75 ± 0.01 in `unified`, pitch 23, hit radius;
    - states: active, inactive, hover, pressed, disabled, full screen;
    - the double-click setting.
  - `tst_tokens.qml` reference metrics: 52, 14, 9, 25.75.
  - compositor GTest:
    - the tag predicate;
    - the Stages band per window;
    - the capability list;
    - the generated light constants equal what the titlebar draws.
  - `Hyprland --verify-config` on the rule.
- **L1, nested.** A new `tests/compositor/client_chrome.sh` with a fixture, run with the plugin and with `--no-plugin`:
  1. Tagged window: no plugin strip. Untagged dialog of the same app id: strip kept (`scripts/nestctl clients -j` and a
     screenshot).
  2. Real clicks through `scripts/dev/pointer.sh`:
     - close closes the window;
     - minimize goes to the Dock tile (gfc `minimized`, `special:minimized`);
     - zoom gives `FSMODE_MAXIMIZED`, and a second zoom returns to the same box (as `zoom_restore.sh`).
  3. Drag: a drag on empty row space moves the window by Δ; a drag on an item does not. Double-click for each
     `titlebarDoubleClick` value (as `double_click_setting.sh`).
  4. Visual states: grey when inactive, glyphs on hover, lights hidden in full screen (screenshots and pixel samples).
  5. Overview v2 and Stages: no empty band above tagged windows (screenshots and layout logs).
  6. Plugin unload and reload while the window is mapped: never two sets of lights, never a strip.
  7. The fixture in the `soak.sh` window churn (C1).
- **Screens.**
  - `scripts/dev/shot.sh` on GF-REF: `client-chrome-{files,settings,preview}-{active,inactive,hover}.png`.
  - A side-by-side with a foot window (plugin titlebar) for the parity check, at scale 1 and 1.5.
  - The A2 contrast check of the glyphs on the lights, and the F1 sign-off by the owner.
- **Review.** R13 for the plugin. The ui public QML API change (a semver minor, master-prompt.md:304). The apps.

## Owner questions (recommended proposal first)
1. **Who draws the lights in Grassfield apps?**
   (a) grassfield-ui inside the app (option D).
   (b) The plugin, over the app's row (option B: a new protocol; the app still draws them without the plugin).
   (c) Keep two rows (option C) until after M5.
2. **When do third-party windows get the same lights?** The plugin parity is hover glyphs, grey when inactive, and
   14-pt lights 9 apart (gap 2).
   (a) One compositor slice, before or with the first app.
   (b) Apps first, plugin later, with a visible mismatch meanwhile, listed under STATE placeholders.
   (c) App lights limited to the plugin's current look until parity.
3. **Which windows draw their own chrome?**
   (a) Every window built from grassfield-ui:
       - the main windows of Files, Settings and Preview in the 52-pt `unified` style;
       - Get Info and Customize Folder in the `titlebar` style of the same component;
       - KIO and widget dialogs keep the plugin titlebar.
   (b) The three main windows only.
   (c) (a), plus Glance moving from `decorate = false` to the same mechanism. Glance would then get close and full-screen
       circles (f1-reference-gaps.md:232).
4. **Minimize and zoom without the plugin.** This only matters if spike steps 4-5 find no native path.
   (a) Hyprland's native paths only:
       - exempt client-chrome windows from `gf-no-maximize-event`;
       - the shell handles Hyprland's minimize report;
       - the lights then behave the same with and without the plugin.
   (b) A plugin bridge. Without the plugin, the app greys minimize and zoom. It learns that the plugin is absent from a
       runtime file the shell writes from the capabilities (a new small contract).
   (c) A plugin bridge, with inert lights without the plugin as a documented limit. Not recommended: R11.
5. **Corner radius of unified-toolbar windows.**
   (a) 26, set by the same session rule (gap 1); titlebar-style windows keep 12.
   (b) Keep 12 everywhere for now.
6. **Qt private API in the apps (needed to tag a window).**
   (a) Accept it, isolated in one helper header in `apps/`. The apps are then rebuilt with each Qt minor, as Quickshell
       already is.
   (b) No private API: keep option C until Qt ships its own xdg-toplevel-tag support (date unknown).

## Spike plan (smallest nested proof of D, before any implementation)
- **Owner.** compositor-engineer, about one day. The code stays under `.dev/spike/client-chrome/` and is not committed.
  Nested only, with headless GF-REF.
- **Fixture, about 150 lines.** A Qt 6.11 `QApplication` with app id `org.grassfield.SpikeChrome`:
  - One QML window with a 52-pt row and three 14-pt lights.
  - A `DragHandler` on empty row space calls `startSystemMove()`.
  - A double-tap calls `showMaximized()` / `showNormal()`.
  - The minimize light calls `showMinimized()`.
  - C++ binds `xdg_toplevel_tag_manager_v1`, with code generated from
    /usr/share/wayland-protocols/staging/xdg-toplevel-tag/xdg-toplevel-tag-v1.xml, and tags the window on
    `surfaceRoleCreated()`.
  - A second, untagged `QDialog` uses the same app id.
- **Plugin prototype, about 40 lines.**
  - `shouldShow()` returns false for the tag.
  - A per-toplevel `stateChanged` listener logs `requestsMinimize` and `requestsMaximize`.
  - A `requestMove` listener logs the requests.
- **Dev config.** The rule above.

| # | Step | Pass |
|---|---|---|
| 1 | `Hyprland --verify-config` on the rule | the `xdg_tag` match key and `tag` effect are accepted |
| 2 | Map both windows; `scripts/nestctl clients -j`; `scripts/dev/shot.sh` | the main window has the xdg tag and `grassfield-client-chrome` and no strip; the dialog has a strip; Hyprland's border and shadow stay on the main window. Repeat with `decorate = false` and record whether the shadow goes. Record whether the client JSON lists tags |
| 3 | `scripts/dev/pointer.sh`: drag 200,100 on empty row space, on a light, and on a zoomed window | moves by (200, 100) ± 1; no move from a light; record what Hyprland does with a maximized window (refuse, move maximized, un-zoom) and whether it snaps |
| 4 | Double-tap with `gf-no-maximize-event` on, then with the window exempted | on: the plugin log shows the request and Hyprland ignores it; exempted: `FSMODE_MAXIMIZED`, then back to the same box |
| 5 | Minimize light, with a socket2 listener as in the existing tests | record whether Hyprland posts its own `minimized` report; the plugin log shows `requestsMinimize` |
| 6 | `scripts/dev/nested-up.sh --no-plugin`, steps 2-5 again | lights drawn, close and drag work; zoom and minimize outcomes recorded (Q4) |
| 7 | Shot next to a foot window with the plugin titlebar, then at scale 1.5 | light centres at 25.75 ± 0.5 px at scale 1; crisp at 1.5 |
| 8 | Unload and reload the plugin while mapped; `tests/compositor/soak.sh 300` | no Hyprland crash, no stale strip |

**If a step fails:**
- **Step 2** (the tag is not applied at map): check whether Hyprland applies rules again when the tag changes. If not,
  return to the owner with a rule on the class plus "no parent window".
- **Step 3** (the move is refused or wrong): the plugin handles `requestMove` with its own titlebar drag. If Hyprland's
  handler cannot be kept out of it, the question goes back to the owner.
- **Step 5** (no native report): minimize goes through the plugin bridge, and Q4 decides the degraded behaviour.

## Consequences
- **Two renderers for the lights.** grassfield-ui draws them for Grassfield apps and the plugin for SSD windows.
  - Generated constants and the parity check keep them equal.
  - E18 in docs/legal/visual-review.md gets a second source file.
  - Lights inside the toolbar at the macOS position bring the trade dress closer: "needs legal review".
- **New additive contracts:**
  - the gfc/1 feature `client-chrome`;
  - the Hyprland tag `grassfield-client-chrome`;
  - the role tags of Grassfield windows;
  - ui components `WindowControls` and `UnifiedToolbar` (semver minor).
- **Packaging.** Plugin and apps ship from the same release (double lights otherwise). With Q6(a), the apps depend on
  Qt private API and are rebuilt with each Qt minor.
- **Overview v2 and Stages:** the band becomes per window. The token `overview.windowTitlebarHeight` stays for
  plugin-decorated windows.
- **Not in this ADR:**
  - The tiling popover on hover of the green light (gap 20). Under D it needs an app → shell path for client-drawn
    lights, which would be its own ADR. The plugin can raise it for SSD windows.
  - The 36-pt capsules and the search circle (gap 9, second half) are app slices that build on `UnifiedToolbar`.
- **Re-verify on every Hyprland update:**
  - the plugin reads `CWindowRuleApplicator::m_tagKeeper`;
  - the plugin may listen to `CXDGToplevelResource::m_events.{stateChanged, requestMove}`;
  - the Lua keys `xdg_tag` and `tag`.

## Implementation notes: spike results (2026-10-22)
**Setup.** Hyprland 0.56.2 (commit efb50993, `scripts/nestctl version`), Qt 6.11.2, nested on headless GF-REF
1920x1080. The spike code stays in `.dev/spike/client-chrome/` (git-ignored, not committed):
- fixture: `QApplication`, app id `org.grassfield.SpikeChrome`, a QML window with a 52-pt row and three 14-pt lights
  (centre 25.75, pitch 23), tagged `browser` on `surfaceRoleCreated()`, plus an untagged `QDialog`. The tag client code
  is generated by `qt6_generate_wayland_protocol_client_sources` from the staging XML;
- plugin prototype: a scratch copy of `compositor/` (0.8.2), built to `.dev`. `shouldShow()` returns false for the
  `grassfield-client-chrome` tag; per-toplevel `stateChanged`/`requestMove` listeners log the requests, the window's
  `m_suppressedEvents` and its fullscreen modes. Loaded with `scripts/nestctl plugin load <.dev path>`;
- dev rule: `.dev/spike/client-chrome/rule.lua` (the rule above, class list plus `SpikeChrome`), added at runtime with
  `scripts/nestctl dispatch 'function() dofile("…/rule.lua") end'`.

Captures are in `.dev/shots/` and logs in `.dev/spike/client-chrome/logs/` (both git-ignored). The 1-min load during the
nested runs was 6.1–11.3:
- plugin session: 7.67, 7.33, 6.73 (soak start), 11.34 (after the soak), 10.17;
- no-plugin session: 6.06–6.33.

2–4 other nested sessions were running.

| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `Hyprland --verify-config` on the rule: exit 0, `config ok` |
| 2 | PASS | tag present at map; no strip on the tagged window, strip on the dialog; border and shadow kept |
| 3 | FAIL | (190, 95) instead of (200, 100); a zoomed window is un-zoomed and centred on the pointer, row off-screen |
| 4 | PASS, with a defect found | suppressed: logged and ignored; exempted: `FSMODE_MAXIMIZED`, then the same box |
| 5 | PASS (recorded) | `requestsMinimize true` logged; Hyprland posts no `minimized` event and does nothing |
| 6 | PASS | no plugin: lights drawn, close and drag work; zoom works when exempted; minimize has no effect |
| 7 | PASS | centre (25.75, 25.76) at scale 1; (25.75, 25.75) pt at 1.5, crisp |
| 8 | PASS | two unload/reload cycles while mapped; `tests/compositor/soak.sh 300`: PASS |

**Step 1.** `GRASSFIELD_CONFIG_DIR=<tree>/config/hypr Hyprland --verify-config --config .dev/spike/client-chrome/verify.lua`
(the core config plus one variant file):
- the rule: exit 0, `config ok`. Variants: `decorate = false` exit 0; the Q4(a) exemption
  `match = { class = ".*", xdg_tag = "negative:.+" }` on `gf-no-maximize-event` exit 0.
- Negative control, a misspelled key: exit 1, `hl.window_rule: unknown match property 'xdg_tagg'`.
- **Q5 finding:** `rounding = 26` in the rule: exit 1, `hl.window_rule: field 'rounding': value 26 is more than the
  maximum of 20` (also in LuaBindingsInternal.hpp: `CLuaConfigInt(0, 0, 20)`). Q5(a) "radius 26 set by the same session
  rule" cannot be done with a 0.56.2 window rule.

**Step 2.**
- The fixture sends `set_toplevel_tag(xdg_toplevel, "browser")` before the toplevel's initial `wl_surface.commit`
  (`WAYLAND_DEBUG=client`, logs/fixture-A2.log).
- The plugin's first `updateRules` line for the window, before `open`, already shows `xdgTag browser tags
  [grassfield-client-chrome*]`, so the tag is applied at map. No re-check path was needed.
- `scripts/nestctl clients -j`: the main window has `"tags": ["grassfield-client-chrome*"], "xdgTag": "browser"`; the
  dialog has `"tags": [], "xdgTag": ""`.
  - The client JSON lists both fields, so Overview can read them. The dynamic tag carries a `*` suffix, which a match
    on the JSON must accept.
  - Not checked: whether Quickshell's Hyprland window data exposes these fields.
- Capture `spike-A-s2-plugin.png`: the main window has no strip and draws its own lights; the dialog has the plugin
  strip; the shadow is under the main window.
- `decorate = false` variant (`spike-A-s2-decorate-false.png`, same window box), sampled with ImageMagick:
  - the shadow goes: pixel (600, 775) is (37,86,50) by default and (46,107,63), the bare background, with the variant;
  - the border goes: column x=559 is (44,78,92) by default and equals the outside pixel with the variant.
  - `scripts/nestctl decorations address:…` still lists Drop Shadow, Border, Inner Glow and grassfield-titlebar: the
    effect stops the drawing, not the objects.
  - This confirms the ADR's choice not to use `decorate = false`.

**Step 3** (`scripts/dev/pointer.sh`; the fixture starts `startSystemMove()` from a `DragHandler`).
- Drag (200, 100) on empty row space: the window moved (190, 95), from (2000, 261) to (2190, 356). FAIL against ± 1.
  - Cause: the `DragHandler` activates after Qt's drag threshold. Fixture log: `startSystemMove at 510 31` for a
    press at (500, 26), i.e. after the first 20-step increment.
  - A slow start (20 px to the right, then to a net (-200, -100)) moved the window (-209, -100). So Hyprland's move
    follows the pointer exactly from the moment the request arrives, and the window lags the pointer by the threshold.
  - Variant `--move-on-press` (`startSystemMove()` on the press): exactly (200, 100), (2000, 261) → (2200, 361). The
    app still sees both presses, so it can detect a double-click from two presses within the double-click interval
    (logs/fixture-A6.log, fixture-A9.log).
- Drag from the zoom light and from a toolbar item: no move, no click. PASS.
- Snap: Hyprland's move snaps (`general:snap:enabled` true, `monitor_gap = 8`). A drag aimed at a left edge 4 px from
  the output edge ended at local x = 1, with the 1-px border on the edge. The plugin's own titlebar drag does not snap
  (compositor.md:975).
- Zoomed window (maximize exemption active): a drag of (200, 100) from the row un-zooms the window (fullscreen 0, back to
  800x500) and centres it on the pointer, at local (700, -124). The row and the lights are above the output, under the
  menu bar (`spike-A-s3-zoomed-drag.png`). Same with `--move-on-press`.
- **Branch applied:** "Step 3 (the move is refused or wrong)": the plugin would handle `requestMove` with its own drag
  (FR8 un-zoom under the pointer).
  - Keeping Hyprland's handler out is not possible through a documented hook. `CWindow::m_listeners.xdgMoveRequest` is
    public (Window.hpp:459), so a plugin could drop it, but it cannot restore it at unload: `onXDGMoveRequest` is private.
    Not tried.
  - As the ADR says, the question goes back to the owner.
  - The plain-drag lag has an app-only fix: start the move on the press.

**Step 4.**
- With `gf-no-maximize-event`:
  - the plugin logs `requestsMaximize false … suppressedEvents 0x2 fs internal 0 client 0`;
  - Hyprland ignores the request: `clients -j` shows `"fullscreen": 0` and the window keeps 800x500.
- With the window exempted (the rule's match extended with `xdg_tag = "negative:.+"`):
  - the window maps with `suppressedEvents 0x0`;
  - the first double-tap gives `"fullscreen": 1, "fullscreenClient": 1`, 1918x972 at (1441, 25);
  - the second returns it to (2000, 261) 800x500. Reproduced with the plugin (fixtures A3 and A8) and without it
    (B2, step 6).
- **Defect found: Qt's maximized state is inverted in the Grassfield session.**
  - Hyprland sends the xdg `maximized` state to these floating windows. Qt reports `Window.Maximized` (visibility 4) for
    the 800x500 floating window after every configure (logs/fixture-A2.log, fixture-A3.log). Window.hpp:196-197:
    "Hyprland sends XDG_TOPLEVEL_STATE_MAXIMIZED to tiled windows to suppress CSD".
  - So Qt never sends `set_maximized` for a normal window: `showMaximized()` sends nothing. Every zoom request is an
    `unset_maximized`.
  - Hyprland toggles `FSMODE_MAXIMIZED` on any maximize request, whatever its value. The plugin logs
    `requestsMaximize false … fs internal 1 client 1` after Hyprland's own handler ran.
  - The exempted zoom therefore works only by this double inversion. The app must not take its zoom state or its glyph
    from Qt's `visibility`, and the behaviour must be re-verified on every Hyprland update.
- **Test caveat.** Each plugin unload or load makes Hyprland re-apply its config. That drops rules added at runtime:
  - after the step-8 reload, fixture A7 ran suppressed (`suppressedEvents 0x2`, logged);
  - fixture A6 behaved the same (not logged).
  - A rule in the session config is not affected.
- Re-registering a named rule merges the given fields into the existing rule: `decorate = false` stayed after
  re-registering the rule without it.

**Step 5.** A click on the minimize light:
- the fixture sends `xdg_toplevel.set_minimized()` (WAYLAND_DEBUG);
- the plugin logs `requestsMinimize true`;
- Hyprland does nothing: the window stays mapped and visible on workspace 2. Qt's visibility goes 3 → 2 at once.
- No `minimized>>` event among the 894 socket2 events of the whole plugin session (logs/socket2-A.log). The only
  `special:minimized` moves are the soak's plugin minimizes.
- **Branch applied:** "Step 5 (no native report)": minimize goes through the plugin bridge (`stateChanged` with
  `requestsMinimize` → the existing `minimize-request`, FR6), and Q4 decides the degraded behaviour.

**Step 6** (`scripts/dev/nested-up.sh --no-plugin`; `scripts/nestctl plugin list`: `no plugins loaded`).
- Step 2 again: the rule still applies (`"tags": ["grassfield-client-chrome*"], "xdgTag": "browser"`).
  `spike-B-s2-noplugin.png`: the fixture draws its lights; the dialog has no titlebar.
- Step 3 again: a row drag moves the window (190, 95), as with the plugin. A drag from a light does not move it.
- Step 4 again:
  - suppressed: `unset_maximized` sent, ignored;
  - exempted: `fullscreen>>1`, 1918x972, then `fullscreen>>0` and back to (2000, 261) 800x500, both through
    `unset_maximized` (logs/fixture-B2.log, socket2-B.log).
- Step 5 again: `set_minimized` sent; the window stays mapped on workspace 2; no socket2 event follows the click.
- Close light: `xdg_toplevel.destroy`, then `closewindow>>`. Close works without the plugin.

**Step 7** (`spike-A-s7-scale1.png`, `spike-A-s7-scale15.png`; tool `.dev/spike/client-chrome/measure.py`, a
coverage-weighted centroid within each light's 23-pt cell, checked to ± 0.01 px on synthetic circles).
- Scale 1, next to a foot window with the plugin titlebar:
  - close (25.75, 25.76), minimize (48.76, 25.76), zoom (71.76, 25.76) px from the window's top-left;
  - diameter about 13.9 px. PASS (± 0.5).
- Scale 1.5 (`scripts/nestctl dispatch 'function() hl.monitor({…, scale = 1.5}) end'`):
  - Hyprland draws the surface from device (150, 392). The logical y of 261 × 1.5 = 391.5 is rounded up, under a 2-px
    border.
  - From that origin: close (38.62, 38.62) device px = (25.75, 25.75) pt, pitch 23.00 pt.
  - From the unrounded logical origin, y is 26.08 pt.
- Crisp:
  - a vertical profile through the close light has one partial pixel at each edge (rendered at 1.5, not scaled up);
  - 8x crops `logs/s7-scale15-lights-x8.png` and `s7-scale15-foot-x8.png`: the plugin's lights are crisp at 1.5 too.

**Step 8.**
- Unload, then reload, with the fixture and a foot window mapped (11:00), and again at 11:14 for a rebuilt prototype.
  - `scripts/nestctl version` answers after each unload.
  - `spike-A-s8-unloaded.png`: foot's strip is gone, the fixture keeps its lights, the shell shows its degraded notice.
  - `spike-A-s8-reloaded.png`: foot's strip is back and the fixture has no strip. Never two sets of lights, no stale
    strip.
- `tests/compositor/soak.sh 300` (load 6.73), with the fixture mapped:
  - `soak: PASS`, 307 s, 45 rounds, Hyprland alive;
  - RSS 156648 → 162172 kB, `No coredumps found.`, grassfield exceptions 0;
  - log `.dev/soak-20261022-110115.log`.
  - The soak reported `minimize pairs 0 (skipped, no move seen: 5)` and 2 minimizes animated. That is the soak's own
    Dock check, not the spike.

**Q4 recommendation** (minimize and zoom without the plugin): split it.
- **Zoom: (a), native.** Change `gf-no-maximize-event` to `match = { class = ".*", xdg_tag = "negative:.+" }`. Zoom
  then behaves the same with and without the plugin.
  - Cost: every window that sets any xdg tag, not only Grassfield's, may maximize itself.
  - Cost: the app must send one maximize request per zoom and never read Qt's maximized state (step 4 defect).
- **Minimize: (b), plugin bridge.** Hyprland has no native path: no report, no state change. Without the plugin the app
  greys the minimize light; it learns that the plugin is absent from the shell's capabilities file.
  - (a) is impossible for minimize. (c) leaves an inert light (R11).
- **Still open for the owner:**
  - dragging a zoomed window (step 3 branch);
  - Q5's radius 26 (step 1 finding).

**Not verified:**
- Window data and bands:
  - whether Quickshell's Hyprland window data carries `tags` and `xdgTag`;
  - the Overview v2 and Stages bands (L1 item 5).
- The fixture's lights:
  - AT-SPI exposure (A1);
  - hover glyphs, the inactive grey and the full-screen hide: the fixture has none.
- Hyprland internals:
  - the contents of the xdg state arrays: WAYLAND_DEBUG prints only their length, and the `maximized` state is inferred
    from Qt and Window.hpp:196-197;
  - why Hyprland toggles on any maximize request: observed only, no source read;
  - detaching `m_listeners.xdgMoveRequest` from a plugin.
- Not exercised:
  - real KIO widget dialogs: a plain `QDialog` stood in;
  - scale 1.5 without the plugin, and several monitors;
  - clang-tidy on the prototype, which is not committed.
- One spike-only incident: a Hyprland "not responding" dialog (`hyprland-dialog`, ANR manager) appeared once at load
  10.2 during a double-click on fixture A9. That attempt was discarded and repeated; its cause was not identified.

## Integrator decisions after the spike (2026-10-22)
The owner asked for decisions without questions (2026-10-21, the maintainers' project log); the macOS model decides the open points.
- **Q4: the spike's split is accepted.** Zoom is native: `gf-no-maximize-event` matches `xdg_tag = "negative:.+"`, and
  the app sends one maximize request per zoom and never reads Qt's maximized state (step 4 defect). Minimize goes
  through the plugin bridge (`requestsMinimize` → `minimize-request`, FR6); without the plugin the app greys its
  minimize light, from the shell's capabilities.
- **Dragging a zoomed window (step 3).** macOS 26: dragging a window that fills the screen from its toolbar takes it
  out of that state at its previous size, and the window stays under the pointer at the same place in its toolbar row.
  So the plugin handles `requestMove` for tagged windows. If the window is zoomed, it restores the remembered box,
  places it so the grab point keeps its horizontal ratio and the toolbar row stays under the pointer, then starts the
  move. The 10 px lag of the move (190 for 200) is Qt's drag threshold and stays, as macOS also has a threshold.
- **Q5, radius 26 (step 1).** Hyprland 0.56.2 rejects `rounding` above 20 in a rule. Tagged windows get 20 with the
  session's `rounding_power`, the closest native shape, as F2a does for `org.grassfield.*`. A plugin-drawn corner mask
  is considered only if the owner's F1 review finds the difference visible.
  - **Correction (F2a, 2026-10-22):** 26 is native through the global `decoration.rounding`; only per-window rules are
    capped at 20 (`--verify-config`: `decoration = { rounding = 26 }` config ok; the rule: "value 26 is more than the
    maximum of 20"). F2a sets the global 26 and gives every class that is not `org.grassfield.*` the radius 12 with a
    negated whole-class rule (`negative:^org\.grassfield\..*$`; 12 is under the cap), measured getprop 26 / 12.
    Tagged unified-toolbar windows get 26 the same way: the 12 rule must exclude them too (by tag or class), no
    rule may raise a window above 20.
- **Status:** accepted with these decisions. Next slices, in order:
  1. plugin parity: the tag rule, `requestMove` un-zoom, the minimize bridge for tagged windows, C2 behaviour;
  2. the grassfield-ui `WindowControls` / `UnifiedToolbar` components;
  3. F2b: sidebars and toolbars of Files, Settings and Preview.

## Implementation: app side (2026-10-23, remediation wave 2) and the plugin work item
Owner decision D-5 (accepted) and D-7 (window menu keyboard access plus app-drawn controls, A1 amended). The app side of
option D is implemented; the plugin and session-config side is written down here as a work item for the compositor
agent (the files are outside this slice).

### Done (grassfield-ui and the apps)
- **Tokens** `window.*` in `ui/tokens/tokens.json` (14, 9, 52, 25.75, 32, glyph and colour values equal to the plugin's
  `Theme.hpp`); `tests/unit/tst_windowcontrols.qml` checks 52 / 14 / 9 / 25.75 and the geometry of both styles.
- **`WindowControls`** (`ui/Grassfield/Ui/WindowControls.qml`, `WindowLight.qml`, `WindowGlyph.qml`): 14-pt lights, glyphs on
  group hover, grey when the window is inactive (coloured again under the pointer), pressed state, disabled state,
  hidden in full screen. Accessible buttons named Close, Minimize, Zoom, each with a press action that refuses a disabled
  light (R12); not in the Tab chain (macOS); the keyboard routes are the shell's Window menu and Super+W, Super+M and
  Super+Alt+F (bindings.lua).
- **`UnifiedToolbar`** (`UnifiedToolbar.qml`): `unified` (52) and `titlebar` (32) styles, title, `leading` / `trailing` rows
  and a free layer; empty space drags the window (`startSystemMove()` after Qt's drag threshold, decision "Dragging a zoomed
  window" above) and a double-click follows `windows.titlebarDoubleClick` (`zoom`, `minimize`, `none`).
- **Actions** (`WindowActions.js`) are plain xdg-toplevel requests made by Qt: close, `set_minimized`, and zoom.
  - Zoom reads Qt's visibility only to pick the request: `showNormal()` when Qt believes the window is Maximized (always,
    in the Grassfield session: the step 4 defect), `showMaximized()` otherwise. It never draws from that state.
  - **Option(Alt)+click on the zoom light is true full screen** (`showFullScreen()`, and again to leave); the zoom glyph shows
    the full-screen arrows while Alt is held over the group (REQ-ADR0002-6, app-drawn controls).
- **Tag helper** `apps/windowchrome.h`: an application event filter tags each window that declares
  `property string gfChromeRole` (`browser`, `settings`, `viewer`, `info`) with `xdg_toplevel_tag_manager_v1.set_toplevel_tag`
  when its toplevel exists (`surfaceRoleCreated()`), before the first commit. One Qt private header
  (`QtGui/qpa/qplatformwindow_p.h`) and the three requests written by hand on libwayland-client; no generated code. It logs
  `grassfield: window tagged '<role>' (xdg-toplevel-tag)` or `no xdg-toplevel-tag manager`. Build: `Qt6::GuiPrivate` and
  `wayland-client` (CMake), the include paths in each `build-direct.sh`. Packaging must list the libwayland-client
  dependency (makedepends for the Qt private headers come with qt6-base).
- **Adoption (Q3):** Files (`browser`: lights in a toolbar over the sidebar, title and items in the content toolbar; Get Info
  and Customize Folder in the `titlebar` style, role `info`), Settings (`settings`: lights over the sidebar, the section
  title in the content toolbar; the in-page title is gone), Preview main window (`viewer`: its two-line title block and tools
  kept, in the toolbar's free layer). Glance keeps `decorate = false`. KIO and widget dialogs set no tag.
- `windows.titlebarDoubleClick` is read live by each app (Files and Preview in C++ like their appearance, Settings from its
  store).

### Plugin work item (compositor-engineer; also in docs/specs/compositor.md "Plugin work item: client chrome")
Items P1-P7 plus the session config S1-S3 and the shell item H1. **Status (2026-10-23): P1-P7 implemented in plugin 0.14.0**
(feature `client-chrome`; docs/specs/compositor.md "Plugin work item: client chrome" says how each one landed and which
nested assertion covers it). With an older plugin a tagged window still gets the plugin strip above the app's own toolbar
(two chromes). P4 as built: the press on a zoomed tagged window is recorded before Hyprland handles it; the move request
that answers it leaves the zoom (if Hyprland's own handler did not), places the floating size at the press's horizontal
fraction with the toolbar row under the pointer, and restarts Hyprland's move from there (public CLayoutManager calls; the
window's own `xdgMoveRequest` listener is left in place, see spike step 3).
- **P1 predicate.** `isClientChrome(window)`: the window's Hyprland tags hold `grassfield-client-chrome` (the dynamic tag
  prints with a `*`; compare without it). `Titlebar::shouldShow()` returns false for it. Re-evaluated on `window.updateRules`
  (main.cpp:84). Never `decorate = false` (it drops the border and the shadow, spike step 2).
- **P2 capability.** Feature `client-chrome` added to the gfc/1 list (additive, ADR-0007), advertised only when P1 is
  registered.
- **P3 Stages band.** `core/Stages.cpp:486-489` and `Stages.hpp:49` use P1: a tagged window has band 0.
- **P4 `requestMove`.** For tagged windows the plugin handles `CXDGToplevelResource::m_events.requestMove`: zoomed window
  (`FSMODE_MAXIMIZED`) restores the remembered box, places it so the grab point keeps its horizontal ratio and the toolbar row
  stays under the pointer, then starts the move (FR8 for the app-drawn row).
- **P5 minimize bridge.** For tagged windows, `stateChanged` with `requestsMinimize` true runs the existing minimize path
  (the same as the titlebar button, FR6: `minimize-request` to the shell, animation, `special:minimized`). Hyprland does
  nothing on its own (spike step 5).
- **P6 Option+click zoom on the plugin's own titlebar** (REQ-ADR0002-6, plugin part): the green button released with Alt held
  toggles `FSMODE_FULLSCREEN` (menu bar hidden by the shell as in any full screen) instead of `FSMODE_MAXIMIZED`; while Alt is
  held over the group its glyph is the full-screen arrows. Tested in `tests/compositor/titlebar_geometry.sh`-based
  scenarios (a new case in `zoom_restore.sh` with `scripts/dev/keys.sh` holding Alt, or `ZoomOption` gtest).
  - Added on 2026-10-23 (review of part B: no pointer way out of full screen): as on macOS, the pointer at the top edge
    of the monitor reveals the full-screen window's titlebar below the menu bar; its zoom light (arrows) leaves full
    screen and its minimize light is unavailable. Mechanism and limits: docs/specs/compositor.md, work item P6.
- **P7 one token source.** `ui/tools/gen-tokens.py` also writes the plugin's light constants (`kButtonDiameter`,
  `kButtonSpacing`, `kTitlebarHeight`, `kButtonInsetLeft`, colours, glyph ratios) from `window.*`, or a GTest compares
  `Theme.hpp` with `tokens.json` (ADR test plan, "generated light constants equal what the titlebar draws").
- **P8 minimize capability** (added 2026-10-25, GF-056 part 2): a client-chrome window is told it can be minimized
  (xdg `wm_capabilities` with minimize; P5 handles the request); see the amendment of 2026-10-25 below.
- **S1 session rule** (`config/hypr/grassfield/windows.lua`, `--verify-config` accepted the keys in the spike):
  `hl.window_rule({ name = "gf-client-chrome", match = { class = "^org\\.grassfield\\.(Files|Settings|Preview)$", xdg_tag = ".+" }, tag = "+grassfield-client-chrome" })`.
- **S2 maximize exemption (Q4):** `gf-no-maximize-event` becomes `match = { class = ".*", xdg_tag = "negative:.+" }` so a
  tagged window's zoom request is honoured.
  - Revised on 2026-10-23 (review of part B): that match exempted any window with an xdg tag, whatever its toolkit. The
    exemption is now exactly the S1 match: `gf-no-maximize-event` matches every other class
    (`class = "negative:^org\\.grassfield\\.(Files|Settings|Preview)$"`) and `gf-no-maximize-event-untagged` every window
    without an xdg tag (`class = ".*", xdg_tag = "negative:.+"`). It does not match the `grassfield-client-chrome` tag
    itself, because the tag is a dynamic rule effect and the suppression a static one read at map.
- **S3 radius (Q5):** unified windows keep the global 26; windows of role `info` (titlebar style) get 12:
  `match = { class = "^org\\.grassfield\\.Files$", xdg_tag = "^info$" }, rounding = 12`.
- **H1 Overview band (shell, with P3):** `shell/overview/OverviewWindow.qml:105-107` and `:131` use band 0 for windows whose
  Hyprland `tags` hold `grassfield-client-chrome*` when `client-chrome` is advertised; it must land with P1/P3 so that the
  shell's layout and the plugin's drawing agree.
- **C2 behaviour (Q4b, done in the app and shell branch):** without the plugin the app draws its lights and the minimize light is
  greyed and inert, as macOS greys an unavailable action.
  - Channel: the shell writes `{"v":1,"pluginPresent":bool,"features":[...]}` to `$XDG_RUNTIME_DIR/grassfield-capabilities.json`
    (`$GRASSFIELD_STATE_HOME/capabilities.json` in a dev session) once the plugin answered or the hello timed out, and on every
    change (`shell/platform/Capabilities.qml`, format in `CapabilitiesFile.js`). A runtime-dir file never outlives the session.
  - Apps: Files and Preview watch it with `apps/chromecaps.h` (property `canMinimize`), Settings through its backend
    (`WindowActions.minimizeAvailable()`); the light is greyed only when the file says the plugin is absent or has no
    `minimize` feature. A missing or malformed file means "not known": the light stays enabled.
  - Tests: `tst_windowcontrols.qml`, `tst_clientchrome.qml`, gtest `ChromeCaps.*` in `tests/unit/files/tst_appscope.cpp`.
- **S1-S3 and H1 (done in the same branch):** the three window rules are in `config/hypr/grassfield/windows.lua`
  (`tests/shell/client_chrome_rules.sh`: `--verify-config` accepts them, a misspelled key is refused, the tag name is the same
  in the rule, the shell and the spec). Overview v2 reads `tags` from Hyprland's window data
  (`Compositor.windowsAcross`) and reserves no band above a window tagged `grassfield-client-chrome` once the plugin advertises
  `client-chrome` (`shell/overview/ClientChrome.js`, `tst_clientchrome.qml`): without the feature the plugin still draws its strip
  everywhere, so the band stays. Left for the plugin: P1-P7 (P3 must use the same tag).
- **Tests:** `tests/compositor/client_chrome.sh` (assertions 1-9 and which depend on P*/S*, in its header); GTests for P1-P3,
  P5, P7; `tests/compositor/soak.sh` with the Settings app mapped.

### Not verified here (no nested session)
The tag helper against a live Hyprland (the log line above), every visual state, hover glyphs, AT-SPI exposure with a screen
reader (the unit test checks the Accessible properties and press actions only), the TapHandler double-tap in a real session
(Qt's synthetic test events carry no timestamps), and `client_chrome.sh` itself.

## Amendment 2026-10-25: third-party apps that draw their own controls (GF-056)
Third-party apps with their own title bar showed two sets of controls: theirs and the plugin's traffic lights. macOS: a
window has one set of traffic lights, close, minimize, zoom, top-left, and an app that draws its own title bar gets no
second bar from the system.

Research (read only, `/usr/include/hyprland`, Hyprland 0.56.2): is there a per-window signal that a client draws its own
decorations, so that the plugin could step aside without a list?
- xdg-decoration: `CXDGDecoration` keeps `mostRecentlyRequested` / `mostRecentlySent` (protocols/XDGDecoration.hpp), but
  the toplevel-to-decoration map is private (`CXDGDecorationProtocol::m_decorations`, no accessor), and neither
  `CWindow` nor `CXDGToplevelResource` holds any decoration state. The KDE server-decoration protocol is the same
  (`CServerDecorationKDEProtocol::m_decos`, private). A plugin cannot read the request through the installed API.
- It would not be reliable anyway. Hyprland answers server-side: foot started with `csd.preferred=client` drew no bar of
  its own (nested 2026-10-25), so a client that negotiates never shows a second set here. The second set comes from
  clients that draw their frame whatever was negotiated: GTK3/GTK4/libadwaita header bars (they never negotiate, like a
  bare client that draws nothing at all, e.g. a game) and Electron/Chromium custom frames.
- XWayland has `CWindow::m_X11DoesntWantBorders`, but Omarchy runs Electron and Chromium on Wayland
  (`ELECTRON_OZONE_PLATFORM_HINT=wayland`, `--ozone-platform=wayland`), and the field's meaning cannot be read from the
  headers alone: not used.

Decision (after the review of 9c0da79):
- The session's GTK button layout is ADR-0002's `close,minimize,maximize:` (left, macOS order): a default in the Grassfield
  dconf database the package ships (`packaging/dconf/grassfield.d/20-window-buttons.conf`,
  `org.gnome.desktop.wm.preferences button-layout`; not a lock). Before, nothing set it and the session read GNOME's
  `appmenu:close`: header bars and Chromium showed a close button only. The dev session reads the same defaults
  (`scripts/dev/devenv.sh` compiles them into `.dev/dconf` with a profile whose user database is the process's own, isolated
  one; the private bus and its portal get it too). Verified in the nested session: GSettings in a client's environment
  and the settings portal on the private bus both answer `'close,minimize,maximize:'`; Evince (GTK3), Nautilus
  (GTK4/libadwaita) and Chromium draw close, minimize, zoom on the left.
- The tag goes only to apps whose own close, minimize and zoom were seen to work in the nested session
  (`tests/compositor/third_party_chrome.sh`, offline: tag, no plugin strip, the app's zoom button zooms and unzooms, its
  minimize button minimizes toward the Dock tile the shell computed and that tile restores the window, its close button
  closes it, a capture of the title bar): rule `gf-client-chrome-third-party` on `org.gnome.Evince`,
  `org.gnome.Nautilus`, `chromium` (the browser window) and `md.obsidian.Obsidian` (Obsidian's Wayland app id; its
  starter window and a vault window). Captures judged 2026-10-25: Evince (GTK3) and Nautilus (GTK4/libadwaita) show
  close, minimize, zoom on the left of their header bar, one set, the three enabled; Chromium the same on the left of its
  tab strip; Obsidian shows minimize, zoom, close at the top right (it ignores the GTK layout), one set, in both windows.
  The test reaches no network: the clients' proxy is a dead local port and Obsidian's updater is off; earlier runs had
  let Obsidian update itself to 1.14.5 from GitHub, so its results then were for that version, not the installed 1.13.7
  checked now.
- Evince and Nautilus first kept the plugin's bar (726be58): two of their buttons did not work. Both causes are handled
  (GF-056 part 2):
  - Evince's zoom button: our own maximize suppression, not Hyprland. GTK3's button sends `xdg_toplevel.unset_maximized`
    (Hyprland reports a floating window as maximized and tiled), and `gf-no-maximize-event` dropped it for every untagged
    class. Tagged (exempt), the request reaches Hyprland, which toggles the maximized mode (WAYLAND_DEBUG in the nested
    session: `unset_maximized()`, then fullscreen 1; the second press restores the box). The first test also lost clicks
    on a window moved under a resting pointer (no pointer focus without a motion): the test now moves the pointer first.
  - Nautilus's minimize button was greyed: GTK4 offers minimize only when `xdg_toplevel.wm_capabilities` lists it, and
    Hyprland 0.56.2 sends every toplevel fullscreen and maximize (no minimize, no window menu), once, from
    `CXDGToplevelResource`'s constructor (read from the binary: the only call of `CXdgToplevel::sendWmCapabilities`).
    Plugin work item **P8** (docs/specs/compositor.md): while a window is client chrome and the plugin's minimize bridge
    (P5) runs, the plugin sends it wm_capabilities again with minimize added (fullscreen, maximize, minimize: Hyprland's
    own, in its order, plus minimize), then a configure, as xdg-shell asks when the capabilities change. That configure
    is Hyprland's own full one (`setSize` with the size it already asked for: an `xdg_toplevel.configure` with its
    current states, then the `xdg_surface.configure`); a bare `xdg_surface.configure` made GTK4 drop its activated and
    tiled states. The toplevel's `wl_resource` is private in `CXDGToplevelResource`: the plugin finds it among its
    client's resources (`wl_client_for_each_resource`, interface `xdg_toplevel`, `CXDGToplevelResource::fromResource`).
    A client older than xdg_toplevel v5 gets nothing (it never had the event). Re-evaluated on `window.updateRules` (the
    tag can come or go); on unload every window told minimize is told Hyprland's own capabilities again. The button
    sends `set_minimized`, which P5 already routes to the titlebar light's path: `minimize-request` to the shell, its
    Dock tile, the effect the settings choose (funnel in the nested run), restore from the Dock.
- Not on the list, the plugin's titlebar kept:
  - Chromium's `--app` windows (Omarchy's web apps, class `chrome-<site>-<profile>`): they draw no frame; one set, the
    plugin's.
  - Not verified, so not listed: VS Code and its builds, Discord, Slack, Spotify, Brave, Chrome, Pinta, Disks, the GTK
    portal's dialogs. They join once they pass the same nested checks.
- P1 (no titlebar), P3 (no band in Overview and Stages), P4, P5 and P8 follow the tag. The listed apps are exempt from
  `gf-no-maximize-event`, as Grassfield's apps are (Q4): their own zoom control is the only one they have.
  `tests/shell/client_chrome_rules.sh` checks that both maximize negations are built from the two lists.

Consequences:
- An app set to draw no frame of its own (Chromium's "Use system title bar and borders") is still tagged and then has no
  controls: it has to leave the list. A new app that draws its own frame has to join it. Neither is automatic until
  Hyprland exposes a decoration signal.
- Known limit: the listed GTK apps and Chromium draw the buttons the GTK layout names. A user layout without minimize or
  zoom (a `button-layout` set in the user's dconf database beats the Grassfield default, which is not a lock) leaves
  those windows a partial set, and one without any button leaves none; the plugin's titlebar does not come back for them.
  Obsidian ignores the layout. Owner check in a real Grassfield session:
  `gsettings get org.gnome.desktop.wm.preferences button-layout` answers `'close,minimize,maximize:'`.
- Degradation (C1-C3): without the plugin there is no titlebar and no P8: a client sees Hyprland's own capabilities, so
  GTK4's minimize button is greyed again, as macOS greys an unavailable action (nested: plugin unload with Nautilus open,
  `wm_capabilities(array[8])` and a full configure, the button greys and the window stays active at its size; load,
  `array[12]`, enabled again). The maximize exemption and the button layout are session settings: with or without the
  plugin, the listed apps' own zoom works and header bars put their buttons on the left.
- Verified in the nested session (Hyprland 0.56.2 efb50993, 2026-10-25, every client on the private bus with an isolated
  home, offline): `third_party_chrome.sh` PASS (Evince, Nautilus, Chromium, Obsidian 1.13.7 starter and vault windows:
  own zoom zooms and unzooms, own minimize goes to the Dock tile with the funnel in about 504 ms, the tile restores the
  window at its box, focused, own close closes it; Obsidian's log shows the installed package and no update check; foot
  and the web app keep the plugin's strip), `client_chrome.sh` PASS, `chrome.sh` PASS, `minimize.sh` PASS. One set of
  controls on every window tested.

## Amendment 2026-11-03: Q4's zoom becomes Grassfield's Zoom while the plugin's tiling runs (ADR-0036 D78)
Opus review of fix/zoom-is-fill (MAJOR): with Zoom made Fill (ADR-0036 D78), a client-chrome window zoomed two ways.
Settings' own green light (and its toolbar double-click, which reads `fill` as its zoom) sent its maximize request, which
Q4 left to Hyprland: the maximized mode, glued at (1,25) 1918x1054 under the menu bar; Window > Zoom and the light under
its popover filled it at (8,32); the own light on the filled window glued it again, and it never came back to its 740x690.

| Question | Options | Choice | Rule applied |
|---|---|---|---|
| Who handles a client-chrome window's own maximize request (`xdg_toplevel.set_maximized` or `unset_maximized`, which Hyprland toggles whatever its value) now that Grassfield's Zoom is Fill? | (a) the plugin, while it advertises `window-tiling`: it sets `SUPPRESS_MAXIMIZE` on client-chrome windows (only what it set, again on every rule change, cleared at unload) and its xdg `stateChanged` listener turns the request into Grassfield's Zoom (`gf::tiler::zoom`: Fill, and back to the box from before); the echo a client may send right after leaving full screen is swallowed for 1 s, as Hyprland does; without the plugin, or without `window-tiling`, Hyprland's maximized mode as Q4 decided (C2); no app change; (b) the apps ask the plugin through the shell; (c) keep Q4: the app's own zoom stays Hyprland's maximized mode | (a) | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: on macOS a window's green button and its title bar double-click are one Zoom, whoever draws the title bar; (a) gives Grassfield's apps and the third-party apps of the 2026-10-25 amendment the same Fill as the plugin's own light, Window > Zoom and Super+Alt+F, without a change in any app, and the unload gives Hyprland its own handling back; (b) needs every app (Chromium, Obsidian, Evince, Nautilus included) to know the plugin; (c) keeps two zooms. A window of fixed size that sends the request is left as it is (its zoom does nothing, as a disabled zoom light). No user step. |

Unchanged: the session rules S2 (the maximize exemption of the client-chrome list), P4 (a drag from the toolbar of a window
in Hyprland's maximized mode) and P5/P8. A Fill-zoomed window dragged from its toolbar leaves its tile at its size from
before under the pointer (ADR-0036 TL16). Tests: `tests/compositor/zoom_fill_apps.sh` (Settings and Files: own light,
double-click with the default and with zoom, Window > Zoom, the light under its popover, and the plugin unloaded),
`client_chrome.sh`, `third_party_chrome.sh`; units `ClientChromeZoom.*`. Measured in nested on Omarchy 4.0.6
(2026-11-03): Evince and Obsidian's vault window fill from their own zoom button and come back; Chromium fills but sends
no second request, and Nautilus's own buttons do nothing, in that run with Hyprland's own maximize as well (the run's
first check, the desktop portal refused on the private bus, failed too): an environment matter of that test, followed
there, not of this amendment.

## Amendment 2026-11-04: one set of traffic lights on third-party windows: Firefox joins the list, the GTK themes draw the lights
Owner's rc1-22 screenshots from a second machine: Firefox showed the plugin's bar over its own tab strip with Firefox's own
grey controls (two bars, two sets); Chromium, tagged client chrome, showed plain grey glyphs, no lights ("Chrome has no
traffic lights"). macOS model: one set per window, top left, close red, minimize yellow, zoom green, glyphs under the
pointer, grey when inactive; browsers draw these lights in their tab strip.

| Question | Choice | Why |
|---|---|---|
| Firefox | `firefox` and `org.mozilla.firefox` (Flatpak) join `gf-client-chrome-third-party` (and both maximize negations) | The owner's screenshot shows Firefox drawing its own controls with the session's GTK button layout. That its own close, minimize and zoom work here is NOT VERIFIED (not installed on the dev machine, not downloaded); the test stands a foot window with its app id in for the rule only. |
| Google Chrome (`google-chrome`) | left out | No evidence of its Wayland app id on this machine (only Chromium's `chromium` is seen). Add it once the owner shows a `hyprctl clients` class. |
| Lights on GTK client-side buttons | `ui/tools/gen-gtk-themes.py` styles them in all 36 themes (-hc and -dark included) from the plugin's `window.*` tokens: GTK 3 `headerbar`, `.titlebar`, `.default-decoration` `button.titlebutton.close/.minimize/.maximize`; GTK 4 `windowcontrols > button.*` | Same 14 pt disc at pitch 23, colours, inactive grey (backdrop), pressed colour (window.pressedOpacity), glyph (black at window.glyphOpacity, shown while the pointer is over the group; GTK 3: on the hovered light, see Limits), hit slop around the disc, first light centre at 16 (window.titlebarLightInset). -hc adds a ring in the text colour and an opaque glyph. Close glyph is GTK's own icon; minus and plus are drawn as bars (GTK has no plus for zoom). |

Limits (read in source and measured nested at 1.25 with the plugin, `tests/compositor/gtk_lights.sh`):
- GTK 3 never sets `:hover` on the box that holds the title buttons (measured in Evince: the rules first hung on `box:hover`,
  and no glyph appeared, an inactive window's lights stayed grey under the pointer, a held close kept its colour). So in
  GTK 3 (Evince, header-bar apps) the group is not one: the hovered light alone shows its colour (also in an inactive
  window) and its glyph, and the pressed colour is its own; the other two keep their state. GTK 4 (Default, no libadwaita)
  has `:hover` on the ancestors: the glyphs of all three show with the pointer over the group, as the plugin draws them.
  Chromium (GTK appearance) draws the glyph of the hovered light only (its own hover model).
- The lights outrank GTK's own rules: every rule names its light (`.close`, `.minimize`, `.maximize`) and GTK 4's
  `.image-button`, above Default's `button.image-button` (0,1,1) and `windowcontrols button:hover > image` (0,1,3, its own hover
  disc), Adwaita's `button.titlebutton:not(.appmenu)` (0,2,1) and `.default-decoration.titlebar:not(headerbar) button.titlebutton`
  (0,3,2). `tests/ci/gtk_themes.py` computes the specificities and fails under them.
- Geometry from the plugin's tokens: disc 14 pt, pitch 23, first centre at `window.titlebarLightInset` + 7 = 16 from the
  left edge (the plugin's titlebar style, not the 26 of its unified toolbar). A header bar is taller (46 pt) than the plugin's
  bar (32 pt): the lights are centred vertically in the bar, as macOS centres them in its toolbar. The 14 pt disc is 17.5
  device px at 1.25; the plugin rounds to 18, GTK and Chromium draw 17 (measured with the same colour threshold).
- libadwaita apps (Nautilus, most GNOME apps) do not read `gtk-theme` (ADR-0035 D-8), so the themes cannot give them lights;
  GTK has no system-wide user-CSS location (only `~/.config/gtk-4.0/gtk.css`, the user's file, which Grassfield does not
  write). Their buttons keep libadwaita's look and the session's layout. Owner decision needed if lights there are wanted.
- Chromium: a fresh profile (what Omarchy's seed `/usr/lib/chromium/initial_preferences` gives: no theme) is in the Classic
  appearance and draws plain grey buttons, the owner's second screenshot (measured: no light in the capture). With the GTK
  appearance (pref `extensions.theme.system_theme` 1, set in a throwaway profile) it asks GTK and draws our lights. No policy
  or command-line flag selects the appearance. User-level, non-root, supported: chrome://settings/appearance > Theme > GTK, once.
  `initial_preferences` is in /usr/lib/chromium, owned by Omarchy and rewritten by its migrations (root); Grassfield does not
  edit a Chromium profile. No supported default for new users exists from Grassfield.
- Firefox with "Title Bar" on (Customize Toolbar) draws no controls, and the tagged window gets no plugin bar: a window with
  none (checked with a stand-in). Accepted for Firefox, whose default is its own frame (the owner's screenshot); the list rule has
  one entry on the owner's evidence only. A user who turns "Title Bar" on turns it off again for its controls, or the list drops
  Firefox.

Measured (device px, 1.25, light variant; `.dev/gtk-lights`; the dark variant gives the same figures):

| | disc | first centre x | pitch | centre y | glyph on hover | inactive | pressed (close) |
|---|---|---|---|---|---|---|---|
| plugin (foot) | 18 | 20.0 | 29.0 | 20.0 (bar 40) | all three | grey | |
| GTK 3 fixture | 17 | 20.0 | 28.5 | 28.5 (bar 57.5) | hovered one | grey | 119 px of #BA2E42-ish |
| GTK 4 fixture | 17 | 20.0 | 28.5 | 28.5 | all three | grey | 113 px |
| Evince (GTK 3) | 17 | 20.0 | 28.5 | 28.5 | hovered one | grey | 119 px |
| Chromium, GTK appearance | 17 | 19.5 | 28.0 | 25.5 | hovered one | grey | 153 px |
| Chromium, Classic | no lights | | | | | | |

NOT VERIFIED: Firefox (its own close, minimize and zoom, and their look with our theme: the owner checks on the second
machine); Nautilus and other libadwaita apps (no lights by design); Google Chrome.

Tests: `tests/ci/gtk_themes.py` (every theme: token colours, states, selectors, specificity, no `box:hover`, size),
`tests/shell/client_chrome_rules.sh` (Firefox in the list, google-chrome not), `tests/compositor/third_party_chrome.sh` (a
stand-in window for the Firefox rule), `tests/compositor/gtk_lights.sh` (nested: the measures above).

## Amendment 2026-11-07: the plugin reads the decoration protocols (P9); private Hyprland members; a machine-wide browser policy
Owner report on 1.0.0-rc6: Telegram and the ArtCraft suite showed two title bars, Google Chrome (in no list) too, and the
browsers showed no traffic lights. The 2026-10-25 amendment kept the tag to a per-app list because Hyprland 0.56.2 exposes no
per-window decoration signal. P9 (docs/specs/compositor.md) reverses that in part: the plugin reads what each client
negotiated and tags the window itself when the protocol proves a bar of the client's own; the list (S1b) stays for the rest.

| Question | Choice | Why |
|---|---|---|
| What proves that a client draws its own title bar? | Only (a) a KDE server-decoration request for client mode (GTK 3 and GTK 4 header bars, libadwaita), and (b) a client that bound a decoration manager (`zxdg_decoration_manager_v1` or `org_kde_kwin_server_decoration_manager`) and holds no decoration object of either protocol (Qt's frameless window: Telegram). Not an xdg client_side request, not "nothing negotiated". | The first P9 (3ca47a4b) also tagged xdg client_side and a client that negotiated nothing; the review found imv and `foot -o csd.preferred=client` left with no bar at all, as 2026-10-25 had already measured for foot. Chromium asks xdg client_side in both of its title bar modes, so the request cannot tell its modes apart: Chromium, Google Chrome and Electron apps stay in S1b. Invariant: no window may end up with neither the client's bar nor the plugin's; when the protocol cannot tell, the plugin's bar stays, because a second bar can be fixed by the list and a missing one cannot be fixed by the user. Telegram is not listed (its "system window frame" option makes it a plain Qt window, which the list would leave bare). |
| How is the request read? | Hyprland's two private containers (`CXDGDecorationProtocol::m_decorations`, keyed by the `xdg_toplevel` resource; `CServerDecorationKDEProtocol::m_decos`) through an explicit instantiation's member pointers (C++ allows naming a private member there, [temp.spec.general]/6); the requests themselves are public members of the objects (`mostRecentlyRequested`, `m_mostRecentlyRequested`). The manager and the objects of (b) come from libwayland's public list of the client's resources (`wl_client_for_each_resource`, interface names). | No public accessor exists in the installed headers; no offset or layout is assumed: the member pointers' types are checked by the compiler against `/usr/include/hyprland`. Read on the compositor thread, at map, at a commit that changes the surface's size, and on `window.updateRules`; nothing is kept (the `xdg_toplevel` resource is only compared as the map key). |
| What if Hyprland changes those members? | A rename or a new type fails the plugin's build, which a Hyprland update needs anyway (the ABI hash check refuses a plugin built for another Hyprland). A change of meaning with the same type (another key, objects kept elsewhere, entries dropped earlier) makes the lookups miss: every window reads "no object", and (b) then still needs a client with no decoration object in libwayland's own list. What degrades: GTK header bars get the plugin's bar above their own again (two bars; Evince and Nautilus are in S1b and keep one), and every other window keeps the plugin's bar. Never a window without a bar. | Fail toward the plugin's bar, per the invariant. Unit `ClientChromeDecoration.AnObjectNotFoundForTheWindowKeepsThePluginsTitlebar`. Check on every Hyprland update: `tests/compositor/decorations.sh` (D1-D12) with the rebuilt plugin, as for the other internals ADR-0013 lists. |
| Browsers' lights under Omarchy's colour policy | The package installs `zz-grassfield-gtk.json` (`{"BrowserThemeColor": ""}`) in `/etc/chromium/policies/managed` and `/etc/opt/chrome/policies/managed`, both in `backup=`. Machine-wide: the Omarchy session's Chromium and Chrome no longer take Omarchy's theme colour either (accepted in the integrator's review of 3ca47a4b; owner to confirm). | Omarchy's `install/helpers/browser-policy.sh` writes `color.json` (`BrowserThemeColor` from the theme) in those directories (and Edge's and Brave's, which Grassfield does not touch); a colour theme replaces the GTK appearance and its lights in every profile. Read in Chromium's source (data): the policy files merge in lexicographic order, the last one winning (`config_dir_policy_loader.cc`); the empty colour fails the handler's check (`theme_color_policy_handler.cc`, `IDS_POLICY_HEX_COLOR_ERROR`) and sets nothing. Rejected: editing Omarchy's `color.json` (Omarchy's file, rewritten at each theme change), writing browser profiles (Grassfield never does), changing `XDG_CURRENT_DESKTOP` for the browsers (never: it also drives xdg-utils, Qt and the browsers' key store). Removing the package removes the files and Omarchy's colour applies again. |

Left as owner steps (no session-safe default exists, read in Chromium's source: a new profile's appearance defaults to GTK
only on a desktop Chromium reads as GNOME-like, and `initial_preferences` is read only next to the browser's executable):
Settings > Appearance > Mode: GTK, once per Chromium or Chrome profile; the ArtCraft suite's app ids (`hyprctl clients -j`
while it runs) before it can join S1b. Google Chrome (`google-chrome`) joins S1b and both maximize negations on Omarchy's
own browser rule for that class (`/usr/share/omarchy/default/hypr/apps/browser.lua`, `(google-)?[cC]hrom(e|ium)`), instead
of the owner capture 2026-11-04 waited for; Chrome is a Chromium build with the same frame, but its own close, minimize and
zoom are NOT VERIFIED (not installed on the dev machine). Tests: units `ClientChromeDecoration.*`; nested `decorations.sh`;
`tests/shell/client_chrome_rules.sh` (google-chrome now in the three lists, its beta and web apps not);
`tests/shell/session_services.sh` (both policy files in `backup=`).
