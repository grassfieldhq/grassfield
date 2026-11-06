# ADR-0050: Staged rollout of Grassfield's own updates, through per-cohort repository paths
Status: Proposed (2026-11-05), applied provisionally (owner rule: decide alone, the recommended option, macOS model first) ·
Date: 2026-11-05 · Decider: owner (revisit), integrator (merge after the opus security review of the root code below) ·
Number: 0050 · **Amends ADR-0033** (a, c, d, g, h) and `docs/specs/updates.md` (U34-U38).

Inspired by Project Luma's `luma-update` (its signed update graph, local wariness, linear ramp, security bypass, pauses,
dead ends and download conditions; Apache-2.0). Mechanism reimplemented for pacman; no code copied.

## Context
- A Grassfield release reaches every machine of a channel at once: `[grassfield]` is one signed pacman database per channel
  (ADR-0033 g, h), and `omarchy update` (`pacman -Syu`) installs whatever that database offers. A bad release therefore
  reaches everyone before anyone can stop it.
- Luma stages its releases: each device draws once a random **wariness** in [0, 1) kept locally; a release's **reach**
  rises linearly from a start percentage over a ramp; a device takes the release once its wariness is below the reach;
  security releases skip the ramp; a release can be paused or turned into a dead end; downloads wait for an unmetered
  connection and mains power or more than 30 % battery; nothing identifying the device is sent.
- Luma decides on the device, after reading a signed graph. **pacman cannot be told to wait**: a database offers the same
  version to every machine that syncs it, and `omarchy update` runs pacman directly, outside Grassfield. A hold kept by
  Grassfield's client (the checker, the pane, Update Now) would only hide the release from Grassfield's own UI.
  So the decision has to be made by **which database a machine syncs**, that is by its `Server` line, which only root
  writes (ADR-0033 c.1).
- `grassfield-packages` (the publishing side) is not available in this session: its part is written here as a contract
  (g) and is NOT VERIFIED end to end.

## Options compared
| | A. Per-cohort paths (chosen) | B. Client-side hold | C. Server-side cohorts by request | D. Per-release paths chosen by the client |
|---|---|---|---|---|
| Mechanism | 20 paths per channel, `<base>/<channel>/cohort/<NN>/$arch`; the machine's Server line names the cohort its local wariness falls in; each cohort path resolves to the old or the new snapshot by the ramp | `IgnorePkg` in `pacman.conf`, or Grassfield's Update Now refusing the release | the CDN maps a request to a cohort by its IP or headers | the Server line names an immutable snapshot (`snap/<id>`), rewritten as the reach grows |
| Stops `omarchy update`? | yes: the database the machine syncs does not list the release | no: Omarchy rewrites `[options]` (ADR-0033 a); Update Now is not the only way to update; `IgnorePkg` on `grassfield-desktop` leaves its split packages (which depend on `grassfield-desktop=<ver>`) unresolvable | yes | yes |
| Device identity | the path names one of 20 random buckets (5 % of machines each), never an identifier | none | IP-derived: an identifier by construction | none |
| Stale database | a cohort only moves forward (g.4), so a synced copy is never newer than its path | n/a | a laptop changing network changes cohort and can go back to an older snapshot: R4's "signature … is invalid" for every roaming machine | each rewrite changes the path: P7 unless the synced files are dropped every time |
| Cohort path missing | the plain channel lines follow the cohort lines (a 404 falls back); during a ramp a missing advanced cohort fails like a bad publication (a2) | n/a | n/a | a snapshot deleted after 7 days (h.2) stops every update (a2) |
| Root work | a rewrite at the post_upgrade scriptlet, when the repository advertises cohorts | none | none | a root rewrite whenever the reach changes: a timer or daemon as root (§5.8: refused) |
| Verdict | **chosen** | rejected: does not work with pacman | rejected: violates "no device identifier", breaks roaming machines | rejected: root daemon, snapshot retention |

**How root learns that the repository serves cohorts** (A needs a signal that root can trust, with no network in root):
- (i) the root helper downloads and verifies the signed descriptor itself: network and a JSON parser in root (rejected:
  ADR-0033 c.1 "uses no network");
- (ii) a polkit action without a password that the shell calls to enroll: a new root entry point (rejected);
- (iii) **a marker package in the signed database** (chosen): the publisher adds a package named `grassfield-rollout`
  (`pkgver` 1: this ADR's scheme) to every database of a channel that serves cohort paths. Root reads it with
  `pacman -Sl grassfield`, which loads the synced database pacman verified (`SigLevel = Required`): the signal has exactly
  the database's trust, needs no network, and is one `repo name version` line.

## Decision

### 1. Wariness and cohort (root, `grassfield-channel.sh`)
- The wariness is drawn once from `/dev/urandom` (32 bits, `od -An -N4 -tu4`) by the root scriptlet the first time it
  enrolls, and stored in **`/var/lib/grassfield/rollout-wariness`** (root, 0600, written through a temporary file and a
  rename; `/var/lib/grassfield` root 0755, never a link). pacman reads the Server line as root, so the value it depends on
  is root's: a user cannot pick an earlier cohort (a person who wants a release early has no hatch here, section 5).
  New directory: the only FHS place for state root keeps across boots (`/etc` is configuration, `/run` is lost).
- **Cohort** = `floor(w × 20 / 2³²)`, two digits `00`-`19`. 20 cohorts (5 % steps) is a contract constant: changing it
  changes every path, so a new count would be a new scheme (`grassfield-rollout` `pkgver` 2).
- The wariness survives Turn Off… and channel changes (same cohort after Set Up… again); it is deleted only when
  `grassfield-desktop` is removed (the scriptlet's `remove`, ADR-0033 b.8's "leaves with Grassfield").
- It never leaves the machine. What leaves is the cohort number in the request path (one of 20 buckets), which adds at
  most log2(20) ≈ 4.3 bits to what the request's IP address already tells the server. No header, cookie or query is added.

### 2. The Server lines
- **Plain form** (today's, ADR-0033 g): `Server = <base>/<channel>/$arch` for the primary, then each mirror.
- **Cohort form**: `Server = <base>/<channel>/cohort/<NN>/$arch` for the primary and each mirror, **then** the plain lines.
  pacman tries the next Server when a download fails (ADR-0033 Q1), so a cohort path that answers 404 falls back to the
  plain path. Built by `generate.py` as `/usr/share/grassfield/pacman/grassfield-<channel>-cohort.conf` with the literal
  `@COHORT@`, which root replaces with the two validated digits (no other text is computed in root).
- **Enrollment** happens only in `grassfield-channel-scriptlet upgrade` (the `post_upgrade` of `grassfield-desktop`, run
  as root by pacman in `omarchy update` and in Update Now alike), after the host migration of ADR-0033 h.3:
  - only a file that is **exactly** one of this build's forms of `stable` or `beta` is touched: its lines, once comments
    and blanks are removed, are the plain template's, or the cohort template's for some cohort. A `custom` file, and one
    an administrator changed (a Server line added, a SigLevel changed), is left as it is: enrollment never overwrites an
    administrator's lines (security review of the staged rollout, L4). Such a machine stays where its file points;
  - `pacman -Sl grassfield` lists `grassfield-rollout 1-<rel>` → the cohort form with this machine's cohort; a listing
    without it → the plain form; **no listing** → nothing changes (review MEDIUM 2). No listing is pacman failing, or an
    empty answer: with no synced `grassfield.db` libalpm reads a missing database, `pacman -Sl` prints nothing and exits 0
    (re-review LOW 1), while a real listing always names `grassfield-desktop`;
  - **the synced `[grassfield]` files are never deleted here** (review HIGH 1). The scriptlet runs inside `omarchy update`,
    whose later `omarchy-update-aur-pkgs` runs `yay -Sua --noconfirm` on the packages no sync database lists: without the
    database every `grassfield-*` package would be foreign for the rest of that run, and an AUR package of the same name and
    a higher version would be built and installed (GF-045), on the whole fleet at once. So:
    - every change of form or cohort (plain → cohort, cohort → plain, a change of cohort) keeps them and sets their time to
      the epoch (`touch -h -c -d @0`, never through a link). a download condition on a file dated the epoch is
      always met (libalpm hands the file's time to libcurl, `curl -z`: recent libcurl, 8.23 included, does send an
      `If-Modified-Since` for time 0, review of the Luma pull request, finding 4), because the server's copy is newer than
      1970: the next sync downloads the database and its signature (200 for both, never a 304), never a
      new `.sig` beside a kept `.db` (P7). plain → cohort does it too (re-review LOW 3): g.4 makes a cohort path never older
      than the plain path, but the hosts' Last-Modified times are not trusted to order them, and a 304 for the database
      beside a newer `.sig` is one R4 failure. ADR-0033 h.3's host migration in the same scriptlet does the same.
    Editing inside the transaction affects only the next sync (Q6).
  - Any failure (no listing, no wariness drawn or read) leaves the file as it is.
- `grassfield-channel-helper set` (Set Up…, Beta Updates, Repair…) keeps writing the **plain** form and drops the synced
  files (outside any transaction: it is refused while pacman runs, and `omarchy update` syncs before its AUR step): the
  next Grassfield upgrade re-enrolls. `restore` and `off` are unchanged.
- A machine that never runs this code (an older Grassfield) stays on the plain path, which the publisher keeps as the
  **last** cohort (g.3): nothing changes for it until it upgrades, and it never gets a release before the ramp ends.

### 3. The signed rollout descriptor (for the UI only)
Who gets what is decided by the paths (pacman). The descriptor only tells the pane what is going on.
- `grassfield-rollout.json` and its detached signature `.sig`, fetched by `grassfield-update-check` (the user) from the
  **plain** channel path (a cohort segment is removed from the Server URLs), only when its own `[grassfield]` sync lists
  `grassfield-rollout`: before the repository advertises staged rollout, the client sends no new request.
- Verified as the release notes are (ADR-0033 d.8): `gpgv` with grassfield-keyring's private folder, the VALIDSIG primary
  listed in `grassfield-trusted` and absent from `grassfield-revoked`. curl: `https` only (`file` when this build's base is
  `file://`), at most 16 KiB, 15 s.
- **Strict schema** (anything else refuses the whole file; nothing is partly believed):
  ```json
  {"schema": 1, "channel": "stable", "arch": "x86_64", "cohorts": 20,
   "generatedAt": "2026-11-05T10:00:00Z", "expiresAt": "2026-11-26T10:00:00Z",
   "releases": [{"version": "1.0.1-1", "importance": "normal", "state": "rolling",
                 "rollout": {"startAt": "2026-11-05T10:00:00Z", "startPercent": 5, "durationHours": 168}}]}
  ```
  - exactly these top-level keys; `schema` 1; `channel` the client's; `arch` the machine's; `cohorts` 20;
  - times `YYYY-MM-DDTHH:MM:SSZ`; at most 16 releases, versions in the notes' grammar and unique;
  - a release has exactly `version`, `importance` (`normal`|`security`), `state` (`rolling`|`paused`|`withdrawn`) and
    `rollout`: an object with exactly `startAt`, `startPercent` (integer 0-100), `durationHours` (integer 0-8760) and, only
    when `state` is `paused` (where it is required), `pausedAt` not before `startAt`; or `null` (a release that skips the
    ramp: a security release, or a withdrawn one);
  - **freshness**: `generatedAt` at most one day ahead of the clock; `expiresAt` after now, after `generatedAt` and at most 31
    days after it; `generatedAt` not older than the newest one this checker accepted for the channel (anti-replay, kept in
    its cache). The publisher re-signs at every publication; 31 days (not Luma's 3) because each signing run waits for the
    owner's approval (ADR-0033 b.7). A stale or invalid descriptor only removes the explanation from the pane: pacman is
    unaffected, so a freeze attack on it hides nothing that the database does not already hide (ADR-0033's known limit
    "an old but validly signed database can be replayed").
- **Reach** (the formula the publisher applies, g.4, and the checker reproduces): before `startAt` 0; a `security` release
  or one without `rollout` 1; a duration of 0 → 1; else `s + (1 − s) × clamp((t − startAt) / duration)` with `s =
  startPercent / 100` and `t = min(now, pausedAt)`. Cohort `k` is offered when `k < reach × 20`; the plain path when
  `reach ≥ 1`.
- What the checker reports (`rollout` in its answer, ADR-0033 d's output): `descriptor` (`ok`, `none`, `invalid`, `stale`),
  `cohort` (the Server line's, or null), `staged` (the newest `rolling` release newer than the installed version and than
  what the database offers, with its importance and the estimated `offerAt`), `withdrawn` (the installed version when the
  descriptor marks it withdrawn), `security` (the release the database offers is a security release).

### 4. UI (Settings › General › Software Update; macOS 27 pane, existing rows)
- **Staged**: a Grassfield row (the brand tile) "Grassfield 1.0.1 is being released gradually." / "It will be offered to
  this computer soon." No button. The headline keeps what the database says (up to date, or the other updates).
- **Security**: the available Grassfield release's row reads "Grassfield 1.0.2" with "Important security update. Installed:
  1.0.1"; a security release still being synced reads "Grassfield 1.0.2 is an important security update." / "It will be
  offered to this computer soon."
- **Withdrawn**: the headline says "Grassfield 1.0.1 has been withdrawn" (not "This computer is up to date", review of the
  Luma pull request, nested finding 10), and the row under it "A corrected version is on its way." / "It will be offered to
  this computer as soon as it's ready."
- A **paused** release shows nothing (macOS explains no phased release); one that was staged disappears from the pane.
- French: « Grassfield 1.0.1 est en cours de déploiement progressif. » / « Elle sera bientôt proposée sur cet ordinateur. »
  and the rest in `translations/grassfield_fr.ts`.

### 5. No "Update Now" escape hatch for a staged release (decision)
Installing a staged release early would need a sync of `[grassfield]` from another path for one run. The update helper
swaps the databases it checked into the system (ADR-0033 s3.2 step 8): the machine would then hold a database newer than its
own cohort path's, and its next sync would get a 304 for the database and a 200 for the older signature (R4: "signature …
is invalid", then a2). Avoiding that means a new root mode in the update helper (a separate dbpath for one repository, not
swapped in) — a widening of SU-M1's root code that this slice does not justify. Update Now keeps installing what the
database offers. A later step may add it; the pane's wording ("soon") promises no date.

### 6. Background checks (Luma's download conditions, where Grassfield checks today)
The shell's automatic check (ADR-0033 d.5, U7) already skips offline and metered connections. It now also waits while the
computer runs **on battery at 30 % or less** (UPower's `onBattery` and the display device's percentage, the shell's
`Battery` service). A computer with no battery, or with UPower's `onBattery` false, checks. When the check was skipped for
power, it runs again when the computer is plugged in, or at the next recheck (30 minutes). A check the person asks for
(Check Now, the pane opening) is never held back. Grassfield's background work downloads databases and notes only: the
packages are downloaded by Update Now or `omarchy update`, which the person starts (Update Now refuses below 50 % on
battery, s3.2). Unknown is permissive for the battery (a desktop without UPower must still check), as it already is for
the metered query (U7): a different choice from Luma, which treats unknown as a battery of unknown charge.

### 7. Failure modes
| Case | What happens |
|---|---|
| The repository never advertises (today) | no marker → plain form kept, no descriptor request: nothing changes on any client |
| Stale synced database | a cohort only moves forward (g.4); every change of form or cohort sets the synced files' time to the epoch, so libalpm downloads both the database and its signature again (a conditional request dated 1970 is always answered with the full file, 200; P7); they are never deleted inside a transaction (GF-045) |
| A cohort path missing on the server | its 404 falls back to the plain lines. Outside a ramp the cohort and plain path name the same snapshot: no effect. During a ramp an advanced cohort's machine holds a newer database than the plain path → 304 + older `.sig` → "signature … is invalid" → `failed`, then `blocking` after two failures 15 minutes apart, with Turn Off… (a2). Forbidden by g.5 |
| Marker published, cohort paths not served (a publisher bug) | enrolled machines fall back to the plain path at each sync (pacman prints a 404 error line in Omarchy's terminal) until it is fixed or the marker is withdrawn (then the next Grassfield upgrade writes the plain form) |
| A machine changes channel | `set` writes the plain form of the new channel and drops the synced files; the same cohort is enrolled at the next Grassfield upgrade |
| Omarchy's own channel change (P11) | its hook only re-adds the `[grassfield]` lines; the file, and its form, are untouched |
| Rollback | pacman never downgrades (`-Syu`); a pointer never goes back (h.2): a withdrawn release is paused for the cohorts that do not have it and fixed forward for those that do (g.6) |
| A manual downgrade (`pacman -U`) to a Grassfield built before ADR-0050 | that build reads the cohort form as `custom`: the pane offers Repair…, which writes the plain form; until then pacman keeps working (the cohort lines, then the plain lines) and the older Store falls back to the build's base for its catalog |
| An administrator's own Server line or SigLevel in `grassfield.conf` | the file is not one of this build's forms: never enrolled or unenrolled, left as it is (the channel reads `custom` once its primary is not this build's) |
| Offline machine | syncs nothing; when back, gets whatever its cohort resolves to now (it may skip a release, which pacman handles); an expired descriptor is ignored |
| Clock wrong on the client | pacman is unaffected (the server's clock decides); the pane's descriptor is refused when `generatedAt` is more than a day ahead, or ignored once `expiresAt` passed |
| An older Grassfield, or an unenrolled machine | the plain path: the last cohort |
| Grassfield Store | reads the channel from the primary Server: the cohort form is now recognised and the catalog is fetched from the plain channel path (`apps/store/src/channel.cpp`) |

### 8. Root code changed (OPUS SECURITY REVIEW REQUIRED before merge)
- `packaging/pacman/grassfield-channel.sh`: `gf_state_dir_ok` (the state folder root's own, never a link, checked before
  every read and write), `gf_wariness`/`gf_cohort` (draw once, store, map), `gf_forget_wariness`, `gf_rollout_advertised`
  (`pacman -Sl grassfield` read whole, one regex; 0/1/2), `gf_write_cohort` (the template with `@COHORT@` replaced by two
  validated digits, temp file and rename as `gf_write_file`), `gf_effective`/`gf_form_text` (the exact-form check),
  `gf_rollout` (the enrollment rule of 2), `gf_refetch_synced` (the synced files' time set to the epoch, `touch -c`, links
  skipped); `gf_migrate` (h.3) also recognises a previous base's cohort form and now calls `gf_refetch_synced` instead of
  `gf_drop_synced`.
- `packaging/pacman/grassfield-channel-scriptlet`: `upgrade` runs `gf_rollout` after `gf_migrate`; `remove` also deletes
  the wariness.
- `packaging/pacman/generate.py` (build time) and `packaging/arch/PKGBUILD`: the two cohort templates.
- Not changed: `grassfield-channel-helper` (its verbs), the polkit policy, `grassfield-update-helper`, `grassfield-update-run`.

## g. Contract (what `grassfield-packages` must publish; amends ADR-0033 g and h)
1. **Opt-in per channel.** Nothing below exists for a channel until its publisher turns staged rollout on. Turning it on
   is one publication that creates the 20 cohort paths (all resolving to the current snapshot) and the descriptor
   **before or in the same pointer write** as the first snapshot whose database lists `grassfield-rollout`. That
   publication **must carry a Grassfield release** (a new `grassfield-desktop` version or pkgrel, at 100 %, with no ramp,
   built with ADR-0050's client): machines enroll only in that package's `post_upgrade`, so a marker published alone
   leaves every machine on the plain path, and the first ramp would then reach nobody before it ends. The first staged
   release comes after it.
2. **The marker.** `grassfield-rollout-1-<rel>-any.pkg.tar.zst` (`arch=any`, no files, no install script, no dependency,
   `pkgdesc` "Marker: this channel serves Grassfield's per-cohort paths (ADR-0050)"), signed like every package, listed in
   every snapshot's database of that channel while cohorts are served. Never a dependency of anything; nothing installs it.
   It joins g's list of `grassfield-*` packages (no `replaces=`).
3. **Paths.** `<channel>/cohort/<NN>/x86_64/` for `NN` in `00`-`19`, serving the fixed names (`grassfield.db`,
   `grassfield.files`, `grassfield-notes.json`, `grassfield-catalog.v1.json`, each with `.sig`) of a snapshot, exactly as the
   plain path `<channel>/x86_64/` does (h.2, h.5), and the package files (immutable names: a redirect or the same objects).
   The plain path is the **last** cohort.
4. **Resolution, monotonic.** Per channel one rollout state object (`<channel>/x86_64/rollout`, not cached, like
   `pointer`): `{"base": "<snapshot id>", "next": "<snapshot id>"|null, "startAt", "startPercent", "durationHours",
   "pausedAt"|null, "descriptor": "<id>"}`. Cohort `k` resolves to `next` when `next` is set and `k < reach(now) × 20`,
   else to `base`; the plain path to `next` when `reach(now) ≥ 1`. `reach` is section 3's formula. A cohort's snapshot
   only ever moves to a **newer** snapshot (created later): R4 forbids going back. Implementation: the Worker of h.5 (a)
   computing it per request (recommended: no scheduled write), or, with option (b), a promotion job that copies forward
   on a schedule. Once `reach ≥ 1`, the next publication sets `base = next`, `next = null`.
5. **Never removed.** Once a channel has published the marker, its 20 cohort paths keep resolving for as long as the marker
   is published and for at least 90 days after it is withdrawn (then every cohort resolves as the plain path does).
6. **Events.**
   - *New release*: a snapshot S built from the current state (h.2), `next = S`, the ramp chosen by the owner. Default
     (owner decision of 2026-11-06, "il faut tout déployer"): `startPercent` 100, `durationHours` 0, so every cohort and
     the plain path get the release at once; a gradual ramp (for example `startPercent` 5 over `durationHours` 168) only
     when the owner asks for one for a given release. Descriptor `rolling`. (Section 3's schema keeps a ramp object for a
     normal release: a ramp of 100 % is how "everyone at once" is written.)
   - *Security release*: built from the newest release, including the one rolling (so no cohort goes back), `base = next =`
     its snapshot, `rollout: null`, `importance: "security"`: every cohort and the plain path at once.
   - *Pause*: `pausedAt = now` (reach frozen: cohorts already on `next` stay there); descriptor `paused` with `pausedAt`.
     Resume: a new `startAt` and `startPercent` equal to the frozen reach.
   - *Dead end (withdraw)*: a pause for the cohorts that do not have it, descriptor `withdrawn`; the machines that have it
     are fixed forward by a newer release (a fix, or the previous release rebuilt with a higher version), published like a
     security release. Never a pointer moved back (h.2), never `pacman -Suu`.
   - *Barrier* (Luma's "must pass through X"): not offered. A database serves one version; upgrade-path steps belong in
     package scripts and Omarchy-style migrations.
7. **Descriptor.** `grassfield-rollout.json` and `.sig` at the plain path's fixed names, resolved through the rollout state's
   `descriptor` id to `rollout/<id>/` (immutable, written before the state, so the file and its signature switch together),
   UTF-8, at most 16 KiB, section 3's schema exactly, signed by the signing job (b.7) at every publication; `expiresAt`
   at most 31 days after `generatedAt`, and the publisher re-signs before it passes while a ramp runs.
8. **Signing.** Only the signing job holds the key (b.7). It signs the marker package, the databases and the descriptor; the
   rollout state and pointers are unsigned objects that name only snapshots the signing job made. A Worker or promotion job
   holds no key and only read access (Worker) or write access to pointer objects (promotion job).
9. **Privacy.** No query string, header or cookie is required. Cohort numbers in access logs are not joined with anything;
   counts per cohort, if ever kept, are aggregates.

## Tests
- `tests/shell/update_check.sh` (extended): the descriptor's schema, bounds, freshness, anti-replay and signature; the reach
  formula; cohort offering; `staged`, `withdrawn`, `security`; no request without the marker; the cohort form's channel.
- `tests/shell/staged_rollout_root.sh` (new): the root library on a temporary tree: wariness drawn once, kept, redrawn
  when malformed; a link, a state folder that is a link or another user's refused on read and write; the cohort mapping at
  its bounds; the marker read (listed, a listing without it, pacman failing, a long listing written by the stub's own
  process); `gf_rollout` (plain↔cohort, same cohort untouched, a custom or administrator-changed file untouched, no
  listing (pacman failing, or no synced database: an empty answer) or no wariness → unchanged, the synced files kept with
  their time the epoch on every change, `touch -h`
  otherwise); `gf_migrate` (the same synced-file rule, links not followed); the templates `generate.py` writes. Its new cases
  fail on the reviewed library (16 failures) and on a `grep -q` mutant of the marker read.
- `tests/integration/software_update.sh`: A7e now expects the synced files kept with their time at the epoch and no
  foreign `grassfield-*` package; the ADR-0050 container case (A17) is described there, to add with a marker snapshot.
- `tests/shell/channel_set_rule.sh`: `grassfield-channel-set` prints `stable`/`beta` for the cohort form.
- `tests/unit/tst_softwareupdate.qml`: the view's `rollout`, `automaticAllowed` (battery); `tst_settingssoftwareupdate.qml`:
  the staged, security and withdrawn rows; `tests/unit/store/tst_channel.cpp`: the cohort form.

## NOT VERIFIED
- The whole flow end to end: no publisher, Worker or cohort path exists (grassfield-packages not available here).
- `pacman -Sl grassfield` from inside a `post_upgrade` scriptlet (pacman holds `db.lck`; read operations take no lock, and
  libalpm re-validates the database signature when it loads it): to run in the container test (`tests/integration/
  software_update.sh`) before the first marker is published. A failure leaves the file as it is (safe).
- That libalpm, whose conditional request for a synced file dated the epoch the server always answers in full, brings a 200 for the database and
  its signature (over https and `file://`), and that `yay -Sua` after a scriptlet that kept the files sees no foreign
  `grassfield-*` package: the updated A7e of `tests/integration/software_update.sh` (container, not run here).
- pacman's fallback from a 404 cohort path to the plain line for both the database and its signature (Q1 tested an
  offline server, not a 404).
- The pane's new rows: visual NOT verified (no nested session here).
