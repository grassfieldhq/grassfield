import QtQuick
import QtTest
import Grassfield.Ui

// The PopupMenu component driven by real key events (navigation model is in tst_menunav).
TestCase {
    id: testCase
    name: "PopupMenu"
    width: 400
    height: 400
    // Shown, so that pointer events reach the menus (a TestCase item starts hidden).
    visible: true
    when: windowShown

    Component {
        id: menuComponent
        PopupMenu {
            model: [
                {id: "a", text: "Alpha", shortcut: "Ctrl+A"},
                {separator: true},
                {id: "b", text: "Beta", enabled: false},
                {id: "c", text: "Gamma"},
                {id: "d", text: "Delta", submenu: [{id: "d1", text: "Delta one"}, {id: "d2", text: "Delta two"}]}
            ]
        }
    }

    Component {
        id: swatchMenuComponent
        PopupMenu {
            model: [
                {id: "open", text: "Open"},
                {id: "tags", swatches: [{id: "tag:0", color: Tokens.filesTagRed, name: "Red", state: 2}, {id: "tag:1", color: Tokens.filesTagOrange, name: "Orange", state: 1},
                        {id: "tag:2", color: Tokens.filesTagYellow, name: "Yellow", state: 0}], accessibleName: "Tags"},
                {id: "notags", swatches: [{id: "tag:0", color: Tokens.filesTagRed, name: "Red", state: 0}], enabled: false, caption: "This volume can’t store tags."},
                {id: "copy", text: "Copy"}
            ]
        }
    }

    // Window > Move & Resize (docs/specs/tiling.md TL25): headed sections, glyph rows and Alt alternates, in a submenu.
    Component {
        id: tilingMenuComponent
        PopupMenu {
            model: [
                {id: "fill", text: "Fill", glyph: {zones: [[0, 0, 12, 12]], own: 0}},
                {id: "move", text: "Move & Resize", submenu: [
                        {header: true, text: "Arrange"},
                        {id: "arrange", layout: "left-right", text: "Left & Right", glyph: {zones: [[0, 0, 6, 12], [6, 0, 6, 12]], own: 0},
                            alternate: {id: "arrange", layout: "left-quarters", text: "Left & Quarters", glyph: {zones: [[0, 0, 6, 12], [6, 0, 6, 6], [6, 6, 6, 6]], own: 0}}},
                        {id: "arrange", layout: "quarters", text: "Quarters"}
                    ]},
                {id: "plain", text: "Plain", alternate: {id: "other", text: "Other"}}
            ]
        }
    }

    Component {
        id: itemComponent
        MenuItem {
            width: 300
        }
    }

    SignalSpy {
        id: activatedSpy
        signalName: "activated"
    }

    SignalSpy {
        id: closeSpy
        signalName: "closeRequested"
    }

    function makeMenu() {
        const m = createTemporaryObject(menuComponent, testCase);
        m.forceActiveFocus();
        activatedSpy.target = m;
        activatedSpy.clear();
        closeSpy.target = m;
        closeSpy.clear();
        return m;
    }

    function test_sizing() {
        const m = makeMenu();
        verify(m.width >= Tokens.menuMinWidth);
        verify(m.height > 0);
    }

    function textItem(root: Item, text: string): var {
        for (const child of root.children) {
            if (child.text === text)
                return child;
            const found = textItem(child, text);
            if (found)
                return found;
        }
        return null;
    }

    // Shortcuts form a right-aligned column whatever the label's length (docs/specs/ui.md), as on macOS.
    function test_shortcutsAlignRight() {
        const short = createTemporaryObject(itemComponent, testCase, {text: "Open", shortcut: "Ctrl+O"});
        const long = createTemporaryObject(itemComponent, testCase, {text: "Glance at “Report.pdf”", shortcut: "Space"});
        for (const row of [short, long]) {
            const hint = textItem(row, row.shortcut);
            verify(hint !== null);
            fuzzyCompare(hint.mapToItem(row, hint.width, 0).x, row.width - Tokens.menuItemPadding, 0.5);
        }
    }

    // macOS 27 menu layout (ADR-0024): the label sits menuItemPadding inside the row; a section that holds a checkable row
    // moves its labels after the check column; an icon moves only its own row; the highlight is concentric with the menu.
    Component {
        id: layoutMenuComponent
        PopupMenu {
            model: [
                {id: "a", text: "Plain"},
                {id: "b", text: "With icon", iconName: "lock"},
                {separator: true},
                {id: "c", text: "Checked", checked: true},
                {id: "d", text: "Unchecked", checked: false},
                {separator: true},
                {id: "e", text: "After"}
            ]
        }
    }

    Component {
        id: plainMenuComponent
        PopupMenu {
            model: [{id: "a", text: "One"}, {separator: true}, {id: "b", text: "Two"}]
        }
    }

    function test_labelsFollowTheirRowAndSection() {
        const m = createTemporaryObject(layoutMenuComponent, testCase);
        wait(0);
        // The label Text of a row (a MenuItem carries the same `text`, so look for the QQuickText itself).
        const label = (root, name) => {
            for (const child of root.children) {
                if (String(child).indexOf("QQuickText") === 0 && child.text === name)
                    return child;
                const found = label(child, name);
                if (found)
                    return found;
            }
            return null;
        };
        const left = name => {
            const t = label(m, name);
            verify(t !== null, name);
            return t.mapToItem(m, 0, 0).x;
        };
        // Capture defect 9: the check hangs in a leading column the whole menu keeps, so every label lines up with the checked one.
        compare(left("Plain"), Tokens.menuPadding + Tokens.menuCheckInset, "a menu with a checkable row keeps the column for every row");
        compare(left("With icon"), Tokens.menuPadding + Tokens.menuCheckInset + Tokens.menuIconSize + Tokens.spacingSm);
        compare(left("Checked"), Tokens.menuPadding + Tokens.menuCheckInset);
        compare(left("Unchecked"), Tokens.menuPadding + Tokens.menuCheckInset, "the checked and unchecked rows align");
        compare(left("After"), Tokens.menuPadding + Tokens.menuCheckInset, "the next section aligns too");
        const plain = createTemporaryObject(plainMenuComponent, testCase);
        wait(0);
        compare(plain.checkColumns.some(c => c), false, "a menu without a checkable row has no column");
        verify(Math.abs(m.width - Math.round(m.width)) < 1e-9, "whole-pixel width " + m.width);
    }

    Component {
        id: headerMenuComponent
        PopupMenu {
            model: [{header: true, text: "A section header much wider than any row below it"}, {id: "a", text: "A", checked: true}]
        }
    }

    // Review NIT 6: a header after the check column keeps its right padding (its width counted the plain inset only).
    function test_aHeaderKeepsItsRightPaddingAfterTheCheckColumn() {
        const m = createTemporaryObject(headerMenuComponent, testCase);
        wait(50);
        const find = root => {
            for (const child of root.children) {
                if (String(child).indexOf("QQuickText") === 0 && child.text.indexOf("A section header") === 0)
                    return child;
                const found = find(child);
                if (found)
                    return found;
            }
            return null;
        };
        const t = find(m);
        verify(t !== null);
        const right = t.mapToItem(m, t.width, 0).x;
        verify(right <= m.width - Tokens.menuPadding - Tokens.menuItemPadding + 0.5, "right edge " + right + " in a menu " + m.width + " wide");
    }

    // One section header for every menu (ADR-0039 step 8, G17): MenuHeader, PopupMenu's `header` rows and the shell's
    // hand-built menus (the sound menu, the tiling popover) alike: a row tall, the caption size in bold, the secondary colour,
    // at the leading edge of the rows below it, after the check column when the menu keeps one.
    Component {
        id: headedMenuComponent
        PopupMenu {
            model: [{header: true, text: "Section"}, {id: "a", text: "Checked row", checked: true}, {id: "b", text: "Plain row"}]
        }
    }

    Component {
        id: headedPlainMenuComponent
        PopupMenu {
            model: [{header: true, text: "Section"}, {id: "a", text: "Plain row"}]
        }
    }

    function quickText(root, text) {
        for (const child of root.children) {
            if (String(child).indexOf("QQuickText") === 0 && child.text === text)
                return child;
            const found = quickText(child, text);
            if (found)
                return found;
        }
        return null;
    }

    function test_aHeaderStartsWithTheLabelsBelowIt_data() {
        return [
            {tag: "after the check column", component: headedMenuComponent, x: Tokens.menuCheckInset},
            {tag: "at the plain inset", component: headedPlainMenuComponent, x: Tokens.menuItemPadding}
        ];
    }

    function test_aHeaderStartsWithTheLabelsBelowIt(data) {
        const m = createTemporaryObject(data.component, testCase);
        wait(0);
        const header = quickText(m, "Section");
        const label = quickText(m, "Plain row");
        verify(header !== null && label !== null);
        compare(header.mapToItem(m, 0, 0).x, Tokens.menuPadding + data.x);
        compare(header.mapToItem(m, 0, 0).x, label.mapToItem(m, 0, 0).x, "the header starts with the labels");
        compare(header.parent.height, Tokens.menuItemHeight, "a row tall");
        compare(header.font.pixelSize, Tokens.typographyCaptionSize);
        compare(header.font.weight, Tokens.typographyMenuBoldWeight);
        verify(Qt.colorEqual(header.color, Appearance.colors.textSecondary));
        compare(header.parent.Accessible.role, Accessible.Heading);
    }

    Component {
        id: headerComponent
        MenuHeader {
            width: 200
        }
    }

    // A hand-built menu's header (the sound menu's Output) is the same one.
    function test_aMenuHeaderStandsAlone() {
        const plain = createTemporaryObject(headerComponent, testCase, {text: "Output"});
        const checked = createTemporaryObject(headerComponent, testCase, {text: "Output", checkColumn: true});
        compare(quickText(plain, "Output").x, Tokens.menuItemPadding);
        compare(quickText(checked, "Output").x, Tokens.menuCheckInset);
        compare(plain.implicitHeight, Tokens.menuItemHeight);
        compare(checked.implicitWidth, Math.ceil(Tokens.menuCheckInset + quickText(checked, "Output").implicitWidth + Tokens.menuItemPadding));
    }

    function test_highlightIsConcentricWithTheMenu() {
        const row = createTemporaryObject(itemComponent, testCase, {text: "Open", highlighted: true});
        let fill = null;
        for (const child of row.children) {
            if (String(child).indexOf("QQuickRectangle") === 0 && child.visible)
                fill = child;
        }
        verify(fill !== null);
        compare(fill.radius, Tokens.radiusMenu - Tokens.menuPadding);
        compare(fill.color, Qt.color(Appearance.colors.selection));
    }

    function test_downSkipsDisabledAndSeparator() {
        const m = makeMenu();
        keyClick(Qt.Key_Down);
        compare(m.currentIndex, 0);
        keyClick(Qt.Key_Down);
        compare(m.currentIndex, 3);
    }

    function test_returnActivatesCurrent() {
        const m = makeMenu();
        keyClick(Qt.Key_Down);
        keyClick(Qt.Key_Return);
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "a");
        compare(activatedSpy.signalArguments[0][1], false, "chosen by the keyboard");
    }

    // How a row was chosen reaches the host (ADR-0039 step 8): a popup opened for it shows its ring after a key only.
    function test_aClickIsThePointers() {
        const m = makeMenu();
        wait(50);
        const p = centreOf(m, "Gamma");
        const local = m.mapFromItem(null, p.x, p.y);
        mouseClick(m, local.x, local.y);
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "c");
        compare(activatedSpy.signalArguments[0][1], true, "chosen by the pointer");
    }

    function test_escapeRequestsClose() {
        makeMenu();
        keyClick(Qt.Key_Escape);
        compare(closeSpy.count, 1);
    }

    function test_disabledNeverActivates() {
        const m = makeMenu();
        m.currentIndex = 2;
        keyClick(Qt.Key_Return);
        compare(activatedSpy.count, 0);
    }

    function test_submenuOpensAndActivates() {
        const m = makeMenu();
        keyClick(Qt.Key_Up);
        compare(m.currentIndex, 4);
        compare(m.extent.width, m.width);
        keyClick(Qt.Key_Right);
        compare(m.openIndex, 4);
        wait(100);
        // A host sized by extent (the desktop's PopupWindow) includes the submenu, which opens to the right.
        const sub = m.submenuItem;
        compare(m.extent.width, sub.mapToItem(m, sub.width, 0).x);
        verify(m.extent.width > m.width);
        verify(m.extent.height >= m.height);
        keyClick(Qt.Key_Down);
        keyClick(Qt.Key_Return);
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "d2");
        compare(activatedSpy.signalArguments[0][1], false, "the submenu passes the keyboard on");
    }

    // Swatch rows (Files colour tags): the keyboard reaches the row, Left/Right pick a swatch, Return activates the
    // swatch itself; a disabled row is skipped and shows its reason; a click on a swatch activates it.
    function test_swatchRowKeyboard() {
        const m = createTemporaryObject(swatchMenuComponent, testCase);
        m.forceActiveFocus();
        activatedSpy.target = m;
        activatedSpy.clear();
        keyClick(Qt.Key_Down);
        keyClick(Qt.Key_Down);
        compare(m.currentIndex, 1);
        compare(m.swatchIndex, 0);
        keyClick(Qt.Key_Right);
        keyClick(Qt.Key_Right);
        compare(m.swatchIndex, 2);
        keyClick(Qt.Key_Right);
        compare(m.swatchIndex, 0, "wraps");
        keyClick(Qt.Key_Left);
        compare(m.swatchIndex, 2);
        keyClick(Qt.Key_Return);
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "tag:2");
        compare(activatedSpy.signalArguments[0][1], false);
        // Down skips the disabled row.
        keyClick(Qt.Key_Down);
        compare(m.currentIndex, 3);
    }

    function test_swatchRowPointer() {
        const m = createTemporaryObject(swatchMenuComponent, testCase);
        activatedSpy.target = m;
        activatedSpy.clear();
        waitForRendering(m);
        // The second swatch of the tags row (row 1, under the one-line "Open" row): menu padding, the row's padding and
        // the ring around each swatch.
        const step = Tokens.menuSwatchSize + 2 * Tokens.menuSwatchRing + Tokens.menuSwatchGap;
        const p = Qt.point(Tokens.menuPadding + Tokens.menuItemPadding + step + Tokens.menuSwatchRing + Tokens.menuSwatchSize / 2,
                           Tokens.menuPadding + Tokens.menuItemHeight + Tokens.spacingXs + Tokens.menuSwatchRing + Tokens.menuSwatchSize / 2);
        mouseMove(m, p.x - 1, p.y);
        mouseMove(m, p.x, p.y);
        compare(m.currentIndex, 1);
        compare(m.swatchIndex, 1);
        mouseClick(m, p.x, p.y);
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "tag:1");
        compare(activatedSpy.signalArguments[0][1], true);
    }

    // ---- pointer relay: press, drag, release with the pointer held by another surface (the menu bar) ----

    // Centre of the row showing `text`, in scene coordinates (what the menu bar reports).
    function centreOf(root: Item, text: string): point {
        const row = textItem(root, text);
        verify(row !== null, "no row " + text);
        return row.mapToItem(null, row.width / 2, row.height / 2);
    }

    function test_relayRowAt() {
        const m = makeMenu();
        wait(50);
        compare(m.rowAt(centreOf(m, "Alpha").x, centreOf(m, "Alpha").y), 0);
        compare(m.rowAt(centreOf(m, "Gamma").x, centreOf(m, "Gamma").y), 3);
        compare(m.rowAt(centreOf(m, "Delta").x, centreOf(m, "Delta").y), 4);
        // A disabled row, the separator and the outside are no row.
        compare(m.rowAt(centreOf(m, "Beta").x, centreOf(m, "Beta").y), -1);
        const sep = centreOf(m, "Alpha");
        compare(m.rowAt(sep.x, sep.y + (centreOf(m, "Beta").y - sep.y) / 2), -1);
        compare(m.rowAt(-50, -50), -1);
        compare(m.rowAt(m.mapToItem(null, 0, 0).x + m.width + 40, sep.y), -1);
        verify(m.containsPoint(sep.x, sep.y));
        verify(!m.containsPoint(-50, -50));
    }

    function test_relayTrackHighlightsTheRowUnderThePointer() {
        const m = makeMenu();
        wait(50);
        m.trackPointer(centreOf(m, "Gamma").x, centreOf(m, "Gamma").y);
        compare(m.currentIndex, 3);
        m.trackPointer(centreOf(m, "Alpha").x, centreOf(m, "Alpha").y);
        compare(m.currentIndex, 0);
        // A disabled row and the outside clear the highlight (the pointer is on no row), nothing runs.
        m.trackPointer(centreOf(m, "Beta").x, centreOf(m, "Beta").y);
        compare(m.currentIndex, -1);
        m.trackPointer(centreOf(m, "Gamma").x, centreOf(m, "Gamma").y);
        m.trackPointer(-30, -30);
        compare(m.currentIndex, -1);
        compare(activatedSpy.count, 0);
    }

    function test_relayReleaseRunsTheRowUnderThePointer() {
        const m = makeMenu();
        wait(50);
        const p = centreOf(m, "Gamma");
        m.trackPointer(p.x, p.y);
        verify(m.releasePointer(p.x, p.y));
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "c");
        compare(activatedSpy.signalArguments[0][1], true, "a release over the row is the pointer's");
        compare(closeSpy.count, 0);
    }

    function test_relayReleaseOutsideARowLeavesTheMenuOpen() {
        const m = makeMenu();
        wait(50);
        const beta = centreOf(m, "Beta");
        verify(!m.releasePointer(beta.x, beta.y));
        verify(!m.releasePointer(-20, -20));
        // Back on the bar title (above the menu): nothing either.
        verify(!m.releasePointer(m.mapToItem(null, 0, 0).x + 5, m.mapToItem(null, 0, 0).y - 10));
        compare(activatedSpy.count, 0);
        compare(closeSpy.count, 0);
    }

    function test_relaySubmenuRowOpensItAndRunsItsRows() {
        const m = makeMenu();
        wait(50);
        const d = centreOf(m, "Delta");
        m.trackPointer(d.x, d.y);
        compare(m.openIndex, 4);
        wait(100);
        const sub = m.submenuItem;
        verify(sub !== null);
        const one = centreOf(sub, "Delta one");
        verify(m.containsPoint(one.x, one.y));
        // The pointer moves into the submenu: its row is highlighted, the parent keeps the open row.
        m.trackPointer(one.x, one.y);
        compare(sub.currentIndex, 0);
        compare(m.currentIndex, 4);
        compare(m.openIndex, 4);
        const two = centreOf(sub, "Delta two");
        m.trackPointer(two.x, two.y);
        compare(sub.currentIndex, 1);
        // Released on a submenu row: that row runs.
        verify(m.releasePointer(two.x, two.y));
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "d2");
        compare(activatedSpy.signalArguments[0][1], true, "the submenu passes the pointer on");
    }

    function test_relayReleaseOnASubmenuRowKeepsTheMenuOpen() {
        const m = makeMenu();
        wait(50);
        const d = centreOf(m, "Delta");
        m.trackPointer(d.x, d.y);
        wait(100);
        verify(m.releasePointer(d.x, d.y));
        compare(activatedSpy.count, 0);
        compare(m.openIndex, 4);
        compare(closeSpy.count, 0);
    }

    function test_relayMovingToAPlainRowClosesTheSubmenu() {
        const m = makeMenu();
        wait(50);
        const d = centreOf(m, "Delta");
        m.trackPointer(d.x, d.y);
        compare(m.openIndex, 4);
        const g = centreOf(m, "Gamma");
        m.trackPointer(g.x, g.y);
        compare(m.openIndex, -1);
        compare(m.currentIndex, 3);
    }

    function test_leftClosesSubmenu() {
        const m = makeMenu();
        keyClick(Qt.Key_Up);
        keyClick(Qt.Key_Right);
        wait(100);
        keyClick(Qt.Key_Left);
        compare(m.openIndex, -1);
        compare(closeSpy.count, 0);
    }

    // Option (Alt) variants (macOS Dock menu): the menu reports whether Alt is down, live, and nothing else changes.
    function test_altHeldFollowsTheKey() {
        const m = makeMenu();
        verify(!m.altHeld);
        keyClick(Qt.Key_Down);
        keyPress(Qt.Key_Alt, Qt.AltModifier);
        verify(m.altHeld);
        compare(m.currentIndex, 0);
        compare(activatedSpy.count, 0);
        compare(closeSpy.count, 0);
        keyRelease(Qt.Key_Alt, Qt.NoModifier);
        verify(!m.altHeld);
    }

    function test_altHeldReachesTheTopMenuFromASubmenu() {
        const m = makeMenu();
        keyClick(Qt.Key_Up);
        keyClick(Qt.Key_Right);
        wait(100);
        verify(m.openIndex >= 0);
        keyPress(Qt.Key_Alt, Qt.AltModifier);
        verify(m.altHeld);
        keyRelease(Qt.Key_Alt, Qt.NoModifier);
        verify(!m.altHeld);
    }

    function makeTilingMenu() {
        const m = createTemporaryObject(tilingMenuComponent, testCase);
        m.forceActiveFocus();
        activatedSpy.target = m;
        activatedSpy.clear();
        return m;
    }

    // Alt shows each row's alternate in place and runs it; the rows come back on release (macOS Option alternates, M28).
    function test_alternatesWhileAltIsHeld() {
        const m = makeTilingMenu();
        compare(m.displayModel[2].id, "plain");
        keyPress(Qt.Key_Alt, Qt.AltModifier);
        compare(m.displayModel[2].id, "other");
        compare(m.displayModel[0].id, "fill", "a row without an alternate stays");
        keyClick(Qt.Key_Up, Qt.AltModifier);
        keyClick(Qt.Key_Return, Qt.AltModifier);
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "other");
        keyRelease(Qt.Key_Alt, Qt.NoModifier);
        compare(m.displayModel[2].id, "plain");
    }

    // A submenu opened by the pointer has no keyboard: it follows the Alt of the menu that opened it. Its header is skipped by
    // the keys and its first row is selected.
    function test_submenuFollowsTheParentsAltAndSkipsItsHeader() {
        const m = makeTilingMenu();
        m.openSubmenuAt(1, false, false);
        wait(50);
        const sub = m.submenuItem;
        verify(sub !== null);
        compare(sub.displayModel[1].layout, "left-right");
        m.altHeld = true;
        compare(sub.displayModel[1].layout, "left-quarters");
        compare(sub.displayModel[2].layout, "quarters");
        m.altHeld = false;
        compare(sub.displayModel[1].layout, "left-right");
        sub.forceActiveFocus();
        keyClick(Qt.Key_Down);
        compare(sub.currentIndex, 1, "the header is skipped");
        keyPress(Qt.Key_Alt, Qt.AltModifier);
        keyClick(Qt.Key_Return, Qt.AltModifier);
        keyRelease(Qt.Key_Alt, Qt.NoModifier);
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].layout, "left-quarters");
    }

    // A glyph row shifts its label like an icon row; a header row is text only.
    function test_glyphAndHeaderRows() {
        const m = makeTilingMenu();
        const glyphRow = createTemporaryObject(itemComponent, testCase, {text: "Fill", glyph: {zones: [[0, 0, 12, 12]], own: 0}});
        const plainRow = createTemporaryObject(itemComponent, testCase, {text: "Fill"});
        compare(glyphRow.labelX, plainRow.labelX + Tokens.menuIconSize + Tokens.spacingSm);
        verify(m.width >= Tokens.menuMinWidth);
    }

    SignalSpy {
        id: stepSpy
        signalName: "menuStepRequested"
    }

    // GF-002 (audit): Right and Left in an open bar menu ask the bar for the next or previous title, also with the host's
    // `bounds` set (the overlay sets it on every menu) and with no row selected (a menu opened with the pointer).
    function test_rightAndLeftStepTheBarMenus() {
        const m = makeMenu();
        m.bounds = testCase;
        m.currentIndex = -1;
        stepSpy.target = m;
        stepSpy.clear();
        keyClick(Qt.Key_Right);
        compare(stepSpy.count, 1);
        compare(stepSpy.signalArguments[0][0], 1);
        keyClick(Qt.Key_Left);
        compare(stepSpy.count, 2);
        compare(stepSpy.signalArguments[1][0], -1);
    }

    // macOS: no row is highlighted when a menu opens, and a submenu opened by the pointer has none either, until the pointer
    // or a key selects one (a submenu opened with Right or Return highlights its first row).
    function test_noHighlightUntilSelected() {
        const m = makeMenu();
        compare(m.currentIndex, -1);
        wait(50);
        const d = centreOf(m, "Delta");
        m.trackPointer(d.x, d.y);
        compare(m.openIndex, 4);
        wait(100);
        compare(m.submenuItem.currentIndex, -1);
        m.closeSubmenu();
        m.currentIndex = 4;
        keyClick(Qt.Key_Right);
        wait(100);
        compare(m.submenuItem.currentIndex, 0);
    }

    // An item's name in a row (Files' and the desktop's item menus: Compress “name”, Glance at “name”) is drawn shortened in
    // its middle to menu.nameMaxWidth, its start, its end and the words around it kept, so that a long file name leaves the
    // menu at its usual width (owner report 2026-11-07: the menu grew to menu.maxWidth). The accessible name keeps it whole.
    Component {
        id: namedMenuComponent
        PopupMenu {
            property string itemName: ""
            model: [
                {id: "open", text: "Open"},
                {id: "compress", text: "Compress “%1”", name: itemName},
                {id: "glance", text: "Glance at “%1”", name: itemName, shortcut: "Space"}
            ]
        }
    }

    function rowsOf(root: Item): var {
        const out = [];
        const stack = [root];
        while (stack.length) {
            const it = stack.pop();
            if (it.shownText !== undefined && it.hasSubmenu !== undefined)
                out.push(it);
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return out;
    }

    function test_aLongNameIsShortenedInTheMiddleAndTheMenuKeepsItsWidth() {
        const longName = "Quarterly report of the regional office, final version approved by everyone 2026-11-07.pdf";
        const shortMenu = createTemporaryObject(namedMenuComponent, testCase, {itemName: "Report.pdf"});
        const longMenu = createTemporaryObject(namedMenuComponent, testCase, {itemName: longName});
        wait(0);
        const glance = rowsOf(longMenu).filter(r => r.text === "Glance at “%1”")[0];
        verify(glance !== undefined);
        const shown = glance.shownText;
        verify(shown.startsWith("Glance at “Quarterly"), "the start of the name: " + shown);
        verify(shown.endsWith(".pdf”"), "its end and the closing quote: " + shown);
        verify(shown.indexOf("…") > 0, "shortened in its middle: " + shown);
        compare(glance.Accessible.name, "Glance at “" + longName + "”", "the accessible name is whole");
        const metrics = Qt.createQmlObject("import QtQuick; FontMetrics {}", testCase);
        metrics.font = glance.children.filter(c => c.text === shown && c.truncated !== undefined)[0].font;
        const name = shown.substring("Glance at “".length, shown.length - 1);
        verify(metrics.advanceWidth(name) <= Tokens.menuNameMaxWidth + 0.5, "the name within menu.nameMaxWidth: " + metrics.advanceWidth(name));
        verify(longMenu.width < Tokens.menuMaxWidth, "the menu stays below its cap: " + longMenu.width);
        verify(longMenu.width - shortMenu.width <= Tokens.menuNameMaxWidth, "and no wider than a row with the longest name drawn");
        const whole = rowsOf(shortMenu).filter(r => r.text === "Compress “%1”")[0];
        compare(whole.shownText, "Compress “Report.pdf”", "a short name is drawn whole");
        metrics.destroy();
    }

    // A row longer than the cap (a label without a name: a recent file, a tray label) still stops the menu at menu.maxWidth and
    // is shortened in its middle (UI audit 2026-11-05 U10).
    function test_aLongLabelStopsTheMenuAtItsCap() {
        const m = createTemporaryObject(namedMenuComponent, testCase);
        m.model = [{id: "a", text: "An extremely long tray label that is much wider than any menu should ever be, ending here"}];
        wait(0);
        compare(m.width, Tokens.menuMaxWidth);
        let label = null;
        const stack = [m];
        while (stack.length && !label) {
            const it = stack.pop();
            if (it.text === m.model[0].text && it.truncated !== undefined)
                label = it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        verify(label !== null);
        compare(label.elide, Text.ElideMiddle);
        verify(label.truncated, "the label is shortened");
    }
}
