#!/usr/bin/env bash
# GF-AUDIT-001 SEC-01 / GF-028: the Grassfield session hides from screen sharing and screencopy every window Omarchy
# hides (`no_screen_share` rules of /usr/share/omarchy/default/hypr/apps/*.lua: 1Password, Bitwarden, ...), by reading
# Omarchy's own rule files (config/hypr/grassfield/privacy.lua). Evaluates privacy.lua with plain `lua` (the Lua 5.5 of
# Hyprland 0.56) and a recording `hl`:
#   omarchy    the installed Omarchy: at least one Grassfield rule per `no_screen_share = true` in Omarchy's files
#              (counted by grep, an independent oracle), the three known password-manager matches among them (SKIP
#              without Omarchy)
#   fixture    a fake Omarchy tree: a new protected app is picked up, table matches kept, other rules ignored, a file
#              that calls os/io stops there without running anything (no marker file), a broken file is skipped; the
#              built-in matches are added anyway, so a 1password.lua that stops before its rule still protects 1Password
#   builtin    no Omarchy rule readable: the built-in password-manager matches apply
#   wiring     core.lua (loaded by session.lua and dev.lua) requires grassfield.privacy
#   layers     the shell's password sheets and authorization sheet (ADR-0035 D-9, step 9b): one layer rule each, with
#              no_screen_share, whose namespace regex matches exactly the namespace the shell gives that sheet
#              (shell/security/secret/SecretAgent.qml grassfield-secret, shell/security/polkit/AuthAgent.qml
#              grassfield-polkit), applied whatever Omarchy holds; a copy without one rule fails the check
# The nested proof (a window with app_id Bitwarden is black in a capture) is tests/security/lock_privacy.sh `screenshare`.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
fail=0
pass() { echo "PASS: screenshare $*"; }
bad() { echo "FAIL: screenshare $*"; fail=1; }
if ! command -v lua >/dev/null; then
  echo "SKIP: screenshare rules (lua not installed)"
  exit 0
fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/screenshare.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Prints "source <omarchy|builtin>", one line per applied window rule: "<name>|<no_screen_share>|<sorted match>", and one per
# layer rule: "layer <name>|<no_screen_share>|<namespace>|<number of match keys>".
cat >"$tmp/run.lua" <<'LUA'
local applied = {}
local layers = {}
hl = { window_rule = function(rule) applied[#applied + 1] = rule end, layer_rule = function(rule) layers[#layers + 1] = rule end }
local M = dofile(arg[1])
print("source " .. M.source)
for _, rule in ipairs(layers) do
  local n = 0
  for _ in pairs(rule.match) do n = n + 1 end
  print("layer " .. tostring(rule.name) .. "|" .. tostring(rule.no_screen_share) .. "|" .. tostring(rule.match.namespace) .. "|" .. n)
end
for _, rule in ipairs(applied) do
  local keys = {}
  for k in pairs(rule.match) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(rule.match[k]) end
  print(rule.name .. "|" .. tostring(rule.no_screen_share) .. "|" .. table.concat(parts, ";"))
end
LUA
run() { # <OMARCHY_PATH> [env...]: evaluates privacy.lua there (its prints go to stdout too), the shell's list from this tree
  local om=$1
  shift
  (cd "$tmp" && env -u GRASSFIELD_SESSION OMARCHY_PATH="$om" GRASSFIELD_DEV=1 GRASSFIELD_SHELL_DIR="$root/shell" "$@" lua "$tmp/run.lua" "$root/config/hypr/grassfield/privacy.lua")
}

# The password managers always applied: the lines of the shell's protected-classes.txt, the ONE list the clipboard also reads
# (R7-SEC-03), as run.lua prints them.
builtin=()
while IFS= read -r line; do
  [[ -z ${line//[[:space:]]/} || $line == \#* ]] || builtin+=("class=$line")
done <"$root/shell/services/protected-classes.txt"
((${#builtin[@]} == 3)) && pass "the one list: protected-classes.txt holds the 3 password-manager matches" || bad "protected-classes.txt: ${#builtin[@]} lines"

# --- omarchy: the installed rule set ---
apps=/usr/share/omarchy/default/hypr/apps
if [[ -d $apps ]]; then
  out=$(run /usr/share/omarchy)
  want=$(cat "$apps"/*.lua | grep -c 'no_screen_share = true' || true)
  got=$(grep -c '^gf-no-screen-share-[0-9]*|true|' <<<"$out" || true)
  [[ $out == *"source omarchy"* ]] && pass "omarchy: rules read from Omarchy's files" || bad "omarchy: source is not Omarchy: $out"
  ((want > 0 && got >= want)) && pass "omarchy: $got rules for $want no_screen_share rules in $apps (built-in ones merged)" || bad "omarchy: $got rules, Omarchy has $want"
  for m in "${builtin[@]}"; do
    grep -qF "|true|$m" <<<"$out" && pass "omarchy: protected $m" || bad "omarchy: $m is not protected"
  done
  # R7-SEC-03: the built-in list is the installed Omarchy's, so that the clipboard history (which takes the built-in list,
  # shell/services/ClipboardLogic.js, tests/unit/tst_clipboard.qml) skips every password manager screen sharing hides. A
  # match Omarchy adds is printed: add it to privacy.lua's BUILTIN and to PROTECTED_CLASSES (a class regex), or decide.
  extra=$(grep '^gf-no-screen-share-[0-9]*|true|' <<<"$out" | sed 's/^[^|]*|true|//' | while IFS= read -r m; do
    printf '%s\n' "${builtin[@]}" | grep -qxF -- "$m" || printf '%s\n' "$m"
  done)
  [[ -z $extra ]] && pass "omarchy: every window the installed Omarchy hides from screen sharing is in the built-in list (the clipboard's)" \
    || bad "omarchy: the built-in list (and the clipboard's) misses Omarchy's: $(tr '\n' ' ' <<<"$extra")"
else
  echo "SKIP: screenshare omarchy: $apps not installed (fixture and fallback cases still run)"
fi

# --- fixture: a fake Omarchy tree ---
mkdir -p "$tmp/om/default/hypr/apps"
cat >"$tmp/om/default/hypr/apps/a-vault.lua" <<'LUA'
o.window("^(NewVault)$", { no_screen_share = true, tag = "+floating-window" })
o.window({ class = "^Keep$", title = "^Secret$" }, { no_screen_share = true })
o.window("^Other$", { float = true, tile = true })
hl.layer_rule({ match = { namespace = "x" }, no_anim = true })
o.bind("SUPER + X", "Something", "touch never")
LUA
cat >"$tmp/om/default/hypr/apps/b-evil.lua" <<'LUA'
o.window("^(Evil)$", { no_screen_share = true })
os.execute("touch marker-os")
o.window("^(AfterEvil)$", { no_screen_share = true })
LUA
cat >"$tmp/om/default/hypr/apps/c-io.lua" <<'LUA'
local f = io.open("marker-io", "w")
o.window("^(AfterIo)$", { no_screen_share = true })
LUA
printf 'o.window("^(Broken)$", { no_screen_share = true \n' >"$tmp/om/default/hypr/apps/d-broken.lua"
cat >"$tmp/om/default/hypr/apps/e-require.lua" <<'LUA'
require("os")
o.window("^(AfterRequire)$", { no_screen_share = true })
LUA
out=$(run "$tmp/om")
[[ $out == *"source omarchy"* ]] && pass "fixture: rules read from the fixture" || bad "fixture: source: $out"
grep -qF '|true|class=^(NewVault)$' <<<"$out" && pass "fixture: a new protected app is picked up" || bad "fixture: NewVault missing"
grep -qF '|true|class=^Keep$;title=^Secret$' <<<"$out" && pass "fixture: a table match is kept whole" || bad "fixture: table match missing"
grep -qF '|true|class=^(Evil)$' <<<"$out" && pass "fixture: rules before a stop still count" || bad "fixture: Evil missing"
if grep -qE 'Other|AfterEvil|AfterIo|Broken|AfterRequire' <<<"$(grep '^gf-no-screen-share' <<<"$out")"; then
  bad "fixture: a rule that is not no_screen_share, or one after a stop, was applied"
else
  pass "fixture: only no_screen_share rules up to a stop"
fi
n=$(grep -c '^gf-no-screen-share-' <<<"$out" || true)
((n == 6)) && pass "fixture: exactly 6 rules (3 read, 3 built-in)" || bad "fixture: $n rules"
for m in "${builtin[@]}"; do
  grep -qF "|true|$m" <<<"$out" && pass "fixture: built-in $m applied although the tree does not declare it" || bad "fixture: built-in $m missing"
done
[[ ! -e $tmp/marker-os && ! -e $tmp/marker-io ]] && pass "fixture: os/io calls of an Omarchy file never ran" || bad "fixture: a marker file was created"
grep -q 'stopped reading .*b-evil.lua' <<<"$out" && grep -q 'stopped reading .*d-broken.lua' <<<"$out" \
  && pass "fixture: stops are reported" || bad "fixture: stops not reported: $out"

# --- a 1password.lua that stops before its rule (reviewer note b): 1Password stays protected ---
mkdir -p "$tmp/om2/default/hypr/apps"
printf 'os.execute("touch marker-1p")\no.window("^(1[pP]assword|com\\\\.onepassword\\\\.OnePassword)$", { no_screen_share = true })\n' >"$tmp/om2/default/hypr/apps/1password.lua"
printf 'o.window("^([bB]itwarden)$", { no_screen_share = true })\n' >"$tmp/om2/default/hypr/apps/bitwarden.lua"
out=$(run "$tmp/om2")
grep -qF "|true|${builtin[0]}" <<<"$out" && [[ ! -e $tmp/marker-1p ]] \
  && pass "stopped file: 1Password still protected by the built-in match, nothing of the file ran" || bad "stopped file: 1Password unprotected: $out"
n=$(grep -c '^gf-no-screen-share-' <<<"$out" || true)
((n == 3)) && pass "stopped file: no duplicate rules (3)" || bad "stopped file: $n rules"

# --- builtin: nothing readable ---
out=$(run "$tmp/none")
[[ $out == *"source builtin"* ]] && pass "builtin: reported when no Omarchy rule can be read" || bad "builtin: source: $out"
for m in "${builtin[@]}"; do
  grep -qF "|true|$m" <<<"$out" && pass "builtin: protected $m" || bad "builtin: $m missing"
done

# --- layers: the shell's sheets (ADR-0035 D-9, step 9b) ---
cat >"$tmp/layers.py" <<'PY'
import re, sys
out, root = sys.stdin.read(), sys.argv[1]
rules = [l[len("layer "):].split("|") for l in out.split("\n") if l.startswith("layer ")]
def namespace_of(path):
    m = re.search(r'WlrLayershell\.namespace:\s*"([^"]+)"', open(f"{root}/{path}", encoding="utf-8").read())
    return m.group(1) if m else None
want = [namespace_of("shell/security/secret/SecretAgent.qml"), namespace_of("shell/security/polkit/AuthAgent.qml")]
ok = want == ["grassfield-secret", "grassfield-polkit"] and len(rules) == 2
for ns in want:
    hits = [r for r in rules if r[1] == "true" and r[3] == "1" and re.fullmatch(r[2], ns or "")
            and not re.fullmatch(r[2], (ns or "") + "x") and not re.fullmatch(r[2], "x" + (ns or ""))]
    ok = ok and len(hits) == 1
print("ok" if ok else "bad " + repr(rules) + " " + repr(want))
PY
for om in /usr/share/omarchy "$tmp/om" "$tmp/none"; do
  r=$(run "$om" | python3 -I "$tmp/layers.py" "$root")
  [[ $r == ok ]] && pass "layers ($om): the secret and polkit sheets' layers are hidden from screen sharing" || bad "layers ($om): $r"
done
sed 's/^hl\.layer_rule({ name = "gf-no-screen-share-secret".*$//' "$root/config/hypr/grassfield/privacy.lua" >"$tmp/privacy-mutant.lua"
r=$(cd "$tmp" && env -u GRASSFIELD_SESSION OMARCHY_PATH="$tmp/none" GRASSFIELD_DEV=1 GRASSFIELD_SHELL_DIR="$root/shell" lua "$tmp/run.lua" "$tmp/privacy-mutant.lua" | python3 -I "$tmp/layers.py" "$root")
[[ $r != ok ]] && pass "layers: mutation: a copy without the secret sheet's rule fails the check" || bad "layers: mutation not caught"

# --- the one list (R7-SEC-03): read from the shell's file, found as bindings.lua finds the shell ---
mkdir -p "$tmp/othershell/services"
printf '# a test list\n^(MarkerVault)$\n' >"$tmp/othershell/services/protected-classes.txt"
out=$(run "$tmp/none" GRASSFIELD_SHELL_DIR="$tmp/othershell")
grep -qF '|true|class=^(MarkerVault)$' <<<"$out" && ! grep -qF 'nngceck' <<<"$out" \
  && pass "one list: a dev session's GRASSFIELD_SHELL_DIR gives the list privacy.lua applies (no copy of it in privacy.lua)" || bad "one list: dev shell dir: $out"
out=$(run "$tmp/none" GRASSFIELD_SHELL_DIR="$tmp/othershell" GRASSFIELD_SESSION=1)
! grep -qF 'MarkerVault' <<<"$out" \
  && pass "one list: a real session ignores GRASSFIELD_SHELL_DIR (the installed shell's file)" || bad "one list: the session read a dev list: $out"
out=$(run "$tmp/om" GRASSFIELD_SHELL_DIR="$tmp/nowhere")
fallback_ok=1
for m in "${builtin[@]}"; do grep -qF "|true|$m" <<<"$out" || fallback_ok=0; done
grep -q "WARNING: no password-manager class read from $tmp/nowhere/services/protected-classes.txt; the built-in fallback list applies" <<<"$out" \
  && grep -qF '|true|class=^(NewVault)$' <<<"$out" && ((fallback_ok)) \
  && pass "one list unreadable: a warning, the built-in fallback (the file's matches) and Omarchy's own rules applied" || bad "one list unreadable: $out"
out=$(run "$tmp/none" GRASSFIELD_SHELL_DIR="$tmp/nowhere")
fallback_ok=1
for m in "${builtin[@]}"; do grep -qF "|true|$m" <<<"$out" || fallback_ok=0; done
((fallback_ok)) && [[ $out == *"source builtin"* ]] \
  && pass "neither the list nor Omarchy's rules readable: the fallback still hides the password managers" || bad "nothing readable: $out"

# --- wiring: both sessions load it ---
grep -qx 'require("grassfield.privacy")' config/hypr/grassfield/core.lua && pass "wiring: core.lua requires grassfield.privacy" || bad "wiring: core.lua"
grep -q 'require("grassfield.core")' config/hypr/session.lua && grep -q 'require("grassfield.core")' config/hypr/dev.lua \
  && pass "wiring: session.lua and dev.lua load core.lua" || bad "wiring: a session does not load core.lua"
exit $fail
