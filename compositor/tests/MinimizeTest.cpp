#include "core/Minimize.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cmath>
#include <limits>
#include <optional>
#include <span>
#include <vector>

using namespace gf::minimize;

namespace {
    constexpr double NaN = std::numeric_limits<double>::quiet_NaN();
    constexpr double Inf = std::numeric_limits<double>::infinity();

    // The nested dev layout: WAYLAND-1 1440x900 at (0,0), GF-REF 1920x1080 at (1440,0).
    constexpr std::array<Box, 2> MONITORS = {{{0, 0, 1440, 900}, {1440, 0, 1920, 1080}}};

    void expectBox(const Box& actual, const Box& expected, double eps = 1e-9) {
        EXPECT_NEAR(actual.x, expected.x, eps);
        EXPECT_NEAR(actual.y, expected.y, eps);
        EXPECT_NEAR(actual.w, expected.w, eps);
        EXPECT_NEAR(actual.h, expected.h, eps);
    }
} // namespace

TEST(MinimizeAddress, AcceptsHyprlandAddresses) {
    EXPECT_EQ(parseAddress("0x605cc1156d90"), 0x605cc1156d90ULL);
    EXPECT_EQ(parseAddress("605cc1156d90"), 0x605cc1156d90ULL);
    EXPECT_EQ(parseAddress("0X605CC1156D90"), 0x605cc1156d90ULL);
    EXPECT_EQ(parseAddress("ffffffffffffffff"), 0xffffffffffffffffULL);
}

TEST(MinimizeAddress, RejectsAnythingElse) {
    EXPECT_FALSE(parseAddress(""));
    EXPECT_FALSE(parseAddress("0x"));
    EXPECT_FALSE(parseAddress("0"));                  // null pointer
    EXPECT_FALSE(parseAddress("1ffffffffffffffff"));  // 17 digits
    EXPECT_FALSE(parseAddress("0x12 "));
    EXPECT_FALSE(parseAddress(" 0x12"));
    EXPECT_FALSE(parseAddress("-12"));
    EXPECT_FALSE(parseAddress("+12"));
    EXPECT_FALSE(parseAddress("12g"));
    EXPECT_FALSE(parseAddress("0x12\"); hl.dsp.exit() --"));
    EXPECT_FALSE(parseAddress(std::string_view("12\0ab", 5)));
}

TEST(MinimizeTarget, DockTileInsideAMonitorIsValid) {
    EXPECT_TRUE(isValidTarget({1440 + 900, 1080 - 70, 52, 52}, MONITORS));
    EXPECT_TRUE(isValidTarget({0, 0, 1, 1}, MONITORS));
    EXPECT_TRUE(isValidTarget({1440 - 52, 900 - 52, 52, 52}, MONITORS)); // flush with the bottom-right corner
    EXPECT_TRUE(isValidTarget({-0.5, 0, 52, 52}, MONITORS));             // within the 1 px tolerance
}

TEST(MinimizeTarget, RejectsOutsideStraddlingDegenerateAndNonFinite) {
    EXPECT_FALSE(isValidTarget({1440 - 20, 100, 52, 52}, MONITORS)); // straddles two monitors
    EXPECT_FALSE(isValidTarget({100, 880, 52, 52}, MONITORS));       // below WAYLAND-1
    EXPECT_FALSE(isValidTarget({-100, -100, 52, 52}, MONITORS));
    EXPECT_FALSE(isValidTarget({100, 100, 0, 0}, MONITORS)); // the shell's "no Dock" rectangle
    EXPECT_FALSE(isValidTarget({100, 100, -52, 52}, MONITORS));
    EXPECT_FALSE(isValidTarget({100, 100, 0.5, 52}, MONITORS));
    EXPECT_FALSE(isValidTarget({1500, 0, 1100, 100}, MONITORS)); // larger than kMaxTargetSide
    EXPECT_FALSE(isValidTarget({NaN, 100, 52, 52}, MONITORS));
    EXPECT_FALSE(isValidTarget({100, Inf, 52, 52}, MONITORS));
    EXPECT_FALSE(isValidTarget({100, 100, 52, NaN}, MONITORS));
    EXPECT_FALSE(isValidTarget({100, 100, 52, 52}, {}));                                // no monitors
    EXPECT_FALSE(isValidTarget({100, 100, 52, 52}, std::vector<Box>{{0, 0, NaN, 900}})); // broken monitor
}

TEST(MinimizeGeometry, FitInsideKeepsTheAspectRatioCentered) {
    // 702x530 window into a 52x52 tile: width-limited, centered vertically.
    const Box fit = fitInside({0, 0, 702, 530}, {100, 200, 52, 52});
    EXPECT_NEAR(fit.w, 52, 1e-9);
    EXPECT_NEAR(fit.h, 52.0 * 530 / 702, 1e-9);
    EXPECT_NEAR(fit.x, 100, 1e-9);
    EXPECT_NEAR(fit.y + (fit.h / 2), 226, 1e-9);
    // Tall window: height-limited, centered horizontally.
    const Box tall = fitInside({0, 0, 300, 600}, {0, 0, 50, 50});
    expectBox(tall, {12.5, 0, 25, 50});
    // Degenerate source: the target itself.
    expectBox(fitInside({0, 0, 0, 10}, {1, 2, 3, 4}), {1, 2, 3, 4});
}

TEST(MinimizeGeometry, LerpAndMapBox) {
    expectBox(lerp({0, 0, 100, 100}, {100, 200, 10, 20}, 0.0), {0, 0, 100, 100});
    expectBox(lerp({0, 0, 100, 100}, {100, 200, 10, 20}, 1.0), {100, 200, 10, 20});
    expectBox(lerp({0, 0, 100, 100}, {100, 200, 10, 20}, 0.5), {50, 100, 55, 60});
    // The shadow box around a 100x100 window, mapped onto a half-size window elsewhere.
    expectBox(mapBox({-10, -10, 120, 120}, {0, 0, 100, 100}, {500, 500, 50, 50}), {495, 495, 60, 60});
    expectBox(mapBox({1, 2, 3, 4}, {0, 0, 0, 0}, {10, 10, 5, 5}), {11, 12, 3, 4}); // degenerate source: translate only
}

TEST(MinimizeEasing, CubicBezierEndpointsAndShape) {
    const CCubicBezier easeIn{0.4, 0.0, 1.0, 1.0};
    EXPECT_DOUBLE_EQ(easeIn(0.0), 0.0);
    EXPECT_DOUBLE_EQ(easeIn(1.0), 1.0);
    EXPECT_DOUBLE_EQ(easeIn(-1.0), 0.0); // clamped
    EXPECT_DOUBLE_EQ(easeIn(2.0), 1.0);
    double previous = 0.0;
    for (int i = 1; i < 100; ++i) {
        const double t = i / 100.0;
        const double v = easeIn(t);
        EXPECT_LT(v, t) << "ease-in stays below the diagonal at t=" << t;
        EXPECT_GE(v, previous) << "monotonic at t=" << t;
        previous = v;
    }
    const CCubicBezier linear{0.0, 0.0, 1.0, 1.0};
    const CCubicBezier linear2{0.25, 0.25, 0.75, 0.75};
    EXPECT_NEAR(linear2(0.3), 0.3, 1e-6);
    EXPECT_NEAR(linear(0.5), 0.5, 1e-6);
}

TEST(MinimizeEasing, RestoreCurveIsTheTimeReverseOfMinimize) {
    const auto in  = curve(Kind::Minimize);
    const auto out = curve(Kind::Restore);
    for (int i = 0; i <= 20; ++i) {
        const double t = i / 20.0;
        EXPECT_NEAR(out(t), 1.0 - in(1.0 - t), 1e-6) << "t=" << t;
        EXPECT_GE(out(t), t - 1e-9) << "ease-out stays above the diagonal";
    }
}

TEST(MinimizeFrames, MinimizeShrinksIntoTheTileAndFadesAtTheEnd) {
    const Box window{2050, 236, 702, 530};
    const Box tile = fitInside(window, {2300, 1010, 52, 52});
    EXPECT_DOUBLE_EQ(durationMs(Kind::Minimize), 300.0);

    const Frame start = frameAt(Kind::Minimize, window, tile, 0);
    expectBox(start.box, window);
    EXPECT_FLOAT_EQ(start.alpha, 1.F);
    EXPECT_FALSE(start.done);

    const Frame mid = frameAt(Kind::Minimize, window, tile, 150);
    EXPECT_GT(mid.box.w, tile.w);
    EXPECT_LT(mid.box.w, window.w);
    // Ease-in: at half time the window has covered less than half of the way.
    EXPECT_GT(mid.box.w, (window.w + tile.w) / 2);
    EXPECT_FLOAT_EQ(mid.alpha, 1.F);
    // Uniform scale: the aspect ratio never changes.
    EXPECT_NEAR(mid.box.w / mid.box.h, window.w / window.h, 1e-9);

    const Frame fading = frameAt(Kind::Minimize, window, tile, 270); // t = 0.9, fade over the last 20 %
    EXPECT_NEAR(fading.alpha, 0.5F, 1e-5);

    const Frame end = frameAt(Kind::Minimize, window, tile, 300);
    expectBox(end.box, tile);
    EXPECT_FLOAT_EQ(end.alpha, 0.F);
    EXPECT_TRUE(end.done);
    EXPECT_TRUE(frameAt(Kind::Minimize, window, tile, 5000).done);
}

TEST(MinimizeFrames, RestoreGrowsFromTheTileAndFadesInAtTheStart) {
    const Box window{2050, 236, 702, 530};
    const Box tile = fitInside(window, {2300, 1010, 52, 52});
    const Frame start = frameAt(Kind::Restore, tile, window, 0);
    expectBox(start.box, tile);
    EXPECT_FLOAT_EQ(start.alpha, 0.F);
    EXPECT_NEAR(frameAt(Kind::Restore, tile, window, 30).alpha, 0.5F, 1e-5);
    const Frame mid = frameAt(Kind::Restore, tile, window, 150);
    EXPECT_GT(mid.box.w, (window.w + tile.w) / 2); // ease-out: more than half of the way at half time
    EXPECT_FLOAT_EQ(mid.alpha, 1.F);
    const Frame end = frameAt(Kind::Restore, tile, window, 300);
    expectBox(end.box, window);
    EXPECT_FLOAT_EQ(end.alpha, 1.F);
    EXPECT_TRUE(end.done);
}

TEST(MinimizeFrames, NonFiniteTimeEndsTheAnimation) {
    EXPECT_TRUE(frameAt(Kind::Minimize, {0, 0, 10, 10}, {0, 0, 1, 1}, NaN).done);
    EXPECT_FALSE(frameAt(Kind::Minimize, {0, 0, 10, 10}, {0, 0, 1, 1}, -50).done); // clock skew: start
}

TEST(MinimizeSnapshot, IdentityDrawsTheTextureOverTheMonitor) {
    // Snapshot of GF-REF (1920x1080 at (1440,0), scale 1); the window drawn where it was.
    const SSnapshotGeometry snap{.visible = {2050, 236, 702, 530}, .monitorX = 1440, .monitorY = 0, .monitorScale = 1, .texW = 1920, .texH = 1080};
    expectBox(textureBox(snap, snap.visible, 1440, 0, 1), {0, 0, 1920, 1080});
}

TEST(MinimizeSnapshot, MatchesHyprlandsFadeoutMathOnTheSameMonitor) {
    // CWindowFadeout::renderBox: scale = size / sourceSize; x = (pos - mon) * s - sourcePos * s * scale.
    const SSnapshotGeometry snap{.visible = {2050, 236, 702, 530}, .monitorX = 1440, .monitorY = 0, .monitorScale = 1.5, .texW = 2880, .texH = 1620};
    const Box               dst{2100, 300, 351, 265}; // half size
    const Box               tex = textureBox(snap, dst, 1440, 0, 1.5);
    const double            k   = 0.5;
    expectBox(tex, {((2100 - 1440) * 1.5) - ((2050 - 1440) * 1.5 * k), (300 * 1.5) - (236 * 1.5 * k), 2880 * k, 1620 * k});
    // The window region of the texture lands exactly on dst (in pixels).
    EXPECT_NEAR(tex.x + ((2050 - 1440) * 1.5 * k), (2100 - 1440) * 1.5, 1e-9);
}

TEST(MinimizeSnapshot, DrawingOnAnotherMonitorUsesThatMonitorsOriginAndScale) {
    // Snapshot taken on GF-REF, drawn on WAYLAND-1 (origin 0,0, scale 2) into a Dock tile there.
    const SSnapshotGeometry snap{.visible = {2050, 236, 702, 530}, .monitorX = 1440, .monitorY = 0, .monitorScale = 1, .texW = 1920, .texH = 1080};
    const Box               dst = fitInside(snap.visible, {700, 840, 52, 52});
    const Box               tex = textureBox(snap, dst, 0, 0, 2);
    const double            k   = (dst.w * 2) / 702.0;
    // The window region (at 610,236 px in the texture) maps onto dst in WAYLAND-1's pixels.
    EXPECT_NEAR(tex.x + (610 * k), dst.x * 2, 1e-9);
    EXPECT_NEAR(tex.y + (236 * k), dst.y * 2, 1e-9);
    EXPECT_NEAR(tex.w, 1920 * k, 1e-9);
}

TEST(MinimizeSnapshot, Intersects) {
    EXPECT_TRUE(intersects({0, 0, 10, 10}, {5, 5, 10, 10}));
    EXPECT_FALSE(intersects({0, 0, 10, 10}, {10, 0, 10, 10})); // touching edges share no area
    EXPECT_FALSE(intersects({0, 0, 0, 10}, {0, 0, 10, 10}));
}

// ---- D-1 (owner decision 2026-10-23, macOS; audit GF-001): a restored window comes back on its own display ----

namespace {
    // GF-REF (1920x1080 at 0,0, a 32 px menu bar) and a second display to its left, as in the audit's failing run
    // (WAYLAND-1 at -1440,0): the Dock that was clicked is on the second one.
    const MonitorPlace kRef{.name = "GF-REF", .box = {0, 0, 1920, 1080}, .usable = {0, 32, 1920, 1048}};
    const MonitorPlace kLeft{.name = "WAYLAND-1", .box = {-1440, 0, 1440, 900}, .usable = {-1440, 32, 1440, 868}};
    constexpr double   kTb = 32.0;

    SavedPlace savedOnRef(Box frame = {610, 302, 700, 500}) {
        return SavedPlace{.monitor = "GF-REF", .monitorBox = {0, 0, 1920, 1080}, .frame = frame, .floating = true};
    }
} // namespace

TEST(MinimizeRestorePlace, ComesBackOnItsOwnDisplayAtItsFrameWhateverDisplayIsFocused) {
    const std::array monitors{kLeft, kRef};
    // The Dock click focused WAYLAND-1 (index 0): the window still goes back to GF-REF, at the very frame.
    const auto plan = planRestore(savedOnRef(), monitors, 0, kTb);
    ASSERT_TRUE(plan.monitor.has_value());
    EXPECT_EQ(monitors[plan.monitor.value_or(0)].name, "GF-REF");
    ASSERT_TRUE(plan.frame.has_value());
    EXPECT_EQ(plan.frame.value_or(Box{}), (Box{610, 302, 700, 500}));
    EXPECT_FALSE(plan.moved);
}

TEST(MinimizeRestorePlace, WithoutARecordTheFocusedDisplayTakesItAsBefore) {
    const std::array monitors{kLeft, kRef};
    const auto       plan = planRestore(std::nullopt, monitors, 1, kTb);
    EXPECT_EQ(plan.monitor, std::optional<size_t>{1});
    EXPECT_FALSE(plan.frame.has_value()) << "Hyprland's placement stays";
    EXPECT_FALSE(plan.moved);
    EXPECT_EQ(planRestore(std::nullopt, monitors, std::nullopt, kTb).monitor, std::optional<size_t>{0}) << "no focus: the first display";
    EXPECT_EQ(planRestore(std::nullopt, monitors, 7, kTb).monitor, std::optional<size_t>{0}) << "an index out of range is no focus";
    EXPECT_FALSE(planRestore(std::nullopt, std::span<const MonitorPlace>{}, std::nullopt, kTb).monitor.has_value()) << "no display at all";
    EXPECT_FALSE(planRestore(savedOnRef(), std::span<const MonitorPlace>{}, std::nullopt, kTb).monitor.has_value());
}

TEST(MinimizeRestorePlace, ADisplayThatMovedKeepsTheFrameRelativeToIt) {
    // GF-REF was re-arranged to the right of the other display since the minimize.
    const MonitorPlace moved{.name = "GF-REF", .box = {1440, 0, 1920, 1080}, .usable = {1440, 32, 1920, 1048}};
    const std::array   monitors{kLeft, moved};
    const auto         plan = planRestore(savedOnRef(), monitors, 0, kTb);
    EXPECT_EQ(plan.monitor, std::optional<size_t>{1});
    ASSERT_TRUE(plan.frame.has_value());
    EXPECT_EQ(plan.frame.value_or(Box{}), (Box{2050, 302, 700, 500}));
    EXPECT_FALSE(plan.moved);
}

TEST(MinimizeRestorePlace, AGoneDisplayHandsTheWindowToTheFocusedOneFittedIntoIt) {
    // Minimized on GF-REF (now unplugged) near its bottom-right corner; WAYLAND-1 (1440x900) is focused.
    const std::array monitors{kLeft};
    const auto       plan = planRestore(savedOnRef({1500, 700, 700, 500}), monitors, 0, kTb);
    EXPECT_EQ(plan.monitor, std::optional<size_t>{0});
    EXPECT_TRUE(plan.moved);
    ASSERT_TRUE(plan.frame.has_value());
    const Box f = plan.frame.value_or(Box{});
    EXPECT_EQ(f.w, 700);
    EXPECT_EQ(f.h, 500);
    EXPECT_GE(f.x, kLeft.usable.x);
    EXPECT_LE(f.x + f.w, kLeft.usable.x + kLeft.usable.w);
    EXPECT_GE(f.y - kTb, kLeft.usable.y) << "the titlebar stays below the menu bar";
    EXPECT_LE(f.y + f.h, kLeft.usable.y + kLeft.usable.h);
}

TEST(MinimizeRestorePlace, NoFrameForAZoomedOrFullScreenWindowOrABadRecord) {
    const std::array monitors{kLeft, kRef};
    SavedPlace       zoomed = savedOnRef();
    zoomed.floating         = false;
    auto plan               = planRestore(zoomed, monitors, 0, kTb);
    EXPECT_EQ(plan.monitor, std::optional<size_t>{1}) << "still its own display";
    EXPECT_FALSE(plan.frame.has_value()) << "its state (zoom, full screen, tiled) sets its size";
    plan = planRestore(savedOnRef({NaN, 0, 700, 500}), monitors, 0, kTb);
    EXPECT_FALSE(plan.frame.has_value());
    plan = planRestore(savedOnRef({10, 40, 0, 500}), monitors, 0, kTb);
    EXPECT_FALSE(plan.frame.has_value());
    SavedPlace nameless = savedOnRef();
    nameless.monitor    = "";
    plan                = planRestore(nameless, monitors, 1, kTb);
    EXPECT_EQ(plan.monitor, std::optional<size_t>{1}) << "an empty name never matches: the focused display";
    EXPECT_TRUE(plan.moved);
}

TEST(MinimizeRestorePlace, FitFrameShrinksThenMovesIn) {
    const Box usable{0, 32, 1440, 868};
    EXPECT_EQ(fitFrame({100, 200, 700, 500}, usable, kTb), (Box{100, 200, 700, 500})) << "inside: unchanged";
    EXPECT_EQ(fitFrame({-50, 0, 700, 500}, usable, kTb), (Box{0, 64, 700, 500})) << "moved in, titlebar below the menu bar";
    EXPECT_EQ(fitFrame({1000, 700, 700, 500}, usable, kTb), (Box{740, 400, 700, 500}));
    EXPECT_EQ(fitFrame({0, 0, 3000, 2000}, usable, kTb), (Box{0, 64, 1440, 836})) << "larger than the area: shrunk to it";
    EXPECT_EQ(fitFrame({5, 6, 7, 8}, Box{0, 0, 0.5, 900}, kTb), (Box{5, 6, 7, 8})) << "degenerate area: unchanged";
    EXPECT_EQ(fitFrame({5, 6, 7, 8}, Box{0, 0, 900, Inf}, kTb), (Box{5, 6, 7, 8})) << "non-finite area: unchanged";
}

// ---- an animation interrupted by the opposite one (WM-06) ----

TEST(MinimizeTakeover, ElapsedForEasedInvertsTheTiming) {
    for (const Kind kind : {Kind::Minimize, Kind::Restore}) {
        for (const double e : {0.0, 0.1, 0.5, 0.9, 1.0}) {
            const double ms = elapsedForEased(kind, e);
            EXPECT_NEAR(easedProgress(kind, ms), e, 1e-6);
        }
    }
    EXPECT_NEAR(elapsedForEased(Kind::Restore, NaN), durationMs(Kind::Restore), 1e-6);
}

// The scenario of WM-06: the shrink minimize clicked back from the Dock 100 ms in. The restore continues from the box on
// screen (no jump to the tile), opaque (no transparent flash: it starts past its fade-in), with the rest of its time.
TEST(MinimizeTakeover, ARestoreContinuesAShrinkMinimizeWithoutJumpOrFlash) {
    const Box  window{100, 100, 800, 600}, tile{700, 1000, 64, 48};
    const Box  fit       = fitInside(window, tile);
    const auto minimized = frameAt(Kind::Minimize, window, fit, 100);
    ASSERT_FLOAT_EQ(minimized.alpha, 1.F);
    const double progress = easedProgress(Kind::Minimize, 100);
    ASSERT_GT(progress, 0.0);
    ASSERT_LT(progress, 0.5);

    const auto c     = continueFrom(Kind::Restore, minimized.box, window, 1.0 - progress);
    const auto first = frameAt(Kind::Restore, c.from, window, c.elapsedMs);
    EXPECT_NEAR(first.box.x, minimized.box.x, 1e-6) << "no jump";
    EXPECT_NEAR(first.box.y, minimized.box.y, 1e-6);
    EXPECT_NEAR(first.box.w, minimized.box.w, 1e-6);
    EXPECT_NEAR(first.box.h, minimized.box.h, 1e-6);
    EXPECT_FLOAT_EQ(first.alpha, 1.F) << "no transparent flash";
    EXPECT_GT(c.elapsedMs, kFadeFraction * durationMs(Kind::Restore));
    EXPECT_LT(durationMs(Kind::Restore) - c.elapsedMs, durationMs(Kind::Restore)) << "only the rest of the way";
    const auto last = frameAt(Kind::Restore, c.from, window, durationMs(Kind::Restore));
    EXPECT_TRUE(last.done);
    EXPECT_NEAR(last.box.x, window.x, 1e-9);
    EXPECT_NEAR(last.box.y, window.y, 1e-9);

    // Before round 1 the restore started at the tile, transparent: the very jump and flash.
    const auto old = frameAt(Kind::Restore, fit, window, 0);
    EXPECT_FLOAT_EQ(old.alpha, 0.F);
}

TEST(MinimizeTakeover, AMinimizeContinuesAShrinkRestore) {
    const Box  window{0, 0, 600, 400}, fit{300, 900, 60, 40};
    const auto restoring = frameAt(Kind::Restore, fit, window, 200);
    const auto c         = continueFrom(Kind::Minimize, restoring.box, fit, 1.0 - easedProgress(Kind::Restore, 200));
    const auto first     = frameAt(Kind::Minimize, c.from, fit, c.elapsedMs);
    EXPECT_NEAR(first.box.x, restoring.box.x, 1e-6);
    EXPECT_NEAR(first.box.w, restoring.box.w, 1e-6);
    EXPECT_NEAR(frameAt(Kind::Minimize, c.from, fit, durationMs(Kind::Minimize)).box.x, fit.x, 1e-9);
}

TEST(MinimizeTakeover, ShareIsBoundedAndNonFiniteIsAFreshStart) {
    const Box  current{10, 10, 100, 100}, to{500, 500, 50, 50};
    const auto c = continueFrom(Kind::Restore, current, to, 5.0);
    EXPECT_TRUE(isFinite(c.from)) << "share at most 0.95: `from` stays finite";
    EXPECT_LE(easedProgress(Kind::Restore, c.elapsedMs), 0.95 + 1e-6);
    const auto n = continueFrom(Kind::Restore, current, to, NaN);
    EXPECT_NEAR(n.elapsedMs, 0, 1e-6);
    EXPECT_NEAR(n.from.x, current.x, 1e-6);
    EXPECT_NEAR(n.from.w, current.w, 1e-6);
}

TEST(MinimizeTakeover, AFadeContinuesFromItsAlpha) {
    const auto out = fadeFrameAt(Kind::Minimize, Box{0, 0, 10, 10}, 30); // alpha 0.7
    const double ms = fadeElapsedFor(Kind::Restore, out.alpha);
    EXPECT_NEAR(fadeFrameAt(Kind::Restore, Box{0, 0, 10, 10}, ms).alpha, out.alpha, 1e-6);
    EXPECT_NEAR(fadeFrameAt(Kind::Minimize, Box{0, 0, 10, 10}, fadeElapsedFor(Kind::Minimize, 0.25F)).alpha, 0.25F, 1e-6);
}
