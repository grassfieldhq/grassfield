// Redact, Pixelate, Blur and Spotlight (slice B7; ADR-0066 D-9): what they do to the pixels, that nothing of a hidden area survives in the
// exported file, that the editor's preview is the export, the tools' gestures, and the clipboard after a redacted export.
#include "annotations.h"
#include "exporter.h"
#include "framing.h"
#include "redaction.h"
#include "screenshotapp.h"
#include "screenshotlogic.h"
#include "toolcontroller.h"
#include "undostack.h"

#include <QBuffer>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSet>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <random>

using namespace screenshot;

namespace {

const QString kSecretText = QStringLiteral("not-a-real-secret-marker");

// A picture of unique-ish colours, none of them the magenta the tests plant as "the secret".
QImage gradient(int w, int h, QImage::Format format = QImage::Format_RGB32)
{
    QImage image(w, h, format);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x)
            image.setPixelColor(x, y, QColor(40 + (x * 3) % 150, 40 + (y * 5) % 150, 40 + ((x + y) * 7) % 150));
    }
    return image;
}

QImage noise(int w, int h, unsigned seed)
{
    std::mt19937 rng(seed);
    QImage image(w, h, QImage::Format_ARGB32_Premultiplied);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const int v = int(rng() % 256);
            image.setPixel(x, y, qRgba(v, v, v, 255));
        }
    }
    return image;
}

Layer region(int id, const QString &type, qreal x, qreal y, qreal w, qreal h, QJsonObject extra = {})
{
    Layer layer;
    layer.id = id;
    layer.type = type;
    layer.fields = extra;
    layer.fields.insert("x", x);
    layer.fields.insert("y", y);
    layer.fields.insert("w", w);
    layer.fields.insert("h", h);
    return layer;
}

QJsonObject pix(int block, const QString &seed)
{
    return QJsonObject{{"block", block}, {"seed", seed}};
}

QByteArray pngBytes(const QImage &image)
{
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    image.save(&buffer, "PNG");
    return bytes;
}

double correlation(const QImage &a, const QImage &b, const QRect &area)
{
    double sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0;
    const double n = double(area.width()) * area.height();
    for (int y = area.top(); y <= area.bottom(); ++y) {
        for (int x = area.left(); x <= area.right(); ++x) {
            const double u = qGray(a.pixel(x, y)), v = qGray(b.pixel(x, y));
            sa += u;
            sb += v;
            saa += u * u;
            sbb += v * v;
            sab += u * v;
        }
    }
    const double cov = sab / n - (sa / n) * (sb / n);
    return cov / std::sqrt((saa / n - (sa / n) * (sa / n)) * (sbb / n - (sb / n) * (sb / n)));
}

} // namespace

// ---- Redact --------------------------------------------------------------------------------------------------------------------------

TEST(Redact, AreaEqualsTheFillExactlyAndNothingElseChanges)
{
    for (const QImage::Format format : {QImage::Format_RGB32, QImage::Format_ARGB32}) {
        const QImage source = gradient(64, 48, format);
        // A box on fractions: the area is the pixels it touches (10..30 by 5..15), the colour's alpha is ignored.
        const Layers layers{region(1, "redact", 10.3, 5.7, 20.2, 10.1, QJsonObject{{"color", "#80336699"}})};
        const QRect area = regionArea(layers[0]);
        ASSERT_EQ(area, QRect(10, 5, 21, 11));
        const QImage out = exportLayers(source, layers);
        ASSERT_EQ(out.size(), source.size());
        for (int y = 0; y < out.height(); ++y) {
            for (int x = 0; x < out.width(); ++x) {
                if (area.contains(x, y))
                    ASSERT_EQ(out.pixelColor(x, y), QColor(0x33, 0x66, 0x99, 255)) << x << "," << y;
                else
                    ASSERT_EQ(out.pixel(x, y), source.pixel(x, y)) << x << "," << y;
            }
        }
    }
}

TEST(Redact, HidesPartiallyTransparentAndFullyTransparentSource)
{
    QImage source(20, 20, QImage::Format_ARGB32);
    for (int y = 0; y < 20; ++y) {
        for (int x = 0; x < 20; ++x)
            source.setPixel(x, y, qRgba(255, 0, 255, (x + y) % 2 ? 0 : 90)); // the secret, half see-through
    }
    const QImage out = exportLayers(source, {region(1, "redact", 0, 0, 20, 20, QJsonObject{{"color", "#000000"}})});
    for (int y = 0; y < 20; ++y) {
        for (int x = 0; x < 20; ++x)
            ASSERT_EQ(out.pixel(x, y), qRgba(0, 0, 0, 255));
    }
    // The same for a pixelate: opaque, and nothing of the magenta (its mean is not near the noise-free secret in a way that matters here:
    // the block's colour is its own mean, which is dark because the source was see-through).
    const QImage px = exportLayers(source, {region(1, "pixelate", 0, 0, 20, 20, pix(12, "00000000000000aa"))});
    for (int y = 0; y < 20; ++y) {
        for (int x = 0; x < 20; ++x)
            ASSERT_EQ(qAlpha(px.pixel(x, y)), 255);
    }
}

TEST(Redact, FailsClosedWhenFieldsDoNotRead)
{
    const QImage source = gradient(40, 40);
    // A colour that does not read: black, never "draws nothing".
    for (const QJsonValue &bad : {QJsonValue(), QJsonValue("red"), QJsonValue(7), QJsonValue("#12")}) {
        QJsonObject fields;
        if (!bad.isUndefined() && !bad.isNull())
            fields.insert("color", bad);
        const QImage out = exportLayers(source, {region(1, "redact", 5, 5, 10, 10, fields)});
        EXPECT_EQ(out.pixel(7, 7), qRgb(0, 0, 0)) << QJsonDocument(fields).toJson().toStdString();
    }
    // A pixelate without a seed or with a bad block still replaces its area (the default block, the seed 0).
    for (const QJsonObject &fields : {QJsonObject{}, QJsonObject{{"block", "x"}, {"seed", 5}}, QJsonObject{{"block", 3}, {"seed", "zz"}}}) {
        const ShapeGeometry g = shapeGeometry(region(1, "pixelate", 5, 5, 20, 20, fields));
        EXPECT_EQ(g.kind, ShapeGeometry::Pixelate);
        EXPECT_GE(g.block, kMinPixelateBlock);
        const QImage out = exportLayers(source, {region(1, "pixelate", 5, 5, 20, 20, fields)});
        EXPECT_NE(out.pixel(10, 10), source.pixel(10, 10));
    }
}

TEST(Redact, ColourChangeDropsTheAlphaAndOtherTypesKeepTheirs)
{
    const Layer redact = region(1, "redact", 0, 0, 5, 5, QJsonObject{{"color", "#000000"}});
    EXPECT_EQ(withColor(redact, "#80ff0000").fields.value("color").toString(), QStringLiteral("#ff0000"));
    EXPECT_EQ(withColor(redact, "#00ff00").fields.value("color").toString(), QStringLiteral("#00ff00"));
    // Blur and the others have no colour.
    const Layer blur = region(2, "blur", 0, 0, 5, 5);
    EXPECT_EQ(withColor(blur, "#ff0000"), blur);
}

// ---- the hidden pixels in the file ----------------------------------------------------------------------------------------------------

TEST(Redact, ExportDropsTheOriginalsTextChunksButItsScale)
{
    QImage source = gradient(30, 30);
    source.setText("Grassfield-Scale", "1.25");
    source.setText("Description", kSecretText);
    source.setText("Comment", kSecretText);
    const QImage plain = exportLayers(source, {makeShape(1, "rectangle", QPointF(1, 1), QPointF(5, 5), [] { ShapeStyle s; s.color = "#ff0000"; return s; }())});
    EXPECT_EQ(plain.text("Description"), kSecretText) << "a file that hides nothing keeps the capture's metadata as before";
    for (const QString &type : {QStringLiteral("redact"), QStringLiteral("pixelate"), QStringLiteral("blur")}) {
        const QImage out = exportLayers(source, {region(1, type, 3, 3, 15, 15)});
        EXPECT_EQ(out.text("Grassfield-Scale"), QStringLiteral("1.25")) << type.toStdString();
        EXPECT_TRUE(out.text("Description").isEmpty()) << type.toStdString();
        EXPECT_TRUE(out.text("Comment").isEmpty()) << type.toStdString();
        EXPECT_FALSE(pngBytes(out).contains(kSecretText.toUtf8())) << type.toStdString();
    }
    // A Spotlight hides nothing.
    EXPECT_FALSE(hidesPixels({region(1, "spotlight", 3, 3, 15, 15)}));
    EXPECT_TRUE(hidesPixels({region(1, "redact", 3, 3, 15, 15)}));
}

TEST(Redact, ThePlantedSecretIsGoneFromEveryRedactedPixelAndTheEncodedFile)
{
    QImage source = gradient(80, 60);
    for (int y = 20; y < 30; ++y) {
        for (int x = 30; x < 50; ++x)
            source.setPixel(x, y, qRgb(255, 0, 255));
    }
    for (const QString &type : {QStringLiteral("redact"), QStringLiteral("pixelate")}) {
        // The box is a little larger than the secret (and on fractions): the secret's own pixels are all inside the area.
        const QImage out = exportLayers(source, {region(1, type, 29.4, 19.4, 21.3, 11.3, type == "pixelate" ? pix(12, "0123456789abcdef") : QJsonObject{})});
        const QImage decoded = QImage::fromData(pngBytes(out), "PNG");
        for (int y = 0; y < decoded.height(); ++y) {
            for (int x = 0; x < decoded.width(); ++x)
                ASSERT_NE(decoded.pixel(x, y) | 0xff000000u, qRgb(255, 0, 255)) << type.toStdString() << " " << x << "," << y;
        }
    }
}

// ---- Pixelate -------------------------------------------------------------------------------------------------------------------------

namespace {

// `source` with the pixels of every cell of the seed's grid (clipped to the picture) permuted within the cell: same block means, other pixels.
QImage shuffledWithinBlocks(const QImage &source, int block, quint64 seed, unsigned rngSeed)
{
    const QPoint offset = pixelateOffset(seed, block);
    QImage out = source;
    std::mt19937 rng(rngSeed);
    const auto floorDiv = [](int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); };
    for (int by = floorDiv(-offset.y(), block); by * block + offset.y() < source.height(); ++by) {
        for (int bx = floorDiv(-offset.x(), block); bx * block + offset.x() < source.width(); ++bx) {
            const QRect cell = QRect(offset.x() + bx * block, offset.y() + by * block, block, block).intersected(QRect(QPoint(), source.size()));
            QList<QRgb> pixels;
            for (int y = cell.top(); y <= cell.bottom(); ++y) {
                for (int x = cell.left(); x <= cell.right(); ++x)
                    pixels.append(source.pixel(x, y));
            }
            std::shuffle(pixels.begin(), pixels.end(), rng);
            int i = 0;
            for (int y = cell.top(); y <= cell.bottom(); ++y) {
                for (int x = cell.left(); x <= cell.right(); ++x)
                    out.setPixel(x, y, pixels[i++]);
            }
        }
    }
    return out;
}

} // namespace

TEST(Pixelate, OutputDependsOnTheSourceOnlyThroughTheBlockMean)
{
    const int block = 14;
    const quint64 seed = 0x1234abcd5678ef01ULL;
    const QImage a = noise(100, 70, 1);
    const QImage b = shuffledWithinBlocks(a, block, seed, 2);
    ASSERT_NE(a, b);
    const QRect area(7, 4, 80, 58); // starts and ends inside blocks
    QImage pa = a, pb = b;
    pixelateArea(&pa, area, block, seed);
    pixelateArea(&pb, area, block, seed);
    ASSERT_NE(pa, pb) << "outside the area the sources are their own";
    for (int y = area.top(); y <= area.bottom(); ++y) {
        for (int x = area.left(); x <= area.right(); ++x)
            ASSERT_EQ(pa.pixel(x, y), pb.pixel(x, y)) << "two sources with the same block means give the same output at " << x << "," << y;
    }
    // Another seed: the outputs differ by the noise alone (at most twice the noise's range per channel, and the difference is the noise's).
    QImage pc = b;
    pixelateArea(&pc, area, block, seed ^ 0x55);
    int differing = 0;
    for (int y = area.top(); y <= area.bottom(); ++y) {
        for (int x = area.left(); x <= area.right(); ++x) {
            differing += pa.pixel(x, y) != pc.pixel(x, y);
        }
    }
    EXPECT_GT(differing, 0);
    // Inside a block the colour is one: the block's mean (rounded) plus a noise of at most kPixelateNoise a channel.
    const QPoint offset = pixelateOffset(seed, block);
    const int bx = 2, by = 1; // an interior block, whole in the picture
    const QRect cell(offset.x() + bx * block, offset.y() + by * block, block, block);
    ASSERT_TRUE(QRect(QPoint(), a.size()).contains(cell));
    ASSERT_TRUE(area.contains(cell));
    long sum[3] = {0, 0, 0};
    for (int y = cell.top(); y <= cell.bottom(); ++y) {
        for (int x = cell.left(); x <= cell.right(); ++x) {
            sum[0] += qRed(a.pixel(x, y));
            sum[1] += qGreen(a.pixel(x, y));
            sum[2] += qBlue(a.pixel(x, y));
        }
    }
    int expected[3], n[3];
    pixelateNoise(seed, bx, by, n);
    const QRgb first = pa.pixel(cell.left(), cell.top());
    for (int c = 0; c < 3; ++c) {
        expected[c] = int((sum[c] + block * block / 2) / (block * block));
        EXPECT_LE(std::abs(n[c]), kPixelateNoise);
        const int got = c == 0 ? qRed(first) : c == 1 ? qGreen(first) : qBlue(first);
        EXPECT_EQ(got, std::clamp(expected[c] + n[c], 0, 255));
    }
    for (int y = cell.top(); y <= cell.bottom(); ++y) {
        for (int x = cell.left(); x <= cell.right(); ++x)
            ASSERT_EQ(pa.pixel(x, y), first);
    }
}

TEST(Pixelate, AnEdgeSliverIsTheMeanOfItsWholeBlock)
{
    // An area one pixel wide inside a block: the pixel is the block's mean, not its own value (no source pixel survives at the border).
    QImage source = noise(60, 40, 3);
    const quint64 seed = 77;
    const int block = 16;
    const QPoint offset = pixelateOffset(seed, block);
    const int x = offset.x() + 16 * 1 + 5, y = offset.y() + 16 * 1 + 5; // inside the block (1, 1)
    QImage out = source;
    pixelateArea(&out, QRect(x, y, 1, 1), block, seed);
    // The same block pixelated whole gives the same colour at that pixel.
    QImage whole = source;
    pixelateArea(&whole, QRect(offset.x() + 16, offset.y() + 16, 16, 16), block, seed);
    EXPECT_EQ(out.pixel(x, y), whole.pixel(x, y));
    EXPECT_NE(out.pixel(x, y), source.pixel(x, y));
    // And only that pixel changed.
    out.setPixel(x, y, source.pixel(x, y));
    EXPECT_EQ(out, source);
}

TEST(Pixelate, CorrelationWithATexturedSourceStaysBelowTheBound)
{
    // The bound of the slice: a pixelated area correlates with its texture below 0.15 (blocks of 12 or more over a texture that varies per
    // pixel: about 1/12 at the smallest block by construction, measured 0.02 to 0.07).
    constexpr double kBound = 0.15;
    for (int block : {12, 16, 24}) {
        for (quint64 seed : {1ULL, 99ULL, 0xdeadbeefcafeULL}) {
            const QImage source = noise(160, 160, unsigned(seed % 1000));
            QImage out = source;
            const QRect area(8, 8, 144, 144);
            pixelateArea(&out, area, block, seed);
            const double r = correlation(source, out, area);
            std::printf("pixelate correlation block %d seed %llu: %.3f\n", block, (unsigned long long)seed, r);
            EXPECT_LT(std::abs(r), kBound) << "block " << block << " seed " << seed;
        }
    }
}

TEST(Pixelate, BlocksAreAtLeastTwelvePixels)
{
    for (const QJsonValue &block : {QJsonValue(), QJsonValue(0), QJsonValue(1), QJsonValue(4), QJsonValue(11), QJsonValue(-5), QJsonValue("x")}) {
        QJsonObject fields{{"seed", "0000000000000007"}};
        if (!block.isNull() && !block.isUndefined())
            fields.insert("block", block);
        EXPECT_GE(shapeGeometry(region(1, "pixelate", 0, 0, 50, 50, fields)).block, kMinPixelateBlock);
    }
    EXPECT_EQ(shapeGeometry(region(1, "pixelate", 0, 0, 50, 50, pix(12, "0000000000000007"))).block, 12);
    // The pixels: runs of one colour along a row are at least 12 long (but at the ends of the area), whatever block was asked for.
    const QImage source = noise(200, 20, 5);
    QImage out = source;
    pixelateArea(&out, QRect(0, 0, 200, 20), 1, 31);
    int transitions = 0;
    for (int x = 1; x < 200; ++x)
        transitions += out.pixel(x, 5) != out.pixel(x - 1, 5);
    EXPECT_LE(transitions, 200 / kMinPixelateBlock + 1);
    // ...and the tool's own block (the style's, at a large display scale) is never smaller.
    ShapeStyle style;
    style.pixelateBlock = 2;
    EXPECT_GE(shapeGeometry(makeRegion(1, "pixelate", QPointF(0, 0), QPointF(50, 50), style)).block, kMinPixelateBlock);
}

TEST(Pixelate, TheGridOffsetAndTheSeedVaryBetweenLayers)
{
    ShapeStyle style;
    QSet<QString> seeds;
    QSet<int> xs, ys;
    for (int i = 0; i < 40; ++i) {
        const Layer layer = makeRegion(i + 1, "pixelate", QPointF(0, 0), QPointF(50, 50), style);
        ASSERT_NE(layer.id, 0);
        const QString seed = layer.fields.value("seed").toString();
        EXPECT_EQ(seed.size(), 16);
        seeds.insert(seed);
        const QPoint offset = pixelateOffset(regionSeed(layer), shapeGeometry(layer).block);
        EXPECT_GE(offset.x(), 0);
        EXPECT_LT(offset.x(), shapeGeometry(layer).block);
        xs.insert(offset.x());
        ys.insert(offset.y());
    }
    EXPECT_EQ(seeds.size(), 40) << "each layer draws a seed of its own from the system's random source";
    EXPECT_GT(xs.size(), 5);
    EXPECT_GT(ys.size(), 5);
    // A seed given (a test's) is used as it is.
    style.seed = 0xabc;
    EXPECT_EQ(regionSeed(makeRegion(1, "pixelate", QPointF(0, 0), QPointF(9, 9), style)), 0xabcULL);
}

TEST(Pixelate, TheSameLayersGiveTheSamePicture)
{
    const QImage source = gradient(120, 90);
    const Layers layers{region(1, "pixelate", 10, 10, 70, 50, pix(16, "00000000deadbeef"))};
    EXPECT_EQ(exportLayers(source, layers), exportLayers(source, layers));
}

// ---- Blur -----------------------------------------------------------------------------------------------------------------------------

TEST(Blur, SpreadsAPointAndLeavesTheRestAndConstantsAlone)
{
    QImage flat(80, 60, QImage::Format_RGB32);
    flat.fill(QColor(120, 130, 140));
    EXPECT_EQ(exportLayers(flat, {region(1, "blur", 10, 10, 40, 30, QJsonObject{{"radius", 6}})}), flat) << "a flat picture stays flat";

    QImage dark(80, 60, QImage::Format_RGB32);
    dark.fill(Qt::black);
    dark.setPixel(30, 25, qRgb(255, 255, 255));
    const Layers layers{region(1, "blur", 10, 10, 40, 30, QJsonObject{{"radius", 4}})};
    const QImage out = exportLayers(dark, layers);
    EXPECT_LT(qRed(out.pixel(30, 25)), 100) << "the point is spread";
    EXPECT_GT(qRed(out.pixel(31, 25)), 0);
    for (int y = 0; y < 60; ++y) {
        for (int x = 0; x < 80; ++x) {
            if (!QRect(10, 10, 40, 30).contains(x, y))
                ASSERT_EQ(out.pixel(x, y), dark.pixel(x, y));
        }
    }
}

// ---- Spotlight ------------------------------------------------------------------------------------------------------------------------

TEST(Spotlight, LeavesItsAreaAloneAndVeilsTheRestWithoutBlendingAtTheEdge)
{
    QImage source(60, 40, QImage::Format_RGB32);
    source.fill(QColor(200, 100, 50));
    const QImage out = exportLayers(source, {region(1, "spotlight", 10.5, 10.5, 20, 10, QJsonObject{{"dim", 0.5}})});
    const QRect area = regionArea(region(1, "spotlight", 10.5, 10.5, 20, 10));
    for (int y = 0; y < 40; ++y) {
        for (int x = 0; x < 60; ++x) {
            if (area.contains(x, y))
                ASSERT_EQ(out.pixel(x, y), source.pixel(x, y)) << x << "," << y;
            else
                ASSERT_NEAR(qRed(out.pixel(x, y)), 100, 1) << x << "," << y;
        }
    }
}

// ---- the preview is the export --------------------------------------------------------------------------------------------------------

TEST(RegionPatch, IsTheExportsOwnPixelsUnderThePixelateAndBlur)
{
    QImage original = gradient(150, 100);
    ShapeStyle style;
    style.color = "#ff0000";
    style.width = 4;
    style.seed = 0x42;
    Layers layers;
    layers.append(makeShape(1, "rectangle", QPointF(20, 20), QPointF(90, 60), style)); // drawn before: the pixelate reads it
    style.seed = 0x4242;
    layers.append(makeRegion(2, "pixelate", QPointF(30.4, 25.2), QPointF(110.7, 70.9), style));
    layers.append(makeShape(3, "line", QPointF(0, 0), QPointF(149, 99), style));
    layers.append(makeRegion(4, "blur", QPointF(60, 30), QPointF(110, 60), style));
    layers.append(makeRegion(5, "pixelate", QPointF(120, 70), QPointF(180, 120), style)); // past the picture's edge
    const QImage exported = exportLayers(original, layers);
    for (const int id : {2, 4, 5}) {
        const QImage patch = regionPatch(original, layers, id);
        ASSERT_FALSE(patch.isNull()) << id;
        const QRect area = regionArea(layers[id - 1]).intersected(QRect(QPoint(), original.size()));
        ASSERT_EQ(patch.size(), area.size()) << id;
        for (int y = 0; y < area.height(); ++y) {
            for (int x = 0; x < area.width(); ++x) {
                // The export reads what the layers after this one drew over it too (the line, the blur): compare where nothing else is drawn.
                if (id == 2 && QRect(60, 30, 50, 30).contains(area.x() + x, area.y() + y))
                    continue; // the later blur
                const QColor p = QColor::fromRgb(patch.pixel(x, y)), e = exported.pixelColor(area.x() + x, area.y() + y);
                if (std::abs((area.x() + x) - (area.y() + y) * 149 / 99) < 8)
                    continue; // the line drawn after the region, over it
                ASSERT_EQ(p.rgb(), e.rgb()) << id << " at " << area.x() + x << "," << area.y() + y;
            }
        }
    }
    // The patch of a layer that is no pixel region is null.
    EXPECT_TRUE(regionPatch(original, layers, 1).isNull());
    EXPECT_TRUE(regionPatch(original, layers, 99).isNull());
}

TEST(RegionPatch, WithACropAndAPixelateBeforeTheBlurAgreesWithTheFile)
{
    QImage original = gradient(160, 120);
    Layers layers;
    Frame frame;
    frame.crop = QRect(10, 5, 120, 90);
    layers.append(makeFrame(1, frame));
    ShapeStyle style;
    style.seed = 9;
    layers.append(makeRegion(2, "pixelate", QPointF(5, 5), QPointF(70, 50), style));
    layers.append(makeRegion(3, "blur", QPointF(40, 30), QPointF(100, 80), style));
    const QImage exported = exportLayers(original, layers);
    ASSERT_EQ(exported.size(), QSize(120, 90));
    const QImage framed = applyFrame(original, frameOf(layers));
    const QImage patch = regionPatch(framed, layers, 3);
    const QRect area = regionArea(layers[2]);
    for (int y = 0; y < area.height(); ++y) {
        for (int x = 0; x < area.width(); ++x)
            ASSERT_EQ(patch.pixel(x, y), exported.pixel(area.x() + x, area.y() + y)) << x << "," << y;
    }
}

// ---- the tools ------------------------------------------------------------------------------------------------------------------------

TEST(RegionTools, DragDrawsOneLayerWithOneSeedAndMoveKeepsIt)
{
    UndoStack stack;
    ToolController tools(&stack);
    tools.style().color = "#ff0000";
    ASSERT_TRUE(tools.setTool("pixelate"));
    ASSERT_TRUE(tools.press(QPointF(10, 10), 3));
    tools.move(QPointF(30, 30), false);
    const QString first = stack.layers().last().fields.value("seed").toString();
    tools.move(QPointF(60, 50), false);
    EXPECT_EQ(stack.layers().last().fields.value("seed").toString(), first) << "the noise does not change while the box is dragged out";
    ASSERT_TRUE(tools.release(QPointF(60, 50), false));
    ASSERT_EQ(stack.layers().size(), 1);
    EXPECT_EQ(stack.layers()[0].type, QStringLiteral("pixelate"));
    EXPECT_EQ(stack.layers()[0].fields.value("w").toDouble(), 50);
    // Select picks it, a move keeps its seed and a resize handle works.
    ASSERT_TRUE(tools.setTool("select"));
    ASSERT_TRUE(tools.press(QPointF(30, 30), 3));
    tools.move(QPointF(40, 30), false);
    tools.release(QPointF(40, 30), false);
    EXPECT_EQ(stack.layers()[0].fields.value("seed").toString(), first);
    EXPECT_EQ(stack.layers()[0].fields.value("x").toDouble(), 20);
    ASSERT_TRUE(tools.press(QPointF(70, 50), 3)); // the bottom right handle
    tools.move(QPointF(90, 70), false);
    tools.release(QPointF(90, 70), false);
    EXPECT_EQ(stack.layers()[0].fields.value("w").toDouble(), 70);
    EXPECT_EQ(stack.layers()[0].fields.value("seed").toString(), first);
    // A drag of two pixels draws nothing.
    ASSERT_TRUE(tools.setTool("redact"));
    ASSERT_TRUE(tools.press(QPointF(200, 200), 3));
    tools.move(QPointF(201, 201), false);
    tools.release(QPointF(201, 201), false);
    EXPECT_EQ(stack.layers().size(), 1);
}

TEST(RegionTools, EveryRegionToolDrawsItsLayerAndRedactIsBlackByDefault)
{
    for (const QString &tool : {QStringLiteral("redact"), QStringLiteral("pixelate"), QStringLiteral("blur"), QStringLiteral("spotlight")}) {
        UndoStack stack;
        ToolController tools(&stack);
        tools.style().color = "#ff0000"; // the other tools' colour is not the redaction's
        ASSERT_TRUE(tools.setTool(tool)) << tool.toStdString();
        ASSERT_TRUE(ToolController::draws(tool));
        ASSERT_TRUE(tools.press(QPointF(5, 5), 3));
        tools.move(QPointF(40, 30), true); // Shift: a square
        tools.release(QPointF(40, 30), true);
        ASSERT_EQ(stack.layers().size(), 1) << tool.toStdString();
        EXPECT_EQ(stack.layers()[0].type, tool);
        EXPECT_EQ(stack.layers()[0].fields.value("w").toDouble(), stack.layers()[0].fields.value("h").toDouble());
        if (tool == "redact")
            EXPECT_EQ(stack.layers()[0].fields.value("color").toString(), QStringLiteral("#000000"));
    }
}

// ---- the app: the preview's image, the colour of Redact, the clipboard after Done -----------------------------------------------------------

namespace {

class RegionAppTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        m_file = m_dir.path() + "/Screenshot.png";
        QImage image = gradient(120, 80);
        for (int y = 20; y < 40; ++y) {
            for (int x = 30; x < 70; ++x)
                image.setPixel(x, y, qRgb(255, 0, 255)); // the secret
        }
        image.setText("Grassfield-Scale", "1");
        ASSERT_TRUE(image.save(m_file, "PNG"));
        m_app = std::make_unique<ScreenshotApp>(m_file, QStringList(), m_dir.path() + "/state");
        ASSERT_TRUE(m_app->errors().isEmpty());
        m_app->setClipboardWriter([this](const QStringList &argv, const QByteArray &png) {
            m_calls.append({argv, png});
            return m_clipboardWorks;
        });
        m_app->setToolColor("#de3651");
    }
    void drag(const QString &tool, QPointF from, QPointF to)
    {
        m_app->setTool(tool);
        ASSERT_TRUE(m_app->toolPress(from.x(), from.y(), 3));
        m_app->toolMove(to.x(), to.y(), false);
        m_app->toolRelease(to.x(), to.y(), false);
    }
    QImage fileImage() const { return QImage(m_file); }
    static bool hasSecret(const QImage &image)
    {
        for (int y = 0; y < image.height(); ++y) {
            for (int x = 0; x < image.width(); ++x) {
                if ((image.pixel(x, y) | 0xff000000u) == qRgb(255, 0, 255))
                    return true;
            }
        }
        return false;
    }
    struct Call {
        QStringList argv;
        QByteArray png;
    };
    QTemporaryDir m_dir;
    QString m_file;
    std::unique_ptr<ScreenshotApp> m_app;
    QList<Call> m_calls;
    bool m_clipboardWorks = true;
};

} // namespace

TEST_F(RegionAppTest, RedactIsBlackByDefaultAndTakesItsOwnColour)
{
    m_app->setTool("redact");
    EXPECT_EQ(m_app->toolColor(), QStringLiteral("#000000"));
    m_app->applyColor("#80336699");
    EXPECT_EQ(m_app->toolColor(), QStringLiteral("#336699")) << "a redaction's colour has no alpha";
    m_app->setTool("rectangle");
    EXPECT_EQ(m_app->toolColor(), QStringLiteral("#de3651")) << "the other tools' colour is untouched";
    drag("redact", QPointF(25, 15), QPointF(75, 45));
    m_app->setTool("select");
    EXPECT_EQ(m_app->selectedType(), QStringLiteral("redact"));
    EXPECT_EQ(m_app->toolColor(), QStringLiteral("#336699"));
}

TEST_F(RegionAppTest, DoneHidesThePixelsAndReplacesTheClipboardWithTheRedactedPicture)
{
    drag("redact", QPointF(25, 15), QPointF(75, 45));
    ASSERT_TRUE(m_app->done()) << m_app->lastError().toStdString();
    EXPECT_FALSE(hasSecret(fileImage()));
    ASSERT_EQ(m_calls.size(), 1);
    EXPECT_EQ(m_calls[0].argv, (QStringList{"wl-copy", "--type", "image/png", "--sensitive"}));
    QFile f(m_file);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    EXPECT_EQ(m_calls[0].png, f.readAll()) << "the clipboard holds the very bytes of the saved file";
    const QImage onClipboard = QImage::fromData(m_calls[0].png, "PNG");
    EXPECT_FALSE(hasSecret(onClipboard));
    EXPECT_EQ(onClipboard.pixel(50, 30), qRgb(0, 0, 0));
    // The history keeps the capture for Revert, privately (ADR-0066 D-9, copy 3): what the original-keeping path does today.
    EXPECT_TRUE(m_app->canRevert());
}

TEST_F(RegionAppTest, DoneWithoutAHidingLayerLeavesTheClipboardAlone)
{
    drag("rectangle", QPointF(25, 15), QPointF(75, 45));
    ASSERT_TRUE(m_app->done());
    drag("spotlight", QPointF(25, 15), QPointF(75, 45));
    ASSERT_TRUE(m_app->done());
    EXPECT_TRUE(m_calls.isEmpty());
}

TEST_F(RegionAppTest, ADoneWithoutChangesTouchesNothing)
{
    drag("pixelate", QPointF(25, 15), QPointF(75, 45));
    ASSERT_TRUE(m_app->done());
    ASSERT_EQ(m_calls.size(), 1);
    ASSERT_TRUE(m_app->done());
    EXPECT_EQ(m_calls.size(), 1);
}

TEST_F(RegionAppTest, AFailedCopyClearsTheClipboardKeepsTheWindowAndIsRetried)
{
    m_clipboardWorks = false;
    drag("blur", QPointF(25, 15), QPointF(75, 45));
    EXPECT_FALSE(m_app->done());
    EXPECT_FALSE(m_app->lastError().isEmpty());
    ASSERT_EQ(m_calls.size(), 2);
    EXPECT_EQ(m_calls[1].argv, (QStringList{"wl-copy", "--clear"})) << "better an empty clipboard than the capture as it was taken";
    m_clipboardWorks = true;
    EXPECT_TRUE(m_app->done()) << "the second Done tries the clipboard again";
    ASSERT_EQ(m_calls.size(), 3);
    EXPECT_EQ(m_calls[2].argv, clipboardArguments());
    EXPECT_TRUE(m_app->lastError().isEmpty());
}

TEST_F(RegionAppTest, ARotatedPictureKeepsTheRedactionOverTheSecret)
{
    drag("redact", QPointF(25, 15), QPointF(75, 45));
    m_app->rotateRight();
    m_app->flipHorizontal();
    drag("pixelate", QPointF(1, 1), QPointF(12, 12));
    ASSERT_TRUE(m_app->done()) << m_app->lastError().toStdString();
    const QImage out = fileImage();
    EXPECT_EQ(out.size(), QSize(80, 120));
    EXPECT_FALSE(hasSecret(out)) << "the layers moved with the picture";
}

TEST_F(RegionAppTest, ThePreviewImageIsTheExportsPixels)
{
    drag("pixelate", QPointF(25.5, 15.5), QPointF(75, 45));
    const int id = m_app->selectedId();
    ASSERT_NE(id, 0);
    const QImage patch = m_app->regionImage(id);
    ASSERT_FALSE(patch.isNull());
    ASSERT_TRUE(m_app->done());
    const QImage out = fileImage();
    const QImage layerPatch = patch;
    for (int y = 0; y < patch.height(); ++y) {
        for (int x = 0; x < patch.width(); ++x)
            ASSERT_EQ(patch.pixel(x, y) | 0xff000000u, out.pixel(25 + x, 15 + y) | 0xff000000u);
    }
    EXPECT_TRUE(m_app->regionImage(9999).isNull());
}

TEST(ClipboardArguments, AreTheAutomaticCopysOwn)
{
    EXPECT_EQ(clipboardArguments(), (QStringList{"wl-copy", "--type", "image/png", "--sensitive"}));
    EXPECT_EQ(clipboardClearArguments(), (QStringList{"wl-copy", "--clear"}));
}
