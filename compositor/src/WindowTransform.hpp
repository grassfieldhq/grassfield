#pragma once

// Live window transforms shared by the overview and Stages (Hyprland 0.56.2 glue): a Render::IWindowTransformer receives a
// monitor-sized work buffer with the window's main pass (surface, subsurfaces, decorations) at its real place; these
// helpers draw that buffer so that the window's surface box lands on a layout rect (uniform scale, centred), live, without
// resizing or configuring the client. Mechanism: docs/specs/overview.md "v2 spike". Compositor thread only.

#include "HyprCompat.hpp"
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

    // A transformer's input and output (HyprCompat.hpp: a monitor-sized buffer in 0.56, a canvas around the window in 0.57).
    using Input  = gf::compat::STransformInput;
    using Output = gf::compat::STransformOutput;

    // Where drawFitted draws `w` fitted at `rect` (its visual box), monitor-local logical on `mon`, `w`'s own monitor: the
    // transformer's extents (Hyprland 0.57 clips and damages a transformed window with them; `currentBox` without a window).
    CBox fittedExtents(const PHLWINDOW& w, const Box& rect, const PHLMONITOR& mon, const CBox& currentBox);

    // Draws `in` (the transformer's input) with the window's surface box fitted into `rect` on the monitor being rendered,
    // into a pooled work buffer, and returns it. Without a free work buffer the window is drawn as nothing this frame
    // (never at its real place; `warnedNoBuffer` limits the warning to one line; `address` is for that line only).
    // Without a monitor or an input texture it is drawn as nothing too where possible; `in` is returned unchanged only
    // when the window, the renderer or the monitor being rendered is missing. A window hidden from captures has its fitted
    // surface under a black plate while that monitor is captured (SEC-01, core/CapturePrivacy.hpp).
    Output drawFitted(const PHLWINDOW& w, const Box& rect, const Input& in, bool& warnedNoBuffer, uint64_t address);

    // The window is drawn as nothing on the monitor being rendered: a transparent buffer is returned (one of the transforms'
    // own, cleared where it last held something: usually nothing to clear), else `in` cleared whole (0.56) or no buffer
    // (0.57: nothing is drawn).
    Output drawNothing(const Input& in);

    // Who keeps the transforms' own output buffers (WM-01, WM-02: monitor-sized buffers whose drawn box is known, so a frame
    // clears only that box and the new one instead of a whole buffer per window). They are released, GL context current,
    // once no user is left (the overview closed and Stages draws nothing): call use() before attaching a transformer and
    // release() when the module transforms nothing any more (and on unload: nothing of them may outlive dlclose).
    enum class EUser : uint8_t {
        Overview = 1U << 0,
        Stages   = 1U << 1,
    };
    void use(EUser user);
    void release(EUser user);

    // The damage the monitor's next frame has so far (its damage ring's current region, monitor pixels). Read at render.pre:
    // what changed since the previous frame (a commit, a decoration, a move), before the plugin adds its own.
    CRegion frameDamage(const PHLMONITOR& mon);

    // Where Hyprland draws (and damages) the window at its real place: its full box with every decoration, at its render
    // offset (layout).
    Box realBox(const PHLWINDOW& w);

    // `damage` (monitor pixels of `mon`, frameDamage) touches the layout box `box`. No allocation.
    bool touches(const CRegion& damage, const PHLMONITOR& mon, const Box& box);

} // namespace gf::transform
