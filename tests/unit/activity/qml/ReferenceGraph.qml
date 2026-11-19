pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import Grassfield.Ui

// The graph as apps/activity/qml/Graph.qml drew it before GraphItem (QtQuick.Shapes, the polygons built in JavaScript at
// every sample), kept as the reference of tst_graph.cpp's pixel comparison. Not part of the app. One change: `barsFillRule`
// (the former file used ShapePath's default odd-even rule, under which the half pixel by which a bar overlaps the next one,
// meant to hide the seam between two bars of one level, cancelled out and showed as a white seam; GraphItem has none, and
// the comparison of the bars is made with the winding rule).
//
// One graph of the summary (spec AM29, AM33, AM39, AM42, AM44): the backend's block {style, max, series: [{values, xs, color}],
// levels, levelColors} drawn as filled shapes, no line and no grid. A value below 0 is a gap (no rate that sample, AM8): the
// fill stops there and starts again after it. Without `xs` the newest value is at the right edge, one slot per sample of
// `capacity`; with them each value is at its own place (the battery's times).
Item {
    id: root
    // A rule or frame: one point (apps.borderWidth, ADR-0039 D5) in whole device pixels, 1 px at 1.25 where 1 pt drew a soft
    // 1.25 px (UI audit 2026-11-05 U37); 1 px at 1x and 2 px at 2x as before.
    readonly property real hairline: Math.max(1, Math.round(Tokens.appsBorderWidth * Screen.devicePixelRatio)) / Math.max(1, Screen.devicePixelRatio)

    property var graph: ({})
    property int capacity: 1
    property int barsFillRule: ShapePath.OddEvenFill

    readonly property string style: root.graph.style || "area"
    readonly property real ceiling: root.graph.max > 0 ? root.graph.max : 1
    readonly property var series: root.graph.series || []

    function valuesOf(i: int): var {
        return i < root.series.length ? root.series[i].values : [];
    }
    function colorOf(i: int): color {
        const name = i < root.series.length ? root.series[i].color : "";
        return name && Appearance.colors[name] !== undefined ? Appearance.colors[name] : "transparent";
    }
    function xAt(n: int, i: int, xs: var): real {
        if (xs && i < xs.length)
            return xs[i] * root.width;
        const slots = Math.max(1, root.capacity - 1);
        return root.width - (n - 1 - i) * root.width / slots;
    }
    // The runs of values at or above 0, each a polygon from `base(v)` to `edge(v)` (y from the top), its top edge left to
    // right and its bottom edge back.
    function runs(values: var, xs: var, edge: var, base: var): var {
        const out = [];
        let top = [], bottom = [];
        const n = values.length;
        for (let i = 0; i <= n; i++) {
            const v = i < n ? values[i] : -1;
            if (v >= 0) {
                const x = root.xAt(n, i, xs);
                top.push(Qt.point(x, edge(i, v)));
                bottom.unshift(Qt.point(x, base(i, v)));
                continue;
            }
            if (top.length === 1) { // a lone sample: as wide as one slot
                const w = root.width / Math.max(1, root.capacity - 1);
                top.unshift(Qt.point(top[0].x - w, top[0].y));
                bottom.push(Qt.point(bottom[0].x - w, bottom[0].y));
            }
            if (top.length > 0)
                out.push(top.concat(bottom, [top[0]])); // closed: every renderer fills it the same
            top = [];
            bottom = [];
        }
        return out;
    }
    function yOf(v: real): real {
        return root.height - Math.min(1, v / root.ceiling) * root.height;
    }

    // "area": one series filled from the bottom. "stacked": the first from the bottom, the second on top of it.
    readonly property var lower: {
        if (root.style === "mirrored")
            return root.runs(root.valuesOf(0), null, (i, v) => root.height / 2 - Math.min(1, v / root.ceiling) * root.height / 2, () => root.height / 2);
        if (root.style === "area" || root.style === "stacked")
            return root.runs(root.valuesOf(0), root.series.length > 0 ? root.series[0].xs : null, (i, v) => root.yOf(v), () => root.height);
        return [];
    }
    readonly property var upper: {
        if (root.style === "mirrored")
            return root.runs(root.valuesOf(1), null, (i, v) => root.height / 2 + Math.min(1, v / root.ceiling) * root.height / 2, () => root.height / 2);
        if (root.style === "stacked") {
            const under = root.valuesOf(0);
            const on = root.valuesOf(1).map((v, i) => v >= 0 && i < under.length && under[i] >= 0 ? v : -1);
            return root.runs(on, null, (i, v) => root.yOf(under[i] + v), (i, v) => root.yOf(under[i]));
        }
        return [];
    }
    // "bars": one bar per sample, coloured by its level (Memory Pressure).
    function bars(level: int): var {
        if (root.style !== "bars")
            return [];
        const values = root.valuesOf(0), levels = root.graph.levels || [];
        const n = values.length, slot = root.width / Math.max(1, root.capacity), out = [];
        for (let i = 0; i < n; i++) {
            if (values[i] < 0 || levels[i] !== level)
                continue;
            // Each bar meets the next (half a pixel over it, so no seam shows between two of the same colour).
            const right = root.width - (n - 1 - i) * slot, left = right - slot - 0.5, y = root.yOf(values[i]);
            out.push([Qt.point(left, root.height), Qt.point(left, y), Qt.point(right, y), Qt.point(right, root.height), Qt.point(left, root.height)]);
        }
        return out;
    }
    function levelColor(level: int): color {
        const names = root.graph.levelColors || [];
        return level < names.length && Appearance.colors[names[level]] !== undefined ? Appearance.colors[names[level]] : "transparent";
    }

    clip: true

    // The middle line of a mirrored graph: what is above came in (or was read), what is below went out (or was written).
    Rectangle {
        visible: root.style === "mirrored"
        width: parent.width
        height: root.hairline
        y: Math.round(parent.height / 2)
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: "transparent"
            strokeWidth: -1
            fillColor: root.colorOf(0)
            PathMultiline {
                paths: root.lower
            }
        }
        ShapePath {
            strokeColor: "transparent"
            strokeWidth: -1
            fillColor: root.colorOf(1)
            PathMultiline {
                paths: root.upper
            }
        }
        ShapePath {
            strokeColor: "transparent"
            strokeWidth: -1
            fillColor: root.levelColor(0)
            fillRule: root.barsFillRule
            PathMultiline {
                paths: root.bars(0)
            }
        }
        ShapePath {
            strokeColor: "transparent"
            strokeWidth: -1
            fillColor: root.levelColor(1)
            fillRule: root.barsFillRule
            PathMultiline {
                paths: root.bars(1)
            }
        }
        ShapePath {
            strokeColor: "transparent"
            strokeWidth: -1
            fillColor: root.levelColor(2)
            fillRule: root.barsFillRule
            PathMultiline {
                paths: root.bars(2)
            }
        }
    }
}
