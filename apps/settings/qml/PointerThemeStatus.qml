import QtQuick

// What the shell reports about the pointer colours (shell/platform/PointerTheme.qml writes pointer-theme.json next to
// grassfield.json): {"state": "default|building|ready|failed", "outline", "fill", "reason"}. The report only counts for the
// colours it names, so a stale file of other colours never shows. Read-only; a missing or malformed file is "unknown".
Item {
    id: root

    required property var backend
    // grassfield.json, the file the status sits next to.
    required property string configPath
    // The colours now chosen (#rrggbb, lower case).
    property string outline: ""
    property string fill: ""

    readonly property string path: root.configPath.replace(/[^/]*$/, "") + "pointer-theme.json"
    property var report: ({})
    // "building" | "ready" | "failed" for the chosen colours, "" when the shell did not say.
    readonly property string result: root.report.state !== undefined && String(root.report.outline).toLowerCase() === root.outline && String(root.report.fill).toLowerCase() === root.fill ? String(root.report.state) : ""
    // The kind of failure ("builder", "tool:NAME", "folder", "failed"): the pane says it in its own language.
    readonly property string code: root.result === "failed" && typeof root.report.code === "string" ? root.report.code.substring(0, 64) : ""
    readonly property string reason: root.result === "failed" && typeof root.report.reason === "string" ? root.report.reason.substring(0, 160) : ""

    visible: false

    function reload(): void {
        const file = root.backend.readText(root.path);
        let parsed = {};
        if (file.exists && file.ok) {
            try {
                const value = JSON.parse(file.text);
                if (value !== null && typeof value === "object" && !Array.isArray(value))
                    parsed = value;
            } catch (e) {
                parsed = {};
            }
        }
        root.report = parsed;
    }

    Component.onCompleted: {
        root.backend.watch(root.path);
        root.reload();
    }

    Connections {
        target: root.backend

        function onFileChanged(path: string): void {
            // The backend watches other files too: only this one is read again.
            if (path === root.path)
                root.reload();
        }
    }
}
