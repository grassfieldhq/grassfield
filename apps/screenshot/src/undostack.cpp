#include "undostack.h"

namespace screenshot {

void UndoStack::reset(const Layers &layers)
{
    m_current = layers;
    m_base.clear();
    m_gesture = false;
    m_undo.clear();
    m_redo.clear();
}

void UndoStack::push(const Layers &before)
{
    m_undo.append(before);
    while (m_undo.size() > kMaxUndoSteps)
        m_undo.removeFirst();
    m_redo.clear();
}

bool UndoStack::commit(const Layers &next)
{
    if (m_gesture) {
        m_current = next;
        return commitGesture();
    }
    if (next == m_current)
        return false;
    push(m_current);
    m_current = next;
    return true;
}

void UndoStack::preview(const Layers &next)
{
    if (!m_gesture) {
        m_base = m_current;
        m_gesture = true;
    }
    m_current = next;
}

bool UndoStack::commitGesture()
{
    if (!m_gesture)
        return false;
    m_gesture = false;
    const bool changed = m_current != m_base;
    if (changed)
        push(m_base);
    m_base.clear();
    return changed;
}

void UndoStack::cancelGesture()
{
    if (!m_gesture)
        return;
    m_current = m_base;
    m_base.clear();
    m_gesture = false;
}

bool UndoStack::undo()
{
    if (!canUndo())
        return false;
    m_redo.append(m_current);
    m_current = m_undo.takeLast();
    return true;
}

bool UndoStack::redo()
{
    if (!canRedo())
        return false;
    m_undo.append(m_current);
    m_current = m_redo.takeLast();
    return true;
}

} // namespace screenshot
