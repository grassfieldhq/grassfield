#include "core/Appmenu.hpp"
#include "core/Overview.hpp"
#include "core/OverviewFocus.hpp"
#include "core/Protocol.hpp"
#include "core/Stages.hpp"
#include "core/Tiling.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

using namespace gf::gfc;

TEST(Protocol, CapabilitiesJsonIsExactWireFormat) {
    EXPECT_EQ(capabilitiesJson(), R"({"v":"gfc/1","type":"capabilities","features":["decorations"]})");
}

TEST(Protocol, Socket2LineMatchesWhatSubscribersReceive) {
    EXPECT_EQ(socket2Line(capabilitiesJson()), R"(grassfield>>{"v":"gfc/1","type":"capabilities","features":["decorations"]})");
}

TEST(Protocol, CapabilitiesWithNoFeatures) {
    EXPECT_EQ(capabilitiesJson({}), R"({"v":"gfc/1","type":"capabilities","features":[]})");
}

TEST(Protocol, CapabilitiesWithSeveralFeaturesKeepsOrder) {
    constexpr std::string_view features[] = {"decorations", "minimize"};
    EXPECT_EQ(capabilitiesJson(features), R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize"]})");
}

TEST(Protocol, OnlyRegisteredFeaturesAreAdvertised) {
    // R11: minimize, config and appmenu are advertised only when their entry points registered at load.
    EXPECT_EQ(capabilitiesJson().find("minimize"), std::string::npos);
    EXPECT_EQ(capabilitiesJson(features(false, false, false)), R"({"v":"gfc/1","type":"capabilities","features":["decorations"]})");
    EXPECT_EQ(capabilitiesJson(features(true, false, false)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true, false)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","config"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, false)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config"]})");
    EXPECT_EQ(capabilitiesJson(features(false, false, true)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","appmenu"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu"]})");
    EXPECT_EQ(capabilitiesJson(features(false, false, false, true)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","overview"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu","overview"]})");
    EXPECT_EQ(capabilitiesJson(features(false, false, false, false, true)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","desktop-focus","desktop-focus-v2"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu","overview","desktop-focus","desktop-focus-v2"]})");
}

// Stages (ADR-0013): the toggle needs "stages-available"; "stages" follows the feature flag and never comes alone.
TEST(Protocol, StagesFeaturesFollowAvailabilityAndTheFlag) {
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, true, false)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","stages-available"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","stages-available","stages"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, true)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","config"]})")
        << "flag on but the hooks failed: nothing advertised";
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu","overview","desktop-focus","desktop-focus-v2","stages-available","stages"]})");
    EXPECT_EQ(luaDispatchRequest(kLuaStages), "hl.plugin.grassfield.stages()");
}

TEST(Protocol, WithdrawnCapabilitiesHaveNoFeature) {
    // Posted at unload: the shell drops every feature (desktop-focus included) and uses its fallbacks.
    EXPECT_EQ(capabilitiesJson({}), R"({"v":"gfc/1","type":"capabilities","features":[]})");
}

TEST(Protocol, AppmenuJsonIsExactWireFormat) {
    EXPECT_EQ(appmenuJson("55d3c2a0b1f0", ":1.42", "/MenuBar/1", 4242),
              R"({"v":"gfc/1","type":"appmenu","address":"55d3c2a0b1f0","service":":1.42","path":"/MenuBar/1","pid":4242})");
    EXPECT_EQ(socket2Line(appmenuJson("55d3c2a0b1f0", "org.kde.Foo", "/a/b", 7)),
              R"(grassfield>>{"v":"gfc/1","type":"appmenu","address":"55d3c2a0b1f0","service":"org.kde.Foo","path":"/a/b","pid":7})");
}

TEST(Protocol, AppmenuClearHasEmptyServiceAndPath) {
    EXPECT_EQ(appmenuJson("55d3c2a0b1f0", "", "", 0), R"({"v":"gfc/1","type":"appmenu","address":"55d3c2a0b1f0","service":"","path":"","pid":0})");
}

TEST(Protocol, AppmenuPidIsANonNegativeInteger) {
    // pid is additive within gfc/1 (consumers that ignore it keep working); unknown or invalid pids are 0.
    EXPECT_EQ(appmenuJson("1", ":1.2", "/m", -1), R"({"v":"gfc/1","type":"appmenu","address":"1","service":":1.2","path":"/m","pid":0})");
    EXPECT_EQ(appmenuJson("1", ":1.2", "/m", 2147483647), R"({"v":"gfc/1","type":"appmenu","address":"1","service":":1.2","path":"/m","pid":2147483647})");
}

TEST(Protocol, AppmenuJsonEscapesEveryField) {
    // Validation rejects these strings before they reach the JSON; the JSON stays well-formed regardless.
    EXPECT_EQ(appmenuJson(R"(a"b)", R"(x","type":"evil)", "/p\n\\", 1),
              R"({"v":"gfc/1","type":"appmenu","address":"a\"b","service":"x\",\"type\":\"evil","path":"/p\n\\","pid":1})");
    EXPECT_EQ(appmenuJson("1", std::string_view(":1.\0", 4), "/\x01", 0), R"({"v":"gfc/1","type":"appmenu","address":"1","service":":1.\u0000","path":"/\u0001","pid":0})");
}

// The menu bar sends a chosen item's action once the item's window has the keyboard back (docs/specs/menu-bridge.md
// MB12): the plugin says when the seat's keyboard focus enters a mapped window.
TEST(Protocol, KeyboardFocusEventAndFeature) {
    EXPECT_EQ(keyboardFocusJson("55d3c2a0b1f0"), R"({"v":"gfc/1","type":"keyboard-focus","address":"55d3c2a0b1f0"})");
    EXPECT_EQ(keyboardFocusJson(R"(a"b)"), R"({"v":"gfc/1","type":"keyboard-focus","address":"a\"b"})");
    // Step 6c (ADR-0036 D65): a full-screen window's titlebar revealed or away on an output.
    EXPECT_EQ(titlebarRevealJson("GF-REF", true), R"({"v":"gfc/1","type":"titlebar-reveal","output":"GF-REF","revealed":true})");
    EXPECT_EQ(titlebarRevealJson(R"(A"B)", false), R"({"v":"gfc/1","type":"titlebar-reveal","output":"A\"B","revealed":false})");
    EXPECT_EQ(kFeatureKeyboardFocus, "keyboard-focus");
    EXPECT_EQ(capabilitiesJson(features(false, false, true, false, false, false, false, false, false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","appmenu","keyboard-focus"]})");
    EXPECT_EQ(capabilitiesJson(features(false, false, true)).find("keyboard-focus"), std::string::npos) << "only when advertised";
}

TEST(Protocol, MinimizeRequestJson) {
    EXPECT_EQ(minimizeRequestJson("55d3c2a0b1f0"), R"({"v":"gfc/1","type":"minimize-request","address":"55d3c2a0b1f0"})");
}

TEST(Protocol, MinimizedAndRestoredEvents) {
    EXPECT_EQ(minimizedJson("55d3c2a0b1f0"), R"({"v":"gfc/1","type":"minimized","address":"55d3c2a0b1f0"})");
    EXPECT_EQ(restoredJson("55d3c2a0b1f0"), R"({"v":"gfc/1","type":"restored","address":"55d3c2a0b1f0"})");
    EXPECT_EQ(restoredJson(R"(x"})"), R"({"v":"gfc/1","type":"restored","address":"x\"}"})");
}

TEST(Protocol, ConfigAllowlist) {
    EXPECT_EQ(parseDoubleClickAction("titlebarDoubleClick", "zoom"), DoubleClickAction::Zoom);
    EXPECT_EQ(parseDoubleClickAction("titlebarDoubleClick", "minimize"), DoubleClickAction::Minimize);
    EXPECT_EQ(parseDoubleClickAction("titlebarDoubleClick", "none"), DoubleClickAction::None);
    EXPECT_EQ(parseDoubleClickAction("titlebarDoubleClick", "fill"), DoubleClickAction::Fill) << "macOS 26/27 Fill (ADR-0036 step 1)";
    EXPECT_FALSE(parseDoubleClickAction("titlebarDoubleClick", "Fill"));
    EXPECT_FALSE(parseDoubleClickAction("titlebarDoubleClick", "Zoom"));
    EXPECT_FALSE(parseDoubleClickAction("titlebarDoubleClick", "zoom "));
    EXPECT_FALSE(parseDoubleClickAction("titlebarDoubleClick", ""));
    EXPECT_FALSE(parseDoubleClickAction("titlebarDoubleClick", std::string_view("zoom\0", 5)));
    EXPECT_FALSE(parseDoubleClickAction("appearance", "zoom"));
    EXPECT_FALSE(parseDoubleClickAction("", "zoom"));
}

// Audit UX-06: the chrome follows the appearance the shell pushes (config "appearance", feature "appearance").
TEST(Protocol, AppearanceConfigAndFeature) {
    using gf::theme::Appearance;
    EXPECT_EQ(parseAppearance("appearance", "dark"), Appearance::Dark);
    EXPECT_EQ(parseAppearance("appearance", "light"), Appearance::Light);
    for (const std::string_view bad : {"auto", "Dark", "light ", "", "dark\"); os.exit() --"})
        EXPECT_FALSE(parseAppearance("appearance", bad).has_value()) << bad;
    EXPECT_FALSE(parseAppearance("titlebarDoubleClick", "dark").has_value());
    EXPECT_FALSE(parseAppearance("appearance", std::string_view("dark\0", 5)).has_value());
    EXPECT_EQ(kConfigAppearance, "appearance");
    EXPECT_EQ(kFeatureAppearance, "appearance");
    // Last in the list, only with config.
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","appearance"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, false, false, false, false, false, false, false, false, true, true, false)).find("appearance"), std::string::npos);
}

TEST(Protocol, JsonEscapeQuotesBackslashAndControls) {
    EXPECT_EQ(jsonEscape(R"(a"b\c)"), R"(a\"b\\c)");
    EXPECT_EQ(jsonEscape("line\nnext\ttab\r\b\f"), R"(line\nnext\ttab\r\b\f)");
    EXPECT_EQ(jsonEscape(std::string_view("\x01\x1f", 2)), R"(\u0001\u001f)");
    EXPECT_EQ(jsonEscape(std::string_view("nul\0x", 5)), R"(nul\u0000x)");
}

TEST(Protocol, JsonEscapeKeepsUtf8) {
    EXPECT_EQ(jsonEscape("Fenêtre — 窓"), "Fenêtre — 窓");
}

TEST(Protocol, EscapedAddressCannotBreakTheObject) {
    EXPECT_EQ(minimizeRequestJson(R"(x","type":"evil)"), R"({"v":"gfc/1","type":"minimize-request","address":"x\",\"type\":\"evil"})");
}

TEST(Protocol, NamesAreStable) {
    EXPECT_EQ(kVersion, "gfc/1");
    EXPECT_EQ(kEventName, "grassfield");
    EXPECT_EQ(kHyprctlCommand, "grassfield");
    EXPECT_EQ(kLuaNamespace, "grassfield");
    EXPECT_EQ(kLuaHello, "hello");
    EXPECT_EQ(kLuaMinimize, "minimize");
    EXPECT_EQ(kLuaRestore, "restore");
    EXPECT_EQ(kLuaConfig, "config");
    EXPECT_EQ(kLuaAppmenu, "appmenu");
    EXPECT_EQ(kFeatureMinimize, "minimize");
    EXPECT_EQ(kFeatureConfig, "config");
    EXPECT_EQ(kFeatureAppmenu, "appmenu");
    EXPECT_EQ(kFeatureOverview, "overview");
    EXPECT_EQ(kFeatureDesktopFocus, "desktop-focus");
    EXPECT_EQ(kFeatureDesktopFocusV2, "desktop-focus-v2");
    EXPECT_EQ(kFeatureStagesAvailable, "stages-available");
    EXPECT_EQ(kFeatureStages, "stages");
    EXPECT_EQ(kLuaStages, "stages");
    EXPECT_EQ(kConfigTitlebarDoubleClick, "titlebarDoubleClick");
}

TEST(Protocol, LuaDispatchRequestIsWhatTheShellSends) {
    // Hyprland wraps it as `return hl.dispatch(hl.plugin.grassfield.hello())`.
    EXPECT_EQ(luaDispatchRequest(kLuaHello), "hl.plugin.grassfield.hello()");
}

// Hyprland 0.56.2 cuts a socket2 event's data at 1024 bytes (CEventManager::formatEvent, read from the binary; 22 stages
// events were cut in the integrator's nested run of 2026-10-24). Every event builder, at its worst case: every feature,
// the longest ids and names a client can give, and for Stages 64 windows on 4 monitors (the full state goes through the
// request socket, `hyprctl grassfield-stages`, which has no such limit).
TEST(Protocol, EveryEventStaysUnderHyprlandsSocket2Limit) {
    const std::string maxAddress = "ffffffffffffffff";
    const auto        under      = [](const std::string& json) { return json.size() < kMaxEventBytes; };

    const auto all = features(true, true, true, true, true, true, true, true, true, true, true, true, true, true, true);
    EXPECT_TRUE(under(capabilitiesJson(all))) << capabilitiesJson(all).size();
    EXPECT_TRUE(under(minimizeRequestJson(maxAddress)));
    EXPECT_TRUE(under(minimizedJson(maxAddress)));
    EXPECT_TRUE(under(restoredJson(maxAddress)));

    // appmenu: the service and the path are client text, validated to at most 255 bytes of [A-Za-z0-9_.:/-] (no escaping).
    const std::string service = ":1." + std::string(gf::appmenu::kMaxNameLength - 3, '2');
    const std::string path    = "/" + std::string(254, 'a');
    ASSERT_TRUE(gf::appmenu::isValidBusName(service));
    ASSERT_TRUE(gf::appmenu::isValidObjectPath(path));
    const auto appmenu = appmenuJson(maxAddress, service, path, std::numeric_limits<int>::max());
    EXPECT_TRUE(under(appmenu)) << appmenu.size();

    EXPECT_TRUE(under(gf::overview::eventJson(gf::overview::Phase::Closing, std::numeric_limits<size_t>::max(), gf::overview::Reason::Interrupted)));

    const gf::overviewfocus::Event focus{.outcome   = gf::overviewfocus::Outcome::Unavailable,
                                         .target    = gf::overviewfocus::Target::Remembered,
                                         .id        = std::numeric_limits<uint32_t>::max(),
                                         .window    = std::numeric_limits<uint64_t>::max(),
                                         .workspace = std::numeric_limits<int64_t>::min(),
                                         .reason    = "refused-by-hyprland"}; // the longest reason
    EXPECT_TRUE(under(gf::overviewfocus::eventJson(focus)));
    EXPECT_EQ(gf::overviewfocus::eventJson(focus).size(), 192U) << "the worst case the ADR-0007 amendment 2026-10-24 states";

    EXPECT_TRUE(under(gf::stages::noticeJson(std::numeric_limits<uint64_t>::max(), false, gf::stages::Reason::Interrupted)));

    // The full Stages state with 64 windows on 4 monitors is far over the limit: it must never be an event.
    std::vector<gf::stages::EventMonitor> monitors(4);
    uint64_t                              id = 0x100000000000;
    for (size_t m = 0; m < monitors.size(); ++m) {
        monitors[m].monitor   = "MONITOR-" + std::to_string(m);
        monitors[m].workspace = static_cast<gf::stages::WorkspaceId>(m + 1);
        monitors[m].active    = 1;
        monitors[m].front     = gf::stages::EventFront{.id = id, .app = std::string(gf::stages::kMaxAppBytes, 'a')};
        for (int st = 0; st < 4; ++st) {
            gf::stages::EventStage stage{.id = static_cast<gf::stages::StageId>(st + 1), .slot = st - 1, .windows = {}};
            for (int w = 0; w < 4; ++w)
                stage.windows.push_back(gf::stages::EventWindow{.id = id++, .thumb = gf::stages::Box{1920.05, 1080.05, 188.05, 160.05}});
            monitors[m].stages.push_back(stage);
        }
    }
    const auto state = gf::stages::stateJson(std::numeric_limits<uint64_t>::max(), true, monitors);
    EXPECT_GT(state.size(), kMaxEventBytes) << "64 windows on 4 monitors: only the request socket can carry it";

    // Window tiling (ADR-0036): the notice is bounded; the state (every tile record) is the reply of hyprctl grassfield-tiling.
    EXPECT_TRUE(under(gf::tiling::noticeJson(std::numeric_limits<uint64_t>::max(), gf::tiling::Reason::Unavailable)));
}

// ADR-0036 D78: zoom-fill (tile(address, "zoom"), Zoom is Fill) always right after window-tiling, never without it: the
// shell's Window > Zoom asks for Fill only with it, Hyprland's maximized mode otherwise (gate C2).
TEST(Protocol, ZoomFillComesRightAfterWindowTiling) {
    EXPECT_EQ(kFeatureZoomFill, "zoom-fill");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","window-tiling","zoom-fill"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true, true, true, true, true, true, false, true, true, true, true, true, true, true, true, true, true))
                  .find("zoom-fill"),
              std::string::npos)
        << "never without window-tiling";
}

// ADR-0036 step 1: tiling-arrange (hl.plugin.grassfield.arrange, the tiling notice and its hyprctl state) comes only with
// window-tiling, last in the list; step 4a: tiling-layouts (arrange's "with", the reply's suggestion) right after it.
TEST(Protocol, TilingArrangeComesWithWindowTiling) {
    EXPECT_EQ(kFeatureTilingArrange, "tiling-arrange");
    EXPECT_EQ(kFeatureTilingLayouts, "tiling-layouts");
    EXPECT_EQ(kLuaArrange, "arrange");
    EXPECT_EQ(kHyprctlTilingCommand, "grassfield-tiling");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, true, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","window-tiling","zoom-fill","tiling-arrange","tiling-layouts"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config"]})")
        << "never without window-tiling";
    EXPECT_EQ(luaDispatchRequest(kLuaArrange), "hl.plugin.grassfield.arrange()");
}

// ADR-0036 step 4b: tiling-groups (group_front) comes last, only with window-tiling and tiling-arrange.
TEST(Protocol, TilingGroupsComeWithTilingArrange) {
    EXPECT_EQ(kFeatureTilingGroups, "tiling-groups");
    EXPECT_EQ(kLuaGroupFront, "group_front");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, true, false, false, false, false, false, true, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","window-tiling","zoom-fill","tiling-arrange","tiling-layouts","tile-hover","tiling-groups"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, true, false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","window-tiling","zoom-fill"]})")
        << "never without tiling-arrange";
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config"]})")
        << "never without window-tiling";
}

// ADR-0036 step 4c: tiling-shared-edge (the shared edge's handle) comes last, only with window-tiling and tiling-arrange.
TEST(Protocol, TilingSharedEdgeComesWithTilingArrange) {
    EXPECT_EQ(kFeatureTilingSharedEdge, "tiling-shared-edge");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, true, false, false, false, false, false, true, true, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","window-tiling","zoom-fill","tiling-arrange","tiling-layouts","tile-hover","tiling-groups","tiling-shared-edge"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, true, false, false, false, false, false, true, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","window-tiling","zoom-fill","tiling-arrange","tiling-layouts","tiling-shared-edge"]})")
        << "without the groups' verb";
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, true, false, false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","window-tiling","zoom-fill"]})")
        << "never without tiling-arrange";
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config"]})")
        << "never without window-tiling";
}

// ADR-0036 step 6a: tiling-split (the Split View Desktops) comes last, only with window-tiling and tiling-arrange.
TEST(Protocol, TilingSplitComesWithTilingArrange) {
    EXPECT_EQ(kFeatureTilingSplit, "tiling-split");
    EXPECT_EQ(kFeatureTilingSplitRows, "tiling-split-rows") << "step 6d: unsplit's second argument, always with tiling-split";
    EXPECT_EQ(kFeatureTilingSplitTitles, "tiling-split-titles") << "step 6e: a member's titlebar away, always after tiling-split-rows";
    EXPECT_EQ(kLuaSplit, "split");
    EXPECT_EQ(kLuaUnsplit, "unsplit");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, true, false, false, false, false, false, true, true, true, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","window-tiling","zoom-fill","tiling-arrange","tiling-layouts","tile-hover","tiling-groups","tiling-shared-edge","tiling-split","tiling-split-rows","tiling-split-titles"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, true, false, false, false, false, false, true, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","window-tiling","zoom-fill","tiling-arrange","tiling-layouts","tiling-split","tiling-split-rows","tiling-split-titles"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, true, false, false, false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","window-tiling","zoom-fill"]})")
        << "never without tiling-arrange";
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config"]})")
        << "never without window-tiling";
}

TEST(Protocol, ToplevelDragIsAdvertisedLastAndAlone) {
    // ADR-0036 amendment 2026-11-08 (URR-030): informational, the shell needs nothing; on its own, after every other feature.
    EXPECT_EQ(kFeatureToplevelDrag, "toplevel-drag");
    EXPECT_EQ(capabilitiesJson(features(false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
                                        false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","toplevel-drag"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, true, false, false, false, false, false, true, false, false, false,
                                        true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","window-tiling","zoom-fill","tiling-arrange","tiling-layouts","tiling-split","tiling-split-rows","tiling-split-titles","toplevel-drag"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true)), R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu"]})")
        << "off by default";
}

TEST(Protocol, TileHoverComesWithWindowTiling) {
    EXPECT_EQ(kFeatureTileHover, "tile-hover");
    EXPECT_EQ(kLuaTilePopover, "tile_popover");
    EXPECT_EQ(kLuaMoveTo, "move_to");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, true, false, false, false, false, false, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","window-tiling","zoom-fill","tiling-arrange","tiling-layouts","tile-hover"]})");
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, true, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config","window-tiling","zoom-fill","tile-hover"]})")
        << "independent of tiling-arrange";
    EXPECT_EQ(capabilitiesJson(features(false, true, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","config"]})")
        << "never without window-tiling";
}
