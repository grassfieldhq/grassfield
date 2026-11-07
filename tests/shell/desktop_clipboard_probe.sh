#!/usr/bin/env bash
# The desktop clipboard probe (shell/desktop/DesktopFiles.qml, extracted and evaluated by node) against a fake wl-paste:
# the first line says whether the files were cut (KDE x-kde-cutselection "1", GNOME gnome-copied-files "cut"), then the
# text/uri-list body; nothing at all without a uri list. Logic layer: no display, no clipboard of the session.
set -u
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
qml=$root/shell/desktop/DesktopFiles.qml
d=$(mktemp -d)
node -e '
const s = require("fs").readFileSync(process.argv[1], "utf8");
const i = s.indexOf("id: clipboardProbe");
const a = s.indexOf("command: [", i) + "command: ".length;
const b = s.indexOf("\n        stdout:", a);
const argv = eval(s.substring(a, b).trim());
process.stdout.write(argv[2]);
' "$qml" > "$d/probe.sh" || { echo "extract failed"; exit 1; }
mkdir "$d/bin"
cat > "$d/bin/wl-paste" <<'EOF'
#!/bin/sh
# Fake wl-paste: types from $FAKE_TYPES (space separated), contents from $FAKE_DIR/<type with / as _>.
case "$*" in
  *--list-types*) [ -n "$FAKE_TYPES" ] || exit 1; for t in $FAKE_TYPES; do echo "$t"; done ;;
  *) t=$(echo "$*" | sed 's/.*--type //'); f="$FAKE_DIR/$(echo "$t" | tr / _)"; [ -f "$f" ] && cat "$f" ;;
esac
EOF
chmod +x "$d/bin/wl-paste"
run() { FAKE_DIR=$d FAKE_TYPES=$1 PATH="$d/bin:$PATH" sh "$d/probe.sh"; }
printf 'file:///a/b\r\n' > "$d/text_uri-list"
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1: got [$2] want [$3]"; fail=1; fi; }
out=$(run "text/uri-list" | head -n 1); check "plain copy" "$out" "cut=0"
printf '1' > "$d/application_x-kde-cutselection"
out=$(run "text/uri-list application/x-kde-cutselection" | head -n 1); check "KDE cut" "$out" "cut=1"
printf '0' > "$d/application_x-kde-cutselection"
out=$(run "text/uri-list application/x-kde-cutselection" | head -n 1); check "KDE copy mark" "$out" "cut=0"
printf 'cut\nfile:///a/b' > "$d/x-special_gnome-copied-files"
out=$(run "text/uri-list x-special/gnome-copied-files" | head -n 1); check "GNOME cut" "$out" "cut=1"
printf 'copy\nfile:///a/b' > "$d/x-special_gnome-copied-files"
out=$(run "text/uri-list x-special/gnome-copied-files" | head -n 1); check "GNOME copy" "$out" "cut=0"
out=$(run "text/plain"); check "no uri list prints nothing" "$out" ""
out=$(run ""); check "empty clipboard prints nothing" "$out" ""
out=$(run "text/uri-list" | tail -n +2); check "uri list follows the first line" "$out" "$(printf 'file:///a/b\r')"
rm -rf "$d"
exit $fail
