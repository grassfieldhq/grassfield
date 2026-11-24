#!/usr/bin/env python3
# script-scan.py: discovery of the user's script commands (ADR-0067 D-3, command-palette.md slice X2). Run as `python3 -I
# script-scan.py <folder>...` by Scripts.qml, never by the GUI thread. It lists, it never runs anything: for each folder it
# prints ONE JSON document {"v": 1, "folders": [{"path", "status", "scripts": [...]}]} and judges only the file system's side
# (Scripts.js parses the header and judges the names' text).
#
# A folder: absolute, must exist ("missing" otherwise: the default folder is created only by Open Scripts Folder), be a directory
# of this user's, not group- or world-writable ("refused-folder" otherwise: its scripts are not listed). Only its direct entries
# are read (no recursion); names starting with "." and `.template.` files are skipped. A file is listed ({"ok": true, ...}) only
# when it is a regular file of this user's, executable by its owner, not group- or world-writable, at most 256 KiB; a link only
# when its target passes the same checks and the target's own folder passes the folder check (a link into a folder others can
# write would let them swap the file). Anything else is reported refused with a reason code. Each file is judged on the open
# descriptor (fstat), opened with O_NOFOLLOW on the resolved path and O_NONBLOCK (a FIFO named here cannot hang the scan), and its
# first 8 KiB are read from that same descriptor. The runner (packaging/bin/grassfield-script-run) checks again at run time.
import codecs
import hashlib
import json
import os
import stat
import sys

MAX_SCRIPT = 256 * 1024
HEAD_BYTES = 8192
MAX_ENTRIES = 512          # per folder; the rest is ignored (a folder of that size is not a script folder)
MAX_FOLDERS = 16


def folder_ok(path):
    """(status, reason) of a folder: ok, or why its scripts are not listed."""
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return "missing"
    except OSError:
        return "refused-folder"
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o022:
        return "refused-folder"
    return "ok"


def refused(name, path, reason):
    return {"name": name, "path": path, "ok": False, "reason": reason}


def judge(name, path):
    try:
        lst = os.lstat(path)
    except OSError:
        return refused(name, path, "gone")
    link = stat.S_ISLNK(lst.st_mode)
    real = path
    if link:
        real = os.path.realpath(path)
        try:
            tst = os.stat(real)
        except OSError:
            return refused(name, path, "dangling-link")
        if not stat.S_ISREG(tst.st_mode):
            return refused(name, path, "not-regular")
        if folder_ok(os.path.dirname(real)) != "ok":
            return refused(name, path, "link-folder")
    elif stat.S_ISDIR(lst.st_mode):
        return None                     # a subfolder: not read (no recursion), not an error
    elif not stat.S_ISREG(lst.st_mode):
        return refused(name, path, "not-regular")
    try:
        fd = os.open(real, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOCTTY | os.O_CLOEXEC)
    except OSError:
        return refused(name, path, "unreadable")
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return refused(name, path, "not-regular")
        if st.st_uid != os.geteuid():
            return refused(name, path, "owner")
        if st.st_mode & 0o022:
            return refused(name, path, "writable")
        if not st.st_mode & 0o100:
            return refused(name, path, "not-executable")
        if st.st_size > MAX_SCRIPT:
            return refused(name, path, "too-big")
        head = os.read(fd, HEAD_BYTES)
    except OSError:
        return refused(name, path, "unreadable")
    finally:
        os.close(fd)
    # A cut multi-byte character at the end of the head is dropped; one bad byte inside becomes U+FFFD.
    text = codecs.getincrementaldecoder("utf-8")("replace").decode(head, final=False)
    out = {"name": name, "path": path, "ok": True, "link": link, "size": st.st_size, "head": text,
           "id": "script." + hashlib.sha256(path.encode("utf-8", "surrogateescape")).hexdigest()[:20]}
    if link:
        out["real"] = real
    return out


def scan(folder):
    status = folder_ok(folder) if folder.startswith("/") else "refused-folder"
    result = {"path": folder, "status": status, "scripts": []}
    if status != "ok":
        return result
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        result["status"] = "refused-folder"
        return result
    for name in names[:MAX_ENTRIES]:
        if name.startswith(".") or ".template." in name:
            continue
        try:
            name.encode("utf-8")
        except UnicodeEncodeError:
            result["scripts"].append(refused(name.encode("utf-8", "replace").decode("utf-8"), os.path.join(folder, name), "name"))
            continue
        one = judge(name, os.path.join(folder, name))
        if one is not None:
            result["scripts"].append(one)
    return result


def main(argv):
    folders = []
    for f in argv[:MAX_FOLDERS]:
        if f not in folders:
            folders.append(f)
    sys.stdout.write(json.dumps({"v": 1, "folders": [scan(f) for f in folders]}, ensure_ascii=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
