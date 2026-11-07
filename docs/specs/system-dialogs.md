# System dialogs spec · shell-engineer, platform-engineer, apps-engineer, security-engineer · 1.0 (ADR-0035)

Status: step 0 (docs only, owner brief 2026-10-27 « toutes les boîtes de dialogue au design Grassfield »); §6 is built
(steps 2b and 2c), §4 (step 3), §9 (step 4a in Files, step 4b in the panels), §1 (step 4b) and §2's permission alerts (step
5a; Open With is step 5b); §4b's notice is built but not active on Hyprland 0.56.2; §5's bridge (step 9a) and the shell's queue
and secret sheets for gcr's prompts (step 9b) are built; the other sections are not built yet. Decisions and delivery order:
`docs/decisions/ADR-0035-system-dialogs.md`. Inventory (every dialog of a Grassfield session, its provider and category):
`docs/audits/dialogs-2026-10-27/inventory.md`. Row ids (P*, H*, S*, K*, O*, T*, G*) refer to that inventory; Q* are the
owner's decisions recorded in the ADR.

This spec covers the surfaces Grassfield draws in place of another desktop's (category A of the inventory) and the toolkit
appearance alignment (category C). Each section follows Appendix G of the master prompt. Geometry is measured from
`design/reference/` (git-ignored, never committed) in the step that builds the surface; values here are structure, not
measurements.

## Common rules (every surface of this spec)
1. **Look.** Built on `Grassfield.Ui` only: the alert shape of `shell/overlay/Dialog.qml` (icon at the top left, bold title,
   left-aligned message, equal-width capsule buttons) or its sheet shape (title, content, hairline above a 64-pt footer, 24-pt
   sheet buttons at the bottom right: rounded rectangles, `Button.sheet`, as macOS 27's Print and Open sheets; ADR-0039 step 10); the frame moves into `Grassfield.Ui` (a public type, `docs/specs/ui-api.md`) in the
   first step whose surface lives outside the shell process. The panel material of ADR-0024 and the existing tokens
   (`Tokens.panelAlertWidth`, `radiusAlert`, `panelSheet*`, `radiusSheet`, `buttonHeight`, `alertButtonHeight`,
   `controlFocusOutline`). The blur behind a dialog in the shell's Overlay takes the corner the dialog draws
   (`Dialog.cornerRadius`: an alert's `radiusAlert`, a sheet's `radiusSheet`; ADR-0039 step 4). No hardcoded value; a new measured value is a new token with its source note. F1 target as ADR-0024 (geometry ±1 pt, tints ±0.1); A2 holds at every transparency ≤ 0.6
   and with Reduce Transparency (opaque tint).
2. **Appearance.** Light, dark and auto follow `appearance` live (`ui/Grassfield/Ui/AutoAppearance.js`; the C++ copy in
   `apps/autoappearance.h` for processes outside the shell); the accent follows `accent.color`; Increase Contrast and Reduce
   Motion as the rest of the shell (crossfades ≤ 100 ms).
3. **Keyboard.** Every control reachable with Tab and Shift+Tab, a visible focus ring (`Appearance.focusRingColor`), Return
   activates the default button, Esc (and Cmd-.) cancels, Space activates the focused button. A destructive button is never
   the default, with one written exception: the copy/move conflict sheet of Files (section 9), whose default is Replace, as
   the Finder's (owner decision Q18, ADR-0035, 2026-10-28). Focus enters the surface when it maps and returns to the window that asked when it closes (the platform's
   focus-return path, ADR-0012).
4. **Accessibility.** `Accessible.role: Accessible.Dialog`, `Accessible.name` = the title, `Accessible.description` = the
   message; every control has a role and a name; secure fields expose no text (A1).
5. **i18n.** Every visible string in `qsTr()` (en + fr, `just check` i18n gate I1); strings that come from an application
   (titles, labels, file names, app names, purpose strings) are shown as plain text, never rich text, flattened to one line
   and capped in rendered lines, as the polkit sheet does (`shell/security/polkit/AuthDialog.qml`). The app is named by its
   desktop entry's `Name` in the UI language, its id under it when it is not installed (as the Settings privacy pane does).
6. **Over the lock.** Nothing opens while the session is locked (`SessionState.refuses(<surface>)`, security.md § Nothing
   opens over the lock), and no fallback opens a stock surface instead while locked. Each section says whether a request
   that arrives while locked waits (shown after the unlock without the keyboard until a click, the polkit hold rule) or is
   cancelled (the screen-sharing picker, owner decision Q15).
7. **Never block, never lose.** Each surface says what happens when the Grassfield surface cannot be shown: the stock
   provider where that is possible and safe (the stock dialog, the stock picker when unlocked, x-d-p-gtk's backend from a
   running portal process), otherwise a defined answer ("cancelled" or an error). A crashed portal backend is restarted by D-Bus
   activation at the next call; the frontend never falls back to `gtk` at runtime (ADR-0035 D-4). Every wait on the shell is
   bounded (its acknowledgement, its connection, its heartbeat); the user's own choice is not (an open picker or panel waits for
   the user, as the stock ones do).
8. **Dev guard.** In a dev session (ADR-0019) nothing reaches the owner's real buses or files: tests run on a private session
   bus with fake peers (fake portal frontend, fake prompter caller, fake xdph caller), never the real bus or the real
   secrets. Every new IPC function is listed in `docs/specs/security.md` § IPC surface (`tests/security/ipc_inventory.sh`).
9. **No Apple names or assets.** No Apple trademark in any string (master-prompt §14); own glyphs from `branding/`.

## 1. Open and Save panels (FileChooser; inventory P1–P3; ADR-0035 D-4; built in step 4b)

### macOS reference behavior (described in words)
- Attached to the requesting window as a sheet: a card centred over the parent, the parent dimmed and inert; with no parent
  window, a free-standing panel centred on the active display. One panel per parent; the app's other windows stay usable.
- Open panel = a Finder browser: sidebar (Favorites: Recents, Applications, Desktop, Documents, Downloads, Home; Locations;
  Tags), toolbar with Back/Forward, the view switcher (icons, list, columns, gallery), the path pop-up (the folder's name; its
  menu lists the enclosing folders), search field. Items the app cannot open are dimmed, not hidden. Footer: the app's options
  (format pop-up, check boxes) when it has any, Cancel, the default button ("Open" or the app's label).
- Folder mode: only folders can be chosen; the default button reads "Open" or the app's label ("Choose").
- Multiple selection when the app allows it (Shift/Cmd click, Cmd-A).
- Save panel: compact by default (Save As field with the name selected without its extension, Tags, Where pop-up with recent
  places) with a disclosure button that expands it to the full browser (remembered per app). New Folder in the expanded panel.
  A Format pop-up when the app offers formats; changing it changes the extension. "Hide extension". Saving over an existing
  file asks "“name” already exists. Do you want to replace it?" with "A file or folder with the same name already exists in
  the folder “X”. Replacing it will overwrite its current contents.": Cancel (default) / Replace.
- Keyboard: Return = default button; Esc or Cmd-. = Cancel; Cmd-Shift-G, or typing "/" or "~", opens Go to Folder (Tab
  completes); Cmd-Up enclosing folder, Cmd-Down open; Cmd-Shift-D Desktop, Cmd-Shift-H Home, Cmd-Shift-O Documents,
  Cmd-Shift-A Applications, Cmd-Option-L Downloads; Cmd-1…4 views; Cmd-Shift-. hidden files; Space = Quick Look; type to
  select; Tab cycles name field, sidebar, list.
- Remembers the last folder and view per app; dragging a file from Finder onto the panel selects it.

### Purpose and non-goals
Purpose: every portal Open/Save request of the Grassfield session gets this panel; the session routes GTK 3's native chooser
there too (`GTK_USE_PORTAL=1`, owner decision Q3). Non-goals: the in-process GTK 3 dialogs of Qt apps (`gtk3` theme) and
LibreOffice (ADR-0035 D-8); remote (KIO network) results; Tags editing in the Save panel before Files has tags (FP rows of the Finder parity matrix).

### Functional requirements
- FC1 `OpenFile` with `multiple`, `directory`, `filters`, `current_filter`, `choices`, `accept_label`, `current_folder`;
  returns `uris` (file://), `choices`, `current_filter`; response 0 on accept, 1 on cancel, 2 on error.
- FC2 `SaveFile` with `current_name` (name selected without extension), `current_folder`, `current_file`, filters/choices;
  the replace alert when the target exists; returns one `uri`.
- FC3 `SaveFiles` (folder choice for several `files`), returns the folder-based `uris`; the replace alert lists the clashes.
- FC4 parent: the panel is the modal child of the app's toplevel through xdg-foreign v2 + xdg-dialog v1; without a handle,
  a centred floating window above the app.
- FC5 the browser is Files': sidebar, the four views, path pop-up, search in the folder, Quick Look on Space, Go to Folder,
  hidden files, per-app last folder and view (state file listed in ADR-0020).
- FC6 Options area: each `choices` entry is a pop-up (with options) or a check box (without).
- FC7 never blocks: the UI shows within 3 s or the running process forwards the request to x-d-p-gtk's backend and relays its
  answer (ADR-0035 D-4). A crash during a request ends that request with an error (response 2); the next request starts a
  fresh process through D-Bus activation.
- FC9 Files' KIO dialogs are Grassfield's in the panel too (ADR-0035 D-12, section 9 below).
- FC10 the process starts with `GTK_USE_PORTAL` and `QT_QPA_PLATFORMTHEME` cleared (its unit), so it never waits on the
  portal that waits on it.
- FC8 over the lock: no panel while locked (common rule 6); a request that arrives then waits for the unlock.

Built in step 4b (`grassfield-portal`, `apps/files/qml/FilePanel.qml`; the decisions are ADR-0035 4b-1 to 4b-18):
- FC1–FC3 as written; an Open panel's default button chooses the selection, opens a selected folder in a file panel, and
  chooses the shown folder in a folder panel; SaveFiles asks about every name that exists in the chosen folder in one alert;
  a Save name that is a folder's is refused with a message (4b-6).
- FC4: the panel carries the application's Wayland app id when the frontend names it, so it counts as that application's
  window (Dock, menu bar, Force Quit), else Files'; modal (xdg-dialog) when the application asked and gave a Wayland parent,
  imported with xdg-foreign v2 through KWindowSystem (4b-3, 4b-4, 4b-13).
- FC5: the views, sidebar, path pop-up (the toolbar's folder button), search, Glance on Space, Go to Folder, hidden files and,
  per application in `portal-filechooser.json`, the last folder, the view and whether the Save panel was expanded. Items a filter refuses
  are dimmed and cannot be selected (4b-5); a panel changes no file but New Folder (Save, folder Open, SaveFiles; 4b-7).
- FC6: one filter shows no pop-up; several show "Show:" (Open) or "Format:" (Save, where the extension follows); each choice is
  a pop-up or a check box.
- FC7: the UI loads at the first request; no first frame in 3 s, a QML that does not load, or no display: the call goes to
  x-d-p-gtk; the process quits 60 s after its last request (4b-11). The panels never read the disk on the GUI thread: a
  folder that has not answered for 1 s (5 s at most for many names; a share gone, a sleeping disk) is passed over when a
  panel opens, never hiding the application's own folder, is dimmed in the sidebar until it answers, and Save, Go to Folder
  and SaveFiles say "“name” isn't responding." there; another application's panel is never held up (4b-18).
- FC8: the compositor's session lock hides the panel and keeps the keyboard from it; a panel that first gets the keyboard
  1.5 s or more after it opened takes keys only after a click, and its footer says so (4b-8).
- FC9: Files' KIO sheets, in the panel the user last worked in.
- Keys: Return (default button; Cancel in a replace alert), Esc and Cmd-. (Cancel), Cmd-Shift-G, Cmd-L, "/" and "~" (Go to
  Folder), Cmd-[ and Cmd-] (back, forward), Cmd-Up, Cmd-Down and Cmd-O, Cmd-Shift-H, Cmd-Shift-D, Cmd-Shift-O, Cmd-Option-L,
  Cmd-1 to Cmd-4, Cmd-Shift-. and Cmd-H (hidden files), Cmd-F, Cmd-A (several items), Cmd-Shift-N, Cmd-Y and Space (Glance),
  Cmd-Shift-P (preview), typing to select (Ctrl stands for Cmd, as in Files).

### Acceptance criteria (L0 unit, L1 nested)
- A-FC1 (L0) option mapping table tested on a fake frontend (private bus): every option of FC1–FC3 in, the exact `a{sv}` out.
- A-FC2 (L1) Chromium "Open File…" and "Save Page As…" in a nested session show the Grassfield panel attached to the window
  (screenshot), Return opens, Esc cancels and the app receives the answer.
- A-FC3 (L1) the panel's first show ≤ 300 ms warm (P4-like log line: "grassfield-portal: panel shown in N ms"), ≤ 80 MB
  private memory while open (ADR-0035 decision 4b-9; the resident size reported), and the `grassfield-portal` process gone
  60 s after the last panel closed (Settings lives in the other process, `grassfield-portal-settings`: ≤ 4 MB private,
  ≤ 20 MB resident with the shared libraries, AP1, ADR-0035 decision 2b-11).
- A-FC4 (L0) fallback: a backend whose QML fails to load forwards to a fake gtk backend and relays its answer.
- A-FC6 (L0) crash: the backend killed during `OpenFile` gives the fake frontend an error within the D-Bus timeout, and the next
  `OpenFile` is answered by a newly activated process.
- A-FC7 (L0) start-up: the backend starts and answers with a frontend that never answers its `ReadAll` (no wait on itself).
- A-FC5 F1 side by side with the reference captures (open, save compact, save expanded, replace alert) in both appearances.

Step 4b: A-FC1, A-FC4, A-FC6 and A-FC7 by `tests/unit/portal/` (a fake frontend and a fake x-d-p-gtk on a private
dbus-daemon) and `tests/integration/portal_filechooser.sh` (the real binary, offscreen, and the real frontend 1.22.1 on a
private bus); the offscreen part of A-FC3 there (a warm panel shows in about 50 ms, 28 MB private, the process quits once
idle); the panel's behaviour by `tests/unit/tst_filepanel.qml`. A-FC2, the nested part of A-FC3 and A-FC5 wait for the
integrator's nested pass.

### Interfaces / contracts
- `org.freedesktop.impl.portal.FileChooser` (version as the frontend 1.22.1 expects), bus name
  `org.freedesktop.impl.portal.desktop.grassfield`, `grassfield.portal` in
  `/usr/share/grassfield/xdg/xdg-desktop-portal/portals/`.
- Per-app state: `$XDG_STATE_HOME/grassfield/portal-filechooser.json` (last folder, view, expanded), ADR-0020 row.

### Degraded behavior
Backend's `.portal` file missing when the frontend starts: the frontend's next name, `gtk`. Backend crashed: the request in
flight fails (the app gets an error), D-Bus activation starts a new process at the next call. UI failure in a running process:
forwarded to gtk. Files' KIO workers missing: local folders only, a note in the sidebar.

### Automated tests · Manual verification steps
Unit (fake frontend, fake gtk peer, scratch HOME); nested (`tests/visual/flow-filechooser.sh`, Chromium and a GTK 4 test app);
manual: an Electron app (Obsidian) Open and Save, a Flatpak if installed.

### Performance · Accessibility · i18n
P4-like budget above; common rules 3–5; the panel's strings in the Grassfield catalogue, the app's labels and filter names as
given.

### Which callers reach the panel (audit after the rc6 bug report)
- **Report (owner, rc6):** "some save or upload windows still show Omarchy's old file dialog instead of Files". That dialog is
  GTK 3's file chooser, which x-d-p-gtk shows in the Omarchy session and which an app shows itself when it does not use the
  portal.
- **The routing is right (measured on the owner's session on 2026-11-07, read-only):** the running frontend has
  `XDG_CURRENT_DESKTOP=Grassfield:Hyprland` and the link `grassfield-portals.conf` (FileChooser `grassfield;gtk`); the owner's
  journal from 2026-10-24 to 2026-11-07 shows the backend drew 6 panels (1489 to 3364 ms from the call, the first load included)
  and forwarded none to x-d-p-gtk.
- **Callers that reach the panel:** GTK 3 apps through `GtkFileChooserNative` with `GTK_USE_PORTAL=1` (present in the
  environment of the session's processes, the browser's included); GTK 4 (4.24 uses the portal by default; it has only a
  `no-portals` debug key, so `GDK_DEBUG=portals` changes nothing there any more); Chromium and Electron (the portal dialog
  whenever the frontend answers, GTK's only for a frontend older than FileChooser 3: read in Chromium's main branch on
  2026-11-07, `ui/shell_dialogs/select_file_dialog_linux_portal.cc`, not in Chromium 155's own source; the 155 binary has the
  portal dialog's class and no kdialog arguments); Firefox (its "auto" mode follows `GTK_USE_PORTAL`; not installed here);
  Flatpaks; apps that call the portal themselves (Omarchy's hype: `org.freedesktop.portal.FileChooser` among its binary's
  strings). The panel takes everything they pass (filters and the current one, the folder, the
  suggested name or file, several files, a folder, choices, the button's label, modality: chooserlogic, A-FC1).
- **Callers that do not, each showing GTK 3's chooser in-process:**
  - Qt apps under the session's `gtk3` platform theme (Omarchy's, kept by owner decision Q3): Qt's `QGtk3FileDialogHelper`.
    Measured with a probe on the nested display (the helper a `QFileDialog` gets); on this machine OBS and Kdenlive are such
    apps (Omarchy's omawrite names the `xdgdesktopportal` theme next to `QT_QPA_PLATFORMTHEME` in its binary's strings, so it
    likely sets that theme for itself; hype calls the portal, above).
    `QT_QPA_PLATFORMTHEME=xdgdesktopportal` alone is not a fix: in this session its base theme is Qt's generic one,
    measured on the nested display: Fusion's light palette and "Sans Serif 9" instead of the GTK palette, font and dark scheme
    (the reason Q3 kept `gtk3`). A fix that keeps the look, measured with a prototype: a platform-theme plugin under the key
    `grassfield` (the session's first desktop name, which Qt lower-cases into a theme name) that hands back Qt's `gtk3` theme,
    under `QT_QPA_PLATFORMTHEME=xdgdesktopportal`: the GTK palette, font and scheme unchanged and `QXdgDesktopPortalFileDialog`
    for file dialogs. Not built: it is a new Qt plugin on Qt's private plugin API (rebuilt with every Qt minor release, and a
    plugin that fails to load gives every Qt app the generic look), a change to the session's environment and units, and an
    amendment of Q3; it needs its own ADR and the owner's agreement.
  - LibreOffice (its GTK 3 plugin builds `GtkFileChooserDialog` itself, with its own controls).
  - Chromium and Electron apps whose first portal call comes while the frontend is still starting: Chromium keeps the failure
    for the life of the process and shows GTK's dialog from then on (read in Chromium's main branch on 2026-11-07,
    `components/dbus/xdg/portal.cc`: a failed setup is never retried; not observed here, not checked in Chromium 155's source).
    At the owner's login of 2026-11-07 (the journal of that boot, monotonic times) the frontend owned its name 26 s after it
    started, waiting on x-d-p-gtk (31.1 s to 56.6 s; ADR-0041 I-4); on a private bus with the same frontend and x-d-p-gtk it
    took 0.4 s with and without `GTK_USE_PORTAL=1`, so
    I-4's hypothesis does not explain it and the cause is still open.

### Known limitations
Not a true sheet (a modal child window dimming its parent, not a card inside it); remote locations refused (4b-10); apps that
draw their own dialog in-process are not covered (D-8). Step 4b also leaves out: the Save panel's Tags field (the panel would
tag a file the application has not written yet) and "Hide extension" (4b-6); Tab completion in Go to Folder; Cmd-Shift-A
(Files' Applications location holds launchers, which a panel shows dimmed and never chooses or starts, 4b-16); a drop on a
panel answers Copy to its source though nothing is copied (the item is only shown); the keyboard moves over dimmed items
(they are passed, never selected). Verified offscreen and on a private bus only: the parent attachment, the dimming of the
parent and the look (A-FC2, A-FC3 nested, A-FC5) are the integrator's nested pass.

## 2. Open With and permission alerts (AppChooser, Access; P4–P7; ADR-0035 D-5)

### macOS reference behavior
- Choose Application: an Open panel rooted at Applications with "Enable: Recommended Applications / All Applications" and
  "Always Open With"; Return opens with the selected app.
- Privacy alert (TCC): the alert shape (app icon at the top left, bold title "“App” would like to access the camera.", the app's
  purpose as the message), "Don't Allow" and "Allow" of equal width; for camera, microphone and screen recording neither is
  the default (Return does nothing until a button has focus); asked once per app and category, the answer is changeable in
  System Settings > Privacy & Security; never over the lock screen.

### Functional requirements
- OW1 `ChooseApplication(handle, app_id, parent_window, choices, options{last_choice, modal, content_type, uri, filename,
  activation_token})`: list the `choices` (desktop ids) with icon and name, `last_choice` selected; "All Applications" enables
  every application (DesktopEntries); a search field filters; "Always Open With" is not offered (ADR-0035 5b-3: the interface
  has no key for it; the frontend stops asking after the same choice three times); `UpdateChoices` refreshes the list live;
  returns `choice` and `activation_token`.
- AC1 `AccessDialog(handle, app_id, parent_window, title, subtitle, body, options{deny_label, grant_label, icon, choices})`:
  the alert with the app's icon (from `app_id`) and its name as the frontend's title gives it ("Allow Example to Use the
  Camera?"; "Allow Apps to …" when it cannot name it), title/subtitle/body as given (plain text, capped), the labels given (else "Don't Allow"/"Allow"), `choices` as radio groups or check boxes; returns response
  0 (grant) or 1 (deny) and the choices.
- AC2 no default button on Camera and Screenshot alerts (the frontend's icon or title tells which: `camera-web-symbolic`,
  `applets-screenshooter-symbolic`); other alerts default to the grant label as the frontend's wording intends.
- AC3 over the lock (ADR-0035 5a-3, replacing "refused with response 2", which the frontend keeps as "no"): an alert asked while
  the session is locked opens under the lock and waits; the lock hides it and keeps the keyboard from it; after the unlock it
  takes keys only after a click (the hold rule). Nothing is answered for the user.

### Acceptance criteria
- A-OW1 (L0) fake frontend: every option in, the answer out; a desktop id that is not installed is not listed.
- A-AC1 (L1) a test client asks for the camera through the real frontend in a nested session with a private permission store:
  the Grassfield alert shows; Allow stores `yes` (read back by Settings > Privacy & Security's model).
- A-AC2 F1 for the alert (both appearances, transparency 0 and 0.6, A2).

### Degraded behavior · Known limitations
As section 1 (forward to gtk). The frontend's wording is xdg-desktop-portal's ("Allow %s to Use the Camera?"), not macOS's
sentence. xdg-desktop-portal 1.22.1 sends it in English (its French catalog is empty): Grassfield gives its known wording in
Grassfield's language and its button labels as the alert's own (ADR-0035 5a-9); another version's new wording shows as it
comes until it is added.

Built in step 5a (`grassfield-portal`'s Access, `apps/files/qml/AccessAlert.qml`; the decisions are ADR-0035 5a-1 to 5a-9):
- AC1 as written: the alert shape of the shell's alerts, the frontend's title in bold, its question, its note in the secondary
  colour, its choices (pop-ups and check boxes), "Don't Allow" and "Allow" (or the frontend's labels) of one width; the
  application's icon from its desktop entry, the frontend's symbolic icon, in the text colour, for an application it cannot
  name; the buttons one above the other when they do not fit side by side, the default on top ("Don't Allow" on top where
  neither is the default); one alert at a time, the others waiting in order; the frontend's own wording in Grassfield's language
  (5a-4, 5a-9).
- AC2 for the camera and screen capture (the frontend's icon names them; xdg-desktop-portal 1.22.1 asks nothing about the
  microphone); Return grants the other questions, as AC2 says; Esc and the window closed are "Don't Allow" (5a-6); the keyboard
  starts on the alert, never on a button, and no click, key or close answers for 500 ms each time the alert becomes the active
  window (a key meanwhile starts that time again), and an alert back after more than 1.5 s away (the lock, another window) takes
  keys only after a click, as at a late first activation; that click, armed or not, only ends the hold, and the hint stands in
  the buttons' place meanwhile (5a-5).
- AC3 as above; a request that ends without the user's answer ends with a D-Bus error, so the frontend keeps nothing (5a-3).
  FC7's forward: an alert that has not drawn in 3 s, or a process without a display, goes to x-d-p-gtk's Access.
- Evidence: `tests/unit/portal/tst_access.cpp`, `tests/unit/tst_accessalert.qml`, and `tests/integration/portal_filechooser.sh`
  scenario 7: the camera asked through the real frontend on a private bus, the alert's answer back to the application and
  kept by the frontend's permission store ("yes" or "no"); A-AC1 in a nested session and A-AC2 are the integrator's.

Built in step 5b (`grassfield-portal`'s AppChooser, Choose Application in `apps/files/qml/FilePanel.qml`; the decisions are
ADR-0035 5b-1 to 5b-7):
- OW1 as the macOS panel: the Open panel in the Applications location, titled "Choose Application", the document named over the
  browser ("Choose an application to open the document “notes.txt”."); the Enable pop-up's "Recommended Applications" (the
  frontend's candidates and its last choice) and "All Applications" (every one), the others dimmed; the last choice selected
  once listed; the candidates and the last choice are listed under both even when the Apps grid hides them (NoDisplay=true,
  OnlyShowIn elsewhere: Omarchy's image viewer imv is NoDisplay and the type's default, which the Open With submenu offers;
  FolderModel.chooser `listed`, 2026-10-30); Open, Return or a double-click answers the application's desktop id, Cancel or Esc answers 1; UpdateChoices
  changes the candidates of the open panel; the search field and the views are the Open panel's. No "Always Open With" box
  (5b-3).
- A-OW1: `tests/unit/portal/tst_appchooser.cpp` (every option in, the answer and its token out, a desktop id that is not one
  never listed or answered), and `tests/integration/portal_filechooser.sh` scenario 8 through the real frontend's OpenFile: the
  panel answers the type's default application, the frontend starts it with the document and counts the choice; Cancel starts
  nothing.

Built in step 5c (Files' own Open With; ADR-0035 5c-1 to 5c-7):
- OW2 Files' Open With, in the item menu and the File menu, lists the applications for the selected files' type, then Other…
  (Other… alone when none); Other… opens the same Choose Application panel, modal over the Files window the user worked in,
  for the selection ("Choose an application to open the document “X”.", or "… the N selected documents."); the application
  chosen opens the documents; Cancel and Esc open nothing. No "Always Open With" box (5c-4).
- OW3 A document whose type has no application (KIO's question in Files): Finder's alert, "There is no application set to open
  the document “X”.", with Choose Application… (the default, Return) and Cancel (Esc); Choose Application… opens the panel,
  and the application chosen opens the document. A job that ends takes its alert or panel away. With Grassfield Store
  installed (Store step 4, 5c-3's follow-up): "Search the Store" too, Finder's App Store button, and the message "Search
  Grassfield Store for an app that opens it, or choose an application on this computer."; it opens the Store on the apps
  that open the document's type (`grassfield-store --page=type:<type>`, ADR-0037 SD34) and the document stays closed.
- The panel's line cuts a long name in its middle (its extension and the closing quote stay) and shows an address decoded,
  without its password.
- Every selected document goes to the application chosen, each as one argument (KIO starts it; no shell reads a name).
- A-OW2: `tests/unit/files/tst_applicationchooser.cpp` (Other… with two documents, one named with a shell's characters, started
  for real), `tests/unit/files/tst_kiodialogs.cpp` (a real OpenUrlJob for a type
  with no application: the alert, the panel, the chosen application started with the document; Cancel on either; a job killed
  under its panel), `tests/unit/tst_filesbrowser.qml` (Other…, the panel over the browser window), `tst_filesglobalmenu.qml`,
  `tst_fileskiosheets.qml`, `tst_filepanel.qml` (a click and a right-click on a dimmed item in each view); the look in a nested
  session is the integrator's.

## 3. Screen-sharing picker (P10; ADR-0035 D-6)

### macOS reference behavior
See ADR-0035 D-6 and the inventory: the system picker offers the entire screen or a window (hover highlights it, a click picks
it), Esc cancels; while sharing, the menu bar shows the screen-recording indicator naming the app.

### Functional requirements
- SP1 the stand-ins print exactly the grammar of ADR-0035 D-6 and nothing else on stdout; a cancel prints nothing.
- SP2 one-time channel: the stand-in creates a Unix socket with a random 128-bit name under
  `$XDG_RUNTIME_DIR/grassfield/picker/` (directory 0700, socket 0600) and a random request id, calls `picker request <id>
  <path>`, and removes the socket file on every exit. The shell answers `accepted`, `busy` or `locked` within 1 s.
- SP2b every wait on the shell is bounded (counter-review of PR #13): after `accepted` the stand-in waits at most 2 s for the
  connection, then removes the socket file and prints nothing (cancelled); after `accepted` the stock picker never starts.
  The shell shows its panel only once connected; a failed connection shows nothing; the panel closes when the stand-in's end
  closes. Connected, the shell writes `<id> wait` every 5 s while the panel is open, then `<id> <selection>` or `<id> cancel`
  once and closes; end of file without an answer, or 15 s without a line, is "cancelled". The user's own choice has no
  deadline.
- SP3 the stand-in validates before printing: the id; the grammar; a `window:` handle present in `XDPH_WINDOW_SHARING_LIST`; a
  `screen:`/`region:` output listed by `hyprctl -j monitors`, a region inside that output's logical size. Anything else prints
  nothing.
- SP4 one picker at a time: a request while a picker is open gets `busy` (cancelled).
- SP5 locked (owner decision Q15): the stand-in checks the lock itself (Hyprland's `solitaryBlockedBy` LOCK on any monitor, or
  the shell's crash-recovery marker read as the shell reads it, `shell/security/LockMachine.js`: only `unlocked` or
  `unlocked sleeps=<n>` is unlocked, and only while `<n>` is the machine's count of suspends or that count cannot be read) and
  the shell answers `locked`; either
  way the request is cancelled and no picker shows, Grassfield's or stock. Every error counts as locked: `hyprctl` failing or
  silent for 1 s, output that is not the expected JSON, no monitor, a marker file that exists but cannot be read.
- SP6 the panel: tabs "Entire Screen" (one live thumbnail per display, the display's name), "Window" (live thumbnails of the
  windows in `XDPH_WINDOW_SHARING_LIST`, grouped by app, title under each, protected windows greyed with "This window can't be
  shared"), "Selection" (crosshair, region relative to its display); the heading "An app wants to share your screen." (the
  picker cannot know which app); "Remember this choice" ticked at opening when xdph passes `--allow-token` (Omarchy's
  `xdph.conf` sets `allow_token_by_default`), unticked otherwise, as xdph intends that flag for its picker's "Allow a restore
  token" box (owner decision Q14 amended after
  the rc6 bug report, see "Fixed after rc6" below); Cancel / Share (default once something is selected); double-click shares at
  once.
- SP7 keyboard: arrows move in the grid, Return shares, Esc cancels, Cmd-1/2/3 switch tabs.
- SP8 the recording indicator in the menu bar while an app shares through the portal (xdph's PipeWire streams, ADR-0035 7-9:
  Hyprland's screencast event comes from every capture, the shell's thumbnails too); its menu says what is shared (the
  picker's choice for that stream when it made one), not which app shares it.
- SP9 no acknowledgement within 1 s and the session not locked: the stand-in removes the socket file, then execs the stock
  picker (a late `accepted` finds no socket and shows nothing).

### Acceptance criteria
- A-SP1 (L0) the stand-in's output for each choice parsed by a copy of xdph 1.4.1's parser (`ScreencopyShared.cpp:70-125`)
  gives the intended selection; malformed, foreign-handle, unknown-output and out-of-bounds answers print nothing.
- A-SP2 (L0) channel: a second request while one is open gets `busy`; a shell that closes the socket without an answer gives
  "cancelled"; after `accepted`, killing the shell never starts the stock picker; a wrong id is ignored.
- A-SP2b (L0) bounds: `accepted` and no connection → nothing printed within 2.5 s, socket file gone, no stock picker; a late
  `accepted` after the stand-in fell back → the fake shell's connection fails and no panel is shown; a connected fake shell
  that stops writing → nothing printed within 15.5 s; the fake shell's panel closes when the stand-in exits.
- A-SP3 (L0) locked: with a fake `hyprctl` reporting LOCK, failing, hanging, printing garbage or listing no monitor, and with an
  unreadable marker, the stand-in prints nothing and starts nothing.
- A-SP4 (L1) Chromium "Share screen" in a nested session: the panel shows, a window share streams that window (screenshot of
  the receiving tab), the indicator appears and goes away when the share stops.
- A-SP5 (L1) two displays: a `region:` selection on the second display streams the selected area (coordinates relative to
  that display).
- A-SP6 (L1) shell stopped, session unlocked: the stock picker opens.

### Built in step 7a (ADR-0035 7-1 to 7-8)
- **Stand-ins:**
  - `packaging/session-bin/hyprland-share-picker` (`python3 -I`) and `hyprland-preview-share-picker`, Omarchy's name, which runs it with `--stock-name`.
  - `env-grassfield` puts that directory first in the systemd user manager's PATH, where xdph runs.
- **Shell:**
  - `shell/services/SharePicker.{qml,js}`: IPC target `picker` (`request`, plus the dev hooks `status` and `choose`).
  - `shell/overlay/SharePickerPanel.qml`: popup kind `sharePicker`.
- **The channel as built (SP2, SP2b):**
  - The stand-in's first line on the socket is `<id> list <json>` (since the rc6 fix below, after `<id> options {"allowToken": …}`): xdph's windows as `{handle, class, title, address}`. The address is Hyprland's, in hex, or `""`. The titles never go into a command line (7-2).
  - The shell opens the panel when that line arrives, at most 2 s after `accepted`; otherwise it closes the connection and shows nothing.
  - The shell's answer is `<id> <flags>/screen:<output>` or `<id> <flags>/window:<handle>`.
  - Lines with another id are ignored. A line longer than 4096 bytes, or one that is not ASCII, cancels.
  - `request` answers `refused` to an id that is not 128-bit lowercase hex, or a socket that is not `<128-bit hex>.sock` directly in `$XDG_RUNTIME_DIR/grassfield/picker/`. The stand-in, which always uses that form, then treats it like a missing shell.
- **The panel (SP6, SP7):**
  - "Share Your Screen", "An app wants to share your screen. Choose what it can see.", and Entire Screen / Window as a segmented control.
  - A grid of live thumbnails, three to a row, two rows before it scrolls.
  - Windows are grouped by app name, then sorted by title. A window without an address, or one the shell does not know, shows its app's icon.
  - Remember this choice is unticked at every opening (owner decision Q14; the amendment below, which opens it as xdph's
    `--allow-token` says, is built behind `SharePickerPanel.followAllowToken` = false and waits for the owner's agreement).
  - Cancel and Share. Share is dimmed until a tile is chosen; nothing is selected at first (7-3).
  - Arrows move in the grid, Return shares, Esc cancels, Cmd-1 and Cmd-2 switch the tabs, and a double-click shares.
  - Nothing answers keys or clicks for `panel.alertArmMs` after the panel shows, or after the last key pressed meanwhile (7-8);
    Esc and Cancel always cancel.
- **Cancelled:**
  - when another popup takes the panel's place or a click lands outside it (7-5);
  - when the session locks;
  - when the stand-in's end closes (it gave up, or xdph ended: the stand-in notices xdph's end of stdout closing).
- **Not in 7a:** Selection, the recording indicator and the greying of protected windows came in step 7b, below.
- **Tests:**
  - `tests/shell/share_picker.sh`: A-SP1, A-SP2, A-SP2b and A-SP3 against fakes, with a copy of xdph 1.4.1's parser.
  - `tests/shell/share_picker_ipc.sh`: the stand-in and the real service under Quickshell, offscreen, for busy, the wait lines, the stand-in's end, another popup, the lock and refused forms; case 13: a failed connection (no socket file, a refused one, a stand-in that gave up because the shell's answer took over 1 s) does not stop the next request from showing its panel, and no request's socket is left once it ended; cases 1 and 2: the panel (loaded as the Overlay loads it) opens with Remember this choice unticked and unarmed, and is armed after `panel.alertArmMs` with Remember still unticked, though xdph passed `--allow-token` (review of PR #83, MINOR 1).
  - `tests/unit/tst_sharepicker.qml`.
  - A-SP4 to A-SP6 (nested, Chromium) are the integrator's.

### Built in step 7b (ADR-0035 7-9 to 7-14)
- **Selection (SP6):** a third tab (Cmd-3).
  - The chosen display's live preview, with a display chooser when there are several; a drag on it marks the area.
  - The area must be at least `panel.sharePickerMinArea` either way, and its size shows under the preview ("640 × 360 on DP-1").
  - The answer is `<flags>/region:<display>@x,y,w,h` in that display's logical pixels. An area past the display is never answered, by the shell or by the stand-in.
- **Windows that hide from capture (SP6):** Hyprland's effective `no_screen_share`, asked with `hyprctl -j getprop` for every listed window when the panel opens (16 at a time, 1 s each at most). Such a window is greyed with "This window can't be shared" and never answered; no window is answered before Hyprland's answers have come. A query that cannot run greys none (Hyprland still blacks such a window out: 7-13).
- **The recording indicator (SP8):** a status item, `screen-share`, while xdph has a stream (a PipeWire video node named `xdg-desktop-portal-hyprland`); it never gives way when the status area is crowded.
  - Its menu has one row per share, named by what the picker chose for it ("Entire screen: DP-1", "Window: …", "Part of DP-1"), best effort: one new stream and one choice answered in the last 3 s. Otherwise "Screen or window" (a share an app restored with its token, or two at once).
  - Then "To stop sharing, use the app that shares."
  - While the bar is away (over a full-screen window, or on the desktop with a bar that hides there) the indicator stays in view: its glyph on its own capsule of the band's glass at the bar's right inset, coming as the bar leaves and going as it comes back (7-14). It takes no click; the top edge brings the bar back.
- **Tests:**
  - `tst_sharepicker.qml`.
  - `share_picker_ipc.sh`, cases 9-12 (11 with a private PipeWire and a stream made as xdph makes it, `share_picker_ipc.d/fake-xdph-stream.c`; 12 with the getprop answers held by gate files).
  - `share_picker_nested.sh`, check 5.
  - `tst_barhide.qml`: the indicator while the bar is away (7-14).
  - The indicator in a real share (Chromium) is the integrator's.

### Fixed after rc6: a browser asked several times for one share
- **Report (owner, rc6):** "when I select the screen to share, the selection prompt comes back several times before it finally
  takes; in Google Meet the preview shows white".
- **Cause:** Chromium's WebRTC capturer (Chrome, Chromium, Electron) captures twice for one share: once for its own picker's
  preview, then again when the page gets the stream, the second time with the restore token the first one got
  (persist_mode 1, kept by the frontend only while the browser runs, for that browser's connection). xdph 1.4.1 gives a token
  only when the picker's answer has the `r` flag (`Screencopy.cpp` onStart, `selection.allowToken`), and the Grassfield panel
  opened with Remember this choice unticked every time (Q14): no token, so every capture of the browser ran the picker again.
  Measured with the real xdg-desktop-portal 1.22.1 and xdph 1.4.1 against the nested session
  (`tests/integration/screencast_restore.sh`, case 1: two picker runs; case 2, with `r`: one).
- **Proposed decision, pending the owner (would amend Q14; until then `followAllowToken` is false and a browser still asks
  twice; macOS model: one choice per share, which the app keeps while it shares; lasting access is listed in
  Settings > Privacy > Screen Sharing, where it is removed):** Remember this choice opens as xdph's `--allow-token` says (xdph's
  `allow_token_by_default`, the default it gives its picker's box): ticked with Omarchy's `xdph.conf`. In the Omarchy session
  that file names `hyprland-preview-share-picker`; it and xdph's stock `hyprland-share-picker` both have an "Allow a restore
  token" box (their binaries' strings). The user may untick it for one share (a browser then asks twice, as before). The
  alternatives: always answering `r` and dropping the box (no way to
  refuse a lasting token), or keeping it unticked (the bug).
- **As built:** the stand-in sends `<id> options {"allowToken": true|false}` (from `--allow-token`) before the list line; the
  shell keeps it for that request (`SharePicker.allowToken`, `SharePicker.js parseOptions`; an older stand-in sends no such line
  and the box opens unticked; an older shell ignores the line) and the panel opens with Remember this choice set from it.
- **White preview:** not reproduced. A capture streams pictures only while its display draws: frames come with damage, and a
  capture of a display that does not draw streams none (measured: the nested window's output while hidden; the headless
  output with a window drawing streams real pictures, case 2). With one picker per share the browser's stream starts as soon as
  the user shares, instead of after a second picker that blocks xdph's main loop meanwhile (upstream). Owner check below.
- **Tests:** `tst_sharepicker.qml` (parseOptions); `share_picker.sh` (the options line, with and without `--allow-token`);
  `share_picker_ipc.sh` cases 1 and 2 (opens ticked with `--allow-token`, unticked without); `share_picker_nested.sh` check 1
  (the nested shell got `--allow-token`; its guard now lists every display's Quickshell instances: Quickshell 0.3.2's
  `list -p` shows only the caller's display, so the guard refused every run from the main session); `screencast_restore.sh`
  (nested, the real frontend and xdph: the browser's second capture without a picker, pictures not blank, persist_mode 0,
  and persist_mode 2 from a host app the portal cannot name, whose token is stored under the app id ""; each run checked
  isolated from the machine: WirePlumber's "policy" profile, no X display, no system bus, no X11 bell, JACK or realtime module,
  GStreamer limited to four plugins, then no device, audio node or host module in the private PipeWire graph and no sound,
  camera or media device open; every process it starts is stopped on exit, Ctrl-C and SIGTERM). Settings:
  `tst_systembus.cpp` (privacyState lists an unnamed app's grant under ""), `tst_settingsprivacy.qml` (Other Apps listed,
  selected and removed by token; no switch for ""), `settings_dbus.sh` (the same over D-Bus, with Delete). The panel's look
  is not in a nested screenshot (grim did not show it on either output while the test held it
  open): visual NOT verified; its state (ticked, unarmed, then armed) is read by the probe in `share_picker_ipc.sh`.
- **Owner check (NOT VERIFIED here: needs the real browser):** in Chromium, Google Meet > Present > Entire screen: the
  Grassfield picker shows once, Remember this choice is ticked, Share starts the presentation and Meet's preview shows the
  screen.

### Known limitations
A browser's token lasts while the browser runs; an app that asks for a lasting one (persist_mode 2: OBS) keeps the choice across
its launches while Remember this choice is ticked, because xdph passes the picker neither the app nor the mode it asked
(`tests/integration/screencast_restore.sh` case 4); Settings > Privacy > Screen Sharing lists such apps and removes them. A host
app the portal cannot name (xdg-desktop-portal 1.22 names a host app after its `app-*.scope` or `app-*.service` unit when a
desktop entry of that name exists, `src/xdp-app-info-host.c`; otherwise its id is "") has its token kept under the app id "",
measured in case 4: Settings lists those as "Other Apps" and removes them by token (review of the rc6 fix, MINOR 3: it used to
drop them, leaving a lasting grant out of sight); the raw key of an entry is never shown.
A user `xdph.conf` naming another picker is respected; xdph blocks its main loop while any picker runs (upstream), for up to
4 s when the shell dies before connecting and 15 s when it hangs after; the picker and the indicator cannot name the
requesting app. A shell that hangs with its panel open leaves the panel drawn: the stand-in gives up after 15 s, and if the
app asks again the stock picker opens beside the frozen panel (only the stock picker can answer). The indicator shows shares
made through the portal only: a recorder that captures without it (wf-recorder, OBS's own Wayland capture) is not shown
(7-9), and any PipeWire client can light it by naming a video node after xdph (nothing is shared then). An area is drawn on a
preview: about 3 logical pixels of a 1920-pixel display per preview pixel (7-10). A row of the indicator's menu can name another
app's choice when an app restores a share with its token within 3 s of the picker answering a different app that has not
started its stream yet (7-12). While the bar is away the indicator's capsule is drawn on the display, so a share of that
display shows it (7-14).

## 4. Not responding (H1; ADR-0035 D-3; built in step 3)

### macOS reference behavior
No alert. After a few seconds without event processing the pointer becomes the wait cursor over the app's windows; the app's
Dock menu shows "Application Not Responding" and Force Quit in place of Quit; Force Quit Applications lists the app with
"(Not Responding)" in red; the system never kills an app on its own.

### Functional requirements
- NR1 the `hyprland-dialog` stand-in (`packaging/session-bin/hyprland-dialog`) takes only Hyprland's exact ANR call in en_US
  or fr_FR (`--title T --text X --buttons B`), tries every " - " split of "{title} - {class}" against Hyprland's client
  list, and with exactly one (split, client pid above 1) match reports (its own pid, that pid, "c:" class, "t:" title, "i:"
  Hyprland instance) to `anr report` and then `exec`s `sleep infinity` (same pid, silent, nothing forked) until Hyprland
  kills it; every other call, and every case below, `exec`s the stock dialog with the same arguments.
- NR1b the shell accepts a report only for a pid above 1, a class, its own Hyprland instance, and a window that no other pid
  it knows shares class and live title with (ADR-0035 decision 3-1); otherwise it answers `refused` (the reason goes to the
  journal) and the stand-in runs the stock dialog. An untitled window ("(unknown)" / "(inconnu)" in Hyprland's text) is
  matched by its empty title and reported with it.
- NR2 the shell marks that pid as not responding while one of its stand-ins lives: Force Quit lists the app with "(Not
  Responding)" (destructive colour); the selection follows a window, not a row: the user's choice is kept, and before the
  user moves it the panel selects the first such app and never moves away from the app shown; the app's Dock menu starts with a disabled "Application Not Responding" item and offers "Force
  Quit" in place of "Quit", for the marked processes only (Option + Force Quit: all of the app's); the app menu keeps "Quit"
  (owner decision Q16). At the confirmation a pid that no longer owns a window of the chosen class (pid reuse) is not
  killed, and a notice says "The application had already quit."; the others are.
- NR3 the mark clears within 1 s of the stand-in's end (the app answered, closed, or was killed): the shell checks the
  stand-ins every 250 ms while there is a mark.
- NR4 no alert, no sound, no focus change. `misc.anr_missed_pings = 3` (about 4.5 s).

### Acceptance criteria
- A-NR1 (L0, `tests/shell/hyprland_dialog.sh`) the stand-in with fake `qs`, `hyprctl` and stock dialog: en and fr texts
  parsed, titles with " - ", a leading "-" or a newline, a class with " - "; ambiguous (two processes, an app named to
  match another split), other-locale, malformed, refused, unanswered (10-s deadline, ADR-0035 decision 3-16: a slow shell
  under load is waited for, no shell ends the call at once) calls exec the stock dialog with the
  same pid and arguments; spawned by a double fork as Hyprland spawns it, the pipe stays open after "ok" and ends when the
  stand-in is killed; the texts match the installed Hyprland. (L0, `tests/shell/anr_ipc.sh`) the stand-in through the real `qs ipc` to
  the real service in an offscreen Quickshell: marked, cleared within 1 s, the shell's own refusals, a rename that lifts an
  ambiguity.
- A-NR3 (L0, `tests/unit/tst_notresponding.qml`) two processes of one app with the same class and title: refused; a pid
  reused between mark and confirmation: Force Quit refuses.
- A-NR2 (L1, `tests/shell/anr_nested.sh`) a foot window stopped with SIGSTOP in a nested session is marked within 12 s and no
  stock dialog opens; SIGCONT clears the mark, and so does killing the stopped app.

### Known limitations
No wait cursor (Hyprland only tints the window); the ANR state is known only through Hyprland's dialog call. A shell restarted
while an app hangs loses the mark until the app answers or closes (Hyprland runs its dialog once per hang); Force Quit still
lists the app. A Hyprland release that changes the texts makes the stand-in fall back to the stock dialog, and so does an app
without an app id (class "(unknown)") or a window that cannot be told apart. A nested Hyprland that crashes while an app hangs
leaves the stand-in waiting (it holds nothing) until logout; the real session's unit takes it down with Hyprland.

## 4b. Hyprland's config errors (H8, H9; ADR-0035 D-2; the notice built in step 3, not active on Hyprland 0.56.2)

### macOS reference behavior
macOS has no user-edited compositor configuration; a setting that cannot be applied is reported in words in a notification,
never as a red bar over the screen.

### Functional requirements
- CE1 Hyprland's error bar stays on: no Grassfield file sets `debug.suppress_errors` (ADR-0035 decision 3-15). Under the Lua
  config of Hyprland 0.56.2 `hyprctl configerrors` is empty (measured: every dispatch is an `eval`, which clears the
  errors, and the shell dispatches at start and after each reload), so the shell has no source to show them instead.
- CE2 the shell reads `hyprctl -j configerrors` when it starts and after every `configreloaded` event; each new non-empty
  set of errors posts one notice "Some settings could not be applied" whose body lists the first three lines as text, then
  "and N more"; the same set after a reload posts nothing; a reload that leaves no error withdraws the notice. No terminal,
  no journal (decision 3-6); the shell logs the count, never the lines. On 0.56.2 the answer is always empty and no notice
  shows.

### Acceptance criteria
- A-CE1 (L0, `tests/unit/tst_configerrors.qml`, `tests/shell/config_errors.sh`) Hyprland's reply parsed (none: `[""]`),
  anything else ignored; one notice per new set, withdrawn when empty, three lines shown as text ("<eof>" kept); a reload
  during a read is read once more.
- A-CE2 (L0, `tests/shell/session_input.sh`) no Grassfield config file sets `suppress_errors`. (L1, integrator) a broken
  config line in the nested session shows Hyprland's bar.

### Known limitations
Hyprland's bar, not a Grassfield notice, shows config errors on 0.56.2 (CE1); its runtime Lua errors (a binding's callback
that fails) and its other toasts stay Hyprland's too (ADR-0035 D-2).

## 5. Password prompts (gcr, udiskie, NetworkManager, KIO; S1–S4, S6, S8, K1; ADR-0035 D-9, D-12; owner decisions Q1, Q10–Q12)
Needs the amendment of the security rule (text in ADR-0035 D-9, owner decision Q12): applied in step 9a (the project's working rules,
master-prompt R12, ADR-0010 "Amendment 2026-10-31"), in force from the integrator's merge of the step 9a pull request, with the owner's agreement on that step; R12 applies (opus
PASS, fail closed where a secret is involved, nothing logged). Step 9a builds the bridge, its socket protocol (below) and
its unit; step 9b the shell's queue and secret sheets for gcr's `password` and `confirm` prompts (ADR-0035 "Delivered in
step 9b", decisions 9-15 to 9-22); step 9c udiskie's helper and the NetworkManager agent (planned as 9d, merged into 9c by
this step's brief; ADR-0035 "Delivered in step 9c", decisions 9-25 to 9-35); step 9e KIO's password server (ADR-0035
"Delivered in step 9e", decisions 9-36 to 9-50).
From 9b the shell connects in the session: gcr's prompts (gnome-keyring, pinentry-gnome3, gcr-ssh-agent) are drawn by the
shell; from 9c also an encrypted removable disk's password (udiskie) and NetworkManager's Wi-Fi secrets; from 9e the
passwords of network locations that KIO asks for (Files, the D-4 panel, any KF6 app); from step 10 BlueZ's pairing steps (section 8),
in the same queue and sheet.

### macOS reference behavior
System-modal alert centred on the active display, above every window, never on the lock screen: the requesting app's icon,
bold title, a message naming the requesting app ("“App” wants to use your confidential information stored in “item” in your
keychain."), a secure password field, a check box where relevant ("Remember this password in my keychain"), buttons "Deny"
and "Allow" (default) or "Cancel"/"OK". A wrong password shakes the alert and clears the field. Not visible to screenshots or
screen sharing. It does not look like the administrator authorization dialog. Encrypted disk: "Enter a password to unlock the
disk “Name”." with "Remember this password in my keychain", Cancel / Unlock. Server: "Enter your name and password for the
server “X”." with "Remember this password in my keychain", Cancel / Connect.

### Functional requirements
- SC1 `grassfield-prompter` (C++/Qt 6 and libgcr-4) owns `org.gnome.keyring.SystemPrompter` while the shell is connected
  (requested without `ALLOW_REPLACEMENT`, so nobody can take it away; queued behind a stock gcr-prompter that still holds it,
  which frees it 10 s after its last prompt); libgcr runs `BeginPrompting`/`PerformPrompt`/`StopPrompting` and the `sx-aes-1`
  exchange.
- SC2 (built in step 9b: `shell/security/SheetQueue.qml`, ADR-0035 9-15) one queue in the shell for every secret sheet and the polkit sheet: one sheet on screen at a time, in arrival order; a new
  request never takes the keyboard from the sheet on screen (the polkit sheet's `WlrKeyboardFocus.Exclusive` stays where it is,
  `shell/security/polkit/AuthAgent.qml:241`) and is shown only after that sheet is answered or cancelled; a request withdrawn by
  its caller (`StopPrompting`, `CancelGetSecrets`, BlueZ `Cancel`, the KIO client gone) leaves the queue unseen; at most 8
  secret requests wait, the 9th secret request is answered "cancelled"; a polkit request always queues, whatever the count.
- SC3 look and identity: a secret sheet is not the authorization sheet: no lock-and-shield glyph, never the title
  "Authentication required"; a fixed top row with the requester's icon and name that only the bridge fills, from the pidfd of
  `GetConnectionCredentials` (`ProcessFD` → PID → `/proc/<pid>/exe`, the pidfd checked alive after the read; trusted only when
  the executable and its parent directories are root-owned and not writable by the user, mapped only to a root-owned desktop
  entry; "Keyring" for gnome-keyring, "GnuPG" for gpg-agent, "SSH" for gcr-ssh-agent, "KIO" for KIO's worker executable
  `/usr/lib/kf6/kioworker` (role `kio`, step 9e, only while every file it maps executable is trusted: security review of
  step 9e, MINOR-2), each only for a process in the bridge's own mount and user namespaces (as an app's row: the
  integrator's review of PR #95); "Disks" for udiskie's helper `grassfield-askpass` in any namespaces (udiskie's unit runs
  it in its own, decision 9-26 amended); anything
  else, or no `ProcessFD`, "Unidentified program" and the path); then the caller's `title`, `message`, `description`
  as plain text, flattened and capped, in the secondary style, framed and introduced as the caller's; `warning` in red in that
  frame (step 9b, decision 9-18: under the field it read as the sheet's own error); a secure field (`password-new`: New and
  Verify fields and a strength bar from the length, decision 9-17); `choice-label` as a check box; the buttons are always
  Grassfield's "Cancel" and "OK", never the caller's `continue-label` / `cancel-label` (step 9b, decision 9-16); a `confirm`
  prompt has no field. Built in step 9b as a macOS alert (`shell/security/secret/SecretSheet.qml`, decision 9-18). A
  confirmation is always shown held, no key answering it before a click past the guard (decision 9-23); Return in New moves
  on to Verify, and an empty new password is sent only from OK (decision 9-24).
- SC3b the row names the program whose process opened the bus connection, not proof of whose code is asking (opus review
  of step 9a, MINOR-2; ADR-0035 9-4, 9-14): "Keyring", "GnuPG" and "SSH" can be made to ask by any program of the user,
  with text of its own. Under such a row (`onBehalf`) the caller's text is shown as unverified text from another program
  (the secondary style, introduced as such, for example "Another app sent this message:"), never as the Keyring's,
  GnuPG's or SSH's own words, never in the title's place, and nothing in the sheet vouches for it.
- SC4 (built in step 9b: `shell/security/secret/SecretAgent.qml`, decisions 9-19, 9-22) security rules of the polkit sheet: nothing over the lock (a request that arrives while locked waits and is shown after
  the unlock without the keyboard until a click 500 ms after it appears); the field is cleared after each answer and on close;
  `ImhSensitiveData`, no input method; Esc and Cancel answer "no"; the shell never logs any field. The surface's layer namespace
  `grassfield-secret` is hidden from screen sharing by a session layer rule (`no_screen_share`, accepted for layers by Hyprland
  0.56.2, `src/desktop/rule/layerRule/LayerRuleEffectContainer.cpp:23`).
- SC5 socket protocol (bridge ↔ shell): one JSON object per line, versioned (`prompter/1`); the bridge accepts only the shell
  (uid and cgroup checked). What can be wiped: the shell clears the field and drops its references and sends the password once;
  the QML strings the JavaScript engine made cannot be zeroed and may stay in the shell's heap until reused (known limitation,
  as for the polkit sheet today); the bridge reads the password into a buffer it zeroes after handing it to libgcr or to the
  D-Bus reply.
- SC6 fallback: shell not connected → the bridge releases the name (the stock gcr-prompter is activated for the next prompt) and
  unregisters its NetworkManager agent (built in step 9c: registered only while a shell that draws kind `nm` is connected,
  and again when NetworkManager comes back on the bus, decision 9-27); it takes them again when the shell reconnects; a
  request in flight when the shell disconnects is answered "no" (gcr: cancelled; NetworkManager: `NoSecrets`; KIO: its
  AuthInfo unmodified, then `org.kde.kpasswdserver6` is released 1 s later, step 9e, decisions 9-36, 9-37).
- SC7 udiskie (built in step 9c: `bridges/prompter/src/askpass.cpp`, decisions 9-25, 9-26): `grassfield-automount.service`
  runs udiskie with `--password-prompt "/usr/lib/grassfield/grassfield-askpass udiskie {device_presentation}"`;
  `grassfield-askpass udiskie <device>` opens a gcr prompt (title "Encrypted Disk", message "Enter a password to unlock the
  disk “%1”." with the device flattened; French with the system catalog), prints the password and a newline on stdout
  straight from gcr's secure memory, exit 0; cancel or a prompt that ends without an answer: no output, exit 1 (udiskie then
  leaves the disk locked); wrong arguments or stdout a terminal: exit 2 before asking; no prompt possible: exit 3. No
  "Remember this password" check box: udiskie's command interface cannot carry the choice back (its cache follows its own
  configuration). The bridge names the helper `disk` ("Disks"), on someone's behalf: any program can run it with a disk name
  of its own (SC3b).
- SC8 NetworkManager (built in step 9c: `bridges/prompter/src/NmAgent.{h,cpp}`, `NmSecrets.{h,cpp}`, decisions 9-27 to 9-35):
  the bridge's secret agent answers `GetSecrets` for `802-11-wireless-security` (WPA/WPA2 `psk`, WPA3 `psk`, WEP
  `wep-key<wep-tx-keyidx>`) and `802-1x` (the password, an EAP method that takes a name and a password, the connection's
  username shown read-only: NetworkManager keeps only secrets from an agent's reply, opus review of step 9c) of a Wi-Fi connection, when
  the flags allow interaction, with the sheet's Wi-Fi alert ("The Wi-Fi network “%1” requires a WPA2 password." / "… a WPA3
  password." / "… a WEP password." / "… requires WPA2 enterprise credentials.", "Requested by NetworkManager", "Username: …"
  for enterprise (read-only), Show password (never selectable or copyable, 9-34), Cancel / Join), always held until a click
  past the guard (9-28); Join answers the secrets, Cancel
  `UserCanceled`; `CancelGetSecrets` closes it (shown or queued, `AgentCanceled`); a request unanswered after 110 s is
  withdrawn (`NoSecrets`, NetworkManager stops waiting at 120 s); `SaveSecrets` is refused (`Failed`: nothing is stored in
  Grassfield, so NetworkManager asks another agent) and `DeleteSecrets` succeeds; NetworkManager keeps system-owned secrets as
  the connection says. It accepts calls only from the current owner of `org.freedesktop.NetworkManager` on the system bus,
  asked when each call arrives; other callers get `PermissionDenied` and no sheet. Without interaction allowed, for VPN, wired
  802.1X, EAP-TLS, LEAP, OWE, an enterprise connection without a stored username: `NoSecrets` without a sheet. VPN: NetworkManager shows no VPN dialog itself (an agent like
  nm-applet runs the VPN plugin's auth dialog, which this one does not), so a VPN that needs secrets at connect time fails,
  as it does today.
- SC9 KIO network passwords (ADR-0035 D-12 b; built in step 9e: `bridges/prompter/src/KioServer.{h,cpp}`, `KioAuth.{h,cpp}`,
  decisions 9-36 to 9-50): the bridge serves `org.kde.KPasswdServer` at `/modules/kpasswdserver` (`checkAuthInfoAsync`,
  `queryAuthInfoAsync`, `addAuthInfo`, `removeAuthInfo`, the two result signals; KIO's types, its AuthInfo
  `(ysssssssssbbbba{s(siv)})` read with bounds; the LEGACY `ay` methods not served) and holds `org.kde.kpasswdserver6`
  (flags 0: queued behind kiod6 when kiod6 holds it, replaced by nobody) only while a shell that draws kind `kio` is
  connected, or while kiod6 runs without it (9-36); it keeps kpasswdserver's rules (sequence numbers, the session cache and
  its quirks, one prompt per window and per server, checks that wait for a query of their server, the user's Cancel kept, a
  changed name moving its entry) and shows the server sheet: "Enter your name and password for the server “%1”." (a host
  name only, 9-42), who asked from the caller's credentials ("Requested by KIO for an app" for KIO's worker running only
  trusted code, an app's name, or an unidentified program and its executable, 9-43), the realm framed as the server's
  unverified words, the name field (read-only or absent as the caller says; a field of its own, unlike a network's read-only
  username), the password field (no Show password), Remember this password (offered when the caller offers it; off at first,
  on when the keyring already holds one, 9-41), a line under it when the keyring that would keep it has no password ("Your
  keyring has no password: a password remembered here is stored unencrypted on this computer.", known only for
  gnome-keyring, 9-45), Cancel / Connect (a password, and a name when asked, 9-47); after a failed login "The name or
  password was not accepted. Try again." (the worker's own message never shown, 9-40); always held until a click past the
  guard (9-38). Remembered passwords go to the Secret Service through libsecret (schema `org.grassfield.NetworkPassword`,
  9-44), never through KWallet's API, only when the user ticked Remember; in the Grassfield session the Secret Service stays
  gnome-keyring's (ADR-0035 Q17-b); bridge down or no shell → D-Bus activation starts kiod6 (KDE's dialog, as before),
  except after kiod6 started while the bridge held the name: kiod6 never takes it then (it registers its names only when it
  starts), so the bridge keeps it and answers "nothing" at once until kiod6 leaves the bus (9-36, security review of step
  9e, MINOR-1).
- SC9b results go to the caller only (counter-review of PR #13, minor; built in step 9e): kpasswdserver broadcasts
  `checkAuthInfoAsyncResult` and `queryAuthInfoAsyncResult`, credentials included, to every listener on the session bus (KIO
  `src/core/org.kde.KPasswdServer.xml:4-15`, `src/kpasswdserver/kpasswdserver.cpp:330, 852, 883`); the bridge sends each
  result as a signal addressed to the caller's unique name (`g_dbus_connection_emit_signal` with a destination, after the
  method reply that gave the requestId), which KIO's real client receives unchanged (`tests/security/kio_passwd.sh`). A
  cached credential goes only to the connection that asks; any same-user process can still ask for one by its URL, as with
  kpasswdserver today (upstream protocol, known limitation). Addressing keeps results from match rules and eavesdropping,
  not from a bus monitor: a same-user process that calls `BecomeMonitor` (the session bus allows it to any connection of
  its user) sees every message, a targeted result and its password included, as it sees every other secret on the session
  bus (the reviewer's probe; known limitation, security review of step 9e, NIT-1).
- SC9c never blocks on itself (counter-review of PR #13, minor; built in step 9e): storing into a locked keyring makes
  gnome-keyring ask through gcr's prompter, which is the bridge. The bridge therefore stores with libsecret's asynchronous
  calls (`secret_password_storev_binary` with a callback on its GLib main context), answers `addAuthInfo` at once, looks
  remembered passwords up asynchronously too (a check unlocks the keyring when an item is there; a query searches without
  unlocking), and makes no synchronous call that can cause a prompt; the unlock prompt then takes its turn in the queue
  (`kio_passwd.sh`: addAuthInfo answered in milliseconds with the keyring locked, the unlock prompt in the shell, other
  calls answered meanwhile). A call that may hold one of gnome-keyring's unlock prompts is never cancelled while that
  Secret Service runs (gnome-keyring 51.1 aborts when an unlock prompt waiting behind another is dismissed); a store holds
  one of 8 places for at most 120 s; the stores and searches sent to a Secret Service that leaves the bus end at once
  (ADR-0035 9-50).
- SC10 the Secret Service handover (ADR-0035 D-12, owner decision Q17-b, step 2c; `grassfield-secrets-handover`, a user unit
  the session starts before the shell). Nothing for the user to do. At the session's start a ksecretd left over from an
  earlier session that still holds `org.freedesktop.secrets` is made to quit, so apps opened from the Dock find the keychain;
  the shell waits for that at most 10 s. Once per user, everything KWallet holds is copied into the keychain: the passwords
  that libsecret clients (Chromium, git helpers) saved while it held that name, and KWallet's own entries, which QtKeychain
  apps now look up in the keychain (ADR-0035 decision 2c-10); never over an item the keychain already holds (of two items
  with the same attributes, the most recently changed; never an empty value). KWallet keeps its copies. A user whose own
  `kwalletrc` gives the Secret Service back to KWallet is left alone. KWallet asks for its password only when something must
  move and the wallet is locked (its own dialog, K2), the keychain only when it is locked or does not exist yet, and the
  handover asks at most once, ever (decision 2c-9). When something moved, one notice: "Saved passwords moved" / "Passwords
  that apps had saved elsewhere on this computer are now kept with your other saved passwords." A refused or unanswered
  question ends it for good, with one notice: "Saved passwords not moved" / "Passwords that apps had saved elsewhere on
  this computer stay where they were. Apps that used them may ask you to sign in again." A peer that is not the expected
  program, or an error before any question, leaves everything as it was, and the handover runs again at the next session.
  No item, label or value is logged; the helper is not dumpable and its unit allows no core file and no swap. Code quality:
  `just check-tidy` covers the compositor only; the helper is built with `-Wall -Wextra` (no warning), its tests run under
  ASan and UBSan, and a one-off clang-tidy run with the compositor's checks (`clang-analyzer-*`, `bugprone-*`,
  `performance-*`; 2026-10-27, LLVM 23.1) found no analyzer finding; the two findings worth a change were fixed (sizes
  narrowed to int, a const local that blocked a move), and what remains is Qt's own idiom (static `QStringLiteral`
  constants, `S_IW*` bit masks, a `QDBusArgument` operator returning its argument, an enum's base type).

### prompter/1 protocol (bridge and shell; built in step 9a, ADR-0035 decisions 9-1 to 9-13; kind nm and role disk in step 9c, 9-26 and 9-33; kind kio and role kio in step 9e, 9-38 to 9-47; kind bluetooth and message progress in step 10, 10-5)
Transport: the Unix stream socket `$XDG_RUNTIME_DIR/grassfield/prompter.sock` (directory 0700, socket 0600), served by
`grassfield-prompter`; UTF-8 JSON, one object per line, ended by a line feed. The bridge accepts one peer at a time, only
one that runs as the user and whose cgroup is the unit named by the bridge's `--peer-unit` (`grassfield-shell.service`;
read race-free through `SO_PEERPIDFD` on Linux 6.5 and later). A refused peer gets `{"type":"error","code":"refused"}`, a
second shell `{"type":"error","code":"busy"}`, and the connection is closed. Nothing secret flows from the bridge to the
shell; the shell sends a password once, in its answer, and the bridge decodes it straight into gcr's secure memory.

Bridge to shell:
- `{"v":"prompter/1","type":"hello","bridge":"<version>","kinds":["password","confirm"],"max":8}`: first line, at once; `kinds`
  goes on with `"nm"` when the bridge's NetworkManager agent runs (it has a system bus, step 9c), `"kio"` when its KIO
  password server runs (step 9e) and `"bluetooth"` when its BlueZ pairing agent runs (it has a system bus, step 10).
- `{"type":"name","state":"released"|"queued"|"owned"}`: after the shell's hello and at every change of
  `org.gnome.keyring.SystemPrompter`'s ownership (queued: another process holds it, usually the stock gcr-prompter for 10 s
  after its last prompt; the bridge gets it when that process lets it go).
- `{"type":"prompt","id":"p<N>","kind":"password"|"confirm","requester":{...},"texts":{...},"choice":{...}|null,
  "passwordNew":bool,"strength":bool}`:
  - `id`: `p` and a decimal number, never reused while the bridge runs;
  - `requester`: `role` (`app`, `keyring`, `gnupg`, `ssh`, `disk`, `kio` or `unidentified`), `name` (the desktop entry's
    unlocalised `Name` for `app`, empty otherwise: the shell names `keyring` "Keyring", `gnupg` "GnuPG", `ssh` "SSH", `disk`
    "Disks", `kio` "KIO" and `unidentified` "Unidentified program" in its own translated words), `desktopId` and `icon` (the
    entry's, for `app`), `path` (the caller's executable when known, shown in the secondary style for `unidentified`),
    `identified` (true for `app`, `keyring`, `gnupg`, `ssh`, `disk`, `kio`), `onBehalf` (true for `keyring`, `gnupg`, `ssh`,
    `disk` and `kio`: these programs
    ask for others and any program of the user can make them ask, so the caller's text under the row is another program's
    unverified text, SC3b; `disk` is `/usr/lib/grassfield/grassfield-askpass`, udiskie's password command, step 9c). Only the bridge fills it, from the caller's bus credentials (SC3); it names the program whose process
    opened the connection: an `app` row only for a process that is not traced and runs nothing but trusted code;
  - `texts`: `title`, `message`, `description`, `warning`, `continue`, `cancel`: the caller's own text, plain, on one line,
    capped (title 128, message 256, description 1024, warning 256, buttons 32 UTF-16 code units, an ellipsis when cut);
    empty when the caller set none (the shell then uses its own words, "OK" and "Cancel");
  - `choice`: the check box (`label`, capped at 128, and `chosen`, its initial state) or null when there is none;
  - `passwordNew`: a new password (New and Verify fields); `strength`: show the strength meter (both only for `password`).
- `{"type":"prompt","id":"p<N>","kind":"nm","network":{"ssid":"...","security":"wpa"|"wpa3"|"wep"|"enterprise",
  "identity":"..."}}` (step 9c): a NetworkManager request, sent only for a call whose sender is the current owner of
  `org.freedesktop.NetworkManager` on the system bus, so it carries no requester object (the shell draws its own row:
  "Wi-Fi", "Requested by NetworkManager"); `ssid` the connection's SSID, plain, at most 64 UTF-16 code units, never empty,
  shown only as a quoted field of the sheet's sentence; `security` WPA/WPA2 Personal, WPA3 Personal, WEP or WPA2 Enterprise;
  `identity` the connection's own username for `enterprise`, never empty there (a connection without one is not asked),
  shown read-only (NetworkManager keeps only secrets from an agent's reply), empty otherwise.
- `{"type":"prompt","id":"p<N>","kind":"kio","requester":{...},"server":"<host>[:<port>]","login":{"name":"...",
  "nameMode":"edit"|"fixed"|"none","realm":"...","retry":bool,"remember":"none"|"off"|"on",
  "keyring":"protected"|"unprotected"|"unknown"}}` (step 9e): a KIO request; `requester` as a gcr prompt's (resolved from
  the caller's credentials; KIO's worker is `kio`); `server` the URL's host in its ASCII form, lower case, letters, digits,
  '-', '_' and dots, or an IPv6 address in brackets, and its port: never free text (the shell refuses anything else);
  `name` the name field's first text (the caller's user name, else the remembered one), at most 256 UTF-16 code units;
  `nameMode` editable, shown only (the caller's readOnly) or absent (`hide-username-line`, then `name` is empty); `realm`
  the server's own words, plain, at most 256 units, shown framed as unverified; `retry` the worker says the last name and
  password failed (its message itself is never sent); `remember` "Remember this password" not offered, off or on at first;
  `keyring` the protection of the keyring that would keep a remembered password ("unknown" when `remember` is "none").
- `{"type":"prompt","id":"p<N>","kind":"bluetooth","device":{"name":"...","address":"XX:XX:XX:XX:XX:XX","icon":"..."},
  "pairing":{"mode":"pin"|"passkey"|"display-pin"|"display-passkey"|"confirm"|"authorize"|"authorize-service","code":"...",
  "entered":0-6,"service":"...","uuid":"..."}}` (step 10): a BlueZ pairing step, sent only for a call whose sender is the
  current owner of `org.bluez` on the system bus, so it carries no requester object (the shell draws its own row, role
  `bluetooth`); `name` the device's Alias (else its Name, else its address), plain, at most 64 UTF-16 code units, never
  empty, shown only as a quoted field of the sheet's sentence; `address` the device's, upper-case hexadecimal, from the
  object path bluetoothd gave; `icon` one of "", `keyboard`, `mouse`, `gamecontroller`, `headphones`, `speaker`, `phone`,
  `laptop`, `display`, `printer`, `camera` (each a Grassfield glyph); `mode` the Agent1 method: `pin` (RequestPinCode) and
  `passkey` (RequestPasskey) ask for a code, `display-pin` (DisplayPinCode) and `display-passkey` (DisplayPasskey) show one to
  type on the device, `confirm` (RequestConfirmation) shows one to compare, `authorize` (RequestAuthorization) and
  `authorize-service` (AuthorizeService) ask to allow an incoming pairing or service; `code` the passkey as 6 digits for
  `display-passkey` and `confirm`, the PIN (1 to 16 ASCII letters and digits) for `display-pin`, "" otherwise; `entered` the
  digits typed on the device for `display-passkey` (0 to 6), 0 otherwise; `service` (`audio`, `remote-control`, `headset`,
  `hands-free`, `file-transfer`, `object-push`, `network`, `input`, `phonebook`, `messages`, `serial`, `dial-up` or `other`)
  and `uuid` (canonical, lower case) for `authorize-service`, "" otherwise.
- `{"type":"progress","id":"p<N>","entered":0-6}` (step 10): the digits typed on the device changed for a `display-passkey`
  request the shell holds; the shell updates that request and nothing else. One for an id the shell does not hold is ignored
  (it crossed the shell's answer); one for an id it holds that shows no passkey closes the connection.
- `{"type":"cancel","id":"p<N>"}`: the request is withdrawn (its caller stopped prompting or left the bus, NetworkManager
  cancelled it or left the bus, bluetoothd cancelled it, left the bus or reported the device paired, its answer's time ran
  out, or the bridge cancelled it after a wrong answer): the shell removes its sheet, shown or still queued, and does not
  answer it.
- `{"type":"error","code":"<code>","message":"<text>"}`: `refused`, `busy`, `version`, `bad-line`, `too-long`,
  `unknown-type`, `bad-answer`.

Shell to bridge (at most 16 KiB per line):
- `{"v":"prompter/1","type":"hello","shell":"<version>","kinds":[...]}`: the first line, once; `kinds` lists what the
  shell draws. The bridge asks for the name only after it, and sends only requests of a listed kind (another kind is
  answered "cancelled" to its caller without reaching the shell).
- `{"type":"answer","id":"p<N>","result":"ok"|"cancel"|"refused","password":"...","choice":true|false,"identity":"..."}`:
  `password` only for a `password`, `nm` or `kio` request answered `ok` (at most 4096 bytes of UTF-8 after decoding; an empty
  one is a password for gcr, never for `nm` or `kio`); `choice` only when the prompt had a check box (never for `nm`; for
  `kio`, Remember this password, only when offered); `identity` only for a `kio` request of `nameMode` "edit" answered `ok`
  (not empty, at most 1024 bytes), never for `nm` (NetworkManager keeps only secrets: an `nm` answer with a name cancels its
  request). `refused` is the shell's own refusal (beyond its bound of 8, or without a queue) and carries nothing: gcr gets
  "cancelled", NetworkManager `NoSecrets`, never the user's `UserCanceled` (opus review of step 9c), KIO's client its
  AuthInfo unmodified with no cancelled entry kept (only the user's Cancel leaves one; ADR-0035 9-37), bluetoothd `Rejected`.
  A `kio` cancellation carries nothing. An `nm` or `kio` answer that breaks these rules cancels its request (NetworkManager
  gets `NoSecrets`; KIO's client its AuthInfo unmodified). A `bluetooth` answer (step 10): `ok` with `password` the PIN (1 to
  16 ASCII letters and digits) for `pin` or the passkey (exactly 6 ASCII digits) for `passkey`, with nothing for `confirm`,
  `authorize` and `authorize-service`; never `ok` for `display-pin` or `display-passkey` (only `cancel`); `cancel` carries
  nothing (bluetoothd gets `Canceled` for a code or a comparison, `Rejected` for an authorization: Decline; for a code shown
  the bridge asks bluetoothd to `CancelPairing`); one that breaks these rules cancels its request (`Rejected`).

The shell's reading (step 9b, decision 9-20; `shell/security/secret/Prompter.js`): exactly these messages with exactly
these keys and types, texts within the caps above, a requester consistent with its role, only the kinds of its hello;
anything else, a line over 16384 UTF-16 code units, a duplicate id or a prompt before the bridge's hello closes the
connection; an `error` before the bridge's hello is its refusal (logged); a `cancel` for an id the shell does not hold is
ignored. The shell answers each request once, only an id it holds, an "ok" only for the request on screen with the keyboard;
an empty password only for a new one. It holds at most 8 secret requests (shown or waiting) and answers a ninth "cancelled"
at once. After a lost connection it tries again after 1 s, doubling to 30 s, reset by the bridge's next hello.

Rules (fail closed: no answer is ever invented):
- At most 8 requests outstanding; a 9th caller is answered "cancelled" at once and the shell never sees it. At most 64
  gcr prompts open, at most 8 for one bus connection: a connection's ninth `BeginPrompting` is answered
  `org.freedesktop.DBus.Error.LimitsExceeded` and never reaches gcr; a `PerformPrompt` of the wrong shape is answered
  `org.freedesktop.DBus.Error.InvalidArgs`. A connection's count follows what gcr holds (opus counter-review of step 9a,
  MINOR-A and MINOR-B): a `BeginPrompting` counts with the prompter's interface named only, a prompt stops counting when
  gcr ends it (its `PromptDone` to the caller, the caller's error to its `PromptReady`, the caller leaving the bus), and
  every count goes when the prompter's name leaves the bridge; when the shell goes, the bridge closes every open gcr prompt
  in the next main loop turn (its callers cancelled already, on seeing the name go; never from inside gcr's own callbacks,
  opus final check of step 9a), so neither gcr nor the count keeps them.
- A peer whose pidfd the kernel will not give is refused, except on a kernel without `SO_PEERPIDFD` (ENOPROTOOPT); in a
  session only slices may lie between `user@<uid>.service` and the shell's unit. Refused connections are logged once per
  10 s, with the count of the others.
- An answer to an id that is not outstanding is ignored. A wrong answer to an outstanding id (an unknown key, a password
  where none is asked or missing for `ok`, a choice where none was shown, a password over 4096 bytes) cancels that request
  (`cancel` to the shell, "cancelled" to the caller).
- A line that cannot be attributed (not one flat JSON object of strings, booleans, null and arrays of strings; over
  16 KiB; an answer without a usable id; anything before hello; another protocol version) closes the connection: every
  outstanding request is cancelled and the name is released until the shell connects again. The ninth unknown or repeated
  message of a connection closes it too.
- When the shell disconnects, every outstanding request is answered "cancelled" and the name is released; the stock
  gcr-prompter is then activated for the next prompt, as before step 9.
- Kind `nm` (Wi-Fi and 802.1X secrets) is built in step 9c, `kio` (a server's name and password) in step 9e and `bluetooth`
  (pairing, with its `progress` message) in step 10; each adds its own prompt and answer fields within `prompter/1`. A change to the fields of
  an existing kind is `prompter/2`; a new value of a field (the role `disk`, step 9c) is not: bridge and shell ship together,
  and a shell that does not know it closes the connection (9-26).
- NetworkManager's, KIO's and bluetoothd's requests share the ids and the bound of 8 with gcr's; the 9th, from any side, is
  refused (gcr: cancelled; NetworkManager: `NoSecrets`; KIO: its AuthInfo unmodified; bluetoothd: `Rejected`).

### Acceptance criteria
- A-SC1 (L0) a fake gcr client on a private bus gets the password through the exchange; a fake process queued on the name never
  receives a prompt while the bridge holds it; with the shell disconnected, the fake stock prompter is activated.
- A-SC2 (L0) queue: with the polkit sheet open and its field focused, a gcr request arrives: the polkit sheet keeps the keyboard,
  the gcr sheet shows only after the polkit answer; a withdrawn request never shows.
- A-SC3 (L0) identity: a caller whose text says "Authentication required" still gets the secret sheet's header with its resolved
  executable; the sheet never shows the polkit glyph.
- A-SC3b (L0) identity sources: a fake caller that exits and whose PID is reused before the read, a caller run from the home
  directory, and a bus that gives no `ProcessFD` all show "Unidentified program"; a polkit request arriving with 8 secret
  requests waiting is queued, not refused.
- A-SC4 (L0) a fake NetworkManager on a private system-style bus asks for a PSK and receives the typed secret; a VPN request
  gets "no secrets"; a call from another sender gets an error and no sheet.
- A-SC5 (L0) a fake KIO client asks `queryAuthInfoAsync` and receives the typed credentials; "Remember" writes to a fake Secret
  Service, never to a KWallet name.
- A-SC5b (L0) a second fake client listening to the bridge's signals never receives another client's result; with the fake
  Secret Service's collection locked, "Remember" raises an unlock prompt in the queue after the server sheet and nothing
  hangs (the bridge answers other calls meanwhile).
- A-SC6 (L0) mutants: removing the uid/cgroup check, the lock refusal, the queue's focus rule, the caller checks or the buffer
  zeroing fails a test.
- A-SC7 (L1) nested: pinentry-gnome3 with a throwaway GNUPGHOME and key asks through the Grassfield sheet (screenshot, "visual
  NOT verified" otherwise); udiskie with a loop-mounted LUKS image and an sftp location are the owner's L2 checks.
- A-SC8 opus PASS.
- Step 9a covers the bridge's part of A-SC1 (a real libgcr-4 client and pinentry-gnome3 get their password through the
  exchange; a process queued on the name, even asking to replace its owner, receives no call; with the shell disconnected
  the name is released), A-SC3 and A-SC3b for the requester the bridge sends (a caller that names another connection in
  its own properties, a caller that exits, an executable the user can write: `tests/unit/prompter`,
  `tests/security/prompter_bridge.sh`), the bound of 8 of A-SC2 and A-SC6's mutants of the bridge (the uid and cgroup check,
  the caller checks, the bound); the sheets, the queue's keyboard rule and the polkit sheet's place in the queue are step
  9b's. The buffer wiping of A-SC6 had no test in step 9a (the integrator's review of PR #94); since the review of PR #95
  the line handling is `takeLines` (`Protocol.h`), unit-tested, and `prompter_bridge.sh --mutants` kills its two wipes
  (`lines-not-wiped`, `rest-not-wiped`), with the name taken before the hello, the answer without a shell, the pidfd's
  re-check and the known callers' namespaces; `tests/fuzz/prompter_protocol.sh` fuzzes the same reading.
- Step 9b covers A-SC2 (`tests/security/secret_sheets.sh`: the polkit sheet keeps the keyboard while a gcr request arrives,
  which shows after, held, and the reverse; a withdrawn request never shows; the ninth cancelled), A-SC3 for the sheet (a
  caller whose text says "Authentication required" gets the secret sheet's title with the bridge's requester, no lock or shield
  glyph), A-SC3b's polkit request queued behind 8 secret requests, A-SC6's mutants of the shell (the queue's focus rule, the
  lock refusal, the click guard, the hold after a wait, an "ok" without the keyboard, the bound, the caller's text or labels in
  the sheet's places, the client's strictness and its single answer: `secret_sheets.sh --mutants`,
  `secret_bridge.sh --mutants`), and A-SC1 through the shell (`tests/security/secret_bridge.sh`: the real bridge on a private
  bus, the shell's real client in Quickshell, libgcr's client gets the password the shell answered).
- A-SC7 nested scenario for step 9b (owner approval: `just nested-up`, `just shot`): with the nested session up, build the
  bridge (`bridges/prompter/build-direct.sh`), start it as a development run on the nested session's private bus
  (`env DBUS_SESSION_BUS_ADDRESS=$(cat .dev/bus.address) GF_TEST_BUS=1 GF_TEST_BUS_DIR=/tmp GRASSFIELD_DEV=1
  .dev/build/grassfield-prompter --socket .dev/run/prompter.sock --peer-unit <the last component of the dev shell's cgroup>`),
  restart the dev shell with `GRASSFIELD_PROMPTER_SOCKET=$PWD/.dev/run/prompter.sock scripts/dev/shell-run.sh`, check
  that `tests/visual/ipc.sh secrets state` (the dev hook, nested environment) says `ready owned`, then ask with libgcr's test client on that
  bus (`python3 -I tests/fixtures/prompter-client.py password --title "Unlock the login keyring" --choice "Remember"`, same
  environment as the bridge): `just shot secret-sheet` (the alert, its requester row, the framed caller text), type a
  password and Return (the client prints it), then `pkexec --help`-safe polkit with a gcr request arriving meanwhile (the
  polkit sheet keeps the keyboard; the secret sheet shows after, held). Visual NOT verified in step 9b.
- Step 9c covers A-SC4 (`tests/security/nm_agent.sh`: the real bridge on a private "system" bus with a fake NetworkManager:
  WPA2, WPA3, WEP and enterprise secrets typed in a fake shell reach it; flags without interaction, VPN, EAP-TLS and a wired
  connection get `NoSecrets` without a sheet; a caller that does not own `org.freedesktop.NetworkManager` gets
  `PermissionDenied` and nothing is shown, its `CancelGetSecrets` cancels nothing; `CancelGetSecrets` withdraws the sheet;
  the shell's departure unregisters, its return registers, a restarted NetworkManager is registered with again; the bound of
  8 shared with gcr; the 110-s withdrawal; `--mutants`: the sender check, the unregistering, the VPN and interaction
  refusals, the cancellation, the kinds gate, the user's cancel, the name check, the timeout, `SaveSecrets`, the
  re-registration), the Wi-Fi sheet (`tests/security/secret_sheets.sh`: held, Join's length rule, Show password,
  enterprise, NetworkManager's cancel while typed into, the queue with polkit and gcr, the lock hiding the shown password;
  mutants), the shell's real client end to end (`tests/security/secret_bridge.sh` e2e with the fake NetworkManager) and SC7
  for the helper (`tests/security/askpass.sh`: through the real bridge, the passphrase printed once with a newline, exit 0;
  Cancel and the shell's departure exit 1 with nothing printed; wrong arguments and a terminal exit 2; French; the stock
  prompter's stand-in by D-Bus activation when no bridge holds the name; the disk role when the helper is the installed
  root-owned file; mutants).
- A-SC7 nested scenario for step 9c (owner approval: `just nested-up`, `just shot`): as for step 9b, with a second private
  dbus-daemon as the "system" bus (the session bus's test configuration with `<type>system</type>` and its own socket under
  `/tmp`, as `tests/security/nm_agent.sh` writes it) and the fake NetworkManager on it (`env DBUS_SYSTEM_BUS_ADDRESS=<that
  bus> GF_TEST_BUS_DIR=/tmp python3 -I tests/fixtures/fake-networkmanager.py --log /tmp/nm.log --commands /tmp/nm.cmd`), the
  bridge started with the same `DBUS_SYSTEM_BUS_ADDRESS`; once `/tmp/nm.log` says `#register`, `echo 'get w1
  802-11-wireless-security 0x1 ssid=Café' >/tmp/nm.cmd`: `just shot wifi-sheet` (the Wi-Fi glyph, the sentence with the SSID,
  "Requested by NetworkManager", held), click past the guard, type a password, tick Show password (`just shot
  wifi-sheet-shown`), Return (`/tmp/nm.log` gets the psk); then `.dev/build/grassfield-askpass udiskie /dev/sdz1 >/tmp/disk.out`
  on the nested session's bus: `just shot disk-sheet` (the drive glyph, "Disks asks for a password", the helper's text framed
  as another program's). Visual NOT verified in step 9c; a real NetworkManager, a real udiskie with a LUKS image and the
  helper's identification inside udiskie's sandbox (`PrivateUsers=self`) are the owner's L2 checks.
- Step 9e covers A-SC5 and A-SC5b (`tests/security/kio_passwd.sh`, on a private session bus: KIO's REAL client,
  `KPasswdServerClient` of the installed KF6 KIOCore (`tests/fixtures/kio-passwd-client.cpp`), gets the name and password
  typed in a fake shell, the anonymous field turned false; addAuthInfo then a check answered from the session's cache; with
  Remember the password is in the REAL gnome-keyring (a throwaway keyring) under its attributes, never in KWallet, and a
  check gets it from there once the session's entry is removed; a query after a failed login says retry, ticks Remember and
  fills the name from the keyring; the user's Cancel kept; a second listener hears none of the bridge's results (it hears
  the broadcasts of kiod6's stand-in, the control); a stranger shown as an unidentified program; KIO's real ftp worker
  (`/usr/lib/kf6/kioworker` with `kio_ftp`, `tests/fixtures/kio-stat.cpp` and `ftp-login-server.py`) shown as `kio`, its
  login reaching the test server, its own addAuthInfo remembering it, a second job without a sheet; addAuthInfo answered at
  once with the keyring locked, the keyring's unlock prompt in the shell after the server sheet while other calls are
  answered, the password stored once unlocked; "unprotected" for Omarchy's plain-text keyring, "protected" for a keyring
  with a password, "unknown" for a fake Secret Service; one caller's ninth request and the shell's ninth (seven gcr prompts
  and a KIO sheet) answered "nothing" at once; wrong answers; the shell's refusal (no cancelled entry); a changed name and
  the old URL's next query; no name field; `<NoAuthPrompt>`; the caller leaving; the shell leaving (the client answered, the
  name released, kiod6's stand-in activated); no shell or a shell without kind `kio`: the name not held, kiod6's stand-in
  activated or keeping it; KDE's real kiod6 started while the bridge holds the name (kept with no shell and a check
  answered at once, taken by a bridge started then, released when kiod6 goes); a worker plugin of the user's run by
  the real kioworker shown as an unidentified program; the keychain's calls (a remembered entry in memory only while its
  window lives, gnome-keyring up when a check's caller leaves while its unlock prompt waits behind a store's, a store's
  place freed after its time, gnome-keyring killed: the waiting stores end); oversized AuthInfo and the LEGACY method
  refused; no test password in the bridge's output;
  `--mutants`: 14 of the server, among them a broadcast result, a requester trusted without its credentials, a synchronous
  store, Remember ignored and the kinds gate, and 6 of the cache key and the cache against the unit tests, all caught), the
  server sheet (`tests/security/secret_sheets.sh`: held, Connect's rule, Remember and the keyring's line, a fixed name, the
  realm framed, retry, an unidentified requester, a free-text server refused; mutants) and the shell's real client end to
  end (`tests/security/secret_bridge.sh`).
- A-SC7 nested scenario for step 9e (owner approval: `just nested-up`, `just shot`): as for step 9b, with the bridge started
  on the nested session's private bus (`--socket .dev/run/prompter.sock`) and the dev shell restarted on it; once
  `tests/visual/ipc.sh secrets state` says `ready owned`, build KIO's client (the `g++` line of `tests/security/kio_passwd.sh`)
  and run it on that bus (`env DBUS_SESSION_BUS_ADDRESS=$(cat .dev/bus.address) .dev/build/kio-passwd-client`), typing
  `query sftp://files.example/home - - keep skipcache`: `just shot server-sheet` (the globe glyph, "Enter your name and
  password for the server “files.example”.", "Requested by KIO for an app", Remember, held), click past the guard, type a
  name and a password, `just shot server-sheet-typed`, Connect (the client prints them); then the same query with
  `Login_failed` as its third field: `just shot server-sheet-retry` (the retry line); with a keyring without a password as
  the nested bus's Secret Service (gnome-keyring started on that bus in a scratch home holding Omarchy's plain-text
  `Default_keyring`): `just shot server-sheet-keyring` (the line under Remember). Visual NOT verified in step 9e; KIO's sftp
  and smb workers against real servers, a real gnome-keyring unlock prompt on screen and Files opening a network location
  are the owner's L2 checks.
- A-SC9 (L0) the handover against fakes on a private bus (`tests/integration/secrets_handover.sh`): the items move once and
  an item the keychain holds is kept; KWallet's own entries (stored as kwalletd 6.29 stores them) move too, and so does an
  older entry KWallet lists only once open; nothing is final from a locked listing that lists nothing; an empty value is
  not copied; a refused or unanswered question creates nothing, ends the handover for good with its notice, and the next
  login asks nothing; a missing default keychain is created; a leftover ksecretd quits, or gets SIGTERM, before readiness;
  a holder that is another program, or a Secret Service that is not gnome-keyring, is left alone and nothing is read or
  written; both notices in English and French; of two items with the same attributes only the newest moves; the user's own
  `kwalletrc` keeps KWallet and nothing is done; a dev run on any bus but a private test bus is refused; in a user namespace
  like `PrivateUsers=self` no peer is identified and nothing is done (why the unit has no namespace option, checked
  statically); the helper is not dumpable; with the real gnome-keyring as the keychain, what moved is read back through
  libsecret; the real ksecretd quits when asked; no item, label or value in any output. Opus PASS (secret path).

### Known limitations
Name ownership is the only authorization (upstream design): a same-user process can still show a fake stock prompt through
gcr-prompter while the bridge is down, and one that holds or is queued for `org.gnome.keyring.SystemPrompter` when the
shell goes gets the next prompts (the bridge releases the name then, by design: never blocking); a same-user process that
owns the name before the bridge asks for it keeps it (the bridge says "queued" and logs who holds it). The socket's
checks stop other processes of the user from passing for the shell, not same-user code that sets out to: the user owns
their systemd manager's cgroups and can move a process into the shell's unit, and the shell's own children that stay in
its cgroup (its helpers; an application started before `uwsm-app` is detected, ADR-0011) could connect while the shell is
not connected (out of scope as for every Grassfield socket, security.md); on a kernel without `SO_PEERPIDFD` at all
(before 6.5) the cgroup is read through the PID `SO_PEERCRED` gives, and a peer that exits and whose PID a process of the
shell's unit reuses in between would pass (later kernels refuse such a peer). An interpreter or a launcher that runs other
code is shown as "Unidentified program" with its path even when the code it runs is an app (9-4). The requester row
names the program whose process opened the bus connection, not proof of whose code is asking (opus review of step 9a,
MINOR-2; ADR-0035 9-14): "GnuPG", "Keyring" and "SSH" can be driven by any program of the user (`gpg-connect-agent`'s
`GET_PASSPHRASE` with its own description, `pinentry-gnome3` run directly, `ssh-add`, an app asking gnome-keyring to
unlock), hence SC3b; a process can connect to the bus, then fork and exec a trusted program while its child speaks on the
connection, or, as the ancestor of a trusted program, ptrace it, change its code and detach; an app's row is refused to a
traced process and to one that maps code from untrusted files (`LD_PRELOAD`, `LD_LIBRARY_PATH`, a library replaced
since it was loaded), which also leaves an app unidentified after an upgrade of its libraries until it restarts. The
mapped files are compared by device and inode with the files their paths name, and only for a process in the bridge's
own mount and user namespaces (opus counter-review of step 9a, MINOR-C: a user namespace lets a process bind-mount its
own file over a trusted path; the known callers need those namespaces too since the integrator's review of PR #95, so a
known program run in a sandbox of its own shows as "Unidentified program", save "Disks", decision 9-26 amended); a trusted app that runs code of the user's through its own scripting maps no untrusted
file (`emacs --batch -l`, `nvim -l`, an app's plugin interpreter) and still gets the app's row. The gcr
protocol is unauthenticated: its exchange protects the
password on the bus from passive listeners only (`gcr/gcr-secret-exchange.c`); the requester shown is the D-Bus caller (gnome-keyring or gpg-agent for most prompts,
with the original app named only when the caller's text names it); copies of the password may stay in the shell's heap (SC5);
remembered network passwords are as safe as the keyring that holds them (Omarchy's default keyring is unencrypted; the
sheet says so only for gnome-keyring, whose file format tells, ADR-0035 9-45); a
same-user process can ask the bridge for a cached network password by its URL, as it can ask kpasswdserver today (SC9b),
and can make KIO's worker ask for a server of its own choosing (the row says "KIO" only while the worker runs nothing but
trusted code, and the server is the host the request names, never proof of where anything connects, 9-42, 9-43); step
9e: a kiod6 started while no shell drew the sheet (a shell restart, a KF6 app's SSL check that started kiod6 for its other
names) keeps `org.kde.kpasswdserver6` for the session, and KIO asks in KDE's dialog until kiod6 exits (the journal says
the bridge is queued, 9-36); a kiod6 started while the bridge held the name never takes it, so with no shell KIO's
requests get "nothing" at once until kiod6 exits, never KDE's dialog (9-36); for 1 s after the shell goes, KIO requests
get "nothing" (9-37); gnome-keyring 51.1 itself aborts when a client dismisses an unlock prompt waiting behind another,
and its queue of unlock prompts stalls after a dismissal (the bridge never dismisses one; a store whose prompt stalls
gives its place up after 120 s, 9-50); a KIO request is held until a click, even right after the user's own click on a
network location (9-38); the sheet
has no domain field (a domain the caller sent goes back unchanged) and no anonymous option, and an account with an empty
password cannot be entered (9-47); an entry of the session cache tied to a window id lives for the bridge's life, as in
kiod6 (9-39); KIO's workers other than ftp, a real Files window and a real keyring prompt on screen are not verified; GDBus
marshals copies of a KIO password into the messages it reads and writes and frees them unwiped (9-49); VPN
secrets are not asked (SC8); the shell's sheets (step 9b): copies of a typed password stay in the shell's heap until reused
(the field's text, the JavaScript string handed to the model, the answer's JSON line and the socket's write buffer; none can
be zeroed, SC5, as the polkit sheet's); the shell reads whatever serves `$XDG_RUNTIME_DIR/grassfield/prompter.sock`: a
same-user process can stop the bridge and bind that path (the same-user stance of every Grassfield socket), and Quickshell's
line reader then keeps a line without a line feed from that server in memory until one comes (the 16384 cap is checked per
line, once a line ends); `JSON.parse` keeps the last of two equal
keys (the bridge's Qt writer never repeats one; every value's type is still checked); a wrong password makes gcr's caller
ask again as a new request, which appears after "Password sent", held, and needs a click (macOS shakes the same alert); a
polkit request that waited behind a secret sheet says it arrived "right after another one" at the time it got its turn
(decision 9-15), and a newer polkit request takes the place of a waiting one (Quickshell keeps one); a polkit request that
arrives during the key sink's linger after an earlier one keeps that one's place, so it is shown, held, before a secret request
queued meanwhile (opus review of step 9b, NIT-1); a shared or captured
output is black while a secret or authorization sheet is up (the layer covers the output, decision 9-22); the strength meter
reads the length only (decision 9-17); the nested scenario (A-SC7) and the sheet's look are not verified; step 9c:
"Disks" names `grassfield-askpass`, which any program of the user can run with a disk name and a passphrase destination of
its own (the text under the row is shown as unverified, SC3b); with `LD_PRELOAD`, or its executable remapped to the
helper's in namespaces of its own, such a program chooses the whole text under the row (title, message and description),
not only the disk name (decision 9-26, amended after the integrator's review of PR #96), and a passphrase udiskie refuses is not asked again (udiskie
2.7.0 reports the failure, which `--no-notify` hides; the disk stays locked until it is plugged in again); the helper's
identification inside udiskie's sandbox (`PrivateUsers=self`) relies on the bridge reading `/proc/<pid>/exe` across that
user namespace, checked here with the installed helper in a user and mount namespace that `unshare` makes, not under
systemd's own sandbox; the NetworkManager agent stores no secret: a connection whose secrets
are agent-owned (`psk-flags=1`, as some editors make them) is asked for its password at every connection, and its
`SaveSecrets` is refused so that another agent may store them; system-owned secrets the agent returns are kept by
NetworkManager only when the user has its `settings.modify.system` (or `modify.own`) permission without authentication
(NetworkManager discards them otherwise and the connection fails: NOT VERIFIED on the owner's polkit rules); VPN, wired
802.1X, EAP-TLS (a certificate's password), LEAP and a PIN are not asked (`NoSecrets`); an enterprise network's username
cannot be changed from the sheet (NetworkManager keeps only secrets from an agent's reply: it is changed where the connection
is edited, as on GNOME; a connection without one is not asked); NetworkManager sends the connection's current system-owned
secrets (the old password of a network asked again) inside `GetSecrets`' connection argument to a user with the modify
permission, and that copy stays in GDBus's buffers of the call until it is answered (never read, forwarded or logged by
the bridge); an SSID is shown as the connection
holds it, flattened, so two networks with look-alike names look alike (macOS shows the name too); a WPA2 password of 64
characters that are not hexadecimal is refused by NetworkManager, not by the sheet; NetworkManager stops waiting at 120 s,
so a Wi-Fi sheet left unanswered is withdrawn at 110 s; GDBus marshals a copy of a Wi-Fi secret into the reply it writes and
frees it unwiped (the bridge is not dumpable and has no core file and no swap); a real NetworkManager and the Wi-Fi alert's
look are not verified; until step 2a ships the session's `kwalletrc` (ADR-0035 Q17-b), KWallet's `ksecretd` can hold
the Secret Service for a session when a KWallet client starts before gnome-keyring, and libsecret clients then meet KWallet's
dialogs (inventory S12); a user `kwalletrc` that turns the key back on wins. The handover (SC10, step 2c) moves what
KWallet holds into the keychain, and makes a leftover ksecretd quit; what remains: a Chromium that made a new key before the
handover keeps it, and what it saved under the old key stays unreadable (the handover never overwrites); an app opened
while the handover waits for the answer to KWallet's password question, or an app of Open at Login (started alongside the
shell), can still find nothing in the keychain, and Chromium then makes a new key; a user who refuses the question keeps
their passwords in KWallet only (asked once, ever); a locked wallet that ksecretd has never listed waits, unasked, until a
KWallet client opens it; KWallet's question is KDE's dialog (K2); the values cross the user's own session bus in plain
Secret Service sessions (ADR-0035 decision 2c-4).

## 6. Toolkit appearance (category C; ADR-0035 D-8)

### macOS reference behavior
Every app follows the system appearance (Light, Dark, Auto) and the accent colour live; Increase Contrast and Reduce Motion
apply to every app.

### Functional requirements
- AP1 `grassfield-portal-settings` (no window, QtCore + QtDBus, started with the session) serves
  `org.freedesktop.impl.portal.Settings` (`Read`, `ReadAll` with the namespace filter, the `SettingChanged` signal, property
  `version` 1; the frontend's `ReadOne` is its `Read`) for `org.freedesktop.appearance` (`color-scheme` u: 1 dark, 2 light;
  `accent-color` (ddd) sRGB, the accent of the current appearance; `contrast` u: 1 when Increase Contrast; `reduced-motion`
  u: 1 when Reduce Motion) and `org.gnome.desktop.interface` (`gtk-theme`, `color-scheme` `prefer-dark`/`prefer-light`,
  `enable-animations`), from the Grassfield settings file, watched (its nearest existing parent while its directory does not
  exist yet) and read as ADR-0020 §2 requires: never without a bound (a FIFO, a device or a directory is never read, at most
  1 MiB, read whole), on a worker thread, one read at a time: a read that hangs is not waited for (ADR-0020's 5 s cut, logged
  once), the calls are answered at once with the last settings all along, and the start waits 3 s at most for the first read;
  a malformed or unreadable file keeps the last good settings (defaults only at start); a missing file means the schema's
  defaults. `auto` follows `AutoAppearance`'s schedule: the clock is checked again every minute as the shell does, the file
  never (ADR-0035 decision 2b-8). A key it does not own answers `org.freedesktop.portal.Error.NotFound` (the frontend then
  asks x-d-p-gtk). Only the keys whose value changed are signalled; once its bus name is owned it signals every value once
  (decision 2b-9); it answers x-d-p-gtk's `SettingChanged` (by its bus name) for a key it owns and a value other than its own
  with its own value (decision 2b-13). A dev run refuses any bus but a private test bus. Budget: ≤ 4 MB private and ≤ 20 MB
  resident memory, no CPU while nothing changes but a clock check a minute under `auto` (decision 2b-11).
- AP1b its unit has `Restart=on-failure` (`RestartSec=1`; counter-review of PR #13): a crashed backend is back within about a
  second, so live changes resume without waiting for a read. The frontend's proxy is bound to the bus name, not to the process,
  and follows its new owner (xdg-desktop-portal 1.22.1 `src/settings.c:333-339`, `G_DBUS_PROXY_FLAGS_NONE`; GLib 2.90.1
  `gio/gdbusproxy.c:1704-1734`: signals subscribed by name, `NameOwnerChanged` tracked).
- AP2 the session's `hyprland-portals.conf` (under `/usr/share/grassfield/xdg/xdg-desktop-portal/`) lists only
  `org.freedesktop.impl.portal.Settings=grassfield-settings;gtk` (`grassfield-settings.portal`, bus name
  `org.freedesktop.impl.portal.desktop.grassfield_settings`); every other interface keeps the stock file's routing.
- AP2b the backend's unit clears `GTK_USE_PORTAL` and `QT_QPA_PLATFORMTHEME`, and `grassfield-shell.service` clears
  `GTK_USE_PORTAL`, so neither waits on the portal at start (ADR-0035 D-4); the shell gives `GTK_USE_PORTAL=1` back to every
  app it starts when `env-grassfield` recorded `GRASSFIELD_APPS_GTK_USE_PORTAL=1` (`Mode.appsGtkPortal`, decision 2b-12).
  `autostart.lua` starts the backend without waiting for it, and its unit gives a start 5 s; the frontend's unit wants the
  backend and starts after it (packaged drop-in, decision 2b-14), since the frontend makes its backend proxies once, when it
  starts.
- AP3 `env-grassfield`, when the routing file is readable: `/usr/share/grassfield/xdg` first in `XDG_DATA_DIRS` (once, the
  list or its default kept), `GTK_USE_PORTAL=1`, and `portals` added once to `GDK_DEBUG` (plain GTK 4 apps outside a sandbox
  read the portal only with it; decision 2b-1); never `GTK_THEME`.
- AP4 (owner decision Q7, decision 2b-2) `/usr/share/themes/Grassfield-<accent>[-hc][-dark]/` with `gtk-3.0/gtk.css` and
  `gtk-4.0/gtk.css` (36 themes: nine accents, two appearances, Increase Contrast), generated at build time from
  `ui/tokens/tokens.json`, each `@import`ing GTK's built-in stylesheet (GTK 3: Adwaita, or HighContrast with `-hc`; GTK 4:
  Default, or Default-hc) and setting only Grassfield's colours where that stylesheet draws its accent, with the shell's
  colour roles (decision 2b-5): the GTK 4 focus ring opaque (`control.focusOutlineOpacity`, decision 2b-15), hover, pressed
  and border shades as the shell's overlays, the selected tab's indicator at GTK's own width (`gtk.tabIndicatorWidth`); no
  CSS colour function; the radii stay GTK's (decision 2b-7). MIT, no copy of Adwaita. `gtk-theme` names the matching one.
  Every theme but `-hc` also lays the warm grounds of ADR-0040 (window `groupFill`, views, lists, menus and popovers
  `windowBackground`, header bars `titlebar.background*`, text `text`; `tests/ci/gtk_themes.py` checks them and 7:1 for the
  text); libadwaita apps keep their own.
- AP5 a change of appearance, accent, contrast or motion in Settings or Quick Settings reaches running GTK 3 (with the
  variable), GTK 4 (with `GDK_DEBUG=portals`), libadwaita, Qt (`gtk3` theme), Chromium, Electron and Firefox within 1 s.

### Acceptance criteria
- A-AP1 (L0) the real xdg-desktop-portal 1.22.1 on a private bus, the session's routing directory first in its
  `XDG_DATA_DIRS` (a copy of the package's), the Grassfield backend D-Bus-activated and a stand-in for x-d-p-gtk: `ReadAll`
  returns Grassfield's values first and the stand-in's for the rest (`font-name`); the namespace filter holds; every other
  interface keeps the stock routing; a settings-file change reaches a client as `SettingChanged`, for the changed keys only;
  after the stand-in signals a dconf change of `gtk-theme` and `color-scheme`, the client ends with Grassfield's values
  (`tests/integration/portal_settings.sh` 1, 2). (L0, unit) a FIFO, a device symlink, a directory, a file over 1 MiB and an
  unreadable file are never read, and they and a malformed file keep the last good settings.
- A-AP2 (L0) on a headless Weston with the session's variables: a GTK 3 app, a GTK 4 app and a libadwaita app take the
  Grassfield theme, colour scheme, contrast and accent from the portal and follow a change within 1 s; a GTK 4 app without
  `GDK_DEBUG=portals` does not (control) (scenario 7). (L1, the integrator) a nested Grassfield session: the same apps and a
  Qt `gtk3` one switch with Settings (screenshots).
- A-AP3 (L0) the themes' colour pairs (WCAG 2.x) for the nine accents in both appearances: selected and highlighted text
  4.5:1, links 4.5:1 and the focus ring 3:1 against the Grassfield window and GTK's own window and view backgrounds, thin
  marks 3:1 except the light yellow accent's (1.86:1 on GTK's window, 1.99:1 under high contrast; the shell's own yellow,
  pinned) (`tests/ci/gtk_themes.py`); the 36 themes rendered with GTK 3 and GTK 4 leave none of GTK's blue and
  show their own colours, against GTK's four stylesheets as controls (`tests/integration/gtk_themes.sh`).
- A-AP4 (L0) crash: the backend killed, the next read through the real frontend activates it again and returns Grassfield's
  values, and the new process signals the next change; with a frontend that never answers, the backend still starts (no GUI,
  no wait) (scenarios 3, 5); a backend whose activation fails when the frontend starts is left out by that frontend for good
  (scenario 4b), so the frontend's unit starts after the backend (static check of the drop-in).
- A-AP5 (L0) crash without a read: the backend killed, the settings file changed while it is down, then the backend started
  with no read (as systemd's `Restart=on-failure` starts it): the change reaches the client (scenario 3); after a restart
  the apps keep their state (scenario 7). systemd's restart itself is not run in the container (no user manager): the unit's
  lines are checked statically; (L2) on the reference machine, `systemctl --user kill -s KILL grassfield-portal-settings`
  then a change in Settings.

### Degraded behavior
Backend absent or crashed: x-d-p-gtk's values (the user's dconf, Omarchy's theme) until systemd restarts it (about 1 s) or
D-Bus activation starts it at the next read; a change made meanwhile is delivered when it starts. A backend that keeps
failing stops after 5 starts in a minute, and the frontend answers from x-d-p-gtk until a later read or the next login. GTK
theme missing: GTK falls back to its default theme. Routing file unreadable: `env-grassfield` sets nothing, and the session
behaves as before step 2b. A `hyprland-portals.conf` of the administrator's (`/etc/xdg-desktop-portal`) wins over the
session's: the apps then take x-d-p-gtk's values. The user's (`~/.config/xdg-desktop-portal`) does not, in the Grassfield
session: the frontend reads one configuration per directory (for each item of `XDG_CURRENT_DESKTOP` in order,
`<item>-portals.conf`, else `portals.conf`), the user's directory first. Omarchy 4.5.0's migration 1788261467 writes
`~/.config/xdg-desktop-portal/hyprland-portals.conf` (`default=hyprland;gtk`, `Secret=gnome-keyring`) on every machine it
updates, and no system-wide file of ours can come before it. So the session's `XDG_CURRENT_DESKTOP` is `Grassfield:Hyprland`
(`config/hypr/session.lua`) and the frontend's unit runs `grassfield-portal-config`, which links the user's
`grassfield-portals.conf` to the session's routing (only a link of ours; a file of the user's, and Omarchy's file, are left
alone); the session's file carries Omarchy's `Secret` line. The frontend's environment, so that of the applications it
launches, is not changed. The Omarchy session is unchanged (tests/integration/portal_settings.sh, scenario 4c, with its controls).

### Known limitations
x-d-p-gtk's own remaining dialogs (its file chooser until step 4, print until step 6, account) and apps that read dconf
directly follow the user's GTK theme, not the Grassfield appearance; GTK 3 and GTK 4 apps that open a file or link through
the portal may meet x-d-p-gtk's app chooser where the portal asks (step 5 replaces it); libadwaita snaps the accent to its
nine accents; Qt reads no accent (its highlight comes from the GTK 3 theme); the text highlight setting (`accent.highlight`)
does not reach GTK apps, whose selected text uses the accent (decision 2b-6); the light yellow accent's thin marks hold
1.86:1 on GTK's window, as the shell's yellow does on its own; after x-d-p-gtk signals a dconf change, apps see its value for
an instant before Grassfield's (decision 2b-13); GTK and libadwaita apps keep GTK's own radii; an app started with its own
`GTK_THEME` keeps it; on the owner's GTK 4.22 plain GTK 4 apps do not read `accent-color` (the Grassfield theme carries the
accent). Code quality: `just check-tidy` covers the compositor only; a one-off clang-tidy run with its checks over the
backend left only Qt's idiom.

## 7. Print sheet (Print portal; P11; ADR-0035 D-7, owner decision Q6)

### macOS reference behavior
The print sheet attaches to the document's window: a preview of the pages on the left (page arrows under it), on the right
Printer, Presets, Copies, Pages (All, From–to, Selection), then Paper Size, Orientation, Scale, Two-Sided and the printer's
options in collapsible sections; at the bottom "PDF" (a menu: Save as PDF…, Open in Preview) and Cancel / Print (default).
The last printer used is shown first; Last Used Settings, a preset of the Presets menu shared by every application, brings the
last print's settings back (ADR-0035 6-18).

### Functional requirements
- PR1 `PreparePrint`: the sheet without preview (the document is not sent yet), every option the destination reports through
  CUPS (`cupsCopyDestInfo`), defaults from the destination; returns GTK's `settings` and `page-setup` keys and a token valid
  for the matching `Print` call.
- PR2 `Print` with a valid token: submits the document fd to the chosen CUPS destination with the chosen options, no UI; without
  a token: the full sheet with the preview of the document (Qt PDF for PDF, the first page of PostScript as an image when it can
  be rendered, else "No preview"; step 6b sends a document that is not a PDF to x-d-p-gtk instead, ADR-0035 6-12).
- PR3 "Save as PDF…" opens the D-4 save panel and writes the document there (PDF input) instead of printing.
- PR4 no printer: the sheet says "No printers available" with "Add Printer…" (opens Settings > Printers).
- PR5 never blocks: CUPS calls run off the UI thread with deadlines (a dead network printer never freezes the sheet); the UI
  falls back to forwarding the call to x-d-p-gtk as D-4.

### Acceptance criteria
- A-PR1 (L0) a fake CUPS (a scratch `cupsd` with a file-backed queue, or a mocked libcups seam) gets the job with the chosen
  options; option mapping tested in both directions with GTK's key names.
- A-PR2 (L1) evince with `GTK_USE_PORTAL=1` in a nested session prints a test page to a file-backed queue through the
  Grassfield sheet (screenshot).
- A-PR3 F1 against the reference print sheet captures (both appearances).

### Built in step 6a (ADR-0035 6-1 to 6-9)
- PR1 done without Presets and the printer's own options (6b): Printer (the application's last printer, else the default; Add
  Printer… last), Copies (up to what the printer takes), Pages (All Pages; Current Page and Selection when the application has
  them; a range typed "1-3, 5", Print dimmed until it reads), Paper Size (the printer's, its default first shown, 6-8),
  Orientation, Scale, and Two-Sided (Off, Long-Edge Binding, Short-Edge Binding) and Colour (Colour, Black & White) when the
  printer has them; another printer chosen dims Print until its options are read. The answer: GTK's settings (strings, with
  one copy: GTK 3 would render the copies itself) and page setup (doubles, no PPD name), and a token good once, for its
  application, for five minutes, that keeps the backend running while it lives (6-4, 6-5).
- PR2 with a token done: the job, named after the application, carries the copies, collation, paper, two sides and colour,
  never the pages, scale or orientation GTK already applied (6-4); only a PDF, sent as one, at most 2 GiB; a job the printer
  refuses is response 2. Without a token: x-d-p-gtk's dialog (6b).
- PR3 done: Save as PDF… (a button, 6-3) opens D-4's Save panel through FileChooser with the application's name for the file;
  Cancel there brings the sheet back, under the application's id. Only a PDF, at most 2 GiB, is written, only in the folder the
  Save panel's answer named (resolved then), never through a link: the folder opened with `O_NOFOLLOW` all the way from "/", a
  temporary file made there with `O_EXCL | O_NOFOLLOW`, synced and renamed over the name (a link at the name is replaced; a file
  that may not be written stays) (6-3). The application never gets the path (its `output-uri` is `file:///dev/null`).
- PR4 done: "No Printers Available" (or "Printers Not Responding"), Add Printer… opens Settings > Printers, Print dimmed, Save
  as PDF kept.
- PR5 done: CUPS's calls run on threads of their own with deadlines (listing 3 s and its own 2, a printer's options 8 s and 2,
  a job's connection 10 s and 30 s without progress, from its first request) and libcups' cancel flag; a sheet that cannot show sends the call to
  x-d-p-gtk (RequestHost).
- A-PR1: `tests/unit/portal/tst_printlogic.cpp` (both directions with GTK's names and types; the CUPS options; what reaches
  CUPS: PWG paper names, the document's type, the job's name), `tests/unit/portal/tst_print.cpp` (the D-Bus interface with
  fakes: tokens, Save as PDF through the Save panel and never through a link, no printer, another printer, the forward; the
  writer: links at the name and in the folder's path, a failed last step, the size limit, permissions kept),
  `tests/integration/print_cups.sh` (libcups against a scratch cupsd: printers, options, a job with its options kept on it, a
  printer language refused before any job). A-PR2 without the nested session: `portal_filechooser.sh` scenario 9 (the real frontend, the sheet's test answer, the
  job in the scratch scheduler with its copies); evince in a nested session is the integrator's. A-PR3: the integrator's.
- `tests/unit/tst_printsheet.qml`: the sheet's states, keys, Save as PDF and the late-keyboard hold.

### Built in step 6b (ADR-0035 6-10 to 6-30)
- PR2 without a token done: Print with no sheet before it (libportal's callers) opens the sheet with the document's preview on
  the left, one page at a time with "‹ 1 of N ›" and Page Up / Page Down (6-14); Orientation and Scale are not offered (the
  document is laid out), Pages is All Pages or a range, which the printer applies (`page-ranges`), and the paper of the
  document's first page is chosen where the printer has it (6-13). The document is kept in an unlinked private file on disk
  (the user's cache folder), within one 2 GiB budget for every document waiting (6-11, 6-21), and its pages are drawn by a
  confined child of grassfield-portal (Qt PDF; Landlock: reading under /usr only; a measured seccomp allow-list: no socket,
  program, process, lock, ioctl, nor any act on another process; setsid, the locale's variables only, 512 MiB, one child at a
  time, one thread when it confines itself; an unlisted call answers ENOSYS; raw pixels read back; no preview when the
  confinement cannot be installed) (6-10, 6-20, 6-25 to 6-27). The sheet may print as soon as the document is kept, its preview
  coming apart, and the document's own paper chosen with the first printer's options, or suggested when its size comes after
  them (6-13, 6-28). Print sends the job at once from that file and the sheet goes (6-15); a document that is not a PDF goes to
  x-d-p-gtk as it came, or fails when it came on a pipe, as does one whose sheet does not show in time once part of a pipe was
  read (6-12, 6-24); one the full budget refuses goes to x-d-p-gtk as it came when it is a file (6-28).
- PR3 done with macOS's "PDF" pull-down (6-16): Save as PDF… (6-3's Save panel and writer) and Open in Preview: a private copy
  in `$XDG_CACHE_HOME/grassfield/preview` (a name within 255 bytes; the copies older than a day, or beyond 16, removed), written
  as Save as PDF writes, opened in Preview started as the Dock starts an application (`systemd-run --expand-environment=no`)
  (6-17, 6-22). In both flows.
- PR1 done with the Presets (6-18): Default Settings and Last Used Settings (one for every printer, kept in grassfield-portal's
  state when Print sends a job: two sides, colour, collation and the printer's own options, never the copies, pages, paper,
  orientation or scale), the sheet opening on Last Used Settings when there are some; and with a printer's own options (6-19):
  Feed From, Media Type and Quality in "Media & Quality", Output Bin and Finishing in "Printer Options", disclosure sections
  closed at first, only what the printer reports with two values or more, its defaults first (the user's lpoptions, else the
  queue's), each value sent as CUPS takes it, only one the printer listed and only when the queue would not apply it by itself
  (the user's lpoptions value goes; 6-23); the standard finishings named in the UI language.
- A-PR1 extended: `tst_printlogic.cpp` (options, page ranges, Open in Preview, presets and their JSON, file names within 255
  bytes), `tst_print.cpp` (the confinement against the security review's probes, the child's environment and session, the
  private file and its budget, the pages drawn by the child, a document sent first through the D-Bus interface, one that is not
  a PDF, one on a pipe never sent on truncated, Open in Preview and its copies' bounds, Last Used Settings, a printer's
  options), `print_cups.sh` (the scratch scheduler reports the queue's
  own options with their names and defaults, and keeps them on the job), `tst_printsheet.qml` (the Presets, the sections, the
  PDF pull-down, the preview and its pages). A-PR2 without the nested session: `portal_filechooser.sh` scenario 9b (Print with
  no token through the real frontend: the sheet, the backend's child counting the pages, the job in the scratch scheduler with
  the document as sent). Evince or a libportal application in a nested session, and A-PR3, are the integrator's.

### Known limitations
Only portal clients get it (Chromium's and Firefox's own previews, LibreOffice, Electron and Qt apps keep their dialogs); no
preview when the app asks for settings before it renders (the portal sends the document later); printer setup stays in
Settings. Step 6b: no named presets (Save Current Settings as Preset…), no Layout (pages per sheet) or Paper Handling (page
order, odd or even pages) sections, and a PPD's vendor options with no IPP name are not shown (the printer's defaults apply);
a document sent first that is not a PDF gets x-d-p-gtk's dialog; the preview needs Landlock (a kernel from 5.13 with Landlock
enabled, as Arch's is) and x86_64 or aarch64 (the allow-list is measured on x86_64 only), else it says "No Preview" and the
document still prints; the child can still learn a path's metadata (whether a file exists, its size, times and mode; never its
contents: Landlock does not cover stat); Open in Preview's copies stay in the user's cache folder for up to a day (16 at most), where an
application allowed to read that folder can read them; a finishing that is neither standard nor named by CUPS is shown as its
keyword in English words. When the sheet cannot show and PreparePrint goes to x-d-p-gtk,
a GTK 3 application asking for n copies gets n × n (GTK renders the n copies its answer names and x-d-p-gtk's job asks for n
again): upstream's behaviour, relayed unchanged (ADR-0035 6-4). Save as PDF goes to the folder the Save panel's answer named as
it resolves a moment later: an application that can write in the folder above can swap the chosen folder for a link in that
moment (6-3). A raw print queue passes a document's bytes to the device as they are (6-4).

## 8. Bluetooth pairing (BlueZ Agent1; inventory O7; ADR-0035 D-11, owner decision Q9; built in step 10, decisions 10-1 to 10-16)
A security module (the secret sheets fed by grassfield-prompter, "BlueZ pairing" in the amended rule, owner decision Q12): R12
applies (opus PASS, fail closed, nothing logged). From step 10 a pairing step that needs the user (a code to type, show or
compare, an incoming pairing or service) is drawn by the shell's secret sheet, in the one queue (section 5, SC2).

### macOS reference behavior
Pairing a keyboard shows "Connection Request from “Name”" with the code to type on the device or to compare, Cancel / Connect;
a device that asks for a PIN gets a PIN field; an incoming request from an unknown device asks before anything connects;
nothing is accepted silently.

### Functional requirements (as built in step 10)
- BT1 (decisions 10-1, 10-2) the bridge (`bridges/prompter/src/BtAgent.{h,cpp}`, `BtPairing.{h,cpp}`) registers
  `org.bluez.Agent1` at `/org/grassfield/prompter/BluetoothAgent` as a `KeyboardDisplay` agent and asks to be the default
  (`RegisterAgent`, `RequestDefaultAgent`) while a shell whose hello lists `bluetooth` is connected, unregisters when it goes,
  registers again when `org.bluez` gets a new owner; the system bus as in SC8 (the fixed socket in the session). Omarchy's
  `bt-agent` does not run in the Grassfield session: `packaging/systemd/bt-agent.service.d/10-grassfield.conf`
  (`ConditionEnvironment=!GRASSFIELD_SESSION=1`, and `PartOf=graphical-session.target` so that one an Omarchy session started
  stops with it even when the user manager stays), installed to `/usr/lib/systemd/user/bt-agent.service.d/`, and
  `grassfield-prompter.service` stops one still running before it starts (opus review of step 10, MAJOR). BlueZ's check
  (10-1): with no agent at all (the shell not connected) bluetoothd makes the adapter non-bondable and refuses every step that
  needs an agent; nothing is accepted silently, so `bt-agent` is not kept as a fallback (it would accept incoming pairings
  without asking exactly then).
- BT2 (10-4 to 10-7, 10-10, 10-11) each Agent1 method is one form of the secret sheet, macOS's connection request: the device's
  glyph, "Connection Request from “Name”", "Bluetooth device <address>", then Grassfield's sentence:
  - `RequestPinCode`: "Enter the device's PIN code.", a PIN field (1 to 16 letters and digits), Cancel / Connect;
  - `RequestPasskey`: "Enter the code shown on the device.", a code field (6 digits), Cancel / Connect;
  - `DisplayPinCode`, `DisplayPasskey`: "Type this code on the device, then press Return on it.", the code large, for a
    passkey "Digits typed on the device: N of 6" updated on each `DisplayPasskey` of the same code without touching the
    keyboard (10-8); Cancel alone, which asks bluetoothd to `CancelPairing` the device; bluetoothd gets its reply at once
    (it hands a PIN to the controller only then) and the sheet goes when bluetoothd leaves, when the device is reported
    paired, disconnects or is removed, when another code is shown (one at a time), or after 55 s (10-6, 10-16);
  - `RequestConfirmation`: "Connect only if the device shows the same code.", the passkey as 6 digits, Cancel / Connect;
  - `RequestAuthorization`: "The device wants to pair with this computer.", Decline / Connect;
  - `AuthorizeService`: "The device wants to use <profile> on this computer." (audio streaming, media remote control, headset
    audio, hands-free calling, file transfer, sending files, network sharing, keyboard or mouse input, phonebook access,
    message access, a serial port, dial-up networking; otherwise "a Bluetooth service" with its UUID), Decline / Connect.
  Every pairing step is held until a click past the guard (10-7): no key answers an authorization or a comparison, nothing
  typed elsewhere reaches a code field. bluetoothd gets the code or an empty reply on Connect, `org.bluez.Error.Canceled` on
  the user's Cancel of a code or a comparison, `org.bluez.Error.Rejected` on Decline and on every other end (the shell gone or
  refusing, a wrong answer, the bound of 8, bluetoothd's departure, no answer within 55 s, under bluetoothd's own 60 s);
  `Cancel` from bluetoothd withdraws its call still waiting for a reply (shown or queued), never a code shown (10-4);
  `Release` (bluetoothd stopping) is answered. A code sent lingers as "Code
  sent" (10-13).
- BT3 (10-9) the device is named by its `Alias` from `org.bluez.Device1` (else its `Name`, else its address), read
  asynchronously from the same owner of `org.bluez` (2 s at most), plain text flattened and capped at 64 UTF-16 code units,
  shown only as a quoted field of Grassfield's sentence; its address (the object path's) is shown under the title so
  look-alike names can be told apart; its `Icon` only as one of a fixed list of glyphs, else the Bluetooth glyph.
- BT4 (10-3) the agent accepts calls only from the current owner of `org.bluez` on the system bus, asked when each call
  arrives; other callers get `org.bluez.Error.Rejected` and no sheet; a stranger's `Cancel` cancels nothing. Every argument is
  checked before anything is shown (a device path of bluetoothd's form, a passkey of at most 999999, a PIN to show of 1 to 16
  letters and digits, a canonical UUID): anything else is Rejected without a sheet. Its sheets go through the same queue and
  bound of 8 as the other secret sheets (section 5, SC2).
- BT5 (10-12) Settings' Bluetooth pane (PR #8) owns discovery and the adapter's state and is unchanged: its `Pair()`, made
  without an agent of its own, asks the default agent, the bridge, so a pairing that needs a code or a comparison shows the
  sheet; a device that needs neither pairs without one.

### Acceptance criteria
- A-BT1 (L0) a fake BlueZ on a private system-style bus drives every method; mutants removing the "no automatic yes" rule or
  the caller check fail. Step 10: `tests/security/bluez_agent.sh` (a fake bluetoothd, `tests/fixtures/fake-bluez.py`, serving
  AgentManager1 and Device1 objects as BlueZ 5.87 does; a fake shell; an attacker; Settings' Pair() through `dbus-send`; the
  shared bound with libgcr's client; a bridge with a short answer time; `--mutants`), `tests/unit/prompter/tst_prompter.cpp`
  (the argument checks, the device's name, the passkey's form, the prompt and progress lines; plain and ASan/UBSan),
  `tests/security/tst_prompter.qml` and `tst_secretsheetmodel.qml` (the kind read strictly, the answers, the sheet's words and
  rules), `tests/security/secret_sheets.sh` (the real agent and sheet: held, no key answers, Decline, the code rules, a code
  shown with Cancel alone following its progress without touching the keyboard; mutants), `tests/security/secret_bridge.sh`
  (the shell's real client against a fake bridge and, end to end, the real bridge with the fake bluetoothd).
- A-BT2 (L2, owner) pairing a keyboard that needs a passkey and a phone that compares a code; opus PASS before merge.
- A-BT3 (L1) nested scenario for step 10 (owner approval: `just nested-up`, `just shot`): as for step 9c (section 5, A-SC7), a
  second private dbus-daemon as the "system" bus (the session bus's test configuration with `<type>system</type>` and its own
  socket under `/tmp`, as `tests/security/bluez_agent.sh` writes it) and the fake bluetoothd on it (`env
  DBUS_SYSTEM_BUS_ADDRESS=<that bus> GF_TEST_BUS_DIR=/tmp python3 -I tests/fixtures/fake-bluez.py --log /tmp/bz.log --commands
  /tmp/bz.cmd`), the bridge started with the same `DBUS_SYSTEM_BUS_ADDRESS`, the dev shell restarted on its socket; once
  `/tmp/bz.log` says `#default`, `echo 'device AA_BB_CC_DD_EE_01 alias=Desk-Keyboard icon=input-keyboard' >/tmp/bz.cmd`, then
  `echo 'confirm c1 AA_BB_CC_DD_EE_01 42' >/tmp/bz.cmd`: `just shot pairing-confirm` (the keyboard glyph, "Connection Request
  from “Desk-Keyboard”", the address, 000042, held), click past the guard, Connect (`/tmp/bz.log` gets `c1 ok`); `echo
  'passkey c2 AA_BB_CC_DD_EE_01' >/tmp/bz.cmd`: `just shot pairing-passkey`, type six digits, Return (`c2 ok <number>`); `echo
  'display-passkey AA_BB_CC_DD_EE_01 123456 0' >/tmp/bz.cmd` then the same line with 1, 2 and 3 typed: `just shot
  pairing-display` (Cancel alone, "Digits typed on the device: 3 of 6"; the keyboard stays where it was), `echo 'paired
  AA_BB_CC_DD_EE_01' >/tmp/bz.cmd` (the sheet goes); `echo 'service c3 AA_BB_CC_DD_EE_01
  0000110b-0000-1000-8000-00805f9b34fb' >/tmp/bz.cmd`: `just shot pairing-service` (Decline / Connect, "audio streaming").
  Visual NOT verified in step 10; a real bluetoothd with a real keyboard and a real phone are the owner's L2 checks (A-BT2).

### Known limitations
Agent precedence with another agent that also asks to be the default is BlueZ's (the last one to ask wins,
`src/agent.c:139-154`): a program of the user that registers its own agent and asks to be the default (`bluetoothctl`'s
`default-agent`) takes the pairings until the bridge registers again (the shell's next connection, or bluetoothd's restart);
an application with an agent of its own gets its own pairings (BlueZ's design). Legacy devices with fixed PINs need the user
to know the PIN. While the shell is not connected bluetoothd has no agent in the Grassfield session: a pairing started then
from Settings works only for a device without keys or a screen and is not kept as a bond, and an incoming one is refused
(10-1); with `AlwaysPairable = true` in `/etc/bluetooth/main.conf` (not BlueZ's default; Omarchy 4.0.4 does not set it; on
the owner's machine UNVERIFIED) the adapter stays bondable without an agent, with the NoInputNoOutput capability, and the
kernel itself would then accept an incoming Just Works pairing while the shell is not connected (`hci_event.c:5393-5394`):
`grassfield-login-check` (after every install and upgrade) warns then, and Grassfield never changes the file (10-15).
Omarchy's `bt-agent.service` does not stop with its session by itself (no `PartOf=`): Grassfield's drop-in adds it, and the
bridge's unit stops a bt-agent still running before it starts (10-1 amended; checked under a systemd 262 user manager in a
container, not on the owner's machine). bluetoothd hands the PIN of `DisplayPinCode` to the controller whatever the
agent answers (`src/device.c:7609-7618`): the sheet cannot refuse such a pairing, only not show the code (the device then
times out). The user's Cancel of a code shown stops a pairing Settings started (`CancelPairing`); one the device started ends
at its own time limit. One code is shown at a time: a newer one (another device) withdraws it (10-16). A device in range
names itself (look-alike names: the address under the title tells them apart); a
service bluetoothd does not name is shown by its UUID. A code sheet left open is withdrawn after 55 s (bluetoothd stops
waiting at 60 s). GDBus marshals a copy of a PIN into the reply it writes and frees it unwiped (10-14). Real devices, the
nested scenario and the sheets' look are not verified (A-BT2, A-BT3).

## 9. KIO's dialogs in Files and the panel (inventory K3–K7, K9; ADR-0035 D-12 a, owner decision Q11; built in step 4a for Files)

### macOS reference behavior
Finder's own alerts: "An item named “X” already exists in this location. Do you want to replace it with the one you're
moving?" ("An older item named…" or "A newer item named…" when the dates tell) with Keep Both / Stop / Replace, Skip and
"Apply to All" for several items; "The operation can't be completed because you don't have permission…" with Skip / Stop;
the certificate sheet ("… can't verify the identity of the server “X”", Show Certificate, Cancel / Continue); Open With >
Other… opens the Choose Application panel. No progress window opens for Undo.

### Functional requirements
- KD1 Files (and, from step 4b, `grassfield-portal`) sets Grassfield's UI delegate, KIO's own `KIO::JobUiDelegate` class with
  Grassfield's KIO delegate extensions as its children, on every job it starts, and makes it KIO's default delegate factory
  while it runs (ADR-0035 4a-2: KIO gives its own sub-jobs and Undo's jobs a default delegate of their own, which
  `KIO::delegateExtension` reads before the parent's, `src/core/jobuidelegatefactory.h:102-126`; KIO's factory comes back when
  Files' prompts go):
  - `AskUserActionInterface`: rename/overwrite (Keep Both / Skip at the leading edge, Stop / Replace at the trailing edge,
    "Merge" for a folder onto a folder, Apply to All for several items; Keep Both names the new item as KIO does,
    `KFileUtils::suggestName`; Resume / Start Over / Stop for a copy that stopped part way), skip (Try Again, or Rename for characters the destination refuses, Stop, and for several
    items Skip and Apply to All; one item that can't be retried: OK), the permanent deletions KIO asks about (a plain move to the Trash is not asked), `requestUserMessageBox` as a sheet
    with the worker's buttons (Show Details for its details), `askIgnoreSslErrors` as the certificate sheet (Show Certificate
    lists the chain as text: subject, issuer, validity, SHA-256, the problems found): Cancel is the default button (Return
    and Esc cancel); Continue accepts for 30 minutes, KIO's "Current Session only"; a permanent rule ("Forever") only when
    the user ticks "Always trust “host”", shown with the certificate and unticked at every opening (ADR-0035 4a-6);
  - `OpenWithHandlerInterface`: Finder's alert for a type with no application, then the Choose Application panel (section 2,
    OW3; 4a-5, 5c-3);
  - `UntrustedProgramHandlerInterface`: refuses with a notice (Files' `LaunchGuard` decides first and never hands an
    executable to KIO, `docs/specs/security.md` § Files never runs what it opens; this is the second guard).
    `OpenOrExecuteFileInterface` has no installed header in KIO 6.31: Files never enables the job option that asks it (4a-4).
- KD2 every answer is the KIO answer the widget dialog gives for the same choice (`RenameDialog_Result`, `SkipDialog_Result`,
  `KIO::WorkerBase::ButtonCode`), so jobs behave exactly as before.
- KD3 the sheets show in the Files window the user last worked in when the question came, one at a time, and stay there
  until answered (in another window if that one closes); a question waits while another sheet or a menu of that window is
  open (Go to Folder, a confirmation, a context or toolbar menu) and keeps its choices; while shown it keeps the keyboard;
  a question whose job ends goes away unanswered; keyboard as common rule 3 (4a-9).
- KD4 errors and warnings KIO shows by itself (where KIO turns its automatic handling on) are notice sheets; Undo reports its
  errors on the window's error line, keeps a copy changed since it was made and says so (4a-11); no job of Files opens
  KIO's progress window (4a-12).
- KD5 Paste is offered for items only: text or an image on the clipboard is not pasted (4a-14).
- KD6 Return never takes a warning's action or a deletion (Cancel, or the secondary action where there is no Cancel,
  4a-17); in the copy/move conflict sheet Return replaces (Merge onto a folder, Resume for a copy that stopped part way),
  as the Finder (owner decision Q18, the exception to common rule 3); a question takes no input for the double-click interval after it shows, a key's auto-repeat answers nothing,
  and a question opens with the keyboard on the sheet,
  not on a button clicked before (4a-18); a long text scrolls inside the sheet, the buttons stay on screen (4a-19); names
  inside KIO's texts show their direction controls (4a-20).

### Acceptance criteria
- A-KD1 (L0) every choice of the conflict, skip and message sheets gives the KIO answer the widget dialog gives
  (`tests/unit/files/tst_kioprompts.cpp`, table test); real KIO copy and move jobs through KIO's file worker in a scratch home,
  answered as the sheets answer, do what that answer says (Replace, Keep Both, Stop, Skip with Apply to All asked once, a
  folder copied and a folder moved onto a folder merged, a file onto a folder never "Merge", a sheet's reply, a withdrawn
  question; `tests/unit/files/tst_kiodialogs.cpp`); the sheets' texts, buttons and replies (`tests/unit/tst_fileskiosheets.qml`);
  the window that shows a question, a question that waits for Go to Folder and for a menu, a sheet that takes the
  keyboard back, and the safe answer with no window (`tests/unit/tst_filesbrowser.qml`).
- A-KD5 (L0) Return on a warning and on a deletion cancels (or gives the secondary action); a double click and a repeated
  Return answer one question only; Return is the default button's after a Tab in the last question; a 200-line message
  keeps the buttons inside the window; direction controls in KIO's texts show as <U+XXXX> (`tst_fileskiosheets.qml`,
  `tst_kioprompts.cpp`).
- A-KD2 (L0) no widget is created by those jobs, KIO's own jobs resolve Grassfield's extensions, an error KIO reports itself
  is a notice, Undo of a changed copy keeps it, a job KIO tracks makes no progress window, only items are pastable, and
  Files' sources hold no KIO or Qt widget dialog, set no other delegate, never use KIO's paste test and never enable "open
  or execute" (`tst_kiodialogs.cpp`).
- A-KD4 (L0) certificate: Return and Esc cancel; Continue answers KIO's follow-up with "Current Session only" (30 minutes),
  and with "Forever" only when "Always trust" was ticked, also when the follow-up comes late; never after Cancel or after
  another question (`tst_kioprompts.cpp`, `tst_kiodialogs.cpp`, `tst_fileskiosheets.qml`).
- A-KD3 F1 against Finder's conflict alert and certificate sheet captures.

### Known limitations
- KF6 apps other than Files keep KIO's own dialogs (inventory K8, themed by D-8); network passwords are section 5's (SC9).
- While a sheet is open, the window's menu commands and keys stay live (as with Files' other sheets, Go to Folder and the
  deletion confirmations); macOS disables them under a sheet.
- The certificate path is tested on KIO's answers (table, extension and sheet), not against a live https server with a bad
  certificate.
- A worker's message box whose job's delegate is deleted before the user answers goes unanswered, and KIO's notification
  queue then waits for it, holding the later message boxes of Files' workers (`usernotificationhandler.cpp:43-54`); KIO's
  own widget handler behaves the same way.


## 10. Screenshots and screen recording (inventory O1, O2, P8; ADR-0035 D-10, owner decision Q4; built in step 8; the toolbar and recording: ADR-0045 OC-1)

### macOS reference behavior
Shift-Cmd-3 captures the screen, and Shift-Cmd-4 a selection: a drag captures an area, and the window mode captures a window.
The picture is saved to the Desktop as "Screenshot <date> at <time>.png". Shift-Cmd-5 opens the capture toolbar (macOS 27):
a floating bar centred near the bottom of the screen, over the Dock, with Close, then Capture Entire Screen, Capture Selected
Window and Capture Selected Portion, then Record Entire Screen and Record Selected Portion, then Options and the Capture or
Record button. Options holds Save to (Desktop, Documents, Clipboard, Mail, Messages, Preview, Other Location), Timer (None, 5
Seconds, 10 Seconds), Microphone (recordings: None and the inputs) and Show Mouse Pointer, and the toolbar remembers them. Esc
closes it, Return captures. A recording shows a stop button in the menu bar until Control-Command-Esc or that button stops
it; it is saved as "Screen Recording <date> at <time>.mov". macOS records no system audio.

### Functional requirements
- SC1 Shift-Cmd-3 captures every display, one picture each, as macOS does (8-4). Shift-Cmd-4 and Print capture a
  selection: a crosshair over the live screen in Grassfield's colours (`capture.*`: an even veil; the window or display
  under the pointer outlined).
  - A drag captures that area.
  - A click captures the window drawn on top under the pointer (on a workspace with a fullscreen or zoomed window, that
    window or one pinned over it), or the display under it when no window is there (the Desktop, the menu bar, the Dock).
  - Esc, or a second press while the crosshair shows, cancels without saving; only this helper's crosshair is cancelled.
- SC2 Each file is saved on the Desktop as macOS names it, translated (the next display's " (2)"), and never overwrites a
  file; the Desktop never shows a picture being written. The Desktop is xdg-user-dir's, never the home folder.
- SC3 The focused display's picture, or the selection, is copied to the clipboard as PNG.
- SC4 A notice shows the picture, as the shell's ordinary banner (then in the Notification Center). A click or its "Open in
  Preview" button opens the capture's pictures in Grassfield's Preview for 2 minutes; then the notice goes. The next capture
  closes it first, so no picture shows the notice of the one before.
- SC5 No Omarchy command or shortcut is named, and no tensaku. Only the real session runs the capture keys and the stop key;
  the nested session never captures the owner's screen (the toolbar opens there, and runs no helper unless a dev session
  names one, `GRASSFIELD_CAPTURE_HELPER`, ADR-0019).

### Capture toolbar
- SC6 Shift-Super-5 (`config/hypr/grassfield/bindings.lua`, the shell's `capture toggle`) opens the toolbar on the focused
  display; again, it closes. It is a shell layer surface (`grassfield-capture`, `shell/capture/CaptureToolbar.qml`) over the
  whole display that holds the keyboard (exclusive, as Search) and swallows the clicks around the bar; opening it closes
  Overview, Apps, Search and the app switcher (ExclusiveSurfaces) and an open menu; the key focus returns to the window that
  had it when it closes. It never opens while the session is locked (`SessionState.refuses("capture")`) and closes when the
  session locks.
- SC7 Layout (macOS 27): a floating bar of the macOS 26 glass (the menus' class, `capture.toolbarHeight` 48 with round ends,
  `capture.toolbarPadding` 8 inside), centred `capture.toolbarBottomGap` above the Dock's band (or the display's bottom edge):
  Close (`xmark-circle-fill`: a grey filled disc, the secondary text colour, with the cross knocked out) | Capture Entire
  Screen, Capture Selected Window, Capture Selected Portion | Record Entire Screen, Record Selected Portion | Options and its
  chevron, then the action, Capture or Record (the shared `Button`, primary capsule, as tall as the bar's other controls,
  `capture.toolbarButtonHeight` 32). The mode buttons are the shared `ToolButton` (capsules
  `capture.toolbarButtonWidth` x `capture.toolbarButtonHeight`, own glyphs `capture-screen`, `capture-window`,
  `capture-selection`, `record-screen`, `record-selection`), one checked at a time with the neutral selection on glass; each
  names itself in a tooltip; groups are split by the toolbar hairline (`toolbar.dividerHeight`, the menus' separator colour).
  Hover, pressed and disabled are the shared controls'; Increase Contrast outlines them and frosts the glass; Reduce
  Transparency makes it opaque; the bar does not move (Reduce Motion has nothing to change).
- SC8 Keys: Esc closes (an open Options menu first), Return and Enter run the action, Left and Right choose the previous or
  next mode. A click on a mode chooses it; the mode is kept (`capture.mode`) and the toolbar opens in it next time.
- SC8a The modes act on the toolbar's own surface, as macOS 27's do (the design review of OC-1, H1; `CaptureToolbar.qml`, the
  pure decisions in `CaptureModel.js`):
  - Capture and Record Selected Portion: as soon as the mode is chosen a frame shows on the toolbar's display, the rest of the
    display dimmed (`capture.frameVeil` around it, black at 45 percent: the helper's crosshair keeps `capture.veil`, `capture.border` and `capture.borderWidth` on it), with eight handles (discs of
    `capture.handleSize`, taken in a `capture.handleHitSize` square, the corners first). A drag on a handle resizes the frame
    (past the opposite edge it turns over), inside it moves it, outside it draws a new one; it stays on the display and at
    least `capture.frameMinSize` each way. While dragging, the size readout (W × H of the picture, in pixels: the logical size
    at the output's real scale: Hyprland's monitor scale, 1.25 gives 1145 × 630 for a 916 × 504 frame, never the layer
    surface's integer ratio) shows beside the pointer on a small glass plate (`capture.readout*`). The pointer is a crosshair
    outside the frame, a move pointer inside, a resize pointer on a handle. The frame opens on the display's last one
    (`capture.lastSelection`, per display name, brought back on the display), else a centred frame half the display each way (from the screen's own logical size: the toolbar's window is 0x0, then 100x100, while it maps).
    Capture, Record and Return act on its geometry.
  - Capture Selected Window: the window under the pointer is tinted with the accent (`capture.windowHighlightOpacity`, its
    corner the window's own superellipse, `capture.windowHighlightRadius` at `capture.windowHighlightPower`): the window drawn on top there among the shown Desktop's windows of
    the platform's window list (`Compositor.windowsOn`), the most recently activated one, a full-screen window hiding those
    activated before it, clipped to the display. A click captures that window; a click where no window is does nothing; Esc
    closes. Every display's surface takes the pointer in this mode (input only; the bar stays on the toolbar's display, the keyboard
    follows the pointer's display: a layer with Exclusive keyboard keeps the pointer on its own display in the compositor). Grassfield's cursor theme has no camera pointer, so the arrow shows. Return and Capture take the window under the
    pointer, else the helper's crosshair (the fallback).
  - Capture and Record Entire Screen: a click on any display captures or records that display (every display's surface takes
    the pointer, the keyboard following the pointer's display as in Capture Selected Window); the Capture button still captures every display, Record the toolbar's display.
  - The geometry goes to the helper as `--geometry "X,Y WxH"` (the compositor's logical coordinates, whole numbers) and the
    display clicked as `--output NAME`; the helper refuses (exit 2, nothing captured) a geometry that is not wholly on one
    enabled display or has no size. Its crosshair stays only as the fallback when the surface has no geometry to give.
- SC9 Options (the shared `PopupMenu` with section headers and check marks, opened above the button, inside the toolbar's
  surface): Save to (Desktop, Documents, Clipboard, Preview; a recording mode lists Desktop, Documents and Preview), Timer
  (None, 5 Seconds, 10 Seconds), Microphone in a recording mode (None, and the default input by its name), Show Mouse Pointer.
  A choice is saved at once (`capture.saveTo`, `capture.timer`, `capture.microphone`, `capture.showPointer`).
- SC10 The action hides the toolbar first, then (once its surface has given the keyboard back and gone,
  `focusReturn.releaseHoldMs` and a moment for the window's focus to return) runs `grassfield-capture` with the mode and the
  options (`shell/capture/CaptureModel.js` helperArgs): `screen [--output <the display clicked>] | window --geometry <the
  window> | selection --geometry <the frame>` with `--save`, `--timer`, `--pointer`; `record screen --output <the display
  clicked, else the toolbar's> | record selection --geometry <the frame>` with `--mic` too. Without a geometry the window mode
  is the helper's crosshair over the windows only (slurp -r). In a real session the helper runs in its own
  scope (uwsm-app, as the Dock starts apps), never in the shell's unit (its CPU and memory limits, its restarts).
- SC11 Save to: the Desktop (copied to the clipboard too, the notice); Documents (xdg-user-dir's, never the home folder;
  copied; the notice says Documents); Clipboard (the focused display's picture or the choice, copied as PNG; no file and no
  notice, as macOS); Preview (opened in Preview at once, no notice; the file is kept on the Desktop, since Preview cannot
  save a document).
- SC12 Timer: after the choice (the window clicked, the area dragged), the helper counts down; the shell shows the seconds
  left on a glass plate (`capture.countdownSize`, the menus' class, `grassfield-capture-countdown`, no keyboard, clicks pass
  through) centred on what will be captured, and drops it when the time is up; the picture or the recording waits half a
  second more, so the plate is in none (Hyprland draws the plate's layer without a fade, `windows.lua`). Ctrl-Super-Esc or
  the session locking cancels a countdown: nothing is captured.

### Screen recording
- SC13 Record Entire Screen records the display clicked, else the toolbar's display; Record Selected Portion the toolbar's
  frame (a frame that is a whole display is recorded as that display, an area as `WxH+X+Y`), with gpu-screen-recorder and the
  backend arguments of Omarchy's `omarchy-capture-screenrecording` (pinned): `-w <display> -s <its size, 4K at most>` or
  `-w WxH+X+Y`, `-k auto -f 60 -fm cfr -fallback-cpu-encoding yes`, `-cursor yes|no` (Show Mouse Pointer), and the
  microphone as `-a default_input -ac aac` when chosen. The desktop's sound is never recorded (macOS).
- SC14 The movie is written to a hidden file of the helper's in the destination (the Desktop, Documents; the clipboard is not
  offered and means the Desktop) and then takes the name "Screen Recording <date> at <time>.mp4" (the start time,
  « Enregistrement de l’écran … à … » in French), never replacing a file; a notice "Screen Recording", "Saved to the Desktop."
  (or Documents) with "Open" follows, whose click plays it in Preview; with Save to Preview it opens in Preview at once. A
  recorder that writes nothing leaves no file and a notice says the recording could not be saved.
- SC15 While it records, the menu bar shows a stop item at the left of the system items (`record-stop` and the elapsed time,
  m:ss, then h:mm:ss; never hidden when the bar is crowded, as a privacy indicator); a click stops the recording, and so does
  Ctrl-Super-Esc (`config/hypr/grassfield/system.lua`, `grassfield-capture stop`).
- SC15a Nothing is captured or recorded behind the lock (the security review of OC-1, MEDIUM), by three independent paths:
  - the shell stops the helper whenever the session is locked and the helper's state is not idle (`CaptureFile.stopNeeded`),
    on either change: the lock coming while a capture runs, and a capture becoming active while locked (a recording whose
    helper was slow to start after Record, a shell restarted under the lock that reads the state late), and asks again every
    2 s while that stays true; a recording writes its state ("starting") the moment its helper begins, before anything slow;
  - the helper reads the lock itself (`session_locked`): the shell's crash-recovery marker
    (`$XDG_RUNTIME_DIR/grassfield-lock-<instance>`, "locked" from the moment a lock is asked for until the unlock, also while the
    shell restarts; the reader the omarchy-shell stand-in uses) and Hyprland's displays blocked by "LOCK"; it refuses to start
    the recorder, and to take a picture, when either says locked (at its start and again just before the recorder or grim);
  - while recording, the helper reads the marker every 0.5 s and ends the recording itself (SIGINT to its recorder, the movie
    saved) when the session locks, with or without a shell.
- SC16 `stop` reads the helper's private state (`$XDG_RUNTIME_DIR/grassfield/capture-state.json`, 0600 in the 0700 folder,
  written by rename; the shell watches it: `shell/services/CaptureState.qml`) and sends SIGINT to the recorder that helper
  started, recognised by its pid, its start time and its parent (the helper, by its own pid and start time), held by a pidfd;
  never a process found by its name. A recorder still running 10 s later is killed. A state whose helper is gone (nobody
  holds the capture lock) is set back to idle. One recording or countdown runs at a time (the lock); a second is refused.
- SC17 Without gpu-screen-recorder (an Omarchy base package) the two Record buttons and their group are not shown, and the
  helper refuses `record` (exit 3) without running anything.

### Acceptance criteria
- A-SC1 (L0) `tests/shell/capture.sh`, with fakes that answer as the real tools do (slurp 1.5.0: the smallest box for a
  click, a click outside every box cancelled; notify-send's output ending before it does, under its own name in /proc):
  every display for the screen, the focused one first; a drag, a click on a window, on a window behind a larger one in
  front (opened without the focus), with the pointer unread or gone from slurp's box, with a hand that moved a pixel, on a
  pinned Picture-in-Picture window over the focused one, on a fullscreen window and the windows pinned or opened over it,
  on a display only, and outside every display, with fixtures that carry every field Hyprland gives, in its stacking
  order; the windows then the displays as slurp's boxes, in the veil's colour; the last capture's notice closed before the
  next, the crosshair not waiting for it, the picture waiting; SIGTERM while the notice waits; Esc and a
  second press (only this helper's slurp); slurp's colours equal to the tokens; the names in English and French and
  " (2)"; every name a capture can take in the next 30 s already there (a picture, a link out of the home folder, a
  dangling link): the next free ones taken, nothing overwritten or followed; no hidden file left; the Desktop's fallbacks, and one that cannot be written (no traceback); the clipboard; the
  notice's arguments; a click opening Preview 40 times out of 40, its button, no click, the bounded wait (notify-send
  closing its notice), gdbus without notify-send (a PATH of the fakes only, so the machine's own notify-send is never
  reached); Preview through `uwsm-app`; failures leave no file.
- A-SC2 (L0) `tests/shell/session_services.sh`: Shift-Super-3, Shift-Super-4 and Print call `grassfield-capture`, never
  `omarchy-capture`; Shift-Super-5 opens the shell's toolbar; Ctrl-Super-Esc runs `grassfield-capture stop`.
- A-SC3 (L2, owner) in the real session: Shift-Cmd-3 and Shift-Cmd-4 with a drag and a click on a window; the file on the
  Desktop and in the clipboard; the notice and Preview.
- A-SC4 (L0) `tests/shell/capture.sh` (`capture.d/options.py`, ADR-0045 OC-1): the toolbar's argv only (anything else is the
  usage, nothing run); the window mode (slurp -r over the windows only; a click outside every window, Esc); the pointer;
  Save to Documents (and xdg-user-dir answering the home folder), Clipboard (no file, no notice), Preview (opened at once);
  the timer's state (countdown, until, where, private), the picture after it and the plate's half second, a stop during it;
  a recording of a display (Omarchy's arguments, the hidden file, the state naming the helper's child), of a display above
  4K, with the microphone and the pointer into Documents, of an area, of a display clicked; a second recording refused; stop
  (SIGINT, the movie named, no hidden file), SIGTERM to the helper while recording (saved), a recorder ignoring SIGINT
  (killed), failing (no file, the notice), missing (exit 3, nothing run); SIGTERM during the countdown; stop never
  signalling a process named like the recorder whose start time or parent differs, nor a left-over state; the names and
  notices in French. The toolbar's geometry (H1): `--geometry` in slurp's form only (whole numbers, a positive size; 14
  malformed forms refused, nothing run), wholly on one display (across two, past an edge, left of every display, below one:
  refused, only Hyprland's displays read), for a frame and a window clicked (no crosshair), for a recording's frame (an area,
  a whole display by name); `--output` of a display clicked (that display only; one that is not there: nothing). The lock: the
  shell's marker saying locked refuses a recording and a picture; Hyprland's LOCK does too; the marker written during a
  recording ends it (SIGINT, the movie saved) without any shell; during a recording's countdown nothing is recorded; a
  recording's state says "starting" before the helper reads Hyprland's displays.
- A-SC5 (L0) `tests/unit/tst_capturemodel.qml` and `tst_capturefile.qml`: the modes and their order, the mode the toolbar
  opens in, the arrows, the helper's argv for every mode and option (with a geometry and a display clicked), the Options
  menu's rows and checks per mode, a choice as the setting it changes; the frame's default, clamp, handles and their hit
  test, resize (turning over, the minimum, the display's edges), move, a new frame drawn, the readout in pixels, the
  geometry text, the remembered frames (per display, 16 at most, within the settings contract's pattern), the window under
  the pointer (activation order, full screen), the clip to the display, the capture.* colours as QML reads them; the state
  file's path (dev and session), its reading (every malformed field refused, "starting"), the seconds left, the elapsed time,
  where the countdown plate goes, and the stop under the lock in both orders (a state that appears after the lock is stopped).
- A-SC6 (L1, nested, NOT VERIFIED in the cloud session that built it) the toolbar on the focused display, its glass, states
  and the Options menu above it; Esc, Return, the arrows; refused while locked; the frame (veil, handles, resize, move, draw,
  readout, reopened on the last frame), the window highlight and its click, a click on each of two displays; the countdown
  plate with a fake helper (`GRASSFIELD_CAPTURE_HELPER`) writing a countdown state; the menu bar's stop item with a recording
  state, and its stop when the session locks after the state appeared.
- A-SC7 (L2, owner) in the real session: every mode and option once, a recording of a display and of an area with and
  without the microphone, its stop from the menu bar, from Ctrl-Super-Esc and by locking; the files, the notices, Preview.

### Known limitations
A picture over 8 MiB shows Preview's icon in the notice, not the picture (8-3). A click on a window captures the window's
own box, without Grassfield's title bar; a click on the title bar itself captures the window behind it or the display
(8-5). Without notify-send (libnotify is optional), the last capture's notice is not closed before the next. While the crosshair shows, slurp outlines the smallest box under the pointer,
which can be a window behind a larger one; the picture is the window drawn on top under the pointer, as Hyprland draws them. The notification settings list the helper under its translated
name ("Screenshot", « Capture d’écran »), so a change of language starts it over.

The capture toolbar and recording (ADR-0045 OC-1) differ from macOS 27 here:
- The frame of the Selected Portion modes is drawn on the toolbar's display only (to frame another display, open the toolbar
  there); the readout shows only while dragging; the handles, the veil, the readout and the highlight are estimates of macOS
  27's (`capture.*`), not measurements.
- Capture Selected Window captures the window's box as it is on screen (whatever covers it, without its shadow and without
  Grassfield's title bar where the plugin draws one): macOS captures the window alone with its shadow. "On top" is the most
  recently activated window, not Hyprland's stacking order (the shell's window list has no stacking): a window raised without
  being activated, or a pinned one, may lose to another. A window's geometry is the window data the shell last read (read again
  when the toolbar opens and when the mode is chosen): a window that moved meanwhile is tinted where it was. There is no camera
  pointer (none in Grassfield's cursor theme): the arrow shows.
- In the Entire Screen modes nothing marks the display under the pointer before the click.
- No floating thumbnail after a capture (the notice stands for it); no Mail, Messages or Other Location in Save to; no
  Remember Last Selection and no Show Floating Thumbnail options; the microphone list holds the default input only.
- Save to Preview keeps the file on the Desktop (Preview cannot save a document); macOS keeps it unsaved in Preview.
- Recordings are MP4 (gpu-screen-recorder's container, as Omarchy's), not MOV; no system audio (as macOS); no mouse clicks
  shown. gpu-screen-recorder's `-cursor` option and its exit on SIGINT are taken from its documented behaviour and Omarchy's
  use, not run in the cloud session that built this (no recorder there): NOT VERIFIED until the owner's session.
- Show Mouse Pointer off: on a GPU where Hyprland draws the pointer in software, grim's picture holds the pointer all the
  same (Omarchy's screenshot forces hardware cursors around grim; Grassfield's helper changes no compositor setting).
- Esc does not cancel the countdown (the plate takes no keyboard, so that the window being captured stays the key window);
  Ctrl-Super-Esc does. The countdown is not shown while another recording runs (one state at a time); the timer still runs.
- Under the lock, a picture or a recording is refused by the helper only from the moment the shell's marker says "locked" or
  Hyprland reports the lock; between the lock key and the marker's write (the shell writes it synchronously when the lock is
  asked for) a capture that was already past its last check can still be taken. While recording, the session locking is seen
  within 0.5 s (the marker's poll) or at once by the shell, whichever comes first: up to that the recording runs on.
- The glyphs, the bar's height and padding and the countdown plate are estimates (`capture.*`
  tokens), not measurements of macOS 27; NOT VERIFIED on screen (no nested capture was taken by the cloud session that built
  them).
