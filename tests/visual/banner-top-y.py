#!/usr/bin/env python3
"""Per frame, the card runs of the banner stack (UI audit 2026-11-05 U1).

Usage: banner-top-y.py CASEDIR SCALE [REST_Y]
CASEDIR holds EPOCH.ppm frames written by tests/visual/flow-banner-exit.sh (the banners strip, device pixels, the card
left edge 24 logical px from the strip's left). Reads one pixel column inside the cards' left padding and prints, per
frame: time since the first frame, the rest-relative state and the runs "start-end" (30 px or more: the close button is left out) of card-like rows (a dark, neutral
row: the glass card over the wallpaper). REST_Y defaults to the rest position of the top card, (menubar 24 + inset 16)
logical px times SCALE. The last lines list the blips (a top card elsewhere for one or two frames between two frames that
agree) and count the frames whose first run starts above REST_Y (a card above its rest position: the jump of U1).
"""
import sys
from pathlib import Path


def read_ppm(path):
    data = Path(path).read_bytes()
    parts = data.split(maxsplit=4)
    assert parts[0] == b"P6", path
    w, h = int(parts[1]), int(parts[2])
    off = len(data) - w * h * 3
    return w, h, data[off:]


def runs_of(path, col_dev):
    w, h, px = read_ppm(path)
    runs, start = [], None
    for y in range(h):
        i = (y * w + col_dev) * 3
        r, g, b = px[i], px[i + 1], px[i + 2]
        card = ((b - r) < 30 and r < 130) or (r > 190 and g > 190 and b > 190)
        if card and start is None:
            start = y
        if not card and start is not None:
            if y - start >= 30:
                runs.append((start, y - 1))
            start = None
    if start is not None and h - start >= 30:
        runs.append((start, h - 1))
    return runs


def main():
    case, scale = Path(sys.argv[1]), float(sys.argv[2])
    rest = int(round(float(sys.argv[3]))) if len(sys.argv) > 3 else int(round(40 * scale))
    col = int(round((24 + 20) * scale))
    frames = sorted(case.glob("*.ppm"), key=lambda p: float(p.stem))
    if not frames:
        sys.exit("no frames in " + str(case))
    t0 = float(frames[0].stem)
    table = []
    for f in frames:
        table.append((float(f.stem) - t0, runs_of(f, col)))
    above = 0
    for k, (t, runs) in enumerate(table):
        first = runs[0][0] if runs else None
        flag = ""
        if first is not None and first < rest - 1:
            flag = "  <-- ABOVE REST"
            above += 1
        print("%03d %6.3f %s%s" % (k, t, " ".join("%d-%d" % r for r in runs), flag))
    # A blip: a frame whose top card is elsewhere while the frames before and after agree (a jump of one frame or two).
    firsts = [r[0][0] if r else None for _, r in table]
    blips = [k for k in range(1, len(firsts) - 1) if firsts[k] != firsts[k - 1] and firsts[k - 1] == firsts[k + 1]]
    blips2 = [k for k in range(1, len(firsts) - 2) if firsts[k] == firsts[k + 1] and firsts[k] != firsts[k - 1] and firsts[k - 1] == firsts[k + 2]]
    print("blips (1 frame): %s  (2 frames): %s" % (blips, blips2))
    print("frames: %d  span: %.2fs  fps: %.1f  rest y: %d  frames above rest: %d" % (
        len(table), table[-1][0], (len(table) - 1) / max(table[-1][0], 1e-9), rest, above))


main()
