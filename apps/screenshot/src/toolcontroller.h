#pragma once

#include "annotations.h"
#include "undostack.h"

#include <QPointF>
#include <QString>
#include <QStringList>

// The pointer logic of the editor's tools (slices B3 and B4), apart from QML so that it is tested: Select (pick, move, resize by a
// handle), Arrow, Line, Rectangle and Ellipse (drag out a shape). Every gesture is one undo step (UndoStack). Positions are in
// picture pixels; the view converts, and gives the tolerance (a few view pixels, as picture pixels) for picking.
namespace screenshot {

constexpr qreal kMinDrag = 3; // a drag shorter than this (picture pixels) draws nothing

class ToolController
{
public:
    explicit ToolController(UndoStack *stack) : m_stack(stack) {}

    static QStringList tools();
    const QString &tool() const { return m_tool; }
    // False for an unknown tool. A gesture in progress is cancelled.
    bool setTool(const QString &tool);

    ShapeStyle &style() { return m_style; }
    const ShapeStyle &style() const { return m_style; }

    int selected() const { return m_selected; }
    void select(int id);
    // The selection is dropped when its layer is no longer there (after an undo, a redo, a reset).
    void syncSelection();
    Layer selectedLayer() const;
    QList<Handle> selectionHandles() const { return handlesOf(selectedLayer()); }
    QRectF selectionBounds() const { return layerBounds(selectedLayer()); }

    // The pointer. `constrain` (Shift) keeps a drawn line or arrow on a 45-degree line and a drawn box square. press returns
    // whether it started a gesture; release whether the layers changed.
    bool press(const QPointF &p, qreal tolerance);
    void move(const QPointF &p, bool constrain);
    bool release(const QPointF &p, bool constrain);
    void cancel();
    bool busy() const { return m_mode != Mode::None; }

    // Edits that are one step of their own. False when there is no selection (or nothing changed).
    bool deleteSelected();
    bool nudgeSelected(const QPointF &delta);

private:
    enum class Mode { None, Draw, Move, Resize };

    void updateGesture(const QPointF &p, bool constrain);
    int indexOf(int id) const;

    UndoStack *m_stack;
    QString m_tool = QStringLiteral("select");
    ShapeStyle m_style;
    int m_selected = 0;
    Mode m_mode = Mode::None;
    QPointF m_start;
    Layer m_origin; // the selected layer when a move or a resize began
    int m_drawId = 0;
    Handle::Kind m_handle = Handle::TopLeft;
};

} // namespace screenshot
