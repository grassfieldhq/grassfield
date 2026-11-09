// SEC-01 (core/CapturePrivacy.hpp): a window hidden from captures (Hyprland's no_screen_share, privacy.lua) shows none of
// its pixels in a capture, the plugin's drawings included. Hyprland 0.56.2 blacks out such a window's own box at its real
// place, rounded; the plugin draws none of the window's pixels outside that box while a capture of the display is in
// progress, and redraws the display whole when that changes. Test names state the rule. The scenario of the leak found on
// 2026-11-09 (lock_privacy.sh screenshare: 98 green px in the Bitwarden fixture's top corners, plugin loaded, 4 runs of 4)
// is FrameByFrame below; the nested check itself stays tests/security/lock_privacy.sh.

#include "core/CapturePrivacy.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <limits>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

namespace {
    using gf::privacy::Box;
    using gf::privacy::CaptureCounts;
    using gf::privacy::DisplayCapture;

    constexpr std::array<double, 4> kScales{1.0, 1.25, 1.5, 2.0};

    std::string slurp(const std::filesystem::path& p) {
        std::ifstream     in(p);
        std::stringstream ss;
        ss << in.rdbuf();
        return ss.str();
    }
} // namespace

TEST(CapturePrivacy, ADisplayIsCapturedWhileAFrameIsAwaitedOrWasCopiedLessThan500msAgo) {
    EXPECT_FALSE(gf::privacy::capturing(CaptureCounts{}));
    EXPECT_TRUE(gf::privacy::capturing(CaptureCounts{.sharingSessions = 0, .pendingFrames = 1})) << "grim's frame, before Hyprland draws it";
    EXPECT_TRUE(gf::privacy::capturing(CaptureCounts{.sharingSessions = 1, .pendingFrames = 0})) << "a screencast between two frames";
    EXPECT_TRUE(gf::privacy::capturing(CaptureCounts{.sharingSessions = 2, .pendingFrames = 3}));
}

TEST(CapturePrivacy, AnUnprotectedWindowIsAlwaysDrawn) {
    for (const bool capturing : {false, true}) {
        for (const bool tracked : {false, true})
            EXPECT_TRUE(gf::privacy::mayDrawContent(false, capturing, tracked)) << capturing << tracked;
    }
}

TEST(CapturePrivacy, AProtectedWindowsPixelsAreNotDrawnOutsideItsBoxWhileTheDisplayIsCaptured) {
    EXPECT_TRUE(gf::privacy::mayDrawContent(true, false, true)) << "no capture: the window looks as it always does";
    EXPECT_FALSE(gf::privacy::mayDrawContent(true, true, true));
}

TEST(CapturePrivacy, WithoutTheCaptureListenersAProtectedWindowsPixelsAreNeverDrawnOutsideItsBox) {
    // No redraw when a capture begins: pixels drawn before it could be copied. Privacy first.
    EXPECT_FALSE(gf::privacy::mayDrawContent(true, false, false));
    EXPECT_FALSE(gf::privacy::mayDrawContent(true, true, false));
}

TEST(CapturePrivacy, ADisplayIsRedrawnWholeWhenACaptureBeginsAndWhenItEnds) {
    DisplayCapture d;
    EXPECT_FALSE(gf::privacy::redrawWhole(d, false)) << "first frame, no capture: nothing to redraw";
    EXPECT_FALSE(gf::privacy::redrawWhole(d, false));
    EXPECT_TRUE(gf::privacy::redrawWhole(d, true)) << "a capture began: nothing drawn before it may be copied";
    EXPECT_FALSE(gf::privacy::redrawWhole(d, true)) << "every pixel since was drawn under the capture";
    EXPECT_TRUE(gf::privacy::redrawWhole(d, false)) << "it ended: the content comes back on screen";
    EXPECT_FALSE(gf::privacy::redrawWhole(d, false));
}

TEST(CapturePrivacy, APluginLoadedDuringACaptureRedrawsTheDisplayAtItsFirstFrame) {
    DisplayCapture d;
    EXPECT_TRUE(gf::privacy::redrawWhole(d, true));
    EXPECT_TRUE(d.known);
    EXPECT_TRUE(d.capturing);
}

// The leak of 2026-11-09 frame by frame: the Bitwarden fixture's titlebar join (its content's top corners), one grim capture.
// Hyprland's counts per frame as 0.56.2 keeps them (ScreenshareFrame.cpp share(), copy(); ScreenshareSession.cpp the 500 ms
// timer). The session grim leaves behind is not among them: it stays "active" for good, and must not hide anything.
TEST(CapturePrivacy, FrameByFrame) {
    struct Frame {
        const char*   what;
        CaptureCounts counts;
        bool          redraw;  // drawn whole
        bool          content; // the corners show the content's own pixels
    };
    const std::array<Frame, 5> frames{{
        {"before the capture", {.sharingSessions = 0, .pendingFrames = 0}, false, true},
        {"grim asked for a frame: the one it copies", {.sharingSessions = 0, .pendingFrames = 1}, true, false},
        {"copied, within 500 ms", {.sharingSessions = 1, .pendingFrames = 0}, false, false},
        {"500 ms later: Hyprland stops counting the session", {.sharingSessions = 0, .pendingFrames = 0}, true, true},
        {"after, grim's session left behind", {.sharingSessions = 0, .pendingFrames = 0}, false, true},
    }};
    DisplayCapture display;
    for (const auto& f : frames) {
        const bool capturing = gf::privacy::capturing(f.counts);
        EXPECT_EQ(gf::privacy::redrawWhole(display, capturing), f.redraw) << f.what;
        EXPECT_EQ(gf::privacy::mayDrawContent(true, capturing, true), f.content) << f.what;
    }
}

TEST(CapturePrivacy, AMiniaturesPlateCoversItsSurfaceWithAWholePixelToSpare) {
    // Fractional places and sizes, as an overview or Stages layout fits a window, on a display away from the origin.
    const std::array<Box, 4> fitted{{{.x = 2010.3, .y = 140.7, .w = 312.45, .h = 201.2},
                                     {.x = 1920.0, .y = 0.0, .w = 640.0, .h = 400.0},
                                     {.x = 1925.5, .y = 33.25, .w = 0.75, .h = 0.5},
                                     {.x = 3800.9, .y = 1000.1, .w = 39.0, .h = 79.9}}};
    constexpr double monX = 1920.0, monY = -60.0;
    for (const double scale : kScales) {
        for (const auto& f : fitted) {
            const Box p = gf::privacy::platePx(f, monX, monY, scale);
            const double left = (f.x - monX) * scale, top = (f.y - monY) * scale;
            const double right = (f.x + f.w - monX) * scale, bottom = (f.y + f.h - monY) * scale;
            EXPECT_LE(p.x, std::floor(left) - 1.0) << scale;
            EXPECT_LE(p.y, std::floor(top) - 1.0) << scale;
            EXPECT_GE(p.x + p.w, std::ceil(right) + 1.0) << scale;
            EXPECT_GE(p.y + p.h, std::ceil(bottom) + 1.0) << scale;
            // Whole pixels: no edge pixel half covered, so none of the surface's own pixels blends through.
            EXPECT_EQ(p.x, std::round(p.x));
            EXPECT_EQ(p.y, std::round(p.y));
            EXPECT_EQ(p.w, std::round(p.w));
            EXPECT_EQ(p.h, std::round(p.h));
            // And no more than that: two pixels and a fraction at most on each side.
            EXPECT_LT(p.w, (right - left) + 4.0);
            EXPECT_LT(p.h, (bottom - top) + 4.0);
        }
    }
}

TEST(CapturePrivacy, NoPlateForNothing) {
    constexpr double nan = std::numeric_limits<double>::quiet_NaN();
    constexpr double inf = std::numeric_limits<double>::infinity();
    EXPECT_EQ(gf::privacy::platePx(Box{.x = 0, .y = 0, .w = 0, .h = 10}, 0, 0, 1), Box{});
    EXPECT_EQ(gf::privacy::platePx(Box{.x = 0, .y = 0, .w = 10, .h = -1}, 0, 0, 1), Box{});
    EXPECT_EQ(gf::privacy::platePx(Box{.x = nan, .y = 0, .w = 10, .h = 10}, 0, 0, 1), Box{});
    EXPECT_EQ(gf::privacy::platePx(Box{.x = 0, .y = 0, .w = inf, .h = 10}, 0, 0, 1), Box{});
    EXPECT_EQ(gf::privacy::platePx(Box{.x = 0, .y = 0, .w = 10, .h = 10}, 0, 0, 0), Box{});
}

// Every place the plugin draws a window's own pixels asks first: a surface's buffer (its current state's texture), a
// framebuffer's texture (a snapshot, a transformer's input). A new one without the question fails here.
TEST(CapturePrivacy, EveryPluginSourceThatDrawsAWindowsPixelsAsksFirst) {
    const std::filesystem::path dir{GF_PLUGIN_SOURCE_DIR};
    ASSERT_TRUE(std::filesystem::is_directory(dir)) << dir;
    const std::regex         pixels{R"(getTexture\(\)|m_current\s*;|m_current\.texture)"};
    std::vector<std::string> drawing;
    std::vector<std::string> missing;
    for (const auto& entry : std::filesystem::directory_iterator(dir)) {
        if (entry.path().extension() != ".cpp")
            continue;
        const std::string text = slurp(entry.path());
        if (!std::regex_search(text, pixels))
            continue;
        drawing.push_back(entry.path().filename().string());
        if (text.find("capturePrivacy::mayDrawContent(") == std::string::npos)
            missing.push_back(entry.path().filename().string());
    }
    EXPECT_GE(drawing.size(), 3U) << "Titlebar.cpp (content corners), WindowTransform.cpp (miniatures), Minimize.cpp (snapshots)";
    EXPECT_TRUE(missing.empty()) << "draws a window's pixels without gf::capturePrivacy::mayDrawContent(): " << ::testing::PrintToString(missing);
}
