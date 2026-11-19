pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtTest
import Grassfield.Ui

// Symbolic glyphs without an offscreen pass per icon (audit B-07): Icon recoloured its hidden Image with a MultiEffect, which
// wraps a PreserveAspectFit Image in its own ShaderEffectSource (one FBO and one unbatched draw per icon, three per notification
// card). It is one ShaderEffect sampling the Image's texture now (shaders/glyph.frag).
// - no MultiEffect, ShaderEffectSource or layer under an Icon whose shader works (any scene graph);
// - the shader's pixels are the MultiEffect's (its colour, its coverage, the colour's alpha as opacity, a non-square glyph keeps
//   its aspect), and a missing shader falls back to the MultiEffect (GPU scene graph only: the software renderer of the
//   offscreen platform runs no ShaderEffect; under Xvfb with Mesa it does).
TestCase {
    id: tc

    name: "GlyphIcon"
    width: 400
    height: 200
    visible: true
    when: windowShown

    property color ink: "#d02060"
    property int side: 48

    Rectangle {
        id: board
        width: 400
        height: 200
        color: "white"

        Icon {
            id: icon
            x: 20
            y: 20
            name: "close-glyph"
            size: tc.side
            color: tc.ink
        }

        // The former rendering (Icon.qml before B-07), the reference.
        Item {
            x: 220
            y: 20
            width: tc.side
            height: tc.side

            Image {
                id: refGlyph
                anchors.fill: parent
                source: icon.directory + icon.name + ".svg"
                sourceSize: Qt.size(tc.side * 2, tc.side * 2)
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
                visible: false
            }

            MultiEffect {
                anchors.fill: parent
                source: refGlyph
                autoPaddingEnabled: false
                brightness: 1.0
                colorization: 1.0
                colorizationColor: Qt.rgba(tc.ink.r, tc.ink.g, tc.ink.b, 1)
                opacity: tc.ink.a
            }
        }

        Icon {
            id: broken
            x: 20
            y: 120
            name: "close-glyph"
            size: 48
            color: "black"
            shaderUrl: Qt.resolvedUrl("missing/glyph.frag.qsb")
        }
    }

    function walk(item, out) {
        for (const c of item.children) {
            out.push(c);
            walk(c, out);
        }
        return out;
    }

    function test_noOffscreenPass() {
        tryVerify(() => icon.children.length > 0);
        let effects = 0;
        for (const it of walk(icon, [])) {
            const t = String(it);
            verify(!it.layer.enabled, "no layer: " + t);
            verify(t.indexOf("MultiEffect") < 0 && t.indexOf("ShaderEffectSource") < 0, "no MultiEffect or ShaderEffectSource: " + t);
            if (t.indexOf("ShaderEffect") >= 0) {
                effects++;
                verify(String(it.fragmentShader).indexOf("shaders/glyph.frag.qsb") >= 0);
            }
        }
        compare(effects, 1, "one effect per icon");
    }

    function luma(img, x, y) {
        const c = Qt.color(img.pixel(x, y));
        return [c.r, c.g, c.b];
    }

    function test_matchesTheMultiEffect_data() {
        return [
            {tag: "opaque ink, 48", ink: "#d02060", side: 48},
            {tag: "translucent ink, 16", ink: "#802080d0", side: 16},
            {tag: "black, 24", ink: "#000000", side: 24}
        ];
    }

    function test_matchesTheMultiEffect(row) {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph (ShaderEffect does not run on the software renderer): run under Xvfb with QT_QPA_PLATFORM=xcb");
        tc.ink = row.ink;
        tc.side = row.side;
        waitForRendering(board);
        wait(100);
        const img = grabImage(board);
        let worst = 0;
        let inked = 0;
        for (let y = 20; y < 20 + row.side; y++) {
            for (let x = 20; x < 20 + row.side; x++) {
                const a = luma(img, x, y);
                const b = luma(img, x + 200, y);
                for (let k = 0; k < 3; k++)
                    worst = Math.max(worst, Math.abs(a[k] - b[k]));
                if (a[0] + a[1] + a[2] < 2.9)
                    inked++;
            }
        }
        verify(inked > row.side, "the glyph is drawn: " + inked + " inked pixels");
        verify(worst <= 3 / 255, "the MultiEffect's pixels, worst difference " + Math.round(worst * 255) + "/255");
    }

    function test_missingShaderFallsBack() {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph: the software renderer leaves a ShaderEffect uncompiled");
        waitForRendering(board);
        tryVerify(() => walk(broken, []).some(it => String(it.fragmentShader).indexOf("missing/glyph.frag.qsb") >= 0 && it.status === ShaderEffect.Error), 2000, "the missing shader is an error");
        tryVerify(() => walk(broken, []).some(it => String(it).indexOf("MultiEffect") >= 0), 2000, "the MultiEffect stands in");
        const img = grabImage(board);
        let inked = 0;
        for (let y = 120; y < 168; y++) {
            for (let x = 20; x < 68; x++) {
                if (Qt.color(img.pixel(x, y)).r < 0.5)
                    inked++;
            }
        }
        verify(inked > 48, "the fallback draws the glyph: " + inked);
    }
}
