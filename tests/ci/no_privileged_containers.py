#!/usr/bin/env python3
"""No test or script may hand the host to a container (GF-010 follow-up, 2026-11-10).

`docker run --privileged` shares the host's /dev. tests/integration/update_migrate.sh did that with systemd as PID 1: the
container's systemd-vconsole-setup and udev ran on the host's devices, the kernel logged "fbcon: Taking over console", the
owner's Hyprland session received SIGHUP and SDDM could no longer take /dev/tty1. It happened three times in one day.

This check fails when a file under tests/ or scripts/ (and the workflows and the justfile) asks docker or podman for:
  - --privileged
  - --device (a host device node)
  - a bind mount of the host's /dev, /run/systemd or /var/run/systemd (-v, --volume or --mount)
  - --pid=host, --ipc=host, --uts=host, --userns=host (the host's namespaces)
Only files that mention docker or podman are read. Whole-line comments are not read: a comment may say what a test no longer does. This file is exempt (it names the patterns).

  python3 -I tests/ci/no_privileged_containers.py [--selftest]
Exit 0 clean, 1 a violation, 2 usage.
"""
import os
import re
import subprocess
import sys

SCAN_DIRS = ("tests", "scripts", ".github")
SCAN_FILES = ("justfile",)
EXEMPT = ("tests/ci/no_privileged_containers.py",)
SKIP_PARTS = ("node_modules", "__pycache__", "/.git/")

HOST_MOUNT = r"(?:/dev|/run/systemd|/var/run/systemd)(?:/[^:\s'\"]*)?"
RULES = [
    (re.compile(r"(?<![\w-])--privileged\b"), "--privileged shares the host's /dev with the container"),
    (re.compile(r"(?<![\w-])--device(?:[=\s]|$)"), "--device gives the container a host device node"),
    (re.compile(r"(?<![\w-])(?:-v|--volume)(?:=|\s+)['\"]?" + HOST_MOUNT + r"(?::|['\"\s]|$)"), "a bind mount of a host /dev or /run/systemd"),
    (re.compile(r"(?<![\w-])--mount(?:=|\s+)[^\n]*\b(?:src|source)=" + HOST_MOUNT + r"(?:[,'\"\s]|$)"), "a bind mount of a host /dev or /run/systemd"),
    (re.compile(r"(?<![\w-])--(?:pid|ipc|uts|userns)(?:=|\s+)host\b"), "the host's namespace shared with the container"),
]


def uses_containers(text):
    """Only a file that runs docker or podman can hand the host to a container (flatpak's --device is not this)."""
    return re.search(r"\b(?:docker|podman)\b", text) is not None


def violations(text, name):
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for rx, why in RULES:
            if rx.search(line):
                out.append("%s:%d: %s: %s" % (name, n, why, line.strip()[:160]))
                break
    return out


def files(root):
    for d in SCAN_DIRS:
        for base, dirs, names in os.walk(os.path.join(root, d)):
            dirs[:] = [x for x in dirs if x not in ("node_modules", "__pycache__", ".git")]
            for f in names:
                yield os.path.join(base, f)
    for f in SCAN_FILES:
        p = os.path.join(root, f)
        if os.path.isfile(p):
            yield p


def scan(root):
    found = []
    for path in files(root):
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        if rel in EXEMPT or any(s in "/" + rel for s in SKIP_PARTS):
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (UnicodeDecodeError, OSError):
            continue  # binary or unreadable: not a script
        if uses_containers(text):
            found += violations(text, rel)
    return found


def selftest():
    bad = [
        "docker run -d --privileged --cgroupns=private img",
        "args=(-d --privileged --network host)",
        "podman run --device /dev/kvm img",
        "docker run -v /dev:/dev img",
        "docker run --volume=/dev/pts:/dev/pts img",
        'docker run -v "/run/systemd:/run/systemd:ro" img',
        "docker run --mount type=bind,src=/dev,dst=/dev img",
        "docker run --mount type=bind,source=/run/systemd,target=/x img",
        "docker run --pid=host img",
        "docker run --userns host img",
    ]
    good = [
        "docker run --rm --network host -v \"$root:/src:ro\" img",
        "docker run -d --cap-add SYS_ADMIN --cgroupns=private --tmpfs /run img",
        "# docker run --privileged was the cause (a comment may say so)",
        "  # -v /dev:/dev",
        "docker run -v /devices-cache:/x img",
        "echo not-privileged and --privilege-free",
        "docker run -v \"$PWD/dev:/src/dev\" img",
        "docker run --mount type=bind,src=/home/me/dev,dst=/dev2 img",
    ]
    fails = 0
    for line in bad:
        if not violations(line, "x"):
            print("SELFTEST FAIL: not caught: " + line)
            fails += 1
    for line in good:
        if violations(line, "x"):
            print("SELFTEST FAIL: false positive: " + line)
            fails += 1
    if uses_containers("flatpak override --device=all x") or not uses_containers("exec docker run x"):
        print("SELFTEST FAIL: uses_containers")
        fails += 1
    print("no_privileged_containers selftest: %d bad and %d good lines, %d failures" % (len(bad), len(good), fails))
    return 1 if fails else 0


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest()
    if len(argv) > 1:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    root = subprocess.run(["git", "-C", os.path.dirname(os.path.abspath(__file__)), "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True, check=True).stdout.strip()
    found = scan(root)
    for v in found:
        print("FAIL " + v)
    if found:
        print("no_privileged_containers: %d violation(s): a container must never share the host's devices (see this file)" % len(found))
        return 1
    print("no_privileged_containers: ok (no --privileged, --device, host /dev or /run/systemd mount, host namespace under tests/ scripts/ .github justfile)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
