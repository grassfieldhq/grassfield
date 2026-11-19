#pragma once

// Minimize / restore animation logic (master-prompt §5.6 feature 2, ADR-0002). Plain C++ with no Hyprland
// includes, so it is unit-testable (compositor/tests/). The Hyprland glue (Minimize.cpp) validates the
// shell's arguments with it and draws a window snapshot at the boxes it computes.
//
// Coordinates: "layout" = Hyprland's global logical coordinates (what hyprctl reports as `at`/`size`, and
// what the shell sends as the Dock tile rectangle); "pixels" = a monitor's framebuffer coordinates.

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>

namespace gf::minimize {

    struct Box {
        double x = 0;
        double y = 0;
        double w = 0;
        double h = 0;

        bool   operator==(const Box&) const = default;
    };

    // Hyprland window address as the shell sends it: optional "0x", then 1 to 16 hex digits, nothing else.
    std::optional<uint64_t> parseAddress(std::string_view text);

    // All four numbers are finite.
    bool isFinite(const Box& b);

    // A usable animation target (the Dock tile): finite, 1..kMaxTargetSide layout pixels per side and fully
    // inside one monitor box (layout coordinates, kLayoutTolerance px tolerance). Anything else means "no
    // target": the window is minimized or restored without animation.
    inline constexpr double kMaxTargetSide   = 1024.0;
    inline constexpr double kLayoutTolerance = 1.0;
    bool                    isValidTarget(const Box& target, std::span<const Box> monitors);

    // The largest box with source's aspect ratio that fits in target, centered in it (the window shrinks
    // uniformly into the tile; it is never distorted). A degenerate source returns target.
    Box fitInside(const Box& source, const Box& target);

    // Component-wise linear interpolation, t in [0, 1].
    Box lerp(const Box& a, const Box& b, double t);

    // CSS-style cubic Bézier easing through (0,0), (x1,y1), (x2,y2), (1,1); x1 and x2 are clamped to [0, 1]
    // so the curve is a function of time.
    class CCubicBezier {
      public:
        constexpr CCubicBezier(double x1, double y1, double x2, double y2) :
            m_x1(x1 < 0 ? 0 : (x1 > 1 ? 1 : x1)), m_y1(y1), m_x2(x2 < 0 ? 0 : (x2 > 1 ? 1 : x2)), m_y2(y2) {}

        // Eased progress for linear time t (clamped to [0, 1]).
        double operator()(double t) const;

      private:
        double m_x1, m_y1, m_x2, m_y2;
    };

    enum class Kind : uint8_t {
        Minimize, // window box -> tile, ease-in, fades out at the end
        Restore,  // tile -> window box, ease-out, fades in at the start
    };

    // The minimize effect (Settings dock.minimizeEffect, pushed by the shell with hl.plugin.grassfield.config):
    // Genie = "funnel" (the default, core/Genie.*), Scale = "shrink" (uniform shrink into the tile, frameAt) or
    // Fade = "fade" (Reduce Motion: the window fades out where it is, fadeFrameAt; the shell sends it while
    // accessibility.reduceMotion is on).
    enum class Effect : uint8_t {
        Genie,
        Scale,
        Fade,
    };

    inline constexpr std::string_view kConfigMinimizeEffect = "minimizeEffect";

    // nullopt unless key is kConfigMinimizeEffect and value is exactly "funnel", "shrink" or "fade" (the values of Settings
    // dock.minimizeEffect, Grassfield's own names; the code keeps Genie / Scale as internal identifiers).
    std::optional<Effect> parseEffect(std::string_view key, std::string_view value);

    // Dev fault injection (tests/compositor/genie.sh fault): hl.plugin.grassfield.config("testFault", "funnel-shader") makes
    // the next funnel draw compile a broken shader. Honoured only in a dev session by the run-mode rule (core/RunMode.hpp:
    // GRASSFIELD_DEV=1 and GRASSFIELD_SESSION not "1" in Hyprland's environment; scripts/dev/nested-up.sh sets the first,
    // the installed session the second); never advertised, rejected like any unknown key otherwise.
    inline constexpr std::string_view kConfigTestFault       = "testFault";
    inline constexpr std::string_view kTestFaultFunnelShader = "funnel-shader";
    bool                              isFunnelShaderFault(std::string_view key, std::string_view value, bool devSession);

    // Shift held when a minimize or restore starts plays it in slow motion, as on macOS (any effect).
    inline constexpr double kSlowMotionFactor = 10.0;

    struct Frame {
        Box   box;           // where the window's visible box is drawn (layout coordinates)
        float alpha = 1.F;   // snapshot opacity
        bool  done  = false; // elapsed >= duration: the animation is over
    };

    // Animation timing (Grassfield values; ~300 ms like the macOS "Scale" effect).
    inline constexpr double kMinimizeDurationMs = 300.0;
    inline constexpr double kRestoreDurationMs  = 300.0;
    inline constexpr double kFadeFraction       = 0.2; // share of the duration spent fading (end / start)
    double                  durationMs(Kind kind);
    CCubicBezier            curve(Kind kind); // ease-in for Minimize, its time-reverse (ease-out) for Restore

    // State of an animation from `from` to `to` after elapsedMs (negative elapsed = start).
    Frame frameAt(Kind kind, const Box& from, const Box& to, double elapsedMs);

    // Reduce Motion: a quick fade in place, no movement (Tokens.motionReducedMax, docs/specs/ui.md).
    inline constexpr double kFadeDurationMs = 100.0;

    // State of a Fade animation of the window box `box` after elapsedMs: the box never moves; alpha goes 1 -> 0
    // (Minimize) or 0 -> 1 (Restore), linearly.
    Frame fadeFrameAt(Kind kind, const Box& box, double elapsedMs);

    // ---- An animation interrupted by the opposite one (a minimize clicked back from the Dock, WM-06) ----
    // The new animation continues from the state on screen instead of starting over: no jump, no flash, and only the part
    // of its duration that is left (macOS reverses an interrupted minimize from where it is).

    // The eased progress (0 window .. 1 its end) of a running shrink animation of `kind` after elapsedMs.
    double easedProgress(Kind kind, double elapsedMs);

    // The elapsed time (ms) at which a shrink animation of `kind` has eased progress `eased` (its timing inverted; clamped
    // to [0, 1]).
    double elapsedForEased(Kind kind, double eased);

    struct Continuation {
        Box    from;          // the box the animation runs from (frameAt's `from`): chosen so that it shows `current` at elapsedMs
        double elapsedMs = 0; // where it starts in its own timing
    };

    // A shrink animation of `kind` toward `to` taking over from the box on screen `current`, with `share` of its way already
    // behind it (1 - the interrupted animation's eased progress; at most 0.95, so `from` stays near the path): it starts at
    // elapsedForEased(kind, share), where frameAt gives `current` exactly, with the alpha its timing has there (past the
    // restore's fade-in once a fifth of its time is behind it: the window is not made transparent again).
    Continuation continueFrom(Kind kind, const Box& current, const Box& to, double share);

    // A fade of `kind` taking over at `alpha` (the interrupted fade's): the elapsed time where fadeFrameAt gives that alpha.
    double fadeElapsedFor(Kind kind, float alpha);

    // The affine map that sends `src` onto `dst` (per-axis scale + translation), applied to `inner`
    // (e.g. the window's full box with its shadow, for damage).
    Box mapBox(const Box& inner, const Box& src, const Box& dst);

    // A window snapshot: a texture of the whole source monitor (texW x texH pixels, the monitor's transformed
    // size) in which the window's visible box `visible` (layout) was rendered at its place.
    struct SSnapshotGeometry {
        Box    visible;
        double monitorX     = 0; // source monitor position (layout)
        double monitorY     = 0;
        double monitorScale = 1;
        double texW         = 0;
        double texH         = 0;
    };

    // Box (pixels of the monitor being rendered: position monX/monY, scale monScale) at which to draw the whole
    // snapshot texture so that its window region lands on `dst` (layout). Same math as Hyprland 0.56.2's
    // CWindowFadeout::renderBox, generalized to drawing on another monitor.
    Box textureBox(const SSnapshotGeometry& snapshot, const Box& dst, double monX, double monY, double monScale);

    // Boxes intersect (shared area > 0).
    bool intersects(const Box& a, const Box& b);

    // ---- Where a restored window goes (owner decision D-1, 2026-10-23, the macOS model; audit GF-001) ----
    // A window restored from the Dock or the Window menu comes back on the display it was minimized from, at its frame, on
    // the Desktop that display shows now: never on the display of the Dock that was clicked. The place is recorded when the
    // plugin minimizes the window. When that display is gone, the focused display takes the window, its frame kept at the
    // same place relative to the display and fitted into it. Without a record (a window parked by the shell's fallback
    // before the plugin loaded) the focused display's Desktop takes it, as before.

    struct SavedPlace {
        std::string monitor;          // the display's name (Hyprland's monitor name, stable across reconnects)
        Box         monitorBox;       // that display then (layout)
        Box         frame;            // the window's floating box then (layout; the surface, its titlebar above it)
        bool        floating = false; // a floating window, not full screen or zoomed: its frame is given back
    };

    struct MonitorPlace {
        std::string_view name;
        Box              box;    // the display (layout)
        Box              usable; // the display without its reserved areas (menu bar, Dock) (layout)
    };

    struct RestorePlan {
        std::optional<size_t> monitor;       // index in the monitors: the display whose current Desktop takes the window
        std::optional<Box>    frame;         // the box the window gets back; nullopt: Hyprland's placement stays
        bool                  moved = false; // the display it was minimized from is gone: another display takes it
    };

    // `focused`: index of the focused display in `monitors` (nullopt: none). `titlebarHeight`: the band above the surface
    // that must stay on the display when a frame is fitted.
    RestorePlan planRestore(const std::optional<SavedPlace>& saved, std::span<const MonitorPlace> monitors, std::optional<size_t> focused, double titlebarHeight);

    // `frame` (layout, the surface box) fitted into `usable` with its titlebar (titlebarHeight above the surface) inside:
    // a side longer than the area shrinks to it, then the box moves in. A degenerate area returns `frame`.
    Box fitFrame(const Box& frame, const Box& usable, double titlebarHeight);

} // namespace gf::minimize
