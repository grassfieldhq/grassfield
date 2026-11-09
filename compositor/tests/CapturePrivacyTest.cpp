// SEC-01 (core/CapturePrivacy.hpp): a window hidden from captures (Hyprland's no_screen_share, privacy.lua) shows none of
// its pixels in a capture, the plugin's drawings included. Hyprland 0.56.2 blacks out such a window's own box at its real
// place, rounded; the plugin draws none of the window's pixels, and not its title, outside that box while a capture of the
// display is in progress, and redraws the display whole when that changes. Test names state the rule. The scenario of the
// leak found on 2026-11-09 (lock_privacy.sh screenshare: 98 green px in the Bitwarden fixture's top corners, plugin loaded,
// 4 runs of 4) is FrameByFrame below; the nested checks are tests/security/lock_privacy.sh (the corners) and
// tests/compositor/capture_privacy.sh (the overview, Stages and minimize drawings, the title).

#include "core/CapturePrivacy.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstddef>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <map>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
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

// Review of e21c2071, MAJOR-1: the end of a share redraws only a display whose capture was in progress at its last frame
// and is over now. Not a display that was not capturing (a window share's events, twice a second while a live thumbnail
// waits for its next frame, redrew every display and so made that frame), and not one with a frame still pending (a
// display share of a still screen: the redraw would make the frame, and the next request the next redraw).
TEST(CapturePrivacy, OnlyADisplayWhoseCaptureEndedIsRedrawnAtTheEndOfAShare) {
    EXPECT_TRUE(gf::privacy::ended(DisplayCapture{.known = true, .capturing = true}, false));
    EXPECT_FALSE(gf::privacy::ended(DisplayCapture{.known = true, .capturing = true}, true)) << "a frame is still pending";
    EXPECT_FALSE(gf::privacy::ended(DisplayCapture{.known = true, .capturing = false}, false)) << "it was not captured (a window share)";
    EXPECT_FALSE(gf::privacy::ended(DisplayCapture{.known = true, .capturing = false}, true)) << "a start is render.pre's";
    EXPECT_FALSE(gf::privacy::ended(DisplayCapture{}, false)) << "a display not drawn yet";
}

// MINOR-3: a request that dies before its first copy ends with no word from Hyprland. The check finds the end at its next
// run while the capture was in progress; it runs at most once a second.
TEST(CapturePrivacy, ACaptureThatDiesBeforeItsFirstCopyEndsAtTheNextCheck) {
    DisplayCapture d;
    EXPECT_TRUE(gf::privacy::redrawWhole(d, true)) << "the frame is pending: drawn under the capture";
    // The client went away; no frame is pending, no session is sharing, Hyprland said nothing.
    EXPECT_TRUE(gf::privacy::ended(d, gf::privacy::capturing(CaptureCounts{})));
    EXPECT_LE(gf::privacy::kEndCheck.count(), 1000);
    EXPECT_GT(gf::privacy::kEndCheck.count(), 0);
}

// The leak of 2026-11-09 frame by frame: the Bitwarden fixture's titlebar join (its content's top corners), one grim capture.
// Hyprland's counts per frame as 0.56.2 keeps them (ScreenshareFrame.cpp share(), copy(); ScreenshareSession.cpp the 500 ms
// timer). The session grim leaves behind is not among them: it stays "active" for good, and must not hide anything.
TEST(CapturePrivacy, FrameByFrame) {
    struct Frame {
        const char*   what;
        CaptureCounts counts;
        bool          redraw;  // drawn whole
        bool          content; // the corners show the content's own pixels, the bar its title
        bool          ended;   // the end of the share redraws the display
    };
    const std::array<Frame, 5> frames{{
        {"before the capture", {.sharingSessions = 0, .pendingFrames = 0}, false, true, false},
        {"grim asked for a frame: the one it copies", {.sharingSessions = 0, .pendingFrames = 1}, true, false, false},
        {"copied, within 500 ms", {.sharingSessions = 1, .pendingFrames = 0}, false, false, false},
        {"500 ms later: Hyprland stops counting the session", {.sharingSessions = 0, .pendingFrames = 0}, true, true, true},
        {"after, grim's session left behind", {.sharingSessions = 0, .pendingFrames = 0}, false, true, false},
    }};
    DisplayCapture display;
    for (const auto& f : frames) {
        const bool capturing = gf::privacy::capturing(f.counts);
        EXPECT_EQ(gf::privacy::ended(display, capturing), f.ended) << f.what;
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

// Review NIT-2: the plate covers the window's subsurfaces too, mapped as the miniature maps the surface.
TEST(CapturePrivacy, AMiniaturesPlateCoversItsSubsurfaces) {
    const Box surface{.x = 100, .y = 200, .w = 800, .h = 600};
    const Box fitted{.x = 1000, .y = 50, .w = 400, .h = 300}; // half size
    EXPECT_EQ(gf::privacy::miniatureCover(surface, fitted, {}), fitted) << "no subsurface: the surface's place";
    EXPECT_EQ(gf::privacy::miniatureCover(surface, fitted, {Box{.x = 150, .y = 250, .w = 100, .h = 100}}), fitted) << "one inside changes nothing";
    // One poking out 40 px to the right and 20 px below, at the real place: 20 and 10 more on the miniature.
    EXPECT_EQ(gf::privacy::miniatureCover(surface, fitted, {Box{.x = 840, .y = 720, .w = 100, .h = 100}}), (Box{.x = 1000, .y = 50, .w = 420, .h = 310}));
    // One above and left of the surface (a negative subsurface position).
    EXPECT_EQ(gf::privacy::miniatureCover(surface, fitted, {Box{.x = 60, .y = 180, .w = 50, .h = 50}}), (Box{.x = 980, .y = 40, .w = 420, .h = 310}));
    constexpr double nan = std::numeric_limits<double>::quiet_NaN();
    EXPECT_EQ(gf::privacy::miniatureCover(surface, fitted, {Box{.x = nan, .y = 0, .w = 10, .h = 10}, Box{.x = 0, .y = 0, .w = 0, .h = 10}}), fitted)
        << "empty or non-finite parts are ignored";
}

// ---- The plugin's sources: every function that draws a window's own pixels, or its title, asks first ----
//
// Review of e21c2071, MINOR-1: a file-wide text search let a second draw site, or a guard moved out of the drawing function,
// pass. Here every use of a window's pixels (a surface's current state, its texture or its buffer, a framebuffer's texture:
// a snapshot, a transformer's input; a window or surface rendered by the plugin itself; the whole display's mirror texture;
// review of a913cc59, nit-a) and of the title's rendering is found in the plugin's sources with comments and literals blanked,
// attributed to the function whose body holds it, and the functions and their counts are pinned: a new use fails until
// it is added here, with or without the guard. A function that draws must call gf::capturePrivacy::mayDrawContent in its
// own body. What a source scan cannot see (a guard whose result is ignored) is for the nested checks.

namespace {
    // Comments, string and character literals (raw strings included) blanked with spaces; newlines kept.
    std::string codeOnly(const std::string& src) {
        std::string out = src;
        size_t      i   = 0;
        const auto  blank = [&out](size_t from, size_t to) {
            for (size_t k = from; k < to && k < out.size(); ++k) {
                if (out[k] != '\n')
                    out[k] = ' ';
            }
        };
        while (i < src.size()) {
            if (src.compare(i, 2, "//") == 0) {
                const size_t end = src.find('\n', i);
                const size_t to  = end == std::string::npos ? src.size() : end;
                blank(i, to);
                i = to;
            } else if (src.compare(i, 2, "/*") == 0) {
                const size_t end = src.find("*/", i + 2);
                const size_t to  = end == std::string::npos ? src.size() : end + 2;
                blank(i, to);
                i = to;
            } else if (src[i] == 'R' && i + 1 < src.size() && src[i + 1] == '"' && (i == 0 || (std::isalnum(static_cast<unsigned char>(src[i - 1])) == 0 && src[i - 1] != '_'))) {
                const size_t open = src.find('(', i + 2);
                if (open == std::string::npos)
                    break;
                const std::string delim = ")" + src.substr(i + 2, open - (i + 2)) + "\"";
                const size_t      end   = src.find(delim, open + 1);
                const size_t      to    = end == std::string::npos ? src.size() : end + delim.size();
                blank(i, to);
                i = to;
            } else if (src[i] == '"' || (src[i] == '\'' && (i == 0 || std::isxdigit(static_cast<unsigned char>(src[i - 1])) == 0))) {
                const char quote = src[i];
                size_t     k     = i + 1;
                while (k < src.size() && src[k] != quote) {
                    if (src[k] == '\\')
                        ++k;
                    ++k;
                }
                blank(i, k + 1);
                i = k + 1;
            } else {
                ++i;
            }
        }
        return out;
    }

    bool identChar(char c) {
        return std::isalnum(static_cast<unsigned char>(c)) != 0 || c == '_' || c == ':' || c == '~';
    }

    size_t skipSpaceBack(const std::string& code, size_t pos) { // the index of the last non-space char before pos, npos if none
        while (pos > 0) {
            --pos;
            if (std::isspace(static_cast<unsigned char>(code[pos])) == 0)
                return pos;
        }
        return std::string::npos;
    }

    // The bracket that opens the one closing at `close` (')' or '}').
    size_t matchingOpen(const std::string& code, size_t close) {
        const char closing = code[close];
        const char opening = closing == ')' ? '(' : '{';
        int        depth   = 0;
        for (size_t k = close + 1; k-- > 0;) {
            if (code[k] == closing)
                ++depth;
            else if (code[k] == opening && --depth == 0)
                return k;
        }
        return std::string::npos;
    }

    // The name of the function whose body the brace at `open` begins, or "" when it begins anything else (a namespace, a
    // class, a control statement, a lambda, an initializer).
    std::string functionAt(const std::string& code, size_t open) {
        size_t p = skipSpaceBack(code, open);
        // Qualifiers between the parameter list and the body.
        for (bool more = true; more && p != std::string::npos;) {
            more = false;
            for (const std::string_view q : {"const", "noexcept", "override", "final", "mutable"}) {
                if (p + 1 >= q.size() && code.compare(p + 1 - q.size(), q.size(), q) == 0 && (p + 1 == q.size() || !identChar(code[p - q.size()]))) {
                    p    = skipSpaceBack(code, p + 1 - q.size());
                    more = true;
                    break;
                }
            }
        }
        // A constructor's initializers: `) : a(x), b{y} {` — walk back over each to the parameter list.
        while (p != std::string::npos && (code[p] == ')' || code[p] == '}')) {
            const bool   parens = code[p] == ')';
            const size_t lp     = matchingOpen(code, p);
            if (lp == std::string::npos)
                return "";
            const size_t nameEnd = skipSpaceBack(code, lp);
            if (nameEnd == std::string::npos)
                return "";
            if (code[nameEnd] == ']')
                return ""; // a lambda
            size_t nameBegin = nameEnd + 1;
            while (nameBegin > 0 && identChar(code[nameBegin - 1]))
                --nameBegin;
            std::string name = code.substr(nameBegin, nameEnd + 1 - nameBegin);
            if (name.empty())
                return "";
            const size_t before = skipSpaceBack(code, nameBegin);
            if (before != std::string::npos && (code[before] == ',' || (code[before] == ':' && (before == 0 || code[before - 1] != ':')))) {
                p = skipSpaceBack(code, before); // an initializer: the parameter list is further back
                continue;
            }
            if (!parens)
                return ""; // `x{...} {`: not a function
            for (const std::string_view keyword : {"if", "for", "while", "switch", "catch", "return", "sizeof", "decltype"}) {
                if (name == keyword)
                    return "";
            }
            if (const size_t colons = name.rfind("::"); colons != std::string::npos)
                name = name.substr(colons + 2);
            return name;
        }
        return "";
    }

    struct Body {
        std::string name;
        size_t      open  = 0;
        size_t      close = 0;
    };

    std::vector<Body> functionBodies(const std::string& code) {
        std::vector<Body>                           bodies;
        std::vector<std::pair<size_t, std::string>> stack; // open brace, function name ("" for other blocks)
        for (size_t i = 0; i < code.size(); ++i) {
            if (code[i] == '{') {
                stack.emplace_back(i, functionAt(code, i));
            } else if (code[i] == '}' && !stack.empty()) {
                if (!stack.back().second.empty())
                    bodies.push_back(Body{.name = stack.back().second, .open = stack.back().first, .close = i});
                stack.pop_back();
            }
        }
        return bodies;
    }

    // The innermost function body holding `pos`; nullptr outside every function.
    const Body* bodyOf(const std::vector<Body>& bodies, size_t pos) {
        const Body* best = nullptr;
        for (const auto& b : bodies) {
            if (b.open < pos && pos < b.close && (!best || b.open > best->open))
                best = &b;
        }
        return best;
    }

    const std::regex& pixelUse() {
        // A surface's current state taken whole, its texture or its buffer; a framebuffer's texture; a window rendered by
        // Hyprland's renderer on the plugin's behalf, or a surface pass element; the display's mirror texture (the frame a
        // display capture copies); the title's rendering. None of the last four occurs in the plugin today.
        static const std::regex re{R"(getTexture\s*\(|m_current\s*;|m_current\s*\.\s*(texture|buffer)\b|renderText\s*\(|renderWindow\s*\(|CSurfacePassElement|getMirrorTexture\s*\()"};
        return re;
    }

    struct Site {
        int  uses  = 0;
        bool draws = true; // false: the use only checks a snapshot exists
    };

    // Every function of the plugin that uses a window's pixels or renders its title, and how often. Add a new one here
    // only with the guard in its body (or, for a use that draws nothing, with draws = false and the reason).
    const std::map<std::string, Site>& pinned() {
        static const std::map<std::string, Site> sites{
            {"Minimize.cpp draw", {.uses = 1, .draws = true}},               // the minimize / restore animation's snapshot
            {"Minimize.cpp takeSnapshot", {.uses = 1, .draws = false}},      // only checks the snapshot has a texture
            {"Titlebar.cpp drawBar", {.uses = 1, .draws = true}},            // the window's title
            {"Titlebar.cpp drawContentCorners", {.uses = 1, .draws = true}}, // the content's own top corners
            {"WindowTransform.cpp drawFitted", {.uses = 1, .draws = true}},  // the overview and Stages miniatures
        };
        return sites;
    }
} // namespace

TEST(CapturePrivacy, TheSourceScanFindsFunctionsAndSkipsCommentsLiteralsAndLambdas) {
    const std::string src = R"cpp(
namespace gf {
    // getTexture() in a comment
    void draw() {
        const auto s = "getTexture() in a string";
        auto f = [](int a) { return a; };
        if (ok(1)) { use(tex->getTexture()); }
    }
    Foo::Foo(int x) : m_x(x), m_y{2} { auto t = fb->getTexture(); }
    int other(int a) const noexcept { return a; }
}
)cpp";
    const std::string code   = codeOnly(src);
    const auto        bodies = functionBodies(code);
    std::vector<std::string> owners;
    for (auto it = std::sregex_iterator(code.begin(), code.end(), pixelUse()); it != std::sregex_iterator(); ++it) {
        const Body* b = bodyOf(bodies, static_cast<size_t>(it->position()));
        owners.push_back(b ? b->name : "<none>");
    }
    EXPECT_EQ(owners, (std::vector<std::string>{"draw", "Foo"})) << "the comment and the string are not uses; the lambda and the if are not functions";
}

namespace {
    using Sources = std::vector<std::pair<std::string, std::string>>; // file name, source text

    struct Scan {
        std::map<std::string, int> uses;      // "<file> <function>" -> uses of a window's pixels or title in its body
        std::vector<std::string>   unguarded; // such functions that draw without asking in their own body
        std::vector<std::string>   outside;   // uses outside every function
    };

    Scan scan(const Sources& sources) {
        Scan result;
        for (const auto& [file, text] : sources) {
            const std::string code   = codeOnly(text);
            const auto        bodies = functionBodies(code);
            for (auto it = std::sregex_iterator(code.begin(), code.end(), pixelUse()); it != std::sregex_iterator(); ++it) {
                const Body* b = bodyOf(bodies, static_cast<size_t>(it->position()));
                if (!b) {
                    result.outside.push_back(file + " at " + std::to_string(it->position()));
                    continue;
                }
                const std::string key = file + " " + b->name;
                ++result.uses[key];
                const std::string_view body{code.data() + b->open, b->close - b->open};
                const bool             guarded = body.find("capturePrivacy::mayDrawContent(") != std::string_view::npos;
                const auto             pin     = pinned().find(key);
                if (!guarded && (pin == pinned().end() || pin->second.draws))
                    result.unguarded.push_back(key);
            }
        }
        return result;
    }

    std::map<std::string, int> pinnedUses() {
        std::map<std::string, int> uses;
        for (const auto& [key, site] : pinned())
            uses[key] = site.uses;
        return uses;
    }

    Sources pluginSources() {
        Sources                     sources;
        const std::filesystem::path dir{GF_PLUGIN_SOURCE_DIR};
        if (!std::filesystem::is_directory(dir))
            return sources;
        for (const auto& entry : std::filesystem::recursive_directory_iterator(dir)) {
            if (entry.path().extension() == ".cpp")
                sources.emplace_back(entry.path().filename().string(), slurp(entry.path()));
        }
        return sources;
    }
} // namespace

TEST(CapturePrivacy, EveryPluginFunctionThatDrawsAWindowsPixelsOrTitleAsksFirst) {
    const auto sources = pluginSources();
    ASSERT_FALSE(sources.empty()) << GF_PLUGIN_SOURCE_DIR;
    const auto result = scan(sources);
    EXPECT_TRUE(result.outside.empty()) << ::testing::PrintToString(result.outside);
    EXPECT_TRUE(result.unguarded.empty()) << "draws a window's pixels or title without gf::capturePrivacy::mayDrawContent() in its own body: "
                                          << ::testing::PrintToString(result.unguarded);
    EXPECT_EQ(result.uses, pinnedUses()) << "a use of a window's pixels was added, moved or removed: review it for SEC-01, then update pinned()";
}

// Review of a913cc59, nit-a: every way the scan knows to draw a window's pixels, added to the real sources in a new
// function, is caught: unguarded, it is named; guarded, it still changes the pinned uses until it is reviewed.
TEST(CapturePrivacy, ANewDrawSiteOfAnyKindIsCaught) {
    const auto sources = pluginSources();
    ASSERT_FALSE(sources.empty()) << GF_PLUGIN_SOURCE_DIR;
    const std::array<std::string_view, 8> sites{
        "auto tex = fb->getTexture();",
        "const auto& state = surface->m_current;",
        "auto tex = surface->m_current.texture;",
        "auto buffer = surface->m_current.buffer;",
        "auto title = g_pHyprRenderer->renderText(w->m_title, colour, 12, false, font, 100, 400);",
        "g_pHyprRenderer->renderWindow(w, mon, now, true, Render::RENDER_PASS_MAIN);",
        "g_pHyprRenderer->draw(CSurfacePassElement::SRenderData{});",
        "auto frame = mon->resources()->getMirrorTexture();",
    };
    // The other files are scanned once; each mutant rescans only the file it changes (std::regex is slow on the big ones).
    const auto target = std::ranges::find_if(sources, [](const auto& s) { return s.first == "WindowTransform.cpp"; });
    ASSERT_NE(target, sources.end());
    Sources others;
    std::ranges::copy_if(sources, std::back_inserter(others), [](const auto& s) { return s.first != "WindowTransform.cpp"; });
    const Scan base = scan(others);
    for (const auto site : sites) {
        for (const bool guard : {false, true}) {
            std::string text = target->second + "\nnamespace gf::transform {\n    void sec01Mutant(const PHLWINDOW& w, const PHLMONITOR& mon) {\n";
            if (guard)
                text += "        if (!gf::capturePrivacy::mayDrawContent(w, mon))\n            return;\n";
            text += "        " + std::string{site} + "\n    }\n}\n";
            Scan       result = base;
            const Scan mutant = scan(Sources{{"WindowTransform.cpp", text}});
            for (const auto& [key, n] : mutant.uses)
                result.uses[key] += n;
            result.unguarded.insert(result.unguarded.end(), mutant.unguarded.begin(), mutant.unguarded.end());
            result.outside.insert(result.outside.end(), mutant.outside.begin(), mutant.outside.end());
            const bool named  = std::ranges::find(result.unguarded, "WindowTransform.cpp sec01Mutant") != result.unguarded.end();
            EXPECT_EQ(named, !guard) << site << (guard ? " (guarded)" : " (unguarded)");
            EXPECT_EQ(result.uses.count("WindowTransform.cpp sec01Mutant"), 1U) << site;
            EXPECT_NE(result.uses, pinnedUses()) << site << ": a new site, guarded or not, is not in pinned()";
        }
    }
}

// Review of a913cc59, S8: the end of a share asks for the end check only for a display or region share.
TEST(CapturePrivacy, OnlyTheEndOfADisplayShareAsksForTheEndCheck) {
    EXPECT_TRUE(gf::privacy::endChecked(false, false)) << "a display or region share ended";
    EXPECT_FALSE(gf::privacy::endChecked(false, true)) << "a window share ended (a live thumbnail, twice a second)";
    EXPECT_FALSE(gf::privacy::endChecked(true, false)) << "a start is render.pre's";
    EXPECT_FALSE(gf::privacy::endChecked(true, true));
}

// Review of a913cc59, nit-c: start() registers once per load, whatever an earlier call left. The counters stand in for
// Hyprland's event loop (timers) and event bus (listeners).
TEST(CapturePrivacy, StartRegistersOnceEvenAfterACallThatFailedMidway) {
    bool started   = false;
    int  timers    = 0;
    int  listeners = 0;
    int  builds    = 0;
    bool failNext  = true;
    const auto undo  = [&] { timers = 0; listeners = 0; };
    const auto build = [&] {
        ++builds;
        ++timers; // addTimer
        if (std::exchange(failNext, false))
            throw std::runtime_error("listen failed after addTimer");
        listeners += 2;
        return true;
    };
    EXPECT_THROW(gf::privacy::startOnce(started, undo, build), std::runtime_error);
    EXPECT_FALSE(started);
    EXPECT_EQ(timers, 1) << "the failed call left its timer";
    EXPECT_TRUE(gf::privacy::startOnce(started, undo, build));
    EXPECT_EQ(timers, 1) << "the second call removed the first timer before adding its own";
    EXPECT_EQ(listeners, 2);
    EXPECT_TRUE(gf::privacy::startOnce(started, undo, build));
    EXPECT_EQ(builds, 2) << "a call after a success registers nothing";
    EXPECT_EQ(timers, 1);
    EXPECT_EQ(listeners, 2);

    // Without the event bus nothing is registered, and the next call tries again.
    bool       again   = false;
    int        tries   = 0;
    const auto missing = [&] { ++tries; return false; };
    EXPECT_FALSE(gf::privacy::startOnce(again, [] {}, missing));
    EXPECT_FALSE(gf::privacy::startOnce(again, [] {}, missing));
    EXPECT_EQ(tries, 2);
}
