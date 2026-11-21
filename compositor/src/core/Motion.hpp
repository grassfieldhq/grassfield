#pragma once

// Retargetable box animations shared by Stages and the Overview (docs/specs/stages.md, docs/specs/overview.md
// "Retargeting"): one track per window, with its own clock. A track runs the shell's timing curve (Tokens.motionCurve*,
// sent with each request) from where a window is drawn to its target; a new target taken mid-flight continues from the
// box on screen WITH the velocity it has there (macOS: an interrupted animation never stops dead and starts again), and a
// target that did not change leaves the track alone (its clock and curve go on). Plain C++, header only, no Hyprland
// includes: unit-tested in compositor/tests/OverviewTest.cpp (Motion*).
//
// The motion is the curve's interpolation plus a cubic Hermite term that carries the velocity of the moment of the
// retarget and fades out with zero slope at the end:
//     p(s) = A + (B - A) * e(s) + W * D * s * (1 - s)^2,      s = (now - start) / D in [0, 1]
// with e the eased progress, D the duration (ms) and W = v0 - (B - A) * e'(0) / D, so that p'(0) = v0 (the velocity at
// the retarget, layout px per ms) and p(1) = B at rest (p'(1) = (B - A) * e'(1) / D, the curve's own end). A track that
// starts from rest has W = 0: exactly the curve, as before.
//
// A retarget mid-flight also scales the duration by the share of the way left (never below kMinRetargetShare): a reversal
// shortly after the start (the Overview closed 50 ms after it opened) takes about as long as the way it travelled, not
// a full duration for a short distance; windows retargeted together stay in step with the ones whose target held.

#include "Overview.hpp"

#include <algorithm>
#include <cmath>
#include <optional>

namespace gf::motion {

    using Box   = gf::minimize::Box;
    using Curve = gf::overview::Curve;

    // The shortest share of a duration a mid-flight retarget runs for (a reversal right after the start).
    inline constexpr double kMinRetargetShare = 0.3;

    struct Track {
        std::optional<Box> from;  // nullopt: the window's live surface box (as `live` is at each step)
        std::optional<Box> to;    // nullopt: the window's live surface box
        Box                carry; // W above: the velocity correction (layout px per ms, per component x, y, w, h)
        double             startMs    = 0;
        double             durationMs = 0; // 0: at its target at once (Reduce Motion)
        Curve              curve;
    };

    inline Box add(const Box& a, const Box& b) {
        return Box{a.x + b.x, a.y + b.y, a.w + b.w, a.h + b.h};
    }
    inline Box sub(const Box& a, const Box& b) {
        return Box{a.x - b.x, a.y - b.y, a.w - b.w, a.h - b.h};
    }
    inline Box mul(const Box& a, double k) {
        return Box{a.x * k, a.y * k, a.w * k, a.h * k};
    }

    // How far apart two boxes are: the Euclidean distance of their edges (left, top, right, bottom), layout px.
    inline double distance(const Box& a, const Box& b) {
        const double l = a.x - b.x, t = a.y - b.y, r = (a.x + a.w) - (b.x + b.w), btm = (a.y + a.h) - (b.y + b.h);
        return std::sqrt((l * l) + (t * t) + (r * r) + (btm * btm));
    }

    // de/dt of the eased progress at linear progress t (central difference; one-sided at the ends).
    inline double easedSlope(const Curve& curve, double t) {
        constexpr double h = 1e-4;
        const double     a = std::clamp(t - h, 0.0, 1.0), b = std::clamp(t + h, 0.0, 1.0);
        return b > a ? (gf::overview::eased(curve, b) - gf::overview::eased(curve, a)) / (b - a) : 0.0;
    }

    inline double endMs(const Track& t) {
        return t.startMs + std::max(0.0, t.durationMs);
    }

    // At its target and at rest from `nowMs` on.
    inline bool settled(const Track& t, double nowMs) {
        return !(t.durationMs > 0) || !std::isfinite(nowMs) || nowMs >= endMs(t);
    }

    // Linear progress s of the track at nowMs (0 before its start, 1 once settled).
    inline double progressAt(const Track& t, double nowMs) {
        return settled(t, nowMs) ? 1.0 : std::clamp((nowMs - t.startMs) / t.durationMs, 0.0, 1.0);
    }

    // Where the window's surface box is drawn at nowMs. `live`: its live surface box (for a nullopt end).
    inline Box positionAt(const Track& t, const Box& live, double nowMs) {
        const Box b = t.to.value_or(live);
        if (settled(t, nowMs))
            return b;
        const double s = progressAt(t, nowMs);
        const Box    a = t.from.value_or(live);
        const double h = t.durationMs * s * (1.0 - s) * (1.0 - s);
        return add(add(a, mul(sub(b, a), gf::overview::eased(t.curve, s))), mul(t.carry, h));
    }

    // Its velocity at nowMs (layout px per ms; zero once settled).
    inline Box velocityAt(const Track& t, const Box& live, double nowMs) {
        if (settled(t, nowMs))
            return Box{};
        const double s = progressAt(t, nowMs);
        const Box    a = t.from.value_or(live), b = t.to.value_or(live);
        return add(mul(sub(b, a), easedSlope(t.curve, s) / t.durationMs), mul(t.carry, (1.0 - s) * (1.0 - (3.0 * s))));
    }

    // A fresh track from rest: from `from` (nullopt: live) to `to` over durationMs.
    inline Track start(const std::optional<Box>& from, const std::optional<Box>& to, double nowMs, double durationMs, const Curve& curve) {
        return Track{.from = from, .to = to, .carry = {}, .startMs = nowMs, .durationMs = std::max(0.0, durationMs), .curve = curve};
    }

    // The track goes to `to` from where it is at nowMs, keeping its velocity; mid-flight the duration is scaled by the share
    // of the way left (kMinRetargetShare at least). False, and the track untouched, when `to` is its target already.
    inline bool retarget(Track& t, const std::optional<Box>& to, const Box& live, double nowMs, double durationMs, const Curve& curve) {
        if (t.to == to)
            return false;
        const bool   moving = !settled(t, nowMs);
        const Box    here   = positionAt(t, live, nowMs);
        const Box    v      = moving ? velocityAt(t, live, nowMs) : Box{};
        const Box    target = to.value_or(live);
        double       d      = std::isfinite(durationMs) ? std::max(0.0, durationMs) : 0.0;
        if (moving && d > 0) {
            const Box    a    = t.from.value_or(live);
            const double span = std::max(distance(a, t.to.value_or(live)), distance(a, target));
            if (span > 0.5)
                d *= std::clamp(distance(here, target) / span, kMinRetargetShare, 1.0);
        }
        Box carry{}; // from rest: exactly the curve (as start())
        if (moving && d > 0)
            carry = sub(v, mul(sub(target, here), easedSlope(curve, 0.0) / d));
        if (!gf::minimize::isFinite(carry))
            carry = {};
        t = Track{.from = here, .to = to, .carry = carry, .startMs = nowMs, .durationMs = d, .curve = curve};
        return true;
    }

} // namespace gf::motion
