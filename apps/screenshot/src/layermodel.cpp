#include "layermodel.h"

#include "annotations.h"

#include <QPointF>

using namespace screenshot;

namespace {

QVariantList closedPolyline(const QPolygonF &polygon)
{
    QVariantList points;
    for (const QPointF &p : polygon)
        points.append(p);
    if (!polygon.isEmpty())
        points.append(polygon.first());
    return points;
}

} // namespace

QHash<int, QByteArray> LayerModel::roleNames() const
{
    return {{KindRole, "gKind"},       {IdRole, "gId"},         {ColorRole, "gColor"},         {StrokeRole, "gStroke"},
            {FillRole, "gFill"},       {BoxXRole, "boxX"},      {BoxYRole, "boxY"},            {BoxWRole, "boxW"},
            {BoxHRole, "boxH"},        {StartRole, "startPt"},  {EndRole, "endPt"},            {CtrlRole, "ctrlPt"},
            {EndHeadRole, "endHead"},  {StartHeadRole, "startHead"}, {HeadStrokeRole, "headStroke"},
            {PathRole, "pathSvg"},     {FlatCapRole, "flatCap"}, {InkRole, "inkColor"},        {OutlineColorRole, "outlineColor"},
            {OutlineWidthRole, "outlineWidth"}, {PlateRole, "plateSvg"}, {PlateColorRole, "plateColor"}};
}

LayerModel::Row LayerModel::makeRow(const Layer &layer, int number)
{
    Row row;
    row.layer = layer;
    row.number = number;
    row.geometry = shapeGeometry(layer, number);
    row.endHead = closedPolyline(row.geometry.endHead);
    row.startHead = closedPolyline(row.geometry.startHead);
    if (row.geometry.kind == ShapeGeometry::Stroke || row.geometry.kind == ShapeGeometry::Glyphs || row.geometry.kind == ShapeGeometry::Spotlight)
        row.pathSvg = pathToSvg(row.geometry.path);
    if (row.geometry.kind == ShapeGeometry::Glyphs && !row.geometry.plate.isEmpty())
        row.plateSvg = pathToSvg(row.geometry.plate);
    return row;
}

QVariant LayerModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_rows.size())
        return {};
    const Row &row = m_rows[index.row()];
    const ShapeGeometry &g = row.geometry;
    switch (role) {
    case IdRole: return row.layer.id;
    case KindRole:
        switch (g.kind) {
        case ShapeGeometry::Rect: return QStringLiteral("rect");
        case ShapeGeometry::Ellipse: return QStringLiteral("ellipse");
        case ShapeGeometry::Line: return QStringLiteral("line");
        case ShapeGeometry::Arrow: return QStringLiteral("arrow");
        case ShapeGeometry::ArrowCurved: return QStringLiteral("arrowCurved");
        case ShapeGeometry::Stroke: return QStringLiteral("stroke");
        case ShapeGeometry::Glyphs: return QStringLiteral("glyphs");
        case ShapeGeometry::Redact: return QStringLiteral("redact");
        case ShapeGeometry::Pixelate: return QStringLiteral("pixelate");
        case ShapeGeometry::Blur: return QStringLiteral("blur");
        case ShapeGeometry::Spotlight: return QStringLiteral("spotlight");
        case ShapeGeometry::None: return QString();
        }
        return QString();
    case ColorRole: return g.color;
    case StrokeRole: return g.width;
    case FillRole: return g.fill;
    case BoxXRole: return g.box.x();
    case BoxYRole: return g.box.y();
    case BoxWRole: return g.box.width();
    case BoxHRole: return g.box.height();
    case StartRole: return g.shaftStart;
    case EndRole: return g.shaftEnd;
    case CtrlRole: return g.ctrl;
    case EndHeadRole: return row.endHead;
    case StartHeadRole: return row.startHead;
    case HeadStrokeRole: return g.headStroke;
    case PathRole: return row.pathSvg;
    case FlatCapRole: return g.flatCap;
    case InkRole: return g.ink;
    case OutlineColorRole: return g.outlineColor;
    case OutlineWidthRole: return g.outlineWidth;
    case PlateRole: return row.plateSvg;
    case PlateColorRole: return g.plateColor;
    default: return {};
    }
}

bool LayerModel::renumber(int from, const QList<int> &numbers, int *first, int *last)
{
    *first = *last = -1;
    for (int i = from; i < m_rows.size(); ++i) {
        if (m_rows[i].number == numbers[i])
            continue;
        m_rows[i] = makeRow(m_rows[i].layer, numbers[i]);
        if (*first < 0)
            *first = i;
        *last = i;
    }
    return *first >= 0;
}

int LayerModel::setLayers(const Layers &layers)
{
    const int oldSize = int(m_rows.size()), newSize = int(layers.size());
    const auto sameAs = [this, &layers]() {
        if (m_rows.size() != layers.size())
            return false;
        for (int i = 0; i < layers.size(); ++i) {
            if (m_rows[i].layer != layers[i])
                return false;
        }
        return true;
    };
    if (sameAs())
        return 0;
    const QList<int> numbers = counterNumbers(layers);
    const auto samePrefix = [this, &layers](int count) {
        for (int i = 0; i < count; ++i) {
            if (m_rows[i].layer.id != layers[i].id)
                return false;
        }
        return true;
    };
    if (oldSize == newSize && samePrefix(newSize)) {
        // The same layers in the same order: only the ones that differ are told about.
        int first = -1, last = -1;
        for (int i = 0; i < newSize; ++i) {
            if (m_rows[i].layer != layers[i]) {
                m_rows[i] = makeRow(layers[i], numbers[i]);
                if (first < 0)
                    first = i;
                last = i;
            }
        }
        emit dataChanged(index(first), index(last));
        return 1;
    }
    // One layer more or fewer (a new shape, a delete, an undo or a redo of either): the row goes in or out at its index and the others
    // keep their items. The ids around it are the same, in the same order.
    if (newSize == oldSize + 1 || oldSize == newSize + 1) {
        const bool adding = newSize > oldSize;
        const auto layerOf = [this](int i) -> const Layer & { return m_rows[i].layer; };
        int at = 0;
        const int shorter = adding ? oldSize : newSize;
        while (at < shorter && (adding ? layerOf(at).id == layers[at].id : layers[at].id == layerOf(at).id))
            ++at;
        bool rest = true; // after the row, the same layers (the data too, so a changed one is not hidden)
        for (int i = at; i < shorter && rest; ++i)
            rest = adding ? layerOf(i) == layers[i + 1] : layerOf(i + 1) == layers[i];
        bool before = true;
        for (int i = 0; i < at && before; ++i)
            before = layerOf(i) == layers[i];
        if (rest && before) {
            if (adding) {
                beginInsertRows(QModelIndex(), at, at);
                m_rows.insert(at, makeRow(layers[at], numbers[at]));
                endInsertRows();
            } else {
                beginRemoveRows(QModelIndex(), at, at);
                m_rows.removeAt(at);
                endRemoveRows();
            }
            // The counters after a row that went in or out are numbered again.
            int first, last;
            if (renumber(at, numbers, &first, &last))
                emit dataChanged(index(first), index(last));
            return adding ? 2 : 3;
        }
    }
    beginResetModel();
    m_rows.clear();
    m_rows.reserve(newSize);
    for (int i = 0; i < newSize; ++i)
        m_rows.append(makeRow(layers[i], numbers[i]));
    endResetModel();
    return 4;
}
