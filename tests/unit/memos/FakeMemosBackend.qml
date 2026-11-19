import QtQuick

// A stand-in for apps/memos/src/memosapp.h (MemosApp) in tests/unit/tst_memos.qml: it keeps the memos in memory and records
// the calls the windows make. The text formatter's calls are recorded, not applied (its effect is tested in gtest,
// tests/unit/memos/tst_memostore.cpp MemoText.*).
QtObject {
    id: root

    property string refusal: ""
    property bool dark: false
    property bool reduceMotion: false
    property bool increaseContrast: false
    property real textScale: 1
    property string accentColor: "multicolor"
    property string accentHighlight: "automatic"
    property string shortcutStyle: "pc"

    property var stored: []
    property var memos: []
    property var updates: []
    property var removed: []
    property int saves: 0
    property int created: 0
    property string clipboard: "pasted"
    // As MemosApp.saveError and dirty: "" while the memos are written.
    property string saveError: ""
    property bool dirty: false
    // What saveNow() answers (false: the write failed, saveError says why).
    property bool saveResult: true
    property int asyncSaves: 0
    property int quits: 0
    // refreshFrames() answers at once unless set; then emitFrames() answers.
    property bool deferFrames: false
    property int frameReads: 0
    property string selection: "primary"

    property QtObject formatter: QtObject {
        property var calls: []
        function record(name, args) {
            calls = calls.concat([{name: name, args: Array.prototype.slice.call(args)}]);
        }
        function toggleBold() {
            record("bold", arguments);
        }
        function toggleItalic() {
            record("italic", arguments);
        }
        function toggleUnderline() {
            record("underline", arguments);
        }
        function changeSize() {
            record("size", arguments);
        }
        function toggleList() {
            record("list", arguments);
        }
        function insertPlain(doc, start, end, text) {
            record("insert", arguments);
            return start;
        }
    }

    function tag(m) {
        return "memo:" + m.id;
    }

    function open(w, h) {
        root.memos = root.stored.map(m => Object.assign({}, m));
        return root.refusal !== "" ? [] : root.current();
    }

    function current() {
        return root.memos.map(m => Object.assign({tag: root.tag(m)}, m));
    }

    function createMemo(frontId, w, h, step) {
        if (root.refusal !== "")
            return ({});
        root.created++;
        const m = {id: "new" + root.created, color: "yellow", html: "", width: w, height: h, collapsed: false, translucent: false};
        root.memos = root.memos.concat([m]);
        return Object.assign({tag: root.tag(m)}, m);
    }

    function update(id, changes) {
        root.updates = root.updates.concat([{id: id, changes: changes}]);
        for (let i = 0; i < root.memos.length; i++) {
            if (root.memos[i].id === id)
                Object.assign(root.memos[i], changes);
        }
    }

    function remove(id) {
        root.removed = root.removed.concat([id]);
        root.memos = root.memos.filter(m => m.id !== id);
    }

    function tagFor(id) {
        const m = root.memos.find(x => x.id === id);
        return m ? root.tag(m) : "";
    }

    // The tags the windows sent again (a collapse or an expand), in order.
    property var retags: []

    function retag(window, tag) {
        root.retags = root.retags.concat([tag]);
    }

    signal framesRead
    signal saved(bool ok)

    function refreshFrames() {
        root.frameReads++;
        if (!root.deferFrames)
            root.framesRead();
    }

    function emitFrames() {
        root.framesRead();
    }

    // As MemosApp: saveNow() and save() ask the windows to push what they hold first.
    signal aboutToSave

    function saveNow() {
        root.aboutToSave();
        root.saves++;
        return root.saveResult;
    }

    function save() {
        root.aboutToSave();
        root.asyncSaves++;
    }

    function quit() {
        root.quits++;
    }

    function clipboardText(selection) {
        return selection ? root.selection : root.clipboard;
    }

    function count() {
        return root.memos.length;
    }

    function lastUpdate(id, key) {
        for (let i = root.updates.length - 1; i >= 0; i--) {
            if (root.updates[i].id === id && root.updates[i].changes[key] !== undefined)
                return root.updates[i].changes[key];
        }
        return undefined;
    }
}
