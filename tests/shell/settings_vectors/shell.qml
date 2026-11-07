pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.store

// The shell's own reader against the shared settings vectors (tests/fixtures/settings-vectors.json, the contract of
// ui/Grassfield/Ui/SettingsContract.js): the real SettingsStore reads every vector the way the contract does, so that the
// shell and the Settings app can never show two values for one stored value (the pointer size did, GF-084 C2 review; an
// idle lock of false or "0" read 0 = never, C3 review). A vector whose key has no reader here FAILS (nothing is skipped
// silently), and so does a contract key without one. A vector marked "shell" is a known difference: it must still differ
// (a mark never goes stale); none is left since slice C3. One more case reads a file without any key: every contract key
// is its default. Offscreen (scripts/dev/test.sh: `qs -p tests/shell/settings_vectors`). Prints "settings-vectors: PASS ...".
ShellRoot {
    id: root

    readonly property string base: (Quickshell.env("GRASSFIELD_TEST_TMP") || "/tmp") + "/gf-vectors-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)

    // The contract key -> the SettingsStore property that reads it (a dotted name goes into the wallpaper object).
    readonly property var readers: ({
            "appearance": "appearance",
            "material.transparency": "transparency",
            "material.profile": "materialProfile",
            "accessibility.reduceTransparency": "reduceTransparency",
            "accessibility.reduceMotion": "reduceMotion",
            "accessibility.increaseContrast": "increaseContrast",
            "accessibility.textSize": "textSize",
            "accessibility.zoom": "zoomOn",
            "accessibility.zoomLevel": "zoomLevel",
            "dock.size": "dockSize",
            "dock.position": "dockPosition",
            "dock.magnification": "dockMagnification",
            "dock.magnificationEnabled": "dockMagnificationEnabled",
            "dock.autohide": "dockAutohide",
            "dock.showRecents": "dockShowRecents",
            "dock.folders": "dockFolders",
            "dock.minimizeIntoApp": "dockMinimizeIntoApp",
            "dock.clickMinimizes": "dockClickMinimizes",
            "dock.animateOpening": "dockAnimateOpening",
            "dock.showIndicators": "dockShowIndicators",
            "dock.endTask": "dockEndTask",
            "dock.minimizeEffect": "dockMinimizeEffect",
            "desktop.showIcons": "desktopShowIcons",
            "menubar.showBackground": "menubarShowBackground",
            "menubar.autoHide": "menubarAutoHide",
            "menubar.showNowPlaying": "menubarShowNowPlaying",
            "menubar.showSearch": "menubarShowSearch",
            "menubar.showWifi": "menubarShowWifi",
            "menubar.showSound": "menubarShowSound",
            "menubar.showBattery": "menubarShowBattery",
            "menubar.showBatteryPercentage": "menubarShowBatteryPercentage",
            "menubar.showFocus": "menubarShowFocus",
            "menubar.clockDate": "menubarClockDate",
            "menubar.clockShowAmPm": "menubarClockShowAmPm",
            "menubar.clockFlashSeparators": "menubarClockFlashSeparators",
            "menubar.showTrayItems": "menubarShowTrayItems",
            "menubar.recentItems": "menubarRecentItems",
            "menubar.clockShowDayOfWeek": "menubarClockShowDayOfWeek",
            "menubar.clockHours": "menubarClockHours",
            "menubar.clockShowSeconds": "menubarClockShowSeconds",
            "windows.titlebarDoubleClick": "titlebarDoubleClick",
            "windows.tilingEdges": "windowsTilingEdges",
            "windows.tilingMenuBar": "windowsTilingMenuBar",
            "windows.tilingOptionDrag": "windowsTilingOptionDrag",
            "windows.tilingMargins": "windowsTilingMargins",
            "windows.tilingLayouts": "windowsTilingLayouts",
            "windows.tilingSuggestions": "windowsTilingSuggestions",
            "windows.tilingGroups": "windowsTilingGroups",
            "windows.stages": "windowsStages",
            "windows.rebuildExtension": "windowsRebuildExtension",
            "notifications.dnd": "notificationsDnd",
            "notifications.previews": "notificationsPreviews",
            "notifications.appPreviews": "notificationsAppPreviews",
            "notifications.appStyles": "notificationsAppStyles",
            "notifications.history": "notificationsHistory",
            "lock.idleMinutes": "lockIdleMinutes",
            "lock.displayOffBattery": "lockDisplayOffBattery",
            "lock.displayOffPower": "lockDisplayOffPower",
            "lock.showUser": "lockShowUser",
            "lock.showMessage": "lockShowMessage",
            "lock.message": "lockMessage",
            "lock.requirePasswordAfterDisplayOff": "lockRequirePasswordAfterDisplayOff",
            "energy.preventSleep": "energyPreventSleep",
            "search.showApps": "searchShowApps",
            "search.showDocuments": "searchShowDocuments",
            "search.showRecents": "searchShowRecents",
            "search.showCalculator": "searchShowCalculator",
            "search.showConversions": "searchShowConversions",
            "search.showSettings": "searchShowSettings",
            "search.showCommands": "searchShowCommands",
            "search.historyResetAt": "searchHistoryResetAt",
            "screensaver.idleMinutes": "screenSaverIdleMinutes",
            "screensaver.kind": "screenSaverKind",
            "screensaver.folder": "screenSaverFolder",
            "capture.mode": "captureMode",
            "capture.saveTo": "captureSaveTo",
            "capture.timer": "captureTimer",
            "capture.microphone": "captureMicrophone",
            "capture.showPointer": "captureShowPointer",
            "capture.lastSelection": "captureLastSelection",
            "hotCorners.topLeft": "hotCornerTopLeft",
            "hotCorners.topRight": "hotCornerTopRight",
            "hotCorners.bottomLeft": "hotCornerBottomLeft",
            "hotCorners.bottomRight": "hotCornerBottomRight",
            "accent.color": "accentColor",
            "accent.highlight": "accentHighlight",
            "terminal.matchAppearance": "terminalMatchAppearance",
            "terminal.lightTheme": "terminalLightTheme",
            "terminal.darkTheme": "terminalDarkTheme",
            "keyboard.shortcutStyle": "keyboardShortcutStyle",
            "keyboard.showInputMenu": "keyboardShowInputMenu",
            "keyboard.dictation": "keyboardDictation",
            "displays.main": "displaysMain",
            "region.formats": "regionFormats",
            "region.firstDayOfWeek": "regionFirstDayOfWeek",
            "icons.mode": "iconMode",
            "icons.tint": "iconTint",
            "icons.folderColor": "folderColor",
            "pointer.size": "pointerSize",
            "pointer.outlineColor": "pointerOutlineColor",
            "pointer.fillColor": "pointerFillColor",
            "search.clipboard.enabled": "clipboardEnabled",
            "search.clipboard.retention": "clipboardRetention",
            "search.clipboard.keepOnDisk": "clipboardKeepOnDisk",
            "search.clipboard.clearedAt": "clipboardClearedAt",
            "search.clipboard.pinnedClearedAt": "clipboardPinnedClearedAt",
            "updates.automaticCheck": "updatesAutomaticCheck",
            "energy.slowHiddenApps": "energySlowHiddenApps",
            "sound.alert": "soundAlert",
            "sound.alertVolume": "soundAlertVolume",
            "sound.effectsOutput": "soundEffectsOutput",
            "sound.uiEffects": "soundUiEffects",
            "sound.volumeFeedback": "soundVolumeFeedback",
            "wallpaper.source": "wallpaper.source",
            "wallpaper.path": "wallpaper.path",
            "wallpaper.color": "wallpaper.color",
            "wallpaper.fit": "wallpaper.fit",
            "wallpaper.interval": "wallpaper.interval",
            "wallpaper.shuffle": "wallpaper.shuffle",
            "wallpaper.videoOnBattery": "wallpaper.videoOnBattery",
            "wallpaper.online.provider": "wallpaper.online.provider",
            "wallpaper.artwork": "wallpaper.artwork",
            "wallpaper.artworkVariant": "wallpaper.artworkVariant",
            "wallpaper.moving": "wallpaper.moving",
            "wallpaper.outputs": "wallpaper.outputs"
        })

    property var cases: []
    property var failures: []
    property int loaded: 0
    property int knownDifferences: 0

    FileView {
        id: fixture
        path: Quickshell.shellPath("../../fixtures/settings-vectors.json")
        blockLoading: true
    }

    function dataFor(v): string {
        if (v.raw !== undefined)
            return v.raw;
        if (v.absent === true || v.allAbsent === true)
            return '{"version":1}';
        const parts = v.path.split(".");
        const doc = {version: 1};
        let node = doc;
        for (let i = 0; i < parts.length - 1; i++) {
            node[parts[i]] = {};
            node = node[parts[i]];
        }
        node[parts[parts.length - 1]] = v.stored;
        return JSON.stringify(doc);
    }

    function dir(i: int): string {
        return base + "/c" + i;
    }

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    // Contract keys the shell's SettingsStore does not read at all: an app reads them (apps/store/qml/Main.qml,
    // SettingsWindow.qml; apps/preview/src/previewapp.cpp readAppearance), with its own tests. They are the only keys exempt
    // from "has a reader here" and from the every-key-is-its-default check; a key listed here that this test also reads is a
    // failure (the list never goes stale).
    readonly property var appOnly: ({
            "store.sources.aur": "apps/store",
            "store.sources.flathub": "apps/store",
            "store.screenshots": "apps/store",
            "preview.textInImages": "apps/preview"
        })

    function readerValue(store: var, path: string): var {
        if (root.readers[path] === undefined)
            return undefined; // reported by the contract-key check; never a throw (it left the case unread and ended in a timeout)
        let got = store;
        for (const part of root.readers[path].split("."))
            got = got[part];
        return got;
    }

    Component.onCompleted: {
        const all = JSON.parse(fixture.text()).vectors;
        // Nothing is skipped: a key without a reader is a failure, and so is a contract key the shell does not read.
        for (const v of all)
            root.check(v.name + ": no reader for " + v.path + " in this test", root.readers[v.path] !== undefined);
        for (const path in SettingsContract.RULES) {
            if (root.appOnly[path] !== undefined)
                root.check("contract key " + path + " is listed as read by " + root.appOnly[path] + " but this test reads it too", root.readers[path] === undefined);
            else
                root.check("contract key " + path + " has no reader in this test", root.readers[path] !== undefined);
        }
        const picked = all.filter(v => root.readers[v.path] !== undefined);
        picked.push({name: "a file without any key", allAbsent: true});
        // Files whose values the contract cannot use at all: every key reads its default, and the store still finishes its
        // load (a null group once threw in resetMissingKeys and skipped the rest).
        picked.push({name: "wallpaper.online is null", allAbsent: true, raw: '{"version":1,"wallpaper":{"online":null}}'});
        picked.push({name: "groups that are not objects", allAbsent: true,
                        raw: '{"version":1,"wallpaper":null,"dock":5,"notifications":"x","lock":[],"pointer":true,"menubar":null,"hotCorners":7}'});
        // A file Settings refuses to edit (a duplicate key, an integer beyond 2^53) shows the defaults there: so does the
        // shell, whatever its other keys say (lock.idleMinutes 0 would be "never").
        picked.push({name: "an unsafe file with a duplicate key", allAbsent: true,
                        raw: '{"version":1,"lock":{"idleMinutes":0},"dock":{"size":80},"material":{"transparency":0.5},"menubar":{"showWifi":false},"x":1,"x":2}'});
        picked.push({name: "an unsafe file with an integer beyond 2^53", allAbsent: true,
                        raw: '{"version":1,"lock":{"idleMinutes":0},"dock":{"size":80},"wallpaper":{"source":"color"},"n":9007199254740993}'});
        cases = picked;
        setup.running = true;
    }

    Process {
        id: setup
        command: {
            const args = ['for t in "$@"; do mkdir -p "$B/c$i" && printf "%s" "$t" > "$B/c$i/grassfield.json"; i=$((i+1)); done'];
            return ["env", "B=" + root.base, "i=0", "sh", "-c", args[0], "sh"].concat(root.cases.map(v => root.dataFor(v)));
        }
        onRunningChanged: {
            if (!running)
                repeater.model = root.cases.length;
        }
    }

    Instantiator {
        id: repeater
        model: 0

        delegate: QtObject {
            id: item
            required property int index
            property var store: SettingsStore {
                saveDelay: 10
                configDir: root.dir(item.index)
                onLoadedFile: {
                    const v = root.cases[item.index];
                    if (v.allAbsent === true) {
                        for (const path in SettingsContract.RULES) {
                            if (root.appOnly[path] !== undefined)
                                continue;
                            const got = root.readerValue(this, path);
                            root.check(v.name + ": " + path + " is " + JSON.stringify(got) + ", the default is " + JSON.stringify(SettingsContract.DEFAULTS[path]), JSON.stringify(got) === JSON.stringify(SettingsContract.DEFAULTS[path]));
                        }
                    } else {
                        const want = v.default === true ? SettingsContract.DEFAULTS[v.path] : v.read;
                        const got = root.readerValue(this, v.path);
                        const same = JSON.stringify(got) === JSON.stringify(want);
                        if (v.shell !== undefined) {
                            // A known difference: it must still be one.
                            root.knownDifferences++;
                            root.check(v.name + " (" + v.path + "): marked " + v.shell + " but the shell now reads the contract's " + JSON.stringify(want) + "; remove the mark", !same);
                        } else {
                            root.check(v.name + " (" + v.path + "): shell " + JSON.stringify(got) + ", contract " + JSON.stringify(want), same);
                        }
                    }
                    root.loaded++;
                    if (root.loaded === root.cases.length)
                        cleanup.running = true;
                }
            }
        }
    }

    Process {
        id: cleanup
        command: ["rm", "-rf", root.base]
        onRunningChanged: {
            if (running)
                return;
            if (root.failures.length === 0) {
                console.log("settings-vectors: PASS (" + root.loaded + " documents read by the shell, " + root.knownDifferences + " known differences)");
                Qt.exit(0);
            } else {
                console.log("settings-vectors: FAIL " + root.failures.join("; "));
                Qt.exit(1);
            }
        }
    }

    Timer {
        interval: 40000
        running: true
        onTriggered: {
            console.log("settings-vectors: FAIL timeout, loaded " + root.loaded + " of " + root.cases.length);
            Qt.exit(1);
        }
    }
}
