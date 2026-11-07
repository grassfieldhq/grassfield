pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import "CaptureLocation.js" as CaptureLocation

// grassfield.json (contract version 1): schema, defaults, persistence. Not a singleton so that
// tests can create independent instances; the shell uses it through the Settings singleton.
// A missing or unreadable file leaves the defaults in place. The file is created on the first
// change made through a setter (Control Center, Dock menu), never otherwise. A new file holds
// every key of config/schema/grassfield.schema.json. Writes are merges: each setter records its
// dotted key in `dirty`; before writing, the file is re-read and only the dirty keys are replaced,
// so external edits (Settings app, by hand) and keys this shell does not know (not allowed by the
// schema, but never dropped) survive. The result is written atomically (a temporary file renamed
// over the target, following a symlinked grassfield.json to its target). A file that exists but
// is not valid JSON, that JSON.parse cannot round-trip (integers beyond 2^53, duplicate keys;
// JsonSafety.js, same rule as the Settings app), that is not a regular file (a FIFO, a device, a
// directory) or is larger than maxFileBytes, is never read in full and never overwritten
// (`writeBlocked`, logged once); the in-memory changes stay and the user fixes the file. A write
// that fails (a read-only directory, a full disk) keeps its change pending and is retried.
//
// Both reads of the file (the load and the fresh read before a write) are one bounded shell
// script (readScript): the file is never opened unless it is a regular file, at most maxFileBytes
// are read, and a read that hangs ends after a few seconds. The JSON adapter of Quickshell's
// FileView is not used: it reads without a limit and keeps old values.
Scope {
    id: root

    property string configDir: ""
    // Debounce for writes; tests use flush().
    property int saveDelay: 150

    // The most a grassfield.json may hold (a real one is a few KiB). A larger file, or one that is not a regular file, is
    // read as malformed without reading it: lock.* fails closed to its default and nothing is written back.
    readonly property int maxFileBytes: 1048576
    // The file is looked at again this often (ms) whatever the watch says: replacing a symlinked grassfield.json with a regular
    // file leaves a file watch on the old target. A stat of the path, nothing more unless it changed.
    property int pollInterval: 10000
    // A file found unusable is re-read at once when its signature changes (or the watch reports it); while the signature stays the
    // same the full re-read backs off: pollInterval, then twice, four times, ... up to this (ms). What can still change without the
    // signature is the reader (a `head` that stalled or failed), which is worth a try now and then, not every tick: a 1 MiB+ file or
    // a FIFO cost a bounded read and parse each time. 5 minutes: a permanently unusable file costs one read per 5 minutes (against
    // one per 10 s). Trade-off: a repair that changes no signature and raises no watch event (a recovered reader) is noticed
    // within 5 minutes, not 10 s; lock.* stays at its closed default until then.
    property int badRetryCap: 300000
    // The full reads started (tests count them).
    property int fullReads: 0
    // A directory searched before PATH for the tools the bounded read runs (head, stat, ...): tests put a stalled or a failing
    // `head` there. Empty in the shell (never taken from the environment); a relative path is ignored.
    property string toolDir: ""
    readonly property var toolEnvironment: root.toolDir.charAt(0) !== "/" ? ({}) : ({"PATH": root.toolDir + ":" + Quickshell.env("PATH")})
    // grassfield.json has been read at least once (also when it was malformed, too large, not a regular file or missing).
    property bool loaded: false
    // True while the file on disk could not be parsed: nothing is written until it loads again.
    property bool writeBlocked: false
    // True once a file was read and is valid (an empty file counts); false before any read and while the file on disk is
    // malformed or unreadable. Consumers that act destructively on "the settings are the defaults" wait for this, not for
    // `loaded` (which is also true for a malformed file, whose values are then only the last good ones).
    property bool validRead: false
    // True while the file read last was empty or only whitespace (validRead is true then: every key reads its default). A
    // consumer that deletes data on a default value waits for a file that says so: an empty file is what a cut write leaves.
    property bool emptyFile: false
    // True while the file on disk is valid JSON that cannot be rewritten safely (JsonSafety.unsafeReason): its values are
    // not used, the defaults are (see read()).
    property bool unsafeFile: false

    // The last document read from the file (JSON.parse of its text, the same path a fresh start takes) with the shell's own
    // pending changes on top. Every view reads from it. (Quickshell's JsonAdapter is not used: it does not replace a property
    // whose new value loosely equals the old one (0 and false, 10 and "10", 1 and true), so on a running shell an edit of
    // lock.idleMinutes from 0 to false left the auto-lock off while Settings and a restarted shell read 5; and it reads without
    // a bound.)
    property var parsedFile: ({})
    property int parsedFileRevision: 0

    // The stored (raw) value of a dotted key in parsedFile, undefined when the file has none.
    function rawValue(path: string): var {
        void root.parsedFileRevision;
        let node = root.parsedFile;
        for (const part of path.split(".")) {
            if (node === null || node === undefined || typeof node !== "object" || Array.isArray(node))
                return undefined;
            node = node[part];
        }
        return node;
    }

    // The value of a dotted key as every reader of grassfield.json sees it (ui/Grassfield/Ui/SettingsContract.js, generated from
    // the schema; ADR-0020): a number out of range is clamped (an integer rounded first), any other invalid value, a number
    // written as a string or a boolean included, is the key's default (lock.idleMinutes: only an exact 0 is "never"; false,
    // "0", a negative number and 0.4 read 5; a value above 240 reads 240, the lock still fires). A hand-edited file may hold
    // anything and reads the same here, in a restarted shell and in the Settings app, after every reload.
    function read(path: string): var {
        // A file the Settings app refuses to edit (an integer beyond 2^53, a duplicate key: JsonSafety) shows its defaults
        // there under a banner: the shell reads the same, never the values of a file it could not rewrite safely either.
        if (root.unsafeFile && SettingsContract.DEFAULTS[path] !== undefined) {
            void root.parsedFileRevision;
            return JSON.parse(JSON.stringify(SettingsContract.DEFAULTS[path]));
        }
        return SettingsContract.normalize(path, rawValue(path));
    }

    // Sets a dotted key of parsedFile (a local change, or one put back on top of a fresh load).
    function setParsed(path: string, value: var): void {
        const parts = path.split(".");
        let node = root.parsedFile;
        for (let i = 0; i < parts.length - 1; i++) {
            if (node[parts[i]] === null || typeof node[parts[i]] !== "object" || Array.isArray(node[parts[i]]))
                node[parts[i]] = ({});
            node = node[parts[i]];
        }
        node[parts[parts.length - 1]] = value;
        root.parsedFileRevision++;
    }

    // After each load: the file's own text is the document. An empty file is an empty document (every key its default). A file
    // that is not a JSON object leaves the last good document in place for the cosmetic keys (validRead tells it is malformed),
    // but NOT for lock.*: the idle lock fails closed there, it reads what a fresh start reads (the default 5), never the last
    // good value, which may be 0 = never.
    function takeDocument(text: string): void {
        let parsed = null;
        try {
            parsed = text.trim() === "" ? {} : JSON.parse(text);
        } catch (e) {
            parsed = null;
        }
        if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
            if ("lock" in root.parsedFile) {
                delete root.parsedFile.lock;
                root.parsedFileRevision++;
            }
            return;
        }
        root.parsedFile = parsed;
        root.parsedFileRevision++;
    }

    // The file is gone: exactly a fresh start without a file. The document is empty (every key its default, lock.idleMinutes 5),
    // writes are allowed again (the next change creates the file from the defaults), and the shell's own pending changes stay
    // on top.
    function takeMissingFile(): void {
        root.parsedFile = ({});
        root.unsafeFile = false;
        root.writeBlocked = false;
        root.validRead = false;
        root.emptyFile = false;
        root.parsedFileRevision++;
        root.reapplyDirty();
        // A change made while the file could not be used waits no longer: the next write creates the file.
        if (Object.keys(root.dirty).length > 0)
            root.save();
    }

    // The file cannot be used as it is (not a regular file, larger than maxFileBytes, or not readable): read as malformed. The
    // cosmetic keys keep their last good values, lock.* fails closed (the default, as a restart reads it), nothing is written.
    function takeBadFile(reason: string): void {
        if (!root.writeBlocked)
            console.warn("settings: " + root.filePath + " is " + reason + "; keeping the file untouched, changes will not be saved until it is fixed");
        root.writeBlocked = true;
        root.validRead = false;
        root.emptyFile = false;
        root.unsafeFile = false;
        // The sentinel no signature equals: whichever read found the file unusable (the load, or the read before a write), the poll
        // reads it again (at once when the signature changed, else with a growing pause), so the store recovers when the file or
        // the reader does, whatever the watch says (it does not report the repair of a symlink to a device, a directory, ...).
        root.lastSignature = "!";
        // The signature it was found at is not known here (applyRead sets it); until then the next poll reads it once more.
        root.badSignature = "";
        root.badLevel = 0;
        root.badTicks = 0;
        saveTimer.stop();
        retryTimer.stop();
        if ("lock" in root.parsedFile) {
            delete root.parsedFile.lock;
            root.parsedFileRevision++;
        }
        root.reapplyDirty();
    }

    readonly property string appearance: read("appearance")
    readonly property real transparency: read("material.transparency")
    readonly property string materialProfile: read("material.profile")
    readonly property bool reduceTransparency: read("accessibility.reduceTransparency")
    readonly property bool reduceMotion: read("accessibility.reduceMotion")
    readonly property bool increaseContrast: read("accessibility.increaseContrast")
    // Text size multiplier of the shell's text (Settings > Accessibility > Display), 1 to 1.3; a hand-edited value is clamped.
    readonly property real textSize: read("accessibility.textSize")
    readonly property bool zoomOn: read("accessibility.zoom")
    readonly property real zoomLevel: read("accessibility.zoomLevel")
    // Tile size of the Dock in px (Settings > Size); a hand-edited value is clamped to the slider range.
    readonly property int dockSize: read("dock.size")
    // Screen edge of the Dock (Settings > Position on screen).
    readonly property string dockPosition: read("dock.position")
    readonly property real dockMagnification: read("dock.magnification")
    readonly property bool dockMagnificationEnabled: read("dock.magnificationEnabled")
    readonly property bool dockAutohide: read("dock.autohide")
    readonly property bool dockShowRecents: read("dock.showRecents")
    readonly property bool dockMinimizeIntoApp: read("dock.minimizeIntoApp")
    readonly property bool dockClickMinimizes: read("dock.clickMinimizes")
    readonly property bool dockAnimateOpening: read("dock.animateOpening")
    readonly property bool dockShowIndicators: read("dock.showIndicators")
    // End Task in the Dock menus of running apps (ADR-0038 AQ5, AM63): off by default, as Windows' own.
    readonly property bool dockEndTask: read("dock.endTask")
    // The clipboard history in Search (ADR-0034): off until allowed; retention of unpinned items; the opt-in history store; the
    // Clear Clipboard History marks the Settings app writes (milliseconds since the epoch; a change clears).
    readonly property bool clipboardEnabled: read("search.clipboard.enabled")
    readonly property string clipboardRetention: read("search.clipboard.retention")
    readonly property bool clipboardKeepOnDisk: read("search.clipboard.keepOnDisk")
    readonly property real clipboardClearedAt: read("search.clipboard.clearedAt")
    readonly property real clipboardPinnedClearedAt: read("search.clipboard.pinnedClearedAt")
    // Software Update's automatic checks (ADR-0033 d.5): on by default; opening the pane checks whatever this says.
    readonly property bool updatesAutomaticCheck: read("updates.automaticCheck")
    // Apps the person cannot see get less CPU and I/O (ADR-0048, Settings > Battery > Options…): on by default.
    readonly property bool energySlowHiddenApps: read("energy.slowHiddenApps")
    // Sound effects (ADR-0047 part B): the alert's id and volume, where effects play, interface sounds, volume feedback.
    readonly property string soundAlert: read("sound.alert")
    readonly property real soundAlertVolume: read("sound.alertVolume")
    readonly property string soundEffectsOutput: read("sound.effectsOutput")
    readonly property bool soundUiEffects: read("sound.uiEffects")
    readonly property bool soundVolumeFeedback: read("sound.volumeFeedback")
    // The default list of the first releases (a file written by them holds it) reads as the current default: Files is the
    // fixed first tile now and Nautilus is no default any more (same rule as DockModel.migratePinned). Any other list, a
    // user's own, is returned as it is. Nothing is written back. The Dock owns this key and its recent list and stack options.
    readonly property var dockPinned: {
        const stored = rawValue("dock.pinned");
        const list = stringList(stored === undefined ? SettingsContract.ALL_DEFAULTS["dock.pinned"] : stored);
        return list.join("\n") === "foot\nchromium\norg.gnome.Nautilus" ? ["chromium", "foot", "org.grassfield.Settings"] : list;
    }
    readonly property var dockRecent: stringList(rawValue("dock.recent"))
    readonly property var dockFolders: read("dock.folders")
    readonly property var dockStackOptions: {
        const stored = rawValue("dock.stackOptions");
        return stored !== null && typeof stored === "object" && !Array.isArray(stored) ? stored : ({});
    }
    readonly property string titlebarDoubleClick: read("windows.titlebarDoubleClick")
    readonly property bool windowsTilingEdges: read("windows.tilingEdges")
    readonly property bool windowsTilingMenuBar: read("windows.tilingMenuBar")
    readonly property bool windowsTilingOptionDrag: read("windows.tilingOptionDrag")
    readonly property bool windowsTilingMargins: read("windows.tilingMargins")
    readonly property bool windowsTilingLayouts: read("windows.tilingLayouts")
    readonly property bool windowsTilingSuggestions: read("windows.tilingSuggestions")
    readonly property bool windowsTilingGroups: read("windows.tilingGroups")
    readonly property bool windowsStages: read("windows.stages")
    readonly property bool windowsRebuildExtension: read("windows.rebuildExtension")
    readonly property string dockMinimizeEffect: read("dock.minimizeEffect")
    readonly property bool notificationsDnd: read("notifications.dnd")
    readonly property var notificationsAppPreviews: read("notifications.appPreviews")
    readonly property var notificationsAppStyles: read("notifications.appStyles")
    readonly property string notificationsHistory: read("notifications.history")
    readonly property string notificationsPreviews: read("notifications.previews")
    readonly property bool desktopShowIcons: read("desktop.showIcons")
    // The remembered choices of the main display, one per set of connected displays (DisplayRole.js, ADR-0044).
    readonly property var displaysMain: read("displays.main")
    readonly property bool menubarShowBackground: read("menubar.showBackground")
    readonly property string menubarAutoHide: read("menubar.autoHide")
    readonly property bool menubarShowNowPlaying: read("menubar.showNowPlaying")
    readonly property bool menubarShowSearch: read("menubar.showSearch")
    readonly property bool menubarShowWifi: read("menubar.showWifi")
    readonly property bool menubarShowSound: read("menubar.showSound")
    readonly property bool menubarShowBattery: read("menubar.showBattery")
    readonly property bool menubarShowBatteryPercentage: read("menubar.showBatteryPercentage")
    readonly property bool menubarShowFocus: read("menubar.showFocus")
    readonly property string menubarClockDate: read("menubar.clockDate")
    readonly property bool menubarClockShowAmPm: read("menubar.clockShowAmPm")
    readonly property bool menubarClockFlashSeparators: read("menubar.clockFlashSeparators")
    readonly property bool menubarShowTrayItems: read("menubar.showTrayItems")
    readonly property int menubarRecentItems: read("menubar.recentItems")
    readonly property bool menubarClockShowDayOfWeek: read("menubar.clockShowDayOfWeek")
    readonly property string menubarClockHours: read("menubar.clockHours")
    readonly property bool menubarClockShowSeconds: read("menubar.clockShowSeconds")
    readonly property string accentColor: read("accent.color")
    readonly property string accentHighlight: read("accent.highlight")
    // Settings > Appearance > Terminal and Developer Apps (ADR-0045 OC-11): Omarchy's theme follows the effective appearance
    // (services/TerminalTheme.qml runs grassfield-terminal-theme); the two Omarchy theme names, as omarchy-theme-list prints them.
    readonly property bool terminalMatchAppearance: read("terminal.matchAppearance")
    readonly property string terminalLightTheme: read("terminal.lightTheme")
    readonly property string terminalDarkTheme: read("terminal.darkTheme")
    // automatic | mac | pc (Settings > Keyboard): how menus label shortcuts; "automatic" follows the device (MenuShortcut.style).
    readonly property string keyboardShortcutStyle: read("keyboard.shortcutStyle")
    // Settings > Keyboard > Input Sources: the Input menu of the menu bar (it exists from two input sources on).
    readonly property bool keyboardShowInputMenu: read("keyboard.showInputMenu")
    // Settings > Keyboard > Dictation (ADR-0045 OC-5): Ctrl-Super-X runs voxtype; bindings.lua reads the file itself at each press.
    readonly property bool keyboardDictation: read("keyboard.dictation")
    // auto | a locale name ("fr_CH"), and auto | monday … sunday (Settings > General > Language & Region): the formats of dates,
    // times and numbers, and the first day of the week in the calendars.
    readonly property string regionFormats: read("region.formats")
    readonly property string regionFirstDayOfWeek: read("region.firstDayOfWeek")
    readonly property string iconMode: read("icons.mode")
    readonly property string iconTint: read("icons.tint")
    readonly property string folderColor: read("icons.folderColor")
    readonly property int pointerSize: read("pointer.size")
    readonly property string pointerOutlineColor: read("pointer.outlineColor")
    readonly property string pointerFillColor: read("pointer.fillColor")
    // The wallpaper settings, complete and valid (WallpaperConfig.normalize: an invalid field reads as its default).
    // The shell only reads them; the Settings app writes them.
    readonly property var wallpaper: root.unsafeFile ? WallpaperConfig.normalize({}) : WallpaperConfig.normalize({
        source: rawValue("wallpaper.source"),
        path: rawValue("wallpaper.path"),
        color: rawValue("wallpaper.color"),
        fit: rawValue("wallpaper.fit"),
        interval: rawValue("wallpaper.interval"),
        shuffle: rawValue("wallpaper.shuffle"),
        videoOnBattery: rawValue("wallpaper.videoOnBattery"),
        online: rawValue("wallpaper.online"),
        artwork: rawValue("wallpaper.artwork"),
        artworkVariant: rawValue("wallpaper.artworkVariant"),
        moving: rawValue("wallpaper.moving"),
        outputs: rawValue("wallpaper.outputs")
    })
    // Minutes of inactivity before the session locks, 0 = never. An invalid value is the default 5, never 0 (fail closed:
    // false or "0" in a hand-edited file must not switch the auto-lock off).
    readonly property int lockIdleMinutes: read("lock.idleMinutes")
    // Minutes without input before the displays turn off while unlocked, on battery and on the power adapter; 0 = never.
    readonly property int lockDisplayOffBattery: read("lock.displayOffBattery")
    // When a display that turned off for inactivity locks the session (ADR-0040 IQ-T4 A): "immediately" ... "never".
    readonly property string lockRequirePasswordAfterDisplayOff: read("lock.requirePasswordAfterDisplayOff")
    readonly property int lockDisplayOffPower: read("lock.displayOffPower")
    // The lock screen shows the account's name and picture, and the user's message (plain text, one line).
    readonly property bool lockShowUser: read("lock.showUser")
    readonly property bool lockShowMessage: read("lock.showMessage")
    readonly property string lockMessage: read("lock.message")
    // On the power adapter (or without a battery) the computer does not sleep by itself once the displays are off
    // (macOS 27 Energy, Battery > Options). Sleep only: never read by a lock decision (shell/security/idle).
    readonly property bool energyPreventSleep: read("energy.preventSleep")
    // The kinds of results Search shows (Settings > Search > Search Results), and the last Delete Search History (milliseconds
    // since the epoch, 0 = never; a real: it does not fit an int).
    readonly property bool searchShowApps: read("search.showApps")
    readonly property bool searchShowDocuments: read("search.showDocuments")
    readonly property bool searchShowRecents: read("search.showRecents")
    readonly property bool searchShowCalculator: read("search.showCalculator")
    readonly property bool searchShowConversions: read("search.showConversions")
    readonly property bool searchShowSettings: read("search.showSettings")
    readonly property bool searchShowCommands: read("search.showCommands")
    readonly property real searchHistoryResetAt: read("search.historyResetAt")
    // The screen saver (Settings > Wallpaper > Screen Saver, ADR-0032): its delay in minutes (0 = never), which one, and the
    // slideshow's folder ("" = the Pictures folder).
    readonly property int screenSaverIdleMinutes: read("screensaver.idleMinutes")
    readonly property string screenSaverKind: read("screensaver.kind")
    readonly property string screenSaverFolder: read("screensaver.folder")
    // The capture toolbar (Shift-Super-5, ADR-0045 OC-1): the mode chosen last and its Options menu (Save to, Timer, Microphone,
    // Show Mouse Pointer). The toolbar writes them; no Settings pane shows them.
    readonly property string captureMode: read("capture.mode")
    // Save to (capture.location; capture.saveTo is the older key, read only while location is absent: CaptureLocation.effective,
    // which keeps its documents, clipboard and preview and moves its desktop, the old default, to the Screenshots folder).
    readonly property string captureLocation: CaptureLocation.effective(rawValue("capture.location"), rawValue("capture.saveTo"), root.unsafeFile)
    // The older key as the contract reads it (the settings vectors; nothing else reads it).
    readonly property string captureSaveTo: read("capture.saveTo")
    readonly property string captureTimer: read("capture.timer")
    readonly property string captureMicrophone: read("capture.microphone")
    readonly property bool captureShowPointer: read("capture.showPointer")
    // The last frame of the Selected Portion modes per display ("NAME=x,y,w,h;..."; CaptureModel.parseSelections reads it).
    readonly property string captureLastSelection: read("capture.lastSelection")

    readonly property string hotCornerTopLeft: read("hotCorners.topLeft")
    readonly property string hotCornerTopRight: read("hotCorners.topRight")
    readonly property string hotCornerBottomLeft: read("hotCorners.bottomLeft")
    readonly property string hotCornerBottomRight: read("hotCorners.bottomRight")

    // A stored tile size: a whole number inside the slider's range (dock.sizeMin..dock.sizeMax); anything that is not a number reads
    // as the default size (same rule as Geometry.clampSize, which the Dock uses for the live resize).
    function tileSize(value: var): int {
        return typeof value === "number" && isFinite(value) ? Math.round(Math.max(Tokens.dockSizeMin, Math.min(Tokens.dockSizeMax, value))) : Tokens.dockIconSize;
    }

    // A stored Dock edge: left or right, anything else is the bottom (Geometry.normalizeEdge).
    function dockEdge(value: var): string {
        return value === "left" || value === "right" ? value : "bottom";
    }

    // Hot corner action clamped to the schema enum.
    function cornerAction(value: var): string {
        return ["none", "overview", "notifications", "apps", "lock"].indexOf(value) >= 0 ? value : "none";
    }

    function stringList(list: var): var {
        const out = [];
        const n = list && typeof list.length === "number" ? list.length : 0;
        for (let i = 0; i < n; i++) {
            if (typeof list[i] === "string" && list[i] !== "")
                out.push(list[i]);
        }
        return out;
    }

    function clampNumber(value: var, min: real, max: real, fallback: real): real {
        const n = Number(value);
        return isFinite(n) ? Math.max(min, Math.min(max, n)) : fallback;
    }

    signal saved
    signal loadedFile

    function setAppearance(value: string): void {
        change("appearance", value === "light" || value === "auto" ? value : "dark");
    }

    function setTransparency(value: real): void {
        change("material.transparency", Math.max(0, Math.min(1, value)));
    }

    function setReduceTransparency(value: bool): void {
        change("accessibility.reduceTransparency", value);
    }

    function setReduceMotion(value: bool): void {
        change("accessibility.reduceMotion", value);
    }

    function setIncreaseContrast(value: bool): void {
        change("accessibility.increaseContrast", value);
    }

    function setZoom(value: bool): void {
        change("accessibility.zoom", value);
    }

    function setZoomLevel(value: real): void {
        change("accessibility.zoomLevel", clampNumber(Math.round(value * 2) / 2, 1.5, 5, 2));
    }

    function setTextSize(value: real): void {
        change("accessibility.textSize", clampNumber(value, 1, 1.3, 1));
    }

    function setDockAutohide(value: bool): void {
        change("dock.autohide", value);
    }

    function setDockSize(value: real): void {
        change("dock.size", tileSize(value));
    }

    function setDockPosition(value: string): void {
        change("dock.position", dockEdge(value));
    }

    function setDockMagnification(value: real, enabled: bool): void {
        change("dock.magnification", Math.max(1, Math.min(2.5, value)));
        change("dock.magnificationEnabled", enabled);
    }

    function setDockPinned(list: var): void {
        change("dock.pinned", list);
    }

    function setDockRecent(list: var): void {
        change("dock.recent", stringList(list));
    }

    function setDockFolders(list: var): void {
        change("dock.folders", stringList(list));
    }

    // Options of the stacks as a whole ({path: {sort, view, display}}, already normalized by Stacks.withOption).
    function setDockStackOptions(options: var): void {
        change("dock.stackOptions", options && typeof options === "object" ? options : ({}));
    }

    // corner: topLeft | topRight | bottomLeft | bottomRight.
    function setHotCorner(corner: string, action: string): void {
        if (["topLeft", "topRight", "bottomLeft", "bottomRight"].indexOf(corner) < 0)
            return;
        change("hotCorners." + corner, cornerAction(action));
    }

    function setStagesEnabled(value: bool): void {
        change("windows.stages", value);
    }

    // The Clipboard view's first-use prompt: "Allow" (ADR-0034 CB-6).
    function setClipboardEnabled(value: bool): void {
        change("search.clipboard.enabled", value);
    }

    function setDesktopShowIcons(value: bool): void {
        change("desktop.showIcons", value);
    }

    function setMenubarShowBackground(value: bool): void {
        change("menubar.showBackground", value);
    }

    function setMenubarAutoHide(value: string): void {
        change("menubar.autoHide", ["always", "desktop", "fullscreen", "never"].indexOf(value) >= 0 ? value : "fullscreen");
    }

    function setAccentColor(value: string): void {
        change("accent.color", Accent.normalize(value));
    }

    function setIconMode(value: string): void {
        change("icons.mode", IconModes.normalizeMode(value));
    }

    function setIconTint(value: string): void {
        change("icons.tint", IconModes.validTint(value) ? value : "accent");
    }

    function setFolderColor(value: string): void {
        change("icons.folderColor", FolderStyle.normalizeColor(value));
    }

    function setPointerSize(value: int): void {
        change("pointer.size", PointerSize.snap(value));
    }

    function setNotificationsDnd(value: bool): void {
        change("notifications.dnd", value);
    }

    // One app's Show previews: always | unlocked | never, or "default" to follow the global setting again.
    function setNotificationsAppPreview(app: string, value: string): void {
        change("notifications.appPreviews", NotificationPrefs.withValue(notificationsAppPreviews, app, value));
    }

    function setNotificationsPreviews(value: string): void {
        change("notifications.previews", ["always", "unlocked", "never"].indexOf(value) >= 0 ? value : "unlocked");
    }

    // The capture toolbar's mode and options (capture.*): a value outside the schema's list is refused, the key left as it is.
    function setCaptureOption(key: string, value: var): void {
        const path = "capture." + key;
        if (SettingsContract.RULES[path] === undefined || SettingsContract.validate(path, value) !== "")
            return;
        change(path, value);
    }

    // Keys the shell changed since its last write: dotted path -> value. Only these are merged into
    // the file, so edits made elsewhere (Settings app, by hand) survive.
    property var dirty: ({})

    // Setter helper: update the in-memory document and remember the key for the next merge.
    function change(path: string, value: var): void {
        setParsed(path, value);
        const d = dirty;
        d[path] = value;
        dirty = d;
        save();
    }

    // A reload from disk replaces the document; put pending local changes back on top.
    function reapplyDirty(): void {
        for (const path in dirty)
            setParsed(path, dirty[path]);
    }

    // Merge the dirty keys into the file as it is on disk right now (fresh read, bounded) and write the
    // result atomically. Keys the shell does not know are kept as they are. A file that is
    // missing or empty is created from the schema defaults. A malformed, oversized or non-regular file is never written.
    function writeMerged(): void {
        if (writeBlocked)
            return;
        // A read or a write of the previous change is still running: this one follows when it ends (saveTimer).
        if (diskRead.running || writer.running) {
            saveTimer.restart();
            return;
        }
        diskRead.command = ["sh", "-c", root.readScript, "sh", root.filePath, String(root.maxFileBytes)];
        diskRead.running = true;
    }

    // The whole document as the shell has it: the defaults with the file's own values over them (tests and diagnostics; the
    // views read single keys through read()).
    function document(): var {
        const merged = defaultDocument();
        const overlay = (base, over) => {
            for (const key in over) {
                if (base[key] !== null && typeof base[key] === "object" && !Array.isArray(base[key]) && over[key] !== null && typeof over[key] === "object" && !Array.isArray(over[key]))
                    overlay(base[key], over[key]);
                else
                    base[key] = over[key];
            }
        };
        void root.parsedFileRevision;
        overlay(merged, root.parsedFile);
        return merged;
    }

    // The document of a fresh file: every key of the schema (nested) at its default, the contract version first.
    function defaultDocument(): var {
        const doc = {version: SettingsContract.VERSION};
        for (const path in SettingsContract.ALL_DEFAULTS) {
            const parts = path.split(".");
            let node = doc;
            for (let i = 0; i < parts.length - 1; i++) {
                if (node[parts[i]] === undefined)
                    node[parts[i]] = {};
                node = node[parts[i]];
            }
            node[parts[parts.length - 1]] = JSON.parse(JSON.stringify(SettingsContract.ALL_DEFAULTS[path]));
        }
        return doc;
    }

    // Second half of writeMerged(), once the fresh read is in (its output: a status line, a signature line, the text).
    function mergeInto(output: string): void {
        if (writeBlocked)
            return;
        const read = root.splitRead(output);
        if (read.status !== "ok" && read.status !== "missing") {
            // Not a regular file, too large or unreadable: nothing is written, the change stays pending.
            root.takeBadFile(root.badReason(read.status));
            return;
        }
        const text = read.status === "missing" ? "" : read.text;
        let obj = null;
        if (text.trim() === "") {
            // A missing or empty file: a fresh one holding every key at its default, built from the schema defaults.
            obj = defaultDocument();
        } else {
            try {
                obj = JSON.parse(text);
            } catch (e) {
                obj = null;
            }
            if (obj === null || typeof obj !== "object" || Array.isArray(obj)) {
                checkText(text);
                takeDocument(text);
                return;
            }
            if (JsonSafety.unsafeReason(text) !== "") {
                checkText(text);
                return;
            }
        }
        for (const path in dirty) {
            const parts = path.split(".");
            let target = obj;
            for (let i = 0; i < parts.length - 1; i++) {
                if (target[parts[i]] === null || typeof target[parts[i]] !== "object" || Array.isArray(target[parts[i]]))
                    target[parts[i]] = {};
                target = target[parts[i]];
            }
            target[parts[parts.length - 1]] = dirty[path];
        }
        // The changes being written leave `dirty`; a failed write puts them back (see writer).
        root.inFlight = dirty;
        dirty = ({});
        writer.text = JSON.stringify(obj, null, 2) + "\n";
        writer.command = ["sh", "-c", root.writeScript, "sh", root.filePath];
        writer.stdinEnabled = true; // closed after the previous text: open it again
        writer.running = true;
    }

    // The two bounded reads. Output: the status (ok, missing, bad, unreadable, incomplete), the signature of the file (device, inode,
    // size, mtime of what the path leads to), then the text. A file that is not a regular file is not opened (a FIFO would
    // block, a device such as /dev/zero would never end); `stat -L` and `-f` follow a symlink to its target. At most $2 bytes
    // are read, a read that does not end in 5 s is cut, and the status is "ok" ONLY when the read ended without error and
    // returned exactly the size the file had: a read that was cut, failed, or met a file that changed under it is
    // "incomplete" (it would otherwise look like an empty file, whose defaults a write would put over the user's settings).
    // A read that returned another size than the stat said is tried once more (an atomic replacement between the two); a cut or failed read is not.
    // The text is held in a shell variable (at most maxFileBytes): no temporary file, so a full or unwritable $TMPDIR cannot make every read fail.
    readonly property string readScript: 'f=$1; max=$2\n'
        + 'if [ ! -e "$f" ]; then echo missing; exit 0; fi\n'
        + 'if [ ! -f "$f" ]; then echo bad; exit 0; fi\n'
        + 'for attempt in 1 2; do\n'
        + '  size=$(stat -L -c %s -- "$f" 2>/dev/null) || { echo bad; exit 0; }\n'
        + '  if [ "$size" -gt "$max" ]; then echo bad; exit 0; fi\n'
        + '  if [ ! -r "$f" ]; then echo unreadable; exit 0; fi\n'
        + '  sig=$(stat -L -c "%d:%i:%s:%y" -- "$f" 2>/dev/null) || sig=-\n'
        + '  out=$(timeout 5 head -c "$max" -- "$f" 2>/dev/null; printf "X%s" "$?")\n'
        + '  rc=${out##*X}; data=${out%X*}\n'
        + '  if [ "$rc" -ne 0 ]; then echo incomplete; exit 0; fi\n'
        + '  n=$(printf "%s" "$data" | wc -c)\n'
        + '  if [ "$n" -eq "$size" ]; then\n'
        + '    echo ok; echo "$sig"; printf "%s" "$data"; exit 0\n'
        + '  fi\n'
        + 'done\n'
        + 'echo incomplete\n'
        + 'exit 0\n'
    readonly property string signatureScript: 'stat -L -c "%d:%i:%s:%y" -- "$1" 2>/dev/null || echo -\n'

    // The atomic write: stdin to a temporary file next to the target, synced, renamed over it. A symlinked grassfield.json is
    // followed to its target (the link is kept, the file it names is replaced). The mode of the file that is replaced is kept (a
    // new file gets 0666 minus the umask). `mv -T` refuses a target that became a directory. Exit 1 when anything fails; nothing
    // is half written, and a crash after the rename leaves the synced file, never an empty one.
    readonly property string writeScript: 'f=$(realpath -m -- "$1") || exit 1\n'
        + 'd=$(dirname -- "$f")\n'
        + 't=$(mktemp -- "$d/.grassfield.json.XXXXXX") || exit 1\n'
        + 'm=$(stat -c %a -- "$f" 2>/dev/null) || m=$(printf "%03o" $((0666 & ~0$(umask))))\n'
        + 'if chmod "$m" "$t" && cat > "$t" && sync -- "$t" && mv -fT -- "$t" "$f"; then exit 0; fi\n'
        + 'rm -f -- "$t"\n'
        + 'exit 1\n'

    // The status, the signature and the text of a bounded read's output.
    function splitRead(output: string): var {
        const first = output.indexOf("\n");
        const status = first < 0 ? output.trim() : output.slice(0, first);
        if (status !== "ok")
            return {status: status, signature: "", text: ""};
        const rest = output.slice(first + 1);
        const second = rest.indexOf("\n");
        return {status: status, signature: second < 0 ? rest : rest.slice(0, second), text: second < 0 ? "" : rest.slice(second + 1)};
    }

    readonly property string filePath: root.configDir === "" ? "" : root.configDir + "/grassfield.json"

    // The change being written (restored to `dirty` when the write fails) and how many writes failed in a row.
    property var inFlight: ({})
    property int writeFailures: 0

    // Reads the file again now (a test, or a watch that is known to have missed something).
    function reload(): void {
        root.readFile();
    }

    // Reads the file now (bounded) and takes it as the document. One read at a time; a request while one runs follows it.
    property bool rereadPending: false
    function readFile(): void {
        if (root.filePath === "")
            return;
        if (loader.running) {
            root.rereadPending = true;
            return;
        }
        loader.command = ["sh", "-c", root.readScript, "sh", root.filePath, String(root.maxFileBytes)];
        // The signature the poll saw just before this read (empty for a read the poll did not start): a file found unusable is
        // remembered at that signature, so a change after it cannot be missed.
        loader.startSignature = root.probedSignature;
        root.probedSignature = "";
        root.fullReads++;
        loader.running = true;
    }

    property string lastSignature: ""
    // The unusable file's state (lastSignature is "!" then): the signature it was found at ("" if unknown), how many times in a row
    // it was read again at that same signature (the backoff level), and the polls since its last read.
    property string badSignature: ""
    property int badLevel: 0
    property int badTicks: 0
    property string probedSignature: ""

    // The polls to let pass before the next full read of an unusable file whose signature did not change: 1, 2, 4, ... up to badRetryCap.
    function badWaitTicks(): int {
        const cap = Math.max(1, Math.floor(root.badRetryCap / Math.max(1, root.pollInterval)));
        return Math.min(cap, Math.pow(2, Math.min(root.badLevel, 30)));
    }

    // A poll's signature of the path: true when the file is to be read in full now. A usable file: when its signature changed. An
    // unusable one: also then (or when it was never known), else only once the backoff has run out.
    function pollWantsRead(now: string): bool {
        if (root.lastSignature !== "!")
            return now !== root.lastSignature;
        if (root.badSignature === "" || now !== root.badSignature)
            return true;
        return ++root.badTicks >= root.badWaitTicks();
    }

    function badReason(status: string): string {
        switch (status) {
        case "unreadable":
            return "not readable";
        case "incomplete":
            return "not read completely (cut after 5 s, a read error, or changed while it was read)";
        }
        return "not a regular file or larger than " + root.maxFileBytes + " bytes";
    }

    function applyRead(output: string): void {
        const read = root.splitRead(output);
        if (read.status === "missing") {
            root.lastSignature = "-";
            root.takeMissingFile();
            // A fresh account has no file: that is a read too, and the defaults are final (the Dock and the desktop wait for it).
            // `loaded` flips after the values are in: its readers run at once, on the document, not on the defaults.
            root.loaded = true;
        } else if (read.status === "ok") {
            root.lastSignature = read.signature;
            root.checkText(read.text);
            root.takeDocument(read.text);
            root.reapplyDirty();
            root.loaded = true;
            // A change that waited because the file could not be read (it is readable now) is written now.
            if (Object.keys(root.dirty).length > 0)
                root.save();
            root.loadedFile();
        } else {
            // Found at the very signature it was already found unusable at: the backoff grows; any other case starts it over.
            const same = root.lastSignature === "!" && loader.startSignature !== "" && loader.startSignature === root.badSignature;
            const level = same ? root.badLevel + 1 : 0;
            root.takeBadFile(root.badReason(read.status));
            root.loaded = true;
            root.badSignature = loader.startSignature;
            root.badLevel = level;
        }
        root.armWatch();
    }

    // The file watch is set again on the path after every read: a watch follows the file it was set on, not the path.
    // The first read starts at once (a missing file is a read like any other), and again for a folder that is set later.
    property bool started: false
    onFilePathChanged: {
        if (root.started)
            root.readFile();
    }
    Component.onCompleted: {
        root.started = true;
        root.readFile();
    }

    property string watchPath: ""
    function armWatch(): void {
        const want = watchedDir.ready ? root.filePath : "";
        root.watchPath = "";
        root.watchPath = want;
    }

    function save(): void {
        if (!writeBlocked)
            saveTimer.restart();
    }

    // Write now (tests, shutdown).
    function flush(): void {
        saveTimer.stop();
        if (!writeBlocked)
            mkdir.running = true;
    }

    // Called with the file contents after each load: a malformed file blocks all writes.
    function checkText(text: string): void {
        let ok = true;
        // An empty file is a fresh one, not a damaged one.
        try {
            const parsed = text.trim() === "" ? {} : JSON.parse(text);
            ok = parsed !== null && typeof parsed === "object" && !Array.isArray(parsed);
        } catch (e) {
            ok = false;
        }
        let why = "is not valid JSON";
        let unsafeNow = false;
        if (ok) {
            const unsafe = JsonSafety.unsafeReason(text);
            if (unsafe !== "") {
                ok = false;
                unsafeNow = true;
                why = "cannot be rewritten safely: " + unsafe;
            }
        }
        unsafeFile = unsafeNow;
        if (!ok && !writeBlocked)
            console.warn("settings: " + root.filePath + " " + why + "; keeping the file untouched, changes will not be saved until it is fixed");
        writeBlocked = !ok;
        validRead = ok;
        emptyFile = text.trim() === "";
        if (!ok)
            saveTimer.stop();
    }

    Timer {
        id: saveTimer
        interval: root.saveDelay
        onTriggered: {
            if (!root.writeBlocked)
                mkdir.running = true;
        }
    }

    // The config directory may not exist yet.
    Process {
        id: mkdir
        command: ["mkdir", "-p", root.configDir]
        onRunningChanged: {
            if (!running && !root.writeBlocked)
                root.writeMerged();
        }
    }

    // The bounded read for the merge before a write.
    Process {
        id: diskRead
        environment: root.toolEnvironment
        stdout: StdioCollector {
            onStreamFinished: root.mergeInto(text)
        }
    }

    // The atomic write; its text comes in on stdin (no size limit of an argument). A failed write puts its changes back.
    Process {
        id: writer
        property string text: ""
        stdinEnabled: true
        onStarted: {
            writer.write(writer.text);
            writer.stdinEnabled = false;
        }
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            if (exitCode === 0) {
                root.writeFailures = 0;
                root.inFlight = ({});
                root.saved();
                // The watch also reports it; the file is read again so the document is what is on disk.
                root.readFile();
                return;
            }
            // Keep every change that was in flight (unless a newer value of the same key was set meanwhile) and try again.
            const d = root.dirty;
            for (const path in root.inFlight) {
                if (!(path in d))
                    d[path] = root.inFlight[path];
            }
            root.dirty = d;
            root.inFlight = ({});
            root.writeFailures++;
            if (root.writeFailures === 1)
                console.warn("settings: " + root.filePath + " could not be written; the change stays pending and is retried");
            retryTimer.interval = Math.min(60000, 2000 * Math.pow(2, Math.min(root.writeFailures - 1, 5)));
            retryTimer.restart();
        }
    }

    // A failed write is retried with a growing pause (2 s, 4 s, ... 60 s) while changes are pending.
    Timer {
        id: retryTimer
        onTriggered: {
            if (!root.writeBlocked && Object.keys(root.dirty).length > 0)
                mkdir.running = true;
        }
    }

    // The bounded load of the file.
    Process {
        id: loader
        environment: root.toolEnvironment
        property string startSignature: ""
        stdout: StdioCollector {
            onStreamFinished: root.applyRead(text)
        }
        onRunningChanged: {
            if (!running && root.rereadPending) {
                root.rereadPending = false;
                root.readFile();
            }
        }
    }

    // The signature of the path now; a change since the last read is read again (see pollInterval).
    Process {
        id: probe
        stdout: StdioCollector {
            onStreamFinished: {
                const now = text.trim();
                // "-" is a path that leads to nothing (read as missing); "!" is the sentinel of a file that could not be used.
                if (root.pollWantsRead(now)) {
                    root.probedSignature = now;
                    root.readFile();
                }
            }
        }
    }

    Timer {
        interval: root.pollInterval
        repeat: true
        running: watchedDir.ready && root.filePath !== ""
        onTriggered: {
            if (!probe.running && !loader.running && !diskRead.running && !writer.running) {
                probe.command = ["sh", "-c", root.signatureScript, "sh", root.filePath];
                probe.running = true;
            }
        }
    }

    // The directory is created first and the FileView gets its path only afterwards: a FileView cannot watch inside a
    // directory that does not exist yet (see WatchedDir), so on a fresh account no Settings change would apply.
    WatchedDir {
        id: watchedDir
        path: root.configDir
        // The folder matters for the watch and for writing only: the first read does not wait for its mkdir (Component.onCompleted
        // below), so `loaded` flips as soon as the bounded read ends. The watch, set now, reports a file created later.
        onReadyChanged: {
            if (ready)
                root.armWatch();
        }
    }

    // Only the watch: it reports a change, the bounded read above takes it. Nothing is loaded by it (preload off) and nothing
    // is written through it.
    FileView {
        id: file
        path: root.watchPath
        preload: false
        watchChanges: true
        printErrors: false
        onFileChanged: root.readFile()
    }
}
