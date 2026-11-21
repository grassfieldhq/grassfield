#include "Overview.hpp"

#include "Json.hpp"
#include "Protocol.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <format>

namespace gf::overview {

    namespace {
        // The strict JSON reader shared with Stages (core/Json.*): strings over kMaxStringBytes and nesting deeper than
        // kMaxDepth are refused.
        using CJsonReader = gf::json::CReader;

        using Error = std::unexpected<std::string>;

        std::expected<WindowTarget, std::string> parseWindow(CJsonReader& in, size_t index) {
            if (!in.take('{'))
                return Error{std::format("windows[{}]: not an object", index)};
            WindowTarget          target;
            bool                  haveAddress = false;
            std::array<bool, 4>   have{};
            std::array<double, 4> values{};
            if (!in.take('}')) {
                do {
                    const auto key = in.string();
                    if (!key || !in.take(':'))
                        return Error{std::format("windows[{}]: malformed member", index)};
                    if (*key == "address") {
                        if (haveAddress)
                            return Error{std::format("windows[{}]: address given twice", index)};
                        const auto text    = in.string();
                        const auto address = text ? gf::minimize::parseAddress(*text) : std::nullopt;
                        if (!address)
                            return Error{std::format("windows[{}]: address is not \"0x\" + 1-16 hex digits", index)};
                        target.address = *address;
                        haveAddress    = true;
                        continue;
                    }
                    static constexpr std::array<std::string_view, 4> NAMES = {"x", "y", "w", "h"};
                    const auto it = std::ranges::find(NAMES, *key);
                    if (it == NAMES.end()) {
                        if (!in.skipValue())
                            return Error{std::format("windows[{}]: malformed value of {}", index, *key)};
                        continue;
                    }
                    const auto slot = static_cast<size_t>(it - NAMES.begin());
                    if (have[slot])
                        return Error{std::format("windows[{}]: {} given twice", index, *key)};
                    const auto value = in.number();
                    if (!value)
                        return Error{std::format("windows[{}]: {} is not a finite number", index, *key)};
                    values[slot] = *value;
                    have[slot]   = true;
                } while (in.take(','));
                if (!in.take('}'))
                    return Error{std::format("windows[{}]: malformed object", index)};
            }
            if (!haveAddress || !std::ranges::all_of(have, [](bool b) { return b; }))
                return Error{std::format("windows[{}]: address, x, y, w and h are required", index)};
            target.rect = Box{values[0], values[1], values[2], values[3]};
            if (target.rect.w < 1.0 || target.rect.h < 1.0)
                return Error{std::format("windows[{}]: w and h must be at least 1", index)};
            return target;
        }

        std::expected<std::vector<WindowTarget>, std::string> parseWindows(CJsonReader& in) {
            std::vector<WindowTarget> out;
            if (!in.take('['))
                return Error{"windows: not an array"};
            if (in.take(']'))
                return out;
            do {
                if (out.size() >= kMaxWindows)
                    return Error{std::format("windows: more than {}", kMaxWindows)};
                auto target = parseWindow(in, out.size());
                if (!target)
                    return Error{target.error()};
                if (std::ranges::any_of(out, [&](const WindowTarget& t) { return t.address == target->address; }))
                    return Error{std::format("windows[{}]: address listed twice", out.size())};
                out.push_back(*target);
            } while (in.take(','));
            if (!in.take(']'))
                return Error{"windows: malformed array"};
            return out;
        }

        std::expected<Curve, std::string> parseCurve(CJsonReader& in) {
            std::array<double, 4> v{};
            if (!in.take('['))
                return Error{"curve: not an array"};
            for (size_t i = 0; i < v.size(); ++i) {
                if (i > 0 && !in.take(','))
                    return Error{"curve: 4 numbers expected"};
                const auto n = in.number();
                if (!n)
                    return Error{"curve: 4 finite numbers expected"};
                v[i] = *n;
            }
            if (!in.take(']'))
                return Error{"curve: 4 numbers expected"};
            const auto xOk = [](double x) { return x >= 0.0 && x <= 1.0; };
            const auto yOk = [](double y) { return y >= kMinCurveY && y <= kMaxCurveY; };
            if (!xOk(v[0]) || !xOk(v[2]) || !yOk(v[1]) || !yOk(v[3]))
                return Error{"curve: control points out of range"};
            return Curve{v[0], v[1], v[2], v[3]};
        }
    } // namespace

    std::expected<Request, std::string> parseRequest(std::string_view json) {
        if (json.size() > kMaxPayloadBytes)
            return Error{std::format("payload larger than {} bytes", kMaxPayloadBytes)};
        CJsonReader in{json, kMaxStringBytes, kMaxDepth};
        Request     request;
        bool        haveOn = false, haveDuration = false, haveWindows = false, haveCurve = false;
        if (!in.take('{'))
            return Error{"not a JSON object"};
        if (!in.take('}')) {
            do {
                const auto key = in.string();
                if (!key || !in.take(':'))
                    return Error{"malformed member"};
                const auto once = [&](bool& seen) -> bool {
                    const bool first = !seen;
                    seen             = true;
                    return first;
                };
                if (*key == "on") {
                    if (!once(haveOn))
                        return Error{"on given twice"};
                    const auto on = in.boolean();
                    if (!on)
                        return Error{"on is not a boolean"};
                    request.on = *on;
                } else if (*key == "durationMs") {
                    if (!once(haveDuration))
                        return Error{"durationMs given twice"};
                    const auto d = in.number();
                    if (!d || *d != std::floor(*d) || *d < 0 || *d > kMaxDurationMs)
                        return Error{std::format("durationMs is not an integer in 0..{}", kMaxDurationMs)};
                    request.durationMs = *d;
                } else if (*key == "windows") {
                    if (!once(haveWindows))
                        return Error{"windows given twice"};
                    auto windows = parseWindows(in);
                    if (!windows)
                        return Error{windows.error()};
                    request.windows = std::move(*windows);
                } else if (*key == "curve") {
                    if (!once(haveCurve))
                        return Error{"curve given twice"};
                    auto curve = parseCurve(in);
                    if (!curve)
                        return Error{curve.error()};
                    request.curve = *curve;
                } else if (!in.skipValue())
                    return Error{std::format("malformed value of {}", *key)};
            } while (in.take(','));
            if (!in.take('}'))
                return Error{"malformed object"};
        }
        if (!in.atEnd())
            return Error{"trailing characters after the object"};
        if (!haveOn || !haveDuration)
            return Error{"on and durationMs are required"};
        if (request.on && !haveWindows)
            return Error{"windows is required when on is true"};
        return request;
    }

    bool insideMonitor(const Box& rect, const Box& monitor) {
        constexpr double TOL = gf::minimize::kLayoutTolerance;
        if (!gf::minimize::isFinite(rect) || !gf::minimize::isFinite(monitor) || monitor.w <= 0 || monitor.h <= 0 || rect.w <= 0 || rect.h <= 0)
            return false;
        return rect.x >= monitor.x - TOL && rect.y >= monitor.y - TOL && rect.x + rect.w <= monitor.x + monitor.w + TOL && rect.y + rect.h <= monitor.y + monitor.h + TOL;
    }

    double progress(double elapsedMs, double durationMs) {
        if (!(durationMs > 0) || !std::isfinite(elapsedMs))
            return 1.0;
        return std::clamp(elapsedMs / durationMs, 0.0, 1.0);
    }

    double eased(const Curve& curve, double t) {
        return gf::minimize::CCubicBezier{curve.x1, curve.y1, curve.x2, curve.y2}(t);
    }

    Box drawBox(const Box& surface, const Box& rect) {
        return gf::minimize::fitInside(surface, rect);
    }

    Box interpolate(const std::optional<Box>& from, const std::optional<Box>& to, const Box& live, double e) {
        return gf::minimize::lerp(from.value_or(live), to.value_or(live), e);
    }

    std::string_view phaseName(Phase phase) {
        switch (phase) {
            case Phase::Closed: return "closed";
            case Phase::Opening: return "opening";
            case Phase::Open: return "open";
            case Phase::Closing: return "closing";
        }
        return "closed";
    }

    std::string_view reasonName(Reason reason) {
        switch (reason) {
            case Reason::None: return "";
            case Reason::Invalid: return "invalid";
            case Reason::NoWindows: return "no-windows";
            case Reason::Unavailable: return "unavailable";
            case Reason::Interrupted: return "interrupted";
            case Reason::NoChrome: return "no-chrome";
            case Reason::Fullscreen: return "fullscreen";
        }
        return "";
    }

    bool focusEndsOverview(FocusCause cause) {
        switch (cause) {
            case FocusCause::UserOrOther: return true;
            case FocusCause::WindowClosed:
            case FocusCause::WindowOpened: return false;
        }
        return true;
    }

    bool chromeCovers(const std::vector<uint64_t>& targetMonitors, const std::vector<ChromeSurface>& chromes) {
        if (targetMonitors.empty())
            return false;
        const bool keyboardHeld = std::ranges::any_of(chromes, [](const ChromeSurface& c) { return c.mapped && c.exclusive && c.keyboard; });
        return keyboardHeld && std::ranges::all_of(targetMonitors, [&chromes](uint64_t monitor) {
                   return std::ranges::any_of(chromes, [monitor](const ChromeSurface& c) { return c.monitor == monitor && c.mapped; });
               });
    }

    DamageBoxes damageStep(const Box& previous, const Box& current) {
        const auto  hasArea = [](const Box& b) { return gf::minimize::isFinite(b) && b.w > 0 && b.h > 0; };
        DamageBoxes out;
        if (hasArea(previous) && !(previous == current))
            out.boxes.at(out.count++) = previous;
        if (hasArea(current))
            out.boxes.at(out.count++) = current;
        return out;
    }

    bool needsRepaint(const Box& previous, const Box& current, bool contentDamaged) {
        return contentDamaged || !(previous == current);
    }

    std::string eventJson(Phase phase, size_t windows, Reason reason) {
        std::string out{R"({"v":")"};
        out += gf::gfc::jsonEscape(gf::gfc::kVersion);
        out += R"(","type":"overview","state":")";
        out += phaseName(phase);
        out += R"(","windows":)";
        out += std::to_string(windows);
        if (reason != Reason::None) {
            out += R"(,"reason":")";
            out += reasonName(reason);
            out += '"';
        }
        out += '}';
        return out;
    }

} // namespace gf::overview
