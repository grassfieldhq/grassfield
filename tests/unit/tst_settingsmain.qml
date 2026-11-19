import QtQuick
import QtTest
import Grassfield.Ui

// Settings' window (apps/settings/qml/Main.qml): Battery in the sidebar only with a laptop battery (UPower's display device),
// Mouse and Trackpad shown for the pointers there are (MouseTrackpad.paneFor), the pages' requests opening their sheets and the
// sheets' answers reaching the page, and every sheet giving the keyboard focus back to what opened it. The backend is a fake in
// a dev session: nothing reaches a bus, a tool or a file.
TestCase {
    id: testCase
    name: "SettingsMain"
    width: 800
    height: 700
    visible: true
    when: windowShown

    // /proc/bus/input/devices: an I2C touchpad (and its own mouse node), a USB mouse (tst_mousetrackpad.qml's fixtures).
    readonly property string touchpad: "I: Bus=0018 Vendor=0F1E Product=0101 Version=0100\nN: Name=\"GF Touchpad\"\nH: Handlers=mouse1 event8 \n"
        + "B: PROP=5\nB: EV=1b\nB: KEY=e520 10000 0 0 0 0\nB: ABS=2e0800000000003\n\n"
        + "I: Bus=0018 Vendor=0F1E Product=0101 Version=0100\nN: Name=\"GF Mouse\"\nH: Handlers=mouse0 event7 \nB: PROP=0\nB: EV=17\n"
        + "B: KEY=30000 0 0 0 0\nB: REL=3\n"
    readonly property string mouse: "I: Bus=0003 Vendor=3c52 Product=0001 Version=0100\nN: Name=\"USB Mouse\"\nH: Handlers=mouse2 event9 \n"
        + "B: PROP=0\nB: EV=17\nB: KEY=1f0000 0 0 0 0\nB: REL=1943\n"
    readonly property string battery: JSON.stringify({present: true, onBattery: true, percent: 71.6, state: 2, timeToEmpty: 3900, timeToFull: 0,
        capacity: 91.5, cycles: 212, limitSupported: true, limitEnabled: false, limitEnd: 80, history24: [], history10: []})

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: true
            readonly property string configFile: "/home/u/.config/grassfield/grassfield.json"
            readonly property string capabilitiesFile: "/run/user/1000/grassfield/capabilities.json"
            readonly property string bindingsFile: "/home/u/.config/hypr/bindings.lua"
            readonly property string stateDir: "/home/u/.local/state"
            readonly property string homeDir: "/home/u"
            readonly property string softwareUpdateFile: "/home/u/.local/state/grassfield/software-update.json"
            readonly property bool omarchyUpdate: true
            readonly property bool updateRunner: false
            readonly property string softwareUpdateRunFile: "/run/user/1000/grassfield/software-update-run.json"
            readonly property var applicationDirs: ["/home/u/.local/share/applications", "/usr/share/applications"]
            property var files: ({})
            property var busQueries: []
            property var queries: []
            property var actions: []
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            signal fileChanged(string path)
            // ADR-0045: a command on PATH (`commands`), Omarchy's read-only checks (recorded nowhere: no answer comes) and the
            // fingerprint enrolment's stop (counted).
            property var commands: []
            property int stops: 0
            function hasCommand(name: string): bool {
                return commands.indexOf(name) >= 0;
            }
            function readOnlyQuery(argv: var, tag: string): void {
            }
            function stopEnroll(): void {
                stops++;
            }
            function readText(path: string): var {
                return {exists: files[path] !== undefined, ok: files[path] !== undefined, text: files[path] ?? ""};
            }
            function writeText(path: string, text: string): string {
                return "";
            }
            function watch(path: string): void {
            }
            function query(argv: var, tag: string): void {
                queries.push({argv: argv, tag: tag});
            }
            function busQuery(what: string, tag: string): void {
                busQueries.push({what: what, tag: tag});
            }
            function act(what: string, argv: var, tag: string): bool {
                actions.push(argv);
                return true;
            }
            function busAct(what: string, op: var, tag: string): bool {
                actions.push(op);
                return true;
            }
            // Storage > All Volumes… (Backend::volumes).
            function volumes(): var {
                return [];
            }
            // Software Update: the shell is asked (the answer comes through the file).
            function askShellToCheck(tag: string): void {
            }
            function runUpdateChecker(tag: string): void {
            }
        }
    }

    function make(devices, props) {
        // The backend outlives the window (the pages read it until they go): it goes with the test case.
        const backend = fakeBackend.createObject(testCase);
        backend.files = {"/proc/bus/input/devices": devices};
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/Main.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const win = createTemporaryObject(comp, testCase, Object.assign({backend: backend, globalMenu: false}, props || {}));
        verify(win);
        return {backend: backend, win: win};
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
        return null;
    }

    function ids(win) {
        return win.available.map(s => s.id);
    }

    // The sheet that has this signal or function (each sheet has its own), and that `also` accepts.
    function sheet(win, member, also) {
        const s = win.sheets.find(x => x[member] !== undefined && (also === undefined || also(x)));
        verify(s, member);
        return s;
    }

    // The pane is built across frames (Main.qml's two loaders): select, then wait until the new page is in front.
    function showPage(win, id) {
        win.select(id);
        tryVerify(() => !win.pageLoading, 5000);
        wait(0);
    }

    function shownSheet(win) {
        return win.sheets.find(x => x.shown) ?? null;
    }

    // The window declares every sheet (34), but builds none of their bodies with it: each sheet's content is made the first time
    // it opens (Sheet.bodyComponent) and kept for the next time; a sheet without content of its own has only its text.
    function test_noSheetBodyExistsBeforeItsFirstShow() {
        const t = make(touchpad);
        compare(t.win.sheets.length, 34);
        const lazy = [];
        for (const s of t.win.sheets) {
            verify(s.bodyItem === null, s.title + ": no body before the first show");
            // Only the body's loader is in the slot: an inline body would be built with the window (Timers and Connections
            // have no geometry).
            for (let i = 0; i < s.body.length; i++) {
                const o = s.body[i];
                verify(o.sourceComponent !== undefined || o.width === undefined, s.title + ": an item of the body made with the window");
            }
            if (s.bodyComponent !== null)
                lazy.push(s);
        }
        compare(lazy.length, 23, "every sheet with content of its own builds it lazily");
        for (const s of lazy) {
            s.open();
            const made = s.bodyItem;
            verify(made !== null, s.title + ": built at the first show");
            verify(made.width > 0, s.title + ": as wide as the sheet");
            s.close();
            compare(s.bodyItem, made, s.title + ": kept once closed");
            s.open();
            compare(s.bodyItem, made, s.title + ": the same next time");
            s.close();
        }
    }

    // A pane is built across frames behind the one shown, then swapped in: the window never shows an empty pane, and the page
    // left goes once the new one is in front.
    function test_aPageIsBuiltBehindTheOneShown() {
        const t = make(touchpad);
        showPage(t.win, "desktop");
        const before = t.win.pageItem;
        verify(before !== null);
        t.win.select("appearance");
        verify(t.win.pageLoading, "built asynchronously, not within select()");
        compare(t.win.pageItem, before, "the page shown stays meanwhile");
        tryVerify(() => !t.win.pageLoading && t.win.pageItem !== before, 5000);
        verify(t.win.pageItem !== null);
        compare(t.win.pageItem.title, "Appearance");
        // Back and forth before the new one is ready: the last choice wins.
        t.win.select("desktop");
        t.win.select("appearance");
        tryVerify(() => !t.win.pageLoading, 5000);
        compare(t.win.selectedId, "appearance");
    }

    // UPower's display device decides: a laptop battery shows Battery, none (or no answer) hides it.
    // The toolbar's edge (ADR-0039 D3, step 15): no rule while the page is at its top, a hairline once its content has scrolled
    // under the toolbar, as Files does.
    function test_theToolbarRuleShowsOnceScrolled() {
        const t = make(touchpad);
        showPage(t.win, "desktop");
        wait(50);
        const rule = find(t.win.contentItem, i => i.objectName === "toolbarRule");
        verify(rule !== null);
        const flick = rule.flick;
        verify(flick !== null, "the page is a Flickable");
        flick.contentY = flick.originY;
        verify(!rule.visible, "at the top: no rule");
        flick.contentY = flick.originY + Tokens.spacingLg;
        verify(rule.visible, "scrolled: the rule");
        compare(rule.height, Tokens.appsBorderWidth);
        flick.contentY = flick.originY;
        verify(!rule.visible);
    }

    Component {
        id: otherWindow
        Window {
            width: 60
            height: 60
            visible: true
        }
    }

    // A window that is not key (ADR-0039 step 17): its sidebar selection turns neutral, the hover ink at the inactive opacity
    // with the label in the text colour, and takes the accent back when the window is key.
    function test_theSelectionTurnsNeutralWhileNotKey() {
        const t = make(touchpad);
        showPage(t.win, "desktop");
        t.win.requestActivate();
        tryVerify(() => t.win.active, 2000);
        wait(50);
        const fillOf = () => find(t.win.contentItem, i => String(i).indexOf("QQuickRectangle") === 0 && i.visible
                                  && (Qt.colorEqual(i.color, Appearance.colors.selection)
                                      || Qt.colorEqual(i.color, Appearance.withAlpha(Appearance.colors.hover, Appearance.inactiveSelectionOpacity))));
        let fill = fillOf();
        verify(fill !== null, "the selected row's fill");
        verify(Qt.colorEqual(fill.color, Appearance.colors.selection), "key: the accent");
        const other = createTemporaryObject(otherWindow, null);
        other.requestActivate();
        tryVerify(() => !t.win.active, 2000);
        verify(Qt.colorEqual(fill.color, Appearance.withAlpha(Appearance.colors.hover, Appearance.inactiveSelectionOpacity)), "not key: neutral");
        // A shell menu or the Control Center holds the keyboard for this window (the app holds it key, apps/keywindow.h): the
        // accent stays (the integrator's macOS decision on #88).
        Appearance.heldKeyWindow = t.win;
        verify(Qt.colorEqual(fill.color, Appearance.colors.selection), "held key: the accent");
        Appearance.heldKeyWindow = null;
        verify(Qt.colorEqual(fill.color, Appearance.withAlpha(Appearance.colors.hover, Appearance.inactiveSelectionOpacity)), "released: neutral");
        other.close();
        t.win.requestActivate();
        tryVerify(() => t.win.active, 2000);
        verify(Qt.colorEqual(fill.color, Appearance.colors.selection), "key again: the accent");
    }

    function test_hasBattery() {
        const t = make(testCase.touchpad);
        compare(t.backend.busQueries.filter(q => q.tag === "main.power").map(q => q.what), ["power.state"]);
        verify(!t.win.hasBattery);
        verify(ids(t.win).indexOf("battery") < 0);
        t.backend.finished("main.power", true, testCase.battery);
        verify(t.win.hasBattery);
        verify(ids(t.win).indexOf("battery") >= 0);
        t.backend.finished("main.power", true, JSON.stringify({present: false}));
        verify(!t.win.hasBattery);
        t.backend.finished("main.power", true, testCase.battery);
        t.backend.finished("main.power", false, "");
        verify(!t.win.hasBattery, "UPower not answering: no Battery");
        verify(ids(t.win).indexOf("battery") < 0);
    }

    // The pane choice (the owner's report of rc1-22, a desktop PC: no power modes, no way to keep it awake): without a battery
    // the sidebar has Energy in Battery's place (macOS 27), with one Battery; Battery asked for without a battery shows
    // Energy and the other way round; a battery that appears moves the selection without a new history entry.
    function test_energyInPlaceOfBattery() {
        const t = make(testCase.touchpad);
        verify(!t.win.hasBattery);
        verify(ids(t.win).indexOf("energy") >= 0, "no battery: Energy");
        verify(ids(t.win).indexOf("battery") < 0);
        const energy = t.win.available.find(s => s.id === "energy");
        compare(energy.title, "Energy");
        compare(energy.group, t.win.available.find(s => s.id === "wifi").group, "in Battery's group");
        showPage(t.win, "battery");
        compare(t.win.selectedId, "energy");
        compare(t.win.sectionTitle, "Energy");
        tryVerify(() => find(t.win.contentItem, i => i.title === "Energy" && i.setMode !== undefined && i.store !== undefined) !== null);
        verify(find(t.win.contentItem, i => i.setLimit !== undefined) === null, "no Battery page");
        const back = t.win.navState.back.length;
        // A battery appears (UPower answers late): Battery replaces Energy, selected, no history entry.
        t.backend.finished("main.power", true, testCase.battery);
        verify(ids(t.win).indexOf("battery") >= 0);
        verify(ids(t.win).indexOf("energy") < 0);
        compare(t.win.selectedId, "battery");
        compare(t.win.navState.back.length, back);
        tryVerify(() => find(t.win.contentItem, i => i.setLimit !== undefined) !== null, 2000, "the Battery page");
        showPage(t.win, "energy");
        compare(t.win.selectedId, "battery", "Energy asked for with a battery: Battery");
        // Search finds Energy by its words on a computer without a battery.
        t.backend.finished("main.power", true, JSON.stringify({present: false}));
        compare(t.win.selectedId, "energy");
        t.win.query = "sleep";
        verify(t.win.filtered.some(s => s.id === "energy"));
        t.win.query = "";
    }

    // --section=battery at start on a desktop (the shell's Battery Settings… cannot be there, but a stale command can): Energy.
    function test_startOnBatteryWithoutBattery() {
        const t = make(testCase.touchpad, {startSection: "battery"});
        compare(t.win.selectedId, "energy");
    }

    // Mouse while a mouse is there, Trackpad where there is one; asked for the other, the one there is shown.
    function test_pointerPane() {
        const pad = make(testCase.touchpad);
        verify(!pad.win.hasMouse && pad.win.hasTouchpad);
        compare(pad.win.pointerPane("mouse"), "trackpad");
        compare(pad.win.pointerPane("sound"), "sound");
        verify(ids(pad.win).indexOf("mouse") < 0 && ids(pad.win).indexOf("trackpad") >= 0);
        showPage(pad.win, "mouse");
        compare(pad.win.selectedId, "trackpad");
        const started = make(testCase.touchpad, {startSection: "mouse"});
        compare(started.win.selectedId, "trackpad", "--section=mouse on a laptop without a mouse");
        const desk = make(testCase.mouse);
        verify(desk.win.hasMouse && !desk.win.hasTouchpad);
        compare(desk.win.pointerPane("trackpad"), "mouse");
        showPage(desk.win, "trackpad");
        compare(desk.win.selectedId, "mouse");
        // A mouse plugged in later: read again with the system state, the pane stays the one asked for.
        desk.backend.files = {"/proc/bus/input/devices": testCase.touchpad + "\n" + testCase.mouse};
        desk.win.readPointers();
        verify(desk.win.hasMouse && desk.win.hasTouchpad);
        showPage(desk.win, "trackpad");
        compare(desk.win.selectedId, "trackpad");
        // The touchpad gone while its pane shows: the mouse's.
        desk.backend.files = {"/proc/bus/input/devices": testCase.mouse};
        desk.win.readPointers();
        compare(desk.win.selectedId, "mouse");
    }

    // `find` through the views too (a list's delegates sit in its contentItem).
    function findDeep(item, pred) {
        if (!item)
            return null;
        if (pred(item))
            return item;
        const kids = (item.children || []).concat(item.contentItem && item.contentItem !== item ? [item.contentItem] : []);
        for (let i = 0; i < kids.length; i++) {
            const hit = findDeep(kids[i], pred);
            if (hit)
                return hit;
        }
        return null;
    }

    // Software Update (U19): the releases the shell found show as a red count on the sidebar's General row and on the hub's
    // Software Update row; the pane's (i), More Info… and Log Out… open their sheets.
    function test_softwareUpdateBadgeAndSheets() {
        const backend = fakeBackend.createObject(testCase);
        backend.files = {
            "/proc/bus/input/devices": testCase.touchpad,
            "/home/u/.local/state/grassfield/software-update.json": JSON.stringify({version: 1, state: "available", channel: "stable", checkedAt: new Date().toISOString(),
                grassfield: {installed: "1.0.0-1", available: "1.0.1-1", notes: [], notesError: null}, omarchy: {installed: "4.0.4-1", available: "4.0.6-1"}, others: 0, otherPackages: []})
        };
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/Main.qml"));
        const win = createTemporaryObject(comp, testCase, {backend: backend, globalMenu: false});
        tryVerify(() => findDeep(win.contentItem, i => i.modelData !== undefined && i.modelData.id === "general") !== null);
        const general = findDeep(win.contentItem, i => i.modelData !== undefined && i.modelData.id === "general");
        compare(general.Accessible.name, "General, 2 updates", "the sidebar's General row says it");
        verify(findDeep(general, i => i.count === 2 && i.spoken !== undefined && i.visible), "and draws it");
        const appearance = findDeep(win.contentItem, i => i.modelData !== undefined && i.modelData.id === "appearance");
        compare(appearance.Accessible.name, "Appearance", "on General only");
        showPage(win, "general");
        tryVerify(() => findDeep(win.contentItem, i => i.text === "Software Update" && i.badge === 2));
        showPage(win, "software-update");
        compare(win.sectionTitle, "Software Update");
        const pane = find(win.contentItem, i => i.infoRequested !== undefined && i.endSessionRequested !== undefined);
        verify(pane);
        for (const topic of ["automatic", "beta", "notes", "others"]) {
            for (const x of win.sheets)
                x.close();
            pane.infoRequested(topic);
            const shown = shownSheet(win);
            verify(shown !== null, topic);
            compare(shown.topic, topic);
        }
        for (const x of win.sheets)
            x.close();
        pane.endSessionRequested("logout");
        compare(shownSheet(win).confirmText, "Log Out");
        shownSheet(win).close();
        pane.endSessionRequested("restart");
        compare(shownSheet(win).confirmText, "Restart");
        // Accepted in a dev session: nothing ends (SystemService's guard).
        shownSheet(win).confirm();
        verify(shownSheet(win) === null);
        // Update Now's end (U29): the restart or log out its run asks for, with Later; nothing for another outcome.
        pane.updates.runFinished("done", "restart");
        compare([shownSheet(win).cancelText, shownSheet(win).confirmText], ["Restart Later", "Restart"]);
        compare(shownSheet(win).title, "Restart your computer to finish updating");
        shownSheet(win).close();
        pane.updates.runFinished("done", "logout");
        compare([shownSheet(win).cancelText, shownSheet(win).confirmText], ["Log Out Later", "Log Out"]);
        shownSheet(win).close();
        pane.updates.runFinished("terminal", "");
        pane.updates.runFinished("done", "");
        verify(shownSheet(win) === null, "no sheet when nothing is to be finished");
    }

    // A page's request opens its sheet; the sheet's answer reaches the page.
    function test_sheetWiring() {
        const t = make(testCase.touchpad);
        t.backend.finished("main.power", true, testCase.battery);
        // Battery > (i) Charging: the sheet; its charge limit goes to the page (refused in a dev session: the page's note).
        showPage(t.win, "battery");
        const batteryPage = find(t.win.contentItem, i => i.infoRequested !== undefined && i.setLimit !== undefined);
        verify(batteryPage);
        batteryPage.infoRequested("charging", batteryPage.power);
        const info = sheet(t.win, "limitRequested");
        verify(info.shown);
        compare(info.topic, "charging");
        info.limitRequested(true);
        verify(!info.shown, "the answer closes the sheet");
        // Battery > Options…: the sleep option's sheet, with the window's store.
        batteryPage.optionsRequested();
        const options = sheet(t.win, "store", s => s.title === "Options");
        verify(options.shown);
        verify(options.store !== null);
        options.accepted();
        options.close();
        // Printers: a printer's sheet, then Remove Printer…'s confirmation.
        showPage(t.win, "printers");
        const printers = find(t.win.contentItem, i => i.detailsRequested !== undefined && i.addRequested !== undefined);
        verify(printers);
        printers.detailsRequested({name: "GF_Office", title: "GF Office", status: "Idle", message: "", location: "", kind: "USB", isDefault: false,
            needsResume: false});
        const details = sheet(t.win, "resumeRequested");
        verify(details.shown);
        compare(details.printer.name, "GF_Office");
        details.removeRequested(details.printer);
        const remove = sheet(t.win, "remove");
        verify(remove.shown);
        // The options of Menu Bar, Lock Screen, Desktop & Dock and Search, each a sheet over the window.
        const cases = [{id: "menubar", signal: "clockOptionsRequested"}, {id: "menubar", signal: "batteryOptionsRequested"},
            {id: "lock", signal: "messageRequested"}, {id: "desktop", signal: "screenCornersRequested"}, {id: "search", signal: "historyDeleteRequested"}];
        for (const c of cases) {
            for (const s of t.win.sheets)
                s.close();
            showPage(t.win, c.id);
            const p = find(t.win.contentItem, i => i[c.signal] !== undefined);
            verify(p, c.signal);
            p[c.signal]();
            verify(shownSheet(t.win) !== null, c.signal);
        }
        // Screen Saver > Lock Screen Settings…: the sheet closes and Lock Screen shows.
        for (const s of t.win.sheets)
            s.close();
        const saver = sheet(t.win, "lockScreenRequested");
        saver.open();
        saver.lockScreenRequested();
        verify(!saver.shown);
        compare(t.win.selectedId, "lock");
        // A sheet over the window: the pane does not change under it (the global menu's View items, a request from another
        // process), or the sheet's answer would find no page.
        saver.open();
        showPage(t.win, "desktop");
        compare(t.win.selectedId, "lock");
        saver.close();
        showPage(t.win, "desktop");
        compare(t.win.selectedId, "desktop");
    }

    // The window closed (src/main.cpp only hides it; the app may live on with About This Computer): a fingerprint enrolment is
    // stopped, the disk password's fields are emptied, the Wi-Fi code is dropped (security review of ADR-0045, M-1).
    function test_closingEndsWhatTheSheetsHold() {
        const t = make(testCase.touchpad);
        t.backend.devSession = false;
        const enroll = sheet(t.win, "ended");
        enroll.openFor("right-index-finger", 3);
        verify(t.backend.actions.some(op => op.op === "fprint.enroll"), "the enrolment started");
        verify(enroll.running);
        const disk = sheet(t.win, "openSheet");
        disk.openSheet();
        const fields = [];
        const collect = item => {
            if (item.echoMode !== undefined && item.placeholderText !== undefined && item.visible)
                fields.push(item);
            for (let i = 0; i < (item.children || []).length; i++)
                collect(item.children[i]);
        };
        collect(disk);
        compare(fields.length, 3);
        fields[0].text = "old secret";
        fields[1].text = "new secret";
        const share = sheet(t.win, "cells");
        share.code = {size: 29, rows: []};
        share.open();
        const before = t.backend.stops;
        t.win.close();
        verify(!t.win.visible);
        verify(t.backend.stops > before, "fprintd is told to stop");
        verify(!enroll.shown);
        compare(enroll.enrolment, null);
        compare(fields.map(f => f.text), ["", "", ""], "the disk password's fields are empty");
        verify(!disk.shown);
        compare(share.code, null, "the Wi-Fi code is dropped");
        // Shown again: nothing comes back.
        t.win.show();
        disk.openSheet();
        compare(fields.map(f => f.text), ["", "", ""]);
    }

    // A dev session's Wi-Fi pane shows the owner's real network: no Share Network… there (security review of ADR-0045, M-2).
    function test_noWifiCodeInADevSession() {
        const t = make(testCase.touchpad);
        t.backend.commands = ["omarchy-network-qr"];
        const details = sheet(t.win, "shareRequested");
        details.openFor({key: "x", hex: "4E", ssid: "N", label: "N", strength: 50, security: "WPA2", secured: true, enterprise: false, active: true, valid: true}, null);
        verify(!details.canShare, "dev session");
        details.close();
        t.backend.devSession = false;
        details.openFor({key: "x", hex: "4E", ssid: "N", label: "N", strength: 50, security: "WPA2", secured: true, enterprise: false, active: true, valid: true}, null);
        verify(details.canShare, "a real session where Omarchy's command is installed");
        details.close();
    }

    // Every sheet of the window is in `sheets`, and each one gives the keyboard focus back to what had it when it appeared.
    function test_sheetsGiveTheFocusBack() {
        const t = make(testCase.touchpad);
        let count = 0;
        find(t.win.contentItem, i => {
            if (i.focusBack !== undefined && i.confirmText !== undefined)
                count++;
            return false;
        });
        compare(t.win.sheets.length, count, "every sheet is listed");
        verify(count >= 23);
        for (const s of t.win.sheets) {
            t.win.searchField.forceActiveFocus();
            verify(t.win.searchField.activeFocus);
            s.open();
            verify(s.shown);
            verify(!t.win.searchField.activeFocus, s.title);
            s.close();
            verify(t.win.searchField.activeFocus, "back from " + s.title);
        }
        // A sheet opened from another one gives the focus back to that one's control.
        const sources = sheet(t.win, "addRequested");
        sources.open();
        const inSheet = t.win.activeFocusItem;
        verify(inSheet !== t.win.searchField);
        // Its +: the layout picker (not Add Printer…, which has a list of what was found).
        const picker = sheet(t.win, "picked", x => x.found === undefined);
        picker.open();
        picker.close();
        compare(t.win.activeFocusItem, inSheet);
        sources.close();
    }

    // The floating panel moved the list (ADR-0024 amendment 2026-11-03): at the top the first row is fully inside the list's
    // visible area, under the search field with the same gap as before, and inside the panel's left and bottom edges.
    function test_sidebarFirstRowIsFullyVisible() {
        const t = make(testCase.touchpad);
        const win = t.win;
        const list = findDeep(win.contentItem, i => i.Accessible.name === "Sections" && i.contentY !== undefined);
        verify(list, "the sections list");
        tryVerify(() => list.height > 0);
        list.positionViewAtBeginning();
        wait(50);
        const first = list.itemAtIndex(0);
        verify(first, "the first row");
        const top = first.mapToItem(list, 0, 0).y;
        verify(top >= 0, "the first row's top " + top + " is at or below the list's visible top");
        const search = win.searchField;
        const gap = list.mapToItem(win.contentItem, 0, 0).y - (search.mapToItem(win.contentItem, 0, 0).y + search.height);
        compare(gap, Tokens.spacingMd, "the gap under the search field");
        const panelBottom = Tokens.windowSidebarPanelInset;
        compare(list.mapToItem(win.contentItem, 0, list.height).y, win.contentItem.height - panelBottom, "the list ends at the panel's bottom");
    }

    // A window that is not key greys its sidebar tiles to a mid grey that keeps the white glyph at 3:1 (macOS; the icon floor of
    // gate A2), in both appearances; key again, the tiles take their colours back.
    function test_inactiveTilesKeepTheGlyphReadable() {
        function lum(c) {
            const f = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
            return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
        }
        const glyph = Qt.color(Tokens.settingsSidebarTileGlyph);
        for (const grey of [Tokens.settingsSidebarTileInactiveLight, Tokens.settingsSidebarTileInactiveDark])
            verify((lum(glyph) + 0.05) / (lum(Qt.color(grey)) + 0.05) >= 3.0, grey + " under the white glyph is under 3:1");
        const t = make(touchpad);
        showPage(t.win, "desktop");
        // The window sets the appearance from its own source once made: the light one is the one under test here.
        Appearance.dark = false;
        t.win.requestActivate();
        tryVerify(() => t.win.active, 2000);
        wait(50);
        const tiles = () => {
            const out = [];
            const walk = i => {
                if (String(i).indexOf("QQuickRectangle") === 0 && i.visible && i.width === Tokens.settingsSidebarIconSize && i.height === i.width
                        && i.mapToItem(t.win.contentItem, 0, 0).x < Tokens.settingsSidebarWidth)
                    out.push(i);
                for (let k = 0; k < (i.children || []).length; k++)
                    walk(i.children[k]);
            };
            walk(t.win.contentItem);
            return out;
        };
        verify(tiles().length > 3, "the sidebar's tiles");
        verify(!tiles().some(r => Qt.colorEqual(r.color, Tokens.settingsSidebarTileInactiveLight)), "key: coloured");
        verify(tiles().every(r => r.gradient !== null), "key: every tile a vivid gradient");
        const other = createTemporaryObject(otherWindow, null);
        other.requestActivate();
        tryVerify(() => !t.win.active, 2000);
        wait(50);
        verify(tiles().every(r => Qt.colorEqual(r.color, Tokens.settingsSidebarTileInactiveLight)), "not key: every tile the inactive grey: ");
        verify(tiles().every(r => r.gradient === null), "not key: no gradient, the flat grey");
        other.close();
    }

    // The sidebar tiles sit on whole device pixels in window coordinates (the 1-pixel dark rim and the edge stay crisp), also
    // after the list scrolls by a fractional offset. Run with QT_SCALE_FACTOR=1.25 to see it at the owner's ratio.
    function test_sidebarTilesSitOnWholeDevicePixels() {
        const t = make(testCase.touchpad, {height: 360});
        const dpr = t.win.devicePixelRatio;
        const tiles = () => {
            const out = [];
            const walk = i => {
                if (String(i).indexOf("QQuickRectangle") === 0 && i.visible && i.width === Tokens.settingsSidebarIconSize && i.height === i.width
                        && i.mapToItem(t.win.contentItem, 0, 0).x < Tokens.settingsSidebarWidth)
                    out.push(i);
                for (let k = 0; k < (i.children || []).length; k++)
                    walk(i.children[k]);
            };
            walk(t.win.contentItem);
            return out;
        };
        const whole = v => Math.abs(v * dpr - Math.round(v * dpr)) < 1e-6;
        wait(50);
        let rows = tiles();
        verify(rows.length >= 2, "at least two tiles: " + rows.length);
        for (const r of rows) {
            const p = r.mapToItem(null, 0, 0);
            verify(whole(p.x) && whole(p.y), "tile at " + p.x + ", " + p.y + " is not on whole device pixels at " + dpr);
        }
        // A fractional scroll offset: the tiles follow it onto whole device pixels.
        const flick = (function find(i) {
            if (i.contentY !== undefined && i.model !== undefined && i.flick !== undefined)
                return i;
            for (let k = 0; k < (i.children || []).length; k++) {
                const f = find(i.children[k]);
                if (f)
                    return f;
            }
            return null;
        })(t.win.contentItem);
        if (flick) {
            flick.contentY = flick.contentY + 3.37;
            wait(50);
            rows = tiles();
            verify(rows.length >= 2, "tiles after scrolling");
            for (const r of rows) {
                const p = r.mapToItem(null, 0, 0);
                verify(whole(p.x) && whole(p.y), "after a fractional scroll: tile at " + p.x + ", " + p.y + " at " + dpr);
            }
        }
    }

    // The sidebar's list is taller than a short window: the wheel scrolls it and stops at the ends, a click on a row still
    // selects it (no drag), and a selection made by key, search or deep link brings its row into view.
    function test_sidebarScrolls() {
        const t = make(testCase.touchpad, {height: 360});
        const win = t.win;
        const list = findDeep(win.contentItem, i => i.Accessible.name === "Sections" && i.contentY !== undefined);
        verify(list, "the sections list");
        verify(list.contentHeight > list.height, "more sections than fit");
        tryVerify(() => list.height > 0);
        const top = list.contentY;

        mouseWheel(list, list.width / 2, list.height / 2, 0, -120);
        tryVerify(() => list.contentY > top, 1000, "wheel down moves the list");
        for (let n = 0; n < 60 && !list.atYEnd; n++) {
            mouseWheel(list, list.width / 2, list.height / 2, 0, -120);
            wait(20);
        }
        tryCompare(list, "atYEnd", true);
        // More wheel events at the bottom: never past the last row (no overshoot, no rebound).
        const bottomBound = list.originY + list.contentHeight - list.height + list.bottomMargin;
        for (let n = 0; n < 5; n++) {
            mouseWheel(list, list.width / 2, list.height / 2, 0, -120);
            verify(list.contentY <= bottomBound + 0.01, "no overshoot at the bottom: " + list.contentY);
            wait(30);
        }
        wait(400);
        verify(list.contentY <= bottomBound + 0.01 && list.atYEnd, "settled at the bottom: " + list.contentY);
        for (let n = 0; n < 80 && !list.atYBeginning; n++) {
            mouseWheel(list, list.width / 2, list.height / 2, 0, 120);
            wait(20);
        }
        tryCompare(list, "atYBeginning", true);
        for (let n = 0; n < 5; n++) {
            mouseWheel(list, list.width / 2, list.height / 2, 0, 120);
            verify(list.contentY >= list.originY - list.topMargin - 0.01, "no overshoot at the top: " + list.contentY);
            wait(30);
        }
        wait(400);
        verify(list.contentY >= list.originY - list.topMargin - 0.01, "settled at the top: " + list.contentY);

        // A click on a row selects it: the first row in view that is not the selected one.
        const row = findDeep(list.contentItem, i => {
            if (i.modelData === undefined || i.modelData.id === win.selectedId)
                return false;
            const y = i.mapToItem(list, 0, 0).y;
            return y > 0 && y + i.height < list.height;
        });
        verify(row, "a row in view");
        const spot = row.mapToItem(null, row.width / 2, row.height / 2);
        mouseClick(win.contentItem, spot.x, spot.y);
        compare(win.selectedId, row.modelData.id);

        // The last section by End: its row is inside the view.
        list.forceActiveFocus();
        keyClick(Qt.Key_End);
        const last = win.filtered[win.filtered.length - 1].id;
        compare(win.selectedId, last);
        tryVerify(() => {
            const r = findDeep(list.contentItem, i => i.modelData !== undefined && i.modelData.id === last);
            // The focus ring (outside the row) is inside the list too.
            return r && r.mapToItem(list, 0, 0).y + r.height + Tokens.controlFocusOutline <= list.height + 0.5;
        });

        // Search: results start at the top; clearing the search brings the selected section back.
        win.searchField.text = "p";
        tryVerify(() => list.contentY <= list.originY - list.topMargin + 0.5, 1000, "results start at the top");
        verify(win.filtered.length > 5);
        win.searchField.text = "";
        tryVerify(() => {
            const r = findDeep(list.contentItem, i => i.modelData !== undefined && i.modelData.id === last);
            return r && r.mapToItem(list, 0, 0).y + r.height <= list.height + 0.5;
        }, 1000, "the selection is back in view");

        // Selected from elsewhere (search, a deep link, back): the first section comes back into view.
        showPage(win, win.filtered[0].id);
        tryVerify(() => list.contentY <= top + 1);
    }
}
