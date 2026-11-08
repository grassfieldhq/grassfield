# ADR-0030: Settings changes the system only through the system services' own polkit actions
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (cloud session, owner brief 2026-10-26: "toute action privilégiée passe par polkit et demande un ADR, plus une
relecture opus") · Date: 2026-10-26 · Decider: owner (brief), integrator (merge after the opus review) · Number: 0030 (it was 0025,
then 0026; the integrator gave 0026 to 0029 to the Files decisions of PR #4)

## Context
The General group of the Settings parity work (`docs/specs/settings.md` § macOS 27 parity inventory) needs the first changes
that are not the user's to make alone:
- About > Name: the computer's name (hostname1 `SetPrettyHostname`, `SetStaticHostname`);
- Date & Time: automatic time, the time zone and the time itself (timedate1 `SetNTP`, `SetTimezone`, `SetTime`).

Later groups add printers (CUPS through `cups-pk-helper`) and power profiles. They get their own entry in this ADR, or their own ADR,
before they land (Hardware group: NetworkManager, Battery and Printers below).

Grassfield already runs the session's polkit agent (`shell/security/`, Quickshell Polkit, SEC6). Omarchy changes the time zone
with `sudo timedatectl set-timezone` from a terminal menu, and generates locales through its own sudoers rule or `pkexec`
(`omarchy-language`). The Settings app has no terminal, no setuid helper, and must not get one.

Each systemd service declares its own polkit actions:
- hostname1: `org.freedesktop.hostname1.set-static-hostname` and `.set-machine-info`;
- timedate1: `org.freedesktop.timedate1.set-time`, `.set-timezone` and `.set-ntp`.

These actions default to `auth_admin_keep` for the active local session. Each method takes an `interactive` flag that lets the
service ask the session's agent itself.

## Decision
- The Settings app calls the system service's own D-Bus method, with `interactive = true`, on the system bus, from a worker
  thread (`apps/settings/src/systembus.cpp`, `busjobs.h`). The service asks polkit. Polkit asks the session's agent, Grassfield's
  sheet, which shows the message, the action id and the requesting program. The service changes the system only when polkit
  says yes.
- No Grassfield code runs as root: no helper, no `pkexec`, no sudo, no setuid binary, no new polkit policy, no rule file. The
  defaults of each service's own policy apply: the administrator's password, kept for a few minutes (`auth_admin_keep`).
- The call waits for the user's answer for up to 120 s (`kPrivilegedMs`). The job's deadline covers three such calls (Add
  Printer's), 370 s (`kPrivilegedJobMs`). The window never blocks. A refusal, a cancelled dialog or no agent at all comes back
  as the service's error and is shown on one line under the group: "The name could not be changed: not allowed: the system
  refused the request". The page then reads the state again. Nothing is retried on its own.
- One polkit action per tag at a time, held by the Backend and not by the page (integrator review of PR #6): a page is created
  anew on each visit, so a waiting state kept there let a second request go out while the first dialog was up, and four such
  blocked calls filled the jobs' `kMaxInFlight`, after which every read of the system bus answered "timed out". `busAct` now
  refuses a polkit action while one of its tag runs (`InFlight`, busjobs.h; `omarchy-language` of `act` likewise), and the
  pages show "Waiting for permission…" from `Backend.pendingActions`, also when opened again while the dialog is up.
- Every op is validated twice:
  - in QML (`General.js` builds the map or returns null);
  - again in C++ (`validAction`):
    - a computer name: 1 to 64 characters, no control character;
    - a zone: one to four segments of `[A-Za-z0-9_+-]` separated by `/` ("Europe/Paris", "America/Argentina/Buenos_Aires",
      "UTC"), at most 64 characters;
    - a time: microseconds between 2000 and 2200, as a decimal string;
    - NTP: a boolean.
  - The static host name is derived in C++ from the validated name (`hostNameFor`: lower case ASCII letters, digits and `-`,
    63 at most). QML never sends it.
- Dev guard (ADR-0019): in a dev session `Backend.busAct` sends nothing. One `dev guard: … suppressed` line is logged and the
  page shows "dev: not applied". Below that, `GuardedCaller` lets only reads through to these services in a dev session:
  `Properties.Get/GetAll`, timedate1 `ListTimezones`, systemd `ListUnitFilesByPatterns`. A nested session can therefore never
  change the owner's clock or name, whatever the QML asks.
- The language goes through Omarchy's own per-user command (`omarchy-language <code>`, owner decision 2026-10-26). Grassfield
  runs that command as an action: one validated code, one argument vector, no shell, no action in a dev session.
  **Not on Omarchy 4.0.4** (integrator review of PR #6, on the owner's machine): 4.0.4-1 ships no `omarchy-language` (no
  package owns it, it is in neither /usr/bin nor /usr/share/omarchy) and no `omarchy-locale-generate`. So:
  - it is not a read-only query (`isReadOnlyQuery`): a dev session never runs a script nobody here has read on the machine
    (ADR-0019). A real session reads it (`omarchy-language list`, `omarchy-language`) only when it is installed
    (`Backend.omarchyLanguage`: found on PATH, never run to find out);
  - without it, Language & Region shows the session's language (its LANG, the locale Settings runs in) and says that
    changing it needs a newer version of Omarchy: no picker that cannot work, and no bare "Unknown" (R11).
  What the command does is Omarchy's, not Grassfield's. **Everything in the list below is NOT VERIFIED on Omarchy 4.0.4**: it
  was read in Omarchy's upstream sources at commit 58858ae, and a later release that ships the command may differ:
  - it generates the locale when it is missing: `sudo -n` through Omarchy's passwordless sudoers rule for its own helper
    `omarchy-locale-generate`, else `pkexec omarchy-locale-generate <code>`, whose password dialog is Grassfield's polkit
    agent (the same sheet as the services above);
  - only once the locale exists, it writes the language file and `~/.config/uwsm/env.d/50-omarchy-language` (LANG for the
    next login), seeds an input method for Chinese, Japanese and Korean, runs `hyprctl eval 'hl.env("LANG", …)'` on the live
    compositor (apps started by Hyprland from then on get the new LANG) and `omarchy-restart-shell`, which is the no-op
    shim in a Grassfield session (packaging/shims), and sends a notification;
  - Settings waits up to 130 s (`actionTimeoutMs`), as long as a polkit call above. When that time is up Settings stops the
    command and says "timed out"; a pkexec dialog that is still open stays open (pkexec is a separate process) and can be
    cancelled; answering it then only generates the locale, the language does not change (the command that would have
    written it is gone). The page asks to log out and back in: grassfield-shell keeps its language until then.
- Unprivileged changes stay what they were: the user's own systemd services (`EnableUnitFiles`/`DisableUnitFiles` on the
  session bus, only units under the user's own unit folders) and the user's autostart folder. They are not polkit actions.
  An autostart write or removal touches only a plain `<name>.desktop` of that folder that is not a symbolic link (a write
  would go through the link, to a dotfile manager's file or out of `.dev`), and in a dev session only a folder whose real
  location lies under the worktree's `.dev` (`isAutostartWrite`, systemguard.h; review finding of 2026-10-26).

- Hardware group (PR #8), NetworkManager. NetworkManager checks its own polkit actions for every client call and lets
  polkit ask the session's agent; the method has no `interactive` argument. Grassfield sends these calls only:
  - Wi-Fi > Forget This Network: `Settings.Connection.Delete` on the saved Wi-Fi profile with that uuid (`wifi.forget`).
    A profile of the whole system needs `org.freedesktop.NetworkManager.settings.modify.system`, `auth_admin_keep` or `yes`
    depending on how the distribution built NetworkManager, so the call may wait for the dialog: 120 s, as above. A profile
    of any other type is refused (a VPN uuid is not a network to forget).
  - Joining a new network (`wifi.connectOpen`, and `wifi.connectSecure` with a WPA/WPA3 personal password):
    `AddAndActivateConnection` adds a profile of the whole system (the same action, `settings.modify.system`), so it waits 120 s
    too. The password goes from the sheet's field to that one call: it is validated (8 to 63 printable ASCII characters or 64
    hex digits) in QML and in C++, never logged (a dev session logs only "wifi join"), and the field is emptied on Join and on
    Cancel; NetworkManager stores it in the profile, as nmcli does. A join that does not come up within 30 s deletes the
    profile it added, so a wrong password leaves no saved network behind. A join cut short before NetworkManager answers (the
    120 s run out while the dialog is open, or Settings closed during the join) cannot be followed: if NetworkManager then
    adds the profile, it stays, with its password, until Forget This Network… (review of 2026-10-26, accepted).
  - VPN switches: `ActivateConnection` of a `vpn` or `wireguard` profile on no device, `DeactivateConnection` of its active
    connection (`vpn.connect`; `network-control`, `yes` for the active session by default). A VPN that needs a secret it does
    not store needs NetworkManager's secret agent, which Grassfield does not provide: the activation fails with
    NetworkManager's own reason, shown under the list.
  All are validated twice (a uuid, an SSID, a password, a boolean) and are refused by `GuardedCaller` in a dev session
  (`tests/unit/settings/tst_systembus.cpp`, `tests/integration/settings_dbus.sh` section 11).

- Hardware group, Battery:
  - Low Power Mode sets Omarchy's two remembered power profiles with Omarchy's own command, `omarchy-powerprofiles-set
    ac|battery <profile>` (an action: one source and one of the three profiles, nothing else; the source in use last, as the
    command applies what it remembers at once). The command switches the profile with `powerprofilesctl`, through
    power-profiles-daemon and its own polkit action for switching profiles (not read here: owner check); it writes
    the choice under `$XDG_STATE_HOME/omarchy/powerprofiles/`. The shell runs `omarchy-powerprofiles-set autodetect` when the
    power source changes. Neither runs in a dev session.
  - Charging > Limit charging calls UPower's `EnableChargeThreshold(b)` on the battery (`power.chargeLimit`), whose polkit
    action `org.freedesktop.UPower.enable-charging-limit` defaults to `yes` for the active session (read in UPower's sources,
    commit 68438ca); it may wait for the agent like the calls above (120 s). Shown only when UPower says the battery has a
    limit (`ChargeThresholdSupported`).
  - Reads only: `power.state` (UPower's properties, `EnumerateDevices`, `GetHistory`), allowed in a dev session.

- Hardware group, Printers (macOS 27 Printers & Scanners, without scanners and fax). Omarchy installs `cups`, `cups-filters`,
  `cups-pk-helper`, `system-config-printer`, `avahi` and `nss-mdns`, and enables `cups.service` (read in Omarchy's
  `install/omarchy-base.packages` and `install/config/enable-services.sh`, branch quattro; owner check on the installed 4.x).
  - Reads are commands, run in the C locale like every tool of the app (English output): `lpstat -l -p` (the queues, their
    state, Description and Location), `lpstat -d` (the default: CUPS reads the user's `~/.cups/lpoptions` first), `lpstat -v`
    (each queue's device URI: its kind), `lpstat -a` (whether each queue accepts jobs), `lpstat -l -e` (Add Printer: what the local cupsd and a second of DNS-SD browsing
    find; a driverless printer not yet queued is a `network` line with its URI) and `lpoptions -p <queue> -l` (its PageSize
    choices, the one in effect marked `*`). Exactly these argument lists are allowed (`isReadOnlyQuery`); a queue name is
    validated first. They read, they change nothing, so a dev session runs them too.
  - The default printer and the default paper size are the user's, as on macOS, and need no password: `lpoptions -d <queue>`
    and `lpoptions -p <queue> -o PageSize=<size>` (for every queue that offers that size) write the user's `~/.cups/lpoptions`,
    nothing else (CUPS writes `/etc/cups/lpoptions` only for root, which Settings never is). Actions (`isAllowedAction`: these
    two forms, a valid queue name, a PPD size keyword), never in a dev session.
  - Adding and removing a printer change the system. They go to `cups-pk-helper` (system bus,
    `org.opensuse.CupsPkHelper.Mechanism`, object `/`, the same interface; read in Debian's 0.2.6 sources, Arch ships 0.2.7),
    which asks polkit with user interaction and then asks cupsd as root:
    - Add (`printer.add`): `PrinterAdd(name, uri, "everywhere", info, "")`, then `PrinterSetEnabled(name, true)` and
      `PrinterSetAcceptJobs(name, true, "")` (a new queue starts stopped and refusing jobs, as `lpadmin` without `-E`); three
      calls, so the job's deadline is 370 s. The
      model "everywhere" makes cupsd build the queue's PPD itself from the printer's IPP attributes, in the background, for a
      `dnssd:`, `ipp:`, `ipps:` or `ippusb:` URI (CUPS `scheduler/ipp.c`, `add_printer`); a printer that does not describe its
      media is dropped again by cupsd. Only such driverless printers are offered (macOS adds AirPrint printers the same way);
      a printer that needs a driver is out of scope (Omarchy's `system-config-printer` does that).
    - Remove (`printer.delete`): `PrinterDelete(name)`, after a confirmation sheet ("Remove …?").
    - Resume (`printer.resume`): `PrinterSetEnabled(name, true)` and `PrinterSetAcceptJobs(name, true, "")`, offered in a
      printer's sheet while it is stopped or refuses jobs (`lpstat -p`, and `lpstat -a`, another read of the allow-list).
    - Polkit: `org.opensuse.cupspkhelper.mechanism.all-edit`, `.printeraddremove`, then `.printer-local-edit` or
      `.printer-remote-edit` (and `.printer-enable` for the two switches): all `auth_admin_keep` for the active session. The
      helper asks interactively for the last one only. Polkit keeps an authorisation per action id, so the switches after an
      add may ask a second time (whether the add's kept `printer-local-edit` or `printer-remote-edit` also covers them depends
      on how the helper judges the new queue: not verified, owner check). A second dialog refused or cancelled leaves the queue
      added, stopped and refusing jobs: the page shows it so ("Stopped", "Not Accepting Jobs") and its sheet offers Resume and
      Remove Printer…; nothing is rolled back behind the user's back (a delete would ask again). 120 s for each call, as
      above (`kPrivilegedMs`). The helper returns CUPS's own message on failure (shown under the list); a polkit refusal comes
      back as its `NotPrivileged` error, "not allowed".
    - Validated in QML (`Printers.js`) and again in C++ (`validAction`): a queue name of 1 to 127 characters
      `[A-Za-z0-9_.+@-]` not starting with `-`; a URI of one of the four schemes, at most 1024 characters, without spaces or
      control characters; the description (`info`, the name with `_` shown as spaces) printable, at most 127 characters.
  - `PrinterSetDefault` is not used: the default printer is the user's (above). Note for a later use: in 0.2.6 it checks an
    action id (`printer-default`) that its own policy does not define (`printer-set-default`).
  - Dev guard: `Backend.busAct` sends nothing in a dev session and `GuardedCaller` lets no `cups-pk-helper` method through
    (none of them is a read); the `lpoptions` actions are refused there like every action. A nested session can therefore
    never add, remove or change the owner's printers.
- Desktop group, Privacy & Security (macOS 27 Privacy & Security, with the permissions the desktop portals keep; amendment of
  2026-10-26). These are the user's own grants: no polkit action, the session bus, as the user's services above.
  - The store: xdg-desktop-portal's permission store, `org.freedesktop.impl.portal.PermissionStore` (session bus, object
    `/org/freedesktop/impl/portal/PermissionStore`, an interface of the same name; read in xdg-desktop-portal's sources at tag
    1.22.1, the version Arch ships, and on main: `document-portal/xdg-permission-store.c`). It is D-Bus activated
    (`xdg-permission-store`, in the `xdg-desktop-portal` package Omarchy installs). It checks no caller: any client of the
    user's session bus may read and write it, so Settings asks for nothing more than any portal client has.
  - Reads (`privacy.state`; `isReadOnlyCall` lets the store's `Lookup`, `List` and `GetPermission` through, so a dev session
    reads it too): `Lookup` of `location`/`location`, `background`/`background` and `devices`/`camera`; `List` of the
    `screencast` and `remote-desktop` tables, then one `Lookup` per saved selection (the malformed ones dropped first, then at
    most 128 per table). A missing table or entry (`org.freedesktop.portal.Error.NotFound`) is "none", not an error.
    Application ids and restore tokens are checked (`isPortalAppId`: no path, no `..`; `isPortalToken`: the portal's own rule,
    `[A-Za-z0-9_]` or a legacy UUID, so the one token in 32 that begins with `_` is kept), anything else is dropped; the host
    applications without an id (the `""` key) are not listed.
  - Values, as the portals read them: location keeps `[accuracy, timestamp]` (fewer than two elements is no entry, and the
    portal asks again), allowed is any accuracy but `NONE`; the camera and the background keep `["yes"]`, `["no"]` or
    `["ask"]` (asked every time: shown as not allowed). A saved selection (screen sharing, remote desktop) is one entry per
    restore token with the application's row and the compositor's data: the application may reuse that screen, window or
    device choice without the picker.
  - Writes: `privacy.allow {category, app, on}` is `SetPermission(table, true, id, app, value)` with `["EXACT", "0"]` or
    `["NONE", "0"]` for location and `["yes"]` or `["no"]` otherwise; `privacy.forget {kind, token}` is `Delete(table, token)`,
    one action per token (an entry already gone, `NotFound`, is not a failure). Validated in QML (`Privacy.js`) and again in
    C++ (`validAction`): a known category or table, a valid id or token, a boolean switch.
  - What it cannot do, said in the pane: only sandboxed applications (Flatpak) are limited by these grants. The portal allows
    an application of the host its location and the background without reading the store (`location.c`, `background.c`; it
    still writes a location row for it), so such a row has no switch there and says "Not sandboxed: not limited". An
    application is taken for the host's (`Privacy.hostApp`) only when no Flatpak export holds its desktop entry, it is not
    a Snap and a visible entry exists elsewhere; every applications folder is read, so a user's copy or hidden stub of a
    Flatpak's entry does not hide its switch, and in doubt the switch stays (an id whose entry is not found, as one from a
    subfolder, keeps a switch that may do nothing: accepted). The camera's grant is read for every application, so its
    switch stays, and a host application's row says it may use the camera directly. A `no` for the background refuses the application's request; stopping a Flatpak that
    already runs needs a portal backend that implements Background (the security review read xdg-desktop-portal-hyprland
    1.4.1, which implements Screenshot, ScreenCast, GlobalShortcuts and InputCapture only, and xdg-desktop-portal-gtk, which
    dropped Background and RemoteDesktop in 1.15.0: on Omarchy the Background and RemoteDesktop portals may not be exported
    at all, owner check `busctl --user introspect org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop`). So
    `privacy.state` also reads `Properties.Get(<portal>, "version")` on `org.freedesktop.portal.Desktop` for those two (the
    only portal read `isReadOnlyCall` allows; a missing interface is false, no answer within 1 s is unknown and the second
    is not asked). It asks only when the portal already runs (`NameHasOwner`, the one bus read allowed), and QtBusCaller
    never auto-starts the portal: on a dev session's private bus that would start xdg-desktop-portal and with it the
    document portal, which unmounts and remounts the owner's `$XDG_RUNTIME_DIR/doc` (re-check of 4ca0246, M1; a real
    session runs it already). A category whose portal is missing stays, reading "Not used on this system", its footnote
    saying no app can ask for it (owner decision 2026-10-26: keep the category, with a line). A saved
    choice removed while the application is sharing is saved again when that session ends: the footnote says to stop
    sharing first. `["ask"]` reads as not allowed (the portal asks every time).
  - Dev guard: `Backend.busAct` sends nothing in a dev session and `GuardedCaller` lets only the reads through (the store's
    `Lookup`, `List` and `GetPermission`, `NameHasOwner` for the portal, the two portals' `version`): a nested session never
    changes the owner's grants.
  - Tests: `tst_systembus.cpp` `SystemBusPrivacy.*` (the reads as the portals keep them, no store as a reason, the exact
    `SetPermission` and `Delete`, bad values and the dev guard send nothing), `tst_systemguard.cpp` `PrivacyGuard.*`,
    `settings_dbus.sh` section 15 (a fake store on the private bus: every call logged with its arguments; the Backend's
    caller never starts the desktop portal, a service the bus can start being started; the bus has its own configuration
    and starts only the test's own services, never the machine's store or portal),
    `tests/unit/tst_settingsprivacy.qml` (the state checked again, the counts, a switch, the host's applications without one,
    the saved selections forgotten one after the other, a failure's reason, the dev guard).
  - Security review (opus), 2026-10-26: FAIL on 5223a69 + f8a6b65 (H1: the token rule rejected the portal's tokens that begin
    with `_`, so those saved choices could neither be seen nor removed; M1 the cap counted malformed tokens; M2 a switch for
    the host's applications that does nothing; M3 the background footnote claimed more than the portal does; L1 removal while
    sharing; L4 the id beside a saved choice) → fixed in the commit after them, then M3's runtime check of the portals
    (the owner's choice above); still open: L2 (`ask` shown as such), L3 (no row cap, names looked up on the GUI thread),
    L5 (a removal's queue lives in the page). Counter-review of the three commits: PASS (no HIGH), with N1 (the host
    check let a user's copy of a Flatpak's entry hide its switch), M3r (the portal check needed before merge), N2 (ids
    named like Object.prototype's properties broke the page's maps), N3 (the footnote named Flatpak only and said host
    applications are not limited while their camera switch stays), N5 (one error tag for every category): all fixed in
    the commit after (every folder read, the portal check, maps without a prototype, "Flatpak, Snap", a tag per category);
    L2, L3 and L5 accepted for merge by that review; N4 (a switch kept in doubt) accepted above. Re-check of that commit:
    PASS, with M1 (the portal read could start the portal, above), L1 (a Linyaps app's entries folder now counts as a
    sandbox's), L2 (an export entry that exists but cannot be read counts, in doubt), L3 (the Flatpak export folders are
    read for the host check even when XDG_DATA_DIRS leaves them out), L4 (the portal read's timeout is 1 s), L5 (tests: a
    failure stays in its category, every "missing" error name, the dev read of the portals): fixed in the commit after.
    Re-check of that commit: PASS, with MEDIUM-2 (the D-Bus test's bus used the system's session.conf and the caller's
    environment, so on Arch it started the real permission store with the owner's home and failed), LOW-1 (nothing tested
    that the caller never auto-starts the portal) and LOW-2 (nothing tested the export folders outside XDG_DATA_DIRS):
    fixed in the commit after (the test bus's own configuration and clean environment, an activation check with a control,
    a QML case). MEDIUM-1, pre-existing and not Settings' read: the dev session's private bus (scripts/dev/shell-run.sh,
    ADR-0011) used the standard service folders and the owner's XDG_RUNTIME_DIR, so Qt's gtk3 platform theme (ReadAll on
    org.freedesktop.portal.Settings, auto-start on) started the desktop portal there and with it the document portal, which
    unmounts the owner's `$XDG_RUNTIME_DIR/doc` (probably the dev shell too: a Quickshell build with gtk3 started it on a
    test bus; not run nested). By the owner's decision (2026-10-26, "Bloquer les portails"; ADR-0011 amendment) that bus
    now blocks both portals.

## macOS reference
System Settings > General > About > Name and Date & Time change machine-wide settings. They ask for an administrator's password
(the lock, or a sheet) and remember it for a while. Nothing else in the window changes while the system asks.

## Alternatives rejected
- A Grassfield polkit helper (a small root binary with its own policy): a new privileged component, its own attack surface
  and review. The systemd services already are that helper.
- `pkexec timedatectl …` / `pkexec hostnamectl …`: runs a whole program as root for what one D-Bus method does, and puts the
  arguments on a command line.
- `sudo` from a terminal (Omarchy's menu): there is no terminal in Settings, and the brief rules sudo out.
- `interactive = false` with a separate `pkcheck` first: a race between the check and the call, and two prompts.

## Consequences
- Tests:
  - `tests/unit/settings/tst_systembus.cpp`: the exact calls, the `interactive` flag and the derived host name against a canned
    bus.
  - `tests/integration/settings_dbus.sh`: fake hostname1, timedate1 and systemd services on a private bus. Each method, a polkit
    refusal and the dev guard.
  - `tests/unit/tst_settingsgeneral.qml`: the QML-side builders.
  - Printers: `tst_systembus.cpp` `SystemBusPrinters.*` (the three calls of an add, in order, the delete, CUPS's message and a
    polkit refusal as the reason, bad values and the dev guard send nothing), `tst_systemguard.cpp` `PrinterGuard.*` (the exact
    reads, the two lpoptions forms, names, URIs and paper keywords), `settings_dbus.sh` section 14 (a fake cups-pk-helper on the
    private bus), `tests/unit/tst_settingsprinters.qml` (CUPS's output, the ops, the paper size written only to the queues that
    have it, a dev session reads and changes nothing).
- The real polkit dialog cannot be shown in a nested session (the agent cannot register there, `docs/specs/security.md` L5). The
  owner checks it in the real session (L2): change the name and the time zone, cancel once, enter a wrong password once, and
  leave the dialog open for 60 s before answering (the service's own polkit query must still apply the change); switch the
  language to one whose locale is not generated yet (Omarchy's prompt or grant, then log out and in) and back.
  Printers (owner, real session with a network printer): Add Printer… (the dialog, then a test page), the default printer and
  the paper size (check `~/.cups/lpoptions` and a print dialog), Remove Printer… (cancel once, then confirm); `pacman -Q
  cups-pk-helper` shows it installed (Omarchy's base list).
  Privacy & Security (owner, real session with a Flatpak that asks for the camera or the location, and one that shares a
  screen): the pane lists them; switch one off and check the application is refused; remove a saved screen choice and check
  the picker comes back; `flatpak permissions` shows the same grants.
- A review by the security reviewer (opus) is required before merge. 2026-10-26: FAIL (an autostart write through a symlinked
  entry; no test of those writes; this ADR silent on what omarchy-language does; a region changing the words; the zone
  wording) → 55d87be → counter-review FAIL (a textual `link/..` path normalised past the folder check) → e0db168 →
  counter-review #2 PASS on the whole scope. Not verified by it: the real polkit dialog, real hostname1/timedate1/systemd,
  the installed omarchy-language, a nested session (owner checks above).

## Amendment (ADR-0033, Software Update, 2026-10-27; opus PASS with ADR-0033 step 0, merged 609017f; Proposed until the owner accepts it)
Software Update in Settings (General > Software Update, step 2 of ADR-0033) is an exception to "No Grassfield code runs as
root: no helper, no `pkexec`, no new polkit policy". No system service owns pacman's configuration, so there is no service
polkit action to call. By the owner's decision O1 (2026-10-27), changing the `[grassfield]` channel goes through a Grassfield
root helper:
- `/usr/lib/grassfield/grassfield-channel-helper`, run by `pkexec`;
- its own polkit action `org.grassfield.packages.set-channel` (`auth_admin_keep` for the active session, `no` otherwise).
Settings starts it through the user command `grassfield-channel-set` as a child process, in this ADR's pattern: a worker,
the argument checked in QML and in C++, "Waiting for permission…", one action at a time, up to 120 s, a refusal or a cancel
shown on one line, nothing in a dev session. The helper:
- takes only fixed verbs (`set stable|beta`, `restore`, `off`);
- reads no environment variable (it runs itself again under `env -i`);
- writes only `/etc/pacman.d/grassfield.conf`, two lines of `/etc/pacman.conf`, pacman's synced `[grassfield]` files and
  pacman's keyring entries for Grassfield's keys;
- installs no package.
It and its policy need the security reviewer's (opus) PASS before they merge. Everything else in this ADR stands. Details:
ADR-0033 c.

## Amendment (ADR-0037, Grassfield Store, 2026-10-27, Proposed)
Grassfield Store is a second exception to "No Grassfield code runs as root: no helper, no `pkexec`, no new polkit policy",
by the owner's decision ST4 (2026-10-27): installing and removing the repository packages the user picks in the Store goes
through a Grassfield root helper (ADR-0037 b.1):
- `/usr/lib/grassfield/grassfield-store-helper`, run by `pkexec` as a waited-for child of the Store;
- its own polkit action `org.grassfield.store.manage-packages` (`auth_admin` for the active session, never kept: the password
  at every operation; `no` otherwise), whose message names the packages through polkit's `$(command_line)` (ADR-0037 b.1,
  S18).
The Store follows this ADR's pattern: a worker, the arguments checked in QML and in C++, "Waiting for permission…", one
action at a time, up to 120 s for the dialog, a refusal or a cancel shown on one line, nothing in a dev session. The helper:
- takes only `install <op-id> <packages>` and `remove <op-id> <packages>`, 1 to 64 validated names; `remove` only for
  explicitly installed repository packages that own an application entry, never a name of its fixed deny list (kernels, firmware,
  `base`, `sudo`, `systemd`, the boot tools, pacman), of Omarchy's two package lists, `grassfield-*` or `HoldPkg`, and only
  when the whole `pacman -Rs --print` plan names none of them (ADR-0037 b.1, S16);
- reads no environment variable but `PKEXEC_UID`;
- runs only `pacman -S --needed --noconfirm` or `pacman -Rns --noconfirm` on those names (never `-y`, `--overwrite`, `-dd`
  or a file), after checking `db.lck` and `pacman -Qu`;
- writes only pacman's own files (through pacman) and its status files under `/run/grassfield-store/`.
The AUR and Omarchy's recipes do not go through it (they run in Omarchy's terminal with sudo, ADR-0037 b.2). It and its policy
need the security reviewer's (opus) PASS before they merge. Everything else in this ADR stands.

## Amendment (ADR-0033 "Step 3", Software Update's Update Now, 2026-10-29, Proposed)
Update Now is a third exception to "No Grassfield code runs as root", by the owner's decision SU-M1 (2026-10-29, confirmed by
the owner): Omarchy's system update runs without a terminal through a Grassfield root helper:
- `/usr/lib/grassfield/grassfield-update-helper`, run by `pkexec` from the user's runner `grassfield-update-run`, which
  Settings starts detached (one exact vector, nothing in a dev session); on a system run by systemd the helper continues as
  the transient system service `grassfield-update.service`, so neither Settings nor the session can stop pacman;
- its own polkit action `org.grassfield.packages.update-system` (`auth_admin` for the active session, never kept; `no`
  otherwise), in `org.grassfield.packages.policy` beside the channel's.
The helper:
- takes only `run <op-id> [<migration>...]` (a 32-digit operation id used once, up to 64 names of `[0-9]{1,20}.sh`);
- reads no environment variable (it runs itself again under `env -i`; not even `PKEXEC_UID`);
- runs no Omarchy script: only pacman, `pacman-key --list-keys`, `paccache`, snapper, bsdtar (reading two package files as
  data), `systemd-inhibit` and `systemd-run`, with the arguments of the Omarchy scripts they replace (pinned in
  `docs/upstream/omarchy.lock`);
- changes nothing before its checks pass (a plan from a copy of the sync databases, the compatibility check, the steps that
  need a person), then takes a snapshot, makes the checked databases the system's and runs `pacman -Su --noconfirm`
  (ADR-0033 s3.2);
- writes only pacman's own files (through pacman, and the sync databases it checked), snapper's snapshots, and its status
  files under `/run/grassfield-update/`.
It, its runner and its policy need the security reviewer's (opus) PASS before they merge. Everything else in this ADR stands.

## Amendment (ADR-0033 "Step 5", owner decision SU-M2, 2026-10-31, Proposed)
The owner chose one password for Update Now and the `sudo` commands of Omarchy's migrations (« Mot de passe unique »). This
widens step 3's exception; it needs the security reviewer's (opus) PASS before it merges:
- `grassfield-update-helper` may run, after its transaction, the migrations that update brings (the same loop as
  `omarchy-migrate`, by name). It runs them as the person who chose Update Now: pkexec's caller, with a real uid of 1000 or
  more, who must be an administrator (in `wheel`). They run in the transient system unit
  `grassfield-update-migrate.service`, with:
  - the primary group `grassfield-update` (sysusers.d, no member), so the person's other processes cannot open the unit's
    `/proc` entries or attach to it;
  - `NoNewPrivileges=yes`, no namespace of its own (`RestrictNamespaces=yes`), its personality locked;
  - a `/tmp` of its own.
  The helper still runs no Omarchy script as root and reads no variable for itself. It reads its caller's uid and two session
  values (`WAYLAND_DISPLAY`, `HYPRLAND_INSTANCE_SIGNATURE`, checked) from `/proc`, for that unit only.
- **A polkit rule**, the first Grassfield ships: `/usr/share/polkit-1/rules.d/49-grassfield-update.rules`. It lets a
  process of that unit, and no other, start a transient unit named `grassfield-update-root-<32 hex>.service` through
  systemd (`org.freedesktop.systemd1.manage-units`, verb `start`), without a dialog. The migrations' `sudo`
  (`/usr/lib/grassfield/update-sudo/sudo`, run as the person) asks systemd for one such unit per command.
- **It runs only when all of these hold,** otherwise the run goes to Omarchy's terminal before any change:
  - systemd;
  - an administrator;
  - no older migration pending;
  - the unit's group without a member;
  - a trial `sudo true` through the channel.
- **What needs a person still goes to the terminal:** `gum`, `/dev/tty`, `pkexec`, `su`, `run0`, `doas`, or a `sudo` by its
  path.

Details, the boundary, what remains (the person's own files, as in Omarchy's terminal) and the evidence are in ADR-0033
"Step 5". Its independent opus review failed the first version (a non-administrator, and `/proc/<pid>/fd`); the conditions
above answer it, and the re-review passed (its minors answered: the migrations' `sudo` takes root as its only target). The
integrator's opus review found no MAJOR; its required minors are answered (no namespaces in the unit; the migrations, their
folder, the sudo and every root command root's alone).

## Amendment (ADR-0045, Omarchy capabilities, 2026-11-04, Proposed)
ADR-0045 (OC-0.4, OC-0.7) adds system changes to Settings, all on this ADR's path where a system service has its own polkit
action: Settings sends the D-Bus call (`Backend::busAct`, refused in a dev session, one per tag while it may wait for a
password, its values checked in `systembus.cpp` `validAction` before any call), the service asks polkit, and Grassfield's
polkit sheet asks the password. Calls that change something now allow interactive authorization (`QtBusCaller`, the D-Bus
flag systemd reads before it asks the agent); reads never do. The new actions, and the polkit actions they use:
- **Remote Login** (`ssh.enable`): systemd's `EnableUnitFiles` + `StartUnit` or `StopUnit` + `DisableUnitFiles` on
  `sshd.service` only (the unit name is a constant of `systembus.cpp`, never the page's):
  `org.freedesktop.systemd1.manage-unit-files` and `org.freedesktop.systemd1.manage-units`. No `Reload` (`reload-daemon`
  would be a third request): the state is the unit file's, read from the disk (`ListUnitFilesByPatterns`).
- **Disk Encryption > Change Password…** (`disk.passphrase`): UDisks2's `org.freedesktop.UDisks2.Encrypted.ChangePassphrase`
  on the LUKS device under the root file system, found by Settings itself in UDisks2's objects (never named by the page):
  `org.freedesktop.udisks2.encrypted-change-passphrase-system` (UDisks2 also needs the current passphrase). The two
  passphrases (1 to 512 characters, no NUL) are never logged nor part of an answer.
- **Fingerprint** (`fprint.enroll`, `fprint.delete`): fprintd's `Claim` (the caller's own user), `EnrollStart` with each
  `EnrollStatus` passed to the page, `EnrollStop`, `Release`, and `DeleteEnrolledFinger`: `net.reactivated.fprint.device.enroll`
  (and `.verify` for reading the enrolled fingers, which the active session holds without a password).
What no service exposes (a package install, PAM edits, the FIDO2 registration, the hibernation swap file, initramfs and boot
entry, OpenSSH's first setup, voxtype) is never a Settings action: it is Omarchy's own script, started as one exact argument
vector of `systemguard.cpp` `isLaunch` (`omarchy-launch-floating-terminal-with-presentation <command>`, the path of Software
Update's Update in Terminal…) behind a sheet that says why, and Omarchy's terminal asks for the password itself. Grassfield
ships no polkit rule or policy for any of this.
