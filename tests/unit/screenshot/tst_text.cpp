// Text (three styles) and counters (slice B6): the layers, their geometry from glyph outlines, the numbering of counters (a place among
// the counters, never stored, so that a deletion renumbers), the backend's editor state and the export. The goldens are in
// tst_golden.cpp and the scene-against-exporter bound in tst_scene.cpp; those need the font the layers name (kFamily), and the
// tests here that do not are font-independent.
#include "annotations.h"
#include "exporter.h"
#include "layermodel.h"
#include "screenshotapp.h"
#include "toolcontroller.h"
#include "undostack.h"

#include <QDir>
#include <QFontDatabase>
#include <QImage>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <memory>

using namespace screenshot;

namespace {

ShapeStyle textStyle(const char *style = "plain", qreal size = 24)
{
    ShapeStyle s;
    s.color = QStringLiteral("#0167fd");
    s.textStyle = QString::fromLatin1(style);
    s.textSize = size;
    s.counterSize = 28;
    return s;
}

// How many pixels of `image` differ from `base` (a count of pixels that are not the same colour).
long changedPixels(const QImage &image, const QImage &base)
{
    long count = 0;
    for (int y = 0; y < image.height(); ++y) {
        for (int x = 0; x < image.width(); ++x)
            count += image.pixel(x, y) != base.pixel(x, y);
    }
    return count;
}

QImage white(int w, int h)
{
    QImage image(w, h, QImage::Format_RGB32);
    image.fill(Qt::white);
    return image;
}

} // namespace

TEST(Text, ALayerHoldsTheTextItsStyleAndItsCentre)
{
    const Layer text = makeText(4, QPointF(50, 30), "Hello\nthere", textStyle("outlined", 30));
    ASSERT_EQ(text.id, 4);
    EXPECT_EQ(text.type, "text");
    EXPECT_EQ(layerText(text), "Hello\nthere");
    EXPECT_EQ(text.fields.value("style").toString(), "outlined");
    EXPECT_EQ(text.fields.value("size").toDouble(), 30);
    EXPECT_EQ(text.fields.value("rot").toInt(), 0);
    EXPECT_EQ(makeText(1, QPointF(1, 1), "", textStyle()).id, 0) << "no text, no layer";
    EXPECT_EQ(makeText(1, QPointF(1, 1), "   \n ", textStyle()).id, 0);
    EXPECT_EQ(makeText(1, QPointF(1, 1), QString(kMaxTextLength + 1, 'x'), textStyle()).id, 0);
    EXPECT_EQ(makeText(1, QPointF(NAN, 1), "a", textStyle()).id, 0);
    EXPECT_EQ(makeText(1, QPointF(1, 1), "a", textStyle("fancy")).fields.value("style").toString(), "plain") << "an unknown style is the plain one";
    ShapeStyle huge = textStyle();
    huge.textSize = 1e6;
    EXPECT_EQ(makeText(1, QPointF(1, 1), "a", huge).fields.value("size").toDouble(), kMaxTextSize);
}

TEST(Text, TheThreeStylesAreDrawnAsTheyAreNamed)
{
    const QPointF c(80, 40);
    const ShapeGeometry plain = shapeGeometry(makeText(1, c, "Look", textStyle("plain")));
    const ShapeGeometry outlined = shapeGeometry(makeText(1, c, "Look", textStyle("outlined")));
    const ShapeGeometry pill = shapeGeometry(makeText(1, c, "Look", textStyle("pill")));
    for (const ShapeGeometry *g : {&plain, &outlined, &pill}) {
        ASSERT_EQ(g->kind, ShapeGeometry::Glyphs);
        EXPECT_FALSE(g->path.isEmpty());
        EXPECT_LT(QLineF(g->path.boundingRect().center(), c).length(), 12) << "centred on the layer's centre";
    }
    EXPECT_EQ(plain.ink, QColor("#0167fd"));
    EXPECT_TRUE(plain.plate.isEmpty());
    EXPECT_EQ(plain.outlineWidth, 0);

    EXPECT_EQ(outlined.ink, QColor("#0167fd"));
    EXPECT_GT(outlined.outlineWidth, 0);
    EXPECT_TRUE(outlined.plate.isEmpty());
    EXPECT_NE(outlined.outlineColor, outlined.ink) << "an edge that sets the text off";

    EXPECT_FALSE(pill.plate.isEmpty());
    EXPECT_EQ(pill.plateColor, QColor("#0167fd")) << "the layer's colour is the pill";
    EXPECT_NE(pill.ink, pill.plateColor) << "the text reads on it";
    EXPECT_TRUE(pill.plate.boundingRect().contains(pill.path.boundingRect())) << "the pill holds the text";
}

TEST(Text, TheLettersAreWhicheverOfBlackAndWhiteReadsOnTheColour)
{
    const auto inkOn = [](const char *color) {
        ShapeStyle s = textStyle("pill");
        s.color = QString::fromLatin1(color);
        return shapeGeometry(makeText(1, QPointF(0, 0), "a", s)).ink;
    };
    EXPECT_EQ(inkOn("#fcea21"), QColor(Qt::black)) << "yellow";
    EXPECT_EQ(inkOn("#ffffff"), QColor(Qt::black));
    EXPECT_EQ(inkOn("#0167fd"), QColor(Qt::white));
    EXPECT_EQ(inkOn("#000000"), QColor(Qt::white));
    EXPECT_EQ(inkOn("#de3651"), QColor(Qt::black)) << "the one with the better contrast (4.7 against 4.4 for white)";
    EXPECT_EQ(inkOn("#783b93"), QColor(Qt::white));
}

TEST(Text, ItGrowsWithItsSizeAndWithMoreLines)
{
    const auto bounds = [](const char *text, qreal size) { return layerBounds(makeText(1, QPointF(100, 100), text, textStyle("plain", size))); };
    const QRectF small = bounds("Hello", 20), big = bounds("Hello", 40);
    EXPECT_NEAR(big.width() / small.width(), 2, 0.02);
    EXPECT_NEAR(big.height() / small.height(), 2, 0.02);
    EXPECT_GT(bounds("Hello\nHello", 20).height(), small.height() * 1.8);
    EXPECT_NEAR(bounds("Hello\nHello", 20).width(), small.width(), 0.5) << "lines are centred on each other";
    EXPECT_LT(bounds("Hi", 20).width(), small.width());
}

TEST(Text, ATurnedTextIsTurnedAboutItsCentre)
{
    Layer text = makeText(1, QPointF(100, 100), "Hello there", textStyle());
    const QRectF flat = layerBounds(text);
    text.fields.insert("rot", 1);
    const QRectF turned = layerBounds(text);
    EXPECT_NEAR(turned.width(), flat.height(), 0.01);
    EXPECT_NEAR(turned.height(), flat.width(), 0.01);
    EXPECT_LT(QLineF(turned.center(), flat.center()).length(), 0.01);
    text.fields.insert("rot", 2);
    EXPECT_NEAR(layerBounds(text).width(), flat.width(), 0.01);
    text.fields.insert("rot", 7);
    EXPECT_NEAR(layerBounds(text).width(), turned.width(), 0.01) << "7 turns read as 3 (mod 4)";
}

TEST(Text, ItIsPickedMovedAndRestyled)
{
    const Layer text = makeText(1, QPointF(100, 100), "Hello", textStyle("plain", 30));
    const QRectF box = layerBounds(text);
    EXPECT_TRUE(hitLayer(text, box.center(), 3));
    EXPECT_TRUE(hitLayer(text, QPointF(box.left() - 2, box.center().y()), 3));
    EXPECT_FALSE(hitLayer(text, QPointF(box.left() - 10, box.center().y()), 3));
    EXPECT_TRUE(handlesOf(text).isEmpty()) << "its size is a style control, not a handle";
    EXPECT_EQ(layerBounds(translated(text, QPointF(7, -4))), box.translated(7, -4));
    EXPECT_EQ(layerText(withText(text, "Bye")), "Bye");
    EXPECT_EQ(withText(text, "  "), text) << "an empty text is not a text";
    EXPECT_EQ(withTextStyle(text, "pill").fields.value("style").toString(), "pill");
    EXPECT_EQ(withTextSize(text, 60).fields.value("size").toDouble(), 60);
    EXPECT_EQ(withTextSize(text, 1e9).fields.value("size").toDouble(), kMaxTextSize);
    EXPECT_EQ(withWidth(text, 9), text) << "a text has no stroke width";
    EXPECT_EQ(withFill(text, true), text);
    EXPECT_EQ(withColor(text, "#ff0000").fields.value("color").toString(), "#ff0000");
    EXPECT_EQ(withColor(text, "red"), text) << "only the two forms of colour";
    Layer broken = text;
    broken.fields.insert("size", -1);
    EXPECT_EQ(shapeGeometry(broken).kind, ShapeGeometry::None);
    broken = text;
    broken.fields.insert("x", "left");
    EXPECT_EQ(shapeGeometry(broken).kind, ShapeGeometry::None);
    broken = text;
    broken.fields.insert("text", QString(kMaxTextLength + 1, 'x'));
    EXPECT_EQ(shapeGeometry(broken).kind, ShapeGeometry::None);
}

TEST(Text, TheExportDrawsTheTextInItsColour)
{
    const QImage base = white(160, 60);
    for (const char *style : {"plain", "outlined", "pill"}) {
        const QImage out = exportLayers(base, {makeText(1, QPointF(80, 30), "Hello", textStyle(style, 28))});
        EXPECT_GT(changedPixels(out, base), 100) << style;
        EXPECT_EQ(out.pixelColor(2, 2), QColor(Qt::white)) << "the corner is untouched";
    }
    // The pill is a solid plate of the colour: its left end, before the letters begin, is the colour.
    const QImage pill = exportLayers(base, {makeText(1, QPointF(80, 30), "Hello", textStyle("pill", 28))});
    const ShapeGeometry g = shapeGeometry(makeText(1, QPointF(80, 30), "Hello", textStyle("pill", 28)));
    const QRectF plate = g.plate.boundingRect();
    EXPECT_EQ(pill.pixelColor(int(plate.left()) + 6, int(plate.center().y())), QColor("#0167fd"));
    EXPECT_EQ(pill.pixelColor(int(plate.left()) - 3, int(plate.center().y())), QColor(Qt::white)) << "and outside it the picture";
}

// ---- counters --------------------------------------------------------------------------------------------------------------------

TEST(Counters, ANumberIsThePlaceAmongTheCountersAndIsNeverStored)
{
    ShapeStyle style = textStyle();
    Layers layers{makeCounter(1, QPointF(20, 20), style), makeShape(2, "line", QPointF(0, 0), QPointF(5, 5), style), makeCounter(3, QPointF(60, 20), style),
                  makeCounter(4, QPointF(100, 20), style)};
    EXPECT_EQ(counterNumbers(layers), (QList<int>{1, 0, 2, 3}));
    EXPECT_FALSE(layers[0].fields.contains("n")) << "nothing numbered in the file";
    EXPECT_FALSE(layers[0].fields.contains("number"));
    layers.removeAt(0);
    EXPECT_EQ(counterNumbers(layers), (QList<int>{0, 1, 2})) << "a deletion renumbers";
    layers.insert(0, makeCounter(9, QPointF(0, 0), style));
    EXPECT_EQ(counterNumbers(layers), (QList<int>{1, 0, 2, 3})) << "and an undo of it puts them back";
}

TEST(Counters, TheGeometryIsADiscWithItsNumberInTheMiddle)
{
    const Layer counter = makeCounter(1, QPointF(50, 40), textStyle());
    const ShapeGeometry one = shapeGeometry(counter, 1), twelve = shapeGeometry(counter, 12);
    ASSERT_EQ(one.kind, ShapeGeometry::Glyphs);
    EXPECT_EQ(one.plate.boundingRect(), QRectF(36, 26, 28, 28));
    EXPECT_EQ(one.plateColor, QColor("#0167fd"));
    EXPECT_EQ(one.ink, QColor(Qt::white));
    for (const ShapeGeometry *g : {&one, &twelve}) {
        EXPECT_LT(QLineF(g->path.boundingRect().center(), QPointF(50, 40)).length(), 0.01) << "the number's ink is centred in the disc";
        EXPECT_TRUE(g->plate.boundingRect().contains(g->path.boundingRect()));
    }
    EXPECT_GT(twelve.path.boundingRect().width(), one.path.boundingRect().width());
    EXPECT_LE(twelve.path.boundingRect().width(), 28 * 0.7 + 0.01) << "a longer number shrinks to stay in the disc";
    EXPECT_LE(shapeGeometry(counter, 1234).path.boundingRect().width(), 28 * 0.7 + 0.01);
    EXPECT_EQ(shapeGeometry(counter, 0).kind, ShapeGeometry::Glyphs) << "a counter that was not numbered reads as 1";
    EXPECT_TRUE(hitLayer(counter, QPointF(50, 40), 2));
    EXPECT_TRUE(hitLayer(counter, QPointF(63, 40), 2));
    EXPECT_FALSE(hitLayer(counter, QPointF(70, 40), 2));
    EXPECT_TRUE(handlesOf(counter).isEmpty());
    EXPECT_EQ(layerBounds(counter), QRectF(36, 26, 28, 28));
    EXPECT_EQ(withTextSize(counter, 40).fields.value("size").toDouble(), 40);
}

TEST(Counters, CountersRenumberAfterADeletionInTheExportToo)
{
    const ShapeStyle style = textStyle();
    const Layer first = makeCounter(1, QPointF(30, 30), style), second = makeCounter(2, QPointF(90, 30), style);
    const QImage base = white(130, 60);
    // Two counters: "1" and "2". After the first is deleted, the second reads "1" where it stands.
    const QImage both = exportLayers(base, {first, second});
    const QImage afterDelete = exportLayers(base, {second});
    // The second counter's disc area differs between "2" and "1": the number changed with the deletion.
    const QRect disc(76, 16, 28, 28);
    EXPECT_NE(both.copy(disc), afterDelete.copy(disc)) << "the remaining counter now says 1";
    // And that picture is the one a single counter at that place gives when it is the first.
    const Layers onlyOneAtThePlace{makeCounter(7, QPointF(90, 30), style)};
    EXPECT_EQ(exportLayers(base, onlyOneAtThePlace).copy(disc), afterDelete.copy(disc));
}

TEST(Counters, TheModelRenumbersTheRowsAfterADeletionAndAnUndo)
{
    const ShapeStyle style = textStyle();
    // At one place, so that what a row draws depends on its number alone.
    Layers layers{makeCounter(1, QPointF(20, 20), style), makeCounter(2, QPointF(20, 20), style), makeCounter(3, QPointF(20, 20), style)};
    LayerModel model;
    model.setLayers(layers);
    const auto path = [&](int row) { return model.data(model.index(row), LayerModel::PathRole).toString(); };
    const QString one = shapeGeometry(layers[0], 1).path.isEmpty() ? QString() : path(0);
    ASSERT_FALSE(one.isEmpty());
    EXPECT_NE(path(1), path(0));
    EXPECT_NE(path(2), path(1));

    int changed = 0, firstRow = -1, lastRow = -1;
    QObject::connect(&model, &QAbstractItemModel::dataChanged, [&](const QModelIndex &a, const QModelIndex &b) {
        ++changed;
        firstRow = a.row();
        lastRow = b.row();
    });
    const QString secondBefore = path(1), thirdBefore = path(2);
    layers.removeAt(0);
    EXPECT_EQ(model.setLayers(layers), 3);
    EXPECT_EQ(changed, 1) << "the counters after the row that went are told";
    EXPECT_EQ(firstRow, 0);
    EXPECT_EQ(lastRow, 1);
    EXPECT_EQ(path(0), one) << "the old second counter now draws a 1";
    EXPECT_NE(path(0), secondBefore);
    EXPECT_NE(path(1), thirdBefore) << "the old third counter now draws a 2";
    EXPECT_EQ(path(1), secondBefore);

    layers.insert(0, makeCounter(1, QPointF(20, 20), style));
    EXPECT_EQ(model.setLayers(layers), 2);
    EXPECT_EQ(path(1), secondBefore) << "an undo puts the numbers back";
    EXPECT_EQ(path(2), thirdBefore);
}

// ---- the tools' gestures and the backend ------------------------------------------------------------------------------------------

TEST(Counters, AClickPutsOneAndADragCarriesItBeforeTheRelease)
{
    UndoStack stack;
    ToolController tools(&stack);
    tools.style().color = "#de3651";
    ASSERT_TRUE(tools.setTool("counter"));
    ASSERT_TRUE(tools.press(QPointF(30, 30), 3));
    EXPECT_TRUE(tools.release(QPointF(30, 30), false)) << "a click, no drag";
    ASSERT_EQ(stack.layers().size(), 1);
    EXPECT_EQ(stack.layers()[0].type, "counter");
    EXPECT_EQ(stack.undoSteps(), 1);
    EXPECT_EQ(tools.selected(), 1);

    ASSERT_TRUE(tools.press(QPointF(60, 30), 3));
    tools.move(QPointF(80, 50), false);
    EXPECT_TRUE(tools.release(QPointF(90, 55), false));
    ASSERT_EQ(stack.layers().size(), 2);
    EXPECT_EQ(layerBounds(stack.layers()[1]).center(), QPointF(90, 55)) << "it ended where the button was let go";
    EXPECT_EQ(counterNumbers(stack.layers()), (QList<int>{1, 2}));
    ASSERT_TRUE(tools.deleteSelected());
    ASSERT_TRUE(tools.setTool("select"));
    ASSERT_TRUE(tools.press(QPointF(30, 30), 3));
    tools.release(QPointF(30, 30), false);
    ASSERT_TRUE(tools.deleteSelected());
    EXPECT_TRUE(stack.layers().isEmpty());
    EXPECT_TRUE(stack.undo());
    EXPECT_EQ(counterNumbers(stack.layers()), (QList<int>{1}));
}

namespace {

class TextApp : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        m_file = m_dir.path() + "/Screenshot.png";
        QImage image(200, 100, QImage::Format_RGB32);
        image.fill(Qt::white);
        ASSERT_TRUE(image.save(m_file, "PNG"));
        m_app = std::make_unique<ScreenshotApp>(m_file, QStringList(), m_dir.path() + "/state");
        ASSERT_TRUE(m_app->errors().isEmpty());
        m_app->setToolColor("#0167fd");
        m_app->setTextSize(24);
    }
    QTemporaryDir m_dir;
    QString m_file;
    std::unique_ptr<ScreenshotApp> m_app;
};

} // namespace

TEST_F(TextApp, ATextToolClickOpensTheEditorAndCommittingPutsTheTextThere)
{
    m_app->setTool("text");
    ASSERT_TRUE(m_app->toolPress(30, 20, 3));
    EXPECT_TRUE(m_app->textEditing());
    EXPECT_EQ(m_app->textEditId(), 0);
    EXPECT_EQ(m_app->textEditPos(), QPointF(30, 20));
    EXPECT_EQ(m_app->textEditText(), QString());
    EXPECT_FALSE(m_app->dirty()) << "nothing yet";
    m_app->toolRelease(30, 20, false);

    m_app->commitText("Look here");
    EXPECT_FALSE(m_app->textEditing());
    ASSERT_TRUE(m_app->canUndo());
    EXPECT_EQ(m_app->selectedType(), "text");
    const QRectF box = m_app->selectionBounds();
    EXPECT_NEAR(box.left(), 30, 0.5) << "the click is the top left of the text";
    EXPECT_NEAR(box.top(), 20, 0.5);
    m_app->undo();
    EXPECT_FALSE(m_app->dirty());
}

TEST_F(TextApp, NothingTypedMakesNoLayerAndCancelLeavesTheLayersAlone)
{
    m_app->setTool("text");
    m_app->toolPress(30, 20, 3);
    m_app->commitText("  ");
    EXPECT_FALSE(m_app->textEditing());
    EXPECT_FALSE(m_app->dirty());
    m_app->toolPress(30, 20, 3);
    m_app->cancelText();
    EXPECT_FALSE(m_app->textEditing());
    m_app->commitText("late"); // after a cancel the editor is gone: nothing happens
    EXPECT_FALSE(m_app->dirty());
}

TEST_F(TextApp, ATextIsEditedByClickingItAndErasingItsTextRemovesIt)
{
    m_app->setTool("text");
    m_app->toolPress(30, 20, 3);
    m_app->commitText("Hello");
    const QRectF before = m_app->selectionBounds();
    m_app->selectNone();

    ASSERT_TRUE(m_app->toolPress(before.center().x(), before.center().y(), 3)) << "a click on the text edits it";
    EXPECT_TRUE(m_app->textEditing());
    EXPECT_EQ(m_app->textEditId(), 1);
    EXPECT_EQ(m_app->textEditText(), "Hello");
    EXPECT_NEAR(m_app->textEditPos().x(), before.left(), 0.01);
    m_app->commitText("Hello, world");
    EXPECT_NEAR(m_app->selectionBounds().left(), before.left(), 0.5) << "the text stays where it began";
    EXPECT_GT(m_app->selectionBounds().width(), before.width());
    EXPECT_EQ(m_app->selectedId(), 1);

    m_app->editSelectedText();
    EXPECT_TRUE(m_app->textEditing());
    EXPECT_EQ(m_app->textEditText(), "Hello, world");
    m_app->commitText("");
    EXPECT_EQ(m_app->selectedId(), 0) << "no text left: no layer";
    m_app->undo();
    EXPECT_EQ(m_app->selectedId(), 0);
    m_app->undo();
    m_app->undo();
    EXPECT_FALSE(m_app->canUndo());
    EXPECT_FALSE(m_app->dirty());
}

TEST_F(TextApp, TheStyleControlsApplyToTheSelectedTextAndToTheNextOne)
{
    m_app->setTool("text");
    m_app->toolPress(30, 20, 3);
    m_app->commitText("Hello");
    const QRectF small = m_app->selectionBounds();
    m_app->applyTextSize(48);
    EXPECT_NEAR(m_app->selectionBounds().width() / small.width(), 2, 0.05);
    EXPECT_EQ(m_app->textSize(), 48);
    m_app->applyTextStyle("pill");
    EXPECT_EQ(m_app->textStyle(), "pill");
    EXPECT_GT(m_app->selectionBounds().width(), small.width() * 2) << "the pill is wider than the text";
    m_app->applyTextStyle("sparkly");
    EXPECT_EQ(m_app->textStyle(), "pill") << "not a style";
    m_app->applyTextSize(0);
    EXPECT_EQ(m_app->textSize(), 48);
    m_app->undo();
    m_app->undo();
    EXPECT_NEAR(m_app->selectionBounds().width(), small.width(), 0.01) << "each control was one step";
}

TEST_F(TextApp, CountersRenumberWhenOneIsDeletedAndDoneWritesTheNumbers)
{
    m_app->setTool("counter");
    for (const QPointF &p : {QPointF(30, 50), QPointF(90, 50), QPointF(150, 50)}) {
        ASSERT_TRUE(m_app->toolPress(p.x(), p.y(), 3));
        m_app->toolRelease(p.x(), p.y(), false);
    }
    m_app->setTool("select");
    ASSERT_TRUE(m_app->toolPress(30, 50, 3));
    m_app->toolRelease(30, 50, false);
    ASSERT_EQ(m_app->selectedId(), 1);
    m_app->deleteSelected();
    auto *model = qobject_cast<LayerModel *>(m_app->layerModel());
    ASSERT_NE(model, nullptr);
    ASSERT_EQ(model->rowCount(), 2);
    // What each remaining counter draws is what a counter in that place of the sequence draws.
    const ShapeStyle style = [&] {
        ShapeStyle s;
        s.color = "#0167fd";
        s.counterSize = m_app->counterSize();
        s.family = m_app->textFamily();
        return s;
    }();
    EXPECT_EQ(model->data(model->index(0), LayerModel::PathRole).toString(), pathToSvg(shapeGeometry(makeCounter(2, QPointF(90, 50), style), 1).path));
    EXPECT_EQ(model->data(model->index(1), LayerModel::PathRole).toString(), pathToSvg(shapeGeometry(makeCounter(3, QPointF(150, 50), style), 2).path));
    ASSERT_TRUE(m_app->done());
    EXPECT_EQ(QImage(m_file).pixelColor(90, 40), QColor("#0167fd")) << "the disc is in the file";
}
