import QtQuick

// The icon appearance effect of one mode over an item (an Image or a layered Item): one custom fragment shader
// (shaders/icon.frag, built to icon.frag.qsb by scripts/dev/build-shaders.sh), a single pass: the icon scaled onto a system
// plate (graphite, glass or tinted) and recoloured by a fixed transform per mode, no analysis of the icon. Used by
// TintedIcon and so by every icon surface and the mode previews in Settings.
// The numbers are the `iconMode` token group; the algorithm and its limits are in docs/specs/ui.md, "Icon shader".
ShaderEffect {
    id: root

    // The item whose texture is drawn (the effect takes its own texture of it: a hidden item still renders).
    property Item source: null
    property string mode: "default"
    property color tint: Appearance.iconTint
    property bool darkAppearance: Appearance.dark
    // Drawn over the bare wallpaper (desktop icons): a look that holds on any wallpaper brightness.
    property bool wallpaper: false
    // Drawn over the accent fill of a selected row: 0 no, 1 a bright accent, 2 a dark one (the plate and the ink are the opposite of it).
    property real accentFill: 0
    // The folder colour step (FolderIcon): the artwork is recoloured in the shader, before the system plate is drawn,
    // so the plate keeps its look. Not used when "recolor" is false.
    property bool recolor: false
    property color recolorTint: "#000000"

    readonly property var params: IconModes.effect(root.mode, root.tint)

    // Shader uniforms (names match shaders/icon.frag).
    // The effect samples the Image's own texture (its texture provider, mipmapped by the Image): no offscreen pass per icon. The
    // hidden Image still gets its texture, because an effect that uses an item as a source keeps it rendered.
    readonly property var iconTexture: root.source
    readonly property real dark: root.darkAppearance ? 1 : 0
    // Over the bare wallpaper (desktop icons); for Clear also over a material that lets so much of it through (transparency at its
    // end) that the icon is over the wallpaper: the look that holds on any wallpaper brightness.
    readonly property real overWallpaper: IconModes.overWallpaperLook(root.params.index, root.wallpaper, Appearance.effectiveTransparency, root.darkAppearance, root.solidMaterial, root.accentFill, Tokens) ? 1 : 0
    readonly property real clearPlateAlphaWallpaper: Tokens.iconModeClearPlateAlphaWallpaper
    readonly property real sysPlateInset: Tokens.iconModeSysPlateInset
    readonly property real sysPlateRadius: Tokens.iconModeSysPlateRadius
    // Scale of the artwork about the centre: the glyph scale (the icon sits on the plate), or for an icon that is already a tile the scale that
    // makes its own tile coincide with the plate (TintedIcon.artScale, IconTile.js).
    property real artScale: Tokens.iconModeSysGlyphScale
    readonly property real sysGlyphScale: root.artScale
    readonly property real darkPlateLuma: Tokens.iconModeDarkPlateLuma
    readonly property real darkArtSaturation: Tokens.iconModeDarkArtSaturation
    readonly property real darkArtScale: Tokens.iconModeDarkArtScale
    readonly property real darkArtLift: Tokens.iconModeDarkArtLift
    // The icon is its own rounded-square tile (own-tile rule, not over an accent fill): the maps keep the luminance of every pixel.
    property bool ownTile: false
    readonly property real tile: root.ownTile ? 1 : 0
    readonly property real tileDarkArtLift: Tokens.iconModeTileDarkArtLift
    readonly property real tileTintedPlateScaleLight: Tokens.iconModeTileTintedPlateScaleLight
    readonly property real tileClearPlateAlphaLight: Tokens.iconModeTileClearPlateAlphaLight
    readonly property real tileClearPlateLightLuma: Tokens.iconModeTileClearPlateLightLuma
    readonly property real clearPlateWallpaperLuma: Tokens.iconModeClearPlateWallpaperLuma
    readonly property real clearPlateLightLuma: Tokens.iconModeClearPlateLightLuma
    readonly property real clearPlateAlphaDark: Tokens.iconModeClearPlateAlphaDark
    readonly property real clearPlateAlphaLight: Tokens.iconModeClearPlateAlphaLight
    readonly property real clearInkDark: Tokens.iconModeClearInkDark
    readonly property real clearInkLight: Tokens.iconModeClearInkLight
    readonly property real clearBackdropDark: Tokens.iconModeClearBackdropDark
    readonly property real clearBackdropLight: Tokens.iconModeClearBackdropLight
    readonly property real clearBackdropMid: Tokens.iconModeClearBackdropMid
    readonly property real clearInkFloor: Tokens.iconModeClearInkFloor
    readonly property real clearPlateAlphaAccent: Tokens.iconModeClearPlateAlphaAccent
    readonly property real tintedPlateScale: Tokens.iconModeTintedPlateScale
    readonly property real tintedPlateMixLight: Tokens.iconModeTintedPlateMixLight
    readonly property real tintedRampLowDark: Tokens.iconModeTintedRampLowDark
    readonly property real tintedRampHighDark: Tokens.iconModeTintedRampHighDark
    readonly property real tintedRampLowLight: Tokens.iconModeTintedRampLowLight
    readonly property real tintedRampHighLight: Tokens.iconModeTintedRampHighLight
    // Tone of a tile icon (shaders/icon.frag, TILE TONE): which side of its pivot the pixels move to, by the pure rule IconModes.tileToneSide. Only for icons on a solid
    // window material (a window's own views, the A2 suite): the Dock and the other glass surfaces have a backdrop the pivots do not describe, so they get none.
    property bool solidMaterial: false
    readonly property real tileToneSide: root.solidMaterial ? IconModes.tileToneSide(root.darkAppearance, root.wallpaper, Appearance.effectiveTransparency, Tokens) : 0
    readonly property real tileTonePivot: root.tileToneSide < 0 ? Tokens.iconModeTileDarkenPivot : (root.darkAppearance ? (root.params.index === 1 ? Tokens.iconModeTileLiftPivotDark : Tokens.iconModeTileLiftPivot) : Tokens.iconModeTileLightLiftPivot)
    readonly property real tileToneExp: root.tileToneSide < 0 ? Tokens.iconModeTileDarkenExponent : (root.darkAppearance ? [0, Tokens.iconModeTileLiftExponentDark, Tokens.iconModeTileLiftExponentClear, Tokens.iconModeTileLiftExponentTinted][root.params.index] : Tokens.iconModeTileLightLiftExponent)
    readonly property real darkPlateLumaOnDarkAccent: Tokens.iconModeDarkPlateLumaOnDarkAccent
    readonly property color folderTint: Qt.rgba(root.recolorTint.r, root.recolorTint.g, root.recolorTint.b, root.recolor ? 1 : 0)
    readonly property real folderBrightness: Tokens.folderIconBrightness
    readonly property real folderContrast: Tokens.folderIconContrast
    readonly property real folderColorization: Tokens.folderIconColorization
    readonly property real folderSaturation: Tokens.folderIconSaturation
    // 1 dark, 2 clear, 3 tinted (`tint` is the colour uniform).
    readonly property real modeIndex: root.params.index

    // The compiled shader; overridable for tests of the failure path.
    property url shaderUrl: Qt.resolvedUrl("shaders/icon.frag.qsb")
    fragmentShader: root.shaderUrl
    // The shader failed to load or compile: the owner draws the plain icon instead.
    readonly property bool failed: root.status === ShaderEffect.Error
    onFailedChanged: {
        if (root.failed) {
            Appearance.iconShaderBroken = true;
            IconModes.warnOnce("icon shader failed to load, icons are drawn as they are: " + root.log);
        }
    }
    blending: true
}
