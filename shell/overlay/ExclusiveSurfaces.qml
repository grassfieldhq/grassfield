pragma ComponentBehavior: Bound
import QtQuick
import QtQml

// Mutual exclusion of the full-attention surfaces that take the keyboard (Overview, Apps, Search): opening one
// closes the others, so that the keyboard always belongs to the visible top surface (macOS model). The one place
// of the rule; shell.qml lists the surfaces. Each entry: {target, close}, where `target` has a boolean `open`
// and `close` is a function that dismisses it (graceful path, e.g. Overview's keyboard release). A surface built late has a
// null `target` until it exists (the capture toolbar, ADR-0056): it is skipped until then.
QtObject {
    id: root

    property var surfaces: []

    readonly property Instantiator watchers: Instantiator {
        model: root.surfaces

        delegate: Connections {
            id: watcher

            required property var modelData
            required property int index

            target: watcher.modelData.target

            function onOpenChanged(): void {
                if (!watcher.modelData.target || !watcher.modelData.target.open)
                    return;
                for (let i = 0; i < root.surfaces.length; i++) {
                    const other = root.surfaces[i];
                    if (i !== watcher.index && other.target && other.target.open)
                        other.close();
                }
            }
        }
    }
}
