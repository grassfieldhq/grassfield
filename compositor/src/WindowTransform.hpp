#pragma once

// Live window transforms shared by the overview and Stages (Hyprland 0.56.2 glue): a Render::IWindowTransformer receives a
// monitor-sized work buffer with the window's main pass (surface, subsurfaces, decorations) at its real place; these
// helpers draw that buffer so that the window's surface box lands on a layout rect (uniform scale, centred), live, without
// resizing or configuring the client. Mechanism: docs/specs/overview.md "v2 spike". Compositor thread only.

#include "core/Minimize.hpp"

#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/helpers/math/Math.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>
#include <hyprland/src/render/Framebuffer.hpp>

#include <cstdint>

namespace gf::transform {

    using Box = gf::minimize::Box;

    Box toBox(const CBox& b);
    CBox toCBox(const Box& b);
    bool hasArea(const Box& b);

    // The window's surface box (hyprctl at/size), layout coordinates.
    Box surfaceBox(const PHLWINDOW& w);

    // What Hyprland adds to a window's position when it renders it (workspace slide, floating offset).
    Vector2D renderOffset(const PHLWINDOW& w);

    // The window's surface box with every decoration extent (titlebar, border, shadow), as drawn at its place.
    Box fullBox(const PHLWINDOW& w);

    // Where the window and its decorations are drawn (layout) when its surface box is fitted into `rect`.
    Box visualBox(const PHLWINDOW& w, const Box& rect);

    // The frame being rendered is a monitor frame (not a snapshot for a close / minimize animation, not a window capture):
    // only then is a window drawn transformed; snapshots and captures show it as it is.
    bool monitorFrame();

    // Draws `in` (the transformer's input) with the window's surface box fitted into `rect` on the monitor being rendered,
    // into a pooled work buffer, and returns it. Without a free work buffer the window is drawn as nothing this frame
    // (never at its real place; `warnedNoBuffer` limits the warning to one line; `address` is for that line only).
    // Without a monitor or an input texture it is drawn as nothing too where possible; `in` is returned unchanged only
    // when the window, the renderer or the monitor being rendered is missing. A window hidden from captures has its fitted
    // surface under a black plate while that monitor is captured (SEC-01, core/CapturePrivacy.hpp).
    SP<Render::IFramebuffer> drawFitted(const PHLWINDOW& w, const Box& rect, const SP<Render::IFramebuffer>& in, bool& warnedNoBuffer, uint64_t address);

    // Clears `in` (the bound work buffer): the window is drawn as nothing on the monitor being rendered.
    SP<Render::IFramebuffer> drawNothing(const SP<Render::IFramebuffer>& in);

} // namespace gf::transform
