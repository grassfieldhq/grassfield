#!/bin/sh
# write-private.sh DIR FILE TEXT: writes TEXT to FILE (inside DIR) as a private state file, atomically: DIR is created 0700 and
# chmod 0700 when it already exists with other permissions, the temporary file is removed first (a stale 0644 one must not
# decide the mode), created under umask 077 and chmod 0600 before it replaces FILE. Used for airplane.json
# (shell/services/Connectivity.qml) and audio-routing.json (shell/services/Audio.qml, ADR-0047); tests/shell/write_private.sh.
# write-private.sh DIR FILE --stdin BYTES: the text is the next BYTES bytes of standard input (one command-line argument holds
# at most 128 KiB; commands.json, written by shell/search/CommandStore.qml, may be 256 KiB). A short input is an error and
# replaces nothing.
umask 077
dir=$1
file=$2
text=$3
bytes=
[ -n "$dir" ] && [ -n "$file" ] || exit 2
if [ "$3" = "--stdin" ]; then
    case $4 in '' | *[!0-9]*) exit 2 ;; esac
    bytes=$4
fi
mkdir -p -m 700 "$dir" || exit 1
chmod 700 "$dir" || exit 1
tmp=$file.tmp
rm -f "$tmp"
if [ -n "$bytes" ]; then
    timeout 10 head -c "$bytes" >"$tmp" || { rm -f "$tmp"; exit 1; }
    [ "$(wc -c <"$tmp")" -eq "$bytes" ] || { rm -f "$tmp"; exit 1; }
else
    printf '%s' "$text" >"$tmp" || exit 1
fi
chmod 600 "$tmp" || exit 1
mv -f "$tmp" "$file"
