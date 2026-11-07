import QtQuick
import QtTest
import "../../apps/files/qml"

// grassfield-files gallery view (apps/files/qml/GalleryView.qml) on a stand-in listing: the first item is shown once
// the folder is listed, the arrow keys move along the strip (Nav.stripMove), the large preview follows the current
// item, Space and Return reach the tab, and the info panel follows its preference.
TestCase {
    id: test
    name: "FilesGallery"
    when: windowShown
    // Shown: pointer events and drags reach only visible items.
    visible: true
    width: 900
    height: 520

    // The FolderModel API the gallery uses, on a ListModel with the same roles.
    ListModel {
        id: listing

        property int currentRow: -1
        property int selectedCount: 0
        property bool loading: false
        property string error: ""
        property url url: "file:///sandbox"
        property var largeLive: ({})
        property bool isApplications: false

        signal revealRequested(int row, bool rename)

        function select(row: int, modifiers: int): void {
            listing.currentRow = row;
            for (let i = 0; i < listing.count; i++)
                listing.setProperty(i, "selected", i === row);
            listing.selectedCount = row >= 0 ? 1 : 0;
        }
        // The preview pane's reads (PreviewPane.qml).
        function isSelected(row: int): bool {
            return row >= 0 && row === listing.currentRow;
        }
        function selectedRows(): var {
            return listing.currentRow >= 0 ? [listing.currentRow] : [];
        }
        function urlAt(row: int): url {
            return listing.get(row).url;
        }
        function info(row: int): var {
            // Nothing selected: the shown folder.
            if (row < 0)
                return {name: "sandbox", kind: "Folder", sizeText: "", isDir: true, created: "", modified: "", accessed: "", where: "/"};
            return {name: listing.get(row).name, kind: "Plain text document", sizeText: "1 KB", isDir: false, created: "Today at 10:00", modified: "Today at 11:00", accessed: "", where: "/sandbox"};
        }
        function requestPreview(row: int, large: bool): void {
            if (large) {
                const live = listing.largeLive;
                                live[listing.get(row).url] = true;
                listing.largeLive = live;
            }
        }
        function cancelPreview(url: url, large: bool): void {
            if (large) {
                const live = listing.largeLive;
                delete live[url];
                listing.largeLive = live;
            }
        }
        function selectedUrls(): var {
            return listing.currentRow >= 0 ? [listing.get(listing.currentRow).url] : [];
        }

        // Dynamic roles keep tagColors a plain list (as FolderModel's role), not a nested ListModel.
        dynamicRoles: true

        function row(name: string, isDir: bool, canPreview: bool, tagColors: var): var {
            return {name: name, url: "file:///sandbox/" + name, iconName: "", thumbnail: "", largeThumbnail: "", emblem: "", selected: false, isDir: isDir,
                    canPreview: canPreview, hidden: false, cut: false, dimmed: false, tagColors: tagColors, folderColor: "", folderGlyph: ""};
        }

        Component.onCompleted: {
            listing.append(listing.row("alpha.png", false, true, [0, 4]));
            listing.append(listing.row("beta.txt", false, false, []));
            listing.append(listing.row("gamma", true, false, [6]));
            listing.append(listing.row("delta.pdf", false, true, []));
            listing.append(listing.row("epsilon.md", false, false, [1, 2, 3, 5]));
        }
    }

    // The BrowserTab API the gallery uses. handleViewKey keeps BrowserTab's mapping for the keys tested here.
    QtObject {
        id: tabItem

        property string searchText: ""
        property int activated: -1
        property int renamed: -1
        property int glances: 0
        property var win: null
        property var app: QtObject {
            property bool galleryInfo: true
            property var typedTags: []
            property var removedTags: []

            function rotatableImages(urls: var): var {
                return [];
            }
            function tagsUnavailable(urls: var): string {
                return "";
            }
            function addTypedTag(urls: var, text: string): void {
                typedTags = typedTags.concat([text]);
            }
            function removeTag(urls: var, tag: string): void {
                removedTags = removedTags.concat([tag]);
            }

            function baseNameLength(name: string, isDir: bool): int {
                return name.length;
            }
            function uriList(urls: var): string {
                return "";
            }
            function isRecents(url: url): bool {
                return String(url).startsWith("grassfield-recents:");
            }
        }

        // BrowserTab's drag bracket: dragStarted before the system drag, dragFinished from its end.
        property var dragEvents: []
        function dragStarted(): void {
            tabItem.dragEvents = tabItem.dragEvents.concat(["started"]);
        }
        function dragFinished(dropAction: int): void {
            tabItem.dragEvents = tabItem.dragEvents.concat(["finished"]);
        }

        function focusView(): void {
            gallery.focusView();
        }
        function isRenaming(model: var, url: url): bool {
            return false;
        }
        function startRename(model: var, row: int): void {
        }
        function activate(row: int, model: var): void {
            tabItem.activated = row;
        }
        function contextMenu(model: var, row: int, x: real, y: real, keyboard: bool): void {
        }
        function dropUrls(urls: var, destination: url, model: var): void {
        }
        function handleViewKey(event: var, model: var, mover: var): void {
            const names = {};
            names[Qt.Key_Left] = "left";
            names[Qt.Key_Right] = "right";
            names[Qt.Key_Up] = "up";
            names[Qt.Key_Down] = "down";
            names[Qt.Key_Home] = "home";
            names[Qt.Key_End] = "end";
            const name = names[event.key];
            if (name !== undefined) {
                const next = mover(name);
                if (next >= 0)
                    model.select(next, 0);
                event.accepted = true;
            } else if (event.key === Qt.Key_Space) {
                tabItem.glances++;
                event.accepted = true;
            } else if (event.key === Qt.Key_Return) {
                // BrowserTab: Return renames the selected item (macOS, docs/specs/files.md F-4).
                tabItem.renamed = model.currentRow;
                event.accepted = true;
            }
        }
    }

    GalleryView {
        id: gallery
        anchors.fill: parent
        tab: tabItem
        model: listing
    }

    // A drag from elsewhere (Drag.Internal: delivered within this window, like the system drag reaches the DropAreas).
    Item {
        id: incoming
        width: 4
        height: 4
        Drag.keys: ["text/uri-list"]
        Drag.dragType: Drag.Internal
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
        Drag.hotSpot.x: 2
        Drag.hotSpot.y: 2
    }

    function init(): void {
        tabItem.app.galleryInfo = true;
        listing.select(0, 0);
        gallery.focusView();
        waitForRendering(gallery);
    }

    function test_showsTheFirstItemOnceListed() {
        // ensureCurrent ran when the view was created: the first item is current and the strip has the focus.
        verify(listing.currentRow >= 0);
        listing.currentRow = -1;
        gallery.ensureCurrent();
        compare(listing.currentRow, 0);
    }

    function test_arrowsMoveAlongTheStrip() {
        keyClick(Qt.Key_Right);
        compare(listing.currentRow, 1);
        keyClick(Qt.Key_Right);
        keyClick(Qt.Key_Right);
        compare(listing.currentRow, 3);
        keyClick(Qt.Key_Up);
        keyClick(Qt.Key_Down);
        compare(listing.currentRow, 3, "Up/Down do not move in the strip");
        keyClick(Qt.Key_End);
        compare(listing.currentRow, 4);
        keyClick(Qt.Key_Right);
        compare(listing.currentRow, 4, "the last item stays current");
        keyClick(Qt.Key_Left);
        compare(listing.currentRow, 3);
        keyClick(Qt.Key_Home);
        compare(listing.currentRow, 0);
        keyClick(Qt.Key_Left);
        compare(listing.currentRow, 0);
    }

    function test_spaceAndReturnReachTheTab() {
        const before = tabItem.glances;
        keyClick(Qt.Key_Right);
        keyClick(Qt.Key_Space);
        compare(tabItem.glances, before + 1);
        keyClick(Qt.Key_Return);
        compare(tabItem.renamed, 1, "Return renames the shown item");
    }

    function test_largePreviewFollowsTheCurrentItem() {
        // The ListView creates and releases its pages on its own schedule (what earlier tests scrolled over, when the
        // cache is trimmed), so assert the state the preview logic must reach rather than the moment a request is made:
        // a page holds a large-thumbnail request while it exists and cancels it when it goes away (largeLive).
        const delta = listing.get(3).url;
        keyClick(Qt.Key_Home);
        for (let i = 0; i < 3; i++)
            keyClick(Qt.Key_Right);
        compare(listing.currentRow, 3);
        // The current page (delta.pdf, previewable) always exists, so it must hold its gallery-size thumbnail.
        tryVerify(() => listing.largeLive[delta] !== undefined);
        keyClick(Qt.Key_End);
        waitForRendering(gallery);
        compare(gallery.info.name, "epsilon.md");
        // The previous page stays in the view's cache next to the new current one: its request is still held.
        tryVerify(() => listing.largeLive[delta] !== undefined);
    }

    function test_tagsFieldAddsWhatWasTyped() {
        const input = findChild(gallery, "previewTagInput");
        verify(input !== null);
        input.forceActiveFocus();
        input.text = "  Work ";
        keyClick(Qt.Key_Return);
        compare(tabItem.app.typedTags, ["  Work "], "the typed text goes to FilesApp, which resolves colour names");
        compare(input.text, "", "the field empties once the tag is added");
        keyClick(Qt.Key_Return);
        compare(tabItem.app.typedTags.length, 1, "an empty field adds nothing");
        keyClick(Qt.Key_Escape);
        verify(!input.activeFocus, "Escape returns to the view");
    }

    // Recents is a list, not a place (Finder): a drag over it is refused (no target, the drop does nothing), a folder takes it.
    function test_recentsRefusesDrops() {
        const over = gallery.mapToItem(test, 100, 100);
        for (const where of [{url: "grassfield-recents:/", accepted: false}, {url: "file:///sandbox", accepted: true}]) {
            listing.url = where.url;
            incoming.x = over.x;
            incoming.y = over.y;
            incoming.Drag.active = true;
            // Moves of an internal drag are delivered from the event loop.
            incoming.x += 1;
            wait(20);
            if (where.accepted)
                verify(incoming.Drag.target !== null, "a folder's background takes the drag");
            else
                compare(incoming.Drag.target, null, "Recents takes no drag");
            const action = incoming.Drag.drop();
            if (!where.accepted)
                compare(action, Qt.IgnoreAction, "the drop on Recents is refused");
            incoming.Drag.active = false;
        }
        listing.url = "file:///sandbox";
    }

    // A drag from the strip brackets the system drag with the tab's dragStarted and dragFinished (BrowserTab keeps the
    // view that started it alive until then: Nav.shownView).
    function test_aDragFromTheStripIsBracketed() {
        tabItem.dragEvents = [];
        const cell = gallery.rowPosition(listing, 1);
        const local = test.mapFromItem(null, cell.x, cell.y);
        mousePress(test, local.x, local.y);
        for (let i = 1; i <= 6; i++)
            mouseMove(test, local.x + i * 8, local.y);
        mouseRelease(test, local.x + 48, local.y);
        tryVerify(() => tabItem.dragEvents.length >= 1, 2000, "the drag started");
        compare(tabItem.dragEvents[0], "started");
        // Offscreen, the platform drag ends at once (no drop).
        tryVerify(() => tabItem.dragEvents.indexOf("finished") > 0, 2000, "and ended after it started");
    }

    function test_infoPanelFollowsItsPreference() {
        compare(gallery.info.name, "alpha.png");
        verify(gallery.showInfo);
        tabItem.app.galleryInfo = false;
        verify(!gallery.showInfo);
        tabItem.app.galleryInfo = true;
        verify(gallery.showInfo);
    }

    // Every MouseArea of the strip that can drag (left and right buttons).
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

    // Nothing is dragged out of the Applications location (read-only); in a folder of files the strip's items drag.
    function test_nothingIsDraggedOutOfApplications() {
        waitForRendering(gallery);
        const files = dragAreas(gallery);
        verify(files.length > 0, "items that can drag were found");
        verify(files.some(a => a.drag.target !== null), "a folder of files drags");
        listing.isApplications = true;
        tryVerify(() => dragAreas(gallery).every(a => a.drag.target === null), 2000, "no item of Applications drags");
        verify(dragAreas(gallery).length > 0);
        listing.isApplications = false;
        tryVerify(() => dragAreas(gallery).some(a => a.drag.target !== null), 2000, "dragging is back");
    }
}
