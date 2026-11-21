#!/usr/bin/env bash
# ADR-0003: the Grassfield session fontconfig (packaging/fontconfig/fonts.conf), resolved with fc-match under
# FONTCONFIG_FILE. Hermetic: HOME, XDG_CONFIG_HOME and XDG_CACHE_HOME point at a scratch directory, so the owner's
# ~/.config/fontconfig, ~/.local/share/fonts and ~/.cache are never read or written. Every case runs twice: with no
# user config, and with an Omarchy-like one (omarchy-font-set's ~/.config/fontconfig/fonts.conf plus the package default
# 50-omarchy.conf in the user's conf.d). The conf under test can be overridden with GRASSFIELD_FONTCONF (regression proof).
# Family names go through fc-match's name parser, where "-" starts a size: it is escaped as \- (apps pass the family
# string directly, so the escape only exists in this test).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
conf=${GRASSFIELD_FONTCONF:-$root/packaging/fontconfig/fonts.conf}
fail=0
if ! command -v fc-match >/dev/null || ! command -v fc-list >/dev/null; then
  echo "SKIP: fontconfig session (fc-match or fc-list missing)"
  exit 0
fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/fontconfig-session.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
omarchy_default=/usr/share/omarchy/default/fontconfig/conf.avail/50-omarchy.conf
mkdir -p "$tmp/none/.config" "$tmp/none/.cache" "$tmp/omarchy/.config/fontconfig/conf.d" "$tmp/omarchy/.cache"
cat >"$tmp/omarchy/.config/fontconfig/fonts.conf" <<'XML'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="pattern">
    <test name="family" qual="any"><string>monospace</string></test>
    <edit name="family" mode="prepend_first" binding="strong"><string>JetBrainsMono Nerd Font</string></edit>
  </match>
</fontconfig>
XML
[[ -r $omarchy_default ]] && cp "$omarchy_default" "$tmp/omarchy/.config/fontconfig/conf.d/50-omarchy.conf"

mode=none
fcx() { # tool args... in the scratch home of the current mode, nothing else from the caller's environment
  local tool=$1; shift
  env -i PATH="$PATH" HOME="$tmp/$mode" XDG_CONFIG_HOME="$tmp/$mode/.config" XDG_CACHE_HOME="$tmp/$mode/.cache" \
    "${FCENV[@]}" "$tool" "$@"
}
fc() { fcx fc-match "$@"; }
fl() { FCENV=(); fcx fc-list "$@"; }
sys() { FCENV=(); fc "$1" family | head -1; }
ses_fc() { FCENV=(FONTCONFIG_FILE="$conf"); fc "$@"; }
ses() { ses_fc "$1" family | head -1; }
is() { # pattern expected-family
  local got; got=$(ses "$1")
  if [[ $got == "$2" ]]; then echo "PASS: [$mode] $1 -> $got"; else echo "FAIL: [$mode] $1 -> $got (want $2)"; fail=1; fi
}
# The generic chains end on fonts the system's own fontconfig prefers, which this file leaves alone: the fontconfig release
# and the installed set decide them (Omarchy's fonts without DejaVu: Noto Naskh Arabic and Noto Color Emoji; with ttf-dejavu,
# which covers both, DejaVu Sans; older fontconfig releases preferred Liberation through the metric aliases, 2.18 prefers Noto).
# So these are checked against the system's answer, plus what the chain is for: the font covers the script or character.
chain() { # pattern fc-list-property: the system's font, never Inter, and one that has the property
  local a b; a=$(sys "$1"); b=$(ses "$1")
  if [[ $a == "$b" && $b != Inter && -n $(fl ":family=$b:$2" family) ]]; then echo "PASS: [$mode] $1 -> $b (the system's chain, has $2)"
  else echo "FAIL: [$mode] $1 -> $b, system gives $a (want the system's font, not Inter, with $2)"; fail=1; fi
}
isnt() { # pattern family: the session never resolves the pattern to that family
  local got; got=$(ses "$1")
  if [[ $got != "$2" ]]; then echo "PASS: [$mode] $1 -> $got (not $2)"; else echo "FAIL: [$mode] $1 -> $got"; fail=1; fi
}
same() { # pattern: unchanged against the system configuration
  local a b; a=$(sys "$1"); b=$(ses "$1")
  if [[ $a == "$b" ]]; then echo "PASS: [$mode] $1 unchanged -> $b"; else echo "FAIL: [$mode] $1 -> $b, system gives $a"; fail=1; fi
}
if [[ -z $(fl Inter family) ]]; then echo "SKIP: fontconfig session (Inter font missing)"; exit 0; fi
for mode in none omarchy; do
  # Inter
  is 'sans\-serif' Inter
  is 'Sans Serif' Inter
  is Sans Inter
  is 'system\-ui' Inter
  is '\-apple\-system' Inter
  is BlinkMacSystemFont Inter
  is 'SF Pro' Inter
  is 'SF Pro Text' Inter
  is '.AppleSystemUIFont' Inter
  is 'SF Pro Display' 'Inter Display'
  is 'sans\-serif:pixelsize=13' Inter
  is 'sans\-serif:pixelsize=24' 'Inter Display'
  is 'system\-ui:pixelsize=24' 'Inter Display'
  # web font stacks: the first name that is an alias, or a missing family, ends on Inter; an installed one wins
  is 'system\-ui,Arial' Inter
  is 'system\-ui,Helvetica' Inter
  is 'system\-ui,\-apple\-system,Segoe UI,Roboto,Helvetica Neue,Arial,sans\-serif' Inter
  is '\-apple\-system,BlinkMacSystemFont,Segoe UI,Noto Sans,Helvetica,Arial,sans\-serif' Inter
  # families that are not installed fall back to Inter
  is 'Segoe UI' Inter
  is 'Cantarell' Inter
  is 'Segoe UI,sans\-serif' Inter
  is 'Cantarell,sans\-serif' Inter
  # a real family that comes first in a list is never overtaken by an alias behind it (GTK passes CSS lists as one pattern)
  same 'monospace,system\-ui'
  same 'Noto Serif,system\-ui'
  same 'Noto Sans,\-apple\-system'
  same 'JetBrainsMono Nerd Font,SF Pro'
  same 'Noto Sans,BlinkMacSystemFont'
  is 'Noto Serif,system\-ui' 'Noto Serif'
  is 'Noto Sans,\-apple\-system' 'Noto Sans'
  # Documented limitation (ADR-0003): a family that is not installed and not one of the system-ui "UI" names gets
  # sans-serif from 49-sansserif, which Omarchy rewrites to Liberation Sans. It keeps what the system gives it.
  same Roboto
  same Verdana
  same Ubuntu
  is Roboto "$(sys 'sans\-serif')"
  if [[ $mode == omarchy && -r $omarchy_default ]]; then is Roboto 'Liberation Sans'; fi
  # unchanged
  same monospace
  same serif
  same Helvetica
  same Arial
  same Arimo
  same 'Liberation Sans'
  same Georgia
  same 'Courier New'
  same 'Times New Roman'
  is Arial 'Liberation Sans'
  is Helvetica 'Nimbus Sans'
  is 'Liberation Sans' 'Liberation Sans'
  is Arimo 'Liberation Sans'
  isnt serif Inter
  isnt monospace Inter
  # system-ui first still ends on Inter (the user's monospace rule of the Omarchy mode applies to any list naming monospace)
  [[ $mode == none ]] && is 'system\-ui,monospace' Inter
  # alias chains behind the generics still fire
  chain ':lang=ar' 'lang=ar'
  is 'emoji' 'Noto Color Emoji'
  chain 'sans\-serif:charset=1f600' 'charset=1f600'
  if ses_fc -s ':lang=ja' family | grep -q 'CJK'; then echo "PASS: [$mode] :lang=ja still has a CJK fallback"
  else echo "FAIL: [$mode] :lang=ja has no CJK fallback"; fail=1; fi
  style=$(ses_fc 'system\-ui:weight=bold' family style | head -1)
  if [[ $style == "Inter:style=Bold" ]]; then echo "PASS: [$mode] system-ui:weight=bold -> Inter Bold"; else echo "FAIL: [$mode] system-ui:weight=bold -> $style"; fail=1; fi
  rend=$(ses_fc -v 'sans\-serif' | grep -E '^\s+(antialias|hintstyle|rgba|lcdfilter):' | tr -s ' \n' ' ')
  case $rend in
    *"antialias: True"*"hintstyle: 1"*"rgba: 5"*"lcdfilter: 0"*) echo "PASS: [$mode] rendering antialias, hintslight, rgba none, lcdfilter none" ;;
    *) echo "FAIL: [$mode] rendering was: $rend"; fail=1 ;;
  esac
done

# Without the session file nothing changes: the user's own config decides.
mode=omarchy
if [[ $(sys 'sans\-serif') != Inter ]]; then echo "PASS: without FONTCONFIG_FILE sans-serif is still $(sys sans-serif)"; else
  echo "NOTE: the system configuration already resolves sans-serif to Inter"; fi
if grep -q '<include ignore_missing="yes">/etc/fonts/fonts.conf</include>' "$conf"; then echo "PASS: includes the system fonts.conf"; else echo "FAIL: no system include"; fail=1; fi
if grep -v '^\s*<!--' "$conf" | grep -qiE '<string>(monospace|Helvetica|Arial)</string>.*</edit>'; then echo "FAIL: rules edit monospace, Helvetica or Arial"; fail=1; else echo "PASS: no rule edits monospace, Helvetica or Arial"; fi
env_ok=$(grep -c 'FONTCONFIG_FILE=/usr/share/grassfield/fontconfig/fonts.conf' "$root/packaging/uwsm/env-grassfield" || true)
if [[ $env_ok == 1 ]] && grep -q '^if \[ -r /usr/share/grassfield/fontconfig/fonts.conf \]; then' "$root/packaging/uwsm/env-grassfield"; then
  echo "PASS: env-grassfield exports FONTCONFIG_FILE behind a readability test"; else echo "FAIL: env-grassfield FONTCONFIG_FILE guard"; fail=1; fi

# QtQuick distance-field text is grayscale only by QSG_DISTANCEFIELD_ANTIALIASING=gray (ADR-0003): sourced env, unconditional.
qsg=$(env -i sh -c '. "$1"; echo "${QSG_DISTANCEFIELD_ANTIALIASING-unset}"' _ "$root/packaging/uwsm/env-grassfield")
if [[ $qsg == gray ]]; then echo "PASS: env-grassfield exports QSG_DISTANCEFIELD_ANTIALIASING=gray (sourced with sh, unconditionally)"; else echo "FAIL: env-grassfield QSG_DISTANCEFIELD_ANTIALIASING is '$qsg'"; fail=1; fi
qsg=$(env -i HOME="$tmp" PATH="$PATH" bash -c "cd \"$root\" && . scripts/dev/devenv.sh && echo \"\${QSG_DISTANCEFIELD_ANTIALIASING-unset}\"" 2>/dev/null | tail -n1)
if [[ $qsg == gray ]]; then echo "PASS: scripts/dev/devenv.sh (dev and nested sessions) exports the same value"; else echo "FAIL: devenv.sh QSG_DISTANCEFIELD_ANTIALIASING is '$qsg'"; fail=1; fi

# User hook ~/.config/grassfield/fonts.conf (XDG_CONFIG_HOME) is the last rule and wins over Inter and the rendering.
for mode in none omarchy; do
  mkdir -p "$tmp/$mode/.config/grassfield"
  cat >"$tmp/$mode/.config/grassfield/fonts.conf" <<'HOOK'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <match target="pattern">
    <test name="family" qual="any"><string>sans-serif</string></test>
    <edit name="family" mode="prepend_first" binding="strong"><string>Noto Sans</string></edit>
  </match>
  <match target="font">
    <edit name="hintstyle" mode="assign"><const>hintfull</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
  </match>
</fontconfig>
HOOK
  if [[ -n $(fl 'Noto Sans' family) ]]; then
    is 'sans\-serif' 'Noto Sans'
    rend=$(ses_fc -v 'sans\-serif' | grep -E '^\s+(hintstyle|rgba):' | tr -s ' \n' ' ')
    case $rend in *"hintstyle: 3"*"rgba: 1"*) echo "PASS: [$mode] the user hook wins over the rendering settings" ;; *) echo "FAIL: [$mode] hook rendering: $rend"; fail=1 ;; esac
  else echo "SKIP: user hook (Noto Sans missing)"; fi
  rm -f "$tmp/$mode/.config/grassfield/fonts.conf"
done
if grep -q '<include ignore_missing="yes" prefix="xdg">grassfield/fonts.conf</include>' "$conf" \
   && [[ $(grep -n '<include\|</fontconfig>' "$conf" | tail -2 | head -1) == *grassfield/fonts.conf* ]]; then
  echo "PASS: the user hook include is the last element"; else echo "FAIL: user hook include missing or not last"; fail=1; fi
exit "$fail"
