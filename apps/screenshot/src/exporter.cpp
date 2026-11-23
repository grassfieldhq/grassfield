#include "exporter.h"

#include "annotations.h"

#include <QLineF>
#include <QPainterPath>
#include <QPolygonF>

#include <algorithm>
#include <cmath>

namespace screenshot {

namespace {

QPen strokePen(const QColor &color, qreal width, Qt::PenJoinStyle join)
{
    QPen pen(color, width);
    pen.setCapStyle(Qt::RoundCap);
    pen.setJoinStyle(join);
    return pen;
}

void paintShape(QPainter *p, const ShapeGeometry &g)
{
    switch (g.kind) {
    case ShapeGeometry::None:
        return;
    case ShapeGeometry::Rect:
    case ShapeGeometry::Ellipse:
        p->setPen(strokePen(g.color, g.width, Qt::MiterJoin));
        p->setBrush(g.fill ? QBrush(g.color) : QBrush(Qt::NoBrush));
        if (g.kind == ShapeGeometry::Ellipse)
            p->drawEllipse(g.box);
        else
            p->drawRect(g.box);
        return;
    case ShapeGeometry::Line:
        p->setPen(strokePen(g.color, g.width, Qt::RoundJoin));
        p->setBrush(Qt::NoBrush);
        p->drawLine(g.shaftStart, g.shaftEnd);
        return;
    case ShapeGeometry::Arrow:
    case ShapeGeometry::ArrowCurved: {
        QPainterPath shaft(g.shaftStart);
        if (g.kind == ShapeGeometry::ArrowCurved)
            shaft.quadTo(g.ctrl, g.shaftEnd);
        else
            shaft.lineTo(g.shaftEnd);
        p->setBrush(Qt::NoBrush);
        p->setPen(strokePen(g.color, g.width, Qt::RoundJoin));
        p->drawPath(shaft);
        // The heads: filled, with a thin round-joined edge so that the corners are not sharper than the shaft's ends.
        p->setBrush(g.color);
        p->setPen(strokePen(g.color, g.headStroke, Qt::RoundJoin));
        p->drawPolygon(g.endHead);
        if (!g.startHead.isEmpty())
            p->drawPolygon(g.startHead);
        return;
    }
    }
}

} // namespace

void paintLayers(QPainter *painter, const Layers &layers)
{
    painter->save();
    painter->setRenderHint(QPainter::Antialiasing, true);
    for (const Layer &layer : layers)
        paintShape(painter, shapeGeometry(layer));
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
    for (const QString &key : original.textKeys())
        out.setText(key, original.text(key)); // the capture's own metadata (its scale) stays in the file
    return out;
}

} // namespace screenshot
