import QtQuick
import QtTest
import "../../shell/platform/shortcuts/Shortcuts.js" as Shortcuts

// CIO-01: the shell's keys arrive in-process (`custom>>gfkey/1 ...` on socket2, shell/platform/shortcuts). The parser accepts
// exactly the requests config/hypr/grassfield/bindings.lua sends (read here), with checked arguments, and nothing else (no
// test hook, no stray target); gesture steps parse with their progress, and a committed end stands for the discrete request.
TestCase {
    name: "Shortcuts"

    function bindingsText() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/hypr/grassfield/bindings.lua"), false);
        xhr.send();
        return xhr.responseText;
    }

    // Every request of bindings.lua, as the event it sends (bindings.lua shell_event: " ''" left out).
    function bindingRequests() {
        const text = bindingsText();
        const out = [];
        const shell = /shell\("(\w+)",\s*"([^"]*)"/g;
        let m;
        while ((m = shell.exec(text)) !== null)
            out.push(m[1] + " " + m[2].replace(/ ''/g, ""));
        // The switcher's own helpers add the hold id (switcher_request) or call it bare (in_switcher_else).
        const held = /switcher_request\("(\w+)"\)/g;
        while ((m = held.exec(text)) !== null)
            out.push("switcher " + m[1] + " 1700000001");
        out.push("switcher release 1700000001");
        const bare = /in_switcher_else\("(\w+)"/g;
        while ((m = bare.exec(text)) !== null)
            out.push("switcher " + m[1]);
        // The Stages loop: `shell("stages", "activate " .. tostring(n))`, n = 1..4.
        if (/shell\("stages",\s*"activate " \.\. tostring\(n\)\)/.test(text)) {
            for (let n = 1; n <= 4; n++)
                out.push("stages activate " + n);
        }
        return out;
    }

    function test_everyBindingRequestIsAccepted() {
        const requests = bindingRequests();
        verify(requests.length > 40, "bindings.lua read: " + requests.length + " requests");
        for (const r of requests) {
            if (r.endsWith(" "))
                continue; // a literal head the code completes (the Stages loop, the switcher's hold id), expanded above
            const parsed = Shortcuts.parseKey("gfkey/1 " + r);
            verify(parsed !== null, "accepted: " + r);
        }
    }

    function test_theListIsExactlyWhatBindingsSend() {
        const used = {};
        for (const r of bindingRequests()) {
            const w = r.split(" ");
            used[w[0] + "." + w[1]] = true;
        }
        // The gestures' discrete fallback (a committed end with no surface following it): overview/apps open and close.
        for (const kind of Shortcuts.gestureKinds) {
            verify(bindingsText().indexOf('tracked.gesture("' + kind + '"') >= 0, "bindings.lua sends the gesture " + kind);
            const r = Shortcuts.gestureFallback({kind: kind, phase: "end", commit: true});
            used[r.target + "." + r.fn] = true;
        }
        for (const target in Shortcuts.requests) {
            for (const fn in Shortcuts.requests[target])
                verify(used[target + "." + fn] === true, target + "." + fn + " is sent by a binding (no request the keys do not need)");
        }
    }

    function test_argumentsAreChecked() {
        compare(JSON.stringify(Shortcuts.parseKey("gfkey/1 windows tile top-left")), JSON.stringify({target: "windows", fn: "tile", args: ["top-left"]}));
        compare(JSON.stringify(Shortcuts.parseKey("gfkey/1 menubar open status")), JSON.stringify({target: "menubar", fn: "open", args: ["status", ""]}));
        compare(JSON.stringify(Shortcuts.parseKey("gfkey/1 menubar open system DP-1")), JSON.stringify({target: "menubar", fn: "open", args: ["system", "DP-1"]}));
        compare(Shortcuts.parseKey("gfkey/1 stages activate 3").args[0], 3);
        compare(Shortcuts.parseKey("gfkey/1 switcher next 1700000123").args[0], "1700000123");
        compare(Shortcuts.parseKey("gfkey/1 windows tile"), null, "a missing argument");
        compare(Shortcuts.parseKey("gfkey/1 windows minimize now"), null, "an extra argument");
        compare(Shortcuts.parseKey("gfkey/1 stages activate 0"), null);
        compare(Shortcuts.parseKey("gfkey/1 stages activate x"), null);
        compare(Shortcuts.parseKey("gfkey/1 switcher next abc"), null);
        compare(Shortcuts.parseKey("gfkey/1 windows tile $(rm)"), null);
        compare(Shortcuts.parseKey("gfkey/1 menubar open system a/b"), null);
    }

    function test_onlyKeyRequestsReachHandlers() {
        compare(Shortcuts.parseKey("gfkey/1 search status"), null, "a test hook is not a key");
        compare(Shortcuts.parseKey("gfkey/1 notifications dnd true"), null);
        compare(Shortcuts.parseKey("gfkey/1 lock lock"), null, "the lock key stays a qs ipc call to the security process");
        compare(Shortcuts.parseKey("gfkey/1 search constructor"), null);
        compare(Shortcuts.parseKey("gfkey/1 toString toString"), null);
        compare(Shortcuts.parseKey("gfkey/1 __proto__ toggle"), null);
        compare(Shortcuts.parseKey("gfkey/2 search toggle"), null);
        compare(Shortcuts.parseKey("search toggle"), null);
        compare(Shortcuts.parseKey(""), null);
        compare(Shortcuts.parseKey(undefined), null);
        compare(Shortcuts.parseKey("gfkey/1 search toggle" + " x".repeat(200)), null);
    }

    function test_gestureSteps() {
        compare(JSON.stringify(Shortcuts.parseGesture("gfgesture/1 overview-open begin 0")), JSON.stringify({kind: "overview-open", phase: "begin", progress: 0, commit: false}));
        compare(Shortcuts.parseGesture("gfgesture/1 overview-open update 0.42").progress, 0.42);
        verify(Shortcuts.parseGesture("gfgesture/1 apps-open end 0.7 commit").commit);
        verify(!Shortcuts.parseGesture("gfgesture/1 apps-open end 0.2 back").commit);
        compare(Shortcuts.parseGesture("gfgesture/1 apps-open end 0.2"), null, "an end says commit or back");
        compare(Shortcuts.parseGesture("gfgesture/1 apps-open update 0.2 commit"), null);
        compare(Shortcuts.parseGesture("gfgesture/1 apps-open update 1.5"), null);
        compare(Shortcuts.parseGesture("gfgesture/1 apps-open update -0.1"), null);
        compare(Shortcuts.parseGesture("gfgesture/1 search-open update 0.1"), null);
        compare(Shortcuts.parseGesture("gfgesture/1 overview-open hover 0.1"), null);
    }

    function test_committedEndIsTheDiscreteRequest() {
        compare(JSON.stringify(Shortcuts.gestureFallback(Shortcuts.parseGesture("gfgesture/1 overview-open end 0.6 commit"))), JSON.stringify({target: "overview", fn: "open"}));
        compare(JSON.stringify(Shortcuts.gestureFallback(Shortcuts.parseGesture("gfgesture/1 apps-close end 1 commit"))), JSON.stringify({target: "apps", fn: "close"}));
        compare(Shortcuts.gestureFallback(Shortcuts.parseGesture("gfgesture/1 apps-close end 0.1 back")), null);
        compare(Shortcuts.gestureFallback(Shortcuts.parseGesture("gfgesture/1 apps-close update 0.9")), null);
        compare(Shortcuts.gestureFallback(Shortcuts.parseGesture("gfgesture/1 apps-close cancel 0.9")), null);
        // Every gesture kind falls back on a request the keys accept too.
        for (const kind of Shortcuts.gestureKinds) {
            const r = Shortcuts.gestureFallback({kind: kind, phase: "end", commit: true});
            verify(Shortcuts.parseKey("gfkey/1 " + r.target + " " + r.fn) !== null, kind);
        }
    }

    function test_theEnabledHandlerAnswers() {
        const early = {target: "search", enabled: true};
        const surface = {target: "search", enabled: false};
        let list = Shortcuts.attached([], early);
        list = Shortcuts.attached(list, surface);
        compare(Shortcuts.pick(list), early);
        early.enabled = false;
        surface.enabled = true;
        compare(Shortcuts.pick(list), surface, "the surface's handler takes over (shell.qml's early hand-over)");
        list = Shortcuts.attached(list, surface);
        compare(list.length, 2, "attached once");
        compare(Shortcuts.attached([null, early], surface).length, 2, "a destroyed handler is dropped");
        compare(Shortcuts.pick([]), null);
        compare(Shortcuts.pick(undefined), null);
    }

    Component {
        id: handlerComponent
        QtObject {
            property string target: "search"
            property bool enabled: true
        }
    }

    // A handler destroyed while attached (a surface unloaded) is not null in the list but an empty wrapper: it neither answers
    // nor stays attached.
    function test_aDestroyedHandlerIsPassedOver() {
        const gone = handlerComponent.createObject(null);
        const live = {target: "search", enabled: true};
        const list = [gone, live];
        gone.destroy();
        wait(0);
        verify(list[0] !== null, "the wrapper of a destroyed object is not null");
        compare(Shortcuts.pick(list), live);
        compare(Shortcuts.attached(list, {target: "search", enabled: true}).length, 2, "the destroyed handler is dropped");
    }

    // R2 (CIO-01): a surface that follows the gesture (Overview, Apps) opens at its begin and draws the fingers' progress,
    // completes or goes back at the end from where the fingers left it; *-close mirrors *-open; Reduce Motion: the end only.
    function g(text) {
        return Shortcuts.parseGesture("gfgesture/1 " + text);
    }

    function test_followTheFingers() {
        const f = Shortcuts.followStep;
        compare(JSON.stringify(f("apps", false, -1, g("apps-open begin 0"), false)), JSON.stringify({action: "show", progress: 0}));
        compare(JSON.stringify(f("apps", true, 0, g("apps-open update 0.4"), false)), JSON.stringify({action: "", progress: 0.4}));
        compare(JSON.stringify(f("apps", true, 0.6, g("apps-open end 0.6 commit"), false)), JSON.stringify({action: "", progress: -1}), "completes from there");
        compare(JSON.stringify(f("apps", true, 0.3, g("apps-open end 0.3 back"), false)), JSON.stringify({action: "close", progress: 0.3}), "goes back from there");
        compare(JSON.stringify(f("apps", true, 0.3, g("apps-open cancel 0.3"), false)), JSON.stringify({action: "close", progress: 0.3}));
        compare(f("apps", true, -1, g("apps-open begin 0"), false), null, "already open: nothing");
        compare(f("apps", false, -1, g("apps-open update 0.5"), false), null, "no begin seen (refused): nothing drawn");
        compare(JSON.stringify(f("apps", false, -1, g("apps-open end 0.8 commit"), false)), JSON.stringify({action: "show", progress: -1}), "a refused begin: the end asks again");
        // Closing mirrors it.
        compare(f("overview", false, -1, g("overview-close begin 0"), false), null, "nothing to close");
        compare(JSON.stringify(f("overview", true, -1, g("overview-close begin 0"), false)), JSON.stringify({action: "", progress: 1}));
        compare(JSON.stringify(f("overview", true, 1, g("overview-close update 0.25"), false)), JSON.stringify({action: "", progress: 0.75}));
        compare(JSON.stringify(f("overview", true, 0.4, g("overview-close end 0.6 commit"), false)), JSON.stringify({action: "close", progress: 0.4}));
        compare(JSON.stringify(f("overview", true, 0.9, g("overview-close end 0.1 back"), false)), JSON.stringify({action: "", progress: -1}), "back to open");
        // Another surface's gesture is not this one's.
        compare(f("overview", false, -1, g("apps-open begin 0"), false), null);
        // Reduce Motion: nothing follows the fingers; the completed end opens or closes, a gone-back end does nothing.
        compare(f("apps", false, -1, g("apps-open begin 0"), true), null);
        compare(f("apps", false, -1, g("apps-open update 0.5"), true), null);
        compare(JSON.stringify(f("apps", false, -1, g("apps-open end 0.7 commit"), true)), JSON.stringify({action: "show", progress: -1}));
        compare(f("apps", false, -1, g("apps-open end 0.2 back"), true), null);
        compare(JSON.stringify(f("apps", true, -1, g("apps-close end 0.7 commit"), true)), JSON.stringify({action: "close", progress: -1}));
        compare(f("apps", false, -1, null, false), null);
    }

    function shellText(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../shell/" + path), false);
        xhr.send();
        return xhr.responseText;
    }

    // Every target a binding calls is answered in-process: the IpcHandler(s) of that target attach to the router
    // (`Component.onCompleted: Shortcuts.attach(this)` right in the handler, and the module imported), or the key would go
    // through a `qs ipc` process (the router's logged fallback). A new target must name its host file here.
    function test_everyKeyTargetIsAttached() {
        const hosts = {
            switcher: ["switcher/Switcher.qml"],
            windows: ["platform/Compositor.qml"],
            search: ["shell.qml", "search/Search.qml"],
            emoji: ["services/Emoji.qml"],
            apps: ["shell.qml", "launchpad/AppsController.qml"],
            overview: ["shell.qml", "overview/Overview.qml"],
            notifications: ["notifications/Notifications.qml"],
            capture: ["capture/Capture.qml"],
            menubar: ["menubar/MenuBar.qml"],
            dock: ["dock/Dock.qml"],
            zoom: ["platform/Zoom.qml"],
            stages: ["platform/StagesLink.qml"],
            volume: ["osd/Osd.qml"],
            brightness: ["osd/Osd.qml"],
            keyboard: ["osd/Osd.qml"]
        };
        for (const target in Shortcuts.requests) {
            verify(hosts[target] !== undefined, target + ": its host file is listed");
            for (const file of hosts[target]) {
                const text = shellText(file);
                verify(text.length > 0, file + " read");
                verify(/^import qs\.platform\.shortcuts\s*$/m.test(text), file + " imports qs.platform.shortcuts");
                // The handler's body up to its first function: target and attach are both in it.
                const re = new RegExp("IpcHandler \\{[^{}]*?target: \"" + target + "\"[^{}]*?Component\\.onCompleted: Shortcuts\\.attach\\(this\\)");
                const loose = new RegExp("IpcHandler \\{[^{}]*?Component\\.onCompleted: Shortcuts\\.attach\\(this\\)[^{}]*?target: \"" + target + "\"");
                verify(re.test(text) || loose.test(text), file + ": the IpcHandler of \"" + target + "\" attaches to the router");
            }
        }
    }

    function test_theLockKeyStaysAProcess() {
        const text = bindingsText();
        verify(/bind\("SUPER \+ CTRL \+ Q", "Lock screen", security\("lock", "lock"\)\)/.test(text), "the lock key uses security()");
        verify(/local function security\(target, fn\)[\s\S]*?hl\.dsp\.exec_cmd\(/.test(text), "security() runs qs ipc (and its stand-in), with the UI process dead too");
    }
}
