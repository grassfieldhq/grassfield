import QtQuick
import QtTest
import Grassfield.Ui

// A glyph colour's alpha fades the glyph (refinement batch 6 delta review; the effect is the glyph shader since audit B-07): MultiEffect read the alpha of its colorization
// colour as the tint's STRENGTH over the white-lifted glyph, which lightens a glyph on a dark window. Icon tints at alpha 1 and
// the alpha is the effect's opacity. The structure is asserted always; the pixels where the scene graph draws the effect (the
// software backend of an offscreen run does not draw it, so the pixel check then says so and is skipped).
TestCase {
    id: tc
    name: "IconAlpha"
    width: 120
    height: 60
    visible: true
    when: windowShown

    Rectangle {
        anchors.fill: parent
        color: "#1C1B18"

        Icon {
            id: full
            x: 10
            y: 10
            name: "gear"
            size: 32
            color: "#F8F5F0"
        }

        Icon {
            id: half
            x: 70
            y: 10
            name: "gear"
            size: 32
            color: Qt.rgba(0.97, 0.96, 0.94, 0.4)
        }
    }

    function effectOf(icon) {
        for (let i = 0; i < icon.children.length; i++) {
            // The glyph shader (shaders/glyph.frag, audit B-07): its `ink` is the tint.
            if (icon.children[i].ink !== undefined)
                return icon.children[i];
        }
        return null;
    }

    function test_theAlphaIsTheEffectsOpacityNotTheTintStrength() {
        const f = effectOf(full);
        const h = effectOf(half);
        verify(f !== null && h !== null, "the tint effect");
        compare(h.ink.a, 1, "the tint is opaque");
        fuzzyCompare(h.opacity, 0.4, 0.001);
        compare(f.opacity, 1);
    }

    function brightest(img, x0) {
        let best = 0;
        for (let y = 10; y < 42; y++) {
            for (let x = x0; x < x0 + 32; x++) {
                const c = img.pixel(x, y);
                best = Math.max(best, c.r);
            }
        }
        return best;
    }

    function test_aHalfAlphaGlyphIsDarkerThanTheFullOneOnADarkWindow() {
        wait(300);
        const img = grabImage(tc);
        const a = brightest(img, 10);
        const b = brightest(img, 70);
        if (a < 0.5) {
            skip("the scene graph of this run does not draw the effect (software backend)");
            return;
        }
        verify(b < a, "half alpha is darker: " + b + " against " + a);
    }
}
