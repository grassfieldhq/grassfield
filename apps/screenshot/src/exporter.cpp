#include "exporter.h"

#include "annotations.h"
#include "framing.h"
#include "redaction.h"

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
    case ShapeGeometry::Redact:
    case ShapeGeometry::Pixelate:
    case ShapeGeometry::Blur:
        return; // pixel operations on the picture (renderLayers), not strokes
    case ShapeGeometry::Spotlight:
        p->setPen(Qt::NoPen);
        p->setBrush(g.color);
        p->drawPath(g.path); // whole-pixel edges: nothing is blended along the area's border
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

namespace {

bool isPixelRegion(ShapeGeometry::Kind kind)
{
    return kind == ShapeGeometry::Redact || kind == ShapeGeometry::Pixelate || kind == ShapeGeometry::Blur;
}

// The first `count` layers on `work` (ARGB32 premultiplied; `origin` is the place of its top left in the picture): the vector layers with a
// painter, the three pixel regions as operations on the pixels in between, in layer order (a pixelate reads what the layers before it drew).
void renderLayers(QImage *work, const Layers &layers, int count, const QPoint &origin)
{
    const QList<int> numbers = counterNumbers(layers);
    // Every Redact of the document is filled in first, before anything reads a pixel: a Blur or a Pixelate that comes earlier in the layer
    // order (or any later reader) must never see the pixels a Redact hides, or it would spread them outside the box. The Redact's own turn
    // below fills it again, over whatever was drawn on it in between. Redacted pixels never exist in a buffer that another layer reads.
    for (int j = 0; j < layers.size(); ++j) {
        const ShapeGeometry r = shapeGeometry(layers[j], numbers[j]);
        if (r.kind == ShapeGeometry::Redact)
            applyRegion(work, r, origin);
    }
    int i = 0;
    while (i < count) {
        const ShapeGeometry g = shapeGeometry(layers[i], numbers[i]);
        if (isPixelRegion(g.kind)) {
            applyRegion(work, g, origin);
            ++i;
            continue;
        }
        QPainter painter(work);
        painter.setRenderHint(QPainter::Antialiasing, true);
        painter.translate(-origin);
        for (; i < count; ++i) {
            const ShapeGeometry h = shapeGeometry(layers[i], numbers[i]);
            if (isPixelRegion(h.kind))
                break;
            paintShape(&painter, h);
        }
    }
}

} // namespace

bool hidesPixels(const Layers &layers)
{
    for (const Layer &layer : layers) {
        if (layer.type == QLatin1String("redact") || layer.type == QLatin1String("pixelate") || layer.type == QLatin1String("blur"))
            return true;
    }
    return false;
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
    renderLayers(&work, layers, int(layers.size()), QPoint());
    // Back to the original's format: a picture without alpha stays without it.
    const QImage::Format back = original.hasAlphaChannel() ? QImage::Format_ARGB32 : QImage::Format_RGB32;
    // Through a view of the pixels alone: a conversion of `work` itself would carry its text chunks along (the original's), and a file that
    // hides pixels must carry only the ones it chooses below.
    const QImage bare(work.constBits(), work.width(), work.height(), work.bytesPerLine(), work.format());
    QImage out = bare.convertToFormat(back);
    out.setDevicePixelRatio(original.devicePixelRatio());
    // The capture's own metadata (its scale) stays in the file. A file that hides pixels keeps no other text chunk of the original's (a
    // description, a preview, anything a tool left there could hold what the layers hide).
    const bool redacting = hidesPixels(layers);
    for (const QString &key : original.textKeys()) {
        if (!redacting || key == QLatin1String("Grassfield-Scale"))
            out.setText(key, original.text(key));
    }
    return out;
}

QImage regionPatch(const QImage &framed, const Layers &layers, int id)
{
    int at = -1;
    for (int i = 0; i < layers.size(); ++i) {
        if (layers[i].id == id)
            at = i;
    }
    if (framed.isNull() || at < 0)
        return {};
    const QList<int> numbers = counterNumbers(layers);
    const ShapeGeometry g = shapeGeometry(layers[at], numbers[at]);
    if (!isPixelRegion(g.kind))
        return {};
    const QRect picture(QPoint(), framed.size());
    const QRect area = g.area.intersected(picture);
    if (area.isEmpty())
        return {};
    // What the layers before this one draw over the part of the picture the region reads; with another pixel region before it, the whole
    // picture is rendered (that region's reach is not this one's).
    bool earlierRegion = false;
    for (int i = 0; i < at; ++i)
        earlierRegion = earlierRegion || isPixelRegion(shapeGeometry(layers[i], numbers[i]).kind);
    const QRect read = earlierRegion ? picture : regionContext(g, picture);
    QImage work = framed.copy(read).convertToFormat(QImage::Format_ARGB32_Premultiplied);
    work.setDevicePixelRatio(1);
    renderLayers(&work, layers, at, read.topLeft());
    applyRegion(&work, g, read.topLeft());
    return work.copy(area.translated(-read.topLeft()));
}

} // namespace screenshot
