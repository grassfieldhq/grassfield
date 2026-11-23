#pragma once

#include "layers.h"

#include <QImage>
#include <QPainter>
#include <QRectF>
#include <QSize>

// The exporter of the editor (ADR-0066 D-3; slice B3): the layers drawn over the original picture with QPainter, at the picture's
// own device pixels. It reads nothing but its two arguments (no font, no theme, no setting), so the same layers on the same
// picture give the same pixels, which the golden tests rely on. Layers are drawn back to front; a layer of a type this build
// does not draw yet (slices B5 to B9 add theirs) or whose fields do not read is skipped.
namespace screenshot {

// Draws `layers` on `painter`, in picture pixels (the caller sets the painter's transform for any scale).
void paintLayers(QPainter *painter, const Layers &layers);

// `original` with the layers drawn on it, in the original's format (RGB32 stays opaque, a picture with alpha keeps it). No layers
// give a copy of the original. A null original gives a null image.
QImage exportLayers(const QImage &original, const Layers &layers);

// The most pixels the editor's overlay may have on a side and in all: the view's size at device pixels, never the zoomed picture's
// (a 4K capture at 16x would ask for gigabytes, and the scene graph's texture limit is 16384).
constexpr int kMaxOverlaySide = 8192;
constexpr qint64 kMaxOverlayPixels = 16LL * 1024 * 1024;
// `target` brought within those limits (kept as is when it already is; empty stays empty).
QSize clampedOverlaySize(const QSize &target);

// The layers alone on a transparent picture of `target` pixels showing `region` of the picture (picture pixels): the editor's
// view of them, the same drawing as the export, so that what is seen is what is written. `target` is clamped (see above). A null
// image for an empty region or target.
QImage renderOverlayRegion(const Layers &layers, const QRectF &region, const QSize &target);

// The whole picture of `natural` pixels at `target` pixels (renderOverlayRegion over the picture's rectangle).
QImage renderOverlay(const Layers &layers, const QSize &natural, const QSize &target);

} // namespace screenshot
