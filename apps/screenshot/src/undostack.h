#pragma once

#include "layers.h"

#include <QList>

// The undo stack of the editor (slice B3): a stack of whole layer lists (layers are small: at most kMaxLayers of a few numbers
// each, and the stack keeps kMaxUndoSteps). One step is one user action: a drag is many previews and one step.
// Not thread-safe: the GUI thread.
namespace screenshot {

constexpr int kMaxUndoSteps = 200;

class UndoStack
{
public:
    // The layers now, with the gesture in progress applied.
    const Layers &layers() const { return m_current; }

    // Starts again from `layers`: no steps, no gesture.
    void reset(const Layers &layers = {});

    // One step to `next`; false (and no step) when it equals the layers now. Ends a gesture in progress with `next` as its result.
    bool commit(const Layers &next);

    // A gesture: previews change the layers now without a step; commitGesture makes the whole one step (false when nothing
    // changed), cancelGesture puts back what the gesture started from.
    void preview(const Layers &next);
    bool commitGesture();
    void cancelGesture();
    bool inGesture() const { return m_gesture; }
    // The layers the gesture began from (the layers now outside a gesture).
    const Layers &gestureBase() const { return m_gesture ? m_base : m_current; }

    bool canUndo() const { return !m_gesture && !m_undo.isEmpty(); }
    bool canRedo() const { return !m_gesture && !m_redo.isEmpty(); }
    // False when there is nothing to undo (or redo). Both are refused while a gesture is in progress.
    bool undo();
    bool redo();

    int undoSteps() const { return m_undo.size(); }
    int redoSteps() const { return m_redo.size(); }

private:
    void push(const Layers &before);

    Layers m_current;
    Layers m_base; // the layers when the gesture began
    bool m_gesture = false;
    QList<Layers> m_undo;
    QList<Layers> m_redo;
};

} // namespace screenshot
