pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Keyboard.js" as Keyboard

// Keyboard > Input Sources > Edit…: the layouts in use, the first one at login; + adds one (LayoutPickerSheet, through Main.qml),
// − removes the selected one, a drag (or Alt+Up/Down) moves it. Each change goes back to the page at once (`changed`), which
// writes keyboard.lua; with two or more, Ctrl+Space selects the previous source and Ctrl+Option+Space the next on every keyboard (bindings.lua, bound from two layouts). A Latin layout always comes first, as
// input.lua applies them (Keyboard.latinFirst: the bindings resolve against the first layout, and a Latin password must be
// typeable at the lock screen); macOS keeps a Latin input source the same way: the last one cannot be removed.
Sheet {
    id: root

    property var sources: []
    property var layouts: ({names: {}, all: []})
    property int selected: 0

    signal changed(var sources)
    signal addRequested(var layouts, var sources)

    title: qsTr("Input Sources")
    message: root.sources.length > 1 ? qsTr("Drag an input source to change the order: the first one is used at login. Press Control-Space to select the next input source.") : qsTr("Add an input source to type in another layout.")
    confirmText: qsTr("Done")
    showCancel: false

    // − is off for the last Latin source (another one has to stay).
    readonly property bool canRemove: root.sources.length > 1 && root.sources.some((s, i) => i !== root.selected && Keyboard.latin(s.layout))

    function openWith(list: var, layouts: var): void {
        root.sources = Keyboard.latinFirst(list);
        root.layouts = layouts;
        root.selected = 0;
        root.open();
    }

    function set(list: var): void {
        root.sources = list;
        root.selected = Math.max(0, Math.min(root.selected, list.length - 1));
        root.changed(list);
    }

    // LayoutPickerSheet's answer.
    function add(source: var): void {
        if (root.sources.some(s => s.layout === source.layout && s.variant === source.variant) || root.sources.length >= Keyboard.MAX_LAYOUTS)
            return;
        root.set(root.sources.concat([{layout: source.layout, variant: source.variant}]));
        root.selected = root.sources.length - 1;
    }

    // The selected source to position j; refused when a layout that cannot type Latin letters would come first.
    function moveTo(j: int): void {
        const i = root.selected;
        if (j < 0 || j >= root.sources.length || j === i)
            return;
        const list = root.sources.slice();
        list.splice(j, 0, list.splice(i, 1)[0]);
        if (!Keyboard.latin(list[0].layout))
            return;
        root.selected = j;
        root.set(list);
    }

    function move(by: int): void {
        root.moveTo(root.selected + by);
    }

    function remove(): void {
        if (root.canRemove)
            root.set(Keyboard.latinFirst(root.sources.filter((s, i) => i !== root.selected)));
    }

    function indexAt(y: real): int {
        return Math.max(0, Math.min(root.sources.length - 1, Math.floor(y / Tokens.settingsRowHeight)));
    }

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            SettingsGroup {
                Item {
                    id: list
                    objectName: "inputSourceList"
                    width: parent.width
                    height: Math.max(1, root.sources.length) * Tokens.settingsRowHeight
                    activeFocusOnTab: true
                    Accessible.role: Accessible.List
                    Accessible.name: root.title

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                            const by = event.key === Qt.Key_Up ? -1 : 1;
                            if (event.modifiers & Qt.AltModifier)
                                root.move(by);
                            else
                                root.selected = Math.max(0, Math.min(root.sources.length - 1, root.selected + by));
                            event.accepted = true;
                        }
                    }

                    // A press selects; dragged further than the platform's drag distance, the source follows the pointer row by row.
                    MouseArea {
                        id: dragArea

                        property bool dragging: false
                        property real startY: 0

                        anchors.fill: parent
                        cursorShape: dragArea.dragging ? Qt.ClosedHandCursor : Qt.ArrowCursor
                        onPressed: mouse => {
                            root.selected = root.indexAt(mouse.y);
                            dragArea.startY = mouse.y;
                            dragArea.dragging = false;
                            list.forceActiveFocus(Qt.MouseFocusReason);
                        }
                        onPositionChanged: mouse => {
                            if (!dragArea.dragging && Math.abs(mouse.y - dragArea.startY) < Application.styleHints.startDragDistance)
                                return;
                            dragArea.dragging = true;
                            root.moveTo(root.indexAt(mouse.y));
                        }
                        onReleased: dragArea.dragging = false
                        onCanceled: dragArea.dragging = false
                    }

                    Repeater {
                        model: root.sources

                        delegate: Item {
                            id: entry

                            required property var modelData
                            required property int index
                            readonly property bool isSelected: entry.index === root.selected

                            y: entry.index * Tokens.settingsRowHeight
                            width: list.width
                            height: Tokens.settingsRowHeight
                            Accessible.role: Accessible.ListItem
                            Accessible.name: Keyboard.sourceName(entry.modelData, root.layouts.names)
                            Accessible.selected: entry.isSelected

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: Tokens.spacingXs
                                visible: entry.isSelected
                                radius: Tokens.settingsNavTileRadius
                                color: list.activeFocus ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.fill, Tokens.settingsSoundTableSelectionOpacity)
                            }

                            Text {
                                textFormat: Text.PlainText
                                x: Tokens.settingsRowInset
                                width: parent.width - 2 * Tokens.settingsRowInset
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                text: entry.Accessible.name
                                color: entry.isSelected && list.activeFocus ? Appearance.colors.selectionText : Appearance.colors.text
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyBodySize
                            }
                        }
                    }
                }

                ListFooter {
                    canAdd: root.sources.length < Keyboard.MAX_LAYOUTS
                    canRemove: root.canRemove
                    addName: qsTr("Add an input source")
                    removeName: qsTr("Remove the selected input source")
                    onAddClicked: root.addRequested(root.layouts, root.sources)
                    onRemoveClicked: root.remove()
                }
            }
        }
    }
}
