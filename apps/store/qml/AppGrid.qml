pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Apps in columns (a row block of Discover, a category, the search results, Installed: spec SR4, SR6, SR8, SR23): as many
// columns of AppLockups as the width holds at their minimum width, filled row by row, a separator under each but the last
// row. The arrows move between items.
// Virtualized (SU-06): the grid is as tall as all its rows, but only the rows the page shows (and one screen around them)
// have delegates: a GridView the size of the visible part of the page's Flickable, following its scroll, its delegates
// reused. Its model is keyed by app id (KeyedModel) and changed in place: a new list of the same apps (a new snapshot, a
// button's state) creates nothing, and each delegate reads its app by id.
Item {
    id: root

    property var apps: []
    property real minColumnWidth: Tokens.storeLockupMinWidth
    property bool showButtons: true

    signal opened(string id)

    readonly property real columnSpacing: Tokens.storeGridColumnGap
    readonly property int columns: Math.max(1, Math.floor((root.width + root.columnSpacing) / (root.minColumnWidth + root.columnSpacing)))
    readonly property real cellWidth: (root.width - (root.columns - 1) * root.columnSpacing) / root.columns
    readonly property int count: keys.count
    readonly property int rowCount: Math.ceil(keys.count / root.columns)
    // Every row as tall as a lockup with a summary (the tallest kind): the Grid this replaces made each row as tall as its
    // tallest item, which is that height in practice.
    readonly property real rowHeight: probe.implicitHeight
    // The app of each key; the delegates read it (a new list of the same apps changes the bindings, not the delegates).
    property var byKey: ({})
    // The page's Flickable this grid scrolls in (ScrollPage's), found once it has a parent; null: every row is made.
    property Flickable flick: null

    implicitHeight: root.rowCount * root.rowHeight

    onAppsChanged: root.sync()
    Component.onCompleted: {
        root.findFlick();
        root.sync();
    }
    onParentChanged: root.findFlick()

    function sync(): void {
        const map = {};
        const list = [];
        for (const a of root.apps || []) {
            let k = String(a && a.id !== undefined ? a.id : "");
            // An id twice (never expected) keeps both items.
            while (map[k] !== undefined)
                k += "#";
            map[k] = a;
            list.push(k);
        }
        root.byKey = map;
        keys.sync(list);
        root.relayout();
    }

    function findFlick(): void {
        let p = root.parent;
        while (p && !(p as Flickable))
            p = p.parent;
        root.flick = p ? p as Flickable : null;
        root.relayout();
    }

    // The part of the grid the page shows, with one screen above and below: where the view sits and what it shows.
    function relayout(): void {
        const total = root.rowCount * root.rowHeight;
        if (!root.flick || !root.flick.contentItem || total <= 0) {
            view.y = 0;
            view.height = total;
            view.contentY = 0;
            return;
        }
        const offset = root.mapToItem(root.flick.contentItem, 0, 0).y;
        const screen = root.flick.height;
        const top = Math.max(0, Math.min(total, root.flick.contentY - offset - screen));
        const bottom = Math.max(top, Math.min(total, root.flick.contentY - offset + 2 * screen));
        // Whole rows: a delegate never straddles the view's edge.
        const first = Math.floor(top / root.rowHeight) * root.rowHeight;
        view.y = first;
        view.height = Math.max(0, Math.min(total, Math.ceil(bottom / root.rowHeight) * root.rowHeight) - first);
        view.contentY = first;
    }

    function focusItem(index: int): void {
        const i = Math.max(0, Math.min(keys.count - 1, index));
        if (i < 0)
            return;
        // The row in sight first (the page scrolls), then its delegate exists and takes the focus.
        if (root.flick && root.flick.contentItem) {
            const offset = root.mapToItem(root.flick.contentItem, 0, 0).y;
            const rowTop = offset + Math.floor(i / root.columns) * root.rowHeight;
            const viewTop = Tokens.windowUnifiedHeight + Tokens.storeFocusScrollMargin;
            const viewBottom = root.flick.height - Tokens.storeFocusScrollMargin;
            const max = Math.max(0, root.flick.contentHeight - root.flick.height);
            let y = root.flick.contentY;
            if (rowTop + root.rowHeight > y + viewBottom)
                y = rowTop + root.rowHeight - viewBottom;
            if (rowTop < y + viewTop)
                y = rowTop - viewTop;
            root.flick.contentY = Math.max(0, Math.min(max, y));
            root.relayout();
        }
        view.forceLayout();
        const item = view.itemAtIndex(i);
        if (item)
            item.forceActiveFocus(Qt.TabFocusReason);
    }

    // The item of an index while it has a delegate (a test, a caller that moves the focus).
    function itemAt(index: int): Item {
        return view.itemAtIndex(index);
    }

    onWidthChanged: root.relayout()
    onYChanged: root.relayout()
    onRowCountChanged: root.relayout()
    onRowHeightChanged: root.relayout()

    Connections {
        target: root.flick
        function onContentYChanged(): void {
            root.relayout();
        }
        function onHeightChanged(): void {
            root.relayout();
        }
        function onContentHeightChanged(): void {
            root.relayout();
        }
    }

    KeyedModel {
        id: keys
    }

    // The height of a row: a lockup with every line.
    AppLockup {
        id: probe
        visible: false
        width: root.cellWidth
        app: ({id: "", name: "X", summary: "X", icon: "", kind: "repo", repo: "extra", page: false})
        showButton: root.showButtons
        separator: false
    }

    GridView {
        id: view
        x: 0
        width: root.width + root.columnSpacing
        cellWidth: root.cellWidth + root.columnSpacing
        cellHeight: root.rowHeight
        interactive: false
        reuseItems: true
        cacheBuffer: 0
        model: keys
        keyNavigationEnabled: false

        delegate: AppLockup {
            id: lockup
            required property string key
            required property int index
            width: root.cellWidth
            height: root.rowHeight
            // A pooled delegate's key may be gone for a moment: an empty app (still "openable", so a focused item never has
            // activeFocusOnTab taken from it).
            app: root.byKey[lockup.key] || ({id: "", name: "", summary: "", icon: "", kind: "", repo: ""})
            showButton: root.showButtons
            separator: Math.floor(lockup.index / root.columns) < root.rowCount - 1
            onOpened: id => root.opened(id)
            Keys.onLeftPressed: root.focusItem(lockup.index - 1)
            Keys.onRightPressed: root.focusItem(lockup.index + 1)
            Keys.onUpPressed: event => {
                if (lockup.index >= root.columns)
                    root.focusItem(lockup.index - root.columns);
                else
                    event.accepted = false;
            }
            Keys.onDownPressed: event => {
                if (lockup.index + root.columns < keys.count)
                    root.focusItem(lockup.index + root.columns);
                else
                    event.accepted = false;
            }
        }
    }
}
