#!/usr/bin/env bash
# Stages an offscreen copy of the shell for a test that instantiates a module whose windows are PanelWindows (no layer-shell
# backend offscreen): every shell module is linked as is, except the modules named, which are copied with PanelWindow replaced
# by PanelStub (tests/shell/panel_stub.d/PanelStub.qml: a plain window with the panel's properties) and the WlrLayershell lines
# (an attached object only a layer surface has) left out. The rest of each file is the shipped code, unchanged.
#
#   stage.sh ROOT DEST MODULE...      (MODULE: a directory of shell/, e.g. dock)
#
# STAGE_SED, when set, is one more sed expression applied to the staged .qml files: a harness's seam (a data source the test
# feeds instead of the compositor), named in the harness's own script.
set -euo pipefail
root=$1 dest=$2
shift 2
mkdir -p "$dest"
for m in "$root"/shell/*/; do
  m=${m%/}
  ln -s "$m" "$dest/${m##*/}"
done
for mod in "$@"; do
  rm "$dest/$mod"
  mkdir "$dest/$mod"
  for f in "$root/shell/$mod"/*; do
    case $f in
      *.qml) sed -E -e 's/^( *)PanelWindow \{/\1PanelStub {/; /^ *WlrLayershell\./d' -e "${STAGE_SED:-}" "$f" >"$dest/$mod/${f##*/}" ;;
      */qmldir) cp "$f" "$dest/$mod/qmldir" ;;
      *) ln -s "$f" "$dest/$mod/" ;;
    esac
  done
  cp "$root/tests/shell/panel_stub.d/PanelStub.qml" "$root/tests/shell/panel_stub.d/PanelEdges.qml" "$dest/$mod/"
  printf 'PanelStub 1.0 PanelStub.qml\nPanelEdges 1.0 PanelEdges.qml\n' >>"$dest/$mod/qmldir"
done
