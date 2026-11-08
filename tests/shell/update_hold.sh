#!/usr/bin/env bash
# The update hold (ADR-0041 step 2a, SQ-3 option A; docs/specs/updates.md U39): the pair grassfield-hold / grassfield-unhold, offline.
#   1. The bounds the hold's `depends` get from BUILD-DEPS (packaging/arch/hold-bounds.sh): quickshell at its version without
#      its pkgrel, qt6-base at major.minor (>= and < the next minor), an epoch kept, never hyprland or kcoreaddons, and no
#      bound at all (the build fails) for a record that cannot be read; the same rule as the update helper's U27 comparison.
#   2. The root helpers' argument validation: grassfield-hold-helper takes exactly hold or unhold, grassfield-channel-helper exactly
#      set stable|beta, restore, off (each with no extra argument), the scriptlet program neither; the polkit policy gives the hold
#      its own action, a password every time.
#   3. gf_hold_swap (packaging/pacman/grassfield-channel.sh) against a pacman stand-in: its refusals leave pacman's install step
#      unstarted (no [grassfield], already installed, not listed, a plan that is more than the one package, a plan that
#      fails), one transaction with `--ask 4` and the explicit grassfield/<package>, a swap that did not complete.
#   4. grassfield-channel-set: the verbs hold and unhold go to the helper (recording stand-in), hold-state prints held,
#      allowed, allowed-moved or none from pacman -Q and BUILD-DEPS.
#   5. The update helper: pacman's refusal naming the hold is exit 6 (the plan block run with stand-ins: only when pacman failed),
#      and with the twin installed Qt and Quickshell are not compared by U27 (u27_exempt) while the others still are.
# Nothing here touches pacman, polkit or the system: every program is a copy with its paths pointed at a temporary tree, or a
# stand-in on PATH. The real transactions are tests/integration/update_hold.sh (a throwaway container, run bare).
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/update-hold.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
expect() { [[ $2 == "$3" ]] && pass "$1" || fail "$1: got '$2', want '$3'"; }

# shellcheck source=packaging/arch/hold-bounds.sh
. "$root/packaging/arch/hold-bounds.sh"

echo "== 1. the bounds come from BUILD-DEPS"
rec=$tmp/BUILD-DEPS
record() { printf '%b' "$1" >"$rec"; }
depends() { gf_hold_depends "$rec" | tr '\n' ' '; }
record 'qt6-base 6.12.0-1\nquickshell 0.3.2.r7-1\nhyprland 0.56.2-4\naquamarine 0.10.0-1\nkcoreaddons 6.29.0-1\n'
expect "qt6-base at its minor, quickshell without its pkgrel" "$(depends)" "quickshell=0.3.2.r7 qt6-base>=6.12 qt6-base<6.13 "
record 'qt6-base 6.9.3-2\nquickshell 0.3.1-1\n'
expect "the next minor is a number, not a string (6.9 -> 6.10)" "$(depends)" "quickshell=0.3.1 qt6-base>=6.9 qt6-base<6.10 "
record 'qt6-base 6.12.1-1\nquickshell 0.3.2.r7-1\n'
expect "a patch release gives the same bounds as the first" "$(depends)" "quickshell=0.3.2.r7 qt6-base>=6.12 qt6-base<6.13 "
record 'qt6-base 1:6.12.0-1\nquickshell 0.3.2-1\n'
expect "an epoch is kept" "$(depends)" "quickshell=0.3.2 qt6-base>=1:6.12 qt6-base<1:6.13 "
record 'qt6-base 6.12.0-1\nquickshell 0.3.2-1\nhyprland 0.56.2-4\nkcoreaddons 6.29.0-1\n'
case $(depends) in *hyprland* | *kcoreaddons* | *aquamarine*) fail "the hold never bounds hyprland, aquamarine or kcoreaddons" ;; *) pass "the hold never bounds hyprland, aquamarine or kcoreaddons" ;; esac
for bad in 'qt6-base 6.12.0-1\n' 'quickshell 0.3.2-1\n' '' 'qt6-base six\nquickshell 0.3.2-1\n' 'qt6-base 6.12.0-1 extra\nquickshell 0.3.2-1\n' \
  'qt6-base 6.12.0-1\nquickshell 0.3.2>=1\n' 'qt6-base 6.12.0-1\nquickshell <1\n' 'Qt6-base 6.12.0-1\nquickshell 0.3.2-1\n'; do
  record "$bad"
  if gf_hold_depends "$rec" >"$tmp/out" 2>/dev/null; then fail "a record that cannot be bounded gives no bound: '${bad//$'\n'/|}' gave $(tr '\n' ' ' <"$tmp/out")"
  else pass "a record that cannot be bounded gives no bound: '${bad//$'\n'/|}'"; fi
done
if gf_hold_depends "$tmp/missing" >/dev/null 2>&1; then fail "a missing record gives no bound"; else pass "a missing record gives no bound"; fi
ln -s "$rec" "$tmp/link"
if gf_hold_depends "$tmp/link" >/dev/null 2>&1; then fail "a link is not a record"; else pass "a link is not a record"; fi
record 'qt6-base 6.12.0-1\nquickshell 0.3.2.r7-1\n'
allows() { gf_hold_allows "$rec" "$1" "$2" && echo yes || echo no; }
expect "inside the bounds (another pkgrel, another patch)" "$(allows 0.3.2.r7-3 6.12.4-1)" yes
expect "quickshell moved" "$(allows 0.3.2.r8-1 6.12.0-1)" no
expect "qt6-base moved a minor" "$(allows 0.3.2.r7-1 6.13.0-1)" no
expect "qt6-base moved back" "$(allows 0.3.2.r7-1 6.11.2-1)" no
expect "an unreadable installed version" "$(allows '' 6.12.0-1)" no
record ''
expect "an unreadable record allows nothing" "$(allows 0.3.2.r7-1 6.12.0-1)" no
# The same rule as the update helper's compatibility check: the helper's compare_key is the rule the bounds restate.
grep -q 'quickshell) printf' "$root/packaging/pacman/grassfield-update-helper" && pass "U27's quickshell rule (whole version) is still the helper's" || fail "U27's rule moved: restate the hold's bounds"

echo "== 2. the root helpers' arguments"
lib=$tmp/lib.sh
# The helpers replace their environment (they run again under `env -i` when they hold anything), so the stand-in library
# carries the recording file's path itself and they are started with no variable at all.
cat >"$lib" <<SH
gf_start() { :; }
gf_lock() { :; }
gf_require_unlocked() { echo "unlocked-check" >>"$tmp/calls"; }
gf_set() { echo "set \$1" >>"$tmp/calls"; }
gf_restore() { echo restore >>"$tmp/calls"; }
gf_off() { echo off >>"$tmp/calls"; }
gf_hold_swap() { echo "swap \$1" >>"$tmp/calls"; }
SH
sed -e "s#^. /usr/lib/grassfield/grassfield-channel.sh.*#. $lib || exit 1#" "$root/packaging/pacman/grassfield-channel-helper" >"$tmp/helper"
sed -e "s#^. /usr/lib/grassfield/grassfield-channel.sh.*#. $lib || exit 1#" "$root/packaging/pacman/grassfield-hold-helper" >"$tmp/hold-helper"
helper() { : >"$tmp/calls"; out=$(env -i /usr/bin/bash -p "$tmp/helper" "$@" 2>&1); rc=$?; }
hhelper() { : >"$tmp/calls"; out=$(env -i /usr/bin/bash -p "$tmp/hold-helper" "$@" 2>&1); rc=$?; }
calls() { grep -v '^unlocked-check$' "$tmp/calls" | tr '\n' '|'; }
for v in hold unhold; do
  hhelper "$v"; expect "hold helper $v: exit 0" "$rc" 0; expect "  one swap, nothing else" "$(calls)" "swap $v|"
  [[ $(head -n 1 "$tmp/calls") == unlocked-check ]] && pass "  pacman is checked not to be running first" || fail "  $v does not check db.lck first"
done
for args in "" "hold x" "unhold x" "hold unhold" "unhold grassfield-unhold" "Hold" "UNHOLD" "hold-state" "holds" "grassfield-hold" "set hold" "set stable" "restore" "off" \
  "-S grassfield-hold" "install grassfield-unhold" "remove" "upgrade" "--help"; do
  # shellcheck disable=SC2086
  hhelper $args
  expect "hold helper refuses '$args' (exit 2, nothing run)" "$rc:$(calls)" "2:"
done
hhelper ""; expect "hold helper: an empty argument is refused" "$rc:$(calls)" "2:"
hhelper "hold "; expect "hold helper: a trailing space is refused" "$rc:$(calls)" "2:"
hhelper "hold
"; expect "hold helper: a newline is refused" "$rc:$(calls)" "2:"
# The channel helper knows no hold verb, the hold helper no channel verb (one program, one polkit action).
for v in hold unhold; do
  helper "$v"; expect "channel helper refuses $v (exit 2, nothing run)" "$rc:$(calls)" "2:"
done
helper set stable; expect "channel helper: set stable accepted" "$(calls)" "set stable|"
helper set beta; expect "channel helper: set beta accepted" "$(calls)" "set beta|"
helper restore; expect "channel helper: restore accepted" "$(calls)" "restore|"
helper off; expect "channel helper: off accepted" "$(calls)" "off|"
for args in "" "set" "set stable beta" "off now" "restore x" "set hold" "hold-state"; do
  # shellcheck disable=SC2086
  helper $args; expect "channel helper refuses '$args' (exit 2, nothing run)" "$rc:$(calls)" "2:"
done
# The scriptlet program knows no hold verb.
if grep -nE '\b(un)?hold\b' "$root/packaging/pacman/grassfield-channel-scriptlet" >/dev/null; then fail "the scriptlet program names a hold verb"; else pass "the scriptlet program names no hold verb"; fi
grep -n 'gf_hold_swap "\$1"' "$root/packaging/pacman/grassfield-hold-helper" >/dev/null && pass "the hold helper hands gf_hold_swap the verb only" || fail "gf_hold_swap is not called with the verb alone"
# The policy: its own action for the hold helper, a password every time, nothing for an inactive or remote session; the channel
# action keeps its scope and its kept password.
python3 -I - "$root/packaging/pacman/org.grassfield.packages.policy" <<'PY' && pass "polkit: org.grassfield.packages.hold is auth_admin (never kept), its own program; set-channel unchanged" || fail "polkit policy"
import sys, xml.etree.ElementTree as ET
t = ET.parse(sys.argv[1]).getroot()
a = {x.get("id"): x for x in t.findall("action")}
def d(i, k): return a[i].find("defaults").find(k).text
def path(i): return [n.text for n in a[i].findall("annotate") if n.get("key") == "org.freedesktop.policykit.exec.path"][0]
assert d("org.grassfield.packages.hold", "allow_active") == "auth_admin"
assert d("org.grassfield.packages.hold", "allow_inactive") == "no" and d("org.grassfield.packages.hold", "allow_any") == "no"
assert path("org.grassfield.packages.hold") == "/usr/lib/grassfield/grassfield-hold-helper"
assert d("org.grassfield.packages.set-channel", "allow_active") == "auth_admin_keep"
assert path("org.grassfield.packages.set-channel") == "/usr/lib/grassfield/grassfield-channel-helper"
assert len(set(path(i) for i in a)) == len(a), "two actions share a program"
m = [x.text for x in a["org.grassfield.packages.hold"].findall("message") if not x.attrib][0]
assert "not tested" in m and "hold them back" in m
assert "where Grassfield gets its updates" in [x.text for x in a["org.grassfield.packages.set-channel"].findall("message") if not x.attrib][0]
PY

echo "== 3. gf_hold_swap against a pacman stand-in"
mkdir -p "$tmp/bin" "$tmp/st/inst" "$tmp/st/repo" "$tmp/st/rconf" "$tmp/st/qconf" "$tmp/st/reason" "$tmp/st/qprov" "$tmp/st/rprov"
cat >"$tmp/bin/pacman" <<'SH'
#!/bin/bash
# A stand-in: state in $ST (inst/<name> = installed version, repo/<name> = listed in [grassfield] at that version, rconf/<name> and
# qconf/<name> = a "Conflicts With" value of a listed or installed package, reason/<name> = install reason). Records every call.
echo "$*" >>"$ST/calls"
last=${*: -1}
spec=${last#grassfield/}
name=${spec%%=*}
case $1 in
  -Q)
    # As pacman 7.1 does: a package that PROVIDES the name answers too (the twin provides grassfield-hold).
    if [[ $2 == -- ]]; then
      [[ -f $ST/inst/$3 ]] && { echo "$3 $(<"$ST/inst/$3")"; exit 0; }
      [[ $3 == grassfield-hold && -f $ST/inst/grassfield-unhold ]] && { echo "grassfield-unhold $(<"$ST/inst/grassfield-unhold")"; exit 0; }
      exit 1
    fi ;;
esac
case $1 in
  -Qq) ls "$ST/inst" ;;
  -Qi)
    for f in "$ST/inst"/*; do
      n=${f##*/}
      printf 'Name            : %s\nVersion         : %s\nProvides        : %s\nConflicts With  : %s\n\n' "$n" "$(<"$f")" "$([[ -f $ST/qprov/$n ]] && cat "$ST/qprov/$n" || echo None)" "$([[ -f $ST/qconf/$n ]] && cat "$ST/qconf/$n" || echo None)"
    done ;;
  -Si)
    [[ $last == grassfield/* && -f $ST/repo/$name ]] || exit 1
    printf 'Repository      : grassfield\nName            : %s\nVersion         : %s\nProvides        : %s\nConflicts With  : %s\n\n' "$name" "$(<"$ST/repo/$name")" "$([[ -f $ST/rprov/$name ]] && cat "$ST/rprov/$name" || echo None)" "$([[ -f $ST/rconf/$name ]] && cat "$ST/rconf/$name" || echo None)" ;;
  -S)
    [[ $last == grassfield/*=* ]] || exit 1
    [[ $spec == "$name=$(<"$ST/repo/$name")" ]] || exit 1
    if [[ " $* " == *" --print "* ]]; then
      [[ -f $ST/plan_fail ]] && { echo "error: could not satisfy dependencies" >&2; exit 1; }
      echo "$name"; [[ -f $ST/plan_extra ]] && echo qt6-base
      exit 0
    fi
    [[ -f $ST/install_fail ]] && exit 1
    # --ask 4 answers the conflict question: the twin replaces the other in one step. The package must come as a dependency.
    [[ " $* " == *" --ask 4 "* && " $* " == *" --asdeps "* ]] || exit 1
    case $name in grassfield-hold) rm -f "$ST/inst/grassfield-unhold" ;; grassfield-unhold) rm -f "$ST/inst/grassfield-hold" ;; esac
    [[ -f $ST/extra_removal ]] && rm -f "$ST/inst/bystander"
    if [[ -f $ST/swap_incomplete ]]; then echo 1 >"$ST/inst/grassfield-hold"; else cp "$ST/repo/$name" "$ST/inst/$name"; echo dep >"$ST/reason/$name"; fi
    exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/pacman"
printf '[options]\n\n[grassfield]\nInclude = /etc/pacman.d/grassfield.conf\n' >"$tmp/pacman.conf"
swap() { # verb [channel.sh]: runs gf_hold_swap in a subshell with the stand-in; sets rc and out
  : >"$tmp/st/calls"
  out=$( (
    export ST=$tmp/st PATH=$tmp/bin:/usr/bin
    . "${2:-$root/packaging/pacman/grassfield-channel.sh}"
    GF_PROG=test GF_PACMAN_CONF=$tmp/pacman.conf
    gf_hold_swap "$1"
  ) 2>&1)
  rc=$?
}
reset() {
  rm -f "$tmp/st"/inst/* "$tmp/st"/repo/* "$tmp/st"/rconf/* "$tmp/st"/qconf/* "$tmp/st"/qprov/* "$tmp/st"/rprov/* "$tmp/st"/reason/* "$tmp/st"/plan_* "$tmp/st"/install_fail "$tmp/st"/swap_incomplete "$tmp/st"/extra_removal
  echo 3-1 >"$tmp/st/repo/grassfield-hold"; echo 3-1 >"$tmp/st/repo/grassfield-unhold"
  echo "grassfield-hold" >"$tmp/st/rconf/grassfield-unhold"; echo "grassfield-hold" >"$tmp/st/rprov/grassfield-unhold"; echo 1-1 >"$tmp/st/inst/bystander"
}
installs() { grep -c -- '^-S --noconfirm' "$tmp/st/calls"; }
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"
swap unhold
expect "unhold: exit 0" "$rc" 0
expect "  the twin replaces the hold, the bystander stays" "$(ls "$tmp/st/inst" | tr '\n' ' ')" "bystander grassfield-unhold "
expect "  one install: explicit repository and version, --ask 4, --needed, --asdeps" "$(grep -- '^-S --noconfirm' "$tmp/st/calls")" "-S --noconfirm --ask 4 --needed --asdeps -- grassfield/grassfield-unhold=3-1"
expect "  the plan was read first, for that very version" "$(grep -- '--print' "$tmp/st/calls")" "-S --print --print-format %n --noconfirm --ask 4 -- grassfield/grassfield-unhold=3-1"
expect "  installed as a dependency (so pacman -Rns of grassfield-desktop takes it along)" "$(<"$tmp/st/reason/grassfield-unhold")" dep
swap hold
expect "hold: exit 0 and the hold is back" "$rc:$(ls "$tmp/st/inst" | tr '\n' ' ')" "0:bystander grassfield-hold "
expect "  one install of grassfield/grassfield-hold=3-1, as a dependency" "$(grep -- '^-S --noconfirm' "$tmp/st/calls"):$(<"$tmp/st/reason/grassfield-hold")" "-S --noconfirm --ask 4 --needed --asdeps -- grassfield/grassfield-hold=3-1:dep"
swap hold
expect "already held: success, nothing installed" "$rc:$(installs)" "0:0"
# The install reason is tested, not only the flag: a copy of the library without --asdeps is refused by the stand-in
# (a package that came without it would be left behind by a manual removal).
sed 's/ --asdeps//' "$root/packaging/pacman/grassfield-channel.sh" >"$tmp/channel-noasdeps.sh"
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"
swap unhold "$tmp/channel-noasdeps.sh"
expect "mutant without --asdeps: the stand-in refuses it (the test sees the flag)" "$rc:$([[ -f $tmp/st/reason/grassfield-unhold ]] && echo reason || echo none)" "1:none"
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; : >"$tmp/pacman.conf"
swap unhold
expect "no [grassfield] section: refused (exit 1), pacman not asked to install" "$rc:$(installs)" "1:0"
printf '[options]\n\n# [grassfield]\n' >"$tmp/pacman.conf"
swap unhold
expect "a commented [grassfield] is not a section" "$rc:$(installs)" "1:0"
printf '[options]\n\n[grassfield]\nInclude = /etc/pacman.d/grassfield.conf\n' >"$tmp/pacman.conf"
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; rm -f "$tmp/st/repo/grassfield-unhold"
swap unhold
expect "not in the synced list: refused, nothing installed" "$rc:$(installs):$(ls "$tmp/st/inst" | tr '\n' ' ')" "1:0:bystander grassfield-hold "
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; : >"$tmp/st/plan_extra"
swap unhold
expect "a plan that adds another package: refused, nothing installed" "$rc:$(installs)" "1:0"
reset; echo 2-1 >"$tmp/st/inst/grassfield-unhold"; : >"$tmp/st/plan_fail"
swap hold
expect "a plan pacman cannot make (the toolkit moved): refused, nothing installed" "$rc:$(installs):$(ls "$tmp/st/inst" | tr '\n' ' ')" "1:0:bystander grassfield-unhold "
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; : >"$tmp/st/install_fail"
swap unhold
expect "an install that fails: exit 1, the hold stays" "$rc:$(ls "$tmp/st/inst" | tr '\n' ' ')" "1:bystander grassfield-hold "
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; : >"$tmp/st/swap_incomplete"
swap unhold
expect "a swap that did not complete is reported" "$rc" 1
# --ask 4 answers every conflict question yes: only the twin may be a conflict.
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; echo "grassfield-hold bystander" >"$tmp/st/rconf/grassfield-unhold"
swap unhold
expect "a target that declares another conflict: refused before the plan, nothing installed" "$rc:$(installs):$(grep -c -- '--print' "$tmp/st/calls")" "1:0:0"
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; echo "grassfield-unhold" >"$tmp/st/qconf/bystander"
swap unhold
expect "an installed package that conflicts with the target: refused, nothing installed" "$rc:$(installs):$(ls "$tmp/st/inst" | tr '\n' ' ')" "1:0:bystander grassfield-hold "
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; echo "grassfield-unhold<=2" >"$tmp/st/qconf/bystander"
swap unhold
expect "  also with a version in its conflicts" "$rc:$(installs)" "1:0"
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; echo "grassfield-unhold" >"$tmp/st/qconf/grassfield-hold"
swap unhold
expect "the hold's own conflict with the twin is the one that is allowed" "$rc" 0
# Providers: --ask 4 would remove an installed package that provides a name the target conflicts with, or one that conflicts with a
# name the target provides (the twin provides grassfield-hold): both are refused before the plan, nothing installed.
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; echo "grassfield-hold=2" >"$tmp/st/qprov/bystander"
swap unhold
expect "an installed package that provides the name the target conflicts with: refused, nothing installed" "$rc:$(installs):$(grep -c -- '--print' "$tmp/st/calls"):$(ls "$tmp/st/inst" | tr '\n' ' ')" "1:0:0:bystander grassfield-hold "
[[ $out == *"provides a name grassfield-unhold conflicts with"* ]] && pass "  and says why" || fail "  no reason: $out"
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; echo "grassfield-hold>=1" >"$tmp/st/qconf/bystander"
swap unhold
expect "an installed package that conflicts with a name the target provides: refused, nothing installed" "$rc:$(installs)" "1:0"
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; echo "grassfield-hold=2" >"$tmp/st/qprov/grassfield-hold"
swap unhold
expect "the hold itself providing its own name is the twin's, allowed" "$rc" 0
# An epoch is kept whole.
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; echo 1:3-1 >"$tmp/st/repo/grassfield-unhold"
swap unhold
expect "a version with an epoch (1:3-1): the swap works, pinned whole" "$rc:$(grep -- '^-S --noconfirm' "$tmp/st/calls" | grep -c 'grassfield-unhold=1:3-1$')" "0:1"
# The conflicts are read into an array, never expanded unquoted.
grep -q 'for item in \$conflicts' "$root/packaging/pacman/grassfield-channel.sh" && fail "an unquoted conflicts loop is back" || pass "the conflicts loop is a quoted array"
# After the transaction: anything but the twin leaving fails loudly.
reset; echo 2-1 >"$tmp/st/inst/grassfield-hold"; : >"$tmp/st/extra_removal"
swap unhold
expect "another package removed by the transaction: exit 1" "$rc" 1
[[ $out == *"UNEXPECTED CHANGE"* && $out == *"removed 'bystander grassfield-hold'"* ]] && pass "  said loudly, naming what left" || fail "  no loud message: $out"
reset
swap sidegrade
expect "any other word is refused before pacman runs" "$rc:$(wc -l <"$tmp/st/calls")" "1:0"
swap ""
expect "an empty verb is refused before pacman runs" "$rc:$(wc -l <"$tmp/st/calls")" "1:0"
# The two package names are constants of the library; every installing pacman call names grassfield/$target=$version.
body=$(awk '/^gf_hold_swap\(\)/ { on = 1 } on { print } on && /^}/ { exit }' "$root/packaging/pacman/grassfield-channel.sh")
if printf '%s\n' "$body" | grep -E '^[^#]*pacman -S[^i]' | grep -v '"grassfield/\$target=\$version"' | grep -q .; then
  fail "a pacman call of gf_hold_swap names a package other than grassfield/\$target=\$version"
else pass "every installing pacman call of gf_hold_swap names grassfield/\$target=\$version"; fi

echo "== 4. grassfield-channel-set: hold, unhold and hold-state"
T=$tmp/tree
mkdir -p "$T/usr/share/grassfield/pacman" "$T/etc/pacman.d" "$T/run" "$T/usr/lib/grassfield"
cp "$root/packaging/arch/hold-bounds.sh" "$T/usr/lib/grassfield/grassfield-hold-bounds.sh"
sed -e "s#^repository=.*#repository=$T/usr/share/grassfield/pacman/repository.conf#" -e "s#^version_file=.*#version_file=$T/usr/share/grassfield/VERSION#" \
  -e "s#^pacman_conf=.*#pacman_conf=$T/etc/pacman.conf#" -e "s#^include=.*#include=$T/etc/pacman.d/grassfield.conf#" \
  -e "s#^build_deps=.*#build_deps=$T/usr/share/grassfield/BUILD-DEPS#" -e "s#^bounds_lib=.*#bounds_lib=$T/usr/lib/grassfield/grassfield-hold-bounds.sh#" \
  "$root/packaging/bin/grassfield-channel-set" >"$tmp/channel-set"
chmod +x "$tmp/channel-set"
cat >"$tmp/bin/recorder" <<'SH'
#!/bin/sh
echo "$*" >>"$CALLS"
SH
chmod +x "$tmp/bin/recorder"
printf 'GRASSFIELD_REPO_BASE=https://packages.grassfield.site\nGRASSFIELD_REPO_MIRRORS=\nGRASSFIELD_REPO_BASE_PREVIOUS=\nGRASSFIELD_SIGNING_FINGERPRINT=E4921A382C349308BAA50D2F44C31B5D862EBEFA\n' >"$T/usr/share/grassfield/pacman/repository.conf"
printf 'qt6-base 6.12.0-1\nquickshell 0.3.2.r7-1\nhyprland 0.56.2-4\n' >"$T/usr/share/grassfield/BUILD-DEPS"
cset() { # args...: as the user in a dev session with the recording runner and the pacman stand-in
  : >"$tmp/calls"
  out=$(env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp/home" XDG_RUNTIME_DIR="$T/run" GRASSFIELD_DEV=1 GRASSFIELD_UPDATE_PKEXEC="$tmp/bin/recorder" \
    CALLS="$tmp/calls" ST="$tmp/st" "$tmp/channel-set" "$@" 2>&1)
  rc=$?
}
ccalls() { cat "$tmp/calls" | tr '\n' '|'; }
for v in hold unhold; do
  cset "$v"; expect "channel-set $v: exit 0, pkexec runs the HOLD helper with $v and nothing else" "$rc:$(ccalls)" "0:/usr/lib/grassfield/grassfield-hold-helper $v|"
done
cset beta; expect "channel-set beta still runs the channel helper" "$rc:$(ccalls)" "0:/usr/lib/grassfield/grassfield-channel-helper set beta|"
for args in "hold unhold" "hold-state hold" "Hold" "holdstate" "unhold x"; do
  # shellcheck disable=SC2086
  cset $args; expect "channel-set $args: usage (exit 2), no helper" "$rc:$(ccalls)" "2:"
done
hs() { : >"$tmp/st/calls"; reset; rm -f "$tmp/st/inst/bystander"; for p in "$@"; do echo "${p#*=}" >"$tmp/st/inst/${p%%=*}"; done; cset hold-state; }
hs grassfield-hold=1 quickshell=0.3.2.r7-1 qt6-base=6.12.0-1
expect "hold-state: the hold installed -> held" "$rc:$out" "0:held"
hs grassfield-unhold=1 quickshell=0.3.2.r7-2 qt6-base=6.12.3-1
expect "hold-state: the twin, toolkit inside the bounds -> allowed" "$rc:$out" "0:allowed"
hs grassfield-unhold=1 quickshell=0.3.2.r8-1 qt6-base=6.12.0-1
expect "hold-state: the twin, quickshell moved -> allowed-moved" "$rc:$out" "0:allowed-moved"
hs grassfield-unhold=1 quickshell=0.3.2.r7-1 qt6-base=6.13.0-1
expect "hold-state: the twin, Qt moved -> allowed-moved" "$rc:$out" "0:allowed-moved"
hs quickshell=0.3.2.r7-1 qt6-base=6.12.0-1
expect "hold-state: neither -> none" "$rc:$out" "0:none"
hs grassfield-unhold=1
expect "hold-state: the twin without quickshell or Qt -> allowed-moved (greyed, never offered)" "$rc:$out" "0:allowed-moved"
rm -f "$T/usr/lib/grassfield/grassfield-hold-bounds.sh"
hs grassfield-unhold=1 quickshell=0.3.2.r7-1 qt6-base=6.12.0-1
expect "hold-state: no bounds library -> allowed-moved (never offered)" "$rc:$out" "0:allowed-moved"
expect "hold-state runs no helper" "$(ccalls)" ""

echo "== 5. the update helper: pacman's refusal naming the hold is exit 6, and an allowed hold is not compared"
helper_src=$root/packaging/pacman/grassfield-update-helper
pattern=$(grep -o 'grep -E "\[\[:space:\]\]required by[^"]*"' "$helper_src" | head -n 1 | sed 's/^grep -E "//; s/"$//')
[[ -n $pattern ]] && pass "the helper's pattern: $pattern" || fail "the helper's grep pattern was not found"
names() { printf '%s\n' "$1" | grep -Eq "$pattern" && echo yes || echo no; }
expect "a broken bound of the hold" "$(names "error: failed to prepare transaction (could not satisfy dependencies)
:: installing qt6-base (6.13.0-1) breaks dependency 'qt6-base<6.13' required by grassfield-hold")" yes
expect "quickshell moved" "$(names ":: installing quickshell (0.3.3-1) breaks dependency 'quickshell=0.3.2.r7' required by grassfield-hold")" yes
expect "pacman's other wording" "$(names "error: failed to prepare transaction (could not satisfy dependencies)
:: unable to satisfy dependency 'qt6-base>=6.12' required by grassfield-hold")" yes
expect "a refusal that names another package" "$(names ":: installing foo (2) breaks dependency 'foo<2' required by bar")" no
expect "a name that only contains the hold's" "$(names ":: installing foo (2) breaks dependency 'foo<2' required by grassfield-hold-extra")" no
expect "a prefix that is not a word" "$(names ":: installing foo (2) breaks dependency 'foo<2' required bygrassfield-hold")" no
expect "the hold named as the broken dependency, not the requirer" "$(names ":: installing grassfield-hold (2) breaks dependency 'grassfield-hold' required by bar")" no
expect "no error" "$(names "")" no
# The block itself, run with stand-ins: exit 6 only when pacman FAILED and named the hold (a warning on a plan that worked is not a refusal).
awk '/^plan=\$\(pacman -Su/ { on = 1 } on { print } on && /^\(\(plan_rc == 0\)\) \|\| finish 8/ { exit }' "$helper_src" >"$tmp/planblock.sh"
[[ $(wc -l <"$tmp/planblock.sh") -gt 5 ]] && pass "the plan block was found in the helper" || fail "the plan block was not found"
planrun() { # exit-code text [stdout|stderr]: the helper's plan block with a pacman that fails (or not) and says that, where
  mkdir -p "$tmp/tmpdb"
  ( tmpdb=$tmp/tmpdb outcome=() PLAN_RC=$1 PLAN_ERR=$2 PLAN_FD=${3:-stderr}
    pacman() {
      if [[ $PLAN_FD == stdout ]]; then printf '%s\n' "$PLAN_ERR"; else printf '%s\n' "$PLAN_ERR" >&2; fi
      [[ $PLAN_RC == 0 ]] && echo "hello 1-1 file:///x"
      return "$PLAN_RC"
    }
    finish() { echo "finish $1 ${outcome[*]:-}"; exit "$1"; }
    . "$tmp/planblock.sh"; echo "went on" ) 2>/dev/null | tail -n 1
}
hold_err=":: installing qt6-base (6.13.0-1) breaks dependency 'qt6-base<6.13' required by grassfield-hold"
expect "plan fails naming the hold -> finish 6 incompatible grassfield-hold" "$(planrun 1 "$hold_err")" "finish 6 incompatible grassfield-hold"
expect "plan fails naming the hold on STDOUT, as pacman 7.1 does -> finish 6" "$(planrun 1 "$hold_err" stdout)" "finish 6 incompatible grassfield-hold"
expect "plan fails naming another package on stdout -> finish 8" "$(planrun 1 ":: installing foo (2) breaks dependency 'foo<2' required by bar" stdout)" "finish 8 "
expect "plan fails naming another package -> finish 8" "$(planrun 1 ":: installing foo (2) breaks dependency 'foo<2' required by bar")" "finish 8 "
expect "plan fails with no message -> finish 8" "$(planrun 1 "")" "finish 8 "
expect "plan works and pacman only warned about the hold -> goes on (no exit 6)" "$(planrun 0 "warning: grassfield-hold ... $hold_err")" "went on"
# u27_exempt: with the twin installed and the hold not coming back, Qt and Quickshell are not compared; the others are.
awk '/^u27_exempt\(\)/ { on = 1 } on { print } on && /^}/ { exit }' "$helper_src" >"$tmp/exempt.sh"
[[ -s $tmp/exempt.sh ]] && pass "u27_exempt exists in the update helper" || fail "u27_exempt is missing from the update helper"
exempt() { # "installed names" "after names" package -> yes|no
  ( declare -A installed=() after=()
    for n in $1; do installed[$n]=1; done
    for n in $2; do after[$n]=1; done
    . "$tmp/exempt.sh"; u27_exempt "$3" && echo yes || echo no )
}
expect "twin installed: qt6-base is exempt" "$(exempt "grassfield-unhold" "" qt6-base)" yes
expect "twin installed: quickshell is exempt (the installed desktop's record, no new desktop in the plan)" "$(exempt "grassfield-unhold grassfield-desktop" "" quickshell)" yes
expect "twin installed: hyprland is still compared" "$(exempt "grassfield-unhold" "" hyprland)" no
expect "twin installed: aquamarine is still compared" "$(exempt "grassfield-unhold" "" aquamarine)" no
expect "twin installed: kcoreaddons is still compared" "$(exempt "grassfield-unhold" "" kcoreaddons)" no
expect "the hold installed: nothing is exempt (the hold is the first line, U27 the second)" "$(exempt "grassfield-hold" "" qt6-base)" no
expect "nothing installed: not exempt" "$(exempt "" "" quickshell)" no
expect "the plan brings the hold back: not exempt" "$(exempt "grassfield-unhold" "grassfield-hold" qt6-base)" no
expect "the plan carries a grassfield-desktop (its record must match the system): qt6-base is compared" "$(exempt "grassfield-unhold grassfield-desktop" "grassfield-desktop" qt6-base)" no
expect "the plan carries a grassfield-desktop: quickshell is compared" "$(exempt "grassfield-unhold grassfield-desktop" "grassfield-desktop" quickshell)" no
expect "the plan carries another package: still exempt" "$(exempt "grassfield-unhold" "bash" quickshell)" yes
# And the check really asks it: the comparison loop skips a package u27_exempt names.
grep -q 'if u27_exempt "\$pkg"; then' "$helper_src" && pass "the compatibility loop asks u27_exempt before it compares" || fail "the compatibility loop does not ask u27_exempt"

echo
if ((fails)); then echo "FAIL: update hold ($fails)"; exit 1; fi
echo "PASS: update hold"
