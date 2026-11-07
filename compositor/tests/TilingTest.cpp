#include <gtest/gtest.h>

#include "core/Protocol.hpp"
#include "core/Tiling.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <string>
#include <vector>

using namespace gf::tiling;

namespace {
    // GF-REF in the nested layout: 1920x1080 at (1440, 0), menu bar 24, Dock 82; WAYLAND-1 sits on its left.
    const Output kOutput{Rect{1440, 0, 1920, 1080}, 24, false, true};
    const Rect   kArea{1440, 24, 1920, 974};
    const Rect   kWindow{2000, 300, 800, 500};
    constexpr double kBar = 32;

    std::optional<Place> at(double x, double y, Output o = kOutput, DragOptions opt = {}) {
        return placeForPointer(x, y, o, opt);
    }
}

TEST(TilingDrag, FreeSideEdgeIsAHalfAndItsCornersAreQuarters) {
    EXPECT_EQ(at(3359, 540), Place::Right);
    EXPECT_EQ(at(3356, 540), Place::Right) << "within kEdge of the edge";
    EXPECT_EQ(at(3359, 50), Place::TopRight);
    EXPECT_EQ(at(3359, 1070), Place::BottomRight);
    EXPECT_EQ(at(3359, 1080 - 1 - kCorner), Place::BottomRight);
    EXPECT_EQ(at(3359, 1080 - 2 - kCorner), Place::Right);
    EXPECT_FALSE(at(3350, 540).has_value()) << "not at the edge yet";
}

TEST(TilingDrag, ASharedEdgeLeadsToTheNextOutputAndNeverTiles) {
    EXPECT_FALSE(at(1440, 540).has_value());
    EXPECT_FALSE(at(1441, 1070).has_value());
    Output alone = kOutput;
    alone.leftFree = true;
    EXPECT_EQ(at(1440, 540, alone), Place::Left);
    EXPECT_EQ(at(1442, 10, alone), Place::TopLeft) << "a side corner wins over the menu bar";
}

TEST(TilingDrag, TheMenuBarFillsAndTheOptionsTurnEachOff) {
    EXPECT_EQ(at(2400, 0), Place::Fill);
    EXPECT_EQ(at(2400, 23), Place::Fill);
    EXPECT_FALSE(at(2400, 24).has_value());
    EXPECT_FALSE(at(2400, 0, kOutput, DragOptions{true, false}).has_value());
    EXPECT_EQ(at(3359, 540, kOutput, DragOptions{true, false}), Place::Right);
    EXPECT_FALSE(at(3359, 540, kOutput, DragOptions{false, true}).has_value());
    EXPECT_EQ(at(3359, 10, kOutput, DragOptions{false, true}), Place::Fill) << "edges off: the menu bar still fills";
    EXPECT_FALSE(at(1439, 540).has_value()) << "another output";
    EXPECT_FALSE(at(2400, 1080).has_value());
}

TEST(TilingPlace, HalvesAndQuartersSplitTheFreeAreaWithMargins) {
    const auto left  = surfaceFor(Place::Left, kArea, kBar, true, kWindow);
    const auto right = surfaceFor(Place::Right, kArea, kBar, true, kWindow);
    // Frames: margin 8 around and between: (1920 - 24) / 2 = 948 wide each.
    EXPECT_DOUBLE_EQ(left.x, 1448);
    EXPECT_DOUBLE_EQ(left.y, 24 + 8 + kBar);
    EXPECT_DOUBLE_EQ(left.w, 948);
    EXPECT_DOUBLE_EQ(left.h, 974 - 16 - kBar);
    EXPECT_DOUBLE_EQ(right.x, 1440 + 16 + 948);
    EXPECT_DOUBLE_EQ(right.x + right.w + 8, 1440 + 1920) << "the right margin";
    const auto tl = surfaceFor(Place::TopLeft, kArea, kBar, true, kWindow);
    const auto bl = surfaceFor(Place::BottomLeft, kArea, kBar, true, kWindow);
    const auto br = surfaceFor(Place::BottomRight, kArea, kBar, true, kWindow);
    EXPECT_DOUBLE_EQ(tl.x, bl.x);
    EXPECT_DOUBLE_EQ(bl.x + bl.w + 8, br.x) << "8 between the columns";
    EXPECT_DOUBLE_EQ(tl.y - kBar + (tl.h + kBar) + 8, bl.y - kBar) << "8 between the rows, titlebar included";
    EXPECT_DOUBLE_EQ(bl.y + bl.h + 8, 24 + 974) << "the bottom margin";
    const auto top    = surfaceFor(Place::Top, kArea, kBar, true, kWindow);
    const auto bottom = surfaceFor(Place::Bottom, kArea, kBar, true, kWindow);
    EXPECT_DOUBLE_EQ(top.w, 1920 - 16);
    EXPECT_DOUBLE_EQ(bottom.y, bl.y);
}

TEST(TilingPlace, FillAndNoMarginsUseEveryPixel) {
    const auto fill = surfaceFor(Place::Fill, kArea, kBar, false, kWindow);
    EXPECT_DOUBLE_EQ(fill.x, 1440);
    EXPECT_DOUBLE_EQ(fill.y, 24 + kBar) << "the titlebar starts right below the menu bar";
    EXPECT_DOUBLE_EQ(fill.w, 1920);
    EXPECT_DOUBLE_EQ(fill.h, 974 - kBar);
    const auto left  = surfaceFor(Place::Left, kArea, kBar, false, kWindow);
    const auto right = surfaceFor(Place::Right, kArea, kBar, false, kWindow);
    EXPECT_DOUBLE_EQ(left.w + right.w, 1920);
    EXPECT_DOUBLE_EQ(right.x, 1440 + 960);
    const auto frame = frameOf(fill, kBar);
    EXPECT_DOUBLE_EQ(frame.y, 24);
    EXPECT_DOUBLE_EQ(frame.h, 974);
}

TEST(TilingPlace, CenterKeepsTheSizeAndCapsIt) {
    const auto c = surfaceFor(Place::Center, kArea, kBar, true, kWindow);
    EXPECT_DOUBLE_EQ(c.w, 800);
    EXPECT_DOUBLE_EQ(c.h, 500);
    EXPECT_DOUBLE_EQ(c.x, 1440 + (1920 - 800) / 2.0);
    EXPECT_DOUBLE_EQ(c.y - kBar, 24 + (974 - 532) / 2.0);
    const auto big = surfaceFor(Place::Center, kArea, kBar, true, Rect{0, 0, 5000, 5000});
    EXPECT_LE(big.w, 1920 * kCenterMaxFraction);
    EXPECT_LE(big.h + kBar, 974 * kCenterMaxFraction + 1);
    const auto tiny = surfaceFor(Place::TopLeft, Rect{0, 0, 10, 10}, kBar, true, kWindow);
    EXPECT_GE(tiny.w, 1);
    EXPECT_GE(tiny.h, 1);
}

TEST(TilingNames, PlacesAndOptionsParseStrictly) {
    for (const char* name : {"left", "right", "top", "bottom", "top-left", "top-right", "bottom-left", "bottom-right", "fill", "center"}) {
        const auto p = parsePlace(name);
        ASSERT_TRUE(p.has_value()) << name;
        EXPECT_EQ(nameOf(p.value_or(Place::Center)), name);
    }
    for (const char* bad : {"", "Left", "left ", "topleft", "maximize", "fill\n"})
        EXPECT_FALSE(parsePlace(bad).has_value()) << bad;
    EXPECT_EQ(parseBool("true"), true);
    EXPECT_EQ(parseBool("false"), false);
    EXPECT_FALSE(parseBool("1").has_value());
    EXPECT_FALSE(parseBool("True").has_value());
}

// TL32: the six switches the plugin takes; tile groups forward together stays in the shell (ADR-0036 D38).
TEST(Tiling, SwitchKeys) {
    EXPECT_EQ(switchOf("tilingEdges"), Switch::Edges);
    EXPECT_EQ(switchOf("tilingMenuBar"), Switch::MenuBar);
    EXPECT_EQ(switchOf("tilingOptionDrag"), Switch::AltDrag);
    EXPECT_EQ(switchOf("tilingMargins"), Switch::Margins);
    EXPECT_EQ(switchOf("tilingLayouts"), Switch::Layouts);
    EXPECT_EQ(switchOf("tilingSuggestions"), Switch::Suggestions);
    for (const char* other : {"", "tilingGroups", "tilingAltDrag", "TilingLayouts", "tilingLayouts ", "titlebarDoubleClick", "stagesEnabled"})
        EXPECT_FALSE(switchOf(other).has_value()) << other;
}

// ---- ADR-0036 step 1: the geometry engine (docs/specs/tiling.md TL1-TL15) ----

namespace {
    // An output of `px` device pixels at `scale` (Hyprland keeps its logical size whole), at the layout origin, with a
    // 24-px menu bar and an 82-px Dock: the work area tiles use.
    Area areaFor(double pxW, double pxH, double scale, double margin) {
        const double w = pxW / scale, h = pxH / scale;
        return Area{Rect{0, 24, w, h - 24 - 82}, margin, Grid{0, 0, gridStep(scale)}};
    }

    bool whole(double v) {
        return std::abs(v - std::round(v)) < 1e-9;
    }

    Placement at(Place place) {
        Placement p;
        p.place = place;
        return p;
    }

    Placement inLayout(std::string_view layout, int zone) {
        Placement p;
        p.layout = std::string{layout};
        p.zone   = zone;
        return p;
    }

    std::vector<Rect> framesOf(std::string_view layoutId, const Area& area) {
        std::vector<Rect> out;
        for (const auto& z : layoutById(layoutId)->zones)
            out.push_back(zoneFrame(z, area));
        return out;
    }
}

TEST(TilingOutputs, AMovedWindowBelongsToTheOutputUnderItsMiddle) {
    // WAYLAND-1 (1440 wide) left of GF-REF (1920 wide), as in the nested session.
    const std::array<Rect, 2> outputs{Rect{0, 0, 1440, 900}, Rect{1440, 0, 1920, 1080}};
    EXPECT_EQ(outputUnder(Rect{1300, 100, 800, 500}, outputs), 1U) << "its middle (1700) is on GF-REF, its top-left is not";
    EXPECT_EQ(outputUnder(Rect{900, 100, 800, 500}, outputs), 0U) << "its middle (1300) is on WAYLAND-1";
    EXPECT_EQ(outputUnder(Rect{1040, 100, 800, 500}, outputs), 1U) << "a middle on the shared edge belongs to the right-hand output";
    EXPECT_FALSE(outputUnder(Rect{300, 900, 800, 400}, outputs).has_value()) << "its middle is below WAYLAND-1: it keeps its Desktop";
    EXPECT_FALSE(outputUnder(Rect{0, 0, 10, 10}, std::span<const Rect>{}).has_value());
}

TEST(TilingOutputs, AnUnmappedWindowIsNeverMoved) {
    // Gate C1: a window that closed or unmapped during a titlebar drag is still alive (its fade-out, or an app that only
    // unmapped it) but has no Desktop and its target no space: the plugin moves nothing (Hyprland would dereference null).
    const WindowFacts live{.mapped = true, .onDesktop = true, .inSpace = true, .floating = true};
    EXPECT_TRUE(movable(live));
    EXPECT_FALSE(movable(WindowFacts{.mapped = false, .onDesktop = true, .inSpace = true, .floating = true}));
    EXPECT_FALSE(movable(WindowFacts{.mapped = true, .onDesktop = false, .inSpace = true, .floating = true})) << "unmapping cleared its Desktop";
    EXPECT_FALSE(movable(WindowFacts{.mapped = true, .onDesktop = true, .inSpace = false, .floating = true})) << "its target left the space";
    EXPECT_TRUE(shouldFollow(live, 1, false));
    EXPECT_FALSE(shouldFollow(live, 1, true)) << "already on that Desktop";
    EXPECT_FALSE(shouldFollow(live, std::nullopt, false)) << "over no output: it keeps its Desktop";
    EXPECT_FALSE(shouldFollow(WindowFacts{.mapped = true, .onDesktop = true, .inSpace = true, .floating = false}, 1, false)) << "tiled by Hyprland's layout";
    EXPECT_FALSE(shouldFollow(WindowFacts{.mapped = false, .onDesktop = false, .inSpace = false, .floating = true}, 1, false)) << "closed during the drag";
}

TEST(TilingGrid, TheStepIsWholeInLogicalAndDevicePixels) {
    EXPECT_EQ(gridStep(1.0), 1);
    EXPECT_EQ(gridStep(2.0), 1);
    EXPECT_EQ(gridStep(1.5), 2);
    EXPECT_EQ(gridStep(2.5), 2);
    EXPECT_EQ(gridStep(160.0 / 120.0), 3);
    EXPECT_EQ(gridStep(1.25), 4);
    EXPECT_EQ(gridStep(1.75), 4);
    EXPECT_EQ(gridStep(1.2), 1) << "step 5: above kMaxGridStep, whole logical px only";
    EXPECT_EQ(gridStep(1.6), 1);
    EXPECT_EQ(gridStep(1.125), 1);
    EXPECT_EQ(gridStep(0.0), 1);
    EXPECT_EQ(gridStep(std::numeric_limits<double>::quiet_NaN()), 1);
    for (double scale : {1.0, 1.25, 160.0 / 120.0, 1.5, 1.75, 2.0}) {
        const int g = gridStep(scale);
        EXPECT_TRUE(whole(g * scale)) << scale;
    }
}

TEST(TilingGrid, NeighboursShareOneEdgeOnWholePixelsAtEveryScale) {
    // Hyprland truncates an xdg window's configured size to whole logical px (Window.cpp:1752-1753): every edge is whole,
    // so no slit opens between neighbours; where the scale has a grid, the edges are whole device px too.
    for (double scale : {1.0, 1.25, 160.0 / 120.0, 1.5, 1.6, 2.0}) {
        const Area a = areaFor(2560, 1440, scale, 0);
        for (std::string_view id : {"left-right", "thirds", "wide-center", "four-columns", "quarters", "stacked-thirds", "wide-left"}) {
            const auto frames = framesOf(id, a);
            for (const auto& f : frames) {
                EXPECT_TRUE(whole(f.x) && whole(f.y) && whole(f.w) && whole(f.h)) << id << " at " << scale;
                if (a.grid.step > 1) {
                    for (double e : {f.x, f.x + f.w}) {
                        if (std::abs(e - a.box.x) > 0.5 && std::abs(e - (a.box.x + a.box.w)) > 0.5) {
                            EXPECT_TRUE(whole(e * scale)) << id << " edge " << e << " at " << scale;
                        }
                    }
                }
            }
            // Without margins the zones meet exactly: the sum of a row's widths is the snapped span.
            for (size_t i = 0; i < frames.size(); ++i) {
                for (size_t j = 0; j < frames.size(); ++j) {
                    const auto& zi = layoutById(id)->zones[i];
                    const auto& zj = layoutById(id)->zones[j];
                    if (zi.x + zi.w == zj.x && zi.y < zj.y + zj.h && zj.y < zi.y + zi.h) {
                        EXPECT_DOUBLE_EQ(frames[i].x + frames[i].w, frames[j].x) << id << " at " << scale;
                    }
                    if (zi.y + zi.h == zj.y && zi.x < zj.x + zj.w && zj.x < zi.x + zi.w) {
                        EXPECT_DOUBLE_EQ(frames[i].y + frames[i].h, frames[j].y) << id << " at " << scale;
                    }
                }
            }
        }
    }
}

TEST(TilingGrid, MarginsAreExactWhenTheStepDividesThem) {
    for (double scale : {1.0, 1.25, 1.5, 2.0}) {
        const Area a      = areaFor(2560, 1440, scale, 8);
        const auto frames = framesOf("thirds", a);
        EXPECT_DOUBLE_EQ(frames[1].x - (frames[0].x + frames[0].w), 8) << scale;
        EXPECT_DOUBLE_EQ(frames[2].x - (frames[1].x + frames[1].w), 8) << scale;
        EXPECT_GE(frames[0].x - a.box.x, 8) << "outer margin " << scale;
        EXPECT_LT(frames[0].x - a.box.x, 8 + a.grid.step) << scale;
        EXPECT_GE(a.box.y + a.box.h - (frames[0].y + frames[0].h), 8) << scale;
        EXPECT_LT(a.box.y + a.box.h - (frames[0].y + frames[0].h), 8 + a.grid.step) << "the Dock ends off the grid at " << scale;
    }
    const Area third = areaFor(2560, 1440, 160.0 / 120.0, 8);
    const auto f     = framesOf("left-right", third);
    const double gap = f[1].x - (f[0].x + f[0].w);
    EXPECT_GE(gap, 8 - 3) << "within one step of the margin at step 3";
    EXPECT_LE(gap, 8 + 3);
}

TEST(TilingFit, AMinimumTakesRoomFromItsNeighbourAsFarAsItsMinimumAllows) {
    const Area a{Rect{0, 0, 1920, 1000}, 0, Grid{0, 0, 1}};
    const auto& zones  = layoutById("left-right")->zones;
    const auto  frames = framesOf("left-right", a);
    // The first window needs 1200: its neighbour (minimum 300) gives 240 and the shared edge moves for both.
    std::vector<Constraints> cons{Constraints{.minW = 1200}, Constraints{.minW = 300}};
    auto fit = fitFrames(zones, frames, cons, a);
    EXPECT_DOUBLE_EQ(fit[0].w, 1200);
    EXPECT_DOUBLE_EQ(fit[1].x, 1200);
    EXPECT_DOUBLE_EQ(fit[1].w, 720);
    // The neighbour can give only 60: the first window grows alone over it, from its edge on the border.
    cons[1].minW = 900;
    fit          = fitFrames(zones, frames, cons, a);
    EXPECT_DOUBLE_EQ(fit[1].x, 1020);
    EXPECT_DOUBLE_EQ(fit[1].w, 900);
    EXPECT_DOUBLE_EQ(fit[0].x, 0);
    EXPECT_DOUBLE_EQ(fit[0].w, 1200) << "it overlaps its neighbour";
    // A right-hand window that must grow alone grows leftwards and stays inside the work area.
    std::vector<Constraints> right{Constraints{.minW = 900}, Constraints{.minW = 1500}};
    fit = fitFrames(zones, frames, right, a);
    EXPECT_DOUBLE_EQ(fit[1].x + fit[1].w, 1920);
    EXPECT_DOUBLE_EQ(fit[1].w, 1500);
    // A minimum larger than the work area: the window starts at the work area's edge.
    const std::array<Zone, 1> fill{Zone{0, 0, 12, 12}};
    const std::array<Rect, 1> fillFrame{zoneFrame(fill[0], a)};
    const std::array<Constraints, 1> huge{Constraints{.minW = 2500, .minH = 400}};
    const auto big = fitFrames(fill, fillFrame, huge, a);
    EXPECT_DOUBLE_EQ(big[0].x, 0);
    EXPECT_DOUBLE_EQ(big[0].w, 2500);
}

TEST(TilingGrid, OuterEdgesSnapInsideTheWorkArea) {
    // A work area that starts and ends off the grid (step 4 from the output's origin): the outer edges go inside it.
    const Area a{Rect{1, 25, 1917, 973}, 0, Grid{0, 0, 4}};
    EXPECT_EQ(zoneFrame(Zone{}, a), (Rect{4, 28, 1912, 968}));
    const Area m{Rect{1, 25, 1917, 973}, 6, Grid{0, 0, 4}};
    EXPECT_EQ(zoneFrame(Zone{}, m), (Rect{8, 32, 1904, 960})) << "the margin first, then the grid line inside";
}

TEST(TilingGrid, InnerEdgesGoToTheNearestLine) {
    // Thirds of 1000 px: the boundaries 333.3 and 666.7 go to 333 and 667 (nearest, not down).
    const Area a{Rect{0, 0, 1000, 1000}, 0, Grid{0, 0, 1}};
    const auto thirds = framesOf("thirds", a);
    EXPECT_DOUBLE_EQ(thirds[1].x, 333);
    EXPECT_DOUBLE_EQ(thirds[2].x, 667);
    EXPECT_DOUBLE_EQ(thirds[0].w, 333);
    EXPECT_DOUBLE_EQ(thirds[2].w, 333);
}

TEST(TilingFit, ARightWindowTakesRoomFromItsLeftNeighbour) {
    // Left & Right, the right window needs 1200: the left one gives 240 across their shared edge (no overlap).
    const Area a{Rect{0, 0, 1920, 1000}, 0, Grid{0, 0, 1}};
    const auto& zones = layoutById("left-right")->zones;
    const std::vector<Constraints> cons{Constraints{}, Constraints{.minW = 1200}};
    const auto fit = fitFrames(zones, framesOf("left-right", a), cons, a);
    EXPECT_DOUBLE_EQ(fit[0].x, 0);
    EXPECT_DOUBLE_EQ(fit[0].w, 720);
    EXPECT_DOUBLE_EQ(fit[1].x, 720);
    EXPECT_DOUBLE_EQ(fit[1].w, 1200);
}

TEST(TilingFit, AWindowGrowingAloneStaysInsideTheWorkArea) {
    const Area a{Rect{0, 0, 1920, 1000}, 0, Grid{0, 0, 1}};
    // The middle third alone (no neighbour placed) needs 1800: it grows to the right, then moves back inside.
    const std::array<Zone, 1> middle{Zone{4, 0, 4, 12}};
    const std::array<Rect, 1> middleFrame{zoneFrame(middle[0], a)};
    const std::array<Constraints, 1> wide{Constraints{.minW = 1800}};
    const auto m = fitFrames(middle, middleFrame, wide, a);
    EXPECT_DOUBLE_EQ(m[0].x, 120);
    EXPECT_DOUBLE_EQ(m[0].x + m[0].w, 1920);
    // The right third alone with a minimum larger than the work area: aligned to its start.
    const std::array<Zone, 1> right{Zone{8, 0, 4, 12}};
    const std::array<Rect, 1> rightFrame{zoneFrame(right[0], a)};
    const std::array<Constraints, 1> huge{Constraints{.minW = 2000}};
    const auto r = fitFrames(right, rightFrame, huge, a);
    EXPECT_DOUBLE_EQ(r[0].x, 0);
    EXPECT_DOUBLE_EQ(r[0].w, 2000);
    // With margins: a right window that must grow alone keeps its margin to the work area's right edge.
    const Area margins{Rect{0, 0, 1920, 1000}, 8, Grid{0, 0, 1}};
    const auto& zones = layoutById("left-right")->zones;
    const std::vector<Constraints> cons{Constraints{.minW = 900}, Constraints{.minW = 1500}};
    const auto fit = fitFrames(zones, framesOf("left-right", margins), cons, margins);
    EXPECT_DOUBLE_EQ(fit[1].w, 1500);
    EXPECT_DOUBLE_EQ(fit[1].x + fit[1].w, 1912) << "the margin stays";
}

TEST(TilingFit, TheOtherQuarterFollowsTheSharedEdge) {
    // Left & Quarters, the top-right window needs 1200: the left half gives 240 and the bottom-right quarter follows the
    // shared edge, so no hole opens beside it (review of 3831dc0).
    const Area a{Rect{0, 0, 1920, 1000}, 0, Grid{0, 0, 1}};
    const auto& zones = layoutById("left-quarters")->zones;
    const std::vector<Constraints> cons{Constraints{}, Constraints{.minW = 1200}, Constraints{}};
    const auto fit = fitFrames(zones, framesOf("left-quarters", a), cons, a);
    EXPECT_DOUBLE_EQ(fit[0].w, 720);
    EXPECT_DOUBLE_EQ(fit[1].x, 720);
    EXPECT_DOUBLE_EQ(fit[1].w, 1200);
    EXPECT_DOUBLE_EQ(fit[2].x, 720) << "no hole between the left half and the bottom-right quarter";
    EXPECT_DOUBLE_EQ(fit[2].w, 1200);
    // Quarters: the top-left window's need moves only the top row's shared edge; the bottom row keeps its own.
    const auto& quarters = layoutById("quarters")->zones;
    const std::vector<Constraints> topLeft{Constraints{.minW = 1200}, Constraints{}, Constraints{}, Constraints{}};
    const auto q = fitFrames(quarters, framesOf("quarters", a), topLeft, a);
    EXPECT_DOUBLE_EQ(q[1].x, 1200);
    EXPECT_DOUBLE_EQ(q[2].w, 960);
    EXPECT_DOUBLE_EQ(q[3].x, 960);
}

TEST(TilingFit, AMaximumIsCentredOnTheGrid) {
    const Area a{Rect{0, 0, 1920, 1000}, 0, Grid{0, 0, 2}};
    const auto& zones = layoutById("left-right")->zones;
    const std::vector<Constraints> cons{Constraints{.maxW = 901}, Constraints{}};
    const auto fit = fitFrames(zones, framesOf("left-right", a), cons, a);
    EXPECT_DOUBLE_EQ(fit[0].w, 901);
    EXPECT_DOUBLE_EQ(fit[0].x, 28) << "29.5 px to centre it, 28 on the grid";
}

TEST(TilingFit, MaximaCentreAndIncrementsRoundDown) {
    const Area a{Rect{0, 0, 1920, 1000}, 0, Grid{0, 0, 1}};
    const auto& zones  = layoutById("left-right")->zones;
    const auto  frames = framesOf("left-right", a);
    std::vector<Constraints> cons{Constraints{.maxW = 500, .maxH = 300, .band = 32}, Constraints{.incW = 10, .incH = 7, .baseW = 2, .baseH = 1, .band = 0}};
    const auto fit = fitFrames(zones, frames, cons, a);
    EXPECT_DOUBLE_EQ(fit[0].w, 500);
    EXPECT_DOUBLE_EQ(fit[0].x, 230) << "centred in its 960-px zone";
    EXPECT_DOUBLE_EQ(fit[0].h, 332) << "the band is added to the surface maximum";
    EXPECT_DOUBLE_EQ(fit[1].x, 960) << "top-left kept";
    EXPECT_DOUBLE_EQ(fit[1].w, 952) << "2 + 95 x 10";
    EXPECT_DOUBLE_EQ(fit[1].h, 995) << "1 + 142 x 7";
}

TEST(TilingNeighbour, AHalfBesideATiledWindowTakesTheRest) {
    const Area a{Rect{0, 24, 1920, 974}, 8, Grid{0, 0, 1}};
    // A window holding the right two thirds (full height): Left takes the rest, one margin before it.
    const Rect twoThirds = zoneFrame(zoneOf(Place::RightTwoThirds).value_or(Zone{}), a);
    const std::array<Rect, 1> neighbours{twoThirds};
    const auto left = halfBesideNeighbour(Place::Left, a, neighbours);
    ASSERT_TRUE(left.has_value());
    const Rect l = left.value_or(Rect{});
    EXPECT_DOUBLE_EQ(l.x, 8);
    EXPECT_DOUBLE_EQ(l.x + l.w + 8, twoThirds.x);
    EXPECT_DOUBLE_EQ(l.h, twoThirds.h);
    // Not full height, or leaving less than a quarter: an exact half.
    const std::array<Rect, 1> quarter{zoneFrame(zoneOf(Place::TopRight).value_or(Zone{}), a)};
    EXPECT_FALSE(halfBesideNeighbour(Place::Left, a, quarter).has_value());
    const std::array<Rect, 1> fill{zoneFrame(zoneOf(Place::Fill).value_or(Zone{}), a)};
    EXPECT_FALSE(halfBesideNeighbour(Place::Left, a, fill).has_value());
    const std::array<Rect, 1> wide{Rect{300, 32, 1612, 958}};
    EXPECT_FALSE(halfBesideNeighbour(Place::Left, a, wide).has_value()) << "it leaves less than a quarter: an exact half";
    // The other sides.
    const std::array<Rect, 1> leftThird{zoneFrame(zoneOf(Place::LeftThird).value_or(Zone{}), a)};
    const auto right = halfBesideNeighbour(Place::Right, a, leftThird);
    ASSERT_TRUE(right.has_value());
    EXPECT_DOUBLE_EQ(right.value_or(Rect{}).x, leftThird[0].x + leftThird[0].w + 8);
    const std::array<Rect, 1> bottom{zoneFrame(zoneOf(Place::Bottom).value_or(Zone{}), a)};
    const auto top = halfBesideNeighbour(Place::Top, a, bottom);
    ASSERT_TRUE(top.has_value());
    const Rect t = top.value_or(Rect{});
    EXPECT_DOUBLE_EQ(t.y + t.h + 8, bottom[0].y);
    EXPECT_FALSE(halfBesideNeighbour(Place::Fill, a, bottom).has_value()) << "halves only";
}

TEST(TilingNeighbour, TheNearestNeighbourWins) {
    const Area a{Rect{0, 24, 1920, 974}, 8, Grid{0, 0, 1}};
    // Two windows hold the right side, the nearer one first: Left stops one margin before the nearer one.
    const std::array<Rect, 2> right{Rect{1100, 32, 812, 958}, Rect{1300, 32, 612, 958}};
    const auto left = halfBesideNeighbour(Place::Left, a, right);
    ASSERT_TRUE(left.has_value());
    EXPECT_DOUBLE_EQ(left.value_or(Rect{}).x + left.value_or(Rect{}).w, 1092);
    const std::array<Rect, 2> leftSide{Rect{8, 32, 800, 958}, Rect{8, 32, 600, 958}};
    const auto rightHalf = halfBesideNeighbour(Place::Right, a, leftSide);
    ASSERT_TRUE(rightHalf.has_value());
    EXPECT_DOUBLE_EQ(rightHalf.value_or(Rect{}).x, 816);
    const std::array<Rect, 2> below{Rect{8, 600, 1904, 390}, Rect{8, 700, 1904, 290}};
    const auto top = halfBesideNeighbour(Place::Top, a, below);
    ASSERT_TRUE(top.has_value());
    EXPECT_DOUBLE_EQ(top.value_or(Rect{}).y + top.value_or(Rect{}).h, 592);
    const std::array<Rect, 2> above{Rect{8, 32, 1904, 400}, Rect{8, 32, 1904, 300}};
    const auto bottom = halfBesideNeighbour(Place::Bottom, a, above);
    ASSERT_TRUE(bottom.has_value());
    EXPECT_DOUBLE_EQ(bottom.value_or(Rect{}).y, 440);
}

TEST(TilingCenter, KeepsTheSizeOnTheGrid) {
    const Area a{Rect{0, 24, 2048, 1046}, 8, Grid{0, 0, 4}};
    const auto c = centerFrame(Rect{100, 100, 801, 500}, 32, a);
    EXPECT_DOUBLE_EQ(c.w, 801);
    EXPECT_DOUBLE_EQ(c.h, 532);
    EXPECT_EQ(static_cast<long>(c.x) % 4, 0);
    EXPECT_EQ(static_cast<long>(c.y) % 4, 0);
}

TEST(TilingCatalogue, ClassesNameLayoutsThatTileTheWholeArea) {
    EXPECT_EQ(classify(1920, 1080), OutputClass::Large);
    EXPECT_EQ(classify(1366, 768), OutputClass::Small);
    EXPECT_EQ(classify(1728, 1117), OutputClass::Small);
    EXPECT_EQ(classify(3440, 1440), OutputClass::UltraWide);
    EXPECT_EQ(classify(2560, 1080), OutputClass::UltraWide);
    EXPECT_EQ(classify(1080, 1920), OutputClass::Portrait);
    EXPECT_EQ(classify(0, 0), OutputClass::Small);
    // The ultra-wide boundary is the 21:9 aspect itself, whatever the width.
    EXPECT_EQ(classify(2520, 1080), OutputClass::UltraWide) << "exactly 21:9";
    EXPECT_EQ(classify(2510, 1080), OutputClass::Large) << "just under 21:9";
    EXPECT_EQ(classify(1800, 760), OutputClass::UltraWide) << "narrower than the large class, still 21:9";
    EXPECT_EQ(classify(1919, 1080), OutputClass::Small);
    EXPECT_EQ(classify(1000, 1000), OutputClass::Small) << "square is not portrait";
    for (OutputClass c : {OutputClass::Small, OutputClass::Large, OutputClass::UltraWide, OutputClass::Portrait}) {
        EXPECT_FALSE(layoutsFor(c).empty()) << nameOf(c);
        for (std::string_view id : layoutsFor(c))
            EXPECT_NE(layoutById(id), nullptr) << id;
    }
    for (const auto& l : catalogue()) {
        ASSERT_GE(l.zones.size(), 1U) << l.id;
        ASSERT_LE(l.zones.size(), kMaxZones) << l.id;
        int cells = 0;
        for (size_t i = 0; i < l.zones.size(); ++i) {
            const auto& z = l.zones[i];
            EXPECT_TRUE(z.x >= 0 && z.y >= 0 && z.w > 0 && z.h > 0 && z.x + z.w <= kZoneGrid && z.y + z.h <= kZoneGrid) << l.id;
            cells += z.w * z.h;
            for (size_t j = i + 1; j < l.zones.size(); ++j) {
                const auto& o = l.zones[j];
                EXPECT_FALSE(z.x < o.x + o.w && o.x < z.x + z.w && z.y < o.y + o.h && o.y < z.y + z.h) << l.id << " zones overlap";
            }
        }
        EXPECT_EQ(cells, kZoneGrid * kZoneGrid) << l.id << " leaves a hole";
    }
    EXPECT_EQ(layoutById("nope"), nullptr);
}

TEST(TilingNames, TheThirdsArePlaces) {
    for (const char* name : {"left-third", "middle-third", "right-third", "left-two-thirds", "right-two-thirds"}) {
        const auto p = parsePlace(name);
        ASSERT_TRUE(p.has_value()) << name;
        EXPECT_EQ(nameOf(p.value_or(Place::Center)), name);
        EXPECT_TRUE(zoneOf(p.value_or(Place::Center)).has_value());
    }
    EXPECT_EQ(zoneOf(Place::RightTwoThirds), (Zone{4, 0, 8, 12}));
    EXPECT_FALSE(zoneOf(Place::Center).has_value());
}

TEST(TilingRecord, TheStateMachineKeepsTheBoxFromBefore) {
    CTileBook book;
    const Rect before{100, 100, 800, 500}, half{0, 56, 960, 942}, quarter{0, 56, 960, 455};
    const auto g0 = book.generation();
    const auto& r = book.placed(1, before, half, 32, at(Place::Left), "A", 1, 0);
    EXPECT_EQ(r.state, TileState::Tiled);
    EXPECT_EQ(r.before, before);
    EXPECT_GT(book.generation(), g0);
    // A later tiling keeps the box from before the first.
    book.placed(1, half, quarter, 32, at(Place::TopLeft), "A", 1, 0);
    EXPECT_EQ(book.find(1)->before, before);
    EXPECT_TRUE(book.check(1, quarter));
    // A drag away: Moving with the box from before; a release elsewhere forgets it.
    EXPECT_EQ(book.beginMove(1), before);
    EXPECT_EQ(book.find(1)->state, TileState::Moving);
    EXPECT_TRUE(book.check(1, Rect{5, 5, 800, 500})) << "a moving window is not checked";
    book.endMove(1);
    EXPECT_EQ(book.find(1), nullptr);
    // A release in a zone after a move keeps the box from before.
    book.placed(2, before, half, 32, at(Place::Left), "A", 1, 0);
    book.beginMove(2);
    book.placed(2, Rect{300, 300, 800, 500}, quarter, 32, at(Place::TopLeft), "A", 1, 0);
    EXPECT_EQ(book.find(2)->before, before);
    EXPECT_EQ(book.find(2)->state, TileState::Tiled);
    // A user resize keeps the record and updates the box.
    EXPECT_TRUE(book.beginResize(2));
    EXPECT_TRUE(book.check(2, Rect{0, 0, 1, 1})) << "a resizing window is not checked";
    book.endResize(2, Rect{0, 56, 1000, 455});
    EXPECT_EQ(book.find(2)->state, TileState::Tiled);
    EXPECT_EQ(book.find(2)->before, before);
    EXPECT_TRUE(book.check(2, Rect{0.5, 56, 1000, 455})) << "1 px slack";
    // Something else moved it: Free.
    EXPECT_FALSE(book.check(2, Rect{50, 56, 1000, 455}));
    EXPECT_EQ(book.find(2), nullptr);
    EXPECT_FALSE(book.check(99, before)) << "no record";
    // Suspended windows keep their record; Return to Previous Size gives the box from before and frees it.
    book.placed(3, before, half, 32, at(Place::Left), "A", 1, 0);
    EXPECT_TRUE(book.suspend(3));
    EXPECT_TRUE(book.check(3, Rect{-5000, 0, 10, 10}));
    EXPECT_FALSE(book.suspend(3));
    ASSERT_NE(book.resume(3), nullptr);
    EXPECT_EQ(book.resume(3), nullptr) << "not Suspended any more";
    EXPECT_EQ(book.takeBefore(3), before);
    EXPECT_EQ(book.find(3), nullptr);
    EXPECT_FALSE(book.beginMove(42).has_value());
}

TEST(TilingRecord, GroupsAndFreeZones) {
    CTileBook book;
    const auto group = book.newGroup();
    const Rect left{8, 64, 948, 926}, right{964, 64, 948, 926};
    book.placed(1, Rect{0, 0, 10, 10}, left, 32, inLayout("left-right", 0), "A", 1, group);
    book.placed(2, Rect{0, 0, 10, 10}, right, 32, inLayout("left-right", 1), "A", 1, group);
    EXPECT_EQ(book.find(1)->group, group);
    EXPECT_EQ(book.find(2)->group, group);
    // A resize keeps both in the group; a drag away dissolves a group of one.
    book.beginResize(1);
    book.endResize(1, Rect{8, 64, 900, 926});
    EXPECT_EQ(book.find(2)->group, group);
    book.beginMove(1);
    EXPECT_EQ(book.find(1)->group, 0U);
    EXPECT_EQ(book.find(2)->group, 0U) << "a group of one dissolves";
    // Free zones: only Tiled and Resizing windows of that output and Desktop count, with more than 1 px of overlap.
    const Rect rightFrame = frameOf(right, 32);
    EXPECT_FALSE(book.zoneFree(rightFrame, "A", 1, 0));
    EXPECT_TRUE(book.zoneFree(rightFrame, "A", 1, 2)) << "itself excepted";
    EXPECT_TRUE(book.zoneFree(rightFrame, "B", 1, 0));
    EXPECT_TRUE(book.zoneFree(rightFrame, "A", 2, 0));
    EXPECT_TRUE(book.zoneFree(Rect{rightFrame.x + rightFrame.w - 1, rightFrame.y, 100, 100}, "A", 1, 0)) << "1 px is not an overlap";
    const std::array<uint64_t, 1> inStrip{2};
    EXPECT_TRUE(book.zoneFree(rightFrame, "A", 1, 0, inStrip)) << "an inactive stage's window does not hold its zone";
    book.suspend(2);
    EXPECT_TRUE(book.zoneFree(rightFrame, "A", 1, 0)) << "a suspended window does not hold its zone";
    book.clear();
    EXPECT_TRUE(book.records().empty());
}

TEST(TilingRecord, MoveToDesktopAndALostOutput) {
    CTileBook book;
    const Rect before{100, 100, 800, 500}, half{8, 64, 948, 926};
    book.placed(1, before, half, 32, at(Place::Left), "A", 1, 0);
    // Move to Desktop: the state and the box stay, the zone now counts on the new Desktop.
    const auto g = book.generation();
    book.setWorkspace(1, 4);
    EXPECT_GT(book.generation(), g);
    EXPECT_EQ(book.find(1)->workspace, 4);
    EXPECT_EQ(book.find(1)->state, TileState::Tiled);
    EXPECT_FALSE(book.zoneFree(frameOf(half, 32), "A", 4, 0));
    EXPECT_TRUE(book.zoneFree(frameOf(half, 32), "A", 1, 0));
    // Its output went away and Hyprland moved it: not checked until it is placed again.
    book.markRelayout(1, true);
    EXPECT_TRUE(book.check(1, Rect{2000, 64, 948, 926}));
    book.setBox(1, Rect{1928, 64, 948, 926}, "B");
    EXPECT_FALSE(book.find(1)->relayout);
    EXPECT_EQ(book.find(1)->output, "B");
    EXPECT_FALSE(book.check(1, Rect{2000, 64, 948, 926})) << "checked again once placed";
}

TEST(TilingRecord, ADeferredRecordIsStillChecked) {
    // The margins changed while the window could not be placed (an inactive stage): it waits to be placed again, but a
    // window the user moved meanwhile is Free (its box is still the one the plugin gave it).
    CTileBook  book;
    const Rect half{8, 64, 948, 926};
    book.placed(1, Rect{100, 100, 800, 500}, half, 32, at(Place::Left), "A", 1, 0);
    book.markDeferred(1, true);
    EXPECT_TRUE(book.find(1)->deferred);
    EXPECT_TRUE(book.check(1, half));
    book.setBox(1, Rect{0, 56, 960, 942}, "A");
    EXPECT_FALSE(book.find(1)->deferred) << "placed again";
    book.markDeferred(1, true);
    book.placed(1, half, half, 32, at(Place::Left), "A", 1, 0);
    EXPECT_FALSE(book.find(1)->deferred) << "tiled again";
    book.markDeferred(1, true);
    EXPECT_FALSE(book.check(1, Rect{300, 300, 948, 926})) << "moved by the user meanwhile: Free";
    EXPECT_EQ(book.find(1), nullptr);
}

TEST(TilingRecord, ASuspendedMemberKeepsItsGroupAlive) {
    CTileBook  book;
    const auto group = book.newGroup();
    const Rect any{0, 0, 10, 10};
    book.placed(1, any, any, 0, inLayout("thirds", 0), "A", 1, group);
    book.placed(2, any, any, 0, inLayout("thirds", 1), "A", 1, group);
    book.placed(3, any, any, 0, inLayout("thirds", 2), "A", 1, group);
    book.suspend(3);
    book.beginMove(1);
    EXPECT_EQ(book.find(2)->group, group) << "one Tiled and one Suspended member: the group lives";
    EXPECT_EQ(book.find(3)->group, group);
    book.forget(2);
    EXPECT_EQ(book.find(3)->group, 0U) << "a Suspended member alone: dissolved";
}

TEST(TilingArrange, TheSizeLimitIsExact) {
    const std::string body = R"("layout":"quarters","windows":["1"]})";
    const auto padded = [&body](size_t total) { return "{" + std::string(total - 1 - body.size(), ' ') + body; };
    ASSERT_EQ(padded(kMaxArrangeBytes).size(), kMaxArrangeBytes);
    EXPECT_TRUE(parseArrange(padded(kMaxArrangeBytes)).has_value());
    EXPECT_FALSE(parseArrange(padded(kMaxArrangeBytes + 1)).has_value());
}

TEST(TilingArrange, RequestsAreStrict) {
    const auto ok = parseArrange(R"({"layout":"left-quarters","windows":["0x1a2b","3c"],"output":"GF-REF"})");
    ASSERT_TRUE(ok.has_value()) << ok.error();
    EXPECT_EQ(ok->layout, "left-quarters");
    EXPECT_EQ(ok->windows, (std::vector<uint64_t>{0x1a2b, 0x3c}));
    EXPECT_TRUE(ok->fill);
    EXPECT_EQ(ok->output, "GF-REF");
    const auto zone = parseArrange(R"({"layout":"thirds","zone":2,"windows":["0x9"]})");
    ASSERT_TRUE(zone.has_value()) << zone.error();
    EXPECT_EQ(zone->zone, 2);
    EXPECT_FALSE(zone->fill);
    const auto noFill = parseArrange(R"({ "layout" : "quarters", "windows" : ["1"], "fill" : false, "unknown": {"a":[1]} })");
    ASSERT_TRUE(noFill.has_value()) << noFill.error();
    EXPECT_FALSE(noFill->fill);
    for (const char* bad : {
             "", "[]", "{}", R"({"layout":"nope","windows":["1"]})", R"({"layout":"left-right"})", R"({"layout":"left-right","windows":[]})",
             R"({"layout":"left-right","windows":["1","2","3"]})", R"({"layout":"quarters","windows":["1","1"]})", R"({"layout":"quarters","windows":["0"]})",
             R"({"layout":"quarters","windows":["xyz"]})", R"({"layout":"quarters","windows":["1","2","3","4","5"]})", R"({"layout":"thirds","zone":3,"windows":["1"]})",
             R"({"layout":"thirds","zone":1,"windows":["1","2"]})", R"({"layout":"thirds","zone":1,"fill":true,"windows":["1"]})", R"({"layout":"thirds","zone":1.5,"windows":["1"]})",
             R"({"layout":"thirds","zone":-1,"windows":["1"]})", R"({"layout":"thirds","windows":["1"],"output":"bad name"})", R"({"layout":"thirds","windows":["1"],"output":""})",
             R"({"layout":"thirds","windows":["1"]} x)", R"({"layout":"thirds","layout":"thirds","windows":["1"]})", R"({"layout":"thirds","windows":["1"],"fill":1})"}) {
        EXPECT_FALSE(parseArrange(bad).has_value()) << bad;
    }
    EXPECT_FALSE(parseArrange(std::string(kMaxArrangeBytes + 1, ' ')).has_value());
}

TEST(TilingJson, TheNoticeIsSmallAndTheStateIsAReply) {
    EXPECT_EQ(noticeJson(7, Reason::Placed), R"({"v":"gfc/1","type":"tiling","gen":7,"reason":"placed"})");
    EXPECT_EQ(noticeJson(0, Reason::None), R"({"v":"gfc/1","type":"tiling","gen":0})");
    CTileBook book;
    book.placed(0xabc, Rect{1, 2, 3, 4}, Rect{8, 64, 948, 926}, 32, at(Place::Left), "GF-REF", 2, 0);
    book.placed(0xdef, Rect{1, 2, 3, 4}, Rect{964, 64, 948, 926}, 0, inLayout("left-right", 1), "GF-REF", 2, 0);
    StateOutput o{.name = "GF-REF", .area = Rect{0, 24, 1920, 974}, .outputClass = OutputClass::Large, .grid = 1, .windows = {}};
    for (const auto& r : book.records())
        o.windows.push_back(&r);
    const std::array<StateOutput, 1> outputs{o};
    EXPECT_EQ(stateJson(3, outputs),
              R"({"v":"gfc/1","type":"tiling","gen":3,"outputs":[{"name":"GF-REF","area":{"x":0,"y":24,"w":1920,"h":974},"class":"large","grid":1,"windows":[)"
              R"({"address":"abc","state":"tiled","place":"left","layout":"","zone":-1,"sides":"","group":0,"x":8,"y":64,"w":948,"h":926},)"
              R"({"address":"def","state":"tiled","place":"","layout":"left-right","zone":1,"sides":"","group":0,"x":964,"y":64,"w":948,"h":926}]}],"splits":[],"unfit":[],"fixed":[],"unfitZones":[],"suggestion":null})");
    Placement edge;
    edge.sides = kSideTop | kSideLeft;
    CTileBook edges;
    edges.placed(0x1, Rect{1, 2, 3, 4}, Rect{8, 64, 400, 300}, 32, edge, "GF-REF", 2, 0);
    StateOutput e{.name = "GF-REF", .area = Rect{0, 24, 1920, 974}, .outputClass = OutputClass::Large, .grid = 1, .windows = {&edges.records().front()}};
    EXPECT_NE(stateJson(4, std::array<StateOutput, 1>{e}).find(R"("place":"","layout":"","zone":-1,"sides":"top-left","group":0)"), std::string::npos)
        << "an edge double-click's record names its sides";
    for (Reason r : {Reason::Placed, Reason::Moved, Reason::Resized, Reason::Suspended, Reason::Restored, Reason::Forgotten, Reason::Relaid, Reason::Invalid,
                     Reason::Locked, Reason::Unavailable})
        EXPECT_FALSE(reasonName(r).empty());
    EXPECT_EQ(noticeJson(9, Reason::Locked), R"({"v":"gfc/1","type":"tiling","gen":9,"reason":"locked"})");
    EXPECT_EQ(noticeJson(std::numeric_limits<uint64_t>::max(), Reason::Unavailable).size(), 79U) << "the bound ADR-0007 states";
}

// ---- step 2: drags (TL17, TL18, TL20) ----

TEST(TilingAltDrag, ThirdsOfTheWorkAreaGiveTheNearestTile) {
    // kArea: thirds at x 2080 and 2720, y 348.7 and 673.3; the middle at x 2400.
    EXPECT_EQ(placeForAltPointer(1500, 100, kArea), Place::TopLeft);
    EXPECT_EQ(placeForAltPointer(2400, 100, kArea), Place::Fill);
    EXPECT_EQ(placeForAltPointer(3300, 100, kArea), Place::TopRight);
    EXPECT_EQ(placeForAltPointer(1500, 500, kArea), Place::Left);
    EXPECT_EQ(placeForAltPointer(3300, 500, kArea), Place::Right);
    EXPECT_EQ(placeForAltPointer(2399, 500, kArea), Place::Left) << "the centre: the half on the pointer's side";
    EXPECT_EQ(placeForAltPointer(2400, 500, kArea), Place::Right);
    EXPECT_EQ(placeForAltPointer(1500, 900, kArea), Place::BottomLeft);
    EXPECT_EQ(placeForAltPointer(3300, 900, kArea), Place::BottomRight);
    EXPECT_EQ(placeForAltPointer(2399, 900, kArea), Place::Left) << "bottom middle: the half on the pointer's side";
    EXPECT_EQ(placeForAltPointer(2400, 900, kArea), Place::Right);
    EXPECT_EQ(placeForAltPointer(2079, 300, kArea), Place::TopLeft);
    EXPECT_EQ(placeForAltPointer(2080, 300, kArea), Place::Fill) << "the cell boundary belongs to the next cell";
    EXPECT_EQ(placeForAltPointer(2400, 348, kArea), Place::Fill);
    EXPECT_EQ(placeForAltPointer(2400, 349, kArea), Place::Right);
    EXPECT_EQ(placeForAltPointer(2400, 5, kArea), Place::Fill) << "on the menu bar, above the area: the top row";
    EXPECT_EQ(placeForAltPointer(1500, 1050, kArea), Place::BottomLeft) << "over the Dock, below the area: the bottom row";
}

TEST(TilingAltDrag, AltWinsOverTheEdgeSettingsAndNeedsItsOwnSetting) {
    EXPECT_EQ(dragPlace(2400, 500, kOutput, kArea, DragOptions{}, true), Place::Right);
    EXPECT_FALSE(dragPlace(2400, 500, kOutput, kArea, DragOptions{}, false).has_value()) << "without Alt: the edges only";
    EXPECT_EQ(dragPlace(3359, 540, kOutput, kArea, DragOptions{}, false), Place::Right);
    EXPECT_EQ(dragPlace(1500, 900, kOutput, kArea, DragOptions{false, false, true}, true), Place::BottomLeft) << "edges and menu bar off";
    EXPECT_FALSE(dragPlace(2400, 500, kOutput, kArea, DragOptions{true, true, false}, true).has_value()) << "the Alt drag setting off";
    EXPECT_EQ(dragPlace(3359, 540, kOutput, kArea, DragOptions{true, true, false}, true), Place::Right) << "then Alt changes nothing";
    EXPECT_FALSE(dragPlace(1439, 500, kOutput, kArea, DragOptions{}, true).has_value()) << "off the output";
    EXPECT_FALSE(dragPlace(2400, 500, kOutput, Rect{}, DragOptions{}, true).has_value()) << "no work area: the edges only";
}

TEST(TilingDwell, ThePreviewWaitsForTheDelayOnOnePlace) {
    ASSERT_GT(kPreviewDelay, 1U);
    CDwell d;
    EXPECT_FALSE(d.remaining(0).has_value()) << "no place";
    EXPECT_FALSE(d.update(Place::Left, "A", 1000, false));
    EXPECT_EQ(d.remaining(1000), kPreviewDelay);
    EXPECT_FALSE(d.update(Place::Left, "A", 1000 + kPreviewDelay - 1, false));
    EXPECT_EQ(d.remaining(1000 + kPreviewDelay - 1), 1U);
    EXPECT_FALSE(d.shown());
    EXPECT_TRUE(d.update(Place::Left, "A", 1000 + kPreviewDelay, false));
    EXPECT_TRUE(d.shown());
    EXPECT_FALSE(d.remaining(1000 + kPreviewDelay).has_value()) << "shown: nothing to wait for";
    EXPECT_TRUE(d.update(Place::Left, "A", 5000, false)) << "it stays shown while the pointer stays";
    EXPECT_FALSE(d.update(Place::Right, "A", 5001, false)) << "another place starts over";
    EXPECT_EQ(d.remaining(5001), kPreviewDelay);
    EXPECT_FALSE(d.update(Place::Right, "B", 5002 + kPreviewDelay, false)) << "the same place on another output starts over";
    EXPECT_EQ(d.remaining(5002 + kPreviewDelay), kPreviewDelay);
    EXPECT_FALSE(d.update(std::nullopt, "", 9000, true)) << "no place: hidden at once, even with Alt";
    EXPECT_FALSE(d.shown());
    EXPECT_FALSE(d.remaining(9000).has_value());
    EXPECT_FALSE(d.update(Place::Left, "A", 9001, false)) << "back on a place: the delay again";
    EXPECT_EQ(d.remaining(9010), kPreviewDelay - 9);
    EXPECT_EQ(d.remaining(9001 + 2 * kPreviewDelay), 0U) << "overdue: due now";
}

TEST(TilingDwell, AltShowsAtOnce) {
    CDwell d;
    EXPECT_TRUE(d.update(Place::Fill, "A", 100, true));
    EXPECT_FALSE(d.update(Place::Left, "A", 101, false));
    EXPECT_TRUE(d.update(Place::Left, "A", 102, true)) << "Alt pressed while waiting";
    EXPECT_TRUE(d.update(Place::Left, "A", 103, false)) << "released: still shown";
    d.reset();
    EXPECT_FALSE(d.shown());
    EXPECT_FALSE(d.remaining(104).has_value());
    EXPECT_FALSE(d.update(Place::Left, "A", 104, false)) << "after a reset, the same place waits again";
}

// Owner report on 1.0.0-rc6 ("the gesture up to fill the screen is very slow"): the menu bar is a target, the pointer pushed past
// the window held below it; it fills at once unless another output lies above (then the strip is crossed on the way there).
TEST(TilingDwell, TheMenuBarFillsAtOnceWhenNothingIsAbove) {
    EXPECT_TRUE(showsAtOnce(Place::Fill, true, false)) << "the menu bar, nothing above: at once";
    EXPECT_FALSE(showsAtOnce(Place::Fill, false, false)) << "an output above: the strip is a way there, the delay stays";
    EXPECT_FALSE(showsAtOnce(Place::Left, true, false)) << "the side edges keep the delay";
    EXPECT_FALSE(showsAtOnce(Place::TopLeft, true, false)) << "the corners too";
    EXPECT_FALSE(showsAtOnce(std::nullopt, true, false)) << "no place";
    EXPECT_TRUE(showsAtOnce(Place::Right, false, true)) << "Alt: any place at once (TL17)";
    CDwell d;
    EXPECT_TRUE(d.update(Place::Fill, "A", 100, showsAtOnce(Place::Fill, true, false))) << "shown as the pointer reaches the menu bar";
}

TEST(TilingSides, ABorderPressGripsTheSidesItIsBeyond) {
    const Rect s{2000, 300, 800, 500};
    EXPECT_EQ(sidesAt(1995, 500, s), kSideLeft);
    EXPECT_EQ(sidesAt(2805, 500, s), kSideRight);
    EXPECT_EQ(sidesAt(2800, 500, s), kSideRight) << "the box's right edge is outside it";
    EXPECT_EQ(sidesAt(2400, 295, s), kSideTop);
    EXPECT_EQ(sidesAt(2400, 805, s), kSideBottom);
    EXPECT_EQ(sidesAt(2400, 800, s), kSideBottom);
    EXPECT_EQ(sidesAt(1995, 295, s), kSideLeft | kSideTop);
    EXPECT_EQ(sidesAt(2805, 805, s), kSideRight | kSideBottom);
    EXPECT_EQ(sidesAt(2005, 305, s), kSideLeft | kSideTop) << "inside, in a rounded corner: its quadrant's corner";
    EXPECT_EQ(sidesAt(2795, 305, s), kSideRight | kSideTop);
    EXPECT_EQ(sidesAt(2005, 795, s), kSideLeft | kSideBottom);
    EXPECT_EQ(sidesAt(2795, 795, s), kSideRight | kSideBottom);
    EXPECT_EQ(sidesAt(2400, 550, s), kSideRight | kSideBottom) << "the middle belongs to the second halves";
}

TEST(TilingSides, AltAddsTheOppositeSides) {
    EXPECT_EQ(extendedSides(kSideLeft, false), kSideLeft);
    EXPECT_EQ(extendedSides(kSideLeft, true), kSideLeft | kSideRight);
    EXPECT_EQ(extendedSides(kSideRight, true), kSideLeft | kSideRight);
    EXPECT_EQ(extendedSides(kSideBottom, true), kSideTop | kSideBottom);
    EXPECT_EQ(extendedSides(kSideTop, true), kSideTop | kSideBottom);
    EXPECT_EQ(extendedSides(kSideTop | kSideLeft, false), kSideTop | kSideLeft);
    EXPECT_EQ(extendedSides(kSideTop | kSideLeft, true), kAllSides) << "Alt on a corner: the whole work area";
    EXPECT_EQ(extendedSides(0xF0, true), 0) << "only the four sides";
    EXPECT_EQ(sidesName(kSideTop | kSideLeft), "top-left");
    EXPECT_EQ(sidesName(kSideLeft | kSideRight), "left-right");
    EXPECT_EQ(sidesName(kSideBottom | kSideRight), "bottom-right");
    EXPECT_EQ(sidesName(kAllSides), "top-bottom-left-right");
    EXPECT_EQ(sidesName(0), "");
}

TEST(TilingExtend, EachSideGoesToTheWorkAreaEdgeInsideTheMargin) {
    const Area area{kArea, kMargin, Grid{1440, 0, 1}};
    const Rect full  = zoneFrame(Zone{}, area);
    ASSERT_EQ(full, (Rect{1448, 32, 1904, 958}));
    const Rect frame = frameOf(kWindow, kBar); // 2000, 268, 800 x 532
    const Constraints c{.band = kBar};
    EXPECT_EQ(extendFrame(frame, kSideLeft, c, area), (Rect{1448, 268, 1352, 532}));
    EXPECT_EQ(extendFrame(frame, kSideRight, c, area), (Rect{2000, 268, 1352, 532}));
    EXPECT_EQ(extendFrame(frame, kSideTop, c, area), (Rect{2000, 32, 800, 768})) << "the titlebar's top reaches the area";
    EXPECT_EQ(extendFrame(frame, kSideBottom, c, area), (Rect{2000, 268, 800, 722}));
    EXPECT_EQ(extendFrame(frame, kSideLeft | kSideRight, c, area), (Rect{1448, 268, 1904, 532}));
    EXPECT_EQ(extendFrame(frame, kSideTop | kSideLeft, c, area), (Rect{1448, 32, 1352, 768}));
    EXPECT_EQ(extendFrame(frame, kAllSides, c, area), full);
    EXPECT_EQ(extendFrame(frame, 0, c, area), frame);
    const Area bare{kArea, 0, Grid{1440, 0, 1}};
    EXPECT_EQ(extendFrame(frame, kSideLeft | kSideBottom, c, bare), (Rect{1440, 268, 1360, 730})) << "no margins: the area's own edges";
}

TEST(TilingExtend, LimitsKeepTheSideThatDidNotMove) {
    const Area area{kArea, kMargin, Grid{1440, 0, 1}};
    const Rect frame = frameOf(kWindow, kBar);
    const Constraints maxW{.maxW = 1000, .band = kBar};
    EXPECT_EQ(extendFrame(frame, kSideLeft, maxW, area), (Rect{1800, 268, 1000, 532})) << "the right side stays";
    EXPECT_EQ(extendFrame(frame, kSideRight, maxW, area), (Rect{2000, 268, 1000, 532}));
    EXPECT_EQ(extendFrame(frame, kSideLeft | kSideRight, maxW, area), (Rect{1900, 268, 1000, 532})) << "both moved: centred";
    const Constraints maxH{.maxH = 600, .band = kBar};
    EXPECT_EQ(extendFrame(frame, kSideTop, maxH, area), (Rect{2000, 168, 800, 632})) << "the maximum counts the surface only";
    const Constraints incW{.incW = 10, .baseW = 0, .band = kBar};
    EXPECT_EQ(extendFrame(frame, kSideLeft, incW, area), (Rect{1450, 268, 1350, 532})) << "increments round down, the right side stays";
    EXPECT_EQ(extendFrame(frame, kSideRight, incW, area), (Rect{2000, 268, 1350, 532}));
    EXPECT_EQ(extendFrame(frame, kSideLeft | kSideRight, incW, area), (Rect{1448, 268, 1900, 532})) << "both moved, no maximum: not centred";
    const Constraints incH{.incH = 20, .baseH = 4, .band = kBar};
    EXPECT_EQ(extendFrame(frame, kSideBottom, incH, area), (Rect{2000, 268, 800, 716})) << "4 + 34 x 20 = 684 of surface";
    const Rect narrow{1460, 268, 100, 532};
    const Constraints minW{.minW = 300, .band = kBar};
    EXPECT_EQ(extendFrame(narrow, kSideLeft, minW, area), (Rect{1260, 268, 300, 532})) << "never smaller than its minimum";
    const Area grid{kArea, 0, Grid{1440, 0, 4}};
    const Constraints odd{.maxW = 1001, .band = kBar};
    EXPECT_EQ(extendFrame(frame, kSideLeft | kSideRight, odd, grid), (Rect{1896, 268, 1001, 532})) << "the centring offset on the grid";
}

TEST(TilingRecord, AnEdgePlacementIsItsOwnPlacement) {
    Placement edge;
    edge.sides = kSideLeft;
    Placement other = edge;
    other.sides     = kSideRight;
    EXPECT_NE(edge, other);
    EXPECT_NE(edge, Placement{});
    CTileBook book;
    const auto& r = book.placed(7, Rect{2000, 300, 800, 500}, Rect{1448, 300, 1352, 500}, 32, edge, "GF-REF", 1, 0);
    EXPECT_EQ(r.where.sides, kSideLeft);
    EXPECT_EQ(r.before, (Rect{2000, 300, 800, 500})) << "Return to Previous Size has a box to go back to";
    EXPECT_EQ(book.takeBefore(7), (Rect{2000, 300, 800, 500}));
}

// ---- step 3: the hover on the zoom light (TL22) ----

TEST(TilingHover, TheZoomLightIsAHoverAfterTheDelay) {
    ASSERT_GT(kHoverDelay, 1U);
    CHoverDwell h;
    EXPECT_FALSE(h.remaining(0).has_value()) << "no light under the pointer";
    auto c = h.update(7, 1000);
    EXPECT_FALSE(c.enter.has_value());
    EXPECT_FALSE(c.leave.has_value());
    EXPECT_EQ(h.remaining(1000), kHoverDelay);
    EXPECT_FALSE(h.update(7, 1000 + kHoverDelay - 1).enter.has_value());
    EXPECT_EQ(h.remaining(1000 + kHoverDelay - 1), 1U);
    c = h.update(7, 1000 + kHoverDelay);
    EXPECT_EQ(c.enter, 7U);
    EXPECT_EQ(h.entered(), 7U);
    EXPECT_FALSE(h.remaining(1000 + kHoverDelay).has_value()) << "entered: nothing to wait for";
    EXPECT_FALSE(h.update(7, 9000).enter.has_value()) << "enter once";
    c = h.update(std::nullopt, 9001);
    EXPECT_EQ(c.leave, 7U) << "off the light: leave";
    EXPECT_FALSE(c.enter.has_value());
    EXPECT_FALSE(h.entered().has_value());
    EXPECT_FALSE(h.update(std::nullopt, 9002).leave.has_value()) << "leave once";
}

TEST(TilingHover, AnotherLightStartsOverAndLeavesTheFirst) {
    CHoverDwell h;
    h.update(1, 0);
    h.update(1, kHoverDelay);
    auto c = h.update(2, kHoverDelay + 5);
    EXPECT_EQ(c.leave, 1U);
    EXPECT_FALSE(c.enter.has_value()) << "the other light waits for its own delay";
    EXPECT_EQ(h.remaining(kHoverDelay + 5), kHoverDelay);
    c = h.update(2, 2 * kHoverDelay + 5);
    EXPECT_EQ(c.enter, 2U);
    h.update(3, 3 * kHoverDelay);
    EXPECT_FALSE(h.update(3, 3 * kHoverDelay + 1).leave.has_value()) << "a light never entered leaves nothing";
    EXPECT_EQ(h.remaining(4 * kHoverDelay + 7), 0U) << "overdue: due now";
    // Integrator review of 4ead6fb: a light the pointer leaves before the delay was never entered, so no leave is posted,
    // neither for another light nor for none.
    CHoverDwell early;
    early.update(8, 0);
    auto c2 = early.update(9, kHoverDelay - 1);
    EXPECT_FALSE(c2.leave.has_value()) << "another light before the delay: nothing to leave";
    EXPECT_FALSE(c2.enter.has_value());
    EXPECT_FALSE(early.update(std::nullopt, kHoverDelay).leave.has_value()) << "off every light before the delay: nothing to leave";
}

// TL22, TL34 (integrator review of 4ead6fb): nothing of the hover over the lock, under a foreign Exclusive layer or under a layer.
// D24 (integrator nested rerun of 25e757c): the lock and a foreign Exclusive layer take the desktop away (the hover starts over
// once it is back), a layer over the light holds it as a press.
TEST(TilingHover, CoveredLightsAreNoHover) {
    using enum HoverCoverEffect;
    EXPECT_EQ(hoverCoverEffect(HoverCover{}), None) << "nothing covers the lights";
    EXPECT_EQ(hoverCoverEffect(HoverCover{.locked = true, .exclusiveNamespaces = {}, .layerUnderPointer = false}), Away) << "the session is locked";
    EXPECT_EQ(hoverCoverEffect(HoverCover{.locked = false, .exclusiveNamespaces = {}, .layerUnderPointer = true}), Over) << "a layer is under the pointer";
    EXPECT_EQ(hoverCoverEffect(HoverCover{.locked = true, .exclusiveNamespaces = {}, .layerUnderPointer = true}), Away) << "the lock comes first";
    EXPECT_EQ(hoverCoverEffect(HoverCover{.locked = false, .exclusiveNamespaces = {"grassfield-polkit"}, .layerUnderPointer = false}), Away)
        << "the polkit sheet (any Exclusive layer but the shell's popups)";
    EXPECT_EQ(hoverCoverEffect(HoverCover{.locked = false, .exclusiveNamespaces = {"grassfield-search"}, .layerUnderPointer = true}), Away)
        << "a foreign Exclusive layer comes before a layer under the pointer";
    EXPECT_EQ(hoverCoverEffect(HoverCover{.locked = false, .exclusiveNamespaces = {std::string{kShellPopupNamespace}, "grassfield-search"}, .layerUnderPointer = false}),
              Away);
    EXPECT_EQ(hoverCoverEffect(HoverCover{.locked = false, .exclusiveNamespaces = {std::string{kShellPopupNamespace}}, .layerUnderPointer = false}), None)
        << "the shell's popup layer on another output: its own pointer test covers its output";
    EXPECT_EQ(hoverCoverEffect(HoverCover{.locked = false, .exclusiveNamespaces = {std::string{kShellPopupNamespace}}, .layerUnderPointer = true}), Over)
        << "the shell's open popover over the light holds it";
    EXPECT_EQ(hoverCoverEffect(HoverCover{.locked = false, .exclusiveNamespaces = {""}, .layerUnderPointer = false}), Away) << "a nameless Exclusive layer";
}

// D24: what the glue does with each effect (Titlebar.cpp updateZoomHover, and the unlock, which forgets the hover and looks
// again): Away is update with no light, Over is press.
TEST(TilingHover, TheHoverStartsOverAfterTheLock) {
    CHoverDwell h;
    h.update(5, 0);
    h.update(5, kHoverDelay);
    ASSERT_EQ(h.entered(), 5U) << "the popover is open";
    auto c = h.update(std::nullopt, kHoverDelay + 10); // the lock comes, the pointer resting on the light
    EXPECT_EQ(c.leave, 5U);
    EXPECT_FALSE(h.remaining(kHoverDelay + 10).has_value()) << "nothing to wait for while locked";
    c = h.update(5, 5000); // unlocked, the pointer still on that light: no new hover needed
    EXPECT_FALSE(c.enter.has_value()) << "the delay again";
    EXPECT_EQ(h.remaining(5000), kHoverDelay) << "the timer the glue arms";
    EXPECT_EQ(h.update(5, 5000 + kHoverDelay).enter, 5U) << "the hover is back";

    // A light held by a layer over it (Over, as a press), then the lock: the unlock gives that light a hover again.
    CHoverDwell held;
    held.update(6, 0);
    held.update(6, kHoverDelay);
    EXPECT_EQ(held.press().leave, 6U);
    EXPECT_FALSE(held.update(6, 3 * kHoverDelay).enter.has_value()) << "held while the pointer stays";
    EXPECT_FALSE(held.update(std::nullopt, 3 * kHoverDelay + 1).leave.has_value()) << "the lock: nothing entered to leave";
    held.update(6, 4 * kHoverDelay);
    EXPECT_EQ(held.update(6, 5 * kHoverDelay).enter, 6U) << "the lock ended the hold";

    // Over, by contrast, keeps the light waiting until the pointer leaves it (a popover closed over the light stays closed).
    CHoverDwell over;
    over.update(7, 0);
    over.update(7, kHoverDelay);
    over.press();
    EXPECT_FALSE(over.update(7, 9 * kHoverDelay).enter.has_value());
    EXPECT_FALSE(over.remaining(9 * kHoverDelay).has_value());
}

TEST(TilingHover, APressEndsTheHoverUntilThePointerLeavesTheLight) {
    CHoverDwell h;
    h.update(4, 0);
    EXPECT_FALSE(h.press().leave.has_value()) << "pressed before the delay: nothing to leave";
    EXPECT_FALSE(h.remaining(1).has_value()) << "held: no timer";
    EXPECT_FALSE(h.update(4, 10 * kHoverDelay).enter.has_value()) << "held while the pointer stays";
    h.update(std::nullopt, 10 * kHoverDelay + 1);
    h.update(4, 10 * kHoverDelay + 2);
    EXPECT_EQ(h.update(4, 11 * kHoverDelay + 2).enter, 4U) << "back on the light after leaving: a hover again";
    EXPECT_EQ(h.press().leave, 4U) << "a press during the hover leaves";
    EXPECT_FALSE(h.entered().has_value());
    EXPECT_FALSE(h.update(4, 20 * kHoverDelay).enter.has_value());
    EXPECT_FALSE(h.press().leave.has_value()) << "a second press leaves nothing";
    CHoverDwell off;
    EXPECT_FALSE(off.press().leave.has_value()) << "no light: a press changes nothing";
    EXPECT_EQ(off.update(5, 0).enter, std::nullopt);
    EXPECT_EQ(off.update(5, kHoverDelay).enter, 5U) << "a press with no light under the pointer holds nothing";
    off.reset();
    EXPECT_FALSE(off.entered().has_value());
    EXPECT_FALSE(off.remaining(0).has_value());
}

TEST(TilingHover, TheEventIsSmall) {
    EXPECT_EQ(tileHoverJson(0xabc, HoverState::Enter, Rect{1500, 40, 18.6667, 18.6667}, true),
              R"({"v":"gfc/1","type":"tile-hover","address":"abc","state":"enter","x":1500,"y":40,"w":18.7,"h":18.7,"tileable":true,"splittable":false,"unfitZones":[],"unfitPlaces":[]})")
        << "one decimal, as the state reply";
    EXPECT_EQ(tileHoverJson(0xabc, HoverState::Open, Rect{1, 2, 3, 4}, false),
              R"({"v":"gfc/1","type":"tile-hover","address":"abc","state":"open","x":1,"y":2,"w":3,"h":4,"tileable":false,"splittable":false,"unfitZones":[],"unfitPlaces":[]})");
    EXPECT_EQ(tileHoverJson(0xabc, HoverState::Leave, Rect{1, 2, 3, 4}, true), R"({"v":"gfc/1","type":"tile-hover","address":"abc","state":"leave"})")
        << "leave carries no box";
    EXPECT_LT(tileHoverJson(UINT64_MAX, HoverState::Enter, Rect{-99999.5, -99999.5, 99999.5, 99999.5}, true).size(), 200U);
}

TEST(TilingMoveTo, AFreeWindowKeepsItsPlaceOnTheOtherOutput) {
    const Rect from{0, 24, 1440, 794};
    const Rect to{1440, 24, 1920, 974};
    // Left-aligned stays left-aligned; centred stays centred; the size is kept.
    EXPECT_EQ(moveToArea(Rect{0, 24, 800, 500}, from, to), (Rect{1440, 24, 800, 500}));
    EXPECT_EQ(moveToArea(Rect{320, 171, 800, 500}, from, to), (Rect{1440 + 560, 24 + 237, 800, 500})) << "centred: 640 / 2 and 294 / 2 of the free space";
    EXPECT_EQ(moveToArea(Rect{640, 318, 800, 500}, from, to), (Rect{1440 + 1120, 24 + 474, 800, 500})) << "against the far edges";
    // Larger than the target area: at most its size, at its origin.
    EXPECT_EQ(moveToArea(Rect{1440 + 0, 24, 1920, 974}, to, from), (Rect{0, 24, 1440, 794}));
    // As large as its old area: centred on the larger one.
    EXPECT_EQ(moveToArea(Rect{0, 24, 1440, 794}, from, to), (Rect{1440 + 240, 24 + 90, 1440, 794}));
    // Off its old area: clamped to the near edge.
    EXPECT_EQ(moveToArea(Rect{-200, 24, 800, 500}, from, to), (Rect{1440, 24, 800, 500}));
    EXPECT_EQ(moveToArea(Rect{0, 24, 0.4, 0.4}, from, to).w, 1) << "never smaller than 1 x 1";
    EXPECT_EQ(moveToArea(Rect{0, 24, 0.4, 0.4}, from, to).h, 1) << "never smaller than 1 x 1";
}

// Owner report on 1.0.0-rc6: a zoomed window moved to a smaller display overflowed it. Nested capture: a 1424 x 860 frame moved
// to GF-REF at 1.25 (1536 x 864, work area 1536 x 840 below the 24 px menu bar) sat at y 3, its titlebar under the menu bar.
TEST(TilingFitIntoArea, AWindowLargerThanTheDisplaysWorkAreaIsMadeToFitIt) {
    const Rect area{1440, 24, 1536, 840};
    EXPECT_EQ(fitIntoArea(Rect{1448, 3, 1424, 860}, area, Constraints{}), (Rect{1448, 24, 1424, 840})) << "too tall: the area's height, below the menu bar, x kept";
    EXPECT_EQ(fitIntoArea(Rect{1500, 300, 1800, 400}, area, Constraints{}), (Rect{1440, 300, 1536, 400})) << "too wide: the area's width from its left edge, y kept";
    EXPECT_EQ(fitIntoArea(Rect{1508, 184, 1400, 862}, area, Constraints{}), (Rect{1508, 24, 1400, 840})) << "a drop that hung below the screen";
    EXPECT_EQ(fitIntoArea(Rect{1000, -50, 2000, 1200}, area, Constraints{}), (Rect{1440, 24, 1536, 840})) << "both axes";
}

TEST(TilingFitIntoArea, AWindowThatFitsKeepsItsFrame) {
    const Rect area{1440, 24, 1536, 840};
    EXPECT_FALSE(fitIntoArea(Rect{1600, 200, 800, 500}, area, Constraints{}).has_value());
    EXPECT_FALSE(fitIntoArea(Rect{2600, 700, 800, 500}, area, Constraints{}).has_value()) << "hanging off the side or the bottom is the user's choice (macOS)";
    EXPECT_FALSE(fitIntoArea(Rect{1440, 24, 1536, 840}, area, Constraints{}).has_value()) << "exactly the area";
    EXPECT_FALSE(fitIntoArea(Rect{1440, 24, 1536.4, 840.4}, area, Constraints{}).has_value()) << "within rounding";
    EXPECT_FALSE(fitIntoArea(Rect{1440, 24, 4000, 4000}, Rect{}, Constraints{}).has_value()) << "no area: nothing to fit";
}

TEST(TilingFitIntoArea, NeverUnderTheWindowsMinimum) {
    const Rect area{0, 24, 1280, 696};
    Constraints c;
    c.minW = 1400;
    c.minH = 700;
    c.band = 32;
    const auto r = fitIntoArea(Rect{100, 100, 1500, 900}, area, c);
    ASSERT_TRUE(r.has_value());
    EXPECT_EQ(r->w, 1400) << "its minimum width, wider than the area";
    EXPECT_EQ(r->h, 732) << "its minimum surface and its titlebar band";
    EXPECT_EQ(r->x, 0);
    EXPECT_EQ(r->y, 24) << "its titlebar still right below the menu bar";
}

// ADR-0036 D67: an output unplugged left a window off every output (integrator nested pass of 12e3dd3: x = -2919).
TEST(TilingGather, AFrameThatMeetsNoOutputIsStray) {
    const std::array<Rect, 2> outputs{Rect{0, 0, 1440, 900}, Rect{1440, 0, 1920, 1080}};
    EXPECT_TRUE(strayFrame(Rect{-2919, 40, 800, 500}, outputs)) << "the reported window";
    EXPECT_FALSE(strayFrame(Rect{100, 100, 800, 500}, outputs));
    EXPECT_FALSE(strayFrame(Rect{3000, 100, 800, 500}, outputs)) << "the second output counts";
    EXPECT_FALSE(strayFrame(Rect{-799, 100, 800, 500}, outputs)) << "1 px on the left edge";
    EXPECT_TRUE(strayFrame(Rect{-800, 100, 800, 500}, outputs)) << "touching the left edge: no area";
    EXPECT_FALSE(strayFrame(Rect{3359, 100, 800, 500}, outputs)) << "1 px on the right edge";
    EXPECT_TRUE(strayFrame(Rect{3360, 100, 800, 500}, outputs)) << "touching the right edge";
    EXPECT_FALSE(strayFrame(Rect{100, -499, 800, 500}, outputs)) << "1 px on the top edge";
    EXPECT_TRUE(strayFrame(Rect{100, -500, 800, 500}, outputs)) << "touching the top edge";
    EXPECT_FALSE(strayFrame(Rect{100, 899, 800, 500}, outputs)) << "1 px on the first output's bottom";
    EXPECT_TRUE(strayFrame(Rect{100, 900, 800, 500}, outputs)) << "under the first output, beside nothing";
    EXPECT_TRUE(strayFrame(Rect{1500, 1080, 800, 500}, outputs)) << "under the second output";
    EXPECT_TRUE(strayFrame(Rect{-900, 1000, 800, 500}, outputs)) << "off on both axes";
    EXPECT_TRUE(strayFrame(Rect{100, 2000, 800, 500}, outputs)) << "in an output's columns, below every row";
    EXPECT_TRUE(strayFrame(Rect{100, 100, 800, 500}, std::span<const Rect>{})) << "no output";
}

TEST(TilingGather, AStrayWindowComesBackCentredAtItsSize) {
    const Rect area{1440, 32, 1920, 1048};
    EXPECT_EQ(gatheredFrame(Rect{-2919, 40, 800, 500}, area), (Rect{1440 + 560, 32 + 274, 800, 500}));
    EXPECT_EQ(gatheredFrame(Rect{-2919, 40, 2400, 500}, area), (Rect{1440, 32 + 274, 1920, 500})) << "at most the area's width";
    EXPECT_EQ(gatheredFrame(Rect{-2919, 40, 800, 1300}, area), (Rect{1440 + 560, 32, 800, 1048})) << "at most the area's height";
    EXPECT_EQ(gatheredFrame(Rect{-2919, 40, 801, 501}, area), (Rect{1440 + 560, 32 + 274, 801, 501})) << "whole px: 559.5 and 273.5 round";
    EXPECT_EQ(gatheredFrame(Rect{-2919, 40, 800.4, 500.4}, area), (Rect{1440 + 560, 32 + 274, 800, 500})) << "whole px sizes";
    EXPECT_EQ(gatheredFrame(Rect{0, 0, 0.2, 0.2}, area).w, 1) << "never smaller than 1 x 1";
    EXPECT_EQ(gatheredFrame(Rect{0, 0, 0.2, 0.2}, area).h, 1) << "never smaller than 1 x 1";
}

TEST(TilingMoveTo, OutputNamesAreStrict) {
    EXPECT_TRUE(outputNameOk("GF-REF"));
    EXPECT_TRUE(outputNameOk("DP-1.2_a"));
    EXPECT_FALSE(outputNameOk(""));
    EXPECT_FALSE(outputNameOk("bad name"));
    EXPECT_FALSE(outputNameOk("a\"b"));
    EXPECT_TRUE(outputNameOk(std::string(kMaxOutputName, 'a')));
    EXPECT_FALSE(outputNameOk(std::string(kMaxOutputName + 1, 'a')));
}

// ---- step 4a: the Layouts section and the suggestions (TL27, TL28) ----

TEST(TilingSuggest, WithNamesTheWindowWhoseLayoutTheZoneIs) {
    const auto pick = parseArrange(R"({"layout":"thirds","windows":["0x9"],"zone":1,"with":"0x1a"})");
    ASSERT_TRUE(pick.has_value()) << pick.error();
    EXPECT_EQ(pick->with, 0x1aU);
    EXPECT_EQ(pick->zone, 1);
    EXPECT_FALSE(pick->fill);
    EXPECT_FALSE(parseArrange(R"({"layout":"thirds","windows":["0x9"],"zone":0})")->with.has_value()) << "a zone of the Layouts section alone";
    for (const char* bad : {
             R"({"layout":"thirds","windows":["0x9"],"with":"0x1a"})",                    // with needs a zone
             R"({"layout":"thirds","windows":["0x9"],"zone":1,"with":"0x9"})",           // the window placed itself
             R"({"layout":"thirds","windows":["0x9"],"zone":1,"with":"0x0"})",           // not a window
             R"({"layout":"thirds","windows":["0x9"],"zone":1,"with":"zz"})",            // not hex
             R"({"layout":"thirds","windows":["0x9"],"zone":1,"with":7})",               // not a string
             R"({"layout":"thirds","windows":["0x9"],"zone":1,"with":"1","with":"2"})",  // twice
         })
        EXPECT_FALSE(parseArrange(bad).has_value()) << bad;
}

TEST(TilingSuggest, TheZonesHeldAreThoseOfTheLayoutInstance) {
    CTileBook  book;
    const Rect any{0, 0, 10, 10};
    book.placed(1, any, any, 0, inLayout("quarters", 2), "A", 1, 0);
    const auto held = [&book](uint64_t id) { return zonesHeld(book.records(), *book.find(id)); };
    book.placed(10, any, any, 0, inLayout("quarters", 1), "A", 1, 0);
    EXPECT_EQ(held(1), (std::vector<int>{2})) << "alone: its own zone (another window without a group is not its group)";
    const auto& quarters = *layoutById("quarters");
    EXPECT_EQ(emptyZones(quarters, held(1)), (std::vector<int>{0, 1, 3}));
    book.forget(10);
    // A suggestion joins it: the asker's group (a new one) holds both zones.
    const uint64_t before = book.generation();
    const uint64_t group  = book.joinGroup(1);
    EXPECT_GT(book.generation(), before) << "a change of the records";
    EXPECT_NE(group, 0U);
    EXPECT_EQ(book.find(1)->group, group);
    EXPECT_EQ(book.joinGroup(1), group) << "the same group the next time";
    book.placed(2, any, any, 0, inLayout("quarters", 0), "A", 1, group);
    EXPECT_EQ(held(1), (std::vector<int>{0, 2}));
    EXPECT_EQ(held(2), (std::vector<int>{0, 2})) << "from any member";
    EXPECT_EQ(emptyZones(quarters, held(2)), (std::vector<int>{1, 3}));
    // Not counted: another group, another layout, another output or Desktop, a member that is not holding its zone.
    book.placed(3, any, any, 0, inLayout("quarters", 1), "A", 1, book.newGroup());
    book.placed(4, any, any, 0, inLayout("quarters", 3), "B", 1, group);
    book.placed(5, any, any, 0, inLayout("quarters", 3), "A", 2, group);
    book.placed(6, any, any, 0, inLayout("thirds", 1), "A", 1, group);
    EXPECT_EQ(held(1), (std::vector<int>{0, 2}));
    book.placed(7, any, any, 0, inLayout("quarters", 3), "A", 1, group);
    ASSERT_TRUE(book.beginMove(7).has_value());
    EXPECT_EQ(held(1), (std::vector<int>{0, 2})) << "dragged away: it left the group and its zone";
    book.placed(8, any, any, 0, inLayout("quarters", 3), "A", 1, group);
    ASSERT_TRUE(book.suspend(8));
    EXPECT_EQ(held(1), (std::vector<int>{0, 2, 3})) << "suspended (minimized): it comes back to its zone";
    EXPECT_EQ(emptyZones(quarters, held(1)), (std::vector<int>{1}));
    EXPECT_EQ(emptyZones(quarters, std::vector<int>{0, 1, 2, 3}), (std::vector<int>{})) << "full: nothing to suggest";
    // A window placed by a place, not a layout, holds no zone of one.
    book.placed(9, any, any, 0, at(Place::Left), "A", 1, 0);
    EXPECT_TRUE(held(9).empty());
    EXPECT_EQ(book.joinGroup(42), 0U) << "no record";
    // Two members on one zone count it once; a record without a zone counts none.
    book.placed(11, any, any, 0, inLayout("quarters", 3), "A", 1, group);
    book.placed(12, any, any, 0, inLayout("quarters", -1), "A", 1, group);
    EXPECT_EQ(held(1), (std::vector<int>{0, 2, 3}));
    // A window being dragged out of its zone holds none.
    CTileBook moving;
    moving.placed(20, any, any, 0, inLayout("quarters", 1), "A", 1, 0);
    ASSERT_TRUE(moving.beginMove(20).has_value());
    EXPECT_TRUE(zonesHeld(moving.records(), *moving.find(20)).empty());
}

TEST(TilingSuggest, TheReplyCarriesTheSuggestion) {
    Suggestion sg;
    sg.generation = 12;
    sg.asker      = 0xabc;
    sg.layout     = "thirds";
    sg.output     = "GF-REF";
    sg.zones      = {0, 2};
    sg.frames     = {Rect{8, 64, 629, 926}, Rect{1283, 64, 629, 926}};
    sg.windows    = {0xd1, 0xd2};
    const std::array<StateOutput, 0> none{};
    EXPECT_EQ(stateJson(12, none, &sg),
              R"({"v":"gfc/1","type":"tiling","gen":12,"outputs":[],"splits":[],"unfit":[],"fixed":[],"unfitZones":[],"suggestion":{"gen":12,"address":"abc","layout":"thirds","output":"GF-REF",)"
              R"("zones":[{"zone":0,"x":8,"y":64,"w":629,"h":926},{"zone":2,"x":1283,"y":64,"w":629,"h":926}],"windows":["d1","d2"]}})");
    EXPECT_EQ(stateJson(12, none), R"({"v":"gfc/1","type":"tiling","gen":12,"outputs":[],"splits":[],"unfit":[],"fixed":[],"unfitZones":[],"suggestion":null})");
    // Bounded: at most kMaxSuggested windows, and a zone without a frame is not written.
    for (uint64_t i = 0; i < 20; ++i)
        sg.windows.push_back(0x100 + i);
    sg.zones.push_back(1);
    const auto json = stateJson(12, none, &sg);
    size_t     quotes = 0;
    for (size_t at = json.find(R"("windows":[)"); at != std::string::npos && at < json.size(); ++at)
        quotes += json[at] == '"' ? 1 : 0;
    EXPECT_EQ(quotes, 2 + 2 * kMaxSuggested) << json;
    EXPECT_EQ(json.find(R"("zone":1)"), std::string::npos);
}

// ---- step 4b: tile groups (TL29) ----

TEST(TilingGroups, TheGroupComesForwardInItsStackingOrder) {
    CTileBook  book;
    const Rect any{0, 0, 10, 10};
    const auto group = book.newGroup();
    book.placed(1, any, any, 0, inLayout("thirds", 0), "A", 1, group);
    book.placed(2, any, any, 0, inLayout("thirds", 1), "A", 1, group);
    book.placed(3, any, any, 0, inLayout("thirds", 2), "A", 1, group);
    book.placed(4, any, any, 0, at(Place::Left), "A", 1, 0);
    const auto other = book.newGroup();
    book.placed(5, any, any, 0, inLayout("left-right", 0), "A", 1, other);
    book.placed(6, any, any, 0, inLayout("left-right", 1), "A", 1, other);
    book.placed(7, any, any, 0, at(Place::Right), "A", 1, 0);
    const std::vector<uint64_t> stack{3, 9, 5, 4, 1, 7, 6, 2}; // bottom to top; 9 has no record
    EXPECT_EQ(groupRaiseOrder(book.records(), 2, stack), (std::vector<uint64_t>{3, 1, 2})) << "the others, bottom first, then the chosen one";
    EXPECT_EQ(groupRaiseOrder(book.records(), 3, stack), (std::vector<uint64_t>{1, 2, 3}));
    EXPECT_EQ(groupRaiseOrder(book.records(), 5, stack), (std::vector<uint64_t>{6, 5})) << "only the chosen one's group";
    EXPECT_TRUE(groupRaiseOrder(book.records(), 7, stack).empty()) << "windows without a group are no group";
    EXPECT_EQ(groupRaiseOrder(book.records(), 2, std::vector<uint64_t>{3, 1}), (std::vector<uint64_t>{3, 1})) << "the chosen one not on screen";
    EXPECT_TRUE(groupRaiseOrder(book.records(), 4, stack).empty()) << "no group";
    EXPECT_TRUE(groupRaiseOrder(book.records(), 9, stack).empty()) << "no record";
    // A suspended member (minimized) stays where it is; one being resized comes; one on another Desktop does not.
    ASSERT_TRUE(book.suspend(3));
    ASSERT_TRUE(book.beginResize(1));
    EXPECT_EQ(groupRaiseOrder(book.records(), 2, stack), (std::vector<uint64_t>{1, 2}));
    // A suspended chosen one on screen (zoomed or full screen, focused: the activation changes nothing) still ends in front
    // of the others (integrator review of cd74af2); minimized or hidden it is in no stack (a special workspace) and its
    // restore raises it.
    EXPECT_EQ(groupRaiseOrder(book.records(), 3, stack), (std::vector<uint64_t>{1, 2, 3}));
    EXPECT_EQ(groupRaiseOrder(book.records(), 3, std::vector<uint64_t>{9, 1, 2}), (std::vector<uint64_t>{1, 2}));
    book.endResize(1, any);
    book.setWorkspace(1, 2);
    EXPECT_TRUE(groupRaiseOrder(book.records(), 2, stack).empty());
    // A window listed twice in the stack is raised once; a member not in the stack (unmapped) is not raised.
    book.setWorkspace(1, 1);
    const std::vector<uint64_t> doubled{1, 1, 2};
    EXPECT_EQ(groupRaiseOrder(book.records(), 2, doubled), (std::vector<uint64_t>{1, 2}));
    EXPECT_TRUE(groupRaiseOrder(book.records(), 2, std::vector<uint64_t>{2}).empty()) << "no other member on screen";
}

// ---- step 4c: the shared edge (TL30) ----

namespace {
    // Left & Quarters with margins 8 in a 1000 x 800 area: L on the left, TR and BR stacked on the right, one group.
    std::vector<EdgeWindow> leftQuarters(uint64_t group = 7) {
        return {
            EdgeWindow{.id = 1, .group = group, .frame = Rect{8, 8, 488, 784}, .limits = {}},
            EdgeWindow{.id = 2, .group = group, .frame = Rect{504, 8, 488, 388}, .limits = {}},
            EdgeWindow{.id = 3, .group = group, .frame = Rect{504, 404, 488, 388}, .limits = {}},
        };
    }

    Rect frameOf(const std::vector<std::pair<uint64_t, Rect>>& frames, uint64_t id) {
        const auto it = std::ranges::find_if(frames, [id](const auto& f) { return f.first == id; });
        return it == frames.end() ? Rect{-1, -1, -1, -1} : it->second;
    }
}

TEST(TilingEdge, TheGroupsSharedEdgesAndTheirHandles) {
    const auto windows = leftQuarters();
    const auto edges   = sharedEdges(windows, 8, 120, 8);
    ASSERT_EQ(edges.size(), 2u);
    const auto& v = edges[0];
    EXPECT_TRUE(v.vertical);
    EXPECT_EQ(v.group, 7u);
    EXPECT_DOUBLE_EQ(v.at, 496);
    EXPECT_DOUBLE_EQ(v.gap, 8);
    EXPECT_EQ(v.before, (std::vector<uint64_t>{1}));
    EXPECT_EQ(v.after, (std::vector<uint64_t>{2, 3})) << "every window of the group along the line";
    ASSERT_EQ(v.handles.size(), 2u) << "one per pair of facing windows";
    EXPECT_EQ(v.handles[0], (Rect{496, 142, 8, 120})) << "the middle 120 of the stretch L and TR share, the gap across";
    EXPECT_EQ(v.handles[1], (Rect{496, 538, 8, 120}));
    const auto& h = edges[1];
    EXPECT_FALSE(h.vertical);
    EXPECT_DOUBLE_EQ(h.at, 396);
    EXPECT_EQ(h.before, (std::vector<uint64_t>{2}));
    EXPECT_EQ(h.after, (std::vector<uint64_t>{3}));
    ASSERT_EQ(h.handles.size(), 1u);
    EXPECT_EQ(h.handles[0], (Rect{688, 396, 120, 8}));

    // A band wider than the gap widens the handle equally into both windows; a stretch shorter than the handle is all of it.
    const auto wide = sharedEdges(windows, 8, 1000, 12);
    ASSERT_FALSE(wide.empty());
    ASSERT_FALSE(wide[0].handles.empty());
    EXPECT_EQ(wide[0].handles[0], (Rect{494, 8, 12, 388}));
    // Without margins the windows touch: the handle is the band, half in each.
    std::vector<EdgeWindow> touching{{.id = 1, .group = 3, .frame = Rect{0, 0, 500, 800}, .limits = {}}, {.id = 2, .group = 3, .frame = Rect{500, 0, 500, 800}, .limits = {}}};
    const auto flush = sharedEdges(touching, 0, 120, 8);
    ASSERT_EQ(flush.size(), 1u);
    EXPECT_DOUBLE_EQ(flush[0].gap, 0);
    ASSERT_EQ(flush[0].handles.size(), 1u);
    EXPECT_EQ(flush[0].handles[0], (Rect{496, 340, 8, 120}));
    // A one-px overlap still counts (gap 0); more, or a gap wider than the margin, does not.
    touching[1].frame.x = 499;
    const auto overlap = sharedEdges(touching, 0, 120, 8);
    ASSERT_EQ(overlap.size(), 1u);
    EXPECT_DOUBLE_EQ(overlap[0].gap, 0);
    touching[1].frame.x = 497;
    EXPECT_TRUE(sharedEdges(touching, 0, 120, 8).empty());
    touching[1].frame.x = 510;
    EXPECT_TRUE(sharedEdges(touching, 8, 120, 8).empty()) << "10 px apart, the margin 8";
    touching[1].frame.x = 509;
    EXPECT_EQ(sharedEdges(touching, 8, 120, 8).size(), 1u);
    // One line, two gaps (a margin on one side only): two edges.
    std::vector<EdgeWindow> uneven{
        {.id = 1, .group = 5, .frame = Rect{8, 8, 488, 784}, .limits = {}},
        {.id = 2, .group = 5, .frame = Rect{504, 8, 488, 388}, .limits = {}},
        {.id = 3, .group = 5, .frame = Rect{496, 404, 496, 388}, .limits = {}},
    };
    const auto split = sharedEdges(uneven, 8, 120, 8);
    ASSERT_EQ(split.size(), 3u) << "L|TR (gap 8), L|BR (gap 0) and TR over BR";
    EXPECT_DOUBLE_EQ(split[0].gap, 8);
    EXPECT_DOUBLE_EQ(split[1].gap, 0);
    EXPECT_EQ(split[1].after, (std::vector<uint64_t>{3}));
    // Facing along at most 1 px is no edge.
    touching[1].frame = Rect{500, 799, 500, 800};
    EXPECT_TRUE(sharedEdges(touching, 0, 120, 8).empty());
}

TEST(TilingEdge, OnlyMembersOfOneGroupShareAnEdge) {
    EXPECT_TRUE(sharedEdges(leftQuarters(0), 8, 120, 8).empty()) << "group 0 is no group";
    auto mixed     = leftQuarters();
    mixed[1].group = 8;
    const auto edges = sharedEdges(mixed, 8, 120, 8);
    ASSERT_EQ(edges.size(), 1u) << "L and BR only";
    EXPECT_EQ(edges[0].after, (std::vector<uint64_t>{3}));
    // Quarters: the cross is two lines, each with all four windows.
    std::vector<EdgeWindow> quarters{
        {.id = 1, .group = 1, .frame = Rect{8, 8, 488, 388}, .limits = {}},   {.id = 2, .group = 1, .frame = Rect{504, 8, 488, 388}, .limits = {}},
        {.id = 3, .group = 1, .frame = Rect{8, 404, 488, 388}, .limits = {}}, {.id = 4, .group = 1, .frame = Rect{504, 404, 488, 388}, .limits = {}},
    };
    const auto cross = sharedEdges(quarters, 8, 120, 8);
    ASSERT_EQ(cross.size(), 2u);
    EXPECT_EQ(cross[0].before, (std::vector<uint64_t>{1, 3}));
    EXPECT_EQ(cross[0].after, (std::vector<uint64_t>{2, 4}));
    EXPECT_EQ(cross[0].handles.size(), 2u);
    EXPECT_EQ(cross[1].before, (std::vector<uint64_t>{1, 2}));
    EXPECT_EQ(cross[1].after, (std::vector<uint64_t>{3, 4}));
    // Two groups side by side on one line (the top pair one group, the bottom pair another): two edges, never one.
    auto halves     = quarters;
    halves[2].group = 2;
    halves[3].group = 2;
    const auto pairs = sharedEdges(halves, 8, 120, 8);
    ASSERT_EQ(pairs.size(), 2u) << "the vertical line splits by group; no window faces one of its group across the horizontal";
    EXPECT_EQ(pairs[0].group, 1u);
    EXPECT_EQ(pairs[0].before, (std::vector<uint64_t>{1}));
    EXPECT_EQ(pairs[0].after, (std::vector<uint64_t>{2}));
    EXPECT_EQ(pairs[1].group, 2u);
    EXPECT_EQ(pairs[1].before, (std::vector<uint64_t>{3}));
    EXPECT_EQ(pairs[1].after, (std::vector<uint64_t>{4}));
}

TEST(TilingEdge, AHandleUnderThePointer) {
    const auto edges = sharedEdges(leftQuarters(), 8, 120, 8);
    const auto onVertical = edgeAt(edges, 500, 200);
    EXPECT_TRUE(onVertical.has_value() && onVertical->vertical);
    const auto onHorizontal = edgeAt(edges, 700, 400);
    EXPECT_TRUE(onHorizontal.has_value() && !onHorizontal->vertical);
    EXPECT_TRUE(edgeAt(edges, 496, 142).has_value()) << "the handle's own corner";
    EXPECT_FALSE(edgeAt(edges, 504, 200).has_value()) << "its far side is out";
    EXPECT_FALSE(edgeAt(edges, 500, 262).has_value());
    EXPECT_FALSE(edgeAt(edges, 500, 100).has_value()) << "the edge outside the handle resizes one window (Hyprland's border)";
    EXPECT_FALSE(edgeAt(edges, 300, 300).has_value());
    EXPECT_FALSE(edgeAt(std::vector<SharedEdge>{}, 500, 200).has_value());
}

TEST(TilingEdge, AHandleYieldsToAWindowInFrontOfIt) {
    const auto edges = sharedEdges(leftQuarters(), 8, 120, 8);
    ASSERT_EQ(edges.size(), 2u);
    const auto& v = edges[0];
    EXPECT_TRUE(handleClear(v, 0, false)) << "nothing there: the margin between the edge's windows";
    EXPECT_TRUE(handleClear(v, 1, false)) << "a before window's border grab area";
    EXPECT_TRUE(handleClear(v, 3, false)) << "an after window's";
    EXPECT_FALSE(handleClear(v, 9, false)) << "another window in front (free, zoomed, full screen, or its titlebar) gets the click";
    EXPECT_FALSE(handleClear(v, 1, true)) << "a popup of the edge's own window";
    EXPECT_FALSE(handleClear(v, 9, true));
    EXPECT_FALSE(handleClear(v, 0, true)) << "a popup over the gap, no window's box there (integrator nested pass of 3d56d60)";
    EXPECT_FALSE(handleClear(v, 3, true)) << "a popup of the lower window under the upper one's border grab area";
    EXPECT_FALSE(handleClear(edges[1], 1, false)) << "a window of the group outside this edge";
}

TEST(TilingEdge, ADragMovesTheEdgeForEveryWindowWithinTheirLimits) {
    auto       windows = leftQuarters();
    const auto edges   = sharedEdges(windows, 8, 120, 8);
    ASSERT_EQ(edges.size(), 2u);
    const auto& v = edges[0];
    const auto& h = edges[1];
    const Grid  grid{.originX = 0, .originY = 0, .step = 1};
    auto       out = dragEdge(v, windows, 50, grid);
    ASSERT_EQ(out.size(), 3u);
    EXPECT_EQ(out[0].first, 1u);
    EXPECT_EQ(frameOf(out, 1), (Rect{8, 8, 538, 784}));
    EXPECT_EQ(frameOf(out, 2), (Rect{554, 8, 438, 388})) << "the gap kept";
    EXPECT_EQ(frameOf(out, 3), (Rect{554, 404, 438, 388}));
    EXPECT_EQ(frameOf(dragEdge(v, windows, -30.4, grid), 1), (Rect{8, 8, 458, 784})) << "the nearest grid line";

    // Minimum and maximum of every window: an after window's minimum stops a move right, a before window's a move left.
    windows[1].limits.minW = 450;
    EXPECT_EQ(frameOf(dragEdge(v, windows, 50, grid), 2), (Rect{542, 8, 450, 388}));
    windows[0].limits.maxW = 500;
    EXPECT_EQ(frameOf(dragEdge(v, windows, 50, grid), 1), (Rect{8, 8, 500, 784}));
    windows[0].limits.minW = 400;
    EXPECT_EQ(frameOf(dragEdge(v, windows, -100, grid), 1), (Rect{8, 8, 400, 784}));
    windows[2].limits.maxW = 520;
    EXPECT_EQ(frameOf(dragEdge(v, windows, -100, grid), 3), (Rect{472, 404, 520, 388})) << "an after window's maximum";

    // Heights count the titlebar band.
    windows[1].limits = Constraints{.minW = 1, .minH = 300, .maxW = 0, .maxH = 0, .incW = 0, .incH = 0, .baseW = 0, .baseH = 0, .band = 32};
    windows[2].limits = Constraints{.minW = 1, .minH = 200, .maxW = 0, .maxH = 0, .incW = 0, .incH = 0, .baseW = 0, .baseH = 0, .band = 32};
    out = dragEdge(h, windows, -100, grid);
    EXPECT_EQ(frameOf(out, 2), (Rect{504, 8, 488, 332}));
    EXPECT_EQ(frameOf(out, 3), (Rect{504, 348, 488, 444}));
    EXPECT_EQ(frameOf(dragEdge(h, windows, 200, grid), 3), (Rect{504, 560, 488, 232}));
    windows[2].limits.maxH = 400;
    EXPECT_EQ(frameOf(dragEdge(h, windows, -100, grid), 3), (Rect{504, 360, 488, 432})) << "an after window's maximum, band included";
}

TEST(TilingEdge, ADragLandsOnTheGrid) {
    const auto windows = leftQuarters();
    const auto edges   = sharedEdges(windows, 8, 120, 8);
    ASSERT_EQ(edges.size(), 2u);
    const auto& h = edges[1];
    const Grid  even{.originX = 0, .originY = 0, .step = 2};
    EXPECT_EQ(frameOf(dragEdge(h, windows, 3, even), 2).h, 392) << "396 + 3 to the nearest even line, 400";
    // The last line inside the limits when the nearest is outside them.
    auto limited          = windows;
    limited[2].limits.minH = 383; // BR may give 5 px
    EXPECT_EQ(frameOf(dragEdge(h, limited, 9, even), 2).h, 392) << "405 is past the limit: 400, not 406";
    // Moving left, the nearest line below the limit: the first line inside it.
    auto vlimited          = windows;
    vlimited[0].limits.minW = 400.6; // L may lose 87.4 px: 408.6 is the edge's limit, 408 the nearest even line
    const auto& v          = edges[0];
    EXPECT_EQ(frameOf(dragEdge(v, vlimited, -100, even), 1).w, 402) << "the edge on 410";
    // No line inside the limits: nothing moves.
    const Grid coarse{.originX = 0, .originY = 0, .step = 4};
    limited[2].limits.minH = 387; // 1 px to give, the next line 4 away
    EXPECT_EQ(frameOf(dragEdge(h, limited, 9, coarse), 2).h, 388);
    // Limits that cannot all hold: nothing moves.
    auto stuck          = windows;
    stuck[1].limits.minH = 500;
    stuck[2].limits.minH = 500;
    EXPECT_EQ(frameOf(dragEdge(h, stuck, 50, Grid{}), 2), windows[1].frame);
    EXPECT_EQ(frameOf(dragEdge(h, stuck, 50, Grid{}), 3), windows[2].frame);
    // A window the frames lack is left out; a side with none left does not move the edge (integrator re-review of ce82fd3:
    // Left & Right, the left window gone, a drag of -600 put the right one at x -96, off the work area).
    const auto alone = dragEdge(h, std::vector<EdgeWindow>{windows[1]}, 10, Grid{});
    ASSERT_EQ(alone.size(), 1u);
    EXPECT_EQ(alone[0].second, windows[1].frame) << "the after side is gone: nothing bounds the before window";
    std::vector<EdgeWindow> pair{{.id = 1, .group = 3, .frame = Rect{8, 8, 488, 784}, .limits = {}}, {.id = 2, .group = 3, .frame = Rect{504, 8, 488, 784}, .limits = {}}};
    const auto              lr = sharedEdges(pair, 8, 120, 8);
    ASSERT_EQ(lr.size(), 1u);
    const auto right = dragEdge(lr[0], std::vector<EdgeWindow>{pair[1]}, -600, Grid{});
    ASSERT_EQ(right.size(), 1u);
    EXPECT_EQ(right[0].second, pair[1].frame) << "the before side is gone: the right window stays in the work area";
    pair[0].limits.minW = 20; // the glue's floor (MIN_WINDOW_SIZE)
    EXPECT_EQ(frameOf(dragEdge(lr[0], pair, -600, Grid{}), 2), (Rect{36, 8, 956, 784})) << "with both, the left window's minimum bounds the edge";
}

// ---- ADR-0036 step 6a: the Full Screen tile (docs/specs/tiling.md TL33) ----

// D42: the two halves of the whole output, one margin apart, none at the outer edges; on the output's grid.
TEST(TilingSplit, TheHalvesFillTheOutputWithOneSeparator) {
    const auto& zones = layoutById("left-right")->zones;
    const Area  one   = splitArea(Rect{0, 0, 1920, 1080}, Grid{0, 0, 1});
    EXPECT_EQ(zoneFrame(zones[0], one), (Rect{0, 0, 960 - kMargin / 2, 1080}));
    EXPECT_EQ(zoneFrame(zones[1], one), (Rect{960 + kMargin / 2, 0, 960 - kMargin / 2, 1080}));
    // Another output to the right, at scale 1.5 (grid step 2): the same shape on its own origin and grid.
    const Area right = splitArea(Rect{1920, 0, 1708, 960}, Grid{1920, 0, gridStep(1.5)});
    const Rect l     = zoneFrame(zones[0], right);
    const Rect r     = zoneFrame(zones[1], right);
    EXPECT_EQ(l.x, 1920);
    EXPECT_EQ(l.y, 0);
    EXPECT_EQ(l.h, 960);
    EXPECT_EQ(r.x + r.w, 1920 + 1708);
    EXPECT_EQ(r.x - (l.x + l.w), kMargin);
    EXPECT_EQ(std::fmod(l.x + l.w - 1920, 2.0), 0.0) << "the inner edge lies on the grid";
    // Fill takes the whole output.
    const Zone full{0, 0, 12, 12};
    EXPECT_EQ(zoneFrame(full, one), (Rect{0, 0, 1920, 1080}));
}

TEST(TilingSplit, ANewDesktopTakesTheNextId) {
    EXPECT_EQ(nextDesktopId(std::vector<int64_t>{}), 1);
    EXPECT_EQ(nextDesktopId(std::vector<int64_t>{1, 2, 5}), 6);
    EXPECT_EQ(nextDesktopId(std::vector<int64_t>{3, -98, -1337}), 4) << "special and named workspaces are negative";
    EXPECT_EQ(nextDesktopId(std::vector<int64_t>{-98}), 1);
}

// Step 6d (ADR-0036 D71): how a window leaves its Split View Desktop, and Replace Tiled Window's offer.
TEST(TilingSplit, HowAWindowLeaves) {
    EXPECT_EQ(unsplitHow(""), Unsplit::Desktop) << "no second argument: Move Window to Desktop (D44)";
    EXPECT_EQ(unsplitHow("desktop"), Unsplit::Desktop);
    EXPECT_EQ(unsplitHow("fullscreen"), Unsplit::Fullscreen);
    EXPECT_EQ(unsplitHow("replace"), Unsplit::Replace);
    for (const char* bad : {"Desktop", "full screen", "fullscreen ", "replace\n", "zoom", "left", "x"})
        EXPECT_FALSE(unsplitHow(bad).has_value()) << bad;
}

TEST(TilingSplit, ReplaceOffersEveryWindowButTheOneReplaced) {
    EXPECT_EQ(offerWindows(std::vector<uint64_t>{0xb2, 0xc3, 0xd4}, 0xc3), (std::vector<uint64_t>{0xb2, 0xd4})) << "the others, in their order";
    EXPECT_EQ(offerWindows(std::vector<uint64_t>{0xb2, 0xc3}, 0xe5), (std::vector<uint64_t>{0xb2, 0xc3})) << "a window not offered changes nothing";
    EXPECT_EQ(offerWindows(std::vector<uint64_t>{0xb2, 0xc3}, 0), (std::vector<uint64_t>{0xb2, 0xc3})) << "0 excludes none";
    EXPECT_TRUE(offerWindows(std::vector<uint64_t>{0xc3}, 0xc3).empty()) << "nothing left to offer: no picker (the other member fills)";
    EXPECT_TRUE(offerWindows(std::vector<uint64_t>{}, 0xc3).empty());
    EXPECT_EQ(offerWindows(std::vector<uint64_t>{0xb2, 0xb2, 0xc3}, 0), (std::vector<uint64_t>{0xb2, 0xc3})) << "each once";
    // The follow-up of #78: the cap counts after the exclusion, so twelve stay offered when thirteen were candidates.
    std::vector<uint64_t> many;
    for (uint64_t i = 1; i <= kMaxSuggested + 1; ++i)
        many.push_back(i);
    const auto offered = offerWindows(many, 1);
    ASSERT_EQ(offered.size(), kMaxSuggested);
    EXPECT_EQ(offered.front(), 2U);
    EXPECT_EQ(offered.back(), kMaxSuggested + 1);
    EXPECT_EQ(offerWindows(many, 0).size(), kMaxSuggested) << "never more than kMaxSuggested";
    EXPECT_EQ(offerWindows(many, 0).back(), kMaxSuggested) << "the first ones, in their order";
}

// Step 6e (ADR-0036 D73): a member's titlebar is away; the windows that joined or left a Split View have theirs refreshed.
TEST(TilingSplit, TheWindowsThatJoinedOrLeftASplitView) {
    const std::vector<SplitDesk> splits{{.workspace = 9, .output = "GF-REF", .home = 2, .members = {0xd4, 0xb2}},
                                        {.workspace = 11, .output = "WAYLAND-1", .home = 4, .members = {0xa1}},
                                        {.workspace = 12, .output = "WAYLAND-1", .home = 4, .members = {}}};
    EXPECT_EQ(splitMembers(splits), (std::vector<uint64_t>{0xa1, 0xb2, 0xd4})) << "every member of every Split View, sorted";
    EXPECT_TRUE(splitMembers({}).empty());
    const std::vector<SplitDesk> twice{{.workspace = 9, .members = {0xb2, 0xb2}}, {.workspace = 11, .members = {0xb2}}};
    EXPECT_EQ(splitMembers(twice), (std::vector<uint64_t>{0xb2})) << "each once";

    const std::vector<uint64_t> before{0xa1, 0xb2, 0xd4};
    EXPECT_TRUE(membersChanged(before, before).empty()) << "nothing joined or left: no titlebar is refreshed";
    EXPECT_EQ(membersChanged(before, std::vector<uint64_t>{0xa1, 0xd4}), (std::vector<uint64_t>{0xb2})) << "one left: its bar comes back";
    EXPECT_EQ(membersChanged(std::vector<uint64_t>{0xa1}, std::vector<uint64_t>{0xa1, 0xc3}), (std::vector<uint64_t>{0xc3})) << "one joined: its bar goes";
    EXPECT_EQ(membersChanged(std::vector<uint64_t>{0xa1, 0xb2}, std::vector<uint64_t>{0xb2, 0xc3}), (std::vector<uint64_t>{0xa1, 0xc3})) << "both at once";
    EXPECT_EQ(membersChanged(before, {}), before) << "every Split View ended";
    EXPECT_EQ(membersChanged({}, before), before) << "a first Split View";
}

TEST(TilingSplit, SidesAndDesktops) {
    EXPECT_EQ(splitZone("left"), 0);
    EXPECT_EQ(splitZone("right"), 1);
    for (const char* bad : {"", "Left", "fill", "top", "left "})
        EXPECT_FALSE(splitZone(bad).has_value()) << bad;
    const std::vector<SplitDesk> splits{{.workspace = 7, .output = "GF-REF", .home = 2}, {.workspace = 9, .output = "WAYLAND-1", .home = 4}};
    ASSERT_NE(splitOf(splits, 9), nullptr);
    EXPECT_EQ(splitOf(splits, 9)->home, 4);
    EXPECT_EQ(splitOf(splits, 7)->output, "GF-REF");
    EXPECT_EQ(splitOf(splits, 2), nullptr);
    EXPECT_EQ(splitOf({}, 7), nullptr);
}

TEST(TilingSplit, TheReplyListsTheSplitDesktops) {
    const std::array<StateOutput, 0> none{};
    const std::array<SplitDesk, 2>   splits{SplitDesk{.workspace = 7, .output = "GF-REF", .home = 2, .members = {0xa1, 0xb2}},
                                          SplitDesk{.workspace = 9, .output = "A\"B", .home = 4, .members = {0xc3}, .waiting = true}};
    EXPECT_EQ(stateJson(5, none, nullptr, splits),
              R"({"v":"gfc/1","type":"tiling","gen":5,"outputs":[],"splits":[{"workspace":7,"output":"GF-REF","home":2,"windows":["a1","b2"],"waiting":false},)"
              R"({"workspace":9,"output":"A\"B","home":4,"windows":["c3"],"waiting":true}],"unfit":[],"fixed":[],"unfitZones":[],"suggestion":null})");
}

// D57 (integrator PASS on 8316ed2, for later): the windows that do not fit half of their output, for the Window menu.
TEST(TilingSplit, TheReplyListsTheWindowsThatDoNotFitAHalf) {
    const std::array<StateOutput, 0> none{};
    const std::array<uint64_t, 2>    unfit{0xa1, 0xbeef};
    EXPECT_EQ(stateJson(5, none, nullptr, {}, unfit), R"({"v":"gfc/1","type":"tiling","gen":5,"outputs":[],"splits":[],"unfit":["a1","beef"],"fixed":[],"unfitZones":[],"suggestion":null})");
}

// ADR-0040 step 1b (the integrator's nested pass of 85c2c10): a window of fixed size has its zoom light disabled (no tiling
// popover on hover, the tile_popover request refused), and the reply lists it for the Window menu, which greys its Zoom and
// tiling items. Fixed on both axes only: a window fixed on one axis stays zoomable (TL9 still refuses to tile it).
TEST(TilingFixed, AWindowOfFixedSizeHasItsZoomLightDisabled) {
    EXPECT_TRUE(fixedSize(Constraints{.minW = 340, .minH = 380, .maxW = 340, .maxH = 380}));   // About This Computer
    EXPECT_TRUE(fixedSize(Constraints{.minW = 341, .minH = 381, .maxW = 340, .maxH = 380}));   // a minimum above the maximum
    EXPECT_FALSE(fixedSize(Constraints{.minW = 340, .minH = 200, .maxW = 340, .maxH = 0}));    // the Store's settings: fixed width
    EXPECT_FALSE(fixedSize(Constraints{.minW = 340, .minH = 200, .maxW = 340, .maxH = 900}));  // a height range
    EXPECT_FALSE(fixedSize(Constraints{.minW = 200, .minH = 380, .maxW = 800, .maxH = 380}));  // a width range
    EXPECT_FALSE(fixedSize(Constraints{}));                                                    // no limits at all
    EXPECT_FALSE(fixedSize(Constraints{.minW = 1, .minH = 1, .maxW = 0, .maxH = 0}));
    const std::array<StateOutput, 0> none{};
    const std::array<uint64_t, 1>    fixed{0xab0};
    EXPECT_EQ(stateJson(6, none, nullptr, {}, {}, fixed), R"({"v":"gfc/1","type":"tiling","gen":6,"outputs":[],"splits":[],"unfit":[],"fixed":["ab0"],"unfitZones":[],"suggestion":null})");
}

// ADR-0040 step 1b's review: Super+Alt+F zoomed About This Computer to 1918x980 and Super+Ctrl+F made it full screen in
// nested, while the Window menu greys Zoom and Enter Full Screen for a window of fixed size. The keys ask window_size: the
// modes by Hyprland's names only, and a window of fixed size only leaves the mode it is in.
TEST(TilingFixed, TheFullScreenAndZoomKeysLeaveAWindowOfFixedSizeAlone) {
    EXPECT_EQ(parseSizeMode("fullscreen"), SizeMode::Fullscreen);
    EXPECT_EQ(parseSizeMode("maximized"), SizeMode::Maximized);
    for (const auto* bad : {"", "Fullscreen", "maximised", "fullscreen ", "zoom", "fullscreenstate"})
        EXPECT_FALSE(parseSizeMode(bad).has_value()) << '"' << bad << '"';
    EXPECT_FALSE(sizeKeyActs(true, false)) << "About This Computer: no Zoom, no Enter Full Screen";
    EXPECT_TRUE(sizeKeyActs(true, true)) << "zoomed or in full screen anyway: Unzoom, Exit Full Screen";
    EXPECT_TRUE(sizeKeyActs(false, false)) << "a resizable window zooms";
    EXPECT_TRUE(sizeKeyActs(false, true)) << "and unzooms";
}

// ADR-0036 D78 (owner report on rc1-16: a maximized foot window glued under the menu bar and against the left edge, in
// Hyprland's maximized mode): Grassfield's Zoom fills the window as a tile, with the margins, and a second Zoom brings back
// its box from before, as macOS 15+ fills from the title bar.
TEST(TilingZoom, ZoomFillsAndBringsBackThePreviousBox) {
    const ZoomFacts plain{.tiling = true};
    EXPECT_EQ(zoomStep(plain), ZoomStep::Fill) << "a plain window fills (its margins: the work area's, TL2)";
    EXPECT_EQ(zoomStep(ZoomFacts{.tiling = true, .filled = true}), ZoomStep::Previous) << "a filled window goes back to its box from before";
    EXPECT_EQ(zoomStep(ZoomFacts{.tiling = true, .atFill = true}), ZoomStep::Unfill)
        << "at the Fill frame after a plugin reload (no record, no box from before): the Center place's frame";
    EXPECT_EQ(zoomStep(ZoomFacts{.tiling = true, .filled = true, .atFill = true}), ZoomStep::Previous) << "a record wins";
}

TEST(TilingZoom, HyprlandsMaximizedModeLeavesIntoFill) {
    EXPECT_EQ(zoomStep(ZoomFacts{.tiling = true, .maximized = true}), ZoomStep::UnzoomToFill)
        << "a window in Hyprland's maximized mode (a dispatcher, an earlier plugin, client chrome zoomed before the plugin "
           "owned its requests) leaves it into Fill";
    EXPECT_EQ(zoomStep(ZoomFacts{.tiling = true, .maximized = true, .filled = true}), ZoomStep::UnzoomToFill)
        << "a tile suspended by the maximized mode is filled, not sent back";
    EXPECT_EQ(zoomStep(ZoomFacts{.tiling = true, .maximized = true, .fixedSize = true}), ZoomStep::Hyprland) << "a window of fixed size only unzooms";
}

TEST(TilingZoom, WithoutWindowTilingTheZoomIsHyprlandsAsBefore) {
    // Gate C2: no plugin, a degraded one (window-tiling not advertised), or the session locked.
    for (const bool maximized : {false, true}) {
        for (const bool filled : {false, true}) {
            for (const bool atFill : {false, true})
                EXPECT_EQ(zoomStep(ZoomFacts{.maximized = maximized, .filled = filled, .atFill = atFill}), ZoomStep::Hyprland)
                    << "maximized " << maximized << " filled " << filled << " at the Fill frame " << atFill;
        }
    }
    EXPECT_EQ(zoomStep(ZoomFacts{.fixedSize = true}), ZoomStep::Refused) << "a window of fixed size is refused with or without the plugin's tiling";
}

TEST(TilingZoom, FullScreenSplitViewAndFixedSize) {
    EXPECT_EQ(zoomStep(ZoomFacts{.tiling = true, .fullscreen = true}), ZoomStep::Hyprland) << "full screen keeps Hyprland's toggle";
    EXPECT_EQ(zoomStep(ZoomFacts{.tiling = true, .splitMember = true}), ZoomStep::Hyprland) << "D50: a member's zoom keeps its half";
    EXPECT_EQ(zoomStep(ZoomFacts{.tiling = true, .splitMember = true, .filled = true}), ZoomStep::Hyprland);
    EXPECT_EQ(zoomStep(ZoomFacts{.tiling = true, .fixedSize = true}), ZoomStep::Refused) << "ADR-0040 step 1b: its zoom light is disabled";
    EXPECT_EQ(zoomStep(ZoomFacts{.tiling = true, .fullscreen = true, .fixedSize = true}), ZoomStep::Hyprland);
    for (const auto step : {ZoomStep::Fill, ZoomStep::Previous, ZoomStep::UnzoomToFill, ZoomStep::Hyprland, ZoomStep::Refused, ZoomStep::Unfill})
        EXPECT_NE(nameOf(step), "?");
}

// TL33, ADR-0036 D50, D52: the members are the Split View's two windows, whatever their state; a window that left its
// workspace is no member any more; another window there never was one.
TEST(TilingSplit, MembersFollowTheirWorkspace) {
    std::vector<SplitDesk> splits{{.workspace = 7, .output = "GF-REF", .home = 2, .members = {0xa1, 0xb2}}, {.workspace = 9, .output = "GF-REF", .home = 2, .members = {0xc3}}};
    ASSERT_NE(splitOfWindow(splits, 0xb2), nullptr);
    EXPECT_EQ(splitOfWindow(splits, 0xb2)->workspace, 7);
    EXPECT_EQ(splitOfWindow(splits, 0xc3)->workspace, 9);
    EXPECT_EQ(splitOfWindow(splits, 0xd4), nullptr) << "a third window on the Desktop is no member";
    EXPECT_EQ(splitOfWindow({}, 0xa1), nullptr);
    EXPECT_FALSE(pruneMembers(splits[0], std::vector<uint64_t>{0xd4, 0xb2, 0xa1})) << "both still there, a third one too";
    EXPECT_EQ(splits[0].members, (std::vector<uint64_t>{0xa1, 0xb2})) << "the order kept";
    EXPECT_TRUE(pruneMembers(splits[0], std::vector<uint64_t>{0xb2, 0xd4}));
    EXPECT_EQ(splits[0].members, (std::vector<uint64_t>{0xb2}));
    EXPECT_TRUE(pruneMembers(splits[0], std::vector<uint64_t>{}));
    EXPECT_TRUE(splits[0].members.empty());
}

// MAJOR C of the nested pass of 1ee992e: a window whose minimum does not fit its half is refused (no overlap); the band counts
// in the height; the event says whether the window fits (the popover greys the halves).
TEST(TilingSplit, AWindowTooWideForAHalfDoesNotFit) {
    const auto& zones = layoutById("left-right")->zones;
    const Area  one   = splitArea(Rect{0, 0, 1920, 1080}, Grid{0, 0, 1});
    const Rect  half  = zoneFrame(zones[0], one); // 956 x 1080
    EXPECT_TRUE(fitsFrame(Constraints{}, half));
    EXPECT_TRUE(fitsFrame(Constraints{.minW = 956, .minH = 1050, .band = 30}, half)) << "exactly the half";
    EXPECT_FALSE(fitsFrame(Constraints{.minW = 1200, .minH = 400}, half)) << "the nested case: 1200 on a 956 half";
    EXPECT_FALSE(fitsFrame(Constraints{.minW = 957, .minH = 1}, half));
    EXPECT_FALSE(fitsFrame(Constraints{.minW = 400, .minH = 1060, .band = 30}, half)) << "the band takes height";
    EXPECT_EQ(tileHoverJson(0xabc, HoverState::Open, Rect{1, 2, 3, 4}, true, true),
              R"({"v":"gfc/1","type":"tile-hover","address":"abc","state":"open","x":1,"y":2,"w":3,"h":4,"tileable":true,"splittable":true,"unfitZones":[],"unfitPlaces":[]})");
}

// ADR-0036 D69 (capture defect of 2026-10-30): Quarters at 1440 x 900 with Settings (minimum 560 x 420, its own chrome) came
// out with shifted rows. The plugin now offers a window only the zones it fits: the capture's work area (menu bar 24, Dock 82,
// margins on) gives quarters 385 px tall, so Settings fits the left and right halves and not one quarter, the top or bottom
// half, nor a third.
TEST(TilingFitZone, TheCaptureCaseFitsTheHalvesAndNoQuarter) {
    const Area        area{Rect{0, 24, 1440, 794}, kMargin, Grid{0, 0, 1}};
    const Constraints settings{.minW = 560, .minH = 420};
    for (const auto& z : layoutById("quarters")->zones) {
        EXPECT_FALSE(fitsZone(settings, z, area)) << zoneName(z);
        EXPECT_LT(zoneFrame(z, area).h, 420) << "a quarter is shorter than its minimum";
    }
    EXPECT_TRUE(fitsZone(settings, zoneOf(Place::Left).value_or(Zone{}), area));
    EXPECT_TRUE(fitsZone(settings, zoneOf(Place::Right).value_or(Zone{}), area));
    EXPECT_FALSE(fitsZone(settings, zoneOf(Place::Top).value_or(Zone{}), area));
    EXPECT_FALSE(fitsZone(settings, zoneOf(Place::LeftThird).value_or(Zone{}), area));
    const auto unfit = unfitZones(settings, area);
    const auto has   = [&unfit](std::string_view name) { return std::ranges::find(unfit, name) != unfit.end(); };
    for (const auto* name : {"0,0,6,6", "6,0,6,6", "0,6,6,6", "6,6,6,6", "0,0,12,6", "0,6,12,6", "0,0,4,12"})
        EXPECT_TRUE(has(name)) << name;
    for (const auto* name : {"0,0,6,12", "6,0,6,12", "0,0,8,12", "4,0,8,12", "3,0,6,12"})
        EXPECT_FALSE(has(name)) << name << " fits";
    EXPECT_FALSE(has("0,0,12,12")) << "Fill is always offered";
    // A small window fits every zone: nothing listed; the event says so with an empty list.
    EXPECT_TRUE(unfitZones(Constraints{.minW = 200, .minH = 150, .band = kBar}, area).empty());
    EXPECT_EQ(tileHoverJson(0xabc, HoverState::Enter, Rect{1, 2, 3, 4}, true, true, std::array<std::string, 2>{"0,0,6,6", "6,0,6,6"}),
              R"({"v":"gfc/1","type":"tile-hover","address":"abc","state":"enter","x":1,"y":2,"w":3,"h":4,"tileable":true,"splittable":true,)"
              R"("unfitZones":["0,0,6,6","6,0,6,6"],"unfitPlaces":[]})");
    EXPECT_EQ(tileHoverJson(0xabc, HoverState::Leave, Rect{1, 2, 3, 4}, true, true, std::array<std::string, 1>{"0,0,6,6"}),
              R"({"v":"gfc/1","type":"tile-hover","address":"abc","state":"leave"})")
        << "leave carries nothing else";
}

// D69: the zones offered are the places' and the catalogue's, each once, named as the shell's glyph tokens; with every one
// listed the event still fits Hyprland's 1024-byte cut; the reply lists the windows that do not fit some zone.
TEST(TilingFitZone, EveryOfferedZoneOnceAndTheEventStaysSmall) {
    const auto zones = offeredZones();
    for (size_t i = 0; i < zones.size(); ++i) {
        EXPECT_NE(zones[i], Zone{}) << "not Fill's whole area";
        for (size_t j = i + 1; j < zones.size(); ++j)
            EXPECT_NE(zones[i], zones[j]) << zoneName(zones[i]) << " twice";
    }
    for (const auto& l : catalogue()) {
        for (const auto& z : l.zones)
            EXPECT_NE(std::ranges::find(zones, z), zones.end()) << l.id << " " << zoneName(z);
    }
    for (const auto p : {Place::Left, Place::BottomRight, Place::MiddleThird, Place::RightTwoThirds})
        EXPECT_NE(std::ranges::find(zones, zoneOf(p).value_or(Zone{})), zones.end()) << nameOf(p);
    EXPECT_EQ(zoneName(Zone{0, 6, 12, 6}), "0,6,12,6");
    const Area huge{Rect{0, 0, 800, 600}, kMargin, Grid{0, 0, 1}};
    const auto all = unfitZones(Constraints{.minW = 5000, .minH = 5000}, huge);
    EXPECT_EQ(all.size(), zones.size()) << "too large for every zone";
    const auto places = unfitPlaces(Constraints{.minW = 5000, .minH = 5000}, huge);
    EXPECT_EQ(places.size(), 13U) << "every place but Fill and Center";
    EXPECT_LT(tileHoverJson(UINT64_MAX, HoverState::Enter, Rect{-99999.5, -99999.5, 99999.5, 99999.5}, true, true, all, places).size(), gf::gfc::kMaxEventBytes);
    const std::array<StateOutput, 0> none{};
    const std::array<WindowFit, 1>   fits{WindowFit{.address = 0xa1, .zones = {"0,0,6,6", "0,0,12,6"}, .places = {"top-left"}}};
    EXPECT_EQ(stateJson(5, none, nullptr, {}, {}, {}, fits),
              R"({"v":"gfc/1","type":"tiling","gen":5,"outputs":[],"splits":[],"unfit":[],"fixed":[],"unfitZones":[{"address":"a1","zones":["0,0,6,6","0,0,12,6"],"places":["top-left"]}],"suggestion":null})");
}

// D69, review MINOR 1: a place is checked on the frame tile() applies (placeStartFrame), which for a half next to a tiled
// neighbour is the rest beside it (TL7), narrower than the half zone an arrangement uses. A window 600 px wide at least, at
// 1440 x 900 with a window in the right two thirds: the Left place does not fit (471 px left) while the half zone, and so
// Left & Right, still does (708 px).
TEST(TilingFitZone, APlaceIsCheckedOnTheFrameTileApplies) {
    const Area                  area{Rect{0, 24, 1440, 794}, kMargin, Grid{0, 0, 1}};
    const Rect                  twoThirds = zoneFrame(zoneOf(Place::RightTwoThirds).value_or(Zone{}), area);
    const std::array<Rect, 1>   neighbours{twoThirds};
    const Constraints           wide{.minW = 600, .minH = 300, .band = kBar};
    const Rect                  half   = zoneFrame(zoneOf(Place::Left).value_or(Zone{}), area);
    const Rect                  beside = placeStartFrame(Place::Left, area, neighbours);
    EXPECT_EQ(beside, halfBesideNeighbour(Place::Left, area, neighbours).value_or(Rect{})) << "the frame tile() gives";
    EXPECT_DOUBLE_EQ(beside.w, 471);
    EXPECT_DOUBLE_EQ(half.w, 708);
    EXPECT_EQ(placeStartFrame(Place::Left, area), half) << "no neighbour: the half zone";
    EXPECT_EQ(placeStartFrame(Place::TopLeft, area, neighbours), zoneFrame(zoneOf(Place::TopLeft).value_or(Zone{}), area)) << "only halves look beside";
    const auto places = unfitPlaces(wide, area, neighbours);
    const auto zones  = unfitZones(wide, area);
    const auto has    = [](const std::vector<std::string>& v, std::string_view name) { return std::ranges::find(v, name) != v.end(); };
    EXPECT_TRUE(has(places, "left")) << "471 px beside the neighbour";
    EXPECT_FALSE(has(places, "right")) << "nothing holds the left side: the half zone";
    EXPECT_FALSE(has(zones, "0,0,6,12")) << "the half zone itself fits: Left & Right is offered";
    EXPECT_FALSE(has(unfitPlaces(wide, area), "left")) << "without the neighbour Left fits";
    EXPECT_FALSE(has(places, "top-left")) << "a quarter (708 x 385) holds 600 x 300 and its band";
    EXPECT_TRUE(has(places, "left-third")) << "a third (471 px) does not";
}

// D69: members that fit their zones keep the catalogue's frames exactly (fitFrames moves nothing): Quarters is four equal
// quarters, the rows and the columns aligned, whatever their minimum below the quarter.
TEST(TilingFitZone, MembersThatFitKeepTheCatalogueFrames) {
    const Area                     area{Rect{0, 24, 1440, 794}, kMargin, Grid{0, 0, 1}};
    const auto&                    zones = layoutById("quarters")->zones;
    std::vector<Rect>              frames;
    std::vector<Constraints>       cons;
    for (const auto& z : zones) {
        frames.push_back(zoneFrame(z, area));
        cons.push_back(Constraints{.minW = 600, .minH = 360});
        ASSERT_TRUE(fitsZone(cons.back(), z, area)) << zoneName(z);
    }
    const auto fit = fitFrames(zones, frames, cons, area);
    for (size_t i = 0; i < fit.size(); ++i)
        EXPECT_EQ(fit[i], frames[i]) << zoneName(zones[i]);
    EXPECT_DOUBLE_EQ(fit[0].y + fit[0].h, fit[1].y + fit[1].h) << "the top row ends on one line";
    EXPECT_DOUBLE_EQ(fit[2].y, fit[3].y) << "the bottom row starts on one line";
    EXPECT_DOUBLE_EQ(fit[0].x + fit[0].w, fit[2].x + fit[2].w) << "the left column ends on one line";
}

// Step 6b (TL33): the separator is the shared edge between the two members of a Split View Desktop, one on each side.
TEST(TilingSplit, TheSeparatorIsTheEdgeBetweenTheTwoMembers) {
    const std::array<SplitDesk, 2> splits{SplitDesk{.workspace = 7, .output = "GF-REF", .home = 2, .members = {0xa1, 0xb2}},
                                          SplitDesk{.workspace = 9, .output = "GF-REF", .home = 2, .members = {0xc3}, .waiting = true}};
    const auto edge = [](std::vector<uint64_t> before, std::vector<uint64_t> after) {
        return SharedEdge{.vertical = true, .group = 1, .at = 960, .gap = 8, .before = std::move(before), .after = std::move(after), .handles = {}};
    };
    ASSERT_NE(splitOfEdge(splits, edge({0xa1}, {0xb2})), nullptr);
    EXPECT_EQ(splitOfEdge(splits, edge({0xa1}, {0xb2}))->workspace, 7);
    EXPECT_EQ(splitOfEdge(splits, edge({0xb2}, {0xa1}))->workspace, 7) << "either member on either side";
    EXPECT_EQ(splitOfEdge(splits, edge({0xa1}, {0xd4})), nullptr) << "a member and another window";
    EXPECT_EQ(splitOfEdge(splits, edge({0xd4}, {0xe5})), nullptr) << "an ordinary tile group";
    EXPECT_EQ(splitOfEdge(splits, edge({0xa1, 0xd4}, {0xb2})), nullptr) << "more than the two members";
    EXPECT_EQ(splitOfEdge(splits, edge({0xa1}, {0xb2, 0xd4})), nullptr) << "more than one window after it";
    EXPECT_EQ(splitOfEdge(splits, edge({0xc3}, {0xc3})), nullptr) << "a Split View with one member has no separator";
    EXPECT_EQ(splitOfEdge(splits, edge({}, {0xb2})), nullptr);
}

// Step 6b (TL33): a member's titlebar drag released over the other half swaps the two; anywhere else it goes back.
TEST(TilingSplit, ADropOnTheOtherHalfSwapsTheMembers) {
    const Rect left{0, 0, 956, 1080};
    const Rect right{964, 0, 956, 1080};
    EXPECT_EQ(splitDropZone(left, right, 0, 1400, 500), 1) << "the left member dropped on the right half";
    EXPECT_EQ(splitDropZone(left, right, 1, 100, 500), 0) << "the right member dropped on the left half";
    EXPECT_EQ(splitDropZone(left, right, 0, 100, 500), std::nullopt) << "on its own half: back in it";
    EXPECT_EQ(splitDropZone(left, right, 0, 960, 500), std::nullopt) << "on the separator: back";
    EXPECT_EQ(splitDropZone(left, right, 0, 964, 0), 1) << "the other half's top-left corner";
    EXPECT_EQ(splitDropZone(left, right, 0, 1920, 500), std::nullopt) << "past its right side";
    EXPECT_EQ(splitDropZone(left, right, 0, 1400, 1080), std::nullopt) << "below it";
    EXPECT_EQ(splitDropZone(left, right, 0, 1400, -0.5), std::nullopt) << "above it";
    EXPECT_EQ(splitDropZone(left, right, 0, 963.5, 500), std::nullopt) << "left of it (on the separator)";
    EXPECT_EQ(splitDropZone(left, right, 1, 955.9, 1079.9), 0);
    EXPECT_EQ(splitDropZone(left, right, 2, 1400, 500), std::nullopt) << "no half of a Split View";
    EXPECT_EQ(splitDropZone(left, right, -1, 100, 500), std::nullopt);
}

// TL10, and the integrator review of e352f7c (step 6b): reconcile forgets a record whose window is gone, or a Tiled one moved
// by other means, but never the Split View member whose titlebar drag is under way (it is placed at its drop).
TEST(TilingBook, AStaleRecordIsForgottenButNotTheDraggedMember) {
    TileRecord r;
    r.id    = 0xa1;
    r.state = TileState::Tiled;
    EXPECT_TRUE(staleRecord(r, false, true, 0)) << "its window gone or unmapped";
    EXPECT_TRUE(staleRecord(r, false, true, 0xa1)) << "gone, even while dragged";
    EXPECT_FALSE(staleRecord(r, true, true, 0)) << "at its box";
    EXPECT_TRUE(staleRecord(r, true, false, 0)) << "moved by other means";
    EXPECT_TRUE(staleRecord(r, true, false, 0xb2)) << "another window is dragged";
    EXPECT_FALSE(staleRecord(r, true, false, 0xa1)) << "the member being dragged keeps its record";
    r.relayout = true;
    EXPECT_FALSE(staleRecord(r, true, false, 0)) << "it waits for a relayout";
    r.relayout = false;
    for (const auto state : {TileState::Moving, TileState::Resizing, TileState::Suspended}) {
        r.state = state;
        EXPECT_FALSE(staleRecord(r, true, false, 0)) << "only a Tiled record is checked against its box";
    }
}

// D43: two members stay; one fills alone unless it is still choosing its second window; none ends the Desktop.
TEST(TilingSplit, OneMemberFillsNoneEnds) {
    EXPECT_EQ(splitStep(2, false), SplitStep::Keep);
    EXPECT_EQ(splitStep(2, true), SplitStep::Keep);
    EXPECT_EQ(splitStep(1, false), SplitStep::Fill);
    EXPECT_EQ(splitStep(1, true), SplitStep::Keep) << "its picker is still pending";
    EXPECT_EQ(splitStep(0, false), SplitStep::End);
    EXPECT_EQ(splitStep(0, true), SplitStep::End);
    EXPECT_EQ(splitStep(3, false), SplitStep::Keep);
}
