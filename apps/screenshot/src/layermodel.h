#pragma once

#include "annotations.h"
#include "layers.h"

#include <QAbstractListModel>
#include <QList>
#include <QString>
#include <QVariantList>

// The editor's shapes as a list model for the scene items of qml/ShapeScene.qml (one item per layer, in picture pixels). It is
// updated from the layer list after every edit with the least change: a drag edits one row (dataChanged: one item's geometry
// moves, no other item is touched), a layer more or fewer (a new shape, a cancelled one, a delete, an undo or redo of those) goes
// in or out at its index with the other rows' items kept; anything else (open, a revert) resets the model. The geometry is the exporter's own (shapeGeometry), so that the screen and the file agree.
// A counter's number is its place among the counters, so a row that goes in or out also tells the counters after it (dataChanged).
class LayerModel : public QAbstractListModel
{
    Q_OBJECT

public:
    // Names the delegates read (QML Items have x, y, width and color of their own, so these are prefixed).
    enum Role {
        KindRole = Qt::UserRole + 1, // "rect" "ellipse" "line" "arrow" "arrowCurved" "stroke" "glyphs", "" for a layer that does not read
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
        PathRole,         // stroke and glyphs: the outline as SVG path data (PathSvg)
        FlatCapRole,      // stroke: a highlighter's flat ends
        InkRole,          // glyphs: the fill of the lettering
        OutlineColorRole, // glyphs: the edge of an outlined text
        OutlineWidthRole, // 0 for none
        PlateRole,        // glyphs: a pill's or a counter's plate as SVG path data, "" for none
        PlateColorRole,
    };

    explicit LayerModel(QObject *parent = nullptr) : QAbstractListModel(parent) {}

    int rowCount(const QModelIndex &parent = QModelIndex()) const override { return parent.isValid() ? 0 : int(m_rows.size()); }
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    // Follows `layers`; returns the kind of change made (for the tests): 0 none, 1 rows changed, 2 row added, 3 row removed, 4 reset.
    int setLayers(const screenshot::Layers &layers);

private:
    // A row keeps what its geometry was made from, so that it is made again only when that changes (laying out text is not free).
    struct Row {
        screenshot::Layer layer;
        int number = 0; // a counter's place among the counters
        screenshot::ShapeGeometry geometry;
        QVariantList endHead, startHead;
        QString pathSvg, plateSvg;
    };
    static Row makeRow(const screenshot::Layer &layer, int number);
    // Makes again the rows of [from, to) whose number is not the one `numbers` gives; the range changed, or -1 for none.
    bool renumber(int from, const QList<int> &numbers, int *first, int *last);

    QList<Row> m_rows;
};
