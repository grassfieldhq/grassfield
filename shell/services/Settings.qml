pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import qs.lib
import Grassfield.Ui
import qs.store
import "../dock/Geometry.js" as DockGeometry // layering-exception: GF-087

// User configuration facade over SettingsStore (grassfield.json, contract version 1).
// Keys are documented in docs/specs/ui.md.
Singleton {
    id: root

    // GRASSFIELD_CONFIG_HOME wins; otherwise $XDG_CONFIG_HOME/grassfield.
    readonly property string configDir: Mode.configDir

    // Validated by the store (out-of-range or unknown values fall back to the schema defaults).
    readonly property string appearance: store.appearance
    // What the shell renders: "auto" follows the fixed local schedule (AutoAppearance.js, dark 19:00 to 07:00 by default),
    // re-evaluated each minute while it is selected (a timer of the minute, not a poll of any service).
    property date now: new Date()
    readonly property bool dark: AutoAppearance.isDark(store.appearance, now, Tokens.autoAppearanceDarkFromHour, Tokens.autoAppearanceDarkToHour)
    readonly property real transparency: store.transparency
    readonly property string materialProfile: store.materialProfile
    readonly property bool reduceTransparency: store.reduceTransparency
    readonly property bool reduceMotion: store.reduceMotion
    readonly property bool increaseContrast: store.increaseContrast
    readonly property real textSize: store.textSize
    readonly property bool zoomOn: store.zoomOn
    readonly property real zoomLevel: store.zoomLevel
    readonly property var dockPinned: store.dockPinned
    readonly property int dockSize: store.dockSize
    // Metrics of the Dock at the stored tile size (what the others reserve around it; the Dock itself follows a live resize).
    readonly property string dockPosition: store.dockPosition
    readonly property var dockMetrics: DockGeometry.metrics(dockSize, {
        iconSize: Tokens.dockIconSize,
        padding: Tokens.dockPadding,
        spacing: Tokens.dockSpacing,
        bottomMargin: Tokens.dockBottomMargin,
        separatorHeight: Tokens.dockSeparatorHeight,
        badgeSize: Tokens.dockBadgeSize,
        radiusIcon: Tokens.radiusDockIcon
    })
    // What the Dock keeps clear on its edge, whether or not it hides (the desktop icons, the widgets and the Apps panel stay put).
    readonly property var dockFootprint: DockGeometry.footprint(dockPosition, dockMetrics, false)
    readonly property real dockMagnification: store.dockMagnification
    readonly property bool dockMagnificationEnabled: store.dockMagnificationEnabled
    readonly property bool dockAutohide: store.dockAutohide
    readonly property bool clipboardEnabled: store.clipboardEnabled
    readonly property string clipboardRetention: store.clipboardRetention
    readonly property bool clipboardKeepOnDisk: store.clipboardKeepOnDisk
    readonly property real clipboardClearedAt: store.clipboardClearedAt
    readonly property real clipboardPinnedClearedAt: store.clipboardPinnedClearedAt
    readonly property bool updatesAutomaticCheck: store.updatesAutomaticCheck
    readonly property bool energySlowHiddenApps: store.energySlowHiddenApps
    readonly property string soundAlert: store.soundAlert
    readonly property real soundAlertVolume: store.soundAlertVolume
    readonly property string soundEffectsOutput: store.soundEffectsOutput
    readonly property bool soundUiEffects: store.soundUiEffects
    readonly property bool soundVolumeFeedback: store.soundVolumeFeedback
    readonly property var dockRecent: store.dockRecent
    readonly property var dockFolders: store.dockFolders
    readonly property var dockStackOptions: store.dockStackOptions
    readonly property bool dockShowRecents: store.dockShowRecents
    readonly property bool dockMinimizeIntoApp: store.dockMinimizeIntoApp
    readonly property bool dockClickMinimizes: store.dockClickMinimizes
    readonly property bool dockAnimateOpening: store.dockAnimateOpening
    readonly property bool dockShowIndicators: store.dockShowIndicators
    readonly property bool dockEndTask: store.dockEndTask
    readonly property string dockMinimizeEffect: store.dockMinimizeEffect

    readonly property string accentColor: store.accentColor
    readonly property string accentHighlight: store.accentHighlight
    // Terminal and Developer Apps (ADR-0045 OC-11): read by TerminalTheme.qml.
    readonly property bool terminalMatchAppearance: store.terminalMatchAppearance
    readonly property string terminalLightTheme: store.terminalLightTheme
    readonly property string terminalDarkTheme: store.terminalDarkTheme
    readonly property string keyboardShortcutStyle: store.keyboardShortcutStyle
    readonly property bool keyboardShowInputMenu: store.keyboardShowInputMenu
    readonly property string regionFormats: store.regionFormats
    readonly property string regionFirstDayOfWeek: store.regionFirstDayOfWeek
    readonly property string iconMode: store.iconMode
    readonly property string iconTint: store.iconTint
    readonly property string folderColor: store.folderColor

    // grassfield.json has been read at least once.
    readonly property bool loaded: store.loaded
    // ... and is valid (false while it is malformed): the pointer theme acts on defaults only then.
    readonly property bool validRead: store.validRead
    // ... and was empty (every key at its default): the clipboard history deletes nothing on it.
    readonly property bool emptyFile: store.emptyFile
    readonly property bool writeBlocked: store.writeBlocked
    readonly property int pointerSize: store.pointerSize
    readonly property string pointerOutlineColor: store.pointerOutlineColor
    readonly property string pointerFillColor: store.pointerFillColor

    // Wallpaper settings (ADR-0016), complete and valid; see ui/Grassfield/Ui/WallpaperConfig.js.
    readonly property var wallpaper: store.wallpaper

    readonly property bool notificationsDnd: store.notificationsDnd
    readonly property string notificationsPreviews: store.notificationsPreviews
    readonly property var notificationsAppPreviews: store.notificationsAppPreviews
    readonly property var notificationsAppStyles: store.notificationsAppStyles
    readonly property string notificationsHistory: store.notificationsHistory
    readonly property string titlebarDoubleClick: store.titlebarDoubleClick
    readonly property bool windowsTilingEdges: store.windowsTilingEdges
    readonly property bool windowsTilingMenuBar: store.windowsTilingMenuBar
    readonly property bool windowsTilingOptionDrag: store.windowsTilingOptionDrag
    readonly property bool windowsTilingMargins: store.windowsTilingMargins
    readonly property bool windowsTilingLayouts: store.windowsTilingLayouts
    readonly property bool windowsTilingSuggestions: store.windowsTilingSuggestions
    readonly property bool windowsTilingGroups: store.windowsTilingGroups
    readonly property bool windowsStages: store.windowsStages
    // Opt-in: the shell builds the compositor extension when none is made for the installed Hyprland (shell.qml).
    readonly property bool windowsRebuildExtension: store.windowsRebuildExtension
    readonly property int lockIdleMinutes: store.lockIdleMinutes
    readonly property int lockDisplayOffBattery: store.lockDisplayOffBattery
    readonly property string lockRequirePasswordAfterDisplayOff: store.lockRequirePasswordAfterDisplayOff
    readonly property int lockDisplayOffPower: store.lockDisplayOffPower
    readonly property bool lockShowUser: store.lockShowUser
    readonly property bool lockShowMessage: store.lockShowMessage
    readonly property string lockMessage: store.lockMessage
    readonly property bool energyPreventSleep: store.energyPreventSleep
    readonly property bool searchShowApps: store.searchShowApps
    readonly property bool searchShowDocuments: store.searchShowDocuments
    readonly property bool searchShowRecents: store.searchShowRecents
    readonly property bool searchShowCalculator: store.searchShowCalculator
    readonly property bool searchShowConversions: store.searchShowConversions
    readonly property bool searchShowSettings: store.searchShowSettings
    readonly property bool searchShowCommands: store.searchShowCommands
    readonly property real searchHistoryResetAt: store.searchHistoryResetAt
    readonly property int screenSaverIdleMinutes: store.screenSaverIdleMinutes
    readonly property string screenSaverKind: store.screenSaverKind
    readonly property string screenSaverFolder: store.screenSaverFolder
    // The capture toolbar's mode and Options menu (ADR-0045 OC-1); the toolbar writes them through setCaptureOption.
    readonly property string captureMode: store.captureMode
    // Save to: the Screenshots folder (Videos for a recording) unless another place was chosen (SettingsStore.captureLocation).
    readonly property string captureLocation: store.captureLocation
    readonly property string captureTimer: store.captureTimer
    readonly property string captureMicrophone: store.captureMicrophone
    readonly property bool captureShowPointer: store.captureShowPointer
    readonly property string captureLastSelection: store.captureLastSelection

    readonly property bool desktopShowIcons: store.desktopShowIcons
    // The remembered choices of the main display (ui/Grassfield/Ui/DisplayRole.js); services/MainDisplay.qml resolves them.
    readonly property var displaysMain: store.displaysMain
    readonly property bool menubarShowBackground: store.menubarShowBackground
    readonly property string menubarAutoHide: store.menubarAutoHide
    readonly property bool menubarShowNowPlaying: store.menubarShowNowPlaying
    readonly property bool menubarShowSearch: store.menubarShowSearch
    readonly property bool menubarShowWifi: store.menubarShowWifi
    readonly property bool menubarShowSound: store.menubarShowSound
    readonly property bool menubarShowBattery: store.menubarShowBattery
    readonly property bool menubarShowBatteryPercentage: store.menubarShowBatteryPercentage
    readonly property bool menubarShowFocus: store.menubarShowFocus
    readonly property bool menubarShowScreenCapture: store.menubarShowScreenCapture
    readonly property string menubarClockDate: store.menubarClockDate
    readonly property bool menubarClockShowAmPm: store.menubarClockShowAmPm
    readonly property bool menubarClockFlashSeparators: store.menubarClockFlashSeparators
    readonly property bool menubarShowTrayItems: store.menubarShowTrayItems
    readonly property int menubarRecentItems: store.menubarRecentItems
    readonly property bool menubarClockShowDayOfWeek: store.menubarClockShowDayOfWeek
    readonly property string menubarClockHours: store.menubarClockHours
    readonly property bool menubarClockShowSeconds: store.menubarClockShowSeconds
    readonly property string hotCornerTopLeft: store.hotCornerTopLeft
    readonly property string hotCornerTopRight: store.hotCornerTopRight
    readonly property string hotCornerBottomLeft: store.hotCornerBottomLeft
    readonly property string hotCornerBottomRight: store.hotCornerBottomRight

    function setHotCorner(corner: string, action: string): void {
        store.setHotCorner(corner, action);
    }

    function setStagesEnabled(value: bool): void {
        store.setStagesEnabled(value);
    }

    function setClipboardEnabled(value: bool): void {
        store.setClipboardEnabled(value);
    }

    function setDesktopShowIcons(value: bool): void {
        store.setDesktopShowIcons(value);
    }

    function setMenubarShowBackground(value: bool): void {
        store.setMenubarShowBackground(value);
    }

    function setMenubarAutoHide(value: string): void {
        store.setMenubarAutoHide(value);
    }

    function setAppearance(value: string): void {
        store.setAppearance(value);
    }

    function setTransparency(value: real): void {
        store.setTransparency(value);
    }

    function setReduceTransparency(value: bool): void {
        store.setReduceTransparency(value);
    }

    function setReduceMotion(value: bool): void {
        store.setReduceMotion(value);
    }

    function setIncreaseContrast(value: bool): void {
        store.setIncreaseContrast(value);
    }

    function setZoom(value: bool): void {
        store.setZoom(value);
    }

    function setZoomLevel(value: real): void {
        store.setZoomLevel(value);
    }

    function setTextSize(value: real): void {
        store.setTextSize(value);
    }

    function setDockAutohide(value: bool): void {
        store.setDockAutohide(value);
    }

    function setDockSize(value: real): void {
        store.setDockSize(value);
    }

    function setDockPosition(value: string): void {
        store.setDockPosition(value);
    }

    function setDockMagnification(value: real, enabled: bool): void {
        store.setDockMagnification(value, enabled);
    }

    function setDockPinned(list: var): void {
        store.setDockPinned(list);
    }

    function setDockRecent(list: var): void {
        store.setDockRecent(list);
    }

    function setDockFolders(list: var): void {
        store.setDockFolders(list);
    }

    function setDockStackOptions(options: var): void {
        store.setDockStackOptions(options);
    }

    function setIconMode(value: string): void {
        store.setIconMode(value);
    }

    function setIconTint(value: string): void {
        store.setIconTint(value);
    }

    function setFolderColor(value: string): void {
        store.setFolderColor(value);
    }

    function setNotificationsDnd(value: bool): void {
        store.setNotificationsDnd(value);
    }

    function setNotificationsAppPreview(app: string, value: string): void {
        store.setNotificationsAppPreview(app, value);
    }

    function setNotificationsPreviews(value: string): void {
        store.setNotificationsPreviews(value);
    }

    // key: mode | location | timer | microphone | showPointer (capture.*); an invalid value is refused.
    function setCaptureOption(key: string, value: var): void {
        store.setCaptureOption(key, value);
    }

    Timer {
        interval: Tokens.autoAppearanceRecheckInterval
        repeat: true
        running: store.appearance === "auto"
        triggeredOnStart: true
        onTriggered: root.now = new Date()
    }

    SettingsStore {
        id: store
        configDir: root.configDir
    }
}
