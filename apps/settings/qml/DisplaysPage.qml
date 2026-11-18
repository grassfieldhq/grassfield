pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Displays.js" as Displays
import "System.js" as System

// Displays as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Displays): the band with each display's picture
// and name (a click chooses which one the groups set), the resolution choices (Larger Text … More Space), Brightness for a
// built-in panel, Refresh rate and Rotation, and Arrange… with several displays. The displays come from the state the shell
// publishes (ADR-0031: this app never talks to Hyprland). A change is a trial: the page writes the trial file, the shell applies
// it and takes it back after 15 seconds unless the sheet's Keep came first (Keep writes displays.conf, which the session reads
// at every start). Brightness goes through SystemService (`brightnessctl`, never in a dev session); an external display's
// over DDC/CI (ADR-0045 OC-4) is Omarchy's `omarchy-brightness-display-ddc`, shown only when the display answers it.
SettingsPage {
    id: root

    required property var backend
    required property var system
    // The settings store (ConfigStore): `displays.main`, the main display's choice (ADR-0044).
    required property var store

    // Main.qml opens the sheets and hands the answers back (keep, revert, arrange).
    signal keepRequested(int until)
    signal trialEnded
    signal arrangeRequested(var monitors)

    title: qsTr("Displays")

    property bool answered: false
    // Displays.parseState of the shell's state file, or null.
    property var displayState: null
    property string selected: ""
    // The kept lines (displays.conf) when the trial was written, the trial's id and lines.
    property string trialId: ""
    property var trialLines: []
    // What the trial changes, shown as chosen until the display says so ({scale}, {hz}, {transform} or {arranged}).
    property var trialChange: null
    // Why the last change did not happen.
    property string notice: ""
    // Keep was taken (only while the shell says the trial is applied: the mode is on screen); displays.conf is written once the
    // shell says it kept it, never before (a Keep that comes too late, after the shell's deadline, writes nothing).
    property bool keeping: false
    // The shell has applied the trial being shown: Keep can be taken (DisplayKeepSheet.canKeep).
    readonly property bool trialApplied: root.trialId !== "" && root.displayState !== null && root.displayState.trial !== null
        && root.displayState.trial.id === root.trialId && root.displayState.trial.state === "applied"

    readonly property var monitors: root.displayState ? root.displayState.monitors : []
    readonly property var monitor: root.monitors.find(m => m.name === root.selected) ?? root.monitors[0] ?? null
    readonly property var choices: root.monitor ? Displays.scaleChoices(root.monitor) : []
    readonly property var rates: root.monitor ? Displays.refreshRates(root.monitor) : []
    readonly property bool nameable: root.monitor !== null && Displays.descOf(root.monitor) !== ""
    readonly property bool settable: root.nameable && root.trialId === ""
    // The backlight as last read. A drag in progress keeps its own value (as Sound's volume does): the reading taken meanwhile
    // would move the knob back under the pointer; the next one follows.
    property var backlight: null
    // The selected external display's brightness over DDC/CI ({output, level}), or null while it has not answered: no slider and
    // no message (macOS shows none for a display it cannot control). Read when the display is selected and after a drag, never
    // on the page's refresh (each read is i2c traffic to the display; DDC/CI has no change event).
    property var ddc: null
    readonly property bool builtIn: root.monitor !== null && Displays.isBuiltIn(root.monitor)
    // The selected display's name: `monitor` is a new object at every reading of the state, its name changes only with the
    // selection (or a replug).
    readonly property string monitorName: root.monitor !== null ? root.monitor.name : ""
    // The Brightness row is shown: the built-in panel with a backlight, or an external display that answered.
    readonly property bool hasBrightness: root.monitor !== null
        && (root.builtIn ? root.backlight !== null : root.ddc !== null && root.ddc.output === root.monitor.name)

    // Ask the selected external display its level (the answer comes back tagged with its name).
    function readDdc(): void {
        const name = root.builtIn ? "" : root.monitorName;
        if (root.ddc !== null && root.ddc.output !== name)
            root.ddc = null;
        const argv = System.ddcBrightnessQuery(name);
        if (argv !== null)
            root.system.queryWithin(argv, "display.ddc@" + name, System.DDC_WAIT_MS);
    }

    onMonitorNameChanged: root.readDdc()

    // ---- the main display (ADR-0044) ----
    // The outputs as the shell identifies them: Hyprland's make, model and serial from the state the shell publishes (Qt's
    // screens have no serial under Wayland).
    readonly property var connected: root.monitors.map(m => ({name: m.name, make: m.make, model: m.model, serial: m.serial}))
    readonly property var mainEntries: root.store.value("displays.main")
    readonly property string mainName: DisplayRole.resolve(root.mainEntries, root.connected).name
    readonly property bool isMain: root.monitor !== null && root.monitor.name === root.mainName

    // Make the display `name` the main display of the connected set (macOS: Use as > Main display).
    function makeMain(name: string): void {
        const key = DisplayRole.keyOf(root.connected, name);
        if (key !== "" && name !== root.mainName)
            root.store.set("displays.main", DisplayRole.withMain(root.mainEntries, root.connected, key));
    }

    // "Use as" (macOS 27, several displays): every display offers Main display and Extended display, the main one too (the
    // owner's rc6 report: the main display's pop-up offered nothing else, so the role could not be moved from the display shown
    // first). Mirroring is not offered (ADR-0044 D-4).
    readonly property var useAsChoices: root.monitors.length > 1 ? [{id: "main", text: qsTr("Main display")}, {id: "extended", text: qsTr("Extended display")}] : []
    readonly property string useAsValue: root.isMain ? "main" : "extended"

    // The selected display's new role: Main display makes it main; Extended display on the main display hands the role to
    // another one (DisplayRole.successor: the built-in panel, else the next display). Anything else changes nothing.
    function useAs(role: string): void {
        if (root.monitor === null || root.monitors.length < 2 || role === root.useAsValue)
            return;
        if (role === "main") {
            root.makeMain(root.monitor.name);
        } else if (role === "extended") {
            const i = DisplayRole.identities(root.connected).indexOf(DisplayRole.successor(root.connected, DisplayRole.keyOf(root.connected, root.monitor.name)));
            if (i >= 0)
                root.makeMain(root.connected[i].name);
        }
    }

    function refresh(): void {
        const path = root.backend.displaysStateFile;
        const r = path !== "" ? root.backend.readText(path) : {ok: false};
        root.displayState = r.ok ? Displays.parseState(r.text) : null;
        if (!brightness.busy)
            root.backlight = root.displayState ? root.displayState.backlight : null;
        root.answered = true;
        // The shell took the trial back (its deadline, or Revert): the sheet goes.
        const t = root.displayState ? root.displayState.trial : null;
        if (root.keeping)
            root.settleKeep();
        else if (root.trialId !== "" && t && t.id === root.trialId && t.state === "reverted")
            root.endTrial();
    }

    function endTrial(): void {
        root.trialId = "";
        root.trialChange = null;
        root.keeping = false;
        applied.stop();
        keepAnswer.stop();
        root.trialEnded();
    }

    // Try new lines for some displays (the others keep their kept lines).
    function tryLines(fresh: var, change: var): void {
        root.notice = "";
        if (fresh.some(l => l === ""))
            return;
        const lines = Displays.mergeLines(root.backend.displaysConf(), fresh);
        const id = Displays.trialId(Math.random);
        const until = Math.floor(Date.now() / 1000) + Tokens.settingsDisplayTrialSeconds;
        const error = root.backend.writeDisplayTrial(id, until, lines);
        if (error !== "") {
            root.notice = qsTr("The change could not be tried: %1").arg(error);
            return;
        }
        root.trialId = id;
        root.trialLines = lines;
        root.trialChange = change;
        applied.restart();
        root.keepRequested(until);
    }

    function tryChange(change: var): void {
        if (!root.settable)
            return;
        const fresh = [Displays.lineFor(root.monitor, change)];
        // A new scale or rotation changes the display's size: the displays beside it move with its edge in the same trial, or
        // one with a kept position would end up under it or apart from it (Displays.resized).
        if (change.scale !== undefined || change.transform !== undefined) {
            const at = Displays.resized(root.monitors, root.monitor.name, change);
            for (const m of root.monitors) {
                const p = at[m.name];
                // A display that cannot be named has no line: it stays where the compositor puts it.
                if (m.name !== root.monitor.name && p && (p.x !== Math.round(m.x) || p.y !== Math.round(m.y)) && Displays.descOf(m) !== "")
                    fresh.push(Displays.lineFor(m, {x: p.x, y: p.y}));
            }
        }
        root.tryLines(fresh, change);
    }

    // DisplayKeepSheet's answers. Keep is taken only while the shell says the trial is applied: a Keep pressed before the
    // mode is on screen (Return twice) is not held for later, it is refused (the sheet stays open and says so). A second Keep
    // changes nothing. Returns whether it was taken.
    function keep(): bool {
        if (!root.trialApplied || root.keeping)
            return false;
        root.keeping = true;
        root.backend.markDisplayTrial("kept", root.trialId);
        keepAnswer.restart();
        return true;
    }

    // After Keep: the shell kept the trial → write displays.conf (the next login reads it); the shell took it back first (its
    // deadline) → nothing is written.
    function settleKeep(): void {
        const t = root.displayState ? root.displayState.trial : null;
        if (!root.keeping || t === null || t.id !== root.trialId)
            return;
        if (t.state === "kept") {
            const error = root.backend.writeDisplaysConf(root.trialLines);
            if (error !== "")
                root.notice = qsTr("The display settings could not be saved for the next login: %1").arg(error);
            root.endTrial();
        } else if (t.state === "reverted") {
            root.notice = qsTr("The display settings were taken back before they were kept.");
            root.endTrial();
        }
    }

    function revert(): void {
        if (root.trialId === "")
            return;
        root.backend.markDisplayTrial("revert", root.trialId);
        root.endTrial();
    }

    // ArrangeSheet's answer: [{name, x, y}] for the displays that moved.
    function arrange(positions: var): void {
        if (root.trialId !== "")
            return;
        const fresh = positions.map(p => {
            const m = root.monitors.find(x => x.name === p.name);
            return m ? Displays.lineFor(m, {x: p.x, y: p.y}) : "";
        });
        root.tryLines(fresh, {arranged: true});
    }

    Connections {
        target: root.backend

        function onFileChanged(path: string): void {
            if (path === root.backend.displaysStateFile)
                root.refresh();
        }

        // The DDC/CI level of the display named in the tag; a display that did not answer has none. A drag in progress keeps
        // its own value.
        function onFinished(tag: string, ok: bool, output: string): void {
            if (!tag.startsWith("display.ddc@") || brightness.busy)
                return;
            const name = tag.slice("display.ddc@".length);
            if (root.builtIn || root.monitorName !== name)
                return;
            const level = ok ? System.parseDdcLevel(output) : -1;
            root.ddc = level >= 0 ? {output: name, level: level} : null;
        }
    }

    // A drag on an external display ended (its last write answered): read the level the display took (the command keeps it
    // within 1..100).
    Connections {
        target: brightness

        function onBusyChanged(): void {
            if (!brightness.busy && !root.builtIn)
                root.readDdc();
        }
    }

    Timer {
        interval: Tokens.settingsSystemRefreshMs
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    // Keep marked: the shell says it kept the trial within this long; otherwise nothing is written and its own countdown takes
    // the trial back.
    Timer {
        id: keepAnswer
        interval: Tokens.settingsDisplayAppliedMs
        onTriggered: {
            root.notice = qsTr("The display settings were not kept: the Grassfield shell did not answer.");
            root.endTrial();
        }
    }

    // The shell says it applied the trial within this long, or the change did not happen (no shell, or a shell without ADR-0031).
    Timer {
        id: applied
        interval: Tokens.settingsDisplayAppliedMs
        onTriggered: {
            const t = root.displayState ? root.displayState.trial : null;
            if (root.trialId !== "" && !(t && t.id === root.trialId)) {
                root.backend.markDisplayTrial("revert", root.trialId);
                root.endTrial();
                root.notice = qsTr("The change was not applied: the Grassfield shell did not answer.");
            }
        }
    }

    Component.onCompleted: {
        if (root.backend.displaysStateFile !== "")
            root.backend.watch(root.backend.displaysStateFile);
        root.refresh();
    }

    DisplayHeader {
        visible: root.monitors.length > 0
        monitors: root.monitors
        selected: root.monitor ? root.monitor.name : ""
        mainName: root.mainName
        paneWidth: root.width
        onPicked: name => root.selected = name
    }

    SettingsGroup {
        visible: root.answered && root.monitors.length === 0
        footnote: qsTr("Display settings are not available: the Grassfield shell has not described the displays.")
    }

    // macOS 27: with several displays, "Use as" is the first of the selected display's settings. The main display holds the
    // Dock, the desktop icons and the notifications (ADR-0044). Applied at once (no trial: nothing about the picture changes).
    SettingsGroup {
        visible: root.monitor !== null && root.useAsChoices.length > 0

        SettingsRow {
            title: qsTr("Use as")
            subtitle: root.isMain ? qsTr("Holds the Dock, the desktop icons and the notifications.") : ""

            ComboBox {
                inline: true
                accessibleName: qsTr("Use as")
                model: root.useAsChoices
                value: root.useAsValue
                onPicked: id => root.useAs(id)
            }
        }
    }

    SettingsGroup {
        visible: root.monitor !== null && root.choices.length > 1

        ResolutionChoices {
            choices: root.choices
            current: root.monitor ? Displays.currentChoice(root.choices, root.monitor.scale) : -1
            pending: root.trialChange && root.trialChange.scale !== undefined ? Displays.currentChoice(root.choices, root.trialChange.scale) : -1
            settable: root.settable
            onChosen: index => {
                if (index !== Displays.currentChoice(root.choices, root.monitor.scale))
                    root.tryChange({scale: root.choices[index].scale});
            }
        }
    }

    // The same row for the built-in panel (its backlight) and for an external display that answers DDC/CI (one command at a
    // time: a DDC write takes 50 to 200 ms; the last value of a drag is sent).
    SettingsGroup {
        visible: root.hasBrightness

        LevelRow {
            id: brightness
            system: root.system
            title: qsTr("Brightness")
            lowGlyph: "sun"
            highGlyph: "sun"
            lowGlyphSize: Tokens.settingsBrightnessLowGlyphSize
            highGlyphSize: Tokens.settingsBrightnessHighGlyphSize
            sliderX: Tokens.settingsBrightnessSliderX
            sliderWidth: Tokens.settingsBrightnessSliderWidth
            value: root.builtIn ? (root.backlight ? root.backlight.level : 0) : (root.ddc ? root.ddc.level : 0)
            what: "brightness"
            tag: "display.brightness"
            oneAtATime: !root.builtIn
            command: v => root.builtIn ? System.setBrightness(root.backlight ? root.backlight.device : "", v)
                : System.setDdcBrightness(root.ddc ? root.ddc.output : "", v)
        }
    }

    SettingsGroup {
        visible: root.monitor !== null
        footnote: root.monitor !== null && !root.nameable ? qsTr("This display has no name Grassfield can keep its settings under.") : root.notice

        SettingsRow {
            visible: root.rates.length > 1
            title: qsTr("Refresh rate")

            ComboBox {
                inline: true
                enabled: root.settable
                accessibleName: qsTr("Refresh rate")
                model: root.rates.map(hz => ({id: hz.toFixed(2), text: Displays.hzLabel(hz)}))
                value: root.trialChange && root.trialChange.hz !== undefined ? root.trialChange.hz.toFixed(2)
                    : root.monitor ? (root.rates.find(hz => Math.abs(hz - root.monitor.refreshRate) < 0.05) ?? root.monitor.refreshRate).toFixed(2) : ""
                onPicked: id => root.tryChange({hz: parseFloat(id)})
            }
        }

        SettingsRow {
            title: qsTr("Rotation")

            ComboBox {
                inline: true
                enabled: root.settable
                accessibleName: qsTr("Rotation")
                model: [{id: "0", text: qsTr("Standard")}, {id: "1", text: qsTr("90°")}, {id: "2", text: qsTr("180°")}, {id: "3", text: qsTr("270°")}]
                value: String(root.trialChange && root.trialChange.transform !== undefined ? root.trialChange.transform : root.monitor ? root.monitor.transform : 0)
                onPicked: id => root.tryChange({transform: parseInt(id, 10)})
            }
        }
    }

    // The push buttons under the groups, right-aligned (macOS 27: Advanced…).
    Item {
        visible: root.monitors.length > 1
        width: parent ? parent.width : implicitWidth
        height: Tokens.settingsPushRowGap - Tokens.settingsGroupGap + arrangeButton.height

        Button {
            id: arrangeButton
            push: true
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            enabled: root.trialId === ""
            text: qsTr("Arrange…")
            onClicked: root.arrangeRequested(root.monitors)
        }
    }

    ErrorNote {
        system: root.system
        tag: "display.brightness"
    }

    DevNote {
        system: root.system
    }
}
