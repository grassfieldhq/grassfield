#include "graphitem.h"

#include <QImage>
#include <QPainter>
#include <QQuickWindow>
#include <QSGFlatColorMaterial>
#include <QSGGeometryNode>
#include <QSGImageNode>
#include <QSGRendererInterface>
#include <QSGTexture>
#include <QSGTransformNode>
#include <QSGVertexColorMaterial>
#include <QtQml/qqml.h>

#include <algorithm>
#include <cmath>

namespace activity {

using namespace graph;

namespace {

bool softwareRenderer(QQuickWindow *window)
{
    return window && window->rendererInterface() && window->rendererInterface()->graphicsApi() == QSGRendererInterface::Software;
}

// A layer's node: its geometry is the ring's blocks, coloured per vertex (premultiplied: the colour times the coverage).
class LayerNode : public QSGGeometryNode
{
public:
    LayerNode()
        : m_geometry(QSGGeometry::defaultAttributes_ColoredPoint2D(), 0, 0, QSGGeometry::UnsignedIntType)
    {
        m_geometry.setDrawingMode(QSGGeometry::DrawTriangles);
        setGeometry(&m_geometry);
        setMaterial(&m_material);
    }

    // Sized for `blocks` blocks, with their fixed triangles; the vertices are written by fill().
    void resize(int blocks)
    {
        if (m_geometry.vertexCount() == blocks * kBlockVertices)
            return;
        m_geometry.allocate(blocks * kBlockVertices, blocks * kBlockIndices);
        auto *indices = m_geometry.indexDataAsUInt();
        for (int b = 0; b < blocks; ++b)
            blockIndices(b, indices + static_cast<size_t>(b) * kBlockIndices);
        std::fill(m_geometry.vertexDataAsColoredPoint2D(), m_geometry.vertexDataAsColoredPoint2D() + m_geometry.vertexCount(),
                  QSGGeometry::ColoredPoint2D{0, 0, 0, 0, 0, 0});
    }

    void fill(const std::vector<Vertex> &from, int block, const QColor &color)
    {
        QSGGeometry::ColoredPoint2D *to = m_geometry.vertexDataAsColoredPoint2D() + static_cast<size_t>(block) * kBlockVertices;
        const Vertex *v = from.data() + static_cast<size_t>(block) * kBlockVertices;
        const float a = static_cast<float>(color.alphaF());
        for (int i = 0; i < kBlockVertices; ++i) {
            const float c = a * v[i].coverage;
            const auto u = [c](float channel) { return static_cast<uchar>(std::lround(std::clamp(channel * c, 0.0f, 1.0f) * 255.0f)); };
            to[i].set(v[i].x, v[i].y, u(static_cast<float>(color.redF())), u(static_cast<float>(color.greenF())),
                      u(static_cast<float>(color.blueF())), u(1.0f));
        }
    }

    void changed() { markDirty(QSGNode::DirtyGeometry); }

private:
    QSGGeometry m_geometry;
    QSGVertexColorMaterial m_material;
};

} // namespace

GraphItem::GraphItem(QQuickItem *parent)
    : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
}

void GraphItem::setGraph(const QVariantMap &graph)
{
    m_graph = graph;
    emit graphChanged();
    refresh();
}

void GraphItem::setCapacity(int capacity)
{
    if (capacity == m_capacity)
        return;
    m_capacity = capacity;
    emit capacityChanged();
    refresh();
}

void GraphItem::setColors(const QVariantList &colors)
{
    if (colors == m_colorList)
        return;
    m_colorList = colors;
    for (bool &all : m_allDirty)
        all = true;
    emit colorsChanged();
    update();
}

QColor GraphItem::layerColor(int layer) const
{
    return layer < m_colorList.size() ? m_colorList.at(layer).value<QColor>() : QColor(Qt::transparent);
}

void GraphItem::refresh()
{
    const qreal dpr = window() ? window()->effectiveDevicePixelRatio() : 1.0;
    if (!m_ring.update(Spec::fromBlock(m_graph, m_capacity), static_cast<float>(width()), static_cast<float>(height()),
                       static_cast<float>(dpr)))
        return;
    int written = 0;
    for (int layer = 0; layer < kLayers; ++layer) {
        const std::vector<int> &w = m_ring.written(layer);
        written += static_cast<int>(w.size());
        if (m_ring.rebuilt())
            m_allDirty[layer] = true;
        else if (!m_allDirty[layer])
            m_dirty[layer].insert(m_dirty[layer].end(), w.begin(), w.end());
    }
    if (m_ring.rebuilt())
        ++m_rebuilds;
    m_lastWritten = written;
    emit drawn();
    update();
}

void GraphItem::geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry)
{
    QQuickItem::geometryChange(newGeometry, oldGeometry);
    if (newGeometry.size() != oldGeometry.size())
        refresh();
}

void GraphItem::itemChange(ItemChange change, const ItemChangeData &value)
{
    QQuickItem::itemChange(change, value);
    if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange)
        refresh();
}

QSGNode *GraphItem::updatePaintNode(QSGNode *old, UpdatePaintNodeData *)
{
    if (width() <= 0 || height() <= 0) {
        delete old;
        return nullptr;
    }
    if (softwareRenderer(window())) {
        // The software renderer draws no geometry node: the shapes painted into an image, antialiased.
        auto *node = dynamic_cast<QSGImageNode *>(old);
        if (!node) {
            delete old;
            node = window()->createImageNode();
            node->setOwnsTexture(true);
        }
        const qreal dpr = window()->effectiveDevicePixelRatio();
        QImage image((size() * dpr).toSize(), QImage::Format_ARGB32_Premultiplied);
        image.setDevicePixelRatio(dpr);
        image.fill(Qt::transparent);
        QPainter painter(&image);
        painter.setRenderHint(QPainter::Antialiasing);
        painter.setPen(Qt::NoPen);
        for (int layer = 0; layer < kLayers; ++layer) {
            painter.setBrush(layerColor(layer));
            for (const QPolygonF &p : m_ring.polygons(layer))
                painter.drawPolygon(p);
        }
        painter.end();
        node->setTexture(window()->createTextureFromImage(image));
        node->setRect(boundingRect());
        for (auto &d : m_dirty)
            d.clear();
        return node;
    }

    auto *root = dynamic_cast<QSGTransformNode *>(old);
    if (!root) {
        delete old;
        root = new QSGTransformNode;
        for (int layer = 0; layer < kLayers; ++layer) {
            auto *node = new LayerNode;
            node->setFlag(QSGNode::OwnedByParent);
            root->appendChildNode(node);
        }
        for (bool &all : m_allDirty)
            all = true;
    }
    QMatrix4x4 m;
    m.translate(m_ring.offset(), 0);
    if (root->matrix() != m) {
        root->setMatrix(m);
        root->markDirty(QSGNode::DirtyMatrix);
    }
    int layer = 0;
    for (QSGNode *child = root->firstChild(); child && layer < kLayers; child = child->nextSibling(), ++layer) {
        auto *node = static_cast<LayerNode *>(child);
        const QColor color = layerColor(layer);
        const std::vector<Vertex> &vertices = m_ring.vertices(layer);
        const int blocks = static_cast<int>(vertices.size()) / kBlockVertices;
        if (m_allDirty[layer]) {
            node->resize(blocks);
            for (int b = 0; b < blocks; ++b)
                node->fill(vertices, b, color);
            node->changed();
        } else if (!m_dirty[layer].empty()) {
            for (int b : m_dirty[layer]) {
                if (b < blocks)
                    node->fill(vertices, b, color);
            }
            node->changed();
        }
        m_allDirty[layer] = false;
        m_dirty[layer].clear();
    }
    return root;
}

void registerGraphItem()
{
    qmlRegisterType<GraphItem>("Grassfield.Activity", 1, 0, "GraphItem");
}

} // namespace activity
