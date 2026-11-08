# ADR-0027: Files search: scopes, backends and saved searches
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (integrator, under owner delegation D-5); applied with the combined Files PR 3–5 (2026-11-01) · Date: 2026-10-26 · Decider: integrator

## Context
- Owner goal (2026-10-26, `docs/specs/files.md` FP-71…FP-74): search as in the Finder: the scope "This Mac" or the shown
  folder, filters (kind, dates, size, tags), saved searches; "the backend is decided in an ADR (an index that exists on
  the machine, or a bounded walk): no new service without a reason (the project's working rules)".
- Files today filters the shown folder by name (`FolderModel.filterText`); the tag search walks one folder tree on a
  worker thread with bounds (F16, `apps/files/src/tagsearch.*`: breadth first, one filesystem, no symbolic links, 50,000
  entries, 2,000 matches, 32 levels, generations so a superseded search never reports).
- The shell's Search (docs/specs/search.md S5) already asks `localsearch search -f` (TinySPARQL, GNOME's indexer, an
  optional dependency of the package) and falls back to `plocate -i -b` when localsearch returns nothing; argv only,
  `timeout 2`, results limited to `$HOME` without hidden path segments. On the dev machine localsearch reports 0 files
  indexed, so plocate answers there.
- Indexes present on an Omarchy machine: plocate's database (refreshed by `updatedb` daily as root: names only, may be a
  day old, readable by the user only for paths the user can read); localsearch only when the user installed and enabled
  it. Baloo (KDE) is not installed. KIO's `filenamesearch:/` worker (kio-extras) walks a folder without bounds or
  metadata filters.
- "Mac" is an Apple trademark: the UI never names it (master-prompt §14). The scope is "This Computer" (« Cet
  ordinateur »), as the system menu says "About This Computer".

## Options
1. **A chain per scope, no new service**: localsearch when its index answers, plocate for names, and a bounded walk of
   the shown folder in Files (the tag search's walker, generalised); metadata filters evaluated on each candidate.
2. Ship and run an indexer (Baloo, localsearch as a required daemon, an own one). Rejected: a new service and a
   background cost the owner did not ask for; R5.
3. KIO `filenamesearch:/` for everything. Rejected for the metadata filters and the bounds (it walks the whole tree), but
   kept as a fallback idea if the walker proves too slow.
4. Name filter of the shown folder only (today). Rejected: not the Finder.

## Decision (proposed)
Option 1.
- **Scope "This Computer"**: localsearch first (names and, with the Contents filter, full text), when `localsearch`
  exists and its answer is not empty; otherwise plocate for names. Both follow the shell's rules (argv arrays, a timeout,
  `$HOME` only, no hidden path segment unless Show Hidden Files is on, at most 2,000 candidates); each candidate is then
  checked with one `lstat` (exists, type, size, dates) and one `lgetxattr` for tags, off the GUI thread. The Contents
  filter without a localsearch index shows its reason in the filter row ("Contents need the file index (localsearch)").
- **Scope "<folder>"**: a bounded walk of the shown local folder (the F16 walker: breadth first, the folder's filesystem
  only, never through symbolic links, hidden entries only with Show Hidden Files, 200,000 entries, 2,000 matches, 32
  levels), names folded for case and accents as the folder filter does (`FileLogic::nameMatchesFilter`); filters run on
  the entries' `lstat`, extension-based kind and tags. Contents in this scope come from localsearch when it indexes the
  folder, else the row explains why.
- **Filters** (Finder's + rows): Kind (folder, document, image, video, audio, PDF, text, archive, application,
  other), Last opened, Last modified, Created (within the last N days, before, after, exactly), Name (contains, begins
  with, ends with, is), Size (greater, less), Tags (has a tag), Contents.
- **Results** are a location `grassfield-search:/?q=…&scope=…&filters=…` (Files-internal, never passed to KIO, like
  `grassfield-tag:/`), so history, tabs and views work; the path bar shows the selected result's path (FP-74).
- **Saved searches**: one JSON file per search in `$XDG_DATA_HOME/grassfield/saved-searches/` (user data, like macOS's
  Saved Searches folder): `{"version":1,"name":…,"scope":"computer"|"<folder URL>","query":…,"filters":[…]}`,
  0600, written atomically; a saved search can be added to the sidebar and opens as its location. Recorded in ADR-0020's
  persisted-files table when it lands.
- Every external call is cancelled when the search changes (generation numbers, as F16), and no result of a stale search
  reaches the view.

## macOS reference
Spotlight answers "This Mac" from its index; the folder scope narrows to the folder; the + button adds criteria rows;
Save makes a smart folder (`.savedSearch`), optionally in the sidebar.

## Consequences
- Files learns the same backend rules as the shell's Search; a later change to them changes both (this ADR).
- Gate P4 (search latency) gets a Files measurement on the 100k-file fixture in PR 3.
- Without localsearch or plocate, "This Computer" walks the home folder with the folder bounds and says so.

## Applied (combined Files PR 3–5, 2026-11-01)
- `searchlogic.{h,cpp}` (the location, rows, saved search JSON), `filesearch.{h,cpp}` (the chain on its own thread:
  localsearch, then plocate, then the bounded walk: 200 000 items, 2000 results, 32 levels, 2 s per program, 8 MiB of
  output), `savedsearches.{h,cpp}` (the store), FolderModel (the location), ScopeBar.qml (scope bar and rows).
- Typing searches This Computer, the Finder's default; the root is the home folder (`GRASSFIELD_SEARCH_ROOT` in dev,
  ADR-0019); a program's exit 1 with nothing on stderr is "no match", anything else falls through to the next backend.
- Differences from the text above: a Contents row without the index says so in the status bar, not in the row; a
  search with no text and no complete row (a new smart folder) lists nothing; results are not live (a new search shows
  new files). Tests: `tests/unit/files/tst_search.cpp`, `tests/unit/tst_filesbrowser.qml` (`test_searchAsYouType`).
