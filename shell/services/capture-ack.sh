#!/bin/sh
# The shell's acknowledgement of the capture helper's `shooting` phase (ADR-0066 D-1). Usage: capture-ack.sh FOLDER FILE [SEQ]
# Makes the 0700 folder and the 0600 file once (a FileView cannot set modes, and keeps only an existing target's); with SEQ it
# then writes it, exactly and without a newline, into the file in place, so the mode never changes. A link at FILE is refused
# (the helper ignores links), and SEQ must be 1 to 32 hex digits. Tested by tests/shell/capture_ack.sh.
umask 077
folder=$1
file=$2
[ ! -L "$folder" ] || exit 1
mkdir -p -m 700 -- "$folder" || exit 1
[ ! -L "$folder" ] || exit 1
chmod 700 -- "$folder" || exit 1
[ ! -L "$file" ] || exit 1
[ -e "$file" ] || install -m 600 /dev/null "$file" || exit 1
[ -f "$file" ] && [ ! -L "$file" ] || exit 1
# A hard link (a second name for the inode) is refused: its content would be written through the other name too.
[ "$(stat -c %h -- "$file")" = 1 ] || exit 1
chmod 600 -- "$file" || exit 1
[ $# -ge 3 ] || exit 0
case $3 in
    '' | *[!0-9A-Fa-f]*) exit 1 ;;
esac
[ ${#3} -le 32 ] || exit 1
# dd opens with O_NOFOLLOW and O_TRUNC: a link swapped in after the checks above makes the write fail, never follow.
printf '%s' "$3" | dd of="$file" oflag=nofollow status=none
