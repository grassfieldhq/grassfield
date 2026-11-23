// The pointer logic of the tools (ToolController) and the editor backend that wires it to the document, the undo stack and the
// export (slices B3 and B4).
#include "annotations.h"
#include "layermodel.h"
#include "screenshotapp.h"
#include "toolcontroller.h"

#include <QAbstractItemModel>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QTemporaryDir>

#include <gtest/gtest.h>

using namespace screenshot;

namespace {

class ToolsTest : public ::testing::Test
{
protected:
    ToolsTest() : tools(&stack) { tools.style().color = QStringLiteral("#ff0000"); }

    // A whole drag: press, a move to the middle, release.
    bool drag(const QPointF &from, const QPointF &to, bool constrain = false, qreal tolerance = 3)
    {
        if (!tools.press(from, tolerance))
            return false;
        tools.move((from + to) / 2, constrain);
        return tools.release(to, constrain);
    }

    UndoStack stack;
    ToolController tools;
};

} // namespace

TEST_F(ToolsTest, TheToolsAreTheFiveOfThisSlice)
{
    EXPECT_EQ(ToolController::tools(), (QStringList{"select", "arrow", "line", "rectangle", "ellipse"}));
    EXPECT_EQ(tools.tool(), "select");
    EXPECT_FALSE(tools.setTool("pen")) << "a tool of a later slice";
    EXPECT_TRUE(tools.setTool("rectangle"));
    EXPECT_EQ(tools.tool(), "rectangle");
}

TEST_F(ToolsTest, ADragDrawsOneShapeAsOneStepAndSelectsIt)
{
    tools.setTool("rectangle");
    ASSERT_TRUE(drag(QPointF(10, 10), QPointF(60, 40)));
    ASSERT_EQ(stack.layers().size(), 1);
    EXPECT_EQ(stack.layers()[0].type, "rectangle");
    EXPECT_EQ(stack.layers()[0].id, 1);
    EXPECT_EQ(tools.selected(), 1);
    EXPECT_EQ(tools.selectionHandles().size(), 8);
    EXPECT_EQ(stack.undoSteps(), 1) << "a press, a move and a release are one step";
    EXPECT_FALSE(tools.busy());

    tools.setTool("ellipse");
    ASSERT_TRUE(drag(QPointF(0, 0), QPointF(20, 20)));
    EXPECT_EQ(stack.layers()[1].id, 2);
    EXPECT_EQ(stack.layers()[1].type, "ellipse");
    EXPECT_EQ(tools.selected(), 2);
}

TEST_F(ToolsTest, ADragThatIsTooShortDrawsNothing)
{
    tools.setTool("line");
    EXPECT_FALSE(drag(QPointF(10, 10), QPointF(11, 11)));
    EXPECT_TRUE(stack.layers().isEmpty());
    EXPECT_EQ(stack.undoSteps(), 0);
    EXPECT_EQ(tools.selected(), 0);
}

TEST_F(ToolsTest, TheShapeFollowsThePointerWhileItIsDragged)
{
    tools.setTool("arrow");
    ASSERT_TRUE(tools.press(QPointF(10, 10), 3));
    tools.move(QPointF(50, 10), false);
    ASSERT_EQ(stack.layers().size(), 1) << "the view shows it before the release";
    QPointF to;
    ASSERT_TRUE(readPoint(stack.layers()[0].fields, "to", &to));
    EXPECT_EQ(to, QPointF(50, 10));
    tools.move(QPointF(90, 10), false);
    EXPECT_EQ(stack.layers().size(), 1) << "the same layer moves on";
    tools.cancel();
    EXPECT_TRUE(stack.layers().isEmpty());
    EXPECT_EQ(stack.undoSteps(), 0);
}

TEST_F(ToolsTest, ShiftKeepsAnglesAndSquares)
{
    tools.setTool("line");
    ASSERT_TRUE(drag(QPointF(0, 0), QPointF(100, 12), true));
    QPointF to;
    ASSERT_TRUE(readPoint(stack.layers()[0].fields, "to", &to));
    EXPECT_NEAR(to.y(), 0, 1e-9) << "snapped to the horizontal";

    tools.setTool("rectangle");
    ASSERT_TRUE(drag(QPointF(0, 0), QPointF(80, 30), true));
    QRectF box;
    ASSERT_TRUE(readBox(stack.layers()[1], &box));
    EXPECT_EQ(box.width(), box.height());
}

TEST_F(ToolsTest, AnArrowStyleIsDrawnAsChosen)
{
    tools.setTool("arrow");
    tools.style().arrow = "curved";
    ASSERT_TRUE(drag(QPointF(0, 0), QPointF(100, 0)));
    EXPECT_EQ(arrowStyle(stack.layers()[0]), "curved");
    QPointF ctrl;
    EXPECT_TRUE(readPoint(stack.layers()[0].fields, "ctrl", &ctrl));
    EXPECT_EQ(tools.selectionHandles().size(), 3) << "the ends and the curve's control point";
}

TEST_F(ToolsTest, SelectPicksMovesAndTheMoveIsOneStep)
{
    tools.setTool("rectangle");
    ASSERT_TRUE(drag(QPointF(10, 10), QPointF(60, 40)));
    tools.setTool("select");
    tools.select(0);
    ASSERT_TRUE(tools.press(QPointF(10, 25), 3)) << "on the left edge";
    EXPECT_EQ(tools.selected(), 1);
    tools.move(QPointF(20, 35), false);
    tools.move(QPointF(30, 45), false);
    EXPECT_TRUE(tools.release(QPointF(30, 45), false));
    QRectF box;
    ASSERT_TRUE(readBox(stack.layers()[0], &box));
    EXPECT_EQ(box, QRectF(30, 30, 50, 30)) << "moved by the pointer's total";
    EXPECT_EQ(stack.undoSteps(), 2) << "the drawing and the move";
    stack.undo();
    ASSERT_TRUE(readBox(stack.layers()[0], &box));
    EXPECT_EQ(box, QRectF(10, 10, 50, 30)) << "one undo puts the whole move back";
}

TEST_F(ToolsTest, ClickingNothingDeselects)
{
    tools.setTool("rectangle");
    ASSERT_TRUE(drag(QPointF(10, 10), QPointF(60, 40)));
    tools.setTool("select");
    EXPECT_FALSE(tools.press(QPointF(200, 200), 3));
    EXPECT_EQ(tools.selected(), 0);
    EXPECT_FALSE(tools.release(QPointF(200, 200), false));
}

TEST_F(ToolsTest, AHandleResizesAndAnUndoRestores)
{
    tools.setTool("ellipse");
    ASSERT_TRUE(drag(QPointF(10, 10), QPointF(50, 30)));
    tools.setTool("select");
    ASSERT_TRUE(tools.press(QPointF(50, 30), 3)) << "the bottom right handle wins over the shape under it";
    tools.move(QPointF(70, 60), false);
    ASSERT_TRUE(tools.release(QPointF(90, 70), false));
    QRectF box;
    ASSERT_TRUE(readBox(stack.layers()[0], &box));
    EXPECT_EQ(box, QRectF(10, 10, 80, 60));
    EXPECT_EQ(stack.layers().size(), 1) << "resized, not duplicated";
    stack.undo();
    ASSERT_TRUE(readBox(stack.layers()[0], &box));
    EXPECT_EQ(box, QRectF(10, 10, 40, 20));
}

TEST_F(ToolsTest, ALineEndIsMovedByItsHandle)
{
    tools.setTool("line");
    ASSERT_TRUE(drag(QPointF(0, 0), QPointF(100, 0)));
    tools.setTool("select");
    ASSERT_TRUE(tools.press(QPointF(100, 0), 3));
    ASSERT_TRUE(tools.release(QPointF(100, 40), false));
    QPointF to, from;
    ASSERT_TRUE(readPoint(stack.layers()[0].fields, "to", &to));
    ASSERT_TRUE(readPoint(stack.layers()[0].fields, "from", &from));
    EXPECT_EQ(to, QPointF(100, 40));
    EXPECT_EQ(from, QPointF(0, 0));
}

TEST_F(ToolsTest, DeleteAndNudgeAreStepsOfTheirOwn)
{
    tools.setTool("rectangle");
    ASSERT_TRUE(drag(QPointF(10, 10), QPointF(60, 40)));
    EXPECT_TRUE(tools.nudgeSelected(QPointF(1, 0)));
    QRectF box;
    ASSERT_TRUE(readBox(stack.layers()[0], &box));
    EXPECT_EQ(box.x(), 11);
    EXPECT_EQ(stack.undoSteps(), 2);
    EXPECT_TRUE(tools.deleteSelected());
    EXPECT_TRUE(stack.layers().isEmpty());
    EXPECT_EQ(tools.selected(), 0);
    EXPECT_FALSE(tools.deleteSelected()) << "nothing selected";
    stack.undo();
    tools.syncSelection();
    EXPECT_EQ(stack.layers().size(), 1) << "the delete is undone";
}

TEST_F(ToolsTest, TheSelectionFollowsUndo)
{
    tools.setTool("rectangle");
    ASSERT_TRUE(drag(QPointF(10, 10), QPointF(60, 40)));
    ASSERT_EQ(tools.selected(), 1);
    stack.undo();
    tools.syncSelection();
    EXPECT_EQ(tools.selected(), 0) << "its layer is gone";
    stack.redo();
    tools.syncSelection();
    EXPECT_EQ(tools.selected(), 0) << "and a redo does not select it again";
}

TEST_F(ToolsTest, ANewToolCancelsAGestureInProgress)
{
    tools.setTool("rectangle");
    ASSERT_TRUE(tools.press(QPointF(0, 0), 3));
    tools.move(QPointF(40, 40), false);
    EXPECT_EQ(stack.layers().size(), 1);
    tools.setTool("line");
    EXPECT_TRUE(stack.layers().isEmpty());
    EXPECT_FALSE(tools.busy());
}

// ---- the backend: the document, Done and Revert with real shapes ------------------------------------------------------------

namespace {

class AppTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        ASSERT_TRUE(QDir().mkpath(m_dir.path() + "/pics"));
        QImage image(80, 60, QImage::Format_RGB32);
        image.fill(Qt::white);
        m_file = m_dir.path() + "/pics/Screenshot.png";
        ASSERT_TRUE(image.save(m_file, "PNG"));
        m_app = std::make_unique<ScreenshotApp>(m_file, QStringList(), m_dir.path() + "/state");
        ASSERT_TRUE(m_app->errors().isEmpty());
    }

    QTemporaryDir m_dir;
    QString m_file;
    std::unique_ptr<ScreenshotApp> m_app;
};

} // namespace

TEST_F(AppTest, DrawingMakesTheDocumentDirtyAndUndoClearsIt)
{
    EXPECT_FALSE(m_app->dirty());
    EXPECT_FALSE(m_app->canUndo());
    m_app->setToolColor("#ff0000");
    m_app->setTool("rectangle");
    ASSERT_TRUE(m_app->toolPress(10, 10, 3));
    m_app->toolMove(40, 30, false);
    EXPECT_TRUE(m_app->dirty());
    m_app->toolRelease(60, 40, false);
    EXPECT_TRUE(m_app->dirty());
    EXPECT_TRUE(m_app->canUndo());
    EXPECT_EQ(m_app->selectedId(), 1);
    EXPECT_EQ(m_app->handles().size(), 8);

    m_app->undo();
    EXPECT_FALSE(m_app->dirty()) << "back to what is saved";
    EXPECT_TRUE(m_app->canRedo());
    EXPECT_EQ(m_app->selectedId(), 0);
    m_app->redo();
    EXPECT_TRUE(m_app->dirty());
}

TEST_F(AppTest, NoColourNoShape)
{
    m_app->setTool("rectangle");
    EXPECT_FALSE(m_app->toolPress(10, 10, 3)) << "a shape with no colour would draw nothing";
    m_app->setToolColor("red"); // not one of the two forms: refused
    EXPECT_TRUE(m_app->toolColor().isEmpty());
}

TEST_F(AppTest, DoneWritesTheShapesAndRevertTakesThemOff)
{
    m_app->setToolColor("#ff0000");
    m_app->setToolWidth(4);
    m_app->setTool("rectangle");
    ASSERT_TRUE(m_app->toolPress(10, 10, 3));
    m_app->toolRelease(60, 40, false);
    ASSERT_TRUE(m_app->done());
    EXPECT_FALSE(m_app->dirty());
    EXPECT_TRUE(m_app->canRevert());
    EXPECT_EQ(QImage(m_file).pixelColor(10, 25), QColor(255, 0, 0)) << "the file holds the drawn picture";
    EXPECT_EQ(QImage(m_file).pixelColor(30, 25), QColor(Qt::white));

    ASSERT_TRUE(m_app->revert());
    EXPECT_EQ(QImage(m_file).pixelColor(10, 25), QColor(Qt::white)) << "the original is back";
    EXPECT_FALSE(m_app->canUndo()) << "a revert clears the undo stack with the layers";
    EXPECT_TRUE(m_app->handles().isEmpty());

    // Reopened after a Done, the shapes are still layers: they can be moved.
    m_app->setTool("rectangle");
    ASSERT_TRUE(m_app->toolPress(10, 10, 3));
    m_app->toolRelease(60, 40, false);
    ASSERT_TRUE(m_app->done());
    ScreenshotApp again(m_file, QStringList(), m_dir.path() + "/state");
    again.setTool("select");
    ASSERT_TRUE(again.toolPress(10, 25, 3)) << "the layer came back with the file";
    again.toolRelease(10, 25, false);
    EXPECT_EQ(again.selectedId(), 1);
}

TEST_F(AppTest, TheLayerModelFollowsTheEditsRowByRow)
{
    auto *model = qobject_cast<QAbstractItemModel *>(m_app->layerModel());
    ASSERT_NE(model, nullptr);
    EXPECT_EQ(model->rowCount(), 0);
    int inserted = 0, changed = 0, removed = 0, resets = 0;
    QObject::connect(model, &QAbstractItemModel::rowsInserted, [&] { ++inserted; });
    QObject::connect(model, &QAbstractItemModel::dataChanged, [&] { ++changed; });
    QObject::connect(model, &QAbstractItemModel::rowsRemoved, [&] { ++removed; });
    QObject::connect(model, &QAbstractItemModel::modelReset, [&] { ++resets; });

    m_app->setToolColor("#ff0000");
    m_app->setTool("line");
    ASSERT_TRUE(m_app->toolPress(5, 30, 3));
    m_app->toolMove(40, 30, false);
    EXPECT_EQ(model->rowCount(), 1) << "the shape is there while it is dragged";
    EXPECT_EQ(inserted, 1);
    m_app->toolMove(60, 30, false);
    m_app->toolRelease(75, 30, false);
    EXPECT_EQ(inserted, 1) << "dragging edits the one row";
    EXPECT_GE(changed, 2);
    EXPECT_EQ(resets, 0);
    EXPECT_EQ(model->data(model->index(0, 0), LayerModel::KindRole).toString(), "line");

    m_app->setTool("rectangle");
    ASSERT_TRUE(m_app->toolPress(10, 10, 3));
    m_app->toolRelease(50, 40, false);
    EXPECT_EQ(model->rowCount(), 2);
    const int changesBefore = changed;
    m_app->setTool("select");
    ASSERT_TRUE(m_app->toolPress(10, 25, 3));
    m_app->toolMove(12, 25, false);
    m_app->toolRelease(14, 25, false);
    EXPECT_GT(changed, changesBefore);
    EXPECT_EQ(resets, 0) << "moving a shape touches no other row";

    m_app->undo();
    EXPECT_EQ(model->rowCount(), 2) << "undo of the move";
    m_app->undo();
    EXPECT_EQ(model->rowCount(), 1);
    EXPECT_EQ(removed, 1);
    m_app->deleteSelected();
    m_app->selectNone();
}

TEST_F(AppTest, TheCaptureScaleComesFromThePngAndSurvivesDone)
{
    EXPECT_EQ(m_app->captureScale(), 0) << "a file that does not say";
    QImage image(80, 60, QImage::Format_RGB32);
    image.fill(Qt::white);
    image.setText("Grassfield-Scale", "1.25");
    const QString scaled = m_dir.path() + "/pics/Scaled.png";
    ASSERT_TRUE(image.save(scaled, "PNG"));
    ScreenshotApp app(scaled, QStringList(), m_dir.path() + "/state2");
    EXPECT_DOUBLE_EQ(app.captureScale(), 1.25);
    app.setToolColor("#ff0000");
    app.setTool("line");
    ASSERT_TRUE(app.toolPress(5, 30, 3));
    app.toolRelease(75, 30, false);
    ASSERT_TRUE(app.done());
    ScreenshotApp again(scaled, QStringList(), m_dir.path() + "/state2");
    EXPECT_DOUBLE_EQ(again.captureScale(), 1.25) << "the edited file keeps the capture's scale";
    image.setText("Grassfield-Scale", "40");
    ASSERT_TRUE(image.save(scaled, "PNG"));
    ScreenshotApp odd(scaled, QStringList(), m_dir.path() + "/state3");
    EXPECT_EQ(odd.captureScale(), 0) << "a value out of range is no scale";
}
