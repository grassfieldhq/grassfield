import QtQuick
import "General.js" as General
import "Privacy.js" as Privacy

// The portal permission store as Privacy & Security shows it (ADR-0030; Privacy.js): the state, read when a pane opens and
// again after each change; why it could not be read; each application's name and icon from its desktop entry; and the two
// actions, through SystemService (so never in a dev session).
QtObject {
    id: root

    required property var backend
    required property var system

    property var state: Privacy.parse("")
    property bool loaded: false
    // Why the store could not be read, "" when it was.
    property string error: ""
    // app id -> {name, icon, host, devices}: the name and icon of its first visible desktop entry (its id when none has one),
    // host from every applications folder that has its entry (Privacy.hostApp), devices from its Flatpak metadata
    // (Privacy.flatpakDevices). No prototype: an id such as "constructor" is a key like any other.
    property var apps: Object.create(null)
    // An action is under way: the switches and − wait for it.
    property bool busy: false
    // The saved selections of one application still to forget (one action each): [{key, token}].
    property var forgetting: []
    // The tag of the action under way (Privacy.actTag: one per category, so a failure shows only under its own list).
    property string pendingTag: ""

    function reload(): void {
        root.system.queryBus("privacy.state", "privacy.state");
    }

    function describe(app: string): var {
        // An app the portal could not name (a saved selection only, Privacy.parse).
        if (app === "")
            return {name: qsTr("Other Apps"), icon: "", host: false, devices: false};
        let found = {name: app, icon: "", host: false};
        let named = false;
        const entries = [];
        const file = Privacy.entryFile(app);
        for (const dir of file !== "" ? Privacy.hostCheckDirs(root.backend.applicationDirs) : []) {
            const r = root.backend.readText(dir + "/" + file);
            if (!r.exists)
                continue;
            // There but unreadable: it counts (in doubt, the switch stays), its name is not known.
            if (!r.ok) {
                entries.push({dir: dir, hidden: true});
                continue;
            }
            const e = General.parseDesktopEntry(r.text, Qt.locale().name);
            entries.push({dir: dir, hidden: e.hidden});
            if (!named && !e.hidden) {
                found = {name: e.name !== "" ? e.name : app, icon: e.icon, host: false};
                named = true;
            }
        }
        found.host = Privacy.hostApp(app, entries);
        // A Flatpak that may open device nodes itself (Privacy.flatpakDevices): read only, from its installed metadata.
        found.devices = !found.host && Privacy.flatpakDevices(app, Privacy.flatpakInstalls(root.backend.applicationDirs), path => {
            const r = root.backend.readText(path);
            return r.ok ? r.text : "";
        });
        return found;
    }

    // One category's applications by name: [{app, allowed} or {app, tokens}, with name, icon, host and devices].
    function list(key: string): var {
        return (root.state[key] || []).map(e => Object.assign({}, e, root.apps[e.app] ?? {name: e.app, icon: "", host: false, devices: false}))
            .sort((a, b) => a.name.localeCompare(b.name));
    }

    function setAllowed(key: string, app: string, on: bool): void {
        if (root.busy || !root.system.act("privacy permission", Privacy.allow(key, app, on), Privacy.actTag(key)))
            return;
        root.busy = true;
        root.pendingTag = Privacy.actTag(key);
    }

    function forget(key: string, entry: var): void {
        if (root.busy || !entry || !Array.isArray(entry.tokens) || entry.tokens.length === 0)
            return;
        root.forgetting = entry.tokens.slice(1).map(t => ({key: key, token: t}));
        if (root.system.act("saved screen selection", Privacy.forget(key, entry.tokens[0]), Privacy.actTag(key))) {
            root.busy = true;
            root.pendingTag = Privacy.actTag(key);
        } else {
            root.forgetting = [];
        }
    }

    Component.onCompleted: root.reload()

    readonly property Connections results: Connections {
        target: root.backend

        function onFailed(tag: string, reason: string): void {
            if (tag === "privacy.state")
                root.error = reason !== "" ? reason : "-";
            else if (tag !== "" && tag === root.pendingTag)
                root.forgetting = [];
        }

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "privacy.state") {
                root.loaded = true;
                if (!ok)
                    return;
                root.error = "";
                root.state = Privacy.parse(output);
                const names = Object.assign(Object.create(null), root.apps);
                for (const key of Privacy.SWITCHES.concat(Privacy.SAVED)) {
                    for (const e of root.state[key]) {
                        if (names[e.app] === undefined)
                            names[e.app] = root.describe(e.app);
                    }
                }
                root.apps = names;
            } else if (tag !== "" && tag === root.pendingTag) {
                const next = root.forgetting[0];
                root.forgetting = root.forgetting.slice(1);
                if (ok && next !== undefined && root.system.act("saved screen selection", Privacy.forget(next.key, next.token), Privacy.actTag(next.key)))
                    return;
                root.forgetting = [];
                root.busy = false;
                root.pendingTag = "";
                root.reload();
            }
        }
    }
}
