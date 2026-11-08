# The screen-sharing picker stand-in's peer check (packaging/session-bin/hyprland-share-picker, rc7 audit R7-SEC-02; ADR-0035
# D-6): only the main process of the shell's unit takes a request, the rule of grassfield-prompter's socket
# (bridges/prompter/src/Peer.cpp). Run by tests/shell/share_picker_peer.sh as `python3 -I peer.py <root>`. No listening
# socket (a sandbox may refuse socket()): the stand-in is loaded as a module, its pure functions are checked on fixed
# inputs, peer_ok on socket pairs (this process, and a child that has exited and been reaped) with a fake `systemctl` that
# answers the unit's MainPID, and accept_shell with a stand-in for the listening socket. Each guard of peer_ok has a case that
# only it refuses: another uid, another unit, another main process, no main process, a peer gone during the check. The
# end-to-end cases (a fake shell connecting to the real channel) are share_picker.d/check.py.
import importlib.machinery
import importlib.util
import os
import socket
import sys
import tempfile
import time

root = sys.argv[1]
failed = False
sys.dont_write_bytecode = True


def check(ok, desc):
    global failed
    print(("PASS: " if ok else "FAIL: ") + "share picker peer: " + desc, flush=True)
    failed = failed or not ok


loader = importlib.machinery.SourceFileLoader("picker", os.path.join(root, "packaging/session-bin/hyprland-share-picker"))
spec = importlib.util.spec_from_loader("picker", loader)
picker = importlib.util.module_from_spec(spec)
loader.exec_module(picker)
check(picker.SYSTEMCTL == "/usr/bin/systemctl", "the stand-in runs systemctl by its path, never through PATH")

uid = os.getuid()
# systemctl: `systemctl --user show --property=MainPID --value <unit>` prints FAKE_MAINPID (or fails: FAKE_MAINPID=fail).
fakebin = tempfile.mkdtemp(prefix="picker-peer.", dir=os.environ.get("TMPDIR") or None)
with open(os.path.join(fakebin, "systemctl"), "w") as f:
    f.write('#!/bin/sh\n[ "$1 $2 $3 $4" = "--user show --property=MainPID --value" ] || exit 3\n'
            '[ "$FAKE_MAINPID" = fail ] && exit 1\nprintf "%s\\n" "$FAKE_MAINPID"\n')
os.chmod(os.path.join(fakebin, "systemctl"), 0o755)
os.environ["FAKE_MAINPID"] = str(os.getpid())
picker.SYSTEMCTL = os.path.join(fakebin, "systemctl")
with open("/proc/self/cgroup") as f:
    own = picker.unified_cgroup(f.read())
leaf = own.rstrip("/").rsplit("/", 1)[-1]

# The cgroup rule, Peer.cpp's cases.
U = "grassfield-shell.service"
M = "/user.slice/user-%d.slice/user@%d.service" % (uid, uid)
cases = [
    (M + "/app.slice/" + U, U, True, True, "the shell's unit under the user's manager and a slice"),
    (M + "/" + U, U, True, True, "directly under the user's manager"),
    (M + "/session.slice/app.slice/" + U, U, True, True, "under nested slices"),
    (M + "/app.slice/" + U + " (deleted)", U, True, False, "a removed cgroup"),
    ("user.slice/user@%d.service/app.slice/%s" % (uid, U), U, True, False, "a relative path"),
    (M + "/app.slice/other.service/" + U, U, True, False, "nested in another unit (only slices between)"),
    (M + "/app.slice/x-" + U, U, True, False, "a name that merely ends with the unit's"),
    (M + "/app.slice/" + U + "/sub", U, True, False, "a sub-cgroup of the unit"),
    ("/user.slice/user-%d.slice/user@%d.service/app.slice/%s" % (uid + 1, uid + 1, U), U, True, False, "another user's manager"),
    ("/system.slice/" + U, U, True, False, "a system unit of the same name"),
    (M + "/.slice/" + U, U, True, False, "a component named .slice alone"),
    ("/system.slice/" + U, U, False, True, "a dev run: the last component alone"),
    ("/", U, False, False, "the root cgroup"),
    ("", U, False, False, "no cgroup"),
    (M + "/app.slice/" + U, "", True, False, "no unit"),
]
for path, unit, manager, want, desc in cases:
    check(picker.cgroup_is_unit(path, unit, uid, manager) is want, "cgroup rule: %s -> %s" % (desc, want))
check(picker.unified_cgroup("12:pids:/x\n0::/a/b.scope\n") == "/a/b.scope" and picker.unified_cgroup("1:name=systemd:/x\n") == "",
      "the cgroup v2 line of /proc/<pid>/cgroup, none without it")
check([picker.pid_from_fdinfo(t) for t in ("pos:\t0\nPid:\t42\n", "Pid:\t-1\n", "Pid:\t0\n", "Pid:\tx\n", "flags:\t0\n")]
      == [42, -1, 0, 0, 0], "a pidfd's PID from its fdinfo: running, exited, another namespace, unreadable, missing")


def with_env(env, fn):
    keep = {k: os.environ.get(k) for k in ("GRASSFIELD_DEV", "GRASSFIELD_SESSION", "GRASSFIELD_PICKER_PEER_UNIT", "FAKE_MAINPID")}
    for k in keep:
        if k != "FAKE_MAINPID":
            os.environ.pop(k, None)
    os.environ.update(env)
    try:
        return fn()
    finally:
        for k, v in keep.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v


# Which unit is expected, by session.
check(with_env({}, picker.peer_unit) == (U, True), "a session expects grassfield-shell.service under the user's manager")
check(with_env({"GRASSFIELD_DEV": "1", "GRASSFIELD_PICKER_PEER_UNIT": "x.scope"}, picker.peer_unit) == ("x.scope", False),
      "a dev session may name the cgroup that stands for the shell's (last component alone)")
check(with_env({"GRASSFIELD_DEV": "1"}, picker.peer_unit) == (U, False), "a dev session without a name expects the shell's unit")
check(with_env({"GRASSFIELD_DEV": "1", "GRASSFIELD_SESSION": "1", "GRASSFIELD_PICKER_PEER_UNIT": "x.scope"}, picker.peer_unit)
      == (U, True), "a real session ignores the dev name (GRASSFIELD_SESSION=1)")
check(with_env({"GRASSFIELD_DEV": "yes", "GRASSFIELD_PICKER_PEER_UNIT": "x.scope"}, picker.peer_unit) == (U, True),
      "a dev flag other than 1 ignores the dev name")
for bad in ("a/b", ".", "..", "x" * 256):
    check(with_env({"GRASSFIELD_DEV": "1", "GRASSFIELD_PICKER_PEER_UNIT": bad}, picker.peer_unit)[0] is None,
          "a dev name that is not one path component is refused: %r" % bad[:12])

# peer_ok on a socket pair: the peer is this process (its credentials are the pair's creator's).
if not leaf:
    print("SKIP: share picker peer: this process sits at the root of its cgroup tree (no unit to stand for the shell's)")
else:
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    check(with_env({"GRASSFIELD_DEV": "1", "GRASSFIELD_PICKER_PEER_UNIT": leaf}, lambda: picker.peer_ok(a)),
          "a peer of the expected unit is taken (this process's cgroup %s)" % leaf)
    check(not with_env({"GRASSFIELD_DEV": "1", "GRASSFIELD_PICKER_PEER_UNIT": "not-" + leaf}, lambda: picker.peer_ok(a)),
          "a peer of another unit is refused")
    in_shell = own.endswith("/" + U)
    check(in_shell or not with_env({"GRASSFIELD_SESSION": "1"}, lambda: picker.peer_ok(a)),
          "in a real session a peer outside grassfield-shell.service is refused")
    dev = {"GRASSFIELD_DEV": "1", "GRASSFIELD_PICKER_PEER_UNIT": leaf}
    # The main process (rc7 security review of R7-SEC-02): a process of the unit's cgroup that is not its main process is
    # refused (one that moved itself into the cgroup), and so is any doubt about it.
    for main, why in ((str(os.getpid() + 1), "another process is the unit's main process"),
                      ("0", "the unit has no main process (stopped, or a scope)"),
                      ("fail", "systemd cannot be asked"), ("12x", "systemd's answer does not read")):
        check(not with_env(dict(dev, FAKE_MAINPID=main), lambda: picker.peer_ok(a)), "refused when %s" % why)
    check(with_env(dict(dev, FAKE_MAINPID=str(os.getpid())), lambda: picker.peer_ok(a)),
          "control: the same peer is taken when it is the unit's main process")
    # The uid guard alone: the peer is this process, of the expected cgroup and the unit's main process, but the stand-in
    # runs as another user.
    real_getuid = picker.os.getuid
    picker.os.getuid = lambda: real_getuid() + 1
    try:
        check(not with_env(dev, lambda: picker.peer_ok(a)), "a peer of another uid is refused (everything else matching)")
    finally:
        picker.os.getuid = real_getuid
    before = len(os.listdir("/proc/self/fd"))
    for _ in range(20):
        with_env({"GRASSFIELD_DEV": "1", "GRASSFIELD_PICKER_PEER_UNIT": leaf}, lambda: picker.peer_ok(a))
    check(len(os.listdir("/proc/self/fd")) == before, "the peer's pidfd is closed after each check")
    a.close()
    b.close()

    # A peer that has exited and been reaped: a child makes the pair, hands one end over and exits before the check.
    carrier, child_end = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    pid = os.fork()
    if pid == 0:
        try:
            carrier.close()
            x, y = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
            socket.send_fds(child_end, [b"x"], [x.fileno()])
        finally:
            os._exit(0)
    child_end.close()
    _, fds, _, _ = socket.recv_fds(carrier, 1, 1)
    os.waitpid(pid, 0)
    gone = socket.socket(fileno=fds[0])
    check(not with_env({"GRASSFIELD_DEV": "1", "GRASSFIELD_PICKER_PEER_UNIT": leaf}, lambda: picker.peer_ok(gone)),
          "a peer that has exited (its PID free to be reused) is refused, even in the expected cgroup")
    # The liveness guard alone: the pidfd's fdinfo is made to name this process (as if the PID had been read just before the
    # peer exited and the PID were reused by a process of the unit, its main process too); the pidfd is of the exited peer.
    real_read = picker.read_small
    picker.read_small = lambda path: ("Pid:\t%d\n" % os.getpid()) if path.startswith("/proc/self/fdinfo/") else real_read(path)
    try:
        check(not with_env({"GRASSFIELD_DEV": "1", "GRASSFIELD_PICKER_PEER_UNIT": leaf}, lambda: picker.peer_ok(gone)),
              "a pidfd whose process has exited refuses the peer, whatever PID was read (the liveness check after the reads)")
    finally:
        picker.read_small = real_read
    gone.close()
    carrier.close()


# accept_shell: a refused peer is closed and the wait goes on; the deadline ends it.
class Server:
    def __init__(self, conns):
        self.conns = list(conns)

    def settimeout(self, value):
        self.timeout = value

    def accept(self):
        if not self.conns:
            raise socket.timeout("timed out")
        return self.conns.pop(0), None


first, first_peer = socket.socketpair()
second, second_peer = socket.socketpair()
real_ok = picker.peer_ok
picker.peer_ok = lambda conn: conn is second
try:
    got = picker.accept_shell(Server([first, second]))
    check(got is second and first.fileno() == -1 and second.fileno() != -1,
          "a refused connection is closed unanswered and the next one, the shell's, is taken")
    check(picker.accept_shell(Server([])) is None, "no connection within the time: none")
    third, third_peer = socket.socketpair()
    picker.peer_ok = lambda conn: False
    check(picker.accept_shell(Server([third])) is None and third.fileno() == -1, "only refused connections: none, each closed")
finally:
    picker.peer_ok = real_ok
for s in (second, first_peer, second_peer, third_peer):
    s.close()

# share_picker.sh's "lines with another id" case through the real peer check and conversation (the integrator's A/B run of
# 2026-11-08 timed out after 2.3 s once): a stray connector first, refused (another uid), then the shell, a child that is the
# unit's main process by the fake systemctl, writing lines with another id; the stand-in takes the shell and waits the whole
# silence bound (shortened to 1.5 s here), then gives up: neither the refusal nor the foreign lines end the request early.
if leaf:
    carrier, child_end = socket.socketpair()
    pid = os.fork()
    if pid == 0:
        try:
            carrier.close()
            mine, theirs = socket.socketpair()
            socket.send_fds(child_end, [b"x"], [theirs.fileno()])
            theirs.close()
            reader = mine.makefile("rb")
            reader.readline()
            reader.readline()
            for _ in range(12):
                mine.sendall(("0" * 32 + " wait\n").encode())
                time.sleep(0.25)
        except OSError:
            pass
        finally:
            os._exit(0)
    child_end.close()
    _, fds, _, _ = socket.recv_fds(carrier, 1, 1)
    shell = socket.socket(fileno=fds[0])
    stray, stray_peer = socket.socketpair()
    real_getuid, real_silence = picker.os.getuid, picker.SILENCE_SECONDS
    picker.SILENCE_SECONDS = 1.5
    try:
        class Stray(Server):
            def accept(self):
                conn, _ = Server.accept(self)
                # The stray is refused for its uid, the shell's check runs as this user.
                picker.os.getuid = (lambda: real_getuid() + 1) if conn is stray else real_getuid
                return conn, None
        t0 = time.monotonic()
        got = with_env({"GRASSFIELD_DEV": "1", "GRASSFIELD_PICKER_PEER_UNIT": leaf, "FAKE_MAINPID": str(pid)},
                       lambda: picker.accept_shell(Stray([stray, shell])))
        answer = picker.converse(got, "ab" * 16, [], False) if got is shell else "not taken"
        took = time.monotonic() - t0
        check(got is shell and stray.fileno() == -1 and answer is None and 1.4 <= took < 2.6,
              "a stray connector refused, then the shell writing lines with another id: the request waits the silence bound "
              "[%r %.1f s]" % (answer, took))
    finally:
        picker.os.getuid, picker.SILENCE_SECONDS = real_getuid, real_silence
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        for s in (shell, stray_peer, carrier):
            s.close()

source = open(os.path.join(root, "packaging/session-bin/hyprland-share-picker")).read()
check(source.count("    conn = accept_shell(server)\n") == 1 and "server.accept()" not in source.replace("            conn, _ = server.accept()\n", ""),
      "main takes the shell's connection only through accept_shell (no other accept)")
import shutil
shutil.rmtree(fakebin, ignore_errors=True)
sys.exit(1 if failed else 0)
