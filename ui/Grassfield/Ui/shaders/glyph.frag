#version 440
// A symbolic glyph in one colour (Icon): the branding SVGs are black shapes; each pixel takes the ink at the glyph's coverage.
// Build: scripts/dev/build-shaders.sh (qsb) -> glyph.frag.qsb. docs/specs/ui.md "Symbolic glyphs".
//
// The effect samples the Image's own texture (its texture provider): no offscreen pass per icon. A MultiEffect did this before
// (brightness 1 lifts black to white, colorization 1 tints it), and with the Image's PreserveAspectFit it wrapped the Image in
// a ShaderEffectSource: one FBO and one pass per icon, in a component the shell draws by the hundred (audit B-07). The
// result is the same: on premultiplied colour, brightness 1 makes every glyph pixel at least white at its coverage and the
// colorization takes the ink at that grey, so each pixel is the ink at the glyph's alpha.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 ink;            // the glyph's colour, opaque (its alpha is the item's opacity)
};

layout(binding = 1) uniform sampler2D source;

void main()
{
    fragColor = vec4(ink.rgb, 1.0) * (texture(source, qt_TexCoord0).a * qt_Opacity);
}
