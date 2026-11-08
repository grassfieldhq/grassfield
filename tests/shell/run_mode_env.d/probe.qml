import QtQuick
import Quickshell
import qs.lib

// Probe of tests/shell/run_mode_env.sh: prints every member of the real Mode singleton and the value of each in the environment the
// harness set, as `RUNMODE {json}`, at the start, whenever it differs from the read before (every 20 ms) and after 1.2 s, so that a gate that opens later (a
// timer, a binding that changes) shows as a difference. GF_PROBE_NAMES is the comma list of dev-plumbing names
// to ask Mode.devValue about.
ShellRoot {
    id: root

    property int reads: 0
    property string last: ""

    function snapshot(): string {
        const members = [];
        for (const key in Mode)
            members.push(key);
        const devValues = {};
        for (const name of (Quickshell.env("GF_PROBE_NAMES") || "").split(",").filter(n => n !== ""))
            devValues[name] = Mode.devValue(name);
        return JSON.stringify({
            members: members.sort(),
            dev: Mode.dev,
            session: Mode.session,
            fixtures: Mode.fixtures,
            ownBus: Mode.ownBus,
            updateNotices: Mode.updateNotices,
            refused: Mode.refused,
            configDir: Mode.configDir,
            stateHome: Mode.stateHome,
            appsTrace: Mode.appsTrace,
            appsGtkPortal: Mode.appsGtkPortal,
            appsQtTheme: Mode.appsQtTheme,
            stateDir: Mode.stateDir,
            shellDirIsTheShellDir: Mode.shellDir === Quickshell.shellDir && Mode.shellDir !== "",
            devValues: devValues
        });
    }

    Timer {
        interval: 20
        repeat: true
        running: true
        onTriggered: {
            root.reads++;
            // Every 20 ms for about 1.2 s: the first read, any read that differs from the one before, and the last.
            const now = root.snapshot();
            if (root.reads === 1 || root.reads >= 60 || now !== root.last)
                console.log("RUNMODE " + root.reads + " " + now);
            root.last = now;
            if (root.reads >= 60)
                Qt.exit(0);
        }
    }
}
