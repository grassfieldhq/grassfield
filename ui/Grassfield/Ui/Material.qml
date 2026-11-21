pragma ComponentBehavior: Bound
import QtQuick

// Glass surface (master-prompt 5.5, ADR-0024): the tint, a diffused shadow drawn outside the shape, and the macOS glass
// edge: one device pixel of darker edge outside, one of brighter specular rim inside (stronger along the top).
//
// This item does NOT blur. Blur comes from the compositor: the hosting window must
// declare this item's geometry as its blur region, e.g.
//     BackgroundEffect.blurRegion: Region { item: material; radius: material.radius }
// and only while material.blurActive is true.
Item {
    id: root

    // 0 = opaque, 1 = most transparent. Defaults to the global appearance value.
    property real transparency: Appearance.effectiveTransparency
    property real radius: Tokens.radiusDock
    property bool shadowEnabled: true
    property bool highlightEnabled: true
    property bool borderEnabled: true

    // Host contract: request a blur region only when the surface is not opaque.
    readonly property bool blurActive: transparency > 0
    // Surfaces without text (the Dock shelf) may be more translucent than the A2 clamp allows: an explicit tint alpha
    // (0..1, -1 = from `transparency`) that applies only while the surface is not opaque (Reduce Transparency wins).
    property real tintAlphaOverride: -1
    // Glass class (ADR-0024 section 2): "menu", "notification", "controls", "apps", "gallery" or "widgets" take the class tint, raised to keep
    // the text legible over the backdrop the shell knows for this output (Appearance.glassAlpha); "" keeps the one material
    // tint (Appearance.tintAlpha).
    property string glassClass: ""
    // The tint colour (a host that adapts its tone to the backdrop sets it: the menu bar's band, Appearance.glassBand).
    property color tintColor: Appearance.colors.materialTint
    // The output this surface is shown on (the Screen attached property of its window).
    readonly property string screenName: Screen.name
    // Where the surface lies on that output (output px), for the backdrop under it (G-3 per surface, Appearance.glassAlpha):
    // a host whose window does not cover the output, or whose surface moves without moving itself (a card in a list), sets
    // the area to judge; empty: measured here when the window covers the output (its coordinates are the output's), unknown
    // otherwise (the whole output's range).
    property rect backdropRect: Qt.rect(0, 0, 0, 0)
    property rect measuredRect: Qt.rect(0, 0, 0, 0)
    readonly property rect glassRect: backdropRect.width > 0 ? backdropRect : measuredRect

    // Not while the host gives the area (backdropRect): a surface whose size animates (the Search panel) then costs nothing per
    // frame here. A host that moves a Material by moving an ancestor calls this when the motion ends, or gives backdropRect.
    function measureRect(): void {
        if (root.backdropRect.width > 0)
            return;
        const w = root.Window.window;
        if (!w || !root.visible || w.width < Screen.width || w.height < Screen.height || root.width <= 0) {
            root.measuredRect = Qt.rect(0, 0, 0, 0);
            return;
        }
        const p = root.mapToItem(null, 0, 0);
        root.measuredRect = Qt.rect(p.x, p.y, root.width, root.height);
    }

    onVisibleChanged: Qt.callLater(root.measureRect)
    onXChanged: Qt.callLater(root.measureRect)
    onYChanged: Qt.callLater(root.measureRect)
    onWidthChanged: Qt.callLater(root.measureRect)
    onHeightChanged: Qt.callLater(root.measureRect)
    Component.onCompleted: Qt.callLater(root.measureRect)
    // Rims (default: the material tokens): the inner specular rim (highlight) and the outer edge (border), each one device
    // pixel wide at every scale. The outer edge is dark in both appearances, the inner rim light.
    property real highlightOpacity: Appearance.dark ? Tokens.materialHighlightOpacity : Tokens.materialHighlightOpacityLight
    // Increase Contrast raises both edges (material.edgeOpacityDark and material.borderOpacity; the dark one by ADR-0039 step 22).
    property real borderOpacity: Appearance.dark ? Math.max(Tokens.materialEdgeOpacityDark, Tokens.materialBorderOpacity) : Tokens.materialBorderOpacity
    property color borderColor: Appearance.dark ? Appearance.colors.shadow : Appearance.colors.materialBorder
    readonly property real hairline: 1 / Math.max(1, Screen.devicePixelRatio)
    readonly property real baseTintAlpha: tintAlphaOverride >= 0 && blurActive ? tintAlphaOverride : (glassClass !== "" ? Appearance.glassAlpha(glassClass, transparency, screenName, glassRect) : Appearance.tintAlpha(transparency))
    // Increase Contrast frosts every glass surface (ADR-0024 G-8); Reduce Transparency has already made it opaque.
    readonly property real tintAlpha: Appearance.frosted(baseTintAlpha)
    // The tint as drawn: what a piece of the same glass outside the shape (a menu's or a tooltip's tail) fills with.
    readonly property color fillColor: Appearance.withAlpha(root.tintColor, root.tintAlpha)
    // The host window needs this much room around the shape for the shadow.
    readonly property int shadowMargin: Tokens.shadowBlur + Tokens.shadowOffsetY

    default property alias content: contentItem.data

    // Diffused shadow outside the shape, never under the glass: one ShaderEffect over the margin box (shaders/shadow.frag:
    // RectangularShadow's falloff with the shape cut out). No layer: two FBOs and a MultiEffect pass per surface did this
    // before, reallocated on every frame of a size animation (the Search panel's height, audit B-03).
    ShaderEffect {
        id: shadow
        visible: root.shadowEnabled && root.width > 0 && root.height > 0
        x: -root.shadowMargin
        y: -root.shadowMargin
        width: root.width + 2 * root.shadowMargin
        height: root.height + 2 * root.shadowMargin
        // Uniforms (names match shaders/shadow.frag). The shadow's box, radius and falloff are RectangularShadow's for this
        // blur (qquickrectangularshadow.cpp, antialiased, no spread), so the look is the one of the layers it replaces.
        readonly property real b: Tokens.shadowBlur
        readonly property color color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.shadowOpacity * (0.35 + 0.65 * root.tintAlpha))
        readonly property size boxSize: Qt.size(shadow.width, shadow.height)
        readonly property rect shapeRect: Qt.rect(root.shadowMargin, root.shadowMargin, root.width, root.height)
        readonly property real shapeRadius: Math.max(0, Math.min(root.radius, root.width / 2, root.height / 2))
        readonly property point shadowCentre: Qt.point(root.shadowMargin + root.width / 2, root.shadowMargin + Tokens.shadowOffsetY + root.height / 2)
        readonly property size shadowHalf: Qt.size(root.width / 2 - 0.8 * shadow.b - 1, root.height / 2 - 0.8 * shadow.b - 1)
        readonly property real shadowRadius: Math.min(Math.max(0, root.radius - 0.75 * shadow.b), Math.min(root.width, root.height) / 2 - 0.75 * shadow.b)
        readonly property real shadowBlur: 2.1 * shadow.b + 1
        readonly property rect clipRect: Qt.rect(root.shadowMargin - shadow.b, root.shadowMargin + Tokens.shadowOffsetY - shadow.b, root.width + 2 * shadow.b, root.height + 2 * shadow.b)
        fragmentShader: Qt.resolvedUrl("shaders/shadow.frag.qsb")
    }

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: root.fillColor
    }

    // Inner specular rim: one device pixel inside the edge, half strength all round and stronger toward the light, the top
    // left (ADR-0024 section 2.5, ADR-0039 step 22): full strength round the top-left corner, fading back to half along the
    // straight parts of the top and left edges.
    Rectangle {
        id: rim
        visible: root.highlightEnabled
        anchors.fill: parent
        anchors.margins: root.hairline
        radius: Math.max(0, root.radius - root.hairline)
        color: "transparent"
        border.width: root.hairline
        border.color: Appearance.withAlpha(Appearance.colors.materialHighlight, root.highlightOpacity / 2)
    }

    Item {
        id: lightCorner
        visible: root.highlightEnabled
        width: Math.min(root.radius, root.width / 2)
        height: Math.min(root.radius, root.height / 2)
        clip: true

        Rectangle {
            x: rim.x
            y: rim.y
            width: rim.width
            height: rim.height
            radius: rim.radius
            color: "transparent"
            border.width: root.hairline
            border.color: Appearance.withAlpha(Appearance.colors.materialHighlight, root.highlightOpacity)
        }
    }

    Rectangle {
        id: topLight
        visible: root.highlightEnabled
        x: lightCorner.width
        y: root.hairline
        width: Math.max(0, root.width - 2 * lightCorner.width)
        height: root.hairline
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop {
                position: 0
                color: Appearance.withAlpha(Appearance.colors.materialHighlight, root.highlightOpacity)
            }
            GradientStop {
                position: 1
                color: Appearance.withAlpha(Appearance.colors.materialHighlight, 0)
            }
        }
    }

    Rectangle {
        id: leftLight
        visible: root.highlightEnabled
        x: root.hairline
        y: lightCorner.height
        width: root.hairline
        height: Math.max(0, root.height - 2 * lightCorner.height)
        gradient: Gradient {
            GradientStop {
                position: 0
                color: Appearance.withAlpha(Appearance.colors.materialHighlight, root.highlightOpacity)
            }
            GradientStop {
                position: 1
                color: Appearance.withAlpha(Appearance.colors.materialHighlight, 0)
            }
        }
    }

    // Outer edge: one device pixel.
    Rectangle {
        visible: root.borderEnabled
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        border.width: root.hairline
        border.color: Appearance.withAlpha(root.borderColor, root.borderOpacity)
    }

    Item {
        id: contentItem
        anchors.fill: parent
    }
}
