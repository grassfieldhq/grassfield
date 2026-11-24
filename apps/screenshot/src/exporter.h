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

// Whether the export of `layers` hides pixels of the picture (a Redact, a Pixelate or a Blur): such an export also drops the original's text
// chunks but its scale, and the app puts the exported picture on the clipboard in place of the automatic copy (ADR-0066 D-9).
bool hidesPixels(const Layers &layers);

// The picture's part under the Pixelate or Blur (or Redact) layer `id` as the export draws it (its area clipped to the picture), from the framed
// picture and the layers: what the editor shows for the layer, made by the same code as the file. A null image for any other layer.
QImage regionPatch(const QImage &framed, const Layers &layers, int id);

} // namespace screenshot
