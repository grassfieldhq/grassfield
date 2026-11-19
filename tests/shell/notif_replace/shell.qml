pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import qs.notifications

// Replacements (replaces_id) on the REAL Notifications singleton (scripts/dev/test.sh: `qs -p tests/shell/notif_replace`, a
// dev session without the D-Bus server; see the dev-session marker file). Quickshell updates a replaced Notification in
// place and emits one change signal per property (Notification::updateProperties); a stand-in object with the same
// properties and signals plays the sender here.
//  B-09: a replacement that changes the summary, the body and the urgency in one go is ONE update (one history write), not
//        one per signal.
//  B-12: a replacement that changes only the urgency (raised to critical) shows through Do Not Disturb and its banner stays
//        (timeout 0); one that changes only expire_timeout gives the banner that timeout; one that changes only the icon is
//        seen; a replacement under Do Not Disturb lowered from critical takes its banner away.
// Prints "notif-replace: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    property int historyWrites: 0
    property string phase: "start"
    property string key: ""

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    // The sender's notification as Quickshell exposes it (the properties and signals the shell reads).
    component FakeNotification: QtObject {
        property int id: 7
        property bool tracked: false
        property string appName: "Downloads"
        property string appIcon: ""
        property string summary: "file.iso"
        property string body: "10%"
        property var actions: []
        property int urgency: NotificationUrgency.Normal
        property real expireTimeout: -1
        property string image: ""
        property bool resident: false
        property string desktopEntry: ""
        property int dismissed: 0

        signal closed(int reason)

        function dismiss(): void {
            dismissed++;
        }
    }

    FakeNotification {
        id: fake
    }

    Connections {
        target: Notifications

        function onHistoryChanged(): void {
            root.historyWrites++;
        }
    }

    function bannerRow(): var {
        for (let i = 0; i < Notifications.bannerModel.count; i++) {
            const r = Notifications.bannerModel.get(i);
            if (r.key === key)
                return r;
        }
        return null;
    }

    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: root.step()
    }

    function step(): void {
        if (phase === "start") {
            // The history file is read first (its load writes the history once).
            if (!Notifications.historyReady)
                return;
            Notifications.setDnd(false);
            Notifications.accept(fake);
            const e = Notifications.history.find(x => x.summary === "file.iso");
            key = e ? e.key : "";
            check("accepted: a banner with the default timeout", key !== "" && bannerRow() !== null && bannerRow().timeout > 0);
            historyWrites = 0;
            // One replacement: three properties change in one go (as updateProperties emits them).
            fake.summary = "file.iso done";
            fake.body = "100%";
            fake.urgency = NotificationUrgency.Low;
            phase = "coalesced";
        } else if (phase === "coalesced") {
            check("B-09: one update for one replacement (" + historyWrites + " history writes)", historyWrites === 1);
            const e = Notifications.entryFor(key);
            check("B-09: the update has all three changes", e !== null && e.summary === "file.iso done" && e.body === "100%" && e.urgency === 0);
            // Only the timeout changes: the banner takes the replacement's timeout.
            fake.expireTimeout = 9000;
            phase = "timeout";
        } else if (phase === "timeout") {
            check("B-12: a replacement's own expire_timeout is the banner's timeout", bannerRow() !== null && bannerRow().timeout === 9000);
            // Do Not Disturb, the banner gone; the replacement raises only the urgency.
            Notifications.setDnd(true);
            Notifications.expireBanner(key);
            phase = "dnd";
        } else if (phase === "dnd") {
            if (!Notifications.dnd)
                return;
            fake.urgency = NotificationUrgency.Critical;
            phase = "critical";
        } else if (phase === "critical") {
            const r = bannerRow();
            check("B-12: raised to critical, it shows through Do Not Disturb", r !== null);
            check("B-12: and stays (timeout 0)", r !== null && r.timeout === 0);
            fake.appIcon = "folder-download";
            phase = "icon";
        } else if (phase === "icon") {
            const e = Notifications.entryFor(key);
            check("B-12: a replacement that changes only the icon is seen", e !== null && e.appIcon === "folder-download");
            fake.urgency = NotificationUrgency.Normal;
            phase = "lowered";
        } else if (phase === "lowered") {
            check("B-12: lowered from critical under Do Not Disturb, the banner goes", bannerRow() === null);
            Notifications.setDnd(false);
            phase = "done";
            if (failures.length === 0)
                console.log("notif-replace: PASS");
            else
                console.log("notif-replace: FAIL " + failures.join("; "));
            Qt.quit();
        }
    }
}
