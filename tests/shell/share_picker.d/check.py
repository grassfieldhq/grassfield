# The screen-sharing picker stand-in (packaging/session-bin/hyprland-share-picker, ADR-0035 D-6, step 7a) against a fake
# shell, a fake hyprctl and fake stock pickers; run by tests/shell/share_picker.sh as `python3 -I check.py <root> <tmp>`.
# Its stdout goes through a copy of xdph 1.4.1's parser (promptForScreencopySelection, src/shared/ScreencopyShared.cpp:70-125),
# so a selection counts only as xdph reads it. Spec system-dialogs.md A-SP1, A-SP2, A-SP2b, A-SP3.
import atexit
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

root, tmp = sys.argv[1:3]
failed = False


def check(ok, desc):
    global failed
    print(("PASS: " if ok else "FAIL: ") + desc, flush=True)
    failed = failed or not ok


def write(path, text, mode=0o755):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


# A scratch copy of the stand-ins whose stock pickers are fakes, and whose count of suspends is a file here. The runtime
# directory is short and of its own: a Unix socket's path holds at most 107 bytes, and `just test` puts the test's
# directory deep in the tree.
bindir, fake, stock = (os.path.join(tmp, d) for d in ("bin", "fake", "stock"))
for d in (bindir, fake, stock):
    os.makedirs(d)
run = tempfile.mkdtemp(prefix="gfsp-", dir="/tmp")
os.chmod(run, 0o700)
atexit.register(shutil.rmtree, run, True)
check(len(os.path.join(run, "grassfield", "picker", "0" * 32 + ".sock").encode()) <= 107, "the channel's path fits a Unix socket")
suspends = os.path.join(tmp, "suspend-success")
source = open(os.path.join(root, "packaging/session-bin/hyprland-share-picker")).read()
check(source.count('STOCK_DIR = "/usr/bin"\n') == 1 and source.count('SUSPEND_STATS = "/sys/power/suspend_stats/success"\n') == 1,
      "the stand-in runs its stock pickers from /usr/bin and reads the suspends' count from /sys/power")
write(os.path.join(bindir, "hyprland-share-picker"), source.replace('STOCK_DIR = "/usr/bin"\n', 'STOCK_DIR = %r\n' % stock)
      .replace('SUSPEND_STATS = "/sys/power/suspend_stats/success"\n', 'SUSPEND_STATS = %r\n' % suspends))
shutil.copy(os.path.join(root, "packaging/session-bin/hyprland-preview-share-picker"), bindir)

logs = {k: os.path.join(tmp, k + ".log") for k in ("qs", "shell", "hyprctl", "stock")}
picker_dir = os.path.join(run, "grassfield", "picker")

# The stock pickers: their name, arguments, the window list they got, the channel files left when they started, and whether
# SIGPIPE was ignored (read by sh before Python starts: Python ignores it itself).
for name in ("hyprland-share-picker", "hyprland-preview-share-picker"):
    write(os.path.join(stock, name + ".py"), """import json, os, sys
d = %r
left = sorted(os.listdir(d)) if os.path.isdir(d) else []
ignored = int(os.environ["SIGIGN"].split()[1], 16)
with open(%r, "a") as f:
    f.write(json.dumps({"name": %r, "args": sys.argv[1:], "list": os.environ.get("XDPH_WINDOW_SHARING_LIST"), "left": left,
                        "sigpipe_ignored": bool(ignored & (1 << (13 - 1)))}) + "\\n")
""" % (picker_dir, logs["stock"], name), 0o644)
    write(os.path.join(stock, name), '#!/bin/sh\nSIGIGN=$(grep "^SigIgn:" /proc/$$/status) exec python3 -I %s "$@"\n'
          % os.path.join(stock, name + ".py"))

# hyprctl: FAKE_HYPRCTL ok (FAKE_MONITORS), fail, hang, garbage.
write(os.path.join(fake, "hyprctl"), """#!/usr/bin/python3 -I
import os, sys, time
with open(%r, "a") as f:
    f.write(" ".join(sys.argv[1:]) + (" +list" if "XDPH_WINDOW_SHARING_LIST" in os.environ else "") + "\\n")
mode = os.environ.get("FAKE_HYPRCTL", "ok")
if mode == "fail":
    sys.exit(1)
if mode == "hang":
    time.sleep(5)
print("not json" if mode == "garbage" else os.environ.get("FAKE_MONITORS", "[]"))
""" % logs["hyprctl"])

# qs: records its arguments, the Quickshell option variables it got and the channel's modes; then answers as FAKE_QS says.
# A shell that accepts connects from a detached child (the real shell is another process) and plays FAKE_SCRIPT.
write(os.path.join(fake, "qs"), r"""#!/usr/bin/python3 -I
import json, os, socket, stat, sys, time
path = sys.argv[-1]
rid = sys.argv[-2]
def mode(p):
    try:
        return oct(stat.S_IMODE(os.lstat(p).st_mode)), stat.S_ISSOCK(os.lstat(p).st_mode)
    except OSError:
        return None, False
with open(os.environ["QS_LOG"], "a") as f:
    f.write(json.dumps({"argv": sys.argv[1:], "qsenv": [k for k in ("QS_CONFIG_PATH", "QS_CONFIG_NAME", "QS_MANIFEST", "XDPH_WINDOW_SHARING_LIST") if k in os.environ],
                        "socket": mode(path), "dir": mode(os.path.dirname(path))}) + "\n")
how = os.environ.get("FAKE_QS", "accept")
log = os.environ["SHELL_LOG"]
def note(event, **more):
    with open(log, "a") as f:
        f.write(json.dumps(dict(event=event, t=time.monotonic(), **more)) + "\n")
def shell(delay):
    if os.fork():
        return
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    time.sleep(delay)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(path)
    except OSError:
        note("connect-failed")
        os._exit(0)
    note("connected")
    reader = s.makefile("rb")
    for step in json.loads(os.environ.get("FAKE_SCRIPT", "[]")):
        kind, _, arg = step.partition(":")
        if kind == "list":
            # The options line comes first, then the list.
            line = reader.readline().decode("ascii", "replace")
            if line.startswith(rid + " options "):
                note("options", line=line)
                line = reader.readline().decode("ascii", "replace")
            note("list", line=line)
        elif kind == "say":
            s.sendall((rid + " " + arg + "\n").encode())
        elif kind == "sayas":
            s.sendall((arg + "\n").encode())
        elif kind == "sleep":
            time.sleep(float(arg))
        elif kind == "close":
            s.close()
            note("closed")
            os._exit(0)
        elif kind == "eof":
            s.settimeout(float(arg))
            try:
                note("eof" if s.recv(1) == b"" else "data")
            except OSError:
                note("no-eof")
    os._exit(0)
if how == "accept":
    print("accepted", flush=True)
    shell(0)
elif how == "accept-noconnect":
    print("accepted", flush=True)
elif how in ("busy", "locked", "garbage"):
    print("yes" if how == "garbage" else how, flush=True)
elif how == "silent":
    time.sleep(3)
elif how == "lock-then-silent":
    with open(os.environ["MARKER_PATH"], "w") as f:
        f.write("locked\n")
    time.sleep(3)
elif how == "late":
    shell(1.5)
    time.sleep(1.2)
    print("accepted", flush=True)
else:
    sys.exit(1)
""")

TWO = json.dumps([
    {"name": "DP-1", "width": 1920, "height": 1080, "scale": 1.0, "transform": 0, "solitaryBlockedBy": [], "disabled": False},
    {"name": "DP-2", "width": 2560, "height": 1440, "scale": 2.0, "transform": 0, "solitaryBlockedBy": []},
])
# Two windows xdph lists (handleLo, class, title, Hyprland address in decimal), and an entry that does not read.
WINDOWS = ("123456[HC>]org.gnome.TextEditor[HT>]notes.txt[HE>]94371412345678[HA>]"
           "4294967295[HC>]firefox[HT>]A page — Firefox[HE>]0[HA>]"
           "12x[HC>]bad[HT>]bad[HE>]1[HA>]")


def env_for(**extra):
    env = {"PATH": "%s:/usr/bin:/bin" % fake, "XDG_RUNTIME_DIR": run, "HYPRLAND_INSTANCE_SIGNATURE": "test_sig",
           "XDPH_WINDOW_SHARING_LIST": WINDOWS, "FAKE_MONITORS": TWO, "QS_LOG": logs["qs"], "SHELL_LOG": logs["shell"],
           "QS_CONFIG_PATH": "/elsewhere", "QS_MANIFEST": "x", "MARKER_PATH": os.path.join(run, "grassfield-lock-test_sig")}
    env.update({k: v for k, v in extra.items() if v is not None})
    return env


def read(name):
    try:
        return [json.loads(l) for l in open(logs[name]) if l.strip()]
    except FileNotFoundError:
        return []


MARKER = os.path.join(run, "grassfield-lock-test_sig")


def reset(marker=None):
    # Empty logs; the shell's lock marker absent, or holding `marker`, or a directory (a marker that cannot be read) for "".
    for p in logs.values():
        if os.path.exists(p):
            os.unlink(p)
    if os.path.isdir(MARKER):
        os.rmdir(MARKER)
    elif os.path.exists(MARKER):
        os.unlink(MARKER)
    if marker == "":
        os.mkdir(MARKER)
    elif marker is not None:
        write(MARKER, marker, 0o600)


def start(args=(), program="hyprland-share-picker", marker=None, **extra):
    reset(marker)
    return subprocess.Popen([os.path.join(bindir, program)] + list(args), env=env_for(**extra), stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, stdin=subprocess.DEVNULL)


def finish(p, timeout=25):
    began = time.monotonic()
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
    return out.decode(), err.decode(), time.monotonic() - began


def picker(args=(), program="hyprland-share-picker", marker=None, **extra):
    return finish(start(args, program, marker, **extra))


def xdph(out):
    # xdph 1.4.1, promptForScreencopySelection after runSync: the same string operations, in the same order.
    if "[SELECTION]" not in out:
        return None
    selection = out[out.find("[SELECTION]") + 11:]
    flags = selection[:selection.find("/")] if "/" in selection else selection
    sel = selection[selection.find("/") + 1:]
    data = {"allowToken": "r" in flags}
    if sel.startswith("screen:"):
        data.update(type="output", output=sel[7:][:-1])
    elif sel.startswith("window:"):
        data.update(type="window", handleLo=int(re.match(r"\d+", sel[7:]).group(0)) & 0xFFFFFFFF)
    elif sel.startswith("region:"):
        running = sel[7:]
        data.update(type="geometry", output=running[:running.find("@")])
        running = running[running.find("@") + 1:]
        x, y, w, h = (int(v) for v in running.split(",", 3))
        data.update(x=x, y=y, w=w, h=h)
    else:
        data["type"] = "invalid"
    return data


def shell_answers(answer, script=None, **extra):
    steps = script if script is not None else ["list", "say:wait", "sleep:0.2", "say:" + answer]
    return picker(FAKE_QS="accept", FAKE_SCRIPT=json.dumps(steps), **extra)


# A-SP1: each choice as xdph reads it; the window list the shell gets.
out, err, took = shell_answers("/screen:DP-1")
check(out == "[SELECTION]/screen:DP-1\n" and xdph(out) == {"allowToken": False, "type": "output", "output": "DP-1"},
      "Entire Screen: xdph reads the display DP-1, no restore token [%r]" % out)
check(err == "", "nothing on stderr")
seen = [e for e in read("shell") if e["event"] == "list"]
qs = read("qs")
rid = qs[0]["argv"][-2] if qs else ""
listed = None
if seen and seen[0]["line"].startswith(rid + " list "):
    listed = json.loads(seen[0]["line"][len(rid) + 6:])
check(re.fullmatch(r"[0-9a-f]{32}", rid) is not None and listed == [
    {"handle": "123456", "class": "org.gnome.TextEditor", "title": "notes.txt", "address": "0x%x" % 94371412345678},
    {"handle": "4294967295", "class": "firefox", "title": "A page — Firefox", "address": ""}],
    "the shell gets the request id and xdph's windows on the socket, addresses in hex, an unreadable entry left out [%r]" % listed)
check(qs and qs[0]["argv"][:7] == ["ipc", "-p", "/usr/share/grassfield/shell", "call", "picker", "request", rid]
      and qs[0]["argv"][-1].startswith(picker_dir + "/") and qs[0]["argv"][-1].endswith(".sock"),
      "the shell is asked with qs ipc -p /usr/share/grassfield/shell call picker request <id> <socket> [%r]" % (qs[0]["argv"] if qs else None))
check(qs and qs[0]["qsenv"] == [], "Quickshell's option variables and the window list are not passed to qs ipc")
check(all(not l.endswith(" +list") for l in open(logs["hyprctl"]).read().splitlines()), "the window list is not passed to hyprctl")
check(qs and qs[0]["socket"] == ["0o600", True] and qs[0]["dir"] == ["0o700", False],
      "the one-time socket is 0600 in a 0700 directory when the shell is asked [%r]" % (qs[0] if qs else None))
check(os.listdir(picker_dir) == [], "the socket file is gone afterwards")
options = [e for e in read("shell") if e["event"] == "options"]
check(len(options) == 1 and options[0]["line"] == rid + ' options {"allowToken": false}\n',
      "without --allow-token the shell gets allowToken false, before the list [%r]" % options)
out, _, _ = shell_answers("r/screen:DP-1", args=["--allow-token"])
options = [e for e in read("shell") if e["event"] == "options"]
rid2 = read("qs")[0]["argv"][-2] if read("qs") else ""
check(len(options) == 1 and options[0]["line"] == rid2 + ' options {"allowToken": true}\n'
      and xdph(out) == {"allowToken": True, "type": "output", "output": "DP-1"},
      "with xdph's --allow-token the shell gets allowToken true (Remember this choice opens ticked), and xdph reads the token "
      "flag [%r %r]" % (options, out))

# A long list (150 windows titled with 200 emoji each: 360 KB of JSON, past a socket's send buffer) reaches the shell whole.
big = "".join("%d[HC>]app[HT>]%s[HE>]0[HA>]" % (i + 1, "\U0001F600" * 200) for i in range(150))
out, _, _ = shell_answers("/window:150", XDPH_WINDOW_SHARING_LIST=big)
seen = [e for e in read("shell") if e["event"] == "list"]
got = json.loads(seen[0]["line"].split(" list ", 1)[1]) if seen else []
check(out == "[SELECTION]/window:150\n" and len(got) == 150 and got[149]["title"] == "\U0001F600" * 200,
      "a list past the socket's buffer reaches the shell whole [%d windows, %r]" % (len(got), out))
out, _, _ = shell_answers("r/window:123456")
check(xdph(out) == {"allowToken": True, "type": "window", "handleLo": 123456},
      "Window with Remember this choice: xdph reads the listed window and the restore-token flag [%r]" % out)
out, _, _ = shell_answers("/window:4294967295")
check(xdph(out) == {"allowToken": False, "type": "window", "handleLo": 4294967295}, "the largest handle xdph can list [%r]" % out)
out, _, _ = shell_answers("/region:DP-2@1200,700,80,20")
check(xdph(out) == {"allowToken": False, "type": "geometry", "output": "DP-2", "x": 1200, "y": 700, "w": 80, "h": 20},
      "a region at the edge of the second display's logical size (2560x1440 at scale 2) [%r]" % out)

for bad, why in (("/window:999", "a window xdph did not list"), ("/screen:HDMI-A-9", "a display Hyprland does not list"),
                 ("/region:DP-2@1201,700,80,20", "a region past the display's logical width"),
                 ("/region:DP-1@0,0,0,10", "an empty region"), ("x/screen:DP-1", "an unknown flag"),
                 ("/screen:DP-1 /window:123456", "trailing text"), ("/screen:DP-1;x", "a display name with other characters"),
                 ("screen:DP-1", "no flags field"), ("/window:0123456", "a handle written otherwise"),
                 ("/region:DP-1@-1,0,10,10", "a negative coordinate")):
    out, _, _ = shell_answers(bad)
    check(out == "", "nothing is printed for %s [%r]" % (why, out))

# A-SP2: the channel.
out, _, took = shell_answers(None, ["list", "say:cancel"])
check(out == "" and took < 2, "the shell's cancel prints nothing, at once [%.1f s]" % took)
out, _, _ = shell_answers(None, ["list", "sayas:%s /screen:DP-1" % ("0" * 32), "say:/window:123456"])
check(xdph(out) == {"allowToken": False, "type": "window", "handleLo": 123456}, "a line with another id is ignored [%r]" % out)
out, _, took = shell_answers(None, ["list", "close"])
check(out == "" and took < 2 and read("stock") == [], "a shell that closes without an answer: nothing, and never the stock picker [%.1f s]" % took)
for answer in ("busy", "locked"):
    out, _, took = picker(FAKE_QS=answer)
    check(out == "" and took < 2 and read("stock") == [], "the shell's %s: nothing printed, no stock picker [%.1f s]" % (answer, took))

# A-SP2b: every wait is bounded.
out, _, took = picker(FAKE_QS="accept-noconnect")
check(out == "" and took < 3.5 and read("stock") == [] and os.listdir(picker_dir) == [],
      "accepted but no connection: nothing within 2 s of the answer, the socket file gone, no stock picker [%.1f s]" % took)
p = start(FAKE_QS="late")
out, _, took = finish(p)
time.sleep(1)
stocks = read("stock")
events = [e["event"] for e in read("shell")]
check(len(stocks) == 1 and stocks[0]["left"] == [] and events == ["connect-failed"],
      "no answer within 1 s: the stock picker runs once the socket file is gone, and a late accepted cannot connect [%r %r]" % (stocks, events))
out, _, took = shell_answers(None, ["list", "say:wait", "sleep:30"])
check(out == "" and 15 <= took < 16.5, "a shell that stops writing: nothing, after 15 s without a line [%.1f s]" % took)
out, _, took = shell_answers(None, ["list"] + ["sayas:%s wait" % ("0" * 32), "sleep:4"] * 5 + ["say:/screen:DP-1"])
check(out == "" and 15 <= took < 16.5, "lines with another id do not keep the stand-in waiting: nothing, after 15 s [%.1f s]" % took)
out, _, took = shell_answers(None, ["list"] + ["say:wait", "sleep:4"] * 5 + ["say:/screen:DP-1"])
check(xdph(out) == {"allowToken": False, "type": "output", "output": "DP-1"} and took > 19,
      "a shell that says wait keeps the stand-in waiting past 15 s for the user's choice [%.1f s]" % took)

# xdph gone (its end of stdout closed): the stand-in cancels and the shell's panel closes (its end of the socket ends).
p = start(FAKE_QS="accept", FAKE_SCRIPT=json.dumps(["list", "eof:6"]))
deadline = time.monotonic() + 5
while time.monotonic() < deadline and not any(e["event"] == "list" for e in read("shell")):
    time.sleep(0.05)
p.stdout.close()
gone = time.monotonic()
try:
    p.wait(timeout=5)
except subprocess.TimeoutExpired:
    p.kill()
time.sleep(0.3)
ends = [e for e in read("shell") if e["event"] in ("eof", "no-eof", "data")]
check(ends and ends[0]["event"] == "eof" and p.returncode == 0 and time.monotonic() - gone < 3,
      "xdph gone: the stand-in ends and the shell's side of the socket closes [%r]" % ends)

# A-SP3: locked, or its lock unknown: nothing, and neither the shell nor the stock picker is asked.
locked_monitors = json.dumps([{"name": "DP-1", "solitaryBlockedBy": ["LOCK"]}, {"name": "DP-2", "solitaryBlockedBy": ["LOCK", "X"]}])
answers = {"FAKE_QS": "accept", "FAKE_SCRIPT": json.dumps(["list", "say:/screen:DP-1"])}
for desc, extra, marker in (
        ("Hyprland reports the lock on every display", {"FAKE_MONITORS": locked_monitors}, None),
        ("hyprctl fails", {"FAKE_HYPRCTL": "fail"}, None),
        ("hyprctl does not answer in 1 s", {"FAKE_HYPRCTL": "hang"}, None),
        ("hyprctl prints no JSON", {"FAKE_HYPRCTL": "garbage"}, None),
        ("Hyprland lists no display", {"FAKE_MONITORS": "[]"}, None),
        ("Hyprland's answer is not a list of displays", {"FAKE_MONITORS": '{"name": "DP-1"}'}, None),
        ("the shell's marker says locked", {}, "locked\n"),
        ("the shell's marker says locked during a sleep", {}, "locked sleeps=2\n"),
        ("the shell's marker holds something else", {}, "unlock\n"),
        ("the shell's marker cannot be read", {}, "")):
    out, _, took = picker(marker=marker, **dict(answers, **extra))
    check(out == "" and read("qs") == [] and read("stock") == [] and took < 2.5,
          "locked when %s: nothing printed, neither the shell nor the stock picker asked [%.1f s]" % (desc, took))
out, _, _ = picker(marker="unlocked\n", **answers)
check(out == "[SELECTION]/screen:DP-1\n", "a marker that says unlocked: the picker is asked [%r]" % out)
# The shell writes "unlocked sleeps=<n>" where the count of suspends can be read (LockMachine.markerLine): unlocked when n
# is the machine's count now or the count cannot be read; a sleep since then, that no shell locked for, is locked.
write(suspends, "3\n", 0o644)
out, _, _ = picker(marker="unlocked sleeps=3\n", **answers)
check(out == "[SELECTION]/screen:DP-1\n", "the shell's unlocked marker with the machine's count of suspends: the picker is asked [%r]" % out)
out, _, _ = picker(marker="unlocked sleeps=2\n", **answers)
check(out == "" and read("qs") == [], "an unlocked marker written before a sleep no shell locked for: locked [%r]" % out)
for bad in ("unlocked sleeps=\n", "unlocked sleeps=x\n", "unlocked sleeps=3 x\n", "unlocked  sleeps=3\n", "UNLOCKED\n"):
    out, _, _ = picker(marker=bad, **answers)
    check(out == "" and read("qs") == [], "a marker outside the shell's grammar is locked: %r" % bad)
os.unlink(suspends)
out, _, _ = picker(marker="unlocked sleeps=2\n", **answers)
check(out == "[SELECTION]/screen:DP-1\n", "the count of suspends unreadable: the shell's unlocked marker stands [%r]" % out)
reset()
one_locked = json.dumps([{"name": "DP-1", "solitaryBlockedBy": ["LOCK"]}, {"name": "DP-2", "width": 2560, "height": 1440, "scale": 2}])
out, _, _ = shell_answers("/screen:DP-2", FAKE_MONITORS=one_locked)
check(out == "" and read("qs") == [], "the lock on one display of two is the session's: locked, as the shell reads it [%r]" % out)
blocked_otherwise = json.dumps([{"name": "DP-1", "width": 1920, "height": 1080, "scale": 1, "solitaryBlockedBy": ["FULLSCREEN"]}])
out, _, _ = shell_answers("/screen:DP-1", FAKE_MONITORS=blocked_otherwise)
check(out == "[SELECTION]/screen:DP-1\n", "a display blocked by something else than the lock: the picker is asked [%r]" % out)

# SP9: no shell, unlocked: the stock picker with the same arguments and window list, by the name xdph used.
for how in ("fail", "silent", "garbage"):
    out, _, took = picker(["--allow-token"], FAKE_QS=how)
    stocks = read("stock")
    check(len(stocks) == 1 and stocks[0]["name"] == "hyprland-share-picker" and stocks[0]["args"] == ["--allow-token"]
          and stocks[0]["list"] == WINDOWS and stocks[0]["left"] == [] and took < 2.5,
          "the shell's %s: the stock picker, its arguments and window list kept, no channel file left [%.1f s %r]" % (how, took, stocks))
check(stocks and not stocks[0]["sigpipe_ignored"], "the stock picker runs with SIGPIPE at its default, not ignored as in Python")
out, _, took = picker(["--allow-token"], FAKE_QS="lock-then-silent")
check(out == "" and read("stock") == [], "the session locked while the shell was asked: no stock picker either [%r]" % read("stock"))
out, _, _ = picker(["--allow-token"], program="hyprland-preview-share-picker", FAKE_QS="fail")
stocks = read("stock")
check(len(stocks) == 1 and stocks[0]["name"] == "hyprland-preview-share-picker" and stocks[0]["args"] == ["--allow-token"],
      "Omarchy's picker name falls back to Omarchy's stock picker [%r]" % stocks)
out, _, _ = picker(["--allow-token"], program="hyprland-preview-share-picker", FAKE_QS="accept",
                   FAKE_SCRIPT=json.dumps(["list", "say:/screen:DP-1"]))
check(out == "[SELECTION]/screen:DP-1\n", "Omarchy's picker name shows the Grassfield picker [%r]" % out)
out, _, _ = picker(["--stock-name", "/bin/sh"], FAKE_QS="fail")
check(out == "" and read("stock") == [] and read("qs") == [], "--stock-name takes only the two picker names [%r]" % read("stock"))

# The dev plumbing: GRASSFIELD_SHELL_DIR only inside a dev session.
for desc, extra, expected in (
        ("a dev session", {"GRASSFIELD_DEV": "1", "GRASSFIELD_SHELL_DIR": "/repo/shell"}, "/repo/shell"),
        ("the real session", {"GRASSFIELD_DEV": "1", "GRASSFIELD_SESSION": "1", "GRASSFIELD_SHELL_DIR": "/repo/shell"},
         "/usr/share/grassfield/shell"),
        ("no dev flag", {"GRASSFIELD_SHELL_DIR": "/repo/shell"}, "/usr/share/grassfield/shell"),
        ("a dev flag other than 1", {"GRASSFIELD_DEV": "yes", "GRASSFIELD_SHELL_DIR": "/repo/shell"}, "/usr/share/grassfield/shell")):
    picker(FAKE_QS="busy", **extra)
    qs = read("qs")
    check(qs and qs[0]["argv"][2] == expected, "%s asks the shell at %s [%r]" % (desc, expected, qs[0]["argv"][2] if qs else None))

# A signal while the shell is asked: the socket file goes too.
p = start(FAKE_QS="silent")
deadline = time.monotonic() + 3
while time.monotonic() < deadline and not read("qs"):
    time.sleep(0.05)
os.kill(p.pid, signal.SIGTERM)
out, _, _ = finish(p)
check(out == "" and os.listdir(picker_dir) == [], "SIGTERM while the shell is asked: nothing printed, the socket file gone")

# The channel's directory: one that is not private, or a link, is never used (the stock picker runs instead).
shutil.rmtree(os.path.join(run, "grassfield"))
os.makedirs(picker_dir, 0o755)
os.chmod(picker_dir, 0o755)
out, _, _ = picker(FAKE_QS="accept", FAKE_SCRIPT=json.dumps(["list", "say:/screen:DP-1"]))
check(out == "" and read("qs") == [] and len(read("stock")) == 1, "a picker directory others can read is not used [%r]" % read("qs"))
shutil.rmtree(os.path.join(run, "grassfield"))
os.makedirs(os.path.join(run, "grassfield"), 0o700)
os.makedirs(os.path.join(tmp, "elsewhere"), 0o700)
os.symlink(os.path.join(tmp, "elsewhere"), picker_dir)
out, _, _ = picker(FAKE_QS="accept", FAKE_SCRIPT=json.dumps(["list", "say:/screen:DP-1"]))
check(out == "" and read("qs") == [] and os.listdir(os.path.join(tmp, "elsewhere")) == [],
      "a picker directory that is a link is not used, and nothing is made where it points")
os.unlink(picker_dir)

sys.exit(1 if failed else 0)
