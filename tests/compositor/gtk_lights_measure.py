#!/usr/bin/env python3
"""Measurements for tests/compositor/gtk_lights.sh: the traffic lights of a capture, in device pixels (stdlib; ImageMagick reads
the PNG).

    gtk_lights_measure.py lights PNG X Y W H TOKENS.json APPEARANCE   JSON on stdout: per light, its disc and its glyph
    gtk_lights_measure.py check DIR                                   compare the cases in DIR with the plugin's own (foot)

A light is the set of pixels within TOL of its token colour (window.closeColor, minimizeColor, zoomColor); its disc is their
bounding box, its centre the box's centre, its glyph the pixels inside the disc that are darker than the light by a third (the
plugin's glyph is black at window.glyphOpacity over it). A grey light (a window that is not active) is the pixels of the
inactive colour that sit where the active discs sit; its count is reported.
"""
import json
import pathlib
import subprocess
import sys

TOL = 14
NAMES = ("close", "minimize", "zoom")
KEYS = ("closeColor", "minimizeColor", "zoomColor")


def rgb(hex_colour):
    h = hex_colour.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def crop(png, x, y, w, h):
    raw = subprocess.run(["magick", png, "-crop", f"{w}x{h}+{x}+{y}", "+repage", "-depth", "8", "rgb:-"],
                         capture_output=True, check=True).stdout
    return raw


def near(p, c, tol=TOL):
    return abs(p[0] - c[0]) <= tol and abs(p[1] - c[1]) <= tol and abs(p[2] - c[2]) <= tol


def lights(png, x, y, w, h, tokens, appearance):
    win = tokens["window"]
    raw = crop(png, x, y, w, h)
    px = [tuple(raw[i:i + 3]) for i in range(0, len(raw) - 2, 3)]
    out = {}
    grey = rgb(win["inactiveLightDark" if appearance == "dark" else "inactiveLightLight"]["value"])
    for name, key in zip(NAMES, KEYS):
        colour = rgb(win[key]["value"])
        pts = [(i % w, i // w) for i, p in enumerate(px) if near(p, colour)]
        pressed = tuple(round(v * (1 - win["pressedOpacity"]["value"])) for v in colour)
        held = sum(1 for p in px if near(p, pressed))
        if len(pts) < 20:
            out[name] = {"n": len(pts), "held": held}
            continue
        x0, x1 = min(p[0] for p in pts), max(p[0] for p in pts)
        y0, y1 = min(p[1] for p in pts), max(p[1] for p in pts)
        cx, cy = (x0 + x1) / 2 + 0.5, (y0 + y1) / 2 + 0.5  # from the crop's corner
        radius = max(x1 - x0, y1 - y0) / 2
        dark = 0
        for j in range(y0, y1 + 1):
            for i in range(x0, x1 + 1):
                if (i - (x0 + x1) / 2) ** 2 + (j - (y0 + y1) / 2) ** 2 <= (radius * 0.8) ** 2:
                    p = px[j * w + i]
                    if sum(p) < 0.67 * sum(colour):
                        dark += 1
        out[name] = {"n": len(pts), "d": max(x1 - x0, y1 - y0) + 1, "cx": cx, "cy": cy, "glyph": dark, "held": held}
    # Grey discs: pixels of the inactive colour; their bounding boxes by thirds of the span (three discs in a row).
    gp = [(i % w, i // w) for i, p in enumerate(px) if near(p, grey, 6)]
    out["grey"] = {"n": len(gp)}
    return out


def check(directory):
    d = pathlib.Path(directory)
    cases = {p.stem: json.loads(p.read_text()) for p in sorted(d.glob("*.json"))}
    scale = cases.get("scale", {}).get("scale", 1.25)
    fails = 0

    def ok(cond, text):
        nonlocal fails
        print(("PASS: " if cond else "FAIL: ") + text)
        fails += 0 if cond else 1

    print(f"{'case':<22}{'light':<10}{'n':>6}{'disc':>6}{'cx':>8}{'cy':>8}{'glyph':>7}")
    for case, data in cases.items():
        if case == "scale":
            continue
        for name in NAMES + ("grey",):
            m = data.get(name, {})
            print(f"{case:<22}{name:<10}{m.get('n', 0):>6}{m.get('d', '-'):>6}{m.get('cx', 0):>8.1f}{m.get('cy', 0):>8.1f}"
                  f"{m.get('glyph', '-'):>7}")
    ref = cases.get("foot-active")
    if not ref or "close" not in ref or "d" not in ref["close"]:
        ok(False, "the plugin's own lights (foot) were measured")
        return 1
    ref_pitch = ref["minimize"]["cx"] - ref["close"]["cx"]
    for toolkit in ("gtk3", "gtk4", "evince", "chromium-gtk"):
        a = cases.get(f"{toolkit}-active")
        if not a or "d" not in a.get("close", {}):
            ok(False, f"{toolkit}: the three lights are drawn (active)")
            continue
        got = all("d" in a.get(n, {}) for n in NAMES)
        ok(got, f"{toolkit}: close, minimize and zoom lights found when active {[a.get(n, {}).get('n') for n in NAMES]}")
        if not got:
            continue
        ok(all(abs(a[n]["d"] - ref[n]["d"]) <= 1.5 for n in NAMES),
           f"{toolkit}: the disc is the plugin's {[a[n]['d'] for n in NAMES]} vs {[ref[n]['d'] for n in NAMES]} device px")
        # Chromium lays its own caption buttons out (its own insets): its disc, pitch and states are checked, not its first centre.
        ok(toolkit == "chromium-gtk" or abs(a["close"]["cx"] - ref["close"]["cx"]) <= 1.5,
           f"{toolkit}: first centre {a['close']['cx']:.1f} from the window's left edge (plugin's {ref['close']['cx']:.1f}) device px")
        pitch = a["minimize"]["cx"] - a["close"]["cx"]
        ok(abs(pitch - ref_pitch) <= 1.5, f"{toolkit}: pitch {pitch:.1f} (plugin's {ref_pitch:.1f}) device px")
        ok(abs(a["close"]["cy"] - a["minimize"]["cy"]) <= 1 and abs(a["close"]["cy"] - a["zoom"]["cy"]) <= 1,
           f"{toolkit}: the three discs share one row")
        ok(all(a[n].get("glyph", 0) <= 3 for n in NAMES), f"{toolkit}: no glyph while the pointer is away {[a[n].get('glyph') for n in NAMES]}")
        h = cases.get(f"{toolkit}-hover")
        if h:
            first = h.get("close", {}).get("glyph", 0)
            ok(first >= 6, f"{toolkit}: the hovered close light shows its glyph [{first} dark px]")
            if toolkit == "gtk4":
                ok(all(h.get(n, {}).get("glyph", 0) >= 6 for n in NAMES), "gtk4: all three glyphs while the pointer is over the group")
            ok(abs(h["close"].get("d", 0) - a["close"]["d"]) <= 1.5, f"{toolkit}: the hover leaves the disc as it was (no GTK hover disc)")
        i = cases.get(f"{toolkit}-inactive")
        if i:
            ok(all(i.get(n, {}).get("n", 0) < 20 for n in NAMES) and i.get("grey", {}).get("n", 0) >= 150,
               f"{toolkit}: inactive, the lights are grey [{i.get('grey', {}).get('n')} grey px, colours "
               f"{[i.get(n, {}).get('n') for n in NAMES]}]")
        pr = cases.get(f"{toolkit}-pressed")
        if pr:
            ok(pr.get("close", {}).get("n", 0) < 0.3 * a["close"]["n"] and pr["close"].get("held", 0) >= 100,
               f"{toolkit}: pressed, the close light has its pressed colour [{pr.get('close', {}).get('held')} px of it, "
               f"{pr.get('close', {}).get('n')} of the colour]")
    classic = cases.get("chromium-classic-active")
    if classic:
        # A fresh profile started through the session stand-in is created with the GTK appearance, so it draws the lights at
        # the plugin's size (R7-FUN-04; before rc7 a fresh profile drew Chromium's own plain buttons).
        found = all("d" in classic.get(n, {}) for n in NAMES)
        ok(found and all(abs(classic[n]["d"] - ref[n]["d"]) <= 1.5 for n in NAMES),
           f"chromium fresh profile through the session stand-in: the three lights at the plugin's disc "
           f"{[classic.get(n, {}).get('d') for n in NAMES]} vs {[ref[n]['d'] for n in NAMES]} device px")
    return 1 if fails else 0


def main(argv):
    if argv[1] == "lights":
        png, x, y, w, h = argv[2], *map(int, argv[3:7])
        tokens = json.loads(pathlib.Path(argv[7]).read_text())
        print(json.dumps(lights(png, x, y, w, h, tokens, argv[8])))
        return 0
    if argv[1] == "check":
        return check(argv[2])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
