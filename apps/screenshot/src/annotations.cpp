#include "annotations.h"

#include <QFont>
#include <QFontMetricsF>
#include <QHash>
#include <QLineF>
#include <QPainterPath>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QTransform>

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
    return layer.type == QLatin1String("rectangle") || layer.type == QLatin1String("ellipse") || isRegionType(layer.type);
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

constexpr qreal kFontBase = 100;        // glyph outlines are laid out at this pixel size and scaled to the layer's size
constexpr qreal kOutlinePerSize = 0.12; // an outlined text's edge, in sizes
constexpr qreal kPillPadX = 0.45;       // a pill's padding around the text, in line heights
constexpr qreal kPillPadY = 0.22;
constexpr qreal kCounterNumberHeight = 0.5; // a counter's digits: their height and the widest they get, in diameters
constexpr qreal kCounterNumberWidth = 0.7;

// Black or white, whichever reads better on `color` (the equal-contrast luminance, 0.179).
QColor contrastOn(const QColor &color)
{
    const auto lin = [](qreal c) { return c <= 0.03928 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4); };
    const qreal luminance = 0.2126 * lin(color.redF()) + 0.7152 * lin(color.greenF()) + 0.0722 * lin(color.blueF());
    return luminance > 0.179 ? QColor(Qt::black) : QColor(Qt::white);
}

bool validColorForm(const QString &name)
{
    static const QRegularExpression form(QStringLiteral("^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"));
    return form.match(name).hasMatch();
}

struct GlyphLayout {
    QPainterPath path; // the glyphs, centred on the origin, at kFontBase
    QRectF box;        // their lines' box (advances, not ink), centred on the origin
};

QFont baseFont(const QString &family, bool bold)
{
    QFont font(family);
    font.setPixelSize(int(kFontBase));
    font.setWeight(bold ? QFont::Bold : QFont::Medium);
    font.setHintingPreference(QFont::PreferNoHinting);
    return font;
}

// The lines of `text` centred on each other and on the origin. Cached by what they depend on (laying out outlines is the one costly
// step, and a drag moves a layer without changing its text).
GlyphLayout glyphLayout(const QString &text, const QString &family, bool bold)
{
    static QHash<QString, GlyphLayout> cache;
    const QString key = family + QLatin1Char('\x1f') + (bold ? QLatin1Char('b') : QLatin1Char('r')) + text;
    const auto hit = cache.constFind(key);
    if (hit != cache.constEnd())
        return *hit;
    const QFont font = baseFont(family, bold);
    const QFontMetricsF fm(font);
    const QStringList lines = text.split(QLatin1Char('\n'));
    qreal widest = 0;
    for (const QString &line : lines)
        widest = std::max(widest, fm.horizontalAdvance(line));
    const qreal lineHeight = fm.lineSpacing();
    const qreal total = lineHeight * lines.size();
    GlyphLayout out;
    out.box = QRectF(-widest / 2, -total / 2, widest, total);
    for (int i = 0; i < lines.size(); ++i) {
        const qreal advance = fm.horizontalAdvance(lines[i]);
        out.path.addText(QPointF(-advance / 2, -total / 2 + i * lineHeight + fm.ascent()), font, lines[i]);
    }
    if (cache.size() > 256)
        cache.clear();
    cache.insert(key, out);
    return out;
}

QPainterPath roundedBox(const QRectF &box, qreal radius)
{
    QPainterPath path;
    path.addRoundedRect(box, radius, radius);
    return path;
}

bool readNumber(const Layer &layer, const char *key, qreal *out, qreal lo, qreal hi)
{
    const QJsonValue v = layer.fields.value(QLatin1String(key));
    if (!v.isDouble() || !std::isfinite(v.toDouble()) || v.toDouble() < lo || v.toDouble() > hi)
        return false;
    *out = v.toDouble();
    return true;
}

int textRotation(const Layer &layer)
{
    const QJsonValue v = layer.fields.value(QStringLiteral("rot"));
    if (!v.isDouble() || !std::isfinite(v.toDouble()))
        return 0;
    // Reduced as a double first: converting a number out of int's range would be undefined.
    const double turns = std::fmod(std::floor(v.toDouble()), 4.0);
    return int(turns < 0 ? turns + 4.0 : turns);
}

QString textStyleOf(const Layer &layer)
{
    const QString style = layer.fields.value(QStringLiteral("style")).toString();
    return style == QLatin1String("outlined") || style == QLatin1String("pill") ? style : QStringLiteral("plain");
}

QRectF pointsBox(const QVector<QPointF> &points)
{
    if (points.isEmpty())
        return {};
    qreal l = points[0].x(), r = l, t = points[0].y(), b = t;
    for (const QPointF &p : points) {
        l = std::min(l, p.x());
        r = std::max(r, p.x());
        t = std::min(t, p.y());
        b = std::max(b, p.y());
    }
    return QRectF(QPointF(l, t), QPointF(r, b));
}

// The box handles and the resize work on: a rectangle's or ellipse's box, a pen's or highlighter's points' box.
bool editBox(const Layer &layer, QRectF *box)
{
    if (isBox(layer))
        return readBox(layer, box);
    if (isStrokeType(layer.type)) {
        const QVector<QPointF> points = strokePoints(layer);
        if (points.size() < 2)
            return false;
        *box = pointsBox(points);
        return true;
    }
    return false;
}

} // namespace

bool isStrokeType(const QString &type)
{
    return type == QLatin1String("pen") || type == QLatin1String("highlighter");
}

bool isTextType(const QString &type)
{
    return type == QLatin1String("text") || type == QLatin1String("counter");
}

bool isShapeType(const QString &type)
{
    return type == QLatin1String("arrow") || type == QLatin1String("line") || type == QLatin1String("rectangle")
        || type == QLatin1String("ellipse") || isStrokeType(type) || isTextType(type);
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
    if (!isShapeType(type) || isStrokeType(type) || isTextType(type))
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

QVector<QPointF> strokePoints(const Layer &layer)
{
    QVector<QPointF> points;
    const QJsonValue v = layer.fields.value(QStringLiteral("points"));
    if (!v.isArray())
        return points;
    const QJsonArray array = v.toArray();
    if (array.size() < 2 || array.size() > kMaxStrokePoints)
        return points;
    points.reserve(array.size());
    for (const QJsonValue &item : array) {
        const QJsonArray pair = item.toArray();
        if (pair.size() != 2 || !pair[0].isDouble() || !pair[1].isDouble() || !finiteIn(pair[0].toDouble()) || !finiteIn(pair[1].toDouble()))
            return {};
        points.append(QPointF(pair[0].toDouble(), pair[1].toDouble()));
    }
    return points;
}

QVector<QPointF> simplified(const QVector<QPointF> &points, qreal epsilon)
{
    const int n = int(points.size());
    if (n < 3)
        return points;
    QVector<bool> keep(n, false);
    keep[0] = keep[n - 1] = true;
    QList<QPair<int, int>> stack{{0, n - 1}};
    while (!stack.isEmpty()) {
        const auto [first, last] = stack.takeLast();
        qreal farthest = 0;
        int at = -1;
        for (int i = first + 1; i < last; ++i) {
            const qreal d = distanceToSegment(points[i], points[first], points[last]);
            if (d > farthest) {
                farthest = d;
                at = i;
            }
        }
        if (at >= 0 && farthest > epsilon) {
            keep[at] = true;
            stack.append({first, at});
            stack.append({at, last});
        }
    }
    QVector<QPointF> out;
    for (int i = 0; i < n; ++i) {
        if (keep[i])
            out.append(points[i]);
    }
    return out;
}

QVector<QPointF> snappedStraight(const QVector<QPointF> &points, qreal width)
{
    if (points.size() < 2)
        return points;
    const QPointF a = points.first(), b = points.last();
    if (QLineF(a, b).length() < 2 * width)
        return points;
    for (const QPointF &p : points) {
        if (distanceToSegment(p, a, b) > 0.6 * width)
            return points;
    }
    const QPointF d = b - a;
    if (std::abs(d.y()) <= std::tan(M_PI / 18) * std::abs(d.x())) {
        qreal sum = 0;
        for (const QPointF &p : points)
            sum += p.y();
        const qreal level = sum / points.size();
        return {QPointF(a.x(), level), QPointF(b.x(), level)};
    }
    return {a, b};
}

QPainterPath smoothPath(const QVector<QPointF> &points)
{
    QPainterPath path;
    const int n = int(points.size());
    if (n == 0)
        return path;
    path.moveTo(points[0]);
    if (n == 1)
        return path;
    if (n == 2) {
        path.lineTo(points[1]);
        return path;
    }
    for (int i = 0; i + 1 < n; ++i) {
        const QPointF &p0 = points[std::max(i - 1, 0)], &p1 = points[i], &p2 = points[i + 1], &p3 = points[std::min(i + 2, n - 1)];
        path.cubicTo(p1 + (p2 - p0) / 6, p2 - (p3 - p1) / 6, p2);
    }
    return path;
}

QString pathToSvg(const QPainterPath &path)
{
    QString svg;
    const auto num = [](qreal v) { return QString::number(v, 'g', 9); };
    QPointF start;
    for (int i = 0; i < path.elementCount(); ++i) {
        const QPainterPath::Element e = path.elementAt(i);
        switch (e.type) {
        case QPainterPath::MoveToElement:
            start = e;
            svg += QStringLiteral("M%1 %2 ").arg(num(e.x), num(e.y));
            break;
        case QPainterPath::LineToElement:
            svg += QStringLiteral("L%1 %2 ").arg(num(e.x), num(e.y));
            if (QPointF(e) == start && (i + 1 == path.elementCount() || path.elementAt(i + 1).type == QPainterPath::MoveToElement))
                svg += QLatin1String("Z "); // the outline came back to its start: closed, so that a stroke joins there
            break;
        case QPainterPath::CurveToElement: {
            const QPainterPath::Element c2 = path.elementAt(i + 1), end = path.elementAt(i + 2);
            svg += QStringLiteral("C%1 %2 %3 %4 %5 %6 ").arg(num(e.x), num(e.y), num(c2.x), num(c2.y), num(end.x), num(end.y));
            if (QPointF(end) == start && (i + 3 == path.elementCount() || path.elementAt(i + 3).type == QPainterPath::MoveToElement))
                svg += QLatin1String("Z ");
            i += 2;
            break;
        }
        default:
            break;
        }
    }
    return svg.trimmed();
}

Layer makeStroke(int id, const QString &type, const QVector<QPointF> &points, const ShapeStyle &style)
{
    if (!isStrokeType(type))
        return Layer{};
    QVector<QPointF> kept = points;
    // Thin out until it fits: a longer stroke loses the detail of its curve before it loses its end.
    for (qreal epsilon = 0.25; kept.size() > kMaxStrokePoints && epsilon < 1e5; epsilon *= 2)
        kept = simplified(points, epsilon);
    if (kept.size() < 2 || kept.size() > kMaxStrokePoints)
        return Layer{};
    Layer layer;
    layer.id = id;
    layer.type = type;
    QColor color(style.color);
    qreal width = style.width;
    if (type == QLatin1String("highlighter")) {
        color.setAlphaF(std::clamp(style.highlightOpacity, 0.05, 1.0));
        width *= style.highlightFactor;
    }
    layer.fields.insert(QStringLiteral("color"), color.isValid() ? color.name(type == QLatin1String("highlighter") ? QColor::HexArgb : QColor::HexRgb) : style.color);
    layer.fields.insert(QStringLiteral("width"), std::clamp<qreal>(width, kMinStrokeWidth, kMaxStrokeWidth));
    QJsonArray array;
    for (const QPointF &p : kept)
        array.append(pointArray(p));
    layer.fields.insert(QStringLiteral("points"), array);
    return layer;
}

Layer makeText(int id, const QPointF &center, const QString &text, const ShapeStyle &style)
{
    if (text.trimmed().isEmpty() || text.size() > kMaxTextLength || !finiteIn(center.x()) || !finiteIn(center.y()))
        return Layer{};
    Layer layer;
    layer.id = id;
    layer.type = QStringLiteral("text");
    layer.fields.insert(QStringLiteral("color"), style.color);
    layer.fields.insert(QStringLiteral("x"), center.x());
    layer.fields.insert(QStringLiteral("y"), center.y());
    layer.fields.insert(QStringLiteral("text"), text);
    layer.fields.insert(QStringLiteral("size"), std::clamp(style.textSize, kMinTextSize, kMaxTextSize));
    const bool known = style.textStyle == QLatin1String("outlined") || style.textStyle == QLatin1String("pill");
    layer.fields.insert(QStringLiteral("style"), known ? style.textStyle : QStringLiteral("plain"));
    layer.fields.insert(QStringLiteral("family"), style.family);
    layer.fields.insert(QStringLiteral("rot"), 0);
    return layer;
}

Layer makeCounter(int id, const QPointF &center, const ShapeStyle &style)
{
    if (!finiteIn(center.x()) || !finiteIn(center.y()))
        return Layer{};
    Layer layer;
    layer.id = id;
    layer.type = QStringLiteral("counter");
    layer.fields.insert(QStringLiteral("color"), style.color);
    layer.fields.insert(QStringLiteral("x"), center.x());
    layer.fields.insert(QStringLiteral("y"), center.y());
    layer.fields.insert(QStringLiteral("size"), std::clamp(style.counterSize, kMinTextSize, kMaxTextSize));
    layer.fields.insert(QStringLiteral("family"), style.family);
    return layer;
}

QString layerText(const Layer &layer)
{
    const QString text = layer.fields.value(QStringLiteral("text")).toString();
    return text.size() > kMaxTextLength ? QString() : text;
}

Layer withColor(const Layer &layer, const QString &color)
{
    if (layer.type == QLatin1String("redact") && validColorForm(color)) {
        Layer out = layer;
        out.fields.insert(QStringLiteral("color"), QColor(QColor(color).rgb()).name()); // a redaction is opaque: the alpha is dropped
        return out;
    }
    if (!isShapeType(layer.type) || !validColorForm(color))
        return layer;
    Layer out = layer;
    QColor c(color);
    if (layer.type == QLatin1String("highlighter")) {
        c.setAlpha(layerColor(layer).isValid() ? layerColor(layer).alpha() : 102); // the marker keeps its see-through
        out.fields.insert(QStringLiteral("color"), c.name(QColor::HexArgb));
    } else {
        out.fields.insert(QStringLiteral("color"), c.name(c.alpha() == 255 ? QColor::HexRgb : QColor::HexArgb));
    }
    return out;
}

Layer withWidth(const Layer &layer, qreal width)
{
    if (layer.type == QLatin1String("text") || layer.type == QLatin1String("counter") || !isShapeType(layer.type))
        return layer;
    Layer out = layer;
    out.fields.insert(QStringLiteral("width"), std::clamp<qreal>(width, kMinStrokeWidth, kMaxStrokeWidth));
    return out;
}

Layer withFill(const Layer &layer, bool fill)
{
    if (layer.type != QLatin1String("rectangle") && layer.type != QLatin1String("ellipse"))
        return layer;
    Layer out = layer;
    out.fields.insert(QStringLiteral("fill"), fill);
    return out;
}

Layer withTextStyle(const Layer &layer, const QString &style)
{
    if (layer.type != QLatin1String("text"))
        return layer;
    Layer out = layer;
    const bool known = style == QLatin1String("outlined") || style == QLatin1String("pill");
    out.fields.insert(QStringLiteral("style"), known ? style : QStringLiteral("plain"));
    return out;
}

Layer withTextSize(const Layer &layer, qreal size)
{
    if (!isTextType(layer.type))
        return layer;
    Layer out = layer;
    out.fields.insert(QStringLiteral("size"), std::clamp(size, kMinTextSize, kMaxTextSize));
    return out;
}

Layer withText(const Layer &layer, const QString &text)
{
    if (layer.type != QLatin1String("text") || text.trimmed().isEmpty() || text.size() > kMaxTextLength)
        return layer;
    Layer out = layer;
    out.fields.insert(QStringLiteral("text"), text);
    return out;
}

QList<int> counterNumbers(const Layers &layers)
{
    QList<int> numbers;
    numbers.reserve(layers.size());
    int next = 1;
    for (const Layer &layer : layers)
        numbers.append(layer.type == QLatin1String("counter") ? next++ : 0);
    return numbers;
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
    if (isStrokeType(layer.type))
        return editBox(layer, &box) ? box : QRectF();
    if (isTextType(layer.type)) {
        const ShapeGeometry g = shapeGeometry(layer);
        return g.kind == ShapeGeometry::Glyphs ? g.layoutBox.united(g.plate.boundingRect()) : QRectF();
    }
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
    if (isTextType(layer.type)) {
        // A text or a counter is picked anywhere on its plate or its lines' box, a little beyond it.
        const ShapeGeometry g = shapeGeometry(layer);
        if (g.kind != ShapeGeometry::Glyphs)
            return false;
        const QRectF box = g.layoutBox.united(g.plate.boundingRect());
        if (layer.type == QLatin1String("counter"))
            return QLineF(box.center(), p).length() <= box.width() / 2 + tolerance;
        return box.adjusted(-tolerance, -tolerance, tolerance, tolerance).contains(p);
    }
    if (isRegionType(layer.type)) {
        const QRect area = regionArea(layer);
        return !area.isEmpty() && QRectF(area).adjusted(-tolerance, -tolerance, tolerance, tolerance).contains(p);
    }
    if (!isShapeType(layer.type) || !layerColor(layer).isValid() || layerWidth(layer) <= 0)
        return false;
    if (isStrokeType(layer.type)) {
        const QVector<QPointF> points = strokePoints(layer);
        if (points.size() < 2)
            return false;
        const qreal reach = tolerance + layerWidth(layer) / 2;
        const QPainterPath path = smoothPath(points);
        for (const QPolygonF &polygon : path.toSubpathPolygons()) {
            for (int i = 1; i < polygon.size(); ++i) {
                if (distanceToSegment(p, polygon[i - 1], polygon[i]) <= reach)
                    return true;
            }
        }
        return false;
    }
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
    if (isStrokeType(layer.type)) {
        QJsonArray array;
        for (const QPointF &point : strokePoints(layer))
            array.append(pointArray(point + delta));
        if (!array.isEmpty())
            out.fields.insert(QStringLiteral("points"), array);
        return out;
    }
    if (isTextType(layer.type)) {
        qreal x, y;
        if (readNumber(layer, "x", &x, -kMaxCoordinate, kMaxCoordinate) && readNumber(layer, "y", &y, -kMaxCoordinate, kMaxCoordinate)) {
            out.fields.insert(QStringLiteral("x"), x + delta.x());
            out.fields.insert(QStringLiteral("y"), y + delta.y());
        }
        return out;
    }
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
    if (isBox(layer) || isStrokeType(layer.type)) {
        if (!editBox(layer, &box))
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
    if (!editBox(layer, &box))
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
    if (isStrokeType(layer.type)) {
        // The points follow the box: each keeps its place in it (a stroke as flat as a level line only moves).
        const qreal sx = box.width() > 1e-9 ? next.width() / box.width() : 1, sy = box.height() > 1e-9 ? next.height() / box.height() : 1;
        QJsonArray array;
        for (const QPointF &p : strokePoints(layer)) {
            const QPointF q(next.x() + (p.x() - box.x()) * sx, next.y() + (p.y() - box.y()) * sy);
            array.append(pointArray(QPointF(std::clamp(q.x(), -kMaxCoordinate, kMaxCoordinate), std::clamp(q.y(), -kMaxCoordinate, kMaxCoordinate))));
        }
        out.fields.insert(QStringLiteral("points"), array);
        return out;
    }
    out.fields.insert(QStringLiteral("x"), next.x());
    out.fields.insert(QStringLiteral("y"), next.y());
    out.fields.insert(QStringLiteral("w"), next.width());
    out.fields.insert(QStringLiteral("h"), next.height());
    return out;
}

// A text or a counter as outlines (its glyphs, and the plate behind them), so that the exporter and the scene draw one thing.
static ShapeGeometry glyphGeometry(const Layer &layer, int counterNumber)
{
    ShapeGeometry g;
    const QColor color = layerColor(layer);
    qreal x, y, size;
    if (!color.isValid() || !readNumber(layer, "x", &x, -kMaxCoordinate, kMaxCoordinate) || !readNumber(layer, "y", &y, -kMaxCoordinate, kMaxCoordinate)
        || !readNumber(layer, "size", &size, kMinTextSize, kMaxTextSize))
        return g;
    g.color = color;
    g.kind = ShapeGeometry::Glyphs;
    if (layer.type == QLatin1String("counter")) {
        const QString number = QString::number(std::max(counterNumber, 1));
        const QString numberFamily = layer.fields.value(QStringLiteral("family")).toString();
        const GlyphLayout glyphs = glyphLayout(number, numberFamily.isEmpty() ? QStringLiteral("sans-serif") : numberFamily, true);
        const QRectF ink = glyphs.path.boundingRect();
        const qreal scale = ink.isEmpty() ? 1 : std::min(size * kCounterNumberHeight / ink.height(), size * kCounterNumberWidth / ink.width());
        QTransform t;
        t.translate(x, y);
        t.scale(scale, scale);
        t.translate(-ink.center().x(), -ink.center().y()); // the ink's own middle, so that a 1 and an 8 both sit in the disc's centre
        g.path = t.map(glyphs.path);
        g.layoutBox = QRectF(x - size / 2, y - size / 2, size, size);
        g.plate.addEllipse(QPointF(x, y), size / 2, size / 2);
        g.plateColor = color;
        g.ink = contrastOn(color);
        return g;
    }
    const QString text = layerText(layer);
    if (text.trimmed().isEmpty())
        return ShapeGeometry();
    const QString family = layer.fields.value(QStringLiteral("family")).toString();
    const GlyphLayout glyphs = glyphLayout(text, family.isEmpty() ? QStringLiteral("sans-serif") : family, false);
    QTransform t;
    t.translate(x, y);
    t.rotate(90.0 * textRotation(layer));
    t.scale(size / kFontBase, size / kFontBase);
    g.path = t.map(glyphs.path);
    g.layoutBox = t.mapRect(glyphs.box);
    const QString style = textStyleOf(layer);
    g.ink = color;
    if (style == QLatin1String("outlined")) {
        g.outlineColor = contrastOn(color);
        g.outlineWidth = size * kOutlinePerSize;
    } else if (style == QLatin1String("pill")) {
        const qreal line = QFontMetricsF(baseFont(family, false)).lineSpacing();
        const QRectF plate = glyphs.box.adjusted(-kPillPadX * line, -kPillPadY * line, kPillPadX * line, kPillPadY * line);
        g.plate = t.map(roundedBox(plate, plate.height() / 2 > 0.6 * line ? 0.6 * line : plate.height() / 2));
        g.plateColor = color;
        g.ink = contrastOn(color);
    }
    return g;
}

namespace {

// The geometry of a region layer (slice B7). Redact and Pixelate fail closed: a field that does not read gives the safe default, never
// a layer that draws nothing (only a box that does not read, or an empty one, has nothing to hide).
ShapeGeometry regionGeometry(const Layer &layer)
{
    ShapeGeometry g;
    const QRect area = regionArea(layer);
    if (area.isEmpty())
        return g;
    g.area = area;
    g.box = QRectF(area);
    if (layer.type == QLatin1String("redact")) {
        g.kind = ShapeGeometry::Redact;
        const QColor c = layerColor(layer);
        g.color = c.isValid() ? QColor(c.rgb()) : QColor(0, 0, 0);
    } else if (layer.type == QLatin1String("pixelate")) {
        g.kind = ShapeGeometry::Pixelate;
        qreal block = 0;
        g.block = readNumber(layer, "block", &block, kMinPixelateBlock, kMaxPixelateBlock) ? int(std::lround(block)) : 16;
        g.block = std::clamp(g.block, kMinPixelateBlock, kMaxPixelateBlock);
        g.seed = regionSeed(layer);
    } else if (layer.type == QLatin1String("blur")) {
        g.kind = ShapeGeometry::Blur;
        qreal radius = 0;
        g.radius = readNumber(layer, "radius", &radius, kMinBlurRadius, kMaxBlurRadius) ? radius : 8;
    } else {
        g.kind = ShapeGeometry::Spotlight;
        qreal dim = 0;
        g.width = readNumber(layer, "dim", &dim, kMinSpotlightDim, kMaxSpotlightDim) ? dim : 0.55;
        g.color = QColor::fromRgbF(0, 0, 0, g.width);
        // The veil: a rectangle past every picture's edge (the picture is at most 16384 px a side) and the area as a hole.
        constexpr qreal far = 1 << 16;
        QPainterPath veil;
        veil.setFillRule(Qt::OddEvenFill);
        veil.addRect(QRectF(-far, -far, 2 * far, 2 * far));
        veil.addRect(QRectF(area));
        g.path = veil;
    }
    return g;
}

} // namespace

bool isRegionType(const QString &type)
{
    return type == QLatin1String("redact") || type == QLatin1String("pixelate") || type == QLatin1String("blur") || type == QLatin1String("spotlight");
}

QRect regionArea(const Layer &layer)
{
    QRectF box;
    if (!isRegionType(layer.type) || !readBox(layer, &box))
        return {};
    // Outward to whole pixels: a pixel the box touches at all is inside the area, so a hidden pixel is never half covered.
    const int left = int(std::floor(box.left())), top = int(std::floor(box.top()));
    const int right = int(std::ceil(box.right())), bottom = int(std::ceil(box.bottom()));
    return QRect(left, top, right - left, bottom - top);
}

QString seedString(quint64 seed)
{
    return QStringLiteral("%1").arg(seed, 16, 16, QLatin1Char('0'));
}

quint64 regionSeed(const Layer &layer)
{
    const QString text = layer.fields.value(QStringLiteral("seed")).toString();
    bool ok = false;
    const quint64 seed = text.size() == 16 ? text.toULongLong(&ok, 16) : 0;
    return ok ? seed : 0;
}

Layer makeRegion(int id, const QString &type, const QPointF &from, const QPointF &to, const ShapeStyle &style)
{
    if (!isRegionType(type))
        return Layer{};
    Layer layer;
    layer.id = id;
    layer.type = type;
    const QRectF box = QRectF(from, to).normalized();
    layer.fields.insert(QStringLiteral("x"), box.x());
    layer.fields.insert(QStringLiteral("y"), box.y());
    layer.fields.insert(QStringLiteral("w"), box.width());
    layer.fields.insert(QStringLiteral("h"), box.height());
    if (type == QLatin1String("redact")) {
        const QColor c(style.redactColor);
        layer.fields.insert(QStringLiteral("color"), c.isValid() ? QColor(c.rgb()).name() : QStringLiteral("#000000"));
    } else if (type == QLatin1String("pixelate")) {
        layer.fields.insert(QStringLiteral("block"), std::clamp<qreal>(std::round(style.pixelateBlock), kMinPixelateBlock, kMaxPixelateBlock));
        // The system's random source (getrandom): the grid's offset and the noise cannot be predicted from anything in the picture.
        layer.fields.insert(QStringLiteral("seed"), seedString(style.seed != 0 ? style.seed : QRandomGenerator::system()->generate64()));
    } else if (type == QLatin1String("blur")) {
        layer.fields.insert(QStringLiteral("radius"), std::clamp(style.blurRadius, kMinBlurRadius, kMaxBlurRadius));
    } else {
        layer.fields.insert(QStringLiteral("dim"), std::clamp(style.spotlightDim, kMinSpotlightDim, kMaxSpotlightDim));
    }
    return layer;
}

ShapeGeometry shapeGeometry(const Layer &layer, int counterNumber)
{
    if (isRegionType(layer.type))
        return regionGeometry(layer);
    ShapeGeometry g;
    g.color = layerColor(layer);
    g.width = layerWidth(layer);
    if (isTextType(layer.type))
        return glyphGeometry(layer, counterNumber);
    if (!isShapeType(layer.type) || !g.color.isValid() || g.width <= 0)
        return ShapeGeometry();
    if (isStrokeType(layer.type)) {
        const QVector<QPointF> points = strokePoints(layer);
        if (points.size() < 2)
            return ShapeGeometry();
        g.kind = ShapeGeometry::Stroke;
        g.path = smoothPath(points);
        g.flatCap = layer.type == QLatin1String("highlighter");
        return g;
    }
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
