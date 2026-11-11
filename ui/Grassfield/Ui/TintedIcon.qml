pragma ComponentBehavior: Bound
import QtQuick

// An application or file icon drawn in the user's icon appearance mode (ADR-0014): default (as is), dark, clear or
// tinted. Never used for symbolic UI glyphs (those are `Icon`). In `default` mode no effect item exists at all: the
// image is drawn directly (no offscreen pass, no cost). Other modes add one IconEffect (a fragment shader) over the image
// texture, only while the icon is visible.
Item {
    id: root

    // Image URL: a theme icon path, image://icon/<name> or a file URL.
    property url source: ""
    property int size: Tokens.dockIconSize
    // Overridable per use (previews); the settings value otherwise.
    property string mode: Appearance.iconMode
    property color tint: Appearance.iconTint
    // Drawn over the selection fill of a selected row (Force Quit, Files): the plate and the ink are then the opposite of the
    // fill (the row's text colour, `selectionText`, says whether the fill is bright or dark), not those of the appearance.
    property bool overAccent: false
    // Clear and Tinted draw differently on a light and a dark material.
    property bool darkAppearance: Appearance.dark
    // The selection fill is bright when its text is dark (Appearance.colors.selectionText).
    readonly property bool accentBright: Qt.color(Appearance.colors.selectionText).hslLightness < 0.5
    // What the effect draws for: the appearance, or over a bright accent fill the dark plates of a dark material.
    readonly property bool inkDark: root.overAccent ? root.accentBright : root.darkAppearance
    // Drawn over the bare wallpaper (desktop icons) rather than a window material.
    property bool overWallpaper: false
    // The icon sits on a solid window material (a window's own views): a tile icon then gets the tile tone (shaders/icon.frag). False for the Dock and other glass.
    property bool solidMaterial: false
    // The luminance of the glass surface under the icon, when known (IconEffect.surfaceLuma); -1 otherwise.
    property real surfaceLuma: -1
    // The folder colour (FolderIcon), applied by the effect to the artwork only; drawn by the owner's layer in default mode.
    property bool recolor: false
    property color recolorTint: "#000000"
    property alias status: image.status
    property alias asynchronous: image.asynchronous
    property alias paintedWidth: image.paintedWidth
    property alias paintedHeight: image.paintedHeight
    // Nominal edge: the image is decoded once at size x oversample, so a surface that scales the item (Dock
    // magnification) does not reload it. Decoded pixels per nominal pixel: hi-dpi and magnified tiles.
    // Decoded pixels per nominal pixel; 2 unless a call site decodes more for a larger magnification.
    readonly property real defaultOversample: 2
    property real oversample: root.defaultOversample
    // The compiled icon shader; if it fails to load the icon is drawn as it is (the default look), see effectFailed.
    property url shaderUrl: Qt.resolvedUrl("shaders/icon.frag.qsb")

    // The icon appearance modes apply from iconMode.minSize up; below it (16 px rows, menus) the Default artwork is drawn in every mode.
    readonly property bool modeActive: IconModes.normalizeMode(root.mode) !== "default" && root.size >= Tokens.iconModeMinSize
    // The mode that is drawn: the setting, or "default" below the minimum size.
    readonly property string effectiveMode: root.modeActive ? IconModes.normalizeMode(root.mode) : "default"
    // The effect item of an effect mode while the icon is shown, else null/false (tests, diagnostics).
    readonly property Item effectItem: effectLoader.item as Item
    readonly property bool effectActive: effectLoader.active
    // True while the plain image is what is drawn (default mode, or an effect mode whose shader failed).
    readonly property bool plainVisible: image.visible
    // The image only provides the effect's texture (at its decoded size) while an effect draws; when the shader failed it is
    // the icon itself again, at the item's size.
    readonly property bool textureOnly: root.modeActive && !root.effectFailed
    // The shader could not be loaded or compiled: the plain image is shown instead of an effect that draws nothing.
    readonly property bool effectFailed: root.modeActive && (Appearance.iconShaderBroken || (effectLoader.item !== null && (effectLoader.item as IconEffect).failed))

    // The own-tile rule (docs/specs/ui.md "Icon shader"): an icon that is already a rounded square filling its box is not put inside the system
    // plate again; the shape of the icon file is measured once (IconShape, a CPU test of the alpha mask) and the artwork scaled so that its own tile
    // coincides with the plate. Glyphs, folders and every other icon keep the glyph scale. Only in an effect mode (none in Default: no read at all).
    property bool detectTile: true
    readonly property bool shapeWanted: root.effectiveMode !== "default" && root.detectTile && !Appearance.iconShaderBroken
    readonly property string shapeKey: String(root.source)
    // undefined until the file is read, 0: not a tile, else the tile edge over the box.
    readonly property var tileSide: !root.shapeWanted ? undefined : (root.shapeKey === "" ? 0 : IconShape.sideOf(root.shapeKey))
    // False while the artwork is not drawn because its scale is not known yet (it fades in once, no icon jumps from one scale to the other).
    readonly property bool shapeKnown: !root.shapeWanted || root.tileSide !== undefined
    // The scale the artwork is drawn at in an effect mode.
    // Over an accent fill (a selected row) the icon keeps the system plate whatever its shape: the plate is what separates it from the fill.
    readonly property bool ownTile: root.tileSide !== undefined && root.tileSide > 0 && !root.overAccent
    readonly property real artScale: IconTile.artScale(root.ownTile ? root.tileSide : 0, Tokens)

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    // Default mode: the image fills the item. Effect modes: the image keeps a fixed size (the decoded size) and only
    // provides the texture, so the effect's texture never changes size while a surface scales the item (Dock
    // magnification); the effect quad is scaled by the GPU.
    Image {
        id: image
        width: root.textureOnly ? root.size * root.oversample : root.width
        height: root.textureOnly ? root.size * root.oversample : root.height
        source: root.source
        // A tile icon is decoded at the size it is drawn at (decoded pixels per drawn pixel = oversample, as in Default): the shader then reads
        // the mip level that holds one texel group per pixel and does not blur the artwork by resampling it at a fraction of a level (A2 rule I at 24 px).
        sourceSize: Qt.size(root.size * root.oversample * (root.textureOnly && root.ownTile ? root.artScale : 1), root.size * root.oversample * (root.textureOnly && root.ownTile ? root.artScale : 1))
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        // Hidden while the effect draws it: the image only provides the texture.
        visible: !root.modeActive || root.effectFailed
    }

    // Effect modes: one shader effect per icon that is shown. `root.visible` is the effective visibility, so an icon
    // hidden by its own `visible: false` or by a hidden ancestor (a type icon under a thumbnail, a closed panel)
    // creates no effect item and costs nothing.
    Loader {
        id: effectLoader
        anchors.fill: parent
        active: root.modeActive && root.visible && !Appearance.iconShaderBroken
        opacity: root.shapeKnown ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.duration(Tokens.motionFast)
            }
        }
        sourceComponent: IconEffect {
            source: image
            mode: root.mode
            tint: root.tint
            darkAppearance: root.inkDark
            wallpaper: root.overWallpaper
            solidMaterial: root.solidMaterial
            surfaceLuma: root.surfaceLuma
            accentFill: root.overAccent ? (root.accentBright ? 1 : 2) : 0
            recolor: root.recolor
            recolorTint: root.recolorTint
            artScale: root.artScale
            ownTile: root.ownTile
            shaderUrl: root.shaderUrl
        }
    }

    // ---- Shape read: the raw icon file's alpha mask, by a few icons at a time, never from the visible icon ----
    function measure() {
        if (!root.shapeWanted || root.tileSide !== undefined || root.width <= 0 || root.height <= 0 || !root.visible || root.Window.window === null || probe.active)
            return;
        const key = root.shapeKey;
        if (!IconShape.claim(key))
            return;
        probe.key = key;
        probe.active = true;
    }

    function scheduleMeasure() {
        settle.restart();
    }

    // Changes arrive in bursts (source, mode, window): look once after them, in a turn of the event loop of its own.
    Timer {
        id: settle

        interval: 0
        onTriggered: root.measure()
    }

    onShapeWantedChanged: root.scheduleMeasure()
    onShapeKeyChanged: root.scheduleMeasure()
    onVisibleChanged: root.scheduleMeasure()
    Component.onCompleted: root.scheduleMeasure()
    Component.onDestruction: {
        if (probe.key !== "")
            IconShape.release(probe.key);
    }

    Connections {
        target: root.Window

        function onWindowChanged() {
            root.scheduleMeasure();
        }
    }

    // A claim released by another icon, or a result stored (a file may be waiting for a free place): look again.
    Connections {
        target: IconShape

        function onRevisionChanged() {
            if (root.shapeWanted && root.tileSide === undefined)
                root.scheduleMeasure();
        }
    }

    Loader {
        id: probe

        property string key: ""

        function finish(side) {
            const k = probe.key;
            probe.key = "";
            probe.active = false;
            if (k !== "")
                IconShape.store(k, side);
        }

        active: false

        sourceComponent: Canvas {
            id: canvas

            function read() {
                if (probe.key === "")
                    return;
                const n = Tokens.iconModeOwnTileProbeSize;
                // The image's own pixels (createImageData of the loaded url), never drawn: drawImage scales an image://icon pixmap
                // by the output's ratio (half the box on a 1.25 output: every icon then looked "empty", not a tile, a pale plate
                // around a coloured tile on every Dock icon) and a Canvas keeps its picture at the window's ratio.
                probe.finish(IconTile.sideOfImageData(canvas.getContext("2d").createImageData(probe.key), n, Tokens));
            }

            width: Tokens.iconModeOwnTileProbeSize
            height: Tokens.iconModeOwnTileProbeSize
            opacity: 0
            renderTarget: Canvas.Image
            renderStrategy: Canvas.Immediate
            onImageLoaded: canvas.read()
            onAvailableChanged: {
                if (canvas.available && probe.key !== "" && canvas.isImageLoaded(probe.key))
                    canvas.read();
            }
            Component.onCompleted: canvas.loadImage(probe.key)

            Timer {
                interval: Tokens.iconModeOwnTileTimeout
                running: true
                onTriggered: probe.finish(0)
            }
        }
    }
}
