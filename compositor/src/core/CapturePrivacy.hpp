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
// The window's bar lies outside the box too: its title is the window's own text.
// Nothing can be drawn into the capture alone (no capture-only render hook; patching Hyprland is excluded, compositor.md),
// so while a capture of a display is in progress the plugin draws none of that there: the bar colour stays in the
// corners, the title is blank, a black plate covers the miniature's surface and its subsurfaces, the animation is not
// drawn. A display is drawn whole when its capture state changes, so a capture never copies pixels drawn before it
// began, and redrawn when the capture ends (Hyprland's word, or a check while one is in progress), so the content comes
// back on screen. Pure logic, no Hyprland includes: unit-tested in tests/CapturePrivacyTest.cpp.

#include "Minimize.hpp"

#include <chrono>
#include <cstdint>
#include <vector>

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

    // The display was capturing at its last frame and is not any more: it must be redrawn for the content to come back
    // (render.pre only runs for a frame something else asked for). Asked when Hyprland says a display share ended
    // (screenshare.state; never for a window share: those leave the displays as they are) and at kEndCheck while a
    // display capture is in progress (a request that dies before its first copy ends with no word). Not while a frame is
    // still pending: the frame is drawn when the display next changes, and redrawing for it would only make the next one.
    bool ended(const DisplayCapture& recorded, bool capturingNow);

    // How often a display capture in progress is checked for an end Hyprland does not report.
    inline constexpr std::chrono::milliseconds kEndCheck{1000};

    // What the plate over a protected window's miniature covers (layout, on the display): the window's surface box
    // `surface` (its real place) and every one of its subsurfaces `parts` (their boxes at the real place too, empty or
    // non-finite ones ignored), mapped as the miniature maps the surface box onto `fitted`.
    Box miniatureCover(const Box& surface, const Box& fitted, const std::vector<Box>& parts);

    // The black plate over that cover (`covered`, layout) on a display at (monX, monY) with `scale`. Display pixels, out to
    // whole pixels and one more on every side: square, so it covers the surface's rounded corners and their antialiased
    // edge whatever the rounding and its power. Empty for an empty or non-finite input.
    Box platePx(const Box& covered, double monX, double monY, double scale);

} // namespace gf::privacy
