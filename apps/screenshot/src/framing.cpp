#include "framing.h"

#include <QJsonArray>
#include <QLineF>

#include <algorithm>
#include <cmath>
#include <functional>

namespace screenshot {

namespace {

constexpr int kMaxFrameCoordinate = 1 << 20;

bool readInt(const QJsonObject &fields, const char *key, int *out, int lo, int hi)
{
    const QJsonValue v = fields.value(QLatin1String(key));
    if (!v.isDouble())
        return false;
    const double d = v.toDouble();
    if (!std::isfinite(d) || d != std::floor(d) || d < lo || d > hi)
        return false;
    *out = int(d);
    return true;
}

bool readFrame(const Layer &layer, Frame *frame)
{
    if (layer.type != QLatin1String("frame"))
        return false;
    Frame f;
    int x, y, w, h;
    const bool hasCrop = layer.fields.contains(QStringLiteral("x")) || layer.fields.contains(QStringLiteral("y"))
        || layer.fields.contains(QStringLiteral("w")) || layer.fields.contains(QStringLiteral("h"));
    if (hasCrop) {
        if (!readInt(layer.fields, "x", &x, 0, kMaxFrameCoordinate) || !readInt(layer.fields, "y", &y, 0, kMaxFrameCoordinate)
            || !readInt(layer.fields, "w", &w, 1, kMaxFrameCoordinate) || !readInt(layer.fields, "h", &h, 1, kMaxFrameCoordinate))
            return false;
        f.crop = QRect(x, y, w, h);
    }
    if (layer.fields.contains(QStringLiteral("rot")) && !readInt(layer.fields, "rot", &f.rot, 0, 3))
        return false;
    const QJsonValue flip = layer.fields.value(QStringLiteral("flip"));
    if (layer.fields.contains(QStringLiteral("flip")) && !flip.isBool())
        return false;
    f.flip = flip.toBool(false);
    *frame = f;
    return true;
}

QRect effectiveCrop(const QSize &original, const Frame &frame)
{
    const QRect whole(QPoint(0, 0), original);
    return frame.crop.isNull() ? whole : frame.crop.intersected(whole);
}

// A point of the framed picture as a point of the original (continuous coordinates: a pixel's corner stays a corner).
QPointF framedToOriginal(const QSize &original, const Frame &frame, QPointF p)
{
    const QRect crop = effectiveCrop(original, frame);
    // The size after the rotation, then back through the mirror and each turn.
    qreal width = (frame.rot % 2) ? crop.height() : crop.width();
    qreal height = (frame.rot % 2) ? crop.width() : crop.height();
    if (frame.flip)
        p.setX(width - p.x());
    for (int i = 0; i < frame.rot; ++i) {
        // One clockwise turn took (x, y) of a (height' x width') picture to (height' - y, x): back through it.
        p = QPointF(p.y(), width - p.x());
        std::swap(width, height);
    }
    return p + crop.topLeft();
}

Frame withTurns(Frame frame, int turns)
{
    for (int i = 0; i < ((turns % 4) + 4) % 4; ++i)
        frame.rot = frame.flip ? (frame.rot + 3) % 4 : (frame.rot + 1) % 4;
    return frame;
}

Layer movedLayer(const Layer &layer, const std::function<QPointF(const QPointF &)> &map, int turns)
{
    if (layer.type == QLatin1String("frame"))
        return layer;
    Layer out = layer;
    QJsonObject &f = out.fields;
    const auto number = [&f](const char *key, double *v) {
        const QJsonValue value = f.value(QLatin1String(key));
        if (!value.isDouble())
            return false;
        *v = value.toDouble();
        return true;
    };
    double x, y, w, h;
    if (number("x", &x) && number("y", &y) && number("w", &w) && number("h", &h)) {
        const QRectF box = QRectF(map(QPointF(x, y)), map(QPointF(x + w, y + h))).normalized();
        f.insert(QStringLiteral("x"), box.x());
        f.insert(QStringLiteral("y"), box.y());
        f.insert(QStringLiteral("w"), box.width());
        f.insert(QStringLiteral("h"), box.height());
    } else if (number("x", &x) && number("y", &y)) {
        const QPointF to = map(QPointF(x, y)); // a text or a counter: its centre
        f.insert(QStringLiteral("x"), to.x());
        f.insert(QStringLiteral("y"), to.y());
        if (layer.type == QLatin1String("text")) {
            int rot = 0;
            readInt(f, "rot", &rot, 0, 3);
            f.insert(QStringLiteral("rot"), ((rot + turns) % 4 + 4) % 4); // the text turns with the picture; a mirror leaves it readable
        }
    }
    for (const char *key : {"from", "to", "ctrl"}) {
        QPointF point;
        if (readPoint(f, key, &point))
            f.insert(QLatin1String(key), pointArray(map(point)));
    }
    if (f.value(QStringLiteral("points")).isArray()) {
        QJsonArray points;
        for (const QPointF &point : strokePoints(layer))
            points.append(pointArray(map(point)));
        if (!points.isEmpty())
            f.insert(QStringLiteral("points"), points);
    }
    return out;
}

// `layers` with the frame layer replaced by `frame` (none when it is the identity) and the others moved by `map`.
Layers reframed(const Layers &layers, const QSize &original, const Frame &frame, const std::function<QPointF(const QPointF &)> &map, int turns, bool *ok)
{
    const int old = frameIndex(layers);
    int id = old >= 0 ? layers[old].id : nextLayerId(layers);
    *ok = true;
    Layers out;
    const bool identity = frame.isIdentity(original);
    if (!identity) {
        if (id == 0) {
            *ok = false;
            return layers;
        }
        out.append(makeFrame(id, frame));
    }
    for (int i = 0; i < layers.size(); ++i) {
        if (i == old)
            continue;
        out.append(movedLayer(layers[i], map, turns));
    }
    return out;
}

} // namespace

bool Frame::isIdentity(const QSize &original) const
{
    return (crop.isNull() || crop == QRect(QPoint(0, 0), original)) && rot == 0 && !flip;
}

int frameIndex(const Layers &layers)
{
    for (int i = 0; i < layers.size(); ++i) {
        Frame f;
        if (layers[i].type == QLatin1String("frame") && readFrame(layers[i], &f))
            return i;
    }
    return -1;
}

Frame frameOf(const Layers &layers)
{
    const int i = frameIndex(layers);
    Frame f;
    if (i >= 0)
        readFrame(layers[i], &f);
    return f;
}

Layer makeFrame(int id, const Frame &frame)
{
    Layer layer;
    layer.id = id;
    layer.type = QStringLiteral("frame");
    if (!frame.crop.isNull()) {
        layer.fields.insert(QStringLiteral("x"), frame.crop.x());
        layer.fields.insert(QStringLiteral("y"), frame.crop.y());
        layer.fields.insert(QStringLiteral("w"), frame.crop.width());
        layer.fields.insert(QStringLiteral("h"), frame.crop.height());
    }
    layer.fields.insert(QStringLiteral("rot"), frame.rot);
    layer.fields.insert(QStringLiteral("flip"), frame.flip);
    return layer;
}

QSize framedSize(const QSize &original, const Frame &frame)
{
    const QSize crop = effectiveCrop(original, frame).size();
    return (frame.rot % 2) ? QSize(crop.height(), crop.width()) : crop;
}

QImage applyFrame(const QImage &original, const Frame &frame)
{
    if (original.isNull())
        return original;
    if (frame.isIdentity(original.size()))
        return original;
    const QRect crop = effectiveCrop(original.size(), frame);
    if (crop.isEmpty())
        return original;
    // 32 bits per pixel, kept as the original has them (a picture without alpha stays without it); a turn is a copy of whole pixels.
    QImage source = original.copy(crop);
    if (source.format() != QImage::Format_RGB32 && source.format() != QImage::Format_ARGB32 && source.format() != QImage::Format_ARGB32_Premultiplied)
        source = source.convertToFormat(source.hasAlphaChannel() ? QImage::Format_ARGB32 : QImage::Format_RGB32);
    const int w = source.width(), h = source.height();
    QImage out = source;
    if (frame.rot != 0) {
        const bool odd = frame.rot % 2 != 0;
        out = QImage(odd ? h : w, odd ? w : h, source.format());
        for (int y = 0; y < h; ++y) {
            const auto *row = reinterpret_cast<const quint32 *>(source.constScanLine(y));
            for (int x = 0; x < w; ++x) {
                // (x, y) goes to ... 90: (h-1-y, x); 180: (w-1-x, h-1-y); 270: (y, w-1-x)
                const int tx = frame.rot == 1 ? h - 1 - y : frame.rot == 2 ? w - 1 - x : y;
                const int ty = frame.rot == 1 ? x : frame.rot == 2 ? h - 1 - y : w - 1 - x;
                reinterpret_cast<quint32 *>(out.scanLine(ty))[tx] = row[x];
            }
        }
    }
    if (frame.flip) {
        QImage mirrored(out.size(), out.format());
        for (int y = 0; y < out.height(); ++y) {
            const auto *row = reinterpret_cast<const quint32 *>(out.constScanLine(y));
            auto *to = reinterpret_cast<quint32 *>(mirrored.scanLine(y));
            for (int x = 0; x < out.width(); ++x)
                to[out.width() - 1 - x] = row[x];
        }
        out = mirrored;
    }
    out.setDevicePixelRatio(original.devicePixelRatio());
    for (const QString &key : original.textKeys())
        out.setText(key, original.text(key));
    return out;
}

Layers rotatedLayers(const Layers &layers, const QSize &original, int quarterTurns)
{
    const int turns = ((quarterTurns % 4) + 4) % 4;
    if (turns == 0 || original.isEmpty())
        return layers;
    Frame frame = frameOf(layers);
    QSize size = framedSize(original, frame);
    Layers current = layers;
    // One turn at a time: each is its own mapping of points, and a picture of the current size.
    for (int i = 0; i < turns; ++i) {
        const qreal height = size.height();
        bool ok = false;
        frame = withTurns(frame, 1);
        current = reframed(current, original, frame, [height](const QPointF &p) { return QPointF(height - p.y(), p.x()); }, 1, &ok);
        if (!ok)
            return layers;
        size.transpose();
    }
    return current;
}

Layers flippedLayers(const Layers &layers, const QSize &original, bool horizontal)
{
    if (original.isEmpty())
        return layers;
    Frame frame = frameOf(layers);
    const QSize size = framedSize(original, frame);
    const qreal width = size.width(), height = size.height();
    bool ok = false;
    if (horizontal) {
        frame.flip = !frame.flip;
        const Layers out = reframed(layers, original, frame, [width](const QPointF &p) { return QPointF(width - p.x(), p.y()); }, 0, &ok);
        return ok ? out : layers;
    }
    // A mirror from top to bottom is a half turn and a mirror from left to right.
    frame = withTurns(frame, 2);
    frame.flip = !frame.flip;
    const Layers out = reframed(layers, original, frame, [height](const QPointF &p) { return QPointF(p.x(), height - p.y()); }, 0, &ok);
    return ok ? out : layers;
}

Layers croppedLayers(const Layers &layers, const QSize &original, const QRect &rect)
{
    Frame frame = frameOf(layers);
    const QSize size = framedSize(original, frame);
    const QRect within = rect.intersected(QRect(QPoint(0, 0), size));
    if (within.isEmpty() || within == QRect(QPoint(0, 0), size))
        return layers;
    const QRectF cropped = QRectF(framedToOriginal(original, frame, within.topLeft()),
                                  framedToOriginal(original, frame, QPointF(within.x() + within.width(), within.y() + within.height())))
                               .normalized();
    frame.crop = QRect(qRound(cropped.x()), qRound(cropped.y()), qRound(cropped.width()), qRound(cropped.height()));
    bool ok = false;
    const QPointF origin = within.topLeft();
    const Layers out = reframed(layers, original, frame, [origin](const QPointF &p) { return p - origin; }, 0, &ok);
    return ok ? out : layers;
}

// ---- the crop rectangle -------------------------------------------------------------------------------------------------------------

QStringList cropAspects()
{
    return {QStringLiteral("free"), QStringLiteral("original"), QStringLiteral("1:1"), QStringLiteral("4:3"),
            QStringLiteral("3:2"),  QStringLiteral("16:9"),     QStringLiteral("9:16")};
}

qreal aspectRatio(const QString &name, const QSizeF &picture)
{
    if (name == QLatin1String("original"))
        return picture.height() > 0 ? picture.width() / picture.height() : 0;
    if (name == QLatin1String("1:1"))
        return 1;
    if (name == QLatin1String("4:3"))
        return 4.0 / 3;
    if (name == QLatin1String("3:2"))
        return 3.0 / 2;
    if (name == QLatin1String("16:9"))
        return 16.0 / 9;
    if (name == QLatin1String("9:16"))
        return 9.0 / 16;
    return 0;
}

QRectF fitAspect(const QRectF &rect, qreal ratio)
{
    if (ratio <= 0 || rect.isEmpty())
        return rect;
    qreal w = rect.width(), h = w / ratio;
    if (h > rect.height()) {
        h = rect.height();
        w = h * ratio;
    }
    return QRectF(rect.center().x() - w / 2, rect.center().y() - h / 2, w, h);
}

QList<Handle> cropHandles(const QRectF &crop)
{
    const QPointF c = crop.center();
    return {{Handle::TopLeft, crop.topLeft()},         {Handle::Top, QPointF(c.x(), crop.top())},
            {Handle::TopRight, crop.topRight()},       {Handle::Right, QPointF(crop.right(), c.y())},
            {Handle::BottomRight, crop.bottomRight()}, {Handle::Bottom, QPointF(c.x(), crop.bottom())},
            {Handle::BottomLeft, crop.bottomLeft()},   {Handle::Left, QPointF(crop.left(), c.y())}};
}

QRectF draggedCrop(const QRectF &crop, Handle::Kind kind, const QPointF &to, const QRectF &bounds, qreal ratio)
{
    const qreal minSide = std::min({kMinCrop, bounds.width(), bounds.height()});
    const bool left = kind == Handle::TopLeft || kind == Handle::Left || kind == Handle::BottomLeft;
    const bool right = kind == Handle::TopRight || kind == Handle::Right || kind == Handle::BottomRight;
    const bool top = kind == Handle::TopLeft || kind == Handle::Top || kind == Handle::TopRight;
    const bool bottom = kind == Handle::BottomLeft || kind == Handle::Bottom || kind == Handle::BottomRight;
    const QPointF c = crop.center();
    // The edges as they stand, the dragged ones moved to the pointer (within the bounds, and a side never smaller than minSide).
    qreal l = crop.left(), r = crop.right(), t = crop.top(), b = crop.bottom();
    if (left)
        l = std::clamp(to.x(), bounds.left(), r - minSide);
    if (right)
        r = std::clamp(to.x(), l + minSide, bounds.right());
    if (top)
        t = std::clamp(to.y(), bounds.top(), b - minSide);
    if (bottom)
        b = std::clamp(to.y(), t + minSide, bounds.bottom());
    if (ratio <= 0)
        return QRectF(QPointF(l, t), QPointF(r, b));

    const bool horizontal = left || right, vertical = top || bottom;
    qreal w = r - l, h = b - t;
    if (horizontal && vertical) {
        // A corner: the side the pointer went farther along rules, the opposite corner stays.
        const qreal fromW = w, fromH = h * ratio;
        w = std::max(fromW, fromH);
        // The room the opposite corner leaves in the direction of the drag.
        const qreal roomW = left ? r - bounds.left() : bounds.right() - l;
        const qreal roomH = top ? b - bounds.top() : bounds.bottom() - t;
        w = std::min({w, roomW, roomH * ratio});
        w = std::max(w, std::max(minSide, minSide * ratio));
        h = w / ratio;
        return QRectF(left ? r - w : l, top ? b - h : t, w, h);
    }
    if (horizontal) {
        // A side: it sets the width, the height follows on the middle.
        const qreal roomW = left ? r - bounds.left() : bounds.right() - l;
        const qreal roomH = 2 * std::min(c.y() - bounds.top(), bounds.bottom() - c.y());
        w = std::max(std::min({w, roomW, roomH * ratio}), std::max(minSide, minSide * ratio));
        h = w / ratio;
        return QRectF(left ? r - w : l, c.y() - h / 2, w, h);
    }
    const qreal roomH = top ? b - bounds.top() : bounds.bottom() - t;
    const qreal roomW = 2 * std::min(c.x() - bounds.left(), bounds.right() - c.x());
    h = std::max(std::min({h, roomH, roomW / ratio}), std::max(minSide, minSide / ratio));
    w = h * ratio;
    return QRectF(c.x() - w / 2, top ? b - h : t, w, h);
}

void CropEditor::reset(const QSizeF &picture)
{
    m_picture = picture;
    m_rect = QRectF(QPointF(0, 0), picture);
    m_mode = Mode::None;
    m_aspect = QStringLiteral("free");
}

bool CropEditor::setAspect(const QString &name)
{
    if (!cropAspects().contains(name))
        return false;
    m_aspect = name;
    m_mode = Mode::None;
    m_rect = fitAspect(m_rect, ratio());
    return true;
}

bool CropEditor::press(const QPointF &p, qreal tolerance)
{
    if (m_picture.isEmpty())
        return false;
    m_start = p;
    m_origin = m_rect;
    const QRectF bounds(QPointF(0, 0), m_picture);
    // The handles first (the last of the list wins a tie, as the topmost drawn), then the inside, else a new rectangle.
    const QList<Handle> handles = cropHandles(m_rect);
    for (int i = handles.size() - 1; i >= 0; --i) {
        if (QLineF(handles[i].pos, p).length() <= tolerance) {
            m_mode = Mode::Resize;
            m_handle = handles[i].kind;
            return true;
        }
    }
    if (m_rect.contains(p)) {
        m_mode = Mode::Move;
        return true;
    }
    m_mode = bounds.contains(p) ? Mode::Draw : Mode::None;
    return m_mode != Mode::None;
}

void CropEditor::move(const QPointF &p)
{
    const QRectF bounds(QPointF(0, 0), m_picture);
    switch (m_mode) {
    case Mode::None:
        return;
    case Mode::Move: {
        QPointF d = p - m_start;
        d.setX(std::clamp(d.x(), bounds.left() - m_origin.left(), bounds.right() - m_origin.right()));
        d.setY(std::clamp(d.y(), bounds.top() - m_origin.top(), bounds.bottom() - m_origin.bottom()));
        m_rect = m_origin.translated(d);
        return;
    }
    case Mode::Resize:
        m_rect = draggedCrop(m_origin, m_handle, p, bounds, ratio());
        return;
    case Mode::Draw: {
        // A rectangle from the press to the pointer: the corner of the same direction drags out from a point.
        const QPointF q(std::clamp(p.x(), bounds.left(), bounds.right()), std::clamp(p.y(), bounds.top(), bounds.bottom()));
        const Handle::Kind kind = q.x() >= m_start.x() ? (q.y() >= m_start.y() ? Handle::BottomRight : Handle::TopRight)
                                                       : (q.y() >= m_start.y() ? Handle::BottomLeft : Handle::TopLeft);
        qreal w = std::abs(q.x() - m_start.x()), h = std::abs(q.y() - m_start.y());
        if (w < 1e-6 && h < 1e-6) {
            m_rect = m_origin;
            return;
        }
        QRectF box(QPointF(std::min(q.x(), m_start.x()), std::min(q.y(), m_start.y())), QSizeF(w, h));
        if (ratio() > 0) {
            const qreal roomW = (kind == Handle::TopLeft || kind == Handle::BottomLeft) ? m_start.x() - bounds.left() : bounds.right() - m_start.x();
            const qreal roomH = (kind == Handle::TopLeft || kind == Handle::TopRight) ? m_start.y() - bounds.top() : bounds.bottom() - m_start.y();
            w = std::min({std::max(w, h * ratio()), roomW, roomH * ratio()});
            h = w / ratio();
            const qreal x = (kind == Handle::TopLeft || kind == Handle::BottomLeft) ? m_start.x() - w : m_start.x();
            const qreal y = (kind == Handle::TopLeft || kind == Handle::TopRight) ? m_start.y() - h : m_start.y();
            box = QRectF(x, y, w, h);
        }
        m_rect = box;
        return;
    }
    }
}

void CropEditor::release(const QPointF &p)
{
    if (m_mode == Mode::None)
        return;
    move(p);
    // A rectangle drawn smaller than the least goes back to what it was.
    if (m_rect.width() < kMinCrop || m_rect.height() < kMinCrop)
        m_rect = m_origin;
    m_mode = Mode::None;
}

void CropEditor::cancel()
{
    if (m_mode != Mode::None)
        m_rect = m_origin;
    m_mode = Mode::None;
}

QRect CropEditor::pixelRect() const
{
    const QRect whole(QPoint(0, 0), m_picture.toSize());
    QRect r(QPoint(qRound(m_rect.left()), qRound(m_rect.top())), QPoint(qRound(m_rect.right()) - 1, qRound(m_rect.bottom()) - 1));
    r = r.intersected(whole);
    if (r.width() < 1)
        r.setWidth(1);
    if (r.height() < 1)
        r.setHeight(1);
    return r.intersected(whole);
}

bool CropEditor::changes() const
{
    return pixelRect() != QRect(QPoint(0, 0), m_picture.toSize());
}

} // namespace screenshot
