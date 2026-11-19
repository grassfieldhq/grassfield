import QtQuick
import Grassfield.Ui
import "Store.js" as Store

// grassfield.json access for the Settings app: reads the file fresh before every change so that
// keys written by the shell or by hand are kept, refuses to touch a malformed file, writes atomically
// (Backend.writeText uses QSaveFile), and follows external changes through the file watcher.
Item {
    id: root

    required property var backend

    // Parsed file contents ({} when missing). Read through value() so that bindings update.
    property var config: ({})
    property int revision: 0
    // Non-empty while the file exists but cannot be used (malformed, unreadable, unsupported version).
    property string error: ""
    property string writeError: ""
    readonly property bool blocked: error !== ""
    readonly property string path: backend.configFile

    visible: false

    // Validated value of a dotted key, or the schema default.
    function value(key: string): var {
        void root.revision;
        return Store.read(root.config, key);
    }

    function reload(): void {
        const file = root.backend.readText(root.path);
        if (file.exists && !file.ok) {
            root.error = qsTr("the file cannot be read");
            root.config = {};
        } else {
            const parsed = Store.parse(file.text);
            const unsupported = parsed.ok && !parsed.fresh && parsed.data.version !== 1;
            root.error = parsed.ok ? (unsupported ? qsTr("unsupported contract version") : "") : parsed.error;
            root.config = parsed.ok ? parsed.data : {};
        }
        root.revision++;
    }

    // The file already says what a change would write: nothing is written then. A slider reports every pointer position, and
    // most of them round to the value already stored; each write is a synchronous save that the shell reads again.
    function unchanged(before: string, after: string): bool {
        const parsed = Store.parse(before);
        return parsed.ok && !parsed.fresh && JSON.stringify(parsed.data, null, 2) + "\n" === after;
    }

    // Set a key. Returns true when the file was written, or already said so.
    function set(key: string, newValue: var): bool {
        const file = root.backend.readText(root.path);
        if (file.exists && !file.ok) {
            root.writeError = qsTr("the file cannot be read");
            return false;
        }
        const result = Store.setValue(file.text, key, newValue);
        if (!result.ok) {
            // The file stays untouched; reload shows why when the file is the problem.
            root.writeError = result.error;
            root.reload();
            return false;
        }
        if (root.unchanged(file.text, result.text)) {
            root.writeError = "";
            return true;
        }
        const failure = root.backend.writeText(root.path, result.text);
        root.writeError = failure;
        if (failure !== "")
            return false;
        root.reload();
        return true;
    }

    // Set several keys in one write ({dotted key: value}). Returns true when the file was written, or already said so.
    function setMany(entries: var): bool {
        const file = root.backend.readText(root.path);
        if (file.exists && !file.ok) {
            root.writeError = qsTr("the file cannot be read");
            return false;
        }
        const result = Store.setValues(file.text, entries);
        if (!result.ok) {
            root.writeError = result.error;
            root.reload();
            return false;
        }
        if (root.unchanged(file.text, result.text)) {
            root.writeError = "";
            return true;
        }
        const failure = root.backend.writeText(root.path, result.text);
        root.writeError = failure;
        if (failure !== "")
            return false;
        root.reload();
        return true;
    }

    // A slider's writes (Dock size, Magnification, Transparency, Pointer size): the first change is written at once, the ones
    // that follow within settingsColorWriteMs are held and only the last of them is written when that time is up, so a drag
    // writes a few times a second and its final position is always written (also when the slider gives no release: the
    // trailing write does it). The store lives with the window: a page left in the middle of a drag still gets its last value
    // written, and closing the window writes what waits (flush).
    property var waiting: null
    property bool waitingMany: false

    function setSoon(key: string, newValue: var): void {
        root.hold(false, ({[key]: newValue}));
    }

    function setManySoon(entries: var): void {
        root.hold(true, entries);
    }

    function hold(many: bool, entries: var): void {
        if (writeThrottle.running) {
            // Entries of different keys wait together; the latest value of a key wins.
            root.waiting = Object.assign({}, root.waiting ?? {}, entries);
            root.waitingMany = root.waitingMany || many;
            return;
        }
        root.writeNow(many, entries);
        writeThrottle.restart();
    }

    function writeNow(many: bool, entries: var): void {
        const keys = Object.keys(entries);
        if (!many && keys.length === 1)
            root.set(keys[0], entries[keys[0]]);
        else
            root.setMany(entries);
    }

    // Writes what waits now (the slider was released, or the window goes).
    function flush(): void {
        writeThrottle.stop();
        const w = root.waiting;
        root.waiting = null;
        if (w !== null)
            root.writeNow(root.waitingMany, w);
        root.waitingMany = false;
    }

    Timer {
        id: writeThrottle
        interval: Tokens.settingsColorWriteMs
        onTriggered: {
            if (root.waiting === null)
                return;
            root.flush();
            // Still dragging: the next change waits for the next interval.
            writeThrottle.restart();
        }
    }

    Component.onCompleted: {
        root.backend.watch(root.path);
        root.reload();
    }

    Component.onDestruction: root.flush()

    Connections {
        target: root.backend

        function onFileChanged(path: string): void {
            // The backend watches other files too: only this one is read again.
            if (path === root.path)
                root.reload();
        }
    }
}
