#!/usr/bin/env bash
# shell/services/capture-ack.sh (ADR-0066 D-1, slice A1): the shell's acknowledgement file for the capture helper's `shooting`
# phase. The 0700 folder and the 0600 file exist before the first write, the mode is still 0600 after every write, the file
# holds exactly the seq (no newline, under the helper's 64 bytes), a link is refused and a seq that is not hex is refused.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/captureack.XXXXXX")
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
script=$root/shell/services/capture-ack.sh
umask 022 # the script must not depend on the caller's umask
folder=$tmp/grassfield
ack=$folder/capture-ack
mode() { stat -c %a -- "$1"; }

sh "$script" "$folder" "$ack"
desc="before the first write: folder 700, file 600 and empty"
check test "$(mode "$folder")" = 700 -a "$(mode "$ack")" = 600 -a ! -s "$ack"

sh "$script" "$folder" "$ack" 0123456789abcdef
desc="first write: status 0, mode still 600, exactly the seq with no newline"
check test "$?" = 0 -a "$(mode "$ack")" = 600 -a "$(cat "$ack")" = 0123456789abcdef -a "$(stat -c %s "$ack")" = 16

sh "$script" "$folder" "$ack" ffeeddccbbaa0099
desc="second write replaces the seq (no leftover bytes), mode 600, folder 700"
check test "$(cat "$ack")" = ffeeddccbbaa0099 -a "$(stat -c %s "$ack")" = 16 -a "$(mode "$ack")" = 600 -a "$(mode "$folder")" = 700

sh "$script" "$folder" "$ack" ab
desc="a shorter seq leaves nothing of the longer one"
check test "$(stat -c %s "$ack")" = 2 -a "$(cat "$ack")" = ab

chmod 666 "$ack"
chmod 755 "$folder"
sh "$script" "$folder" "$ack" 12
desc="a loosened file and folder are tightened to 600 and 700 again"
check test "$(mode "$ack")" = 600 -a "$(mode "$folder")" = 700 -a "$(cat "$ack")" = 12

for bad in "xyz" "../x" "a b" "$(printf '%033d' 0)" ""; do
    sh "$script" "$folder" "$ack" "$bad"
    rc=$?
    desc="seq '$bad' refused: status 1, file unchanged"
    check test "$rc" = 1 -a "$(cat "$ack")" = 12
done

rm -f "$ack"
printf secret >"$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$ack"
sh "$script" "$folder" "$ack" 12
rc=$?
desc="a link at the file is refused: status 1, the target untouched"
check test "$rc" = 1 -a "$(cat "$tmp/elsewhere")" = secret
rm -f "$ack"
printf secret >"$tmp/other"
ln "$tmp/other" "$ack"
sh "$script" "$folder" "$ack" 12
rc=$?
desc="a hard link at the file is refused: status 1, the other name untouched"
check test "$rc" = 1 -a "$(cat "$tmp/other")" = secret

mkdir "$tmp/real"
ln -s "$tmp/real" "$tmp/linkfolder"
chmod 755 "$tmp/real"
sh "$script" "$tmp/linkfolder" "$tmp/linkfolder/capture-ack" 12
rc=$?
desc="a symlinked folder is refused: status 1, its target not chmodded, nothing created"
check test "$rc" = 1 -a "$(mode "$tmp/real")" = 755 -a ! -e "$tmp/real/capture-ack"

rm -f "$ack"
sh "$script" "$folder" "$ack" 0123456789abcdef
desc="after all the refusals a clean write still gives mode 600, one link, exactly the seq"
check test "$?" = 0 -a "$(mode "$ack")" = 600 -a "$(stat -c %h "$ack")" = 1 -a "$(cat "$ack")" = 0123456789abcdef -a "$(stat -c %s "$ack")" = 16
exit $fail
