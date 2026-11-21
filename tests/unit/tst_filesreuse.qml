pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../apps/files/qml"

// grassfield-files views reuse their cells (reuseItems on the icon grid, the list and the columns): scrolled through a large
// folder, the cells scrolled out go to a pool and come back for the rows scrolled in, instead of being destroyed and made
// again. A reused cell shows its new row (name, thumbnail, no rename field of the old one), asks its new row's thumbnail
// exactly once and drops the old row's request; a rename shown by a cell that went to the pool is canceled (RenameField: a
// field taken out of the view cancels).
TestCase {
    id: test
    name: "FilesReuse"
    when: windowShown
    visible: true
    width: 900
    height: 600

    readonly property url picture: Qt.resolvedUrl("../../branding/brandkit-proposal/assets/symbol-black.png")

    // The FolderModel API the views use, on a ListModel with the same roles.
    ListModel {
        id: listing

        property int groupBy: 0
        property var groups: []
        property int currentRow: -1
        property int selectedCount: 0
        property bool loading: false
        property bool isApplications: false
        property bool isFileSearch: false
        property string error: ""
        property url url: "file:///sandbox"
        // Thumbnail requests by row, and the URLs whose request was dropped.
        property var asked: ({})
        property var canceled: []

        signal revealRequested(int row, bool rename)

        function requestPreview(row: int, large: bool): void {
            listing.asked[row] = (listing.asked[row] ?? 0) + 1;
        }
        function cancelPreview(url: url, large: bool): void {
            listing.canceled.push(String(url));
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

    // The BrowserTab API the views read: the item being renamed is `renameUrl`.
    QtObject {
        id: fakeTab

        property string searchText: ""
        property int sortKey: 0
        property bool sortDescending: false
        property string renameUrl: ""
        property int cancels: 0
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
            return fakeTab.renameUrl !== "" && String(url) === fakeTab.renameUrl;
        }
        function cancelRename(): void {
            fakeTab.renameUrl = "";
            fakeTab.cancels++;
        }
        function commitRename(name: string): void {
            fakeTab.renameUrl = "";
        }
        function startRename(model: var, row: int): void {
        }
        function handleViewKey(event: var, model: var, mover: var): void {
        }
        function sortBy(key: int, toggle: bool): void {
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
    }

    Component {
        id: iconComponent
        IconView {
            anchors.fill: parent
            tab: fakeTab
            model: listing
        }
    }

    Component {
        id: listComponent
        FileList {
            anchors.fill: parent
            tab: fakeTab
            model: listing
        }
    }

    // A thumbnail for two rows of three, each its own URL (the same picture): a stale one is told by its source.
    function thumbnailOf(i: int): string {
        return i % 3 === 0 ? "" : String(test.picture) + "?row=" + i;
    }

    function fill(count: int): void {
        listing.clear();
        listing.asked = {};
        listing.canceled = [];
        fakeTab.renameUrl = "";
        fakeTab.cancels = 0;
        for (let i = 0; i < count; i++) {
            listing.append({name: "File " + i, url: "file:///sandbox/f" + i, iconName: "", thumbnail: test.thumbnailOf(i), emblem: "",
                            selected: false, isDir: false, folderColor: "", folderGlyph: "", canPreview: i % 3 !== 0, hidden: false,
                            cut: false, dimmed: false, tagColors: [], modifiedText: "", sizeText: "", kind: "Plain text document"});
        }
    }

    function findItem(item: Item, pred: var): var {
        const stack = [item];
        while (stack.length) {
            const it = stack.pop();
            if (pred(it))
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    // The view's cells (made, live or in the pool): the delegates of its content item.
    function cellsOf(view: var): var {
        const out = [];
        const kids = view.contentItem.children;
        for (let i = 0; i < kids.length; i++) {
            if (kids[i].url !== undefined && kids[i].name !== undefined)
                out.push(kids[i]);
        }
        return out;
    }

    // A cell in view: not in the pool, and within the page.
    function liveCells(view: var): var {
        return cellsOf(view).filter(c => c.pooled !== true && c.y + c.height > view.contentY && c.y < view.contentY + view.height);
    }

    function renameField(cell: Item): var {
        return findItem(cell, i => i.originalName !== undefined && i.committed !== undefined);
    }

    function scrollTo(view: var, y: real): void {
        view.contentY = Math.max(view.originY, Math.min(y, view.contentHeight - view.height + view.originY));
        view.forceLayout();
        wait(0);
    }

    // Every cell in view shows its own row: the name, the thumbnail (no stale picture from the row it showed before) and no
    // rename field unless that row is the one renamed.
    function checkLiveCells(view: var, where: string): void {
        const live = test.liveCells(view);
        verify(live.length > 0, where + ": cells in view");
        for (const c of live) {
            const row = c.row !== undefined ? c.row : c.index;
            const item = listing.get(row);
            compare(String(c.url), item.url, where + ": the cell's row");
            compare(c.name, item.name, where);
            const icon = c.thumbnail === undefined ? null : test.findItem(c, i => i.thumbnail !== undefined && i.iconName !== undefined && i !== c);
            if (icon !== null) {
                compare(icon.thumbnail, item.thumbnail, where + ": row " + row + "'s thumbnail");
                const image = test.findItem(icon, i => i.status !== undefined && i.sourceSize !== undefined);
                compare(String(image.source), item.thumbnail, where + ": the picture asked for is the row's");
                if (item.thumbnail === "")
                    verify(!image.visible, where + ": no picture left from the row shown before (row " + row + ")");
            }
            if (c.canPreview !== undefined)
                compare(listing.asked[row] ?? 0, item.canPreview ? 1 : 0, where + ": row " + row + "'s thumbnail asked once");
            const field = test.renameField(c);
            if (String(c.url) === fakeTab.renameUrl)
                verify(field !== null && field.originalName === item.name, where + ": the renamed row shows its field");
            else
                verify(field === null || !field.visible, where + ": no field on row " + row);
        }
    }

    function test_theIconGridReusesItsCells() {
        fill(3000);
        const view = createTemporaryObject(iconComponent, test);
        verify(view !== null);
        const grid = view.flick;
        verify(grid.reuseItems, "the grid reuses its cells");
        waitForRendering(view);
        tryVerify(() => test.liveCells(grid).length > 0);
        const first = test.liveCells(grid).slice();
        checkLiveCells(grid, "top");

        // A rename on a row in view, then a scroll a page at a time to the end.
        fakeTab.renameUrl = String(first[1].url);
        verify(test.renameField(first[1]) !== null, "the field is shown");
        let made = test.cellsOf(grid).length;
        for (let y = grid.height; y < grid.contentHeight; y += grid.height) {
            scrollTo(grid, y);
            checkLiveCells(grid, "at " + Math.round(y));
            made = Math.max(made, test.cellsOf(grid).length);
        }
        // A pool, not one cell per row: about the page, its cache and the pool (3,000 rows, 9 columns).
        verify(made < 3 * (first.length + 2 * 9 * 2), "cells made for 3,000 rows: " + made);
        const reused = first.filter(c => test.liveCells(grid).indexOf(c) >= 0);
        verify(reused.length > 0, "cells of the first page show the last one");
        // The rows scrolled out before their thumbnail started dropped their request; the rename went with its cell.
        verify(listing.canceled.indexOf("file:///sandbox/f1") >= 0, "row 1's request dropped");
        compare(fakeTab.cancels, 1, "the rename shown by a pooled cell is canceled");
        compare(fakeTab.renameUrl, "");

        // A rename shown by a reused cell, then back to the top: the field goes with that cell, none comes back.
        const shown = test.liveCells(grid)[0];
        fakeTab.renameUrl = String(shown.url);
        checkLiveCells(grid, "renamed at the end");
        scrollTo(grid, 0);
        compare(fakeTab.cancels, 2);
        for (const c of test.liveCells(grid)) {
            const field = test.renameField(c);
            verify(field === null || !field.visible, "no field at the top again");
        }
        verify(test.liveCells(grid).every(c => String(c.url) === listing.get(c.row).url), "the top rows again");
    }

    function test_theListReusesItsRows() {
        fill(3000);
        const view = createTemporaryObject(listComponent, test);
        verify(view !== null);
        const list = test.findItem(view, i => i.reuseItems !== undefined && i.section !== undefined);
        verify(list !== null);
        verify(list.reuseItems, "the list reuses its rows");
        waitForRendering(view);
        tryVerify(() => test.liveCells(list).length > 0);
        const first = test.liveCells(list).slice();
        checkLiveCells(list, "top");
        fakeTab.renameUrl = String(first[2].url);
        verify(test.renameField(first[2]) !== null, "the field is shown");
        for (let y = list.height; y < list.contentHeight; y += list.height) {
            scrollTo(list, y);
            checkLiveCells(list, "at " + Math.round(y));
        }
        verify(test.cellsOf(list).length < 3000 / 4, "rows made for 3,000: " + test.cellsOf(list).length);
        verify(first.some(c => test.liveCells(list).indexOf(c) >= 0), "rows of the first page show the last one");
        compare(fakeTab.cancels, 1, "the rename shown by a pooled row is canceled");
    }
}
