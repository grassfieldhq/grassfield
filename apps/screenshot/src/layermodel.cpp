#include "layermodel.h"

#include "annotations.h"

#include <QPointF>
#include <QVariantList>

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

bool samePrefix(const Layers &a, const Layers &b, int count)
{
    for (int i = 0; i < count; ++i) {
        if (a[i].id != b[i].id)
            return false;
    }
    return true;
}

} // namespace

QHash<int, QByteArray> LayerModel::roleNames() const
{
    return {{KindRole, "gKind"},       {IdRole, "gId"},         {ColorRole, "gColor"},         {StrokeRole, "gStroke"},
            {FillRole, "gFill"},       {BoxXRole, "boxX"},      {BoxYRole, "boxY"},            {BoxWRole, "boxW"},
            {BoxHRole, "boxH"},        {StartRole, "startPt"},  {EndRole, "endPt"},            {CtrlRole, "ctrlPt"},
            {EndHeadRole, "endHead"},  {StartHeadRole, "startHead"}, {HeadStrokeRole, "headStroke"}};
}

QVariant LayerModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_layers.size())
        return {};
    const Layer &layer = m_layers[index.row()];
    if (role == IdRole)
        return layer.id;
    const ShapeGeometry g = shapeGeometry(layer);
    switch (role) {
    case KindRole:
        switch (g.kind) {
        case ShapeGeometry::Rect: return QStringLiteral("rect");
        case ShapeGeometry::Ellipse: return QStringLiteral("ellipse");
        case ShapeGeometry::Line: return QStringLiteral("line");
        case ShapeGeometry::Arrow: return QStringLiteral("arrow");
        case ShapeGeometry::ArrowCurved: return QStringLiteral("arrowCurved");
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
    case EndHeadRole: return closedPolyline(g.endHead);
    case StartHeadRole: return closedPolyline(g.startHead);
    case HeadStrokeRole: return g.headStroke;
    default: return {};
    }
}

int LayerModel::setLayers(const Layers &layers)
{
    if (layers == m_layers)
        return 0;
    const int oldSize = int(m_layers.size()), newSize = int(layers.size());
    if (oldSize == newSize && samePrefix(m_layers, layers, newSize)) {
        // The same layers in the same order: only the ones that differ are told about.
        int first = -1, last = -1;
        for (int i = 0; i < newSize; ++i) {
            if (m_layers[i] != layers[i]) {
                if (first < 0)
                    first = i;
                last = i;
            }
        }
        m_layers = layers;
        emit dataChanged(index(first), index(last));
        return 1;
    }
    // One layer more or fewer (a new shape, a delete, an undo or a redo of either): the row goes in or out at its index and the others
    // keep their items. The ids around it are the same, in the same order.
    if (newSize == oldSize + 1 || oldSize == newSize + 1) {
        const bool adding = newSize > oldSize;
        const Layers &longer = adding ? layers : m_layers;
        const Layers &shorter = adding ? m_layers : layers;
        int at = 0;
        while (at < shorter.size() && longer[at].id == shorter[at].id)
            ++at;
        bool rest = true; // after the row, the same layers (the data too, so a changed one is not hidden)
        for (int i = at; i < shorter.size() && rest; ++i)
            rest = longer[i + 1] == shorter[i];
        bool before = true;
        for (int i = 0; i < at && before; ++i)
            before = longer[i] == shorter[i];
        if (rest && before) {
            if (adding) {
                beginInsertRows(QModelIndex(), at, at);
                m_layers = layers;
                endInsertRows();
                return 2;
            }
            beginRemoveRows(QModelIndex(), at, at);
            m_layers = layers;
            endRemoveRows();
            return 3;
        }
    }
    beginResetModel();
    m_layers = layers;
    endResetModel();
    return 4;
}
