#pragma once

// Overview v2 ("Mission Control" with live windows, master-prompt §5.6 feature 4): request parsing, validation and
// animation math. Plain C++ with no Hyprland includes, so it is unit-testable (compositor/tests/OverviewTest.cpp).
// The Hyprland glue (Overview.cpp) draws each real window, live, at the box computed here (spec: docs/specs/overview.md
// "v2"; mechanism: docs/specs/overview.md "v2 spike").
//
// Coordinates are layout coordinates (Hyprland's global logical space, what `hyprctl clients` reports as at/size).

#include "Minimize.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <expected>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace gf::overview {

    using Box = gf::minimize::Box;

    // Limits of hl.plugin.grassfield.overview(json) (untrusted input).
    inline constexpr size_t kMaxPayloadBytes = 16384; // a 64-window layout is ~6 KiB
    inline constexpr size_t kMaxWindows      = 64;
    inline constexpr size_t kMaxStringBytes  = 256;  // keys and addresses are short
    inline constexpr int    kMaxDepth        = 16;   // nesting of skipped unknown values
    inline constexpr double kMaxDurationMs   = 2000; // 0 = no animation (Reduce Motion)
    inline constexpr double kMinCurveY       = -1.0; // control points of the timing curve: x in [0, 1], y in this range
    inline constexpr double kMaxCurveY       = 2.0;

    // The timing curve (CSS cubic-bezier control points). Default: the shell's Tokens.motionCurveStandard.
    struct Curve {
        double x1 = 0.2;
        double y1 = 0.0;
        double x2 = 0.0;
        double y2 = 1.0;

        bool   operator==(const Curve&) const = default;
    };

    struct WindowTarget {
        uint64_t address = 0; // Hyprland window address (compared with the live windows, never dereferenced)
        Box      rect;        // where the window's surface box (hyprctl at/size) is drawn when the overview is open

        bool     operator==(const WindowTarget&) const = default;
    };

    struct Request {
        bool                      on         = false;
        double                    durationMs = 0;
        Curve                     curve;
        std::vector<WindowTarget> windows;
    };

    // Parses and validates {"on":bool,"durationMs":int,"windows":[{"address":"0x…","x":…,"y":…,"w":…,"h":…}…],
    // "curve":[x1,y1,x2,y2]}. Strict: a JSON object of at most kMaxPayloadBytes; `on` (bool) and `durationMs` (integer,
    // 0..kMaxDurationMs) are required, `windows` is required when `on` is true (at most kMaxWindows objects, each with
    // a valid address string and four finite numbers, w and h >= 1, no address twice), `curve` is optional (4 finite
    // numbers, x in [0, 1], y in [kMinCurveY, kMaxCurveY]). Unknown keys are skipped (additive gfc/1 fields), a key
    // given twice is an error. Whether a window exists, may be transformed and fits its monitor is checked by the glue.
    std::expected<Request, std::string> parseRequest(std::string_view json);

    // Rect fully inside the monitor box (kLayoutTolerance px tolerance, as for the Dock tile of minimize).
    bool insideMonitor(const Box& rect, const Box& monitor);

    // Linear progress in [0, 1] after elapsedMs of an animation of durationMs (0 or less: done at once).
    double progress(double elapsedMs, double durationMs);

    // Eased progress for linear progress t.
    double eased(const Curve& curve, double t);

    // The box a window's surface (current box `surface`) is drawn at for the layout rect `rect`: uniform scale (never
    // distorted), centered in rect.
    Box drawBox(const Box& surface, const Box& rect);

    // Interpolates between `from` and `to` (nullopt: the window's live surface box `live`) for eased progress e.
    Box interpolate(const std::optional<Box>& from, const std::optional<Box>& to, const Box& live, double e);

    enum class Phase : uint8_t {
        Closed,  // nothing transformed
        Opening, // windows animate from their place to the layout
        Open,    // windows drawn at the layout
        Closing, // windows animate back to their place
    };

    // "opening", "open", "closing", "closed".
    std::string_view phaseName(Phase phase);

    // Why an overview ended or was refused (closed event field `reason`); None for a normal close.
    enum class Reason : uint8_t {
        None,
        Invalid,     // the request failed validation
        NoWindows,   // windows were listed but none of them can be transformed
        Unavailable, // the plugin is unloading
        Interrupted, // a window got focus, the keyboard left the shell's chrome, the chrome went away, the workspace or a monitor changed
        NoChrome,    // refused: the shell's chrome surface is not mapped on a target monitor, not Exclusive, or does not hold the keyboard
        Fullscreen,  // a window went full screen while shown: the windows of its workspace left the overview (state unchanged)
    };

    std::string_view reasonName(Reason reason);

    // Why Hyprland focused a window while an overview is shown (the glue maps Hyprland's focus reasons).
    enum class FocusCause : uint8_t {
        UserOrOther,  // a click, a key binding, a dispatch, anything not listed below
        WindowClosed, // the focused window closed or unmapped and Hyprland picked the next one
        WindowOpened, // a new window took focus when it mapped
    };

    // A window getting focus ends the overview (macOS: the chosen window becomes key and Mission Control zooms back),
    // except when Hyprland only moved focus because a window closed or opened: the overview then stays and the shell
    // retargets (spec: "on:true again while open (a window opened or closed …) retargets").
    bool focusEndsOverview(FocusCause cause);

    // The shell's chrome surface (layer namespace grassfield-overview) as the glue sees it on one monitor.
    struct ChromeSurface {
        uint64_t monitor   = 0; // opaque monitor id
        bool     mapped    = false;
        bool     exclusive = false; // keyboard interactivity Exclusive
        bool     keyboard  = false; // the seat keyboard is on it (the surface, a subsurface or one of its popups)
    };

    // An on:true request may transform windows only while the shell covers them: every target monitor has a mapped
    // chrome surface (any keyboard interactivity: its whole-surface input takes the pointer), and the keyboard is held by a
    // mapped chrome surface with Exclusive interactivity (the focused output's). Otherwise input could reach a window drawn
    // elsewhere (R13 review of f12f610). Only one chrome needs to be Exclusive (shell integration review, main 23caeab:
    // with every output's chrome Exclusive, Hyprland's refocusLastWindow is refused while another Exclusive chrome remains,
    // and the keyboard was lost after the close on two outputs).
    bool chromeCovers(const std::vector<uint64_t>& targetMonitors, const std::vector<ChromeSurface>& chromes);

    // Boxes to damage when a window's drawn box goes from `previous` (the last damaged box; empty at first) to `current`:
    // `previous` when it differs and has an area, then `current` when it has an area. The caller then stores `current` as
    // the last damaged box, so a box drawn once is always damaged again when the window leaves it (a resized surface leaves
    // no stale pixels, and the box detached at close is the one drawn last).
    // At most two boxes, no allocation: the overview and Stages call it per window per frame.
    struct DamageBoxes {
        std::array<Box, 2> boxes{};
        size_t             count = 0;

        const Box*         begin() const {
            return boxes.data();
        }
        const Box* end() const {
            return boxes.data() + count;
        }
        size_t size() const {
            return count;
        }
        bool empty() const {
            return count == 0;
        }
        const Box& operator[](size_t i) const {
            return boxes.at(i);
        }
    };
    DamageBoxes damageStep(const Box& previous, const Box& current);

    // Whether a frame that already has damage must repaint a window drawn elsewhere (WM-01, WM-02): only when its drawn box
    // changed (`previous` -> `current`, an animation step or a resized surface) or its content did (`contentDamaged`: the
    // frame's damage touches its real place, where Hyprland damages a commit, a decoration change or a move). A blinking
    // cursor elsewhere on the screen no longer repaints every thumbnail.
    bool needsRepaint(const Box& previous, const Box& current, bool contentDamaged);

    // {"v":"gfc/1","type":"overview","state":"<phase>","windows":N} (N = windows transformed in that state), plus
    // "reason":"<reason>" when a request was refused (the state is then the unchanged current one) or the overview was
    // interrupted or ended by an unload.
    std::string eventJson(Phase phase, size_t windows, Reason reason = Reason::None);

} // namespace gf::overview
