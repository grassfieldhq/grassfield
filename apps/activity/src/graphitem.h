// Activity Monitor's graph in the scene graph (graphgeometry.h has the shapes): one QSGGeometryNode per layer, under a
// transform that slides the ring along x. A new sample uploads the blocks GraphRing wrote (the new sample's and the edges'),
// not the shapes rebuilt in JavaScript and triangulated again as Graph.qml did with QtQuick.Shapes (audit apps-misc). Filled
// bands without a line, their edge antialiased by a coverage strip (vertex colours), as the Shapes' curve renderer drew
// them. On the software renderer (no geometry nodes) the same shapes are painted with QPainter into an image node.
// Registered as Grassfield.Activity/GraphItem by the app (registerGraphItem); Graph.qml makes it.
#pragma once

#include "graphgeometry.h"

#include <QColor>
#include <QQuickItem>
#include <QVariantList>
#include <QVariantMap>

#include <vector>

namespace activity {

class GraphItem : public QQuickItem
{
    Q_OBJECT
    // The backend's graph block ({style, max, series, levels}).
    Q_PROPERTY(QVariantMap graph READ graph WRITE setGraph NOTIFY graphChanged)
    Q_PROPERTY(int capacity READ capacity WRITE setCapacity NOTIFY capacityChanged)
    // The layers' colours: series 0, series 1, then the bars of level 0, 1 and 2 (Graph.qml resolves the block's colour names).
    Q_PROPERTY(QVariantList colors READ colors WRITE setColors NOTIFY colorsChanged)
    // How many times the geometry was rebuilt whole, and how many blocks the last change wrote (tests).
    Q_PROPERTY(int rebuilds READ rebuilds NOTIFY drawn)
    Q_PROPERTY(int lastWritten READ lastWritten NOTIFY drawn)

public:
    explicit GraphItem(QQuickItem *parent = nullptr);

    QVariantMap graph() const { return m_graph; }
    void setGraph(const QVariantMap &graph);
    int capacity() const { return m_capacity; }
    void setCapacity(int capacity);
    QVariantList colors() const { return m_colorList; }
    void setColors(const QVariantList &colors);
    int rebuilds() const { return m_rebuilds; }
    int lastWritten() const { return m_lastWritten; }

    const graph::GraphRing &ring() const { return m_ring; }

signals:
    void graphChanged();
    void capacityChanged();
    void colorsChanged();
    void drawn();

protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *data) override;
    void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;
    void itemChange(ItemChange change, const ItemChangeData &value) override;

private:
    void refresh();
    QColor layerColor(int layer) const;

    graph::GraphRing m_ring;
    QVariantMap m_graph;
    int m_capacity = 1;
    QVariantList m_colorList;
    // Waiting for the render thread: per layer, every block (a rebuild, a new colour) or the blocks written since.
    bool m_allDirty[graph::kLayers] = {true, true, true, true, true};
    std::vector<int> m_dirty[graph::kLayers];
    int m_rebuilds = 0;
    int m_lastWritten = 0;
};

// Grassfield.Activity 1.0: GraphItem (the app's main() and the QML tests' harness).
void registerGraphItem();

} // namespace activity
