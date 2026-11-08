# ADR-0028: Ownership and permission changes in Files, privileged ones through polkit
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (integrator, under owner delegation D-5). The unprivileged part is applied with Files PR 4; the
privileged part needs an `opus` reviewer PASS on this ADR before any of its code is written, then on that code
(privileged action, master-prompt R12 spirit). Revised 2026-10-26 after the first opus review (FAIL; see "Review
history") · Date: 2026-10-26 · Decider: integrator

## Context
- Owner goal (2026-10-26, `docs/specs/files.md` FP-60, FP-61): in Get Info, the owner, the group and the permissions can be
  changed (section "Sharing & Permissions"); "what needs rights goes through polkit, with an ADR and an opus review".
- Files shows owner, group and permissions read-only today (`apps/files/qml/InfoWindow.qml`).
- macOS: Sharing & Permissions lists the owner, the group and everyone with a privilege each (Read & Write, Read only,
  Write only, No Access), +/− for users and groups, "Apply to enclosed items", and a padlock that asks for an
  administrator before changes to items the user does not own.
- Linux: mode bits for owner, group and others (ACLs exist but are rarely used on a desktop). Without privileges a user
  can `chmod` items they own and `chgrp` them to a group they belong to; changing the owner needs `CAP_CHOWN`.
- KIO's own privilege path (the KAuth `file_helper` and the `org.kde.kio.file` polkit action) is not built into Arch's
  `kio` (verified 2026-10-26 on kio 6.31 from the Arch mirror: no helper and no policy file in the package), so it is not
  available on Omarchy.
- Grassfield never writes code that runs as root (R12), except the root programs of ADR-0033 c.1
  (`grassfield-channel-helper` and `grassfield-channel-scriptlet`, owner decision O1; ADR-0030's amendment for Settings'
  path) and Grassfield Store's `grassfield-store-helper` (ADR-0037 b.1, owner decision ST4 of 2026-10-27; ADR-0030's second
  amendment); Files has no such exception. The session's polkit agent is the shell's (Quickshell Polkit, `shell/security`,
  R12 PASS). `pkexec` and GNU coreutils are installed on Omarchy: polkit 127 and coreutils 9.11 on the owner's machine
  (Omarchy 4.0.4); the probes below ran with coreutils 9.12 (the cloud sysroot; its pkexec is 128 and could not run: no
  polkit daemon there).
  pkexec's action is the generic `org.freedesktop.policykit.exec` (admin password every time: it keeps no
  authorization); its prompt says "Authentication is required to run a program as another user", whatever the program.
- A descriptor's `/proc/self/fd/<n>` entry is a "magic link": a path walk through it lands on the opened inode itself,
  not on a path looked up again, so a program given that name acts on exactly the item the descriptor pins. Acting on
  the entry with `--no-dereference` (`-h`) would act on the `/proc` link instead and change nothing.

## Options
1. **Unprivileged only.** Items the user owns: privileges and group (to the user's groups) through `KIO::chmod` and
   `KIO::chown`; anything else read-only, with the reason. Safe, but not the Finder's padlock.
2. **pkexec + the system's coreutils** for the rest: Files runs `pkexec /usr/bin/chown|chmod` with fixed options and no
   shell; polkit asks for an administrator through the session's agent (`org.freedesktop.policykit.exec`, auth_admin;
   a generic message, the command line only in the prompt's details). No Grassfield code runs as root.
3. **An own polkit helper** (a D-Bus system service or a pkexec target) that resolves paths with `openat2(RESOLVE_NO_SYMLINKS)`.
   Closes path races fully, but it is root code: excluded by R12.
4. KIO's KAuth helper: not available (context).

## Decision (proposed)
Option 1 now, option 2 behind the review, with these rules:
- The editor is Finder's: rows for the owner, the group and "everyone" (others), each with a privilege popup (Read &
  Write, Read only, Write only, No Access), the padlock, and "Apply to enclosed items…" (confirmed). Execute bits keep
  their state on files; on folders "Read" maps to r-x (macOS lists folder access, not execute). Special bits (setuid,
  setgid, sticky) are shown and never changed by the popup; the editor refuses to add setuid or setgid.
- Unprivileged path (applied, Files PR 3–5 combined): the item is pinned as below (`O_PATH | O_NOFOLLOW`, `fstat`: a
  folder or a regular file the user owns) and changed with `chmod(2)` / `chown(2)` on its `/proc/self/fd/<n>` entry,
  rather than a KIO job that looks the path up again; "Apply to enclosed items…" runs `/usr/bin/chmod -R -- OPS <folder>`
  as the user (the `+`/`-` operators below, probe 12; the folder checked to be no link). Errors in the window's banner;
  the window reads the item again afterwards. An item the user does not own shows the closed padlock and its reason.
- Privileged path (after the review): the padlock opens one polkit prompt per `pkexec` call, with one `--` before the
  operands, absolute program paths and no shell. Each command is proven by a probe below.
  - Pinning: Files opens the item with `O_PATH | O_NOFOLLOW | O_CLOEXEC`, checks the descriptor (`fstat`: the device
    and inode it showed, a regular file or a folder, not a symbolic link, on a local filesystem) and gives that
    descriptor to `pkexec` as its standard input (no other descriptor is passed). The root child names its own standard
    input, `/proc/self/fd/0`, and follows it (no `-h` on that name): no path is looked up again, and no other process's
    `/proc/<pid>` entry is used, so a swapped item, a swapped parent folder, or Files dying during the prompt and its
    process number being reused, cannot redirect the change (the descriptor is pkexec's own inherited input).
  - One item: `pkexec /usr/bin/chown -- USER:GROUP /proc/self/fd/0` (probes 2, 7) and
    `pkexec /usr/bin/chmod -- MODE /proc/self/fd/0` (probe 6), MODE four octal digits built from the popups and the
    item's current special bits (kept as they are: the editor never adds setuid or setgid). USER and GROUP are looked
    up from the system databases and passed as names that exist. An item that is not a folder and has more than one
    hard link (`st_nlink` > 1) is refused before any prompt: the change would reach a name outside what was chosen.
  - "Apply to enclosed items…" (confirmed), owner and group: two calls, the contents first, then the folder itself:
    `chown -R -H -h -- USER:GROUP /proc/self/fd/0` (probe 5: `-H` enters the folder through the link, `-h` changes the
    symbolic links found inside themselves, never their targets; on its own it leaves the folder unchanged), then
    `chown -- USER:GROUP /proc/self/fd/0` (probe 2). The folder changes owner last, so the new owner cannot add, remove
    or swap entries in it while the root walk is still running. Two prompts, as the action keeps no authorization.
    `-R -H` without `-h` is never used: it changed a file outside the folder through a link (probe 4).
  - "Apply to enclosed items…", privileges: one `chmod -R -H -- OPS /proc/self/fd/0`, OPS the popups as `+` and `-`
    operators per class (Read & Write `+rwX`, Read only `+rX,-w`, Write only `+wX,-r`, No Access `-rwx`; for example
    `u+rwX,g+rX,g-w,o-rwx`). chmod never follows the links it meets in the walk (probes 10, 12); `+`/`-` keep the
    special bits (probe 12: the setuid file 4755 → 4750, the setgid folder 2775 → 2750), where `=` clears setuid on
    files (probe 10: 4755 → 0750). Never an octal mode recursively: it gave the folder's bits to every file (probe 9).
    `X` gives execute to folders and to files some class can already execute (the group given Read can run a script
    its owner runs): said in the confirmation.
  - A recursive privileged change is refused before any prompt when `fs.protected_hardlinks` is not 1 (a hard link to
    a file outside the folder would be changed as root) or when a mount point lies inside the folder
    (`/proc/self/mountinfo`; chown and chmod cross mount points). Inside the walk, a link swapped in is changed itself
    (`-h`), not followed; coreutils' walk opens each folder relative to its parent and checks it (no probe can show a
    race: this rests on coreutils).
  - A change of owner clears setuid and setgid on files (the kernel does it: probe 5, 4755 → 0755): Files re-reads and
    shows it.
- Refusals before any prompt: items outside local filesystems, the Trash, symbolic links (they are shown with their own
  owner and never changed), and anything under `/proc`, `/sys` and `/dev`.
- A cancelled or failed authentication leaves everything unchanged and says so; Files re-reads the item afterwards and
  shows what the system reports, never what it asked for.
- Dev and tests: the privileged path is refused in a dev session (`runmode::dev`) and in tests, except a test mode that
  replaces `pkexec` with a recording stub (no privilege ever used by the agent). That stub is a dev setting
  (`FILES_PKEXEC`, honoured only in `dev`): it is listed in ADR-0019's table.

## Probes (2026-10-26, coreutils 9.12, a test tree under `.dev/`, the container's root standing for pkexec's child)
`docs/audits/finder-parity-2026-10-26/tools/adr0028-probes.py <dir under .dev/>` rebuilds the tree before each command
and gives the command the pinned `O_PATH | O_NOFOLLOW` descriptor of the test folder (or file) as its standard input, as
designed above. The tree: a folder (0755), two files (0644), a script (0755), a setuid file (4755), a setgid folder
(2775), a subfolder with a file, and a symbolic link to a file outside the folder. Owner and group set: 12345.
`fs.protected_hardlinks` was 1.

| # | Command (descriptor of) | Result |
|---|---|---|
| 1 | `chown --no-dereference -- U:G /proc/self/fd/0` (folder; first version) | exit 0, nothing changed |
| 2 | `chown -- U:G /proc/self/fd/0` (folder) | the folder itself only |
| 3 | `chown -R -h -- U:G /proc/self/fd/0` (folder) | exit 0, nothing changed (the walk does not enter the link) |
| 4 | `chown -R -H -- U:G /proc/self/fd/0` (folder) | the folder, everything in it **and the file outside, through the link** |
| 5 | `chown -R -H -h -- U:G /proc/self/fd/0` (folder) | everything in it and the link itself (setuid cleared by the kernel: 4755 → 0755); not the folder, not the file outside |
| 6 | `chmod -- 0600 /proc/self/fd/0` (a file) | that file 0644 → 0600 |
| 7 | `chown -- U:G /proc/self/fd/0` (a file) | that file |
| 8 | `chmod -- 0640 -- /proc/self/fd/0` (a file; two `--`, first version) | exit 1, "cannot access '--'", and the file was changed all the same |
| 9 | `chmod -R -H -- 0700 /proc/self/fd/0` (folder) | every file 0700 (the folder's bits); the setuid file 4755 → 0700 |
| 10 | `chmod -R -H -- u=rwX,g=rX,o= /proc/self/fd/0` (folder) | folder 0750, files 0640, script 0750, setuid file 4755 → 0750 (`=` clears it), setgid folder 2775 → 2750; the link and the file outside unchanged |
| 11 | `chmod -R -- u=rwX,g=rX,o= /proc/self/fd/0` (folder) | as 10: chmod follows a link given as an argument by default |
| 12 | `chmod -R -H -- u+rwX,g+rX,g-w,o-rwx /proc/self/fd/0` (folder) | folder 0750, files 0640, script 0750, setuid file 4755 → 4750, setgid folder 2775 → 2750; the link and the file outside unchanged |

## Risks for the review
- NOT VERIFIED: that pkexec (polkit 127) gives its standard input to the program it runs. Nothing here shows it (the
  sysroot's pkexec could not run). The owner checks it once before any code, on a test file:
  `pkexec /usr/bin/stat -L -c %i /proc/self/fd/0 < testfile` must print the inode `stat -c %i testfile` prints. If it
  does not, the privileged path is not built: there is no fallback that looks a path up again as root.
- `chown` and `chmod` through an `O_PATH` descriptor's magic link work (probes 2, 5, 6, 7, 10), as root in a container;
  the same check on the owner's machine runs with test files owned by a test user, never the owner's files.
- The polkit prompt is generic and shows `/proc/self/fd/0`, not the item: the Files sheet before it names the item and
  the change in plain words, and says that the system will ask for an administrator's password (twice for owner and
  group with "Apply to enclosed items").
- `org.freedesktop.policykit.exec` is a generic action: an administrator may have disabled it; then the padlock reports
  that changes need an administrator in a terminal.

## Review history
- 2026-10-26, opus, FAIL on the first version. BLOCKER: `--no-dereference` on `/proc/<pid>/fd/<n>` acted on the link and
  changed nothing; a working recursion (`-R -H`) would follow symbolic links inside the tree as root. MAJOR: two `--`
  (the second read as a file name), one octal mode for a recursive change, the caller's process number reusable while
  the prompt waits, and the hidden ⌘X of decision F-6. The revision: the child's own standard input, followed; one `--`;
  F-6 drops ⌘X for files (`docs/specs/files.md`); after the owner's prompt, the reviewer's two-call plan for the
  recursive owner change and `+`/`-` operators for recursive privileges, each command proven by a probe (above), the
  real versions (coreutils 9.11, polkit 127), the stub in ADR-0019's table. A new opus review is needed before any code.

## Consequences
- PR 4 ships option 1 and the editor; option 2 lands in the same PR only with the review PASS, otherwise in a follow-up.
- Tests: the mode arithmetic and the argv builder in gtests (no privilege), the stub-pkexec flow in a headless test,
  the polkit prompt itself on the owner's machine (L2).
