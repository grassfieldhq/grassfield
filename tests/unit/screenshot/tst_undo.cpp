// The undo stack of the editor (slice B3): steps, redo, gestures and the bound.
#include "undostack.h"

#include <gtest/gtest.h>

using namespace screenshot;

namespace {

Layers ids(std::initializer_list<int> list)
{
    Layers layers;
    for (int id : list)
        layers.append(Layer{id, "line", QJsonObject{{"n", id}}});
    return layers;
}

QList<int> idsOf(const Layers &layers)
{
    QList<int> out;
    for (const Layer &layer : layers)
        out.append(layer.id);
    return out;
}

} // namespace

TEST(Undo, UndoAndRedoWalkTheSteps)
{
    UndoStack stack;
    EXPECT_FALSE(stack.canUndo());
    EXPECT_FALSE(stack.canRedo());
    EXPECT_TRUE(stack.commit(ids({1})));
    EXPECT_TRUE(stack.commit(ids({1, 2})));
    EXPECT_TRUE(stack.commit(ids({1, 2, 3})));
    ASSERT_TRUE(stack.canUndo());

    EXPECT_TRUE(stack.undo());
    EXPECT_EQ(idsOf(stack.layers()), (QList<int>{1, 2}));
    EXPECT_TRUE(stack.undo());
    EXPECT_TRUE(stack.undo());
    EXPECT_TRUE(stack.layers().isEmpty());
    EXPECT_FALSE(stack.undo()) << "nothing left to undo";

    EXPECT_TRUE(stack.redo());
    EXPECT_EQ(idsOf(stack.layers()), (QList<int>{1}));
    EXPECT_TRUE(stack.redo());
    EXPECT_TRUE(stack.redo());
    EXPECT_EQ(idsOf(stack.layers()), (QList<int>{1, 2, 3}));
    EXPECT_FALSE(stack.redo());
}

TEST(Undo, ANewStepClearsRedo)
{
    UndoStack stack;
    stack.commit(ids({1}));
    stack.commit(ids({1, 2}));
    stack.undo();
    ASSERT_TRUE(stack.canRedo());
    stack.commit(ids({1, 9}));
    EXPECT_FALSE(stack.canRedo());
    EXPECT_EQ(idsOf(stack.layers()), (QList<int>{1, 9}));
}

TEST(Undo, AnUnchangedCommitIsNoStep)
{
    UndoStack stack;
    stack.reset(ids({1}));
    EXPECT_FALSE(stack.commit(ids({1})));
    EXPECT_EQ(stack.undoSteps(), 0);
}

TEST(Undo, AGestureIsOneStep)
{
    UndoStack stack;
    stack.reset(ids({1}));
    stack.preview(ids({1, 2}));
    stack.preview(ids({1, 2, 3}));
    EXPECT_TRUE(stack.inGesture());
    EXPECT_EQ(idsOf(stack.layers()), (QList<int>{1, 2, 3})) << "the view follows the previews";
    EXPECT_FALSE(stack.canUndo()) << "no undo in the middle of a drag";
    EXPECT_FALSE(stack.undo());
    EXPECT_TRUE(stack.commitGesture());
    EXPECT_EQ(stack.undoSteps(), 1);
    EXPECT_TRUE(stack.undo());
    EXPECT_EQ(idsOf(stack.layers()), (QList<int>{1})) << "one undo takes the whole drag back";
    EXPECT_TRUE(stack.redo());
    EXPECT_EQ(idsOf(stack.layers()), (QList<int>{1, 2, 3}));
}

TEST(Undo, ACancelledOrUnchangedGestureIsNoStep)
{
    UndoStack stack;
    stack.reset(ids({1}));
    stack.preview(ids({1, 2}));
    stack.cancelGesture();
    EXPECT_EQ(idsOf(stack.layers()), (QList<int>{1}));
    EXPECT_FALSE(stack.inGesture());
    EXPECT_EQ(stack.undoSteps(), 0);

    stack.preview(ids({1, 2}));
    stack.preview(ids({1})); // dragged back to where it began
    EXPECT_FALSE(stack.commitGesture());
    EXPECT_EQ(stack.undoSteps(), 0);
}

TEST(Undo, TheStackIsBounded)
{
    UndoStack stack;
    Layers layers;
    for (int i = 1; i <= kMaxUndoSteps + 25; ++i) {
        layers.append(Layer{i, "line", {}});
        ASSERT_TRUE(stack.commit(layers));
    }
    EXPECT_EQ(stack.undoSteps(), kMaxUndoSteps);
    int undone = 0;
    while (stack.undo())
        ++undone;
    EXPECT_EQ(undone, kMaxUndoSteps);
    EXPECT_EQ(stack.layers().size(), 25) << "the oldest steps are the ones forgotten";
}

TEST(Undo, ResetForgetsEverything)
{
    UndoStack stack;
    stack.commit(ids({1}));
    stack.preview(ids({1, 2}));
    stack.reset(ids({7}));
    EXPECT_FALSE(stack.inGesture());
    EXPECT_FALSE(stack.canUndo());
    EXPECT_FALSE(stack.canRedo());
    EXPECT_EQ(idsOf(stack.layers()), (QList<int>{7}));
}
