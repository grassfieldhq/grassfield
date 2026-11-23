#pragma once

#include "layers.h"

#include <QAbstractListModel>
#include <QList>

// The editor's shapes as a list model for the scene items of qml/ShapeScene.qml (one item per layer, in picture pixels). It is
// updated from the layer list after every edit with the least change: a drag edits one row (dataChanged: one item's geometry
// moves, no other item is touched), a layer more or fewer (a new shape, a cancelled one, a delete, an undo or redo of those) goes
// in or out at its index with the other rows' items kept; anything else (open, a revert) resets the model. The geometry is the exporter's own (shapeGeometry), so that the screen and the file agree.
class LayerModel : public QAbstractListModel
{
    Q_OBJECT

public:
    // Names the delegates read (QML Items have x, y, width and color of their own, so these are prefixed).
    enum Role {
        KindRole = Qt::UserRole + 1, // "rect" "ellipse" "line" "arrow" "arrowCurved", "" for a layer that does not read
        IdRole,
        ColorRole,
        StrokeRole,
        FillRole,
        BoxXRole,
        BoxYRole,
        BoxWRole,
        BoxHRole,
        StartRole, // a point (the shaft's first end)
        EndRole,   // the shaft's last end
        CtrlRole,
        EndHeadRole,   // a closed polyline of points (the first one again at the end), empty without a head
        StartHeadRole,
        HeadStrokeRole,
    };

    explicit LayerModel(QObject *parent = nullptr) : QAbstractListModel(parent) {}

    int rowCount(const QModelIndex &parent = QModelIndex()) const override { return parent.isValid() ? 0 : int(m_layers.size()); }
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    // Follows `layers`; returns the kind of change made (for the tests): 0 none, 1 rows changed, 2 row added, 3 row removed, 4 reset.
    int setLayers(const screenshot::Layers &layers);

private:
    screenshot::Layers m_layers;
};
