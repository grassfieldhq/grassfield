#pragma once

#include "layers.h"

#include <QColor>
#include <QJsonArray>
#include <QPainterPath>
#include <QPointF>
#include <QPolygonF>
#include <QRect>
#include <QRectF>
#include <QString>
#include <QVector>

// The shape layers of the editor (slice B4; fields of layers.json version 1) and the geometry the editor does on them: building,
// hit testing, moving and resizing. All lengths are device pixels of the original picture (a capture at scale 1.25 has 1.25 times
// the pixels of the same window at scale 1: the tools make their default width from the display's scale, the file stores pixels).
//
//   every shape   "color"  "#rrggbb" or "#aarrggbb";  "width"  the stroke, kMinStrokeWidth to kMaxStrokeWidth
//   rectangle     "x" "y" "w" "h" (w and h are 0 or more),  "fill" (bool, default false)
//   ellipse       as rectangle: the ellipse inscribed in the box
//   line          "from" [x, y], "to" [x, y]
//   arrow         "from", "to", "style": "straight" | "curved" | "double",  "ctrl" [x, y] (curved: the control point of the
//                 quadratic curve; double: heads at both ends, straight)
//   pen           "color", "width", "points" [[x, y], ...] (2 to kMaxStrokePoints): the centre line, smoothed when drawn
//   highlighter   as pen: drawn flat-capped, its colour carries the alpha
//   text          "x" "y" the centre of the text, "text" (at most kMaxTextLength characters, lines split on \n), "size" (the
//                 font's pixel size), "color", "style": "plain" | "outlined" | "pill", "family", "rot" (quarter turns, clockwise)
//   counter       "x" "y" the centre of the disc, "size" its diameter, "color"; its number is its place among the counters
//                 (counterNumbers), never stored, so that deleting one renumbers the others
//   redact        "x" "y" "w" "h" (the box), "color" (the fill; its alpha is ignored: a redaction is opaque, black when the field does not read)
//   pixelate      the box, "block" (the block's side in device pixels, at least kMinPixelateBlock), "seed" (16 hex digits: the grid's offset
//                 and the per-block noise; drawn from the system's random source when the layer is made)
//   blur          the box, "radius" (the Gaussian's sigma in device pixels). Blur is for looks: it is NOT redaction (it can be undone).
//   spotlight     the box, "dim" (the alpha of the dark veil over everything outside the box)
//   The area of these four is the box rounded OUTWARD to whole device pixels (regionArea), never anti-aliased: no source pixel of the
//   border is left half-covered. Redact and Pixelate are the secure tools (redaction.h); a layer of theirs that does not read in some
//   field still hides (black, the default block, seed 0) rather than draw nothing.
// A layer whose fields do not read (missing, not finite, out of range, no valid colour) is neither drawn, hit nor selected.
namespace screenshot {

constexpr qreal kMaxCoordinate = 1.0e6;
constexpr qreal kMinStrokeWidth = 0.5;
constexpr qreal kMaxStrokeWidth = 1000;
constexpr int kMaxStrokePoints = 4000;
constexpr int kMaxTextLength = 2000;
constexpr qreal kMinTextSize = 4;
constexpr qreal kMaxTextSize = 1000;
// Pixelate: blocks are never smaller than this many device pixels (ADR-0066 D-9), nor larger than the cap.
constexpr int kMinPixelateBlock = 12;
constexpr int kMaxPixelateBlock = 512;
constexpr qreal kMinBlurRadius = 1;
constexpr qreal kMaxBlurRadius = 128;
constexpr qreal kMinSpotlightDim = 0.05;
constexpr qreal kMaxSpotlightDim = 0.95;

// What a new shape is drawn with.
struct ShapeStyle {
    QString color; // "#rrggbb" or "#aarrggbb"; an invalid colour makes shapes that draw nothing
    qreal width = 3;
    bool fill = false;
    QString arrow = QStringLiteral("straight");
    // Text and counters (slice B6): the size is in device pixels (the font's pixel size, the disc's diameter).
    QString textStyle = QStringLiteral("plain"); // "plain" | "outlined" | "pill"
    qreal textSize = 20;
    QString family = QStringLiteral("sans-serif");
    qreal counterSize = 28;
    // The highlighter (slice B5) is as wide as the pen's width times this, at this alpha.
    qreal highlightFactor = 4;
    qreal highlightOpacity = 0.4;
    // The region tools (slice B7). Redact's fill has a colour of its own ("#rrggbb": the tool's default is black); a pixelate block, a blur
    // sigma and a spotlight's veil are in device pixels / alpha; `seed` 0 draws a new one from the system's random source for each layer.
    QString redactColor = QStringLiteral("#000000");
    qreal pixelateBlock = 16;
    qreal blurRadius = 8;
    qreal spotlightDim = 0.55;
    quint64 seed = 0;
};

// The layer types the tools draw and edit (shapes, strokes, text and counters; a frame is no shape: framing.h).
bool isShapeType(const QString &type);
bool isStrokeType(const QString &type); // pen and highlighter
bool isTextType(const QString &type);
// The four tools that act on a box of the picture (slice B7): redact, pixelate, blur and spotlight.
bool isRegionType(const QString &type);
// What reads of a region layer: its area (the box rounded outward to whole pixels; empty when the box does not read or is empty).
QRect regionArea(const Layer &layer);
// A region layer over the box from `from` to `to` (either order); an unknown type gives id 0.
Layer makeRegion(int id, const QString &type, const QPointF &from, const QPointF &to, const ShapeStyle &style);
// The seed field as a number (0 when missing or not 16 hex digits) and a number as the field.
quint64 regionSeed(const Layer &layer);
QString seedString(quint64 seed);

// The colour of a layer, invalid when the field is missing or does not read.
QColor layerColor(const Layer &layer);
// The stroke, clamped; 0 when the field is missing or not a finite number.
qreal layerWidth(const Layer &layer);
bool layerFill(const Layer &layer);
QString arrowStyle(const Layer &layer);

// A point field ("from", "to", "ctrl") as a point; false when missing, not two finite numbers or out of range.
bool readPoint(const QJsonObject &fields, const char *key, QPointF *point);
QJsonArray pointArray(const QPointF &point);

// The box of a rectangle or ellipse layer (w and h are 0 or more); false when the fields do not read.
bool readBox(const Layer &layer, QRectF *box);

// The layer for `type` from `from` to `to` (for a rectangle or an ellipse: two opposite corners, in either order). A curved
// arrow gets its control point on the chord's perpendicular, a quarter of its length from the middle. An unknown type gives id 0.
Layer makeShape(int id, const QString &type, const QPointF &from, const QPointF &to, const ShapeStyle &style);

// The points of a pen or highlighter layer (empty when the field does not read).
QVector<QPointF> strokePoints(const Layer &layer);
// A pen or highlighter layer through `points` (reduced to at most kMaxStrokePoints by simplified()); a highlighter's width is the
// style's times its factor and its colour has the style's highlight opacity. Another type gives id 0.
Layer makeStroke(int id, const QString &type, const QVector<QPointF> &points, const ShapeStyle &style);
// A text layer centred on `center` (an empty text, or one over kMaxTextLength, gives id 0) and a counter.
Layer makeText(int id, const QPointF &center, const QString &text, const ShapeStyle &style);
Layer makeCounter(int id, const QPointF &center, const ShapeStyle &style);
QString layerText(const Layer &layer);
// The same layer with another colour, stroke, text style, text size or fill (the style controls on a selection); the layer itself
// when the field does not apply to its type.
Layer withColor(const Layer &layer, const QString &color);
Layer withWidth(const Layer &layer, qreal width);
Layer withFill(const Layer &layer, bool fill);
Layer withTextStyle(const Layer &layer, const QString &style);
Layer withTextSize(const Layer &layer, qreal size);
Layer withText(const Layer &layer, const QString &text);

// `points` without the ones within `epsilon` of the line through their neighbours (Ramer-Douglas-Peucker); the ends stay.
QVector<QPointF> simplified(const QVector<QPointF> &points, qreal epsilon);
// A highlighter stroke that is nearly straight (every point within 0.6 of `width` of the chord, the chord at least twice `width`)
// as its two ends, level when it is within 10 degrees of the horizontal: the marker snaps along a line of text. Else `points`.
QVector<QPointF> snappedStraight(const QVector<QPointF> &points, qreal width);
// The curve through `points` (Catmull-Rom as cubic segments).
QPainterPath smoothPath(const QVector<QPointF> &points);
// A path as SVG path data ("M x y L x y C ..."), which PathSvg draws as the same outline.
QString pathToSvg(const QPainterPath &path);

// The number of each layer: 1, 2, ... for the counters in layer order, 0 for the others.
QList<int> counterNumbers(const Layers &layers);

// The smallest id above every id of `layers` (1 for none), 0 when the ids are used up.
int nextLayerId(const Layers &layers);

// The geometry's bounds, without the stroke; null for a layer that does not read or has no geometry in this slice.
QRectF layerBounds(const Layer &layer);

// Whether `p` is on the layer within `tolerance` of the drawn shape (stroke included): inside a filled shape, near the edge of an
// outlined one, near the line or curve.
bool hitLayer(const Layer &layer, const QPointF &p, qreal tolerance);
// The topmost layer hit, 0 for none.
int hitTest(const Layers &layers, const QPointF &p, qreal tolerance);

Layer translated(const Layer &layer, const QPointF &delta);

// The handles of a selected layer: the eight of a box, or the ends (and the control point of a curve) of a line.
struct Handle {
    enum Kind { TopLeft, Top, TopRight, Right, BottomRight, Bottom, BottomLeft, Left, From, To, Control };
    Kind kind;
    QPointF pos;
};
QList<Handle> handlesOf(const Layer &layer);
// The handle of `layer` within `tolerance` of `p`, if any.
bool handleAt(const Layer &layer, const QPointF &p, qreal tolerance, Handle::Kind *kind);
// The layer with its handle `kind` moved to `to` (a box edge can cross the opposite one: the box flips; a side never gets
// smaller than one pixel while it is dragged).
Layer draggedHandle(const Layer &layer, Handle::Kind kind, const QPointF &to);

// What is drawn for a shape layer, worked out once for both its users: the QPainter exporter and the editor's scene items (the
// model of layermodel.h), so that the two cannot disagree about where a head, a shaft or an edge goes. All in picture pixels.
struct ShapeGeometry {
    enum Kind { None, Rect, Ellipse, Line, Arrow, ArrowCurved, Stroke, Glyphs, Redact, Pixelate, Blur, Spotlight };
    Kind kind = None; // None: the layer does not read, nothing is drawn
    QColor color;
    qreal width = 0;
    bool fill = false;      // Rect and Ellipse
    QRectF box;             // Rect and Ellipse
    QPointF shaftStart;     // Line and the arrows: the stroke's ends (an arrow's shaft stops inside its head)
    QPointF shaftEnd;
    QPointF ctrl;           // ArrowCurved: the quadratic curve's control point
    QPolygonF endHead;      // the arrows: filled triangles (three points)
    QPolygonF startHead;    // a double arrow's second head, else empty
    qreal headStroke = 0;   // the thin round-joined edge drawn around a head
    // Stroke (a pen or a highlighter): the smoothed centre line, stroked with `width`, flat-capped for a highlighter.
    QPainterPath path;
    bool flatCap = false;
    // Glyphs (text and a counter's number): `path` is the outline of the glyphs, filled with `ink`; an outlined text first strokes
    // it with `outlineColor` (`outlineWidth` wide); a pill or a counter first fills `plate` with `plateColor`.
    QColor ink;
    QColor outlineColor;
    qreal outlineWidth = 0;
    QPainterPath plate;
    QColor plateColor;
    // The regions (slice B7): `area` is whole device pixels (box = area), `color` is Redact's opaque fill or the Spotlight's veil;
    // Spotlight's `path` is the veil (an outer rectangle and the area, odd-even filled).
    QRect area;
    int block = 0;      // Pixelate: at least kMinPixelateBlock
    quint64 seed = 0;   // Pixelate
    qreal radius = 0;   // Blur: the Gaussian's sigma
    QRectF layoutBox; // the lines' box (their advances, not the ink): what a text or a counter takes, which is what is picked and selected
};
// `counterNumber` is the counter's place among the counters (counterNumbers); other layers ignore it.
ShapeGeometry shapeGeometry(const Layer &layer, int counterNumber = 0);

// `to` kept on the 45-degree lines through `from` (a line or an arrow), or on the square's diagonal (`square`, for a box).
QPointF constrained(const QPointF &from, const QPointF &to, bool square);

} // namespace screenshot
