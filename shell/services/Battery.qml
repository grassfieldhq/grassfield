pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.lib
import Quickshell.Services.UPower
import "BatteryLogic.js" as Logic

// Battery of the laptop for Quick Settings (UPower display device; power profile through power-profiles-daemon).
// `present` is false without a laptop battery (desktops, VMs, visual fixtures): the module is then hidden.
// In a GRASSFIELD_DEV session the power profile is never changed (it would change the owner's machine).
Singleton {
    id: root

    readonly property var device: UPower.displayDevice
    readonly property bool present: !VisualFixtures.active && device !== null && device.isPresent && device.isLaptopBattery
    readonly property int percent: present ? Logic.percent(device.percentage) : 0
    readonly property int state: present ? device.state : 0
    readonly property string source: Logic.source(state, UPower.onBattery)
    readonly property var status: Logic.status(state, present ? device.timeToEmpty : 0, present ? device.timeToFull : 0)
    readonly property string iconName: Logic.iconName(state)

    // Low Power Mode = the power-saver profile (always on offer: when power-profiles-daemon is missing the switch has no effect
    // and the profile stays Balanced).
    readonly property bool lowPower: Logic.lowPower(PowerProfiles.profile)
    readonly property bool devSession: Mode.dev
    signal devSuppressed

    // When the power source changes, Omarchy's profile remembered for that source applies (Settings > Battery > Low Power Mode
    // sets the two; omarchy-powerprofiles-init does it once at login). Never in a dev session.
    readonly property bool onBattery: UPower.onBattery
    onOnBatteryChanged: {
        if (!root.present || root.devSession) {
            if (root.devSession && root.present)
                console.info("dev guard: power profile for the power source suppressed");
            return;
        }
        // A run still going is left to end (stopping it would start nothing): it runs once more after, for the last source.
        if (sourceProfile.running)
            sourceProfile.again = true;
        else
            sourceProfile.running = true;
    }

    Process {
        id: sourceProfile
        // Set when the power source changed while the command was running: run it once more.
        property bool again: false
        command: ["sh", "-c", "command -v omarchy-powerprofiles-set >/dev/null && exec omarchy-powerprofiles-set autodetect"]
        onRunningChanged: {
            if (!running && again) {
                again = false;
                running = true;
            }
        }
    }

    function setLowPower(on: bool): void {
        if (devSession) {
            console.info("dev guard: low power mode suppressed");
            devSuppressed();
            return;
        }
        PowerProfiles.profile = Logic.profileFor(on);
    }

    // Second line of the module, e.g. "Power Adapter, 1:12 until full".
    readonly property string description: {
        const sourceText = source === "adapter" ? qsTr("Power Adapter") : qsTr("Battery");
        switch (status.kind) {
        case "full":
            return qsTr("%1, fully charged").arg(sourceText);
        case "charging":
            return status.time !== "" ? qsTr("%1, %2 until full").arg(sourceText).arg(status.time) : qsTr("%1, charging").arg(sourceText);
        case "discharging":
            return status.time !== "" ? qsTr("%1, %2 remaining").arg(sourceText).arg(status.time) : qsTr("%1, estimating time remaining").arg(sourceText);
        }
        return sourceText;
    }
}
