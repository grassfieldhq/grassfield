#!/usr/bin/env bash
# The A2 limits of docs/specs/ui.md and tests/fixtures/icons/a2-limits.json (the data of tests/unit/tst_iconshader.qml) are one table: every
# cell of the JSON appears in the doc with its value and Default value, and the doc lists no cell that the JSON lacks. Every rule letter
# (E, I, S, N, D) is covered, in both directions. The table is EMPTY since 2026-11-08 (owner decision, R7-REQ-13: icon modes at 3:1 before 1.0):
# a row fails this script until the owner accepts an exception in writing and this check is relaxed on purpose.
# $1 (optional): the JSON to compare, for a mutation check on a copy.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
python3 -I - "$root" "${1:-}" <<'PY'
import json, re, sys
root = sys.argv[1]
src = sys.argv[2] or root + "/tests/fixtures/icons/a2-limits.json"
lim = json.load(open(src))["limits"]
doc = open(root + "/docs/specs/ui.md").read()
want = {"- `%s`: %.2f (Default %.2f)" % (e["key"], e["value"], e["default"]) for e in lim}
have = {l for l in doc.splitlines() if re.match(r"- `[EISND] ", l)}
missing = sorted(want - have)
extra = sorted(have - want)
for l in missing:
    print("FAIL: ui.md lacks " + l)
for l in extra:
    print("FAIL: ui.md lists a limit that a2-limits.json lacks: " + l)
if lim:
    print("FAIL: the A2 limits table must be empty (owner decision 2026-11-08, R7-REQ-13); it holds %d row(s)" % len(lim))
    sys.exit(1)
if missing or extra:
    sys.exit(1)
print("PASS: the A2 limits table is empty and docs/specs/ui.md lists none")
PY
