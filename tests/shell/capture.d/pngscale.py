# The Grassfield-Scale tEXt chunk of packaging/bin/grassfield-capture's PNG screenshots (run by tests/shell/capture.sh as
# `python3 -I pngscale.py <root> <tmp>`): the screenshot editor reads the capture's output scale from it (apps/screenshot,
# QImage::text("Grassfield-Scale")). Present with the display's scale in every saved PNG, every CRC right, the picture
# intact, a file the helper did not write never touched.
import json
import os
import struct
import subprocess
import sys
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


fake, home, runtime = (os.path.join(tmp, d) for d in ("pfake", "phome", "prun"))
for d in (fake, home):
    os.makedirs(d)
os.makedirs(runtime, mode=0o700)
helper = os.path.join(root, "packaging/bin/grassfield-capture")
for name in ("grim", "hyprctl", "wl-copy", "notify-send", "xdg-user-dir"):
    write(os.path.join(fake, name), r'''#!/usr/bin/python3 -I
import os, struct, sys, zlib
name = os.path.basename(sys.argv[0])


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


if name == "grim":
    rows = b"".join(b"\0" + bytes(range(12)) for _ in range(2))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 2, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows))
           + chunk(b"IEND", b""))
    if sys.argv[-1] == "-":
        sys.stdout.buffer.write(png)
    else:
        open(sys.argv[-1], "wb").write(png)
elif name == "hyprctl":
    print(os.environ["FAKE_MONITORS"] if sys.argv[2] == "monitors" else "[]")
elif name == "xdg-user-dir":
    sys.exit(1)
elif name == "notify-send":
    print(17, flush=True)
else:
    sys.stdin.buffer.read()
''')


def monitor(name, x, scale, focused):
    return {"name": name, "x": x, "y": 0, "width": int(1000 * scale), "height": int(800 * scale), "scale": scale, "transform": 0,
            "focused": focused, "activeWorkspace": {"id": 1}, "specialWorkspace": {"id": 0}}


MONITORS = json.dumps([monitor("DP-1", 0, 1.0, True), monitor("HDMI-A-1", 1000, 1.25, False)])
config = os.path.join(home, ".config", "grassfield")
os.makedirs(config)
desktop = os.path.join(home, "Desktop")
os.makedirs(desktop)
BASE = {"PATH": fake + ":/usr/bin:/bin", "HOME": home, "XDG_RUNTIME_DIR": runtime, "FAKE_MONITORS": MONITORS, "FAKE_DESKTOP": desktop}


def config_with(capture):
    with open(os.path.join(config, "grassfield.json"), "w") as f:
        json.dump({"version": 1, "capture": dict({"location": "desktop", "showThumbnail": False}, **capture)}, f)


def helper_run(args, **env):
    return subprocess.run([helper] + args, env=dict(BASE, **env), capture_output=True, timeout=60)


def shoot(args, **env):
    for f in os.listdir(desktop):
        os.unlink(os.path.join(desktop, f))
    r = helper_run(args, **env)
    return r, sorted(os.path.join(desktop, f) for f in os.listdir(desktop))


def chunks(path):
    # Every chunk of a PNG as (type, body), each CRC checked; None when the file is not a whole PNG.
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    out, i = [], 8
    while i < len(data):
        size = struct.unpack(">I", data[i:i + 4])[0]
        kind, body, crc = data[i + 4:i + 8], data[i + 8:i + 8 + size], data[i + 8 + size:i + 12 + size]
        if len(crc) != 4 or struct.unpack(">I", crc)[0] != zlib.crc32(kind + body):
            return None
        out.append((kind, body))
        i += 12 + size
    return out


def scale_of(path):
    c = chunks(path)
    if not c:
        return None
    texts = [b for k, b in c if k == b"tEXt" and b.startswith(b"Grassfield-Scale\0")]
    return texts[0].split(b"\0", 1)[1].decode() if len(texts) == 1 else None


def intact(path):
    c = chunks(path)
    return bool(c) and [k for k, _ in c] == [b"IHDR", b"tEXt", b"IDAT", b"IEND"] and \
        zlib.decompress(dict(c)[b"IDAT"]) == b"".join(b"\0" + bytes(range(12)) for _ in range(2))


config_with({})
r, files = shoot(["screen"])
check(r.returncode == 0 and len(files) == 2 and sorted(scale_of(f) for f in files) == ["1.0", "1.25"] and all(intact(f) for f in files),
      "fullscreen: one file per display, each with its own display's scale (1 and 1.25), CRCs right, the picture intact [%r]"
      % [scale_of(f) for f in files])
r, files = shoot(["screen", "--output", "HDMI-A-1"])
check(len(files) == 1 and scale_of(files[0]) == "1.25" and intact(files[0]), "one display: its scale, 1.25")
r, files = shoot(["selection", "--geometry", "100,100 300x200"])
check(len(files) == 1 and scale_of(files[0]) == "1.0" and intact(files[0]), "an area on the 1.0 display: 1.0")
r, files = shoot(["window", "--geometry", "1100,50 300x200"])
check(len(files) == 1 and scale_of(files[0]) == "1.25" and intact(files[0]), "a window on the 1.25 display: 1.25")
config_with({"lastSelection": "HDMI-A-1=10,20,300,200"})
focused_hdmi = json.dumps([monitor("DP-1", 0, 1.0, False), monitor("HDMI-A-1", 1000, 1.25, True)])
r, files = shoot(["selection", "--previous"], FAKE_MONITORS=focused_hdmi)
check(len(files) == 1 and scale_of(files[0]) == "1.25" and intact(files[0]), "the previous area: the focused display's scale")
config_with({})

# a file the helper did not write is never touched: the new picture takes the next free name beside it, and no hidden file stays
for f in os.listdir(desktop):
    os.unlink(os.path.join(desktop, f))
r = helper_run(["selection", "--geometry", "100,100 300x200"])
taken = os.listdir(desktop)[0]
foreign = b"\x89PNG\r\n\x1a\n" + b"not a real png, someone else's"
os.unlink(os.path.join(desktop, taken))
with open(os.path.join(desktop, taken), "wb") as f:  # the name a capture of the same second would take
    f.write(foreign)
before = os.stat(os.path.join(desktop, taken))
r = helper_run(["selection", "--geometry", "100,100 300x200"])
after = os.stat(os.path.join(desktop, taken))
now = sorted(os.listdir(desktop))
check(open(os.path.join(desktop, taken), "rb").read() == foreign and (before.st_mtime_ns, before.st_ino) == (after.st_mtime_ns, after.st_ino),
      "a file already there is neither replaced nor rewritten [%r]" % now)
check(len(now) == 2 and not [f for f in now if f.startswith(".")], "the second picture sits beside it, no hidden file is left")

sys.exit(1 if failed else 0)
