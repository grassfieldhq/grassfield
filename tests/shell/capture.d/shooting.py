# ADR-0066 D-1, slices C1 and C2: packaging/bin/grassfield-capture's shooting handshake with a fake shell, and its result
# file (run by tests/shell/capture.sh as `python3 -I shooting.py <root> <tmp>`). A thread plays the shell: it reads the state,
# and when the phase is "shooting" it writes (or, for the refusals, mis-writes) the acknowledgement. The fakes log a monotonic
# time, the clock the thread logs the acknowledgement with, so "grim only after the acknowledgement" is read from the logs.
import json
import os
import re
import signal
import stat
import subprocess
import sys
import threading
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


fake, home, log, runtime, scratch = (os.path.join(tmp, d) for d in ("sfake", "shome", "slog", "srun", "sscratch"))
for d in (fake, home, log, scratch):
    os.makedirs(d)
os.makedirs(runtime, mode=0o700)
helper = os.path.join(root, "packaging/bin/grassfield-capture")
source = open(helper).read()
check(re.search(r"^ACK_SECONDS = 1\.0$", source, re.M) is not None and re.search(r"^ACK_MAX = 64$", source, re.M) is not None,
      "the acknowledgement wait is 1 s at most and the file at most 64 bytes (ADR-0066 D-1)")
# The same helper, waiting 0.5 s for an acknowledgement: the refusals below are read at that deadline.
short = os.path.join(tmp, "grassfield-capture-ack-short")
write(short, re.sub(r"^ACK_SECONDS = [0-9.]+$", "ACK_SECONDS = 0.5", source, flags=re.M))

for name in ("grim", "hyprctl", "wl-copy", "notify-send", "xdg-user-dir", "gpu-screen-recorder"):
    write(os.path.join(fake, name), r'''#!/usr/bin/python3 -I
import json, os, signal, sys, time
name = os.path.basename(sys.argv[0])
data = sys.stdin.buffer.read() if name == "wl-copy" else b""
env = os.environ
with open(os.path.join(env["FAKE_LOG"], "calls"), "a") as f:
    f.write(json.dumps({"name": name, "argv": sys.argv[1:], "size": len(data), "t": time.monotonic()}) + "\n")
if name == "grim":
    w, h = (int(v) for v in env.get("FAKE_PNG", "100x50").split("x"))
    png = (b"\x89PNG\r\n\x1a\n" + (13).to_bytes(4, "big") + b"IHDR" + w.to_bytes(4, "big") + h.to_bytes(4, "big")
           + b"\x08\x06\x00\x00\x00fake")
    if sys.argv[-1] == "-":
        sys.stdout.buffer.write(png)
    else:
        open(sys.argv[-1], "wb").write(png)
elif name == "hyprctl":
    print(env["FAKE_MONITORS"] if sys.argv[2] == "monitors" else "[]")
elif name == "xdg-user-dir":
    if "FAKE_" + sys.argv[1] in env:
        print(env["FAKE_" + sys.argv[1]])
    else:
        sys.exit(1)
elif name == "notify-send":
    print(17, flush=True)
elif name == "gpu-screen-recorder":
    out = sys.argv[sys.argv.index("-o") + 1]
    open(out, "wb").write(b"movie")
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    time.sleep(60)
''')

MONITORS = json.dumps([
    {"name": "DP-1", "x": 0, "y": 0, "width": 2400, "height": 1350, "scale": 1.25, "transform": 0, "focused": True,
     "activeWorkspace": {"id": 1}, "specialWorkspace": {"id": 0}}])
desktop = os.path.join(home, "Desktop")
config = os.path.join(home, ".config", "grassfield")
os.makedirs(config)
folder = os.path.join(runtime, "grassfield")
state_file, ack_file, result_file = (os.path.join(folder, n) for n in ("capture-state.json", "capture-ack", "capture-result.json"))
BASE = {"PATH": fake + ":/usr/bin:/bin", "HOME": home, "FAKE_LOG": log, "FAKE_MONITORS": MONITORS, "XDG_RUNTIME_DIR": runtime,
        "FAKE_DESKTOP": desktop}


def set_config(capture):
    with open(os.path.join(config, "grassfield.json"), "w") as f:
        json.dump({"version": 1, "capture": dict({"location": "desktop"}, **capture)}, f)


def calls(name=None):
    try:
        lines = [json.loads(l) for l in open(os.path.join(log, "calls"))]
    except FileNotFoundError:
        return []
    return [c for c in lines if name is None or c["name"] == name]


def reset():
    for p in (os.path.join(log, "calls"), ack_file, result_file, state_file):
        if os.path.lexists(p):
            os.unlink(p)
    for f in os.listdir(desktop) if os.path.isdir(desktop) else []:
        os.unlink(os.path.join(desktop, f))


def state():
    try:
        return json.load(open(state_file))
    except (OSError, ValueError):
        return {}


class Shell(threading.Thread):
    """The shell's side of the handshake: acknowledges each `shooting` state its own way."""

    def __init__(self, mode):
        super().__init__(daemon=True)
        self.mode, self.acks, self.phases, self.seqs, self.stopping, self.seen = mode, [], [], [], False, None

    def run(self):
        while not self.stopping:
            st = state()
            phase = st.get("phase")
            if phase and (not self.phases or self.phases[-1] != phase):
                self.phases.append(phase)
            seq = st.get("seq")
            if phase == "shooting" and self.seen is None:
                self.seen = time.monotonic()
            if phase == "shooting" and seq not in self.seqs and self.mode != "none":
                self.seqs.append(seq)
                asked = time.monotonic()  # taken before the write: the helper cannot accept the answer earlier
                self.answer(seq)
                self.acks.append(asked)
            time.sleep(0.003)

    def answer(self, seq):
        mode, bait = self.mode, os.path.join(scratch, "bait")
        if mode in ("good", "newline"):
            fd = os.open(ack_file, os.O_WRONLY | os.O_CREAT, 0o600)  # the shell pre-creates it 0600, then writes in place
            os.write(fd, (seq + ("\n" if mode == "newline" else "")).encode())
            os.close(fd)
        elif mode == "wrong":
            fd = os.open(ack_file, os.O_WRONLY | os.O_CREAT, 0o600)
            os.write(fd, b"0" * 16)
            os.close(fd)
        elif mode == "mode644":
            fd = os.open(ack_file, os.O_WRONLY | os.O_CREAT, 0o644)
            os.write(fd, seq.encode())
            os.fchmod(fd, 0o644)
            os.close(fd)
        elif mode == "big":
            fd = os.open(ack_file, os.O_WRONLY | os.O_CREAT, 0o600)
            os.write(fd, (seq + "\n" + "x" * 60).encode())  # 77 bytes
            os.close(fd)
        elif mode in ("link", "hardlink"):
            with open(bait, "wb") as f:
                f.write(seq.encode())
            os.chmod(bait, 0o600)
            (os.symlink if mode == "link" else os.link)(bait, ack_file)

    def finish(self):
        self.stopping = True
        self.join(5)


def env_of(extra):
    env = dict(BASE)
    env.update(extra)
    return env


def shot(args, mode, program=None, before=None, **extra):
    reset()
    if before:
        before()
    shell = Shell(mode)
    shell.start()
    began = time.monotonic()
    r = subprocess.run([program or helper] + args, env=env_of(extra), capture_output=True, timeout=60)
    took = time.monotonic() - began
    shell.finish()
    return r, took, began, shell


# ---- C1: grim only after the acknowledgement ----
set_config({"showThumbnail": False})
r, took, began, shell = shot(["screen"], "good")
grim = calls("grim")
check(r.returncode == 0 and len(grim) == 1 and len(shell.acks) == 1 and shell.acks[0] < grim[0]["t"] < shell.acks[0] + 0.8,
      "the picture is taken after the acknowledgement, and at once after it (no 1 s wait) [ack %.3f, grim %.3f, took %.2f]"
      % (shell.acks[0] - began if shell.acks else -1, grim[0]["t"] - began if grim else -1, took))
check(shell.phases[:2] == ["shooting", "idle"] and state().get("phase") == "idle",
      "the phase goes shooting then back to idle after the picture [%r]" % shell.phases)
check(len(shell.seqs) == 1 and re.fullmatch(r"[0-9a-f]{16}", shell.seqs[0] or "") is not None,
      "the seq is 16 random hex digits [%r]" % shell.seqs)
r, took, began, shell = shot(["screen"], "newline")
check(r.returncode == 0 and calls("grim") and shell.acks[0] < calls("grim")[0]["t"] < shell.acks[0] + 0.8,
      "an acknowledgement ending in a newline is accepted")

r, took, began, shell = shot(["screen"], "none")
grim = calls("grim")
check(r.returncode == 0 and grim and shell.seen and 0.95 <= grim[0]["t"] - shell.seen < 3.0
      and state().get("phase") == "idle",
      "without an acknowledgement the picture is taken 1 s after the shooting state, the phase back to idle [%.2f s]"
      % (grim[0]["t"] - shell.seen if grim and shell.seen else -1))
check(len(files := os.listdir(desktop)) == 1, "and it is saved: %r" % files)

for mode, why in (("wrong", "a wrong seq"), ("link", "a symbolic link"), ("hardlink", "a second name for the file"),
                  ("mode644", "mode 0644"), ("big", "more than 64 bytes")):
    r, took, began, shell = shot(["screen"], mode, program=short)
    grim = calls("grim")
    check(r.returncode == 0 and grim and shell.acks and shell.seen and grim[0]["t"] - shell.seen >= 0.49
          and state().get("phase") == "idle",
          "an acknowledgement with %s is ignored: the picture waits for the deadline, then goes on [%.2f s]"
          % (why, grim[0]["t"] - shell.seen if grim and shell.seen else -1))

# the timer path: the countdown as before, then the handshake
r, took, began, shell = shot(["screen", "--timer", "5"], "good", program=short)
grim = calls("grim")
check(r.returncode == 0 and shell.phases[:3] == ["countdown", "idle", "shooting"] and shell.phases[-1] == "idle"
      and grim and shell.acks and grim[0]["t"] > shell.acks[0] and took >= 5,
      "with a timer: countdown, then shooting after it, then idle [%r]" % shell.phases)

# stop during the shooting phase: nothing is captured, the state is idle
reset()
proc = subprocess.Popen([helper, "screen"], env=env_of({}), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
until = time.monotonic() + 5
while state().get("phase") != "shooting" and time.monotonic() < until:
    time.sleep(0.01)
stopped = subprocess.run([helper, "stop"], env=env_of({}), capture_output=True, timeout=30)
proc.wait(timeout=30)
check(stopped.returncode == 0 and proc.returncode == 0 and calls("grim") == [] and state().get("phase") == "idle",
      "stop during the shooting phase: no picture, the phase idle [stop %r, helper %r]" % (stopped.returncode, proc.returncode))

# a lock request: no state, no handshake, no picture
marker = os.path.join(runtime, "grassfield-lock-default")
write(marker, "locked\n", 0o600)
r, took, began, shell = shot(["screen"], "good")
check(r.returncode == 1 and calls("grim") == [] and shell.phases == [] and not os.path.exists(state_file),
      "under the lock: no shooting state, no picture")
os.unlink(marker)

# a recorder: only after the acknowledgement
reset()
shell = Shell("good")
shell.start()
proc = subprocess.Popen([helper, "record", "screen"], env=env_of({}), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
until = time.monotonic() + 10
while state().get("phase") != "recording" and time.monotonic() < until:
    time.sleep(0.02)
until = time.monotonic() + 10
while not calls("gpu-screen-recorder") and time.monotonic() < until:  # the state says recording as the recorder is spawned
    time.sleep(0.02)
rec = calls("gpu-screen-recorder")
check(rec and shell.acks and rec[0]["t"] > shell.acks[0] and "shooting" in shell.phases,
      "the recorder starts after the acknowledgement [%r]" % shell.phases)
subprocess.run([helper, "stop"], env=env_of({}), capture_output=True, timeout=30)
proc.wait(timeout=30)
shell.finish()
check(proc.returncode == 0 and state().get("phase") == "idle", "the recording ends, the phase idle")
rec_result = None
try:
    rec_result = json.load(open(result_file))
except (OSError, ValueError):
    pass
# (config says showThumbnail false above: the notice, no result)
check(rec_result is None and len(calls("notify-send")) == 1, "a recording with the thumbnail off: the notice, no result file")

# ---- C2: the result file ----
set_config({})
r, took, began, shell = shot(["screen"], "good", FAKE_PNG="2400x1350")
st = os.lstat(result_file) if os.path.lexists(result_file) else None
res = json.load(open(result_file)) if st else {}
saved = sorted(os.listdir(desktop))
check(r.returncode == 0 and st and stat.S_ISREG(st.st_mode) and stat.S_IMODE(st.st_mode) == 0o600 and st.st_nlink == 1,
      "the result is a regular file, 0600, one name")
check(set(res) == {"v", "id", "kind", "paths", "primary", "output", "rect", "scale", "pixels", "time", "text"}
      and res["v"] == 1 and re.fullmatch(r"[0-9a-f]{16}", res["id"]) and res["kind"] == "shot"
      and res["paths"] == [os.path.join(desktop, f) for f in saved] and res["primary"] == res["paths"][0]
      and res["output"] == "DP-1" and res["rect"] == {"x": 0, "y": 0, "w": 1920, "h": 1080} and res["scale"] == 1.25
      and res["pixels"] == {"w": 2400, "h": 1350} and abs(res["time"] - time.time() * 1000) < 60000 and res["text"] == "",
      "the result's fields: v, id, kind, paths, primary, output, rect, scale, pixels, time, text [%r]" % res)
check(os.listdir(folder).count("capture-result.json") == 1 and not [f for f in os.listdir(folder) if f.endswith(".tmp")],
      "no temporary file is left beside it")
check(calls("notify-send") == [], "the thumbnail on (the default): no notice")
copied = calls("wl-copy")
check(len(copied) == 1 and copied[0]["argv"] == ["--type", "image/png", "--sensitive"],
      "the automatic copy is wl-copy --type image/png --sensitive [%r]" % [c["argv"] for c in copied])

first = res.get("id")
r, took, began, shell = shot(["screen"], "good")
check(json.load(open(result_file)).get("id") not in (None, first), "a second capture replaces the result (a new id)")


# by rename, never through a link: a link planted where the result goes is replaced, its target untouched
victim = os.path.join(scratch, "victim")


def plant():
    with open(victim, "w") as f:
        f.write("untouched")
    os.makedirs(folder, exist_ok=True)
    os.symlink(victim, result_file)


r, took, began, shell = shot(["screen"], "good", before=plant)
check(r.returncode == 0 and open(victim).read() == "untouched" and not os.path.islink(result_file)
      and json.load(open(result_file)).get("v") == 1 and stat.S_IMODE(os.lstat(result_file).st_mode) == 0o600,
      "a link planted at the result's place is replaced by the rename, never followed")

# a result that cannot be written (no private runtime folder): the notice stands in, whatever the setting
r, took, began, shell = shot(["screen"], "none", XDG_RUNTIME_DIR="not/absolute")
check(r.returncode == 0 and len(calls("notify-send")) == 1 and len(os.listdir(desktop)) == 1,
      "no runtime folder: the picture is saved and the notice is shown")

# capture.showThumbnail: the notice is skipped when on (true, absent, not a boolean), kept when off
for value, notice in ((True, 0), (False, 1), ("no", 0), (0, 0), (None, 0)):
    set_config({} if value is None else {"showThumbnail": value})
    r, took, began, shell = shot(["screen"], "good")
    check(r.returncode == 0 and len(calls("notify-send")) == notice and os.path.exists(result_file) == (notice == 0),
          "showThumbnail %r: %s [notices %d, result %s]" % (value if value is not None else "absent",
                                                           "no notice, a result" if notice == 0 else "the notice, no result",
                                                           len(calls("notify-send")), os.path.exists(result_file)))

# not acknowledged (no shell answers in time): the setting on still writes the result, but the notice shows the picture
set_config({})
r, took, began, shell = shot(["screen"], "none", program=short)
check(r.returncode == 0 and len(calls("notify-send")) == 1 and os.path.exists(result_file),
      "showThumbnail on, no acknowledgement: the notice AND a result [notices %d, result %s]"
      % (len(calls("notify-send")), os.path.exists(result_file)))
r, took, began, shell = shot(["screen"], "wrong", program=short)
check(r.returncode == 0 and len(calls("notify-send")) == 1 and os.path.exists(result_file),
      "showThumbnail on, an invalid acknowledgement: the notice and a result")
# a recording not acknowledged: the notice too
reset()
proc = subprocess.Popen([short, "record", "screen"], env=env_of({}), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
until = time.monotonic() + 10
while not calls("gpu-screen-recorder") and time.monotonic() < until:
    time.sleep(0.02)
time.sleep(0.3)
subprocess.run([short, "stop"], env=env_of({}), capture_output=True, timeout=30)
proc.wait(timeout=30)
check(len(calls("notify-send")) == 1 and os.path.exists(result_file),
      "a recording not acknowledged: the notice and a result")
set_config({"showThumbnail": False})
r, took, began, shell = shot(["screen"], "good")
check(len(calls("notify-send")) == 1 and not os.path.exists(result_file),
      "showThumbnail off, even acknowledged: the notice, no result")
set_config({})

# the clipboard: a saved picture is copied sensitive; Save to Clipboard is the user's own copy and is not
set_config({"location": "clipboard"})
r, took, began, shell = shot(["screen"], "good")
copied = calls("wl-copy")
check(r.returncode == 0 and len(copied) == 1 and copied[0]["argv"] == ["--type", "image/png"]
      and not os.path.exists(result_file) and calls("notify-send") == [],
      "Save to Clipboard: a normal copy (the user's choice), no file, no result, no notice")

# an area: the display under it, the area's own rectangle
set_config({})
r, took, began, shell = shot(["selection", "--geometry", "100,200 300x150"], "good", FAKE_PNG="375x188")
res = json.load(open(result_file)) if os.path.exists(result_file) else {}
check(res.get("rect") == {"x": 100, "y": 200, "w": 300, "h": 150} and res.get("output") == "DP-1"
      and res.get("pixels") == {"w": 375, "h": 188} and res.get("scale") == 1.25, "an area: its rectangle on its display [%r]" % res)

# a recording: a result of kind recording, the notice skipped
reset()
shell = Shell("good")
shell.start()
proc = subprocess.Popen([helper, "record", "screen"], env=env_of({}), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
until = time.monotonic() + 10
while state().get("phase") != "recording" and time.monotonic() < until:
    time.sleep(0.02)
subprocess.run([helper, "stop"], env=env_of({}), capture_output=True, timeout=30)
proc.wait(timeout=30)
shell.finish()
res = json.load(open(result_file)) if os.path.exists(result_file) else {}
check(res.get("kind") == "recording" and len(res.get("paths", [])) == 1 and res["paths"][0].endswith(".mp4")
      and res["pixels"] == {"w": 2400, "h": 1350} and calls("notify-send") == [],
      "a recording: a result of kind recording, no notice [%r]" % res)

# French: the notice (thumbnail off) is in French, the clipboard and the result carry no text
set_config({"showThumbnail": False})
r, took, began, shell = shot(["screen"], "good", LANG="fr_FR.UTF-8")
note = calls("notify-send")
check(note and note[0]["argv"][-2:] == ["Capture d’écran", "Enregistrée sur le Bureau et copiée."]
      and "default=Ouvrir dans la Visionneuse" in note[0]["argv"], "in French: the notice stays « Capture d’écran » [%r]"
      % (note[0]["argv"][-2:] if note else None))

sys.exit(1 if failed else 0)
