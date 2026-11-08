#pragma once

// xdg_toplevel_drag_v1 (wayland-protocols staging): the pure state machine behind the plugin's server (ADR-0036 amendment
// 2026-11-08, docs/specs/compositor.md "Toplevel drag (xdg_toplevel_drag_v1)", URR-030). One CDrag per xdg_toplevel_drag_v1
// object: the phase of its wl_data_source's drag, the attached toplevel and where it goes under the pointer, the protocol
// errors the spec mandates. CSources keeps one live object per wl_data_source (invalid_source). No Hyprland or libwayland
// include: unit-tested (compositor/tests/ToplevelDragTest.cpp); the glue (ToplevelDrag.*) feeds it the requests, the drag
// events it observes on the wire and Hyprland's window events.

#include <cstdint>
#include <optional>
#include <unordered_map>

namespace gf::toplevelDrag {

    using Id = uint64_t; // an address (a toplevel, a source, an object), compared, never dereferenced

    struct Point {
        double x = 0.0;
        double y = 0.0;

        bool   operator==(const Point&) const = default;
    };

    // The protocol errors the spec mandates.
    enum class Error : uint8_t {
        None,
        InvalidSource,    // xdg_toplevel_drag_manager_v1.error.invalid_source (0): the source has a live toplevel drag already
        ToplevelAttached, // xdg_toplevel_drag_v1.error.toplevel_attached (0): attach while a toplevel that has its role is attached
        OngoingDrag,      // xdg_toplevel_drag_v1.error.ongoing_drag (1): destroy after start_drag, before the drag ended
    };

    // The drag of the object's wl_data_source.
    enum class Phase : uint8_t {
        Waiting,  // created; wl_data_device.start_drag naming its source not seen yet
        Dragging, // start_drag seen; neither dnd_drop_performed nor cancelled yet (the pointer may be released already: Hyprland
                  // 0.56.2 sends dnd_drop_performed only when the target finishes, see release())
        Ended,    // dropped, cancelled or the source gone: nothing moves any more (a source makes one drag)
    };

    // How the drag ended, as observed.
    enum class EndKind : uint8_t {
        DropPerformed, // wl_data_source.dnd_drop_performed
        Cancelled,     // wl_data_source.cancelled
        SourceGone,    // the wl_data_source was destroyed (undefined by the spec while attached), or Hyprland's drag ended unseen
    };

    // What the end does to the attached window.
    enum class Outcome : uint8_t {
        Drop,   // "as if an xdg_toplevel.move ended": the tiling place shown takes it, else it stays where it is
        Cancel, // the preview goes, nothing moves (the client reverts)
    };

    // A drag that the pointer's release ended is a drop, also when Hyprland cancels it because no client accepted it (a
    // window released over the desktop) or when the target cancels after the release; a cancel without that release (Escape,
    // the client, the source gone) is not.
    Outcome outcomeOf(EndKind kind, bool releaseSeen);

    // One step of the window following the pointer.
    struct Step {
        Point topLeft;       // where the window's top-left (its window geometry, Hyprland's window box) goes
        bool  first = false; // the first step since it follows: the glue may resize it (a tiled window takes back its size)
    };

    // The end of the window's part in a drag: at the release (always a drop), or at the drag's end when no release came first.
    struct End {
        Outcome           outcome = Outcome::Cancel;
        std::optional<Id> toplevel; // the toplevel that followed the pointer until then (attached and mapped), if any
    };

    class CDrag {
      public:
        Phase phase() const {
            return m_phase;
        }

        // The toplevel attached now (nullopt: none, or detached since).
        std::optional<Id> attached() const {
            return m_attached;
        }

        // xdg_toplevel_drag_v1.attach. `mapped`: the toplevel is mapped now. A toplevel mapped later is placed at the pointer
        // minus the client's offset; one mapped already keeps the point the pointer holds (holdAt at the attach, else measured
        // at its first step: it does not jump). ToplevelAttached while a toplevel is attached (the same one included); nothing
        // changes then.
        Error attach(Id toplevel, bool mapped, int32_t xOffset, int32_t yOffset);

        // xdg_toplevel_drag_v1.destroy: OngoingDrag while the drag runs (accepted before start_drag and after the end).
        Error destroy() const;

        // wl_data_device.start_drag named this object's source and Hyprland's drag runs. False (nothing changes) unless Waiting.
        bool start();

        // A pointer button was released during the drag: Hyprland 0.56.2 drops then (CWLDataDeviceProtocol::dropDrag, any
        // button), but keeps the drag's source until the target finishes (dnd_drop_performed comes from completeDrag, run by
        // wl_data_offer.finish), which may be late or never. So the window's drag ends here, as a drop: it follows no more and
        // takes no part in the target any more, whatever comes later. Dragging and not released yet: the release is kept until
        // the drag ends, and the End names the toplevel that followed (the window to place); otherwise nullopt.
        std::optional<End> release();

        // A release came during this drag (sticky until it ends).
        bool released() const {
            return m_released;
        }

        // The drag ended. Dragging: Ended, with the outcome (outcomeOf with the release seen) and the toplevel that followed
        // the pointer, unless the release placed it already (it is detached). Waiting (a source cancelled before its drag
        // began): Ended, nullopt. Ended: nullopt.
        std::optional<End> end(EndKind kind);

        // The attached toplevel mapped (another toplevel: nothing).
        void mapped(Id toplevel);

        // The toplevel unmapped: detached when it is the attached one (true then). A new attach is needed after it maps again.
        bool unmapped(Id toplevel);

        // The toplevel's role was destroyed: detached when it is the attached one (true then).
        bool gone(Id toplevel);

        // The drag moves the attached toplevel now: Dragging, not released, a toplevel attached and mapped.
        bool follows() const;

        // Where the window goes with the pointer at `pointer`, the window's top-left being `topLeft` now; nullopt unless
        // follows(). The first step measures the grab of a window that was mapped when attached.
        std::optional<Step> step(Point pointer, Point topLeft);

        // The glue placed the window itself (a tiled window back at its size from before under the pointer): the grab is
        // measured again from there.
        void regrab(Point pointer, Point topLeft);

        // A toplevel attached while mapped: the point the pointer holds now (at the attach, which Chromium sends right after
        // the press, before start_drag), unless measured already. Nothing for a toplevel not mapped (its client's offset).
        void holdAt(Point pointer, Point topLeft);

      private:
        Phase                m_phase = Phase::Waiting;
        std::optional<Id>    m_attached;
        bool                 m_mapped  = false;
        bool                 m_stepped  = false; // a step happened since the toplevel follows
        bool                 m_released = false; // a pointer button was released during the drag
        std::optional<Point> m_grab;            // the pointer minus the window's top-left (nullopt: measured at the first step)
    };

    // One live toplevel-drag object per wl_data_source (invalid_source while it lives; a source whose object is destroyed may
    // get another one, as KWin allows).
    class CSources {
      public:
        // InvalidSource when `source` has a live object already (nothing changes then).
        Error add(Id source, Id object);

        // The object is destroyed: its source is free again.
        void removeObject(Id object);

        // The source is destroyed.
        void removeSource(Id source);

        std::optional<Id> objectOf(Id source) const;

        bool              empty() const {
            return m_bySource.empty();
        }

      private:
        std::unordered_map<Id, Id> m_bySource;
    };

} // namespace gf::toplevelDrag
