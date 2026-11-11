// A browser tab torn off moves with the pointer (xdg_toplevel_drag_v1, URR-030, ADR-0036 amendment 2026-11-08): the state
// machine behind the plugin's server. Test names state the user-visible rule or the protocol rule.

#include "core/ToplevelDrag.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <optional>
#include <vector>

namespace {
    using gf::toplevelDrag::CDrag;
    using gf::toplevelDrag::CSources;
    using gf::toplevelDrag::EndKind;
    using gf::toplevelDrag::Error;
    using gf::toplevelDrag::Outcome;
    using gf::toplevelDrag::Phase;
    using gf::toplevelDrag::Point;

    // The value after an ASSERT_TRUE on it (clang-tidy's optional check does not read gtest's assertions).
    gf::toplevelDrag::Step stepOf(const std::optional<gf::toplevelDrag::Step>& s) {
        return s.value_or(gf::toplevelDrag::Step{});
    }
    gf::toplevelDrag::End endOf(const std::optional<gf::toplevelDrag::End>& e) {
        return e.value_or(gf::toplevelDrag::End{});
    }

    constexpr gf::toplevelDrag::Id kWindow = 0x1000; // a toplevel
    constexpr gf::toplevelDrag::Id kOther  = 0x2000; // another toplevel

    // A drag begun (start_drag seen) with a toplevel attached before it maps, as Chromium does for a torn-off tab.
    CDrag tornOff(int32_t x, int32_t y) {
        CDrag d;
        EXPECT_TRUE(d.start());
        EXPECT_EQ(d.attach(kWindow, false, x, y), Error::None);
        d.mapped(kWindow);
        return d;
    }
} // namespace

TEST(ToplevelDrag, ANewObjectWaitsForItsDragAndMovesNothing) {
    CDrag d;
    EXPECT_EQ(d.phase(), Phase::Waiting);
    EXPECT_EQ(d.attach(kWindow, true, 0, 0), Error::None);
    EXPECT_FALSE(d.follows()); // attached before start_drag: nothing moves until the drag runs
    EXPECT_EQ(d.step(Point{100, 100}, Point{0, 0}), std::nullopt);
}

TEST(ToplevelDrag, AToplevelMappedWhileAttachedSitsUnderThePointerAtTheClientsOffset) {
    auto d = tornOff(40, 12); // the tab's point in the new window
    ASSERT_TRUE(d.follows());
    const auto s = d.step(Point{500, 300}, Point{0, 0}); // wherever Hyprland placed it at the map
    ASSERT_TRUE(s);
    EXPECT_EQ(stepOf(s).topLeft, (Point{460, 288}));
    EXPECT_TRUE(stepOf(s).first);
    const auto next = d.step(Point{510, 330}, stepOf(s).topLeft);
    ASSERT_TRUE(next);
    EXPECT_EQ(stepOf(next).topLeft, (Point{470, 318}));
    EXPECT_FALSE(stepOf(next).first);
}

TEST(ToplevelDrag, AWindowAlreadyMappedWhenAttachedDoesNotJump) {
    CDrag d;
    ASSERT_TRUE(d.start());
    EXPECT_EQ(d.attach(kWindow, true, 999, 999), Error::None); // the offset is only a hint for an unmapped window
    const auto s = d.step(Point{300, 200}, Point{250, 180});
    ASSERT_TRUE(s);
    EXPECT_EQ(stepOf(s).topLeft, (Point{250, 180})); // the grab is measured where the pointer holds it
    const auto next = d.step(Point{320, 260}, stepOf(s).topLeft);
    ASSERT_TRUE(next);
    EXPECT_EQ(stepOf(next).topLeft, (Point{270, 240}));
}

TEST(ToplevelDrag, AWindowHeldAtTheAttachKeepsThatGrabWholeDrag) {
    // Dragging a window's only tab: the window is attached at the press, before start_drag; the pointer then moves before the
    // first step reaches the plugin. The grab is the one of the press, so the window moves by the pointer's whole delta.
    CDrag d;
    ASSERT_EQ(d.attach(kWindow, true, 0, 0), Error::None);
    d.holdAt(Point{300, 350}, Point{100, 200});
    ASSERT_TRUE(d.start());
    const auto s = d.step(Point{310, 357}, Point{100, 200});
    ASSERT_TRUE(s);
    EXPECT_EQ(stepOf(s).topLeft, (Point{110, 207}));
    d.holdAt(Point{0, 0}, Point{0, 0}); // measured already: kept
    const auto end = d.step(Point{500, 500}, stepOf(s).topLeft);
    ASSERT_TRUE(end);
    EXPECT_EQ(stepOf(end).topLeft, (Point{300, 350}));
}

TEST(ToplevelDrag, AHoldIsOnlyForAMappedAttachedWindow) {
    CDrag d;
    d.holdAt(Point{300, 350}, Point{100, 200}); // nothing attached
    ASSERT_TRUE(d.start());
    ASSERT_EQ(d.attach(kWindow, false, 40, 12), Error::None);
    d.holdAt(Point{300, 350}, Point{100, 200}); // not mapped: the client's offset stays
    d.mapped(kWindow);
    const auto s = d.step(Point{500, 300}, Point{0, 0});
    ASSERT_TRUE(s);
    EXPECT_EQ(stepOf(s).topLeft, (Point{460, 288}));
}

TEST(ToplevelDrag, ARegrabKeepsTheNewPlaceUnderThePointer) {
    CDrag d;
    ASSERT_TRUE(d.start());
    ASSERT_EQ(d.attach(kWindow, true, 0, 0), Error::None);
    ASSERT_TRUE(d.step(Point{300, 200}, Point{0, 0}));
    d.regrab(Point{300, 200}, Point{200, 190}); // a tiled window back at its size from before under the pointer (TL16)
    const auto s = d.step(Point{310, 210}, Point{200, 190});
    ASSERT_TRUE(s);
    EXPECT_EQ(stepOf(s).topLeft, (Point{210, 200}));
}

TEST(ToplevelDrag, AttachingWhileAToplevelIsAttachedIsAProtocolError) {
    CDrag d;
    ASSERT_EQ(d.attach(kWindow, false, 0, 0), Error::None);
    EXPECT_EQ(d.attach(kOther, false, 0, 0), Error::ToplevelAttached);
    EXPECT_EQ(d.attach(kWindow, false, 0, 0), Error::ToplevelAttached); // the same toplevel again too
    EXPECT_EQ(d.attached(), kWindow);
}

TEST(ToplevelDrag, AnUnmappedToplevelIsDetachedAndCanBeAttachedAgainOnceItMaps) {
    auto d = tornOff(10, 10);
    EXPECT_FALSE(d.unmapped(kOther)); // another window: nothing
    EXPECT_TRUE(d.unmapped(kWindow)); // Chromium hides the window when the tab joins another strip
    EXPECT_FALSE(d.follows());
    EXPECT_EQ(d.attached(), std::nullopt);
    EXPECT_EQ(d.step(Point{1, 1}, Point{0, 0}), std::nullopt);
    // Pulled out again: attach again (no error) and it follows once mapped.
    EXPECT_EQ(d.attach(kWindow, false, 20, 5), Error::None);
    EXPECT_FALSE(d.follows());
    d.mapped(kWindow);
    const auto s = d.step(Point{100, 100}, Point{0, 0});
    ASSERT_TRUE(s);
    EXPECT_EQ(stepOf(s).topLeft, (Point{80, 95}));
    EXPECT_TRUE(stepOf(s).first);
}

TEST(ToplevelDrag, ADestroyedRoleDetachesItsToplevel) {
    auto d = tornOff(0, 0);
    EXPECT_TRUE(d.gone(kWindow));
    EXPECT_FALSE(d.follows());
    EXPECT_EQ(d.attach(kOther, false, 0, 0), Error::None);
}

TEST(ToplevelDrag, AMapOfAnotherToplevelChangesNothing) {
    CDrag d;
    ASSERT_TRUE(d.start());
    ASSERT_EQ(d.attach(kWindow, false, 0, 0), Error::None);
    d.mapped(kOther);
    EXPECT_FALSE(d.follows());
}

TEST(ToplevelDrag, DestroyingTheObjectDuringItsDragIsAProtocolError) {
    CDrag d;
    EXPECT_EQ(d.destroy(), Error::None); // before start_drag: accepted
    ASSERT_TRUE(d.start());
    EXPECT_EQ(d.destroy(), Error::OngoingDrag);
    ASSERT_TRUE(d.end(EndKind::DropPerformed));
    EXPECT_EQ(d.destroy(), Error::None); // after dnd_drop_performed
}

TEST(ToplevelDrag, ADropEndsTheDragAndNamesTheWindowThatFollowed) {
    auto       d   = tornOff(0, 0);
    const auto end = d.end(EndKind::DropPerformed);
    ASSERT_TRUE(end);
    EXPECT_EQ(endOf(end).outcome, Outcome::Drop);
    EXPECT_EQ(endOf(end).toplevel, kWindow);
    EXPECT_EQ(d.phase(), Phase::Ended);
    EXPECT_FALSE(d.follows());
    EXPECT_EQ(d.attached(), std::nullopt);
    EXPECT_EQ(d.end(EndKind::Cancelled), std::nullopt); // once
    EXPECT_FALSE(d.start());                                   // a source makes one drag
}

TEST(ToplevelDrag, AWindowReleasedOverNothingIsADropNotARevert) {
    // Hyprland cancels a drop no client accepted (the desktop) inside its handling of the release: the release placed the
    // window as a drop already, and the cancel that follows is still the drop's.
    auto       d       = tornOff(0, 0);
    const auto release = d.release();
    ASSERT_TRUE(release);
    EXPECT_EQ(endOf(release).outcome, Outcome::Drop);
    EXPECT_EQ(endOf(release).toplevel, kWindow);
    const auto end = d.end(EndKind::Cancelled);
    ASSERT_TRUE(end);
    EXPECT_EQ(endOf(end).outcome, Outcome::Drop);
    EXPECT_EQ(endOf(end).toplevel, std::nullopt); // placed at the release, not twice
}

TEST(ToplevelDrag, TheReleaseEndsTheWindowsDragWhenTheTargetFinishesLate) {
    // Review of aa8211de: Hyprland 0.56.2 sends dnd_drop_performed only when the target calls wl_data_offer.finish. The window
    // is placed at the release and follows no more meanwhile; the protocol's drag still runs until that event.
    auto       d       = tornOff(40, 12);
    const auto step    = d.step(Point{500, 300}, Point{0, 0});
    const auto release = d.release();
    ASSERT_TRUE(step);
    ASSERT_TRUE(release);
    EXPECT_EQ(endOf(release).outcome, Outcome::Drop);
    EXPECT_EQ(endOf(release).toplevel, kWindow);
    EXPECT_TRUE(d.released());
    EXPECT_FALSE(d.follows());
    EXPECT_EQ(d.step(Point{900, 700}, stepOf(step).topLeft), std::nullopt); // the pointer moves on, the window stays
    EXPECT_EQ(d.phase(), Phase::Dragging);
    EXPECT_EQ(d.destroy(), Error::OngoingDrag); // the drag has not ended for the protocol yet
    const auto end = d.end(EndKind::DropPerformed);  // the target finished at last
    ASSERT_TRUE(end);
    EXPECT_EQ(endOf(end).outcome, Outcome::Drop);
    EXPECT_EQ(endOf(end).toplevel, std::nullopt);
    EXPECT_EQ(d.destroy(), Error::None);
}

TEST(ToplevelDrag, ATargetThatNeverFinishesLeavesTheWindowWhereItWasReleased) {
    auto d = tornOff(0, 0);
    ASSERT_TRUE(d.release());
    for (int i = 0; i < 5; ++i)
        EXPECT_EQ(d.step(Point{100.0 * i, 50.0 * i}, Point{0, 0}), std::nullopt);
    EXPECT_FALSE(d.follows());
    EXPECT_EQ(d.phase(), Phase::Dragging);
}

TEST(ToplevelDrag, ATargetCancellingAfterTheReleaseIsStillADrop) {
    // The release is kept until the drag ends, not for one event loop pass: a target that aborts later does not turn the drop
    // into a cancel.
    auto d = tornOff(0, 0);
    ASSERT_TRUE(d.release());
    const auto end = d.end(EndKind::Cancelled);
    ASSERT_TRUE(end);
    EXPECT_EQ(endOf(end).outcome, Outcome::Drop);
}

TEST(ToplevelDrag, AReleasedWindowStaysOutOfTheTargetUntilTheDragEnds) {
    // Counter-review of 2dcae1f2: after the release Hyprland keeps the drag until the target finishes; the window, still
    // attached, never becomes the target (no enter for its own drag), though it no longer moves.
    auto d = tornOff(0, 0);
    EXPECT_TRUE(d.excludes());
    ASSERT_TRUE(d.release());
    EXPECT_FALSE(d.follows());
    EXPECT_TRUE(d.excludes());
    ASSERT_TRUE(d.end(EndKind::DropPerformed));
    EXPECT_FALSE(d.excludes()); // the drag ended: Hyprland's own target choice again
}

TEST(ToplevelDrag, AnUnmappedOrUnattachedWindowIsNotExcluded) {
    CDrag d;
    ASSERT_TRUE(d.start());
    EXPECT_FALSE(d.excludes()); // nothing attached
    ASSERT_EQ(d.attach(kWindow, false, 0, 0), Error::None);
    EXPECT_FALSE(d.excludes()); // not mapped: Hyprland cannot pick it anyway
    d.mapped(kWindow);
    ASSERT_TRUE(d.release());
    EXPECT_TRUE(d.excludes());
    EXPECT_TRUE(d.unmapped(kWindow)); // the tab joined a strip after the release
    EXPECT_FALSE(d.excludes());
}

TEST(ToplevelDrag, ADroppedSourceGetsItsDropBeforeHyprlandsCancel) {
    // Integrator nested run of 000240ef (T9): Hyprland cancelled a drop nobody accepted without dnd_drop_performed, and
    // Chromium put the tab back as after Escape.
    auto d = tornOff(0, 0);
    ASSERT_TRUE(d.release());
    EXPECT_TRUE(d.dropBeforeCancel());
    EXPECT_FALSE(d.dropBeforeCancel()); // once
    const auto end = d.end(EndKind::Cancelled);
    ASSERT_TRUE(end);
    EXPECT_EQ(endOf(end).outcome, Outcome::Drop);
}

TEST(ToplevelDrag, EscapeGetsNoDrop) {
    auto d = tornOff(0, 0);
    EXPECT_FALSE(d.dropBeforeCancel()); // no release: the cancel stays a cancel, the client reverts
}

TEST(ToplevelDrag, HyprlandsOwnDropNeedsNoSecond) {
    auto d = tornOff(0, 0);
    ASSERT_TRUE(d.release());
    ASSERT_TRUE(d.end(EndKind::DropPerformed)); // a target that received and finished
    EXPECT_FALSE(d.dropBeforeCancel());
}

TEST(ToplevelDrag, AReleaseWithoutAWindowStillDrops) {
    // A tab moved within its strip (nothing attached): its release is a drop too, never a revert.
    CDrag d;
    ASSERT_TRUE(d.start());
    ASSERT_TRUE(d.release());
    EXPECT_TRUE(d.dropBeforeCancel());
}

TEST(ToplevelDrag, OneReleasePerDrag) {
    auto d = tornOff(0, 0);
    ASSERT_TRUE(d.release());
    EXPECT_EQ(d.release(), std::nullopt);
}

TEST(ToplevelDrag, AReleaseWithoutAFollowingWindowPlacesNothing) {
    CDrag d;
    EXPECT_EQ(d.release(), std::nullopt); // before start_drag: nothing
    ASSERT_TRUE(d.start());
    ASSERT_EQ(d.attach(kWindow, false, 0, 0), Error::None); // never mapped
    const auto release = d.release();
    ASSERT_TRUE(release);
    EXPECT_EQ(endOf(release).toplevel, std::nullopt);
    d.mapped(kWindow); // mapped after the release: it never follows
    EXPECT_FALSE(d.follows());
}

TEST(ToplevelDrag, EscapeOrTheClientCancellingOnlyRemovesThePreview) {
    auto       d   = tornOff(0, 0);
    const auto end = d.end(EndKind::Cancelled);
    ASSERT_TRUE(end);
    EXPECT_EQ(endOf(end).outcome, Outcome::Cancel);
    EXPECT_EQ(endOf(end).toplevel, kWindow);
}

TEST(ToplevelDrag, ASourceDestroyedDuringTheDragCancels) {
    auto       d   = tornOff(0, 0);
    const auto end = d.end(EndKind::SourceGone);
    ASSERT_TRUE(end);
    EXPECT_EQ(endOf(end).outcome, Outcome::Cancel);
}

TEST(ToplevelDrag, AnEndWithoutAMappedWindowNamesNone) {
    CDrag d;
    ASSERT_TRUE(d.start());
    ASSERT_EQ(d.attach(kWindow, false, 0, 0), Error::None); // never mapped
    const auto end = d.end(EndKind::DropPerformed);
    ASSERT_TRUE(end);
    EXPECT_EQ(endOf(end).toplevel, std::nullopt);
}

TEST(ToplevelDrag, ASourceCancelledBeforeItsDragBeganEndsQuietly) {
    CDrag d;
    EXPECT_EQ(d.end(EndKind::Cancelled), std::nullopt);
    EXPECT_EQ(d.phase(), Phase::Ended);
    EXPECT_FALSE(d.start());
}

TEST(ToplevelDrag, OutcomesFollowTheRelease) {
    using gf::toplevelDrag::outcomeOf;
    EXPECT_EQ(outcomeOf(EndKind::DropPerformed, false), Outcome::Drop);
    EXPECT_EQ(outcomeOf(EndKind::DropPerformed, true), Outcome::Drop);
    EXPECT_EQ(outcomeOf(EndKind::Cancelled, true), Outcome::Drop);
    EXPECT_EQ(outcomeOf(EndKind::Cancelled, false), Outcome::Cancel);
    EXPECT_EQ(outcomeOf(EndKind::SourceGone, true), Outcome::Cancel);
    EXPECT_EQ(outcomeOf(EndKind::SourceGone, false), Outcome::Cancel);
}

namespace {
    using gf::toplevelDrag::Target;
    using gf::toplevelDrag::TargetKind;

    // A scene as Hyprland's hit tester sees it: windows from the top of the stack, floating ones admitted only with
    // ALLOW_FLOATING (CViewHitTester::windowAt), layers by level.
    struct SFakeWindow {
        gf::toplevelDrag::Id id       = 0;
        bool                 floating = true;
        bool                 surface  = true; // a surface under the pointer (else its border)
    };
    class CFakeScene : public gf::toplevelDrag::ITargetScene {
      public:
        std::vector<SFakeWindow> stack; // top first
        bool                     popup = false;
        std::vector<TargetKind>  layers;
        bool                     honoursIgnore = true; // false: a windowAt path that returns the ignored window anyway

        bool                     layerPopup() override {
            return popup;
        }
        bool layer(TargetKind level) override {
            return std::ranges::find(layers, level) != layers.end();
        }
        std::optional<gf::toplevelDrag::Id> window(uint16_t properties, gf::toplevelDrag::Id ignore) override {
            for (const auto& w : stack) {
                if ((honoursIgnore && w.id == ignore) || (w.floating && !(properties & gf::toplevelDrag::kAllowFloating)))
                    continue;
                return w.id;
            }
            return std::nullopt;
        }
        bool windowSurface(gf::toplevelDrag::Id window) override {
            return std::ranges::any_of(stack, [window](const SFakeWindow& w) { return w.id == window && w.surface; });
        }
    };
} // namespace

TEST(ToplevelDragTarget, TheFloatingWindowUnderTheDraggedOneIsTheTarget) {
    // Integrator nested run of 3ae753c2: every Grassfield window floats; a lookup without ALLOW_FLOATING went through to the
    // wallpaper, and the tab could never drop back into a strip.
    CFakeScene scene;
    scene.stack  = {SFakeWindow{.id = kWindow}, SFakeWindow{.id = kOther}};
    scene.layers = {TargetKind::Background};
    EXPECT_EQ(gf::toplevelDrag::pickTarget(scene, kWindow), (Target{.kind = TargetKind::Window, .window = kOther}));
    EXPECT_NE(gf::toplevelDrag::kTargetWindowProperties & gf::toplevelDrag::kAllowFloating, 0U);
    EXPECT_EQ(gf::toplevelDrag::kTargetWindowProperties, 0x113U) << "CInputManager::mouseMoveUnified's own lookup (0x6b9729)";
}

TEST(ToplevelDragTarget, TheDraggedWindowIsNeverTheTarget) {
    CFakeScene scene;
    scene.stack  = {SFakeWindow{.id = kWindow}};
    scene.layers = {TargetKind::Background};
    EXPECT_EQ(gf::toplevelDrag::pickTarget(scene, kWindow), (Target{.kind = TargetKind::Background, .window = std::nullopt}));
}

TEST(ToplevelDragTarget, ALookupThatReturnsTheDraggedWindowCountsAsNoWindow) {
    // Delta review of 000240ef: should a windowAt path ignore the exclusion, the dragged window still never becomes the target;
    // the layers below are looked at as when no window is there.
    CFakeScene scene;
    scene.honoursIgnore = false;
    scene.stack         = {SFakeWindow{.id = kWindow}, SFakeWindow{.id = kOther}};
    scene.layers        = {TargetKind::Background};
    EXPECT_EQ(gf::toplevelDrag::pickTarget(scene, kWindow), (Target{.kind = TargetKind::Background, .window = std::nullopt}));
}

TEST(ToplevelDragTarget, LayersAboveWindowsComeFirstAndThoseBelowLast) {
    CFakeScene scene;
    scene.stack  = {SFakeWindow{.id = kOther}};
    scene.layers = {TargetKind::Top, TargetKind::Bottom};
    EXPECT_EQ(gf::toplevelDrag::pickTarget(scene, kWindow).kind, TargetKind::Top);
    scene.popup = true;
    EXPECT_EQ(gf::toplevelDrag::pickTarget(scene, kWindow).kind, TargetKind::LayerPopup);
    scene.popup  = false;
    scene.layers = {TargetKind::Bottom, TargetKind::Background};
    EXPECT_EQ(gf::toplevelDrag::pickTarget(scene, kWindow).kind, TargetKind::Window);
    scene.stack.clear();
    EXPECT_EQ(gf::toplevelDrag::pickTarget(scene, kWindow).kind, TargetKind::Bottom);
    scene.layers.clear();
    EXPECT_EQ(gf::toplevelDrag::pickTarget(scene, kWindow), Target{});
}

TEST(ToplevelDragTarget, AWindowsBorderIsNoTargetAndHidesTheLayersBelow) {
    CFakeScene scene;
    scene.stack  = {SFakeWindow{.id = kOther, .floating = true, .surface = false}};
    scene.layers = {TargetKind::Background};
    EXPECT_EQ(gf::toplevelDrag::pickTarget(scene, kWindow), (Target{.kind = TargetKind::WindowBorder, .window = kOther}));
}

TEST(ToplevelDragFollow, AWindowMovedAwayFromThePointerGoesBackALimitedNumberOfTimes) {
    // Integrator nested run of 1c576658: Chromium's torn window was moved 116 px up after its map; it goes back under the
    // pointer at its next commit, without fighting whoever moves it for ever.
    using gf::toplevelDrag::kMaxCorrectionsBetweenMotions;
    using gf::toplevelDrag::needsCorrection;
    EXPECT_TRUE(needsCorrection(Point{433, 502}, Point{433, 386}, 0));
    EXPECT_FALSE(needsCorrection(Point{433, 502}, Point{433.4, 502.3}, 0)); // where it was put: nothing to do
    EXPECT_TRUE(needsCorrection(Point{433, 502}, Point{433, 386}, kMaxCorrectionsBetweenMotions - 1));
    EXPECT_FALSE(needsCorrection(Point{433, 502}, Point{433, 386}, kMaxCorrectionsBetweenMotions)); // the next motion decides
}

TEST(ToplevelDragMisuse, InvalidSourceGoesOnlyToTheObjectsOwnLiveManager) {
    using gf::toplevelDrag::misuseRaisable;
    constexpr gf::toplevelDrag::Id kClientA = 0xA0, kClientB = 0xB0;
    EXPECT_TRUE(misuseRaisable(kClientA, kClientA, kClientA));
    EXPECT_TRUE(misuseRaisable(kClientA, kClientA, std::nullopt)); // the source destroyed since: the object's client decides
    EXPECT_FALSE(misuseRaisable(std::nullopt, kClientA, kClientA)); // the manager destroyed: nothing to raise it on
    // Client A's manager gone and its address reused by client B's: A's misuse never disconnects B.
    EXPECT_FALSE(misuseRaisable(kClientB, kClientA, kClientA));
    EXPECT_FALSE(misuseRaisable(kClientA, kClientA, kClientB));
}

TEST(ToplevelDragSources, ASourceTakesOneLiveObject) {
    CSources s;
    EXPECT_TRUE(s.empty());
    EXPECT_EQ(s.add(1, 10), Error::None);
    EXPECT_EQ(s.add(1, 11), Error::InvalidSource);
    EXPECT_EQ(s.objectOf(1), 10U);
    EXPECT_EQ(s.add(2, 11), Error::None);
    s.removeObject(10); // the object destroyed: the source may get another one
    EXPECT_EQ(s.objectOf(1), std::nullopt);
    EXPECT_EQ(s.add(1, 12), Error::None);
    s.removeSource(2);
    EXPECT_EQ(s.objectOf(2), std::nullopt);
    s.removeSource(1);
    EXPECT_TRUE(s.empty());
}
