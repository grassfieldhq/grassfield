pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../shell/search/KeyedRows.js" as KeyedRows

// Search results as keyed rows updated in place (audit B-05): the results ListView's model was a JS array replaced on every
// keystroke (and again when the file hits landed), so the view reset and every row delegate was destroyed and made again
// inside onTextChanged. Search.setResults now brings a ListModel of {key, itemIndex} in line by key (KeyedRows.sync).
// - the rows follow the keys in order, itemIndex is the position, duplicate keys still give one row each;
// - a result that stays keeps its delegate (no destruction, no creation) across keystrokes and the file hits' arrival;
// - a seeded random sequence of key lists always ends with the model equal to the keys.
TestCase {
    id: tc

    name: "SearchRows"
    width: 300
    height: 600
    visible: true
    when: windowShown

    property var created: ({})
    property var destroyed: ({})

    ListModel {
        id: rows
    }

    ListView {
        id: view
        width: 300
        height: 600
        model: rows
        delegate: Item {
            id: d
            required property string key
            required property int itemIndex
            readonly property string myKey: key
            width: 300
            height: 20
            Component.onCompleted: tc.created[d.myKey] = (tc.created[d.myKey] || 0) + 1
            Component.onDestruction: tc.destroyed[d.myKey] = (tc.destroyed[d.myKey] || 0) + 1
        }
    }

    function init() {
        rows.clear();
        tc.created = {};
        tc.destroyed = {};
    }

    function keysOf() {
        const out = [];
        for (let i = 0; i < rows.count; i++) {
            compare(rows.get(i).itemIndex, i, "itemIndex is the position");
            out.push(rows.get(i).key);
        }
        return out;
    }

    function test_followsTheKeys() {
        KeyedRows.sync(rows, ["app:firefox", "cmd:lock", "file:/a"]);
        compare(keysOf(), ["app:firefox", "cmd:lock", "file:/a"]);
        KeyedRows.sync(rows, ["file:/a", "app:firefox"]);
        compare(keysOf(), ["file:/a", "app:firefox"]);
        KeyedRows.sync(rows, ["calc", "calc", "app:x"]);
        compare(keysOf(), ["calc", "calc#1", "app:x"], "a repeated key still gives its own row");
        KeyedRows.sync(rows, []);
        compare(rows.count, 0);
    }

    function test_rowsThatStayKeepTheirDelegate() {
        // Typing "f", "fi", "fir", "fire", then the file hits land: the apps that still match keep their rows.
        const steps = [
            ["top:app:files", "app:firefox", "app:foot", "app:fractal", "cmd:forcequit"],
            ["top:app:firefox", "app:files", "cmd:find"],
            ["top:app:firefox", "app:files"],
            ["top:app:firefox"],
            ["top:app:firefox", "file:/home/u/fire.txt", "file:/home/u/fireworks.png"]
        ];
        KeyedRows.sync(rows, steps[0]);
        waitForRendering(view);
        tc.created = {};
        const stats = KeyedRows.sync(rows, steps[1]);
        compare(stats.inserted, 3, "the new keys only");
        compare(tc.destroyed["app:firefox"], undefined, "app:firefox stayed: no destruction");
        tryVerify(() => tc.destroyed["app:fractal"] === 1, 1000, "a row that left is destroyed");
        for (let i = 2; i < steps.length; i++) {
            KeyedRows.sync(rows, steps[i]);
            compare(keysOf(), steps[i]);
        }
        waitForRendering(view);
        compare(tc.created["top:app:firefox"], 1, "the Top Hit row was made once, at the second keystroke, and kept since");
        compare(tc.destroyed["top:app:firefox"], undefined);
        compare(tc.created["file:/home/u/fire.txt"], 1);
    }

    function test_randomSequences() {
        let seed = 7;
        const rnd = n => {
            seed = (seed * 1103515245 + 12345) & 0x7fffffff;
            return seed % n;
        };
        const pool = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"];
        for (let round = 0; round < 300; round++) {
            const n = rnd(pool.length + 1);
            const keys = [];
            for (let i = 0; i < n; i++)
                keys.push(pool[rnd(pool.length)]);
            KeyedRows.sync(rows, keys);
            compare(keysOf(), KeyedRows.uniqueKeys(keys), "round " + round);
        }
    }

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    // The shell's list really is the keyed model (Search and SearchPanel need Quickshell; their wiring is checked here).
    function test_wiring() {
        const panel = source("shell/search/SearchPanel.qml");
        verify(panel.indexOf("model: root.controller.rowModel") >= 0, "the results ListView's model is Search.rowModel");
        compare(panel.indexOf("model: root.controller.rows\n"), -1, "not the JS array");
        const search = source("shell/search/Search.qml");
        verify(search.indexOf("KeyedRows.sync(rowStore, flat.map(it => it.key))") >= 0, "setResults syncs the rows by key");
        compare((search.match(/\n\s*items = /g) || []).length, 1, "the results are set in setResults only");
    }
}
