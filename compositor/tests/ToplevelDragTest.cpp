// A browser tab torn off moves with the pointer (xdg_toplevel_drag_v1, URR-030, ADR-0036 amendment 2026-11-08): the state
// machine behind the plugin's server. Test names state the user-visible rule or the protocol rule.

#include "core/ToplevelDrag.hpp"

#include <gtest/gtest.h>

#include <optional>

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
    ASSERT_TRUE(d.end(EndKind::DropPerformed, true));
    EXPECT_EQ(d.destroy(), Error::None); // after dnd_drop_performed
}

TEST(ToplevelDrag, ADropEndsTheDragAndNamesTheWindowThatFollowed) {
    auto       d   = tornOff(0, 0);
    const auto end = d.end(EndKind::DropPerformed, true);
    ASSERT_TRUE(end);
    EXPECT_EQ(endOf(end).outcome, Outcome::Drop);
    EXPECT_EQ(endOf(end).toplevel, kWindow);
    EXPECT_EQ(d.phase(), Phase::Ended);
    EXPECT_FALSE(d.follows());
    EXPECT_EQ(d.attached(), std::nullopt);
    EXPECT_EQ(d.end(EndKind::Cancelled, false), std::nullopt); // once
    EXPECT_FALSE(d.start());                                   // a source makes one drag
}

TEST(ToplevelDrag, AWindowReleasedOverNothingIsADropNotARevert) {
    // Hyprland cancels a drop no client accepted (the desktop): right after the pointer's release that is still the drop.
    auto       d   = tornOff(0, 0);
    const auto end = d.end(EndKind::Cancelled, true);
    ASSERT_TRUE(end);
    EXPECT_EQ(endOf(end).outcome, Outcome::Drop);
}

TEST(ToplevelDrag, EscapeOrTheClientCancellingOnlyRemovesThePreview) {
    auto       d   = tornOff(0, 0);
    const auto end = d.end(EndKind::Cancelled, false);
    ASSERT_TRUE(end);
    EXPECT_EQ(endOf(end).outcome, Outcome::Cancel);
    EXPECT_EQ(endOf(end).toplevel, kWindow);
}

TEST(ToplevelDrag, ASourceDestroyedDuringTheDragCancels) {
    auto       d   = tornOff(0, 0);
    const auto end = d.end(EndKind::SourceGone, true);
    ASSERT_TRUE(end);
    EXPECT_EQ(endOf(end).outcome, Outcome::Cancel);
}

TEST(ToplevelDrag, AnEndWithoutAMappedWindowNamesNone) {
    CDrag d;
    ASSERT_TRUE(d.start());
    ASSERT_EQ(d.attach(kWindow, false, 0, 0), Error::None); // never mapped
    const auto end = d.end(EndKind::DropPerformed, true);
    ASSERT_TRUE(end);
    EXPECT_EQ(endOf(end).toplevel, std::nullopt);
}

TEST(ToplevelDrag, ASourceCancelledBeforeItsDragBeganEndsQuietly) {
    CDrag d;
    EXPECT_EQ(d.end(EndKind::Cancelled, false), std::nullopt);
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
