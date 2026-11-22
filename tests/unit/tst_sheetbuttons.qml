import QtQuick
import QtTest
import Grassfield.Ui

// Sheets and alerts as macOS 27 draws them (ADR-0039 step 10; docs/audits/design-polish-2026-10-29.md § 3.8, measured on the
// 512 Pixels release captures): a sheet has the window's corner (radius.sheet 17, Q2 (a): the window's 16.7 circle-equivalent, ADR-0024 C-1), an alert a rounder one
// (radius.alert 26, the owner's choice of 2026-10-31); a sheet's buttons are 24-pt rounded rectangles with a 7-pt corner,
// not capsules, the Cancel and default pair one width, 20 from the sheet's right and bottom edges; an alert keeps its 28-pt
// capsules. The shared Sheet is built here, and so is the shell's Dialog (Grassfield.Ui only), in both shapes.
TestCase {
    id: tc

    name: "SheetButtons"
    width: 640
    height: 480
    visible: true
    when: windowShown

    Item {
        id: host
        width: 640
        height: 480

        Sheet {
            id: sheet
            title: "Replace the file?"
            message: "A file with this name already exists."
            confirmText: "Replace"
            extraButtons: [{id: "both", text: "Keep Both"}]
        }
    }

    Component {
        id: buttonComponent
        Button {}
    }

    Component {
        id: dialogButton
        Button {
            text: "Force Quit"
        }
    }

    function cleanup() {
        if (sheet.visible)
            sheet.close();
    }

    // Every Button under `item` (by its own flags, so that no type name is needed).
    function buttonsIn(item) {
        const out = [];
        const stack = [item];
        while (stack.length > 0) {
            const it = stack.shift();
            if (it.sheet !== undefined && it.push !== undefined && it.capsule !== undefined && it.visible)
                out.push(it);
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return out;
    }

    function byText(buttons, text) {
        const found = buttons.filter(b => b.text === text);
        verify(found.length === 1, "one button " + text);
        return found[0];
    }

    // The Material under `item` (the panel's glass).
    function materialIn(item) {
        const stack = [item];
        while (stack.length > 0) {
            const it = stack.shift();
            if (it.glassClass !== undefined && it.radius !== undefined)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function test_theTokens() {
        compare(Tokens.radiusSheet, 17, "a sheet has the window's corner (rounding 17 at power 2.6: 16.7 circle-equivalent)");
        compare(Tokens.radiusAlert, 26, "an alert is rounder, as macOS 27's");
        compare(Tokens.controlSheetButtonRadius, 7);
        compare(Tokens.controlButtonHeight, 24);
        compare(Tokens.controlAlertButtonHeight, 28);
    }

    function test_aSheetButtonIsARoundedRectangle() {
        const b = createTemporaryObject(buttonComponent, tc, {text: "Cancel", sheet: true});
        compare(b.height, Tokens.controlButtonHeight);
        compare(b.background.radius, Tokens.controlSheetButtonRadius, "not a capsule");
        verify(b.background.radius < b.height / 2);
        compare(b.shapeRadius, Tokens.controlSheetButtonRadius, "its focus ring follows the same corner");
        compare(b.implicitWidth, Math.ceil(b.contentItem.implicitWidth + 2 * Tokens.controlPushPadding), "as wide as its label");
        // The other shapes are unchanged: a push button and an alert's are capsules.
        const push = createTemporaryObject(buttonComponent, tc, {text: "Details…", push: true});
        compare(push.background.radius, push.height / 2);
        const alert = createTemporaryObject(buttonComponent, tc, {text: "OK", capsule: true});
        compare(alert.height, Tokens.controlAlertButtonHeight);
        compare(alert.background.radius, alert.height / 2);
    }

    function test_theSharedSheet() {
        sheet.open();
        tryCompare(sheet, "visible", true);
        wait(50);
        const glass = materialIn(sheet);
        verify(glass !== null);
        compare(glass.radius, Tokens.radiusSheet);
        const buttons = buttonsIn(sheet);
        const cancel = byText(buttons, "Cancel");
        const confirm = byText(buttons, "Replace");
        const extra = byText(buttons, "Keep Both");
        for (const b of [cancel, confirm, extra]) {
            verify(b.sheet && !b.push && !b.capsule, b.text + " is a sheet button");
            compare(b.height, Tokens.controlButtonHeight, b.text);
        }
        compare(cancel.width, confirm.width, "the pair has one width");
        compare(confirm.width, Math.max(cancel.implicitWidth, confirm.implicitWidth), "the wider label's");
        compare(extra.width, extra.implicitWidth, "a leading button is as wide as its label");
        compare(confirm.mapToItem(cancel, 0, 0).x, cancel.width + Tokens.spacingSm, "8 apart");
        // 20 from the panel's right and bottom edges (the panel is the glass's parent).
        const panel = glass.parent;
        const corner = confirm.mapToItem(panel, confirm.width, confirm.height);
        compare(panel.width - corner.x, Tokens.panelSheetPadding, "20 from the right edge");
        compare(panel.height - corner.y, Tokens.panelSheetPadding, "20 from the bottom edge");
        compare(Tokens.panelSheetPadding, 20);
    }

    // The pair takes the wider label's width whichever button has it (the review of #88: with "Replace" wider than "Cancel",
    // a pair sized to the default button alone passed).
    function test_thePairTakesTheWiderLabelEitherWay() {
        const was = sheet.confirmText;
        try {
            sheet.confirmText = "OK";
            sheet.open();
            tryCompare(sheet, "visible", true);
            wait(50);
            const buttons = buttonsIn(sheet);
            const cancel = byText(buttons, "Cancel");
            const confirm = byText(buttons, "OK");
            verify(cancel.implicitWidth > confirm.implicitWidth, "Cancel is the wider label here");
            compare(confirm.width, cancel.implicitWidth, "the default button takes Cancel's width");
            compare(cancel.width, cancel.implicitWidth);
        } finally {
            sheet.close();
            sheet.confirmText = was;
        }
    }

    // A sheet never exceeds its window: in a narrow one it narrows to the window less the side margins, its text wraps and its
    // buttons stay whole inside the panel; in a wide one it keeps its width (Get Info's Change All... sheet, rc9 feedback).
    function test_aSheetNeverExceedsItsWindow() {
        const was = host.width;
        const wasMessage = sheet.message;
        try {
            sheet.message = "Do you want to change all documents like this one to open with this application?";
            sheet.open();
            tryCompare(sheet, "visible", true);
            wait(50);
            const glass = materialIn(sheet);
            const panel = glass.parent;
            compare(panel.width, Tokens.controlSheetWidth, "a normal window keeps the sheet's width");
            host.width = 300;
            wait(50);
            compare(panel.width, 300 - 2 * Tokens.spacingLg, "the window less the side margins");
            const origin = panel.mapToItem(host, 0, 0);
            verify(origin.x >= Tokens.spacingLg, "inside the window on the left");
            verify(origin.x + panel.width <= host.width - Tokens.spacingLg, "inside the window on the right");
            const buttons = buttonsIn(sheet);
            for (const b of [byText(buttons, "Cancel"), byText(buttons, "Replace")]) {
                const tl = b.mapToItem(panel, 0, 0);
                verify(tl.x >= 0 && tl.x + b.width <= panel.width, b.text + " is whole inside the panel");
            }
            host.width = 100;
            wait(50);
            const confirm = byText(buttonsIn(sheet), "Replace");
            const c = confirm.mapToItem(panel, 0, 0);
            verify(c.x >= 0 && c.x + confirm.width <= panel.width, "even a tiny window keeps the buttons whole");
        } finally {
            sheet.close();
            host.width = was;
            sheet.message = wasMessage;
        }
    }

    function test_theShellsDialog_data() {
        return [
            {tag: "sheet", sheet: true, radius: Tokens.radiusSheet},
            {tag: "alert", sheet: false, radius: Tokens.radiusAlert}
        ];
    }

    function test_theShellsDialog(data) {
        const component = Qt.createComponent(Qt.resolvedUrl("../../shell/overlay/Dialog.qml"));
        compare(component.status, Component.Ready, component.errorString());
        const dialog = createTemporaryObject(component, tc, {sheet: data.sheet, title: "Force Quit Applications"});
        verify(dialog !== null);
        const cancel = createTemporaryObject(dialogButton, null, {text: "Cancel"});
        const quit = createTemporaryObject(dialogButton, null, {text: "Force Quit", primary: true});
        dialog.buttons = [cancel, quit];
        wait(50);
        compare(dialog.cornerRadius, data.radius);
        compare(dialog.surface.radius, data.radius);
        for (const b of [cancel, quit]) {
            compare(b.sheet, data.sheet, b.text);
            compare(b.capsule, !data.sheet, b.text);
            verify(!b.push, b.text + " is no push capsule");
            compare(b.height, data.sheet ? Tokens.controlButtonHeight : Tokens.controlAlertButtonHeight);
            compare(b.background.radius, data.sheet ? Tokens.controlSheetButtonRadius : b.height / 2);
        }
        compare(cancel.width, quit.width, "one width");
        if (data.sheet) {
            const corner = quit.mapToItem(dialog, quit.width, quit.height);
            compare(dialog.width - corner.x, Tokens.panelSheetPadding, "20 from the right edge");
            compare(dialog.height - corner.y, Tokens.panelSheetPadding, "20 from the bottom edge");
        }
    }

    // UI audit 2026-11-05 U2: alert buttons that do not fit side by side stack full width, the default (last) one on top.
    function test_theShellsAlertStacks() {
        const component = Qt.createComponent(Qt.resolvedUrl("../../shell/overlay/Dialog.qml"));
        compare(component.status, Component.Ready, component.errorString());
        const dialog = createTemporaryObject(component, tc, {title: "Voulez-vous vraiment fermer la session ?"});
        const cancel = createTemporaryObject(dialogButton, null, {text: "Annuler"});
        const quit = createTemporaryObject(dialogButton, null, {text: "Fermer la session maintenant", primary: true});
        dialog.buttons = [cancel, quit];
        wait(50);
        const room = dialog.width - 2 * dialog.pad;
        compare(cancel.width, room, "full width");
        compare(quit.width, room, "full width");
        compare(cancel.x, quit.x, "one column");
        verify(quit.y < cancel.y, "the default button on top");
        const bottom = cancel.mapToItem(dialog, 0, cancel.height).y;
        compare(dialog.height - bottom, dialog.pad, "the stack ends one padding above the bottom edge");
    }
}
