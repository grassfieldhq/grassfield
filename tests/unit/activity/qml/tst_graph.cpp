// Activity Monitor's graphs (apps/activity/src/graphgeometry.h, graphitem.h; audit apps-misc "graphs rebuilt per sample"):
// - the vertex data: gaps stop a band, a lone sample is one slot wide, mirrored series go up and down from the middle, a
//   value of 0 draws nothing; a new sample writes only its own blocks and the edges' (no rebuild), and the ring it keeps is,
//   at every step, the graph a full rebuild makes;
// - the pixels: Graph.qml (GraphItem) against the QtQuick.Shapes graph it replaces (ReferenceGraph.qml, the former
//   Graph.qml), for each style, also after samples were added one by one. In this binary's offscreen run the scene graph is
//   the software one (QPainter on both sides); the comparison on a GPU scene graph (the geometry nodes and their coverage
//   strips against the Shapes' curve renderer) runs this binary again under Xvfb with Mesa when xvfb-run is installed.
#include "graphgeometry.h"
#include "graphitem.h"

#include <QElapsedTimer>
#include <QGuiApplication>
#include <QImage>
#include <QProcess>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRandomGenerator>
#include <QSGRendererInterface>
#include <QStandardPaths>

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>

#ifndef ACTIVITY_ROOT
#error "ACTIVITY_ROOT: the repository's root (build-direct.sh and CMakeLists.txt define it)"
#endif

using namespace activity::graph;

namespace {

QVariantMap block(const QString &style, double max, const QList<QVariantList> &series, const QVariantList &levels = {},
                  const QVariantList &xs = {})
{
    QVariantList list;
    for (int i = 0; i < series.size(); ++i) {
        QVariantMap s{{QStringLiteral("values"), series.at(i)},
                      {QStringLiteral("color"), i == 0 ? QStringLiteral("activityGraphSystem") : QStringLiteral("activityGraphUser")}};
        if (i == 0 && !xs.isEmpty())
            s.insert(QStringLiteral("xs"), xs);
        list.append(s);
    }
    QVariantMap b{{QStringLiteral("style"), style}, {QStringLiteral("max"), max}, {QStringLiteral("series"), list}};
    if (!levels.isEmpty()) {
        b.insert(QStringLiteral("levels"), levels);
        b.insert(QStringLiteral("levelColors"), QStringList{QStringLiteral("activityPressureGreen"), QStringLiteral("activityPressureYellow"),
                                                              QStringLiteral("activityPressureRed")});
    }
    return b;
}

QVariantList vl(std::initializer_list<double> v)
{
    QVariantList out;
    for (double d : v)
        out.append(d);
    return out;
}

int filledBlocks(const GraphRing &ring, int layer)
{
    const std::vector<Vertex> &v = ring.vertices(layer);
    int n = 0;
    for (size_t b = 0; b * kBlockVertices < v.size(); ++b) {
        bool any = false;
        for (int i = 0; i < kBlockVertices; ++i)
            any = any || v[b * kBlockVertices + i].coverage > 0;
        n += any ? 1 : 0;
    }
    return n;
}

// A layer's triangles in item coordinates, block by block in sample order (empty blocks left out).
std::vector<std::vector<Vertex>> drawn(const GraphRing &ring, int layer, int samples)
{
    std::vector<std::vector<Vertex>> out;
    const std::vector<Vertex> &v = ring.vertices(layer);
    for (int i = 0; i < samples; ++i) {
        const size_t b = static_cast<size_t>(ring.blockOf(i)) * kBlockVertices;
        std::vector<Vertex> one(v.begin() + static_cast<long>(b), v.begin() + static_cast<long>(b) + kBlockVertices);
        if (std::none_of(one.begin(), one.end(), [](const Vertex &x) { return x.coverage > 0; }))
            continue;
        for (Vertex &x : one)
            x.x += ring.offset();
        out.push_back(one);
    }
    return out;
}

void expectSameDrawing(const GraphRing &a, const GraphRing &b, int samples, const std::string &where)
{
    for (int layer = 0; layer < kLayers; ++layer) {
        const auto da = drawn(a, layer, samples), db = drawn(b, layer, samples);
        ASSERT_EQ(da.size(), db.size()) << where << " layer " << layer;
        for (size_t i = 0; i < da.size(); ++i) {
            for (int k = 0; k < kBlockVertices; ++k) {
                EXPECT_NEAR(da[i][k].x, db[i][k].x, 1e-3) << where << " layer " << layer << " block " << i;
                EXPECT_NEAR(da[i][k].y, db[i][k].y, 1e-3) << where;
                EXPECT_NEAR(da[i][k].coverage, db[i][k].coverage, 1e-6) << where;
            }
        }
    }
}

} // namespace

// AM5, AM8: a value below 0 is a gap: the fill stops there and starts again after it, never drawn as zero (the former
// tst_activitymain.qml test_graphGaps, on the shapes and on the triangles).
TEST(GraphGeometry, AGapStopsTheBandAndALoneSampleIsOneSlotWide)
{
    GraphRing ring;
    ring.update(Spec::fromBlock(block(QStringLiteral("area"), 1, {vl({0.5, -1, 0.2, 0.4, -1})}), 5), 100, 50, 1);
    const QList<QPolygonF> runs = ring.polygons(kLower);
    ASSERT_EQ(runs.size(), 2); // [0.5] and [0.2, 0.4]
    for (const QPointF &p : runs.at(1))
        EXPECT_TRUE(p.y() >= 0 && p.y() <= 50);
    // The lone 0.5 is one slot (100 / 4) wide, at the first sample's place.
    EXPECT_NEAR(runs.at(0).boundingRect().width(), 25, 1e-4);
    EXPECT_NEAR(runs.at(0).boundingRect().right(), 0, 1e-4);
    // Triangles: the lone sample's quad and the band from 0.2 to 0.4; nothing at the gaps.
    EXPECT_EQ(filledBlocks(ring, kLower), 2);
    EXPECT_FALSE(ring.layerUsed(kUpper));

    ring.update(Spec::fromBlock(block(QStringLiteral("mirrored"), 10, {vl({5, 10}), vl({-1, 5})}), 5), 100, 50, 1);
    ASSERT_EQ(ring.polygons(kLower).size(), 1);
    ASSERT_EQ(ring.polygons(kUpper).size(), 1);
    for (const QPointF &p : ring.polygons(kLower).at(0))
        EXPECT_LE(p.y(), 25.001) << "reads above the middle";
    for (const QPointF &p : ring.polygons(kUpper).at(0))
        EXPECT_GE(p.y(), 24.999) << "writes below it";
    for (const Vertex &v : ring.vertices(kUpper)) {
        if (v.coverage > 0)
            EXPECT_GE(v.y, 25.0f) << "the strip of the writes is below them too";
    }
}

// The edge is antialiased across half a device pixel outside the band, from half the coverage to none; the base is not. A
// band of height 0 draws nothing at all (no line along the bottom).
TEST(GraphGeometry, TheEdgeHasACoverageStripAndZeroDrawsNothing)
{
    GraphRing ring;
    ring.update(Spec::fromBlock(block(QStringLiteral("area"), 1, {vl({0.5, 0.5})}), 2), 100, 40, 2);
    const auto blocks = drawn(ring, kLower, 2);
    ASSERT_EQ(blocks.size(), 1u);
    const std::vector<Vertex> &b = blocks.at(0);
    EXPECT_FLOAT_EQ(b[0].y, 20); // the edge
    EXPECT_FLOAT_EQ(b[2].y, 40); // the base
    EXPECT_FLOAT_EQ(b[4].coverage, 0.5f);
    EXPECT_FLOAT_EQ(b[6].coverage, 0.0f);
    EXPECT_NEAR(b[6].y, 20 - 0.25, 1e-5) << "half a device pixel above the edge at a ratio of 2";

    ring.update(Spec::fromBlock(block(QStringLiteral("area"), 1, {vl({0, 0, 0})}), 3), 100, 40, 1);
    EXPECT_EQ(filledBlocks(ring, kLower), 0);
}

// A new sample (the history moved by one) writes the new sample's block, the one before it and the first two (the left
// edge), and clears the one that left: never a rebuild. At every step the ring draws what a full rebuild draws, for every
// style, with gaps, lone samples, levels and a history still filling up.
TEST(GraphGeometry, ANewSampleWritesOnlyItsBlocksAndDrawsWhatARebuildDraws)
{
    QRandomGenerator rng(20261119);
    const QStringList styles{QStringLiteral("area"), QStringLiteral("stacked"), QStringLiteral("mirrored"), QStringLiteral("bars")};
    for (const QString &style : styles) {
        const int capacity = 40;
        QVariantList a, b, levels;
        GraphRing ring;
        int rebuilds = 0;
        for (int step = 0; step < 400; ++step) {
            const auto value = [&] { return rng.bounded(10) == 0 ? -1.0 : rng.bounded(1000) / 1000.0 * 0.5; };
            a.append(value());
            b.append(value());
            levels.append(rng.bounded(3));
            if (a.size() > capacity) {
                a.removeFirst();
                b.removeFirst();
                levels.removeFirst();
            }
            const Spec spec = Spec::fromBlock(block(style, 1, {a, b}, style == QLatin1String("bars") ? levels : QVariantList{}), capacity);
            ASSERT_TRUE(ring.update(spec, 300, 80, 1));
            if (ring.rebuilt()) {
                ++rebuilds;
            } else {
                for (int layer = 0; layer < kLayers; ++layer)
                    EXPECT_LE(ring.written(layer).size(), 5u) << style.toStdString() << " step " << step;
            }
            GraphRing fresh;
            fresh.update(spec, 300, 80, 1);
            expectSameDrawing(ring, fresh, static_cast<int>(a.size()), style.toStdString() + " step " + std::to_string(step));
        }
        // The first sample, then a rebase of the coordinates every few rings (they would lose float precision).
        EXPECT_LE(rebuilds, 1 + 400 / (3 * (capacity + 1)) + 1) << style.toStdString();
    }
}

// A new scale (a peak entered or left the window), a new size or a changed value already drawn rebuilds; the same block
// again changes nothing.
TEST(GraphGeometry, ScaleSizeOrAnEditedValueRebuildsAndTheSameBlockChangesNothing)
{
    GraphRing ring;
    const QVariantList v = vl({0.1, 0.2, 0.3});
    ring.update(Spec::fromBlock(block(QStringLiteral("area"), 1, {v}), 10), 100, 40, 1);
    EXPECT_FALSE(ring.update(Spec::fromBlock(block(QStringLiteral("area"), 1, {v}), 10), 100, 40, 1));
    ASSERT_TRUE(ring.update(Spec::fromBlock(block(QStringLiteral("area"), 1, {vl({0.1, 0.2, 0.3, 0.4})}), 10), 100, 40, 1));
    EXPECT_FALSE(ring.rebuilt()) << "a sample added to a history still filling up";
    ring.update(Spec::fromBlock(block(QStringLiteral("area"), 2, {vl({0.1, 0.2, 0.3, 0.4})}), 10), 100, 40, 1);
    EXPECT_TRUE(ring.rebuilt()) << "a new scale";
    ring.update(Spec::fromBlock(block(QStringLiteral("area"), 2, {vl({0.1, 0.25, 0.3, 0.4})}), 10), 100, 40, 1);
    EXPECT_TRUE(ring.rebuilt()) << "a value already drawn changed";
    ring.update(Spec::fromBlock(block(QStringLiteral("area"), 2, {vl({0.1, 0.25, 0.3, 0.4})}), 10), 120, 40, 1);
    EXPECT_TRUE(ring.rebuilt()) << "a new width";
}

// ---- Pixels -----------------------------------------------------------------------------------------------------------
namespace {

constexpr int kW = 300;
constexpr int kH = 80;

// Graph.qml (GraphItem) on the left, the Shapes graph it replaces on the right, each on white, with the same block.
struct Scene {
    std::unique_ptr<QQmlEngine> engine;
    std::unique_ptr<QQuickWindow> window;
    QQuickItem *next = nullptr;
    QQuickItem *reference = nullptr;
};

Scene makeScene(const QVariantMap &graph, int capacity)
{
    Scene s;
    s.engine = std::make_unique<QQmlEngine>();
    s.engine->addImportPath(QStringLiteral(ACTIVITY_ROOT "/ui"));
    QQmlComponent c(s.engine.get());
    const QByteArray qml = "import QtQuick\n"
                           "import \"file://" ACTIVITY_ROOT "/apps/activity/qml\" as App\n"
                           "import \"file://" ACTIVITY_ROOT "/tests/unit/activity/qml\" as Ref\n"
                           "Window {\n"
                           "  width: 640; height: 100; visible: true; color: \"white\"\n"
                           "  property alias next: next\n"
                           "  property alias reference: reference\n"
                           "  App.Graph { id: next; x: 10; y: 10; width: 300; height: 80 }\n"
                           "  Ref.ReferenceGraph { id: reference; x: 330; y: 10; width: 300; height: 80 }\n"
                           "}\n";
    c.setData(qml, QUrl::fromLocalFile(QStringLiteral(ACTIVITY_ROOT "/tests/unit/activity/qml/scene.qml")));
    QObject *o = c.create();
    EXPECT_NE(o, nullptr) << c.errorString().toStdString();
    s.window.reset(qobject_cast<QQuickWindow *>(o));
    if (!s.window)
        return s;
    s.next = s.window->property("next").value<QQuickItem *>();
    s.reference = s.window->property("reference").value<QQuickItem *>();
    for (QQuickItem *g : {s.next, s.reference}) {
        g->setProperty("capacity", capacity);
        g->setProperty("graph", graph);
    }
    return s;
}

QImage grab(Scene &s)
{
    QElapsedTimer t;
    t.start();
    while (!s.window->isExposed() && t.elapsed() < 3000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
    QCoreApplication::processEvents();
    return s.window->grabWindow().convertToFormat(QImage::Format_ARGB32);
}

struct Difference {
    double mean = 0;
    double bigShare = 0;
    int coloured = 0;
};

// The two graphs' pixels compared: the mean difference per channel (0 to 255), the share of pixels that differ by more
// than a third of the range (an edge a pixel apart is one; a missing or misplaced band is many), and how many pixels of the
// new graph are not white (it drew something).
Difference compare(const QImage &img)
{
    Difference d;
    const qreal dpr = img.devicePixelRatio();
    const int w = qRound(kW * dpr), h = qRound(kH * dpr), ax = qRound(10 * dpr), bx = qRound(330 * dpr), y0 = qRound(10 * dpr);
    double sum = 0;
    int big = 0;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const QRgb a = img.pixel(ax + x, y0 + y), b = img.pixel(bx + x, y0 + y);
            const int diff = std::max({std::abs(qRed(a) - qRed(b)), std::abs(qGreen(a) - qGreen(b)), std::abs(qBlue(a) - qBlue(b))});
            sum += diff;
            big += diff > 85 ? 1 : 0;
            d.coloured += (qRed(a) < 250 || qGreen(a) < 250 || qBlue(a) < 250) ? 1 : 0;
        }
    }
    d.mean = sum / (w * h);
    d.bigShare = static_cast<double>(big) / (w * h);
    return d;
}

bool gpuChild()
{
    return qEnvironmentVariableIntValue("GRASSFIELD_TEST_XCB") == 1;
}

void checkScene(const QVariantMap &graph, int capacity, const char *what)
{
    Scene s = makeScene(graph, capacity);
    ASSERT_TRUE(s.window && s.next && s.reference) << what;
    // The bars as the former Graph.qml meant them: without the white seam its odd-even fill left where two bars overlap.
    s.reference->setProperty("barsFillRule", 1 /* ShapePath.WindingFill */);
    const QImage img = grab(s);
    ASSERT_FALSE(img.isNull()) << what;
    const QSGRendererInterface::GraphicsApi api = s.window->rendererInterface()->graphicsApi();
    if (gpuChild())
        ASSERT_NE(api, QSGRendererInterface::Software) << "the GPU run must have a GPU scene graph";
    ASSERT_NE(s.next->property("surface").value<QQuickItem *>(), nullptr) << "Graph.qml made its GraphItem";
    const Difference d = compare(img);
    std::printf("graph %s: scene graph api %d, mean difference %.2f, pixels off by more than a third %.3f%%\n", what, int(api), d.mean,
                d.bigShare * 100);
    EXPECT_GT(d.coloured, 200) << what << ": the new graph drew its bands";
    EXPECT_LT(d.mean, 3.0) << what << " (api " << int(api) << ")";
    EXPECT_LT(d.bigShare, 0.006) << what << " (api " << int(api) << ")";
    if (qEnvironmentVariableIsSet("GRASSFIELD_GRAPH_DUMP"))
        img.save(qEnvironmentVariable("GRASSFIELD_GRAPH_DUMP") + QLatin1Char('/') + QString::fromLatin1(what) + QStringLiteral(".png"));
}

QVariantList wave(int n, double phase, double scale, int gapEvery = 0)
{
    QVariantList out;
    for (int i = 0; i < n; ++i) {
        const bool gap = gapEvery > 0 && (i % gapEvery == gapEvery - 1 || i % (gapEvery * 3) == 2);
        out.append(gap ? -1.0 : scale * (0.5 + 0.45 * std::sin(i * 0.37 + phase) * std::cos(i * 0.11)));
    }
    return out;
}

} // namespace

TEST(GraphPixels, EachStyleMatchesTheShapesItReplaces)
{
    const int cap = 60;
    checkScene(block(QStringLiteral("stacked"), 1, {wave(cap, 0, 0.5), wave(cap, 1.3, 0.4)}), cap, "stacked");
    checkScene(block(QStringLiteral("area"), 2, {wave(cap, 0.4, 2, 7)}), cap, "area-gaps");
    checkScene(block(QStringLiteral("mirrored"), 10, {wave(cap, 0.2, 10, 9), wave(cap, 2.1, 8)}), cap, "mirrored");
    QVariantList levels;
    for (int i = 0; i < cap; ++i)
        levels.append((i / 9) % 3);
    checkScene(block(QStringLiteral("bars"), 1, {wave(cap, 0.9, 1)}, levels), cap, "bars");
    // The battery's: each value at its time (xs), a history shorter than the capacity.
    QVariantList xs, values;
    for (int i = 0; i < 25; ++i) {
        xs.append(0.3 + i * 0.028);
        values.append(40 + 30 * std::sin(i * 0.3));
    }
    checkScene(block(QStringLiteral("area"), 100, {values}, {}, xs), cap, "battery");
}

// After samples came one by one (the ring's incremental path, its blocks written in place and the whole slid along), the
// pixels are the same graph's.
TEST(GraphPixels, SamplesAddedOneByOneDrawTheSameGraph)
{
    const int cap = 60;
    const QVariantList all0 = wave(cap + 40, 0.7, 0.5, 11), all1 = wave(cap + 40, 2.0, 0.3);
    Scene s = makeScene(QVariantMap(), cap);
    ASSERT_TRUE(s.window && s.next);
    QQuickItem *item = s.next->property("surface").value<QQuickItem *>();
    ASSERT_NE(item, nullptr);
    grab(s);
    const int before = item->property("rebuilds").toInt();
    QVariantMap last;
    for (int n = 1; n <= all0.size(); ++n) {
        const int from = std::max(0, n - cap);
        last = block(QStringLiteral("stacked"), 1, {all0.mid(from, n - from), all1.mid(from, n - from)});
        s.next->setProperty("graph", last);
        if (n % 17 == 0)
            grab(s); // drawn now and then while the samples come
    }
    EXPECT_LE(item->property("rebuilds").toInt() - before, 2) << "samples are added, not rebuilt";
    EXPECT_LE(item->property("lastWritten").toInt(), 10) << "the last sample wrote a few blocks";
    s.reference->setProperty("graph", last);
    const QImage img = grab(s);
    const Difference d = compare(img);
    EXPECT_GT(d.coloured, 200);
    EXPECT_LT(d.mean, 3.0);
    EXPECT_LT(d.bigShare, 0.006);
}

// The same comparisons on a GPU scene graph (OpenGL on Mesa under Xvfb): this binary again, on xcb.
TEST(GraphPixels, OnAGpuSceneGraphUnderXvfb)
{
    if (gpuChild())
        GTEST_SKIP() << "this is the GPU run";
    const QString xvfb = QStandardPaths::findExecutable(QStringLiteral("xvfb-run"));
    if (xvfb.isEmpty())
        GTEST_SKIP() << "xvfb-run is not installed: the GPU comparison needs Xvfb and Mesa";
    QProcess p;
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("GRASSFIELD_TEST_XCB"), QStringLiteral("1"));
    env.insert(QStringLiteral("QSG_RHI_BACKEND"), QStringLiteral("opengl"));
    env.insert(QStringLiteral("LIBGL_ALWAYS_SOFTWARE"), QStringLiteral("1"));
    p.setProcessEnvironment(env);
    p.setProcessChannelMode(QProcess::MergedChannels);
    p.start(xvfb, {QStringLiteral("-a"), QStringLiteral("-s"), QStringLiteral("-screen 0 1024x768x24"), QCoreApplication::applicationFilePath(),
                   QStringLiteral("--gtest_filter=GraphPixels.EachStyle*:GraphPixels.SamplesAdded*")});
    ASSERT_TRUE(p.waitForFinished(120000));
    const QString out = QString::fromUtf8(p.readAll());
    EXPECT_EQ(p.exitCode(), 0) << out.toStdString();
    EXPECT_TRUE(out.contains(QStringLiteral("[  PASSED  ] 2 tests"))) << out.toStdString();
}
