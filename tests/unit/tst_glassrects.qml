import QtQuick
import QtTest
import Grassfield.Ui

// Where a glass surface's backdrop is judged (Material.glassRect, ADR-0024 G-3 per surface), for surfaces whose own geometry
// does not say where they are (audit B-02, B-03, B-13, B-15):
// - a host that gives backdropRect is not measured at all (no work per frame of a size animation, no stale measure);
// - a Material moved by an ancestor keeps its first measure (why hosts give the rect or measure again; this is the case
//   B-13 found: the Center's pill, close disc and title plate were measured once, off-screen to the right);
// - the hosts in the shell give it: the Center's pill, close disc, title plate and widget tiles (the column at rest), the
//   Search panel (its height at rest), the capture readout (the whole output) and the banners (the stack at rest); a widget
//   tile is measured again when its host moves it.
TestCase {
    id: tc

    name: "GlassRects"
    width: Screen.width
    height: Screen.height
    visible: true
    when: windowShown

    Item {
        id: mover
        x: 10
        y: 10
        width: 200
        height: 200

        Material {
            id: carried
            width: 100
            height: 50
            shadowEnabled: false
        }

        Material {
            id: given
            y: 60
            width: 100
            height: 50
            shadowEnabled: false
            backdropRect: Qt.rect(500, 40, 300, 400)
        }
    }

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    function test_givenRectIsNotMeasured() {
        wait(50);
        compare(given.measuredRect.width, 0, "no measure when the host gives the area");
        compare(given.glassRect, Qt.rect(500, 40, 300, 400));
        given.height = 80;
        wait(20);
        compare(given.measuredRect.width, 0, "nor on a size change");
        given.measureRect();
        compare(given.measuredRect.width, 0, "nor when asked");
    }

    function test_movedByAnAncestorIsNotHeard() {
        // The window is not the size of a screen offscreen when the test window is smaller; only run where it is.
        if (carried.Window.window.width < Screen.width || carried.Window.window.height < Screen.height)
            skip("the test window does not cover the screen: Material measures only then");
        tryVerify(() => carried.measuredRect.width > 0);
        const firstX = carried.measuredRect.x;
        mover.x = 300;
        wait(30);
        compare(carried.measuredRect.x, firstX, "an ancestor's move is not heard by the Material itself");
        carried.measureRect();
        compare(carried.measuredRect.x, firstX + 290, "measured again when its host asks");
    }

    function test_hostsGiveTheArea() {
        const center = source("shell/notifications/NotificationCenter.qml");
        verify(center.indexOf("property alias backdropRect: pillSurface.backdropRect") >= 0, "the footer pill takes a rect");
        verify(/id: editPill[\s\S]{0,80}backdropRect: panelItem\.restRect/.test(center), "Edit Widgets is judged over the column at rest");
        verify(/id: closeSurface[\s\S]{0,500}backdropRect: panelItem\.restRect/.test(center), "the close disc too");
        verify(/id: titlePlate[\s\S]{0,900}backdropRect: titleRow\.area/.test(center), "the title plate over its row at rest");
        verify(/delegate: WidgetHost \{[\s\S]{0,700}backdropRect: panelItem\.restRect/.test(center), "the widget tiles over the column at rest");
        const host = source("shell/widgets/WidgetHost.qml");
        verify(host.indexOf("property alias backdropRect: tileGlass.backdropRect") >= 0);
        verify(host.indexOf("onXChanged: Qt.callLater(tileGlass.measureRect)") >= 0 && host.indexOf("onYChanged: Qt.callLater(tileGlass.measureRect)") >= 0, "a tile moved by its host is measured again");
        const search = source("shell/search/SearchPanel.qml");
        verify(search.indexOf("backdropRect: Qt.rect(panel.x, panel.y, panel.width, panel.restHeight)") >= 0, "the Search panel at its height at rest");
        verify(search.indexOf("height: restHeight") >= 0, "the panel glides to that height");
        const capture = source("shell/capture/CaptureToolbar.qml");
        verify(capture.indexOf("backdropRect: Qt.rect(0, 0, readout.parent.width, readout.parent.height)") >= 0, "the readout over the whole output");
        verify(/Repeater \{\s*model: 8\s/.test(capture), "eight handles made once (B-15)");
        compare(capture.indexOf("model: Model.handleCentres(win.frame)"), -1, "not a model of fresh points per move");
        const stack = source("shell/notifications/BannerStack.qml");
        verify(stack.indexOf("Tokens.notificationBannerWidth, stack.restHeight)") >= 0, "the banners over the stack at rest (B-02)");
    }
}
