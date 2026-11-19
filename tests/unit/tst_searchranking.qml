import QtQuick
import QtTest
import "../../shell/search/Ranking.js" as Ranking
import "../../shell/search/Files.js" as Files

TestCase {
    name: "SearchRanking"

    readonly property var apps: [
        {id: "firefox", name: "Firefox", genericName: "Web Browser", comment: "Browse the World Wide Web", keywords: ["internet", "www"]},
        {id: "foot", name: "Foot", genericName: "Terminal", comment: "Fast terminal emulator", keywords: ["shell", "prompt"]},
        {id: "files", name: "Files", genericName: "File Manager", comment: "Browse your files", keywords: ["folder"]},
        {id: "fire-tool", name: "Hot Fire Tool", genericName: "", comment: "", keywords: []},
        {id: "kitty", name: "kitty", genericName: "Terminal", comment: "", keywords: []}
    ]

    // The usage boost decays from the time of the picks: tests pick at T0 and rank at T0 (or later on purpose).
    readonly property real t0: Date.UTC(2026, 10, 5)
    readonly property real day: 86400000

    function ids(query, usage, now) {
        return Ranking.rank(apps, query, usage || Ranking.newUsage(), 0, now === undefined ? t0 : now).map(r => r.app.id);
    }

    function test_prefixBeatsWordBeatsSubstring() {
        compare(ids("fire")[0], "firefox");
        compare(ids("fire")[1], "fire-tool");
        compare(ids("foo")[0], "foot");
    }

    function test_noMatchAndEmpty() {
        compare(ids("zzzq").length, 0);
        compare(ids("").length, 0);
        compare(ids("   ").length, 0);
    }

    function test_fuzzy() {
        compare(ids("ffx")[0], "firefox");
        compare(ids("fox")[0], "firefox");
    }

    function test_keywordsGenericNameComment() {
        compare(ids("internet")[0], "firefox");
        compare(ids("terminal").slice(0, 2).sort().join(), "foot,kitty");
        compare(ids("emulator")[0], "foot");
        compare(ids("folder")[0], "files");
    }

    function test_nameBeatsKeyword() {
        compare(ids("shell")[0], "foot");
        const apps2 = [{id: "a", name: "Other", keywords: ["term"]}, {id: "b", name: "Term", keywords: []}];
        compare(Ranking.rank(apps2, "term", Ranking.newUsage())[0].app.id, "b");
    }

    function test_usageBoostReordersEqualMatches() {
        const usage = Ranking.newUsage();
        for (let i = 0; i < 10; i++)
            Ranking.bumpUsage(usage, "files", t0 + i);
        compare(ids("fi", usage)[0], "files");
        verify(Ranking.usageBoost(usage["files"], t0) > 0);
        verify(Ranking.usageBoost(usage["files"], t0) <= 20);
    }

    // The boost decays (half-life USAGE_HALF_LIFE_DAYS): the weight halves per half-life, a long-unused favourite loses to a
    // recent one, and it never exceeds the cap however often it was picked.
    function test_usageBoostDecays() {
        const u = Ranking.newUsage();
        Ranking.bumpUsage(u, "a", t0);
        compare(u.a.weight, 1);
        fuzzyCompare(Ranking.usageBoost(u.a, t0), 5, 1e-9);
        const half = Ranking.USAGE_HALF_LIFE_DAYS * day;
        fuzzyCompare(Ranking.decayedWeight(u.a, t0 + half), 0.5, 1e-9);
        fuzzyCompare(Ranking.decayedWeight(u.a, t0 + 2 * half), 0.25, 1e-9);
        // A clock that went back does not inflate the weight.
        compare(Ranking.decayedWeight(u.a, t0 - day), 1);
        // A second pick a half-life later: 0.5 + 1.
        Ranking.bumpUsage(u, "a", t0 + half);
        fuzzyCompare(u.a.weight, 1.5, 1e-9);
        compare(u.a.count, 2);
        // Capped: weight and boost.
        const many = Ranking.newUsage();
        for (let i = 0; i < 500; i++)
            Ranking.bumpUsage(many, "x", t0 + i);
        compare(many.x.weight, Ranking.USAGE_WEIGHT_CAP);
        compare(Ranking.usageBoost(many.x, t0 + 500), Ranking.USAGE_BOOST_CAP);
        // 100 picks a year ago lose to 3 picks this week.
        const old = Ranking.newUsage();
        for (let i = 0; i < 100; i++)
            Ranking.bumpUsage(old, "firefox", t0 - 365 * day + i);
        for (let i = 0; i < 3; i++)
            Ranking.bumpUsage(old, "fire-tool", t0 - 2 * day + i);
        verify(Ranking.usageBoost(old["fire-tool"], t0) > Ranking.usageBoost(old.firefox, t0));
        verify(Ranking.usageBoost(old.firefox, t0) < 0.01);
        // The boost never makes a fuzzy hit beat a prefix match.
        const fav = Ranking.newUsage();
        for (let i = 0; i < 50; i++)
            Ranking.bumpUsage(fav, "kitty", t0 + i);
        compare(ids("foo", fav, t0 + 50)[0], "foot");
    }

    // USAGE_VERSION 2: a version 1 file ({count, last}) is migrated (weight = count, capped), then decays from its last pick.
    function test_usageMigrationFromVersion1() {
        const v1 = JSON.stringify({version: 1, usage: {firefox: {count: 7, last: t0}, foot: {count: 900, last: t0 - 400 * day}, bad: {count: 0, last: 1}}});
        const u = Ranking.parseUsage(v1);
        compare(Object.keys(u).sort(), ["firefox", "foot"]);
        compare(u.firefox.weight, 7);
        compare(u.firefox.count, 7);
        compare(u.foot.weight, Ranking.USAGE_WEIGHT_CAP);
        verify(Ranking.usageBoost(u.foot, t0) < 0.01);
        fuzzyCompare(Ranking.usageBoost(u.firefox, t0), 15, 1e-9);
        // Written back as version 2, read back the same.
        const text = Ranking.serializeUsage(u);
        compare(JSON.parse(text).version, 2);
        compare(Ranking.USAGE_VERSION, 2);
        const back = Ranking.parseUsage(text);
        compare(back.firefox.weight, 7);
        // A version 2 entry with a bad weight falls back to its count; a newer version is foreign.
        compare(Ranking.parseUsage(JSON.stringify({version: 2, usage: {a: {count: 3, last: t0, weight: "x"}}})).a.weight, 3);
        compare(Ranking.parseUsage(JSON.stringify({version: 2, usage: {a: {count: 3, last: t0, weight: -1}}})).a.weight, 3);
        compare(Object.keys(Ranking.parseUsage(JSON.stringify({version: 3, usage: {a: {count: 3, last: t0, weight: 1}}}))).length, 0);
        compare(Object.keys(Ranking.parseUsage(JSON.stringify({version: 2, usage: {a: {count: 3, last: Infinity}}}))).length, 0);
    }

    // ---- file ranking ------------------------------------------------------------------------------------------------

    readonly property var fileCtx: ({home: "/home/u", xdgDirs: ["/home/u/Bureau", "/home/u/Documents", "/home/u/Téléchargements"], usage: null, now: t0})

    function rankedFiles(paths, q, ctx) {
        return Ranking.rankFiles(paths, q, ctx || fileCtx, 0);
    }

    function test_filesJunkNamesSink() {
        const paths = ["/home/u/notes/report-old.txt", "/home/u/notes/report.txt", "/home/u/notes/report.txt~", "/home/u/notes/report (2).txt",
            "/home/u/notes/report copy.txt", "/home/u/notes/report.bak", "/home/u/notes/Rapport - copie.txt", "/home/u/notes/report_backup.txt"];
        const r = rankedFiles(paths, "report");
        compare(r[0], "/home/u/notes/report.txt");
        // Every junk variant ranks under the clean one.
        for (const p of paths.slice(0))
            verify(p === r[0] || r.indexOf(p) > 0, p);
        // French words count too.
        verify(Ranking.junkPenalty("rapport ancien.odt", []).penalty > 0);
        verify(Ranking.junkPenalty("Sauvegarde-agenda.ics", ["agenda"]).penalty > 0);
        verify(Ranking.junkPenalty("Rapport - copie.txt", []).reasons.indexOf("duplicate") >= 0);
        // camelCase and digits split words.
        compare(Ranking.nameWords("oldReport2.txt").slice(0, 3), ["old", "report", "2"]);
        // A word the query touches is what the user wants.
        compare(Ranking.junkPenalty("backup-plan.txt", ["backup"]).penalty, 0);
        compare(Ranking.junkPenalty("disk.bak", ["bak"]).penalty, 0);
        compare(Ranking.junkPenalty("report.txt", ["report"]).penalty, 0);
        // Never more than the cap.
        verify(Ranking.junkPenalty("old backup copy (2).bak~", []).penalty <= Ranking.FILE_JUNK_CAP);
        // Not junk: words that only contain a junk word.
        compare(Ranking.junkPenalty("golden.txt", []).penalty, 0);
        compare(Ranking.junkPenalty("Temple.jpg", []).penalty, 0);
    }

    function test_filesGeneratedFoldersAndDepth() {
        const paths = ["/home/u/code/app/node_modules/x/README.md", "/home/u/code/app/README.md", "/home/u/code/app/build/README.md",
            "/home/u/code/app/target/README.md", "/home/u/code/app/__pycache__/README.md", "/home/u/code/app/dist/README.md"];
        compare(rankedFiles(paths, "readme")[0], "/home/u/code/app/README.md");
        verify(Ranking.locationAdjustment("/home/u/a/.git/x", "/home/u").reasons.indexOf("generated-path") >= 0);
        verify(Ranking.locationAdjustment("/home/u/a/Cache/x", "/home/u").reasons.indexOf("generated-path") >= 0);
        // The result itself may be called build: only the folders on the way count.
        compare(Ranking.locationAdjustment("/home/u/build", "/home/u").adjustment, 0);
        // Depth: two levels are free, then a step per level, capped.
        compare(Ranking.locationAdjustment("/home/u/Documents/a.txt", "/home/u").adjustment, 0);
        compare(Ranking.locationAdjustment("/home/u/a/b/c.txt", "/home/u").adjustment, -Ranking.FILE_DEPTH_STEP);
        compare(Ranking.locationAdjustment("/home/u/1/2/3/4/5/6/7/8/9/10/11/12/x", "/home/u").adjustment, -Ranking.FILE_DEPTH_CAP);
        const shallow = rankedFiles(["/home/u/a/b/c/d/e/plan.txt", "/home/u/a/plan.txt"], "plan");
        compare(shallow[0], "/home/u/a/plan.txt");
        // Outside the home (or a home prefix that is not a folder boundary).
        compare(Ranking.locationAdjustment("/srv/plan.txt", "/home/u").reasons, ["outside-home"]);
        compare(Ranking.locationAdjustment("/home/uu/plan.txt", "/home/u").reasons, ["outside-home"]);
        compare(rankedFiles(["/srv/plan.txt", "/home/u/plan.txt"], "plan")[0], "/home/u/plan.txt");
    }

    function test_filesXdgFoldersFavoured() {
        // The user's own folders, in the user's language.
        const r = rankedFiles(["/home/u/projets/facture.pdf", "/home/u/Téléchargements/facture.pdf"], "facture");
        compare(r[0], "/home/u/Téléchargements/facture.pdf");
        compare(Ranking.xdgBonus("/home/u/Documents", fileCtx.xdgDirs), Ranking.FILE_XDG_SELF);
        compare(Ranking.xdgBonus("/home/u/Documents/x/y.txt", fileCtx.xdgDirs), Ranking.FILE_XDG_INSIDE);
        compare(Ranking.xdgBonus("/home/u/DocumentsOld/y.txt", fileCtx.xdgDirs), 0);
        // No English names are assumed: without user-dirs.dirs, "Documents" is an ordinary folder.
        const none = Object.assign({}, fileCtx, {xdgDirs: []});
        compare(Ranking.xdgBonus("/home/u/Documents/x.txt", none.xdgDirs), 0);
    }

    function test_filesUsageBoost() {
        const u = Ranking.newUsage();
        for (let i = 0; i < 4; i++)
            Ranking.bumpUsage(u, "file:/home/u/b/plan.txt", t0 + i);
        const ctx = Object.assign({}, fileCtx, {usage: u, now: t0 + 10});
        compare(Ranking.rankFiles(["/home/u/a/plan.txt", "/home/u/b/plan.txt"], "plan", ctx, 0)[0], "/home/u/b/plan.txt");
        // Months later the boost has decayed: back to the plain order (equal scores, then the path).
        const later = Object.assign({}, ctx, {now: t0 + 365 * day});
        compare(Ranking.rankFiles(["/home/u/a/plan.txt", "/home/u/b/plan.txt"], "plan", later, 0)[0], "/home/u/a/plan.txt");
    }

    function test_filesTextAndLimits() {
        // A name match beats a content-only match; the extension does not stop an exact match.
        const r = rankedFiles(["/home/u/minutes.txt", "/home/u/budget.ods"], "budget");
        compare(r[0], "/home/u/budget.ods");
        compare(Ranking.scoreFile("/home/u/budget.ods", "budget", fileCtx).reasons[0], "text:100");
        compare(Ranking.scoreFile("/home/u/minutes.txt", "budget", fileCtx).reasons[0], "text:" + Ranking.FILE_CONTENT_SCORE);
        // Several words: each must match the name.
        verify(Ranking.scoreFile("/home/u/tax return 2026.pdf", "return tax", fileCtx).reasons[0] !== "text:" + Ranking.FILE_CONTENT_SCORE);
        // Repeats and junk input are dropped, the limit holds, ties go to the shorter path.
        compare(Ranking.rankFiles(["/home/u/a.txt", "/home/u/a.txt", "", null, "/home/u/x/a.txt"], "a", fileCtx, 1), ["/home/u/a.txt"]);
        compare(Ranking.rankFiles([], "a", fileCtx, 5), []);
        // Repeats are dropped (localsearch and a merge can name a file twice): no limit, still one row per path.
        compare(Ranking.rankFiles(["/home/u/a.txt", "/home/u/x/a.txt", "/home/u/a.txt", "/home/u/x/a.txt"], "a", fileCtx, 0),
                ["/home/u/a.txt", "/home/u/x/a.txt"]);
    }

    // Files opened from Search never push the apps' history out: apps and files have their own caps in search-usage.json.
    function test_usageCapsPerKind() {
        const u = Ranking.newUsage();
        for (let i = 0; i < 500; i++)
            Ranking.bumpUsage(u, "app" + i, t0 + i);
        for (let i = 0; i < 400; i++)
            Ranking.bumpUsage(u, "file:/home/u/f" + i, t0 + 1000 + i);
        const back = Ranking.parseUsage(Ranking.serializeUsage(u));
        const ids = Object.keys(back);
        compare(ids.filter(k => !k.startsWith("file:")).length, Ranking.MAX_USAGE_ENTRIES);
        compare(ids.filter(k => k.startsWith("file:")).length, Ranking.MAX_FILE_USAGE_ENTRIES);
        verify("app0" in back, "the oldest app pick is kept");
        verify("file:/home/u/f399" in back && !("file:/home/u/f0" in back), "the newest files are kept");
        // A file written with more entries than the caps is read within them.
        const big = {version: 2, usage: {}};
        for (let i = 0; i < 900; i++)
            big.usage[(i % 2 ? "file:/f" : "a") + i] = {count: 1, last: t0 + i, weight: 1};
        const read = Object.keys(Ranking.parseUsage(JSON.stringify(big)));
        verify(read.filter(k => k.startsWith("file:")).length <= Ranking.MAX_FILE_USAGE_ENTRIES);
        verify(read.filter(k => !k.startsWith("file:")).length <= Ranking.MAX_USAGE_ENTRIES);
    }

    function test_userDirsParsing() {
        const text = "# written by xdg-user-dirs-update\nXDG_DESKTOP_DIR=\"$HOME/Bureau\"\nXDG_DOWNLOAD_DIR=\"$HOME/Téléchargements\"\n"
            + "XDG_TEMPLATES_DIR=\"$HOME/Modèles\"\nXDG_PUBLICSHARE_DIR=\"$HOME\"\nXDG_DOCUMENTS_DIR=\"/data/docs\"\nXDG_MUSIC_DIR=\"$HOME\"\n"
            + "XDG_PICTURES_DIR=\"relative/pics\"\nXDG_VIDEOS_DIR=\"$HOME/.hidden\"\nnot a line\n";
        compare(Files.parseUserDirs(text, "/home/u"), ["/home/u/Bureau", "/home/u/Téléchargements", "/data/docs"]);
        compare(Files.parseUserDirs("", "/home/u"), []);
        compare(Files.parseUserDirs(undefined, "/home/u"), []);
        compare(Files.parseUserDirs("XDG_DESKTOP_DIR=\"$HOME/a/../Desk\"", "/home/u/"), ["/home/u/Desk"]);
    }

    // S2/P4: the file ranking runs once per file answer, never above the keystroke budget: 300 candidates well under 50 ms.
    function test_filePerformanceOn300Paths() {
        const paths = [];
        const dirs = ["Documents", "Downloads", "code/app/node_modules/pkg", "code/app/build", "Pictures/2026", "notes/old"];
        for (let i = 0; i < 300; i++)
            paths.push("/home/u/" + dirs[i % dirs.length] + "/report " + i + (i % 7 === 0 ? " copy" : "") + (i % 5 === 0 ? ".bak" : ".txt"));
        const u = Ranking.newUsage();
        for (let i = 0; i < 50; i++)
            Ranking.bumpUsage(u, "file:" + paths[i * 3], t0 - i * day);
        const ctx = Object.assign({}, fileCtx, {usage: u});
        let best = Infinity;
        for (let rep = 0; rep < 5; rep++) {
            const start = Date.now();
            for (let i = 0; i < 20; i++)
                Ranking.rankFiles(paths, "report", ctx, 20);
            best = Math.min(best, (Date.now() - start) / 20);
        }
        console.log("rankFiles 300 paths: best " + best + " ms per ranking");
        verify(best <= 50, "rankFiles took " + best + " ms (limit 50)");
    }

    function test_accentsFoldBothWays() {
        const list = [
            {id: "settings", name: "R\u00e9glages", genericName: "", comment: "", keywords: []},
            {id: "settings-nfd", name: "Re\u0301glages bis", genericName: "", comment: "", keywords: []},
            {id: "other", name: "Terminal", genericName: "", comment: "", keywords: []}
        ];
        const hits = q => Ranking.rank(list, q, Ranking.newUsage()).map(r => r.app.id);
        compare(hits("reglages").length, 2);
        compare(hits("R\u00e9glages").length, 2);
        compare(hits("re\u0301glages").length, 2);
        compare(hits("reglages")[0], "settings");
        compare(Ranking.norm("\u00c9COLE"), "ecole");
        compare(Ranking.norm("Re\u0301glages"), Ranking.norm("R\u00e9glages"));
        compare(Ranking.norm("plain"), "plain");
    }

    function test_foldedTiesUseCollator() {
        const list = [
            {id: "b", name: "caf\u00e9", genericName: "", comment: "", keywords: []},
            {id: "a", name: "cafe", genericName: "", comment: "", keywords: []}
        ];
        const r = Ranking.rank(list, "cafe", Ranking.newUsage());
        compare(r.length, 2);
        compare(r[0].app.id, "a");
    }

    function test_plocateFoldsAccents() {
        const out = Files.parsePlocate("/h/u/R\u00e9sum\u00e9.txt\n/h/u/other.txt\n", "resume", "/h/u", 5);
        compare(out[0], "/h/u/R\u00e9sum\u00e9.txt");
    }

    function test_usageBoostNeverCreatesMatch() {
        const usage = Ranking.newUsage();
        for (let i = 0; i < 50; i++)
            Ranking.bumpUsage(usage, "kitty", i);
        compare(ids("zzzq", usage).length, 0);
    }

    function test_usageRoundTripAndCorruption() {
        const usage = Ranking.newUsage();
        Ranking.bumpUsage(usage, "foot", 5);
        Ranking.bumpUsage(usage, "foot", 6);
        const back = Ranking.parseUsage(Ranking.serializeUsage(usage));
        compare(back["foot"].count, 2);
        compare(back["foot"].last, 6);
        compare(Object.keys(Ranking.parseUsage("not json")).length, 0);
        compare(Object.keys(Ranking.parseUsage("{\"version\":9,\"usage\":{}}")).length, 0);
        compare(Object.keys(Ranking.parseUsage("{\"version\":1,\"usage\":{\"a\":{\"count\":\"x\",\"last\":1}}}")).length, 0);
    }

    // Settings > Search > Delete Search History (search.historyResetAt): what was picked before is forgotten, later picks stay.
    function test_forgetUsageBefore() {
        const u = Ranking.newUsage();
        Ranking.bumpUsage(u, "firefox", 1000);
        Ranking.bumpUsage(u, "foot", 3000);
        const kept = Ranking.forgetUsageBefore(u, 2000);
        compare(Object.keys(kept), ["foot"]);
        compare(kept.foot.last, 3000);
        // Nothing deleted yet, or a time that is not a number: nothing is forgotten.
        for (const at of [0, -1, NaN, "2000", undefined, null])
            compare(Object.keys(Ranking.forgetUsageBefore(u, at)).length, 2, String(at));
        compare(Object.keys(Ranking.forgetUsageBefore(u, 5000)).length, 0);
    }

    function test_usageCap() {
        const usage = Ranking.newUsage();
        for (let i = 0; i < 700; i++)
            Ranking.bumpUsage(usage, "app" + i, i);
        const back = Ranking.parseUsage(Ranking.serializeUsage(usage));
        compare(Object.keys(back).length, 500);
        verify("app699" in back);
        verify(!("app0" in back));
    }

    function test_performanceOn300Entries() {
        const many = [];
        for (let i = 0; i < 300; i++)
            many.push({id: "app" + i, name: "Application Number " + i, genericName: "Tool", comment: "A long description for entry " + i, keywords: ["alpha", "beta", "gamma"]});
        // P4: at most 50 ms per keystroke. The minimum over 5 repetitions (20 keystrokes each) is
        // robust against machine load: a slow repetition does not fail the test, a slow ranker does.
        // Every entry has a usage record: the decayed boost (one Math.pow per match) is part of the measured cost.
        const usage = Ranking.newUsage();
        for (let i = 0; i < 300; i++)
            Ranking.bumpUsage(usage, "app" + i, t0 - i * day);
        let best = Infinity;
        for (let rep = 0; rep < 5; rep++) {
            const start = Date.now();
            for (let i = 0; i < 20; i++)
                Ranking.rank(many, "appnum", usage, 0, t0);
            best = Math.min(best, (Date.now() - start) / 20);
        }
        console.log("rank 300 entries: best " + best + " ms per keystroke");
        verify(best <= 50, "rank took " + best + " ms per keystroke (limit 50)");
    }

    function test_filesParsing() {
        const xbel = "<xbel><bookmark href=\"file:///home/u/My%20Doc.txt\" modified=\"2026-01-02T00:00:00Z\"><info><metadata><mime:mime-type type=\"text/plain\"/></metadata></info></bookmark>"
            + "<bookmark href=\"file:///home/u/new&amp;1.md\" modified=\"2026-02-02T00:00:00Z\"><info></info></bookmark>"
            + "<bookmark href=\"https://example.com/x\" modified=\"2026-03-02T00:00:00Z\"></bookmark></xbel>";
        const r = Files.parseXbel(xbel);
        compare(r.length, 2);
        compare(r[0].path, "/home/u/new&1.md");
        compare(r[1].path, "/home/u/My Doc.txt");
        compare(r[1].mime, "text/plain");
        const p = Files.parsePlocate("/etc/x/report\n/home/u/.cache/report\n/home/u/a/old-report.txt\n/home/u/report.md", "report", "/home/u", 20);
        compare(p.join(), "/home/u/report.md,/home/u/a/old-report.txt");
        compare(Files.parseLocalsearch("file:///home/u/a%20b.txt\n  file:///home/u/.hidden/x\nnoise", "/home/u", 20).join(), "/home/u/a b.txt");
        compare(Files.tildePath("/home/u/a", "/home/u"), "~/a");
    }

    function test_filesRestrictedToHome() {
        const ls = "file:///home/u/ok.txt\nfile:///etc/passwd\nfile:///home/u/../v/x\nfile:///home/u/a/../b.txt\n"
            + "file:///home/uu/x\nfile:///home/u/.ssh/id\nfile://host/home/u/x\nfile:///home/u/%2e%2e/etc/y\nfile:///home/u";
        compare(Files.parseLocalsearch(ls, "/home/u", 20).join(), "/home/u/ok.txt,/home/u/b.txt");
        compare(Files.parsePlocate("/home/u/../etc/report\n/home/u/./report2", "report", "/home/u", 20).join(), "/home/u/report2");
        const xbel = "<xbel><bookmark href=\"file:///home/u/a.txt\" modified=\"2026-01-02T00:00:00Z\"></bookmark>"
            + "<bookmark href=\"file:///etc/shadow\" modified=\"2026-01-03T00:00:00Z\"></bookmark>"
            + "<bookmark href=\"file:///home/u/.config/x\" modified=\"2026-01-04T00:00:00Z\"></bookmark>"
            + "<bookmark href=\"file:///home/u/../w/z\" modified=\"2026-01-05T00:00:00Z\"></bookmark>"
            + "<bookmark href=\"smb://srv/share/f\" modified=\"2026-01-06T00:00:00Z\"></bookmark></xbel>";
        compare(Files.parseXbel(xbel, "/home/u").map(r => r.path).join(), "/home/u/a.txt");
    }

    // Audit B-20: the recent documents are capped to the newest Files.MAX_RECENT (Search matches them on each keystroke), and
    // Search reads the file again when it changes, not on every opening.
    function test_recentsCappedAndReadOnChange() {
        let xbel = "<xbel>";
        for (let i = 0; i < 1000; i++)
            xbel += "<bookmark href=\"file:///home/u/f" + i + ".txt\" modified=\"" + new Date(Date.UTC(2026, 0, 1) + i * 60000).toISOString() + "\"></bookmark>";
        xbel += "</xbel>";
        const r = Files.parseXbel(xbel, "/home/u");
        compare(r.length, Files.MAX_RECENT);
        compare(r[0].path, "/home/u/f999.txt", "the newest first");
        compare(r[r.length - 1].path, "/home/u/f" + (1000 - Files.MAX_RECENT) + ".txt", "the oldest are dropped");
        compare(Files.parseXbel(xbel, "/home/u", 3).length, 3);
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../shell/search/Search.qml"), false);
        xhr.send();
        const src = xhr.responseText;
        const show = src.substring(src.indexOf("function show(text: string)"), src.indexOf("function hide()"));
        compare(show.indexOf("recentFile.reload()"), -1, "no read of the file on each opening");
        const view = src.substring(src.indexOf("id: recentFile"), src.indexOf("id: recentReload"));
        verify(view.indexOf("watchChanges: true") >= 0 && view.indexOf("onFileChanged: recentReload.restart()") >= 0, "read again when it changes");
    }
}
