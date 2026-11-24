// The editor's shapes as scene items (qml/ShapeScene.qml over the LayerModel): the model's row-by-row updates, the agreement of the
// scene with the exporter at several zooms, the clip to the picture, the scene's alignment under the zoom and the cost of an edit.
//
// The scene is rendered here with Qt Quick's software backend (QQuickWindow::setGraphicsApi(Software)): there is no GPU in the unit
// tests, and the software renderer draws the same paths with QPainter. That proves the geometry (every point the items are given)
// and the composition; the curve renderer the app uses on the GPU is checked on the nested screenshots, not here.
#include "annotations.h"
#include "exporter.h"
#include "layermodel.h"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QGuiApplication>
#include <QImage>
#include <QPainter>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGRendererInterface>

#include <gtest/gtest.h>

#include <cstdio>
#include <memory>

#ifndef GF_SCREENSHOT_QML_DIR
#error "GF_SCREENSHOT_QML_DIR names apps/screenshot/qml (build-direct.sh and CMakeLists.txt define it)"
#endif

using namespace screenshot;

namespace {

ShapeStyle style(const char *color, qreal width, bool fill = false, const char *arrow = "straight")
{
    ShapeStyle s;
    s.color = QString::fromLatin1(color);
    s.width = width;
    s.fill = fill;
    s.arrow = QString::fromLatin1(arrow);
    return s;
}

// One layer of every kind, over each other, some past the picture's edge.
Layers allKinds()
{
    return {makeShape(1, "rectangle", QPointF(10, 8), QPointF(70, 40), style("#0167fd", 3)),
            makeShape(2, "rectangle", QPointF(-10, 30), QPointF(30, 70), style("#80195e3f", 4, true)),
            makeShape(3, "ellipse", QPointF(20, 5), QPointF(75, 45), style("#de3651", 3)),
            makeShape(4, "ellipse", QPointF(40, 20), QPointF(90, 60), style("#7fb844", 2, true)),
            makeShape(5, "line", QPointF(5, 45), QPointF(75, 10), style("#0167fd", 4)),
            makeShape(6, "arrow", QPointF(8, 48), QPointF(70, 12), style("#de3651", 3)),
            makeShape(7, "arrow", QPointF(10, 25), QPointF(72, 25), style("#de3651", 3, false, "double")),
            makeShape(8, "arrow", QPointF(12, 46), QPointF(70, 30), style("#de3651", 3, false, "curved"))};
}

// The kinds of slices B5 and B6: pen, highlighter, the three text styles (one of two lines, one turned) and two counters.
ShapeStyle penLook(const char *color, qreal width)
{
    ShapeStyle s = style(color, width);
    s.highlightFactor = 4;
    s.highlightOpacity = 0.45;
    s.textSize = 14;
    s.counterSize = 18;
    return s;
}

Layers newKinds()
{
    ShapeStyle plain = penLook("#0167fd", 3), outlined = plain, pill = plain;
    outlined.textStyle = "outlined";
    outlined.color = "#fcea21"; // yellow: its edge is black, which shows on the scene test's white
    pill.textStyle = "pill";
    Layer turned = makeText(7, QPointF(80, 55), "Turned", plain);
    turned.fields.insert("rot", 1);
    return {makeStroke(1, "pen", {{4, 6}, {14, 16}, {25, 8}, {36, 18}, {50, 10}, {62, 20}}, penLook("#de3651", 2.5)),
            makeStroke(2, "highlighter", {{6, 30}, {70, 33}, {88, 28}}, penLook("#fcea21", 3)),
            makeText(3, QPointF(30, 46), "Look here", plain),
            makeText(4, QPointF(62, 58), "Two\nlines", outlined),
            makeText(5, QPointF(22, 62), "Pill", pill),
            makeCounter(6, QPointF(86, 12), penLook("#7fb844", 3)),
            turned,
            makeCounter(8, QPointF(88, 40), penLook("#de3651", 3))};
}

// The scene on a software window, the way Editor.qml puts it (the holder is the picture's size on screen).
struct Rig {
    Rig(const QSize &picture, qreal zoom, const QSize &view)
        : natural(picture)
    {
        static const bool once = (QQuickWindow::setGraphicsApi(QSGRendererInterface::Software), true);
        (void)once;
        window.setColor(Qt::white);
        window.resize(view);
        QQmlComponent component(&engine, QUrl::fromLocalFile(QStringLiteral(GF_SCREENSHOT_QML_DIR "/ShapeScene.qml")));
        EXPECT_FALSE(component.isError()) << component.errorString().toStdString();
        QObject *object = component.createWithInitialProperties({{QStringLiteral("model"), QVariant::fromValue(&model)}, {QStringLiteral("viewScale"), zoom}});
        scene = qobject_cast<QQuickItem *>(object);
        EXPECT_NE(scene, nullptr);
        if (!scene)
            return;
        scene->setParentItem(window.contentItem());
        scene->setSize(QSizeF(picture.width() * zoom, picture.height() * zoom));
        this->zoom = zoom;
        window.show();
        for (int i = 0; i < 200 && !window.isExposed(); ++i)
            QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
    }

    // The scene is a QML-made object: deleted before its engine goes (else the engine's contexts are reported as leaks).
    ~Rig() { delete scene; }
    Rig(const Rig &) = delete;
    Rig &operator=(const Rig &) = delete;

    void setZoom(qreal z)
    {
        zoom = z;
        scene->setProperty("viewScale", z);
        scene->setSize(QSizeF(natural.width() * z, natural.height() * z));
    }
    QImage grab()
    {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
        return window.grabWindow().convertToFormat(QImage::Format_RGB32);
    }
    QQuickItem *content() const { return scene->findChild<QQuickItem *>(QStringLiteral("shapeContent")); }

    QSize natural;
    qreal zoom = 1;
    QQmlEngine engine;
    QQuickWindow window;
    LayerModel model;
    QQuickItem *scene = nullptr;
};

// The exporter's drawing of `layers` over white at `zoom` (what the scene is to match), as a picture the size of the scene.
QImage exporterAt(const Layers &layers, const QSize &natural, qreal zoom)
{
    QImage image(QSize(int(std::lround(natural.width() * zoom)), int(std::lround(natural.height() * zoom))), QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::white);
    {
        QPainter painter(&image);
        painter.scale(zoom, zoom);
        paintLayers(&painter, layers);
    }
    return image.convertToFormat(QImage::Format_RGB32);
}

// The share of pixels in `a` and `b` (the size of `a`, taken from the origin of `b`) that differ by more than `tolerance` levels.
double differing(const QImage &a, const QImage &b, int tolerance, int *worst = nullptr)
{
    long count = 0;
    int most = 0;
    for (int y = 0; y < a.height(); ++y) {
        const auto *pa = reinterpret_cast<const QRgb *>(a.constScanLine(y));
        const auto *pb = reinterpret_cast<const QRgb *>(b.constScanLine(y));
        for (int x = 0; x < a.width(); ++x) {
            const int d = std::max({std::abs(qRed(pa[x]) - qRed(pb[x])), std::abs(qGreen(pa[x]) - qGreen(pb[x])), std::abs(qBlue(pa[x]) - qBlue(pb[x]))});
            most = std::max(most, d);
            if (d > tolerance)
                ++count;
        }
    }
    if (worst)
        *worst = most;
    return double(count) / (double(a.width()) * a.height());
}

// Where a layer is drawn, in pixels of the scene at `zoom`: its geometry with the stroke and the heads, a little more, within the image.
QRect boxOf(const Layer &layer, qreal zoom, const QSize &image)
{
    const ShapeGeometry g = shapeGeometry(layer);
    QRectF bounds = layerBounds(layer);
    for (const QPolygonF *head : {&g.endHead, &g.startHead}) {
        for (const QPointF &p : *head)
            bounds = bounds.united(QRectF(p, QSizeF(0, 0)));
    }
    const qreal margin = g.width + g.headStroke + g.outlineWidth + 3;
    bounds.adjust(-margin, -margin, margin, margin);
    const QRectF px(bounds.x() * zoom, bounds.y() * zoom, bounds.width() * zoom, bounds.height() * zoom);
    return px.toAlignedRect().intersected(QRect(QPoint(0, 0), image));
}

// As `differing`, inside `box` only: a thin shape in a large picture would hide a wrong width in the empty pixels around it.
double differingIn(const QImage &a, const QImage &b, const QRect &box, int tolerance)
{
    long count = 0;
    for (int y = box.top(); y <= box.bottom(); ++y) {
        const auto *pa = reinterpret_cast<const QRgb *>(a.constScanLine(y));
        const auto *pb = reinterpret_cast<const QRgb *>(b.constScanLine(y));
        for (int x = box.left(); x <= box.right(); ++x) {
            const int d = std::max({std::abs(qRed(pa[x]) - qRed(pb[x])), std::abs(qGreen(pa[x]) - qGreen(pb[x])), std::abs(qBlue(pa[x]) - qBlue(pb[x]))});
            if (d > tolerance)
                ++count;
        }
    }
    return double(count) / (double(box.width()) * box.height());
}

// The same layer drawn wrongly, for the exporter's side of a comparison that must then fail.
Layer thinner(Layer layer)
{
    if (layer.fields.contains("size")) // a text or a counter: 30% smaller
        layer.fields.insert("size", layer.fields.value("size").toDouble() * 0.7);
    else
        layer.fields.insert("width", layer.fields.value("width").toDouble() * 0.7);
    return layer;
}
Layer withoutHeads(const Layer &layer) // an arrow as the plain line it would be with no head
{
    if (layer.type != QLatin1String("arrow"))
        return layer;
    Layer line = layer;
    line.type = QStringLiteral("line");
    return line;
}
Layer oneHeadLess(Layer layer) // a double arrow with one head
{
    layer.fields.insert("style", "straight");
    return layer;
}

} // namespace

// ---- the model ----------------------------------------------------------------------------------------------------------------

TEST(LayerModel, UpdatesTheLeastItCan)
{
    LayerModel model;
    int inserted = 0, removed = 0, changed = 0, resets = 0;
    QObject::connect(&model, &QAbstractItemModel::rowsInserted, [&] { ++inserted; });
    QObject::connect(&model, &QAbstractItemModel::rowsRemoved, [&] { ++removed; });
    QObject::connect(&model, &QAbstractItemModel::dataChanged, [&] { ++changed; });
    QObject::connect(&model, &QAbstractItemModel::modelReset, [&] { ++resets; });

    Layers layers = allKinds();
    EXPECT_EQ(model.setLayers(layers), 4) << "from nothing: a reset";
    EXPECT_EQ(model.rowCount(), 8);
    EXPECT_EQ(model.setLayers(layers), 0) << "no change, no signal";

    layers[3] = translated(layers[3], QPointF(5, 5));
    EXPECT_EQ(model.setLayers(layers), 1);
    EXPECT_EQ(changed, 1) << "one row told about";
    layers.append(makeShape(9, "line", QPointF(0, 0), QPointF(9, 9), style("#ff0000", 2)));
    EXPECT_EQ(model.setLayers(layers), 2);
    EXPECT_EQ(inserted, 1);
    layers.removeLast();
    EXPECT_EQ(model.setLayers(layers), 3);
    EXPECT_EQ(removed, 1);
    const Layer middle = layers[2];
    layers.removeAt(2);
    EXPECT_EQ(model.setLayers(layers), 3) << "a layer taken out of the middle: that row goes, the others stay";
    EXPECT_EQ(removed, 2);
    layers.insert(2, middle);
    EXPECT_EQ(model.setLayers(layers), 2) << "and undo puts it back at its index";
    EXPECT_EQ(inserted, 2);
    EXPECT_EQ(resets, 1) << "only the first load reset the model";
    layers.swapItemsAt(0, 1);
    EXPECT_EQ(model.setLayers(layers), 4) << "a different order is a reset";
}

TEST(LayerModel, TheRolesAreTheExportersGeometry)
{
    LayerModel model;
    model.setLayers(allKinds());
    const auto role = [&](int row, LayerModel::Role r) { return model.data(model.index(row), r); };
    EXPECT_EQ(role(0, LayerModel::KindRole).toString(), "rect");
    EXPECT_EQ(role(2, LayerModel::KindRole).toString(), "ellipse");
    EXPECT_EQ(role(4, LayerModel::KindRole).toString(), "line");
    EXPECT_EQ(role(5, LayerModel::KindRole).toString(), "arrow");
    EXPECT_EQ(role(7, LayerModel::KindRole).toString(), "arrowCurved");
    EXPECT_EQ(role(1, LayerModel::FillRole).toBool(), true);
    EXPECT_EQ(role(0, LayerModel::StrokeRole).toDouble(), 3);
    EXPECT_EQ(role(0, LayerModel::BoxWRole).toDouble(), 60);
    EXPECT_EQ(role(5, LayerModel::EndHeadRole).toList().size(), 4) << "a closed triangle: the first point again at the end";
    EXPECT_EQ(role(6, LayerModel::StartHeadRole).toList().size(), 4) << "a double arrow's second head";
    EXPECT_TRUE(role(5, LayerModel::StartHeadRole).toList().isEmpty());
    const ShapeGeometry g = shapeGeometry(allKinds()[5]);
    EXPECT_EQ(role(5, LayerModel::EndRole).toPointF(), g.shaftEnd);
    EXPECT_EQ(role(5, LayerModel::EndHeadRole).toList()[0].toPointF(), g.endHead[0]);
    Layer broken = allKinds()[0];
    broken.fields.insert("color", "nope");
    model.setLayers({broken});
    EXPECT_EQ(role(0, LayerModel::KindRole).toString(), "") << "a layer that does not read has no kind: no item draws it";
}

// ---- the scene against the exporter ------------------------------------------------------------------------------------------

class SceneAgreement : public ::testing::TestWithParam<double>
{
};

// What the scene may differ from the exporter by, inside a layer's own box: a pixel differs when a channel is off by more than
// kLevels; a layer fails above kShare (0.1%) of the box's pixels. The correct scene measures 0.000% at the three zooms (the software
// backend draws with the exporter's own QPainter); a stroke 30% too thin (1.6% to 17%), a missing head (2.1% to 18%) and a double
// arrow with one head (7% to 8.8%) are far above (checked below, every run).
constexpr int kLevels = 24;
constexpr double kShare = 0.001;

// Every kind at once, then each alone, at the zoom: the scene's pixels are the exporter's within a few levels along the edges. Each
// layer alone is compared inside its own box, and the same comparison must fail against a wrongly drawn exporter picture.
TEST_P(SceneAgreement, TheSceneIsTheExportersDrawingAtThatZoom)
{
    const double zoom = GetParam();
    const QSize natural(96, 72);
    const Layers all = allKinds();
    Rig rig(natural, zoom, QSize(int(natural.width() * zoom), int(natural.height() * zoom)));
    ASSERT_NE(rig.scene, nullptr);

    rig.model.setLayers(all);
    const QImage together = rig.grab();
    EXPECT_LT(differing(together, exporterAt(all, natural, zoom), kLevels), 0.01) << "all kinds together at zoom " << zoom;

    for (const Layer &layer : all) {
        rig.model.setLayers({layer});
        const QImage scene = rig.grab();
        const QRect box = boxOf(layer, zoom, scene.size());
        ASSERT_FALSE(box.isEmpty());
        const double right = differingIn(scene, exporterAt({layer}, natural, zoom), box, kLevels);
        std::printf("share layer %d (%s) zoom %.1f: right %.3f%%", layer.id, layer.type.toLatin1().constData(), zoom, right * 100);
        EXPECT_LT(right, kShare) << layer.type.toStdString() << " " << layer.id << " at zoom " << zoom;

        QImage blank(scene.size(), QImage::Format_RGB32);
        blank.fill(Qt::white);
        EXPECT_GT(differingIn(scene, blank, box, kLevels), 0.0) << "layer " << layer.id << " drew nothing";

        // The bound is tight: the comparison fails for the wrong drawings it is there to catch.
        const double narrow = differingIn(scene, exporterAt({thinner(layer)}, natural, zoom), box, kLevels);
        std::printf(", thinner %.3f%%", narrow * 100);
        EXPECT_GT(narrow, kShare) << "a stroke 30% thinner passes for layer " << layer.id << " at zoom " << zoom;
        if (layer.type == QLatin1String("arrow")) {
            const bool both = layer.fields.value("style").toString() == QLatin1String("double");
            const Layer wrong = both ? oneHeadLess(layer) : withoutHeads(layer);
            const double missing = differingIn(scene, exporterAt({wrong}, natural, zoom), box, kLevels);
            std::printf(", head missing %.3f%%", missing * 100);
            EXPECT_GT(missing, kShare) << "a missing head passes for layer " << layer.id << " at zoom " << zoom;
        }
        std::printf("\n");
    }
}

INSTANTIATE_TEST_SUITE_P(Zooms, SceneAgreement, ::testing::Values(1.0, 2.5, 16.0));

// The same bound for the kinds of slices B5 and B6, each on its own and then all together (the counters' numbers come from their place
// in the list, so the two counters are also drawn with each other). Text depends on the font at hand, but the scene and the
// exporter lay out the same glyph outlines, so the bound does not.
class SceneAgreementNewKinds : public ::testing::TestWithParam<double>
{
};

TEST_P(SceneAgreementNewKinds, TheScenePenHighlighterTextAndCountersAreTheExportersDrawing)
{
    const double zoom = GetParam();
    const QSize natural(96, 72);
    const Layers all = newKinds();
    Rig rig(natural, zoom, QSize(int(natural.width() * zoom), int(natural.height() * zoom)));
    ASSERT_NE(rig.scene, nullptr);

    rig.model.setLayers(all);
    const QImage together = rig.grab();
    EXPECT_LT(differing(together, exporterAt(all, natural, zoom), kLevels), 0.01) << "all the new kinds together at zoom " << zoom;

    const QList<int> numbers = counterNumbers(all);
    for (int i = 0; i < all.size(); ++i) {
        const Layer &layer = all[i];
        // Alone, but with the counters before it that number it: a counter is drawn as the place it takes among the counters.
        Layers shown;
        for (int k = 0; k <= i; ++k) {
            if (k == i || (layer.type == QLatin1String("counter") && all[k].type == QLatin1String("counter")))
                shown.append(all[k]);
        }
        rig.model.setLayers(shown);
        const QImage scene = rig.grab();
        const QRect box = boxOf(layer, zoom, scene.size());
        ASSERT_FALSE(box.isEmpty());
        const double right = differingIn(scene, exporterAt(shown, natural, zoom), box, kLevels);
        std::printf("share layer %d (%s, number %d) zoom %.1f: right %.3f%%", layer.id, layer.type.toLatin1().constData(), numbers[i], zoom, right * 100);
        EXPECT_LT(right, kShare) << layer.type.toStdString() << " " << layer.id << " at zoom " << zoom;

        QImage blank(scene.size(), QImage::Format_RGB32);
        blank.fill(Qt::white);
        EXPECT_GT(differingIn(scene, blank, box, kLevels), 0.0) << "layer " << layer.id << " drew nothing";

        // The bound is tight: a stroke 30% thinner and a text or counter 30% smaller are caught.
        Layers wrong = shown;
        wrong.last() = thinner(layer);
        const double narrow = differingIn(scene, exporterAt(wrong, natural, zoom), box, kLevels);
        std::printf(", wrong size or width %.3f%%", narrow * 100);
        EXPECT_GT(narrow, kShare) << "a 30% smaller drawing passes for layer " << layer.id << " at zoom " << zoom;
        if (layer.type == QLatin1String("text") && layer.fields.value("style").toString() != QLatin1String("plain")) {
            Layers plainOne = shown;
            plainOne.last().fields.insert("style", "plain");
            const double flat = differingIn(scene, exporterAt(plainOne, natural, zoom), box, kLevels);
            std::printf(", style left out %.3f%%", flat * 100);
            EXPECT_GT(flat, kShare) << "the outline or the pill is missing from the exporter's side and the bound does not see it";
        }
        if (layer.type == QLatin1String("counter") && shown.size() > 1) {
            Layers renumbered = shown;
            renumbered.removeFirst(); // the same counter, drawn as the first
            const double number = differingIn(scene, exporterAt(renumbered, natural, zoom), box, kLevels);
            std::printf(", number off by one %.3f%%", number * 100);
            EXPECT_GT(number, kShare) << "a counter with the wrong number passes";
        }
        std::printf("\n");
    }
}

INSTANTIATE_TEST_SUITE_P(Zooms, SceneAgreementNewKinds, ::testing::Values(1.0, 2.5, 16.0));

TEST(LayerModel, TheNewKindsAreStrokesAndGlyphsWithTheExportersOutlines)
{
    LayerModel model;
    const Layers all = newKinds();
    model.setLayers(all);
    const auto role = [&](int row, LayerModel::Role r) { return model.data(model.index(row), r); };
    EXPECT_EQ(role(0, LayerModel::KindRole).toString(), "stroke");
    EXPECT_EQ(role(1, LayerModel::KindRole).toString(), "stroke");
    EXPECT_EQ(role(0, LayerModel::FlatCapRole).toBool(), false);
    EXPECT_EQ(role(1, LayerModel::FlatCapRole).toBool(), true) << "a marker's ends are flat";
    for (int row : {2, 3, 4, 5, 6, 7})
        EXPECT_EQ(role(row, LayerModel::KindRole).toString(), "glyphs") << row;
    EXPECT_EQ(role(0, LayerModel::PathRole).toString(), pathToSvg(shapeGeometry(all[0]).path));
    EXPECT_EQ(role(5, LayerModel::PathRole).toString(), pathToSvg(shapeGeometry(all[5], 1).path)) << "the first counter reads 1";
    EXPECT_EQ(role(7, LayerModel::PathRole).toString(), pathToSvg(shapeGeometry(all[7], 2).path)) << "the second reads 2";
    EXPECT_EQ(role(2, LayerModel::PlateRole).toString(), "") << "plain text has no plate";
    EXPECT_NE(role(4, LayerModel::PlateRole).toString(), "") << "a pill has";
    EXPECT_NE(role(5, LayerModel::PlateRole).toString(), "") << "and a counter's disc is its plate";
    EXPECT_GT(role(3, LayerModel::OutlineWidthRole).toDouble(), 0);
    EXPECT_EQ(role(2, LayerModel::OutlineWidthRole).toDouble(), 0);
}

TEST(Scene, ItIsClippedToThePictureAsTheExportIs)
{
    const QSize natural(40, 30);
    Rig rig(natural, 1, QSize(120, 90)); // the window is larger than the picture
    ASSERT_NE(rig.scene, nullptr);
    EXPECT_TRUE(rig.scene->clip());
    rig.model.setLayers({makeShape(1, "rectangle", QPointF(-30, 5), QPointF(70, 20), style("#ff0000", 3, true))});
    const QImage scene = rig.grab();
    EXPECT_EQ(scene.pixelColor(20, 12), QColor(255, 0, 0)) << "inside the picture";
    EXPECT_EQ(scene.pixelColor(60, 12), QColor(Qt::white)) << "past the picture's right edge: nothing, as in the file";
    EXPECT_EQ(scene.pixelColor(20, 60), QColor(Qt::white));
}

// A rectangle's outline is one closed path: its first corner is joined like the others (mitred), not capped round.
TEST(Scene, TheFirstCornerOfARectangleIsJoinedNotRounded)
{
    const QSize natural(60, 40);
    const double zoom = 8;
    Rig rig(natural, zoom, QSize(int(natural.width() * zoom), int(natural.height() * zoom)));
    ASSERT_NE(rig.scene, nullptr);
    rig.model.setLayers({makeShape(1, "rectangle", QPointF(10, 10), QPointF(50, 30), style("#ff0000", 6))});
    const QImage scene = rig.grab();
    // The outer corner of the stroke is (7, 7) in the picture: one pixel in from it, on the screen, is red for a mitre and white for a cap.
    const int c = int(7 * zoom) + 1;
    EXPECT_EQ(scene.pixelColor(c, c), QColor(255, 0, 0)) << "top left (where the path starts)";
    EXPECT_EQ(scene.pixelColor(int(53 * zoom) - 2, c), QColor(255, 0, 0)) << "top right";
    EXPECT_EQ(scene.pixelColor(c, int(33 * zoom) - 2), QColor(255, 0, 0)) << "bottom left";
}

// A layer taken out or put back in the middle goes in or out of the scene alone: the other items are the same objects.
TEST(Scene, TheOtherItemsSurviveARowRemovedOrInsertedInTheMiddle)
{
    Rig rig(QSize(96, 72), 1, QSize(96, 72));
    ASSERT_NE(rig.scene, nullptr);
    Layers layers = allKinds();
    rig.model.setLayers(layers);
    const auto items = [&] {
        QList<QQuickItem *> out;
        for (QQuickItem *child : rig.content()->childItems()) {
            if (child->objectName() != QLatin1String("shapeRepeater"))
                out.append(child);
        }
        return out;
    };
    const QList<QQuickItem *> before = items();
    ASSERT_EQ(before.size(), 8);
    const Layer middle = layers[3];
    layers.removeAt(3);
    rig.model.setLayers(layers);
    QList<QQuickItem *> expected = before;
    expected.removeAt(3);
    EXPECT_EQ(items(), expected) << "the seven others are the same items";
    layers.insert(3, middle);
    rig.model.setLayers(layers);
    const QList<QQuickItem *> after = items();
    ASSERT_EQ(after.size(), 8);
    for (const QQuickItem *item : expected)
        EXPECT_TRUE(after.contains(const_cast<QQuickItem *>(item))) << "kept through the insert";
}

TEST(Scene, TheItemsFollowTheZoomWithNothingDrawnAgain)
{
    Rig rig(QSize(96, 72), 1, QSize(300, 220));
    ASSERT_NE(rig.scene, nullptr);
    rig.model.setLayers(allKinds());
    QQuickItem *content = rig.content();
    ASSERT_NE(content, nullptr);
    // The repeater is a child too; the others are the layers' items, one each.
    const auto shapes = [&] {
        QList<QQuickItem *> items;
        for (QQuickItem *child : content->childItems()) {
            if (child->objectName() != QLatin1String("shapeRepeater"))
                items.append(child);
        }
        return items;
    };
    ASSERT_EQ(shapes().size(), 8) << "one item per layer";
    EXPECT_EQ(content->scale(), 1);
    // The shape is placed in picture pixels: its place on screen is the zoom times it, with the scene's own offset.
    QQuickItem *first = shapes().first();
    for (const double zoom : {1.0, 1.25, 2.5, 4.0, 16.0}) {
        rig.setZoom(zoom);
        EXPECT_EQ(content->scale(), zoom);
        const QPointF screen = first->mapToItem(rig.scene, QPointF(10, 8)); // the first rectangle's corner
        EXPECT_NEAR(screen.x(), 10 * zoom, 1e-6) << "at zoom " << zoom;
        EXPECT_NEAR(screen.y(), 8 * zoom, 1e-6);
        EXPECT_EQ(shapes().size(), 8) << "the zoom touches no row";
    }
    rig.scene->setX(-37); // what scrolling does: the scene moves with the content, nothing else changes
    EXPECT_NEAR(first->mapToItem(rig.window.contentItem(), QPointF(10, 8)).x(), -37 + 10 * 16, 1e-6);
}

// The cost of one pointer move on a 4K capture with 24 shapes, at 100% and 400%, in a 1500 x 1000 view: the model update, the
// bindings and the scene graph's sync (processEvents), then the software rasteriser's whole-view render (an upper bound: on the
// GPU nothing but the changed shape's geometry is uploaded). Printed, not asserted: a loaded machine must not fail a build.
TEST(Scene, TheCostOfAMoveOnAFourKCapture)
{
    Layers layers;
    for (int i = 0; i < 12; ++i) {
        layers.append(makeShape(2 * i + 1, "rectangle", QPointF(100 + i * 250, 100 + i * 120), QPointF(600 + i * 250, 500 + i * 120), style("#de3651", 8)));
        layers.append(makeShape(2 * i + 2, "arrow", QPointF(50 + i * 300, 2000), QPointF(900 + i * 280, 300), style("#0167fd", 8)));
    }
    Rig rig(QSize(3840, 2160), 1, QSize(1500, 1000));
    ASSERT_NE(rig.scene, nullptr);
    rig.model.setLayers(layers);
    rig.grab();
    for (const double zoom : {1.0, 4.0}) {
        rig.setZoom(zoom);
        rig.scene->setX(-1000 * zoom / 2);
        rig.scene->setY(-500 * zoom / 2);
        rig.grab();
        qint64 model = -1, render = -1;
        for (int run = 0; run < 7; ++run) {
            layers[3] = translated(layers[3], QPointF(3, 2)); // one shape moves
            QElapsedTimer timer;
            timer.start();
            rig.model.setLayers(layers); // the model's update and the bindings it triggers, on the GUI thread
            const qint64 a = timer.nsecsElapsed() / 1000;
            QCoreApplication::processEvents(QEventLoop::AllEvents, 10); // polish, sync and the software render of the whole view
            rig.window.grabWindow();
            const qint64 b = timer.nsecsElapsed() / 1000;
            model = model < 0 ? a : std::min(model, a);
            render = render < 0 ? b : std::min(render, b);
        }
        std::printf("scene per move, 4K capture, 24 shapes, zoom %.0f%%: model and bindings %lld us; with the software rasteriser drawing the whole 1500x1000 view %lld us\n",
                    zoom * 100, (long long)model, (long long)render);
    }
}
