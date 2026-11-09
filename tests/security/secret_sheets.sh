#!/usr/bin/env bash
# The secret sheets and the one queue they share with the polkit sheet (ADR-0035 D-9, step 9b; master-prompt R12), offscreen:
# the real shell/security/secret/SecretAgent.qml and shell/security/polkit/AuthAgent.qml with their Quickshell types replaced
# by plain QML (secret_sheets.d/make_harness.py and authagent_flows.d/make_harness.py; the logic untouched), beside the real
# SecretSheet, SecretSheetModel, AuthDialog, AuthDialogModel and SheetQueue, wired as shell.qml wires them, driven by
# secret_sheets.d/sheets.qml with real key and mouse events, a fake prompter client and mock polkit flows (step 9c: the
# Wi-Fi alert of a NetworkManager request: held, Join's length rule, Show password, enterprise, cancelled by NetworkManager
# while typed into, in the queue with polkit and gcr, hidden again by the lock; step 9e: KIO's server sheet: held, the name
# field's modes, Connect's rule, Remember and the keyring's line, the realm framed, retry, an unidentified requester; step 10:
# BlueZ's pairing sheets: held, no key answering a confirmation or an authorization, Decline, the passkey's and the PIN's
# rules, a code shown with Cancel alone following the digits typed on the device without touching the keyboard): a gcr password
# answered once, the field then empty; cancel; a withdrawn request (queued: never shown; shown: the sink keeps the rest of
# the password); the ninth request cancelled; a queued request held when its turn comes; the polkit sheet keeping the
# keyboard while a gcr request arrives and the reverse; nothing over the lock; held after an unlock and under the screen
# saver; no "ok" for a request that is not on screen with the keyboard; a polkit request never refused by the bound of
# 8; a lost connection; a new password; a confirmation
# with a check box; the caller's text plain; a confirmation never answered by a key before a click past the guard and an
# empty new password never sent by Return (opus review of step 9b, MAJOR-1 and MINOR-1); a restarted bridge's reused id. Then static checks of what offscreen cannot run (the layer namespace, the
# keyboard binding, no lock or shield glyph and no "Authentication required" in the sheets, the same delays as the
# polkit sheet's). No compositor, no bridge, no polkit, no PAM.
# Against the security process (ADR-0041 step 1, S3): both agents run there, beside the lock they read in process
# (qs.security's SheetSession, which the tests set as SecurityHost's Bindings would), with qs.security and qs.lib only.
#
#   tests/security/secret_sheets.sh              the tests: PASS / FAIL
#   tests/security/secret_sheets.sh --mutants    also each mutant below, which the tests must catch ("MUTANT <name>: CAUGHT")
#
# Scratch copies under .dev/ (removed on exit); the working tree is never edited. QMLTESTRUNNER overrides the runner's path.
# Exit 0 PASS, 1 FAIL, 2 environment error; SKIP (exit 0) without qmltestrunner or python3.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
runner=${QMLTESTRUNNER:-/usr/lib/qt6/bin/qmltestrunner}
d=$root/tests/security/secret_sheets.d
pd=$root/tests/security/authagent_flows.d
[[ -x $runner ]] || { echo "SKIP: secret_sheets needs qmltestrunner ($runner)"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: secret_sheets needs python3"; exit 0; }
mutants=0
case ${1:-} in
  "") ;;
  --mutants) mutants=1 ;;
  *) echo "usage: secret_sheets.sh [--mutants]" >&2; exit 2 ;;
esac
mkdir -p "$root/.dev"
scratch=$(mktemp -d "$root/.dev/secret-sheets.XXXXXX") || { echo "ENVIRONMENT: no scratch directory"; exit 2; }
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unset QT_QPA_PLATFORMTHEME
export QT_QPA_PLATFORM=offscreen
fail=0

# qs.lib is the real folder; qs.security the real files but PasswordField.qml, which run() takes from the case under test
# (a mutant may change it: opus review of step 9c, MINOR). No other qs module: the security process's world (ADR-0041 S3).
mkdir -p "$scratch/qsroot/qs/security"
for entry in "$root"/shell/security/* "$root"/shell/security/qmldir; do
  [[ $(basename "$entry") == PasswordField.qml ]] || ln -sf "$entry" "$scratch/qsroot/qs/security/$(basename "$entry")"
done
ln -s "$root/shell/lib" "$scratch/qsroot/qs/lib"

# run <dir with SecretAgent.qml, SecretSheet.qml, SecretSheetModel.qml, Prompter.js, AuthAgent.qml, AuthDialog.qml,
# AuthDialogModel.qml>: generates the harness and runs the tests; 0 when every case passed and no QML runtime error was
# printed.
run() {
  local src=$1 case_dir=$scratch/run out
  rm -rf "$case_dir"
  mkdir -p "$case_dir/secret" "$case_dir/polkit"
  python3 -I "$d/make_harness.py" "$src/SecretAgent.qml" "$case_dir/secret/AgentUnderTest.qml" || return 1
  python3 -I "$pd/make_harness.py" "$src/AuthAgent.qml" "$case_dir/polkit/AgentUnderTest.qml" || return 1
  cp "$src/SecretSheet.qml" "$src/SecretSheetModel.qml" "$src/Prompter.js" "$case_dir/secret/"
  sed 's#^import "../../../shell/security/secret/Prompter.js" as Prompter$#import "Prompter.js" as Prompter#' "$d/FakeClient.qml" >"$case_dir/secret/FakeClient.qml"
  cp "$src/AuthDialog.qml" "$src/AuthDialogModel.qml" "$case_dir/polkit/"
  cp "$src/PasswordField.qml" "$scratch/qsroot/qs/security/PasswordField.qml"
  cp "$d/sheets.qml" "$case_dir/tst_sheets.qml"
  # The model's unit test against the same (possibly mutated) model.
  sed 's#^import "../../shell/security/secret"$#import "secret"#' "$root/tests/security/tst_secretsheetmodel.qml" >"$case_dir/tst_secretsheetmodel.qml"
  out=$(cd "$case_dir" && "$runner" -import "$root/ui" -import "$scratch/qsroot" -input . 2>&1)
  echo "$out"
  ! grep -q '^FAIL' <<<"$out" && grep -qE '^Totals: [0-9]+ passed, 0 failed' <<<"$out" &&
    ! grep -qE '^QWARN.*(TypeError|ReferenceError|Binding loop|Unable to assign|is not a function|is not a constructor)' <<<"$out"
}

real=$scratch/real
mkdir -p "$real"
cp "$root"/shell/security/secret/{SecretAgent.qml,SecretSheet.qml,SecretSheetModel.qml,Prompter.js} "$root"/shell/security/polkit/{AuthAgent.qml,AuthDialog.qml,AuthDialogModel.qml} "$root"/shell/security/PasswordField.qml "$real/"
out=$(run "$real")
rc=$?
grep -E '^(PASS|FAIL|Totals)' <<<"$out" | grep -vE '^PASS   : qmltestrunner::[A-Za-z]+::(initTestCase|cleanupTestCase)\(\)'
if ((rc != 0)); then
  grep -E '^(QWARN|QDEBUG|   Loc|   Actual|   Expected)|error|Error' <<<"$out" | head -40
  echo "FAIL: secret_sheets"
  fail=1
fi

# --- static: what offscreen cannot run ------------------------------------------------------------------------------
static=$(python3 -I - "$root" <<'PY'
import re, sys
root = sys.argv[1]
def read(p):
    return open(f"{root}/{p}", encoding="utf-8").read()
def code(t):
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    return "\n".join(l.split("//", 1)[0] for l in t.split("\n"))
agent = code(read("shell/security/secret/SecretAgent.qml"))
sheet = code(read("shell/security/secret/SecretSheet.qml"))
model = code(read("shell/security/secret/SecretSheetModel.qml"))
polkit_model = code(read("shell/security/polkit/AuthDialogModel.qml"))
host = code(read("shell/security/host/SheetHost.qml"))
security_host = code(read("shell/security/host/SecurityHost.qml"))
checks = []
def expect(what, ok):
    checks.append(("OK " if ok else "PROBLEM ") + what)
expect("the secret sheet's layer namespace is grassfield-secret", re.search(r'WlrLayershell\.namespace:\s*"grassfield-secret"\s*\n', agent) is not None)
expect("the compositor's keyboard follows takesKeys only (Exclusive, else None), as the polkit sheet's",
       re.search(r"keyboardFocus:\s*win\.takesKeys\s*\?\s*WlrKeyboardFocus\.Exclusive\s*:\s*WlrKeyboardFocus\.None\s*\n", agent) is not None
       and re.search(r"property bool takesKeys:\s*!SheetSession\.locked\s*&&\s*\(\(root\.requestOpen\s*&&\s*\(!root\.heldByLock\s*\|\|\s*root\.userFocused\)\)\s*\|\|\s*root\.sinkingKeys\)\s*\n", agent) is not None
       and re.search(r"\bvisible:\s*!SheetSession\.locked\s*&&\s*\(root\.requestOpen\s*\|\|\s*root\.sinkingKeys\)\s*\n", agent) is not None)
expect("the overlay layer, as the polkit sheet", re.search(r"WlrLayershell\.layer:\s*WlrLayer\.Overlay\s*\n", agent) is not None)
glyphs = re.findall(r'"([a-z-]+)"', re.search(r"property string glyph:[^\n]*", model).group(0)) if re.search(r"property string glyph:", model) else []
expect("the requester glyphs are never a lock or a shield (" + ", ".join(glyphs) + ")", glyphs != [] and not any(g in ("lock", "lock-fill", "shield") for g in glyphs))
expect("no lock or shield glyph and no \"Authentication required\" in the secret sheets",
       not re.search(r'name:\s*"(lock|lock-fill|shield)"', sheet + agent) and "Authentication required" not in read("shell/security/secret/SecretSheet.qml") + read("shell/security/secret/SecretAgent.qml") + read("shell/security/secret/SecretSheetModel.qml"))
expect("every text of the sheet and the agent is plain text", sheet.count("Text {") == sheet.count("textFormat: Text.PlainText") and agent.count("Text {") == agent.count("textFormat: Text.PlainText"))
expect("the caller's button labels are never shown (continueLabel and cancelLabel are not read)", "continueLabel" not in sheet + model + agent and "cancelLabel" not in sheet + model + agent)
for name in ("heldGuardMs", "heldAfterUnlockMs", "sinkLingerMaxMs"):
    a = re.search(r"readonly property int " + name + r":\s*(\d+)", model)
    b = re.search(r"readonly property int " + name + r":\s*(\d+)", polkit_model)
    expect(f"{name} equals the polkit sheet's", a is not None and b is not None and a.group(1) == b.group(1))
expect("the password fields tell the input method they hold a secret (PasswordField); the one plain field is a server's name (a network's username is read-only text)",
       sheet.count("PasswordField {") == 3 and "TextInput" not in sheet and sheet.count("TextField {") == 1
       and re.search(r'TextField \{\s*id: nameField\s*objectName: "secretName"\s*visible: root\.model\.asksName\s*\n', sheet) is not None)
expect("Show password reveals a network's password field only (the secret sheet's one reveal), never copyable",
       sheet.count("reveal:") == 1 and re.search(r"reveal:\s*root\.model\.network\s*&&\s*root\.model\.showPassword\s*\n", sheet) is not None
       and re.search(r"copyable:\s*false\s*\n", sheet) is not None)
expect("a NetworkManager request is always held (decision 9-28)",
       re.search(r"root\.heldByLock = sheetModel\.active && \(typing \|\| waited \|\| confirm \|\| network \|\|", agent) is not None)
expect("a KIO request is always held (decision 9-38)",
       re.search(r"root\.heldByLock = sheetModel\.active && \(typing \|\| waited \|\| confirm \|\| network \|\| server \|\|", agent) is not None
       and re.search(r'const server = sheetModel\.active && sheetModel\.request\.kind === "kio";', agent) is not None)
expect("a Bluetooth pairing step is always held (decision 10-7)",
       re.search(r"root\.heldByLock = sheetModel\.active && \(typing \|\| waited \|\| confirm \|\| network \|\| server \|\| pairing \|\|", agent) is not None
       and re.search(r'const pairing = sheetModel\.active && sheetModel\.request\.kind === "bluetooth";', agent) is not None)
expect("a Bluetooth code shown has no OK, only Cancel (decision 10-6)",
       re.search(r"visible:\s*!root\.model\.displaysCode\s*\n", sheet) is not None
       and re.search(r'if \(mode === "display-pin" \|\| mode === "display-passkey"\)\s*\n\s*return "";', code(read("shell/security/secret/Prompter.js"))) is not None)
expect("the security process's sheets (SheetHost.qml) wire one SheetQueue to both agents and the polkit sheet's place (ADR-0041 S3)",
       re.search(r"SheetQueue\s*\{\s*id:\s*sheetQueue\s*polkitPresent:\s*authAgent\.queuePresent\s*\}", host) is not None
       and re.search(r"AuthAgent\s*\{\s*id:\s*authAgent\s*queue:\s*sheetQueue\b", host) is not None
       and re.search(r"SecretAgent\s*\{\s*id:\s*secretAgent\s*queue:\s*sheetQueue\b", host) is not None)
expect("the published authorizing covers the secret sheets (the UI's clipboard history records nothing meanwhile)",
       re.search(r"readonly property bool authorizing:\s*authAgent\.requestActive\s*\|\|\s*secretAgent\.requestActive\s*\n", host) is not None
       and re.search(r'target:\s*Lock\s*property:\s*"authorizing"\s*value:\s*root\.sheets\s*!==\s*null\s*&&\s*root\.sheets\.authorizing\s*===\s*true\s*\}', read("shell/security/host/SecurityHost.qml")) is not None)
polkit = code(read("shell/security/polkit/AuthAgent.qml"))
expect("the polkit agent is handed no request while a secret sheet came first",
       re.search(r"flow:\s*agent\.isActive\s*&&\s*!root\.waiting\s*\?\s*agent\.flow\s*:\s*null", polkit) is not None
       and re.search(r"property bool waiting:\s*root\.queue\s*!==\s*null\s*&&\s*root\.queue\.polkitWaits\s*\n", polkit) is not None)
for c in checks:
    print(c)
PY
)
while IFS= read -r line; do
  case $line in
    "OK "*) echo "PASS: secret sheets static: ${line#OK }" ;;
    "PROBLEM "*) echo "FAIL: secret sheets static: ${line#PROBLEM }"; fail=1 ;;
    *) [[ -n $line ]] && { echo "FAIL: secret sheets static checker: $line"; fail=1; } ;;
  esac
done <<<"$static"

((fail == 0)) || { echo "FAIL: secret_sheets"; exit 1; }
((mutants)) || { echo "PASS: secret_sheets"; exit 0; }

# Each mutant removes a guard: its name, then triples of a file, a text that must occur in it once and what replaces it
# ('#'-separated, \n a newline). The tests must fail on every one (the harness or the model's unit test, run beside it).
# Not listed: the sheet's input disabled while the sink has the keys (`inputEnabled`, AuthAgent's guard, kept): no request
# reaches this sheet while the sink has the keys (the queue holds the next one until a linger ends), so removing it changes
# nothing the tests can see.
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
queue-ignored (the secret sheet shows any request)#SecretAgent.qml#        const head = root.queue.secretHead;#        const head = Object.keys(root.requests)[0] || "";
polkit-not-gated (the polkit sheet takes a request while a secret sheet is on screen)#AuthAgent.qml#flow: agent.isActive && !root.waiting ? agent.flow : null#flow: agent.isActive ? agent.flow : null
polkit-not-held-after-a-secret-sheet#AuthAgent.qml#            if (kind === "secret")\n                dialogModel.noteEnded();#            if (kind === "nothing")\n                dialogModel.noteEnded();
secret-not-held-after-the-polkit-sheet#SecretAgent.qml#            if (kind === "polkit")\n                sheetModel.noteEnded();#            if (kind === "nothing")\n                sheetModel.noteEnded();
waited-not-held#SecretAgent.qml#        request.waited = root.queue.secretHead !== request.id;#        request.waited = false;
ok-without-the-keyboard#SecretAgent.qml#(ok && !(win.shown && win.takesKeys && !root.sinkingKeys))#(ok && !win.shown)
ok-behind-the-lock#SecretAgent.qml#(ok && !(win.shown && win.takesKeys && !root.sinkingKeys))#(false)
no-bound-of-eight#SecretAgent.qml#root.requestCount >= Prompter.MAX_REQUESTS#root.requestCount >= 99
queued-withdrawal-stays#SecretAgent.qml#        else if (id !== root.shownId && root.queue !== null)\n            root.queue.removeSecret(id);#        else if (id !== root.shownId && root.queue !== null)\n            ;
no-linger-after-a-password (the polkit rule)#SecretAgent.qml#const typing = root.sinkingKeys || (!sheetModel.active && win.takesKeys && !(answered && root.answeredKeysBack));#const typing = root.sinkingKeys || (!sheetModel.active && win.takesKeys && !answered);
linger-after-a-cancel#SecretAgent.qml#const typing = root.sinkingKeys || (!sheetModel.active && win.takesKeys && !(answered && root.answeredKeysBack));#const typing = root.sinkingKeys || (!sheetModel.active && win.takesKeys);
no-linger#SecretAgent.qml#const typing = root.sinkingKeys || (!sheetModel.active && win.takesKeys && !(answered && root.answeredKeysBack));#const typing = false;
released-during-the-linger#SecretAgent.qml#        if (sheetModel.active || root.sinkingKeys || root.shownId === "")#        if (sheetModel.active || root.shownId === "")
shown-over-the-lock#SecretAgent.qml#readonly property bool shown: sheetModel.active && !SheetSession.locked#readonly property bool shown: sheetModel.active#SecretAgent.qml#visible: !SheetSession.locked && (root.requestOpen || root.sinkingKeys)#visible: (root.requestOpen || root.sinkingKeys)
no-click-guard#SecretAgent.qml#                if (!sheetModel.heldClickAccepted())\n                    return;#                ;
no-unlock-hold#SecretSheetModel.qml#return locked || unlockHold.running || afterRequest.running;#return locked || afterRequest.running;
saver-not-held#SecretAgent.qml#                root.heldByLock = true;\n                root.userFocused = false;\n                sheetModel.clearRequested();#                root.userFocused = false;
answered-twice#SecretSheetModel.qml#    readonly property bool canSubmit: !!request && priv.answeredKey !== keyOf(request)#    readonly property bool canSubmit: !!request
empty-unlock-password-sent#SecretSheetModel.qml#            if (typeof password !== "string" || (password.length === 0 && !passwordNew)) {#            if (typeof password !== "string") {#SecretSheet.qml#            id: field\n            objectName: "secretField"#            id: field\n            allowEmpty: true\n            objectName: "secretField"
new-passwords-not-compared#SecretSheetModel.qml#            if (passwordNew && password !== verify) {#            if (false) {
caller-title-as-the-sheet-title#SecretSheetModel.qml#    readonly property string title: server ? serverTitleOf(nameMode, serverName) : network ? networkTitleOf(networkSecurity, networkSsid) : pairing ? qsTr("Connection Request from “%1”").arg(deviceName) : titleOf(role, requesterName, kind, passwordNew)#    readonly property string title: request ? request.texts.title : ""
caller-labels-on-the-buttons#SecretSheet.qml#            text: root.model.network ? qsTr("Join") : root.model.server || root.model.pairing ? qsTr("Connect") : qsTr("OK")#            text: root.model.request && root.model.request.texts.continueLabel !== "" ? root.model.request.texts.continueLabel : qsTr("OK")
confirm-not-held (MAJOR-1 of the opus review)#SecretAgent.qml#        root.heldByLock = sheetModel.active && (typing || waited || confirm || network || server || pairing || sheetModel.arrivesHeld(#        root.heldByLock = sheetModel.active && (typing || waited || network || server || pairing || sheetModel.arrivesHeld(
network-not-held (decision 9-28)#SecretAgent.qml#        root.heldByLock = sheetModel.active && (typing || waited || confirm || network || server || pairing || sheetModel.arrivesHeld(#        root.heldByLock = sheetModel.active && (typing || waited || confirm || server || pairing || sheetModel.arrivesHeld(
server-not-held (decision 9-38)#SecretAgent.qml#        root.heldByLock = sheetModel.active && (typing || waited || confirm || network || server || pairing || sheetModel.arrivesHeld(#        root.heldByLock = sheetModel.active && (typing || waited || confirm || network || pairing || sheetModel.arrivesHeld(
pairing-not-held (decision 10-7)#SecretAgent.qml#        root.heldByLock = sheetModel.active && (typing || waited || confirm || network || server || pairing || sheetModel.arrivesHeld(#        root.heldByLock = sheetModel.active && (typing || waited || confirm || network || server || sheetModel.arrivesHeld(
pairing-progress-not-shown (decision 10-8)#SecretAgent.qml#        if (sheetModel.active && sheetModel.id === id)\n            sheetModel.entered = entered;#        if (sheetModel.active && sheetModel.id === id)\n            ;
pairing-progress-takes-the-keyboard (decision 10-8)#SecretAgent.qml#        if (sheetModel.active && sheetModel.id === id)\n            sheetModel.entered = entered;#        if (sheetModel.active && sheetModel.id === id) {\n            sheetModel.entered = entered;\n            root.userFocused = true;\n        }
pairing-progress-arrives-again (decision 10-8)#SecretAgent.qml#        if (sheetModel.active && sheetModel.id === id)\n            sheetModel.entered = entered;#        if (sheetModel.active && sheetModel.id === id)\n            sheetModel.request = Object.assign({}, request);
pairing-queued-count-lost#SecretAgent.qml#        request.pairing.entered = entered;#        ;
pairing-display-has-ok (decision 10-6)#SecretSheet.qml#            visible: !root.model.displaysCode#            visible: true
pairing-display-answered-ok (decision 10-6)#SecretSheetModel.qml#            if (displaysCode) {#            if (false) {
pairing-code-form-not-checked#SecretSheetModel.qml#            if (asksCode && !Prompter.pairingCodeOk(pairingMode, password)) {#            if (false) {
pairing-connect-ignores-the-length#SecretSheet.qml#                if (root.model.pairingReady(field.length))\n                    field.submit();#                field.submit();
pairing-name-as-rich-text#SecretSheet.qml#            objectName: "secretTitle"\n            width: parent.width\n            textFormat: Text.PlainText#            objectName: "secretTitle"\n            width: parent.width\n            textFormat: Text.RichText
connect-without-a-name#SecretSheetModel.qml#        return server && canSubmit && passwordLength > 0 && (nameMode !== "edit" || nameLength > 0);#        return server && canSubmit && passwordLength > 0;#SecretSheetModel.qml#            if (nameMode === "edit" && root.loginName === "") {#            if (false) {
server-name-dropped#SecretSheetModel.qml#nameMode === "edit" ? root.loginName : null#null
remember-state-ignored#SecretSheetModel.qml#            root.choice = request.kind === "kio" ? request.login.remember === "on" : request.choice !== null && request.choice.chosen === true;#            root.choice = request.kind === "kio" ? false : request.choice !== null && request.choice.chosen === true;
remember-not-sent#Prompter.js#            if (login.remember === "off" || login.remember === "on")\n                m.choice = choice === true;#            if (false)\n                m.choice = choice === true;
keyring-notice-missing#SecretSheetModel.qml#request.login.keyring === "unprotected" ? qsTr(#request.login.keyring === "never" ? qsTr(
fixed-name-editable#SecretSheet.qml#            readOnly: !visible || !enabled || root.model.nameReadOnly#            readOnly: !visible || !enabled
retry-not-said#SecretSheetModel.qml#request.login.retry === true ? qsTr("The name or password was not accepted. Try again.") : "";#false ? qsTr("The name or password was not accepted. Try again.") : "";
server-free-text-accepted#Prompter.js#    if (typeof m.server !== "string" || m.server.length > CAPS.server || !SERVER_PATTERN.test(m.server))#    if (typeof m.server !== "string" || m.server.length > CAPS.server)
network-password-always-shown#SecretSheet.qml#            reveal: root.model.network && root.model.showPassword#            reveal: root.model.network
show-password-not-reset#SecretSheetModel.qml#    onClearRequested: root.showPassword = false#    onClearRequested: {}
join-ignores-the-length#SecretSheet.qml#            if (root.model.networkReady(field.length))\n                field.submit();#            field.submit();#SecretSheet.qml#            enabled: root.model.canSubmit && (root.model.network ? root.model.networkReady(field.length) : !root.model.server || root.model.serverReady(field.length, nameField.text.length))#            enabled: root.model.canSubmit#SecretSheetModel.qml#            if (!Prompter.networkLengthOk(networkSecurity, password.length)) {#            if (false) {
refusal-as-cancel (opus review of step 9c, NIT)#SecretAgent.qml#            client.refuse(request.id);#            client.answer(request.id, false, null, false, null);
shown-password-copyable (opus review of step 9c, MINOR)#SecretSheet.qml#            copyable: false#            copyable: true
password-field-guard-off (opus review of step 9c, MINOR)#PasswordField.qml#    readonly property bool guarded: root.reveal && !root.copyable#    readonly property bool guarded: false
empty-new-password-by-return (MINOR-1)#SecretSheet.qml#        if (!fromButton && first === "" && second === "")\n            return;#        if (false)\n            return;
return-in-new-submits (MINOR-1)#SecretSheet.qml#            submitOnReturn: false#            submitOnReturn: true
answer-kept-across-requests (a restarted bridge's p1)#SecretAgent.qml#        root.answeredId = "";#        ;
rich-caller-text#SecretSheet.qml#                        objectName: "secretCaller_" + modelData.key\n                        width: callerColumn.width\n                        visible: text !== ""\n                        textFormat: Text.PlainText#                        objectName: "secretCaller_" + modelData.key\n                        width: callerColumn.width\n                        visible: text !== ""\n                        textFormat: Text.RichText
EOF_MUTANTS
((status == 0)) && echo "PASS: secret_sheets (and every mutant caught)" || echo "FAIL: secret_sheets mutants"
exit "$status"
