// Mutation fuzzing of every core parser that reads text another process of the user can send (ADR-0041 step 5, T-1):
// the gfc/1 request readers (overview, overview_focus, stages, arrange), the config key/value readers, the window address
// and D-Bus address validators, the JSON reader, the two text sanitisers whose output goes into events, and the name
// readers (a layer namespace, a Split View side, an xdg interface name). Each parser is fed a corpus of valid requests,
// mutated in the tree (byte flips, token insertion, number extremes, invalid UTF-8, nesting, growth past the payload cap,
// splices of two entries), for GF_FUZZ_ITERATIONS rounds (default 2000) from GF_FUZZ_SEED (default 1): the same seed
// gives the same inputs, so a finding reproduces. Properties: no crash (the ASan/UBSan build of
// compositor/build-direct.sh tests-asan runs this file too), a bounded CPU time per call (a reader that explodes on
// nesting or length is as harmful as a crash inside the compositor), the same answer when the same text is read twice,
// and, for an accepted input, every invariant the header promises (caps, distinctness, ranges, grammar). No libFuzzer,
// no dependency.
#include "core/Appmenu.hpp"
#include "core/ClientChrome.hpp"
#include "core/DesktopFocus.hpp"
#include "core/Json.hpp"
#include "core/LayerPointer.hpp"
#include "core/Minimize.hpp"
#include "core/Overview.hpp"
#include "core/OverviewFocus.hpp"
#include "core/Protocol.hpp"
#include "core/Stages.hpp"
#include "core/Tiling.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <functional>
#include <iostream>
#include <limits>
#include <set>
#include <string>
#include <string_view>
#include <vector>

namespace {

    // ---- the in-tree mutator ----------------------------------------------------------------------------------------

    struct Rng {
        uint64_t s;
        explicit Rng(uint64_t seed) : s(seed * 0x9E3779B97F4A7C15ULL + 0x2545F4914F6CDD1DULL) {}
        uint64_t next() { // xorshift64*
            s ^= s >> 12;
            s ^= s << 25;
            s ^= s >> 27;
            return s * 0x2545F4914F6CDD1DULL;
        }
        size_t below(size_t n) { return n == 0 ? 0 : static_cast<size_t>(next() % n); }
        bool   coin() { return (next() & 1) != 0; }
    };

    const std::vector<std::string>& dictionary() {
        static const std::vector<std::string> d = {
            "{", "}", "[", "]", "\"", "\\", ":", ",", " ", "\n", "\t", "null", "true", "false", "-0", "0", "1", "-1", "1e999",
            "-1e999", "1e-999", "NaN", "Infinity", "0x", "0X", "0x0", "0xffffffffffffffff", "0x10000000000000000",
            "2147483648", "4294967296", "18446744073709551616", "99999999999999999999999", "0.1", "1.5", ".5", "5.", "1e",
            "\\u0000", "\\ud800", "\\udfff", "\\uDBFF\\uDFFF", "\\n", "\\\"", "\\/", "\\x", "\xC3\xA9", "\xF0\x9F\x98\x80",
            "\xC0\xAF", "\xED\xA0\x80", "\xFF", "\x80", std::string(1, '\0'), "address", "windows", "on", "durationMs", "curve", "strips",
            "monitor", "tiles", "op", "stage", "new", "target", "workspace", "id", "layout", "zone", "with", "fill", "output",
            "remembered", "window", "none", "press", "activate", "merge", "move", "off", "x", "y", "w", "h", "hidden",
            "quarters", "thirds", "left-quarters", "GF-REF", "../", "/", "//", ".", "..", "org.kde", ":1.", "LOCK"};
        return d;
    }

    struct Mutator {
        Rng    rng;
        size_t maxLen;
        Mutator(uint64_t seed, size_t maxLen) : rng(seed), maxLen(maxLen) {}

        std::string mutate(const std::string& base, const std::vector<std::string>& corpus) {
            std::string s     = base;
            const int   rounds = 1 + static_cast<int>(rng.below(4));
            for (int r = 0; r < rounds; ++r) {
                switch (rng.below(12)) {
                    case 0: flipBit(s); break;
                    case 1: replaceByte(s); break;
                    case 2: insertToken(s); break;
                    case 3: deleteSlice(s); break;
                    case 4: duplicateSlice(s); break;
                    case 5: truncate(s); break;
                    case 6: tweakNumber(s); break;
                    case 7: nest(s); break;
                    case 8: splice(s, corpus); break;
                    case 9: grow(s); break;
                    case 10: insertRaw(s); break;
                    default: swapSlices(s); break;
                }
                if (s.size() > maxLen)
                    s.resize(maxLen);
            }
            return s;
        }

      private:
        size_t pos(const std::string& s) { return rng.below(s.size() + 1); }
        void   flipBit(std::string& s) {
            if (s.empty())
                return;
            const size_t i = rng.below(s.size());
            s[i] = static_cast<char>(static_cast<unsigned char>(s[i]) ^ static_cast<unsigned char>(1u << rng.below(8)));
        }
        void replaceByte(std::string& s) {
            if (s.empty())
                return;
            static const unsigned char specials[] = {0x00, 0xFF, 0x80, '"', '\\', '{', '}', '[', ']', ',', ':', '\n', ' ', '-', '0', '9', 'e', '.', '/'};
            s[rng.below(s.size())] = static_cast<char>(specials[rng.below(sizeof specials)]);
        }
        void insertToken(std::string& s) { s.insert(pos(s), dictionary()[rng.below(dictionary().size())]); }
        void insertRaw(std::string& s) {
            std::string raw(1 + rng.below(8), '\0');
            for (char& c : raw)
                c = static_cast<char>(rng.below(256));
            s.insert(pos(s), raw);
        }
        void deleteSlice(std::string& s) {
            if (s.empty())
                return;
            const size_t a = rng.below(s.size());
            s.erase(a, 1 + rng.below(std::min<size_t>(16, s.size() - a)));
        }
        void duplicateSlice(std::string& s) {
            if (s.empty())
                return;
            const size_t a = rng.below(s.size());
            const size_t n = 1 + rng.below(std::min<size_t>(32, s.size() - a));
            s.insert(pos(s), s.substr(a, n));
        }
        void truncate(std::string& s) {
            if (!s.empty())
                s.resize(rng.below(s.size()));
        }
        void tweakNumber(std::string& s) {
            static const char* extremes[] = {"-0", "0", "1e999", "-1e999", "NaN", "2147483648", "-2147483649", "4294967296",
                                             "18446744073709551616", "1e-999", "0.5", "-5", "1.0e3", "1e", "1.", ".1", "99999999999999999999"};
            size_t             i          = 0;
            while (i < s.size() && !(s[i] >= '0' && s[i] <= '9'))
                ++i;
            if (i == s.size())
                return;
            size_t j = i;
            while (j < s.size() && ((s[j] >= '0' && s[j] <= '9') || s[j] == '.' || s[j] == 'e' || s[j] == '-' || s[j] == '+'))
                ++j;
            s.replace(i, j - i, extremes[rng.below(sizeof extremes / sizeof *extremes)]);
        }
        void nest(std::string& s) {
            const size_t depth = 1 + rng.below(64);
            const char   open  = rng.coin() ? '[' : '{';
            s.insert(pos(s), std::string(depth, open));
        }
        void splice(std::string& s, const std::vector<std::string>& corpus) {
            if (corpus.empty())
                return;
            const std::string& other = corpus[rng.below(corpus.size())];
            if (other.empty())
                return;
            const size_t a = rng.below(other.size());
            s.insert(pos(s), other.substr(a, 1 + rng.below(other.size() - a)));
        }
        void grow(std::string& s) {
            if (s.empty())
                return;
            const size_t target = std::min(maxLen, s.size() * (2 + rng.below(8)) + 1);
            const size_t a      = rng.below(s.size());
            const size_t n      = 1 + rng.below(std::min<size_t>(64, s.size() - a));
            const std::string chunk = s.substr(a, n);
            while (s.size() < target)
                s.insert(std::min(pos(s), s.size()), chunk);
        }
        void swapSlices(std::string& s) {
            if (s.size() < 4)
                return;
            const size_t a = rng.below(s.size() / 2), b = s.size() / 2 + rng.below(s.size() / 2);
            std::swap(s[a], s[b]);
        }
    };

    // ---- the harness ------------------------------------------------------------------------------------------------

    uint64_t envNumber(const char* name, uint64_t fallback) {
        const char* v = std::getenv(name);
        if (!v || !*v)
            return fallback;
        char*               end = nullptr;
        const unsigned long long n = std::strtoull(v, &end, 10);
        return (end && *end == '\0') ? static_cast<uint64_t>(n) : fallback;
    }

    uint64_t iterations() { return envNumber("GF_FUZZ_ITERATIONS", 2000); }
    uint64_t seed() { return envNumber("GF_FUZZ_SEED", 1); }

    std::string printable(std::string_view s) {
        std::string out;
        for (unsigned char c : s.substr(0, 200)) {
            if (c >= 0x20 && c < 0x7F && c != '\\')
                out += static_cast<char>(c);
            else {
                char buf[8];
                std::snprintf(buf, sizeof buf, "\\x%02X", c);
                out += buf;
            }
        }
        if (s.size() > 200)
            out += "...(" + std::to_string(s.size()) + " bytes)";
        return out;
    }

    // Bounds a reader must keep per call, in CPU time of this thread (a loaded machine stretches the wall clock, not the
    // work; the integrator's review of 265e6c7, minor 6), wider under the sanitizers (an -O0 ASan build does the same
    // work several times slower): a reader that takes longer on one input has a complexity problem (deep nesting,
    // quadratic copies), which is the finding.
#if defined(__SANITIZE_ADDRESS__)
    constexpr bool kSanitized = true;
#elif defined(__has_feature)
#if __has_feature(address_sanitizer) || __has_feature(undefined_behavior_sanitizer)
    constexpr bool kSanitized = true;
#else
    constexpr bool kSanitized = false;
#endif
#else
    constexpr bool kSanitized = false;
#endif
    constexpr double kMaxCallMs = kSanitized ? 200.0 : 50.0;
    constexpr double kMaxMeanUs = kSanitized ? 8000.0 : 2000.0;

    double cpuUs() {
        timespec ts{};
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
        return static_cast<double>(ts.tv_sec) * 1e6 + static_cast<double>(ts.tv_nsec) / 1e3;
    }

    struct Stats {
        uint64_t accepted = 0, rejected = 0;
        size_t   maxLen    = 0;
        double   maxCallUs = 0, totalUs = 0;
    };

    // Runs `check(input)` for every mutated input; `check` returns true when the parser accepted it and must assert its
    // own invariants. The corpus itself is read first (every seed must be accepted: a broken corpus proves nothing). A
    // `tweak` is a parser-specific operation the generic ones seldom reach: one input in eight is a corpus entry with the
    // tweak alone (an operation that must land on a valid request to matter), and one mutated input in four gets it too.
    void fuzz(const char* name, const std::vector<std::string>& corpus, size_t cap, const std::function<bool(const std::string&)>& check,
              const std::function<void(std::string&, Rng&)>& tweak = {}) {
        Mutator mutator(seed() ^ std::hash<std::string_view>{}(name), cap * 2 + 64);
        for (const std::string& c : corpus)
            EXPECT_TRUE(check(c)) << name << ": the corpus entry is not accepted: " << printable(c);
        Stats st;
        const uint64_t n = iterations();
        for (uint64_t i = 0; i < n; ++i) {
            std::string  input = corpus[mutator.rng.below(corpus.size())];
            const size_t roll  = tweak ? mutator.rng.below(8) : 1;
            if (roll != 0)
                input = mutator.mutate(input, corpus);
            if (tweak && (roll == 0 || mutator.rng.below(4) == 0))
                tweak(input, mutator.rng);
            st.maxLen       = std::max(st.maxLen, input.size());
            const double t0 = cpuUs();
            const bool   ok = check(input);
            const double us = cpuUs() - t0;
            st.totalUs += us;
            st.maxCallUs = std::max(st.maxCallUs, us);
            ok ? ++st.accepted : ++st.rejected;
            EXPECT_LT(us, kMaxCallMs * 1000.0) << name << " took " << us / 1000.0 << " ms on iteration " << i << " (seed " << seed()
                                               << "): " << printable(input);
            if (::testing::Test::HasFailure()) {
                std::cout << "[fuzz] " << name << ": FAILED on iteration " << i << " of seed " << seed() << "\n";
                return;
            }
        }
        const double meanUs = n ? st.totalUs / static_cast<double>(n) : 0.0;
        EXPECT_LT(meanUs, kMaxMeanUs) << name << ": mean " << meanUs << " us per call";
        std::cout << "[fuzz] " << name << ": iterations=" << n << " accepted=" << st.accepted << " rejected=" << st.rejected
                  << " maxLen=" << st.maxLen << " mean_us=" << static_cast<long>(meanUs) << " max_call_us=" << static_cast<long>(st.maxCallUs)
                  << " seed=" << seed() << "\n";
    }

    bool validUtf8(std::string_view s) {
        size_t i = 0;
        while (i < s.size()) {
            const unsigned char c = static_cast<unsigned char>(s[i]);
            size_t              n = 0;
            uint32_t            cp = 0;
            if (c < 0x80) {
                ++i;
                continue;
            }
            if (c >= 0xC2 && c <= 0xDF) {
                n  = 1;
                cp = c & 0x1F;
            } else if (c >= 0xE0 && c <= 0xEF) {
                n  = 2;
                cp = c & 0x0F;
            } else if (c >= 0xF0 && c <= 0xF4) {
                n  = 3;
                cp = c & 0x07;
            } else
                return false;
            if (i + n >= s.size())
                return false;
            for (size_t k = 1; k <= n; ++k) {
                const unsigned char d = static_cast<unsigned char>(s[i + k]);
                if ((d & 0xC0) != 0x80)
                    return false;
                cp = (cp << 6) | (d & 0x3FU); // unsigned: d & 0x3F alone is an int (promotion), a signed operand of |
            }
            if ((n == 2 && cp < 0x800) || (n == 3 && (cp < 0x10000 || cp > 0x10FFFF)) || (cp >= 0xD800 && cp <= 0xDFFF))
                return false;
            i += n + 1;
        }
        return true;
    }

    bool hexAddressGrammar(std::string_view t) { // optional 0x or 0X, then 1-16 hex digits, nothing else, not zero
        if (t.size() >= 2 && t[0] == '0' && (t[1] == 'x' || t[1] == 'X'))
            t.remove_prefix(2);
        if (t.empty() || t.size() > 16)
            return false;
        bool nonZero = false;
        for (char c : t) {
            const bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
            if (!hex)
                return false;
            nonZero = nonZero || c != '0';
        }
        return nonZero;
    }

    bool nameChars(std::string_view s) {
        return std::ranges::all_of(s, [](char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'; });
    }

} // namespace

// ---- gfc/1 requests -----------------------------------------------------------------------------------------------

TEST(ParserFuzz, OverviewRequest) {
    using namespace gf::overview;
    const std::vector<std::string> corpus = {
        R"({"on":true,"durationMs":350,"windows":[{"address":"0x55d0c0a1b2c0","x":1500,"y":120,"w":560,"h":400},{"address":"0x55d0c0a1b2c1","x":10,"y":20,"w":300,"h":200}]})",
        R"({"on":false,"durationMs":0})",
        R"({"on":false,"durationMs":300,"curve":[0.4,0,1,1]})",
        R"( { "on" : true , "durationMs" : 0 , "windows" : [ ] } )",
        R"({"future":{"a":[1,2,{"b":null}],"c":"x\"y"},"on":true,"durationMs":10,"windows":[{"address":"0x1","x":0,"y":0,"w":1,"h":1}]})",
        R"({"on":true,"durationMs":0,"windows":[],"emoji":"😀 é \/"})"};
    fuzz("overview.parseRequest", corpus, kMaxPayloadBytes, [](const std::string& in) {
        const auto a = parseRequest(in);
        const auto b = parseRequest(in);
        EXPECT_EQ(a.has_value(), b.has_value()) << "not deterministic: " << printable(in);
        if (!a)
            return false;
        EXPECT_TRUE(a->on == b->on && a->durationMs == b->durationMs && a->curve == b->curve && a->windows == b->windows) << "two reads differ: " << printable(in);
        EXPECT_LE(in.size(), kMaxPayloadBytes);
        EXPECT_TRUE(std::isfinite(a->durationMs) && a->durationMs >= 0 && a->durationMs <= kMaxDurationMs) << printable(in);
        EXPECT_LE(a->windows.size(), kMaxWindows);
        std::set<uint64_t> seen;
        for (const WindowTarget& w : a->windows) {
            EXPECT_NE(w.address, 0u);
            EXPECT_TRUE(seen.insert(w.address).second) << "address twice: " << printable(in);
            EXPECT_TRUE(gf::minimize::isFinite(w.rect));
            EXPECT_GE(w.rect.w, 1.0);
            EXPECT_GE(w.rect.h, 1.0);
        }
        for (double x : {a->curve.x1, a->curve.x2})
            EXPECT_TRUE(x >= 0.0 && x <= 1.0) << printable(in);
        for (double y : {a->curve.y1, a->curve.y2})
            EXPECT_TRUE(y >= kMinCurveY && y <= kMaxCurveY) << printable(in);
        return true;
    });
}

TEST(ParserFuzz, OverviewFocusRequest) {
    using namespace gf::overviewfocus;
    const std::vector<std::string> corpus = {R"({"target":"window","address":"0x55aa01"})", R"({"target":"workspace","workspace":3,"id":7})",
                                             R"({"target":"remembered","address":"0x1"})", R"({"target":"none","id":4294967295})",
                                             R"({"target":"none","later":{"field":[1,2]}})", R"( { "target" : "remembered" , "address" : "0xABC" , "workspace" : 2 } )"};
    fuzz("overviewfocus.parseRequest", corpus, kMaxPayloadBytes, [](const std::string& in) {
        const auto a = parseRequest(in);
        EXPECT_EQ(a.has_value(), parseRequest(in).has_value());
        if (!a)
            return false;
        EXPECT_LE(in.size(), kMaxPayloadBytes);
        EXPECT_LE(a->id, kMaxRequestId);
        EXPECT_TRUE(a->workspace >= 0 && a->workspace <= kMaxWorkspaceId) << printable(in);
        switch (a->target) {
            case Target::Window: EXPECT_NE(a->window, 0u); EXPECT_EQ(a->workspace, 0); break;
            case Target::Workspace: EXPECT_EQ(a->window, 0u); EXPECT_GE(a->workspace, 1); break;
            case Target::Remembered: EXPECT_NE(a->window, 0u); break;
            case Target::None: EXPECT_EQ(a->window, 0u); EXPECT_EQ(a->workspace, 0); break;
            case Target::Press: ADD_FAILURE() << "press is never a parsed target: " << printable(in); break;
        }
        return true;
    });
}

TEST(ParserFuzz, StagesRequest) {
    using namespace gf::stages;
    const std::vector<std::string> corpus = {
        R"({"op":"on","durationMs":250,"curve":[0.2,0,0,1],"strips":[{"monitor":"GF-REF","tiles":[{"x":12,"y":40,"w":160,"h":120},{"x":12,"y":180,"w":160,"h":120}]},{"monitor":"DP-1","hidden":true,"tiles":[{"x":-5000,"y":2160,"w":160,"h":120}]}]})",
        R"({"op":"off"})", R"({"op":"off","durationMs":100})", R"({"op":"activate","stage":7})", R"({"op":"merge","stage":4294967295})",
        R"({"op":"move","address":"0x5f3a","stage":"new"})", R"({"op":"move","address":"5f3a","stage":3})",
        R"({"op":"on","durationMs":0,"strips":[{"monitor":"A","tiles":[{"x":0,"y":0,"w":16,"h":16}]}]})"};
    fuzz("stages.parseRequest", corpus, kMaxPayloadBytes, [](const std::string& in) {
        const auto a = parseRequest(in);
        EXPECT_EQ(a.has_value(), parseRequest(in).has_value());
        if (!a)
            return false;
        EXPECT_LE(in.size(), kMaxPayloadBytes);
        EXPECT_TRUE(std::isfinite(a->durationMs) && a->durationMs >= 0 && a->durationMs <= kMaxDurationMs) << printable(in);
        EXPECT_LE(a->strips.size(), kMaxStrips);
        std::set<std::string> monitors;
        for (const Strip& s : a->strips) {
            EXPECT_TRUE(!s.monitor.empty() && s.monitor.size() <= kMaxMonitorName && nameChars(s.monitor)) << printable(in);
            EXPECT_TRUE(monitors.insert(s.monitor).second) << "monitor twice: " << printable(in);
            EXPECT_TRUE(!s.tiles.empty() && s.tiles.size() <= kMaxTiles) << printable(in);
            for (const Box& t : s.tiles) {
                EXPECT_TRUE(gf::minimize::isFinite(t));
                EXPECT_TRUE(t.w >= kMinTileSide && t.w <= kMaxTileSide && t.h >= kMinTileSide && t.h <= kMaxTileSide) << printable(in);
                EXPECT_TRUE(std::fabs(t.x) <= kMaxTileCoord && std::fabs(t.y) <= kMaxTileCoord) << printable(in);
            }
        }
        if (a->op == Op::Move) {
            EXPECT_TRUE(a->window != 0 && (a->newStage || a->stage != 0)) << printable(in);
        }
        if (a->op == Op::Activate || a->op == Op::Merge) {
            EXPECT_NE(a->stage, 0u) << printable(in);
        }
        return true;
    });
}

TEST(ParserFuzz, ArrangeRequest) {
    using namespace gf::tiling;
    const std::vector<std::string> corpus = {R"({"layout":"left-quarters","windows":["0x1a2b","3c"],"output":"GF-REF"})",
                                             R"({"layout":"thirds","windows":["0x9"],"zone":1,"with":"0x1a"})", R"({"layout":"thirds","zone":2,"windows":["0x9"]})",
                                             R"({ "layout" : "quarters", "windows" : ["1"], "fill" : false, "unknown": {"a":[1]} })"};
    fuzz("tiling.parseArrange", corpus, kMaxArrangeBytes, [](const std::string& in) {
        const auto a = parseArrange(in);
        EXPECT_EQ(a.has_value(), parseArrange(in).has_value());
        if (!a)
            return false;
        EXPECT_LE(in.size(), kMaxArrangeBytes);
        const Layout* l = layoutById(a->layout);
        EXPECT_NE(l, nullptr) << printable(in);
        EXPECT_TRUE(!a->windows.empty() && a->windows.size() <= kMaxZones) << printable(in);
        if (l) {
            EXPECT_LE(a->windows.size(), l->zones.size());
        }
        std::set<uint64_t> seen;
        for (uint64_t w : a->windows) {
            EXPECT_NE(w, 0u);
            EXPECT_TRUE(seen.insert(w).second) << "window twice: " << printable(in);
        }
        if (a->zone) {
            EXPECT_TRUE(*a->zone >= 0 && *a->zone < static_cast<int>(kMaxZones)) << printable(in);
        }
        if (a->with) {
            EXPECT_TRUE(*a->with != 0 && a->zone.has_value()) << printable(in);
        }
        EXPECT_TRUE(a->output.empty() || outputNameOk(a->output)) << printable(in);
        return true;
    }, [](std::string& s, Rng& rng) {
        // One window of the "windows" array repeated inside it: the generic operations seldom make two windows equal, so
        // the parser without its "a window is given twice" check survived 2000 iterations (killed at 8312; the
        // integrator's review of 265e6c7).
        const size_t key = s.find("\"windows\"");
        const size_t open = key == std::string::npos ? key : s.find('[', key);
        const size_t close = open == std::string::npos ? open : s.find(']', open);
        if (close == std::string::npos)
            return;
        std::vector<std::pair<size_t, size_t>> quoted; // [begin, end) of every "..." element between the brackets
        for (size_t q = s.find('"', open); q != std::string::npos && q < close;) {
            const size_t e = s.find('"', q + 1);
            if (e == std::string::npos || e > close)
                break;
            quoted.emplace_back(q, e + 1);
            q = s.find('"', e + 1);
        }
        if (quoted.empty())
            return;
        const auto [b, e] = quoted[rng.below(quoted.size())];
        s.insert(e, "," + s.substr(b, e - b));
    });
}

// ---- scalar readers: addresses, config values, names ----------------------------------------------------------------

TEST(ParserFuzz, WindowAddress) {
    const std::vector<std::string> corpus = {"0x605cc1156d90", "605cc1156d90", "0x1", "ffffffffffffffff", "0X605CC1156D90"};
    fuzz("minimize.parseAddress", corpus, 64, [](const std::string& in) {
        const auto a = gf::minimize::parseAddress(in);
        if (!a) {
            EXPECT_FALSE(hexAddressGrammar(in)) << "an address inside the grammar was refused: " << printable(in);
            return false;
        }
        EXPECT_TRUE(hexAddressGrammar(in)) << "accepted outside the grammar: " << printable(in);
        EXPECT_NE(*a, 0u);
        std::string_view digits = in;
        if (digits.size() >= 2 && digits[0] == '0' && (digits[1] == 'x' || digits[1] == 'X'))
            digits.remove_prefix(2);
        EXPECT_EQ(*a, std::strtoull(std::string(digits).c_str(), nullptr, 16));
        return true;
    });
}

TEST(ParserFuzz, ConfigValues) {
    const std::vector<std::string> corpus = {"appearance=dark", "appearance=light", "titlebarDoubleClick=zoom", "titlebarDoubleClick=fill",
                                             "minimizeEffect=funnel", "minimizeEffect=shrink", "stagesEnabled=true", "tilingEdges=false",
                                             "tilingLayouts=true", "left-third", "bottom-right", "fill", "GF-REF", "DP-1.2_a"};
    fuzz("config.keyValue", corpus, 512, [](const std::string& in) {
        const size_t     eq    = in.find('=');
        std::string_view key   = eq == std::string::npos ? std::string_view{} : std::string_view(in).substr(0, eq);
        std::string_view value = eq == std::string::npos ? std::string_view(in) : std::string_view(in).substr(eq + 1);
        bool             any   = false;
        if (const auto a = gf::gfc::parseAppearance(key, value)) {
            EXPECT_EQ(key, gf::gfc::kConfigAppearance);
            EXPECT_TRUE(value == "dark" || value == "light") << printable(in);
            any = true;
        }
        if (const auto d = gf::gfc::parseDoubleClickAction(key, value)) {
            EXPECT_EQ(key, gf::gfc::kConfigTitlebarDoubleClick);
            EXPECT_TRUE(value == "zoom" || value == "minimize" || value == "none" || value == "fill") << printable(in);
            any = true;
        }
        if (const auto e = gf::minimize::parseEffect(key, value)) {
            EXPECT_EQ(key, gf::minimize::kConfigMinimizeEffect);
            EXPECT_TRUE(value == "funnel" || value == "shrink" || value == "fade") << printable(in);
            any = true;
        }
        if (const auto s = gf::stages::parseStagesEnabled(key, value)) {
            EXPECT_EQ(key, gf::stages::kConfigStagesEnabled);
            EXPECT_TRUE(value == "true" || value == "false") << printable(in);
            any = true;
        }
        if (const auto sw = gf::tiling::switchOf(key)) {
            EXPECT_TRUE(key.starts_with("tiling")) << printable(in);
            if (const auto b = gf::tiling::parseBool(value)) {
                EXPECT_TRUE(value == "true" || value == "false") << printable(in);
                any = true;
            }
        }
        if (const auto p = gf::tiling::parsePlace(value)) {
            EXPECT_EQ(gf::tiling::nameOf(*p), value) << "a place name that does not round-trip: " << printable(in);
            any = true;
        }
        if (gf::tiling::outputNameOk(value)) {
            EXPECT_TRUE(!value.empty() && value.size() <= gf::tiling::kMaxOutputName && nameChars(value)) << printable(in);
            any = true;
        }
        EXPECT_FALSE(gf::minimize::isFunnelShaderFault(key, value, false)) << "the test fault is honoured outside a dev session: " << printable(in);
        return any;
    });
}

TEST(ParserFuzz, AppmenuAddress) {
    using namespace gf::appmenu;
    const std::vector<std::string> corpus = {":1.42|/MenuBar/1", "org.kde.Foo|/com/canonical/menu/3", "a.b|/", ":1.0|/a_b/c9"};
    fuzz("appmenu.isValidAddress", corpus, kMaxNameLength * 2 + 2, [](const std::string& in) {
        const size_t     bar     = in.find('|');
        std::string_view service = bar == std::string::npos ? std::string_view(in) : std::string_view(in).substr(0, bar);
        std::string_view path    = bar == std::string::npos ? std::string_view{} : std::string_view(in).substr(bar + 1);
        const bool       s = isValidBusName(service), p = isValidObjectPath(path), both = isValidAddress(service, path);
        EXPECT_EQ(both, s && p) << printable(in);
        if (s) {
            EXPECT_TRUE(!service.empty() && service.size() <= kMaxNameLength) << printable(in);
            EXPECT_TRUE(std::ranges::all_of(service, [](char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' || c == ':'; })) << printable(in);
            EXPECT_TRUE(service.find('.') != std::string_view::npos && service.find("..") == std::string_view::npos && service.back() != '.') << printable(in);
        }
        if (p) {
            EXPECT_TRUE(!path.empty() && path.size() <= kMaxNameLength && path[0] == '/') << printable(in);
            EXPECT_TRUE(path == "/" || (path.back() != '/' && path.find("//") == std::string_view::npos)) << printable(in);
            EXPECT_TRUE(std::ranges::all_of(path, [](char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '/'; })) << printable(in);
        }
        return both;
    });
}

// ---- the JSON reader and the two text makers --------------------------------------------------------------------------

TEST(ParserFuzz, JsonReader) {
    const std::vector<std::string> corpus = {R"({"a":[1,2.5,-3e2,true,false,null,"sé\n"],"b":{"c":{}}})", R"("plain")", "12345", "[[[[[]]]]]", R"({"k":"😀"})"};
    fuzz("json.CReader", corpus, 4096, [](const std::string& in) {
        gf::json::CReader r{in, 256, 16};
        bool              any = false;
        Rng               order(std::hash<std::string>{}(in));
        for (int step = 0; step < 48; ++step) {
            switch (order.below(8)) {
                case 0: r.skipSpace(); break;
                case 1: any = r.atEnd() || any; break;
                case 2: any = r.take(static_cast<char>("{}[],:\"x"[order.below(8)])) || any; break;
                case 3: (void)r.peek(); break;
                case 4:
                    if (const auto s = r.string()) {
                        EXPECT_LE(s->size(), 256u) << printable(in);
                        // Raw bytes above 0x7F pass through as they come (the consumers check what they keep: names,
                        // addresses, catalogue ids); a raw control character never does, and a \u escape decodes to UTF-8.
                        EXPECT_TRUE(std::ranges::none_of(*s, [](char c) { return static_cast<unsigned char>(c) < 0x20 && c != '\0' && c != '\n' && c != '\t' && c != '\r' && c != '\b' && c != '\f'; }) ||
                                    in.find("\\u00") != std::string::npos)
                            << "a raw control character came out of a JSON string: " << printable(in);
                        any = true;
                    }
                    break;
                case 5:
                    if (const auto n = r.number()) {
                        EXPECT_TRUE(std::isfinite(*n)) << printable(in);
                        any = true;
                    }
                    break;
                case 6: any = r.boolean().has_value() || any; break;
                default: any = r.skipValue() || any; break;
            }
        }
        return any;
    });
}

TEST(ParserFuzz, JsonEscapeRoundTrip) {
    const std::vector<std::string> corpus = {"plain", "quote\"back\\slash", "ctrl\x01\x1f\ttab\nnl", "é😀 /", std::string("nul\0inside", 10)};
    fuzz("gfc.jsonEscape", corpus, 2048, [](const std::string& in) {
        const std::string escaped = gf::gfc::jsonEscape(in);
        bool              backslash = false;
        for (unsigned char c : escaped) {
            EXPECT_GE(c, 0x20) << "a raw control character survived escaping: " << printable(in);
            if (c == '"') {
                EXPECT_TRUE(backslash) << "an unescaped quote: " << printable(in);
            }
            backslash = c == '\\' && !backslash;
        }
        const std::string quoted = "\"" + escaped + "\""; // named: CReader keeps a view of its text
        gf::json::CReader r{quoted, in.size() + 1, 1};
        const auto        back = r.string();
        EXPECT_TRUE(back.has_value()) << "escaped text is not a JSON string: " << printable(in);
        if (back) {
            EXPECT_EQ(*back, in) << "round trip changed the text: " << printable(in);
        }
        return true;
    });
}

TEST(ParserFuzz, SanitizedText) {
    const std::vector<std::string> corpus = {"org.gnome.Nautilus", "é😀", "a\xff\xfe\x62", std::string(300, 'x'), "\xED\xA0\x80surrogate"};
    fuzz("stages.sanitizedText", corpus, 1024, [](const std::string& in) {
        for (size_t cap : {size_t{0}, size_t{1}, size_t{3}, size_t{17}, gf::stages::kMaxAppBytes}) {
            const std::string out = gf::stages::sanitizedText(in, cap);
            EXPECT_LE(out.size(), cap) << printable(in);
            EXPECT_TRUE(validUtf8(out)) << "sanitised text is not UTF-8 (cap " << cap << "): " << printable(in);
            if (validUtf8(in) && in.size() <= cap) {
                EXPECT_EQ(out, in) << "valid text under the cap was changed: " << printable(in);
            }
        }
        return true;
    });
}

TEST(ParserFuzz, LuaDispatchRequest) {
    const std::vector<std::string> corpus = {"hello", "minimize", "overview", "group_front"};
    fuzz("gfc.luaDispatchRequest", corpus, 256, [](const std::string& in) {
        const std::string out = gf::gfc::luaDispatchRequest(in);
        EXPECT_NE(out.find(gf::gfc::kLuaNamespace), std::string::npos) << printable(in);
        return true;
    });
}

// ---- names: a layer namespace, a Split View side, an xdg interface name --------------------------------------------

TEST(ParserFuzz, LayerNamespace) {
    using gf::desktopfocus::SurfaceKind;
    const std::vector<std::string> corpus = {"grassfield-desktop-icons", "grassfield-menubar", "grassfield-overlay", "grassfield-x"};
    fuzz("layer.namespace", corpus, 256, [](const std::string& in) {
        const bool ours = gf::layerpointer::isGrassfieldNamespace(in);
        EXPECT_EQ(ours, gf::layerpointer::isGrassfieldNamespace(in));
        EXPECT_EQ(ours, in.size() > gf::layerpointer::kNamespacePrefix.size() && in.starts_with(gf::layerpointer::kNamespacePrefix)) << printable(in);
        for (const bool popup : {false, true}) {
            const SurfaceKind kind = gf::desktopfocus::classifyLayer(in, popup);
            EXPECT_EQ(kind, gf::desktopfocus::classifyLayer(in, popup));
            if (in == gf::desktopfocus::kDesktopNamespace) {
                EXPECT_EQ(kind, popup ? SurfaceKind::DesktopPopup : SurfaceKind::Desktop);
            } else if (in.starts_with(gf::desktopfocus::kShellNamespacePrefix)) {
                EXPECT_EQ(kind, SurfaceKind::ShellLayer) << printable(in);
            } else {
                EXPECT_EQ(kind, SurfaceKind::OtherLayer) << printable(in);
            }
            // A layer the pointer refresh follows is never another client's for the focus policy.
            if (ours) {
                EXPECT_NE(kind, SurfaceKind::OtherLayer) << printable(in);
            }
        }
        return ours;
    });
}

TEST(ParserFuzz, SplitSide) {
    const std::vector<std::string> corpus = {"left", "right"};
    fuzz("tiling.splitZone", corpus, 64, [](const std::string& in) {
        const std::optional<int> zone = gf::tiling::splitZone(in);
        EXPECT_EQ(zone, gf::tiling::splitZone(in));
        if (in == "left") {
            EXPECT_EQ(zone, 0);
        } else if (in == "right") {
            EXPECT_EQ(zone, 1);
        } else {
            EXPECT_FALSE(zone.has_value()) << printable(in);
        }
        return zone.has_value();
    });
}

TEST(ParserFuzz, CapabilityCandidate) {
    const std::vector<std::string> corpus = {"xdg_toplevel"};
    fuzz("chrome.capabilityCandidate", corpus, 128, [](const std::string& in) {
        bool any = false;
        for (const int version : {std::numeric_limits<int>::min(), -1, 0, 4, 5, 6, std::numeric_limits<int>::max()}) {
            for (const bool data : {false, true}) {
                const bool candidate = gf::chrome::capabilityCandidate(in, version, data);
                EXPECT_EQ(candidate, in == "xdg_toplevel" && version >= static_cast<int>(gf::chrome::kWmCapabilitiesSince) && data)
                    << printable(in) << " v" << version << (data ? " with" : " without") << " user data";
                any = any || candidate;
            }
        }
        return any;
    });
}
