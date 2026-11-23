pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Displays.js" as Displays

// Which display a group of settings is for: "All Displays" (the top-level keys) or one connected display whose own entry of
// `<group>.outputs` overrides some of them (DisplayScope, docs/specs/settings.md "Scope of a setting"). One instance per page; the
// page shows `ScopeGroup` over it and reads and writes its rows through scoped() and setScoped().
QtObject {
    id: root

    required property var store
    // The Settings backend (its screens()); null in a test of a page without one: then no display is known.
    property var backend: null
    // Key prefix of the group ("dock", "menubar", "hotCorners") and the DisplayScope schema of its per-display fields.
    required property string group
    required property var schema

    // "all" = All Displays, else a display key (WallpaperConfig.displayKey).
    property string displayId: "all"
    // The connected displays: [{key, name, model, serial, label}], named as Settings > Displays names them.
    // Follows displays plugged or unplugged while the page is open (the binding reads the application's screens).
    property var displays: {
        void Qt.application.screens;
        return root.readDisplays();
    }
    readonly property int displayCount: root.displays.length
    readonly property var currentDisplay: root.displayId === "all" ? null : (root.displays.find(d => d.key === root.displayId) || null)
    // The store is bound after the page creates its children: nothing is read before it is there.
    readonly property var outputs: root.store ? root.store.value(root.group + ".outputs") : []
    readonly property bool hasOverride: root.currentDisplay !== null && DisplayScope.hasOverride(root.schema, root.outputs, root.currentDisplay)

    function readDisplays(): var {
        const list = root.backend && typeof root.backend.screens === "function" ? root.backend.screens() : [];
        const named = list.map(s => {
            const d = DisplayScope.identity(s);
            d.key = WallpaperConfig.displayKey(d);
            d.label = Displays.isBuiltIn(d) ? qsTr("Built-in Display") : (String(d.model).trim() !== "" ? String(d.model).trim() : d.name);
            return d;
        });
        const twins = named.map(d => named.filter(o => o.label === d.label).length > 1);
        return named.map((d, i) => {
            if (twins[i])
                d.label = qsTr("%1 (%2)").arg(d.label).arg(d.name);
            return d;
        });
    }

    // The value of a scoped field for the display chosen.
    function scoped(field: string): var {
        const globals = {};
        globals[field] = root.store ? root.store.value(root.group + "." + field) : SettingsContract.DEFAULTS[root.group + "." + field];
        return DisplayScope.resolve(root.schema, globals, root.outputs, root.currentDisplay)[field];
    }

    // Writes {field: value}: to the chosen display's entry, or to the top-level keys under All Displays (`soon`: a slider's
    // coalesced write).
    function setScoped(fields: var, soon: bool): void {
        if (root.currentDisplay === null) {
            const keys = {};
            for (const f of Object.keys(fields))
                keys[root.group + "." + f] = fields[f];
            const names = Object.keys(keys);
            if (soon)
                root.store.setManySoon(keys);
            else if (names.length === 1)
                root.store.set(names[0], keys[names[0]]);
            else
                root.store.setMany(keys);
            return;
        }
        const next = DisplayScope.withOverride(root.schema, root.outputs, root.currentDisplay, fields);
        if (soon)
            root.store.setSoon(root.group + ".outputs", next);
        else
            root.store.set(root.group + ".outputs", next);
    }

    // The chosen display follows All Displays again (its entry is removed).
    function useAllDisplays(): void {
        if (root.currentDisplay !== null)
            root.store.set(root.group + ".outputs", DisplayScope.withoutOverride(root.schema, root.outputs, root.currentDisplay));
    }

    onDisplaysChanged: {
        if (root.displayId !== "all" && !root.displays.some(d => d.key === root.displayId))
            root.displayId = "all";
    }
}
