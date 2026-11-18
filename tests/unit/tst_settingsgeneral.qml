import QtQuick
import QtTest
import "../../apps/settings/qml/General.js" as General

// The pure logic of Settings > General's sub-panes (apps/settings/qml/General.js): the D-Bus states, the action maps the
// Backend checks again (systembus.cpp), command output, desktop entries. Nothing here touches the machine.
TestCase {
    name: "SettingsGeneral"

    // ADR-0053: the path grassfield-report printed, taken only when it is a report file inside the home; the Files command.
    function test_diagnosticReportPath() {
        const home = "/home/u";
        const ok = "/home/u/Téléchargements/grassfield-report-20261105-100000.txt";
        compare(General.reportPath(ok + "\n"), ok);
        compare(General.reportPath("noise\n" + ok + "\n\n"), ok);
        // The report was written: any clean absolute report path is named (XDG_DOWNLOAD_DIR may lie outside the home)...
        compare(General.reportPath("/data/downloads/grassfield-report-1.txt\n"), "/data/downloads/grassfield-report-1.txt");
        for (const bad of ["", "\n", "/home/u/../v/grassfield-report-1.txt", "/home/u/./grassfield-report-1.txt", "/home/u//grassfield-report-1.txt",
                           "/home/u/report.txt", "/home/u/grassfield-report-1.sh", "relative/grassfield-report-1.txt", "/home/u/a\u0007/grassfield-report-1.txt"])
            compare(General.reportPath(bad), "", bad);
        compare(General.reportPath(null), "");
        // ...but Files opens only a folder inside the home (systemguard.cpp isRevealInFiles).
        verify(General.revealable(ok, home));
        verify(General.revealable(ok, home + "/"));
        verify(!General.revealable("/data/downloads/grassfield-report-1.txt", home));
        verify(!General.revealable("/home/uu/grassfield-report-1.txt", home));
        verify(!General.revealable(ok, "/"));
        verify(!General.revealable(ok, ""));
        verify(!General.revealable("", home));
        compare(General.reportName(ok), "grassfield-report-20261105-100000.txt");
        compare(General.revealArgv(ok), ["/usr/bin/grassfield-files", "--", "/home/u/Téléchargements"]);
        compare(General.REPORT_ARGV, ["/usr/lib/grassfield/grassfield-report"]);
    }

    function test_hostState() {
        const h = General.parseHost('{"pretty":"Alex’s Laptop","static":"alexs-laptop","hostname":"x","chassis":"laptop","vendor":"LENOVO","model":"ThinkPad X1 Carbon Gen 11"}');
        compare(h.pretty, "Alex’s Laptop");
        compare(General.computerName(h), "Alex’s Laptop");
        compare(General.computerName({pretty: "", "static": "box", hostname: "t"}), "box");
        compare(General.computerName({pretty: "", "static": "", hostname: "t"}), "t");
        compare(General.parseHost("[]"), null);
        compare(General.parseHost("nope"), null);
        // Strings only: a number or an object becomes "".
        compare(General.parseHost('{"pretty":3,"model":{}}').pretty, "");
    }

    function test_modelName() {
        compare(General.modelName({vendor: "LENOVO", model: "ThinkPad X1 Carbon Gen 11"}), "LENOVO ThinkPad X1 Carbon Gen 11");
        compare(General.modelName({vendor: "Framework", model: "Framework Laptop 13"}), "Framework Laptop 13");
        compare(General.modelName({vendor: "Apple Inc.", model: "MacBookPro18,3"}), "Apple Inc. MacBookPro18,3");
        compare(General.modelName({vendor: "System manufacturer", model: "System Product Name"}), "");
        compare(General.modelName({vendor: "ASUS", model: "To Be Filled By O.E.M."}), "ASUS");
        compare(General.modelName(null), "");
    }

    function test_deviceKind() {
        compare(General.deviceKind("laptop"), "laptop");
        compare(General.deviceKind("convertible"), "laptop");
        compare(General.deviceKind("desktop"), "desktop");
        compare(General.deviceKind("vm"), "desktop");
        compare(General.deviceKind(""), "desktop");
    }

    function test_rename() {
        compare(General.hostSetName("  Grassfield Reference "), {op: "host.setName", name: "Grassfield Reference"});
        compare(General.hostSetName(""), null);
        compare(General.hostSetName("   "), null);
        compare(General.hostSetName("a\nb"), null);
        compare(General.hostSetName("x".repeat(65)), null);
        verify(General.hostSetName("x".repeat(64)) !== null);
    }

    function test_diagonal() {
        compare(General.diagonalInches(302, 188), 14);
        compare(General.diagonalInches(286, 179), 13.3);
        compare(General.diagonalInches(0, 188), 0);
        compare(General.diagonalInches(undefined, undefined), 0);
    }

    function test_startupVolume() {
        compare(General.startupVolume([{root: "/"}, {root: "/home"}]).root, "/");
        // A list from the Backend need not be a JavaScript Array.
        compare(General.startupVolume({length: 1, 0: {root: "/"}}).root, "/");
        compare(General.startupVolume([]), null);
        compare(General.startupVolume(undefined), null);
    }

    function test_storage() {
        const du = General.parseDu("18400000000\t/home/u/Documents\n41700000000\t/home/u/Pictures\ndu: cannot read\n");
        compare(du["/home/u/Documents"], 18400000000);
        compare(du["/home/u/Pictures"], 41700000000);
        compare(General.packagesBytes("Name : a\nInstalled Size  : 1.50 GiB\nInstalled Size  : 512.00 KiB\nInstalled Size  : 10 B\n"), Math.round(1.5 * 1073741824 + 512 * 1024 + 10));
        compare(General.packagesBytes(""), 0);
        const argv = General.duArgv("/home/u");
        compare(argv.slice(0, 5), ["du", "-s", "-x", "--block-size=1", "--"]);
        compare(argv.length, 5 + 7);
        verify(argv.slice(5).every(p => p.indexOf("/home/u/") === 0));
        const volume = {total: 1000, available: 400};
        const cats = General.categories(volume, {"/home/u/Documents": 100, "/home/u/Pictures": 250}, 150, "/home/u");
        compare(cats.map(c => c.id), ["pictures", "applications", "documents", "system"]);
        compare(cats[3].bytes, 600 - 500);
        // What is counted never makes System negative.
        compare(General.categories({total: 100, available: 90}, {"/home/u/Documents": 50}, 0, "/home/u").pop().bytes, 0);
        compare(General.categories(null, {}, 0, "/home/u"), []);
    }

    function test_barWidths() {
        compare(General.barWidths([100, 300, 600], 102, 1, 1), [10, 30, 60]);
        // A tiny segment stays visible; the free space (last) takes the rest.
        compare(General.barWidths([1, 999], 101, 1, 1), [1, 99]);
        compare(General.barWidths([0, 0, 50], 52, 1, 1), [1, 1, 48]);
        compare(General.barWidths([], 100, 1, 1), []);
        const w = General.barWidths([123, 456, 789, 1000], 438, 1, 1);
        compare(w.reduce((a, b) => a + b, 0) + 3, 438);
    }

    function test_time() {
        const t = General.parseTime('{"zone":"Europe/Paris","ntp":true,"canNtp":true,"synced":false,"localRtc":false,"usec":"1792832460123456","server":"a","servers":["a","b",3]}');
        compare(t.zone, "Europe/Paris");
        verify(t.ntp);
        compare(t.servers, ["a", "b"]);
        compare(General.msOf(t), 1792832460123);
        compare(General.parseTime('{"usec":"12; rm"}').usec, "0");
        compare(General.parseZones('{"zones":["Europe/Paris","../x","UTC"]}'), ["Europe/Paris", "UTC"]);
        compare(General.cityOf("America/Argentina/Buenos_Aires"), "Buenos Aires");
        compare(General.areaOf("Europe/Paris"), "Europe");
        compare(General.cityOf("UTC"), "UTC");
        compare(General.areaOf("UTC"), "");
        const zones = ["Europe/Zurich", "America/New_York", "Europe/Paris", "Asia/Tokyo", "Pacific/Port_Moresby"];
        compare(General.cityMatches(zones, "zur", 5), ["Europe/Zurich"]);
        compare(General.cityMatches(zones, "Zür", 5), ["Europe/Zurich"]);
        compare(General.cityMatches(zones, "new y", 5), ["America/New_York"]);
        compare(General.cityMatches(zones, "or", 5), ["America/New_York", "Pacific/Port_Moresby"]);
        compare(General.cityMatches(zones, "  ", 5), []);
        compare(General.timeNtp(true), {op: "time.ntp", on: true});
        compare(General.timeNtp("yes"), null);
        compare(General.timeZone("Europe/Paris"), {op: "time.zone", zone: "Europe/Paris"});
        compare(General.timeZone("../../etc/passwd"), null);
        compare(General.timeZone("Europe/Paris\n"), null);
        compare(General.timeSet(1792832460123.9), {op: "time.set", usec: "1792832460123000"});
        compare(General.timeSet(0), null);
        compare(General.timeSet(NaN), null);
    }

    function test_wallClock() {
        // 2026-10-24 09:01:00 UTC: 11:01 in Paris (UTC+2), 05:01 in New York (UTC-4), whatever this process's own zone is.
        const ms = 1792832460000;
        const paris = General.wallClock(ms, 7200);
        compare(paris.getHours(), 11);
        compare(paris.getMinutes(), 1);
        compare(paris.getDate(), 24);
        compare(General.wallClock(ms, -14400).getHours(), 5);
        compare(General.fromWallClock(paris, 7200), ms);
        compare(General.fromWallClock(General.wallClock(ms, 0), 0), ms);
        // A date across a daylight-saving change takes the offset of that date: in a zone at UTC+2 until 2026-10-25 01:00 UTC
        // and UTC+1 after it (Paris), 15 January 2027 12:00 set in July is 11:00 UTC, not 10:00.
        const change = Date.UTC(2026, 9, 25, 1, 0, 0);
        const offsetAt = at => at < change ? 7200 : 3600;
        const january = General.wallClock(Date.UTC(2027, 0, 15, 11, 0, 0), 3600);
        compare(january.getHours(), 12);
        compare(General.fromWallClockAt(january, 7200, offsetAt), Date.UTC(2027, 0, 15, 11, 0, 0));
        compare(General.fromWallClockAt(paris, 7200, offsetAt), ms);
        // Two hours after the change (past the hour the clocks read twice), found from the offset before it.
        compare(General.fromWallClockAt(General.wallClock(change + 7200000, 3600), 7200, offsetAt), change + 7200000);
    }

    function test_uses24Hour() {
        verify(General.uses24Hour("24", "h:mm AP"));
        verify(!General.uses24Hour("12", "HH:mm"));
        verify(General.uses24Hour("auto", "HH:mm"));
        verify(!General.uses24Hour("auto", "h:mm AP"));
        // A quoted literal is not an AM/PM field.
        verify(General.uses24Hour("auto", "HH'h'mm 'Uhr'"));
        verify(!General.uses24Hour("auto", "h:mm a"));
    }

    function test_formatsLocale() {
        // The language's words with the region's formats when Qt has the pair; else the region's own locale.
        compare(General.formatsLocale("en_US", "fr_CH").name, "en_CH");
        compare(General.formatsLocale("en_US", "de_DE").name, "en_DE");
        compare(General.formatsLocale("fr_FR", "en_US").name, "en_US");
        compare(General.formatsLocale("fr_FR", "auto").name, "fr_FR");
        compare(General.formatsLocale("fr_FR", "fr_CH; rm").name, "fr_FR");
    }

    function test_language() {
        const list = General.parseLanguages("English\ten\tEnglish\nFrançais\tfr\tFrench\nbad line\nX\tFR\tbad\n中文 (简体)\tzh-CN\tChinese (Simplified)\n");
        compare(list.length, 3);
        compare(list[1], {name: "Français", code: "fr", english: "French"});
        compare(list[2].code, "zh-CN");
        compare(General.currentLanguage("fr\n"), "fr");
        compare(General.currentLanguage("fr; rm\n"), "");
        compare(General.languageArgv("fr"), ["omarchy-language", "fr"]);
        // Omarchy 4.0.4 has no omarchy-language: the page says a newer Omarchy is needed (never a bare "Unknown" without a
        // picker); installed but no list in a real session: it says so; a dev session reads nothing and says nothing more.
        compare(General.languageNote(false, false, false, 0), "tool");
        compare(General.languageNote(false, true, false, 0), "tool");
        compare(General.languageNote(true, false, true, 0), "list");
        compare(General.languageNote(true, false, false, 0), "");
        compare(General.languageNote(true, false, true, 12), "");
        compare(General.languageNote(true, true, false, 0), "");
        compare(General.languageName("français", "fr_FR"), "Français");
        compare(General.languageName("American English", "en_US"), "American English");
        compare(General.languageName("", "C"), "C");
        compare(General.languageArgv("--help"), null);
        compare(General.languageArgv("fr\n"), null);
    }

    function test_pendingActions() {
        // The waiting state of a change that may ask for a password is the Backend's (integrator review of PR #6): a page opened
        // again while a polkit dialog is up shows which change waits, and its controls stay off (the Backend refuses a second
        // one of the tag anyway).
        compare(General.pendingTimeOp({}), "");
        compare(General.pendingTimeOp(undefined), "");
        compare(General.pendingTimeOp({"time.act": "automatic time"}), "ntp");
        compare(General.pendingTimeOp({"time.act": "date and time"}), "set");
        compare(General.pendingTimeOp({"time.act": "time zone"}), "zone");
        compare(General.pendingTimeOp({"host.act": "computer name"}), "");
    }

    function test_desktopEntries() {
        const text = "[Desktop Entry]\nType=Application\nName=Syncthing\nName[fr]=Syncthing (fr)\nExec=syncthing\nIcon=syncthing\nOnlyShowIn=GNOME;Hyprland;\n[Desktop Action x]\nName=Other\n";
        const e = General.parseDesktopEntry(text, "fr_FR.UTF-8");
        compare(e.name, "Syncthing (fr)");
        compare(e.exec, "syncthing");
        compare(e.onlyShowIn, ["GNOME", "Hyprland"]);
        compare(General.parseDesktopEntry(text, "de").name, "Syncthing");
        verify(General.startsHere(e, ["Hyprland"]));
        verify(!General.startsHere(e, ["KDE"]));
        verify(!General.startsHere(General.parseDesktopEntry("[Desktop Entry]\nName=a\nHidden=true\n", ""), ["Hyprland"]));
        verify(!General.startsHere(General.parseDesktopEntry("[Desktop Entry]\nName=a\nX-GNOME-Autostart-enabled=false\n", ""), ["Hyprland"]));
        verify(!General.startsHere(General.parseDesktopEntry("[Desktop Entry]\nName=a\nNotShowIn=Hyprland;\n", ""), ["Hyprland"]));
    }

    function test_loginItems() {
        const system = [
            {file: "fcitx.desktop", text: "[Desktop Entry]\nName=Fcitx 5\nIcon=fcitx\n"},
            {file: "applet.desktop", text: "[Desktop Entry]\nName=Print Applet\n"},
            {file: "gnome-only.desktop", text: "[Desktop Entry]\nName=GNOME thing\nOnlyShowIn=GNOME;\n"}
        ];
        const user = [
            {file: "applet.desktop", text: "[Desktop Entry]\nHidden=true\n"},
            {file: "notes.desktop", text: "[Desktop Entry]\nName=Notes\nExec=notes\n"}
        ];
        const items = General.loginItems(user, system, ["Hyprland"], "en");
        compare(items.map(i => i.name), ["Fcitx 5", "Notes", "Print Applet"]);
        const applet = items.filter(i => i.file === "applet.desktop")[0];
        verify(!applet.enabled);
        verify(applet.user && applet.system);
        verify(items.filter(i => i.file === "notes.desktop")[0].enabled);
        verify(General.validEntryFile("notes.desktop"));
        verify(!General.validEntryFile("../notes.desktop"));
        verify(!General.validEntryFile("notes.desktop\n"));
        verify(!General.validEntryFile("notes"));
        compare(General.hiddenEntryText(), "[Desktop Entry]\nType=Application\nHidden=true\n");
        const copy = General.loginEntryText("[Desktop Entry]\nName=App\nExec=app\nHidden=true\nOnlyShowIn=GNOME;\n[Desktop Action n]\nOnlyShowIn=x\n");
        compare(copy, "[Desktop Entry]\nName=App\nExec=app\n[Desktop Action n]\nOnlyShowIn=x\n");
    }

    function test_hiddenToggle() {
        compare(General.setHidden("[Desktop Entry]\nName=Notes\nExec=notes\n", true), "[Desktop Entry]\nHidden=true\nName=Notes\nExec=notes\n");
        compare(General.setHidden("[Desktop Entry]\nHidden=true\nName=Notes\n[Desktop Action a]\nHidden=x\n", false), "[Desktop Entry]\nName=Notes\n[Desktop Action a]\nHidden=x\n");
        verify(General.onlyOverride(General.hiddenEntryText()));
        verify(!General.onlyOverride("[Desktop Entry]\nType=Application\nHidden=true\nExec=custom\n"));
    }

    function test_applications() {
        const apps = General.applications([
            {file: "notes.desktop", text: "[Desktop Entry]\nType=Application\nName=Notes\nExec=notes\nIcon=notes\n"},
            {file: "notes.desktop", text: "[Desktop Entry]\nType=Application\nName=Old Notes\nExec=old\n"},
            {file: "helper.desktop", text: "[Desktop Entry]\nType=Application\nName=Helper\nExec=h\nNoDisplay=true\n"},
            {file: "link.desktop", text: "[Desktop Entry]\nType=Link\nName=Link\nURL=https://x\n"},
            {file: "gnome.desktop", text: "[Desktop Entry]\nType=Application\nName=Gnome\nExec=g\nOnlyShowIn=GNOME;\n"},
            {file: "../x.desktop", text: "[Desktop Entry]\nType=Application\nName=X\nExec=x\n"},
            {file: "atlas.desktop", text: "[Desktop Entry]\nType=Application\nName=Atlas\nExec=atlas\n"}
        ], ["Hyprland"], "en");
        compare(apps.map(a => a.name), ["Atlas", "Notes"]);
        compare(apps[1].icon, "notes");
    }

    function test_userUnits() {
        compare(General.userEnable("sync.service", false), {op: "user.enable", unit: "sync.service", on: false});
        compare(General.userEnable("sync.timer", true), null);
        compare(General.userEnable("../x.service", true), null);
        compare(General.userEnable("x.service", "on"), null);
        compare(General.parseUnits('{"units":[{"unit":"a.service","path":"/p","state":"enabled"},{"unit":3}]}').length, 1);
        compare(General.parseUnits("x"), []);
        compare(General.unitDescription("[Unit]\nDescription=File synchronisation\n[Service]\nDescription=x\n"), "File synchronisation");
        compare(General.unitDescription("[Service]\nExecStart=x\n"), "");
    }
}
