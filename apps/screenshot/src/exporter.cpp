#include "exporter.h"

#include "annotations.h"

#include <QLineF>
#include <QPainterPath>
#include <QPolygonF>

#include <cmath>

namespace screenshot {

namespace {

constexpr qreal kHeadHalfAngle = 0.5236; // 30 degrees
constexpr qreal kHeadPerWidth = 4;       // the head's length, in strokes
constexpr qreal kHeadMinimum = 6;        // and at least this many pixels

QPen strokePen(const QColor &color, qreal width, Qt::PenJoinStyle join)
{
    QPen pen(color, width);
    pen.setCapStyle(Qt::RoundCap);
    pen.setJoinStyle(join);
    return pen;
}

// The head at `tip`, pointing along `direction` (unit); its base centre is returned in `base`.
QPolygonF head(const QPointF &tip, const QPointF &direction, qreal length, QPointF *base)
{
    const QPointF back = tip - direction * length;
    const QPointF side(-direction.y(), direction.x());
    const qreal half = length * std::tan(kHeadHalfAngle);
    *base = tip - direction * (length * 0.8); // the shaft stops inside the head, so that the tip stays sharp
    return QPolygonF{tip, back + side * half, back - side * half};
}

QPointF unit(const QPointF &v, const QPointF &fallback)
{
    const qreal length = std::hypot(v.x(), v.y());
    return length > 1e-9 ? v / length : fallback;
}

void paintBox(QPainter *p, const Layer &layer, const QColor &color, qreal width)
{
    QRectF box;
    if (!readBox(layer, &box))
        return;
    p->setPen(strokePen(color, width, Qt::MiterJoin));
    p->setBrush(layerFill(layer) ? QBrush(color) : QBrush(Qt::NoBrush));
    if (layer.type == QLatin1String("ellipse"))
        p->drawEllipse(box);
    else
        p->drawRect(box);
}

void paintLine(QPainter *p, const Layer &layer, const QColor &color, qreal width)
{
    QPointF a, b;
    if (!readPoint(layer.fields, "from", &a) || !readPoint(layer.fields, "to", &b))
        return;
    p->setPen(strokePen(color, width, Qt::RoundJoin));
    p->setBrush(Qt::NoBrush);
    p->drawLine(a, b);
}

void paintArrow(QPainter *p, const Layer &layer, const QColor &color, qreal width)
{
    QPointF a, b, ctrl;
    if (!readPoint(layer.fields, "from", &a) || !readPoint(layer.fields, "to", &b))
        return;
    const QString style = arrowStyle(layer);
    const bool curved = style == QLatin1String("curved") && readPoint(layer.fields, "ctrl", &ctrl);
    const bool both = style == QLatin1String("double");
    if (!curved)
        ctrl = (a + b) / 2;
    const qreal chord = QLineF(a, b).length();
    if (chord <= 0)
        return;
    // A head is at most half the arrow (a short arrow is all head); the curve leaves and arrives along its control point.
    const qreal length = std::min(std::max(kHeadPerWidth * width, kHeadMinimum), chord * (both ? 0.4 : 0.5));
    const QPointF endDir = unit(b - ctrl, unit(b - a, QPointF(1, 0)));
    const QPointF startDir = unit(a - ctrl, unit(a - b, QPointF(-1, 0)));

    QPointF shaftEnd = b, shaftStart = a;
    QPolygonF endHead, startHead;
    endHead = head(b, endDir, length, &shaftEnd);
    if (both)
        startHead = head(a, startDir, length, &shaftStart);

    QPainterPath shaft(shaftStart);
    if (curved)
        shaft.quadTo(ctrl, shaftEnd);
    else
        shaft.lineTo(shaftEnd);
    p->setBrush(Qt::NoBrush);
    p->setPen(strokePen(color, width, Qt::RoundJoin));
    p->drawPath(shaft);

    // The heads: filled, with a thin round-joined edge so that the corners are not sharper than the shaft's ends.
    p->setBrush(color);
    p->setPen(strokePen(color, std::max<qreal>(1, width * 0.5), Qt::RoundJoin));
    p->drawPolygon(endHead);
    if (both)
        p->drawPolygon(startHead);
}

} // namespace

void paintLayers(QPainter *painter, const Layers &layers)
{
    painter->save();
    painter->setRenderHint(QPainter::Antialiasing, true);
    for (const Layer &layer : layers) {
        const QColor color = layerColor(layer);
        const qreal width = layerWidth(layer);
        if (!isShapeType(layer.type) || !color.isValid() || width <= 0)
            continue;
        if (layer.type == QLatin1String("rectangle") || layer.type == QLatin1String("ellipse"))
            paintBox(painter, layer, color, width);
        else if (layer.type == QLatin1String("line"))
            paintLine(painter, layer, color, width);
        else
            paintArrow(painter, layer, color, width);
    }
    painter->restore();
}

QImage exportLayers(const QImage &original, const Layers &layers)
{
    if (original.isNull() || layers.isEmpty())
        return original;
    QImage work = original.convertToFormat(QImage::Format_ARGB32_Premultiplied);
    work.setDevicePixelRatio(1);
    {
        QPainter painter(&work);
        paintLayers(&painter, layers);
    }
    // Back to the original's format: a picture without alpha stays without it.
    const QImage::Format back = original.hasAlphaChannel() ? QImage::Format_ARGB32 : QImage::Format_RGB32;
    QImage out = work.convertToFormat(back);
    out.setDevicePixelRatio(original.devicePixelRatio());
    return out;
}

QImage renderOverlay(const Layers &layers, const QSize &natural, const QSize &target)
{
    if (natural.isEmpty() || target.isEmpty())
        return {};
    QImage overlay(target, QImage::Format_ARGB32_Premultiplied);
    overlay.fill(Qt::transparent);
    {
        QPainter painter(&overlay);
        painter.scale(qreal(target.width()) / natural.width(), qreal(target.height()) / natural.height());
        paintLayers(&painter, layers);
    }
    return overlay;
}

} // namespace screenshot
