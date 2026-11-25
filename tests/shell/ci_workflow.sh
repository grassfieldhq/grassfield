#!/usr/bin/env bash
# The CI job (.github/workflows/ci.yml, scripts/gates/ci.sh), offline: ci.sh's pure parts on fixtures (the dependency reader,
# the scope of the checks, the refusal of the installing steps outside a CI runner's container, the test summary), and the
# workflow's shape: the triggers, the archlinux:latest container with no option, device or host mount (ADR-0057), the history
# for the secret scan, the setup and pinned-toolkit steps as root, the checks and tests as the unprivileged user, the summary
# uploaded. The YAML is parsed when PyYAML is installed (python-yaml), read line by line otherwise. Layer: logic.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fails=0
bash "$root/scripts/gates/ci.sh" --selftest || fails=$((fails + 1))

python3 -I - "$root/.github/workflows/ci.yml" <<'PY' || fails=$((fails + 1))
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
fails = []

def expect(name, ok):
    print(("  ok   " if ok else "  FAIL ") + name)
    if not ok:
        fails.append(name)

code = "\n".join(line.split(" #", 1)[0] for line in text.splitlines() if not line.lstrip().startswith("#"))
try:
    import yaml
    doc = yaml.safe_load(text)
    on = doc.get("on", doc.get(True))
    job = doc["jobs"]["check-and-test"]
    steps = job["steps"]
    runs = [s.get("run", "") for s in steps]
    uses = [s["uses"] for s in steps if "uses" in s]
    expect("yaml: pull requests and pushes to main", "pull_request" in on and on["push"]["branches"] == ["main"])
    expect("yaml: read-only token", doc.get("permissions") == {"contents": "read"})
    expect("yaml: the archlinux:latest container, no other key (no options, volumes, ports)", job["container"] == {"image": "archlinux:latest"})
    checkout = next(s for s in steps if s.get("uses", "").startswith("actions/checkout@"))
    expect("yaml: the whole history (gitleaks scans it)", checkout.get("with", {}).get("fetch-depth") == 0)
    expect("yaml: git is installed before the checkout", steps.index(checkout) > 0 and "git" in steps[0].get("run", ""))
    order = [next((i for i, r in enumerate(runs) if k in r), -1) for k in ("ci.sh scope", "ci.sh setup", "ci.sh toolkit", "ci.sh check", "ci.sh test")]
    expect("yaml: scope, setup, toolkit, check, test in this order", -1 not in order and order == sorted(order))
    expect("yaml: the checks and the tests run as the unprivileged user",
           all(r.startswith("runuser -u builder -- ") for r in runs if "ci.sh check" in r or "ci.sh test" in r))
    expect("yaml: the checks and the tests run in setup's copy in the user's home, their logs in the workspace",
           all("/home/builder/grassfield/scripts/gates/ci.sh" in r and '"$GITHUB_WORKSPACE/.dev/ci"' in r and "HOME=/home/builder" in r
               for r in runs if "ci.sh check" in r or "ci.sh test" in r))
    expect("yaml: clang-tidy is installed when the scope is full", "steps.scope.outputs.scope == 'full' && '--tidy'" in next(r for r in runs if "ci.sh setup" in r))
    upload = [s for s in steps if s.get("uses", "").startswith("actions/upload-artifact@")]
    expect("yaml: the test summary is uploaded, also after a failure",
           len(upload) == 1 and ".dev/ci/test-summary.txt" in upload[0]["with"]["path"] and "cancelled()" in upload[0].get("if", ""))
    expect("yaml: the tests run even when a check failed", "!cancelled()" in next(s for s in steps if "ci.sh test" in s.get("run", "")).get("if", ""))
    expect("yaml: every action pinned to a major version", all(re.fullmatch(r"[\w-]+/[\w-]+@v\d+", u) for u in uses))
    expect("yaml: the tests wait for the pinned toolkit", "steps.toolkit.outcome == 'success'" in next(s for s in steps if "ci.sh test" in s.get("run", "")).get("if", ""))
    # The matrix splits `just test` without dropping anything: every layer of a default run once, the gtest suites (they belong to
    # the logic layer) in shards 0..N-1 of the same N, and the one part that runs no tests is the checks.
    parts = job["strategy"]["matrix"]["include"]
    args = [p.get("args", "") for p in parts]
    layers = [l for a in args if "--layer" in a for l in a.split("--layer ", 1)[1].split()[0].split(",")]
    shards = [tuple(map(int, a.split("--gtest-shard ", 1)[1].split()[0].split("/"))) for a in args if "--gtest-shard" in a]
    expect("yaml: matrix: the checks part has no test arguments", [p["part"] for p in parts if not p.get("args")] == ["checks"])
    # The layers a CI container can run: data, logic, headless. The nested layer needs a compositor session (its scripts all SKIP
    # without one, and naming it makes test.sh gate it: "every check skipped"), so it is left out on purpose, and so is visual.
    expect("yaml: matrix: data, logic and headless are each run exactly once; nested and visual are not (no compositor here)",
           sorted(layers) == ["data", "headless", "logic"])
    expect("yaml: matrix: the logic layer is run without the gtest suites, which are the shards",
           all("--skip-gtest" in a for a in args if "logic" in a) and len(shards) > 0)
    expect("yaml: matrix: the gtest shards are 0..N-1 of one N, each once",
           len({n for _, n in shards}) == 1 and sorted(i for i, _ in shards) == list(range(shards[0][1])))
    gate = doc["jobs"].get("check-and-test-result", {})
    expect("yaml: one final job, named as the single job was, needs the matrix job and runs always",
           gate.get("name") == "check and test (Arch Linux)" and gate.get("needs") == "check-and-test" and "always()" in str(gate.get("if", "")))
    expect("yaml: the final job fails unless the matrix result is success", any("= success" in st.get("run", "") for st in gate.get("steps", [])))
    expect("yaml: matrix: every part is a distinct name", len({p["part"] for p in parts}) == len(parts))
    expect("yaml: the job has a timeout (a stuck run does not take hours)", isinstance(job.get("timeout-minutes"), int) and job["timeout-minutes"] <= 120)
except ImportError:
    print("  SKIP the parsed checks (PyYAML not installed: pacman -S python-yaml); the line checks still run")
# Line checks, PyYAML or not: the container rules of tests/ci/no_privileged_containers.py, spelled for a workflow.
expect("text: one container image, archlinux:latest", re.findall(r"^\s+image:\s*(\S+)", code, re.M) == ["archlinux:latest"])
for bad, why in ((r"^\s*options\s*:", "no container options"), (r"^\s*volumes\s*:", "no volume"), (r"--privileged", "no --privileged"),
                 (r"--device", "no --device"), (r"(?<![\w/.])/dev(?:/|\b)(?!/null)", "no host /dev"), (r"/run/systemd", "no /run/systemd"),
                 (r"--cap-add", "no added capability"), (r"\bsudo\b", "no sudo")):
    expect("text: " + why, re.search(bad, code, re.M) is None)
if fails:
    print("workflow: %d failure(s)" % len(fails))
    sys.exit(1)
PY

# The shard table of test.sh lists every gtest suite once (a suite missing from it still runs, in its K mod N shard, but the
# balance is then a guess), and every shard of four has a suite.
suites=$(grep -o '^gtest_suite tests/unit/[a-z-]*' "$root/scripts/dev/test.sh" | cut -d' ' -f2 | sort)
table=$(grep -o '\[tests/unit/[a-z-]*\]=[0-9]' "$root/scripts/dev/test.sh" | sort)
if [[ $suites == "$(sed 's/\]=.*//;s/^\[//' <<<"$table")" && $(sed 's/.*=//' <<<"$table" | sort -u | tr -d '\n') == 0123 ]]; then
  echo "  ok   test.sh: the shard table lists every gtest suite, and each of the four shards has some"
else
  echo "  FAIL test.sh: the shard table (gtest_shard4) and the gtest_suite calls differ, or a shard has no suite"
  fails=$((fails + 1))
fi

if ((fails == 0)); then echo "PASS ci_workflow"; else echo "FAIL ci_workflow: $fails"; exit 1; fi
