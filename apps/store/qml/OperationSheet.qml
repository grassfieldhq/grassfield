pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Store.js" as Store

// The confirmation sheet of Get and Uninstall… (spec SR14, SR15, SR17, SR22; ADR-0037 e.1): nothing runs without its
// default button. While the plan is checked (the backend's plan(), a few pacman queries as the user) the button waits;
// then the sheet lists the source, the licence, the sizes and every package the operation adds or removes (pacman's plan),
// or, for a web app, the launcher it adds or removes; for an Omarchy setup, first what it changes (our catalog's text), the
// recipe Omarchy's terminal runs and, for a removal, the files it deletes (ADR-0037 e.1, b.2); for the AUR, its warning every
// time (SR16), then what yay builds from the AUR and what pacman adds from the repositories, with "Install from the AUR"
// beside Cancel, which is the default (Return cancels: the build runs the package's script before any password; common
// rule 3); for a Flatpak (SD25), what it can reach and flatpak's own plan (the runtimes it pulls, each at most its
// download), installed in the user's own folder without a password, and for a removal that its data stays and the runtimes
// no other app needs go with it (SD27); for "Get Flatpak…" (SD24, from the settings), what Flatpak is, that Omarchy
// installs it in its terminal, which asks for the password, and when Flathub's apps reach the launcher, then pacman's plan.
// A plan that cannot run says why instead, and offers Software Update when the system must be updated first; Esc
// or Cancel close it and nothing runs. A Flatpak's update (step 4) asks only when it lets an app reach more than before, or
// when that could not be read (SD25 for an update): otherwise it starts at once, as an update does on macOS. Update All
// never asks: what asks for more waits for its own Update (ADR-0049), whose sheet says what changes, grant by grant.
Sheet {
    id: root

    required property var backend
    property var app: ({})
    property string kind: "install"
    // null while it is checked; then {refusal, packages, download, installed, unfinished, upgrades, dependents, protected,
    // detail} (StoreBackend::plan).
    property var plan: null
    readonly property bool removing: root.kind === "remove"
    readonly property bool updating: root.kind === "update"
    // An update asked for and not shown yet: its plan decides whether the sheet opens.
    property bool pendingUpdate: false
    readonly property bool webApp: root.app.kind === "webapp"
    readonly property bool setup: root.app.kind === "setup"
    readonly property bool aur: root.app.kind === "aur"
    readonly property bool flatpak: root.app.kind === "flatpak"
    readonly property bool getFlatpak: root.app.kind === "getFlatpak"
    readonly property var setupInfo: root.app.setup || ({})
    readonly property string refusal: root.plan ? (root.plan.refusal || "") : ""
    readonly property bool updateFirst: root.refusal === "unfinished" || root.refusal === "outdated"
    // The AUR's packages yay builds (marked so), then what pacman adds from the repositories.
    readonly property var packages: root.plan ? (root.plan.built || []).map(p => ({name: p.name, version: p.version, size: qsTr("AUR")}))
                                                .concat(root.plan.packages || []) : []
    readonly property string appName: root.app.name || ""

    // True while the sheet answers a hand-over ("uninstall:<entry>" from the launcher or Files, ADR-0046 D1): the Store's own alert
    // "Delete “App”?", the app's icon and the packages -Rns takes, Cancel the default, and the only confirmation: a request
    // from another process can open this sheet and nothing more.
    property bool handedOver: false

    function show(app: var, kind: string, handedOver: var): void {
        root.app = app;
        root.kind = kind;
        root.plan = null;
        root.pendingUpdate = false;
        root.handedOver = handedOver === true && kind === "remove";
        root.open();
        root.backend.plan(app.id, kind);
    }

    // Update (a Flatpak's, or the Flatpak group's Update All): its plan first, the sheet only when it has something to say.
    function showUpdate(app: var): void {
        if (root.visible)
            return;
        root.app = app;
        root.kind = "update";
        root.plan = null;
        root.handedOver = false;
        root.pendingUpdate = true;
        root.backend.plan(app.id, "update");
    }

    Connections {
        target: root.backend
        function onPlanReady(app: string, kind: string, plan: var): void {
            if (app !== root.app.id || kind !== root.kind)
                return;
            if (root.pendingUpdate) {
                root.pendingUpdate = false;
                root.plan = plan;
                // ADR-0049: only an update that asks for more (or could not be checked) asks; Update All leaves those out.
                const quiet = plan.refusal === "" && !plan.asks;
                if (quiet)
                    root.backend.update(app);
                else
                    root.open();
            } else if (root.visible) {
                root.plan = plan;
            }
        }
    }

    title: {
        if (root.updating && root.app.id === "store:flatpak-updates") // Update All of the Flatpak group: its own words
            return root.refusal === "" ? qsTr("Update the Flatpak apps?") : qsTr("The Flatpak apps can't be updated now");
        if (root.updating)
            return root.refusal === "" ? qsTr("Update “%1”?").arg(root.appName) : qsTr("“%1” can't be updated now").arg(root.appName);
        if (root.refusal === "" && root.getFlatpak)
            return qsTr("Get Flatpak?");
        if (root.refusal === "")
            return root.handedOver ? qsTr("Delete “%1”?").arg(root.appName)
                 : root.removing ? qsTr("Uninstall “%1”?").arg(root.appName) : qsTr("Install “%1”?").arg(root.appName);
        switch (root.refusal) {
        case "unfinished":
            return qsTr("Finish the system update first");
        case "outdated":
            return qsTr("Update your system first");
        case "busy":
            return qsTr("Another installation or an update is running");
        case "offline":
            return qsTr("You're offline");
        case "dependency":
            return qsTr("“%1” can't be uninstalled").arg(root.appName);
        case "protected":
            return root.removing ? qsTr("Uninstalling it would also remove part of the system") : qsTr("“%1” can't be installed from the AUR").arg(root.appName);
        case "repository":
            return qsTr("“%1” is in a repository").arg(root.appName);
        }
        return root.removing ? qsTr("“%1” can't be uninstalled now").arg(root.appName) : qsTr("“%1” can't be installed now").arg(root.appName);
    }
    message: {
        if (!root.plan)
            return qsTr("Checking what this changes…");
        if (root.updating) {
            if (root.refusal !== "")
                return root.plan.detail === "none" ? qsTr("There's nothing to update now.")
                     : root.plan.detail === "queued" ? qsTr("It's already waiting to be updated.")
                     : root.plan.detail === "held" ? qsTr("Each of these apps asks for more than before. Update them one by one to see what they ask for.")
                     : Store.getBlockText(root.plan.detail || "", "flatpak") || qsTr("The Store could not read what this would change.");
            // What each update changes in what its app can reach (ADR-0049): what it newly reaches, then what it no longer
            // does; and what could not be read.
            const parts = [];
            for (const c of root.plan.changed || []) {
                const lines = Store.changeLines(c.changes);
                if (lines.more.length > 0)
                    parts.push(qsTr("After this update, “%1” can also reach:").arg(c.name) + "\n" + lines.more.join("\n"));
                if (lines.less.length > 0)
                    parts.push(qsTr("It can no longer reach:") + "\n" + lines.less.join("\n"));
            }
            if ((root.plan.unknown || []).length > 0)
                parts.push(qsTr("What this update lets %1 reach could not be read.").arg((root.plan.unknown || []).join(", ")));
            parts.push(root.app.id === "store:flatpak-updates" ? qsTr("They're updated in your own folder, for you alone, without administrator rights.")
                                                               : qsTr("It's updated in your own folder, for you alone, without administrator rights."));
            return parts.join("\n\n");
        }
        switch (root.refusal) {
        case "":
            if (root.getFlatpak) {
                // The flatpak package, as Omarchy installs it in its terminal (SD24); its exports reach the launcher at the next
                // login (S20).
                return [qsTr("Flatpak installs the apps of Flathub in your own folder, for you alone."),
                        qsTr("It comes from Arch Linux: Omarchy installs it in a Terminal window, which asks for your password."),
                        qsTr("The apps you get from Flathub show in your app launcher after you log in again."),
                        qsTr("These packages will be installed:")].join("\n\n");
            }
            if (root.webApp)
                return root.removing ? qsTr("The launcher and its icon are removed from Apps.")
                                     : qsTr("A launcher that opens %1 in your browser is added to Apps, with its icon.").arg(Store.hostOf(root.app.webUrl || ""));
            if (root.setup) {
                // Omarchy's recipe, in its terminal: it asks for the password there (sudo), as Omarchy's own menu does.
                const recipe = root.removing ? (root.setupInfo.remove || "") : (root.setupInfo.install || "");
                const parts = root.removing ? [] : [root.setupInfo.changes || ""];
                parts.push(qsTr("Omarchy's “%1” runs in a Terminal window, which asks for your password.").arg(recipe));
                // The user data the removal recipe deletes, as our catalog says (nothing said when it says nothing).
                if (root.removing && root.setupInfo.removes)
                    parts.push(qsTr("It also deletes: %1").arg(root.setupInfo.removes));
                parts.push(root.removing ? qsTr("These packages will be removed:") : qsTr("These packages will be installed:"));
                return parts.filter(t => t !== "").join("\n\n");
            }
            if (root.flatpak) {
                // The user's own installation: no password, nothing of the system changes (b.3).
                if (root.removing)
                    return qsTr("Its data in ~/.var/app/%1 stays. Runtimes no other app needs are removed too.").arg(root.app.flatpakId || root.app.name || "");
                // What it can reach, never less than its metadata grants (SD25), grouped as its page's cards (ADR-0049):
                // unread, nothing is said.
                const grants = root.plan.permissions === undefined || root.plan.permissions === null ? null : root.plan.permissions;
                // Short lines, one thing each (macOS's way): the groups by title, the warnings visible, the details on its page.
                const summary = grants === null ? null : Store.permissionSummary(grants);
                return [qsTr("It's installed in your own folder, for you alone, without administrator rights."),
                        summary === null ? "" : summary.titles.length === 0 ? qsTr("It can reach only its own window and files.")
                                                                           : qsTr("It can reach:") + "\n" + summary.titles.join("\n"),
                        summary === null || summary.warnings.length === 0 ? "" : qsTr("Take care:") + "\n" + summary.warnings.join("\n"),
                        summary === null || summary.titles.length === 0 ? "" : qsTr("Its page lists each one."),
                        qsTr("These will be installed:")].filter(t => t !== "").join("\n\n");
            }
            if (root.aur) {
                // yay builds them in Omarchy's terminal and pacman installs them there: the password is asked there (sudo).
                if (root.removing)
                    return qsTr("It is removed in a Terminal window, which asks for your password.") + "\n\n"
                        + qsTr("These packages will be removed. Your files and settings stay.");
                const parts = [Store.aurWarning(),
                               qsTr("The packages marked AUR are built on this computer in a Terminal window, which asks for your password.")];
                if (root.plan.incomplete)
                    parts.push(qsTr("Some of what the AUR lists for it could not be read: the build may install more than this."));
                parts.push(qsTr("These packages will be installed:"));
                return parts.join("\n\n");
            }
            return root.removing ? qsTr("These packages will be removed. Your files and settings stay.") : qsTr("These packages will be installed:");
        case "unfinished":
            return qsTr("The last system update did not finish: some packages are newer in the repositories than on this computer. Finish the update in Software Update, then try again.");
        case "outdated":
            return qsTr("Your system needs to be updated before you can install apps. Software Update brings it up to date; then get the app again.");
        case "busy":
            return qsTr("Try again when it has finished.");
        case "offline":
            return qsTr("Installing an app needs a connection to the internet.");
        case "dependency":
            return qsTr("Other apps need it: %1.").arg((root.plan.dependents || []).join(", "));
        case "protected":
            if (!root.removing)
                return qsTr("It would build %1 from the AUR, a name the system, Omarchy or Grassfield uses. The Store doesn't install it.").arg(root.plan.protected || "");
            return qsTr("Uninstalling “%1” would also remove %2, which the system, Omarchy or Grassfield needs. It stays installed.").arg(root.appName).arg(root.plan.protected || "");
        case "omarchyChanged":
            return Store.omarchyChangedText(root.app.kind);
        case "repository":
            return qsTr("A repository has this package, or one that provides it: the Store installs it from there, without building it.");
        case "notOnAur":
            return root.plan.detail === root.app.package ? qsTr("The AUR doesn't have this package (anymore).")
                                                       : qsTr("It needs %1, which neither the repositories nor the AUR have.").arg(root.plan.detail || "");
        case "unavailable":
            return Store.getBlockText(root.plan.detail || "", root.app.kind) || Store.uninstallReasonText(root.plan.detail || "", root.app.kind);
        }
        return qsTr("The Store could not read what this would change.");
    }
    confirmText: {
        if (root.refusal === "" && root.updating)
            return qsTr("Update");
        if (root.refusal === "")
            return root.handedOver ? qsTr("Delete") : root.removing ? qsTr("Uninstall") : root.aur ? qsTr("Install from the AUR") : qsTr("Install");
        return root.updateFirst ? qsTr("Update Now…") : qsTr("OK");
    }
    destructive: root.removing && root.refusal === ""
    // An AUR install is never the default: a click, or Tab and Space, on "Install from the AUR".
    returnCancels: (root.aur && !root.removing && root.refusal === "") || (root.handedOver && root.refusal === "")
    showCancel: root.refusal === "" || root.updateFirst
    confirmEnabled: root.plan !== null

    onAccepted: {
        if (root.refusal === "" && root.updating) {
            root.backend.update(root.app.id);
        } else if (root.refusal === "") {
            if (root.removing)
                root.backend.uninstall(root.app.id);
            else
                root.backend.install(root.app.id);
        } else if (root.updateFirst) {
            root.backend.openSoftwareUpdate();
        }
    }

    ProgressBar {
        width: parent.width
        visible: root.plan === null
        indeterminate: true
        accessibleName: qsTr("Checking")
    }

    // The app, as the Store names it, for a removal asked from outside (the user's own .desktop name is never used).
    AppIcon {
        visible: root.handedOver && root.refusal === ""
        source: root.app.icon || ""
        size: Tokens.storeLockupIconSize
    }

    // Source, licence and sizes.
    Column {
        width: parent.width
        visible: root.plan !== null && root.refusal === "" && !root.updating
        spacing: Tokens.storeInfoLineGap

        Repeater {
            model: [
                [qsTr("Source"), Store.sourceLabel(root.app.kind, root.app.repo)],
                [qsTr("Licence"), root.getFlatpak ? "" : root.app.license || qsTr("Licence not stated")],
                // An AUR package's sizes are its build's, unknown before it: those of the repositories' part only.
                // flatpak gives the most each ref downloads (its "<"): a total no larger than this.
                [root.aur ? qsTr("Download from the repositories") : root.flatpak ? qsTr("Download, at most") : qsTr("Download"),
                 root.plan && !root.removing ? (root.plan.download || "") : ""],
                [qsTr("Installed size"), root.plan && !root.removing && !root.aur ? (root.plan.installed || "") : ""]
            ].filter(row => row[1] !== "")

            delegate: Row {
                id: infoRow
                required property var modelData
                width: parent.width
                spacing: Tokens.spacingSm

                Text {
                    width: Math.round(infoRow.width / 3)
                    textFormat: Text.PlainText
                    text: infoRow.modelData[0]
                    wrapMode: Text.Wrap // a long label ("Download from the repositories") takes a second line
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }

                Text {
                    width: infoRow.width - Math.round(infoRow.width / 3) - infoRow.spacing
                    textFormat: Text.PlainText
                    text: infoRow.modelData[1]
                    elide: Text.ElideRight
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }
            }
        }
    }

    // Every package the plan adds or removes (pacman -S --print, -Rs --print), the app's own first.
    ListView {
        id: list
        width: parent.width
        visible: root.plan !== null && root.refusal === "" && !root.updating && root.packages.length > 0
        height: Math.min(root.packages.length, Tokens.storeSheetListMaxRows) * Tokens.storeSheetRowHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        model: root.packages
        Accessible.role: Accessible.List
        Accessible.name: root.removing ? qsTr("Packages to remove") : qsTr("Packages to install")

        ScrollBar.vertical: ScrollBar {}

        delegate: Item {
            id: row
            required property var modelData
            width: list.width
            height: Tokens.storeSheetRowHeight
            Accessible.role: Accessible.ListItem
            Accessible.name: [row.modelData.name, row.modelData.version, row.modelData.size].filter(t => t).join(", ")

            Text {
                anchors.left: parent.left
                anchors.right: size.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: row.modelData.name + "  " + row.modelData.version
                elide: Text.ElideRight
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }

            Text {
                id: size
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: row.modelData.size || ""
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }
        }
    }

    // pacman's own words, when it gave some (an unresolved plan, the last update's packages); never for a system older than
    // its mirror, said in plain words with Update Now… (its detail goes to the log).
    Text {
        width: parent.width
        visible: text !== ""
        textFormat: Text.PlainText
        text: root.plan && !root.updating && ["", "unavailable", "notOnAur", "repository", "outdated"].indexOf(root.refusal) < 0
              ? (root.refusal === "unfinished" ? (root.plan.unfinished || []).slice(0, 6).join("\n") : (root.plan.detail || "")) : ""
        wrapMode: Text.WrapAnywhere
        maximumLineCount: 6
        elide: Text.ElideRight
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
    }
}
