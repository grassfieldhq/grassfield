import QtQuick
import QtTest
import "../../shell/notifications/History.js" as History

TestCase {
    name: "NotificationHistory"

    readonly property real now: 1800000000000
    readonly property real day: 24 * 3600 * 1000

    function entry(key, app, time, extra) {
        const e = {key: key, nid: 1, appName: app, appIcon: "", summary: "s" + key, body: "b", time: time, urgency: 1,
            transient: false, resident: false, actions: []};
        return Object.assign(e, extra || {});
    }

    function test_pruneDropsOlderThanSevenDays() {
        const list = [entry("new", "a", now - day), entry("edge", "a", now - 7 * day), entry("old", "a", now - 7 * day - 1)];
        compare(History.prune(list, now).map(e => e.key).join(","), "new,edge");
    }

    // GF-113: retention, nothing at rest, no bodies for apps whose previews are Never.
    function test_serializeRetentionAndBodies() {
        const list = [entry("a", "Signal", now - 1000, {body: "secret"}), entry("b", "Mail", now - 2 * day, {body: "hello"})];
        const day1 = JSON.parse(History.serialize(list, now, {maxAgeMs: day}));
        compare(day1.notifications.map(e => e.key), ["a"]);
        const never = JSON.parse(History.serialize(list, now, {keep: false}));
        compare(never.notifications.length, 0);
        const noBody = JSON.parse(History.serialize(list, now, {textKept: app => app !== "Signal"}));
        compare(noBody.notifications[0].body, "");
        compare(noBody.notifications[1].body, "hello");
        // The title and the action labels are text too: an app whose previews are Never leaves none of it on disk.
        compare(noBody.notifications[0].summary, "");
        compare(noBody.notifications[0].appName, "Signal");
        compare(noBody.notifications[1].summary, "sb");
        const withActions = JSON.parse(History.serialize([entry("c", "Signal", now - 5, {actions: [{id: "reply", text: "Reply to Alice"}]})], now, {textKept: () => false}));
        compare(withActions.notifications[0].actions, []);
        compare(JSON.parse(History.serialize(list, now)).notifications[0].body, "secret");
    }

    // Review: a damaged file is moved aside, a file of a newer version is never rewritten, and neither is read as "no history".
    function test_inspectTellsEmptyCorruptAndFutureApart() {
        compare(History.inspect("", now).status, "empty");
        compare(History.inspect("  \n", now).status, "empty");
        compare(History.inspect("not json", now).status, "corrupt");
        compare(History.inspect("[]", now).status, "corrupt");
        compare(History.inspect("{\"version\":0,\"notifications\":[]}", now).status, "corrupt");
        compare(History.inspect("{\"version\":1.5,\"notifications\":[]}", now).status, "corrupt");
        compare(History.inspect("{\"version\":\"1\",\"notifications\":[]}", now).status, "corrupt");
        compare(History.inspect("{\"version\":1,\"notifications\":{}}", now).status, "corrupt");
        compare(History.inspect("{\"version\":2,\"notifications\":[{\"time\":1}]}", now).status, "future");
        compare(History.inspect("{\"version\":2,\"notifications\":[{\"time\":1}]}", now).entries.length, 0);
        const ok = History.inspect(History.serialize([entry("a", "Mail", now - 1000)], now), now);
        compare(ok.status, "ok");
        compare(ok.entries.length, 1);
    }

    // "1 Day" is applied to what is read and what arrives, not only to what is written.
    function test_oneDayRetentionAppliesInMemory() {
        const text = History.serialize([entry("a", "Mail", now - 1000), entry("b", "Mail", now - 2 * day)], now);
        compare(History.inspect(text, now).entries.length, 2);
        compare(History.inspect(text, now, day).entries.map(e => e.key), ["a"]);
        const pushed = History.pushNewest([entry("a", "Mail", now - 2 * day)], entry("n", "Mail", now), now, day);
        compare(pushed.map(e => e.key), ["n"]);
    }

    function test_pruneCapsAt200NewestFirst() {
        const list = [];
        for (let i = 0; i < 250; i++)
            list.push(entry("k" + i, "a", now - i * 1000));
        const kept = History.prune(list, now);
        compare(kept.length, 200);
        compare(kept[0].key, "k0");
        compare(kept[199].key, "k199");
    }

    function test_pushNewestMatchesPrune() {
        let list = [];
        for (let i = 0; i < 200; i++)
            list.push(entry("k" + i, "a", now - (i + 1) * 1000));
        const next = entry("new", "a", now);
        const fast = History.pushNewest(list, next, now);
        compare(fast.map(e => e.key).join(","), History.prune([next].concat(list), now).map(e => e.key).join(","));
        compare(fast.length, 200);
        compare(fast[0].key, "new");
        // Older than the head: falls back to the full prune (sorted).
        const late = History.pushNewest(list, entry("late", "a", now - 5000), now);
        compare(late[4].key, "late");
        // Aged-out tail is dropped.
        const aged = History.pushNewest([entry("x", "a", now - 7 * day - 1)], next, now);
        compare(aged.map(e => e.key).join(","), "new");
    }

    function test_transientAndLowNotPersisted() {
        verify(!History.shouldPersist(entry("t", "a", now, {transient: true})));
        verify(!History.shouldPersist(entry("l", "a", now, {urgency: 0})));
        verify(History.shouldPersist(entry("lr", "a", now, {urgency: 0, resident: true})));
        verify(History.shouldPersist(entry("n", "a", now)));
        verify(History.shouldPersist(entry("c", "a", now, {urgency: 2})));
        const data = JSON.parse(History.serialize([entry("t", "a", now, {transient: true}), entry("n", "a", now)], now));
        compare(data.notifications.length, 1);
        compare(data.notifications[0].key, "n");
    }

    function test_roundTripRestoresNonActionable() {
        const live = entry("1", "mail", now - 1000, {actions: [{id: "reply", text: "Reply"}], nid: 42});
        const restored = History.parse(History.serialize([live], now), now);
        compare(restored.length, 1);
        compare(restored[0].nid, -1);
        compare(restored[0].restored, true);
        compare(restored[0].actions.length, 1);
        compare(restored[0].actions[0].text, "Reply");
        compare(restored[0].actions[0].id, "");
        compare(restored[0].summary, "s1");
    }

    function test_parseRejectsGarbage() {
        compare(History.parse("not json", now).length, 0);
        compare(History.parse("{\"version\": 2, \"notifications\": []}", now).length, 0);
        compare(History.parse("{\"version\": 1, \"notifications\": [1, {\"time\": \"x\"}, {\"time\": " + now + "}]}", now).length, 1);
    }

    function test_parsePrunesStoredOldEntries() {
        const text = JSON.stringify({version: 1, notifications: [{key: "o", time: now - 8 * day}, {key: "n", time: now}]});
        compare(History.parse(text, now).map(e => e.key).join(","), "n");
    }

    function test_groupByAppNewestFirst() {
        const list = [entry("1", "mail", now - 3000), entry("2", "chat", now - 1000), entry("3", "mail", now - 2000, {appIcon: "mail-icon"}),
            entry("4", "", now - 4000)];
        const groups = History.group(list);
        compare(groups.map(g => g.appName).join(","), "chat,mail,");
        compare(groups[1].items.map(e => e.key).join(","), "3,1");
        compare(groups[1].appIcon, "mail-icon");
        compare(groups[1].latest, now - 2000);
    }

    // An app may carry the name of a member of Object.prototype (audit B-04): it groups like any other.
    function test_groupByAppNamedLikeAnObjectMember() {
        const names = ["constructor", "__proto__", "toString", "valueOf", "hasOwnProperty"];
        const list = [];
        names.forEach((name, i) => {
            list.push(entry("a" + i, name, now - 1000 * i));
            list.push(entry("b" + i, name, now - 1000 * i - 500));
        });
        const groups = History.group(list);
        compare(groups.map(g => g.appName).join(","), names.join(","));
        groups.forEach((g, i) => compare(g.items.map(e => e.key).join(","), "a" + i + ",b" + i));
    }

    // Texts are bounded at intake (audit B-10); a cut never splits a surrogate pair.
    function test_bounded() {
        compare(History.bounded("abc", 3), "abc");
        compare(History.bounded("abcd", 3), "abc");
        compare(History.bounded("ab\ud83d\ude00", 3), "ab");
        compare(History.bounded("a\ud83d\ude00b", 3), "a\ud83d\ude00");
        compare(History.bounded("x".repeat(100000), History.MAX_LINE).length, History.MAX_LINE);
        compare(History.bounded(undefined, 3), undefined);
    }

    function test_removeKeyAndApp() {
        const list = [entry("1", "mail", now), entry("2", "chat", now), entry("3", "mail", now)];
        compare(History.removeKey(list, "2").length, 2);
        compare(History.removeApp(list, "mail").map(e => e.key).join(","), "2");
    }

    // Clear one (the x of a card): only that entry goes, order kept, unknown key changes nothing, input untouched.
    function test_clearOneKeepsTheRest() {
        const list = [entry("1", "mail", now), entry("2", "mail", now - 1000), entry("3", "chat", now - 2000)];
        const after = History.removeKey(list, "2");
        compare(after.map(e => e.key).join(","), "1,3");
        compare(list.length, 3);
        compare(History.removeKey(list, "nope").map(e => e.key).join(","), "1,2,3");
        compare(History.removeKey([], "1").length, 0);
        compare(History.group(after).map(g => g.appName + ":" + g.items.length).join(","), "mail:1,chat:1");
    }

    // Clear group (Clear All on a group header): every entry of the app, also the app without a name, nothing else.
    function test_clearGroupRemovesWholeApp() {
        const list = [entry("1", "mail", now), entry("2", "", now - 1000), entry("3", "mail", now - 2000), entry("4", "chat", now - 3000),
            entry("5", "", now - 4000)];
        compare(History.removeApp(list, "mail").map(e => e.key).join(","), "2,4,5");
        compare(History.removeApp(list, "").map(e => e.key).join(","), "1,3,4");
        compare(History.removeApp(list, "none").length, 5);
        compare(History.group(History.removeApp(list, "mail")).map(g => g.appName).join(","), ",chat");
    }

    // History state after clearing: what is written to disk no longer holds the cleared entries; clearing everything
    // writes an empty list that parses back to nothing (no "Clear All" is needed to reach that state).
    function test_clearedEntriesLeaveTheStoredHistory() {
        const list = [entry("1", "mail", now - 1000), entry("2", "mail", now - 2000), entry("3", "chat", now - 3000)];
        const stored = JSON.parse(History.serialize(History.removeApp(History.removeKey(list, "3"), "mail"), now));
        compare(stored.notifications.length, 0);
        const some = JSON.parse(History.serialize(History.removeKey(list, "1"), now));
        compare(some.notifications.map(e => e.key).join(","), "2,3");
        const restored = History.parse(History.serialize(History.removeKey(list, "2"), now), now);
        compare(restored.map(e => e.key).join(","), "1,3");
        compare(History.parse(History.serialize([], now), now).length, 0);
    }

    function test_relativeParts() {
        compare(History.relativeParts(now - 5000, now).unit, "now");
        compare(JSON.stringify(History.relativeParts(now - 120000, now)), "{\"unit\":\"m\",\"n\":2}");
        compare(JSON.stringify(History.relativeParts(now - 3 * 3600 * 1000, now)), "{\"unit\":\"h\",\"n\":3}");
        compare(JSON.stringify(History.relativeParts(now - 2 * day, now)), "{\"unit\":\"d\",\"n\":2}");
        compare(History.relativeParts(now + 5000, now).unit, "now");
    }

    // Quickshell's Notification.expireTimeout is in milliseconds.
    function test_bannerTimeout() {
        compare(History.bannerTimeout(2, 3000, 5000), 0);
        compare(History.bannerTimeout(1, 0, 5000), 0);
        compare(History.bannerTimeout(1, 2000, 5000), 2000);
        // A positive timeout shorter than the entrance is raised to the minimum (audit B-18).
        compare(History.bannerTimeout(1, 1, 5000), History.MIN_BANNER_MS);
        compare(History.bannerTimeout(0, 0.2, 5000), History.MIN_BANNER_MS);
        compare(History.bannerTimeout(1, -1, 5000), 5000);
        compare(History.bannerTimeout(0, -1, 5000), 5000);
    }

    // GF-114 / DT-07: only local files, the image data the app sent and theme names; never a URL to fetch.
    function test_imageRef_data() {
        return [
            {tag: "app icon path (Quickshell)", image: "image://icon//usr/share/icons/hicolor/48x48/apps/btop.png", kind: "file"},
            {tag: "absolute path", image: "/tmp/a.png", kind: "file"},
            {tag: "file URL", image: "file:///home/u/Pictures/a.png", kind: "file"},
            {tag: "file URL, localhost", image: "file://localhost/tmp/a.png", kind: "file"},
            {tag: "file URL, one slash", image: "file:/tmp/a.png", kind: "file"},
            {tag: "file URL, upper-case scheme", image: "FILE:///tmp/a.png", kind: "file"},
            {tag: "image data the app sent", image: "image://qsimage/12/0", kind: "attached"},
            {tag: "theme name", image: "image://icon/firefox", kind: "themed", name: "firefox"},
            {tag: "theme name, encoded", image: "image://icon/org.gnome.Nautilus%2Dsymbolic", kind: "themed", name: "org.gnome.Nautilus-symbolic"},
            {tag: "http", image: "http://127.0.0.1:8080/p.png", kind: "refused"},
            {tag: "https", image: "https://tracker.example/pixel.png?u=1", kind: "refused"},
            {tag: "HTTPS upper case", image: "HTTPS://tracker.example/p.png", kind: "refused"},
            {tag: "ftp", image: "ftp://example.org/p.png", kind: "refused"},
            {tag: "data URI", image: "data:image/png;base64,AA", kind: "refused"},
            {tag: "qrc", image: "qrc:/x.png", kind: "refused"},
            {tag: "other image provider", image: "image://other/x", kind: "refused"},
            {tag: "relative path", image: "pictures/a.png", kind: "refused"},
            {tag: "network-path reference", image: "//host/share/a.png", kind: "refused"},
            {tag: "file URL of another host", image: "file://evil.example/share/a.png", kind: "refused"},
            {tag: "file URL with an empty path element", image: "file:////host/a.png", kind: "refused"},
            {tag: "theme name with a query", image: "image://icon/firefox?fallback=x", kind: "refused"},
            {tag: "theme name that is a URL", image: "image://icon/http%3A%2F%2Fexample.org%2Fa.png", kind: "refused"},
            {tag: "theme name, bad escape", image: "image://icon/%E0%A4%A", kind: "refused"},
            {tag: "empty theme name", image: "image://icon/", kind: "refused"},
            {tag: "control character", image: "/tmp/a\npng", kind: "refused"},
            {tag: "oversized", image: "/" + "a".repeat(5000), kind: "refused"},
            {tag: "empty", image: "", kind: "none"}
        ];
    }

    function test_imageRef(data) {
        const ref = History.imageRef(data.image);
        compare(ref.kind, data.kind);
        if (data.kind === "file" || data.kind === "attached" || data.kind === "themed")
            compare(ref.source, data.image);
        else
            compare(ref.source, "");
        if (data.kind === "themed")
            compare(ref.name, data.name);
    }

    function test_imageRefNonString() {
        compare(History.imageRef(undefined).kind, "none");
        compare(History.imageRef(null).kind, "none");
        compare(History.imageRef(42).kind, "none");
    }

    // Review of 8b2a710: the path a local image loads, so that it can be checked (regular file, bounded) before it is shown.
    function test_localPathOf() {
        compare(History.localPathOf("/tmp/a.png"), "/tmp/a.png");
        compare(History.localPathOf("image://icon//usr/share/icons/x.png"), "/usr/share/icons/x.png");
        compare(History.localPathOf("file:///home/u/My%20Pictures/a.png"), "/home/u/My Pictures/a.png");
        compare(History.localPathOf("file://localhost/tmp/a.png"), "/tmp/a.png");
        compare(History.localPathOf("file:/tmp/a.png"), "/tmp/a.png");
        compare(History.localPathOf("file:///tmp/a%0Ab.png"), "", "a decoded control character");
        compare(History.localPathOf("file:///tmp/%E0%A4%A"), "", "a malformed escape");
        compare(History.localPathOf("file://evil.example/a.png"), "");
        compare(History.localPathOf("//host/a.png"), "");
        compare(History.localPathOf("https://example.org/a.png"), "");
        compare(History.localPathOf("image://icon/firefox"), "");
        compare(History.localPathOf(""), "");
        compare(History.localPathOf(undefined), "");
    }

    // Review of beebaff: the forms where the checked name and the loaded URL could differ are refused outright.
    function test_localPathOfRefusesUrlLookalikes() {
        compare(History.localPathOf("/dir/x.png?a"), "", "a plain path with ?");
        compare(History.localPathOf("/dir/x.png#f"), "", "a plain path with #");
        compare(History.localPathOf("/dir/x%2Epng"), "", "a plain path with %");
        compare(History.localPathOf("file:///dir/x.png?a"), "", "a file: URL with a query");
        compare(History.localPathOf("file:///dir/x.png#f"), "", "a file: URL with a fragment");
        compare(History.localPathOf("file:///dir/x%3Fa.png"), "", "an escape decoding to ?");
        compare(History.localPathOf("file:///dir/x%2525.png"), "", "an escape decoding to %");
        compare(History.localPathOf("image://icon//dir/x.png?fallback=a"), "", "Quickshell's icon path with a query");
        compare(History.localPathOf("/dir/./x.png"), "", "a . segment");
        compare(History.localPathOf("/dir/../etc/x.png"), "", "a .. segment");
        compare(History.localPathOf("/dir//x.png"), "", "an empty segment");
        compare(History.localPathOf("/dir/"), "", "a directory path");
        compare(History.localPathOf("file:///dir/x%2Epng"), "/dir/x.png", "a file: URL escape decodes to the plain name it names");
    }

    // Review of 6e24d36: an app icon NAME reaches the icon theme only when it is a plain theme name; Qt's fallback search
    // (/usr/share/pixmaps) turned "../../../dir/evil" into any file, a FIFO included.
    function test_safeIconName_data() {
        return [
            {tag: "plain", name: "firefox", kept: "firefox"},
            {tag: "reverse DNS", name: "org.gnome.Nautilus", kept: "org.gnome.Nautilus"},
            {tag: "symbolic", name: "dialog-information-symbolic", kept: "dialog-information-symbolic"},
            {tag: "underscore", name: "steam_icon_570", kept: "steam_icon_570"},
            {tag: "parent traversal", name: "../../../tmp/evil", kept: ""},
            {tag: "theme-relative traversal", name: "hicolor/../../../../tmp/evil", kept: ""},
            {tag: "dot-dot alone", name: "..", kept: ""},
            {tag: "dot-dot inside", name: "a..b", kept: ""},
            {tag: "leading dot", name: ".hidden", kept: ""},
            {tag: "leading dash", name: "-x", kept: ""},
            {tag: "leading underscore", name: "_x", kept: ""},
            {tag: "128 characters", name: "a".repeat(128), kept: "a".repeat(128)},
            {tag: "slash", name: "apps/firefox", kept: ""},
            {tag: "backslash", name: "a\\b", kept: ""},
            {tag: "colon", name: "file:x", kept: ""},
            {tag: "NUL", name: "fire\u0000fox", kept: ""},
            {tag: "newline", name: "fire\nfox", kept: ""},
            {tag: "space", name: "fire fox", kept: ""},
            {tag: "too long", name: "a".repeat(129), kept: ""},
            {tag: "empty", name: "", kept: ""}
        ];
    }

    function test_safeIconName(data) {
        compare(History.safeIconName(data.name), data.kept);
    }

    function test_keptAppIconAndHistoryLoad() {
        compare(History.keptAppIcon("firefox"), "firefox");
        compare(History.keptAppIcon("../../../tmp/evil"), "", "a traversal name is dropped at intake");
        compare(History.keptAppIcon("/usr/share/icons/x.png"), "/usr/share/icons/x.png", "a path goes on to the private-copy route");
        compare(History.keptAppIcon("file:///usr/share/icons/x.png"), "file:///usr/share/icons/x.png");
        compare(History.keptAppIcon("/tmp/x.png?a"), "", "a path the copy route refuses is dropped");
        compare(History.keptAppIcon(undefined), "");
        // A history file written before the rule (or by hand) is cleaned on load.
        const now = Date.now();
        const text = JSON.stringify({version: 1, notifications: [
                {key: "a", appName: "A", appIcon: "../../../tmp/evil", summary: "s", body: "", time: now - 1000, urgency: 1},
                {key: "b", appName: "B", appIcon: "firefox", summary: "s", body: "", time: now - 2000, urgency: 1}]});
        const restored = History.parse(text, now);
        compare(restored.length, 2);
        compare(restored.find(e => e.key === "a").appIcon, "");
        compare(restored.find(e => e.key === "b").appIcon, "firefox");
        // The same rule for a themed image hint (Quickshell's image://icon/<name>).
        compare(History.imageRef("image://icon/..%2F..%2Ftmp%2Fevil").kind, "refused");
        compare(History.imageRef("image://icon/.hidden").kind, "refused");
        compare(History.imageRef("image://icon/firefox").kind, "themed");
    }

    function test_copySource() {
        compare(History.copySource("/run/user/1000/grassfield-notification-images", 12, 0), "file:///run/user/1000/grassfield-notification-images/12.0.png");
        compare(History.copySource("/run/user/1000/grassfield-notification-images", 12, 7), "file:///run/user/1000/grassfield-notification-images/12.7.png", "the sender number is part of the name");
        compare(History.copySource("/tmp/my dir", 3, 1), "file:///tmp/my%20dir/3.1.png", "every segment encoded");
        compare(History.copySource("/tmp/a?b", 3, 1), "", "an odd directory name");
        compare(History.copySource("relative", 3, 1), "");
        compare(History.copySource("/tmp", 0, 1), "");
        compare(History.copySource("/tmp", 1.5, 1), "");
        compare(History.copySource("/tmp", 3, -1), "", "a negative sender");
        compare(History.copySource("/tmp", 3, 0.5), "", "a fractional sender");
        compare(History.copySource("/tmp", 3), "", "no sender");
        verify(History.MAX_IMAGE_FILE_BYTES > 0 && History.MAX_IMAGE_FILE_BYTES <= 64 * 1024 * 1024);
    }

    function test_imageScheme() {
        compare(History.imageScheme("https://tracker.example/p.png"), "https");
        compare(History.imageScheme("DATA:image/png;base64,AA"), "data");
        compare(History.imageScheme("pictures/a.png"), "");
        compare(History.imageScheme(undefined), "");
    }
}
