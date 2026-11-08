# ADR-0029: Compress and Expand through bsdtar in a child process
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (integrator, under owner delegation D-5); applied with the combined Files PR 3–5 (2026-11-01) · Date: 2026-10-26 · Decider: integrator

## Context
- Owner goal (2026-10-26, `docs/specs/files.md` FP-59): Compress and Expand (zip, tar.*, 7z depending on the tools present).
- Finder: File > Compress makes `name.zip` (one item) or `Archive.zip` (several; `Archive 2.zip` when it exists) next to
  the items; opening an archive expands it next to itself with Archive Utility: one top-level item keeps its name, several
  go into a folder named after the archive; a name in use gets " 2".
- `libarchive` (and its `bsdtar`) is in Arch's core repository and a dependency of pacman, so it is on every Omarchy
  machine; 7-Zip is optional. KArchive (KDE Frameworks, a dependency of KIO) reads and writes zip, tar.* and 7z in-process.
- Archives are untrusted input (path traversal, links pointing out, huge expansions). The Files Applications location
  (FP-26, merged) moves icon decoding into a killable child process for the same reason.

## Options
1. **`bsdtar` in a child process**: one tool for zip, tar, tar.gz/bz2/xz/zst, 7z, cpio, iso and rar (read); killable;
   a crash never takes a Files window down.
2. KArchive in-process on a worker thread: no process, fewer formats, a decoder bug runs inside Files.
3. A tool per format (`unzip`, `7z`, `tar`): several dependencies and several sets of safety flags.

## Decision (proposed)
Option 1.
- Compress: `bsdtar --format zip -s ',^\./,,S' -cf <tmp> -C <folder> -- ./<name>…` into a hidden temporary name in the
  destination, then renamed to Finder's name (`name.zip`, `Archive.zip`, " 2"…); symbolic links are stored as links
  (zip's way), never followed. Each name is passed as `./<name>`: bsdtar reads an operand starting with `@` as an
  archive to copy from, even after `--` (verified 2026-10-26 with bsdtar 3.8.10: `-- @notes` failed with "Failed to
  open 'notes'", `-- ./@notes` stored the file); `-s ',^\./,,S'` stores the names without the `./` (verified: the
  archive lists `@notes`); the `S` flag leaves symbolic link targets as they are (without it a link to `./@notes` was
  stored pointing to `@notes`, and a link to `./` with an empty target; verified 2026-10-27 with bsdtar 3.8.9).
- Expand: `bsdtar -xf <archive> -C <tmp dir>` with `--no-same-owner --no-same-permissions --no-acls --no-fflags
  --no-xattrs` (`-P` never), into a new hidden folder next to the archive, then moved into place with Finder's naming.
  bsdtar refuses absolute paths and `..` components without `-P`; Files also refuses an archive whose listing (`bsdtar
  -tvf`) has a member above a size budget (free space minus a margin) and stops the child when the written size passes
  it. Links that point outside the new folder are kept as links (they are never followed by Files).
- Progress and cancel: the window's progress UI (FP-68); a cancel kills the child and removes the temporary folder.
- Encrypted archives: bsdtar asks for no passphrase here; Files reports "This archive is protected by a password" and
  offers nothing else (limit).
- Packaging: `libarchive` is declared in the desktop package's `depends`; `7zip` is not needed (bsdtar reads 7z).

## macOS reference
Archive Utility, as described above; Compress never asks for a format.

## Consequences
- Tests: the naming rules and argv builders in gtests; Compress then Expand round trips on files under `.dev` in a
  headless test, with a hostile archive (`../x`, an absolute member, a link out) that must not write outside the folder.
- Known limitation: password-protected archives, and multi-part archives.

## Applied (combined Files PR 3–5, 2026-11-01)
- `archivelogic.{h,cpp}` (names, argv, listing) and `archivejob.{h,cpp}` (the child process) as decided; temporary names
  `.grassfield-compress-<hex>.zip` and `.grassfield-expand-<hex>` next to the items, removed on every failure and cancel.
- The size budget is the sum of the listing's members (stricter than "a member above the budget") against the free space
  less 64 MiB; while bsdtar writes, the free space is read every 500 ms and the child stopped under that margin (a
  listing can lie). A listing longer than 30 s or 16 MiB is refused.
- Progress: the status bar ("Compressing “Archive.zip”…"); the copy window (FP-68) shows KIO's jobs only.
- Tests: `tests/unit/files/tst_archive.cpp` (real bsdtar round trips with an `@name`, a folder and a link; a member
  named `../payload-out` writes nothing outside; a cancel and a broken archive leave no temporary name).
