import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings > Accessibility as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Accessibility): a hub whose
// compact rows open Zoom, Display, Motion and Keyboard, and those sub-panes writing their keys. The store is a fake; the
// pointer theme report is never there.
TestCase {
    id: testCase
    name: "SettingsAccessibility"
    width: 508
    height: 900
    visible: true
    when: windowShown

    Component {
        id: storeComponent
        QtObject {
            property var values: Object.assign({}, SettingsContract.ALL_DEFAULTS)
            property var writes: []
            readonly property string path: "/nonexistent/grassfield.json"
            // The Backend's file reads and watches, as the Display sub-pane's pointer status uses them: no file.
            readonly property QtObject backend: QtObject {
                signal fileChanged(string path)
                function readText(path: string): var {
                    return {exists: false, ok: false, text: ""};
                }
                function watch(path: string): void {
                }
            }
            function value(key: string): var {
                return values[key];
            }
            function setMany(entries: var): bool {
                writes.push(entries);
                values = Object.assign({}, values, entries);
                return true;
            }
            // ConfigStore's throttled writes (a slider's drag): written at once here.
            function flush(): void {
            }
            function setSoon(key: string, v: var): void {
                set(key, v);
            }
            function setManySoon(entries: var): void {
                setMany(entries);
            }
            function set(key: string, v: var): bool {
                const e = {};
                e[key] = v;
                return setMany(e);
            }
        }
    }

    Component {
        id: hubComponent
        SettingsQml.AccessibilityPage {
            width: 508
            height: 900
        }
    }

    Component {
        id: zoomComponent
        SettingsQml.AccessibilityZoomPage {
            width: 508
            height: 900
        }
    }

    Component {
        id: displayComponent
        SettingsQml.AccessibilityDisplayPage {
            width: 508
            height: 900
        }
    }

    Component {
        id: motionComponent
        SettingsQml.AccessibilityMotionPage {
            width: 508
            height: 900
        }
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

    function make(component) {
        const store = createTemporaryObject(storeComponent, testCase);
        const page = createTemporaryObject(component, testCase, {store: store});
        verify(page);
        return {store: store, page: page};
    }

    // The hub's rows: macOS 27's compact rows (42 tall, 43 apart), each opening its sub-pane.
    function test_hubRows() {
        const hub = createTemporaryObject(hubComponent, testCase);
        const opened = [];
        hub.open.connect(id => opened.push(id));
        const rows = ["Zoom", "Display", "Motion", "Keyboard"].map(t => find(hub.contentItem, i => i.text === t && i.compact === true));
        rows.forEach((r, i) => verify(r, "row " + i));
        compare(rows[0].height, Tokens.settingsNavCompactRowHeight);
        compare(rows[1].height, Tokens.settingsNavCompactRowHeight + 1);
        compare(rows[1].mapToItem(hub.contentItem, 0, 0).y - rows[0].mapToItem(hub.contentItem, 0, 0).y, Tokens.settingsNavCompactRowHeight);
        rows.forEach(r => r.clicked());
        compare(opened, ["accessibility-zoom", "accessibility-display", "accessibility-motion", "accessibility-keyboard"]);
    }

    function test_zoom() {
        const t = make(zoomComponent);
        named(t.page.contentItem, "Zoom").toggled(true);
        compare(last(t.store), {"accessibility.zoom": true});
        const level = named(t.page.contentItem, "Zoom level");
        verify(level.inline);
        compare(level.value, "2");
        compare(level.model.length, 8);
        compare(level.model[0].id, "1.5");
        level.picked("3.5");
        compare(last(t.store), {"accessibility.zoomLevel": 3.5});
        // A hand-edited level stays selectable, in its place.
        t.store.set("accessibility.zoomLevel", 2.25);
        compare(level.model.length, 9);
        compare(level.model[2].id, "2.25");
        compare(level.value, "2.25");
    }

    function test_display() {
        const t = make(displayComponent);
        named(t.page.contentItem, "Increase contrast").toggled(true);
        compare(last(t.store), {"accessibility.increaseContrast": true});
        named(t.page.contentItem, "Reduce transparency").toggled(true);
        compare(last(t.store), {"accessibility.reduceTransparency": true});
        const size = named(t.page.contentItem, "Text size");
        compare(size.value, "1");
        size.picked("1.2");
        compare(last(t.store), {"accessibility.textSize": 1.2});
        // The pointer stays with the display, as on macOS.
        verify(named(t.page.contentItem, "Pointer size"));
        verify(named(t.page.contentItem, "Pointer outline colour"));
        verify(named(t.page.contentItem, "Pointer fill colour"));
    }

    function test_motion() {
        const t = make(motionComponent);
        const reduce = named(t.page.contentItem, "Reduce motion");
        verify(!reduce.checked);
        reduce.toggled(true);
        compare(last(t.store), {"accessibility.reduceMotion": true});
    }
}
