import QtQuick
import QtTest

// The desktop's context menus (macOS model, shell/desktop/IconMenu.qml): which actions each kind offers, in which
// order, and when the conditional rows (Paste, Open With ▸) appear.
TestCase {
    id: testCase
    name: "IconMenu"

    function menu(props: var): var {
        const c = Qt.createComponent(Qt.resolvedUrl("../../shell/desktop/IconMenu.qml"));
        verify(c.status === Component.Ready, c.errorString());
        const m = c.createObject(testCase, props);
        verify(m !== null);
        return m;
    }

    function ids(m: var): var {
        return m.model.filter(i => !i.separator).map(i => i.id);
    }

    function test_noRowHighlightedAtOpen() {
        const d = menu({kind: "desktop"});
        compare(d.currentIndex, -1);
        d.destroy();
        const i = menu({kind: "icon", count: 1, singleName: "Report.pdf"});
        compare(i.currentIndex, -1);
        i.destroy();
    }

    function test_desktopMenu() {
        const m = menu({kind: "desktop"});
        compare(ids(m), ["newFolder", "getInfo", "wallpaper", "editWidgets", "cleanUp", "cleanUpByMenu"]);
        const by = m.model.find(i => i.id === "cleanUpByMenu").submenu.map(i => i.id);
        compare(by, ["cleanUpBy:name", "cleanUpBy:kind", "cleanUpBy:modified", "cleanUpBy:created", "cleanUpBy:size"]);
        m.destroy();
    }

    // Another display than the one with the icons: the menu opens there too, without New Folder, Paste (their rename field and
    // result are on the icons' screen) and Clean Up.
    function test_secondDisplayOffersNoArrangement() {
        const m = menu({kind: "desktop", itemsHere: false, pasteCount: 1});
        compare(ids(m), ["getInfo", "wallpaper", "editWidgets"]);
        verify(!m.model[0].separator, "no separator first");
        m.destroy();
    }

    // Show Desktop Items off: the surface is still there; nothing that makes or arranges items is offered.
    function test_itemsHiddenKeepsTheRest() {
        const m = menu({kind: "desktop", itemsHere: false, pasteCount: 2});
        compare(ids(m), ["getInfo", "wallpaper", "editWidgets"]);
        verify(!m.model[0].separator);
        m.destroy();
    }

    function test_pasteOnlyWithFilesOnTheClipboard() {
        const one = menu({kind: "desktop", pasteCount: 1});
        compare(ids(one).slice(0, 2), ["newFolder", "paste"]);
        compare(one.model[1].text, "Paste Item");
        one.destroy();
        const two = menu({kind: "desktop", pasteCount: 2});
        compare(two.model[1].text, "Paste 2 Items");
        two.destroy();
    }

    function test_iconMenu() {
        const m = menu({kind: "icon", count: 1, singleName: "Report.pdf"});
        compare(ids(m), ["open", "trash", "getInfo", "rename", "compress", "duplicate", "alias", "quickLook", "copy"]);
        // The name goes in the row's name (drawn shortened in its middle when long: menu.nameMaxWidth).
        compare(m.model.find(i => i.id === "compress").text, "Compress “%1”");
        compare(m.model.find(i => i.id === "compress").name, "Report.pdf");
        compare(m.model.find(i => i.id === "quickLook").text, "Glance at “%1”");
        compare(m.model.find(i => i.id === "quickLook").name, "Report.pdf");
        verify(m.model.find(i => i.id === "rename").enabled);
        m.destroy();
    }

    function test_severalItems() {
        const m = menu({kind: "icon", count: 3});
        compare(m.model.find(i => i.id === "compress").text, "Compress 3 Items");
        compare(m.model.find(i => i.id === "copy").text, "Copy 3 Items");
        // macOS renames several items in a batch window; there is none: Rename is off.
        compare(m.model.find(i => i.id === "rename").enabled, false);
        m.destroy();
    }

    function test_openWithListsTheDefaultFirst() {
        const m = menu({kind: "icon", count: 1, singleName: "a.txt", openWithApps: [{id: "editor", name: "Editor"}, {id: "viewer", name: "Viewer"}]});
        compare(ids(m).slice(0, 2), ["open", "openWithMenu"]);
        const sub = m.model.find(i => i.id === "openWithMenu").submenu;
        compare(sub.map(i => i.id), ["openWith:editor", "openWith:viewer"]);
        compare(sub[0].text, "Editor (default)");
        compare(sub[1].text, "Viewer");
        m.destroy();
    }
}
