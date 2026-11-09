#include "CapturePrivacy.hpp"

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

    Box platePx(const Box& fitted, double monX, double monY, double scale) {
        const double left   = (fitted.x - monX) * scale;
        const double top    = (fitted.y - monY) * scale;
        const double right  = (fitted.x + fitted.w - monX) * scale;
        const double bottom = (fitted.y + fitted.h - monY) * scale;
        if (!std::isfinite(left) || !std::isfinite(top) || !std::isfinite(right) || !std::isfinite(bottom) || !(scale > 0.0) || !(fitted.w > 0.0) ||
            !(fitted.h > 0.0))
            return Box{};
        const double x0 = std::floor(left) - 1.0;
        const double y0 = std::floor(top) - 1.0;
        const double x1 = std::ceil(right) + 1.0;
        const double y1 = std::ceil(bottom) + 1.0;
        return Box{x0, y0, x1 - x0, y1 - y0};
    }

} // namespace gf::privacy
