#pragma once

#include "annotations.h"
#include "undostack.h"

#include <QPointF>
#include <QString>
#include <QStringList>

// The pointer logic of the editor's tools (slices B3 to B6), apart from QML so that it is tested: Select (pick, move, resize by a
// handle), Arrow, Line, Rectangle and Ellipse (drag out a shape), Pen and Highlighter (a stroke along the pointer) and Counter (a
// click puts one). Every gesture is one undo step (UndoStack). Positions are in picture pixels; the view converts, and gives the
// tolerance (a few view pixels, as picture pixels) for picking. The tools that are not pointer gestures of this class (Text opens
// an editor, Eyedropper reads a pixel, Crop has its own rectangle: framing.h) are named here and handled by the backend.
namespace screenshot {

constexpr qreal kMinDrag = 3; // a drag shorter than this (picture pixels) draws nothing
constexpr qreal kMinSample = 0.75;     // a pen sample closer than this to the last one is dropped
constexpr qreal kStrokeEpsilon = 0.4;  // and the stroke is thinned to within this of its drawn line (picture pixels)
constexpr int kMaxPendingSamples = 64; // the most samples held back since the last point kept

class ToolController
{
public:
    explicit ToolController(UndoStack *stack) : m_stack(stack) {}

    static QStringList tools();
    // The tools whose press, move and release draw a layer here.
    static bool draws(const QString &tool);
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

    // A stroke's preview is made when asked (flushPreview) instead of at every move, so that the owner can make one per frame; a
    // move then costs the same however long the stroke is. Off (the default): every move previews at once.
    void setDeferPreview(bool defer) { m_defer = defer; }
    bool previewPending() const { return m_dirty; }
    // The stroke as drawn so far, previewed; a release flushes by itself.
    void flushPreview();
    // The points of the stroke so far (the thinned samples and the latest one).
    QVector<QPointF> strokeSoFar() const;

    // Edits that are one step of their own. False when there is no selection (or nothing changed).
    bool deleteSelected();
    bool nudgeSelected(const QPointF &delta);
    // Puts `layer` on top with the next id and selects it (one step); false when the layers are full. The id of `layer` is ignored.
    bool addLayer(Layer layer);
    // The selected layer replaced by `layer` (same id; one step); false when nothing is selected or nothing changed.
    bool replaceSelected(const Layer &layer);

private:
    enum class Mode { None, Draw, Move, Resize };

    void updateGesture(const QPointF &p, bool constrain);
    void addSample(const QPointF &p);
    int indexOf(int id) const;

    UndoStack *m_stack;
    QString m_tool = QStringLiteral("select");
    ShapeStyle m_style;
    int m_selected = 0;
    Mode m_mode = Mode::None;
    QPointF m_start;
    Layer m_origin; // the selected layer when a move or a resize began
    int m_drawId = 0;
    // A stroke's samples, thinned as they come: the points kept, and the ones since the last kept, all within m_eps of the line from the
    // last kept to the latest (so a move is a bounded amount of work, and the stroke's size follows its shape, not its sampling).
    QVector<QPointF> m_kept;
    QVector<QPointF> m_pending;
    qreal m_eps = 0.4;
    bool m_defer = false;
    bool m_dirty = false;
    Handle::Kind m_handle = Handle::TopLeft;
};

} // namespace screenshot
