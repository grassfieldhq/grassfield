pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// General > Software Update (macOS 27 panes; docs/specs/updates.md U8, U11-U14, U21, U22; ADR-0033). The first group holds
// Automatic Updates and Beta Updates, each with its value and an (i) sheet (Main.qml opens it: infoRequested). The status group
// says what the last check found (SoftwareUpdateState.view): the releases with More Info…, Omarchy's, the other updates, Update
// Now; or why there is nothing to show, with the one action that helps (Set Up…, Repair…, Turn Off Grassfield Updates…).
// Update Now runs without a terminal (U24-U30, owner decision SU-M1): while it runs, the status shows its phase, a package
// count and one bar; when it ends, a sentence says what happened, with the one action that helps (Update in Terminal…,
// Finish in Terminal…). After an update that needs it, a group above asks to log out or restart (Main.qml asks first:
// endSessionRequested), or says not to restart. The pane checks when it opens unless a check finished less than a minute
// ago (U8).
SettingsPage {
    id: root

    // SoftwareUpdateState (one per window: the badge reads it too).
    required property var updates
    required property var store
    required property var system

    // "automatic", "beta", "notes" (Grassfield's release notes) or "others" (the other updates).
    signal infoRequested(string topic)
    // "logout" or "restart".
    signal endSessionRequested(string action)

    title: qsTr("Software Update")

    readonly property var view: root.updates.view
    readonly property bool waiting: root.updates.waitingForPermission
    // Update Now's run (SoftwareUpdateState.run) and whether it goes on.
    readonly property var run: root.updates.run
    readonly property bool running: root.updates.running
    // The releases found by the last success, kept through a failure, an update and `blocking` (ADR-0033 d.6).
    readonly property bool hasReleases: root.view.grassfield !== null || root.view.omarchy !== null || root.view.others > 0

    // A time as the pane says it: "Today, 10:42", or the date and time.
    function when(ms: double): string {
        if (ms <= 0)
            return "";
        const d = new Date(ms);
        const today = new Date();
        const time = d.toLocaleTimeString(Qt.locale(), Locale.ShortFormat);
        if (d.toDateString() === today.toDateString())
            return qsTr("Today, %1").arg(time);
        return d.toLocaleDateString(Qt.locale(), Locale.ShortFormat) + " " + time;
    }

    // The phase of a run as the pane says it (U25).
    readonly property string runHeadline: {
        switch (root.run.phase) {
        case "checking":
            return qsTr("Preparing the update…");
        case "snapshot":
            return qsTr("Saving a snapshot of this computer…");
        case "keyring":
        case "downloading":
            return qsTr("Downloading updates…");
        case "installing":
            return qsTr("Installing updates…");
        case "finishing":
        case "configuring":
            return qsTr("Finishing the update…");
        }
        return qsTr("Waiting for permission…");
    }
    readonly property string runDetail: root.run.total > 0 ? qsTr("%1 of %2").arg(root.run.done).arg(root.run.total)
        : root.run.phase === "authorizing" || root.run.phase === "" ? qsTr("Enter an administrator's password to start the update.")
        : qsTr("You can keep working; the update goes on if you close Settings.")

    // What the last run says (U28-U30): a sentence, the line under it, and its one action ("terminal", "finish" or "").
    readonly property var outcome: {
        const r = root.run.result;
        const deferred = root.run.deferred;
        if (root.run.state !== "done")
            return null;
        switch (r) {
        case "incompatible":
            return { title: qsTr("This update needs a newer version of Grassfield, which isn't available yet."),
                subtitle: qsTr("Software Update checks again later and tells you when it's ready."), action: "" };
        case "terminal":
            return { title: qsTr("This update asks questions that need Omarchy's terminal."),
                subtitle: root.run.synced ? qsTr("The updates were not installed. Omarchy's update asks them in its terminal and installs everything listed here.")
                    : qsTr("Nothing was changed. Omarchy's update asks them in its terminal and installs everything listed here."), action: "terminal" };
        case "stalelock":
            return { title: qsTr("An earlier update stopped before it finished."),
                subtitle: qsTr("Nothing was changed. Omarchy's update in its terminal shows how to finish it."), action: "terminal" };
        case "failed":
            return root.run.synced ? { title: qsTr("The update could not be installed."),
                subtitle: qsTr("The updates were not installed. Check that this computer is online, then try Update Now again."), action: "" }
                : { title: qsTr("The update could not be installed. Nothing was changed."),
                subtitle: qsTr("Check that this computer is online, then try Update Now again."), action: "" };
        case "failed-partial":
            return { title: qsTr("The update stopped before it finished."),
                subtitle: root.run.snapshot === "made" ? qsTr("Try Update Now again. The snapshot saved before the update can be chosen when the computer starts.")
                    : qsTr("Try Update Now again."), action: "" };
        case "space":
            return { title: qsTr("This computer needs 10 GB of free space to update."), subtitle: qsTr("Nothing was changed."), action: "" };
        case "power":
            return { title: qsTr("Connect this computer to power to update."), subtitle: qsTr("Nothing was changed."), action: "" };
        case "busy":
            return { title: qsTr("Another update is running."), subtitle: qsTr("Try again when it has finished."), action: "" };
        case "denied":
            return { title: qsTr("Software Update was not allowed to update this computer."), subtitle: qsTr("Nothing was changed."), action: "" };
        case "done":
            if (deferred.indexOf("migrations") >= 0)
                return { title: qsTr("Some of Omarchy's last steps need its terminal."),
                    subtitle: qsTr("The updates are installed. Omarchy finishes them in its terminal."), action: "finish" };
            if (deferred.indexOf("aur") >= 0)
                return { title: qsTr("Apps from the AUR are updated in Omarchy's terminal."),
                    subtitle: qsTr("Everything else is up to date."), action: "terminal" };
        }
        return null;
    }

    // The installed release was withdrawn and no newer one is offered yet (ADR-0050, U37).
    readonly property bool withdrawnNow: root.view.rollout.withdrawn !== "" && root.view.grassfield === null && !root.running
    // "Up to date" is not said under a release that was withdrawn: the headline says that instead (macOS's headline is the news).
    readonly property string upToDateText: root.withdrawnNow ? qsTr("Grassfield %1 has been withdrawn").arg(SoftwareUpdateLogic.displayVersion(root.view.rollout.withdrawn))
                                                             : qsTr("This computer is up to date")
    // The status's headline and the line under it.
    readonly property string headline: {
        if (root.running)
            return root.runHeadline;
        switch (root.view.kind) {
        case "checking":
            return qsTr("Checking for updates…");
        case "update-running":
            return qsTr("An update is running in Omarchy's terminal");
        case "up-to-date":
            return root.upToDateText;
        case "available":
            return root.hasReleases ? qsTr("Updates are available") : root.upToDateText;
        case "failed":
            return qsTr("Software Update could not check for updates");
        case "blocking":
            return qsTr("Grassfield's package repository cannot be used");
        case "repair":
            return qsTr("Grassfield updates need to be repaired");
        case "not-set-up":
            // A build without a host or key cannot set Grassfield's updates up; the system's are still offered.
            if (root.updates.buildReady)
                return qsTr("Grassfield updates are not set up");
            return root.hasReleases ? qsTr("Updates are available") : root.upToDateText;
        }
        return root.updates.channel === "custom" ? qsTr("Grassfield updates need to be repaired") : qsTr("Software Update has not checked for updates yet");
    }

    readonly property string detail: {
        const installed = root.view.installed;
        if (root.running)
            return root.runDetail;
        switch (root.view.kind) {
        case "update-running":
            return qsTr("Software Update checks again when it has finished.");
        case "up-to-date":
        case "available":
            if (root.hasReleases)
                return "";
            return installed.grassfield !== "" && installed.omarchy !== ""
                ? qsTr("Grassfield %1, Omarchy %2").arg(SoftwareUpdateLogic.displayVersion(installed.grassfield)).arg(SoftwareUpdateLogic.displayVersion(installed.omarchy))
                : "";
        case "failed":
            if (root.view.error === "offline")
                return qsTr("This computer is offline.");
            return root.view.message !== "" ? qsTr("The checker said: %1").arg(root.view.message) : qsTr("The package servers did not answer.");
        case "blocking":
            return qsTr("Until it works again, every system update stops, security fixes included. Turn Grassfield updates off to update the system now; you can set them up again later.");
        case "repair":
            return qsTr("Omarchy rewrote the system's package configuration, or it was changed by hand. Repair puts Grassfield's repository back; it asks for an administrator's password.");
        case "not-set-up":
            return root.updates.buildReady ? qsTr("Set Up adds Grassfield's package repository to the system; it asks for an administrator's password.")
                : qsTr("Grassfield's own updates are not available in this build: it has no package repository or signing key yet.");
        }
        return root.view.repair ? qsTr("The system's package configuration points Grassfield updates elsewhere. Repair puts Grassfield's repository back; it asks for an administrator's password.") : "";
    }

    // The one action of the status (U13, U22): "setup", "repair", "off" or "".
    readonly property string fix: {
        if (root.running)
            return "";
        // Off: the checker's not-set-up, or a failed check while grassfield-channel-set says off.
        if (root.view.kind === "not-set-up" || (root.view.kind === "failed" && root.updates.channel === "off"))
            return root.updates.buildReady ? "setup" : "";
        if (root.view.kind === "blocking")
            return "off";
        if (root.view.kind === "repair" || (root.view.repair && root.view.kind !== "checking" && root.view.kind !== "update-running"))
            return "repair";
        return "";
    }

    function runFix(): void {
        if (root.fix === "setup")
            root.updates.setChannel(root.updates.defaultChannel, "setup");
        else if (root.fix === "repair")
            root.updates.setChannel("repair", "repair");
        else if (root.fix === "off")
            root.updates.setChannel("off", "off");
    }

    // One line when a channel change failed (U12: "Beta updates were not changed: not allowed"); the tool's reason, its
    // "not allowed" in the UI language.
    function failure(action: string): string {
        const raw = root.updates.channelError;
        if (raw === "" || root.updates.lastAction !== action)
            return "";
        const reason = raw === "-" ? qsTr("the change failed") : raw.replace(/^grassfield-channel-set:\s*/, "").indexOf("not allowed") === 0 ? qsTr("not allowed")
            : raw.replace(/^grassfield-channel-set:\s*/, "");
        switch (action) {
        case "beta":
            return qsTr("Beta updates were not changed: %1").arg(reason);
        case "setup":
            return qsTr("Grassfield updates were not set up: %1").arg(reason);
        case "repair":
            return qsTr("Grassfield updates were not repaired: %1").arg(reason);
        }
        return qsTr("Grassfield updates were not turned off: %1").arg(reason);
    }

    Component.onCompleted: {
        root.updates.readRestart();
        root.updates.checkIfStale(Date.now());
    }

    // U14, U29: after an update, what finishes it. A restart covers a log out. When the update could not prepare the startup
    // files, the pane says not to restart instead, and offers no restart.
    SettingsGroup {
        visible: root.updates.restartBlocked || root.updates.restartNeeded || root.updates.logoutNeeded

        SettingsRow {
            title: root.updates.restartBlocked ? qsTr("Don't restart this computer yet")
                : root.updates.restartNeeded ? qsTr("Restart to finish updating")
                : root.updates.grassfieldLogout ? qsTr("Log out to finish updating Grassfield") : qsTr("Log out to finish updating")
            subtitle: root.updates.restartBlocked ? qsTr("The update could not prepare the computer's startup files. Get help before restarting.")
                : root.updates.restartNeeded ? qsTr("Part of the update is used only after the computer restarts.")
                : root.updates.grassfieldLogout ? qsTr("The new version of Grassfield starts when you log in again.")
                : qsTr("Some of the update is used only after you log in again.")

            Button {
                visible: !root.updates.restartBlocked
                // Not while Update Now's run goes on: the system changes until it ends (its helper also blocks a shutdown).
                enabled: !root.running
                push: true
                text: root.updates.restartNeeded ? qsTr("Restart…") : qsTr("Log Out…")
                onClicked: root.endSessionRequested(root.updates.restartNeeded ? "restart" : "logout")
            }
        }
    }

    SettingsGroup {
        footnote: root.failure("beta")

        SettingsRow {
            title: qsTr("Automatic Updates")
            valueText: root.store.value("updates.automaticCheck") ? qsTr("Check for updates") : qsTr("Off")

            InfoButton {
                accessibleName: qsTr("Automatic Updates details")
                onClicked: root.infoRequested("automatic")
            }
        }
        SettingsRow {
            title: qsTr("Beta Updates")
            valueText: root.waiting && root.updates.lastAction === "beta" ? qsTr("Waiting for permission…")
                : root.updates.channel === "beta" ? qsTr("Grassfield Beta") : qsTr("Off")

            InfoButton {
                accessibleName: qsTr("Beta Updates details")
                onClicked: root.infoRequested("beta")
            }
        }
    }

    SettingsGroup {
        footnote: root.failure("setup") || root.failure("repair") || root.failure("off")

        SettingsRow {
            title: root.headline
            subtitle: root.waiting && root.updates.lastAction !== "beta" ? qsTr("Waiting for permission…") : root.detail

            Spinner {
                visible: !root.running && (root.view.kind === "checking" || root.view.kind === "update-running")
                running: visible
            }

            Button {
                visible: root.fix !== ""
                enabled: !root.waiting
                push: true
                destructive: root.fix === "off"
                text: root.fix === "setup" ? qsTr("Set Up…") : root.fix === "repair" ? qsTr("Repair…") : qsTr("Turn Off Grassfield Updates…")
                onClicked: root.runFix()
            }
        }

        // Update Now's run (U25): one bar across the row, determinate when a count is known.
        SettingsRow {
            id: progressRow
            visible: root.running

            ProgressBar {
                anchors.verticalCenter: parent.verticalCenter
                // From the row's inset to its end: the row has no title, so the bar takes its whole width.
                width: Math.max(0, progressRow.width - 2 * Tokens.settingsRowInset)
                from: 0
                to: 100
                value: Math.max(0, root.run.percent)
                indeterminate: root.run.percent < 0
                accessibleName: root.runHeadline
            }
        }

        // What the last run says, with its one action (U28-U30).
        SettingsRow {
            visible: root.outcome !== null && !root.running
            title: root.outcome ? root.outcome.title : ""
            subtitle: root.outcome ? root.outcome.subtitle : ""

            Button {
                visible: root.outcome !== null && root.outcome.action !== "" && root.updates.canUseTerminal
                push: true
                text: root.outcome && root.outcome.action === "finish" ? qsTr("Finish in Terminal…") : qsTr("Update in Terminal…")
                enabled: !root.updates.updateRunning
                onClicked: root.outcome.action === "finish" ? root.updates.finishInTerminal() : root.updates.updateInTerminal()
            }
        }

        // The releases (U21): Grassfield's with its notes, Omarchy's, the other packages.
        SettingsRow {
            visible: root.view.grassfield !== null
            glyph: "grassfield-logo"
            // The mark's tile in the brand green, as General > About's (ADR-0040 ID-11; review of 5391761).
            tileColor: "grassfield"
            title: root.view.grassfield ? qsTr("Grassfield %1").arg(SoftwareUpdateLogic.releaseName(root.view.grassfield.available, root.view.grassfield.installed)) : ""
            // ADR-0050 (U36): a release its descriptor marks as a security release says so.
            subtitle: !root.view.grassfield ? ""
                : root.view.rollout.security ? qsTr("Important security update. Installed: %1").arg(SoftwareUpdateLogic.displayVersion(root.view.grassfield.installed))
                : qsTr("Installed: %1").arg(SoftwareUpdateLogic.displayVersion(root.view.grassfield.installed))

            LinkText {
                text: qsTr("More Info…")
                onActivated: root.infoRequested("notes")
            }
        }
        // The staged rollout (ADR-0050, U35): a newer release still being released gradually, which the database this
        // computer syncs does not offer yet. No button: it is installed once offered.
        SettingsRow {
            visible: root.view.rollout.staged !== null && !root.running
            glyph: "grassfield-logo"
            tileColor: "grassfield"
            title: !root.view.rollout.staged ? ""
                : root.view.rollout.staged.security ? qsTr("Grassfield %1 is an important security update.").arg(SoftwareUpdateLogic.releaseName(root.view.rollout.staged.version, root.view.installed.grassfield))
                : qsTr("Grassfield %1 is being released gradually.").arg(SoftwareUpdateLogic.releaseName(root.view.rollout.staged.version, root.view.installed.grassfield))
            subtitle: qsTr("It will be offered to this computer soon.")
        }
        // The installed release was withdrawn (ADR-0050, U37), while no newer one is offered yet.
        SettingsRow {
            visible: root.withdrawnNow
            glyph: "grassfield-logo"
            tileColor: "grassfield"
            title: qsTr("A corrected version is on its way.")
            subtitle: qsTr("It will be offered to this computer as soon as it's ready.")
        }
        SettingsRow {
            visible: root.view.omarchy !== null
            glyph: "laptop"
            title: root.view.omarchy ? qsTr("Omarchy %1").arg(SoftwareUpdateLogic.displayVersion(root.view.omarchy.available)) : ""
            subtitle: qsTr("Omarchy's release notes are on its project page.")
        }
        SettingsRow {
            visible: root.view.others > 0
            glyph: "grid"
            title: root.view.others === 1 ? qsTr("1 other update") : qsTr("%1 other updates").arg(root.view.others)
            subtitle: qsTr("System packages, updated with Omarchy's update.")

            InfoButton {
                accessibleName: qsTr("Other updates")
                onClicked: root.infoRequested("others")
            }
        }
        // While `blocking`, every Omarchy update fails at its first sync (U22): Update Now waits for Turn Off… or the repository.
        SettingsRow {
            visible: root.hasReleases && root.view.kind !== "checking" && !root.running
            title: !root.updates.canUpdate ? qsTr("Update Now needs Omarchy's update command, which this system does not have.")
                : root.view.kind === "blocking" ? qsTr("Omarchy's update cannot run while Grassfield's repository cannot be used.")
                : root.updates.withoutTerminal ? qsTr("Update Now installs everything listed here.")
                : qsTr("Omarchy's update installs everything listed here.")
            subtitle: !root.updates.canUpdate || root.view.kind === "blocking" ? ""
                : root.updates.withoutTerminal ? qsTr("It asks for an administrator's password and saves a snapshot first.")
                : qsTr("It runs in Omarchy's terminal and asks before it starts.")

            Button {
                primary: true
                push: true
                text: qsTr("Update Now")
                enabled: root.updates.canUpdate && !root.updates.updateRunning && root.view.kind !== "blocking"
                onClicked: root.updates.updateNow()
            }
        }

        // When the last check ran, and Check Now (U8).
        SettingsRow {
            title: root.view.checkedAt > 0 ? qsTr("Last checked: %1").arg(root.when(root.view.checkedAt)) : qsTr("Not checked yet")
            subtitle: root.view.kind === "failed" && root.view.lastSuccessAt > 0 ? qsTr("Last successful check: %1").arg(root.when(root.view.lastSuccessAt)) : ""

            Button {
                push: true
                text: qsTr("Check Now")
                // Never held back by the stored state alone: a stale update-running is cleared by a check.
                enabled: !root.updates.checking
                onClicked: root.updates.check()
            }
        }
    }

    DevNote {
        system: root.system
    }
}
