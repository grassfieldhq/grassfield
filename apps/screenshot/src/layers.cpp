#include "layers.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QSet>

namespace screenshot {

QStringList layerTypes()
{
    return {QStringLiteral("arrow"),    QStringLiteral("line"),      QStringLiteral("rectangle"), QStringLiteral("ellipse"),
            QStringLiteral("pen"),      QStringLiteral("highlighter"), QStringLiteral("text"),    QStringLiteral("counter"),
            QStringLiteral("redact"),   QStringLiteral("pixelate"),  QStringLiteral("blur"),      QStringLiteral("spotlight"),
            QStringLiteral("image"),
            QStringLiteral("frame")};
}

QByteArray layersToJson(const Layers &layers)
{
    QJsonArray array;
    for (const Layer &layer : layers) {
        QJsonObject object = layer.fields;
        object.insert(QStringLiteral("id"), layer.id);
        object.insert(QStringLiteral("type"), layer.type);
        array.append(object);
    }
    const QJsonObject root{{QStringLiteral("v"), kLayersVersion}, {QStringLiteral("layers"), array}};
    return QJsonDocument(root).toJson(QJsonDocument::Compact);
}

bool layersFromJson(const QByteArray &bytes, Layers *layers, QString *error)
{
    layers->clear();
    const auto fail = [error](const QString &why) {
        if (error)
            *error = why;
        return false;
    };
    if (bytes.size() > kMaxLayersBytes)
        return fail(QStringLiteral("layers file too large"));
    QJsonParseError parse;
    const QJsonDocument doc = QJsonDocument::fromJson(bytes, &parse);
    if (parse.error != QJsonParseError::NoError || !doc.isObject())
        return fail(QStringLiteral("layers file is not a JSON object"));
    const QJsonObject root = doc.object();
    const QJsonValue version = root.value(QStringLiteral("v"));
    if (!version.isDouble() || version.toDouble() != kLayersVersion)
        return fail(QStringLiteral("unsupported layers file version"));
    const QJsonValue list = root.value(QStringLiteral("layers"));
    if (!list.isArray())
        return fail(QStringLiteral("layers is not a list"));
    const QJsonArray array = list.toArray();
    if (array.size() > kMaxLayers)
        return fail(QStringLiteral("too many layers"));

    const QStringList types = layerTypes();
    QSet<int> seen;
    Layers parsed;
    parsed.reserve(array.size());
    for (const QJsonValue &value : array) {
        if (!value.isObject())
            return fail(QStringLiteral("a layer is not an object"));
        QJsonObject object = value.toObject();
        const QJsonValue id = object.take(QStringLiteral("id"));
        const double idNumber = id.toDouble();
        if (!id.isDouble() || idNumber < 1 || idNumber > 2147483647.0 || idNumber != double(int(idNumber)))
            return fail(QStringLiteral("a layer has no valid id"));
        if (seen.contains(int(idNumber)))
            return fail(QStringLiteral("a layer id is repeated"));
        seen.insert(int(idNumber));
        const QJsonValue type = object.take(QStringLiteral("type"));
        if (!type.isString() || !types.contains(type.toString()))
            return fail(QStringLiteral("a layer has an unknown type"));
        parsed.append(Layer{int(idNumber), type.toString(), object});
    }
    *layers = parsed;
    return true;
}

} // namespace screenshot
