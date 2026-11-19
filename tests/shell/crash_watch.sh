#!/usr/bin/env bash
# grassfield-crash-watch follows the macOS model: "<App> quit unexpectedly" only when an application of the user QUIT by crashing
# (its scope is gone or empty), never for a tool run in a terminal, a helper of a running app, a service or a forged entry.
# Journal entries recorded with `journalctl -o json MESSAGE_ID=fc2e22bc6ee647b6b90729ab34a250b1` in the owner's real session
# (2026-10-25, tests/shell/crash_watch/real-*.json; only the large dump fields are dropped) are the input; the cgroup tree is a
# fake directory (GRASSFIELD_CGROUP_ROOT). Nothing here talks to a session: notify-send, gdbus, systemd-run, uwsm-app and
# journalctl are stubs on PATH. The rules are also mutation-tested: each mutant of the helper must make the decisions fail.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/crash-watch.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
helper=$root/packaging/bin/grassfield-crash-watch

mkdir -p "$tmp/bin"
cat >"$tmp/bin/notify-send" <<'SH'
#!/bin/sh
echo "notify-send $*" >>"$FAKE_LOG"
case " $* " in *" -p "*) echo 42 ;; esac
[ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP"
case " $* " in *" -w "*) printf '%s\n' "${FAKE_ANSWER:-}" ;; esac
exit 0
SH
printf '#!/bin/sh\necho "systemd-run $*" >>"$FAKE_LOG"\n' >"$tmp/bin/systemd-run"
cat >"$tmp/bin/gdbus" <<'SH'
#!/bin/sh
# GetNameOwner answers with the owner kept in $FAKE_OWNER_FILE (not logged); everything else is logged.
case " $* " in
  *GetNameOwner*) [ -s "${FAKE_OWNER_FILE:-/nonexistent}" ] && { printf "('%s',)\n" "$(cat "$FAKE_OWNER_FILE")"; exit 0; }; exit 1 ;;
esac
echo "gdbus $*" >>"$FAKE_LOG"
SH
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/uwsm-app"
printf '#!/bin/sh\ncat "$FAKE_JOURNAL"\n' >"$tmp/bin/journalctl"
chmod +x "$tmp/bin"/*

cat >"$tmp/test.py" <<'PY'
import copy, importlib.machinery, importlib.util, json, os, shutil, sys, time
sys.dont_write_bytecode = True  # no __pycache__ in packaging/bin (it would be packaged)
root, tmp, helper, mode = sys.argv[1:5]   # mode: all | decisions
os.environ["GRASSFIELD_CGROUP_ROOT"] = tmp + "/cg"
loader = importlib.machinery.SourceFileLoader("crash", helper)
spec = importlib.util.spec_from_loader("crash", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
fx = root + "/tests/shell/crash_watch/"
uid = os.getuid()
def load(pid):
    e = json.load(open(fx + "real-%s.json" % pid))
    for k in ("COREDUMP_CGROUP", "COREDUMP_PROC_CGROUP"):
        if k in e: e[k] = e[k].replace("1000", str(uid))
    e["COREDUMP_UID"] = str(uid); e["_UID"] = str(uid)
    return e
CG = "/user.slice/user-%d.slice/user@%d.service/app.slice/app-graphical.slice/" % (uid, uid)
SPOTIFY = CG + "app-Hyprland-spotify-1191618a.scope"
FOOT = CG + "app-Hyprland-foot-d359984a.scope"
def cg(path, state):
    d = tmp + "/cg" + path
    if state == "gone":
        shutil.rmtree(d, ignore_errors=True); return
    os.makedirs(d, exist_ok=True)
    try: os.remove(d + "/cgroup.events")
    except OSError: pass
    if state in ("populated", "empty"):
        open(d + "/cgroup.events", "w").write("populated %d\nfrozen 0\n" % (state == "populated"))
    if state == "unreadable":
        os.makedirs(d + "/cgroup.events")  # a directory where the file should be: open() fails with EISDIR
data = tmp + "/share/applications"; os.makedirs(data)
def desktop(name, text): open(data + "/" + name, "w").write("[Desktop Entry]\nType=Application\n" + text)
desktop("spotify.desktop", "Name=Spotify\nName[fr]=Spotify fr\nName[fr_CA]=Spotify ca\nExec=spotify %U\n")
desktop("foot.desktop", "Name=Foot\nExec=foot\n")
desktop("hidden.desktop", "Hidden=true\nName=Hidden\nExec=hidden\n")
desktop("org.gnome.Nautilus.desktop", "Name=Files (Nautilus)\nName[fr]=Fichiers\nExec=nautilus --new-window %U\nStartupWMClass=org.gnome.Nautilus\n")
desktop("grassfield-files.desktop", "Name=Grassfield Files\nExec=/usr/bin/grassfield-files %U\n")
desktop("libreoffice-writer.desktop", "Name=LibreOffice Writer\nExec=libreoffice --writer %U\n")
desktop("libreoffice-calc.desktop", "Name=LibreOffice Calc\nExec=libreoffice --calc %U\n")
desktop("libreoffice-startcenter.desktop", "Name=LibreOffice\nExec=libreoffice %U\n")
desktop("gimp-a.desktop", "Name=Gimp A\nExec=env X=1 gimp --a\n")
desktop("gimp-b.desktop", "Name=Gimp B\nExec=gimp --b\n")
desktop("wmc.desktop", "Name=Wm Class\nExec=/opt/x/launcher\nStartupWMClass=SomeClass\n")
desktop("org.x.My-App.desktop", "Name=My App\nExec=flatpak run org.x.My-App\n")
os.makedirs(data + "/kde"); open(data + "/kde/part.desktop", "w").write("[Desktop Entry]\nType=Application\nName=Part\nExec=kpart\n")
env_en = {"XDG_DATA_HOME": tmp + "/none", "XDG_DATA_DIRS": tmp + "/share", "LANG": "en_US.UTF-8"}
env_fr = dict(env_en, LANG="fr_FR.UTF-8")

class W(m.Watcher):
    """The decisions only: what would be sent."""
    def __init__(self, *a, **k): super().__init__(*a, **k); self.out = []
    def send(self, job, now): self.out.append((job["info"]["name"], job["info"]["key"], job["info"]["desktop_id"]))

def fresh(tree=True):
    """An empty cgroup2 tree (its cgroup.controllers file is what says the tree is there), or none at all."""
    shutil.rmtree(tmp + "/cg", ignore_errors=True)
    if tree:
        os.makedirs(tmp + "/cg"); open(tmp + "/cg/cgroup.controllers", "w").write("cpu memory pids\n")

def run(entry, script, env=env_en, times=range(0, 13)):
    """script: {time: (cgroup, state)} applied before the step at that time. Returns (what was sent, pending left)."""
    fresh()   # every cgroup is gone unless the script says otherwise
    w = W(uid, env, tmp + "/cg"); w.add(entry, 0.0)
    for t in times:
        if t in script:
            for path, state in script[t]: cg(path, state)
        w.step(float(t))
    return w.out, len(w.pending)
def one(out): return out[0] if out else None

gpu, qml = load(2602), load(128224)
quick, portal = load(1549372), load(3298)
assert gpu["_EXE"] == "/usr/lib/systemd/systemd-coredump" and gpu["_SYSTEMD_UNIT"].startswith("systemd-coredump@")
print("fields", gpu["COREDUMP_UID"] == str(uid), gpu["COREDUMP_USER_UNIT"], qml["COREDUMP_USER_UNIT"])
res = {}
# 1. A command run from a terminal: the terminal's scope still holds the shell (qml --version in foot, real dump 128224).
res["terminal-child"] = run(qml, {0: [(FOOT, "populated")]})
# 2. A helper of a running app (Spotify GPU process, real dump 2602): the scope is populated all along.
res["helper"] = run(gpu, {0: [(SPOTIFY, "populated")]})
# 3. The application quit: scope gone, or empty at once, or emptied after 3 s; never, or unreadable, or unknown: silent.
res["quit-gone"] = run(gpu, {0: [(SPOTIFY, "gone")]})
res["quit-empty"] = run(gpu, {0: [(SPOTIFY, "empty")]})
res["quit-late"] = run(gpu, {0: [(SPOTIFY, "populated")], 3: [(SPOTIFY, "empty")]})
res["too-late"] = run(gpu, {0: [(SPOTIFY, "populated")], 11: [(SPOTIFY, "gone")]})
res["unknown"] = run(gpu, {0: [(SPOTIFY, "unknown")]})
res["unreadable"] = run(gpu, {0: [(SPOTIFY, "unreadable")]})
# 4. Services: never, even when their cgroup is gone (the shell is 37 of this boot's dumps).
assert "wayland-wm@hyprland.desktop.service" in quick["COREDUMP_CGROUP"]
res["shell-service"] = run(quick, {})
res["portal-service"] = run(portal, {})  # (no scope state given: gone)
sess = copy.deepcopy(gpu); sess["COREDUMP_CGROUP"] = "/user.slice/user-%d.slice/session-2.scope" % uid; sess["COREDUMP_USER_UNIT"] = ""
res["login-scope"] = run(sess, {})
other = copy.deepcopy(gpu); other["COREDUMP_CGROUP"] = other["COREDUMP_CGROUP"].replace("user-%d" % uid, "user-%d" % (uid + 1)).replace("user@%d" % uid, "user@%d" % (uid + 1))
res["other-users-scope"] = run(other, {})
# 5. Forged or foreign entries: a user process logging the same MESSAGE_ID has its own _EXE and unit.
def mod(e, **kw): e = copy.deepcopy(e); e.update(kw); return e
res["forged-exe"] = run(mod(gpu, _EXE="/usr/bin/python3"), {})
res["forged-unit"] = run(mod(gpu, _SYSTEMD_UNIT="app-x.scope"), {})
res["forged-no-trusted"] = run({k: v for k, v in gpu.items() if not k.startswith("_")}, {})
res["forged-id"] = run(mod(gpu, MESSAGE_ID="0" * 32), {})
res["other-coredump-uid"] = run(mod(gpu, COREDUMP_UID=str(uid + 1)), {})
res["uid-is-coredump-uid"] = run(mod(gpu, _UID="0"), {})
res["not-app-slice"] = run(mod(gpu, COREDUMP_CGROUP=SPOTIFY.replace("/app.slice/", "/background.slice/")), {})
res["unit-mismatch"] = run(mod(gpu, COREDUMP_USER_UNIT="app-other-1.scope"), {})
res["dotdot"] = run(mod(gpu, COREDUMP_CGROUP=CG + "../../x/app-a-b-1.scope"), {})
# 6. Malformed fields never announce and never raise.
bad = {}
for name, entry in {"empty": {}, "list": [], "none": None, "str": "x",
                    "pid-superscript": mod(gpu, COREDUMP_PID="²"), "pid-garbage": mod(gpu, COREDUMP_PID="x; rm"),
                    "uid-superscript": mod(gpu, COREDUMP_UID="²"), "cgroup-int": mod(gpu, COREDUMP_CGROUP=12),
                    "cgroup-none": mod(gpu, COREDUMP_CGROUP=None), "cgroup-list": mod(gpu, COREDUMP_CGROUP=[1, 2, 300]),
                    "exe-none": mod(gpu, COREDUMP_EXE=None, COREDUMP_COMM=None),
                    "own": mod(gpu, COREDUMP_EXE="/usr/lib/grassfield/grassfield-crash-watch")}.items():
    try:
        bad[name] = run(entry, {0: [(SPOTIFY, "gone")]})[0]
    except Exception as exc:  # noqa
        bad[name] = "RAISED %r" % exc
print("bad", sorted(k for k, v in bad.items() if v) or "none-announced")
# 7. Names: desktop entry by id, by Exec binary, StartupWMClass; generic entry for a shared binary; localized.
def named(appid, env=env_en, exe="x", launcher="Hyprland"):
    e = mod(gpu, COREDUMP_EXE="/usr/bin/" + exe)
    e["COREDUMP_CGROUP"] = CG + "app-%s-%s-77.scope" % (launcher, appid); e["COREDUMP_USER_UNIT"] = "app-%s-%s-77.scope" % (launcher, appid)
    return one(run(e, {0: [(e["COREDUMP_CGROUP"], "gone")]}, env)[0])
print("by-id", named("spotify"), named("spotify", env_fr), named("foot"))
print("by-exec", named("nautilus"), named("nautilus", env_fr), named("grassfield-files"))
print("by-wm-class", named("org.gnome.Nautilus"), named("someclass"))
print("shared", named("libreoffice"), named("gimp", exe="gimp"), named("kpart"), named("hidden", exe="hidden"))
print("unknown-app", named("nosuchapp", exe="nosuch"), named("gtk\\x2dlaunch", exe="script"))
print("flatpak", named("org.x.My-App", launcher="flatpak"), named("org.x.My\\x2dApp", launcher="Hyprland"))
print("scope-names", m.parse_scope("app-Hyprland-gtk\\x2dlaunch-27c3252d.scope"), m.parse_scope("app-foo-123.scope"),
      m.parse_scope("app-flatpak-org.x.My-App-99.scope"), m.parse_scope("app-.scope"), m.parse_scope("foo.service"), m.parse_scope("app-a@b.service"))
print("traversal", [m.desktop_entry(a, env_en) for a in ("../x", "a/b", "", ".hidden", "x..y", "spotify\n")])
# 8. Dedupe key = desktop id (or the program), so two gtk-launch scopes of different programs both get a notice, one program once.
w = W(uid, env_en, tmp + "/cg")
fresh()
for i, (a, x) in enumerate([("gtk\\x2dlaunch", "alpha"), ("gtk\\x2dlaunch", "beta"), ("spotify", "spotify"), ("spotify", "spotify")]):
    unit = "app-Hyprland-%s-%d.scope" % (a, 100 + i)
    e = mod(gpu, COREDUMP_EXE="/usr/bin/" + x, COREDUMP_CGROUP=CG + unit, COREDUMP_USER_UNIT=unit)
    w.add(e, float(i))
w.step(5.0)
print("dedupe-keys", [o[1] for o in w.out])
# 9. Ledger: window and cap.
led = m.Ledger()
print("ledger", led.reserve("a", 1000.0), led.reserve("a", 1030.0), led.reserve("a", 1540.0), led.reserve("a", 1601.0))
led.release("a", 1601.0); print("release", led.reserve("a", 1602.0))
led = m.Ledger(); print("cap", [led.reserve("k%d" % i, 2000.0 + i) for i in range(8)], led.reserve("z", 2000.0 + 3700))
print("under_cap", m.under_cap([0.0, 10.0, 20.0, 30.0, 40.0, 50.0], 100.0), m.under_cap([0.0, 10.0, 20.0, 30.0, 40.0, 50.0], 3700.0), m.under_cap([0.0] * 5, 100.0))
# A scope that stays populated is dropped at the deadline (nothing pending is kept).
print("pending-after", run(gpu, {0: [(SPOTIFY, "populated")]})[1], run(gpu, {0: [(SPOTIFY, "gone")]})[1])
# Entries without _EXE (2 of 127 real ones) are trusted by their coredump unit; a user-manager unit is refused either way.
noexe = {k: v for k, v in gpu.items() if k != "_EXE"}
res["no-exe"] = run(noexe, {0: [(SPOTIFY, "gone")]})
res["no-exe-user-unit"] = run(mod(noexe, _SYSTEMD_UNIT="user@%d.service" % uid), {})
res["no-exe-no-unit"] = run({k: v for k, v in noexe.items() if k != "_SYSTEMD_UNIT"}, {})
res["foreign-exe"] = run(mod(gpu, _EXE="/usr/bin/evil"), {})
# Chromium-based apps run their browser process in a scope named after the application id (not a desktop file id): the crashed
# binary finds the entry.
desktop("chromium.desktop", "Name=Chromium\nName[fr]=Chromium fr\nExec=chromium %U\n")
def chrome(appid, exe, env=env_en):
    u = "app-Hyprland-%s-77.scope" % appid
    e = mod(gpu, COREDUMP_EXE="/usr/lib/chromium/" + exe, COREDUMP_CGROUP=CG + u, COREDUMP_USER_UNIT=u)
    return one(run(e, {0: [(CG + u, "gone")]}, env)[0])
print("chromium", chrome("org.chromium.Chromium", "chromium"), chrome("org.chromium.Chromium", "chromium", env_fr), chrome("org.other.App", "other-bin"))
# A missing cgroup2 tree is unknown, never "everything quit"; a tree without the scope is gone.
fresh(tree=False)
w = W(uid, env_en, tmp + "/cg"); w.add(gpu, 0.0); w.step(0.0); w.step(11.0)
print("no-tree", w.out, len(w.pending), m.scope_state(SPOTIFY, tmp + "/cg"))
fresh(); print("tree", m.scope_state(SPOTIFY, tmp + "/cg"))
# A cgroup.events file that is not what the kernel writes is "unknown", never an exception (tests/fuzz/fuzz_helpers.py found
# both: a non-UTF-8 byte raised UnicodeDecodeError, a "populated" line without its value raised IndexError). The populated
# line decides wherever it is, and a stray byte on another line does not hide it; a directory in its place is unknown (each
# guard told apart from the others: the integrator's review of 265e6c7, nit).
for name, content in (("events-not-utf8", b"populated \xff\n"), ("events-no-value", b"populated\n"), ("events-blank-value", b"populated   \n"),
                      ("events-long", b"frozen 0\n" * 2000 + b"populated 0\n"), ("events-oversized", b"frozen 0\n" * 20000 + b"populated 0\n"),
                      ("events-late-garbage", b"populated 1\nfrozen 0\n\xff\n"), ("events-frozen-first", b"frozen 0\npopulated 1\n")):
    fresh(); cg(SPOTIFY, "populated"); open(tmp + "/cg" + SPOTIFY + "/cgroup.events", "wb").write(content)
    print(name, m.scope_state(SPOTIFY, tmp + "/cg"))
fresh(); cg(SPOTIFY, "populated"); os.remove(tmp + "/cg" + SPOTIFY + "/cgroup.events"); os.mkdir(tmp + "/cg" + SPOTIFY + "/cgroup.events")
print("events-directory", m.scope_state(SPOTIFY, tmp + "/cg"))
# The Flatpak user installation is under the data home (XDG_DATA_HOME/flatpak/exports/share), not next to it.
xh = tmp + "/xh"; os.makedirs(xh + "/flatpak/exports/share/applications")
open(xh + "/flatpak/exports/share/applications/org.f.App.desktop", "w").write("[Desktop Entry]\nType=Application\nName=Flat App\nExec=flatpak run org.f.App\n")
env_fp = {"XDG_DATA_HOME": xh, "XDG_DATA_DIRS": tmp + "/none", "LANG": "C"}
print("flatpak-path", xh + "/flatpak/exports/share" in m.data_dirs(env_fp), not any(".." in d for d in m.data_dirs(env_fp)), m.desktop_entry("org.f.App", env_fp))
for k, v in res.items():
    print("case", k, one(v[0]))

if mode == "decisions":
    sys.exit(0)

# Strings: every source string has a French translation of its own, with the same placeholders.
src = [m.TITLE, m.BODY, m.REOPEN]
fr = m.CATALOG["fr"]
print("catalog", sorted(fr) == sorted(src), all(fr[s] and fr[s] != s and fr[s].count("%s") == s.count("%s") for s in src),
      m.tr(m.REOPEN, m.locale_names({"LANG": "fr_FR.UTF-8"})), m.tr(m.REOPEN, m.locale_names({"LANG": "C"})),
      m.tr(m.REOPEN, m.locale_names({"LANG": "de_DE.UTF-8"})), m.tr(m.REOPEN, m.locale_names({"LC_ALL": "en_US", "LANG": "fr"})),
      m.tr(m.REOPEN, m.locale_names({"GRASSFIELD_LANG": "fr", "LANG": "en_US.UTF-8"})), m.locale_names({"LANG": "fr_CA.UTF-8@euro"}))

# Sending, with the stubs on PATH.
os.environ["PATH"] = tmp + "/bin:" + os.environ["PATH"]
log = tmp + "/log"; os.environ["FAKE_LOG"] = log
def reset(answer="", sleep=""):
    open(log, "w").close(); os.environ["FAKE_ANSWER"] = answer
    if sleep: os.environ["FAKE_SLEEP"] = sleep
    else: os.environ.pop("FAKE_SLEEP", None)
def drive(w, limit=8.0):
    t0 = time.monotonic()
    while w.busy() and time.monotonic() - t0 < limit:
        w.step(time.monotonic()); time.sleep(0.05)
def jobinfo(name, desktop_id, key=None): return {"info": {"name": name, "key": key or name, "desktop_id": desktop_id, "signal": "SIGSEGV"}, "at": 1.0, "key": key or name, "attempts": 0, "ready": 0.0}
def logged(): return open(log).read().splitlines()
# The id of a notice belongs to the server that showed it: closed by id only while the same server owns the name.
ownerfile = tmp + "/owner"; os.environ["FAKE_OWNER_FILE"] = ownerfile
def wait_ends(owner_after, owner_before=":1.7"):
    m.WAIT_SECONDS = 0.8
    open(ownerfile, "w").write(owner_before) if owner_before else (os.path.exists(ownerfile) and os.remove(ownerfile))
    reset("", "5"); w = m.Watcher(uid, env_en)
    w.send(jobinfo("Spotify", "spotify.desktop"), time.monotonic())
    time.sleep(0.2)
    open(ownerfile, "w").write(owner_after) if owner_after else (os.path.exists(ownerfile) and os.remove(ownerfile))
    drive(w, 4.0)
    return len(w.waiting), any(x.startswith("gdbus call") and "CloseNotification 42" in x for x in logged())
print("owner", wait_ends(":1.7"), wait_ends(":1.9"), wait_ends(None), wait_ends(":1.7", ":1.5"))
m.WAIT_SECONDS = 600.0
if mode == "owner":
    sys.exit(0)
# SS-05: no server owns org.freedesktop.Notifications: nothing is sent (notify-send would start another daemon by D-Bus
# activation); the notice is retried and shown once the shell's server is there.
os.path.exists(ownerfile) and os.remove(ownerfile)
reset(""); w = m.Watcher(uid, env_en); w.ledger.reserve("Spotify", 1.0); w.send(jobinfo("Spotify", None), time.monotonic())
before = sum(x.startswith("notify-send") for x in logged()); pending = len(w.sending)
open(ownerfile, "w").write(":1.7"); drive(w, 4.0)
print("no-server", before, pending, sum(x.startswith("notify-send") for x in logged()))
reset("reopen"); w = m.Watcher(uid, env_fr); w.send(jobinfo("Spotify", "spotify.desktop"), time.monotonic()); drive(w); l = logged()
print("reopen", len(l), "-p -w -A reopen=Rouvrir" in l[0], "« Spotify » a quitt" in l[0], "(SIGSEGV)" in l[0], l[1].startswith("systemd-run --user --collect --quiet -- ") and l[1].endswith("uwsm-app -- spotify.desktop"))
reset(""); w = m.Watcher(uid, env_en); w.send(jobinfo("Spotify", "spotify.desktop"), time.monotonic()); drive(w); l = logged()
print("dismissed", len(l), "Spotify quit unexpectedly" in l[0])
reset("reopen"); w = m.Watcher(uid, env_en); w.send(jobinfo("qml", None), time.monotonic()); drive(w); l = logged()
print("no-entry", len(l), " -w " in l[0], " -A " in l[0])
reset("reopen"); w = m.Watcher(uid, env_en); w.send(jobinfo("Spotify", "bad id; rm"), time.monotonic()); drive(w); l = logged()
print("bad-id", len(l), any("systemd-run" in x for x in l))
# At most MAX_WAITING notices wait for a click; the third is shown without the button (and nothing is lost).
reset("", "2"); w = m.Watcher(uid, env_en)
for i in range(3): w.send(jobinfo("App%d" % i, "app%d.desktop" % i), time.monotonic())
l = logged(); print("max-waiting", len(w.waiting), len(l), sum(" -w " in x for x in l))
drive(w)
# No answer: after the wait the notice is closed by its id (no dead button) and the process is gone.
m.WAIT_SECONDS = 0.6
reset("", "5"); w = m.Watcher(uid, env_en); w.send(jobinfo("Spotify", "spotify.desktop"), time.monotonic()); drive(w, 3.0); l = logged()
print("wait-ends", len(w.waiting), any(x.startswith("gdbus call") and "CloseNotification 42" in x for x in l))
# A notify-send that cannot be started is retried a bounded number of times, then its slot is freed.
m.SEND_ATTEMPTS = 3
saved = os.environ["PATH"]; os.environ["PATH"] = tmp + "/nobin"
w = m.Watcher(uid, env_en); w.ledger.reserve("k", 1.0); w.sending.append(jobinfo("X", None, "k"))
for t in range(100, 110): w.step(float(t))
print("send-fails", len(w.sending), "k" in w.ledger.last)
os.environ["PATH"] = saved
# The loop never waits for a notice: 3 s notify-send, two apps, junk lines: main() is done in under 2 s and both are shown.
fresh()
b = mod(gpu, COREDUMP_CGROUP=CG + "app-Hyprland-foot-77.scope", COREDUMP_USER_UNIT="app-Hyprland-foot-77.scope", COREDUMP_EXE="/usr/bin/foot")
open(tmp + "/journal", "w").write(json.dumps(gpu) + "\nnot json\n" + json.dumps(b) + "\n[]\n")
os.environ["FAKE_JOURNAL"] = tmp + "/journal"; reset("", "3")
t0 = time.monotonic(); rc = m.main(); elapsed = time.monotonic() - t0
time.sleep(1.0)
print("loop", rc, elapsed < 2.0, sum(x.startswith("notify-send") for x in logged()))
PY
decisions() { python3 -I "$tmp/test.py" "$root" "$tmp" "$1" "${2:-decisions}" 2>&1 || true; }
out=$(python3 -I "$tmp/test.py" "$root" "$tmp" "$helper" all 2>&1) || { echo "$out"; echo "FAIL: the crash-watch test program ran"; exit 1; }
has() { grep -qxF -- "$1" <<<"$out"; }

# The decision lines every mutant must break.
expect=(
  "case terminal-child None" "case helper None"
  "case quit-gone ('Spotify', 'spotify.desktop', 'spotify.desktop')" "case quit-empty ('Spotify', 'spotify.desktop', 'spotify.desktop')"
  "case quit-late ('Spotify', 'spotify.desktop', 'spotify.desktop')" "case too-late None" "case unknown None" "case unreadable None"
  "case shell-service None" "case portal-service None" "case login-scope None" "case other-users-scope None"
  "case forged-exe None" "case forged-unit None" "case forged-no-trusted None" "case forged-id None" "case other-coredump-uid None"
  "case uid-is-coredump-uid ('Spotify', 'spotify.desktop', 'spotify.desktop')" "case not-app-slice None" "case unit-mismatch None" "case dotdot None"
  "bad none-announced" "pending-after 0 0"
  "case no-exe ('Spotify', 'spotify.desktop', 'spotify.desktop')" "case no-exe-user-unit None" "case no-exe-no-unit None" "case foreign-exe None"
  "chromium ('Chromium', 'chromium.desktop', 'chromium.desktop') ('Chromium fr', 'chromium.desktop', 'chromium.desktop') ('other-bin', 'other-bin', None)"
  "no-tree [] 0 unknown" "tree gone" "flatpak-path True True ('org.f.App.desktop', 'Flat App')"
  "events-not-utf8 unknown" "events-no-value unknown" "events-blank-value unknown" "events-long empty" "events-oversized unknown"
  "events-late-garbage populated" "events-frozen-first populated" "events-directory unknown"
)
expect_owner=("owner (0, True) (0, False) (0, False) (0, False)")
desc="a command run from a terminal (qml --version in foot, real dump 128224): the terminal's scope is populated, no notice"
check has "case terminal-child None"
desc="a helper of a running app (Spotify GPU process, real dump 2602): no notice while the scope holds processes, also not once the wait is over"
check has "case helper None"
check has "case too-late None"
desc="the application quit: scope gone, scope empty, scope emptied within the wait: one notice named by its entry"
check has "case quit-gone ('Spotify', 'spotify.desktop', 'spotify.desktop')"
check has "case quit-empty ('Spotify', 'spotify.desktop', 'spotify.desktop')"
check has "case quit-late ('Spotify', 'spotify.desktop', 'spotify.desktop')"
desc="an unreadable or unknown scope state is silence"
check has "case unknown None"
check has "case unreadable None"
desc="services (the shell: this boot's 37 dumps, a portal), login-session scopes and other users' scopes give no notice even when gone"
check bash -c 'for c in shell-service portal-service login-scope other-users-scope; do grep -qxF "case $c None" <<<"$1" || exit 1; done' _ "$out"
desc="entries not written by systemd-coredump (forged _EXE, unit, id, or no trusted field) and other users' dumps give no notice; the user is COREDUMP_UID"
check bash -c 'for c in forged-exe forged-unit forged-no-trusted forged-id other-coredump-uid; do grep -qxF "case $c None" <<<"$1" || exit 1; done' _ "$out"
check has "case uid-is-coredump-uid ('Spotify', 'spotify.desktop', 'spotify.desktop')"
desc="a cgroup outside app.slice, with a unit that does not match COREDUMP_USER_UNIT, or with .. is not an app scope"
check bash -c 'for c in not-app-slice unit-mismatch dotdot; do grep -qxF "case $c None" <<<"$1" || exit 1; done' _ "$out"
desc="unknown or malformed fields (a superscript digit, lists, None, ints) never announce and never raise"
check has "bad none-announced"
desc="an entry without _EXE is trusted by its systemd-coredump unit; a user-manager unit, no unit, or another _EXE is refused"
check has "case no-exe ('Spotify', 'spotify.desktop', 'spotify.desktop')"
check bash -c 'for c in no-exe-user-unit no-exe-no-unit foreign-exe; do grep -qxF "case $c None" <<<"$1" || exit 1; done' _ "$out"
desc="Chromium-based apps (scope named after the application id, no such desktop file): the crashed binary finds the entry; unknown stays the program name"
check has "chromium ('Chromium', 'chromium.desktop', 'chromium.desktop') ('Chromium fr', 'chromium.desktop', 'chromium.desktop') ('other-bin', 'other-bin', None)"
desc="a missing cgroup2 tree is unknown (silence), a tree without the scope is gone"
check has "no-tree [] 0 unknown"
check has "tree gone"
desc="a cgroup.events file that is not the kernel's (not UTF-8, 'populated' without a value, over 64 KiB, a directory) is unknown, never an exception; a long one is still read, the populated line decides wherever it is"
check bash -c 'for c in "events-not-utf8 unknown" "events-no-value unknown" "events-blank-value unknown" "events-long empty" "events-oversized unknown" "events-late-garbage populated" "events-frozen-first populated" "events-directory unknown"; do grep -qxF "$c" <<<"$1" || exit 1; done' _ "$out"
desc="the Flatpak user installation is XDG_DATA_HOME/flatpak/exports/share (no '..'), and its entries are found"
check has "flatpak-path True True ('org.f.App.desktop', 'Flat App')"
desc="the Dock's scopes (the binary's name) resolve: by id, by Exec binary (nautilus, grassfield-files), by StartupWMClass; localized"
check has "by-id ('Spotify', 'spotify.desktop', 'spotify.desktop') ('Spotify fr', 'spotify.desktop', 'spotify.desktop') ('Foot', 'foot.desktop', 'foot.desktop')"
check has "by-exec ('Files (Nautilus)', 'org.gnome.Nautilus.desktop', 'org.gnome.Nautilus.desktop') ('Fichiers', 'org.gnome.Nautilus.desktop', 'org.gnome.Nautilus.desktop') ('Grassfield Files', 'grassfield-files.desktop', 'grassfield-files.desktop')"
check has "by-wm-class ('Files (Nautilus)', 'org.gnome.Nautilus.desktop', 'org.gnome.Nautilus.desktop') ('Wm Class', 'wmc.desktop', 'wmc.desktop')"
desc="several entries for one binary: the generic one (LibreOffice); none generic (gimp), hidden entries, subdirectory ids: the program's name, no Reopen"
check has "shared ('LibreOffice', 'libreoffice-startcenter.desktop', 'libreoffice-startcenter.desktop') ('gimp', 'gimp', None) ('Part', 'kde-part.desktop', 'kde-part.desktop') ('hidden', 'hidden', None)"
desc="no entry: the executable's name, no Reopen; Flatpak ids with dashes (plain or escaped) resolve"
check has "unknown-app ('nosuch', 'nosuch', None) ('script', 'script', None)"
check has "flatpak ('My App', 'org.x.My-App.desktop', 'org.x.My-App.desktop') ('My App', 'org.x.My-App.desktop', 'org.x.My-App.desktop')"
desc="scope names: escaped dashes, launcher optional, Flatpak with dashes, non-scopes refused; ids that are not plain names are never looked up"
check has "scope-names ('Hyprland', 'gtk-launch') ('', 'foo') ('flatpak', 'org.x.My-App') None None None"
check has "traversal [None, None, None, None, None, None]"
desc="dedupe key is the desktop id or the program: two gtk-launch scopes of different programs both announced, one program once"
check has "dedupe-keys ['alpha', 'beta', 'spotify.desktop']"
desc="dedupe: one per application per 10 minutes, again after; a failed delivery frees its slot; at most 6 an hour in all, the window slides"
check has "ledger True False False True"
check has "release True"
check has "cap [True, True, True, True, True, True, False, False] True"
check has "under_cap False True True"
desc="strings: fr catalog complete and different from the source, same placeholders; language from GRASSFIELD_LANG, LC_ALL, LANG; C and unknown stay English"
check has "catalog True True Rouvrir Reopen Reopen Reopen Rouvrir ['fr_CA@euro', 'fr_CA', 'fr@euro', 'fr']"
desc="Reopen: translated action with a known entry; the click starts uwsm-app in a transient unit; no click, no start; no entry or a bad id, no action"
check has "reopen 2 True True True True"
check has "dismissed 1 True"
check has "no-entry 1 False False"
check has "bad-id 1 False"
desc="at most 2 notices wait for a click (4 tasks each); the third is shown without the button; the wait ends by closing the notice by id"
check has "max-waiting 2 3 2"
check has "wait-ends 0 True"
desc="the notice is closed by id only while the server that showed it still owns the name (not after a restart, not when unknown)"
check has "owner (0, True) (0, False) (0, False) (0, False)"
desc="SS-05: with no notification server on the bus nothing is sent (no D-Bus activation of another daemon); the notice is retried and shown once the server is there"
check has "no-server 0 1 1"
desc="a notify-send that cannot start is retried a bounded number of times, then the dedupe slot is freed"
check has "send-fails 0 False"
desc="the loop is not blocked by notices that wait for a click (3 s notify-send, two apps, junk lines: done in under 2 s, both shown)"
check has "loop 1 True 2"

# Mutation tests: every mutant of a rule must make the decisions fail.
mutate() { # name, text to replace, replacement, optional mode (decisions | owner)
  local name=$1 dest=$tmp/mutant-$1 mode=${4:-decisions}
  # A pattern the helper no longer holds is a failure of the test, never a silent pass: the mutant file was not written,
  # the decisions could not run, and nothing matched (ignore-populated-flag went stale that way; the integrator's merge
  # review of #62).
  python3 -I - "$helper" "$dest" "$2" "$3" <<'PY' || { echo "MUTANT PATTERN NOT FOUND: $name" >&2; return 1; }
import sys
src, dest, old, new = sys.argv[1:5]
text = open(src).read()
assert old in text, old
open(dest, "w").write(text.replace(old, new, 1))
PY
  local result
  result=$(decisions "$dest" "$mode")
  local -n lines=expect
  [[ $mode == owner ]] && local -n lines=expect_owner
  for e in "${lines[@]}"; do grep -qxF -- "$e" <<<"$result" || return 0   # a decision line differs: the mutant is caught
  done
  echo "MUTANT SURVIVED: $name" >&2
  return 1
}
desc="mutation: a pattern the helper no longer holds fails the test instead of passing silently"
if mutate pattern-gone "NO SUCH TEXT IN THE HELPER" "x" 2>/dev/null; then stale=1; else stale=0; fi
check test "$stale" -eq 0
while IFS='|' read -r name old new mode; do
  desc="mutation: $name is caught"
  check mutate "$name" "$old" "$new" "$mode"
done <<'EOF'
drop-trusted-check|not isinstance(entry, dict) or not trusted(entry)|not isinstance(entry, dict)
drop-exe-check|(exe == "" or exe in COREDUMP_EXES)|True
exe-absent-refused|exe == "" or |
drop-unit-check|text_of(entry.get("_SYSTEMD_UNIT")).startswith("systemd-coredump@") and |True and 
drop-message-id-check|and text_of(entry.get("MESSAGE_ID")) == COREDUMP_MESSAGE_ID|and True
drop-app-slice-check|user@%d.service/app.slice/"|user@%d.service/"
drop-user-check|number(entry.get("COREDUMP_UID")) != uid or|False or
drop-emptied-check|if state in ("gone", "empty"):|if True:
populated-counts-as-quit|if state in ("gone", "empty"):|if state in ("gone", "empty", "populated"):
unknown-counts-as-quit|if state in ("gone", "empty"):|if state in ("gone", "empty", "unknown"):
no-deadline|elif now >= item["deadline"]:|elif False:
ignore-populated-flag|{"0": "empty", "1": "populated"}.get(words[1], "unknown")|"empty"
dir-without-events-is-gone|if os.path.isdir(base) or not os.path.isfile(|if not os.path.isfile(
missing-tree-is-gone|if os.path.isdir(base) or not os.path.isfile((root or CGROUP_ROOT) + "/cgroup.controllers"):|if os.path.isdir(base):
drop-exe-fallback|if found is None and cand["exe"] != cand["appid"]:|if False:
flatpak-path-reverted|os.path.join(home, "flatpak/exports/share")|os.path.join(home, "../flatpak/exports/share")
drop-owner-check|if notice_id and owner and server_owner() == owner:|if notice_id:|owner
owner-not-recorded|self.owner = server_owner()  # who showed it: ids are only good for that server|self.owner = ":1.7"|owner
drop-unit-match|text_of(entry.get("COREDUMP_USER_UNIT")).strip() not in ("", unit)|False
drop-exec-index|appid in (binary, os.path.basename(keys.get("TryExec", ""))) or|False or
drop-generic-rule|shown = [m for m in shown if m[2]]|shown = shown
unicode-digits|re.fullmatch(r"[0-9]{1,10}", v)|v.isdigit()
dedupe-by-appid|"key": found[0] if found else cand["exe"]|"key": cand["appid"]
scope-strict-decode|with open(base + "/cgroup.events", encoding="utf-8", errors="replace") as f:|with open(base + "/cgroup.events", encoding="utf-8", errors="strict") as f:
scope-no-oserror|    except (OSError, ValueError):|    except ValueError:
scope-any-line|if len(words) >= 2 and words[0] == "populated":|if len(words) >= 2:
scope-unbounded-read|for line in f.read(65536).splitlines():|for line in f.read().splitlines():
EOF

exit $fail
