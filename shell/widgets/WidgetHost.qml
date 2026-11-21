pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Grassfield.Ui
import "Placements.js" as Placements

// Renders one widget of a given size in a rounded tile (widgets/1 host). `entry` is a placement
// {uid, id, size}; the tile is sized from the cell edge and gap (the Center and the desktop use
// different cells). Right click, the Menu key or Shift+F10 ask for the widget's context menu;
// Delete removes the widget.
FocusScope {
    id: root

    required property var entry
    property real cell: Tokens.widgetCell
    property real gap: Tokens.widgetGap
    // False while the tile is not shown: widgets stop their timers (WidgetBase.active).
    property bool active: true
    // Inside a panel the tile is a flat fill; on the desktop it is the frosted material.
    property bool flat: false
    // Pointer interaction is off for gallery previews.
    property bool interactive: true

    readonly property string size: entry.size
    readonly property string widgetId: entry.id
    readonly property var footprint: Placements.px(size, cell, gap)
    readonly property WidgetBase widget: loader.item as WidgetBase
    readonly property bool hovered: hover.hovered
    // The area of the output the tile's glass is judged over (Material.backdropRect): a host whose list scrolls or slides the
    // tile sets it (the Notifications column); empty: measured where the tile is laid out and again whenever the tile moves.
    property alias backdropRect: tileGlass.backdropRect

    // (x, y) in this item's coordinates; keyboard requests use the center.
    signal menuRequested(real x, real y)
    signal removeRequested
    // Any press on the tile (desktop: the desktop becomes the active surface).
    signal pressed

    width: footprint.w
    height: footprint.h
    // The tile's Material does not hear its host move it (a drag, a new place): measured again then (audit B-13).
    onXChanged: Qt.callLater(tileGlass.measureRect)
    onYChanged: Qt.callLater(tileGlass.measureRect)
    activeFocusOnTab: interactive
    Accessible.role: Accessible.Grouping
    Accessible.name: qsTr("%1 widget, %2").arg(Registry.title(widgetId)).arg(Registry.sizeLabel(size))
    Accessible.description: qsTr("Press the Menu key for options")
    Accessible.focusable: interactive

    Keys.onPressed: event => {
        if (!root.interactive)
            return;
        if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
            root.menuRequested(root.width / 2, root.height / 2);
            event.accepted = true;
        } else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
            root.removeRequested();
            event.accepted = true;
        }
    }

    // Near-opaque glass (ADR-0024 section 2: the widgets' class, 0.92; ADR-0039 step 22).
    Material {
        id: tileGlass
        glassClass: "widgets"
        anchors.fill: parent
        visible: !root.flat
        radius: Tokens.widgetRadius
        shadowEnabled: true
    }

    Rectangle {
        anchors.fill: parent
        visible: root.flat
        radius: Tokens.widgetRadius
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity / 2)
        // One device pixel at every scale (UI audit 2026-11-05 U37).
        border.width: 1 / Math.max(1, Screen.devicePixelRatio)
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
    }

    Loader {
        id: loader
        anchors.fill: parent
        asynchronous: false
        source: Registry.source(root.widgetId)
        onLoaded: {
            if (item === null)
                return;
            root.applyHostApi();
        }
    }

    function applyHostApi(): void {
        const w = root.widget;
        if (!w)
            return;
        w.size = Qt.binding(() => root.size);
        w.active = Qt.binding(() => root.active);
        // A gallery preview is the only host without pointer interaction.
        w.preview = Qt.binding(() => !root.interactive);
    }

    // A widget that failed to load shows nothing but its name (never a blank tile).
    WidgetLabel {
        anchors.centerIn: parent
        width: parent.width - 2 * Tokens.spacingLg
        horizontalAlignment: Text.AlignHCenter
        visible: loader.status === Loader.Error
        text: Registry.title(root.widgetId)
        color: Appearance.colors.textSecondary
    }

    // The shared ring outside the widget, after a key only (ADR-0039 step 7).
    KeyFocus {
        id: hostFocus
    }

    FocusRing {
        shapeRadius: Tokens.widgetRadius
        visible: hostFocus.active && root.interactive
    }

    TapHandler {
        enabled: root.interactive
        acceptedButtons: Qt.RightButton
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: eventPoint => {
            root.forceActiveFocus();
            root.menuRequested(eventPoint.position.x, eventPoint.position.y);
        }
    }

    HoverHandler {
        id: hover
        enabled: root.interactive
    }

    // Passive: reports any press without taking the grab from the handlers above or from drags.
    PointHandler {
        enabled: root.interactive
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onActiveChanged: if (active)
            root.pressed()
    }
}
