#pragma once

// SEC-01 glue (core/CapturePrivacy.hpp, Hyprland 0.56.2): which windows Hyprland hides from captures, whether a display is
// being captured, and a whole redraw of a display when that changes. Every place the plugin draws a window's own pixels
// (a surface texture, a snapshot, a transformer's input) asks mayDrawContent() first (CapturePrivacyTest checks the
// sources). Not a capability: the shell has nothing to do, and without the plugin Hyprland's own box is all there is.
// Compositor thread only.

#include <hyprland/src/desktop/DesktopTypes.hpp>

namespace gf::capturePrivacy {

    // Listens to every display's frames (render.pre) and to Hyprland's screen-share state. False without the event bus:
    // then mayDrawContent() never lets a protected window's pixels be drawn outside its box, captured or not.
    bool start();

    // Unload: removes the listeners (their callbacks are code of this library) and redraws every display.
    void stop();

    // The window has Hyprland's effective no_screen_share (privacy.lua's rules or any other).
    bool protectedWindow(const PHLWINDOW& w);

    // A capture of `mon` is in progress: a client waits for a frame of it, or one was copied less than 500 ms ago.
    bool capturing(const PHLMONITOR& mon);

    // The plugin may draw the window's own pixels outside Hyprland's black box on `mon` (the display being rendered).
    bool mayDrawContent(const PHLWINDOW& w, const PHLMONITOR& mon);

    // Same, for pixels of a window found protected earlier (a snapshot that may outlive its window).
    bool mayDrawContent(bool protectedWindow, const PHLMONITOR& mon);

} // namespace gf::capturePrivacy
