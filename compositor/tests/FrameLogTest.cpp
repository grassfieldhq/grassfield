// Presented-frame timestamps (ADR-0006 gate P3, core/FrameLog.hpp): the ring keeps the last kCapacity frames in time order,
// the JSON `hyprctl grassfield-frames` returns, and the feature name.

#include "core/FrameLog.hpp"
#include "core/Protocol.hpp"

#include <gtest/gtest.h>

#include <cmath>
#include <string>
#include <vector>

using namespace gf::frames;

TEST(FrameLog, KeepsFramesOldestFirst) {
    CRing ring;
    EXPECT_TRUE(ring.push(100));
    EXPECT_TRUE(ring.push(116));
    EXPECT_TRUE(ring.push(133));
    EXPECT_EQ(ring.snapshot(), (std::vector<uint64_t>{100, 116, 133}));
    EXPECT_EQ(ring.total(), 3U);
}

TEST(FrameLog, AFrameThatIsNotNewerIsRefused) {
    CRing ring;
    EXPECT_TRUE(ring.push(1000));
    EXPECT_FALSE(ring.push(1000)) << "a duplicate presentation event";
    EXPECT_FALSE(ring.push(999)) << "a clock that went backwards";
    EXPECT_EQ(ring.snapshot(), (std::vector<uint64_t>{1000}));
    EXPECT_EQ(ring.total(), 1U);
}

TEST(FrameLog, OnlyTheLastCapacityFramesAreKept) {
    CRing ring;
    for (uint64_t i = 1; i <= kCapacity + 10; ++i)
        ASSERT_TRUE(ring.push(i * 16667));
    const auto s = ring.snapshot();
    ASSERT_EQ(s.size(), kCapacity);
    EXPECT_EQ(s.front(), 11U * 16667) << "the 10 oldest were overwritten";
    EXPECT_EQ(s.back(), (kCapacity + 10) * 16667);
    EXPECT_EQ(ring.total(), kCapacity + 10);
    for (size_t i = 1; i < s.size(); ++i)
        ASSERT_LT(s[i - 1], s[i]) << "time order across the wrap";
}

namespace {
    // The loop records of a reply with no beat (the probe not recording, or a plugin that never beat). Built when a test asks
    // for it, not at static initialisation (bugprone-throwing-static-initialization: a throw there could not be caught).
    std::string noLoop() {
        return R"(,"loop":{"beats":0,"stalls":[],"work":[]}})";
    }
}

TEST(FrameLog, JsonNamesTheClockAndEachMonitor) {
    const std::vector<MonitorFrames> m{{.name = "GF-REF", .refreshHz = 60, .total = 2, .presentedUs = {10, 26}, .renders = {}},
                                       {.name = "WAYLAND-1", .refreshHz = 59.951, .total = 0, .presentedUs = {}, .renders = {}}};
    EXPECT_EQ(framesJson(m), R"({"v":"gfc/1","type":"frames","clock":"monotonic","unit":"us","monitors":[)"
                             R"({"name":"GF-REF","refreshHz":60.000,"total":2,"presented":[10,26],"renders":[]},)"
                             R"({"name":"WAYLAND-1","refreshHz":59.951,"total":0,"presented":[],"renders":[]}],"marks":[])" + noLoop());
    EXPECT_EQ(framesJson({}), R"({"v":"gfc/1","type":"frames","clock":"monotonic","unit":"us","monitors":[],"marks":[])" + noLoop());
}

TEST(FrameLog, JsonIsSafeWithOddMonitorData) {
    const std::vector<MonitorFrames> odd{{.name = "a\"b\\c\n", .refreshHz = std::nan(""), .total = 0, .presentedUs = {}, .renders = {}}};
    EXPECT_EQ(framesJson(odd), R"({"v":"gfc/1","type":"frames","clock":"monotonic","unit":"us","monitors":[)"
                               R"({"name":"a\"b\\c\n","refreshHz":0.000,"total":0,"presented":[],"renders":[]}],"marks":[])" + noLoop());
    // A long name is cut on a UTF-8 boundary: 63 ASCII bytes then a 2-byte character that would straddle byte 64.
    const std::string                longName = std::string(63, 'x') + "\xc3\xa9" + "tail";
    const std::vector<MonitorFrames> named{{.name = longName, .refreshHz = 60, .total = 0, .presentedUs = {}, .renders = {}}};
    EXPECT_NE(framesJson(named).find("\"name\":\"" + std::string(63, 'x') + "\""), std::string::npos);
    std::vector<MonitorFrames> many(kMaxMonitors + 3, MonitorFrames{.name = "M", .refreshHz = 60, .total = 0, .presentedUs = {}, .renders = {}});
    const auto                 json  = framesJson(many);
    size_t                     count = 0;
    for (size_t at = json.find("\"name\""); at != std::string::npos; at = json.find("\"name\"", at + 1))
        ++count;
    EXPECT_EQ(count, kMaxMonitors);
}

// Attribution (integrator run 2026-10-24: the Overview missed its frames; whose cost was it?): each rendered frame's CPU span
// and the plugin's animation phases, on the presentation clock.
TEST(FrameLog, RenderSpansAreKeptInTimeOrder) {
    CSpanRing ring;
    EXPECT_TRUE(ring.push({.beginUs = 100, .cpuUs = 4000}));
    EXPECT_FALSE(ring.push({.beginUs = 100, .cpuUs = 1})) << "not after the newest";
    EXPECT_TRUE(ring.push({.beginUs = 16800, .cpuUs = 21000}));
    EXPECT_EQ(ring.snapshot(), (std::vector<RenderSpan>{{.beginUs = 100, .cpuUs = 4000}, {.beginUs = 16800, .cpuUs = 21000}}));
    for (uint64_t i = 1; i <= kCapacity + 5; ++i)
        ASSERT_TRUE(ring.push({.beginUs = 20000 + i, .cpuUs = i}));
    const auto s = ring.snapshot();
    ASSERT_EQ(s.size(), kCapacity);
    EXPECT_EQ(s.front().beginUs, 20000U + 6U) << "the oldest overwritten";
}

TEST(FrameLog, MarksAreCutAndOrdered) {
    CMarkRing marks;
    EXPECT_TRUE(marks.push(500, "overview-opening"));
    EXPECT_TRUE(marks.push(500, "overview-open")) << "the same instant is allowed";
    EXPECT_FALSE(marks.push(499, "late")) << "older than the newest";
    EXPECT_TRUE(marks.push(900, std::string(40, 'x')));
    const auto s = marks.snapshot();
    ASSERT_EQ(s.size(), 3U);
    EXPECT_EQ(s[2].what, std::string(kMaxMarkBytes, 'x'));
    for (uint64_t i = 0; i < kMaxMarks + 2; ++i)
        ASSERT_TRUE(marks.push(1000 + i, "m"));
    EXPECT_EQ(marks.snapshot().size(), kMaxMarks);
    EXPECT_EQ(marks.snapshot().front().us, 1002U);
}

TEST(FrameLog, JsonCarriesRendersAndMarks) {
    const std::vector<MonitorFrames> m{{.name = "GF-REF", .refreshHz = 60, .total = 1, .presentedUs = {10}, .renders = {{.beginUs = 3, .cpuUs = 7}, {.beginUs = 20, .cpuUs = 18000}}}};
    const std::vector<Mark>          marks{{.us = 5, .what = "overview-opening"}, {.us = 9, .what = "a\"b"}};
    EXPECT_EQ(framesJson(m, marks), R"({"v":"gfc/1","type":"frames","clock":"monotonic","unit":"us","monitors":[)"
                                    R"({"name":"GF-REF","refreshHz":60.000,"total":1,"presented":[10],"renders":[[3,7],[20,18000]]}],)"
                                    R"("marks":[{"t":5,"what":"overview-opening"},{"t":9,"what":"a\"b"}])" + noLoop());
}

// Integrator review of a6d04df (MAJOR 2): a main-loop stall before a render shows only as a late render. A beat of the loop
// later than kStallUs past its due time records the stall; the plugin's own work outside a render is recorded beside it.
TEST(FrameLog, ALateBeatIsAStallFromItsDueTime) {
    EXPECT_FALSE(stallOf(10'000, 10'000, 0).has_value());
    EXPECT_FALSE(stallOf(10'000, 10'000 + kStallUs, 0).has_value()) << "within kStallUs: on time";
    EXPECT_EQ(stallOf(10'000, 10'001 + kStallUs, 7), (Stall{.beginUs = 10'000, .lengthUs = kStallUs + 1, .cpuUs = 7}));
    EXPECT_EQ(stallOf(10'000, 60'000, 51'000), (Stall{.beginUs = 10'000, .lengthUs = 50'000, .cpuUs = 51'000})) << "a 50 ms stall, the thread working";
    EXPECT_EQ(stallOf(10'000, 60'000, 900).value_or(Stall{}).cpuUs, 900U) << "the same stall with the thread waiting";
    EXPECT_FALSE(stallOf(10'000, 9'000, 0).has_value()) << "early (a timer that fired before its due time)";
    EXPECT_LE(kStallUs, kBeatUs);
}

// Integrator re-review of ce82fd3: a hold is recorded at most one beat short, so a 12 ms hold before a 3 ms render must read
// as over the attribution's budget, 0.8 of a 60 Hz period (13.3 ms); a beat of 4 ms let it pass.
TEST(FrameLog, TheBeatSeesAHoldThatMissesAFrame) {
    constexpr double kBudgetUs = 0.8 * 1e6 / 60;
    EXPECT_GT(static_cast<double>(12'000 - kBeatUs + 3'000), kBudgetUs);
    // The hold begins just after a beat ran: the next beat, due kBeatUs later, runs when the hold ends.
    const uint64_t ran  = 100'000;
    const auto     seen = stallOf(ran + kBeatUs, ran + 12'000, 12'000);
    ASSERT_TRUE(seen.has_value());
    EXPECT_GE(seen.value_or(Stall{}).lengthUs, 12'000 - kBeatUs);
}

TEST(FrameLog, StallsAreKeptInTimeOrder) {
    CStallRing ring;
    EXPECT_TRUE(ring.push({.beginUs = 100, .lengthUs = 3000, .cpuUs = 10}));
    EXPECT_FALSE(ring.push({.beginUs = 100, .lengthUs = 1, .cpuUs = 1})) << "not after the newest";
    EXPECT_TRUE(ring.push({.beginUs = 8000, .lengthUs = 50'000, .cpuUs = 49'000}));
    EXPECT_EQ(ring.snapshot(), (std::vector<Stall>{{.beginUs = 100, .lengthUs = 3000, .cpuUs = 10}, {.beginUs = 8000, .lengthUs = 50'000, .cpuUs = 49'000}}));
    ring.clear();
    EXPECT_TRUE(ring.snapshot().empty());
}

TEST(FrameLog, JsonCarriesTheLoopsStallsAndThePluginsWork) {
    const LoopRecords loop{.beats  = 250,
                           .stalls = {{.beginUs = 100, .lengthUs = 50'000, .cpuUs = 1200}},
                           .work   = {{.beginUs = 7, .cpuUs = 300}, {.beginUs = 90, .cpuUs = 12}}};
    EXPECT_EQ(framesJson({}, {}, loop), R"({"v":"gfc/1","type":"frames","clock":"monotonic","unit":"us","monitors":[],"marks":[],)"
                                        R"("loop":{"beats":250,"stalls":[[100,50000,1200]],"work":[[7,300],[90,12]]}})");
}

// Review of part B, 2026-10-24: off unless a measurement asked, bounded, and nothing kept from a locked session.
TEST(FrameLog, RecordingIsOffUntilStartedAndStopsByItself) {
    CRecording r;
    EXPECT_FALSE(r.active(1000)) << "off by default";
    r.start(1000);
    EXPECT_TRUE(r.active(1000));
    EXPECT_TRUE(r.active(1000 + kMaxRecordingMs - 1));
    EXPECT_FALSE(r.active(1000 + kMaxRecordingMs)) << "auto-stop";
    r.start(50'000);
    EXPECT_EQ(r.untilMs(), 50'000 + kMaxRecordingMs) << "a new start extends it";
    EXPECT_FALSE(r.active(49'999)) << "a clock that went backwards";
    r.stop();
    EXPECT_FALSE(r.active(50'001));
}

TEST(FrameLog, RingsForgetEverythingOnClear) {
    CRing frames;
    ASSERT_TRUE(frames.push(10));
    frames.clear();
    EXPECT_TRUE(frames.snapshot().empty());
    EXPECT_EQ(frames.total(), 0U);
    EXPECT_TRUE(frames.push(5)) << "after a clear, any time is accepted";
    CSpanRing spans;
    ASSERT_TRUE(spans.push({.beginUs = 10, .cpuUs = 1}));
    spans.clear();
    EXPECT_TRUE(spans.snapshot().empty());
    EXPECT_TRUE(spans.push({.beginUs = 5, .cpuUs = 1}));
    CMarkRing marks;
    ASSERT_TRUE(marks.push(10, "overview-open"));
    marks.clear();
    EXPECT_TRUE(marks.snapshot().empty());
    EXPECT_TRUE(marks.push(5, "overview-closed"));
}

TEST(FrameLog, FeatureName) {
    using namespace gf::gfc;
    EXPECT_EQ(kFeatureFrameTimes, "frame-times");
    EXPECT_EQ(gf::frames::kHyprctlCommand, "grassfield-frames");
    EXPECT_EQ(gf::frames::kHyprctlStartCommand, "grassfield-frames-start");
    EXPECT_EQ(capabilitiesJson(features(false, false, false, false, false, false, false, false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","frame-times"]})");
}
