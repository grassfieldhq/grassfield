import QtQuick
import QtTest
import Grassfield.Ui
import "store"

// Grassfield Store's Get, Open and Uninstall… (apps/store/qml; ADR-0037 step 3; spec SR13-SR22, SR30) with a fake backend:
// the confirmation sheet (checking, the plan, the refusals and Open Software Update), the button's states (Get, Open, the
// ring of a running or waiting operation, a waiting one leaving the queue), Uninstall… in the product page's menu and in an
// installed app's context menu with the reasons it is not offered, the queue in the toolbar, how an operation ended (Try
// Again, Details…), pacman's lock left behind, an app that could not be opened, and Ctrl+Q. Nothing installs or opens.
TestCase {
    id: testCase
    name: "StoreOperations"
    width: 800
    height: 600
    visible: true
    when: windowShown

    Component {
        id: fakeBackend
        FakeStoreBackend {}
    }

    function make(props) {
        const backend = fakeBackend.createObject(testCase);
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/store/qml/Main.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const win = createTemporaryObject(comp, testCase, Object.assign({backend: backend, globalMenu: false}, props || {}));
        verify(win);
        win.requestActivate();
        tryVerify(() => win.active, 2000, "the window is active");
        wait(50);
        tryVerify(() => win.page !== null);
        return {backend: backend, win: win};
    }

    // Items and the objects they hold (`data`: a Popup is not a child item), each visited once.
    function findAll(item, pred, out, seen) {
        out = out || [];
        seen = seen || [];
        if (!item || seen.indexOf(item) >= 0)
            return out;
        seen.push(item);
        // Items only (findPopup finds the menus): an attached Accessible on anything else warns.
        if (item.childrenRect !== undefined && pred(item))
            out.push(item);
        for (const k of item.data || item.children || [])
            findAll(k, pred, out, seen);
        if (item.contentItem && item.contentItem !== item)
            findAll(item.contentItem, pred, out, seen);
        return out;
    }

    function find(item, pred) {
        return findAll(item, pred)[0] || null;
    }

    // A MenuPopup (a Popup: not an item) held under `item`.
    function findPopup(item, pred, seen) {
        seen = seen || [];
        if (!item || seen.indexOf(item) >= 0)
            return null;
        seen.push(item);
        if (item.openAt !== undefined && item.closePolicy !== undefined && pred(item))
            return item;
        for (const k of item.data || item.children || []) {
            const hit = findPopup(k, pred, seen);
            if (hit)
                return hit;
        }
        return item.contentItem && item.contentItem !== item ? findPopup(item.contentItem, pred, seen) : null;
    }

    function sheet(t) {
        return find(t.win.contentItem, i => i.confirmEnabled !== undefined && i.plan !== undefined);
    }

    function textSheet(t) {
        return find(t.win.contentItem, i => i.confirmEnabled !== undefined && i.plan === undefined && i.text !== undefined && i.showCancel === false && i.title !== undefined);
    }

    function button(t, name) {
        return find(t.win.page, i => i.Accessible.role === Accessible.Button && i.Accessible.name === name);
    }

    function confirmButton(s) {
        return find(s, i => i.text === s.confirmText && i.primary !== undefined && i.destructive !== undefined && i !== s);
    }

    // Get: the sheet checks first (its button waits), then lists the plan; Install queues the operation and closes it.
    function test_getShowsThePlanThenInstalls() {
        const t = make({startPage: "app:org.example.Paint"});
        tryVerify(() => button(t, "Get Paint") !== null);
        mouseClick(button(t, "Get Paint"));
        const s = sheet(t);
        verify(s.visible);
        compare(s.title, "Install “Paint”?");
        compare(s.message, "Checking what this changes…");
        verify(!s.confirmEnabled, "Install waits for the plan");
        verify(t.backend.calls.indexOf("plan:install:org.example.Paint") >= 0);
        keyClick(Qt.Key_Return);
        verify(s.visible, "Return does nothing while it checks");
        t.backend.planReady("org.example.Paint", "install", {refusal: "", packages: [{name: "paint", version: "1-1", repo: "extra", size: "1.2 MB"},
            {name: "libbrush", version: "2-1", repo: "extra", size: "300 kB"}], download: "1.5 MB", installed: "6 MB", detail: ""});
        verify(s.confirmEnabled);
        compare(s.message, "These packages will be installed:");
        compare(s.confirmText, "Install");
        verify(!s.destructive);
        verify(!s.returnCancels, "Return installs a repository's package, as before");
        const list = find(s, i => i.Accessible.role === Accessible.List);
        tryCompare(list, "count", 2);
        compare(list.itemAtIndex(0).Accessible.name, "paint, 1-1, 1.2 MB");
        verify(find(s, i => i.text === "GPL-3.0-or-later") !== null, "the licence");
        verify(find(s, i => i.text === "6 MB") !== null, "the installed size");
        keyClick(Qt.Key_Return);
        verify(!s.visible);
        verify(t.backend.calls.indexOf("install:org.example.Paint") >= 0);
    }

    // Cancel (Esc) closes it and nothing runs (SR14).
    function test_cancelRunsNothing() {
        const t = make({startPage: "app:org.example.Paint"});
        tryVerify(() => button(t, "Get Paint") !== null);
        t.win.requestGet(t.backend.find("org.example.Paint"));
        const s = sheet(t);
        t.backend.planReady("org.example.Paint", "install", {refusal: "", packages: [{name: "paint", version: "1-1", repo: "extra", size: ""}]});
        keyClick(Qt.Key_Escape);
        verify(!s.visible);
        verify(t.backend.calls.indexOf("install:org.example.Paint") < 0);
    }

    // A plan that cannot run says why (SR15): the last update unfinished or an outdated system offer Software Update; the
    // locks and the others only OK.
    function test_refusals() {
        const t = make({startPage: "app:org.example.Paint"});
        const s = sheet(t);
        t.win.requestGet(t.backend.find("org.example.Paint"));
        t.backend.planReady("org.example.Paint", "install", {refusal: "unfinished", unfinished: ["linux 6.17-1 -> 6.18-1"], packages: []});
        compare(s.title, "Finish the system update first");
        compare(s.confirmText, "Update Now…");
        verify(s.showCancel);
        verify(find(s, i => i.text === "linux 6.17-1 -> 6.18-1") !== null, "pacman's line");
        s.confirm();
        verify(t.backend.calls.indexOf("openSoftwareUpdate") >= 0);
        verify(t.backend.calls.indexOf("install:org.example.Paint") < 0);

        t.win.requestGet(t.backend.find("org.example.Paint"));
        t.backend.planReady("org.example.Paint", "install", {refusal: "outdated", packages: [], upgrades: ["glib2"],
                            detail: "https://mirror.example/extra/paint-1-1-x86_64.pkg.tar.zst: HTTP 404"});
        compare(s.title, "Update your system first");
        verify(!find(s, i => i.text !== undefined && String(i.text).indexOf("HTTP 404") >= 0 && i.visible), "the mirror's answer stays in the log");
        // The system older than the mirror (the integrator's note on PR #36): plain words and one action, Software Update.
        compare(s.message, "Your system needs to be updated before you can install apps. Software Update brings it up to date; then get the app again.");
        compare(s.confirmText, "Update Now…");
        s.cancel();

        t.win.requestGet(t.backend.find("org.example.Paint"));
        t.backend.planReady("org.example.Paint", "install", {refusal: "busy", packages: []});
        compare(s.title, "Another installation or an update is running");
        compare(s.confirmText, "OK");
        verify(!s.showCancel);
        s.confirm();
        verify(t.backend.calls.indexOf("install:org.example.Paint") < 0);

        t.win.requestUninstall(t.backend.find("org.example.Photo"));
        t.backend.planReady("org.example.Photo", "remove", {refusal: "dependency", dependents: ["accountsservice", "gtk3"], packages: []});
        compare(s.title, "“Photo Lab” can't be uninstalled");
        compare(s.message, "Other apps need it: accountsservice, gtk3.");
        s.confirm();
        t.win.requestUninstall(t.backend.find("org.example.Photo"));
        t.backend.planReady("org.example.Photo", "remove", {refusal: "protected", protected: "efibootmgr", packages: []});
        compare(s.title, "Uninstalling it would also remove part of the system");
        verify(s.message.indexOf("efibootmgr") >= 0);
        s.confirm();
        verify(t.backend.calls.indexOf("uninstall:org.example.Photo") < 0);
    }

    // A web app: the sheet alone (owner ST3), no package list.
    function test_webAppSheet() {
        const t = make({startPage: "app:org.example.Mail"});
        const s = sheet(t);
        t.win.requestGet(t.backend.find("org.example.Mail"));
        t.backend.planReady("org.example.Mail", "install", {refusal: "", packages: []});
        compare(s.message, "A launcher that opens mail.example.com in your browser is added to Apps, with its icon.");
        compare(findAll(s, i => i.Accessible.role === Accessible.ListItem).length, 0);
        s.confirm();
        verify(t.backend.calls.indexOf("install:org.example.Mail") >= 0);
    }

    // An Omarchy setup (ADR-0037 b.2): what it changes (our catalog's text), the recipe Omarchy's terminal runs and its password
    // prompt, the packages; its removal names the files the recipe deletes; a setup the installed Omarchy no longer matches
    // says so.
    function test_setupSheet() {
        const t = make({startPage: "app:org.example.Games"});
        const s = sheet(t);
        t.win.requestGet(t.backend.find("org.example.Games"));
        t.backend.planReady("org.example.Games", "install", {refusal: "", packages: [{name: "gamehub", version: "1-1", repo: "multilib", size: "4 MB"}],
            download: "4 MB", installed: "12 MB", detail: ""});
        compare(s.title, "Install “Game Hub”?");
        compare(s.message, "Installs Game Hub and the 32-bit graphics drivers for your graphics card.\n\n"
                + "Omarchy's “omarchy-install-gaming-hub” runs in a Terminal window, which asks for your password.\n\n"
                + "These packages will be installed:");
        compare(s.confirmText, "Install");
        tryCompare(find(s, i => i.Accessible.role === Accessible.List), "count", 1);
        verify(find(s, i => i.text === "Omarchy setup") !== null, "the source");
        s.confirm();
        verify(t.backend.calls.indexOf("install:org.example.Games") >= 0);

        t.win.requestUninstall(t.backend.find("org.example.Games"));
        t.backend.planReady("org.example.Games", "remove", {refusal: "", packages: [{name: "gamehub", version: "1-1", repo: "", size: ""}]});
        compare(s.title, "Uninstall “Game Hub”?");
        compare(s.message, "Omarchy's “omarchy-remove-gaming-hub” runs in a Terminal window, which asks for your password.\n\n"
                + "It also deletes: Game Hub's folders in your home folder, with the games.\n\n"
                + "These packages will be removed:");
        verify(s.destructive);
        s.close();

        t.win.requestGet(t.backend.find("org.example.Games"));
        t.backend.planReady("org.example.Games", "install", {refusal: "omarchyChanged", packages: [], detail: "install/helpers/gpu.sh"});
        compare(s.title, "“Game Hub” can't be installed now");
        compare(s.message, "This setup hasn't been checked with your version of Omarchy yet. The Store offers it again once its catalog has been.");
        compare(s.confirmText, "OK");
        verify(find(s, i => i.text === "install/helpers/gpu.sh") !== null, "the file that differs, for whoever checks");
        s.close();
    }

    // The AUR's sheet (SR14, SR16): the warning every time, what yay builds (marked AUR) and what pacman adds, its button
    // "Install from the AUR"; a plan the AUR cannot complete says so; its refusals.
    function test_aurSheet() {
        const t = make({startPage: "app:aur:example-app-bin"});
        const s = sheet(t);
        const app = t.backend.find("aur:example-app-bin");
        t.win.requestGet(app);
        t.backend.planReady("aur:example-app-bin", "install", {refusal: "", built: [{name: "example-app-bin", version: "2.4.1-1", repo: "aur", size: ""},
            {name: "example-lib", version: "1.3-2", repo: "aur", size: ""}], packages: [{name: "gtk3", version: "1:3.24.50-1", repo: "extra", size: "7 MB"}],
            download: "7 MB", installed: "", incomplete: false, detail: ""});
        compare(s.title, "Install “example-app-bin”?");
        compare(s.message, "AUR packages are made by users and reviewed by no one, neither Arch Linux nor Grassfield. Their build script runs on "
                + "this computer and the package is then installed with administrator rights. Install only what you trust.\n\n"
                + "The packages marked AUR are built on this computer in a Terminal window, which asks for your password.\n\n"
                + "These packages will be installed:");
        compare(s.confirmText, "Install from the AUR");
        const list = find(s, i => i.Accessible.role === Accessible.List);
        tryCompare(list, "count", 3);
        tryVerify(() => list.itemAtIndex(0) !== null && list.itemAtIndex(2) !== null);
        compare(list.itemAtIndex(0).Accessible.name, "example-app-bin, 2.4.1-1, AUR");
        compare(list.itemAtIndex(2).Accessible.name, "gtk3, 1:3.24.50-1, 7 MB");
        // Its long label takes a second line rather than running into its value (seen in the step-3b2 captures).
        const label = find(s, i => i.text === "Download from the repositories");
        verify(label !== null);
        verify(label.contentWidth <= label.width, "the label stays in its column: " + label.contentWidth + " > " + label.width);
        // Cancel is the default (common rule 3: the build runs the package's script before any password): Return closes the
        // sheet and nothing is queued; "Install from the AUR" takes a click, or Tab and Space.
        verify(s.returnCancels);
        keyClick(Qt.Key_Return);
        verify(!s.visible);
        verify(t.backend.calls.indexOf("install:aur:example-app-bin") < 0, "Return installed nothing");
        t.win.requestGet(app);
        t.backend.planReady("aur:example-app-bin", "install", {refusal: "", built: [{name: "example-app-bin", version: "2.4.1-1", repo: "aur", size: ""}],
            packages: [], download: "", installed: "", incomplete: false, detail: ""});
        const install = find(s, i => i.text === "Install from the AUR" && i.visible);
        verify(install !== null);
        install.clicked();
        verify(!s.visible);
        verify(t.backend.calls.indexOf("install:aur:example-app-bin") >= 0);

        t.win.requestGet(app);
        t.backend.planReady("aur:example-app-bin", "install", {refusal: "", built: [{name: "example-app-bin", version: "2.4.1-1", repo: "aur", size: ""}],
            packages: [], incomplete: true});
        verify(s.message.indexOf("Some of what the AUR lists for it could not be read: the build may install more than this.") >= 0);
        s.close();
        for (const c of [["repository", "", "“example-app-bin” is in a repository", "A repository has this package, or one that provides it: the Store installs it from there, without building it."],
                         ["notOnAur", "python-pytest", "“example-app-bin” can't be installed now", "It needs python-pytest, which neither the repositories nor the AUR have."],
                         ["omarchyChanged", "bin/omarchy-pkg-aur-add", "“example-app-bin” can't be installed now",
                          "Installing from the AUR hasn't been checked with your version of Omarchy yet. The Store offers it again once its catalog has been."]]) {
            t.win.requestGet(app);
            t.backend.planReady("aur:example-app-bin", "install", {refusal: c[0], packages: [], detail: c[1]});
            compare(s.title, c[2]);
            compare(s.message, c[3]);
            compare(s.confirmText, "OK");
            s.close();
        }
        // A dependency the AUR would build under a name of the deny list (the integrator's note on PR #36).
        t.win.requestGet(app);
        t.backend.planReady("aur:example-app-bin", "install", {refusal: "protected", protected: "omarchy-example-lib", packages: [], detail: ""});
        compare(s.title, "“example-app-bin” can't be installed from the AUR");
        compare(s.message, "It would build omarchy-example-lib from the AUR, a name the system, Omarchy or Grassfield uses. The Store doesn't install it.");
        compare(s.confirmText, "OK");
        s.close();
        t.win.requestUninstall(Object.assign({}, app, {installed: true}));
        t.backend.planReady("aur:example-app-bin", "remove", {refusal: "", packages: [{name: "example-app-bin", version: "2.4.1-1", repo: "", size: ""}]});
        compare(s.message, "It is removed in a Terminal window, which asks for your password.\n\nThese packages will be removed. Your files and settings stay.");
        compare(s.confirmText, "Uninstall");
        s.close();
    }

    // A Flatpak's sheet (SD25, SD27): no password, what it can reach, flatpak's own plan with each ref's most; its removal
    // keeps its data and takes the runtimes no other app needs.
    function test_flatpakSheet() {
        const t = make({startPage: "app:org.example.Notes"});
        const s = sheet(t);
        const app = t.backend.find("org.example.Notes");
        t.win.requestGet(app);
        verify(t.backend.calls.indexOf("plan:install:org.example.Notes") >= 0);
        t.backend.planReady("org.example.Notes", "install", {refusal: "", packages: [{name: "org.gnome.Platform", version: "50", repo: "flathub", size: "418.8 MB"},
            {name: "org.example.Notes", version: "stable", repo: "flathub", size: "1.5 MB"}], download: "420.3 MB", installed: "", access: ["network", "home"], detail: "",
            permissions: [{key: "network", name: "", level: 1, detail: ""}, {key: "home", name: "~", level: 2, detail: ""}]});
        compare(s.title, "Install “Notes”?");
        compare(s.message, "It's installed in your own folder, for you alone, without administrator rights.\n\nIt can reach:\n"
                + "Files and Folders\nNetwork\n\nTake care:\nIt can read and change everything in your home folder, including other apps' data and settings.\n\nIts page lists each one.\n\nThese will be installed:");
        compare(s.confirmText, "Install");
        verify(!s.returnCancels, "the user's own folder, nothing built: Install is the default");
        verify(find(s, i => i.text === "Download, at most" && i.visible) !== null);
        verify(find(s, i => i.text === "420.3 MB" && i.visible) !== null);
        verify(find(s, i => i.text === "Installed size" && i.visible) === null, "flatpak's plan gives no installed size");
        const list = find(s, i => i.Accessible.role === Accessible.List);
        tryCompare(list, "count", 2);
        tryVerify(() => list.itemAtIndex(0) !== null);
        compare(list.itemAtIndex(0).Accessible.name, "org.gnome.Platform, 50, 418.8 MB");
        keyClick(Qt.Key_Return);
        verify(!s.visible);
        verify(t.backend.calls.indexOf("install:org.example.Notes") >= 0);

        t.win.requestGet(app);
        t.backend.planReady("org.example.Notes", "install", {refusal: "", packages: [{name: "org.example.Notes", version: "stable", repo: "flathub", size: "1.5 MB"}],
            download: "1.5 MB", access: [], permissions: []});
        verify(s.message.indexOf("It can reach only its own window and files.") >= 0, s.message);
        s.close();
        // A grant the window does not know is still said; what it can reach unread: no claim at all (PR #58).
        t.win.requestGet(app);
        t.backend.planReady("org.example.Notes", "install", {refusal: "", packages: [{name: "org.example.Notes", version: "stable", repo: "flathub", size: "1.5 MB"}],
            download: "1.5 MB", access: ["outside", "sessionService:org.freedesktop.systemd1", "other:devices=tpm"],
            permissions: [{key: "outside", name: "", level: 1, detail: ""}, {key: "sessionService", name: "org.freedesktop.systemd1", level: 1, detail: ""},
                          {key: "other", name: "devices=tpm", level: 1, detail: ""}]});
        verify(s.message.indexOf("It can reach:\nOther Apps and Services\nOutside Its Sandbox\nOther\n\n") >= 0, s.message);
        // The warnings are on the sheet, each once, on their own lines (finding 10: they had been left out).
        verify(s.message.indexOf("Take care:\nAnything it starts this way has all of your access.\n\n") >= 0, s.message);
        s.close();
        t.win.requestGet(app);
        t.backend.planReady("org.example.Notes", "install", {refusal: "", packages: [{name: "org.example.Notes", version: "stable", repo: "flathub", size: "1.5 MB"}],
            download: "1.5 MB"});
        verify(s.message.indexOf("It can reach") < 0, s.message);
        verify(s.message.indexOf("These will be installed:") >= 0, s.message);
        s.close();
        // flatpak could not give its plan: its own words, no Install.
        t.win.requestGet(app);
        t.backend.planReady("org.example.Notes", "install", {refusal: "failed", packages: [], detail: "error: No remote refs found for org.example.Notes"});
        compare(s.title, "“Notes” can't be installed now");
        verify(find(s, i => i.text === "error: No remote refs found for org.example.Notes" && i.visible) !== null);
        compare(s.confirmText, "OK");
        s.close();

        t.win.requestUninstall(Object.assign({}, app, {installed: true}));
        t.backend.planReady("org.example.Notes", "remove", {refusal: "", packages: [{name: "org.example.Notes", version: "", repo: "flathub", size: ""}]});
        compare(s.title, "Uninstall “Notes”?");
        compare(s.message, "Its data in ~/.var/app/org.example.Notes stays. Runtimes no other app needs are removed too.");
        compare(s.confirmText, "Uninstall");
        verify(s.destructive);
        keyClick(Qt.Key_Return);
        verify(t.backend.calls.indexOf("uninstall:org.example.Notes") >= 0);
    }

    // A Flatpak install that runs can stop (SD26): the ring's square, and the queue's menu.
    function test_flatpakStop() {
        const t = make({startPage: "app:org.example.Notes"});
        tryVerify(() => button(t, "Get Notes") !== null);
        t.backend.operations = [{id: "op5", app: "org.example.Notes", name: "Notes", kind: "install", path: "flatpak", state: "running", blocked: false,
                                 done: 1, total: 3, stoppable: true}];
        const ring = find(t.win.page, i => i.stop !== undefined && i.indeterminate !== undefined && i.visible);
        verify(ring);
        verify(ring.stop);
        compare(ring.value, 1 / 3);
        compare(ring.Accessible.name, "Stop installing Notes");
        compare(ring.Accessible.description, "Installing: 1 of 3");
        const queue = find(t.win.contentItem, i => i.accessibleName !== undefined && i.iconName === "arrow-down-circle");
        queue.clicked();
        const menu = findPopup(t.win.contentItem, p => p.accessibleName === "Installations");
        verify(menu);
        tryVerify(() => menu.opened);
        verify(menu.items.some(i => i.id === "stop:op5" && i.text === "Stop Installing “Notes”"), JSON.stringify(menu.items));
        menu.close();
        mouseClick(ring);
        verify(t.backend.calls.indexOf("stop:op5") >= 0);
        verify(t.backend.calls.indexOf("removeWaiting:op5") < 0, "a running one is stopped, not taken out of the queue");
        // Once asked to stop, it cannot be asked again: a plain ring.
        t.backend.operations = [{id: "op5", app: "org.example.Notes", name: "Notes", kind: "install", path: "flatpak", state: "running", blocked: false,
                                 done: 1, total: 3, stoppable: false}];
        verify(!find(t.win.page, i => i.stop !== undefined && i.indeterminate !== undefined && i.visible).stop);
    }

    // The button (SR13, SR18): Open opens; while its operation runs, a ring with its count; a waiting one shows a square
    // that takes it out of the queue; the queue's button in the toolbar.
    function test_buttonStatesAndQueue() {
        const t = make({startPage: "app:org.example.Photo"});
        tryVerify(() => button(t, "Open Photo Lab") !== null);
        mouseClick(button(t, "Open Photo Lab"));
        compare(t.backend.opened, ["org.example.Photo"]);
        t.backend.openWorks = false;
        mouseClick(button(t, "Open Photo Lab"));
        const notice = find(t.win.contentItem, i => i.objectName === "operationNotice");
        compare(notice.text, "“Photo Lab” could not be opened.");

        const queue = find(t.win.contentItem, i => i.accessibleName !== undefined && i.iconName === "arrow-down-circle");
        verify(queue);
        verify(!queue.visible);
        t.win.openPage("app:org.example.Paint");
        tryVerify(() => button(t, "Get Paint") !== null);
        t.backend.operations = [{id: "op0", app: "org.example.Photo", name: "Photo Lab", kind: "remove", state: "running", blocked: false, done: 0, total: 1},
                                {id: "op1", app: "org.example.Paint", name: "Paint", kind: "install", state: "waiting", blocked: false, done: 0, total: 3}];
        verify(queue.visible);
        verify(button(t, "Get Paint") === null || !button(t, "Get Paint").visible, "the ring in the button's place");
        const ring = find(t.win.page, i => i.stop !== undefined && i.indeterminate !== undefined && i.visible);
        verify(ring);
        verify(ring.stop);
        compare(ring.Accessible.name, "Remove Paint from the queue");
        compare(ring.Accessible.description, "Waiting");
        mouseClick(ring);
        verify(t.backend.calls.indexOf("removeWaiting:op1") >= 0);

        t.backend.operations = [{id: "op2", app: "org.example.Paint", name: "Paint", kind: "install", state: "running", blocked: false, done: 2, total: 4}];
        const running = find(t.win.page, i => i.stop !== undefined && i.indeterminate !== undefined && i.visible);
        verify(!running.stop);
        verify(!running.indeterminate);
        compare(running.value, 0.5);
        compare(running.Accessible.description, "Installing: 2 of 4");
        t.backend.operations = [{id: "op2", app: "org.example.Paint", name: "Paint", kind: "install", state: "authorizing", blocked: false, done: 0, total: 4}];
        compare(find(t.win.page, i => i.stop !== undefined && i.visible).Accessible.description, "Waiting for permission…");
    }

    // A hand-over ("--page=uninstall:<entry>", from the launcher or Files, or any D-Bus peer: ADR-0046 D1) only OPENS the Store's own
    // alert: the Store's name and the packages -Rns takes, Delete, Cancel the default. Nothing is removed until Delete is pressed
    // here: Return and Escape cancel, and no path of the hand-over calls uninstall.
    function test_handOverOnlyOpensTheAlert() {
        const t = make({});
        const uninstalled = () => t.backend.calls.filter(c => c.startsWith("uninstall:")).length;
        t.win.openPage("uninstall:photo.desktop");
        const s = sheet(t);
        verify(s.visible, "the alert is shown at once, before any plan");
        verify(!s.confirmEnabled, "Delete waits for the plan");
        compare(uninstalled(), 0);
        t.backend.planReady("org.example.Photo", "remove", {refusal: "", packages: [{name: "photolab", version: "3-1", repo: "", size: ""},
                                                                                   {name: "photolab-data", version: "3-1", repo: "", size: ""}]});
        compare(s.title, "Delete “Photo Lab”?", "the Store's own name for the app");
        compare(s.confirmText, "Delete");
        verify(s.handedOver && s.destructive && s.returnCancels, "Cancel is the default");
        compare(s.packages.length, 2, "the packages -Rns takes are listed");
        compare(uninstalled(), 0, "a plan with nothing to ask runs nothing either");
        keyClick(Qt.Key_Return);
        verify(!s.visible, "Return cancels");
        compare(uninstalled(), 0);
        t.win.openPage("uninstall:photo.desktop");
        t.backend.planReady("org.example.Photo", "remove", {refusal: "", packages: [{name: "photolab", version: "3-1", repo: "", size: ""}]});
        verify(s.visible);
        keyClick(Qt.Key_Escape);
        verify(!s.visible, "Escape cancels");
        compare(uninstalled(), 0);
        t.win.openPage("uninstall:photo.desktop");
        t.backend.planReady("org.example.Photo", "remove", {refusal: "", packages: [{name: "photolab", version: "3-1", repo: "", size: ""}]});
        s.cancel();
        compare(uninstalled(), 0, "Cancel removes nothing");
        t.win.openPage("uninstall:photo.desktop");
        t.backend.planReady("org.example.Photo", "remove", {refusal: "", packages: [{name: "photolab", version: "3-1", repo: "", size: ""}]});
        s.confirm();
        compare(uninstalled(), 1, "only Delete in the Store removes it");
        verify(t.backend.calls.indexOf("uninstall:org.example.Photo") >= 0);
    }

    // A hand-over while an alert is open is ignored: the alert for X keeps X (Delete cannot end up removing Y), and Y's plan is
    // not even asked for.
    function test_handOverWhileTheSheetIsOpenKeepsItsApp() {
        const t = make({});
        t.backend.entries = {"photo.desktop": "org.example.Photo", "paint.desktop": "org.example.Paint"};
        t.win.openPage("uninstall:photo.desktop");
        const s = sheet(t);
        verify(s.visible);
        compare(s.app.id, "org.example.Photo");
        t.win.openPage("uninstall:paint.desktop");
        compare(s.app.id, "org.example.Photo", "the open alert keeps its app");
        verify(t.backend.calls.indexOf("plan:remove:org.example.Paint") < 0, "the second app's plan is never asked for");
        t.backend.planReady("org.example.Photo", "remove", {refusal: "", packages: [{name: "photolab", version: "3-1", repo: "", size: ""}]});
        compare(s.title, "Delete “Photo Lab”?");
        s.confirm();
        verify(t.backend.calls.indexOf("uninstall:org.example.Photo") >= 0);
        verify(t.backend.calls.indexOf("uninstall:org.example.Paint") < 0, "Delete removed X, never Y");
        // Once answered, the next hand-over opens its own alert.
        t.win.openPage("uninstall:paint.desktop");
        compare(s.app.id, "org.example.Paint");
        s.cancel();
    }

    // An entry the Store does not know, or a refusal: no alert to confirm, nothing runs.
    function test_handOverOfAnUnknownEntryRunsNothing() {
        const t = make({});
        t.win.openPage("uninstall:nothing.desktop");
        verify(!sheet(t).visible, "no sheet for an app the Store does not know");
        compare(t.win.transientNotice, "The Store can't uninstall this app.");
        verify(t.backend.calls.filter(c => c.startsWith("uninstall:")).length === 0);
        t.win.openPage("uninstall:photo.desktop");
        t.backend.planReady("org.example.Photo", "remove", {refusal: "protected", packages: [], protected: "glib2"});
        const s = sheet(t);
        verify(s.visible, "the refusal is said");
        compare(s.confirmText, "OK");
        s.confirm();
        verify(t.backend.calls.filter(c => c.startsWith("uninstall:")).length === 0, "OK on a refusal removes nothing");
    }

    // A hand-over's wording never leaks into another operation of the sheet (the product page's Uninstall…, an install, an update).
    function test_handOverStateDoesNotLeak() {
        const t = make({startPage: "app:org.example.Photo"});
        t.win.openPage("uninstall:photo.desktop");
        const s = sheet(t);
        verify(s.handedOver);
        t.win.requestUninstall(t.backend.find("org.example.Photo"));
        verify(!s.handedOver, "the product page's Uninstall… is its own alert");
        t.backend.planReady("org.example.Photo", "remove", {refusal: "", packages: [{name: "photolab", version: "3-1", repo: "", size: ""}]});
        compare(s.title, "Uninstall “Photo Lab”?");
        compare(s.confirmText, "Uninstall");
        s.cancel();
        t.win.openPage("uninstall:photo.desktop");
        verify(s.handedOver);
        t.win.requestGet(t.backend.find("org.example.Paint"));
        verify(!s.handedOver);
        compare(s.kind, "install");
        s.cancel();
    }

    // Uninstall… (SR22): in the product page's menu when the Store may remove the app, with the reason otherwise.
    function test_uninstallFromTheProductPage() {
        const t = make({startPage: "app:org.example.Photo"});
        const more = find(t.win.page, i => i.Accessible.role === Accessible.ButtonMenu && i.visible);
        verify(more, "the … button of an installed app");
        compare(more.Accessible.name, "More for Photo Lab");
        more.openMenu();
        const menu = findPopup(t.win.page, i => i.app === undefined);
        tryVerify(() => menu.opened);
        compare(menu.items[0].text, "Uninstall…");
        verify(menu.items[0].enabled);
        menu.chosen("uninstall");
        const s = sheet(t);
        verify(s.visible);
        t.backend.planReady("org.example.Photo", "remove", {refusal: "", packages: [{name: "photolab", version: "3-1", repo: "", size: ""}]});
        compare(s.title, "Uninstall “Photo Lab”?");
        compare(s.confirmText, "Uninstall");
        verify(s.destructive);
        s.confirm();
        verify(t.backend.calls.indexOf("uninstall:org.example.Photo") >= 0);
        menu.close();

        t.backend.blocks = {"org.example.Photo": {uninstall: "omarchy"}};
        t.backend.revision++;
        verify(find(t.win.page, i => i.text === "Part of Omarchy" && i.visible) !== null);
        more.openMenu();
        verify(!menu.items[0].enabled);
        menu.close();
    }

    // The context menu of an installed app's item in Installed (SR22, SR23): Open, Show in Store, Uninstall….
    function test_contextMenu() {
        const t = make();
        t.win.openInstalled();
        tryVerify(() => t.win.pageKind === "installed");
        const lockup = find(t.win.page, i => i.app !== undefined && i.opened !== undefined && i.app.id === "org.example.Photo");
        verify(lockup);
        mouseClick(lockup, 10, 10, Qt.RightButton);
        const menu = findPopup(t.win.contentItem, i => i.app !== undefined);
        tryVerify(() => menu.opened);
        compare(menu.items.filter(i => !i.separator).map(i => i.text), ["Open", "Show in Store", "Uninstall…"]);
        menu.chosen("open");
        compare(t.backend.opened, ["org.example.Photo"]);
        menu.close();
        // A web app our catalog does not list: Open and Uninstall…, no page.
        const notes = find(t.win.page, i => i.app !== undefined && i.opened !== undefined && i.app.id === "webapp:Notes");
        mouseClick(notes, 10, 10, Qt.RightButton);
        tryVerify(() => menu.opened);
        compare(menu.items.filter(i => !i.separator).map(i => i.text), ["Open", "Uninstall…"]);
        menu.chosen("uninstall");
        verify(t.backend.calls.indexOf("plan:remove:webapp:Notes") >= 0);
        menu.close();
    }

    // How an operation ended (SR19, SR20): a line with Try Again and Details…; pacman's lock left behind, with Arch's way.
    function test_resultsAndLock() {
        const t = make();
        const notice = find(t.win.contentItem, i => i.objectName === "operationNotice");
        verify(!notice.visible);
        t.backend.results = {"org.example.Paint": {kind: "install", name: "Paint", outcome: "interrupted", present: 15, total: 110,
                             details: "error: failed to commit transaction (conflicting files)"}};
        compare(notice.text, "“Paint”: The installation was interrupted: 15 of 110 packages were installed.");
        compare(notice.actions.map(a => a.text), ["Try Again", "Details…", "Close"]);
        notice.acted("details");
        const details = textSheet(t);
        verify(details && details.visible);
        compare(details.text, "error: failed to commit transaction (conflicting files)");
        details.confirm();
        notice.acted("again");
        verify(t.backend.calls.indexOf("dismiss:org.example.Paint") >= 0);
        verify(t.backend.calls.indexOf("plan:install:org.example.Paint") >= 0);
        verify(sheet(t).visible);
        sheet(t).cancel();

        t.backend.results = {"org.example.Paint": {kind: "install", name: "Paint", outcome: "cancelled", present: 0, total: 1, details: ""}};
        verify(!notice.visible, "a cancelled request says nothing");
        t.backend.results = {};
        t.backend.staleLock = true;
        compare(notice.text, "A package manager stopped mid-way and left its lock: nothing installs until it goes.");
        notice.acted("lock");
        compare(details.text, "sudo rm /var/lib/pacman/db.lck");
        verify(details.message.indexOf("no pacman is running") >= 0);
        details.confirm();
    }

    // A system older than the mirror (a plan refused before anything downloaded, or a file the mirror no longer had: the
    // integrator's note on PR #36): plain words and "Update Now…", which opens Software Update; pacman's output is never
    // shown (no Details…), and no Try Again before the update.
    function test_outdatedSaysUpdateNow() {
        const t = make();
        const notice = find(t.win.contentItem, i => i.objectName === "operationNotice");
        t.backend.results = {"org.example.Paint": {kind: "install", name: "Paint", outcome: "outdated", present: 0, total: 3,
                             details: "error: failed retrieving file 'paint-1-1-x86_64.pkg.tar.zst' from mirror.example : The requested URL returned error: 404"}};
        tryVerify(() => notice.visible);
        compare(notice.text, "“Paint”: Your system needs to be updated before you can install apps.");
        compare(notice.actions.map(a => a.text), ["Update Now…", "Close"]);
        notice.acted("update");
        verify(t.backend.calls.indexOf("openSoftwareUpdate") >= 0);
        verify(t.backend.calls.indexOf("dismiss:org.example.Paint") >= 0);

        t.backend.results = {"org.example.Paint": {kind: "install", name: "Paint", outcome: "outdated", present: 0, total: 3, details: "error: 404"}};
        t.win.openPage("app:org.example.Paint");
        tryVerify(() => find(t.win.page, i => i.text === "Your system needs to be updated before you can install apps." && i.visible) !== null);
        const update = find(t.win.page, i => i.text === "Update Now…" && i.activated !== undefined && i.visible);
        verify(update);
        verify(!find(t.win.page, i => i.text === "Details…" && i.visible), "pacman's output stays in the log");
        verify(!find(t.win.page, i => i.text === "Try Again" && i.visible));
        const before = t.backend.calls.filter(c => c === "openSoftwareUpdate").length;
        update.activated();
        compare(t.backend.calls.filter(c => c === "openSoftwareUpdate").length, before + 1);
    }

    // The product page says how its last operation ended, with Try Again and Details…; the line at the bottom is for the
    // other pages (not twice on the app's own).
    function test_resultOnTheProductPage() {
        const t = make({startPage: "app:org.example.Paint"});
        const notice = find(t.win.contentItem, i => i.objectName === "operationNotice");
        t.backend.results = {"org.example.Paint": {kind: "install", name: "Paint", outcome: "failed", present: 0, total: 1, details: "error"}};
        tryVerify(() => find(t.win.page, i => i.text === "The installation failed." && i.visible) !== null);
        verify(!notice.visible, "the app's own page has the line under its button");
        t.win.openPage("categories");
        tryVerify(() => notice.visible);
        compare(notice.text, "“Paint”: The installation failed.");
        t.win.openPage("app:org.example.Paint");
        tryVerify(() => find(t.win.page, i => i.text === "Try Again" && i.activated !== undefined) !== null);
        verify(!notice.visible);
        const again = find(t.win.page, i => i.text === "Try Again" && i.activated !== undefined);
        again.activated();
        verify(sheet(t).visible);
        sheet(t).cancel();
    }

    // Ctrl+Q: the backend quits once the running operation ended (ADR-0037 f).
    function test_quitWaitsForTheOperation() {
        const t = make();
        keyClick(Qt.Key_Q, Qt.ControlModifier);
        verify(t.backend.calls.indexOf("quitWhenIdle") >= 0);
    }
}
