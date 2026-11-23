import QtQuick
import QtTest
import "../../shell/search/Commands.js" as Commands

// The command catalogue of Search (ADR-0067 P1/P2): schema, ids, duplicates, keywords en/fr, the five system commands
// as before, and the dispatch by id (every run goes through Commands.run and reaches the function the UI already calls).
TestCase {
    name: "SearchCommands"

    property var calls: []

    readonly property var words: ({
            subtitle: "System command",
            lock: "Lock Screen", lockWord: "lock", sleep: "Sleep", sleepWord: "suspend", restart: "Restart", restartWord: "reboot",
            shutdown: "Shut Down", shutdownWord: "power off", shutdownWord2: "poweroff",
            logout: "Log Out", logoutWord: "sign out", logoutWord2: "log off"
        })
    readonly property var wordsFr: ({
            subtitle: "Commande système",
            lock: "Verrouiller l’écran", lockWord: "verrouiller", sleep: "Suspendre", sleepWord: "veille", restart: "Redémarrer", restartWord: "relancer",
            shutdown: "Éteindre", shutdownWord: "arrêter", shutdownWord2: "extinction",
            logout: "Fermer la session", logoutWord: "déconnexion", logoutWord2: "quitter"
        })

    function acts() {
        const mk = id => () => calls.push(id);
        return {lock: mk("lock"), sleep: mk("sleep"), restart: mk("restart"), shutdown: mk("shutdown"), logout: mk("logout")};
    }

    function reg(t, lockOn) {
        return Commands.build([Commands.systemCommands(t || words, acts(), lockOn !== false)]);
    }

    function ids(r, q) {
        return Commands.match(r, q).map(h => h.cmd.id);
    }

    function init() {
        calls = [];
    }

    function entry(id) {
        return {id: id, title: "T", keywords: [], run: () => {}};
    }

    function test_idRule() {
        for (const ok of ["a", "sys.lock", "win.tile.left-half", "script.0a1b", "set.wifi"])
            verify(Commands.validId(ok), ok);
        for (const bad of ["", "Sys.lock", "1abc", "-a", ".a", "a b", "a_b", "a".repeat(65), "é", 5, null])
            verify(!Commands.validId(bad), String(bad));
        verify(Commands.validId("a".repeat(64)));
    }

    function test_schema() {
        compare(Commands.validate(entry("a.b")), "");
        compare(Commands.validate(null), "not an object");
        compare(Commands.validate({title: "T", run: () => {}}), "bad id");
        compare(Commands.validate({id: "a", title: " ", run: () => {}}), "empty title");
        compare(Commands.validate({id: "a", title: "T"}), "run must be a function");
        compare(Commands.validate({id: "a", title: "T", run: () => {}, keywords: "x"}), "keywords must be strings");
        compare(Commands.validate({id: "a", title: "T", run: () => {}, keywords: [1]}), "keywords must be strings");
        compare(Commands.validate({id: "a", title: "T", run: () => {}, kind: "nope"}), "unknown kind");
        compare(Commands.validate({id: "a", title: "T", run: () => {}, available: "yes"}), "available must be a boolean or a function");
        compare(Commands.validate({id: "a", title: "T", run: () => {}, args: {}}), "args must be a list");
    }

    function test_duplicateIdsRefused() {
        const r = Commands.build([[entry("a.x"), entry("a.y")], () => [entry("a.x"), entry("Bad")]]);
        compare(r.entries.map(e => e.id), ["a.x", "a.y"]);
        compare(r.errors, ["a.x: duplicate id", "Bad: bad id"]);
        verify(Commands.find(r, "a.y") !== null);
        compare(Commands.find(r, "Bad"), null);
        compare(Commands.find(r, "toString"), null);
    }

    function test_systemRowsAsBefore() {
        const r = reg();
        compare(r.errors, []);
        compare(r.entries.map(e => e.id), ["sys.lock", "sys.sleep", "sys.restart", "sys.shutdown", "sys.logout"]);
        compare(r.entries.map(e => e.title), ["Lock Screen", "Sleep", "Restart", "Shut Down", "Log Out"]);
        compare(r.entries.map(e => e.glyph), ["lock", "moon", "power", "power", "person"]);
        verify(r.entries.every(e => e.subtitle === "System command" && e.kind === "system" && e.provider === "system"));
    }

    function test_matchLikeBefore() {
        const r = reg();
        compare(ids(r, "lock"), ["sys.lock"]);
        compare(ids(r, "sle"), ["sys.sleep"]);
        compare(ids(r, "reboot"), ["sys.restart"]);
        compare(ids(r, "power off"), ["sys.shutdown"]);
        compare(ids(r, "poweroff"), ["sys.shutdown"]);
        compare(ids(r, "sign out"), ["sys.logout"]);
        compare(ids(r, "log"), ["sys.logout"]);
        compare(ids(r, "zzzz"), []);
        // Title beats keyword; a keyword hit is worth 80 % of its text score.
        const a = Commands.match(r, "shut");
        compare(a[0].cmd.id, "sys.shutdown");
        verify(a[0].score >= 50);
        verify(Commands.match(r, "reboot")[0].score < Commands.match(r, "restart")[0].score);
    }

    function test_frenchKeywordsAndEnglishKept() {
        const fr = reg(wordsFr);
        compare(ids(fr, "verrouiller"), ["sys.lock"]);
        compare(ids(fr, "Éteindre"), ["sys.shutdown"]);
        compare(ids(fr, "eteindre"), ["sys.shutdown"]);
        compare(ids(fr, "lock"), []);
        // keywordsEn keeps the English words next to the translated ones.
        const e = entry("sys.lock");
        e.title = "Verrouiller l’écran";
        e.keywords = ["verrouiller"];
        e.keywordsEn = ["lock"];
        const r = Commands.build([[e]]);
        compare(ids(r, "lock"), ["sys.lock"]);
        compare(ids(r, "verrou"), ["sys.lock"]);
    }

    function test_availability() {
        compare(ids(reg(words, false), "lock"), []);
        compare(Commands.run(reg(words, false), "sys.lock"), false);
        let on = false;
        const e = entry("a.cond");
        e.title = "Conditional";
        e.available = () => on;
        const r = Commands.build([[e]]);
        compare(ids(r, "conditional"), []);
        on = true;
        compare(ids(r, "conditional"), ["a.cond"]);
    }

    function test_dispatchTable() {
        const r = reg();
        for (const [id, call] of [["sys.lock", "lock"], ["sys.sleep", "sleep"], ["sys.restart", "restart"], ["sys.shutdown", "shutdown"], ["sys.logout", "logout"]]) {
            calls = [];
            verify(Commands.run(r, id, [], "row"), id);
            compare(calls, [call]);
        }
    }

    function test_unknownIdRunsNothing() {
        const r = reg();
        compare(Commands.run(r, "lock"), false);
        compare(Commands.run(r, "sys.nope"), false);
        compare(Commands.run(r, ""), false);
        compare(Commands.run(r, undefined), false);
        compare(calls, []);
    }

    function test_runPassesArgsAndOrigin() {
        let seen = null;
        const e = entry("a.args");
        e.run = (args, origin) => {
            seen = [args, origin];
        };
        const r = Commands.build([[e]]);
        verify(Commands.run(r, "a.args", ["x"], "hotkey"));
        compare(seen, [["x"], "hotkey"]);
        verify(Commands.run(r, "a.args"));
        compare(seen, [[], "row"]);
    }
}
