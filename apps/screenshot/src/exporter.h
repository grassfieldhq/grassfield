#pragma once

#include "layers.h"

#include <QImage>
#include <QPainter>

// The exporter of the editor (ADR-0066 D-3; slice B3): the layers drawn over the original picture with QPainter, at the picture's
// own device pixels. It reads nothing but its two arguments (no font, no theme, no setting), so the same layers on the same
// picture give the same pixels, which the golden tests rely on (text and counters are drawn from glyph outlines of the font the
// layer names, so a golden of text depends on that font being installed). Layers are drawn back to front; a layer of a type this
// build does not draw yet (slices B7 to B9 add theirs) or whose fields do not read is skipped. A frame layer (framing.h) makes the
// picture the cropped, turned and mirrored original first.
namespace screenshot {

// Draws `layers` on `painter`, in picture pixels (the caller sets the painter's transform for any scale).
void paintLayers(QPainter *painter, const Layers &layers);

// `original` with the layers drawn on it, in the original's format (RGB32 stays opaque, a picture with alpha keeps it). No layers
// give a copy of the original. A null original gives a null image.
QImage exportLayers(const QImage &original, const Layers &layers);

} // namespace screenshot
