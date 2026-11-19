#pragma once

// Stages (Grassfield's stage manager, M5, behind the feature flag config stagesEnabled): Hyprland 0.56.2 glue for
// core/Stages.* (model, validation, geometry). The windows of inactive stages stay mapped on their workspace, at their
// real places, live: a Render::IWindowTransformer draws each one into the shell's strip tile, and a plugin-owned input
// block reason (CWindow::setInputBlocked) keeps pointer and keyboard away from their real places. Nothing is ever moved,
// resized or configured (the one exception: a window a titlebar drag dropped on the strip gets back its place from before
// that drag, dropOnStrip), so turning Stages off or unloading the plugin only detaches transformers and lifts the blocks.
// Compositor thread only, nothing blocks. Spec: docs/specs/stages.md; decision: docs/decisions/ADR-0013-stages.md.

#include "core/Stages.hpp"

#include <hyprland/src/desktop/DesktopTypes.hpp>

#include <optional>

namespace gf::stager {

    // Registers the listeners (nothing is managed until the flag is on and the shell sends op "on"). False if anything
    // failed (then neither stages-available nor stages is advertised; stop() undoes what was registered).
    bool start();

    // Unload: every window back to normal rendering with its input unblocked, pending callbacks and the watchdog removed,
    // {"on":false,"reason":"unavailable"} posted while the event throttle still runs.
    void stop();

    // start() succeeded and stop() has not run.
    bool ready();

    // Window tiling's work area (docs/specs/tiling.md TL1): while Stages is on, the right edge (layout x) of the column
    // `monitor`'s strip holds: its tiles as the shell last sent them with op:on (shown or hidden) plus kStripDropMargin.
    // nullopt when Stages is off or the monitor has no strip.
    std::optional<double> stripColumnRight(const PHLMONITOR& monitor);

    // `w` belongs to an inactive stage (drawn in a strip): tiling neither fills nor counts it (tiling.md TL6, TL10).
    bool inStripStage(const PHLWINDOW& w);
    // The same by window address (compared, never dereferenced): no walk over Hyprland's window list (tiling's per-motion
    // and per-reply paths, WM-13, WM-14).
    bool inStripStage(uint64_t address);

    // Called from the plugin's first pointer button listener, before anything else of the plugin and before Hyprland
    // delivers the button: a pointer focus left on a window Stages blocks (no motion since the block) is refreshed to the
    // surface under the cursor, or the event reaches no surface. Never cancels the event. No-op unless ready().
    void beforePointerButton(bool pressed);

    // The feature flag (config stagesEnabled, off by default). Turning it off ends Stages at once (no animation).
    bool enabled();
    void setEnabled(bool on);

    // The reply of `hyprctl grassfield-stages`: the state of the latest `stages` notice (core stateJson; an "off" state with
    // generation 0 before the first one). Compositor thread.
    std::string stateReply();

    // A validated hl.plugin.grassfield.stages(json) request.
    void request(const gf::stages::Request& request);

    // A refused request: posts the current state with `reason` (nothing changes).
    void refuse(gf::stages::Reason reason);

    // A titlebar drag of `window` released at (x, y) (layout); `tiling`: the release tiles the window. When the release is on
    // the strip of that monitor (core inDropZone, dropAction; macOS: a window dragged onto the strip becomes a stage of its
    // own), the window goes to the strip as a stage of its own (what op move "new" does) and is drawn into its tile from
    // where it was dropped; `before` (its box at the press) given, its real place goes back there once it is drawn in the
    // strip. A stages event follows as for any change. True when it did.
    bool dropOnStrip(const PHLWINDOW& window, double x, double y, bool tiling, std::optional<gf::stages::Box> before);

} // namespace gf::stager
