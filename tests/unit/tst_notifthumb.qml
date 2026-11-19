import QtQuick
import QtTest
import Grassfield.Ui

// The attached picture of a notification (audit B-19): image data comes from Quickshell's provider at the size the sender
// sent (up to ~5.7k x 5.7k), whatever size is asked for, and an Image held that whole texture for a 40 px thumbnail per
// notification, behind a MultiEffect mask (two layers). NotificationContent now draws it once into a Canvas the thumbnail's
// size, cropped to the square and rounded, and lets the full picture go.
// - a wide picture (3000 x 1000: red, green and blue thirds) shows its middle third (PreserveAspectCrop) with rounded corners;
// - after the draw the reading Image has no source (the full picture is not held) and nothing under the content is a layer;
// - a picture that cannot be read shows no thumbnail; a new picture replaces the drawn one.
TestCase {
    id: tc

    name: "NotifThumb"
    width: 400
    height: 120
    visible: true
    when: windowShown

    readonly property string wide: "data:image/svg+xml;utf8," + encodeURIComponent("<svg xmlns='http://www.w3.org/2000/svg' width='3000' height='1000'>"
        + "<rect width='1000' height='1000' fill='#ff0000'/><rect x='1000' width='1000' height='1000' fill='#00ff00'/>"
        + "<rect x='2000' width='1000' height='1000' fill='#0000ff'/></svg>")
    readonly property string tall: "data:image/svg+xml;utf8," + encodeURIComponent("<svg xmlns='http://www.w3.org/2000/svg' width='100' height='300'>"
        + "<rect width='100' height='300' fill='#0000ff'/></svg>")

    Rectangle {
        id: board
        width: 400
        height: 120
        color: "white"
    }

    property var content: null

    // The real file, made outside its module directory (whose qmldir names the Notifications singleton, a Quickshell service).
    function init() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../shell/notifications/NotificationContent.qml"), false);
        xhr.send();
        verify(xhr.responseText.length > 0);
        content = Qt.createQmlObject(xhr.responseText, board, Qt.resolvedUrl("notifthumb-standalone/NotificationContent.qml"));
        verify(content !== null);
        content.width = 380;
        content.summary = "Photo";
        content.appName = "Messages";
        content.imageSource = tc.wide;
    }

    function cleanup() {
        if (content)
            content.destroy();
        content = null;
    }

    function find(item, pred) {
        for (const c of item.children) {
            if (pred(c))
                return c;
            const r = find(c, pred);
            if (r)
                return r;
        }
        return null;
    }

    function walk(item, out) {
        for (const c of item.children) {
            out.push(c);
            walk(c, out);
        }
        return out;
    }

    function canvas() {
        return find(content, c => c.drawnFrom !== undefined);
    }

    function test_croppedRoundedAndLetGo() {
        tryVerify(() => canvas() && canvas().drawn, 3000, "the picture is drawn");
        verify(content.hasThumbnail);
        const reader = find(content, c => String(c).indexOf("QQuickImage") >= 0 && !c.visible && c.asynchronous && c.parent === canvas().parent);
        verify(reader !== null, "the reading Image");
        compare(String(reader.source), "", "the full picture is let go once drawn");
        for (const it of walk(content, []))
            verify(!it.layer.enabled, "no layer: " + it);
        waitForRendering(board);
        const img = grabImage(board);
        const cv = canvas();
        const p = cv.mapToItem(board, 0, 0);
        const mid = Qt.color(img.pixel(p.x + cv.width / 2, p.y + cv.height / 2));
        verify(mid.g > 0.9 && mid.r < 0.2 && mid.b < 0.2, "the middle third (green) fills the square: " + mid);
        const left = Qt.color(img.pixel(p.x + 2, p.y + cv.height / 2));
        verify(left.g > 0.9 && left.r < 0.2, "cropped, not fitted: the left edge is green too: " + left);
        const corner = Qt.color(img.pixel(p.x, p.y));
        verify(corner.r > 0.9 && corner.g > 0.9 && corner.b > 0.9, "a rounded corner shows the board: " + corner);
    }

    function test_replacedAndFailed() {
        tryVerify(() => canvas() && canvas().drawn, 3000);
        content.imageSource = tc.tall;
        verify(!canvas().drawn, "the old picture is not taken for the new one");
        tryVerify(() => canvas().drawn, 3000, "the new picture is drawn");
        waitForRendering(board);
        const img = grabImage(board);
        const cv = canvas();
        const p = cv.mapToItem(board, 0, 0);
        const mid = Qt.color(img.pixel(p.x + cv.width / 2, p.y + cv.height / 2));
        verify(mid.b > 0.9 && mid.g < 0.2, "the new picture: " + mid);
        content.imageSource = Qt.resolvedUrl("missing/none.png");
        tryVerify(() => !content.hasThumbnail, 3000, "an unreadable picture: no thumbnail");
    }
}
