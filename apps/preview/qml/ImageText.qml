import QtQuick
import "TextInImages.js" as TextInImages

// Select Text in Images (ADR-0045 OC-2, docs/specs/preview.md P13): reads the text and the QR codes of the still image a
// window shows, once per image shown, in the background (PreviewApp.recognize), and gives them to the image view as `page`
// and `codes`. Content.qml holds one for its window, so that tesseract's languages are asked once. A new image, or the
// setting going off, cancels what still runs; nothing is stored. A missing tool gives nothing at all (no text, no chip, no
// message on screen; the backend writes one journal line).
Item {
    id: root

    // PreviewApp (a test's mock without recognize leaves `active` false).
    property var backend: null
    // The image's index in the backend's list, and its URL: "" when the file is not a still image to read.
    property int fileIndex: -1
    property string url: ""
    // preview.textInImages.
    property bool active: false

    // What was read (TextInImages.parseTsv, parseCodes).
    property var page: TextInImages.emptyPage()
    property var codes: []

    // tesseract's -l value chosen from `tesseract --list-langs` and the session's language: asked once (0 not asked yet,
    // 1 asked, 2 known; "" when neither the language nor English is installed, or tesseract is not).
    property int languagesState: 0
    property string languages: ""
    property int languagesRequest: 0
    property int textRequest: 0
    property int codesRequest: 0
    // The image being read ("" while none).
    property string readingUrl: ""

    visible: false

    onUrlChanged: root.restart()
    onActiveChanged: root.restart()
    onBackendChanged: root.restart()
    Component.onCompleted: root.restart()
    Component.onDestruction: root.cancel()

    function cancel(): void {
        if (root.textRequest > 0)
            root.backend.cancelRecognition(root.textRequest);
        if (root.codesRequest > 0)
            root.backend.cancelRecognition(root.codesRequest);
        root.textRequest = 0;
        root.codesRequest = 0;
    }

    // Another image (or none): what was read goes, and the new one is read once the viewer has rested on it for a moment
    // (the arrow keys held down through a folder start nothing).
    function restart(): void {
        root.cancel();
        root.readingUrl = "";
        root.page = TextInImages.emptyPage();
        root.codes = [];
        if (root.active && root.url !== "" && root.backend !== null)
            delay.restart();
        else
            delay.stop();
    }

    function start(): void {
        root.readingUrl = root.url;
        root.codesRequest = root.backend.recognize("qr", root.fileIndex, "");
        if (root.languagesState === 2) {
            root.readText();
        } else if (root.languagesState === 0) {
            root.languagesRequest = root.backend.recognize("languages", -1, "");
            root.languagesState = root.languagesRequest > 0 ? 1 : 2;
        }
    }

    function readText(): void {
        if (root.languages !== "" && root.readingUrl !== "" && root.textRequest === 0)
            root.textRequest = root.backend.recognize("text", root.fileIndex, root.languages);
    }

    // A debounce (logic, ADR-0039 D7), not a visible timing. On battery the viewer must rest longer on an image before it
    // is read (P5 of the 2026-11 audit: tesseract keeps a core busy for seconds per photo while a folder is browsed).
    Timer {
        id: delay
        interval: root.backend && root.backend.onBattery === true ? 1500 : 300
        onTriggered: root.start()
    }

    Connections {
        target: root.backend
        enabled: root.backend !== null
        ignoreUnknownSignals: true

        function onRecognized(request: int, tool: string, exitCode: int, output: string): void {
            if (request === 0)
                return;
            if (request === root.languagesRequest) {
                root.languagesRequest = 0;
                root.languagesState = 2;
                root.languages = TextInImages.chooseLanguages(TextInImages.parseLanguages(exitCode === 0 ? output : ""), Qt.locale().name);
                if (root.languages === "")
                    console.info("grassfield-preview: no tesseract language data for " + Qt.locale().name + " or English: no text selection in images");
                root.readText();
            } else if (request === root.textRequest) {
                root.textRequest = 0;
                root.page = exitCode === 0 ? TextInImages.parseTsv(output) : TextInImages.emptyPage();
            } else if (request === root.codesRequest) {
                root.codesRequest = 0;
                root.codes = TextInImages.parseCodes(exitCode, output);
            }
        }
    }
}
