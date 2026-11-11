#!/usr/bin/env bash
# The polkit agent's behaviour, offscreen (reviews of f513b3b, b5d7657 and 38dbfe8): the real shell/security/polkit/AuthAgent.qml
# with its Quickshell types replaced by plain QML (authagent_flows.d/make_harness.py; the logic untouched), beside the real
# sheet and model, driven by authagent_flows.d/flows.qml and sink.qml with real key and mouse events through the request orders
# Quickshell 0.3.1 produces: a request replacing the open one, back-to-back requests, one ending under the user's typing, the
# lock, the screen saver. Nothing typed for one request may reach another one's field or the window underneath (security
# counter-review of f9e24e1: nor the rest of a password typed into a request that ends unanswered; the notice that says
# so while the keys go nowhere). window.qml runs the same agent in FakePanel.qml
# (make_harness.py --panel): a window made again each time it is shown and given the keyboard only once mapped, as
# Quickshell's PanelWindow and a compositor do, beside a window underneath (check of c1ca44f). flows.qml test_20 to test_34:
# a request the user cannot see (locked, saver, displays off, held other than right after another one, waiting behind a
# secret sheet, replaced) is refused once PAM talks without asking, as for a fingerprint reader (ADR-0045 OC-6, security
# review of e3542510 and its re-reviews). test_36 to test_46: registration (ADR-0041 S3, the opus review's MINOR-3, its
# delta review's MAJOR-1 and its round 2's MINOR-A): refused, the agent is made again with a backoff and the new one asks
# again, never while locked, the displays off or a sleep under way, at most four times per unlock period, and never again
# in that period once an attempt stopped the event loop (the plain agent can: mockBlockMs); the plain agent keeps
# Quickshell's rules (asks only when made, its path set once, one per process: make_harness.py), so a retry by a new path
# or one made before the last is gone is caught; tests/security/authagent_registration.sh counts the attempts on a real
# Quickshell. No compositor, no polkit, no PAM.
# Against the security process (ADR-0041 step 1, S3): the agent runs there, beside the lock it reads in process
# (qs.security's SheetSession, which the tests set as SecurityHost's Bindings would), so the harness gives it qs.security and
# qs.lib only: no qs.services, nothing of the UI (an import of the UI's world fails to load here).
#
#   tests/security/authagent_flows.sh              the tests: PASS / FAIL
#   tests/security/authagent_flows.sh --mutants    also each mutant below, which the tests must catch ("MUTANT <name>: CAUGHT")
#
# Scratch copies under .dev/ (removed on exit); the working tree is never edited. QMLTESTRUNNER overrides the runner's path.
# Exit 0 PASS, 1 FAIL, 2 environment error; SKIP (exit 0) without qmltestrunner or python3.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
runner=${QMLTESTRUNNER:-/usr/lib/qt6/bin/qmltestrunner}
d=$root/tests/security/authagent_flows.d
[[ -x $runner ]] || { echo "SKIP: authagent_flows needs qmltestrunner ($runner)"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: authagent_flows needs python3"; exit 0; }
mutants=0
case ${1:-} in
  "") ;;
  --mutants) mutants=1 ;;
  *) echo "usage: authagent_flows.sh [--mutants]" >&2; exit 2 ;;
esac
mkdir -p "$root/.dev"
scratch=$(mktemp -d "$root/.dev/authagent-flows.XXXXXX") || { echo "ENVIRONMENT: no scratch directory"; exit 2; }
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unset QT_QPA_PLATFORMTHEME
export QT_QPA_PLATFORM=offscreen

# qs.security and qs.lib are the real folders, and the only qs modules (the security process's world, ADR-0041 S3).
mkdir -p "$scratch/qsroot/qs"
ln -s "$root/shell/security" "$scratch/qsroot/qs/security"
ln -s "$root/shell/lib" "$scratch/qsroot/qs/lib"

# run <dir with AuthAgent.qml, AuthDialog.qml, AuthDialogModel.qml>: generates the harness and runs the tests; the output on
# stdout, 0 when every case passed and no QML runtime error was printed (gate Q2's failures, in the generated copies too).
run() {
  local src=$1 case_dir=$scratch/run out
  rm -rf "$case_dir"
  mkdir -p "$case_dir/polkit" "$case_dir/panel"
  python3 -I "$d/make_harness.py" "$src/AuthAgent.qml" "$case_dir/polkit/AgentUnderTest.qml" || return 1
  python3 -I "$d/make_harness.py" --panel "$src/AuthAgent.qml" "$case_dir/panel/AgentUnderTest.qml" || return 1
  cp "$src/AuthDialog.qml" "$src/AuthDialogModel.qml" "$case_dir/polkit/"
  cp "$src/AuthDialog.qml" "$src/AuthDialogModel.qml" "$d/FakePanel.qml" "$case_dir/panel/"
  # The test files are named without tst_ in the tree, so the tests/security run does not load them without the harness.
  cp "$d/flows.qml" "$case_dir/tst_flows.qml"
  cp "$d/sink.qml" "$case_dir/tst_sink.qml"
  cp "$d/window.qml" "$case_dir/tst_window.qml"
  out=$(cd "$case_dir" && "$runner" -import "$root/ui" -import "$scratch/qsroot" -input . 2>&1)
  echo "$out"
  ! grep -q '^FAIL' <<<"$out" && grep -qE '^Totals: [0-9]+ passed, 0 failed' <<<"$out" &&
    ! grep -qE '^QWARN.*(TypeError|ReferenceError|Binding loop|Unable to assign|is not a function|is not a constructor)' <<<"$out"
}

real=$scratch/real
mkdir -p "$real"
cp "$root/shell/security/polkit/AuthAgent.qml" "$root/shell/security/polkit/AuthDialog.qml" "$root/shell/security/polkit/AuthDialogModel.qml" "$real/"
out=$(run "$real")
rc=$?
grep -E '^(PASS|FAIL|Totals)' <<<"$out" | grep -vE '^PASS   : qmltestrunner::[A-Za-z]+::(initTestCase|cleanupTestCase)\(\)'
if ((rc != 0)); then
  grep -E '^(QWARN|QDEBUG|   Loc|   Actual|   Expected)|error|Error' <<<"$out" | head -40
  echo "FAIL: authagent_flows"
  exit 1
fi
((mutants)) || { echo "PASS: authagent_flows"; exit 0; }

# Each mutant brings back a defect a review found: its name, then triples of a file, a text that must occur in it once and what
# replaces it ('#'-separated, \n a newline). The tests must fail on every one. focusField doing nothing while the input is
# disabled is a second guard behind the sheet handing the focus back: it is removed with it. The sheet focusing its field at
# another moment (the check of 38dbfe8's M3) is no longer one (lock_surfaces.sh pins those call sites). Two orders of the
# f9e24e1 fix are pinned by lock_surfaces.sh only, the tests here cannot tell them apart (measured): the window's `visible` and
# `takesKeys` reading the model's `active` instead of `requestOpen` (here the agent's handler runs before the window's bindings
# see a request's end), and the hold changed before `requestOpen` goes false at an end (a flicker inside one function; the
# panel, as a compositor, takes the keyboard request at the next frame).
status=0
while IFS= read -r line; do
  [[ -n $line ]] || continue
  IFS='#' read -r -a f <<<"$line"
  name=${f[0]}
  m=$scratch/mutant
  rm -rf "$m"
  cp -a "$real" "$m"
  python3 -I - "$m" "${f[@]:1}" <<'PY' || { echo "MUTANT $name: NOT APPLIED (a text is not there once)"; status=1; continue; }
import sys
base, rest = sys.argv[1], [a.replace("\\n", "\n") for a in sys.argv[2:]]
if not rest or len(rest) % 3:
    sys.exit(4)
for name, old, new in zip(rest[0::3], rest[1::3], rest[2::3]):
    path = base + "/" + name
    text = open(path).read()
    if text.count(old) != 1:
        sys.exit(3)
    open(path, "w").write(text.replace(old, new))
PY
  if run "$m" >/dev/null; then echo "MUTANT $name: NOT CAUGHT"; status=1; else echo "MUTANT $name: CAUGHT"; fi
done <<'EOF_MUTANTS'
no-focus-taken-back (38dbfe8 MEDIUM-A, c1ca44f M2)#AuthAgent.qml#                onActiveFocusChanged: if (activeFocus && root.sinkingKeys)#                onActiveFocusChanged: if (false)
no-focus-taken-back, field focused while disabled (c1ca44f M2)#AuthAgent.qml#                onActiveFocusChanged: if (activeFocus && root.sinkingKeys)#                onActiveFocusChanged: if (false)#AuthDialog.qml#        if (root.inputEnabled)\n            field.forceActiveFocus();#        field.forceActiveFocus();
typing-read-late (38dbfe8 LOW-2 M1)#AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#let typing = false;#AuthAgent.qml#        root.userFocused = false;\n        if (dialogModel.active)\n            root.requestOpen = true;#        root.userFocused = false;\n        typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);\n        root.sinkingKeys = typing;\n        if (dialogModel.active)\n            root.requestOpen = true;
lock-keeps-sink (38dbfe8 LOW-2 M2)#AuthAgent.qml#            root.sinkingKeys = false;\n            if (dialogModel.active) {#            if (dialogModel.active) {
no-linger (38dbfe8 MEDIUM-B)#AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#const typing = (follows && win.takesKeys) || (!dialogModel.active && win.takesKeys && !dialogModel.answered);
unmapped-linger (38dbfe8 MEDIUM-B)#AuthAgent.qml#visible: !SheetSession.locked && (root.requestOpen || root.sinkingKeys)#visible: shown
visible-through-lingering (c1ca44f M1)#AuthAgent.qml#visible: !SheetSession.locked && (root.requestOpen || root.sinkingKeys)#visible: shown || root.lingering
keys-through-lingering (c1ca44f M1)#AuthAgent.qml#readonly property bool takesKeys: !SheetSession.locked && ((root.requestOpen && (!root.heldByLock || root.userFocused)) || root.sinkingKeys)#readonly property bool takesKeys: (shown && (!root.heldByLock || root.userFocused || root.sinkingKeys)) || root.lingering
input-enabled-while-sinking (c1ca44f M2)#AuthAgent.qml#                inputEnabled: !root.sinkingKeys#                inputEnabled: true
linger-start-read-stale (c1ca44f)#AuthAgent.qml#        if (typing && !dialogModel.active && !SheetSession.locked) {#        if (root.lingering) {
cap-never-started (c1ca44f L1)#AuthAgent.qml#            sinkIdle.restart();\n            sinkCap.restart();#            sinkIdle.restart();
cap-ends-request-sink (c1ca44f L1)#AuthAgent.qml#        interval: dialogModel.sinkLingerMaxMs\n        onTriggered: if (root.lingering)#        interval: dialogModel.sinkLingerMaxMs\n        onTriggered: if (true)
linger-ends-request-sink#AuthAgent.qml#        interval: dialogModel.heldAfterUnlockMs\n        onTriggered: if (root.lingering)#        interval: dialogModel.heldAfterUnlockMs\n        onTriggered: if (true)
no-escape (38dbfe8 LOW-1)#AuthAgent.qml#                else if (event.key === Qt.Key_Escape)\n                    dialogModel.cancel();#                else if (event.key === Qt.Key_Escape)\n                    ;
linger-arrival-unheld#AuthAgent.qml#(follows || typing || dialogModel.arrivesHeld(#(follows || dialogModel.arrivesHeld(
no-sink (b5d7657 MEDIUM-2)#AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#const typing = false;
no-linger-own-field (f9e24e1 LOW-1)#AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#const typing = (follows && win.takesKeys) || root.sinkingKeys;
linger-ignores-the-window (f9e24e1 LOW-1)#AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && !dialogModel.answered);
linger-after-an-answer (f9e24e1 LOW-1)#AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys && !dialogModel.answered);#const typing = (follows && win.takesKeys) || root.sinkingKeys || (!dialogModel.active && win.takesKeys);
answer-not-noted-on-send (f9e24e1 LOW-1)#AuthDialogModel.qml#        priv.submitted = true;\n        priv.answered = true;#        priv.submitted = true;
answer-not-noted-on-cancel (f9e24e1 LOW-1)#AuthDialogModel.qml#        priv.submitted = false;\n        priv.answered = true;#        priv.submitted = false;
answer-kept-after-failure (f9e24e1 LOW-1)#AuthDialogModel.qml#            root.priv.submitted = false;\n            root.priv.answered = false;\n            root.priv.error#            root.priv.submitted = false;\n            root.priv.error
answer-cleared-at-the-end (f9e24e1 LOW-1)#AuthDialogModel.qml#        if (flow)\n            priv.answered = false;#        priv.answered = false;
window-unmapped-before-the-sink (f9e24e1 LOW-1)#AuthAgent.qml#        root.sinkingKeys = typing;\n        if (!dialogModel.active)\n            root.requestOpen = false;#        if (!dialogModel.active)\n            root.requestOpen = false;\n        root.sinkingKeys = typing;
no-ended-notice (f9e24e1 LOW-3)#AuthAgent.qml#            visible: root.lingering#            visible: false
ended-notice-over-a-sheet (f9e24e1 LOW-3)#AuthAgent.qml#            visible: root.lingering#            visible: root.sinkingKeys
device-answers-unseen (e3542510 MAJOR-2)#AuthDialogModel.qml#        if (refusesUnseen)\n            request.cancelAuthenticationRequest();#        if (refusesUnseen)\n            console.info("refused");
refusal-inside-the-binding (e3542510 MAJOR-2, binding loop)#AuthDialogModel.qml#        Qt.callLater(root.refuseUnseen)#        root.refuseUnseen()
device-answers-behind-lock-and-saver (e3542510 MAJOR-2)#AuthAgent.qml#        answerable: !SheetSession.locked && !SheetSession.saverShown && #        answerable:
held-shown-request-refused (re-review: Remote Login, Add Printer)#AuthAgent.qml#root.userFocused || root.heldWhy === "queued")#root.userFocused)
unlock-held-answerable (re-review 2 MINOR-1)#AuthAgent.qml#                    && (!root.heldByLock || root.userFocused || root.heldWhy === "queued")#                    && true
displays-off-ignored (re-review 2 MINOR-2)#AuthAgent.qml#!SheetSession.displaysOff && #true &&
replaced-not-watched (re-review MAJOR-1)#AuthDialogModel.qml#            priv.replaced = liveReplaced().concat([before]);#            ;
replaced-alone-refused (re-review MAJOR-1)#AuthDialogModel.qml#        if (request && request.isCompleted !== true && replaced.indexOf(request) < 0)\n            request.cancelAuthenticationRequest();#        ;
replaced-refused-first (re-review MAJOR-1)#AuthDialogModel.qml#        if (request && request.isCompleted !== true && replaced.indexOf(request) < 0)\n            request.cancelAuthenticationRequest();\n        for (const f of replaced)\n            f.cancelAuthenticationRequest();#        for (const f of replaced)\n            f.cancelAuthenticationRequest();\n        if (request && request.isCompleted !== true && replaced.indexOf(request) < 0)\n            request.cancelAuthenticationRequest();
replaced-refusal-inside-the-binding (re-review MAJOR-1)#AuthDialogModel.qml#        Qt.callLater(root.refuseReplaced)#        root.refuseReplaced()
device-answers-a-waiting-request (e3542510 MAJOR-2)#AuthAgent.qml#        request: root.agent !== null ? root.agent.flow : null#        request: root.agentActive && !root.waiting ? root.agent.flow : null
device-answers-always (e3542510 MAJOR-2)#AuthAgent.qml#        answerable: !SheetSession.locked#        answerable: true || !SheetSession.locked
registration-never-asked-again (S3 review MINOR-3)#AuthAgent.qml#        running: root.retryArmed#        running: false
registration-by-setPath (S3 delta review MAJOR-1: the retry of 655916ba)#AuthAgent.qml#        agentHolder.active = false;\n        agentRemake.restart();#        root.agent.path = root.agentPath + "/" + root.registrationTries;
registration-remade-in-the-same-turn (S3 delta review MAJOR-1)#AuthAgent.qml#        agentHolder.active = false;\n        agentRemake.restart();#        agentHolder.active = false;\n        agentHolder.active = true;
registration-never-remade (S3 delta review MAJOR-1)#AuthAgent.qml#            root.watchAttempt();\n            agentHolder.active = true;#            root.watchAttempt();
registration-no-backoff (S3 review MINOR-3)#AuthAgent.qml#        interval: root.registrationRetryInterval#        interval: root.registrationRetryMs
registration-no-doubling (S3 review MINOR-3)#AuthAgent.qml#root.registrationRetryMs * Math.pow(2, Math.min(root.periodTries, 10)))#root.registrationRetryMs)
registration-no-longest-wait (S3 review MINOR-3)#AuthAgent.qml#Math.min(root.registrationRetryMaxMs, root.registrationRetryMs#Math.min(1000000000, root.registrationRetryMs
registration-asked-while-registered (S3 review MINOR-3)#AuthAgent.qml#    readonly property bool retryArmed: !root.registered && #    readonly property bool retryArmed:
registration-lets-a-request-go (S3 delta review MAJOR-1)#AuthAgent.qml#        if (!root.retryArmed || root.agentActive)#        if (!root.retryArmed)
registration-asked-in-a-dev-session (S3 review MINOR-3)#AuthAgent.qml#!root.registered && !root.devSession && !root.quiet#!root.registered && !root.quiet
registration-while-quiet (S3 round 2 MINOR-A)#AuthAgent.qml#!root.devSession && !root.quiet && !root.registrationStalled#!root.devSession && !root.registrationStalled
registration-while-locked (S3 round 2 MINOR-A)#AuthAgent.qml#    readonly property bool quiet: SheetSession.locked || SheetSession.displaysOff#    readonly property bool quiet: SheetSession.displaysOff
registration-while-the-displays-are-off (S3 round 2 MINOR-A)#AuthAgent.qml#SheetSession.locked || SheetSession.displaysOff || SheetSession.sleeping#SheetSession.locked || SheetSession.sleeping
registration-while-a-sleep-is-under-way (S3 round 2 MINOR-A)#AuthAgent.qml#SheetSession.displaysOff || SheetSession.sleeping#SheetSession.displaysOff
registration-made-at-the-lock (S3 round 2 MINOR-A)#AuthAgent.qml#            if (root.quiet || root.registrationStalled)\n                return;\n            root.watchAttempt();#            root.watchAttempt();
registration-no-cap (S3 round 2 MINOR-A)#AuthAgent.qml# && root.periodTries < root.registrationTriesMax# && true
registration-cap-kept-after-an-unlock (S3 round 2 MINOR-A)#AuthAgent.qml#        root.periodTries = 0;\n        root.registrationStalled = false;#        root.registrationStalled = false;
registration-unlock-unseen (S3 round 2 MINOR-A)#AuthAgent.qml#                root.sawLock = false;\n                root.rearmRegistration();#                root.sawLock = false;
registration-rearm-on-any-fall-of-locked (S3 round 3 MINOR-1)#AuthAgent.qml#            } else if (root.sawLock) {#            } else if (true) {
registration-lock-never-seen (S3 round 3 MINOR-1)#AuthAgent.qml#            if (SheetSession.locked) {\n                root.sawLock = true;#            if (SheetSession.locked) {\n                root.sawLock = false;
registration-stall-ignored (S3 round 2 MINOR-A)#AuthAgent.qml#        if (sinceMs > root.stallLimitMs && #        if (false &&
registration-stall-kept-after-an-unlock (S3 round 2 MINOR-A)#AuthAgent.qml#        root.periodTries = 0;\n        root.registrationStalled = false;#        root.periodTries = 0;
registration-stall-unwatched (S3 round 2 MINOR-A)#AuthAgent.qml#            root.watchAttempt();\n            agentHolder.active = true;#            agentHolder.active = true;
EOF_MUTANTS
((status == 0)) && echo "PASS: authagent_flows (and every mutant caught)" || echo "FAIL: authagent_flows mutants"
exit "$status"
