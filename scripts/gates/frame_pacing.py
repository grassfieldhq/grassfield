#!/usr/bin/env python3
"""Gate P3: frame pacing of one shell surface, from presentation timestamps (the gate) or the shell's render time (a proxy).

  frame_pacing.py --presented RECORD --surface NAME [--marks FILE] [--session real|nested] [--refresh-hz HZ]
                  [--tolerance 1.2] [--min-share 95] [--min-frames 100]
  frame_pacing.py --surface NAME LOG [--threshold-ms 16.7] [--min-share 95] [--min-frames 100]      (the proxy)
  frame_pacing.py --selftest

PRESENTED (the gate, ADR-0006 as amended on 2026-11-19: refresh-relative). RECORD is the output of the probe
tests/tools/presentprobe: one line per content update of a surface that commits on every frame callback, with the time the
compositor presented it (wp_presentation feedback), the output's refresh period and its vblank counter (MSC). Every surface
of an output is presented in the same frame, so a frame the compositor misses while the shell animates is missed by the
probe too. The refresh period P is the one the feedback reports (the median of its non-zero values), else the output's mode
(`# output` line), else --refresh-hz; without any of them the verdict is INCONCLUSIVE (a refresh-relative gate cannot guess
the rate: a compositor stuck at half rate would look perfect against its own median).
For each pair of consecutive presented frames in a window, the interval D:
  on time   D <= tolerance x P (default 1.2: 20.0 ms at 60 Hz, 10.0 at 120, 8.3 at 144, 5.0 at 240; a missed frame is 2 P)
  missed    the vblanks skipped: MSC delta - 1 when the compositor counts vblanks, else round(D / P) - 1
Windows: --marks FILE holds "<label> <realtime_ns> <window_ms>" lines (the moment the harness asked for an animation and how
long it is judged); the record's `# offset_ns` (CLOCK_REALTIME minus the presentation clock) places them; an interval counts
when both of its frames are in the window. Without --marks every interval of the record counts.
Printed: per label and for all, the intervals, the share on time, p50/p95/p99 interval, the worst stall (ms and periods), the
missed-frame count, the discarded updates. Verdict (all windows together): fewer than --min-frames intervals INCONCLUSIVE
(exit 2); on the owner's real session (--session real) PASS at >= --min-share % (exit 0), FAIL below (exit 1); in the nested
session (the default) the output is paced by the nested compositor's own timer: "NESTED, NOT VERIFIED" (exit 2) or
"NESTED FAIL (indicative)" (exit 1). Only --session real can PASS.

PROXY (the fallback where no probe can run). Each "frame rendered in R ms" line of the shell's render-timing log
(QSG_RENDER_TIMING, GRASSFIELD_RENDER_TIMING=1) is one frame; R < threshold counts as within the budget. It never prints
PASS: below --min-share "PROXY FAIL" (exit 1, indicative), at or above "PROXY, NOT VERIFIED" (exit 2), fewer than
--min-frames INCONCLUSIVE (exit 2).

Standard library only (python3 -I).
"""
import argparse
import re
import statistics
import sys

FRAME = re.compile(r"frame rendered in (\d+)\s*ms")
STANDARD_HZ = (60, 75, 90, 100, 120, 144, 165, 175, 240, 360)


# --- the proxy: the shell's render-thread time --------------------------------------------------------------------------------
def frames(text):
    return [int(m) for m in FRAME.findall(text)]


def percentile(sorted_values, q):
    if not sorted_values:
        return 0
    i = min(len(sorted_values) - 1, max(0, int(round(q * (len(sorted_values) - 1)))))
    return sorted_values[i]


def verdict(values, threshold_ms, min_share, min_frames):
    """-> (exit code, share in %, text)"""
    n = len(values)
    if n == 0:
        return 2, 0.0, "no frame in the log (was the shell started with --render-timing?)"
    within = sum(1 for v in values if v < threshold_ms)
    share = 100.0 * within / n
    s = sorted(values)
    stats = f"{within}/{n} frames < {threshold_ms:g} ms = {share:.1f} %, p50 {percentile(s, .5)} ms, p95 {percentile(s, .95)} ms, p99 {percentile(s, .99)} ms, slowest {s[-1]} ms"
    if n < min_frames:
        return 2, share, f"INCONCLUSIVE: only {n} frames (minimum {min_frames}); {stats}"
    # P3 is defined on wp_presentation timestamps (ADR-0006). The shell's render-thread time is a proxy: it can say "clearly
    # not met", never "met".
    if share >= min_share:
        return 2, share, (f"PROXY, NOT VERIFIED (not a pass: the gate needs wp_presentation timestamps, ADR-0006): shell render-thread "
                          f"time meets the share, {stats} (needs >= {min_share:g} %)")
    return 1, share, f"PROXY FAIL (indicative: shell render-thread time, not wp_presentation): {stats} (needs >= {min_share:g} %)"


# --- the gate: presentation timestamps of tests/tools/presentprobe -------------------------------------------------------------
class Record:
    def __init__(self):
        self.clock = None
        self.offsets = []          # CLOCK_REALTIME - presentation clock, ns (start, end)
        self.output_mhz = []       # refresh of the outputs the surface entered, mHz
        self.output_names = []
        self.frames = []           # (commit, present_ns, refresh_ns, msc, flags, commit_ns, lag_ms), in presentation order
        self.discarded = []        # commit numbers
        self.surface = None


def parse_record(text):
    rec = Record()
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        try:
            if parts[0] == "p" and len(parts) >= 6:
                extra = (int(parts[6]), int(parts[7])) if len(parts) >= 8 else (0, -1)
                rec.frames.append((int(parts[1]), int(parts[2]), int(parts[3]), int(parts[4]), int(parts[5])) + extra)
            elif parts[0] == "d" and len(parts) >= 2:
                rec.discarded.append(int(parts[1]))
            elif parts[0] == "#" and len(parts) >= 3:
                key = parts[1]
                if key == "clock":
                    rec.clock = int(parts[2])
                elif key in ("offset_ns", "offset_end_ns"):
                    rec.offsets.append(int(parts[2]))
                elif key == "output" and len(parts) >= 4:
                    rec.output_names.append(parts[2])
                    rec.output_mhz.append(int(parts[3]))
                elif key == "surface":
                    rec.surface = " ".join(parts[2:])
        except ValueError:
            continue
    rec.frames.sort(key=lambda f: f[1])
    return rec


def read_marks(text):
    """(label, realtime_ns, window_ns) per line "<label> <realtime_ns> <window_ms>"; other lines are ignored."""
    out = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and not line.startswith("#"):
            try:
                out.append((parts[0], int(parts[1]), int(float(parts[2]) * 1e6)))
            except ValueError:
                continue
    return out


def refresh_period(rec, override_hz=None):
    """-> (period in ns, where it came from) or (None, reason)."""
    if override_hz:
        return 1e9 / override_hz, f"--refresh-hz {override_hz:g}"
    reported = [f[2] for f in rec.frames if f[2] > 0]
    if reported:
        return statistics.median(reported), "presentation feedback"
    modes = [m for m in rec.output_mhz if m > 0]
    if modes:
        return 1e12 / modes[-1], f"output mode ({rec.output_names[-1] if rec.output_names else '?'})"
    return None, "no refresh period in the feedback or the output mode (variable refresh?): give --refresh-hz"


def nominal(hz):
    near = min(STANDARD_HZ, key=lambda s: abs(s - hz))
    return f"{hz:.2f} Hz" + (f" (~{near} Hz)" if abs(near - hz) / near < 0.02 and abs(near - hz) >= 0.005 else "")


def probe_lag_limit(rec, period):
    """-> (baseline lag in ms, limit in ms): a frame whose callback the probe handled more than max(2 ms, half a period) later
    than the record's median lag was late because of the probe's own scheduling. The median absorbs the compositor's own
    convention for the callback's timestamp (Hyprland stamps the send, Weston the frame time, a repaint window earlier)."""
    lags = sorted(f[6] for f in rec.frames if f[6] >= 0)
    if not lags:
        return None, None
    base = lags[len(lags) // 2]
    return base, base + max(2.0, 0.5 * period / 1e6)


def intervals(rec, period, windows=None, tolerance=1.2):
    """[(label, interval_ns, missed, probe_late)] of consecutive presented frames; with windows [(label, start_ns, end_ns)] in
    the presentation clock, only the pairs whose two frames are inside the same window. probe_late: a late interval whose second
    frame came from a callback the probe itself handled late (probe_lag_limit)."""
    out = []
    fr = rec.frames
    _base, limit = probe_lag_limit(rec, period)
    for a, b in zip(fr, fr[1:]):
        d = b[1] - a[1]
        if d <= 0:
            continue
        msc_ok = a[3] > 0 and b[3] > a[3]
        slots = (b[3] - a[3]) if msc_ok else max(1, int(round(d / period)))
        probe_late = d > tolerance * period and limit is not None and b[6] >= 0 and b[6] > limit
        if windows is None:
            out.append(("all", d, slots - 1, probe_late))
            continue
        for label, lo, hi in windows:
            if lo <= a[1] and b[1] <= hi:
                out.append((label, d, slots - 1, probe_late))
                break
    return out


def summary(ivals, period, tolerance):
    """Statistics of the intervals the compositor is answerable for; the probe's own late frames are counted apart."""
    probe_late = sum(1 for i in ivals if i[3])
    ivals = [i for i in ivals if not i[3]]
    n = len(ivals)
    if n == 0:
        return None
    ds = sorted(d for _l, d, _m, _p in ivals)
    on_time = sum(1 for d in ds if d <= tolerance * period)
    worst = ds[-1]
    return {
        "count": n,
        "on_time": on_time,
        "share": 100.0 * on_time / n,
        "p50_ms": percentile(ds, .5) / 1e6,
        "p95_ms": percentile(ds, .95) / 1e6,
        "p99_ms": percentile(ds, .99) / 1e6,
        "worst_ms": worst / 1e6,
        "worst_periods": worst / period,
        "missed": sum(m for _l, _d, m, _p in ivals),
        "probe_late": probe_late,
    }


def describe(s, tolerance, period):
    return (f"{s['on_time']}/{s['count']} frames on time (<= {tolerance:g} periods = {tolerance * period / 1e6:.2f} ms) = {s['share']:.1f} %, "
            f"p50 {s['p50_ms']:.2f} ms, p95 {s['p95_ms']:.2f} ms, p99 {s['p99_ms']:.2f} ms, worst stall {s['worst_ms']:.2f} ms "
            f"({s['worst_periods']:.1f} periods), {s['missed']} missed"
            + (f"; {s['probe_late']} late frame{'s' if s['probe_late'] != 1 else ''} of the probe's own left out" if s["probe_late"] else ""))


def judge_presented(rec, marks=None, session="nested", refresh_hz=None, tolerance=1.2, min_share=95.0, min_frames=100):
    """-> (exit code, summary dict or None, [lines])"""
    lines = []
    if not rec.frames:
        return 2, None, ["INCONCLUSIVE: no presented frame in the record (did the probe connect and draw?)"]
    period, source = refresh_period(rec, refresh_hz)
    if period is None:
        return 2, None, [f"INCONCLUSIVE: {source}"]
    windows = None
    if marks is not None:
        if not rec.offsets:
            return 2, None, ["INCONCLUSIVE: marks given but the record has no '# offset_ns' line to place them"]
        offset = sum(rec.offsets) / len(rec.offsets)
        windows = [(label, t - offset, t - offset + w) for label, t, w in marks]
        if not windows:
            return 2, None, ["INCONCLUSIVE: no mark in the marks file"]
    ivals = intervals(rec, period, windows, tolerance)
    lines.append(f"refresh {nominal(1e9 / period)}, period {period / 1e6:.3f} ms from the {source}; "
                 f"{len(rec.frames)} presented, {len(rec.discarded)} discarded updates in the record")
    if windows is not None:
        for label in dict.fromkeys(label for label, _lo, _hi in windows):
            s = summary([i for i in ivals if i[0] == label], period, tolerance)
            n = sum(1 for w in windows if w[0] == label)
            lines.append(f"  {label} ({n} window{'s' if n != 1 else ''}): " + (describe(s, tolerance, period) if s else "no frame"))
    s = summary(ivals, period, tolerance)
    if s is None:
        return 2, None, lines + ["INCONCLUSIVE: no frame interval in the windows"]
    stats = describe(s, tolerance, period)
    need = f"(needs >= {min_share:g} % and {min_frames} frames)"
    if s["count"] < min_frames:
        return 2, s, lines + [f"INCONCLUSIVE: only {s['count']} frame intervals (minimum {min_frames}); {stats}"]
    # The probe must keep up for its record to speak for the compositor: when its own scheduling made more than 5 % of the
    # frames late (a loaded CPU), nothing is judged.
    if s["probe_late"] * 20 > s["count"] + s["probe_late"]:
        base, limit = probe_lag_limit(rec, period)
        return 2, s, lines + [f"INCONCLUSIVE: the probe itself was late on {s['probe_late']} of {s['count'] + s['probe_late']} frames "
                              f"(it handled the frame callback more than {limit - base:.1f} ms after the usual {base} ms: a loaded CPU); {stats}"]
    meets = s["share"] >= min_share
    if session == "real":
        return (0, s, lines + [f"PASS: {stats} {need}"]) if meets else (1, s, lines + [f"FAIL: {stats} {need}"])
    if meets:
        return 2, s, lines + [f"NESTED, NOT VERIFIED (not a pass: P3 is judged on the owner's real session): {stats} {need}"]
    return 1, s, lines + [f"NESTED FAIL (indicative: the nested output is paced by its host): {stats} {need}"]


# --- selftest ----------------------------------------------------------------------------------------------------------------
def synth(period_ns, gaps, refresh=True, msc=False, start=1_000_000_000, header=True, discarded=(), lags=None):
    """A probe record: one frame per entry of gaps (in periods after the previous frame); lags: the probe's callback lag in ms
    per frame (the 8-field lines of the probe), else the older 6-field lines."""
    lines = ["# presentprobe 1", "# clock 1", "# offset_ns 5000000000"] if header else []
    t, seq = start, 100
    for i, g in enumerate(gaps):
        t += int(round(g * period_ns))
        seq += int(round(g))
        extra = f" {t - period_ns} {lags[i]}" if lags is not None else ""
        lines.append(f"p {i} {t} {period_ns if refresh else 0} {seq if msc else 0} {7 if msc else 0}{extra}")
    lines += [f"d {c}" for c in discarded]
    return "\n".join(lines) + "\n"


def selftest():
    fails = []

    def expect(name, got, want):
        if got != want:
            fails.append(f"{name}: got {got!r}, want {want!r}")

    # The proxy, unchanged: never a pass.
    log = "".join(f"2026-10-23 10:00:{i % 60:02d}.000 INFO qml: frame rendered in {ms} ms, sync=0, render=1, swap=2\n"
                  for i, ms in enumerate([8] * 96 + [30] * 4))
    expect("proxy: frames parsed", len(frames(log)), 100)
    expect("proxy: 96 % is only a proxy, never a pass", verdict(frames(log), 16.7, 95, 100)[0], 2)
    expect("proxy: 96 % says NOT VERIFIED", "NOT VERIFIED" in verdict(frames(log), 16.7, 95, 100)[2] and "PASS:" not in verdict(frames(log), 16.7, 95, 100)[2], True)
    log2 = "".join(f"frame rendered in {ms} ms\n" for ms in [8] * 90 + [30] * 10)
    expect("proxy: 90 % is a proxy fail", verdict(frames(log2), 16.7, 95, 100)[0], 1)
    expect("proxy: few frames inconclusive", verdict([8] * 10, 16.7, 95, 100)[0], 2)
    expect("proxy: no frames inconclusive", verdict([], 16.7, 95, 100)[0], 2)
    expect("proxy: 16 ms is within 16.7", verdict([16] * 100, 16.7, 95, 100)[2].startswith("PROXY, NOT VERIFIED"), True)
    expect("proxy: 17 ms is not", verdict([17] * 100, 16.7, 95, 100)[0], 1)
    expect("proxy: exactly at the share", verdict([8] * 95 + [30] * 5, 16.7, 95, 100)[0], 2)

    # Presented frames: the verdict is relative to the output's own refresh period.
    for hz in (60, 120, 144, 240):
        p = int(1e9 / hz)
        clean = parse_record(synth(p, [1] * 200))
        code, s, _ = judge_presented(clean, session="real")
        expect(f"{hz} Hz, every vblank: PASS on the real session", (code, s["share"], s["missed"]), (0, 100.0, 0))
        expect(f"{hz} Hz, every vblank: nested is never a pass", judge_presented(clean, session="nested")[0], 2)
        # 6 % of the intervals one vblank late: 94 % on time, below the gate.
        late = parse_record(synth(p, [1] * 188 + [2] * 12))
        code, s, _ = judge_presented(late, session="real")
        expect(f"{hz} Hz, 6 % missed: FAIL with 12 missed", (code, s["missed"], round(s["share"], 1)), (1, 12, 94.0))
        expect(f"{hz} Hz, 6 % missed: nested fail is indicative", judge_presented(late)[0], 1)
    # Half rate: every frame on every second vblank. 0 % on time; the rate is the feedback's, not the median interval's.
    half = parse_record(synth(int(1e9 / 120), [2] * 201))
    code, s, lines = judge_presented(half, session="real")
    expect("half rate at 120 Hz: FAIL, 0 %, 200 missed", (code, s["share"], s["missed"]), (1, 0.0, 200))
    expect("half rate: the period is the feedback's 8.333 ms", "period 8.333 ms" in lines[0], True)
    # The 1.2-period tolerance: 1.19 periods on time, 1.21 not.
    edge = parse_record(synth(int(1e9 / 60), [1.19] * 100 + [1.21] * 5))
    expect("1.19 periods on time, 1.21 late", judge_presented(edge, session="real")[1]["on_time"], 99)
    # The vblank counter counts what was skipped when the compositor reports it (MSC), the rounding otherwise.
    msc = parse_record(synth(int(1e9 / 144), [1] * 150 + [3] + [1] * 50, msc=True))
    expect("MSC: one interval of 3 vblanks = 2 missed", judge_presented(msc, session="real")[1]["missed"], 2)
    # No refresh in the feedback: the output's mode; neither: INCONCLUSIVE unless --refresh-hz.
    norefresh = synth(int(1e9 / 60), [1] * 150, refresh=False)
    expect("no refresh anywhere: INCONCLUSIVE", judge_presented(parse_record(norefresh), session="real")[0], 2)
    expect("refresh from the output mode", judge_presented(parse_record(norefresh + "# output DP-1 60000 1920x1080\n"), session="real")[0], 0)
    expect("refresh from --refresh-hz", judge_presented(parse_record(norefresh), session="real", refresh_hz=60)[0], 0)
    # The same 120 Hz stream judged as if it were 60 Hz: twice the budget. The threshold follows the rate.
    st120 = parse_record(synth(int(1e9 / 120), [1] * 180 + [1.8] * 20))
    expect("120 Hz with 1.8-period gaps: 90 % at its own rate", round(judge_presented(st120, session="real")[1]["share"]), 90)
    expect("the same at a forced 60 Hz: 100 %", judge_presented(st120, session="real", refresh_hz=60)[1]["share"], 100.0)
    # Too few intervals, no frame at all, discarded updates are counted.
    expect("few frames inconclusive", judge_presented(parse_record(synth(int(1e9 / 60), [1] * 50)), session="real")[0], 2)
    expect("no frame inconclusive", judge_presented(parse_record("# presentprobe 1\n"), session="real")[0], 2)
    d = judge_presented(parse_record(synth(int(1e9 / 60), [1] * 150, discarded=(3, 9))), session="real")[2][0]
    expect("discarded updates reported", "2 discarded" in d, True)
    # Windows from marks: realtime = presentation clock + offset (5 s in synth). Frames every period from t=1 s; a stall of 10
    # periods at frame 100. A window around the stall judges the stall; a window elsewhere does not see it.
    p = int(1e9 / 60)
    rec = parse_record(synth(p, [1] * 100 + [10] + [1] * 200))
    t_stall = 1_000_000_000 + 100 * p + 5_000_000_000
    at_stall = read_marks(f"open {t_stall - 100 * 1000000} 400\n")
    code, s, lines = judge_presented(rec, at_stall, session="real", min_frames=10)
    expect("window over the stall: 9 missed, FAIL", (code, s["missed"]), (1, 9))
    elsewhere = read_marks(f"close {t_stall + 1500 * 1000000} 600\n# a comment\n")
    code, s, lines = judge_presented(rec, elsewhere, session="real", min_frames=10)
    expect("window away from the stall: PASS", (code, s["missed"]), (0, 0))
    expect("per-label line", any(line.startswith("  close (1 window)") for line in lines), True)
    # The probe's own lateness: a late frame whose callback the probe handled far later than usual is left out (and too many
    # of them make the run INCONCLUSIVE); the same late frame with the usual lag is the compositor's.
    p = int(1e9 / 60)
    gaps = [1] * 150 + [2] * 3 + [1] * 50
    own = parse_record(synth(p, gaps, lags=[1] * 150 + [30] * 3 + [1] * 50))
    code, s, lines = judge_presented(own, session="real")
    expect("probe-late frames left out: PASS, 0 missed, 3 apart", (code, s["missed"], s["probe_late"], s["count"]), (0, 0, 3, 199))
    theirs = parse_record(synth(p, gaps, lags=[1] * len(gaps)))
    expect("the same frames at the usual lag are missed", judge_presented(theirs, session="real")[1]["missed"], 3)
    slow = parse_record(synth(p, [1] * 100 + [2] * 10, lags=[1] * 100 + [40] * 10))
    expect("the probe late on > 5 %: INCONCLUSIVE", judge_presented(slow, session="real")[0], 2)
    # Weston stamps the callback with the frame time: every lag is about 10 ms, the baseline absorbs it.
    weston = parse_record(synth(p, gaps, lags=[10] * len(gaps)))
    expect("a constant 10 ms lag is the compositor's convention", judge_presented(weston, session="real")[1]["probe_late"], 0)
    expect("marks without an offset: INCONCLUSIVE",
           judge_presented(parse_record(synth(p, [1] * 150, header=False)), at_stall, session="real")[0], 2)
    if fails:
        print("\n".join("FAIL: " + f for f in fails))
        return 1
    print("frame_pacing selftest: PASS (proxy and presented-frame cases)")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("log", nargs="?", help="the shell's render-timing log (proxy mode)")
    ap.add_argument("--surface")
    ap.add_argument("--presented", metavar="RECORD", help="a tests/tools/presentprobe record (the gate)")
    ap.add_argument("--marks", metavar="FILE", help="'<label> <realtime_ns> <window_ms>' lines: the windows judged")
    ap.add_argument("--session", choices=("real", "nested"), default="nested")
    ap.add_argument("--refresh-hz", type=float)
    ap.add_argument("--tolerance", type=float, default=1.2, help="on time: an interval of at most this many refresh periods")
    ap.add_argument("--threshold-ms", type=float, default=16.7, help="proxy mode: a render time below this is within the budget")
    ap.add_argument("--min-share", type=float, default=95.0)
    ap.add_argument("--min-frames", type=int, default=100)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    if not args.surface or not (args.log or args.presented) or (args.log and args.presented):
        ap.error("--surface and either LOG (proxy) or --presented RECORD are required")
    path = args.presented or args.log
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        marks = None
        if args.marks:
            with open(args.marks, encoding="utf-8", errors="replace") as f:
                marks = read_marks(f.read())
    except OSError as e:
        print(f"P3 {args.surface}: cannot read: {e}", file=sys.stderr)
        return 2
    if args.presented:
        code, _s, lines = judge_presented(parse_record(text), marks, args.session, args.refresh_hz, args.tolerance, args.min_share,
                                          args.min_frames)
        for line in lines[:-1]:
            print(f"P3 {args.surface}: {line}" if not line.startswith("  ") else f"P3 {args.surface}:{line}")
        print(f"P3 {args.surface} [{args.session}, wp_presentation]: {lines[-1]}")
        return code
    code, _share, out = verdict(frames(text), args.threshold_ms, args.min_share, args.min_frames)
    print(f"P3 {args.surface}: {out}")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
