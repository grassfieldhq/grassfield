#pragma once

// SEC-01 (docs/specs/security.md SEC11, docs/specs/compositor.md "Capture privacy"): a window with Hyprland's
// no_screen_share rule (the password managers of config/hypr/grassfield/privacy.lua) is black in every capture of a
// display. Hyprland 0.56.2 builds a display capture from the frame the display shows (the monitor's mirror texture), then
// paints one black box over each such window: the window's own box at its real place, with the window's rounding on all
// four corners (src/managers/screenshare/ScreenshareFrame.cpp, CScreenshareFrame::renderMonitor). Whatever the plugin
// draws of that window's pixels outside the box is copied with the frame:
//   - the content's own pixels in the surface's top corners, the titlebar's square join (Titlebar.cpp): the box rounds
//     those corners away (lock_privacy.sh screenshare, 2026-11-09: 98 green px of the Bitwarden fixture);
//   - an overview or Stages miniature (WindowTransform.cpp): drawn elsewhere, the box stays at the real place;
//   - a minimize or restore animation (Minimize.cpp): the window is hidden then, and Hyprland paints no box at all.
// Nothing can be drawn into the capture alone (no capture-only render hook; patching Hyprland is excluded, compositor.md),
// so while a capture of a display is in progress the plugin draws none of that there: the bar colour stays in the
// corners, a black plate covers the miniature's surface, the animation is not drawn. A display is drawn whole when its
// capture state changes, so a capture never copies pixels drawn before it began, and the content comes back on screen
// when it ends. Pure logic, no Hyprland includes: unit-tested in tests/CapturePrivacyTest.cpp.

#include "Minimize.hpp"

#include <cstdint>

namespace gf::privacy {

    using Box = gf::minimize::Box;

    // What counts here of Hyprland's account of one display's captures (CScreenshareManager::SOutputCopyFBState).
    struct CaptureCounts {
        uint32_t sharingSessions = 0; // sessions that copied a frame of the display less than 500 ms ago
        uint32_t pendingFrames   = 0; // frames a client asked for and Hyprland has not copied yet
    };

    // A capture may copy the frame being drawn on the display, or a later frame built on its pixels: every copy is of a
    // pending frame, after a frame drawn while it was pending. Not "any session": Hyprland 0.56.2 keeps a wlr-screencopy
    // client's session once the client is gone (each grim run leaves one), so the content would stay hidden for good.
    bool capturing(const CaptureCounts& counts);

    // Whether the plugin may draw a window's own pixels outside Hyprland's black box on a display. `tracked`: the capture
    // listeners are registered (CapturePrivacy.cpp); without them a change of capture state does not redraw the display,
    // so a protected window's pixels are not drawn there at all, captured or not.
    bool mayDrawContent(bool protectedWindow, bool capturing, bool tracked);

    // One display's capture state as of its last frame.
    struct DisplayCapture {
        bool known     = false;
        bool capturing = false;
    };

    // Before each frame of the display: records `capturingNow` and says whether this frame must be drawn whole. It must
    // when the state changed (a capture began: no pixel drawn before it may be copied; it ended: the content comes back),
    // and on the first frame seen while a capture is in progress (the plugin was loaded during it).
    bool redrawWhole(DisplayCapture& display, bool capturingNow);

    // The black plate over a protected window's miniature: `fitted` (layout) is where its surface box is drawn, on a display
    // at (monX, monY) with `scale`. Display pixels, out to whole pixels and one more on every side: square, so it covers
    // the surface's rounded corners and their antialiased edge whatever the rounding and its power. Empty for an empty or
    // non-finite input.
    Box platePx(const Box& fitted, double monX, double monY, double scale);

} // namespace gf::privacy
