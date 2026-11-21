pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Plain text and code, read only. The text is always PlainText (never interpreted as markup).
Item {
    id: root

    property var info: ({})
    property int fileIndex: 0
    // PreviewApp (Content.qml binds it): Copy of a long text goes through its clipboard call.
    property var backend: null

    // A long text comes in pieces of whole lines (PreviewApp.inspect `chunks`, P7 of the 2026-11 audit): a list lays out only
    // the pieces on screen, so a zoom step or a new window width re-lays out a screenful, not 2 MiB. Select All and Copy
    // still take the whole text; a drag selects within one piece.
    readonly property var chunks: root.info.chunks ?? []
    readonly property bool chunked: root.chunks.length > 0
    // Select All in pieces: every piece shows selected and Copy takes the whole text.
    property bool allSelected: false
    // The piece holding the selection made with the pointer, and its text.
    property int selectedChunk: -1
    property string chunkSelection: ""
    // The width the text wraps at: follows the window, a moment after a live resize settles (one layout, not one per step).
    property real wrapWidth: 0

    readonly property bool canZoom: true
    readonly property bool canRotate: false
    readonly property bool canSearch: false
    readonly property string zoomLabel: Math.round(root.factor * 100) + "%"
    readonly property int pageCount: 1
    property int currentPage: 0
    property real factor: 1
    // Edit menu (GlobalMenu.qml): the selection of the text.
    readonly property bool canCopy: root.chunked ? (root.allSelected || root.chunkSelection !== "") : edit.selectedText !== ""
    readonly property bool canSelectAll: root.chunked || edit.length > 0

    Accessible.role: Accessible.Document
    Accessible.name: qsTr("Text %1").arg(root.info.name ?? "")

    function copy(): void {
        if (!root.chunked) {
            edit.copy();
            return;
        }
        const text = root.allSelected ? String(root.info.text ?? "") : root.chunkSelection;
        if (text !== "" && root.backend)
            root.backend.copyText(text, false);
    }
    function selectAll(): void {
        if (!root.chunked) {
            edit.selectAll();
            return;
        }
        root.selectedChunk = -1;
        root.chunkSelection = "";
        root.allSelected = true;
    }

    function scrollBy(view: var, step: real): void {
        view.contentY = Math.max(view.originY, Math.min(view.originY + view.contentHeight - view.height, view.contentY + step));
    }
    function keyScroll(view: var, event: var): void {
        if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
            root.scrollBy(view, (event.key === Qt.Key_Down ? 1 : -1) * Tokens.previewCodeFontSize * 3);
            event.accepted = true;
        } else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
            root.scrollBy(view, (event.key === Qt.Key_PageDown ? 1 : -1) * view.height * 0.9);
            event.accepted = true;
        }
    }

    onWidthChanged: {
        if (root.wrapWidth <= 0)
            root.wrapWidth = root.width;
        else
            settle.restart();
    }
    Component.onCompleted: root.wrapWidth = root.width
    onChunksChanged: {
        root.allSelected = false;
        root.selectedChunk = -1;
        root.chunkSelection = "";
    }

    // A debounce (logic, ADR-0039 D7), not a visible timing.
    Timer {
        id: settle
        interval: 120
        onTriggered: root.wrapWidth = root.width
    }

    function zoomIn(): void {
        root.factor = Math.min(Tokens.previewZoomMax, root.factor * Tokens.previewZoomStep);
    }
    function zoomOut(): void {
        root.factor = Math.max(Tokens.previewZoomMin, root.factor / Tokens.previewZoomStep);
    }
    function fit(): void {
        root.factor = 1;
    }
    function actualSize(): void {
        root.factor = 1;
    }
    function rotate(direction: int): void {
    }
    function goToPage(page: int): void {
    }

    // The content has scrolled under the window's toolbar: the toolbar draws its rule (ADR-0039 D3, step 16).
    readonly property bool scrolled: root.chunked ? list.contentY > list.originY : flick.contentY > flick.originY

    Flickable {
        id: flick
        anchors.fill: parent
        visible: !root.chunked
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: width
        contentHeight: edit.height + 2 * Tokens.spacingMd
        flickableDirection: Flickable.VerticalFlick
        focus: !root.chunked

        // The overlay scroll bar every scrolling view of the apps shows (ADR-0039 step 16).
        ScrollBar.vertical: ScrollBar {}

        Keys.onPressed: event => root.keyScroll(flick, event)

        TextEdit {
            id: edit
            TextCursor {}
            x: Tokens.spacingMd
            y: Tokens.spacingMd
            width: Math.max(0, root.wrapWidth - 2 * Tokens.spacingMd)
            readOnly: true
            selectByMouse: true
            // The selection survives the global menu taking the keyboard (Edit > Copy acts on it).
            persistentSelection: true
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
            text: root.chunked ? "" : (root.info.text ?? "")
            color: Appearance.colors.text
            selectedTextColor: Appearance.highlightText
            selectionColor: Appearance.highlight
            font.family: Tokens.typographyMonoFamily
            font.pixelSize: Tokens.previewCodeFontSize * root.factor
        }
    }

    ListView {
        id: list
        objectName: "textChunks"
        anchors.fill: parent
        visible: root.chunked
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        focus: root.chunked
        model: root.chunked ? root.chunks : []
        header: Item {
            height: Tokens.spacingMd
            width: 1
        }
        footer: Item {
            height: Tokens.spacingMd
            width: 1
        }

        ScrollBar.vertical: ScrollBar {}

        Keys.onPressed: event => root.keyScroll(list, event)

        delegate: TextEdit {
            id: piece

            required property int index
            required property string modelData

            TextCursor {}
            x: Tokens.spacingMd
            width: Math.max(0, root.wrapWidth - 2 * Tokens.spacingMd)
            readOnly: true
            selectByMouse: true
            persistentSelection: true
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
            text: piece.modelData
            color: Appearance.colors.text
            selectedTextColor: Appearance.highlightText
            selectionColor: Appearance.highlight
            font.family: Tokens.typographyMonoFamily
            font.pixelSize: Tokens.previewCodeFontSize * root.factor

            function follow(): void {
                if (root.allSelected)
                    piece.selectAll();
                else if (root.selectedChunk !== piece.index && piece.selectedText !== "")
                    piece.deselect();
            }
            Component.onCompleted: piece.follow()
            Connections {
                target: root
                function onAllSelectedChanged(): void {
                    piece.follow();
                }
                function onSelectedChunkChanged(): void {
                    piece.follow();
                }
            }
            onSelectedTextChanged: {
                if (root.allSelected || piece.selectedText === "")
                    return;
                root.selectedChunk = piece.index;
                root.chunkSelection = piece.selectedText;
            }
            TapHandler {
                onPressedChanged: {
                    if (pressed && root.allSelected)
                        root.allSelected = false;
                }
            }
        }
    }
}
