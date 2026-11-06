pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import Grassfield.Ui
import qs.notifications
import qs.platform
import qs.services
import "BarHide.js" as BarHide
import "../dock/AutoHide.js" as AutoHide
import "StatusLogic.js" as Logic
import "ClockFormat.js" as ClockFormat

// Top bar, one per screen. Left: Grassfield menu (the Grassfield mark), the focused app name with its
// application menu, then the app's own menus when it exports them (T1/T2 through MenuBridge) or the
// T0 File menu, then Window. Right (real backends only): network, volume, battery (when present),
// Control Center, clock. Popups are rendered by qs.overlay through Popups.
Scope {
    id: root

    // The Search status item asks the shell to toggle Search (shell.qml owns it); `searchActive` lights the item while open.
    property bool searchActive: false
    signal searchRequested

    // Test and keyboard hook: qs ipc call menubar open <system|app|volume|network|battery|controlcenter> <output|"">.
    IpcHandler {
        target: "menubar"

        // screen: output name, empty for the first one.
        function open(kind: string, screen: string): void {
            const all = bars.instances;
            let bar = all.length > 0 ? all[0] : null;
            const wanted = screen !== "" ? screen : Compositor.focusedScreenName;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === wanted)
                    bar = all[i];
            }
            if (bar)
                bar.popup(kind);
        }

        // Centered panels without a bar anchor: forcequit (Popups refuses a kind its Overlay does not draw).
        function panel(kind: string, screen: string): void {
            Popups.open(kind, screen, 0, 0, "center", {});
        }

        // Test hook: refused outside a dev session (VisualFixtures.dev), like every read-only hook below (SEC-04).
        function close(): void {
            if (VisualFixtures.dev)
                Popups.close();
        }

        // Test hook (tests/visual/menubar-macos.sh): the open popup's kind and output, "" when none. Read-only.
        function openKind(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return Popups.active ? Popups.kind + "@" + Popups.screenName : "";
        }

        // Test hook (tests/visual/menubar-macos.sh): "held" while the overlay waits for the end of a press on the bar before it
        // takes the keyboard (a press whose release the bar never saw would leave it so: keys then reach the window below).
        function keyboardWait(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return Popups.active && Popups.pointerHeld ? "held" : "";
        }

        // Test hook (tests/visual/flow-capture-defects.sh): the app the bar of `screen` names and how many app menus it carries, as
        // JSON {appId, appName, bridgeMenus}. Read-only, dev session only.
        function shown(screen: string): string {
            if (!VisualFixtures.dev)
                return "refused";
            const all = bars.instances;
            let bar = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    bar = all[i];
            }
            return bar ? JSON.stringify({appId: bar.shownAppId, appName: bar.appName, bridgeMenus: bar.bridgeMenus.length}) : "{}";
        }

        // Test hook (tests/visual/menubar-status.sh): JSON {menusRight, status: [{name, x, w}]} of the bar of `screen`.
        function statusState(screen: string): string {
            if (!VisualFixtures.dev)
                return "refused";
            const all = bars.instances;
            let bar = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    bar = all[i];
            }
            return bar ? JSON.stringify({menusRight: bar.menusRight(), status: bar.statusRects()}) : "{}";
        }

        // Test hook (tests/visual/menubar-macos.sh): the auto-hide state of an output's bar as JSON. Read-only.
        function autohide(screen: string): string {
            if (!VisualFixtures.dev)
                return "refused";
            const all = bars.instances;
            let bar = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    bar = all[i];
            }
            if (!bar)
                return "{}";
            return JSON.stringify({
                mode: bar.hideMode,
                fullscreen: bar.fullscreen,
                hides: bar.autoHides,
                state: bar.hideMachine.state,
                visible: bar.hideMachine.visible,
                away: bar.away,
                overlay: BarHide.overlayLayer(bar.fullscreen),
                zone: bar.exclusiveZone,
                titlebarRevealed: bar.titlebarRevealed
            });
        }

        // Test hook (tests/integration/global_menus.sh): JSON with the shown window, the bridge state, the bar's
        // left titles and, when a bridge menu is open, its rows (submenus included), in output coordinates.
        function bridgeState(screen: string): string {
            if (!VisualFixtures.dev)
                return "refused";
            const all = bars.instances;
            let bar = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    bar = all[i];
            }
            return JSON.stringify({
                window: MenuBridge.window,
                windowAppId: MenuBridge.windowAppId,
                connected: MenuBridge.connected,
                registrar: MenuBridge.registrar,
                menus: MenuBridge.menus.map(m => m.title),
                bar: bar ? bar.titleRects() : [],
                popup: Popups.kind === "appbridge" && MenuBridge.popup ? root.rowRects(MenuBridge.popup) : []
            });
        }
    }

    // Rows of an open bridge menu and of its open submenus: [{text, dbusId, enabled, submenu, x, y, w, h}].
    function rowRects(menu: Item): var {
        const out = [];
        const walk = item => {
            const kids = item.children;
            for (let i = 0; i < kids.length; i++) {
                const k = kids[i];
                // PopupMenu rows are delegates with a `modelData` item (generic Item access: no static type).
                const data = k["modelData"];
                if (data && typeof data === "object" && data.dbusId !== undefined && k.visible) {
                    const p = k.mapToItem(null, 0, 0);
                    out.push({text: data.text, dbusId: data.dbusId, enabled: data.enabled !== false, submenu: data.submenu !== undefined, x: Math.round(p.x), y: Math.round(p.y), w: Math.round(k.width), h: Math.round(k.height)});
                }
                walk(k);
            }
        };
        walk(menu);
        return out;
    }

    // Test hook: set Control Center values the way the UI does (persisted too). Refused outside a dev session
    // (VisualFixtures.dev, SEC-04): another process must not change the user's settings behind their back.
    IpcHandler {
        target: "controlcenter"

        function transparency(value: real): void {
            if (VisualFixtures.dev)
                Settings.setTransparency(value);
        }

        function appearance(name: string): void {
            if (VisualFixtures.dev)
                Settings.setAppearance(name);
        }

        function reduceTransparency(on: bool): void {
            if (VisualFixtures.dev)
                Settings.setReduceTransparency(on);
        }

        function reduceMotion(on: bool): void {
            if (VisualFixtures.dev)
                Settings.setReduceMotion(on);
        }

        // The Sound and Display sliders by IPC (REQ-QS-CC5/CC6 acceptance: set the slider, then `wpctl get-volume
        // @DEFAULT_AUDIO_SINK@` or `brightnessctl` agrees). Test hooks, so refused outside a dev session (SEC-04: another
        // process must not drive the shell's controls); in the dev session the sliders' own dev guard then answers
        // "refused: dev guard" and changes nothing (tests/shell/cc_sliders_ipc.sh). `value` is 0..1.
        function volume(value: real): string {
            if (!VisualFixtures.dev)
                return "refused";
            return Audio.deviceReady ? (Audio.setVolume(value) ? "ok" : "refused: dev guard") : "unavailable: no output";
        }

        function brightness(value: real): string {
            if (!VisualFixtures.dev)
                return "refused";
            if (!Brightness.deviceAvailable)
                return "unavailable: no backlight";
            return Brightness.setLevel(value) ? "ok" : "refused: dev guard";
        }

        // Read-only: the level the sliders show, 0..1 with two decimals ("none" without the device). Dev session only.
        function volumeLevel(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return Audio.deviceReady ? Audio.deviceVolume.toFixed(2) : "none";
        }

        function brightnessLevel(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return Brightness.deviceAvailable ? Brightness.deviceLevel.toFixed(2) : "none";
        }

        // Read-only: what the shell applies of the Quick Settings values, as JSON (tests/visual/flow-quicksettings.sh,
        // flow-settings.sh). `nightShift` is "hidden" when the helper or hyprsunset is missing (the switch is not
        // shown), else "off" or "on". Dev session only.
        function state(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return JSON.stringify({
                appearance: Settings.appearance,
                dark: Settings.dark,
                transparency: Math.round(Settings.transparency * 100) / 100,
                reduceTransparency: Settings.reduceTransparency,
                reduceMotion: Settings.reduceMotion,
                dnd: Notifications.dnd,
                nightShift: NightShift.available ? (NightShift.on ? "on" : "off") : "hidden"
            });
        }
    }

    Variants {
        id: bars

        model: Quickshell.screens

        // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: win

            required property ShellScreen modelData

            // Gate P5: the first frame of this bar counts toward "grassfield-shell: usable" (platform/Usable.qml).
            UsableProbe {
                kind: "bar"
                screenName: win.modelData ? win.modelData.name : ""
                // P5 counts the entrance (ADR-0040 step 6): the bar's first frame once it is shown.
                armed: win.entered
            }

            // Last non-empty app: layer-shell focus (a popup is open) clears the active toplevel.
            // It only counts while that app still has a window: a killed last window must not leave
            // its name in the bar.
            property string lastAppId: ""
            readonly property bool lastAppAlive: {
                if (lastAppId === "")
                    return false;
                const list = Compositor.toplevels.values;
                for (let i = 0; i < list.length; i++) {
                    if (list[i].appId === lastAppId)
                        return true;
                }
                return false;
            }
            // The desktop holds the keyboard: Hyprland still reports the last window as active, the bar shows the desktop (Finder).
            // With Stages on and no active window (an Exclusive layer holds the keyboard after a swap) the front app of the
            // Stages state is named (display only, AppMenus.context disables the window commands).
            readonly property string shownAppId: DesktopState.holdsKeyboard || Compositor.quickLookFromDesktop ? "" : Compositor.frontAppId !== "" ? Compositor.frontAppId : (Popups.active && lastAppId !== "" && lastAppAlive ? lastAppId : Compositor.stagesFrontAppId)
            readonly property string appName: {
                if (shownAppId === "")
                    return qsTr("Desktop");
                return Apps.nameFor(shownAppId);
            }
            readonly property bool hasApp: shownAppId !== ""
            // The app's own menus (T1/T2, MenuBridge) for the shown app: [{dbusId, title, enabled}], [] when it
            // exports none (GTK4, Electron, no plugin or bridge): the T0 menus then stay. MenuBridge is read first
            // so that the singleton (bridge connection, appmenu registrations) exists from the start.
            readonly property var bridgeMenus: MenuBridge.menus.length > 0 && hasApp && MenuBridge.windowAppId.toLowerCase() === shownAppId.toLowerCase() ? MenuBridge.menus : []
            // T0 File (desktop entry actions) gives way to the app's own menus; the actions stay in the Dock menu.
            readonly property bool hasFileMenu: hasApp && bridgeMenus.length === 0 && AppMenus.model.hasFileMenu(AppMenus.context(shownAppId))
            // Transparent by default (like macOS 26/27); `menubar.showBackground` restores the frosted band, and so does a wallpaper
            // strip over which neither tone reaches 4.5:1 (BarTone.assistOf, ADR-0016: shown on that output until the wallpaper changes).
            // Over a full-screen window the bar is drawn on that window's content, not on the wallpaper the tone was measured on: the frosted band then (macOS does the same).
            // Reduce Transparency and Increase Contrast show the band too, as macOS does (ADR-0039 step 25): the opaque band under
            // the first, the frosted one under the second.
            readonly property bool showBackground: Settings.menubarShowBackground || BarTone.assistOf(win.screen.name) || win.fullscreen
                || Appearance.reduceTransparency || Appearance.increaseContrast
            // Without a background the bar sits on the wallpaper and its foreground adapts to the wallpaper strip under this
            // output's bar (BarTone, the macOS model): white text over a dark wallpaper, black over a light one, with a faint
            // shadow of the opposite colour (gate A2). On the material it is the appearance's text colour.
            // The glass band judged over the strip under the bar (a picture or a video), only while that strip is what lies behind it
            // (BarHide.bandOnWallpaper); else the appearance's own material at the worst case (Appearance.barBand).
            readonly property var bandRange: BarHide.bandOnWallpaper(win.hideMode, win.fullscreen) ? BarTone.rangeOf(win.screen.name) : null
            readonly property var band: Appearance.barBand(bandRange, BarTone.bandDarkOf(win.screen.name))
            readonly property bool darkTone: BarTone.toneOf(win.screen.name) === "dark"
            readonly property var barPalette: darkTone ? Appearance.lightColors : Appearance.darkColors
            readonly property var foreground: Appearance.barForeground(showBackground, band, darkTone)
            readonly property color barText: foreground.text
            readonly property color barTextDisabled: Appearance.withAlpha(barText, Tokens.materialDisabledOpacity)
            readonly property color barTint: foreground.hover
            readonly property color barShadow: darkTone ? barPalette.materialHighlight : barPalette.shadow
            readonly property var battery: UPower.displayDevice
            // Now Playing (macOS: "Show When Active"): while a player has a session (playing, or paused with a track).
            readonly property bool showNowPlaying: Logic.nowPlayingShown(Settings.menubarShowNowPlaying, Media.available, Media.playing, Media.title)
            // Screen sharing (ADR-0035 D-6, step 7b): while an app shares the screen through the portal (xdph's streams). Never
            // optional: a privacy indicator does not give way when the status area is crowded.
            readonly property bool showScreenShare: SharePicker.sharing
            // A screen recording runs (ADR-0045 OC-1, grassfield-capture's state through CaptureState): its stop item with the
            // elapsed time. Never optional either: the screen being recorded, and how to stop it, always show.
            readonly property bool showRecording: CaptureState.recording
            // The Input menu (macOS: shown as soon as there are two input sources, Settings > Keyboard > Input Sources can hide
            // it): the source in use, FR or US.
            readonly property bool showInput: InputSource.available && Settings.keyboardShowInputMenu
            // Crowding (macOS: status items that would collide with the menus are hidden): the status area gets the width
            // between the application menus and the right inset; optional items (third-party, Now Playing, Search) give way
            // leftmost first, never the system items, Quick Settings or the clock (StatusLogic.hiddenItems). Implicit widths
            // only: a hidden item never changes the decision.
            readonly property real statusIconWidth: Tokens.menubarIconSize + 2 * Tokens.menubarStatusItemPadding
            // The clock's text: date part by the setting (the date setting resolves to `withDate`), time part by the hour format,
            // seconds and AM/PM options; `off` is the dark beat of the flashing separators.
            function clockString(withDate: bool, off: bool): string {
                const parts = clockParts(withDate);
                return ClockFormat.join(parts.date, ClockFormat.flash(parts.time, off), Tokens.menubarClockGap);
            }
            // The clock's date part ("" for none) and time part, as clockString joins them.
            function clockParts(withDate: bool): var {
                const kind = ClockFormat.dateKind(withDate, Settings.menubarClockShowDayOfWeek);
                const d = FixedTime.date(clock.date);
                let dateText = "";
                // Day and month in the region's order (macOS: "Mon Oct 26" in the US, "Mon 26 Oct" in the UK).
                const monthFirst = ClockFormat.monthFirst(Qt.locale().dateFormat(Locale.ShortFormat));
                if (kind === "both")
                    dateText = Qt.locale().toString(d, ClockFormat.orderDate(qsTr("ddd MMM d"), monthFirst));
                else if (kind === "day")
                    dateText = Qt.locale().toString(d, qsTr("ddd"));
                else if (kind === "date")
                    dateText = Qt.locale().toString(d, ClockFormat.orderDate(qsTr("MMM d"), monthFirst));
                const t = Qt.formatTime(d, ClockFormat.timePattern(Qt.locale().timeFormat(Locale.ShortFormat), Settings.menubarClockHours, Settings.menubarClockShowSeconds, Settings.menubarClockShowAmPm));
                return {date: dateText, time: t};
            }
            readonly property var clockShownParts: clockParts(clockDateShown)
            readonly property bool clockFlashOff: Settings.menubarClockFlashSeparators && clock.date.getSeconds() % 2 === 1
            // Widths of the clock with and without the date (never of what is drawn now, so the choice cannot feed back).
            readonly property real clockFullWidth: clockFullMetrics.width
            readonly property real clockShortWidth: clockShortMetrics.width
            // The button's own padding, not its implicit width minus the text's: that read the text, which follows clockDateShown
            // (a binding loop).
            readonly property real clockPadding: 2 * clockButton.padding
            // "When Space Allows": the date stays while the whole status area fits with it.
            readonly property bool clockDateShown: {
                const mode = Settings.menubarClockDate;
                if (mode !== "auto")
                    return mode === "always";
                const items = statusList(clockFullWidth);
                let total = 0;
                for (const it of items)
                    total += it.width;
                return ClockFormat.dateFits(mode, Logic.hiddenItems(statusAvailable, items, 0), total, statusAvailable);
            }
            readonly property var statusItems: statusList(clockDateShown ? clockFullWidth : clockShortWidth)
            function statusList(clockWidth: real): var {
                const list = [];
                const trays = Settings.menubarShowTrayItems ? TrayHost.items : [];
                for (let i = 0; i < trays.length; i++)
                    list.push({key: "tray" + i, width: statusIconWidth, optional: true});
                if (showNowPlaying)
                    list.push({key: "nowplaying", width: statusIconWidth, optional: true});
                if (showRecording)
                    list.push({key: "recording", width: recordingButton.implicitWidth, optional: false});
                if (showScreenShare)
                    list.push({key: "screenshare", width: statusIconWidth, optional: false});
                list.push({key: "system", width: (showFocus ? dndButton.implicitWidth : 0) + (showInput ? inputButton.implicitWidth : 0) + (Settings.menubarShowWifi ? networkButton.implicitWidth : 0) + (Settings.menubarShowSound ? volumeButton.implicitWidth : 0) + (showBattery ? batteryButton.implicitWidth : 0), optional: false});
                if (Settings.menubarShowSearch)
                    list.push({key: "search", width: statusIconWidth, optional: true});
                list.push({key: "core", width: ccButton.implicitWidth + clockPadding + clockWidth, optional: false});
                return list;
            }
            // Width of the status items that never give way (system items, Quick Settings, clock without its date: the
            // narrowest, so the application name's room never depends on the date decision).
            readonly property real statusMandatoryShortWidth: {
                const items = statusList(clockShortWidth);
                let sum = 0;
                for (let i = 0; i < items.length; i++) {
                    if (!items[i].optional)
                        sum += items[i].width;
                }
                return sum;
            }
            // Room for the application name: the bar minus the insets, the fixed titles and the mandatory status items.
            readonly property real appTitleMax: Math.max(0, win.width - (Tokens.menubarInsetLeft - Tokens.menubarItemPadding) - (Tokens.menubarInsetRight - Tokens.menubarItemPadding)
                - systemButton.implicitWidth - (hasFileMenu ? fileButton.implicitWidth : 0) - (hasApp ? windowButton.implicitWidth : 0)
                - 2 * Tokens.menubarItemPadding - statusMandatoryShortWidth - 2 * Tokens.menubarItemPadding)
            // The app's own menus that fit (UI audit 2026-11-05 U15): after the application name, in the app's order, as long
            // as they end before the status items that never give way; the trailing ones that would run under them are
            // hidden (macOS cuts an app's menus where the bar has no more room). The name keeps its own room first (it
            // only elides when even the shell's menus leave it none).
            readonly property int bridgeShown: {
                const count = bridgeRepeater.count;
                let room = appTitleMax - appTitle.width;
                let n = 0;
                for (let i = 0; i < count; i++) {
                    const b = bridgeRepeater.itemAt(i);
                    if (!b)
                        break;
                    room -= b.implicitWidth;
                    if (room < 0)
                        break;
                    n++;
                }
                return n;
            }
            readonly property real statusAvailable: win.width - (Tokens.menubarInsetRight - Tokens.menubarItemPadding) - (leftRow.x + leftRow.width) - Tokens.menubarItemPadding
            readonly property var hiddenStatus: Logic.hiddenItems(statusAvailable, statusItems, 0)
            readonly property bool hasBattery: !VisualFixtures.active && battery !== null && battery.isPresent && battery.isLaptopBattery
            // Settings > Menu Bar: which system items the bar shows (Focus only while it is on, as before).
            readonly property bool showBattery: hasBattery && Settings.menubarShowBattery
            readonly property bool showFocus: Notifications.dnd && Settings.menubarShowFocus

            // SingleMainWindow of the app's desktop entry decides whether File has New Window.
            onShownAppIdChanged: {
                // The app is gone: its open app menu would act on nothing.
                if (shownAppId === "" && ["app", "appfile", "appwindow", "appbridge"].indexOf(Popups.kind) >= 0 && Popups.screenName === (win.screen ? win.screen.name : ""))
                    Qt.callLater(Popups.close);
                const entry = shownAppId !== "" ? Apps.lookup(shownAppId) : null;
                if (entry)
                    AppMenus.probe(entry.id);
            }

            Connections {
                target: Compositor

                function onFrontAppIdChanged(): void {
                    if (Compositor.frontAppId !== "")
                        win.lastAppId = Compositor.frontAppId;
                }
            }

            // Forget the remembered app once its last window is gone. Deferred: writing lastAppId from this
            // handler would re-enter the lastAppAlive binding (binding loop).
            onLastAppAliveChanged: {
                if (!lastAppAlive && lastAppId !== "")
                    Qt.callLater(() => {
                        if (!win.lastAppAlive)
                            win.lastAppId = "";
                    });
            }

            // The app's menus went away (window closed, app quit, bridge gone): an open one would act on nothing.
            onBridgeMenusChanged: {
                if (bridgeMenus.length === 0 && isOpen("appbridge"))
                    Qt.callLater(Popups.close);
            }

            // Auto-hide (macOS "Automatically hide and show the menu bar", BarHide.js): the Dock's state machine (AutoHide.js) per
            // output. The bar window keeps its size; only the content slides, and only the edge strip takes input while it is
            // away. Over a full-screen window it sits on the overlay layer (Hyprland draws full-screen windows above the top layer).
            readonly property string hideMode: BarHide.normalize(Settings.menubarAutoHide)
            readonly property bool fullscreen: Compositor.fullscreenOn(win.screen.name, Compositor.topologyRevision)
            readonly property bool autoHides: BarHide.hides(hideMode, fullscreen)
            property var hideMachine: AutoHide.create()
            // Over a full-screen window the bar comes and goes with that window's titlebar the plugin reveals at the top edge
            // (ADR-0036 D65, macOS): in view at once while it is revealed, and leaving with it without the grace.
            readonly property bool titlebarRevealed: fullscreen && Compositor.titlebarRevealedOn(win.screen ? win.screen.name : "")
            onTitlebarRevealedChanged: {
                if (!titlebarRevealed)
                    Qt.callLater(win.leaveWithTitlebar);
            }
            function leaveWithTitlebar(): void {
                if (!win.titlebarRevealed)
                    win.hideMachine = AutoHide.leaveNow(win.hideMachine, win.hideInhibitors, win.autoHides);
            }
            // A menu of this bar open (or Notification Center from the clock) keeps it in view; the pointer on the bar or its edge
            // strip too; a revealed full-screen titlebar below it too.
            readonly property var hideInhibitors: ({
                    pointer: winHover.hovered,
                    popup: tracking || (Notifications.centerOpen && Notifications.centerScreen === (win.screen ? win.screen.name : "")),
                    forced: titlebarRevealed
                })
            readonly property var hideTiming: ({
                    hideGrace: Tokens.menubarHideGrace,
                    hideDuration: Appearance.reduceMotion ? 0 : Tokens.menubarHideDuration,
                    revealDwell: Tokens.menubarRevealDwell,
                    revealDuration: Appearance.reduceMotion ? 0 : Tokens.menubarRevealDuration
                })
            readonly property bool away: autoHides && hideMachine.state === "hidden" && !AutoHide.forcing(hideInhibitors)
            readonly property real slideY: BarHide.slideOffset(Tokens.menubarHeight, AutoHide.ease(hideMachine.visible))
            // The screen-sharing indicator stays in view when the bar goes (ADR-0035 7-14): over a full-screen window, or on the
            // desktop with a bar that hides there, its own piece of the band at the bar's right end comes as the bar leaves and
            // goes as it comes back with its status item, as macOS keeps its privacy indicator in the corner of a full-screen app.
            readonly property real pinnedShareOpacity: BarHide.pinnedIndicatorOpacity(showScreenShare, AutoHide.ease(hideMachine.visible))

            // The Now Playing item went away (player closed, switched off in Settings): its open popover would act on nothing.
            onShowNowPlayingChanged: {
                if (!showNowPlaying && isOpen("nowplaying"))
                    Qt.callLater(Popups.close);
            }

            // The input sources went down to one (Settings, or the keyboard list changed): the open Input menu would list one.
            onShowInputChanged: {
                if (!showInput && isOpen("input"))
                    Qt.callLater(Popups.close);
            }

            // The last share ended: its open menu would list nothing.
            onShowScreenShareChanged: {
                if (!showScreenShare && isOpen("screenshare"))
                    Qt.callLater(Popups.close);
            }

            function isOpen(kind: string): bool {
                return Popups.kind === kind && Popups.screenName === (win.screen ? win.screen.name : "");
            }

            // macOS menu tracking: while one of this bar's menus is open, moving onto another title or status item opens
            // its menu without a click. The clock (Notification Center) and the Do Not Disturb indicator are not menus.
            readonly property var trackedKinds: ["system", "app", "appfile", "appwindow", "appbridge", "network", "volume", "battery", "controlcenter", "tray", "nowplaying", "screenshare", "input"]
            readonly property bool tracking: Popups.active && Popups.screenName === (win.screen ? win.screen.name : "") && trackedKinds.indexOf(Popups.kind) >= 0

            function hoverSwitch(kind: string): void {
                if (win.tracking && Popups.kind !== kind)
                    win.popup(kind);
            }

            function hoverSwitchBridge(button: Item, menu: var): void {
                if (win.tracking && !(Popups.kind === "appbridge" && Popups.data.dbusId === menu.dbusId))
                    win.openBridge(button, menu);
            }

            function hoverSwitchTray(button: Item, item: var): void {
                if (item && win.tracking && !(Popups.kind === "tray" && Popups.data.item === item))
                    win.openTray(button, item);
            }

            // Opens (or closes, if it is open) a status item's own menu, aligned to the right edge of its button.
            function openTray(button: Item, item: var): void {
                if (isOpen("tray") && Popups.data.item === item) {
                    Popups.close();
                    return;
                }
                const x = button.mapToItem(null, button.width, 0).x;
                Popups.open("tray", (win.screen ? win.screen.name : ""), x, Tokens.menubarHeight, "right", {item: item});
            }

            // Left titles that open a menu, in bar order: [{kind, button, menu}] (menu: the bridge entry, else null).
            function menuTitles(): var {
                const out = [];
                const kids = leftRow.children;
                let bridge = 0;
                for (let i = 0; i < kids.length; i++) {
                    const k = kids[i];
                    const name = k.objectName;
                    if (name.indexOf("menubar-") !== 0)
                        continue;
                    const sep = name.indexOf(":");
                    const kind = sep < 0 ? name.slice(8) : name.slice(8, sep);
                    const menu = kind === "bridge" ? win.bridgeMenus[bridge++] : null;
                    if (!k.visible || (menu && !menu.enabled))
                        continue;
                    out.push({kind: kind, button: k, menu: menu});
                }
                return out;
            }

            // Every item the keyboard cycle reaches, in bar order: the left titles, then the status items that open a menu
            // (third-party tray items first). Search, the clock and Do Not Disturb are not menus: they have their own keys.
            function navEntries(): var {
                const out = win.menuTitles();
                const kids = rightRow.children;
                for (let i = 0; i < kids.length; i++) {
                    const k = kids[i] as BarButton;
                    if (!k || !k.visible || !k.opensMenu)
                        continue;
                    if (k.objectName === "menubar-tray")
                        out.push({kind: "tray", button: k, menu: null});
                    else if (k.menuKind !== "")
                        out.push({kind: k.menuKind, button: k, menu: null});
                }
                return out;
            }

            readonly property var popupKindOf: ({system: "system", app: "app", bridge: "appbridge", file: "appfile", window: "appwindow"})

            function isEntryOpen(t: var): bool {
                const popupKind = win.popupKindOf[t.kind] !== undefined ? win.popupKindOf[t.kind] : t.kind;
                if (popupKind !== Popups.kind)
                    return false;
                if (t.menu)
                    return Popups.data.dbusId === t.menu.dbusId;
                if (t.kind === "tray")
                    return Popups.data.item === t.button.item;
                return true;
            }

            function openEntry(t: var): void {
                if (t.menu)
                    win.openBridge(t.button, t.menu);
                else if (t.kind === "tray")
                    win.openTray(t.button, t.button.item);
                else
                    win.popup(t.kind === "file" ? "appfile" : t.kind === "window" ? "appwindow" : t.kind);
            }

            // Left/Right in an open menu (macOS): the previous or next item's menu, wrapping around.
            function stepMenu(direction: int): void {
                const titles = win.navEntries();
                let at = -1;
                for (let i = 0; i < titles.length; i++) {
                    if (win.isEntryOpen(titles[i]))
                        at = i;
                }
                if (at < 0 || titles.length < 2)
                    return;
                win.openEntry(titles[(at + direction + titles.length) % titles.length]);
            }

            // Ctrl+F8 (macOS "move focus to the status menus"): the first status item's menu; no status menu: nothing.
            function openFirstStatus(): void {
                const all = win.navEntries();
                for (let i = 0; i < all.length; i++) {
                    if (["input", "network", "volume", "battery", "controlcenter", "nowplaying", "screenshare", "tray"].indexOf(all[i].kind) >= 0) {
                        win.openEntry(all[i]);
                        return;
                    }
                }
            }

            Connections {
                target: Popups

                function onMenuStepRequested(screen: string, direction: int): void {
                    if (screen === (win.screen ? win.screen.name : ""))
                        win.stepMenu(direction);
                }
            }

            // The bar button under x (output coordinates), null for none.
            function buttonAt(x: real): BarButton {
                const rows = [leftRow, rightRow];
                for (let r = 0; r < rows.length; r++) {
                    const kids = rows[r].children;
                    for (let i = 0; i < kids.length; i++) {
                        const k = kids[i] as BarButton;
                        if (!k || !k.visible)
                            continue;
                        const left = k.mapToItem(null, 0, 0).x;
                        if (x >= left && x < left + k.width)
                            return k;
                    }
                }
                return null;
            }

            // The overlay's share of the bar strip while a popup is open (Popups.bars): moving onto a menu item switches to
            // its menu; a press acts like a click on that item (the open one closes, another opens), and a press on the
            // clock, the Do Not Disturb item or empty bar closes the open menu first.
            function trackAt(x: real): void {
                const b = win.buttonAt(x);
                if (b && b.opensMenu)
                    b.entered();
            }

            function pressAt(x: real, button: string): void {
                const b = win.buttonAt(x);
                if (!b || !b.opensMenu)
                    Popups.close();
                if (!b)
                    return;
                if (button === "right" || button === "middle")
                    b.auxPressed(button);
                else
                    b.activated();
            }

            // The entrance's key for this output, taken once (the screen is gone when a removed output destroys the window).
            property string entranceKey: ""
            Component.onCompleted: {
                Popups.registerBar(win.screen.name, win);
                win.entranceKey = "menubar:" + win.screen.name;
                Entrance.expect(win.entranceKey);
                if (win.barFinal)
                    win.settleBar();
                if (win.entered)
                    Journal.shown("menubar", win.screen.name);
            }
            Component.onDestruction: {
                Popups.unregisterBar(win.screen.name, win);
                if (win.entered)
                    Journal.hidden("menubar", win.screen ? win.screen.name : "");
                else
                    Entrance.forget(win.entranceKey);
            }

            // ---- the entrance (ADR-0040 step 6, ID-20, ID-5, ID-6) ----
            // The bar's content is final once the settings are read (or the wait for them is over: Entrance.settingsFinal); its
            // auto-hide then starts where it will rest (hidden when it hides, as the Dock's), instead of showing and sliding
            // away. It appears with the Dock and the desktop icons in one fade (Entrance.revealed, session.revealMs).
            readonly property bool barFinal: Entrance.settingsFinal
            onBarFinalChanged: {
                if (barFinal)
                    win.settleBar();
            }
            function settleBar(): void {
                win.hideMachine = AutoHide.initial(win.autoHides);
                Entrance.ready(win.entranceKey);
            }
            readonly property bool entered: Entrance.revealed
            onEnteredChanged: {
                if (!entered)
                    return;
                // What it rests in now: the settings or the full-screen state may have changed since settleBar (review of
                // 3a5e1b80: slow settings, a restart over a full-screen window).
                win.hideMachine = AutoHide.initial(win.autoHides);
                Journal.shown("menubar", win.screen.name);
            }
            onAutoHidesChanged: {
                if (!win.entered && win.barFinal)
                    win.hideMachine = AutoHide.initial(win.autoHides);
            }
            property real entrance: Entrance.revealed ? 1 : 0
            Behavior on entrance {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.sessionRevealMs)
                }
            }

            // Opens a popup under (left) or aligned to the right edge of (right) a bar button.
            function openFor(kind: string, button: Item, alignment: string, payload: var): void {
                const x = button.mapToItem(null, alignment === "right" ? button.width : 0, 0).x;
                Popups.toggle(kind, (win.screen ? win.screen.name : ""), x, Tokens.menubarHeight, alignment, payload);
            }

            // Opens (or closes, if it is open) one of the app's own menus under its title.
            function openBridge(button: Item, menu: var): void {
                if (!menu.enabled)
                    return;
                if (isOpen("appbridge") && Popups.data.dbusId === menu.dbusId) {
                    Popups.close();
                    return;
                }
                const x = button.mapToItem(null, 0, 0).x;
                Popups.open("appbridge", (win.screen ? win.screen.name : ""), x, Tokens.menubarHeight, "left", {dbusId: menu.dbusId, window: MenuBridge.window, title: menu.title});
                MenuBridge.aboutToShow(menu.dbusId);
            }

            // Left titles in output coordinates (test hook): [{kind, title, x, y, w, h}], kind app|bridge|file|window.
            function titleRects(): var {
                const out = [];
                const kids = leftRow.children;
                for (let i = 0; i < kids.length; i++) {
                    const k = kids[i];
                    const name = k.objectName;
                    if (!k.visible || name.indexOf("menubar-") !== 0)
                        continue;
                    const p = k.mapToItem(null, 0, 0);
                    const sep = name.indexOf(":");
                    out.push({kind: sep < 0 ? name.slice(8) : name.slice(8, sep), title: sep < 0 ? "" : name.slice(sep + 1), x: Math.round(p.x), y: Math.round(p.y), w: Math.round(k.width), h: Math.round(k.height)});
                }
                return out;
            }

            // Visible status buttons in output coordinates (test hook): [{name, x, w}] left to right, and the right edge of the
            // application menus (`menusRight`), to check that the two never overlap.
            function statusRects(): var {
                const out = [];
                const kids = rightRow.children;
                for (let i = 0; i < kids.length; i++) {
                    const k = kids[i] as BarButton;
                    if (!k || !k.visible)
                        continue;
                    out.push({name: k.accessibleName, x: Math.round(k.mapToItem(null, 0, 0).x), w: Math.round(k.width)});
                }
                return out;
            }

            function menusRight(): real {
                return Math.round(leftRow.mapToItem(null, leftRow.width, 0).x);
            }

            function popup(kind: string): void {
                switch (kind) {
                case "status":
                    win.openFirstStatus();
                    break;
                case "system":
                    openFor("system", systemButton, "left", {});
                    break;
                case "app":
                    openFor("app", appButton, "left", {appId: win.shownAppId});
                    break;
                case "appfile":
                    openFor("appfile", fileButton, "left", {appId: win.shownAppId});
                    break;
                case "appwindow":
                    openFor("appwindow", windowButton, "left", {appId: win.shownAppId});
                    break;
                case "network":
                    if (Settings.menubarShowWifi)
                        openFor("network", networkButton, "right", {});
                    break;
                case "volume":
                    if (Settings.menubarShowSound)
                        openFor("volume", volumeButton, "right", {});
                    break;
                case "battery":
                    if (win.showBattery)
                        openFor("battery", batteryButton, "right", {});
                    break;
                case "controlcenter":
                    openFor("controlcenter", ccButton, "right", {});
                    break;
                case "nowplaying":
                    if (win.showNowPlaying)
                        openFor("nowplaying", nowPlayingButton, "right", {});
                    break;
                case "screenshare":
                    if (win.showScreenShare)
                        openFor("screenshare", screenShareButton, "right", {});
                    break;
                case "input":
                    if (win.showInput)
                        openFor("input", inputButton, "right", {});
                    break;
                }
            }

            screen: modelData
            anchors {
                top: true
                left: true
                right: true
            }
            implicitHeight: Tokens.menubarHeight
            // Only a bar that is on the desktop in its mode reserves space, constantly: reveal and hide never reflow windows.
            exclusiveZone: BarHide.reservesSpace(hideMode) ? Tokens.menubarHeight : 0
            color: "transparent"
            // Never the keyboard: hovering or starting must never take it from the focused window, and while one of this
            // bar's menus is open its popup holds it (Exclusive, shell/overlay; CTRL+F2 opens the system menu that way).
            // An OnDemand bar took the keyboard as a menu closed with the pointer resting on the bar (Hyprland gives an
            // on-demand layer under the pointer the keyboard when it refocuses), so the window it still counted active lost
            // its keys (tests/compositor/click_focus.sh).
            focusable: false
            WlrLayershell.layer: BarHide.overlayLayer(win.fullscreen) ? WlrLayer.Overlay : WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.namespace: "grassfield-menubar"
            // Quickshell qmltypes name this property's type PendingRegion/FileViewAdapter without exporting it (metadata quirk).
            // qmllint disable missing-type
            // The band while any of it is in view, the indicator's piece while it shows (ADR-0035 7-14), both during the slide; the
            // band not before the entrance (a blurred strip under an invisible band would show the bar in two steps, review of 3a5e1b80).
            BackgroundEffect.blurRegion: win.entered && win.bandBlurred ? (win.pinnedBlurred ? bandAndPinnedRegion : blurRegion) : (win.pinnedBlurred ? pinnedRegion : null)
            // The bar, or only the top edge strip while it is away.
            mask: Region {
                item: hitItem
            }
            // qmllint enable missing-type

            readonly property bool bandBlurred: win.showBackground && material.blurActive && win.hideMachine.visible > 0
            readonly property bool pinnedBlurred: pinnedShare.visible && pinnedShare.blurActive

            Region {
                id: blurRegion
                item: material
                radius: material.radius
            }

            Region {
                id: pinnedRegion
                item: pinnedShare
                radius: pinnedShare.radius
            }

            Region {
                id: bandAndPinnedRegion
                item: material
                radius: material.radius

                Region {
                    item: pinnedShare
                    radius: pinnedShare.radius
                }
            }

            Item {
                id: hitItem
                width: win.width
                // No input before the entrance: nothing of the bar is visible yet.
                height: win.entered ? BarHide.inputHeight(Tokens.menubarHeight, Tokens.menubarRevealZone, win.away) : 0
            }

            // The menu bar window is mapped for the whole session: it hosts the idle reads of the icon shapes (the first output's
            // bar only), so that the Apps panel opens with every icon's shape known (PERF-01).
            IconShapePrewarm {
                sources: Quickshell.screens.length > 0 && win.screen && Quickshell.screens[0].name === (win.screen ? win.screen.name : "") ? Apps.listedIconSources : []
            }

            HoverHandler {
                id: winHover
                onPointChanged: if (hovered)
                    PointerTracker.report(win.screen.name, point.position.x, point.position.y)
            }

            // Press, drag, release (macOS): a title opens its menu on the press and the button is still down, so the pointer
            // stays with this window (implicit grab) as it moves down onto the menu. Relay it to the open menu (it highlights
            // the row under the pointer) and, on the release, let it run that row; a release on no row leaves the menu open.
            PointHandler {
                id: menuDrag
                property real lastX: 0
                property real lastY: 0
                acceptedButtons: Qt.LeftButton
                onPointChanged: {
                    lastX = point.scenePosition.x;
                    lastY = point.scenePosition.y;
                    if (active)
                        Popups.trackPointer(win.screen.name, lastX, lastY);
                }
                onActiveChanged: {
                    if (active) {
                        Popups.pointerHeld = true;
                    } else {
                        Popups.releasePointer(win.screen.name, lastX, lastY);
                        Popups.pointerHeld = false;
                    }
                }
            }

            // Frame clock of the auto-hide machine: stops while nothing can change (away and idle, or in view and held).
            FrameAnimation {
                running: AutoHide.active(win.hideMachine, win.hideInhibitors, win.autoHides)
                onTriggered: win.hideMachine = AutoHide.step(win.hideMachine, win.hideInhibitors, win.autoHides, win.hideTiming, Math.min(frameTime * 1000, 100))
            }

            WallClock {
                id: clock
                // One tick a second only while the bar is in view (hidden: the minute tick, right again on the reveal).
                seconds: (Settings.menubarClockShowSeconds || Settings.menubarClockFlashSeparators) && !win.away
            }

            TextMetrics {
                id: clockFullMetrics
                font: clockText.font
                text: win.clockString(true, false)
            }

            TextMetrics {
                id: clockShortMetrics
                font: clockText.font
                text: win.clockString(false, false)
            }

            // macOS: with several displays the menu bar of the one that is not active is dimmed (band and content). A single
            // output, no focused output known, or a bar with one of its menus open (the user is using it, whatever output
            // Hyprland counts as focused) is never dimmed.
            readonly property bool dimmed: Quickshell.screens.length > 1 && Compositor.focusedScreenName !== "" && Compositor.focusedScreenName !== (win.screen ? win.screen.name : "")
                && !(Popups.active && Popups.screenName === (win.screen ? win.screen.name : ""))
            property real dimOpacity: win.dimmed ? Tokens.menubarInactiveOpacity : 1

            Behavior on dimOpacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }

            Material {
                id: material
                y: win.slideY
                width: parent.width
                height: parent.height
                // Dimmed with the bar on a display that is not the active one, but never made see-through under Reduce
                // Transparency (ADR-0039 step 25): the opaque band stays opaque, its content dims. It comes in with the bar.
                opacity: (Appearance.reduceTransparency ? 1 : win.dimOpacity) * win.entrance
                visible: win.showBackground
                // ADR-0024: the band is glass like the other surfaces (the "menu" class: its target at the slider, raised to keep the
                // text at 4.5:1 over the wallpaper strip), not the legacy clamped tint; the strip under the bar is what lies behind it.
                glassClass: "menu"
                backdropRect: Qt.rect(0, 0, win.width, Tokens.menubarHeight)
                // The band's tone follows the strip under it (Appearance.glassBand), not the appearance; Reduce Transparency keeps the
                // appearance's own opaque colours.
                tintAlphaOverride: win.band ? win.band.alpha : -1
                tintColor: win.band ? win.band.colors.materialTint : Appearance.colors.materialTint
                radius: Tokens.radiusMenuBar
                shadowEnabled: false
                highlightEnabled: false
                borderEnabled: false

                // Hairline along the bottom edge instead of a full border.
                Rectangle {
                    anchors {
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom
                    }
                    // One device pixel at every scale (UI audit 2026-11-05 U37).
                    height: 1 / Math.max(1, Screen.devicePixelRatio)
                    color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
                }
            }

            // Content: drawn straight on the wallpaper unless the user turns the background on (Settings, Menu Bar).
            Item {
                id: barContent
                y: win.slideY
                width: parent.width
                height: parent.height
                opacity: win.dimOpacity * win.entrance

                    Row {
                        id: leftRow
                        anchors {
                            left: parent.left
                            leftMargin: Tokens.menubarInsetLeft - Tokens.menubarItemPadding
                            verticalCenter: parent.verticalCenter
                        }
                        spacing: 0

                        BarButton {
                            id: systemButton
                            objectName: "menubar-system"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            highlightOutset: Tokens.menubarHighlightOutset
                            accessibleName: qsTr("Grassfield menu")
                            active: win.isOpen("system")
                            onActivated: win.popup("system")
                            opensMenu: true
                            onEntered: win.hoverSwitch("system")

                            Icon {
                                size: Tokens.menubarIconSize
                                heavy: true
                                color: win.barText
                                name: "grassfield-logo"
                            }
                        }

                        BarButton {
                            id: appButton
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            highlightOutset: Tokens.menubarHighlightOutset
                            objectName: "menubar-app"
                            accessibleName: qsTr("Application menu: %1").arg(win.appName)
                            active: win.isOpen("app")
                            onActivated: win.popup("app")
                            opensMenu: true
                            onEntered: win.hoverSwitch("app")

                            Text {
                                id: appTitle
                                textFormat: Text.PlainText
                                text: win.appName
                                color: win.barText
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyMenuSize
                                font.weight: Tokens.typographyMenuBoldWeight
                                elide: Text.ElideRight
                                // A name too long for the room the always-present status items leave is elided.
                                width: Math.min(implicitWidth, win.appTitleMax)
                            }
                        }

                        // The app's own menus (T1/T2), in the app's order.
                        Repeater {
                            id: bridgeRepeater
                            model: win.bridgeMenus

                            delegate: BarButton {
                                id: bridgeButton
                                tint: win.barTint
                                shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            highlightOutset: Tokens.menubarHighlightOutset

                                required property var modelData
                                required property int index

                                // Hidden when it would run under the status items (win.bridgeShown); out of the keyboard
                                // cycle then too (menuTitles skips hidden titles).
                                visible: index < win.bridgeShown
                                objectName: "menubar-bridge:" + modelData.title
                                accessibleName: qsTr("%1 menu").arg(modelData.title)
                                active: win.isOpen("appbridge") && Popups.data.dbusId === modelData.dbusId
                                onActivated: win.openBridge(bridgeButton, bridgeButton.modelData)
                                opensMenu: true
                                onEntered: win.hoverSwitchBridge(bridgeButton, bridgeButton.modelData)

                                Text {
                                    textFormat: Text.PlainText
                                    text: bridgeButton.modelData.title
                                    color: bridgeButton.modelData.enabled ? win.barText : win.barTextDisabled
                                    font.family: Appearance.fontFamily
                                    font.pixelSize: Tokens.typographyMenuSize
                                    font.weight: Tokens.typographyMenuWeight
                                }
                            }
                        }

                        BarButton {
                            id: fileButton
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            highlightOutset: Tokens.menubarHighlightOutset
                            objectName: "menubar-file"
                            visible: win.hasFileMenu
                            accessibleName: qsTr("File menu")
                            active: win.isOpen("appfile")
                            onActivated: win.popup("appfile")
                            opensMenu: true
                            onEntered: win.hoverSwitch("appfile")

                            Text {
                                textFormat: Text.PlainText
                                text: qsTr("File")
                                color: win.barText
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyMenuSize
                                font.weight: Tokens.typographyMenuWeight
                            }
                        }

                        BarButton {
                            id: windowButton
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            highlightOutset: Tokens.menubarHighlightOutset
                            objectName: "menubar-window"
                            visible: win.hasApp
                            accessibleName: qsTr("Window menu")
                            active: win.isOpen("appwindow")
                            onActivated: win.popup("appwindow")
                            opensMenu: true
                            onEntered: win.hoverSwitch("appwindow")

                            Text {
                                textFormat: Text.PlainText
                                text: qsTr("Window")
                                color: win.barText
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyMenuSize
                                font.weight: Tokens.typographyMenuWeight
                            }
                        }
                    }

                    Row {
                        id: rightRow
                        anchors {
                            right: parent.right
                            rightMargin: Tokens.menubarInsetRight - Tokens.menubarItemPadding
                            verticalCenter: parent.verticalCenter
                        }
                        spacing: 0

                        // Third-party status items (StatusNotifierItem), leftmost: macOS keeps them left of the system's.
                        Repeater {
                            model: Settings.menubarShowTrayItems ? TrayHost.items : []

                            delegate: TrayButton {
                                required property var modelData
                                required property int index

                                item: modelData
                                visible: !win.hiddenStatus["tray" + index]
                                bar: win
                                tint: win.barTint
                                shadowed: !win.showBackground
                                shadowColor: win.barShadow
                            }
                        }

                        // Screen recording (ADR-0045 OC-1): while grassfield-capture records, the stop glyph and the elapsed
                        // time; a click stops the recording (the helper's stop, as Ctrl-Super-Esc). Not a menu.
                        BarButton {
                            id: recordingButton
                            objectName: "menubar-recording"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            visible: win.showRecording
                            accessibleName: qsTr("Stop Screen Recording, %1").arg(CaptureState.elapsedText)
                            onActivated: CaptureState.stop()

                            Icon {
                                size: Tokens.menubarIconSize
                                heavy: true
                                color: win.barText
                                name: "record-stop"
                            }

                            Text {
                                textFormat: Text.PlainText
                                text: CaptureState.elapsedText
                                color: win.barText
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyMenuSize
                                font.weight: Tokens.typographyMenuWeight
                                // Tabular figures: the item keeps its width while the seconds change.
                                font.features: {"tnum": 1}
                            }
                        }

                        // Screen sharing: while an app shares the screen; its menu says what is shared.
                        BarButton {
                            id: screenShareButton
                            menuKind: "screenshare"
                            objectName: "menubar-screenshare"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            visible: win.showScreenShare
                            accessibleName: qsTr("Screen Sharing")
                            active: win.isOpen("screenshare")
                            onActivated: win.popup("screenshare")
                            opensMenu: true
                            onEntered: win.hoverSwitch("screenshare")

                            Icon {
                                size: Tokens.menubarIconSize
                                heavy: true
                                color: win.barText
                                name: "screen-share"
                            }
                        }

                        // Now Playing: the active player's controls, while it has a session.
                        BarButton {
                            id: nowPlayingButton
                            menuKind: "nowplaying"
                            objectName: "menubar-nowplaying"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            visible: win.showNowPlaying && !win.hiddenStatus.nowplaying
                            accessibleName: Media.title !== "" ? qsTr("Now Playing: %1").arg(Media.title) : qsTr("Now Playing")
                            active: win.isOpen("nowplaying")
                            onActivated: win.popup("nowplaying")
                            opensMenu: true
                            onEntered: win.hoverSwitch("nowplaying")

                            Icon {
                                size: Tokens.menubarIconSize
                                heavy: true
                                color: win.barText
                                name: "now-playing"
                            }
                        }

                        // Do Not Disturb indicator; click turns it off.
                        BarButton {
                            id: dndButton
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            visible: win.showFocus
                            accessibleName: qsTr("Do Not Disturb is on")
                            onActivated: Notifications.setDnd(false)

                            Icon {
                                size: Tokens.menubarIconSize
                                heavy: true
                                color: win.barText
                                name: "moon"
                            }
                        }

                        // Input menu: the input source in use; its menu lists the sources and Open Keyboard Settings….
                        BarButton {
                            id: inputButton
                            menuKind: "input"
                            objectName: "menubar-input"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            visible: win.showInput
                            accessibleName: qsTr("Input source: %1").arg(InputSource.shortLabel)
                            active: win.isOpen("input")
                            onActivated: win.popup("input")
                            opensMenu: true
                            onEntered: win.hoverSwitch("input")

                            Text {
                                textFormat: Text.PlainText
                                text: InputSource.shortLabel
                                color: win.barText
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyMenuSize
                                font.weight: Tokens.typographyMenuWeight
                            }
                        }

                        BarButton {
                            id: networkButton
                            visible: Settings.menubarShowWifi
                            menuKind: "network"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            accessibleName: qsTr("Network: %1").arg(Connectivity.description)
                            active: win.isOpen("network")
                            onActivated: win.popup("network")
                            opensMenu: true
                            onEntered: win.hoverSwitch("network")

                            Icon {
                                size: Connectivity.iconName.indexOf("wifi") === 0 ? Tokens.menubarIconSize * Tokens.menubarWifiIconScale : Tokens.menubarIconSize
                                heavy: true
                                color: win.barText
                                name: Connectivity.iconName
                            }
                        }

                        BarButton {
                            id: volumeButton
                            visible: Settings.menubarShowSound
                            menuKind: "volume"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            accessibleName: qsTr("Volume: %1%").arg(Math.round(Audio.volume * 100))
                            active: win.isOpen("volume")
                            onActivated: win.popup("volume")
                            opensMenu: true
                            onEntered: win.hoverSwitch("volume")
                            onScrolled: delta => Audio.adjust(delta > 0 ? 0.05 : -0.05)

                            Icon {
                                size: Tokens.menubarIconSize * Tokens.menubarVolumeIconScale
                                heavy: true
                                color: win.barText
                                name: Audio.iconName
                            }
                        }

                        BarButton {
                            id: batteryButton
                            menuKind: "battery"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            visible: win.showBattery
                            accessibleName: qsTr("Battery %1%").arg(win.battery ? Math.round(win.battery.percentage * 100) : 0)
                            active: win.isOpen("battery")
                            onActivated: win.popup("battery")
                            opensMenu: true
                            onEntered: win.hoverSwitch("battery")

                            Icon {
                                size: Tokens.menubarIconSize
                                heavy: true
                                color: win.barText
                                name: win.battery && win.battery.state === UPowerDeviceState.Charging ? "battery-charging" : "battery"
                            }

                            Text {
                                textFormat: Text.PlainText
                                visible: Settings.menubarShowBatteryPercentage
                                text: win.battery ? qsTr("%1%").arg(Math.round(win.battery.percentage * 100)) : ""
                                color: win.barText
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyMenuSize
                                font.weight: Tokens.typographyMenuWeight
                            }
                        }

                        // Search (macOS shows the Spotlight magnifier by default): toggles Search, not a menu.
                        BarButton {
                            id: searchButton
                            objectName: "menubar-search"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            visible: Settings.menubarShowSearch && !win.hiddenStatus.search
                            accessibleName: qsTr("Search")
                            active: root.searchActive
                            onActivated: root.searchRequested()

                            Icon {
                                size: Tokens.menubarIconSize
                                heavy: true
                                color: win.barText
                                name: "search"
                            }
                        }

                        BarButton {
                            id: ccButton
                            menuKind: "controlcenter"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            accessibleName: qsTr("Quick Settings")
                            active: win.isOpen("controlcenter")
                            onActivated: win.popup("controlcenter")
                            opensMenu: true
                            onEntered: win.hoverSwitch("controlcenter")

                            Icon {
                                size: Tokens.menubarIconSize
                                heavy: true
                                color: win.barText
                                name: "control-center"
                            }
                        }

                        BarButton {
                            id: clockButton
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            highlightOutset: Tokens.menubarHighlightOutset
                            leftPadding: Tokens.menubarStatusItemPadding
                            accessibleName: qsTr("Date and time: %1. Open Notifications").arg(win.clockString(win.clockDateShown, false))
                            active: Notifications.centerOpen && Notifications.centerScreen === (win.screen ? win.screen.name : "")
                            onActivated: Notifications.toggleCenter(win.screen.name)

                            // A steady width (LOW, UI audit 2026-11-05): tabular figures, so the time keeps its width from
                            // second to second, and on the dark beat of the flashing separators the colons turn
                            // invisible instead of becoming spaces, so they keep their advance. The time is drawn
                            // character by character as plain text (no rich text); clockText's font is the metrics' too.
                            Row {
                                Text {
                                    id: clockText
                                    textFormat: Text.PlainText
                                    text: win.clockShownParts.date !== "" ? win.clockShownParts.date + Tokens.menubarClockGap : ""
                                    visible: text !== ""
                                    color: win.barText
                                    font.family: Appearance.fontFamily
                                    font.pixelSize: Tokens.typographyMenuSize
                                    font.weight: Tokens.typographyMenuWeight
                                    font.features: {
                                        "tnum": 1
                                    }
                                }

                                Repeater {
                                    model: String(win.clockShownParts.time).split("")

                                    Text {
                                        required property string modelData
                                        textFormat: Text.PlainText
                                        text: modelData
                                        color: modelData === ":" && win.clockFlashOff ? "transparent" : win.barText
                                        font: clockText.font
                                    }
                                }
                            }
                        }
                    }
            }

            // The screen-sharing indicator while the bar is away (pinnedShareOpacity, ADR-0035 7-14): the status item's glyph on
            // a capsule of the band's glass, where a status item's capsule sits, at the bar's right inset. Never dimmed with an
            // inactive display's bar; it takes no input (the edge strip still brings the bar, and its status item, back).
            Material {
                id: pinnedShare
                anchors.right: parent.right
                anchors.rightMargin: Tokens.menubarInsetRight - Tokens.menubarStatusItemPadding
                y: Tokens.menubarHoverInsetTop
                width: win.statusIconWidth
                height: Tokens.menubarHeight - Tokens.menubarHoverInsetTop - Tokens.menubarHoverInsetBottom
                radius: height / 2
                opacity: win.pinnedShareOpacity
                visible: win.pinnedShareOpacity > 0
                glassClass: "menu"
                backdropRect: Qt.rect(x, y, width, height)
                tintAlphaOverride: win.band ? win.band.alpha : -1
                tintColor: win.band ? win.band.colors.materialTint : Appearance.colors.materialTint
                shadowEnabled: false
                Accessible.role: Accessible.Indicator
                Accessible.name: qsTr("Screen Sharing")
                Accessible.ignored: !visible

                Icon {
                    anchors.centerIn: parent
                    size: Tokens.menubarIconSize
                    heavy: true
                    color: win.barText
                    name: "screen-share"
                }
            }
        }
    }
}
