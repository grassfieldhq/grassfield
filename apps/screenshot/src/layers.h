#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QStringList>

// The layers of an edited picture and their file, layers.json version 1 (ADR-0066 D-4 and D-5):
//   {"v": 1, "layers": [{"id": 1, "type": "rectangle", ...the tool's own fields}, ...]}
// The model is a list of vector layers over the original picture, back to front. The tools (slices B3 to B9) each own the
// fields of their layer type; this file validates only what every layer shares (id, type) and the bounds of the whole, so that
// a hostile or corrupt file never reaches a tool. A file of another version is refused as a whole and never rewritten.
namespace screenshot {

constexpr int kLayersVersion = 1;
constexpr int kMaxLayers = 2000;
constexpr qint64 kMaxLayersBytes = 4 * 1024 * 1024;

struct Layer {
    int id = 0;          // 1 or more, unique in the document
    QString type;        // one of layerTypes()
    QJsonObject fields;  // everything else of the layer, as the tool wrote it ("id" and "type" are not in here)

    bool operator==(const Layer &other) const { return id == other.id && type == other.type && fields == other.fields; }
    bool operator!=(const Layer &other) const { return !(*this == other); }
};
using Layers = QList<Layer>;

// The layer types of the tool group (docs/specs/capture-suite.md §3.3), "image" (a dropped picture, slice B27) and "frame" (slice B8:
// the crop, rotation and flip of the picture itself, at most one per document; framing.h).
QStringList layerTypes();

// The file's bytes for `layers` (compact JSON, keys sorted: the same layers always give the same bytes).
QByteArray layersToJson(const Layers &layers);

// Parses and validates a layers file. False with `error` set when the bytes are not valid JSON, hold more than kMaxLayersBytes,
// are not a version-1 document, hold more than kMaxLayers layers, a layer that is not an object, an id that is not an integer of
// 1 or more or is repeated, or a type that is not in layerTypes(). `layers` is empty on failure.
bool layersFromJson(const QByteArray &bytes, Layers *layers, QString *error = nullptr);

} // namespace screenshot
