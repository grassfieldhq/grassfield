#!/usr/bin/env bash
# rc7 audit R7-SEC-02 (ADR-0035 D-6): the screen-sharing picker stand-in takes a request only from a process of the shell's
# unit (packaging/session-bin/hyprland-share-picker peer_ok, the rule of grassfield-prompter's socket). Its cgroup rule, the
# expected unit by session (the dev plumbing GRASSFIELD_PICKER_PEER_UNIT only in a dev session), peer_ok on socket pairs (a
# peer of the expected cgroup, of another, a peer that has exited) and the accept loop; no listening socket, so it runs where
# socket() is refused. The end-to-end cases are tests/shell/share_picker.sh. The checks are share_picker.d/peer.py.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
unset GRASSFIELD_DEV GRASSFIELD_SESSION GRASSFIELD_PICKER_PEER_UNIT
python3 -I "$root/tests/shell/share_picker.d/peer.py" "$root"
