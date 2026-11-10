#!/usr/bin/env bash
# tests/security/pam_audit.sh counts the PAM attempts of this tree's Quickshell instances from their per-instance logs, found by the
# config path their first lines name. In a `--migrated` nested run (ADR-0056) the instances are started on
# <tree>/.dev/migrated-<stamp>/shell, and the count read 0 (l2_wrong_password: "audit: 0 PAM attempts (want 3)" although PAM ran).
# Offscreen: fake instance logs under a fake XDG_RUNTIME_DIR.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/pamaudit.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

mk() { # id, config path, submits
  mkdir -p "$tmp/quickshell/by-id/$1"
  { echo "2026-11-10 12:00:00.000  INFO: Launching config: \"$2\""; echo "2026-11-10 12:00:00.001  INFO: Shell ID: x"
    for _ in $(seq 1 "$3"); do echo "2026-11-10 12:00:05.000  INFO qml: grassfield-lock: authenticating (submit)"; done
    echo "2026-11-10 12:00:06.000  WARN qml: grassfield-lock: dev: PAM submit suppressed"
  } >"$tmp/quickshell/by-id/$1/log.log"
}
mk src "$root/shell/security.qml" 2
mk mig "$root/.dev/migrated-0123456789abcdef/shell/security.qml" 3
mk migui "$root/.dev/migrated-0123456789abcdef/shell/shell.qml" 0
mk legacy "$root/.dev/migrated/shell/security.qml" 1
mk old "$root/.dev/migrated-legacy/shell/security.qml" 1
mk other "/home/someone/else/shell/security.qml" 9
mk otherdev "/home/someone/else/.dev/migrated-0123456789abcdef/shell/security.qml" 9
mk notstamp "$root/.dev/migrated-XYZ/shell/security.qml" 9
mk sub "$root/.dev/migrated-0123456789abcdef/shell/lib/Mode.qml" 9

counts=$(XDG_RUNTIME_DIR=$tmp bash -c '. "$1"; pam_counts' _ "$root/tests/security/pam_audit.sh")
desc="the audit counts the source form and every migrated form of this tree, and nothing else (instances 5, submits 2+3+0+1+1 = 7, suppressed 5)"
check test "$counts" = "5 7 5"
exit "$fail"
