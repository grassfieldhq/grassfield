#include "annotations.h"

#include <QLineF>
#include <QPainterPath>
#include <QRegularExpression>

#include <algorithm>
#include <cmath>

namespace screenshot {

namespace {

constexpr qreal kHeadHalfAngle = 0.5236; // 30 degrees
constexpr qreal kHeadPerWidth = 4;       // an arrow head's length, in strokes
constexpr qreal kHeadMinimum = 6;        // and at least this many pixels

bool finiteIn(double v)
{
    return std::isfinite(v) && std::abs(v) <= kMaxCoordinate;
}

// The curve of an arrow's shaft (a straight one is a segment).
QPainterPath shaft(const Layer &layer, const QPointF &from, const QPointF &to)
{
    QPainterPath path(from);
    QPointF ctrl;
    if (arrowStyle(layer) == QLatin1String("curved") && readPoint(layer.fields, "ctrl", &ctrl))
        path.quadTo(ctrl, to);
    else
        path.lineTo(to);
    return path;
}

qreal distanceToSegment(const QPointF &p, const QPointF &a, const QPointF &b)
{
    const QPointF ab = b - a;
    const qreal len2 = ab.x() * ab.x() + ab.y() * ab.y();
    if (len2 <= 0)
        return QLineF(p, a).length();
    const qreal t = std::clamp(((p.x() - a.x()) * ab.x() + (p.y() - a.y()) * ab.y()) / len2, 0.0, 1.0);
    return QLineF(p, a + ab * t).length();
}

bool pointsOf(const Layer &layer, QPointF *from, QPointF *to)
{
    return readPoint(layer.fields, "from", from) && readPoint(layer.fields, "to", to);
}

bool isBox(const Layer &layer)
{
    return layer.type == QLatin1String("rectangle") || layer.type == QLatin1String("ellipse");
}

QPointF unit(const QPointF &v, const QPointF &fallback)
{
    const qreal length = std::hypot(v.x(), v.y());
    return length > 1e-9 ? v / length : fallback;
}

// The head at `tip`, pointing along `direction` (unit); `base` is where the shaft stops, inside the head, so that the tip stays sharp.
QPolygonF headAt(const QPointF &tip, const QPointF &direction, qreal length, QPointF *base)
{
    const QPointF back = tip - direction * length;
    const QPointF side(-direction.y(), direction.x());
    const qreal half = length * std::tan(kHeadHalfAngle);
    *base = tip - direction * (length * 0.8);
    return QPolygonF{tip, back + side * half, back - side * half};
}

} // namespace

bool isShapeType(const QString &type)
{
    return type == QLatin1String("arrow") || type == QLatin1String("line") || type == QLatin1String("rectangle")
        || type == QLatin1String("ellipse");
}

QColor layerColor(const Layer &layer)
{
    const QJsonValue v = layer.fields.value(QStringLiteral("color"));
    if (!v.isString())
        return {};
    const QString name = v.toString();
    // Only the two documented forms; QColor would also take names and other notations.
    static const QRegularExpression form(QStringLiteral("^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"));
    return form.match(name).hasMatch() ? QColor(name) : QColor();
}

qreal layerWidth(const Layer &layer)
{
    const QJsonValue v = layer.fields.value(QStringLiteral("width"));
    if (!v.isDouble() || !std::isfinite(v.toDouble()))
        return 0;
    return std::clamp(v.toDouble(), kMinStrokeWidth, kMaxStrokeWidth);
}

bool layerFill(const Layer &layer)
{
    return layer.fields.value(QStringLiteral("fill")).toBool(false);
}

QString arrowStyle(const Layer &layer)
{
    const QString style = layer.fields.value(QStringLiteral("style")).toString();
    return style == QLatin1String("curved") || style == QLatin1String("double") ? style : QStringLiteral("straight");
}

bool readPoint(const QJsonObject &fields, const char *key, QPointF *point)
{
    const QJsonValue v = fields.value(QLatin1String(key));
    if (!v.isArray())
        return false;
    const QJsonArray a = v.toArray();
    if (a.size() != 2 || !a[0].isDouble() || !a[1].isDouble() || !finiteIn(a[0].toDouble()) || !finiteIn(a[1].toDouble()))
        return false;
    *point = QPointF(a[0].toDouble(), a[1].toDouble());
    return true;
}

QJsonArray pointArray(const QPointF &point)
{
    return QJsonArray{point.x(), point.y()};
}

bool readBox(const Layer &layer, QRectF *box)
{
    const auto num = [&layer](const char *key, double *out) {
        const QJsonValue v = layer.fields.value(QLatin1String(key));
        if (!v.isDouble() || !finiteIn(v.toDouble()))
            return false;
        *out = v.toDouble();
        return true;
    };
    double x, y, w, h;
    if (!num("x", &x) || !num("y", &y) || !num("w", &w) || !num("h", &h) || w < 0 || h < 0)
        return false;
    *box = QRectF(x, y, w, h);
    return true;
}

Layer makeShape(int id, const QString &type, const QPointF &from, const QPointF &to, const ShapeStyle &style)
{
    if (!isShapeType(type))
        return Layer{};
    Layer layer;
    layer.id = id;
    layer.type = type;
    layer.fields.insert(QStringLiteral("color"), style.color);
    layer.fields.insert(QStringLiteral("width"), std::clamp<qreal>(style.width, kMinStrokeWidth, kMaxStrokeWidth));
    if (isBox(layer)) {
        const QRectF box = QRectF(from, to).normalized();
        layer.fields.insert(QStringLiteral("x"), box.x());
        layer.fields.insert(QStringLiteral("y"), box.y());
        layer.fields.insert(QStringLiteral("w"), box.width());
        layer.fields.insert(QStringLiteral("h"), box.height());
        layer.fields.insert(QStringLiteral("fill"), style.fill);
        return layer;
    }
    layer.fields.insert(QStringLiteral("from"), pointArray(from));
    layer.fields.insert(QStringLiteral("to"), pointArray(to));
    if (type == QLatin1String("arrow")) {
        const bool known = style.arrow == QLatin1String("curved") || style.arrow == QLatin1String("double");
        const QString arrow = known ? style.arrow : QStringLiteral("straight");
        layer.fields.insert(QStringLiteral("style"), arrow);
        if (arrow == QLatin1String("curved")) {
            const QPointF mid = (from + to) / 2;
            const QPointF d = to - from;
            layer.fields.insert(QStringLiteral("ctrl"), pointArray(mid + QPointF(d.y(), -d.x()) * 0.25));
        }
    }
    return layer;
}

int nextLayerId(const Layers &layers)
{
    qint64 top = 0;
    for (const Layer &layer : layers)
        top = std::max<qint64>(top, layer.id);
    return top >= 2147483647 ? 0 : int(top + 1);
}

QRectF layerBounds(const Layer &layer)
{
    QRectF box;
    if (isBox(layer))
        return readBox(layer, &box) ? box : QRectF();
    QPointF a, b, ctrl;
    if ((layer.type == QLatin1String("line") || layer.type == QLatin1String("arrow")) && pointsOf(layer, &a, &b)) {
        QRectF bounds = QRectF(a, b).normalized();
        if (layer.type == QLatin1String("arrow") && arrowStyle(layer) == QLatin1String("curved") && readPoint(layer.fields, "ctrl", &ctrl)) {
            // The curve stays within the hull of its three points; the editor's box is the hull's box.
            bounds = bounds.united(QRectF(ctrl, QSizeF(0, 0)));
        }
        return bounds;
    }
    return {};
}

bool hitLayer(const Layer &layer, const QPointF &p, qreal tolerance)
{
    if (!isShapeType(layer.type) || !layerColor(layer).isValid() || layerWidth(layer) <= 0)
        return false;
    const qreal reach = tolerance + layerWidth(layer) / 2;
    QRectF box;
    if (layer.type == QLatin1String("rectangle")) {
        if (!readBox(layer, &box))
            return false;
        const QRectF outer = box.adjusted(-reach, -reach, reach, reach);
        if (layerFill(layer))
            return outer.contains(p);
        const QRectF inner = box.adjusted(reach, reach, -reach, -reach);
        return outer.contains(p) && !(inner.width() > 0 && inner.height() > 0 && inner.contains(p));
    }
    if (layer.type == QLatin1String("ellipse")) {
        if (!readBox(layer, &box))
            return false;
        const QPointF c = box.center();
        const auto inside = [&](qreal grow) { // inside the ellipse grown by `grow` on every side
            const qreal a = box.width() / 2 + grow, b = box.height() / 2 + grow;
            if (a <= 0 || b <= 0)
                return false;
            const qreal dx = (p.x() - c.x()) / a, dy = (p.y() - c.y()) / b;
            return dx * dx + dy * dy <= 1;
        };
        return layerFill(layer) ? inside(reach) : inside(reach) && !inside(-reach);
    }
    QPointF a, b;
    if (!pointsOf(layer, &a, &b))
        return false;
    const QPainterPath path = shaft(layer, a, b);
    constexpr int steps = 48; // the curve flattened into short pieces
    QPointF previous = path.pointAtPercent(0);
    for (int i = 1; i <= steps; ++i) {
        const QPointF next = path.pointAtPercent(qreal(i) / steps);
        if (distanceToSegment(p, previous, next) <= reach)
            return true;
        previous = next;
    }
    return false;
}

int hitTest(const Layers &layers, const QPointF &p, qreal tolerance)
{
    for (int i = layers.size() - 1; i >= 0; --i) {
        if (hitLayer(layers[i], p, tolerance))
            return layers[i].id;
    }
    return 0;
}

Layer translated(const Layer &layer, const QPointF &delta)
{
    Layer out = layer;
    QRectF box;
    if (isBox(layer)) {
        if (readBox(layer, &box)) {
            out.fields.insert(QStringLiteral("x"), box.x() + delta.x());
            out.fields.insert(QStringLiteral("y"), box.y() + delta.y());
        }
        return out;
    }
    for (const char *key : {"from", "to", "ctrl"}) {
        QPointF point;
        if (readPoint(layer.fields, key, &point))
            out.fields.insert(QLatin1String(key), pointArray(point + delta));
    }
    return out;
}

QList<Handle> handlesOf(const Layer &layer)
{
    QRectF box;
    if (isBox(layer)) {
        if (!readBox(layer, &box))
            return {};
        const QPointF c = box.center();
        return {{Handle::TopLeft, box.topLeft()},         {Handle::Top, QPointF(c.x(), box.top())},
                {Handle::TopRight, box.topRight()},       {Handle::Right, QPointF(box.right(), c.y())},
                {Handle::BottomRight, box.bottomRight()}, {Handle::Bottom, QPointF(c.x(), box.bottom())},
                {Handle::BottomLeft, box.bottomLeft()},   {Handle::Left, QPointF(box.left(), c.y())}};
    }
    QPointF a, b, ctrl;
    if ((layer.type == QLatin1String("line") || layer.type == QLatin1String("arrow")) && pointsOf(layer, &a, &b)) {
        QList<Handle> handles{{Handle::From, a}, {Handle::To, b}};
        if (layer.type == QLatin1String("arrow") && arrowStyle(layer) == QLatin1String("curved") && readPoint(layer.fields, "ctrl", &ctrl))
            handles.append({Handle::Control, ctrl});
        return handles;
    }
    return {};
}

bool handleAt(const Layer &layer, const QPointF &p, qreal tolerance, Handle::Kind *kind)
{
    // The last of the list wins a tie, as the topmost drawn: the control point sits over the ends of a flat curve.
    const QList<Handle> handles = handlesOf(layer);
    for (int i = handles.size() - 1; i >= 0; --i) {
        if (QLineF(handles[i].pos, p).length() <= tolerance) {
            *kind = handles[i].kind;
            return true;
        }
    }
    return false;
}

Layer draggedHandle(const Layer &layer, Handle::Kind kind, const QPointF &to)
{
    Layer out = layer;
    if (!finiteIn(to.x()) || !finiteIn(to.y()))
        return out;
    if (kind == Handle::From || kind == Handle::To || kind == Handle::Control) {
        const char *key = kind == Handle::From ? "from" : kind == Handle::To ? "to" : "ctrl";
        out.fields.insert(QLatin1String(key), pointArray(to));
        return out;
    }
    QRectF box;
    if (!readBox(layer, &box))
        return out;
    qreal l = box.left(), r = box.right(), t = box.top(), b = box.bottom();
    bool sidesX = true, sidesY = true; // whether the handle moves a vertical edge, a horizontal edge
    switch (kind) {
    case Handle::TopLeft: l = to.x(); t = to.y(); break;
    case Handle::Top: t = to.y(); sidesX = false; break;
    case Handle::TopRight: r = to.x(); t = to.y(); break;
    case Handle::Right: r = to.x(); sidesY = false; break;
    case Handle::BottomRight: r = to.x(); b = to.y(); break;
    case Handle::Bottom: b = to.y(); sidesX = false; break;
    case Handle::BottomLeft: l = to.x(); b = to.y(); break;
    case Handle::Left: l = to.x(); sidesY = false; break;
    default: break;
    }
    QRectF next = QRectF(QPointF(l, t), QPointF(r, b)).normalized();
    if (sidesX && next.width() < 1)
        next.setWidth(1);
    if (sidesY && next.height() < 1)
        next.setHeight(1);
    out.fields.insert(QStringLiteral("x"), next.x());
    out.fields.insert(QStringLiteral("y"), next.y());
    out.fields.insert(QStringLiteral("w"), next.width());
    out.fields.insert(QStringLiteral("h"), next.height());
    return out;
}

ShapeGeometry shapeGeometry(const Layer &layer)
{
    ShapeGeometry g;
    g.color = layerColor(layer);
    g.width = layerWidth(layer);
    if (!isShapeType(layer.type) || !g.color.isValid() || g.width <= 0)
        return ShapeGeometry();
    if (isBox(layer)) {
        if (!readBox(layer, &g.box))
            return ShapeGeometry();
        g.kind = layer.type == QLatin1String("ellipse") ? ShapeGeometry::Ellipse : ShapeGeometry::Rect;
        g.fill = layerFill(layer);
        return g;
    }
    QPointF a, b, ctrl;
    if (!pointsOf(layer, &a, &b))
        return ShapeGeometry();
    if (layer.type == QLatin1String("line")) {
        g.kind = ShapeGeometry::Line;
        g.shaftStart = a;
        g.shaftEnd = b;
        return g;
    }
    const QString style = arrowStyle(layer);
    const bool curved = style == QLatin1String("curved") && readPoint(layer.fields, "ctrl", &ctrl);
    const bool both = style == QLatin1String("double");
    if (!curved)
        ctrl = (a + b) / 2;
    const qreal chord = QLineF(a, b).length();
    if (chord <= 0)
        return ShapeGeometry();
    // A head is at most half the arrow (a short arrow is all head); the curve leaves and arrives along its control point.
    const qreal length = std::min(std::max(kHeadPerWidth * g.width, kHeadMinimum), chord * (both ? 0.4 : 0.5));
    const QPointF endDir = unit(b - ctrl, unit(b - a, QPointF(1, 0)));
    const QPointF startDir = unit(a - ctrl, unit(a - b, QPointF(-1, 0)));
    g.kind = curved ? ShapeGeometry::ArrowCurved : ShapeGeometry::Arrow;
    g.shaftStart = a;
    g.shaftEnd = b;
    g.ctrl = ctrl;
    g.endHead = headAt(b, endDir, length, &g.shaftEnd);
    if (both)
        g.startHead = headAt(a, startDir, length, &g.shaftStart);
    g.headStroke = std::max<qreal>(1, g.width * 0.5);
    return g;
}

QPointF constrained(const QPointF &from, const QPointF &to, bool square)
{
    const QPointF d = to - from;
    if (square) {
        const qreal side = std::max(std::abs(d.x()), std::abs(d.y()));
        return from + QPointF(d.x() < 0 ? -side : side, d.y() < 0 ? -side : side);
    }
    const qreal length = std::hypot(d.x(), d.y());
    if (length == 0)
        return to;
    const qreal step = M_PI / 4;
    const qreal angle = std::round(std::atan2(d.y(), d.x()) / step) * step;
    return from + QPointF(std::cos(angle), std::sin(angle)) * length;
}

} // namespace screenshot
