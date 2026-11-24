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

#include <QElapsedTimer>
#include <QThread>
#include <QCoreApplication>
#include "capturehistory.h"
#include "layers.h"
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

// ---- a stroke costs the same per move however long it is -----------------------------------------------------------------------------

namespace {

// A hand-drawn line: a wave with a tremor, `count` samples a pixel or so apart.
QVector<QPointF> tremor(int count)
{
    QVector<QPointF> points;
    unsigned seed = 12345;
    for (int i = 0; i < count; ++i) {
        seed = seed * 1103515245u + 12345u;
        const double noise = double((seed >> 16) & 0x7fff) / 0x7fff - 0.5;
        points.append(QPointF(i * 0.9, 60 + 30 * std::sin(i * 0.02) + noise * 0.8));
    }
    return points;
}

struct Timing {
    double total = 0; // ms, all the moves
    double worst = 0; // ms, the slowest move
};

} // namespace

TEST(StrokeCost, AMoveIsBoundedWorkAndTheStrokeStaysThinned)
{
    double totals[4] = {};
    int index = 0;
    for (int count : {500, 1000, 2000, 4000}) {
        UndoStack stack;
        ToolController tools(&stack);
        tools.style().color = "#de3651";
        tools.setDeferPreview(true);
        ASSERT_TRUE(tools.setTool("pen"));
        const QVector<QPointF> samples = tremor(count);
        ASSERT_TRUE(tools.press(samples[0], 3));
        Timing t;
        for (int i = 1; i < count; ++i) {
            QElapsedTimer timer;
            timer.start();
            tools.move(samples[i], false);
            const double ms = timer.nsecsElapsed() / 1e6;
            t.total += ms;
            t.worst = std::max(t.worst, ms);
        }
        EXPECT_TRUE(stack.layers().isEmpty()) << "nothing is built until a preview is asked for";
        EXPECT_TRUE(tools.previewPending());
        const QVector<QPointF> kept = tools.strokeSoFar();
        EXPECT_LE(kept.size(), kMaxStrokePoints);
        EXPECT_LT(kept.size(), count / 3) << "thinned as it comes";
        EXPECT_EQ(kept.first(), samples.first());
        EXPECT_EQ(kept.last(), samples.last());
        // Every sample is within the thinning's epsilon of the line through the kept points.
        for (const QPointF &p : samples) {
            qreal best = 1e9;
            for (int k = 1; k < kept.size(); ++k) {
                const QPointF a = kept[k - 1], b = kept[k], ab = b - a;
                const qreal len2 = ab.x() * ab.x() + ab.y() * ab.y();
                const qreal u = len2 > 0 ? std::clamp(((p.x() - a.x()) * ab.x() + (p.y() - a.y()) * ab.y()) / len2, 0.0, 1.0) : 0;
                best = std::min(best, QLineF(p, a + ab * u).length());
            }
            ASSERT_LE(best, kStrokeEpsilon + 1e-6);
        }
        QElapsedTimer timer;
        timer.start();
        tools.flushPreview();
        const double flush = timer.nsecsElapsed() / 1e6;
        ASSERT_EQ(stack.layers().size(), 1);
        EXPECT_TRUE(tools.release(samples.last(), false));
        std::printf("stroke of %d samples: %zd points kept, moves %.2f ms in all, worst %.3f ms, one preview %.2f ms\n", count, size_t(kept.size()), t.total,
                    t.worst, flush);
        EXPECT_LT(t.worst, 25) << "no move is a hiccup";
        EXPECT_LT(flush, 400);
        totals[index++] = t.total;
    }
    EXPECT_LT(totals[3], 1000) << "4000 samples in under a second (they took 69 s when every move rebuilt the stroke)";
    if (totals[1] > 2)
        EXPECT_LT(totals[3] / totals[1], 9) << "four times the samples is not sixteen times the work";
}

TEST(StrokeCost, TheBackendMakesOnePreviewPerFrameNotOnePerSample)
{
    QTemporaryDir dir;
    QImage image(2000, 200, QImage::Format_RGB32);
    image.fill(Qt::white);
    ASSERT_TRUE(image.save(dir.path() + "/p.png", "PNG"));
    ScreenshotApp app(dir.path() + "/p.png", QStringList(), dir.path() + "/state");
    app.setToolColor("#de3651");
    app.setTool("pen");
    auto *model = qobject_cast<LayerModel *>(app.layerModel());
    int updates = 0;
    QObject::connect(model, &QAbstractItemModel::rowsInserted, [&] { ++updates; });
    QObject::connect(model, &QAbstractItemModel::dataChanged, [&] { ++updates; });
    const QVector<QPointF> samples = tremor(2000);
    ASSERT_TRUE(app.toolPress(samples[0].x(), samples[0].y(), 3));
    QElapsedTimer all;
    all.start();
    double worst = 0;
    for (int i = 1; i < samples.size(); ++i) {
        QElapsedTimer timer;
        timer.start();
        app.toolMove(samples[i].x(), samples[i].y(), false);
        worst = std::max(worst, timer.nsecsElapsed() / 1e6);
    }
    EXPECT_EQ(updates, 0) << "the moves of one burst make no model update (the frame's timer has not fired)";
    QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
    for (int i = 0; i < 40 && updates == 0; ++i) {
        QThread::msleep(5);
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    }
    EXPECT_GE(updates, 1) << "and the frame's timer makes one";
    app.toolRelease(samples.back().x(), samples.back().y(), false);
    EXPECT_EQ(model->rowCount(), 1);
    EXPECT_TRUE(app.canUndo());
    const double total = all.nsecsElapsed() / 1e6;
    std::printf("backend, 2000 samples: moves %.1f ms in all, worst %.3f ms\n", total, worst);
    EXPECT_LT(worst, 40);
    EXPECT_LT(total, 1500);
}

// ---- the layers file is never larger than the reader takes ----------------------------------------------------------------------------

TEST(LayersFileSize, EveryEditAndTheWriterStayWithinWhatTheReaderTakes)
{
    Layers many;
    for (int i = 1; i <= 40; ++i) {
        QVector<QPointF> p;
        for (int k = 0; k < 4000; ++k)
            p.append(QPointF(k * 0.7, 30 * std::sin(k * 0.05 + i)));
        many.append(makeStroke(i, "pen", p, penStyle()));
    }
    ASSERT_FALSE(layersFit(many));
    ASSERT_GT(layersToJson(many).size(), kMaxLayersBytes);
    Layers part = many.mid(0, 20);
    ASSERT_TRUE(layersFit(part));

    UndoStack stack;
    stack.reset(part);
    EXPECT_FALSE(stack.commit(many)) << "an edit past the limit is refused";
    EXPECT_EQ(stack.layers(), part);
    EXPECT_EQ(stack.undoSteps(), 0);
    // A gesture that ends past the limit is given up.
    stack.preview(many);
    EXPECT_FALSE(stack.commitGesture());
    EXPECT_EQ(stack.layers(), part);
    EXPECT_FALSE(stack.inGesture());
    stack.preview(part.mid(0, 10));
    EXPECT_TRUE(stack.commitGesture()) << "and one within it goes in";

    // The writer refuses the same bytes, whoever asks; the reader takes what the writer wrote.
    QTemporaryDir dir;
    CaptureHistory history(dir.path() + "/h");
    HistoryEntry e;
    ASSERT_TRUE(history.add("/tmp/x.png", "bytes", QSize(2, 2), &e));
    QString why;
    EXPECT_FALSE(history.writeLayers(e.id, layersToJson(many), &why));
    EXPECT_FALSE(why.isEmpty());
    ASSERT_TRUE(history.writeLayers(e.id, layersToJson(part), &why)) << why.toStdString();
    Layers back;
    EXPECT_TRUE(layersFromJson(history.readLayers(e.id), &back));
    EXPECT_EQ(back, part);
}

// ---- an eyedropper drag is one step ---------------------------------------------------------------------------------------------------

namespace {

int undoSteps(ScreenshotApp &app)
{
    int steps = 0;
    while (app.canUndo()) {
        app.undo();
        ++steps;
    }
    return steps;
}

} // namespace

TEST_F(EyedropperTest, ADragOverFiftyPixelsIsOneUndoStepOnTheSelectionAndNoneWithout)
{
    // Without a selection a drag edits no layer: no step at all.
    m_app->toolPress(30, 12, 3);
    for (int x = 31; x <= 80; ++x)
        m_app->toolMove(x, 12, false);
    m_app->toolRelease(80, 12, false);
    EXPECT_EQ(m_app->toolColor(), QColor(80, 12, 17).name());
    EXPECT_FALSE(m_app->canUndo());

    m_app->setTool("rectangle");
    ASSERT_TRUE(m_app->toolPress(10, 10, 3));
    m_app->toolRelease(60, 40, false);
    ASSERT_NE(m_app->selectedId(), 0);
    m_app->setTool("eyedropper");
    ASSERT_TRUE(m_app->toolPress(30, 12, 3));
    for (int x = 31; x <= 90; ++x) {
        m_app->toolMove(x, 12, false);
        EXPECT_FALSE(m_app->canUndo()) << "a drag in progress is a preview, not a step";
    }
    m_app->toolRelease(90, 12, false);
    EXPECT_EQ(m_app->toolColor(), QColor(90, 12, 17).name());
    EXPECT_EQ(undoSteps(*m_app), 2) << "the rectangle and the whole drag, 61 pixels, as one step";
}

TEST_F(EyedropperTest, ADragThatEndsOnTheColourTheLayerHasMakesNoStep)
{
    m_app->setTool("rectangle");
    m_app->applyColor(QColor(30, 12, 17).name());
    ASSERT_TRUE(m_app->toolPress(10, 10, 3));
    m_app->toolRelease(60, 40, false);
    m_app->setTool("eyedropper");
    ASSERT_TRUE(m_app->toolPress(30, 12, 3));
    for (int x = 31; x <= 50; ++x)
        m_app->toolMove(x, 12, false);
    m_app->toolMove(30, 12, false);
    m_app->toolRelease(30, 12, false);
    EXPECT_EQ(undoSteps(*m_app), 1) << "only the rectangle: the colour came back to what it was";
}

// ---- text: Done and closing take the text being typed ---------------------------------------------------------------------------------

namespace {

class TextEditing : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        m_file = m_dir.path() + "/t.png";
        QImage image(200, 100, QImage::Format_RGB32);
        image.fill(Qt::white);
        ASSERT_TRUE(image.save(m_file, "PNG"));
        m_app = std::make_unique<ScreenshotApp>(m_file, QStringList(), m_dir.path() + "/state");
        m_app->setToolColor("#0167fd");
        m_app->setTextSize(30);
        m_app->setTool("text");
    }
    QTemporaryDir m_dir;
    QString m_file;
    std::unique_ptr<ScreenshotApp> m_app;
};

long nonWhite(const QImage &image)
{
    long n = 0;
    for (int y = 0; y < image.height(); ++y) {
        for (int x = 0; x < image.width(); ++x)
            n += image.pixelColor(x, y) != QColor(Qt::white);
    }
    return n;
}

} // namespace

TEST_F(TextEditing, DoneWritesTheTextThatIsStillBeingTyped)
{
    ASSERT_TRUE(m_app->toolPress(20, 20, 3));
    m_app->previewText("Hi there");
    EXPECT_TRUE(m_app->textEditing());
    EXPECT_TRUE(m_app->dirty()) << "closing asks, as with any change";
    ASSERT_TRUE(m_app->done()) << "Ctrl+S with the editor open";
    EXPECT_FALSE(m_app->textEditing());
    EXPECT_GT(nonWhite(QImage(m_file)), 100) << "the text is in the file";
    EXPECT_FALSE(m_app->dirty());
    EXPECT_TRUE(m_app->canRevert());
}

TEST_F(TextEditing, ACleanDocumentWithTextBeingTypedIsDirtyAndATextNotTypedIsNot)
{
    ASSERT_TRUE(m_app->toolPress(20, 20, 3));
    EXPECT_FALSE(m_app->dirty()) << "nothing typed yet";
    m_app->previewText("x");
    EXPECT_TRUE(m_app->dirty());
    m_app->previewText("");
    EXPECT_FALSE(m_app->dirty());
    m_app->previewText("again");
    m_app->cancelText();
    EXPECT_FALSE(m_app->dirty());
    EXPECT_FALSE(m_app->canUndo());
}

TEST_F(TextEditing, ThePreviewIsTheLayerTheCommitMakes)
{
    ASSERT_TRUE(m_app->toolPress(20, 20, 3));
    m_app->applyTextStyle("pill");
    m_app->previewText("Look");
    auto *model = qobject_cast<LayerModel *>(m_app->layerModel());
    ASSERT_EQ(model->rowCount(), 1) << "shown while typed, through the model of the file's own geometry";
    const QVariant plate = model->data(model->index(0), LayerModel::PlateRole);
    const QVariant path = model->data(model->index(0), LayerModel::PathRole);
    EXPECT_NE(plate.toString(), "") << "the pill is already there";
    EXPECT_FALSE(m_app->canUndo()) << "a preview, not a step";
    m_app->commitText("Look");
    ASSERT_EQ(model->rowCount(), 1);
    EXPECT_EQ(model->data(model->index(0), LayerModel::PathRole), path);
    EXPECT_EQ(model->data(model->index(0), LayerModel::PlateRole), plate);
    EXPECT_EQ(undoSteps(*m_app), 1) << "typing a text, however long, is one step";
}

TEST_F(TextEditing, AChangeOfToolPutsTheTextIn)
{
    ASSERT_TRUE(m_app->toolPress(20, 20, 3));
    m_app->previewText("kept");
    m_app->setTool("select");
    EXPECT_FALSE(m_app->textEditing());
    EXPECT_EQ(m_app->selectedType(), "text");
    EXPECT_TRUE(m_app->canUndo());
}

TEST_F(TextEditing, ATextPastTheLimitIsCutNotDropped)
{
    EXPECT_EQ(m_app->textMaxLength(), kMaxTextLength);
    ASSERT_TRUE(m_app->toolPress(5, 5, 3));
    m_app->commitText(QString(kMaxTextLength + 500, 'x'));
    EXPECT_EQ(m_app->selectedType(), "text");
    ASSERT_TRUE(m_app->done());
    // Reopened, the layer holds the first kMaxTextLength characters.
    ScreenshotApp again(m_file, QStringList(), m_dir.path() + "/state");
    again.setTool("select");
    ASSERT_TRUE(again.toolPress(6, 6, 3));
    again.toolRelease(6, 6, false);
    EXPECT_EQ(again.selectedType(), "text");
    again.editSelectedText();
    ASSERT_TRUE(again.textEditing());
    EXPECT_EQ(again.textEditText().size(), kMaxTextLength) << "the first characters, not nothing";
    EXPECT_EQ(makeText(1, QPointF(0, 0), QString(kMaxTextLength + 1, 'x'), ShapeStyle{}).id, 0) << "the layer guard stays";
}

TEST(TextRotation, ANumberOutOfRangeReadsAsATurnWithoutOverflow)
{
    ShapeStyle s;
    s.color = "#0167fd";
    Layer text = makeText(1, QPointF(50, 50), "Hello", s);
    const QRectF flat = layerBounds(text);
    for (double rot : {1e30, -1e30, 3e9, -7.0, 4.0, 5.0}) {
        text.fields.insert("rot", rot);
        EXPECT_EQ(shapeGeometry(text).kind, ShapeGeometry::Glyphs) << rot;
        const QRectF b = layerBounds(text);
        EXPECT_TRUE(std::abs(b.width() - flat.width()) < 0.01 || std::abs(b.width() - flat.height()) < 0.01) << rot;
    }
    text.fields.insert("rot", -1);
    const QRectF minusOne = layerBounds(text);
    text.fields.insert("rot", 3);
    EXPECT_EQ(minusOne, layerBounds(text));
    text.fields.insert("rot", 2.5);
    EXPECT_EQ(shapeGeometry(text).kind, ShapeGeometry::Glyphs);
}

// ---- one gesture at a time: nothing but the text itself edits the document while a text is typed -----------------------------------------

namespace {

class TypedWhileSelected : public TextEditing
{
protected:
    void SetUp() override
    {
        TextEditing::SetUp();
        // Another layer is selected when the typing starts: it must never take what is meant for the text.
        m_app->setToolWidth(2);
        m_app->setTool("rectangle");
        ASSERT_TRUE(m_app->toolPress(120, 10, 3));
        m_app->toolRelease(180, 40, false);
        ASSERT_NE(m_app->selectedId(), 0);
        m_model = qobject_cast<LayerModel *>(m_app->layerModel());
        m_rectColor = m_model->data(m_model->index(0), LayerModel::ColorRole).value<QColor>();
        m_app->setTool("text");
        m_app->setToolColor("#0167fd");
        ASSERT_TRUE(m_app->toolPress(20, 60, 3));
        m_app->previewText("ab");
    }
    int glyphRows() const
    {
        int n = 0;
        for (int i = 0; i < m_model->rowCount(); ++i)
            n += m_model->data(m_model->index(i), LayerModel::KindRole).toString() == "glyphs";
        return n;
    }
    QColor rowColor(int row) const { return m_model->data(m_model->index(row), LayerModel::ColorRole).value<QColor>(); }
    LayerModel *m_model = nullptr;
    QColor m_rectColor;
};

} // namespace

TEST_F(TypedWhileSelected, ASwatchWhileTypingColoursTheTextAndNothingElse)
{
    m_app->applyColor("#de3651");
    m_app->previewText("abc");
    EXPECT_EQ(glyphRows(), 1) << "still the one text being typed";
    m_app->commitText("abc");
    EXPECT_EQ(glyphRows(), 1) << "not a second text with the rest of the letters";
    ASSERT_EQ(m_model->rowCount(), 2);
    EXPECT_EQ(rowColor(0), m_rectColor) << "the rectangle that was selected is untouched";
    EXPECT_EQ(rowColor(1), QColor("#de3651"));
    EXPECT_EQ(undoSteps(*m_app), 2) << "the rectangle, and the text with its colour as one step";
}

TEST_F(TypedWhileSelected, ASizeWhileTypingSizesTheText)
{
    m_app->applyTextSize(60);
    m_app->previewText("abc");
    m_app->commitText("abc");
    EXPECT_EQ(glyphRows(), 1);
    ShapeStyle style;
    style.color = "#0167fd";
    style.textSize = 60;
    EXPECT_NEAR(m_app->selectionBounds().height(), layerBounds(makeText(1, QPointF(0, 0), "abc", style)).height(), 0.5);
    EXPECT_EQ(undoSteps(*m_app), 2);
}

TEST_F(TypedWhileSelected, TheMenuDeletePutsTheTextInThenDeletesTheSelectionWhichIsThatText)
{
    m_app->deleteSelected();
    EXPECT_FALSE(m_app->textEditing());
    EXPECT_EQ(glyphRows(), 0) << "no duplicate, and nothing of the text left";
    EXPECT_EQ(m_model->rowCount(), 1) << "the rectangle stays";
    EXPECT_EQ(undoSteps(*m_app), 3) << "the rectangle, the text put in, the delete";
}

TEST_F(TypedWhileSelected, ARotationWhileTypingPutsTheTextInFirst)
{
    m_app->rotateRight();
    EXPECT_EQ(glyphRows(), 1);
    EXPECT_EQ(m_model->rowCount(), 3) << "the frame, the rectangle and one text";
    EXPECT_EQ(undoSteps(*m_app), 3) << "the rectangle, the text, the turn";
}

TEST_F(TypedWhileSelected, UndoWhileTypingPutsTheTextInAndThenUndoesIt)
{
    m_app->undo();
    EXPECT_EQ(glyphRows(), 0) << "the text typed is what Undo takes";
    EXPECT_EQ(m_model->rowCount(), 1);
    EXPECT_TRUE(m_app->canUndo()) << "the rectangle is still there to undo";
    EXPECT_TRUE(m_app->canRedo());
    m_app->redo();
    EXPECT_EQ(glyphRows(), 1) << "and Redo brings it back, one text";
}

TEST_F(TypedWhileSelected, ArrowKeysFlipsAndAnotherToolAlsoPutTheTextInOnce)
{
    m_app->nudgeSelected(3, 0);
    EXPECT_EQ(glyphRows(), 1);
    EXPECT_FALSE(m_app->textEditing());
    m_app->toolPress(20, 60, 3); // a click on the text edits it again
    EXPECT_TRUE(m_app->textEditing());
    m_app->previewText("abcd");
    m_app->flipHorizontal();
    EXPECT_EQ(glyphRows(), 1);
    EXPECT_FALSE(m_app->textEditing());
}

TEST_F(TypedWhileSelected, AnEditedTextTakesTheStyleChangedWhileItIsEdited)
{
    m_app->commitText("ab");
    m_app->selectNone();
    const QRectF box = m_app->selectionBounds(); // none selected: null
    (void)box;
    // Press on the text: it is edited; a swatch then a letter, then Return.
    ASSERT_TRUE(m_app->toolPress(22, 62, 6));
    ASSERT_TRUE(m_app->textEditing());
    ASSERT_NE(m_app->textEditId(), 0);
    m_app->applyColor("#7fb844");
    m_app->previewText("abc");
    m_app->commitText("abc");
    EXPECT_EQ(glyphRows(), 1) << "the same layer, not a second";
    EXPECT_EQ(rowColor(1), QColor("#7fb844"));
    EXPECT_EQ(rowColor(0), m_rectColor);
    EXPECT_EQ(undoSteps(*m_app), 3) << "the rectangle, the text, and the edit with its colour";
}

TEST_F(TextEditing, TheEditorFollowsTheLettersInAPillAsItFollowsThemInAnExistingText)
{
    m_app->applyTextStyle("pill");
    ASSERT_TRUE(m_app->toolPress(20, 20, 3));
    EXPECT_EQ(m_app->textEditPos(), QPointF(20, 20));
    m_app->previewText("Look");
    ShapeStyle style;
    style.color = "#0167fd";
    style.textStyle = "pill";
    style.textSize = 30;
    Layer expected = makeText(1, QPointF(20, 20), "Look", style);
    expected = translated(expected, QPointF(20, 20) - layerBounds(expected).topLeft());
    const QPointF letters = shapeGeometry(expected).layoutBox.topLeft();
    EXPECT_GT(letters.x(), 20.5) << "the pill's padding is before the letters";
    EXPECT_NEAR(m_app->textEditPos().x(), letters.x(), 0.01);
    EXPECT_NEAR(m_app->textEditPos().y(), letters.y(), 0.01);
    const QPointF before = m_app->textEditPos();
    m_app->previewText("Look!");
    EXPECT_NEAR(m_app->textEditPos().x(), before.x(), 0.01) << "no drift from one letter to the next";
    EXPECT_NEAR(m_app->textEditPos().y(), before.y(), 0.01);
}

TEST(StrokeCost, ThePerFramePreviewOfALongStrokeStaysWithinABound)
{
    UndoStack stack;
    ToolController tools(&stack);
    tools.style().color = "#de3651";
    tools.setDeferPreview(true);
    ASSERT_TRUE(tools.setTool("pen"));
    const QVector<QPointF> samples = tremor(4000);
    ASSERT_TRUE(tools.press(samples[0], 3));
    double worst = 0, total = 0;
    int frames = 0;
    for (int i = 1; i < samples.size(); ++i) {
        tools.move(samples[i], false);
        if (i % 16 == 0) { // a frame
            QElapsedTimer timer;
            timer.start();
            tools.flushPreview();
            const double ms = timer.nsecsElapsed() / 1e6;
            worst = std::max(worst, ms);
            total += ms;
            ++frames;
        }
    }
    std::printf("4000 samples, %d frames: stroke made %.1f ms in all, worst frame %.2f ms\n", frames, total, worst);
    EXPECT_LT(worst, 60) << "the layer's side of a frame (the scene's own cost is measured with the scene)";
    EXPECT_LT(total, 2500);
}
