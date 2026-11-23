#!/usr/bin/env bash
# The floating thumbnail's picture (docs/specs/security-images.md): the shell decodes only a PNG that services/image-copy.py made
# from the capture, never the capture file. Run exactly as CaptureThumbs.copyArgv builds it. An SVG kept in a .png file is
# re-encoded to a real PNG by the helper (no decoder of the shell sees the original bytes); a FIFO at the path, which would block
# an image-loader thread for good, is refused at once, so no other Image waits behind it; a folder, a payload that is no image and a missing file are
# refused. The card's Image reads only the copy (tests/unit/tst_capturethumbs.qml).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/capturethumbcopy.XXXXXX")
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
helper=$root/shell/services/image-copy.py
export HOME=$tmp/home
mkdir -p "$HOME/Pictures/Screenshots"
shots=$HOME/Pictures/Screenshots
dirscript=$root/shell/services/capture-thumb-dir.sh

# The pictures' private folder (docs/specs/security-images.md, "Store"): 0700, in the 0700 folder of the helper's private files,
# emptied at start and when the last card leaves; a link is refused at either level and nothing outside is touched.
umask 022
runtime=$tmp/run
mkdir -p "$runtime"
folder=$runtime/grassfield/capture-thumbs
sh "$dirscript" "$folder"
rc=$?
desc="the folder is made 0700 inside a 0700 parent, empty"
check test "$rc" = 0 -a "$(stat -c %a "$folder")" = 700 -a "$(stat -c %a "$runtime/grassfield")" = 700 -a -z "$(ls -A "$folder")"
printf x >"$folder/1-1.png"
printf x >"$folder/.hidden"
ln -s "$tmp/secret-target" "$folder/link.png"
printf KEEP >"$tmp/secret-target"
mkdir "$folder/sub"
printf deep >"$folder/sub/x.png"
chmod 755 "$folder"
sh "$dirscript" "$folder"
rc=$?
desc="emptied again: files, hidden files and links go, a link's target and anything below a folder stay, the mode is 0700 again"
check test "$rc" = 0 -a ! -e "$folder/1-1.png" -a ! -e "$folder/.hidden" -a ! -L "$folder/link.png" -a "$(cat "$tmp/secret-target")" = KEEP -a -f "$folder/sub/x.png" -a "$(stat -c %a "$folder")" = 700
rm -rf "$folder"
mkdir "$tmp/elsewhere"
printf KEEP >"$tmp/elsewhere/file"
ln -s "$tmp/elsewhere" "$folder"
sh "$dirscript" "$folder"
rc=$?
desc="a link at the folder is refused and what it points to is untouched"
check test "$rc" != 0 -a -f "$tmp/elsewhere/file"
rm -f "$folder"
rm -rf "$runtime/grassfield"
ln -s "$tmp/elsewhere" "$runtime/grassfield"
sh "$dirscript" "$folder"
rc=$?
desc="a link at the parent is refused too"
check test "$rc" != 0 -a -f "$tmp/elsewhere/file" -a ! -e "$tmp/elsewhere/capture-thumbs"
rm -f "$runtime/grassfield"
sh "$dirscript" "$runtime/grassfield/other"
rc=$?
desc="a folder not named capture-thumbs is refused"
check test "$rc" != 0
sh "$dirscript" "relative/capture-thumbs"
rc=$?
desc="a relative folder is refused"
check test "$rc" != 0
sh "$dirscript" "$folder"
rc=$?

copy() { # path out: runs as the shell does (timeout, setpriv, python3 -I), 64 MiB cap
    timeout -k 2 20 python3 -I "$helper" file "$1" 67108864 "$2" >/dev/null 2>&1
}
png_magic() { [ "$(head -c 8 "$1" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]; }

# A real PNG (1 x 1) copies to a PNG of its own.
printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==' | base64 -d >"$shots/a.png"
copy "$shots/a.png" "$tmp/out1.png"
rc=$?
desc="a PNG is copied: status 0, a PNG, mode 600"
check test "$rc" = 0 -a "$(stat -c %a "$tmp/out1.png" 2>/dev/null)" = 600
check png_magic "$tmp/out1.png"

# An SVG that names a file, kept in a .png: the helper renders it with no base URL (no reference followed) to a PNG of its own.
printf '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="8" height="8"><image xlink:href="%s" width="8" height="8"/></svg>' "$tmp/secret" >"$shots/svg.png"
printf 'SECRET' >"$tmp/secret"
copy "$shots/svg.png" "$tmp/out2.png"
rc=$?
desc="an SVG in a .png is re-encoded: what the shell would load is a PNG the helper made, not the original bytes"
check test "$rc" = 0 -a ! "$(head -c 4 "$tmp/out2.png")" = "<svg"
check png_magic "$tmp/out2.png"

# A FIFO at the path: refused at once, within the helper's own time, never waiting for a writer.
mkfifo "$shots/fifo.png"
start=$SECONDS
copy "$shots/fifo.png" "$tmp/out3.png"
rc=$?
desc="a FIFO at the path is refused without blocking (status not 0, no copy, well under the helper's 20 s)"
check test "$rc" != 0 -a ! -e "$tmp/out3.png" -a $((SECONDS - start)) -lt 10

# A link is refused by capture-thumb.sh before any copy is asked (tests/shell/capture_thumb.sh); the helper itself follows a link
# that really lies under its allowed roots, by design.

mkdir "$shots/folder.png"
copy "$shots/folder.png" "$tmp/out5.png"
rc=$?
desc="a folder is refused"
check test "$rc" != 0 -a ! -e "$tmp/out5.png"

copy "$shots/missing.png" "$tmp/out6.png"
rc=$?
desc="a file that is gone is refused"
check test "$rc" != 0 -a ! -e "$tmp/out6.png"

printf 'not an image at all' >"$shots/junk.png"
copy "$shots/junk.png" "$tmp/out7.png"
rc=$?
desc="a payload that is no image is refused, no copy made"
check test "$rc" != 0 -a ! -e "$tmp/out7.png"

# The copy is made new: an existing file is never written through.
printf 'old' >"$tmp/out8.png"
copy "$shots/a.png" "$tmp/out8.png"
rc=$?
desc="an existing copy path is never overwritten"
check test "$rc" != 0 -a "$(cat "$tmp/out8.png")" = old
exit $fail
