#!/usr/bin/env bash
# grassfield-energy (ADR-0048): apps the person cannot see get less CPU and I/O, the app in front never. The helper runs here
# against a fake /proc (GRASSFIELD_PROC_ROOT: cgroup, comm, fd links, fdinfo) and a fake cgroup tree (GRASSFIELD_CGROUP_ROOT:
# cgroup.procs, cpu.stat, cpu.weight, cpu.idle, cpu.uclamp.max), with a systemctl stub on PATH that logs what it is asked and
# a fixed clock (GRASSFIELD_ENERGY_NOW). The seams are dev plumbing (honoured only with GRASSFIELD_DEV=1 and no
# GRASSFIELD_SESSION=1), so the runs below set GRASSFIELD_DEV=1. Nothing here talks to a session or a user manager. The pure decisions (ladder, merge,
# scope contract, quietness, "no stronger", planning) are checked on the module itself, the commands through the CLI.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/app-energy.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
helper=$root/packaging/bin/grassfield-energy

mkdir -p "$tmp/bin"
cat >"$tmp/bin/systemctl" <<'SH'
#!/bin/sh
echo "systemctl $*" >>"$FAKE_LOG"
exit "${FAKE_SYSTEMCTL_EXIT:-0}"
SH
chmod +x "$tmp/bin/systemctl"

cat >"$tmp/test.py" <<'PY'
import importlib.machinery, importlib.util, json, os, shutil, subprocess, sys
sys.dont_write_bytecode = True  # no __pycache__ in packaging/bin (it would be packaged)
helper, tmp = sys.argv[1:3]
PROC, CG = tmp + "/proc", tmp + "/cg"
os.environ["GRASSFIELD_DEV"] = "1"
os.environ.pop("GRASSFIELD_SESSION", None)
os.environ["GRASSFIELD_PROC_ROOT"] = PROC
os.environ["GRASSFIELD_CGROUP_ROOT"] = CG
loader = importlib.machinery.SourceFileLoader("energy", helper)
spec = importlib.util.spec_from_loader("energy", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
uid = os.getuid()
SLICE = "/user.slice/user-%d.slice/user@%d.service/app.slice/app-graphical.slice/" % (uid, uid)
LOG = tmp + "/systemctl.log"
STATE = tmp + "/run/grassfield/app-energy.json"
failures = []

def check(desc, ok):
    print(("PASS: " if ok else "FAIL: ") + desc)
    if not ok:
        failures.append(desc)

# ---- pure decisions ----
check("hidden on battery: 20/30, uclamp 40, after 30 s", m.rung("hidden", True) == (20, 30, 40, 30))
check("occluded on battery: 40/60, uclamp 60, after 10 s", m.rung("occluded", True) == (40, 60, 60, 10))
check("on mains: nothing is ever limited", m.rung("occluded", False) is None and m.rung("hidden", False) is None)
check("focused and visible are never limited, on battery or not", all(m.rung(s, b) is None for s in ("focused", "visible") for b in (True, False)))
check("unknown state: nothing", m.rung("bogus", True) is None)
check("an app is as awake as its most awake window", m.most_awake(["hidden", "visible", "occluded"]) == "visible" and m.most_awake(["hidden", "focused"]) == "focused")
check("no window state: hidden", m.most_awake([]) == "hidden")
check("app scope under app-graphical.slice", m.app_unit(SLICE + "app-Hyprland-foot-d359984a.scope", uid) == "app-Hyprland-foot-d359984a.scope")
check("a process in a sub-cgroup of a scope is not one", m.app_unit(SLICE + "app-Hyprland-foot-1.scope/sub", uid) == "")
check("flatpak scope directly under app.slice is protected", m.app_unit("/user.slice/user-%d.slice/user@%d.service/app.slice/app-flatpak-org.x-12.scope" % (uid, uid), uid) == "")
check("another user's app is not one", m.app_unit(SLICE.replace(str(uid), str(uid + 1)) + "app-x-1.scope", uid) == "")
check("session services are not apps", m.app_unit("/user.slice/user-%d.slice/user@%d.service/session.slice/pipewire.service" % (uid, uid), uid) == "")
check("a service in app-graphical.slice is not an app scope", m.app_unit(SLICE + "app-foo@x.service", uid) == "")
check("system slice is not an app", m.app_unit("/system.slice/sshd.service", uid) == "")
check("a unit name with a slash or option shape is refused", m.app_unit(SLICE + "--force.scope", uid) == "" and m.app_unit(SLICE + "app-$(x).scope", uid) == "")
check("quiet below 0.5 % of a core", m.quiet(0, 40_000, 10) and not m.quiet(0, 60_000, 10))
check("no window, no judgement of quietness", not m.quiet(0, 0, 0))
check("weaker limits held while going to a stronger rung are kept", m.no_stronger({"CPUWeight": 40, "IOWeight": 60}, 60, m.rung("hidden", True)))
check("stronger limits held while going to a milder rung are not", not m.no_stronger({"CPUWeight": 20, "IOWeight": 30}, None, m.rung("occluded", True)))
check("a uclamp held where the rung has none is stronger", not m.no_stronger({"CPUWeight": 40, "IOWeight": 60}, 40, m.rung("hidden", False)))
check("nothing held is never stronger", m.no_stronger({}, None, None))
check("session processes by name", m.session_comm("Hyprland") and m.session_comm("xdg-desktop-por") and m.session_comm("fcitx5") and m.session_comm("grassfield-shel") and not m.session_comm("firefox") and not m.session_comm("grassfield-file"))
check("windows JSON: pids and states only", m.parse_windows('{"12": "hidden", "x": "hidden", "13": "asleep", "-1": "visible", "14": "visible"}') == {12: "hidden", 14: "visible"})
check("windows JSON: garbage is refused", m.parse_windows("[1,2]") is None and m.parse_windows("{") is None)
check("pid lists: digits only", m.parse_pids("1, 2,x,,-3,4") == [1, 2, 4])

def no_claims(unit, r, now):
    return []

recs = {}
acts, nxt = m.plan(recs, {"app-a-1.scope": "hidden"}, 100.0, True, no_claims)
check("plan: a newly hidden app waits its 30 s", acts == [] and recs["app-a-1.scope"]["waiting"] == 30 and nxt == 10)
acts, nxt = m.plan(recs, {"app-a-1.scope": "hidden"}, 131.0, True, no_claims)
check("plan: hidden for 30 s on battery: 20/30 and uclamp 40", acts == [("set", "app-a-1.scope", {"CPUWeight": 20, "IOWeight": 30}, 40)] and nxt == 60)
recs["app-a-1.scope"]["applied"] = {"CPUWeight": 20, "IOWeight": 30}; recs["app-a-1.scope"]["uclamp"] = 40
acts, _ = m.plan(recs, {"app-a-1.scope": "focused"}, 132.0, True, no_claims)
check("plan: focused again: released at once", acts == [("release", "app-a-1.scope")])
recs["app-a-1.scope"]["applied"] = {"CPUWeight": 20, "IOWeight": 30}; recs["app-a-1.scope"]["uclamp"] = 40
recs["app-a-1.scope"]["state"] = "hidden"
acts, _ = m.plan(recs, {"app-a-1.scope": "occluded"}, 133.0, True, no_claims)
check("plan: hidden to occluded: the stronger limit is lifted at once, not kept while waiting", acts == [("release", "app-a-1.scope")])
recs = {"app-b-1.scope": {"state": "occluded", "since": 0.0, "applied": {"CPUWeight": 40, "IOWeight": 60}, "uclamp": 60, "mark": None, "busy": True}}
acts, _ = m.plan(recs, {"app-b-1.scope": "hidden"}, 100.0, True, no_claims)
check("plan: occluded to hidden: the milder limit is kept while the 30 s run", acts == [] and recs["app-b-1.scope"]["waiting"] == 30)
acts, _ = m.plan(recs, {"app-b-1.scope": "hidden"}, 130.0, True, lambda u, r, n: ["media"])
check("plan: a claim lifts a held limit", acts == [("release", "app-b-1.scope")] and recs["app-b-1.scope"]["reasons"] == ["media"])
recs["app-b-1.scope"]["applied"] = {"CPUWeight": 40, "IOWeight": 60}
acts, _ = m.plan(recs, {"app-b-1.scope": "hidden"}, 131.0, True, lambda u, r, n: ["foreign"])
check("plan: a weight set elsewhere releases the rest (IOWeight, uclamp)", acts == [("release", "app-b-1.scope")])
recs["app-b-1.scope"]["applied"] = {}; recs["app-b-1.scope"]["uclamp"] = None
acts, _ = m.plan(recs, {}, 140.0, True, no_claims)
check("plan: an app with no window left is forgotten", recs == {} and acts == [])
recs = {"app-c-1.scope": {"state": "hidden", "since": 0.0, "applied": {"CPUWeight": 20, "IOWeight": 30}, "uclamp": 40, "mark": None, "busy": True}}
acts, _ = m.plan(recs, {}, 140.0, True, no_claims)
check("plan: a limited app whose windows are gone is released", acts == [("release", "app-c-1.scope")])
recs = {}
m.plan(recs, {"app-d-1.scope": "occluded"}, 0.0, False, no_claims)
acts, nxt = m.plan(recs, {"app-d-1.scope": "occluded"}, 10.0, False, no_claims)
check("plan: occluded 10 s on mains: nothing, and no run asked", acts == [] and nxt == 0)
recs = {"app-e-1.scope": {"state": "hidden", "since": 0.0, "applied": {"CPUWeight": 20, "IOWeight": 30}, "uclamp": 40, "mark": None, "busy": True}}
acts, _ = m.plan(recs, {"app-e-1.scope": "hidden"}, 100.0, False, no_claims)
check("plan: on mains a held limit is lifted", acts == [("release", "app-e-1.scope")])

# ---- the fake system ----
def reset_fs():
    for d in (PROC, CG, tmp + "/run"):
        shutil.rmtree(d, ignore_errors=True)
    open(LOG, "w").close()

def proc(pid, cgroup, comm="app", fds=None, fdinfo=None):
    d = "%s/%d" % (PROC, pid)
    os.makedirs(d + "/fd", exist_ok=True); os.makedirs(d + "/fdinfo", exist_ok=True)
    open(d + "/cgroup", "w").write("0::%s\n" % cgroup)
    open(d + "/comm", "w").write(comm + "\n")
    for fd, target in (fds or {}).items():
        os.symlink(target, "%s/fd/%s" % (d, fd))
    for fd, text in (fdinfo or {}).items():
        open("%s/fdinfo/%s" % (d, fd), "w").write(text)

def scope(name, pids, usec=0, weight=None, idle=None, uclamp=None):
    d = CG + SLICE + name
    os.makedirs(d, exist_ok=True)
    open(d + "/cgroup.procs", "w").write("".join("%d\n" % p for p in pids))
    open(d + "/cpu.stat", "w").write("usage_usec %d\nuser_usec 0\n" % usec)
    if weight is not None:
        open(d + "/cpu.weight", "w").write("%s\n" % weight)
    if idle is not None:
        open(d + "/cpu.idle", "w").write("%s\n" % idle)
    if uclamp is not None:
        open(d + "/cpu.uclamp.max", "w").write(uclamp + "\n")
    return d

def set_usec(name, usec):
    open(CG + SLICE + name + "/cpu.stat", "w").write("usage_usec %d\n" % usec)

def run(args, now, env=None):
    e = dict(os.environ, PATH=tmp + "/bin:" + os.environ["PATH"], FAKE_LOG=LOG, GRASSFIELD_ENERGY_NOW=str(now),
             XDG_RUNTIME_DIR=tmp + "/run")
    e.update(env or {})
    p = subprocess.run([sys.executable, "-I", helper] + args, env=e, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()

def log():
    return [l for l in open(LOG).read().splitlines() if l]

def state():
    return json.load(open(STATE))

def rnd(windows, now, power="battery", extra=None, env=None):
    return run(["round", "--power", power, "--windows", json.dumps({str(k): v for k, v in windows.items()})] + (extra or []), now, env)

FOOT, WEB, PLAYER = "app-Hyprland-foot-11.scope", "app-Hyprland-chromium-22.scope", "app-Hyprland-spotify-33.scope"

# A hidden app is limited after 30 s (its first CPU sample counts as working), the focused one never.
reset_fs()
proc(100, SLICE + FOOT, "foot"); scope(FOOT, [100], usec=1000, weight=100)
proc(200, SLICE + WEB, "chromium"); proc(201, SLICE + WEB, "chromium"); scope(WEB, [200, 201], usec=5000, weight=100, uclamp="max")
code, out, err = rnd({100: "focused", 200: "hidden"}, 1000)
check("round: exit 0 and asks to run again within 10 s while an app waits", code == 0 and json.loads(out)["next"] == 10)
check("round: nothing applied before the delay", log() == [])
code, out, _ = rnd({100: "focused", 200: "hidden"}, 1031)
check("round: hidden 30 s and quiet: CPUWeight 20 IOWeight 30 at runtime", log() == ["systemctl --user set-property --runtime -- %s CPUWeight=20 IOWeight=30" % WEB])
check("round: uclamp hint written when the file is writable", open(CG + SLICE + WEB + "/cpu.uclamp.max").read() == "40" and state()["uclamp"] == "available")
check("round: the focused app is never touched", FOOT not in " ".join(log()) and state()["apps"][FOOT]["applied"] == {})
check("round: next run within 60 s while a limit is held", json.loads(out)["next"] == 60 and json.loads(out)["limited"] == 1)
open(CG + SLICE + WEB + "/cpu.weight", "w").write("20\n")
open(LOG, "w").close()
code, out, _ = rnd({100: "focused", 200: "hidden"}, 1100)
check("round: an unchanged picture applies nothing again", log() == [])
code, out, _ = run(["status"], 1100)
check("status: explains the limited app and the focused one", "%s: hidden for 100 s · limited (CPUWeight=20, IOWeight=30, uclamp.max=40%%)" % WEB in out and "%s: focused" % FOOT in out and "seen by the person" in out)
# Focus moves to it: lifted at once (empty values put systemd's defaults back), uclamp back to max.
code, out, _ = rnd({100: "visible", 200: "focused"}, 1101)
check("round: focused again: released with empty values", log() == ["systemctl --user set-property --runtime -- %s CPUWeight= IOWeight=" % WEB])
check("round: uclamp back to max on release", open(CG + SLICE + WEB + "/cpu.uclamp.max").read() == "max")

# A wake lifts at once and the app earns its delay again.
reset_fs()
proc(200, SLICE + WEB, "chromium"); scope(WEB, [200], usec=0, weight=100)
rnd({200: "hidden"}, 0); rnd({200: "hidden"}, 25); set_usec(WEB, 100); rnd({200: "hidden"}, 40)
check("wake: precondition limited", state()["apps"][WEB]["applied"] == {"CPUWeight": 20, "IOWeight": 30})
open(CG + SLICE + WEB + "/cpu.weight", "w").write("20\n"); open(LOG, "w").close()
code, out, _ = run(["wake", "--pid", "200"], 41)
check("wake --pid: released at once", code == 0 and log() == ["systemctl --user set-property --runtime -- %s CPUWeight= IOWeight=" % WEB] and json.loads(out) == {"woken": 1})
open(LOG, "w").close()
rnd({200: "hidden"}, 42)
check("wake: the app earns its 30 s again", log() == [] and state()["apps"][WEB]["waiting"] == 30)
code, out, _ = run(["wake", "--all"], 43)
check("wake --all: every managed app", code == 0 and json.loads(out) == {"woken": 1})

# Claims.
def limited_after(setup, windows=None, extra=None, power="battery"):
    reset_fs()
    setup()
    windows = windows or {300: "hidden"}
    rnd(windows, 0, power, extra); rnd(windows, 15, power, extra); rnd(windows, 31, power, extra)
    return [l for l in log() if "CPUWeight=2" in l or "CPUWeight=4" in l]

def base(comm="spotify", fds=None, fdinfo=None, **kw):
    def go():
        proc(300, SLICE + PLAYER, comm, fds, fdinfo); scope(PLAYER, [300], **kw)
    return go

check("claims: a quiet hidden app with nothing open is limited", limited_after(base(weight=100)) != [])
check("claims: an open sound device protects it", limited_after(base(fds={"7": "/dev/snd/pcmC0D0p"})) == [] and state()["apps"][PLAYER]["reasons"] == ["device"])
check("claims: an open camera protects it", limited_after(base(fds={"7": "/dev/video0"})) == [])
check("claims: a render node alone does not", limited_after(base(fds={"7": "/dev/dri/renderD128"})) != [])
# PipeWire claims (D-3): stream node ids -> the node's client.id -> that Client's pipewire.sec.pid, from pw-dump (here a fixture).
def dump(nodes, clients, serials=True):
    # Serials as the server gives them: a client is created before its streams (lower object.serial).
    def sp(p, n):
        return {"object.serial": str(n), **p} if serials else p
    out = [{"id": i, "type": "PipeWire:Interface:Node", "info": {"props": sp(p, 1000 + i)}} for i, p in nodes.items()]
    out += [{"id": i, "type": "PipeWire:Interface:Client", "info": {"props": sp(p, 10 + i)}} for i, p in clients.items()]
    return out

def with_dump(data, raw=None):
    path = tmp + "/pwdump.json"
    open(path, "w").write(raw if raw is not None else json.dumps(data))
    return {"GRASSFIELD_PWDUMP_FILE": path}

def limited_env(env, extra):
    reset_fs(); base()()
    ws = {300: "hidden"}
    rnd(ws, 0, "battery", extra, env); rnd(ws, 15, "battery", extra, env); rnd(ws, 31, "battery", extra, env)
    return [l for l in log() if "CPUWeight=2" in l or "CPUWeight=4" in l]

real = dump({50: {"client.id": "7"}}, {7: {"pipewire.sec.pid": "300"}})
check("claims: a PipeWire stream of one of its processes (node -> client -> sec pid) protects it",
      limited_env(with_dump(real), ["--streams", "50"]) == [] and "media" in state()["apps"][PLAYER]["reasons"])
check("claims: another app's stream does not", limited_env(with_dump(dump({50: {"client.id": "7"}}, {7: {"pipewire.sec.pid": "999"}})), ["--streams", "50"]) != [])
forged = dump({50: {"client.id": "7", "pipewire.sec.pid": "300", "application.process.id": "300"}}, {7: {"pipewire.sec.pid": "999"}})
check("claims: a pid the NODE carries (forged pipewire.sec.pid, application.process.id) protects nothing",
      limited_env(with_dump(forged), ["--streams", "50"]) != [])
check("claims: a node without client.id, or whose client is missing, protects nothing",
      limited_env(with_dump(dump({50: {"pipewire.sec.pid": "300"}}, {7: {"pipewire.sec.pid": "300"}})), ["--streams", "50"]) != []
      and limited_env(with_dump(dump({50: {"client.id": "8"}}, {7: {"pipewire.sec.pid": "300"}})), ["--streams", "50"]) != [])
# PipeWire reuses object ids: a lingering node whose client left, and a newer client that took its id, protects nothing.
reused = dump({50: {"client.id": "7"}}, {7: {"pipewire.sec.pid": "300"}})
reused[1]["info"]["props"]["object.serial"] = "5000"
check("claims: a client newer than the stream (a reused client id) protects nothing", limited_env(with_dump(reused), ["--streams", "50"]) != [])
check("claims: a lingering node (object.linger) protects nothing",
      limited_env(with_dump(dump({50: {"client.id": "7", "object.linger": "true"}}, {7: {"pipewire.sec.pid": "300"}})), ["--streams", "50"]) != []
      and limited_env(with_dump(dump({50: {"client.id": "7", "object.linger": True}}, {7: {"pipewire.sec.pid": "300"}})), ["--streams", "50"]) != [])
check("claims: a node or client without object.serial protects nothing",
      limited_env(with_dump(dump({50: {"client.id": "7"}}, {7: {"pipewire.sec.pid": "300"}}, serials=False)), ["--streams", "50"]) != [])
check("claims: a dump nested deeper than the parser allows is no claim and no failure",
      limited_env(with_dump(None, raw="[" * 200000 + "]" * 200000), ["--streams", "50"]) != [])
check("claims: non-ASCII digits in --streams are dropped, no failure",
      limited_env(with_dump(real), ["--streams", "\u00b2,5\u0660"]) != [])
check("claims: a stream id that is not in the dump protects nothing", limited_env(with_dump(real), ["--streams", "51"]) != [])
check("claims: a dump that is not JSON, or not a list, is no claim and no failure",
      limited_env(with_dump(None, "not json"), ["--streams", "50"]) != [] and limited_env(with_dump(None, "{}"), ["--streams", "50"]) != [])
check("claims: an unreadable dump (no file) is no claim and no failure",
      limited_env({"GRASSFIELD_PWDUMP_FILE": tmp + "/missing.json"}, ["--streams", "50"]) != [])
check("claims: no stream passed, no dump read: the real pid in the dump alone protects nothing", limited_env(with_dump(real), []) != [])
check("claims: stream_client_pids reads only the client's pid, bounded and typed",
      m.stream_client_pids(real, [50]) == {300} and m.stream_client_pids(real, [1]) == set()
      and m.stream_client_pids(dump({50: {"client.id": 7}}, {7: {"pipewire.sec.pid": 300}}), [50]) == {300}
      and m.stream_client_pids(dump({50: {"client.id": "7"}}, {7: {"pipewire.sec.pid": "-1"}}), [50]) == set()
      and m.stream_client_pids(dump({50: {"client.id": "7"}}, {7: {"pipewire.sec.pid": "99999999"}}), [50]) == set()
      and m.stream_client_pids(dump({50: {"client.id": "7"}}, {7: {}}), [50]) == set()
      and m.stream_client_pids([None, 3, {"id": "x"}, {"id": 1}], [1]) == set() and m.stream_client_pids(None, [1]) == set())
check("claims: the person's choice protects it", limited_after(base(), extra=["--keep", "300"]) == [] and "keep" in state()["apps"][PLAYER]["reasons"])
check("claims: an alarm timerfd (CLOCK_BOOTTIME_ALARM) protects it",
      limited_after(base(fds={"9": "anon_inode:[timerfd]"}, fdinfo={"9": "pos:\t0\nflags:\t02\nclockid: 9\nticks: 0\n"})) == [] and state()["apps"][PLAYER]["reasons"] == ["alarm"])
check("claims: CLOCK_REALTIME_ALARM too",
      limited_after(base(fds={"9": "anon_inode:[timerfd]"}, fdinfo={"9": "clockid: 8\n"})) == [])
check("claims: an ordinary monotonic timerfd does not",
      limited_after(base(fds={"9": "anon_inode:[timerfd]"}, fdinfo={"9": "clockid: 1\n"})) != [])
check("claims: a session process in the scope protects it", limited_after(base(comm="xdg-desktop-por")) == [] and "session" in state()["apps"][PLAYER]["reasons"])
check("claims: Efficiency Mode's weight (1) is someone else's: left alone", limited_after(base(weight=1)) == [] and "foreign" in state()["apps"][PLAYER]["reasons"])
check("claims: cpu.idle 1 is someone else's too", limited_after(base(weight=100, idle=1)) == [])
def busy():
    proc(300, SLICE + PLAYER, "spotify"); scope(PLAYER, [300], usec=0)
reset_fs(); busy()
rnd({300: "hidden"}, 0); set_usec(PLAYER, 1_000_000); rnd({300: "hidden"}, 15); set_usec(PLAYER, 2_000_000); rnd({300: "hidden"}, 31)
check("claims: more than 0.5 % of a core over the window: still working", log() == [] and state()["apps"][PLAYER]["reasons"] == ["working"])
reset_fs(); busy()
rnd({300: "hidden"}, 0); rnd({300: "hidden"}, 31)
check("claims: the first CPU sample is judged once a full window has passed", log() != [])
reset_fs(); busy()
recs = {"app-e-1.scope": {"state": "hidden", "since": 0.0, "applied": {}, "uclamp": None, "mark": None, "busy": True, "cgroup": SLICE + PLAYER}}
check("claims: a first sample (no mark yet) counts as working", m.Probe.working(recs["app-e-1.scope"], 50.0) is True and recs["app-e-1.scope"]["mark"] == [0, 50.0])
check("claims: a sample younger than the window keeps the last judgement", m.Probe.working(recs["app-e-1.scope"], 55.0) is True)
check("claims: a quiet full window is judged quiet", m.Probe.working(recs["app-e-1.scope"], 61.0) is False)
reset_fs(); busy()
open(CG + SLICE + PLAYER + "/cpu.stat", "w").write("garbage\n")
rnd({300: "hidden"}, 0); rnd({300: "hidden"}, 15); rnd({300: "hidden"}, 31)
check("claims: an unreadable cpu.stat counts as working (when unsure, do not limit)", log() == [] and state()["apps"][PLAYER]["reasons"] == ["working"])

# Weight set elsewhere while Grassfield's limit is held (review of the first pass, BLOCKER): CPUWeight is theirs and stays,
# IOWeight and uclamp are put back at once, so nothing of Grassfield's is left behind whatever happens next.
reset_fs(); base(weight=100, uclamp="max")()
rnd({300: "hidden"}, 0); rnd({300: "hidden"}, 15); rnd({300: "hidden"}, 31)
check("foreign: precondition limited with uclamp 40", state()["apps"][PLAYER]["applied"] == {"CPUWeight": 20, "IOWeight": 30} and open(CG + SLICE + PLAYER + "/cpu.uclamp.max").read() == "40")
open(CG + SLICE + PLAYER + "/cpu.weight", "w").write("1\n"); open(LOG, "w").close()
rnd({300: "hidden"}, 100)
check("foreign: Efficiency Mode over our limit: IOWeight and uclamp back, CPUWeight left to it",
      log() == ["systemctl --user set-property --runtime -- %s IOWeight=" % PLAYER] and open(CG + SLICE + PLAYER + "/cpu.uclamp.max").read() == "max" and state()["apps"][PLAYER]["applied"] == {} and state()["apps"][PLAYER]["uclamp"] is None)
open(CG + SLICE + PLAYER + "/cpu.weight", "w").write("100\n"); open(LOG, "w").close()
rnd({300: "focused"}, 101); run(["reset"], 102)
check("foreign: Efficiency Mode turned off, app focused, reset: nothing left to lift, uclamp stays max", log() == [] and open(CG + SLICE + PLAYER + "/cpu.uclamp.max").read() == "max")
reset_fs(); base(weight=100)()
rnd({300: "hidden"}, 0); rnd({300: "hidden"}, 15); rnd({300: "hidden"}, 31)
open(CG + SLICE + PLAYER + "/cpu.weight", "w").write("1\n"); open(LOG, "w").close()
rnd({300: "focused"}, 32)
check("foreign: a release (focused again) never resets a weight set elsewhere, still puts IOWeight back",
      log() == ["systemctl --user set-property --runtime -- %s IOWeight=" % PLAYER] and state()["apps"][PLAYER]["applied"] == {})

# E1 of the 2026-11 audit: our limit undone elsewhere (Efficiency Mode turned off puts the default weight back) was still
# recorded as applied and never set again. It is seen and applied again.
reset_fs(); base(weight=100)()
rnd({300: "hidden"}, 0); rnd({300: "hidden"}, 15); rnd({300: "hidden"}, 31)
check("undone: precondition limited", state()["apps"][PLAYER]["applied"] == {"CPUWeight": 20, "IOWeight": 30})
open(CG + SLICE + PLAYER + "/cpu.weight", "w").write("20\n"); open(LOG, "w").close()
rnd({300: "hidden"}, 100)
check("undone: our own weight read back: nothing set again", log() == [])
open(CG + SLICE + PLAYER + "/cpu.weight", "w").write("100\n")
rnd({300: "hidden"}, 170)
check("undone: the default weight back while limited: applied again",
      log() == ["systemctl --user set-property --runtime -- %s CPUWeight=20 IOWeight=30" % PLAYER] and state()["apps"][PLAYER]["applied"] == {"CPUWeight": 20, "IOWeight": 30})

# E2 of the 2026-11 audit: a wake waited for a running round's lock (a pw-dump and fd scans), the app in front kept its
# limit meanwhile. It lifts at once, notes itself, and the round takes the note: it does not limit that app again.
import fcntl, time
reset_fs(); base(weight=100)()
rnd({300: "hidden"}, 0); rnd({300: "hidden"}, 15); rnd({300: "hidden"}, 31)
open(CG + SLICE + PLAYER + "/cpu.weight", "w").write("20\n"); open(LOG, "w").close()
held = os.open(STATE + ".lock", os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(held, fcntl.LOCK_EX)  # a round is running
started = time.monotonic()
code, out, _ = run(["wake", "--pid", "300"], 40)
took = time.monotonic() - started
check("wake during a round: does not wait for its lock", code == 0 and took < 3 and json.loads(out) == {"woken": 1})
check("wake during a round: the limit is lifted at once", log() == ["systemctl --user set-property --runtime -- %s CPUWeight= IOWeight=" % PLAYER])
check("wake during a round: noted for the round", os.path.exists(STATE + ".wakes"))
data = {"v": 1, "apps": {PLAYER: dict(state()["apps"][PLAYER])}}
check("take_wakes: the round sees the noted app as released", m.take_wakes(STATE, data, 41.0) == {PLAYER} and data["apps"][PLAYER]["applied"] == {} and data["apps"][PLAYER]["state"] == "visible")
open(STATE + ".wakes", "w").write(json.dumps({"all": False, "units": [PLAYER], "at": 40}) + "\n")  # noted again for the CLI round
fcntl.flock(held, fcntl.LOCK_UN); os.close(held)
open(CG + SLICE + PLAYER + "/cpu.weight", "w").write("100\n"); open(LOG, "w").close()
rnd({300: "hidden"}, 41)
check("wake during a round: the next round records it released and limits nothing yet",
      log() == [] and state()["apps"][PLAYER]["applied"] == {} and state()["apps"][PLAYER]["waiting"] == 30 and not os.path.exists(STATE + ".wakes"))

# Protection and unreadable processes.
reset_fs()
proc(400, "/user.slice/user-%d.slice/user@%d.service/session.slice/xdg-desktop-portal.service" % (uid, uid), "xdg-desktop-por")
proc(401, "/user.slice/user-%d.slice/user@%d.service/app.slice/app-flatpak-org.x-1.scope" % (uid, uid), "x")
for t in (0, 31, 62):
    rnd({400: "hidden", 401: "hidden", 402: "hidden"}, t)
check("protected: session services, Flatpak scopes and unreadable processes are never limited", log() == [] and state()["apps"] == {})
code, out, _ = run(["status"], 62)
check("status: says why a window's process is never limited", "window process 400: never limited (outside the person's apps)" in out and "window process 402: never limited (process not readable)" in out)

# The app takes its most awake window: one visible window of a scope keeps it out of reach.
reset_fs()
proc(500, SLICE + WEB, "chromium"); proc(501, SLICE + WEB, "chromium"); scope(WEB, [500, 501], weight=100)
for t in (0, 31, 62):
    rnd({500: "hidden", 501: "visible"}, t)
check("merge: a scope with a visible window is not limited", log() == [] and state()["apps"][WEB]["state"] == "visible")

# Power (integrator decision 2026-11-05): nothing on the power adapter; back on it everything is lifted at once.
reset_fs(); base(weight=100, uclamp="max")()
rnd({300: "hidden"}, 0, "mains"); rnd({300: "hidden"}, 15, "mains"); code, out, _ = rnd({300: "hidden"}, 100, "mains")
check("mains: a hidden app is never limited and no run is asked", log() == [] and json.loads(out)["next"] == 0 and open(CG + SLICE + PLAYER + "/cpu.uclamp.max").read().strip() == "max")
reset_fs(); base(weight=100, uclamp="max")()
rnd({300: "hidden"}, 0); rnd({300: "hidden"}, 15); rnd({300: "hidden"}, 31)
open(CG + SLICE + PLAYER + "/cpu.weight", "w").write("20\n"); open(LOG, "w").close()
rnd({300: "hidden"}, 40, "mains")
check("mains: the battery limit is lifted at once", log() == ["systemctl --user set-property --runtime -- %s CPUWeight= IOWeight=" % PLAYER] and open(CG + SLICE + PLAYER + "/cpu.uclamp.max").read() == "max")
open(CG + SLICE + PLAYER + "/cpu.weight", "w").write("100\n"); open(LOG, "w").close()
rnd({300: "hidden"}, 200, "mains")
check("mains: and stays lifted", log() == [])

# uclamp: absent or not writable: marked unavailable, never tried again, weights still applied.
reset_fs(); base(weight=100)()
rnd({300: "hidden"}, 0); rnd({300: "hidden"}, 15); rnd({300: "hidden"}, 31)
check("uclamp: no file: unavailable, weights applied", state()["uclamp"] == "unavailable" and state()["apps"][PLAYER]["applied"] == {"CPUWeight": 20, "IOWeight": 30} and state()["apps"][PLAYER]["uclamp"] is None)
code, out, _ = run(["status"], 32)
check("status: says uclamp is unavailable", "uclamp: unavailable" in out)

# A failing systemctl records nothing as applied.
reset_fs(); base(weight=100)()
env = {"FAKE_SYSTEMCTL_EXIT": "1"}
rnd({300: "hidden"}, 0, env=env); rnd({300: "hidden"}, 15, env=env); code, out, err = rnd({300: "hidden"}, 31, env=env)
check("systemctl failure: nothing recorded as applied, round still exits 0", code == 0 and state()["apps"][PLAYER]["applied"] == {} and "systemctl" in err)

# Reset lifts every recorded limit; a gone scope is only forgotten.
reset_fs()
proc(300, SLICE + PLAYER, "spotify"); scope(PLAYER, [300], weight=100)
proc(200, SLICE + WEB, "chromium"); scope(WEB, [200], weight=100)
for t in (0, 15, 31):
    rnd({300: "hidden", 200: "hidden"}, t)
open(CG + SLICE + PLAYER + "/cpu.weight", "w").write("20\n")
shutil.rmtree(CG + SLICE + WEB); open(LOG, "w").close()
code, out, _ = run(["reset"], 50)
check("reset: lifts the live scope, skips the gone one, empties the record", code == 0 and log() == ["systemctl --user set-property --runtime -- %s CPUWeight= IOWeight=" % PLAYER] and json.loads(out) == {"reset": 2} and state()["apps"] == {})
open(LOG, "w").close()
run(["reset"], 51)
check("reset: idempotent", log() == [])

# Dry run (nested dev sessions): decides and records, never runs systemctl nor writes cgroup files; its records are never
# released for real.
reset_fs(); base(weight=100, uclamp="max")()
dry = tmp + "/dev/app-energy.json"
for t in (0, 15, 31):
    run(["round", "--dry-run", "--state", dry, "--power", "battery", "--windows", '{"300": "hidden"}'], t)
d = json.load(open(dry))
check("dry run: decided (limited in the record)", d["dry"] is True and d["apps"][PLAYER]["applied"] == {"CPUWeight": 20, "IOWeight": 30})
check("dry run: no systemctl, no cgroup write, real state file untouched", log() == [] and open(CG + SLICE + PLAYER + "/cpu.uclamp.max").read().strip() == "max" and not os.path.exists(STATE))
run(["reset", "--state", dry], 40)
check("dry run: a real reset of a dry record runs nothing", log() == [])
code, out, _ = run(["status", "--state", dry], 41)
check("status: of an empty record", code == 0 and "no app is managed" in out)

# A dry run without --state keeps its own file: a dry release never hides the real records from a later real reset.
reset_fs(); base(weight=100)()
for t in (0, 15, 31):
    rnd({300: "hidden"}, t)
open(CG + SLICE + PLAYER + "/cpu.weight", "w").write("20\n"); open(LOG, "w").close()
code, out, _ = run(["reset", "--dry-run"], 40)
check("dry run without --state: its own file, the real record kept", code == 0 and log() == [] and state()["apps"].get(PLAYER, {}).get("applied") == {"CPUWeight": 20, "IOWeight": 30}
      and os.path.exists(tmp + "/run/grassfield/app-energy.dry.json"))
run(["reset"], 41)
check("dry run without --state: a later real reset still lifts the real limit", log() == ["systemctl --user set-property --runtime -- %s CPUWeight= IOWeight=" % PLAYER])

# The dev rule in the helper itself (ADR-0019): outside a dev session the seams are ignored; in a dev session without a full
# fixture every command is a dry run.
reset_fs(); base(weight=100)()
for t in (0, 15, 31):
    rnd({300: "hidden"}, t, env={"GRASSFIELD_DEV": "", "GRASSFIELD_ENERGY_NOW": "x"})
real = json.load(open(STATE))
check("outside dev: the fake /proc and cgroup tree are not read", log() == [] and PLAYER not in real["apps"])
reset_fs(); base(weight=100)()
for t in (0, 15, 31):
    rnd({300: "hidden"}, t, env={"GRASSFIELD_DEV": "1", "GRASSFIELD_SESSION": "1"})
check("a packaged session with GRASSFIELD_DEV=1 is not dev: seams ignored", log() == [] and PLAYER not in state()["apps"])
reset_fs(); base(weight=100)()
for t in (0, 15, 31):
    rnd({300: "hidden"}, t, env={"GRASSFIELD_CGROUP_ROOT": ""})
dryfile = tmp + "/run/grassfield/app-energy.dry.json"
d = json.load(open(dryfile)) if os.path.exists(dryfile) else {}
check("dev without a full fixture: forced dry run, in the dry file", log() == [] and d.get("dry") is True and not os.path.exists(STATE))
# The real trees named another way (a trailing slash, a link) are the real trees, never a fixture: either one real is enough
# for a forced dry run.
os.symlink("/proc", tmp + "/proc-link")
for roots in ({"GRASSFIELD_PROC_ROOT": "/proc/", "GRASSFIELD_CGROUP_ROOT": "/sys/fs/cgroup/"},
              {"GRASSFIELD_PROC_ROOT": tmp + "/proc-link", "GRASSFIELD_CGROUP_ROOT": "/sys/fs/cgroup/."},
              {"GRASSFIELD_PROC_ROOT": "/proc/", "GRASSFIELD_CGROUP_ROOT": CG},
              {"GRASSFIELD_PROC_ROOT": PROC, "GRASSFIELD_CGROUP_ROOT": "/sys/fs/cgroup/"}):
    reset_fs(); base(weight=100)()
    code, out, _ = rnd({os.getpid(): "hidden"}, 0, env=roots)
    check("dev with the real trees spelled %s, %s: forced dry run" % (roots["GRASSFIELD_PROC_ROOT"], roots["GRASSFIELD_CGROUP_ROOT"]),
          code == 0 and log() == [] and not os.path.exists(STATE) and json.load(open(dryfile)).get("dry") is True)

# The clock seam is dev plumbing too: outside a dev session GRASSFIELD_ENERGY_NOW is ignored (the monotonic clock is used).
def woken_since(env):
    reset_fs()
    os.makedirs(tmp + "/run/grassfield", exist_ok=True)
    rec = {"cgroup": SLICE + PLAYER, "state": "hidden", "since": 0, "applied": {}, "uclamp": None, "mark": None, "busy": True}
    json.dump({"v": 1, "apps": {PLAYER: rec}}, open(STATE, "w"))
    run(["wake", "--all"], 5, env)
    return state()["apps"][PLAYER]["since"]
check("clock seam honoured in dev (control)", woken_since({}) == 5)
check("clock seam ignored outside dev", woken_since({"GRASSFIELD_DEV": ""}) != 5)
reset_fs()

# Bad input.
code, out, err = run(["round", "--power", "battery", "--windows", "[1]"], 0)
check("round: malformed windows refused (exit 2), nothing written", code == 2 and not os.path.exists(STATE))
code, out, err = run(["round", "--power", "solar", "--windows", "{}"], 0)
check("round: unknown power refused", code == 2)
code, out, err = run(["bogus"], 0)
check("unknown command: usage, exit 2", code == 2 and "grassfield-energy round" in err)
open(STATE, "w").write("{not json")
code, out, err = run(["reset"], 0)
check("a corrupt state file reads as empty", code == 0 and json.loads(out) == {"reset": 0})

print("%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
PY
python3 -I "$tmp/test.py" "$helper" "$tmp"
