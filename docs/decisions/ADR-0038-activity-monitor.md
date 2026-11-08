# ADR-0038: Activity Monitor: a native app that shows the computer's processes and stops the user's own, on macOS 27's model with the best of Windows 11's Task Manager
Status: Accepted as built (owner ratification of 2026-11-08: every Proposed ADR accepted at once for 1.0). Before:
Proposed (cloud session, owner brief 2026-10-28, step 0; docs only, no code before the opus PASS). The owner
answered AQ1 to AQ7 on 2026-10-28 (AskUserQuestion), recorded in "Owner decisions". Every other choice follows the owner's
rule of 2026-10-28 ("the closest to macOS 27, with no technical step for the end user") and is recorded in "Decisions taken
under the owner's rule" (AD1 to AD52). Revised after the integrator's opus review of e3882de (FAIL: five MAJORs and eight
MINORs, all answered in "Review history"; each changed place says "review of e3882de"). Step 0 merged (pull request #37, opus
PASS on f950042). Step 1 (the sampler, no window, with its cost gate) is built and measured in its own pull request
(`docs/audits/activity-2026-10-28/step1.md`); the integrator's notes on the merge of step 0 are answered there and marked
"step 1" here. Revised after the integrator's opus review of 949fc98 (FAIL: four MAJORs, five MINORs, five surviving
mutants), answered in "Review history"; each changed place says "review of 949fc98". Revised again after the re-review of
f68789c (FAIL: one MAJOR, four MINORs), each changed place saying "review of f68789c". Step 1 merged (pull request #40,
opus PASS on 19f5d4c, main 9bb1422); its follow-ups are answered in "Review history", the CPU tab's headroom first. Step 2
is split into 2a to 2d ("Delivery order"); 2a, the window and its table, is built in its own pull request
(`docs/audits/activity-2026-10-28/step2a.md`; AD34 to AD36), merged (pull request #47, main b345334); 2b, the summaries,
graphs and grouped views, in its own (`docs/audits/activity-2026-10-28/step2b.md`; AD37 to AD41), merged (pull request
#53, main 0a2b52b); 2c, Quit, Force Quit and Send Signal, in its own (`docs/audits/activity-2026-10-28/step2c.md`; AD42
to AD44), merged (pull request #63, main 317cce3); 2d, Inspect, in its own (`docs/audits/activity-2026-10-28/step2d.md`;
AD45 to AD47). From step 2d the owner asked for one pull request for the rest of the chantier (2026-10-31: steps 2d, 3, 4
and 5 together, the integrator reviewing them once); steps 3, 4 and 5 are built there (`step3-5.md`; AD48 to AD57;
Keep CPU Windows on Top not built, AD57).
· Date: 2026-10-28 ·
Decider: owner
(AQ1 to AQ7), integrator (merge after the opus review) · Number: 0038 (0033 to 0037 are merged; 0038 is free on main
be7eb7c and on the open pull requests #33 and #35)

The app is named "Activity Monitor" / « Moniteur d'activité » (owner, AQ1; macOS's own app name in both languages:
**needs legal review**, element E38 and question 14 of `docs/legal/visual-review.md`, added in this pull request). The
precedent named in AQ1 holds only in part (review of e3882de): L1 keeps the English "Preview" with the French name
« Visionneuse » as shipped (`apps/preview/org.grassfield.Preview.desktop:4`; the 2026-10-27 question had named « Aperçu » by
mistake, corrected on main in b6763c2), so « Moniteur d'activité » would be the first French app name shipped as macOS's. Internal identifiers stay
neutral (master-prompt §14): the folder `apps/activity`, the binary `grassfield-activity`, the app id and desktop file
`org.grassfield.Activity`, the QML module and the code say "activity". In this ADR "the app" means it.

Parity with macOS 27 and Windows 11, row by row: `docs/audits/activity-2026-10-28/parity.md`. Behaviour, keyboard,
accessibility, refusals and limits: `docs/specs/activity.md`. Evidence: the probes A0 to A10 of
`docs/audits/activity-2026-10-28/activity-probes.sh`, run in a throwaway `archlinux:base` container, output in
`probes-output.txt` next to it. Legal points are marked "needs legal review" (master-prompt §14); none is a conclusion.

## Context

### The owner's brief (2026-10-28)
- A native app in `apps/` that takes the best of Windows 11's Task Manager with the design and model of macOS 27's Activity
  Monitor.
- From macOS: the window with the CPU, Memory, Energy, Disk and Network tabs; the summary at the bottom of the window,
  memory pressure included; Quit and Force Quit; Inspect a process; the Dock icon that can show a graph.
- From Windows 11: processes grouped (Apps, Background processes); the Performance graphs (CPU per core, GPU, memory, disk,
  network); the app history; efficiency mode; End task from an app's menu in the Dock (Windows: the taskbar); a choice of
  columns; search.
- Constraints:
  - no root code: the app sees and stops only the user's own processes; no new polkit action without the owner's decision;
  - `/proc` and `/sys` read directly, no new dependency;
  - the data of Force Quit and of "Not Responding" (`shell/services/NotResponding*`) reused, never duplicated;
  - the apps that open at login stay in Settings > General > Login Items: a link, not a copy;
  - tokens only, plain text, French translations;
  - the app's own CPU and memory cost measured: a monitor must not be noticed.
- Step 0 (this pull request): this ADR, the spec, the parity matrix and the owner's questions. Then one pull request per step;
  the integrator reviews (opus), runs the nested passes and merges.

### What Grassfield has today
- **Force Quit** (`shell/overlay/ForceQuitPanel.qml`, SUPER+ALT+ESCAPE, `config/hypr/grassfield/bindings.lua:151`): the
  windows by app, "(Not Responding)" in `colors.danger`, a confirmation, then `kill -9` of the window's client pid through
  `Power.run("forcequit")` (`shell/services/Power.qml`), which refuses a pid that no longer owns a window of the chosen class.
- **"Not Responding"** (ADR-0035 D-3): Hyprland runs `hyprland-dialog` when an app misses its pings; Grassfield's stand-in
  reports the pid to `NotResponding.qml` (IPC `anr report`), which keeps one mark per stand-in while it lives. The marks
  are shell state; `anr status` is a dev hook (it returns window titles).
- **The Dock menu** (`shell/overlay/DockMenu.qml`): "Application Not Responding" first for a hung app, then Force Quit in
  place of Quit for its hung processes; Option turns Quit into Force Quit for all its processes (ADR-0035 decision 3-5).
  The Dock already draws an app's progress bar and badge on its tile (ADR-0018, `shell/dock/Dock.qml` `tile.progress`).
- **App launches** (`shell/services/AppLaunch.js:45`, `Apps.scoped`): every app the shell starts runs in its own systemd
  scope through `uwsm-app --`, in `app-graphical.slice` (A7: `app-<first XDG_CURRENT_DESKTOP>-<command basename>-<8 hex>.scope`,
  so `app-Hyprland-firefox-1a2b3c4d.scope` in the Grassfield session, ADR-0001).
- **Login Items** (`apps/settings/qml/LoginItemsPage.qml`, General > Login Items): the XDG autostart entries with switches
  and the user's own systemd services ("Allow in the Background"). Settings opens on a pane with `--section=login`
  (`shell/services/SettingsApp.qml:21`).
- **App to shell**: an app calls the running shell with `qs ipc -p <shell dir> call …` (`apps/runmode.h` `shellIpcArgs`);
  the IPC surface is the table of `docs/specs/security.md` "IPC surface", checked by `tests/security/ipc_inventory.sh`.
- **Omarchy 4.0.4** (data): its "Activity" is btop in a terminal (SUPER+CTRL+T, `default/hypr/bindings/utilities.lua:103`);
  the Grassfield session does not load Omarchy's bindings. Omarchy swaps to zram (`zram-size = ram`, zstd,
  `default/systemd/zram-generator.conf.d/90-omarchy.conf`) and turns zswap off (`etc/tmpfiles.d/omarchy-zswap.conf`).

### What the kernel lets a user read and do (probes, kernel 6.18.44; `probes-output.txt`)
| What | Own process | Another user's process, or an own non-dumpable one | Cost (A10 in C, A8 for `smaps_rollup`; step 1) |
|---|---|---|---|
| `/proc/<pid>/stat`, `statm`, `status`, `cmdline`, `comm`, `cgroup`, `sched`, `limits`, `task/` | read (A1) | read (A1) | `stat` 2.4–3.9 µs, `status` 6.7–7.6 µs, `statm` 0.7 µs per process; a thread's `status` 9.6–11.1 µs |
| `/proc/<pid>/io` (bytes read and written by the storage layer) | read | refused (EACCES) | 3.3–4.9 µs |
| `/proc/<pid>/smaps_rollup` (proportional and private memory) | read | refused | **6.6 ms** for a 1 GiB process (A8) |
| `/proc/<pid>/fd/`, `fdinfo/` (open files, sockets, GPU clients), `exe`, `cwd`, `maps`, `environ` | read | refused | a readlink per descriptor, 2.1–2.4 µs each |
| signal (`kill`, `pidfd_send_signal`) | allowed (A2) | refused (EPERM) | — |
| a pidfd on a process that ended | `pidfd_send_signal` fails with ESRCH: a pid reused since cannot be hit (A2) | — | — |
| a `/proc/<pid>` directory descriptor | names one process for good: `stat` read through it with `openat`, and the same descriptor signalled with `pidfd_send_signal`; once the process ended both fail with ESRCH (A2) | — | — |
| `sched_setaffinity` | allowed, and back to every processor allowed (A9) | — | — |
| `perf_event_open` on own processes | allowed for user space: `kernel.perf_event_paranoid` is 2 (A9) | — | — |
| raise the nice value | allowed; **lowering it back is refused** (EACCES) under RLIMIT_NICE 0 (A3) | — | — |
| `SCHED_IDLE` | allowed; **back to `SCHED_OTHER` refused** (A3) | — | — |
| I/O class idle (`ioprio_set`) | allowed, and back to best-effort allowed (A3) | — | — |
| `/proc/stat`, `meminfo`, `vmstat`, `loadavg`, `uptime`, `diskstats`, `net/dev`, `net/tcp`, `net/udp`, `swaps`, `cpuinfo`, `pressure/{cpu,memory,io}`, `/sys/block/*/stat`, `/sys/block/zram0/mm_stat` | read (A4) | (system-wide files) | — |
| TCP bytes and segments per socket (`NETLINK_SOCK_DIAG` with `tcp_info`, what `ss -ti` reads) | read, with the owning process found through the own `/proc/<pid>/fd` (A5) | the socket's counters are visible, its process is not | one netlink dump |
| UDP bytes per socket | the kernel's answer has no byte counters (A5) | — | — |

The CPU cost of one sample, measured in C (A10, `sampcost.c`, kept descriptors re-read with `pread`, median of 101 samples,
two runs, this cloud machine's CPU) with 611 processes (406 own with 4 threads and about 17 descriptors each, 205 of
another user) and 220 TCP sockets: the `/proc` listing 0.64–0.68 ms; `stat` 2.4–3.9 µs per process; `status` 6.7–7.6 µs;
`statm` 0.7 µs; `io` 3.3–4.9 µs per own process; a thread's `status` 9.6–11.1 µs (1 605 threads: 15.5–17.9 ms); a
descriptor's `readlink` 2.1–2.4 µs (6 850 descriptors: 14.3–16.3 ms); the TCP `sock_diag` dump 2.3–2.4 µs per socket; every
system file together 0.04 ms. Reading everything at every sample would cost 38–44 ms.

### What the session gives (A6, A7; not product code)
- systemd 262 delegates `pids memory cpu` to the user manager (`user@.service`: `Delegate=pids memory cpu`), not `io`.
- When a unit stops, systemd 262 logs "Consumed %s CPU time" with `MESSAGE_ID=ae8f7b866b0347b9af31fe1c80b127c0` and
  structured fields (`CPU_USAGE_NSEC=`, `IO_METRIC_*`, `IP_METRIC_*`; the I/O and IP fields need accounting the user manager
  does not have).
- uwsm 0.27.1 names an app's scope as above; `UWSM_APP_UNIT_TYPE` may make it a service instead
  (`app-<desktop>-<name>@<8 hex>.service`). `<name>` is the desktop id without `.desktop` when the app was started by its
  desktop entry (`uwsm app -- org.mozilla.firefox.desktop`, `main.py:3421`), else the command's basename; both are escaped
  by `simple_systemd_escape`, so a "-" becomes `\x2d` (`grassfield-settings` → `grassfield\x2dsettings`, A7).
- uwsm binds the graphical session to its login process with `wayland-session-bindpid@<pid>.service` in `background.slice`,
  `OnSuccess=` and `OnFailure=wayland-session-shutdown.target`: when it ends, the session ends (A7). The login process itself
  runs in the login session's scope, `session-<n>.scope` under `user-<uid>.slice`, outside the user manager.
- The resource record carries `MEMORY_PEAK` and `MEMORY_SWAP_PEAK` too (A6; the first run's "absent" was the probe's own
  search for "MEMORY_PEAK=", review of e3882de).

### Not verified here (read-only checks on the owner's machine at the step that needs them; listed in the spec)
- GPU per process from `/proc/<pid>/fdinfo` (`drm-engine-*`, `drm-memory-*`) on the owner's i915 (this cloud machine has no
  GPU).
- RLIMIT_NICE in the owner's session; the `cpu` controller in `app-graphical.slice`; the user journal holding the resource
  records of app scopes; Hyprland's client list carrying `inhibitingIdle`; UPower's history on the laptop.
- A10's costs on the reference machine (i5-10400H): step 1 runs the same fixture there (d). Step 1 gathers this list in
  one read-only script for the owner, `docs/audits/activity-2026-10-28/owner-checks.sh` (nothing is changed, nothing needs
  root); its output is recorded in `step1.md` when the owner sends it.
- Whether systemd turns the `cpu` controller off again in `app.slice` once no unit sets a weight (step 4, g).

## Decision

### Overview
One Qt 6 / QML app on Grassfield.Ui, `apps/activity`, packaged in `grassfield-desktop` (like Settings, Files and Preview:
it has no root part). No daemon, no service, no root code, no polkit action, no new dependency (Qt Core, Gui, Qml, Quick
and DBus, which Settings and the Store already use; `journalctl` and `systemd` are part of the base system). A C++ sampler
reads `/proc` and `/sys` on a thread of its own; QML draws the window with tokens only. The shell gains two small links:
it publishes its windows and "Not Responding" marks for the app (a projection, not a copy of the logic), and it draws the
app's Dock tile graph from numbers the app writes.

### a. The window (macOS 27's structure, ADR-0024 material)
- One main window: the unified toolbar (ADR-0015) with the traffic lights, the title and the current view as subtitle
  ("All Processes"), the Stop button (Quit Process), the Info button (Inspect), the action menu (…), a segmented control
  CPU / Memory / Energy / Disk / Network, and the search field. Under it, the process table; at the bottom, the tab's summary
  (figures and a graph). The window is opaque (§5.5); the toolbar's scroll-edge glass follows ADR-0024 phase 3.
- Menus: Activity Monitor, File, Edit (Copy, Select All, Find), View (Columns, Dock Icon, Update Frequency, the process
  filters, Clear CPU History, Inspect Process, Quit Process, Send Signal to Process…, Efficiency Mode), Window (Activity
  Monitor, CPU Usage, CPU History, GPU History, Performance, App History, Login Items…), Help. Exported to the menu bar
  through the apps' T1 path (`apps/globalmenu.h`).
- Small windows of the Window menu: CPU Usage (one bar per logical processor), CPU History (one graph per logical
  processor), GPU History (one graph per GPU) as on macOS; **Performance** and **App History** come from Windows 11 (g).

### b. What is measured, and from where
Formulas and edge cases are the spec's (AM20 to AM49); the sources are:
| Tab | Columns (default first) | Source |
|---|---|---|
| CPU | % CPU, CPU Time, Threads, % GPU, GPU Time, PID, User; optional Wake Ups, Open Files, Status, Command, Kind | `stat` (utime + stime of the whole thread group, `num_threads`), `fdinfo` of the DRM descriptors, `task/*/status` (voluntary switches) |
| Memory | Memory, Threads, PID, User; optional Real Memory, Private Memory, Shared Memory, Compressed Memory, Peak Memory, Page Ins | `status` (`RssAnon`, `RssFile`, `RssShmem`, `VmSwap`, `VmHWM`), `stat` (`majflt`) |
| Energy | Energy Impact (AQ3), Preventing Sleep, PID, User; optional Average Energy Impact, Wake Ups, % GPU | the CPU and GPU terms above, logind's inhibitors (system bus), the shell's idle-inhibit flag |
| Disk | Bytes Written, Bytes Read, PID, User; optional Read/s, Written/s | `io` (`read_bytes`, `write_bytes`) |
| Network | Sent Bytes, Rcvd Bytes, Sent Packets, Rcvd Packets, all headed "(TCP)" (AQ2), PID, User | `NETLINK_SOCK_DIAG` (`tcpi_bytes_acked`, `tcpi_bytes_received`, `tcpi_segs_out`, `tcpi_segs_in`) and the own `fd/` |
| Summaries | CPU: System, User, Idle, CPU Load graph, Threads, Processes. Memory: Memory Pressure graph, Physical Memory, Memory Used (App Memory, Wired Memory, Compressed), Cached Files, Swap Used. Energy: Energy Impact graph, and on a laptop Remaining charge, Time remaining or Time until full, Time on battery or on AC, Battery (Last 12 hours). Disk: Reads in, Writes out, Reads in/sec, Writes out/sec, Data read, Data written, Data read/sec, Data written/sec, graph IO or Data. Network: Packets in, Packets out, Packets in/sec, Packets out/sec, Data received, Data sent, Data received/sec, Data sent/sec, graph Packets or Data | `/proc/stat`, `loadavg`, `meminfo`, `pressure/memory`, `swaps`, `/sys/block/zram*/mm_stat`, `diskstats` (whole physical disks), `net/dev` (every interface but `lo`), UPower (system bus) |
macOS meanings are kept where Linux has them: "User" is the CPU of the user's own processes and "System" everything else
that is not idle (AD5), "Compressed" is zram's RAM and "Swap Used" the swap on disk (AD7). A figure Linux cannot give is
not invented (R11): it is absent, or "—" for a process that refuses the read.

### c. Which processes (AQ4: other users' processes shown read-only, as macOS)
- The table lists every process the kernel shows in `/proc`, as macOS's "All Processes": the user's own, those of system
  accounts (root and the services' users, uid below `UID_MIN` of `/etc/login.defs`, 1000 on Arch) and those of other people
  (uid from `UID_MIN`). Kernel threads are not listed one by one: one row "Kernel" (user root, no pid) sums their CPU,
  as macOS's `kernel_task` (AD25).
- View > My Processes, System Processes and Other User Processes filter by owner, as macOS. A User column (default on every
  tab, macOS) names the owner. The owner is the real uid of `status`; the `/proc/<pid>` directory's owner (the effective uid,
  and root for a non-dumpable process) serves as a shortcut on the tabs that do not read `status`, and `status` is read
  where that shortcut says root and `stat` does not say kernel thread (d). The directory's owner is read when a process
  is first seen, after an exec and in its turn, a tenth of the processes per sample (AD33, review of 949fc98).
- **Read-only for the others.** Their rows are filled from `stat`, `statm` and `status` only (% CPU, CPU Time, Threads,
  Memory, User, PID); their `cgroup` is not read either (review of 949fc98); disk, network, GPU, open files and Inspect's detailed tabs show "—" for them. Their name is the kernel's short name
  (`stat` field 2), never `cmdline`: a process can rewrite its `argv[0]` into a title (an SSH server's "sshd: bob@pts/0"),
  so other people's command lines and titles are never read or shown (AD25, review of e3882de).
- **Actions only on the user's own processes** (the kernel enforces it, A2; no polkit action, the brief): Quit, Force Quit,
  Send Signal and Efficiency Mode are disabled on another owner's row with the reason ("You can only quit your own
  processes."). macOS asks for an administrator there; Grassfield does not (a known limitation).
- The summaries and graphs are system-wide (`/proc/stat`, `meminfo`, …) as before. With `/proc` mounted `hidepid`, other
  users' processes are invisible and only the user's are listed.

### d. Sampling and its cost (rewritten after the review of e3882de: one budget per tab, from A10's measures)
- One sampler thread, woken by one timer at the update frequency: View > Update Frequency, Very Often (1 sec), Often (2 sec),
  Normally (5 sec), **Normally by default** (Apple's guide for macOS 27: "every 5 seconds" by default).
- What one sample reads (AD10), kept descriptors re-read with `pread` at offset 0 while the process lives (A10: 9.8–11.0 µs
  for `stat` and `status` against 14.4–15.9 µs with an open and a close each):
  - every tab: the `/proc` listing, `stat` of every process, the system files of the tab's summary; the directory's owner
    (`fstatat`) only for a process seen for the first time, after an exec, and in its turn (AD33);
  - Memory: `statm` of every process, and `status` of one fifth of them in turn for `VmSwap` and `VmHWM`, which `statm`
    lacks, every new process at once (AD32, review of 949fc98; step 0 read `status` of every process at every sample);
  - Disk: `io` of the user's processes, kept open and re-read with `pread` as `stat` (the kernel checks the access at each
    read);
  - Energy: `io` of the user's processes and, for the Wake Ups term, the threads' `status` of one fifth of the user's
    processes in turn (each process every fifth sample; its rate is taken over those five samples);
  - Network: one TCP `sock_diag` dump, and the descriptor lists (`fd/`) of one tenth of the user's processes in turn, each new
    process at its first sample; a socket counted once its process is known (its counters are cumulative, so nothing is lost
    while the socket lives); the dump leaves out listeners, TIME_WAIT and closed sockets, which carry no bytes or no owner
    (review of f68789c: the dump is most of this tab's cost);
  - the GPU columns: the descriptor lists in the same turn (one tenth per sample, new processes at once), then each sample
    only the `fdinfo` of one descriptor per client: the first read after a turn reads every DRM descriptor found and keeps
    the first of each (`drm-pdev`, `drm-client-id`), and one that fails or names another client brings the full read back
    at once (the integrator's AM-P2 run of f68789c: Mesa's pipe loader and iris's buffer manager each duplicate their DRM
    descriptor, a duplicate is the same client, and each `fdinfo` read has the driver go over the client's objects);
  - `smaps_rollup` never in the table (6.6 ms for a 1 GiB process, A8), only in Inspect.
  - The turns (a fifth, a tenth) go by each process's order of arrival, not by its pid, so each sample reads as many lists
    whatever the pids are (review of 949fc98). An own process's `cgroup` is read when it is first seen and again in its
    first two descriptor turns (a launcher moves a process into its unit before it runs it), then no more.
  - An exec is seen from `stat` alone (review of 949fc98): for the user's own processes, whose code addresses `stat` gives
    (fields 26 and 27), a change of either address, so a new image even under the same name; a new name with the same
    addresses is a `prctl(PR_SET_NAME)` rename, and the process keeps its name and command as on macOS (review of
    f68789c). For other owners, whose addresses read 0, a new name (field 2) is all there is. The process is then named
    again (AM17) from its command line and its `exe` link. Known limit: an exec into the same non-position-independent
    program (or with address randomization turned off) maps it at the same addresses and is not seen; its Command keeps the
    old arguments until the process ends.
  - Nothing a sample reads is cleared or copied first (step 0's code cleared a 64 KiB buffer at every read, most of a
    sample's cost on the reference machine; review of 949fc98); a per-process file is read in one call.
- Kept descriptors (step 1, the integrator's note on the merge of step 0): `stat` of every process, `statm` and `status` on
  the Memory tab, `io` of the user's processes on the Disk and Energy tabs, so up to about 2 400 for the reference fixture,
  over the session's soft `RLIMIT_NOFILE` of 1 024. The app
  raises its soft limit at start to the hard limit, at most 16 384 (`raiseFileLimit`; an unprivileged process may raise its
  soft limit up to its hard one), and keeps at most that soft limit less 256 descriptors open, the 256 left for everything
  else it opens (Qt, D-Bus, the window, the descriptor lists it reads). Past that budget a file is opened, read and closed
  each time: slower, never an error. A kept descriptor whose `pread` fails is closed (its process ended), and every kept
  descriptor of a process is closed when the process leaves the listing or its start time changes (pid reuse). The
  session's hard limit is one of the owner's read-only checks (`owner-checks.sh`).
- The window hidden or minimized: no per-process sample. With a Dock graph (f), only the system file the graph needs, at the
  update frequency. Nothing else wakes the app.
- **Budget (AM-P1 to AM-P4, `tests/apps/activity_cost.sh`).** One sample's CPU time on the sampler's thread
  (`CLOCK_THREAD_CPUTIME_ID`) for the reference fixture of A10 (about 600 processes, 1 600 threads, 6 800 descriptors, 220
  TCP sockets): **each tab ≤ 1.3 × A10's step-1 plan** (A10 reading what the sampler reads), the worse of A10's two runs
  on the same fixture, before and after the product's (the integrator's decision on pull request #47, 2026-10-29; the
  reference machine's figures from its run at idle). **Disk's plan is A10's one pass** over the same files in the
  sampler's order (`step 1 Disk, in one pass`; the integrator's second decision, the same day): the summed plan adds parts
  each measured alone with warm caches, and no reader of those files meets it (the product reading them and parsing
  nothing was 1.25–1.41 × it here, the whole product within 0–10 % of that and about 1.17 × the one pass). Since step 2b
  **Disk's margin is 1.15**, not 1.3, and a run started at a load average of 2 or more does not count (the integrator's
  decision after #47's merge): a `stat` or `io` line identical to the process's last one is not parsed again. CPU, Memory,
  Energy and Network keep the summed plan (1.06–1.20 × on the reference machine). Until then the limits were A10's step-0 plan there plus about 30 %:
  CPU 17, Memory 25, Disk 17, Energy 40 and Network 45 ms (pull request #40), and before that, from the cloud machine,
  6, 10, 7, 13 and 7 ms. The whole app's CPU with the window visible on a tab: ≤ 0.5 % of one core at Normally (5
  sec) on every tab; at Very Often (1 sec) ≤ 1.5 % on CPU, Memory, Disk and Network and ≤ 2 % on Energy; ≤ 0.1 % minimized
  with a Dock graph at 5 s; PSS ≤ 120 MB after 10 minutes and < 5 MB of growth over an hour (AM-P1 to AM-P4 are step 2's
  gates, measured on the whole app; on the reference machine, 0.5 % of a core at 5 s is 25 ms a sample and 1.5 % at 1 s is
  15 ms, below some AM-P2 limits, so the integrator sets them again with step 2's measures). The app lists itself, as macOS
  does, so the user sees its cost too.
- **Step 1, measured** (`tests/apps/activity_cost.sh --model` on the product sampler, as an unprivileged user in a throwaway
  container on this cloud machine, 608 processes of which 404 own, 1 600 threads, 100 TCP connections; median of 101
  samples, then probe A10 on the same fixture in the same run): after the review of 949fc98, CPU 2.6–2.8 ms, Memory
  2.8–2.9, Energy 5.9–6.0, Disk 2.1, Network 3.2–3.4; against A10 0.9–1.1 × on CPU, Memory, Energy and Network and 0.7–0.8
  × on Disk (three runs; `docs/audits/activity-2026-10-28/step1.md`). Against A10 reading the same as the sampler (its
  "step 1" plan: owners a tenth per sample, `statm` and a fifth of `status`, `io` kept; review of f68789c), 1.1–1.2 × on
  CPU, Energy and Network and 1.3–1.4 × on Disk and Memory, whose reads cost least in the kernel: the rest is the sampler's
  parsing and its 368-byte rows. The reference machine's figures are the integrator's run of the same script at idle
  (the review of 949fc98 measured 1.6 to 2.3 × A10 there before these changes; the re-review of f68789c 0.73 to 1.10 ×). A10 itself
  now raises its soft `RLIMIT_NOFILE` as the app does: at 1 024 its kept `stat`, `status` and `statm` (three per process)
  used up the descriptors and its later phases opened nothing (no thread, no descriptor list, no socket read), so its
  figures came out too low; it prints the files it could not open.

### e. Quit, Force Quit and signals (no root; macOS sheet)
- The Stop button and View > Quit Process open macOS's sheet: "Are you sure you want to quit this process?", with Cancel,
  Force Quit and Quit (Quit is the default button).
- **Quit** is the safe one (macOS: "quits when it's safe to do so"): for a process with windows, the shell closes its windows
  (new IPC action `activity quit`, the same path as the Dock's Quit: the app can save or ask), never a signal; for a process
  without windows, `SIGTERM`. **Force Quit** is `SIGKILL`.
- **One process, from the check to the signal** (AD30, review of e3882de: checking the start time and then opening a pidfd
  left a gap in which the pid could be reused). When the sheet opens the app opens `/proc/<pid>` as a directory descriptor,
  reads `stat` through it (`openat`) and compares the start time (field 22) with the row's; the same descriptor is the one
  `pidfd_send_signal` gets (the kernel takes a `/proc/<pid>` descriptor as a pidfd). A descriptor names one process for
  good: once that process ended, the read and the signal fail with ESRCH (A2), so another process is never hit.
- View > Send Signal to Process…: macOS's sheet with a pop-up of the usual POSIX signals, then Send; the same descriptor path.
- The user's session processes (AD22: the compositor, the shell, the menu bridge, the user manager, the login session's
  scope and uwsm's session binding) can be quit, force quit or sent any signal only after a second sheet that says the
  session may end (spec AM54), and Stop (`SIGSTOP`) is refused for them outright: a stopped compositor or shell freezes the
  screen and the lock before sleep (review of e3882de).

### f. With the shell: Not Responding, windows, the Dock, Force Quit (AQ5, AQ6)
- **One folder per display** (AD29, review of e3882de: a nested session shares the real session's `$XDG_RUNTIME_DIR`, so one
  folder for both would let a nested test draw on the owner's Dock tile and delete the real session's projection). The
  shell and the app use `$XDG_RUNTIME_DIR/grassfield/activity-<display>/`, `<display>` being the last part of
  `WAYLAND_DISPLAY` with every character outside `[A-Za-z0-9._-]` replaced by "_", as the clipboard helper's folder
  (`shell/services/ClipboardLogic.js` `runtimeDir`). Folder 0700, files 0600, written to a temporary name then renamed. Each
  file names its writer by pid and start time; a reader ignores a file whose writer is not that process any more.
- **Projection, not duplication.** While a window with app id `org.grassfield.Activity` is open, the shell writes
  `windows.json` in that folder: `{"v":1,"writer":{"pid","start"},"windows":[{"pid","app","idleInhibit"}],
  "notResponding":[pid,…]}`, from `Compositor.knownWindows()` (Hyprland's list read again when a window opens or closes) and
  `NotResponding.marks`, coalesced over 250 ms, at most 256 windows. No title (the anr dev hook keeps titles private). The
  app watches the file (inotify through `QFileSystemWatcher`): no polling, no second "not responding" detector. The app shows
  "(Not Responding)" in red after the name (macOS) and "Not Responding" in the optional Status column (Windows). Without the
  shell (absent, crashed) the file is gone or stale: no row is marked and Quit of a process in an app scope is not offered
  (Force Quit still is).
- **IPC action `activity quit <pid>`** (class action, caller `grassfield-activity`; security.md table): the shell closes every
  window whose client pid is that pid, as the Dock's Quit; it answers `ok`, `no-windows` or `refused` and never kills.
  `tests/security/ipc_inventory.sh` only looks for real-session callers in the session's config and helpers today
  (`ipc_inventory.sh:850`): step 3 extends it to the apps' sources, so this caller is seen (review of e3882de).
- **Dock tile graph** (macOS View > Dock Icon: Show Application Icon, Show Network Usage, Show Disk Activity, Show CPU
  Usage, Show CPU History): the app writes `dock-tile.json` in the same folder at the update frequency
  (`{"v":1,"writer":{"pid","start"},"kind","samples":[…]}`, values 0 to 1 the app has scaled, at most 32 samples, at most 2
  KiB); the Dock draws it with tokens over the `org.grassfield.Activity` tile while that app runs (it reads no other path and
  no other app id: no app can draw on another app's tile). The image is never written by the app (no pixels to trust, no
  decode cost).
- **Force Quit panel and Dock menu (AQ5: End Task behind a setting).** The Force Quit panel is unchanged. A new switch in
  Settings > Desktop & Dock, "Show End Task in Dock menus" (fr « Afficher Fin de tâche dans les menus du Dock »), off by
  default as Windows' own (setting `dock.endTask` in `grassfield.json`), adds "End Task" (fr « Fin de tâche ») after Quit in
  the Dock menu of every running app. End Task is the Dock's existing Option + Force Quit (AD27): the same confirmation,
  then `Power.run("forcequit")` on every process of the app, nothing new in the kill path. The macOS items (Force Quit with
  Option, at once for a hung app) are unchanged.
- **Keyboard shortcut (AQ6): Ctrl+Shift+Esc** (Windows'), free in Grassfield's bindings. The binding runs
  `grassfield-launch-key activity` (`packaging/bin/grassfield-launch-key`, a new kind next to `settings` and `files`), which
  starts `org.grassfield.Activity.desktop` through `uwsm app` in its own scope, or brings the running app forward (AM1).

### g. From Windows 11 (in the Grassfield structure)
- **Processes, by Type** (View menu; Windows' "group by type"; AD26): Apps (the user's processes in `app-graphical.slice`
  units or that own a window, one group per unit, named and drawn with its desktop entry), Background Processes (the user's
  other services and processes), Session Processes (the user's session processes, AD22), System Processes (system accounts
  and the kernel), Other Users (only when another person's processes run). Groups expand to their processes; a group's row
  sums them. macOS 27's "Processes, by GPU" groups by GPU.
- **Performance** (Window menu): a sidebar of resources with a small graph each (CPU, Memory, each physical disk, each
  network interface, each GPU) and the selected one's large graph and details (Windows' Performance page in macOS 27's
  window structure). CPU: overall or one graph per logical processor; speed, cores, logical processors, caches, up time,
  processes, threads. Memory: in use, available, committed, cached, compressed, swap, composition bar. Disk: active time,
  read and write speed, average response time, capacity, SSD or HDD. Network: send and receive throughput, interface, kind,
  addresses. GPU: one graph per engine (render, video, copy) from the user's GPU clients, memory where the driver reports it.
- **App History** (Window menu): per app, CPU time, memory peak, number of launches and last use, over the last 12 hours
  (macOS's "Applications in last 12 hours" span), 7 days or 30 days, from systemd's own record of each app unit that
  stopped (the user journal, `journalctl --user`, read when the window opens) plus the live units' `cpu.stat`. Nothing can
  be deleted: the journal is the system's record and a user cannot remove entries from it, so Windows' "Delete usage history"
  is not offered rather than a button that would only hide them (AD31, review of e3882de). No collector runs in the
  background.
- **Efficiency Mode** (View menu, the action menu and the row's context menu; AD19, revised after the review of e3882de):
  the lowest CPU weight on the process's own app unit, through the systemd user manager on the session bus
  (`SetUnitProperties`, runtime only), turned off by the same call with the unset value: reversible, no root, unlike `nice`
  and `SCHED_IDLE` (A3).
  - Only the units uwsm names for each launch in `app-graphical.slice` (a random suffix: `…-<8 hex>.scope` or
    `…@<8 hex>.service`). The runtime drop-in systemd writes under `/run/user/<uid>/systemd/user.control/` then belongs
    to a name no later launch reuses, and it goes at logout. Long-lived user services are refused: their drop-in would
    outlive a restart.
  - It applies to the whole app (Windows applies it to a group too) and says so in a first-time sheet ("Don't ask
    again"). Unavailable, with the reason, for a process outside such a unit and for the session's own processes.
  - Side effect, recorded: the first weight set makes systemd enable the `cpu` controller in `app.slice` and
    `app-graphical.slice`. From then on, apps under contention share the processor app by app rather than thread by
    thread (the model GNOME's resource daemon uses), possibly until logout (step 4 checks whether systemd turns it off
    again). Nothing changes for an app while the processor is not contended.
  - Status column: "Efficiency Mode".
- **Columns** (View > Columns and the header's context menu), **search** (process name, app name, user, own command
  lines, PID), **Copy** of the selected rows as text, and the Status column.
- **Login Items…** (Window menu): opens Settings on General > Login Items (`grassfield-settings --section=login`). Nothing
  of it is copied into the app.

### h. Not built (the parity matrix gives each reason)
- **Sample Process, Run Spindump, Run System Diagnostics.** A user may sample their own processes' user space
  (`perf_event_paranoid` 2, A9), but sampling needs a stack unwinder and a symbolizer, new code with no need in this
  chantier (R5); macOS's Sample is a developer tool. Corrected after the review of e3882de, which found the earlier
  reason ("no unprivileged stack sampling") wrong.
- **The Cache tab** (no content cache). **App Nap and Graphics Card** (no Linux counterpart).
- **12 hr Power.** No 12-hour record exists without a background sampler; the Energy tab has an average since the app
  opened instead.
- **Windows' Users, Details and Services pages.** One user per session; Details is the main table; Settings has the user's
  services.
- **Run new task.** Search and Apps start apps.
- **Set priority.** One-way without root (A3).
- **Set affinity.** It can be undone without root (A9); it is left out as a technical setting macOS does not offer. The
  earlier reason was wrong (review of e3882de).
- **Others:** Create dump file, Search online, heat-map cells, Paused update speed, Delete usage history (g), and any
  action on another owner's process (no administrator path: no root code, no new polkit action).

### i. Security and privacy
- Nothing runs as root; no polkit action; nothing is sent anywhere. The kernel refuses every action on another user's
  process (A2).
- Other owners' processes are read-only and show only what `stat` and `status` give (A1). Their command lines and their
  rewritten process titles are never read (c, AD25).
- The user's own command lines are shown (what `ps` shows); environment variables are never read.
- Inspect (step 2d, AD45, AD46) reads one process through the `/proc/<pid>` descriptor AM51's check opened: a pid taken
  again is never read. Another owner's process gives its `stat`, `status` and threads' `status` only. For the user's own:
  `io`, `cgroup`, `cmdline`, `smaps_rollup`'s totals, the `exe` and `cwd` links and the descriptors' links, and its own
  network namespace's socket tables; never its environment, memory maps or memory. Every path and name shown is
  sanitized (AM17).
- One name on the session bus (AD34, step 2a): `org.grassfield.Activity` with one method, `Activate(token)`, which only
  brings the window forward; any process of the user could call it, as it could start the app. The token is kept only if
  it is a short printable string; nothing is read from the caller.
- Every process name and command line shown, the user's own included, has its control characters and bidirectional
  formatting characters removed before display (spec AM17), so a process cannot reorder or hide text in the table.
- The projection holds pids and app ids (any local process of the user reads `hyprctl -j clients` already, ADR-0035
  decision 3-14); the Dock tile file holds numbers. Both live in the display's 0700 runtime folder (AD29) and go when their
  writer stops.
- Dev sessions (ADR-0019): the app runs in the owner's account and sees the owner's real processes. In a dev session every
  action (signals, Quit, Efficiency Mode) is refused for a process that does not descend from a dev root (AD42: a pid
  record named by `GRASSFIELD_ACTIVITY_DEV_ROOTS`, a test fixture's; none named, everything is refused), with a "dev
  guard" journal line (as Settings' guard); efficiency mode is refused for every unit not named by a test. The nested session's runtime folder is its own display's (AD29).

### j. Files (rows added to ADR-0020 in the step that writes them)
- `activity.json` (state, version 1, the app only): window frames, tab, view, columns and sort per tab, update frequency,
  Dock icon, Efficiency Mode's "Don't ask again", App History's period. Step 2a writes the window's size (Wayland places
  windows: no position), the tab, the view, the update frequency, and per tab the columns, their widths and the sort; its
  ADR-0020 row is added there; step 2b adds what the Disk and Network graphs show (`diskGraph` "io" or "data",
  `networkGraph` "packets" or "data"); the later keys come with their steps.
- `activity-<display>/windows.json` and `activity-<display>/dock-tile.json` (runtime, 0600): above; removed when their writer
  stops, and ignored when stale.

## Owner decisions (asked 2026-10-28 with AskUserQuestion; each option with its pros and cons)

**AQ1. The app's name (needs legal review).**
| Option | For | Against |
|---|---|---|
| A. « Moniteur d'activité » / "Activity Monitor" | the macOS name, which users look for; the same footing as "Preview" / « Aperçu », kept by the owner (L1) [as asked; Preview ships « Visionneuse », so the precedent holds for the English name only: see the header, review of e3882de] | Apple's app name: trade-dress risk on the list (§14, docs/legal/visual-review.md) |
| B. « Activité » / "Activity" | short, close to macOS, Omarchy already calls btop "Activity" | further from macOS; collides in words with Omarchy's btop entry if both are shown |
| C. « Moniteur système » / "System Monitor" | the generic Linux name (GNOME, KDE), lowest resemblance | not macOS; two different apps on Linux already carry it |
| D. « Gestionnaire d'activité Grassfield » / "Grassfield Activity" | own name, like "Grassfield Store" | long in the Dock and the menu bar |
Answer: A (see "Answers").

**AQ2. Network use per process** (no root).
| Option | For | Against |
|---|---|---|
| A. TCP only, labelled (Sent Bytes and Rcvd Bytes headed "(TCP)", a line under the table: "UDP traffic, such as some video, is counted only in the totals") | real per-process numbers without root (A5); the culprit of a download is found | UDP (QUIC) is missing; a connection that opens and closes between two samples is missed; counts start when the app opens |
| B. No per-process network: the tab shows the system totals and graph only | nothing partial on screen | the Network tab's table is empty of network data (PID, name only) |
| C. A root helper (eBPF or packet capture) | complete numbers | contradicts the brief (no root code, no new polkit action) |

**AQ3. Energy per process** (no root).
| Option | For | Against |
|---|---|---|
| A. Energy Impact as macOS: a relative index without unit, computed from CPU, wake-ups, GPU and disk; Preventing Sleep from logind and the shell; battery figures and the 12-hour battery graph from UPower | macOS's own Energy Impact is a computed estimate too ("lower is better"); real inputs | Grassfield's weights are its own, calibrated on the owner's laptop; a desktop without battery shows the index and Preventing Sleep only |
| B. No index: the Energy tab shows CPU, wake-ups, Preventing Sleep and the battery | no model to calibrate | not the macOS tab; nothing ranks the apps by energy |
| C. Measured watts per process (RAPL, powertop) | measured | RAPL counters are root-only since 2020; a root helper is excluded |

**AQ4. Other users' processes** (root's services, other accounts).
| Option | For | Against |
|---|---|---|
| A. Hidden, as the brief says: only the user's processes; the totals stay system-wide | the brief; nothing to explain about rows the user cannot act on | the per-process CPU does not add up to "System" (the difference is root's and the kernel's work) |
| B. Shown read-only, as macOS's "All Processes" (View > My Processes, System Processes, Other User Processes): name, CPU, memory, user; actions greyed | closest to macOS; the user sees which service eats the CPU | reading other accounts' command lines; disk, network, GPU and Inspect show "—" for them (A1); contradicts the brief |
| C. One aggregated row "Other Users and System" | the totals add up; no foreign details | a row that cannot be expanded or acted on |

**AQ5. The Dock and Force Quit.**
| Option | For | Against |
|---|---|---|
| A. macOS model only: the Dock tile graph; the Dock menu unchanged (Force Quit with Option, or at once for a hung app); the Force Quit panel unchanged | macOS 27 exactly; no new item | Windows' End task is not added |
| B. A + Windows' "End Task" in every running app's Dock menu, behind a switch in Settings > Desktop & Dock, off by default | Windows' feature for those who want it, invisible otherwise | one more setting; End Task is Force Quit under another name |
| C. A + an "Activity Monitor…" button in the Force Quit panel (bottom left) | a path from the panel to the details, as Windows' "More details" | not on macOS |
| D. B and C | both additions | both costs |

**AQ6. Keyboard shortcut to open the app.**
| Option | For | Against |
|---|---|---|
| A. Ctrl+Shift+Esc (Windows) | known by every Windows user; free in Grassfield's bindings; apps rarely use it | not a macOS shortcut (macOS has none for Activity Monitor) |
| B. None (macOS): Search, Apps and the Dock open it | macOS exactly | slower to reach when something hangs |
| C. Super+Shift+Esc (next to Force Quit, Super+Alt+Esc) | the Grassfield (Command) family | nobody knows it yet |
| D. Super+Ctrl+T (Omarchy's "Activity") | Omarchy users' habit | Omarchy's key for btop; unrelated to Escape and Force Quit |

**AQ7. The order of the steps** (each one pull request, reviewed and merged before the next).
| Option | For | Against |
|---|---|---|
| A. macOS first: 1 sampler (no window) with its cost gate; 2 the window, its five tabs, Quit and Force Quit, Inspect; 3 the shell links (Not Responding, Quit through the shell, Dock graph, AQ5, AQ6); 4 Windows' additions (by Type, Performance, Efficiency Mode, App History, Login Items link); 5 the small windows and the finish (F1, A2, cost re-measured) | the cost is proven before any UI; a usable app at step 2 | the Windows features come last |
| B. Shell links early: 1 sampler; 2 the shell links and the Dock graph; 3 the window; 4 Windows; 5 finish | Not Responding and End Task reach the Dock sooner | the Dock graph before the app the user sees |
| C. Windows first: 1 sampler; 2 the window with Performance and by Type; 3 macOS's tabs; 4 shell; 5 finish | the Windows graphs early | the macOS model, the owner's rule, comes late |

### Answers (2026-10-28, AskUserQuestion; the options as asked in French, in the order above)
| Question | Answer | Consequence |
|---|---|---|
| AQ1 name | « Moniteur d'activité » (Recommandé) → A | "Activity Monitor" / « Moniteur d'activité »; **needs legal review** (E38 and question 14 of the visual review, added in this pull request). The option's "same footing as Preview / Aperçu" holds for the English name only: L1 keeps Preview's shipped French name « Visionneuse » (main b6763c2; review of e3882de; the owner is told in the reply to the review). **Confirmed again by the owner on 2026-10-28** with the corrected precedent in view (relayed by the integrator on pull request #40): the name stays in both languages, at the owner's risk; it still needs legal review (visual review section 7) |
| AQ2 network per process | « TCP seulement, étiqueté » (Recommandé) → A | AM43: the four columns headed "(TCP)" and the line under the table |
| AQ3 energy per process | « Indice « Impact énergétique » » (Recommandé) → A | AM36 to AM39; weights calibrated by an owner L2 run on the laptop |
| AQ4 other users' processes | « Visibles en lecture seule » → **B** (not the recommended A) | c above, AD25, AD26; the brief's "sees only the user's processes" is amended by the owner for seeing; stopping stays the user's own processes only |
| AQ5 the Dock and Force Quit | « « Fin de tâche », réglage » (Recommandé) → B | f above, AD27; Settings > Desktop & Dock gains the switch at step 3 |
| AQ6 shortcut | « Ctrl+Maj+Échap » (Recommandé) → A | f above, AD28 |
| AQ7 order | « macOS d'abord » (Recommandé) → A | "Delivery order" |

## Decisions taken under the owner's rule (2026-10-28: the closest to macOS 27, no technical step for the end user)
- **AD1. One app, no daemon.** The app samples only while it runs; App History reads systemd's records rather than a
  collector of ours (R5, §5.8).
- **AD2. Package.** `grassfield-desktop` (no root part, unlike `grassfield-store`); desktop entry `org.grassfield.Activity`,
  Categories `System;Monitor;`; a Grassfield icon of its own (branding, CC-BY-SA-4.0, L2), never Apple's art.
- **AD3. Default update frequency: Normally (5 sec)**, Apple's default; Very Often (1 sec) and Often (2 sec) offered. No
  "Paused" (Windows).
- **AD4. % CPU is a share of one core** (macOS; can exceed 100 % for a process with several busy threads), not of the whole
  machine (Windows).
- **AD5. System and User as macOS means them:** User = the CPU of the user's processes (the sum of their shares), System =
  every other non-idle CPU (`/proc/stat`), Idle = the rest. A process that ended between two samples moves its last slice to
  System (a known limitation).
- **AD6. Memory column = private footprint** (`RssAnon + VmSwap`), the nearest to macOS's "Memory" and Windows' private
  working set; Real, Private, Shared, Compressed and Peak are optional columns of the Memory tab. They come from `status`,
  read on the Memory tab only (A10: 6.7–7.6 µs per process; `statm` would cost 0.7 µs but has no `VmSwap`). PSS only in
  Inspect (A8).
- **AD7. Memory summary:** Physical Memory `MemTotal`; Memory Used `MemTotal − MemAvailable`; Compressed = zram's RAM
  (`mm_stat` `mem_used_total`); Wired = `SUnreclaim + KernelStack + PageTables + Unevictable`; App Memory = Memory Used −
  Wired − Compressed, so the three add up as on macOS; Cached Files = `Active(file) + Inactive(file)`; Swap Used = swap
  in use on devices that are not zram (`/proc/swaps`). The Compressed Memory column is titled "Swapped Memory" when a
  disk swap is in use too.
- **AD8. Memory Pressure:** the graph's height is the memory in use; its colour is green, yellow or red from the kernel's
  pressure stall information (`/proc/pressure/memory`) and the memory left (thresholds in the spec, AM33).
- **AD9. GPU** from `fdinfo` (`drm-engine-*`): % GPU = the busiest engine of the process, GPU Time = the sum of its engines;
  the system's GPU graphs sum the user's clients (the compositor is one of them). A driver without these keys shows no GPU
  column ("—").
- **AD10. Read only what is shown** (d), with the costly reads spread over samples: a fifth of the processes' threads per
  sample for Wake Ups, a tenth of the processes' descriptor lists per sample for sockets and GPU clients, new processes at
  once (A10: reading every thread and descriptor at every sample costs 38–44 ms). A process the kernel refuses a read for
  (another owner's or a non-dumpable one) shows "—" in that column.
- **AD11. Quit through the shell for windowed processes**, `SIGTERM` otherwise; Force Quit `SIGKILL`; one `/proc/<pid>` descriptor from the start-time check to the signal (AD30).
- **AD12. Send Signal to Process…** kept (macOS); its list is the usual POSIX signals with plain names.
- **AD13. Inspect** (Info button, Ctrl+I): macOS's window "<name> (<pid>)": Parent Process, Process Group, User, % CPU,
  Recent hangs (marks seen since the app opened); tabs Memory, Statistics, Open Files and Ports (files, pipes, sockets with
  their addresses from `/proc/net/*`); Quit. No Sample button (h). Another owner's process shows what `stat` and `status`
  give and "—" elsewhere (spec AM57).
- **AD14. Views (View menu):** All Processes (default), All Processes, Hierarchically, My Processes, System Processes,
  Other User Processes (AQ4), Active Processes, Inactive Processes, GPU Processes, Windowed Processes, Selected Processes,
  Processes, by Type (g), Processes, by GPU.
- **AD15. Search** is a live filter, as macOS; matches the process name, the app name, the user's name, the user's own
  command lines (AD25) and the PID.
- **AD16. Dock Icon** offers macOS's five items; "Show Memory Pressure" is not offered (no source confirms it on macOS).
- **AD17. The app quits when its last window closes** (the Grassfield Dock knows running apps by their windows), so the Dock
  graph shows while the window is open or minimized (macOS keeps the app running without a window: known limitation).
- **AD18. Performance and App History are windows of the Window menu**, not tabs: the five macOS tabs stay as they are.
- **AD19. Efficiency Mode** through the user manager's CPU weight (g): only on the units uwsm names per launch in
  `app-graphical.slice`; turned off with the unset value; its side effect on the `cpu` controller recorded (g); refused, with
  the reason, everywhere else (review of e3882de: a service's runtime drop-in would outlive a restart).
- **AD20. App History's source** is the user journal's resource records of app units plus the live units. A unit name
  `app-<desktop>-<name>-<8 hex>.scope` or `app-<desktop>-<name>@<8 hex>.service` is split at its "-" and "@" (an escaped part
  holds none: uwsm writes "-" as `\x2d`), `<name>` is unescaped (`\xNN` to its byte), then matched as a desktop id first
  (uwsm's name for a launch by desktop entry), else to the desktop entry whose `Exec` basename it equals, else shown as it
  is (review of e3882de).
- **AD21. Projection file and Dock tile file** (f) rather than IPC polls: no process is started per sample, no wake-up
  without a change.
- **AD22. Session processes** are the user's processes whose unit ends the session or runs it: units of `session.slice`
  and `session-graphical.slice` (the compositor through uwsm's `wayland-wm@`, the shell, the menu bridge and Grassfield's
  other session units), uwsm's `wayland-session-bindpid@*.service` (in `background.slice`; its end stops the session, A7),
  the login session's `session-<n>.scope` under `user-<uid>.slice` (the process the session is bound to), and the user
  manager's `init.scope`. Quit, Force Quit and every signal ask twice (AM54); Stop is refused; Efficiency Mode is refused
  (review of e3882de: the bindpid unit and the login scope were missing).
- **AD23. Keep CPU Windows on Top** (macOS Window menu) through a toplevel tag (ADR-0015's `xdg-toplevel-tag` helper) and a
  rule of the Grassfield session's Hyprland config; without the rule, the item is absent.
- **AD24. Tables and graphs** reuse Grassfield.Ui (tokens, `SegmentedControl`, `SearchField`, `PopupMenu`, `Sheet`) and the
  list header of Files (`apps/files/qml/FileList.qml`); a shared table component moves into Grassfield.Ui only if the
  step's code is the same in both apps (R5).
- **AD25. Other owners' rows (AQ4 = B).** Read from `stat`, `statm` and `status` only (not `cgroup`, review of 949fc98); their name is `stat`'s short name (the
  kernel's 15-character `comm`), their Command cell is "—", and search does not match their command lines. `cmdline` is never
  read for them: its first word can be a rewritten title (review of e3882de). Kernel threads (`PF_KTHREAD`) are summed into
  one "Kernel" row (user root, PID "—"), as macOS's `kernel_task`; its CPU counts in System.
- **AD26. Processes, by Type** has five groups (g): Apps, Background Processes and Session Processes (AD22) for the user's
  own processes, System Processes (system accounts and the Kernel row) and Other Users. "System Processes" means the same set
  as macOS's View filter of that name (owner uid below `UID_MIN`, plus the kernel).
- **AD27. End Task (AQ5)** is a label and a switch, not a new path: the Dock menu's existing Force Quit of all the app's
  processes (Option + Force Quit, `Launch.forceQuitPids`, `Power.run("forcequit")`), with its confirmation. Shown after
  Quit only while `dock.endTask` is on and the app runs; never on the Files tile, folders or the Trash.
- **AD28. Ctrl+Shift+Esc (AQ6)** goes through `grassfield-launch-key activity`, the session's way of opening a default app
  from a key: the app gets its own scope, and the key does nothing in a nested dev session (as the other launch keys).
- **AD29. One runtime folder per display** (f): `$XDG_RUNTIME_DIR/grassfield/activity-<display>/`, the clipboard helper's
  rule; every file names its writer by pid and start time (review of e3882de).
- **AD30. One process from the check to the signal** (e): a `/proc/<pid>` directory descriptor, `stat` read through it, the
  same descriptor signalled (review of e3882de).
- **AD31. No "Delete Usage History"** (g): a user cannot delete journal entries, and a button that only hides them would not
  do what it says (R11; review of e3882de).
- **AD32. The Memory tab reads `statm` at every sample and `status` in turns** (d; review of 949fc98). `statm`'s resident
  set less its file and shared-memory part is `RssAnon` exactly, at a sixth of `status`'s cost (A10); `VmSwap` and
  `VmHWM` come from `status`, a fifth of the processes per sample and every new one at once, so they show at most five
  samples late (25 s at Normally), and the peak never shows below the resident set. The tab's first sample after another
  tab, or after a pause of more than two intervals (a hidden window), reads every process's `status` once, so the bound
  holds when the user comes back to it (review of f68789c). The interval is the one set (AM9), not the one measured, which
  a full read left unknown (review of 19f5d4c). Swap changes slowly: the column stays macOS's, at the cost of the CPU
  tab.
- **AD33. A process's owner from its directory on arrival, after an exec and in its turn** (c, d; review of 949fc98): six
  hundred `fstatat` a sample bought nothing a running process changes without an exec but its uid, which the turn (a
  tenth per sample) catches; behind a directory owned by root (a non-dumpable process) the turn reads `status`'s real uid
  again too (review of f68789c); an action reads its process's identity again anyway (AD30).
- **AD34. One instance, on the session bus** (AM1; step 2a). The running app owns `org.grassfield.Activity`
  (`org.grassfield.Activity.Dev` in a dev session, which shares the owner's bus); a second launch calls its `Activate`
  with its own xdg-activation token, if it has one, and leaves. The running app takes the name before its window loads and
  answers from its event loop, after the load: a second launch waits for that answer up to 25 s and leaves whatever comes
  back, and runs only when the name has no owner (step 2b; a 2 s wait opened a second window while the first was starting,
  review of #47). The window comes forward with that token (Qt's Wayland
  window takes `XDG_ACTIVATION_TOKEN` for its next activation request); without one the compositor decides. No Grassfield
  app had one: the spec's "the mechanism Settings and the Store use" was the Dock's activation plan, which a launch from
  Apps or a key does not go through, and a monitor running twice would sample twice. Launched again while its window is
  off screen (minimized, or on another Desktop: the compositor suspends it, AD35), the app also asks the shell's Dock to
  bring it back, `qs ipc -p <shell> call dock reopen org.grassfield.Activity` (apps/runmode.h `shellIpcArgs`, as Settings'
  `update check`; the call is killed after 5 s, `kShellIpcMs`, as Settings' are): the Dock does what a click on its tile does (`Launch.activationPlan`: everything minimized, the most
  recent window comes back), the path the Dock uses for a minimized window. xdg-activation alone switches Desktops but
  leaves a window on `special:minimized`, which the shell hides again as soon as an activation shows it (the integrator's
  nested pass of 983b7de; macOS: launching a running app brings its window back). The action is in the IPC table
  (`docs/specs/security.md`), and `tests/security/ipc_inventory.sh` counts a Grassfield app as its caller only through
  `shellIpcArgs()`.
- **AD35. The sampler on its own thread, only while the window is shown** (AM8, AM9, AM-P3; step 2a). A sample costs up to
  17 ms on the reference machine's CPU tab and more on Energy and Network (AM-P2): too long for the window's thread. One
  sample at a time, on a low-priority thread, at the update frequency; the window is shown when it is visible, exposed and
  not minimized. Back on screen the sampler forgets its rate baselines (`Sampler::forgetRates`): the first sample's rates
  show "—", and the next comes one second later rather than a whole interval.
  Hidden is told by what the compositor sends, not by a Grassfield record (the integrator's review of 983b7de): Hyprland
  0.56.2 sets xdg_toplevel's `suspended` state on every mapped window whose workspace is not shown
  (`GlobalWindowController::updateSuspendedStates`, run by every move to a workspace and every workspace change), and Qt's
  Wayland client (6.11.2, xdg_wm_base version 6) then reports the window not exposed (`QWaylandXdgSurface::isExposed`) and
  sends an expose event. That covers Grassfield's minimize, whose hidden state is the workspace `special:minimized`
  (whether the plugin or the shell's fallback moves the window there), and a Desktop not shown, with no request from the
  app to the shell. Grassfield's own minimize record (the plugin's places, the shell's list) would need a new channel from
  the app and would miss the other Desktops. Qt's Minimized state stays in the test for the platforms that keep it: on
  Wayland, which has no minimized state, Qt reverts it at once. A window covered by others is still on a shown workspace and
  keeps sampling. A-W1 drives Qt's side (an expose event that makes the window unexposed, as Qt's Wayland client sends it);
  the compositor's side is the nested pass.
- **AD36. A row's icon from its launch unit's desktop entry, theme names only** (AM10, AM17; step 2a). uwsm names a
  launch's unit after the desktop id it launched (A7), so an own process in such a unit takes that entry's `Icon` when it
  is a theme name, looked up in the icon theme on the window's thread (as Files' theme icons); every other process, and an
  entry that names a file, gets the theme's generic executable icon. A file named by an entry the user may have written is
  not decoded here (Files decodes such files in an isolated child; the table holds hundreds of rows). The entry's name
  joins the search (AM14); it names a row only through the projection, step 3.
- **AD37. Every graph keeps its history whichever tab is shown** (AM5, AM29, AM42, AM44; step 2b). macOS samples every
  resource whatever the tab, so coming back to a tab shows its graph's last minutes. The sampler now reads the four system
  groups (`/proc/stat` and `loadavg`; `meminfo`, `pressure/memory`, `swaps` and zram's `mm_stat`; `diskstats`; `net/dev`)
  at every sample on every tab: 0.04 ms together on the cloud machine, 0.04 to 0.07 ms more on a Disk sample of A10's
  fixture, measured in pairs. A10's step-1 plans always counted every system file; its one-pass Disk line now reads them
  too, like for like. The Energy Impact graph is the exception: its sum needs the Energy tab's own reads (io, threads, GPU),
  so it takes only the samples that computed it. A rate the sampler could not give (a first sample, the one after the
  window was hidden, AM8) is a gap in its graph, never a zero. Each graph keeps `historySamples` samples (120: two minutes
  at Very Often, ten at Normally).
- **AD38. A figure's colour is a square beside it, the text stays text** (AM7; step 2b). macOS colours the System and User
  values (and the IO and network rates) in their graph's colour. A graph colour holds A2's 3:1 against the graph, not the
  4.5:1 a line of caption text needs, so the figure a graph draws carries a square of its colour (`swatchSize`) before its
  label, and its label and value keep the window's text colours. The colours are Grassfield's own, per appearance, each 3:1
  or more against the graph's fill and the window (`test_activity_graph_colours`): System and Write and Out a red, User and
  Read and In a blue, the Memory Pressure levels green, yellow and red, Battery green.
- **AD39. The battery from UPower, read while the Energy tab is shown** (AM39; step 2b). The display device (its
  properties, read only) at each Energy sample, as the inhibitors (AM38); the charge history of the laptop battery (the
  first device UPower names `battery_*`; peripherals are named by their kind) at most once a minute, or at once when the
  power source changes. Time on battery or on AC is the time since the history's last change between discharging and
  anything else, "—" when the twelve hours show none; "Calculating…" while UPower estimates the time left. A computer
  without a battery shows the Energy Impact graph alone, as macOS. No new D-Bus name or method is served.
- **AD40. The grouped views are levels in the table's list** (AM13, AM49; step 2b). macOS shows both views in its outline:
  rows with a disclosure triangle, indented by level. They are entries of the same list model as the flat views (a
  process at its depth, or a GPU's header), so a new sample still never resets the model and the selection still follows
  its processes. An entry's identity is its process's and its group's (a process that uses two GPUs is under both, selected
  and copied once). In the tree a row whose parent is not listed, or is not older than it (the parent's pid was reused),
  is a root, and so is a row no root leads to (two rows that name each other, read in a race); each level is sorted by the
  sort column; the search keeps a row that matches and every row above it. A collapsed row stays collapsed across samples
  while its process lives, a GPU's header while the app runs; the triangle, or Right and Left, open and close a row. A
  header is not a process: never selected, passed over by the keyboard. The GPU views (GPU Processes too) read the GPU
  clients on every tab, a gap of step 2a (they listed nothing on Memory, Disk and Network).
- **AD41. A GPU's name from pci.ids** (AM47; step 2b). The card is the `/sys/class/drm/card<n>` whose `device` link ends in
  the GPU's `drm-pdev`; its vendor and device ids are looked up in hwdata's `pci.ids` once per GPU. The name is the vendor's
  short name (its bracket's first part, "[AMD/ATI]": AMD; else its name without a company suffix) and the device's
  marketing name (its last bracket, else its name): "Intel UHD Graphics", "AMD Radeon RX 6600/6600 XT/6600M", "NVIDIA
  GeForce RTX 3060 Lite Hash Rate". Without a name, "GPU <n>" for card n-1; without a card, the pdev.
- **AD42. The dev guard's roots are named pid records** (AM56; step 2c). In a dev session an action reaches only a
  process that a root names or one of its descendants. A root is a record of `scripts/dev/pidfile.sh` (the pid, and its
  start time in `<file>.start`), named by `GRASSFIELD_ACTIVITY_DEV_ROOTS` (dev plumbing, ADR-0019); none named, every
  action is refused. The spec's first wording ("descending from the nested compositor") cannot hold: an app the nested
  shell starts is detached (Quickshell's `execDetached` is `QProcess::startDetached`, which leaves the child under init:
  measured, its parent pid 1), and Hyprland's `exec` detaches the same way, so a nested app descends from neither. A test
  names its fixture's record; a nested pass that quits processes starts them as such a fixture. Fails closed: a record
  whose process ended, or whose pid another process took, names nothing. Step 3's projection names the nested display's
  windows, which may widen it then.
- **AD43. Quit before the shell's projection** (AM52, AM75; step 2c). Until step 3 there is no projection, so the app
  cannot tell a process's windows: Quit of a process of an app unit (under `app-graphical.slice`) sends nothing and the
  sheet says "The process couldn't be quit safely." with Cancel (now the default) and Force Quit only, as AM75 says for a
  session without the shell. A process outside an app unit gets `SIGTERM`. Quit never risks unsaved work by a signal;
  Send Signal's Terminate stays available. **A command run in a terminal** (the integrator's decision on the review of
  1153365, delegated by the owner on 2026-10-27: the closest to macOS, no technical step for the user): a process with a
  controlling terminal (stat's `tty_nr`) whose parent is in the same app unit, so not the process that started the unit,
  gets `SIGTERM` on Quit (`python` in foot); the unit's own process waits for step 3's projection.
- **AD44. The sheets** (AM50, AM54, AM55; step 2c). Grassfield.Ui's Sheet (as Files and Settings): the quit sheet with
  Force Quit at the leading edge, Cancel and Quit; a session process's warning when the action is chosen, before the quit
  sheet or Send Signal's sheet, Cancel its default; Send Signal's pop-up (Grassfield.Ui's ComboBox) with Terminate chosen
  first. The processes of a sheet are fixed when it opens (a descriptor each, AM51) and released when it closes. The Stop
  button and the action menu share one glass capsule in the toolbar (macOS 27); the Stop glyph, an octagon with a cross,
  is our own drawing (`branding/LICENSES.md`).
- **AD45. Inspect's windows and their reads** (AM57, AM58; step 2d). One window per process, a transient window of the
  main one in the titlebar-only style (role "info", as Files' Get Info), brought forward by a second request and closed
  with the main window (AD17). It reads through the `/proc/<pid>` directory descriptor that AM51's start-time check opened
  (`ProcessHandle`), so a pid another process took is never read, and a read that fails means the process ended: the
  window then closes (it would show a process that is gone, and its Quit would act on nothing). The reads run on the
  sampler's thread (AD35: `smaps_rollup` of a process of 1 GB costs 3 ms, too long for the window's thread), at the update
  frequency and only while the window is on screen (AM8, AD35's ShownWatch); back on screen a read comes at once and the
  next a second later, the % CPU starting again from the first. A read covers the header (`stat`, `status`, the parent's
  `stat`) and the tab shown only (AD10): Memory adds `smaps_rollup` at most every 5 s, Statistics the threads' `status`
  and, for an own process, `io`, `cgroup`, `cmdline`, `exe` and `cwd`, Open Files and Ports the descriptors and their
  sockets. Another tab's last values stay until it is read again, so no "—" flashes between a tab and its read. The Parent
  Process is the parent now, and a parent younger than the process holds a reused pid (AD40).
- **AD46. What an Inspect window reads, and from where** (AM57, AM58; step 2d). Another owner's process gives its `stat`,
  `status` and its threads' `status` (Context Switches), so its Scheduler Policy (stat's field 41) shows too, which AM57's
  first list left out; never its `io`, `cgroup`, command line, links or descriptors (AD25). Sockets are looked up in the
  process's own network namespace, `/proc/<pid>/net/{tcp,tcp6,udp,udp6,unix}` read through its descriptor, not the app's
  `/proc/net` (the spec's first wording): a process in a sandbox with its own network namespace gets its own sockets, and
  the tables are read once per read and only when the process holds a socket. At most 10 000 descriptors are listed (a
  process can hold a million), the rest counted on a last line.
- **AD47. The window's header, Quit and keys** (AM57, AM59; step 2d). Recent hangs shows "—" until step 3's projection
  can count them (R11: no made-up 0). Quit opens AM50's sheets for this process alone, through a `ProcessActions` of its
  own with the same rules (own processes only, the session warning, AD43, the dev guard); quitting the app's own process
  from its Inspect window closes the main window (AM54). The Info button joins Stop and the action menu in their capsule
  (macOS 27), with the existing `info` glyph. A key belongs to the key window (as Files' Get Info): while an Inspect window
  has the keyboard, the main window's keys and its global menu's wait (Ctrl+W closes the Inspect window, never the main
  one), Ctrl+Q aside. The labels' columns are as wide as their longest label, the token width at least, and always leave
  the values their room (French labels run longer).

- **AD48. The projection, as built** (AM60; step 3). The shell's `ActivityLink` service writes `windows.json` while a window
  of the app is open on its display: Hyprland's list is read again on `openwindow` and `closewindow` (pid and class come
  with it) and on a change of NotResponding's marks, and the file is written 250 ms after the last of them, only when its
  body changed. The writer is the shell itself: the script that writes the file names its parent (the shell) by pid and
  stat start time, then hands the text to `write-private.sh` (0700 folder, 0600 file, a temporary name renamed). The file
  goes when the app's last window closes. The app watches the folder and the file (inotify) and reads the file again at each
  sample, so a shell that crashed (its file left behind, its writer gone) stops counting at once. Anything that is not a
  valid version 1 file from a live writer is no projection (Terms), and the app behaves as without a shell (AM75).
- **AD49. Quit through the shell waits for the outcome, 10 s at most** (AM52, AM61; step 3; amended after the review of
  5bfd4419, whose first bound, a second with `qs` starting included, could offer Force Quit while the app showed its save
  prompt on a loaded machine: the outcome is now the shell's "ok", the process gone, or its windows gone from the
  projection, looked for every 250 ms; Force Quit only on "refused" or nothing within 10 s). As first written: Quit of a process that owns windows asks the
  shell (`qs ipc ... call activity quit <pid>`, through `shellIpcArgs()`) and answers "pending"; the sheet then takes no
  click or key (Grassfield.Ui's Sheet: a confirm handler may answer `false`, then closes the sheet or shows its error
  itself). "ok" sends nothing more (the app may ask to save), "no-windows" sends SIGTERM through AM51's descriptor, and
  "refused" or no answer within a second leaves Force Quit alone. A sheet closed meanwhile drops the answer. With a
  projection, a process of an app unit that owns no window (an app's helper) gets SIGTERM; without one, AD43 holds.
- **AD50. The Dock tile's graph** (AM62; step 3). View > Dock Icon (activity.json `dockIcon`): the app writes
  `dock-tile.json` at each sample (32 samples at most, three decimals, under 2 KiB) and removes it when the icon is chosen
  and when it quits. While its window is off screen with a graph chosen, the app reads the system's files alone at the
  interval, no process (AM-P3). The Dock reads its own display's folder only, only while the app's window is open, and draws
  only a file whose writer owns one of the app's windows now: the shell has no reader of `/proc` in QML, and a window the
  app owns is proof that it is alive (a crashed app owns none). It draws on a dark plate in both appearances with the dark
  palette's graph colours (the plate is dark, so those hold their contrast), network and disk mirrored around the middle,
  CPU history stacked, CPU usage a gauge of ten segments (tokens `dock.tileGraph*`).
- **AD51. End Task, as built** (AM63, AQ5; step 3). The Dock menu's last rows come from `Launch.quitRows`: End Task after
  Quit (or after Force Quit for an app that does not respond) while `dock.endTask` is on, never with Option and never on
  the Files tile; it runs the Option + Force Quit path unchanged. The switch is in Settings > Desktop & Dock under the
  Dock's other switches; the key comes into the schema, the defaults and the generated contract.
- **AD52. Ctrl+Shift+Esc, as built** (AM64, AQ6; step 3). `grassfield-launch-key activity` starts the desktop entry through
  `uwsm app` (nothing in a nested dev session, as its other kinds); the binding is off on the lock screen as the other
  launch keys and is listed in Settings' keyboard shortcuts ("Activity Monitor").

- **AD53. Processes, by Type, as built** (AM65; step 4). A header per kind with its count, in Windows' order (Apps,
  Background Processes, Session Processes, System Processes with the Kernel row, Other Users), a kind without a process the
  search keeps left out. Under Apps, a header per app unit with the app's icon and its count, then the window owners outside
  such a unit. A unit's identity is a hash of its name the sampler keeps (`unitKey`, never the path, AD25); its name is the
  window's app (the projection), else the desktop entry of that id, else the entry whose `Exec` runs that command (read once,
  at the first such lookup), else the unit's `<name>`. Headers collapse and stay collapsed while the app runs, as AM49's.
- **AD54. Efficiency Mode, as built** (AM68, AM76; step 4). `SetUnitProperties(unit, runtime=true, [CPUWeight])` on the
  session bus, the user manager's own units (no polkit): 0 (systemd's `idle`, which writes `cpu.idle=1` and leaves
  `cpu.weight`; checked in systemd v258's `dbus-cgroup.c` and `cgroup.c`), 1 when a systemd older than 252 answers
  `InvalidArgs`, `UINT64_MAX` (unset) to turn it off. The unit is read again through the process's `/proc` descriptor when
  the item is chosen; a session unit, another unit or an ended process changes nothing and says so in a sheet; the dev guard
  is AM56's. The sampler reads each eligible unit's `cpu.idle`, then `cpu.weight`, once per sample while the main window
  shows (`ReadEfficiency`), so Status and the check mark follow a change made elsewhere. The first time, the sheet; its
  "Don't ask again" is `askEfficiency` in activity.json. No user manager on the bus at start: the items are absent.
  Disabled items show no reason (decided 2026-10-31 under the owner's rule, closest to macOS, whose menu items are
  greyed without one; no menu here shows a tooltip, the menu bar's being the shell's): AM68's tooltip is dropped. The
  backend keeps the reason (`reason`) for an accessibility description if a menu row ever carries one.
- **AD55. App History, as built** (AM67; step 4). `journalctl --user --output=json --output-fields=MESSAGE_ID,USER_UNIT,
  CPU_USAGE_NSEC,MEMORY_PEAK --since=@<start> MESSAGE_ID=ae8f7b866b0347b9af31fe1c80b127c0`, read when the window opens and
  when the period changes, at most 16 MiB, 30 s at most (else "not available"); a record counts when its `USER_UNIT` is a
  launch uwsm named (AM65's names: the record does not name the slice). The live app units add their cgroup's `cpu.stat`
  `usage_usec` and `memory.peak` (a unit whose record came in the same read counts once). systemd writes the record at
  `info` only when the unit used more than 1 s of CPU, 64 MiB of memory or 1 MiB of disk (`unit.c` MENTIONWORTHY_*), so a
  light launch is missing from the history; recorded for the owner's check (A6).
- **AD56. Performance and the CPU windows** (AM66, AM71, AM72; steps 4 and 5). One backend object keeps every resource's
  history from the samples (the system's files the sampler already reads, plus each processor's user part and each GPU's
  memory by region) and builds the texts only while one of its windows is on screen. While one is and the main window is
  not, the app reads the system's files at the interval, and the processes' GPU clients for Performance and GPU History
  (AM8's rule otherwise holds). Facts that do not change are read once (`machine.cpp`: the processors' topology and caches
  from `/sys/devices/system/cpu`, a disk's `size`, `queue/rotational` and `device/model`, an interface's kind); the
  processors' mean `scaling_cur_freq` and `/proc/uptime` at each sample while CPU is shown; a Wi-Fi network's name from
  NetworkManager on the system bus (read-only, `GetDeviceByIpIface`, `ActiveAccessPoint`, `Ssid`) each time it is selected.
  CPU Usage lights twenty segments per processor (System, then User, the kernel's split per processor: `/proc/stat` has no
  owner per processor); Clear CPU History empties the per-processor histories.
- **AD57. Keep CPU Windows on Top is not built** (AM73; step 5). The compositor plugin places a window's controls by its
  xdg tag and reads `info` exactly (`compositor/src/Titlebar.cpp`), so a tag for a Hyprland rule needs a plugin change, which
  only a nested pass can check (C1 to C3). Per AM73 the item is absent without the rule. Proposed for the integrator: the
  plugin reads the role up to a `+` (`info+on-top` is `info`), the CPU windows carry `info+on-top` while the setting is on
  (set at map, so the windows open again when it changes), and `config/hypr/grassfield/windows.lua` adds
  `hl.window_rule({ name = "gf-activity-on-top", match = { class = "^org\\.grassfield\\.Activity$", xdg_tag = "^info\\+on-top$" }, pin = true })`
  once a nested pass shows that `pin` keeps them above the others.

## Delivery order (owner, AQ7 = A: macOS first)
Each step is one pull request to main, reviewed by the integrator (opus), with its nested pass, and merged before the next.
0. **Docs** (this pull request): ADR-0038, `docs/specs/activity.md`, the parity matrix, the probes.
1. **The sampler, no window**: `apps/activity/src` (process and system samples, rates, row identity, owners, kinds, the
   Kernel row, GPU clients, TCP sockets, memory pressure), gtest on fixture trees, `tests/apps/activity_cost.sh` with
   AM-P2 met, `tests/integration/activity_owners.sh` (another user's processes through the real kernel), the owner-machine
   read-only checks of "Not verified here". Spec AM20 to AM49 (data), AM79.
2. **The window**, in four pull requests (2026-10-28, under the owner's rule: each a slice the integrator can review and
   pass nested on its own, as other lanes' 4a and 4b):
   - **2a. The window and its table**: the toolbar, the five tabs, the table with each tab's columns, the flat views,
     search, the columns chooser, sort, selection, Copy, Preventing Sleep (logind), `activity.json`, menus, icon, desktop
     entry, translations, the PKGBUILD lines, the legal element; one instance (AD34); sampling on its own thread only while
     the window is shown (AD35); AM-P1, AM-P3, AM-P4 measured. Spec AM1 to AM4, AM6 to AM12, AM14 to AM19, AM38, AM74.
   - **2b. The summaries and graphs**, and the views that group rows: each tab's summary and graph (AM5, AM29, AM32 to
     AM35, AM39 with UPower, AM42, AM44, AM47's GPU name), the graph tokens (AM7), Network's line under the table (AM43),
     All Processes, Hierarchically (AM13), Processes, by GPU (AM49). Built (AD37 to AD41;
     `docs/audits/activity-2026-10-28/step2b.md`).
   - **2c. Quit, Force Quit, Send Signal** (AM50 to AM56): the sheets, the `/proc/<pid>` descriptor and
     `pidfd_send_signal`, the session processes' second sheet, the dev guard; the Stop button and the action menu. Built
     (AD42 to AD44; `docs/audits/activity-2026-10-28/step2c.md`).
   - **2d. Inspect** (AM57 to AM59): the Info button and its windows. Built (AD45 to AD47;
     `docs/audits/activity-2026-10-28/step2d.md`).
3. **The shell links**: the projection and "(Not Responding)", IPC `activity quit` and Quit of windowed processes, the Dock
   tile graph, End Task and its Settings switch (AQ5), Ctrl+Shift+Esc (AQ6). Spec AM60 to AM64. Built in the pull request
   of steps 2d to 5 (AD48 to AD52; `docs/audits/activity-2026-10-28/step3-5.md`).
4. **Windows 11's additions**: Processes, by Type, Performance, Efficiency Mode, App History, the Login Items link, the
   Status column. Spec AM65 to AM70. Built in the same pull request (AD53 to AD56).
5. **The small windows and the finish**: CPU Usage, CPU History, GPU History, Keep CPU Windows on Top; F1 against public
   captures, A2, the budget measured again on the owner's machine (L2). Spec AM71 to AM73. Built in the same pull request
   but Keep CPU Windows on Top (AD56, AD57); F1, A2 and L2 need the integrator's nested pass and the owner's machine.

## macOS reference (Apple's Activity Monitor User Guide, macOS 27 in its version selector, read 2026-10-28; facts only)
Five tabs CPU, Memory, Energy, Disk, Network; the bottom of the window summarises each one (System, User and Idle for the
CPU; Physical Memory, Memory Used, App Memory, Wired Memory, Compressed, Cached Files and Swap Used with the Memory
Pressure graph; Remaining charge, Time remaining, Time on battery and Battery (Last 12 hours) on laptops; Reads in, Writes
out, Data read, Data written and their rates; Packets in, Packets out, Data received, Data sent and their rates). View
menu filters: All Processes; All Processes, Hierarchically; My Processes; System Processes; Other User Processes; Active
Processes; Inactive Processes; GPU Processes; Windowed Processes; Selected Processes; Applications in last 12 hours;
Processes, by GPU. Columns by View > Columns; search field; Info button or a double-click for a process's details; the
Stop button offers Quit ("quits when it's safe to do so") and Force Quit; a hung process is "(Not Responding)" in red;
View > Send Signal to Process; Window > CPU Usage, CPU History, GPU History; View > Dock Icon puts a live CPU, network or
disk graph in the Dock; the default update is every 5 seconds.

## Windows 11 reference (described in words; Microsoft's own pages were not found by the search, third-party descriptions used, marked in the parity matrix)
Task Manager (Ctrl+Shift+Esc): a navigation pane with Processes, Performance, App history, Startup apps, Users, Details,
Services and Settings; a search box for name, publisher or PID. Processes grouped as Apps, Background processes and
Windows processes, groups expandable; columns chosen from the header (Status, CPU, Memory, Disk, Network, GPU, Power usage,
…). Performance: CPU (overall or per logical processor), Memory, Disk, Network and GPU graphs with details. App history:
resource use per app since a date, with Delete usage history. Efficiency mode (22H2): lowers a process's priority and its
power class, toggled from the command bar, refused for core Windows processes. End task in the taskbar's menu: a switch
under Settings > System > For developers (Advanced on 25H2), off by default.

## Alternatives rejected
- **A shell surface instead of an app:** the owner asked for a native app in `apps/`; a shell surface would sample inside
  the shell process (gates P1, P2) and could not be closed.
- **Reading Hyprland from the app** (`hyprctl -j clients` each sample): only the shell's platform layer talks to Hyprland
  (§5.2, §5.4), and a poll would wake Hyprland's request socket every second.
- **A second "not responding" detector** (pinging windows from the app): the brief forbids duplicating NotResponding.
- **`nice` or `SCHED_IDLE` for Efficiency Mode:** one-way without root (A3).
- **PSS (`smaps_rollup`) as the Memory column:** 6.6 ms per read of a 1 GiB process (A8): a browser would cost tens of
  milliseconds per sample.
- **Every per-process file at every sample:** 38–44 ms per sample on the A10 fixture; the reads are spread (AD10).
- **Checking the start time, then opening a pidfd:** the pid can be reused between the two (review of e3882de); the
  `/proc/<pid>` descriptor closes the gap (AD30).
- **A background collector for App History and 12 hr Power:** a new service (R5, §5.8); systemd already records each app's
  CPU time when it stops.
- **The app drawing its Dock tile as an image:** arbitrary pixels on a system surface and a decode per sample; numbers drawn
  by the Dock are cheaper and cannot imitate another tile.

## Evidence
- `docs/audits/activity-2026-10-28/activity-probes.sh` and `probes-output.txt` (docker exit 0): A1 the `/proc` read matrix
  as an unprivileged user (own, another user's, own non-dumpable, root's); A2 signals and pidfds (EPERM on another user's
  process, ESRCH after the target ended); A3 nice and `SCHED_IDLE` one-way under RLIMIT_NICE 0, I/O class reversible; A4 the
  system files; A5 TCP byte counters per socket with the owner process for the user's own sockets, none for UDP; A6 systemd
  262's delegation and resource record (`CPU_USAGE_NSEC`, `MEMORY_PEAK`, `MEMORY_SWAP_PEAK`, `IO_METRIC_*`, `IP_METRIC_*`);
  A7 uwsm 0.27.1's scope and service names, its escape of "-" and the session's bindpid unit; A8 the cost of each `/proc`
  read (Python); A2 also the `/proc/<pid>` descriptor path; A9 `perf_event_paranoid` 2 and a reversible
  `sched_setaffinity`; A10 the CPU cost of one sample per tab in C (`sampcost.c`), two runs. The second recorded output
  replaces the first (review of e3882de). Step 1 corrects `sampcost.c`'s Energy label only (the recorded output keeps the
  old label; its figure already counted the descriptor lists).
- Step 1: `docs/audits/activity-2026-10-28/step1.md` (the cost per tab, the unit tests plain and under ASan and UBSan, the
  mutants, the two-user container test) and `owner-checks.sh` (the read-only checks for the owner's machine).
- Code read: `shell/services/NotResponding.qml` and `.js`, `shell/overlay/ForceQuitPanel.qml`, `shell/overlay/DockMenu.qml`,
  `shell/services/Power.qml`, `shell/services/AppLaunch.js`, `shell/services/SettingsApp.qml`,
  `apps/settings/qml/LoginItemsPage.qml`, `apps/runmode.h`, `config/hypr/grassfield/bindings.lua`.
- Omarchy v4.0.4 (c668141, data): the btop binding, zram and zswap files named above.

## Consequences
- New: `apps/activity/` (C++ sampler and model, QML window), `tests/unit/activity/` (gtest with fixture `/proc` trees: every
  formula, every refusal), `tests/apps/activity_cost.sh` (the budget), `tests/integration/activity_owners.sh` (two users in
  a throwaway container), `tests/apps/activity_*.sh` (offscreen), a nested
  scenario (Not Responding, Quit through the shell, the Dock graph), translations, the icon, the PKGBUILD lines.
- Shell: a projection writer and the IPC action `activity quit` (security.md "IPC surface"; `ipc_inventory.sh` extended to
  the callers in `apps/`), the Dock
  tile graph in `shell/dock/Dock.qml`, End Task in `shell/overlay/DockMenu.qml` (AQ5), Ctrl+Shift+Esc in
  `config/hypr/grassfield/bindings.lua` and the `activity` kind of `packaging/bin/grassfield-launch-key` (AQ6).
- Settings and config: the switch in Settings > Desktop & Dock and the key `dock.endTask` (boolean, default false) in the
  `grassfield.json` schema (`config/schema/`).
- Docs: ADR-0020 rows (j); `docs/specs/security.md` (the IPC row); `docs/legal/visual-review.md` (element E38 and question
  14 added in this pull request: the app's name "Activity Monitor" / « Moniteur d'activité », "needs legal review"; its
  window joins E38 at step 2); `docs/specs/dock.md` (the tile graph, End Task); `docs/specs/settings.md` (the switch).
- Efficiency Mode can change how all apps share the processor under contention once it is first used (g).
- Gates: P1 and P2 are the shell's and unchanged except the projection writer (measured); the app's own budget is AM-P1 to
  AM-P4; A1, A2, I1, Q1 to Q3 and F1 apply as for every app.

## Review history
**Integrator's opus review of e3882de (2026-10-28): FAIL, five MAJORs and eight MINORs, all on the docs.** What held: no
root, no polkit action, no new dependency; the IPC never kills; A1 supports AQ4; RLIMIT_NICE 0 as A3; Ctrl+Shift+Esc free;
`just check-quick`, `bash -n` and `ui_names.py` exit 0. Each finding and its answer:
| Finding | Answer |
|---|---|
| MAJOR 1: the nested and the real session share `$XDG_RUNTIME_DIR/grassfield/activity/` | one folder per display and a writer's start time in every file (f, AD29; spec AM60, AM62) |
| MAJOR 2: `session-<n>.scope` and `wayland-session-bindpid@` missing from the session processes | both are Session processes (AD22; spec AM54, AM65); A7 now prints the bindpid unit |
| MAJOR 3: Send Signal skips the second sheet; `SIGSTOP` freezes the compositor or the shell | the second sheet for every signal to a session process, Stop refused for them (e; spec AM55) |
| MAJOR 4: start time checked before the pidfd is opened | one `/proc/<pid>` descriptor from the check to the signal (e, AD30; spec AM51); A2 now shows the path |
| MAJOR 5: the cost gates cover the CPU tab only, and 600 tasks already exceed 6 ms | A10 measures every read in C; the reads are spread (AD10) and every tab has its own threshold from those numbers (d; spec AM-P1, AM-P2) |
| MINOR: argv[0] titles of other users ("sshd: bob@pts/0") | other owners' names from `stat`'s short name, `cmdline` never read for them; control and bidirectional characters removed from every name (c, i, AD25; spec AM17) |
| MINOR: CPUWeight enables the `cpu` controller for every app; a service's drop-in outlives a restart | only uwsm's per-launch units; the side effect recorded (g, AD19; spec AM68) |
| MINOR: the parity rows for affinity and sampling are wrong | corrected: affinity can be undone and a user may sample their own processes; both stay out for other reasons (h; parity) |
| MINOR: AQ1's precedent (Preview ships « Visionneuse ») | stated in the header and in "Answers"; told to the owner; E38 and question 14 added to the visual review now |
| MINOR: unit names from desktop ids and `\x2d` escapes | AD20; spec AM65; A7 prints `main.py:3421` and an escape |
| MINOR: `ipc_inventory.sh` does not see callers in `apps/` | extended at step 3 (f; spec A-I1) |
| MINOR: A6's "absent: MEMORY_PEAK=" | a probe artifact: A6 now searches field names without "=" and finds all of them |
| MINOR: "Delete Usage History" deletes nothing | dropped (g, AD31; spec AM67) |

**Integrator's notes on the merge of step 0 (pull request #37, opus PASS on f950042), carried into step 1.**
| Note | Answer (step 1) |
|---|---|
| raise the soft `RLIMIT_NOFILE` (1 024 in the session) or cap the kept `/proc` descriptors (about 1 200 to 1 800) | both: the soft limit raised to the hard one (at most 16 384) and the kept descriptors capped at that limit less 256, opened and closed each time past it (d; spec AM-P2; `tst_sampler.cpp` "kept budget") |
| "A0 to A8" (ADR header, spec header) and the cost column's figures | A0 to A10; the column gives A10's figures in C, A8's for `smaps_rollup` only |
| AQ1's option A still calls the Preview precedent « Aperçu » | the option text stays as asked, annotated: Preview ships « Visionneuse », so the precedent holds for the English name only |
| `sampcost.c`'s Energy label | "(+ io + a fifth of the threads + a tenth of the descriptor lists)", as its formula already counted |
| the owner confirms AQ1 again (question 14) | asked in the session reply of step 1; confirmed by the owner on 2026-10-28 (relayed by the integrator on pull request #40): the name stays, owner-accepted risk; recorded in "Answers" and in the visual review's section 7 |

**Integrator's opus review of 949fc98 (step 1, 2026-10-28): FAIL, four MAJORs and five MINORs; five surviving mutants.**
What held: security and lifetime (the sampler reads only `/proc`, `/sys`, `login.defs` and `sock_diag`; writes nothing,
execs nothing, has no thread, timer or install rule). Each finding and its answer:
| Finding | Answer |
|---|---|
| MAJOR 1: AM-P2 fails on the reference CPU; the product costs 1.6 to 2.3 × A10's model (a 64 KiB buffer cleared at every read) | profiled (callgrind, perf, strace): no buffer cleared or copied; one read per per-process file; `stat` and `status` parsed in one pass; `io` kept; the owner's `fstatat` on arrival, exec and turn only (AD33); the Memory tab on `statm` with `status` in turns (AD32); the TCP dump searched without a table. Same run, same fixture: 0.9–1.1 × A10 on CPU, Memory, Energy and Network, 0.7–0.8 × on Disk. `activity_cost.sh --model` prints the ratios; the bench prints user and kernel time. A10 raises its own descriptor limit (at 1 024 it read no thread, descriptor or socket) |
| MAJOR 2: names never refresh after exec | an exec is seen from `stat` (its name, or the user's processes' code addresses, fields 26 and 27), and the process is named again (d; spec AM17); `ANameFollowsAnExec`, `AnExecThatKeepsStatsNameIsSeenByItsCodeAddresses` |
| MAJOR 3: a title written over argv[0] names the process | argv[0]'s basename only when argv[0] has no space and is the executable's or the invoked name, else the executable's basename, else `stat`'s (spec AM17; `processName`); the case in the fixture |
| MAJOR 4: the fixture hardcodes /tmp, silently | `$TMPDIR`, and an exception the test reports when the fixture cannot be made or written |
| MINOR 5: a failed `sock_diag` dump doubles TCP totals; a failed `opendir(/proc)` wipes every row and all state | a failed dump changes nothing; a failed listing keeps the last rows (`processesStale`) and all state (`AFailedTcpDumpChangesNoTotal`, `AFailedListingWipesNothing`) |
| MINOR 6: other owners' cgroup read and kept raw | not read; no cgroup path in a row at all (an own unit's kind, session and eligibility are kept) |
| MINOR 7: `socketOwner_` written, never read | removed |
| MINOR 8: turns by pid residue can be unbalanced | turns by order of arrival (`TheTurnsAreAsFullWhateverThePids`) |
| MINOR 9: AM47's GPU name and AM49's per-row device not built; AM38 and AM39 deferred without a record | AM49's devices are in the rows (`gpuDevices`); AM47's name, AM38 and AM39 (D-Bus) recorded in the spec as step 2 |
| Mutants M03, M06, M07, M09, M10 survive | each killed by a test (`TheClockTickIsTheMachines`, `MemoryColumnsFromStatus`, `TheMemoryTabReadsStatmAndStatusInTurns`, `ACounterThatWentBackGivesNoRate`, `TheUserShareIsNeverAboveTheBusyShare`) |

**Integrator's opus re-review of f68789c (step 1, 2026-10-28): FAIL, one MAJOR from this round's AD32, four MINORs.**
What held: every claim of 568d5c8 (cost 0.73–1.10 × A10 against its step-0 plan; exec and argv[0] titles on the real
kernel; the fixture; every MINOR; the limits of f68789c across the script, the spec, d, step1.md and STATE). Each finding
and its answer:
| Finding | Answer |
|---|---|
| MAJOR: AD32's swap goes stale after a tab switch: back on Memory, four fifths of the rows show the old swap | the tab's first sample after another tab or a pause of more than two intervals reads every `status` (AD32; spec AM30; `TheMemoryTabReadsEveryStatusAfterAnotherTabOrAPause`) |
| MINOR: the `--model` ratios compare different read plans | A10 prints a "step 1" plan, the sampler's reads (owners a tenth per sample, `statm` and a fifth of `status`, `io` kept, the TCP dump without listeners), beside step 0's (the limits' source); `--model` takes its ratios from the step-1 plan: 1.1–1.4 × (d; step1.md) |
| MINOR: `sampcost` warns "out of descriptors?" on the kernel's refusals | EMFILE and ENFILE counted apart from refusals (pid 1's `fd/`, non-dumpable agents), which are expected |
| MINOR: two exec-detection gaps | a `prctl(PR_SET_NAME)` rename is no exec for the user's processes (their code addresses decide; `AProcessThatRenamesItselfKeepsItsName`); an exec into the same program at the same addresses (non-PIE, or randomization off) stays a known limit (d; spec Known limitations) |
| MINOR: surviving mutants N06, N10, N13 (N03 without effect) | `AnExecIsSeenByItsCodeEndAlone` (N06); the real uid behind a root-owned directory read again in the owner's turn, `TheRealUidBehindARootDirectoryIsReadAgainInItsTurn` (N10); `ThePeakIsNeverBelowTheResidentSet` (N13) |
| Network has no headroom (45.2–46.6 ms in a loaded sandbox) | the dump leaves out listeners, TIME_WAIT and closed sockets (fewer sockets on a real machine; none on the fixture, whose 200 sockets are established); the verdict waits on the integrator's idle run |

**Integrator's AM-P2 runs on the reference machine, and the review of 19f5d4c: PASS, merged (2026-10-28).** On f68789c
(load 3.5 to 5, a review build running) every tab passed: CPU 16.5 ms (limit 17), Memory 12.9 (25), Energy 32.8 (40), Disk
10.9 (17), Network 35.8 (45). On 19f5d4c, at the merge (load 3.0 to 3.9): CPU 16.7, Memory 13.0, Energy 32.5, Disk 11.0,
Network 36.0, at 1.39, 1.22, 1.24, 1.31 and 1.07 × A10's step-1 plan. Network is settled; the follow-ups go with step 2:
| Note | Answer |
|---|---|
| 1. CPU passes with 0.3 ms to spare, at 1.39 × the step-1 plan, 14.5 ms of it in the kernel (f68789c): find the cut that brings it near 1.1 ×; does it read anything per process beyond `stat` that it does not show? | beyond `stat`, the CPU tab reads the owner (a tenth per sample, the User column), the descriptor lists (a tenth per sample: the GPU clients; Open Files comes with them), the real uid behind a root-owned directory (a tenth), and at every sample the `fdinfo` of every DRM descriptor found. Only that last read is outside A10, and this cloud machine has no GPU to measure it. A client is now read through one of its descriptors between two turns (d; spec AM45; `ADrmClientIsReadThroughOneOfItsDescriptors`), and A10 measures the DRM reads (every descriptor, one per client) and counts them in its step-1 CPU and Energy plans. The rest of the cut: open |
| 2. A pause right after the first Memory sample is missed (`memoryInterval_` is 0 after a full read): use the configured interval | the pause is told by the interval set, `Options::interval` and `Sampler::setInterval` (AM9, Normally by default; the window sets it at step 2); AD32; spec AM30; `APauseRightAfterTheFirstMemorySampleIsSeen` (your probe: Memory at 5 s, back at 3 605 s, every swap new) |
| 3. Mutant R13: `parseIo` accepts a line with one of its two byte fields | each byte field is one bit, and both are needed: one alone, or one twice, is no `io` (`ProcParse.Io`) |
| 4. Carried from step 1: AM47's GPU name, AM38, AM39 | step 2 |

**Step 2a, pull request #47: the integrator's review of 983b7de (PASS with a condition) and nested pass on 983b7de and
bd50b9c (2026-10-29).** The stop on minimize is proven nested: the sampler's thread stays flat minimized and on another
Desktop, and resumes on restore; WAYLAND_DEBUG shows one more toplevel state (`suspended`) on minimize, as AD35 says.
| Note | Answer |
|---|---|
| Condition: the stop on minimize rests on what the compositor sends; say which in the ADR | AD35: the xdg_toplevel `suspended` state, read in Hyprland 0.56.2's and Qt 6.11.2's sources; A-W1 drives Qt's side (unexposed, then minimized); proven nested |
| MINOR: an amdgpu client idle at its turn is never picked | picked by its identity, engine lines or not (d; `AClientIdleAtItsTurnIsPickedAndItsWorkShows`) |
| MINOR: mutants L03, L05, L09, J01 survive | four cases (`step2a.md`); 13 of 13 mutants of the round caught |
| NITs: the entry's apostrophe; no tooltip on the tabs and the search field (AM3) | `Moniteur d’activité`; Grassfield.Ui's `Tooltip` under each control (`test_toolbarTooltips`) |
| MAJOR (nested): a second titlebar, the `gf-client-chrome` rule lacks `org.grassfield.Activity` | added there and to the maximize exemption; `client_chrome_rules.sh` checks that every app making a ChromeTagger is in the rule, under each app id it sets (Glance keeps its own rule), with a negative control |
| MINOR (nested): a second launch leaves a minimized window minimized | the integrator chose the Dock's path: `dock reopen <desktop id>` (AD34), called by the app when its window is off screen (`activateWindow`, A-W1); `DockModel.windowsOf`; the IPC inventory counts an app caller built on `shellIpcArgs()`, with two selftests |
| Cost: CPU 17.93 ms against 17 at load 3.9, 1.06 × A10's step-1 plan | **Integrator's decision**: AM-P2's limits are re-based on A10's step-1 plan, × 1.3 (d; spec "Performance"). `activity_cost.sh` runs A10 before and after the product on the same fixture, takes each tab's worse step-1 plan, prints the plan, the limit and the ratio, and fails a tab over 1.3 ×; `--model` is accepted and changes nothing. The reference machine's figures come from the integrator's run at idle before the merge |
| Check of 737cdb0: Disk at 1.27–1.35 × its step-1 plan against 1.3; find what it spends beyond the plan and cut it to about 1.15 × | the Disk tab reads exactly the plan's files (strace: per sample `stat` of every process, `io` of the own ones, a tenth of the owners, the listing, `diskstats`). A10 now also reads them in one pass, in the sampler's order: 1.20–1.44 × the summed plan here, whose parts are each measured alone with warm caches; the product is 1.11–1.16 × that one pass. Reading `io` in a second pass costs more (2.55–2.64 against 2.38–2.53 ms). So 1.15 × the summed plan would need the product faster than C doing the same reads: put to the integrator |
| Check of f2ff9a0, MAJOR: a second launch toggles the maximized state (`setWindowStates(... & ~Minimized)` made Qt send `unset_maximized`, which Hyprland toggles) | `activateWindow` leaves the states alone and clears only a Minimized state Qt still holds; A-W1 counts the platform's state requests during a second launch, normal and maximized: none (the old code asked once each time and fails it) |
| Check of f2ff9a0: Disk 1.23–1.28 × its step-1 plan on the i5; cut it to about 1.15 × | callgrind: of the Disk tab's user-mode instructions, `parseStat` 56 %, `parseIo` 20 %, the loop 9 %. The product with that work taken out (its loop reading the same files, parsing and building nothing) costs 2.26–2.29 ms here against a summed plan of 1.62–1.83 ms (1.25–1.41 ×) and A10's one pass 1.93–2.16 ms; the whole product 2.27–2.53 ms. The parsing and the rows are 0–10 % of the sample: no cut there reaches 1.15 × the summed plan, which the reads alone exceed. Put to the integrator again, with the reads-only floor |
| **Integrator's decision on Disk's reference** (after the reads-only floor) | AM-P2: Disk's limit is 1.3 × A10's one-pass Disk line, the other tabs keep the summed step-1 plan. `activity_cost.sh` takes Disk's plan from the one-pass line (the worse of A10's runs before and after the product) and prints both Disk lines; here Disk 1.19 × its one pass (1.97 against 1.66 ms). A cheaper way to read the same files is for 2b |

**Step 2b, from main b345334: the integrator's closing comment on pull request #47 (2026-10-29).**
| Note | Answer |
|---|---|
| Blocking: Disk at most 1.15 × its one-pass line, measured at a load under 2 | a `stat` or `io` line identical to the process's last one is not parsed again (most processes are idle between two samples), and `parseStat` clears the code addresses it does not read; the parsers copy only the bytes they read, the name's end is looked for near its start, and the sweep for ended processes runs only when one ended. callgrind, the Disk tab on A10's fixture: 2.86 M to 0.61 M instructions a sample. `activity_cost.sh` gates Disk at 1.15 × its one pass and does not count a run started at a load average of 2 or more; here (load 0.7–0.9) Disk 1.00–1.08 × its one pass, main 1.13–1.19 × |
| `main.cpp` takes the bus name before `engine.load`, and a second launch waits 2 s at most: two windows | AD34: `claimOrHandOver` takes the name, or calls the running app's `Activate` with the token and waits up to 25 s; it leaves on the answer and on any error but "no owner", and runs only when the name has none (`ALaunchTakesTheNameOrHandsItsTokenOverAndLeaves`, on a private bus) |
| `activityapp.cpp`: `startDetached` without a timeout | `runWithTimeout`, killed after `kShellIpcMs` (5 s) as in Settings (`AShellCallIsKilledAfterItsTime`) |
| `DockModel.js`: `isFilesId` compares with case, the comment says without | `windowsOf` compares the normalized ids (`tst_dockmodel.qml`, `ORG.grassfield.files.desktop`) |

**Step 2b, pull request #53: the integrator's opus review of 831f752 (PASS on correctness, three MINORs, NITs;
2026-10-29).** The line cache is correct (its key is the whole line and the code flag; old and new parsers agree on 20 757
records); 9 of 15 mutants killed.
| Note | Answer |
|---|---|
| MINOR 1: a cache hit that stopped restoring `writeBytes` would survive | `AnUnchangedLineIsNotParsedAgain` checks the write side: bytes written kept, both rates 0, then the write rate |
| MINOR 2: `kShellIpcMs` copied from Settings | one constant in `apps/runmode.h`, beside `shellIpcArgs()`, for both apps |
| MINOR 3: `DockModel.isFilesId` compares with case | it compares without case, as `windowsOf` and the entry lookup; `tst_dockmodel.qml` (a key of another case gives its windows to the Files tile) |
| NIT: six surviving mutants (the seen count, a key without the start time or the code flag, the NUL, a 120-byte io buffer, the reuse branch) | a case each: `AnEndedProcessIsSweptBesideAKernelThread`, `AReusedPidWithTheSameLineButItsStartIsAnotherProcess`, `TheCodeAddressFlagIsPartOfTheCache`, `StatEndsWhereItsTextEnds`, `IoOfABusyProcess`; the seven mutants (with MINOR 1's) each killed |
| NIT: the load is read after the build | read just before the measures, the worse phase counts, printed again beside the verdicts |
| NIT: an idle fixture favours the cache | `activity_cost.sh --changing 10` (the default): Disk measured again with every tenth process changing its stat and io lines between samples (the bench pokes them outside the measured time), against A10's one pass on the same fixture poked the same way between its rounds (reading a process that just ran costs any reader more), at 1.15: 1.06 and 1.11 × here |

**Step 2b, pull request #53: the integrator's opus review of 91dcb63 (FAIL: three MAJORs, NITs; 2026-10-29).** 25 of 27
mutants killed; the integrator's decision: until the owner's system and the packages move to Qt 6.12 together, Grassfield
code loads and passes its checks on Qt 6.11.2 too, and a Qt 6.12 API is used only behind a guard.
| Note | Answer |
|---|---|
| MAJOR 1: `ProcessList.qml` sets `Accessible.expandable` and `.expanded`, which Qt 6.11.2 lacks: the window does not load | set from `Component.onCompleted` only when the attached object has them; A-W1 checks the state on Qt 6.12, and every check runs on Qt 6.11.2 too (`step2b.md`) |
| MAJOR 2: with transparent huge pages `always`, the changing fixture's stat lines seldom change | its region is `madvise(MADV_NOHUGEPAGE)`; `activity_cost.sh` fails when fewer stat or io lines are parsed a sample than 90 % of the changing processes (shown failing on a huge-page build) |
| MAJOR 3: the battery's times count to the last battery state, set only when it changes | each sample moves that time; a case checks the time and the graph between two states |
| NIT: `windowsOf` strips `.desktop` with case; two surviving mutants; the PSS range and 1.60 % at 1 s | without case, with a case; a case each (the vendor's end, the pruning); −12 to +292 kB, and the 1.60 % stated as a miss here |

**Step 2c, pull request #63: the integrator's opus security review of 1153365 (PASS, four MINORs, NITs; 2026-10-30).** Only
the user's own processes are signalled, the Kernel row is refused twice, session processes get the warning and never Stop,
no recycled pid can be hit, only the eleven signals are accepted; C++ mutants 23 of 25 killed (one equivalent), QML 7 of 8.
| Note | Answer |
|---|---|
| MINOR 1: Send Signal's dev guard untested (mutant M20) | `TheDevGuard` sends Terminate with no root: refused, nothing sent |
| MINOR 2: the A-W2 cleanup SIGKILLs pids already reaped | only a child `waitpid` still answers for is signalled |
| MINOR 3: `activity_actions.sh` keeps `QT_QPA_PLATFORMTHEME` | unset, as `scripts/dev/test.sh` does |
| MINOR 4: a command run in a terminal is refused by Quit (AD43) | the integrator's decision, built: a controlling terminal and a parent in the same app unit get `SIGTERM`; the unit's own process waits for step 3 (`ATerminalCommandIsQuitBySigterm`, a pseudo-terminal's child) |
| NITs: an empty `/tmp` directory after the pid-reuse case; the guard's walk from the parent read at the sheet's opening; "can't force quit itself" in Send Signal and its French; mutant Q08 | the test makes and removes the directory; the walk starts from the parent read again through the descriptor; Send Signal says "This app can't send a signal to itself.", the French reads « Cette app ne peut pas forcer sa propre fermeture. »; `test_sendSignal` checks that Cancel releases the processes |

**Step 2c, pull request #63: the integrator's notes at the merge (2026-10-30), answered in step 2d.**
| Note | Answer |
|---|---|
| NIT: `actions.cpp:106-107` reads the terminal's parent unit by path, from the pid read when the sheet opened | `ProcessHandle::parentCgroup`: the parent's pid read again through the process's descriptor, the parent's `/proc` directory opened, its stat checked (not younger than the process: a reused pid, AD40) and its cgroup read through that directory; `TheParentsUnitIsNeverAYoungerProcesss` (a younger parent, a reparenting, an ended parent) |
| NIT: `currentPpid()` has no test (mutant T7) | `TheParentIsReadAgainThroughTheDescriptor`: a grandchild orphaned under the test as subreaper; `ppid()` keeps the first parent, `currentPpid()` and `parentCgroup()` follow the new one; T7 killed (`step2d.md`) |
| MINOR and NIT for the design lane: the shared Sheet's destructive label in dark, the sheet against its window, the generic executable icon | the design lane's (Grassfield.Ui), not this one's; listed in STATE |
| For later nested passes: the nested session's rows are not session processes in a dev pass; sort by PID | noted in `step2d.md` for the nested pass of step 2d |
