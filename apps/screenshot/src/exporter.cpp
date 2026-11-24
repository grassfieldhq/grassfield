#include "exporter.h"

#include "annotations.h"
#include "framing.h"

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
    case ShapeGeometry::Stroke: {
        QPen pen = strokePen(g.color, g.width, Qt::RoundJoin);
        pen.setCapStyle(g.flatCap ? Qt::FlatCap : Qt::RoundCap);
        p->setBrush(Qt::NoBrush);
        p->setPen(pen);
        p->drawPath(g.path); // one path, one stroke: a highlighter's overlaps are not darker
        return;
    }
    case ShapeGeometry::Glyphs:
        p->setPen(Qt::NoPen);
        if (!g.plate.isEmpty()) {
            p->setBrush(g.plateColor);
            p->drawPath(g.plate);
        }
        if (g.outlineWidth > 0) {
            p->setBrush(Qt::NoBrush);
            p->setPen(strokePen(g.outlineColor, g.outlineWidth, Qt::RoundJoin));
            p->drawPath(g.path);
            p->setPen(Qt::NoPen);
        }
        p->setBrush(g.ink);
        p->drawPath(g.path);
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
    const QList<int> numbers = counterNumbers(layers);
    for (int i = 0; i < layers.size(); ++i)
        paintShape(painter, shapeGeometry(layers[i], numbers[i]));
    painter->restore();
}

QImage exportLayers(const QImage &original, const Layers &layers)
{
    if (original.isNull() || layers.isEmpty())
        return original;
    // The picture as the frame layer (crop, rotate, flip) leaves it: every other layer is in its pixels.
    const QImage framed = applyFrame(original, frameOf(layers));
    bool anyDrawn = false;
    for (const Layer &layer : layers)
        anyDrawn = anyDrawn || layer.type != QLatin1String("frame");
    if (!anyDrawn)
        return framed; // a crop or a turn alone moves whole pixels: no round trip through another format, nothing to blend
    QImage work = framed.convertToFormat(QImage::Format_ARGB32_Premultiplied);
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
