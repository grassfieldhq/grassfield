#pragma once

// A window's titlebar never goes under the menu bar (macOS): a drag that would leave the top of a floating window under
// it, or above the output, keeps it just below the menu bar, so the window can always be grabbed again. The titlebar is
// the plugin's (a band above the surface) or the app's own (no band: client chrome, ADR-0015, e.g. Chromium's tab
// strip, which is how the owner lost a window under the menu bar). Only the top is held: a window may still hang off
// the sides or the bottom of an output. Pure logic, no Hyprland includes: unit-tested in tests/TopClampTest.cpp.

#include "Tiling.hpp"

#include <cstddef>
#include <optional>
#include <span>

namespace gf::topclamp {

    using Rect = gf::tiling::Rect; // global logical (layout) coordinates

    struct Point {
        double x = 0;
        double y = 0;
    };

    // An output: its box and the bottom of its menu bar strip (the output's top reserved area; its top without one).
    struct Output {
        Rect   box;
        double menuBarBottom = 0;
    };

    // The output whose menu bar holds a window's titlebar, `frame` being the surface with its titlebar band:
    //  - the output the frame's top edge lies on (the one sharing most of its width when the edge crosses several), unless
    //    it holds only a sliver of the edge (under 64 px) and the nearest output below shares more of it: that one then;
    //  - else (the top edge above the outputs or in a gap between them: out of reach there) the nearest output below the
    //    top edge that shares some of its width;
    //  - else the output under the pointer; none when the pointer is on none either.
    // The top edge decides, not the pointer: a SUPER+drag or a resize may hold the window anywhere, and the output under
    // the pointer moved a window that sat correctly on an upper output onto the lower one at the release (review of
    // e0a3734). During a titlebar drag both are the same output.
    std::optional<size_t> outputFor(const Rect& frame, Point pointer, std::span<const Output> outputs);

    // A move: the surface box (its titlebar `band` px above it) moved down so that the frame starts at the menu bar's
    // bottom when it would start higher; unchanged otherwise. Whole pixels.
    Rect afterMove(const Rect& surface, double band, const Output& output);

    // A resize: the top edge stops at the menu bar's bottom (the bottom edge stays, the height shrinks, never below
    // 1 px); unchanged when the frame already starts below it. Whole pixels.
    Rect afterResize(const Rect& surface, double band, const Output& output);

    // Whether two boxes differ by more than rounding (half a pixel on any side).
    bool changed(const Rect& a, const Rect& b);

    // One step of the plugin's titlebar drag: the surface box it proposes, held below the menu bar of outputFor().
    Rect heldMove(const Rect& surface, double band, Point pointer, std::span<const Output> outputs);

    // The end of one of Hyprland's own drags that left the surface box at `after`; `before` is the box when the drag was
    // first seen moving (none when it never was). The box held below the menu bar, or none when it stays. A move is held
    // like a titlebar drag. A resize is held only when it moved the top edge: a resize from the bottom or a side edge
    // never moves the window (and one whose start is unknown is left alone).
    std::optional<Rect> afterDrag(const std::optional<Rect>& before, const Rect& after, bool resize, double band, Point pointer, std::span<const Output> outputs);

} // namespace gf::topclamp
