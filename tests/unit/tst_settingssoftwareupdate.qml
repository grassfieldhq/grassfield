pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings > General > Software Update (ADR-0033; docs/specs/updates.md U8, U10-U14, U19, U21, U22; A11): the badge of the
// General row, the check when the pane opens (the shell asked first, the checker run here without one), what each state shows,
// the exact commands of Set Up…, Repair…, Turn Off…, Beta Updates and Update Now, the password's wait and the one-line
// refusal, Log Out… and Restart… after an update, and the dev guard. Update Now without a terminal (U24-U30, owner decision
// SU-M1): the runner's one launch, the run's phases from its state and the helper's progress, the pane opened again
// mid-run, what each outcome says and offers, the end's restart. The backend is a fake: nothing runs.
TestCase {
    id: testCase
    name: "SettingsSoftwareUpdate"
    width: 700
    height: 1100
    visible: true
    when: windowShown

    readonly property string stateFile: "/state/grassfield/software-update.json"
    readonly property string runFile: "/run/user/1000/grassfield/software-update-run.json"
    readonly property string runOp: "0123456789abcdef0123456789abcdef"
    readonly property string repositoryReady: "GRASSFIELD_REPO_BASE=https://packages.example.org\nGRASSFIELD_SIGNING_FINGERPRINT=0123456789ABCDEF0123456789ABCDEF01234567\n"
    readonly property string repositoryPlaceholder: "GRASSFIELD_REPO_BASE=https://packages.grassfield.site\nGRASSFIELD_SIGNING_FINGERPRINT=\n"

    function iso(ms) {
        return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
    }

    function answer(state, extra, at) {
        return Object.assign({version: 1, state: state, channel: "stable", checkedAt: iso(at === undefined ? Date.now() : at)}, extra || {});
    }

    function available(at) {
        return answer("available", {
            grassfield: {installed: "1.0.0-1", available: "1.0.1-1", notes: [{version: "1.0.1-1", date: "2026-10-30", notes: {en: "Faster Dock.", fr: "Dock plus rapide."}}], notesError: null},
            omarchy: {installed: "4.0.4-1", available: "4.0.6-1"},
            others: 2,
            otherPackages: [{name: "glibc", installed: "2.42-1", available: "2.42-2"}, {name: "linux", installed: "6.18.1-1", available: "6.18.2-1"}]
        }, at);
    }

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: false
            property bool omarchyUpdate: true
            property bool updateRunner: false
            property string softwareUpdateRunFile: testCase.runFile
            property string homeDir: "/home/u"
            property string softwareUpdateFile: testCase.stateFile
            property var pendingActions: ({})
            property var files: ({})
            property var watched: []
            property var queries: []
            property var actions: []
            property var launches: []
            property var asks: []
            property var runs: []
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            signal fileChanged(string path)
            function readText(path: string): var {
                return {exists: files[path] !== undefined, ok: files[path] !== undefined, text: files[path] ?? ""};
            }
            function watch(path: string): bool {
                watched.push(path);
                return true;
            }
            function query(argv: var, tag: string): void {
                queries.push({argv: argv, tag: tag});
            }
            function act(what: string, argv: var, tag: string): bool {
                actions.push({argv: argv, tag: tag});
                const p = Object.assign({}, pendingActions);
                p[tag] = what;
                pendingActions = p;
                return true;
            }
            function launch(what: string, argv: var): bool {
                launches.push(argv);
                return true;
            }
            function askShellToCheck(tag: string): void {
                asks.push(tag);
            }
            function runUpdateChecker(tag: string): void {
                runs.push(tag);
            }
            // The Backend's end of a channel change: the latch released, then the answer.
            function endAction(tag: string, ok: bool, reason: string): void {
                const p = Object.assign({}, pendingActions);
                delete p[tag];
                pendingActions = p;
                if (!ok)
                    failed(tag, reason);
                finished(tag, ok, "");
            }
            function write(path: string, text: string): void {
                const f = Object.assign({}, files);
                if (text === null)
                    delete f[path];
                else
                    f[path] = text;
                files = f;
                fileChanged(path);
            }
        }
    }

    Component {
        id: storeComp
        QtObject {
            property var values: Object.assign({}, SettingsContract.ALL_DEFAULTS)
            property var writes: []
            function value(key: string): var {
                return values[key];
            }
            function set(key: string, v: var): bool {
                const e = {};
                e[key] = v;
                writes.push(e);
                values = Object.assign({}, values, e);
                return true;
            }
        }
    }

    Component {
        id: serviceComp
        SettingsQml.SystemService {}
    }

    Component {
        id: stateComp
        SettingsQml.SoftwareUpdateState {
            rebootMarker: "/home/u/.local/state/omarchy/reboot-required"
            kernelReleaseFile: "/proc/osrelease"
            modulesDir: "/modules"
        }
    }

    Component {
        id: pageComp
        SettingsQml.SoftwareUpdatePage {
            anchors.fill: parent
        }
    }

    Component {
        id: generalComp
        SettingsQml.GeneralPage {
            anchors.fill: parent
        }
    }

    Component {
        id: sheetComp
        SettingsQml.SoftwareUpdateSheet {
            anchors.fill: parent
        }
    }

    // `file`: software-update.json's object (null: none); `files`: more of the fake machine.
    function make(file, options) {
        const o = options || {};
        const files = Object.assign({"/proc/osrelease": "6.18.1-arch1-1\n", "/modules/6.18.1-arch1-1": "", "/usr/share/grassfield/pacman/repository.conf": o.repository ?? testCase.repositoryReady}, o.files || {});
        if (file !== null)
            files[testCase.stateFile] = JSON.stringify(file);
        const backend = createTemporaryObject(fakeBackend, testCase, {devSession: o.dev === true, omarchyUpdate: o.omarchy !== false, updateRunner: o.runner === true, files: files});
        const system = createTemporaryObject(serviceComp, testCase, {backend: backend});
        const store = createTemporaryObject(storeComp, testCase);
        const updates = createTemporaryObject(stateComp, testCase, {backend: backend, system: system});
        if (o.channel !== undefined)
            backend.finished("update.channel", true, o.channel + "\n");
        const page = o.noPage ? null : createTemporaryObject(pageComp, testCase, {updates: updates, store: store, system: system});
        return {backend: backend, system: system, store: store, updates: updates, page: page};
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

    function shown(item, pred) {
        return find(item, i => i.visible && pred(i));
    }

    function row(page, title) {
        return shown(page, i => i.title === title && i.valueText !== undefined);
    }

    function button(page, text) {
        return shown(page, i => i.text === text && i.push === true);
    }

    // The badge (U19): the releases the last success found, read from the shell's file; General's row shows it.
    function test_theBadgeCountsTheReleases() {
        const t = make(available(), {noPage: true});
        compare(t.updates.count, 2);
        verify(t.backend.watched.indexOf(testCase.stateFile) >= 0, "the file is watched");
        verify(t.backend.watched.indexOf("/etc/pacman.d/grassfield.conf") >= 0, "and the channel's file");
        const general = createTemporaryObject(generalComp, testCase, {updateCount: t.updates.count});
        const nav = shown(general, i => i.text === "Software Update" && i.badge !== undefined);
        verify(nav);
        compare(nav.badge, 2);
        compare(nav.Accessible.name, "Software Update, 2 updates");
        const badge = shown(nav, i => i.count === 2 && i.spoken !== undefined);
        verify(badge, "the red count is drawn");
        // The shell writes a new answer: the badge follows.
        t.backend.write(testCase.stateFile, JSON.stringify(answer("up-to-date", {grassfield: {installed: "1.0.1-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}})));
        compare(t.updates.count, 0);
        // A failure keeps the releases found (ADR-0033 d.6).
        const kept = SoftwareUpdateLogic.combine(available(), answer("failed", {error: "offline"}));
        t.backend.write(testCase.stateFile, JSON.stringify(kept));
        compare(t.updates.count, 2);
        t.backend.write(testCase.stateFile, "{half");
        compare(t.updates.count, 0, "a file that is not JSON counts nothing");
    }

    // U8: the pane checks when it opens, unless a check finished less than a minute ago; the shell is asked first.
    function test_thePaneChecksWhenItOpens() {
        const stale = make(available(Date.now() - 2 * 60 * 1000));
        compare(stale.backend.asks, ["update.ask"]);
        verify(stale.updates.checking);
        compare(stale.page.view.kind, "checking");
        verify(row(stale.page, "Checking for updates…"));
        verify(!button(stale.page, "Check Now").enabled, "one check at a time");
        const fresh = make(available(Date.now() - 20 * 1000));
        compare(fresh.backend.asks, [], "a check finished 20 s ago");
        verify(!fresh.updates.checking);
        const never = make(null);
        compare(never.backend.asks, ["update.ask"], "never checked");
    }

    // The shell runs the check (it answered "ok"): the pane waits for the file's next answer, not for the pending logout alone.
    function test_theShellsAnswerEndsTheWait() {
        // One time for both files: checkedAt keeps whole seconds, and two Date.now() calls around the page's creation could
        // fall on either side of a second, which made the pending logout below look like a new answer (1 run in 4).
        const before = Date.now() - 5 * 60 * 1000;
        const t = make(available(before));
        t.backend.finished("update.ask", true, "ok\n");
        verify(t.updates.checking);
        compare(t.backend.runs, []);
        t.backend.write(testCase.stateFile, JSON.stringify(Object.assign(available(before), {logoutPending: true})));
        verify(t.updates.checking, "the pending logout written alone is no answer");
        t.backend.write(testCase.stateFile, JSON.stringify(answer("up-to-date", {grassfield: {installed: "1.0.1-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}})));
        verify(!t.updates.checking);
        verify(row(t.page, "This computer is up to date"));
        verify(row(t.page, "This computer is up to date").subtitle.indexOf("Grassfield 1.0.1, Omarchy 4.0.6") === 0);
        verify(button(t.page, "Check Now").enabled);
        button(t.page, "Check Now").clicked();
        compare(t.backend.asks, ["update.ask", "update.ask"], "Check Now, whatever the last check's age");
    }

    // U10: no shell (or a dev session without one): Settings runs the checker and keeps its answer in memory.
    function test_withoutAShellSettingsChecksItself() {
        const t = make(null);
        t.backend.finished("update.ask", false, "");
        compare(t.backend.runs, ["update.run"]);
        verify(t.updates.checking);
        t.backend.finished("update.run", true, JSON.stringify(available()) + "\n");
        verify(!t.updates.checking);
        compare(t.updates.count, 2);
        compare(t.page.view.kind, "available");
        t.updates.check();
        t.backend.finished("update.ask", true, "refused\n");
        compare(t.backend.runs.length, 2, "a refusal is no check either");
        t.backend.finished("update.run", false, "");
        compare([t.page.view.kind, t.page.view.message], ["failed", "the checker could not run"]);
        compare(t.updates.count, 2, "what was found stays");
        verify(row(t.page, "Software Update could not check for updates"));
    }

    // U21: the releases, the notes, Omarchy's, the other updates and Update Now with its exact command (U11).
    function test_availableUpdates() {
        const t = make(available());
        verify(row(t.page, "Updates are available"));
        const gf = row(t.page, "Grassfield 1.0.1");
        verify(gf);
        compare(gf.subtitle, "Installed: 1.0.0");
        // The mark's tile in the brand green, as General > About's (ADR-0040 ID-11; review of 5391761).
        compare(gf.tileColor, "grassfield");
        const info = [];
        t.page.infoRequested.connect(topic => info.push(topic));
        shown(gf, i => i.text === "More Info…" && i.activated !== undefined).activated();
        verify(row(t.page, "Omarchy 4.0.6"));
        compare(row(t.page, "Omarchy 4.0.6").subtitle, "Omarchy's release notes are on its project page.");
        const others = row(t.page, "2 other updates");
        verify(others);
        shown(others, i => i.accessibleName === "Other updates").clicked();
        compare(info, ["notes", "others"]);
        const update = button(t.page, "Update Now");
        verify(update.enabled);
        update.clicked();
        compare(t.backend.launches, [["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"]]);
        verify(t.updates.updateRunning);
        verify(!button(t.page, "Update Now").enabled, "while Omarchy's terminal runs the update");
        verify(button(t.page, "Check Now").enabled, "Check Now is never held back by the update's state");
        // The check after the launch finds the lock held: update-running, until the waiter's answer.
        t.updates.launchCheck.triggered();
        compare(t.backend.asks.length, 1, "the pane opened on a fresh check: this is the first ask");
        t.backend.finished("update.ask", true, "ok");
        t.backend.write(testCase.stateFile, JSON.stringify(SoftwareUpdateLogic.combine(available(), answer("update-running", {}, Date.now() + 1000))));
        verify(t.updates.updateRunning);
        verify(row(t.page, "An update is running in Omarchy's terminal"));
        verify(!button(t.page, "Update Now").enabled);
        t.backend.write(testCase.stateFile, JSON.stringify(answer("up-to-date", {grassfield: {installed: "1.0.1-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}}, Date.now() + 2000)));
        verify(!t.updates.updateRunning);
        verify(!button(t.page, "Update Now"), "nothing left to update");
    }

    // ADR-0050 (U35-U37): a release still being released gradually, a security release, a withdrawn one.
    function test_stagedRollout() {
        const upToDate = {grassfield: {installed: "1.0.0-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}};
        let t = make(answer("up-to-date", Object.assign({rollout: {descriptor: "ok", cohort: 12, staged: {version: "1.0.1-1", security: false, offerAt: null}, withdrawn: null, security: false}}, upToDate)));
        verify(row(t.page, "This computer is up to date"), "the headline is what the database offers");
        const staged = row(t.page, "Grassfield 1.0.1 is being released gradually.");
        verify(staged);
        compare(staged.subtitle, "It will be offered to this computer soon.");
        compare(staged.tileColor, "grassfield");
        verify(!shown(staged, i => i.push === true), "no button: it is installed once offered");
        verify(!button(t.page, "Update Now"), "nothing to install yet");

        t = make(answer("up-to-date", Object.assign({rollout: {descriptor: "ok", cohort: 12, staged: {version: "1.0.1-1", security: true, offerAt: null}, withdrawn: null, security: false}}, upToDate)));
        verify(row(t.page, "Grassfield 1.0.1 is an important security update."));

        const sec = available();
        sec.rollout = {descriptor: "ok", cohort: 3, staged: null, withdrawn: null, security: true};
        t = make(sec);
        compare(row(t.page, "Grassfield 1.0.1").subtitle, "Important security update. Installed: 1.0.0");

        t = make(answer("up-to-date", Object.assign({rollout: {descriptor: "ok", cohort: 3, staged: null, withdrawn: "1.0.0-1", security: false}}, upToDate)));
        // The headline says it, never "up to date" under a withdrawn release (nested review finding 10).
        verify(row(t.page, "Grassfield 1.0.0 has been withdrawn"));
        verify(!row(t.page, "This computer is up to date"), "not up to date: its release was withdrawn");
        const gone = row(t.page, "A corrected version is on its way.");
        verify(gone);
        compare(gone.subtitle, "It will be offered to this computer as soon as it's ready.");

        const fixed = available();
        fixed.rollout = {descriptor: "ok", cohort: 3, staged: null, withdrawn: "1.0.0-1", security: false};
        t = make(fixed);
        verify(!row(t.page, "Grassfield 1.0.0 has been withdrawn"), "a newer release is offered: its row is the answer");
        verify(!row(t.page, "A corrected version is on its way."));

        t = make(answer("up-to-date", Object.assign({rollout: {descriptor: "stale", cohort: 3, staged: {version: "1.0.1-1", security: false, offerAt: null}, withdrawn: null, security: false}}, upToDate)));
        verify(!row(t.page, "Grassfield 1.0.1 is being released gradually."), "a stale descriptor explains nothing");
    }

    // A stored update-running whose waiter ended with the session (a reboot or a log out during the update, a crash) is never
    // kept: the pane checks when it opens, and Check Now stays available (integrator review of a9a5974, MAJOR 3).
    function test_aStaleUpdateRunningIsCheckedAgain() {
        const t = make(SoftwareUpdateLogic.combine(available(Date.now() - 7 * 3600 * 1000), answer("update-running", {}, Date.now() - 6 * 3600 * 1000)));
        compare(t.backend.asks, ["update.ask"], "checked when the pane opens");
        t.backend.finished("update.ask", true, "ok");
        t.backend.write(testCase.stateFile, JSON.stringify(available(Date.now())));
        verify(!t.updates.checking);
        verify(button(t.page, "Check Now").enabled);
        // Even while the stored state still says update-running, Check Now is there.
        const held = make(SoftwareUpdateLogic.combine(available(Date.now() - 3600 * 1000), answer("update-running", {}, Date.now() - 10 * 1000)));
        compare(held.backend.asks, [], "a fresh update-running is not checked again at once");
        verify(!button(held.page, "Update Now").enabled, "Update Now waits while the stored state says the update runs");
        verify(button(held.page, "Check Now").enabled, "Check Now is never held back by the stored state alone");
        button(held.page, "Check Now").clicked();
        compare(held.backend.asks, ["update.ask"]);
    }

    // Grassfield updates off still offers the system's updates (the integrator's decision of 2026-10-28): Omarchy's release,
    // the other updates and Update Now under Set Up….
    function test_turnedOffStillOffersTheSystemsUpdates() {
        const t = make(answer("not-set-up", {channel: null, grassfield: {installed: "1.0.0-1", available: null, notes: [], notesError: null},
            omarchy: {installed: "4.0.4-1", available: "4.0.6-1"}, others: 2, otherPackages: [{name: "glibc", installed: "2.42-1", available: "2.42-2"},
                {name: "linux", installed: "6.18.1-1", available: "6.18.2-1"}]}), {channel: "off"});
        verify(row(t.page, "Grassfield updates are not set up"));
        verify(button(t.page, "Set Up…"));
        verify(row(t.page, "Omarchy 4.0.6"));
        verify(row(t.page, "2 other updates"));
        verify(!row(t.page, "Grassfield 1.0.1"));
        verify(button(t.page, "Update Now").enabled);
        button(t.page, "Update Now").clicked();
        compare(t.backend.launches, [["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"]]);
        compare(t.updates.count, 1, "Omarchy's release on the badge");
        // A failed check while off: what was found stays, Set Up… too.
        const f = make(SoftwareUpdateLogic.combine(answer("not-set-up", {omarchy: {installed: "4.0.4-1", available: "4.0.6-1"}, others: 0, otherPackages: []}),
            answer("failed", {error: "offline"})), {channel: "off"});
        verify(button(f.page, "Set Up…"));
        verify(row(f.page, "Omarchy 4.0.6"));
    }

    // Degraded: not an Omarchy system (no launcher): Update Now is disabled and says why.
    function test_withoutOmarchysUpdateCommand() {
        const t = make(available(), {omarchy: false});
        verify(!button(t.page, "Update Now").enabled);
        verify(row(t.page, "Update Now needs Omarchy's update command, which this system does not have."));
        t.updates.updateNow();
        compare(t.backend.launches, []);
    }

    // U13: Set Up… runs `grassfield-channel-set stable` on a plain version (beta on a prerelease or an unreadable one: test_setUpOnAPrereleaseBuildChoosesBeta), through the polkit dialog.
    function test_setUpWaitsForPermissionAndSaysWhyNot() {
        const t = make(answer("not-set-up"), {channel: "off", files: {"/usr/share/grassfield/VERSION": "1.0.0\n"}});
        verify(row(t.page, "Grassfield updates are not set up"));
        const setUp = button(t.page, "Set Up…");
        verify(setUp);
        setUp.clicked();
        compare(t.backend.actions, [{argv: ["/usr/lib/grassfield/grassfield-channel-set", "stable"], tag: "update.channel.act"}]);
        verify(t.updates.waitingForPermission);
        compare(row(t.page, "Grassfield updates are not set up").subtitle, "Waiting for permission…");
        verify(!button(t.page, "Set Up…").enabled, "no second dialog");
        t.backend.endAction("update.channel.act", false, "grassfield-channel-set: not allowed: the authentication was cancelled or refused, or no authentication agent answered");
        verify(!t.updates.waitingForPermission);
        verify(shown(t.page, i => i.footnote === "Grassfield updates were not set up: not allowed"));
        compare(t.backend.queries.filter(q => q.tag === "update.channel").length, 2, "the channel read again");
        compare(t.backend.asks.length, 0, "nothing changed: no check (the pane opened on a fresh answer)");
        // Accepted: the channel is read again and the pane checks (U12).
        button(t.page, "Set Up…").clicked();
        t.backend.endAction("update.channel.act", true, "");
        compare(t.backend.asks, ["update.ask"]);
        verify(!shown(t.page, i => i.footnote === "Grassfield updates were not set up: not allowed"), "the line goes with the next attempt");
    }

    // A prerelease build sets up on beta (owner decision of 2026-11-04): -rcN and -betaN, never a plain version.
    function test_setUpOnAPrereleaseBuildChoosesBeta() {
        const t = make(answer("not-set-up"), {channel: "off", files: {"/usr/share/grassfield/VERSION": "1.0.0-rc2\n"}});
        compare(t.updates.defaultChannel, "beta");
        button(t.page, "Set Up…").clicked();
        compare(t.backend.actions, [{argv: ["/usr/lib/grassfield/grassfield-channel-set", "beta"], tag: "update.channel.act"}]);
        const plain = make(answer("not-set-up"), {channel: "off", files: {"/usr/share/grassfield/VERSION": "1.0.0\n"}});
        compare(plain.updates.defaultChannel, "stable");
        button(plain.page, "Set Up…").clicked();
        compare(plain.backend.actions[0].argv[1], "stable");
    }

    // The channel rule (ADR-0033 O15b): while the installed version is a prerelease, or cannot be read, the picker's Off would
    // follow the empty stable channel: it is disabled and the sheet says why. A plain version enables it.
    function test_betaStaysOnWithABetaVersionInstalled() {
        const texts = ["1.0.0-rc2\n", "1.1.0-beta1", "", "unknown", "1.0"];
        for (const v of texts) {
            const files = v === "" ? {} : {"/usr/share/grassfield/VERSION": v};
            const t = make(available(), {channel: "beta", files: files});
            const sheet = createTemporaryObject(sheetComp, testCase, {updates: t.updates, store: t.store, topic: "beta"});
            sheet.open();
            const menu = shown(sheet, i => i.accessibleName === "Beta updates" && i.picked !== undefined);
            verify(!menu.enabled, "Off disabled for VERSION '" + v + "'");
            verify(shown(sheet, i => i.footnote === "Beta updates stay on while a beta version of Grassfield is installed. You can turn them off once the release is installed."), "the footnote for '" + v + "'");
            verify(shown(sheet, i => i.text === "Turn Off Grassfield Updates…" && i.push === true).enabled, "Turn Off stays available");
        }
        const plain = make(available(), {channel: "beta", files: {"/usr/share/grassfield/VERSION": "1.0.0\n"}});
        const plainSheet = createTemporaryObject(sheetComp, testCase, {updates: plain.updates, store: plain.store, topic: "beta"});
        plainSheet.open();
        verify(shown(plainSheet, i => i.accessibleName === "Beta updates" && i.picked !== undefined).enabled, "Off enabled on a plain version");
        verify(!shown(plainSheet, i => i.footnote !== undefined && i.footnote.indexOf("Beta updates stay on") === 0));
    }

    // Refusals: a build without its key or host hides Set Up… and says so.
    // Without a host or key the pane never contradicts itself: the system's updates are offered under the up-to-date or available
    // headline, with one line on Grassfield's own (integrator re-review of 5ae52b1, minor 1).
    function test_aBuildWithoutRepositoryHidesSetUp() {
        const t = make(answer("not-set-up"), {repository: testCase.repositoryPlaceholder});
        verify(row(t.page, "This computer is up to date"));
        compare(row(t.page, "This computer is up to date").subtitle, "Grassfield's own updates are not available in this build: it has no package repository or signing key yet.");
        verify(!button(t.page, "Set Up…"));
        const listing = make(answer("not-set-up", {omarchy: {installed: "4.0.4-1", available: "4.0.6-1"}, others: 0, otherPackages: []}),
            {repository: testCase.repositoryPlaceholder});
        verify(row(listing.page, "Updates are available"));
        verify(!row(listing.page, "This computer is up to date"));
        verify(row(listing.page, "Omarchy 4.0.6"));
        verify(button(listing.page, "Update Now").enabled);
        verify(!button(listing.page, "Set Up…"));
        const none = make(answer("not-set-up"), {files: {"/usr/share/grassfield/pacman/repository.conf": undefined}, repository: ""});
        verify(!button(none.page, "Set Up…"), "no repository.conf at all");
    }

    // U13: repair, and a custom channel, offer Repair…; U22: blocking offers Turn Off Grassfield Updates….
    function test_repairAndTurnOff() {
        const r = make(answer("repair"));
        button(r.page, "Repair…").clicked();
        compare(r.backend.actions.map(a => a.argv), [["/usr/lib/grassfield/grassfield-channel-set", "repair"]]);
        const custom = make(answer("up-to-date", {channel: "custom", grassfield: {installed: "1.0.1-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}}));
        verify(button(custom.page, "Repair…"), "a custom channel is repaired too");
        const b = make(SoftwareUpdateLogic.combine(available(), answer("blocking", {episode: "2026-10-28T09:00:00Z"})));
        verify(row(b.page, "Grassfield's package repository cannot be used"));
        verify(row(b.page, "Grassfield's package repository cannot be used").subtitle.indexOf("every system update stops") > 0);
        verify(!button(b.page, "Update Now").enabled, "every Omarchy update fails while blocking");
        verify(row(b.page, "Omarchy's update cannot run while Grassfield's repository cannot be used."));
        b.updates.updateNow();
        compare(b.backend.launches, []);
        const off = button(b.page, "Turn Off Grassfield Updates…");
        verify(off.destructive);
        off.clicked();
        compare(b.backend.actions.map(a => a.argv), [["/usr/lib/grassfield/grassfield-channel-set", "off"]]);
        b.backend.endAction("update.channel.act", false, "grassfield-channel-set: an Omarchy update is running: try again when it has finished");
        verify(shown(b.page, i => i.footnote === "Grassfield updates were not turned off: an Omarchy update is running: try again when it has finished"));
    }

    // U12: Beta Updates shows the channel grassfield-channel-set prints; the sheet's menu runs the switch.
    function test_betaUpdates() {
        // A plain version is installed: Off is available (a prerelease locks it, test_betaStaysOnWithABetaVersionInstalled).
        const t = make(available(), {channel: "beta", files: {"/usr/share/grassfield/VERSION": "1.0.0\n"}});
        compare(t.backend.queries[0], {argv: ["/usr/lib/grassfield/grassfield-channel-set"], tag: "update.channel"});
        compare(row(t.page, "Beta Updates").valueText, "Grassfield Beta");
        const info = [];
        t.page.infoRequested.connect(topic => info.push(topic));
        shown(row(t.page, "Beta Updates"), i => i.accessibleName === "Beta Updates details").clicked();
        compare(info, ["beta"]);
        const sheet = createTemporaryObject(sheetComp, testCase, {updates: t.updates, store: t.store, topic: "beta"});
        sheet.open();
        const menu = shown(sheet, i => i.accessibleName === "Beta updates" && i.picked !== undefined);
        verify(menu.enabled);
        compare(menu.value, "beta");
        menu.picked("stable");
        compare(t.backend.actions, [{argv: ["/usr/lib/grassfield/grassfield-channel-set", "stable"], tag: "update.channel.act"}]);
        compare(menu.value, "beta", "the old value until the file changes");
        compare(row(t.page, "Beta Updates").valueText, "Waiting for permission…");
        verify(!menu.enabled);
        t.backend.endAction("update.channel.act", false, "grassfield-channel-set: not allowed: the authentication was cancelled or refused, or no authentication agent answered");
        verify(shown(t.page, i => i.footnote === "Beta updates were not changed: not allowed"));
        // The file changed: the channel is read again.
        const reads = t.backend.queries.length;
        t.backend.fileChanged("/etc/pacman.d/grassfield.conf");
        compare(t.backend.queries.length, reads + 1);
        t.backend.finished("update.channel", true, "stable\n");
        compare(row(t.page, "Beta Updates").valueText, "Off");
        compare(menu.value, "stable");
        // Turn Off Grassfield Updates… in the sheet (U13).
        shown(sheet, i => i.text === "Turn Off Grassfield Updates…" && i.push === true).clicked();
        compare(t.backend.actions[t.backend.actions.length - 1].argv, ["/usr/lib/grassfield/grassfield-channel-set", "off"]);
        // Not set up: the menu waits for Set Up.
        const off = make(answer("not-set-up"), {channel: "off", noPage: true});
        const offSheet = createTemporaryObject(sheetComp, testCase, {updates: off.updates, store: off.store, topic: "beta"});
        offSheet.open();
        verify(!shown(offSheet, i => i.accessibleName === "Beta updates" && i.picked !== undefined).enabled);
    }

    // U7, U21: Automatic Updates' one switch.
    function test_automaticUpdates() {
        const t = make(available());
        compare(row(t.page, "Automatic Updates").valueText, "Check for updates");
        const sheet = createTemporaryObject(sheetComp, testCase, {updates: t.updates, store: t.store, topic: "automatic"});
        sheet.open();
        verify(sheet.message.indexOf("never downloads or installs anything by itself") > 0);
        const toggle = shown(sheet, i => i.accessibleName === "Check for updates" && i.toggled !== undefined);
        verify(toggle.checked);
        toggle.toggled(false);
        compare(t.store.writes, [{"updates.automaticCheck": false}]);
        compare(row(t.page, "Automatic Updates").valueText, "Off");
    }

    // U6: More Info… shows the notes; the other updates are listed; notes that are missing say so.
    function test_notesAndOtherUpdates() {
        const t = make(available(), {noPage: true});
        const notes = createTemporaryObject(sheetComp, testCase, {updates: t.updates, store: t.store, topic: "notes"});
        notes.open();
        compare(notes.title, "Grassfield 1.0.1");
        verify(shown(notes, i => i.text === "Faster Dock."), "plain text, English in an English session");
        const others = createTemporaryObject(sheetComp, testCase, {updates: t.updates, store: t.store, topic: "others"});
        others.open();
        compare(others.title, "Other Updates");
        tryVerify(() => shown(others, i => i.title === "linux" && i.valueText === "6.18.1-1 → 6.18.2-1"));
        const bare = make(answer("available", {grassfield: {installed: "1.0.0-1", available: "1.0.1-1", notes: [], notesError: "unavailable"}, omarchy: {installed: "4.0.4-1", available: null}, others: 0, otherPackages: []}), {noPage: true});
        const none = createTemporaryObject(sheetComp, testCase, {updates: bare.updates, store: bare.store, topic: "notes"});
        compare(none.message, "Release notes are not available.");
    }

    // U14: after an update, Log Out… (GF-083's pending logout) or Restart… (Omarchy's marker, or the kernel's modules gone).
    // ADR-0041 step 2b (U31): a toolkit package replaced under the session, without a Grassfield update of its own: the row
    // says "Log out to finish updating" (no "Grassfield", no package name), with the generic subtitle; with Grassfield's
    // own log out too, its name comes back.
    function test_aToolkitLogOutAlone() {
        const t = make(Object.assign(answer("up-to-date"), {toolkitLogout: true}));
        verify(t.updates.toolkitLogout && !t.updates.grassfieldLogout && t.updates.logoutNeeded, "the toolkit's log out alone is a log out");
        verify(row(t.page, "Log out to finish updating"), "the generic title");
        verify(!row(t.page, "Log out to finish updating Grassfield"), "not Grassfield's");
        const asked = [];
        t.page.endSessionRequested.connect(a => asked.push(a));
        button(t.page, "Log Out…").clicked();
        compare(asked, ["logout"]);
        const both = make(Object.assign(answer("up-to-date"), {toolkitLogout: true, logoutPending: true}));
        verify(both.updates.grassfieldLogout && row(both.page, "Log out to finish updating Grassfield"), "with Grassfield's own update, its name");
        const none = make(answer("up-to-date"));
        verify(!none.updates.toolkitLogout && !none.updates.logoutNeeded && !row(none.page, "Log out to finish updating"));
    }

    function test_logOutOrRestartAfterAnUpdate() {
        const t = make(Object.assign(answer("up-to-date"), {logoutPending: true}));
        verify(row(t.page, "Log out to finish updating Grassfield"));
        const asked = [];
        t.page.endSessionRequested.connect(a => asked.push(a));
        verify(button(t.page, "Log Out…").enabled, "no run going on: Log Out… can be used");
        button(t.page, "Log Out…").clicked();
        compare(asked, ["logout"]);
        t.updates.endSession("logout");
        compare(t.backend.launches, [["/usr/lib/grassfield/grassfield-session-end", "logout"]]);
        const r = make(answer("up-to-date"), {files: {"/home/u/.local/state/omarchy/reboot-required": ""}});
        verify(row(r.page, "Restart to finish updating"));
        verify(button(r.page, "Restart…").enabled, "no run going on: Restart… can be used");
        button(r.page, "Restart…").clicked();
        r.updates.endSession("restart");
        compare(r.backend.launches, [["/usr/lib/grassfield/grassfield-session-end", "restart"]]);
        const kernel = make(answer("up-to-date"), {files: {"/modules/6.18.1-arch1-1": undefined}});
        verify(kernel.updates.restartNeeded, "the running kernel's modules are gone");
        const unknown = make(answer("up-to-date"), {files: {"/proc/osrelease": undefined}});
        verify(!unknown.updates.restartNeeded, "an unreadable kernel release says nothing");
        const none = make(answer("up-to-date"));
        verify(!none.updates.restartNeeded && !none.updates.logoutPending);
        verify(!row(none.page, "Log out to finish updating Grassfield"));
    }

    // The runner's state file, and the process it names (field 22 of /proc/<pid>/stat is its start time).
    function runState(phase, result, extra) {
        return JSON.stringify(Object.assign({version: 1, op: testCase.runOp, pid: 4242, startTime: "777", phase: phase, result: result || "",
            restart: "", snapshot: "", deferred: [], startedAt: Date.now(), finishedAt: phase === "done" ? Date.now() : 0}, extra || {}));
    }
    readonly property string runnerStat: "4242 (grassfield-upda) S 1 4242 4242 0 -1 4194560 100 0 0 0 0 0 0 0 20 0 1 0 777 1000 100\n"
    readonly property string helperStat: "5151 (bash) S 1 5151 5151 0 -1 4194560 100 0 0 0 0 0 0 0 20 0 1 0 888 1000 100\n"
    function helperFile(ext) {
        return "/run/grassfield-update/" + testCase.runOp + "." + ext;
    }

    // U24-U25: Update Now starts the runner, once, then shows the run's phase, its count and one bar from the files it reads.
    function test_updateNowRunsWithoutATerminal() {
        const t = make(available(), {runner: true});
        verify(row(t.page, "Update Now installs everything listed here."));
        compare(row(t.page, "Update Now installs everything listed here.").subtitle, "It asks for an administrator's password and saves a snapshot first.");
        button(t.page, "Update Now").clicked();
        compare(t.backend.launches, [["/usr/lib/grassfield/grassfield-update-run"]]);
        verify(t.updates.running);
        verify(t.updates.poll.running, "the pane reads the run's files while it goes on");
        verify(row(t.page, "Waiting for permission…"));
        verify(!button(t.page, "Update Now"), "no second Update Now while it runs");
        const bar = shown(t.page, i => i.indeterminate !== undefined && i.accessibleName === "Waiting for permission…");
        verify(bar && bar.indeterminate, "an indeterminate bar until something is counted");
        // The runner writes its state; the helper its progress.
        t.backend.write(testCase.runFile, runState("authorizing"));
        t.backend.write("/proc/4242/stat", testCase.runnerStat);
        t.updates.readRun();
        verify(row(t.page, "Waiting for permission…"), "the password dialog is up");
        t.backend.write(helperFile("started"), "5151 888
");
        t.backend.write("/proc/5151/stat", testCase.helperStat);
        t.backend.write(helperFile("progress"), "checking
");
        t.updates.readRun();
        verify(row(t.page, "Preparing the update…"));
        t.backend.write(helperFile("progress"), "snapshot
");
        t.updates.readRun();
        verify(row(t.page, "Saving a snapshot of this computer…"));
        t.backend.write(helperFile("progress"), "downloading 3 10
");
        t.updates.readRun();
        compare(row(t.page, "Downloading updates…").subtitle, "3 of 10");
        compare(t.updates.run.percent, 17);
        verify(!shown(t.page, i => i.indeterminate !== undefined && i.accessibleName === "Downloading updates…").indeterminate);
        t.backend.write(helperFile("progress"), "installing 5 10
");
        t.updates.readRun();
        compare(row(t.page, "Installing updates…").subtitle, "5 of 10");
        compare(t.updates.run.percent, 70);
        t.backend.write(helperFile("exit"), "0
snapshot made
packages 10
restart kernel
");
        t.backend.write(testCase.runFile, runState("configuring"));
        t.updates.readRun();
        verify(row(t.page, "Finishing the update…"));
        // The end: the restart it asks for, once, and the pane's row.
        const finished = [];
        t.updates.runFinished.connect((result, restart) => finished.push(result + ":" + restart));
        t.backend.write(testCase.runFile, runState("done", "done", {restart: "restart", snapshot: "made"}));
        t.updates.readRun();
        compare(finished, ["done:restart"]);
        verify(!t.updates.running);
        verify(!t.updates.poll.running, "nothing read once it ended");
        verify(t.updates.restartNeeded);
        verify(row(t.page, "Restart to finish updating"));
        t.updates.readRun();
        compare(finished.length, 1, "a run that ended is announced once");
        verify(button(t.page, "Check Now").enabled);
    }

    // U25: the run outlives the window. Opened again mid-run, the pane shows it; a runner gone with its helper shows nothing.
    function test_aRunIsShownWhenThePaneOpensAgain() {
        const running = {};
        running[testCase.runFile] = runState("authorizing");
        running["/proc/4242/stat"] = testCase.runnerStat;
        running[helperFile("started")] = "5151 888
";
        running["/proc/5151/stat"] = testCase.helperStat;
        running[helperFile("progress")] = "installing 2 4
";
        const t = make(available(), {runner: true, files: running});
        verify(t.updates.running);
        verify(t.updates.poll.running);
        compare(row(t.page, "Installing updates…").subtitle, "2 of 4");
        // The runner ended without its last state (a log out): the helper still runs, so the run is shown.
        const orphan = Object.assign({}, running, {"/proc/4242/stat": undefined});
        verify(make(available(), {runner: true, files: orphan}).updates.running);
        // Neither runs (a crash, a reboot left the state): nothing is shown, Update Now is back.
        const gone = Object.assign({}, orphan, {"/proc/5151/stat": undefined});
        const g = make(available(), {runner: true, files: gone});
        verify(!g.updates.running);
        verify(button(g.page, "Update Now").enabled);
        // A pid reused by another process (another start time) is not the runner.
        const reused = Object.assign({}, gone, {"/proc/4242/stat": testCase.runnerStat.replace(" 777 ", " 999 ")});
        verify(!make(available(), {runner: true, files: reused}).updates.running);
        // Restart… and Log Out… wait for the run's end (the system changes until then).
        const marked = Object.assign({}, running, {"/home/u/.local/state/omarchy/reboot-required": ""});
        const m = make(available(), {runner: true, files: marked});
        verify(row(m.page, "Restart to finish updating"));
        verify(!button(m.page, "Restart…").enabled, "no restart while the run goes on");
        const after = Object.assign({}, gone, {"/home/u/.local/state/omarchy/reboot-required": ""});
        verify(button(make(available(), {runner: true, files: after}).page, "Restart…").enabled, "Restart… is back once the run ended");
        // A new session (the log out took the runner's folder): the helper `last` names, while it runs.
        const session = {"/run/grassfield-update/last": testCase.runOp + "\n"};
        session[helperFile("started")] = "5151 888\n";
        session["/proc/5151/stat"] = testCase.helperStat;
        session[helperFile("progress")] = "installing 3 4\n";
        const s = make(available(), {runner: true, files: session});
        verify(s.updates.running);
        compare(row(s.page, "Installing updates…").subtitle, "3 of 4");
        session[helperFile("exit")] = "0\npackages 4\n";
        verify(!make(available(), {runner: true, files: session}).updates.running, "an ended helper shows nothing");
        verify(!make(available(), {runner: true, files: {"/run/grassfield-update/last": "../../etc\n"}}).updates.running, "only an operation id");
    }

    // U28-U30: what an ended run says, with its one action; the same sentence when Settings opens again.
    function test_whatARunSays() {
        const cases = [
            ["incompatible", "This update needs a newer version of Grassfield, which isn't available yet.", ""],
            ["terminal", "This update asks questions that need Omarchy's terminal.", "Update in Terminal…"],
            ["failed", "The update could not be installed. Nothing was changed.", ""],
            ["failed-partial", "The update stopped before it finished.", ""],
            ["space", "This computer needs 10 GB of free space to update.", ""],
            ["power", "Connect this computer to power to update.", ""],
            ["busy", "Another update is running.", ""],
            ["denied", "Software Update was not allowed to update this computer.", ""]
        ];
        for (const c of cases) {
            const files = {};
            files[testCase.runFile] = runState("done", c[0]);
            const t = make(available(), {runner: true, files: files});
            const r = row(t.page, c[1]);
            verify(r, c[0] + " says: " + c[1]);
            if (c[2] !== "")
                verify(button(t.page, c[2]), c[0] + " offers " + c[2]);
            else
                verify(!button(t.page, "Update in Terminal…") && !button(t.page, "Finish in Terminal…"), c[0] + " offers no terminal");
            verify(button(t.page, "Update Now").enabled, c[0] + ": Update Now can be tried again");
        }
        // A lock an earlier pacman left: said so, with Omarchy's terminal.
        const stale = {};
        stale[testCase.runFile] = runState("done", "stalelock");
        const st = make(available(), {runner: true, files: stale});
        verify(row(st.page, "An earlier update stopped before it finished."));
        verify(button(st.page, "Update in Terminal…"));
        // Once the checked databases were the system's, "Nothing was changed" is not said.
        const synced = {};
        synced[testCase.runFile] = runState("done", "failed", {synced: true});
        const fs = make(available(), {runner: true, files: synced});
        verify(row(fs.page, "The update could not be installed."));
        verify(!row(fs.page, "The update could not be installed. Nothing was changed."));
        synced[testCase.runFile] = runState("done", "terminal", {synced: true});
        compare(row(make(available(), {runner: true, files: synced}).page, "This update asks questions that need Omarchy's terminal.").subtitle,
            "The updates were not installed. Omarchy's update asks them in its terminal and installs everything listed here.");
        const files = {};
        files[testCase.runFile] = runState("done", "failed-partial", {snapshot: "made"});
        compare(row(make(available(), {runner: true, files: files}).page, "The update stopped before it finished.").subtitle,
            "Try Update Now again. The snapshot saved before the update can be chosen when the computer starts.");
        // Update in Terminal…: Omarchy's update in its terminal, then the check that waits for it.
        files[testCase.runFile] = runState("done", "terminal");
        const term = make(available(), {runner: true, files: files});
        button(term.page, "Update in Terminal…").clicked();
        compare(term.backend.launches, [["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"]]);
        verify(term.updates.updateRunning);
        // A migration left: Finish in Terminal… runs Omarchy's migrations there.
        files[testCase.runFile] = runState("done", "done", {deferred: ["migrations", "aur"]});
        const mig = make(answer("up-to-date"), {runner: true, files: files});
        verify(row(mig.page, "Some of Omarchy's last steps need its terminal."));
        button(mig.page, "Finish in Terminal…").clicked();
        compare(mig.backend.launches, [["omarchy-launch-floating-terminal-with-presentation", "omarchy-migrate"]]);
        files[testCase.runFile] = runState("done", "done", {deferred: ["aur"]});
        verify(row(make(answer("up-to-date"), {runner: true, files: files}).page, "Apps from the AUR are updated in Omarchy's terminal."));
        // Nothing to say after a cancelled dialog or an update with nothing to install.
        for (const quiet of ["cancelled", "up-to-date", "done"]) {
            files[testCase.runFile] = runState("done", quiet);
            const q = make(answer("up-to-date"), {runner: true, files: files});
            verify(!shown(q.page, i => i.title !== undefined && /Omarchy's terminal|Nothing was changed|newer version/.test(i.title)), quiet + " says nothing more");
        }
        // The startup files could not be prepared: no restart is offered, even with Omarchy's marker.
        files[testCase.runFile] = runState("done", "bootimage", {restart: "restart"});
        files["/home/u/.local/state/omarchy/reboot-required"] = "";
        const boot = make(answer("up-to-date"), {runner: true, files: files});
        verify(row(boot.page, "Don't restart this computer yet"));
        verify(!boot.updates.restartNeeded);
        verify(!button(boot.page, "Restart…"));
        // A log out is enough when only Grassfield changed.
        const logout = {};
        logout[testCase.runFile] = runState("done", "done", {restart: "logout"});
        const l = make(answer("up-to-date"), {runner: true, files: logout});
        verify(l.updates.logoutNeeded && !l.updates.restartNeeded);
        verify(row(l.page, "Log out to finish updating Grassfield"));
    }

    // Without the runner installed (a build before step 3, or no pkexec), Update Now is Omarchy's terminal (U11).
    function test_withoutTheRunnerUpdateNowOpensTheTerminal() {
        const t = make(available(), {runner: false});
        verify(row(t.page, "Omarchy's update installs everything listed here."));
        button(t.page, "Update Now").clicked();
        compare(t.backend.launches, [["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"]]);
    }

    // A dev session: the state is read, nothing is changed or started.
    function test_devGuard() {
        const t = make(available(), {dev: true, channel: "stable"});
        button(t.page, "Update Now").clicked();
        compare(t.backend.launches, []);
        verify(!t.updates.updateRunning);
        const r = make(available(), {dev: true, runner: true});
        button(r.page, "Update Now").clicked();
        compare(r.backend.launches, [], "nor the runner");
        verify(!r.updates.running);
        t.updates.setChannel("beta", "beta");
        t.updates.endSession("logout");
        compare(t.backend.actions, []);
        compare(t.backend.launches, []);
        verify(t.system.suppressedNote);
        verify(shown(t.page, i => i.text === "dev: not applied"));
    }
}
