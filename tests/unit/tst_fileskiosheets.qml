pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"
import "../../apps/files/qml/KioSheetsLogic.js" as KioSheetsLogic

// KIO's questions in Files as sheets (apps/files/qml/KioSheets.qml, KioSheetsLogic.js; ADR-0035 D-12 a,
// docs/specs/system-dialogs.md section 9): the macOS texts and buttons for each kind, and the replies the sheet sends
// (FilesApp.prompts.reply) for the buttons, Return, Esc, "Apply to All", "Show Certificate" and "Always trust"; a question
// withdrawn while shown; a kind this version doesn't know. The C++ side, with real KIO jobs, is
// tests/unit/files/tst_kiodialogs.cpp; the window that shows a question, tests/unit/tst_filesbrowser.qml.
TestCase {
    id: test
    name: "FilesKioSheets"
    when: windowShown
    width: 640
    height: 480
    visible: true

    // FilesApp.prompts: the question on screen, the ones waiting behind it (shown at once after a reply, as KioPrompts does),
    // and the replies the sheet sent.
    QtObject {
        id: fakePrompts
        property var current: ({})
        property var waiting: []
        property var replies: []
        function reply(id: int, answer: var): void {
            fakePrompts.replies = fakePrompts.replies.concat([{
                    id: id,
                    button: answer.button,
                    applyToAll: answer.applyToAll,
                    alwaysTrust: answer.alwaysTrust
                }]);
            const next = fakePrompts.waiting.length > 0 ? fakePrompts.waiting[0] : ({});
            fakePrompts.waiting = fakePrompts.waiting.slice(1);
            fakePrompts.current = next;
        }
    }

    Component {
        id: sheetsComponent
        Item {
            property alias sheets: sheets
            width: test.width
            height: test.height
            KioSheets {
                id: sheets
                prompts: fakePrompts
                shown: true
            }
        }
    }

    function init(): void {
        fakePrompts.current = ({});
        fakePrompts.waiting = [];
        fakePrompts.replies = [];
    }

    function make(): var {
        const host = createTemporaryObject(sheetsComponent, test);
        verify(host !== null, "KioSheets.qml");
        return host.sheets;
    }

    // The visible item under `root` whose `text` is `text` (a button, a check box), or null.
    function find(root: var, text: string): var {
        const walk = item => {
            if (!item || !item.visible)
                return null;
            if (item.text === text && (item.clicked !== undefined || item.toggled !== undefined))
                return item;
            for (let i = 0; i < item.children.length; i++) {
                const found = walk(item.children[i]);
                if (found)
                    return found;
            }
            return null;
        };
        return walk(root);
    }

    // Clicks the visible control `text` of `sheet` once the sheet has laid it out (a sheet just opened, or a part just shown,
    // is placed on the next polish).
    function click(sheet: var, text: string): void {
        verify(waitForPolish(sheet.Window.window, 1000), "the sheet is laid out");
        const item = test.find(sheet, text);
        verify(item !== null, text);
        mouseClick(item);
    }

    // The sheet is shown and takes input (KioSheets holds it for the double-click interval after a question changes).
    function shown(sheet: var): void {
        tryVerify(() => sheet.visible, 1000, "the sheet shows");
        tryVerify(() => !sheet.holdInput, 2000, "the sheet takes input");
    }

    function sheetOf(sheets: var): var {
        for (let i = 0; i < sheets.children.length; i++) {
            if (sheets.children[i] instanceof Sheet)
                return sheets.children[i];
        }
        return null;
    }

    function conflict(extra: var): var {
        return Object.assign({
            id: 7,
            kind: "conflict",
            name: "Report.pdf",
            folder: "Documents",
            mode: "copy",
            merge: false,
            replace: true,
            keepBoth: true,
            skip: false,
            applyToAll: false
        }, extra);
    }

    // --- texts and buttons (KioSheetsLogic.js) ---------------------------------------------------------------------------

    function test_conflictTexts(): void {
        let s = KioSheetsLogic.sheet(test.conflict({}));
        compare(s.title, "An item named “Report.pdf” already exists in this location.");
        compare(s.message, "Do you want to replace it with the one you’re copying?");
        compare(s.confirmText, "Replace");
        compare(s.cancelText, "Stop");
        compare(s.extras.map(e => e.id), ["keepBoth"]);
        compare(s.applyToAll, false);

        // Finder names the older or newer item.
        s = KioSheetsLogic.sheet(test.conflict({
            mode: "move",
            srcModified: new Date(2026, 9, 2),
            destModified: new Date(2026, 9, 1)
        }));
        compare(s.title, "An older item named “Report.pdf” already exists in this location.");
        compare(s.message, "Do you want to replace it with the newer one you’re moving?");
        s = KioSheetsLogic.sheet(test.conflict({
            srcModified: new Date(2026, 9, 1),
            destModified: new Date(2026, 9, 2)
        }));
        compare(s.title, "A newer item named “Report.pdf” already exists in this location.");
        compare(s.message, "Do you want to replace it with the older one you’re copying?");

        // Several items: Skip and Apply to All; a folder onto a folder merges.
        s = KioSheetsLogic.sheet(test.conflict({
            skip: true,
            applyToAll: true,
            merge: true,
            name: "Photos"
        }));
        compare(s.title, "A folder named “Photos” already exists in this location.");
        compare(s.confirmText, "Merge");
        compare(s.extras.map(e => e.id), ["keepBoth", "skip"]);
        compare(s.applyToAll, true);

        // No Replace (the item itself): Keep Both is the default.
        s = KioSheetsLogic.sheet(test.conflict({
            replace: false
        }));
        compare(s.confirmId, "keepBoth");
        compare(s.extras, []);
    }

    function test_otherKinds(): void {
        let s = KioSheetsLogic.sheet({
            id: 1,
            kind: "skip",
            text: "Access denied",
            retry: true,
            rename: false,
            skip: true,
            applyToAll: true
        });
        compare(s.title, "The operation can’t be completed.");
        compare(s.message, "Access denied");
        compare([s.confirmId, s.cancelId], ["retry", "stop"]);
        compare(s.extras.map(e => e.id), ["skip"]);
        // One item: no Skip (KIO's SkipDialog); one that can't be retried has OK only, which stops.
        s = KioSheetsLogic.sheet({
            id: 11,
            kind: "skip",
            text: "Access denied",
            retry: true,
            rename: false,
            skip: false,
            applyToAll: false
        });
        compare(s.extras, []);
        s = KioSheetsLogic.sheet({
            id: 12,
            kind: "skip",
            text: "Access denied",
            retry: false,
            rename: false,
            skip: false,
            applyToAll: false
        });
        compare([s.confirmText, s.confirmId, s.showCancel], ["OK", "stop", false]);

        s = KioSheetsLogic.sheet({
            id: 2,
            kind: "delete",
            type: "emptyTrash",
            count: 3,
            name: "a"
        });
        compare(s.title, "Are you sure you want to permanently erase the items in the Trash?");
        compare(s.confirmText, "Empty Trash");
        verify(s.destructive);
        s = KioSheetsLogic.sheet({
            id: 3,
            kind: "delete",
            type: "delete",
            count: 1,
            name: "a.txt"
        });
        compare(s.title, "Are you sure you want to delete “a.txt”?");
        compare(s.message, "You can’t undo this action.");

        // A two-action question without Cancel: Esc gives the secondary action (KMessageBox).
        s = KioSheetsLogic.sheet({
            id: 4,
            kind: "message",
            title: "",
            text: "Overwrite?",
            details: "",
            primary: "Yes",
            secondary: "No",
            cancel: false,
            okOnly: false,
            warning: false
        });
        compare([s.title, s.message, s.confirmText, s.cancelText, s.cancelId], ["Overwrite?", "", "Yes", "No", "secondary"]);
        s = KioSheetsLogic.sheet({
            id: 5,
            kind: "message",
            title: "Server",
            text: "Save it?",
            details: "more",
            primary: "Save",
            secondary: "Discard",
            cancel: true,
            okOnly: false,
            warning: true
        });
        compare(s.extras.map(e => e.id), ["secondary", "details"]);
        compare(s.cancelId, "cancel");
        verify(s.destructive);
        s = KioSheetsLogic.sheet({
            id: 6,
            kind: "message",
            title: "",
            text: "Done",
            details: "",
            primary: "",
            secondary: "",
            cancel: false,
            okOnly: true,
            warning: false
        });
        compare([s.confirmText, s.confirmId, s.showCancel], ["OK", "ok", false]);

        s = KioSheetsLogic.sheet({
            id: 8,
            kind: "certificate",
            host: "files.example.org",
            error: "expired",
            chain: []
        });
        compare(s.title, "Files can’t verify the identity of the server “files.example.org”.");
        verify(s.returnCancels, "Cancel is the default");
        compare(s.extras.map(e => e.id), ["certificate"]);

        compare(KioSheetsLogic.sheet({}), null);
        compare(KioSheetsLogic.sheet({
            id: 9,
            kind: "future"
        }), null);
    }

    function test_chainLines(): void {
        const lines = KioSheetsLogic.chainLines([{
                readable: true,
                subject: "files.example.org",
                issuer: "Example CA",
                validFrom: "a",
                validUntil: "b",
                sha256: "AB:CD",
                problems: ["The certificate has expired"]
            }, {
                readable: false,
                problems: []
            }], d => "<" + d + ">");
        compare(lines, ["files.example.org", "Issued by: Example CA", "Valid from <a> to <b>", "SHA-256: AB:CD", "• The certificate has expired", "", "A certificate that can’t be read"]);
    }

    // --- the sheet (KioSheets.qml) ----------------------------------------------------------------------------------

    function test_conflictReplies(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        verify(sheet !== null);
        verify(!sheet.visible, "no question, no sheet");

        fakePrompts.current = test.conflict({
            skip: true,
            applyToAll: true
        });
        test.shown(sheet);
        compare(sheet.title, "An item named “Report.pdf” already exists in this location.");
        test.click(sheet, "Keep Both");
        compare(fakePrompts.replies.length, 1);
        compare(fakePrompts.replies[0].id, 7);
        compare(fakePrompts.replies[0].button, "keepBoth");
        compare(fakePrompts.replies[0].applyToAll, false);
        verify(!sheet.visible);

        // Apply to All, then Return: Replace for all.
        fakePrompts.current = test.conflict({
            id: 8,
            skip: true,
            applyToAll: true
        });
        test.shown(sheet);
        test.click(sheet, "Apply to All");
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[1].button, "replace");
        compare(fakePrompts.replies[1].applyToAll, true);

        // A new question starts with Apply to All off; Esc stops.
        fakePrompts.current = test.conflict({
            id: 9,
            skip: true,
            applyToAll: true
        });
        test.shown(sheet);
        verify(!test.find(sheet, "Apply to All").checked, "Apply to All starts off");
        keyClick(Qt.Key_Escape);
        compare(fakePrompts.replies[2].button, "stop");
        compare(fakePrompts.replies[2].applyToAll, false);

        // Skip.
        fakePrompts.current = test.conflict({
            id: 10,
            skip: true
        });
        test.shown(sheet);
        test.click(sheet, "Skip");
        compare(fakePrompts.replies[3].button, "skip");
        compare(fakePrompts.replies.length, 4);
    }

    function test_resume(): void {
        const s = KioSheetsLogic.sheet(test.conflict({
            resume: true,
            keepBoth: false
        }));
        compare(s.title, "Part of “Report.pdf” is already in this location.");
        compare([s.confirmText, s.confirmId, s.cancelId], ["Resume", "resume", "stop"]);
        compare(s.extras, [{id: "replace", text: "Start Over"}]);

        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = test.conflict({
            id: 41,
            resume: true,
            keepBoth: false
        });
        test.shown(sheet);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].button, "resume");
    }

    // A question hidden a moment (another sheet or a menu of the window) comes back with the choices made on it.
    function test_choicesKeptWhileHidden(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = test.conflict({
            id: 51,
            skip: true,
            applyToAll: true
        });
        test.shown(sheet);
        test.click(sheet, "Apply to All");
        sheets.shown = false;
        tryVerify(() => !sheet.visible, 1000);
        sheets.shown = true;
        test.shown(sheet);
        verify(test.find(sheet, "Apply to All").checked, "Apply to All kept");
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].applyToAll, true);
    }

    // Owner decision Q18 (ADR-0035): in the copy/move conflict sheet Return replaces, as the Finder (the written exception
    // to common rule 3); Replace is drawn as the default button, Stop is not. Merge and Resume are the defaults of theirs.
    function test_conflictReturnReplaces(): void {
        const s = KioSheetsLogic.sheet(test.conflict({}));
        compare([s.confirmId, s.returnCancels, s.destructive], ["replace", false, false]);
        compare(KioSheetsLogic.sheet(test.conflict({
            merge: true
        })).confirmId, "replace");
        compare(KioSheetsLogic.sheet(test.conflict({
            resume: true,
            keepBoth: false
        })).confirmId, "resume");

        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = test.conflict({
            id: 131,
            skip: true,
            applyToAll: true
        });
        test.shown(sheet);
        verify(test.find(sheet, "Replace").primary, "Replace is the default button");
        verify(!test.find(sheet, "Stop").primary, "Stop is not");
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].button, "replace");
        compare(fakePrompts.replies[0].applyToAll, false);
        fakePrompts.current = test.conflict({
            id: 132
        });
        test.shown(sheet);
        keyClick(Qt.Key_Enter);
        compare(fakePrompts.replies[1].button, "replace", "Enter too");
    }

    // A deletion: Delete answers "delete"; Return cancels (a destructive button is never the default, common rule 3).
    function test_deletion(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        const request = {
            id: 61,
            kind: "delete",
            type: "delete",
            count: 1,
            name: "a.txt"
        };
        fakePrompts.current = request;
        test.shown(sheet);
        test.click(sheet, "Delete");
        compare(fakePrompts.replies[0].button, "delete");
        fakePrompts.current = Object.assign({}, request, {
            id: 62
        });
        test.shown(sheet);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[1].button, "cancel");
    }

    // A document whose type has no application (ADR-0035 5c-3): Finder's alert; Choose Application… is the default (Return),
    // Cancel and Esc open nothing.
    function test_noApplication(): void {
        const s = KioSheetsLogic.sheet({
            id: 63,
            kind: "noApplication",
            name: "a.gfnone"
        });
        compare(s.title, "There is no application set to open the document “a.gfnone”.");
        compare(s.confirmText, "Choose Application…");
        compare([s.confirmId, s.cancelId], ["choose", "cancel"]);
        compare([s.destructive, s.returnCancels, s.showCancel], [false, false, true]);
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        const request = {
            id: 64,
            kind: "noApplication",
            name: "a.gfnone"
        };
        fakePrompts.current = request;
        test.shown(sheet);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].button, "choose");
        fakePrompts.current = Object.assign({}, request, {
            id: 65
        });
        test.shown(sheet);
        keyClick(Qt.Key_Escape);
        compare(fakePrompts.replies[1].button, "cancel");
        fakePrompts.current = Object.assign({}, request, {
            id: 66
        });
        test.shown(sheet);
        test.click(sheet, "Cancel");
        compare(fakePrompts.replies[2].button, "cancel");
        // With Grassfield Store there (step 4): Search the Store, Finder's App Store button, answers "store".
        const withStore = KioSheetsLogic.sheet({id: 67, kind: "noApplication", name: "a.gfnone", store: true});
        compare(withStore.message, "Search Grassfield Store for an app that opens it, or choose an application on this computer.");
        compare(withStore.extras, [{id: "store", text: "Search the Store"}]);
        compare(withStore.confirmId, "choose", "Choose Application… stays the default");
        compare(s.extras, [], "without the Store, no such button");
        fakePrompts.current = Object.assign({}, request, {id: 68, store: true});
        test.shown(sheet);
        test.click(sheet, "Search the Store");
        compare(fakePrompts.replies[3].button, "store");
    }

    // A worker's warning: Return never takes its action. With a Cancel it cancels; without one it gives the secondary
    // action (KDE's own box defaults to Cancel; an sftp host key that changed must not be accepted by Return).
    function test_warningReturnIsSafe(): void {
        let s = KioSheetsLogic.sheet({
            id: 70,
            kind: "message",
            title: "",
            text: "The host key changed.",
            details: "",
            primary: "Connect Anyway",
            secondary: "",
            cancel: true,
            okOnly: false,
            warning: true
        });
        verify(s.returnCancels, "a warning with Cancel");
        s = KioSheetsLogic.sheet({
            id: 71,
            kind: "message",
            title: "",
            text: "Overwrite?",
            details: "",
            primary: "Yes",
            secondary: "No",
            cancel: false,
            okOnly: false,
            warning: false
        });
        verify(!s.returnCancels, "a question that is not a warning keeps its primary action as the default");

        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = {
            id: 72,
            kind: "message",
            title: "Host key",
            text: "The host key changed.",
            details: "",
            primary: "Connect Anyway",
            secondary: "",
            cancel: true,
            okOnly: false,
            warning: true
        };
        test.shown(sheet);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].button, "cancel");
        fakePrompts.current = {
            id: 73,
            kind: "message",
            title: "",
            text: "Replace the remote file?",
            details: "",
            primary: "Replace",
            secondary: "Keep",
            cancel: false,
            okOnly: false,
            warning: true
        };
        test.shown(sheet);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[1].button, "secondary");
    }

    // A request without the merge field is never a merge.
    function test_conflictWithoutMergeField(): void {
        const request = test.conflict({});
        delete request.merge;
        const s = KioSheetsLogic.sheet(request);
        compare(s.title, "An item named “Report.pdf” already exists in this location.");
        compare(s.confirmText, "Replace");
    }

    // Two jobs' conflicts, one after the other: a double click on Replace answers the first one only; the second shows and
    // takes no input for the double-click interval (Return held down does not answer it either), then answers as usual.
    function test_secondQuestionIsNotAnsweredUnseen(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.waiting = [test.conflict({
                id: 82,
                name: "Other.pdf"
            })];
        fakePrompts.current = test.conflict({
            id: 81
        });
        test.shown(sheet);
        verify(waitForPolish(sheet.Window.window, 1000));
        const replace = test.find(sheet, "Replace");
        verify(replace !== null);
        mouseDoubleClickSequence(replace);
        compare(fakePrompts.replies.length, 1, "the double click answered one question");
        compare(fakePrompts.replies[0].id, 81);
        tryVerify(() => sheet.visible, 1000);
        verify(sheet.holdInput, "the second question holds its input");
        compare(sheet.title, "An item named “Other.pdf” already exists in this location.");
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies.length, 1, "Return right after it changed does not answer it");
        // Still held halfway through the double-click interval.
        wait(Application.styleHints.mouseDoubleClickInterval / 2);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies.length, 1, "Return halfway through the hold does not answer it either");
        wait(Qt.styleHints.mouseDoubleClickInterval + 50);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies.length, 2);
        compare(fakePrompts.replies[1].id, 82);
    }

    // A key held down answers nothing: its auto-repeat is not a press (Return held past one question).
    function test_heldReturnAnswersNothing(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = test.conflict({
            id: 111
        });
        test.shown(sheet);
        verify(sheet.handleKey(Qt.Key_Return, true), "the repeat is taken");
        compare(fakePrompts.replies, [], "and answers nothing");
        verify(sheet.handleKey(Qt.Key_Escape, true));
        compare(fakePrompts.replies, []);
        verify(sheet.handleKey(Qt.Key_Return, false));
        compare(fakePrompts.replies.length, 1, "a press answers");
    }

    // A button pressed and released elsewhere (no click) does not take the keyboard: Return stays the default button's.
    function test_aPressedButtonKeepsNoKeyboard(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = test.conflict({
            id: 121,
            skip: true
        });
        test.shown(sheet);
        verify(waitForPolish(sheet.Window.window, 1000));
        for (const label of ["Stop", "Keep Both"]) {
            const button = test.find(sheet, label);
            verify(button !== null, label);
            mousePress(button);
            mouseMove(button, -20, -20, -1, Qt.LeftButton);
            mouseRelease(button, -20, -20);
            verify(!button.activeFocus, label + " has no keyboard");
        }
        compare(fakePrompts.replies, [], "no click");
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].button, "replace");
    }

    // Return is the default button's in every new question, also after the user tabbed to another button in the last one
    // (Stop: a button every conflict sheet keeps).
    function test_returnIsTheDefaultAfterTab(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = test.conflict({
            id: 101
        });
        test.shown(sheet);
        verify(waitForPolish(sheet.Window.window, 1000));
        const stop = test.find(sheet, "Stop");
        verify(stop !== null);
        for (let i = 0; i < 6 && !stop.activeFocus; i++)
            keyClick(Qt.Key_Tab);
        verify(stop.activeFocus, "Tab reaches Stop");
        keyClick(Qt.Key_Escape);
        compare(fakePrompts.replies[0].button, "stop");
        fakePrompts.current = test.conflict({
            id: 102
        });
        test.shown(sheet);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[1].button, "replace", "Return is Replace's, not the button tabbed to last time");
    }

    // A long worker message: the sheet stays within its window, the buttons on screen, the text scrolls.
    function test_longMessageKeepsTheButtonsOnScreen(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        const lines = [];
        for (let i = 0; i < 200; i++)
            lines.push("Line " + i + " of what the server said.");
        fakePrompts.current = {
            id: 91,
            kind: "message",
            title: "Server",
            text: lines.join("\n"),
            details: "",
            primary: "",
            secondary: "",
            cancel: false,
            okOnly: true,
            warning: false
        };
        test.shown(sheet);
        verify(waitForPolish(sheet.Window.window, 1000));
        const ok = test.find(sheet, "OK");
        verify(ok !== null);
        const bottom = ok.mapToItem(sheets, 0, ok.height).y;
        verify(bottom <= sheets.height, "the OK button is inside the window (" + bottom + " <= " + sheets.height + ")");
        // The text scrolls: the wheel moves it.
        const findScroller = item => {
            if (item instanceof Flickable && item.contentHeight > item.height)
                return item;
            for (let i = 0; i < item.children.length; i++) {
                const found = findScroller(item.children[i]);
                if (found)
                    return found;
            }
            return null;
        };
        const scroller = findScroller(sheet);
        verify(scroller !== null, "the text is in a scroller");
        verify(scroller.interactive, "it scrolls");
        mouseWheel(scroller, scroller.width / 2, scroller.height / 2, 0, -360);
        tryVerify(() => scroller.contentY > 0, 1000, "the wheel scrolls the text");
        wait(Qt.styleHints.mouseDoubleClickInterval + 50);
        mouseClick(ok);
        compare(fakePrompts.replies[0].button, "ok");
    }

    function test_withdrawnQuestion(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = test.conflict({});
        test.shown(sheet);
        // The job ended: KioPrompts withdraws the question, unanswered.
        fakePrompts.current = ({});
        tryVerify(() => !sheet.visible, 1000, "the sheet goes with its question");
        compare(fakePrompts.replies, []);
    }

    function test_certificate(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        const request = {
            id: 21,
            kind: "certificate",
            host: "files.example.org",
            error: "The certificate has expired",
            chain: [{
                    readable: true,
                    subject: "files.example.org",
                    issuer: "Example CA",
                    validFrom: new Date(2025, 0, 1),
                    validUntil: new Date(2026, 0, 1),
                    sha256: "AB:CD",
                    problems: ["The certificate has expired"]
                }]
        };
        fakePrompts.current = request;
        test.shown(sheet);
        // Return cancels: connecting is never the default.
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].button, "cancel");

        fakePrompts.current = Object.assign({}, request, {
            id: 22
        });
        test.shown(sheet);
        verify(test.find(sheet, "Always trust “files.example.org”") === null, "Always trust comes with the certificate");
        test.click(sheet, "Show Certificate");
        verify(sheet.visible, "Show Certificate keeps the sheet");
        verify(test.find(sheet, "Hide Certificate") !== null);
        test.click(sheet, "Always trust “files.example.org”");
        test.click(sheet, "Continue");
        compare(fakePrompts.replies[1].button, "continue");
        compare(fakePrompts.replies[1].alwaysTrust, true);

        // The next certificate starts untrusted, its details hidden.
        fakePrompts.current = Object.assign({}, request, {
            id: 23
        });
        test.shown(sheet);
        verify(test.find(sheet, "Show Certificate") !== null);
        test.click(sheet, "Continue");
        compare(fakePrompts.replies[2].alwaysTrust, false);
    }

    // --- Files opens apps the Gatekeeper way (FilesApp::requestRun, explainForeign; ADR-0011 amendment 2026-11-08) ----------

    // The sheet before a downloaded program runs: where it came from, what Open does; Return and Esc cancel, only Open runs it.
    function test_openProgramTexts(): void {
        let s = KioSheetsLogic.sheet({id: 90, kind: "openProgram", what: "app", name: "Tool.AppImage", downloaded: true, host: "downloads.example.org",
                                      allowRun: true, copy: false});
        compare(s.title, "“Tool.AppImage” is an app downloaded from the Internet. Are you sure you want to open it?");
        compare(s.message, "This app was downloaded from downloads.example.org. Opening it allows it to run on this computer.");
        compare([s.confirmText, s.confirmId, s.cancelText, s.cancelId], ["Open", "open", "Cancel", "cancel"]);
        compare([s.destructive, s.returnCancels, s.showCancel], [false, true, true], "running is never the default answer");
        compare(s.extras, []);
        s = KioSheetsLogic.sheet({id: 91, kind: "openProgram", what: "app", name: "Tool.AppImage", downloaded: true, host: "", allowRun: false, copy: false});
        compare(s.message, "", "no host recorded: no origin line");
        s = KioSheetsLogic.sheet({id: 92, kind: "openProgram", what: "app", name: "tool", downloaded: false, host: "", allowRun: true, copy: false});
        compare(s.title, "Are you sure you want to open “tool”?");
        compare(s.message, "Opening it allows it to run on this computer.");
        s = KioSheetsLogic.sheet({id: 93, kind: "openProgram", what: "app", name: "Tool.AppImage", downloaded: true, host: "example.org", allowRun: true, copy: true});
        compare(s.message, "This app was downloaded from example.org. It can’t run from this location: it will be copied to your Applications folder and opened from there.");
        compare([s.confirmText, s.confirmId], ["Copy and Open", "open"]);
        s = KioSheetsLogic.sheet({id: 94, kind: "openProgram", what: "script", name: "install.sh", downloaded: true, host: "example.org", allowRun: false, copy: false});
        compare(s.title, "“install.sh” is a script downloaded from the Internet. Are you sure you want to run it in Terminal?");
        compare(s.message, "This script was downloaded from example.org.");
        compare(s.confirmText, "Run");
        s = KioSheetsLogic.sheet({id: 95, kind: "openProgram", what: "script", name: "install.sh", downloaded: false});
        compare(s.title, "Are you sure you want to run “install.sh” in Terminal?");
        // Open With: the application that would open (and may run) it is named; Return and Esc still cancel.
        s = KioSheetsLogic.sheet({id: 96, kind: "openProgram", what: "app", name: "Tool.AppImage", downloaded: true, host: "example.org", allowRun: false,
                                  copy: false, handler: "AppImage Helper"});
        compare(s.title, "“Tool.AppImage” is an app downloaded from the Internet. Are you sure you want to open it with AppImage Helper?");
        compare(s.message, "This app was downloaded from example.org.");
        compare([s.confirmText, s.confirmId, s.cancelId, s.returnCancels, s.destructive], ["Open with AppImage Helper", "open", "cancel", true, false]);
        s = KioSheetsLogic.sheet({id: 97, kind: "openProgram", what: "script", name: "install.sh", downloaded: true, host: "", allowRun: false, copy: false,
                                  handler: "Script Runner"});
        compare(s.title, "“install.sh” is a script downloaded from the Internet. Are you sure you want to open it with Script Runner?");
        compare(s.message, "");
        compare(s.confirmText, "Open with Script Runner");
        s = KioSheetsLogic.sheet({id: 98, kind: "openProgram", what: "app", name: "tool", downloaded: false, handler: "AppImage Helper"});
        compare(s.title, "Are you sure you want to open “tool” with AppImage Helper?");
        // A name drawn in another order (right-to-left text, a bidi mark written out by DisplayName): said in the sheet.
        s = KioSheetsLogic.sheet({id: 99, kind: "openProgram", what: "app", name: "<U+200F>pdf.<U+200F>Invoice", downloaded: false, allowRun: false,
                                  copy: false, nameUntrusted: true});
        compare(s.title, "Are you sure you want to open “<U+200F>pdf.<U+200F>Invoice”?");
        compare(s.message, "Its name contains right-to-left text, which can change the way it is shown: it may not be what its name suggests.");
        compare([s.confirmText, s.returnCancels], ["Open", true]);
    }

    function test_openProgramReplies(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        const request = {id: 100, kind: "openProgram", what: "app", name: "Tool.AppImage", downloaded: true, host: "example.org", allowRun: true, copy: false};
        fakePrompts.current = request;
        test.shown(sheet);
        compare(sheet.title, "“Tool.AppImage” is an app downloaded from the Internet. Are you sure you want to open it?");
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].button, "cancel", "Return cancels");
        fakePrompts.current = Object.assign({}, request, {id: 101});
        test.shown(sheet);
        keyClick(Qt.Key_Escape);
        compare(fakePrompts.replies[1].button, "cancel", "Esc cancels");
        fakePrompts.current = Object.assign({}, request, {id: 102});
        test.shown(sheet);
        test.click(sheet, "Open");
        compare(fakePrompts.replies[2].button, "open", "only Open runs it");
    }

    // A Windows or Java program: explained; "Open with …" only when an application here opens it, and never the default.
    function test_foreignProgram(): void {
        let s = KioSheetsLogic.sheet({id: 110, kind: "foreignProgram", platform: "windows", name: "setup.exe", handler: "", downloaded: true, host: "example.org"});
        compare(s.title, "This file is a program for Windows; it doesn’t work directly on Linux.");
        compare(s.message, "“setup.exe” can’t be opened on this computer. This file was downloaded from example.org.");
        compare([s.confirmText, s.confirmId, s.showCancel, s.returnCancels], ["OK", "ok", false, false]);
        s = KioSheetsLogic.sheet({id: 111, kind: "foreignProgram", platform: "windows", name: "setup.exe", handler: "Wine", downloaded: false});
        compare(s.message, "Wine can open “setup.exe”. Open it only if you trust where it came from.");
        compare([s.confirmText, s.confirmId, s.cancelId, s.showCancel, s.returnCancels], ["Open with Wine", "open", "cancel", true, true]);
        s = KioSheetsLogic.sheet({id: 112, kind: "foreignProgram", platform: "java", name: "tool.jar", handler: ""});
        compare(s.title, "This file is a Java program.");
        compare(s.message, "Java isn’t installed on this computer, so “tool.jar” can’t be opened.");
        s = KioSheetsLogic.sheet({id: 113, kind: "foreignProgram", platform: "java", name: "tool.jar", handler: "Java"});
        compare(s.message, "Java can open “tool.jar”. Open it only if you trust where it came from.");
        compare(s.confirmText, "Open with Java");
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = {id: 114, kind: "foreignProgram", platform: "windows", name: "setup.exe", handler: "Wine"};
        test.shown(sheet);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].button, "cancel", "Return never runs it");
        fakePrompts.current = {id: 115, kind: "foreignProgram", platform: "windows", name: "setup.exe", handler: "Wine"};
        test.shown(sheet);
        test.click(sheet, "Open with Wine");
        compare(fakePrompts.replies[1].button, "open");
    }

    // Another system's app (.dmg, .pkg): explained; Search the Store when the Store is there. The text never names the system.
    function test_foreignApp(): void {
        let s = KioSheetsLogic.sheet({id: 120, kind: "foreignApp", name: "Slack.dmg", store: true});
        compare(s.title, "This file contains an app made for another operating system, which can’t work on Linux.");
        compare(s.message, "Look in the Store for an app for Linux that does the same thing.");
        compare(s.extras, [{id: "store", text: "Search the Store"}]);
        compare([s.confirmText, s.confirmId, s.showCancel], ["OK", "ok", false]);
        s = KioSheetsLogic.sheet({id: 121, kind: "foreignApp", name: "Slack.dmg", store: false});
        compare(s.message, "Look for a version of “Slack.dmg” made for Linux.");
        compare(s.extras, []);
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = {id: 122, kind: "foreignApp", name: "Slack.dmg", store: true};
        test.shown(sheet);
        test.click(sheet, "Search the Store");
        compare(fakePrompts.replies[0].button, "store");
        fakePrompts.current = {id: 123, kind: "foreignApp", name: "Slack.dmg", store: true};
        test.shown(sheet);
        keyClick(Qt.Key_Escape);
        compare(fakePrompts.replies[1].button, "ok");
    }

    function test_unknownKindStops(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = {
            id: 31,
            kind: "future"
        };
        tryVerify(() => fakePrompts.replies.length === 1, 1000);
        compare(fakePrompts.replies[0].button, "stop");
        verify(!sheet.visible);
    }

    function test_notShownHere(): void {
        const host = createTemporaryObject(sheetsComponent, test);
        host.sheets.shown = false;
        const sheet = test.sheetOf(host.sheets);
        fakePrompts.current = test.conflict({});
        wait(50);
        verify(!sheet.visible, "another window shows it");
        host.sheets.shown = true;
        tryVerify(() => sheet.visible, 1000, "this window, once it is the one");
        compare(fakePrompts.replies, []);
    }
}
