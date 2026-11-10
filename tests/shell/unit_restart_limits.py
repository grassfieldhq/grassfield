#!/usr/bin/env python3
"""The lifetime model of tests/shell/unit_restart_limits.sh (ADR-0041 step 1a): exit 0 when a loop of one crash every
LIFETIME seconds (default 10) ends for the unit file given, exit 1 otherwise.

A start limit counts starts within an interval: with a lifetime L per cycle and RestartSec R, the (Burst + 1)-th start,
the one systemd refuses, happens Burst x (R + L) after the first, so the limit ends the loop only when
Burst x (R + L) <= Interval. The bound is always computed and printed. A unit that names grassfield-shell-failed.service in
OnFailure= also ends a loop of any pace at the counter's threshold, which passes it when the bound does not hold.
Times are systemd's: a bare number is seconds, or a number with us, ms, s, sec, min, h, d (several may follow each other:
"1min 30s"). Standard library only.
"""
import re
import sys

LIFETIME = 10
UNITS = {"us": 1e-6, "usec": 1e-6, "ms": 1e-3, "msec": 1e-3, "s": 1.0, "sec": 1.0, "second": 1.0, "seconds": 1.0,
         "m": 60.0, "min": 60.0, "minute": 60.0, "minutes": 60.0, "h": 3600.0, "hr": 3600.0, "hour": 3600.0, "hours": 3600.0,
         "d": 86400.0, "day": 86400.0, "days": 86400.0}


def seconds(value):
    """systemd's timespan in seconds, or None when it is not one."""
    parts = re.findall(r"(\d+(?:\.\d+)?)\s*([a-z]*)", value.strip())
    if not parts or "".join(f"{n}{u}" for n, u in parts).replace(" ", "") != re.sub(r"\s+", "", value.strip()):
        return None
    total = 0.0
    for n, u in parts:
        if u not in UNITS and u != "":
            return None
        total += float(n) * UNITS.get(u, 1.0)
    return total


def main(argv):
    if len(argv) != 2:
        print("usage: unit_restart_limits.py UNIT_FILE", file=sys.stderr)
        return 2
    text = open(argv[1], encoding="utf-8").read()

    def num(key, default=None):
        m = re.search(r"^" + key + r"=(.+)$", text, re.M)
        if not m:
            return default
        v = seconds(m[1])
        return default if v is None else v

    interval, sec = num("StartLimitIntervalSec"), num("RestartSec", 1.0)
    burst = num("StartLimitBurst")
    if not interval or not burst:
        return 1
    bound = burst * (sec + LIFETIME)
    holds = bound <= interval
    print(f"{burst:g} x ({sec:g} + {LIFETIME}) = {bound:g} s {'<=' if holds else '>'} {interval:g} s: the start limit "
          f"{'ends' if holds else 'does not end'} a {LIFETIME} s loop")
    on_failure = re.search(r"^OnFailure=(.*)$", text, re.M)
    counter = bool(on_failure and "grassfield-shell-failed.service" in on_failure[1].split())
    return 0 if holds or counter else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
