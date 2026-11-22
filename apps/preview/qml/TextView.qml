pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Markdown.js" as Markdown

// Plain text and code, read only. The text is always PlainText (never interpreted as markup), except a Markdown document,
// which shows rendered (the owner's report on 1.0.0-rc9; macOS Quick Look shows a Markdown file formatted): the backend
// turns it into rich text with its pictures checked and served by Preview itself (PreviewApp.inspect `markdown`, `html`;
// previewlogic markdownHtml). `showSource` (View > Show Markdown Source, the toolbar's source button) shows its plain text.
Item {
    id: root

    property var info: ({})
    property int fileIndex: 0
    // PreviewApp (Content.qml binds it): Copy of a long text goes through its clipboard call.
    property var backend: null

    // A long text comes in pieces of whole lines (PreviewApp.inspect `chunks`, P7 of the 2026-11 audit): a list lays out only
    // the pieces on screen, so a zoom step or a new window width re-lays out a screenful, not 2 MiB. Select All and Copy
    // still take the whole text; a drag selects within one piece.
    // A Markdown document shown rendered (one rich text, never in pieces), or its source.
    property bool showSource: false
    readonly property bool canShowSource: root.info.markdown === true
    readonly property bool rendered: root.canShowSource && !root.showSource && typeof root.info.html === "string"
    readonly property var chunks: root.rendered ? [] : (root.info.chunks ?? [])
    readonly property bool chunked: root.chunks.length > 0
    // The text item shown when the text is not in pieces.
    readonly property var edit: root.rendered ? rich : plain
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
    readonly property bool canCopy: root.chunked ? (root.allSelected || root.chunkSelection !== "") : root.edit.selectedText !== ""
    readonly property bool canSelectAll: root.chunked || root.edit.length > 0

    Accessible.role: Accessible.Document
    Accessible.name: qsTr("Text %1").arg(root.info.name ?? "")

    function copy(): void {
        if (!root.chunked) {
            root.edit.copy();
            return;
        }
        const text = root.allSelected ? String(root.info.text ?? "") : root.chunkSelection;
        if (text !== "" && root.backend)
            root.backend.copyText(text, false);
    }
    function selectAll(): void {
        if (!root.chunked) {
            root.edit.selectAll();
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
        contentHeight: root.edit.height + 2 * root.edit.y
        flickableDirection: Flickable.VerticalFlick
        focus: !root.chunked

        // The overlay scroll bar every scrolling view of the apps shows (ADR-0039 step 16).
        ScrollBar.vertical: ScrollBar {}

        Keys.onPressed: event => root.keyScroll(flick, event)

        TextEdit {
            id: plain
            visible: !root.rendered
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
            text: root.chunked || root.rendered ? "" : (root.info.text ?? "")
            color: Appearance.colors.text
            selectedTextColor: Appearance.highlightText
            selectionColor: Appearance.highlight
            font.family: Tokens.typographyMonoFamily
            font.pixelSize: Tokens.previewCodeFontSize * root.factor
        }

        // The rendered Markdown: rich text made by the backend from Qt's own Markdown reader (its raw HTML off), pictures
        // only from Preview's image provider at their served size, laid out no wider than the column: the backend's
        // fitMarkdownImages changes the picture formats only, so a resize never parses the text again and keeps the
        // selection. Read only, selectable; Copy gives the text.
        TextEdit {
            id: rich
            objectName: "markdownText"
            visible: root.rendered
            x: Tokens.previewMarkdownPadding
            y: Tokens.previewMarkdownPadding
            width: Math.max(0, root.wrapWidth - 2 * Tokens.previewMarkdownPadding)
            readOnly: true
            selectByMouse: true
            persistentSelection: true
            textFormat: TextEdit.RichText
            wrapMode: TextEdit.Wrap
            // Code blocks on the control fill, which shows in both appearances (light: black at 6 %, dark: white at 14 %).
            text: root.rendered ? Markdown.styled(root.info.html, {link: Appearance.colors.accent, code: Appearance.buttonFill}) : ""
            color: Appearance.colors.text
            selectedTextColor: Appearance.highlightText
            selectionColor: Appearance.highlight
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.previewMarkdownFontSize * root.factor
            Accessible.role: Accessible.Document
            Accessible.name: qsTr("Text %1").arg(root.info.name ?? "")

            function fitPictures(): void {
                if (root.rendered && root.backend && typeof root.backend.fitMarkdownImages === "function")
                    root.backend.fitMarkdownImages(rich.textDocument, rich.width);
            }
            onTextChanged: rich.fitPictures()
            onWidthChanged: rich.fitPictures()

            // A link opens in the browser (http and https only, PreviewApp.openLink checks it again); any other target
            // (another file, an anchor in the page) does nothing.
            onLinkActivated: link => {
                if (Markdown.isWebLink(link) && root.backend && typeof root.backend.openLink === "function")
                    root.backend.openLink(link);
            }

            HoverHandler {
                cursorShape: rich.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor
            }
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
