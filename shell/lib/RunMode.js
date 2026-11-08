.pragma library

// The one definition of the run-mode rule (ADR-0019, GF-089). Pure: every function takes the raw values of the
// environment variables (Quickshell.env(...): a string, undefined or null when unset) and nothing else, so the rule is
// unit-tested without a shell (tests/unit/tst_runmode.qml) against the vectors the C++ side is held to as well
// (tests/fixtures/run-mode-vectors.json). Readers of GRASSFIELD_* that feed it: shell/lib/Mode.qml for the shell's modules,
// and the security modules (shell/security/**), which import this file by a relative path and pass it GRASSFIELD_DEV and
// GRASSFIELD_SESSION themselves (ADR-0019 amendment, slice M2: no QML import path can replace that import).
//
// dev = GRASSFIELD_DEV exactly "1" AND GRASSFIELD_SESSION not "1". "dev" means both "test hooks allowed" and "never act on
// the owner's machine". The packaged session config sets GRASSFIELD_SESSION=1 (config/hypr/session.lua), so a
// GRASSFIELD_DEV=1 that leaks into a real session changes nothing there; the nested dev session never sets it
// (scripts/dev/devenv.sh unsets an inherited one). Anything but those exact strings leaves dev closed.

function dev(devValue, sessionValue) {
    return devValue === "1" && sessionValue !== "1";
}

// A packaged session: GRASSFIELD_SESSION exactly "1" (independent of dev).
function session(sessionValue) {
    return sessionValue === "1";
}

// Deterministic visual fixtures: dev AND GRASSFIELD_VISUAL_FIXTURES exactly "1".
function fixtures(devValue, sessionValue, fixturesValue) {
    return dev(devValue, sessionValue) && fixturesValue === "1";
}

// Whether this shell owns the session bus names (notification server, tray watcher) and may drive the owner's media
// players: always outside dev; in dev only on a private bus (GRASSFIELD_PRIVATE_BUS exactly "1").
function ownBus(devValue, sessionValue, privateBusValue) {
    return !dev(devValue, sessionValue) || privateBusValue === "1";
}

// Answer of a dev-gated IPC function outside a dev session (the security modules return it through their relative
// import of this file, every other module through Mode.refused).
var REFUSED = "refused";

// Update notices are for a packaged session only.
function updateNotices(sessionValue) {
    return session(sessionValue);
}

// A dev-plumbing variable (ADR-0019 table): its value in dev, "" otherwise.
function devPlumbing(devValue, sessionValue, value) {
    if (!dev(devValue, sessionValue))
        return "";
    return value === undefined || value === null ? "" : String(value);
}

// $GRASSFIELD_CONFIG_HOME wins (always honoured), else $XDG_CONFIG_HOME/grassfield, else <home>/.config/grassfield.
// An empty value counts as unset.
function configDir(configHome, xdgConfigHome, home) {
    if (configHome)
        return configHome;
    return (xdgConfigHome ? xdgConfigHome : home + "/.config") + "/grassfield";
}

// $GRASSFIELD_STATE_HOME wins (always honoured), else $XDG_STATE_HOME/grassfield, else <home>/.local/state/grassfield.
function stateDir(stateHome, xdgStateHome, home) {
    if (stateHome)
        return stateHome;
    return (xdgStateHome ? xdgStateHome : home + "/.local/state") + "/grassfield";
}

// GRASSFIELD_APPS_TRACE (always honoured): launcher tracing, exactly "1".
function appsTrace(value) {
    return value === "1";
}

// GRASSFIELD_APPS_GTK_USE_PORTAL (always honoured): env-grassfield sets it to "1" when the session routes GTK to the portal
// (ADR-0035 D-8, decision 2b-12); the shell, whose own unit clears GTK_USE_PORTAL, gives GTK_USE_PORTAL=1 back to the apps it
// starts. Exactly "1".
function appsGtkPortal(value) {
    return value === "1";
}

// GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME (always honoured): the session's Qt platform theme for the apps the shell starts (ADR-0054).
// The shell's own unit pins gtk3, and an app inherits the shell's environment, so session.lua names the session's choice here and
// the shell gives it back. Exactly "xdgdesktopportal"; "" otherwise.
function appsQtTheme(value) {
    return (value === "xdgdesktopportal") ? value : "";
}

// A raw home override such as GRASSFIELD_STATE_HOME (always honoured): its value, "" when unset or empty.
function homeOverride(value) {
    return value ? value : "";
}
