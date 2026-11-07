#pragma once

// Window tiling (macOS 15+ model with the Windows 11 layouts the owner took; docs/specs/compositor.md FR47-FR50,
// docs/specs/tiling.md TL1-TL15, ADR-0036). A window dragged by its titlebar so that the pointer touches a free left or
// right edge of an output fills that half; near a corner of that edge, that quarter; the pointer on the menu bar fills the
// free area. hl.plugin.grassfield.tile(address, place) places one window (Window > Move & Resize);
// hl.plugin.grassfield.arrange(json) fills a layout of the catalogue with several windows (macOS Arrange, the Layouts
// section). Every window stays a floating window: the plugin only sets its box and keeps a tile record (CTileBook).
// Pure logic, no Hyprland includes: unit-tested in tests/TilingTest.cpp.

#include "ThemeTokens.hpp"

#include <cstdint>
#include <expected>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace gf::tiling {

    // Box in global logical (layout) coordinates.
    struct Rect {
        double x = 0;
        double y = 0;
        double w = 0;
        double h = 0;

        bool   operator==(const Rect&) const = default;
    };

    enum class Place : uint8_t {
        Left,
        Right,
        Top,
        Bottom,
        TopLeft,
        TopRight,
        BottomLeft,
        BottomRight,
        Fill,
        Center,
        LeftThird,
        MiddleThird,
        RightThird,
        LeftTwoThirds,
        RightTwoThirds,
    };

    // Drag geometry (tokens tiling.edge, tiling.cornerBand). The pointer is on an edge when it is within kEdge px of it
    // (the pointer stops at an outer edge); on a corner of a side edge when it is also within kCorner px of the output's
    // top or bottom.
    inline constexpr double kEdge   = theme::tokens::kTilingEdge;
    inline constexpr double kCorner = theme::tokens::kTilingCornerBand;
    // Gap around and between tiled windows when margins are on (token tiling.margin; macOS "Tiled windows have margins").
    inline constexpr double kMargin = theme::tokens::kTilingMargin;
    // The shared-edge handle (TL30): the middle of a shared stretch where a drag moves the whole edge, and its least width
    // across the edge (tokens tiling.handleLength, tiling.handleBand).
    inline constexpr double kHandleLength = theme::tokens::kTilingHandleLength;
    inline constexpr double kHandleBand   = theme::tokens::kTilingHandleBand;
    // Centre: the window keeps its size, at most this fraction of the free area (token tiling.centerMaxFraction).
    inline constexpr double kCenterMaxFraction = theme::tokens::kTilingCenterMaxFraction;

    struct DragOptions {
        bool edges   = true; // "Drag windows to left or right edge of screen to tile"
        bool menuBar = true; // "Drag windows to menu bar to fill screen"
        bool altDrag = true; // "Hold Alt key while dragging windows to tile" (TL18)
    };

    // The output the pointer is on: its full box, the bottom of the menu bar strip (the output's top reserved area), and
    // whether its left / right edges are free (no other output there: a shared edge is a way to the next output).
    struct Output {
        Rect   box;
        double menuBarBottom = 0;
        bool   leftFree      = true;
        bool   rightFree     = true;
    };

    // The place a drag would tile into with the pointer at (x, y), or none.
    std::optional<Place> placeForPointer(double x, double y, const Output& output, const DragOptions& options);

    // TL18: with Alt held, the nearest half, quarter or fill from the pointer's position in the work area `area`, split in
    // thirds across and down: the corner cells give the quarters, the side cells of the middle row the halves, the
    // top-middle cell Fill, the centre and bottom-middle cells the half on the pointer's side. A pointer outside the area
    // (on the menu bar, over the Dock) counts in the nearest cell.
    Place placeForAltPointer(double x, double y, const Rect& area);

    // The place of a drag with the pointer at (x, y) on `output` (nullopt: off it): with Alt held and the Alt drag on,
    // placeForAltPointer in the work area `area`, whatever the edge and menu-bar settings; else placeForPointer.
    std::optional<Place> dragPlace(double x, double y, const Output& output, const Rect& area, const DragOptions& options, bool alt);

    // TL17: a drag's place shows (its preview is drawn, a release tiles it) once the pointer has rested on that place of
    // the same output for kPreviewDelay ms (token tiling.previewDelay), at once with Alt held; another place, another
    // output or none starts over and hides the preview at once.
    inline constexpr uint64_t kPreviewDelay = theme::tokens::kTilingPreviewDelay;
    // Which places show without that delay: any with Alt held (TL17), and the menu bar's Fill when no other output lies
    // above that output's top edge (`topFree`): the window is held below the menu bar there (FR56) and the pointer has gone on
    // into the top of the screen, a target and never a way to another display (owner report on 1.0.0-rc6: "the gesture up to
    // fill the screen is very slow"; macOS shows the fill outline as the pointer reaches the menu bar). With an output above,
    // the strip is crossed on the way there and keeps the delay, as the side edges do.
    bool showsAtOnce(std::optional<Place> place, bool topFree, bool alt);
    class CDwell {
      public:
        // The pointer is on `place` of output `output` (nullopt: none) at `nowMs`; `immediate`: Alt is held. True when
        // the place shows now.
        bool update(std::optional<Place> place, std::string_view output, uint64_t nowMs, bool immediate);
        // Milliseconds until the place shows if the pointer stays on it (the timer that draws it then); nullopt when it
        // shows already or there is no place.
        std::optional<uint64_t> remaining(uint64_t nowMs) const;
        bool                    shown() const;
        void                    reset();

      private:
        std::optional<Place> m_place;
        std::string          m_output;
        uint64_t             m_since = 0;
        bool                 m_shown = false;
    };

    // TL22: the pointer resting on a window's zoom light for kHoverDelay ms (token tiling.hoverDelay) is a hover: `enter`,
    // and `leave` once the pointer is off that light. One light at a time. A press while the pointer is on the light (its
    // click zooms the window) ends the hover and holds it off until the pointer has left that light.
    inline constexpr uint64_t kHoverDelay = theme::tokens::kTilingHoverDelay;
    struct HoverChange {
        std::optional<uint64_t> leave; // the window whose hover ended (post leave)
        std::optional<uint64_t> enter; // the window whose hover began (post enter)
    };
    class CHoverDwell {
      public:
        // The pointer is over the zoom light of window `window` (nullopt: over none) at `nowMs`.
        HoverChange             update(std::optional<uint64_t> window, uint64_t nowMs);
        // A press (or a drag) begins: a hover that began ends, and the light waits until the pointer has left it.
        HoverChange             press();
        // Milliseconds until the light under the pointer is a hover if the pointer stays (the timer that posts enter then);
        // nullopt when there is nothing to wait for.
        std::optional<uint64_t> remaining(uint64_t nowMs) const;
        std::optional<uint64_t> entered() const;
        void                    reset();

      private:
        std::optional<uint64_t> m_window;
        uint64_t                m_since   = 0;
        bool                    m_entered = false;
        bool                    m_held    = false; // pressed: no hover on this light until the pointer leaves it
    };

    // The shell's popup layer (shell/overlay/Overlay.qml): mapped Exclusive while a shell popup is open, the tiling popover
    // included, on the output of that popup only.
    inline constexpr std::string_view kShellPopupNamespace = "grassfield-overlay";
    // What hides every zoom light from the hover now (TL22, TL34; integrator review of 4ead6fb): the session is locked; an
    // Exclusive layer other than the shell's popup layer is mapped anywhere (the polkit sheet, Search, Apps, the Overview, the
    // switcher, the Notification Center, the Dock's keyboard mode, a third-party one); or a Top or Overlay layer, or a layer
    // popup, is under the pointer (the light is covered, the shell's own popup layer too).
    struct HoverCover {
        bool                     locked = false;
        std::vector<std::string> exclusiveNamespaces; // of the mapped Exclusive layers
        bool                     layerUnderPointer = false;
    };
    // What a cover does to the hover (D24; integrator nested rerun of 25e757c). Away: the lock or a foreign Exclusive layer
    // took the desktop; the hover ends and starts over once it is back (CHoverDwell::update with no light), so a pointer that
    // rested on a light through the lock gives a hover after the delay. Over: a layer covers the light (the shell's open
    // popover included); as a press, the light waits until the pointer has left it, so a popover closed over the light does not
    // come back by itself. The lock and a foreign Exclusive layer come first.
    enum class HoverCoverEffect : uint8_t {
        None,
        Away,
        Over,
    };
    HoverCoverEffect hoverCoverEffect(const HoverCover& cover);

    // The `tile-hover` event (gfc/1). enter: the pointer rested on the window's zoom light (TL22); leave: it left that light;
    // open: hl.plugin.grassfield.tile_popover asked for the popover with the keyboard (Super+Ctrl+L, TL26). enter and open
    // carry the light's box (layout coordinates) and whether the window can be tiled (TL9: the shell greys the glyphs):
    // {"v":"gfc/1","type":"tile-hover","address":"<hex>","state":"enter","x":…,"y":…,"w":…,"h":…,"tileable":true}. Bounded.
    enum class HoverState : uint8_t {
        Enter,
        Leave,
        Open,
    };
    std::string_view hoverStateName(HoverState state); // its "state" in the event
    // `splittable`: the window fits one half of its output's Split View (TL33; the popover greys Left and Right of Screen).
    // enter and open also carry "unfitZones" and "unfitPlaces" (always, [] when it fits everything): the zones and the places it
    // does not fit (unfitZones, unfitPlaces, D69; the popover greys the arrangements and Layouts zones, and the places, that
    // would put it there). Under kMaxEventBytes even with every offered zone and every place listed.
    std::string tileHoverJson(uint64_t address, HoverState state, const Rect& light = {}, bool tileable = false, bool splittable = false,
                              std::span<const std::string> unfitZones = {}, std::span<const std::string> unfitPlaces = {});

    // The output a window belongs to after the plugin moved it (its titlebar drag, a tile): the one under the middle of
    // its box, as Hyprland's own move decides (CDragStateController::mouseMove); nullopt off every output (it keeps its
    // Desktop). `outputs`: the outputs' logical boxes.
    std::optional<size_t> outputUnder(const Rect& box, std::span<const Rect> outputs);

    // What the plugin knows of a window before it moves it.
    struct WindowFacts {
        bool mapped    = false; // CWindow::m_isMapped
        bool onDesktop = false; // CWindow::m_workspace is set (unmapping clears it, Window.cpp:750)
        bool inSpace   = false; // its layout target is in a layout space (unmapping takes it out, Window.cpp:2639)
        bool floating  = false;
    };

    // The plugin may set the window's box: CLayoutManager::setTargetGeom reaches the target's space and
    // CWindow::moveToWorkspace reads its old Desktop, both without a null check. A window that closed or unmapped during a
    // titlebar drag fails it (integrator re-review of 439e1f2, gate C1).
    bool movable(const WindowFacts& w);

    // followOutput: give the window the Desktop of the output under its middle (`output`, outputUnder) when it is movable
    // and floating, there is such an output, and that Desktop's space is not already the window's (`sameSpace`).
    bool shouldFollow(const WindowFacts& w, std::optional<size_t> output, bool sameSpace);

    // ---- geometry (TL1-TL8) ----

    // A zone of the work area on a 12 x 12 grid: halves, thirds and quarters are exact twelfths.
    inline constexpr int kZoneGrid = 12;
    struct Zone {
        int  x = 0;
        int  y = 0;
        int  w = kZoneGrid;
        int  h = kZoneGrid;

        bool operator==(const Zone&) const = default;
    };

    // The zone of a single place; nullopt for Center (it keeps the window's size).
    std::optional<Zone> zoneOf(Place place);

    // TL3: Hyprland keeps an output's scale on steps of 1/120 with an integer logical size (output/Monitor.cpp:996-1048), so
    // `120 / gcd(round(scale x 120), 120)` logical px is a whole number of device px too. That step when it is at most
    // kMaxGridStep, else 1 (whole logical px only; the device position is then Hyprland's rounding).
    inline constexpr int kMaxGridStep = 4;
    int gridStep(double scale);

    // Edges are snapped to multiples of `step` logical px from the output's logical origin.
    struct Grid {
        double originX = 0;
        double originY = 0;
        int    step    = 1;
    };

    // Where tiles go: the work area (the output minus its reserved area and the Stages strip column, TL1), the margin
    // (0 when "Tiled windows have margins" is off) and the output's grid.
    struct Area {
        Rect   box;
        double margin = 0;
        Grid   grid;
    };

    // The frame (titlebar band included) of `zone` in `area`: the area shrunk by the margin, the zone's twelfths of it, half
    // a margin taken on each side of an edge between two zones; every edge a whole logical px on the grid (TL3: an edge
    // between zones is rounded to the nearest grid line, an outer edge to the nearest one inside the work area). Two zones
    // that share an edge without margins share one value. Never smaller than 1 x 1.
    Rect zoneFrame(const Zone& zone, const Area& area);

    // What a window allows (logical px). min*/max* are its surface's limits (TL8: for an xdg window the larger of a
    // min_size rule and its protocol minimum; maxW/maxH 0 = none); inc*/base* its X11 resize increments (0 = none);
    // `band` the titlebar band above its surface (32 for the plugin's titlebar, 0 for client chrome, ADR-0015).
    struct Constraints {
        double minW  = 1;
        double minH  = 1;
        double maxW  = 0;
        double maxH  = 0;
        double incW  = 0;
        double incH  = 0;
        double baseW = 0;
        double baseH = 0;
        double band  = 0;
    };

    // TL8: frames[i] (zone zones[i]) made to fit constraints[i]. A frame smaller than the window's minimum first takes room
    // from the zones on the other side of its inner edges as far as their own minimum allows (the shared edge moves for
    // them too), then grows alone (from its edge on the work area's border, or both ways) and overlaps; never beyond the
    // work area unless the minimum is larger than it. A frame larger than the maximum shrinks to it, centred in its zone.
    // X11 increments round a surface down, top-left kept. Moves are whole grid steps where the minimum allows.
    std::vector<Rect> fitFrames(std::span<const Zone> zones, std::span<const Rect> frames, std::span<const Constraints> constraints, const Area& area);

    // TL7: a half (Left, Right, Top, Bottom) next to a tiled neighbour that already holds the other side: the frame from the
    // work area's edge to that neighbour, one margin before it. A neighbour holds the other side when its frame touches
    // the opposite inner edge and both perpendicular inner edges (within one grid step) and leaves at least a quarter of
    // the work area; the nearest such neighbour wins. nullopt: an exact half.
    std::optional<Rect> halfBesideNeighbour(Place place, const Area& area, std::span<const Rect> neighbourFrames);

    // Center: the window keeps its size (at most kCenterMaxFraction of the work area), in the middle, snapped.
    Rect centerFrame(const Rect& currentSurface, double band, const Area& area);

    // TL20: the sides of a window a double-click on its resize border extends, as a mask.
    inline constexpr uint8_t kSideLeft   = 1;
    inline constexpr uint8_t kSideRight  = 2;
    inline constexpr uint8_t kSideTop    = 4;
    inline constexpr uint8_t kSideBottom = 8;
    inline constexpr uint8_t kAllSides   = kSideLeft | kSideRight | kSideTop | kSideBottom;

    // The sides a press at (x, y) on a window's resize border grips. `surface`: the box Hyprland's border grab surrounds
    // (the window's geometric box, InputManager processMouseDownNormal). Left of it: left; right of it: right; above or
    // below likewise (both near a corner); inside it (a press in a rounded corner, which Hyprland also takes as the
    // border): the corner of the quadrant the press is in.
    uint8_t sidesAt(double x, double y, const Rect& surface);

    // The sides a double-click on `sides` extends: with Alt, the opposite side of each too (a corner then gives all four:
    // the window fills the work area).
    uint8_t extendedSides(uint8_t sides, bool alt);

    // TL20: the frame `frame` (titlebar band included) with each side in `sides` moved to the work area's edge, inside the
    // margin and on the grid (the edges of the whole-area frame, zoneFrame); the other sides stay. The window's limits
    // (`constraints`, band included): never larger than its maximum nor smaller than its minimum, X11 increments round its
    // surface down; the side that did not move stays, and when both sides of an axis moved a maximum centres the window.
    Rect extendFrame(const Rect& frame, uint8_t sides, const Constraints& constraints, const Area& area);

    // "top", "bottom", "left", "right" joined by "-" in that order ("top-left", "left-right"); "" for none.
    std::string sidesName(uint8_t sides);

    // Move to <display> of a window that is not tiled (TL23): its frame `frame` in the work area `from` goes to the work area
    // `to` at the same relative place (the free space left and above it keeps its share on each axis), its size kept, at
    // most `to`'s; whole logical px.
    Rect moveToArea(const Rect& frame, const Rect& from, const Rect& to);

    // A window that lands on another output (dropped there by a drag, or moved to a Desktop of that output) larger than that
    // output's work area `area` (owner report on 1.0.0-rc6: a zoomed window moved to a smaller display overflowed it, its
    // titlebar under the menu bar): macOS makes it fit the display, below the menu bar and above the Dock. Its frame `frame`
    // (titlebar band included) is made at most the area's size on each axis, never under the window's minimum (`limits`, its
    // band counted as fitsFrame does), whole logical px; on an axis where it was larger it starts at the area's start (its
    // titlebar right below the menu bar), on the other it keeps its place. nullopt when it fits already on both axes.
    std::optional<Rect> fitIntoArea(const Rect& frame, const Rect& area, const Constraints& limits);

    // An output went away (TL11): Hyprland moves a floating window of its Desktops by the offset between the two outputs,
    // and a window can end off every output (integrator nested pass of 6b's 12e3dd3: x = -2919). `strayFrame`: the frame
    // (titlebar included) shares no area with any of `outputs` (their logical boxes). `gatheredFrame`: where such a window
    // comes back (ADR-0036 D67, macOS gathers a disconnected display's windows): centred in `area` (the work area of its
    // Desktop's output) at its size, at most the area's; whole logical px.
    bool strayFrame(const Rect& frame, std::span<const Rect> outputs);
    Rect gatheredFrame(const Rect& frame, const Rect& area);

    // The frame (titlebar included) of a surface box: what the preview draws; and back.
    Rect frameOf(const Rect& surface, double titlebar);
    Rect surfaceOf(const Rect& frame, double titlebar);

    // The window's surface box for `place` in the free area `area` at scale 1 with the area's own origin as grid origin:
    // the helper the drag preview and the single-window requests share (zoneFrame, centerFrame).
    Rect surfaceFor(Place place, const Rect& area, double titlebar, bool margins, const Rect& current);

    // ---- outputs and the layout catalogue (TL5, owner decision T1f) ----

    enum class OutputClass : uint8_t {
        Small,     // under kLargeWidth logical px wide
        Large,     // kLargeWidth or wider
        UltraWide, // aspect kUltraWideAspect or wider
        Portrait,  // taller than wide
    };
    inline constexpr double kLargeWidth      = 1920.0;
    inline constexpr double kUltraWideAspect = 21.0 / 9.0;
    OutputClass      classify(double logicalWidth, double logicalHeight);
    std::string_view nameOf(OutputClass outputClass);

    // A layout of the catalogue (tokens tiling.layout*): zones in zone order, the first for the window that asks.
    inline constexpr size_t kMaxZones = 4;
    struct Layout {
        std::string_view  id;
        std::vector<Zone> zones;
    };
    std::span<const Layout>           catalogue();
    const Layout*                     layoutById(std::string_view id);
    std::span<const std::string_view> layoutsFor(OutputClass outputClass); // the Layouts section of that class (tokens tiling.class*)

    // ---- the tile record (TL10) ----

    enum class TileState : uint8_t {
        Tiled,     // in its tile
        Moving,    // a drag that began tiled: it took its box from before under the pointer
        Resizing,  // a resize by the user (Hyprland's drag): the record and the group stay
        Suspended, // full screen, zoomed, minimized or hidden: back to its tile when it returns
    };
    std::string_view nameOf(TileState state);

    // Where a window was placed: a place, zone `zone` of layout `layout`, or the sides an edge double-click extended (TL20).
    struct Placement {
        std::optional<Place> place;
        std::string          layout;
        int                  zone  = -1;
        uint8_t              sides = 0;

        bool                 operator==(const Placement&) const = default;
    };

    struct TileRecord {
        uint64_t    id    = 0;
        TileState   state = TileState::Tiled;
        Placement   where;
        Rect        box;    // the surface box the plugin gave it, or that it took through a user resize
        Rect        before; // its floating surface box before the first tiling
        double      band = 0;
        uint64_t    group = 0; // 0: none
        std::string output;
        int64_t     workspace = 0;
        bool        relayout  = false; // placed again from its zone when it comes back (margins changed, output gone)
        bool        deferred  = false; // placed again from its zone once it can be (TL2: the margins changed while it could not
                                       // be placed, e.g. in an inactive stage); its box is still the plugin's, so it is checked
    };

    // The tile records of every window (TL10). A group lives while two of its members are Tiled, Resizing or Suspended.
    // `generation()` grows with every change (the tiling notice).
    class CTileBook {
      public:
        // Free, Tiled or Moving -> Tiled. `current`: the window's surface box now; it becomes `before` unless the window
        // already has a record (a later tiling keeps the box from before the first one). `group` 0: none; joining another
        // group leaves the old one, which dissolves when one member is left. Returns the record.
        const TileRecord& placed(uint64_t id, const Rect& current, const Rect& box, double band, Placement where, std::string output, int64_t workspace,
                                 uint64_t group);
        // Tiled -> Moving: the box from before (the window takes its size under the pointer); it leaves its group. nullopt
        // when the window is not Tiled.
        std::optional<Rect> beginMove(uint64_t id);
        // Moving -> Free (a release elsewhere, a cancelled drag). A release that tiles calls placed() instead.
        void endMove(uint64_t id);
        // Tiled -> Resizing. False when the window is not Tiled.
        bool beginResize(uint64_t id);
        // Resizing -> Tiled with the new box; `before` and the group stay.
        void endResize(uint64_t id, const Rect& box);
        // Tiled or Resizing -> Suspended.
        bool suspend(uint64_t id);
        // Suspended -> Tiled (the glue checks zoneFree first and calls forget() otherwise). nullptr when not Suspended.
        const TileRecord* resume(uint64_t id);
        // Tiled: its box differs from the record by more than 1 px (something the plugin does not observe moved or
        // resized it) -> Free; false then, and for a window without a record. Moving, Resizing, Suspended and a record
        // waiting to be placed again (markRelayout: its output went away and Hyprland moved it): true.
        bool check(uint64_t id, const Rect& current);
        // Return to Previous Size: the box from before, the window Free.
        std::optional<Rect> takeBefore(uint64_t id);
        // The window closed, unmapped or was placed by other means.
        void forget(uint64_t id);
        void clear();
        // Changes the box of a Tiled window (a re-placement after a margins change or an output removal).
        void setBox(uint64_t id, const Rect& box, std::string output);
        // Marks a record to be placed again from its zone when it comes back (Suspended) or now (Tiled).
        void markRelayout(uint64_t id, bool on);
        // Marks a Tiled record to be placed again once its window can be (see TileRecord::deferred). Unlike markRelayout
        // the record is still checked against the window's box: a window the user moves meanwhile becomes Free.
        void markDeferred(uint64_t id, bool on);
        // Move to Desktop: the record keeps its state and box on the window's new Desktop.
        void setWorkspace(uint64_t id, int64_t workspace);

        const TileRecord*           find(uint64_t id) const;
        std::span<const TileRecord> records() const;
        uint64_t                    newGroup();
        uint64_t                    generation() const;
        // A suggestion's window joins the window that asked (TL28): that window's group, a new one it joins first when it has
        // none. 0 when it has no record.
        uint64_t joinGroup(uint64_t asker);

        // TL10: no other window that is Tiled or Resizing on `output` and `workspace` has a frame overlapping `frame` by
        // more than 1 px on both axes. `ignore`: windows that do not count either (an inactive stage's, drawn in the strip).
        bool zoneFree(const Rect& frame, std::string_view output, int64_t workspace, uint64_t except, std::span<const uint64_t> ignore = {}) const;

      private:
        TileRecord* get(uint64_t id);
        void        changed();
        void        leaveGroup(TileRecord& r);
        void        dissolveIfSingle(uint64_t group);

        std::vector<TileRecord> m_records;
        uint64_t                m_nextGroup  = 1;
        uint64_t                m_generation = 0;
    };

    // ---- requests ----

    // "left", "right", "top", "bottom", "top-left", "top-right", "bottom-left", "bottom-right", "fill", "center",
    // "left-third", "middle-third", "right-third", "left-two-thirds", "right-two-thirds".
    std::optional<Place> parsePlace(std::string_view name);
    std::string_view    nameOf(Place place);

    // hl.plugin.grassfield.arrange(json): {"layout":"<catalogue id>","windows":["0x<hex>",…],"fill":bool?,"zone":int?,
    // "with":"0x<hex>"?,"output":"<name>"?}. windows[i] takes zone i (1 to the layout's zone count of them, distinct, not 0);
    // with "fill" (default true) the plugin fills the remaining zones with the next tileable windows in stacking order (TL6).
    // With "zone", exactly one window goes to that zone of the layout and nothing is filled (a zone of the Layouts section,
    // TL27). "with" (only with "zone"; feature tiling-layouts) names the window whose layout the zone belongs to: a pick of
    // the suggestions (TL28); the window joins that window's group. Untrusted: strictly validated, at most kMaxArrangeBytes.
    inline constexpr size_t kMaxArrangeBytes = 4096;
    inline constexpr size_t kMaxOutputName   = 64;
    // An output name a request may carry: 1 to kMaxOutputName characters of [A-Za-z0-9._-].
    bool outputNameOk(std::string_view name);
    struct ArrangeRequest {
        std::string           layout;
        std::vector<uint64_t> windows;
        bool                  fill = true;
        std::optional<int>      zone;
        std::optional<uint64_t> with;
        std::string             output;
    };
    std::expected<ArrangeRequest, std::string> parseArrange(std::string_view json);

    // ---- tile groups (TL29) ----

    // The members of the group of `chosen` that come forward with it (a window brought forward from the Dock, the app
    // switcher or the Overview), in the order to raise them: the stacking order, bottom first (`stack`: the windows on
    // screen, bottom to top: none on a special workspace). Members Tiled or Resizing on the Desktop of `chosen`; a suspended
    // one (minimized, full screen, zoomed, hidden) stays where it is. `chosen` comes last whenever it is in `stack`, whatever
    // its state (zoomed or full screen it is Suspended but on screen; integrator review of cd74af2): the shell's activation
    // also raises it but may reach the compositor first, and changes nothing for the focused window. A minimized or hidden
    // `chosen` is not in `stack`: its restore raises it, before or after this request. Empty when no member comes forward
    // (`chosen` has no group, or none on screen beside it).
    std::vector<uint64_t> groupRaiseOrder(std::span<const TileRecord> records, uint64_t chosen, std::span<const uint64_t> stack);

    // ---- shared edge (TL30) ----

    // A Tiled member of a group on one output's Desktop as the shared edge sees it: its frame (titlebar band included) and
    // its limits (its surface's minimum and maximum, `band` the titlebar band; X11 increments are not applied during a drag,
    // as Hyprland's own floating resize does not apply them).
    struct EdgeWindow {
        uint64_t    id    = 0;
        uint64_t    group = 0;
        Rect        frame;
        Constraints limits;
    };

    // An edge the windows of one group share. Vertical (side by side): the windows `before` it (left) have their right side
    // on `at`, those `after` it (right) their left side `gap` further (the margin between them, 0 without margins);
    // horizontal (stacked) likewise with the bottom and top sides. Only windows that face one across the edge are in it, and
    // every such window of the group along that line is. `handles`: one per pair of facing windows, the middle
    // `handleLength` of the stretch they share (all of it when shorter), at least `band` across (the gap, widened equally
    // into both windows when narrower: without margins the windows touch).
    struct SharedEdge {
        bool                  vertical = true;
        uint64_t              group    = 0;
        double                at       = 0;
        double                gap      = 0;
        std::vector<uint64_t> before;
        std::vector<uint64_t> after;
        std::vector<Rect>     handles;
    };

    // The shared edges of `windows` (the Tiled group members of one output's Desktop). Two windows face each other when
    // they are in the same group (never group 0), the gap between their facing sides is from -1 to `maxGap` + 1 logical px
    // (the margin; frames sit on the grid) and they overlap along the edge by more than 1 px; an edge gathers the pairs of
    // one group on the same line (`at` and `gap` within 1 px).
    std::vector<SharedEdge> sharedEdges(std::span<const EdgeWindow> windows, double maxGap, double handleLength, double band);

    // The edge one of whose handles holds the point (x, y) (the first in `edges`), or nullopt.
    std::optional<SharedEdge> edgeAt(std::span<const SharedEdge> edges, double x, double y);

    // Whether a handle under the pointer may take it (TL30, TL34): the frontmost window under the point always gets the
    // click (macOS). `topmost`: the window Hyprland's pointer focus finds there (its hit test with the reserved and input
    // extents and floating windows: a titlebar, a border grab area, a full-screen window, from the top of the stack), 0 when
    // none; `popup`: an xdg popup of any window holds the point (that hit test returns the topmost window whose box holds
    // the point before it looks at the popups of the windows below: a popup reaching over the gap from the lower window of
    // the edge was not seen; integrator nested pass of 3d56d60). Clear when no popup is there and no window, or one of the
    // edge's own windows by its body or border.
    bool handleClear(const SharedEdge& edge, uint64_t topmost, bool popup);

    // A drag of `edge` by `delta` logical px along its axis (x for a vertical edge) from the frames at the press
    // (`windows`, which hold every window of the edge): the before windows' far side and the after windows' near side move
    // together and the gap stays; the edge lands on the grid line nearest the pointer; it never takes a window under its
    // minimum or over its maximum (heights count the titlebar band), stopping on the last grid line that keeps every window
    // within them, and does not move when no line does, nor when `windows` lacks every window of one side (nothing would
    // bound the other). Returns the new frames, the before windows then the after ones in the edge's order (a window
    // `windows` lacks is left out).
    std::vector<std::pair<uint64_t, Rect>> dragEdge(const SharedEdge& edge, std::span<const EdgeWindow> windows, double delta, const Grid& grid);

    // ---- suggestions (TL28) ----

    // The zones of the layout instance of `asker` that a window holds: its own and those of the members of its group placed
    // in the same layout on the same output and Desktop (Tiled, Resizing or Suspended: a suspended member comes back to its
    // zone), in zone order, each once.
    std::vector<int> zonesHeld(std::span<const TileRecord> records, const TileRecord& asker);
    // The zones of `layout` that are not in `held`, in zone order.
    std::vector<int> emptyZones(const Layout& layout, std::span<const int> held);

    // What the shell offers to fill the rest of a layout (TL28) after an arrangement or a zone of the Layouts section left
    // zones empty: kept by the plugin, published in the state reply while the tile records are still those of `generation`
    // (any later change ends it) and the window that asked still holds its zone.
    inline constexpr size_t kMaxSuggested = 12;
    struct Suggestion {
        uint64_t              generation = 0;
        uint64_t              asker      = 0; // the window whose layout it fills
        std::string           layout;
        std::string           output;
        std::vector<int>      zones;   // the empty zones, zone order: the shell offers the first
        std::vector<Rect>     frames;  // their frames (layout coordinates), same order
        std::vector<uint64_t> windows; // the windows that can fill them, at most kMaxSuggested (D26)
    };

    // hl.plugin.grassfield.config keys (values "true" | "false"): the switches of Desktop & Dock > Windows (TL32).
    inline constexpr std::string_view kConfigEdges       = "tilingEdges";
    inline constexpr std::string_view kConfigMenuBar     = "tilingMenuBar";
    inline constexpr std::string_view kConfigMargins     = "tilingMargins";
    inline constexpr std::string_view kConfigAltDrag     = "tilingOptionDrag";  // Settings windows.tilingOptionDrag (TL18)
    inline constexpr std::string_view kConfigLayouts     = "tilingLayouts";     // the green button's hover event (TL22)
    inline constexpr std::string_view kConfigSuggestions = "tilingSuggestions"; // the suggestion after an arrangement (TL28)
    enum class Switch : uint8_t {
        Edges,
        MenuBar,
        AltDrag,
        Margins,
        Layouts,
        Suggestions,
    };
    // The switch a config key names; nullopt for any other key ("Bring tile groups forward together" is the shell's alone:
    // the plugin raises a group only on group_front, ADR-0036 D38).
    std::optional<Switch> switchOf(std::string_view key);
    std::optional<bool>   parseBool(std::string_view value);

    // ---- the tiling notice and state (gfc/1, ADR-0007) ----

    enum class Reason : uint8_t {
        None,
        Placed,      // a window took a tile (tile, arrange, a release in a drag zone)
        Moved,       // a tiled window was dragged away
        Resized,     // a user resize of a tiled window ended
        Suspended,   // full screen, zoom, minimize or hide
        Restored,    // back from Suspended
        Forgotten,   // a record ended (Free, closed, Return to Previous Size)
        Relaid,      // windows placed again (margins changed, an output went away)
        Invalid,     // a refused request (nothing changed)
        Locked,      // a request refused while the session is locked (tiling.md TL34; nothing changed)
        Unavailable, // the plugin unloads
    };
    std::string_view reasonName(Reason reason);

    // The `tiling` event, a change notice: {"v":"gfc/1","type":"tiling","gen":N} plus "reason":"…". Bounded (ADR-0007: no
    // event grows with the windows); the state is the reply of `hyprctl grassfield-tiling`.
    std::string noticeJson(uint64_t generation, Reason reason);

    // ---- the Full Screen tile (macOS Split View, docs/specs/tiling.md TL33, step 6a) ----

    // A Split View Desktop: the workspace the plugin made for it, its output, and the Desktop its first window came from (its
    // home: Exit Full Screen sends a window back there, ADR-0036 D44). Its members are the window it was made for and the one
    // picked for its other half, whatever their state (full screen and zoomed included, D50); another window on that workspace
    // is no member (D52).
    struct SplitDesk {
        int64_t               workspace = 0;
        std::string           output{};
        int64_t               home = 0;
        std::vector<uint64_t> members{};
        bool                  waiting = false; // its second window not chosen yet (the suggestion pending): one member does not fill it

        bool                  operator==(const SplitDesk&) const = default;
    };

    // The area of a Split View Desktop (ADR-0036 D42): the whole output `output` (no menu bar, Dock or Stages strip), its two
    // halves one tiling margin apart and no margin at the outer edges, whatever the margins switch says; `grid` the output's.
    Area splitArea(const Rect& output, const Grid& grid);

    // A window with limits `c` fits `frame` (titlebar included, layout coordinates): its minimum surface with its band inside
    // (TL8). A Split View half too narrow for it is refused rather than overlapped (integrator nested pass of 1ee992e, MAJOR C).
    bool fitsFrame(const Constraints& c, const Rect& frame);

    // A window of fixed size (minimum and maximum the same on both axes): macOS greys the zoom light of a window that cannot
    // be resized, and a Grassfield app draws it disabled. Hovering it opens no tiling popover and the tile_popover request is
    // refused; the Window menu greys Zoom, Enter Full Screen and the tiling items (the state reply's "fixed"). ADR-0040 step
    // 1b's About This Computer, the integrator's nested pass of 85c2c10. A window fixed on one axis only stays zoomable; TL9
    // refuses to tile it.
    bool fixedSize(const Constraints& c);

    // The Full Screen and Zoom keys (Super+Ctrl+F, Super+Alt+F; config/hypr/grassfield/bindings.lua asks the plugin's
    // window_size at each press, ADR-0040 step 1b's review): Hyprland's fullscreen modes by the names its dispatcher takes,
    // "fullscreen" and "maximized" (strict; nullopt for anything else).
    enum class SizeMode : uint8_t {
        Fullscreen,
        Maximized,
    };
    std::optional<SizeMode> parseSizeMode(std::string_view name);
    // Whether such a key acts on the focused window, as the Window menu has it: a window of fixed size (`fixed`) only leaves
    // the mode it is in (`inMode`: Exit Full Screen, Unzoom); any other window toggles as Hyprland's dispatcher does.
    bool sizeKeyActs(bool fixed, bool inMode);

    // ---- Zoom is Fill (ADR-0036 D78; tiling.md TL35) ----
    // Grassfield's Zoom (the zoom light without Alt, a titlebar double-click set to Zoom or Fill, Super+Alt+F, Window > Zoom)
    // fills the window as a tile, with the tiling margins when "Tiled windows have margins" is on, as macOS 15+ fills a window
    // from its title bar; Hyprland's maximized mode (fullscreen 1) glued it under the menu bar and against the screen's edges.
    enum class ZoomStep : uint8_t {
        Fill,         // tiled as Fill (a plain window, or one tiled in another place)
        Previous,     // back to its box from before tiling (Return to Previous Size): it is filled now
        UnzoomToFill, // out of Hyprland's maximized mode, then Fill
        Hyprland,     // Hyprland's own maximized mode, toggled as before
        Refused,      // nothing: a window of fixed size that is not zoomed (its zoom light is disabled)
        Unfill,       // at the Fill frame without a tile record (the plugin was reloaded): the Center place's frame, Free
    };

    // What the step reads from the window and the plugin.
    struct ZoomFacts {
        bool tiling       = false; // feature window-tiling advertised (the tile verb registered) and the session not locked
        bool maximized    = false; // in Hyprland's maximized mode (fullscreen 1)
        bool fullscreen   = false; // in Hyprland's full screen (fullscreen 2)
        bool splitMember  = false; // a member of a Split View Desktop (TL33): its Desktop places it (D50)
        bool fixedSize    = false; // minimum = maximum on both axes
        bool filled       = false; // its tile record is Tiled as Fill (a place, not a layout zone or extended sides)
        bool atFill       = false; // no tile record, and its frame is the Fill frame of its work area now (within 1 px)
    };

    // A window of fixed size that is not zoomed is refused (ADR-0040 step 1b). Without window-tiling (no plugin, a degraded
    // one: gate C2), in full screen or for a Split View member: Hyprland's maximized mode, as before. A window in Hyprland's
    // maximized mode leaves it into Fill (client chrome too: while window-tiling is advertised its own maximize request is
    // this Zoom, ADR-0015 Q4 amended), unless it is of fixed size (it only unzooms). A filled window goes back to its box
    // from before; one at the Fill frame whose record a plugin reload forgot takes the Center place's frame (no box from
    // before is known); any other window fills.
    ZoomStep zoomStep(const ZoomFacts& f);
    std::string_view nameOf(ZoomStep step);

    // ---- what a window fits (ADR-0036 D69: D57's model for every place and arrangement) ----

    // A window with limits `c` fits zone `zone` of `area`: fitsFrame on the zone's frame as its glyph shows it (zoneFrame). The
    // plugin places a window only in a zone it fits (a place, a zone of the Layouts section, an arrangement's every member),
    // so an arrangement is always the catalogue's equal zones, never shifted rows or columns (capture defect of 2026-10-30:
    // Quarters at 1440 x 900 with a window 420 px tall at least). fitFrames' make-room stays for windows already placed when
    // their work area shrinks (a margins switch, the Dock).
    bool fitsZone(const Constraints& c, const Zone& zone, const Area& area);

    // The zones a window may be asked into, each once: the places' zones (TL4) in Place order, then the catalogue's (TL5) in
    // its order; not Fill's whole area (Fill always takes the window as far as its minimum allows) nor Center (no zone).
    std::span<const Zone> offeredZones();

    // A zone as the shell names it: its twelfths "x,y,w,h" (the token array of its glyph, joined by ",").
    std::string zoneName(const Zone& zone);

    // The names (zoneName) of the zones of offeredZones() that a window with limits `c` does not fit in `area` (fitsZone), in
    // that order: the "unfitZones" of the tile-hover event and of the state reply (the shell greys those places, arrangements
    // and Layouts zones).
    std::vector<std::string> unfitZones(const Constraints& c, const Area& area);

    // The frame `place` gives a window before its limits, exactly as tile() applies it (TL4, TL7): its zone's frame; for a
    // half, the rest of the work area beside a tiled neighbour that holds the other side (halfBesideNeighbour over
    // `neighbourFrames`, the frames of the other Tiled or Resizing windows of that output's Desktop). Not for Center (no zone).
    Rect placeStartFrame(Place place, const Area& area, std::span<const Rect> neighbourFrames = {});

    // The places (nameOf, in Place order) a window with limits `c` does not fit, each on the frame tile() applies
    // (placeStartFrame); never Fill or Center (always offered). The "unfitPlaces" of the tile-hover event and of the state
    // reply: the shell greys those places (halves, quarters, thirds) in the popover and the Window menu, and unfitZones keeps
    // the arrangements and the Layouts zones, which place every member afresh on the plain zone frames (review of D69, MINOR
    // 1: a half beside a tiled neighbour is narrower than the half zone).
    std::vector<std::string> unfitPlaces(const Constraints& c, const Area& area, std::span<const Rect> neighbourFrames = {});

    // One window's unfitZones and unfitPlaces for the state reply (the Window menu reads it again when it opens, as D57's
    // "unfit").
    struct WindowFit {
        uint64_t                 address = 0;
        std::vector<std::string> zones;
        std::vector<std::string> places;
    };

    // The id of a new Desktop: one past the highest regular workspace id of `ids` (special and named ones are negative), as
    // the Overview's "+" does (ADR-0036 D41); 1 when there is none.
    int64_t nextDesktopId(std::span<const int64_t> ids);

    // The zone of the "left-right" layout a side of the Full Screen tile takes: "left" 0, "right" 1; nullopt otherwise.
    std::optional<int> splitZone(std::string_view side);

    // How a window leaves its Split View Desktop (unsplit's second argument, step 6d, ADR-0036 D71): Move Window to Desktop
    // ("desktop", or nothing: D44), Make Window Full Screen ("fullscreen": then full screen on that Desktop), Replace Tiled
    // Window ("replace": its half waits for another window, the picker offering the windows of that Desktop but it).
    enum class Unsplit : uint8_t {
        Desktop,
        Fullscreen,
        Replace,
    };
    std::optional<Unsplit> unsplitHow(std::string_view text);

    // The windows a suggestion offers (TL28, D26): `candidates` in their order (top first, then the minimized ones), each once,
    // never `exclude` (Replace Tiled Window's window, back on the Desktop the picker offers windows from: D71; 0 excludes
    // none), at most kMaxSuggested: the cap counts after the exclusion (the follow-up of #78: 11 offered with 12 or more).
    std::vector<uint64_t> offerWindows(std::span<const uint64_t> candidates, uint64_t exclude);

    // The Split View Desktop `workspace` is, or nullptr.
    const SplitDesk* splitOf(std::span<const SplitDesk> splits, int64_t workspace);

    // The Split View Desktop window `id` is a member of, or nullptr.
    const SplitDesk* splitOfWindow(std::span<const SplitDesk> splits, uint64_t id);

    // TL10: record `r` is stale and is forgotten when its window is gone or unmapped (`mapped` false), or when it is Tiled and
    // no longer at its box (`atItsBox` false: moved or resized by other means) unless it waits for a relayout or it is the
    // Split View member whose titlebar drag is under way (`dragged`: placed at its drop, TL33 step 6b; the integrator review
    // of e352f7c: forgotten mid-drag, it never swapped nor went back).
    bool staleRecord(const TileRecord& r, bool mapped, bool atItsBox, uint64_t dragged);

    // The Split View Desktop whose two members `edge` separates (one on each side, nothing else on it: the separator, TL33),
    // or nullptr (an edge of an ordinary tile group).
    const SplitDesk* splitOfEdge(std::span<const SplitDesk> splits, const SharedEdge& edge);

    // Step 6b (TL33): a Split View member's titlebar drag released at (x, y), the member in zone `ownZone` (0 left, 1 right) of
    // the halves `left` and `right` (frames): the other zone when the point lies in the other half (the two members swap
    // halves, macOS), else nullopt (it goes back to its own half).
    std::optional<int> splitDropZone(const Rect& left, const Rect& right, int ownZone, double x, double y);

    // Keeps the members of `d` still on its workspace (`on`: the windows there now, in any state), in their order. True when
    // one left.
    bool pruneMembers(SplitDesk& d, std::span<const uint64_t> on);

    // Step 6e (ADR-0036 D73): every member of the Split View Desktops `splits`, sorted, each once (their titlebars are away).
    std::vector<uint64_t> splitMembers(std::span<const SplitDesk> splits);

    // The windows that joined or left a Split View Desktop: in one of `before` and `now` (both from splitMembers) and not in
    // the other, sorted. Their titlebars are refreshed (one goes, one comes back above its window).
    std::vector<uint64_t> membersChanged(std::span<const uint64_t> before, std::span<const uint64_t> now);

    // What a Split View Desktop does after a change (TL33, ADR-0036 D43): with two members it stays; with one it fills it
    // alone, unless that window is still choosing its second one (`picking`: the suggestion of its Split View pending); with
    // none it ends.
    enum class SplitStep : uint8_t {
        Keep,
        Fill,
        End,
    };
    SplitStep splitStep(size_t members, bool picking);

    struct StateOutput {
        std::string                    name;
        Rect                           area; // the work area a placement would use now
        OutputClass                    outputClass = OutputClass::Small;
        int                            grid        = 1;
        std::vector<const TileRecord*> windows;
    };
    // The reply of `hyprctl grassfield-tiling`: "splits" the Split View Desktops with their members and whether one waits for
    // its second window (TL33), "unfit" the windows that do not fit half of their output (the Window menu greys their Full
    // Screen Tile, D57), "fixed" the windows of fixed size (fixedSize: the Window menu greys their Zoom and tiling items),
    // "unfitZones" the windows that do not fit some offered zone with those zones (always present; the Window menu greys those
    // Halves, Quarters and Arrange items, D69), "suggestion" null without one.
    std::string stateJson(uint64_t generation, std::span<const StateOutput> outputs, const Suggestion* suggestion = nullptr,
                          std::span<const SplitDesk> splits = {}, std::span<const uint64_t> unfit = {}, std::span<const uint64_t> fixed = {},
                          std::span<const WindowFit> unfitZones = {});

} // namespace gf::tiling
