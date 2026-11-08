import QtQuick
import QtTest
import "../../shell/services/AppLaunch.js" as AppLaunch

// Launch helpers of Apps.qml: isolated XDG homes for apps started from a GRASSFIELD_DEV session, and
// Exec field-code stripping for the dev launch path.
TestCase {
    name: "AppLaunch"

    function test_isolatedEnvironment() {
        const env = AppLaunch.isolatedEnvironment("/w/.dev/apps-home");
        compare(env.XDG_CONFIG_HOME, "/w/.dev/apps-home/config");
        compare(env.XDG_CACHE_HOME, "/w/.dev/apps-home/cache");
        compare(env.XDG_STATE_HOME, "/w/.dev/apps-home/state");
        compare(env.XDG_DATA_HOME, "/w/.dev/apps-home/data");
        compare(env.HOME, "/w/.dev/apps-home/home");
        // The system data dirs keep resolving desktop entries and icons.
        verify(!("XDG_DATA_DIRS" in env));
    }

    // Regression (PR #74 review): the nested dev shell's Search listed the owner's recent files.
    function test_dataHomeDevIsNotTheOwners() {
        const apps = "/w/.dev/apps-home";
        compare(AppLaunch.dataHome(true, apps, "/home/o/.local/share", "/home/o"), apps + "/data");
        compare(AppLaunch.dataHome(true, apps, "", "/home/o"), apps + "/data");
        // The shell reads where the isolated apps write (Files' Recents).
        compare(AppLaunch.dataHome(true, apps, "", "/home/o"), AppLaunch.isolatedEnvironment(apps).XDG_DATA_HOME);
        // A real session is unchanged.
        compare(AppLaunch.dataHome(false, apps, "/x/share", "/home/o"), "/x/share");
        compare(AppLaunch.dataHome(false, apps, "", "/home/o"), "/home/o/.local/share");
    }

    function test_searchRootDevIsNotHome() {
        const apps = "/w/.dev/apps-home";
        compare(AppLaunch.searchRoot(true, "", apps, "/home/o"), apps + "/files");
        compare(AppLaunch.searchRoot(true, "/fixture", apps, "/home/o"), "/fixture");
        compare(AppLaunch.searchRoot(false, "", apps, "/home/o"), "/home/o");
    }

    function test_mergeEnvironment() {
        const base = {"HOME": "/h"};
        const extra = {"XCURSOR_SIZE": "48"};
        compare(AppLaunch.mergeEnvironment(base, extra), {"HOME": "/h", "XCURSOR_SIZE": "48"});
        compare(AppLaunch.mergeEnvironment({}, {}), {});
        compare(AppLaunch.mergeEnvironment(base, {}), {"HOME": "/h"});
        // Neither input is modified.
        compare(base, {"HOME": "/h"});
        compare(extra, {"XCURSOR_SIZE": "48"});
    }

    // The apps the shell starts get GTK_USE_PORTAL=1 back when env-grassfield recorded that the session sets it
    // (Mode.appsGtkPortal; the shell's own unit clears it, ADR-0035 D-8); nothing otherwise.
    function test_portalEnvironment() {
        compare(AppLaunch.portalEnvironment(true), {"GTK_USE_PORTAL": "1"});
        for (const other of [false, undefined, null, "", "1", 1])
            compare(AppLaunch.portalEnvironment(other), {}, String(other));
        compare(AppLaunch.mergeEnvironment(AppLaunch.portalEnvironment(true), {"XCURSOR_SIZE": "48"}),
                {"GTK_USE_PORTAL": "1", "XCURSOR_SIZE": "48"});
    }

    // The Qt platform theme of the session (ADR-0054) comes back to the apps the shell starts: the shell's unit pins gtk3 for itself
    // and an app inherits the shell's environment, so GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME carries the session's value. Exactly
    // that value; the pin (gtk3) never travels.
    function test_themeEnvironment() {
        compare(AppLaunch.themeEnvironment("xdgdesktopportal"), {"QT_QPA_PLATFORMTHEME": "xdgdesktopportal"});
        for (const other of ["", "gtk3", "xdgdesktopportal2", "xdgdesktopportal:gtk3", "kde", undefined, null, true, 1])
            compare(AppLaunch.themeEnvironment(other), {}, String(other));
        // What Apps.launchEnvironment() builds: never empty once the session chose the portal theme (so the environment path of
        // launchNow is taken), the pointer entries and GTK_USE_PORTAL kept, no gtk3 anywhere.
        const session = AppLaunch.mergeEnvironment(AppLaunch.portalEnvironment(true), AppLaunch.themeEnvironment("xdgdesktopportal"));
        const all = AppLaunch.mergeEnvironment(AppLaunch.mergeEnvironment({}, session), {"XCURSOR_SIZE": "48"});
        compare(all, {"GTK_USE_PORTAL": "1", "QT_QPA_PLATFORMTHEME": "xdgdesktopportal", "XCURSOR_SIZE": "48"});
        verify(Object.keys(all).length > 0);
    }

    function test_appsHomeIsNextToTheStateHome() {
        compare(AppLaunch.appsHomeFor("/w/.dev/state", "/run"), "/w/.dev/apps-home");
        compare(AppLaunch.appsHomeFor("/w/.dev/state/", "/run"), "/w/.dev/apps-home");
        compare(AppLaunch.appsHomeFor("", "/run"), "/run/grassfield-dev/apps-home");
    }

    // Empty Trash (Dock Trash menu): a dev session empties ONLY the isolated trash under its apps-home (ADR-0011), never gio's
    // trash:/// (served by the owner's session) and never the owner's ~/.local/share/Trash.
    function test_emptyTrashDevIsOnlyTheIsolatedTrash() {
        const argv = AppLaunch.emptyTrashArgv(true, "/w/.dev/apps-home");
        compare(argv.join(" "), "find /w/.dev/apps-home/data/Trash/files /w/.dev/apps-home/data/Trash/info -mindepth 1 -delete");
        verify(argv.indexOf("gio") < 0);
        for (const a of argv)
            verify(a.indexOf("/.local/share/Trash") < 0 && a.indexOf("trash:") < 0, a);
    }

    function test_emptyTrashDevRefusesAnythingButAnAppsHome() {
        for (const bad of ["", "relative/apps-home", "/w/.dev/apps-home/../../home/u/apps-home", "/", "/home/u", "/w/.dev/state", "/w/ .dev/apps-home\n", "/w/.dev/apps-home/"])
            compare(AppLaunch.emptyTrashArgv(true, bad), null, "accepted: " + bad);
    }

    function test_emptyTrashRealSessionUsesGio() {
        compare(AppLaunch.emptyTrashArgv(false, "/w/.dev/apps-home").join(" "), "gio trash --empty");
    }

    function test_folderAwareArgv() {
        const s = "/usr/share/grassfield/shell/services/open-real.sh";
        // A real session: gio open and xdg-open go through the folder policy, scoped afterwards by the caller.
        compare(AppLaunch.folderAwareArgv(["gio", "open", "/h/a b"], s, true), ["bash", s, "gio", "/h/a b"]);
        compare(AppLaunch.folderAwareArgv(["/usr/bin/gio", "open", "/a", "/b"], s, true), ["bash", s, "gio", "/a", "/b"]);
        compare(AppLaunch.folderAwareArgv(["xdg-open", "/h/x.txt"], s, true), ["bash", s, "xdg-open", "/h/x.txt"]);
        compare(AppLaunch.folderAwareArgv(["gio", "open", "trash:///"], s, true), ["bash", s, "gio", "trash:///"]);
        // Anything else, a dev session and an empty request stay as they are.
        compare(AppLaunch.folderAwareArgv(["gtk-launch", "x", "/f"], s, true), ["gtk-launch", "x", "/f"]);
        compare(AppLaunch.folderAwareArgv(["gio", "trash", "--", "/f"], s, true), ["gio", "trash", "--", "/f"]);
        compare(AppLaunch.folderAwareArgv(["gio", "open"], s, true), ["gio", "open"]);
        compare(AppLaunch.folderAwareArgv(["gio", "open", "/h"], s, false), ["gio", "open", "/h"]);
        compare(AppLaunch.folderAwareArgv(undefined, s, true), []);
    }

    function test_scopedArgv() {
        // A real session: the application runs in a scope of its own through uwsm's app launcher.
        compare(AppLaunch.scopedArgv(["foot"], true), ["uwsm-app", "--", "foot"]);
        compare(AppLaunch.scopedArgv(["gio", "open", "/h/a b.txt"], true), ["uwsm-app", "--", "gio", "open", "/h/a b.txt"]);
        // An argument that looks like an option stays the application's (after "--").
        compare(AppLaunch.scopedArgv(["-x"], true), ["uwsm-app", "--", "-x"]);
        // A dev session or no uwsm-app: unchanged; nothing to start: nothing added.
        compare(AppLaunch.scopedArgv(["foot", "-e", "top"], false), ["foot", "-e", "top"]);
        compare(AppLaunch.scopedArgv([], true), []);
        compare(AppLaunch.scopedArgv(undefined, true), []);
        // The input is not modified.
        const argv = ["foot"];
        AppLaunch.scopedArgv(argv, true);
        compare(argv, ["foot"]);
    }

    function test_fieldCodesAreDropped() {
        compare(AppLaunch.stripFieldCodes(["chromium", "%U"]), ["chromium"]);
        compare(AppLaunch.stripFieldCodes(["foot", "--title", "%c", "%f"]), ["foot", "--title"]);
        compare(AppLaunch.stripFieldCodes(["app", "--url=%u", "100%%"]), ["app", "--url=", "100%"]);
        compare(AppLaunch.stripFieldCodes([]), []);
        compare(AppLaunch.stripFieldCodes(["%U"]), []);
    }

    // Dev open policy (ADR-0011): every helper that asks another application to open something is recognised.
    function test_openRequests() {
        compare(AppLaunch.openRequest(["gio", "open", "/a"]).targets, ["/a"]);
        compare(AppLaunch.openRequest(["gio", "open", "/a", "/b"]).targets, ["/a", "/b"]);
        compare(AppLaunch.openRequest(["/usr/bin/gio", "open", "trash:///"]).targets, ["trash:///"]);
        compare(AppLaunch.openRequest(["xdg-open", "/a"]).targets, ["/a"]);
        compare(AppLaunch.openRequest(["gtk-launch", "org.gnome.gedit", "/a"]).targets, ["/a"]);
        compare(AppLaunch.openRequest(["gtk-launch", "org.gnome.gedit"]).refuse, "application launch");
        compare(AppLaunch.openRequest(["gio", "launch", "x.desktop"]).refuse, "application launch");
        compare(AppLaunch.openRequest(["gio", "open"]).refuse, "nothing to open");
    }

    function test_otherHelpersAreNotOpenRequests() {
        compare(AppLaunch.openRequest(["gio", "trash", "--", "/a"]), null);
        compare(AppLaunch.openRequest(["nm-connection-editor"]), null);
        compare(AppLaunch.openRequest([]), null);
    }

    function test_autostart() {
        compare(AppLaunch.autostartDir(true, "/w/.dev/apps-home", "/x", "/h"), "/w/.dev/apps-home/config/autostart");
        compare(AppLaunch.autostartDir(false, "", "/x", "/h"), "/x/autostart");
        compare(AppLaunch.autostartDir(false, "", "", "/h"), "/h/.config/autostart");
        const text = AppLaunch.autostartText({name: "My App", icon: "my-app", command: ["/usr/bin/my app", "--x=%u", "50%"], runInTerminal: false});
        verify(text.startsWith("[Desktop Entry]\nType=Application\nName=My App\n"));
        verify(text.indexOf('Exec="/usr/bin/my app" --x= "50%%"\n') > 0);
        verify(text.indexOf("Icon=my-app\n") > 0 && text.indexOf("Terminal=false\n") > 0);
        compare(AppLaunch.execQuote("a$b"), '"a\\$b"');
    }

    // Hostile names and arguments: nothing can add a key or a line to the autostart file; backslashes follow the Desktop
    // Entry escape rules (the string escape after the quoting rule); control characters in Exec are refused.
    function test_autostartHostile() {
        const lines = t => t.split("\n").filter(l => l !== "");
        const bad = AppLaunch.autostartText({name: "Evil\nHidden=true\nExec=rm", icon: "i\rHidden=true", command: ["/bin/x"], runInTerminal: false});
        compare(lines(bad).filter(l => l.startsWith("Hidden=")).length, 0);
        compare(lines(bad).length, 6, "Entry, Type, Name, Exec, Icon, Terminal: no line is added");
        verify(bad.indexOf("Name=Evil\\nHidden=true\\nExec=rm\n") > 0);
        compare(AppLaunch.autostartText({name: "x", command: ["/bin/x", "a\nHidden=true"]}), "");
        compare(AppLaunch.autostartText({name: "x", command: ["/bin/x", "a\u0000b"]}), "");
        compare(AppLaunch.autostartText({name: "x", command: ["/bin/x", "a\u001b[0m"]}), "");
        compare(AppLaunch.autostartText({name: "x", command: ["%f"]}), "");
        // one literal backslash in a quoted argument is four backslashes in the file (quoting rule, then string escape)
        const bs = AppLaunch.autostartText({name: "a\\b", command: ["/bin/x", "c\\d"]});
        verify(bs.indexOf("Name=a\\\\b\n") > 0, bs);
        verify(bs.indexOf('Exec=/bin/x "c\\\\\\\\d"\n') > 0, bs);
        // empty, spaced, quoted and shell-looking arguments are quoted
        const q = AppLaunch.autostartText({name: "x", command: ["/bin/x", "", "a b", "q\"z", "$(id)", "it's"]});
        compare(AppLaunch.autostartText({name: "x", command: ["/bin/x", "t\tx"]}), "", "a tab in Exec is a control character");
        verify(q.indexOf('Exec=/bin/x "" "a b" "q\\\\"z" "\\\\$(id)" "it\'s"\n') > 0, q);
    }

    function test_autostartFileNames() {
        compare(AppLaunch.autostartFile("/d/autostart", "org.x.App"), "/d/autostart/org.x.App.desktop");
        compare(AppLaunch.autostartFile("/d/autostart", "../evil"), "");
        compare(AppLaunch.autostartFile("/d/autostart", "a/b"), "");
        compare(AppLaunch.autostartFile("/d/autostart", ".hidden"), "");
        compare(AppLaunch.autostartFile("/d/autostart", "a\nb"), "");
        compare(AppLaunch.autostartFile("/d/autostart", ""), "");
        compare(AppLaunch.autostartFile("/d/autostart", "x".repeat(300)), "");
        compare(AppLaunch.autostartFile("", "x"), "");
    }
}
