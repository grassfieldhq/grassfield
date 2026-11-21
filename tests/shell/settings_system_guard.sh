#!/usr/bin/env bash
# Dev guard of the Settings system sections, on the real Backend (apps/settings/src): with GRASSFIELD_DEV=1 only the
# read-only queries run, no action does; without it actions run (and unknown programs are refused).
# The tools are shims first on PATH that only record their arguments, and the system bus is an address that does not exist
# (DBUS_SYSTEM_BUS_ADDRESS, checked below): the Wi-Fi and Bluetooth actions are D-Bus calls that find no bus here, so nothing
# in this test can touch the machine's network, Bluetooth or audio. The D-Bus services are tested on a private bus with fakes
# (tests/integration/settings_dbus.sh).
# Plain shell test: prints PASS/FAIL, exits non-zero on failure. Offscreen, no compositor needed.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
fail=0
check() { # name, condition result (0 = ok)
  if [[ $2 -eq 0 ]]; then echo "PASS: settings_system_guard $1"; else echo "FAIL: settings_system_guard $1"; fail=1; fi
}

apps/settings/build-direct.sh >/dev/null
tmp=$(mktemp -d "$root/.dev/settings-guard.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/settings-guard.XXXXXX"; })
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/qml"
# The bus every run below uses: a socket that is not there. Never the real system bus (a real Wi-Fi radio is not a test fixture).
dead_bus="unix:path=$tmp/no-such-system-bus"
[[ $dead_bus == unix:path=$tmp/* && ! -e $tmp/no-such-system-bus ]] || { echo "FAIL: the test bus is not a dead address"; exit 2; }
for tool in nmcli bluetoothctl wpctl touch pacman lspci; do
  # Records the arguments and the locale the tool was started with; FAILCASE anywhere, or the device id 999999 (a wpctl form
  # the guard allows), prints a reason on stderr and exits 1.
  cat >"$tmp/bin/$tool" <<EOF
#!/bin/sh
echo "$tool \$*" >> "$tmp/marker"
echo "LC_ALL=\$LC_ALL LANG=\$LANG LANGUAGE=\${LANGUAGE-unset}" >> "$tmp/locale"
case "\$*" in *FAILCASE*|*" 999999 "*) echo "Error: simulated failure" >&2; exit 1;; esac
exit 0
EOF
  chmod +x "$tmp/bin/$tool"
done

sed "s|@SYSTEM_JS@|$root/apps/settings/qml/System.js|" >"$tmp/qml/Main.qml" <<'EOF'
import QtQml
import "file://@SYSTEM_JS@" as System

QtObject {
    id: root
    required property var backend
    required property bool globalMenu
    property string startSection: ""

    property int expected: 0
    property int seen: 0
    property int okCount: 0
    property int refusedCount: 0
    property var reasons: []
    // The real-session D-Bus actions go out one at a time, each when the previous one finished: BusJobs lets 4 jobs run at once
    // and answers any other "timed out" at once (busjobs.h), and a join (wifi.connectKnown, wifi.connectOpen) is followed until it
    // is up and runs one at a time per tag (Backend::busAct latches it: a second one while the first runs is refused, systembus.h
    // followsActivation, audit fix 7c9abeb). Neither is what this test is about.
    property var pendingOps: []
    property var busReturns: [] // what busAct returned for the real-session ops, kept in order, listed before the other returns

    readonly property string uuid: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
    // Wi-Fi and Bluetooth actions are D-Bus maps (busAct), Sound's are wpctl argument vectors (act).
    readonly property var busOps: [
        System.wifiRadio(false), System.wifiConnectKnown(root.uuid), System.wifiConnectOpen("Cafe"), System.wifiDisconnect("wlo1"),
        System.wifiScan(), System.btPower(false), System.btConnect("AA:BB:CC:DD:EE:FF", true), System.btConnect("AA:BB:CC:DD:EE:FF", false)
    ]
    readonly property var commands: [System.setDefaultDevice(52), System.setVolume(52, 0.5), System.setMute(52, true)]

    readonly property Connections conn: Connections {
        target: root.backend
        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "b.act" && root.pendingOps.length > 0)
                root.busReturns.push(root.backend.busAct("test", root.pendingOps.shift(), "b.act"));
            root.seen++;
            if (ok)
                root.okCount++;
            else
                root.refusedCount++;
            if (root.seen >= root.expected)
                root.finish();
        }
    }

    readonly property Connections failures: Connections {
        target: root.backend
        function onFailed(tag: string, reason: string): void {
            root.reasons.push(tag + "=" + reason);
        }
    }

    readonly property Timer failsafe: Timer {
        interval: 8000
        running: true
        onTriggered: {
            console.log("RESULT timeout seen=" + root.seen + " expected=" + root.expected);
            Qt.exit(3);
        }
    }

    function finish(): void {
        console.log("RESULT dev=" + root.backend.devSession + " ok=" + root.okCount + " refused=" + root.refusedCount + " actReturns=" + root.busReturns.concat(root.actReturns).join(",") + " runs=" + root.runs.join("|") + " reasons=" + root.reasons.join("|"));
        Qt.quit();
    }

    property var actReturns: []
    property var runs: []

    // Commands that are not in the allow-list: run() must refuse them in every session (no output, nothing started).
    readonly property var stray: [["touch", "x"], ["nmcli", "radio", "wifi", "off"], ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"], ["pacman", "-S", "hyprland"],
        ["pacman", "-Q", "bash"], ["lspci", "-vv"], ["nmcli", "-t", "-f", "802-11-wireless.ssid", "connection", "show", "uuid", "not-a-uuid"],
        ["bluetoothctl", "show"], ["bluetoothctl", "power", "off"]]

    Component.onCompleted: {
        // The command-line queries of the Sound page, and the 4 commands of the About pane.
        const queries = Object.keys(System.QUERY).map(k => System.QUERY[k]);
        const about = [["pacman", "-Q", "hyprland"], ["pacman", "-Q", "quickshell"], ["pacman", "-Q", "quickshell-git"], ["lspci"]];
        // run() takes the same allow-list in both sessions.
        for (const c of about)
            root.runs.push(root.backend.run(c) === "" ? "empty" : "out");
        for (const c of root.stray)
            root.runs.push(root.backend.run(c) === "" ? "empty" : "out");
        if (root.backend.devSession) {
            // Queries must run; wpctl actions sent as queries must not; no action of either kind may start.
            root.expected = queries.length + root.commands.length;
            for (const q of queries)
                root.backend.query(q, "q");
            for (const a of root.commands) {
                root.backend.query(a, "a");
            }
            for (const o of root.busOps)
                root.actReturns.push(root.backend.busAct("test", o, "b"));
            for (const a of root.commands)
                root.actReturns.push(root.backend.act("test", a, "a"));
            // A malformed D-Bus action is refused in a real session too, here in the dev one first.
            root.actReturns.push(root.backend.busAct("test", {op: "Properties.Set"}, "b"));
        } else {
            // Real session: every wpctl action runs; a D-Bus action is attempted and, with no bus, fails with a reason; a program
            // outside wpctl and xdg-open (nmcli and bluetoothctl are not programs of the pages any more) is refused.
            root.expected = root.busOps.length + root.commands.length + 1;
            root.pendingOps = root.busOps.slice(1);
            root.busReturns.push(root.backend.busAct("test", root.busOps[0], "b.act"));
            for (const a of root.commands)
                root.actReturns.push(root.backend.act("test", a, "a"));
            // A failing tool reports its reason (stderr) before finished(false).
            root.backend.act("test", ["wpctl", "set-mute", "999999", "1"], "failing");
            root.actReturns.push(root.backend.act("test", ["touch", "x"], "a"));
            root.actReturns.push(root.backend.act("test", ["nmcli", "radio", "wifi", "off"], "a"));
            root.actReturns.push(root.backend.act("test", ["bluetoothctl", "power", "off"], "a"));
            // A malformed D-Bus action never starts anything.
            root.actReturns.push(root.backend.busAct("test", {op: "Properties.Set"}, "b"));
        }
        // Always start from a French user locale: the tools must still see C.
        root.actReturns = root.actReturns.slice();
    }
}
EOF

run() { # GRASSFIELD_DEV value, then an optional GRASSFIELD_SESSION value (1 with 1 = a dev value that leaked into a real session)
  : >"$tmp/marker"
  : >"$tmp/locale"
  QT_FORCE_STDERR_LOGGING=1 PATH="$tmp/bin:$PATH" GRASSFIELD_SETTINGS_QML="$tmp/qml" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui" \
    timeout 30 scripts/dev/isolated.sh --name settings-guard env DBUS_SYSTEM_BUS_ADDRESS="$dead_bus" GRASSFIELD_LANG=en GRASSFIELD_DEV="$1" GRASSFIELD_SESSION="${2:-}" LC_ALL=fr_FR.UTF-8 LANG=fr_FR.UTF-8 LANGUAGE=fr "$root/.dev/build/grassfield-settings" 2>&1
}

out=$(run 1) || true
res=$(grep -E 'RESULT' <<<"$out" || true)
echo "$res"
queries=$(wc -l <"$tmp/marker")
has() { grep -q -- "$1" <<<"$2" && echo 0 || echo 1; }
# The two command-line queries of the Sound page (wpctl status, wpctl status -n), 3 wpctl actions sent as queries (refused);
# About's 4 commands go through run(). Wi-Fi and Bluetooth are D-Bus: in a dev session their actions start nothing.
check "dev: the 2 Sound queries run, the 3 wpctl actions sent as queries are refused" "$(has 'dev=true ok=2 refused=3' "$res")"
check "dev: only the 2 Sound queries and the 4 About commands reached a tool ($queries)" "$([[ $queries -eq 6 ]] && echo 0 || echo 1)"
check "dev: run() answered the 4 About commands and refused the 9 stray ones" "$(has 'runs=empty|empty|empty|empty|empty|empty|empty|empty|empty|empty|empty|empty|empty' "$res")"
check "dev: no stray command reached a tool" "$(grep -qE 'get-volume|touch|pacman -S|pacman -Q bash|lspci -vv|not-a-uuid|radio wifi off|bluetoothctl' "$tmp/marker" && echo 1 || echo 0)"
check "tools always see the C locale, whatever the user locale" "$([[ $(sort -u "$tmp/locale") == 'LC_ALL=C LANG=C LANGUAGE=unset' ]] && echo 0 || echo 1)"
check "dev: no action verb reached a tool" "$(grep -qE "radio wifi|connection up|wifi connect|device disconnect|power |bluetoothctl|set-|wifi rescan|nmcli" "$tmp/marker" && echo 1 || echo 0)"
check "dev: busAct and act return false for every action, also for a malformed one" "$(has 'actReturns=false,false,false,false,false,false,false,false,false,false,false,false' "$res")"
check "dev: one log line per suppressed action" "$(has 'dev guard: test suppressed' "$out")"
[[ $fail -eq 0 ]] || echo "$out" | tail -20

out=$(run 0) || true
res=$(grep -E 'RESULT' <<<"$out" || true)
echo "$res"
check "real: the 3 wpctl actions run, the failing one and the 8 D-Bus actions (no bus here) report" "$(has 'dev=false ok=3 refused=9' "$res")"
check "real: failure reason is the tool's stderr line" "$(has 'failing=Error: simulated failure' "$res")"
# The app runs with GRASSFIELD_LANG=en (see run()): the reasons are the English source strings whatever catalog is installed on the
# machine (outside a dev session the app loads /usr/share/grassfield/translations). The tools still see C: forceCLocale.
check "real: a D-Bus action with no bus fails with a reason, not silently" "$(grep -o 'b.act=no connection to the system bus' <<<"$res" | wc -l | grep -qx 8 && echo 0 || echo 1)"
check "real: run() takes the same allow-list" "$(has 'runs=empty|empty|empty|empty|empty|empty|empty|empty|empty|empty|empty|empty|empty' "$res")"
check "real: no stray run() command reached a tool" "$(grep -qE 'get-volume|^touch|pacman -S|pacman -Q bash|lspci -vv|not-a-uuid|bluetoothctl' "$tmp/marker" && echo 1 || echo 0)"
check "real: tools always see the C locale" "$([[ $(sort -u "$tmp/locale") == 'LC_ALL=C LANG=C LANGUAGE=unset' ]] && echo 0 || echo 1)"
check "real: the D-Bus actions start (true), wpctl runs, nmcli, bluetoothctl, touch and a malformed action are refused" "$(has 'actReturns=true,true,true,true,true,true,true,true,true,true,true,false,false,false,false' "$res")"
check "real: neither nmcli, bluetoothctl nor touch ever ran" "$(grep -qE '^(touch|nmcli|bluetoothctl)' "$tmp/marker" && echo 1 || echo 0)"
[[ $fail -eq 0 ]] || echo "$out" | tail -20

# A GRASSFIELD_DEV=1 that leaked into a packaged session (GRASSFIELD_SESSION=1) is a real session (ADR-0019): the same
# answers as the real run above, never the dev guard.
out=$(run 1 1) || true
res=$(grep -E 'RESULT' <<<"$out" || true)
echo "$res"
check "leaked dev in a real session: it is not a dev session, the actions run" "$(has 'dev=false ok=3 refused=9' "$res")"
check "leaked dev in a real session: the actions were attempted (no dev guard line)" "$(grep -q 'dev guard' <<<"$out" && echo 1 || echo 0)"
check "leaked dev in a real session: unknown programs are still refused" "$(has 'actReturns=true,true,true,true,true,true,true,true,true,true,true,false,false,false,false' "$res")"
check "leaked dev in a real session: touch never ran" "$(grep -q '^touch' "$tmp/marker" && echo 1 || echo 0)"
[[ $fail -eq 0 ]] || echo "$out" | tail -20
exit $fail
