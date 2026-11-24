#!/bin/sh
# read-import.sh PATH: reads a file the person chose to import (shell/search/CommandStore.qml importFile) and prints "OK", a newline
# and its content (at most 1 MiB + 1 byte), or one line "ERR <reason>" and exits 0. Reasons: path (not absolute), link (the
# last part of the path is a symbolic link), missing, not-regular (a directory, FIFO, socket or device), not-yours (owned by
# another user), too-big (over 1 MiB), unreadable, changed (the path names another file than the one opened). Nothing is run
# or sourced: the content is only printed. The caller bounds the time (a FIFO swapped in after the checks would block the open).
umask 077
p=$1
err() { echo "ERR $1"; exit 0; }
case $p in /*) ;; *) err path ;; esac
[ -L "$p" ] && err link
[ -e "$p" ] || err missing
[ -f "$p" ] || err not-regular
[ -O "$p" ] || err not-yours
size=$(stat -c %s -- "$p") || err unreadable
[ "$size" -le 1048576 ] || err too-big
before=$(stat -c %d:%i -- "$p") || err unreadable
# One open: the checks and the read are on the same descriptor (a failed redirection of a group does not end a POSIX shell).
{
    after=$(stat -L -c %d:%i:%F:%u /dev/fd/3) || err unreadable
    [ "$after" = "$before:regular file:$(id -u)" ] || err changed
    echo OK
    head -c 1048577 <&3
    :
} 3<"$p" || err unreadable
