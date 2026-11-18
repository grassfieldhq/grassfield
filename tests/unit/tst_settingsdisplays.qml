import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Displays.js" as Displays
import "../../apps/settings/qml/System.js" as System
import "../../apps/settings/qml" as SettingsQml

// Settings > Displays (ADR-0031): the state the shell publishes, the resolution choices (Larger Text … More Space) and refresh
// rates of a monitor, the lines of displays.conf and of a trial (the same rule as config/hypr/grassfield/displays.lua), the
// merge of a change into the kept lines, and the arrangement's snap. Then the page on a fake backend: a choice writes a trial
// with the kept lines of the other displays and asks for the keep sheet; Keep is taken only while the shell says the trial is
// applied (an earlier Keep is refused, not held; the sheet stays open), and displays.conf is written only once the shell kept
// it (a Keep after the shell's deadline writes nothing); Revert marks it; the shell taking it back, or not answering, ends it; Arrange tries the moved displays; a display
// without a usable name is never written; brightness is the shell's command and nothing in a dev session.
TestCase {
    id: testCase
    name: "SettingsDisplays"
    width: 700
    height: 900
    visible: true
    when: windowShown

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: false
            property string displaysStateFile: "/run/user/1000/grassfield-displays.json"
            property string stateText: ""
            property var conf: []
            property var calls: []
            property var actions: []
            property string trialError: ""
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            signal fileChanged(string path)
            function readText(path: string): var {
                return {exists: stateText !== "", ok: path === displaysStateFile && stateText !== "", text: stateText};
            }
            function watch(path: string): bool {
                return true;
            }
            function displaysConf(): var {
                return conf;
            }
            function writeDisplaysConf(lines: var): string {
                calls.push({call: "conf", lines: lines});
                return "";
            }
            function writeDisplayTrial(id: string, until: real, lines: var): string {
                calls.push({call: "trial", id: id, until: until, lines: lines});
                return trialError;
            }
            function markDisplayTrial(state: string, id: string): string {
                calls.push({call: "mark", state: state, id: id});
                return "";
            }
            function act(what: string, argv: var, tag: string): bool {
                actions.push(argv);
                return true;
            }
            property var queries: []
            function query(argv: var, tag: string, timeoutMs: var): void {
                queries.push({argv: argv, tag: tag, timeoutMs: timeoutMs});
            }
        }
    }

    // The settings store of the page: `displays.main` as a ConfigStore keeps it, writes recorded.
    Component {
        id: fakeStore
        QtObject {
            property var values: ({})
            property var sets: []
            function value(key: string): var {
                void values;
                return values[key] !== undefined ? values[key] : [];
            }
            function set(key: string, v: var): bool {
                sets.push({key: key, value: v});
                const next = Object.assign({}, values);
                next[key] = v;
                values = next;
                return true;
            }
        }
    }

    function makePage(dev, monitors) {
        const backend = createTemporaryObject(fakeBackend, testCase, {devSession: dev});
        backend.stateText = JSON.stringify({v: 1, monitors: monitors, backlight: {device: "intel_backlight", level: 0.5}, trial: null});
        const sc = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/SystemService.qml"));
        const service = createTemporaryObject(sc, testCase, {backend: backend});
        const pc = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/DisplaysPage.qml"));
        compare(pc.status, Component.Ready, pc.errorString());
        const store = createTemporaryObject(fakeStore, testCase);
        const page = createTemporaryObject(pc, testCase, {backend: backend, system: service, store: store, width: 700, height: 900});
        verify(page);
        return {backend: backend, page: page, service: service, store: store};
    }

    function publish(t, trial) {
        const j = JSON.parse(t.backend.stateText);
        j.trial = trial;
        t.backend.stateText = JSON.stringify(j);
        t.page.refresh();
    }

    readonly property var panelIpc: ({name: "eDP-1", description: "BOE 0x0BCA", width: 2880, height: 1800, physicalWidth: 300, physicalHeight: 190,
        refreshRate: 120, x: 0, y: 0, scale: 2, transform: 0, availableModes: ["2880x1800@120.00Hz", "2880x1800@60.00Hz"]})
    readonly property var externalIpc: ({name: "DP-1", description: "GF Display 27 0001", model: "Display 27", width: 2560, height: 1440,
        physicalWidth: 597, physicalHeight: 336, refreshRate: 60, x: 1440, y: 0, scale: 1, transform: 0, availableModes: ["2560x1440@60.00Hz"]})

    SignalSpy {
        id: keepSpy
        signalName: "keepRequested"
    }

    SignalSpy {
        id: endSpy
        signalName: "trialEnded"
    }

    function test_page_aChoiceIsATrialThenKept() {
        const t = makePage(false, [panelIpc, externalIpc]);
        keepSpy.target = t.page;
        keepSpy.clear();
        endSpy.target = t.page;
        endSpy.clear();
        // The kept line of the other display stays in the trial.
        const other = "v1\tdesc:GF Display 27 0001\t2560x1440@60.00\t1440x0\t1\t0";
        t.backend.conf = [other];
        compare(t.page.monitors.length, 2);
        compare(t.page.choices.length, 5);
        t.page.tryChange({scale: 2.5});
        const trial = t.backend.calls[0];
        compare(trial.call, "trial");
        verify(/^[a-z0-9]{8}$/.test(trial.id));
        const now = Math.floor(Date.now() / 1000);
        verify(trial.until >= now + 14 && trial.until <= now + 15, String(trial.until));
        // The panel gets narrower (1152 wide): the display on its right follows its edge in the same trial, in place of its kept line.
        compare(trial.lines, ["v1\tdesc:BOE 0x0BCA\t2880x1800@120.00\t0x0\t2.5\t0", "v1\tdesc:GF Display 27 0001\t2560x1440@60.00\t1152x0\t1\t0"]);
        compare(keepSpy.count, 1);
        compare(keepSpy.signalArguments[0][0], trial.until);
        // One trial at a time.
        verify(!t.page.settable);
        t.page.tryChange({scale: 1.6});
        compare(t.backend.calls.length, 1);
        // Keep before the shell applied the trial (Return twice) is refused and not held: the applied state that follows sends
        // nothing on its own.
        verify(!t.page.trialApplied);
        verify(!t.page.keep());
        publish(t, {id: trial.id, state: "applied"});
        compare(t.backend.calls.length, 1);
        // The mode is on screen: Keep marks the trial kept, once; displays.conf is not written yet.
        verify(t.page.trialApplied);
        verify(t.page.keep());
        verify(!t.page.keep());
        compare(t.backend.calls.slice(1), [{call: "mark", state: "kept", id: trial.id}]);
        compare(endSpy.count, 0);
        // The shell kept it: now displays.conf, for the next login.
        publish(t, {id: trial.id, state: "kept"});
        compare(t.backend.calls.slice(1), [{call: "mark", state: "kept", id: trial.id}, {call: "conf", lines: trial.lines}]);
        compare(endSpy.count, 1);
        verify(t.page.settable);
    }

    function test_page_aLateKeepWritesNothing() {
        const t = makePage(false, [panelIpc]);
        endSpy.target = t.page;
        endSpy.clear();
        // The shell's deadline came before the Keep reached it: it took the trial back; nothing reaches displays.conf.
        t.page.tryChange({scale: 2.5});
        const id = t.backend.calls[0].id;
        publish(t, {id: id, state: "applied"});
        t.page.keep();
        publish(t, {id: id, state: "reverted"});
        compare(t.backend.calls.filter(c => c.call === "conf"), []);
        compare(endSpy.count, 1);
        verify(t.page.notice.indexOf("taken back") >= 0, t.page.notice);
        // Keep after the shell already took it back: nothing at all.
        t.page.tryChange({scale: 1.6});
        const id2 = t.backend.calls[t.backend.calls.length - 1].id;
        publish(t, {id: id2, state: "applied"});
        publish(t, {id: id2, state: "reverted"});
        const before = t.backend.calls.length;
        t.page.keep();
        compare(t.backend.calls.length, before);
        // A shell that never applies the trial: Keep is never taken (the applied timer takes the trial back).
        t.page.tryChange({scale: 1.6});
        verify(!t.page.keep());
        tryCompare(t.page, "trialId", "", 6000);
        compare(t.backend.calls.filter(c => c.call === "mark" && c.state === "kept").length, 1);
        // A shell that applied the trial but never answers the Keep: nothing written, said so.
        t.page.tryChange({scale: 2.5});
        const id3 = t.backend.calls[t.backend.calls.length - 1].id;
        publish(t, {id: id3, state: "applied"});
        t.page.keep();
        tryCompare(t.page, "trialId", "", 6000);
        compare(t.backend.calls.filter(c => c.call === "conf"), []);
        verify(t.page.notice.indexOf("did not answer") >= 0, t.page.notice);
    }

    function test_page_revertAndTheShellsAnswers() {
        const t = makePage(false, [panelIpc]);
        endSpy.target = t.page;
        endSpy.clear();
        t.page.tryChange({hz: 60});
        const id = t.backend.calls[0].id;
        compare(t.backend.calls[0].lines, ["v1\tdesc:BOE 0x0BCA\t2880x1800@60.00\t0x0\t2\t0"]);
        t.page.revert();
        compare(t.backend.calls[1], {call: "mark", state: "revert", id: id});
        compare(endSpy.count, 1);
        // The shell takes a trial back (its deadline): the sheet goes, nothing is written.
        t.page.tryChange({transform: 1});
        const id2 = t.backend.calls[2].id;
        publish(t, {id: id2, state: "applied"});
        publish(t, {id: id2, state: "reverted"});
        compare(endSpy.count, 2);
        compare(t.backend.calls.length, 3);
        // A trial the shell never answers is taken back and said so.
        t.page.tryChange({scale: 1.6});
        const id3 = t.backend.calls[3].id;
        tryCompare(t.page, "trialId", "", 6000);
        compare(t.backend.calls[4], {call: "mark", state: "revert", id: id3});
        verify(t.page.notice.indexOf("did not answer") >= 0, t.page.notice);
        // A trial the backend refuses: no sheet, the reason shown.
        t.backend.trialError = "no folder for a display trial in this session";
        t.page.tryChange({scale: 1.6});
        compare(t.page.trialId, "");
        verify(t.page.notice.indexOf("no folder") >= 0);
    }

    Component {
        id: keepSheet
        Item {
            width: 700
            height: 600
            property alias sheet: sheet
            property int kept: 0
            SettingsQml.DisplayKeepSheet {
                id: sheet
                onKeep: parent.kept++
            }
        }
    }

    function test_keepSheetWaitsForTheModeOnScreen() {
        const host = createTemporaryObject(keepSheet, testCase);
        host.sheet.openFor(Math.floor(Date.now() / 1000) + 15);
        // Not applied yet: Keep (Return) leaves the sheet open and says why; no keep is sent.
        host.sheet.confirm();
        verify(host.sheet.visible);
        compare(host.kept, 0);
        verify(host.sheet.errorText !== "");
        // Applied: Keep is sent once and the sheet closes.
        host.sheet.canKeep = true;
        host.sheet.confirm();
        verify(!host.sheet.visible);
        compare(host.kept, 1);
    }

    function test_page_arrangeAndUnnamedDisplays() {
        const t = makePage(false, [panelIpc, externalIpc]);
        t.page.arrange([{name: "DP-1", x: -2560, y: 0}]);
        compare(t.backend.calls[0].lines, ["v1\tdesc:GF Display 27 0001\t2560x1440@60.00\t-2560x0\t1\t0"]);
        t.page.revert();
        // A display without a description: shown, never written.
        const u = makePage(false, [Object.assign({}, panelIpc, {description: ""})]);
        verify(!u.page.nameable);
        verify(!u.page.settable);
        u.page.tryChange({scale: 2.5});
        compare(u.backend.calls.length, 0);
    }

    function test_page_brightness() {
        compare(System.setBrightness("intel_backlight", 0.456), ["brightnessctl", "-q", "-d", "intel_backlight", "set", "46%"]);
        compare(System.setBrightness("-d", 0.5), null);
        compare(System.setBrightness("a/b", 0.5), null);
        compare(System.setBrightness("intel_backlight", NaN), null);
        const dev = makePage(true, [panelIpc]);
        verify(dev.service.dev);
        compare(dev.service.act("brightness", System.setBrightness("intel_backlight", 0.3), "display.brightness"), false);
        compare(dev.backend.actions.length, 0);
    }

    // ADR-0044: with two displays the page knows the main one (the built-in panel by default), and making the other main writes
    // displays.main through the store, keyed by identity (make, model and serial from Hyprland's monitors in the state file), never by the connector.
    function test_page_mainDisplay() {
        const monitors = [{name: "eDP-1", make: "LG", model: "LGD", serial: "123", description: "LGD x", width: 1920, height: 1080, refreshRate: 60, x: 0, y: 0, scale: 1, transform: 0, availableModes: []},
                          {name: "DP-2", make: "Dell", model: "DELL", serial: "ABC", description: "DELL x", width: 1920, height: 1080, refreshRate: 60, x: 1920, y: 0, scale: 1, transform: 0, availableModes: []}];
        const u = makePage(false, monitors);
        compare(u.page.mainName, "eDP-1");
        u.page.selected = "DP-2";
        compare(u.page.isMain, false);
        u.page.makeMain("DP-2");
        compare(u.store.sets.length, 1);
        compare(u.store.sets[0].key, "displays.main");
        compare(u.store.sets[0].value, [{set: ["s:Dell|DELL|ABC", "s:LG|LGD|123"], main: "s:Dell|DELL|ABC"}]);
        compare(u.page.mainName, "DP-2");
        compare(u.page.isMain, true);
        // The same panel on another port is still the main display.
        compare(DisplayRole.resolve(u.store.values["displays.main"], [{name: "HDMI-A-1", make: "Dell", model: "DELL", serial: "ABC"}, {name: "eDP-1", make: "LG", model: "LGD", serial: "123"}]).name, "HDMI-A-1");
    }

    // The owner's rc6 report: "there is no way to set the main display with several displays". The display shown first is the
    // main one, and its "Use as" pop-up offered only "Main display". macOS 27: every display's pop-up offers Main display and
    // Extended display; Extended display on the main one hands the role on (the built-in panel, else the next display). The
    // row is the first of the display's settings, and the band names the main display.
    function test_page_useAsOnEveryDisplay() {
        const monitors = [{name: "DP-1", make: "Dell", model: "U2723", serial: "A1", description: "Dell U2723 A1", width: 2560, height: 1440, refreshRate: 60, x: 0, y: 0, scale: 1, transform: 0, availableModes: []},
                          {name: "DP-2", make: "Dell", model: "U2723", serial: "B2", description: "Dell U2723 B2", width: 2560, height: 1440, refreshRate: 60, x: 2560, y: 0, scale: 1, transform: 0, availableModes: []},
                          {name: "HDMI-A-1", make: "LG", model: "TV", serial: "", description: "LG TV", width: 1920, height: 1080, refreshRate: 60, x: 5120, y: 0, scale: 1, transform: 0, availableModes: []}];
        const u = makePage(false, monitors);
        // No built-in panel, no choice: the first display is main, and it is the one shown.
        compare(u.page.mainName, "DP-1");
        compare(u.page.monitor.name, "DP-1");
        compare(u.page.useAsChoices.map(c => c.id), ["main", "extended"]);
        compare(u.page.useAsValue, "main");
        // Extended display on the main one: the next display takes the role.
        u.page.useAs("extended");
        compare(u.store.sets.length, 1);
        compare(u.page.mainName, "DP-2");
        compare(u.page.useAsValue, "extended");
        // Main display on another one.
        u.page.selected = "HDMI-A-1";
        compare(u.page.useAsValue, "extended");
        u.page.useAs("main");
        compare(u.page.mainName, "HDMI-A-1");
        compare(u.page.useAsValue, "main");
        // Choosing what already holds changes nothing.
        u.page.useAs("main");
        u.page.selected = "DP-1";
        u.page.useAs("extended");
        compare(u.store.sets.length, 2);
        // The row comes first, before the resolution choices.
        const useAs = find(u.page, x => x.accessibleName === qsTr("Use as") && x.model !== undefined);
        verify(useAs !== null);
        const choices = find(u.page, x => x.choices !== undefined && x.pending !== undefined);
        verify(choices !== null);
        waitForRendering(u.page);
        const above = useAs.mapToItem(u.page, 0, 0).y, below = choices.mapToItem(u.page, 0, 0).y;
        verify(above < below, "Use as is above the resolution: " + above + " / " + below);
        // One display: no "Use as".
        const one = makePage(false, [monitors[0]]);
        compare(one.page.useAsChoices.length, 0);
    }

    // macOS 27 Arrange: drag the menu bar to another display to make it the main display. The sheet hands the choice back on
    // Done, with the moved displays; Cancel drops it.
    function test_arrangeMovesTheMenuBar() {
        const monitors = [{name: "DP-1", model: "A", width: 1920, height: 1080, x: 0, y: 0, scale: 1, transform: 0},
                          {name: "DP-2", model: "B", width: 1920, height: 1080, x: 1920, y: 0, scale: 1, transform: 0}];
        const c = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/ArrangeSheet.qml"));
        compare(c.status, Component.Ready, c.errorString());
        const sheet = createTemporaryObject(c, testCase, {width: 600, height: 500});
        const spy = createTemporaryObject(spyComponent, testCase, {target: sheet, signalName: "mainChosen"});
        const moved = createTemporaryObject(spyComponent, testCase, {target: sheet, signalName: "arranged"});
        sheet.mainName = "DP-1";
        sheet.openFor(monitors);
        compare(sheet.barOn, "DP-1");
        // The bar dropped where no display is stays where it was.
        sheet.dropMenuBar(-5000, -5000);
        compare(sheet.barOn, "DP-1");
        // Dropped on the other display's tile (layout pixels): it moves there.
        sheet.dropMenuBar(1920 + 400, 300);
        compare(sheet.barOn, "DP-2");
        sheet.accepted();
        compare(spy.count, 1);
        compare(spy.signalArguments[0][0], "DP-2");
        compare(moved.count, 0);
        // Opened again: the bar starts on the main display; Done without a move says nothing.
        sheet.mainName = "DP-2";
        sheet.openFor(monitors);
        compare(sheet.barOn, "DP-2");
        sheet.accepted();
        compare(spy.count, 1);
    }

    Component {
        id: spyComponent
        SignalSpy {}
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

    // A drag keeps its own value (as Sound's volume does): a reading taken meanwhile does not move the knob back; the next does.
    function test_page_brightnessHoldsWhileDragging() {
        const t = makePage(false, [panelIpc]);
        compare(t.page.backlight.level, 0.5);
        const row = find(t.page, i => i.title === "Brightness" && i.busy !== undefined);
        verify(row);
        const slider = find(row, i => i.moved !== undefined && i.local !== undefined);
        verify(slider);
        slider.local = 0.8;
        slider.moved(0.8);
        compare(t.backend.actions, [["brightnessctl", "-q", "-d", "intel_backlight", "set", "80%"]]);
        verify(row.busy);
        // The shell's state still says the old level while the drag goes on.
        const j = JSON.parse(t.backend.stateText);
        j.backlight.level = 0.45;
        t.backend.stateText = JSON.stringify(j);
        t.page.refresh();
        compare(t.page.backlight.level, 0.5, "the drag's reading is kept");
        compare(slider.shown, 0.8, "the knob stays under the pointer");
        // Once the drag is applied, the next reading follows.
        tryVerify(() => !row.busy);
        j.backlight.level = 0.8;
        t.backend.stateText = JSON.stringify(j);
        t.page.refresh();
        compare(t.page.backlight.level, 0.8);
        compare(slider.shown, 0.8);
    }

    // ADR-0045 OC-4: an external display's brightness over DDC/CI, Omarchy's command; the connector alone reads it.
    function test_ddcCommands() {
        compare(System.ddcBrightnessQuery("DP-1"), ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1"]);
        compare(System.ddcBrightnessQuery("HDMI-A-1"), ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "HDMI-A-1"]);
        compare(System.setDdcBrightness("DP-1", 0.456), ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "46%"]);
        compare(System.setDdcBrightness("DP-1", 1.4), ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "100%"]);
        compare(System.setDdcBrightness("DP-1", -1), ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "0%"]);
        // Security review LOW 3: the bound (12 s, then KILL 2 s later: 14 s at most) ends every run before the Backend gives up on
        // it (an action's 15 s, the read's DDC_WAIT_MS), so its ddcutil never outlives it and the next write never meets it.
        compare(System.DDC_BOUND, ["timeout", "-k", "2", "12"]);
        verify((12 + 2) * 1000 < System.DDC_WAIT_MS);
        verify((12 + 2) * 1000 < 15000, "Backend.act's default wait");
        for (const bad of ["", "-x", "DP-", "DP1", "DP-1 ", "../DP-1", "DP-1;rm", "eDP-1", "LVDS-1", undefined])
            compare(System.ddcBrightnessQuery(bad), null, JSON.stringify(bad));
        compare(System.setDdcBrightness("-d", 0.5), null);
        compare(System.setDdcBrightness("DP-1", NaN), null);
        compare(System.parseDdcLevel("40\n"), 0.4);
        compare(System.parseDdcLevel("100"), 1);
        compare(System.parseDdcLevel("0"), 0);
        for (const bad of ["", "101", "40%", "-1", "4.5", "abc", "40\n41"])
            compare(System.parseDdcLevel(bad), -1, JSON.stringify(bad));
    }

    // The external display's row is the built-in one's (LevelRow): shown once the display answered, nothing before or without an
    // answer (macOS shows no slider for a display it cannot control); a drag sends one command at a time, the last value once the
    // running one answered; then the level is read again. The built-in panel is never asked over DDC/CI.
    function test_page_ddcBrightness() {
        const t = makePage(false, [panelIpc, externalIpc]);
        compare(t.page.monitorName, "eDP-1");
        compare(t.backend.queries.length, 0, "the built-in panel is not asked");
        verify(t.page.hasBrightness, "the backlight's row");
        t.page.selected = "DP-1";
        compare(t.backend.queries.length, 1);
        compare(t.backend.queries[0].argv, ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1"]);
        compare(t.backend.queries[0].tag, "display.ddc@DP-1");
        compare(t.backend.queries[0].timeoutMs, System.DDC_WAIT_MS, "the read is waited for past its bound");
        verify(!t.page.hasBrightness, "no row before the display answered");
        // The page's own refresh never asks again (each read is i2c traffic).
        t.page.refresh();
        t.page.refresh();
        compare(t.backend.queries.length, 1);
        // An answer for another display, or a display that does not answer: still no row.
        t.backend.finished("display.ddc@HDMI-A-1", true, "70\n");
        verify(!t.page.hasBrightness);
        t.backend.finished("display.ddc@DP-1", false, "");
        verify(!t.page.hasBrightness);
        t.backend.finished("display.ddc@DP-1", true, "40\n");
        verify(t.page.hasBrightness);
        compare(t.page.ddc, {output: "DP-1", level: 0.4});
        const row = find(t.page, i => i.title === "Brightness" && i.busy !== undefined);
        verify(row);
        verify(row.oneAtATime);
        compare(row.value, 0.4);
        const slider = find(row, i => i.moved !== undefined && i.local !== undefined);
        verify(slider);
        slider.local = 0.6;
        slider.moved(0.6);
        compare(t.backend.actions, [["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "60%"]]);
        verify(row.running);
        // More of the drag while it runs: nothing more is started, whatever the throttle says.
        slider.local = 0.7;
        slider.moved(0.7);
        slider.local = 0.85;
        slider.moved(0.85);
        wait(Tokens.settingsVolumeApplyMs * 2);
        compare(t.backend.actions.length, 1, "one command at a time");
        // A reading taken meanwhile does not move the knob.
        t.backend.finished("display.ddc@DP-1", true, "40\n");
        compare(t.page.ddc.level, 0.4);
        compare(slider.shown, 0.85);
        // The running one answers: only the last value goes.
        t.backend.finished("display.brightness", true, "60\n");
        compare(t.backend.actions.length, 2);
        compare(t.backend.actions[1], ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1", "85%"]);
        t.backend.finished("display.brightness", true, "85\n");
        tryVerify(() => !row.busy);
        // The drag ended: the display's level is read again.
        compare(t.backend.queries.length, 2);
        compare(t.backend.queries[1].argv, ["timeout", "-k", "2", "12", "omarchy-brightness-display-ddc", "DP-1"]);
        t.backend.finished("display.ddc@DP-1", true, "85\n");
        compare(t.page.ddc.level, 0.85);
        // Back to the built-in panel: its backlight, no DDC/CI row.
        t.page.selected = "eDP-1";
        compare(t.page.ddc, null);
        verify(!row.oneAtATime);
        compare(row.value, 0.5);
        compare(t.backend.queries.length, 2);
    }

    // A dev session takes no DDC/CI write either (SystemService's guard; the Backend's guard refuses the read there).
    function test_page_ddcBrightnessDev() {
        const t = makePage(true, [externalIpc]);
        compare(t.backend.queries.length, 1);
        t.backend.finished("display.ddc@DP-1", true, "40\n");
        verify(t.page.hasBrightness);
        compare(t.service.act("brightness", System.setDdcBrightness("DP-1", 0.3), "display.brightness"), false);
        compare(t.backend.actions.length, 0);
        const row = find(t.page, i => i.title === "Brightness" && i.busy !== undefined);
        const slider = find(row, i => i.moved !== undefined && i.local !== undefined);
        slider.local = 0.9;
        slider.moved(0.9);
        compare(t.backend.actions.length, 0);
        verify(!row.running);
        verify(t.service.suppressedNote);
    }

    // The choice in use keeps its accent ring; the keyboard's focus is a ring of its own outside it.
    function test_resolutionChoiceFocusRing() {
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/ResolutionChoices.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const choices = createTemporaryObject(comp, testCase, {width: 468, current: 1,
            choices: [{scale: 2.5, width: 1152, height: 720, isDefault: false}, {scale: 2, width: 1440, height: 900, isDefault: true},
                {scale: 1.6, width: 1800, height: 1125, isDefault: false}]});
        const cells = choices.children.filter(c => c.inUse !== undefined);
        compare(cells.length, 3);
        const rings = cell => cell.children.filter(r => r.border !== undefined && r.color.a === 0 && r.border.width > 1);
        const inUse = cells[1];
        compare(rings(inUse).length, 2);
        const focus = rings(inUse).find(r => r.border.width === Tokens.controlFocusOutline);
        const accent = rings(inUse).find(r => r.border.width === Tokens.settingsDisplayChoiceRing);
        verify(focus && accent);
        verify(accent.visible && !focus.visible);
        verify(Qt.colorEqual(accent.border.color, Appearance.colors.accent));
        inUse.forceActiveFocus(Qt.TabFocusReason);
        verify(accent.visible && focus.visible, "both: in use and focused");
        verify(Qt.colorEqual(focus.border.color, Appearance.focusRingColor));
        // Outside the accent ring, set off from it.
        compare(accent.x - focus.x, Tokens.iconModePreviewFocusGap + Tokens.controlFocusOutline);
        compare(focus.width - accent.width, 2 * (Tokens.iconModePreviewFocusGap + Tokens.controlFocusOutline));
        // Another choice with the focus: its focus ring only.
        cells[2].forceActiveFocus(Qt.TabFocusReason);
        verify(!focus.visible && accent.visible);
        const other = rings(cells[2]);
        verify(other.find(r => r.border.width === Tokens.controlFocusOutline).visible);
        verify(!other.find(r => r.border.width === Tokens.settingsDisplayChoiceRing).visible);
    }

    readonly property var panel: ({name: "eDP-1", description: "BOE 0x0BCA", make: "BOE", model: "0x0BCA", width: 2880, height: 1800,
        physicalWidth: 300, physicalHeight: 190, refreshRate: 120, x: 0, y: 0, scale: 2, transform: 0,
        modes: [{w: 2880, h: 1800, hz: 120}, {w: 2880, h: 1800, hz: 60}, {w: 2880, h: 1800, hz: 59.94}, {w: 1920, h: 1200, hz: 60}, {w: 2880, h: 1800, hz: 120.001}]})
    readonly property var monitor24: ({name: "DP-1", description: "Dell Inc. DELL P2419H 4GHXRV2", width: 1920, height: 1080, physicalWidth: 530,
        physicalHeight: 300, refreshRate: 60, x: 1440, y: 0, scale: 1, transform: 0, modes: []})
    // The owner's development laptop as Hyprland describes it (hyprctl monitors -j, 2026-11-07).
    readonly property var ownerPanel: ({name: "eDP-1", description: "AU Optronics 0x2E8D", make: "AU Optronics", model: "0x2E8D", width: 1920,
        height: 1080, physicalWidth: 340, physicalHeight: 190, refreshRate: 60.056, x: 0, y: 0, scale: 1.25, transform: 0,
        modes: [{w: 1920, h: 1080, hz: 60.06}, {w: 1920, h: 1080, hz: 48.05}]})

    function test_parseState() {
        const text = JSON.stringify({v: 1, monitors: [
            {name: "eDP-1", description: "BOE 0x0BCA", width: 2880, height: 1800, physicalWidth: 300, physicalHeight: 190, refreshRate: 120, x: 0, y: 0, scale: 2,
             transform: 0, disabled: false, availableModes: ["2880x1800@120.00Hz", "2880x1800@60.00Hz", "junk"]},
            {name: "HDMI-A-1", disabled: true}, {description: "no name"}],
            backlight: {device: "intel_backlight", level: 0.4}, trial: {id: "a1b2", state: "applied"}});
        const s = Displays.parseState(text);
        compare(s.monitors.length, 1);
        compare(s.monitors[0].modes, [{w: 2880, h: 1800, hz: 120}, {w: 2880, h: 1800, hz: 60}]);
        compare(s.backlight, {device: "intel_backlight", level: 0.4});
        compare(s.trial, {id: "a1b2", state: "applied"});
        compare(Displays.parseState("{}"), null);
        compare(Displays.parseState("not json"), null);
        compare(Displays.parseState('{"v":2,"monitors":[]}'), null);
        compare(Displays.parseState('{"v":1,"monitors":[]}').backlight, null);
    }

    function test_defaultScaleAndChoices() {
        // 14" 2880 x 1800: 243 ppi, Hyprland's default 2; macOS's span: 1152 x 720 … 1800 x 1125.
        compare(Displays.defaultScale(panel), 2);
        const c = Displays.scaleChoices(panel);
        compare(c.map(x => x.width + "x" + x.height), ["1152x720", "1200x750", "1440x900", "1728x1080", "1800x1125"]);
        compare(c.filter(x => x.isDefault).map(x => x.scale), [2]);
        compare(Displays.currentChoice(c, 2), 2);
        // A monitor set elsewhere to a scale outside the span is still shown as it is.
        const odd = Object.assign({}, panel, {scale: 1});
        verify(Displays.scaleChoices(odd).some(x => x.scale === 1));
        verify(Displays.scaleChoices(odd).length <= Displays.MAX_CHOICES);
        // 24" 1080p: about 92 ppi, default 1; the only other choice is Larger Text at 1.25 (1536 x 864).
        compare(Displays.defaultScale(monitor24), 1);
        compare(Displays.scaleChoices(monitor24).map(x => x.scale), [1.25, 1]);
        // Without a physical size: 1.
        compare(Displays.defaultScale(Object.assign({}, panel, {physicalWidth: 0})), 1);
    }

    // The owner's report (rc6, development laptop): a 15.6" 1920 x 1080 panel (144 ppi, Hyprland's default 1.5) kept at 1.25 by
    // displays.conf, and 100 % could not be chosen: the span stopped at the default / 1.25 = 1.2. A display below
    // Displays.NATIVE_MAX_PPI (150) always offers its native resolution as More Space, as macOS does for a display that is not
    // Retina; a denser one keeps macOS's span (review of e0a6e922: the 4K 27" lost its 3072 x 1728 step to native 3840 x 2160).
    function test_nativeResolutionOffered() {
        compare(Displays.defaultScale(ownerPanel), 1.5);
        verify(Math.abs(Displays.ppi(ownerPanel) - 143.7) < 0.5, String(Displays.ppi(ownerPanel)));
        const c = Displays.scaleChoices(ownerPanel);
        verify(c.length <= Displays.MAX_CHOICES, JSON.stringify(c));
        const last = c[c.length - 1];
        compare(last.scale, 1);
        compare(last.width + "x" + last.height, "1920x1080");
        // The scale in use and the default stay offered.
        verify(c.some(x => x.scale === 1.25));
        compare(c.filter(x => x.isDefault).map(x => x.scale), [1.5]);
        compare(Displays.currentChoice(c, 1.25), c.findIndex(x => x.scale === 1.25));
        // The native choice is a trial line with scale 1, as displays.lua reads it.
        compare(Displays.lineFor(ownerPanel, {scale: last.scale}), "v1\tdesc:AU Optronics 0x2E8D\t1920x1080@60.06\t0x0\t1\t0");
        // At 100 % the panel still offers the same span (1.25 is kept as a choice in between).
        const at1 = Displays.scaleChoices(Object.assign({}, ownerPanel, {scale: 1}));
        compare(at1[at1.length - 1].scale, 1);
        compare(Displays.currentChoice(at1, 1), at1.length - 1);
        // A high-density panel (default 2) keeps macOS's span: no native resolution.
        verify(!Displays.scaleChoices(panel).some(x => x.scale === 1));
        // A 4K 27" (163 ppi) and a 4K 24" (185 ppi): Hyprland's default 1.5 too, but above 150 ppi: macOS's span, unchanged from
        // rc6, More Space 3072 x 1728, no native 3840 x 2160.
        const k27 = {name: "DP-1", description: "Dell U2723QE", width: 3840, height: 2160, physicalWidth: 597, physicalHeight: 336, refreshRate: 60,
            x: 0, y: 0, scale: 1.5, transform: 0, modes: []};
        const k24 = Object.assign({}, k27, {name: "DP-2", physicalWidth: 527, physicalHeight: 296});
        for (const m of [k27, k24]) {
            compare(Displays.defaultScale(m), 1.5);
            verify(Displays.ppi(m) > Displays.NATIVE_MAX_PPI, m.name + " " + Displays.ppi(m));
            compare(Displays.scaleChoices(m).map(x => x.width + "x" + x.height), ["2304x1296", "2400x1350", "2560x1440", "2880x1620", "3072x1728"], m.name);
        }
        verify(Math.abs(Displays.ppi(k27) - 163.2) < 0.5, String(Displays.ppi(k27)));
        verify(Math.abs(Displays.ppi(k24) - 185.1) < 0.5, String(Displays.ppi(k24)));
        // Without a physical size the density is unknown: no native step is added (Hyprland's default is then 1, already native).
        compare(Displays.ppi(Object.assign({}, k27, {physicalWidth: 0})), 0);
    }

    function test_refreshRates() {
        // The modes of the current resolution only, one per rate to the hundredth (120 and 120.001 are one), highest first.
        compare(Displays.refreshRates(panel), [120, 60, 59.94]);
        // The number in the language's format (the UI's locale by default), in one translatable sentence.
        const en = Qt.locale("en_US");
        compare(Displays.hzLabel(120, en), "120 Hz");
        compare(Displays.hzLabel(59.94, en), "59.94 Hz");
        compare(Displays.hzLabel(60.001, en), "60 Hz");
        compare(Displays.hzLabel(59.94, Qt.locale("fr_FR")), "59,94 Hz");
        compare(Displays.hzLabel(59.94), Displays.hzLabel(59.94, Qt.locale()));
    }

    function test_lines() {
        compare(Displays.lineFor(panel, {}), "v1\tdesc:BOE 0x0BCA\t2880x1800@120.00\t0x0\t2\t0");
        compare(Displays.lineFor(panel, {scale: 1.666667, hz: 60, transform: 1, x: -1440, y: 12.4}), "v1\tdesc:BOE 0x0BCA\t2880x1800@60.00\t-1440x12\t1.666667\t1");
        // A display that cannot be named this way is never written.
        compare(Displays.lineFor(Object.assign({}, panel, {description: ""}), {}), "");
        compare(Displays.lineFor(Object.assign({}, panel, {description: "A\tB"}), {}), "");
        compare(Displays.lineFor(Object.assign({}, panel, {description: "x".repeat(161)}), {}), "");
        compare(Displays.lineFor(Object.assign({}, panel, {description: "é".repeat(81)}), {}), "");
        compare(Displays.descOfLine("v1\tdesc:BOE 0x0BCA\t2880x1800@60.00\t0x0\t2\t0"), "BOE 0x0BCA");
        compare(Displays.descOfLine("garbage"), "");
    }

    function test_mergeLines() {
        const kept = ["v1\tdesc:A\t1920x1080@60.00\t0x0\t1\t0", "v1\tdesc:B\t1920x1080@60.00\t1920x0\t1\t0"];
        const fresh = ["v1\tdesc:B\t1920x1080@60.00\t0x1080\t1\t0", "v1\tdesc:C\t1920x1080@60.00\t-1920x0\t1\t0"];
        compare(Displays.mergeLines(kept, fresh), [kept[0], fresh[0], fresh[1]]);
        compare(Displays.mergeLines([], fresh), fresh);
    }

    function test_trialId() {
        let n = 0;
        const id = Displays.trialId(() => (n++ % 10) / 10);
        verify(/^[a-z0-9]{8}$/.test(id), id);
        verify(/^[a-z0-9]{8}$/.test(Displays.trialId(Math.random)));
    }

    // A layout never overlaps and never leaves a display apart (audit SP-03, SP-08).
    function test_settleAndResized() {
        const d = (name, x, y, more) => Object.assign({name: name, width: 1920, height: 1080, x: x, y: y, scale: 1, transform: 0}, more || {});
        const a = d("A", 0, 0), b = d("B", 1920, 0), c = d("C", 3840, 0);
        // A layout that works is left alone, whichever display is named.
        compare(Displays.settle([a, b, c], "B"), {A: {x: 0, y: 0}, B: {x: 1920, y: 0}, C: {x: 3840, y: 0}});
        // C dropped on B's place stays there; B moves to the nearest free place beside the others.
        compare(Displays.settle([a, b, d("C", 1920, 0)], "C"), {C: {x: 1920, y: 0}, A: {x: 0, y: 0}, B: {x: 1920, y: -1080}});
        // B moved above A: C, left apart, comes back beside A.
        compare(Displays.settle([a, d("B", 0, -1080), c], "B"), {B: {x: 0, y: -1080}, A: {x: 0, y: 0}, C: {x: 1920, y: 0}});
        // A corner is not a shared edge.
        compare(Displays.settle([a, d("B", 1920, 1080)], "A"), {A: {x: 0, y: 0}, B: {x: 1920, y: 1079}});
        // A 4K display at scale 2 with a display on its right: a new scale or a rotation moves that display with the edge.
        const big = d("L", 0, 0, {width: 3840, height: 2160, scale: 2}), right = d("R", 1920, 0);
        compare(Displays.resized([big, right], "L", {scale: 1.5}), {L: {x: 0, y: 0}, R: {x: 2560, y: 0}});
        compare(Displays.resized([big, right], "L", {scale: 3}), {L: {x: 0, y: 0}, R: {x: 1280, y: 0}});
        compare(Displays.resized([big, right], "L", {scale: 1.25}), {L: {x: 0, y: 0}, R: {x: 3072, y: 0}});
        compare(Displays.resized([big, right], "L", {scale: 1}), {L: {x: 0, y: 0}, R: {x: 3840, y: 0}});
        compare(Displays.resized([big, right], "L", {transform: 1}), {L: {x: 0, y: 0}, R: {x: 1080, y: 0}});
        // A display on its left or above it does not move; one below follows the bottom edge.
        compare(Displays.resized([d("L", 1920, 0, {width: 3840, height: 2160, scale: 2}), d("R", 0, 0)], "L", {scale: 3}), {L: {x: 1920, y: 0}, R: {x: 0, y: 0}});
        compare(Displays.resized([big, d("R", 0, 1080)], "L", {scale: 1.5}), {L: {x: 0, y: 0}, R: {x: 0, y: 1440}});
        // The two-decimal scale Hyprland reports stands for the listed one.
        compare(Displays.logicalSize({width: 2880, height: 1800, scale: 1.67, transform: 0}), {w: 1728, h: 1080});
    }

    function test_snapBeside() {
        // The panel (1440 x 900 logical) at 0,0; the 24" (1920 x 1080) dropped to its right, a little low: it touches the right edge.
        compare(Displays.snapBeside(monitor24, 1500, 300, panel), {x: 1440, y: 300});
        // Dropped far right and low: still to the right (farther that way than down), as low as the two edges still share a pixel.
        compare(Displays.snapBeside(monitor24, 3000, 1400, panel), {x: 1440, y: 899});
        // Dropped below: under the panel, where it was dropped across.
        compare(Displays.snapBeside(monitor24, 500, 1000, panel), {x: 500, y: 900});
        // Dropped to the left.
        compare(Displays.snapBeside(monitor24, -2500, -50, panel), {x: -1920, y: -50});
        // Dropped above, overlapping: it goes above.
        compare(Displays.snapBeside(monitor24, 100, -900, panel), {x: 100, y: -1080});
        // A rotated monitor is placed by its turned size.
        const turned = Object.assign({}, monitor24, {transform: 1});
        compare(Displays.logicalSize(turned), {w: 1080, h: 1920});
        compare(Displays.snapBeside(turned, -900, 0, panel), {x: -1080, y: 0});
    }
}
