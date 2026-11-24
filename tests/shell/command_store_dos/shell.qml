pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.search
import "search/CommandsFile.js" as CommandsFile

// The IPC rate limit of CommandStore under a same-user loop (command palette E1b review; scripts/dev/test.sh:
// `qs -p tests/shell/command_store_dos`, offscreen, a dev session; prints "command-store-dos: PASS" or the failures).
// The file is filled to just under its 256 KiB cap with large replacements (as a hostile or careless client would), then one
// `updateItem` per event-loop turn is sent for 8 s, each making the store serialize, read back and write the whole file.
// The limit charges every request by the main-thread time it took: the work the store did must stay under 15 % of the time
// (the limit aims at 10 %), the 100 ms heartbeat of the event loop must keep at least 75 % of its beats, requests are answered
// `busy` meanwhile, and the store never stops writing or reports an error. The measured figures are printed.
ShellRoot {
    id: root

    property var failures: []
    property int beats: 0
    property int accepted: 0
    property int busy: 0
    property int other: 0
    property bool attack: false
    property real attackStart: 0
    property real workStart: 0
    property int phase: 0

    readonly property var store: search.commandStore

    Search {
        id: search
    }

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function obj(i: int): var {
        return {id: "text.d" + i, replace: "d" + i, with: "é".repeat(16000)};
    }

    function item(i: int): string {
        return JSON.stringify({list: "replacements", item: obj(i)});
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: root.beats++
    }

    // The attacker: one IPC call per event-loop turn.
    Timer {
        interval: 1
        repeat: true
        running: root.attack
        onTriggered: {
            const r = JSON.parse(search.ipc.updateItem(root.item(root.accepted % 8)));
            if (r.ok)
                root.accepted++;
            else if (r.reason === "busy")
                root.busy++;
            else
                root.other++;
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            root.phase++;
            const s = root.store;
            if (root.phase === 1) {
                root.check("the store is ready", s.status === "ok");
                let n = 0;
                for (let i = 0; i < 8; i++)
                    if (s.change("replacements", root.obj(i), "add").ok)
                        n++;
                root.check("8 large replacements fit under the cap (" + n + ", " + CommandsFile.serialize(s.data).bytes + " bytes)", n === 8 && CommandsFile.serialize(s.data).bytes < 262144);
                root.check("a ninth does not", s.change("replacements", root.obj(8), "add").reason === "too-big");
            } else if (root.phase === 3) {
                root.beats = 0;
                root.workStart = s.workMs;
                root.attackStart = Date.now();
                root.attack = true;
            } else if (root.phase === 11) {
                root.attack = false;
                const secs = (Date.now() - root.attackStart) / 1000;
                const duty = (s.workMs - root.workStart) / (secs * 1000);
                const expected = Math.round(secs * 10);
                console.log("command-store-dos: " + secs.toFixed(1) + " s: accepted " + root.accepted + ", busy " + root.busy + ", other " + root.other + "; store work " + Math.round(s.workMs - root.workStart) + " ms = duty " + (duty * 100).toFixed(1) + " %; heartbeats " + root.beats + " of ~" + expected);
                root.check("requests were accepted and others refused (" + root.accepted + " accepted, " + root.busy + " busy)", root.accepted >= 1 && root.busy > 0 && root.other === 0);
                root.check("the store's duty cycle stays under 15 % (" + (duty * 100).toFixed(1) + " %)", duty < 0.15);
                root.check("the event loop keeps 75 % of its beats (" + root.beats + " of " + expected + ")", root.beats >= expected * 0.75);
                root.check("no write is stuck, no error (" + s.writeError + ")", s.writeError === "");
            } else if (root.phase === 13) {
                root.check("the store settles", !s.writing);
                if (root.failures.length === 0) {
                    console.log("command-store-dos: PASS");
                    Qt.exit(0);
                } else {
                    console.log("command-store-dos: FAIL: " + root.failures.join("; "));
                    Qt.exit(1);
                }
            }
        }
    }
}
