#!/usr/bin/env bash
# ADR-0015 session rules, offline (no session): the window rules S1-S3 of config/hypr/grassfield/windows.lua are accepted by
# this Hyprland (`--verify-config`), a misspelled match key is refused (negative control: the check can fail), and the tag name
# is the same in the rule, the shell (shell/overview/ClientChrome.js) and the spec (docs/specs/compositor.md, P1).
# Exit 0 when every check passes; the verify-config checks SKIP (printed) without a Hyprland binary.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [[ $2 == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }

rules=$root/config/hypr/grassfield/windows.lua
tag=$(sed -n 's/^var TAG = "\(.*\)";$/\1/p' "$root/shell/overview/ClientChrome.js")
[[ -n $tag ]]
check "the shell names the tag ($tag)" $?
grep -q "tag = \"+$tag\"" "$rules"
check "the session rule sets the same tag" $?
grep -q "$tag" "$root/docs/specs/compositor.md"
check "the spec (plugin work item P1) uses the same tag" $?
# S2: the maximize exemption is exactly the client-chrome matches (reviewer 2026-10-23: any xdg-tagged window was exempt):
# Grassfield's apps with an xdg tag, and the third-party list of GF-056 (ADR-0015 amendment 2026-10-25).
cc_class=$(sed -n 's/.*name = "gf-client-chrome", match = { class = "\([^"]*\)", xdg_tag = "\.+" }.*/\1/p' "$rules")
[[ -n $cc_class ]]
check "the client-chrome rule matches a class list and any xdg tag" $?
tp_class=$(sed -n 's/.*name = "gf-client-chrome-third-party", match = { class = "\([^"]*\)" }, tag = "+grassfield-client-chrome".*/\1/p' "$rules")
[[ $tp_class == '^('*')$' ]]
check "the third-party client-chrome rule matches a class list (GF-056)" $? "$tp_class"
tp_re=${tp_class//\\\\/\\}
okc=0
for id in chromium google-chrome firefox org.mozilla.firefox md.obsidian.Obsidian org.gnome.Evince org.gnome.Nautilus; do [[ $id =~ $tp_re ]] || okc=1; done
for id in google-chrome-beta chrome-example.com__-Default firefox-esr Firefox org.mozillafirefox; do [[ $id =~ $tp_re ]] && okc=1; done
check "the third-party list holds Firefox (firefox, org.mozilla.firefox; owner's rc1-22 screenshot) and Google Chrome (google-chrome, as Omarchy's browser rule names it), not an app window (chrome-<site>-Default)" $okc
# Every Grassfield app that draws its own chrome (its main.cpp makes a ChromeTagger, apps/windowchrome.h) is in the rule,
# under each app id it gives itself; Glance alone has its own rule, without a titlebar (integrator, PR #47: Activity Monitor
# showed two sets of lights). A missing app gets the plugin's titlebar over its toolbar.
cc_re=${cc_class//\\\\/\\}
glance_re=$(sed -n 's/.*name = "gf-glance", match = { class = "\([^"]*\)" }.*decorate = false.*/\1/p' "$rules")
glance_re=${glance_re//\\\\/\\}
ids=$(grep -l "ChromeTagger" "$root"/apps/*/src/main.cpp | xargs grep -h "setDesktopFileName" \
  | grep -o 'QStringLiteral("org\.grassfield\.[A-Za-z.]*")' | sed 's/QStringLiteral("\(.*\)")/\1/' | sort -u)
missing=""
for id in $ids; do
  [[ $id =~ $cc_re || ( -n $glance_re && $id =~ $glance_re ) ]] || missing+=" $id"
done
[[ -n $ids && -z $missing ]]
rc=$?
check "every Grassfield app drawing its own chrome is in the client-chrome rule ($(echo $ids | wc -w) ids)" $rc
[[ -n $missing ]] && echo "  missing:$missing"
[[ ! org.grassfield.NotAnApp =~ $cc_re ]]
check "negative control: an id outside the list does not match the rule" $?
cc_inner=${cc_class#^}; cc_inner=${cc_inner%\$}
tp_inner=${tp_class#^(}; tp_inner=${tp_inner%)\$}
grep -qF "name = \"gf-no-maximize-event\", match = { class = \"negative:^($cc_inner|$tp_inner)\$\" }, suppress_event = \"maximize\"" "$rules"
check "S2: every other class keeps the maximize suppression (negation of both lists)" $?
grep -qF "name = \"gf-no-maximize-event-untagged\", match = { class = \"negative:$tp_class\", xdg_tag = \"negative:.+\" }, suppress_event = \"maximize\"" "$rules"
check "S2: a window without an xdg tag and not in the third-party list keeps the maximize suppression" $?
if grep -v "^ *--" "$rules" | grep 'suppress_event = "maximize"' | grep -v 'gf-no-maximize-event' | grep -q .; then
  check "S2: no other rule touches the maximize suppression" 1
else
  check "S2: no other rule touches the maximize suppression" 0
fi
# One radius for every window (ADR-0024 C-1): the info windows' rule and the third-party rule set decoration.rounding's.
radius=$(sed -n 's/^    rounding = \([0-9][0-9]*\),.*/\1/p' "$root/config/hypr/grassfield/looknfeel.lua" | head -n 1)
[[ -n $radius ]]
check "decoration.rounding is set (${radius:-none})" $?
grep -q "name = \"gf-client-chrome-info-rounding\".*xdg_tag = \"^info\\\$\".*rounding = $radius })" "$rules"
check "windows of role info get the one window radius ${radius:-?} (S3, ADR-0024)" $?
grep -q "name = \"gf-third-party-rounding\".*rounding = $radius })" "$rules"
check "third-party windows get the one window radius ${radius:-?} (ADR-0024 C-1)" $?
if grep -v "^ *--" "$rules" | grep "decorate *= *false" | grep -v "gf-glance" | grep -q .; then
  check "no rule but Glance's uses decorate = false (it drops the border and the shadow)" 1
else
  check "no rule but Glance's uses decorate = false (it drops the border and the shadow)" 0
fi

hypr=$(command -v Hyprland || true)
if [[ -z $hypr ]]; then
  echo "SKIP verify-config: no Hyprland binary"
  exit $fails
fi
verify() { # <config dir> -> exit 0 when "config ok"
  GRASSFIELD_CONFIG_DIR=$1 "$hypr" --verify-config --config "$1/session.lua" 2>&1 | sed -n '/Config parsing result/,$p' | grep -qx 'config ok'
}
verify "$root/config/hypr"
check "Hyprland --verify-config accepts the rules (S1-S3)" $?
cp -r "$root/config/hypr" "$tmp/hypr"
sed -i 's/xdg_tag = "\.+"/xdg_tagg = ".+"/' "$tmp/hypr/grassfield/windows.lua"
verify "$tmp/hypr"
[[ $? != 0 ]]
check "negative control: a misspelled match key is refused" $?
exit $fails
