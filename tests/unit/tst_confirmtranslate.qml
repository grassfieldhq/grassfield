import QtQuick
import QtTest

// The session alerts (Log Out, Restart, Shut Down, Empty Trash, Force Quit) build their texts in a signal handler: there qsTr
// stayed English in a French session (the catalog held the strings; nested capture, UI audit 2026-11-05), while qsTranslate with
// the file's own context returned the French text, as for the widgets' Registry. Each Popups.confirm call therefore uses
// qsTranslate with its file's context, and the catalog holds every string under that context.
TestCase {
    name: "ConfirmTranslate"

    readonly property var files: [
        {path: "shell/overlay/SystemMenu.qml", context: "SystemMenu"},
        {path: "shell/search/Search.qml", context: "Search"},
        {path: "shell/overlay/DockMenu.qml", context: "DockMenu"}
    ]

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    function test_confirmTextsCarryTheirContext() {
        const catalog = source("translations/grassfield_fr.ts");
        for (const f of files) {
            const calls = source(f.path).split("\n").filter(l => l.indexOf("Popups.confirm(") >= 0);
            verify(calls.length > 0, f.path + ": has confirm calls");
            for (const line of calls) {
                compare(line.replace(/qsTranslate\(/g, "").indexOf("qsTr("), -1, f.path + ": no bare qsTr in " + line.trim());
                const re = /qsTranslate\("([A-Za-z]+)",\s*"((?:[^"\\]|\\.)*)"/g;
                let m;
                while ((m = re.exec(line)) !== null) {
                    compare(m[1], f.context, f.path + ": the file's own context");
                    const text = m[2].replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
                    verify(catalog.indexOf("<source>" + text + "</source>") >= 0, f.path + ": in the catalog: " + m[2]);
                }
            }
        }
    }
}
