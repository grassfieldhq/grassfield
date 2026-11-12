#!/usr/bin/env bash
# grassfield-update-check (ADR-0033 d; docs/specs/updates.md U1-U6, acceptance A7f, A7h, A8): states, the [grassfield]-only
# sync and `blocking` after two failures 15 minutes apart (fake clock), a Server change dropping only its own [grassfield]
# files, a stale db.lck removed, the 180 s stop of a hung child group, its own lock (`busy`), Omarchy's update lock
# (`update-running`) and the waiter that checks once it is released, the release notes (the signer is VALIDSIG's
# argument 10; trusted, not revoked; size, JSON, channel, length, control characters; https only unless this build's base
# is file://), and the counts (grassfield-* packages are not "others").
# Nothing here touches pacman: pacman-conf, pacman, fakeroot, checkupdates, vercmp and gpgv are stubs on PATH (real gpgv
# signatures are checked by tests/integration/software_update.sh in a throwaway container); curl is the real one, on
# file:// URLs. As root, the checker refuses (exit 2); the cases that run it as a whole are then only the refusal.
set -euo pipefail
# Not git alone: tests/integration/software_update.sh mounts a worktree's files at /src, and its .git file points at a path the
# container does not have.
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/update-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
command -v curl >/dev/null || { echo "SKIP: curl is not installed"; exit 0; }

mkdir -p "$tmp/bin" "$tmp/state"
# pacman-conf: --repo-list from state/repo-list (exit 1 when state/conf-broken exists), GPGDir, the expanded Servers.
cat >"$tmp/bin/pacman-conf" <<'SH'
#!/bin/sh
PATH=/usr/bin:/bin
[ -e "$FAKE/conf-broken" ] && { echo "error: config file could not be read" >&2; exit 1; }
case "$*" in
  --repo-list) cat "$FAKE/repo-list" ;;
  GPGDir) echo /nonexistent/gnupg/ ;;
  "--repo grassfield Server") cat "$FAKE/servers-expanded" ;;
  *) exit 1 ;;
esac
SH
# fakeroot -- pacman -Sy …: the [grassfield]-only sync; its arguments are logged; fails when state/health-fail exists.
cat >"$tmp/bin/fakeroot" <<'SH'
#!/bin/sh
PATH=/usr/bin:/bin
echo "$*" >>"$FAKE/fakeroot.log"
[ -e "$FAKE/health-fail" ] && { echo "error: failed to synchronize all databases (unexpected error)" >&2; exit 1; }
exit 0
SH
# checkupdates: state/updates (exit 0, or 2 when empty); a db.lck in CHECKUPDATES_DB makes it fail as the real one does;
# state/checkupdates-sleep makes it hang (its pid in state/checkupdates.pid).
cat >"$tmp/bin/checkupdates" <<'SH'
#!/bin/sh
PATH=/usr/bin:/bin
echo "$CHECKUPDATES_DB" >"$FAKE/checkupdates.db"
if [ -e "$FAKE/checkupdates-sleep" ]; then echo $$ >"$FAKE/checkupdates.pid"; exec sleep 60; fi
[ -e "$CHECKUPDATES_DB/db.lck" ] && { echo "==> ERROR: Cannot fetch updates" >&2; exit 1; }
[ -e "$FAKE/checkupdates-fail" ] && { echo "==> ERROR: Cannot fetch updates" >&2; exit 1; }
[ -s "$FAKE/updates" ] || exit 2
cat "$FAKE/updates"
SH
# pacman -Q <name> from state/installed; pacman … -Sql grassfield from state/grassfield-names.
cat >"$tmp/bin/pacman" <<'SH'
#!/bin/sh
PATH=/usr/bin:/bin
case "$*" in
  "-Q "*) line=$(grep "^$2 " "$FAKE/installed") || exit 1; echo "$line" ;;
  *"-Sql grassfield") cat "$FAKE/grassfield-names" ;;
  *) exit 1 ;;
esac
SH
# vercmp for the plain versions used here (sort -V orders them as pacman does).
cat >"$tmp/bin/vercmp" <<'SH'
#!/bin/sh
PATH=/usr/bin:/bin
[ "$1" = "$2" ] && { echo 0; exit 0; }
[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ] && echo -1 || echo 1
SH
# gpgv: exit state/gpgv-rc (default 0) and one VALIDSIG whose argument 10 is state/signer (argument 1 a subkey).
cat >"$tmp/bin/gpgv" <<'SH'
#!/bin/sh
PATH=/usr/bin:/bin
rc=$(cat "$FAKE/gpgv-rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] && echo "[GNUPG:] VALIDSIG 1111111111111111111111111111111111111111 2026-10-27 1793000000 0 4 0 22 10 00 $(cat "$FAKE/signer")"
exit "$rc"
SH
chmod +x "$tmp/bin"/*

cat >"$tmp/test.py" <<'PY'
import fcntl, importlib.machinery, importlib.util, json, os, shutil, signal, subprocess, sys, time
sys.dont_write_bytecode = True  # no __pycache__ in packaging/bin (it would be packaged)
root, tmp = sys.argv[1:3]
helper = root + "/packaging/bin/grassfield-update-check"
loader = importlib.machinery.SourceFileLoader("checker", helper)
spec = importlib.util.spec_from_loader("checker", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
S = tmp + "/state"
os.environ["FAKE"] = S
os.environ["PATH"] = tmp + "/bin:" + os.environ["PATH"]
GOOD, ROGUE, OLD = "A" * 40, "B" * 40, "C" * 40
SRV = tmp + "/srv"
fails = 0

def check(desc, ok, detail=""):
    global fails
    print(("PASS: " if ok else "FAIL: ") + desc + ("" if ok else "  [" + str(detail)[:400] + "]"))
    fails += 0 if ok else 1

def put(name, text):
    with open(os.path.join(S, name), "w") as f: f.write(text)

def rm(name):
    try: os.unlink(os.path.join(S, name))
    except FileNotFoundError: pass

def setup(base="file://" + SRV, server=None, listed=True, conf=True, sections=None, keep_cache=False):
    shutil.rmtree(S, ignore_errors=True); os.makedirs(S)
    if not keep_cache:
        shutil.rmtree(tmp + "/cache", ignore_errors=True)
    os.makedirs(tmp + "/keyring", exist_ok=True)
    m.REPOSITORY_CONF = tmp + "/repository.conf"
    m.GRASSFIELD_CONF = tmp + "/grassfield.conf"
    m.PACMAN_CONF = tmp + "/pacman.conf"
    n = (1 if listed else 0) if sections is None else sections
    with open(m.PACMAN_CONF, "w") as f:
        f.write("[options]\n[core]\nInclude = /etc/pacman.d/mirrorlist\n" + "\n[grassfield]  # Software Update\nInclude = x\n" * n)
    m.KEYRING_DIR = tmp + "/keyring"
    with open(m.REPOSITORY_CONF, "w") as f:
        f.write("GRASSFIELD_REPO_BASE=%s\nGRASSFIELD_REPO_MIRRORS=\nGRASSFIELD_REPO_BASE_PREVIOUS=\n"
                "GRASSFIELD_SIGNING_FINGERPRINT=%s\n" % (base, GOOD))
    server = server or base + "/stable/$arch"
    if conf:
        with open(m.GRASSFIELD_CONF, "w") as f: f.write("SigLevel = Required\nServer = %s  # primary\n" % server)
    elif os.path.exists(m.GRASSFIELD_CONF):
        os.unlink(m.GRASSFIELD_CONF)
    put("repo-list", "core\nextra\nomarchy\n" + ("grassfield\n" if listed else ""))
    put("servers-expanded", server.replace("$arch", "x86_64") + "\n")
    put("installed", "grassfield-desktop 1.0.0-1\nomarchy 4.0.4-1\n")
    put("grassfield-names", "grassfield-desktop\ngrassfield-compositor\ngrassfield-icons\ngrassfield-keyring\n")
    put("updates", "")
    put("signer", GOOD)
    with open(tmp + "/keyring/grassfield-trusted", "w") as f: f.write(GOOD + ":4:\n" + OLD + ":4:\n")
    with open(tmp + "/keyring/grassfield-revoked", "w") as f: f.write(OLD + "\n")
    open(tmp + "/keyring/grassfield.gpg", "w").close()

def notes(releases, channel="stable", raw=None):
    d = SRV + "/stable/x86_64"
    os.makedirs(d, exist_ok=True)
    data = raw if raw is not None else json.dumps({"version": 1, "channel": channel, "releases": releases}).encode()
    with open(d + "/grassfield-notes.json", "wb") as f: f.write(data)
    with open(d + "/grassfield-notes.json.sig", "wb") as f: f.write(b"sig")

def run(now=1793000000, offline=False, seconds=None):
    c = m.Checker(tmp + "/cache/grassfield", offline, now=now, children=m.Children(seconds) if seconds else None)
    return c.run()

R101 = {"version": "1.0.1-1", "date": "2026-11-02", "notes": {"en": "Fixes.\n\tTabbed\x1b[31m red‮", "fr": "Corrections."}}
R100 = {"version": "1.0.0-1", "date": "2026-10-30", "notes": {"en": "First."}}
R102 = {"version": "1.0.2-1", "date": "2026-11-09", "notes": {"en": "Later."}}

# -- states
setup(listed=False, conf=False); r = run()
check("no [grassfield] and no file -> not-set-up", r["state"] == "not-set-up" and r["channel"] is None, r)
# Turned off (or never set up): the system's updates are still listed, without any [grassfield] sync (integrator decision
# of 2026-10-28: macOS always offers its system updates; ADR-0033 "Step 2 as built").
setup(listed=False, conf=False)
put("updates", "omarchy 4.0.4-1 -> 4.0.6-1\nlinux 6.18.1-1 -> 6.18.2-1\ngrassfield-desktop 1.0.0-1 -> 1.0.1-1\n")
r = run()
check("not-set-up lists Omarchy's release and the other updates",
      r["state"] == "not-set-up" and r["omarchy"]["available"] == "4.0.6-1" and r["others"] == 1
      and [p["name"] for p in r["otherPackages"]] == ["linux"] and r["lastSuccessAt"] is not None, r)
check("not-set-up: no [grassfield] sync, no Grassfield release, no notes fetched", not os.path.exists(S + "/fakeroot.log")
      and r["grassfield"]["available"] is None and r["grassfield"]["notes"] == [], r)
# A blocking episode, then Turn Off…, then Set Up… a month later: the first failure starts a new count (integrator re-review
# of 5ae52b1, minor 2).
T = 1793000000
setup(); put("health-fail", ""); run(now=T); r = run(now=T + 16 * 60)
check("two failures 16 minutes apart -> blocking (the episode before Turn Off…)", r["state"] == "blocking", r)
failure_count = tmp + "/cache/grassfield/health-db/failures"
setup(listed=False, conf=False, keep_cache=True); r = run(now=T + 20 * 60)
check("Turn Off… (not-set-up) forgets the failure count", r["state"] == "not-set-up" and not os.path.exists(failure_count), r)
setup(keep_cache=True); put("health-fail", ""); r = run(now=T + 30 * 86400)
check("Set Up… a month later: its first sync failure is failed with a retry, not blocking",
      r["state"] == "failed" and r["episode"] is None and r["retryAt"] is not None, r)
setup(listed=False, conf=False); put("checkupdates-fail", ""); r = run()
check("not-set-up, checkupdates failing -> failed (not counted towards blocking)",
      r["state"] == "failed" and r["error"] == "unavailable" and r["episode"] is None and r["retryAt"] is None, r)
setup(listed=False, conf=False); put("checkupdates-fail", ""); r = run(offline=True)
check("not-set-up, offline -> failed/offline", r["state"] == "failed" and r["error"] == "offline", r)
setup(listed=False); r = run()
check("the file without the [grassfield] lines -> repair (channel read from the file)", r["state"] == "repair" and r["channel"] == "stable", r)
setup(); put("conf-broken", ""); r = run()
check("pacman's configuration unreadable -> failed/unavailable, no crash", r["state"] == "failed" and r["error"] == "unavailable", r)
setup(conf=False); put("conf-broken", ""); r = run()
check("the [grassfield] lines without their file (every pacman command fails) -> repair, not failed", r["state"] == "repair", r)
setup(sections=2); put("conf-broken", ""); r = run()
check("[grassfield] twice (pacman: already registered) -> repair", r["state"] == "repair" and r["channel"] == "stable", r)
setup(server="https://elsewhere.example/grassfield/$arch"); r = run()
check("a Server that is not <base>/<channel>/$arch -> channel custom", r["channel"] == "custom", r)
setup(server="file://" + SRV + "/beta/$arch"); r = run()
check("<base>/beta/$arch -> channel beta, up-to-date", r["channel"] == "beta" and r["state"] == "up-to-date", r)
check("checkupdates got the checker's own database folder", open(S + "/checkupdates.db").read().strip() == tmp + "/cache/grassfield/checkup-db")
log = open(S + "/fakeroot.log").read()
check("the [grassfield]-only sync: fakeroot pacman -Sy, own config and database, checkupdates' sandbox flag",
      "-- pacman -Sy --disable-sandbox-filesystem --config " + tmp + "/cache/grassfield/health-db/health.conf --dbpath "
      + tmp + "/cache/grassfield/health-db --logfile /dev/null" in log, log)
hc = open(tmp + "/cache/grassfield/health-db/health.conf").read()
check("its config: [options] and the Include only, no DisableSandbox", "Include = " + tmp + "/grassfield.conf" in hc
      and "DisableSandbox" not in hc and "[grassfield]" in hc, hc)
check("a success records lastSuccessAt", r["lastSuccessAt"] == m.iso(1793000000), r)

# -- counts and notes
setup(); notes([R102, R101, R100])
put("updates", "grassfield-desktop 1.0.0-1 -> 1.0.1-1\ngrassfield-icons 1.0.0-1 -> 1.0.1-1\nomarchy 4.0.4-1 -> 4.0.6-1\nlinux 6.18.1-1 -> 6.18.2-1\n")
r = run()
gf = r["grassfield"]
check("available: Grassfield 1.0.0-1 -> 1.0.1-1, Omarchy 4.0.4-1 -> 4.0.6-1",
      r["state"] == "available" and (gf["installed"], gf["available"]) == ("1.0.0-1", "1.0.1-1")
      and (r["omarchy"]["installed"], r["omarchy"]["available"]) == ("4.0.4-1", "4.0.6-1"), r)
check("others: linux only (grassfield-icons belongs to the Grassfield release)", r["others"] == 1, r)
check("otherPackages: the list behind the count, with its versions", r["otherPackages"] == [
      {"name": "linux", "installed": "6.18.1-1", "available": "6.18.2-1"}] and "otherPackagesTruncated" not in r, r)
check("notes: only the releases above the installed one and up to the available one", [n["version"] for n in gf["notes"]] == ["1.0.1-1"], gf)
check("notes: control and bidirectional characters removed, line feeds kept, fr kept",
      gf["notes"] and gf["notes"][0]["notes"] == {"en": "Fixes.\nTabbed[31m red", "fr": "Corrections."}, gf)
setup(); put("updates", "grassfield-desktop 1.0.0-1 -> 1.0.2-1\n"); notes([R101, R102])
r = run()
check("notes newest first", [n["version"] for n in r["grassfield"]["notes"]] == ["1.0.2-1", "1.0.1-1"], r)
check("omarchy installed but not updated -> no Omarchy release", r["omarchy"]["available"] is None and r["omarchy"]["installed"] == "4.0.4-1", r)

setup(); put("updates", "zstd 1.5.6-1 -> 1.5.7-1\nomarchy-dev 4.0.4-1 -> 4.0.6-1\nglibc 2.42-1 -> 2.42-2\ngrassfield-store 1.0.0-1 -> 1.0.1-1\n")
r = run()
check("otherPackages sorted by name; omarchy-dev (not installed) is another package; grassfield-* never listed",
      [p["name"] for p in r["otherPackages"]] == ["glibc", "omarchy-dev", "zstd"] and r["others"] == 3, r)

# -- the 256 KiB cap (ADR-0033 d.3.5): the list of other updates is cut first, then the notes; the counts stay
def emitted(result):
    import contextlib, io
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        m.emit(result)
    text = out.getvalue()
    return len(text.encode("utf-8")), json.loads(text)
def big(packages, notes):
    pkgs = [{"name": "package-%05d-%s" % (i, "x" * 40), "installed": "1.0-1", "available": "1.1-1"} for i in range(packages)]
    rel = [{"version": "1.0.%d-1" % i, "date": "2026-11-02", "notes": {"en": "e" * 8000, "fr": "f" * 8000}} for i in range(notes)]
    return {"version": 1, "state": "available", "grassfield": {"installed": "1.0.0-1", "available": "1.0.9-1", "notes": rel,
            "notesError": None}, "omarchy": {"installed": None, "available": None}, "others": packages, "otherPackages": pkgs}
n, out = emitted(big(100, 2))
check("under the cap: nothing cut", out["others"] == 100 and len(out["otherPackages"]) == 100 and len(out["grassfield"]["notes"]) == 2
      and "otherPackagesTruncated" not in out, n)
n, out = emitted(big(5000, 2))
check("a long list: cut first, flagged; notes and counts kept; the line within 256 KiB (%d bytes)" % n,
      n <= m.OUTPUT_CAP and out["otherPackagesTruncated"] is True and 0 < len(out["otherPackages"]) < 5000
      and out["otherPackages"][0]["name"].startswith("package-00000") and out["others"] == 5000
      and len(out["grassfield"]["notes"]) == 2 and out["grassfield"]["notesError"] is None, (n, len(out["otherPackages"])))
n, out = emitted(big(10, 20))
check("notes alone past the cap: the notes go (notesError), the whole list stays, not flagged (%d bytes)" % n,
      n <= m.OUTPUT_CAP and out["grassfield"]["notes"] == [] and out["grassfield"]["notesError"] == "unavailable"
      and len(out["otherPackages"]) == 10 and "otherPackagesTruncated" not in out and out["others"] == 10, n)
n, out = emitted(big(5000, 20))
check("both past the cap: notes gone, the list cut to what fits, flagged (%d bytes)" % n,
      n <= m.OUTPUT_CAP and out["grassfield"]["notes"] == [] and out["otherPackagesTruncated"] is True
      and 0 < len(out["otherPackages"]) < 5000 and out["others"] == 5000, n)

def notes_refused(desc, prepare, **where):
    setup(**where); put("updates", "grassfield-desktop 1.0.0-1 -> 1.0.1-1\n"); notes([R101])
    prepare()
    r = run()
    check("notes refused, update still offered: " + desc,
          r["state"] == "available" and r["grassfield"]["notes"] == [] and r["grassfield"]["notesError"] == "unavailable", r)

notes_refused("a rogue signer (VALIDSIG argument 10 not in grassfield-trusted)", lambda: put("signer", ROGUE))
notes_refused("a revoked signer", lambda: put("signer", OLD))
notes_refused("gpgv fails (bad or changed signature)", lambda: put("gpgv-rc", "1"))
notes_refused("larger than 64 KiB", lambda: notes(None, raw=b" " * 65537))
notes_refused("not JSON", lambda: notes(None, raw=b"{"))
notes_refused("not UTF-8", lambda: notes(None, raw=b'{"version":1,"channel":"stable","releases":[],"x":"\xff"}'))
notes_refused("version 2", lambda: notes(None, raw=json.dumps({"version": 2, "channel": "stable", "releases": []}).encode()))
notes_refused("another channel's notes", lambda: notes([R101], channel="beta"))
notes_refused("no en text", lambda: notes([{"version": "1.0.1-1", "date": "2026-11-02", "notes": {"fr": "x"}}]))
notes_refused("a text longer than 8000 characters", lambda: notes([{"version": "1.0.1-1", "date": "2026-11-02", "notes": {"en": "x" * 8001}}]))
notes_refused("more than 20 releases", lambda: notes([R101] * 21))
notes_refused("a malformed version", lambda: notes([{"version": "1.0.1", "date": "2026-11-02", "notes": {"en": "x"}}]))
notes_refused("not published", lambda: os.unlink(SRV + "/stable/x86_64/grassfield-notes.json.sig"))
notes_refused("a file:// Server in a build whose base is https (https only)", lambda: put("signer", GOOD),
              base="https://packages.example", server="file://" + SRV + "/stable/$arch")

# -- U5: a Server change drops only the checker's own [grassfield] files; a stale db.lck goes (A7f)
setup(); run()
c = tmp + "/cache/grassfield"
for db in ("checkup-db", "health-db"):
    os.makedirs(c + "/" + db + "/sync", exist_ok=True)
    for n in ("grassfield.db", "grassfield.db.sig", "extra.db"):
        open(c + "/" + db + "/sync/" + n, "w").close()
open(c + "/checkup-db/db.lck", "w").close()
r = run()
check("a stale db.lck in its own database folder is removed (checkupdates would fail on it)", r["state"] == "up-to-date"
      and not os.path.exists(c + "/checkup-db/db.lck"), r)
check("same Server: its [grassfield] files stay", os.path.exists(c + "/checkup-db/sync/grassfield.db"))
with open(m.GRASSFIELD_CONF, "w") as f: f.write("SigLevel = Required\nServer = file://%s/beta/$arch\n" % SRV)
r = run()
check("the Server changed: its own grassfield.{db,files}{,.sig} dropped, extra.db kept",
      not any(os.path.exists(c + "/" + db + "/sync/grassfield.db" + s) for db in ("checkup-db", "health-db") for s in ("", ".sig"))
      and os.path.exists(c + "/checkup-db/sync/extra.db"), os.listdir(c + "/checkup-db/sync"))

# -- A7h: blocking only after two failures in a row, 15 minutes apart (fake clock)
setup(); put("health-fail", ""); t0 = 1793000000
r = run(now=t0)
check("first [grassfield] failure -> failed/unavailable with retryAt = +15 min, not blocking",
      r["state"] == "failed" and r["error"] == "unavailable" and r["retryAt"] == m.iso(t0 + 900), r)
r = run(now=t0 + 300)
check("a second failure 5 minutes later -> still failed, same retryAt", r["state"] == "failed" and r["retryAt"] == m.iso(t0 + 900), r)
r = run(now=t0 + 900)
check("a failure 15 minutes after the first -> blocking, episode = the first failure", r["state"] == "blocking" and r["episode"] == t0, r)
r = run(now=t0 + 4000)
check("still failing later -> the same episode", r["state"] == "blocking" and r["episode"] == t0, r)
rm("health-fail"); r = run(now=t0 + 5000)
check("a success ends the episode", r["state"] == "up-to-date" and not os.path.exists(c + "/health-db/failures"), r)
put("health-fail", ""); r = run(now=t0 + 6000)
check("after a success, one failure is not blocking again", r["state"] == "failed" and r["retryAt"] == m.iso(t0 + 6900), r)
setup(); put("health-fail", ""); r = run(now=t0, offline=True); r2 = run(now=t0 + 1000, offline=True)
check("offline: failed/offline, never counted towards blocking", r["error"] == "offline" and r2["state"] == "failed"
      and not os.path.exists(c + "/health-db/failures"), (r, r2))
setup(); put("checkupdates-fail", ""); r = run()
check("checkupdates fails after a good [grassfield] sync -> failed/unavailable, not blocking", r["state"] == "failed"
      and r["error"] == "unavailable" and "Cannot fetch updates" in (r["message"] or ""), r)

# -- missing programs (PATH holds only the chosen stubs), a hung child
saved = os.environ["PATH"]
os.makedirs(tmp + "/only", exist_ok=True)
for n in ("pacman-conf", "pacman", "vercmp", "gpgv", "fakeroot"):
    os.symlink(tmp + "/bin/" + n, tmp + "/only/" + n)
os.environ["PATH"] = tmp + "/only"
setup(); r = run()
check("checkupdates missing -> failed/unavailable 'pacman-contrib is not installed'", r["state"] == "failed"
      and r["message"] == "pacman-contrib is not installed", r)
os.unlink(tmp + "/only/fakeroot"); os.symlink(tmp + "/bin/checkupdates", tmp + "/only/checkupdates")
setup(); r = run()
check("fakeroot missing -> failed/unavailable, not counted towards blocking", r["message"] == "fakeroot is not installed"
      and not os.path.exists(c + "/health-db/failures"), r)
os.environ["PATH"] = saved
setup(); put("checkupdates-sleep", ""); start = time.monotonic(); r = run(seconds=2)
pid = int(open(S + "/checkupdates.pid").read())
alive = True
try: os.kill(pid, 0)
except ProcessLookupError: alive = False
check("a hung check is stopped at the deadline (SIGTERM to its process group) -> failed, no crash",
      r["state"] == "failed" and time.monotonic() - start < 10 and not alive, (r, alive))

# -- ADR-0041 step 2b (U31): the toolkit as installed, each package with its install time, the record's version and whether
# it moved by U27's rule
m.BUILD_DEPS = tmp + "/BUILD-DEPS"; m.PACMAN_LOCAL = tmp + "/local"
BUILT = "qt6-base 6.11.2-1\nquickshell 0.3.1-1\nhyprland 0.56.2-1\naquamarine 0.9.3-1\nkcoreaddons 6.20.0-1\n"
def record(text):
    with open(m.BUILD_DEPS, "w") as f: f.write(text)
def desc(name, version, when):
    d = m.PACMAN_LOCAL + "/%s-%s" % (name, version); os.makedirs(d, exist_ok=True)
    with open(d + "/desc", "w") as f:
        f.write("%NAME%\n" + name + "\n\n%VERSION%\n" + version + "\n\n" + ("%INSTALLDATE%\n" + str(when) + "\n\n" if when is not None else "") + "%VALIDATION%\npgp\n\n")
def toolkit_lines(**over):
    base = {"qt6-base": "6.11.2-1", "quickshell": "0.3.1-1", "hyprland": "0.56.2-1", "aquamarine": "0.9.3-1", "kcoreaddons": "6.20.0-1"}
    base.update(over)
    return "grassfield-desktop 1.0.0-1\nomarchy 4.0.4-1\n" + "".join("%s %s\n" % kv for kv in base.items() if kv[1] is not None)
def view(r, *keys):
    return [tuple(p[k] for k in keys) for p in r["toolkit"]["packages"]]
setup(listed=False, conf=False); rm_record = lambda: os.path.exists(m.BUILD_DEPS) and os.unlink(m.BUILD_DEPS); rm_record()
put("installed", toolkit_lines()); r = run()
check("no record: the five packages listed with built and moved null, record false, the state as before",
      r["state"] == "not-set-up" and r["toolkit"]["record"] is False and view(r, "name", "built", "moved") == [(n, None, None) for n in m.TRACKED], r)
record(BUILT); r = run()
check("every tracked package matches its record -> moved false, built as the record says, no install time without a database entry",
      r["toolkit"]["record"] is True and view(r, "name", "installed", "built", "moved", "installedAt") == [(n, v, v, False, None) for n, v in zip(m.TRACKED, BUILT.split()[1::2])], r)
put("installed", toolkit_lines(**{"qt6-base": "6.11.2-3", "hyprland": "0.56.4-1", "kcoreaddons": "6.20.1-2", "aquamarine": "0.9.3-2"})); r = run()
check("a pkgrel or a patch level alone is no move (Qt, Hyprland, aquamarine and KF6 by major.minor), the installed version still listed",
      view(r, "moved") == [(False,)] * 5 and view(r, "installed")[0] == ("6.11.2-3",), r)
shutil.rmtree(m.PACMAN_LOCAL, ignore_errors=True); desc("qt6-base", "6.12.0-1", 1793000500); desc("quickshell", "0.3.2-1", None)
put("installed", toolkit_lines(**{"qt6-base": "6.12.0-1", "quickshell": "0.3.2-1"})); r = run()
check("Qt 6.11 -> 6.12 and Quickshell 0.3.1 -> 0.3.2 (compared whole) moved, with the install time (null without %INSTALLDATE%); the rest not moved",
      view(r, "name", "built", "installed", "moved", "installedAt")[:2] == [("qt6-base", "6.11.2-1", "6.12.0-1", True, m.iso(1793000500)), ("quickshell", "0.3.1-1", "0.3.2-1", True, None)]
      and view(r, "moved")[2:] == [(False,)] * 3, r)
desc("aquamarine", "1:0.9.3-1", 1793000600); put("installed", toolkit_lines(**{"aquamarine": "1:0.9.3-1"})); r = run()
check("an epoch is part of the key (aquamarine 0.9.3 -> 1:0.9.3 moved, dated)", [p["name"] for p in r["toolkit"]["packages"] if p["moved"]] == ["aquamarine"] and view(r, "installedAt")[3] == (m.iso(1793000600),), r)
desc("hyprland", "0.57.0-1", -5); desc("kcoreaddons", "6.21.0-1", 2 ** 50); desc("qt6-base", "6.13.0-1", 253402300800); desc("quickshell", "0.4.0-1", 253402300799)
put("installed", toolkit_lines(**{"hyprland": "0.57.0-1", "kcoreaddons": "6.21.0-1", "qt6-base": "6.13.0-1", "quickshell": "0.4.0-1"})); r = run()
check("an install time outside a four-digit year reads as unknown (null), never a raise; 9999-12-31T23:59:59Z is the last one read",
      view(r, "name", "installedAt") == [("qt6-base", None), ("quickshell", "9999-12-31T23:59:59Z"), ("hyprland", None), ("aquamarine", None), ("kcoreaddons", None)], r)
record("qt6-base 6.11.2-1\nquickshell 0.3.1-1 extra words\n# a comment\nhyprland\naquamarine 0.9.3-1\n")
put("installed", toolkit_lines(**{"kcoreaddons": None})); r = run()
check("a record line outside pacman -Q's grammar is skipped (the helper reads it so) and the package it named reads as moved with built null (fail safe, as the helper refuses); a package pacman does not list is not listed",
      view(r, "name", "built", "moved") == [("qt6-base", "6.11.2-1", False), ("quickshell", None, True), ("hyprland", None, True), ("aquamarine", "0.9.3-1", False)], r)
setup(sections=2); record(BUILT); put("installed", toolkit_lines(**{"qt6-base": "6.12.0-1"})); r = run()
check("the field is in a repair answer too", r["state"] == "repair" and [p["name"] for p in r["toolkit"]["packages"] if p["moved"]] == ["qt6-base"], r)
setup(); put("conf-broken", ""); put("installed", toolkit_lines(**{"qt6-base": "6.12.0-1"})); r = run()
check("...and in a failed one", r["state"] == "failed" and [p["name"] for p in r["toolkit"]["packages"] if p["moved"]] == ["qt6-base"], r)
rm_record(); shutil.rmtree(m.PACMAN_LOCAL, ignore_errors=True)

# -- ADR-0050: the staged rollout's descriptor (schema, bounds, freshness, anti-replay, signature), the reach formula and
# cohort offering, the cohort form of the Server line, and what the checker reports (staged, withdrawn, security)
NOW = 1793000000
ARCH = os.uname().machine
def ramp(start=NOW - 3600, pct=5, hours=168, paused=None):
    r = {"startAt": m.iso(start), "startPercent": pct, "durationHours": hours}
    if paused is not None: r["pausedAt"] = m.iso(paused)
    return r
def desc(releases=None, **over):
    d = {"schema": 1, "channel": "stable", "arch": ARCH, "cohorts": 20, "generatedAt": m.iso(NOW - 60),
         "expiresAt": m.iso(NOW + 7 * 86400),
         "releases": releases if releases is not None else [{"version": "1.0.1-1", "importance": "normal", "state": "rolling", "rollout": ramp()}]}
    d.update(over)
    return d
def parsed(d, seen=None, raw=None):
    try:
        return m.parse_rollout(raw if raw is not None else json.dumps(d).encode(), "stable", ARCH, NOW, seen)
    except m.Stale as e:
        return "stale"
    except ValueError as e:
        return "invalid"
ok = parsed(desc())
check("a well-formed descriptor parses (times as Unix seconds, no pausedAt)", isinstance(ok, dict)
      and ok["releases"][0]["rollout"] == {"startAt": NOW - 3600, "startPercent": 5, "durationHours": 168, "pausedAt": None}, ok)
REL = {"version": "1.0.1-1", "importance": "normal", "state": "rolling", "rollout": ramp()}
for desc_text, d in [
        ("an unknown top-level key", dict(desc(), extra=1)),
        ("a missing top-level key", {k: v for k, v in desc().items() if k != "expiresAt"}),
        ("schema 2", desc(schema=2)), ("schema true", desc(schema=True)), ("schema \"1\"", desc(schema="1")),
        ("another channel", desc(channel="beta")), ("another architecture", desc(arch="aarch64-not-this")),
        ("19 cohorts", desc(cohorts=19)), ("cohorts true", desc(cohorts=True)),
        ("a time without Z", desc(generatedAt="2026-10-27T00:00:00+00:00")), ("an impossible date", desc(generatedAt="2026-02-30T00:00:00Z")),
        ("expiresAt before generatedAt", desc(expiresAt=m.iso(NOW - 120))),
        ("expiresAt 32 days after generatedAt", desc(expiresAt=m.iso(NOW - 60 + 32 * 86400))),
        ("releases not a list", desc(releases={"a": 1})), ("17 releases", desc(releases=[dict(REL, version=f"1.0.{i}-1") for i in range(17)])),
        ("a release with an extra key", desc(releases=[dict(REL, notes="x")])),
        ("a release without rollout", desc(releases=[{k: v for k, v in REL.items() if k != "rollout"}])),
        ("a malformed version", desc(releases=[dict(REL, version="1.0.1")])), ("a version with a newline", desc(releases=[dict(REL, version="1.0.1-1\n")])),
        ("a repeated version", desc(releases=[REL, REL])),
        ("an unknown importance", desc(releases=[dict(REL, importance="critical")])), ("an unknown state", desc(releases=[dict(REL, state="done")])),
        ("a normal rolling release without a ramp", desc(releases=[dict(REL, rollout=None)])),
        ("startPercent 101", desc(releases=[dict(REL, rollout=ramp(pct=101))])), ("startPercent 5.5", desc(releases=[dict(REL, rollout=dict(ramp(), startPercent=5.5))])),
        ("durationHours -1", desc(releases=[dict(REL, rollout=ramp(hours=-1))])), ("durationHours 8761", desc(releases=[dict(REL, rollout=ramp(hours=8761))])),
        ("pausedAt on a rolling release", desc(releases=[dict(REL, rollout=ramp(paused=NOW))])),
        ("a paused release without pausedAt", desc(releases=[dict(REL, state="paused")])),
        ("pausedAt before startAt", desc(releases=[dict(REL, state="paused", rollout=ramp(paused=NOW - 7200))])),
        ("a ramp with an extra key", desc(releases=[dict(REL, rollout=dict(ramp(), reach=1))]))]:
    check("descriptor refused: " + desc_text, parsed(d) == "invalid", parsed(d))
check("descriptor refused: larger than 16 KiB", parsed(None, raw=b" " * 16385 + json.dumps(desc()).encode()) == "invalid")
check("descriptor refused: not UTF-8 JSON", parsed(None, raw=b"\xff{") == "invalid")
check("descriptor refused: nested too deep", parsed(None, raw=b"[" * 100000) == "invalid")
check("a security release and a withdrawn one may skip the ramp", isinstance(parsed(desc(releases=[
    dict(REL, importance="security", rollout=None), dict(REL, version="1.0.0-1", state="withdrawn", rollout=None)])), dict))
check("stale: generatedAt more than a day ahead", parsed(desc(generatedAt=m.iso(NOW + 86401), expiresAt=m.iso(NOW + 2 * 86400))) == "stale")
check("a day ahead is tolerated (clock skew)", isinstance(parsed(desc(generatedAt=m.iso(NOW + 86400), expiresAt=m.iso(NOW + 2 * 86400))), dict))
check("stale: expired", parsed(desc(generatedAt=m.iso(NOW - 10 * 86400), expiresAt=m.iso(NOW))) == "stale")
check("stale: older than one already accepted (anti-replay)", parsed(desc(), seen=NOW) == "stale")
check("the same generatedAt as the one accepted passes", isinstance(parsed(desc(), seen=NOW - 60), dict))

# The reach formula and cohort offering (the publisher's, g.4)
def rel(**kw):
    r = {"version": "1.0.1-1", "importance": "normal", "state": "rolling", "rollout": {"startAt": 1000, "startPercent": 10, "durationHours": 10, "pausedAt": None}}
    r.update(kw)
    return r
check("reach before the start: 0", m.reach(rel(), 999) == 0.0)
check("reach at the start: startPercent", abs(m.reach(rel(), 1000) - 0.10) < 1e-9)
check("reach half way: 10 % + 90 % / 2", abs(m.reach(rel(), 1000 + 5 * 3600) - 0.55) < 1e-9)
check("reach after the ramp: 1", m.reach(rel(), 1000 + 11 * 3600) == 1.0)
check("a security release reaches everyone at once", m.reach(rel(importance="security"), 0) == 1.0)
check("no ramp: everyone", m.reach(rel(rollout=None, state="withdrawn"), 0) == 1.0)
check("duration 0: everyone from the start", m.reach(rel(rollout={"startAt": 1000, "startPercent": 0, "durationHours": 0, "pausedAt": None}), 1000) == 1.0)
paused = rel(state="paused", rollout={"startAt": 1000, "startPercent": 10, "durationHours": 10, "pausedAt": 1000 + 5 * 3600})
check("a pause freezes the reach (no cohort goes back)", abs(m.reach(paused, 1000 + 9 * 3600) - 0.55) < 1e-9)
check("cohort 0 is offered at 5 %, cohort 1 is not", m.offered(0, 0.05) and not m.offered(1, 0.05))
check("cohort 10 is offered just past 50 %, not at 50 %", m.offered(10, 0.5001) and not m.offered(10, 0.5))
check("cohort 19 is offered just past 95 %", m.offered(19, 0.951) and not m.offered(19, 0.95))
check("the plain path (unenrolled) only at 100 %", not m.offered(None, 0.999) and m.offered(None, 1.0))
for cohort in (0, 1, 5, 10, 19, None):
    t = m.offer_at(rel(), cohort)
    check(f"offer_at for cohort {cohort} is the first second the formula offers it",
          m.offered(cohort, m.reach(rel(), t)) and (t == 1000 or not m.offered(cohort, m.reach(rel(), t - 1))), t)
check("offer_at: a paused or security release has no date", m.offer_at(paused, 3) is None and m.offer_at(rel(importance="security"), 3) is None)

# The Server line's form, and the plain URL the descriptor is fetched from
B = "https://packages.grassfield.site"
check("form: plain stable", m.form_of(B + "/stable/$arch", B) == ("stable", None))
check("form: cohort 07 of beta", m.form_of(B + "/beta/cohort/07/$arch", B) == ("beta", 7))
for bad in ("/stable/cohort/20/$arch", "/stable/cohort/7/$arch", "/stable/cohort/07/x86_64", "/stable/cohort/07/$arch/x"):
    check("form: " + bad + " is custom", m.form_of(B + bad, B) == ("custom", None))
check("form: another base is custom", m.form_of("https://elsewhere.example/stable/cohort/07/$arch", B) == ("custom", None))
check("plain_url drops the cohort segment", m.plain_url(B + "/stable/cohort/07/x86_64") == B + "/stable/x86_64"
      and m.plain_url(B + "/stable/x86_64") == B + "/stable/x86_64")

# The checker end to end (curl on file://, gpgv a stub): no request without the marker; the cohort form; staged, withdrawn,
# security; invalid, stale; the anti-replay mark kept
def publish(d, raw=None):
    p = SRV + "/stable/x86_64"
    os.makedirs(p, exist_ok=True)
    with open(p + "/grassfield-rollout.json", "wb") as f: f.write(raw if raw is not None else json.dumps(d).encode())
    with open(p + "/grassfield-rollout.json.sig", "wb") as f: f.write(b"sig")
def rollout_setup(updates="", installed="1.0.0-1", marker=True):
    setup(server="file://" + SRV + "/stable/cohort/07/$arch")
    put("installed", f"grassfield-desktop {installed}\nomarchy 4.0.4-1\n")
    put("updates", updates)
    put("grassfield-names", "grassfield-desktop\ngrassfield-keyring\n" + ("grassfield-rollout\n" if marker else ""))
    shutil.rmtree(SRV + "/stable/x86_64", ignore_errors=True)
    shutil.rmtree(SRV + "/stable/cohort", ignore_errors=True)
R2 = {"version": "1.0.2-1", "importance": "normal", "state": "rolling", "rollout": ramp()}
rollout_setup(marker=False); publish(desc([R2])); r = run(now=NOW)
check("no marker in the database: no rollout, and the cohort form still reads as stable", r["rollout"] is None
      and r["channel"] == "stable" and r["state"] == "up-to-date", r)
rollout_setup(); r = run(now=NOW)
check("marker, no descriptor published: descriptor none, cohort 7 from the Server line", r["rollout"] ==
      {"descriptor": "none", "cohort": 7, "staged": None, "withdrawn": None, "security": False}, r["rollout"])
rollout_setup(updates="grassfield-desktop 1.0.0-1 -> 1.0.1-1\n")
publish(desc([REL, R2, dict(R2, version="1.0.3-1", state="paused", rollout=ramp(paused=NOW))])); r = run(now=NOW)
st = r["rollout"]["staged"] if r["rollout"] else None
check("staged: the newest rolling release beyond what the database offers (a paused one is not staged)",
      r["rollout"]["descriptor"] == "ok" and st and st["version"] == "1.0.2-1" and st["security"] is False
      and st["offerAt"] == m.iso(m.offer_at(m.parse_rollout(json.dumps(desc([R2])).encode(), "stable", ARCH, NOW, None)["releases"][0], 7))
      and r["grassfield"]["available"] == "1.0.1-1" and r["state"] == "available", r)
check("the accepted descriptor's time is kept (anti-replay)", open(tmp + "/cache/grassfield/health-db/rollout-seen-stable").read() == str(NOW - 60))
publish(desc([R2], generatedAt=m.iso(NOW - 3600))); r = run(now=NOW)
check("an older descriptor than the one accepted: stale, nothing staged", r["rollout"]["descriptor"] == "stale" and r["rollout"]["staged"] is None, r["rollout"])
rollout_setup(updates="grassfield-desktop 1.0.0-1 -> 1.0.2-1\n"); publish(desc([R2])); r = run(now=NOW)
check("what the database offers is not staged", r["rollout"]["staged"] is None and r["rollout"]["descriptor"] == "ok", r["rollout"])
rollout_setup(updates="grassfield-desktop 1.0.0-1 -> 1.0.2-1\n"); publish(desc([dict(R2, importance="security", rollout=None)])); r = run(now=NOW)
check("security: the release the database offers is a security release", r["rollout"]["security"] is True, r["rollout"])
rollout_setup(); publish(desc([dict(R2, importance="security", rollout=None)])); r = run(now=NOW)
check("a security release not in the database yet: staged with security", r["rollout"]["staged"] == {"version": "1.0.2-1", "security": True, "offerAt": None}, r["rollout"])
rollout_setup(installed="1.0.1-1"); publish(desc([dict(REL, state="withdrawn", rollout=None)])); r = run(now=NOW)
check("withdrawn: the installed release is withdrawn, nothing staged", r["rollout"]["withdrawn"] == "1.0.1-1" and r["rollout"]["staged"] is None, r["rollout"])
rollout_setup(installed="1.0.0-1"); publish(desc([dict(REL, state="withdrawn", rollout=None)])); r = run(now=NOW)
check("a withdrawn release that is not the installed one is not reported", r["rollout"]["descriptor"] == "ok"
      and r["rollout"]["withdrawn"] is None, r["rollout"])
rollout_setup(); publish(None, raw=b"{"); r = run(now=NOW)
check("a malformed descriptor: invalid, the check still succeeds", r["rollout"]["descriptor"] == "invalid" and r["state"] == "up-to-date", r)
rollout_setup(); publish(desc([R2])); put("gpgv-rc", "1"); r = run(now=NOW)
check("a bad signature: invalid, nothing staged", r["rollout"]["descriptor"] == "invalid" and r["rollout"]["staged"] is None, r["rollout"])
rollout_setup(); publish(desc([R2])); put("signer", ROGUE); r = run(now=NOW)
check("a signature by an untrusted key: invalid", r["rollout"]["descriptor"] == "invalid", r["rollout"])
rollout_setup(); publish(desc([R2], channel="beta")); r = run(now=NOW)
check("another channel's descriptor: invalid", r["rollout"]["descriptor"] == "invalid", r["rollout"])
setup(listed=False, conf=False); put("grassfield-names", "grassfield-rollout\n"); r = run(now=NOW)
check("not set up: no rollout at all", r["state"] == "not-set-up" and r["rollout"] is None, r)

# -- the whole program (the installed paths): root refusal, its own lock, Omarchy's update lock and the waiter
setup()
env = dict(os.environ, XDG_CACHE_HOME=tmp + "/xdg-cache", XDG_RUNTIME_DIR=tmp + "/run")
os.makedirs(tmp + "/run", exist_ok=True)
def program(*args, **kw):
    return subprocess.run([helper, *args], env=env, capture_output=True, text=True, timeout=60, **kw)
if os.geteuid() == 0:
    p = program()
    check("run as root -> refused, exit 2, nothing printed on stdout", p.returncode == 2 and p.stdout == "", p)
    print("SKIP: the lock and waiter cases need a user (this run is root)")
else:
    os.makedirs(tmp + "/xdg-cache/grassfield", exist_ok=True)
    held = os.open(tmp + "/xdg-cache/grassfield/checkup.lock", os.O_RDWR | os.O_CREAT)
    fcntl.flock(held, fcntl.LOCK_EX)
    p = program()
    check("a second check while one runs -> busy", p.returncode == 0 and json.loads(p.stdout)["state"] == "busy", p)
    os.close(held)
    lock = os.open(tmp + "/run/omarchy-update.lock", os.O_RDWR | os.O_CREAT)
    fcntl.flock(lock, fcntl.LOCK_EX)
    p = program()
    check("Omarchy's update lock held -> update-running, nothing checked", json.loads(p.stdout)["state"] == "update-running", p)
    waiter = subprocess.Popen([helper, "--after-update-lock"], env=env, stdout=subprocess.PIPE, text=True)
    time.sleep(1.5)
    early = waiter.poll()
    released = time.monotonic()
    fcntl.flock(lock, fcntl.LOCK_UN); os.close(lock)
    out, _ = waiter.communicate(timeout=60)
    state = json.loads(out)["state"]
    check("the waiter blocks while the lock is held, then checks once it is released (A7f)",
          early is None and state not in ("update-running", "busy"), (early, out))
    check("the waiter does not keep Omarchy's lock", subprocess.run(["flock", "-n", tmp + "/run/omarchy-update.lock", "true"]).returncode == 0)
sys.exit(1 if fails else 0)
PY
python3 -I "$tmp/test.py" "$root" "$tmp"
