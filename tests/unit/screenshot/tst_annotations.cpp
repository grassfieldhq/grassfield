// The shape layers: building, reading, hit testing, moving and resizing (slices B3 and B4), and the exporter's pixels.
#include "annotations.h"
#include "exporter.h"

#include <QElapsedTimer>
#include <QImage>

#include <cstdio>

#include <gtest/gtest.h>

using namespace screenshot;

namespace {

ShapeStyle red(qreal width = 4)
{
    ShapeStyle style;
    style.color = QStringLiteral("#ff0000");
    style.width = width;
    return style;
}

QImage white(int w, int h)
{
    QImage image(w, h, QImage::Format_RGB32);
    image.fill(Qt::white);
    return image;
}

} // namespace

TEST(Annotations, MakeShapeWritesTheDocumentedFields)
{
    const Layer rect = makeShape(3, "rectangle", QPointF(30, 40), QPointF(10, 20), red());
    EXPECT_EQ(rect.id, 3);
    EXPECT_EQ(rect.type, "rectangle");
    QRectF box;
    ASSERT_TRUE(readBox(rect, &box));
    EXPECT_EQ(box, QRectF(10, 20, 20, 20)) << "two opposite corners in either order";
    EXPECT_FALSE(layerFill(rect));

    const Layer arrow = makeShape(4, "arrow", QPointF(0, 0), QPointF(100, 0), [] { auto s = red(); s.arrow = "curved"; return s; }());
    EXPECT_EQ(arrowStyle(arrow), "curved");
    QPointF ctrl;
    ASSERT_TRUE(readPoint(arrow.fields, "ctrl", &ctrl));
    EXPECT_EQ(ctrl, QPointF(50, -25)) << "a quarter of the length, left of the way it points";

    EXPECT_EQ(makeShape(5, "text", {}, {}, red()).id, 0) << "only the shape tools' types";
    EXPECT_EQ(makeShape(5, "arrow", {}, {}, [] { auto s = red(); s.arrow = "weird"; return s; }()).fields.value("style").toString(), "straight");
}

TEST(Annotations, ALayerThatDoesNotReadIsNotDrawnOrHit)
{
    Layer layer = makeShape(1, "rectangle", QPointF(10, 10), QPointF(50, 50), red());
    layer.fields.insert("color", "red"); // not one of the two forms
    EXPECT_FALSE(layerColor(layer).isValid());
    EXPECT_FALSE(hitLayer(layer, QPointF(10, 10), 2));
    QImage image = white(60, 60);
    EXPECT_EQ(exportLayers(image, {layer}), image) << "nothing drawn";

    Layer far = makeShape(2, "line", QPointF(0, 0), QPointF(5, 5), red());
    far.fields.insert("to", QJsonArray{1e30, 0});
    EXPECT_FALSE(hitLayer(far, QPointF(0, 0), 5));
    EXPECT_TRUE(layerBounds(far).isNull());
    Layer negative = makeShape(3, "ellipse", QPointF(0, 0), QPointF(5, 5), red());
    negative.fields.insert("w", -4);
    EXPECT_TRUE(layerBounds(negative).isNull());
    Layer thin = makeShape(4, "line", QPointF(0, 0), QPointF(5, 5), red());
    thin.fields.insert("width", "wide");
    EXPECT_EQ(layerWidth(thin), 0);
}

TEST(Annotations, NextIdIsAboveEveryId)
{
    EXPECT_EQ(nextLayerId({}), 1);
    EXPECT_EQ(nextLayerId({Layer{4, "line", {}}, Layer{2, "line", {}}}), 5);
    EXPECT_EQ(nextLayerId({Layer{2147483647, "line", {}}}), 0);
}

TEST(Annotations, HitTestPicksTheTopmostShape)
{
    ShapeStyle style = red(4);
    const Layer back = makeShape(1, "rectangle", QPointF(0, 0), QPointF(100, 100), [&] { auto s = style; s.fill = true; return s; }());
    const Layer front = makeShape(2, "rectangle", QPointF(40, 40), QPointF(60, 60), [&] { auto s = style; s.fill = true; return s; }());
    EXPECT_EQ(hitTest({back, front}, QPointF(50, 50), 2), 2);
    EXPECT_EQ(hitTest({back, front}, QPointF(10, 10), 2), 1);
    EXPECT_EQ(hitTest({back, front}, QPointF(300, 300), 2), 0);
}

TEST(Annotations, AnOutlinedShapeIsHitOnItsEdgeOnly)
{
    const Layer rect = makeShape(1, "rectangle", QPointF(0, 0), QPointF(100, 100), red(4));
    EXPECT_EQ(hitLayer(rect, QPointF(0, 50), 2), true);
    EXPECT_EQ(hitLayer(rect, QPointF(50, 50), 2), false) << "the inside of an outline is the picture's";
    EXPECT_EQ(hitLayer(rect, QPointF(-3, 50), 2), true) << "within the tolerance and half the stroke";
    EXPECT_EQ(hitLayer(rect, QPointF(-9, 50), 2), false);

    const Layer ellipse = makeShape(2, "ellipse", QPointF(0, 0), QPointF(100, 60), red(4));
    EXPECT_TRUE(hitLayer(ellipse, QPointF(50, 0), 2));
    EXPECT_TRUE(hitLayer(ellipse, QPointF(100, 30), 2));
    EXPECT_FALSE(hitLayer(ellipse, QPointF(50, 30), 2));
    EXPECT_FALSE(hitLayer(ellipse, QPointF(2, 2), 2)) << "the box's corner is outside the ellipse";
}

TEST(Annotations, ALineAndACurveAreHitAlongTheirLength)
{
    const Layer line = makeShape(1, "line", QPointF(0, 0), QPointF(100, 0), red(4));
    EXPECT_TRUE(hitLayer(line, QPointF(50, 3), 2));
    EXPECT_FALSE(hitLayer(line, QPointF(50, 10), 2));
    EXPECT_FALSE(hitLayer(line, QPointF(150, 0), 2));

    ShapeStyle curved = red(4);
    curved.arrow = "curved";
    const Layer arrow = makeShape(2, "arrow", QPointF(0, 0), QPointF(100, 0), curved); // control point (50, -25)
    EXPECT_TRUE(hitLayer(arrow, QPointF(50, -12.5), 2)) << "the curve's middle";
    EXPECT_FALSE(hitLayer(arrow, QPointF(50, 0), 2)) << "not the chord";
}

TEST(Annotations, TranslatedMovesEveryPoint)
{
    ShapeStyle curved = red();
    curved.arrow = "curved";
    const Layer arrow = translated(makeShape(1, "arrow", QPointF(0, 0), QPointF(100, 0), curved), QPointF(5, 7));
    QPointF p;
    ASSERT_TRUE(readPoint(arrow.fields, "from", &p));
    EXPECT_EQ(p, QPointF(5, 7));
    ASSERT_TRUE(readPoint(arrow.fields, "to", &p));
    EXPECT_EQ(p, QPointF(105, 7));
    ASSERT_TRUE(readPoint(arrow.fields, "ctrl", &p));
    EXPECT_EQ(p, QPointF(55, -18));

    const Layer rect = translated(makeShape(2, "ellipse", QPointF(10, 10), QPointF(20, 30), red()), QPointF(-10, 1));
    QRectF box;
    ASSERT_TRUE(readBox(rect, &box));
    EXPECT_EQ(box, QRectF(0, 11, 10, 20));
}

TEST(Annotations, HandlesResizeABox)
{
    const Layer rect = makeShape(1, "rectangle", QPointF(10, 10), QPointF(50, 30), red());
    EXPECT_EQ(handlesOf(rect).size(), 8);
    Handle::Kind kind;
    ASSERT_TRUE(handleAt(rect, QPointF(50, 30), 3, &kind));
    EXPECT_EQ(kind, Handle::BottomRight);
    EXPECT_FALSE(handleAt(rect, QPointF(30, 20), 3, &kind));

    QRectF box;
    ASSERT_TRUE(readBox(draggedHandle(rect, Handle::BottomRight, QPointF(70, 60)), &box));
    EXPECT_EQ(box, QRectF(10, 10, 60, 50));
    ASSERT_TRUE(readBox(draggedHandle(rect, Handle::Left, QPointF(0, 999)), &box));
    EXPECT_EQ(box, QRectF(0, 10, 50, 20)) << "a side handle moves one edge";
    ASSERT_TRUE(readBox(draggedHandle(rect, Handle::Right, QPointF(-10, 0)), &box));
    EXPECT_EQ(box, QRectF(-10, 10, 20, 20)) << "an edge dragged across the other flips the box";
    ASSERT_TRUE(readBox(draggedHandle(rect, Handle::Top, QPointF(0, 30)), &box));
    EXPECT_GE(box.height(), 1) << "never smaller than a pixel while dragged";
}

TEST(Annotations, HandlesMoveTheEndsOfALine)
{
    ShapeStyle curved = red();
    curved.arrow = "curved";
    const Layer arrow = makeShape(1, "arrow", QPointF(0, 0), QPointF(100, 0), curved);
    EXPECT_EQ(handlesOf(arrow).size(), 3);
    EXPECT_EQ(handlesOf(makeShape(2, "line", {}, QPointF(1, 1), red())).size(), 2);
    QPointF p;
    ASSERT_TRUE(readPoint(draggedHandle(arrow, Handle::Control, QPointF(50, 40)).fields, "ctrl", &p));
    EXPECT_EQ(p, QPointF(50, 40));
    ASSERT_TRUE(readPoint(draggedHandle(arrow, Handle::From, QPointF(-5, 5)).fields, "from", &p));
    EXPECT_EQ(p, QPointF(-5, 5));
    // A drag that is not a number leaves the layer as it was.
    EXPECT_EQ(draggedHandle(arrow, Handle::To, QPointF(1e30, 0)), arrow);
}

TEST(Annotations, ConstrainKeepsAnglesAndSquares)
{
    const QPointF at = constrained(QPointF(0, 0), QPointF(100, 10), false);
    EXPECT_NEAR(at.x(), std::hypot(100.0, 10.0), 1e-9);
    EXPECT_NEAR(at.y(), 0, 1e-9);
    const QPointF diagonal = constrained(QPointF(0, 0), QPointF(50, 60), false);
    EXPECT_NEAR(diagonal.x(), diagonal.y(), 1e-9);
    EXPECT_EQ(constrained(QPointF(10, 10), QPointF(40, -5), true), QPointF(40, -20));
}

// The exporter's own pixels, apart from the golden files: a stroke is exactly its colour at its centre, and nothing else moves.
TEST(Exporter, ARectangleOutlineIsDrawnWhereItSays)
{
    const QImage out = exportLayers(white(60, 60), {makeShape(1, "rectangle", QPointF(10, 10), QPointF(50, 40), red(4))});
    EXPECT_EQ(out.pixelColor(10, 25), QColor(255, 0, 0)) << "on the left edge";
    EXPECT_EQ(out.pixelColor(30, 40), QColor(255, 0, 0)) << "on the bottom edge";
    EXPECT_EQ(out.pixelColor(30, 25), QColor(Qt::white)) << "an outline leaves the inside";
    EXPECT_EQ(out.pixelColor(2, 2), QColor(Qt::white));
    EXPECT_EQ(out.format(), QImage::Format_RGB32) << "a picture without alpha stays without it";
}

TEST(Exporter, AFilledEllipseCoversItsCentreOnly)
{
    ShapeStyle style = red(2);
    style.fill = true;
    const QImage out = exportLayers(white(60, 60), {makeShape(1, "ellipse", QPointF(10, 10), QPointF(50, 50), style)});
    EXPECT_EQ(out.pixelColor(30, 30), QColor(255, 0, 0));
    EXPECT_EQ(out.pixelColor(11, 11), QColor(Qt::white)) << "the box's corner is outside the ellipse";
}

TEST(Exporter, ALineAndAnArrowReachTheirEnds)
{
    const QImage line = exportLayers(white(60, 20), {makeShape(1, "line", QPointF(5, 10), QPointF(55, 10), red(4))});
    EXPECT_EQ(line.pixelColor(30, 10), QColor(255, 0, 0));
    EXPECT_EQ(line.pixelColor(30, 2), QColor(Qt::white));

    const QImage arrow = exportLayers(white(80, 20), {makeShape(1, "arrow", QPointF(5, 10), QPointF(75, 10), red(2))});
    EXPECT_EQ(arrow.pixelColor(40, 10), QColor(255, 0, 0)) << "the shaft";
    EXPECT_EQ(arrow.pixelColor(70, 10), QColor(255, 0, 0)) << "the head";
    EXPECT_EQ(arrow.pixelColor(67, 7), QColor(255, 0, 0)) << "the head is wider than the shaft";
    EXPECT_EQ(arrow.pixelColor(40, 4), QColor(Qt::white));
    EXPECT_EQ(arrow.pixelColor(5, 4), QColor(Qt::white)) << "a single head: none at the start";
    ShapeStyle both = red(2);
    both.arrow = "double";
    const QImage twin = exportLayers(white(80, 20), {makeShape(1, "arrow", QPointF(5, 10), QPointF(75, 10), both)});
    EXPECT_EQ(twin.pixelColor(12, 7), QColor(255, 0, 0)) << "the second head";
    EXPECT_EQ(arrow.pixelColor(12, 7), QColor(Qt::white)) << "a single head has none there";
}

TEST(Exporter, TranslucentColoursBlendAndAlphaIsKept)
{
    ShapeStyle half = red();
    half.color = QStringLiteral("#80ff0000");
    half.fill = true;
    const QImage blended = exportLayers(white(30, 30), {makeShape(1, "rectangle", QPointF(5, 5), QPointF(25, 25), half)});
    const QColor c = blended.pixelColor(15, 15);
    EXPECT_EQ(c.red(), 255);
    EXPECT_NEAR(c.green(), 127, 2);

    QImage clear(30, 30, QImage::Format_ARGB32);
    clear.fill(Qt::transparent);
    const QImage kept = exportLayers(clear, {makeShape(1, "rectangle", QPointF(5, 5), QPointF(25, 25), red())});
    EXPECT_TRUE(kept.hasAlphaChannel());
    EXPECT_EQ(kept.pixelColor(2, 2).alpha(), 0) << "alpha stays where nothing is drawn";
    EXPECT_EQ(kept.pixelColor(5, 15).alpha(), 255);
}

TEST(Exporter, NoLayersAreTheOriginalAndOtherTypesAreSkipped)
{
    const QImage image = white(20, 20);
    EXPECT_EQ(exportLayers(image, {}), image);
    EXPECT_EQ(exportLayers(image, {Layer{1, "text", QJsonObject{{"text", "x"}}}}), image) << "a type slice B6 draws";
    EXPECT_TRUE(exportLayers(QImage(), {makeShape(1, "line", {}, QPointF(1, 1), red())}).isNull());
}

TEST(Exporter, TheOverlayIsTheSameDrawingScaled)
{
    const Layers layers{makeShape(1, "rectangle", QPointF(10, 10), QPointF(50, 40), red(4))};
    const QImage full = renderOverlay(layers, QSize(60, 60), QSize(60, 60));
    const QImage half = renderOverlay(layers, QSize(60, 60), QSize(30, 30));
    EXPECT_EQ(half.size(), QSize(30, 30));
    EXPECT_EQ(full.pixelColor(2, 2).alpha(), 0) << "transparent where nothing is drawn";
    EXPECT_EQ(full.pixelColor(10, 25), QColor(255, 0, 0));
    EXPECT_GT(half.pixelColor(5, 12).alpha(), 200) << "the left edge, at half size";
    EXPECT_TRUE(renderOverlay(layers, QSize(), QSize(10, 10)).isNull());
}

// ---- the overlay is bounded by the view, not by the zoomed picture ---------------------------------------------------------------

TEST(Overlay, TheSizeIsClampedToTheLimits)
{
    EXPECT_EQ(clampedOverlaySize(QSize(1200, 800)), QSize(1200, 800)) << "a size within the limits is kept";
    const QSize huge = clampedOverlaySize(QSize(61440, 34560)); // a 4K capture at 16 times
    EXPECT_LE(huge.width(), kMaxOverlaySide);
    EXPECT_LE(huge.height(), kMaxOverlaySide);
    EXPECT_LE(qint64(huge.width()) * huge.height(), kMaxOverlayPixels);
    EXPECT_NEAR(double(huge.width()) / huge.height(), 61440.0 / 34560, 0.01) << "the aspect is kept";
    EXPECT_TRUE(clampedOverlaySize(QSize()).isEmpty());
}

// A 3840 x 2160 capture at 16 times in a 1200 x 800 view (a 1.25 display: 1500 x 1000 device pixels): the overlay is the view's
// size, not 61440 x 34560, and it shows the right part of the picture.
TEST(Overlay, AViewOfAFourKCaptureAtSixteenTimesIsTheViewsSize)
{
    const Layers layers{makeShape(1, "line", QPointF(1900, 1080), QPointF(1960, 1080), red(8)),
                        makeShape(2, "rectangle", QPointF(100, 100), QPointF(3700, 2000), red(8))};
    const double scale = 16 * 1.25; // device pixels per picture pixel
    const QSize view(1500, 1000);
    const QRectF region(1900, 1050, view.width() / scale, view.height() / scale); // 75 x 50 picture pixels
    QElapsedTimer timer;
    timer.start();
    const QImage overlay = renderOverlayRegion(layers, region, view);
    RecordProperty("overlay_ms_16x", int(timer.elapsed()));
    ASSERT_EQ(overlay.size(), view) << "the view's pixels";
    // The line is at picture y 1080: (1080 - 1050) * 20 = 600, from x 0 to 60 * 20 = 1200.
    EXPECT_EQ(overlay.pixelColor(600, 600), QColor(255, 0, 0));
    EXPECT_EQ(overlay.pixelColor(600, 100).alpha(), 0) << "transparent away from it";
    EXPECT_EQ(overlay.pixelColor(1400, 600).alpha(), 0) << "past the line's end";
}

TEST(Overlay, ARequestBeyondTheLimitsIsClampedNotRefused)
{
    const Layers layers{makeShape(1, "rectangle", QPointF(10, 10), QPointF(50, 40), red(4))};
    const QImage overlay = renderOverlayRegion(layers, QRectF(0, 0, 60, 60), QSize(61440, 34560));
    ASSERT_FALSE(overlay.isNull());
    EXPECT_LE(overlay.width(), kMaxOverlaySide);
    EXPECT_LE(qint64(overlay.width()) * overlay.height(), kMaxOverlayPixels);
    EXPECT_TRUE(renderOverlayRegion(layers, QRectF(), QSize(10, 10)).isNull());
}

TEST(Exporter, TheCapturesTextMetadataSurvivesTheExport)
{
    QImage image = white(30, 30);
    image.setText("Grassfield-Scale", "1.25");
    const QImage out = exportLayers(image, {makeShape(1, "line", QPointF(1, 1), QPointF(20, 20), red())});
    EXPECT_EQ(out.text("Grassfield-Scale"), "1.25");
}

// The cost of one pointer move, measured (printed, not asserted: a slow machine must not fail it): a 3840 x 2160 capture with 24
// shapes in a 1200 x 800 point view on a 1.25 display (1500 x 1000 device pixels) at 100%, 400% and 1600%. The overlay's size is
// asserted: it is the view's whatever the zoom.
TEST(Overlay, TheCostOfAMoveIsTheViewsNotTheZoomsAndItsSizeIsTheViews)
{
    Layers layers;
    for (int i = 0; i < 12; ++i) {
        layers.append(makeShape(2 * i + 1, "rectangle", QPointF(100 + i * 250, 100 + i * 120), QPointF(600 + i * 250, 500 + i * 120), red(8)));
        layers.append(makeShape(2 * i + 2, "arrow", QPointF(50 + i * 300, 2000), QPointF(900 + i * 280, 300), red(8)));
    }
    const QSize view(1500, 1000);
    for (const double zoom : {1.0, 4.0, 16.0}) {
        const double perPixel = zoom * 1.25;
        const QRectF region(1000, 500, view.width() / perPixel, view.height() / perPixel);
        qint64 best = -1;
        for (int run = 0; run < 5; ++run) {
            QElapsedTimer timer;
            timer.start();
            const QImage overlay = renderOverlayRegion(layers, region, view);
            const qint64 us = timer.nsecsElapsed() / 1000;
            best = best < 0 ? us : std::min(best, us);
            ASSERT_EQ(overlay.size(), view);
        }
        std::printf("overlay per move, 4K capture, zoom %.0f%%: %lld us, %d x %d px (%lld KB)\n", zoom * 100, (long long)best, view.width(),
                    view.height(), (long long)view.width() * view.height() * 4 / 1024);
    }
}
