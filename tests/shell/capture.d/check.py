# packaging/bin/grassfield-capture against fakes (run by tests/shell/capture.sh as `python3 -I check.py <root> <tmp>`).
# The fakes answer as the real tools do (reviews of step 8): slurp 1.5.0 (Arch's) gives the smallest fed box for a click
# inside one and cancels a click outside every box; notify-send prints the notice's id then the action, ends its output before
# it ends and, sent SIGINT while it waits, closes its notice and ends; it shows as `notify-send` in /proc, as the real one.
import datetime
import json
import os
import re
import shutil
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


fake, quiet, home, log = (os.path.join(tmp, d) for d in ("fake", "fake-no-notify", "home", "log"))
for d in (fake, quiet, home, log):
    os.makedirs(d)
helper = os.path.join(root, "packaging/bin/grassfield-capture")
source = open(helper).read()
# The same helper, waiting 2 s instead of WAIT_SECONDS for a click on its notice.
short = os.path.join(tmp, "grassfield-capture-short")
write(short, re.sub(r"^WAIT_SECONDS = [0-9]+$", "WAIT_SECONDS = 2", source, flags=re.M))
# The same helper, leaving 3 s instead of BANNER_GONE_SECONDS for the last notice to go: what waits for it, and what does
# not, shows above any delay of a busy machine.
slow = os.path.join(tmp, "grassfield-capture-slow")
write(slow, re.sub(r"^BANNER_GONE_SECONDS = [0-9.]+$", "BANNER_GONE_SECONDS = 3", source, flags=re.M))

# The colours are the tokens' (capture.*), as slurp takes them.
tokens = json.load(open(os.path.join(root, "ui/tokens/tokens.json")))["capture"]
m = re.search(r"^COLOURS = (\{.*\})$", source, re.M)
colours = json.loads(m.group(1)) if m else {}
check(colours == {k: tokens[k]["value"] for k in ("veil", "selection", "border")}
      and re.search(r"^BORDER_WIDTH = %d$" % tokens["borderWidth"]["value"], source, re.M) is not None,
      "the crosshair's colours and width are ui/tokens/tokens.json's capture.* [%r]" % colours)
slurp_argv = ["-b", colours["veil"], "-s", colours["selection"], "-c", colours["border"], "-B", colours["veil"],
              "-w", str(tokens["borderWidth"]["value"])]

# Fakes: each records its argv (and stdin) as one JSON line; behaviour from FAKE_* variables. notify-send runs under its
# own name (exec -a), so the helper finds it in /proc as it finds the real one.
os.makedirs(os.path.join(fake, "impl"))
write(os.path.join(fake, "notify-send"), '#!/bin/bash\nexec -a notify-send /usr/bin/python3 -I "$(dirname "$0")/impl/notify-send" "$@"\n')
for name in ("grim", "slurp", "wl-copy", "notify-send", "hyprctl", "xdg-user-dir", "pkill", "systemd-run", "uwsm-app", "gdbus",
             "pw-play"):
    write(os.path.join(fake, "impl" if name == "notify-send" else "", name), r'''#!/usr/bin/python3 -I
import json, os, re, signal, sys, time
name = os.path.basename(sys.argv[0])
data = sys.stdin.buffer.read().decode("utf-8", "replace") if name in ("slurp", "wl-copy") else ""
def record(**extra):
    with open(os.path.join(os.environ["FAKE_LOG"], "calls"), "a") as f:
        f.write(json.dumps(dict({"name": name, "argv": sys.argv[1:], "stdin": data[:200], "t": time.monotonic()}, **extra)) + "\n")
record()
env = os.environ
if name == "grim":
    if env.get("FAKE_GRIM") == "fail":
        sys.exit(1)
    open(sys.argv[-1], "wb").write(b"\x89PNG fake " + sys.argv[-2].encode())
elif name == "slurp":
    answer = env.get("FAKE_SLURP", "")
    if answer == "":
        sys.exit(1)  # Esc
    click = re.fullmatch(r"click:(-?\d+),(-?\d+)", answer)
    if click:
        # As slurp 1.5.0: the smallest fed box under the point; outside every box, a click selects nothing and slurp
        # prints "selection cancelled" and exits 1 (main.c handle_selection_end).
        px, py = int(click[1]), int(click[2])
        boxes = []
        for line in data.splitlines():
            b = re.fullmatch(r"(-?\d+),(-?\d+) (\d+)x(\d+)", line)
            if b:
                x, y, w, h = map(int, b.groups())
                if x <= px < x + w and y <= py < y + h:
                    boxes.append((w * h, len(boxes), line))
        if not boxes:
            print("selection cancelled", file=sys.stderr)
            sys.exit(1)
        answer = min(boxes, key=lambda b: (b[0], -b[1]))[2]  # of equal boxes, the last (main.c seat_update_selection)
    print(answer)
elif name == "hyprctl":
    if sys.argv[2] == "cursorpos":
        if "FAKE_CURSOR" not in env:
            sys.exit(1)
        print(env["FAKE_CURSOR"])
    else:
        print(env.get("FAKE_MONITORS" if sys.argv[2] == "monitors" else "FAKE_CLIENTS", "[]"))
elif name == "xdg-user-dir":
    # FAKE_DESKTOP answers DESKTOP, FAKE_PICTURES PICTURES, and so on; no variable, no answer.
    if "FAKE_" + sys.argv[1] in env:
        print(env["FAKE_" + sys.argv[1]])
    else:
        sys.exit(1)
elif name == "pkill":
    sys.exit(0 if env.get("FAKE_SELECTING") == "1" else 1)
elif name == "notify-send":
    def closed(sig, frame):
        record(signal="INT")
        sys.exit(0)
    signal.signal(signal.SIGINT, closed)
    print(17, flush=True)
    answer = env.get("FAKE_ANSWER", "")
    if answer == "hang":
        time.sleep(60)
    elif answer:
        print(answer, flush=True)
    # As notify-send, whose output ends before it has ended (it still closes its connection to the bus): the helper must wait
    # for the process, not take the end of the output for its wait running out (review of step 8, MAJOR 1).
    os.close(1)
    time.sleep(0.2)
''')
for name in os.listdir(fake):
    if name not in ("notify-send", "impl"):
        os.symlink(os.path.join(fake, name), os.path.join(quiet, name))

MONITORS = json.dumps([
    {"name": "DP-1", "x": 0, "y": 0, "width": 3840, "height": 2160, "scale": 2.0, "transform": 0, "focused": False,
     "activeWorkspace": {"id": 1}, "specialWorkspace": {"id": 0}},
    {"name": "HDMI-A-1", "x": 1920, "y": 0, "width": 1080, "height": 1920, "scale": 1.0, "transform": 1, "focused": True,
     "activeWorkspace": {"id": 2}, "specialWorkspace": {"id": 0}},
    {"name": "DP-2", "x": 0, "y": 0, "width": 1920, "height": 1080, "scale": 1.0, "transform": 0, "disabled": True,
     "activeWorkspace": {"id": 3}, "specialWorkspace": {"id": 0}}])
def client(ws, at, size, fullscreen=0, focus=0, pinned=False, over=True, hidden=False):
    # A window as `hyprctl -j clients` lists it (Hyprland 0.56.2 HyprCtl.cpp): every field the helper reads. The list goes
    # from the bottom of the stack up; Grassfield floats every window; allowedOverFullscreen is Hyprland's default true,
    # cleared for the other windows of a workspace when one goes fullscreen (FullscreenHandler.cpp).
    return {"mapped": True, "hidden": hidden, "visible": not hidden, "workspace": {"id": ws}, "at": at, "size": size,
            "floating": True, "pinned": pinned, "fullscreen": fullscreen, "allowedOverFullscreen": over, "focusHistoryID": focus}


CLIENTS = json.dumps([
    client(1, [100, 50], [800, 600], focus=1),
    client(1, [0, 0], [500, 500], focus=2, hidden=True),
    client(9, [0, 0], [400, 400], focus=3),
    client(2, [2000, 100], [600, 400], focus=0)])
# Workspace 1: a zoomed (maximized) window, a window behind it. Workspace 2, from the bottom up: a window behind a fullscreen
# one, the fullscreen one (focused), a window opened over it, and a pinned one (first in the list, drawn above all).
FULL = json.dumps([
    client(2, [2500, 500], [300, 200], focus=4, pinned=True),
    client(1, [100, 50], [800, 600], focus=5, over=False),
    client(1, [0, 0], [1920, 1080], fullscreen=1, focus=1),
    client(2, [2000, 100], [600, 400], focus=3, over=False),
    client(2, [1920, 0], [1920, 1080], fullscreen=2, focus=0),
    client(2, [3000, 700], [400, 300], focus=2)])
# Workspace 1, from the bottom up: a small window (the focused one) behind a larger one opened over it without the focus.
STACK = json.dumps([
    client(1, [100, 100], [200, 200], focus=0),
    client(1, [0, 0], [1000, 800], focus=-1)])
# A fullscreen window on DP-1 (workspace 1) and a window of HDMI-A-1's workspace 2 that reaches over DP-1 (drawn under it).
CROSS = json.dumps([
    client(2, [1700, 200], [800, 600], focus=0),
    client(1, [0, 0], [1920, 1080], fullscreen=2, focus=1)])
# DP-1 shows the special workspace -98 over workspace 1: its window is drawn above workspace 1's, wherever they are listed.
SPECIAL_MONITORS = json.dumps([dict(m, specialWorkspace={"id": -98}) if m["name"] == "DP-1" else m for m in json.loads(MONITORS)])
SPECIAL = json.dumps([
    client(-98, [100, 100], [400, 300], focus=0),
    client(1, [50, 50], [600, 500], focus=1)])
# A Picture-in-Picture window pinned over the browser that has the focus (the pinned one first in the list).
PIP = json.dumps([
    client(1, [600, 400], [320, 180], focus=1, pinned=True),
    client(1, [0, 0], [1600, 900], focus=0)])


def calls(name=None):
    try:
        lines = [json.loads(l) for l in open(os.path.join(log, "calls"))]
    except FileNotFoundError:
        return []
    return [c for c in lines if name is None or c["name"] == name]


def capture(mode, program=None, path=None, **extra):
    if os.path.exists(os.path.join(log, "calls")):
        os.unlink(os.path.join(log, "calls"))
    # A path given is the whole PATH (hermetic: the system's own tools, notify-send first, are never reached through it).
    env = {"PATH": path or fake + ":/usr/bin:/bin", "HOME": home, "FAKE_LOG": log, "FAKE_MONITORS": MONITORS,
           "FAKE_CLIENTS": CLIENTS, "FAKE_ANSWER": "default"}
    env.update(extra)
    began = time.monotonic()
    r = subprocess.run([program or helper] + ([mode] if mode is not None else []), env=env, capture_output=True, timeout=60)
    return r, time.monotonic() - began


def files(folder):
    return sorted(os.listdir(folder)) if os.path.isdir(folder) else []


desktop = os.path.join(home, "Desktop")
# Save to: the Desktop, chosen in the toolbar (capture.location in ~/.config/grassfield/grassfield.json, which the keys follow),
# so that the checks below find the pictures where they look; the default place, the Screenshots folder, is checked at the end.
config = os.path.join(home, ".config", "grassfield")
os.makedirs(config, exist_ok=True)


def set_config(doc):
    with open(os.path.join(config, "grassfield.json"), "w") as f:
        json.dump(doc, f)


ON_DESKTOP = {"capture": {"location": "desktop"}}
set_config(dict({"version": 1}, **ON_DESKTOP))
name = re.compile(r"Screenshot [0-9]{4}-[0-9]{2}-[0-9]{2} at [0-9]{2}\.[0-9]{2}\.[0-9]{2}( \([0-9]+\))?\.png")

# The screen: every enabled display, the focused one first, one picture each, saved to ~/Desktop (no xdg-user-dir answer).
r, _ = capture("screen")
grim = calls("grim")
saved = files(desktop)
base = [f for f in saved if " (" not in f]
check(r.returncode == 0 and [g["argv"][:2] for g in grim] == [["-o", "HDMI-A-1"], ["-o", "DP-1"]] and len(saved) == 2
      and all(name.fullmatch(f) for f in saved) and len(base) == 1 and base[0][:-4] + " (2).png" in saved,
      "Shift-Cmd-3: every display, the focused one first, as macOS names them (the next one \" (2)\") [%r %r]"
      % ([g["argv"] for g in grim], saved))
first = os.path.join(desktop, base[0]) if base else ""
second = first[:-4] + " (2).png" if first else ""
check(all(os.path.dirname(g["argv"][-1]) == desktop and os.path.basename(g["argv"][-1]).startswith(".grassfield-capture-")
          for g in grim) and first and open(first, "rb").read().endswith(b"-o HDMI-A-1"[-8:]),
      "grim writes a hidden file of the helper's on the Desktop, which then takes the picture's name [%r]"
      % [g["argv"][-1] for g in grim])
check(not any(f.startswith(".") for f in os.listdir(desktop)), "no hidden file is left on the Desktop")
check(calls("slurp") == [], "the screen needs no crosshair")
copied = calls("wl-copy")
check(copied and copied[0]["argv"] == ["--type", "image/png"] and copied[0]["stdin"].startswith("�PNG")
      and copied[0]["stdin"].endswith("HDMI-A-1"), "the focused display's picture is copied to the clipboard as PNG")
note = calls("notify-send")
check(note and "string:image-path:" + first in note[0]["argv"] and "default=Open in Preview" in note[0]["argv"]
      and "open=Open in Preview" in note[0]["argv"] and note[0]["argv"][-2:] == ["Screenshot", "Saved to the Desktop and copied."]
      and "-t" not in note[0]["argv"] and note[0]["argv"][note[0]["argv"].index("-i") + 1] == "org.grassfield.Preview",
      "the notice shows the picture (Preview's icon when it cannot), an ordinary banner (no -t 0), a click or its button "
      "opens Preview [%r]" % (note[0]["argv"] if note else None))
run = calls("systemd-run")
check(run and run[0]["argv"][-5:] == [os.path.join(fake, "uwsm-app"), "--", "org.grassfield.Preview.desktop", first, second],
      "a click opens Preview with the capture's pictures, as the Dock starts an app [%r]" % (run[0]["argv"] if run else None))

# A second capture: two more pictures (whether it lands in the same second or not; the fixed-time check follows).
before = files(desktop)
r, _ = capture("screen")
check(len(files(desktop)) == len(before) + 2 and all(name.fullmatch(f) for f in files(desktop)),
      "a second capture adds its own two pictures: %r" % files(desktop))

# Never a file overwritten, nor a link followed, whatever the second (integrator review of step 8, MINOR): every name the
# capture can take in the next 30 s is already there: "<stem>.png" a picture, " (2)" a link to a file outside the home folder,
# " (3)" a dangling link into the home folder. The capture takes " (4)" and " (5)" and leaves all three untouched.
crowded = os.path.join(home, "Crowded")
os.makedirs(crowded)
outside, nowhere = os.path.join(tmp, "outside.png"), os.path.join(home, "nowhere.png")
with open(outside, "wb") as f:
    f.write(b"outside")
began = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
stems = ["Screenshot %s" % (began + datetime.timedelta(seconds=s)).strftime("%Y-%m-%d at %H.%M.%S") for s in range(-1, 30)]
for stem in stems:
    with open(os.path.join(crowded, stem + ".png"), "wb") as f:
        f.write(b"earlier " + stem.encode())
    os.symlink(outside, os.path.join(crowded, stem + " (2).png"))
    os.symlink(nowhere, os.path.join(crowded, stem + " (3).png"))
r, _ = capture("screen", FAKE_DESKTOP=crowded, TZ="UTC")
new = sorted(set(files(crowded)) - {s + e for s in stems for e in (".png", " (2).png", " (3).png")})
kept = all(open(os.path.join(crowded, s + ".png"), "rb").read() == b"earlier " + s.encode()
           and os.readlink(os.path.join(crowded, s + " (2).png")) == outside
           and os.readlink(os.path.join(crowded, s + " (3).png")) == nowhere for s in stems)
check(r.returncode == 0 and len(new) == 2 and all(f.endswith((" (4).png", " (5).png")) for f in new)
      and all(not os.path.islink(os.path.join(crowded, f)) for f in new) and kept
      and open(outside, "rb").read() == b"outside" and not os.path.lexists(nowhere),
      "every name taken (a picture, a link out, a dangling link): the capture takes the next free ones, overwrites and "
      "follows nothing [%r]" % new)

# The click on the notice is never lost (review of step 8, MAJOR 1: notify-send's output ended before it could be reaped,
# and the helper took that for its wait running out): 40 notices clicked as soon as they show.
opened = 0
for _ in range(40):
    r, _ = capture("selection", FAKE_SLURP="10,20 300x200")
    opened += len(calls("systemd-run")) == 1 and not any(c.get("signal") for c in calls("notify-send"))
check(opened == 40, "a click on the notice opens Preview every time (%d of 40)" % opened)
r, _ = capture("selection", FAKE_SLURP="10,20 300x200", FAKE_ANSWER="open")
check(len(calls("systemd-run")) == 1, "its Open in Preview button opens Preview")

# The selection: slurp in the tokens' colours (its boxes filled with the veil itself, so the veil is even), the shown
# workspaces' visible windows then the displays as boxes (slurp 1.5.0 cancels a click outside every box).
r, _ = capture("selection", FAKE_SLURP="10,20 300x200")
slurp = calls("slurp")
check(slurp and slurp[0]["argv"] == slurp_argv and slurp_argv[slurp_argv.index("-B") + 1] == colours["veil"],
      "the crosshair in Grassfield's colours, its boxes the veil's [%r]" % (slurp[0]["argv"] if slurp else None))
check(slurp and slurp[0]["stdin"] == "100,50 800x600\n2000,100 600x400\n1920,0 1920x1080\n0,0 1920x1080\n",
      "boxes: the shown workspaces' visible windows, then each display's logical rectangle (scale, rotation), the focused first [%r]"
      % (slurp[0]["stdin"] if slurp else None))
grim = calls("grim")
check(grim and grim[0]["argv"][:2] == ["-g", "10,20 300x200"], "a drag: that area [%r]" % (grim[0]["argv"] if grim else None))
r, _ = capture("selection", FAKE_SLURP="click:150,70")
grim = calls("grim")
check(grim and grim[0]["argv"][:2] == ["-g", "100,50 800x600"], "a click on a window: that window [%r]" % (grim[0]["argv"] if grim else None))
r, _ = capture("selection", FAKE_SLURP="click:1950,600")
grim = calls("grim")
check(grim and grim[0]["argv"][:2] == ["-g", "1920,0 1920x1080"], "a click outside every window: the display under it, "
      "rotated [%r]" % (grim[0]["argv"] if grim else None))
r, _ = capture("selection", FAKE_SLURP="click:5000,5000")
check(calls("grim") == [], "a click outside every display: nothing")
# A click on a window behind a larger one in front: slurp answers the smaller box; the helper takes the window drawn on top
# under the pointer, as Hyprland stacks them (pinned first, then the later in its list), never by the focus.
def clicked(fixture, point, cursor=None, answer=None):
    extra = {"FAKE_SLURP": answer or "click:%d,%d" % point, "FAKE_CLIENTS": fixture}
    if cursor is not False:
        extra["FAKE_CURSOR"] = json.dumps({"x": (cursor or point)[0], "y": (cursor or point)[1]})
    capture("selection", **extra)
    grim = calls("grim")
    return grim[0]["argv"][1] if grim else None


got = clicked(STACK, (150, 150))
check(got == "0,0 1000x800", "a click where a window in front (opened without the focus) covers a smaller focused one: the "
      "one in front [%r]" % got)
got = clicked(STACK, (150, 150), cursor=False)
check(got == "100,100 200x200", "the pointer unread: slurp's answer [%r]" % got)
got = clicked(STACK, (150, 150), cursor=(900, 700))
check(got == "100,100 200x200", "the pointer gone from slurp's box after the click: slurp's answer [%r]" % got)
got = clicked(STACK, (150, 150), answer="150,150 2x1")
check(got == "0,0 1000x800", "a click whose hand moved a pixel (slurp answers 2x1): the window on top there [%r]" % got)
got = clicked(PIP, (700, 450))
check(got == "600,400 320x180", "a click on a pinned window over the focused one (Picture in Picture): the pinned one [%r]" % got)
capture("selection", FAKE_SLURP="click:2100,200", FAKE_CLIENTS=FULL, FAKE_CURSOR='{"x": 2100, "y": 200}')
slurp, grim = calls("slurp"), calls("grim")
check(slurp and slurp[0]["stdin"].split("\n")[:4] == ["2500,500 300x200", "0,0 1920x1080", "1920,0 1920x1080", "3000,700 400x300"]
      and grim and grim[0]["argv"][1] == "1920,0 1920x1080",
      "a fullscreen or zoomed window and the windows over it are their workspace's boxes, never the windows behind [%r %r]"
      % (slurp[0]["stdin"] if slurp else None, grim[0]["argv"] if grim else None))
got = clicked(FULL, (2600, 550))
check(got == "2500,500 300x200", "a click on a pinned window over a fullscreen one: the pinned one [%r]" % got)
got = clicked(FULL, (3100, 800))
check(got == "3000,700 400x300", "a click on a window opened over a fullscreen one that has the focus: that window [%r]" % got)
got = clicked(CROSS, (1800, 300))
check(got == "0,0 1920x1080", "a click on a fullscreen window where another display's window reaches under it: the fullscreen "
      "one [%r]" % got)
# A named workspace has a negative id too (Hyprland: -1338 and below), yet is no special workspace.
NAMED_MONITORS = json.dumps([dict(m, activeWorkspace={"id": -1338}) if m["name"] == "HDMI-A-1" else m for m in json.loads(MONITORS)])
NAMED = json.dumps([
    client(-1338, [1700, 200], [800, 600], focus=0),
    client(1, [0, 0], [1920, 1080], fullscreen=2, focus=1)])
capture("selection", FAKE_SLURP="click:1800,300", FAKE_CLIENTS=NAMED, FAKE_MONITORS=NAMED_MONITORS,
        FAKE_CURSOR='{"x": 1800, "y": 300}')
grim = calls("grim")
got = grim[0]["argv"][1] if grim else None
check(got == "0,0 1920x1080", "a named workspace's window (a negative id) reaching under a fullscreen one: the fullscreen one "
      "[%r]" % got)
capture("selection", FAKE_SLURP="click:200,200", FAKE_CLIENTS=SPECIAL, FAKE_MONITORS=SPECIAL_MONITORS,
        FAKE_CURSOR='{"x": 200, "y": 200}')
grim = calls("grim")
got = grim[0]["argv"][1] if grim else None
check(got == "100,100 400x300", "a click on a special workspace's window shown over the workspace: that window [%r]" % got)
count = len(files(desktop))
r, _ = capture("selection", FAKE_SLURP="")
check(r.returncode == 0 and calls("grim") == [] and calls("notify-send") == [] and len(files(desktop)) == count,
      "Esc: nothing captured, saved or shown")
r, _ = capture("selection", FAKE_SELECTING="1", FAKE_SLURP="10,20 300x200")
pk = calls("pkill")
check(r.returncode == 0 and calls("slurp") == [] and calls("grim") == [] and pk
      and pk[0]["argv"] == ["-u", str(os.getuid()), "-f", "-x", " ".join(["slurp"] + slurp_argv)],
      "a second press while the crosshair shows cancels it, and only this helper's slurp (its exact command line) [%r]"
      % (pk[0]["argv"] if pk else None))
r, _ = capture("selection", FAKE_SLURP="garbage")
check(calls("grim") == [] and len(files(desktop)) == count, "an answer of slurp that does not read: nothing")

# The notice's wait is bounded: unanswered, notify-send is asked (SIGINT) to close its notice; nothing opens.
r, took = capture("selection", program=short, FAKE_SLURP="10,20 300x200", FAKE_ANSWER="hang")
note = calls("notify-send")
check(r.returncode == 0 and any(c.get("signal") == "INT" for c in note) and calls("systemd-run") == [] and calls("gdbus") == []
      and took < 10, "no click within the wait: notify-send closes its notice, Preview does not open (%.1f s)" % took)
# The previous capture's notice is closed before the next one (its banner in no picture): capture A waits on its notice,
# capture B asks A's notify-send to close it (SIGINT) before grim runs; A's helper then ends without opening Preview.
runtime = os.path.join(tmp, "run")
os.makedirs(runtime, mode=0o700)
for f in ("calls",):
    if os.path.exists(os.path.join(log, f)):
        os.unlink(os.path.join(log, f))
env = {"PATH": fake + ":/usr/bin:/bin", "HOME": home, "FAKE_LOG": log, "FAKE_MONITORS": MONITORS, "FAKE_CLIENTS": CLIENTS,
       "XDG_RUNTIME_DIR": runtime}
first = subprocess.Popen([helper, "screen"], env=dict(env, FAKE_ANSWER="hang"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(100):
    if calls("notify-send"):
        break
    time.sleep(0.05)
time.sleep(0.2)
began = len(calls())
second = subprocess.run([helper, "screen"], env=dict(env, FAKE_ANSWER=""), capture_output=True, timeout=60)
try:
    first.wait(timeout=10)
except subprocess.TimeoutExpired:
    first.kill()
after = calls()[began:]
order = [c["name"] + (":INT" if c.get("signal") else "") for c in after]
check(second.returncode == 0 and first.returncode == 0 and "notify-send:INT" in order and "grim" in order
      and order.index("notify-send:INT") < order.index("grim") and calls("systemd-run") == [],
      "the last capture's notice is closed before the next capture (SIGINT to its notify-send), and Preview does not open [%r]"
      % order)
check(oct(os.stat(os.path.join(runtime, "grassfield")).st_mode & 0o777) == "0o700",
      "the notice's pid is kept in $XDG_RUNTIME_DIR/grassfield (0700)")
# Shift-Cmd-4 after a capture: the crosshair shows at once; only the picture waits for the last notice to be gone.
first = subprocess.Popen([helper, "screen"], env=dict(env, FAKE_ANSWER="hang"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(100):
    if len([c for c in calls("notify-send") if not c.get("signal")]) >= 3:
        break
    time.sleep(0.05)
time.sleep(0.2)
began = len(calls())
subprocess.run([slow, "selection"], env=dict(env, FAKE_ANSWER="", FAKE_SLURP="10,20 300x200"), capture_output=True, timeout=60)
first.wait(timeout=10)
after = calls()[began:]
stamp = {c["name"] + (":INT" if c.get("signal") else ""): c["t"] for c in reversed(after)}
check({"notify-send:INT", "slurp", "grim"} <= set(stamp) and stamp["slurp"] - stamp["notify-send:INT"] < 1.5
      and stamp["grim"] - stamp["notify-send:INT"] >= 2.9,
      "the crosshair shows at once after the last notice is closed; only the picture waits for it to be gone [%s]"
      % {k: round(v - stamp.get("notify-send:INT", 0), 2) for k, v in stamp.items()})
# The helper told to end (SIGTERM) while it waits on its notice: notify-send closes the notice and ends with it.
waiting = subprocess.Popen([helper, "screen"], env=dict(env, FAKE_ANSWER="hang"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(100):
    if len([c for c in calls("notify-send") if not c.get("signal")]) >= 5:
        break
    time.sleep(0.05)
time.sleep(0.2)
began = len(calls())
waiting.terminate()
waiting.wait(timeout=10)
time.sleep(0.3)
check(waiting.returncode == 143 and any(c.get("signal") == "INT" for c in calls()[began:]),
      "SIGTERM while the notice waits: notify-send closes it, the helper ends (%r)" % waiting.returncode)
# No click: no Preview.
r, _ = capture("screen", FAKE_ANSWER="")
check(calls("systemd-run") == [], "the notice closed without a click: Preview does not open")
# Without notify-send (libnotify is optional): the notice through gdbus, no button. Hermetic (integrator review of step 8,
# MAJOR): PATH is the fakes without notify-send and nothing else, so a machine's own /usr/bin/notify-send is never run.
check(shutil.which("notify-send", path=quiet) is None and shutil.which("gdbus", path=quiet),
      "the case without notify-send cannot reach one")
r, _ = capture("screen", path=quiet)
bus = calls("gdbus")
check(r.returncode == 0 and bus and "org.freedesktop.Notifications.Notify" in bus[0]["argv"]
      and bus[0]["argv"][bus[0]["argv"].index("org.freedesktop.Notifications.Notify") + 3] == "org.grassfield.Preview"
      and any(a.startswith("{'image-path': <\"" + desktop) for a in bus[0]["argv"]),
      "without notify-send: the notice through gdbus, with the picture [%r]" % (bus[0]["argv"] if bus else None))

# Failures leave nothing behind, and never end in a traceback.
count = len(files(desktop))
r, _ = capture("screen", FAKE_GRIM="fail")
check(r.returncode != 0 and len(files(desktop)) == count and calls("notify-send") == []
      and not any(f.startswith(".") for f in os.listdir(desktop)), "grim failing: no file left, no notice")
r, _ = capture("screen", FAKE_MONITORS="[]")
check(r.returncode != 0 and calls("grim") == [], "no display: nothing")
if os.geteuid() == 0:
    print("SKIP: a Desktop that cannot be written (root writes anywhere)")
else:
    os.chmod(desktop, 0o555)
    r, _ = capture("screen")
    os.chmod(desktop, 0o755)
    check(r.returncode == 1 and b"Traceback" not in r.stderr and len(files(desktop)) == count and calls("notify-send") == [],
          "a Desktop that cannot be written: nothing, and no traceback [%r]" % r.stderr[-200:])
r, _ = capture(None)
check(r.returncode == 2 and calls() == [], "no mode: usage, nothing run")
r, _ = capture("fullscreen")
check(r.returncode == 2 and calls() == [], "Omarchy's mode names are not taken")

# The Desktop: xdg-user-dir's, never the home folder or the root.
other = os.path.join(home, "Bureau")
r, _ = capture("screen", FAKE_DESKTOP=other)
check(len(files(other)) == 2, "xdg-user-dir's Desktop (a French one) [%r]" % files(other))
for bad in (home, "/", "", "relative/dir"):
    count = len(files(desktop))
    r, _ = capture("screen", FAKE_DESKTOP=bad)
    check(len(files(desktop)) == count + 2 and not any(f.endswith(".png") for f in os.listdir(home)),
          "xdg-user-dir answering %r: ~/Desktop" % bad)

# The shutter (ADR-0047 B-5): pw-play once a picture is saved, as Settings > Sound says (the defaults without a sound group).
def played():
    # pw-play is started in its own session and not waited for: give it a moment to record itself.
    for _ in range(40):
        if calls("pw-play"):
            break
        time.sleep(0.05)
    return [c["argv"] for c in calls("pw-play")]


SHUTTER = "/usr/share/sounds/grassfield/stereo/screen-capture.wav"
r, _ = capture("screen")
check(played() == [["--media-role", "Notification", "--volume", "0.422", "--", SHUTTER]],
      "the shutter plays once per capture at the default alert volume (0.75 cubed) [%r]" % played())
with open(os.path.join(config, "grassfield.json"), "w") as f:
    json.dump(dict({"version": 1}, **ON_DESKTOP, sound={"uiEffects": True, "alertVolume": 0.5, "effectsOutput": "bluez_output.AA_BB_CC_DD_EE_FF.1"}), f)
r, _ = capture("screen")
check(played() == [["--media-role", "Notification", "--volume", "0.125", "--target", "bluez_output.AA_BB_CC_DD_EE_FF.1", "--", SHUTTER]],
      "it follows the alert volume and the effects output [%r]" % played())
with open(os.path.join(config, "grassfield.json"), "w") as f:
    json.dump(dict({"version": 1}, **ON_DESKTOP, sound={"alertVolume": 7, "effectsOutput": "-x", "uiEffects": "no"}), f)
r, _ = capture("screen")
check(played() == [["--media-role", "Notification", "--volume", "1.000", "--", SHUTTER]],
      "the contract's rules: a volume clamped, an invalid output or switch is the default [%r]" % played())
for sound in ({"uiEffects": False}, {"alertVolume": 0}):
    with open(os.path.join(config, "grassfield.json"), "w") as f:
        json.dump(dict({"version": 1}, **ON_DESKTOP, sound=sound), f)
    r, _ = capture("screen")
    time.sleep(0.3)
    check(r.returncode == 0 and calls("pw-play") == [], "no shutter with %r" % sound)
os.unlink(os.path.join(config, "grassfield.json"))
os.mkfifo(os.path.join(config, "grassfield.json"))
r, _ = capture("screen")
check(r.returncode == 0 and len(played()) == 1, "a FIFO in place of grassfield.json is not waited on: the defaults")
os.unlink(os.path.join(config, "grassfield.json"))
r, _ = capture("screen", FAKE_GRIM="fail")
time.sleep(0.3)
check(calls("pw-play") == [], "no shutter when no picture was saved")

# French: the names and the notice.
set_config(dict({"version": 1}, **ON_DESKTOP))
r, _ = capture("screen", LANG="fr_FR.UTF-8")
fr = [f for f in files(desktop) if f.startswith("Capture")]
note = calls("notify-send")
check(len(fr) == 2 and all(re.fullmatch(r"Capture d’écran [0-9]{4}-[0-9]{2}-[0-9]{2} à [0-9]{2}\.[0-9]{2}\.[0-9]{2}( \(2\))?\.png", f)
                           for f in fr)
      and note and "default=Ouvrir dans la Visionneuse" in note[0]["argv"]
      and note[0]["argv"][-2:] == ["Capture d’écran", "Enregistrée sur le Bureau et copiée."],
      "in French: « Capture d’écran … à … », the notice in French [%r]" % fr)

# Save to's default (owner 2026-11-07: not the Desktop): with nothing chosen the keys save to a Screenshots folder in the Pictures
# folder, made on first use, and the notice names that folder. (The clipboard alone is options.py's: this grim fake writes no
# picture to its standard output.)
def shots(folder):
    return [f for f in files(folder) if name.fullmatch(f) or f.startswith("Capture d’écran ")]


os.unlink(os.path.join(config, "grassfield.json"))
pictures = os.path.join(home, "Pics")
screenshots = os.path.join(pictures, "Screenshots")
on_desktop = files(desktop)
r, _ = capture("screen", FAKE_PICTURES=pictures)
note = calls("notify-send")
focused = [f for f in shots(screenshots) if " (" not in f]
check(r.returncode == 0 and len(shots(screenshots)) == 2 and files(desktop) == on_desktop
      and not any(f.startswith(".") for f in os.listdir(screenshots))
      and note and note[0]["argv"][-2:] == ["Screenshot", "Saved to Screenshots and copied."]
      and len(focused) == 1 and "string:image-path:" + os.path.join(screenshots, focused[0]) in note[0]["argv"],
      "nothing chosen: a Screenshots folder made in xdg-user-dir's Pictures, the notice names it, nothing on the Desktop [%r %r]"
      % (files(screenshots), note[0]["argv"][-2:] if note else None))
default_shots = os.path.join(home, "Pictures", "Screenshots")
count = len(shots(default_shots))
r, _ = capture("screen")
check(len(shots(default_shots)) == count + 2, "no Pictures answer: ~/Pictures/Screenshots")
r, _ = capture("screen", FAKE_PICTURES=home)
check(len(shots(default_shots)) == count + 4 and not os.path.exists(os.path.join(home, "Screenshots")),
      "xdg-user-dir answering the home folder for Pictures: ~/Pictures/Screenshots, never a folder in the home folder")
# In French the folder is made under its French name; an English one already there is kept (no second folder).
images = os.path.join(home, "Images")
r, _ = capture("screen", FAKE_PICTURES=images, LANG="fr_FR.UTF-8")
note = calls("notify-send")
check(len(shots(os.path.join(images, "Captures d’écran"))) == 2 and note
      and note[0]["argv"][-1] == "Enregistrée dans Captures d’écran et copiée.",
      "in French: « Captures d’écran » in Images, the notice names it [%r]" % files(images))
r, _ = capture("screen", FAKE_PICTURES=pictures, LANG="fr_FR.UTF-8")
check(len(shots(screenshots)) == 4 and not os.path.exists(os.path.join(pictures, "Captures d’écran")),
      "in French, the Screenshots folder already there is used [%r]" % files(pictures))
# Back to English after French (review of e134ded6): the French folder already there is used, no "Screenshots" beside it.
r, _ = capture("screen", FAKE_PICTURES=images)
note = calls("notify-send")
check(len(shots(os.path.join(images, "Captures d’écran"))) == 4 and not os.path.exists(os.path.join(images, "Screenshots"))
      and note and note[0]["argv"][-1] == "Saved to Captures d’écran and copied.",
      "in English, the French folder already there is used, no second folder [%r]" % files(images))
# Something that is not a folder in its place: the pictures go to the Pictures folder itself, a link is never followed.
odd = os.path.join(home, "Odd")
os.makedirs(odd)
with open(os.path.join(odd, "Screenshots"), "w") as f:
    f.write("not a folder")
r, _ = capture("screen", FAKE_PICTURES=odd)
check(r.returncode == 0 and len(shots(odd)) == 2, "a file named Screenshots: the pictures go to the Pictures folder [%r]" % files(odd))
linked, target = os.path.join(home, "Linked"), os.path.join(tmp, "elsewhere")
os.makedirs(linked)
os.makedirs(target)
os.symlink(target, os.path.join(linked, "Screenshots"))
r, _ = capture("screen", FAKE_PICTURES=linked)
check(r.returncode == 0 and len(shots(linked)) == 2 and files(target) == [],
      "a link named Screenshots is not followed: the Pictures folder [%r %r]" % (files(linked), files(target)))
# The older key (capture.saveTo, before capture.location): its Documents stays, its Desktop (the old default every file the
# shell created held) moves to the Screenshots folder; capture.location wins, and a bad one is the default.
documents = os.path.join(home, "Docs")
set_config({"version": 1, "capture": {"saveTo": "documents"}})
r, _ = capture("screen", FAKE_PICTURES=pictures, FAKE_DOCUMENTS=documents)
note = calls("notify-send")
check(len(shots(documents)) == 2 and note and note[0]["argv"][-1] == "Saved to Documents and copied.",
      "the older Save to Documents stays [%r]" % files(documents))
set_config({"version": 1, "capture": {"saveTo": "desktop"}})
count, on_desktop = len(shots(screenshots)), files(desktop)
r, _ = capture("screen", FAKE_PICTURES=pictures)
check(len(shots(screenshots)) == count + 2 and files(desktop) == on_desktop,
      "the older Desktop, the old default, moves to the Screenshots folder")
set_config({"version": 1, "capture": {"saveTo": "documents", "location": "mail"}})
r, _ = capture("screen", FAKE_PICTURES=pictures, FAKE_DOCUMENTS=documents)
check(len(shots(screenshots)) == count + 4 and len(shots(documents)) == 2,
      "an unknown capture.location is the Screenshots folder; the older key is not read then")
set_config({"version": 1, "capture": {"location": "desktop", "saveTo": "documents"}})
r, _ = capture("screen", FAKE_PICTURES=pictures, FAKE_DOCUMENTS=documents)
check(len(files(desktop)) == len(on_desktop) + 2 and len(shots(screenshots)) == count + 4 and len(shots(documents)) == 2,
      "capture.location desktop: the Desktop, as chosen; the older key is not read then")
set_config({"version": 1, "capture": {"location": "preview"}})
r, _ = capture("selection", FAKE_PICTURES=pictures, FAKE_SLURP="10,20 300x200")
run = calls("systemd-run")
check(r.returncode == 0 and len(shots(screenshots)) == count + 5 and run and run[0]["argv"][-1].startswith(screenshots + "/")
      and calls("notify-send") == [], "capture.location preview: kept in the Screenshots folder, opened in Preview")
# A file the shell reads as its defaults (JsonSafety.js: a key twice in one object, an integer beyond 2^53, an integer-like key)
# reads as the defaults here too (review of e134ded6: the helper took the last `location` while the shell read the Screenshots
# folder).
for raw, why in (('{"version": 1, "capture": {"location": "documents", "location": "desktop"}}', "a duplicate location key"),
                 ('{"version": 1, "n": 9007199254740993, "capture": {"location": "desktop"}}', "an integer beyond 2^53"),
                 ('{"version": 1, "capture": {"location": "desktop"}, "x": {"7": 1}}', "an integer-like key")):
    with open(os.path.join(config, "grassfield.json"), "w") as f:
        f.write(raw)
    count, on_desktop, in_documents = len(shots(screenshots)), files(desktop), files(documents)
    r, _ = capture("screen", FAKE_PICTURES=pictures, FAKE_DOCUMENTS=documents)
    check(r.returncode == 0 and len(shots(screenshots)) == count + 2 and files(desktop) == on_desktop and files(documents) == in_documents,
          "an unsafe file (%s): the default place, as the shell reads it" % why)
# The same values written safely are followed (the rule is the file's, not the value's).
set_config({"version": 1, "n": 9007199254740991, "capture": {"location": "desktop"}})
on_desktop = files(desktop)
r, _ = capture("screen", FAKE_PICTURES=pictures)
check(len(files(desktop)) == len(on_desktop) + 2, "2^53 - 1 is safe: capture.location desktop is followed")

sys.exit(1 if failed else 0)
