pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.I18n
import Grassfield.Ui
import qs.capture
import qs.desktop
import qs.dock
import qs.lib
import qs.launchpad
import qs.menubar
import qs.notifications
import qs.osd
import qs.overview
import qs.overlay
import qs.platform
import qs.saver
import qs.search
import qs.security
import qs.security.idle
import qs.security.lock
import qs.security.polkit
import qs.security.secret
import qs.services
import qs.stages
import qs.switcher
import "platform/ExtensionStatus.js" as ExtensionStatus

// grassfield-shell root. Settings feed the design-system Appearance singleton; surfaces
// read Appearance and Tokens only.
ShellRoot {
    id: root

    // Never reload on file changes: a reload is a security event for the session lock (R12,
    // shell/security/lock/Lock.qml). Re-applied by every reload (Quickshell resets it to true).
    // Development restarts the shell instead (scripts/dev/shell-run.sh).
    settings.watchFiles: false

    // Instantiates the Translator singleton first: it installs the catalog (GRASSFIELD_LANG or system
    // locale) before the surfaces below evaluate their qsTr() strings.
    readonly property string language: Translator.language

    // The session configuration's watchers (keyboard.lua and mouse-trackpad.lua, SessionConfig, ADR-0031 amendment) start with
    // the shell: Quickshell makes a singleton only when it is first used, and nothing else uses it before a display trial.
    readonly property int sessionConfigReloads: SessionConfig.reloads

    // The formats of dates, times and numbers (region.formats, Settings > General > Language & Region): the Translator makes
    // them the default locale, so every Qt.locale() of the shell (menu bar clock, widgets, lock screen) follows.
    Binding {
        target: Translator
        property: "formats"
        value: Settings.regionFormats
    }

    Binding {
        target: Appearance
        property: "dark"
        value: Settings.dark
    }

    // Lock state and lock requests for the modules that must not import shell/security (Notifications, Search).
    Binding {
        target: SessionState
        property: "locked"
        value: Lock.locked
    }
    Binding {
        target: SessionState
        property: "saverShown"
        value: saver.shown
    }

    // The Dock's keyboard mode for the tiling popover, which never opens over it (services/TilingHover, TL22).
    Binding {
        target: TilingHover
        property: "dockKeyboard"
        value: dock.keyboardMode
    }

    // The authorization state for the modules that must not import shell/security (the clipboard history, ADR-0034 Q11): the
    // polkit sheet or a secret sheet is open (ADR-0035 D-9).
    Binding {
        target: SessionState
        property: "authorizing"
        value: authAgent.requestActive || secretAgent.requestActive
    }
    // The displays are off (Idle): no device answers a polkit request nobody can see (ADR-0045 OC-6).
    Binding {
        target: SessionState
        property: "displaysOff"
        value: idle.displayOff
    }
    // A security sheet or its key sink may hold the keyboard: the capture toolbar takes none meanwhile.
    Binding {
        target: SessionState
        property: "securityKeyboard"
        value: authAgent.queuePresent || secretAgent.requestActive || secretAgent.sinkingKeys
    }

    // Apps the person cannot see get less CPU and I/O (ADR-0048). While the overview or the app switcher is open every
    // window counts as visible and every limit is lifted at once (the person is about to pick one). Also starts the service.
    Binding {
        target: AppEnergy
        property: "awake"
        value: overviewSurface.open || switcher.active
    }

    Connections {
        target: SessionState

        function onLockRequested(reason: string): void {
            Lock.lock(reason);
        }
    }

    Binding {
        target: Appearance
        property: "transparency"
        value: Settings.transparency
    }

    Binding {
        target: Appearance
        property: "reduceTransparency"
        value: Settings.reduceTransparency
    }

    Binding {
        target: Appearance
        property: "reduceMotion"
        value: Settings.reduceMotion
    }

    Binding {
        target: Appearance
        property: "increaseContrast"
        value: Settings.increaseContrast
    }

    Binding {
        target: Appearance
        property: "textScale"
        value: Settings.textSize
    }

    Binding {
        target: Appearance
        property: "accentSetting"
        value: Settings.accentColor
    }

    Binding {
        target: Appearance
        property: "highlightSetting"
        value: Settings.accentHighlight
    }

    // Adaptive glass: what lies behind it on each output, when known (ADR-0024 G-3).
    Binding {
        target: Appearance
        property: "backdrops"
        value: Backdrop.known
    }

    // Menu shortcuts: the macOS symbols on a Mac, the text on a PC (keyboard.shortcutStyle, owner decision 2026-10-26).
    Binding {
        target: Appearance
        property: "shortcutStyle"
        value: MenuShortcut.style(Settings.keyboardShortcutStyle, SystemInfo.macDevice)
    }

    Binding {
        target: Appearance
        property: "iconMode"
        value: Settings.iconMode
    }

    Binding {
        target: Appearance
        property: "iconTintSetting"
        value: Settings.iconTint
    }

    Binding {
        target: Appearance
        property: "folderColorSetting"
        value: Settings.folderColor
    }

    // Screen magnification (Settings > Accessibility > Zoom): sent to the compositor once the settings are read, then on change.
    Binding {
        target: Zoom
        property: "ready"
        value: Settings.validRead
    }

    // Settings > Displays (ADR-0031): the backlight goes into the displays state the Settings app reads.
    Binding {
        target: Displays
        property: "backlight"
        value: Brightness.deviceAvailable ? {device: Brightness.device, level: Brightness.deviceLevel} : null
    }

    // Pointer size (Settings > Accessibility > Pointer): the compositor is asked for the new size live.
    Binding {
        target: Pointer
        property: "size"
        value: Settings.pointerSize
    }

    // Pointer colours: the cursor theme is regenerated (debounced, off the UI thread) and switched to; the state of the
    // build is written next to grassfield.json for the Settings app.
    Binding {
        target: Pointer
        property: "outlineColor"
        value: Settings.pointerOutlineColor
    }

    Binding {
        target: Pointer
        property: "fillColor"
        value: Settings.pointerFillColor
    }

    // The colours are the stored ones only once the file is read (a custom theme from an earlier session is kept until then).
    Binding {
        target: Pointer
        property: "colorsKnown"
        value: Settings.validRead
    }

    // A malformed grassfield.json is not a read: the compositor theme and the custom theme on disk stay as they are.
    Binding {
        target: Pointer
        property: "settingsFailed"
        value: Settings.writeBlocked
    }

    Binding {
        target: Pointer
        property: "statusPath"
        value: Settings.configDir + "/pointer-theme.json"
    }

    // One degraded-mode notice when the compositor extension is absent; withdrawn if it loads later.
    property string degradedNoticeKey: ""
    // Why it is absent (ADR-0009 "Amendment 2026-10-23", GF-033): the session loads no build that is not made for the
    // Hyprland that runs. The rebuild tool says whether none is (--status); with the opt-in setting
    // windows.rebuildExtension the shell builds it once in the background (--session) and says how it went.
    readonly property string extensionTool: "/usr/lib/grassfield/grassfield-compositor-rebuild"
    property string extensionVersion: ""
    property bool extensionRebuildTried: false
    // The build that needs rebuilding was made from an older Grassfield (ExtensionStatus "stale"): its notices speak of an
    // update to finish, never of the Hyprland version.
    property bool extensionStale: false

    // The degraded notice is shown once the compositor extension is known to be absent (Capabilities.absent: not at the
    // first timeout, a loaded plugin can answer late at login) and withdrawn when it is present.
    function syncDegradedNotice(): void {
        if (Capabilities.absent && degradedNoticeKey === "") {
            if (!extensionStatus.running) {
                extensionStatus.running = true;
                extensionStatusLate.restart();
            }
        } else if (!Capabilities.absent && degradedNoticeKey !== "") {
            Notifications.clear(degradedNoticeKey);
            degradedNoticeKey = "";
        }
    }

    // "Hyprland 0.56.2", or a generic name when the tool gave no version.
    function hyprlandName(): string {
        return extensionVersion !== "" ? qsTr("Hyprland %1").arg(extensionVersion) : qsTr("this version of Hyprland");
    }

    // The notice for the --status answer (`text`, "" when the tool is not there or did not answer in time).
    function postDegradedNotice(text: string): void {
        extensionStatusLate.stop();
        if (!Capabilities.absent || degradedNoticeKey !== "")
            return;
        const status = ExtensionStatus.parse(text);
        // The choice is ExtensionStatus.degradedNotice (unit tested: a stale build never gets a text naming Hyprland).
        const key = ExtensionStatus.degradedNotice(status, Settings.windowsRebuildExtension, extensionRebuildTried);
        console.info("grassfield: degraded notice posted (compositor extension absent: " + ExtensionStatus.notice(status) + ")");
        extensionVersion = ExtensionStatus.version(status);
        extensionStale = key.startsWith("stale");
        const rebuild = key.endsWith("-rebuilding");
        switch (key) {
        case "stale-rebuilding":
            // GF-083's wording: an update finishes at the next login (macOS: "Restart to finish installing").
            degradedNoticeKey = Notifications.postInternal(qsTr("Updating the compositor extension"), qsTr("Grassfield was updated, and its compositor extension is being updated in the background. Window titlebars and minimize come back once it is done, or after the next login."));
            break;
        case "stale-manual":
            // ADR-0041 step 2d (SP-6): no command to type; a click runs the rebuild the opt-in setting would have run.
            degradedNoticeKey = Notifications.postInternalAction(qsTr("Log out to finish updating"), qsTr("Grassfield was updated. Click to update its compositor extension, then log out and back in. Window titlebars and minimize are unavailable until then."), () => root.startExtensionRebuild("the notice"));
            break;
        case "mismatch-rebuilding":
            degradedNoticeKey = Notifications.postInternal(qsTr("Compositor extension needs a rebuild"), qsTr("It is not built for %1 yet. Window titlebars and minimize are unavailable while it is built in the background.").arg(hyprlandName()));
            break;
        case "mismatch-manual":
            degradedNoticeKey = Notifications.postInternalAction(qsTr("Compositor extension needs a rebuild"), qsTr("It is not built for %1 yet, so window titlebars and minimize are unavailable. Click to build it, then log out and back in.").arg(hyprlandName()), () => root.startExtensionRebuild("the notice"));
            break;
        default:
            degradedNoticeKey = Notifications.postInternal(qsTr("Compositor extension not loaded"), qsTr("Window titlebars and minimize are unavailable (compositor extension not loaded)."));
            return;
        }
        if (rebuild)
            startExtensionRebuild("the setting");
    }

    // The background rebuild (`--session`, as the user): started once per shell run by the opt-in setting, or by a click on
    // a manual degraded notice (ADR-0041 step 2d). A second click while it runs, or after it ran, starts nothing: the
    // result notice already said what is next.
    function startExtensionRebuild(why: string): void {
        if (extensionSession.running || extensionRebuildTried)
            return;
        extensionRebuildTried = true;
        console.info("grassfield: compositor extension rebuild started (" + why + ")");
        extensionSession.running = true;
    }

    // The notice for the --session answer.
    function postRebuildResult(text: string): void {
        const status = ExtensionStatus.parse(text);
        const outcome = ExtensionStatus.resultNotice(status, extensionStale);
        console.info("grassfield: compositor extension rebuild: " + ExtensionStatus.outcome(status));
        if (outcome === "updated-loaded")
            Notifications.postInternal(qsTr("Compositor extension updated"), qsTr("It is up to date and active."));
        else if (outcome === "updated-built")
            Notifications.postInternal(qsTr("Log out to finish updating"), qsTr("The compositor extension was updated. Log out and back in to use it."));
        else if (outcome === "rebuilt-loaded")
            Notifications.postInternal(qsTr("Compositor extension rebuilt"), qsTr("It is built for %1 and loaded.").arg(hyprlandName()));
        else if (outcome === "rebuilt-built")
            Notifications.postInternal(qsTr("Compositor extension rebuilt"), qsTr("It is built for %1. Log out and back in to use it.").arg(hyprlandName()));
        else if (outcome === "cannot-build")
            Notifications.postInternal(qsTr("Compositor extension not rebuilt"), qsTr("The build tools are missing or another build is running. Run grassfield-compositor-rebuild in a terminal to see why."));
        else
            Notifications.postInternal(qsTr("Compositor extension not rebuilt"), qsTr("The build failed. Run grassfield-compositor-rebuild in a terminal to see why."));
    }

    Process {
        id: extensionStatus
        command: [root.extensionTool, "--status"]
        stdout: StdioCollector {
            onStreamFinished: root.postDegradedNotice(text)
        }
    }

    // No answer (the tool is not installed, or it hangs): the plain notice all the same.
    Timer {
        id: extensionStatusLate
        interval: 3000
        onTriggered: root.postDegradedNotice("")
    }

    Process {
        id: extensionSession
        command: [root.extensionTool, "--session"]
        stdout: StdioCollector {
            onStreamFinished: root.postRebuildResult(text)
        }
    }

    // GF-083: a package update leaves the old shell and compositor plugin running until the next login (macOS: "Restart to
    // finish installing"). One notice per run; nothing is shown while the versions are unknown. While an Update Now run goes
    // on, the notice waits for its end, which says what finishes the update (a restart covers the log out, ADR-0033 s3.7):
    // onRunEnded below. A run still going on after an hour (its runner gone) no longer holds it.
    UpdateNotice {
        id: updateNotice
        property bool announced: false
        function announce(): void {
            if (!updatePending || announced)
                return;
            if (SoftwareUpdate.runningOp !== "" && !updateNoticeHeld.expired) {
                updateNoticeHeld.start();
                return;
            }
            announced = true;
            Notifications.postInternal(qsTr("Log out to finish updating"), qsTr("Grassfield was updated. Log out and back in to use the new version."));
        }
        onUpdatePendingChanged: announce()
    }

    Timer {
        id: updateNoticeHeld
        property bool expired: false
        interval: 60 * 60 * 1000
        onTriggered: {
            expired = true;
            updateNotice.announce();
        }
    }

    // Software Update (ADR-0033 U14, U20, U22): GF-083's pending logout goes to the pane through software-update.json; each
    // newly found release, and each episode of a [grassfield] that stops every update, is one notice whose click opens
    // Settings > General > Software Update (never for a check the user started: the service does not announce those).
    Binding {
        target: SoftwareUpdate
        property: "logoutPending"
        value: updateNotice.updatePending
    }

    Connections {
        target: SoftwareUpdate

        function onAnnounce(kind: string, version: string, installed: string): void {
            const open = () => SettingsApp.openSection("software-update");
            const name = SoftwareUpdate.releaseName(version, installed);
            if (kind === "blocking")
                Notifications.postInternalAction(qsTr("Updates are stopped"), qsTr("Grassfield's update repository cannot be used, and this stops every system update. Open Software Update to turn Grassfield updates off."), open);
            else if (kind === "grassfield")
                Notifications.postInternalAction(qsTr("Grassfield %1 is available").arg(name), qsTr("See what's new in Software Update."), open);
            else if (kind === "security")   // ADR-0050: a Grassfield release its descriptor marks as a security release
                Notifications.postInternalAction(qsTr("Important security update"), qsTr("Grassfield %1 includes important security fixes. Install it in Software Update.").arg(name), open);
            else if (kind === "omarchy")
                Notifications.postInternalAction(qsTr("Omarchy %1 is available").arg(name), qsTr("Update Now in Software Update installs it."), open);
            else if (kind === "toolkit")   // ADR-0041 step 2b (U31): no package name in the sentence (the service logs them)
                Notifications.postInternalAction(qsTr("Log out to finish updating"), qsTr("Some updates finish when you log out. Log out and back in to use them."), open);
        }

        // The end of an Update Now run (U33): one notice whose click opens the pane. A restart or a log out is not posted when
        // Settings' window is in front: its end sheet asks it there (U29). The restart and the log out are GF-083's notice
        // too: it is never posted after them, and a notice it held for the run is posted after any other end.
        function onRunEnded(kind: string): void {
            updateNoticeHeld.stop();
            updateNoticeHeld.expired = false;   // the next run holds GF-083's notice again
            const finishing = kind === "restart" || kind === "logout";
            if (finishing)
                updateNotice.announced = true;
            const settings = Compositor.frontAppId === "org.grassfield.Settings"
                && Compositor.frontToplevel !== Compositor.taggedToplevel("org.grassfield.Settings", "info");
            const open = () => SettingsApp.openSection("software-update");
            const notices = {
                "restart": [qsTr("Restart to finish updating"), qsTr("The updates are installed. Restart when you're ready.")],
                "logout": [qsTr("Log out to finish updating"), qsTr("Grassfield was updated. Log out and back in to use the new version.")],
                "migrations": [qsTr("Some of Omarchy's last steps need its terminal"), qsTr("The updates are installed. Open Software Update to finish them.")],
                "aur": [qsTr("Updates installed"), qsTr("Apps from the AUR are updated in Omarchy's terminal. Open Software Update to update them.")],
                "installed": [qsTr("Updates installed"), qsTr("This computer is up to date.")],
                "bootimage": [qsTr("Don't restart this computer yet"), qsTr("The update could not prepare the computer's startup files. Open Software Update for details.")],
                "incompatible": [qsTr("This update needs a newer version of Grassfield"), qsTr("Software Update checks again later and tells you when it's ready.")],
                "terminal": [qsTr("This update needs Omarchy's terminal"), qsTr("Open Software Update to continue it in Omarchy's terminal.")],
                "stopped": [qsTr("The update stopped before it finished"), qsTr("Open Software Update to try again.")],
                "failed": [qsTr("The update could not be installed"), qsTr("Open Software Update to see why.")]
            };
            const notice = notices[kind];
            if (notice && !(finishing && settings))
                Notifications.postInternalAction(notice[0], notice[1], open);
            updateNotice.announce();
        }
    }

    // ADR-0044 A-1: displays connected together for the first time (settled, two or more, never seen, not while locked): one
    // notice whose click opens Settings > Displays (macOS extends without asking; the arrangement is one click away).
    DisplayArrival {
        onOffered: key => Notifications.postInternalAction(qsTr("New display arrangement"), qsTr("These displays are connected together for the first time. Open Displays Settings to arrange them and choose the main display."), () => SettingsApp.openSection("displays"))
    }

    // ADR-0035 D-2: Hyprland's config errors, as one notice per new set (its red bar stays: on 0.56.2 the source is empty,
    // decision 3-15).
    // The lines are the details (no terminal: decision 3-6); the notice goes once they are gone.
    ConfigErrors {
        property string noticeKey: ""
        onAppeared: (lines, more) => {
            if (noticeKey !== "")
                Notifications.clear(noticeKey);
            // Singular/plural pair (the catalogs carry no numerus forms).
            const rest = more === 0 ? "" : (more === 1 ? qsTr("and 1 more") : qsTr("and %1 more").arg(more));
            noticeKey = Notifications.postInternal(qsTr("Some settings could not be applied"), noticeBody(lines, rest));
        }
        onCleared: {
            if (noticeKey !== "")
                Notifications.clear(noticeKey);
            noticeKey = "";
        }
    }

    Connections {
        target: SettingsApp

        function onMissing(): void {
            Notifications.postInternal(qsTr("Grassfield Settings is not installed"), qsTr("Install the grassfield-desktop package to open Settings."));
        }
    }

    Connections {
        target: GlanceApp

        function onMissing(): void {
            Notifications.postInternal(qsTr("Glance is not available"), qsTr("Install the grassfield-desktop package to preview files with Space."));
        }
    }

    Connections {
        target: Capabilities

        // No reply for helloAbsentMs, an unload (empty capabilities event), or a plugin that loads after the notice.
        function onAbsentChanged(): void {
            root.syncDegradedNotice();
        }
    }

    Wallpaper {
        // The session lock owns the screen: a video wallpaper pauses (ADR-0016 section 5).
        locked: Lock.lockState !== "unlocked"
    }
    HotCorners {}
    DesktopIcons {}
    DesktopWidgets {}
    MenuBar {
        searchActive: searchSurface.open
        onSearchRequested: searchSurface.toggle()
        captureActive: captureSurface.open
        onCaptureRequested: screen => captureSurface.toggleOn(screen)
    }
    Dock {
        id: dock
        onAppsRequested: appsSurface.toggle()
    }
    Overlay {}
    Stages {}
    Banners {}
    NotificationCenter {}
    OsdWindow {}
    // Log Out, Restart and Shut Down end under one fade to the ground (ADR-0040 ID-10; grassfield-session-end asks for it).
    ExitCover {}
    Search {
        id: searchSurface
    }
    // The one queue of the polkit sheet and the secret sheets (ADR-0035 D-9, master-prompt R12): one sheet on screen at a
    // time, in arrival order; no sheet takes the keyboard from another.
    SheetQueue {
        id: sheetQueue
        polkitPresent: authAgent.queuePresent
    }
    AuthAgent {
        id: authAgent
        queue: sheetQueue
    }
    // Password prompts of gcr's callers (gnome-keyring, GnuPG's pinentry, gcr-ssh-agent) through grassfield-prompter
    // (ADR-0035 D-9, step 9b). In a dev session it connects only to the test socket GRASSFIELD_PROMPTER_SOCKET names.
    SecretAgent {
        id: secretAgent
        queue: sheetQueue
        devSocket: Mode.devValue("PROMPTER_SOCKET")
        shellVersion: SystemInfo.grassfieldVersion
    }
    Idle {
        id: idle
        // Applications' org.freedesktop.ScreenSaver inhibitors, served by the menu bridge (GF-016).
        busInhibited: MenuBridge.screenSaverInhibited
    }
    // The screen saver (ADR-0032): the same inhibitors keep it off; its slideshow stops while the displays are off.
    Saver {
        id: saver
        busInhibited: MenuBridge.screenSaverInhibited
        displaysOff: idle.displayOff
    }
    Overview {
        id: overviewSurface
        // The session lock owns the screen and the keyboard: the overview closes and focuses nothing.
        locked: Lock.lockState !== "unlocked"
    }
    AppsController {
        id: appsSurface
    }
    Switcher {
        id: switcher
        // The session lock owns the screen and the keyboard: the switcher ends and does not start.
        locked: Lock.lockState !== "unlocked"
    }
    SwitcherWindow {
        controller: switcher
    }
    // The capture toolbar (Shift-Super-5, ADR-0045 OC-1) and the countdown of its timer.
    Capture {
        id: captureSurface
        // The session lock owns the screen and the keyboard: the toolbar closes and does not open.
        locked: Lock.lockState !== "unlocked"
    }

    // Opening Overview, Apps, Search, the app switcher or the capture toolbar closes the others: the keyboard follows the visible
    // top surface.
    ExclusiveSurfaces {
        surfaces: [
            {target: overviewSurface, close: () => overviewSurface.requestCloseForOther()},
            {target: appsSurface, close: () => appsSurface.hide()},
            {target: searchSurface, close: () => searchSurface.hide()},
            {target: switcher, close: () => switcher.cancel()},
            {target: captureSurface, close: () => captureSurface.hide()}
        ]
    }

    // Referencing Capabilities instantiates it, which sends the plugin hello; referencing Lock
    // instantiates the session lock (IPC target "lock", crash-recovery restore); referencing RecentItems makes it listen to
    // every launch from the start (it would otherwise exist only once the Grassfield menu opened); referencing NotResponding
    // registers its IPC target "anr" for the hyprland-dialog stand-in (ADR-0035 D-3), SharePicker its target "picker" for the
    // screen-sharing picker's stand-in (D-6); referencing TilingHover makes it listen
    // to the plugin's tile-hover events (the tiling popover, docs/specs/tiling.md TL22); referencing TilingSuggest makes it
    // listen to the suggestions that follow a layout or an arrangement (TL28); referencing SoftwareUpdate starts its automatic
    // checks and registers its IPC target "update" (ADR-0033 d.7); referencing ActivityLink registers its IPC target "activity"
    // and writes Activity Monitor's projection while the app's window is open (ADR-0038 AM60, AM61); referencing KeyWindow
    // writes the key window's file for the apps from the start (ADR-0039 step 17); referencing Emoji registers its IPC target
    // "emoji" for Ctrl+Super+Space and reads Recently Used (ADR-0045 OC-3; Omarchy's list waits for the first opening);
    // referencing Sounds makes it listen to the compositor's bell and the power adapter from the start, and Audio starts its
    // output routing (ADR-0047).
    Component.onCompleted: console.info("grassfield-shell: started, version", SystemInfo.grassfieldVersion, "plugin protocol", Capabilities.protocol, "lock", Lock.lockState, "recent items", RecentItems.max, "clipboard history", Clipboard.state, "not responding", NotResponding.marks.length, "share picker", SharePicker.current === null ? "idle" : "open", "tiling popover", TilingHover.address === "" ? "closed" : "open", "tiling suggestions", TilingSuggest.shown ? "shown" : "none", "software update", SoftwareUpdate.count, "activity link", ActivityLink.folder !== "" ? "ready" : "no runtime folder", "key window", KeyWindow.path !== "" ? "written" : "no runtime folder", "terminal theme", TerminalTheme.state, "emoji", Emoji.state, "sounds", Sounds.devSession ? "dev: silent" : "on", "audio routing", Audio.routingFile)
}
