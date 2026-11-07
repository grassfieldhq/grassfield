#include "Tiling.hpp"

#include "ClientChrome.hpp"
#include "DeferredFocus.hpp"
#include "FrameProbe.hpp"
#include "Ipc.hpp"
#include "Plugin.hpp"
#include "Stages.hpp"
#include "Minimize.hpp"
#include "Titlebar.hpp"
#include "TopClamp.hpp"
#include "core/Minimize.hpp"
#include "core/TitlebarLayout.hpp"

#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/pointer/cursor/CursorShapeOverrideController.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>
#include <hyprland/src/xwayland/XSurface.hpp>
#include <hyprland/src/xwayland/XWayland.hpp>

#include <linux/input-event-codes.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <format>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace gf::tiler {

    namespace {
        // A Suspended window coming back (TL10): after a Desktop move from a special workspace (minimize, hide, Show
        // Desktop) its zone must be free; after full screen or zoom its box is put back.
        struct SResume {
            uint64_t id        = 0;
            bool     checkFree = false;
        };

        // The drag of a floating window (the plugin's titlebar drag or one of Hyprland's moves; one seat pointer): the place
        // under the pointer, shown once the preview delay has passed (TL17).
        struct SDrag {
            PHLWINDOWREF        window;
            std::optional<Snap> candidate;
            tiling::CDwell      dwell;
            bool                hyprland = false; // one of Hyprland's moves (ended by Hyprland, tiled after it)
        };

        // The release of one of Hyprland's moves, handled once Hyprland ended the drag (TL16).
        struct SMoveRelease {
            PHLWINDOWREF        window;
            std::optional<Snap> snap; // the place shown at the release: tiled
        };

        // The output under a window's middle when one of Hyprland's moves of it was first seen: a release on another output
        // fits the window there (fitToOutput; owner report on 1.0.0-rc6).
        struct SMoveFrom {
            PHLWINDOWREF window;
            std::string  output;
        };

        // TL20: the clicks on one window's resize border, and a double-click waiting for Hyprland to end its resize.
        struct SBorderClicks {
            PHLWINDOWREF                window;
            uint8_t                     sides = 0;
            gf::titlebar::CClickTracker clicks{}; // braces: its default constructor is explicit
        };
        // TL33 (step 6b): the presses on a Split View Desktop's separator (the shared edge between its two members), for its
        // double-click: equal halves again.
        struct SSeparatorClicks {
            int64_t                     workspace = 0;
            gf::titlebar::CClickTracker clicks{}; // braces: its default constructor is explicit
        };
        struct SExtend {
            PHLWINDOWREF window;
            uint8_t      sides = 0; // with Alt's opposite sides (core extendedSides)
        };

        // TL30: a drag of a shared edge's handle (the plugin's own: its press and release are cancelled on the bus). The
        // windows of the edge as they were at the press, the edge, the pointer at the press; the frames last applied, at most
        // one application per refresh of the output (the rest wait for the timer or the release).
        struct SEdgeDrag {
            tiling::SharedEdge                          edge;
            std::vector<tiling::EdgeWindow>             windows;
            tiling::Grid                                grid;
            Vector2D                                    press;
            PHLMONITORREF                               monitor;
            double                                      delta = 0;
            std::vector<std::pair<uint64_t, tiling::Rect>> applied;
            uint64_t                                    beganMs   = 0;
            uint64_t                                    appliedMs = 0;
            uint32_t                                    steps     = 0; // applications that changed a frame
            uint32_t                                    held      = 0; // motions that waited for the next refresh
            std::vector<uint64_t>                       left;          // windows that left it (gate C1): no longer set, still bounds
            std::vector<uint64_t>                       moved;         // windows set at another size than at the press (the probe's mark)
            uint64_t                                    workUs    = 0; // the plugin's own time in the drag's motions and frames
            uint64_t                                    maxWorkUs = 0; // the longest of them (one motion or one refresh's frames)
        };

        // TL30: a record the shared edge looks at (a Tiled group member on the Desktop an output shows) and what it read of
        // its window: whether it counts (mapped, shown, not full screen or zoomed, not in an inactive stage), its box, its band.
        struct SEdgeMember {
            uint64_t     id    = 0;
            uint64_t     group = 0;
            PHLWINDOWREF window;
            bool         counts = false;
            CBox         box;
            double       band = 0;
        };

        // The shared edges of the Desktop an output shows (edgeScene), and what they were derived from.
        struct SEdgeScene {
            PHLMONITORREF                   monitor;
            int64_t                         workspace = -1;
            double                          margin    = -1;
            std::vector<SEdgeMember>        members; // in the book's order
            std::vector<tiling::EdgeWindow> windows;
            std::vector<tiling::SharedEdge> edges;
            tiling::Grid                    grid;
        };

        struct SState {
            bool                             ready = false;
            tiling::CTileBook                book;
            uint64_t                         posted = 0; // generation of the latest notice
            PHLWINDOWREF                     resizing;   // a tiled window one of Hyprland's resizes holds
            bool                             relayoutPending = false;
            bool                             gatherPending   = false; // an output went away: windows left off every output come back (D67)
            std::vector<SResume>             resuming;
            gf::deferredFocus::CLater        later; // after Hyprland's own handling (its callback is code of this library)
            std::vector<CHyprSignalListener> listeners;
            SDrag                            drag;
            SP<CEventLoopTimer>              previewTimer; // draws the preview once the delay passed (code of this library: removed in stop())
            bool                             recheck = false;  // a key may have changed Alt: the drag's place is read again
            std::optional<Vector2D>          press;            // the pointer at the left button's press (the grip of Hyprland's move)
            uint32_t                         pressMs = 0;
            std::optional<SMoveRelease>      moveRelease;
            SBorderClicks                    border;
            SSeparatorClicks                 separator;
            PHLWINDOWREF                     memberDrag; // TL33 (step 6b): the member whose titlebar drag is under way (reconcile keeps it)
            std::optional<SExtend>           extend;
            std::optional<tiling::Suggestion> suggestion; // TL28: valid while the book is at its generation
            std::optional<SEdgeDrag>          edge;            // TL30: a shared edge being dragged
            bool                              edgeReleaseOwed = false; // the release of the handle's cancelled press is cancelled too
            bool                              edgeCursor      = false; // the handle's cursor is set (Hyprland's special-action override)
            bool                              holdPending     = false; // the shell's menu bar mapped: windows left under it go below it
            SP<CEventLoopTimer>               edgeTimer;       // the frames that waited for the next refresh (code of this library: removed in stop())
            SEdgeScene                        edgeHoverScene;  // the edges hover looks up, kept while what they derive from holds
            std::vector<tiling::SplitDesk>    splits;          // TL33: the Split View Desktops the plugin made
            std::unordered_map<uint64_t, tiling::TileRecord> splitHomes; // TL33: a member's tile on its home Desktop before its split
            std::vector<uint64_t>             chromeMembers;   // step 6e (D73): the members whose titlebars were last made to follow
            std::vector<uint64_t>             backInReach;     // windows that left a Split View, their titlebar not in reach yet (locked, hidden)
            std::vector<PHLWINDOWREF>         fitting;         // Free windows moved to a Desktop: fitted to its output once Hyprland placed them
            SMoveFrom                         moveFrom;        // the output one of Hyprland's moves began on (fitted at its release; no window: none)
        };

        // Constructed on first use inside a guarded call (R13).
        SState& st() {
            static SState s;
            return s;
        }

        // The quick look panel (docs/specs/preview.md) is never tiled (TL9).
        constexpr std::string_view kGlanceClass = "org.grassfield.Preview.Glance";

        tiling::Rect toRect(const CBox& b) {
            return tiling::Rect{b.x, b.y, b.w, b.h};
        }

        CBox toCBox(const tiling::Rect& r) {
            return CBox{r.x, r.y, r.w, r.h};
        }

        uint64_t idOf(const PHLWINDOW& w) {
            return reinterpret_cast<uintptr_t>(w.get());
        }

        PHLWINDOW windowById(uint64_t id) {
            if (!Desktop::windowState())
                return nullptr;
            for (const auto& w : Desktop::windowState()->windows()) {
                if (w && idOf(w) == id)
                    return w;
            }
            return nullptr;
        }

        // Enabled outputs only: Hyprland keeps a disconnected monitor (m_enabled false) in its list for a while.
        std::vector<PHLMONITOR> monitors() {
            std::vector<PHLMONITOR> out;
            const auto&             state = State::monitorState();
            if (!state)
                return out;
            for (const auto& m : state->monitors()) {
                if (m && m->m_enabled)
                    out.push_back(m);
            }
            return out;
        }

        PHLMONITOR monitorAt(const Vector2D& p) {
            for (const auto& m : monitors()) {
                if (m->logicalBox().containsPoint(p))
                    return m;
            }
            return nullptr;
        }

        PHLMONITOR monitorByName(std::string_view name) {
            for (const auto& m : monitors()) {
                if (m->m_name == name)
                    return m;
            }
            return nullptr;
        }

        // The output a window is on now: the one under its middle. Hyprland's m_monitor is not updated by the plugin's own
        // titlebar drags, so a window dragged to another output would tile back on the old one (R13).
        PHLMONITOR monitorOf(const PHLWINDOW& w) {
            const auto target = w ? w->layoutTarget() : nullptr;
            if (!target)
                return nullptr;
            if (auto m = monitorAt(target->position().middle()))
                return m;
            const auto m = w->m_monitor.lock();
            return m && m->m_enabled ? m : nullptr;
        }

        // An edge of `m` is free when no other monitor touches it along an overlapping span: a shared edge leads to the
        // next output (dragging there moves the window over), it never tiles.
        bool edgeFree(const PHLMONITOR& m, bool left) {
            const CBox box = m->logicalBox();
            for (const auto& o : monitors()) {
                if (o == m)
                    continue;
                const CBox   other    = o->logicalBox();
                const bool   overlaps = other.y < box.y + box.h && other.y + other.h > box.y;
                const double edge     = left ? box.x : box.x + box.w;
                const double touch    = left ? other.x + other.w : other.x;
                if (overlaps && std::abs(edge - touch) < 1.0)
                    return false;
            }
            return true;
        }

        // The top edge of `m` is free when no other monitor's bottom edge touches it along an overlapping span: the menu bar
        // strip is then the top of the screen, never crossed on the way to another output (core showsAtOnce).
        bool topFree(const PHLMONITOR& m) {
            const CBox box = m->logicalBox();
            for (const auto& o : monitors()) {
                if (o == m)
                    continue;
                const CBox other    = o->logicalBox();
                const bool overlaps = other.x < box.x + box.w && other.x + other.w > box.x;
                if (overlaps && std::abs(box.y - (other.y + other.h)) < 1.0)
                    return false;
            }
            return true;
        }

        bool sameBox(const CBox& a, const CBox& b) {
            return std::abs(a.x - b.x) <= 1.0 && std::abs(a.y - b.y) <= 1.0 && std::abs(a.w - b.w) <= 1.0 && std::abs(a.h - b.h) <= 1.0;
        }

        bool fullscreenNow(const PHLWINDOW& w) {
            const auto& fs = Fullscreen::controller();
            return fs && fs->getFullscreenModes(w).internal != Fullscreen::FSMODE_NONE; // zoom is FSMODE_MAXIMIZED
        }

        // TL9: an X11 window Hyprland floats by type or role: CHyprXWaylandManager::shouldBeFloated's X11 branch
        // (XWaylandManager.cpp:110-131), read here without its side effects (that function also sets focus flags).
        bool x11FloatedByHyprland(const PHLWINDOW& w) {
            if (!w->m_isX11)
                return false;
            if (w->isX11OverrideRedirect() || w->isModal())
                return true;
            const auto xs = w->m_xwaylandSurface.lock();
            if (!xs)
                return true; // nothing to read: never tiled
            if (xs->m_transient || static_cast<bool>(xs->m_parent) || xs->m_role.contains("task_dialog") || xs->m_role.contains("pop-up"))
                return true;
            static constexpr std::array<std::string_view, 10> kTypes{
                "_NET_WM_WINDOW_TYPE_DIALOG",  "_NET_WM_WINDOW_TYPE_SPLASH",        "_NET_WM_WINDOW_TYPE_TOOLBAR", "_NET_WM_WINDOW_TYPE_UTILITY",
                "_NET_WM_WINDOW_TYPE_TOOLTIP", "_NET_WM_WINDOW_TYPE_POPUP_MENU",    "_NET_WM_WINDOW_TYPE_DOCK",    "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU",
                "_NET_WM_WINDOW_TYPE_MENU",    "_KDE_NET_WM_WINDOW_TYPE_OVERRIDE"};
            for (const auto name : kTypes) {
                const auto it = HYPRATOMS.find(std::string{name}); // find, never operator[]: Hyprland's table is only read
                if (it != HYPRATOMS.end() && it->second != 0 && std::ranges::find(xs->m_atoms, it->second) != xs->m_atoms.end())
                    return true;
            }
            return false;
        }

        // ICCCM WM_NORMAL_HINTS flags (4.1.2.3).
        constexpr uint32_t kHintMinSize   = 1U << 4;
        constexpr uint32_t kHintResizeInc = 1U << 6;
        constexpr uint32_t kHintBaseSize  = 1U << 8;
        // Hyprland's "no maximum" (CWindow::maxSize: numeric_limits<double>::max() per axis).
        constexpr double kNoMaximum = 1e7;

        // TL8: the window's limits. Minimum: CWindow::minSize() (a min_size rule, else the client's) and, for an xdg window,
        // at least the protocol minimum Hyprland's commit clamp applies (Window.cpp:2741-2747); never under Hyprland's own
        // floor, MIN_WINDOW_SIZE (20 px, macros.hpp: what its resizes fall back to; an app with no minimum is not squeezed
        // to a 1 px frame, integrator review of a6d04df). Maximum: likewise the smaller of the rule and the protocol maximum.
        // X11 increments from WM_NORMAL_HINTS.
        tiling::Constraints constraintsOf(const PHLWINDOW& w) {
            tiling::Constraints c;
            c.band       = gf::chrome::bandOf(w); // none above a window that draws its own chrome (ADR-0015)
            Vector2D min = w->minSize().value_or(Vector2D{1, 1});
            Vector2D max = w->maxSize().value_or(Vector2D{0, 0});
            if (!w->m_isX11) {
                const auto xdg = w->m_xdgSurface.lock();
                const auto top = xdg ? xdg->m_toplevel.lock() : nullptr;
                if (top) {
                    const auto pmin = top->layoutMinSize();
                    const auto pmax = top->layoutMaxSize();
                    min.x           = std::max(min.x, pmin.x);
                    min.y           = std::max(min.y, pmin.y);
                    if (pmax.x > 1)
                        max.x = max.x > 0 && max.x < kNoMaximum ? std::min(max.x, pmax.x) : pmax.x;
                    if (pmax.y > 1)
                        max.y = max.y > 0 && max.y < kNoMaximum ? std::min(max.y, pmax.y) : pmax.y;
                }
            }
            c.minW = std::max(MIN_WINDOW_SIZE, min.x);
            c.minH = std::max(MIN_WINDOW_SIZE, min.y);
            c.maxW = max.x > 0 && max.x < kNoMaximum ? max.x : 0;
            c.maxH = max.y > 0 && max.y < kNoMaximum ? max.y : 0;
            if (w->m_isX11) {
                const auto xs = w->m_xwaylandSurface.lock();
                if (xs && xs->m_sizeHints) {
                    const auto& hints = *xs->m_sizeHints;
                    if (hints.flags & kHintResizeInc) {
                        c.incW = std::max(0, hints.width_inc);
                        c.incH = std::max(0, hints.height_inc);
                    }
                    if (hints.flags & kHintBaseSize) {
                        c.baseW = std::max(0, hints.base_width);
                        c.baseH = std::max(0, hints.base_height);
                    } else if (hints.flags & kHintMinSize) {
                        c.baseW = std::max(0, hints.min_width);
                        c.baseH = std::max(0, hints.min_height);
                    }
                }
            }
            return c;
        }

        tiling::WindowFacts factsOf(const PHLWINDOW& w) {
            const auto target = w ? w->layoutTarget() : nullptr;
            return tiling::WindowFacts{.mapped    = w && w->m_isMapped,
                                       .onDesktop = w && w->m_workspace,
                                       .inSpace   = target && target->space(),
                                       .floating  = target && target->floating()};
        }

        // An output showing an open special workspace (a scratchpad): nothing tiles there (TL9), a drop only moves.
        bool showsSpecial(const PHLMONITOR& m) {
            return m && m->m_activeSpecialWorkspace;
        }

        // TL9 apart from where the window is now: what a window minimized from an output passes to be suggested there (TL28).
        bool tileableKind(const PHLWINDOW& w) {
            if (!w || !tiling::movable(factsOf(w)) || !w->m_isFloating || w->m_pinned || fullscreenNow(w))
                return false;
            if (w->parent() || x11FloatedByHyprland(w) || w->m_class == kGlanceClass)
                return false;
            const auto c = constraintsOf(w);
            return !((c.maxW > 0 && c.minW >= c.maxW) || (c.maxH > 0 && c.minH >= c.maxH)); // fixed size on an axis
        }

        // TL9 (no drag preview, refused by tile and arrange).
        bool placeable(const PHLWINDOW& w) {
            if (!tileableKind(w) || w->isHidden() || !w->m_workspace || w->m_workspace->m_isSpecialWorkspace)
                return false; // minimized and hidden windows live on special workspaces
            return !gf::stager::inStripStage(w);
        }

        // TL1, TL2, TL3: the output minus its reserved area now, minus the Stages strip column; the margin; the grid. On a
        // Split View Desktop (TL33, D42: `workspace`, else the one `m` shows) the whole output with its separator.
        tiling::Area areaFor(const PHLMONITOR& m, std::optional<int64_t> workspace = std::nullopt) {
            const int64_t shown = workspace ? *workspace : (m->m_activeWorkspace ? m->m_activeWorkspace->m_id : 0);
            if (tiling::splitOf(st().splits, shown)) { // on whichever output it is now (an output unplugged moves it)
                const CBox whole = m->logicalBox();
                return tiling::splitArea(toRect(whole), tiling::Grid{.originX = whole.x, .originY = whole.y, .step = tiling::gridStep(m->m_scale)});
            }
            CBox box = m->logicalBoxMinusReserved();
            if (const auto right = gf::stager::stripColumnRight(m); right && *right > box.x) {
                const double cut = std::min(*right, box.x + box.w) - box.x;
                box.x += cut;
                box.w -= cut;
            }
            const CBox output = m->logicalBox();
            return tiling::Area{.box    = toRect(box),
                                .margin = state().tilingMargins ? tiling::kMargin : 0.0,
                                .grid   = tiling::Grid{.originX = output.x, .originY = output.y, .step = tiling::gridStep(m->m_scale)}};
        }

        // Windows of inactive stages (drawn in the strip at their real places): never neighbours, never holding a zone.
        std::vector<uint64_t> stripWindows() {
            std::vector<uint64_t> out;
            for (const auto& r : st().book.records()) {
                if (const auto w = windowById(r.id); w && gf::stager::inStripStage(w))
                    out.push_back(r.id);
            }
            return out;
        }

        bool isHalf(tiling::Place place) {
            return place == tiling::Place::Left || place == tiling::Place::Right || place == tiling::Place::Top || place == tiling::Place::Bottom;
        }

        // The frames of `zones` (zone order) filled by `windows` (same order) in `area`, fitted to each window's limits.
        std::vector<tiling::Rect> fitted(const std::vector<tiling::Zone>& zones, const std::vector<PHLWINDOW>& windows, const tiling::Area& area) {
            std::vector<tiling::Rect>        frames;
            std::vector<tiling::Constraints> limits;
            frames.reserve(zones.size());
            limits.reserve(zones.size());
            for (size_t i = 0; i < zones.size(); ++i) {
                frames.push_back(tiling::zoneFrame(zones[i], area));
                limits.push_back(constraintsOf(windows[i]));
            }
            return tiling::fitFrames(zones, frames, limits, area);
        }

        // The frame a place gives `w` before its limits (TL4, TL7): its zone's; for a half next to a tiled neighbour on the
        // same output and Desktop, the rest of the work area beside it. Not for Center (it keeps the window's size).
        // TL7: the frames of the other Tiled or Resizing windows of `output`'s Desktop `workspace` (not those of an inactive stage,
        // drawn in the strip): what a half beside them leaves.
        std::vector<tiling::Rect> neighbourFramesOf(const PHLWINDOW& w, std::string_view output, int64_t workspace) {
            const auto                strip = stripWindows();
            std::vector<tiling::Rect> neighbours;
            for (const auto& r : st().book.records()) {
                if (r.id == idOf(w) || r.output != output || r.workspace != workspace || std::ranges::find(strip, r.id) != strip.end())
                    continue;
                if (r.state == tiling::TileState::Tiled || r.state == tiling::TileState::Resizing)
                    neighbours.push_back(tiling::frameOf(r.box, r.band));
            }
            return neighbours;
        }

        tiling::Rect startFrame(const PHLWINDOW& w, tiling::Place place, const tiling::Area& area, std::string_view output, int64_t workspace) {
            return tiling::placeStartFrame(place, area, isHalf(place) ? neighbourFramesOf(w, output, workspace) : std::vector<tiling::Rect>{});
        }

        // ADR-0036 D69 (D57's model for every place): `w` fits the frame `place` starts from (startFrame). Fill and Center always
        // do (Fill takes the window as far as its minimum allows, Center keeps its size).
        bool fitsPlace(const PHLWINDOW& w, tiling::Place place, const tiling::Area& area, std::string_view output, int64_t workspace) {
            if (place == tiling::Place::Fill || place == tiling::Place::Center)
                return true;
            return tiling::fitsFrame(constraintsOf(w), startFrame(w, place, area, output, workspace));
        }

        // The frame of a single place for `w` (TL4, TL7, TL8): Center keeps its size; a half next to a tiled neighbour on
        // the same output and Desktop takes the rest of the work area beside it.
        tiling::Rect placeFrame(const PHLWINDOW& w, tiling::Place place, const tiling::Area& area, std::string_view output, int64_t workspace) {
            const auto band = gf::chrome::bandOf(w);
            if (place == tiling::Place::Center)
                return tiling::centerFrame(toRect(w->layoutTarget()->position()), band, area);
            const std::array<tiling::Zone, 1>        zones{tiling::zoneOf(place).value_or(tiling::Zone{})};
            const std::array<tiling::Rect, 1>        frames{startFrame(w, place, area, output, workspace)};
            const std::array<tiling::Constraints, 1> limits{constraintsOf(w)};
            return tiling::fitFrames(zones, frames, limits, area).front();
        }

        // The frame of a placement alone: its place, its zone of its layout, or its extended sides.
        std::optional<tiling::Rect> placementFrame(const PHLWINDOW& w, const tiling::Placement& where, const tiling::Area& area, std::string_view output,
                                                   int64_t workspace) {
            if (where.place)
                return placeFrame(w, *where.place, area, output, workspace);
            if (where.sides != 0) // TL20: the sides an edge double-click extended go to this area's edges, the others stay
                return tiling::extendFrame(tiling::frameOf(toRect(w->layoutTarget()->position()), gf::chrome::bandOf(w)), where.sides, constraintsOf(w), area);
            const auto* layout = tiling::layoutById(where.layout);
            if (!layout || where.zone < 0 || where.zone >= static_cast<int>(layout->zones.size()))
                return std::nullopt;
            return fitted({layout->zones[static_cast<size_t>(where.zone)]}, {w}, area).front();
        }

        bool heldByHyprlandDrag(const PHLWINDOW& w); // below, with the drags

        // A Free floating window the plugin may fit onto the output it is on (fitToOutput): mapped on a regular Desktop (C1:
        // movable), not full screen or zoomed, not a Split View member nor on a Split View Desktop (its half is the whole
        // output's), not in a Stages strip (its place is the strip's), not tiled (a tile follows its window: relayout), and
        // not in the middle of a drag: Hyprland's move gives the window the Desktop of the output its middle crosses while the
        // button is still down (nested: a fit then had its width kept and its place taken back by the drag); the release fits
        // it (finishMove, fitAfterDrop).
        bool fitCandidate(const PHLWINDOW& w) {
            if (!w || !tiling::movable(factsOf(w)) || !w->m_isFloating || fullscreenNow(w) || !w->m_workspace || w->m_workspace->m_isSpecialWorkspace)
                return false;
            const auto& s = st();
            if (heldByHyprlandDrag(w) || s.drag.window.lock() == w)
                return false;
            if (gf::stager::inStripStage(w) || tiling::splitOfWindow(s.splits, idOf(w)) || tiling::splitOf(s.splits, w->m_workspace->m_id))
                return false;
            const auto* r = s.book.find(idOf(w));
            return !r || (r->state != tiling::TileState::Tiled && r->state != tiling::TileState::Resizing);
        }

        // Owner report on 1.0.0-rc6 (macOS model): a window that lands on an output whose work area it does not fit is made to
        // fit it (core fitIntoArea), and its titlebar is never left under that output's menu bar (FR56: Hyprland keeps such a
        // window inside the output and bottom-aligned, which put its titlebar under the bar). `why` names the move in the log;
        // `resize` false holds the titlebar below the menu bar only (the menu bar coming back resizes nothing). True when the
        // window was moved or resized.
        bool fitToOutput(const PHLWINDOW& w, std::string_view why, bool resize = true) {
            if (!g_layoutManager || !fitCandidate(w))
                return false;
            const auto m = monitorOf(w);
            if (!m || showsSpecial(m))
                return false;
            const auto   target = w->layoutTarget();
            const double band   = gf::chrome::bandOf(w);
            const CBox   now    = target->position();
            CBox         surface = now;
            const auto   frame   = resize ? tiling::fitIntoArea(tiling::frameOf(toRect(now), band), areaFor(m, w->m_workspace->m_id).box, constraintsOf(w))
                                          : std::nullopt;
            if (frame)
                surface = toCBox(tiling::surfaceOf(*frame, band));
            surface = gf::topClamp::belowMenuBar(w, surface, band);
            if (sameBox(surface, now))
                return false;
            g_layoutManager->setTargetGeom(surface, target);
            logRequest(Log::INFO, "window {:x} {}: made to fit {} at {:.0f},{:.0f} {:.0f}x{:.0f}", idOf(w), why, m->m_name, surface.x, surface.y, surface.w, surface.h);
            return true;
        }

        void scheduleAfter();

        // Posts the `tiling` notice when the records changed since the latest one; refusals, the unload and `force` (the Split
        // View Desktops changed, TL33) always post. A Split View Desktop waiting for its second window is checked again after
        // a change: the suggestion of its picker is over once the records changed (splitCheck).
        void notify(tiling::Reason reason, bool force = false) {
            auto&      s      = st();
            const auto gen    = s.book.generation();
            const bool always = force || reason == tiling::Reason::Invalid || reason == tiling::Reason::Locked || reason == tiling::Reason::Unavailable;
            if (std::ranges::any_of(s.splits, &tiling::SplitDesk::waiting) && gen != s.posted)
                scheduleAfter();
            if (!always && gen == s.posted)
                return;
            s.posted = gen;
            gf::ipc::postEvent(gf::events::Key{.channel = gf::events::Channel::Tiling, .id = 0}, tiling::noticeJson(gen, reason));
        }

        // Records of closed windows are dropped; a Tiled window whose box is not the one the plugin gave it (an app's own
        // configure, a keyboard move or resize, a rule) becomes Free (TL10).
        void reconcile() {
            auto&                 s       = st();
            const auto            dragged = s.memberDrag.lock();
            std::vector<uint64_t> gone;
            for (const auto& r : s.book.records()) {
                const auto w      = windowById(r.id);
                const auto target = w && w->m_isMapped ? w->layoutTarget() : nullptr;
                if (tiling::staleRecord(r, target != nullptr, target && sameBox(target->position(), toCBox(r.box)), dragged ? idOf(dragged) : 0))
                    gone.push_back(r.id);
            }
            for (const auto id : gone)
                s.book.forget(id);
            if (!gone.empty())
                notify(tiling::Reason::Forgotten);
        }

        void applySurface(const PHLWINDOW& w, const CBox& surface) {
            const auto target = w->layoutTarget();
            if (target && !sameBox(target->position(), surface))
                g_layoutManager->setTargetGeom(surface, target);
        }

        // Why tiled windows are placed again.
        enum class ERelayout : uint8_t {
            Margins,    // TL2: every Tiled window; one that cannot be placed now (an inactive stage) is deferred, Suspended
                        // ones are marked
            OutputGone, // TL11: the windows of a removed output, on the output Hyprland moved them to; one that cannot be
                        // placed is Free
            CatchUp,    // the deferred ones that can be placed now; the others keep waiting
        };

        // Places Tiled windows again from their placement on the work area now. Groups of an arrangement are fitted
        // together; halves come last (TL7 reads the others' new frames).
        void relayout(ERelayout why) {
            auto& s = st();
            if (!g_layoutManager)
                return;
            reconcile();
            struct SItem {
                uint64_t          id = 0;
                PHLWINDOW         w;
                PHLMONITOR        m;
                tiling::Placement where;
                uint64_t          group     = 0;
                int64_t           workspace = 0;
                bool              done      = false;
            };
            const bool            margins = why == ERelayout::Margins;
            std::vector<SItem>    items;
            std::vector<uint64_t> suspended;
            std::vector<uint64_t> waiting; // cannot be placed now (an inactive stage): placed once it can be, still checked
            std::vector<uint64_t> lost;    // its output went away and it cannot be placed: Free
            for (const auto& r : s.book.records()) {
                if (r.state == tiling::TileState::Suspended) {
                    if (margins)
                        suspended.push_back(r.id);
                    continue;
                }
                const bool selected = margins || (why == ERelayout::OutputGone ? r.relayout : r.deferred);
                if (r.state != tiling::TileState::Tiled || !selected)
                    continue;
                const auto w  = windowById(r.id);
                const bool ok = placeable(w);
                PHLMONITOR m  = ok && margins ? monitorByName(r.output) : nullptr;
                if (!m && ok)
                    m = monitorOf(w);
                if (!m) {
                    if (why == ERelayout::OutputGone)
                        lost.push_back(r.id); // never left with relayout set: it would never be checked again
                    else if (margins)
                        waiting.push_back(r.id);
                    continue;
                }
                items.push_back(SItem{.id = r.id, .w = w, .m = m, .where = r.where, .group = r.group, .workspace = w->m_workspace->m_id});
            }
            for (const auto id : suspended)
                s.book.markRelayout(id, true);
            for (const auto id : waiting)
                s.book.markDeferred(id, true);
            for (const auto id : lost)
                s.book.forget(id);
            const auto place = [&s](SItem& item, const tiling::Rect& frame) {
                const CBox surface = toCBox(tiling::surfaceOf(frame, gf::chrome::bandOf(item.w)));
                applySurface(item.w, surface);
                s.book.setBox(item.id, toRect(surface), item.m->m_name);
                item.done = true;
            };
            // Arrangement groups, fitted together on their output.
            for (auto& first : items) {
                if (first.done || first.where.layout.empty() || first.group == 0)
                    continue;
                const auto* layout = tiling::layoutById(first.where.layout);
                if (!layout)
                    continue;
                std::vector<SItem*>       members;
                std::vector<tiling::Zone> zones;
                std::vector<PHLWINDOW>    windows;
                for (auto& other : items) {
                    if (other.done || other.group != first.group || other.where.layout != first.where.layout || other.m != first.m || other.workspace != first.workspace)
                        continue;
                    if (other.where.zone < 0 || other.where.zone >= static_cast<int>(layout->zones.size()))
                        continue;
                    members.push_back(&other);
                    zones.push_back(layout->zones[static_cast<size_t>(other.where.zone)]);
                    windows.push_back(other.w);
                }
                if (members.empty())
                    continue;
                const auto frames = fitted(zones, windows, areaFor(first.m, first.workspace));
                for (size_t i = 0; i < members.size(); ++i)
                    place(*members[i], frames[i]);
            }
            // Single zones and places, halves last.
            for (const bool halves : {false, true}) {
                for (auto& item : items) {
                    if (item.done || (item.where.place && isHalf(*item.where.place)) != halves)
                        continue;
                    if (const auto frame = placementFrame(item.w, item.where, areaFor(item.m, item.workspace), item.m->m_name, item.workspace))
                        place(item, *frame);
                }
            }
            notify(tiling::Reason::Relaid);
        }

        // Reconciles the records, then places the deferred windows that can be placed now (TL2: the margins changed while
        // they were in an inactive stage): at the next placement or state read once they can be.
        void catchUp() {
            reconcile();
            const auto records = st().book.records();
            if (std::ranges::any_of(records, [](const tiling::TileRecord& r) { return r.state == tiling::TileState::Tiled && r.deferred; }))
                relayout(ERelayout::CatchUp);
        }

        // TL28: what fills the rest of the layout of `askerId` on `m`: its empty zones (their frames in the work area now) and the
        // windows that can take them (D26): the tileable windows of that output's Desktop in the active stage, top first, then
        // the windows minimized from that output, the latest first; never one that holds a zone of that layout already.
        // nullopt when no zone is empty or no window fits (nothing is shown then).
        std::optional<tiling::Suggestion> suggestionFor(uint64_t askerId, const PHLMONITOR& m, uint64_t exclude = 0) {
            const auto& s      = st();
            const auto* asker  = s.book.find(askerId);
            const auto* layout = asker ? tiling::layoutById(asker->where.layout) : nullptr;
            if (!layout || !m || !m->m_activeWorkspace || !Desktop::windowState())
                return std::nullopt;
            const auto held  = tiling::zonesHeld(s.book.records(), *asker);
            const auto empty = tiling::emptyZones(*layout, held);
            if (empty.empty())
                return std::nullopt;
            tiling::Suggestion sg{.generation = s.book.generation(), .asker = askerId, .layout = asker->where.layout, .output = m->m_name, .zones = empty, .frames = {}, .windows = {}};
            const auto         area = areaFor(m);
            for (const int z : empty)
                sg.frames.push_back(tiling::zoneFrame(layout->zones[static_cast<size_t>(z)], area));
            const auto inLayout = [&s, asker](uint64_t id) {
                const auto* r = s.book.find(id);
                return r && (r->id == asker->id || (asker->group != 0 && r->group == asker->group && r->where.layout == asker->where.layout));
            };
            // On a Split View Desktop the windows of the Desktop it came from (TL33), else those of the Desktop shown.
            const auto*   split = tiling::splitOf(s.splits, m->m_activeWorkspace->m_id);
            const int64_t from  = split ? split->home : m->m_activeWorkspace->m_id;
            const auto&   all   = Desktop::windowState()->windows(); // bottom to top
            // A zone takes only a window that fits it (TL8: a Split View's other half since the nested pass of 1ee992e, MAJOR C;
            // every zone since D69, so that a pick never shifts the layout's rows or columns).
            const auto fits = [&](const PHLWINDOW& w) { return tiling::fitsFrame(constraintsOf(w), sg.frames.front()); };
            std::vector<uint64_t> candidates;
            for (auto it = all.rbegin(); it != all.rend(); ++it) {
                const auto& w = *it;
                if (w && w->m_workspace && w->m_workspace->m_id == from && placeable(w) && monitorOf(w) == m && !inLayout(idOf(w)) && fits(w))
                    candidates.push_back(idOf(w));
            }
            for (const auto id : gf::minimizer::minimizedFrom(m->m_name)) {
                if (const auto w = windowById(id); tileableKind(w) && !inLayout(id) && fits(w))
                    candidates.push_back(id);
            }
            // Capped after `exclude` is left out (core offerWindows; the follow-up of #78: Replace offered 11 of 12 or more).
            sg.windows = tiling::offerWindows(candidates, exclude);
            if (sg.windows.empty())
                return std::nullopt;
            return sg;
        }

        // Return to Previous Size and a window coming back to a taken zone: `before`, centred in the free area of the
        // output the window is on when it lies off every output (its output went away).
        CBox beforeBox(const PHLWINDOW& w, const tiling::Rect& before) {
            CBox box = toCBox(before);
            if (monitorAt(box.middle()))
                return box;
            auto m = monitorOf(w);
            if (!m && Desktop::focusState())
                m = Desktop::focusState()->monitor();
            if (m) {
                const CBox area = m->logicalBoxMinusReserved();
                box.x           = std::round(area.x + (area.w - box.w) / 2);
                box.y           = std::round(area.y + (area.h - box.h) / 2);
            }
            return box;
        }

        // Return to Previous Size (tile(address, "previous"), a second Zoom of a filled window): `before` put back, the window
        // Free. False when it has no record, cannot be placed now (TL9) or is a Split View member (its Desktop places it).
        // A window moved to another output since (move_to, a drop there) stays on that output and its Desktop: `before` at
        // the same relative place of that output's work area, its size kept (core moveToArea, as move_to places a Free
        // window; review of fix/zoom-is-fill: it went back to the old output while its Desktop stayed the new one's).
        bool returnToPrevious(const PHLWINDOW& w) {
            auto&          s  = st();
            const uint64_t id = idOf(w);
            const auto*    r  = placeable(w) && g_layoutManager && !tiling::splitOfWindow(s.splits, id) ? s.book.find(id) : nullptr;
            const double   band   = r ? r->band : 0.0;
            const auto     before = r ? s.book.takeBefore(id) : std::nullopt;
            if (!before)
                return false;
            CBox       box  = beforeBox(w, *before);
            const auto now  = monitorOf(w);
            const auto then = monitorAt(box.middle());
            if (now && then && now != then) {
                const auto frame = tiling::moveToArea(tiling::frameOf(*before, band), areaFor(then).box, areaFor(now, w->m_workspace ? std::optional<int64_t>{w->m_workspace->m_id} : std::nullopt).box);
                box              = toCBox(tiling::surfaceOf(frame, band));
            }
            g_layoutManager->setTargetGeom(box, w->layoutTarget());
            followOutput(w); // its Desktop is the one of the output under its middle (TL21, D9)
            notify(tiling::Reason::Forgotten);
            return true;
        }

        // ADR-0036 D78: the window has no tile record and its frame is the Fill frame of its work area now (within 1 px): a
        // window the plugin filled before a reload, which forgot its record.
        bool atFillFrame(const PHLWINDOW& w) {
            if (!placeable(w) || st().book.find(idOf(w)))
                return false;
            const auto m = monitorOf(w);
            if (!m)
                return false;
            const int64_t      workspace = w->m_workspace->m_id;
            const double       band      = gf::chrome::bandOf(w);
            const tiling::Rect frame     = tiling::frameOf(toRect(w->layoutTarget()->position()), band);
            const tiling::Rect fill      = placeFrame(w, tiling::Place::Fill, areaFor(m, workspace), m->m_name, workspace);
            return std::abs(frame.x - fill.x) <= 1 && std::abs(frame.y - fill.y) <= 1 && std::abs(frame.w - fill.w) <= 1 && std::abs(frame.h - fill.h) <= 1;
        }

        // ADR-0036 D78: the Zoom of a window at the Fill frame without a record (no box from before is known): the Center
        // place's frame (its size, at most tiling.centerMaxFraction of the work area, in the middle), the window Free, so the
        // next Zoom fills it again and the one after comes back here.
        bool unfill(const PHLWINDOW& w) {
            const auto m = monitorOf(w);
            if (!m || !g_layoutManager)
                return false;
            const int64_t      workspace = w->m_workspace->m_id;
            const tiling::Rect frame     = placeFrame(w, tiling::Place::Center, areaFor(m, workspace), m->m_name, workspace);
            g_layoutManager->setTargetGeom(toCBox(tiling::surfaceOf(frame, gf::chrome::bandOf(w))), w->layoutTarget());
            return true;
        }

        // Hyprland's own maximized mode toggled, as the zoom was before ADR-0036 D78 (and still is without window-tiling).
        void toggleMaximized(const PHLWINDOW& w) {
            const auto& fs = Fullscreen::controller();
            if (!fs)
                return;
            const auto target = fs->getFullscreenModes(w).internal == Fullscreen::FSMODE_MAXIMIZED ? Fullscreen::FSMODE_NONE : Fullscreen::FSMODE_MAXIMIZED;
            fs->setFullscreenMode(w, target, target, false);
        }

        bool hyprlandDrag(eMouseBindMode mode) {
            return mode == MBIND_MOVE || mode == MBIND_RESIZE || mode == MBIND_RESIZE_BLOCK_RATIO || mode == MBIND_RESIZE_FORCE_RATIO;
        }

        bool hyprlandDragging() {
            if (!g_layoutManager)
                return false;
            const auto& drag = g_layoutManager->dragController();
            return drag && hyprlandDrag(drag->mode());
        }

        // One of Hyprland's drags holds `w` now (a client-chrome window dragged out of its zoom restarts one, ADR-0015 P4).
        bool heldByHyprlandDrag(const PHLWINDOW& w) {
            if (!hyprlandDragging())
                return false;
            const auto target = g_layoutManager->dragController()->target();
            return target && target->window() == w;
        }

        // TL10: a Suspended window comes back. On the output Hyprland shows it on (under its middle, else the focused one):
        // its own box when that output is the record's and nothing re-placed it meanwhile, else its zone placed there.
        // From a special workspace the zone must be free (else Free at `before`); from full screen or zoom it is put back.
        void resumeNow(const SResume& resume) {
            auto&      s = st();
            const auto r = s.book.find(resume.id);
            if (!r || r->state != tiling::TileState::Suspended)
                return;
            const auto w = windowById(resume.id);
            if (!w) {
                s.book.forget(resume.id);
                notify(tiling::Reason::Forgotten);
                return;
            }
            if (!g_layoutManager || fullscreenNow(w) || !w->m_workspace || w->m_workspace->m_isSpecialWorkspace)
                return; // still full screen, zoomed or minimized: stays Suspended (its own event resumes it)
            if (!placeable(w)) {
                s.book.forget(resume.id); // back, but not tileable any more (pinned, a parent, a strip): Free for good
                notify(tiling::Reason::Forgotten);
                return;
            }
            if (heldByHyprlandDrag(w)) {
                s.book.forget(resume.id); // dragged out of its zoom: it leaves its tile under the pointer
                notify(tiling::Reason::Moved);
                return;
            }
            const CBox current = w->layoutTarget()->position();
            auto       m       = monitorAt(current.middle());
            if (!m && Desktop::focusState())
                m = Desktop::focusState()->monitor();
            if (!m || !m->m_enabled)
                return;
            const int64_t           workspace = w->m_workspace->m_id;
            const auto              band      = gf::chrome::bandOf(w);
            const tiling::Placement where     = r->where;
            const uint64_t          group     = r->group;
            const tiling::Rect      before    = r->before;
            std::optional<tiling::Rect> frame;
            if (r->output == m->m_name && !r->relayout)
                frame = tiling::frameOf(r->box, r->band);
            else
                frame = placementFrame(w, where, areaFor(m, workspace), m->m_name, workspace);
            const auto strip = stripWindows();
            if (frame && (!resume.checkFree || s.book.zoneFree(*frame, m->m_name, workspace, resume.id, strip))) {
                const CBox surface = toCBox(tiling::surfaceOf(*frame, band));
                applySurface(w, surface);
                s.book.placed(resume.id, toRect(current), toRect(surface), band, where, m->m_name, workspace, group);
                notify(tiling::Reason::Restored);
                return;
            }
            g_layoutManager->setTargetGeom(beforeBox(w, before), w->layoutTarget());
            s.book.forget(resume.id);
            notify(tiling::Reason::Forgotten);
        }

        // Resizing -> Tiled with the box Hyprland's resize left (the top clamp has run: it is scheduled first).
        void finishResize() {
            auto&      s = st();
            const auto w = std::exchange(s.resizing, PHLWINDOWREF{}).lock();
            const auto t = w ? w->layoutTarget() : nullptr;
            if (!t)
                return; // closed meanwhile: reconcile() drops the record
            s.book.endResize(idOf(w), toRect(t->position()));
            notify(tiling::Reason::Resized);
        }

        // ---- drags (TL16-TL20) ----

        void scheduleAfter();     // below: its callback is afterEvents
        void gatherStrays();      // below, with onMonitorRemoved
        void holdUnderMenuBars(); // below, with scheduleAfter

        uint64_t nowMs() {
            return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
        }

        // Alt (Option) held on any keyboard.
        bool altHeld() {
            return g_pInputManager && (g_pInputManager->getModsFromAllKBs() & HL_MODIFIER_ALT) != 0;
        }

        // A preview frame appears or goes: it is drawn again.
        void damage(const std::optional<Snap>& snap) {
            if (snap && g_pHyprRenderer)
                g_pHyprRenderer->damageBox(snap->frame);
        }

        std::optional<Snap> shownOf(const SDrag& d) {
            return d.dwell.shown() ? d.candidate : std::nullopt;
        }

        // The preview delay passed with the pointer at rest: the drag's place is read again and shows if the pointer is
        // still on it. No button held any more: the drag ended without its end seen here. (Not tied to ready(): the titlebar
        // drag tiles without the tiling listeners; stop() removes the timer at the unload.)
        void previewDue() {
            auto&      s = st();
            const auto w = s.drag.window.lock();
            if (!w || !g_pInputManager)
                return;
            if (!g_pInputManager->hasHeldButtons()) {
                dragDone();
                return;
            }
            dragMotion(w, g_pInputManager->getMouseCoordsInternal());
        }

        void armPreviewTimer(uint64_t ms) {
            auto& s = st();
            if (!g_pEventLoopManager)
                return;
            if (!s.previewTimer) {
                s.previewTimer = makeShared<CEventLoopTimer>(
                    std::nullopt, [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) { gf::guarded("tiling preview delay", [] { previewDue(); }); }, nullptr);
                g_pEventLoopManager->addTimer(s.previewTimer);
            }
            s.previewTimer->updateTimeout(std::chrono::milliseconds(ms));
        }

        // TL16: one of Hyprland's moves of a tiled window passed the drag threshold: Moving, with its size from before
        // under the pointer at the same place of its grip (macOS). Hyprland keeps the drag's start to itself
        // (CDragStateController::m_beginDragPositionXY), so its drag is ended and begun again from that box, with the
        // exclusive device grab an app's move request asked for (CWindow::onXDGMoveRequest), as client chrome does after a
        // zoom (ClientChrome.cpp P4).
        void restartAtSizeBefore(const PHLWINDOW& w, const SP<Layout::ITarget>& target, tiling::Rect tiled, const Vector2D& grip, const Vector2D& pointer) {
            if (!movable(w)) {
                logRequest(Log::INFO, "window {:x} closed or unmapped: its move not restarted (gate C1)", idOf(w));
                return;
            }
            const auto& drag      = g_layoutManager->dragController();
            const bool  exclusive = drag && drag->exclusiveDeviceGrab();
            const auto  before    = beginMove(w);
            if (!before)
                return;
            const auto box = gf::titlebar::unzoomedDragBox(gf::titlebar::Rect{tiled.x, tiled.y, tiled.w, tiled.h}, before->w, before->h, grip.x, grip.y, pointer.x,
                                                           pointer.y);
            g_layoutManager->endDragTarget();
            g_layoutManager->setTargetGeom(CBox{box.x, box.y, box.w, box.h}, target);
            g_layoutManager->beginDragTarget(target, MBIND_MOVE, std::nullopt, exclusive);
            logRequest(Log::DEBUG, "Hyprland's move of {:x} leaves its tile: {:.0f}x{:.0f} at {:.0f},{:.0f}", idOf(w), box.w, box.h, box.x, box.y);
        }

        // One of Hyprland's moves (an app's toolbar drag, Super+drag) is at the pointer, before Hyprland applies the motion:
        // a tiled window leaves its tile once past the drag threshold (until then it stays Tiled: its release puts it back);
        // a movable floating window shows the place under the pointer (dragMotion). A window Hyprland itself tiles, dragged
        // out of its layout for the drag only (CDragStateController::draggingTiled), shows none: Hyprland tiles it again.
        void hyprlandMove(const PHLWINDOW& w, const SP<Layout::ITarget>& target) {
            auto& s = st();
            if (!w || !target || !g_pInputManager)
                return;
            const auto& drag = g_layoutManager->dragController();
            if (drag && drag->draggingTiled()) {
                if (s.drag.hyprland)
                    dragDone();
                return;
            }
            if (tiling::splitOfWindow(s.splits, idOf(w))) {
                if (s.drag.hyprland)
                    dragDone(); // TL33: a Split View window shows no place; its release puts it back in its half (finishMove)
                return;
            }
            if (s.moveFrom.window.lock() != w) {
                const auto from = monitorOf(w);
                s.moveFrom      = SMoveFrom{.window = w, .output = from ? from->m_name : std::string{}};
            }
            const Vector2D pointer = g_pInputManager->getMouseCoordsInternal();
            if (const auto r = s.book.find(idOf(w)); r && r->state == tiling::TileState::Tiled) {
                const Vector2D grip = s.press.value_or(pointer);
                if (!gf::titlebar::exceedsDragThreshold(pointer.x - grip.x, pointer.y - grip.y))
                    return;
                restartAtSizeBefore(w, target, r->box, grip, pointer);
            }
            dragMotion(w, pointer);
            s.drag.hyprland = true;
        }

        // TL16, after Hyprland ended one of its moves: the place shown at the release is tiled; a tiled window released
        // under the drag threshold goes back to its tile; a Moving one released elsewhere is Free. A release that did not
        // end the drag (another button) changes nothing: the drag and its preview go on.
        void finishMove(const SMoveRelease& rel) {
            auto& s = st();
            if (hyprlandDragging())
                return;
            const auto w    = rel.window.lock();
            const auto from = std::exchange(s.moveFrom, SMoveFrom{});
            if (s.drag.hyprland)
                dragDone();
            if (!w)
                return;
            if (!movable(w)) {
                endMove(w); // closed or unmapped meanwhile (gate C1): nothing is moved
                return;
            }
            if (rel.snap && gf::deferredFocus::sessionLocked()) {
                endMove(w); // nothing tiles behind the lock screen (TL34, behind Hyprland's own refusal of drags then)
                return;
            }
            if (const auto* d = tiling::splitOfWindow(s.splits, idOf(w))) {
                // TL33, D46: a Split View window does not leave its half by one of Hyprland's moves (Super+drag): back in it at
                // the release, unless the move took it to another output's Desktop (it left the Split View: splitCheck).
                if (const auto r = s.book.find(idOf(w)); r && w->m_workspace && w->m_workspace->m_id == d->workspace)
                    applySurface(w, toCBox(r->box));
                return;
            }
            if (rel.snap) {
                if (!tile(w, rel.snap->place, rel.snap->monitor.lock())) {
                    endMove(w); // refused (D69: its minimum grew since the preview): Free where it was dropped,
                    fitToOutput(w, "dropped where its tile was refused"); // below the menu bar (the top clamp left it to the tile)
                }
                return;
            }
            if (const auto r = s.book.find(idOf(w)); r && r->state == tiling::TileState::Tiled) {
                applySurface(w, toCBox(r->box));
                return;
            }
            endMove(w);
            // Released on another output than the one it was on (owner report on 1.0.0-rc6): it fits that output's work area.
            const auto now = monitorOf(w);
            if (from.window.lock() == w && now && now->m_name != from.output)
                fitToOutput(w, "dropped on another output by Hyprland's move");
        }

        // TL20: a click on `w`'s resize border at `at` (`timeMs`: its press). Two on the same sides within the double-click
        // time and distance (core CClickTracker) extend those sides, with Alt their opposite sides too, once Hyprland ended
        // the resize the second press began.
        void borderClick(const PHLWINDOW& w, const Vector2D& at, uint32_t timeMs) {
            auto&         s     = st();
            const uint8_t sides = tiling::sidesAt(at.x, at.y, toRect(w->getWindowMainSurfaceBox()));
            if (s.border.window.lock() != w || s.border.sides != sides) {
                s.border.window = w;
                s.border.sides  = sides;
                s.border.clicks.reset();
            }
            if (!s.border.clicks.press(timeMs, at.x, at.y))
                return;
            s.extend = SExtend{.window = w, .sides = tiling::extendedSides(sides, altHeld())};
            scheduleAfter();
        }

        // TL20, after Hyprland ended the second click's resize: the sides go to the work area's edges (core extendFrame) and
        // the window is tiled with a box from before; all four sides (Alt on a corner) is Fill.
        void extendSides(const SExtend& e) {
            auto&      s = st();
            const auto w = e.window.lock();
            if (!w || e.sides == 0 || !placeable(w) || !g_layoutManager || hyprlandDragging() || gf::deferredFocus::sessionLocked() ||
                tiling::splitOfWindow(s.splits, idOf(w)))
                return; // locked: nothing tiles behind the lock screen (TL34); a Split View window keeps its half (TL33)
            const auto m = monitorOf(w);
            if (!m || showsSpecial(m))
                return;
            if (e.sides == tiling::kAllSides) {
                tile(w, tiling::Place::Fill, m);
                return;
            }
            catchUp();
            const CBox current = w->layoutTarget()->position();
            const auto band    = gf::chrome::bandOf(w);
            const auto frame   = tiling::extendFrame(tiling::frameOf(toRect(current), band), e.sides, constraintsOf(w), areaFor(m));
            const CBox surface = toCBox(tiling::surfaceOf(frame, band));
            applySurface(w, surface);
            tiling::Placement where;
            where.sides = e.sides;
            s.book.placed(idOf(w), toRect(current), toRect(surface), band, where, m->m_name, w->m_workspace->m_id, 0);
            logRequest(Log::DEBUG, "edge double-click {:x}: {} extended on {}", idOf(w), tiling::sidesName(e.sides), m->m_name);
            notify(tiling::Reason::Placed);
        }

        // After Hyprland's own handling of the events that scheduled it: a resize that ended, outputs that went away,
        // windows that came back, a move released, an edge double-clicked, a key that may have changed Alt during a drag.
        // ---- the Full Screen tile (TL33) ----

        // Step 6e (D73; the review of #99): a window that left a Split View any way (moved to another Desktop by a key, the
        // plugin unloaded) gets its titlebar back where it can be reached: its frame, with the band it has again above it,
        // below the menu bar of its output (a member's surface sat at the output's top edge: its bar came back above the
        // output). A window back in a Split View meanwhile, in full screen or zoomed is left alone; a hidden one (minimized,
        // on a special workspace) waits until it shows again (false: later). Unsplit's own places (its box from before, its
        // tile) are below the menu bar already: nothing moves then.
        bool titlebarBackInReach(const PHLWINDOW& w) {
            if (!w)
                return true; // closed
            if (!w->m_isMapped || w->isHidden() || !w->m_workspace || w->m_workspace->m_isSpecialWorkspace)
                return false;
            if (fullscreenNow(w) || !tiling::movable(factsOf(w)) || !g_layoutManager || tiling::splitOfWindow(st().splits, idOf(w)))
                return true;
            const auto target = w->layoutTarget();
            if (!target)
                return true;
            const CBox current = target->position();
            const CBox held    = gf::topClamp::belowMenuBar(w, current, gf::chrome::bandOf(w));
            if (!sameBox(held, current)) {
                applySurface(w, held);
                logRequest(Log::DEBUG, "split: {:x} left a Split View: its titlebar back below the menu bar, at {:.0f},{:.0f}", idOf(w), held.x, held.y);
            }
            return true;
        }

        // Step 6e (D73): a member's titlebar is away (CGrassfieldTitlebar::shouldShow reads inSplit) and no band is kept above
        // it. The windows that joined or left a Split View Desktop since the last call have theirs refreshed: it goes, or comes
        // back above the window, then in reach (titlebarBackInReach). After every change of the members (a split, a pick, an
        // unsplit, splitCheck's prune).
        void titlebarsFollowSplits() {
            auto&      s       = st();
            auto       now     = tiling::splitMembers(s.splits);
            const auto changed = tiling::membersChanged(s.chromeMembers, now);
            for (const auto id : changed) {
                if (const auto w = windowById(id))
                    CGrassfieldTitlebar::refreshWindow(w);
                if (!std::ranges::binary_search(now, id))
                    s.backInReach.push_back(id); // it left: its titlebar comes back where it can be reached
            }
            s.chromeMembers = std::move(now);
            if (!gf::deferredFocus::sessionLocked()) // D55: nothing moves behind the lock; at the unlock's check instead
                std::erase_if(s.backInReach, [](uint64_t id) { return titlebarBackInReach(windowById(id)); });
        }

        // The Split View Desktop `workspace` got its second window, or its first one fills it: one window left alone is
        // filled from now on (D43).
        void settleSplit(int64_t workspace) {
            for (auto& d : st().splits) {
                if (d.workspace == workspace)
                    d.waiting = false;
            }
        }

        // The output a Split View Desktop is on now (Hyprland moves its workspace when its output goes away), else the one it
        // was made on.
        PHLMONITOR splitMonitor(const tiling::SplitDesk& d) {
            const auto ws = State::workspaceState() ? State::workspaceState()->query().id(d.workspace).run() : nullptr;
            if (ws && ws->m_monitor)
                return ws->m_monitor.lock();
            return monitorByName(d.output);
        }

        // The frame of half `zone` (0 left, 1 right) of a Split View Desktop on `m` (core splitArea, D42).
        tiling::Rect splitHalf(const PHLMONITOR& m, int zone) {
            const CBox  whole = m->logicalBox();
            const auto  area  = tiling::splitArea(toRect(whole), tiling::Grid{.originX = whole.x, .originY = whole.y, .step = tiling::gridStep(m->m_scale)});
            const auto* lr    = tiling::layoutById("left-right");
            return tiling::zoneFrame(lr->zones[static_cast<size_t>(zone == 1 ? 1 : 0)], area);
        }

        // TL33 (step 6b): the separator's double-click: the two members of `d` back to their halves of the whole output (their
        // zones of "left-right", fitted as the split placed them; TL8). Nothing while locked, nor when a member is not Tiled in its
        // half (full screen or zoomed: Suspended, it comes back to its half anyway).
        void splitHalvesAgain(const tiling::SplitDesk& d) {
            auto&       s      = st();
            const auto  m      = splitMonitor(d);
            const auto* layout = tiling::layoutById("left-right");
            if (!m || !layout || d.members.size() != 2 || gf::deferredFocus::sessionLocked())
                return;
            std::vector<tiling::Zone> zones;
            std::vector<PHLWINDOW>    windows;
            for (const auto id : d.members) {
                const auto w = windowById(id);
                const auto r = s.book.find(id);
                if (!w || !r || r->state != tiling::TileState::Tiled || r->where.layout != layout->id || r->where.zone < 0 || r->where.zone > 1)
                    return;
                zones.push_back(layout->zones[static_cast<size_t>(r->where.zone)]);
                windows.push_back(w);
            }
            const auto frames = fitted(zones, windows, areaFor(m, d.workspace));
            for (size_t i = 0; i < windows.size(); ++i) {
                const CBox surface = toCBox(tiling::surfaceOf(frames[i], gf::chrome::bandOf(windows[i])));
                applySurface(windows[i], surface);
                s.book.setBox(d.members[i], toRect(surface), m->m_name);
            }
            logRequest(Log::DEBUG, "split: the separator of Desktop {} double-clicked: equal halves again", d.workspace);
            notify(tiling::Reason::Resized);
        }

        // The suggestion of the Split View that window `id` started is still pending (published, nothing changed since): its
        // picker may still give it its second window.
        bool picking(uint64_t id) {
            const auto& s = st();
            return s.suggestion && s.suggestion->asker == id && s.suggestion->generation == s.book.generation();
        }

        // D43: the one window left on the Split View Desktop `d` takes all of it, unless it already does.
        void splitFill(const PHLWINDOW& w, const tiling::SplitDesk& d) {
            auto&      s = st();
            const auto m = splitMonitor(d);
            const auto r = s.book.find(idOf(w));
            if (!m || !tiling::movable(factsOf(w)) || fullscreenNow(w) || (r && r->where.place == tiling::Place::Fill && r->workspace == d.workspace))
                return; // full screen or zoomed: its record is Suspended, and comes back filling (TL12)
            const auto target  = w->layoutTarget();
            const CBox current = target->position();
            const auto band    = gf::chrome::bandOf(w);
            const CBox surface = toCBox(tiling::surfaceOf(placeFrame(w, tiling::Place::Fill, areaFor(m, d.workspace), m->m_name, d.workspace), band));
            applySurface(w, surface);
            s.book.placed(idOf(w), toRect(current), toRect(surface), band, tiling::Placement{.place = tiling::Place::Fill, .layout = {}, .zone = -1}, m->m_name,
                          d.workspace, 0);
            logRequest(Log::DEBUG, "split: window {:x} alone on Desktop {}: it fills it", idOf(w), d.workspace);
            notify(tiling::Reason::Placed);
        }

        // TL33, D43, D50, D52: a Split View Desktop keeps its two members, whatever their state (an app's own full screen, a
        // zoom: still members); a member closed, minimized or moved to another Desktop leaves it; one left fills it alone (not
        // while its second window is being chosen, nor once that choice is over without one: then it fills too); none left
        // ends it, and its output goes back to the home Desktop when it showed it. While the session is locked no window
        // moves and no Desktop is switched: the fill and the end wait for the unlock (D55). Another window on that workspace is no member and changes nothing. Posts the notice when a Desktop ended or
        // its members changed, also without a tile record changing (the shell reads `splits`).
        void splitCheck() {
            auto& s = st();
            if (s.splits.empty() || !Desktop::windowState() || !State::workspaceState()) {
                titlebarsFollowSplits();
                return;
            }
            bool                           changed = false;
            std::vector<tiling::SplitDesk> ended;
            for (auto& d : s.splits) {
                const auto            ws = State::workspaceState()->query().id(d.workspace).run();
                std::vector<uint64_t> on;
                if (ws) {
                    for (const auto& w : Desktop::windowState()->windows()) {
                        if (w && w->m_isMapped && w->m_workspace == ws)
                            on.push_back(idOf(w));
                    }
                }
                changed |= tiling::pruneMembers(d, on);
                if (ws && ws->m_monitor && ws->m_monitor->m_name != d.output) {
                    d.output = ws->m_monitor->m_name; // an output unplugged: Hyprland moved the Desktop (MINOR 9 of #48)
                    changed  = true;
                }
                const bool wasWaiting = d.waiting;
                if (d.members.size() != 1 || !picking(d.members.front()))
                    d.waiting = false; // two members, or the picker's suggestion is over (dismissed, superseded): no more waiting
                changed |= wasWaiting != d.waiting;
                switch (tiling::splitStep(d.members.size(), d.waiting)) {
                    case tiling::SplitStep::Keep: break;
                    case tiling::SplitStep::Fill:
                        if (const auto w = windowById(d.members.front()); w && !gf::deferredFocus::sessionLocked())
                            splitFill(w, d); // while locked: at the unlock (D55)
                        break;
                    case tiling::SplitStep::End:
                        if (!gf::deferredFocus::sessionLocked())
                            ended.push_back(d);
                        break;
                }
            }
            for (const auto& d : ended) {
                std::erase(s.splits, d);
                changed = true;
                logRequest(Log::DEBUG, "split: Desktop {} has no window of its own left: it ends", d.workspace);
                const auto m = splitMonitor(d);
                if (!m || !m->m_activeWorkspace || m->m_activeWorkspace->m_id != d.workspace)
                    continue;
                bool empty = true; // another window there keeps the Desktop shown, an ordinary one now (D52)
                for (const auto& w : Desktop::windowState()->windows()) {
                    if (w && w->m_isMapped && w->m_workspace && w->m_workspace->m_id == d.workspace)
                        empty = false;
                }
                if (!empty)
                    continue;
                auto home = State::workspaceState()->query().id(d.home).run();
                if (!home)
                    home = State::workspaceState()->create(d.home, m->m_id);
                if (!home || home->m_isSpecialWorkspace)
                    continue;
                if (const auto result = Config::Actions::changeWorkspace(home); !result)
                    logRequest(Log::WARN, "split: going back to Desktop {} failed: {}", d.home, result.error().message);
            }
            std::erase_if(s.splitHomes, [&s](const auto& kv) { return !tiling::splitOfWindow(s.splits, kv.first); });
            titlebarsFollowSplits();
            if (changed)
                notify(tiling::Reason::Forgotten, true);
        }

        void afterEvents() {
            auto& s = st();
            if (!s.ready)
                return;
            if (s.resizing.lock() && !hyprlandDragging())
                finishResize();
            if (std::exchange(s.relayoutPending, false))
                relayout(ERelayout::OutputGone);
            if (s.gatherPending && !gf::deferredFocus::sessionLocked()) { // behind the lock screen: at the unlock (D55, D67)
                s.gatherPending = false;
                gatherStrays();
            }
            for (const auto& resume : std::exchange(s.resuming, {}))
                resumeNow(resume);
            for (const auto& moved : std::exchange(s.fitting, {})) {
                if (const auto w = moved.lock())
                    fitToOutput(w, "moved to a Desktop");
            }
            if (std::exchange(s.holdPending, false))
                holdUnderMenuBars();
            if (const auto rel = std::exchange(s.moveRelease, std::nullopt))
                finishMove(*rel);
            if (const auto e = std::exchange(s.extend, std::nullopt))
                extendSides(*e);
            if (std::exchange(s.recheck, false)) {
                const auto w = s.drag.window.lock();
                if (w && g_pInputManager && g_pInputManager->hasHeldButtons())
                    dragMotion(w, g_pInputManager->getMouseCoordsInternal());
            }
            splitCheck();
        }

        void scheduleAfter() {
            st().later.schedule([] { gf::guarded("tiling after events", [] { afterEvents(); }); });
        }

        // The shell's menu bar layer, whose exclusive zone is the top reserved area the clamp and the work area read.
        constexpr std::string_view kMenuBarNamespace = "grassfield-menubar";

        // The shell's menu bar mapped on an output (the session's start, the shell back after a restart; the bar also maps again
        // when it changes layer around a full-screen window): a window placed while it was away (at map, by an app, by a move
        // meanwhile) and now under it goes below it, as macOS never leaves a title bar under the menu bar (FR56). Its size is
        // left alone. Never a window one of the drags holds.
        void holdUnderMenuBars() {
            if (!Desktop::windowState())
                return;
            const auto dragged = st().drag.window.lock();
            const auto windows = Desktop::windowState()->windows(); // a copy: nothing here maps or closes one, but stay safe
            for (const auto& w : windows) {
                if (w && w != dragged && !heldByHyprlandDrag(w))
                    fitToOutput(w, "left under the menu bar that came", false);
            }
        }

        void onClose(const PHLWINDOW& w) {
            auto& s = st();
            if (!s.splits.empty())
                scheduleAfter(); // TL33: a Split View Desktop may have lost a window (splitCheck, once Hyprland removed it)
            if (!w || !s.book.find(idOf(w)))
                return;
            s.book.forget(idOf(w));
            notify(tiling::Reason::Forgotten);
        }

        // TL12: full screen and zoom suspend; leaving them puts the box back once Hyprland restored the window.
        void onFullscreen(const PHLWINDOW& w) {
            auto&      s = st();
            const auto r = w ? s.book.find(idOf(w)) : nullptr;
            if (!r)
                return;
            if (fullscreenNow(w)) {
                if (s.book.suspend(idOf(w)))
                    notify(tiling::Reason::Suspended);
                return;
            }
            if (r->state == tiling::TileState::Suspended && w->m_workspace && !w->m_workspace->m_isSpecialWorkspace) {
                s.resuming.push_back(SResume{.id = idOf(w), .checkFree = false});
                scheduleAfter();
            }
        }

        // TL14: minimize, hide and Show Desktop move a window to a special workspace (Suspended); back on a regular one it
        // returns to its zone if it is free. Move to Desktop between regular workspaces keeps the state.
        // Owner report on 1.0.0-rc6: a window moved to a Desktop of another output (the Overview, Move to Desktop) kept its size
        // there, overflowing a smaller display with its titlebar under the menu bar (Hyprland keeps it inside the output,
        // bottom-aligned). A tiled window takes the same tile on that output (as move_to: relayout once Hyprland moved it); a
        // Free one is fitted to that output's work area (fitToOutput, after events).
        void onMoveToWorkspace(const PHLWINDOW& w, const PHLWORKSPACE& ws) {
            auto& s = st();
            if (!s.splits.empty())
                scheduleAfter(); // TL33: minimized, hidden or moved off a Split View Desktop (splitCheck)
            if (!w || !ws)
                return;
            const auto r = s.book.find(idOf(w));
            if (!r) {
                if (!ws->m_isSpecialWorkspace) {
                    s.fitting.emplace_back(w);
                    scheduleAfter();
                }
                return;
            }
            if (ws->m_isSpecialWorkspace) {
                if (s.book.suspend(idOf(w)))
                    notify(tiling::Reason::Suspended);
                return;
            }
            if (r->state == tiling::TileState::Suspended) {
                s.resuming.push_back(SResume{.id = idOf(w), .checkFree = true});
                scheduleAfter();
                return;
            }
            s.book.setWorkspace(idOf(w), ws->m_id); // the state reply carries no Desktop: no notice
            const auto to = ws->m_monitor.lock();
            if (r->state == tiling::TileState::Tiled && to && to->m_name != r->output) {
                s.book.markRelayout(idOf(w), true); // checked again only once placed there (TL11's machinery)
                s.relayoutPending = true;
                scheduleAfter();
            } else if (r->state != tiling::TileState::Tiled && r->state != tiling::TileState::Resizing) {
                s.fitting.emplace_back(w);
                scheduleAfter();
            }
        }

        // ADR-0036 D67: after an output went away (the tiled windows placed again first, TL11), a floating window Hyprland
        // left off every output (it moves them by the offset between the outputs, WorkspacePlacementController.cpp:311)
        // comes back centred on the work area of its Desktop's output, at its size (core strayFrame, gatheredFrame). Not
        // a full-screen window (Hyprland gives it its new output), one in a Stages strip (its place is the strip's) or one
        // on a special workspace (a minimized window: restore() plans its own display, Minimize.cpp D-1). Never behind the
        // lock screen: afterEvents keeps it pending until the unlock (D55).
        void gatherStrays() {
            if (!g_layoutManager || !Desktop::windowState())
                return;
            const auto                all = monitors();
            std::vector<tiling::Rect> outputs;
            outputs.reserve(all.size());
            for (const auto& m : all)
                outputs.push_back(toRect(m->logicalBox()));
            if (outputs.empty())
                return; // no output enabled: every window would count as stray, and there is nowhere to gather them (review of 7096305)
            for (const auto& w : Desktop::windowState()->windows()) {
                if (!w || !w->m_isMapped || !w->m_isFloating || w->isHidden() || fullscreenNow(w) || gf::stager::inStripStage(w))
                    continue;
                const auto ws     = w->m_workspace;
                const auto target = w->layoutTarget();
                if (!ws || ws->m_isSpecialWorkspace || !target || !target->space())
                    continue;
                const double band  = gf::chrome::bandOf(w);
                const auto   frame = tiling::frameOf(toRect(target->position()), band);
                if (!tiling::strayFrame(frame, outputs))
                    continue;
                auto m = ws->m_monitor.lock();
                if ((!m || !m->m_enabled) && Desktop::focusState())
                    m = Desktop::focusState()->monitor();
                if (!m || !m->m_enabled)
                    continue;
                const auto surface = toCBox(tiling::surfaceOf(tiling::gatheredFrame(frame, toRect(m->logicalBoxMinusReserved())), band));
                g_layoutManager->setTargetGeom(surface, target);
                logRequest(Log::INFO, "window {:x} was off every output after an output went away: gathered on {} at {:.0f},{:.0f}", idOf(w), m->m_name, surface.x,
                           surface.y);
            }
        }

        // TL11: Hyprland moves the windows of a removed output to another one (its workspaces); the tiled ones are placed
        // into the same zone there once it did. Not checked meanwhile (markRelayout). D67: then the floating windows left
        // off every output are gathered (gatherStrays).
        void onMonitorRemoved(const PHLMONITOR& m) {
            auto& s = st();
            if (!m)
                return;
            s.gatherPending = true;
            scheduleAfter();
            bool any = false;
            for (const auto& r : s.book.records()) {
                if (r.output == m->m_name) {
                    s.book.markRelayout(r.id, true);
                    any = true;
                }
            }
            if (any)
                s.relayoutPending = true;
        }
        // ---- shared edge (TL30) ----

        // A record the shared edge looks at on `m` (a Tiled group member on the Desktop `m` shows), with what it reads of
        // its window `w` now.
        bool edgeCandidate(const tiling::TileRecord& r, const PHLMONITOR& m) {
            return r.state == tiling::TileState::Tiled && r.group != 0 && r.output == m->m_name && r.workspace == m->m_activeWorkspace->m_id;
        }
        SEdgeMember edgeMember(const tiling::TileRecord& r, const PHLWINDOW& w) {
            SEdgeMember member{.id = r.id, .group = r.group, .window = w, .counts = false, .box = {}, .band = 0};
            const auto  t = w && w->m_isMapped && !w->isHidden() && !fullscreenNow(w) && !gf::stager::inStripStage(w) ? w->layoutTarget() : nullptr;
            if (t) {
                member.counts = true;
                member.box    = t->position();
                member.band   = gf::chrome::bandOf(w);
            }
            return member;
        }

        // The shared edges of the Desktop `m` shows (core sharedEdges over its Tiled group members): none over an open
        // special workspace; a window in full screen or zoom, hidden, unmapped or in an inactive stage is not Tiled or left out.
        SEdgeScene edgeScene(const PHLMONITOR& m) {
            SEdgeScene scene;
            if (!m || showsSpecial(m) || !m->m_activeWorkspace)
                return scene;
            const auto area = areaFor(m);
            scene.monitor   = m;
            scene.workspace = m->m_activeWorkspace->m_id;
            scene.margin    = area.margin;
            scene.grid      = area.grid;
            for (const auto& r : st().book.records()) {
                if (!edgeCandidate(r, m))
                    continue;
                const auto w      = windowById(r.id);
                const auto member = edgeMember(r, w);
                scene.members.push_back(member);
                if (!member.counts)
                    continue;
                const auto limits = constraintsOf(w);
                scene.windows.push_back(tiling::EdgeWindow{.id = r.id, .group = r.group, .frame = tiling::frameOf(toRect(member.box), limits.band), .limits = limits});
            }
            scene.edges = tiling::sharedEdges(scene.windows, area.margin, tiling::kHandleLength, tiling::kHandleBand);
            return scene;
        }

        // Whether `scene` still holds for `m`: the same output, Desktop and margin, no special workspace over it, and the same
        // records looked at (the book's records alone: no window lookup), each window counting, placed and banded as then.
        bool edgeSceneHolds(const SEdgeScene& scene, const PHLMONITOR& m) {
            if (!m || scene.monitor.lock() != m || showsSpecial(m) || !m->m_activeWorkspace || scene.workspace != m->m_activeWorkspace->m_id ||
                scene.margin != areaFor(m).margin)
                return false;
            size_t i = 0;
            for (const auto& r : st().book.records()) {
                if (!edgeCandidate(r, m))
                    continue;
                if (i == scene.members.size())
                    return false;
                const auto& was = scene.members[i++];
                if (was.id != r.id || was.group != r.group)
                    return false;
                const auto now = edgeMember(r, was.window.lock());
                if (now.counts != was.counts || now.box != was.box || now.band != was.band)
                    return false;
            }
            return i == scene.members.size();
        }

        // The edges hover looks up (review of a6d04df, MINOR 5: hover ran the whole scene, a window lookup per record and the
        // quadratic sharedEdges, on every motion): built again only when what they derive from changed.
        const std::vector<tiling::SharedEdge>& hoverEdges(const PHLMONITOR& m) {
            auto& cached = st().edgeHoverScene;
            if (!edgeSceneHolds(cached, m))
                cached = edgeScene(m);
            return cached.edges;
        }

        bool modifierHeld() {
            constexpr uint32_t kMods = HL_MODIFIER_SHIFT | HL_MODIFIER_CTRL | HL_MODIFIER_ALT | HL_MODIFIER_META; // not Caps or Num Lock
            return g_pInputManager && (g_pInputManager->getModsFromAllKBs() & kMods) != 0;
        }

        // A popup holds the point: an xdg popup of any window shown on a visible Desktop, or an X11 override-redirect window
        // (an XWayland app's menu, a tooltip) whose box holds it. Hyprland's windowAt returns the topmost window whose box
        // (border grab area included) holds the point before it looks at the popups of the windows below (integrator nested
        // pass of 3d56d60), and for an override-redirect window that wants no focus it returns the focused window: an edge
        // window when the menu is that window's (integrator review of 0c4c8f2).
        bool popupAt(const Vector2D& p) {
            if (!Desktop::windowState())
                return false;
            for (const auto& w : Desktop::windowState()->windows()) {
                if (!w || !w->m_isMapped || w->isHidden() || (w->m_workspace && !w->m_workspace->isVisible()))
                    continue;
                if (w->m_isX11 ? w->isX11OverrideRedirect() && w->getWindowMainSurfaceBox().containsPoint(p) : w->m_workspace && w->hasPopupAt(p))
                    return true;
            }
            return false;
        }

        // TL30, TL34: the frontmost window under the point gets the click (core handleClear). Hyprland's own hit test of its
        // pointer focus: a window's titlebar (its reserved extents) or border grab area, a full-screen or zoomed window, from
        // the top of the stack; and any popup there, a popup of the edge's own windows included.
        bool handleClearAt(const tiling::SharedEdge& edge, const Vector2D& p) {
            if (!Desktop::viewState())
                return false;
            constexpr auto props = static_cast<uint16_t>(Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS | Desktop::View::ALLOW_FLOATING);
            const auto     w     = Desktop::viewState()->hitTest().windowAt(p, props);
            return tiling::handleClear(edge, w ? idOf(w) : 0, popupAt(p));
        }

        // The handle under the pointer, for a plain pointer (no button held, no modifier: Super+drag stays Hyprland's move),
        // with nothing in front of it (the lock, a foreign Exclusive layer, a layer under the point, a window, titlebar or
        // popup other than the edge's own: TL34). `windows` and `grid` (a press): the scene as it is now; hover reads the kept
        // edges.
        std::optional<tiling::SharedEdge> handleAt(const Vector2D& p, std::vector<tiling::EdgeWindow>* windows, tiling::Grid* grid) {
            if (gf::deferredFocus::sessionLocked() || modifierHeld())
                return std::nullopt;
            const auto m     = monitorAt(p);
            const bool press = windows || grid;
            SEdgeScene scene;
            if (press)
                scene = edgeScene(m);
            auto edge = tiling::edgeAt(press ? scene.edges : hoverEdges(m), p.x, p.y); // not const: returned by move
            if (!edge || CGrassfieldTitlebar::pointerCovered(p) || !handleClearAt(*edge, p)) // the hit tests only over a handle
                return std::nullopt;
            if (windows)
                *windows = std::move(scene.windows);
            if (grid)
                *grid = scene.grid;
            return edge;
        }

        // The handle's cursor: a left-right or up-down double arrow (Hyprland's special-action override, which outranks the
        // border icon of resize_on_border), set while the pointer rests on a handle and during its drag.
        void edgeCursor(std::optional<bool> vertical) {
            auto& s = st();
            if (!Pointer::Cursor::overrideController)
                return;
            if (vertical) {
                Pointer::Cursor::overrideController->setOverride(*vertical ? "ew-resize" : "ns-resize", Pointer::Cursor::CURSOR_OVERRIDE_SPECIAL_ACTION);
                s.edgeCursor = true;
            } else if (std::exchange(s.edgeCursor, false)) {
                Pointer::Cursor::overrideController->unsetOverride(Pointer::Cursor::CURSOR_OVERRIDE_SPECIAL_ACTION);
            }
        }

        void edgeHover() {
            const auto& s = st();
            if (!g_pInputManager || s.edge)
                return;
            const auto edge = g_pInputManager->hasHeldButtons() ? std::nullopt : handleAt(g_pInputManager->getMouseCoordsInternal(), nullptr, nullptr);
            edgeCursor(edge ? std::optional<bool>{edge->vertical} : std::nullopt);
        }

        // The frames of the drag's delta (core dragEdge) on the windows still there: each surface box set and its animation
        // ended at once (as a step of Hyprland's own resize: setTargetGeom, warpPositionSize). A window closed, unmapped (its
        // Desktop and layout space gone while the object lives: gate C1, setTargetGeom would reach the missing space) or no
        // longer Resizing meanwhile (full screen, zoom, minimized: Suspended; forgotten) leaves the drag (once, logged): it is
        // no longer set, but its frame from the press and its limits still bound the edge (integrator re-review of ce82fd3:
        // without them, the other side's windows would follow the pointer off the work area); the others go on.
        void edgeApply() {
            auto& s = st();
            if (!s.edge || !g_layoutManager)
                return;
            auto&      d      = *s.edge;
            const auto frames = tiling::dragEdge(d.edge, d.windows, d.delta, d.grid);
            d.appliedMs       = nowMs();
            if (frames == d.applied)
                return;
            std::vector<uint64_t> gone;
            for (const auto& f : frames) {
                const uint64_t id = f.first;
                if (std::ranges::find(d.left, id) != d.left.end())
                    continue;
                const auto w = windowById(id);
                const auto t = tiling::movable(factsOf(w)) ? w->layoutTarget() : nullptr; // C1: mapped, on a Desktop, in a layout space
                const auto e = std::ranges::find_if(d.windows, [id](const tiling::EdgeWindow& x) { return x.id == id; });
                const auto r = s.book.find(id);
                if (!t || e == d.windows.end() || !r || r->state != tiling::TileState::Resizing) {
                    gone.push_back(id);
                    continue;
                }
                g_layoutManager->setTargetGeom(toCBox(tiling::surfaceOf(f.second, e->limits.band)), t);
                t->warpPositionSize();
                // Followed: set at a size other than its size at the press (integrator follow-up of PR #42: a frame set at the
                // same size resized nothing).
                if ((f.second.w != e->frame.w || f.second.h != e->frame.h) && std::ranges::find(d.moved, id) == d.moved.end())
                    d.moved.push_back(id);
            }
            for (const uint64_t id : gone) {
                d.left.push_back(id);
                logRequest(Log::INFO, "window {:x} closed, unmapped or no longer resizing: it leaves the shared edge's drag (gate C1)", id);
            }
            d.applied = frames;
            ++d.steps;
        }

        // The plugin's own time in a step of the drag (a motion, the frames of a refresh): recorded for the frame probe's
        // attribution (integrator review of a6d04df, MAJOR 2: the drag runs before the render, where a stall reads as a late
        // client) and summed for the drag's DEBUG line.
        template <typename F>
        void edgeTimed(F&& step) {
            const uint64_t began = gf::frameProbe::nowUs();
            std::forward<F>(step)();
            gf::frameProbe::work(began);
            if (auto& d = st().edge) {
                const uint64_t spent = gf::frameProbe::nowUs() - began;
                d->workUs += spent;
                d->maxWorkUs = std::max(d->maxWorkUs, spent);
            }
        }

        void armEdgeTimer(uint64_t ms) {
            auto& s = st();
            if (!g_pEventLoopManager)
                return;
            if (!s.edgeTimer) {
                s.edgeTimer = makeShared<CEventLoopTimer>(
                    std::nullopt, [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) { gf::guarded("tiling shared edge frame", [] { edgeTimed(edgeApply); }); },
                    nullptr);
                g_pEventLoopManager->addTimer(s.edgeTimer);
            }
            s.edgeTimer->updateTimeout(std::chrono::milliseconds(ms));
        }

        // The end of a drag (its release; the lock; another press): the last frames, then Resizing -> Tiled with the boxes
        // the windows have, one `resized` notice; the cursor goes back.
        void edgeEnd(std::string_view why) {
            auto& s = st();
            if (!s.edge)
                return;
            if (s.edgeTimer)
                s.edgeTimer->updateTimeout(std::nullopt);
            edgeApply();
            const auto d = std::move(*s.edge);
            s.edge.reset();
            for (const auto& e : d.windows) {
                const auto w = windowById(e.id);
                const auto t = w ? w->layoutTarget() : nullptr;
                const auto r = s.book.find(e.id);
                if (t && r && r->state == tiling::TileState::Resizing)
                    s.book.endResize(e.id, toRect(t->position()));
            }
            notify(tiling::Reason::Resized);
            edgeCursor(std::nullopt);
            // The drag's own count for P3 (integrator review of 0c4c8f2: the windows it resized, not a number the harness
            // assumes): "edge-drag:F/E", F of the edge's E windows followed it (set at another size than at the press, and never
            // left it).
            const auto followed = std::ranges::count_if(d.windows, [&d](const tiling::EdgeWindow& e) {
                return std::ranges::find(d.moved, e.id) != d.moved.end() && std::ranges::find(d.left, e.id) == d.left.end();
            });
            gf::frameProbe::mark(std::format("edge-drag:{}/{}", followed, d.windows.size()));
            logRequest(Log::DEBUG, "shared edge: {} window(s), {:+.0f} px, {} step(s) and {} held motion(s) in {} ms, the plugin's work {} us (longest step {} us) ({})",
                       d.windows.size(), d.delta, d.steps, d.held, nowMs() - d.beganMs, d.workUs, d.maxWorkUs, why);
        }

        // A plain left press on a handle: the drag begins (every window of the edge Resizing), the press is the plugin's. The
        // second press of a double-click on a Split View Desktop's separator puts its two members back to equal halves instead
        // (TL33, step 6b; the press and its release stay the plugin's, nothing is dragged).
        bool edgePress(const Vector2D& p, uint32_t timeMs) {
            auto& s = st();
            // Hyprland's held buttons before this press is recorded: another device holding one would make the release
            // this press owes ambiguous (the bus names no device; FR13, as P6).
            if (s.edge || !g_layoutManager || !g_pInputManager || g_pInputManager->hasHeldButtons())
                return false;
            if (const auto& drag = g_layoutManager->dragController(); drag && drag->mode() != MBIND_INVALID)
                return false;
            std::vector<tiling::EdgeWindow> windows;
            tiling::Grid                    grid;
            const auto                      edge = handleAt(p, &windows, &grid);
            if (!edge)
                return false;
            if (const auto* d = tiling::splitOfEdge(s.splits, *edge)) {
                if (s.separator.workspace != d->workspace) {
                    s.separator.workspace = d->workspace;
                    s.separator.clicks.reset();
                }
                if (s.separator.clicks.press(timeMs, p.x, p.y)) {
                    splitHalvesAgain(*d);
                    s.edgeReleaseOwed = true;
                    return true;
                }
            } else {
                s.separator.workspace = 0;
            }
            std::erase_if(windows, [&](const tiling::EdgeWindow& w) {
                return std::ranges::find(edge->before, w.id) == edge->before.end() && std::ranges::find(edge->after, w.id) == edge->after.end();
            });
            for (const auto& w : windows)
                s.book.beginResize(w.id); // Tiled by edgeScene
            const auto now = nowMs();
            s.edge         = SEdgeDrag{.edge = *edge, .windows = std::move(windows), .grid = grid, .press = p, .monitor = monitorAt(p), .delta = 0, .applied = {},
                                       .beganMs = now, .appliedMs = now, .steps = 0, .held = 0, .left = {}, .moved = {}, .workUs = 0, .maxWorkUs = 0};
            s.edgeReleaseOwed = true;
            edgeCursor(edge->vertical);
            return true;
        }

        // A motion during the drag: the edge follows the pointer along its axis, applied at most once per refresh of the
        // output (TL30, P3: the neighbours are configured at most once per refresh), the rest when the frame is due.
        void edgeMotion() {
            auto& s = st();
            if (!s.edge)
                return; // beforePointerMotion calls it during a drag only
            auto& d = *s.edge;
            if (gf::deferredFocus::sessionLocked()) {
                edgeEnd("the session locked");
                return;
            }
            const Vector2D p = g_pInputManager ? g_pInputManager->getMouseCoordsInternal() : d.press;
            d.delta          = d.edge.vertical ? p.x - d.press.x : p.y - d.press.y;
            const auto   m       = d.monitor.lock();
            const double hz      = m && m->m_refreshRate > 1 ? m->m_refreshRate : 60.0;
            const auto   frameMs = static_cast<uint64_t>(std::ceil(1000.0 / hz));
            const auto   since   = nowMs() - d.appliedMs;
            if (since < frameMs) {
                ++d.held;
                armEdgeTimer(frameMs - since);
                return;
            }
            edgeApply();
        }

        // TL34: the lock ends a drag at once (the frames its motions before the lock asked for, then Tiled, one `resized`),
        // and the handle's cursor goes, also a hover's (the lock surface shows its own). Its release stays cancelled.
        void edgeLocked() {
            edgeEnd("the session locked");
            edgeCursor(std::nullopt);
        }

        // TL33, D51 (re-review of e5bd9d2, MAJOR A): the lock closes the shell's popups, a Split View's picker with them: a
        // Split View waiting for its second window waits no more, and its one member fills at the unlock (splitCheck acts on
        // nothing while locked). The plugin does it itself: a fill the shell sends while Hyprland still reports the lock would
        // be refused.
        void splitsLocked() {
            bool changed = false;
            for (auto& d : st().splits)
                changed |= std::exchange(d.waiting, false);
            if (changed)
                notify(tiling::Reason::Forgotten, true);
        }

    } // namespace

    bool start() {
        auto& bus = Event::bus();
        auto& s   = st();
        // A load starts with no record, also when the library stayed mapped since a previous load (FR23).
        s.book.clear();
        s.suggestion.reset();
        s.posted = s.book.generation();
        s.resizing.reset();
        s.relayoutPending = false;
        s.gatherPending   = false;
        s.resuming.clear();
        s.later.clear(); // a previous stop() cancelled it
        s.drag = {};
        s.recheck = false;
        s.press.reset();
        s.moveRelease.reset();
        s.border = {};
        s.extend.reset();
        s.edge.reset();
        s.edgeReleaseOwed = false;
        s.edgeCursor      = false;
        s.edgeHoverScene  = {};
        s.separator       = {};
        s.memberDrag.reset();
        s.splits.clear(); // TL33: a Split View Desktop of a previous load is an ordinary Desktop now
        s.splitHomes.clear();
        s.chromeMembers.clear();
        s.backInReach.clear();
        s.fitting.clear();
        s.moveFrom = {};
        if (!bus || !Desktop::windowState() || !State::monitorState() || !Fullscreen::controller())
            return false;
        auto& ev = bus->m_events;
        auto& l  = s.listeners;
        l.push_back(ev.window.close.listen([](const PHLWINDOW& w) { gf::guarded("tiling window.close", [&] { onClose(w); }); }));
        l.push_back(ev.window.fullscreen.listen([](const PHLWINDOW& w) { gf::guarded("tiling window.fullscreen", [&] { onFullscreen(w); }); }));
        l.push_back(ev.window.moveToWorkspace.listen(
            [](const PHLWINDOW& w, const PHLWORKSPACE& ws) { gf::guarded("tiling window.moveToWorkspace", [&] { onMoveToWorkspace(w, ws); }); }));
        l.push_back(ev.monitor.removed.listen([](const PHLMONITOR& m) { gf::guarded("tiling monitor.removed", [&] { onMonitorRemoved(m); }); }));
        l.push_back(ev.layer.opened.listen([](const PHLLS& ls) {
            gf::guarded("tiling layer.opened", [&] {
                if (ls && ls->m_namespace == kMenuBarNamespace) {
                    st().holdPending = true; // read once Hyprland gave the output its reserved area (after events)
                    scheduleAfter();
                }
            });
        }));
        if (g_pSessionLockManager) {
            l.push_back(g_pSessionLockManager->m_events.lock.listen([] {
                gf::guarded("tiling session lock", [] {
                    edgeLocked();
                    splitsLocked();
                });
            }));
            // TL33: a Split View settles at the unlock: its one member fills, one emptied ends (nothing behind the lock screen).
            // D67: the windows an unplug left off every output while locked are gathered then too.
            l.push_back(g_pSessionLockManager->m_events.unlock.listen([] {
                gf::guarded("tiling session unlock", [] {
                    if (!st().splits.empty() || st().gatherPending || !st().backInReach.empty())
                        scheduleAfter();
                });
            }));
        }
        s.ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.listeners.clear();
        s.later.cancel();
        dragDone(); // the preview goes; a drag of Hyprland's goes on as Hyprland's own
        if (s.previewTimer) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.previewTimer);
            s.previewTimer.reset();
        }
        s.recheck = false;
        s.press.reset();
        s.moveRelease.reset();
        s.moveFrom = {};
        s.fitting.clear();
        s.border = {};
        s.extend.reset();
        s.resizing.reset();
        s.relayoutPending = false;
        s.gatherPending   = false;
        s.resuming.clear();
        // Step 6e (D73, D75; the review of #99): the unload ends every Split View. A member dragged by its revealed bar goes back
        // in its half first (the titlebars drop their gesture after this stop, when the tiler places nothing any more); then
        // each member gets its titlebar band back below the menu bar (the unload drops the titlebars; a later load draws them
        // again above the surface). Not while locked (D55).
        if (const auto dragged = s.memberDrag.lock()) {
            if (const auto* r = s.book.find(idOf(dragged)); r && tiling::splitOfWindow(s.splits, idOf(dragged)) && !gf::deferredFocus::sessionLocked())
                applySurface(dragged, toCBox(r->box));
        }
        s.memberDrag.reset();
        const auto members = tiling::splitMembers(s.splits);
        s.splits.clear();
        s.splitHomes.clear();
        s.chromeMembers.clear();
        s.backInReach.clear();
        if (!gf::deferredFocus::sessionLocked()) {
            for (const auto id : members)
                titlebarBackInReach(windowById(id));
        }
        s.book.clear(); // windows keep their boxes; groups are forgotten
        s.suggestion.reset();
        // TL30: a drag of a shared edge ends with the boxes the windows have (the book is cleared just above: no notice for
        // it); the release it owes is still cancelled by nobody once the listener is gone, and Hyprland never saw its press.
        if (s.edgeTimer) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.edgeTimer);
            s.edgeTimer.reset();
        }
        s.edge.reset();
        s.edgeReleaseOwed = false;
        s.edgeHoverScene  = {};
        edgeCursor(std::nullopt);
        if (std::exchange(s.ready, false))
            notify(tiling::Reason::Unavailable);
    }

    bool edgeOwnsPointer() {
        return st().edge.has_value();
    }

    bool ready() {
        return st().ready;
    }

    std::optional<Snap> snapFor(const PHLWINDOW& w, const Vector2D& pointer) {
        const auto& options = state().tilingDrag;
        const bool  alt     = options.altDrag && altHeld();
        if (!placeable(w) || (!options.edges && !options.menuBar && !alt))
            return std::nullopt;
        const auto m = monitorAt(pointer);
        if (!m || showsSpecial(m))
            return std::nullopt;
        const CBox box = m->logicalBox();
        const tiling::Output output{toRect(box), box.y + m->m_reservedArea.top(), edgeFree(m, true), edgeFree(m, false)};
        const auto           area  = areaFor(m);
        const auto           place = tiling::dragPlace(pointer.x, pointer.y, output, area.box, options, alt);
        if (!place || !fitsPlace(w, *place, area, m->m_name, w->m_workspace->m_id))
            return std::nullopt; // D69: no preview of a place the window does not fit (the release only moves it)
        return Snap{*place, toCBox(placeFrame(w, *place, area, m->m_name, w->m_workspace->m_id)), m};
    }

    std::optional<Snap> dragMotion(const PHLWINDOW& w, const Vector2D& pointer) {
        auto& s = st();
        if (!w)
            return std::nullopt;
        auto& d = s.drag;
        if (d.window.lock() != w) {
            dragDone(); // another window's drag: its preview goes
            d.window = w;
        }
        const auto before = shownOf(d);
        auto       next   = snapFor(w, pointer);
        const auto m      = next ? next->monitor.lock() : nullptr;
        const auto now    = nowMs();
        const auto place  = next ? std::optional{next->place} : std::nullopt;
        d.dwell.update(place, m ? std::string_view{m->m_name} : std::string_view{}, now, tiling::showsAtOnce(place, m && topFree(m), altHeld()));
        d.candidate      = std::move(next);
        const auto after = shownOf(d);
        const bool same  = before && after ? before->place == after->place && before->frame == after->frame : before.has_value() == after.has_value();
        if (!same) {
            damage(before);
            damage(after);
        }
        // The line tests wait for before they capture the preview (tests/compositor/tiling.sh): it shows now.
        if (after && (!before || before->place != after->place))
            logRequest(Log::DEBUG, "tiling preview {:x}: {} on {}", idOf(w), tiling::nameOf(after->place), m ? m->m_name : std::string{});
        if (const auto wait = d.dwell.remaining(now))
            armPreviewTimer(*wait);
        return after;
    }

    void dragDone() {
        auto& s = st();
        damage(shownOf(s.drag));
        s.drag = {};
        if (s.previewTimer)
            s.previewTimer->updateTimeout(std::nullopt);
    }

    std::optional<Snap> previewOf(const PHLWINDOW& w) {
        const auto& s = st();
        if (!w || s.drag.window.lock() != w)
            return std::nullopt;
        return shownOf(s.drag);
    }

    void onKey() {
        auto& s = st();
        if (!s.ready || !s.drag.window.lock())
            return;
        s.recheck = true; // Hyprland applies the key after this listener: Alt is read once it did
        scheduleAfter();
    }

    bool tile(const PHLWINDOW& w, tiling::Place place, const PHLMONITOR& monitor) {
        if (!placeable(w) || !g_layoutManager)
            return false;
        auto& s = st();
        catchUp();
        const auto m = monitor && monitor->m_enabled ? monitor : monitorOf(w);
        if (!m || showsSpecial(m))
            return false; // over an open special workspace the drop only moves the window (followOutput)
        const auto target  = w->layoutTarget();
        const CBox current = target->position();
        const auto band    = gf::chrome::bandOf(w);
        const auto onDesktop = monitorOf(w) == m ? std::optional<int64_t>{w->m_workspace->m_id} : std::nullopt; // its own Desktop's area, shown or not
        const auto area      = areaFor(m, onDesktop);
        if (!fitsPlace(w, place, area, m->m_name, w->m_workspace->m_id)) {
            // D69: never a tile larger than its place (it would overlap its neighbours and shift their rows or columns); the
            // shell greys that place (unfitZones), so this is a key, a stale menu or a request of another client.
            logRequest(Log::INFO, "tile {:x}: refused: its minimum does not fit {} on {} (TL8, D69)", idOf(w), tiling::nameOf(place), m->m_name);
            notify(tiling::Reason::Invalid);
            return false;
        }
        const CBox surface = toCBox(tiling::surfaceOf(placeFrame(w, place, area, m->m_name, w->m_workspace->m_id), band));
        g_layoutManager->setTargetGeom(surface, target);
        followOutput(w); // tiled on another output (a drag's release there, tile() after a drag over): that output's Desktop
        const int64_t workspace = w->m_workspace ? w->m_workspace->m_id : 0;
        s.book.placed(idOf(w), toRect(current), toRect(surface), band, tiling::Placement{.place = place, .layout = {}, .zone = -1}, m->m_name, workspace, 0);
        settleSplit(workspace); // TL33: Fill after the suggestion was dismissed (D43)
        logRequest(Log::DEBUG, "tile {:x}: {} on {}", idOf(w), tiling::nameOf(place), m->m_name);
        notify(tiling::Reason::Placed);
        return true;
    }

    tiling::ZoomStep zoom(const PHLWINDOW& w, bool toggleHyprland) {
        const auto& fs = Fullscreen::controller();
        if (!w || !fs)
            return tiling::ZoomStep::Refused;
        const auto mode = fs->getFullscreenModes(w).internal;
        reconcile(); // a record whose window something else moved is Free (TL10): such a window fills again
        const auto*             r = st().book.find(idOf(w));
        const tiling::ZoomFacts facts{
            .tiling       = gf::ipc::tilingAvailable() && !gf::deferredFocus::sessionLocked(),
            .maximized    = mode == Fullscreen::FSMODE_MAXIMIZED,
            .fullscreen   = mode == Fullscreen::FSMODE_FULLSCREEN,
            .splitMember  = inSplit(w),
            .fixedSize    = fixedSize(w),
            .filled       = r && r->state == tiling::TileState::Tiled && r->where.place == tiling::Place::Fill && r->where.layout.empty() && r->where.sides == 0,
            .atFill       = !r && mode == Fullscreen::FSMODE_NONE && atFillFrame(w),
        };
        auto step = tiling::zoomStep(facts);
        switch (step) {
            case tiling::ZoomStep::Fill:
                if (!tile(w, tiling::Place::Fill)) {
                    logRequest(Log::DEBUG, "zoom {:x}: Fill refused (TL9), Hyprland's maximized mode instead", idOf(w));
                    step = tiling::ZoomStep::Hyprland;
                }
                break;
            case tiling::ZoomStep::Previous:
                if (!returnToPrevious(w)) {
                    logRequest(Log::INFO, "zoom {:x}: its box from before cannot be put back now", idOf(w));
                    step = tiling::ZoomStep::Refused;
                }
                break;
            case tiling::ZoomStep::UnzoomToFill:
                fs->setFullscreenMode(w, Fullscreen::FSMODE_NONE, Fullscreen::FSMODE_NONE, false); // Hyprland restores its box at once
                if (!tile(w, tiling::Place::Fill))
                    logRequest(Log::DEBUG, "zoom {:x}: out of the maximized mode; Fill refused (TL9), its box kept", idOf(w));
                break;
            case tiling::ZoomStep::Unfill:
                if (!unfill(w))
                    step = tiling::ZoomStep::Refused;
                break;
            case tiling::ZoomStep::Hyprland:
            case tiling::ZoomStep::Refused: break;
        }
        logRequest(Log::DEBUG, "zoom {:x}: {}", idOf(w), tiling::nameOf(step));
        if (step == tiling::ZoomStep::Hyprland && toggleHyprland)
            toggleMaximized(w);
        return step;
    }

    tiling::ZoomStep zoomFocused() {
        const auto focus = Desktop::focusState();
        const auto w     = focus ? focus->window() : nullptr;
        return w ? zoom(w, false) : tiling::ZoomStep::Hyprland; // no window: Hyprland's dispatcher does nothing itself
    }

    bool movable(const PHLWINDOW& w) {
        return tiling::movable(factsOf(w));
    }

    bool tileable(const PHLWINDOW& w) {
        return placeable(w);
    }

    bool fixedSize(const PHLWINDOW& w) {
        return w && tiling::fixedSize(constraintsOf(w));
    }

    bool sizeKeyActs(tiling::SizeMode mode) {
        const auto  focus = Desktop::focusState();
        const auto  w     = focus ? focus->window() : nullptr;
        const auto& fs    = Fullscreen::controller();
        if (!w || !fs)
            return true;
        const auto in  = fs->getFullscreenModes(w).internal == (mode == tiling::SizeMode::Maximized ? Fullscreen::FSMODE_MAXIMIZED : Fullscreen::FSMODE_FULLSCREEN);
        const bool act = tiling::sizeKeyActs(fixedSize(w), in);
        if (!act)
            logRequest(Log::INFO, "window_size: {} refused: window {:x} is of fixed size", mode == tiling::SizeMode::Maximized ? "maximized" : "fullscreen", idOf(w));
        return act;
    }

    bool splittable(const PHLWINDOW& w) {
        const auto m = placeable(w) ? monitorOf(w) : nullptr;
        return m && tiling::fitsFrame(constraintsOf(w), splitHalf(m, 0)) && tiling::fitsFrame(constraintsOf(w), splitHalf(m, 1));
    }

    std::vector<std::string> unfitZones(const PHLWINDOW& w) {
        const auto m = w && w->m_workspace ? monitorOf(w) : nullptr;
        if (!m)
            return {};
        return tiling::unfitZones(constraintsOf(w), areaFor(m, w->m_workspace->m_id)); // the area tile() places it in
    }

    std::vector<std::string> unfitPlaces(const PHLWINDOW& w) {
        const auto m = w && w->m_workspace ? monitorOf(w) : nullptr;
        if (!m)
            return {};
        // tile() from a key or a menu: its own output's Desktop, the frame startFrame gives (TL7 neighbours included).
        const int64_t workspace = w->m_workspace->m_id;
        return tiling::unfitPlaces(constraintsOf(w), areaFor(m, workspace), neighbourFramesOf(w, m->m_name, workspace));
    }

    void moveToRequest(std::string_view addressText, std::string_view outputName) {
        if (gf::deferredFocus::sessionLocked()) {
            logRequest(Log::WARN, "move_to: refused: the session is locked");
            notify(tiling::Reason::Locked);
            return;
        }
        const auto refuse = [](std::string_view why) {
            logRequest(Log::WARN, "move_to: refused: {}", why);
            notify(tiling::Reason::Invalid);
        };
        const uint64_t address = minimize::parseAddress(addressText).value_or(0); // 0 is never a window
        const auto     w       = address != 0 ? windowById(address) : nullptr;
        if (!w || !g_layoutManager) {
            refuse("no such window");
            return;
        }
        if (!tiling::outputNameOk(outputName)) {
            refuse("not an output name");
            return;
        }
        const auto to   = monitorByName(outputName);
        const auto from = monitorOf(w);
        if (!to || !to->m_enabled || !from || to == from || showsSpecial(to) || !to->m_activeWorkspace) {
            refuse("no other output of that name with a Desktop shown");
            return;
        }
        if (!movable(w) || !w->m_isFloating || w->m_pinned || fullscreenNow(w) || !w->m_workspace || w->m_workspace->m_isSpecialWorkspace) {
            refuse("the window cannot move to another output");
            return;
        }
        auto& s = st();
        catchUp();
        const CBox         current  = w->layoutTarget()->position();
        const auto         band     = gf::chrome::bandOf(w);
        const auto         toArea   = areaFor(to);
        const tiling::Rect frame    = tiling::frameOf(toRect(current), band);
        const tiling::Rect relative = tiling::moveToArea(frame, areaFor(from).box, toArea.box);
        const auto         r        = s.book.find(idOf(w));
        std::optional<tiling::Placement> where;
        std::optional<tiling::Rect>      tiled;
        if (r && r->state == tiling::TileState::Tiled && placeable(w)) {
            where = r->where; // a copy: the book changes below
            if (where->sides != 0)
                tiled = tiling::extendFrame(relative, where->sides, constraintsOf(w), toArea);
            else
                tiled = placementFrame(w, *where, toArea, to->m_name, to->m_activeWorkspace->m_id);
        }
        const CBox surface = toCBox(tiling::surfaceOf(tiled.value_or(relative), band));
        g_layoutManager->setTargetGeom(surface, w->layoutTarget());
        followOutput(w); // its middle is on `to` now: that output's Desktop, as after Hyprland's own move (TL21, D9)
        const int64_t workspace = w->m_workspace ? w->m_workspace->m_id : 0;
        if (tiled && where) {
            s.book.placed(idOf(w), toRect(current), toRect(surface), band, *where, to->m_name, workspace, 0); // a group stays on its output
            notify(tiling::Reason::Placed);
        } else if (r) {
            s.book.forget(idOf(w)); // not tiled (or not tileable any more): Free on the other output
            notify(tiling::Reason::Forgotten);
        }
        logRequest(Log::DEBUG, "move_to {:x}: {} -> {}{}", idOf(w), from->m_name, to->m_name, tiled ? " (in the same tile)" : "");
    }

    void followOutput(const PHLWINDOW& w) {
        const auto facts = factsOf(w);
        if (!g_layoutManager || !w)
            return;
        if (!tiling::movable(facts)) {
            // Closed or unmapped (during a drag): no Desktop, no space (gate C1); tiling.sh's C1 cases look for this line.
            logRequest(Log::INFO, "window {:x} closed or unmapped: its Desktop not changed (gate C1)", idOf(w));
            return;
        }
        const auto                target = w->layoutTarget();
        const CBox                box    = target->position();
        const auto                all = monitors();
        std::vector<tiling::Rect> boxes;
        boxes.reserve(all.size());
        for (const auto& m : all)
            boxes.push_back(toRect(m->logicalBox()));
        const auto i = tiling::outputUnder(toRect(box), boxes);
        if (!i)
            return; // off every output: it keeps its Desktop
        const auto& m  = all[*i];
        const auto  ws = m->m_activeSpecialWorkspace ? m->m_activeSpecialWorkspace : m->m_activeWorkspace;
        if (!ws || !ws->m_space || !tiling::shouldFollow(facts, i, ws->m_space == target->space()))
            return;
        target->assignToSpace(ws->m_space);
        g_layoutManager->setTargetGeom(box, target);
        logRequest(Log::DEBUG, "window {:x} moved by the plugin onto {}: now on its Desktop {}", idOf(w), m->m_name, ws->m_name);
    }

    void fitAfterDrop(const PHLWINDOW& w, const CBox& pressBox) {
        if (!w)
            return;
        const auto from = monitorAt(pressBox.middle());
        const auto now  = monitorOf(w);
        if (now && now != from)
            fitToOutput(w, "dropped on another output by its titlebar");
    }

    bool isTiled(const PHLWINDOW& w) {
        if (!w)
            return false;
        reconcile();
        const auto r = st().book.find(idOf(w));
        return r && r->state == tiling::TileState::Tiled;
    }

    std::optional<CBox> beginMove(const PHLWINDOW& w) {
        if (!w)
            return std::nullopt;
        const auto before = st().book.beginMove(idOf(w));
        if (!before)
            return std::nullopt;
        notify(tiling::Reason::Moved);
        return toCBox(*before);
    }

    void leave(const PHLWINDOW& w) {
        auto& s = st();
        if (!w || !s.book.find(idOf(w)))
            return;
        s.book.forget(idOf(w));
        notify(tiling::Reason::Moved);
    }

    void endMove(const PHLWINDOW& w) {
        auto&      s = st();
        const auto r = w ? s.book.find(idOf(w)) : nullptr;
        if (!r || r->state != tiling::TileState::Moving)
            return;
        s.book.endMove(idOf(w));
        notify(tiling::Reason::Forgotten);
    }

    void tileRequest(std::string_view addressText, std::string_view placeName) {
        if (gf::deferredFocus::sessionLocked()) {
            logRequest(Log::INFO, "tile: refused: the session is locked");
            notify(tiling::Reason::Locked);
            return;
        }
        const uint64_t address = minimize::parseAddress(addressText).value_or(0); // 0 is never a window
        const auto     window  = address != 0 ? windowById(address) : nullptr;
        if (!window) {
            logRequest(Log::WARN, "tile: rejected: no such window");
            return;
        }
        if (placeName == "previous") {
            if (!returnToPrevious(window))
                logRequest(Log::INFO, "tile {:x}: not tiled, nothing to return to", address);
            return;
        }
        if (placeName == "zoom") {
            // ADR-0036 D78 (feature zoom-fill): Window > Zoom and the zoom light clicked under its open popover (D64).
            if (zoom(window, true) == tiling::ZoomStep::Refused)
                logRequest(Log::INFO, "tile {:x}: zoom refused (fixed size, or its box from before cannot be put back)", address);
            return;
        }
        const auto place = tiling::parsePlace(placeName);
        if (!place) {
            logRequest(Log::WARN, "tile: rejected: unknown place");
            return;
        }
        // TL33: a Split View window is placed by its Desktop (a tiling key would take it out of its half); only the Fill of
        // the one left alone, which the shell sends when its picker ended without a second window (D43).
        if (const auto* d = tiling::splitOfWindow(st().splits, address); d && !(*place == tiling::Place::Fill && d->members.size() == 1)) {
            logRequest(Log::WARN, "tile {:x}: rejected: a window of a Split View Desktop", address);
            notify(tiling::Reason::Invalid);
            return;
        }
        if (!tile(window, *place))
            logRequest(Log::INFO, "tile {:x}: not tileable (tiling.md TL9)", address);
    }

    void groupFrontRequest(std::string_view addressText) {
        auto& s = st();
        if (gf::deferredFocus::sessionLocked()) {
            logRequest(Log::INFO, "group_front: refused: the session is locked");
            notify(tiling::Reason::Locked);
            return;
        }
        const uint64_t address = minimize::parseAddress(addressText).value_or(0); // 0 is never a window
        const auto     w       = address != 0 ? windowById(address) : nullptr;
        if (!w) {
            logRequest(Log::WARN, "group_front: rejected: not a live window");
            notify(tiling::Reason::Invalid);
            return;
        }
        if (!Desktop::windowState())
            return;
        std::vector<uint64_t> stack; // the windows on screen, bottom to top: a minimized or hidden one is on a special workspace
        for (const auto& o : Desktop::windowState()->windows()) {
            if (o && o->m_isMapped && !o->isHidden() && o->m_workspace && !o->m_workspace->m_isSpecialWorkspace)
                stack.push_back(idOf(o));
        }
        const auto order = tiling::groupRaiseOrder(s.book.records(), idOf(w), stack);
        for (const auto id : order) {
            const auto member = windowById(id);
            if (!member)
                continue;
            if (const auto result = Config::Actions::alterZOrder("top", member); !result)
                logRequest(Log::WARN, "group_front: raising {:x} failed: {}", id, result.error().message);
        }
        if (!order.empty())
            logRequest(Log::DEBUG, "group_front {:x}: {} member(s) brought forward", idOf(w), order.size());
    }

    void splitRequest(std::string_view addressText, std::string_view sideText) {
        auto& s = st();
        if (gf::deferredFocus::sessionLocked()) {
            logRequest(Log::INFO, "split: refused: the session is locked");
            notify(tiling::Reason::Locked);
            return;
        }
        const auto refuse = [](std::string_view why) {
            logRequest(Log::WARN, "split: rejected: {}", why);
            notify(tiling::Reason::Invalid);
        };
        const auto zone = tiling::splitZone(sideText);
        if (!zone) {
            refuse("the side is left or right");
            return;
        }
        const uint64_t address = minimize::parseAddress(addressText).value_or(0); // 0 is never a window
        const auto     w       = address != 0 ? windowById(address) : nullptr;
        if (!w || !placeable(w) || fullscreenNow(w) || !g_layoutManager || !State::workspaceState()) {
            refuse("not a window that can be tiled now (TL9)");
            return;
        }
        const auto m = monitorOf(w);
        if (!m || !m->m_activeWorkspace || showsSpecial(m) || w->m_workspace != m->m_activeWorkspace) {
            refuse("the window is not on the Desktop its output shows");
            return;
        }
        if (tiling::splitOf(s.splits, w->m_workspace->m_id)) {
            refuse("the window is on a Split View Desktop already");
            return;
        }
        if (gf::stager::stripColumnRight(m)) {
            refuse("Stages shows its strip on that output (ADR-0036 D47)");
            return;
        }
        if (!tiling::fitsFrame(constraintsOf(w), splitHalf(m, *zone))) {
            refuse("the window does not fit half of the output (TL8; the popover greys the halves)");
            return;
        }
        catchUp();
        // D41: a new Desktop with the next free id on the window's output (the shell lists it after the one it came from).
        std::vector<int64_t> ids;
        for (const auto& ws : State::workspaceState()->workspacesCopy()) {
            if (ws)
                ids.push_back(ws->m_id);
        }
        const int64_t id   = tiling::nextDesktopId(ids);
        const auto    desk = State::workspaceState()->create(id, m->m_id);
        if (!desk) {
            refuse("Hyprland made no Desktop");
            return;
        }
        const int64_t home    = w->m_workspace->m_id;
        const auto    homeWs  = w->m_workspace;
        const auto    target  = w->layoutTarget();
        const CBox    current = target->position();
        // Its tile on that Desktop, if any, comes back with Exit Full Screen (macOS restores the window's frame; #48 MINOR 8).
        // Kept before the move, which gives the record the new Desktop.
        if (const auto* before = s.book.find(idOf(w)); before && before->state == tiling::TileState::Tiled)
            s.splitHomes[idOf(w)] = *before;
        s.splits.push_back(tiling::SplitDesk{.workspace = id, .output = m->m_name, .home = home, .members = {idOf(w)}, .waiting = true});
        const auto moved = Config::Actions::moveToWorkspace(desk, false, w); // the output shows the new Desktop
        if (!moved || w->m_workspace != desk || m->m_activeWorkspace != desk) {
            std::erase_if(s.splits, [id](const tiling::SplitDesk& d) { return d.workspace == id; });
            s.splitHomes.erase(idOf(w));
            // A refusal changes nothing (ADR-0007): back on its Desktop, which its output shows (#48 review, MINOR 9).
            if (w->m_workspace == desk) {
                if (const auto back = Config::Actions::moveToWorkspace(homeWs, true, w); !back)
                    logRequest(Log::WARN, "split: back to Desktop {} failed: {}", home, back.error().message);
                applySurface(w, current);
            }
            if (m->m_activeWorkspace != homeWs) {
                if (const auto shown = Config::Actions::changeWorkspace(homeWs); !shown)
                    logRequest(Log::WARN, "split: showing Desktop {} again failed: {}", home, shown.error().message);
            }
            refuse(moved ? std::string{"the window did not reach the new Desktop"} : std::format("the move failed: {}", moved.error().message));
            return;
        }
        // The window in its half of the whole output (D42), alone in the "left-right" layout until its second window joins it.
        const auto* layout  = tiling::layoutById("left-right");
        const auto  band    = gf::chrome::bandOf(w);
        const auto  frames  = fitted({layout->zones[static_cast<size_t>(*zone)]}, {w}, areaFor(m, id));
        const CBox  surface = toCBox(tiling::surfaceOf(frames.front(), band));
        g_layoutManager->setTargetGeom(surface, target);
        s.book.placed(idOf(w), toRect(current), toRect(surface), band, tiling::Placement{.place = std::nullopt, .layout = std::string{layout->id}, .zone = *zone},
                      m->m_name, id, 0);
        titlebarsFollowSplits(); // its titlebar goes: no band above it in its half (D73)
        // The Split View always asks for its second window (whatever "Suggest windows to fill the rest of a layout" says):
        // from the Desktop the window came from. Nothing to suggest: it fills the Desktop alone (D43).
        s.suggestion = suggestionFor(idOf(w), m);
        if (!s.suggestion) {
            settleSplit(id);
            splitFill(w, s.splits.back());
        }
        logRequest(Log::DEBUG, "split {:x}: {} of Desktop {} on {}, from Desktop {}{}", idOf(w), sideText, id, m->m_name, home,
                   s.suggestion ? std::format(", {} window(s) to suggest", s.suggestion->windows.size()) : ", alone");
        notify(tiling::Reason::Placed);
    }

    namespace {
        // D44: `w`, a member of `desk`, back on its home Desktop, shown: in its tile there from before the split when that
        // zone is still free (MINOR 8 of #48), else at its box from before tiling; the other member fills the Split View
        // Desktop alone, and one left without a member ends. An empty string, or why not.
        std::string unsplitWindow(const PHLWINDOW& w, tiling::Unsplit how) {
            auto&      s     = st();
            const auto split = tiling::splitOfWindow(s.splits, idOf(w));
            if (!split || !g_layoutManager || !State::workspaceState())
                return "the window is no member of a Split View Desktop";
            if (!tiling::movable(factsOf(w)))
                return "the window closed or unmapped (gate C1)";
            const bool replace = how == tiling::Unsplit::Replace;
            if (replace && split->members.size() != 2)
                return "Replace Tiled Window needs the other member (D71)";
            const tiling::SplitDesk desk = *split;
            const auto              m    = splitMonitor(desk) ? splitMonitor(desk) : monitorOf(w);
            auto                    home = State::workspaceState()->query().id(desk.home).run();
            if (!home && m)
                home = State::workspaceState()->create(desk.home, m->m_id); // Hyprland ended it when it emptied
            if (!home || home->m_isSpecialWorkspace)
                return "its Desktop could not be made again";
            catchUp();
            const auto*        r      = s.book.find(idOf(w));
            const tiling::Rect before = r ? r->before : toRect(w->layoutTarget()->position());
            std::optional<tiling::TileRecord> homeTile;
            if (const auto it = s.splitHomes.find(idOf(w)); it != s.splitHomes.end()) {
                const auto& t = it->second;
                if (t.workspace == desk.home && s.book.zoneFree(tiling::frameOf(t.box, t.band), t.output, desk.home, idOf(w)))
                    homeTile = t;
            }
            // Replace Tiled Window keeps the Split View Desktop shown (its picker shows there); the other ways show the Desktop.
            if (const auto moved = Config::Actions::moveToWorkspace(home, replace, w); !moved || w->m_workspace != home)
                return moved ? std::string{"the window did not reach its Desktop"} : std::format("the move failed: {}", moved.error().message);
            // Back as an ordinary window: out of a zoom or a full screen of Hyprland's (re-review of e5bd9d2: a member zoomed by
            // a key went home still zoomed), once the move can no longer be refused (PASS on 1ee992e, NIT: a refusal changed it).
            if (fullscreenNow(w)) {
                if (const auto& fs = Fullscreen::controller())
                    fs->setFullscreenMode(w, Fullscreen::FSMODE_NONE, Fullscreen::FSMODE_NONE, false);
            }
            if (s.book.find(idOf(w)))
                s.book.forget(idOf(w));
            s.splitHomes.erase(idOf(w));
            if (homeTile) {
                applySurface(w, toCBox(homeTile->box));
                // Its group again when another window still holds it (the shared edge, Show Tile Group); else none.
                const bool groupLives = homeTile->group != 0 && std::ranges::any_of(s.book.records(), [&](const tiling::TileRecord& o) { return o.group == homeTile->group; });
                s.book.placed(idOf(w), homeTile->before, homeTile->box, homeTile->band, homeTile->where, homeTile->output, desk.home, groupLives ? homeTile->group : 0);
            } else
                applySurface(w, beforeBox(w, before));
            if (how == tiling::Unsplit::Fullscreen) {
                // Make Window Full Screen (D71): in full screen on that Desktop, its box from before kept for the way back.
                if (const auto& fs = Fullscreen::controller())
                    fs->setFullscreenMode(w, Fullscreen::FSMODE_FULLSCREEN, Fullscreen::FSMODE_FULLSCREEN, false);
            }
            bool waits = false;
            if (const auto d = std::ranges::find(s.splits, desk.workspace, &tiling::SplitDesk::workspace); d != s.splits.end()) {
                std::erase(d->members, idOf(w));
                // Replace Tiled Window (D71): the other member keeps its half and waits for the window the picker offers, from
                // the Desktop the Split View came from but the one replaced; nothing to offer: it fills alone (D43).
                const auto m = replace && d->members.size() == 1 ? splitMonitor(*d) : nullptr;
                if (m && m->m_activeWorkspace && m->m_activeWorkspace->m_id == d->workspace) {
                    s.suggestion = suggestionFor(d->members.front(), m, idOf(w));
                    d->waiting   = s.suggestion.has_value();
                    waits        = d->waiting;
                }
            }
            logRequest(Log::DEBUG, "unsplit {:x}: back on Desktop {}{}{}", idOf(w), desk.home, homeTile ? ", in its tile" : "",
                       how == tiling::Unsplit::Fullscreen ? ", in full screen" : waits ? ", its half waiting for another window" : "");
            if (!waits)
                settleSplit(desk.workspace);
            splitCheck();
            notify(homeTile ? tiling::Reason::Placed : tiling::Reason::Forgotten, true);
            return {};
        }
    } // namespace

    void unsplitRequest(std::string_view addressText, std::string_view howText) {
        if (gf::deferredFocus::sessionLocked()) {
            logRequest(Log::INFO, "unsplit: refused: the session is locked");
            notify(tiling::Reason::Locked);
            return;
        }
        const auto how = tiling::unsplitHow(howText);
        if (!how) {
            logRequest(Log::WARN, "unsplit: rejected: how is desktop, fullscreen or replace");
            notify(tiling::Reason::Invalid);
            return;
        }
        const uint64_t address = minimize::parseAddress(addressText).value_or(0); // 0 is never a window
        const auto     w       = address != 0 ? windowById(address) : nullptr;
        if (const auto why = w ? unsplitWindow(w, *how) : std::string{"no such window"}; !why.empty()) {
            logRequest(Log::WARN, "unsplit: rejected: {}", why);
            notify(tiling::Reason::Invalid);
        }
    }

    bool inSplit(const PHLWINDOW& w) {
        return w && tiling::splitOfWindow(st().splits, idOf(w)) != nullptr;
    }

    void memberDragBegin(const PHLWINDOW& w) {
        auto& s = st();
        if (s.ready && w && tiling::splitOfWindow(s.splits, idOf(w)))
            s.memberDrag = w;
    }

    void memberDragForget() {
        st().memberDrag.reset();
    }

    void memberDrop(const PHLWINDOW& w, std::optional<Vector2D> at) {
        auto& s = st();
        s.memberDrag.reset(); // first: from here the record is checked as any other (nothing below reconciles before it is placed)
        if (!s.ready || !w || !g_layoutManager)
            return;
        const auto* d = tiling::splitOfWindow(s.splits, idOf(w));
        if (!d || !w->m_workspace || w->m_workspace->m_id != d->workspace)
            return; // it left the Split View meanwhile (splitCheck)
        const auto* r = s.book.find(idOf(w));
        if (!r)
            return;
        const auto       m       = splitMonitor(*d);
        const uint64_t   otherId = d->members.size() == 2 ? (d->members[0] == idOf(w) ? d->members[1] : d->members[0]) : 0;
        const auto*      ro      = otherId ? s.book.find(otherId) : nullptr;
        const auto       ow      = otherId ? windowById(otherId) : nullptr;
        const auto*      layout  = tiling::layoutById("left-right");
        std::optional<int> zone;
        if (at && m && ro && ow && layout && !gf::deferredFocus::sessionLocked() && r->state == tiling::TileState::Tiled && ro->state == tiling::TileState::Tiled &&
            r->where.layout == layout->id && ro->where.layout == layout->id && ow->m_workspace == w->m_workspace)
            zone = tiling::splitDropZone(splitHalf(m, 0), splitHalf(m, 1), r->where.zone, at->x, at->y);
        if (!zone) {
            applySurface(w, toCBox(r->box)); // back in its half (the state from before the drag, also under the lock)
            return;
        }
        // The two swap halves (macOS): each takes the other's zone, fitted together on the whole output (TL8), in its group.
        const std::array<PHLWINDOW, 2> windows{w, ow};
        const std::array<int, 2>       zones{*zone, r->where.zone};
        const std::array<uint64_t, 2>  groups{r->group, ro->group};
        const auto frames = fitted({layout->zones[static_cast<size_t>(zones[0])], layout->zones[static_cast<size_t>(zones[1])]}, {windows[0], windows[1]},
                                   areaFor(m, d->workspace));
        for (size_t i = 0; i < windows.size(); ++i) {
            const CBox current = windows[i]->layoutTarget()->position();
            const auto band    = gf::chrome::bandOf(windows[i]);
            const CBox surface = toCBox(tiling::surfaceOf(frames[i], band));
            applySurface(windows[i], surface);
            s.book.placed(idOf(windows[i]), toRect(current), toRect(surface), band,
                          tiling::Placement{.place = std::nullopt, .layout = std::string{layout->id}, .zone = zones[i]}, m->m_name, d->workspace, groups[i]);
        }
        logRequest(Log::DEBUG, "split: {:x} dropped on the other half of Desktop {}: the two windows swapped halves", idOf(w), d->workspace);
        notify(tiling::Reason::Placed);
    }

    bool leaveSplit(const PHLWINDOW& w) {
        if (!inSplit(w) || gf::deferredFocus::sessionLocked())
            return false;
        if (const auto why = unsplitWindow(w, tiling::Unsplit::Desktop); !why.empty())
            logRequest(Log::WARN, "split: the green button of {:x}: {}", idOf(w), why);
        return true;
    }

    void arrangeRequest(std::string_view json) {
        auto&      s      = st();
        const auto refuse = [](std::string_view why) {
            logRequest(Log::WARN, "arrange: rejected: {}", why);
            notify(tiling::Reason::Invalid);
        };
        if (gf::deferredFocus::sessionLocked()) {
            logRequest(Log::INFO, "arrange: refused: the session is locked");
            notify(tiling::Reason::Locked);
            return;
        }
        const auto request = tiling::parseArrange(json);
        if (!request) {
            refuse(request.error());
            return;
        }
        if (!g_layoutManager) {
            refuse("no layout manager");
            return;
        }
        // A pick of the suggestions (TL28): the window whose layout the zone belongs to, still tiled in that layout.
        const auto asker = request->with ? windowById(*request->with) : nullptr;
        if (request->with) {
            const auto* r = asker ? s.book.find(*request->with) : nullptr;
            if (!r || r->state != tiling::TileState::Tiled || r->where.layout != request->layout) {
                refuse("with is not a window tiled in that layout (tiling.md TL28)");
                return;
            }
        }
        std::vector<PHLWINDOW> windows;
        for (const auto address : request->windows) {
            const auto w = windowById(address);
            if (!w) {
                refuse("a window is not a live tileable window (tiling.md TL9)");
                return;
            }
            if (tiling::splitOfWindow(s.splits, address)) {
                refuse("a window of a Split View Desktop is placed by its Desktop (tiling.md TL33)");
                return;
            }
            windows.push_back(w);
        }
        // The output is the one the windows are on (under their middle), whatever Desktop Hyprland still records for them; for
        // a pick, the one of the window that asked: the picked window may wait on special:minimized (D27).
        const auto here = monitorOf(asker ? asker : windows.front());
        const auto m    = request->output.empty() ? here : monitorByName(request->output);
        if (!m) {
            refuse("the output is unknown");
            return;
        }
        if (here != m) {
            refuse(std::format("the {} window is on {}, not on {} (D3)", asker ? "asking" : "first", here ? here->m_name : "no output", m->m_name));
            return;
        }
        // A pick may be a window minimized from that output (D27): restored first, once every check passed.
        const auto minimized = asker ? gf::minimizer::minimizedFrom(m->m_name) : std::vector<uint64_t>{};
        const bool restoring = asker && std::ranges::find(minimized, idOf(windows.front())) != minimized.end() && tileableKind(windows.front());
        for (const auto& w : windows) {
            if (!restoring && !placeable(w)) {
                refuse("a window is not a live tileable window (tiling.md TL9)");
                return;
            }
        }
        // Every check before anything moves (ADR-0007: a refusal changes nothing).
        if (showsSpecial(m) || !m->m_activeWorkspace) {
            refuse(std::format("{} shows a special workspace or no Desktop (TL9)", m->m_name));
            return;
        }
        for (const auto& w : windows) {
            if (!restoring && monitorOf(w) != m) {
                refuse(std::format("the windows are not all on {}", m->m_name));
                return;
            }
        }
        // The records first (a tile moved by other means is freed, a deferred one placed), so that a pick is checked against
        // them before anything of this request moves: its minimized window is restored only once the pick passed (ADR-0007).
        catchUp();
        if (request->with) {
            const auto* r = s.book.find(*request->with);
            if (!r || r->state != tiling::TileState::Tiled || r->where.layout != request->layout) {
                refuse("with is not a window tiled in that layout any more");
                return;
            }
            if (r->output != m->m_name || r->workspace != m->m_activeWorkspace->m_id) {
                refuse("the asking window's tile is not on that output's Desktop");
                return;
            }
            const int  zone = request->zone.value_or(-1); // parseArrange: with comes with a zone
            const auto held = tiling::zonesHeld(s.book.records(), *r);
            if (std::ranges::find(held, zone) != held.end()) {
                refuse(std::format("zone {} of {} is held", zone, request->layout));
                return;
            }
            if (tiling::splitOfWindow(s.splits, *request->with) && !tiling::fitsFrame(constraintsOf(windows.front()), splitHalf(m, zone))) {
                refuse("the window does not fit the other half of the Split View (TL8)");
                return;
            }
        }
        // D69 (D57's model for every arrangement): each given window fits its zone as the glyph shows it, else nothing moves (it
        // would overlap its neighbours and shift the layout's rows or columns); the shell greys those (unfitZones).
        const auto* layout = tiling::layoutById(request->layout); // parseArrange checked the id
        if (!layout) {
            refuse("the layout is unknown");
            return;
        }
        const auto area = areaFor(m);
        for (size_t i = 0; i < windows.size(); ++i) {
            const int zone = request->zone ? *request->zone : static_cast<int>(i);
            if (zone < 0 || zone >= static_cast<int>(layout->zones.size()) ||
                !tiling::fitsZone(constraintsOf(windows[i]), layout->zones[static_cast<size_t>(zone)], area)) {
                refuse(std::format("{:x} does not fit zone {} of {} (TL8, D69)", idOf(windows[i]), zone, request->layout));
                return;
            }
        }
        // Then a minimized pick comes back to that output's Desktop (no Dock animation: it appears in its zone), and each window
        // takes the Desktop of the output it is on (D9), whatever moved it there: the plugin's titlebar drag, or a move
        // Hyprland's own action makes without changing the Desktop (Actions::move).
        if (restoring) {
            gf::minimizer::restore(idOf(windows.front()), std::nullopt);
            if (!placeable(windows.front()) || monitorOf(windows.front()) != m) {
                refuse("the minimized window did not come back on that output (its restore failed)");
                return;
            }
        }
        // TL33, D54: a pick into a Split View Desktop keeps the tile the picked window had on its Desktop, for its Exit Full
        // Screen (before followOutput gives the record the Split View Desktop).
        if (request->with) {
            if (const auto* d = tiling::splitOfWindow(s.splits, *request->with); d && d->workspace == m->m_activeWorkspace->m_id) {
                for (const auto& w : windows) {
                    if (const auto* r = s.book.find(idOf(w)); r && r->state == tiling::TileState::Tiled && r->workspace != d->workspace)
                        s.splitHomes[idOf(w)] = *r;
                }
            }
        }
        for (const auto& w : windows)
            followOutput(w);
        const auto workspace = m->m_activeWorkspace;
        for (const auto& w : windows) {
            if (w->m_workspace != workspace) { // followOutput gives every placeable window that Desktop: never expected
                refuse(std::format("{} shows Desktop {}, a window stayed on Desktop {}", m->m_name, workspace->m_name, w->m_workspace ? w->m_workspace->m_name : "none"));
                return;
            }
        }
        std::vector<int>          zoneIndex;
        std::vector<tiling::Zone> zones;
        zoneIndex.reserve(layout->zones.size());
        zones.reserve(layout->zones.size());
        if (request->zone) {
            zoneIndex.push_back(*request->zone);
        } else {
            for (size_t i = 0; i < windows.size(); ++i)
                zoneIndex.push_back(static_cast<int>(i));
            // TL6: then each remaining zone takes the topmost tileable window (stacking order) on that output and Desktop, in the
            // active stage, that fits it (D69: a window too large for a zone is left for another zone or left out; a zone no
            // window fits stays empty, for the suggestion).
            if (request->fill && Desktop::windowState()) {
                const auto& all = Desktop::windowState()->windows(); // bottom to top
                for (size_t z = windows.size(); z < layout->zones.size(); ++z) {
                    for (auto it = all.rbegin(); it != all.rend(); ++it) {
                        const auto& w = *it;
                        if (!w || std::ranges::find(windows, w) != windows.end() || w->m_workspace != workspace || !placeable(w) || monitorOf(w) != m)
                            continue;
                        if (!tiling::fitsZone(constraintsOf(w), layout->zones[z], area))
                            continue;
                        windows.push_back(w);
                        zoneIndex.push_back(static_cast<int>(z));
                        break;
                    }
                }
            }
        }
        for (const auto i : zoneIndex)
            zones.push_back(layout->zones[static_cast<size_t>(i)]);
        // TL33: a pick into the other half of a Split View Desktop makes that window its second member (the two are one tile
        // group: the shared edge resizes both). Before its frame is fitted (nothing is refused from here on): a member has no
        // band above it (step 6e, D73), so its half is filled from the output's top edge.
        if (request->with) {
            const auto d = std::ranges::find_if(s.splits, [&](const tiling::SplitDesk& x) {
                return x.workspace == workspace->m_id && std::ranges::find(x.members, *request->with) != x.members.end();
            });
            if (d != s.splits.end()) {
                for (const auto& w : windows) {
                    if (std::ranges::find(d->members, idOf(w)) == d->members.end())
                        d->members.push_back(idOf(w));
                }
                d->waiting = false;
            }
        }
        const auto frames = fitted(zones, windows, area);
        // The windows placed together form a tile group (TL6, T1d); one window alone has none; a pick joins the asker's (TL28).
        const uint64_t group = request->with ? s.book.joinGroup(*request->with) : windows.size() >= 2 ? s.book.newGroup() : 0;
        for (size_t i = 0; i < windows.size(); ++i) {
            const auto& w       = windows[i];
            const auto  target  = w->layoutTarget();
            const CBox  current = target->position();
            const auto  band    = gf::chrome::bandOf(w);
            const CBox  surface = toCBox(tiling::surfaceOf(frames[i], band));
            g_layoutManager->setTargetGeom(surface, target);
            s.book.placed(idOf(w), toRect(current), toRect(surface), band, tiling::Placement{.place = std::nullopt, .layout = std::string{layout->id}, .zone = zoneIndex[i]},
                          m->m_name, workspace->m_id, group);
        }
        titlebarsFollowSplits(); // a window picked into a Split View: its titlebar goes (D73)
        // TL28: the zones left empty in that layout, offered to the shell in the state reply until the next change (none while
        // "Suggest windows to fill the rest of a layout" is off, TL32).
        s.suggestion = state().tilingSuggestions ? suggestionFor(request->with ? *request->with : idOf(windows.front()), m) : std::nullopt;
        logRequest(Log::DEBUG, "arrange: {} with {} window(s) on {}{}", layout->id, windows.size(), m->m_name,
                   s.suggestion ? std::format(", {} zone(s) to suggest", s.suggestion->zones.size()) : "");
        notify(tiling::Reason::Placed);
    }

    void suggestionsOff() {
        st().suggestion.reset();
    }

    void marginsChanged() {
        relayout(ERelayout::Margins);
    }

    std::string stateReply() {
        auto& s = st();
        reconcile(); // records only: the reply never moves a window (deferred ones are placed at the next tiling action)
        const auto                       all = monitors();
        std::vector<tiling::StateOutput> outputs;
        outputs.reserve(all.size());
        for (const auto& m : all) {
            const auto area  = areaFor(m);
            const CBox box   = m->logicalBox();
            const bool split = m->m_activeWorkspace && tiling::splitOf(s.splits, m->m_activeWorkspace->m_id) != nullptr; // TL33: the whole output
            tiling::StateOutput o{.name = m->m_name, .area = split ? toRect(box) : area.box, .outputClass = tiling::classify(box.w, box.h), .grid = area.grid.step, .windows = {}};
            for (const auto& r : s.book.records()) {
                if (r.output == m->m_name)
                    o.windows.push_back(&r);
            }
            outputs.push_back(std::move(o));
        }
        // TL28: the suggestion while nothing changed since; a window closed meanwhile is left out.
        std::optional<tiling::Suggestion> suggestion;
        if (s.suggestion && s.suggestion->generation == s.book.generation()) {
            suggestion = *s.suggestion;
            std::erase_if(suggestion->windows, [](uint64_t id) { return !windowById(id); });
            if (suggestion->windows.empty())
                suggestion.reset();
        }
        // TL33: the Split View Desktops whose workspace still exists (splitCheck ends the others at the next event).
        std::vector<tiling::SplitDesk> splits;
        for (const auto& d : s.splits) {
            if (State::workspaceState() && State::workspaceState()->query().id(d.workspace).run())
                splits.push_back(d);
        }
        // D57: the windows that do not fit half of their output (the Window menu greys their Full Screen Tile); the windows of
        // fixed size (the Window menu greys their Zoom and tiling items, ADR-0040 step 1b); D69: the zones each tileable window
        // does not fit (the Window menu greys those Halves, Quarters and Arrange items).
        std::vector<uint64_t>          unfit;
        std::vector<uint64_t>          fixed;
        std::vector<tiling::WindowFit> fits;
        if (Desktop::windowState()) {
            for (const auto& w : Desktop::windowState()->windows()) {
                if (w && placeable(w) && !splittable(w))
                    unfit.push_back(idOf(w));
                if (w && w->m_isMapped && fixedSize(w))
                    fixed.push_back(idOf(w));
                if (w && placeable(w)) {
                    auto zones  = unfitZones(w);
                    auto places = unfitPlaces(w);
                    if (!zones.empty() || !places.empty())
                        fits.push_back(tiling::WindowFit{.address = idOf(w), .zones = std::move(zones), .places = std::move(places)});
                }
            }
        }
        return tiling::stateJson(s.book.generation(), outputs, suggestion ? &*suggestion : nullptr, splits, unfit, fixed, fits);
    }

    void beforePointerMotion() {
        auto& s = st();
        if (!s.ready || !g_layoutManager)
            return;
        if (s.edge) {
            edgeTimed(edgeMotion); // TL30: the plugin's own drag (Hyprland has none)
            return;
        }
        const auto& drag = g_layoutManager->dragController();
        if (!drag || !hyprlandDrag(drag->mode())) {
            if (s.resizing.lock())
                finishResize(); // the drag ended without a release seen here
            if (s.drag.hyprland)
                dragDone(); // likewise the preview of a move
            if (!s.moveRelease)
                s.moveFrom = {}; // a move that ended without a release seen here (one owed is read by finishMove)
            edgeHover();
            return;
        }
        s.edgeCursor = false; // a drag of Hyprland's set its own special-action cursor in place of the handle's
        const auto target = drag->target();
        const auto w      = target ? target->window() : nullptr;
        if (drag->mode() == MBIND_MOVE) {
            hyprlandMove(w, target);
            return;
        }
        if (s.drag.hyprland)
            dragDone(); // a resize now: no move preview
        const auto r = w ? s.book.find(idOf(w)) : nullptr;
        if (r && r->state == tiling::TileState::Tiled && s.book.beginResize(idOf(w)))
            s.resizing = w;
    }

    bool beforePointerButton(uint32_t button, bool pressed, uint32_t timeMs) {
        auto& s = st();
        if (!s.ready || !g_layoutManager || !g_pInputManager)
            return false;
        const Vector2D pointer = g_pInputManager->getMouseCoordsInternal();
        // TL30: the shared edge's handle takes a plain left press and its release (both cancelled: Hyprland's held-button
        // state stays as it was, ADR-0015 P6). A left press while a release is still owed means that release was lost (a
        // device gone): the drag ends and nothing more is cancelled for it.
        if (button == BTN_LEFT && pressed && std::exchange(s.edgeReleaseOwed, false))
            edgeEnd("its release was not seen");
        if (button == BTN_LEFT && !pressed && std::exchange(s.edgeReleaseOwed, false)) {
            edgeEnd("released");
            return true;
        }
        if (button == BTN_LEFT && pressed) {
            if (edgePress(pointer, timeMs))
                return true;
            s.separator = {}; // a press anywhere else ends a separator's double-click
        }
        if (pressed) {
            if (button == BTN_LEFT) {
                s.press   = pointer;
                s.pressMs = timeMs;
            }
            return false;
        }
        if (s.resizing.lock())
            scheduleAfter(); // ends Resizing once Hyprland ended its drag (afterEvents)
        if (button != BTN_LEFT)
            return false;
        const auto  grip   = std::exchange(s.press, std::nullopt);
        const auto& drag   = g_layoutManager->dragController();
        const auto  mode   = drag ? drag->mode() : MBIND_INVALID;
        const auto  target = drag && hyprlandDrag(mode) ? drag->target() : nullptr;
        const auto  w      = target ? target->window() : nullptr;
        if (!w)
            return false;
        if (mode == MBIND_MOVE) {
            // TL16: tiled once Hyprland ended the drag; the top clamp leaves the window to it (the tile lies below the menu
            // bar), as it does a tiled window put back in its tile.
            const auto shown = previewOf(w);
            const auto r     = s.book.find(idOf(w));
            if (shown || (r && r->state == tiling::TileState::Tiled))
                gf::topClamp::skip(w);
            s.moveRelease = SMoveRelease{.window = w, .snap = shown};
            scheduleAfter();
            return false;
        }
        // A resize begun at the press and released where it began: a click on the window's resize border (TL20).
        if (grip && !gf::titlebar::exceedsDragThreshold(pointer.x - grip->x, pointer.y - grip->y))
            borderClick(w, *grip, s.pressMs);
        return false;
    }

} // namespace gf::tiler
