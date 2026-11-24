#pragma once

#include "annotations.h"
#include "layers.h"

#include <QImage>
#include <QPointF>
#include <QRect>
#include <QRectF>
#include <QSize>
#include <QSizeF>
#include <QString>
#include <QStringList>

// Crop, rotate and flip (slice B8). They change the picture, not a layer, so the document keeps them as one layer of type "frame"
// (at most one, first in the list) that the undo stack, layers.json, the history and the exporter already carry:
//   frame   "x" "y" "w" "h" the crop, in pixels of the original picture (all four, or none for the whole picture),
//           "rot" quarter turns clockwise after the crop (0 to 3), "flip" mirrored horizontally after the rotation
// The picture the editor shows and the file Done writes is the original framed that way (applyFrame), and every other layer is in
// the framed picture's pixels. An edit (cropping, rotating, flipping) is one list of layers: the frame layer updated, the other layers
// moved to follow the picture; one undo step brings the picture and its layers back together.
namespace screenshot {

struct Frame {
    QRect crop;        // original pixels; null: the whole picture
    int rot = 0;       // 0 to 3
    bool flip = false;

    bool isIdentity(const QSize &original) const;
    bool operator==(const Frame &other) const { return crop == other.crop && rot == other.rot && flip == other.flip; }
    bool operator!=(const Frame &other) const { return !(*this == other); }
};

// Index of the frame layer, -1 for none. A frame layer whose fields do not read is ignored (the whole picture).
int frameIndex(const Layers &layers);
Frame frameOf(const Layers &layers);
Layer makeFrame(int id, const Frame &frame);
// The size of the framed picture (the crop's, turned).
QSize framedSize(const QSize &original, const Frame &frame);
// The original cropped, turned and mirrored, pixel for pixel (no resampling), in a 32-bit format of the original's alpha; its text
// (the capture's scale) and device pixel ratio are kept. A null original gives a null image.
QImage applyFrame(const QImage &original, const Frame &frame);

// The layers after the edit: the frame layer updated (or taken out when it becomes the identity), the others moved with the
// picture. `quarterTurns` is clockwise. Each returns `layers` unchanged when the edit does nothing (a crop of the whole picture,
// an empty crop) or when the ids are used up.
Layers rotatedLayers(const Layers &layers, const QSize &original, int quarterTurns);
Layers flippedLayers(const Layers &layers, const QSize &original, bool horizontal);
// `rect`: pixels of the framed picture (kept within it).
Layers croppedLayers(const Layers &layers, const QSize &original, const QRect &rect);

// ---- the crop rectangle's own editing (the tool's pointer logic, apart from QML so that it is tested) -----------------------------

constexpr qreal kMinCrop = 4; // the smallest side of the crop rectangle, in picture pixels

// "free", "original", "1:1", "4:3", "3:2", "16:9", "9:16".
QStringList cropAspects();
// The width over the height the preset asks for (`picture` for "original"); 0 for "free" and for a name that is not one.
qreal aspectRatio(const QString &name, const QSizeF &picture);
// The largest rectangle of `ratio` within `rect`, on its centre (`rect` itself for ratio 0).
QRectF fitAspect(const QRectF &rect, qreal ratio);
// The eight handles of `crop`.
QList<Handle> cropHandles(const QRectF &crop);
// `crop` with its handle `kind` moved to `to`, kept within `bounds`, at least kMinCrop on a side, and at `ratio` (0: free).
QRectF draggedCrop(const QRectF &crop, Handle::Kind kind, const QPointF &to, const QRectF &bounds, qreal ratio);

// The crop rectangle of the Crop tool: it starts as the whole picture; a press on a handle resizes it, a press inside moves it, a press
// outside draws a new one; the aspect preset keeps its ratio through every gesture.
class CropEditor
{
public:
    // The whole picture, free.
    void reset(const QSizeF &picture);
    const QRectF &rect() const { return m_rect; }
    const QSizeF &picture() const { return m_picture; }
    const QString &aspect() const { return m_aspect; }
    // False for a name that is not a preset. The rectangle is fitted to the new ratio at once.
    bool setAspect(const QString &name);

    bool press(const QPointF &p, qreal tolerance);
    void move(const QPointF &p);
    void release(const QPointF &p);
    void cancel();
    bool busy() const { return m_mode != Mode::None; }

    // The rectangle in whole picture pixels (rounded, within the picture, at least one pixel).
    QRect pixelRect() const;
    // Whether it is not the whole picture.
    bool changes() const;

private:
    enum class Mode { None, Draw, Move, Resize };
    qreal ratio() const { return aspectRatio(m_aspect, m_picture); }

    QSizeF m_picture;
    QRectF m_rect;
    QString m_aspect = QStringLiteral("free");
    Mode m_mode = Mode::None;
    QPointF m_start;
    QRectF m_origin;
    Handle::Kind m_handle = Handle::TopLeft;
};

} // namespace screenshot
