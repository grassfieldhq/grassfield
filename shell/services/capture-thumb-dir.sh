#!/bin/sh
# The floating thumbnail's private folder for the pictures it shows (docs/specs/security-images.md, "Store"). Usage:
#   capture-thumb-dir.sh FOLDER
# FOLDER is $XDG_RUNTIME_DIR/grassfield/capture-thumbs (the last name is required). Makes it 0700 (and its parent, which the
# capture acknowledgement already keeps 0700), refuses a link at either, refuses a folder that is not the user's own, and empties
# it: only plain files and links directly in it are removed, never anything below and never through a link. Run when the shell
# starts and when the last card leaves. Exit 0 ready; 1 refused. Tested by tests/shell/capture_thumb_copy.sh.
umask 077
folder=$1
case $folder in
    /*/capture-thumbs) ;;
    *) exit 1 ;;
esac
parent=${folder%/*}
[ ! -L "$parent" ] || exit 1
mkdir -p -m 700 -- "$parent" || exit 1
[ ! -L "$parent" ] && [ -d "$parent" ] && [ -O "$parent" ] || exit 1
chmod 700 -- "$parent" || exit 1
[ ! -L "$folder" ] || exit 1
mkdir -p -m 700 -- "$folder" || exit 1
[ ! -L "$folder" ] && [ -d "$folder" ] && [ -O "$folder" ] || exit 1
chmod 700 -- "$folder" || exit 1
for f in "$folder"/* "$folder"/.[!.]*; do
    if [ -f "$f" ] || [ -L "$f" ]; then
        rm -f -- "$f"
    fi
done
exit 0
