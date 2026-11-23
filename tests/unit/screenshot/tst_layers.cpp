// layers.json version 1 (slice B2): the schema round trip and what the reader refuses.
#include "layers.h"

#include <QJsonArray>
#include <QJsonDocument>

#include <gtest/gtest.h>

using namespace screenshot;

namespace {

Layer layer(int id, const QString &type, const QJsonObject &fields = {})
{
    return Layer{id, type, fields};
}

Layers sample()
{
    return {layer(1, "rectangle", {{"x", 10}, {"y", 20}, {"w", 100}, {"h", 50}, {"color", "#ff0000"}, {"fill", false}}),
            layer(2, "arrow", {{"from", QJsonArray{1, 2}}, {"to", QJsonArray{30, 40}}, {"style", "curved"}}),
            layer(7, "text", {{"text", "Grüße \"quoted\"\n2nd line"}, {"size", 14.5}}),
            layer(9, "redact", {{"rect", QJsonObject{{"x", 0}, {"y", 0}, {"w", 8}, {"h", 8}}}})};
}

} // namespace

TEST(Layers, SchemaRoundTrip)
{
    const Layers in = sample();
    const QByteArray bytes = layersToJson(in);
    Layers out;
    QString why;
    ASSERT_TRUE(layersFromJson(bytes, &out, &why)) << why.toStdString();
    ASSERT_EQ(out.size(), in.size());
    for (int i = 0; i < in.size(); ++i) {
        EXPECT_EQ(out[i].id, in[i].id);
        EXPECT_EQ(out[i].type, in[i].type);
        EXPECT_EQ(out[i].fields, in[i].fields) << i;
    }
    EXPECT_EQ(layersToJson(out), bytes) << "the same layers always give the same bytes";
}

TEST(Layers, EmptyDocumentRoundTrips)
{
    const QByteArray bytes = layersToJson({});
    EXPECT_EQ(bytes, QByteArray("{\"layers\":[],\"v\":1}"));
    Layers out{layer(1, "line")};
    ASSERT_TRUE(layersFromJson(bytes, &out));
    EXPECT_TRUE(out.isEmpty());
}

TEST(Layers, FileShape)
{
    const QJsonObject root = QJsonDocument::fromJson(layersToJson(sample())).object();
    EXPECT_EQ(root.value("v").toInt(), 1);
    const QJsonArray array = root.value("layers").toArray();
    ASSERT_EQ(array.size(), 4);
    EXPECT_EQ(array[0].toObject().value("id").toInt(), 1);
    EXPECT_EQ(array[0].toObject().value("type").toString(), "rectangle");
    EXPECT_EQ(array[0].toObject().value("color").toString(), "#ff0000") << "the tool's fields sit beside id and type";
}

TEST(Layers, EveryToolTypeIsKnown)
{
    for (const char *t : {"arrow", "line", "rectangle", "ellipse", "pen", "highlighter", "text", "counter", "redact", "pixelate", "blur",
                          "spotlight", "image"})
        EXPECT_TRUE(layerTypes().contains(QString::fromLatin1(t))) << t;
}

TEST(Layers, RefusedInputs)
{
    const auto refused = [](const QByteArray &bytes) {
        Layers out{layer(1, "line")};
        QString why;
        const bool ok = layersFromJson(bytes, &out, &why);
        return !ok && !why.isEmpty() && out.isEmpty();
    };
    EXPECT_TRUE(refused(""));
    EXPECT_TRUE(refused("not json"));
    EXPECT_TRUE(refused("[]"));
    EXPECT_TRUE(refused("{}"));
    EXPECT_TRUE(refused("{\"v\":2,\"layers\":[]}")) << "another version is refused whole";
    EXPECT_TRUE(refused("{\"v\":\"1\",\"layers\":[]}"));
    EXPECT_TRUE(refused("{\"v\":1}"));
    EXPECT_TRUE(refused("{\"v\":1,\"layers\":{}}"));
    EXPECT_TRUE(refused("{\"v\":1,\"layers\":[5]}"));
    EXPECT_TRUE(refused("{\"v\":1,\"layers\":[{\"type\":\"line\"}]}")) << "no id";
    EXPECT_TRUE(refused("{\"v\":1,\"layers\":[{\"id\":0,\"type\":\"line\"}]}"));
    EXPECT_TRUE(refused("{\"v\":1,\"layers\":[{\"id\":-3,\"type\":\"line\"}]}"));
    EXPECT_TRUE(refused("{\"v\":1,\"layers\":[{\"id\":1.5,\"type\":\"line\"}]}"));
    EXPECT_TRUE(refused("{\"v\":1,\"layers\":[{\"id\":\"1\",\"type\":\"line\"}]}"));
    EXPECT_TRUE(refused("{\"v\":1,\"layers\":[{\"id\":99999999999,\"type\":\"line\"}]}"));
    EXPECT_TRUE(refused("{\"v\":1,\"layers\":[{\"id\":1}]}")) << "no type";
    EXPECT_TRUE(refused("{\"v\":1,\"layers\":[{\"id\":1,\"type\":\"laser\"}]}"));
    EXPECT_TRUE(refused("{\"v\":1,\"layers\":[{\"id\":1,\"type\":5}]}"));
    EXPECT_TRUE(refused("{\"v\":1,\"layers\":[{\"id\":1,\"type\":\"line\"},{\"id\":1,\"type\":\"arrow\"}]}")) << "repeated id";
}

TEST(Layers, BoundsOfTheWhole)
{
    Layers many;
    for (int i = 1; i <= kMaxLayers; ++i)
        many.append(layer(i, "line"));
    Layers out;
    EXPECT_TRUE(layersFromJson(layersToJson(many), &out));
    EXPECT_EQ(out.size(), kMaxLayers);
    many.append(layer(kMaxLayers + 1, "line"));
    EXPECT_FALSE(layersFromJson(layersToJson(many), &out));
    EXPECT_TRUE(out.isEmpty());
    const QByteArray big(int(kMaxLayersBytes) + 1, ' ');
    EXPECT_FALSE(layersFromJson(big, &out));
}
