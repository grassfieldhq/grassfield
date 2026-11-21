#include "graphgeometry.h"

#include <QPointF>
#include <QVariantList>

#include <algorithm>
#include <cmath>

namespace activity::graph {

namespace {

QList<double> doubles(const QVariant &v)
{
    QList<double> out;
    const QVariantList list = v.toList();
    out.reserve(list.size());
    for (const QVariant &x : list) {
        bool ok = false;
        const double d = x.toDouble(&ok);
        out.append(ok && std::isfinite(d) ? d : -1.0);
    }
    return out;
}

// The steepest edge whose antialiasing strip is still drawn along y (a spike's side is mostly vertical: its strip would
// grow long and thin); beyond it the strip is this long.
constexpr float kMaxStripSlope = 16.0f;

} // namespace

Spec Spec::fromBlock(const QVariantMap &block, int capacity)
{
    Spec s;
    const QString style = block.value(QStringLiteral("style")).toString();
    s.style = style == QLatin1String("stacked") ? Style::Stacked
        : style == QLatin1String("mirrored")    ? Style::Mirrored
        : style == QLatin1String("bars")        ? Style::Bars
                                                : Style::Area;
    const double max = block.value(QStringLiteral("max")).toDouble();
    s.ceiling = max > 0 && std::isfinite(max) ? max : 1.0;
    s.capacity = std::max(1, capacity);
    const QVariantList series = block.value(QStringLiteral("series")).toList();
    if (!series.isEmpty()) {
        const QVariantMap first = series.at(0).toMap();
        s.values0 = doubles(first.value(QStringLiteral("values")));
        s.xs0 = doubles(first.value(QStringLiteral("xs")));
    }
    if (series.size() > 1)
        s.values1 = doubles(series.at(1).toMap().value(QStringLiteral("values")));
    for (const QVariant &l : block.value(QStringLiteral("levels")).toList())
        s.levels.append(l.toInt());
    return s;
}

void blockIndices(int b, uint32_t *out)
{
    const uint32_t v = static_cast<uint32_t>(b) * kBlockVertices;
    const uint32_t pattern[kBlockIndices] = {0, 1, 2, 1, 3, 2, 4, 5, 6, 5, 7, 6};
    for (int i = 0; i < kBlockIndices; ++i)
        out[i] = v + pattern[i];
}

int GraphRing::count(int layer) const
{
    switch (layer) {
    case kLower:
        return m_spec.style == Style::Bars ? 0 : static_cast<int>(m_spec.values0.size());
    case kUpper:
        return m_spec.style == Style::Stacked || m_spec.style == Style::Mirrored ? static_cast<int>(m_spec.values1.size()) : 0;
    default:
        return m_spec.style == Style::Bars ? static_cast<int>(m_spec.values0.size()) : 0;
    }
}

bool GraphRing::layerUsed(int layer) const
{
    return count(layer) > 0;
}

bool GraphRing::slotted(int layer) const
{
    // Series 0 of an area or a stack may be placed by its own xs (the battery's times); the rest is one slot per sample.
    return !(layer == kLower && !m_spec.xs0.isEmpty() && (m_spec.style == Style::Area || m_spec.style == Style::Stacked));
}

float GraphRing::slotWidth() const
{
    if (m_spec.style == Style::Bars)
        return m_width / static_cast<float>(std::max(1, m_spec.capacity));
    return m_width / static_cast<float>(std::max(1, m_spec.capacity - 1));
}

float GraphRing::loneWidth() const
{
    return m_width / static_cast<float>(std::max(1, m_spec.capacity - 1));
}

float GraphRing::xAt(int layer, int i) const
{
    if (!slotted(layer) && i < m_spec.xs0.size())
        return static_cast<float>(m_spec.xs0.at(i)) * m_width;
    const int n = count(layer);
    return m_width - static_cast<float>(n - 1 - i) * slotWidth();
}

float GraphRing::relX(int layer, int i) const
{
    // A graph whose series 0 is placed by time is in item coordinates (it is rebuilt at every change).
    if (!slotted(kLower))
        return xAt(layer, i);
    return static_cast<float>(m_first + i - m_base) * slotWidth();
}

Band GraphRing::band(int layer, int i) const
{
    Band b;
    const float h = m_height;
    const auto share = [this](double v) { return static_cast<float>(std::min(1.0, v / m_spec.ceiling)); };
    const auto yOf = [h, share](double v) { return h - share(v) * h; };
    if (layer == kLower) {
        const double v = i < m_spec.values0.size() ? m_spec.values0.at(i) : -1;
        b.valid = v >= 0;
        if (m_spec.style == Style::Mirrored) {
            b.edge = h / 2 - share(v) * h / 2;
            b.base = h / 2;
        } else {
            b.edge = yOf(v);
            b.base = h;
        }
    } else if (layer == kUpper) {
        const double v = i < m_spec.values1.size() ? m_spec.values1.at(i) : -1;
        if (m_spec.style == Style::Mirrored) {
            b.valid = v >= 0;
            b.edge = h / 2 + share(v) * h / 2;
            b.base = h / 2;
        } else {
            const double under = i < m_spec.values0.size() ? m_spec.values0.at(i) : -1;
            b.valid = v >= 0 && under >= 0;
            b.edge = yOf(under + v);
            b.base = yOf(under);
        }
    } else {
        const double v = i < m_spec.values0.size() ? m_spec.values0.at(i) : -1;
        const int level = i < m_spec.levels.size() ? m_spec.levels.at(i) : -1;
        b.valid = v >= 0 && level == layer - kBars;
        b.edge = yOf(v);
        b.base = h;
    }
    if (!b.valid)
        b.edge = b.base = 0;
    return b;
}

int GraphRing::blockOf(int i) const
{
    if (m_ring <= 0)
        return 0;
    const int64_t r = (m_first + i) % m_ring;
    return static_cast<int>(r < 0 ? r + m_ring : r);
}

void GraphRing::clearBlock(int layer, int block)
{
    Vertex *v = m_vertices[layer].data() + static_cast<size_t>(block) * kBlockVertices;
    std::fill(v, v + kBlockVertices, Vertex{});
    m_written[layer].push_back(block);
}

void GraphRing::writeBlock(int layer, int i)
{
    const int block = blockOf(i);
    Vertex *v = m_vertices[layer].data() + static_cast<size_t>(block) * kBlockVertices;
    m_written[layer].push_back(block);
    std::fill(v, v + kBlockVertices, Vertex{});
    const int n = count(layer);
    if (i < 0 || i >= n)
        return;

    // The piece of this block: a quad from (xl, edge el, base bl) to (xr, er, br).
    float xl = 0, xr = 0, el = 0, er = 0, bl = 0, br = 0;
    const Band cur = band(layer, i);
    if (layer >= kBars) {
        if (!cur.valid)
            return;
        // Each bar meets the next (half a pixel over it, so no seam shows between two of the same colour).
        xr = relX(layer, i);
        xl = xr - slotWidth() - 0.5f;
        el = er = cur.edge;
        bl = br = cur.base;
    } else {
        const Band prev = i >= 1 ? band(layer, i - 1) : Band{};
        const float w = loneWidth();
        if (prev.valid && cur.valid) {
            // The band from the sample before to this one.
            xl = relX(layer, i - 1);
            xr = relX(layer, i);
            el = prev.edge;
            er = cur.edge;
            bl = prev.base;
            br = cur.base;
        } else if (prev.valid && !cur.valid && (i - 1 == 0 || !band(layer, i - 2).valid)) {
            // The sample before stands alone (a gap on each side): as wide as one slot.
            xr = relX(layer, i - 1);
            xl = xr - w;
            el = er = prev.edge;
            bl = br = prev.base;
        } else if (i == n - 1 && cur.valid && !prev.valid) {
            // The newest sample after a gap (or the only one): as wide as one slot, until the next one joins it.
            xr = relX(layer, i);
            xl = xr - w;
            el = er = cur.edge;
            bl = br = cur.base;
        } else {
            return;
        }
    }

    // The fill, then the strip along the edge (away from the base): from half the coverage at the edge to none half a device
    // pixel further, measured across the edge (as a coverage-antialiased edge of Qt Quick Shapes looks).
    const float hl = std::abs(bl - el), hr = std::abs(br - er);
    if (hl <= 0 && hr <= 0)
        return; // nothing to fill: a value of 0 draws nothing, not a line
    v[0] = {xl, el, 1};
    v[1] = {xr, er, 1};
    v[2] = {xl, bl, 1};
    v[3] = {xr, br, 1};
    const float outward = (el + er) < (bl + br) ? -1.0f : 1.0f;
    const float dx = xr - xl;
    const float slope = dx > 0 ? std::min(kMaxStripSlope, std::abs(er - el) / dx) : 0.0f;
    const float reach = 0.5f / std::max(1.0f, m_dpr) * std::sqrt(1.0f + slope * slope);
    v[4] = {xl, el, 0.5f * std::min(1.0f, hl)};
    v[5] = {xr, er, 0.5f * std::min(1.0f, hr)};
    v[6] = {xl, el + outward * reach, 0};
    v[7] = {xr, er + outward * reach, 0};
}

void GraphRing::rebuildAll()
{
    int most = 0;
    for (int layer = 0; layer < kLayers; ++layer)
        most = std::max(most, count(layer));
    m_ring = std::max(m_spec.capacity, most) + 1;
    m_first = 0;
    m_base = 0;
    m_rebuilt = true;
    for (int layer = 0; layer < kLayers; ++layer) {
        m_vertices[layer].assign(static_cast<size_t>(m_ring) * kBlockVertices, Vertex{});
        m_written[layer].clear();
        for (int b = 0; b < m_ring; ++b)
            m_written[layer].push_back(b);
        const int n = count(layer);
        for (int i = 0; i < n; ++i)
            writeBlock(layer, i);
        // writeBlock listed its blocks again: the list says "every block" once.
        m_written[layer].resize(static_cast<size_t>(m_ring));
    }
}

int GraphRing::shiftFrom(const Spec &old, const Spec &now) const
{
    const auto moved = [](const auto &a, const auto &b, int k) {
        // b is a moved k to the left, then grown at its end (an array the graph does not have stays empty).
        if (a.empty() && b.empty())
            return true;
        const int keep = static_cast<int>(a.size()) - k;
        if (keep < 0 || b.size() < keep)
            return false;
        return std::equal(a.begin() + k, a.end(), b.begin());
    };
    // At least one sample kept: a history replaced whole is drawn again whole.
    const int most = std::min<int>(static_cast<int>(old.values0.size()) - 1, 4);
    for (int k = 0; k <= most; ++k) {
        if (moved(old.values0, now.values0, k) && moved(old.values1, now.values1, k) && moved(old.levels, now.levels, k))
            return k;
    }
    return -1;
}

bool GraphRing::update(const Spec &spec, float width, float height, float devicePixelRatio)
{
    for (auto &w : m_written)
        w.clear();
    m_rebuilt = false;
    const Spec old = m_spec;
    const bool sameFrame = m_have && width == m_width && height == m_height && devicePixelRatio == m_dpr && spec.style == old.style
        && spec.capacity == old.capacity && spec.ceiling == old.ceiling && spec.xs0.isEmpty() && old.xs0.isEmpty();
    if (sameFrame && spec == old)
        return false;
    m_spec = spec;
    m_width = width;
    m_height = height;
    m_dpr = devicePixelRatio;
    m_have = true;

    // Moved along by whole samples, every layer by as many (the same lengths), within the ring: only the edges change.
    int k = sameFrame ? shiftFrom(old, spec) : -1;
    int oldN = 0, newN = 0;
    for (int layer = 0; layer < kLayers && k >= 0; ++layer) {
        m_spec = old;
        const int before = count(layer);
        m_spec = spec;
        const int after = count(layer);
        if (before == 0 && after == 0)
            continue;
        if ((oldN != 0 && before != oldN) || (newN != 0 && after != newN))
            k = -1;
        oldN = before;
        newN = after;
    }
    if (k < 0 || newN > m_ring || m_first + k - m_base > 3LL * m_ring) {
        rebuildAll();
    } else {
        for (int layer = 0; layer < kLayers; ++layer) {
            if (count(layer) == 0)
                continue;
            for (int j = 0; j < k; ++j)
                clearBlock(layer, blockOf(j));
        }
        m_first += k;
        for (int layer = 0; layer < kLayers; ++layer) {
            if (count(layer) == 0)
                continue;
            // The left edge (a sample that became the first may stand alone now), then the right one: the samples added
            // and the last one before them (its piece was the newest's).
            if (k > 0) {
                writeBlock(layer, 0);
                if (newN > 1)
                    writeBlock(layer, 1);
            }
            for (int i = std::max(0, oldN - k - 1); i < newN; ++i)
                writeBlock(layer, i);
        }
    }
    const int n = std::max(count(kLower), count(kBars));
    m_offset = slotted(kLower) ? m_width - static_cast<float>(n - 1 + m_first - m_base) * slotWidth() : 0.0f;
    return true;
}

QList<QPolygonF> GraphRing::polygons(int layer) const
{
    QList<QPolygonF> out;
    const int n = count(layer);
    if (layer >= kBars) {
        const float slot = slotWidth();
        for (int i = 0; i < n; ++i) {
            const Band b = band(layer, i);
            if (!b.valid)
                continue;
            const float right = xAt(layer, i), left = right - slot - 0.5f;
            out.append(QPolygonF({QPointF(left, b.base), QPointF(left, b.edge), QPointF(right, b.edge), QPointF(right, b.base),
                                  QPointF(left, b.base)}));
        }
        return out;
    }
    QList<QPointF> top, bottom;
    for (int i = 0; i <= n; ++i) {
        const Band b = i < n ? band(layer, i) : Band{};
        if (b.valid) {
            const float x = xAt(layer, i);
            top.append(QPointF(x, b.edge));
            bottom.prepend(QPointF(x, b.base));
            continue;
        }
        if (top.size() == 1) { // a lone sample: as wide as one slot
            const float w = loneWidth();
            top.prepend(QPointF(top.at(0).x() - w, top.at(0).y()));
            bottom.append(QPointF(bottom.at(0).x() - w, bottom.at(0).y()));
        }
        if (!top.isEmpty()) {
            QPolygonF p(top);
            p << bottom << top.at(0);
            out.append(p);
        }
        top.clear();
        bottom.clear();
    }
    return out;
}

} // namespace activity::graph
