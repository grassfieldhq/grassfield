#!/usr/bin/env python3
"""No test, gate or script may hand the host to a container (GF-010 follow-up, 2026-11-11).

`docker run --privileged` shares the host's /dev. tests/integration/update_migrate.sh did that with systemd as PID 1: the
container's systemd-vconsole-setup and udev ran on the host's devices, the owner's Hyprland session received SIGHUP and SDDM could
no longer take /dev/tty1. It happened three times on 2026-11-11 (16:47, 19:13, 20:28).

A denylist of flags cannot hold (--device-cgroup-rule, -v /run:/run, -v/dev:/dev, -v //dev:/dev, --cgroupns=host, --cap-add ALL,
--security-opt systempaths=unconfined, flags split over a `\\` line or kept in a variable or an array are all ways to the same
place). So this is an ALLOWLIST by construction:

  1. Every tracked shell, python, just, yaml, cmake or similar file is read (continuations joined). A call of docker, podman,
     nerdctl, buildah or docker-compose is refused EVERYWHERE except tests/integration/container.sh, with one exception:
     `docker info` (is a daemon there?). A variable that holds such a command name is refused too. Compose files, Dockerfiles and
     Containerfiles are refused. A yaml `options:` line is refused.
  2. tests/integration/container.sh is the only wrapper. Inside it every docker call must be one of five exact spellings, and
     every statement that adds to `gf_args` (the only option array) or to `envs` must be one of a short list of exact statements
     (a mount `-v "$src:$2:$mode"` whose source gf_mount validates at run time, `--network none|host`, `-e "$v"`, and update_migrate's
     systemd set: CAP_SYS_ADMIN minus MKNOD, a private cgroup namespace, tmpfs /run /run/lock /tmp, no device, no host path).
     A variable, an array expansion or a flag the guard cannot resolve is therefore a failure, never a pass.
  3. CAP_SYS_ADMIN is only in gf_container_systemd_start, which only tests/integration/update_migrate.sh may call.
  4. The wrapper's own arrays (gf_args, gf_trees, gf_stages) are not touched outside the wrapper.
  5. Every tracked text file is read, whatever its extension (shell, python, lua, .service, .desktop, zsh, extensionless
     executables, QML, C++, JS ...), except docs/, markdown and this file. A line of product code that merely names docker is
     listed in ALLOW by exact file and exact line text; nothing else is waived.
Comments are not read. This file is exempt (it spells the cases).

WHAT THIS IS, AND IS NOT (integrator decision, 2026-11-12; ADR-0057). This guard is a LINT against ACCIDENTAL reintroduction of a
container that shares the host, by people or agents. It is NOT a sandbox against deliberately written code: a determined author can
spell a call in ways no static scan resolves (a string built at run time, an interpreter, an encoded payload). The real boundaries
are at RUN TIME: (1) the wrapper refuses anything dangerous it is handed (tests/shell/container_wrapper.sh proves each refusal fires
before docker is called); (2) update_migrate.sh fails closed outside a virtual machine (tests/shell/update_migrate_refusal.sh);
(3) the virtual machine itself, the only place that script runs (scripts/gates/vm-drill.sh update-migrate).

  python3 -I tests/ci/no_privileged_containers.py [--selftest]
Exit 0 clean, 1 a violation, 2 usage.
"""
import os
import re
import subprocess
import sys

WRAPPER = "tests/integration/container.sh"
SYSTEMD_USER = "tests/integration/update_migrate.sh"
EXEMPT = ("tests/ci/no_privileged_containers.py",)
CLI = r"(?:docker|podman|nerdctl|buildah|docker-compose)"
CLI_PATH = r"(?:/[\w.+-]+)*/"  # an absolute path before the name: /usr/bin/docker, /usr/local/bin/podman
# Product code that names docker without running a container: (file, exact stripped line). Empty unless a scan finds one.
ALLOW = set()
# Test files that exercise the wrapper itself (stub docker, no container) may name its arrays and its systemd start.
WRAPPER_TESTS = ("tests/shell/container_wrapper.sh",)
SHELLISH = (".sh", ".bash", ".zsh", ".py", ".just", ".yml", ".yaml", ".in", ".mk", ".cmake")
STRINGISH = (".cpp", ".h", ".hpp", ".cc", ".qml", ".js", ".ts", ".mjs")
BASENAMES = ("justfile", "Makefile", "makefile", "CMakeLists.txt")
SKIP_PARTS = ("node_modules/", "__pycache__/", ".dev/", "docs/", "translations/")
CONTAINER_FILES = re.compile(r"(^|/)(docker-compose[^/]*\.ya?ml|compose\.ya?ml|Dockerfile[^/]*|Containerfile[^/]*|\.devcontainer[^/]*)$")

# What may stand before a command word on its command line: wrappers, options, assignments, a yaml key or list dash, a recipe's @.
PREFIX_OK = re.compile(r"""^(?:\s*(?:@|-|exec|sudo|env|nohup|time|then|do|else|if|elif|while|until|!|command|builtin|timeout|nice|
    setsid|stdbuf|xargs|COMMAND|run|[\w.-]+:|\w+=\S*|-\S+|\d+))*\s*$""", re.X)
# Commands that run another command, with arguments of their own (flock FILE, timeout 5s, systemd-run --user, xargs -n1 ...).
RUNNERS = {"sudo", "doas", "su", "env", "exec", "command", "builtin", "nice", "ionice", "timeout", "xargs", "flock", "unshare",
           "systemd-run", "nohup", "setsid", "stdbuf", "time", "chroot", "runuser", "script", "watch", "parallel", "ssh"}
# A command found by lookup and then run: "$(command -v docker)" run, `which podman`, $(type -P docker).
RESOLVED = re.compile(r"(?:\$\(|`)\s*(?:command\s+-[vV]|which|type\s+-[pP]|whereis)\s+[\"']?(?:" + CLI_PATH + r")?" + CLI + r"(?![\w-])")
SEP = re.compile(r"""(;|&&|\|\||\||\(|\{|\$\(|`)""")

WRAPPER_CALLS = [
    r'info( >/dev/null 2>&1)?',
    r'rm -f "\$gf_cid" >/dev/null 2>&1',
    r'run --rm "\$\{gf_args\[@\]\}" "\$@"',
    r'run "\$\{gf_args\[@\]\}" "\$image" bash -c "\$script" "\$mask"',
    r'exec "\$\{envs\[@\]\}" "\$id" "\$@"',
]
SYSTEMD_SET = '-d --cap-add SYS_ADMIN --cap-drop MKNOD --cgroupns=private --tmpfs /run --tmpfs /run/lock --tmpfs /tmp -e container=docker'
WRAPPER_ARRAYS = {
    "gf_args": ["-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*'", '-v "$src:$2:$mode"', "--network none", "--network host", '-e "$v"', SYSTEMD_SET, ""],
    "envs": ['-e "$v"', ""],
}


def logical_lines(text):
    """(line number, text) with `\\` continuations joined; whole-line comments dropped."""
    out, buf, start = [], "", 0
    for n, line in enumerate(text.split("\n"), 1):
        if not buf:
            start = n
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        buf += line
        if not buf.lstrip().startswith("#"):
            out.append((start, buf))
        buf = ""
    if buf and not buf.lstrip().startswith("#"):
        out.append((start, buf))
    return out


def calls(line):
    """Yield (word, rest) for every container CLI used as a command on this logical line."""
    line = line.replace("{}", "_")  # xargs -I{} is a placeholder, not a brace group
    for m in re.finditer(r"(?<![\w.-])(?:" + CLI_PATH + r")?(" + CLI + r")(?![\w/-])", line):
        before = line[:m.start()]
        seps = list(SEP.finditer(before))
        prefix = before[seps[-1].end():] if seps else before
        adjacent_quote = before[-1:] in ("'", '"')
        if re.search(r"\bcommand\s+-[vV]\s*$", prefix):
            continue  # `command -v docker`: a lookup, not a call
        if not (PREFIX_OK.match(prefix) or adjacent_quote or any(t in RUNNERS for t in prefix.split())):
            continue
        rest = line[m.end():]
        end = re.search(r"(;|&&|\|\||\||\))", rest)
        yield m.group(1), (rest[:end.start()] if end else rest).strip()


def info_only(rest):
    toks = [t for t in rest.split() if not re.match(r"^\d*[<>&]", t)]
    return toks[:1] == ["info"] and len(toks) == 1


def stmt_arrays(text):
    """(number, array name, op, content) for `name=(...)` and `name+=(...)` statements (one line)."""
    for n, line in logical_lines(text):
        for m in re.finditer(r"\b(gf_args|envs)(\+?)=\((.*?)\)(?=\s*(?:$|[;&|]|\|\|))", line):
            yield n, m.group(1), m.group(2), m.group(3).strip()


def functions(text):
    """name -> (first line, last line) of each `name() {` ... `}` at the left margin."""
    out, cur, start = {}, None, 0
    for n, line in enumerate(text.split("\n"), 1):
        m = re.match(r"^([A-Za-z_]\w*)\(\) \{", line)
        if m:
            cur, start = m.group(1), n
        elif line.startswith("}") and cur:
            out[cur] = (start, n)
            cur = None
    return out


def check_text(rel, text):
    out = []
    base = os.path.basename(rel)
    if CONTAINER_FILES.search(rel):
        return ["%s: a compose, Dockerfile or Containerfile: containers are built only by tests/integration/container.sh" % rel]
    ext = os.path.splitext(rel)[1]
    if ext in STRINGISH:
        for m in re.finditer(r"""["'](?:""" + CLI_PATH + r""")?(""" + CLI + r""")(?:["']|\s)""", text):
            out.append("%s:%d: a container CLI named in code: only tests/integration/container.sh runs docker" % (rel, text[:m.start()].count("\n") + 1))
        return out
    is_wrapper = rel == WRAPPER
    shellish = ext in SHELLISH or base in BASENAMES or text.startswith("#!")
    if ext == ".py":
        for m in re.finditer(r"""["'](?:""" + CLI_PATH + r""")?(""" + CLI + r""")["']""", text):
            nxt = text[m.end():]
            if not re.match(r"""\s*,\s*["']info["']\s*[\],)]""", nxt):
                out.append("%s:%d: a container CLI in python outside `docker info`: %s" % (rel, text[:m.start()].count("\n") + 1, nxt[:60].strip().replace("\n", " ")))
        for m in re.finditer(r"""["'](?:""" + CLI_PATH + r""")?(""" + CLI + r""")\s+(?!info\b)\S""", text):
            out.append("%s:%d: a container command line in a python string: %s" % (rel, text[:m.start()].count("\n") + 1, text[m.start():m.start() + 60].replace("\n", " ")))
        return out
    if not shellish:  # lua, .service, .desktop, extensionless files ...: a quoted command line is a call too
        for m in re.finditer(r"""["'](?:""" + CLI_PATH + r""")?(""" + CLI + r""")(?:["']|\s+(?!info\b)\S)""", text):
            out.append("%s:%d: a container CLI named in a quoted string: %s" % (rel, text[:m.start()].count("\n") + 1, text[m.start():m.start() + 60].replace("\n", " ")))
    for n, line in logical_lines(text):
        if RESOLVED.search(line):
            out.append("%s:%d: a container CLI found by lookup and then run: %s" % (rel, n, line.strip()[:120]))
        if re.search(r"""\b\w+=["']?(?:""" + CLI_PATH + r""")?""" + CLI + r"""(?![\w-])""", line.replace(SYSTEMD_SET, "")):
            out.append("%s:%d: a variable holding a container CLI (its flags could not be checked): %s" % (rel, n, line.strip()[:120]))
        m = re.match(r"^\s*options:\s*(.*)$", line)
        if m and re.search(r"(^|\s)-", m.group(1)):
            out.append("%s:%d: a yaml container `options:` line: %s" % (rel, n, line.strip()[:120]))
        for word, rest in calls(line):
            if is_wrapper:
                if not any(re.fullmatch(c, rest) for c in WRAPPER_CALLS) or word != "docker":
                    out.append("%s:%d: a %s call that is not one of the wrapper's five exact spellings: %s %s" % (rel, n, word, word, rest[:120]))
            elif not info_only(rest):
                out.append("%s:%d: %s %s: containers are run only through tests/integration/container.sh (`docker info` is the one direct call)" % (rel, n, word, rest[:100]))
    if is_wrapper:
        fns = functions(text)
        for n, name, op, content in stmt_arrays(text):
            if content not in WRAPPER_ARRAYS[name] or (op == "" and content != ""):
                out.append("%s:%d: %s%s=(%s) is not one of the wrapper's allowed option statements" % (rel, n, name, op, content))
            if content == SYSTEMD_SET:
                lo, hi = fns.get("gf_container_systemd_start", (0, -1))
                if not lo <= n <= hi:
                    out.append("%s:%d: the systemd option set (CAP_SYS_ADMIN) is only allowed inside gf_container_systemd_start" % (rel, n))
        for n, line in logical_lines(text):
            if SYSTEMD_SET in line:
                continue
            if re.search(r"--(privileged|device|pid|ipc|uts|userns|security-opt|volume|mount|group-add|ulimit|sysctl|add-host|cap-add|cgroupns)\b", line):
                out.append("%s:%d: a forbidden container option in the wrapper: %s" % (rel, n, line.strip()[:120]))
        # an option array other than the two allowed ones that reaches a docker call
        for n, line in logical_lines(text):
            for m in re.finditer(r'"\$\{(\w+)\[@\]\}"', line):
                if m.group(1) in ("gf_args", "envs"):
                    continue
                if re.search(r"(?<![\w./-])" + CLI + r"(?![\w-])", line):
                    out.append("%s:%d: a docker call with an array the guard does not check (%s)" % (rel, n, m.group(1)))
    elif rel not in WRAPPER_TESTS:
        for n, line in logical_lines(text):
            if re.search(r"\b(gf_args|gf_trees|gf_stages)\b", line):
                out.append("%s:%d: the wrapper's option arrays are not touched outside tests/integration/container.sh" % (rel, n))
            if re.search(r"\bgf_container_systemd_start\b", line) and rel != SYSTEMD_USER:
                out.append("%s:%d: only %s may start a container with systemd (CAP_SYS_ADMIN)" % (rel, n, SYSTEMD_USER))
    return [v for v in out if not allowed(rel, text, v)]


def allowed(rel, text, violation):
    """A violation on a line listed in ALLOW (exact file, exact stripped line text)."""
    m = re.match(r"^[^:]+:(\d+):", violation)
    if not m:
        return False
    lines = text.split("\n")
    n = int(m.group(1))
    return 0 < n <= len(lines) and (rel, lines[n - 1].strip()) in ALLOW


def tracked(root):
    try:
        raw = subprocess.run(["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"], capture_output=True, check=True).stdout
        return [p for p in raw.decode().split("\0") if p]
    except (subprocess.CalledProcessError, FileNotFoundError):
        found = []
        for base, dirs, names in os.walk(root):
            dirs[:] = [d for d in dirs if d not in ("node_modules", "__pycache__", ".git", ".dev")]
            found += [os.path.relpath(os.path.join(base, n), root) for n in names]
        return found


def scan(root):
    found = []
    for rel in tracked(root):
        rel = rel.replace(os.sep, "/")
        if rel in EXEMPT or any(("/" + rel).find("/" + s) >= 0 for s in SKIP_PARTS) or rel.endswith(".md"):
            continue
        path = os.path.join(root, rel)
        if CONTAINER_FILES.search(rel):
            found.append("%s: a compose, Dockerfile or Containerfile: containers are built only by tests/integration/container.sh" % rel)
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (UnicodeDecodeError, OSError):
            continue
        found += check_text(rel, text)
    return found


BAD_CALLS = [
    "docker run --privileged img",
    "docker run -d --privileged --cgroupns=private img",
    "podman run --device /dev/kvm img",
    "docker run --device-cgroup-rule 'c 4:* rwm' img",
    "docker run -v /dev:/dev img",
    "docker run -v/dev:/dev img",
    "docker run -v //dev:/dev img",
    "docker run --volume=/dev/pts:/dev/pts img",
    'docker run -v "/run/systemd:/run/systemd:ro" img',
    "docker run -v /run:/run img",
    "docker run -v /:/host img",
    "docker run -v /run/dbus:/run/dbus img",
    "docker run -v /run/user/1000:/run/user/1000 img",
    "docker run --mount type=bind,src=/dev,dst=/dev img",
    "docker run --mount type=bind,source=/run/systemd,target=/x img",
    "docker run --security-opt systempaths=unconfined img",
    "docker run --security-opt seccomp=unconfined img",
    "docker run --cgroupns=host img",
    "docker run --cgroupns host img",
    "docker run --cap-add ALL img",
    "docker run --cap-add=SYS_ADMIN img",
    "docker run --pid=host img",
    "docker run --ipc host img",
    "docker run --uts=host img",
    "docker run --userns host img",
    "docker run --network host img",
    "docker run \\\n  --privileged \\\n  img",
    "docker run --rm \\\n  -v /dev:/dev img",
    'docker run "${args[@]}" img',
    'docker run "${flags}" img',
    'docker run $FLAGS img',
    "exec docker run --rm img",
    "sudo docker run img",
    "sudo -E docker run img",
    "env FOO=1 docker run img",
    "timeout 5 docker run img",
    'bash -c "docker run --privileged img"',
    "x=$(docker run -d img)",
    "echo y | docker run -i img",
    "if docker run img; then :; fi",
    "docker exec --privileged c sh",
    "docker exec c sh",
    "docker create img",
    "docker cp a c:/b",
    "docker start c",
    "docker build .",
    "docker compose up",
    "docker-compose up",
    "docker -H tcp://host:2375 info",
    "docker --context other info",
    "docker info --format x",
    "podman run img",
    "nerdctl run img",
    "buildah bud .",
    "DOCKER=docker",
    "CLI=podman",
    'CLI="docker"',
    "@docker run img",
    "  run: docker run --privileged img",
    "  - docker run img",
    "  options: --privileged",
    "  options: --cap-add SYS_ADMIN",
    "COMMAND docker run img",
    # round-3 probes: absolute paths, resolved commands, runners with arguments
    "/usr/bin/docker run --privileged img",
    "/usr/local/bin/podman run img",
    "/opt/x/bin/nerdctl run img",
    "/usr/bin/buildah bud .",
    'exec /usr/bin/docker run img',
    '"$(command -v docker)" run --privileged img',
    '"$(which docker)" run img',
    '$(which podman) run img',
    'd=$(command -v docker); "$d" run img',
    'x=`which docker`',
    'dk=$(type -P docker)',
    "systemd-run --user --pty docker run img",
    "systemd-run --user --scope -p MemoryMax=1G /usr/bin/docker run img",
    "flock /tmp/lock docker run img",
    "flock -n 9 docker run img",
    "doas docker run img",
    "unshare -m docker run img",
    "unshare --mount --map-root-user /usr/bin/docker run img",
    "env docker run img",
    "env -i PATH=/usr/bin docker run img",
    "exec docker run img",
    "command docker run img",
    "nice -n 5 docker run img",
    "ionice -c3 docker run img",
    "timeout 5s docker run img",
    "timeout --signal=KILL 60 docker run img",
    "echo img | xargs docker run",
    "echo img | xargs -n1 -I{} docker run {}",
    "nohup docker run img &",
    "setsid docker run img",
    "bash -c 'docker run --privileged img'",
    "sh -c '/usr/bin/docker run img'",
    "ssh host docker run img",
    "ExecStart=/usr/bin/docker run img",
    "Exec=docker run img",
]
GOOD_CALLS = [
    "docker info >/dev/null 2>&1",
    "command -v docker >/dev/null && docker info >/dev/null 2>&1 || exit 0",
    'echo "SKIP: no docker daemon (this test runs only in a throwaway container)"',
    "# docker run --privileged was the cause (a comment may say so)",
    "gf_container_run \"$IMAGE\" bash /src/tests/integration/x.sh --inside",
    "gf_standard auto || exit 2",
    'omarchy_mounts "$omarchy" /omarchy || exit 2',
    "echo not-privileged and --privilege-free",
    "flatpak override --device=all x",
    "exec \"$cmd\" --device=all",
]
PY_BAD = [
    'os.system("docker run --privileged img")',
    'os.system("/usr/bin/docker run img")',
    'os.popen("podman run img")',
    'subprocess.Popen(["/usr/bin/docker", "run", "img"])',
    'subprocess.check_call(["/usr/local/bin/podman", "run"])',
    'subprocess.run("docker run img", shell=True)',
    'subprocess.run(f"docker run {img}", shell=True)',
    'shutil.which("docker")',
    'subprocess.Popen(["nerdctl", "run", img])',
    'subprocess.run(["buildah", "bud"])',
    'subprocess.run(["docker", "run", "--privileged", "img"])',
    'subprocess.run(["docker",\n    "run", "img"])',
    'cmd = ["podman"] + args',
    "subprocess.run(['docker', 'exec', c])",
]
# other file kinds: (file name, text). Every tracked text file is read, whatever its extension.
OTHER_BAD = [
    ("config/hypr/x.lua", 'hl.exec_cmd("docker run --privileged img")'),
    ("config/hypr/x.lua", "os.execute('/usr/bin/docker run img')"),
    ("packaging/x.service", "ExecStart=/usr/bin/docker run img"),
    ("packaging/x.service", "ExecStart=docker run img"),
    ("packaging/x.desktop", "Exec=docker run img"),
    ("scripts/dev/x.zsh", "docker run --privileged img"),
    ("scripts/dev/tool", "#!/bin/sh\ndocker run img"),
    ("scripts/dev/tool", "docker run img"),
    ("scripts/dev/tool", '"$(which docker)" run img'),
    ("shell/x.qml", 'Process { command: ["docker", "run", "img"] }'),
    ("plugins/x.cpp", 'QProcess::start("/usr/bin/docker", {"run"});'),
    ("shell/x.js", "exec('docker run img')"),
    ("config/x.toml", 'cmd = "docker run img"'),
]
OTHER_GOOD = [
    ("config/hypr/x.lua", 'hl.exec_cmd("kitty")'),
    ("packaging/x.service", "ExecStart=/usr/bin/true"),
    ("scripts/dev/tool", "#!/bin/sh\necho hello"),
    ("scripts/dev/x.zsh", "docker info >/dev/null 2>&1"),
]
PY_GOOD = ['subprocess.run(["docker", "info"], check=False)']


def selftest():
    fails = 0

    def want(label, text, rel, bad):
        nonlocal fails
        got = check_text(rel, text)
        if bool(got) != bad:
            print("SELFTEST FAIL: %s %s: %s" % ("not caught" if bad else "false positive", label, text.replace("\n", "\\n")[:100]))
            fails += 1

    for c in BAD_CALLS:
        want("shell", c + "\n", "tests/integration/x.sh", True)
        want("recipe", "task:\n    " + c + "\n", "justfile", True)
    for c in GOOD_CALLS:
        want("shell", c + "\n", "tests/integration/x.sh", False)
    for c in PY_BAD:
        want("python", c + "\n", "scripts/dev/x.py", True)
    for c in PY_GOOD:
        want("python", c + "\n", "scripts/dev/x.py", False)
    for name, text in OTHER_BAD:
        want("other file", text + "\n", name, True)
    for name, text in OTHER_GOOD:
        want("other file", text + "\n", name, False)
    want("an ALLOW entry: before", "docker run x\n", "tests/integration/x.sh", True)
    ALLOW.add(("tests/integration/x.sh", "docker run x"))
    want("an ALLOW entry waives exactly its line", "docker run x\n", "tests/integration/x.sh", False)
    want("an ALLOW entry waives only that text", "docker run y\n", "tests/integration/x.sh", True)
    ALLOW.discard(("tests/integration/x.sh", "docker run x"))
    want("cpp", 'QProcess::start("docker", {"run"});', "tests/unit/x.cpp", True)
    want("compose file", "services: {}\n", "tests/docker-compose.yml", True)
    want("dockerfile", "FROM scratch\n", "tests/Dockerfile", True)
    want("wrapper arrays outside", "gf_args+=(-v /dev:/dev)\n", "tests/integration/x.sh", True)
    want("systemd start outside update_migrate", 'gf_container_systemd_start "$IMAGE" "$mask"\n', "tests/integration/x.sh", True)
    want("systemd start in update_migrate", 'gf_container_systemd_start "$IMAGE" "$mask" >/dev/null\n', SYSTEMD_USER, False)

    root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    try:
        with open(os.path.join(root, WRAPPER), encoding="utf-8") as fh:
            wrapper = fh.read()
    except OSError:
        print("SELFTEST FAIL: cannot read " + WRAPPER)
        return 1
    want("the real wrapper", wrapper, WRAPPER, False)
    mutations = [
        "gf_args+=(--privileged)",
        "gf_args+=(-v /dev:/dev)",
        "gf_args+=(-v/dev:/dev)",
        "gf_args+=(-v //dev:/dev)",
        "gf_args+=(-v /run:/run)",
        "gf_args+=(-v /:/host)",
        "gf_args+=(-v /run/dbus:/run/dbus)",
        "gf_args+=(-v /run/user/1000:/run/user/1000)",
        'gf_args+=(-v "$HOME:/h:rw")',
        "gf_args+=(--device /dev/kvm)",
        "gf_args+=(--device-cgroup-rule 'c *:* rwm')",
        "gf_args+=(--cap-add ALL)",
        "gf_args+=(--cap-add SYS_ADMIN)",
        "gf_args+=(--security-opt systempaths=unconfined)",
        "gf_args+=(--security-opt seccomp=unconfined)",
        "gf_args+=(--cgroupns=host)",
        "gf_args+=(--pid=host --ipc=host)",
        "gf_args+=(--userns=host)",
        'gf_args+=("${extra[@]}")',
        'gf_args+=("$flag")',
        'gf_args=("$@")',
        "gf_args+=(--network host --privileged)",
        'envs+=(--privileged)',
        'envs+=("${more[@]}")',
        "docker run --privileged img",
        'docker run "${gf_args[@]}" --privileged "$1"',
        'docker run "${other[@]}" "$1"',
        'docker run --rm "${gf_args[@]}" "$@" --privileged',
        'docker exec --privileged "$1" sh',
        'docker create "${gf_args[@]}" x',
        'podman run --rm "${gf_args[@]}" "$@"',
        "docker cp a b",
        "docker network create x",
        "x=docker",
        "gf_other() {\n  gf_args+=(%s)\n}" % SYSTEMD_SET,
    ]
    for mut in mutations:
        want("wrapper + " + mut.split("\n")[0], wrapper + "\n" + mut + "\n", WRAPPER, True)
    print("no_privileged_containers selftest: %d shell, %d python, %d wrapper mutations, %d good lines, %d failures"
          % (len(BAD_CALLS), len(PY_BAD) + len(OTHER_BAD), len(mutations), len(GOOD_CALLS) + len(OTHER_GOOD), fails))
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
        print("no_privileged_containers: %d violation(s): containers are run only through tests/integration/container.sh (see tests/ci/no_privileged_containers.py)" % len(found))
        return 1
    print("no_privileged_containers: ok (docker and podman are called only in tests/integration/container.sh, whose options are an exact allowlist)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
