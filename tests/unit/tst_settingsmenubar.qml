import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings > Menu Bar as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Menu Bar): the first group's pop-ups
// and switch, the Menu Bar Controls list (a check box per control at the measured places, the clock without one, Battery only
// with a battery), the option sheets asked for, and Battery Options writing the percentage. The store is a fake.
TestCase {
    id: testCase
    name: "SettingsMenuBar"
    width: 508
    height: 1400
    visible: true
    when: windowShown

    Component {
        id: storeComponent
        QtObject {
            property var values: Object.assign({}, SettingsContract.ALL_DEFAULTS)
            property var writes: []
            function value(key: string): var {
                return values[key];
            }
            function setMany(entries: var): bool {
                writes.push(entries);
                values = Object.assign({}, values, entries);
                return true;
            }
            function set(key: string, v: var): bool {
                const e = {};
                e[key] = v;
                return setMany(e);
            }
        }
    }

    Component {
        id: pageComponent
        SettingsQml.MenuBarPage {
            width: 508
            height: 1400
        }
    }

    Component {
        id: sheetComponent
        SettingsQml.BatteryOptionsSheet {
            anchors.fill: parent
        }
    }

    Component {
        id: backendComponent
        QtObject {
            signal fileChanged(string path)
            property string wallpaperStatusFile: "/state/wallpaper-state.json"
            property string text: "{}"
            function watch(path: string): bool {
                return true;
            }
            function readText(path: string): var {
                return {exists: true, ok: true, text: text};
            }
        }
    }

    // ADR-0016 D1: when the wallpaper forces the band, the pane says so (the shell's status file, block `bar`).
    function test_bandForcedByTheWallpaperIsExplained() {
        const store = createTemporaryObject(storeComponent, testCase);
        const backend = createTemporaryObject(backendComponent, testCase);
        const page = createTemporaryObject(pageComponent, testCase, {store: store, backend: backend});
        compare(page.bandForced, false);
        const note = find(page.contentItem, i => i.footnote !== undefined && i.footnote.indexOf("background is shown") >= 0);
        compare(note, null);
        backend.text = JSON.stringify({outputs: {}, bar: {"eDP-1": true}});
        backend.fileChanged("/state/wallpaper-state.json");
        compare(page.bandForced, true);
        verify(find(page.contentItem, i => i.footnote !== undefined && i.footnote.indexOf("background is shown") >= 0));
        // The switch is on: the band is the user's own, nothing to explain.
        store.set("menubar.showBackground", true);
        compare(find(page.contentItem, i => i.footnote !== undefined && i.footnote.indexOf("background is shown") >= 0), null);
        // The wallpaper no longer forces it.
        store.set("menubar.showBackground", false);
        backend.text = JSON.stringify({outputs: {}, bar: {}});
        backend.fileChanged("/state/wallpaper-state.json");
        compare(page.bandForced, false);
    }

    function make(battery) {
        const store = createTemporaryObject(storeComponent, testCase);
        const page = createTemporaryObject(pageComponent, testCase, {store: store, hasBattery: battery === true});
        verify(page);
        return {store: store, page: page};
    }

    function find(item, pred) {
        if (!item)
            return null;
        if (pred(item))
            return item;
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++) {
            const hit = find(kids[i], pred);
            if (hit)
                return hit;
        }
        if (item.contentItem && item.contentItem !== item) {
            const hit = find(item.contentItem, pred);
            if (hit)
                return hit;
        }
        return null;
    }

    function named(root, name) {
        return find(root, i => i.accessibleName === name);
    }

    function last(store) {
        return store.writes[store.writes.length - 1];
    }

    function test_firstGroup() {
        const t = make();
        const hide = named(t.page.contentItem, "Automatically hide and show the menu bar");
        verify(hide.inline);
        hide.picked("never");
        compare(last(t.store), {"menubar.autoHide": "never"});
        named(t.page.contentItem, "Show menu bar background").toggled(true);
        compare(last(t.store), {"menubar.showBackground": true});
        const recent = named(t.page.contentItem, "Recent documents and applications");
        compare(recent.model.map(m => m.id), ["0", "5", "10", "15", "20", "30", "50"]);
        recent.picked("20");
        compare(last(t.store), {"menubar.recentItems": 20});
    }

    function test_controlsList() {
        const t = make(true);
        waitForRendering(t.page);
        const keys = [["Search", "menubar.showSearch"], ["Wi-Fi", "menubar.showWifi"], ["Battery", "menubar.showBattery"], ["Focus", "menubar.showFocus"], ["Sound", "menubar.showSound"], ["Now Playing", "menubar.showNowPlaying"]];
        for (const [title, key] of keys) {
            const box = named(t.page.contentItem, "Show " + title + " in the menu bar");
            verify(box, title);
            compare(box.x, Tokens.settingsMenuBarCheckX);
            compare(box.parent.height, Tokens.settingsMenuBarControlRowHeight);
            verify(box.checked, title);
            mouseClick(box);
            compare(last(t.store), {[key]: false}, title);
        }
        // The clock is always in the menu bar: no check box, its options.
        verify(!find(t.page.contentItem, i => i.accessibleName === "Show Clock in the menu bar" && i.visible));
        let asked = 0;
        t.page.clockOptionsRequested.connect(() => asked++);
        find(t.page.contentItem, i => i.text === "Clock Options…" && i.clicked !== undefined).clicked();
        compare(asked, 1);
        t.page.batteryOptionsRequested.connect(() => asked++);
        find(t.page.contentItem, i => i.text === "Battery Options…" && i.clicked !== undefined).clicked();
        compare(asked, 2);
    }

    // Screen Capture (macOS 26/27: the control added to the menu bar, owner 2026-11-07): off by default, the last control, its
    // check box writing menubar.showScreenCapture.
    function test_screenCaptureControl() {
        const t = make(true);
        waitForRendering(t.page);
        const box = named(t.page.contentItem, "Show Screen Capture in the menu bar");
        verify(box, "the row");
        compare(box.x, Tokens.settingsMenuBarCheckX);
        verify(!box.checked, "off by default");
        const nowPlaying = named(t.page.contentItem, "Show Now Playing in the menu bar");
        verify(box.mapToItem(t.page.contentItem, 0, 0).y > nowPlaying.mapToItem(t.page.contentItem, 0, 0).y, "after Now Playing");
        mouseClick(box);
        compare(last(t.store), {"menubar.showScreenCapture": true});
    }

    function test_batteryOnlyWithABattery() {
        const t = make(false);
        const box = named(t.page.contentItem, "Show Battery in the menu bar");
        verify(!box.parent.visible);
    }

    function test_batteryOptionsSheet() {
        const t = make(true);
        const sheet = createTemporaryObject(sheetComponent, testCase, {store: t.store});
        sheet.open();
        const percentage = named(sheet, "Show the battery percentage in the menu bar");
        verify(percentage);
        percentage.toggled(false);
        compare(last(t.store), {"menubar.showBatteryPercentage": false});
    }

    function test_trayItems() {
        const t = make();
        named(t.page.contentItem, "Show status items of applications in the menu bar").toggled(false);
        compare(last(t.store), {"menubar.showTrayItems": false});
    }
}
