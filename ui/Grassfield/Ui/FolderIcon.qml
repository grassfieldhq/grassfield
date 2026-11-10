pragma ComponentBehavior: Bound
import QtQuick

// A folder icon: a TintedIcon (icon appearance mode, unchanged) recoloured with the folder colour, plus an optional
// symbol or emoji on the body of the folder (macOS 26, Customize Folder). The folder colour is the folder's own
// (`folderColor`, "" = none) else the global `icons.folderColor`; "theme" keeps the theme's colour and then no layer or
// effect exists (no extra cost, no change for folders without a colour). The colour step runs after the mode step.
Item {
    id: root

    property url source: ""
    property int size: Tokens.dockIconSize
    property real oversample: 2
    // The folder's own colour setting ("theme", "accent", "#rrggbb"; "" = follow the global setting) and its symbol.
    property string folderColor: ""
    property string folderGlyph: ""
    // Overridable for previews; the global setting otherwise.
    property string globalColor: Appearance.folderColorSetting
    property color globalTint: Appearance.folderTint
    property alias status: icon.status
    property alias asynchronous: icon.asynchronous
    property alias mode: icon.mode
    property alias tint: icon.tint
    property alias darkAppearance: icon.darkAppearance
    property alias overWallpaper: icon.overWallpaper
    property alias overAccent: icon.overAccent

    readonly property string setting: FolderStyle.effectiveColor(root.folderColor, root.globalColor)
    readonly property bool recolored: FolderStyle.recolors(root.setting)
    // The symbol as kept by the shared rule (one grapheme cluster, no control or bidi characters).
    readonly property string glyph: FolderStyle.normalizeGlyph(root.folderGlyph)
    readonly property bool hasGlyph: root.glyph !== ""
    readonly property bool glyphIsEmoji: FolderStyle.isEmoji(root.glyph)
    // The appearance the icon is drawn for (over an accent fill: the polarity opposite to the fill).
    readonly property bool inkDark: icon.inkDark
    readonly property string modeName: icon.effectiveMode
    // The look the shader gives the plate (IconModes.overWallpaperLook): the folder model must repeat it exactly (A2 test_folderModelMatchesTheShader).
    readonly property bool wallLook: IconModes.overWallpaperLook(IconModes.effect(root.modeName, root.tint).index, root.overWallpaper, Appearance.effectiveTransparency, root.inkDark, root.solidMaterial, 0, Tokens)
    // The plate under the symbol (FolderPlate): the raw icon's pixels under it are read once per icon file and size bucket
    // (never per colour), the plate of this icon's mode, colour and appearance is computed from them. A plain symbol is
    // shaded against it. undefined until read, null when it could not be (the estimate of FolderStyle serves, and serves
    // until then). An emoji is opaque and in its own colours: it needs no plate.
    readonly property bool needsPlate: root.hasGlyph && !root.glyphIsEmoji
    readonly property string rawKey: FolderPlate.rawKeyOf(root.source, root.size)
    readonly property var plate: root.needsPlate ? FolderPlate.plateOf(root.rawKey, root.modeName, root.modeName === "tinted" ? String(root.tint) : "",
                                                                       root.recolored ? String(root.folderTint) : "", root.inkDark || root.wallLook, root.wallLook) : undefined
    // The engraved shade of the plate's colour (opaque).
    readonly property color glyphColor: FolderStyle.glyphShade(root.recolored, root.folderTint, root.modeName, root.tint, Tokens, root.plate, root.inkDark || root.wallLook, root.wallLook)
    // Its own hex colour, else the global colour (which is the accent for "accent").
    readonly property color folderTint: FolderStyle.colorOf(root.setting, Appearance.colors.accent)

    // The icon sits on a solid window material (see TintedIcon.solidMaterial).
    property bool solidMaterial: false
    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    TintedIcon {
        id: icon
        objectName: "icon"
        anchors.fill: parent
        source: root.source
        size: root.size
        oversample: root.oversample
        // Default mode (no effect item) and a failed shader: the folder colour is a layer over the plain icon. In an icon mode the
        // shader recolours the artwork itself (TintedIcon.recolor), so that the system plate is not recoloured.
        solidMaterial: root.solidMaterial
        recolor: root.recolored
        recolorTint: root.folderTint
        layer.enabled: root.recolored && (root.modeName === "default" || icon.effectFailed)
        layer.smooth: true
        layer.effect: FolderEffect {
            tint: root.folderTint
        }
    }

    // ---- Plate read: the raw icon's pixels under the symbol, by one icon at a time, never from the visible icon ----
    function measure() {
        if (!root.needsPlate || root.plate !== undefined || root.width <= 0 || root.height <= 0 || !root.visible || root.Window.window === null
            || String(root.source) === "" || probe.active)
            return;
        const key = root.rawKey;
        if (!FolderPlate.claim(key))
            return;
        probe.key = key;
        probe.bucket = FolderPlate.bucketOf(root.size);
        probe.url = String(root.source);
        probe.active = true;
    }

    function scheduleMeasure() {
        settle.restart();
    }

    // Changes arrive in bursts (key parts, window): look once after them, in a turn of the event loop of its own.
    Timer {
        id: settle

        interval: 0
        onTriggered: root.measure()
    }

    onNeedsPlateChanged: root.scheduleMeasure()
    onRawKeyChanged: root.scheduleMeasure()
    onVisibleChanged: root.scheduleMeasure()
    Component.onCompleted: root.scheduleMeasure()
    Component.onDestruction: {
        if (probe.key !== "")
            FolderPlate.release(probe.key);
    }

    Connections {
        target: root.Window

        function onWindowChanged() {
            root.scheduleMeasure();
        }
    }

    // A claim released by another icon (it went away) or samples stored: look again.
    Connections {
        target: FolderPlate

        function onRevisionChanged() {
            if (root.needsPlate && root.plate === undefined)
                root.scheduleMeasure();
        }
    }

    Loader {
        id: probe

        property string key: ""
        property string url: ""
        property int bucket: 0

        function finish(samples) {
            const k = probe.key;
            probe.key = "";
            probe.active = false;
            if (k !== "")
                FolderPlate.store(k, samples);
        }

        active: false

        sourceComponent: Canvas {
            id: canvas

            function read() {
                if (probe.key === "")
                    return;
                const ctx = canvas.getContext("2d");
                // The image's own pixels (createImageData of the loaded url, never drawn: drawImage scales an image://icon pixmap by the
                // output's ratio); only the box under the symbol, as fractions of the image, is sampled.
                const img = ctx.createImageData(probe.url);
                const box = FolderStyle.glyphBox(1, Tokens);
                probe.finish(FolderStyle.sampleBox(img.data, img.width, img.height, box[0] * img.width, box[1] * img.height, box[2] * img.width, box[3] * img.height, Tokens.folderIconPlateSamples));
            }

            width: probe.bucket
            height: probe.bucket
            opacity: 0
            renderTarget: Canvas.Image
            renderStrategy: Canvas.Immediate
            onImageLoaded: canvas.read()
            onAvailableChanged: {
                if (canvas.available && probe.key !== "" && canvas.isImageLoaded(probe.url))
                    canvas.read();
            }
            Component.onCompleted: canvas.loadImage(probe.url)

            Timer {
                interval: 3000
                running: true
                onTriggered: probe.finish(null)
            }
        }
    }

    // The symbol is drawn over the effect, clipped to the icon (a hostile value cannot draw outside it). Emoji keep their
    // own colours and are opaque (their colour glyphs ignore `color`; a text-presentation fallback uses the shade); a
    // plain symbol is an engraved shade of the plate's colour (A2: >= 3:1 against the plate, FolderStyle.glyphShade) with a
    // light edge under it. It is drawn at once, with the estimate of the plate, and settles on the measured plate with a
    // cross-fade of one motion token (no pop).
    Item {
        id: glyphBox

        objectName: "glyphBox"
        anchors.fill: parent
        // In an icon mode the folder shrinks to sit on the system plate (the shader's sysGlyphScale):
        // the symbol follows it. Not when the shader failed and the plain icon is drawn.
        scale: root.modeName !== "default" && !icon.effectFailed ? icon.artScale : 1
        transformOrigin: Item.Center
        clip: true
        visible: root.hasGlyph

        Text {
            objectName: "glyphHighlight"
            visible: !root.glyphIsEmoji
            x: glyphText.x
            y: glyphText.y + Math.max(1, Math.round(root.size * Tokens.folderIconGlyphHighlightOffset))
            width: glyphText.width
            horizontalAlignment: Text.AlignHCenter
            text: glyphText.text
            textFormat: Text.PlainText
            color: Tokens.folderIconGlyphHighlight
            font.pixelSize: glyphText.font.pixelSize
        }

        Text {
            id: glyphText

            objectName: "glyph"
            y: root.height * Tokens.folderIconGlyphCenterY - height / 2
            width: root.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            maximumLineCount: 1
            text: root.glyph
            textFormat: Text.PlainText
            color: root.glyphColor
            font.pixelSize: Math.max(1, Math.round(root.size * Tokens.folderIconGlyphScale))

            Behavior on color {
                ColorAnimation {
                    duration: Appearance.duration(Tokens.motionNormal)
                }
            }
        }
    }
}
