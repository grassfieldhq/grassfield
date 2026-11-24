# ADR-0066 D-1, slice C4: packaging/bin/grassfield-capture's frozen screen (`selection --freeze`) and its `choose` channel against
# fakes of grim, hyprctl, wl-copy, notify-send and xdg-user-dir (run by tests/shell/capture.sh as `python3 -I freeze.py <root> <tmp>`):
# the crop at scale 1.25 equals the pixels the fake grim wrote, `choose` refuses what it must (exit 2, nothing written), the waiting
# helper ignores a choice that is not a private regular file of the right shape, and the frames are gone on every way out.
import json
import os
import re
import signal
import stat
import subprocess
import sys
import time
import zlib

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


fake, home, log, runtime, scratch = (os.path.join(tmp, d) for d in ("ffake", "fhome", "flog", "frun", "fscratch"))
for d in (fake, home, log, scratch):
    os.makedirs(d)
os.makedirs(runtime, mode=0o700)
helper = os.path.join(root, "packaging/bin/grassfield-capture")
source = open(helper).read()
check(re.search(r"^FREEZE_SECONDS = 120\b", source, re.M) is not None and re.search(r"^CHOICE_MAX = 4096$", source, re.M) is not None
      and "hmac.compare_digest" in source, "the wait is 120 s, a choice at most 4 KiB, the token compared with hmac.compare_digest")
# The same helper, with a short acknowledgement wait (no shell here) and, for the timeout, a short freeze wait.
fast = os.path.join(tmp, "grassfield-capture-fast")
write(fast, re.sub(r"^ACK_SECONDS = [0-9.]+$", "ACK_SECONDS = 0.05", source, flags=re.M))
brief = os.path.join(tmp, "grassfield-capture-brief")
write(brief, re.sub(r"^FREEZE_SECONDS = [0-9.]+", "FREEZE_SECONDS = 1.5", open(fast).read(), flags=re.M))

for name in ("grim", "hyprctl", "wl-copy", "notify-send", "xdg-user-dir"):
    write(os.path.join(fake, name), r'''#!/usr/bin/python3 -I
import json, os, sys, time
name = os.path.basename(sys.argv[0])
data = sys.stdin.buffer.read() if name == "wl-copy" else b""
env = os.environ
with open(os.path.join(env["FAKE_LOG"], "calls"), "a") as f:
    f.write(json.dumps({"name": name, "argv": sys.argv[1:], "size": len(data), "t": time.monotonic()}) + "\n")
if name == "grim":
    # grim -t ppm -o NAME PATH: a picture whose pixel (x, y) is ((x + shift) % 256, y % 256, (x + y) % 256)
    out = sys.argv[sys.argv.index("-o") + 1]
    w, h = (int(v) for v in dict(p.split("=") for p in env["FAKE_SIZES"].split(","))[out].split("x"))
    shift = 50 if out == "DP-2" else 0
    base = bytes(i % 256 for i in range(w + 256))
    red = bytes((x + shift) % 256 for x in range(w))
    rows = []
    for y in range(h):
        row = bytearray(w * 3)
        row[0::3] = red
        row[1::3] = bytes([y % 256]) * w
        row[2::3] = base[y % 256:y % 256 + w]
        rows.append(bytes(row))
    open(sys.argv[-1], "wb").write(b"P6\n%d %d\n255\n" % (w, h) + b"".join(rows))
elif name == "hyprctl":
    print(env["FAKE_MONITORS"] if sys.argv[2] == "monitors" else "[]")
elif name == "xdg-user-dir":
    if "FAKE_" + sys.argv[1] in env:
        print(env["FAKE_" + sys.argv[1]])
    else:
        sys.exit(1)
elif name == "notify-send":
    print(17, flush=True)
''')

# DP-1: 1200x800 device pixels at 1.25 (960x640 logical) at 0,0; DP-2: 600x400 at 1.0 at x = 1000 (a gap of 40 between them)
MONITORS = json.dumps([
    {"name": "DP-1", "x": 0, "y": 0, "width": 1200, "height": 800, "scale": 1.25, "transform": 0, "focused": True,
     "activeWorkspace": {"id": 1}, "specialWorkspace": {"id": 0}},
    {"name": "DP-2", "x": 1000, "y": 0, "width": 600, "height": 400, "scale": 1.0, "transform": 0, "focused": False,
     "activeWorkspace": {"id": 2}, "specialWorkspace": {"id": 0}}])
desktop = os.path.join(home, "Desktop")
config = os.path.join(home, ".config", "grassfield")
os.makedirs(config)
with open(os.path.join(config, "grassfield.json"), "w") as f:
    json.dump({"version": 1, "capture": {"location": "desktop", "showThumbnail": False}}, f)
folder = os.path.join(runtime, "grassfield")
state_file, frozen, choice = (os.path.join(folder, n) for n in ("capture-state.json", "frozen", "capture-choice.json"))
marker = os.path.join(runtime, "grassfield-lock-default")
bait = os.path.join(scratch, "bait")
ENV = {"PATH": fake + ":/usr/bin:/bin", "HOME": home, "FAKE_LOG": log, "FAKE_MONITORS": MONITORS, "XDG_RUNTIME_DIR": runtime,
       "FAKE_DESKTOP": desktop, "FAKE_SIZES": "DP-1=1200x800,DP-2=600x400"}
GOOD = "101,53 203x77"


def calls(name):
    try:
        return [c for c in (json.loads(l) for l in open(os.path.join(log, "calls"))) if c["name"] == name]
    except FileNotFoundError:
        return []


def state():
    try:
        return json.load(open(state_file))
    except (OSError, ValueError):
        return {}


def folder_names():
    return sorted(os.listdir(folder)) if os.path.isdir(folder) else []


def written():
    # Anything of a choice in the runtime folder (the file or a half-written one)
    return [n for n in folder_names() if n.startswith("capture-choice")]


def start(args=("selection", "--freeze"), program=fast):
    for p in (os.path.join(log, "calls"), marker):
        if os.path.lexists(p):
            os.unlink(p)
    for n in os.listdir(desktop) if os.path.isdir(desktop) else []:
        os.unlink(os.path.join(desktop, n))
    return subprocess.Popen([program] + list(args), env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def frozen_state(proc, timeout=20):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        st = state()
        if st.get("phase") == "frozen" and st.get("pid") == proc.pid:
            return st
        if proc.poll() is not None:
            return None
        time.sleep(0.02)
    return None


def choose(*args, program=fast):
    return subprocess.run([program, "choose"] + list(args), env=ENV, capture_output=True, timeout=30)


def finish(proc, timeout=20):
    try:
        proc.wait(timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    return proc.returncode


def decode(path):
    # An 8-bit RGB PNG with filter 0 on every row (what the helper writes): (w, h, rows, text chunks)
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    i, idat, text, w, h = 8, b"", {}, 0, 0
    while i < len(data):
        n, kind = int.from_bytes(data[i:i + 4], "big"), data[i + 4:i + 8]
        body = data[i + 8:i + 8 + n]
        if zlib.crc32(kind + body) != int.from_bytes(data[i + 8 + n:i + 12 + n], "big"):
            return None
        if kind == b"IHDR":
            w, h = int.from_bytes(body[:4], "big"), int.from_bytes(body[4:8], "big")
            assert body[8:] == b"\x08\x02\x00\x00\x00"
        elif kind == b"IDAT":
            idat += body
        elif kind == b"tEXt":
            k, _, v = body.partition(b"\0")
            text[k.decode()] = v.decode()
        i += 12 + n
    raw = zlib.decompress(idat)
    stride = 1 + w * 3
    rows = [raw[y * stride + 1:(y + 1) * stride] for y in range(h)]
    assert all(raw[y * stride] == 0 for y in range(h)) and len(raw) == stride * h
    return w, h, rows, text


def expected(output, x0, x1, y0, y1):
    shift = 50 if output == "DP-2" else 0
    return [bytes(c for x in range(x0, x1) for c in ((x + shift) % 256, y % 256, (x + y) % 256)) for y in range(y0, y1)]


def pictures():
    return sorted(n for n in os.listdir(desktop) if n.endswith(".png"))


# ---- the crop is pixel-exact at scale 1.25, and the frames are private and gone afterwards ----
proc = start()
st = frozen_state(proc)
check(st is not None and re.fullmatch(r"[0-9a-f]{32}", st.get("token", "")) is not None and st.get("pid") == proc.pid
      and [f.get("output") for f in st.get("frames", [])] == ["DP-1", "DP-2"], "the state says frozen with a 128-bit token and the frames" + (" [%r]" % st.get("token") if st else ""))
if st:
    modes = {n: stat.S_IMODE(os.lstat(os.path.join(frozen, n)).st_mode) for n in os.listdir(frozen)}
    check(stat.S_IMODE(os.lstat(frozen).st_mode) == 0o700 and sorted(modes) == ["0.ppm", "1.ppm"] and set(modes.values()) == {0o600},
          "the frozen folder is 0700 and its frames 0600 [%r]" % modes)
    check(st["frames"][0]["rect"] == {"x": 0, "y": 0, "w": 960, "h": 640} and st["frames"][0]["scale"] == 1.25
          and st["frames"][1]["rect"] == {"x": 1000, "y": 0, "w": 600, "h": 400},
          "each frame: its logical rectangle and its scale")
    r = choose("--token", st["token"], "--geometry", GOOD)
    rc = finish(proc)
    check(r.returncode == 0 and rc == 0 and len(pictures()) == 1, "a good choice: choose exits 0, the helper saves one picture [%r %r]" % (r.returncode, rc))
    got = decode(os.path.join(desktop, pictures()[0])) if pictures() else None
    # 101,53 203x77 at 1.25: x 126.25 -> 126 to 380, y 66.25 -> 66 to 162.5 -> 163 (rounded outwards)
    check(got is not None and got[:2] == (254, 97) and got[2] == expected("DP-1", 126, 380, 66, 163)
          and got[3] == {"Grassfield-Scale": "1.25"}, "scale 1.25: the crop is 254x97 and every pixel equals the frame's, rounded outwards [%r]"
          % ((got[:2] if got else None),))
    check(not os.path.lexists(frozen) and not written() and state().get("phase") == "idle" and len(calls("wl-copy")) == 1,
          "frames and choice removed on finish, the phase idle, the picture copied [%r]" % folder_names())
    check(len(calls("grim")) == 2 and all(c["argv"][:3] == ["-t", "ppm", "-o"] for c in calls("grim")),
          "one grim call per display, as PPM [%r]" % [c["argv"][:4] for c in calls("grim")])

proc = start()
st = frozen_state(proc)
if st:
    r = choose("--token", st["token"], "--geometry", "1010,5 100x50")
    rc = finish(proc)
    got = decode(os.path.join(desktop, pictures()[0])) if pictures() else None
    check(r.returncode == 0 and rc == 0 and got and got[:2] == (100, 50) and got[2] == expected("DP-2", 10, 110, 5, 55)
          and got[3] == {"Grassfield-Scale": "1.0"}, "the second display at scale 1.0: its own pixels, offset by its place")

# ---- choose refuses (exit 2, nothing written) ----
proc = start()
st = frozen_state(proc)
if st:
    tok = st["token"]
    refused = [("a wrong token", ["--token", "f" * 32, "--geometry", GOOD]),
               ("a wrong token, cancel", ["--token", "f" * 32, "--cancel"]),
               ("an upper-case token", ["--token", tok.upper().replace("E", "A"), "--geometry", GOOD]),
               ("a 31-digit token", ["--token", tok[:31], "--geometry", GOOD]),
               ("a 33-digit token", ["--token", tok + "0", "--geometry", GOOD]),
               ("a token with a newline", ["--token", tok + "\n", "--geometry", GOOD]),
               ("a geometry in the gap between displays", ["--token", tok, "--geometry", "970,10 20x20"]),
               ("a geometry across two displays", ["--token", tok, "--geometry", "900,10 200x20"]),
               ("a geometry below the frames", ["--token", tok, "--geometry", "10,630 20x20"]),
               ("a geometry at negative coordinates", ["--token", tok, "--geometry", "-5,10 20x20"]),
               ("a geometry far outside", ["--token", tok, "--geometry", "5000,5000 20x20"])]
    for n, geo in enumerate(["", "10,10", "10,10 0x20", "10,10 20x0", "10,10 -20x20", "10 10 20x20", "10,10 20X20", "10,10  20x20",
                             " 10,10 20x20", "10,10 20x20 ", "10,10 20x20\n", "1e1,10 20x20", "10,10 20x20;touch injected",
                             "$(touch injected),1 2x2", "1,1 1000000x1", "٣,1 2x2", "10,10 20x20\x00"], 1):
        refused.append(("malformed geometry #%d %r" % (n, geo), ["--token", tok, "--geometry", geo]))
    check(sum(1 for d, _ in refused if d.startswith("malformed")) >= 14, "14 or more malformed geometries are tried")
    bad = []
    for desc, args in refused:
        try:
            r = choose(*args)
        except ValueError:  # a NUL cannot be an argument: nothing to refuse
            continue
        if r.returncode != 2 or written() or proc.poll() is not None:
            bad.append((desc, r.returncode, written()))
    check(not bad and not os.path.exists("injected") and not os.path.exists(os.path.join(folder, "injected")),
          "choose refuses each (exit 2), writes nothing, runs nothing, and the helper still waits [%r]" % bad)
    r = choose("--token", tok)
    r2 = choose("--geometry", GOOD)
    r3 = choose("--token", tok, "--geometry", GOOD, "--cancel")
    r4 = choose("--token", tok, "--geometry", GOOD, "--geometry", GOOD)
    check([r.returncode, r2.returncode, r3.returncode, r4.returncode] == [2, 2, 2, 2] and not written(),
          "missing, extra or repeated options: the usage, exit 2, nothing written")
    # under the lock, choose is refused and writes nothing
    with open(marker, "w") as f:
        f.write("locked\n")
    r = choose("--token", tok, "--geometry", GOOD)
    check(r.returncode == 1 and not written(), "choose is refused under the lock (exit 1), nothing written [%r]" % r.returncode)
    rc = finish(proc)
    check(rc == 1 and not os.path.lexists(frozen) and not pictures(),
          "the lock ends the wait: no picture, the frames removed, exit 1 [%r]" % rc)

# ---- a dead helper ----
proc = start()
st = frozen_state(proc)
if st:
    os.kill(proc.pid, signal.SIGKILL)
    finish(proc)
    r = choose("--token", st["token"], "--geometry", GOOD)
    check(st.get("phase") == "frozen" and state().get("phase") == "frozen" and r.returncode == 2 and not written(),
          "a dead helper (SIGKILLed, the state left over): choose exits 2, nothing written [%r]" % r.returncode)
    # a recycled pid is not the helper: the start time is checked
    leftover = dict(state(), start=state().get("start", 0) + 1)
    with open(state_file, "w") as f:
        json.dump(leftover, f)
    os.chmod(state_file, 0o600)
    r = choose("--token", st["token"], "--geometry", GOOD)
    check(r.returncode == 2 and not written(), "a state naming another start time: exit 2")
    # the left-over frames (the helper was killed) are removed at the next freeze; a link inside is unlinked, not followed
    with open(bait, "w") as f:
        f.write("keep")
    os.symlink(bait, os.path.join(frozen, "trap"))
    proc = start()
    st2 = frozen_state(proc)
    check(st2 is not None and sorted(os.listdir(frozen)) == ["0.ppm", "1.ppm"] and open(bait).read() == "keep",
          "a left-over frozen folder is removed at the next freeze, a link in it unlinked, not followed")
    r = choose("--token", st["token"], "--geometry", GOOD)
    check(r.returncode == 2 and not written(), "the old token is not the new helper's: exit 2")
    r = choose("--token", st2["token"], "--cancel")
    finish(proc)

# ---- the waiting helper ignores a choice that is not a private regular file of the right shape ----
proc = start()
st = frozen_state(proc)
if st:
    tok = st["token"]
    good = json.dumps({"v": 1, "token": tok, "geometry": GOOD})

    def plant(kind):
        if os.path.lexists(choice):
            os.unlink(choice)
        mode = 0o644 if kind == "mode644" else 0o600
        body = {"link": good, "hardlink": good, "mode644": good, "big": good + " " * 4096, "mode600": good,
                "wrongtoken": json.dumps({"v": 1, "token": "f" * 32, "geometry": GOOD}),
                "outside": json.dumps({"v": 1, "token": tok, "geometry": "970,10 20x20"}),
                "version": json.dumps({"v": 2, "token": tok, "geometry": GOOD}),
                "extra": json.dumps({"v": 1, "token": tok, "geometry": GOOD, "x": 1}),
                "both": json.dumps({"v": 1, "token": tok, "geometry": GOOD, "cancel": True}),
                "cancelfalse": json.dumps({"v": 1, "token": tok, "cancel": False}),
                "garbage": "{" * 4000, "notjson": "hello", "nonascii": json.dumps({"v": 1, "token": tok, "geometry": GOOD}) + "é",
                "array": "[1]"}.get(kind, good)
        path = bait if kind in ("link", "hardlink") else choice
        with open(path, "wb") as f:
            f.write(body.encode("utf-8"))
        os.chmod(path, mode)
        if kind == "link":
            os.symlink(bait, choice)
        elif kind == "hardlink":
            os.link(bait, choice)

    wrongly = []
    for kind in ("link", "hardlink", "mode644", "big", "wrongtoken", "outside", "version", "extra", "both", "cancelfalse", "garbage",
                 "notjson", "nonascii", "array"):
        plant(kind)
        time.sleep(0.3)
        if proc.poll() is not None or pictures():
            wrongly.append(kind)
            break
    check(not wrongly and os.path.lexists(choice), "a choice that is a link, a second name, mode 0644, over 4 KiB, another token, outside "
          "the frames, another version, with extra or both keys, or not JSON is ignored: the helper keeps waiting [%r]" % wrongly)
    # a link left in place is replaced by choose's rename, never followed, and the bait is untouched
    plant("link")
    before = open(bait).read()
    r = choose("--token", tok, "--geometry", "10,10 40x30")
    rc = finish(proc)
    got = decode(os.path.join(desktop, pictures()[0])) if pictures() else None
    check(r.returncode == 0 and rc == 0 and got and got[:2] == (51, 38) and open(bait).read() == before
          and not os.path.islink(choice) and not os.path.lexists(choice),
          "a link in the choice's place is replaced by a real choice, the bait untouched; the choice is deleted after use [%r %r]"
          % (r.returncode, rc))

# ---- cancel, timeout, SIGTERM, stop, the lock at the start ----
proc = start()
st = frozen_state(proc)
if st:
    r = choose("--token", st["token"], "--cancel")
    rc = finish(proc)
    check(r.returncode == 0 and rc == 0 and not pictures() and not os.path.lexists(frozen) and not written()
          and state().get("phase") == "idle" and not calls("wl-copy"), "cancel: no picture, no copy, the frames removed, idle")

proc = start(program=brief)
st = frozen_state(proc)
began = time.monotonic()
rc = finish(proc)
check(st is not None and rc == 1 and 1.0 < time.monotonic() - began < 6 and not pictures() and not os.path.lexists(frozen)
      and not written() and state().get("phase") == "idle", "the timeout: no picture, the frames removed, exit 1 [%r]" % rc)

proc = start()
st = frozen_state(proc)
if st:
    proc.send_signal(signal.SIGTERM)
    rc = finish(proc)
    check(rc == 143 and not os.path.lexists(frozen) and not written() and state().get("phase") == "idle" and not pictures(),
          "SIGTERM: the frames removed, the phase idle, exit 143 [%r]" % rc)

proc = start()
st = frozen_state(proc)
if st:
    r = subprocess.run([fast, "stop"], env=ENV, capture_output=True, timeout=30)
    rc = finish(proc)
    check(r.returncode == 0 and rc == 0 and not os.path.lexists(frozen) and state().get("phase") == "idle" and not pictures(),
          "stop ends the frozen screen: the frames removed, no picture [%r %r]" % (r.returncode, rc))

os.unlink(os.path.join(log, "calls"))
with open(marker, "w") as f:
    f.write("locked\n")
proc = subprocess.Popen([fast, "selection", "--freeze"], env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
rc = finish(proc)
check(rc == 1 and not calls("grim") and not os.path.lexists(frozen) and not pictures(),
      "refused under the lock: exit 1, no grim, no frames [%r]" % rc)
os.unlink(marker)

# ---- the clipboard, and the options that do not go with a frozen screen ----
proc = start(("selection", "--freeze", "--save", "clipboard"))
st = frozen_state(proc)
if st:
    choose("--token", st["token"], "--geometry", GOOD)
    rc = finish(proc)
    copied = calls("wl-copy")
    check(rc == 0 and len(copied) == 1 and copied[0]["argv"] == ["--type", "image/png"] and not pictures() and not os.path.lexists(frozen),
          "Save to Clipboard: the crop is copied, no file")
for args in (["selection", "--freeze", "--timer", "5"], ["selection", "--freeze", "--geometry", GOOD],
             ["selection", "--freeze", "--previous"], ["window", "--freeze"], ["screen", "--freeze"],
             ["selection", "--freeze", "--freeze"], ["record", "selection", "--freeze"]):
    r = subprocess.run([fast] + args, env=ENV, capture_output=True, timeout=30)
    if r.returncode != 2:
        check(False, "usage, exit 2: %r [%r]" % (args, r.returncode))
        break
else:
    check(True, "a timer, a geometry, --previous, another mode or a repeat with --freeze: the usage (exit 2)")

sys.exit(1 if failed else 0)
