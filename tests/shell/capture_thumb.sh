#!/usr/bin/env bash
# shell/services/capture-thumb.sh (ADR-0066 D-9, slice A3): the floating thumbnail's file actions. A capture's path is data from
# the result file; the script acts only on a regular file, not a link, directly in a Save to folder (links in the folder's own
# path resolved on both sides). Fake wl-copy and gio record what they were given.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/capturethumb.XXXXXX")
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
script=$root/shell/services/capture-thumb.sh

mkdir -p "$tmp/bin" "$tmp/home/Pictures/Screenshots" "$tmp/home/Desktop" "$tmp/home/Documents" "$tmp/home/Videos" "$tmp/elsewhere" "$tmp/real"
cat >"$tmp/bin/wl-copy" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$tmp/wlcopy.args"
cat >"$tmp/wlcopy.stdin"
EOF
cat >"$tmp/bin/gio" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/gio.args"
EOF
chmod +x "$tmp/bin/wl-copy" "$tmp/bin/gio"
export PATH="$tmp/bin:$PATH"

shots=$tmp/home/Pictures/Screenshots
roots=("$shots" "$tmp/home/Desktop" "$tmp/home/Documents")
vroots=("$tmp/home/Videos" "$tmp/home/Desktop" "$tmp/home/Documents")
printf 'PNGDATA' >"$shots/a.png"
printf 'MOVIE' >"$tmp/home/Videos/r.mp4"
act() { sh "$script" "$@" >/dev/null 2>&1; }

act check shot "$shots/a.png" "${roots[@]}"
desc="a regular picture in the Screenshots folder passes"
check test "$?" = 0
act check recording "$tmp/home/Videos/r.mp4" "${vroots[@]}"
desc="a recording in the Videos folder passes"
check test "$?" = 0

act check shot "$shots" "${roots[@]}"
rc=$?
desc="a result naming the Screenshots folder itself is refused"
check test "$rc" != 0
mkdir "$shots/folder.png"
act check shot "$shots/folder.png" "${roots[@]}"
rc=$?
desc="a folder named like a picture is refused"
check test "$rc" != 0
act copy shot "$shots/folder.png" "${roots[@]}"
rc=$?
desc="and is not copied either"
check test "$rc" != 0 -a ! -e "$tmp/wlcopy.args"
act trash shot "$shots/folder.png" "${roots[@]}"
rc=$?
desc="and is not trashed: gio was never run"
check test "$rc" != 0 -a ! -e "$tmp/gio.args"

printf 'SECRET' >"$tmp/elsewhere/secret.png"
ln -s "$tmp/elsewhere/secret.png" "$shots/link.png"
act check shot "$shots/link.png" "${roots[@]}"
rc=$?
desc="a link to a file elsewhere is refused"
check test "$rc" != 0
act copy shot "$shots/link.png" "${roots[@]}"
rc=$?
desc="a link is not copied (the clipboard never gets the target)"
check test "$rc" != 0 -a ! -e "$tmp/wlcopy.args"
act trash shot "$shots/link.png" "${roots[@]}"
rc=$?
desc="a link is not trashed"
check test "$rc" != 0 -a ! -e "$tmp/gio.args"
ln -s "$shots/a.png" "$shots/link2.png"
act check shot "$shots/link2.png" "${roots[@]}"
rc=$?
desc="a link to a file in the same folder is refused too"
check test "$rc" != 0

act check shot "$tmp/elsewhere/secret.png" "${roots[@]}"
rc=$?
desc="a picture outside every Save to folder is refused"
check test "$rc" != 0
act check shot "$tmp/home/Pictures/a.png" "${roots[@]}"
printf 'x' >"$tmp/home/Pictures/a.png"
act check shot "$tmp/home/Pictures/a.png" "${roots[@]}"
rc=$?
desc="the Pictures folder itself is not a Save to folder"
check test "$rc" != 0
mkdir "$shots/sub"
printf 'x' >"$shots/sub/b.png"
act check shot "$shots/sub/b.png" "${roots[@]}"
rc=$?
desc="a file in a folder below a Save to folder is refused"
check test "$rc" != 0
act check shot "$shots/../a.png" "${roots[@]}"
rc=$?
desc="a path that climbs out of the folder is refused"
check test "$rc" != 0

printf 'x' >"$shots/.hidden.png"
act check shot "$shots/.hidden.png" "${roots[@]}"
rc=$?
desc="a hidden name (the helper's file being written) is refused"
check test "$rc" != 0
printf 'x' >"$shots/notes.txt"
act check shot "$shots/notes.txt" "${roots[@]}"
rc=$?
desc="a name that is not a picture is refused"
check test "$rc" != 0
act check shot "$shots/missing.png" "${roots[@]}"
rc=$?
desc="a file that does not exist is refused"
check test "$rc" != 0
act check shot "a.png" "${roots[@]}"
rc=$?
desc="a relative path is refused"
check test "$rc" != 0
printf 'x' >"$shots/$(printf 'bad\nname.png')"
act check shot "$shots/$(printf 'bad\nname.png')" "${roots[@]}"
rc=$?
desc="a newline in the path is refused"
check test "$rc" != 0
act check shot "$tmp/home/Videos/r.mp4" "${roots[@]}"
rc=$?
desc="a movie is not a screenshot"
check test "$rc" != 0
act check recording "$shots/a.png" "${vroots[@]}"
rc=$?
desc="a picture is not a recording"
check test "$rc" != 0

act copy shot "$shots/a.png" "${roots[@]}"
rc=$?
desc="copy hands the picture to wl-copy with its type"
check test "$rc" = 0 -a "$(cat "$tmp/wlcopy.args")" = "--type image/png" -a "$(cat "$tmp/wlcopy.stdin")" = PNGDATA
act copy recording "$tmp/home/Videos/r.mp4" "${vroots[@]}"
rc=$?
desc="a recording is not copied"
check test "$rc" != 0 -a "$(cat "$tmp/wlcopy.args")" = "--type image/png"

act trash shot "$shots/a.png" "${roots[@]}"
rc=$?
desc="trash is gio trash of the path, never a removal"
check test "$rc" = 0 -a "$(cat "$tmp/gio.args")" = "trash -- $shots/a.png" -a -e "$shots/a.png"

ln -s "$tmp/real" "$tmp/home/Documents2"
printf 'D' >"$tmp/real/d.png"
out=$(sh "$script" check shot "$shots/a.png" "${roots[@]}" 2>/dev/null)
desc="check prints the path it checked, one line, for the caller to open"
check test "$out" = "$shots/a.png"
out=$(sh "$script" check shot "$tmp/home/Documents2/d.png" "$tmp/home/Documents2" 2>/dev/null)
desc="through a link to a Save to folder it prints the path with the link resolved"
check test "$out" = "$tmp/real/d.png"

# A Save to folder that is a link to the real folder (a Pictures folder on another disk): the picture in it is accepted.
act check shot "$tmp/home/Documents2/d.png" "$tmp/home/Documents2" "$tmp/home/Documents"
rc=$?
desc="a Save to folder reached through a link is accepted (both sides resolved)"
check test "$rc" = 0
act check shot "$tmp/real/d.png" "$tmp/home/Documents2"
rc=$?
desc="and so is the same folder by its real name"
check test "$rc" = 0
act check shot "$tmp/elsewhere/secret.png" "$tmp/home/Documents2"
rc=$?
desc="but a link to some other folder is not a Save to folder for what is in it"
check test "$rc" != 0

sh "$script" bogus shot "$shots/a.png" "${roots[@]}" >/dev/null 2>&1
rc=$?
desc="an unknown action is a usage error"
check test "$rc" = 2
sh "$script" check shot "$shots/a.png" >/dev/null 2>&1
rc=$?
desc="no Save to folder given is a usage error"
check test "$rc" = 2
exit $fail
