pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Power.js" as Power
import "General.js" as General

// Battery as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Battery): Low Power Mode, Battery Health and
// Charging with their (i) sheets, and the level of the last 24 hours or 10 days. UPower over D-Bus (`power.state`, read-only;
// the charge limit through UPower's own polkit action, ADR-0030). Low Power Mode keeps Omarchy's model: a power profile
// remembered for the power adapter and one for the battery (read from Omarchy's state files, set with
// omarchy-powerprofiles-set, the source in use last). Options… opens the sleep option (PowerOptionsSheet: energy.preventSleep).
// Every change goes through SystemService, so never in a dev session.
SettingsPage {
    id: root

    required property var backend
    required property var system

    // Main.qml opens the (i) sheets and hands the charge limit back (setLimit). setupRequested: Hibernation's Omarchy commands
    // in its terminal (TerminalSetupSheet, ADR-0045 OC-9).
    signal infoRequested(string topic, var power)
    signal setupRequested(string id)
    // Options… (macOS 27): Main.qml opens PowerOptionsSheet (Prevent automatic sleeping when the display is off; battery and power adapter).
    signal optionsRequested

    title: qsTr("Battery")

    // Hibernation's state (HibernationGroup).
    readonly property string hibernation: hibernationGroup.status


    // The state of the battery for the toolbar, under the pane's title (macOS 27).
    readonly property string subtitle: root.statusText

    property var power: null
    property bool answered: false
    // The profiles power-profiles-daemon offers, and the two Omarchy remembers.
    property var profiles: []
    property string acProfile: ""
    property string batteryProfile: ""
    property string range: "day"
    // The Low Power Mode being set, and the commands still to run (the source in use last).
    property string pendingMode: ""
    property var queue: []

    readonly property string mode: root.pendingMode !== "" ? root.pendingMode : Power.lowPowerMode(root.acProfile, root.batteryProfile)
    readonly property string statusText: {
        if (!root.power || !root.power.present)
            return "";
        const time = Power.duration(root.power.state === 1 ? root.power.timeToFull : root.power.timeToEmpty);
        switch (Power.kind(root.power.state)) {
        case "full":
            return qsTr("Fully Charged");
        case "charging":
            return time !== "" ? qsTr("%1 % · %2 until full").arg(root.power.percent).arg(time) : qsTr("%1 % · Charging").arg(root.power.percent);
        case "discharging":
            return time !== "" ? qsTr("%1 % · %2 remaining").arg(root.power.percent).arg(time) : qsTr("%1 %").arg(root.power.percent);
        }
        return qsTr("%1 %").arg(root.power.percent);
    }

    function refresh(): void {
        root.system.queryBus("power.state", "power.state");
    }

    function readProfiles(): void {
        const dir = root.backend.stateDir + "/omarchy/powerprofiles/";
        root.acProfile = root.backend.readText(dir + "ac").text.trim();
        root.batteryProfile = root.backend.readText(dir + "battery").text.trim();
    }

    function setMode(mode: string): void {
        if (mode === root.mode || root.pendingMode !== "" || !root.power)
            return;
        const commands = Power.commands(Power.profilesFor(mode, root.acProfile, root.batteryProfile, root.profiles), root.power.onBattery);
        if (commands === null)
            return;
        root.pendingMode = mode;
        root.queue = commands.slice(1);
        if (!root.system.act("low power mode", commands[0], "power.act")) {
            root.pendingMode = "";
            root.queue = [];
        }
    }

    // BatteryInfoSheet's answer.
    function setLimit(on: bool): void {
        root.system.act("charge limit", {op: "power.chargeLimit", on: on === true}, "power.limit");
    }

    // The chart's bars and time labels for the range shown.
    readonly property int now: Math.round(clock.now / 1000)
    readonly property var chart: {
        const days = root.range === "day" ? 1 : 10;
        const end = Power.windowEnd(root.now, days);
        const span = days * 24 * 3600;
        const history = root.power ? (days === 1 ? root.power.history24 : root.power.history10) : [];
        const labels = [];
        const twelve = !General.uses24Hour("auto", Qt.locale().timeFormat(Locale.ShortFormat));
        for (let k = 0; k < (days === 1 ? 8 : 10); k++) {
            const d = new Date((end - span) * 1000 + k * (days === 1 ? 3 * 3600 : 24 * 3600) * 1000);
            if (days !== 1)
                labels.push({text: Qt.locale().dayName(d.getDay(), Locale.ShortFormat)});
            else if (twelve)
                labels.push({text: d.getHours() === 0 ? qsTr("12 A") : d.getHours() === 12 ? qsTr("12 P") : String(d.getHours() % 12)});
            else
                labels.push({text: String(d.getHours())});
        }
        const start = new Date((end - span) * 1000);
        return {bars: Power.bars(history, end, span, days === 1 ? 96 : 240, root.now), labels: labels,
            // The first day shown ("Sep 9"): the month's short name and the day, in the order of the language.
            date: qsTr("%1 %2", "short month name, day of the month").arg(Qt.locale().monthName(start.getMonth(), Locale.ShortFormat)).arg(start.getDate())};
    }

    QtObject {
        id: clock
        property real now: Date.now()
    }

    Connections {
        target: root.backend
        ignoreUnknownSignals: true

        // A change on the system bus (Backend.busChanged, coalesced there): read again; a reading on its way reads once more after.
        function onBusChanged(what: string): void {
            if (what === "power") {
                root.refresh();
            }
        }

        function onFinished(tag: string, ok: bool, output: string): void {
            switch (tag) {
            case "power.state":
                root.power = ok ? Power.parseState(output) : null;
                root.answered = true;
                clock.now = Date.now();
                break;
            case "power.profiles":
                root.profiles = ok ? Power.parseProfiles(output) : [];
                break;
            case "power.act":
                if (ok && root.queue.length > 0) {
                    const next = root.queue[0];
                    root.queue = root.queue.slice(1);
                    if (root.system.act("low power mode", next, "power.act"))
                        break;
                }
                root.queue = [];
                root.pendingMode = "";
                root.readProfiles();
                break;
            case "power.limit":
                root.refresh();
                break;
            }
        }
    }

    // A poll only while the system bus's change signals are not followed (Backend.followBus: no bus, a test's backend).
    Timer {
        interval: Tokens.settingsSystemRefreshMs
        running: root.backend.busSignals !== true
        repeat: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: {
        if (typeof root.backend.followBus === "function")
            root.backend.followBus("power");
        root.refresh();
        root.readProfiles();
        root.system.query(["omarchy-powerprofiles-list"], "power.profiles");
    }

    SettingsGroup {
        visible: root.power !== null && root.power.present
        footnote: root.power !== null && root.power.present && root.profiles.length === 0 ? qsTr("Power profiles are not available: power-profiles-daemon is not running.") : ""

        SettingsRow {
            title: qsTr("Low Power Mode")

            ComboBox {
                inline: true
                enabled: root.pendingMode === "" && root.profiles.length > 0
                accessibleName: qsTr("Low Power Mode")
                model: [{id: "never", text: qsTr("Never")}, {id: "always", text: qsTr("Always")}, {id: "battery", text: qsTr("Only on Battery")},
                    {id: "adapter", text: qsTr("Only on Power Adapter")}]
                value: root.mode
                onPicked: id => root.setMode(id)
            }
        }
    }

    SettingsGroup {
        visible: root.power !== null && root.power.present

        SettingsRow {
            visible: root.power !== null && Power.health(root.power.capacity) !== ""
            title: qsTr("Battery Health")
            valueText: root.power && Power.health(root.power.capacity) === "service" ? qsTr("Service Recommended") : qsTr("Normal")

            InfoButton {
                accessibleName: qsTr("Battery Health details")
                onClicked: root.infoRequested("health", root.power)
            }
        }
        SettingsRow {
            title: qsTr("Charging")

            InfoButton {
                accessibleName: qsTr("Charging details")
                onClicked: root.infoRequested("charging", root.power)
            }
        }
    }

    SettingsGroup {
        visible: root.power !== null && root.power.present

        Item {
            width: parent.width
            height: Tokens.settingsChartHeaderHeight

            SegmentedControl {
                x: Tokens.settingsRowInset
                y: Tokens.settingsRowInset
                width: parent.width - 2 * Tokens.settingsRowInset
                height: Tokens.controlButtonHeight
                fill: true
                prominent: true
                accessibleName: qsTr("Period")
                model: [{id: "day", text: qsTr("Last 24 Hours")}, {id: "days", text: qsTr("Last 10 Days")}]
                value: root.range
                onPicked: id => root.range = id
            }

            Text {
                textFormat: Text.PlainText
                x: Tokens.settingsRowInset
                y: Tokens.settingsChartStatusBaseline - baselineOffset
                text: root.statusText
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        }

        Item {
            width: parent.width
            height: chart.height + 1

            Rectangle {
                x: Tokens.settingsRowInset
                width: parent.width - 2 * Tokens.settingsRowInset
                height: Tokens.appsBorderWidth
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }

            BatteryChart {
                id: chart
                y: 1
                title: qsTr("Battery Level")
                bars: root.chart.bars
                timeLabels: root.chart.labels
                dateText: root.chart.date
            }
        }
    }

    // Hibernation (ADR-0045 OC-9): the group Energy shows too.
    HibernationGroup {
        id: hibernationGroup
        backend: root.backend
        onSetupRequested: id => root.setupRequested(id)
    }

    // The push button under the groups, right-aligned (macOS 27: Options… and ?).
    Item {
        visible: root.power !== null && root.power.present
        width: parent ? parent.width : implicitWidth
        height: Tokens.settingsPushRowGap - Tokens.settingsGroupGap + optionsButton.height

        Button {
            id: optionsButton
            push: true
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            text: qsTr("Options…")
            Accessible.name: qsTr("Battery options")
            onClicked: root.optionsRequested()
        }
    }

    Text {
        textFormat: Text.PlainText
        visible: root.answered && (root.power === null || !root.power.present)
        width: parent.width
        leftPadding: Tokens.settingsRowInset
        wrapMode: Text.Wrap
        text: root.power === null ? qsTr("The battery cannot be read: UPower did not answer.") : qsTr("This computer has no battery.")
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
    }

    ErrorNote {
        system: root.system
        tag: "power.act"
    }

    ErrorNote {
        system: root.system
        tag: "power.limit"
    }

    DevNote {
        system: root.system
    }
}
