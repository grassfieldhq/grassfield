# Images the shell does not own · security-engineer

Integrator decisions after the reviews of 5ee6240 and 423766f. Qt never reads a user-writable icon file, and **the shell
only ever decodes images it produced itself**. Before that, the shell copied files verbatim or checked SVG bytes with a
regex. Neither held: a gzip, UTF-16 or BOM-prefixed SVG, or SVG content in a `.png` file, still reached QtSvg. QtSvg then
followed `<image xlink:href>` to a FIFO and blocked the one image loader thread for good.

## Rule
- **Packaged files only, by name.** A plain theme name (`NotificationPrefs.safeIconName`) is looked up by Qt only in
  `/usr/share/icons` and `/usr/share/pixmaps`, which system packages fill (grassfield-icons included), and only while
  the user can neither write nor replace them (`ui/i18n/iconsearchpaths.h`); it is shown by its `image://icon` URL.
  Root-owned is not enough (review of dce68c2, minor 2): QtSvg follows a theme SVG's hrefs, and flatpak and snap
  system exports (`/var/lib/flatpak/exports/share/icons`, `/var/lib/snapd/desktop/icons`) are root-owned but written by
  app installs. Those, `/usr/local/share` and the user's folders go through the helper.
  Raw pixels an application sent are shown as Quickshell holds them: notification `image-data` (`image://qsimage/`)
  and tray `IconPixmap` (`image://qspixmap/`). That is not a file format.
- **Everything else becomes a PNG the shell made.** This covers:
  - a name found only outside the packaged directories: the user's icon folders, flatpak exports (user or system), snap
    exports, `/usr/local/share`;
  - an `Icon=` path;
  - a tray icon from the app's `IconThemePath`;
  - notification image and app-icon files;
  - MPRIS media art: a `file://` file, or an `https://` resource fetched by the helper (see "Media art over
    https");
  - desktop thumbnails and stack previews;
  - the lock screen's `~/.face` and AccountsService picture.

  All of them go through `shell/services/image-copy.py`, which runs as `python3 -I`, in a process of its own. The Image
  then loads that `.png` asynchronously. Anything refused shows the caller's generic icon, or the initials on the lock.
- **Never.** No http, `data:` or other media art URL. No tray `IconName` holding `/` or `..`. No URL built from an
  application's string, except the two pixel providers above.

## The helper
1. **Open.** The real path (`realpath`: flatpak exports are symlinks) must lie under an allowed root:
   - `$HOME`, `$XDG_DATA_HOME` and `$XDG_DATA_DIRS`;
   - `/usr`, `/opt`, `/var/lib/flatpak`, `/var/lib/snapd/desktop` and `/var/lib/AccountsService/icons`;
   - `/tmp`, `/var/tmp` and `$XDG_RUNTIME_DIR`;
   - `/media`, `/mnt`, `/run/media` and `/srv`.

   Never `/proc`, `/sys` or `/dev`. `lstat` must say a regular file. The file is then opened with
   `O_NOFOLLOW|O_NONBLOCK|O_NOCTTY`. `fstat` must say a regular, non-empty file within its cap (8 MiB, or 16 MiB for a
   picture; 64 MiB for a capture thumbnail, see below), and `/proc/self/fd` must still name a path under an allowed root. The file is read once, into memory.
2. **Re-encode** with `rsvg-convert`, fed on STDIN, into a PNG of at most 256 x 256 px. 256 px is the largest any site
   shows: notification images, thumbnails, art and the avatar. With no base URL, librsvg resolves no reference to
   another file. This was checked against a FIFO for absolute, `file:`, relative and `../` hrefs, XInclude, CSS
   `@import`, `@font-face`, external entities and DTDs, parameter entities, and filter and `<use>` references. Fed the
   same file by its path, librsvg does follow a relative same-directory href (rc 124). rsvg-convert has no option to
   turn external loading off, so the bytes always go on stdin.
   - **PNG, JPEG, GIF and WebP**, recognised by their magic bytes, must declare a size of at most 16384 px per side and
     50 Mpx. They are wrapped as a `data:` URI in an SVG the helper writes itself (`--unlimited` only for that one).
   - **Anything else** is given to rsvg-convert as SVG, with `-w 256 -h 256 -a`: plain, gzip or any XML encoding.
     Whatever it cannot parse is refused.
   - **Limits.** The rsvg-convert child runs with `RLIMIT_AS` 1 GiB and `RLIMIT_CPU` 8 s, under an 8 s timeout. Its
     output must be a PNG of at most 4 MiB.
   - **What the 50 Mpx cap does not cover** (review of dce68c2, minor 5). The cap applies to a raster file the helper is
     given; it does not apply to raster images embedded in an SVG (`data:` URIs). librsvg decodes those at their own
     size, whatever the 256 px output, and the helper cannot see their headers reliably (entities, compression, encodings).
     Only `RLIMIT_AS` (1 GiB) and the CPU limit bound them: the review's 20-image SVG peaked at 583 MiB and rendered, a
     bigger one failed at the memory limit. Either way it happens in the helper's process, never in the shell.
3. **Store** the result in a 0700 directory emptied at start, created with `O_CREAT|O_EXCL|O_NOFOLLOW`:
   - ThemeIcons: `$XDG_RUNTIME_DIR/grassfield-icons-<display>/<n>.png`. At most 128 MiB in all; the least recently
     used copies are deleted to make room. Past 4096 keys, the least recently used quarter is forgotten and its files
     deleted.
   - Notifications: `…/grassfield-notification-images-<display>/<n>.<sender>.png`, with its window, budget and
     per-sender share (notifications.md).
   - The capture thumbnail (docs/specs/capture-suite.md § 3.2, ADR-0066): `$XDG_RUNTIME_DIR/grassfield/capture-thumbs/<pid>-<n>.png`,
     a 0700 folder in the 0700 folder of the capture helper's private files, made and emptied by
     `shell/services/capture-thumb-dir.sh` when the shell starts and when the last card leaves (a link at either level is
     refused). One copy per card, deleted when the card goes. The shell makes it with `image-copy.py file`, under
     `timeout -k 2 20 setpriv --pdeathsig KILL`, from a capture file the thumbnail's own checks accepted
     (`capture-thumb.sh`); a card whose copy fails shows a glyph, never the file. **The capture thumbnail's cap is 64 MiB**:
     the largest display picture supported is 8K (7680 x 4320, 33 Mpx, within the 50 Mpx limit below), 126 MiB raw, and a
     PNG of anything but noise is under half of that; the helper wraps it for rsvg-convert (a third more) within its 1 GiB
     address-space limit.

**Hangs.** A batch runs under `timeout -k 2 60 setpriv --pdeathsig KILL`. After 20 s the helper starts no new item: it
answers `later` for the rest, and ThemeIcons asks for those again first. So a batch of big photos ends in time rather
than being killed with every item refused. A theme name re-encodes at most 3 readable candidates. A QML watchdog
(70 s) sends TERM, then KILL, and refuses the batch's keys. `timeout` signals its whole process group, which includes
rsvg-convert. Each notification file runs under `timeout -k 2 12`.

## Media art over https
Spotify, browsers and others name their art by an `https` URL; the coordinator asked for it after the review of
80f0f19. Unlike macOS, where apps hand Now Playing the image bytes and nothing is fetched by the system, the shell
fetches it (review of dce68c2, minor 1): so it fetches only from public addresses, on behalf of an app that could have
fetched it itself. `ThemeIcons.artSource(url)` is what both Now Playing views show, for `Media.artShown`: the player's
URL, applied 300 ms after its last change, so skipping through tracks fetches only where it stops.
- **URL check.** It must match `https://host[:port][/path]`, both in `ArtUrl.remoteUrl` and in the helper:
  - the host is a name of labels of letters, digits and inner hyphens; no user or password; no empty label, so no
    leading, trailing or doubled dot (review of 684ed6d: `x.` passed the check as `x`, and curl, given `x.`, did not
    match it against `--resolve x:…` and resolved it itself);
  - never an IP literal in any notation: an IPv6 literal does not match, and a host whose last label is a decimal or
    `0x` number is one (`127.0.0.1`, `2130706433`, `0x7f000001`, `0177.0.0.1`, `127.1`), as URL parsers read it;
  - never `localhost` or a `*.localhost` name;
  - the path is printable ASCII without spaces or backslashes; at most 2048 characters.
- **Addresses.** The helper resolves the name itself (3 s at most). Every address must be public:
  - none in a private, loopback, link-local, site-local (fec0::/10), shared (100.64/10), reserved, documentation,
    unspecified or multicast range;
  - an IPv6 address that carries an IPv4 one counts only when that IPv4 address is public too: IPv4-mapped,
    IPv4-compatible (::/96), IPv4-translated (::ffff:0:0:0/96), NAT64 (64:ff9b::/96, a DNS64 network's synthesized
    address), 6to4 and Teredo;
  - local-use NAT64 (64:ff9b:1::/48) never counts.

  curl then connects to exactly those addresses (`--resolve host:port:addresses`), so a second lookup cannot answer
  differently (no DNS rebinding), and to no proxy (`--noproxy '*'`: a proxy would resolve the name itself). Behind a
  mandatory proxy, https art therefore does not show.
- **The URL curl gets** is rebuilt from the parts the helper checked: the lowercased host, the port only when it is not
  443, and the path. So curl's host, the `--resolve` name and the checked name are the same bytes, on every hop.
- **Redirects** are followed by the helper, not by curl: at most 3, and each target goes through the same URL check,
  resolution and address rule before any connection.
- **Fetch.** curl runs with `-q` first (no `.curlrc`), no `HOME` (no `.netrc`), `--globoff`, `--proto =https`,
  `--max-filesize` 5 MiB (and a 5 MiB read cap of the helper's own), 5 s in all over every hop, and a CPU limit. There
  is no cookie engine and no credential, and the user agent is fixed: `Grassfield-NowPlaying/1.0`. Only the session's
  CA variables reach curl. The body stays in memory and is re-encoded like any file into a PNG of at most 256 px. curl
  is a runtime dependency (packaging/arch/PKGBUILD).
- **Cache and order.** There is one key per URL (`url:<url>`), in the same 128 MiB budget and the same
  least-recently-used order. One helper run at a time, and only the newest queued URL is fetched; older ones are
  forgotten and asked again while shown.
- **Retries** (minor 4). A URL that fails is asked again after 60 s, then after 10 min, and only while a view still
  shows it. After its third try it is not asked again this session. The retry map is bounded (review of 684ed6d):
  - at most 256 entries, the oldest leaving first;
  - an entry leaves on success, after its last try, and with its key;
  - an entry also leaves when no view asks for its due retry within two ticks: the URL is no longer shown, so it is
    forgotten and asked afresh if it is shown again.
- **Locked** (minor 3). No fetch starts while the session is locked (`SessionState.locked`), and queued URLs wait for
  the unlock. A run that is fetching art when the session locks is stopped at once: TERM to `timeout`, which signals
  its process group. Its items wait for the unlock under new numbers, and whatever it wrote is deleted. Only art
  already made shows; the lock screen itself shows no media art. Two races are closed (review of 684ed6d):
  - **A lock inside the change that starts a run** (Quickshell signals only a process it reports started). The run is
    not started at all when the change already stopped it. A run that started anyway is stopped as soon as Quickshell
    reports it started, if it was stopped or carries art while the session is locked.
  - **No curl outlives the helper.** curl runs in a process group of its own with `PR_SET_PDEATHSIG` (SIGKILL). The
    helper's SIGTERM handler kills that group before the helper exits, and if the helper is killed outright, curl dies
    with it. rsvg-convert has the same death signal.

**The copy directory belongs to the user,** like every file of the session, the shell's own QML included. A process
running as the user can replace a copy. The design protects against what applications *name*: a path, a theme file, a
FIFO, a device, an SVG with references, or a hostile image for Qt's decoders. It does not protect against code already
running as the user.

## Tests
`tests/security/theme_icon_files.sh` runs offscreen with the REAL shell modules:
- **Part 1:** user icon files for a theme name: FIFO, symlinks, devices, an SVG referencing a FIFO, and the review's
  gzip, UTF-16, BOM and comment-prefixed SVG, and SVG-in-.png bypasses.
- **Part 2:** hostile `index.theme` files.
- **Part 3:** Launchpad, desktop, thumbnails, the About panel, media art `file://` naming a FIFO or an SVG that
  references one, the lock avatar, and flatpak symlinks.
- **Part 4:** the policy: the logged search paths (read back from Qt) are only `/usr/share/icons` and
  `/usr/share/pixmaps`; a root-owned icon directory outside `/usr/share` found on the machine (`/opt/spotify/icons`
  here), named by `XDG_DATA_DIRS`, is not searched by Qt and is in the helper's bases. An LD_PRELOAD open log is kept. A user-writable
  pixmaps icon is found and opened by the same probe without Grassfield.I18n (a positive control), and neither found
  nor opened with it. Offscreen, Qt searches no theme folder even without the policy, so user theme folders are
  reported NOT VERIFIED there; part 2 covers them.
- **Part 6:** https media art, offline, against a local HTTPS server on 127.0.0.1 with a throwaway CA and a plain
  HTTP twin. It is reached as `art.test` through a test stand-in of the helper (`image-copy-testnet.py`, never
  shipped). The stand-in changes only name resolution, and admits 127.0.0.1 for that one name. The system resolver does
  not know `art.test`, so a fetch that works shows that curl used the pinned address. Fetched: a PNG, and an SVG naming
  a FIFO (the FIFO untouched). Refused before any request: IP literals in every notation, localhost names, names
  resolving to loopback, private or IPv4-mapped loopback addresses, and redirects to a loopback name or an IP literal.
  The address rule is checked against every range. Also refused:
  - text/html;
  - a redirect to http (its target is never asked) or to `file:`;
  - a fourth redirect;
  - more than 5 MiB, announced or chunked;
  - a response slower than 5 s;
  - an http URL, and a URL with credentials.

  No request carries a cookie or credentials. The pin cases use the machine's host name, which the system resolves to
  a loopback address where a second server listens (a positive control shows it). The stand-in pins that name to an
  address where nothing listens. A trailing dot, several dots, an uppercase name, the plain name and a redirect Location
  with a trailing dot never reach that server. URL vectors, rebuilt URLs and address vectors (IPv4-compatible, NAT64,
  IPv4-translated, site-local) are checked, and `fetch()` is checked with curl stubbed. The helper killed mid-fetch
  with SIGTERM or SIGKILL leaves no curl. In the shell:
  - no fetch starts while locked, and the held art is fetched after the unlock;
  - a fetch running when the session locks is stopped at once (no curl left) and fetched again after the unlock;
  - a lock inside the change that starts a run sends no request and leaves no curl; the URL is fetched once, after
    the unlock;
  - of three URLs asked in one turn, only the newest is fetched;
  - a URL failing twice is shown on its third try, and one that always fails is asked exactly three times;
  - a failed URL no view shows any more is forgotten, and the retry map is bounded.
- **Part 5:** the tray: the real `TrayButton` with fake items (IconThemePath FIFO, absolute and traversal `IconName`,
  pixmap and plain name). There is also a private-bus StatusNotifierItem run (`env -i`, a private
  `DBUS_SESSION_BUS_ADDRESS` and a guard refusing the session bus). Its dbus-daemon uses the session bus's default
  policy (a policy without a receive rule dropped every reply, the Hello reply too, so the run could never pass), and
  `theme_icon_files.d/bus_check.py` checks first that the bus carries a method reply and a signal, naming the error when
  it does not. The address must be exactly the socket dbus-daemon made in the test's directory. Both tray probes record
  an icon only once its Image has stopped loading (an asynchronous load read too early showed status 2). It is skipped
  where Unix sockets are blocked.

`tests/shell/notif_image_files` and `notif_image_budget`, `notif_image_fairness` and `notif_clear` cover notification
images. They include an SVG in a `.img` file that names a FIFO.

## Residual risks
- librsvg, cairo and libxml2 parse hostile input. They do it out of the shell, under limits; a crash there costs one
  image.
- An image whose embedded raster fails to decode becomes a transparent PNG, not a refusal.
- A batch of slow documents delays other icons or notification images for up to its timeout. The shell itself never
  waits.
- The lock screen's avatar appears once the helper answers, usually within about 50 ms of start.
- Raster images embedded in an SVG are bounded by the helper's memory and CPU limits only (see "What the 50 Mpx cap
  does not cover").
- An app can still make the shell fetch from any public https host, which it could do itself.
- Behind a mandatory proxy, https art does not show.
