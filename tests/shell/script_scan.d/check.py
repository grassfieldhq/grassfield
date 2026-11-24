# shell/search/script-scan.py on a scratch folder (run by tests/shell/script_scan.sh as `python3 -I check.py <root> <tmp>`).
import json
import os
import stat
import subprocess
import sys

root, tmp = sys.argv[1:3]
failed = False


def check(ok, desc):
    global failed
    print(("PASS: " if ok else "FAIL: ") + desc, flush=True)
    failed = failed or not ok


tool = os.path.join(root, "shell/search/script-scan.py")


def scan(*folders):
    r = subprocess.run([sys.executable, "-I", tool, *folders], capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        check(False, "the scan ends 0 [%s]" % r.stderr)
    return json.loads(r.stdout)["folders"]


def put(folder, name, body=b"#!/bin/sh\n# @raycast.title X\n", mode=0o700):
    p = os.path.join(folder, name)
    with open(p, "wb") as f:
        f.write(body)
    os.chmod(p, mode)
    return p


def folder(name, mode=0o700):
    p = os.path.join(tmp, name)
    os.mkdir(p)
    os.chmod(p, mode)
    return p


def by_name(result):
    return {s["name"]: s for s in result["scripts"]}


d = folder("scripts")
put(d, "good.sh", b"#!/bin/sh\n# @raycast.title Good \xe2\x9c\x93\n")
put(d, "good2.py", b"#!/usr/bin/env python3\n")
put(d, "gw.sh", mode=0o770)
put(d, "ow.sh", mode=0o707)
put(d, "gw-only-write.sh", mode=0o720)
put(d, "noexec.sh", mode=0o600)
put(d, "big.sh", b"#!/bin/sh\n" + b"#" * (256 * 1024), 0o700)
put(d, "limit.sh", b"#!/bin/sh\n" + b"#" * (256 * 1024 - 10), 0o700)
put(d, ".hidden.sh")
put(d, "script-command.template.sh")
put(d, "x.template.txt")
os.mkfifo(os.path.join(d, "fifo.sh"), 0o700)
os.mknod(os.path.join(d, "sock.sh"), stat.S_IFSOCK | 0o700)     # a socket file, made without opening a socket
os.mkdir(os.path.join(d, "subdir"))
put(os.path.join(d, "subdir"), "inner.sh")
# a head longer than 8 KiB is cut; a multi-byte character cut at the end never leaves a broken one
put(d, "long.sh", b"#!/bin/sh\n" + b"# " + "é".encode() * 9000 + b"\n")
bad_name = os.path.join(os.fsencode(d), b"bad-\xff-name.sh")
with open(bad_name, "wb") as f:
    f.write(b"#!/bin/sh\n")
os.chmod(bad_name, 0o700)

# links
t = folder("targets")
put(t, "real.sh", b"#!/bin/sh\n# real\n")
put(t, "real-noexec.sh", mode=0o600)
put(t, "real-gw.sh", mode=0o770)
os.symlink(os.path.join(t, "real.sh"), os.path.join(d, "link-good.sh"))
os.symlink(os.path.join(t, "real-noexec.sh"), os.path.join(d, "link-noexec.sh"))
os.symlink(os.path.join(t, "real-gw.sh"), os.path.join(d, "link-gw.sh"))
os.symlink(os.path.join(tmp, "nowhere"), os.path.join(d, "link-dangling.sh"))
os.symlink(os.path.join(d, "fifo.sh"), os.path.join(d, "link-fifo.sh"))
os.symlink(t, os.path.join(d, "link-dir.sh"))
os.symlink("/usr/bin/true", os.path.join(d, "link-root.sh"))                     # a root-owned file in a root-owned folder
open_dir = folder("open-dir", 0o777)
put(open_dir, "target.sh")
os.symlink(os.path.join(open_dir, "target.sh"), os.path.join(d, "link-opendir.sh"))
os.symlink(os.path.join(d, "good.sh"), os.path.join(d, "link-inside.sh"))        # a link to a file of the same folder is fine
os.symlink("good.sh", os.path.join(d, "link-relative.sh"))

res = scan(d)[0]
s = by_name(res)
check(res["status"] == "ok", "the folder is read")
good = s.get("good.sh", {})
check(good.get("ok") is True and good["id"].startswith("script.") and len(good["id"]) == len("script.") + 20 and good["link"] is False,
      "a regular, executable, own-user file is listed with a path-derived id")
check("Good ✓" in good.get("head", ""), "its head is read as text")
check(s["good2.py"]["ok"], "any language: the interpreter line is the script's own business")
for name, why in (("gw.sh", "writable"), ("ow.sh", "writable"), ("gw-only-write.sh", "writable"), ("noexec.sh", "not-executable"),
                  ("big.sh", "too-big"), ("fifo.sh", "not-regular"), ("sock.sh", "not-regular"), ("link-noexec.sh", "not-executable"),
                  ("link-gw.sh", "writable"), ("link-dangling.sh", "dangling-link"), ("link-fifo.sh", "not-regular"),
                  ("link-dir.sh", "not-regular"), ("link-opendir.sh", "link-folder")):
    check(s.get(name, {}).get("ok") is False and s[name]["reason"] == why and "head" not in s[name], "refused %s: %s [%s]" % (name, why, s.get(name, {}).get("reason")))
check(s["link-root.sh"]["ok"] is False and s["link-root.sh"]["reason"] in ("link-folder", "owner"), "a link to someone else's file is refused [%s]" % s["link-root.sh"]["reason"])
check(s["limit.sh"]["ok"] is True, "a file just under 256 KiB is listed")
check(s["link-good.sh"]["ok"] and s["link-good.sh"]["link"] is True and s["link-good.sh"]["real"] == os.path.join(t, "real.sh")
      and "# real" in s["link-good.sh"]["head"], "a link to a good file in a good folder is listed, its target's head is read")
check(s["link-inside.sh"]["ok"] and s["link-relative.sh"]["ok"], "links inside the same folder, absolute or relative, are listed")
for name in (".hidden.sh", "script-command.template.sh", "x.template.txt", "subdir", "inner.sh"):
    check(name not in s, "skipped silently: " + name)
check(len(s["long.sh"]["head"].encode()) <= 8192 and "�" not in s["long.sh"]["head"], "a head over 8 KiB is cut at 8 KiB without a broken character")
badn = [x for x in res["scripts"] if x["name"].startswith("bad-")]
check(len(badn) == 1 and badn[0]["ok"] is False and badn[0]["reason"] == "name",
      "a name that is not UTF-8 is refused (reason name)")
check(json.dumps(res).isascii(), "the report is plain ASCII JSON (no raw control character reaches the shell)")

# folders
check(scan(os.path.join(tmp, "absent"))[0]["status"] == "missing", "a folder that does not exist is missing, not an error")
gwd = folder("gw-folder", 0o770)
put(gwd, "a.sh")
r = scan(gwd)[0]
check(r["status"] == "refused-folder" and r["scripts"] == [], "a group-writable folder lists nothing")
owd = folder("ow-folder", 0o703)
put(owd, "a.sh")
r = scan(owd)[0]
check(r["status"] == "refused-folder" and r["scripts"] == [], "a world-writable folder lists nothing")
r = scan("/usr/share")[0]
check(r["status"] == "refused-folder" and r["scripts"] == [], "a folder owned by someone else lists nothing")
r = scan("relative/folder")[0]
check(r["status"] == "refused-folder", "a relative folder is refused")
filep = put(tmp, "plainfile")
check(scan(filep)[0]["status"] == "refused-folder", "a file given as a folder is refused")
fl = os.path.join(tmp, "folder-link")
os.symlink(d, fl)
check(scan(fl)[0]["status"] == "ok", "a folder that is a link to a good folder is read")
r = scan(d, d, t)
check([x["path"] for x in r] == [d, t], "a folder given twice is read once")
many = folder("many")
for i in range(600):
    put(many, "s%04d.sh" % i)
check(len(scan(many)[0]["scripts"]) == 512, "at most 512 entries of a folder are read")

# a change is seen by the next scan
before = by_name(scan(d)[0])
os.chmod(os.path.join(d, "good.sh"), 0o777)
after = by_name(scan(d)[0])
check(before["good.sh"]["ok"] and after["good.sh"]["reason"] == "writable", "a mode change is picked up by the next scan")
put(d, "later.sh")
check("later.sh" in by_name(scan(d)[0]), "a new file is picked up by the next scan")
os.unlink(os.path.join(d, "later.sh"))
check("later.sh" not in by_name(scan(d)[0]), "a removed file is dropped by the next scan")

print("script_scan: FAIL" if failed else "script_scan: PASS")
sys.exit(1 if failed else 0)
