import QtQuick
import QtTest
import "../../ui/Grassfield/Ui/SoftwareUpdateLogic.js" as Logic

// Software Update step 2 (ADR-0033 d; docs/specs/updates.md A9): the checker's answers read, the last success kept through a
// failure, the releases counted for the badge, each new version and `blocking` episode announced once, versions as people
// read them, the checker's arguments and the automatic schedule (fake clock); and what Settings' pane reads from them: the
// file, the channel, whether the build can set updates up, the notes in the session's language, the pane's view.
TestCase {
    name: "SoftwareUpdate"

    function answer(state, extra) {
        return Object.assign({version: 1, state: state, checkedAt: "2026-10-28T10:00:00Z"}, extra || {});
    }

    function available(gf, om) {
        return answer("available", {
            channel: "stable",
            grassfield: {installed: "1.0.0-1", available: gf || null, notes: [], notesError: null},
            omarchy: {installed: "4.0.4-1", available: om || null},
            others: 2,
            otherPackages: [{name: "glibc", installed: "2.42-1", available: "2.42-2"}, {name: "linux", installed: "6.18.1-1", available: "6.18.2-1"}]
        });
    }

    function test_onlyTheCheckersAnswersAreRead() {
        compare(Logic.parse(JSON.stringify(available("1.0.1-1"))).state, "available");
        for (const s of ["not-set-up", "repair", "blocking", "up-to-date", "available", "failed", "update-running", "busy"])
            compare(Logic.parse(JSON.stringify(answer(s))).state, s, s);
        compare(Logic.parse(""), null, "nothing printed");
        compare(Logic.parse("not json"), null);
        compare(Logic.parse("[1]"), null, "not an object");
        compare(Logic.parse("null"), null);
        compare(Logic.parse(JSON.stringify({version: 2, state: "available"})), null, "another version");
        compare(Logic.parse(JSON.stringify({version: 1, state: "installing"})), null, "an unknown state");
        compare(Logic.parse(undefined), null);
        compare(Logic.parse("{\"version\":1,\"state\":\"failed\",\"x\":\"" + "a".repeat(310 * 1024) + "\"}"), null, "longer than any answer");
    }

    function test_aRunWithoutAnAnswerIsAFailure() {
        const a = Logic.noAnswer(Date.UTC(2026, 9, 28, 10, 0, 0), "the checker could not start");
        compare([a.version, a.state, a.error, a.message, a.checkedAt], [1, "failed", "unavailable", "the checker could not start", "2026-10-28T10:00:00Z"]);
    }

    function test_theLastSuccessIsKeptThroughAFailure() {
        let f = Logic.combine(Logic.normalize(null), available("1.0.1-1", "4.0.6-1"));
        compare(f.state, "available");
        compare(f.previous, undefined);
        compare(Logic.releases(f), 2, "Grassfield and Omarchy");
        f = Logic.combine(f, answer("failed", {error: "offline", lastSuccessAt: "2026-10-28T10:00:00Z"}));
        compare([f.state, f.error], ["failed", "offline"]);
        compare(f.previous.grassfield.available, "1.0.1-1", "what was found stays");
        compare(f.previous.otherPackages.length, 2);
        compare(Logic.releases(f), 2, "the badge stays through a failure");
        f = Logic.combine(f, answer("update-running"));
        compare(f.previous.omarchy.available, "4.0.6-1", "and while omarchy update runs");
        f = Logic.combine(f, answer("blocking", {episode: "2026-10-28T09:00:00Z"}));
        compare(Logic.releases(f), 2);
        f = Logic.combine(f, answer("up-to-date", {grassfield: {installed: "1.0.1-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}}));
        compare(f.previous, undefined, "a success replaces it");
        compare(Logic.releases(f), 0);
        f = Logic.combine(Logic.combine(f, available("1.0.2-1")), answer("not-set-up"));
        compare(f.previous, undefined, "turned off: Grassfield's release is no longer checked, nothing kept");
        compare(Logic.releases(f), 0);
    }

    // Grassfield updates off (not-set-up) still lists the system's updates (the integrator's decision of 2026-10-28): Omarchy's
    // release counts, is announced, shows in the pane, and stays through a failure.
    function test_turnedOffStillListsTheSystemsUpdates() {
        const off = answer("not-set-up", {channel: null, grassfield: {installed: "1.0.0-1", available: null, notes: [], notesError: null},
            omarchy: {installed: "4.0.4-1", available: "4.0.6-1"}, others: 1, otherPackages: [{name: "linux", installed: "6.18.1-1", available: "6.18.2-1"}]});
        let f = Logic.combine(Logic.normalize(null), off);
        compare(Logic.releases(f), 1, "Omarchy's release");
        compare(Logic.news(Logic.normalize(null), off).map(n => n.id), ["omarchy 4.0.6-1"]);
        const v = Logic.view(f, false);
        compare([v.kind, v.omarchy.available, v.grassfield, v.others, v.otherPackages.length], ["not-set-up", "4.0.6-1", null, 1, 1]);
        f = Logic.combine(f, answer("failed", {error: "offline"}));
        compare(f.previous.state, "not-set-up", "a failure keeps what the last check found");
        compare(Logic.releases(f), 1);
        compare(Logic.view(f, false).omarchy.available, "4.0.6-1");
    }

    function test_aBusyAnswerChangesNothing() {
        compare(Logic.combine(Logic.normalize(null), answer("busy")), null);
        compare(Logic.combine(Logic.normalize(null), null), null);
    }

    function test_theFileKeepsTheAnnouncedVersionsAndThePendingLogout() {
        let f = Logic.normalize({version: 1, state: "up-to-date", announced: ["grassfield 1.0.1-1", 7, null], logoutPending: true});
        compare(f.announced, ["grassfield 1.0.1-1"], "only strings");
        f = Logic.combine(f, available("1.0.2-1"));
        compare(f.announced, ["grassfield 1.0.1-1"]);
        compare(f.logoutPending, true);
        f = Logic.withLogoutPending(f, false);
        compare(f.logoutPending, undefined);
        compare(Logic.normalize({version: 3, announced: ["x"]}).announced, [], "another version reads as empty");
        compare(Logic.normalize("junk").state, "");
        let many = Logic.normalize(null);
        for (let i = 0; i < 40; i++)
            many = Logic.withAnnounced(many, [{id: "omarchy 4.0." + i + "-1"}]);
        compare(many.announced.length, 32, "bounded, the oldest dropped");
        compare(many.announced[31], "omarchy 4.0.39-1");
    }

    // ADR-0041 step 2b (U31): a toolkit package replaced under the running session asks for a log out, once per session,
    // through a restart of the shell; the session's start is Hyprland's.
    function toolkitAnswer(state, at, moved) {
        return answer(state, {toolkit: {record: true, packages: [{name: "qt6-base", installed: "6.12.0-1", installedAt: at, built: "6.11.2-1", moved: moved}]}});
    }

    // U33 with U31: the end of an Update Now run that asks for a restart (or a log out) covers the toolkit's log out in this
    // session: its notice is not posted after it, in this session only (the integrator's review of b6fdedf).
    function test_aRunsRestartCoversTheToolkitsLogOut() {
        const start = Logic.timeOf("2026-10-28T10:00:00Z");
        const a = toolkitAnswer("up-to-date", "2026-10-28T11:00:00Z", true);
        compare(Logic.news(Logic.normalize(null), a, start).map(n => n.kind), ["toolkit"], "without a run's end, the toolkit is announced");
        const covered = Logic.withToolkitCovered(Logic.normalize(null), start);
        compare(covered.announced, ["toolkit " + start]);
        compare(Logic.news(covered, a, start).map(n => n.kind), [], "after a run's restart: nothing more to post");
        verify(Logic.toolkitLogout(a, start), "the log out stays due for the pane's row");
        compare(Logic.withToolkitCovered(covered, start).announced, ["toolkit " + start], "marked once");
        compare(Logic.news(covered, a, start + 1).map(n => n.kind), ["toolkit"], "another session is not covered");
    }

    function test_aToolkitReplacedUnderTheSessionAsksForALogOutOnce() {
        const start = Logic.timeOf("2026-10-28T10:00:00Z");
        const signature = "ab12cd_" + Math.floor(start / 1000) + "_42";
        compare(Logic.sessionStart(signature, start + 60000), start, "the session's start from the instance signature, before the shell's own");
        compare(Logic.sessionStart(signature, start - 60000), start - 60000, "never later than the shell's start (a later signature would hide installs)");
        compare(Logic.sessionStart("", 5), 5, "the shell's own start without a signature");
        compare(Logic.sessionStart(undefined, 5), 5);
        compare(Logic.sessionStart("junk", 5), 5);
        compare(Logic.sessionStart("ab_0_1", 5), 5, "a zero time is no time");
        const a = toolkitAnswer("up-to-date", "2026-10-28T11:00:00Z", true);
        verify(Logic.toolkitLogout(a, start), "installed after the session started");
        verify(!Logic.toolkitLogout(a, Logic.timeOf("2026-10-28T12:00:00Z")), "installed before: the session already runs on it");
        // An unreadable install time (a pacman database outside its default path): asked once, then recorded, so the next
        // session does not ask again for the same installed version (the review of e03013d, minor).
        const unknown = toolkitAnswer("failed", null, false);
        verify(Logic.toolkitLogout(unknown, start, {}), "an unreadable time counts as this session once, whatever the record says");
        const asked = Logic.withToolkitAsked(Logic.normalize(null), Logic.toolkitReplaced(unknown, start, {}));
        compare(Logic.toolkitAsked(asked), {"qt6-base": "6.12.0-1"}, "...and the installed version is recorded as asked for");
        verify(!Logic.toolkitLogout(unknown, start, Logic.toolkitAsked(asked)), "the same installed version asks no more");
        verify(Logic.toolkitLogout(answer("failed", {toolkit: {record: true, packages: [{name: "qt6-base", installed: "6.12.1-1", installedAt: null, built: "6.11.2-1", moved: true}]}}), start, Logic.toolkitAsked(asked)), "another version asks again");
        compare(Logic.toolkitAsked(Logic.combine(asked, answer("up-to-date"))), {"qt6-base": "6.12.0-1"}, "kept through an answer");
        compare(Logic.toolkitAsked(Logic.withToolkitAsked(asked, Logic.toolkitReplaced(a, start, {}))), {"qt6-base": "6.12.0-1"}, "a readable time records nothing");
        compare(Logic.toolkitAsked({toolkitAsked: {a: 1, b: "x"}}), {b: "x"}, "strings only");
        // A shell restarted in the same session after the log out was asked on an unreadable time: the file's flag and the
        // announcement marked with this session's start keep it due; another session's flag is stale.
        let due = Logic.withLogoutPending(Logic.withAnnounced(Logic.combine(asked, unknown), [{id: "toolkit " + start}]), false, true);
        verify(!Logic.toolkitLogout(due, start, Logic.toolkitAsked(due)), "the versions asked for say nothing more...");
        verify(Logic.toolkitDueFromFile(due, start), "...but the file says the log out was found due in this session");
        verify(!Logic.toolkitDueFromFile(due, start + 1), "another session's flag is stale");
        verify(!Logic.toolkitDueFromFile(Logic.withLogoutPending(due, true, false), start), "no flag, nothing due");
        verify(Logic.toolkitLogout(toolkitAnswer("up-to-date", "2026-10-28T11:00:00Z", false), start), "a pkgrel rebuild replaces the file too: a log out, without a move");
        verify(!Logic.toolkitLogout(answer("up-to-date", {toolkit: {record: false, packages: []}}), start), "nothing listed");
        verify(!Logic.toolkitLogout(answer("up-to-date", {toolkit: null}), start), "no list");
        verify(!Logic.toolkitLogout(answer("up-to-date", {toolkit: {packages: "junk"}}), start), "not a list");
        verify(!Logic.toolkitLogout(answer("up-to-date", {toolkit: {packages: [{installed: 5}, "x", null]}}), start), "not entries");
        compare(Logic.toolkitMoved(a).length, 1, "the moved list is for the log line");
        compare(Logic.toolkitMoved(toolkitAnswer("up-to-date", "2026-10-28T11:00:00Z", false)).length, 0);
        // The crash-restart scenario (the review of 9043ac4, major 2): log in 09:00, the upgrade at 10:00, the shell
        // crashes and is restarted at 10:05: it reads the session's start from the signature, not its own.
        const login = Logic.timeOf("2026-10-28T09:00:00Z");
        const restarted = Logic.timeOf("2026-10-28T10:05:00Z");
        const upgrade = toolkitAnswer("up-to-date", "2026-10-28T10:00:00Z", true);
        verify(Logic.toolkitLogout(upgrade, Logic.sessionStart("ab12cd_" + Math.floor(login / 1000) + "_1", restarted)), "after the restart the upgrade still asks for a log out");
        verify(!Logic.toolkitLogout(upgrade, restarted), "the shell's own start would have hidden it");
        let items = Logic.news(Logic.normalize(null), a, start);
        compare(items.length, 1);
        compare(items[0].kind, "toolkit");
        compare(items[0].id, "toolkit " + start, "once per session: the id is the session's start, whatever the versions");
        let f = Logic.withAnnounced(Logic.combine(Logic.normalize(null), a), items);
        compare(Logic.news(f, a, start), [], "announced once");
        compare(Logic.news(f, toolkitAnswer("up-to-date", "2026-10-28T11:30:00Z", true), start), [], "a later update in the same session announces nothing more");
        compare(Logic.toolkitPackages(f).length, 1, "the file keeps the list");
        f = Logic.withLogoutPending(f, true, true);
        compare(f.logoutPending, true);
        compare(f.toolkitLogout, true, "two flags: Grassfield's own log out and the toolkit's");
        f = Logic.combine(f, answer("update-running"));
        compare(Logic.toolkitPackages(f).length, 1, "an answer without the list (update-running) keeps the file's");
        compare(f.toolkitLogout, true, "and the flags");
        verify(Logic.toolkitLogout(f, start, Logic.toolkitAsked(f)), "a restarted shell re-reads the log out from the file");
        f = Logic.withLogoutPending(f, false, true);
        compare(f.logoutPending, undefined, "the toolkit's alone: the pane's generic title");
        compare(f.toolkitLogout, true);
        f = Logic.withLogoutPending(f, true, false);
        compare(f.logoutPending, true, "Grassfield's own alone");
        compare(f.toolkitLogout, undefined);
        compare(Logic.news(Logic.normalize(null), a, Logic.timeOf("2026-10-28T12:00:00Z")), [], "nothing to announce when it was installed before the session");
        compare(Logic.news(Logic.normalize(null), available("1.0.1-1"), start).map(n => n.kind), ["grassfield"], "an answer without the list announces as before");
    }

    function test_eachNewReleaseIsAnnouncedOnce() {
        let f = Logic.normalize(null);
        let items = Logic.news(f, available("1.0.1-1", "4.0.6-1"));
        compare(items.map(n => n.id), ["grassfield 1.0.1-1", "omarchy 4.0.6-1"]);
        compare(items[0].installed, "1.0.0-1");
        f = Logic.withAnnounced(Logic.combine(f, available("1.0.1-1", "4.0.6-1")), items);
        compare(Logic.news(f, available("1.0.1-1", "4.0.6-1")), [], "never twice");
        compare(Logic.news(f, available("1.0.2-1", "4.0.6-1")).map(n => n.id), ["grassfield 1.0.2-1"], "a newer version is new");
        compare(Logic.news(f, answer("up-to-date")), []);
        compare(Logic.news(f, answer("failed")), []);
    }

    function test_aBlockingEpisodeIsAnnouncedOnce() {
        let f = Logic.normalize(null);
        const a = answer("blocking", {episode: "2026-10-28T09:00:00Z"});
        const items = Logic.news(f, a);
        compare(items.map(n => n.id), ["blocking 2026-10-28T09:00:00Z"]);
        f = Logic.withAnnounced(Logic.combine(f, a), items);
        compare(Logic.news(f, a), [], "still the same episode");
        compare(Logic.news(f, answer("blocking", {episode: "2026-10-29T09:00:00Z"})).length, 1, "a new episode");
        compare(Logic.news(f, answer("blocking")), [], "no episode, nothing to name");
    }

    function test_releasesCountTheBadge() {
        compare(Logic.releases(Logic.normalize(null)), 0);
        compare(Logic.releases(available("1.0.1-1")), 1);
        compare(Logic.releases(available(null, "4.0.6-1")), 1);
        compare(Logic.releases(available("1.0.1-1", "4.0.6-1")), 2);
        compare(Logic.releases(answer("up-to-date")), 0);
        compare(Logic.releases(answer("available")), 0, "an answer without releases counts none");
    }

    function test_versionsAsPeopleReadThem() {
        compare(Logic.displayVersion("1.0.1-1"), "1.0.1");
        compare(Logic.displayVersion("1.1.0beta1-3"), "1.1.0-beta1");
        compare(Logic.displayVersion("1.0.0rc1-5"), "1.0.0-rc1");
        compare(Logic.displayVersion("2:4.0.6-1"), "4.0.6");
        compare(Logic.displayVersion("4.0.6"), "4.0.6");
        compare(Logic.rebuildOf("1.0.1-3", "1.0.1-4"), "4", "a rebuild for a new Hyprland (O7)");
        compare(Logic.rebuildOf("1.0.0-3", "1.0.1-3"), "");
        compare(Logic.rebuildOf("", "1.0.1-1"), "");
        compare(Logic.releaseName("1.0.1-4", "1.0.1-3"), "1.0.1-4");
        compare(Logic.releaseName("1.0.1-1", "1.0.0-1"), "1.0.1");
        compare(Logic.releaseName("1.1.0beta1-3", "1.0.1-3"), "1.1.0-beta1");
    }

    function test_theCheckersArguments() {
        compare(Logic.checkerArgs("/usr/lib/grassfield/grassfield-update-check", false, false), ["/usr/lib/grassfield/grassfield-update-check"]);
        compare(Logic.checkerArgs("c", true, false), ["c", "--offline"]);
        compare(Logic.checkerArgs("c", false, true), ["c", "--after-update-lock"]);
        compare(Logic.checkerArgs("c", true, true), ["c", "--offline", "--after-update-lock"]);
    }

    function test_theAutomaticSchedule() {
        const min = 60 * 1000, hour = 60 * min, start = Date.UTC(2026, 9, 28, 8, 0, 0);
        const first = 10 * min, every = 6 * hour;
        compare(Logic.nextAutomatic(start, 0, 0, first, every), start + first, "never checked: 10 minutes after the start");
        compare(Logic.nextAutomatic(start, start - 7 * hour, 0, first, every), start + first, "checked long ago");
        compare(Logic.nextAutomatic(start, start - 1 * hour, 0, first, every), start + 5 * hour, "a restarted shell waits for the 6 hours");
        compare(Logic.nextAutomatic(start, start + 30 * min, 0, first, every), start + 30 * min + every, "then every 6 hours");
        compare(Logic.nextAutomatic(start, start + 30 * min, start + 45 * min, first, every), start + 45 * min, "the checker's retry (U3) comes first");
        compare(Logic.timeOf("2026-10-28T10:00:00Z"), Date.UTC(2026, 9, 28, 10, 0, 0));
        compare(Logic.timeOf(undefined), 0);
        compare(Logic.timeOf("never"), 0);
    }

    function test_meteredConnections() {
        verify(Logic.metered("yes\n"));
        verify(Logic.metered("--\nyes (guessed)\n"), "any device");
        verify(!Logic.metered("no\n"));
        verify(!Logic.metered("unknown\n"));
        verify(!Logic.metered(""), "an unreadable answer is not metered");
    }

    function test_settingsReadsTheShellsFile() {
        const f = Logic.fromText(JSON.stringify(Object.assign(available("1.0.1-1"), {announced: ["grassfield 1.0.1-1"], logoutPending: true})));
        compare(f.state, "available");
        compare(f.announced, ["grassfield 1.0.1-1"]);
        compare(f.logoutPending, true);
        compare(Logic.releases(f), 1);
        compare(Logic.fromText("").state, "", "no file yet");
        compare(Logic.fromText("{").state, "", "half written");
        compare(Logic.fromText("[]").state, "");
        compare(Logic.fromText(undefined).state, "");
        compare(Logic.fromText("{\"version\":1,\"state\":\"up-to-date\",\"x\":\"" + "a".repeat(1100 * 1024) + "\"}").state, "", "longer than the shell's file can be");
    }

    function test_theChannelAsPrinted() {
        for (const c of ["stable", "beta", "custom", "repair", "off"])
            compare(Logic.channelOf(c + "\n"), c);
        compare(Logic.channelOf("  beta  "), "beta");
        compare(Logic.channelOf("grassfield-channel-set: missing /usr/share/grassfield/pacman/repository.conf"), "");
        compare(Logic.channelOf(""), "");
        compare(Logic.channelOf("Beta"), "");
    }

    // R7-INS-03: the 7 days. The clock starts at the first refusal, is not moved by a later one, and ends with an update that went through.
    function test_theHoldWaitIsSevenDays() {
        const day = 24 * 60 * 60 * 1000, t0 = 1700000000000;
        const none = Logic.normalize(null);
        verify(!Logic.holdWaitOver(none, t0 + 30 * day), "no refusal recorded: never over");
        const first = Logic.withHoldRefused(none, t0);
        compare(first.holdRefusedAt, t0);
        compare(Logic.withHoldRefused(first, t0 + 3 * day).holdRefusedAt, t0, "a later refusal does not move the clock");
        verify(!Logic.holdWaitOver(first, t0), "the first moment");
        verify(!Logic.holdWaitOver(first, t0 + 7 * day - 1), "one millisecond short of 7 days");
        verify(Logic.holdWaitOver(first, t0 + 7 * day), "exactly 7 days is over");
        verify(Logic.holdWaitOver(first, t0 + 30 * day));
        verify(!Logic.holdWaitOver(first, t0 - day), "a stamp in the future is not over");
        verify(!Logic.holdWaitStarted(Logic.withoutHoldRefused(first)), "cleared by an update that went through");
        verify(Logic.holdWaitStarted(first));
        for (const bad of ["x", -5, 0, NaN, null, {}]) {
            const f = Object.assign({}, none, {holdRefusedAt: bad});
            verify(!Logic.holdWaitOver(f, t0 + 30 * day), "a garbage stamp is not over: " + JSON.stringify(bad));
            compare(Logic.withHoldRefused(f, t0).holdRefusedAt, t0, "a garbage stamp is replaced by a real one");
        }
        // A checker answer keeps the clock.
        compare(Logic.combine(first, {version: 1, state: "up-to-date", checkedAt: "2026-11-08T10:00:00Z"}).holdRefusedAt, t0);
    }

    // ADR-0041 step 2a: what `grassfield-channel-set hold-state` printed; anything else shows no hold row.
    function test_theHoldAsPrinted() {
        for (const h of ["held", "allowed", "allowed-moved", "none"])
            compare(Logic.holdOf(h + "\n"), h);
        compare(Logic.holdOf("  held  "), "held");
        compare(Logic.holdOf("held\nallowed"), "held");
        for (const bad of ["", "Held", "hold", "unheld", "allowed moved", "grassfield-channel-set: pacman failed"])
            compare(Logic.holdOf(bad), "");
        compare(Logic.holdOf(undefined), "");
    }

    function test_aPrereleaseBuildSetsUpOnBeta() {
        compare(Logic.defaultChannel("1.0.0-rc2\n"), "beta");
        compare(Logic.defaultChannel("1.1.0-beta3"), "beta");
        compare(Logic.defaultChannel("1.0.0"), "stable");
        // Missing, empty, unreadable or malformed: only beta is safe (ADR-0033 O15b).
        compare(Logic.defaultChannel(""), "beta");
        compare(Logic.defaultChannel(undefined), "beta");
        compare(Logic.defaultChannel("1.0.0-rc"), "beta", "not a version the build writes");
        compare(Logic.defaultChannel("1.0.0.rc2"), "beta");
        compare(Logic.defaultChannel("unknown"), "beta");
        compare(Logic.defaultChannel("1.0.0\n1.0.0"), "beta");
        verify(Logic.stableAllowed("1.0.0\n"));
        verify(Logic.stableAllowed("  2.10.3 "));
        for (const v of ["1.0.0-rc2", "1.1.0-beta3", "", undefined, null, "1.0", "x"])
            verify(!Logic.stableAllowed(v), "no stable for " + v);
    }

    function test_aBuildWithoutKeyOrHostCannotSetUp() {
        const conf = (base, fp) => "# comment\nGRASSFIELD_REPO_BASE=" + base + "\nGRASSFIELD_REPO_MIRRORS=\nGRASSFIELD_SIGNING_FINGERPRINT=" + fp + "\n";
        const fp = "0123456789ABCDEF0123456789ABCDEF01234567";
        verify(!Logic.buildReady(conf("https://packages.grassfield.site", "")), "a build made without the key (the shipped repository.conf names it since 2026-11-04)");
        verify(Logic.buildReady(conf("https://packages.grassfield.site", fp)), "the host with the owner's key");
        verify(!Logic.buildReady(conf("https://packages.grassfield.invalid", "")), "the old placeholder");
        verify(!Logic.buildReady(conf("https://packages.grassfield.invalid", fp)), "a key but no host");
        verify(!Logic.buildReady(conf("https://packages.example.org", "")), "a host but no key");
        verify(!Logic.buildReady(conf("https://invalid/x", fp)));
        verify(!Logic.buildReady(conf("http://packages.example.org", fp)), "https only");
        verify(Logic.buildReady(conf("https://packages.example.org", fp)));
        verify(Logic.buildReady(conf("https://packages.example.org:8443/grassfield", fp)));
        verify(Logic.buildReady(conf("file:///srv/repo", fp)), "the container tests' base");
        verify(!Logic.buildReady(""), "no repository.conf");
        verify(!Logic.buildReady(undefined));
    }

    function test_notesInTheSessionsLanguage() {
        const gf = {installed: "1.0.0-1", available: "1.0.2-1", notes: [
                {version: "1.0.2-1", date: "2026-11-02", notes: {en: "Faster Dock.", fr: "Dock plus rapide."}},
                {version: "1.0.1-1", date: "2026-10-30", notes: {en: "Fixes."}},
                {version: "1.0.0-9", date: "x", notes: "junk"}, null]};
        compare(Logic.notesFor(gf, "fr_FR"), [{version: "1.0.2-1", date: "2026-11-02", text: "Dock plus rapide."}, {version: "1.0.1-1", date: "2026-10-30", text: "Fixes."}],
            "French where it is given, English otherwise, newest first");
        compare(Logic.notesFor(gf, "en_GB")[0].text, "Faster Dock.");
        compare(Logic.notesFor(gf, "de")[0].text, "Faster Dock.");
        compare(Logic.notesFor({notes: []}, "fr"), []);
        compare(Logic.notesFor(null, "fr"), []);
    }

    function test_thePanesView() {
        let v = Logic.view(Logic.normalize(null), false);
        compare(v.kind, "never");
        compare(v.grassfield, null);
        compare(Logic.view(Logic.normalize(null), true).kind, "checking");
        v = Logic.view(available("1.0.1-1", "4.0.6-1"), false);
        compare([v.kind, v.grassfield.available, v.omarchy.available, v.others, v.otherPackages.length, v.channel], ["available", "1.0.1-1", "4.0.6-1", 2, 2, "stable"]);
        compare(v.installed, {grassfield: "1.0.0-1", omarchy: "4.0.4-1"});
        verify(!v.repair);
        // A failure keeps what the last success found, with its time.
        const failed = Logic.combine(Logic.combine(Logic.normalize(null), available("1.0.1-1")), answer("failed", {error: "offline", checkedAt: "2026-10-28T12:00:00Z"}));
        v = Logic.view(failed, false);
        compare([v.kind, v.error, v.grassfield.available, v.lastSuccessAt, v.checkedAt], ["failed", "offline", "1.0.1-1", Date.UTC(2026, 9, 28, 10, 0, 0), Date.UTC(2026, 9, 28, 12, 0, 0)]);
        compare(Logic.view(answer("failed"), false).error, "unavailable");
        v = Logic.view(answer("up-to-date", {channel: "custom", grassfield: {installed: "1.0.1-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}}), false);
        compare([v.kind, v.repair, v.grassfield, v.others], ["up-to-date", true, null, 0], "a custom channel is repaired");
        verify(Logic.view(answer("repair"), false).repair);
        compare(Logic.view(answer("busy"), false).kind, "never", "busy is no state of the pane");
        compare(Logic.view(answer("update-running"), false).kind, "update-running");
    }

    function test_aNewAnswerEndsTheWait() {
        const before = answer("up-to-date");
        verify(!Logic.answered(before, Object.assign({}, before, {logoutPending: true})), "the pending logout written alone");
        verify(Logic.answered(before, answer("available", {checkedAt: "2026-10-28T10:05:00Z"})));
        verify(Logic.answered(Logic.normalize(null), before), "the first answer");
        verify(!Logic.answered(before, Logic.normalize(null)));
    }
    // Update Now's run (ADR-0033 "Step 3", s3.5): the runner's state, read strictly.
    function test_runState() {
        const op = "0123456789abcdef0123456789abcdef";
        const good = {version: 1, op: op, pid: 42, startTime: "777", phase: "configuring", result: "", restart: "", snapshot: "made",
            deferred: ["aur", "x"], startedAt: 1000, finishedAt: 0};
        const r = Logic.parseRun(JSON.stringify(good));
        compare(r.op, op);
        compare(r.pid, 42);
        compare(r.startTime, "777");
        compare(r.phase, "configuring");
        compare(r.snapshot, "made");
        compare(r.deferred, ["aur"], "only the known deferred steps");
        compare(Logic.parseRun(JSON.stringify(Object.assign({}, good, {phase: "done", result: "done", restart: "restart"}))).restart, "restart");
        for (const bad of [Object.assign({}, good, {version: 2}), Object.assign({}, good, {op: "x"}), Object.assign({}, good, {phase: "running"}),
                Object.assign({}, good, {phase: "done", result: "weird"}), Object.assign({}, good, {result: "done"})])
            compare(Logic.parseRun(JSON.stringify(bad)), null, JSON.stringify(bad));
        compare(Logic.parseRun("{half"), null);
        compare(Logic.parseRun(""), null);
        compare(Logic.parseRun("x".repeat(5000)), null);
        compare(Logic.parseRun(JSON.stringify(Object.assign({}, good, {pid: -1, startTime: "x1"}))).pid, 0);
        compare(Logic.parseRun(JSON.stringify(good)).synced, false);
        compare(Logic.parseRun(JSON.stringify(Object.assign({}, good, {phase: "done", result: "stalelock", synced: true}))).synced, true);
        compare(Logic.parseRun(JSON.stringify(Object.assign({}, good, {synced: "true"}))).synced, false, "only a JSON true");
        // The helper `last` names, without a runner's state.
        compare(Logic.helperRun(op + "\n").op, op);
        compare(Logic.helperRun(op).phase, "authorizing");
        for (const bad of ["", "x", op + "0", "../" + op, op.toUpperCase()])
            compare(Logic.helperRun(bad), null, bad);
    }

    // The start time of /proc/<pid>/stat, whose command name may hold spaces and parentheses.
    function test_startTimeOf() {
        compare(Logic.startTimeOf("42 (bash) S 1 42 42 0 -1 4194560 100 0 0 0 0 0 0 0 20 0 1 0 777 1000 100"), "777");
        compare(Logic.startTimeOf("42 (a) b) (c) S 1 42 42 0 -1 4194560 100 0 0 0 0 0 0 0 20 0 1 0 888 1000 100"), "888");
        compare(Logic.startTimeOf("42 (bash) S 1 42"), "");
        compare(Logic.startTimeOf(""), "");
    }

    // The helper's progress line and the run's one percentage (0-5 checking, 5-45 downloading, 45-95 installing, 95-100 the end).
    function test_runProgress() {
        compare(Logic.parseProgress("downloading 3 10\n"), {phase: "downloading", done: 3, total: 10});
        compare(Logic.parseProgress("installing 12 10"), {phase: "installing", done: 10, total: 10}, "never more than the total");
        compare(Logic.parseProgress("checking"), {phase: "checking", done: 0, total: 0});
        compare(Logic.parseProgress("rm -rf /"), null);
        compare(Logic.parseProgress(""), null);
        compare(Logic.percentOf("checking", 0, 0), -1);
        compare(Logic.percentOf("downloading", 0, 10), 5);
        compare(Logic.percentOf("downloading", 10, 10), 45);
        compare(Logic.percentOf("downloading", 0, 0), -1, "nothing to download is not 0 %");
        compare(Logic.percentOf("installing", 5, 10), 70);
        compare(Logic.percentOf("installing", 10, 10), 95);
        compare(Logic.percentOf("finishing", 0, 0), 95);
        compare(Logic.percentOf("configuring", 0, 0), 97);
    }

    // The notice the end of a run deserves (U33), by its outcome.
    function test_runNotice() {
        const done = (result, extra) => Logic.parseRun(JSON.stringify(Object.assign({version: 1, op: "0123456789abcdef0123456789abcdef", pid: 1,
            startTime: "1", phase: "done", result: result, restart: "", deferred: [], startedAt: 1, finishedAt: 2}, extra || {})));
        compare(Logic.runNotice(done("done", {restart: "restart"})), "restart");
        compare(Logic.runNotice(done("done", {restart: "logout"})), "logout");
        compare(Logic.runNotice(done("done", {deferred: ["migrations", "aur"]})), "migrations");
        compare(Logic.runNotice(done("done", {deferred: ["aur"]})), "aur", "the pane says the AUR's apps wait for Omarchy's terminal");
        compare(Logic.runNotice(done("done")), "installed");
        compare(Logic.runNotice(done("done", {restart: "restart", deferred: ["migrations", "aur"]})), "restart", "what finishes the update first");
        compare(Logic.runNotice(done("bootimage", {restart: "restart"})), "bootimage", "never a restart after a failed startup image");
        compare(Logic.runNotice(done("incompatible")), "incompatible");
        compare(Logic.runNotice(done("terminal")), "terminal");
        compare(Logic.runNotice(done("stalelock")), "terminal");
        compare(Logic.runNotice(done("failed-partial")), "stopped");
        for (const r of ["failed", "space", "power", "busy"])
            compare(Logic.runNotice(done(r)), "failed", r);
        for (const r of ["up-to-date", "cancelled", "denied"])
            compare(Logic.runNotice(done(r)), "", r);
        compare(Logic.runNotice(null), "");
        compare(Logic.runNotice(Logic.parseRun(JSON.stringify({version: 1, op: "0123456789abcdef0123456789abcdef", pid: 1, startTime: "1",
            phase: "configuring", result: "", restart: "", deferred: [], startedAt: 1, finishedAt: 0}))), "", "a run going on");
    }

    // What the pane shows of a run.
    function test_runView() {
        const run = phase => Logic.parseRun(JSON.stringify({version: 1, op: "0123456789abcdef0123456789abcdef", pid: 42, startTime: "777",
            phase: phase, result: phase === "done" ? "terminal" : "", restart: "", deferred: [], startedAt: 1, finishedAt: 0}));
        compare(Logic.runView(null, false, null, false).state, "none");
        compare(Logic.runView(run("authorizing"), true, null, false).phase, "authorizing");
        const dl = Logic.runView(run("authorizing"), true, Logic.parseProgress("downloading 1 4"), true);
        compare([dl.state, dl.phase, dl.done, dl.total, dl.percent], ["running", "downloading", 1, 4, 15]);
        compare(Logic.runView(run("configuring"), true, Logic.parseProgress("finishing"), false).phase, "configuring");
        compare(Logic.runView(run("authorizing"), false, null, false).state, "none", "a runner gone, no helper: nothing");
        compare(Logic.runView(run("authorizing"), false, Logic.parseProgress("installing 1 2"), true).phase, "installing", "the helper outlives the runner");
        const done = Logic.runView(run("done"), false, null, false);
        compare([done.state, done.result], ["done", "terminal"]);
    }

    // ADR-0050: the staged rollout's explanation, from the checker's `rollout` (U34-U36).
    function rolloutAnswer(state, rollout, gf) {
        const a = state === "available" ? available(gf || "1.0.1-1") : answer(state, {channel: "stable",
            grassfield: {installed: "1.0.0-1", available: null, notes: [], notesError: null}, omarchy: {installed: "4.0.4-1", available: null}});
        a.rollout = rollout;
        return a;
    }

    function test_rolloutView() {
        const staged = {descriptor: "ok", cohort: 7, staged: {version: "1.0.2-1", security: false, offerAt: "2026-11-06T10:00:00Z"}, withdrawn: null, security: false};
        let v = Logic.view(Logic.combine(null, rolloutAnswer("up-to-date", staged)), false);
        compare(v.rollout.staged, {version: "1.0.2-1", security: false}, "up to date with a release still being released gradually");
        compare(v.kind, "up-to-date", "the headline stays what the database says");
        v = Logic.view(Logic.combine(Logic.combine(null, rolloutAnswer("up-to-date", staged)), answer("failed", {error: "offline"})), false);
        compare(v.rollout.staged.version, "1.0.2-1", "kept with the last success through a failed check");
        v = Logic.view(Logic.combine(null, rolloutAnswer("available", {descriptor: "ok", cohort: null, staged: null, withdrawn: null, security: true}, "1.0.2-1")), false);
        compare([v.rollout.security, v.grassfield.available], [true, "1.0.2-1"], "the release offered is a security release");
        v = Logic.view(Logic.combine(null, rolloutAnswer("up-to-date", {descriptor: "ok", cohort: 3, staged: null, withdrawn: "1.0.0-1", security: false})), false);
        compare(v.rollout.withdrawn, "1.0.0-1", "the installed release was withdrawn");
        for (const bad of [null, {descriptor: "stale", staged: staged.staged}, {descriptor: "invalid", security: true},
                           {descriptor: "ok", staged: {version: "1.0.2"}, withdrawn: "x\n", security: "yes"}, "ok", []]) {
            v = Logic.view(Logic.combine(null, rolloutAnswer("up-to-date", bad)), false);
            compare(v.rollout, {staged: null, withdrawn: "", security: false}, "nothing to say for " + JSON.stringify(bad));
        }
        v = Logic.view(Logic.combine(null, answer("not-set-up", {rollout: staged})), false);
        compare(v.rollout.staged, null, "not set up: no rollout");
        compare(Logic.view(null, false).rollout, {staged: null, withdrawn: "", security: false}, "before any answer");
    }

    function test_securityAnnouncedOnce() {
        const sec = rolloutAnswer("available", {descriptor: "ok", cohort: 0, staged: null, withdrawn: null, security: true}, "1.0.2-1");
        const items = Logic.news(null, sec, 0);
        compare(items.map(n => n.id), ["security 1.0.2-1"], "a security release is announced as one");
        const after = Logic.withAnnounced(null, items);
        compare(Logic.news(after, available("1.0.2-1"), 0).length, 0, "the same release, its descriptor gone: not announced again");
        compare(Logic.news(Logic.withAnnounced(null, Logic.news(null, available("1.0.2-1"), 0)), sec, 0).length, 0,
                "announced first as a release, then marked security: not again");
    }

    function test_lowBattery() {
        verify(Logic.lowBattery(true, true, 30, 30), "on battery at 30 %: waits");
        verify(Logic.lowBattery(true, true, 5, 30), "on battery at 5 %: waits");
        verify(!Logic.lowBattery(true, true, 31, 30), "on battery above 30 %: checks");
        verify(!Logic.lowBattery(false, true, 5, 30), "on mains: checks");
        verify(!Logic.lowBattery(true, false, 0, 30), "no battery: checks");
        verify(!Logic.lowBattery(undefined, undefined, undefined, 30), "unknown: checks");
    }
}
