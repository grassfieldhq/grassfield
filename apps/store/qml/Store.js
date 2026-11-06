.pragma library

// The words of the Store's data (spec SR5, SR11, SR13, SR23, SR24): the backend gives kinds, repositories, levels and
// states; the text is made here, translated. Pure, so that tests/unit/tst_storetext.qml reaches every case.

// A source badge (SR5): the repository for Arch Linux's, "Omarchy" for [omarchy], and the other sources by name.
function sourceLabel(kind, repo) {
    switch (kind) {
    case "repo":
        return repo === "omarchy" ? qsTr("Omarchy") : qsTr("Arch Linux · %1").arg(repo);
    case "setup":
        return qsTr("Omarchy setup");
    case "webapp":
        return qsTr("Web app");
    case "aur":
        return qsTr("AUR");
    case "flatpak":
        return qsTr("Flathub");
    case "getFlatpak":
        return qsTr("Arch Linux");
    case "foreign":
        return qsTr("Not from a repository");
    }
    return "";
}

// The glyph of a catalog symbol (sections and categories); an unknown symbol gets the generic one.
var SYMBOLS = {
    "discover": "sparkle",
    "create": "paintbrush",
    "work": "paperplane",
    "play": "gamecontroller",
    "develop": "hammer",
    "category-productivity": "paperplane",
    "category-graphics": "paintbrush",
    "category-photo-video": "film",
    "category-music-audio": "music-note",
    "category-developer-tools": "hammer",
    "category-games": "gamecontroller",
    "category-internet": "globe",
    "category-education": "book",
    "category-utilities": "wrench"
};

function symbolIcon(symbol) {
    return SYMBOLS[symbol] || "apps";
}

// The button of an app (SR13): its operation's ring while one runs or waits ("progress"), else Get, Update (a Flatpak with
// an update, step 4), Open (installed with a launcher) or Installed (installed without one). `actions`: the backend's
// (installed, launcher, update), when there is one.
function buttonState(app, actions, operation) {
    if (operation)
        return "progress";
    const installed = actions ? actions.installed : app && app.installed;
    const launcher = actions ? actions.launcher : app && app.launcher;
    if (!installed)
        return "get";
    if (actions && actions.update !== undefined && actions.update !== "none")
        return "update";
    return launcher ? "open" : "installed";
}

// Why Get is not offered now (the button's tooltip, SR13, SR30). `kind`: the app's source (the AUR's words differ).
function getBlockText(reason, kind) {
    switch (reason) {
    case "dev":
        return qsTr("dev: not applied");
    case "offline":
        return qsTr("You're offline.");
    case "missing":
        return qsTr("This computer can't install apps from the Store: Omarchy's commands or Grassfield's installer are missing.");
    case "icon":
        return qsTr("This web app's icon hasn't been downloaded yet. Refresh the Store, then try again.");
    case "omarchyChanged":
        return omarchyChangedText(kind);
    case "aurUnchecked":
        return omarchyChangedText("aur");
    case "flatpakUnchecked":
        return omarchyChangedText("getFlatpak");
    case "aurOff":
        return qsTr("Turn on the AUR in the Store's settings to install from it.");
    case "aurProtected":
        return qsTr("The system, Omarchy or Grassfield uses this name, so the Store doesn't build it from the AUR.");
    case "listsMissing":
        return qsTr("Omarchy's package lists can't be read, so the Store installs nothing from the AUR.");
    case "repository":
        return qsTr("A repository has this package: the Store installs it from there, from its own page.");
    case "flathubOff":
        return qsTr("Turn on Flathub in the Store's settings to install from it.");
    case "checking":
        return qsTr("Checking what this update changes…");
    case "noFlatpak":
        return qsTr("Flathub needs the flatpak package.");
    case "source":
        return qsTr("Installing apps from this source comes in a later version of the Store.");
    }
    return "";
}

// A setup, or an AUR app, while the installed Omarchy differs from the release the catalog checked (ADR-0037 b.2, g).
function omarchyChangedText(kind) {
    if (kind === "aur")
        return qsTr("Installing from the AUR hasn't been checked with your version of Omarchy yet. The Store offers it again once its catalog has been.");
    if (kind === "getFlatpak")
        return qsTr("Flathub needs Flatpak, and getting it hasn't been checked with your version of Omarchy yet. The Store offers it again once its catalog has been.");
    return qsTr("This setup hasn't been checked with your version of Omarchy yet. The Store offers it again once its catalog has been.");
}

// An AUR result's line (SR7): its votes, and the out-of-date flag; "" for any other app.
function aurLine(app) {
    if (!app || app.votes === undefined)
        return "";
    const votes = app.votes === 1 ? qsTr("1 vote") : qsTr("%1 votes").arg(app.votes);
    return app.outOfDate ? qsTr("%1 · Flagged out of date").arg(votes) : votes;
}

// The AUR's warning, on the sheet of every AUR install (spec SR16, ADR-0037 e.7).
function aurWarning() {
    return qsTr("AUR packages are made by users and reviewed by no one, neither Arch Linux nor Grassfield. Their build script runs on this computer and the package is then installed with administrator rights. Install only what you trust.");
}

// What an operation is doing (its ring's accessible text and the queue's rows, SR18).
function operationText(op) {
    if (!op)
        return "";
    const removing = op.kind === "remove";
    switch (op.state) {
    case "waiting":
        return op.blocked ? qsTr("Waiting for another installation or an update to finish") : qsTr("Waiting");
    case "authorizing":
        return qsTr("Waiting for permission…");
    case "opening":
        return qsTr("Opening Terminal…");
    case "checking":
        return removing ? qsTr("Finishing the uninstallation…") : qsTr("Finishing the installation…");
    }
    if (op.total > 0 && op.done > 0)
        return removing ? qsTr("Uninstalling: %1 of %2").arg(op.done).arg(op.total) : qsTr("Installing: %1 of %2").arg(op.done).arg(op.total);
    if (op.path === "terminal")
        return removing ? qsTr("Uninstalling in Terminal…") : qsTr("Installing in Terminal…");
    return removing ? qsTr("Uninstalling…") : qsTr("Installing…");
}

// How the last operation of an app ended, in one line (SR19, SR20); "" when there is nothing to say (done, cancelled, or a
// Flatpak install the user stopped: "stopped").
function resultText(result) {
    if (!result)
        return "";
    const removing = result.kind === "remove";
    // A Flatpak's update (step 4): judged by a new check, never by flatpak's exit code alone (offline it says "Nothing to
    // update" and exits 0, S31d).
    if (result.kind === "update") {
        switch (result.outcome) {
        case "interrupted":
            return qsTr("The update was interrupted: %1 of %2 were updated.").arg(result.present).arg(result.total);
        case "notFinished":
            return qsTr("The update did not finish. Check your connection to the internet, then try again.");
        case "lostTrack":
            return qsTr("The Store stopped following this operation after a long time. Check what is installed in Installed.");
        case "failed":
            return qsTr("The update failed.");
        }
        return "";
    }
    switch (result.outcome) {
    case "interrupted":
        return removing ? qsTr("The uninstallation was interrupted: %1 of %2 packages were removed.").arg(result.present).arg(result.total)
                        : qsTr("The installation was interrupted: %1 of %2 packages were installed.").arg(result.present).arg(result.total);
    case "notFinished":
        return removing ? qsTr("The uninstallation did not finish.") : qsTr("The installation did not finish.");
    case "lostTrack":
        return qsTr("The Store stopped following this operation after a long time. Check what is installed in Installed.");
    case "timedOut":
        return qsTr("The request for permission timed out.");
    case "didNotStart":
        return removing ? qsTr("The uninstallation could not start: permission was not given.") : qsTr("The installation could not start: permission was not given.");
    case "busy":
        return qsTr("Another installation or an update is running.");
    case "unfinished":
        return qsTr("Finish the system update first.");
    case "outdated":
        // The databases are older than the mirror (a plan refused before anything downloaded, or a file the mirror no
        // longer had): the system is updated first (the integrator's note on PR #36).
        return qsTr("Your system needs to be updated before you can install apps.");
    case "refused":
        // The AUR's plan checked again in the terminal (a repository has the package now, or it is protected or needed).
        return removing ? qsTr("This app can't be uninstalled from the Store.")
                        : qsTr("The installation was refused: the system changed since the Store checked it. Try again from its page.");
    case "notApp":
        return qsTr("This package isn't an app: the Store installs only apps.");
    case "failed":
        return removing ? qsTr("The uninstallation failed.") : qsTr("The installation failed.");
    case "omarchyChanged":
        return omarchyChangedText(result.source || "");
    case "terminalDidNotOpen":
        return qsTr("The terminal did not open.");
    }
    return "";
}

// A result that Software Update answers (the last system update did not finish, or the system is older than the mirror):
// "Update Now…" opens it, and nothing of pacman's output is shown.
function needsUpdate(result) {
    return !!result && (result.outcome === "outdated" || result.outcome === "unfinished");
}

// A result the user can try again (the same plan; --needed completes a partial install).
function canTryAgain(result) {
    return !!result && ["interrupted", "notFinished", "timedOut", "didNotStart", "busy", "failed", "lostTrack", "terminalDidNotOpen"].indexOf(result.outcome) >= 0;
}

// Why "Uninstall…" is not offered (SR22); "" when it is, or when there is nothing to say (not installed).
function uninstallReasonText(reason, kind) {
    switch (reason) {
    case "omarchy":
        return qsTr("Part of Omarchy");
    case "grassfield":
        return qsTr("Part of Grassfield");
    case "system":
        return qsTr("Part of the system");
    case "dependency":
        return qsTr("Installed with another app");
    case "notApp":
        return qsTr("Not an app: it has no window of its own");
    case "notFromRepository":
        return qsTr("Not from a repository: uninstalling it comes in a later version of the Store");
    case "listsMissing":
        return qsTr("Omarchy's package lists can't be read, so the Store uninstalls nothing");
    case "dev":
        return qsTr("dev: not applied");
    case "missing":
        return qsTr("This computer can't uninstall apps from the Store: Omarchy's commands or Grassfield's installer are missing.");
    case "omarchyChanged":
        return omarchyChangedText(kind);
    case "aurUnchecked":
        return omarchyChangedText("aur");
    case "aurOff":
        return qsTr("Turn on the AUR in the Store's settings to uninstall it from the Store.");
    case "flathubOff":
        return qsTr("Turn on Flathub in the Store's settings to uninstall it from the Store.");
    case "noFlatpak":
        return qsTr("Flathub needs the flatpak package.");
    }
    return "";
}

// ---- A Flatpak's permissions, grant by grant (ADR-0049): the product page's cards, the sheets' lines, the Updates list's
// "Asks for more". A grant is the backend's {key, name, level} (view::permissions; a place's level 1 read only, 2 read and
// write, 3 create); a change adds {change, previous} (view::permissionChanges).

// The groups in the order the page shows them: id, title, glyph (branding/icons/symbolic).
const PERMISSION_GROUPS = [
    ["files", "folder"], ["network", "globe"], ["devices", "camera"], ["sound", "microphone"], ["display", "display"],
    ["keys", "key"], ["services", "apps"], ["background", "power"], ["sandbox", "exclamationmark-triangle"], ["other", "info"]
];

function permissionGroupTitle(id) {
    switch (id) {
    case "files":
        return qsTr("Files and Folders");
    case "network":
        return qsTr("Network");
    case "devices":
        return qsTr("Camera and Other Devices");
    case "sound":
        return qsTr("Microphone and Speakers");
    case "display":
        return qsTr("Display");
    case "keys":
        return qsTr("Keys and Passwords");
    case "services":
        return qsTr("Other Apps and Services");
    case "background":
        return qsTr("Background and Login");
    case "sandbox":
        return qsTr("Outside Its Sandbox");
    }
    return qsTr("Other");
}

// Bus names Grassfield can name in plain words (the session's and the system's).
function busNameWords(name) {
    switch (name) {
    case "org.freedesktop.secrets":
        return qsTr("Your saved passwords");
    case "ca.desrt.dconf":
        return qsTr("Desktop settings");
    case "org.gtk.vfs.*":
        return qsTr("Network locations and the Trash");
    case "org.freedesktop.NetworkManager":
        return qsTr("Network settings");
    case "org.freedesktop.GeoClue2":
        return qsTr("Your location");
    case "org.bluez":
        return qsTr("Bluetooth");
    case "org.freedesktop.login1":
        return qsTr("Sessions, sleep and shutdown");
    case "org.freedesktop.UPower":
        return qsTr("Battery");
    case "org.freedesktop.UDisks2":
        return qsTr("Disks");
    case "org.freedesktop.Avahi":
        return qsTr("Devices on your local network");
    }
    return "";
}

// A user folder as flatpak writes it (xdg-download…), in the words of the file manager's sidebar.
function userFolderWords(word) {
    switch (word) {
    case "xdg-desktop":
        return qsTr("Desktop");
    case "xdg-documents":
        return qsTr("Documents");
    case "xdg-download":
        return qsTr("Downloads");
    case "xdg-music":
        return qsTr("Music");
    case "xdg-pictures":
        return qsTr("Pictures");
    case "xdg-public-share":
        return qsTr("Public");
    case "xdg-templates":
        return qsTr("Templates");
    case "xdg-videos":
        return qsTr("Videos");
    }
    return "";
}

// A place (the backend's normalised name) in plain words.
function placeWords(place) {
    if (place === "/" || place === "host-root")
        return qsTr("All files on this computer");
    if (place === "host-os")
        return qsTr("The system's programs and libraries");
    if (place === "host-etc")
        return qsTr("The system's settings");
    if (place === "~")
        return qsTr("Your home folder");
    if (place === "*")
        return qsTr("A folder its path climbs out of (“..”), which could be anywhere");
    const slash = place.indexOf("/");
    const head = slash < 0 ? place : place.slice(0, slash), rest = slash < 0 ? "" : place.slice(slash + 1);
    const folder = userFolderWords(head);
    if (folder !== "")
        return rest === "" ? folder : folder + "/" + rest;
    if (head === "$RUN")
        return rest === "" ? qsTr("Your session's runtime folder") : qsTr("Your session's runtime folder: %1").arg(rest);
    if (/^\/(run\/media|media|mnt)(\/|$)/.test(place))
        return qsTr("Removable drives");
    return place;
}

// One grant as an item: its group, its words, and a short note when it is wide (what it means, said plainly).
function permissionItem(g) {
    const key = String(g.key || ""), name = String(g.name || ""), level = Number(g.level || 1);
    const write = level >= 2;
    const mode = text => level >= 3 ? qsTr("%1 (read and write, created if missing)").arg(text)
                       : write ? qsTr("%1 (read and write)").arg(text) : qsTr("%1 (read only)").arg(text);
    switch (key) {
    case "network":
        return {group: "network", text: qsTr("The internet and your local network"), note: ""};
    case "allFiles":
    case "home":
    case "folders": {
        const all = key === "allFiles" && (name === "/" || name === "host-root"), home = key === "home";
        const note = all ? (write ? qsTr("It can read and change any file you can, including other apps' data and connected drives.")
                                  : qsTr("It can read any file you can, including other apps' data and connected drives."))
                   : home ? (write ? qsTr("It can read and change everything in your home folder, including other apps' data and settings.")
                                   : qsTr("It can read everything in your home folder, including other apps' data and settings."))
                   : "";
        return {group: "files", text: mode(placeWords(name)), note: note};
    }
    case "devices":
        return {group: "devices", text: qsTr("All devices"),
                note: qsTr("Cameras, microphones, game controllers, USB drives and any other device, without asking.")};
    case "input":
        return {group: "devices", text: qsTr("Game controllers and other input devices"), note: ""};
    case "usb":
        return {group: "devices", text: qsTr("USB devices, directly"), note: qsTr("Any USB device, without asking.")};
    case "usbPortal":
        return {group: "devices", text: name === "all" ? qsTr("USB devices, through the USB portal") : qsTr("The USB device %1, through the USB portal").arg(name),
                note: ""};
    case "usbHidden":
        return {group: "devices", text: name === "all" ? qsTr("Hidden from it: every USB device") : qsTr("Hidden from it: the USB device %1").arg(name),
                note: ""};
    case "kvm":
        return {group: "devices", text: qsTr("Virtual machines, through KVM"), note: ""};
    case "bluetooth":
        return {group: "devices", text: qsTr("Bluetooth devices, directly"), note: ""};
    case "canbus":
        return {group: "devices", text: qsTr("CAN bus devices"), note: ""};
    case "printers":
        return {group: "devices", text: qsTr("Your printers, directly"), note: ""};
    case "smartCards":
        return {group: "keys", text: qsTr("Smart cards"), note: ""};
    case "audio":
        return {group: "sound", text: qsTr("Your speakers and microphone"), note: qsTr("It can record from the microphone without asking.")};
    case "x11":
        return {group: "display", text: qsTr("The X11 display"),
                note: qsTr("Through X11 it can see what other X11 apps show and what you type in them.")};
    case "x11Fallback":
        return {group: "display", text: qsTr("The X11 display, only where Wayland is missing"),
                note: qsTr("This session has Wayland: here it gets no X11.")};
    case "ssh":
        return {group: "keys", text: qsTr("Your SSH keys, through the SSH agent"), note: ""};
    case "gpg":
        return {group: "keys", text: qsTr("Your GnuPG keys, through the GnuPG agent"), note: ""};
    case "bus":
        return {group: "services", text: qsTr("Every service of your session"),
                note: qsTr("Including services that can start programs outside its sandbox.")};
    case "systemBus":
        return {group: "services", text: qsTr("Every service of the system"), note: qsTr("Including services that change the system's settings.")};
    case "sessionService":
    case "systemService": {
        const wildcard = name.endsWith(".*");
        const known = busNameWords(name);
        const shown = known !== "" ? qsTr("%1 (%2)").arg(known).arg(name) : wildcard ? name.slice(0, -2) : name;
        const text = wildcard && known === "" ? (write ? qsTr("Owns every name under “%1”").arg(shown) : qsTr("Talks to every service under “%1”").arg(shown))
                                              : (write ? qsTr("Owns the name “%1”").arg(shown) : qsTr("Talks to “%1”").arg(shown));
        const group = name === "org.freedesktop.secrets" ? "keys" : "services";
        return {group: group, text: key === "systemService" ? qsTr("%1, on the system").arg(text) : text,
                note: wildcard ? qsTr("A wildcard: services it does not name are included.") : ""};
    }
    case "login":
        return {group: "background", text: qsTr("Programs that start when you log in"),
                note: qsTr("It can add programs that start at your next login, outside its sandbox.")};
    case "outside":
        return {group: "sandbox", text: qsTr("Programs outside its sandbox"), note: qsTr("Anything it starts this way has all of your access.")};
    case "devel":
        return {group: "sandbox", text: qsTr("Developer features that can trace programs"), note: ""};
    case "ipc":
        return {group: "other", text: qsTr("Memory your other programs share (IPC)"), note: ""};
    case "shm":
        return {group: "other", text: qsTr("The shared memory folder of your other programs (/dev/shm)"), note: ""};
    case "multiarch":
        return {group: "other", text: qsTr("32-bit programs"), note: ""};
    case "more":
        return {group: "other", text: qsTr("%1 more permissions").arg(name), note: ""};
    }
    return {group: "other", text: qsTr("A permission the Store can't describe: %1").arg(key === "other" ? name : key), note: ""};
}

// The product page's cards: [{id, title, icon, items [{text, note}], footnote}] in the groups' order, only those present.
// [] for none (the page then says "only its own window and files"); null when unread (the page says nothing).
function permissionGroups(grants) {
    if (grants === undefined || grants === null)
        return null;
    const byGroup = {};
    for (const g of grants) {
        const item = permissionItem(g);
        (byGroup[item.group] = byGroup[item.group] || []).push({text: item.text, note: item.note});
    }
    const wideFiles = Array.from(grants, g => g.key === "home" || (g.key === "allFiles" && (g.name === "/" || g.name === "host-root"))).indexOf(true) >= 0;
    return PERMISSION_GROUPS.filter(p => byGroup[p[0]] !== undefined).map(p => ({
        id: p[0], title: permissionGroupTitle(p[0]), icon: p[1], items: byGroup[p[0]],
        footnote: p[0] === "files" && !wideFiles ? qsTr("Other files: only those you choose in an Open or Save dialog.") : ""
    }));
}

// The same as lines for a sheet: "Files and Folders: Downloads (read and write), Music (read only)", one per group.
function permissionLines(grants) {
    const groups = permissionGroups(grants);
    if (groups === null)
        return [];
    return groups.map(g => qsTr("%1: %2").arg(g.title).arg(g.items.map(i => i.text).join(", ")));
}

// The same for an install sheet, short to scan (macOS's sheets say one thing per line): one line per group, its title only,
// and the notes that warn (a wide grant: a service that starts programs, all of the user's access), each once, on a line
// of their own. The page lists the items. {titles: [], warnings: []}; null when unread.
function permissionSummary(grants) {
    const groups = permissionGroups(grants);
    if (groups === null)
        return null;
    const warnings = [];
    for (const g of groups) {
        for (const i of g.items) {
            if (i.note !== "" && warnings.indexOf(i.note) < 0)
                warnings.push(i.note);
        }
    }
    return {titles: groups.map(g => g.title), warnings: warnings};
}

// What a grant was before an update (a widened or narrowed change's previous), in words.
function previousWords(change) {
    const p = change.previous;
    if (!p)
        return "";
    // A bus name is talked to or owned, never read or written (review of the Luma pull request, nested finding 9).
    if (p.key === change.key && p.name === change.name && (p.key === "sessionService" || p.key === "systemService"))
        return Number(p.level) >= 2 ? qsTr("owned it") : qsTr("could talk to it");
    if (p.key === change.key && p.name === change.name)
        return Number(p.level) >= 3 ? qsTr("read and write, created if missing") : Number(p.level) >= 2 ? qsTr("read and write") : qsTr("read only");
    return permissionItem(p).text;
}

// An update's changes as the sheet says them: what the app can newly reach (added, widened, with what it had), then what
// it can no longer reach (removed, narrowed). {more: [lines], less: [lines]}.
function changeLines(changes) {
    const more = [], less = [];
    for (const c of changes || []) {
        if (c.change === "more") {
            more.push(qsTr("%1 more changes").arg(c.name));
            continue;
        }
        const item = permissionItem(c);
        const group = permissionGroupTitle(item.group);
        const was = previousWords(c);
        const line = was !== "" ? qsTr("%1: %2 (was: %3)").arg(group).arg(item.text).arg(was) : qsTr("%1: %2").arg(group).arg(item.text);
        if (c.change === "added" || c.change === "widened")
            more.push(line);
        else
            less.push(line);
    }
    return {more: more, less: less};
}

// The Updates list's line under an app whose update asks for more (ADR-0049): what it newly reaches, in short; "" for one
// that does not.
function asksForMoreText(app) {
    if (!app || !app.asksForMore)
        return "";
    if (app.permissionsUnknown)
        return qsTr("What this update can reach couldn't be checked.");
    const words = [];
    for (const c of app.permissionChanges || []) {
        if (c.change !== "added" && c.change !== "widened")
            continue;
        const text = c.key === "more" ? qsTr("%1 more").arg(c.name) : permissionItem(c).text;
        if (words.indexOf(text) < 0)
            words.push(text);
    }
    const shown = words.length > 3 ? words.slice(0, 3).concat([qsTr("%1 more").arg(words.length - 3)]) : words;
    return qsTr("Asks for more: %1").arg(shown.join(", "));
}

function buttonText(state) {
    return state === "open" ? qsTr("Open") : state === "installed" ? qsTr("Installed") : state === "update" ? qsTr("Update") : qsTr("Get");
}

// The content rating (SR11): "Not rated" without OARS data, "None" when it lists nothing, else each group at its level.
function ratingText(rated, rating) {
    if (!rated)
        return qsTr("Not rated");
    const groups = [["violence", qsTr("Violence")], ["drugs", qsTr("Drugs, alcohol or tobacco")], ["sex", qsTr("Sexual content")],
                    ["language", qsTr("Strong language")], ["social", qsTr("Online interaction")], ["money", qsTr("Purchases or gambling")]];
    const levels = ["", qsTr("mild"), qsTr("moderate"), qsTr("intense")];
    const parts = [];
    for (const g of groups) {
        const level = rating ? rating[g[0]] : 0;
        if (level >= 1 && level <= 3)
            parts.push(qsTr("%1: %2").arg(g[1]).arg(levels[level]));
    }
    return parts.length === 0 ? qsTr("None") : parts.join(" · ");
}

// The languages (SR11): up to three by name, else two and how many more.
function languagesText(languages) {
    if (!languages || languages.length === 0)
        return "";
    if (languages.length <= 3)
        return languages.join(", ");
    return qsTr("%1, %2 and %3 more").arg(languages[0]).arg(languages[1]).arg(languages.length - 2);
}

// The sources present in a list, in the Store's order: the category page's filter (SR8).
function kindsIn(apps) {
    const order = ["repo", "setup", "webapp", "aur", "flatpak"];
    const seen = {};
    for (const a of apps || [])
        seen[a.kind] = true;
    return order.filter(k => seen[k]);
}

function kindTitle(kind) {
    switch (kind) {
    case "repo":
        return qsTr("Repositories");
    case "setup":
        return qsTr("Omarchy Setups");
    case "webapp":
        return qsTr("Web Apps");
    case "aur":
        return qsTr("AUR");
    case "flatpak":
        return qsTr("Flathub");
    }
    return "";
}

// A group of Installed (SR23).
function groupTitle(group) {
    switch (group) {
    case "arch":
        return qsTr("Arch Linux");
    case "omarchy":
        return qsTr("Omarchy");
    case "setup":
        return qsTr("Omarchy Setups");
    case "webapp":
        return qsTr("Web Apps");
    case "aur":
        return qsTr("AUR");
    case "flatpak":
        return qsTr("Flathub");
    case "foreign":
        return qsTr("Not from a Repository");
    }
    return "";
}

// The state line of Updates (SR24): an update running, a check asked, the last system update unfinished (S12), else what
// Software Update's last check says. `u`: StoreBackend::updates.
function updatesStatus(u) {
    if (!u)
        return qsTr("Software Update has not checked for updates yet.");
    if (u.running)
        return qsTr("Update in progress");
    if (u.checking)
        return qsTr("Checking for updates…");
    if (u.unfinished > 0)
        return qsTr("The last system update did not finish.");
    switch (u.state) {
    case "up-to-date":
        if ((u.count || 0) > 0)
            return u.checkedAt !== "" ? qsTr("Last checked %1.").arg(u.checkedAt) : "";
        return u.checkedAt !== "" ? qsTr("Your apps are up to date. Last checked %1.").arg(u.checkedAt) : qsTr("Your apps are up to date.");
    case "available":
        return u.checkedAt !== "" ? qsTr("Last checked %1.").arg(u.checkedAt) : "";
    case "update-running":
    case "busy":
        return qsTr("Update in progress");
    case "failed":
        return u.error === "offline" ? qsTr("Updates could not be checked: you're offline.") : qsTr("Updates could not be checked.");
    case "blocking":
        return qsTr("System updates are blocked. Software Update in Settings says why.");
    case "not-set-up":
    case "repair":
        return qsTr("Software Update is not set up. Settings can set it up.");
    }
    return u.askFailed ? qsTr("Software Update couldn't check for updates. Open it to check.") : qsTr("Software Update has not checked for updates yet.");
}

// What the system part of Updates offers (SR24, SD32): "update" (Update All… opens Software Update, which updates the whole
// system), "software" (Software Update… for what only it can do: blocked, not set up), or "" (nothing to update, or it runs).
function systemAction(u) {
    if (!u || u.running || u.checking)
        return "";
    if (u.unfinished > 0)
        return "update";
    if (u.state === "blocking" || u.state === "not-set-up" || u.state === "repair")
        return "software";
    const releases = (u.grassfield && u.grassfield.available) || (u.omarchy && u.omarchy.available);
    return (u.others || 0) > 0 || releases ? "update" : "";
}

// The Flatpak group's line (SR24): an update's plan while it reads each app's commit and access (SD33), Flathub's check while
// it runs, or why it could not answer.
function flatpakUpdatesLine(f) {
    if (!f || !f.on)
        return "";
    // One app: no count. More: "%1 of %2 apps", the noun plural in English and French whatever %1 (French: « %1 sur %2 apps »).
    if (f.planning && f.planning.total === 1)
        return qsTr("Checking what the update changes…");
    if (f.planning && f.planning.total > 1)
        return qsTr("Checking what the updates change: %1 of %2 apps…").arg(f.planning.done).arg(f.planning.total);
    if (f.state === "checking")
        return qsTr("Checking Flathub for updates…");
    if (f.state === "failed")
        return qsTr("Flathub's updates couldn't be checked. Check your connection to the internet, then try again.");
    if ((f.apps || []).length === 0 && (f.runtimes || 0) === 0)
        return qsTr("Your Flatpak apps are up to date.");
    if ((f.apps || []).length === 0)
        return f.runtimes === 1 ? qsTr("1 runtime has an update.") : qsTr("%1 runtimes have an update.").arg(f.runtimes);
    return "";
}

// The address a link shows: its host.
function hostOf(url) {
    const m = /^https:\/\/([^/?#]+)/.exec(url || "");
    return m ? m[1] : "";
}

// Why the Store has nothing to show (no catalog in use and no app data from Arch), in plain words: what is missing first,
// then what would bring it.
function unavailableReason(catalog, appData, online) {
    if (!online)
        return qsTr("You're offline, and this computer has no saved catalog or app data yet.");
    const parts = [];
    switch (catalog ? catalog.problem : "") {
    case "unconfigured":
        parts.push(qsTr("This version of Grassfield has no catalog host yet."));
        break;
    case "untrusted":
        parts.push(qsTr("The Grassfield catalog can't be verified: no trusted Grassfield key is installed yet."));
        break;
    case "refused":
        parts.push(qsTr("The Grassfield catalog could not be verified."));
        break;
    case "unavailable":
        parts.push(qsTr("The Grassfield catalog could not be fetched."));
        break;
    }
    if (appData && appData.problem === "download")
        parts.push(qsTr("Arch's app data couldn't be downloaded. Check for updates, then try again."));
    else if (appData && appData.problem === "unverified")
        parts.push(qsTr("Arch's app data could not be verified."));
    else if (!appData || appData.origin === "none")
        parts.push(qsTr("Arch's app data isn't installed and could not be fetched."));
    return parts.join(" ");
}
