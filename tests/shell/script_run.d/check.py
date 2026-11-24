# packaging/bin/grassfield-script-run against fakes (run by tests/shell/script_run.sh as `python3 -I check.py <root> <tmp>`).
# The fake systemd-run reads the unit's stdin like the unit would, records its argv and that stdin, can change the script file
# after the runner read it, print output, flood, or wait; the fake systemctl records its argv and marks a kill, which ends
# a waiting or flooding fake. Nothing here starts a unit.
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
import time

root, tmp = sys.argv[1:3]
failed = False


def check(ok, desc):
    global failed
    print(("PASS: " if ok else "FAIL: ") + desc, flush=True)
    failed = failed or not ok


def write(path, text, mode=0o755):
    with open(path, "w" if isinstance(text, str) else "wb") as f:
        f.write(text)
    os.chmod(path, mode)


runner = os.path.join(root, "packaging/bin/grassfield-script-run")
source = open(runner).read()
fast = os.path.join(tmp, "grassfield-script-run-fast")
write(fast, re.sub(r"^GRACE_SECONDS = [0-9]+", "GRACE_SECONDS = 1",
                   re.sub(r"^RUN_SECONDS = [0-9]+", "RUN_SECONDS = 1", source, flags=re.M), flags=re.M))

fake, log, state, scripts = (os.path.join(tmp, d) for d in ("fake", "log", "state", "scripts"))
for d in (fake, log, scripts, os.path.join(state, "grassfield")):
    os.makedirs(d)
os.chmod(os.path.join(state, "grassfield"), 0o700)

write(os.path.join(fake, "systemd-run"), r'''#!/usr/bin/python3 -I
import json, os, sys, time
log = os.environ["FAKE_LOG"]
n = len([f for f in os.listdir(log) if f.startswith("run-")]) // 2
stdin = sys.stdin.buffer.read()
open(os.path.join(log, "run-%d.json" % n), "w").write(json.dumps(sys.argv[1:]))
open(os.path.join(log, "run-%d.stdin" % n), "wb").write(stdin)
swap = os.environ.get("FAKE_SWAP")
if swap:
    p, text = swap.split("=", 1)
    open(p, "w").write(text)
for line in os.environ.get("FAKE_OUT", "").splitlines():
    print(line, flush=True)
flood = os.environ.get("FAKE_FLOOD")
if flood:
    chunk = (b"x" * 99 + b"\n") * 100 if flood == "bytes" else b"y\n" * 100
    if flood == "stderr":
        chunk = b"e" * 1000 + b"\n"
    out = sys.stderr.buffer if flood == "stderr" else sys.stdout.buffer
    for _ in range(100000):
        if os.path.exists(os.path.join(log, "killed")):
            sys.exit(137)
        try:
            out.write(chunk); out.flush()
        except BrokenPipeError:
            sys.exit(137)
if os.environ.get("FAKE_WAIT"):
    for _ in range(300):
        if os.path.exists(os.path.join(log, "killed")):
            sys.exit(137)
        time.sleep(0.05)
sys.exit(int(os.environ.get("FAKE_EXIT", "0")))
''')
write(os.path.join(fake, "systemctl"), r'''#!/usr/bin/python3 -I
import json, os, sys
log = os.environ["FAKE_LOG"]
open(os.path.join(log, "systemctl.jsonl"), "a").write(json.dumps(sys.argv[1:]) + "\n")
open(os.path.join(log, "killed"), "w").write("1")
''')

approvals = os.path.join(state, "grassfield", "script-approvals.json")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def approve(entries, mode=0o600):
    write(approvals, json.dumps({"v": 1, "approvals": entries}), mode)


def script(name, body=b"#!/bin/sh\necho hi\n", mode=0o700):
    p = os.path.join(scripts, name)
    write(p, body, mode)
    return p


def entry(path, data, net=False, ses=False):
    return {"path": path, "sha256": sha(data), "allowNetwork": net, "allowSession": ses}


def reset():
    for f in os.listdir(log):
        os.unlink(os.path.join(log, f))


def req(path, **kw):
    r = {"v": 1, "path": path, "level": "confined", "mode": "fullOutput", "args": [], "passwords": []}
    r.update(kw)
    return r


def env(extra=None):
    e = {"PATH": fake + ":/usr/bin:/bin", "HOME": tmp, "XDG_STATE_HOME": state, "FAKE_LOG": log}
    e.update(extra or {})
    return e


def go(request, extra=None, helper=runner, wait=True, text=None):
    reset()
    p = subprocess.Popen([sys.executable, "-I", helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env(extra))
    p.stdin.write(text if text is not None else json.dumps(request).encode() + b"\n")
    p.stdin.close()
    if not wait:
        return p
    out, err = p.communicate(timeout=60)
    return p.returncode, [json.loads(line) for line in out.decode().splitlines()], err.decode()


def done(events):
    return [e for e in events if e.get("done")][-1]


def ran():
    return os.path.exists(os.path.join(log, "run-0.json"))


def argv0():
    return json.load(open(os.path.join(log, "run-0.json")))


def frame0():
    return open(os.path.join(log, "run-0.stdin"), "rb").read()


def unit_of(argv):
    return next((x[len("--unit="):] for x in argv if x.startswith("--unit=")), "")


def kills():
    path = os.path.join(log, "systemctl.jsonl")
    if not os.path.exists(path):
        return None
    return [json.loads(line) for line in open(path).read().splitlines()]


loader = importlib.machinery.SourceFileLoader("gsr", runner)
spec = importlib.util.spec_from_loader("gsr", loader)
gsr = importlib.util.module_from_spec(spec)
loader.exec_module(gsr)

# ---- the approved run --------------------------------------------------------------------------------------------------------
body = b"#!/bin/sh\necho hi\n"
p = script("ok.sh", body)
approve([entry(p, body)])
secret = "pw-" + "z" * 8
rc, ev, err = go(req(p, args=["one", "two words"], passwords=[secret]), {"FAKE_OUT": "hello\nworld"})
check(rc == 0 and done(ev)["reason"] == "ok" and done(ev)["status"] == 0, "an approved script runs and ends ok [%r]" % (done(ev),))
check([e["o"] for e in ev if "o" in e] == ["hello", "world"], "stdout reaches the shell line by line")
a = argv0()
unit = unit_of(a)
check(re.fullmatch(r"grassfield-script-[0-9a-f]{16}", unit) is not None, "the unit has a name of its own [%s]" % unit)
check(a[:7] == ["--user", "--wait", "--pipe", "--collect", "--quiet", "--description=Grassfield script", "--unit=" + unit],
      "argv starts with the fixed flags and the fixed description [%r]" % (a[:7],))
check(a[7:11] == ["--property=RuntimeMaxSec=60", "--property=MemoryMax=512M", "--property=TasksMax=64",
                  "--property=NoNewPrivileges=yes"], "the limits are properties [%r]" % (a[7:11],))
check(a[11:] == ["--", sys.executable, "-I", runner, "--sandbox"], "the command is the runner's own sandbox stage, nothing else [%r]" % (a[11:],))
blob = "\0".join(a)
check("one" not in a and "two words" not in blob and secret not in blob and "echo hi" not in blob,
      "no argument, password or script text in the unit's argv or description")
header, data = gsr.decode_frame(frame0())
check(data == body and header["sha256"] == sha(body) and header["args"] == ["one", "two words"] and header["passwords"] == [secret]
      and header["level"] == "confined" and header["path"] == p, "the frame carries the bytes, their hash, the arguments and the passwords")
check(kills() is None, "no kill on a normal run")
rc, ev, err = go(req(p, mode="inline"))
check(argv0()[7] == "--property=RuntimeMaxSec=10", "inline runs get 10 s")

# ---- exit status ---------------------------------------------------------------------------------------------------------------
rc, ev, err = go(req(p), {"FAKE_EXIT": "3"})
check(rc == 1 and done(ev)["reason"] == "failed" and done(ev)["status"] == 3, "a failing script reports its status [%r]" % (done(ev),))


# ---- the approvals file --------------------------------------------------------------------------------------------------------
def refused(desc, request=None, **kw):
    rc, ev, err = go(request if request is not None else req(p), **kw)
    d = done(ev)
    check(rc == 1 and d["reason"] == "refused" and not ran(), desc + " [%s]" % d.get("why"))
    return d.get("why")


approve([entry(p, b"another script\n")])
check(refused("a hash that is not the approved one is refused even when the shell asks") == "approval", "  reason is approval")
approve([entry(p + "x", body)])
refused("an approval for another path is refused")
approve([])
refused("an empty approvals file refuses")
os.unlink(approvals)
refused("no approvals file refuses")
approve([entry(p, body)], mode=0o644)
check(refused("a readable approvals file (not 0600) is refused") == "approval-file", "  reason is approval-file")
approve([entry(p, body)])
real = approvals + ".real"
os.rename(approvals, real)
os.symlink(real, approvals)
refused("an approvals file that is a link is refused")
os.unlink(approvals)
os.rename(real, approvals)
write(approvals, "{not json", 0o600)
refused("a malformed approvals file refuses")
write(approvals, json.dumps({"v": 2, "approvals": [entry(p, body)]}), 0o600)
refused("an approvals file of another version refuses")
approve([{"path": p, "sha256": sha(body).upper(), "allowNetwork": True, "allowSession": True}])
refused("a malformed entry (upper-case hash) never matches")
approve([{"path": p, "sha256": sha(body), "allowNetwork": "yes", "allowSession": False}])
refused("a malformed entry (a non-boolean) never matches")

approve([entry(p, body)])
check(refused("network without allowNetwork is refused", req(p, level="network")) == "approval-level", "  network level checked")
check(refused("session without allowSession is refused", req(p, level="session")) == "approval-level", "  session level checked")
approve([entry(p, body, net=True)])
rc, ev, err = go(req(p, level="network"))
check(done(ev)["reason"] == "ok" and gsr.decode_frame(frame0())[0]["level"] == "network", "network runs with allowNetwork")
refused("session still refused with only allowNetwork", req(p, level="session"))
approve([entry(p, body, ses=True)])
rc, ev, err = go(req(p, level="session"))
check(done(ev)["reason"] == "ok", "session runs with allowSession")

# ---- the file read once ----------------------------------------------------------------------------------------------------------
approve([entry(p, body)])
rc, ev, err = go(req(p), {"FAKE_SWAP": p + "=#!/bin/sh\nrm -rf ~\n"})
check(done(ev)["reason"] == "ok" and gsr.decode_frame(frame0())[1] == body,
      "a swap after the read changes nothing that runs: the frame holds the read bytes")
refused("the swapped file (new hash) is refused on the next run")
write(p, body, 0o700)


# ---- the script's own checks -------------------------------------------------------------------------------------------------------
def with_script(name, content, mode, desc, why):
    q = script(name, content, mode)
    approve([entry(q, content)])
    check(refused(desc, req(q)) == why, "  reason " + why)


with_script("gw.sh", body, 0o770, "a group-writable script is refused", "script-writable")
with_script("ow.sh", body, 0o707, "a world-writable script is refused", "script-writable")
with_script("nx.sh", body, 0o600, "a script that is not executable is refused", "script-executable")
with_script("big.sh", b"#!/bin/sh\n" + b"#" * (256 * 1024), 0o700, "a script over 256 KiB is refused", "script-size")
fifo = os.path.join(scripts, "fifo.sh")
os.mkfifo(fifo, 0o700)
approve([entry(fifo, b"")])
check(refused("a FIFO is refused without hanging", req(fifo)) == "script-type", "  reason script-type")
refused("a directory is refused", req(scripts))
refused("a missing script is refused", req(os.path.join(scripts, "none.sh")))
lnk = os.path.join(scripts, "link.sh")
os.symlink(p, lnk)
approve([entry(lnk, body)])
rc, ev, err = go(req(lnk))
check(done(ev)["reason"] == "ok", "a link to a good script is read through (discovery decided it may be listed)")

# ---- requests ----------------------------------------------------------------------------------------------------------------------
approve([entry(p, body)])
refused("four arguments are refused", req(p, args=["a", "b", "c", "d"]))
refused("a password with a line break is refused", req(p, passwords=["a\nb"]))
refused("an argument with NUL is refused", req(p, args=["a\0b"]))
refused("a relative path is refused", req("scripts/ok.sh"))
refused("an unknown level is refused", req(p, level="root"))
refused("an unknown mode is refused", req(p, mode="x"))
refused("an extra key is refused", dict(req(p), shell=True))
refused("not JSON is refused", text=b"hello\n")
refused("a request over 64 KiB is refused", text=b'{"v":1,"pad":"' + b"a" * 70000 + b'"}\n')
refused("an empty request is refused", text=b"")
rc, ev, err = go(req(p), {"PATH": "/nonexistent"})
check(done(ev)["reason"] == "refused" and done(ev)["why"].startswith("missing-") and not ran(),
      "no systemd-run on PATH: refused, nothing run [%s]" % done(ev)["why"])
r = subprocess.run([sys.executable, "-I", runner, "--bogus"], capture_output=True)
check(r.returncode == 2, "an unknown argument gives the usage (exit 2)")

# ---- caps ----------------------------------------------------------------------------------------------------------------------------
for kind, desc in (("lines", "2 000 lines on stdout"), ("bytes", "1 MiB on stdout"), ("stderr", "64 KiB on stderr")):
    rc, ev, err = go(req(p), {"FAKE_FLOOD": kind})
    d = done(ev)
    k = kills()
    check(d["reason"] == "capped" and rc == 1 and k is not None and k[0][:3] == ["--user", "kill", "--kill-whom=all"]
          and unit_of(argv0()) in k[0], "the cap of %s stops the run and kills its unit [%s]" % (desc, d["reason"]))
    if kind == "lines":
        check(len([e for e in ev if "o" in e]) == 2000, "  exactly 2000 lines passed on")
    if kind == "bytes":
        check(sum(len(e["o"]) + 1 for e in ev if "o" in e) - 1 <= 1024 * 1024, "  at most 1 MiB passed on")
    if kind == "stderr":
        check(sum(len(e["e"]) + 1 for e in ev if "e" in e) - 1 <= 64 * 1024, "  at most 64 KiB passed on")

# ---- timeout and lock ------------------------------------------------------------------------------------------------------------
t0 = time.monotonic()
rc, ev, err = go(req(p), {"FAKE_WAIT": "1"}, helper=fast)
k = kills()
check(done(ev)["reason"] == "timeout" and k is not None and k[0][-1] == unit_of(argv0()) and time.monotonic() - t0 < 15,
      "a run past its time is killed by the runner [%s]" % done(ev)["reason"])
proc = go(req(p), {"FAKE_WAIT": "1"}, wait=False)
for _ in range(100):
    if ran():
        break
    time.sleep(0.05)
time.sleep(0.3)
proc.send_signal(signal.SIGTERM)
out, err = proc.communicate(timeout=30)
ev = [json.loads(line) for line in out.decode().splitlines()]
k = kills()
check(done(ev)["reason"] == "killed" and k is not None and k[0][-1] == unit_of(argv0()),
      "SIGTERM (the shell stopping a run) kills the unit and reports killed [%s]" % done(ev)["reason"])
reset()
r = subprocess.run([sys.executable, "-I", runner, "--kill-all"], env=env(), capture_output=True, timeout=30)
check(r.returncode == 0 and kills() == [["--user", "kill", "--kill-whom=all", "--signal=SIGKILL", "grassfield-script-*.service"]],
      "--kill-all kills every script unit (the lock) [%r]" % (kills(),))

# ---- the frame and the unit's stage ------------------------------------------------------------------------------------------------
good = gsr.encode_frame(p, body, sha(body), "confined", ["a"], [])
for desc, bad in (("a wrong magic", b"X" + good[1:]), ("a cut frame", good[:len(good) - 3]), ("a longer frame", good + b"!"),
                  ("a changed script byte", good[:-2] + b"X" + good[-1:]), ("an empty frame", b""),
                  ("a huge header length", good[:10] + b"\xff\xff\xff\xff" + good[14:])):
    try:
        gsr.decode_frame(bad)
        ok = False
    except ValueError:
        ok = True
    check(ok, "decode_frame refuses " + desc)
r = subprocess.run([sys.executable, "-I", runner, "--sandbox"], input=b"junk", capture_output=True)
check(r.returncode == 70, "the unit's stage refuses a bad frame (exit 70)")
r = subprocess.run([sys.executable, "-I", runner, "--sandbox"], input=good, capture_output=True)
check(r.returncode == 71 and r.stdout == b"", "until X3b the unit's stage runs nothing, even for a good frame (exit 71)")

print("script_run: FAIL" if failed else "script_run: PASS")
sys.exit(1 if failed else 0)
