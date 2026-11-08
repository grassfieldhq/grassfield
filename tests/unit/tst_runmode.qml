import QtQuick
import QtTest
import "../../shell/lib/RunMode.js" as RunMode

// ADR-0019 (GF-089): the one run-mode rule (RunMode.js), held to tests/fixtures/run-mode-vectors.json (the C++ side, apps/runmode.h,
// is held to the same file from slice M6). The real Mode singleton (Quickshell.env) is held to the same vectors, in each environment,
// by tests/shell/run_mode_env.sh; that `import qs.lib` resolves, by tests/shell/run_mode_import/shell.qml.
TestCase {
    name: "RunMode"

    function vectors() {
        const request = new XMLHttpRequest();
        request.open("GET", Qt.resolvedUrl("../fixtures/run-mode-vectors.json"), false);
        request.send();
        return JSON.parse(request.responseText);
    }

    function test_modeVectors() {
        const modes = vectors().modes;
        verify(modes.length >= 15, "vectors read: " + modes.length);
        for (const v of modes) {
            const e = v.env;
            compare(RunMode.dev(e.GRASSFIELD_DEV, e.GRASSFIELD_SESSION), v.dev, v.name + " (dev)");
            compare(RunMode.session(e.GRASSFIELD_SESSION), v.session, v.name + " (session)");
            compare(RunMode.fixtures(e.GRASSFIELD_DEV, e.GRASSFIELD_SESSION, e.GRASSFIELD_VISUAL_FIXTURES), v.fixtures, v.name + " (fixtures)");
            compare(RunMode.ownBus(e.GRASSFIELD_DEV, e.GRASSFIELD_SESSION, e.GRASSFIELD_PRIVATE_BUS), v.ownBus, v.name + " (ownBus)");
            compare(RunMode.updateNotices(e.GRASSFIELD_SESSION), v.updateNotices, v.name + " (updateNotices)");
        }
    }

    function test_dirVectors() {
        const dirs = vectors().dirs;
        verify(dirs.length >= 5, "vectors read: " + dirs.length);
        for (const v of dirs) {
            const e = v.env;
            compare(RunMode.configDir(e.GRASSFIELD_CONFIG_HOME, e.XDG_CONFIG_HOME, e.HOME), v.configDir, v.name + " (configDir)");
            compare(RunMode.stateDir(e.GRASSFIELD_STATE_HOME, e.XDG_STATE_HOME, e.HOME), v.stateDir, v.name + " (stateDir)");
        }
    }

    function test_homeAndTraceVectors() {
        const v = vectors();
        for (const h of v.homes)
            compare(RunMode.homeOverride(h.env.GRASSFIELD_STATE_HOME), h.stateHome, h.name + " (stateHome)");
        for (const t of v.traces)
            compare(RunMode.appsTrace(t.env.GRASSFIELD_APPS_TRACE), t.appsTrace, t.name + " (appsTrace)");
        for (const x of [undefined, null, "", "true", "yes", " 1", 1, true])
            verify(!RunMode.appsTrace(x), JSON.stringify(x));
    }

    function test_portalVectors() {
        const rows = vectors().portal;
        verify(rows.length >= 5, "vectors read: " + rows.length);
        for (const p of rows)
            compare(RunMode.appsGtkPortal(p.env.GRASSFIELD_APPS_GTK_USE_PORTAL), p.appsGtkPortal, p.name + " (appsGtkPortal)");
        for (const x of [undefined, null, "", "true", "yes", " 1", 1, true])
            verify(!RunMode.appsGtkPortal(x), JSON.stringify(x));
    }

    function test_qtThemeVectors() {
        const rows = vectors().qttheme;
        verify(rows.length >= 5, "vectors read: " + rows.length);
        for (const p of rows)
            compare(RunMode.appsQtTheme(p.env.GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME), p.appsQtTheme, p.name + " (appsQtTheme)");
        for (const x of [undefined, null, "", "gtk3", " xdgdesktopportal", 1, true])
            compare(RunMode.appsQtTheme(x), "", JSON.stringify(x));
    }

    function test_plumbingVectors() {
        const rows = vectors().plumbing;
        verify(rows.length >= 4, "vectors read: " + rows.length);
        for (const v of rows) {
            const e = v.env;
            compare(RunMode.devPlumbing(e.GRASSFIELD_DEV, e.GRASSFIELD_SESSION, e[v.variable]), v.value, v.name);
        }
    }

    // Only exact strings open a gate, whatever else the caller passes.
    function test_closedWithoutExactDev() {
        const values = [undefined, null, "", "0", "true", "yes", " 1", "1 ", "01", 1, true];
        for (let i = 0; i < values.length; i++) {
            verify(!RunMode.dev(values[i], undefined), JSON.stringify(values[i]));
            verify(!RunMode.fixtures(values[i], undefined, "1"), JSON.stringify(values[i]) + " (fixtures)");
        }
    }

    function test_privateBusNeedsTheExactString() {
        const values = [undefined, null, "", "0", "true", 1, true];
        for (let i = 0; i < values.length; i++)
            verify(!RunMode.ownBus("1", undefined, values[i]), JSON.stringify(values[i]));
    }
}
