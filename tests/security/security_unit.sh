#!/usr/bin/env bash
# ADR-0041 step 1, S1 (the owner's SQ-1 B): the security process runs beside the UI; since S2 it hosts the lock, idle and
# the sleep inhibitor (shell/security/host/SecurityHost.qml), since S3 the polkit agent and the secret sheets with their
# one queue, and the UI holds none of them. Static (data layer): the root
# shell/security.qml (a root of its own next to shell.qml, imports only QtQuick, Quickshell, Quickshell.Io and
# qs.security.host, never reloads on a file change, one SecurityHost, one IpcHandler `security` with `state` and `heartbeat`;
# the reviewed file
# is pinned by its SHA-256, comments included, so any change needs the opus security review and then the new hash here
# (the integrator's decision on #75: a static check cannot model all of QML); tests/security/root_check.py stays as the
# readable second check, an allow-list of identifiers, imports and types read as the engine reads them, with a selftest of
# planted mutants),
# grassfield-security.service (loads that root by path from the system tree, the same cleared environment as the UI's
# unit, Restart=always with a start limit a loop reaches, session-only, no NoNewPrivileges for the helpers of S2/S3, memory
# guards from the measurement and the UI unit's CPU quota, OnFailure=omarchy-sleep-lock.service since S2 while the UI's
# unit lost it), the autostart (started just before the shell, --no-block), the PKGBUILD, grassfield-security-status
# (read-only, calls the targets by the unit's path), the IPC surface table, and the S2/S3 scan
# (tests/security/security_process_scan.py: no lock, idle, polkit agent or secret sheet in the UI tree, one Idle, one
# AuthAgent, one SecretAgent and one queue in the host, one PolkitAgent in the tree, no UI service in the security process,
# the sheets reading the lock in process). S3: grassfield-prompter accepts this unit's processes only, and the polkit
# module keeps nothing across a restart. S4 (safe mode): the host's one SafeMode, its controller pinned, the notice lazy and
# small, the fixed commands it runs, its dev-only IPC target, its actions refused unless the notice is on screen. qmllint
# parses the root when it is installed. Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
fail=0
check() { if "$@"; then echo "PASS: security unit $desc"; else echo "FAIL: security unit $desc"; fail=1; fi; }
qml=shell/security.qml
unit=packaging/systemd/grassfield-security.service
ui=packaging/systemd/grassfield-shell.service
helper=packaging/bin/grassfield-security-status

desc="root: a root of its own next to shell.qml"
check bash -c '[[ -f "$1" && -f shell/shell.qml ]]' _ "$qml"
# The reviewed root, pinned. A change to shell/security.qml, comments included, fails here until the opus security review
# of that change has passed and the hash below is updated in the same pull request (the integrator's decision on #75).
pinned=452918e2a1db7b4b9d5ae1c8db8715df2e7e6e63fef5980f9526ec98947f482c
desc="root: the reviewed file is pinned by its SHA-256 (any change: security review required, then update the pinned hash)"
check bash -c '[[ "$(sha256sum "$1" | cut -d" " -f1)" == "$2" ]] || { echo "shell/security.qml changed: security review required, then update the pinned hash" >&2; exit 1; }' _ "$qml" "$pinned"
# What the root instantiates (S2: the security process's whole content, its one Idle and the lock singleton's first use;
# S3: the sheets' session and the run-time creation of SheetHost.qml; S4: the one SafeMode and its two inputs), pinned the
# same way (the opus review of 77a0ceb3, NIT: the root's pin alone left the host free to change).
host_pinned=67adfa653bb473f6cb029e75deb3755a8e3abe10f7b1bd62ab72bc501ce682e4
desc="host: the reviewed shell/security/host/SecurityHost.qml is pinned by its SHA-256 too (any change: security review required, then update the pinned hash)"
check bash -c '[[ "$(sha256sum shell/security/host/SecurityHost.qml | cut -d" " -f1)" == "$1" ]] || { echo "shell/security/host/SecurityHost.qml changed: security review required, then update the pinned hash" >&2; exit 1; }' _ "$host_pinned"
# The tool that makes the shipped UI tree (ADR-0056, Proposed): it rewrites the imports of every file the UI process loads, the
# polkit agent and the secret sheets included, and verifies the package equals the source apart from them. A change of it can
# change what ships, so it is pinned the same way (the opus review of #37, MAJOR-1).
migrate_pinned=d5b0b9f9d2792da70e090c275a037474b3d08f10e6501f4e9cd96cbe9715d0ad
desc="migrate: scripts/dev/migrate-qs-imports.py is pinned by its SHA-256 (any change: security review required, then update the pinned hash)"
check bash -c '[[ "$(sha256sum scripts/dev/migrate-qs-imports.py | cut -d" " -f1)" == "$1" ]] || { echo "scripts/dev/migrate-qs-imports.py changed: security review required, then update the pinned hash" >&2; exit 1; }' _ "$migrate_pinned"
# What runs the verification is pinned with the tool (the delta review of #37, LOW-4): the CI step (check-migrate.sh) and the two
# lines of the PKGBUILD that migrate and verify the package. A weakened or removed one would let a changed tree ship.
check_migrate_pinned=2ff879212f6044bd6f6417d86456febad202c9071112189818a44c539a4140d1
desc="migrate: scripts/dev/check-migrate.sh (the CI step that verifies the migrated copy) is pinned by its SHA-256 (any change: security review required)"
check bash -c '[[ "$(sha256sum scripts/dev/check-migrate.sh | cut -d" " -f1)" == "$1" ]] || { echo "scripts/dev/check-migrate.sh changed: security review required, then update the pinned hash" >&2; exit 1; }' _ "$check_migrate_pinned"
desc="migrate: the PKGBUILD migrates and then verifies the package (both lines exactly, in this order), and just check-quick runs check-migrate"
check bash -c 'grep -Fxn "  python3 -I \"\$root/scripts/dev/migrate-qs-imports.py\" --in-place \"\$pkgdir/usr/share/grassfield/shell\" || return 1" packaging/arch/PKGBUILD | cut -d: -f1 > "$1" && grep -Fxn "  python3 -I \"\$root/scripts/dev/migrate-qs-imports.py\" --verify --src \"\$root/shell\" \"\$pkgdir/usr/share/grassfield/shell\" || return 1" packaging/arch/PKGBUILD | cut -d: -f1 >> "$1" && [[ $(wc -l < "$1") == 2 && $(( $(tail -1 "$1") - $(head -1 "$1") )) == 2 ]] && grep -qE "^check-quick:.* check-migrate( |$)" justfile' _ "$(mktemp)"
desc="root: the readable second check (tests/security/root_check.py): ASCII only, no backslash, no regex literal, template string or bracket outside strings; every identifier one the root uses today; imports QtQuick, Quickshell, Quickshell.Io and qs.security.host only, wherever they stand; ShellRoot, SecurityHost and IpcHandler the only types; one SecurityHost; one IpcHandler, target security, the functions state and heartbeat only"
check python3 -I tests/security/root_check.py "$qml"
desc="root check selftest: the root passes (with LF and with CRLF) and each of the 38 planted mutants (next-line braces, comments before braces, indented imports, a singleton's property, names as strings or through Reflect, a U+2028 ending a comment, Unicode escapes, a second IpcHandler, an animation, Quickshell.reload, a third function, a renamed target, a second SecurityHost, the lock, idle, polkit or qs.security module imported into the root, ...) is refused"
check python3 -I tests/security/root_check.py --selftest "$qml"
desc="root: never reloads on a file change (settings.watchFiles: false)"
check grep -qE '^\s*settings\.watchFiles: false' "$qml"
desc="root: one IpcHandler, target security, functions state and heartbeat, and nothing else that answers IPC"
check bash -c '[[ $(grep -c "IpcHandler {" "$1") == 1 ]] && grep -qE "^\s*target: \"security\"" "$1" && grep -qE "^\s*function state\(\): string" "$1" && grep -qE "^\s*function heartbeat\(\): string" "$1" && [[ $(grep -cE "^\s*function " "$1") == 2 ]]' _ "$qml"
desc="host: logs the ready line the start-time measurement reads (shell/security/host/SecurityHost.qml, instantiated by the root)"
check bash -c 'grep -q "grassfield-security: ready" shell/security/host/SecurityHost.qml && grep -qE "^\s*SecurityHost \{" "$1"' _ "$qml"
desc="S2/S3 scan (tests/security/security_process_scan.py): the UI tree imports no security module and names no Lock, Idle, SleepInhibitor, AuthAgent, SecretAgent, SheetQueue, SheetSession, PrompterClient or PolkitAgent (no Lock.lock caller, no second polkit agent or prompter client in the UI); one Idle, one AuthAgent, one SecretAgent and one SheetQueue in the host; one PolkitAgent in the tree, in AuthAgent.qml; the security modules use no UI module, the lock and idle only the qs.services types Settings, VisualFixtures, FixedTime and WallClock, the sheets none; SessionState and LockClient named by no security module, SheetSession bound by the host alone from Lock.locked (and the stranded-lock probe), idle.displayOff, idle.saverShown, idle.starting and idle.sleeping (MINOR-4; the start notice of the delta review, LOW; the registration bound of round 2, MINOR-A); one definition of the state file; the UI never writes it (no FileView write, write option, adapter or process with its path in LockClient.qml, its path named nowhere else in the UI)"
check python3 -I tests/security/security_process_scan.py "$root"
desc="S2/S3/S4 scan selftest: the tree is clean, each of the 100 planted mutants (S4: a second SafeMode, its inputs bound to a constant, without the asked-for lock or the key sink, or unbound, SafeMode open by default, SafeMode in the UI or the lock, the UI importing it, safe mode on qs.services, SessionState or Settings; earlier steps: (code built from strings in the UI or Grassfield.Ui: createQmlObject, a Loader or createComponent of the agent, with a computed source or Qt.resolvedUrl of one, a web address as a source (round 2, NIT), a source or an import that is no file of the tree, in the UI or the security tree, its escapes decoded (an address with a scheme, an absolute path, a path out of the tree: round 3, NIT-1), a file: address or a security name in a string (the opus review of S3, MINOR-2, its M1 and M2); SheetSession open by default (M3); a UI caller of Lock.lock, a Connections on Lock, the lock, idle, polkit, secret or qs.security module imported into the UI, a second polkit agent, a prompter client, a queue or a raw PolkitAgent in the UI, a second Idle, AuthAgent or queue, no SecretAgent or a window in the host, a second PolkitAgent, the sheets reading SessionState or LockClient or importing qs.services, Popups, ThemeIcons, WallpaperState, Battery, the notification server or the desktop in the security modules, SheetSession bound to anything else, elsewhere, or assigned, a write of the state file from the UI, ...) is found, and each of the 5 allowed cases (a Loader or createComponent of Qt.resolvedUrl of a UI file, one spelled with escapes, http and https links whose path says security/: the delta review of S3, NIT) is not"
check python3 -I tests/security/security_process_scan.py --selftest "$root"
# ADR-0041 S4: safe mode, in this process (shell/security/safemode/).
sm=shell/security/safemode/SafeMode.qml
smodel=shell/security/safemode/SafeModeModel.js
notice=shell/security/safemode/SafeModeNotice.qml
card=shell/security/safemode/SafeModeCard.qml
# The controller runs commands as the user and decides when the notice may take input: pinned like the root and the host.
safe_mode_pinned=bd547ccd18d5e0957b99abbc75bd1a8208c99d0f7b2d36f7ffd09de0ea417ee8
desc="S4: the reviewed controller shell/security/safemode/SafeMode.qml is pinned by its SHA-256 (any change: security review required, then update the pinned hash)"
check bash -c '[[ "$(sha256sum "$1" | cut -d" " -f1)" == "$2" ]] || { echo "shell/security/safemode/SafeMode.qml changed: security review required, then update the pinned hash" >&2; exit 1; }' _ "$sm" "$safe_mode_pinned"
desc="S4: the host makes one SafeMode, its inputs from this process's lock (any state but unlocked, the stranded-lock probe) and sheets (open, held or the key sink); the controller reads both true until bound (the scan holds the exact bindings)"
check bash -c '[[ $(grep -cE "^\s*SafeMode \{" "$1") == 1 ]] && grep -qx "        locked: Lock.locked || Lock.strandedProbing || Lock.publicState !== \"unlocked\"" "$1" && grep -qx "        sheetUp: root.sheets !== null && (root.sheets.authorizing === true || root.sheets.securityKeyboard === true)" "$1" && grep -qx "    property bool locked: true" "$2" && grep -qx "    property bool sheetUp: true" "$2"' _ shell/security/host/SecurityHost.qml "$sm"
desc="S4: the notice is lazy (one LazyLoader, active only while shown, by the source of SafeModeNotice.qml; no window in the controller), and on screen only when confirmed, unlocked and no sheet is up (an exact false each)"
check bash -c '[[ $(grep -c "LazyLoader {" "$1") == 1 ]] && grep -A3 -x "    LazyLoader {" "$1" | grep -qx "        active: root.shown" && grep -qx "        source: Qt.resolvedUrl(\"SafeModeNotice.qml\")" "$1" && grep -qx "    readonly property bool shown: Model.shown(root.confirmed, root.locked, root.sheetUp)" "$1" && ! grep -qE "(PanelWindow|FloatingWindow|PopupWindow|WlrLayershell)" "$1" && grep -qx "    return isConfirmed === true && locked === false && sheetUp === false;" "$2" && grep -qx "    return isShown === true && busy === false;" "$2"' _ "$sm" "$smodel"
desc="S4: Try Again and Log Out refuse first unless the notice is on screen and nothing runs (SafeModeModel.canAct), whatever asks (a button, Return, the dev hook)"
check bash -c 'for f in tryAgain logOut; do grep -A1 -x "    function $f(): string {" "$1" | tail -1 | grep -qx "        if (!Model.canAct(root.shown, root.busy)) {" || exit 1; done' _ "$sm"
desc="S4: the commands are fixed, as the user: the look (the flag tested as a plain file, never read; systemctl show of grassfield-shell.service, bounded), Try Again (grassfield-shell-failed --try-again, bounded) and Log Out (grassfield-session-end logout, bounded); nothing else starts a process, reads or writes a file, or opens a socket in shell/security/safemode/"
check bash -c 'grep -qxF "        command: [\"/usr/bin/timeout\", \"-k\", \"1\", \"5\", \"/usr/bin/sh\", \"-c\", \"if [ -f \\\"\$1\\\" ] && [ ! -L \\\"\$1\\\" ]; then echo marker=1; else echo marker=0; fi; exec /usr/bin/systemctl --user show --property=ActiveState --property=SubState --property=Result grassfield-shell.service\", \"grassfield-safe-mode\", root.markerPath]" "$1" && grep -qxF "        command: [\"/usr/bin/timeout\", \"-k\", \"2\", \"40\", \"/usr/lib/grassfield/grassfield-shell-failed\", \"--try-again\"]" "$1" && grep -qxF "        command: [\"/usr/bin/timeout\", \"-k\", \"5\", \"330\", \"/usr/lib/grassfield/grassfield-session-end\", \"logout\"]" "$1" && [[ $(grep -c "^\s*command:" "$1") == 3 && $(grep -c "Process {" "$1") == 3 ]] && ! grep -nE "\b(FileView|Socket|SocketServer|JsonAdapter|PersistentProperties|LocalStorage)\s*\{|setText\(|execDetached|startDetached|Qt\.openUrlExternally" shell/security/safemode/*.qml' _ "$sm"
desc="S4: the dev session never asks systemd and runs no action (each suppressed with a journal line); its looks are the fake ones"
check bash -c 'grep -A3 -x "    function look(): void {" "$1" | grep -qx "        if (root.devHooks) {" && grep -q "dev session, suppressed Try Again" "$1" && grep -q "dev session, suppressed grassfield-session-end logout" "$1" && grep -qx "    readonly property bool devHooks: RunMode.dev(Quickshell.env(\"GRASSFIELD_DEV\"), Quickshell.env(\"GRASSFIELD_SESSION\"))" "$1"' _ "$sm"
desc="S4: the safemode IPC target has dev functions only (status, devSet, devPress), each refused outside a dev session first; nothing of safe mode answers IPC in a real session (the IPC table lists the row)"
check bash -c '[[ $(grep -c "IpcHandler {" "$1") == 1 ]] && grep -qx "        target: \"safemode\"" "$1" && [[ $(awk "/IpcHandler \\{/{on=1} on && /^        function /{print}" "$1" | wc -l) == 3 ]] && [[ $(awk "/IpcHandler \\{/{on=1} on && /^        function /{getline; print}" "$1" | grep -cx "            if (!root.devHooks)") == 3 ]] && grep -qE "^\| safemode \| status, devSet, devPress \| dev \|" "$2"' _ "$sm" docs/specs/security.md
desc="S4: the notice's window is one small Overlay layer surface (no anchor: centred by the compositor, never full screen), namespace grassfield-safe-mode, the keyboard on demand; the alert's text is fixed and plain, the caution symbol, never the Grassfield mark"
check bash -c '[[ $(grep -c "PanelWindow {" "$1") == 1 ]] && grep -qx "        WlrLayershell.layer: WlrLayer.Overlay" "$1" && grep -qx "        WlrLayershell.namespace: \"grassfield-safe-mode\"" "$1" && grep -qx "        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand" "$1" && ! grep -qE "^\s*anchors \{|anchors\.(fill|top|bottom|left|right)" "$1" && [[ $(grep -c "textFormat: Text.PlainText" "$2") == 3 ]] && grep -q "name: \"exclamationmark-triangle\"" "$2" && ! grep -q "grassfield-logo" "$2"' _ "$notice" "$card"
# ADR-0041 S3: the polkit agent and the secret sheets run here.
desc="S3 (the opus review of S3, LOW-4): the sheets count the start-up probe of a stranded or foreign lock as locked, bounded by the probe (Lock.strandedProbing: strandedUndecided && strandedProbe.running; SheetSession.locked <- Lock.locked || Lock.strandedProbing)"
check bash -c 'grep -qx "    readonly property bool strandedProbing: strandedUndecided && strandedProbe.running" shell/security/lock/Lock.qml && grep -qx "        value: Lock.locked || Lock.strandedProbing" shell/security/host/SecurityHost.qml'
desc="S3 (the opus review of S3, MINOR-3, its delta review, MAJOR-1, and its round 2, MINOR-A): while refused, the agent is made again (Quickshell asks only when a PolkitAgent is made and sets its path once), the Loader letting the old one go and making the next one an event-loop turn later, with a backoff, never in a dev session, never letting a registered agent or a request go; never while locked, the displays off or a sleep under way, at most 4 tries per unlock period, none after an attempt that stalled the event loop (AuthAgent.qml; authagent_flows.d test_36 to test_46 and 23 mutants; a real unlock only re-arms (round 3, MINOR-1); authagent_registration.sh on the real Quickshell)"
check bash -c 'f=shell/security/polkit/AuthAgent.qml; grep -qx "        running: root.retryArmed" $f && grep -qx "    readonly property bool retryArmed: !root.registered && !root.devSession && !root.quiet && !root.registrationStalled && root.periodTries < root.registrationTriesMax" $f && grep -qx "    readonly property bool quiet: SheetSession.locked || SheetSession.displaysOff || SheetSession.sleeping" $f && grep -qx "    readonly property int registrationTriesMax: 4" $f && grep -qx "        if (!root.retryArmed || root.agentActive)" $f && grep -A1 -x "        agentHolder.active = false;" $f | grep -qx "        agentRemake.restart();" && ! grep -qE "\.path = " $f'
desc="S3: the host says what it hosts (security state: lock idle, and polkit secrets once the sheets are made), and makes the sheets at run time so that a sheet that cannot load never keeps the lock from loading (the scan holds the one creation)"
check bash -c 'grep -qx "    readonly property string hosted: \"lock idle\" + (root.sheets !== null ? \" polkit secrets\" : \"\")" shell/security/host/SecurityHost.qml && ! grep -qE "^\s*SheetHost\s*\{" shell/security/host/SecurityHost.qml'
desc="S3: grassfield-prompter accepts a peer of this unit only (--peer-unit grassfield-security.service in its unit and as its default): the secret sheets share one queue with the polkit sheet (ADR-0035 decision 9-7); the UI's unit is refused"
check bash -c 'grep -qx "ExecStart=/usr/lib/grassfield/grassfield-prompter --peer-unit grassfield-security.service" packaging/systemd/grassfield-prompter.service && grep -q "peerUnit    = QStringLiteral(\"grassfield-security.service\");" bridges/prompter/src/main.cpp && ! grep -q "peer-unit grassfield-shell.service" packaging/systemd/grassfield-prompter.service'
desc="S3: an authorization asked while this process restarts fails (no agent until the restart: polkitd answers it not authorized), and nothing of the polkit module outlives the process: no file, process, socket or setting written by shell/security/polkit/ (a restarted agent starts with no request; tests/security/authagent_flows.d test_35)"
check bash -c 'grep -qx "Restart=always" "$1" && grep -qx "RestartSec=1" "$1" && ! grep -nE "\b(FileView|Process|Socket|SocketServer|JsonAdapter|PersistentProperties|LocalStorage)\s*\{|setText\(|\bSettings\.set|execDetached" shell/security/polkit/*.qml' _ "$unit"
desc="S3: the polkit and secret sheets' passwords live in this process: no core file here (LimitCORE=0, above), and the UI no longer instantiates either agent (the scan)"
check bash -c 'grep -qx "LimitCORE=0" "$1" && ! grep -nE "^\s*(AuthAgent|SecretAgent|SheetQueue)\s*\{" shell/shell.qml' _ "$unit"
if [[ -x /usr/lib/qt6/bin/qmllint ]]; then
  desc="root: qmllint parses it (unknown-module warnings aside)"
  check bash -c '/usr/lib/qt6/bin/qmllint "$1" 2>&1 | grep -v -i -E "warning" | grep -qi "error" && exit 1; exit 0' _ "$qml"
else
  echo "NOTE: security unit root: qmllint not installed here (syntax NOT VERIFIED by this run)"
fi

desc="unit: loads the root by its path in the system tree (GF-115), no -c, with -n"
check grep -qx 'ExecStart=/usr/bin/qs -n -p /usr/share/grassfield/shell/security.qml' "$unit"
desc="unit: the same cleared environment as the UI's unit (both UnsetEnvironment= lines identical, the same Environment=)"
check bash -c '[[ "$(grep "^UnsetEnvironment=" "$1")" == "$(grep "^UnsetEnvironment=" "$2")" && "$(grep "^Environment=" "$1")" == "$(grep "^Environment=" "$2")" ]]' _ "$unit" "$ui"
desc="unit: Restart=always, RestartSec=1, a start limit a loop reaches (5 in 300 s), session-only, part of and requiring the session target"
check bash -c 'grep -qx "Restart=always" "$1" && grep -qx "RestartSec=1" "$1" && grep -qx "StartLimitIntervalSec=300" "$1" && grep -qx "StartLimitBurst=5" "$1" && grep -qx "ConditionEnvironment=GRASSFIELD_SESSION=1" "$1" && grep -qx "PartOf=graphical-session.target" "$1" && grep -qx "Requisite=graphical-session.target" "$1" && grep -qx "Slice=session.slice" "$1"' _ "$unit"
desc="unit: no NoNewPrivileges, ProtectSystem or sandbox that would break unix_chkpwd and polkit-agent-helper-1 (S2, S3), as the UI's unit"
check bash -c '! grep -qE "^(NoNewPrivileges|ProtectSystem|ProtectHome|PrivateUsers|SystemCallFilter|CapabilityBoundingSet)=" "$1"' _ "$unit"
# Quickshell's crash handler kept a crashed process alive under a relaunched child: systemd saw no failure, OnFailure= never ran
# (the integrator's nested run of e1a3ff4c). Off in both units and in the dev launcher, so a crash ends the process. And no
# core file (the opus delta review of 122f8d67, MAJOR): a dump of the process that reads the password is user-readable.
desc="unit: no core file (LimitCORE=0) in this unit and the UI's (the polkit agent and the secret sheets), and none from the dev launcher (ulimit -c 0 before both processes): a crash is logged, its memory never stored"
check bash -c 'grep -qx "LimitCORE=0" "$1" && grep -qx "LimitCORE=0" "$2" && [[ $(grep -c "^LimitCORE=" "$1") == 1 && $(grep -c "^LimitCORE=" "$2") == 1 ]] && grep -A1 -x "crash_env=(QS_DISABLE_CRASH_HANDLER=1)" scripts/dev/shell-run.sh | grep -qx "ulimit -c 0"' _ "$unit" "$ui"
desc="unit: Quickshell's crash handler off (Environment=QS_DISABLE_CRASH_HANDLER=1) in this unit and the UI's, and in scripts/dev/shell-run.sh for both processes: a crash ends the process, systemd restarts it and OnFailure= runs"
check bash -c 'grep -qx "Environment=QS_DISABLE_CRASH_HANDLER=1" "$1" && grep -qx "Environment=QS_DISABLE_CRASH_HANDLER=1" "$2" && grep -qx "crash_env=(QS_DISABLE_CRASH_HANDLER=1)" scripts/dev/shell-run.sh && [[ $(grep -c "^ *env \"\${unit_unset\[@\]}\" \"\${timing\[@\]}\" \"\${crash_env\[@\]}\"" scripts/dev/shell-run.sh) == 2 ]]' _ "$unit" "$ui"
desc="unit: OnFailure=omarchy-sleep-lock.service (S2: the sleep lock armed after every failure of the process that holds the inhibitor), and the UI's unit no longer arms it (its OnFailure= is the failure counter alone)"
check bash -c '[[ $(grep -c "^OnFailure=" "$1") == 1 ]] && grep -qx "OnFailure=omarchy-sleep-lock.service" "$1" && grep -qx "OnFailure=grassfield-shell-failed.service" "$2" && ! grep -q "omarchy-sleep-lock" <(grep "^OnFailure=" "$2")' _ "$unit" "$ui"
desc="unit: the lock keeps at least the headroom it had in the UI's unit (MemoryHigh and MemoryMax at least the UI unit's: never throttled before it is measured, the opus review of 77a0ceb3 MAJOR-2); CPUQuota as the UI unit's, at least a whole core"
check bash -c 'mb() { sed -nE "s/^$1=([0-9]+)([MG])$/\1 \2/p" "$2" | awk "{ print (\$2 == \"G\") ? \$1 * 1024 : \$1 }"; }
  high=$(mb MemoryHigh "$1") && max=$(mb MemoryMax "$1") && uihigh=$(mb MemoryHigh "$2") && uimax=$(mb MemoryMax "$2") && cpu=$(sed -nE "s/^CPUQuota=([0-9]+)%$/\1/p" "$1") &&
  [[ -n $high && -n $max && -n $uihigh && -n $uimax && -n $cpu ]] && ((high >= uihigh && max >= uimax && max > high && cpu >= 100)) &&
  [[ $cpu == "$(sed -nE "s/^CPUQuota=([0-9]+)%$/\1/p" "$2")" ]] && grep -q "157 MB" "$1" && grep -q "MemoryPeak" "$1"' _ "$unit" "$ui"
desc="autostart: started just before the shell, without waiting for it (--no-block), and the shell still starts if it failed"
check bash -c 'grep -q "systemctl --user start --no-block grassfield-security.service; systemctl --user start grassfield-shell.service" "$1"' _ config/hypr/grassfield/autostart.lua
desc="package: the unit is installed with the session units; the root ships with the shell tree; the helper from packaging/bin"
check bash -c 'grep -q "for unit in .*security" "$1" && grep -q "cp -a --no-preserve=ownership \"\$root/shell\" \"\$pkgdir/usr/share/grassfield/shell\"" "$1"' _ packaging/arch/PKGBUILD
desc="helper: read-only, calls the targets by the unit's path with Quickshell's option variables cleared (security state and heartbeat, lock state), never start, stop, kill or unlock"
check bash -c '[[ -x "$1" ]] && grep -q "unset QS_CONFIG_PATH QS_CONFIG_NAME QS_MANIFEST" "$1" && grep -q "call security state" "$1" && grep -q "call security heartbeat" "$1" && grep -q "call lock state" "$1" && ! grep -v "^#" "$1" | grep -qE "systemctl --user (start|stop|kill|restart|reset-failed)|unlock|kill "' _ "$helper"
desc="helper: works from a TTY: --any-display when WAYLAND_DISPLAY is not set (the instance is on another display connection), never inside the session"
check bash -c 'grep -q "\[ -n \"\${WAYLAND_DISPLAY:-}\" \] || display=\"--any-display\"" "$1" && [[ $(grep -c "qs ipc \$display -p" "$1") == 3 ]]' _ "$helper"
desc="IPC surface: the table lists target security with state and heartbeat as actions with their caller (tests/security/ipc_inventory.sh holds it to the code)"
check grep -qE '^\| security \| state, heartbeat \| action \|' docs/specs/security.md
desc="restart limits: the unit passes the lifetime model (a 10 s loop ends at its limit: 5 x (1 + 10) = 55 <= 300)"
check python3 -I tests/shell/unit_restart_limits.py "$unit"
exit "$fail"
