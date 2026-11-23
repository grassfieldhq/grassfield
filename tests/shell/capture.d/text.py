# ADR-0066 D-7, slice C3 (`text`) and C8 (`selection --previous`) of packaging/bin/grassfield-capture, against fakes of grim,
# slurp, tesseract, zbarimg, wl-copy, notify-send and hyprctl (run by tests/shell/capture.sh as `python3 -I text.py <root> <tmp>`).
# The fakes log every call with its argv, its standard input's size and, for wl-copy, what it was given.
import json
import os
import re
import stat
import subprocess
import sys

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


fake, home, log, runtime = (os.path.join(tmp, d) for d in ("tfake", "thome", "tlog", "trun"))
for d in (fake, home, log):
    os.makedirs(d)
os.makedirs(runtime, mode=0o700)
helper = os.path.join(root, "packaging/bin/grassfield-capture")
source = open(helper).read()

for name in ("grim", "slurp", "hyprctl", "wl-copy", "notify-send", "tesseract", "zbarimg", "xdg-user-dir"):
    write(os.path.join(fake, name), r'''#!/usr/bin/python3 -I
import json, os, sys, time
name = os.path.basename(sys.argv[0])
env = os.environ
data = b"" if name in ("grim", "hyprctl", "notify-send", "xdg-user-dir") else sys.stdin.buffer.read()
with open(os.path.join(env["FAKE_LOG"], "calls"), "a") as f:
    f.write(json.dumps({"name": name, "argv": sys.argv[1:], "size": len(data), "t": time.monotonic(),
                        "data": data.decode("utf-8", "replace") if name == "wl-copy" else "",
                        "nice": os.getpriority(os.PRIO_PROCESS, 0), "omp": env.get("OMP_THREAD_LIMIT")}) + "\n")
if name == "grim":
    if sys.argv[-1] == "-":
        sys.stdout.buffer.write(b"P6\n1 1\n255\n\0\0\0")
    else:
        open(sys.argv[-1], "wb").write(b"\x89PNG\r\n\x1a\n" + (13).to_bytes(4, "big") + b"IHDR" + (5).to_bytes(4, "big")
                                       + (5).to_bytes(4, "big") + b"\x08\x06\x00\x00\x00fake")
elif name == "slurp":
    print(env.get("FAKE_SLURP", "10,20 300x100"))
elif name == "hyprctl":
    print(env["FAKE_MONITORS"] if sys.argv[2] == "monitors" else "[]")
elif name == "xdg-user-dir":
    sys.exit(1)
elif name == "notify-send":
    print(17, flush=True)
elif name == "tesseract":
    if sys.argv[1] == "--list-langs":
        print('List of available languages in "/usr/share/tessdata/" (%s):' % env.get("FAKE_LANGS", "eng").count("\n"))
        print(env.get("FAKE_LANGS", "eng\nosd"))
    else:
        sys.stdout.write(env.get("FAKE_TEXT", ""))
elif name == "zbarimg":
    sys.stdout.write(env.get("FAKE_QR", ""))
    sys.exit(0 if env.get("FAKE_QR") else 4)
''')

MONITORS = json.dumps([
    {"name": "DP-1", "x": 0, "y": 0, "width": 2400, "height": 1350, "scale": 1.25, "transform": 0, "focused": False,
     "activeWorkspace": {"id": 1}, "specialWorkspace": {"id": 0}},
    {"name": "HDMI-A-1", "x": 1920, "y": 0, "width": 1000, "height": 800, "scale": 1.0, "transform": 0, "focused": True,
     "activeWorkspace": {"id": 2}, "specialWorkspace": {"id": 0}}])
config = os.path.join(home, ".config", "grassfield")
os.makedirs(config)
folder = os.path.join(runtime, "grassfield")
result_file = os.path.join(folder, "capture-result.json")
BASE = {"PATH": fake + ":/usr/bin:/bin", "HOME": home, "FAKE_LOG": log, "FAKE_MONITORS": MONITORS, "XDG_RUNTIME_DIR": runtime}


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
    for p in (os.path.join(log, "calls"), result_file, os.path.join(folder, "capture-ack"), os.path.join(folder, "capture-state.json")):
        if os.path.lexists(p):
            os.unlink(p)


def go(args, **extra):
    reset()
    env = dict(BASE)
    env.update(extra)
    return subprocess.run([helper] + args, env=env, capture_output=True, timeout=60)


def result():
    try:
        return json.load(open(result_file))
    except (OSError, ValueError):
        return None


def tess(name="text"):
    return [c for c in calls("tesseract") if c["argv"][:1] != ["--list-langs"]]


marker = os.path.join(runtime, "grassfield-lock-default")
set_config({})
GEO = ["--geometry", "2000,100 400x300"]  # on HDMI-A-1 (logical 1920,0 1000x800)

# ---- C3: the tools and their arguments ----
# Preview's vectors, read from its source: the text command's arguments with `psm` and `tsv` replaced.
cpp = open(os.path.join(root, "apps/preview/src/previewlogic.cpp")).read()
text_branch = cpp.split('tool == QLatin1String("text")')[1].split('} else if (tool == QLatin1String("qr"))')[0]
preview_text = re.findall(r'QStringLiteral\("([^"]*)"\)', text_branch.split("out.arguments")[1])
preview_qr = re.findall(r'QStringLiteral\("([^"]*)"\)', cpp.split('tool == QLatin1String("qr")')[1].split("out.image")[0])[1:]
r = go(["text"] + GEO, FAKE_TEXT="Hello\nworld\f\n", FAKE_LANGS="eng\nfra\nosd", LANG="fr_FR.UTF-8")
t = tess()
check(r.returncode == 0 and len(t) == 1 and preview_text[:2] == ["stdin", "stdout"] and "tsv" in preview_text,
      "Preview's text vector is read from previewlogic.cpp [%r]" % preview_text)
check(t and t[0]["argv"] == ["stdin", "stdout", "--oem", "1", "--psm", "6", "--dpi", "300", "-l", "fra+eng"],
      "tesseract's argv equals Preview's except --psm 6 and plain text (no tsv) [%r]" % (t[0]["argv"] if t else None))
check(t and t[0]["argv"] == [("6" if a == "3" else a) for a in preview_text if a not in ("tsv", "languages")] + ["fra+eng"],
      "the same fields as Preview's, in the same order, but --psm 6, no tsv")
check(bool(t) and t[0]["nice"] == 19 and t[0]["omp"] == "1",
      "tesseract runs at the lowest priority with one OpenMP thread [%r]" % ([(t[0]["nice"], t[0]["omp"]) if t else None],))
copied = calls("wl-copy")
check(len(copied) == 1 and copied[0]["argv"] == ["--type", "text/plain"] and copied[0]["data"] == "Hello\nworld",
      "the plain text is copied, trimmed, not sensitive [%r]" % [(c["argv"], c["data"]) for c in copied])
check(calls("zbarimg") and calls("zbarimg")[0]["argv"] == preview_qr and preview_qr == ["-q", "-Sdisable", "-Sqrcode.enable", "-"],
      "zbarimg reads QR only, with Preview's arguments [%r]" % [c["argv"] for c in calls("zbarimg")])
grim = calls("grim")
check(len(grim) == 1 and grim[0]["argv"] == ["-t", "ppm", "-g", "2000,100 400x300", "-"],
      "grim takes the area to its standard output [%r]" % [c["argv"] for c in grim])
check(os.path.exists(os.path.join(folder, "capture-state.json")) and json.load(open(os.path.join(folder, "capture-state.json"))).get("phase") == "idle",
      "the picture is taken through the shooting handshake (the state is idle after it)")
res = result()
check(res and res["kind"] == "text" and res["text"] == "Hello\nworld" and res["paths"] == [] and res["primary"] == ""
      and res["output"] == "HDMI-A-1" and res["rect"] == {"x": 2000, "y": 100, "w": 400, "h": 300}
      and stat.S_IMODE(os.stat(result_file).st_mode) == 0o600, "a text result: the text, no path, 0600 [%r]" % res)
check(len(calls("notify-send")) == 1 and calls("notify-send")[0]["argv"][-2:] == ["Capturer le texte", "Texte copié."],
      "no shell acknowledged: the result is written and the notice shows the copy")

# languages: the session's language only when installed; English; none installed
r = go(["text"] + GEO, FAKE_TEXT="x", FAKE_LANGS="eng\nosd", LANG="fr_FR.UTF-8")
check(tess() and tess()[0]["argv"][-2:] == ["-l", "eng"], "French not installed: English only")
r = go(["text"] + GEO, FAKE_TEXT="x", FAKE_LANGS="deu\nosd", LANG="en_US.UTF-8")
check(tess() == [] and len(calls("notify-send")) == 1 and calls("wl-copy") == [], "no language installed: no recognition, a notice")

# ---- QR ----
set_config({})
r = go(["text"] + GEO, FAKE_QR="QR-Code:https://example.org/a?b=1\nQR-Code:second\nline2\nQR-Code:https://example.org/a?b=1\nQR-Code:second\nline2\n", FAKE_TEXT="NOT READ")
copied = calls("wl-copy")
check(r.returncode == 0 and len(copied) == 1 and copied[0]["argv"] == ["--type", "text/plain", "--sensitive"]
      and copied[0]["data"] == "https://example.org/a?b=1\nsecond\nline2" and tess() == [],
      "QR codes (deduplicated, continued lines) go through wl-copy --sensitive; tesseract is not run [%r]"
      % [(c["argv"], c["data"]) for c in copied])
res = result()
check(res and res["kind"] == "text" and res["text"] == "" and "example.org" not in open(result_file).read() and "second" not in open(result_file).read(),
      "the QR data is never in the result file [%r]" % res)
out = r.stdout + r.stderr + b"".join(json.dumps(c["argv"]).encode() for c in calls("notify-send"))
check(b"example.org" not in out, "the QR data is in no notice, output or log")
# a thumbnail off: a notice without the data
set_config({"showThumbnail": False})
r = go(["text"] + GEO, FAKE_QR="QR-Code:secret-data\n")
note = calls("notify-send")
check(len(note) == 1 and "secret-data" not in json.dumps(note[0]["argv"]) and not os.path.exists(result_file)
      and note[0]["argv"][-2:] == ["Capture Text", "QR code copied."], "showThumbnail off: a notice, no result [%r]" % [n["argv"][-2:] for n in note])
set_config({})

# ---- no text, no tool ----
r = go(["text"] + GEO, FAKE_TEXT=" \n\f")
check(r.returncode == 0 and calls("wl-copy") == [] and len(calls("notify-send")) == 1
      and calls("notify-send")[0]["argv"][-2:] == ["Capture Text", "No text was found."] and not os.path.exists(result_file),
      "no text: a notice, nothing copied, no result [%r]" % [n["argv"][-2:] for n in calls("notify-send")])
r = go(["text"] + GEO, FAKE_TEXT="ignored", LANG="fr_FR.UTF-8", FAKE_LANGS="fra\neng")
note = calls("notify-send")
check(len(note) == 1 and note[0]["argv"][-2:] == ["Capturer le texte", "Texte copié."],
      "in French: the notice of a copy [%r]" % [n["argv"][-2:] for n in note])
r = go(["text"] + GEO, FAKE_TEXT="", LANG="fr_FR.UTF-8")
check(calls("notify-send") and calls("notify-send")[0]["argv"][-2:] == ["Capturer le texte", "Aucun texte trouvé."],
      "in French: the notice without text")
empty = os.path.join(tmp, "tbare")
os.makedirs(empty)
for n in ("grim", "hyprctl", "wl-copy", "notify-send"):
    os.symlink(os.path.join(fake, n), os.path.join(empty, n))
r = go(["text"] + GEO, PATH=empty + ":/nonexistent", FAKE_TEXT="x", LANG="fr_FR.UTF-8")
check(r.returncode == 0 and calls("wl-copy") == [] and calls("notify-send")
      and calls("notify-send")[0]["argv"][-2:] == ["Capturer le texte", "La reconnaissance de texte n’est pas installée."],
      "no tesseract: a notice that recognition is not installed, exit 0")

# ---- C3: arguments and the lock ----
for bad in (["text", "--geometry"], ["text", "--geometry", "1,2 3"], ["text", "--geometry", "0,0 0x5"], ["text", "--save", "desktop"],
            ["text", "--geometry", "1,2 3x4", "--pointer"], ["text", "extra"]):
    r = go(bad)
    check(r.returncode == 2 and calls("grim") == [], "bad arguments %r: the usage, exit 2, no picture" % " ".join(bad))
r = go(["text", "--geometry", "5000,5000 10x10"])
check(r.returncode == 2 and calls("grim") == [], "a geometry off every display: exit 2, no picture")
with open(marker, "w") as f:
    f.write("locked\n")
os.chmod(marker, 0o600)
r = go(["text"] + GEO, FAKE_TEXT="x")
check(r.returncode == 1 and calls("grim") == [] and calls("wl-copy") == [] and calls("slurp") == [],
      "under the lock (the marker): no crosshair, no picture, no copy, exit 1")
r = go(["text"], FAKE_TEXT="x")
check(r.returncode == 1 and calls("grim") == [] and calls("slurp") == [], "under the lock, the crosshair is not shown either")
os.unlink(marker)
blocked = json.dumps([dict(json.loads(MONITORS)[1], solitaryBlockedBy=["LOCK"])])
r = go(["text"] + GEO, FAKE_TEXT="x", FAKE_MONITORS=blocked)
check(r.returncode == 1 and calls("grim") == [], "under the lock (Hyprland's display blocked by LOCK): no picture")

# the crosshair when there is no --geometry
r = go(["text"], FAKE_TEXT="from slurp")
check(r.returncode == 0 and calls("slurp") and calls("grim") and calls("grim")[0]["argv"][-2] == "10,20 300x100"
      and calls("wl-copy")[0]["data"] == "from slurp", "without --geometry the crosshair chooses the area")

# the language table equals Preview's
js = open(os.path.join(root, "apps/preview/qml/TextInImages.js")).read()
table = dict(re.findall(r'([a-z]{2}): "([a-z]{3})"', js.split("const languageCodes = {")[1].split("};")[0]))
ns = {}
exec(re.search(r"^LANGUAGE_CODES = .*?\.split\(\)\)", source, re.M | re.S).group(0), {}, ns)
check(ns["LANGUAGE_CODES"] == table and len(table) > 70, "the language codes equal Preview's table (%d)" % len(table))

# ---- C8: selection --previous ----
STORED = "DP-1=10,20,300,200;HDMI-A-1=100,50,400,300;Other=1,2,3,4"
set_config({"lastSelection": STORED, "location": "desktop"})
r = go(["selection", "--previous"], FAKE_DESKTOP=os.path.join(home, "Desktop"))
g = calls("grim")
check(r.returncode == 0 and len(g) == 1 and g[0]["argv"][:2] == ["-g", "2020,50 400x300"] and calls("slurp") == [],
      "the focused display's entry (HDMI-A-1, in its own coordinates + its origin) is the area, no crosshair [%r]"
      % [c["argv"] for c in g])
# the other display focused
other = json.dumps([dict(m, focused=(m["name"] == "DP-1")) for m in json.loads(MONITORS)])
r = go(["selection", "--previous"], FAKE_MONITORS=other, FAKE_DESKTOP=os.path.join(home, "Desktop"))
check(calls("grim") and calls("grim")[0]["argv"][:2] == ["-g", "10,20 300x200"], "the focused display decides (DP-1 focused: its entry)")
# a frame off its display is brought back
set_config({"lastSelection": "HDMI-A-1=900,700,400,300"})
r = go(["selection", "--previous"], FAKE_DESKTOP=os.path.join(home, "Desktop"))
check(calls("grim") and calls("grim")[0]["argv"][:2] == ["-g", "2520,500 400x300"], "a frame off its display is moved back inside it")
set_config({"lastSelection": "HDMI-A-1=0,0,5000,5000"})
r = go(["selection", "--previous"], FAKE_DESKTOP=os.path.join(home, "Desktop"))
check(calls("grim") and calls("grim")[0]["argv"][:2] == ["-g", "1920,0 1000x800"], "a frame larger than its display is cut to it")
# a missing entry: the crosshair
for stored in ("", "DP-1=1,2,3,4", "HDMI-A-1=1,2,0,4", "garbage", "HDMI-A-1=1,2,3"):
    set_config({"lastSelection": stored})
    r = go(["selection", "--previous"], FAKE_DESKTOP=os.path.join(home, "Desktop"))
    check(r.returncode == 0 and len(calls("slurp")) == 1 and calls("grim") and calls("grim")[0]["argv"][:2] == ["-g", "10,20 300x100"],
          "lastSelection %r has no entry for the focused display: the crosshair" % stored)
set_config({})
r = go(["selection", "--previous"], FAKE_DESKTOP=os.path.join(home, "Desktop"))
check(len(calls("slurp")) == 1, "no lastSelection at all: the crosshair")
# the lock
set_config({"lastSelection": STORED})
with open(marker, "w") as f:
    f.write("locked\n")
os.chmod(marker, 0o600)
r = go(["selection", "--previous"], FAKE_DESKTOP=os.path.join(home, "Desktop"))
check(r.returncode == 1 and calls("grim") == [] and calls("slurp") == [], "under the lock: refused, no crosshair, no picture")
os.unlink(marker)
r = go(["selection", "--previous"], FAKE_MONITORS=blocked, FAKE_DESKTOP=os.path.join(home, "Desktop"))
check(r.returncode == 1 and calls("grim") == [], "under the lock (display blocked by LOCK): refused")
# arguments
for bad in (["selection", "--previous", "--geometry", "1,2 3x4"], ["screen", "--previous"], ["window", "--previous"],
            ["selection", "--previous", "--previous"], ["record", "selection", "--previous"]):
    r = go(bad)
    check(r.returncode == 2 and calls("grim") == [], "bad arguments %r: exit 2" % " ".join(bad))
r = go(["selection", "--previous", "--pointer", "--timer", "0", "--save", "clipboard"])
check(r.returncode == 0 and calls("grim") and calls("grim")[0]["argv"][:3] == ["-g", "2020,50 400x300", "-c"],
      "--previous takes the other options (--pointer, --save) [%r]" % [c["argv"] for c in calls("grim")])

sys.exit(1 if failed else 0)
