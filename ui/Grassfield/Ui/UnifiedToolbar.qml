import QtQuick
import "WindowActions.js" as Actions

// The toolbar row of a Grassfield app window (ADR-0015): the window lights, the window title and the app's toolbar items
// in one bar, as in a macOS toolbar window. The app declares the style and places its items; it never draws or wires the
// lights. Place it at the top of the window; it takes the width of its parent.
//
// style "unified": a 52-pt row, the lights' first centre at 26 / 26, the title left-aligned and bold after the
//   leading items. A window whose sidebar holds the lights puts one toolbar over the sidebar (showControls, no title,
//   no items) and one over the content (showControls false).
// style "titlebar": a 32-pt row with the lights and a centred title (Get Info, Customize Folder).
//
// Items: `leading` (after the lights and before the title), `trailing` (right-aligned) and, for a layout of its own, the
// default property (a layer over the whole toolbar). Empty
// space is the window's drag area: a drag starts the compositor's interactive move (xdg_toplevel.move) and a double-click
// does what `doubleClickAction` says (`windows.titlebarDoubleClick`: fill, the default, or zoom: the zoom request, which the
// compositor plugin turns into Fill, ADR-0036 D78; minimize or none).
Item {
    id: root

    // The QtQuick Window the toolbar belongs to.
    property var window: null
    // "unified" or "titlebar".
    property string style: "unified"
    property string title: ""
    property bool showTitle: true
    // Draw the three lights here (false where another toolbar over the sidebar holds them).
    property bool showControls: true
    // windows.titlebarDoubleClick of grassfield.json: "fill" (the settings default) or "zoom" (both the zoom request),
    // "minimize" or "none"; the apps start from "zoom" until they read the file.
    property string doubleClickAction: "zoom"
    property bool canMinimize: true
    property string accessibleName: qsTr("Toolbar")
    // `leading` (after the lights, before the title) and `trailing` (right-aligned) are rows of items; anything else a host
    // declares goes in `content`, a layer over the whole toolbar for a layout of its own (Preview's two-line title).
    property alias leading: leadingRow.data
    property alias trailing: trailingRow.data
    default property alias content: freeArea.data

    readonly property bool titlebarStyle: root.style === "titlebar"
    readonly property alias controls: lights
    // Left edge of the leading items: after the lights, or the item inset where the lights are elsewhere.
    readonly property real contentStart: root.showControls ? Math.max(lights.contentStart, Tokens.windowItemsInset) : Tokens.windowItemsInset
    // Where the title may start and end (the host reads them to place extra content).
    readonly property real titleStart: leadingRow.x + (leadingRow.children.length > 0 ? leadingRow.width + Tokens.windowItemsGap : 0)
    readonly property real titleEnd: trailingRow.children.length > 0 ? trailingRow.x - Tokens.windowItemsGap : root.width - Tokens.windowItemsInset

    // What a double-click on empty space did last (tests read it; "" before any).
    property string lastDoubleClick: ""

    implicitHeight: root.titlebarStyle ? Tokens.windowTitlebarHeight : Tokens.windowUnifiedHeight
    height: implicitHeight
    Accessible.role: Accessible.ToolBar
    Accessible.name: root.accessibleName

    // A point of the drag area (its coordinates) is on the lights: a press that starts there belongs to the lights, so a
    // drag from a light never moves the window and a double-click on them is not the toolbar's (macOS; client_chrome.sh 7).
    function onLights(x: real, y: real): bool {
        if (!root.showControls || !lights.visible)
            return false;
        const p = lights.mapFromItem(dragArea, x, y);
        return lights.overLights(p.x, p.y);
    }

    // The double-click, also callable by a host (a keyboard route to the same action).
    function doubleClicked(): void {
        root.lastDoubleClick = Actions.doubleClick(root.window, root.doubleClickAction, root.canMinimize);
    }

    // Drag and double-click on the empty space: behind every item, so a press on a control never moves the window.
    Item {
        id: dragArea
        anchors.fill: parent
        z: -1

        DragHandler {
            id: dragHandler
            target: null
            acceptedButtons: Qt.LeftButton
            // Never from a control: a press on a button, a field or a light is that item's (it holds the grab), and a drag
            // that starts there must not take it over and move the window (macOS: a toolbar button tracks the pointer, its
            // click is not lost to a move). Qt's default lets a drag handler take over from items; only empty space moves.
            grabPermissions: PointerHandler.CanTakeOverFromHandlersOfDifferentType | PointerHandler.ApprovesTakeOverByAnything
            // The threshold is Qt's own drag distance; the compositor then follows the pointer (ADR-0015, step 3). A drag
            // that started on a light is the light's (its press, then its release elsewhere: nothing).
            onActiveChanged: {
                if (active && root.window && !root.onLights(dragHandler.centroid.pressPosition.x, dragHandler.centroid.pressPosition.y))
                    root.window.startSystemMove();
            }
        }

        TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: eventPoint => {
                if (!root.onLights(eventPoint.position.x, eventPoint.position.y))
                    root.doubleClicked();
            }
        }
    }

    WindowControls {
        id: lights
        visible: root.showControls && !lights.fullScreen
        window: root.window
        style: root.style
        canMinimize: root.canMinimize
    }

    Item {
        id: freeArea
        anchors.fill: parent
    }

    Row {
        id: leadingRow
        x: root.contentStart
        anchors.verticalCenter: parent.verticalCenter
        spacing: Tokens.windowItemsGap
    }

    Text {
        id: titleText
        textFormat: Text.PlainText
        visible: root.showTitle
        anchors.verticalCenter: parent.verticalCenter
        x: root.titlebarStyle ? Math.max(root.titleStart, (root.width - Math.min(titleText.implicitWidth, root.titleEnd - root.titleStart)) / 2) : root.titleStart
        width: Math.max(0, Math.min(titleText.implicitWidth, root.titleEnd - titleText.x))
        text: root.title
        elide: Text.ElideRight
        // Dimmed while the window is not key (macOS 27; ADR-0039 step 17).
        color: Appearance.looksKey(root.Window.window, root.Window.active) ? Appearance.colors.text : Appearance.withAlpha(Appearance.colors.text, Appearance.inactiveTextOpacity)
        font.family: Appearance.fontFamily
        font.pixelSize: root.titlebarStyle ? Tokens.typographyBodySize : Tokens.windowTitleSize
        font.weight: Tokens.typographyTitleWeight
        Accessible.role: Accessible.Heading
        Accessible.name: text
    }

    Row {
        id: trailingRow
        anchors.right: parent.right
        anchors.rightMargin: Tokens.windowItemsInset
        anchors.verticalCenter: parent.verticalCenter
        spacing: Tokens.windowItemsGap
    }
}
