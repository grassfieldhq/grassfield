#pragma once

#include "annotations.h"

#include <QColor>
#include <QImage>
#include <QPoint>
#include <QRect>

// The pixel operations of the region tools (slice B7; ADR-0066 D-9), on a picture of format ARGB32 premultiplied. They are the whole of
// what Redact, Pixelate and Blur do to a picture, called by the exporter and by the editor's preview, so that the screen shows exactly
// what the file holds.
//
//   Redact    every pixel of the area is the fill, opaque (alpha 255, whatever the source's alpha was). Nothing of the source remains.
//   Pixelate  the picture is cut in square blocks of `block` pixels (at least kMinPixelateBlock) on a grid whose offset comes from the
//             seed; each block of the area becomes ONE colour: the mean of the block's source pixels (the whole block, also the part
//             outside the area, so that a sliver of one pixel is still the mean of a full block) plus a per-block, per-channel noise
//             of at most kPixelateNoise levels (a term shared by the three channels, kPixelateLuma at most, and one of each), opaque. The output inside a block therefore depends on the source only through the
//             block's mean, and the noise depends on the seed and the block's place only.
//   Blur      three box passes (a Gaussian of `sigma`) over the area, reading the picture around it. Blur is NOT redaction: it keeps
//             enough of the picture to be undone in part, and the tools say so.
//
// An `area` is in the picture's pixels and is clipped to it. `origin` is the place of the image's top left in the picture (for an image
// that is a part of the picture: the grid and the area stay the picture's); the part must hold every block and margin the operation reads
// (regionContext below).
namespace screenshot {

constexpr int kPixelateNoise = 12; // the most a channel of a block is moved by its noise, in levels of 255
constexpr int kPixelateLuma = 8;   // of which a share common to the three channels (the rest is each channel's own)

void redactArea(QImage *image, const QRect &area, const QColor &fill, const QPoint &origin = QPoint());
void pixelateArea(QImage *image, const QRect &area, int block, quint64 seed, const QPoint &origin = QPoint());
void blurArea(QImage *image, const QRect &area, qreal sigma, const QPoint &origin = QPoint());

// The grid offset of a pixelate seed, in [0, block).
QPoint pixelateOffset(quint64 seed, int block);
// The noise of one block, per channel red, green, blue, in [-kPixelateNoise, kPixelateNoise].
void pixelateNoise(quint64 seed, int blockX, int blockY, int noise[3]);

// The rectangle of the picture that the geometry `g` of a region layer reads (the blocks the area touches, the blur's margin), clipped to
// `picture`; the area itself for Redact and Spotlight.
QRect regionContext(const ShapeGeometry &g, const QRect &picture);

// `g` applied to `image` (a Redact, a Pixelate or a Blur; false for any other kind, which is not a pixel operation).
bool applyRegion(QImage *image, const ShapeGeometry &g, const QPoint &origin = QPoint());

} // namespace screenshot
