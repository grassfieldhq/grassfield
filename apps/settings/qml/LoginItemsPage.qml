pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "General.js" as General

// General > Login Items (the structure of the macOS 15 capture, docs/audits/settings-parity-2026-10-26.md § Login Items).
// Open at Login: the XDG autostart entries that start in this session (the user's folder over the system's, General.loginItems),
// each with a switch; + adds an application (a copy of its desktop entry in the user's folder), − removes an item the user
// added. A system item is switched off by a user override (Hidden=true) and back on by removing it again. Allow in the
// Background: the user's own systemd services (the session bus, ADR-0030: no privilege), each with a switch. Writes go only to
// the user's autostart folder (Backend.writeAutostart, removeAutostart; a dev session only under the worktree's .dev).
// Not built (docs/specs/settings.md): Extensions; the Hyprland exec lines of the user's own files are never touched.
SettingsPage {
    id: root

    required property var backend
    required property var system

    // + : Main.qml opens AppPickerSheet with the applications and hands the choice back to add().
    signal addRequested(var apps)

    title: qsTr("Login Items")

    property var items: []
    property var units: []
    property string selectedFile: ""
    property string writeError: ""
    property string pendingUnit: ""

    readonly property var selected: root.items.find(i => i.file === root.selectedFile) ?? null
    // Only an item the user added can go; a system one is switched off instead.
    readonly property bool canRemove: root.selected !== null && root.selected.user && !root.selected.system

    function entries(dir: string): var {
        return root.backend.desktopEntries(dir).map(f => ({file: f, text: root.backend.readText(dir + "/" + f).text}));
    }

    function reload(): void {
        let system = [];
        for (const dir of root.backend.systemAutostartDirs)
            system = system.concat(root.entries(dir));
        root.items = General.loginItems(root.entries(root.backend.autostartDir), system, root.backend.currentDesktops, Qt.locale().name);
        if (root.selected === null)
            root.selectedFile = "";
    }

    // + : the applications folders are read off the GUI thread (Backend.readDesktopEntries), and the picker opens with them; a
    // backend without that door (a test's) is read here.
    function askApplications(): void {
        if (typeof root.backend.readDesktopEntries === "function") {
            root.backend.readDesktopEntries(root.backend.applicationDirs, "login.applications");
            return;
        }
        let all = [];
        for (const dir of root.backend.applicationDirs)
            all = all.concat(root.entries(dir));
        root.addRequested(General.applications(all, root.backend.currentDesktops, Qt.locale().name));
    }

    function write(file: string, text: string): void {
        const path = root.backend.autostartDir + "/" + file;
        const reason = text === "" ? root.backend.removeAutostart(path) : root.backend.writeAutostart(path, text);
        root.writeError = reason;
        root.reload();
    }

    function setEnabled(item: var, on: bool): void {
        if (!General.validEntryFile(item.file))
            return;
        const userText = item.user ? root.backend.readText(root.backend.autostartDir + "/" + item.file).text : "";
        if (!item.user)
            root.write(item.file, General.hiddenEntryText());
        else if (on && item.system && General.onlyOverride(userText))
            root.write(item.file, "");
        else
            root.write(item.file, General.setHidden(userText, !on));
    }

    function add(app: var): void {
        if (General.validEntryFile(app.file)) {
            root.write(app.file, General.loginEntryText(app.text));
            root.selectedFile = app.file;
        }
    }

    function removeSelected(): void {
        if (root.canRemove)
            root.write(root.selectedFile, "");
    }

    function toggleUnit(unit: var, on: bool): void {
        if (root.system.act("background item", General.userEnable(unit.unit, on), "units.act"))
            root.pendingUnit = unit.unit;
    }

    Component.onCompleted: {
        root.reload();
        root.system.queryBus("user.units", "user.units");
    }

    Connections {
        target: root.backend
        ignoreUnknownSignals: true

        function onDesktopEntriesRead(tag: string, entries: var): void {
            if (tag === "login.applications")
                root.addRequested(General.applications(entries, root.backend.currentDesktops, Qt.locale().name));
        }

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "user.units") {
                // Each with its own description (the unit file's [Unit] Description=), read once.
                root.units = (ok ? General.parseUnits(output) : []).map(u => Object.assign({}, u, {description: General.unitDescription(root.backend.readText(u.path).text)}));
            } else if (tag === "units.act") {
                root.pendingUnit = "";
                root.system.queryBus("user.units", "user.units");
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Open at Login")
        captionDetail: qsTr("These items open automatically when you log in.")
        footnote: root.writeError !== "" ? qsTr("The change could not be saved: %1.").arg(root.writeError) : ""

        // The list is one focus stop: Up and Down move the selection, Delete removes it (macOS table).
        FocusScope {
            id: list
            width: parent.width
            height: rows.height
            activeFocusOnTab: true
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Open at Login")

            Keys.onPressed: event => {
                const i = root.items.findIndex(it => it.file === root.selectedFile);
                if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                    if (root.items.length > 0)
                        root.selectedFile = root.items[Math.max(0, Math.min(root.items.length - 1, i < 0 ? 0 : i + (event.key === Qt.Key_Down ? 1 : -1)))].file;
                    event.accepted = true;
                } else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
                    root.removeSelected();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Space && root.selected !== null) {
                    root.setEnabled(root.selected, !root.selected.enabled);
                    event.accepted = true;
                }
            }

            Column {
                id: rows
                width: parent.width

                Repeater {
                    model: root.items

                    LoginItemRow {
                        required property var modelData
                        icon: modelData.icon
                        title: modelData.name
                        subtitle: modelData.system ? "" : qsTr("Added by you")
                        checked: modelData.enabled
                        selected: modelData.file === root.selectedFile
                        onClicked: {
                            root.selectedFile = modelData.file;
                            list.forceActiveFocus();
                        }
                        onToggled: c => root.setEnabled(modelData, c)
                    }
                }

                EmptyListRow {
                    visible: root.items.length === 0
                    text: qsTr("No login items")
                }
            }

            // After a key only (ADR-0039 step 7).
            KeyFocus {
                id: listFocus
                target: list
            }

            FocusRing {
                shapeRadius: Tokens.radiusGroup
                visible: listFocus.active
            }
        }

        ListFooter {
            canRemove: root.canRemove
            addName: qsTr("Add a login item")
            removeName: qsTr("Remove the selected login item")
            onAddClicked: root.askApplications()
            onRemoveClicked: root.removeSelected()
        }
    }

    SettingsGroup {
        caption: qsTr("Allow in the Background")
        captionDetail: qsTr("Your own services keep running in the background after you log in.")
        footnote: root.system.errors["units.act"] !== undefined ? qsTr("The change could not be made: %1.").arg(root.system.errors["units.act"]) : ""

        Repeater {
            model: root.units

            SettingsRow {
                id: unitRow
                required property var modelData
                title: modelData.unit.replace(/\.service$/, "")
                // The unit's own description, else where it lives.
                subtitle: root.pendingUnit === modelData.unit ? qsTr("Changing…") : (modelData.description || modelData.path)
                Toggle {
                    accessibleName: unitRow.modelData.unit
                    enabled: root.pendingUnit === "" && (unitRow.modelData.state === "enabled" || unitRow.modelData.state === "disabled")
                    checked: unitRow.modelData.state === "enabled"
                    onToggled: c => root.toggleUnit(unitRow.modelData, c)
                }
            }
        }
        EmptyListRow {
            visible: root.units.length === 0
            text: qsTr("No background items")
        }
    }

    DevNote {
        system: root.system
    }
}
