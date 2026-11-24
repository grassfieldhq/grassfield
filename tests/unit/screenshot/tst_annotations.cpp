// The shape layers: building, reading, hit testing, moving and resizing (slices B3 and B4), and the exporter's pixels.
#include "annotations.h"
#include "exporter.h"

#include <QImage>

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

TEST(Exporter, TheCapturesTextMetadataSurvivesTheExport)
{
    QImage image = white(30, 30);
    image.setText("Grassfield-Scale", "1.25");
    const QImage out = exportLayers(image, {makeShape(1, "line", QPointF(1, 1), QPointF(20, 20), red())});
    EXPECT_EQ(out.text("Grassfield-Scale"), "1.25");
}

TEST(Exporter, AShapePastThePicturesEdgeIsClippedToThePicture)
{
    // A rectangle that starts left of the picture and runs past its right edge: the export has the picture's size and the part inside.
    const QImage out = exportLayers(white(40, 40), {makeShape(1, "rectangle", QPointF(-30, 10), QPointF(80, 30), [] { auto s = red(); s.fill = true; return s; }())});
    EXPECT_EQ(out.size(), QSize(40, 40));
    EXPECT_EQ(out.pixelColor(0, 20), QColor(255, 0, 0));
    EXPECT_EQ(out.pixelColor(39, 20), QColor(255, 0, 0));
    EXPECT_EQ(out.pixelColor(20, 2), QColor(Qt::white));
}

// ---- the geometry the exporter and the scene items share ----------------------------------------------------------------------

TEST(ShapeGeometry, AStraightArrowHasOneHeadAndAShaftThatStopsInsideIt)
{
    const ShapeGeometry g = shapeGeometry(makeShape(1, "arrow", QPointF(0, 0), QPointF(100, 0), red(4)));
    EXPECT_EQ(g.kind, ShapeGeometry::Arrow);
    EXPECT_EQ(g.endHead.size(), 3);
    EXPECT_TRUE(g.startHead.isEmpty());
    EXPECT_EQ(g.endHead[0], QPointF(100, 0)) << "the tip is the arrow's end";
    EXPECT_LT(g.shaftEnd.x(), 100);
    EXPECT_GT(g.shaftEnd.x(), g.endHead[1].x()) << "the shaft ends inside the head: the tip stays sharp";
    EXPECT_EQ(g.shaftStart, QPointF(0, 0));
}

TEST(ShapeGeometry, ADoubleArrowHasTwoAndACurvedOneFollowsItsControlPoint)
{
    ShapeStyle both = red(4);
    both.arrow = "double";
    const ShapeGeometry twin = shapeGeometry(makeShape(1, "arrow", QPointF(0, 0), QPointF(100, 0), both));
    EXPECT_EQ(twin.startHead.size(), 3);
    EXPECT_GT(twin.shaftStart.x(), 0);
    ShapeStyle curved = red(4);
    curved.arrow = "curved";
    const ShapeGeometry c = shapeGeometry(makeShape(2, "arrow", QPointF(0, 0), QPointF(100, 0), curved));
    EXPECT_EQ(c.kind, ShapeGeometry::ArrowCurved);
    EXPECT_EQ(c.ctrl, QPointF(50, -25));
    EXPECT_LT(c.endHead[0].y() - c.endHead[1].y(), 0) << "the head leans back along the curve, not along the chord";
}

TEST(ShapeGeometry, ALayerThatDoesNotReadHasNoGeometry)
{
    Layer layer = makeShape(1, "rectangle", QPointF(0, 0), QPointF(5, 5), red());
    layer.fields.insert("color", "nope");
    EXPECT_EQ(shapeGeometry(layer).kind, ShapeGeometry::None);
    EXPECT_EQ(shapeGeometry(Layer{1, "text", {}}).kind, ShapeGeometry::None);
    EXPECT_EQ(shapeGeometry(makeShape(1, "arrow", QPointF(3, 3), QPointF(3, 3), red())).kind, ShapeGeometry::None) << "no length, no arrow";
}
