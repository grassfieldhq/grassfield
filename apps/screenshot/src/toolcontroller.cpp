#include "toolcontroller.h"

#include <QLineF>

namespace screenshot {

QStringList ToolController::tools()
{
    return {QStringLiteral("select"), QStringLiteral("arrow"),       QStringLiteral("line"),    QStringLiteral("rectangle"),
            QStringLiteral("ellipse"), QStringLiteral("pen"),        QStringLiteral("highlighter"), QStringLiteral("text"),
            QStringLiteral("counter"), QStringLiteral("eyedropper"), QStringLiteral("crop")};
}

bool ToolController::draws(const QString &tool)
{
    return tool == QLatin1String("arrow") || tool == QLatin1String("line") || tool == QLatin1String("rectangle") || tool == QLatin1String("ellipse")
        || tool == QLatin1String("pen") || tool == QLatin1String("highlighter") || tool == QLatin1String("counter");
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
        if (!draws(m_tool))
            return false;
        if (m_stack->layers().size() >= kMaxLayers || nextLayerId(m_stack->layers()) == 0)
            return false;
        // The file is read whole at 4 MiB: a stroke that would not fit is not started (a long drawing is many strokes of few points).
        if ((m_tool == QLatin1String("pen") || m_tool == QLatin1String("highlighter")) && layersToJson(m_stack->layers()).size() > kMaxLayersBytes * 3 / 4)
            return false;
        m_mode = Mode::Draw;
        m_drawId = 0;
        m_points = {p};
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
    if (m_mode == Mode::Draw && (m_tool == QLatin1String("pen") || m_tool == QLatin1String("highlighter"))) {
        // A stroke: the pointer's samples, thinned as they come. Shift keeps a highlighter straight (on a 45-degree line).
        if (constrain && m_tool == QLatin1String("highlighter"))
            m_points = {m_start, constrained(m_start, p, false)};
        else if (QLineF(m_points.last(), p).length() >= kMinSample)
            m_points.append(p);
        if (m_drawId == 0) {
            if (QLineF(m_start, p).length() < kMinDrag)
                return; // not a drag yet
            m_drawId = nextLayerId(now);
        }
        const Layer stroke = makeStroke(m_drawId, m_tool, simplified(m_points, kStrokeEpsilon), m_style);
        if (stroke.id == 0)
            return;
        Layers next = m_stack->gestureBase();
        next.append(stroke);
        m_stack->preview(next);
        return;
    }
    if (m_mode == Mode::Draw && m_tool == QLatin1String("counter")) {
        // A click puts one, and the pointer carries it until the button is let go.
        if (m_drawId == 0)
            m_drawId = nextLayerId(now);
        Layers next = m_stack->gestureBase();
        next.append(makeCounter(m_drawId, p, m_style));
        m_stack->preview(next);
        return;
    }
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
    if (m_mode == Mode::Draw && m_drawId != 0 && m_tool == QLatin1String("highlighter") && !constrain) {
        // The marker snaps straight when the stroke was nearly so (along a line of text).
        const QVector<QPointF> snapped = snappedStraight(simplified(m_points, kStrokeEpsilon), m_style.width * m_style.highlightFactor);
        Layers next = m_stack->gestureBase();
        next.append(makeStroke(m_drawId, m_tool, snapped, m_style));
        m_stack->preview(next);
    }
    const Mode mode = m_mode;
    m_mode = Mode::None;
    const bool changed = m_stack->commitGesture();
    if (mode == Mode::Draw && changed)
        m_selected = m_drawId; // the new shape is selected, with its handles
    m_drawId = 0;
    m_points.clear();
    return changed;
}

void ToolController::cancel()
{
    m_stack->cancelGesture();
    m_mode = Mode::None;
    m_drawId = 0;
    m_points.clear();
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

bool ToolController::addLayer(Layer layer)
{
    const Layers &now = m_stack->layers();
    const int id = nextLayerId(now);
    if (id == 0 || now.size() >= kMaxLayers || layer.type.isEmpty())
        return false;
    layer.id = id;
    Layers next = now;
    next.append(layer);
    const bool changed = m_stack->commit(next);
    if (changed)
        m_selected = id;
    return changed;
}

bool ToolController::replaceSelected(const Layer &layer)
{
    const int i = indexOf(m_selected);
    if (i < 0 || layer.id != m_selected)
        return false;
    Layers next = m_stack->layers();
    next[i] = layer;
    return m_stack->commit(next);
}

} // namespace screenshot
