#include "TopClamp.hpp"

#include <algorithm>
#include <cmath>

namespace gf::topclamp {

    namespace {
        bool usable(const Rect& r) {
            return r.w > 0 && r.h > 0;
        }

        bool contains(const Rect& r, double x, double y) {
            return usable(r) && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
        }

        // Width the horizontal segment [left, right) shares with the box (<= 0: none).
        double sharedWidth(double left, double right, const Rect& box) {
            return std::min(right, box.x + box.w) - std::max(left, box.x);
        }

        // The least width of a titlebar that is still easy to grab (px): below it, an output does not hold the top edge when a
        // lower output shares more of it (outputFor).
        constexpr double kReachWidth = 64;

        // The highest surface top whose frame still starts below the menu bar (whole pixels, rounded up: never under it).
        double lowestAllowedTop(double band, const Output& output) {
            return std::ceil(output.menuBarBottom + band);
        }
    } // namespace

    std::optional<size_t> outputFor(const Rect& frame, Point pointer, std::span<const Output> outputs) {
        const double left  = frame.x;
        const double right = frame.x + frame.w;
        const double top   = frame.y;
        // The output the top edge lies on.
        std::optional<size_t> on;
        double                onWidth = 0;
        for (size_t i = 0; i < outputs.size(); ++i) {
            const Rect& box = outputs[i].box;
            if (!usable(box) || top < box.y || top >= box.y + box.h)
                continue;
            if (const double w = sharedWidth(left, right, box); w > onWidth) {
                on      = i;
                onWidth = w;
            }
        }
        // Out of reach (above the outputs, in a gap): the nearest output below it; of outputs whose tops are level, the one
        // sharing most of its width (review of 9ba1d40: a tie went to the lowest index).
        std::optional<size_t> below;
        double                belowWidth = 0;
        for (size_t i = 0; i < outputs.size(); ++i) {
            const Rect&  box = outputs[i].box;
            const double w   = sharedWidth(left, right, box);
            if (!usable(box) || box.y <= top || w <= 0)
                continue;
            const bool nearer = !below || box.y < outputs[*below].box.y - 0.5;
            const bool level  = below && std::abs(box.y - outputs[*below].box.y) <= 0.5; // level within half a pixel
            if (nearer || (level && w > belowWidth)) {
                below      = i;
                belowWidth = w;
            }
        }
        // On an output by a sliver only, the rest above a lower output that shares more of the edge (outputs side by side,
        // one set lower): the titlebar would stay in the dead space above that output, grabbable by the sliver alone. The
        // lower output holds it then.
        if (on && !(below && onWidth < kReachWidth && belowWidth > onWidth))
            return on;
        if (below)
            return below;
        for (size_t i = 0; i < outputs.size(); ++i) {
            if (contains(outputs[i].box, pointer.x, pointer.y))
                return i;
        }
        return std::nullopt;
    }

    Rect afterMove(const Rect& surface, double band, const Output& output) {
        const double top = lowestAllowedTop(band, output);
        if (surface.y >= top - 0.5)
            return surface;
        Rect moved = surface;
        moved.y    = top;
        return moved;
    }

    Rect afterResize(const Rect& surface, double band, const Output& output) {
        const double top = lowestAllowedTop(band, output);
        if (surface.y >= top - 0.5)
            return surface;
        const double bottom = surface.y + surface.h;
        Rect trimmed        = surface;
        trimmed.y           = top;
        trimmed.h           = std::max(1.0, std::round(bottom - top));
        return trimmed;
    }

    bool changed(const Rect& a, const Rect& b) {
        return std::abs(a.x - b.x) > 0.5 || std::abs(a.y - b.y) > 0.5 || std::abs(a.w - b.w) > 0.5 || std::abs(a.h - b.h) > 0.5;
    }

    Rect heldMove(const Rect& surface, double band, Point pointer, std::span<const Output> outputs) {
        const auto at = outputFor(gf::tiling::frameOf(surface, band), pointer, outputs);
        return at ? afterMove(surface, band, outputs[*at]) : surface;
    }

    std::optional<Rect> afterDrag(const std::optional<Rect>& before, const Rect& after, bool resize, double band, Point pointer, std::span<const Output> outputs) {
        if (resize && (!before || std::abs(before->y - after.y) <= 0.5))
            return std::nullopt; // the grip was on another edge: the top did not move
        const auto at = outputFor(gf::tiling::frameOf(after, band), pointer, outputs);
        if (!at)
            return std::nullopt;
        const Rect next = resize ? afterResize(after, band, outputs[*at]) : afterMove(after, band, outputs[*at]);
        if (!changed(next, after))
            return std::nullopt;
        return next;
    }

} // namespace gf::topclamp
