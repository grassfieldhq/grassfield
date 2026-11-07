pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.services

// End to end, with the REAL unit environment (packaging/systemd/grassfield-shell.service: QS_DISABLE_FILE_WATCHER=1,
// QS_NO_RELOAD_POPUP=1, GRASSFIELD_SESSION=1, no GRASSFIELD_DEV, no GRASSFIELD_CONFIG_HOME) and a FRESH account: the
// config directory ($XDG_CONFIG_HOME/grassfield) does not exist when the shell starts. Every key documented in
// docs/specs/ui.md and docs/specs/settings.md is written the way grassfield-settings writes it (create the directory,
// write a full new file next to it, rename it over grassfield.json: QSaveFile, merging the keys already there) and the
// real Settings singleton must show the new value within the budget. Printed: "settings-apply: PASS" or the failures.
ShellRoot {
    id: root

    // "about 1 s" in the brief; the margin absorbs a loaded test machine, the sequence is still checked per key.
    readonly property int budgetMs: 1500
    readonly property string dir: Quickshell.env("XDG_CONFIG_HOME") + "/grassfield"

    // [dotted key, new value, check on the Settings singleton]. The first write also creates the file.
    readonly property var steps: [
        ["appearance", "light", () => Settings.appearance === "light" && Settings.dark === false],
        ["material.transparency", 0.6, () => Math.abs(Settings.transparency - 0.6) < 1e-9],
        ["material.profile", "full", () => Settings.materialProfile === "full"],
        ["accessibility.reduceTransparency", true, () => Settings.reduceTransparency === true],
        ["accessibility.reduceMotion", true, () => Settings.reduceMotion === true],
        ["dock.pinned", ["a", "b"], () => Settings.dockPinned.join(",") === "a,b"],
        ["dock.size", 72, () => Settings.dockSize === 72],
        ["dock.size", 500, () => Settings.dockSize === 96],
        ["dock.size", "big", () => Settings.dockSize === 48],
        ["dock.position", "left", () => Settings.dockPosition === "left"],
        ["dock.position", "right", () => Settings.dockPosition === "right"],
        ["dock.position", "top", () => Settings.dockPosition === "bottom"],
        ["dock.magnification", 2.0, () => Math.abs(Settings.dockMagnification - 2.0) < 1e-9],
        ["dock.magnificationEnabled", true, () => Settings.dockMagnificationEnabled === true],
        ["dock.autohide", true, () => Settings.dockAutohide === true],
        ["dock.recent", ["x", "y"], () => Settings.dockRecent.join(",") === "x,y"],
        ["dock.folders", ["~/Downloads", "/srv/x"], () => Settings.dockFolders.join(",") === "~/Downloads,/srv/x"],
        ["dock.stackOptions", {"/srv/x": {sort: "name", view: "list"}}, () => Settings.dockStackOptions["/srv/x"] && Settings.dockStackOptions["/srv/x"].view === "list"],
        ["dock.showRecents", false, () => Settings.dockShowRecents === false],
        ["dock.minimizeIntoApp", true, () => Settings.dockMinimizeIntoApp === true],
        ["dock.clickMinimizes", false, () => Settings.dockClickMinimizes === false],
        ["dock.animateOpening", false, () => Settings.dockAnimateOpening === false],
        ["dock.showIndicators", false, () => Settings.dockShowIndicators === false],
        ["dock.endTask", true, () => Settings.dockEndTask === true],
        ["dock.minimizeEffect", "shrink", () => Settings.dockMinimizeEffect === "shrink"],
        ["desktop.showIcons", false, () => Settings.desktopShowIcons === false],
        ["menubar.showBackground", true, () => Settings.menubarShowBackground === true],
        ["menubar.autoHide", "always", () => Settings.menubarAutoHide === "always"],
        ["menubar.autoHide", "bogus", () => Settings.menubarAutoHide === "fullscreen"],
        ["menubar.showNowPlaying", false, () => Settings.menubarShowNowPlaying === false],
        ["menubar.showSearch", false, () => Settings.menubarShowSearch === false],
        ["menubar.showWifi", false, () => Settings.menubarShowWifi === false],
        ["menubar.showSound", false, () => Settings.menubarShowSound === false],
        ["menubar.showBattery", false, () => Settings.menubarShowBattery === false],
        ["menubar.showBatteryPercentage", false, () => Settings.menubarShowBatteryPercentage === false],
        ["menubar.showFocus", false, () => Settings.menubarShowFocus === false],
        ["menubar.clockDate", "never", () => Settings.menubarClockDate === "never"],
        ["menubar.clockDate", "bogus", () => Settings.menubarClockDate === "auto"],
        ["menubar.clockShowAmPm", false, () => Settings.menubarClockShowAmPm === false],
        ["menubar.clockFlashSeparators", true, () => Settings.menubarClockFlashSeparators === true],
        ["menubar.showTrayItems", false, () => Settings.menubarShowTrayItems === false],
        ["menubar.recentItems", 5, () => Settings.menubarRecentItems === 5],
        ["menubar.recentItems", 99, () => Settings.menubarRecentItems === 50],
        ["menubar.clockShowDayOfWeek", false, () => Settings.menubarClockShowDayOfWeek === false],
        ["menubar.clockHours", "24", () => Settings.menubarClockHours === "24"],
        ["menubar.clockHours", "bogus", () => Settings.menubarClockHours === "auto"],
        ["menubar.clockShowSeconds", true, () => Settings.menubarClockShowSeconds === true],
        ["keyboard.shortcutStyle", "mac", () => Settings.keyboardShortcutStyle === "mac" && Appearance.shortcutStyle === "mac"],
        ["keyboard.shortcutStyle", "bogus", () => Settings.keyboardShortcutStyle === "automatic"],
        ["keyboard.showInputMenu", false, () => Settings.keyboardShowInputMenu === false],
        ["keyboard.dictation", true, () => Settings.keyboardDictation === true],
        ["region.formats", "fr_CH", () => Settings.regionFormats === "fr_CH"],
        ["region.formats", "fr_CH; rm", () => Settings.regionFormats === "auto"],
        ["region.firstDayOfWeek", "sunday", () => Settings.regionFirstDayOfWeek === "sunday"],
        ["region.firstDayOfWeek", "bogus", () => Settings.regionFirstDayOfWeek === "auto"],
        ["windows.titlebarDoubleClick", "minimize", () => Settings.titlebarDoubleClick === "minimize"],
        ["windows.titlebarDoubleClick", "fill", () => Settings.titlebarDoubleClick === "fill"],
        ["windows.tilingEdges", false, () => Settings.windowsTilingEdges === false],
        ["windows.tilingMenuBar", false, () => Settings.windowsTilingMenuBar === false],
        ["windows.tilingOptionDrag", false, () => Settings.windowsTilingOptionDrag === false],
        ["windows.tilingMargins", false, () => Settings.windowsTilingMargins === false],
        ["windows.tilingLayouts", false, () => Settings.windowsTilingLayouts === false],
        ["windows.tilingSuggestions", false, () => Settings.windowsTilingSuggestions === false],
        ["windows.tilingGroups", false, () => Settings.windowsTilingGroups === false],
        ["windows.stages", true, () => Settings.windowsStages === true],
        ["notifications.dnd", true, () => Settings.notificationsDnd === true],
        ["notifications.previews", "never", () => Settings.notificationsPreviews === "never"],
        ["lock.idleMinutes", 17, () => Settings.lockIdleMinutes === 17],
        ["lock.displayOffBattery", 3, () => Settings.lockDisplayOffBattery === 3],
        ["lock.displayOffPower", 0, () => Settings.lockDisplayOffPower === 0],
        ["lock.showUser", false, () => Settings.lockShowUser === false],
        ["energy.slowHiddenApps", false, () => Settings.energySlowHiddenApps === false],
        ["lock.showMessage", true, () => Settings.lockShowMessage === true],
        ["lock.message", "Back at 3", () => Settings.lockMessage === "Back at 3"],
        ["lock.message", "two\nlines", () => Settings.lockMessage === ""],
        ["energy.preventSleep", false, () => Settings.energyPreventSleep === false],
        ["search.showApps", false, () => Settings.searchShowApps === false],
        ["search.showDocuments", false, () => Settings.searchShowDocuments === false],
        ["search.showRecents", false, () => Settings.searchShowRecents === false],
        ["search.showCalculator", false, () => Settings.searchShowCalculator === false],
        ["search.showConversions", false, () => Settings.searchShowConversions === false],
        ["search.showSettings", false, () => Settings.searchShowSettings === false],
        ["search.showCommands", false, () => Settings.searchShowCommands === false],
        ["search.historyResetAt", 1792832460000, () => Settings.searchHistoryResetAt === 1792832460000],
        ["screensaver.idleMinutes", 10, () => Settings.screenSaverIdleMinutes === 10],
        ["screensaver.kind", "slideshow", () => Settings.screenSaverKind === "slideshow"],
        ["screensaver.folder", "/home/u/Photos", () => Settings.screenSaverFolder === "/home/u/Photos"],
        ["capture.mode", "recordScreen", () => Settings.captureMode === "recordScreen"],
        // Save to: the older key alone keeps its Documents and moves its Desktop (the old default) to the Screenshots folder; the
        // newer key wins once written, and an unknown place in it is the Screenshots folder.
        ["capture.saveTo", "desktop", () => Settings.captureLocation === "screenshots"],
        ["capture.saveTo", "documents", () => Settings.captureLocation === "documents"],
        ["capture.location", "desktop", () => Settings.captureLocation === "desktop"],
        ["capture.location", "mail", () => Settings.captureLocation === "screenshots"],
        ["capture.timer", "10", () => Settings.captureTimer === "10"],
        ["capture.timer", 10, () => Settings.captureTimer === "none"],
        ["capture.microphone", "default", () => Settings.captureMicrophone === "default"],
        ["capture.showPointer", true, () => Settings.captureShowPointer === true],
        ["capture.lastSelection", "DP-1=10,20,300,200", () => Settings.captureLastSelection === "DP-1=10,20,300,200"],
        ["capture.lastSelection", "DP-1=10,20,300,200;", () => Settings.captureLastSelection === ""],
        ["hotCorners.topLeft", "overview", () => Settings.hotCornerTopLeft === "overview"],
        ["hotCorners.topRight", "notifications", () => Settings.hotCornerTopRight === "notifications"],
        ["hotCorners.bottomLeft", "apps", () => Settings.hotCornerBottomLeft === "apps"],
        ["hotCorners.bottomRight", "lock", () => Settings.hotCornerBottomRight === "lock"],
        // Accent colour: the setting, then the colour Appearance resolves from it (bound as shell.qml binds it), live.
        ["accent.color", "purple", () => Settings.accentColor === "purple" && Appearance.colors.accent.toString().toLowerCase() === String(Tokens.colorAccentLight.purple).toLowerCase()],
        ["accent.color", "orange", () => Settings.accentColor === "orange" && Appearance.colors.accent.toString().toLowerCase() === String(Tokens.colorAccentLight.orange).toLowerCase() && Appearance.colors.accentText.toString().toLowerCase() === String(Tokens.colorAccentLight.orangeText).toLowerCase()],
        ["accent.color", "neon", () => Settings.accentColor === "multicolor" && Appearance.colors.accent.toString().toLowerCase() === String(Tokens.colorLight.accent).toLowerCase()],
        ["accent.color", "graphite", () => Settings.accentColor === "graphite" && Appearance.colors.accent.toString().toLowerCase() === String(Tokens.colorAccentLight.graphite).toLowerCase()],
        ["accent.highlight", "pink", () => Settings.accentHighlight === "pink" && Appearance.highlight.toString().toLowerCase() === String(Tokens.colorAccentLight.pink).toLowerCase()],
        ["accent.highlight", "neon", () => Settings.accentHighlight === "automatic" && Appearance.highlight.toString().toLowerCase() === String(Appearance.colors.accent).toLowerCase()],
        // Terminal and Developer Apps (ADR-0045 OC-11): the switch and the two Omarchy theme names; a name with a slash is refused.
        ["terminal.matchAppearance", true, () => Settings.terminalMatchAppearance === true],
        ["terminal.lightTheme", "Rose Pine", () => Settings.terminalLightTheme === "Rose Pine"],
        ["terminal.darkTheme", "../nord", () => Settings.terminalDarkTheme === "Tokyo Night"],
        ["icons.mode", "tinted", () => Settings.iconMode === "tinted"],
        ["icons.tint", "#8e5bea", () => Settings.iconTint === "#8e5bea"],
        ["icons.folderColor", "#8e5bea", () => Settings.folderColor === "#8e5bea"],
        ["pointer.size", 48, () => Settings.pointerSize === 48],
        ["pointer.outlineColor", "#ff0000", () => Settings.pointerOutlineColor === "#ff0000"],
        ["pointer.fillColor", "#00ff00", () => Settings.pointerFillColor === "#00ff00"]
    ]

    // As shell.qml: the settings drive Appearance (appearance is "light" from the first step on).
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

    Binding {
        target: Appearance
        property: "dark"
        value: Settings.dark
    }

    Binding {
        target: Appearance
        property: "shortcutStyle"
        value: MenuShortcut.style(Settings.keyboardShortcutStyle, SystemInfo.macDevice)
    }

    property var doc: ({
            "version": 1
        })
    property int index: -1
    property int waited: 0
    property var failures: []

    function setPath(obj: var, path: string, value: var): void {
        const parts = path.split(".");
        let t = obj;
        for (let i = 0; i < parts.length - 1; i++) {
            if (typeof t[parts[i]] !== "object" || t[parts[i]] === null)
                t[parts[i]] = {};
            t = t[parts[i]];
        }
        t[parts[parts.length - 1]] = value;
    }

    function fail(name: string): void {
        failures.push(name);
    }

    function finish(): void {
        if (failures.length === 0) {
            console.log("settings-apply: PASS (" + steps.length + " keys applied through the real unit environment)");
            Qt.exit(0);
        } else {
            console.log("settings-apply: FAIL " + failures.join(", "));
            Qt.exit(1);
        }
    }

    function next(): void {
        index++;
        if (index >= steps.length) {
            finish();
            return;
        }
        setPath(doc, steps[index][0], steps[index][1]);
        waited = 0;
        writer.command = ["sh", "-c", 'mkdir -p "$1" && printf "%s\\n" "$2" > "$1/grassfield.json.tmp" && mv "$1/grassfield.json.tmp" "$1/grassfield.json"', "sh", root.dir, JSON.stringify(doc, null, 2)];
        writer.running = true;
    }

    // The environment really is the unit's: a test that ran with the dev variables would prove nothing.
    Component.onCompleted: {
        if (Quickshell.env("QS_DISABLE_FILE_WATCHER") !== "1")
            fail("env: QS_DISABLE_FILE_WATCHER not set");
        if (Quickshell.env("GRASSFIELD_SESSION") !== "1")
            fail("env: GRASSFIELD_SESSION not set");
        if (Quickshell.env("GRASSFIELD_DEV") || Quickshell.env("GRASSFIELD_CONFIG_HOME"))
            fail("env: a dev variable is set");
        if (Settings.configDir !== root.dir)
            fail("path: Settings.configDir is " + Settings.configDir + ", the app writes " + root.dir);
        // Let the shell finish starting (as in a session, the Settings app is opened later).
        startTimer.start();
    }

    Timer {
        id: startTimer
        interval: 800
        onTriggered: root.next()
    }

    // Same sequence as apps/settings/src/backend.cpp writeText: mkpath, then a file next to the target renamed over it.
    Process {
        id: writer
        onRunningChanged: {
            if (!running)
                poll.start();
        }
    }

    Timer {
        id: poll
        interval: 50
        repeat: true
        onTriggered: {
            root.waited += interval;
            const s = root.steps[root.index];
            if (s[2]()) {
                stop();
                root.next();
            } else if (root.waited >= root.budgetMs) {
                stop();
                root.fail(s[0] + " not applied in " + root.budgetMs + " ms");
                // Later keys cannot be told apart from a dead watcher: stop here.
                root.finish();
            }
        }
    }

    Timer {
        interval: 120000
        running: true
        onTriggered: {
            root.fail("timeout");
            root.finish();
        }
    }
}
