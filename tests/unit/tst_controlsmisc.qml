import QtQuick
import QtTest
import Grassfield.Ui

// SegmentedControl, ComboBox, ProgressBar, ScrollBar, Sheet and Slider of Grassfield.Ui on QtQuick.Templates (GF-085).
TestCase {
    id: tc

    name: "ControlsMisc"
    width: 500
    height: 500
    visible: true
    when: windowShown

    property var picks: []
    property int moves: 0
    property int releases: 0
    property int bodiesMade: 0

    Item {
        id: stage
        anchors.fill: parent

        Column {
            spacing: 8

            SegmentedControl {
                id: seg
                model: [{id: "a", text: "Alpha"}, {id: "b", text: "Beta"}, {id: "c", text: "Gamma"}]
                value: "b"
                accessibleName: "Letters"
                onPicked: id => tc.picks.push(id)
            }

            ComboBox {
                id: combo
                model: [{id: "x", text: "Ex"}, {id: "y", text: "Why"}]
                value: "x"
                accessibleName: "Pick"
                onPicked: id => tc.picks.push(id)
            }

            ProgressBar {
                id: bar
                from: 0
                to: 10
                value: 5
                accessibleName: "Copy"
            }

            Slider {
                id: slider
                value: 0.5
                accessibleName: "Level"
                onMoved: v => tc.moves++
                onReleased: tc.releases++
            }

            Item {
                width: 100
                height: 100

                Flickable {
                    id: flick
                    anchors.fill: parent
                    contentWidth: 100
                    contentHeight: 400
                }

                ScrollBar {
                    id: scroll
                    flickable: flick
                    anchors.right: parent.right
                    height: parent.height
                }
            }
        }

        Sheet {
            id: sheet
            title: "Go to"
            withField: true
            confirmHandler: text => text === "bad" ? "No such folder" : ""
        }

        Sheet {
            id: lazySheet
            title: "Lazy"
            bodyComponent: Text {
                text: "body"
                Component.onCompleted: tc.bodiesMade++
            }
        }
    }

    function init() {
        tc.picks = [];
        tc.moves = 0;
        seg.value = "b";
        combo.value = "x";
        sheet.visible = false;
    }

    function test_segmentedKeysReportButDoNotMoveTheValue() {
        seg.forceActiveFocus();
        keyClick(Qt.Key_Right);
        compare(tc.picks, ["c"]);
        compare(seg.value, "b", "the host owns the value");
        keyClick(Qt.Key_Left);
        compare(tc.picks, ["c", "a"]);
        seg.value = "c";
        keyClick(Qt.Key_Right);
        compare(tc.picks.length, 2, "no step past the end");
    }

    function test_segmentedAccessibility() {
        compare(seg.Accessible.role, Accessible.Grouping);
        compare(seg.Accessible.name, "Letters");
        compare(seg.Accessible.description, "Beta");
        compare(seg.currentIndex, 1);
        const row = seg.contentItem;
        const seg0 = row.children[0];
        compare(seg0.Accessible.role, Accessible.RadioButton);
        compare(seg0.Accessible.checked, false);
        compare(row.children[1].Accessible.checked, true);
        seg0.Accessible.pressAction();
        compare(tc.picks, ["a"]);
    }

    function test_accessibilityPressIsGuarded() {
        const seg0 = seg.contentItem.children[0];
        seg.enabled = false;
        seg0.Accessible.pressAction();
        compare(tc.picks, [], "a disabled SegmentedControl never picks on an accessibility press");
        seg0.Accessible.toggleAction();
        compare(tc.picks, [], "nor on a toggle action");
        seg.enabled = true;
        seg.visible = false;
        seg0.Accessible.toggleAction();
        compare(tc.picks, [], "a hidden one ignores toggle too");
        seg0.Accessible.pressAction();
        compare(tc.picks, [], "a hidden one neither");
        seg.visible = true;
        combo.enabled = false;
        combo.Accessible.pressAction();
        verify(!combo.open, "a disabled ComboBox does not open on an accessibility press");
        combo.enabled = true;
        combo.visible = false;
        combo.Accessible.pressAction();
        verify(!combo.open, "a hidden one neither");
        combo.visible = true;
        combo.Accessible.pressAction();
        tryCompare(combo, "open", true);
        combo.popup.close();
        tryCompare(combo, "open", false);
        slider.enabled = false;
        slider.Accessible.increaseAction();
        compare(tc.moves, 0, "a disabled Slider ignores an accessibility increase");
        slider.enabled = true;
        slider.Accessible.increaseAction();
        compare(tc.moves, 1);
    }

    // The macOS rule: a hidden or disabled control cannot act, and hiding or disabling the one that has the focus closes its
    // pop-up and moves the focus on.
    function test_hiddenOrDisabledControlsCannotActAndLoseTheFocus() {
        // SegmentedControl, Slider: handed the focus by code while hidden, their keys do nothing.
        seg.visible = false;
        seg.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Right);
        keyClick(Qt.Key_Left);
        compare(tc.picks, [], "a hidden SegmentedControl ignores the arrows");
        seg.visible = true;
        slider.visible = false;
        slider.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Right);
        keyClick(Qt.Key_Home);
        compare(tc.moves, 0, "a hidden Slider ignores its keys");
        slider.visible = true;
        // Hiding or disabling the focused control moves the focus.
        for (const c of [seg, slider, combo]) {
            for (const state of ["hidden", "disabled"]) {
                c.forceActiveFocus(Qt.TabFocusReason);
                verify(c.activeFocus);
                if (state === "hidden")
                    c.visible = false;
                else
                    c.enabled = false;
                verify(!c.activeFocus, state + ": the focus left " + c);
                c.visible = true;
                c.enabled = true;
            }
        }
        // ComboBox: a list open while the combo is disabled or hidden is closed, never picks, and is not reopened by a key.
        for (const state of ["disabled", "hidden"]) {
            combo.forceActiveFocus(Qt.TabFocusReason);
            keyClick(Qt.Key_Space);
            tryCompare(combo, "open", true);
            const menu = combo.list as PopupMenu;
            if (state === "disabled")
                combo.enabled = false;
            else
                combo.visible = false;
            tryCompare(combo, "open", false);
            menu.activated({id: "y", text: "Why"}, false);
            compare(tc.picks, [], "a " + state + " combo does not pick");
            verify(!combo.activeFocus, "and does not take the focus back");
            combo.enabled = true;
            combo.visible = true;
            verify(!combo.open, "showing it again does not reopen the list");
        }
        // A hidden combo handed the focus by code: its opening keys do nothing.
        combo.visible = false;
        combo.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Return);
        keyClick(Qt.Key_Down);
        verify(!combo.open, "a hidden combo does not open on a key");
        combo.visible = true;
    }

    function test_segmentedClickPicks() {
        const row = seg.contentItem;
        mouseClick(row.children[2]);
        compare(tc.picks, ["c"]);
    }

    function test_comboShowsTheValueAndOpensWithKeys() {
        compare(combo.displayText, "Ex");
        compare(combo.Accessible.role, Accessible.ComboBox);
        combo.forceActiveFocus();
        keyClick(Qt.Key_Down);
        tryCompare(combo, "open", true);
        combo.popup.close();
        tryCompare(combo, "open", false);
        keyClick(Qt.Key_Space);
        tryCompare(combo, "open", true);
        combo.popup.close();
        tryCompare(combo, "open", false);
    }

    function test_comboPickReportsAndKeepsTheHostValue() {
        combo.forceActiveFocus();
        keyClick(Qt.Key_Return);
        tryCompare(combo, "open", true);
        const menu = combo.list as PopupMenu;
        menu.activated({id: "y", text: "Why"}, false);
        compare(tc.picks, ["y"]);
        compare(combo.displayText, "Ex", "shows the host's value until it changes");
        combo.value = "y";
        compare(combo.displayText, "Why");
        tryCompare(combo, "open", false);
    }

    // The open list keeps the size its rows need (a Popup that resizes its content collapsed it to a 10 px strip).
    function test_comboListKeepsItsSizeAndShowsAllRows() {
        combo.model = [{id: "a", text: "Always"}, {id: "b", text: "On Desktop Only"}, {id: "c", text: "In Full Screen Only, a longer label"}, {id: "d", text: "Never"}];
        combo.forceActiveFocus();
        keyClick(Qt.Key_Space);
        tryCompare(combo, "open", true);
        const menu = combo.list;
        const rows = 4 * Tokens.menuItemHeight;
        verify(menu.height >= rows, "menu height " + menu.height + " holds " + rows + " of rows");
        compare(menu.height, combo.popup.height);
        compare(menu.width, combo.popup.width);
        verify(menu.width >= Tokens.menuMinWidth);
        // The last row lies inside the menu.
        const last = menu.mapToItem(menu, 0, menu.height - Tokens.menuPadding - 1);
        verify(last.y < menu.height);
        combo.popup.close();
        tryCompare(combo, "open", false);
        combo.model = [{id: "x", text: "Ex"}, {id: "y", text: "Why"}];
        combo.value = "x";
    }

    // The list stays inside the window: a long label no longer opens it at a negative x.
    function test_comboListStaysInsideTheWindow() {
        combo.model = [{id: "a", text: "A fairly long label that makes the list wider than the button"}, {id: "b", text: "Short"}];
        combo.forceActiveFocus();
        keyClick(Qt.Key_Space);
        tryCompare(combo, "open", true);
        const at = combo.popup.contentItem.mapToItem(null, 0, 0);
        verify(at.x >= Tokens.spacingSm, "left edge " + at.x);
        verify(at.x + combo.popup.width <= tc.width - Tokens.spacingSm + 0.5, "right edge " + (at.x + combo.popup.width));
        verify(at.y >= Tokens.spacingSm);
        combo.popup.close();
        tryCompare(combo, "open", false);
        combo.model = [{id: "x", text: "Ex"}, {id: "y", text: "Why"}];
    }

    // A label wider than the whole window is elided: the list never leaves the window (it did, by 25 px, in a 600 px window).
    function test_comboListWiderThanTheWindowIsElidedInsideIt() {
        const long = "An extremely long label that is by far wider than the window of this test, so that no pop-up could ever show it whole, ending here";
        combo.model = [{id: "a", text: long}, {id: "b", text: "Short"}];
        combo.forceActiveFocus();
        keyClick(Qt.Key_Space);
        tryCompare(combo, "open", true);
        const at = combo.popup.contentItem.mapToItem(null, 0, 0);
        verify(at.x >= Tokens.spacingSm - 0.5, "left edge " + at.x);
        verify(at.x + combo.popup.width <= tc.width - Tokens.spacingSm + 0.5, "right edge " + (at.x + combo.popup.width) + " of " + tc.width);
        const shown = (combo.list as PopupMenu).model[0].text;
        verify(shown.length < long.length && shown.endsWith("\u2026"), "elided: " + shown);
        compare((combo.list as PopupMenu).model[1].text, "Short");
        combo.popup.close();
        tryCompare(combo, "open", false);
        combo.model = [{id: "x", text: "Ex"}, {id: "y", text: "Why"}];
    }

    // In a window smaller than the minimum menu width the list is still inside the window (narrower, scrolling).
    function test_comboListInATinyWindowStaysInside() {
        const win = tc.Window.window;
        const w0 = win.width;
        const h0 = win.height;
        win.width = 120;
        win.height = 90;
        tc.width = 120;   // the test case is the top item of the window here: it does not follow the window by itself
        tc.height = 90;
        wait(150);  // the window resizes its root item on the next turn of the event loop
        combo.model = [{id: "a", text: "Alpha"}, {id: "b", text: "Beta"}, {id: "c", text: "Gamma"}, {id: "d", text: "Delta"}];
        combo.forceActiveFocus();
        keyClick(Qt.Key_Space);
        tryCompare(combo, "open", true);
        const at = combo.popup.contentItem.mapToItem(null, 0, 0);
        verify(at.x >= 0 && at.x + combo.popup.width <= win.width, "inside horizontally: " + at.x + " + " + combo.popup.width + " of " + win.width);
        verify(at.y >= 0 && at.y + combo.popup.height <= win.height, "inside vertically: " + at.y + " + " + combo.popup.height + " of " + win.height);
        verify(combo.popup.height > 0 && combo.popup.width > 0);
        combo.popup.close();
        tryCompare(combo, "open", false);
        win.width = w0;
        win.height = h0;
        tc.width = w0;
        tc.height = h0;
        combo.model = [{id: "x", text: "Ex"}, {id: "y", text: "Why"}];
    }

    // 40 rows do not fit: the list is capped to the window and scrolls (macOS), the keyboard cursor stays in view.
    function test_comboListOf40RowsScrollsInsideTheWindow() {
        const rows = [];
        for (let i = 0; i < 40; i++)
            rows.push({id: "r" + i, text: "Row " + i});
        combo.model = rows;
        combo.value = "r0";
        combo.forceActiveFocus();
        keyClick(Qt.Key_Space);
        tryCompare(combo, "open", true);
        const scroller = combo.popup.contentItem as Flickable;
        verify(combo.list.height > tc.height, "the 40 rows need more than the window: " + combo.list.height);
        verify(combo.popup.height <= tc.height - 2 * Tokens.spacingSm, "popup " + combo.popup.height + " fits the window");
        compare(scroller.contentHeight, combo.list.height);
        verify(scroller.interactive);
        const at = scroller.mapToItem(null, 0, 0);
        verify(at.y >= 0 && at.y + scroller.height <= tc.height, "inside the window vertically");
        keyClick(Qt.Key_End);
        verify(scroller.contentY > 0, "End scrolls to the last row");
        verify(scroller.contentY <= scroller.contentHeight - scroller.height + 0.5);
        keyClick(Qt.Key_Home);
        compare(scroller.contentY, 0);
        combo.popup.close();
        tryCompare(combo, "open", false);
        combo.model = [{id: "x", text: "Ex"}, {id: "y", text: "Why"}];
        combo.value = "x";
    }

    // A keyboard pick gives the focus back with a visible ring; a pointer pick does not show one.
    function test_comboRingSurvivesAKeyboardPick() {
        combo.model = [{id: "x", text: "Ex"}, {id: "y", text: "Why"}];
        combo.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        tryCompare(combo, "open", true);
        keyClick(Qt.Key_Down);
        keyClick(Qt.Key_Return);
        tryCompare(combo, "open", false);
        verify(combo.activeFocus);
        verify(combo.visualFocus, "the ring is kept after a keyboard pick");
        compare(tc.picks[tc.picks.length - 1], "y");
    }

    function test_progressBar() {
        fuzzyCompare(bar.visualPosition, 0.5, 1e-9);
        bar.value = 10;
        // The fill grows to the new value (Behavior on width, UI audit 2026-11-05 LOW).
        tryVerify(() => Math.abs(bar.contentItem.children[0].width - bar.width) <= 1, 1000, "the fill reaches the new value");
        compare(bar.height, Tokens.controlProgressHeight);
        compare(bar.Accessible.name, "Copy");
        bar.indeterminate = true;
        Appearance.reduceMotion = true;
        verify(!bar.sweeping, "no sweep with Reduce Motion");
        Appearance.reduceMotion = false;
        verify(bar.sweeping);
        Appearance.reduceMotion = false;
        bar.indeterminate = false;
        bar.value = 5;
    }

    // A value the host sets while the pointer holds the slider is a late echo: the user's value stays shown until the
    // release, which takes the host's (audit B-06).
    function test_sliderHoldsTheUserValueWhilePressed() {
        mousePress(slider, slider.width - 1, slider.height / 2);
        compare(slider.shown, 1);
        slider.value = 0.2;
        compare(slider.shown, 1, "a late echo does not move a held slider");
        mouseRelease(slider, slider.width - 1, slider.height / 2);
        compare(slider.shown, 0.2, "the release takes the host's value");
        slider.value = 0.5;
        compare(slider.shown, 0.5);
    }

    // A host that throttles its writes writes the last one at the release (settings-portal SP-02).
    function test_sliderReleaseSignal() {
        tc.releases = 0;
        mousePress(slider, slider.width / 2, slider.height / 2);
        compare(tc.releases, 0);
        mouseMove(slider, slider.width - 2, slider.height / 2);
        mouseRelease(slider, slider.width - 2, slider.height / 2);
        compare(tc.releases, 1, "released once, at the release");
        slider.value = 0.5;
    }

    // A sheet's bodyComponent is made the first time it opens, and kept (Settings declares 34 sheets).
    function test_sheetBodyMadeOnFirstShow() {
        compare(tc.bodiesMade, 0, "not made while the sheet was never shown");
        compare(lazySheet.bodyItem, null);
        lazySheet.visible = true;
        tryVerify(() => lazySheet.bodyItem !== null);
        compare(tc.bodiesMade, 1);
        lazySheet.visible = false;
        wait(20);
        verify(lazySheet.bodyItem !== null, "kept when hidden");
        lazySheet.visible = true;
        compare(tc.bodiesMade, 1, "made once");
        lazySheet.visible = false;
    }

    function test_sliderKeysReportAndKeepTheHostValue() {
        slider.forceActiveFocus();
        keyClick(Qt.Key_Right);
        compare(tc.moves, 1);
        keyClick(Qt.Key_Home);
        compare(tc.moves, 2);
        compare(slider.Accessible.role, Accessible.Slider);
        compare(slider.value, 0.5);
    }

    function test_scrollBarFollowsTheView() {
        verify(scroll.visible);
        verify(scroll.size < 1);
        flick.contentY = 150;
        verify(scroll.position > 0);
        compare(scroll.Accessible.role, Accessible.ScrollBar);
        flick.contentHeight = 50;
        verify(!scroll.visible, "nothing to scroll");
        flick.contentHeight = 400;
        flick.contentY = 0;
    }

    // macOS 27 overlay scroll bars (owner report 2026-11-02): nothing over a still view; the thumb shows while the view moves,
    // stays a moment after it stops, then fades out.
    function test_scrollBarHidesWhileTheViewIsStill() {
        verify(scroll.visible);
        flick.contentY = 0;
        const settle = Tokens.controlScrollbarHideDelayMs + Tokens.motionNormal + 2000;
        tryCompare(scroll.contentItem, "opacity", 0, settle, "hidden over a still view");
        flick.flick(0, -1500);
        tryVerify(() => flick.moving && scroll.contentItem.opacity > 0.9, 2000, "shown while the view moves");
        tryCompare(flick, "moving", false, 5000);
        verify(scroll.contentItem.opacity > 0.9, "still shown just after the view stops");
        tryCompare(scroll.contentItem, "opacity", 0, settle, "hidden again once the view is still");
        flick.contentY = 0;
    }

    function test_sheetConfirmErrorKeepsItOpenAndEscapeCancels() {
        sheet.open();
        verify(sheet.visible);
        sheet.setField("bad");
        keyClick(Qt.Key_Return);
        verify(sheet.visible, "an error keeps the sheet open");
        compare(sheet.errorText, "No such folder");
        sheet.setField("good");
        compare(sheet.errorText, "");
        keyClick(Qt.Key_Return);
        verify(!sheet.visible);
        sheet.open();
        keyClick(Qt.Key_Escape);
        verify(!sheet.visible);
    }

    // returnCancels: Return cancels (nothing accepted), the cancel button is the default one and the confirm one is not.
    function test_sheetReturnCancels() {
        let accepted = 0, canceled = 0;
        const onAccepted = () => accepted++;
        const onCanceled = () => canceled++;
        sheet.accepted.connect(onAccepted);
        sheet.canceled.connect(onCanceled);
        sheet.returnCancels = true;
        sheet.open();
        sheet.setField("good");
        keyClick(Qt.Key_Return);
        verify(!sheet.visible);
        compare([accepted, canceled], [0, 1]);
        const buttons = [];
        const walk = item => {
            for (let i = 0; i < item.children.length; ++i) {
                const c = item.children[i];
                if (c.text === "Cancel" || c.text === "OK")
                    buttons.push(c);
                walk(c);
            }
        };
        walk(sheet);
        compare(buttons.find(b => b.text === "Cancel").primary, true);
        compare(buttons.find(b => b.text === "OK").primary, false);
        sheet.returnCancels = false;
        sheet.open();
        keyClick(Qt.Key_Return);
        compare([accepted, canceled], [1, 1]);
        // A destructive sheet: Return still confirms, and the confirm button is the visible default, drawn red (UI audit
        // 2026-11-05 U20); Esc cancels.
        sheet.destructive = true;
        const ok = buttons.find(b => b.text === "OK");
        compare(ok.primary, true, "the destructive confirm is the visible default");
        verify(Qt.colorEqual(ok.background.color, Appearance.colors.destructive), "drawn as the red default");
        sheet.open();
        keyClick(Qt.Key_Escape);
        compare([accepted, canceled], [1, 2]);
        sheet.destructive = false;
        sheet.accepted.disconnect(onAccepted);
        sheet.canceled.disconnect(onCanceled);
    }
}
