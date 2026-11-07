# packaging/bin/grassfield-capture's toolbar modes against fakes (run by tests/shell/capture.sh as
# `python3 -I options.py <root> <tmp>`; ADR-0045 OC-1): the window mode, the options (save to, timer, pointer), screen
# recording with gpu-screen-recorder (Omarchy's backend arguments), the private state the shell watches, and `stop`, which
# signals only the recorder this helper started (its pid, start time and parent), never a process found by its name.
# The fakes answer as the real tools do: slurp 1.5.0 (the smallest fed box for a click, -r restricting the choice to the boxes,
# a click outside every box cancelled), gpu-screen-recorder writing its -o file and ending on SIGINT (it saves on SIGINT, as
# Omarchy's stop relies on), grim writing "-" to its output. Nothing here captures a screen, records or reaches a bus.
import fcntl
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
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


fake, norec, home, log, runtime = (os.path.join(tmp, d) for d in ("ofake", "ofake-norec", "ohome", "olog", "orun"))
for d in (fake, norec, home, log):
    os.makedirs(d)
os.makedirs(runtime, mode=0o700)
helper = os.path.join(root, "packaging/bin/grassfield-capture")
source = open(helper).read()
# The same helper, killing a recorder that ignores SIGINT after 1 s instead of STOP_SECONDS.
quick = os.path.join(tmp, "grassfield-capture-quick")
write(quick, re.sub(r"^STOP_SECONDS = [0-9]+$", "STOP_SECONDS = 1", source, flags=re.M))
tokens = json.load(open(os.path.join(root, "ui/tokens/tokens.json")))["capture"]
slurp_argv = ["-b", tokens["veil"]["value"], "-s", tokens["selection"]["value"], "-c", tokens["border"]["value"],
              "-B", tokens["veil"]["value"], "-w", str(tokens["borderWidth"]["value"])]

# Fakes: each records its argv (and stdin) as one JSON line; behaviour from FAKE_* variables. notify-send runs under its
# own name (exec -a), so the helper finds it in /proc as it finds the real one.
os.makedirs(os.path.join(fake, "impl"))
write(os.path.join(fake, "notify-send"), '#!/bin/bash\nexec -a notify-send /usr/bin/python3 -I "$(dirname "$0")/impl/notify-send" "$@"\n')
NAMES = ("grim", "slurp", "wl-copy", "notify-send", "hyprctl", "xdg-user-dir", "pkill", "systemd-run", "uwsm-app", "gdbus",
         "gpu-screen-recorder", "pw-play")
for name in NAMES:
    write(os.path.join(fake, "impl" if name == "notify-send" else "", name), r'''#!/usr/bin/python3 -I
import json, os, re, signal, sys, time
name = os.path.basename(sys.argv[0])
data = sys.stdin.buffer.read() if name in ("slurp", "wl-copy") else b""
def record(**extra):
    with open(os.path.join(os.environ["FAKE_LOG"], "calls"), "a") as f:
        f.write(json.dumps(dict({"name": name, "argv": sys.argv[1:], "stdin": data[:200].decode("utf-8", "replace"),
                                 "size": len(data), "t": time.monotonic(), "pid": os.getpid(), "ppid": os.getppid()},
                                **extra)) + "\n")
record()
env = os.environ
if name == "grim":
    picture = b"\x89PNG fake " + " ".join(sys.argv[1:-1]).encode()
    if sys.argv[-1] == "-":
        sys.stdout.buffer.write(picture)
    else:
        open(sys.argv[-1], "wb").write(picture)
elif name == "slurp":
    answer = env.get("FAKE_SLURP", "")
    if answer == "":
        sys.exit(1)  # Esc
    click = re.fullmatch(r"click:(-?\d+),(-?\d+)", answer)
    if click:
        px, py = int(click[1]), int(click[2])
        boxes = []
        for line in data.decode().splitlines():
            b = re.fullmatch(r"(-?\d+),(-?\d+) (\d+)x(\d+)", line)
            if b:
                x, y, w, h = map(int, b.groups())
                if x <= px < x + w and y <= py < y + h:
                    boxes.append((w * h, len(boxes), line))
        if not boxes:
            sys.exit(1)  # a click outside every box: "selection cancelled"
        answer = min(boxes, key=lambda b: (b[0], -b[1]))[2]
    elif "-r" in sys.argv:
        sys.exit(1)  # -r: only a box can be chosen
    print(answer)
elif name == "hyprctl":
    if env.get("FAKE_SLOW_HYPRCTL"):
        time.sleep(1)
    if sys.argv[2] == "cursorpos":
        if "FAKE_CURSOR" not in env:
            sys.exit(1)
        print(env["FAKE_CURSOR"])
    else:
        print(env.get("FAKE_MONITORS" if sys.argv[2] == "monitors" else "FAKE_CLIENTS", "[]"))
elif name == "xdg-user-dir":
    answer = env.get("FAKE_" + sys.argv[1], "")
    if not answer:
        sys.exit(1)
    print(answer)
elif name == "pkill":
    sys.exit(1)
elif name == "notify-send":
    print(17, flush=True)
    answer = env.get("FAKE_ANSWER", "")
    if answer:
        print(answer, flush=True)
elif name == "gpu-screen-recorder":
    how = env.get("FAKE_RECORDER", "")
    if how == "fail":
        sys.exit(1)
    out = sys.argv[sys.argv.index("-o") + 1]
    def saved(sig, frame):
        record(signal=signal.Signals(sig).name)
        if how != "ignore":
            with open(out, "ab") as f:
                f.write(b" end")
            sys.exit(0)
    signal.signal(signal.SIGINT, saved)
    signal.signal(signal.SIGTERM, saved)
    if how != "empty":
        with open(out, "wb") as f:
            f.write(b"MP4 fake")
    while True:
        time.sleep(0.05)
''')
for name in os.listdir(fake):
    if name != "gpu-screen-recorder":
        os.symlink(os.path.join(fake, name), os.path.join(norec, name))

MONITORS = json.dumps([
    {"name": "DP-1", "x": 0, "y": 0, "width": 5120, "height": 2880, "scale": 2.0, "transform": 0, "focused": False,
     "activeWorkspace": {"id": 1}, "specialWorkspace": {"id": 0}},
    {"name": "HDMI-A-1", "x": 2560, "y": 0, "width": 1920, "height": 1080, "scale": 1.0, "transform": 0, "focused": True,
     "activeWorkspace": {"id": 2}, "specialWorkspace": {"id": 0}}])


def client(ws, at, size):
    return {"mapped": True, "hidden": False, "workspace": {"id": ws}, "at": at, "size": size, "floating": True, "pinned": False,
            "fullscreen": 0, "allowedOverFullscreen": True, "focusHistoryID": 0}


CLIENTS = json.dumps([client(1, [100, 50], [800, 600]), client(2, [2700, 100], [600, 400])])
desktop, documents = os.path.join(home, "Desktop"), os.path.join(home, "Docs")
BASE = {"PATH": fake + ":/usr/bin:/bin", "HOME": home, "FAKE_LOG": log, "FAKE_MONITORS": MONITORS, "FAKE_CLIENTS": CLIENTS,
        "FAKE_ANSWER": "", "FAKE_DOCUMENTS": documents, "XDG_RUNTIME_DIR": runtime}
state_file = os.path.join(runtime, "grassfield", "capture-state.json")
# Save to: the Desktop chosen in the toolbar (capture.location), which a run without --save follows; the default places (the
# Screenshots folder in Pictures, the Videos folder) are checked where --save asks for them.
os.makedirs(os.path.join(home, ".config", "grassfield"), exist_ok=True)
with open(os.path.join(home, ".config", "grassfield", "grassfield.json"), "w") as f:
    json.dump({"version": 1, "capture": {"location": "desktop"}}, f)
screenshots, videos = os.path.join(home, "Pictures", "Screenshots"), os.path.join(home, "Videos")


def calls(name=None):
    try:
        lines = [json.loads(line) for line in open(os.path.join(log, "calls"))]
    except FileNotFoundError:
        return []
    return [c for c in lines if name is None or c["name"] == name]


def reset():
    if os.path.exists(os.path.join(log, "calls")):
        os.unlink(os.path.join(log, "calls"))


def env_of(extra):
    env = dict(BASE)
    env.update(extra)
    return env


def capture(args, program=None, **extra):
    reset()
    began = time.monotonic()
    r = subprocess.run([program or helper] + args, env=env_of(extra), capture_output=True, timeout=90)
    return r, time.monotonic() - began


def start(args, program=None, **extra):
    reset()
    return subprocess.Popen([program or helper] + args, env=env_of(extra), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def state():
    try:
        return json.load(open(state_file))
    except (OSError, ValueError):
        return {}


def wait_for(test, seconds=15):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if test():
            return True
        time.sleep(0.05)
    return False


def files(folder):
    return sorted(os.listdir(folder)) if os.path.isdir(folder) else []


def stop(**extra):
    return subprocess.run([helper, "stop"], env=env_of(extra), capture_output=True, timeout=60)


# ---- usage: the toolbar's argv only; anything else runs nothing ----
for bad in (["record"], ["record", "window"], ["screen", "--timer", "3"], ["screen", "--save", "nowhere"], ["selection", "--mic"],
            ["selection", "--output", "DP-1"], ["record", "selection", "--output", "DP-1"], ["record", "screen", "--output", "a b"],
            ["screen", "--pointer", "--pointer"], ["screen", "--timer"], ["stop", "now"], ["window", "extra"],
            # --geometry: whole numbers in slurp's form, a positive size, only where an area is chosen
            ["screen", "--geometry", "0,0 10x10"], ["record", "screen", "--geometry", "0,0 10x10"],
            ["selection", "--geometry", "0,0 0x10"], ["selection", "--geometry", "0,0 10x0"], ["selection", "--geometry", "a,b cxd"],
            ["selection", "--geometry", " 0,0 10x10"], ["selection", "--geometry", "0,0 10x10 "], ["selection", "--geometry", "0.5,0 10x10"],
            ["selection", "--geometry", "0,0 10x-1"], ["selection", "--geometry", "0,0  10x10"], ["selection", "--geometry", "0,0,10,10"],
            ["window", "--geometry", "0,0 10x10", "--geometry", "0,0 10x10"], ["selection", "--geometry"]):
    r, _ = capture(bad)
    check(r.returncode == 2 and calls() == [], "usage refused, nothing run: %r" % bad)

# ---- the toolbar's own choice: --geometry (its frame, the window clicked), --output (the display clicked) ----
r, _ = capture(["selection", "--geometry", "2600,40 300x200"])
grim = calls("grim")
check(r.returncode == 0 and calls("slurp") == [] and calls("pkill") == [] and grim and grim[0]["argv"][:2] == ["-g", "2600,40 300x200"],
      "Capture Selected Portion with the toolbar's frame: that area, no crosshair [%r]" % (grim[0]["argv"] if grim else None))
r, _ = capture(["window", "--geometry", "100,50 800x600", "--pointer"])
grim = calls("grim")
check(r.returncode == 0 and calls("slurp") == [] and grim and grim[0]["argv"][:3] == ["-g", "100,50 800x600", "-c"],
      "Capture Selected Window with the window clicked: its box, no crosshair [%r]" % (grim[0]["argv"] if grim else None))
for off, why in (("2500,40 300x200", "across two displays"), ("4400,0 200x100", "past the right edge"),
                 ("-10,0 100x100", "left of every display"), ("0,2800 100x100", "below DP-1")):
    r, _ = capture(["selection", "--geometry", off])
    check(r.returncode == 2 and calls("grim") == [] and calls("slurp") == [] and [c["name"] for c in calls()] == ["hyprctl"],
          "--geometry %s (%s) is refused: nothing captured, only Hyprland's displays read" % (off, why))
r, _ = capture(["screen", "--output", "DP-1"])
grim = calls("grim")
check(r.returncode == 0 and [g["argv"][:2] for g in grim] == [["-o", "DP-1"]],
      "a click on a display in Capture Entire Screen: that display only [%r]" % [g["argv"] for g in grim])
r, _ = capture(["screen", "--output", "VGA-9"])
check(r.returncode == 1 and calls("grim") == [], "a display that is not there: nothing")

# ---- the window mode: the crosshair restricted to the windows ----
r, _ = capture(["window"], FAKE_SLURP="click:150,70")
slurp, grim = calls("slurp"), calls("grim")
check(slurp and slurp[0]["argv"] == slurp_argv + ["-r"] and slurp[0]["stdin"] == "100,50 800x600\n2700,100 600x400\n",
      "Capture Selected Window: slurp -r with the windows only, never the displays [%r]" % (slurp[0] if slurp else None))
check(grim and grim[0]["argv"][:2] == ["-g", "100,50 800x600"] and "-c" not in grim[0]["argv"],
      "a click on a window captures that window, without the pointer [%r]" % (grim[0]["argv"] if grim else None))
r, _ = capture(["window"], FAKE_SLURP="click:2000,900")
check(r.returncode == 0 and calls("grim") == [], "a click outside every window captures nothing")
r, _ = capture(["window"], FAKE_SLURP="")
check(r.returncode == 0 and calls("grim") == [] and calls("notify-send") == [], "Esc in the window mode: nothing")

# ---- the pointer ----
r, _ = capture(["selection", "--pointer"], FAKE_SLURP="10,20 300x200")
grim = calls("grim")
check(grim and grim[0]["argv"][:3] == ["-g", "10,20 300x200", "-c"], "Show Mouse Pointer: grim -c [%r]" % (grim[0]["argv"] if grim else None))
r, _ = capture(["screen", "--pointer"])
grim = calls("grim")
check(len(grim) == 2 and all(g["argv"][2] == "-c" for g in grim), "the screen with the pointer, every display")

# ---- save to ----
name = re.compile(r"Screenshot [0-9]{4}-[0-9]{2}-[0-9]{2} at [0-9]{2}\.[0-9]{2}\.[0-9]{2}( \([0-9]+\))?\.png")
count = len(files(desktop))
r, _ = capture(["selection", "--save", "documents"], FAKE_SLURP="10,20 300x200")
note = calls("notify-send")
check(r.returncode == 0 and len(files(documents)) == 1 and name.fullmatch(files(documents)[0]) and len(files(desktop)) == count
      and calls("wl-copy") and note and note[0]["argv"][-2:] == ["Screenshot", "Saved to Documents and copied."]
      and "default=Open in Preview" in note[0]["argv"],
      "Save to Documents: xdg-user-dir's Documents, copied, the notice says so [%r]" % files(documents))
r, _ = capture(["selection", "--save", "documents"], FAKE_SLURP="10,20 300x200", FAKE_DOCUMENTS=home)
check(len(files(os.path.join(home, "Documents"))) == 1 and not any(f.endswith(".png") for f in os.listdir(home)),
      "xdg-user-dir answering the home folder for Documents: ~/Documents, never the home folder")
before = (files(desktop), files(documents))
r, _ = capture(["screen", "--save", "clipboard"])
grim, copied = calls("grim"), calls("wl-copy")
check(r.returncode == 0 and len(grim) == 1 and grim[0]["argv"] == ["-o", "HDMI-A-1", "-"] and copied
      and copied[0]["argv"] == ["--type", "image/png"] and copied[0]["stdin"].startswith("�PNG fake -o HDMI-A-1")
      and calls("notify-send") == [] and (files(desktop), files(documents)) == before,
      "Save to Clipboard: the focused display's picture copied as PNG, no file, no notice (macOS) [%r]"
      % (grim[0]["argv"] if grim else None))
# The shutter plays for a picture copied alone too (ADR-0047 B-5; pw-play is not waited for).
for _ in range(40):
    if calls("pw-play"):
        break
    time.sleep(0.05)
check(len(calls("pw-play")) == 1 and calls("pw-play")[0]["argv"][-1] == "/usr/share/sounds/grassfield/stereo/screen-capture.wav",
      "Save to Clipboard: the shutter plays once")
before, on_desktop = set(files(screenshots)), files(desktop)
r, _ = capture(["selection", "--save", "preview"], FAKE_SLURP="10,20 300x200")
run = calls("systemd-run")
shown = [f for f in files(screenshots) if name.fullmatch(f) and f not in before]
check(r.returncode == 0 and len(shown) == 1 and run and run[0]["argv"][-1] == os.path.join(screenshots, shown[0])
      and files(desktop) == on_desktop
      and "org.grassfield.Preview.desktop" in run[0]["argv"] and calls("notify-send") == [] and calls("wl-copy") == [],
      "Save to Preview: the picture opens in Preview at once (kept in the Screenshots folder: Preview cannot save), no notice [%r]"
      % (run[0]["argv"] if run else None))
# Save to the Screenshots folder (the toolbar's default): in the Pictures folder, the notice names it.
pictures = os.path.join(home, "Pics")
r, _ = capture(["selection", "--save", "screenshots"], FAKE_SLURP="10,20 300x200", FAKE_PICTURES=pictures)
note = calls("notify-send")
check(r.returncode == 0 and len(files(os.path.join(pictures, "Screenshots"))) == 1 and files(desktop) == on_desktop and note
      and note[0]["argv"][-2:] == ["Screenshot", "Saved to Screenshots and copied."],
      "Save to Screenshots: a Screenshots folder in xdg-user-dir's Pictures, copied, the notice names it [%r]"
      % (note[0]["argv"][-2:] if note else None))

# ---- the timer: a countdown the shell shows, then the picture ----
r_proc = start(["screen", "--timer", "5"])
seen = wait_for(lambda: state().get("phase") == "countdown")
s = state()
began = time.time() * 1000
check(seen and s.get("kind") == "shot" and abs(s.get("until", 0) - began - 5000) < 1500 and s.get("output") == "HDMI-A-1"
      and s.get("rect") == {"x": 2560, "y": 0, "w": 1920, "h": 1080} and s.get("pid") == r_proc.pid and s.get("v") == 1,
      "the timer: the state says countdown, until when, over the focused display [%r]" % s)
check(oct(os.stat(state_file).st_mode & 0o777) == "0o600" and oct(os.stat(os.path.dirname(state_file)).st_mode & 0o777) == "0o700",
      "the state is private (0600 in the 0700 runtime folder)")
r_proc.wait(timeout=30)
grim = calls("grim")
check(r_proc.returncode == 0 and grim and grim[0]["t"] - calls()[0]["t"] >= 5.4 and state().get("phase") == "idle",
      "the picture is taken once the countdown is over and the plate gone, and the state goes idle")
r_proc = start(["selection", "--timer", "10"], FAKE_SLURP="10,20 300x200")
wait_for(lambda: state().get("phase") == "countdown")
check(state().get("rect") == {"x": 10, "y": 20, "w": 300, "h": 200}, "the countdown of a selection is over the selection")
stopped = stop()
r_proc.wait(timeout=30)
check(stopped.returncode == 0 and r_proc.returncode == 0 and calls("grim") == [] and state().get("phase") == "idle",
      "stop during the countdown: no picture, the state idle [%r %r]" % (stopped.returncode, r_proc.returncode))

# ---- recording ----
rec_name = re.compile(r"Screen Recording [0-9]{4}-[0-9]{2}-[0-9]{2} at [0-9]{2}\.[0-9]{2}\.[0-9]{2}( \([0-9]+\))?\.mp4")


def recording(args, **extra):
    proc = start(["record"] + args, **extra)
    # The recorder has started (the state is written as it is spawned) and has opened its file.
    ok = wait_for(lambda: state().get("phase") == "recording") and wait_for(lambda: calls("gpu-screen-recorder"))
    return proc, ok


def recorder_argv():
    rec = calls("gpu-screen-recorder")
    return rec[0]["argv"] if rec else []


for f in files(desktop):
    os.unlink(os.path.join(desktop, f))
proc, ok = recording(["screen", "--output", "HDMI-A-1"], FAKE_ANSWER="open")
argv = recorder_argv()
hidden = argv[-1] if argv else ""
s = state()
rec = calls("gpu-screen-recorder")
check(ok and argv[:-1] == ["-w", "HDMI-A-1", "-s", "0x0", "-k", "auto", "-f", "60", "-fm", "cfr", "-fallback-cpu-encoding",
                           "yes", "-cursor", "no", "-o"]
      and os.path.dirname(hidden) == desktop and os.path.basename(hidden).startswith(".grassfield-recording-")
      and hidden.endswith(".mp4"),
      "Record Entire Screen: Omarchy's backend arguments, that display at its own size, into a hidden file on the Desktop [%r]" % argv)
check(s.get("kind") == "recording" and s.get("pid") == proc.pid and rec and s.get("recorder") == rec[0]["pid"]
      and rec[0]["ppid"] == proc.pid and isinstance(s.get("started"), int) and abs(s["started"] - time.time() * 1000) < 5000
      and s.get("output") == "HDMI-A-1",
      "the state names the recorder (this helper's child), its start time and when the recording began [%r]" % s)
check([f for f in files(desktop) if not f.startswith(".")] == [] and os.path.exists(hidden),
      "the Desktop shows no movie being written (only the hidden file grows)")
second = subprocess.run([helper, "record", "screen"], env=env_of({}), capture_output=True, timeout=30)
check(second.returncode == 1 and len(calls("gpu-screen-recorder")) == 1, "a second recording is refused while one runs")
stopped = stop()
proc.wait(timeout=30)
saved = files(desktop)
note = calls("notify-send")
sig = [c for c in calls("gpu-screen-recorder") if c.get("signal")]
check(stopped.returncode == 0 and sig and sig[0]["signal"] == "SIGINT" and len(saved) == 1 and rec_name.fullmatch(saved[0])
      and open(os.path.join(desktop, saved[0]), "rb").read() == b"MP4 fake end" and not os.path.exists(hidden),
      "stop: SIGINT to the recorder, the movie takes its name, no hidden file left [%r]" % saved)
check(note and note[0]["argv"][-2:] == ["Screen Recording", "Saved to the Desktop."] and "default=Open" in note[0]["argv"]
      and not any(a.startswith("string:image-path:") for a in note[0]["argv"]) and state().get("phase") == "idle",
      "the notice: Screen Recording, saved to the Desktop, Open (no picture of a movie) [%r]" % (note[0]["argv"] if note else None))
run = calls("systemd-run")
check(run and run[0]["argv"][-2:] == ["org.grassfield.Preview.desktop", os.path.join(desktop, saved[0])] if saved else False,
      "its Open plays the movie in Preview")

proc, ok = recording(["screen", "--output", "DP-1", "--mic", "--pointer", "--save", "documents"])
argv = recorder_argv()
check(ok and argv[:4] == ["-w", "DP-1", "-s", "3840x2160"] and argv[argv.index("-cursor") + 1] == "yes"
      and argv[-4:] == ["-a", "default_input", "-ac", "aac"] and os.path.dirname(argv[argv.index("-o") + 1]) == documents,
      "a display above 4K at 4K (Omarchy), the pointer, the microphone only (no desktop sound), into Documents [%r]" % argv)
stop()
proc.wait(timeout=30)
note = calls("notify-send")
check(any(rec_name.fullmatch(f) for f in files(documents)) and note and note[0]["argv"][-1] == "Saved to Documents.",
      "saved to Documents, and the notice says so")

proc, ok = recording(["selection"], FAKE_SLURP="10,20 300x200")
argv = recorder_argv()
check(ok and argv[:2] == ["-w", "300x200+10+20"] and "-s" not in argv and state().get("rect") == {"x": 10, "y": 20, "w": 300, "h": 200},
      "Record Selected Portion: the area as WxH+X+Y in logical coordinates, no size [%r]" % argv)
stop()
proc.wait(timeout=30)
proc, ok = recording(["selection"], FAKE_SLURP="click:3000,900")
argv = recorder_argv()
check(ok and argv[:4] == ["-w", "HDMI-A-1", "-s", "0x0"], "a click on a display records that display by name [%r]" % argv)
stop()
proc.wait(timeout=30)
r, _ = capture(["record", "selection"], FAKE_SLURP="")
check(r.returncode == 0 and calls("gpu-screen-recorder") == [] and state().get("phase") == "idle", "Esc: no recording")

for f in files(desktop):
    os.unlink(os.path.join(desktop, f))
proc, ok = recording(["screen", "--save", "preview"])
stop()
proc.wait(timeout=30)
run = calls("systemd-run")
movies = [f for f in files(videos) if rec_name.fullmatch(f)]
check(ok and len(movies) == 1 and files(desktop) == [] and run and run[0]["argv"][-1] == os.path.join(videos, movies[0])
      and calls("notify-send") == [], "Save to Preview: the movie, kept in the Videos folder, opens in Preview at once, no notice")
proc, ok = recording(["screen", "--save", "clipboard"])
argv = recorder_argv()
stop()
proc.wait(timeout=30)
check(ok and os.path.dirname(argv[argv.index("-o") + 1]) == videos and calls("wl-copy") == [],
      "a recording asked for the clipboard goes to the Videos folder (a movie is not copied)")
# Save to the default place (the toolbar's `screenshots`): a recording goes to xdg-user-dir's Videos, and the notice names it.
films = os.path.join(home, "Films")
proc, ok = recording(["screen", "--save", "screenshots"], FAKE_VIDEOS=films, FAKE_ANSWER="")
argv = recorder_argv()
stop()
proc.wait(timeout=30)
note = calls("notify-send")
check(ok and os.path.dirname(argv[argv.index("-o") + 1]) == films and len([f for f in files(films) if rec_name.fullmatch(f)]) == 1
      and files(desktop) == [] and note and note[0]["argv"][-2:] == ["Screen Recording", "Saved to Films."],
      "a recording saved to the default place: xdg-user-dir's Videos folder, the notice names it [%r]"
      % (note[0]["argv"][-2:] if note else None))

# The session ending (SIGTERM to the helper) while it records: the recorder is told to save, the file is named.
count = len(files(desktop))
proc, ok = recording(["screen"])
proc.terminate()
proc.wait(timeout=30)
sig = [c for c in calls("gpu-screen-recorder") if c.get("signal")]
check(ok and sig and sig[0]["signal"] == "SIGINT" and len(files(desktop)) == count + 1 and state().get("phase") == "idle",
      "SIGTERM while recording: the recorder gets SIGINT and the movie is saved")
# A recorder that ignores SIGINT is killed after the wait (the quick helper's 1 s); the state goes idle.
proc = start(["record", "screen"], FAKE_RECORDER="ignore")
wait_for(lambda: state().get("phase") == "recording") and wait_for(lambda: calls("gpu-screen-recorder"))
stopped = subprocess.run([quick, "stop"], env=env_of({}), capture_output=True, timeout=60)
proc.wait(timeout=30)
check(stopped.returncode == 0 and proc.returncode == 0 and state().get("phase") == "idle"
      and not any(f.startswith(".") for f in os.listdir(desktop)),
      "a recorder that does not end on SIGINT is killed after the wait; no hidden file left")
# A recorder that fails or writes nothing: no file, a notice that says so.
count = len(files(desktop))
r, _ = capture(["record", "screen"], FAKE_RECORDER="fail")
note = calls("notify-send")
check(r.returncode == 1 and len(files(desktop)) == count and not any(f.startswith(".") for f in os.listdir(desktop)) and note
      and note[0]["argv"][-1] == "The screen recording could not be saved." and "-A" not in note[0]["argv"]
      and state().get("phase") == "idle", "a recorder that fails: no file, the notice says so, no button")
# Without gpu-screen-recorder (an Omarchy base package): nothing runs, exit 3 (the toolbar hides its Record buttons then).
r, _ = capture(["record", "selection"], PATH=norec, FAKE_SLURP="10,20 300x200")
check(r.returncode == 3 and calls() == [], "without gpu-screen-recorder: exit 3, nothing run")
# The session ending during the countdown: no recording.
proc = start(["record", "screen", "--timer", "10"])
wait_for(lambda: state().get("phase") == "countdown")
proc.terminate()
proc.wait(timeout=30)
check(proc.returncode == 0 and calls("gpu-screen-recorder") == [] and state().get("phase") == "idle",
      "SIGTERM during a recording's countdown: nothing recorded, the state idle")
# A countdown before the recording: the recorder starts after it.
proc = start(["record", "screen", "--timer", "5"])
wait_for(lambda: state().get("phase") == "countdown")
early = calls("gpu-screen-recorder") == []
wait_for(lambda: state().get("phase") == "recording", 20) and wait_for(lambda: calls("gpu-screen-recorder"))
rec = calls("gpu-screen-recorder")
stop()
proc.wait(timeout=30)
check(early and rec and rec[0]["t"] - calls()[0]["t"] >= 5.4, "the recording starts once the countdown and its plate are gone")

# ---- stop: never a process named like a recorder; never a left-over state ----
r = stop()
check(r.returncode == 1, "stop with nothing running: exit 1")
with open(state_file, "w") as f:
    json.dump({"v": 1, "phase": "recording", "pid": 999999, "start": 1, "recorder": 999998, "recorderStart": 1}, f)
r = stop()
check(r.returncode == 1 and state().get("phase") == "idle", "a state nobody holds the lock for is left over: idle, nothing signalled")


def ticks(pid):
    return int(open("/proc/%d/stat" % pid, "rb").read().rpartition(b")")[2].split()[19])


# A process named gpu-screen-recorder that is not the recording helper's child: stop leaves it alone, whatever the state says.
lock = os.open(os.path.join(runtime, "grassfield", "capture-lock"), os.O_RDWR)
fcntl.flock(lock, fcntl.LOCK_EX)
outsider = subprocess.Popen(["bash", "-c", "exec -a gpu-screen-recorder sleep 30"])
time.sleep(0.2)
grand = subprocess.Popen(["sh", "-c", "sleep 30 & wait"])
time.sleep(0.2)
grandchild = int(subprocess.run(["pgrep", "-P", str(grand.pid)], capture_output=True, text=True).stdout.split()[0])
me = os.getpid()
cases = [
    ("the recorder's start time differs", {"recorder": outsider.pid, "recorderStart": ticks(outsider.pid) + 1}),
    ("the recorder is not the helper's child", {"recorder": grandchild, "recorderStart": ticks(grandchild)}),
    ("the helper's start time differs", {"recorder": outsider.pid, "recorderStart": ticks(outsider.pid), "start": ticks(me) + 1}),
]
for desc, fields in cases:
    with open(state_file, "w") as f:
        json.dump(dict({"v": 1, "phase": "recording", "pid": me, "start": ticks(me)}, **fields), f)
    r = stop()
    check(r.returncode == 1 and outsider.poll() is None and grand.poll() is None and os.path.exists("/proc/%d" % grandchild),
          "stop refuses when %s: nothing signalled" % desc)
# The same state with the right identity: the outsider is this test's child, as the recorder is the helper's.
with open(state_file, "w") as f:
    json.dump({"v": 1, "phase": "recording", "pid": me, "start": ticks(me), "recorder": outsider.pid,
               "recorderStart": ticks(outsider.pid)}, f)
r = stop()
outsider.wait(timeout=10)
check(r.returncode == 0 and outsider.returncode == -signal.SIGINT, "the recorder recognised by pid, start time and parent gets SIGINT")
for p in (grand,):
    p.kill()
    p.wait()
os.kill(grandchild, signal.SIGKILL)
fcntl.flock(lock, fcntl.LOCK_UN)
os.close(lock)
with open(state_file, "w") as f:
    json.dump({"v": 1, "phase": "idle"}, f)

# ---- recording the toolbar's frame ----
proc, ok = recording(["selection", "--geometry", "2600,40 300x200"])
argv = recorder_argv()
check(ok and argv[:2] == ["-w", "300x200+2600+40"] and "-s" not in argv and calls("slurp") == [],
      "Record Selected Portion with the toolbar's frame: that area as WxH+X+Y, no crosshair [%r]" % argv)
stop()
proc.wait(timeout=30)
proc, ok = recording(["selection", "--geometry", "2560,0 1920x1080"])
argv = recorder_argv()
check(ok and argv[:4] == ["-w", "HDMI-A-1", "-s", "0x0"], "a frame that is a whole display records that display [%r]" % argv)
stop()
proc.wait(timeout=30)
r, _ = capture(["record", "selection", "--geometry", "2500,40 300x200"])
check(r.returncode == 2 and calls("gpu-screen-recorder") == [] and state().get("phase") == "idle",
      "a frame across two displays is refused: nothing recorded, the state idle")

# ---- the session lock: nothing is captured or recorded behind it, whoever asked ----
marker = os.path.join(runtime, "grassfield-lock-default")
LOCKED_MONITORS = json.dumps([dict(m, solitaryBlockedBy=["LOCK"]) for m in json.loads(MONITORS)])


def mark(text):
    with open(marker, "w") as f:
        f.write(text)


mark("locked sleeps=3\n")
r, _ = capture(["record", "screen"])
check(r.returncode == 1 and calls("gpu-screen-recorder") == [] and state().get("phase") == "idle",
      "the shell's marker says locked: the recording is refused before the recorder starts")
r, _ = capture(["selection", "--geometry", "2600,40 300x200"])
check(r.returncode == 1 and calls("grim") == [] and calls("notify-send") == [], "the marker says locked: no picture")
r, _ = capture(["screen"])
check(r.returncode == 1 and calls("grim") == [], "the marker says locked: no picture of the screen either")
mark("unlocked sleeps=3\n")
r, _ = capture(["record", "screen"], FAKE_MONITORS=LOCKED_MONITORS)
check(r.returncode == 1 and calls("gpu-screen-recorder") == [], "Hyprland reports the lock (LOCK on the displays): no recording")
r, _ = capture(["selection", "--geometry", "2600,40 300x200"], FAKE_MONITORS=LOCKED_MONITORS)
check(r.returncode == 1 and calls("grim") == [], "Hyprland reports the lock: no picture")
# The session locks while a recording runs (no shell to stop it): the helper reads the marker and ends the recording itself.
count = len(files(desktop))
proc, ok = recording(["screen"])
mark("locked\n")
proc.wait(timeout=30)
sig = [c for c in calls("gpu-screen-recorder") if c.get("signal")]
check(ok and sig and sig[0]["signal"] == "SIGINT" and len(files(desktop)) == count + 1 and state().get("phase") == "idle",
      "the session locks during a recording: the helper ends it (SIGINT) within its poll and saves the movie")
mark("unlocked\n")
# The session locks during a recording's countdown: the recorder never starts.
proc = start(["record", "screen", "--timer", "5"])
wait_for(lambda: state().get("phase") == "countdown")
mark("locked\n")
proc.wait(timeout=30)
check(proc.returncode == 1 and calls("gpu-screen-recorder") == [] and state().get("phase") == "idle",
      "the session locks during the countdown: nothing recorded, the state idle")
# A recording writes its state at once ("starting"), before anything slow, so the shell sees it coming.
mark("unlocked\n")
proc = start(["record", "selection"], FAKE_SLURP="", FAKE_SLOW_HYPRCTL="1")
seen = wait_for(lambda: state().get("phase") in ("starting", "selecting"), 5)
first = state().get("phase")
proc.wait(timeout=30)
check(seen and first == "starting", "a recording's state says starting before it reads Hyprland's displays [%r]" % first)
# A stop that arrives while the helper is still reading Hyprland's displays (counter-review of ADR-0045, LOW-1): the helper
# ends and the state goes back to idle, never left "starting" with a dead pid (which kept Record disabled).
proc = start(["record", "screen"], FAKE_SLOW_HYPRCTL="1")
seen = wait_for(lambda: state().get("phase") == "starting", 5)
stopped = stop()
proc.wait(timeout=30)
check(seen and proc.returncode == 0 and state().get("phase") == "idle" and calls("gpu-screen-recorder") == [],
      "a stop during the first steps leaves the state idle and records nothing [%r, rc %r, stop %r]"
      % (state().get("phase"), proc.returncode, getattr(stopped, "returncode", stopped)))
os.unlink(marker)

# ---- French ----
for f in files(desktop):
    os.unlink(os.path.join(desktop, f))
proc, ok = recording(["screen"], LANG="fr_FR.UTF-8")
stop()
proc.wait(timeout=30)
note = calls("notify-send")
check(len(files(desktop)) == 1 and re.fullmatch(r"Enregistrement de l’écran [0-9]{4}-[0-9]{2}-[0-9]{2} à [0-9]{2}\.[0-9]{2}\.[0-9]{2}\.mp4",
                                                 files(desktop)[0])
      and note and note[0]["argv"][-2:] == ["Enregistrement de l’écran", "Enregistré sur le Bureau."] and "default=Ouvrir" in note[0]["argv"],
      "in French: « Enregistrement de l’écran … à … », the notice in French [%r]" % files(desktop))
r, _ = capture(["selection", "--save", "documents"], FAKE_SLURP="10,20 300x200", LANG="fr_FR.UTF-8")
note = calls("notify-send")
check(note and note[0]["argv"][-1] == "Enregistrée dans Documents et copiée.", "Save to Documents in French")

sys.exit(1 if failed else 0)
