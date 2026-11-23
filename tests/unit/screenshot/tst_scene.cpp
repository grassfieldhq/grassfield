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
    layers.removeAt(2);
    EXPECT_EQ(model.setLayers(layers), 4) << "a layer taken out of the middle: a reset";
    EXPECT_EQ(resets, 2);
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

// Every kind at once, then each alone, at the zoom: the scene's pixels are the exporter's within a few levels along the edges.
TEST_P(SceneAgreement, TheSceneIsTheExportersDrawingAtThatZoom)
{
    const double zoom = GetParam();
    const QSize natural(96, 72);
    const Layers all = allKinds();
    Rig rig(natural, zoom, QSize(int(natural.width() * zoom), int(natural.height() * zoom)));
    ASSERT_NE(rig.scene, nullptr);

    QList<Layers> cases{all};
    for (const Layer &layer : all)
        cases.append(Layers{layer});
    for (int i = 0; i < cases.size(); ++i) {
        rig.model.setLayers(cases[i]);
        const QImage scene = rig.grab();
        const QImage expected = exporterAt(cases[i], natural, zoom);
        ASSERT_EQ(scene.size(), expected.size());
        int worst = 0;
        const double share = differing(scene, expected, 40, &worst);
        EXPECT_LT(share, 0.01) << "case " << i << " at zoom " << zoom << ": " << share * 100 << "% of the pixels differ by more than 40 levels (the most "
                               << worst << ")";
        if (i > 0) { // each layer alone must draw something
            QImage blank(scene.size(), QImage::Format_RGB32);
            blank.fill(Qt::white);
            EXPECT_GT(differing(scene, blank, 40), 0.0) << "case " << i << " drew nothing";
        }
    }
}

INSTANTIATE_TEST_SUITE_P(Zooms, SceneAgreement, ::testing::Values(1.0, 2.5, 16.0));

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
