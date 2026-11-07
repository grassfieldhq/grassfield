pragma ComponentBehavior: Bound
import QtQuick
import "MenuNav.js" as MenuNav
import "MenuPlace.js" as MenuPlace

// macOS-style menu on the frosted material. The host window supplies the blur region (see Material).
// model: [{id, text, name?, shortcut?, detail?, iconName?, glyph?, enabled?, checked?, destructive?, separator?, header?,
//          submenu?: [...], alternate?: {...}}]
// name: an item's name put in place of text's "%1", shortened in its middle to menu.nameMaxWidth (MenuItem.name).
// glyph: a tiling glyph ({zones, own}, MenuItem) in the icon's place. header: a section title row (text only, never selected).
// alternate: the row shown instead while Alt is held (macOS Option alternates: Window > Move & Resize > Arrange), in this
// menu and in its submenus.
// A row may also be a swatch row (SwatchRow): {id, swatches: [{id, color, name, state}], caption?, enabled?, accessibleName?};
// choosing a swatch activates the swatch object itself (its own id).
// Keyboard: Up/Down/Home/End move, Return/Space activate, Right opens a submenu, Left closes it, Esc closes; on a
// swatch row Left/Right move between the swatches.
FocusScope {
    id: root

    property var model: []
    property int currentIndex: -1
    // The swatch under the keyboard cursor when the current row is a swatch row.
    property int swatchIndex: 0
    property bool isSubmenu: false
    // Whether Alt (Option) is down, live while the menu has the keyboard (a host shows its Option variants, macOS Dock menu).
    // A submenu does not accept the Alt events, so they reach the top-level menu through the item tree.
    property bool altHeld: false
    // Alt held in the menu that opened this submenu (a submenu opened by the pointer never has the keyboard).
    property bool inheritedAlt: false
    readonly property bool alternatesShown: root.altHeld || root.inheritedAlt
    // The rows as shown: each row's alternate while Alt is held.
    readonly property var displayModel: (root.model || []).map(item => root.alternatesShown && item && item.alternate ? item.alternate : item)
    property string accessibleName: ""
    // Index of the row whose submenu is open, -1 if none.
    property int openIndex: -1
    // Optional area that submenus stay inside (an app window's menu layer): a submenu that would cross its right edge
    // opens to the left of the menu, and one that would cross its bottom edge moves up. null: no limit.
    property Item bounds: null
    // The open submenu (null when none): a host sized to its own window (a PopupWindow) grows to include it and gives
    // it a blur region of its own.
    readonly property Item submenuItem: submenuLoader.item as Item
    // Size of the menu together with its open submenus (no bounds: they open to the right and below), for that host.
    // Not childrenRect: reading it inside the host's binding re-enters the binding (binding loop on implicitWidth).
    readonly property size extent: {
        const sub = submenuLoader.item as PopupMenu;
        return Qt.size(Math.max(width, sub ? submenuLoader.x + sub.extent.width : 0), Math.max(height, sub ? submenuLoader.y + sub.extent.height : 0));
    }

    // A leaf item was chosen; `byPointer`: by a click or a release over its row (false: Return or Space). A host that opens
    // a popup for the item passes it on (the shell's Popups.withPointer), so that a ring shows on open after a key only.
    signal activated(var item, bool byPointer)
    // Esc on the top-level menu.
    signal closeRequested
    // Right on a row without a submenu (also inside a submenu) or Left in the top-level menu: the menu bar opens the
    // next (+1) or previous (-1) title's menu (macOS). Other hosts ignore it.
    signal menuStepRequested(int direction)

    readonly property Item surface: material

    // The least width (a pop-up button's list covers its button: ComboBox sets it).
    property real minimumWidth: Tokens.menuMinWidth
    // Widest row; a Column sizes by width, not implicitWidth, so rows report through measure().
    property real rowsWidth: 0

    // Whole pixels: the menu's right edge, its rim and the right-aligned shortcuts stay sharp. Never wider than menu.maxWidth: a
    // longer label is shortened in its middle (MenuItem; UI audit 2026-11-05 U10).
    width: Math.ceil(Math.max(root.minimumWidth, Math.min(Tokens.menuMaxWidth, rowsWidth + 2 * Tokens.menuPadding)))
    height: column.implicitHeight + 2 * Tokens.menuPadding
    activeFocusOnTab: true
    Accessible.role: Accessible.PopupMenu
    Accessible.name: root.accessibleName

    function measure(): void {
        let widest = 0;
        for (let i = 0; i < rows.count; i++) {
            const row = rows.itemAt(i);
            if (row)
                widest = Math.max(widest, row.implicitWidth);
        }
        rowsWidth = widest;
    }

    onDisplayModelChanged: Qt.callLater(measure)

    // Per row: whether the menu holds a checkable row, so that every label starts after the check column (macOS: the check
    // hangs in a fixed leading column). A row is checkable when its model entry has a `checked` field.
    readonly property var checkColumns: {
        // The check sits in a leading column that the whole menu keeps (macOS): once any row is checkable, every label of the
        // menu starts after that column, so a checked window title lines up with Minimize, Zoom and the other rows.
        const out = [];
        const m = root.displayModel;
        const any = m.some(item => item && item.checked !== undefined);
        for (let i = 0; i < m.length; i++)
            out[i] = any && !(m[i] && m[i].separator);
        return out;
    }

    function closeSubmenu(): void {
        openIndex = -1;
        root.forceActiveFocus();
    }

    // `byKey`: opened with the keyboard, so its first row is highlighted (macOS); opened by the pointer it has no highlight
    // until the pointer or a key selects a row.
    property bool submenuByKey: false

    function openSubmenuAt(index: int, focusIt: bool, byKey: bool): void {
        submenuByKey = byKey;
        openIndex = index;
        if (focusIt)
            Qt.callLater(() => {
                if (submenuLoader.item)
                    (submenuLoader.item as Item).forceActiveFocus();
            });
    }

    // The pointer chose the row (a click, a release over it).
    function activateIndex(index: int): void {
        const item = root.displayModel[index];
        if (!MenuNav.selectable(item))
            return;
        if (MenuNav.hasSubmenu(item))
            openSubmenuAt(index, true, false);
        else if (MenuNav.hasSwatches(item))
            root.activateSwatch(index, root.swatchIndex, true);
        else
            root.activated(item, true);
    }

    function activateSwatch(index: int, swatch: int, byPointer: bool): void {
        const item = root.displayModel[index];
        if (MenuNav.selectable(item) && MenuNav.hasSwatches(item) && swatch >= 0 && swatch < item.swatches.length)
            root.activated(item.swatches[swatch], byPointer);
    }

    // ---- Pointer relay (macOS press, drag, release) ----
    // The pointer is held by another surface (the menu bar: its implicit grab, while the button that opened this menu is
    // down), so the rows get no pointer events of their own. That surface reports the pointer here, in the coordinates of
    // this menu's window (scene), and the menu does what hovering and clicking would do.

    // True when the point is inside this menu or inside its open submenus.
    function containsPoint(x: real, y: real): bool {
        const p = root.mapFromItem(null, x, y);
        if (p.x >= 0 && p.y >= 0 && p.x < root.width && p.y < root.height)
            return true;
        const sub = submenuLoader.item as PopupMenu;
        return sub ? sub.containsPoint(x, y) : false;
    }

    // Index of the selectable row of this menu under the point, -1 for none (a separator, a disabled row, outside).
    function rowAt(x: real, y: real): int {
        const p = root.mapFromItem(null, x, y);
        for (let i = 0; i < rows.count; i++) {
            const row = rows.itemAt(i);
            if (!row || !MenuNav.selectable(root.displayModel[i]))
                continue;
            const q = row.mapFromItem(root, p.x, p.y);
            if (q.x >= 0 && q.y >= 0 && q.x < row.width && q.y < row.height)
                return i;
        }
        return -1;
    }

    // Highlights the row under the point like a hover (a submenu row opens its submenu, a plain row closes an open one) and
    // follows the pointer into an open submenu. Off every row the highlight clears, except on the row whose submenu is open.
    function trackPointer(x: real, y: real): void {
        const sub = submenuLoader.item as PopupMenu;
        if (sub && sub.containsPoint(x, y)) {
            sub.trackPointer(x, y);
            return;
        }
        const i = root.rowAt(x, y);
        if (i < 0) {
            if (root.openIndex < 0)
                root.currentIndex = -1;
            return;
        }
        root.currentIndex = i;
        if (MenuNav.hasSubmenu(root.displayModel[i])) {
            if (root.openIndex !== i)
                root.openSubmenuAt(i, false, false);
        } else if (root.openIndex !== -1) {
            root.openIndex = -1;
        }
    }

    // The button was released at the point: the row under it runs (a submenu row opens its submenu and the menu stays open).
    // Returns false, and does nothing, when the point is on no selectable row (or on a swatch row): the menu stays open.
    function releasePointer(x: real, y: real): bool {
        const sub = submenuLoader.item as PopupMenu;
        if (sub && sub.containsPoint(x, y))
            return sub.releasePointer(x, y);
        const i = root.rowAt(x, y);
        if (i < 0 || MenuNav.hasSwatches(root.displayModel[i]))
            return false;
        root.currentIndex = i;
        root.activateIndex(i);
        return true;
    }

    // Entering a row with the keyboard starts on its first swatch.
    onCurrentIndexChanged: root.swatchIndex = 0

    function keyName(key: int): string {
        switch (key) {
        case Qt.Key_Down:
            return "down";
        case Qt.Key_Up:
            return "up";
        case Qt.Key_Left:
            return "left";
        case Qt.Key_Right:
            return "right";
        case Qt.Key_Return:
        case Qt.Key_Enter:
            return "return";
        case Qt.Key_Space:
            return "space";
        case Qt.Key_Escape:
            return "escape";
        case Qt.Key_Home:
            return "home";
        case Qt.Key_End:
            return "end";
        }
        return "";
    }

    // The Alt key itself decides on its own press and release (whether a toolkit counts a modifier's own press in `modifiers`
    // varies); any other key reports the modifiers as they are.
    Keys.onReleased: event => {
        root.altHeld = event.key === Qt.Key_Alt ? false : (event.modifiers & Qt.AltModifier) !== 0;
    }

    Keys.onPressed: event => {
        root.altHeld = event.key === Qt.Key_Alt || (event.modifiers & Qt.AltModifier) !== 0;
        const name = root.keyName(event.key);
        if (name === "")
            return;
        event.accepted = true;
        const result = MenuNav.handleKey(root.displayModel, root.currentIndex, name, root.isSubmenu);
        root.currentIndex = result.index;
        switch (result.action) {
        case "activate":
            if (MenuNav.hasSwatches(root.displayModel[root.currentIndex]))
                root.activateSwatch(root.currentIndex, root.swatchIndex, false);
            else
                root.activated(root.displayModel[root.currentIndex], false);
            break;
        case "swatchPrevious":
            root.swatchIndex = MenuNav.stepSwatch(root.displayModel[root.currentIndex], root.swatchIndex, -1);
            break;
        case "swatchNext":
            root.swatchIndex = MenuNav.stepSwatch(root.displayModel[root.currentIndex], root.swatchIndex, 1);
            break;
        case "openSubmenu":
            root.openSubmenuAt(root.currentIndex, true, true);
            break;
        case "close":
            root.closeRequested();
            break;
        case "closeSubmenu":
            // Handled by the parent menu through submenuLoader.
            root.closeRequested();
            break;
        case "nextMenu":
            root.menuStepRequested(1);
            break;
        case "previousMenu":
            root.menuStepRequested(-1);
            break;
        }
    }

    // The menu's glass as drawn, for a piece of it outside the shape (the Dock menu's tail, ADR-0039 step 22).
    readonly property color glassFill: material.fillColor

    Material {
        id: material
        glassClass: "menu"
        anchors.fill: parent
        radius: Tokens.radiusMenu
    }

    Column {
        id: column
        x: Tokens.menuPadding
        y: Tokens.menuPadding
        width: root.width - 2 * Tokens.menuPadding

        Repeater {
            id: rows
            model: root.displayModel
            onItemAdded: root.measure()

            delegate: Item {
                id: row

                required property var modelData
                required property int index

                width: column.width
                implicitWidth: loader.item ? (loader.item as Item).implicitWidth : 1
                onImplicitWidthChanged: root.measure()
                height: loader.item ? (loader.item as Item).implicitHeight : 0

                Loader {
                    id: loader
                    width: row.width
                    sourceComponent: row.modelData.separator ? separatorComponent : row.modelData.header ? headerComponent : MenuNav.hasSwatches(row.modelData) ? swatchComponent : itemComponent
                }

                Component {
                    id: separatorComponent
                    MenuSeparator {}
                }

                // A section title, aligned with the labels of the rows below it.
                Component {
                    id: headerComponent
                    MenuHeader {
                        text: row.modelData.text !== undefined ? row.modelData.text : ""
                        checkColumn: root.checkColumns[row.index] === true
                    }
                }

                Component {
                    id: swatchComponent
                    SwatchRow {
                        model: row.modelData.swatches
                        enabled: row.modelData.enabled !== false
                        caption: row.modelData.caption !== undefined ? row.modelData.caption : ""
                        accessibleName: row.modelData.accessibleName !== undefined ? row.modelData.accessibleName : ""
                        currentIndex: root.currentIndex === row.index ? root.swatchIndex : -1
                        onHoveredSwatch: swatch => {
                            if (root.openIndex !== -1)
                                root.openIndex = -1;
                            root.currentIndex = row.index;
                            root.swatchIndex = swatch;
                        }
                        onChosen: swatch => root.activateSwatch(row.index, swatch, true)
                    }
                }

                Component {
                    id: itemComponent
                    MenuItem {
                        text: row.modelData.text !== undefined ? row.modelData.text : ""
                        name: row.modelData.name !== undefined ? row.modelData.name : ""
                        shortcut: row.modelData.shortcut !== undefined ? row.modelData.shortcut : ""
                        detail: row.modelData.detail !== undefined ? row.modelData.detail : ""
                        iconName: row.modelData.iconName !== undefined ? row.modelData.iconName : ""
                        glyph: row.modelData.glyph !== undefined ? row.modelData.glyph : null
                        checked: row.modelData.checked === true
                        destructive: row.modelData.destructive === true
                        enabled: row.modelData.enabled !== false
                        hasSubmenu: MenuNav.hasSubmenu(row.modelData)
                        checkColumn: root.checkColumns[row.index] === true
                        highlighted: root.currentIndex === row.index
                        onHovered: {
                            root.currentIndex = row.index;
                            if (hasSubmenu)
                                root.openSubmenuAt(row.index, false, false);
                            else if (root.openIndex !== -1)
                                root.openIndex = -1;
                        }
                        onClicked: root.activateIndex(row.index)
                    }
                }
            }
        }
    }

    // Submenu position: right of the menu, top aligned with its row; flipped and shifted to stay inside `bounds`.
    function submenuX(width: real): real {
        const right = root.width - Tokens.menuSubmenuOverlap;
        if (!root.bounds)
            return right;
        const origin = root.mapToItem(root.bounds, 0, 0);
        return MenuPlace.submenuX(origin.x, root.width, width, Tokens.menuSubmenuOverlap, root.bounds.width, Tokens.spacingSm);
    }

    function submenuY(rowY: real, height: real): real {
        if (!root.bounds)
            return rowY;
        const origin = root.mapToItem(root.bounds, 0, 0);
        return MenuPlace.submenuY(origin.y, rowY, height, root.bounds.height, Tokens.spacingSm);
    }

    // Submenu. A Loader by URL: a component cannot instantiate its own type directly.
    Loader {
        id: submenuLoader
        readonly property real rowY: {
            const r = rows.itemAt(root.openIndex);
            return r ? r.y : 0;
        }
        x: root.submenuX(submenuLoader.item ? (submenuLoader.item as Item).width : 0)
        y: root.submenuY(submenuLoader.rowY, submenuLoader.item ? (submenuLoader.item as Item).height : 0)
    }

    Binding {
        target: submenuLoader.item
        property: "inheritedAlt"
        value: root.alternatesShown
        when: submenuLoader.item !== null
    }

    Connections {
        target: submenuLoader.item
        ignoreUnknownSignals: true

        function onActivated(item: var, byPointer: bool): void {
            root.activated(item, byPointer);
        }

        function onMenuStepRequested(direction: int): void {
            root.menuStepRequested(direction);
        }

        function onCloseRequested(): void {
            root.closeSubmenu();
        }
    }

    onOpenIndexChanged: {
        const item = root.displayModel[root.openIndex];
        if (root.openIndex >= 0 && MenuNav.hasSubmenu(item))
            submenuLoader.setSource("PopupMenu.qml", {model: item.submenu, isSubmenu: true, currentIndex: root.submenuByKey ? MenuNav.first(item.submenu) : -1, bounds: root.bounds});
        else
            submenuLoader.source = "";
    }
}
