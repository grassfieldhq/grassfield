#include "Minimize.hpp"

#include <algorithm>
#include <charconv>
#include <cmath>

namespace gf::minimize {

    std::optional<uint64_t> parseAddress(std::string_view text) {
        if (text.starts_with("0x") || text.starts_with("0X"))
            text.remove_prefix(2);
        if (text.empty() || text.size() > 16)
            return std::nullopt;
        for (const char c : text) {
            const bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
            if (!hex)
                return std::nullopt;
        }
        uint64_t value = 0;
        const auto [end, ec] = std::from_chars(text.data(), text.data() + text.size(), value, 16);
        if (ec != std::errc{} || end != text.data() + text.size() || value == 0)
            return std::nullopt;
        return value;
    }

    bool isFinite(const Box& b) {
        return std::isfinite(b.x) && std::isfinite(b.y) && std::isfinite(b.w) && std::isfinite(b.h);
    }

    bool isValidTarget(const Box& target, std::span<const Box> monitors) {
        if (!isFinite(target) || target.w < 1.0 || target.h < 1.0 || target.w > kMaxTargetSide || target.h > kMaxTargetSide)
            return false;
        return std::ranges::any_of(monitors, [&target](const Box& m) {
            if (!isFinite(m) || m.w <= 0 || m.h <= 0)
                return false;
            return target.x >= m.x - kLayoutTolerance && target.y >= m.y - kLayoutTolerance && target.x + target.w <= m.x + m.w + kLayoutTolerance &&
                target.y + target.h <= m.y + m.h + kLayoutTolerance;
        });
    }

    Box fitInside(const Box& source, const Box& target) {
        if (source.w <= 0 || source.h <= 0 || target.w <= 0 || target.h <= 0)
            return target;
        const double scale = std::min(target.w / source.w, target.h / source.h);
        const double w     = source.w * scale;
        const double h     = source.h * scale;
        return Box{target.x + ((target.w - w) / 2.0), target.y + ((target.h - h) / 2.0), w, h};
    }

    Box lerp(const Box& a, const Box& b, double t) {
        const auto mix = [t](double p, double q) { return p + ((q - p) * t); };
        return Box{mix(a.x, b.x), mix(a.y, b.y), mix(a.w, b.w), mix(a.h, b.h)};
    }

    double CCubicBezier::operator()(double t) const {
        t = std::clamp(t, 0.0, 1.0);
        if (t == 0.0 || t == 1.0)
            return t;

        const auto bez  = [](double p1, double p2, double s) { return (3.0 * (1.0 - s) * (1.0 - s) * s * p1) + (3.0 * (1.0 - s) * s * s * p2) + (s * s * s); };
        const auto dbez = [](double p1, double p2, double s) { return (3.0 * (1.0 - s) * (1.0 - s) * p1) + (6.0 * (1.0 - s) * s * (p2 - p1)) + (3.0 * s * s * (1.0 - p2)); };

        // x(s) is monotonic on [0, 1] (x1, x2 clamped): Newton steps, bisection when the slope is flat.
        double s  = t;
        double lo = 0.0;
        double hi = 1.0;
        for (int i = 0; i < 32; ++i) {
            const double x = bez(m_x1, m_x2, s) - t;
            if (std::abs(x) < 1e-9)
                break;
            if (x > 0)
                hi = s;
            else
                lo = s;
            const double d = dbez(m_x1, m_x2, s);
            double       next = std::abs(d) > 1e-6 ? s - (x / d) : (lo + hi) / 2.0;
            if (next <= lo || next >= hi)
                next = (lo + hi) / 2.0;
            s = next;
        }
        return bez(m_y1, m_y2, s);
    }

    double durationMs(Kind kind) {
        return kind == Kind::Minimize ? kMinimizeDurationMs : kRestoreDurationMs;
    }

    CCubicBezier curve(Kind kind) {
        // Ease-in (motion token "accelerate": 0.4, 0, 1, 1) and its time-reverse for the way back.
        return kind == Kind::Minimize ? CCubicBezier{0.4, 0.0, 1.0, 1.0} : CCubicBezier{0.0, 0.0, 0.6, 1.0};
    }

    Frame frameAt(Kind kind, const Box& from, const Box& to, double elapsedMs) {
        const double duration = durationMs(kind);
        const double t        = duration > 0 && std::isfinite(elapsedMs) ? std::clamp(elapsedMs / duration, 0.0, 1.0) : 1.0;

        Frame        frame;
        frame.box  = lerp(from, to, curve(kind)(t));
        frame.done = t >= 1.0;
        if (kind == Kind::Minimize)
            frame.alpha = t <= 1.0 - kFadeFraction ? 1.F : static_cast<float>((1.0 - t) / kFadeFraction);
        else
            frame.alpha = t >= kFadeFraction ? 1.F : static_cast<float>(t / kFadeFraction);
        frame.alpha = std::clamp(frame.alpha, 0.F, 1.F);
        return frame;
    }

    double easedProgress(Kind kind, double elapsedMs) {
        const double duration = durationMs(kind);
        const double t        = duration > 0 && std::isfinite(elapsedMs) ? std::clamp(elapsedMs / duration, 0.0, 1.0) : 1.0;
        return curve(kind)(t);
    }

    double elapsedForEased(Kind kind, double eased) {
        const double target = std::isfinite(eased) ? std::clamp(eased, 0.0, 1.0) : 1.0;
        const auto   c      = curve(kind);
        double       lo = 0.0, hi = 1.0; // the curve is monotonic in t (y1, y2 in [0, 1] for both timings)
        for (int i = 0; i < 48; ++i) {
            const double mid = (lo + hi) / 2.0;
            if (c(mid) < target)
                lo = mid;
            else
                hi = mid;
        }
        return ((lo + hi) / 2.0) * durationMs(kind);
    }

    Continuation continueFrom(Kind kind, const Box& current, const Box& to, double share) {
        const double s       = std::isfinite(share) ? std::clamp(share, 0.0, 0.95) : 0.0;
        const double elapsed = elapsedForEased(kind, s);
        const double e       = curve(kind)(elapsed / durationMs(kind)); // what frameAt will use at `elapsed`
        if (e >= 1.0 || !isFinite(current) || !isFinite(to))
            return Continuation{.from = current, .elapsedMs = 0};
        const auto back = [e](double c, double t) { return (c - (t * e)) / (1.0 - e); }; // lerp(from, to, e) == current
        return Continuation{.from = Box{back(current.x, to.x), back(current.y, to.y), back(current.w, to.w), back(current.h, to.h)}, .elapsedMs = elapsed};
    }

    double fadeElapsedFor(Kind kind, float alpha) {
        const double a = std::isfinite(alpha) ? std::clamp(static_cast<double>(alpha), 0.0, 1.0) : 1.0;
        return (kind == Kind::Minimize ? 1.0 - a : a) * kFadeDurationMs;
    }

    std::optional<Effect> parseEffect(std::string_view key, std::string_view value) {
        if (key != kConfigMinimizeEffect)
            return std::nullopt;
        if (value == "funnel")
            return Effect::Genie;
        if (value == "shrink")
            return Effect::Scale;
        if (value == "fade")
            return Effect::Fade;
        return std::nullopt;
    }

    bool isFunnelShaderFault(std::string_view key, std::string_view value, bool devSession) {
        return devSession && key == kConfigTestFault && value == kTestFaultFunnelShader;
    }

    Frame fadeFrameAt(Kind kind, const Box& box, double elapsedMs) {
        const double t = std::isfinite(elapsedMs) ? std::clamp(elapsedMs / kFadeDurationMs, 0.0, 1.0) : 1.0;
        Frame        frame;
        frame.box   = box;
        frame.done  = t >= 1.0;
        frame.alpha = std::clamp(static_cast<float>(kind == Kind::Minimize ? 1.0 - t : t), 0.F, 1.F);
        return frame;
    }

    Box mapBox(const Box& inner, const Box& src, const Box& dst) {
        const double sx = src.w > 0 ? dst.w / src.w : 1.0;
        const double sy = src.h > 0 ? dst.h / src.h : 1.0;
        return Box{dst.x + ((inner.x - src.x) * sx), dst.y + ((inner.y - src.y) * sy), inner.w * sx, inner.h * sy};
    }

    Box textureBox(const SSnapshotGeometry& snapshot, const Box& dst, double monX, double monY, double monScale) {
        const Box&   v  = snapshot.visible;
        const double kx = v.w > 0 && snapshot.monitorScale > 0 ? (dst.w * monScale) / (v.w * snapshot.monitorScale) : 1.0;
        const double ky = v.h > 0 && snapshot.monitorScale > 0 ? (dst.h * monScale) / (v.h * snapshot.monitorScale) : 1.0;
        return Box{((dst.x - monX) * monScale) - ((v.x - snapshot.monitorX) * snapshot.monitorScale * kx),
                   ((dst.y - monY) * monScale) - ((v.y - snapshot.monitorY) * snapshot.monitorScale * ky), snapshot.texW * kx, snapshot.texH * ky};
    }

    bool intersects(const Box& a, const Box& b) {
        return a.w > 0 && a.h > 0 && b.w > 0 && b.h > 0 && a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
    }

    Box fitFrame(const Box& frame, const Box& usable, double titlebarHeight) {
        if (!isFinite(frame) || !isFinite(usable) || !std::isfinite(titlebarHeight) || usable.w < 1.0 || usable.h - titlebarHeight < 1.0)
            return frame;
        const double w    = std::clamp(frame.w, 1.0, usable.w);
        const double h    = std::clamp(frame.h, 1.0, usable.h - titlebarHeight);
        const double minY = usable.y + titlebarHeight;
        return Box{std::clamp(frame.x, usable.x, usable.x + usable.w - w), std::clamp(frame.y, minY, usable.y + usable.h - h), w, h};
    }

    namespace {
        // `frame` at the same place relative to `to` as it was relative to `from`.
        Box translated(const Box& frame, const Box& from, const Box& to) {
            return Box{to.x + (frame.x - from.x), to.y + (frame.y - from.y), frame.w, frame.h};
        }

        bool usableFrame(const SavedPlace& saved) {
            return saved.floating && isFinite(saved.frame) && saved.frame.w > 0 && saved.frame.h > 0 && isFinite(saved.monitorBox);
        }
    } // namespace

    RestorePlan planRestore(const std::optional<SavedPlace>& saved, std::span<const MonitorPlace> monitors, std::optional<size_t> focused, double titlebarHeight) {
        RestorePlan plan;
        const auto  fallback = [&]() -> std::optional<size_t> {
            if (focused && *focused < monitors.size())
                return focused;
            return monitors.empty() ? std::nullopt : std::optional<size_t>{0};
        };
        if (!saved) {
            plan.monitor = fallback();
            return plan;
        }
        for (size_t i = 0; i < monitors.size(); ++i) {
            if (!saved->monitor.empty() && monitors[i].name == saved->monitor) {
                plan.monitor = i;
                break;
            }
        }
        if (!plan.monitor) {
            plan.monitor = fallback();
            plan.moved   = plan.monitor.has_value();
        }
        if (!plan.monitor || !usableFrame(*saved))
            return plan;
        const auto& m = monitors[*plan.monitor];
        if (!plan.moved && m.box == saved->monitorBox)
            plan.frame = saved->frame; // the same display, unchanged: the very frame
        else
            plan.frame = fitFrame(translated(saved->frame, saved->monitorBox, m.box), m.usable, titlebarHeight);
        return plan;
    }

} // namespace gf::minimize
