#!/usr/bin/env bash
# The session's xdg-settings stand-in (packaging/session-bin/xdg-settings, ADR-0055 D-6) against the REAL xdg-utils in a scratch
# HOME (generic mode, XDG_CURRENT_DESKTOP=Grassfield:Hyprland, as the session): nothing of the owner's is read or written, no
# program but fakes is started, no session, no bus.
#   A  the problem: with Sanaga seeded in the session list, the real `xdg-settings set default-web-browser firefox.desktop` fails
#      (exit 4) and its rollback writes our entry into mimeapps.list (the finding of the review of PR #38)
#   B  through the stand-in the same call exits 0; the session list, ~/.config/mimeapps.list and the record all follow; xdg-mime
#      and xdg-open of an http URL then resolve to Firefox; get and check answer from the effective default
#   C  the url-scheme variants (http, https) set the web group; other schemes and properties are the real tool's, unchanged
#   D  `omarchy default browser` (when Omarchy's script is installed here, with fake browsers and a fake notifier) goes through it
#   E  the stand-in never finds itself: a real path that is the stand-in stops with an error before anything is written, and the
#      real tool is only ever named by absolute path
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
unset GRASSFIELD_SESSION QT_QPA_PLATFORMTHEME BROWSER DISPLAY WAYLAND_DISPLAY GRASSFIELD_STATE_HOME GRASSFIELD_XDG_SETTINGS_REAL
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/xdg-standin.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
check() { # description, condition command...
  local d=$1
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}
real=/usr/bin/xdg-settings
standin=$root/packaging/session-bin/xdg-settings
[[ -x $real && -x $standin && -x /usr/bin/xdg-mime && -x /usr/bin/xdg-open ]] || { echo "SKIP: xdg_settings_standin: needs xdg-utils"; exit 0; }

export HOME=$tmp/home XDG_CONFIG_HOME=$tmp/home/.config XDG_DATA_HOME=$tmp/home/.local/share XDG_STATE_HOME=$tmp/home/.local/state
export XDG_DATA_DIRS=$tmp/share XDG_CONFIG_DIRS=$tmp/etc-xdg XDG_CURRENT_DESKTOP=Grassfield:Hyprland GRASSFIELD_DEV=1 XDG_RUNTIME_DIR=$tmp/run
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/applications" "$XDG_STATE_HOME" "$tmp/share/applications" "$tmp/etc-xdg" "$tmp/bin" "$tmp/run"
cfg=$XDG_CONFIG_HOME
rec=$XDG_STATE_HOME/grassfield/default-apps.state
log=$tmp/opened.log

for name in sanaga firefox chromium; do
  cat >"$tmp/bin/fake-$name" <<EOF
#!/bin/sh
echo "$name \$*" >>"$log"
EOF
  chmod +x "$tmp/bin/fake-$name"
  cat >"$tmp/share/applications/$name.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Exec=$tmp/bin/fake-$name %u
Categories=Network;WebBrowser;
MimeType=text/html;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
EOF
done
ln -s "$standin" "$tmp/bin/xdg-settings"

# Omarchy's install: chromium for the web in mimeapps.list, the routing entry in hyprland-mimeapps.list; Sanaga seeded by the seed
reset_session() {
  rm -rf "$XDG_STATE_HOME/grassfield" "$cfg"/*.list "$log"
  printf '[Default Applications]\ntext/html=chromium.desktop\nx-scheme-handler/http=chromium.desktop\nx-scheme-handler/https=chromium.desktop\nx-scheme-handler/mailto=HEY.desktop\n' >"$cfg/mimeapps.list"
  printf '[Default Applications]\nx-scheme-handler/http=omarchy-browser.desktop\nx-scheme-handler/https=omarchy-browser.desktop\n' >"$cfg/hyprland-mimeapps.list"
  printf '[Default Applications]\nx-scheme-handler/http=sanaga.desktop;\nx-scheme-handler/https=sanaga.desktop;\ntext/html=sanaga.desktop;\napplication/xhtml+xml=sanaga.desktop;\n' >"$cfg/grassfield-mimeapps.list"
  mkdir -p "$XDG_STATE_HOME/grassfield"
  printf 'web.state=seeded\nweb.x-scheme-handler/http=chromium.desktop\nweb.x-scheme-handler/https=chromium.desktop\nweb.text/html=chromium.desktop\nweb.application/xhtml+xml=-\n' >"$rec"
}
effective() { PATH=$tmp/bin:$PATH xdg-mime query default "$1" 2>/dev/null; }
first_of() { sed -n "/^\[Default Applications\]/,/^\[/{s|^$2=||p}" "$1" | head -n 1; }

# A
reset_session
PATH=/usr/bin:/bin "$real" set default-web-browser firefox.desktop >/dev/null 2>&1
rc=$?
if ((rc != 0)); then ok "A the real xdg-settings fails with Sanaga seeded in the session list (exit $rc)"; else echo "NOTE: A the real xdg-settings did not fail here (another xdg-utils); the stand-in is still tested below"; fi
if [[ $(first_of "$cfg/mimeapps.list" text/html) != chromium.desktop || -n $(grep -c 'sanaga.desktop' "$cfg/mimeapps.list" | grep -v '^0$') ]]; then
  ok "A and its rollback or write leaves mimeapps.list changed (the pollution the review found)"
else
  echo "NOTE: A mimeapps.list was not polluted by this xdg-utils"
fi

# B
reset_session
PATH=$tmp/bin:$PATH xdg-settings set default-web-browser firefox.desktop >"$tmp/set.out" 2>&1
check "B set default-web-browser firefox.desktop exits 0 through the stand-in" test $? -eq 0
for t in x-scheme-handler/http x-scheme-handler/https text/html application/xhtml+xml; do
  check "B the session list names firefox for $t" test "$(first_of "$cfg/grassfield-mimeapps.list" "$t")" = "firefox.desktop;"
done
check "B mimeapps.list follows the explicit choice (the real tool ran)" test "$(first_of "$cfg/mimeapps.list" x-scheme-handler/http)" = "firefox.desktop"
check "B mimeapps.list still holds its other lines" grep -q '^x-scheme-handler/mailto=HEY.desktop' "$cfg/mimeapps.list"
check "B the record says user, with the choice" grep -q '^web.state=user$' "$rec"
check "B the record names the choice" grep -q '^web.chosen=firefox.desktop$' "$rec"
check "B the record's baseline is what the user's own lists name after the real tool" grep -q '^web.x-scheme-handler/http=firefox.desktop$' "$rec"
check "B xdg-mime resolves http to firefox in the session" test "$(effective x-scheme-handler/http)" = "firefox.desktop"
check "B xdg-mime resolves text/html to firefox in the session" test "$(effective text/html)" = "firefox.desktop"
rm -f "$log"
DISPLAY=:99 PATH=$tmp/bin:$PATH xdg-open "http://example.test/page" >"$tmp/open.out" 2>&1
sleep 0.5
[[ -f $log ]] || echo "NOTE: xdg-open said: $(cat "$tmp/open.out")"
check "B xdg-open of an http URL runs Firefox" grep -q "^firefox http://example.test/page" "$log"
check "B ... and not Sanaga or Chromium" bash -c '! grep -qE "^(sanaga|chromium) " "$1"' _ "$log"
check "B get default-web-browser answers firefox.desktop" test "$(PATH=$tmp/bin:$PATH xdg-settings get default-web-browser)" = "firefox.desktop"
check "B check default-web-browser firefox.desktop says yes" test "$(PATH=$tmp/bin:$PATH xdg-settings check default-web-browser firefox.desktop)" = "yes"
check "B check default-web-browser chromium.desktop says no" test "$(PATH=$tmp/bin:$PATH xdg-settings check default-web-browser chromium.desktop)" = "no"
check "B a second choice (chromium) works at once too" bash -c 'PATH="$1/bin:$PATH" xdg-settings set default-web-browser chromium.desktop && test "$(PATH="$1/bin:$PATH" xdg-settings get default-web-browser)" = chromium.desktop' _ "$tmp"

# the session start seed's view of what the stand-in left (the C++ seed is tested in files-unit-tests: BundledApps.*): the record parses
check "B the record is key=value lines only" bash -c '! grep -vE "^(#|$|[^=]+=.*)" "$1"' _ "$rec"

# C
reset_session
PATH=$tmp/bin:$PATH xdg-settings set default-url-scheme-handler https firefox.desktop >/dev/null 2>&1
check "C set default-url-scheme-handler https exits 0" test $? -eq 0
check "C and sets the web group (http too)" test "$(PATH=$tmp/bin:$PATH xdg-settings get default-url-scheme-handler http)" = "firefox.desktop"
check "C get default-url-scheme-handler https answers from the session" test "$(PATH=$tmp/bin:$PATH xdg-settings get default-url-scheme-handler https)" = "firefox.desktop"
check "C check default-url-scheme-handler https yes" test "$(PATH=$tmp/bin:$PATH xdg-settings check default-url-scheme-handler https firefox.desktop)" = "yes"
reset_session
want=$(PATH=/usr/bin:/bin "$real" get default-url-scheme-handler mailto 2>&1)
got=$(PATH=$tmp/bin:$PATH xdg-settings get default-url-scheme-handler mailto 2>&1)
check "C another scheme (mailto) is the real tool's, unchanged" test "$got" = "$want"
PATH=$tmp/bin:$PATH xdg-settings set default-url-scheme-handler mailto HEY.desktop >/dev/null 2>&1
check "C setting another scheme leaves the session list and the record alone" bash -c 'grep -q "^web.state=seeded$" "$1" && grep -q "sanaga.desktop" "$2/grassfield-mimeapps.list"' _ "$rec" "$cfg"
want=$("$real" --version 2>&1)
got=$(PATH=$tmp/bin:$PATH xdg-settings --version 2>&1)
check "C --version is the real tool's" test "$got" = "$want"
check "C the routing entry is never a target: refused with 2, nothing written" bash -c 'PATH="$1/bin:$PATH" xdg-settings set default-web-browser omarchy-browser.desktop >/dev/null 2>&1; test $? -eq 2 && grep -q "^web.state=seeded$" "$2"' _ "$tmp" "$rec"
check "C an id that is not a desktop id is refused with 2, nothing written" bash -c 'PATH="$1/bin:$PATH" xdg-settings set default-web-browser "../x" >/dev/null 2>&1; test $? -eq 2 && grep -q "^web.state=seeded$" "$2"' _ "$tmp" "$rec"

# F  a failed set writes nothing and never reaches the real tool (review of PR #38, MED-1 and the LOWs)
snap() { cat "$cfg/grassfield-mimeapps.list" "$cfg/mimeapps.list" "$rec" 2>/dev/null; }
reset_session
before=$(snap)
PATH=$tmp/bin:$PATH xdg-settings set default-web-browser firefx.desktop >/dev/null 2>&1
check "F a typo (not installed) exits 2" test $? -eq 2
check "F ... and changes nothing at all" test "$before" = "$(snap)"
check "F ... get still answers Sanaga" test "$(PATH=$tmp/bin:$PATH xdg-settings get default-web-browser)" = sanaga.desktop
check "F ... the scheme variant is refused the same" bash -c 'PATH="$1/bin:$PATH" xdg-settings set default-url-scheme-handler https firefx.desktop >/dev/null 2>&1; test $? -eq 2' _ "$tmp"
make_entry() { # id, name, exec
  cat >"$tmp/share/applications/$1" <<EOF
[Desktop Entry]
Type=Application
Name=$2
Exec=$3
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;
EOF
}
make_entry loop.desktop Loop 'xdg-open %u'
make_entry quoted.desktop Quoted '"/usr/bin/xdg-open" %u'
make_entry uwsmloop.desktop UwsmLoop 'uwsm app -- xdg-open %u'
make_entry uwsmapp.desktop UwsmApp 'uwsm-app -- omarchy-launch-browser %U'
make_entry shell.desktop Shell "sh -c 'firefox %u'"
for id in loop quoted uwsmloop uwsmapp shell; do
  reset_session
  before=$(snap)
  PATH=$tmp/bin:$PATH xdg-settings set default-web-browser "$id.desktop" >/dev/null 2>&1
  rc=$?
  check "F an entry whose Exec is a launcher ($id) is refused with 2" test $rc -eq 2
  check "F ... nothing is written for $id" test "$before" = "$(snap)"
done
make_entry zen.desktop Zen "uwsm app -- $tmp/bin/fake-firefox %u"
reset_session
PATH=$tmp/bin:$PATH xdg-settings set default-web-browser zen.desktop >/dev/null 2>&1
check "F a real browser behind uwsm app is accepted" test $? -eq 0
check "F ... and is the effective default" test "$(PATH=$tmp/bin:$PATH xdg-settings get default-web-browser)" = zen.desktop
# an entry GLib could not run, or would read two ways, is refused with 2 and nothing is written (delta review: LOW-1, LOW-2)
make_raw() { printf '%s\n' "$2" >"$tmp/share/applications/$1"; }
ENTRY_HEAD='[Desktop Entry]
Type=Application
Name=Odd
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;'
make_raw gone.desktop "$ENTRY_HEAD
Exec=/nonexistent/bin/gone %u"
make_raw nopath.desktop "$ENTRY_HEAD
Exec=no-such-browser-anywhere %u"
make_raw gonewrap.desktop "$ENTRY_HEAD
Exec=uwsm app -- /nonexistent/bin/gone %u"
make_raw notry.desktop "$ENTRY_HEAD
Exec=$tmp/bin/fake-firefox %u
TryExec=/nonexistent/bin/gone"
make_raw dupexec1.desktop "$ENTRY_HEAD
Exec=$tmp/bin/fake-firefox %u
Exec=xdg-open %u"
make_raw dupexec2.desktop "$ENTRY_HEAD
Exec=xdg-open %u
Exec=$tmp/bin/fake-firefox %u"
make_raw duptry.desktop "$ENTRY_HEAD
Exec=$tmp/bin/fake-firefox %u
TryExec=$tmp/bin/fake-firefox
TryExec=/nonexistent/bin/gone"
make_raw duptype.desktop "$ENTRY_HEAD
Type=Link
Exec=$tmp/bin/fake-firefox %u"
cp "$tmp/share/applications/firefox.desktop" "$tmp/share/evil.desktop"
# delta review 3: LOW-A a file of PATH that is not executable is no program; LOW-B an indented second Exec is read by GLib as the last
# Exec; LOW-C the group twice is merged by GLib, the later Exec wins
mkdir -p "$tmp/nxbin"
printf '#!/bin/sh\nexit 0\n' >"$tmp/nxbin/nxprog"
chmod 644 "$tmp/nxbin/nxprog"
make_raw nxpath.desktop "$ENTRY_HEAD
Exec=nxprog %u"
make_raw nxtry.desktop "$ENTRY_HEAD
Exec=$tmp/bin/fake-firefox %u
TryExec=nxprog"
make_raw dupindent.desktop "$ENTRY_HEAD
Exec=$tmp/bin/fake-firefox %u
  Exec=xdg-open %u"
make_raw dupindent2.desktop "$ENTRY_HEAD
	Exec=$tmp/bin/fake-firefox %u
Exec=xdg-open %u"
make_raw dupgroup.desktop "$ENTRY_HEAD
Exec=$tmp/bin/fake-firefox %u
[Desktop Entry]
Exec=xdg-open %u"
make_raw dupgroup2.desktop "$ENTRY_HEAD
Exec=$tmp/bin/fake-firefox %u
[Desktop Action new]
Name=New
[Desktop Entry]
Name=Again"
# LOW-D: the second header with trailing whitespace is still the group (GLib trims the line)
printf '%s\nExec=%s/bin/fake-firefox %%u\n[Desktop Entry]  \nExec=xdg-open %%u\n' "$ENTRY_HEAD" "$tmp" >"$tmp/share/applications/duptrail.desktop"
printf '%s\nExec=%s/bin/fake-firefox %%u\n[Desktop Entry]\t\nName=Again\n' "$ENTRY_HEAD" "$tmp" >"$tmp/share/applications/duptrail2.desktop"
for id in nxpath nxtry dupindent dupindent2 dupgroup dupgroup2 duptrail duptrail2; do
  reset_session
  before=$(snap)
  PATH=$tmp/nxbin:$tmp/bin:$PATH xdg-settings set default-web-browser "$id.desktop" >/dev/null 2>&1
  rc=$?
  check "F delta 3: $id is refused with 2" test $rc -eq 2
  check "F ... nothing is written for $id" test "$before" = "$(snap)"
done
for id in gone nopath gonewrap notry dupexec1 dupexec2 duptry duptype; do
  reset_session
  before=$(snap)
  PATH=$tmp/bin:$PATH xdg-settings set default-web-browser "$id.desktop" >/dev/null 2>&1
  rc=$?
  check "F an entry that cannot run or reads two ways ($id) is refused with 2" test $rc -eq 2
  check "F ... nothing is written for $id, get still answers Sanaga" test "$before" = "$(snap)" -a "$(PATH=$tmp/bin:$PATH xdg-settings get default-web-browser)" = sanaga.desktop
done
reset_session
before=$(snap)
PATH=$tmp/bin:$PATH xdg-settings set default-web-browser "..-evil.desktop" >/dev/null 2>&1
check "F an id with .. (read as applications/../evil.desktop) is refused with 2" test $? -eq 2
check "F ... and nothing is written" test "$before" = "$(snap)"
# a program found in PATH, a TryExec that exists, one of each key: accepted
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/pathbrowser"
chmod +x "$tmp/bin/pathbrowser"
make_raw pathy.desktop "$ENTRY_HEAD
Exec=pathbrowser %u
TryExec=pathbrowser"
reset_session
PATH=$tmp/bin:$PATH xdg-settings set default-web-browser pathy.desktop >/dev/null 2>&1
check "F a program named in PATH (with its TryExec) is accepted" test $? -eq 0
check "F ... and is the effective default" test "$(PATH=$tmp/bin:$PATH xdg-settings get default-web-browser)" = pathy.desktop
# a linked session list or record: refused with a non-zero exit, the real tool is NOT called (it would fail and write our entry into mimeapps.list)
reset_session
mv "$cfg/grassfield-mimeapps.list" "$tmp/real-session-list"
ln -s "$tmp/real-session-list" "$cfg/grassfield-mimeapps.list"
before=$(cat "$cfg/mimeapps.list" "$rec" "$tmp/real-session-list")
PATH=$tmp/bin:$PATH xdg-settings set default-web-browser firefox.desktop >/dev/null 2>&1
rc=$?
check "F a linked session list is refused (exit $rc, not 0)" test $rc -ne 0
check "F ... nothing is written through it, the user's mimeapps.list is untouched and holds no Sanaga" test "$before" = "$(cat "$cfg/mimeapps.list" "$rec" "$tmp/real-session-list")"
check "F ... no sanaga.desktop line reached mimeapps.list" bash -c '! grep -q "sanaga.desktop" "$1"' _ "$cfg/mimeapps.list"
reset_session
mv "$rec" "$tmp/real-record"
ln -s "$tmp/real-record" "$rec"
before=$(cat "$cfg/mimeapps.list" "$cfg/grassfield-mimeapps.list" "$tmp/real-record")
PATH=$tmp/bin:$PATH xdg-settings set default-web-browser firefox.desktop >/dev/null 2>&1
rc=$?
check "F a linked record is refused (exit $rc, not 0)" test $rc -ne 0
check "F ... and nothing is written" test "$before" = "$(cat "$cfg/mimeapps.list" "$cfg/grassfield-mimeapps.list" "$tmp/real-record")"
rm -f "$rec" "$cfg/grassfield-mimeapps.list"

# D
if [[ -x /usr/bin/omarchy-default-browser && -x /usr/bin/omarchy-cmd-missing ]]; then
  reset_session
  for n in firefox chromium; do
    printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/$n"
    chmod +x "$tmp/bin/$n"
  done
  printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/omarchy-notification-send"
  chmod +x "$tmp/bin/omarchy-notification-send"
  PATH=$tmp/bin:/usr/bin:/bin /usr/bin/omarchy-default-browser firefox >"$tmp/odb.out" 2>&1
  rc=$?
  check "D omarchy default browser firefox exits 0 through the stand-in" test $rc -eq 0
  check "D and Firefox is the session's http handler" test "$(effective x-scheme-handler/http)" = "firefox.desktop"
  check "D the choice is the user's in the record" grep -q '^web.chosen=firefox.desktop$' "$rec"
else
  echo "SKIP: D omarchy default browser is not installed here"
fi

# E
reset_session
before=$(cat "$cfg/grassfield-mimeapps.list" "$rec" "$cfg/mimeapps.list")
out=$(GRASSFIELD_XDG_SETTINGS_REAL="$tmp/bin/xdg-settings" PATH=$tmp/bin:$PATH timeout 10 "$tmp/bin/xdg-settings" set default-web-browser firefox.desktop 2>&1)
rc=$?
check "E a real path that is the stand-in (through a link) stops with an error" test $rc -eq 1
check "E ... saying it refuses to call itself" grep -q "refusing to call itself" <<<"$out"
check "E ... before anything is written" test "$before" = "$(cat "$cfg/grassfield-mimeapps.list" "$rec" "$cfg/mimeapps.list")"
out=$(GRASSFIELD_XDG_SETTINGS_REAL="$standin" timeout 10 "$standin" get default-web-browser 2>&1)
check "E the same with the file itself" test $? -eq 1
# a real tool that is a script calling `xdg-settings` through PATH would re-enter the stand-in: the stand-in itself calls $real only
check "E the stand-in never runs xdg-settings by name (only through \"$real\")" bash -c '! grep -nE "^[[:space:]]*(exec[[:space:]]+)?xdg-settings([[:space:]]|$)|\$\([[:space:]]*xdg-settings([[:space:]]|\))" "$1"' _ "$standin"
check "E the default real path is /usr/bin/xdg-settings" grep -q '^real=/usr/bin/xdg-settings$' "$standin"
# the override works in a dev run only
out=$(GRASSFIELD_DEV=0 GRASSFIELD_XDG_SETTINGS_REAL=/nonexistent PATH=$tmp/bin:$PATH "$tmp/bin/xdg-settings" get default-url-scheme-handler mailto 2>&1)
check "E outside a dev run the override is ignored" test "$out" = "$("$real" get default-url-scheme-handler mailto 2>&1)"
exit "$fail"
