#!/bin/sh
# The floating thumbnail's file actions (ADR-0066 D-9, slice A3). Usage: capture-thumb.sh ACTION KIND PATH ROOT...
#   ACTION  check (nothing but the checks), copy (the picture onto the clipboard) or trash (gio trash)
#   KIND    shot or recording
#   PATH    the capture's file, as the helper's result file names it: data, never trusted for being named there
#   ROOT    every Save to folder (CaptureThumbs.roots)
# PATH is acted on only when it is an absolute path, no hidden name, with the extension of its kind, a regular file (not a link,
# not a folder) whose folder, once links are resolved, is one of the ROOTs once links are resolved. For copy, the file is opened
# once and the open file must be that very file (a link swapped in after the checks makes it fail). Exit 0 done; 1 refused or
# failed; 2 bad usage. Tested by tests/shell/capture_thumb.sh.
umask 077
[ $# -ge 4 ] || exit 2
action=$1
kind=$2
path=$3
shift 3
case $action in
    check | copy | trash) ;;
    *) exit 2 ;;
esac
case $kind in
    shot | recording) ;;
    *) exit 2 ;;
esac
case $path in
    /*) ;;
    *) exit 1 ;;
esac
# No control character in a path: a newline first (grep reads by line), then the rest.
case $path in
    *'
'*) exit 1 ;;
esac
if printf '%s' "$path" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    exit 1
fi
name=${path##*/}
folder=${path%/*}
[ -n "$name" ] && [ -n "$folder" ] || exit 1
case $name in
    .* | *'/'*) exit 1 ;;
esac
ext=$(printf '%s' "${name##*.}" | LC_ALL=C tr 'A-Z' 'a-z')
[ "$ext" != "$name" ] || exit 1
mime=
case $kind:$ext in
    shot:png) mime=image/png ;;
    shot:jpg | shot:jpeg) mime=image/jpeg ;;
    shot:webp) mime=image/webp ;;
    recording:mp4 | recording:mkv | recording:webm | recording:mov) ;;
    *) exit 1 ;;
esac
# A link at the path is refused, and so is anything that is not a regular file (a folder named like a picture).
[ ! -L "$path" ] || exit 1
[ -f "$path" ] || exit 1
real=$(cd -P -- "$folder" 2>/dev/null && pwd -P) || exit 1
found=1
for root in "$@"; do
    resolved=$(cd -P -- "$root" 2>/dev/null && pwd -P) || continue
    if [ "$resolved" = "$real" ]; then
        found=0
        break
    fi
done
[ "$found" = 0 ] || exit 1
case $action in
    check)
        exit 0
        ;;
    copy)
        [ -n "$mime" ] || exit 1
        exec 3<"$path" || exit 1
        # The open file is the one that was checked: its own path, links resolved, is the checked folder and name.
        [ "$(readlink -f -- "/proc/$$/fd/3")" = "$real/$name" ] || exit 1
        [ -f "/proc/$$/fd/3" ] || exit 1
        exec wl-copy --type "$mime" <&3
        ;;
    trash)
        exec gio trash -- "$path"
        ;;
esac
