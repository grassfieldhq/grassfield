.pragma library

// The file the shell writes so that the Grassfield apps know what the compositor plugin offers (ADR-0015 Q4b: an app greys its
// minimize light when the plugin is absent). Pure functions, unit-tested (tests/unit/tst_capabilitiesfile.qml). The apps read
// the same file with apps/chromecaps.h (C++) and ui/Grassfield/Ui/WindowActions.js minimizeAvailable() (QML).
//
//   {"v":1,"pluginPresent":true,"features":["decorations","minimize",...]}

var VERSION = 1;

// $GRASSFIELD_STATE_HOME/capabilities.json in a dev session, else $XDG_RUNTIME_DIR/grassfield/capabilities.json (runtime dir:
// per session, gone at logout, so a stale answer never outlives the session; in Grassfield's own runtime folder, as the
// key-window file, so the apps watch that folder and not all of $XDG_RUNTIME_DIR: apps-misc H1). "" when neither directory
// is known.
function path(stateHome, runtimeDir) {
    if (stateHome)
        return String(stateHome) + "/capabilities.json";
    if (runtimeDir)
        return String(runtimeDir) + "/grassfield/capabilities.json";
    return "";
}

// The folder of path() that the shell makes, private (0700), before the first write: "" in a dev session.
function runtimeFolder(stateHome, runtimeDir) {
    if (stateHome || !runtimeDir)
        return "";
    return String(runtimeDir) + "/grassfield";
}

// The file's text. `features` are the plugin's feature names (strings only; anything else is dropped).
function payload(pluginPresent, features) {
    const list = (Array.isArray(features) ? features : []).filter(f => typeof f === "string");
    return JSON.stringify({v: VERSION, pluginPresent: !!pluginPresent, features: pluginPresent ? list : []}) + "\n";
}
