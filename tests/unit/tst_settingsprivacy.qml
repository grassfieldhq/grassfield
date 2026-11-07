import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Privacy.js" as Privacy
import "../../apps/settings/qml" as SettingsQml

// Settings > Privacy & Security (ADR-0030, the portal permission store): the state as Privacy.js checks it, the actions it
// builds, the hub's counts, a category's switches, the saved selections forgotten one action each, and the dev guard. The
// backend is a fake: nothing reaches a bus.
TestCase {
    id: testCase
    name: "SettingsPrivacy"
    width: 700
    height: 900
    visible: true
    when: windowShown

    readonly property string tokenA: "00000000-1111-2222-3333-444444444444"
    // The portal's current tokens: base64 with + and / made _, so some begin with _.
    readonly property string tokenB: "_0000_fake_0000_0000_"
    readonly property var stateJson: ({
            location: [{app: "org.example.Maps", allowed: true}, {app: "org.example.Weather", allowed: false}, {app: "org.example.Studio", allowed: false},
                {app: "org.example.Ghost", allowed: false}],
            background: [],
            camera: [{app: "org.example.Meet", allowed: true}, {app: "org.example.Booth", allowed: false}],
            remoteDesktop: [],
            screencast: [{app: "org.example.Meet", token: testCase.tokenA}, {app: "org.example.Meet", token: testCase.tokenB},
                {app: "org.example.Studio", token: testCase.tokenA}],
            // The desktop portal exports Background, not RemoteDesktop.
            portals: {background: true, remoteDesktop: false}
        })

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: false
            property var busQueries: []
            property var busActions: []
            // The user's folder first, as XDG_DATA_HOME comes first.
            property var applicationDirs: ["/apps", "/home/u/.local/share/flatpak/exports/share/applications"]
            // Booth and Weather are the host's (their entries in a plain applications folder only); Studio a Flatpak with the
            // user's own copy of its entry; Ghost only a hidden stub (not known to be the host's); the others are shown by
            // their id.
            property var files: ({
                    "/apps/org.example.Booth.desktop": "[Desktop Entry]\nType=Application\nName=Booth Camera\nIcon=booth\n",
                    "/apps/org.example.Weather.desktop": "[Desktop Entry]\nType=Application\nName=Weather\n",
                    "/apps/org.example.Studio.desktop": "[Desktop Entry]\nType=Application\nName=My Studio\n",
                    "/apps/org.example.Ghost.desktop": "[Desktop Entry]\nType=Application\nName=Ghost\nHidden=true\n",
                    "/home/u/.local/share/flatpak/exports/share/applications/org.example.Studio.desktop": "[Desktop Entry]\nType=Application\nName=Studio\n"
                })
            // Entries that are there but cannot be read.
            property var unreadable: []
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            // ADR-0045: a command on PATH (none here) and Omarchy's read-only checks (recorded nowhere: no answer comes).
            function hasCommand(name: string): bool {
                return false;
            }
            function readOnlyQuery(argv: var, tag: string): void {
            }
            function readText(path: string): var {
                if (unreadable.indexOf(path) >= 0)
                    return {exists: true, ok: false, text: ""};
                return {exists: files[path] !== undefined, ok: files[path] !== undefined, text: files[path] ?? ""};
            }
            function busQuery(what: string, tag: string): void {
                busQueries.push({what: what, tag: tag});
            }
            function busAct(what: string, op: var, tag: string): bool {
                busActions.push({what: what, op: op, tag: tag});
                return true;
            }
        }
    }

    Component {
        id: serviceComp
        SettingsQml.SystemService {}
    }

    Component {
        id: hubComp
        SettingsQml.PrivacyPage {
            anchors.fill: parent
        }
    }

    Component {
        id: categoryComp
        SettingsQml.PrivacyCategoryPage {
            anchors.fill: parent
        }
    }

    function make(comp, props, dev) {
        const backend = createTemporaryObject(fakeBackend, testCase, {devSession: dev === true});
        const system = createTemporaryObject(serviceComp, testCase, {backend: backend});
        const page = createTemporaryObject(comp, testCase, Object.assign({backend: backend, system: system}, props || {}));
        verify(page);
        return {backend: backend, system: system, page: page};
    }

    function answer(t, json) {
        // The store's state is the last query of the permissions (the hub also asks UDisks2 for Disk Encryption, ADR-0045).
        const store = t.backend.busQueries.filter(q => q.what !== "disk.state");
        compare(store[store.length - 1], {what: "privacy.state", tag: "privacy.state"});
        t.backend.finished("privacy.state", true, JSON.stringify(json === undefined ? testCase.stateJson : json));
    }

    function find(item, pred) {
        if (!item)
            return null;
        if (pred(item))
            return item;
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++) {
            const hit = find(kids[i], pred);
            if (hit)
                return hit;
        }
        if (item.contentItem && item.contentItem !== item) {
            const hit = find(item.contentItem, pred);
            if (hit)
                return hit;
        }
        return null;
    }

    function row(page, text) {
        return find(page, i => i.text === text && i.subtitle !== undefined);
    }

    function test_parse() {
        const s = Privacy.parse(JSON.stringify({
            location: [{app: "org.example.Maps", allowed: true}, {app: "../x", allowed: true}, {app: "org.example.A", allowed: "yes"}, null],
            camera: "nope",
            screencast: [{app: "org.example.Meet", token: testCase.tokenA}, {app: "org.example.Meet", token: testCase.tokenB},
                {app: "org.example.Meet", token: testCase.tokenA}, {app: "org.example.Bad", token: "a b"}]
        }));
        compare(s.location, [{app: "org.example.Maps", allowed: true}], "a path, a value that is not a boolean and null are dropped");
        compare(s.camera, []);
        compare(s.background, []);
        compare(s.remoteDesktop, [], "every key is there");
        compare(s.screencast, [{app: "org.example.Meet", tokens: [testCase.tokenA, testCase.tokenB]}], "one entry per app, a token once");
        compare(s.portals, {}, "not known: left out");
        compare(Privacy.parse(JSON.stringify({portals: {background: false, remoteDesktop: "no"}})).portals, {background: false}, "only booleans");
        verify(Privacy.portalMissing(Privacy.parse(JSON.stringify({portals: {remoteDesktop: false}})), "remoteDesktop"));
        verify(!Privacy.portalMissing(s, "remoteDesktop"), "unknown is not missing");
        compare(Privacy.parse("not json").location, []);
        compare(Privacy.parse("null").screencast, []);
    }

    function test_count() {
        const s = Privacy.parse(JSON.stringify(testCase.stateJson));
        compare(Privacy.count(s, "location"), 1, "those allowed");
        compare(Privacy.count(s, "camera"), 1);
        compare(Privacy.count(s, "screencast"), 2, "the apps with a saved selection");
        compare(Privacy.count(s, "remoteDesktop"), 0);
        compare(Privacy.count(null, "camera"), 0);
    }

    function test_actions() {
        compare(Privacy.allow("camera", "org.example.Meet", false), {op: "privacy.allow", category: "camera", app: "org.example.Meet", on: false});
        compare(Privacy.allow("location", "org.example.Maps", true).category, "location");
        compare(Privacy.allow("microphone", "org.example.Meet", true), null, "a category the store does not keep here");
        compare(Privacy.allow("camera", "../etc", true), null);
        compare(Privacy.allow("camera", "org.example.Meet", "yes"), null);
        compare(Privacy.allow("screencast", "org.example.Meet", true), null, "a saved selection has no switch");
        compare(Privacy.forget("screencast", testCase.tokenA), {op: "privacy.forget", kind: "screencast", token: testCase.tokenA});
        compare(Privacy.forget("remoteDesktop", "abc").kind, "remoteDesktop");
        compare(Privacy.forget("camera", "abc"), null);
        compare(Privacy.forget("screencast", "a b"), null);
        compare(Privacy.forget("screencast", "tok:1"), null, "only the portal's characters");
        compare(Privacy.forget("screencast", "_0000_fake_0000_0000_").token, "_0000_fake_0000_0000_");
        compare(Privacy.forget("screencast", ""), null);
        compare(Privacy.entryFile("org.example.Meet"), "org.example.Meet.desktop");
        compare(Privacy.entryFile("../../x"), "");
        const plain = {dir: "/usr/share/applications", hidden: false};
        verify(Privacy.hostApp("org.example.A", [plain]));
        verify(!Privacy.hostApp("org.example.A", [{dir: "/var/lib/flatpak/exports/share/applications", hidden: false}]), "a Flatpak export");
        verify(!Privacy.hostApp("org.example.A", [plain, {dir: "/home/u/.local/share/flatpak/exports/share/applications/", hidden: false}]),
            "a Flatpak with an override elsewhere");
        verify(!Privacy.hostApp("org.example.A", [{dir: "/home/u/.local/share/applications", hidden: true}]), "a hidden stub only: in doubt");
        verify(!Privacy.hostApp("snap.firefox", [plain]), "a Snap");
        verify(!Privacy.hostApp("org.example.A", []), "no entry found: not known to be the host's");
        verify(!Privacy.hostApp("org.example.A", [plain, {dir: "/var/lib/linglong/entries/share/applications", hidden: false}]), "a Linyaps app");
        compare(Privacy.hostCheckDirs(["/home/u/.local/share/applications", "/usr/share/applications"]),
            ["/home/u/.local/share/applications", "/usr/share/applications", "/home/u/.local/share/flatpak/exports/share/applications",
                "/var/lib/flatpak/exports/share/applications"], "the export folders are always read");
        compare(Privacy.hostCheckDirs(["/home/u/.local/share/applications", "/var/lib/flatpak/exports/share/applications"]).length, 3, "once each");
        compare(Privacy.actTag("camera"), "privacy.camera.act");
        // Ids that are Object.prototype's names are keys like any other.
        const odd = Privacy.parse(JSON.stringify({screencast: [{app: "__proto__", token: "abc"}], camera: [{app: "constructor", allowed: true}]}));
        compare(odd.screencast.length, 1);
        compare(odd.screencast[0].app, "__proto__");
        compare(odd.camera, [{app: "constructor", allowed: true}]);
    }

    // The portal allows the host's apps their location without reading the store: no switch for them there; the camera's
    // grant it reads for every app, so the switch stays.
    function test_hostApps() {
        const t = make(categoryComp, {key: "location"});
        answer(t);
        const weather = find(t.page, i => i.title === "Weather" && i.showToggle !== undefined);
        verify(!weather.showToggle);
        compare(weather.subtitle, "org.example.Weather · Not sandboxed: not limited");
        const maps = find(t.page, i => i.title === "org.example.Maps" && i.showToggle !== undefined);
        verify(maps.showToggle, "no entry found: the switch stays");
        const studio = find(t.page, i => i.title === "My Studio" && i.showToggle !== undefined);
        verify(studio.showToggle, "a Flatpak whose entry the user copied: still sandboxed, the user's name");
        compare(studio.subtitle, "org.example.Studio");
        verify(find(t.page, i => i.title === "org.example.Ghost" && i.showToggle !== undefined).showToggle, "a hidden stub only: in doubt, the switch stays");
        const c = make(categoryComp, {key: "camera"});
        answer(c);
        const booth = find(c.page, i => i.title === "Booth Camera" && i.showToggle !== undefined);
        verify(booth.showToggle, "the camera's grant is read for the host too");
        compare(booth.subtitle, "org.example.Booth · Not sandboxed: may use the camera directly");
    }

    // A Flatpak given every device (--device=all) opens /dev/video* itself: the metadata says so, an override may take it back.
    function test_flatpakDevices() {
        const meta = "[Application]\nname=org.example.Call\n\n[Context]\nshared=network;ipc;\ndevices=dri;all;\n";
        compare(Privacy.devicesAll(meta, false), true);
        compare(Privacy.devicesAll("[Context]\ndevices=dri;\n", false), false);
        compare(Privacy.devicesAll("[Context]\ndevices=!all;\n", true), false, "an override takes it back");
        compare(Privacy.devicesAll("[Context]\nshared=ipc;\n", true), true, "silent: unchanged");
        compare(Privacy.devicesAll("[Session Bus Policy]\ndevices=all\n", false), false, "only the Context group");
        compare(Privacy.flatpakInstalls(["/home/u/.local/share/applications", "/usr/share/applications"]),
            [{dir: "/home/u/.local/share/flatpak", user: true}, {dir: "/var/lib/flatpak", user: false}]);
        compare(Privacy.flatpakInstalls(["/apps"]), [{dir: "/var/lib/flatpak", user: false}]);
        const installs = Privacy.flatpakInstalls(["/home/u/.local/share/applications"]);
        const files = {};
        const read = p => files[p] ?? "";
        compare(Privacy.flatpakDevices("org.example.Call", installs, read), false, "not installed");
        files["/var/lib/flatpak/app/org.example.Call/current/active/metadata"] = meta;
        compare(Privacy.flatpakDevices("org.example.Call", installs, read), true);
        // The user's override, then the system's global one: flatpak run applies the system's first, the user's last.
        files["/home/u/.local/share/flatpak/overrides/org.example.Call"] = "[Context]\ndevices=!all;\n";
        compare(Privacy.flatpakDevices("org.example.Call", installs, read), false);
        files["/var/lib/flatpak/overrides/global"] = "[Context]\ndevices=all;\n";
        compare(Privacy.flatpakDevices("org.example.Call", installs, read), false, "the user's own override comes last");
        // A user installation does not read the system's overrides.
        files["/home/u/.local/share/flatpak/app/org.example.Mic/current/active/metadata"] = "[Context]\ndevices=dri;\n";
        compare(Privacy.flatpakDevices("org.example.Mic", installs, read), false);
        files["/home/u/.local/share/flatpak/overrides/global"] = "[Context]\ndevices=all;\n";
        compare(Privacy.flatpakDevices("org.example.Mic", installs, read), true);
        compare(Privacy.flatpakDevices("../x", installs, () => meta), false);
        compare(Privacy.flatpakDevices("snap.zoom", installs, () => meta), false);

        // The camera list says so under the app (its switch stays: the portal still reads it); the location list does not.
        const c = make(categoryComp, {key: "camera"});
        c.backend.files = Object.assign({}, c.backend.files, {"/var/lib/flatpak/app/org.example.Meet/current/active/metadata": meta});
        answer(c);
        const meet = find(c.page, i => i.title === "org.example.Meet" && i.showToggle !== undefined);
        verify(meet.showToggle);
        compare(meet.subtitle, "All devices: may use the camera directly");
        verify(find(c.page, i => i.footnote !== undefined && i.visible && i.footnote.indexOf("its switch does not limit it") >= 0));
        const l = make(categoryComp, {key: "location"});
        l.backend.files = Object.assign({}, l.backend.files, {"/var/lib/flatpak/app/org.example.Maps/current/active/metadata": meta});
        answer(l);
        compare(find(l.page, i => i.title === "org.example.Maps" && i.showToggle !== undefined).subtitle, "");
    }

    // No pane claims more than the portal enforces: the hub's footnote names who is not limited.
    function test_noClaimBeyondThePortal() {
        const t = make(hubComp);
        answer(t);
        const note = find(t.page, i => i.footnote !== undefined && i.visible && i.footnote !== "");
        verify(note.footnote.indexOf("They do not limit apps that are not sandboxed, nor sandboxed apps given direct access to devices.") >= 0, note.footnote);
        for (const key of ["location", "camera"]) {
            const c = make(categoryComp, {key: key});
            answer(c);
            verify(c.page.explanation.indexOf("when they ask the desktop portal") >= 0, key);
            verify(c.page.explanation.indexOf("without being asked") < 0, key);
        }
    }

    // An export entry that cannot be read still counts: the user's copy elsewhere does not make the app the host's.
    function test_unreadableExport() {
        const t = make(categoryComp, {key: "location"});
        t.backend.files = Object.assign({}, t.backend.files, {"/apps/org.example.Maps.desktop": "[Desktop Entry]\nType=Application\nName=Maps\n"});
        t.backend.unreadable = ["/home/u/.local/share/flatpak/exports/share/applications/org.example.Maps.desktop"];
        answer(t);
        verify(find(t.page, i => i.title === "Maps" && i.showToggle !== undefined).showToggle);
    }

    // The Flatpak export folders count even when the session's folders leave them out (Privacy.hostCheckDirs): the user's,
    // beside the user's applications folder, and the system's. A visible copy of the entry in the user's folder keeps the switch.
    function test_exportsOutsideDataDirs() {
        const t = make(categoryComp, {key: "location"});
        t.backend.applicationDirs = ["/home/u/.local/share/applications", "/usr/share/applications"];
        t.backend.files = {
            "/home/u/.local/share/applications/org.example.Maps.desktop": "[Desktop Entry]\nType=Application\nName=Maps\n",
            "/home/u/.local/share/flatpak/exports/share/applications/org.example.Maps.desktop": "[Desktop Entry]\nType=Application\nName=Maps\n",
            "/home/u/.local/share/applications/org.example.Weather.desktop": "[Desktop Entry]\nType=Application\nName=Weather\n",
            "/var/lib/flatpak/exports/share/applications/org.example.Weather.desktop": "[Desktop Entry]\nType=Application\nName=Weather\n",
            "/usr/share/applications/org.example.Studio.desktop": "[Desktop Entry]\nType=Application\nName=Studio\n"
        };
        answer(t);
        verify(find(t.page, i => i.title === "Maps" && i.showToggle !== undefined).showToggle, "the user's Flatpak export");
        verify(find(t.page, i => i.title === "Weather" && i.showToggle !== undefined).showToggle, "the system's Flatpak export");
        verify(!find(t.page, i => i.title === "Studio" && i.showToggle !== undefined).showToggle, "an entry in a plain folder only: the host's");
    }

    // A failure shows under its own category only (the tags differ), not under another one's list.
    function test_failureStaysInItsCategory() {
        const backend = createTemporaryObject(fakeBackend, testCase);
        const system = createTemporaryObject(serviceComp, testCase, {backend: backend});
        const camera = createTemporaryObject(categoryComp, testCase, {backend: backend, system: system, key: "camera"});
        answer({backend: backend});
        find(camera, i => i.title === "Booth Camera" && i.checked !== undefined).toggled(true);
        backend.failed("privacy.camera.act", "Rejected");
        backend.finished("privacy.camera.act", false, "");
        verify(find(camera, i => i.footnote !== undefined && i.visible && i.footnote.indexOf("Rejected") >= 0));
        const location = createTemporaryObject(categoryComp, testCase, {backend: backend, system: system, key: "location"});
        answer({backend: backend});
        verify(!find(location, i => i.footnote !== undefined && i.footnote.indexOf("Rejected") >= 0), "not under Location");
    }

    // A category whose portal this system does not have: its apps without a switch, and the footnote says why.
    function test_noPortalNoSwitch() {
        const t = make(categoryComp, {key: "background"});
        answer(t, Object.assign({}, testCase.stateJson, {background: [{app: "org.example.Maps", allowed: true}], portals: {background: false}}));
        const maps = find(t.page, i => i.title === "org.example.Maps" && i.showToggle !== undefined);
        verify(!maps.showToggle);
        verify(find(t.page, i => i.footnote !== undefined && i.visible && i.footnote.indexOf("do not provide this permission") >= 0));
        // An id named like an object's own property still gets its row.
        const c = make(categoryComp, {key: "camera"});
        answer(c, Object.assign({}, testCase.stateJson, {camera: [{app: "constructor", allowed: true}]}));
        verify(find(c.page, i => i.title === "constructor" && i.showToggle !== undefined));
    }

    // The hub asks the store once, then counts: Location's value, each category's "None", "1 app", "2 apps". (It also asks UDisks2
    // once, for Disk Encryption: ADR-0045.)
    function test_hubCounts() {
        const t = make(hubComp);
        compare(t.backend.busQueries.filter(q => q.what === "privacy.state").length, 1);
        compare(t.backend.busQueries.filter(q => q.what === "disk.state").length, 1);
        const location = find(t.page, i => i.text === "Location Services" && i.value !== undefined);
        compare(location.value, "", "nothing until the store answers");
        answer(t);
        compare(location.value, "1", "Maps; Weather, Studio and Ghost are not allowed");
        compare(row(t.page, "Background Apps").subtitle, "None");
        compare(row(t.page, "Camera").subtitle, "1 app");
        compare(row(t.page, "Remote Desktop").subtitle, "Not used on this system", "its portal is not there");
        compare(row(t.page, "Screen Sharing").subtitle, "2 apps");
        let opened = "";
        t.page.open.connect(id => opened = id);
        row(t.page, "Screen Sharing").clicked();
        compare(opened, "privacy-screen-sharing");
        location.clicked();
        compare(opened, "privacy-location");
    }

    // The store cannot be read: the reason under the categories, no counts.
    function test_hubStoreMissing() {
        const t = make(hubComp);
        t.backend.failed("privacy.state", "the service is not running");
        t.backend.finished("privacy.state", false, "");
        compare(row(t.page, "Camera").subtitle, "");
        verify(find(t.page, i => i.footnote !== undefined && i.footnote.indexOf("the service is not running") >= 0));
    }

    // A switch sends the store's action, waits for it, then reads the store again; the app's name is its desktop entry's.
    function test_cameraSwitch() {
        const t = make(categoryComp, {key: "camera"});
        answer(t);
        const booth = find(t.page, i => i.title === "Booth Camera" && i.checked !== undefined);
        verify(booth, "the name from org.example.Booth.desktop");
        compare(booth.subtitle, "org.example.Booth · Not sandboxed: may use the camera directly");
        compare(booth.checked, false);
        const meet = find(t.page, i => i.title === "org.example.Meet" && i.checked !== undefined);
        verify(meet, "no desktop entry: its id");
        compare(meet.subtitle, "", "the id is not repeated");
        booth.toggled(true);
        compare(t.backend.busActions.length, 1);
        compare(t.backend.busActions[0].op, {op: "privacy.allow", category: "camera", app: "org.example.Booth", on: true});
        compare(t.backend.busActions[0].tag, "privacy.camera.act", "a tag per category");
        verify(!booth.toggleEnabled, "busy until the store answers");
        meet.toggled(false);
        compare(t.backend.busActions.length, 1, "one change at a time");
        const queries = t.backend.busQueries.length;
        t.backend.finished("privacy.screencast.act", true, "");
        compare(t.backend.busQueries.length, queries, "another category's answer is not this one's");
        t.backend.finished("privacy.camera.act", true, "");
        compare(t.backend.busQueries.length, queries + 1, "read again");
        verify(booth.toggleEnabled);
    }

    // Remove forgets every saved selection of the selected app, one action after the other, then reads the store again.
    function test_forgetSavedSelections() {
        const t = make(categoryComp, {key: "screencast"});
        answer(t);
        const meet = find(t.page, i => i.title === "org.example.Meet" && i.showToggle !== undefined);
        compare(meet.subtitle, "2 saved choices", "no desktop entry: the id is the name");
        verify(!meet.showToggle);
        const remove = find(t.page, i => i.accessibleName === "Remove the selected app");
        verify(!remove.enabled, "nothing selected");
        meet.clicked();
        verify(remove.enabled);
        remove.clicked();
        compare(t.backend.busActions.map(a => a.op), [{op: "privacy.forget", kind: "screencast", token: testCase.tokenA}]);
        t.backend.finished("privacy.screencast.act", true, "");
        compare(t.backend.busActions.map(a => a.op.token), [testCase.tokenA, testCase.tokenB]);
        const queries = t.backend.busQueries.length;
        t.backend.finished("privacy.screencast.act", true, "");
        compare(t.backend.busActions.length, 2);
        compare(t.backend.busQueries.length, queries + 1);
    }

    // A lasting grant of a host app the portal could not name (xdg-desktop-portal 1.22 stores it under "") is listed as Other
    // Apps and can be removed; "" is still no app for a switch (review of the rc6 picker fix, MINOR 3).
    function test_unnamedAppSavedSelection() {
        const s = Privacy.parse(JSON.stringify({
            location: [{app: "", allowed: true}],
            screencast: [{app: "", token: testCase.tokenB}, {app: "", token: "a b"}, {app: "org.example.Meet", token: testCase.tokenA}]
        }));
        compare(s.location, [], "no switch for an app without an id");
        compare(s.screencast, [{app: "", tokens: [testCase.tokenB]}, {app: "org.example.Meet", tokens: [testCase.tokenA]}],
            "a saved selection without an app id is kept, a bad token is not");
        const t = make(categoryComp, {key: "screencast"});
        answer(t, {screencast: [{app: "", token: testCase.tokenB}, {app: "org.example.Meet", token: testCase.tokenA}]});
        const other = find(t.page, i => i.title === "Other Apps" && i.showToggle !== undefined);
        verify(other, "listed under a clear name");
        compare(other.subtitle, "1 saved choice", "no id to show beside the name");
        verify(!other.selected, "not selected before a click");
        const remove = find(t.page, i => i.accessibleName === "Remove the selected app");
        verify(!remove.enabled, "nothing selected");
        other.clicked();
        verify(other.selected);
        verify(remove.enabled);
        remove.clicked();
        compare(t.backend.busActions.map(a => a.op), [{op: "privacy.forget", kind: "screencast", token: testCase.tokenB}]);
    }

    // A failed action stops the queue and shows the store's reason.
    function test_forgetFailure() {
        const t = make(categoryComp, {key: "screencast"});
        answer(t);
        find(t.page, i => i.title === "org.example.Meet" && i.showToggle !== undefined).clicked();
        t.page.forgetSelected();
        t.backend.failed("privacy.screencast.act", "Unable to write the permission database");
        t.backend.finished("privacy.screencast.act", false, "");
        compare(t.backend.busActions.length, 1, "the second token is not tried");
        verify(find(t.page, i => i.footnote !== undefined && i.visible && i.footnote.indexOf("Unable to write the permission database") >= 0));
    }

    // In a dev session the state is read and nothing is sent.
    function test_devGuard() {
        const t = make(categoryComp, {key: "location"}, true);
        answer(t);
        const maps = find(t.page, i => i.title === "org.example.Maps" && i.checked !== undefined);
        maps.toggled(false);
        compare(t.backend.busActions.length, 0);
        verify(t.system.suppressedNote);
        verify(maps.toggleEnabled, "not left busy");
    }

    function test_emptyCategory() {
        const t = make(categoryComp, {key: "remoteDesktop"});
        answer(t);
        // Said as every empty list of Settings says it (EmptyListRow, ADR-0039 step 15).
        verify(find(t.page, i => i.text === "No saved choices" && i.visible && i.Accessible.role === Accessible.StaticText));
        // Its portal is not there: the footnote says so.
        verify(find(t.page, i => i.footnote !== undefined && i.visible && i.footnote.indexOf("do not provide this permission") >= 0));
        const b = make(categoryComp, {key: "background"});
        answer(b);
        verify(find(b.page, i => i.footnote !== undefined && i.visible && i.footnote.indexOf("may run in the background when they ask") >= 0), "its portal is there");
    }
}
