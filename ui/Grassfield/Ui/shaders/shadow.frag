#version 440
// The shadow of a glass surface (Material, ADR-0024): a diffused shadow outside the shape, never under it.
// Build: scripts/dev/build-shaders.sh (qsb) -> shadow.frag.qsb. docs/specs/ui.md "Material shadow".
//
// One pass over the margin box (the shape plus the shadow's reach on every side), no offscreen layer: Qt's RectangularShadow
// (its shader and the constants of qquickrectangularshadow.cpp, which Material computes into the uniforms: a rounded box
// shrunk by 1.8 blur + 1, a squared smoothstep over 2.1 blur + 1, the radius reduced by 0.75 blur, drawn inside the shape
// grown by the blur) times the coverage of the shape's outside, so the shape is cut out of the shadow with an antialiased
// edge. Before this, two layers the size of the margin box and a MultiEffect inverted mask did the same: two FBOs and a pass
// per surface, reallocated on every frame of a size animation (audit B-03).

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 color;          // the shadow colour (premultiplied by Qt)
    vec2 boxSize;        // the effect item's size: the margin box, in item pixels
    vec4 shapeRect;      // the glass shape in the margin box (x, y, width, height)
    float shapeRadius;   // its corner radius (clamped to half the shorter side, as a Rectangle does)
    vec2 shadowCentre;   // centre of the shadow's rounded box (the shape's, moved by the offset)
    vec2 shadowHalf;     // its half size
    float shadowRadius;  // its corner radius
    float shadowBlur;    // the width of its falloff
    vec4 clipRect;       // where RectangularShadow draws: the moved shape grown by the blur
};

// Signed distance of p to a rounded box centred on the origin (half size h, corner radius r): RectangularShadow's.
float roundedBox(vec2 p, vec2 h, float r)
{
    return length(max(abs(p) - h + vec2(r), vec2(0.0))) - r;
}

void main()
{
    vec2 p = qt_TexCoord0 * boxSize;
    float a = 1.0 - smoothstep(0.0, shadowBlur, roundedBox(p - shadowCentre, shadowHalf, shadowRadius));
    vec2 c = step(clipRect.xy, p) * step(p, clipRect.xy + clipRect.zw);
    // The shape's outside, antialiased over one device pixel (fwidth: the distance's change per pixel at any scale).
    float s = roundedBox(p - (shapeRect.xy + 0.5 * shapeRect.zw), 0.5 * shapeRect.zw, shapeRadius);
    float outside = clamp(0.5 + s / max(fwidth(s), 1e-4), 0.0, 1.0);
    fragColor = color * (qt_Opacity * a * a * c.x * c.y * outside);
}
