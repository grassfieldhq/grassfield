pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects

// Themed symbolic icon: the branding SVGs are monochrome black and are recolored at runtime.
Item {
    id: root

    // File name without extension in branding/icons/symbolic, e.g. "wifi-3".
    property string name: ""
    property color color: Appearance.glyphTint(root)
    // The heavier variant (icons-bar/, stroke 2.4 against 1.75): the menu bar's status glyphs, which macOS draws solid.
    property bool heavy: false
    property int size: Tokens.menubarIconSize
    // Overridable so that an installed layout can point at its own icon directory.
    // `icons` is a symlink to branding/icons/symbolic in the repo and a real directory once installed.
    property url directory: Qt.resolvedUrl(root.heavy ? "icons-bar/" : "icons/")

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    Image {
        id: glyph
        anchors.fill: parent
        source: root.name !== "" ? root.directory + root.name + ".svg" : ""
        sourceSize: Qt.size(root.size * 2, root.size * 2)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        visible: false
    }

    // The glyph in its colour: one ShaderEffect sampling the Image's own texture (shaders/glyph.frag), no offscreen pass. A
    // MultiEffect did this before; with the Image's PreserveAspectFit it took a ShaderEffectSource, so one FBO and one more
    // pass per icon (audit B-07). The effect covers the painted image only, so the texture is not stretched.
    ShaderEffect {
        id: tinted
        x: (root.width - width) / 2
        y: (root.height - height) / 2
        width: glyph.paintedWidth
        height: glyph.paintedHeight
        visible: glyph.status === Image.Ready && !tinted.failed
        // Dev-only glyph mask (Appearance.devGlyphMode, tests/visual): a hidden marker colour hides the icon. Never true in
        // production. Otherwise the colour's alpha is the item's opacity (the ink itself is opaque).
        opacity: Appearance.devGlyphMode === "hidden" && Appearance.isGlyphMarker(root.color) ? 0 : root.color.a
        // Uniforms (names match shaders/glyph.frag).
        readonly property var source: glyph
        readonly property color ink: Qt.rgba(root.color.r, root.color.g, root.color.b, 1)
        fragmentShader: root.shaderUrl
        readonly property bool failed: tinted.status === ShaderEffect.Error
        onFailedChanged: {
            if (tinted.failed)
                console.warn("Icon: the glyph shader failed to load, glyphs are drawn by MultiEffect: " + tinted.log);
        }
    }

    // The compiled shader; overridable for tests of the failure path.
    property url shaderUrl: Qt.resolvedUrl("shaders/glyph.frag.qsb")

    // Only when the shader cannot run: the former MultiEffect (brightness lifts the black glyph to white, colorization tints it).
    Loader {
        anchors.fill: parent
        active: tinted.failed

        sourceComponent: MultiEffect {
            source: glyph
            autoPaddingEnabled: false
            brightness: 1.0
            colorization: 1.0
            colorizationColor: tinted.ink
            opacity: tinted.opacity
        }
    }
}
