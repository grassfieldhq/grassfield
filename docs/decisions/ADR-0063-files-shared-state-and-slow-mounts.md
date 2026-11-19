# ADR-0063: Files: what the GUI thread reads, and state shared between Files processes
Status: Accepted (audit round 2, files scope, 2026-11-19) · Date: 2026-11-19 · Decider: integrator (audit fix brief 2) · Number: 0063 · Related: ADR-0035 (portal panels are the Files library), ADR-0029 (Compress and Expand), ADR-0028 (permissions), audit findings F2, F3, F5, F9, F11

## Context

The audit of Files found that "local" meant the `file:` scheme: a folder on NFS, SMB or sshfs, or a stale FUSE mount, made the
GUI thread resolve the folder's path, add an inotify watch, sniff file contents and read extended attributes (tags, folder
looks). One hung mount froze every window of Files and every Open and Save panel of the portal, which share the code. It also
found that Files is not single-instance (`Exec=grassfield-files %U`): each process loaded the sidebar's favourites and the
known tags once and wrote whole lists back, so one process wrote over another's edit. Paste in the column view went into the
focused column's folder while the title named another.

## Decision

1. The file system kind of a shown folder is found once per folder, off the GUI thread (`FsKind`, `apps/files/src/fskind.h`:
   statfs and realpath on a worker, at most 8 probes at once, answers kept 15 s). Only an allowlist of local disk file systems
   (`Kind::Disk`) is read from the GUI thread: content sniffing, tags, folder looks, the inotify watch, the canonical path of
   the staging check. Everything else (network, FUSE, pseudo file systems, unknown types, a folder whose probe has not
   answered) shows what KIO's out-of-process listing knows. A stuck probe holds one worker, never the GUI thread.
2. Files stays one process per launch (macOS has one Finder, but the portal's panels are separate processes in any case, so a
   single instance would not remove sharing). Shared lists in QSettings (`sidebar/favorites`, `sidebar/hidden`, `tags/known`,
   `tags/hidden`, the recent folders and servers) are read again from the file (`QSettings::sync`) right before each change and
   written at once; every Files and panel process watches the settings file and follows its changes.
3. Long work that was on the GUI thread moves to tracked worker threads (`Workers`, `apps/files/src/workers.h`), joined with a
   bound (3 s) at quit after a stop flag every walk checks: the removal of a staging tree, a big batch's destination check,
   Apply to enclosed items, the Trash's state, the file system probes, the searches.
4. Paste, Move Item Here and New Folder target the folder the title shows (the Finder's rule); in the column view that is the
   last column, whichever column has the keyboard; a column's own context menu targets that column.

## Consequences

- Rows on a network share show no tags or folder looks and type icons from the name only (KIO's own `setDelayedMimeTypes`
  guess); an ntfs-3g volume (FUSE) is treated as a network share.
- A row of a folder never probed shows its tags one event loop turn later (the probe's answer emits the row's change).
- Two processes editing the sidebar at the same instant are serialized by QSettings' lock file; neither edit is lost.
