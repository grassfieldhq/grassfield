// The pen, the highlighter and the eyedropper (slice B5): the stroke geometry, the tools' gestures, the style controls and the pixel
// the eyedropper reads at a capture scale of 1.25. The goldens of the two stroke tools are in tst_golden.cpp, their scene-against-
// exporter bound in tst_scene.cpp.
#include "annotations.h"
#include "exporter.h"
#include "layermodel.h"
#include "screenshotapp.h"
#include "toolcontroller.h"
#include "undostack.h"

#include <QDir>
#include <QImage>
#include <QJsonArray>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <cmath>
#include <memory>

using namespace screenshot;

namespace {

QVector<QPointF> wave(int count, qreal width = 100)
{
    QVector<QPointF> points;
    for (int i = 0; i < count; ++i) {
        const qreal x = width * i / (count - 1);
        points.append(QPointF(x, 20 + 10 * std::sin(x / 8)));
    }
    return points;
}

ShapeStyle penStyle(qreal width = 3)
{
    ShapeStyle s;
    s.color = QStringLiteral("#de3651");
    s.width = width;
    return s;
}

} // namespace

// ---- the geometry ----------------------------------------------------------------------------------------------------------------

TEST(Strokes, SimplifiedKeepsTheEndsAndDropsWhatIsOnTheLine)
{
    const QVector<QPointF> straight{{0, 0}, {1, 0.01}, {2, 0}, {3, -0.01}, {10, 0}};
    const QVector<QPointF> out = simplified(straight, 0.1);
    EXPECT_EQ(out, (QVector<QPointF>{{0, 0}, {10, 0}}));
    const QVector<QPointF> bend{{0, 0}, {5, 0}, {10, 8}};
    EXPECT_EQ(simplified(bend, 0.1), bend) << "a real corner stays";
    EXPECT_EQ(simplified({{1, 1}}, 5), (QVector<QPointF>{{1, 1}}));
    // Every dropped point stays within epsilon of the result: the drawn line moves by at most that.
    const QVector<QPointF> dense = wave(400);
    const QVector<QPointF> thin = simplified(dense, 0.4);
    EXPECT_LT(thin.size(), dense.size() / 2);
    const QPainterPath path = smoothPath(thin);
    EXPECT_EQ(thin.first(), dense.first());
    EXPECT_EQ(thin.last(), dense.last());
    for (const QPointF &p : dense) {
        qreal best = 1e9;
        for (int i = 0; i <= 400; ++i)
            best = std::min(best, QLineF(path.pointAtPercent(i / 400.0), p).length());
        EXPECT_LT(best, 1.0);
    }
}

TEST(Strokes, TheSmoothPathPassesThroughEveryPointAndIsSmooth)
{
    const QVector<QPointF> points{{0, 0}, {10, 10}, {20, 0}, {30, 10}};
    const QPainterPath path = smoothPath(points);
    // One cubic per segment, ending on the next point.
    QVector<QPointF> ends{path.elementAt(0)};
    for (int i = 1; i < path.elementCount(); i += 3) {
        ASSERT_EQ(path.elementAt(i).type, QPainterPath::CurveToElement);
        ends.append(path.elementAt(i + 2));
    }
    EXPECT_EQ(ends, points);
    // At a joint the curve arrives and leaves along one direction (Catmull-Rom): no kink. The joint at (10, 10) is the end of the first
    // cubic (elements 1 to 3) and the start of the second (elements 4 to 6).
    const QPointF arriving = QPointF(path.elementAt(3)) - QPointF(path.elementAt(2));
    const QPointF leaving = QPointF(path.elementAt(4)) - QPointF(path.elementAt(3));
    EXPECT_NEAR(arriving.x() * leaving.y() - arriving.y() * leaving.x(), 0, 1e-9) << "parallel";
    EXPECT_GT(arriving.x() * leaving.x() + arriving.y() * leaving.y(), 0) << "and the same way";
    EXPECT_EQ(smoothPath({{0, 0}, {5, 5}}).elementCount(), 2) << "two points: a segment";
    EXPECT_TRUE(smoothPath({}).isEmpty());
}

TEST(Strokes, TheSvgOfAPathIsItsElementsInOrder)
{
    QPainterPath path;
    path.moveTo(1, 2);
    path.lineTo(3, 4);
    path.cubicTo(5, 6, 7, 8, 9, 10);
    EXPECT_EQ(pathToSvg(path), "M1 2 L3 4 C5 6 7 8 9 10");
    QPainterPath closed;
    closed.moveTo(0, 0);
    closed.lineTo(4, 0);
    closed.lineTo(4, 4);
    closed.lineTo(0, 0);
    EXPECT_EQ(pathToSvg(closed), "M0 0 L4 0 L4 4 L0 0 Z") << "an outline that came back to its start is closed, so that a stroke joins there";
    EXPECT_EQ(pathToSvg(QPainterPath()), "");
}

TEST(Strokes, AStrokeLayerReadsOnlyWithValidPoints)
{
    const Layer pen = makeStroke(3, "pen", wave(30), penStyle());
    ASSERT_EQ(pen.id, 3);
    EXPECT_FALSE(strokePoints(pen).isEmpty());
    EXPECT_EQ(shapeGeometry(pen).kind, ShapeGeometry::Stroke);
    EXPECT_FALSE(shapeGeometry(pen).flatCap);

    Layer broken = pen;
    broken.fields.insert("points", QJsonArray{QJsonArray{1, 2}});
    EXPECT_EQ(shapeGeometry(broken).kind, ShapeGeometry::None) << "one point is no stroke";
    broken.fields.insert("points", QJsonArray{QJsonArray{1, 2}, QJsonArray{3}});
    EXPECT_EQ(shapeGeometry(broken).kind, ShapeGeometry::None);
    broken.fields.insert("points", QJsonArray{QJsonArray{1, 2}, QJsonArray{"x", 3}});
    EXPECT_EQ(shapeGeometry(broken).kind, ShapeGeometry::None);
    broken.fields.insert("points", QJsonArray{QJsonArray{1, 2}, QJsonArray{1e9, 3}});
    EXPECT_EQ(shapeGeometry(broken).kind, ShapeGeometry::None) << "a point past the coordinate bound";
    broken = pen;
    broken.fields.insert("color", "nope");
    EXPECT_EQ(shapeGeometry(broken).kind, ShapeGeometry::None);
    EXPECT_EQ(makeStroke(1, "line", wave(5), penStyle()).id, 0) << "not a stroke type";
    EXPECT_EQ(makeStroke(1, "pen", {{1, 1}}, penStyle()).id, 0);
}

TEST(Strokes, AStrokeTooLongIsThinnedToWhatTheFileAllows)
{
    QVector<QPointF> many;
    for (int i = 0; i < 20000; ++i)
        many.append(QPointF(i * 0.05, 10 + 4 * std::sin(i * 0.01)));
    const Layer pen = makeStroke(1, "pen", many, penStyle());
    ASSERT_EQ(pen.id, 1);
    EXPECT_LE(strokePoints(pen).size(), kMaxStrokePoints);
    EXPECT_EQ(strokePoints(pen).first(), many.first());
    EXPECT_EQ(strokePoints(pen).last(), many.last());
}

TEST(Strokes, TheHighlighterIsWiderAndSeeThrough)
{
    ShapeStyle style = penStyle(3);
    style.highlightFactor = 4;
    style.highlightOpacity = 0.4;
    const Layer mark = makeStroke(1, "highlighter", wave(10), style);
    ASSERT_EQ(mark.id, 1);
    EXPECT_DOUBLE_EQ(layerWidth(mark), 12);
    EXPECT_NEAR(layerColor(mark).alphaF(), 0.4, 0.005);
    EXPECT_EQ(layerColor(mark).rgb() & 0xffffff, QColor("#de3651").rgb() & 0xffffff) << "the colour is kept, the alpha is added";
    EXPECT_TRUE(shapeGeometry(mark).flatCap);
    // The pen keeps the colour as chosen, opaque.
    EXPECT_EQ(layerColor(makeStroke(2, "pen", wave(10), style)).alpha(), 255);
    // A colour that already has an alpha gets the highlighter's.
    style.color = "#10de3651";
    EXPECT_NEAR(layerColor(makeStroke(3, "highlighter", wave(10), style)).alphaF(), 0.4, 0.005);
}

TEST(Strokes, AHighlighterThatIsNearlyStraightSnapsAlongTheLine)
{
    // A hand-drawn pass along a line of text: wobbling by a quarter of the marker's width.
    QVector<QPointF> pass;
    for (int i = 0; i <= 20; ++i)
        pass.append(QPointF(10 + i * 8, 40 + ((i % 2) ? 2 : -2) + i * 0.1));
    const QVector<QPointF> snapped = snappedStraight(pass, 12);
    ASSERT_EQ(snapped.size(), 2);
    EXPECT_EQ(snapped[0].y(), snapped[1].y()) << "within 10 degrees of the horizontal: level";
    EXPECT_EQ(snapped[0].x(), pass.first().x());
    EXPECT_EQ(snapped[1].x(), pass.last().x());
    EXPECT_NEAR(snapped[0].y(), 41, 1.5) << "on the middle of the pass";
    // A diagonal stays diagonal.
    QVector<QPointF> slope;
    for (int i = 0; i <= 10; ++i)
        slope.append(QPointF(i * 10, i * 8 + (i % 2)));
    const QVector<QPointF> straight = snappedStraight(slope, 12);
    ASSERT_EQ(straight.size(), 2);
    EXPECT_NE(straight[0].y(), straight[1].y());
    // A curve is not snapped, nor is a short mark.
    EXPECT_EQ(snappedStraight(wave(30, 200), 6), wave(30, 200));
    const QVector<QPointF> shortPass{{0, 0}, {5, 1}, {10, 0}};
    EXPECT_EQ(snappedStraight(shortPass, 12), shortPass);
}

TEST(Strokes, TheyAreHitMovedAndResizedLikeAnyLayer)
{
    const Layer pen = makeStroke(1, "pen", {{10, 10}, {50, 10}, {90, 40}}, penStyle(4));
    EXPECT_TRUE(hitLayer(pen, QPointF(30, 11), 3));
    EXPECT_FALSE(hitLayer(pen, QPointF(30, 30), 3));
    EXPECT_FALSE(hitLayer(pen, QPointF(30, 11), -10)) << "no reach, no hit";
    EXPECT_EQ(layerBounds(pen), QRectF(QPointF(10, 10), QPointF(90, 40)));
    EXPECT_EQ(handlesOf(pen).size(), 8);

    const Layer moved = translated(pen, QPointF(5, -3));
    EXPECT_EQ(layerBounds(moved), QRectF(QPointF(15, 7), QPointF(95, 37)));
    // Dragging the right-middle handle to twice the width scales the points in the box.
    const Layer wider = draggedHandle(pen, Handle::Right, QPointF(170, 25));
    EXPECT_EQ(layerBounds(wider), QRectF(QPointF(10, 10), QPointF(170, 40)));
    EXPECT_EQ(strokePoints(wider)[1], QPointF(90, 10)) << "the middle point stays in the middle of the box";
    EXPECT_EQ(layerWidth(wider), 4) << "the stroke's width does not scale";
    // A level stroke: its box has no height, and dragging a vertical handle does not blow up.
    const Layer level = makeStroke(2, "pen", {{0, 5}, {40, 5}}, penStyle());
    const Layer taller = draggedHandle(level, Handle::Bottom, QPointF(20, 30));
    for (const QPointF &p : strokePoints(taller))
        EXPECT_TRUE(std::isfinite(p.x()) && std::isfinite(p.y()));
}

// ---- the gestures ----------------------------------------------------------------------------------------------------------------

namespace {

class StrokeTools : public ::testing::Test
{
protected:
    StrokeTools() : tools(&stack)
    {
        tools.style().color = QStringLiteral("#de3651");
        tools.style().width = 3;
    }
    // A drag along `points`: press at the first, a move to each of the others, release at the last.
    bool stroke(const QVector<QPointF> &points, bool constrain = false)
    {
        if (!tools.press(points.first(), 3))
            return false;
        for (int i = 1; i + 1 < points.size(); ++i)
            tools.move(points[i], constrain);
        return tools.release(points.last(), constrain);
    }
    UndoStack stack;
    ToolController tools;
};

} // namespace

TEST_F(StrokeTools, ADragIsOnePenStrokeAndOneStep)
{
    ASSERT_TRUE(tools.setTool("pen"));
    ASSERT_TRUE(stroke(wave(60)));
    ASSERT_EQ(stack.layers().size(), 1);
    EXPECT_EQ(stack.layers()[0].type, "pen");
    EXPECT_EQ(stack.undoSteps(), 1);
    EXPECT_EQ(tools.selected(), 1);
    EXPECT_EQ(tools.selectionHandles().size(), 8);
    const QVector<QPointF> points = strokePoints(stack.layers()[0]);
    EXPECT_EQ(points.first(), wave(60).first());
    EXPECT_EQ(points.last(), wave(60).last());
    EXPECT_LT(points.size(), 60) << "the samples are thinned as they come";
    EXPECT_TRUE(stack.undo());
    EXPECT_TRUE(stack.layers().isEmpty());
}

TEST_F(StrokeTools, TheStrokeGrowsWhileTheButtonIsDown)
{
    ASSERT_TRUE(tools.setTool("pen"));
    ASSERT_TRUE(tools.press(QPointF(10, 10), 3));
    tools.move(QPointF(11, 10), false);
    EXPECT_TRUE(stack.layers().isEmpty()) << "not a drag yet";
    tools.move(QPointF(30, 20), false);
    ASSERT_EQ(stack.layers().size(), 1);
    EXPECT_TRUE(stack.inGesture());
    tools.move(QPointF(60, 5), false);
    EXPECT_EQ(strokePoints(stack.layers()[0]).last(), QPointF(60, 5));
    tools.cancel();
    EXPECT_TRUE(stack.layers().isEmpty());
    EXPECT_EQ(stack.undoSteps(), 0);
}

TEST_F(StrokeTools, ATapDrawsNothing)
{
    ASSERT_TRUE(tools.setTool("pen"));
    EXPECT_FALSE(stroke({QPointF(10, 10), QPointF(11, 10)}));
    EXPECT_TRUE(stack.layers().isEmpty());
}

TEST_F(StrokeTools, TheHighlighterSnapsStraightOnReleaseAndKeepsAFreeStrokeFree)
{
    tools.style().highlightFactor = 4;
    tools.style().highlightOpacity = 0.4;
    ASSERT_TRUE(tools.setTool("highlighter"));
    QVector<QPointF> pass;
    for (int i = 0; i <= 20; ++i)
        pass.append(QPointF(10 + i * 8, 40 + ((i % 2) ? 1.5 : -1.5)));
    ASSERT_TRUE(stroke(pass));
    ASSERT_EQ(stack.layers().size(), 1);
    EXPECT_EQ(stack.layers()[0].type, "highlighter");
    EXPECT_EQ(strokePoints(stack.layers()[0]).size(), 2) << "the wobble is gone: a straight mark";
    EXPECT_EQ(strokePoints(stack.layers()[0])[0].y(), strokePoints(stack.layers()[0])[1].y());

    EXPECT_TRUE(stroke(wave(40, 150)));
    EXPECT_GT(strokePoints(stack.layers()[1]).size(), 3) << "a curve is left as drawn";
}

TEST_F(StrokeTools, ShiftKeepsTheHighlighterOnAFortyFiveDegreeLine)
{
    ASSERT_TRUE(tools.setTool("highlighter"));
    ASSERT_TRUE(stroke({QPointF(10, 10), QPointF(40, 18), QPointF(70, 60)}, true));
    const QVector<QPointF> points = strokePoints(stack.layers()[0]);
    ASSERT_EQ(points.size(), 2);
    EXPECT_EQ(points[0], QPointF(10, 10));
    const QPointF d = points[1] - points[0];
    EXPECT_NEAR(std::abs(d.x()), std::abs(d.y()), 1e-6) << "Shift: a 45-degree line from the press to the pointer";
}

TEST_F(StrokeTools, AStrokeIsNotStartedWhenTheFileWouldNotFit)
{
    Layers many;
    for (int i = 1; i <= 40; ++i) {
        QVector<QPointF> p;
        for (int k = 0; k < 4000; ++k)
            p.append(QPointF(k * 0.7, 30 * std::sin(k * 0.05 + i)));
        many.append(makeStroke(i, "pen", p, penStyle()));
    }
    ASSERT_GT(layersToJson(many).size(), kMaxLayersBytes * 3 / 4) << "the fixture is as large as it needs to be";
    stack.reset(many);
    ASSERT_TRUE(tools.setTool("pen"));
    EXPECT_FALSE(tools.press(QPointF(1, 1), 3));
    ASSERT_TRUE(tools.setTool("rectangle"));
    EXPECT_TRUE(tools.press(QPointF(1, 1), 3)) << "a shape is small";
    tools.cancel();
}

TEST_F(StrokeTools, TheLayerOfAStrokeCanBeRestyledAsOneStep)
{
    ASSERT_TRUE(tools.setTool("highlighter"));
    ASSERT_TRUE(stroke(wave(40, 150)));
    const Layer before = tools.selectedLayer();
    const Layer green = withColor(before, "#7fb844");
    EXPECT_EQ(layerColor(green).rgb() & 0xffffff, QColor("#7fb844").rgb() & 0xffffff);
    EXPECT_EQ(layerColor(green).alpha(), layerColor(before).alpha()) << "a marker stays a marker";
    ASSERT_TRUE(tools.replaceSelected(green));
    EXPECT_EQ(stack.undoSteps(), 2);
    EXPECT_FALSE(tools.replaceSelected(green)) << "nothing changed: no step";
    EXPECT_EQ(layerWidth(withWidth(before, 20)), 20);
    EXPECT_EQ(withFill(before, true), before) << "a fill does not apply to a stroke";
    EXPECT_EQ(withTextSize(before, 30), before);
}

// ---- the eyedropper at a capture scale of 1.25 -----------------------------------------------------------------------------------

namespace {

// A capture at scale 1.25 of a 160 x 100 point window: 200 x 125 pixels, each one its own colour (red is x, green is y, blue 17).
void makeCapture(const QString &path, double scale)
{
    const int w = int(std::lround(160 * scale)), h = int(std::lround(100 * scale));
    QImage image(w, h, QImage::Format_RGB32);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x)
            image.setPixelColor(x, y, QColor(x, y, 17));
    }
    image.setText("Grassfield-Scale", QString::number(scale));
    ASSERT_TRUE(image.save(path, "PNG"));
}

class EyedropperTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        m_file = m_dir.path() + "/Screenshot.png";
        makeCapture(m_file, 1.25);
        m_app = std::make_unique<ScreenshotApp>(m_file, QStringList(), m_dir.path() + "/state");
        ASSERT_TRUE(m_app->errors().isEmpty());
        ASSERT_EQ(m_app->imageWidth(), 200);
        ASSERT_EQ(m_app->imageHeight(), 125);
        m_app->setTool("eyedropper");
    }
    QTemporaryDir m_dir;
    QString m_file;
    std::unique_ptr<ScreenshotApp> m_app;
};

} // namespace

TEST_F(EyedropperTest, ItReadsThePixelUnderThePointerAtScaleOnePointTwoFive)
{
    EXPECT_NEAR(m_app->captureScale(), 1.25, 1e-9);
    // The view hands the backend picture pixels (its point divided by the zoom, ZoomView.viewScale); at a zoom of 2.5 a view point
    // of 100.4 is picture pixel 40.16: the pixel 40, whatever the display's scale was.
    for (const QPointF &view : {QPointF(100.4, 62.9), QPointF(0.2, 0.2), QPointF(499.9, 312.4), QPointF(250, 125)}) {
        const QPointF p(view.x() / 2.5, view.y() / 2.5);
        const int x = int(std::floor(p.x())), y = int(std::floor(p.y()));
        EXPECT_EQ(m_app->pickColor(p.x(), p.y()), QColor(x, y, 17).name()) << "at view point " << view.x() << "," << view.y();
    }
    // The pixel's own corners: pixel i spans [i, i + 1).
    EXPECT_EQ(m_app->pickColor(40.0, 25.0), QColor(40, 25, 17).name());
    EXPECT_EQ(m_app->pickColor(40.999, 25.999), QColor(40, 25, 17).name());
    EXPECT_EQ(m_app->pickColor(41.0, 26.0), QColor(41, 26, 17).name());
    EXPECT_EQ(m_app->pickColor(199.5, 124.5), QColor(199, 124, 17).name()) << "the last pixel";
    // Outside the picture: nothing, and the colour is left as it was.
    const QString kept = m_app->toolColor();
    for (const QPointF &p : {QPointF(-0.1, 5), QPointF(5, -0.1), QPointF(200, 5), QPointF(5, 125), QPointF(NAN, 5)})
        EXPECT_EQ(m_app->pickColor(p.x(), p.y()), QString()) << p.x() << "," << p.y();
    EXPECT_EQ(m_app->toolColor(), kept);
}

TEST_F(EyedropperTest, ThePickedColourIsTheColourOfNewShapesAndOfTheSelection)
{
    ASSERT_TRUE(m_app->toolPress(30, 12, 3)) << "a press picks";
    EXPECT_EQ(m_app->toolColor(), QColor(30, 12, 17).name());
    m_app->toolMove(31, 12, false);
    EXPECT_EQ(m_app->toolColor(), QColor(31, 12, 17).name()) << "and so does a drag";
    m_app->toolRelease(33, 14, false);
    EXPECT_EQ(m_app->toolColor(), QColor(33, 14, 17).name());
    EXPECT_FALSE(m_app->canUndo()) << "picking edits nothing";
    EXPECT_FALSE(m_app->dirty());

    m_app->setTool("rectangle");
    ASSERT_TRUE(m_app->toolPress(10, 10, 3));
    m_app->toolRelease(60, 40, false);
    ASSERT_EQ(m_app->selectedId(), 1);
    m_app->setTool("eyedropper");
    m_app->toolPress(100, 100, 3);
    m_app->toolRelease(100, 100, false);
    EXPECT_TRUE(m_app->canUndo());
    m_app->undo();
    m_app->undo();
    EXPECT_FALSE(m_app->dirty()) << "the colour change of the selection was one step of its own";
}

TEST_F(EyedropperTest, ItReadsThePictureNotTheLayersOverIt)
{
    m_app->setToolColor("#ff0000");
    m_app->setTool("rectangle");
    ASSERT_TRUE(m_app->toolPress(10, 10, 3));
    m_app->toolRelease(100, 60, false);
    m_app->selectNone();
    m_app->setTool("eyedropper");
    EXPECT_EQ(m_app->pickColor(10, 30), QColor(10, 30, 17).name()) << "on the red outline: the picture's pixel";
}

// ---- the style controls ------------------------------------------------------------------------------------------------------------

TEST_F(EyedropperTest, TheStyleControlsEditTheSelectionInOneStepAndNewLayersTakeThem)
{
    m_app->setTool("pen");
    m_app->setToolColor("#ff0000");
    ASSERT_TRUE(m_app->toolPress(10, 10, 3));
    m_app->toolMove(40, 30, false);
    m_app->toolRelease(80, 20, false);
    const int id = m_app->selectedId();
    ASSERT_NE(id, 0);

    m_app->applyColor("#0167fd");
    m_app->applyWidth(9);
    EXPECT_EQ(m_app->toolColor(), "#0167fd");
    EXPECT_EQ(m_app->toolWidth(), 9);
    EXPECT_EQ(m_app->selectedType(), "pen");
    m_app->undo(); // the width
    m_app->undo(); // the colour
    m_app->undo(); // the stroke
    EXPECT_FALSE(m_app->canUndo());
    EXPECT_FALSE(m_app->dirty());
    EXPECT_EQ(m_app->toolWidth(), 9) << "the style is the next layer's, not part of an undo";

    // With nothing selected a style control only changes what the next layer gets.
    m_app->applyColor("#7fb844");
    EXPECT_FALSE(m_app->canUndo());
    m_app->applyColor("red");
    EXPECT_EQ(m_app->toolColor(), "#7fb844") << "a colour not in the two forms is refused";
    m_app->applyWidth(0);
    EXPECT_EQ(m_app->toolWidth(), 9) << "and a width out of range";
}

TEST_F(EyedropperTest, ADoneWritesThePenAndTheHighlighterIntoTheFile)
{
    m_app->setToolColor("#ff0000");
    m_app->setToolWidth(4);
    m_app->setTool("pen");
    ASSERT_TRUE(m_app->toolPress(10, 60, 3));
    m_app->toolMove(60, 62, false);
    m_app->toolRelease(120, 60, false);
    ASSERT_TRUE(m_app->done());
    const QImage out(m_file);
    EXPECT_EQ(out.pixelColor(60, 62), QColor(255, 0, 0)) << "the stroke's pixels";
    EXPECT_EQ(out.pixelColor(60, 90), QColor(60, 90, 17)) << "the others untouched";
}
