// A window's titlebar never goes under the menu bar (macOS; owner report from the 1.0.0-rc1 real session: Chromium dragged
// up until its tab strip was under the menu bar could not be grabbed again). Test names state the user-visible rule.

#include "core/TopClamp.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cstddef>
#include <optional>

namespace {
    using gf::topclamp::Output;
    using gf::topclamp::Point;
    using gf::topclamp::Rect;

    // Two outputs side by side, the left one 1920x1080 with a 32 px menu bar, the right one 2560x1440 at x 1920 with a
    // 24 px menu bar; and a third one under the left one (no menu bar of its own: a 0 px reserved area).
    constexpr std::array<Output, 3> kOutputs{
        Output{Rect{0, 0, 1920, 1080}, 32},
        Output{Rect{1920, 0, 2560, 1440}, 24},
        Output{Rect{0, 1080, 1920, 1080}, 1080},
    };
    constexpr size_t kNone = 99; // "no output" in the comparisons below

    constexpr double kBand = 32; // the plugin's titlebar above the surface
} // namespace

TEST(TopClamp, AWindowDraggedUnderTheMenuBarStopsJustBelowIt) {
    // The plugin's titlebar would start at y = 20 - 32 = -12: the frame starts at the menu bar's bottom instead.
    const Rect moved = gf::topclamp::afterMove(Rect{300, 20, 800, 600}, kBand, kOutputs[0]);
    EXPECT_DOUBLE_EQ(moved.y, 32 + kBand) << "the titlebar starts at the menu bar's bottom";
    EXPECT_DOUBLE_EQ(moved.x, 300) << "only the top is held";
    EXPECT_DOUBLE_EQ(moved.w, 800);
    EXPECT_DOUBLE_EQ(moved.h, 600) << "a move keeps the size";
}

TEST(TopClamp, AnAppThatDrawsItsOwnTitlebarIsHeldByItsSurfaceTop) {
    // Client chrome (Chromium's tab strip): no band, the surface top itself stays below the menu bar.
    const Rect moved = gf::topclamp::afterMove(Rect{300, 5, 1382, 798}, 0, kOutputs[0]);
    EXPECT_DOUBLE_EQ(moved.y, 32);
    const Rect above = gf::topclamp::afterMove(Rect{300, -200, 1382, 798}, 0, kOutputs[0]);
    EXPECT_DOUBLE_EQ(above.y, 32) << "dragged above the output too";
}

TEST(TopClamp, AWindowBelowTheMenuBarIsLeftAlone) {
    const Rect fine{300, 64, 800, 600};
    EXPECT_FALSE(gf::topclamp::changed(gf::topclamp::afterMove(fine, kBand, kOutputs[0]), fine)) << "exactly at the menu bar";
    const Rect lower{300, 400, 800, 600};
    EXPECT_FALSE(gf::topclamp::changed(gf::topclamp::afterMove(lower, kBand, kOutputs[0]), lower));
    const Rect offBottom{300, 900, 800, 600};
    EXPECT_FALSE(gf::topclamp::changed(gf::topclamp::afterMove(offBottom, kBand, kOutputs[0]), offBottom)) << "a window may hang off the bottom";
    const Rect fraction{300, 63.6, 800, 600};
    EXPECT_FALSE(gf::topclamp::changed(gf::topclamp::afterMove(fraction, kBand, kOutputs[0]), fraction)) << "rounding is not a move";
}

TEST(TopClamp, EachOutputHasItsOwnMenuBar) {
    // The frame's top edge is on the right output, whose menu bar is 24 px high.
    const Rect frame{2000, -10, 900, 632};
    const size_t index = gf::topclamp::outputFor(frame, Point{2300, 5}, kOutputs).value_or(kNone);
    ASSERT_EQ(index, 1U);
    const Rect moved = gf::topclamp::afterMove(Rect{2000, 22, 900, 600}, kBand, kOutputs.at(index));
    EXPECT_DOUBLE_EQ(moved.y, 24 + kBand);
}

TEST(TopClamp, TheOutputUnderTheTopEdgeHoldsTheWindow) {
    // A window dragged by its titlebar from the lower output up into the upper one: once its top edge is on the upper
    // output, that output's menu bar holds it, not the lower output's top.
    const Rect frame{100, 1050, 800, 632};
    const size_t upper = gf::topclamp::outputFor(frame, Point{400, 1070}, kOutputs).value_or(kNone);
    ASSERT_EQ(upper, 0U);
    EXPECT_FALSE(gf::topclamp::changed(gf::topclamp::heldMove(Rect{100, 1082, 800, 600}, kBand, Point{400, 1095}, kOutputs), Rect{100, 1082, 800, 600}));
    // The top edge across two outputs: the one sharing most of its width.
    EXPECT_EQ(gf::topclamp::outputFor(Rect{1500, 10, 1000, 300}, Point{-500, -500}, kOutputs).value_or(kNone), 1U);
    EXPECT_EQ(gf::topclamp::outputFor(Rect{1200, 10, 1000, 300}, Point{-500, -500}, kOutputs).value_or(kNone), 0U);
    // Above every output: the nearest output below the top edge (the pointer plays no part).
    EXPECT_EQ(gf::topclamp::outputFor(Rect{2100, -300, 400, 300}, Point{100, 1500}, kOutputs).value_or(kNone), 1U);
    // Above two outputs whose tops are level: the one sharing most of the top edge's width, whatever their order (review
    // of 9ba1d40: the lowest index won).
    constexpr std::array<Output, 2> kLevel{Output{Rect{0, 100, 1000, 800}, 124}, Output{Rect{1000, 100, 1000, 800}, 132}};
    EXPECT_EQ(gf::topclamp::outputFor(Rect{900, 20, 600, 300}, Point{-500, -500}, kLevel).value_or(kNone), 1U) << "100 px on the first, 500 on the second";
    EXPECT_EQ(gf::topclamp::outputFor(Rect{500, 20, 600, 300}, Point{-500, -500}, kLevel).value_or(kNone), 0U) << "500 px on the first, 100 on the second";
    constexpr std::array<Output, 2> kLevelSwapped{kLevel[1], kLevel[0]};
    EXPECT_EQ(gf::topclamp::outputFor(Rect{900, 20, 600, 300}, Point{-500, -500}, kLevelSwapped).value_or(kNone), 0U) << "the same output in either order";
    const auto held = gf::topclamp::afterDrag(Rect{900, 400, 600, 300}, Rect{900, 20, 600, 300}, false, 0, Point{1200, 150}, kLevel);
    EXPECT_DOUBLE_EQ(held.value_or(Rect{}).y, 132) << "below the menu bar of the output sharing most of the width";
    // Nowhere near an output: the pointer, else nothing.
    EXPECT_EQ(gf::topclamp::outputFor(Rect{-900, -900, 100, 100}, Point{100, 1500}, kOutputs).value_or(kNone), 2U);
    EXPECT_FALSE(gf::topclamp::outputFor(Rect{-900, -900, 100, 100}, Point{-500, -500}, kOutputs).has_value()) << "nowhere: no clamp";
}

TEST(TopClamp, ASliverOnAHigherOutputDoesNotLeaveTheTitlebarAboveTheLowerOne) {
    // Two outputs side by side, the right one set 300 px lower: a window of the right one dragged up with 20 px of its top
    // edge on the left one stayed there, its titlebar in the dead space above the right output.
    constexpr std::array<Output, 2> kOffset{Output{Rect{0, 0, 1920, 1080}, 32}, Output{Rect{1920, 300, 1280, 720}, 324}};
    EXPECT_EQ(gf::topclamp::outputFor(Rect{1900, 200, 800, 632}, Point{1910, 210}, kOffset).value_or(kNone), 1U) << "20 px on the left output";
    EXPECT_DOUBLE_EQ(gf::topclamp::heldMove(Rect{1900, 232, 800, 600}, kBand, Point{1910, 210}, kOffset).y, 324 + kBand);
    EXPECT_EQ(gf::topclamp::outputFor(Rect{1919, 200, 800, 632}, Point{-500, -500}, kOffset).value_or(kNone), 1U) << "1 px";
    // Enough of the titlebar on the higher output to grab it: that output holds the window, as before.
    EXPECT_EQ(gf::topclamp::outputFor(Rect{1820, 200, 800, 632}, Point{-500, -500}, kOffset).value_or(kNone), 0U) << "100 px on the left output";
    // A sliver on an output with nothing more below it: still that output (a window may hang off a side).
    EXPECT_EQ(gf::topclamp::outputFor(Rect{-780, 200, 800, 632}, Point{-500, -500}, kOffset).value_or(kNone), 0U);
    EXPECT_EQ(gf::topclamp::outputFor(Rect{-780, 200, 800, 632}, Point{-500, -500}, kOutputs).value_or(kNone), 0U) << "the output below shares no more";
}

// Review of e0a3734: the output under the POINTER decided, and a window sitting correctly on an upper output was moved
// or cut at the release of a SUPER+drag or a resize that ended with the pointer on another output.
namespace {
    // Two 1920x1080 outputs stacked, a 24 px menu bar on each.
    constexpr std::array<Output, 2> kStacked{Output{Rect{0, 0, 1920, 1080}, 24}, Output{Rect{0, 1080, 1920, 1080}, 1104}};
    // A 2560x1440 output and a 1920x1080 one to its right, bottom edges aligned (the right one starts at y 360).
    constexpr std::array<Output, 2> kBottomAligned{Output{Rect{0, 0, 2560, 1440}, 24}, Output{Rect{2560, 360, 1920, 1080}, 384}};
} // namespace

TEST(TopClamp, ASuperDragEndingWithThePointerOnTheLowerOutputLeavesTheWindowAlone) {
    // SUPER+LMB grips the window anywhere: its top is on the upper output, the pointer near its bottom on the lower one.
    const Rect after{200, 500, 800, 900};
    EXPECT_FALSE(gf::topclamp::afterDrag(Rect{200, 300, 800, 900}, after, false, 0, Point{600, 1300}, kStacked).has_value()) << "was y 500 -> 1104";
    EXPECT_FALSE(gf::topclamp::afterDrag(Rect{1500, 100, 1000, 800}, Rect{1800, 200, 1000, 800}, false, 0, Point{2700, 600}, kBottomAligned).has_value());
    EXPECT_FALSE(gf::topclamp::afterDrag(std::nullopt, after, false, 0, Point{600, 1300}, kStacked).has_value()) << "start unknown: same rule for a move";
}

TEST(TopClamp, AResizeFromTheBottomOrASideEdgeNeverMovesTheWindow) {
    // Bottom edge dragged down onto the lower output (stacked): the top did not move.
    const Rect taller{200, 500, 800, 1300};
    EXPECT_FALSE(gf::topclamp::afterDrag(Rect{200, 500, 800, 900}, taller, true, 0, Point{600, 1800}, kStacked).has_value()) << "was y 500 -> 1104, h 900 -> 296";
    // Right edge dragged onto the right output (bottom-aligned outputs).
    const Rect wider{1800, 200, 1000, 800};
    EXPECT_FALSE(gf::topclamp::afterDrag(Rect{1800, 200, 700, 800}, wider, true, 0, Point{2700, 600}, kBottomAligned).has_value()) << "was y 200 -> 384, h 800 -> 616";
    // Even a window whose top is under the menu bar (placed there by the app): a bottom-edge resize leaves it.
    const Rect high{300, 5, 800, 700};
    EXPECT_FALSE(gf::topclamp::afterDrag(Rect{300, 5, 800, 600}, high, true, kBand, Point{600, 700}, kOutputs).has_value());
    // A resize whose start was never seen moving is left alone.
    EXPECT_FALSE(gf::topclamp::afterDrag(std::nullopt, Rect{300, 5, 800, 700}, true, kBand, Point{600, 5}, kOutputs).has_value());
}

TEST(TopClamp, AResizeThatMovedTheTopEdgeUnderTheMenuBarStopsIt) {
    // The top edge dragged up under the menu bar of the output it is on: held, the bottom edge kept.
    const auto held = gf::topclamp::afterDrag(Rect{300, 200, 800, 500}, Rect{300, 10, 800, 690}, true, kBand, Point{600, 10}, kOutputs);
    ASSERT_TRUE(held.has_value());
    EXPECT_DOUBLE_EQ(held.value_or(Rect{}).y, 32 + kBand);
    EXPECT_DOUBLE_EQ(held.value_or(Rect{}).y + held.value_or(Rect{}).h, 700);
    // On the lower of two stacked outputs, the top edge into its menu bar strip: held below that menu bar.
    const auto lower = gf::topclamp::afterDrag(Rect{200, 1300, 800, 500}, Rect{200, 1090, 800, 710}, true, 0, Point{600, 1090}, kStacked);
    ASSERT_TRUE(lower.has_value());
    EXPECT_DOUBLE_EQ(lower.value_or(Rect{}).y, 1104);
    // Further up, onto the upper output: below the upper output's menu bar, nothing to hold.
    EXPECT_FALSE(gf::topclamp::afterDrag(Rect{200, 1300, 800, 500}, Rect{200, 1000, 800, 800}, true, 0, Point{600, 1000}, kStacked).has_value());
}

TEST(TopClamp, AMoveThatLeftTheTitlebarUnderAMenuBarIsHeld) {
    // An app's move request (Chromium's tab strip, no band) released with the strip under the lower output's menu bar.
    const auto lower = gf::topclamp::afterDrag(Rect{200, 1500, 800, 600}, Rect{200, 1090, 800, 600}, false, 0, Point{500, 1100}, kStacked);
    ASSERT_TRUE(lower.has_value());
    EXPECT_DOUBLE_EQ(lower.value_or(Rect{}).y, 1104);
    EXPECT_DOUBLE_EQ(lower.value_or(Rect{}).h, 600) << "a move keeps the size";
    // Above the top of the upper output.
    const auto upper = gf::topclamp::afterDrag(Rect{200, 300, 800, 600}, Rect{200, -40, 800, 600}, false, 0, Point{500, 5}, kStacked);
    ASSERT_TRUE(upper.has_value());
    EXPECT_DOUBLE_EQ(upper.value_or(Rect{}).y, 24);
    // Bottom-aligned outputs: a top edge above the right output and off the left one is out of reach: held below the
    // right output's menu bar.
    const auto right = gf::topclamp::afterDrag(Rect{3000, 600, 800, 600}, Rect{3000, 200, 800, 600}, false, 0, Point{3400, 400}, kBottomAligned);
    ASSERT_TRUE(right.has_value());
    EXPECT_DOUBLE_EQ(right.value_or(Rect{}).y, 384);
}

TEST(TopClamp, AResizeStopsTheTopEdgeAtTheMenuBar) {
    // The top edge dragged up under the menu bar: it stops there, the bottom edge stays.
    const Rect resized = gf::topclamp::afterResize(Rect{300, 10, 800, 700}, kBand, kOutputs[0]);
    EXPECT_DOUBLE_EQ(resized.y, 64);
    EXPECT_DOUBLE_EQ(resized.y + resized.h, 710) << "the bottom edge does not move";
    EXPECT_DOUBLE_EQ(resized.x, 300);
    EXPECT_DOUBLE_EQ(resized.w, 800);
    const Rect tiny = gf::topclamp::afterResize(Rect{300, -400, 800, 420}, kBand, kOutputs[0]);
    EXPECT_GE(tiny.h, 1) << "never smaller than 1 px";
    const Rect fine{300, 100, 800, 700};
    EXPECT_FALSE(gf::topclamp::changed(gf::topclamp::afterResize(fine, kBand, kOutputs[0]), fine));
}

TEST(TopClamp, AnOutputWithoutAMenuBarHoldsAtItsTop) {
    // A reserved area of 0 px (no shell, or an output without the menu bar): the output's top edge.
    const Output bare{Rect{0, 0, 1920, 1080}, 0};
    const Rect moved = gf::topclamp::afterMove(Rect{300, 10, 800, 600}, kBand, bare);
    EXPECT_DOUBLE_EQ(moved.y, kBand);
}
