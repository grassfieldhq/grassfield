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

    // The countdown sentence is built in PopupKinds.js, called from a handler: a bare qsTr there stays English (nested capture,
    // from the system menu). All six strings use qsTranslate("PopupKinds", ...) and sit in the catalog under that context.
    function test_countdownSentencesCarryTheirContext() {
        const catalog = source("translations/grassfield_fr.ts");
        const ctx = catalog.substring(catalog.indexOf("<name>PopupKinds</name>"));
        const body = ctx.substring(0, ctx.indexOf("</context>"));
        const fn = source("shell/services/PopupKinds.js").split("function countdownMessage")[1];
        verify(fn.length > 0);
        compare(fn.replace(/qsTranslate\(/g, "").indexOf("qsTr("), -1, "no bare qsTr in countdownMessage");
        const re = /qsTranslate\("([A-Za-z]+)",\s*"((?:[^"\\]|\\.)*)"/g;
        let m, n = 0;
        while ((m = re.exec(fn)) !== null) {
            n++;
            compare(m[1], "PopupKinds");
            verify(body.indexOf("<source>" + m[2] + "</source>") >= 0, "in the PopupKinds catalog context: " + m[2]);
        }
        compare(n, 6);
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
