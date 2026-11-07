// Windows that draw their own chrome (ADR-0015, docs/specs/compositor.md "Plugin work item: client chrome"): the tag
// predicate (P1), the feature (P2), the band (P3), the zoomed drag (P4), Option+click full screen and its glyph (P6) and
// the one token source of the lights (P7). Test names state the user-visible rule.

#include "core/ClientChrome.hpp"
#include "core/Protocol.hpp"
#include "core/Stages.hpp"
#include "core/Theme.hpp"
#include "core/ThemeTokens.hpp"
#include "core/TitlebarLayout.hpp"

#include <gtest/gtest.h>

#include <vector>

// P8 (GF-056 part 2): a window that draws its own controls is told it can be minimized (GTK4 greys a minimize button the
// compositor does not offer); every other window keeps exactly what Hyprland 0.56.2 sends.
TEST(ClientChromeCapabilities, ClientChromeWindowsAreToldMinimizeWhileTheBridgeRuns) {
    using gf::chrome::wmCapabilities;
    const std::vector<uint32_t> hyprland{gf::chrome::kCapFullscreen, gf::chrome::kCapMaximize};
    EXPECT_EQ(wmCapabilities(false, true), hyprland) << "not client chrome: Hyprland's own capabilities";
    EXPECT_EQ(wmCapabilities(true, false), hyprland) << "no bridge (unload, start failed): Hyprland's own capabilities";
    EXPECT_EQ(wmCapabilities(false, false), hyprland);
    const auto chrome = wmCapabilities(true, true);
    ASSERT_EQ(chrome.size(), 3U);
    EXPECT_EQ(chrome[0], gf::chrome::kCapFullscreen);
    EXPECT_EQ(chrome[1], gf::chrome::kCapMaximize);
    EXPECT_EQ(chrome[2], gf::chrome::kCapMinimize);
}

TEST(ClientChromeCapabilities, TheValuesAreTheProtocolsEnum) {
    // xdg-shell.xml xdg_toplevel.wm_capabilities: window_menu 1, maximize 2, fullscreen 3, minimize 4; the event since v5.
    EXPECT_EQ(gf::chrome::kCapWindowMenu, 1U);
    EXPECT_EQ(gf::chrome::kCapMaximize, 2U);
    EXPECT_EQ(gf::chrome::kCapFullscreen, 3U);
    EXPECT_EQ(gf::chrome::kCapMinimize, 4U);
    EXPECT_EQ(gf::chrome::kWmCapabilitiesSince, 5U);
}

// The walk over a client's resources reads a resource through CXDGToplevelResource::fromResource only when it can be the
// window's toplevel and be told: an xdg_toplevel, v5 or later, still holding its user data (null while it is destroyed;
// fromResource would read through it).
TEST(ClientChromeCapabilities, OnlyALiveToplevelWithTheEventIsReadDuringTheWalk) {
    using gf::chrome::capabilityCandidate;
    EXPECT_TRUE(capabilityCandidate("xdg_toplevel", 5, true));
    EXPECT_TRUE(capabilityCandidate("xdg_toplevel", 7, true));
    EXPECT_FALSE(capabilityCandidate("xdg_toplevel", 7, false)) << "a resource being destroyed (no user data) is never read";
    EXPECT_FALSE(capabilityCandidate("xdg_toplevel", 4, true)) << "older than v5: it never had the event";
    EXPECT_FALSE(capabilityCandidate("xdg_toplevel", 1, true));
    EXPECT_FALSE(capabilityCandidate("xdg_surface", 7, true)) << "another interface";
    EXPECT_FALSE(capabilityCandidate("xdg_popup", 7, true));
    EXPECT_FALSE(capabilityCandidate("", 7, true));
    EXPECT_FALSE(capabilityCandidate("xdg_toplevel_extra", 7, true)) << "the exact interface name, no prefix";
}

// A window is told only when the answer changes, and a window that could not be told is never walked again (every rule
// change would repeat the walk for nothing).
TEST(ClientChromeCapabilities, AWindowIsToldOnceAndAnUnreachableOneNeverAgain) {
    using gf::chrome::CapabilityTell;
    using gf::chrome::needsTell;
    CapabilityTell fresh;
    EXPECT_TRUE(needsTell(fresh, true)) << "a new client-chrome window: told minimize";
    EXPECT_FALSE(needsTell(fresh, false)) << "a new other window: it already has Hyprland's own capabilities";
    const CapabilityTell told{.minimizeTold = true, .unreachable = false};
    EXPECT_FALSE(needsTell(told, true)) << "same answer: nothing sent again on the next rule change";
    EXPECT_TRUE(needsTell(told, false)) << "the tag went, or the unload: told Hyprland's own capabilities again";
    const CapabilityTell unreachable{.minimizeTold = false, .unreachable = true};
    EXPECT_FALSE(needsTell(unreachable, true));
    EXPECT_FALSE(needsTell(unreachable, false));
}

#include <cmath>
#include <set>
#include <string>
#include <vector>

using namespace gf::chrome;

// ---- P1 ----

TEST(ClientChromeTag, TheSessionRulesTagMarksTheWindow) {
    EXPECT_TRUE(hasClientChromeTag({"grassfield-client-chrome"}));
    EXPECT_TRUE(hasClientChromeTag({"grassfield-client-chrome*"})) << "a dynamic (rule-set) tag prints with a trailing *";
    EXPECT_TRUE(hasClientChromeTag({"other", "grassfield-client-chrome*", "third*"}));
}

TEST(ClientChromeTag, NoOtherTagCounts) {
    EXPECT_FALSE(hasClientChromeTag({}));
    EXPECT_FALSE(hasClientChromeTag({"grassfield-client-chrome-x"}));
    EXPECT_FALSE(hasClientChromeTag({"grassfield-client-chrom"}));
    EXPECT_FALSE(hasClientChromeTag({"Grassfield-Client-Chrome"})) << "exact, case-sensitive";
    EXPECT_FALSE(hasClientChromeTag({"grassfield-client-chrome**"})) << "one star only";
    EXPECT_FALSE(hasClientChromeTag({"*grassfield-client-chrome"}));
    EXPECT_FALSE(hasClientChromeTag({"grassfield-client-chrome "}));
}

TEST(ClientChromeTag, TheTagIsTheShellsAndTheSessionRules) {
    // shell/overview/ClientChrome.js TAG and config/hypr/grassfield/windows.lua `tag = "+grassfield-client-chrome"`
    // (tests/shell/client_chrome_rules.sh compares them with the spec).
    EXPECT_EQ(kTag, "grassfield-client-chrome");
}

// ---- P9: the decoration the client negotiated (owner report on 1.0.0-rc6: two title bars on Telegram and ArtCraft) ----

TEST(ClientChromeDecoration, TheValuesAreTheProtocolsEnums) {
    // xdg-decoration-unstable-v1.xml zxdg_toplevel_decoration_v1.mode: client_side 1, server_side 2;
    // kde-server-decoration.xml org_kde_kwin_server_decoration.mode: None 0, Client 1, Server 2.
    EXPECT_EQ(gf::chrome::kXdgModeClientSide, 1U);
    EXPECT_EQ(gf::chrome::kXdgModeServerSide, 2U);
    EXPECT_EQ(gf::chrome::kKdeModeClient, 1U);
    EXPECT_EQ(gf::chrome::kKdeModeServer, 2U);
}

// The review of 3ca47a4b (nested at 1.25): imv (no decoration manager bound) and foot -o csd.preferred=client (xdg client_side,
// then Hyprland's server_side answer taken) were tagged and lost every title bar. A window the plugin tags must draw its own.
TEST(ClientChromeDecoration, OnlyARequestThatProvesABarOfItsOwnTagsTheWindow) {
    using gf::chrome::DecorationRequest;
    using gf::chrome::drawsOwnTitlebar;
    EXPECT_TRUE(drawsOwnTitlebar(DecorationRequest{.kdeObject = true, .kdeRequested = 1, .managerBound = true, .clientHasObject = true}))
        << "KDE client: a GTK header bar";
    EXPECT_TRUE(drawsOwnTitlebar(DecorationRequest{.managerBound = true})) << "a manager bound, no object in the client: Qt's frameless window (Telegram)";
}

TEST(ClientChromeDecoration, ARequestThatProvesNoBarKeepsThePluginsTitlebar) {
    using gf::chrome::DecorationRequest;
    using gf::chrome::drawsOwnTitlebar;
    EXPECT_FALSE(drawsOwnTitlebar(DecorationRequest{})) << "nothing negotiated, no manager bound: imv draws nothing";
    EXPECT_FALSE(drawsOwnTitlebar(DecorationRequest{.xdgObject = true, .xdgRequested = 1, .managerBound = true, .clientHasObject = true}))
        << "xdg client_side alone: foot -o csd.preferred=client draws nothing under Hyprland (Chromium is in S1b)";
    EXPECT_FALSE(drawsOwnTitlebar(DecorationRequest{.xdgObject = true, .xdgRequested = 2, .managerBound = true, .clientHasObject = true}))
        << "xdg server_side (foot, Qt, SDL, mpv)";
    EXPECT_FALSE(drawsOwnTitlebar(DecorationRequest{.xdgObject = true, .xdgRequested = 0, .managerBound = true, .clientHasObject = true}))
        << "xdg object, mode left to the compositor";
    EXPECT_FALSE(drawsOwnTitlebar(DecorationRequest{.kdeObject = true, .kdeRequested = 2, .managerBound = true, .clientHasObject = true}))
        << "KDE server (a GTK window without a header bar)";
    EXPECT_FALSE(drawsOwnTitlebar(DecorationRequest{.kdeObject = true, .kdeRequested = 0, .managerBound = true, .clientHasObject = true}))
        << "KDE object, never asked (or KDE's none)";
}

// What degrades when Hyprland changes its private decoration containers' meaning (ADR-0015, amendment 2026-11-07): the lookups
// miss, and a window whose client holds any decoration object keeps the plugin's titlebar; only a client with none is tagged.
TEST(ClientChromeDecoration, AnObjectNotFoundForTheWindowKeepsThePluginsTitlebar) {
    using gf::chrome::DecorationRequest;
    using gf::chrome::drawsOwnTitlebar;
    EXPECT_FALSE(drawsOwnTitlebar(DecorationRequest{.managerBound = true, .clientHasObject = true}))
        << "the client holds an object not found for this window: another of its windows, or a changed private map";
    EXPECT_FALSE(drawsOwnTitlebar(DecorationRequest{.clientHasObject = true})) << "an object without its manager: nothing proved";
}

TEST(ClientChromeDecoration, AKdeClientRequestIsAHeaderBarWhateverTheXdgSide) {
    using gf::chrome::DecorationRequest;
    using gf::chrome::drawsOwnTitlebar;
    EXPECT_FALSE(drawsOwnTitlebar(
        DecorationRequest{.xdgObject = true, .xdgRequested = 1, .kdeObject = true, .kdeRequested = 2, .managerBound = true, .clientHasObject = true}));
    EXPECT_TRUE(drawsOwnTitlebar(
        DecorationRequest{.xdgObject = true, .xdgRequested = 2, .kdeObject = true, .kdeRequested = 1, .managerBound = true, .clientHasObject = true}));
}

TEST(ClientChromeDecoration, TheDecorationInterfacesAreTheProtocolsNames) {
    using gf::chrome::DecorationInterface;
    using gf::chrome::decorationInterface;
    EXPECT_EQ(decorationInterface("zxdg_decoration_manager_v1"), DecorationInterface::Manager);
    EXPECT_EQ(decorationInterface("org_kde_kwin_server_decoration_manager"), DecorationInterface::Manager);
    EXPECT_EQ(decorationInterface("zxdg_toplevel_decoration_v1"), DecorationInterface::Object);
    EXPECT_EQ(decorationInterface("org_kde_kwin_server_decoration"), DecorationInterface::Object);
    EXPECT_EQ(decorationInterface("xdg_wm_base"), DecorationInterface::Other);
    EXPECT_EQ(decorationInterface("zxdg_decoration_manager_v2"), DecorationInterface::Other) << "exact names";
    EXPECT_EQ(decorationInterface(""), DecorationInterface::Other);
}

TEST(ClientChromeDecoration, TheDecorationKeyIsAnyLiveToplevel) {
    using gf::chrome::toplevelCandidate;
    EXPECT_TRUE(toplevelCandidate("xdg_toplevel", true)) << "any version: xdg-decoration does not need v5";
    EXPECT_FALSE(toplevelCandidate("xdg_toplevel", false)) << "being destroyed: never handed to fromResource";
    EXPECT_FALSE(toplevelCandidate("xdg_popup", true));
    EXPECT_FALSE(toplevelCandidate("zxdg_toplevel_decoration_v1", true));
}

TEST(ClientChromeDecoration, ThePluginOnlyEverRemovesTheTagItAdded) {
    using gf::chrome::TagChange;
    using gf::chrome::tagChange;
    EXPECT_EQ(tagChange(true, false, false), TagChange::Add) << "draws its own, untagged: the plugin tags it";
    EXPECT_EQ(tagChange(true, true, false), TagChange::None) << "already tagged by a session rule";
    EXPECT_EQ(tagChange(true, true, true), TagChange::None) << "already tagged by the plugin";
    EXPECT_EQ(tagChange(false, true, true), TagChange::Remove) << "switched to server-side decorations: the plugin's tag goes";
    EXPECT_EQ(tagChange(false, true, false), TagChange::None) << "the per-app fallback rule's tag is never removed";
    EXPECT_EQ(tagChange(false, false, false), TagChange::None);
    EXPECT_EQ(tagChange(false, false, true), TagChange::None) << "the plugin's tag already gone: nothing to remove";
}

// ---- P2 ----

TEST(ClientChromeFeature, AdvertisedOnlyWhenItsListenersAreRegistered) {
    using namespace gf::gfc;
    EXPECT_EQ(capabilitiesJson(features(false, false, false, false, false, false, false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","client-chrome"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, false, false, false, false, false, false, false, false, false, false, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appearance","client-chrome"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true, true, true, true, true, true, true, true, true, false)).find("client-chrome"),
              std::string::npos);
    EXPECT_EQ(kFeatureClientChrome, "client-chrome") << "the name the shell's ClientChrome.js FEATURE waits for";
}

// ---- P3 ----

TEST(ClientChromeBand, NoTitlebarBandAboveSuchAWindow) {
    EXPECT_EQ(band(true), 0.0);
    EXPECT_EQ(band(false), gf::theme::kTitlebarHeight);
}

// TL33, step 6e (ADR-0036 D73): a Split View member's titlebar is away, so its half is filled from the output's top edge.
TEST(ClientChromeBand, NoBandAboveASplitViewMember) {
    EXPECT_EQ(band(false, true), 0.0) << "a member: its bar is away";
    EXPECT_EQ(band(true, true), 0.0);
    EXPECT_EQ(band(false, false), gf::theme::kTitlebarHeight) << "an ordinary window keeps its band";
    EXPECT_EQ(band(true, false), 0.0) << "client chrome, as before";
}

TEST(ClientChromeBand, StagesThumbnailOfSuchAWindowHasNoBand) {
    using namespace gf::stages;
    const Box                 tile{16, 120, 180, 130};
    const std::vector<Box>    surfaces{{500, 300, 700, 500}};
    const std::vector<double> none{band(true)};
    const auto                r = thumbRects(tile, surfaces, none);
    ASSERT_EQ(r.size(), 1U);
    const double s = std::min(180.0 / 700, 130.0 / 500);
    EXPECT_NEAR(r[0].w, 700 * s, 1e-9) << "fitted on the surface alone";
    EXPECT_NEAR(r[0].y, tile.y + ((130 - (500 * s)) / 2), 1e-9) << "centred with no band above it";
    const auto withBar = thumbRects(tile, surfaces);
    EXPECT_LT(withBar[0].h, r[0].h) << "a window with the plugin's strip is fitted with its band, so it is smaller";
}

TEST(ClientChromeBand, StagesBandsArePerWindowAndBadValuesFallBack) {
    using namespace gf::stages;
    const Box                 tile{0, 0, 300, 300};
    const std::vector<Box>    surfaces{{0, 0, 200, 100}, {0, 0, 200, 100}, {0, 0, 200, 100}};
    const std::vector<double> bands{0.0, std::nan(""), -5.0}; // the client-chrome window first, then two invalid bands
    const auto                r     = thumbRects(tile, surfaces, bands);
    const auto                plain = thumbRects(tile, surfaces);
    ASSERT_EQ(r.size(), 3U);
    EXPECT_NE(r[0].y, plain[0].y) << "band 0 for the first window";
    EXPECT_EQ(r[1], plain[1]) << "NaN: the titlebar band";
    EXPECT_EQ(r[2], plain[2]) << "negative: the titlebar band";
    const std::vector<double> shortList{0.0};
    EXPECT_EQ(thumbRects(tile, surfaces, shortList)[2], plain[2]) << "a shorter list: the titlebar band for the rest";
}

TEST(ClientChromeBand, StripTargetsPassTheBandsOn) {
    using namespace gf::stages;
    const std::vector<Box>    tiles{{16, 120, 180, 130}};
    const std::vector<Box>    surfaces{{500, 300, 700, 500}};
    const std::vector<double> none{0.0};
    const Box                 monitor{0, 0, 1920, 1080};
    const auto                t = stripTargets(0, tiles, false, false, monitor, surfaces, none);
    ASSERT_EQ(t.size(), 1U);
    EXPECT_EQ(t[0].to, thumbRects(tiles[0], surfaces, none)[0]);
}

// ---- P4 ----

TEST(ClientChromeZoomedDrag, AMoveRequestAnswersTheRecordedPressOfTheSameWindow) {
    const ZoomedPress press{.window = 0xabc, .zoomed = {0, 30, 1920, 1050}, .x = 960, .y = 56, .timeMs = 1000};
    EXPECT_TRUE(moveAnswersPress(press, 0xabc, true, 1010));
    EXPECT_TRUE(moveAnswersPress(press, 0xabc, true, 1000 + kMovePressMaxAgeMs));
    EXPECT_FALSE(moveAnswersPress(press, 0xdef, true, 1010)) << "another window";
    EXPECT_FALSE(moveAnswersPress(press, 0xabc, false, 1010)) << "the button was released";
    EXPECT_FALSE(moveAnswersPress(press, 0xabc, true, 1001 + kMovePressMaxAgeMs)) << "too late";
    EXPECT_FALSE(moveAnswersPress(press, 0xabc, true, 999)) << "a clock that went backwards";
    EXPECT_FALSE(moveAnswersPress(std::nullopt, 0xabc, true, 1010)) << "no press recorded";
    EXPECT_FALSE(moveAnswersPress(ZoomedPress{}, 0, true, 0)) << "no window";
}

TEST(ClientChromeZoomedDrag, TheWindowComesBackUnderThePointerAtTheSamePlaceInItsRow) {
    // Zoomed: the surface fills 1920 x 1050 below the menu bar; the press is in the toolbar row, three quarters across.
    const ZoomedPress press{.window = 1, .zoomed = {0, 30, 1920, 1050}, .x = 1440, .y = 56, .timeMs = 0};
    const auto        box = unzoomedBox(press, 800, 500, 1450, 70); // the pointer moved by (10, 14) before the request
    EXPECT_DOUBLE_EQ(box.w, 800);
    EXPECT_DOUBLE_EQ(box.h, 500);
    EXPECT_DOUBLE_EQ(box.x, 1450 - (0.75 * 800)) << "the same horizontal fraction";
    EXPECT_DOUBLE_EQ(box.y, 70 - 26) << "the same height below the top edge: the toolbar row stays under the pointer";
}

TEST(ClientChromeZoomedDrag, APressBelowTheRestoredHeightKeepsThePointerOnTheWindow) {
    const ZoomedPress press{.window = 1, .zoomed = {0, 30, 1920, 1050}, .x = 100, .y = 900, .timeMs = 0};
    const auto        box = unzoomedBox(press, 800, 500, 100, 900);
    EXPECT_DOUBLE_EQ(box.y, 900 - 500) << "never below the restored window";
}

// ---- P6 ----

TEST(ClientChromeZoomLight, OptionClickIsTrueFullScreen) {
    EXPECT_EQ(zoomAction(false, false, false), ZoomAction::Zoom);
    EXPECT_EQ(zoomAction(true, false, false), ZoomAction::Unzoom);
    EXPECT_EQ(zoomAction(false, false, true), ZoomAction::EnterFullscreen);
    EXPECT_EQ(zoomAction(true, false, true), ZoomAction::EnterFullscreen) << "from zoomed too";
    EXPECT_EQ(zoomAction(false, true, false), ZoomAction::LeaveFullscreen);
    EXPECT_EQ(zoomAction(false, true, true), ZoomAction::LeaveFullscreen) << "the light of a full-screen window leaves it";
}

TEST(ClientChromeZoomLight, TheGlyphShowsTheArrowsWhileOptionIsHeld) {
    EXPECT_TRUE(zoomGlyphIsArrows(true, false));
    EXPECT_FALSE(zoomGlyphIsArrows(false, false));
    EXPECT_TRUE(zoomGlyphIsArrows(false, true)) << "the light of a full-screen window leaves it: arrows";
}

// Reviewer, 2026-10-23: a window in full screen had no titlebar, so the pointer had no way out of it (LeaveFullscreen was
// unreachable). macOS: the pointer at the top edge reveals the titlebar below the menu bar.
TEST(ClientChromeFullscreenTitlebar, ThePointerAtTheTopEdgeRevealsIt) {
    RevealInput in{.revealable = true, .onMonitor = true, .pointerY = 0.0, .barTop = 30.0, .pressing = false};
    EXPECT_TRUE(nextRevealed(false, in)) << "at the top edge";
    in.pointerY = kRevealEdge;
    EXPECT_TRUE(nextRevealed(false, in));
    in.pointerY = kRevealEdge + 1.0;
    EXPECT_FALSE(nextRevealed(false, in)) << "below the edge: the content's own";
    in.pointerY = 45.0;
    EXPECT_FALSE(nextRevealed(false, in)) << "where the bar would be, coming from below: never revealed";
}

TEST(ClientChromeFullscreenTitlebar, ItStaysWhileThePointerIsOnItAndGoesBelowIt) {
    RevealInput in{.revealable = true, .onMonitor = true, .pointerY = 30.0 + 16.0, .barTop = 30.0, .pressing = false};
    EXPECT_TRUE(nextRevealed(true, in)) << "on the bar, below the menu bar";
    in.pointerY = 5.0;
    EXPECT_TRUE(nextRevealed(true, in)) << "over the menu bar";
    in.pointerY = 30.0 + gf::theme::kTitlebarHeight + kRevealSlack - 0.5;
    EXPECT_TRUE(nextRevealed(true, in)) << "within the slack";
    in.pointerY = 30.0 + gf::theme::kTitlebarHeight + kRevealSlack;
    EXPECT_FALSE(nextRevealed(true, in)) << "below the slack: away";
    in.pressing = true;
    EXPECT_TRUE(nextRevealed(true, in)) << "a press on a light is decided at its release";
    in.pressing   = false;
    in.pointerY   = 0.0;
    in.onMonitor  = false;
    EXPECT_FALSE(nextRevealed(true, in)) << "the pointer went to another monitor";
    in.onMonitor  = true;
    in.revealable = false;
    EXPECT_FALSE(nextRevealed(true, in)) << "the window left full screen";
    in.pressing = true;
    EXPECT_FALSE(nextRevealed(true, in)) << "even during a press";
}

// TL33, step 6e (ADR-0036 D74): each half of a Split View reveals its own bar; the pointer moving across within the band
// hands the bar over to the other half (one menu bar over both, macOS).
TEST(ClientChromeSplitTitlebar, EachHalfRevealsItsOwnBar) {
    RevealInput in{.revealable = true, .onMonitor = true, .pointerY = 0.0, .barTop = 30.0, .pressing = false, .inSpan = true, .handOver = false};
    EXPECT_TRUE(nextRevealed(false, in)) << "at the top edge over its half";
    in.inSpan = false;
    EXPECT_FALSE(nextRevealed(false, in)) << "at the top edge over the other half: that half's bar, not this one";
    in.pointerY = 20.0;
    in.inSpan   = true;
    EXPECT_TRUE(nextRevealed(true, in)) << "revealed, the pointer on it";
    in.inSpan = false;
    EXPECT_TRUE(nextRevealed(true, in)) << "in the gap between the halves: still its bar";
    in.overOther = true;
    EXPECT_FALSE(nextRevealed(true, in)) << "the pointer went across to the other half: it goes";
    in.pointerY = 0.0;
    EXPECT_FALSE(nextRevealed(false, in)) << "over the other half at the top edge: that half's bar, not this one";
}

namespace {
    // Two members side by side (the review of #99: an 8 px gap between the halves), the pointer walked along the band from
    // `from` to `to` in `step` px: at every step exactly one bar is revealed, the left one until the pointer is over the
    // right half, the right one from there. Both bars' states come from nextRevealed, each motion seeing the other's state
    // before it (updateReveal's handOver).
    void walkTheGap(double from, double to, double step) {
        constexpr double kLeftEnd = 956.0, kRightStart = 964.0, kWidth = 1920.0, kBarTop = 24.0;
        bool             left = false, right = false;
        const auto       input = [&]([[maybe_unused]] double x, bool inOwn, bool overOther, bool otherRevealed) {
            return RevealInput{.revealable = true, .onMonitor = true, .pointerY = 20.0, .barTop = kBarTop, .pressing = false, .inSpan = inOwn,
                               .handOver = otherRevealed, .overOther = overOther};
        };
        // Revealed first over the left half, at the top edge.
        left = nextRevealed(left, RevealInput{.revealable = true, .onMonitor = true, .pointerY = 0.0, .barTop = kBarTop, .pressing = false, .inSpan = true});
        ASSERT_TRUE(left);
        const int steps = static_cast<int>((to - from) / step);
        for (int i = 0; i <= steps; ++i) {
            const double x = from + (i * step);
            const bool inLeft  = x >= 0 && x < kLeftEnd;
            const bool inRight = x >= kRightStart && x < kWidth;
            const bool l = nextRevealed(left, input(x, inLeft, inRight, right));
            const bool r = nextRevealed(right, input(x, inRight, inLeft, left));
            left  = l;
            right = r;
            EXPECT_EQ(left, x < kRightStart) << "the left bar at x " << x;
            EXPECT_EQ(right, x >= kRightStart) << "the right bar at x " << x;
        }
    }
} // namespace

TEST(ClientChromeSplitTitlebar, TheBarIsHandedOverAcrossTheGapInSmallSteps) {
    walkTheGap(900.0, 1020.0, 4.0);
    walkTheGap(900.0, 1020.0, 12.0);
    walkTheGap(950.0, 970.0, 1.0);
    walkTheGap(940.0, 980.0, 40.0); // one jump over the gap, as before
}

TEST(ClientChromeSplitTitlebar, AndBackTheOtherWay) {
    // Revealed over the right half, walked left in small steps: the right bar until the pointer is over the left half.
    constexpr double kLeftEnd = 956.0, kRightStart = 964.0, kBarTop = 24.0;
    bool             left = false;
    bool             right = nextRevealed(false, RevealInput{.revealable = true, .onMonitor = true, .pointerY = 0.0, .barTop = kBarTop, .pressing = false});
    for (int i = 0; i <= 25; ++i) {
        const double x       = 1000.0 - (i * 4.0); // 1000 down to 900
        const bool   inLeft  = x < kLeftEnd;
        const bool inRight = x >= kRightStart;
        const auto in      = [&](bool own, bool other, bool otherRevealed) {
            return RevealInput{.revealable = true, .onMonitor = true, .pointerY = 20.0, .barTop = kBarTop, .pressing = false, .inSpan = own,
                               .handOver = otherRevealed, .overOther = other};
        };
        const bool l = nextRevealed(left, in(inLeft, inRight, right));
        const bool r = nextRevealed(right, in(inRight, inLeft, left));
        left  = l;
        right = r;
        EXPECT_EQ(right, x >= kLeftEnd) << "the right bar at x " << x;
        EXPECT_EQ(left, x < kLeftEnd) << "the left bar at x " << x;
    }
}

TEST(ClientChromeSplitTitlebar, TheOtherHalfsBarComesAcrossTheBand) {
    RevealInput in{.revealable = true, .onMonitor = true, .pointerY = 20.0, .barTop = 30.0, .pressing = false, .inSpan = true, .handOver = true};
    EXPECT_TRUE(nextRevealed(false, in)) << "the other half's bar is revealed: within the band this one comes";
    in.pointerY = 30.0 + gf::theme::kTitlebarHeight + kRevealSlack - 0.5;
    EXPECT_TRUE(nextRevealed(false, in)) << "within the slack too";
    in.pointerY = 30.0 + gf::theme::kTitlebarHeight + kRevealSlack;
    EXPECT_FALSE(nextRevealed(false, in)) << "below the band: the content's own";
    in.pointerY = 20.0;
    in.handOver = false;
    EXPECT_FALSE(nextRevealed(false, in)) << "no bar revealed on this monitor: only the top edge reveals";
    in.handOver = true;
    in.inSpan   = false;
    EXPECT_FALSE(nextRevealed(false, in)) << "not over its half";
    in.inSpan    = true;
    in.onMonitor = false;
    EXPECT_FALSE(nextRevealed(false, in)) << "not on its monitor";
    in.onMonitor = true;
    in.pointerY  = -1.0;
    EXPECT_FALSE(nextRevealed(false, in)) << "above its monitor";
    in.pointerY   = 20.0;
    in.revealable = false;
    EXPECT_FALSE(nextRevealed(false, in)) << "a window that cannot show it";
}

TEST(ClientChromeSplitTitlebar, APressOnARevealedBarHoldsItAndNoOtherComes) {
    RevealInput in{.revealable = true, .onMonitor = true, .pointerY = 600.0, .barTop = 30.0, .pressing = true, .inSpan = false, .handOver = true};
    EXPECT_TRUE(nextRevealed(true, in)) << "a member dragged by its revealed bar keeps it, wherever the pointer goes";
    in.pointerY = 0.0;
    in.inSpan   = true;
    EXPECT_FALSE(nextRevealed(false, in)) << "the other half's bar does not come during that press, even at the top edge";
}

TEST(ClientChromeFullscreenTitlebar, MinimizeIsUnavailable) {
    EXPECT_TRUE(lightAvailableInFullscreen(gf::titlebar::Button::Close));
    EXPECT_FALSE(lightAvailableInFullscreen(gf::titlebar::Button::Minimize));
    EXPECT_TRUE(lightAvailableInFullscreen(gf::titlebar::Button::Zoom));
}

// TL33, step 6e (ADR-0036 D75): the revealed bar of a Split View member takes its drag as well as its lights.
TEST(ClientChromeSplitTitlebar, ARevealedMembersBarStartsItsDragAwayFromTheLights) {
    using gf::titlebar::HitTarget;
    EXPECT_EQ(revealedPress(HitTarget::DragArea, true), RevealedPress::MemberDrag) << "a member in its half: its drag (D59)";
    EXPECT_EQ(revealedPress(HitTarget::DragArea, false), RevealedPress::Nothing) << "full screen, or a member zoomed: focus only";
    EXPECT_EQ(revealedPress(HitTarget::Zoom, true), RevealedPress::ArmLight) << "the green light leaves the Split View at its release";
    EXPECT_EQ(revealedPress(HitTarget::Close, true), RevealedPress::ArmLight);
    EXPECT_EQ(revealedPress(HitTarget::Close, false), RevealedPress::ArmLight) << "full screen's lights, as before";
    EXPECT_EQ(revealedPress(HitTarget::Zoom, false), RevealedPress::ArmLight);
    EXPECT_EQ(revealedPress(HitTarget::Minimize, true), RevealedPress::Nothing) << "minimize is inert (D56), never a drag";
    EXPECT_EQ(revealedPress(HitTarget::Minimize, false), RevealedPress::Nothing);
    EXPECT_EQ(revealedPress(HitTarget::None, true), RevealedPress::Nothing) << "off the bar";
}

// ADR-0040 step 1b's review: a window of fixed size drawn with the plugin's titlebar showed a live zoom light and a click
// zoomed it. Its zoom light is disabled (macOS greys the green button of a window that cannot be resized), unless it is zoomed
// or in full screen already (the light brings it back, as the menu's Unzoom and Exit Full Screen); its other lights are not.
TEST(ClientChromeFixedSize, TheZoomLightOfAWindowOfFixedSizeIsDisabled) {
    using gf::titlebar::Button;
    EXPECT_FALSE(lightAvailable(Button::Zoom, false, true, false)) << "fixed size, as it is";
    EXPECT_TRUE(lightAvailable(Button::Zoom, false, true, true)) << "fixed size but zoomed: Unzoom";
    EXPECT_TRUE(lightAvailable(Button::Zoom, true, true, true)) << "fixed size in full screen: Exit Full Screen";
    EXPECT_TRUE(lightAvailable(Button::Zoom, false, false, false)) << "a resizable window";
    EXPECT_TRUE(lightAvailable(Button::Close, false, true, false));
    EXPECT_TRUE(lightAvailable(Button::Minimize, false, true, false));
    EXPECT_FALSE(lightAvailable(Button::Minimize, true, false, true)) << "full screen keeps its rule";
    EXPECT_TRUE(lightAvailable(Button::Close, true, false, true));
}

TEST(ClientChromeFullscreenTitlebar, OnlyThePressesOnTheBarHaveTheirReleaseCancelled) {
    constexpr uint32_t kLeft  = 0x110;
    constexpr uint32_t kRight = 0x111;
    CRevealPresses     p;
    p.onPress(kLeft, true);
    EXPECT_TRUE(p.pressing());
    EXPECT_FALSE(p.takeRelease(kRight)) << "another button's release is Hyprland's";
    EXPECT_TRUE(p.takeRelease(kLeft)) << "the bar's press: its release is cancelled too";
    EXPECT_FALSE(p.pressing());
    EXPECT_FALSE(p.takeRelease(kLeft)) << "only once";

    p.onPress(kLeft, false);
    EXPECT_FALSE(p.takeRelease(kLeft)) << "a press elsewhere: Hyprland records it and gets its release";
}

TEST(ClientChromeFullscreenTitlebar, ALostReleaseIsForgottenAtTheNextPress) {
    constexpr uint32_t kLeft = 0x110;
    CRevealPresses     p;
    p.onPress(kLeft, true); // its release never comes (the device went away)
    p.onPress(kLeft, false);
    EXPECT_FALSE(p.takeRelease(kLeft)) << "the release of a press Hyprland recorded is never cancelled";
    EXPECT_FALSE(p.pressing());
    p.onPress(kLeft, true);
    p.reset();
    EXPECT_FALSE(p.pressing());
}

// Review of part B, 2026-10-24: a button already held when the plugin loads must not be mistaken for nothing held.
TEST(ClientChromeFullscreenTitlebar, HeldButtonsAreUnknownUntilHyprlandHoldsNone) {
    constexpr uint32_t kLeft  = 0x110;
    constexpr uint32_t kRight = 0x111;
    CHeldButtons       held;
    EXPECT_FALSE(held.mayTake(kLeft, false)) << "just loaded, Hyprland holds something: unknown, refused";
    EXPECT_FALSE(held.known());
    EXPECT_TRUE(held.mayTake(kLeft, true)) << "Hyprland holds nothing: known from here";
    held.observe(kRight, true);
    EXPECT_TRUE(held.mayTake(kLeft, false)) << "another button held";
    EXPECT_FALSE(held.mayTake(kRight, false)) << "the same button held by another device: refused";
    held.observe(kRight, false);
    EXPECT_TRUE(held.mayTake(kRight, false));
    held.observe(kLeft, true); // its release lost (a device that went away): Hyprland keeps it too
    EXPECT_FALSE(held.mayTake(kLeft, false));
    EXPECT_TRUE(held.mayTake(kLeft, true)) << "Hyprland holds nothing again: the record starts over";
    held.reset();
    EXPECT_FALSE(held.mayTake(kLeft, false)) << "reset: unknown again";
}

TEST(ClientChromeZoomLight, TheArrowsAreTwoTrianglesAtOppositeCorners) {
    using namespace gf::titlebar;
    const int  n    = 16;
    const auto mask = glyphMask(Button::Zoom, n, 0.12 * 14, true);
    ASSERT_EQ(mask.size(), static_cast<size_t>(n * n));
    const auto at = [&](int x, int y) { return mask[(static_cast<size_t>(y) * n) + static_cast<size_t>(x)]; };
    EXPECT_EQ(at(0, n - 1), 255) << "bottom-left corner filled";
    EXPECT_EQ(at(n - 1, 0), 255) << "top-right corner filled";
    EXPECT_EQ(at(0, 0), 0) << "top-left corner empty";
    EXPECT_EQ(at(n - 1, n - 1), 0) << "bottom-right corner empty";
    EXPECT_EQ(at(n / 2, n / 2), 0) << "the middle is empty: two arrows, not a block";
    for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x)
            EXPECT_EQ(at(x, y), at(n - 1 - x, n - 1 - y)) << "point symmetry at " << x << "," << y;
    }
    EXPECT_NE(glyphMask(Button::Zoom, n, 0.12 * 14, false), mask) << "the + without Alt";
    EXPECT_EQ(glyphMask(Button::Close, n, 0.12 * 14, true), glyphMask(Button::Close, n, 0.12 * 14)) << "only the zoom light changes";
}

// ---- P7 ----

TEST(ClientChromeTokens, ThePluginsLightsAreTheAppsLights) {
    namespace t = gf::theme::tokens;
    using namespace gf::theme;
    EXPECT_EQ(kButtonDiameter, t::kWindowLightDiameter);
    EXPECT_EQ(kButtonSpacing, t::kWindowLightGap);
    EXPECT_EQ(kTitlebarHeight, t::kWindowTitlebarHeight);
    EXPECT_EQ(kButtonInsetLeft, t::kWindowTitlebarLightInset);
    EXPECT_NEAR(kButtonHitSlop, t::kWindowLightHitSlop, 1e-3);
    EXPECT_EQ(kTitlePadding, t::kWindowTitleGap);
    EXPECT_EQ(kGlyphRatio, t::kWindowGlyphRatio);
    EXPECT_EQ(kGlyphStroke, t::kWindowGlyphStroke);
    EXPECT_FLOAT_EQ(kGlyphColor.a, static_cast<float>(t::kWindowGlyphOpacity));
    const auto same = [](const Rgba& c, uint32_t hex) {
        const Rgba want = fromHex(hex);
        return c.r == want.r && c.g == want.g && c.b == want.b;
    };
    EXPECT_TRUE(same(kCloseColor, t::kWindowCloseColor));
    EXPECT_TRUE(same(kMinimizeColor, t::kWindowMinimizeColor));
    EXPECT_TRUE(same(kZoomColor, t::kWindowZoomColor));
    EXPECT_TRUE(same(titlebarPalette(Appearance::Dark).inactiveLight, t::kWindowInactiveLightDark));
    EXPECT_TRUE(same(titlebarPalette(Appearance::Light).inactiveLight, t::kWindowInactiveLightLight));
}

// ADR-0036 D78, ADR-0015 Q4 amended (opus review of fix/zoom-is-fill: Settings' own green light glued the window in
// Hyprland's maximized mode while Window > Zoom filled it): while window-tiling is advertised the plugin owns a
// client-chrome window's maximize requests (Zoom is Fill); otherwise Hyprland's own, as before (gate C2).
TEST(ClientChromeZoom, ThePluginOwnsAClientChromeMaximizeOnlyWithWindowTiling) {
    using gf::chrome::ownsMaximize;
    EXPECT_TRUE(ownsMaximize(true, true, true));
    EXPECT_FALSE(ownsMaximize(true, false, true)) << "no window-tiling (a degraded plugin): Hyprland's maximized mode";
    EXPECT_FALSE(ownsMaximize(false, true, true)) << "the bridge stopped (unload): Hyprland's maximized mode";
    EXPECT_FALSE(ownsMaximize(true, true, false)) << "not client chrome: its maximize stays whatever the session rules say";
}

TEST(ClientChromeZoom, TheEchoAfterFullScreenIsSwallowedForABoundedTime) {
    using gf::chrome::kMaximizeEchoMs;
    using gf::chrome::maximizeEcho;
    EXPECT_FALSE(maximizeEcho(0, 5000)) << "never left full screen";
    EXPECT_TRUE(maximizeEcho(5000, 5000));
    EXPECT_TRUE(maximizeEcho(5000, 5000 + kMaximizeEchoMs));
    EXPECT_FALSE(maximizeEcho(5000, 5001 + kMaximizeEchoMs)) << "a later request is the user's zoom";
    EXPECT_FALSE(maximizeEcho(5000, 4999)) << "a clock that went back counts as no echo";
}
