import QtQuick
import Grassfield.Ui
import qs.security.lock
import qs.services

// Grassfield menu (the Grassfield mark): About, Settings, Recent Items (RecentItems), Force Quit, Sleep/Restart/Shut Down, Lock Screen,
// Log Out.
// About This Computer and Settings… launch grassfield-settings (`--about` for the first; GRASSFIELD_SETTINGS_CMD overrides the
// command in dev). Lock Screen engages the session lock.
PopupMenu {
    id: root

    accessibleName: qsTr("Grassfield menu")
    currentIndex: -1

    model: [
        {id: "about", text: qsTr("About This Computer")},
        {separator: true},
        // Software Update's releases after the label (ADR-0033 U19).
        {id: "settings", text: qsTr("Settings…"), detail: SoftwareUpdate.menuDetail},
        {separator: true},
        // Settings > Menu Bar > Recent items "None" hides the submenu.
        ...(Settings.menubarRecentItems > 0 ? [{id: "recentMenu", text: qsTr("Recent Items"), submenu: RecentItems.menu()}, {separator: true}] : []),
        {id: "forcequit", text: qsTr("Force Quit…")},
        {separator: true},
        {id: "sleep", text: qsTr("Sleep")},
        {id: "restart", text: qsTr("Restart…")},
        {id: "shutdown", text: qsTr("Shut Down…")},
        {separator: true},
        {id: "lock", text: qsTr("Lock Screen")},
        {id: "logout", text: qsTr("Log Out %1…").arg(SystemInfo.user)}
    ]

    onCloseRequested: Popups.close()
    onMenuStepRequested: direction => Popups.stepMenu(direction)

    onActivated: (item, byPointer) => {
        switch (item.id) {
        case "recentApp":
            Apps.launch(Apps.lookup(item.appId));
            Popups.close();
            break;
        case "recentDocument":
            Apps.openDetached(["xdg-open", item.path]);
            Popups.close();
            break;
        case "recentClear":
            RecentItems.clear();
            Popups.close();
            break;
        case "about":
            // Settings' About This Computer window (ADR-0040 ID-19).
            SettingsApp.openAbout();
            Popups.close();
            break;
        case "settings":
            SettingsApp.open();
            Popups.close();
            break;
        case "forcequit":
            // Its list's ring shows on open after Return only, not after a click (Popups.openedByPointer).
            Popups.withPointer(byPointer, () => Popups.openCentered("forcequit", {}));
            break;
        case "sleep":
            Popups.close();
            Power.sleepNow();
            break;
        // Restart, Shut Down and Log Out: no message, the dialog shows its countdown (ADR-0040 ID-21).
        case "restart":
            Popups.confirm(qsTranslate("SystemMenu", "Are you sure you want to restart your computer now?"), "", qsTranslate("SystemMenu", "Restart"), "restart", {}, true);
            break;
        case "shutdown":
            Popups.confirm(qsTranslate("SystemMenu", "Are you sure you want to shut down your computer now?"), "", qsTranslate("SystemMenu", "Shut Down"), "shutdown", {}, true);
            break;
        case "lock":
            Popups.close();
            Lock.lock("menu");
            break;
        case "logout":
            Popups.confirm(qsTranslate("SystemMenu", "Are you sure you want to quit all applications and log out %1?").arg(SystemInfo.user), "", qsTranslate("SystemMenu", "Log Out"), "logout", {}, true);
            break;
        default:
            Popups.close();
        }
    }
}
