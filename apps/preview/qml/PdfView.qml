pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Pdf
import Grassfield.Ui

// PDF through QtPdf (pdfium, no JavaScript): continuous pages, zoom, rotation (view only), search
// text and page navigation. Encrypted documents are not supported in v1.
FocusScope {
    id: root

    property var info: ({})
    property int fileIndex: 0
    // Search text from the window's search field.
    property string searchText: ""

    readonly property bool canZoom: doc.status === PdfDocument.Ready
    readonly property bool canRotate: doc.status === PdfDocument.Ready
    readonly property bool canSearch: doc.status === PdfDocument.Ready
    readonly property string zoomLabel: Math.round(view.renderScale * 100) + "%"
    readonly property int pageCount: doc.status === PdfDocument.Ready ? doc.pageCount : 1
    readonly property int currentPage: view.currentPage
    readonly property alias document: doc
    property int matches: 0

    Accessible.role: Accessible.Document
    Accessible.name: qsTr("PDF document %1").arg(root.info.name ?? "")

    function fit(): void {
        view.scaleToWidth(view.width, view.height);
    }
    function actualSize(): void {
        view.resetScale();
    }
    function zoomIn(): void {
        view.renderScale = Math.min(Tokens.previewZoomMax, view.renderScale * Tokens.previewZoomStep);
    }
    function zoomOut(): void {
        view.renderScale = Math.max(Tokens.previewZoomMin, view.renderScale / Tokens.previewZoomStep);
    }
    function rotate(direction: int): void {
        view.pageRotation += direction * 90;
    }
    function goToPage(page: int): void {
        view.goToPage(Math.max(0, Math.min(doc.pageCount - 1, page)));
    }
    function nextMatch(): void {
        view.searchForward();
    }
    function previousMatch(): void {
        view.searchBack();
    }

    PdfDocument {
        id: doc
        source: root.info.url ?? ""
        onStatusChanged: () => {
            if (doc.status === PdfDocument.Ready)
                Qt.callLater(root.fit);
        }
    }

    // The content has scrolled under the window's toolbar: the toolbar draws its rule (ADR-0039 D3, step 16). The page view is
    // a TableView it does not expose, so past the first page (within it, the rule waits; NOT VERIFIED here: QtQuick.Pdf is not
    // in the test container).
    readonly property bool scrolled: view.currentPage > 0

    PdfMultiPageView {
        id: view
        anchors.fill: parent
        document: doc
        visible: doc.status === PdfDocument.Ready
        searchString: root.searchText
        focus: true
        onWidthChanged: if (doc.status === PdfDocument.Ready && width > 0 && renderScale === 1)
            Qt.callLater(root.fit)

        Keys.onPressed: event => {
            if (event.key === Qt.Key_PageDown) {
                root.goToPage(view.currentPage + 1);
                event.accepted = true;
            } else if (event.key === Qt.Key_PageUp) {
                root.goToPage(view.currentPage - 1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Home) {
                root.goToPage(0);
                event.accepted = true;
            } else if (event.key === Qt.Key_End) {
                root.goToPage(doc.pageCount - 1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                // The page view is a TableView that does not scroll by keys: arrows turn pages.
                root.goToPage(view.currentPage + (event.key === Qt.Key_Down ? 1 : -1));
                event.accepted = true;
            }
        }

        WheelHandler {
            acceptedModifiers: Qt.ControlModifier
            onWheel: event => {
                if (event.angleDelta.y > 0)
                    root.zoomIn();
                else if (event.angleDelta.y < 0)
                    root.zoomOut();
            }
        }

        Connections {
            target: view.searchModel
            function onModelReset(): void {
                root.matches = view.searchModel.rowCount();
            }
            function onRowsInserted(): void {
                root.matches = view.searchModel.rowCount();
            }
        }
    }

    // passwordRequired is a signal of PdfDocument, not a property (always truthy when read): the document's error says
    // whether it is the password that stops it.
    readonly property bool locked: doc.status === PdfDocument.Error
        && (doc.error === PdfDocument.IncorrectPassword || doc.error === PdfDocument.UnsupportedSecurityScheme)

    Message {
        anchors.fill: parent
        visible: doc.status === PdfDocument.Error
        title: root.locked ? qsTr("Password protected") : qsTr("This PDF cannot be opened")
        text: root.locked ? qsTr("Encrypted documents are not supported yet.") : qsTr("The file is damaged or not a PDF document.")
    }

    Message {
        anchors.fill: parent
        visible: doc.status === PdfDocument.Loading
        text: qsTr("Loading…")
    }
}
