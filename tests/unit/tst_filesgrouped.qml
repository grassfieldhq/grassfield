pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../apps/files/qml"

// grassfield-files grouped icon view (apps/files/qml/IconView.qml, View > Group By) on a stand-in listing: only the
// sections near the view are made (their header, the DelegateModel of their rows, their views: a folder grouped by name
// can have thousands of groups, each DelegateModel follows every change of the listing), a view made before it has its
// size makes the cells of the lines it shows only, and a far group is made when it is scrolled to.
TestCase {
    id: test
    name: "FilesGrouped"
    when: windowShown
    visible: true
    width: 1000
    height: 700

    // The FolderModel API the icon view uses, on a ListModel with the same roles; `made` counts the cells (each asks for
    // its thumbnail when it is made).
    ListModel {
        id: listing

        property int groupBy: 1
        property var groups: []
        property int currentRow: -1
        property int selectedCount: 0
        property bool loading: false
        property bool isApplications: false
        property string error: ""
        property url url: "file:///sandbox"
        property int made: 0
        property var asked: ({})

        signal revealRequested(int row, bool rename)

        function requestPreview(row: int, large: bool): void {
            listing.made++;
            listing.asked[row] = true;
        }
        function cancelPreview(url: url, large: bool): void {
        }
        function select(row: int, modifiers: int): void {
        }
        function selectedUrls(): var {
            return [];
        }
        function selectUrls(urls: var): void {
        }
        function clearSelection(): void {
        }
        function urlAt(row: int): url {
            return listing.get(row).url;
        }
        function isSelected(row: int): bool {
            return false;
        }
    }

    QtObject {
        id: fakeTab

        property string searchText: ""
        property var win: null
        property var app: QtObject {
            function baseNameLength(name: string, isDir: bool): int {
                return name.length;
            }
            function isRecents(url: url): bool {
                return false;
            }
            function uriList(urls: var): string {
                return "";
            }
        }
        function isRenaming(model: var, url: url): bool {
            return false;
        }
        function handleViewKey(event: var, model: var, mover: var): void {
        }
        function contextMenu(model: var, row: int, x: real, y: real, keyboard: bool): void {
        }
        function activate(row: int, model: var, modifiers: int): void {
        }
        function springHover(url: url): void {
        }
        function springLeave(url: url): void {
        }
        function dropUrls(urls: var, destination: url, model: var): void {
        }
        function dragStarted(): void {
        }
        function dragFinished(action: int): void {
        }
        function startRename(model: var, row: int): void {
        }
        function commitRename(name: string): void {
        }
        function cancelRename(): void {
        }
    }

    // The BrowserTab API the list view reads; the list rows carry the extra roles below.
    QtObject {
        id: listTab
        property string searchText: ""
        property int sortKey: 0
        property bool sortDescending: false
        property var app: QtObject {
            function isRecents(url: url): bool {
                return false;
            }
            function baseNameLength(name: string, isDir: bool): int {
                return name.length;
            }
            function uriList(urls: var): string {
                return "";
            }
        }
        function isRenaming(model: var, url: url): bool {
            return false;
        }
        function handleViewKey(event: var, model: var, mover: var): void {
        }
        function sortBy(key: int, toggle: bool): void {
        }
        function activate(row: int, model: var, modifiers: int): void {
        }
        function contextMenu(model: var, row: int, x: real, y: real, keyboard: bool): void {
        }
        function dropUrls(urls: var, destination: url, model: var): void {
        }
        function dragStarted(): void {
        }
        function dragFinished(action: int): void {
        }
        function springHover(url: url): void {
        }
        function springLeave(url: url): void {
        }
        function startRename(model: var, row: int): void {
        }
        function commitRename(name: string): void {
        }
        function cancelRename(): void {
        }
    }

    Component {
        id: listComponent
        FileList {
            anchors.fill: parent
            tab: listTab
            model: listing
        }
    }

    Component {
        id: viewComponent
        IconView {
            anchors.fill: parent
            tab: fakeTab
            model: listing
        }
    }

    // `groupCount` groups of `size` items, one first letter each (U+4E00 on: each its own Name group, FileLogic::groupOf).
    function fill(groupCount: int, size: int): void {
        listing.clear();
        listing.made = 0;
        listing.asked = {};
        const groups = [];
        for (let g = 0; g < groupCount; g++) {
            const letter = String.fromCharCode(0x4E00 + g);
            groups.push({title: letter, first: listing.count, count: size});
            for (let i = 0; i < size; i++) {
                listing.append({name: letter + " " + i, url: "file:///sandbox/" + g + "-" + i, iconName: "", thumbnail: "", emblem: "", selected: false,
                                isDir: false, folderColor: "", folderGlyph: "", canPreview: true, hidden: false, cut: false, dimmed: false, tagColors: [],
                                modifiedText: "", sizeText: "", kind: "Plain text document"});
            }
        }
        listing.groups = groups;
    }

    function findText(item: Item, text: string): var {
        const stack = [item];
        while (stack.length) {
            const it = stack.pop();
            if (it.text === text && it.visible !== undefined)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    // Made before it has a size (as by the tab's view Loader), a view of 27 long groups makes the cells it shows, not every
    // cell of the groups near its top (before: 1,908 of 5,000 cells, every line laid out at a zero cell width).
    function test_aViewMadeBeforeItsSizeMakesWhatItShows() {
        fill(27, 185);
        const view = createTemporaryObject(viewComponent, test);
        verify(view !== null);
        waitForRendering(view);
        verify(listing.made > 0, "cells were made");
        verify(listing.made < 400, "cells made: " + listing.made);
    }

    // Of 600 groups only the ones near the view are made: a far group's header does not exist until it is scrolled to,
    // then its cells are made.
    function test_onlyTheSectionsNearTheViewAreMade() {
        fill(600, 3);
        const view = createTemporaryObject(viewComponent, test);
        verify(view !== null);
        waitForRendering(view);
        const last = String.fromCharCode(0x4E00 + 599);
        verify(findText(view, String.fromCharCode(0x4E00)) !== null, "the first group's header");
        compare(findText(view, last), null, "the last group is not made");
        verify(listing.made < 100, "cells made: " + listing.made);
        const flick = view.flick;
        flick.contentY = flick.contentHeight - flick.height;
        waitForRendering(view);
        tryVerify(() => findText(view, last) !== null, 2000, "the last group's header once scrolled to");
        tryVerify(() => listing.asked[listing.count - 1] === true, 2000, "and its cells");
        compare(findText(view, String.fromCharCode(0x4E00)), null, "the first group is gone");
    }

    // Show All lays a made group out in full; the keyboard's reveal reaches a group that was not made.
    function test_showAllAndRevealStillWork() {
        fill(40, 30);
        const view = createTemporaryObject(viewComponent, test);
        verify(view !== null);
        waitForRendering(view);
        const first = String.fromCharCode(0x4E00);
        view.setExpanded(first, true);
        waitForRendering(view);
        verify(findText(view, "Show Less") !== null, "the first group in full");
        tryVerify(() => listing.asked[29] === true, 2000, "its last item made");
        view.setExpanded(first, false);
        // The last item of the last group: the page goes down and the line along.
        view.reveal(listing.count - 1);
        waitForRendering(view);
        tryVerify(() => listing.asked[listing.count - 1] === true, 2000, "the revealed item is made");
    }

    // Every MouseArea of the cells that can drag (left and right buttons, a drag target).
    function dragAreas(item: Item): var {
        const found = [];
        const stack = [item];
        while (stack.length) {
            const it = stack.pop();
            if (it.drag !== undefined && it.acceptedButtons === (Qt.LeftButton | Qt.RightButton))
                found.push(it);
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return found;
    }

    // Nothing is dragged out of the Applications location (read-only: the permission refusal of Finder); a folder of files
    // lets its cells drag.
    function test_nothingIsDraggedOutOfApplications() {
        fill(3, 4);
        const files = createTemporaryObject(viewComponent, test);
        verify(files !== null);
        waitForRendering(files);
        const filesAreas = dragAreas(files);
        verify(filesAreas.length > 0, "cells that can drag were found");
        verify(filesAreas.some(a => a.drag.target !== null), "a folder of files drags");
        files.destroy();
        listing.isApplications = true;
        const apps = createTemporaryObject(viewComponent, test);
        verify(apps !== null);
        waitForRendering(apps);
        const appAreas = dragAreas(apps);
        verify(appAreas.length > 0, "cells that can drag were found in Applications too");
        verify(appAreas.every(a => a.drag.target === null), "no cell of Applications drags");
        listing.isApplications = false;
    }

    // In the list view too, a name that starts with a right-to-left letter keeps to the left edge (integrator nested pass of
    // step 5c, NIT).
    function test_aRightToLeftNameStartsAtTheLeftInTheList() {
        listing.groupBy = 0;
        fill(1, 2);
        listing.groups = [];
        listing.setProperty(0, "name", "\u05e9\u05dc\u05d5\u05dd.txt");
        const list = createTemporaryObject(listComponent, test);
        verify(list !== null);
        waitForRendering(list);
        const stack = [list];
        let label = null;
        while (stack.length && !label) {
            const it = stack.pop();
            if (it.effectiveHorizontalAlignment !== undefined && String(it.text).indexOf("\u05e9") >= 0 && it.visible)
                label = it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        verify(label !== null, "the name's label");
        compare(label.effectiveHorizontalAlignment, Text.AlignLeft);
        listing.groupBy = 1;
    }

    // The same for the list view: its rows drag in a folder of files and not out of Applications.
    function test_nothingIsDraggedOutOfApplicationsInTheList() {
        listing.groupBy = 0;
        fill(1, 6);
        listing.groups = [];
        const files = createTemporaryObject(listComponent, test);
        verify(files !== null);
        waitForRendering(files);
        const filesAreas = dragAreas(files);
        verify(filesAreas.length > 0, "rows that can drag were found");
        verify(filesAreas.some(a => a.drag.target !== null), "a folder of files drags");
        files.destroy();
        listing.isApplications = true;
        const apps = createTemporaryObject(listComponent, test);
        verify(apps !== null);
        waitForRendering(apps);
        const appAreas = dragAreas(apps);
        verify(appAreas.length > 0, "rows that can drag were found in Applications too");
        verify(appAreas.every(a => a.drag.target === null), "no row of Applications drags");
        listing.isApplications = false;
        listing.groupBy = 1;
    }
}
