#include "toolcontroller.h"

#include <QLineF>

namespace screenshot {

QStringList ToolController::tools()
{
    return {QStringLiteral("select"), QStringLiteral("arrow"), QStringLiteral("line"), QStringLiteral("rectangle"), QStringLiteral("ellipse")};
}

bool ToolController::setTool(const QString &tool)
{
    if (!tools().contains(tool))
        return false;
    cancel();
    m_tool = tool;
    return true;
}

void ToolController::select(int id)
{
    m_selected = indexOf(id) >= 0 ? id : 0;
}

void ToolController::syncSelection()
{
    if (m_selected != 0 && indexOf(m_selected) < 0)
        m_selected = 0;
}

int ToolController::indexOf(int id) const
{
    const Layers &layers = m_stack->layers();
    for (int i = 0; i < layers.size(); ++i) {
        if (layers[i].id == id)
            return i;
    }
    return -1;
}

Layer ToolController::selectedLayer() const
{
    const int i = indexOf(m_selected);
    return i >= 0 ? m_stack->layers()[i] : Layer{};
}

bool ToolController::press(const QPointF &p, qreal tolerance)
{
    if (busy())
        cancel();
    m_start = p;
    if (m_tool != QLatin1String("select")) {
        if (m_stack->layers().size() >= kMaxLayers || nextLayerId(m_stack->layers()) == 0)
            return false;
        m_mode = Mode::Draw;
        m_drawId = 0;
        return true;
    }
    // A handle of the selected layer first, then the topmost layer under the pointer.
    const Layer current = selectedLayer();
    Handle::Kind kind;
    if (current.id != 0 && handleAt(current, p, tolerance, &kind)) {
        m_mode = Mode::Resize;
        m_handle = kind;
        m_origin = current;
        return true;
    }
    const int id = hitTest(m_stack->layers(), p, tolerance);
    m_selected = id;
    if (id == 0)
        return false;
    m_mode = Mode::Move;
    m_origin = selectedLayer();
    return true;
}

void ToolController::updateGesture(const QPointF &p, bool constrain)
{
    const Layers &now = m_stack->layers();
    if (m_mode == Mode::Draw) {
        const bool box = m_tool == QLatin1String("rectangle") || m_tool == QLatin1String("ellipse");
        const QPointF end = constrain ? constrained(m_start, p, box) : p;
        if (m_drawId == 0) {
            if (QLineF(m_start, end).length() < kMinDrag)
                return; // not a drag yet
            m_drawId = nextLayerId(now);
        }
        Layers next = m_stack->gestureBase();
        next.append(makeShape(m_drawId, m_tool, m_start, end, m_style));
        m_stack->preview(next);
        return;
    }
    const int i = indexOf(m_origin.id);
    if (i < 0)
        return;
    Layers next = m_stack->gestureBase();
    if (m_mode == Mode::Move) {
        next[i] = translated(m_origin, p - m_start);
    } else if (m_mode == Mode::Resize) {
        const bool box = m_origin.type == QLatin1String("rectangle") || m_origin.type == QLatin1String("ellipse");
        QPointF to = p;
        if (constrain && !box) {
            // An end of a line keeps its 45-degree angle from the other end.
            const QList<Handle> handles = handlesOf(m_origin);
            QPointF anchor;
            if (m_handle == Handle::From && handles.size() > 1)
                anchor = handles[1].pos;
            else if (m_handle == Handle::To)
                anchor = handles[0].pos;
            else
                anchor = p;
            to = constrained(anchor, p, false);
        }
        next[i] = draggedHandle(m_origin, m_handle, to);
    }
    m_stack->preview(next);
}

void ToolController::move(const QPointF &p, bool constrain)
{
    if (m_mode != Mode::None)
        updateGesture(p, constrain);
}

bool ToolController::release(const QPointF &p, bool constrain)
{
    if (m_mode == Mode::None)
        return false;
    updateGesture(p, constrain);
    const Mode mode = m_mode;
    m_mode = Mode::None;
    const bool changed = m_stack->commitGesture();
    if (mode == Mode::Draw && changed)
        m_selected = m_drawId; // the new shape is selected, with its handles
    m_drawId = 0;
    return changed;
}

void ToolController::cancel()
{
    m_stack->cancelGesture();
    m_mode = Mode::None;
    m_drawId = 0;
}

bool ToolController::deleteSelected()
{
    const int i = indexOf(m_selected);
    if (i < 0)
        return false;
    Layers next = m_stack->layers();
    next.removeAt(i);
    const bool changed = m_stack->commit(next);
    m_selected = 0;
    return changed;
}

bool ToolController::nudgeSelected(const QPointF &delta)
{
    const int i = indexOf(m_selected);
    if (i < 0 || busy())
        return false;
    Layers next = m_stack->layers();
    next[i] = translated(next[i], delta);
    return m_stack->commit(next);
}

} // namespace screenshot
