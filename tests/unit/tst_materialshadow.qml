pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtTest
import Grassfield.Ui

// Material's shadow without layers (audit B-03): a Material used to draw its shadow as two layered items the size of the
// margin box (RectangularShadow, a black cut-out) combined by a MultiEffect inverted mask, two FBOs and a pass per surface,
// reallocated on every frame of a size animation (the Search panel's height). It is one ShaderEffect now (shaders/shadow.frag).
// - no item under a Material enables a layer, and no MultiEffect or ShaderEffectSource is left (any scene graph);
// - the shader's pixels match the old composition outside the shape, and nothing is drawn under the glass (GPU scene graph
//   only: the software renderer of the offscreen platform does not run ShaderEffect; under Xvfb with Mesa it runs).
TestCase {
    id: tc

    name: "MaterialShadow"
    width: 480
    height: 260
    visible: true
    when: windowShown

    Rectangle {
        id: board
        width: 480
        height: 260
        color: "white"

        // The new Material: the shape's own fill is transparent so the comparison reads the shadow alone outside it.
        Material {
            id: glass
            x: 40
            y: 40
            width: tc.w
            height: tc.h
            radius: tc.r
            transparency: tc.clear ? 1 : 0
            tintAlphaOverride: tc.clear ? 0 : -1
            highlightEnabled: false
            borderEnabled: false
        }

        // The old composition (Material.qml before B-03), kept here as the reference of the look.
        Item {
            id: reference
            x: 280
            y: 40
            width: tc.w
            height: tc.h
            readonly property real margin: Tokens.shadowBlur + Tokens.shadowOffsetY

            Item {
                id: refSource
                visible: false
                layer.enabled: true
                x: -reference.margin
                y: -reference.margin
                width: reference.width + 2 * reference.margin
                height: reference.height + 2 * reference.margin

                RectangularShadow {
                    x: reference.margin
                    y: reference.margin
                    width: reference.width
                    height: reference.height
                    radius: tc.r
                    blur: Tokens.shadowBlur
                    offset: Qt.vector2d(0, Tokens.shadowOffsetY)
                    color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.shadowOpacity * (0.35 + 0.65 * glass.tintAlpha))
                }
            }

            Item {
                id: refCut
                visible: false
                layer.enabled: true
                x: refSource.x
                y: refSource.y
                width: refSource.width
                height: refSource.height

                Rectangle {
                    x: reference.margin
                    y: reference.margin
                    width: reference.width
                    height: reference.height
                    radius: tc.r
                    color: "black"
                }
            }

            MultiEffect {
                x: refSource.x
                y: refSource.y
                width: refSource.width
                height: refSource.height
                source: refSource
                autoPaddingEnabled: false
                maskEnabled: true
                maskSource: refCut
                maskInverted: true
            }
        }
    }

    property real w: 160
    property real h: 120
    property real r: 20
    property bool clear: true

    function walk(item, out) {
        for (const c of item.children) {
            out.push(c);
            walk(c, out);
        }
        return out;
    }

    function test_noLayers() {
        const all = walk(glass, []);
        let effects = 0;
        for (const it of all) {
            verify(!it.layer.enabled, "no layer under a Material: " + it);
            const t = String(it);
            verify(t.indexOf("MultiEffect") < 0 && t.indexOf("ShaderEffectSource") < 0, "no MultiEffect or ShaderEffectSource: " + t);
            if (t.indexOf("ShaderEffect") >= 0) {
                effects++;
                verify(String(it.fragmentShader).indexOf("shaders/shadow.frag.qsb") >= 0, "the shadow shader");
                compare(it.width, glass.width + 2 * glass.shadowMargin, "covers the margin box");
            }
        }
        compare(effects, 1, "one effect for the shadow");
    }

    function test_noEffectWithoutShadow() {
        glass.shadowEnabled = false;
        const all = walk(glass, []);
        for (const it of all) {
            if (String(it).indexOf("ShaderEffect") >= 0)
                verify(!it.visible, "no shadow drawn when disabled");
        }
        glass.shadowEnabled = true;
    }

    function luma(img, x, y) {
        const c = Qt.color(img.pixel(x, y));
        return (c.r + c.g + c.b) / 3;
    }

    function boxDistance(px, py, hx, hy, r) {
        const qx = Math.max(Math.abs(px) - hx + r, 0);
        const qy = Math.max(Math.abs(py) - hy + r, 0);
        return Math.sqrt(qx * qx + qy * qy) - r;
    }

    function test_matchesTheOldComposition_data() {
        return [
            {tag: "clear glass", w: 160, h: 120, r: 20, clear: true},
            {tag: "opaque glass (darkest shadow)", w: 160, h: 120, r: 20, clear: false},
            {tag: "radius above half the side", w: 30, h: 44, r: 20, clear: false},
            {tag: "square corners", w: 120, h: 60, r: 0, clear: true}
        ];
    }

    function test_matchesTheOldComposition(row) {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph (ShaderEffect does not run on the software renderer): run under Xvfb with QT_QPA_PLATFORM=xcb");
        tc.w = row.w;
        tc.h = row.h;
        tc.r = row.r;
        tc.clear = row.clear;
        waitForRendering(board);
        wait(50);
        const img = grabImage(board);
        const m = glass.shadowMargin;
        const rr = Math.min(row.r, row.w / 2, row.h / 2);
        let worst = 0;
        let darkest = 1;
        let samples = 0;
        for (let y = 40 - m; y < 40 + row.h + m; y++) {
            for (let x = 40 - m; x < 40 + row.w + m; x++) {
                // Distance to the shape (rounded box): under the glass, on its antialiased edge, or outside it.
                const d = boxDistance(x + 0.5 - 40 - row.w / 2, y + 0.5 - 40 - row.h / 2, row.w / 2, row.h / 2, rr);
                const a = luma(img, x, y);
                if (d < -1.5) {
                    // Under clear glass: nothing (the fill is transparent here, the board is white).
                    if (row.clear)
                        verify(a > 0.995, "no shadow under the glass at " + x + "," + y + ": " + a);
                    continue;
                }
                if (d < 1.5)
                    continue;
                const b = luma(img, x + 240, y);
                worst = Math.max(worst, Math.abs(a - b));
                darkest = Math.min(darkest, a);
                samples++;
            }
        }
        verify(samples > 500);
        verify(darkest < 0.97, "a shadow is drawn: darkest " + darkest);
        verify(worst <= 2 / 255, "the look of the old composition, worst difference " + Math.round(worst * 255) + "/255");
    }
}
