#pragma once

#include "layers.h"

#include <QColor>
#include <QJsonArray>
#include <QPointF>
#include <QPolygonF>
#include <QRectF>
#include <QString>

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
// A layer whose fields do not read (missing, not finite, out of range, no valid colour) is neither drawn, hit nor selected.
namespace screenshot {

constexpr qreal kMaxCoordinate = 1.0e6;
constexpr qreal kMinStrokeWidth = 0.5;
constexpr qreal kMaxStrokeWidth = 1000;

// What a new shape is drawn with.
struct ShapeStyle {
    QString color; // "#rrggbb" or "#aarrggbb"; an invalid colour makes shapes that draw nothing
    qreal width = 3;
    bool fill = false;
    QString arrow = QStringLiteral("straight");
};

// The shape tools' layer types (the geometry the editor edits in this slice).
bool isShapeType(const QString &type);

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
    enum Kind { None, Rect, Ellipse, Line, Arrow, ArrowCurved };
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
};
ShapeGeometry shapeGeometry(const Layer &layer);

// `to` kept on the 45-degree lines through `from` (a line or an arrow), or on the square's diagonal (`square`, for a box).
QPointF constrained(const QPointF &from, const QPointF &to, bool square);

} // namespace screenshot
