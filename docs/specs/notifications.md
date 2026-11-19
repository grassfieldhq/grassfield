# Notifications spec · shell-engineer · M2

UI naming (renamed 2026-10-18, owner decision): the internal "Notification Center" (`NotificationCenter.qml`, IPC `toggleCenter`) is shown to the user as "Notifications" (fr « Notifications »); the do-not-disturb mode is "Do Not Disturb" (fr « Ne pas déranger »), not "Focus".
Status: implemented in M2 (see "Implementation notes"); N10 (lock screen) belongs to the lock module.

## macOS reference behavior (described in words)
- Banners slide in at the top-right under the menu bar, their top where the Notifications column's top is (16 pt below the bar), ~344 pt wide, rounded ~18 pt, material background,
  app icon left, bold title, body up to 4 lines, relative time ("now", "2m ago") top-right. They stay ~5 s
  (alerts stay until acted on), hovering pauses dismissal, a swipe/drag to the right dismisses, a close (×)
  button appears on hover at the top-left corner.
- Multiple banners stack vertically with 6 pt gaps; same-app notifications group with a count in the
  Notifications column.
- The Notifications column opens from the clock in the menu bar (click). macOS model (F1 gap 7): no full-height panel; a
  344 pt column of floating glass cards, the width of a banner, 16 pt from the right edge and below the bar. No title capsule (the
  reference has none); cards are grouped by app, newest first, 6 pt apart (within a group and between groups); the first card of a
  group of two or more carries the app name and the count, a single notification has no app-name row (icon, bold title, body,
  time: 56 pt for two lines; ADR-0024 lot 4b, C-14); widgets placed in the Center follow as glass tiles; the footer (Edit Widgets pill, 24 pt close circle) is
  centred under the column, 16 pt below the last card (at the bottom when the list fills the column); the pill label is 12 pt regular in the secondary colour.
  Title row (macOS 27, owner decision 2026-10-26; docs/audits/ui-finesse-2026-10-25/f1-macos27.md § Notifications): while the
  column has notifications, "Notification Center" (fr « Centre de notifications », `notification.titleSize` 19 bold) sits
  above the cards, 2 from the column edge, in a 30-pt row (`titleRowHeight`), with a 20-pt round x at the right
  (`titleCloseSize`, accessible name "Clear All") that clears every notification (`Notifications.clearAll`). The title is drawn
  straight on the wallpaper in the ink that keeps 4.5:1 over what lies under it (`GlassTint.inkOn` over the output's luminance
  grid: the light appearance's text colour or the dark one's); when the backdrop is unknown (a window on the workspace) or
  neither ink holds, it gets a glass plate (`titlePlatePadding`) and the appearance's text colour (A2). The x is reached by the
  pointer and assistive technology, not by Tab (each card and group keeps its own clear). The banners hide while the column or Quick Settings is open.
  macOS 26 clear model (owner decision 2026-10-19, batch 4): there is NO permanent "Clear All" pill. Hovering (or focusing) a card
  shows a small round x at its top-left corner (accessible name "Close", fr « Fermer »); hovering a group shows, on its header card,
  "Show Less" (when the group was expanded with "Show All") and a round x that grows into a "Clear All" pill (fr « Tout effacer ») under
  the pointer or the keyboard focus and clears the whole group (only for a group of two or more: a single notification has just its own
  x, as on macOS). A clear takes effect at once (history, "No Notifications", the file); the column only animates it: the cleared card
  (or every card of a cleared group) slides out to the right while it fades (`motion.normal`) and the cards below slide up, so closing
  the column mid-animation never loses a clear. Keyboard: Tab reaches each card, then
  its x, then the group controls; Space or Return on the x clears; Delete or Backspace on a focused card clears it and focuses the next card
  (the card that now holds its slot; when the group has no card left to reveal, the group's new last card, else the next group's first
  card, else the previous one; never another app's card while the same app still has one; the column when none is left).
  Esc, the close circle or a click outside the cards closes.
- Do Not Disturb (from Quick Settings) silences banners; the menu bar shows a moon icon.

## Purpose and non-goals
Single `org.freedesktop.Notifications` server for the session (Quickshell `Quickshell.Services.Notifications`),
banners, history (ADR-0004), Notifications panel, DND. Non-goals: notification sounds beyond one
Grassfield sound (later), cross-device sync.

## Functional requirements
1. N1 Server registers `org.freedesktop.Notifications`; capabilities: body, body-markup (sanitized subset),
   actions, icon-static, persistence, inline-reply only if Quickshell supports it.
2. N2 Banner per notification; timeout = hint/expire_timeout, default 5 s; `urgency=critical` never auto-expires.
3. N3 Hover pauses the timeout; drag right > 30 % width or × button dismisses (calls `dismiss()`).
4. N4 Clicking the banner invokes the `default` action if present and focuses the sender window if known.
5. N5 Actions render as buttons (max 3 visible, rest in a "More" menu); each invokes the real action.
6. N6 History persisted per ADR-0004 (0600, ≤ 200 entries, ≤ 7 days, transient not stored).
7. N7 Notifications panel: opens from the clock or `SUPER+N`; grouped by app; per-card x and per-group "Clear All" (hover/focus; no global Clear All).
8. N8 DND: toggle (Quick Settings); suppresses banners except critical; menu bar moon indicator.
9. N9 Markup is sanitized (allow b, i, u, a href shown as text); images limited to 256 px.
10. N10 Never shown on the lock screen by default (L4).

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| N1 | `notify-send` from inside nested → banner screenshot; `busctl --user` shows the name owned by qs | L1 |
| N2/N3 | scripted: send 3, wait 6 s, only critical remains | L1 |
| N5 | `notify-send -A ok=OK` → click via `wtype`/IPC → `notify-send` prints `ok` | L1 |
| N6 | restart shell → history restored; file mode 0600 | L1 |
| N9 | unit test of the sanitizer (QML TestCase) | L0 |

## Interfaces
D-Bus `org.freedesktop.Notifications` 1.2 (spec). Settings keys `notifications.dnd`, `notifications.previews` (the default) and `notifications.appPreviews` (per-app overrides). Alert style per app: `notifications.appStyles` (`{app, style}`, `banners` default | `alerts` stay until dismissed | `none` no banner; macOS model, GF-107). History retention: `notifications.history` (`week` default | `day` | `never`), and the body of an app whose previews are Never is never written to disk (GF-113).
IPC target `notifications`: `toggleCenter()`, `dnd(on)`.

## Degraded behavior
If another server owns the name (e.g. mako), show one warning and run banners-only off.

## Dependencies (verified versions)
Quickshell 0.3.1 `Quickshell.Services.Notifications` (`NotificationServer`, `Notification`, `NotificationAction`; API read
from the installed qmltypes), Qt 6.11.2, `busctl` (ownership probe), `install`/`mkdir`/`chmod` (history file creation).

## Implementation notes (M2)
- Code: `shell/notifications/` (`Notifications.qml` singleton: server, banner queue, history, IPC; `Banners.qml`/`Banner.qml`;
  `NotificationCenter.qml` (window, footer, widgets) + `NotificationList.qml` (the cards); `NotificationContent.qml`; pure `Sanitizer.js`, `History.js`).
- Clear model (NotificationList.qml): `clearCard(group, refocus)` commits to the model at once: `Notifications.clear(key)` or, for a
  group, `Notifications.clearKeys(Notifications.keysOf(app))` (a snapshot of the keys at the click: a same-app notification that arrives
  later stays). The ListView animates the result: `remove` (the delegate's `slide` to the right + `opacity` to 0), `motion.normal`. The cards below glide by a visual offset: a delegate always sits at the
  layout position the view gives it (the model layout) and, when that `y` changes (a card above arrived, left, or changed height as "Show All" does), adds
  `old y - new y` to its `shift` (a `Translate`) and lets `shift` glide to 0 (`Glide`, a critically damped spring that keeps its velocity when the card is moved again on the way: audit B-17), so no transition can leave a final offset (the old `displaced`/`move`
  transitions animated an absolute `y` to a target fixed at their start and left the cards below a "Show All" 36 px too low). A card that arrives while the column is open slides in from the right while it fades in (run by the delegate, `enter`, for keys flagged by `Notifications.takeFresh`; never a card that is merely revealed). Reduce Motion (macOS: slides become fades): nothing moves (the cards stay in place and only fade in or out, within `motionReducedMax` through `Appearance.duration`; the cards below jump to their new place). A delegate that left the model is disabled
  (`ListView.onRemove`): no input, no focus. The footer glides with a `Behavior on y`. Blur regions follow through `list.motionTick` (bumped at most once per frame, `list.bumpTick`, however many cards moved: 200 sliding cards bumped it 600 times a frame and each bump re-read every region; a faded card's region is skipped without mapping it); a card's region is cut to the list viewport on all four sides and shrinks about its centre with the
  card's opacity, so the blur never outlives the glass. Surface records carry a unique id: Variants ignores and warns about equal values, and
  records of destroyed cards ({item: null}) were equal (163 464 "same value specified twice" lines for a 600-notification burst). The list is
  `panel.gutter` (= close size / 3) wider and taller than the column so the x can stick out of the card's corner like the banner's.
  Where the keyboard focus goes after a clear is the focus resolver's (below), read from the model AFTER the update. Hover over the group controls is counted per hover handler (card and the x that sticks
  out of it; `CenterLogic.hoverStep`), also decremented when a card is destroyed under the pointer.
  `Notifications.clearAll()` stays as the IPC test hook `clearAll()` only; the UI has no global Clear All. The IPC test hooks `invoke`, `clearAll` and
  `dismissAll` share one gate, `Notifications.testHooks` = `VisualFixtures.active` (`GRASSFIELD_DEV=1` AND `GRASSFIELD_VISUAL_FIXTURES=1`, never with
  `GRASSFIELD_SESSION=1`; `nested-up.sh` and `shell-run.sh` take `--visual-fixtures`), else they answer `refused: <name> is a test hook` and change nothing
  (`tests/shell/notif_hooks.sh`).
  Keyboard focus is independent of the view: the ListView has `currentIndex: -1`, no highlight following and no key navigation (a current item
  made the view move the focus onto that delegate on any insert or removal at or above it); focus moves only by key (Tab, `tabStep`) and by the resolver below. A clear keeps the
  focus on another card, and moves it (next card rule above) when it was on the cleared card, any card of a cleared group, or on the keyboard and
  accessibility paths (the x's accessibility press behaves like Space on it). Tab and Shift+Tab follow the visual order (top to bottom, then the widgets, then Edit Widgets and the close circle; inside a card: card, x, buttons):
  Qt's focus chain follows delegate CREATION order (newer cards sit above older ones) and moves the focus before any parent sees the key, so two
  `Shortcut`s (Tab, Shift+Tab; off while the widget gallery or a widget menu is open) run `ListView.tabStep`, which redirects only where Qt's next
  item would leave the card, and otherwise focuses Qt's own next item. Reduce Motion: see above; a banner fades in where it stands
  instead of sliding in (`Banner.entrance`), the banners jump down for the OSD, the column fades in at its place instead of
  sliding in and its footer jumps with the cards (ADR-0039 step 5; `tests/shell/reduce_motion_wiring.sh`); a banner dropped
  short of dismissing is back in place at once and a group's pill takes its new width at once (step 6).
  A group that empties forgets its "Show All" (`expandedApps`, also when the whole Center empties): its next cards arrive collapsed.
  One focus invariant for the whole column (macOS model: the focused element never disappears from under the keyboard): the element that
  holds the focus always exists, is visible and enabled; when it goes away the focus moves, visibly, to the nearest remaining element of the
  CURRENT layout. The target is an identity, never an item: card key plus control role (`card`, `close` (the x), `clearGroup`, `showLess`,
  `showAll`, `more`, `action:<id>`), noted by `NotificationList.noteFocus` whenever the focus is on a card or one of its controls
  (`focusId`, with the card's group and rank). Anything that can change what is shown (the model's `rowsInserted/Removed/Moved/dataChanged/modelReset`,
  a delegate leaving, a control's `visible`, the sender's actions) calls `queueResolve()`; ONE resolver (`resolveFocus`) runs once per
  event-loop turn after all of them, however many changes the turn held, applies the layout (`forceLayout()`) and checks the target
  (`itemOf`: present, visible, enabled). If it is, nothing happens. Otherwise (`nearestTo`): the same card's `card` (a hidden Clear All,
  Show Less, Show All or x lands on the card that carried it; never on another destructive control), the sender's buttons by position
  (More revealing the rest lands on the first revealed button), and when the card itself left the displayed rows the pure
  `CenterLogic.focusAfterGone(lost, oldKeys, rows)`: the card now in the same slot of the same group (same rank, clamped to the group's
  last displayed card; Show All / Show Less keep their role there), else (group gone) the next group's first card, else the previous
  card, else the panel (`releaseFocus`). Only `rows` (the model now) says what exists; the settled rows before (`snapRows`) only give
  the neighbourhood, so nothing acts on a stale or gone key, also after several changes in one turn. A same-id update by the app only
  changes the card's roles: the delegate and its focus stay. `Show All` used with the keyboard hands the focus to the group's "Show
  Less"; `Show Less` hands it to "Show All" (an intent the resolver honours, `handoff`).
  What Qt does with the focus when the item that held it goes away, and what the code does about it (`noteFocus`, `resolveFocus`): a
  sender button rebuilt by a same-id update puts the focus on the card's actions `Loader` (a focus scope inside the card: `identityOf`
  names no control for it, role `""`, and keeps the previous identity); a card that left the displayed rows and came back in the same turn
  (or was destroyed) puts it on the list, its content item or the panel (`droppedFocus`). In both cases, if the identity still names a
  visible, enabled element, the resolver gives the focus back to it (`forceActiveFocus`, so the ring is drawn); otherwise it moves it as
  above. A focus on Edit Widgets or the close circle is the user leaving and is forgotten (`focusId = null`; `releaseFocus`, which also
  drops the identity, is the explicit leave to the panel).
  The identity is kept current: on every resolve, whether or not the focus moved, `settle(item)` rebuilds it from the layout as it is
  then (`rank` in the group, `cidx` among the sender's buttons) and takes the displayed rows as the new "before" (`snapRows`): a card that
  stays while others arrive or leave around it changes slot, and the successor of a later removal is computed from the slot it has now.
  Keys act only on an element that can be acted on RIGHT NOW: every key handler (the card, its x, Clear All, Show All / Show Less, the sender's
  buttons through `actionTriggered`, `clearCard`) checks at key time, synchronously, with the delegate's `actable(item)`: the item is
  visible and enabled and the card is one of the displayed rows (`liveKey`, read from the model, which changes at once; the delegates only
  follow at the next layout). A key that arrives in the same turn as a change, before the resolver ran, on an element that change took
  away does nothing (it is swallowed: it would otherwise bubble to the card) and the resolver is queued. A hidden control still holding
  the focus swallows only its ACTIVATION keys (Return, Enter, Space; `GroupClear`, the shared `Button`), and every other key (Escape above
  all) propagates, so a Button hidden by its parent never blocks Escape (the polkit dialog uses the same Button). Return opens a card only
  when the card itself holds the focus (not from a stray child such as the actions Loader). Delete and Backspace clear a card only when the
  card itself or its x holds the focus; on Show All, More, an action or Clear All they do nothing.
  The list is its own component (`NotificationList.qml`, a ListView) so that the tests run the shipped code: the PanelWindow needs a compositor.
  Tests: `tests/unit/tst_notifcenter.qml` (focus choice `focusAfterGone` incl. several changes in one turn, hover counts), `tests/shell/notif_center_list` (the real list in a plain
  window on the real singleton, real key events through `QtTest.TestCase.keyClick`: focus after arrival, Show Less, collapse, expiry, same-id update, group clear, last card; a focused
  Clear All / Show Less / Show All / More / action hidden by an arrival, a close, a shrink or the sender expiring; two and three changes in one turn; keys never
  act on a hidden control; case "same-id update drops another action under the focused action" and case "pushed out and brought back in one turn"; Delete and Backspace only on the card and its x; the identity rank following the layout (focus the 2nd card, an arrival, Delete: the card that slid into the slot), the settled order following the layout, Escape through a hidden Clear All, keys in the same turn as the change that took the element away (Delete on a pushed-out card, Space on a sender action of a card that left, Return on the stray Loader); a seeded random sequence of 80 turns with the focus anywhere; tabStep order incl. after arrivals;
  focusedDelegate; clearCard refocus; Show All / Show Less focus handoff; layout invariant after toggles; bumpTick; takeFresh), `tests/shell/notif_center_random` and `notif_center_random2` (the same list, 1200 seeded turns in 6 seeds, split over two tests for the 60 s limit of test.sh of 1 to 4 changes: arrivals, closes, expiries, same-id updates adding or dropping actions, x, Clear All, Show All / Show Less, More; focus on every control or outside the cards; real Space, Return, Enter, Delete, Backspace and Tab, Shift+Tab before and after the changes; the invariant is asserted after every turn, plus a SUCCESSOR ORACLE: a reference model that reads the focused identity and the displayed rows when the column is settled and names the exact element the focus must be on after the turn; keys come both before and after the changes, so some meet the state the changes left before the resolver ran), `tests/tools/mutate-notifications.sh` (15 mutants of the resolver and the key guards, every one must fail a shipped test; `--against REV` runs the focus tests against an older NotificationList.qml), `tests/visual/notification-focus.sh` (nested: the ring after a same-id update; fails when no ring is drawn on the expected button), `tests/unit/tst_buttonkeys.qml` (the Button guard: activation keys swallowed while hidden, Escape and other keys propagate), `tests/shell/notif_clear` (real singleton: immediate clear, snapshot,
  repeated group clears, focus after Delete in collapsed and expanded groups), `tests/shell/notif_clear/nested.sh` (nested helper, notifications on the nested private bus only).
- Banners: one layer-shell window (Overlay layer, no keyboard focus) on the active display only (`Compositor.activeScreenName`); input and blur follow the cards.
  Timeout: `expire_timeout` (seconds), -1 = 5 s, 0 and critical = never. Expiry only hides the banner: the entry stays in the Center
  and stays actionable while the sender keeps the notification alive. x / drag-dismiss calls `dismiss()` (sender told "dismissed"),
  the entry stays in the Center as non-actionable. A sender `CloseNotification` removes the entry. Invoking an action or the default
  click clears the entry unless `resident`. Max 5 banners visible; older ones wait in the queue, at most `Notifications.bannerQueueMax` (20; the oldest non-critical leaves the queue first, the entry stays in the Center). A banner pushed back into the queue by a newer one leaves as a dismissed one does (slide, fade, close) before its slot empties (audit B-11); at most 5 exits play at once. The stack (`BannerStack.qml`, inside the `Banners.qml` window) syncs once per event-loop turn, with its live rows indexed by key, and judges every banner's glass over the stack at rest (`restHeight`, audit B-02). A replacement (replaces_id) is one update per turn whatever properties changed (summary, body, actions, urgency, expire_timeout, image, app icon, app name; audit B-09, B-12): the banner takes the replacement's own timeout, one raised to critical shows through Do Not Disturb and stays, one lowered from critical under Do Not Disturb loses its banner; a replacement that changes nothing emits no signal from Quickshell and is not seen. The attached picture is drawn once into a Canvas the thumbnail's size, cropped and rounded, and the full picture is let go (audit B-19: Quickshell's image provider ignores the requested size).
- Actions: first 3 non-default actions are buttons, the rest appear after "More" (inline expansion, not a menu). macOS shape (docs/audits/visual-tahoe-2026-10-25.md § Banners — close, 7/10): equal-width capsules 22 pt tall (`notification.actionHeight`), 8 pt apart (`spacing.sm`), under the text; the close badge is 20 pt.
- Click on a banner/row runs `default` and focuses a window of `desktop-entry` when one is open.
- Notifications column: separate full-screen transparent window (Esc and click outside the cards close, the menu bar strip stays clickable so the
  clock toggles it). Groups by app name, newest first. A collapsed group of two or more is a stack (macOS 27, owner decision 2026-10-26; `notification.centerGroupCollapsed` 1, `Notifications.groupCollapsed`): its newest card in front with no header, the cards behind it drawn as a tail under it (`stackStep` 4 per card, two at most, each `stackInset` 10 narrower on each side, clipped under the front card so the translucent glass never shows them through it). The tail is the group's Show All (accessible name "Show All (n)", Tab stop, Space or Return): it opens the group, which then shows every card with the header (app name, count, Show Less, Clear All) on the first. A click on the front card still runs its default action (macOS opens the stack instead; the focus tests rely on the card's own action). The focus tests (`tests/shell/notif_center_list`, `notif_clear`) drive their scenes with groups of three collapsed cards (`Notifications.groupCollapsed = 3`; the focus invariant does not depend on the count) and scene 37 covers the stacks. Every card, each widget
  tile and the footer controls are separate glass surfaces: each registers itself with the content (`addSurface`) and gets its own blur
  region (`Variants` of `Region`, rectangle in window coordinates, cut to the list viewport for rows, refreshed when the list scrolls or
  changes height). A click outside every registered surface closes; the empty area below the last card is outside the list.
  Opening a menu/popup closes the Center.
  The Center list shows only the DISPLAYED rows: `Notifications.centerModel` (keyed ListModel) holds the first 3 rows of each app
  group (all rows of a group the user expanded with "Show All"; the expansion resets when the Center closes), so collapsed rows
  never get a delegate and the ListView has no sections. The full order lives in two JS arrays (`centerKeys` / `centerApps`:
  grouped by app, newest group first, newest row first inside a group); `syncShown()` reconciles the model with the displayed
  subset and touches it only where that set changed (insert / remove / move by key, a few rows per Notify). Per-row group info
  travels as roles of the rows that need it: `headCount` (> 0 on the first row of a group: draws the header with name, count and
  Clear; drawn for a group of two or more), `headFirst` (top group), `toggleCount` (> 0 on the row that carries Show All / Show Less); a role is
  written only when its value changed. History insert is O(dropped) (`History.pushNewest`) and
  evicted live notifications are dismissed after the Notify reply (`Qt.callLater`). The Center window is full-screen and keeps its
  size while open (the column slides in once), so a Notify never reconfigures the layer surface; it adds one card and one blur
  region (the region list is rebuilt when a surface registers or the row count changes). Notify round trip on the nested shell,
  loaded machine: median 32-38 ms from 60 to 200 same-app entries (bare gdbus 16-17 ms); before: 44-54 ms at 200. With the Center
  open (history 200, `notifications toggleCenter`): median 35-37 ms against 28-33 ms closed (60 / 40 sends, 2026-10-17).
- Body markup: `Sanitizer.sanitize` keeps only b, i, u and br (balanced); links render as "label (url)" text and are not clickable;
  images are dropped (alt kept); everything else is stripped; 4000 characters max. Images in hints are loaded at <= 256 px,
  and only when they are a local file, the image data the app sent or a theme icon name (`History.imageRef`, GF-114): an
  http(s), data, ftp or other URL is dropped at arrival (log line with the scheme only) and the app icon is shown instead;
  `tests/unit/tst_notifhistory.qml`, nested DT-07 `tests/security/notif_remote_image.sh`. A local file (image or app icon
  path) is never loaded from where the app named it (reviews of 8b2a710 and beebaff: a FIFO blocked the one image loader
  for good; a check of the named path was fooled by `?`, `#` and `%XX`, which Qt reads in a URL, and by a file swapped
  after the check). Only a plain absolute path is accepted (`History.localPathOf`: a path, a file: URL without query or
  fragment, Quickshell's `image://icon//path`; no `?`, `#`, `%` after decoding, no `.`/`..`/empty segment). A helper process
  (`Notifications.requestCopy`; the path as an argument) runs `shell/services/image-copy.py` under `timeout 12`: it opens
  the file safely (real path under an allowed root, O_NOFOLLOW|O_NONBLOCK, fstat: a regular file of at most 8 MiB) and
  re-encodes it into a PNG of at most 256 x 256 pixels (review of 423766f: a verbatim copy of an SVG naming a FIFO still
  stalled the loader; the shell only ever decodes images it produced itself, see `docs/specs/security-images.md`), in
  the shell's private directory `$XDG_RUNTIME_DIR/grassfield-notification-images-<display>` (0700, emptied at start); the
  Image loads that `<n>.<sender>.png` by a URL built from its number with every segment encoded (`History.copySource`). Each intake makes a
  fresh copy (album art at a reused path changes). The directory holds at most 48 copies and 64 MiB across all senders
  (`copyWindow`, `copyBudgetBytes`; review of 6e24d36: 60 notifications naming one 8 MiB file filled 384 MiB of the
  session's tmpfs), and at most half of the budget for one sender (`copyShareBytes`; the sender is the notification's
  app name, a number of it is part of each copy's file name; review of 2dfd992: eight critical banners of one sender held
  the whole budget). The helper evicts first the sender's own oldest copies while it is over its share, then the oldest
  copies overall, never one shown on screen: a displayed banner's or, while it is open, a Notification Center row's,
  including copies made in the same helper batch (review of 2dfd992: they were not protected); the batch starts later in
  the turn that asked for it, once the notification's banner is on screen. An image larger than a sender's share, or that
  would not fit even after those evictions, is refused before anything is evicted. An evicted or refused image shows the
  app icon; an evicted copy is re-made only when a new notification names the file, never because it is shown (copies
  cannot evict each other in a loop). `tests/shell/notif_image_budget` (budget lowered to 3 MiB: six 1 MiB images, an
  image larger than the budget, a banner's copy kept, an image the banners' copies leave no room for) and
  `tests/shell/notif_image_fairness` (one batch of banners keeps its copies; one sender's banners keep half the budget,
  another sender still fits; a sender replaces its own older copy; an open Center row's copy is kept; four mutants fail
  it).
  Until the copy exists the app icon or the bell shows; without `XDG_RUNTIME_DIR` no local file is shown.
  `tests/shell/notif_image_files` (FIFO, symlink to it, `/dev/null`, a sparse 20 MiB file, a directory, a missing file,
  the reviewer's bypass forms `x.png?a`, `file://…?a`, `x%2Epng`, `file://…#f`, `image://icon//…?fallback=a` and an app
  icon path, a file swapped for a FIFO after its copy; a normal image still loads afterwards; mutation allowing `?#%` fails
  it). An app icon NAME (and a themed image hint) reaches the icon theme only when it is a plain theme name
  (`NotificationPrefs.safeIconName` in Grassfield.Ui, the one name test: 1–128 of letters, digits, `.`, `_`, `-`, starting
  with a letter or digit, no `..`): Qt also searches its fallback directory `/usr/share/pixmaps`, where `../../../dir/evil`
  named any file, a FIFO included (review of 6e24d36). `History.safeIconName` calls it (and refuses every name if it is
  missing); it applies at intake (`checkedAppIcon`, `History.keptAppIcon`), on history load (`History.parse`) and in
  `iconSource`; with previews hidden `NotificationPrefs.appIconShown` keeps only a name that passes the same test, so the
  sender's image and an app icon path (its private copy included) give way to the app's theme icon or the generic one.
  A name that passes reaches an Image only through `ThemeIcons` (shell/services: the single entry point for every icon
  named by a notification, the polkit sheet, a desktop entry, an application or a file). Integrator decision after the
  review of 5ee6240 (mirroring Qt's index.theme parser proved endless): Qt never reads a user-writable icon file.
  Grassfield.I18n (`ui/i18n/iconsearchpaths.h`, applied when grassfield-shell imports the module, before any binding)
  sets Qt's theme and fallback search paths to the usual ones minus every directory the user can write or replace (the
  canonical path and each ancestor must belong to root, or to the overflow uid inside a user namespace, and not be
  writable by the user), and only the packaged /usr/share/icons and /usr/share/pixmaps (review of dce68c2: flatpak and
  snap system exports are root-owned but written by app installs; see security-images.md); ~/.icons, $XDG_DATA_HOME/icons and
  user-writable $XDG_DATA_DIRS entries (a flatpak user export) are out. The shell logs the result once
  (`grassfield-icons: theme search paths ...`). No environment variable changes, so applications launched from the shell
  keep their own icon paths and Quickshell's DesktopEntries still lists user applications. A theme name is looked up
  there (`Quickshell.hasThemeIcon` on the GUI thread reads only root-owned theme files). A name found only in the user's
  folders, an absolute `Icon=` path, a tray icon from the app's IconThemePath, media art and a desktop or stack picture
  are shown as PNGs the shell made (`docs/specs/security-images.md`): `shell/services/image-copy.py` (python3, off the
  GUI thread, under `timeout` and `--pdeathsig`) looks the name up plainly (each theme folder x size folder x
  apps|status|mimetypes|places|devices x png|svg, hicolor first, then pixmaps; no index.theme), opens each candidate
  safely (real path under an allowed root, O_NOFOLLOW|O_NONBLOCK, fstat: a regular non-empty file within its cap, 8 MiB,
  16 MiB for a picture) and re-encodes it with rsvg-convert fed on stdin (no reference to another file is followed) into
  $XDG_RUNTIME_DIR/grassfield-icons-<display>/<n>.png (0700, emptied at start, 128 MiB in all, least recently used copies
  deleted to make room). The Image loads only that PNG, asynchronously; anything else shows the caller's generic icon. A new notification naming the icon makes
  a new copy. A helper that hangs is stopped (TERM, KILL 2 s later) and its icons refused. `tests/security/theme_icon_files.sh`:
  part 1 (FIFO, symlinks to a FIFO, /dev/zero, /dev/null, FIFO .svg, an SVG referencing a FIFO, FIFO under ~/.icons, a
  swap: the generic icon; a regular user icon: its copy; Qt never sees them), part 2 (the review's hostile index.theme
  files: escaped sections and Inherits=, continuation, escaped key, Inherits=.., Inherits=., a user hicolor index under
  Adwaita, FIFO index.theme and icon-theme.cache: the generic icon, no stall; Qt with a real session's search paths
  stalls on each), part 3 (real Launchpad cells, desktop icons and the About panel with FIFO Icon= values and a FIFO
  picture; a user-installed icon shown as a copy; the other sites' calls), part 4 (the logged search paths hold no
  user-changeable directory; an LD_PRELOAD open log shows no open of a user icon file except by the helper with
  O_NOFOLLOW|O_NONBLOCK; a child process gets the environment unchanged; 24 lookups next to a 99k-file user theme in
  about 0.2 s). Every Image with a dynamic source loads asynchronously: the Dock (applications, minimized windows, folder,
  trash and Apps tiles), Launchpad cells, the Apps prewarm list, desktop icons and thumbnails, folder stacks (type icons
  and previews) and their popup, Search rows, the Switcher, the Overview, Stages, Force Quit, About and the polkit sheet.
  Anything else shows the generic notification icon (macOS: a notification shows its app's icon, never a file the sender
  names). Tests: `tst_notifhistory` (`test_safeIconName`, `test_keptAppIconAndHistoryLoad`), `tst_notifprefs`
  (`test_safeIconNameIsTheHiddenPreviewRule`), `notif_image_files` (traversal names to a FIFO and to a regular file, the
  mutant without the rule stalls the loader and fails; previews hidden for one sender drop its copy).
- DND: `notifications.dnd` in grassfield.json; Quick Settings "Do Not Disturb" tile; moon icon in the menu bar (click turns it off).
  Critical notifications still show; history is kept. `notifications.previews = never` hides the title and the body: the app name and a generic "Notification" line show instead (banners and Center).
- History (ADR-0004): `$GRASSFIELD_STATE_HOME/notifications.json` (dev) else `$XDG_STATE_HOME/grassfield/notifications.json`
  (default `~/.local/state/grassfield`). FileView cannot set a mode, so a one-shot `sh -c` Process creates the directory (`mkdir -m 700`)
  and the file (`install -m 600 /dev/null`, then `chmod 600`) before the first read/write; FileView's atomic write (temp + rename) keeps
  the 0600 mode (verified with `stat -c %a`). Max 200 entries, max 7 days (pruned on every arrival and every 30 s), `transient` and
  low-urgency non-resident notifications are not stored, images are not stored, actions are stored as labels and restored non-actionable.
  Writes are debounced 400 ms and blocked until the file was read, so a slow start never wipes the history.
- IPC target `notifications`: `toggleCenter()`, `dnd(on)`, and test hooks `clearAll()`, `invoke(actionId)` (newest live notification; "default" =
  banner click), `dismissAll()` (all three gated, see Clear model) and `status()`.

## Dev / nested testing (private bus)
The nested session shares the owner's D-Bus session bus, where omarchy-shell owns `org.freedesktop.Notifications`. Never take it over:
- In a `GRASSFIELD_DEV=1` session the server is **not created** unless `GRASSFIELD_PRIVATE_BUS=1` (log: "dev session on the shared
  bus; server disabled"). History is still loaded and the Center and DND work.
- `GRASSFIELD_PRIVATE_BUS=1 scripts/dev/shell-run.sh` (or exported before `nested-up.sh`) wraps the shell in `dbus-run-session`; the bus
  address is written to `.dev/bus.address`. Send test notifications with
  `DBUS_SESSION_BUS_ADDRESS=$(cat .dev/bus.address) notify-send ...` and IPC with the same variable
  (`qs -p shell ipc call notifications status`). `shell-run.sh` stops the previous shell by process group so no orphan keeps the old bus.
- The nested output order is WAYLAND-1 (window) then GF-REF: banners, OSD and the Center use the first screen, so capture with
  `scripts/dev/shot.sh <name> WAYLAND-1`.

## Degraded behavior (implemented)
If another process owns the name (probe 1.5 s after start: `busctl --user status` PID differs from Quickshell's), one warning is logged
("owned by another process; banners and history are off"), `serverState` becomes `external` and history writes are blocked. Quickshell
itself logs its own registration warning. Verified on a private bus with a foreign owner.

## Verified (L1, nested, private bus, 2026-10-17)
N1 name owned by qs (`busctl --user status`: PID of qs) · N2/N3 three normal banners gone after 6 s, critical (`-t 1000`) stays ·
N5 `notify-send -A snooze=Snooze` prints `snooze` after `ipc call notifications invoke snooze` (a test hook: needs `nested-up.sh --visual-fixtures`, refused otherwise) · N6 restart restores history, file 0600 ·
N7 Center opens by IPC, Esc (wtype) closes · N8 DND hides banners, moon in bar, critical still shown · N9 unit tests (L0).
Screenshots under `.dev/shots/` (not committed).

## Verified (L1, nested, private bus, 2026-10-19: macOS 26 clear model)
Pointer (`scripts/dev/pointer.sh`) and keyboard (`scripts/dev/keys.sh`) on the nested private bus: no Clear All pill in the footer; hover on a card
shows its x at the top-left corner and, on the group header, the round group x; hover on the group x grows it into "Clear All"; the x of a card clears
only that card (history 8 -> 7) and the column reflows; "Clear All" of the Mail group removed its 4 entries (7 -> 3); Show All then "Show Less" on the header;
Tab reaches a card, then its x (focus ring), Space clears and the focus lands on the next card; Delete on a focused card clears it and focuses the next one.
A2 (`tests/visual/contrast.sh --surfaces desktop,notificationcenter,notificationcenterhover,notificationcenterclear --wallpapers white,black,noise
--transparency 0.25`): 102 cells, 0 failures; card x glyph min 7.1:1, group x glyph min 7.5:1, "Clear All" pill label min 14.9:1 (light and dark).
Not verified: transparency 0.6, Reduce Motion, two outputs, the fr strings on screen (catalog entries only), the pill growth frame by frame
(the nested compositor draws few frames while idle; only the end states were captured).

## Known limitations
- Inline reply depends on Quickshell support; otherwise hidden (not faked). Not offered in M2 (`inlineReplySupported: false`).
- No per-app notification sounds in M2.
- Banner pointer interactions (hover pause, x button, drag dismiss) were NOT verified with a real pointer. The Notifications column
  clear model (hover x on a card, group x growing into Clear All, Show Less, slide-out) was verified with `scripts/dev/pointer.sh` on the
  nested private bus (2026-10-19); the nested compositor draws few frames while idle, so the slide-out can look frozen in a capture taken
  right after the click (it finishes on the next frames; a pointer nudge drives them).
- Banners appear on the main display (`MainDisplay.screenName`, ADR-0044: Settings > Displays > Use as, else the built-in panel, else the first screen; macOS puts them there too), not on the focused one; the Notification Center opens on the active display too (SUPER+N, IPC), the first screen only when the compositor reports no focus.

## Per-app previews (ADR-0004, C-NOTIF-2; owner decision 2026-10-23: follow macOS)
macOS keeps one "Show previews" default (Always, When Unlocked, Never) and lets every app override it. Grassfield does the same; the earlier decision that the single global key was the whole requirement is superseded, and the global key stays as the default.
- Keys: `notifications.previews` (default `unlocked`) and `notifications.appPreviews`, a list (at most 200) of `{app, previews}`; `app` is the sender's name (`Notification.appName`, the key the Notifications column groups by, compared without case or surrounding blanks), `previews` is `always`, `unlocked` or `never`. An app without an entry follows the global key. Rules in one copy: `ui/Grassfield/Ui/NotificationPrefs.js` (shell store, Settings, notification service); schema `config/schema/grassfield.schema.json`.
- Effect (`Notifications.bodyFor(bodyHtml, appName)`, banners and the Notifications column): `never` hides the title and the text: the app name is the title and a generic "Notification" line replaces the body, in banners and in the Notifications column (macOS; `Notifications.summaryFor`, `bodyFor`); the sender's image and action buttons are hidden with them (only the app icon shows, and only a plain theme-icon name: a path or URL given as `app_icon`, such as a photo, falls back to the generic icon; `imageFor`, `appIconFor`, `actionsFor`); the history file keeps the real text; `always` shows it; `unlocked` hides it while the session lock is on (`Lock.locked`, shell/security/lock) and shows it again after unlocking. The lock screen itself never shows notifications (N10).
- Settings > Notifications: "Show previews" (global) and "Application Notifications", one row per app that opens the app's sub-pane (Alert style; Show previews: Default / Always / When Unlocked / Never; macOS 27 layout since 2026-10-26, docs/specs/settings.md). Do Not Disturb is in Settings > Focus. The apps are the senders the shell has seen: the shell writes their names (never text) to `$configDir/notification-apps.json` (`{"apps": [...]}`, rewritten 500 ms after the set changes); apps that have a setting stay listed. Tests: `tests/unit/tst_notifprefs.qml`, `tests/shell/settings_roundtrip`.
- Replacing notifications (same id) update the entry and restart the banner timer, but do not re-show a banner that already expired.
- Relative times refresh every 30 s.
- `appIcon` names resolve through the icon theme only; a missing icon shows a bell tile.
