# Activity Monitor spec · apps-engineer (app), shell-engineer (projection, IPC, Dock tile) · owner brief 2026-10-28
Decision record: `docs/decisions/ADR-0038-activity-monitor.md` (owner questions AQ1 to AQ7, decisions AD1 to AD31). Parity
row by row: `docs/audits/activity-2026-10-28/parity.md`. Evidence of the kernel facts: `docs/audits/activity-2026-10-28/`
(probes A0 to A10). The app is "Activity Monitor" / « Moniteur d'activité » (owner, AQ1; needs legal review); this spec says
"the app". Internal names: `apps/activity`, `grassfield-activity`, `org.grassfield.Activity`.

Status: step 0 (docs). Requirements are numbered AM1 to AM79, gates AM-P1 to AM-P4; each names the step that builds it
(ADR-0038 "Delivery order", owner AQ7: macOS first). The owner's answers of 2026-10-28 are built in: AQ2 TCP only and
labelled, AQ3 the Energy Impact index, AQ4 other owners' processes shown read-only, AQ5 End Task behind a setting, AQ6
Ctrl+Shift+Esc. Revised after the integrator's opus review of e3882de (ADR-0038 "Review history"); the changed requirements
say "review of e3882de". Step 0 is merged (pull request #37). Step 1, the sampler without a window (AM20 to AM49's data,
AM79's fixture roots as test options; AM-P2 measured), is built in its own pull request: its results are in
`docs/audits/activity-2026-10-28/step1.md`, and the places it changed say "step 1"; those the integrator's opus review of
949fc98 changed say "review of 949fc98", and those of its re-review "review of f68789c". Steps 2a to 2c are merged (pull
requests #47, #53 and #63); step 2d, Inspect, is built in its own pull request (`docs/audits/activity-2026-10-28/step2d.md`;
ADR-0038 AD45 to AD47), and the places it changed say "step 2d".

## macOS reference behavior (Apple's Activity Monitor User Guide, macOS 27; described in words, no Apple image committed)
- One window: a toolbar with the Stop button, the Info button and an action menu, five tabs (CPU, Memory, Energy, Disk,
  Network), a search field; the process table; the summary of the tab at the bottom of the window.
- CPU: System, User and Idle shares, the CPU load graph, Threads and Processes. Memory: the Memory Pressure graph, Physical
  Memory, Memory Used (App Memory, Wired Memory, Compressed), Cached Files, Swap Used. Energy: Energy Impact ("lower is
  better"), 12 hr Power (laptops), App Nap, Preventing Sleep, Graphics Card; at the bottom the battery's charge, time
  remaining or until full, time on battery or on AC, Battery (Last 12 hours). Disk: reads, writes, data read and written,
  per second, graph IO or Data. Network: packets and data in and out, per second, graph Packets or Data.
- View menu: Columns, Dock Icon (application icon, or a live CPU, CPU history, network or disk graph), Update Frequency
  (every 5 seconds by default), the process filters (All Processes; All Processes, Hierarchically; My Processes; System
  Processes; Other User Processes; Active Processes; Inactive Processes; GPU Processes; Windowed Processes; Selected
  Processes; Applications in last 12 hours; Processes, by GPU), Inspect Process, Quit Process, Send Signal to Process.
- Window menu: CPU Usage, CPU History, GPU History.
- Quit ("quits when it's safe to do so") and Force Quit (ends at once, data may be lost); a hung process is "(Not
  Responding)" in red; a process of another user needs an administrator.
- A process's details: double-click or the Info button.

## Windows 11 reference (what is taken; ADR-0038 g)
Processes grouped by type with expandable groups; Performance (CPU overall or per logical processor, memory, disk, network,
GPU, each with details); App history (per app since a date, with a delete action); Efficiency mode (a process's lower
priority, refused for the system's own); columns from the header; search by name or PID; End task from the taskbar's menu
(a switch, off by default); Ctrl+Shift+Esc. Not taken: ADR-0038 h and the parity matrix.

## Purpose and non-goals
Purpose: let the user see what their computer is doing, find what is slow, hot, hung or heavy, and stop it, with macOS 27's
window and the most useful Windows 11 views, at a cost the user does not notice.

Non-goals: root code or polkit actions; any action on another owner's process (AQ4: read-only); stack sampling and
diagnostics; editing login
items (Settings does it); a background collector; any network access.

## Terms
- **Sample:** one read of the counters at the update frequency. A **rate** is the change between two samples divided by the
  wall time between them (`CLOCK_MONOTONIC`).
- **Own process:** real uid equals the app's uid (`/proc/<pid>/status` `Uid:` first field). On the tabs that do not read
  `status`, the `/proc/<pid>` directory's owner (the effective uid; root for a non-dumpable process) stands in for it, and
  `status` is read for the processes whose directory says root and whose `stat` flags do not say kernel thread.
  **Other owner's process:** any other uid. **System account:** a uid below `UID_MIN` of `/etc/login.defs` (1000 when the
  file says nothing). **Kernel thread:** `PF_KTHREAD` (0x00200000) in `stat` field 9; kernel threads are never listed one
  by one (AM20a).
- **Row identity:** (pid, start time) where start time is `stat` field 22. A pid with another start time is another process.
- **App unit:** the systemd unit uwsm made for one launch, from `/proc/<pid>/cgroup` (`0::` line): `app-<desktop>-<name>-<8
  hex>.scope` or `app-<desktop>-<name>@<8 hex>.service` under `app-graphical.slice` (ADR-0038 A7, AM65).
- **Runtime folder:** `$XDG_RUNTIME_DIR/grassfield/activity-<display>/`, `<display>` the last part of `WAYLAND_DISPLAY`
  with every character outside `[A-Za-z0-9._-]` replaced by "_" (one folder per display: a nested session never shares
  the real session's, review of e3882de).
- **Projection:** the shell's file `windows.json` in the runtime folder (AM60).
- **Writer:** the pid and start time a runtime file names; the file is stale when no process has both.
- **"—":** the kernel refused the read (another owner's or a non-dumpable process, A1) or the driver gives no such value.

## Functional requirements

### Window and navigation (step 2a)
- **AM1** One instance: launching the app while it runs brings its main window to the front, with the launch's activation
  token (ADR-0038 AD34: the session bus name `org.grassfield.Activity`). Closing the main window quits the app (AD17).
- **AM2** The main window opens at its last size (`activity.json`; Wayland places windows, so there is no position), else at
  the token size `activity.windowWidth` × `activity.windowHeight`, never smaller than `activity.windowMinWidth` ×
  `activity.windowMinHeight`. Opaque window, ADR-0024 radius, unified toolbar (ADR-0015).
- **AM3** Toolbar, left to right: the traffic lights; the title (the app's name) with the current view as subtitle; the
  Stop button (Quit Process, enabled with a selection of own processes); the Info button (Inspect, enabled with one row);
  the action menu (…: Quit Process, Inspect Process, Send Signal to Process…, Efficiency Mode, Copy); the segmented control
  CPU, Memory, Energy, Disk, Network; the search field. Every control has a tooltip, an accessible name and keyboard
  focus. Step 2d: the Info button sits between Stop and the action menu, in their glass capsule (macOS 27).
- **AM4** The tab chosen is remembered. Each tab has its own columns, sort and summary.
- **AM5** The summary area at the bottom of the window has the token height `activity.summaryHeight`; it holds the tab's
  figures (label and value pairs, tokens' type scale) and its graph. Its graphs and the table update at the same sample.
  Step 2b, left to right as macOS: CPU — System, User, Idle | CPU Load | Threads, Processes; Memory — Memory Pressure |
  Physical Memory, Memory Used, Cached Files, Swap Used | App Memory, Wired Memory, Compressed; Energy — Energy Impact
  (with a battery: | its figures | Battery (Last 12 hours)); Disk — Reads in, Writes out and their rates | the IO or Data
  graph | Data read, Data written and their rates; Network — Packets in, Packets out and their rates | the Packets or Data
  graph | Data received, Data sent and their rates. A figure that the graph draws has a square of its colour
  (`activity.swatchSize`) before its label (ADR-0038 AD38). Every graph keeps `activity.historySamples` samples, each tab's
  at every sample whichever tab is shown (AD37); a rate the sampler could not give is a gap, never a zero.
  Drawing (audit apps-misc, round 2): every graph is a `GraphItem` (`src/graphitem.h`, registered as
  `Grassfield.Activity`; `qml/Graph.qml` makes it and resolves the colour names): filled bands without a line, their edge
  antialiased by a coverage strip half a device pixel wide, as the Qt Quick Shapes graph it replaces looked. Its triangles
  live in a ring of one block per sample (`src/graphgeometry.h`), in coordinates that slide with one transform: a new sample
  writes its own block, the one before it and the two at the left edge, and clears the one that left; a new scale, size or
  style, or an edited value, rebuilds the graph. One exception to "as before": two Memory Pressure bars of one level no
  longer show the white seam the Shapes' odd-even fill left where they overlap. The software scene graph paints the same
  shapes with QPainter. Checked by `tests/unit/activity/qml/tst_graph.cpp`: the vertex data, the ring against a full
  rebuild at every one of 400 samples per style, and the pixels against the former graph (offscreen, and on a GPU scene graph
  under Xvfb with Mesa: mean difference 0.3 to 1.8 of 255, under 0.4 % of pixels off by more than a third).
- **AM6** Menus: the app menu (About, Hide, Quit), File (Close Window), Edit (Copy, Select All, Find), View, Window, Help,
  exported to the menu bar (T1, `apps/globalmenu.h`). There is no settings window: the View menu holds the options (macOS).
- **AM7** Light and dark appearance and the accent follow the session; table rows alternate with the token fill
  `activity.rowAlternate`; graphs use tokens only, a colour per appearance (`color.dark` and `color.light`:
  `activityGraphSystem`, `activityGraphUser`, `activityGraphRead`, `activityGraphWrite`, `activityGraphIn`,
  `activityGraphOut`, `activityGraphBattery`, `activityPressureGreen`, `activityPressureYellow`, `activityPressureRed`),
  each holding A2's 3:1 against the graph's background (the group fill) and the window in both appearances
  (`tests/visual/test_contrast_tokens.py`); sizes `activity.summaryHeight`, `graphWidth`, `figureWidth`, `swatchSize`,
  `historySamples`, `treeIndent`.
- **AM8** While the window is hidden or minimized no per-process sample is taken (AM-P3). Back on screen, the next sample
  comes at once; rates restart from it (no rate is drawn from a gap): its rate columns show "—", and the sample after it
  comes one second later rather than a whole interval (ADR-0038 AD35).
- **AM9** View > Update Frequency: Very Often (1 sec), Often (2 sec), Normally (5 sec), default Normally; the choice is
  remembered and applies to every window of the app.

### The table (step 2a; Hierarchically and the grouped views at step 2b)
- **AM10** A row: the icon (the app's icon for a process of an app, a generic executable glyph otherwise, 16 pt; ADR-0038
  AD36: the theme icon its launch unit's desktop entry names), the name,
  then the tab's columns; PID and User are default columns on every tab (macOS). Another owner's row is drawn like the
  others (macOS); only its actions differ (AM50). A click on a header sorts by it; a second click reverses. Defaults: CPU by % CPU, Memory by
  Memory, Energy by Energy Impact, Disk by Bytes Written, Network by Sent Bytes, each descending.
- **AM11** Selection: one or several rows (Shift, Ctrl). The selection follows its processes (row identity) across samples
  and sorts; a process that ends leaves the selection. The scroll position never jumps on a refresh.
- **AM12** Views (View menu, one checked; the subtitle names it): All Processes (default); All Processes, Hierarchically
  (AM13); My Processes (own); System Processes (system accounts and the Kernel row); Other User Processes (other owners
  that are not system accounts); Active Processes (CPU share above 0 in the last sample); Inactive Processes (the others);
  GPU Processes (with a GPU client); Windowed Processes (owning a window per the projection); Selected Processes (the rows
  selected when chosen, kept until another view); Processes, by Type (AM65); Processes, by GPU (AM49).
- **AM13** Hierarchically: a tree by parent pid (`stat` field 4); a process whose parent is not listed is a root; rows have
  disclosure triangles; expansion is kept across samples. Step 2b (ADR-0038 AD40): a parent not older than its child (a
  reused pid) is not its parent, and a row no root leads to is a root; each level is sorted by the sort column; the
  search keeps a row that matches and every row above it; the triangle, or Right and Left, open and close a row; a row is
  indented `activity.treeIndent` per level; every row starts expanded.
- **AM14** Search: a live filter (no Return needed), case-insensitive, matching the process name, the app name, the user's
  name, the command (own processes only, AD25) or a PID that starts with the digits typed. Ctrl+F focuses the field, Esc clears it. In a grouped view a
  group stays when one of its processes matches.
- **AM15** Columns: View > Columns lists the current tab's optional columns, checked when shown; the header's context menu
  lists the same. The name column cannot be hidden. Widths are resizable; columns, widths and order are remembered per tab.
- **AM16** Values: sizes in the session's locale with the unit scale Files uses (kB, MB, GB, decimal), times as `h:mm:ss.ss`,
  shares with one decimal, "—" where Terms say so. A column with no value for any row still shows its header.
- **AM17** Names and icons: a process owning a window (projection) takes its app's desktop entry name and icon; another
  process of the same app unit takes the app's icon and its own executable name; any other own process takes the basename
  of `cmdline`'s first word when that word has no space and is the executable's name (the `exe` link) or the invoked one
  (`stat`'s short name, the start of it when cut at 15 bytes), else the executable's basename (" (deleted)" removed), else
  `stat`'s short name: a title written over argv[0] (Chromium's and Electron's helpers, setproctitle, a login shell's
  "-bash") never names a process (review of 949fc98). After an exec (the same pid and start time, another image: for the
  user's own processes the code addresses of `stat` fields 26 and 27 changed; for another owner's, whose addresses read 0,
  `stat`'s short name changed) the name and the command line are read again. A new short name with the same addresses is a
  `prctl(PR_SET_NAME)` rename: the user's process keeps its name and command, as on macOS (review of f68789c). Another owner's process always takes `stat`'s short name: its
  `cmdline` is never read (a process can rewrite its `argv[0]` into a title such as "sshd: bob@pts/0", review of e3882de).
  Every name and command line shown has its control characters (Unicode Cc) and format characters (Cf: the bidirectional
  embeddings, overrides and isolates U+202A–U+202E and U+2066–U+2069, the marks U+200E and U+200F, zero-width characters)
  removed before display, so no process can reorder or hide text in a row. A name is plain text (no markup), elided in the
  middle.
- **AM18** Rows of processes that ended go at the next sample; new processes appear at the next sample in sort order.
- **AM19** Edit > Copy (Ctrl+C) copies the selected rows as text: the visible columns' headers, then one line per row,
  values separated by tabs, as shown.

### CPU (step 1 data, step 2 window)
- **AM20** % CPU = Δ(utime + stime) of the whole thread group (`stat` fields 14 and 15) ÷ (Δt × `CLK_TCK`) × 100: a share of
  one logical processor (can pass 100, AD4). The first sample of a process shows "—" in rate columns.
- **AM20a** Kernel row (AD25): one row "Kernel" (fr « Noyau »), user root, PID "—", whose % CPU and CPU Time sum every
  kernel thread's (`stat` only); Threads = their number; other columns "—". It counts in System (AM29) and System Processes
  (AM12). It cannot be selected for an action.
- **AM21** CPU Time = utime + stime since the process started, `h:mm:ss.ss`.
- **AM22** Threads = `stat` field 20.
- **AM23** Wake Ups (optional): Δ of `voluntary_ctxt_switches` summed over `/proc/<pid>/task/*/status` ÷ Δt, for own
  processes. Read while the column or the Energy tab is shown, one fifth of the processes per sample in turn (a new process
  at its first sample; the turns go by order of arrival, not by pid, so each sample reads as many, review of 949fc98), each rate taken over that process's last five samples (A10: every thread at every sample would
  cost 15–18 ms on the reference fixture, review of e3882de). Another owner's process shows "—".
- **AM24** % GPU and GPU Time: AM48.
- **AM25** Open Files (optional): the entries of `/proc/<pid>/fd`, re-counted at most every 10 s per process.
- **AM26** Kind (optional): App, Background or Session (AM65).
- **AM27** Status (optional): Not Responding (projection), Efficiency Mode (AM68), Stopped (`stat` state T), Zombie (Z);
  empty otherwise. The name of a process that does not respond carries " (Not Responding)" (fr « (ne répond pas) », the
  string the Force Quit panel uses) in `colors.danger`, in every tab (macOS).
- **AM28** Command (optional): `cmdline`'s words joined by spaces, elided at the end, sanitized as AM17, for own processes;
  "—" for another owner's process, whose `cmdline` is never read (AM17), and for a process that refuses it.
- **AM29** Summary: System, User, Idle (AD5: User = Σ % CPU of own processes ÷ number of logical processors, System =
  non-idle share of `/proc/stat`'s `cpu` line minus User, never below 0, Idle = `idle + iowait` share); the CPU Load graph
  (System and User stacked, `activity.historySamples` samples); Threads = the total of `/proc/loadavg`'s fourth field;
  Processes = the number of numeric entries of `/proc`.

### Memory (step 1 data, step 2 window)
- **AM30** Memory = `RssAnon + VmSwap` (AD6). The Memory tab reads `statm` of every process at each sample (resident less
  file and shared memory is `RssAnon`; A10: 0.6 µs per process) and `status` of one fifth of them in turn, a new process at
  once, for `VmSwap` and `VmHWM`, which therefore show at most five samples late (AD32, review of 949fc98; step 0 read
  `status` of every process at 6.7–7.6 µs each); the other tabs read neither. The tab's first sample after another tab, or
  after a pause of more than two intervals (as set, AM9; review of 19f5d4c), reads every process's `status` once, so the
  bound holds when the user comes back to it (review of f68789c).
- **AM31** Optional: Real Memory (`VmRSS`, `statm`'s resident), Private Memory (`RssAnon`), Shared Memory (`RssFile +
  RssShmem`, `statm`'s shared), Compressed Memory (`VmSwap`; titled Swapped Memory under AM34), Peak Memory (`VmHWM`, never
  shown below Real Memory), Page Ins (`stat` field 12, major faults), Threads, PID.
- **AM32** Summary (AD7): Physical Memory, Memory Used, App Memory, Wired Memory, Compressed, Cached Files, Swap Used, from
  `/proc/meminfo`, `/sys/block/zram*/mm_stat` (third field, `mem_used_total`, summed) and `/proc/swaps`. App + Wired +
  Compressed = Memory Used (App is the remainder, never below 0).
- **AM33** Memory Pressure graph: height = `(MemTotal − MemAvailable) ÷ MemTotal`; colour red when `full avg10` of
  `/proc/pressure/memory` ≥ 5 or `MemAvailable` < 5 % of `MemTotal`, else yellow when `some avg10` ≥ 10 or `MemAvailable` <
  15 %, else green (provisional thresholds, pinned by tests, tuned at step 1 with a memory-pressure fixture in a container).
  Without `/proc/pressure` (kernel without PSI) the colour follows the memory left only.
- **AM34** "Compressed Memory" names the column when every active swap device in `/proc/swaps` is zram; otherwise it is
  "Swapped Memory" and Swap Used counts the non-zram devices.
- **AM35** Memory figures are bytes; the summary shows them with AM16's unit scale.

### Energy (step 1 data, step 2 window; AQ3)
- **AM36** Energy Impact (owner, AQ3): a relative index without unit, `EI = %CPU + %GPU + 0.02 × wake-ups/s + 1.0 × disk MB/s`
  (provisional weights; the step calibrates them against the laptop's `power_now` in an owner L2 run, then fixes and pins
  them). Shown with one decimal; never called watts. An unknown term counts as 0 (no GPU client, a first sample of wake-ups
  or disk bytes). Another owner's process shows "—": its `io` and descriptors are refused, so its index would leave terms
  out (step 1).
- **AM37** Average Energy Impact (optional): the mean of EI since the app opened or since the process started, whichever is
  later; the header's tooltip says so. Weighted by time over the samples that computed EI, that is while the Energy tab was
  shown (its reads are made only then, ADR-0038 d; step 1).
- **AM38** Preventing Sleep: "Yes" when the process holds a logind inhibitor whose What includes `sleep` or `idle` in `block`
  mode (`org.freedesktop.login1.Manager.ListInhibitors`, system bus, read when the tab is shown and at each sample), or when
  the projection marks one of its windows `idleInhibit`; "No" otherwise. Built with the window, step 2 (a D-Bus read; the
  projection's flag at step 3), not by the sampler of step 1 (review of 949fc98).
- **AM39** Summary: the Energy Impact graph (Σ EI of own processes). On a computer with a battery (UPower's DisplayDevice
  `IsPresent`): Remaining charge (`Percentage`), Time remaining (`TimeToEmpty`, "Calculating…" at 0) or Time until full
  (`TimeToFull`), "Battery Is Charged" when full, Time on battery or Time on AC (from the last state change in UPower's
  history), and Battery (Last 12 hours) (`GetHistory("charge", 43200, 120)`). Without a battery only the graph shows.
  Step 1 gives the graph's sum (`Snapshot::energyImpact`); the battery part is UPower over D-Bus and comes with the window,
  step 2 (review of 949fc98). Step 2b (ADR-0038 AD39): the display device at each Energy sample, the history of the first
  `battery_*` device at most once a minute (and at once when the source changes); "—" for the time on battery or on AC
  when the twelve hours show no change; the graph takes only the samples that computed Σ EI (the Energy tab's).
- **AM40** Not built: App Nap, Graphics Card, 12 hr Power (ADR-0038 h).

### Disk (step 1 data, step 2 window)
- **AM41** Bytes Read and Bytes Written = `io` `read_bytes` and `write_bytes` since the process started (storage, not page
  cache); optional Read/s and Written/s (rates). "—" when `io` is refused.
- **AM42** Summary from `/proc/diskstats`, counting only whole physical disks (a `/sys/block/<name>/device` link exists: no
  loop, zram, dm or md device, no partition): Reads in (field 4), Writes out (field 8), Data read (field 6 × 512), Data
  written (field 10 × 512), each since boot, and per second; the graph shows IO (reads and writes per second) or Data (bytes
  per second), chosen by a pop-up above it (remembered: `activity.json` `diskGraph`). Reads and data read go above the
  graph's middle, writes and data written below it.

### Network (step 1 data, step 2 window; AQ2)
- **AM43** (owner, AQ2) Sent Bytes, Rcvd Bytes, Sent Packets, Rcvd Packets per process, headed "(TCP)": a `NETLINK_SOCK_DIAG`
  dump of TCP sockets (IPv4 and IPv6) with `tcp_info` (`tcpi_bytes_acked`, `tcpi_bytes_received`, `tcpi_segs_out`,
  `tcpi_segs_in`), each socket matched to the own process whose `fd/` holds `socket:[inode]` (descriptor lists re-read at
  most every 10 s and for new processes). A process's value = Σ over the sockets seen since the app opened (a socket's last
  values are kept after it closes). Descriptor lists are re-read in turn, one tenth of the own processes per sample, a new
  process at its first sample (A10: 2.1–2.4 µs per descriptor; every list at every sample would cost 14–16 ms on the
  reference fixture, review of e3882de; turns by order of arrival, review of 949fc98); a socket whose process is not known
  yet is counted once it is. A dump that fails (out of descriptors, say) changes no total: the last ones show again (review
  of 949fc98: read as "every socket closed", it doubled them). Another owner's
  process shows "—" (its descriptors cannot be read). A line under the
  table: "UDP traffic, such as some video, is counted only in the totals below." The dump leaves out listening, TIME_WAIT
  and closed sockets: a listener carries no bytes, a TIME_WAIT socket no owner, and a closed one's counters were kept when
  it left the dump (review of f68789c).
- **AM44** Summary from `/proc/net/dev`, every interface except `lo`: Packets in, Packets out, Data received, Data sent
  (since boot) and per second; the graph shows Packets or Data (a pop-up, remembered: `activity.json` `networkGraph`),
  received above its middle and sent below it.

### GPU (step 1 data, step 2 window)
- **AM45** GPU clients: each own process's DRM descriptors (`fd/` links to `/dev/dri/*`), found by the same turn as AM43
  (one tenth of the processes' descriptor lists per sample, a new process at its first sample); at each sample only the
  `fdinfo` of the DRM descriptors found is read: keys `drm-driver`, `drm-pdev`, `drm-client-id`, `drm-engine-<name>`,
  `drm-engine-capacity-<name>`, `drm-memory-<region>`; one client per (`drm-pdev`, `drm-client-id`) even when several
  descriptors share it. Between two descriptor turns only one descriptor per client is read (its lowest), and every DRM
  descriptor again as soon as one of those fails or names another client (ADR-0038 d).
- **AM46** Engine share of a client = Δ`drm-engine-<name>` (ns) ÷ (Δt × capacity); % GPU of a process = its busiest engine
  (Σ over its clients, capped at 100); GPU Time = Σ of its engines' times.
- **AM47** A system GPU's engine share = Σ over the user's clients on that `drm-pdev`, capped at 100 (the compositor is one of
  them); its name from `/sys/class/drm/card*/device` (vendor and device ids looked up in `/usr/share/hwdata/pci.ids` when
  present, else "GPU <n>"), its driver from the `driver` link. Step 1 gives the shares, `drm-pdev` and the driver; the name
  comes with the window, step 2, which shows it (review of 949fc98). Step 2b (ADR-0038 AD41): the card is the one whose `device` link ends in the
  pdev, read once per GPU; the name is the vendor's short name and the device's marketing name ("Intel UHD Graphics");
  "GPU <n>" names card n-1.
- **AM48** A driver without `drm-engine-*` keys gives "—" in % GPU and GPU Time, and no GPU in GPU History or Performance
  (verified on the owner's i915 at step 1, read-only).
- **AM49** Processes, by GPU (macOS 27): one group per GPU (`drm-pdev`) with its client processes; processes without a client
  are not listed in this view. Step 1: each row carries the devices it is a client of (`gpuDevices`, sorted); the view is
  step 2's. Step 2b (ADR-0038 AD40): a header row per GPU (its name, AM47; bold, no icon, never
  selected, passed over by the keyboard, collapsible), in pdev order, then its processes sorted and indented; a process
  of two GPUs is under both, selected and copied once; a GPU without a process the search keeps is not listed. This view
  and GPU Processes read the GPU clients on every tab.

### Quit, Force Quit, signals (step 2c, built: ADR-0038 AD42 to AD44, `docs/audits/activity-2026-10-28/step2c.md`; Quit of windowed processes through the shell at step 3)
- **AM50** Actions (Quit, Force Quit, Send Signal, Efficiency Mode) apply to own processes only: with another owner's row
  or the Kernel row in the selection they are disabled, the tooltip saying "You can only quit your own processes." (no
  administrator path, AQ4). Otherwise the Stop button, View > Quit Process (Ctrl+Alt+Q) and the row's context menu open the
  sheet "Are you sure you want
  to quit this process?" (several rows: "Are you sure you want to quit these %n processes?"), buttons Cancel, Force Quit,
  Quit; Quit is the default (Return), Esc cancels. Step 2c: the Stop button and the action menu share one glass capsule
  of the toolbar (macOS 27); the action menu and the context menu hold Quit Process, Inspect Process (step 2d, AM57),
  Send Signal to Process… and Copy (Efficiency Mode at step 4); a right click selects the row under the pointer first; the
  sheet names one process as "“%1” (PID %2)".
- **AM51** Before the sheet shows, the app opens `/proc/<pid>` as a directory descriptor (`O_DIRECTORY`) for each selected
  row, reads `stat` through it with `openat` and compares the start time with the row's; a row whose read fails (the process
  ended) or whose start time differs is dropped (none left: no sheet). The signal of AM52, AM53 or AM55 is sent with
  `pidfd_send_signal` on that same descriptor, which names one process for good: if it ended meanwhile the call fails with
  ESRCH (A2) and no other process can be hit (review of e3882de: a pidfd opened after the check left a gap). The
  descriptors are closed when the sheet closes.
- **AM52** Quit: a process owning windows (projection) → IPC `activity quit <pid>` to the shell (AM61); `ok`, the process
  gone or its windows gone from the projection → nothing more (the app may ask to save); `no-windows` → `SIGTERM` through
  AM51's descriptor; `refused`, none of these within 10 s (`qs` starting included; ADR-0038 AD49 as amended), or no
  projection for a process of an app unit → the sheet stays with "The process couldn't be quit safely." and only Cancel
  and Force Quit. A process without windows → `SIGTERM` through AM51's descriptor. A command run in a terminal (a controlling
  terminal, and a parent in the same app unit: not the process that started the unit) → `SIGTERM` (ADR-0038 AD43, the
  integrator's decision on the review of 1153365).
- **AM53** Force Quit → `SIGKILL` through AM51's descriptor. ESRCH (it ended) is silent; any other error shows "The process couldn't
  be quit." with the reason in the journal.
- **AM54** Session processes (AD22): the user's processes in units of `session.slice` or `session-graphical.slice`, in uwsm's
  `wayland-session-bindpid@*.service` (whatever its slice), in the login session's `session-<n>.scope` under
  `user-<uid>.slice`, or in the user manager's `init.scope` (review of e3882de: the bindpid unit and the login scope end the
  session too). Quit, Force Quit and Send Signal first show a second sheet "Quitting “%1” may end your session or stop part
  of it." (for a signal: "Sending a signal to “%1” may end your session or stop part of it."), buttons Cancel (the default)
  and Continue (destructive). The app refuses to signal itself from the table (its own row's Quit closes its window
  instead). Step 2c: the warning comes when the action is chosen, before the quit sheet or Send Signal's sheet (AD44).
- **AM55** View > Send Signal to Process… (one row): a sheet with a pop-up of Hangup (SIGHUP), Interrupt (SIGINT), Quit
  (SIGQUIT), Abort (SIGABRT), Kill (SIGKILL), Alarm (SIGALRM), Terminate (SIGTERM), User Defined 1 (SIGUSR1), User Defined 2
  (SIGUSR2), Stop (SIGSTOP), Continue (SIGCONT); Cancel and Send; the descriptor path of AM51. For a session process AM54's
  second sheet comes before the signal, and Stop is not in the pop-up at all: a stopped compositor or shell freezes the
  screen and the lock before sleep (review of e3882de). Stop is not offered for the app itself either. Step 2c: the sheet
  "Choose a signal to send to “%1” (PID %2).", Terminate chosen first; an error shows "The signal couldn't be sent.".
- **AM56** Dev guard (ADR-0019): in a dev session AM52 to AM55 and AM68 act only on a process a dev root names or one of
  its descendants; any other is refused with one "dev guard" journal line and the sheet says "Development session: only the
  nested session's processes can be quit." A root is a pid record of `scripts/dev/pidfile.sh` (the pid in a file, its
  start time in `<file>.start`) named by the dev plumbing variable `GRASSFIELD_ACTIVITY_DEV_ROOTS` (paths separated by
  ':'); none named, every action is refused. Step 2c (AD42): the nested compositor is not a root, since an app it or the
  nested shell starts is detached and so descends from neither (a test fixture names its own record).

### Inspect (step 2d, built: ADR-0038 AD45 to AD47, `docs/audits/activity-2026-10-28/step2d.md`)
- **AM57** The Info button, a row's double-click, View > Inspect Process and the action and context menus (Ctrl+I; one row,
  not the Kernel row): a window "<name> (<pid>)" per process (a second request brings it forward), refreshed at the update
  frequency while it is on screen (AM8's rule: a read at once when it comes back, then one a second later, which gives its
  % CPU, then one per interval). For another owner's process the window shows what `stat` and `status` give (the header,
  the Memory tab but Proportional Memory, Threads, CPU Time, Context Switches, Faults, Started, Nice, Scheduler Policy:
  step 2d, stat's field 41) and "—" elsewhere; Open Files and Ports says "The open files of another user's process can't be
  read." and the Quit button is disabled, its tooltip AM50's reason. Header: Parent Process (name and pid; a click inspects
  it; a parent younger than the process holds a reused pid, AD40, and shows "—"), Process Group (the leader's name and the
  pgid), User (name and uid), % CPU, Recent hangs (the number of times the projection marked it since the app opened;
  "—" without a projection, AM75: no made-up 0). The window closes when its process ends (AD45), and with the main window
  (AD17). Every read goes through the `/proc/<pid>` descriptor that AM51's start-time check opened, on the sampler's thread,
  and covers the header and the tab shown only (AD10).
- **AM58** Tabs: **Memory** (Real Memory Size `VmRSS`, Virtual Memory Size `VmSize`, Shared Memory Size `RssFile +
  RssShmem`, Private Memory Size `RssAnon`, Proportional Memory Size from `smaps_rollup` `Pss` read at most every 5 s, the
  swapped size `VmSwap` titled as the table's column (Compressed Memory, or Swapped Memory under AM34), Peak Memory
  `VmHWM`, never below Real Memory); **Statistics** (Threads, User and System CPU Time, Voluntary and Involuntary Context
  Switches summed over the threads' `task/*/status`, Minor and Major Faults, Read and Write Calls from `io`
  `syscr`/`syscw`, Started (date and time, from `/proc/stat`'s `btime`), Nice, Scheduler Policy (Normal, Real-time first
  in first out, Real-time round robin, Batch, Idle, Deadline), Unit (the systemd unit: the cgroup's last `.service` or
  `.scope`, else its last `.slice`), Command, Executable (`exe`), Working Folder (`cwd`)); **Open Files and Ports** (one
  line per descriptor, by number: a file's path, a pipe, a TCP or UDP socket with local and remote address and port, "*"
  for any address, a local socket's path, or the kernel's own name such as `anon_inode:[eventfd]`; sockets from the
  process's own network namespace, `/proc/<pid>/net/{tcp,tcp6,udp,udp6,unix}` through its descriptor (AD46: the app's
  `/proc/net` misses a sandboxed process's sockets); at most 10 000 lines, and a line saying how many more there are). A
  value the kernel refuses is "—"; an own process that is not dumpable refuses its descriptors too ("The open files of
  this process can't be read."). Every text a process chose (paths, the command, socket paths) is sanitized as AM17.
- **AM59** Buttons: Quit (AM50's sheet for this process alone, with AM51 to AM56's rules: the session warning, AD43, the dev
  guard). No Sample button. Environment variables are never read.

### The shell (step 3, built in the pull request of steps 2d to 5: ADR-0038 AD48 to AD52, `docs/audits/activity-2026-10-28/step3-5.md`)
- **AM60** Projection: while a toplevel with app id `org.grassfield.Activity` exists on its display, the shell writes
  `windows.json` in the runtime folder (folder 0700, file 0600, written to a temporary name then renamed):
  `{"v":1,"writer":{"pid":N,"start":N},"windows":[{"pid":N,"app":"<app id>","idleInhibit":bool}…],"notResponding":[N…]}`,
  at most 256 windows, from `Compositor.knownWindows()` after `Compositor.refreshToplevels()` on a window opening, closing or
  changing class, and from `NotResponding.marks`, coalesced over 250 ms. No title. The file is removed when the last such
  toplevel closes. When the shell stops it may stay (a reload keeps the same process, so the shell cannot tell a stop from
  a reload): the app drops it at its next reading, its writer being gone (review of 5bfd4419). The app reads it on change (inotify) and ignores it when stale (Terms: writer)
  or invalid (over 64 KiB, another `v`, a value of the wrong type). Step 3 (AD48): the shell's `ActivityLink`; the writer
  is the shell, named by the script that writes the file (its parent); the app reads the file again at each sample, so a
  crashed shell's file stops counting. It names a windowed process (AM17: its app's desktop entry name and icon), marks one
  that does not respond (AM27), lists Windowed Processes (AM12), counts Recent hangs (AM57) and adds a window's idle
  inhibitor to Preventing Sleep (AM38).
- **AM61** IPC target `activity`, function `quit(pid: int): string`, class action, caller `grassfield-activity`: refused
  (`refused`) for a pid ≤ 1; otherwise closes every window whose client pid is `pid` and that the shell can close
  (`Compositor.close`, as the Dock's Quit), from the window list as the shell last read it (read again at every window
  opened or closed, AM60), and answers `ok`, or `no-windows` when there was none. Never kills. Listed in
  `docs/specs/security.md` "IPC surface" and `tests/security/ipc_inventory.sh`. A shell reaches its own compositor's windows
  only (a nested session's shell, the nested ones); in a development session the app's dev guard (AM56) refuses a process
  outside the nested session before the shell is asked (review of 5bfd4419: the shell has no refusal of its own). Step 3
  (AD49, as amended): the app's Quit waits for the outcome, up to 10 s with `qs` starting included, the sheet taking no
  click or key meanwhile: "ok", the process gone or its windows gone from the projection close the sheet; "no-windows"
  sends SIGTERM through AM51's descriptor; "refused" or no outcome within the bound leaves Force Quit alone.
- **AM62** Dock tile graph: View > Dock Icon: Show Application Icon (default), Show Network Usage, Show Disk Activity, Show
  CPU Usage, Show CPU History. Other than the icon, the app writes `dock-tile.json` in the runtime folder (0600, renamed
  into place) at each sample: `{"v":1,"writer":{"pid":N,"start":N},"kind":"network|disk|cpu-usage|cpu-history",
  "samples":[…]}`, at most 32 samples, each a number or a pair in [0, 1] the app has scaled (network and disk: in and out over
  the window's maximum; CPU usage: one value, drawn as a 10-segment gauge; CPU history: pairs System and User), at most 2
  KiB. The Dock reads only its own display's runtime folder (a nested session's file never reaches the real Dock, review of
  e3882de), only for the `org.grassfield.Activity` tile while it is running; it rejects a file over 2 KiB, a `v` other than
  1, an unknown kind, a value out of range or a stale writer, and draws the graph over the tile with tokens
  (`dock.tileGraph*`), the running dot and badge unchanged. The app removes the file when the icon is chosen and when it
  quits. Step 3 (AD50): a live writer is one that owns one of the app's windows now; the graph is drawn on a dark plate
  with the dark palette's graph colours; off screen with a graph chosen, the app reads the system's files alone.
- **AM63** End Task (owner, AQ5; AD27): Settings > Desktop & Dock gains the switch "Show End Task in Dock menus" (fr
  « Afficher Fin de tâche dans les menus du Dock »), key `dock.endTask` in `grassfield.json` (boolean, default false; schema
  and settings contract). While it is on, the Dock menu of a running app (not the Files tile, a folder or the Trash) shows
  "End Task" (fr « Fin de tâche ») right after Quit (or after Force Quit when the app does not respond); it runs the menu's
  existing Option + Force Quit: the confirmation "Force quit “%1”?", then `Power.run("forcequit")` on every process of the
  app. With Option held, the menu shows Force Quit as today and no End Task (the two would do the same). The Force Quit panel
  is unchanged. Step 3 (AD51): `Launch.quitRows`; the switch is the Dock group's last.
- **AM64** Ctrl+Shift+Esc (owner, AQ6; AD28): `bind("CTRL + SHIFT + ESCAPE", "Activity Monitor", launch("activity"))` in
  `config/hypr/grassfield/bindings.lua`; `packaging/bin/grassfield-launch-key` gains the kind `activity`
  (`org.grassfield.Activity.desktop`, through `uwsm app`, its own scope; nothing in a nested dev session, as its other kinds);
  a running app comes to the front (AM1). The shortcut is listed with the others in Settings' keyboard shortcuts. Step 3
  (AD52): built, off on the lock screen as the other launch keys.

### From Windows 11 (step 4, built in the pull request of steps 2d to 5: ADR-0038 AD53 to AD56, `docs/audits/activity-2026-10-28/step3-5.md`)
- **AM65** Processes, by Type (AD26): groups with a count in their header, in this order: Apps, Background Processes,
  Session Processes (each for own processes), System Processes (system accounts and the Kernel row), Other Users (only
  when such a process runs). An own process is a Session process per AM54; else it is in Apps when its unit is under
  `app-graphical.slice` or it owns a window (projection); else in Background Processes. Apps has one sub-group per unit.
  Unit names (AD20, review of e3882de): `app-<desktop>-<name>-<8 hex>.scope` or `app-<desktop>-<name>@<8 hex>.service`,
  split at "-" and "@" (an escaped part holds neither: uwsm writes "-" as `\x2d`), `<name>` unescaped (`\xNN` to its byte);
  the sub-group's name and icon come from the window's app id, else the desktop entry whose id is `<name>` (a launch by
  desktop entry), else the one whose `Exec` basename is `<name>`, else `<name>` itself, sanitized as AM17.
- **AM66** Performance window (Window > Performance, Ctrl+5): a sidebar with one row per resource (CPU; Memory; each
  physical disk; each network interface but `lo`, Wi-Fi or Ethernet from `/sys/class/net/<if>/wireless` and `type`; each GPU
  with clients), each with a small live graph and its current value; the selected resource's large graph (`activity.
  historySamples` samples) and details:
  - CPU: Overall or Logical Processors (one small graph per `cpuN` line of `/proc/stat`, a pop-up), Utilization, Speed (mean
    `scaling_cur_freq`), Base Speed (`base_frequency` when present), Processes, Threads, Up Time (`/proc/uptime`), Cores and
    Logical Processors (`topology/`), L1, L2, L3 caches (`cache/index*/size`).
  - Memory: In Use, Available, Committed (`Committed_AS` of `CommitLimit`), Cached, Compressed, Swap Used, and a composition
    bar (In Use, Compressed, Cached, Free).
  - Disk: Active Time (Δ field 13 ÷ Δt), Read Speed, Write Speed, Average Response Time (Δ(fields 7 + 11) ÷ Δ(fields 4 + 8)),
    Capacity (`size` × 512), Type (SSD or HDD from `queue/rotational`), Model (`device/model`).
  - Network: Send and Receive throughput (two series), Interface, Kind, IPv4 and IPv6 addresses (`getifaddrs`), and for Wi-Fi
    the network's name from NetworkManager (system bus, read-only) and the signal from `/proc/net/wireless`.
  - GPU: one graph per engine (AM47), memory per region where `drm-memory-*` reports it, Driver.
- **AM67** App History window (Window > App History, Ctrl+6): a period pop-up (Last 12 Hours (default), Last 7 Days, Last 30
  Days) and a line "Resource use since <date> for <user>"; rows per app: name and icon, CPU Time, Memory Peak, Launches, Last
  Used; sortable. Source, read when the window opens and on the period's change: `journalctl --user -o json
  MESSAGE_ID=ae8f7b866b0347b9af31fe1c80b127c0 --since <start>` (records of the units AM65 names, under
  `app-graphical.slice`; fields `CPU_USAGE_NSEC` and `MEMORY_PEAK` as systemd 262 writes them, A6, checked on the owner's
  journal at step 4, read-only), plus each live app unit's `cpu.stat` `usage_usec`. Apps match AM65's naming. Nothing can be
  deleted (the journal is the system's record; Windows' "Delete usage history" is not offered, AD31, review of e3882de). No
  journal access (an error from `journalctl`) shows "Usage history isn't available." and nothing else.
- **AM68** Efficiency Mode (View menu, action menu, context menu; a checked item for the selected process): available only
  for an own process in a unit uwsm named for one launch under `app-graphical.slice` (AM65's names, with the random suffix),
  never a Session process (AM54) or a long-lived user service (its runtime drop-in would outlive a restart, review of
  e3882de). It sets the unit's CPU weight to the lowest systemd accepts (`CPUWeight=idle` where supported, else 1) with
  `org.freedesktop.systemd1.Manager.SetUnitProperties(unit, runtime=true, …)` on the session bus, and the unset value to
  turn it off. The first time, a sheet "Turn on Efficiency Mode for “%1”?" explains that the whole app runs at the lowest
  priority when the computer is busy, with "Don't ask again" (remembered), Cancel and Turn On. Status shows "Efficiency
  Mode" for every process of that unit while the unit's `cpu.weight` (read from its cgroup) is the low value, so a change
  made elsewhere shows too. Unavailable items are disabled, as macOS's menu items are, with no reason shown
  (no menu here shows a tooltip; decided under the owner's rule, ADR-0038 AD54); choosing the item when the unit no longer
  applies says why in a sheet ("This process isn't running as an app.", "This process is part of your session."). Side effect (ADR-0038 g): the first weight set makes systemd enable
  the `cpu` controller in `app.slice` and `app-graphical.slice`, so contended apps then share the processor app by app;
  step 4 records whether systemd turns it off again when no weight is set.
- **AM69** Window > Login Items… opens Settings on General > Login Items (`grassfield-settings --section=login` through the
  shell's launch path or `uwsm-app`); nothing of that pane is in the app.
- **AM70** Status column and Copy: AM27, AM19.

### Small windows (step 5, built in the pull request of steps 2d to 5: ADR-0038 AD56, AD57; AM73 not built, AD57)
- **AM71** Window > CPU Usage (Ctrl+2): a small window with one vertical bar per logical processor, current share,
  System and User stacked.
- **AM72** Window > CPU History (Ctrl+3): one small graph per logical processor; Window > GPU History (Ctrl+4): one graph per
  GPU (AM47); View > Clear CPU History (Ctrl+K) empties the CPU graphs.
- **AM73** Window > Keep CPU Windows on Top: those windows carry a toplevel tag the Grassfield session's Hyprland rules pin
  above other windows (AD23); without the rule the item is absent.

### Persistence, degraded behaviour, dev (every step)
- **AM74** `activity.json` (state, version 1, written by the app only, ADR-0020 row): window frames, tab, view, columns,
  widths and sort per tab, graph pop-ups, update frequency, Dock icon, "Don't ask again", App History's period. An unknown
  version or a broken file is set aside (renamed `.bad`) and defaults are used.
- **AM75** No shell: no projection (no "(Not Responding)", no Windowed Processes view, Quit as AM52), no Dock graph; everything
  else works.
- **AM76** No systemd user manager on the session bus: Efficiency Mode absent; App History shows AM67's message.
- **AM77** No UPower: AM39's battery part absent.
- **AM78** No `/proc/pressure`: AM33's fallback.
- **AM79** Fixture tree (tests only): in a dev session, `GRASSFIELD_PROC_ROOT` and `GRASSFIELD_SYS_ROOT` (dev plumbing,
  `runmode.h` `devValue`) point the sampler at a fixture tree; outside a dev session they are ignored.

- **AM77** (2026-11 audit, round 2) Off the window's thread and kept honest:
  - App History's journal answer is parsed, its live units' cgroups read and its apps resolved on the sampler's thread
    (`AppHistory::setWorker`); the window's thread only swaps the rows in, and a newer read makes an older answer unused.
  - The desktop entries of the app ids (each own row's unit, each window's app) are resolved on the sampler's thread with
    each sample (`SamplerWorker` `AppNames`): the scan of every `.desktop` file for a command-launched app never runs on
    the window's thread.
  - The processors' current speed and the uptime are read by the sampler (`ReadSystemSpeed`), only while Performance shows
    CPU; each logical processor's series are boxed only while a window draws them (CPU Usage, CPU History, Performance's
    logical processors).
  - "Data read/written", "Packets in/out" and the network and disk byte totals keep the last counters of a disk or an
    interface that went away (or restarted from zero): they never go back.
  - A TCP socket counts for one process: the one that holds it and held it first; one handed to another process counts
    for that one from the hand-over on, the first keeping its share; one inherited across a fork counts once.
  - The table sorts on each row's text made once per rebuild, and announces (`dataChanged`) only the rows whose shown
    values changed, in runs.

## Keyboard
| Keys | Action |
|---|---|
| Ctrl+F | focus the search field (Esc clears it) |
| Ctrl+I | Inspect the selected process |
| Ctrl+Alt+Q | Quit Process (the sheet) |
| Ctrl+C, Ctrl+A | Copy, Select All |
| Ctrl+1 to Ctrl+6 | the main window, CPU Usage, CPU History, GPU History, Performance, App History |
| Ctrl+K | Clear CPU History |
| Ctrl+W, Ctrl+Q | close the window (an Inspect window when it has the keyboard, step 2d), quit the app |
| Up, Down, Home, End, Page Up, Page Down, Shift+arrows | move and extend the selection |
| Left, Right | collapse and expand a tree row or group |
| Tab, Shift+Tab | toolbar controls, tabs, search, table, summary pop-ups |
| Ctrl+Shift+Esc | open the app from anywhere (AQ6) |
Shortcuts follow the other Grassfield apps' Ctrl-for-Command mapping and the menu shortcut style of ADR-0024 (symbols on a
Mac keyboard, text on a PC).

## Accessibility
- Table: role table, rows with role row and a name made of the process name and the visible values ("Firefox, 12.4 percent
  CPU, 1.2 gigabytes"), headers as column headers with their sort state.
- Graphs: an accessible name with the current values ("CPU load: system 8 percent, user 22 percent"), updated at most every
  5 s for screen readers.
- Sheets: focus on the default button; destructive buttons named as such. Every control keyboard-reachable with a visible
  focus ring (A1).
- Colour is never the only cue: "(Not Responding)" is text; the pressure level is also in the graph's accessible name and a
  label ("Memory pressure: normal, high, critical").

## i18n (en and fr)
Every visible string through `qsTr()`; fr complete (I1). French follows macOS's: tabs « Processeur », « Mémoire »,
« Énergie », « Disque », « Réseau »; « Quitter », « Forcer à quitter », « Pression de la mémoire », « Mémoire physique »,
« Mémoire utilisée », « Mémoire de l'app », « Mémoire résidente » (Wired), « Compressée », « Fichiers en cache », « Swap
utilisé »; « (ne répond pas) » as the Force Quit panel. Sizes and times in the locale's format.

## Refusals (what is refused, and what the user sees)
| Case | What the user sees |
|---|---|
| A process of another owner, or the Kernel row (AQ4) | actions disabled; tooltip "You can only quit your own processes."; "—" where the kernel refuses a read; no command line |
| A read the kernel refuses | "—" in that cell |
| Quit of a windowed process without the shell | AM52's message; Force Quit offered |
| A session process | AM54's second sheet before Quit, Force Quit or any signal; no Stop in Send Signal (AM55) |
| Efficiency Mode outside an app unit or for a session process | the item disabled, AM68's reasons |
| The app's own row | Quit closes its window; Force Quit and signals refused ("This app can't force quit itself.") |
| Dev session, a process outside the nested session | AM56's message |
| Open Files and Ports of another owner's process (step 2d) | "The open files of another user's process can't be read."; the Quit button disabled with AM50's tooltip |
| Open Files and Ports of an own process that is not dumpable | "The open files of this process can't be read." |

## Acceptance criteria (each mapped to a test; level)
| ID | Criterion | Test | Level |
|---|---|---|---|
| A-S1 | every formula of AM20 to AM47 on fixture `/proc` and `/sys` trees, including "—" cases and first-sample rates | `tests/unit/activity/tst_sampler.cpp` (gtest) | L0 |
| A-S2 | owners (own, system account, other user), the Kernel row, the My/System/Other views, other owners' "—" cells and hidden command lines, row identity across pid reuse | `tst_sampler.cpp` (fixture trees with three uids) | L0 |
| A-S2b | the same against the real kernel: a process of another uid (a test container with two users, as the probes) shows its CPU and memory, "—" for disk, and every action is refused. Step 1: its rows (not own, Other Users, the kernel's short name, no command line, no argv[0] title anywhere, memory read, no `io`, no descriptors) and the user's own row beside it; the refused actions join with step 2 | `tests/integration/activity_owners.sh` (container only) | L1 |
| A-S3 | AM33's levels at each threshold; AM32's sum; AM34's naming | `tst_memory.cpp` | L0 |
| A-S4 | AM54's and AM65's classification of fixture cgroup paths: a uwsm scope and a uwsm service in `app-graphical.slice` (Apps), `session.slice`, `session-graphical.slice`, `init.scope`, `wayland-session-bindpid@1234.service` in `background.slice` and a login `session-3.scope` (Session), `app.slice` services (Background); unit names from a desktop id and from a command with `\x2d` escapes, unescaped and matched (AD20) | `tst_units.cpp` (step 1; named `tst_kinds.cpp` before) | L0 |
| A-S5 | sock_diag parsing and socket-to-process matching (captured netlink replies) | `tst_netdiag.cpp` | L0 |
| A-S6 | AM51's path: `stat` read through the `/proc/<pid>` descriptor; a child that ended and was reaped between the check and the send is never signalled (ESRCH), even when a new process has taken its pid (a pid-reuse fixture); a start-time mismatch drops the row | `tst_signals.cpp` (step 2c: the pid taken again in a user and pid namespace of the test's own, skipped with the reason where the kernel refuses it; AM56's roots), `tests/unit/activity/window/tst_actions.cpp` (the actions' rules) | L0 |
| A-S7 | projection and Dock tile file validation (sizes, versions, kinds, ranges, a stale writer by pid or by start time); the runtime folder of two displays (a nested display's files never read by the other) | `tests/unit/activity/window/tst_runtimefiles.cpp` (app) and `tests/unit/tst_docktilegraph.qml`, `tst_activitylink.qml`, `tests/shell/activity_projection.sh` (shell; step 3) | L0 |
| A-S8 | AM17's names: another owner's `argv[0]` title never shown (its `stat` name instead); control and format characters (bidirectional overrides and isolates, zero-width characters) removed from names and command lines | `tst_textclean.cpp` and `tst_sampler.cpp` (step 1; named `tst_names.cpp` before) | L0 |
| A-S9 | AM23's and AM43's turns: one fifth of the threads and one tenth of the descriptor lists per sample, a new process at once, every process covered within five and ten samples | `tst_sampler.cpp` | L0 |
| A-S10 | after the review of 949fc98: a name and a command line follow an exec (by `stat`'s name, and by the code addresses with the same name); a title over argv[0], a login shell and a symbolic link named as AM17 says; the owner read on arrival, exec and turn only; the turns as full whatever the pids; the Memory tab on `statm` with `status` in turns; a failed TCP dump and a failed listing change nothing | `tst_sampler.cpp`, `tst_procparse.cpp` | L0 |
| A-W1 | the window: tabs, columns chooser, sort, search, views, Copy text, offscreen; no sample while hidden; the size kept | `tests/unit/activity/qml/tst_window.cpp` (the real backend on a fixture tree, offscreen; step 2a), `tests/unit/tst_activitymain.qml` (a fake backend), `tests/unit/activity/window/` (the backend's logic) | L1 |
| A-W2 | Quit sheet → `SIGTERM` for a windowless fixture, Force Quit → `SIGKILL`, ESRCH silent; Send Signal to a fixture classified as a session process shows the second sheet and offers no Stop; the dev guard refuses a process outside its roots | `tests/apps/activity_actions.sh` (the window-qml cases `ActivityActions.*` on the real /proc; step 2c) and `tests/unit/tst_activitymain.qml` (the sheets on a fake backend) | L1 |
| A-S11 | AM57's and AM58's reads: the parsers (stat's policy after a name with parentheses, `smaps_rollup`, `btime`, the socket tables, the unit), every tab of an own process on a fixture tree, another owner's (no io, unit, command line, links or descriptors), % CPU between two reads, `smaps_rollup` at most every 5 s, a younger parent, a process ended or replaced; a real child's pipe, TCP listener and local socket through its descriptor | `tests/unit/activity/tst_inspect.cpp` (step 2d) | L0 |
| A-S12 | AM65's groups (kinds in order with their counts, an app unit's header with its name and icon, a window owner outside a unit, the Kernel row with the System Processes, collapsed headers kept, the search); a unit's number for its processes; AM70's Status column in its order | `tests/unit/activity/window/tst_processtable.cpp`, `tst_sampler.cpp` (step 4) | L0 |
| A-S13 | AM68: available for an own app unit only, the reasons, nothing without the user manager (AM76); the unit read again when chosen; idle on, 1 on an older systemd, unset off; a failure said; the sampler's `cpu.idle` and `cpu.weight` reads, once per unit, a change made elsewhere followed | `tests/unit/activity/window/tst_efficiency.cpp`, `tst_sampler.cpp`, `tests/unit/tst_activitymain.qml` (step 4) | L0 |
| A-S20 | AM77: `tests/unit/activity/tst_sampler.cpp` (TotalsKeepTheCountersOfDevicesThatWent, ASocketCountsForTheProcessThatHoldsIt, TheSpeedIsReadOnlyWhenAsked), `window/tst_apphistory.cpp` (TheJournalIsReadOnTheWorker), `window/tst_performance.cpp`, `window/tst_processtable.cpp` (OnlyTheRowsThatChangedAreAnnounced) | L0 |
| A-S14 | AM67: the journal's records of the launches only, summed per app with the live units, the period, the caption, the sort, "not available" when journalctl fails | `tests/unit/activity/window/tst_apphistory.cpp`, `tests/unit/tst_activitymain.qml` (step 4) | L0 |
| A-S15 | AM66, AM71, AM72: the machine's facts on fixture trees (processors, caches once, speeds, uptime, a disk, an interface's kind, a Wi-Fi signal); the sidebar and details built only while shown, Memory's bar whole, a selection that went away, each processor's split and history, Clear CPU History, a GPU without clients idling; the windows on a fake backend | `tests/unit/activity/tst_machine.cpp`, `window/tst_performance.cpp`, `tests/unit/tst_activitymain.qml` (steps 4 and 5) | L0 |
| A-W3 | the Info button's window on the real /proc: its reads, a second request raising it, its Quit sending SIGTERM, the window closing with its process; another owner's process (pid 1) with "—" and Quit off; the windows closed with the main window. The backend: one inspection per process, the tabs' texts, the reads on the worker's thread and only on screen. The window on a fake backend: the Info button, Ctrl+I, the menus, a double-click, the tabs, the parent link, the disabled Quit's tooltip, the keys of the key window | `tests/apps/activity_actions.sh` (`ActivityInspect.*`), `tests/unit/activity/window/tst_inspection.cpp`, `tests/unit/tst_activitymain.qml` (step 2d) | L1 |
| A-N1 | nested: a SIGSTOP'd foot shows "(Not Responding)" (the ANR stand-in path of ADR-0035), Quit through the shell closes a foot window, the Dock tile graph draws and goes at quit | `tests/apps/activity_nested.sh` (the files and IPC side, written at step 5, run by the integrator) + `just shot activity` (the drawing) | L1 |
| A-N2 | dev guard: an action on a process outside the nested session is refused | the refusal through the window: A-W2's dev-guard case (`tests/apps/activity_actions.sh`); `activity_nested.sh` checks the nested app runs as a dev session | L1 |
| A-I1 | `ipc_inventory.sh` lists `activity quit` and finds its caller: its real-session caller scan (today `config/hypr/grassfield/`, `packaging/bin/`, `packaging/shims/`, `packaging/session-bin/` and the screen corners, `ipc_inventory.sh:850`) is extended to the apps' sources that build `shellIpcArgs()` calls (review of e3882de) | `tests/security/ipc_inventory.sh` | L0 |
| A-D1 | End Task: absent while `dock.endTask` is off, after Quit when on, absent with Option held and on the Files tile, folders and the Trash; the same confirmation and pids as Option + Force Quit | `tests/unit/tst_docklaunch.qml` (with `Launch.js`) and a new `tests/unit/tst_dockmenu.qml` for the menu model | L0 |
| A-K1 | `grassfield-launch-key activity` starts the desktop id through uwsm, nothing in a nested dev session; the binding exists once | `tests/shell/launch_keys.sh`, `tests/shell/session_input.sh` | L0 |
| A-P | AM-P1 to AM-P4, per tab | `tests/apps/activity_cost.sh` | L1 (and L2 on the owner's machine) |
| A-E | Efficiency Mode on a test scope (`systemd-run --user --scope --slice=app-graphical.slice --unit=app-grassfield-activitytest-<8 hex>.scope`, named as uwsm names a launch) sets and reverts the weight; prints the `cpu` controller's state before, during and after | `tests/apps/activity_efficiency.sh` with the case `EfficiencyLive.*` (L2: the owner's user manager; skipped outside it) | L2 |
| A-H | App History on fixture journal records (`journalctl -o json` lines) | `tests/unit/activity/window/tst_apphistory.cpp` (A-S14; step 4) | L0 |

## Interfaces / contracts (versions)
- `activity-<display>/windows.json` v1 (AM60) and `activity-<display>/dock-tile.json` v1 (AM62) in the runtime folder: new,
  between the shell and the app; a breaking change bumps `v` and needs ADR-0038 amended.
- IPC `activity quit` (AM61): `docs/specs/security.md` "IPC surface".
- `activity.json` v1 (AM74): ADR-0020.
- Session bus, served (AD34, step 2a): `org.grassfield.Activity` (`org.grassfield.Activity.Dev` in a dev session), object
  `/org/grassfield/Activity`, interface `org.grassfield.Activity`, one method `Activate(s token)`: the window comes
  forward with the caller's xdg-activation token (one instance, AM1).
- Read-only D-Bus: logind `ListInhibitors`, UPower (DisplayDevice, `GetHistory`), NetworkManager (active connection name);
  read-write: the systemd user manager `SetUnitProperties` (runtime only, AM68).
- Kernel interfaces: `/proc/<pid>/{stat,statm,status,io,cmdline,cgroup,fd,fdinfo,task,smaps_rollup,exe,cwd}`, `/proc/{stat,
  meminfo,loadavg,uptime,diskstats,swaps,pressure/memory}`, `/proc/net/{dev,tcp,tcp6,udp,udp6,unix,wireless}`, `/sys/block`,
  `/sys/class/{drm,net}`, `/sys/devices/system/cpu`, `NETLINK_SOCK_DIAG`, `pidfd_send_signal` on a `/proc/<pid>`
  descriptor (Linux ≥ 5.1).

## Dependencies (verified versions)
Qt 6 (Core, Gui, Qml, Quick, DBus; as Settings and the Store), Grassfield.Ui, glibc (`getifaddrs`, `syscall`), the kernel
(6.18.44 in the probes), systemd 262 and uwsm 0.27.1 (A6, A7; the owner's versions checked at step 1), `journalctl`.
No new package.

## Degraded behavior
AM75 to AM78; a kernel without `pidfd_send_signal` (older than 5.1) is not supported by Omarchy 4 and is not handled.

## Automated tests · Manual verification steps
Automated: the table above. Manual (owner, L2): AM36's calibration on the laptop; AM39 on battery and on AC; AM43 with a
download in a browser (TCP) and a video (QUIC, only in the totals); AM48 on i915; AM-P1 to AM-P4 on the real session;
Efficiency Mode on a real app with a CPU load (`stress-ng` once installed by the owner) to see its share fall under
contention.

## Performance (gates; one threshold per tab, from ADR-0038 A10, review of e3882de)
The reference fixture is A10's: about 600 processes (400 of the user with 4 threads and about 17 descriptors each, 200 of
another user), about 1 600 threads, 6 800 descriptors and 220 TCP sockets. Since the integrator's decision on pull request
#47 (2026-10-29; ADR-0038 "Review history"), each tab's AM-P2 limit is 1.3 × A10 reading what the sampler reads, its
"step 1" plan: `activity_cost.sh` runs A10 before and after the product on the same fixture and takes the worse run, so a
product more than 1.3 × its own plan fails on any machine. Disk's plan is A10's one pass over the same files in the
sampler's order (the integrator's second decision of that day): its summed plan, parts measured alone with warm caches,
is below what any reader of those files pays. Since step 2b Disk's margin is 1.15 (the integrator's decision after #47's
merge) and a run started at a load average of 2 or more does not count. The reference machine's figures come from the integrator's run
at idle (load under 2) before step 2a's merge. Before that decision the limits were A10's step-0 plan, worse of two runs
plus about 30 %, on the reference machine (i5-10400H, 8 threads, kernel 7.2.5, the owner's live session, outside any
sandbox; pull request #40, the integrator's comment of 18:59 UTC of 2026-10-28): CPU 17, Memory 25, Energy 40, Disk 17 and
Network 45 ms, from A10's step-0 plan of 13.0, 19.1, 30.8, 13.3 and 34.6 ms. Step 1 changed the reads on purpose (AD32,
AD33, the owners' turns), so that plan no longer measured the product. Step 0's first limits came from the cloud machine
(6, 10, 13, 7 and 7 ms). Each is measured per tab, the window visible on that tab.

| Tab | One sample (AM-P2), sampler thread's CPU time | A10 step-1 plan, reference machine | App CPU at Normally (5 sec) (AM-P1) | App CPU at Very Often (1 sec) (AM-P1) |
|---|---|---|---|---|
| CPU | ≤ 1.3 × the plan | the integrator's idle run (16.92 ms at load 3.9) | ≤ 0.5 % of one core | ≤ 1.5 % |
| Memory | ≤ 1.3 × the plan | the integrator's idle run | ≤ 0.5 % | ≤ 1.5 % |
| Energy | ≤ 1.3 × the plan | the integrator's idle run | ≤ 0.5 % | ≤ 2 % |
| Disk | ≤ 1.15 × the plan in one pass (step 2b) | the integrator's idle run | ≤ 0.5 % | ≤ 1.5 % |
| Network | ≤ 1.3 × the plan | the integrator's idle run | ≤ 0.5 % | ≤ 1.5 % |

The AM-P1 shares came with step 0's cloud figures. On the reference machine 0.5 % of a core at Normally (5 sec) is 25 ms a
sample, and 1.5 % (2 % on Energy) at Very Often (1 sec) is 15 ms (20 ms): below AM-P2's limits for some tabs. AM-P1 is
measured on the whole app at step 2, and the integrator sets it again then (open, step 1).

- **AM-P1** The app's whole CPU (Δ utime + stime of its own `stat` over 10 minutes, sampler and window together) with the
  window visible on the tab, at the rates above.
- **AM-P2** One sample, read as ADR-0038 d says (the listing, `stat`, the tab's own reads, the turns of AM23 and AM43); the
  dev build counts each kind of read so the test can tell which one went over. Step 1: the gate is the **median of 101
  samples** taken back to back after a first one (which opens every kept descriptor and has no rates), on the sampler
  thread's clock; the 95th percentile and the maximum are printed beside it and not gated. The per-process files are kept
  open and re-read with `pread` while their process lives (`stat`; `statm` and `status` on the Memory tab; `io` of the
  user's processes on the Disk and Energy tabs); the app raises its soft `RLIMIT_NOFILE` at start to the hard limit, at most
  16 384 (the session's soft limit is 1 024), and keeps at most that soft limit less 256 open; past that budget a file is
  opened, read and closed each time, slower and never an error (`tst_sampler.cpp`). A `stat` or `io` line identical to the
  process's last one is not parsed again, and every tab reads the system files, so each tab's graph keeps its history
  (step 2b; ADR-0038 AD37). The limit is 1.3 × the tab's step-1 plan, 1.15 × on Disk (the table above), and Disk is
  measured again with a tenth of the fixture's processes changing their `stat` and `io` lines between two samples
  (`--changing`, review of PR #53): `activity_cost.sh` runs probe A10 on the same fixture before and after the product, prints
  each tab's plan, limit and ratio, and fails a tab over its limit; the bench prints each sample's user and kernel time.
- **AM-P3** Minimized: no per-process sample (counted by a dev counter); with a Dock graph at 5 s, ≤ 0.1 % of one core.
- **AM-P4** Memory: the app's PSS ≤ 120 MB after 10 minutes, and its growth over one hour < 5 MB.
- Inspect (step 2d): an open Inspect window reads on the sampler's thread at the update frequency, only while it is on
  screen, and only the header and its tab; `activity-sampler-bench inspect PID` prints one read's CPU time per tab
  (`step2d.md`: the header 0.01 ms; Statistics 0.43 ms for 64 threads; Open Files and Ports 1.5 to 2 ms for 400 to 1 000
  descriptors; `smaps_rollup` of a process of 1 GB, 3.1 ms, at most every 5 s). The whole app with one open adds at most
  about 0.1 % of a core at Normally (5 sec), on Open Files and Ports with a thousand descriptors.
- The shell: the projection writer and the Dock graph add no measurable CPU at idle (P1) and are measured during a window
  storm (20 windows opened and closed).
Method: `tests/apps/activity_cost.sh` builds the fixture (as `sampcost spawn` and `sampcost tcp` do), starts the app
(offscreen and nested), switches through the tabs at both rates, samples its `/proc/<pid>/stat` and `smaps_rollup` and its
dev read counters, and fails over a threshold; results recorded in the step's audit file. Step 1 has no window yet: the
script measures AM-P2 with `activity-sampler-bench`, the product sampler on the A10 fixture, and refuses to run as root
(root reads every process's `io` and descriptors, which is not the user's cost); step 2 adds the app for AM-P1, AM-P3 and
AM-P4. Step 1's figures on this cloud machine after the review of 949fc98: CPU 2.6–2.8 ms, Memory 2.8–2.9, Energy 5.9–6.0,
Disk 2.1, Network 3.2–3.4 (medians of three runs; before it, 4.6, 7.0, 8.7, 4.2 and 4.7). A real session is measured again
at step 5 (L2), with its own number of processes, threads and descriptors noted beside the results.

## Known limitations (honest, user-visible gaps vs macOS)
- Other owners' processes are read-only (AQ4): no administrator path to quit them (macOS asks for an administrator), and
  their disk, network, GPU, open files and command line are not shown.
- Time the kernel spends on interrupts belongs to no process: System is a little above the sum of the rows.
- An exec into the same program at the same addresses (a program that is not position-independent, or address
  randomization turned off) is not seen: the Command column keeps the old arguments until the process ends (review of
  f68789c).
- Network per process is TCP only and starts when the app opens (AQ2); UDP, including QUIC video, is only in the totals.
- Energy Impact is Grassfield's own estimate (AQ3); no 12 hr Power, App Nap or Graphics Card.
- No Sample Process, Spindump or System Diagnostics.
- An Inspect window lists at most 10 000 descriptors (the rest counted); its Recent hangs shows "—" until step 3.
- Wake Ups count voluntary context switches, not package wake-ups from idle, and each process's value is refreshed every
  fifth sample (AM23).
- GPU figures need a driver that reports `drm-engine-*`; another user's GPU use is not seen.
- The app quits with its last window, so the Dock graph lasts while a window is open or minimized (macOS keeps it running).
- Efficiency Mode lowers a whole app's CPU weight, only under contention, only until the app quits or the session ends, and
  not its disk priority (the `io` controller is not delegated to the user manager). Only apps started in their own unit
  can use it. Once used, contended apps may share the processor app by app until logout (AM68).
- App History covers apps started in their own scope (from the Dock, Apps, Search or a uwsm launch), from systemd's records
  of apps that ended plus the running ones, as far back as the journal keeps them; it cannot be deleted from the app.
- A new socket or GPU client of a process already listed is seen within ten samples (AM43, AM45).
- A process that ended between two samples moves its last slice of CPU to System.
