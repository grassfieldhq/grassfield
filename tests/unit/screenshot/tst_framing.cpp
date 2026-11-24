// Crop, rotate and flip (slice B8): the frame layer, the pixel-exact picture it makes, the layers that follow every edit, the crop
// rectangle's own editing, and the backend's one-step edits with Done, Revert and a reopening.
#include "annotations.h"
#include "exporter.h"
#include "framing.h"
#include "screenshotapp.h"
#include "undostack.h"

#include <QDir>
#include <QImage>
#include <QJsonArray>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <cmath>
#include <memory>
#include <random>

using namespace screenshot;

namespace {

// Every pixel its own colour: (x, y) can be told from the picture.
QImage numbered(int w, int h, QImage::Format format = QImage::Format_RGB32)
{
    QImage image(w, h, QImage::Format_ARGB32);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x)
            image.setPixel(x, y, qRgba(x % 256, y % 256, (x / 256) * 40 + (y / 256) * 8 + 1, format == QImage::Format_ARGB32 ? 100 + (x + y) % 150 : 255));
    }
    return image.convertToFormat(format);
}

// The reference operations, with Qt's own (so that the frame code is not checked against itself).
QImage refRotateRight(const QImage &image) { return image.transformed(QTransform().rotate(90)); }
QImage refRotateLeft(const QImage &image) { return image.transformed(QTransform().rotate(270)); }
QImage refFlipH(const QImage &image) { return image.flipped(Qt::Horizontal); }
QImage refFlipV(const QImage &image) { return image.flipped(Qt::Vertical); }

bool samePixels(const QImage &a, const QImage &b)
{
    if (a.size() != b.size())
        return false;
    const QImage x = a.convertToFormat(QImage::Format_ARGB32), y = b.convertToFormat(QImage::Format_ARGB32);
    for (int row = 0; row < x.height(); ++row) {
        if (memcmp(x.constScanLine(row), y.constScanLine(row), size_t(x.width()) * 4) != 0)
            return false;
    }
    return true;
}

// The largest channel difference between two pictures of one size (255 when the sizes differ).
int worstDifference(const QImage &a, const QImage &b)
{
    if (a.size() != b.size())
        return 255;
    const QImage x = a.convertToFormat(QImage::Format_RGB32), y = b.convertToFormat(QImage::Format_RGB32);
    int worst = 0;
    for (int row = 0; row < x.height(); ++row) {
        const auto *pa = reinterpret_cast<const QRgb *>(x.constScanLine(row));
        const auto *pb = reinterpret_cast<const QRgb *>(y.constScanLine(row));
        for (int col = 0; col < x.width(); ++col)
            worst = std::max({worst, std::abs(qRed(pa[col]) - qRed(pb[col])), std::abs(qGreen(pa[col]) - qGreen(pb[col])), std::abs(qBlue(pa[col]) - qBlue(pb[col]))});
    }
    return worst;
}

// The share of pixels that differ by more than `levels` in a channel.
double differingShare(const QImage &a, const QImage &b, int levels)
{
    if (a.size() != b.size())
        return 1;
    const QImage x = a.convertToFormat(QImage::Format_RGB32), y = b.convertToFormat(QImage::Format_RGB32);
    long count = 0;
    for (int row = 0; row < x.height(); ++row) {
        const auto *pa = reinterpret_cast<const QRgb *>(x.constScanLine(row));
        const auto *pb = reinterpret_cast<const QRgb *>(y.constScanLine(row));
        for (int col = 0; col < x.width(); ++col) {
            const int d = std::max({std::abs(qRed(pa[col]) - qRed(pb[col])), std::abs(qGreen(pa[col]) - qGreen(pb[col])), std::abs(qBlue(pa[col]) - qBlue(pb[col]))});
            count += d > levels;
        }
    }
    return double(count) / (double(x.width()) * x.height());
}

ShapeStyle style(const char *color, qreal width = 3)
{
    ShapeStyle s;
    s.color = QString::fromLatin1(color);
    s.width = width;
    return s;
}

// One layer of each kind that keeps its shape under a turn, at places that are not symmetric in the picture.
Layers shapes()
{
    return {makeShape(1, "rectangle", QPointF(7.5, 5.25), QPointF(41, 20), style("#0167fd", 3)),
            makeShape(2, "ellipse", QPointF(30, 22.5), QPointF(60.5, 38), style("#80de3651", 2.5)),
            makeShape(3, "line", QPointF(4, 36.5), QPointF(33, 30.25), style("#7fb844", 4)),
            makeShape(4, "arrow", QPointF(50, 8.5), QPointF(20, 28), style("#f56a16", 3)),
            makeStroke(5, "pen", {{5, 3}, {14, 12}, {27, 6}, {40, 15}, {55, 9}}, style("#783b93", 2.5)),
            makeStroke(6, "highlighter", {{10, 40}, {50, 41}}, [] {
                ShapeStyle s = style("#fcea21", 3);
                s.highlightFactor = 4;
                s.highlightOpacity = 0.5;
                return s;
            }())};
}

QImage white(const QSize &size)
{
    QImage image(size, QImage::Format_RGB32);
    image.fill(Qt::white);
    return image;
}

} // namespace

// ---- the frame layer -----------------------------------------------------------------------------------------------------------

TEST(Frame, ItRoundTripsThroughTheLayersFile)
{
    Frame frame;
    frame.crop = QRect(3, 4, 20, 10);
    frame.rot = 3;
    frame.flip = true;
    const Layers layers{makeFrame(1, frame), makeShape(2, "line", QPointF(0, 0), QPointF(5, 5), style("#ff0000"))};
    Layers back;
    ASSERT_TRUE(layersFromJson(layersToJson(layers), &back));
    EXPECT_EQ(back, layers);
    EXPECT_EQ(frameOf(back), frame);
    EXPECT_EQ(frameIndex(back), 0);
    EXPECT_EQ(frameOf({}), Frame()) << "no layer: the whole picture";
    EXPECT_TRUE(Frame().isIdentity(QSize(10, 10)));
    Frame whole;
    whole.crop = QRect(0, 0, 10, 10);
    EXPECT_TRUE(whole.isIdentity(QSize(10, 10)));
    EXPECT_FALSE(whole.isIdentity(QSize(11, 10)));
}

TEST(Frame, AFrameThatDoesNotReadIsIgnored)
{
    Layer frame = makeFrame(1, Frame{QRect(1, 1, 5, 5), 1, false});
    ASSERT_EQ(frameIndex({frame}), 0);
    for (const auto &[key, value] : std::initializer_list<std::pair<const char *, QJsonValue>>{
             {"rot", 4}, {"rot", -1}, {"rot", 1.5}, {"rot", "1"}, {"flip", 1}, {"x", -1}, {"w", 0}, {"h", 1.5}, {"x", "2"}, {"y", 1e12}}) {
        Layer broken = frame;
        broken.fields.insert(QLatin1String(key), value);
        EXPECT_EQ(frameIndex({broken}), -1) << key;
        EXPECT_EQ(frameOf({broken}), Frame()) << key << ": the whole picture, not a half-read crop";
    }
    Layer partial = frame;
    partial.fields.remove("w");
    EXPECT_EQ(frameIndex({partial}), -1) << "a crop with a side missing";
}

TEST(Frame, ACropBeyondThePictureIsClippedToIt)
{
    const QImage image = numbered(20, 10);
    const QImage out = applyFrame(image, Frame{QRect(15, 5, 100, 100), 0, false});
    EXPECT_EQ(out.size(), QSize(5, 5));
    EXPECT_EQ(framedSize(image.size(), Frame{QRect(15, 5, 100, 100), 0, false}), QSize(5, 5));
    EXPECT_TRUE(samePixels(out, image.copy(15, 5, 5, 5)));
    EXPECT_EQ(applyFrame(image, Frame{QRect(50, 50, 4, 4), 0, false}).size(), image.size()) << "a crop outside the picture is none";
}

// ---- the picture, pixel for pixel --------------------------------------------------------------------------------------------

TEST(Frame, ACropIsExactlyThoseVideoPixels)
{
    for (QImage::Format format : {QImage::Format_RGB32, QImage::Format_ARGB32}) {
        const QImage image = numbered(37, 23, format);
        for (const QRect &rect : {QRect(5, 3, 11, 9), QRect(0, 0, 1, 1), QRect(36, 22, 1, 1), QRect(0, 0, 37, 5), QRect(10, 0, 27, 23)}) {
            const Layers layers = croppedLayers({}, image.size(), rect);
            ASSERT_EQ(frameIndex(layers), 0);
            EXPECT_EQ(frameOf(layers).crop, rect);
            const QImage out = exportLayers(image, layers);
            EXPECT_EQ(out.size(), rect.size());
            EXPECT_TRUE(samePixels(out, image.copy(rect))) << rect.x() << "," << rect.y() << " " << rect.width() << "x" << rect.height();
            EXPECT_EQ(out.hasAlphaChannel(), image.hasAlphaChannel()) << "a picture without alpha stays without it";
        }
    }
    const QImage image = numbered(10, 10);
    EXPECT_TRUE(croppedLayers({}, image.size(), QRect(0, 0, 10, 10)).isEmpty()) << "the whole picture is no crop";
    EXPECT_TRUE(croppedLayers({}, image.size(), QRect(3, 3, 0, 0)).isEmpty());
    EXPECT_TRUE(croppedLayers({}, image.size(), QRect(40, 40, 3, 3)).isEmpty());
    EXPECT_EQ(frameOf(croppedLayers({}, image.size(), QRect(-5, -5, 10, 10))).crop, QRect(0, 0, 5, 5)) << "kept within the picture";
}

TEST(Frame, TheCropKeepsTheCapturesScaleAndTheDevicePixelRatio)
{
    QImage image = numbered(40, 30);
    image.setText("Grassfield-Scale", "1.25");
    image.setDevicePixelRatio(1.25);
    const QImage out = exportLayers(image, croppedLayers({}, image.size(), QRect(5, 5, 20, 10)));
    EXPECT_EQ(out.text("Grassfield-Scale"), "1.25");
    EXPECT_DOUBLE_EQ(out.devicePixelRatio(), 1.25);
}

TEST(Frame, ARotationAndAFlipMoveEveryPixelWhereItBelongs)
{
    const QImage image = numbered(37, 23);
    const QSize s = image.size();
    EXPECT_TRUE(samePixels(exportLayers(image, rotatedLayers({}, s, 1)), refRotateRight(image)));
    EXPECT_TRUE(samePixels(exportLayers(image, rotatedLayers({}, s, 3)), refRotateLeft(image)));
    EXPECT_TRUE(samePixels(exportLayers(image, rotatedLayers({}, s, 2)), refRotateRight(refRotateRight(image))));
    EXPECT_TRUE(samePixels(exportLayers(image, flippedLayers({}, s, true)), refFlipH(image)));
    EXPECT_TRUE(samePixels(exportLayers(image, flippedLayers({}, s, false)), refFlipV(image)));
    EXPECT_EQ(exportLayers(image, rotatedLayers({}, s, 1)).size(), QSize(23, 37));
    EXPECT_TRUE(rotatedLayers({}, s, 4).isEmpty()) << "four turns: the picture is the original";
    EXPECT_TRUE(rotatedLayers({}, s, 0).isEmpty());
    EXPECT_TRUE(flippedLayers(flippedLayers({}, s, true), s, true).isEmpty()) << "two mirrors: the original";
    EXPECT_TRUE(flippedLayers(flippedLayers({}, s, false), s, false).isEmpty());
    EXPECT_TRUE(rotatedLayers(rotatedLayers({}, s, 1), s, 3).isEmpty());
    EXPECT_TRUE(rotatedLayers(rotatedLayers({}, s, 1), s, 3).isEmpty());
    // Rotating a rotation: the turn comes out of the same frame layer, not a second one.
    const Layers twice = rotatedLayers(rotatedLayers({}, s, 1), s, 1);
    EXPECT_EQ(twice.size(), 1);
    EXPECT_EQ(frameOf(twice).rot, 2);
}

// Any sequence of crops, turns and mirrors: the frame layer's picture is what the same operations make of the picture one at a time,
// and the layers over it are in the new picture's pixels.
TEST(Frame, AnySequenceOfEditsGivesTheOperationsPictureAndTheLayersFollow)
{
    std::mt19937 rng(20261124);
    const QImage original = numbered(61, 47);
    for (int round = 0; round < 40; ++round) {
        Layers layers = shapes();
        QImage ref = original;                // the picture, by the reference operations
        QImage render = exportLayers(white(original.size()), layers); // the layers' drawing, which the operations move with the picture
        for (int step = 0; step < 12; ++step) {
            const Layers before = layers;
            const QImage renderBefore = render;
            QImage nextRef;
            QImage nextRender;
            switch (rng() % 5) {
            case 0:
                layers = rotatedLayers(layers, original.size(), 1);
                nextRef = refRotateRight(ref);
                nextRender = refRotateRight(render);
                break;
            case 1:
                layers = rotatedLayers(layers, original.size(), 3);
                nextRef = refRotateLeft(ref);
                nextRender = refRotateLeft(render);
                break;
            case 2:
                layers = flippedLayers(layers, original.size(), true);
                nextRef = refFlipH(ref);
                nextRender = refFlipH(render);
                break;
            case 3:
                layers = flippedLayers(layers, original.size(), false);
                nextRef = refFlipV(ref);
                nextRender = refFlipV(render);
                break;
            default: {
                const int w = 1 + int(rng() % unsigned(ref.width())), h = 1 + int(rng() % unsigned(ref.height()));
                const QRect rect(int(rng() % unsigned(ref.width() - w + 1)), int(rng() % unsigned(ref.height() - h + 1)), w, h);
                layers = croppedLayers(layers, original.size(), rect);
                nextRef = ref.copy(rect);
                nextRender = render.copy(rect);
                break;
            }
            }
            ref = nextRef;
            const QImage framed = applyFrame(original, frameOf(layers));
            ASSERT_TRUE(samePixels(framed, ref)) << "round " << round << " step " << step << ": the frame's picture is not the operations'";
            // The layers: drawn over the framed picture they are what the earlier drawing becomes under the operation (an integer
            // shift, a quarter turn and a mirror put each pixel's coverage where it was: the difference is rounding only).
            render = exportLayers(white(original.size()), layers);
            if (render.size() == nextRender.size()) {
                // A turned raster and the drawn turned geometry are the same coverage up to the rasteriser's rounding along the edges.
                ASSERT_LT(differingShare(render, nextRender, 24), 0.004) << "round " << round << " step " << step << ": the layers did not follow (worst "
                                                                          << worstDifference(render, nextRender) << " levels)";
            } else {
                FAIL() << "the drawing is " << render.width() << "x" << render.height() << ", the operation's " << nextRender.width() << "x" << nextRender.height();
            }
            render = nextRender; // continue from the reference so that rounding does not build up
            (void)before;
            (void)renderBefore;
            if (ref.width() < 4 || ref.height() < 4)
                break;
        }
    }
}

TEST(Frame, FourTurnsBringTheLayersBackToTheNumber)
{
    const Layers original = shapes();
    const QSize size(61, 47);
    Layers layers = original;
    for (int i = 0; i < 4; ++i)
        layers = rotatedLayers(layers, size, 1);
    ASSERT_EQ(layers.size(), original.size());
    EXPECT_EQ(frameIndex(layers), -1);
    for (int i = 0; i < layers.size(); ++i) {
        EXPECT_EQ(layers[i].type, original[i].type);
        EXPECT_EQ(layers[i].id, original[i].id);
        for (const char *key : {"x", "y", "w", "h"}) {
            if (original[i].fields.contains(key)) {
                EXPECT_NEAR(layers[i].fields.value(key).toDouble(), original[i].fields.value(key).toDouble(), 1e-9) << key;
            }
        }
        EXPECT_EQ(strokePoints(layers[i]).size(), strokePoints(original[i]).size());
    }
    layers = original;
    layers = flippedLayers(flippedLayers(layers, size, false), size, false);
    EXPECT_EQ(layers, original) << "two mirrors give back the very same layers";
}

TEST(Frame, ACropMovesTheLayersByTheCropsCornerAndKeepsTheFrameInOriginalPixels)
{
    const QSize size(61, 47);
    Layers layers = shapes();
    layers = rotatedLayers(layers, size, 1);                  // 47 x 61
    layers = croppedLayers(layers, size, QRect(5, 10, 30, 20)); // in the rotated picture
    const Frame frame = frameOf(layers);
    EXPECT_EQ(frame.rot, 1);
    // The rotated picture's (5,10)-(35,30) is, in the original, x from 10 to 30 and y from 47-35=12 to 47-5=42.
    EXPECT_EQ(frame.crop, QRect(10, 12, 20, 30)) << "the crop is stored in the original's pixels";
    EXPECT_EQ(framedSize(size, frame), QSize(30, 20));
}

TEST(Frame, TextTurnsWithThePictureAndAMirrorLeavesItReadable)
{
    const QSize size(100, 60);
    ShapeStyle t = style("#0167fd");
    t.textSize = 20;
    Layer text = makeText(1, QPointF(30, 10), "Hi", t);
    const Layer counter = makeCounter(2, QPointF(70, 40), t);
    const Layers turned = rotatedLayers({text, counter}, size, 1);
    ASSERT_EQ(turned.size(), 3);
    const Layer &turnedText = turned[1];
    EXPECT_EQ(turnedText.fields.value("rot").toInt(), 1);
    EXPECT_NEAR(turnedText.fields.value("x").toDouble(), 60 - 10, 1e-9) << "(x, y) -> (height - y, x)";
    EXPECT_NEAR(turnedText.fields.value("y").toDouble(), 30, 1e-9);
    EXPECT_EQ(turned[2].fields.value("rot").toInt(), 0) << "a counter has no turn of its own";
    EXPECT_NEAR(turned[2].fields.value("x").toDouble(), 60 - 40, 1e-9);
    EXPECT_NEAR(turned[2].fields.value("y").toDouble(), 70, 1e-9);
    const Layers left = rotatedLayers({text}, size, 3);
    EXPECT_EQ(left[1].fields.value("rot").toInt(), 3);

    const Layers mirrored = flippedLayers({text, counter}, size, true);
    EXPECT_EQ(mirrored[1].fields.value("rot").toInt(), 0) << "not mirrored: the text still reads";
    EXPECT_NEAR(mirrored[1].fields.value("x").toDouble(), 70, 1e-9);
    const Layers upsideDown = flippedLayers({text}, size, false);
    EXPECT_EQ(upsideDown[1].fields.value("rot").toInt(), 0);
    EXPECT_NEAR(upsideDown[1].fields.value("y").toDouble(), 50, 1e-9);

    // Drawn, a turned text is the earlier drawing turned (the glyph outlines turn, exactly).
    const QImage base = white(size);
    const QImage drawn = exportLayers(base, {text});
    const QImage after = exportLayers(base, rotatedLayers({text}, size, 1));
    EXPECT_LT(differingShare(after, refRotateRight(drawn), 24), 0.004);
}

TEST(Frame, ALayerOfALaterToolWithABoxMovesLikeABox)
{
    // The redaction layers of slice B7 are boxes ("x", "y", "w", "h"): they follow without this file knowing their type.
    Layer box;
    box.id = 1;
    box.type = QStringLiteral("redact");
    box.fields = QJsonObject{{"x", 10}, {"y", 20}, {"w", 30}, {"h", 5}};
    const Layers turned = rotatedLayers({box}, QSize(100, 60), 1);
    ASSERT_EQ(turned.size(), 2);
    EXPECT_EQ(turned[1].fields.value("x").toDouble(), 60 - 25);
    EXPECT_EQ(turned[1].fields.value("y").toDouble(), 10);
    EXPECT_EQ(turned[1].fields.value("w").toDouble(), 5);
    EXPECT_EQ(turned[1].fields.value("h").toDouble(), 30);
}

TEST(Frame, ALayerDoesNotTakeTheFrameIdOfAnother)
{
    const QSize size(50, 50);
    Layers layers{makeShape(1, "line", QPointF(0, 0), QPointF(9, 9), style("#ff0000")), makeShape(7, "line", QPointF(0, 0), QPointF(9, 9), style("#ff0000"))};
    layers = rotatedLayers(layers, size, 1);
    EXPECT_EQ(layers.first().type, "frame");
    EXPECT_EQ(layers.first().id, 8);
    const int id = layers.first().id;
    layers = flippedLayers(layers, size, true);
    EXPECT_EQ(layers.first().id, id) << "the same frame layer is updated";
}

// ---- the crop rectangle -------------------------------------------------------------------------------------------------------------

TEST(Crop, TheAspectPresetsAndTheirRatios)
{
    EXPECT_EQ(cropAspects(), (QStringList{"free", "original", "1:1", "4:3", "3:2", "16:9", "9:16"}));
    EXPECT_EQ(aspectRatio("free", QSizeF(200, 100)), 0);
    EXPECT_EQ(aspectRatio("original", QSizeF(200, 100)), 2);
    EXPECT_EQ(aspectRatio("1:1", QSizeF()), 1);
    EXPECT_DOUBLE_EQ(aspectRatio("4:3", QSizeF()), 4.0 / 3);
    EXPECT_DOUBLE_EQ(aspectRatio("9:16", QSizeF()), 9.0 / 16);
    EXPECT_EQ(aspectRatio("banana", QSizeF()), 0);
    EXPECT_EQ(aspectRatio("original", QSizeF(0, 0)), 0);
    const QRectF fitted = fitAspect(QRectF(10, 10, 200, 100), 1);
    EXPECT_EQ(fitted, QRectF(60, 10, 100, 100)) << "the largest square, on the same centre";
    EXPECT_EQ(fitAspect(QRectF(10, 10, 100, 200), 2), QRectF(10, 85, 100, 50));
    EXPECT_EQ(fitAspect(QRectF(1, 2, 3, 4), 0), QRectF(1, 2, 3, 4));
}

TEST(Crop, DraggingAHandleKeepsTheBoundsTheMinimumAndTheRatio)
{
    const QRectF bounds(0, 0, 200, 120);
    const QRectF crop(40, 30, 100, 60);
    // Free: the edge goes where the pointer does, within the picture.
    EXPECT_EQ(draggedCrop(crop, Handle::Right, QPointF(150, 999), bounds, 0), QRectF(40, 30, 110, 60));
    EXPECT_EQ(draggedCrop(crop, Handle::Right, QPointF(5000, 0), bounds, 0), QRectF(40, 30, 160, 60)) << "stops at the picture's edge";
    EXPECT_EQ(draggedCrop(crop, Handle::TopLeft, QPointF(-50, -50), bounds, 0), QRectF(0, 0, 140, 90));
    EXPECT_GE(draggedCrop(crop, Handle::Left, QPointF(500, 0), bounds, 0).width(), kMinCrop) << "never smaller than the least";
    // Fixed ratio: every handle gives the ratio, inside the picture, with the opposite corner or edge fixed.
    std::mt19937 rng(7);
    for (qreal ratio : {1.0, 4.0 / 3, 16.0 / 9, 9.0 / 16, 0.5}) {
        for (int i = 0; i < 400; ++i) {
            const Handle::Kind kind = static_cast<Handle::Kind>(rng() % 8);
            const QPointF to(int(rng() % 400) - 100, int(rng() % 300) - 90);
            const QRectF out = draggedCrop(crop, kind, to, bounds, ratio);
            ASSERT_TRUE(bounds.contains(out.topLeft()) && bounds.contains(out.bottomRight())) << "within the picture";
            ASSERT_NEAR(out.width() / out.height(), ratio, 1e-6) << "kind " << kind << " ratio " << ratio;
            ASSERT_GE(out.width(), kMinCrop - 1e-9);
            ASSERT_GE(out.height(), kMinCrop - 1e-9);
        }
    }
    // A corner holds the opposite corner.
    const QRectF corner = draggedCrop(crop, Handle::BottomRight, QPointF(170, 100), bounds, 2);
    EXPECT_EQ(corner.topLeft(), crop.topLeft());
    // A side holds the opposite side and grows on the middle.
    const QRectF side = draggedCrop(crop, Handle::Right, QPointF(160, 0), bounds, 2);
    EXPECT_DOUBLE_EQ(side.left(), crop.left());
    EXPECT_NEAR(side.center().y(), crop.center().y(), 1e-9);
}

TEST(Crop, TheEditorStartsOnTheWholePictureAndAPresetFitsTheRectangle)
{
    CropEditor crop;
    crop.reset(QSizeF(200, 100));
    EXPECT_EQ(crop.rect(), QRectF(0, 0, 200, 100));
    EXPECT_FALSE(crop.changes());
    EXPECT_EQ(crop.pixelRect(), QRect(0, 0, 200, 100));
    EXPECT_TRUE(crop.setAspect("1:1"));
    EXPECT_EQ(crop.rect(), QRectF(50, 0, 100, 100));
    EXPECT_TRUE(crop.changes());
    EXPECT_EQ(crop.pixelRect(), QRect(50, 0, 100, 100));
    EXPECT_TRUE(crop.setAspect("16:9"));
    EXPECT_NEAR(crop.rect().width() / crop.rect().height(), 16.0 / 9, 1e-9);
    EXPECT_FALSE(crop.setAspect("7:5"));
    EXPECT_EQ(crop.aspect(), "16:9") << "a name that is no preset changes nothing";
    EXPECT_TRUE(crop.setAspect("free"));
    EXPECT_TRUE(crop.setAspect("original"));
    EXPECT_NEAR(crop.rect().width() / crop.rect().height(), 2, 1e-9);
}

TEST(Crop, APressOnAHandleResizesInsideMovesAndOutsideDrawsANewOne)
{
    CropEditor crop;
    crop.reset(QSizeF(200, 100));
    crop.setAspect("free");
    // Resize by the bottom-right handle.
    ASSERT_TRUE(crop.press(QPointF(199, 99), 4));
    crop.move(QPointF(150, 80));
    crop.release(QPointF(150, 80));
    EXPECT_EQ(crop.rect(), QRectF(0, 0, 150, 80));
    EXPECT_FALSE(crop.busy());
    // Move by dragging the inside, kept in the picture.
    ASSERT_TRUE(crop.press(QPointF(70, 40), 4));
    crop.move(QPointF(120, 60));
    EXPECT_EQ(crop.rect(), QRectF(50, 20, 150, 80)) << "stops at the picture's edge";
    crop.release(QPointF(120, 60));
    // A press outside the rectangle (inside the picture) draws a new one.
    crop.reset(QSizeF(200, 100));
    ASSERT_TRUE(crop.press(QPointF(199, 99), 2)) << "the bottom right handle";
    crop.move(QPointF(100, 50));
    crop.release(QPointF(100, 50));
    ASSERT_EQ(crop.rect(), QRectF(0, 0, 100, 50));
    ASSERT_TRUE(crop.press(QPointF(150, 70), 2)) << "outside the rectangle (0,0)-(100,50)";
    crop.move(QPointF(180, 90));
    crop.release(QPointF(180, 90));
    EXPECT_EQ(crop.rect(), QRectF(150, 70, 30, 20));
    EXPECT_EQ(crop.pixelRect(), QRect(150, 70, 30, 20));
    // Esc during a drag puts it back.
    ASSERT_TRUE(crop.press(QPointF(160, 80), 1));
    crop.move(QPointF(170, 85));
    crop.cancel();
    EXPECT_EQ(crop.rect(), QRectF(150, 70, 30, 20));
    // A drawn rectangle with a ratio holds it from the press point.
    crop.reset(QSizeF(200, 100));
    crop.setAspect("1:1");
    ASSERT_TRUE(crop.press(QPointF(1, 1), 0)) << "inside the rectangle already? no: it is the square (50,0)-(150,100); (1,1) is outside it";
    crop.move(QPointF(40, 30));
    crop.release(QPointF(40, 30));
    EXPECT_NEAR(crop.rect().width(), crop.rect().height(), 1e-9);
    EXPECT_EQ(crop.rect().topLeft(), QPointF(1, 1));
    // A rectangle drawn too small goes back to what it was.
    const QRectF before = crop.rect();
    ASSERT_TRUE(crop.press(QPointF(190, 10), 0));
    crop.move(QPointF(191, 11));
    crop.release(QPointF(191, 11));
    EXPECT_EQ(crop.rect(), before);
}

TEST(Crop, ThePixelRectIsWholePixelsWithinThePicture)
{
    CropEditor crop;
    crop.reset(QSizeF(100, 80));
    ASSERT_TRUE(crop.press(QPointF(99.5, 79.5), 2));
    crop.move(QPointF(60.4, 40.6));
    crop.release(QPointF(60.4, 40.6));
    const QRect r = crop.pixelRect();
    EXPECT_EQ(r, QRect(0, 0, 60, 41));
    EXPECT_TRUE(QRect(0, 0, 100, 80).contains(r));
}

// ---- the backend ---------------------------------------------------------------------------------------------------------------------

namespace {

class FrameApp : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        m_file = m_dir.path() + "/Screenshot.png";
        m_original = numbered(60, 40, QImage::Format_RGB32);
        ASSERT_TRUE(m_original.save(m_file, "PNG"));
        m_app = std::make_unique<ScreenshotApp>(m_file, QStringList(), m_dir.path() + "/state");
        ASSERT_TRUE(m_app->errors().isEmpty());
        m_app->setToolColor("#ff0000");
        m_app->setToolWidth(2);
    }
    void drawRectangle(double x0, double y0, double x1, double y1)
    {
        m_app->setTool("rectangle");
        ASSERT_TRUE(m_app->toolPress(x0, y0, 3));
        m_app->toolRelease(x1, y1, false);
        m_app->setTool("select");
        m_app->selectNone();
    }
    QTemporaryDir m_dir;
    QString m_file;
    QImage m_original;
    std::unique_ptr<ScreenshotApp> m_app;
};

} // namespace

TEST_F(FrameApp, ARotationIsOneStepThatTurnsThePictureAndItsLayersTogether)
{
    drawRectangle(5, 5, 25, 15);
    int pictureSignals = 0;
    QObject::connect(m_app.get(), &ScreenshotApp::pictureChanged, [&] { ++pictureSignals; });
    const QString source = m_app->imageSource();
    m_app->rotateRight();
    EXPECT_EQ(m_app->imageWidth(), 40);
    EXPECT_EQ(m_app->imageHeight(), 60);
    EXPECT_NE(m_app->imageSource(), source) << "the view loads the new picture";
    EXPECT_GE(pictureSignals, 1);
    EXPECT_TRUE(m_app->dirty());
    EXPECT_TRUE(samePixels(m_app->currentImage(), refRotateRight(m_original)));
    m_app->undo(); // the rotation, in one step
    EXPECT_EQ(m_app->imageWidth(), 60);
    EXPECT_EQ(m_app->imageHeight(), 40);
    EXPECT_TRUE(samePixels(m_app->currentImage(), m_original));
    m_app->undo(); // the rectangle
    EXPECT_FALSE(m_app->canUndo());
    EXPECT_FALSE(m_app->dirty());
    m_app->redo();
    m_app->redo();
    EXPECT_EQ(m_app->imageWidth(), 40) << "a redo brings the picture along with the layers";
}

TEST_F(FrameApp, DoneWritesTheEditedPictureAndRevertPutsTheCaptureBack)
{
    drawRectangle(5, 5, 25, 15);
    m_app->rotateLeft();
    m_app->flipHorizontal();
    ASSERT_TRUE(m_app->done());
    const QImage written(m_file);
    EXPECT_EQ(written.size(), QSize(40, 60));
    EXPECT_TRUE(samePixels(written.copy(0, 0, 5, 5), refFlipH(refRotateLeft(m_original)).copy(0, 0, 5, 5))) << "away from the rectangle: the turned and mirrored capture";
    // The rectangle's left side (x = 5 .. 25 at y = 5 and 15) is now a horizontal pair of lines near the top; its red is in the file.
    int red = 0;
    for (int y = 0; y < written.height(); ++y) {
        for (int x = 0; x < written.width(); ++x)
            red += written.pixelColor(x, y) == QColor(255, 0, 0);
    }
    EXPECT_GT(red, 40) << "the rectangle's outline is drawn in the turned picture";
    EXPECT_TRUE(m_app->canRevert());

    // Reopened after a Done: the picture is the capture framed again and the edits are still edits.
    ScreenshotApp again(m_file, QStringList(), m_dir.path() + "/state");
    EXPECT_EQ(again.imageWidth(), 40);
    EXPECT_EQ(again.imageHeight(), 60);
    EXPECT_TRUE(samePixels(again.currentImage(), refFlipH(refRotateLeft(m_original))));
    again.rotateRight();
    again.rotateRight();
    EXPECT_TRUE(again.dirty());

    ASSERT_TRUE(m_app->revert());
    EXPECT_EQ(QImage(m_file).size(), QSize(60, 40));
    EXPECT_TRUE(samePixels(QImage(m_file), m_original));
    EXPECT_EQ(m_app->imageWidth(), 60);
    EXPECT_FALSE(m_app->canUndo());
}

TEST_F(FrameApp, TheCropToolApplyCropsToTheRectangleAndMovesTheLayers)
{
    drawRectangle(20, 10, 40, 30);
    m_app->setTool("crop");
    EXPECT_EQ(m_app->cropRect(), QRectF(0, 0, 60, 40)) << "the whole picture to start";
    EXPECT_FALSE(m_app->cropChanges());
    m_app->applyCrop();
    EXPECT_FALSE(m_app->canRedo());
    EXPECT_EQ(m_app->imageWidth(), 60) << "an unchanged crop does nothing";

    ASSERT_TRUE(m_app->toolPress(59, 39, 3));
    m_app->toolMove(45, 33, false);
    m_app->toolRelease(45, 33, false);
    EXPECT_EQ(m_app->cropRect(), QRectF(0, 0, 45, 33));
    ASSERT_TRUE(m_app->cropChanges());
    m_app->setCropAspect("1:1");
    EXPECT_EQ(m_app->cropAspect(), "1:1");
    EXPECT_NEAR(m_app->cropRect().width(), m_app->cropRect().height(), 1e-9);
    EXPECT_EQ(m_app->cropRect(), QRectF(6, 0, 33, 33)) << "the largest square of the rectangle, on its middle";
    m_app->applyCrop();
    EXPECT_EQ(m_app->imageWidth(), 33);
    EXPECT_EQ(m_app->imageHeight(), 33);
    EXPECT_TRUE(samePixels(m_app->currentImage(), m_original.copy(6, 0, 33, 33))) << "pixel-exact";
    EXPECT_EQ(m_app->cropRect(), QRectF(0, 0, 33, 33)) << "the tool starts again on the new picture";
    m_app->setTool("select");
    EXPECT_EQ(m_app->cropRect(), QRectF()) << "no rectangle without the tool";

    // The rectangle drawn before (20,10)-(40,30) did not move: the crop's corner is the picture's.
    m_app->undo();
    EXPECT_EQ(m_app->imageWidth(), 60);
    EXPECT_TRUE(samePixels(m_app->currentImage(), m_original));
}

TEST_F(FrameApp, LeavingTheCropToolGivesUpTheRectangle)
{
    m_app->setTool("crop");
    ASSERT_TRUE(m_app->toolPress(59, 39, 3));
    m_app->toolRelease(30, 20, false);
    ASSERT_TRUE(m_app->cropChanges());
    m_app->setTool("pen");
    m_app->setTool("crop");
    EXPECT_FALSE(m_app->cropChanges());
    ASSERT_TRUE(m_app->toolPress(59, 39, 3));
    m_app->toolMove(30, 20, false);
    m_app->toolCancel(); // Esc in the middle of the drag
    EXPECT_EQ(m_app->cropRect(), QRectF(0, 0, 60, 40));
    m_app->cancelCrop();
    EXPECT_EQ(m_app->cropRect(), QRectF(0, 0, 60, 40));
}

TEST_F(FrameApp, TheEyedropperReadsTheFramedPicture)
{
    m_app->rotateRight();
    // After a quarter turn the original's (x, y) is at (39 - y, x): the pixel at (30, 10) of the turned picture is the original's (10, 9).
    m_app->setTool("eyedropper");
    EXPECT_EQ(m_app->pickColor(30.5, 10.5), QColor(10, 9, 1).name());
}

TEST_F(FrameApp, ASelectionSurvivesAnEditOfTheFrameAndItsHandlesFollow)
{
    m_app->setTool("rectangle");
    ASSERT_TRUE(m_app->toolPress(5, 5, 3));
    m_app->toolRelease(25, 15, false);
    ASSERT_EQ(m_app->selectedId(), 1);
    m_app->rotateRight();
    EXPECT_EQ(m_app->selectedId(), 1);
    const QRectF bounds = m_app->selectionBounds();
    EXPECT_EQ(bounds, QRectF(25, 5, 10, 20)) << "(5,5)-(25,15) turned in a 40 x 60 picture: x from 40-15 to 40-5, y from 5 to 25";
    EXPECT_EQ(m_app->handles().size(), 8);
}

TEST_F(FrameApp, WithoutADocumentTheEditsDoNothing)
{
    ScreenshotApp empty(QString(), QStringList(), m_dir.path() + "/state2");
    empty.rotateRight();
    empty.flipVertical();
    empty.applyCrop();
    EXPECT_FALSE(empty.canUndo());
    EXPECT_EQ(empty.imageWidth(), 0);
}
