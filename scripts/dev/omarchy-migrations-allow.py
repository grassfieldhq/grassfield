#!/usr/bin/env python3
"""The reviewed list of Omarchy migrations that Software Update may run with root without a person (rc7 audit R7-SEC-01 and
its security reviews; ADR-0033 s5, owner decision SU-M2): packaging/pacman/omarchy-migrations.allow, read by
grassfield-update-helper.

  scripts/dev/omarchy-migrations-allow.py --tree ROOT [--tree ROOT]... [--package FILE]...   regenerate those releases
  scripts/dev/omarchy-migrations-allow.py --check [--tree ROOT]... [--package FILE]...      check (no write)
  Tests only: --list FILE (another list), --release VERSION (name the release of the trees given instead of their lock)

ROOT is a package root holding usr/share/omarchy (`/` for the installed Omarchy); FILE is an Omarchy package
(omarchy-<version>-<arch>.pkg.tar.zst, from pacman's cache), extracted with bsdtar into a scratch folder. Each tree is one
supported release: the drift lock (docs/upstream/omarchy*.lock) whose `# omarchy-newest-migration N` names the tree's
newest migration gives its package version; a tree no lock names is refused (a release Grassfield does not support yet:
pin its lock first, scripts/dev/upstream-drift.sh).

Each migration is judged with everything it reaches, its CLOSURE: every file of the package a word of it names
($OMARCHY_PATH/..., $OMARCHY_INSTALL/..., /usr/share/omarchy/..., anywhere, comments too: sourced, run, run directly, through
env or timeout, or copied; a folder of at most DIR_MAX files with those files), the omarchy-* commands it names, a file under
/etc it sources (root's configuration: listed, never hashed, the helper requires it root's alone), and the same for each of
those, transitively (the security reviews of 2026-11-08: 1792474908 sourced an excluded migration; 1781984677 ran an install
script through `as_root env ... bash`). A package path it cannot resolve (a variable in it, the package root, a larger
folder), a source it cannot resolve, a pipe into a shell, `exec`, a shell after a prefix word (env, timeout, as_root, sudo),
or an omarchy-* name built at run time excludes the migration (`review`). The helper's OWN scans (cut out of
packaging/pacman/grassfield-update-helper, run as written there) and the wider review patterns below are applied to every
file of the closure: `exclude ... person` when one needs a person, or when the migration relies on its working folder (the
unit works from /: a relative path, $PWD, `cd -`); `exclude ... home-code` when one reaches code the person can change;
`exclude ... review` when one reaches a review pattern (other interpreters and package builders, login, interactive or -c
shells, eval, input read from or code run out of a home path, the XDG folders, /home/); else `allow`, with the closure's
files and the sha256 of the package files' "<file> <sha256>" lines, sorted, which the helper hashes again.
A regeneration replaces only the lines of the releases it read.
--check without a tree: every drift lock has its `release` line, each release has exactly its count of lines, every line
reads, no name twice in a release. With trees: also their lines are exactly what the generation from that tree gives.
Exit 0 ok, 1 a difference (printed), 2 usage or an unreadable tree. Standard library only; it never runs a migration.
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
LIST = os.path.join(ROOT, "packaging/pacman/omarchy-migrations.allow")
HELPER = os.path.join(ROOT, "packaging/pacman/grassfield-update-helper")
LOCKS = os.path.join(ROOT, "docs/upstream")
NAME = re.compile(r"[0-9]{1,20}\.sh")
VERSION = r"[A-Za-z0-9._+:-]{1,64}"
# The files a closure may hold: the helper's GU_CLOSURE_FILE. etc/ files are root's configuration a migration sources: listed,
# never hashed (each machine's own), and the helper requires them root's alone.
CLOSURE_FILE = re.compile(r"usr/(share/omarchy/[A-Za-z0-9._@+-]+(/[A-Za-z0-9._@+-]+)*|bin/omarchy-[a-z0-9-]+)"
                          r"|etc/[A-Za-z0-9._@+-]+(/[A-Za-z0-9._@+-]+)*")
# A directory named by a path word joins the closure with every file under it, up to this many; a larger one (the package
# root itself) cannot be reviewed as part of one migration.
DIR_MAX = 64
ALLOW = re.compile(r"allow ([0-9a-f]{64}) ([0-9]{1,20}\.sh) (" + VERSION + r")((?: \S+)+)")
EXCLUDE = re.compile(r"exclude ([0-9a-f]{64}) ([0-9]{1,20}\.sh) (" + VERSION + r") (person|home-code|review|unreadable)")
RELEASE = re.compile(r"release (" + VERSION + r") newest-migration ([0-9]{1,20}) migrations ([0-9]{1,6})")
# Generation-time review patterns (the reviewer's list of what a word scan misses, rc7 security review of R7-SEC-01): matched as
# the helper matches its words, the Omarchy commands that reach them included, comments counted.
REVIEW_WORDS = ("zsh|fish|dash|ksh|eval|makepkg|yay|paru|node|nodejs|bun|bunx|deno|ruby|gem|perl|pip[0-9.]*|pipx|uv|uvx|"
                "cargo|rustup|lua|luajit|php|tclsh|xargs|crontab|systemd-run")
REVIEW_EXTRA = ("(bash|sh|zsh)[[:space:]]+-[A-Za-z]*[lic]|<[[:space:]]*[\"']?(~|\\$HOME|\\$\\{HOME)|"
                "\\$\\{?XDG_[A-Z]+_HOME|/home/|\\$\\(cat[[:space:]]|`cat[[:space:]]|"
                "(~|\\$HOME|\\$\\{HOME\\})/[^[:space:]\"']*/(bin|hooks|scripts)/")
# A migration that relies on its working folder (the unit works from /, the security review's MAJOR): a relative path, $PWD,
# pwd, `cd -`. Conservative: a relative path inside a string counts too.
CWD = ("(^|[[:space:]\"'=(])\\.\\.?/|(^|[[:space:]\"'=(])\\.(config|local|cache|ssh|bashrc|zshrc|profile)([^[:alnum:]_]|$)|"
       "\\$PWD|\\$\\{PWD|(^|[^[:alnum:]_.-])pwd([^[:alnum:]_.-]|$)|(^|[;&|[:space:]])cd[[:space:]]+-([[:space:]]|$)")
# Where bash starts a command, then source / . / bash / sh and its options, then its first word.
SOURCE = re.compile(r"(?:^|[;&|({!]|\bthen\b|\bdo\b|\belse\b)\s*(source|\.|bash|sh)\s+((?:-[A-Za-z]+\s+)*)(\S+)")
COMMAND = re.compile(r"(?<![A-Za-z0-9_.-])(omarchy-[a-z0-9-]+)(?![A-Za-z0-9_.-])")
# Every word naming a path of the Omarchy package, anywhere (comments too), joins the closure: a script run directly, through
# env, timeout or exec, or copied, is covered whatever the command around it (the third security review).
OMARCHY_WORD = re.compile(r"""(\$\{?OMARCHY_PATH\}?|\$\{?OMARCHY_INSTALL\}?|/usr/share/omarchy)((?:/[^\s"'`;|&()<>{}]*)?)""")
# Ways of running code the closure cannot follow (non-comment lines): a pipe into a shell, exec, a shell after a prefix word
# (env, timeout, as_root, sudo ... bash), an omarchy-* command named at run time.
PIPE_SHELL = re.compile(r"\|\s*(?:\S*/)?(bash|sh|zsh|dash|ksh)(?![A-Za-z0-9_.-])")
EXEC_WORD = re.compile(r"(?<![A-Za-z0-9_.-])exec(?![A-Za-z0-9_.-])")
SHELL_WORD = re.compile(r"(?<![A-Za-z0-9_.-])(bash|sh|zsh|dash|ksh)(?![A-Za-z0-9_.-])")
DYNAMIC_COMMAND = re.compile(r"(?<![A-Za-z0-9_.-])omarchy-[a-z0-9-]*[$`]")
HEADER = """\
# Omarchy migrations that Software Update may run with root without a person (ADR-0033 s5, owner decision SU-M2; rc7 audit
# R7-SEC-01 and its security reviews). Installed as /usr/share/grassfield/update/omarchy-migrations.allow (root's alone):
# grassfield-update-helper uses its migrations' unit only when the Omarchy version being installed is a release below and
# every migration the run would run there has an `allow` line for that version, whose files (the migration and everything
# it sources or names under /usr/share/omarchy, transitively) still hash to the line's sum, before the transaction and again
# just before they run; anything else takes Omarchy's terminal. This list is the guarantee; the word scans are defence in
# depth. GENERATED by scripts/dev/omarchy-migrations-allow.py from each supported Omarchy release (one per
# docs/upstream/omarchy*.lock, the trees of the drift review); review the `allow` lines of a new release with its drift
# review before committing them. tests/shell/omarchy_migrations_allow.sh fails while a supported release is not listed whole.
#   release <omarchy package> newest-migration <N> migrations <count>
#   allow   <closure sha256> <name> <omarchy package> <file>...
#   exclude <sha256 of the migration> <name> <omarchy package> <person|home-code|review|unreadable>
# (the closure sha256: of the files' "<file> <sha256>" lines, sorted by file; review: the generator's wider patterns, or a
# source it cannot resolve)
"""


def fail(msg, code=2):
    print("omarchy-migrations-allow: " + msg, file=sys.stderr)
    sys.exit(code)


def locks():
    """{newest migration number: package version} of every drift lock."""
    out = {}
    for name in sorted(os.listdir(LOCKS)):
        if not (name.startswith("omarchy") and name.endswith(".lock")):
            continue
        text = open(os.path.join(LOCKS, name), encoding="utf-8").read()
        newest = re.search(r"^# omarchy-newest-migration ([0-9]+)$", text, re.M)
        package = re.search(r"^# omarchy-package (\S+)$", text, re.M)
        if not newest or not package:
            fail("%s has no omarchy-newest-migration or omarchy-package line" % name)
        out[newest.group(1)] = package.group(1)
    if not out:
        fail("no drift lock in docs/upstream")
    return out


def scan_code():
    """The helper's scan, cut out of it: its word lists, reach() and the pattern lines, as written there."""
    src = open(HELPER, encoding="utf-8").read().split("\n")
    out = [l for l in src if re.match(r"GU_(PERSON_WORDS|PERSON_EXTRA|ROOT_WORDS|USER_WORDS|USER_EXTRA)=", l)]
    start = next(i for i, l in enumerate(src) if l.startswith("  reach() {"))
    end = next(i for i in range(start, len(src)) if src[i] == "  }")
    out += src[start:end + 1]
    start = next(i for i, l in enumerate(src) if l.startswith("  person_words=$(reach "))
    end = next(i for i in range(start, len(src)) if src[i].startswith("  user_pattern="))
    out += src[start:end + 1]
    if len(out) < 25:
        fail("cannot cut the scan out of the helper")
    return "\n".join(out) + "\n"


RUNNER = r"""set -uo pipefail
scan=$1
shift
bin_dirs=("$@")
finish() { echo "finish $*" >&2; exit 1; }
. "$scan"
review_words=$(reach "$REVIEW_WORDS" "$REVIEW_EXTRA") || exit 1
printf '%s\n' "$person_pattern" "$user_pattern" "(^|[^[:alnum:]_.-])($review_words)([^[:alnum:]_.-]|\$)|$REVIEW_EXTRA"
"""


def patterns(tree, scratch):
    """(person, home-code, review) patterns of the helper's scan over the tree's commands."""
    bins = [os.path.join(tree, "usr/bin"), os.path.join(tree, "usr/share/omarchy/bin")]
    with open(os.path.join(scratch, "scan.sh"), "w") as f:
        f.write(scan_code())
    with open(os.path.join(scratch, "run.sh"), "w") as f:
        f.write(RUNNER)
    run = subprocess.run(["bash", os.path.join(scratch, "run.sh"), os.path.join(scratch, "scan.sh")] + bins,
                         capture_output=True, text=True, timeout=600,
                         env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "REVIEW_WORDS": REVIEW_WORDS, "REVIEW_EXTRA": REVIEW_EXTRA})
    lines = run.stdout.split("\n")
    if run.returncode != 0 or len(lines) < 3 or not all(lines[:3]):
        fail("the scan failed on %s: %s" % (tree, (run.stdout + run.stderr)[-400:]))
    return lines[:3]


def matching(pattern, files, tree):
    """The files (relative to the tree) whose text matches the ERE `pattern`, as grep reads it (the helper's matcher); a file
    grep cannot read counts as matching (fails closed)."""
    hit = set()
    for i in range(0, len(files), 200):
        chunk = files[i:i + 200]
        run = subprocess.run(["grep", "-lE", "-e", pattern, "--"] + [os.path.join(tree, f) for f in chunk],
                             capture_output=True, text=True, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
        if run.returncode not in (0, 1) or run.stderr.strip():
            return set(files)
        hit |= {os.path.relpath(p, tree) for p in run.stdout.split("\n") if p}
    return hit


class Tree:
    def __init__(self, tree):
        self.tree = tree
        self.edges = {}

    def command_file(self, name):
        for d in ("usr/share/omarchy/bin", "usr/bin"):
            rel = d + "/" + name
            path = os.path.join(self.tree, rel)
            if os.path.isfile(path) and not os.path.islink(path):
                return rel
        return None

    def resolve(self, word):
        """("files", [rel...]) for a file or a small folder of the package, ("etc", rel) for a file under /etc, else
        ("unresolved", word)."""
        a = word.strip("\"'")
        a = re.sub(r"^\$\{?OMARCHY_INSTALL\}?(?=/|$)", "usr/share/omarchy/install", a)
        a = re.sub(r"^(\$\{?OMARCHY_PATH\}?|/usr/share/omarchy)(?=/|$)", "usr/share/omarchy", a)
        a = a.rstrip("/")
        if any(c in a for c in "$`*?[") or ".." in a.split("/"):
            return "unresolved", word
        if a.startswith("usr/share/omarchy") and a != "usr/share/omarchy":
            path = os.path.join(self.tree, a)
            if os.path.islink(path):
                name = os.path.basename(a)
                target = self.command_file(name) if a.startswith("usr/share/omarchy/bin/") else None
                return ("files", [target]) if target else ("unresolved", word)
            if os.path.isfile(path) and CLOSURE_FILE.fullmatch(a):
                return "files", [a]
            if os.path.isdir(path):
                found = []
                for top, dirs, names in os.walk(path):
                    dirs.sort()
                    for n in sorted(names):
                        rel = os.path.relpath(os.path.join(top, n), self.tree)
                        if not os.path.islink(os.path.join(top, n)) and CLOSURE_FILE.fullmatch(rel):
                            found.append(rel)
                        else:
                            return "unresolved", word
                if 0 < len(found) <= DIR_MAX:
                    return "files", found
            return "unresolved", word
        if a.startswith("/etc/") and CLOSURE_FILE.fullmatch(a[1:]):
            return "etc", a[1:]
        return "unresolved", word

    def reach(self, rel):
        """(files it reaches, ways of running code the closure cannot follow) of one file."""
        if rel not in self.edges:
            out, bad = set(), []
            if rel.startswith("etc/"):
                self.edges[rel] = (out, bad)
                return self.edges[rel]
            for line in open(os.path.join(self.tree, rel), encoding="utf-8", errors="replace"):
                for m in COMMAND.finditer(line):
                    f = self.command_file(m.group(1))
                    if f:
                        out.add(f)
                for m in OMARCHY_WORD.finditer(line):
                    kind, value = self.resolve(m.group(0))
                    if kind == "files":
                        out.update(value)
                    else:
                        bad.append("a path of the package it cannot resolve: " + m.group(0))
                if line.lstrip().startswith("#"):
                    continue
                starts = set()
                for m in SOURCE.finditer(line):
                    starts.add(m.start(1))
                    if re.search(r"-[A-Za-z]*c", m.group(2)):
                        continue  # a command string: the review patterns judge it
                    kind, value = self.resolve(m.group(3))
                    if kind == "files":
                        out.update(value)
                    elif kind == "etc":
                        out.add(value)
                    else:
                        bad.append(m.group(1) + " " + value)
                if PIPE_SHELL.search(line):
                    bad.append("a pipe into a shell")
                if EXEC_WORD.search(line):
                    bad.append("exec")
                if DYNAMIC_COMMAND.search(line):
                    bad.append("an omarchy-* command named at run time")
                for m in SHELL_WORD.finditer(line):
                    if m.start(1) not in starts:
                        bad.append("a shell after a prefix word: " + m.group(1))
            self.edges[rel] = (out, bad)
        return self.edges[rel]

    def closure(self, rel):
        seen, todo, bad = {rel}, [rel], []
        while todo:
            out, b = self.reach(todo.pop())
            bad += b
            for f in sorted(out - seen):
                seen.add(f)
                todo.append(f)
        return sorted(seen), bad


def sha_file(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def closure_sum(tree, files):
    """The sha256 of the package files' "<file> <sha256>" lines, in order (etc/ files are listed, never hashed)."""
    return hashlib.sha256("".join("%s %s\n" % (f, sha_file(os.path.join(tree, f))) for f in files
                                  if not f.startswith("etc/")).encode()).hexdigest()


def generate(tree, scratch):
    """({name: row}, newest migration number). row: ("allow", closure sum, "", files) or ("exclude", sha, reason, ())."""
    mig = os.path.join(tree, "usr/share/omarchy/migrations")
    if not os.path.isdir(mig) or not os.path.isdir(os.path.join(tree, "usr/share/omarchy/bin")):
        fail("%s holds no usr/share/omarchy/migrations and usr/share/omarchy/bin" % tree)
    names = sorted((n for n in os.listdir(mig) if n.endswith(".sh")), key=lambda n: (len(n), n))
    if not names or any(not NAME.fullmatch(n) for n in names):
        fail("%s: no migration, or a migration name the helper refuses" % tree)
    person, home, review = patterns(tree, scratch)
    t = Tree(tree)
    closures = {}
    for n in names:
        rel = "usr/share/omarchy/migrations/" + n
        path = os.path.join(tree, rel)
        closures[n] = t.closure(rel) if os.path.isfile(path) and not os.path.islink(path) else None
    files = sorted({f for c in closures.values() if c for f in c[0] if not f.startswith("etc/")})
    scripts = [f for f in files if not f.startswith(("usr/bin/", "usr/share/omarchy/bin/"))]
    hits = {"person": matching(person, files, tree), "cwd": matching(CWD, scripts, tree),
            "home-code": matching(home, files, tree), "review": matching(review, files, tree)}
    rows = {}
    for n in names:
        rel = "usr/share/omarchy/migrations/" + n
        if closures[n] is None:
            rows[n] = ("exclude", "0" * 64, "unreadable", ())
            continue
        cfiles, bad = closures[n]
        if any(f in hits["person"] or f in hits["cwd"] for f in cfiles):
            reason = "person"
        elif any(f in hits["home-code"] for f in cfiles):
            reason = "home-code"
        elif bad or any(f in hits["review"] for f in cfiles):
            reason = "review"
        else:
            reason = ""
        if reason:
            rows[n] = ("exclude", sha_file(os.path.join(tree, rel)), reason, ())
        else:
            rows[n] = ("allow", closure_sum(tree, cfiles), "", tuple(cfiles))
    return rows, names[-1][:-3]


def parse(text):
    """(releases {package: (newest, count)}, entries {package: {name: row}}, problems)."""
    releases, entries, problems = {}, {}, []
    for i, line in enumerate(text.split("\n"), 1):
        if not line or line.startswith("#"):
            continue
        m = RELEASE.fullmatch(line)
        if m:
            if m.group(1) in releases:
                problems.append("line %d: release %s twice" % (i, m.group(1)))
            releases[m.group(1)] = (m.group(2), int(m.group(3)))
            continue
        m, row = ALLOW.fullmatch(line), None
        if m:
            files = tuple(m.group(4).split())
            if not all(CLOSURE_FILE.fullmatch(f) and ".." not in f for f in files) or \
                    "usr/share/omarchy/migrations/" + m.group(2) not in files or list(files) != sorted(files):
                problems.append("line %d: a closure file the helper refuses, or not sorted: %s" % (i, line[:120]))
                continue
            row = (m.group(2), m.group(3), ("allow", m.group(1), "", files))
        else:
            m = EXCLUDE.fullmatch(line)
            if m:
                row = (m.group(2), m.group(3), ("exclude", m.group(1), m.group(4), ()))
        if row is None:
            problems.append("line %d does not read: %s" % (i, line[:120]))
            continue
        name, pkg, value = row
        per = entries.setdefault(pkg, {})
        if name in per:
            problems.append("line %d: %s twice in %s" % (i, name, pkg))
        per[name] = value
    return releases, entries, problems


def render(releases, entries):
    out = [HEADER.rstrip("\n")]
    order = sorted(releases, key=lambda p: int(releases[p][0]))
    for pkg in order:
        out.append("release %s newest-migration %s migrations %d" % (pkg, releases[pkg][0], releases[pkg][1]))
    for pkg in order:
        for name in sorted(entries.get(pkg, {}), key=lambda n: (len(n), n)):
            kind, sha, reason, files = entries[pkg][name]
            if kind == "allow":
                out.append(" ".join(["allow", sha, name, pkg] + list(files)))
            else:
                out.append(" ".join(["exclude", sha, name, pkg, reason]))
    return "\n".join(out) + "\n"


def main(argv):
    global LIST
    check, trees, packages, release = False, [], [], None
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--check":
            check = True
        elif a in ("--tree", "--package") and args:
            (trees if a == "--tree" else packages).append(args.pop(0))
        elif a == "--list" and args:
            LIST = args.pop(0)
        elif a == "--release" and args:
            release = args.pop(0)
        else:
            fail("usage: omarchy-migrations-allow.py [--check] [--tree ROOT]... [--package FILE]... [--list FILE] [--release V]")
    if not check and not trees and not packages:
        fail("nothing to regenerate: give --tree or --package (or --check)")
    if release is not None and (os.path.realpath(LIST) == os.path.realpath(os.path.join(ROOT, "packaging/pacman/omarchy-migrations.allow"))
                                or not re.fullmatch(VERSION, release)):
        fail("--release is for a test list only (with --list)")
    by_newest = locks()
    text = open(LIST, encoding="utf-8").read() if os.path.exists(LIST) else ""
    releases, entries, problems = parse(text)
    scratch = tempfile.mkdtemp(prefix="omarchy-allow.", dir=os.environ.get("TMPDIR") or None)
    try:
        for pkg_file in packages:
            dest = os.path.join(scratch, "pkg%d" % len(trees))
            os.makedirs(dest)
            r = subprocess.run(["bsdtar", "-xf", pkg_file, "-C", dest, "usr/share/omarchy/migrations", "usr/share/omarchy/bin",
                                "usr/share/omarchy/install", "usr/bin"], capture_output=True, text=True)
            if r.returncode != 0:
                fail("cannot extract %s: %s" % (pkg_file, r.stderr.strip()[-200:]))
            trees.append(dest)
        fresh = {}
        for tree in trees:
            rows, newest = generate(tree, scratch)
            if release is not None:
                pkg = release
            elif newest in by_newest:
                pkg = by_newest[newest]
            else:
                fail("%s: its newest migration %s.sh is in no drift lock (an Omarchy release Grassfield does not support yet)"
                     % (tree, newest))
            fresh[pkg] = (newest, rows)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    if check:
        if release is None:
            for newest, pkg in sorted(by_newest.items()):
                if pkg not in releases:
                    problems.append("the supported release %s (newest migration %s) has no release line: regenerate it" % (pkg, newest))
                elif releases[pkg][0] != newest:
                    problems.append("release %s: newest migration %s, its drift lock says %s" % (pkg, releases[pkg][0], newest))
        for pkg, (newest, count) in releases.items():
            got = entries.get(pkg, {})
            if len(got) != count:
                problems.append("release %s: %d lines, %d migrations" % (pkg, len(got), count))
            if newest + ".sh" not in got:
                problems.append("release %s: its newest migration %s.sh is not listed" % (pkg, newest))
        for pkg in entries:
            if pkg not in releases:
                problems.append("lines of %s, a release with no release line" % pkg)
        for pkg, (newest, rows) in fresh.items():
            listed = entries.get(pkg, {})
            for name in sorted(set(rows) | set(listed), key=lambda n: (len(n), n)):
                if rows.get(name) != listed.get(name):
                    problems.append("release %s, %s: the tree gives %s, the list says %s" % (pkg, name, rows.get(name), listed.get(name)))
            if releases.get(pkg, (None, None))[1] not in (None, len(rows)):
                problems.append("release %s: the tree has %d migrations, the list says %d" % (pkg, len(rows), releases[pkg][1]))
        for p in problems:
            print("FAIL: " + p)
        if problems:
            sys.exit(1)
        print("omarchy-migrations-allow: ok (%s)" % ", ".join("%s: %d" % (p, releases[p][1]) for p in sorted(releases)))
        return 0
    if problems:
        fail("the list does not read: " + "; ".join(problems[:5]), 1)
    for pkg, (newest, rows) in fresh.items():
        releases[pkg] = (newest, len(rows))
        entries[pkg] = rows
    with open(LIST + ".new", "w", encoding="utf-8") as f:
        f.write(render(releases, entries))
    os.replace(LIST + ".new", LIST)
    for pkg, (newest, rows) in sorted(fresh.items()):
        allow = sum(1 for r in rows.values() if r[0] == "allow")
        print("omarchy-migrations-allow: %s: %d migrations, %d allow, %d exclude" % (pkg, len(rows), allow, len(rows) - allow))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
