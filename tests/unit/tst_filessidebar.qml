pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"

// Files' sidebar eject: with the toolbar buttons out of the Tab chain, the keyboard reaches Eject through File > Eject (Ctrl+E)
// and the sidebar item's context menu (macOS Finder). Sidebar.ejectRow names the volume the sidebar points at (the row
// the keyboard is on while the sidebar has the focus, else the one whose folder is shown); it is -1 for anything else.
TestCase {
    id: tc

    name: "FilesSidebar"
    width: 400
    height: 600
    visible: true
    when: windowShown

    property var ejected: []
    property var menus: []

    ListModel {
        id: placesItem

        property string current: "file:///media/usb"

        ListElement {
            section: "favorites"
            name: "Home"
            url: "file:///home/u"
            iconName: "user-home"
            kind: "folder"
            mounted: true
            ejectable: false
            busy: false
            tag: ""
            tagColor: -1
            unavailable: false
        }

        ListElement {
            section: "locations"
            name: "USB"
            url: "file:///media/usb"
            iconName: "drive-removable-media"
            kind: "volume"
            mounted: true
            ejectable: true
            busy: false
            tag: ""
            tagColor: -1
            unavailable: false
        }

        ListElement {
            section: "locations"
            name: "Busy disk"
            url: "file:///media/busy"
            iconName: "drive-removable-media"
            kind: "volume"
            mounted: true
            ejectable: true
            busy: true
            tag: ""
            tagColor: -1
            unavailable: false
        }

        // Last here so the rows above keep their numbers (first in the real sidebar).
        ListElement {
            section: "favorites"
            name: "Applications"
            url: "grassfield-apps:/"
            iconName: "folder-applications"
            kind: "applications"
            mounted: true
            ejectable: false
            busy: false
            tag: ""
            tagColor: -1
            unavailable: false
        }

        ListElement {
            section: "recents"
            name: "Recents"
            url: "grassfield-recents:/"
            iconName: "document-open-recent"
            kind: "recents"
            mounted: true
            ejectable: false
            busy: false
            tag: ""
            tagColor: -1
            unavailable: false
        }

        // A folder the user added to Favorites (row 5; PlacesModel lists them after the standard places).
        ListElement {
            section: "favorites"
            name: "Projects"
            url: "file:///home/u/Projects"
            iconName: "folder"
            kind: "pinned"
            mounted: true
            ejectable: false
            busy: false
            tag: ""
            tagColor: -1
            unavailable: false
        }

        property int firstPinnedRow: 5
        property int pinnedCount: 1

        function rowForUrl(url): int {
            for (let i = 0; i < placesItem.count; i++) {
                if (String(placesItem.get(i).url) === String(url))
                    return i;
            }
            return -1;
        }
        function eject(row: int): void {
            tc.ejected = tc.ejected.concat([row]);
        }
        function mount(row: int): void {
        }
    }

    QtObject {
        id: fakeApp

        property var places: placesItem
        property var hiddenTags: []
        // Favorites editing, recorded.
        property var added: []
        property var removed: []
        property var moved: []
        // A drop at a gap also names the place to fall back to (items with no folder go into it) and the sidebar's token.
        property var lastFallback: ""
        property string lastToken: ""
        signal sidebarDropFallback(string token, var urls, url destination)
        function addToSidebar(urls: var, position: int, fallback: url, token: string): void {
            fakeApp.added = fakeApp.added.concat([{urls: urls.map(u => String(u)), position: position}]);
            fakeApp.lastFallback = String(fallback);
            fakeApp.lastToken = token;
        }
        function removeFromSidebar(url: url): void {
            fakeApp.removed = fakeApp.removed.concat([String(url)]);
        }
        function moveInSidebar(url: url, position: int): void {
            fakeApp.moved = fakeApp.moved.concat([{url: String(url), position: position}]);
        }
    }

    QtObject {
        id: fakeTab

        property var url: "file:///media/usb"
        // An Open or Save panel's tab has one (the sidebar edits nothing there).
        property var chooser: null
        property var win: QtObject {
            property var menuLayer: QtObject {
                function open(items, x, y, cb, back, flag): void {
                    tc.menus = tc.menus.concat([{items: items, cb: cb, keyboard: flag}]);
                }
            }
            property var tabs: []
            function newTab(url, restore): void {
                fakeTab.win.tabs = fakeTab.win.tabs.concat([String(url)]);
            }
        }
        property var drops: []
        function dropUrls(urls, destination, model): void {
            fakeTab.drops = fakeTab.drops.concat([String(destination)]);
        }
        property var navigated: []
        function navigate(url, record): void {
            fakeTab.navigated = fakeTab.navigated.concat([String(url)]);
        }
        property var hovered: []
        function springHover(url): void {
            fakeTab.hovered = fakeTab.hovered.concat([String(url)]);
        }
        function springLeave(url): void {
        }
    }

    // A drag from elsewhere (Drag.Internal: delivered within this window, like the system drag reaches the DropAreas).
    Item {
        id: incoming
        width: 4
        height: 4
        z: 10
        Drag.keys: ["text/uri-list"]
        Drag.mimeData: {"text/uri-list": "file:///home/u/New"}
        Drag.dragType: Drag.Internal
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
        Drag.hotSpot.x: 2
        Drag.hotSpot.y: 2
    }

    Sidebar {
        id: sidebar

        width: 200
        height: 520
        app: fakeApp
        tab: fakeTab
    }

    function init() {
        tc.ejected = [];
        tc.menus = [];
        fakeTab.url = "file:///media/usb";
        tc.forceActiveFocus();
        sidebar.keyRow = -1;
        tryCompare(sidebar, "ejectRow", 1);
    }

    // The floating panel (ADR-0024 amendment 2026-11-03), also in an Open or Save panel (macOS's panel has a floating sidebar
    // too; topInset 0 there, no lights): inset from the left, top and bottom, rounded, and the rows inside it.
    function test_thePanelFloatsAndTheRowsStayInsideIt() {
        const inset = Tokens.windowSidebarPanelInset;
        let panel = null;
        let list = null;
        const stack = [sidebar];
        while (stack.length > 0) {
            const it = stack.shift();
            if (String(it).indexOf("SidebarPanel") === 0)
                panel = it;
            if (it.Accessible && it.Accessible.name === "Sidebar" && it.contentY !== undefined)
                list = it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        verify(panel !== null, "the panel");
        verify(list !== null, "the list");
        compare(panel.x, inset);
        compare(panel.y, inset);
        compare(panel.height, sidebar.height - 2 * inset);
        // The panel token on whole device pixels (SidebarPanel), concentric with the window's corner.
        compare(panel.radius, Math.round(Tokens.windowSidebarPanelRadius * panel.pixelRatio) / panel.pixelRatio);
        verify(list.y >= panel.y + Tokens.spacingSm, "the first row starts inside the panel, not on its edge: " + list.y);
        verify(list.x >= panel.x, "inside the panel's left edge");
        verify(list.y + list.height <= panel.y + panel.height, "inside the panel's bottom edge");
    }

    function test_theVolumeShownIsTheEjectTarget() {
        compare(sidebar.ejectRow, 1);
        verify(sidebar.eject());
        compare(tc.ejected, [1]);
    }

    function test_aFolderBusyOrUnknownRowIsNoTarget() {
        fakeTab.url = "file:///home/u";
        tryCompare(sidebar, "ejectRow", -1);
        verify(!sidebar.eject());
        fakeTab.url = "file:///media/busy";
        tryCompare(sidebar, "ejectRow", -1);
        verify(!sidebar.eject());
        compare(tc.ejected, [], "nothing was ejected");
    }

    function test_theKeyboardRowWinsWhileTheSidebarHasTheFocus() {
        fakeTab.url = "file:///home/u";
        sidebar.forceActiveFocus();
        sidebar.keyRow = 1;
        tryCompare(sidebar, "ejectRow", 1);
        sidebar.keyRow = 0;
        tryCompare(sidebar, "ejectRow", -1);
        sidebar.keyRow = 2;
        tryCompare(sidebar, "ejectRow", -1, 1000, "a busy volume is not ejected twice");
    }

    // The context menu of an ejectable volume row offers Eject, and it ejects that row.
    function test_contextMenuOfAVolumeRowOffersEject() {
        // The row of "USB": click it with the right button through the list item.
        const listView = findList(sidebar);
        verify(listView !== null);
        const item = listView.itemAtIndex(1);
        verify(item !== null);
        mouseClick(item, 20, item.height / 2, Qt.RightButton);
        compare(tc.menus.length, 1);
        compare(tc.menus[0].items.map(i => i.text), ["Eject"]);
        tc.menus[0].cb("eject");
        compare(tc.ejected, [1]);
        // A busy volume row has no menu.
        mouseClick(listView.itemAtIndex(2), 20, 8, Qt.RightButton);
        compare(tc.menus.length, 1);
    }

    // Recents takes no drop and does not spring open (Finder); a folder place takes the drag and springs.
    function test_recentsTakesNoDrop() {
        const listView = findList(sidebar);
        verify(listView !== null);
        fakeTab.hovered = [];
        for (const row of [{index: 4, accepted: false}, {index: 0, accepted: true}]) {
            const item = listView.itemAtIndex(row.index);
            verify(item !== null);
            const p = item.mapToItem(tc, item.width / 2, item.height / 2);
            incoming.x = p.x - 2;
            incoming.y = p.y - 2;
            incoming.Drag.active = true;
            incoming.y += 1;
            wait(20);
            if (row.accepted)
                verify(incoming.Drag.target !== null, "Home takes the drag");
            else
                compare(incoming.Drag.target, null, "Recents takes no drag");
            if (!row.accepted)
                compare(incoming.Drag.drop(), Qt.IgnoreAction);
            incoming.Drag.active = false;
        }
        compare(fakeTab.hovered, ["file:///home/u"], "only Home sprang");
    }

    // The Applications place (kind "applications") is an ordinary place to the sidebar: a click opens its location in the tab
    // (a new tab and Back/Forward are the tab's, as for a folder); it has no eject menu.
    function test_applicationsPlaceOpensItsLocation() {
        const listView = findList(sidebar);
        verify(listView !== null);
        const item = listView.itemAtIndex(3);
        verify(item !== null);
        fakeTab.navigated = [];
        mouseClick(item, 20, item.height / 2);
        compare(fakeTab.navigated, ["grassfield-apps:/"]);
        mouseClick(item, 20, item.height / 2, Qt.RightButton);
        compare(tc.menus.length, 1, "the Favorites place menu");
        compare(tc.menus[0].items.filter(i => i.text).map(i => i.text), ["Open in New Tab", "Remove from Sidebar"], "no Eject on a place that cannot be ejected");
    }

    // A standard folder whose disk does not answer is listed, dimmed (PlacesModel's "unavailable"; re-review of 24bdf58,
    // MINOR 4).
    function test_anUnavailablePlaceIsDimmed() {
        const listView = findList(sidebar);
        verify(listView !== null);
        compare(listView.itemAtIndex(0).opacity, 1);
        placesItem.setProperty(0, "unavailable", true);
        tryCompare(listView.itemAtIndex(0), "opacity", Tokens.materialDisabledOpacity);
        placesItem.setProperty(0, "unavailable", false);
        tryCompare(listView.itemAtIndex(0), "opacity", 1);
    }

    // Favorites editing (FP-27; owner report 2026-11-07: "there is no way to pin a folder in the sidebar, neither with right-click
    // nor by drag and drop"). A Favorites folder place's menu: Open in New Tab and Remove from Sidebar, for a folder of the
    // user's and a standard one alike (FilesApp hides a standard place); the Menu key opens the keyboard row's menu.
    function test_aFavoritesPlaceMenuRemovesItFromTheSidebar() {
        const listView = findList(sidebar);
        fakeApp.removed = [];
        fakeTab.win.tabs = [];
        for (const row of [5, 0]) {
            tc.menus = [];
            const item = listView.itemAtIndex(row);
            mouseClick(item, 20, item.height / 2, Qt.RightButton);
            compare(tc.menus.length, 1, "row " + row + " has a menu");
            compare(tc.menus[0].items.filter(i => i.text).map(i => i.text), ["Open in New Tab", "Remove from Sidebar"]);
            tc.menus[0].cb("unlist");
        }
        compare(fakeApp.removed, ["file:///home/u/Projects", "file:///home/u"]);
        tc.menus[0].cb("newTab");
        compare(fakeTab.win.tabs, ["file:///home/u"]);
        // The keyboard: the Menu key on the row the keyboard is on.
        tc.menus = [];
        sidebar.forceActiveFocus();
        listView.forceActiveFocus();
        sidebar.keyRow = 5;
        keyClick(Qt.Key_Menu);
        compare(tc.menus.length, 1, "the Menu key opens the row's menu");
        verify(tc.menus[0].keyboard, "opened for the keyboard (its first row selected)");
        compare(tc.menus[0].items.filter(i => i.text).map(i => i.text), ["Open in New Tab", "Remove from Sidebar"]);
        // A panel's sidebar edits nothing.
        tc.menus = [];
        fakeTab.chooser = {filter: {}};
        mouseClick(listView.itemAtIndex(5), 20, 8, Qt.RightButton);
        compare(tc.menus.length, 0, "no menu in an Open or Save panel");
        fakeTab.chooser = null;
    }

    // A drag at the edge of a Favorites row shows the insertion line and a drop there adds the items to the user's folders at
    // that position (FilesApp keeps the folders); in the middle of a place the items go into it, as before. The drag is
    // tracked by the rows' drop areas for real; an internal drag carries no URLs, so the drop's items are handed to the row
    // as its onDropped hands a system drag's (PlaceRow.dropItems).
    function test_aDropBetweenFavoritesRowsAddsToTheSidebar() {
        const listView = findList(sidebar);
        fakeApp.added = [];
        fakeTab.drops = [];
        const dragTo = (row, y) => {
            const item = listView.itemAtIndex(row);
            const p = item.mapToItem(tc, item.width / 2, y);
            incoming.x = p.x - 2;
            incoming.y = p.y - 2;
            incoming.Drag.active = true;
            incoming.y += 0.5;
            wait(20);
        };
        const items = ["file:///home/u/New"];
        const pinned = listView.itemAtIndex(5);
        dragTo(5, pinned.height - 3);
        compare(sidebar.insertGap, 1, "the bottom edge of the user's first folder: after it");
        const line = findLine();
        verify(line !== null && line.visible, "the insertion line shows");
        fuzzyCompare(line.y + line.height / 2, pinned.y + pinned.height, 0.5, "under the user's first folder");
        verify(pinned.dropItems(items));
        incoming.Drag.active = false;
        compare(fakeApp.added, [{urls: items, position: 1}]);
        compare(fakeApp.lastFallback, "file:///home/u/Projects", "items with no folder would go into Projects itself");
        compare(sidebar.insertGap, -1, "the line goes with the drop");
        verify(!line.visible);
        dragTo(5, 3);
        compare(sidebar.insertGap, 0, "its top edge: before it");
        verify(pinned.dropItems(items));
        incoming.Drag.active = false;
        dragTo(0, 3);
        compare(sidebar.insertGap, 0, "a standard place's edge: before the user's folders");
        incoming.Drag.active = false;
        sidebar.insertGap = -1;
        dragTo(0, pinned.height / 2);
        compare(sidebar.insertGap, -1, "the middle of a place: into it");
        verify(listView.itemAtIndex(0).dropItems(items));
        incoming.Drag.active = false;
        compare(fakeTab.drops, ["file:///home/u"], "the items went into Home");
        compare(fakeApp.added.length, 2);
        // A panel's sidebar takes no insertion.
        fakeTab.chooser = {filter: {}};
        dragTo(5, pinned.height - 3);
        compare(sidebar.insertGap, -1);
        incoming.Drag.active = false;
        fakeTab.chooser = null;
    }

    // A folder of the user's drags: dropped at another gap it moves there, released out of the sidebar it leaves Favorites
    // (the Finder's drag out); the folder itself is untouched.
    function test_aFolderOfTheUsersMovesAndDragsOut() {
        const listView = findList(sidebar);
        fakeApp.moved = [];
        fakeApp.removed = [];
        const pinned = listView.itemAtIndex(5);
        const start = pinned.mapToItem(tc, 40, pinned.height / 2);
        // To the top edge of Home (gap 0: before the user's folders).
        const home = listView.itemAtIndex(0);
        const to = home.mapToItem(tc, 40, 3);
        // The pointer moves in steps, the event loop turning between them (an internal drag reaches the drop areas then).
        const dragAlong = (from, dx, dy) => {
            mousePress(tc, from.x, from.y);
            for (let i = 1; i <= 8; i++) {
                mouseMove(tc, from.x + dx * i / 8, from.y + dy * i / 8);
                wait(10);
            }
            mouseRelease(tc, from.x + dx, from.y + dy);
        };
        dragAlong(start, 0, to.y - start.y);
        compare(fakeApp.moved, [{url: "file:///home/u/Projects", position: 0}]);
        compare(fakeApp.removed, [], "a move is no removal");
        // Out of the sidebar (to its right).
        dragAlong(start, 320, 0);
        compare(fakeApp.removed, ["file:///home/u/Projects"]);
        // A standard place does not drag.
        fakeApp.removed = [];
        dragAlong(home.mapToItem(tc, 40, home.height / 2), 320, 0);
        compare(fakeApp.removed, []);
    }

    // Integrator review, L4: items with no folder among them dropped at the edge of a place go into that place (FilesApp answers
    // with sidebarDropFallback for the token this sidebar sent); an answer for another sidebar's token is not this one's.
    function test_anEdgeDropWithNoFolderGoesIntoThePlace() {
        const listView = findList(sidebar);
        fakeTab.drops = [];
        const home = listView.itemAtIndex(0);
        const p = home.mapToItem(tc, home.width / 2, 3);
        incoming.x = p.x - 2;
        incoming.y = p.y - 2;
        incoming.Drag.active = true;
        incoming.y += 0.5;
        wait(20);
        compare(sidebar.insertGap, 0, "Home's top edge is a gap");
        verify(home.dropItems(["file:///home/u/note.txt"]));
        incoming.Drag.active = false;
        compare(fakeApp.lastFallback, "file:///home/u", "Home is the place to fall back to");
        verify(fakeApp.lastToken !== "", "with this sidebar's token");
        fakeApp.sidebarDropFallback("another-sidebar", ["file:///home/u/note.txt"], "file:///home/u");
        compare(fakeTab.drops, [], "another sidebar's answer is ignored");
        fakeApp.sidebarDropFallback(fakeApp.lastToken, ["file:///home/u/note.txt"], "file:///home/u");
        compare(fakeTab.drops, ["file:///home/u"], "the items go into Home, as a drop in its middle");
        fakeApp.sidebarDropFallback(fakeApp.lastToken, ["file:///home/u/note.txt"], "file:///home/u");
        compare(fakeTab.drops, ["file:///home/u"], "once");
    }

    // The insertion line (a Rectangle with lineY in the list's content).
    function findLine(): var {
        const stack = [findList(sidebar).contentItem];
        while (stack.length) {
            const it = stack.pop();
            if (it.lineY !== undefined)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function findList(item: Item): var {
        const stack = [item];
        while (stack.length) {
            const it = stack.pop();
            if (it.itemAtIndex !== undefined && it.count !== undefined)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }
}
