#!/usr/bin/env bash
# The update hold (ADR-0041 step 2a, SQ-3 option A; docs/specs/updates.md U39): the pair grassfield-hold / grassfield-unhold, offline.
#   1. The bounds the hold's `depends` get from BUILD-DEPS (packaging/arch/hold-bounds.sh): quickshell at its version without
#      its pkgrel, qt6-base at major.minor (>= and < the next minor), an epoch kept, never hyprland or kcoreaddons, and no
#      bound at all (the build fails) for a record that cannot be read; the same rule as the update helper's U27 comparison.
#   2. The root helper's argument validation (packaging/pacman/grassfield-channel-helper): exactly the verbs set stable|beta,
#      restore, off, hold, unhold, each with no extra argument; the scriptlet program refuses the helper's verbs.
#   3. gf_hold_swap (packaging/pacman/grassfield-channel.sh) against a pacman stand-in: its refusals leave pacman's install step
#      unstarted (no [grassfield], already installed, not listed, a plan that is more than the one package, a plan that
#      fails), one transaction with `--ask 4` and the explicit grassfield/<package>, a swap that did not complete.
#   4. grassfield-channel-set: the verbs hold and unhold go to the helper (recording stand-in), hold-state prints held,
#      allowed, allowed-moved or none from pacman -Q and BUILD-DEPS.
#   5. The helper's reading of pacman's refusal (grassfield-update-helper): exit 6 only when the error names grassfield-hold.
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

echo "== 2. the root helper's arguments"
lib=$tmp/lib.sh
# The helper replaces its environment (it runs again under `env -i` when it holds anything), so the stand-in library
# carries the recording file's path itself and the helper is started with no variable at all.
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
helper() { : >"$tmp/calls"; out=$(env -i /usr/bin/bash -p "$tmp/helper" "$@" 2>&1); rc=$?; }
calls() { grep -v '^unlocked-check$' "$tmp/calls" | tr '\n' '|'; }
for v in hold unhold; do
  helper "$v"; expect "$v: exit 0" "$rc" 0; expect "  one swap, nothing else" "$(calls)" "swap $v|"
done
helper set stable; expect "set stable accepted" "$(calls)" "set stable|"
helper set beta; expect "set beta accepted" "$(calls)" "set beta|"
helper restore; expect "restore accepted" "$(calls)" "restore|"
helper off; expect "off accepted" "$(calls)" "off|"
for args in "" "hold x" "unhold x" "hold unhold" "unhold grassfield-unhold" "Hold" "UNHOLD" "hold-state" "holds" "grassfield-hold" "set hold" "set" "set stable beta" \
  "-S grassfield-hold" "install grassfield-unhold" "remove" "upgrade" "--help" "off now" "restore x"; do
  # shellcheck disable=SC2086
  helper $args
  expect "refused: '$args' (exit 2, nothing run)" "$rc:$(calls)" "2:"
done
helper ""; expect "an empty argument is refused" "$rc:$(calls)" "2:"
helper "hold " ; expect "a trailing space is refused" "$rc:$(calls)" "2:"
helper "hold
"; expect "a newline is refused" "$rc:$(calls)" "2:"
# The scriptlet program knows no hold verb (each program knows only its own verbs).
if grep -nE '\b(un)?hold\b' "$root/packaging/pacman/grassfield-channel-scriptlet" >/dev/null; then fail "the scriptlet program names a hold verb"; else pass "the scriptlet program names no hold verb"; fi
# Every verb of the helper takes the unlocked check first (pacman is not running).
helper hold; [[ $(head -n 1 "$tmp/calls") == unlocked-check ]] && pass "hold checks that pacman is not running first" || fail "hold does not check db.lck first"
helper unhold; [[ $(head -n 1 "$tmp/calls") == unlocked-check ]] && pass "unhold checks that pacman is not running first" || fail "unhold does not check db.lck first"
# The helper never takes a package name from its arguments: gf_hold_swap is called with the verb, which picks a constant.
grep -n 'gf_hold_swap "\$1"' "$root/packaging/pacman/grassfield-channel-helper" >/dev/null && pass "the helper hands gf_hold_swap the verb only" || fail "gf_hold_swap is not called with the verb alone"

echo "== 3. gf_hold_swap against a pacman stand-in"
mkdir -p "$tmp/bin" "$tmp/st/inst" "$tmp/st/repo"
cat >"$tmp/bin/pacman" <<'SH'
#!/bin/bash
# A stand-in: state in $ST (inst/<name> = installed, repo/<name> = listed in [grassfield]). Records every call.
echo "$*" >>"$ST/calls"
last=${*: -1}
name=${last#grassfield/}
case $1 in
  -Q) [[ -f $ST/inst/$name ]] && { echo "$name $(<"$ST/inst/$name")"; exit 0; }; exit 1 ;;
  -Si) [[ $last == grassfield/* && -f $ST/repo/$name ]] && exit 0; exit 1 ;;
  -S)
    [[ $last == grassfield/* ]] || exit 1
    if [[ " $* " == *" --print "* ]]; then
      [[ -f $ST/plan_fail ]] && { echo "error: could not satisfy dependencies" >&2; exit 1; }
      echo "$name"; [[ -f $ST/plan_extra ]] && echo qt6-base
      exit 0
    fi
    [[ -f $ST/install_fail ]] && exit 1
    # --ask 4 answers the conflict question: the twin replaces the other in one step.
    [[ " $* " == *" --ask 4 "* ]] || exit 1
    case $name in grassfield-hold) rm -f "$ST/inst/grassfield-unhold" ;; grassfield-unhold) rm -f "$ST/inst/grassfield-hold" ;; esac
    [[ -f $ST/swap_incomplete ]] || echo 1 >"$ST/inst/$name"
    [[ -f $ST/swap_incomplete ]] && echo 1 >"$ST/inst/grassfield-hold"
    exit 0 ;;
esac
exit 1
SH
chmod +x "$tmp/bin/pacman"
printf '[options]\n\n[grassfield]\nInclude = /etc/pacman.d/grassfield.conf\n' >"$tmp/pacman.conf"
swap() { # verb: runs gf_hold_swap in a subshell with the stand-in; sets rc and out
  : >"$tmp/st/calls"
  out=$( (
    export ST=$tmp/st PATH=$tmp/bin:/usr/bin
    . "$root/packaging/pacman/grassfield-channel.sh"
    GF_PROG=test GF_PACMAN_CONF=$tmp/pacman.conf
    gf_hold_swap "$1"
  ) 2>&1)
  rc=$?
}
reset() { rm -f "$tmp/st"/inst/* "$tmp/st"/repo/* "$tmp/st"/plan_* "$tmp/st"/install_fail "$tmp/st"/swap_incomplete; echo 1 >"$tmp/st/repo/grassfield-hold"; echo 1 >"$tmp/st/repo/grassfield-unhold"; }
installs() { grep -c -- '^-S --noconfirm' "$tmp/st/calls"; }
reset; echo 1 >"$tmp/st/inst/grassfield-hold"
swap unhold
expect "unhold: exit 0" "$rc" 0
expect "  the twin replaces the hold" "$(ls "$tmp/st/inst" | tr '\n' ' ')" "grassfield-unhold "
expect "  one install, explicit repository, --ask 4, --needed" "$(grep -- '^-S --noconfirm' "$tmp/st/calls")" "-S --noconfirm --ask 4 --needed -- grassfield/grassfield-unhold"
expect "  the plan was read first, for that package only" "$(grep -c -- '--print' "$tmp/st/calls")" 1
swap hold
expect "hold: exit 0 and the hold is back" "$rc:$(ls "$tmp/st/inst" | tr '\n' ' ')" "0:grassfield-hold "
expect "  one install of grassfield/grassfield-hold" "$(grep -- '^-S --noconfirm' "$tmp/st/calls")" "-S --noconfirm --ask 4 --needed -- grassfield/grassfield-hold"
swap hold
expect "already held: success, nothing installed" "$rc:$(installs)" "0:0"
reset; echo 1 >"$tmp/st/inst/grassfield-hold"; : >"$tmp/pacman.conf"
swap unhold
expect "no [grassfield] section: refused (exit 1), pacman not asked to install" "$rc:$(installs)" "1:0"
printf '[options]\n\n# [grassfield]\n' >"$tmp/pacman.conf"
swap unhold
expect "a commented [grassfield] is not a section" "$rc:$(installs)" "1:0"
printf '[options]\n\n[grassfield]\nInclude = /etc/pacman.d/grassfield.conf\n' >"$tmp/pacman.conf"
rm -f "$tmp/st/repo/grassfield-unhold"
swap unhold
expect "not in the synced list: refused, nothing installed" "$rc:$(installs):$(ls "$tmp/st/inst")" "1:0:grassfield-hold"
reset; echo 1 >"$tmp/st/inst/grassfield-hold"; : >"$tmp/st/plan_extra"
swap unhold
expect "a plan that adds another package: refused, nothing installed" "$rc:$(installs)" "1:0"
reset; echo 1 >"$tmp/st/inst/grassfield-unhold"; : >"$tmp/st/plan_fail"
swap hold
expect "a plan pacman cannot make (the toolkit moved): refused, nothing installed" "$rc:$(installs):$(ls "$tmp/st/inst")" "1:0:grassfield-unhold"
reset; echo 1 >"$tmp/st/inst/grassfield-hold"; : >"$tmp/st/install_fail"
swap unhold
expect "an install that fails: exit 1, the hold stays" "$rc:$(ls "$tmp/st/inst")" "1:grassfield-hold"
reset; echo 1 >"$tmp/st/inst/grassfield-hold"; : >"$tmp/st/swap_incomplete"
swap unhold
expect "a swap that did not complete is reported" "$rc" 1
reset
swap sidegrade
expect "any other word is refused before pacman runs" "$rc:$(wc -l <"$tmp/st/calls")" "1:0"
swap ""
expect "an empty verb is refused before pacman runs" "$rc:$(wc -l <"$tmp/st/calls")" "1:0"
# The two package names are constants of the library; nothing in gf_hold_swap reads another variable for a package name.
body=$(awk '/^gf_hold_swap\(\)/ { on = 1 } on { print } on && /^}/ { exit }' "$root/packaging/pacman/grassfield-channel.sh")
if printf '%s\n' "$body" | grep -E '^[^#]*pacman -S' | grep -v '"grassfield/\$target"' | grep -q .; then
  fail "a pacman call of gf_hold_swap names a package other than grassfield/\$target"
else pass "every pacman call of gf_hold_swap names grassfield/\$target"; fi

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
ccalls() { sed 's#^/usr/lib/grassfield/grassfield-channel-helper ##' "$tmp/calls" | tr '\n' '|'; }
for v in hold unhold; do
  cset "$v"; expect "channel-set $v: exit 0, the helper's $v and nothing else" "$rc:$(ccalls)" "0:$v|"
done
for args in "hold unhold" "hold-state hold" "Hold" "holdstate" "unhold x"; do
  # shellcheck disable=SC2086
  cset $args; expect "channel-set $args: usage (exit 2), no helper" "$rc:$(ccalls)" "2:"
done
hs() { : >"$tmp/st/calls"; reset; for p in "$@"; do echo "${p#*=}" >"$tmp/st/inst/${p%%=*}"; done; cset hold-state; }
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

echo "== 5. pacman's refusal naming the hold is exit 6"
pattern=$(grep -o 'grep -Eq "[^"]*"' "$root/packaging/pacman/grassfield-update-helper" | head -n 1 | sed 's/^grep -Eq "//; s/"$//')
[[ -n $pattern ]] && pass "the helper's pattern: $pattern" || fail "the helper's grep pattern was not found"
names() { printf '%s\n' "$1" | grep -Eq "$pattern" && echo yes || echo no; }
expect "a broken bound of the hold" "$(names "error: failed to prepare transaction (could not satisfy dependencies)
:: installing qt6-base (6.13.0-1) breaks dependency 'qt6-base<6.13' required by grassfield-hold")" yes
expect "quickshell moved" "$(names ":: installing quickshell (0.3.3-1) breaks dependency 'quickshell=0.3.2.r7' required by grassfield-hold")" yes
expect "pacman's other wording" "$(names "error: failed to prepare transaction (could not satisfy dependencies)
:: unable to satisfy dependency 'qt6-base>=6.12' required by grassfield-hold")" yes
expect "a refusal that names another package" "$(names ":: installing foo (2) breaks dependency 'foo<2' required by bar")" no
expect "a name that only contains the hold's" "$(names ":: installing foo (2) breaks dependency 'foo<2' required by grassfield-hold-extra")" no
expect "the hold named as the broken dependency, not the requirer" "$(names ":: installing grassfield-hold (2) breaks dependency 'grassfield-hold' required by bar")" no
expect "no error" "$(names "")" no

echo
if ((fails)); then echo "FAIL: update hold ($fails)"; exit 1; fi
echo "PASS: update hold"
