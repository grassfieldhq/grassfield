#!/usr/bin/env bash
# FINDINGS 6: the startup log printed "version unknown" because SystemInfo.grassfieldVersion was read before the VERSION file
# loaded. The real shell/services/SystemInfo.qml runs offscreen in the packaged layout (<root>/shell + <root>/VERSION, as
# /usr/share/grassfield has it): the very first read, in Component.onCompleted of the root, must already be the version.
# Needs qs; runs with QT_QPA_PLATFORM=offscreen (never without a display).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
if ! command -v qs >/dev/null; then echo "SKIP: no quickshell"; exit 0; fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/shellver.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

mkdir -p "$tmp/pkg/shell/services"
cp "$root/VERSION" "$tmp/pkg/VERSION"
cp "$root/shell/services/SystemInfo.qml" "$tmp/pkg/shell/services/SystemInfo.qml"
cat >"$tmp/pkg/shell/services/VisualFixtures.qml" <<'EOF'
pragma Singleton
import QtQuick
import Quickshell
Singleton {
    property bool active: false
    property string user: ""
    property string hostname: ""
}
EOF
printf 'singleton SystemInfo 1.0 SystemInfo.qml\nsingleton VisualFixtures 1.0 VisualFixtures.qml\n' >"$tmp/pkg/shell/services/qmldir"
cat >"$tmp/pkg/shell/shell.qml" <<'EOF'
import QtQuick
import Quickshell
import "services"
ShellRoot {
    Component.onCompleted: {
        console.log("VERSION-AT-START=" + SystemInfo.grassfieldVersion);
        Qt.callLater(() => Qt.quit());
    }
}
EOF
# Grassfield.Ui is installed system-wide by the package (/usr/lib/qt6/qml/Grassfield/Ui); here it comes from this tree, so the
# case does not depend on an installed Grassfield.
out=$(QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME='' QML_IMPORT_PATH="$root/ui${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}" \
  timeout 60 qs -n -p "$tmp/pkg/shell" --no-color 2>&1 || true)
want=$(tr -d '[:space:]' <"$root/VERSION")
desc="the first read of SystemInfo.grassfieldVersion in the packaged layout is $want, not unknown"
check bash -c 'grep -q "VERSION-AT-START=$2\$" <<<"$1"' _ "$out" "$want"
# The shell's one reader is that log line; About This Computer is Settings' window and shows Settings' compile-time VERSION
# (apps/settings/build-direct.sh; ADR-0040 step 1b).
desc="the startup log reads SystemInfo.grassfieldVersion and nothing writes it"
check bash -c 'grep -q "version\", SystemInfo.grassfieldVersion" "$1/shell/shell.qml" && ! grep -rq "grassfieldVersion *=" "$1/shell"' _ "$root"
exit "$fail"
