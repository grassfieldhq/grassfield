#include "CapturePrivacy.hpp"

#include <algorithm>
#include <cmath>

namespace gf::privacy {

    bool capturing(const CaptureCounts& counts) {
        return counts.sharingSessions > 0 || counts.pendingFrames > 0;
    }

    bool mayDrawContent(bool protectedWindow, bool capturing, bool tracked) {
        if (!protectedWindow)
            return true;
        return tracked && !capturing;
    }

    bool redrawWhole(DisplayCapture& display, bool capturingNow) {
        const bool changed = display.known ? display.capturing != capturingNow : capturingNow;
        display.known      = true;
        display.capturing  = capturingNow;
        return changed;
    }

    bool ended(const DisplayCapture& recorded, bool capturingNow) {
        return recorded.known && recorded.capturing && !capturingNow;
    }

    bool endChecked(bool started, bool windowShare) {
        return !started && !windowShare;
    }

    Box miniatureCover(const Box& surface, const Box& fitted, const std::vector<Box>& parts) {
        double left   = surface.x;
        double top    = surface.y;
        double right  = surface.x + surface.w;
        double bottom = surface.y + surface.h;
        for (const auto& p : parts) {
            if (!gf::minimize::isFinite(p) || !(p.w > 0.0) || !(p.h > 0.0))
                continue;
            left   = std::min(left, p.x);
            top    = std::min(top, p.y);
            right  = std::max(right, p.x + p.w);
            bottom = std::max(bottom, p.y + p.h);
        }
        return gf::minimize::mapBox(Box{left, top, right - left, bottom - top}, surface, fitted);
    }

    Box platePx(const Box& covered, double monX, double monY, double scale) {
        const double left   = (covered.x - monX) * scale;
        const double top    = (covered.y - monY) * scale;
        const double right  = (covered.x + covered.w - monX) * scale;
        const double bottom = (covered.y + covered.h - monY) * scale;
        if (!std::isfinite(left) || !std::isfinite(top) || !std::isfinite(right) || !std::isfinite(bottom) || !(scale > 0.0) || !(covered.w > 0.0) ||
            !(covered.h > 0.0))
            return Box{};
        const double x0 = std::floor(left) - 1.0;
        const double y0 = std::floor(top) - 1.0;
        const double x1 = std::ceil(right) + 1.0;
        const double y1 = std::ceil(bottom) + 1.0;
        return Box{x0, y0, x1 - x0, y1 - y0};
    }

} // namespace gf::privacy
