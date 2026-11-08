#pragma once

// xdg_toplevel_drag_v1 server (wayland-protocols staging), Hyprland 0.56.2 glue: a browser tab torn off moves with the
// pointer, drops back into a tab strip, and tiles like any window being dragged (URR-030, ADR-0036 amendment 2026-11-08,
// docs/specs/compositor.md "Toplevel drag (xdg_toplevel_drag_v1)"). The state machine is core/ToplevelDrag.*.
//
// - The `xdg_toplevel_drag_manager_v1` global (version 1) is created with libwayland's wl_global_create on Hyprland's
//   display; its request handlers come from server code hyprwayland-scanner generates from the installed wayland-protocols
//   XML. Lifetime as the appmenu global (AppmenuServer.hpp): at an unload with live client objects the library pins itself,
//   removes the global and leaves the objects inert.
// - Hyprland runs the drag and drop itself (CWLDataDeviceProtocol, unchanged). The plugin sees it on the wire through
//   libwayland's public protocol logger, installed only while a toplevel-drag object waits for or runs its drag:
//   wl_data_device.start_drag naming the object's source begins it, wl_data_source.dnd_drop_performed / cancelled end it. The
//   logger callback records only; the work runs from Hyprland's event loop afterwards. A destroy listener on the source's
//   wl_resource ends it too, and CWLDataDeviceProtocol::dndActive() is checked at every step.
// - While its drag runs, a mapped attached window follows the pointer (a floating move as the plugin's titlebar drag does:
//   snapping, the menu bar clamp, the tiling preview through gf::tiler::dragMotion), and the surface under the pointer
//   other than that window becomes the drag's target (CViewHitTester::windowAt's ignoreWindow, CSeatManager::setPointerFocus;
//   Hyprland's own pointer-focus pass for that motion is cancelled on the bus). The pointer's release ends the window's drag
//   (Hyprland 0.56.2 drops then but sends dnd_drop_performed only when the target finishes): the place shown tiles. A cancel
//   without a release only removes the preview.
// Compositor thread only, nothing blocks.

namespace gf::toplevelDrag {

    // Creates the global and the listeners. False if anything failed (everything registered so far is removed; the feature
    // is then not advertised and clients see no global), and always false in a build without the protocol XML.
    bool start();

    // Unload: the protocol logger, the source destroy listeners, the bus listeners and the scheduled callbacks are removed (all
    // code of this library), a tiling preview of the drag goes, the global goes (live client objects inert, the library
    // pinned, as the appmenu global). A drag in progress goes on as Hyprland's plain drag and drop. Safe more than once.
    void stop();

    // start() succeeded and stop() has not run.
    bool ready();

} // namespace gf::toplevelDrag
