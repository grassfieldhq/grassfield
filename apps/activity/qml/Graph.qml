pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// One graph of the summary (spec AM29, AM33, AM39, AM42, AM44): the backend's block {style, max, series: [{values, xs, color}],
// levels, levelColors} drawn as filled bands, no line and no grid. A value below 0 is a gap (no rate that sample, AM8): the
// fill stops there and starts again after it. Without `xs` the newest value is at the right edge, one slot per sample of
// `capacity`; with them each value is at its own place (the battery's times).
// The drawing is the app's GraphItem (src/graphitem.h, Grassfield.Activity): its triangles are kept between samples and a new
// sample writes only its own (it was QtQuick.Shapes, rebuilt in JavaScript and triangulated again at every sample, for every
// graph: one per processor in CPU History; audit apps-misc). This file resolves the colour names and draws the middle line.
// A QML test runner, which has no Grassfield.Activity, draws no bands (tests/unit/activity/qml/tst_graph.cpp draws them).
Item {
    id: root
    // A rule or frame: one point (apps.borderWidth, ADR-0039 D5) in whole device pixels, 1 px at 1.25 where 1 pt drew a soft
    // 1.25 px (UI audit 2026-11-05 U37); 1 px at 1x and 2 px at 2x as before.
    readonly property real hairline: Math.max(1, Math.round(Tokens.appsBorderWidth * Screen.devicePixelRatio)) / Math.max(1, Screen.devicePixelRatio)

    property var graph: ({})
    property int capacity: 1

    readonly property string style: root.graph.style || "area"
    readonly property var series: root.graph.series || []
    // Series 0, series 1, then the bars' levels 0 to 2 (GraphItem.colors).
    readonly property var colors: [root.colorOf(0), root.colorOf(1), root.levelColor(0), root.levelColor(1), root.levelColor(2)]
    // The GraphItem, once made.
    property Item surface: null

    function colorOf(i: int): color {
        const name = i < root.series.length ? root.series[i].color : "";
        return name && Appearance.colors[name] !== undefined ? Appearance.colors[name] : "transparent";
    }
    function levelColor(level: int): color {
        const names = root.graph.levelColors || [];
        return level < names.length && Appearance.colors[names[level]] !== undefined ? Appearance.colors[names[level]] : "transparent";
    }

    clip: true

    Component.onCompleted: {
        try {
            const item = Qt.createQmlObject("import Grassfield.Activity\nGraphItem {}", root, "GraphItem");
            // Its properties follow this item's (the type is the app's: named, not known to the linter).
            const follow = {
                width: () => root.width,
                height: () => root.height,
                capacity: () => root.capacity,
                colors: () => root.colors,
                graph: () => root.graph
            };
            for (const name in follow)
                item[name] = Qt.binding(follow[name]);
            root.surface = item as Item;
        } catch (e) {
            root.surface = null;
        }
    }

    // The middle line of a mirrored graph: what is above came in (or was read), what is below went out (or was written).
    Rectangle {
        visible: root.style === "mirrored"
        width: parent.width
        height: root.hairline
        y: Math.round(parent.height / 2)
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }
}
