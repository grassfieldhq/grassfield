pragma Singleton
import QtQuick
import Quickshell
import "RunMode.js" as RunMode

// The reader of GRASSFIELD_* for the shell's modules (ADR-0019; enforced from M8 by tests/ci/run_mode.py). Consumers ask
// Mode; the rule itself is RunMode.js. Integrator decision for M2: the security modules (shell/security/**) do not use
// this singleton or the qs.lib module (a qs/lib directory on QML_IMPORT_PATH would replace it); they import RunMode.js by
// a relative path and pass it the two environment values themselves (tests/security/ipc_inventory.sh checks both forms).
// Consumers: every module of the shell outside shell/security (tests/ci/run_mode.py refuses a GRASSFIELD_ read anywhere else).
Singleton {
    id: root

    // Test hooks allowed and never act on the owner's machine: GRASSFIELD_DEV "1" and GRASSFIELD_SESSION not "1".
    readonly property bool dev: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))
    // A packaged session (GRASSFIELD_SESSION "1").
    readonly property bool session: RunMode.session(Quickshell.env("GRASSFIELD_SESSION"))
    // Deterministic visual fixtures (dev and GRASSFIELD_VISUAL_FIXTURES "1").
    readonly property bool fixtures: RunMode.fixtures(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"), Quickshell.env("GRASSFIELD_VISUAL_FIXTURES"))
    // The shell owns the session bus names and may drive real players: not dev, or dev on a private bus.
    readonly property bool ownBus: RunMode.ownBus(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"), Quickshell.env("GRASSFIELD_PRIVATE_BUS"))
    readonly property bool updateNotices: RunMode.updateNotices(Quickshell.env("GRASSFIELD_SESSION"))
    // Answer of a dev-gated IPC function outside a dev session.
    readonly property string refused: RunMode.REFUSED

    readonly property string configDir: RunMode.configDir(Quickshell.env("GRASSFIELD_CONFIG_HOME"), Quickshell.env("XDG_CONFIG_HOME"), Quickshell.env("HOME"))
    readonly property string stateDir: RunMode.stateDir(Quickshell.env("GRASSFIELD_STATE_HOME"), Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME"))
    readonly property string shellDir: Quickshell.shellDir
    // Raw GRASSFIELD_STATE_HOME ("" when unset): honoured always, like stateDir; for the two readers that need to know whether it is set.
    readonly property string stateHome: RunMode.homeOverride(Quickshell.env("GRASSFIELD_STATE_HOME"))
    // GRASSFIELD_APPS_TRACE "1" (always honoured).
    readonly property bool appsTrace: RunMode.appsTrace(Quickshell.env("GRASSFIELD_APPS_TRACE"))
    // GRASSFIELD_APPS_GTK_USE_PORTAL "1" (always honoured): the apps the shell starts get GTK_USE_PORTAL=1 (ADR-0035 D-8).
    readonly property bool appsGtkPortal: RunMode.appsGtkPortal(Quickshell.env("GRASSFIELD_APPS_GTK_USE_PORTAL"))
    // GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME "xdgdesktopportal" (always honoured): the apps the shell starts get that Qt platform theme
    // back (the shell's own unit pins gtk3, ADR-0054).
    readonly property string appsQtTheme: RunMode.appsQtTheme(Quickshell.env("GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME"))

    // A dev-plumbing variable GRASSFIELD_<name> (ADR-0019 table): its value in dev, "" otherwise.
    function devValue(name) {
        return RunMode.devPlumbing(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"), Quickshell.env("GRASSFIELD_" + name));
    }
}
