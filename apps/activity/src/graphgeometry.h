// Activity Monitor's graphs as vertex data (spec AM29, AM33, AM39, AM42, AM44; audit apps-misc "graphs rebuilt per sample").
// A graph block of the backend ({style, max, series: [{values, xs}], levels}) becomes filled bands without a line by default,
// as Graph.qml drew them with QtQuick.Shapes: "area" (series 0 from the bottom), "stacked" (series 1 on top of series 0),
// "mirrored" (series 0 up from the middle, series 1 down from it), "bars" (one bar per sample, a layer per level). A value
// below 0 is a gap: the band stops at the last sample before it and starts again after it; a lone sample is as wide as one
// slot. Without `xs` the newest value is at the right edge, one slot per sample of `capacity`; with them each value is at its
// own place (the battery's times).
//
// GraphRing keeps each layer's triangles in a ring of blocks, one block per sample, in coordinates that do not move with the
// window: x = (sample's sequence number − a base) × slot width, and the item translates the whole by one offset. A new sample
// (the history moved by one) writes the blocks of the samples whose pieces changed (the new one, the one before it, the
// first two at the left edge) and clears the blocks of the samples that left; nothing else is computed again. A change of
// scale, size, style or of a value already drawn rebuilds every block. Pure (Qt Core and Gui types only): graphitem.cpp puts
// it in the scene graph, tests/unit/activity/qml/tst_graph.cpp checks the vertex data.
#pragma once

#include <QColor>
#include <QList>
#include <QPolygonF>
#include <QVariantMap>

#include <cstdint>
#include <vector>

namespace activity::graph {

enum class Style { Area, Stacked, Mirrored, Bars };

// What one graph block asks for.
struct Spec {
    Style style = Style::Area;
    double ceiling = 1;
    int capacity = 1;
    QList<double> values0, values1;
    // Positions of values0 in [0, 1] of the width (the battery's times); empty: one slot per sample.
    QList<double> xs0;
    QList<int> levels;

    static Spec fromBlock(const QVariantMap &block, int capacity);
    bool operator==(const Spec &o) const
    {
        return style == o.style && ceiling == o.ceiling && capacity == o.capacity && values0 == o.values0 && values1 == o.values1
            && xs0 == o.xs0 && levels == o.levels;
    }
    bool operator!=(const Spec &o) const { return !(*this == o); }
};

// Layers, drawn in this order: series 0 ("lower"), series 1 ("upper"), the bars of level 0, 1 and 2.
constexpr int kLayers = 5;
constexpr int kLower = 0;
constexpr int kUpper = 1;
constexpr int kBars = 2;

// A sample of a band: its edge (the side away from the base, where the band is antialiased) and its base, in pixels.
struct Band {
    bool valid = false;
    float edge = 0;
    float base = 0;
};

// A vertex: position and coverage (1 inside, falling to 0 across the antialiased edge).
struct Vertex {
    float x = 0;
    float y = 0;
    float coverage = 0;
    bool operator==(const Vertex &o) const { return x == o.x && y == o.y && coverage == o.coverage; }
};

// Each block: the fill quad (4 vertices: edge left, edge right, base left, base right) and the edge's antialiasing strip
// (4: inner left, inner right, outer left, outer right). An empty block is 8 vertices at 0 (degenerate triangles).
constexpr int kBlockVertices = 8;
constexpr int kBlockIndices = 12;
// The triangles of block b (vertex indices from b * kBlockVertices).
void blockIndices(int b, uint32_t *out);

class GraphRing
{
public:
    // A new block: rebuilt, moved by whole samples, or unchanged. Returns true when anything drawn changed.
    bool update(const Spec &spec, float width, float height, float devicePixelRatio);

    int ringSize() const { return m_ring; }
    // The translation along x that puts the ring's coordinates in the item.
    float offset() const { return m_offset; }
    const std::vector<Vertex> &vertices(int layer) const { return m_vertices[layer]; }
    // Blocks written by the last update (all when it rebuilt) and whether it rebuilt (tests; the item uploads these).
    const std::vector<int> &written(int layer) const { return m_written[layer]; }
    bool rebuilt() const { return m_rebuilt; }
    bool layerUsed(int layer) const;

    // The block of sample i of the current spec (its sequence number's place in the ring).
    int blockOf(int i) const;

    // The same graph as closed polygons in item coordinates, one list per layer (the software renderer's path, and the
    // shapes Graph.qml drew: a run of samples, its edge left to right and its base back).
    QList<QPolygonF> polygons(int layer) const;

    // Sample i of a layer, and where it is along x in item coordinates (tests).
    Band band(int layer, int i) const;
    float xAt(int layer, int i) const;

private:
    int count(int layer) const;
    bool slotted(int layer) const;
    float slotWidth() const;
    float loneWidth() const;
    float relX(int layer, int i) const;
    void writeBlock(int layer, int i);
    void clearBlock(int layer, int block);
    void rebuildAll();
    // How many samples left at the front if the new spec is the old one moved along (-1: it is not).
    int shiftFrom(const Spec &old, const Spec &now) const;

    Spec m_spec;
    float m_width = 0;
    float m_height = 0;
    float m_dpr = 1;
    bool m_have = false;
    int m_ring = 0;
    // The sequence number of values[0], and the one x is counted from.
    int64_t m_first = 0;
    int64_t m_base = 0;
    float m_offset = 0;
    bool m_rebuilt = false;
    std::vector<Vertex> m_vertices[kLayers];
    std::vector<int> m_written[kLayers];
};

} // namespace activity::graph
