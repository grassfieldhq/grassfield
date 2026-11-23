#!/usr/bin/env bash
# Startup settle, wiring (review of fix/startup-settle): the Dock and the desktop show once, in place. The Dock cannot be
# instantiated offscreen (no PanelWindow backend), so the wiring is checked statically; the rules themselves are in
# tests/unit/tst_dockgeometry.qml and tst_desktopicons.qml, the store in tests/shell/startup_settle.sh, the picture in a nested
# capture burst. Fails when one of these is reverted:
#  * Dock: the windows are mapped only when settled; the first fill glides, fades and shifts nothing before it; the fallback timer
#    exists, uses the token and settles; settle() sets `settled` in a finally and starts every window's auto-hide machine from
#    AutoHide.initial(autohide); the inputs are the settings and the apps model only.
#  * Store: `loaded` flips after the document is taken (all three branches), and also for a missing file.
#  * Desktop: `lay` is empty until ready; `ready` waits for the listing, settings and widgets; entriesListed resets with the
#    folder; a stale (cwd) listing is refused row by row and nothing is pruned before a complete listing; Clean Up waits for
#    ready; an icon is invisible until whole, with a bounded wait.
# WIRING_ROOT (a copy of the tree) is for the mutant runs.
set -uo pipefail
root=${WIRING_ROOT:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}
cd "$root" || exit 2
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
has() { grep -qF -- "$2" "$1"; }
# Line number of the first line containing a fixed string at or after line $3 (default 1); empty when absent.
at() { tail -n +"${3:-1}" "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1 | awk -v o="${3:-1}" '{print $1 + o - 1}'; }
# True when the fixed string A is found, and B is found after it (within 40 lines, the same function).
before() { local a; a=$(at "$1" "$2"); [ -n "$a" ] || return 1; local b; b=$(at "$1" "$3" "$a"); [ -n "$b" ] && [ $((b - a)) -le "${4:-40}" ]; }
# The text from the first line containing a fixed string, for 40 lines.
block() { local a; a=$(at "$1" "$2"); [ -n "$a" ] && tail -n +"$a" "$1" | head -"${3:-40}"; }

D=shell/dock/Dock.qml S=shell/store/SettingsStore.qml F=shell/desktop/DesktopFiles.qml V=shell/desktop/IconsView.qml I=shell/desktop/DesktopIcon.qml

desc="Dock: the windows are revealed only when settled and placed (reveal), and mapped at once"
check has $D "readonly property bool revealWanted: root.settled && (placed || placedGivenUp)"
check has $D "onRevealWantedChanged: {"
check before $D "onRevealWantedChanged: {" "reveal = true;" 4
desc="Dock: the reveal is latched (a position change never hides the Dock)"
check has $D "property bool reveal: false"
check has $D "readonly property bool placed: screen !== null && Geometry.placed("
check bash -c '! grep -q "visible: root.settled" "$1"' _ $D
desc="Dock: before the reveal nothing is drawn, caught or reserved (opacity, mask, blur, exclusive zone, keyboard, probe)"
check has $D "opacity: win.reveal ? 1 : 0"
check has $D "mask: win.reveal ? hitMask : emptyMask"
check has $D "BackgroundEffect.blurRegion: win.reveal && shelf.blurActive ? blurRegion : null"
check has $D "exclusiveZone: reveal && hasDock ?"
check has $D "if (!windows.instances.some(w => w.screenName === root.actionScreen && w.reveal))"
check has $D "active: win.reveal"
desc="Dock: the placed fallback timer runs after settle and gives up"
check has $D "onTriggered: win.placedGivenUp = true"
check has $D "running: root.settled && !win.reveal && !win.placedGivenUp"
t=$(block $D "readonly property bool placed: screen" 12)
check bash -c 'grep -q "interval: Tokens.dockSettleTimeout" <<<"$1"' _ "$t"
desc="Dock: the make-room Behavior is off before settled"
check has $D "enabled: win.reveal && !tile.dragging && !win.dragSnap"
desc="Dock: playLayout does nothing before settled"
check has $D "if (!reveal || Appearance.reduceMotion || dragFrom >= 0)"
desc="Dock: the fallback timer runs until settled, uses the token and releases the wait (waited), which feeds settledOn"
t=$(block $D "id: settleTimer" 6)
check bash -c 'grep -q "running: !root.settled" <<<"$1" && grep -q "interval: Tokens.dockSettleTimeout" <<<"$1" && grep -q "onTriggered: root.waited = true" <<<"$1"' _ "$t"
check has $D "waited: waited"
desc="Dock: settle() resets every window's machine, then sets settled in a finally"
check before $D "function settle(): void {" "} finally {" 25
check before $D "} finally {" "windows.instances.forEach(w => w.resetHide())" 6
check before $D "windows.instances.forEach(w => w.resetHide())" "settled = true" 4
desc="Dock: settle() latches the output with Geometry.settleScreen (the fallback latch)"
check has $D "chosenScreen = Geometry.settleScreen(chosenScreen, screenNames, Compositor.focusedScreenName, startHint);"
desc="Dock: resetHide starts the machine from AutoHide.initial(autohide)"
check has $D "hideMachine = AutoHide.initial(autohide);"
desc="Dock: the inputs are the settings file and the apps model"
check bash -c 'grep -q "settings: Settings.loaded && MainDisplay.ready," "$1" && grep -q "apps: Apps.hiddenReady," "$1"' _ $D
desc="Dock: a settled Dock settles once and the input change calls settle()"
check bash -c 'grep -q "onInputsFinalChanged" "$1" && grep -q "if (settled)" "$1"' _ $D

desc="Store: loaded flips after takeDocument (usable file)"
check before $S "root.takeDocument(read.text);" "root.loaded = true" 4
desc="Store: loaded flips after takeMissingFile (a missing file counts as read)"
check before $S "root.takeMissingFile();" "root.loaded = true" 4
desc="Store: loaded flips after takeBadFile"
bad=$(at $S "const level = same ? root.badLevel + 1 : 0;"); tb=$(at $S "root.takeBadFile(root.badReason(read.status));" "${bad:-1}"); ld=$(at $S "root.loaded = true" "${tb:-1}")
check test -n "$bad" -a -n "$tb" -a -n "$ld" -a "$((tb - bad))" -le 3 -a "$((ld - tb))" -le 2

desc="Store: the first read starts at once, not behind the folder's mkdir"
check has $S "root.started = true;"
desc="Desktop: lay is empty until ready (and on a display that does not hold the icons)"
check has $V "readonly property var lay: ready && iconsHere ? Logic.layout("
desc="Desktop: ready waits for the settings, the widgets, the positions and the listing"
check bash -c 'grep -q "settings: Settings.loaded" "$1" && grep -q "widgets: Widgets.loaded" "$1" && grep -q "positions: files.positionsLoaded" "$1" && grep -q "listed: files.entriesListed" "$1"' _ $V
desc="Desktop: Clean Up waits for ready"
check has $V 'else if (action.startsWith("cleanUp") && !root.ready)'
desc="Desktop: entriesListed resets with the folder"
check has $F "onDirChanged: entriesListed = false"
desc="Desktop: a stale listing (parent is not the desktop folder, or the model is on another folder) is refused row by row"
t=$(block $F "function rebuild(): void {" 45)
check bash -c 'grep -q "Logic.dirName(String(model.get(i, \"filePath\"))) !== dir" <<<"$1" && grep -q "String(model.folder) !== String(Qt.url(folderUrl))" <<<"$1" && grep -q "entriesListed = false" <<<"$1"' _ "$t"
desc="Desktop: nothing is pruned before a complete listing (the prune follows entriesListed = true)"
check before $F "entriesListed = true;" "Logic.prune" 6
desc="Desktop icon: invisible until whole, bounded by the token"
check bash -c 'grep -q "opacity: shown ? 1 : 0" "$1" && grep -q "interval: Tokens.desktopIconLoadTimeout" "$1" && grep -q "readonly property bool whole: imageDone && (!launcher || info.read)" "$1" && grep -q "onLoadFailed: info.read = true" "$1"' _ $I

exit $fail
