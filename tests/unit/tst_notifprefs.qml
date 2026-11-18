import QtQuick
import QtTest
import Grassfield.Ui

// Per-app notification previews (ADR-0004, C-NOTIF-2): validation, resolution against the global default, the lock state.
TestCase {
    name: "NotificationPrefs"

    readonly property var list: [{app: "Signal", previews: "never"}, {app: "Mail", previews: "always"}]

    function test_validation() {
        compare(NotificationPrefs.problem(list), "");
        compare(NotificationPrefs.problem([]), "");
        verify(NotificationPrefs.problem("x") !== "");
        verify(NotificationPrefs.problem([{app: "", previews: "never"}]) !== "");
        verify(NotificationPrefs.problem([{app: "A", previews: "bogus"}]) !== "");
        verify(NotificationPrefs.problem([{app: "A", previews: "never"}, {app: " a ", previews: "always"}]) !== "");
        verify(NotificationPrefs.problem([{app: "bad\u0001", previews: "never"}]) !== "");
        verify(NotificationPrefs.problem([null]) !== "");
        const many = [];
        for (let i = 0; i < NotificationPrefs.MAX_APPS + 1; i++)
            many.push({app: "a" + i, previews: "never"});
        verify(NotificationPrefs.problem(many) !== "");
    }

    function test_normalizeDropsInvalidAndRepeated() {
        const out = NotificationPrefs.normalize([{app: "A", previews: "never"}, {app: "a", previews: "always"}, {app: "", previews: "never"}, {app: "B", previews: "x"}, 3, null]);
        compare(out.length, 1);
        compare(out[0].previews, "never");
        compare(NotificationPrefs.normalize("nope").length, 0);
    }

    function test_perAppBeatsGlobal() {
        compare(NotificationPrefs.effective(list, "Signal", "always"), "never");
        compare(NotificationPrefs.effective(list, "signal ", "always"), "never");
        compare(NotificationPrefs.effective(list, "Mail", "never"), "always");
        compare(NotificationPrefs.effective(list, "Other", "never"), "never");
        compare(NotificationPrefs.effective(list, "Other", "bogus"), "unlocked");
        compare(NotificationPrefs.effective([], "", "always"), "always");
    }

    function test_valueForAndWithValue() {
        compare(NotificationPrefs.valueFor(list, "Signal"), "never");
        compare(NotificationPrefs.valueFor(list, "Nope"), "default");
        const a = NotificationPrefs.withValue(list, "Signal", "unlocked");
        compare(NotificationPrefs.valueFor(a, "Signal"), "unlocked");
        compare(a.length, 2);
        const b = NotificationPrefs.withValue(a, "signal", "default");
        compare(NotificationPrefs.valueFor(b, "Signal"), "default");
        compare(b.length, 1);
        compare(NotificationPrefs.withValue([], "", "never").length, 0);
        compare(list.length, 2);
    }

    function test_bodyShownFollowsThePolicyAndTheLock() {
        verify(NotificationPrefs.bodyShown("always", true));
        verify(NotificationPrefs.bodyShown("always", false));
        verify(!NotificationPrefs.bodyShown("never", false));
        verify(!NotificationPrefs.bodyShown("unlocked", true));
        verify(NotificationPrefs.bodyShown("unlocked", false));
    }

    function test_hiddenPreviewShowsTheAppNameAndAGenericLine() {
        const hidden = NotificationPrefs.display(false, "Re: salary", "<b>secret</b>", "Mail", "Notification");
        compare(hidden.title, "Mail");
        compare(hidden.body, "Notification");
        const nameless = NotificationPrefs.display(false, "Re: salary", "x", "", "Notification");
        compare(nameless.title, "Notification");
        const shown = NotificationPrefs.display(true, "Re: salary", "text", "Mail", "Notification");
        compare(shown.title, "Re: salary");
        compare(shown.body, "text");
    }

    function test_hiddenPreviewShowsNoImageAndNoSenderActions() {
        compare(NotificationPrefs.imageShown(false, "file:///photo.png"), "");
        compare(NotificationPrefs.imageShown(true, "file:///photo.png"), "file:///photo.png");
        compare(NotificationPrefs.actionsShown(false, "[{\"id\":\"reply\",\"text\":\"Reply to Anna\"}]"), "[]");
        compare(NotificationPrefs.actionsShown(true, "[{\"id\":\"a\"}]"), "[{\"id\":\"a\"}]");
    }

    function test_hiddenPreviewKeepsOnlyAPlainThemeAppIcon() {
        compare(NotificationPrefs.appIconShown(true, "/home/u/photo.jpg"), "/home/u/photo.jpg");
        compare(NotificationPrefs.appIconShown(false, "/home/u/photo.jpg"), "");
        compare(NotificationPrefs.appIconShown(false, "file:///tmp/p.png"), "");
        compare(NotificationPrefs.appIconShown(false, "image://x/y"), "");
        compare(NotificationPrefs.appIconShown(false, "../secret"), "");
        compare(NotificationPrefs.appIconShown(false, "a..b"), "");
        compare(NotificationPrefs.appIconShown(false, "org.mozilla.firefox"), "org.mozilla.firefox");
        compare(NotificationPrefs.appIconShown(false, "mail-unread"), "mail-unread");
        compare(NotificationPrefs.appIconShown(false, ""), "");
        compare(NotificationPrefs.appIconShown(false, undefined), "");
    }

    // The one name test (review of 6e24d36, Quick Settings merge): appIconShown and the shell's History.safeIconName both
    // use NotificationPrefs.safeIconName.
    function test_safeIconNameIsTheHiddenPreviewRule() {
        for (const name of ["firefox", "org.gnome.Nautilus", "steam_icon_570", "a".repeat(128)])
            compare(NotificationPrefs.appIconShown(false, name), NotificationPrefs.safeIconName(name), name);
        for (const name of ["a".repeat(129), ".hidden", "-x", "_x", "a\\b", "fire\u0000fox", "fire\nfox", "fire fox", "hicolor/../../x", "file:x"]) {
            compare(NotificationPrefs.safeIconName(name), "", JSON.stringify(name));
            compare(NotificationPrefs.appIconShown(false, name), "", JSON.stringify(name));
        }
        compare(NotificationPrefs.safeIconName(42), "");
    }

    function test_appsToList() {
        compare(NotificationPrefs.appsToList(["Zed", "mail", "Alpha"], list), ["Alpha", "Mail", "Signal", "Zed"]);
        compare(NotificationPrefs.appsToList(undefined, []), []);
        compare(NotificationPrefs.appsToList(["", 4], []), []);
        // An app named like a member of Object.prototype is an app like any other.
        const odd = NotificationPrefs.appsToList(["constructor", "__proto__", "constructor"], []);
        compare(odd.length, 2);
        verify(odd.indexOf("constructor") >= 0 && odd.indexOf("__proto__") >= 0);
        compare(NotificationPrefs.problem([{app: "constructor", previews: "never"}, {app: "__proto__", previews: "never"}]), "");
        compare(NotificationPrefs.normalize([{app: "constructor", previews: "never"}, {app: "toString", previews: "never"}]).length, 2);
        compare(NotificationPrefs.normalizeStyles([{app: "constructor", style: "alerts"}, {app: "constructor", style: "none"}]).length, 1);
    }

    // GF-107: alert style per app.
    function test_alertStyles() {
        const l = [{app: "Signal", style: "alerts"}, {app: "Mail", style: "none"}];
        compare(NotificationPrefs.problemStyles(l), "");
        verify(NotificationPrefs.problemStyles([{app: "A", style: "loud"}]) !== "");
        verify(NotificationPrefs.problemStyles([{app: "A", style: "none"}, {app: "a", style: "alerts"}]) !== "");
        verify(NotificationPrefs.problemStyles("x") !== "");
        compare(NotificationPrefs.styleFor(l, "signal "), "alerts");
        compare(NotificationPrefs.styleFor(l, "Other"), "banners");
        const a = NotificationPrefs.withStyle(l, "Signal", "banners");
        compare(NotificationPrefs.styleFor(a, "Signal"), "banners");
        compare(a.length, 1);
        compare(NotificationPrefs.normalizeStyles([{app: "A", style: "x"}, null, {app: "B", style: "none"}]).length, 1);
    }

    function test_bannerTimeoutByStyle() {
        compare(NotificationPrefs.bannerTimeoutFor("banners", 5000), 5000);
        compare(NotificationPrefs.bannerTimeoutFor("alerts", 5000), 0);
        compare(NotificationPrefs.bannerTimeoutFor("none", 5000), null);
    }

    // GF-113: history retention.
    function test_historyRetention() {
        compare(NotificationPrefs.historyMaxAge("week"), 7 * 24 * 3600 * 1000);
        compare(NotificationPrefs.historyMaxAge("day"), 24 * 3600 * 1000);
        compare(NotificationPrefs.historyMaxAge("never"), 0);
        compare(NotificationPrefs.historyMaxAge("bogus"), 7 * 24 * 3600 * 1000);
        verify(NotificationPrefs.validHistory("day"));
        verify(!NotificationPrefs.validHistory("month"));
    }
}
