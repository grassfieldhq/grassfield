import QtQuick
import QtTest
import "../../apps/store/qml/Store.js" as Store
import "../../apps/store/qml/StoreNav.js" as Nav

// The Store's words (apps/store/qml/Store.js: the source badges, the button, the operations and their outcomes, the content
// rating, the languages, the filter's sources, Installed's groups, Updates' state line) and its Back / Forward history
// (StoreNav.js).
TestCase {
    name: "StoreText"

    function test_sourceLabel() {
        compare(Store.sourceLabel("repo", "extra"), "Arch Linux · extra");
        compare(Store.sourceLabel("repo", "omarchy"), "Omarchy");
        compare(Store.sourceLabel("setup", ""), "Omarchy setup");
        compare(Store.sourceLabel("webapp", ""), "Web app");
        compare(Store.sourceLabel("aur", ""), "AUR");
        compare(Store.sourceLabel("flatpak", ""), "Flathub");
        compare(Store.sourceLabel("foreign", ""), "Not from a repository");
        compare(Store.sourceLabel("other", ""), "");
    }

    // The AUR (step 3b2): why Get or Uninstall… is not offered, its own wording for an unchecked Omarchy, a result's line, its
    // Installed group, a refused install, the warning.
    function test_aurTexts() {
        compare(Store.getBlockText("aurOff", "aur"), "Turn on the AUR in the Store's settings to install from it.");
        compare(Store.getBlockText("aurProtected", "aur"), "The system, Omarchy or Grassfield uses this name, so the Store doesn't build it from the AUR.");
        compare(Store.getBlockText("listsMissing", "aur"), "Omarchy's package lists can't be read, so the Store installs nothing from the AUR.");
        compare(Store.getBlockText("repository", "aur"), "A repository has this package: the Store installs it from there, from its own page.");
        compare(Store.getBlockText("aurUnchecked", "aur"), "Installing from the AUR hasn't been checked with your version of Omarchy yet. The Store offers it again once its catalog has been.");
        compare(Store.getBlockText("omarchyChanged", "aur"), Store.getBlockText("aurUnchecked", "aur"));
        compare(Store.getBlockText("omarchyChanged", "setup"), "This setup hasn't been checked with your version of Omarchy yet. The Store offers it again once its catalog has been.");
        compare(Store.uninstallReasonText("aurOff", "aur"), "Turn on the AUR in the Store's settings to uninstall it from the Store.");
        compare(Store.aurLine({votes: 1, outOfDate: false}), "1 vote");
        compare(Store.aurLine({votes: 120, outOfDate: true}), "120 votes · Flagged out of date");
        compare(Store.aurLine({name: "x"}), "");
        compare(Store.groupTitle("aur"), "AUR");
        compare(Store.resultText({kind: "install", outcome: "refused"}), "The installation was refused: the system changed since the Store checked it. Try again from its page.");
        compare(Store.resultText({kind: "remove", outcome: "refused"}), "This app can't be uninstalled from the Store.");
        compare(Store.resultText({kind: "install", outcome: "omarchyChanged", source: "aur"}), Store.omarchyChangedText("aur"));
        verify(Store.aurWarning().startsWith("AUR packages are made by users and reviewed by no one"));
    }

    // Flathub (step 3c part 2): why Get or Uninstall… is not offered, what a Flatpak can reach in plain words (SR11, SD25),
    // its Installed group, a stopped install said nothing about (SD26).
    function test_flathubTexts() {
        compare(Store.getBlockText("flathubOff", "flatpak"), "Turn on Flathub in the Store's settings to install from it.");
        compare(Store.getBlockText("noFlatpak", "flatpak"), "Flathub needs the flatpak package.");
        compare(Store.uninstallReasonText("flathubOff", "flatpak"), "Turn on Flathub in the Store's settings to uninstall it from the Store.");
        compare(Store.groupTitle("flatpak"), "Flathub");
        compare(Store.resultText({kind: "install", outcome: "stopped"}), "", "stopped by the user: nothing to say");
        verify(!Store.canTryAgain({outcome: "stopped"}));
        compare(Store.resultText({kind: "install", outcome: "failed", source: "flatpak"}), "The installation failed.");
    }

    // A Flatpak's permissions (ADR-0049): every class in its group and words, the places with their mode, bus names with
    // their plain name, the notes under the wide grants, a grant the Store does not know as flatpak writes it.
    function test_permissionItems() {
        const item = (key, name, level) => Store.permissionItem({key: key, name: name || "", level: level || 1});
        const groups = {network: "network", allFiles: "files", home: "files", folders: "files", devices: "devices", input: "devices",
                        usb: "devices", usbPortal: "devices", usbHidden: "devices", kvm: "devices", bluetooth: "devices", canbus: "devices",
                        printers: "devices", smartCards: "keys", audio: "sound", x11: "display", x11Fallback: "display", ssh: "keys", gpg: "keys",
                        bus: "services", systemBus: "services", login: "background", outside: "sandbox", devel: "sandbox", ipc: "other", shm: "other",
                        multiarch: "other", other: "other"};
        for (const key in groups)
            compare(item(key, key === "allFiles" ? "/" : key === "home" ? "~" : key === "folders" ? "xdg-download" : "").group, groups[key], key);
        compare(item("folders", "xdg-download", 2).text, "Downloads (read and write)");
        compare(item("folders", "xdg-pictures/Screenshots", 1).text, "Pictures/Screenshots (read only)");
        compare(item("folders", "~/Games", 2).text, "~/Games (read and write)");
        compare(item("folders", "$RUN/pipewire-0", 2).text, "Your session's runtime folder: pipewire-0 (read and write)");
        compare(item("folders", "/run/media/alice", 1).text, "Removable drives (read only)");
        compare(item("folders", "*", 1).text, "A folder its path climbs out of (“..”), which could be anywhere (read only)");
        compare(item("folders", "/opt/data", 2).text, "/opt/data (read and write)");
        compare(item("folders", "xdg-download", 2).note, "", "a folder: no note");
        compare(item("allFiles", "/", 2).text, "All files on this computer (read and write)");
        compare(item("allFiles", "/", 2).note, "It can read and change any file you can, including other apps' data and connected drives.");
        compare(item("allFiles", "/", 1).note, "It can read any file you can, including other apps' data and connected drives.");
        compare(item("allFiles", "host-os", 1).text, "The system's programs and libraries (read only)");
        compare(item("allFiles", "host-os", 1).note, "");
        compare(item("home", "~", 2).text, "Your home folder (read and write)");
        compare(item("home", "~", 1).note, "It can read everything in your home folder, including other apps' data and settings.");
        compare(item("devices").note, "Cameras, microphones, game controllers, USB drives and any other device, without asking.");
        compare(item("x11").text, "The X11 display");
        compare(item("x11").note, "Through X11 it can see what other X11 apps show and what you type in them.");
        compare(item("x11Fallback").text, "The X11 display, only where Wayland is missing");
        compare(item("x11Fallback").note, "This session has Wayland: here it gets no X11.");
        compare(item("usb").text, "USB devices, directly");
        compare(item("usb").note, "Any USB device, without asking.", "raw USB: as wide as all devices for USB");
        compare(item("usbPortal", "all").text, "USB devices, through the USB portal");
        compare(item("usbPortal", "vnd:1234+dev:5678").text, "The USB device vnd:1234+dev:5678, through the USB portal");
        compare(item("usbHidden", "vnd:1234").text, "Hidden from it: the USB device vnd:1234");
        compare(item("usbHidden", "all").text, "Hidden from it: every USB device");
        compare(item("ipc").text, "Memory your other programs share (IPC)");
        compare(item("shm").text, "The shared memory folder of your other programs (/dev/shm)");
        compare(item("folders", "~/Games", 3).text, "~/Games (read and write, created if missing)");
        compare(Store.previousWords({key: "folders", name: "~/Games", previous: {key: "folders", name: "~/Games", level: 3}}), "read and write, created if missing");
        // A bus name that went from talk to own is said in bus words, never "read only" (review finding 9).
        compare(Store.previousWords({key: "sessionService", name: "org.example.Sync", previous: {key: "sessionService", name: "org.example.Sync", level: 1}}), "could talk to it");
        compare(Store.previousWords({key: "systemService", name: "org.example.Sync", previous: {key: "systemService", name: "org.example.Sync", level: 2}}), "owned it");
        compare(item("bus").note, "Including services that can start programs outside its sandbox.");
        compare(item("sessionService", "org.example.Sync", 1).text, "Talks to “org.example.Sync”");
        compare(item("sessionService", "org.example.Sync", 2).text, "Owns the name “org.example.Sync”");
        compare(item("sessionService", "org.example.*", 1).text, "Talks to every service under “org.example”");
        compare(item("sessionService", "org.example.*", 1).note, "A wildcard: services it does not name are included.");
        compare(item("sessionService", "org.gtk.vfs.*", 1).text, "Talks to “Network locations and the Trash (org.gtk.vfs.*)”");
        compare(item("sessionService", "org.freedesktop.secrets", 1).group, "keys");
        compare(item("systemService", "org.freedesktop.NetworkManager", 1).text, "Talks to “Network settings (org.freedesktop.NetworkManager)”, on the system");
        compare(item("login").note, "It can add programs that start at your next login, outside its sandbox.");
        compare(item("outside").note, "Anything it starts this way has all of your access.");
        compare(item("other", "devices=tpm").text, "A permission the Store can't describe: devices=tpm");
        compare(item("later", "x").text, "A permission the Store can't describe: later", "a key this window does not know, as it is");
        compare(item("more", "40").text, "40 more permissions");
    }

    // The product page's cards and the sheets' lines: the groups present in their order, the Files card's footnote unless
    // all files or the home folder are granted; [] for nothing granted, null (no section) when unread.
    function test_permissionGroups() {
        compare(Store.permissionGroups(null), null);
        compare(Store.permissionGroups(undefined), null);
        compare(Store.permissionGroups([]), []);
        const groups = Store.permissionGroups([{key: "network", name: "", level: 1}, {key: "folders", name: "xdg-download", level: 2},
                                               {key: "audio", name: "", level: 1}, {key: "sessionService", name: "org.freedesktop.secrets", level: 1},
                                               {key: "outside", name: "", level: 1}]);
        compare(groups.map(g => g.id), ["files", "network", "sound", "keys", "sandbox"]);
        compare(groups.map(g => g.icon), ["folder", "globe", "microphone", "key", "exclamationmark-triangle"]);
        compare(groups[0].title, "Files and Folders");
        compare(groups[0].items, [{text: "Downloads (read and write)", note: ""}]);
        compare(groups[0].footnote, "Other files: only those you choose in an Open or Save dialog.");
        compare(groups[2].items[0].note, "It can record from the microphone without asking.");
        compare(Store.permissionGroups([{key: "home", name: "~", level: 1}])[0].footnote, "", "the home folder: no footnote");
        compare(Store.permissionLines([{key: "network", name: "", level: 1}, {key: "folders", name: "xdg-music", level: 1},
                                       {key: "folders", name: "xdg-download", level: 2}]),
                ["Files and Folders: Music (read only), Downloads (read and write)", "Network: The internet and your local network"]);
        compare(Store.permissionLines(null), []);
        // The install sheet's short form: group titles, the warning notes once each (review finding 10).
        const sum = Store.permissionSummary([{key: "outside", name: "", level: 1}, {key: "bus", name: "", level: 1}, {key: "network", name: "", level: 1},
                                             {key: "audio", name: "", level: 1}]);
        compare(sum.titles, ["Network", "Microphone and Speakers", "Other Apps and Services", "Outside Its Sandbox"]);
        compare(sum.warnings, ["It can record from the microphone without asking.", "Including services that can start programs outside its sandbox.",
                               "Anything it starts this way has all of your access."]);
        compare(Store.permissionSummary(null), null);
        compare(Store.permissionSummary([]).titles, []);
        for (const id of ["files", "network", "devices", "sound", "display", "keys", "services", "background", "sandbox", "other"])
            verify(Store.permissionGroupTitle(id) !== "", id);
        compare(Store.permissionGroupTitle("devices"), "Camera and Other Devices");
    }

    // An update's changes (ADR-0049): what it newly reaches with what it had, what it no longer reaches; the Updates list's
    // line, at most three then a count.
    function test_permissionChanges() {
        const changes = [{change: "added", key: "network", name: "", level: 1},
                         {change: "widened", key: "folders", name: "xdg-download", level: 2, previous: {key: "folders", name: "xdg-download", level: 1}},
                         {change: "widened", key: "home", name: "~", level: 2, previous: {key: "folders", name: "xdg-documents", level: 2}},
                         {change: "removed", key: "audio", name: "", level: 1},
                         {change: "narrowed", key: "folders", name: "~/Projects/notes", level: 1, previous: {key: "folders", name: "~/Projects", level: 2}},
                         {change: "more", name: "3"}];
        const lines = Store.changeLines(changes);
        compare(lines.more, ["Network: The internet and your local network",
                             "Files and Folders: Downloads (read and write) (was: read only)",
                             "Files and Folders: Your home folder (read and write) (was: Documents (read and write))",
                             "3 more changes"]);
        compare(lines.less, ["Microphone and Speakers: Your speakers and microphone",
                             "Files and Folders: ~/Projects/notes (read only) (was: ~/Projects (read and write))"]);
        compare(Store.changeLines(undefined), {more: [], less: []});
        compare(Store.asksForMoreText({asksForMore: false, permissionChanges: changes}), "");
        compare(Store.asksForMoreText({name: "x"}), "");
        compare(Store.asksForMoreText({asksForMore: true, permissionsUnknown: true}), "What this update can reach couldn't be checked.");
        compare(Store.asksForMoreText({asksForMore: true, permissionChanges: changes.slice(0, 3)}),
                "Asks for more: The internet and your local network, Downloads (read and write), Your home folder (read and write)");
        compare(Store.asksForMoreText({asksForMore: true, permissionChanges: changes.slice(0, 3).concat([{change: "added", key: "x11", name: "", level: 1},
                                                                                                         {change: "added", key: "more", name: "7", level: 1}])}),
                "Asks for more: The internet and your local network, Downloads (read and write), Your home folder (read and write), 2 more");
    }

    function test_symbols() {
        compare(Store.symbolIcon("discover"), "sparkle");
        compare(Store.symbolIcon("category-internet"), "globe");
        compare(Store.symbolIcon("unknown-symbol"), "apps", "an unknown symbol gets the generic glyph");
    }

    function test_button() {
        compare(Store.buttonState(null), "get");
        compare(Store.buttonState({installed: false, launcher: true}), "get");
        compare(Store.buttonState({installed: true, launcher: true}), "open");
        compare(Store.buttonState({installed: true, launcher: false}), "installed");
        compare(Store.buttonText("get"), "Get");
        compare(Store.buttonText("open"), "Open");
        compare(Store.buttonText("installed"), "Installed");
    }

    // Step 3: the button with the backend's actions and an operation, why Get or Uninstall… is not offered, what an operation
    // is doing, how it ended (SR13, SR18-SR22, SR30).
    function test_operations() {
        compare(Store.buttonState({installed: false}, {installed: true, launcher: true}, null), "open", "the backend's facts win");
        compare(Store.buttonState({installed: true, launcher: true}, null, {state: "waiting"}), "progress");
        compare(Store.getBlockText("dev"), "dev: not applied");
        compare(Store.getBlockText("offline"), "You're offline.");
        compare(Store.getBlockText(""), "");
        compare(Store.operationText({kind: "install", state: "waiting", blocked: false}), "Waiting");
        compare(Store.operationText({kind: "install", state: "waiting", blocked: true}), "Waiting for another installation or an update to finish");
        compare(Store.operationText({kind: "install", state: "authorizing"}), "Waiting for permission…");
        compare(Store.operationText({kind: "install", state: "running", done: 0, total: 3}), "Installing…");
        compare(Store.operationText({kind: "install", state: "running", done: 2, total: 3}), "Installing: 2 of 3");
        compare(Store.operationText({kind: "remove", state: "running", done: 1, total: 2}), "Uninstalling: 1 of 2");
        compare(Store.operationText({kind: "remove", state: "checking"}), "Finishing the uninstallation…");
        // Omarchy's terminal (b.2): opening it, then the recipe running there; pacman's count when its log has one.
        compare(Store.operationText({kind: "install", path: "terminal", state: "opening"}), "Opening Terminal…");
        compare(Store.operationText({kind: "install", path: "terminal", state: "running", done: 0, total: 3}), "Installing in Terminal…");
        compare(Store.operationText({kind: "remove", path: "terminal", state: "running", done: 0, total: 1}), "Uninstalling in Terminal…");
        compare(Store.operationText({kind: "install", path: "terminal", state: "running", done: 1, total: 3}), "Installing: 1 of 3");
        compare(Store.resultText({kind: "install", outcome: "terminalDidNotOpen"}), "The terminal did not open.");
        verify(Store.canTryAgain({outcome: "terminalDidNotOpen"}));
        compare(Store.resultText({kind: "install", outcome: "omarchyChanged"}),
                "This setup hasn't been checked with your version of Omarchy yet. The Store offers it again once its catalog has been.");
        verify(!Store.canTryAgain({outcome: "omarchyChanged"}), "trying again changes nothing until the catalog has");
        compare(Store.getBlockText("omarchyChanged"), Store.resultText({outcome: "omarchyChanged"}));
        compare(Store.uninstallReasonText("omarchyChanged"), Store.resultText({outcome: "omarchyChanged"}));
        compare(Store.resultText({kind: "install", outcome: "interrupted", present: 15, total: 110}),
                "The installation was interrupted: 15 of 110 packages were installed.");
        compare(Store.resultText({kind: "remove", outcome: "notFinished"}), "The uninstallation did not finish.");
        compare(Store.resultText({kind: "install", outcome: "cancelled"}), "", "a cancelled request says nothing");
        compare(Store.resultText({kind: "install", outcome: "unfinished"}), "Finish the system update first.");
        verify(Store.canTryAgain({outcome: "interrupted"}));
        verify(!Store.canTryAgain({outcome: "refused"}));
        compare(Store.uninstallReasonText("omarchy"), "Part of Omarchy");
        compare(Store.uninstallReasonText("grassfield"), "Part of Grassfield");
        compare(Store.uninstallReasonText("system"), "Part of the system");
        compare(Store.uninstallReasonText("dependency"), "Installed with another app");
        compare(Store.uninstallReasonText(""), "");
        compare(Store.uninstallReasonText("notInstalled"), "");
    }

    function test_rating() {
        compare(Store.ratingText(false, {}), "Not rated");
        compare(Store.ratingText(true, {}), "None");
        compare(Store.ratingText(true, {violence: 1, money: 2}), "Violence: mild · Purchases or gambling: moderate");
        compare(Store.ratingText(true, {social: 3, drugs: 9}), "Online interaction: intense", "a level out of range is left out");
    }

    function test_languages() {
        compare(Store.languagesText([]), "");
        compare(Store.languagesText(["Deutsch", "français"]), "Deutsch, français");
        compare(Store.languagesText(["a", "b", "c"]), "a, b, c");
        compare(Store.languagesText(["a", "b", "c", "d", "e"]), "a, b and 3 more");
        compare(Store.languagesText(["a", "b", "c", "d"]), "a, b and 2 more");
    }

    function test_kinds() {
        compare(Store.kindsIn([{kind: "webapp"}, {kind: "repo"}, {kind: "repo"}, {kind: "setup"}]), ["repo", "setup", "webapp"]);
        compare(Store.kindsIn([]), []);
        compare(Store.kindTitle("setup"), "Omarchy Setups");
        compare(Store.groupTitle("foreign"), "Not from a Repository");
    }

    function test_updatesStatus() {
        compare(Store.updatesStatus({state: "up-to-date", checkedAt: "9:12"}), "Your apps are up to date. Last checked 9:12.");
        compare(Store.updatesStatus({state: "failed", error: "offline"}), "Updates could not be checked: you're offline.");
        compare(Store.updatesStatus({state: "busy"}), "Update in progress");
        compare(Store.updatesStatus({state: "unknown"}), "Software Update has not checked for updates yet.");
        compare(Store.updatesStatus(null), "Software Update has not checked for updates yet.");
        // Step 4: what runs or is asked comes first.
        compare(Store.updatesStatus({state: "available", running: true}), "Update in progress");
        compare(Store.updatesStatus({state: "available", checking: true}), "Checking for updates…");
        compare(Store.updatesStatus({state: "up-to-date", unfinished: 3}), "The last system update did not finish.");
        compare(Store.updatesStatus({state: "up-to-date", checkedAt: "9:12", count: 1}), "Last checked 9:12.");
        compare(Store.updatesStatus({state: "unknown", askFailed: true}), "Software Update couldn't check for updates. Open it to check.");
    }

    // The system's button on Updates (SD32): Update All… opens Software Update; Software Update… when only it can act.
    function test_systemAction() {
        compare(Store.systemAction({state: "available", others: 3}), "update");
        compare(Store.systemAction({state: "up-to-date", others: 0, grassfield: {available: "1.0.1-1"}}), "update");
        compare(Store.systemAction({state: "up-to-date", others: 0, unfinished: 1}), "update");
        compare(Store.systemAction({state: "up-to-date", others: 0}), "");
        compare(Store.systemAction({state: "blocking"}), "software");
        compare(Store.systemAction({state: "not-set-up"}), "software");
        compare(Store.systemAction({state: "available", others: 3, running: true}), "");
        compare(Store.systemAction({state: "available", others: 3, checking: true}), "");
        compare(Store.systemAction(null), "");
    }

    function test_flatpakUpdates() {
        compare(Store.flatpakUpdatesLine({on: false}), "");
        compare(Store.flatpakUpdatesLine({on: true, state: "checking"}), "Checking Flathub for updates…");
        compare(Store.flatpakUpdatesLine({on: true, state: "failed"}), "Flathub's updates couldn't be checked. Check your connection to the internet, then try again.");
        compare(Store.flatpakUpdatesLine({on: true, state: "", apps: [], runtimes: 0}), "Your Flatpak apps are up to date.");
        compare(Store.flatpakUpdatesLine({on: true, state: "", apps: [], runtimes: 2}), "2 runtimes have an update.");
        compare(Store.flatpakUpdatesLine({on: true, state: "", apps: [{id: "a"}], runtimes: 2}), "");
        // An update's plan reading each app's commit and access (SD33): counted, before anything else.
        compare(Store.flatpakUpdatesLine({on: true, state: "checking", apps: [{id: "a"}], planning: {done: 2, total: 5}}), "Checking what the updates change: 2 of 5 apps…");
        compare(Store.flatpakUpdatesLine({on: true, state: "", apps: [], runtimes: 1, planning: {done: 0, total: 0}}), "1 runtime has an update.");
        compare(Store.flatpakUpdatesLine({on: true, state: "", apps: [{id: "a"}], planning: {done: 0, total: 1}}), "Checking what the update changes…", "one app: no count");
        compare(Store.flatpakUpdatesLine({on: true, state: "", apps: [{id: "a"}], planning: {done: 1, total: 2}}), "Checking what the updates change: 1 of 2 apps…");
        compare(Store.getBlockText("checking", "flatpak"), "Checking what this update changes…");
        compare(Store.buttonState({}, {installed: true, launcher: true, update: "checking"}, null), "update");
        // The button: Update for an installed Flatpak with an update, never before Get.
        compare(Store.buttonState({}, {installed: true, launcher: true, update: ""}, null), "update");
        compare(Store.buttonState({}, {installed: true, launcher: true, update: "offline"}, null), "update");
        compare(Store.buttonState({}, {installed: true, launcher: true, update: "none"}, null), "open");
        compare(Store.buttonState({}, {installed: false, launcher: false, update: ""}, null), "get");
        compare(Store.buttonText("update"), "Update");
        // How an update ended: judged by a new check (S31d).
        compare(Store.resultText({kind: "update", outcome: "notFinished"}), "The update did not finish. Check your connection to the internet, then try again.");
        compare(Store.resultText({kind: "update", outcome: "interrupted", present: 1, total: 3}), "The update was interrupted: 1 of 3 were updated.");
        compare(Store.resultText({kind: "update", outcome: "failed"}), "The update failed.");
        compare(Store.resultText({kind: "update", outcome: ""}), "");
    }

    function test_host() {
        compare(Store.hostOf("https://www.gimp.org/about"), "www.gimp.org");
        compare(Store.hostOf("http://example.org"), "");
        compare(Store.hostOf(""), "");
    }

    // Back and forward keep each page's scroll; the same page is not visited twice; a typed query replaces in place.
    function test_navigation() {
        let s = Nav.start({page: "section", id: "discover"});
        verify(!Nav.canBack(s) && !Nav.canForward(s));
        s = Nav.visit(s, {page: "app", id: "a"}, 300);
        compare(s.back[0].scroll, 300);
        compare(s.current.scroll, 0);
        compare(Nav.visit(s, {page: "app", id: "a"}, 10), s, "the same page changes nothing");
        s = Nav.back(s, 55);
        compare(s.current.id, "discover");
        compare(s.current.scroll, 300);
        compare(s.forward[0].scroll, 55);
        s = Nav.forward(s, 300);
        compare(s.current.id, "a");
        compare(s.current.scroll, 55);
        s = Nav.visit(s, {page: "search", query: "p"}, 0);
        s = Nav.replace(s, {page: "search", query: "pa"});
        compare(s.back.length, 2);
        compare(s.current.query, "pa");
        compare(Nav.back(Nav.start({page: "x"})).current.page, "x", "nothing to go back to");
        verify(!Nav.same({page: "search", query: "a"}, {page: "search", query: "b"}));
    }
}
