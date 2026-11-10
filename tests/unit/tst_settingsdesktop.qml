import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings > Desktop & Dock as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Desktop & Dock): Size and
// Magnification side by side at the measured places, Magnification as one slider from Off through Small to Large, the rows of
// the capture writing their keys, Show items as a check box, and the Screen Corners sheet. The store is a fake.
TestCase {
    id: testCase
    name: "SettingsDesktop"
    width: 508
    height: 1600
    visible: true
    when: windowShown

    Component {
        id: storeComponent
        QtObject {
            property var values: Object.assign({}, SettingsContract.ALL_DEFAULTS)
            property var writes: []
            function value(key: string): var {
                return values[key];
            }
            function setMany(entries: var): bool {
                writes.push(entries);
                values = Object.assign({}, values, entries);
                return true;
            }
            function set(key: string, v: var): bool {
                const e = {};
                e[key] = v;
                return setMany(e);
            }
        }
    }

    Component {
        id: pageComponent
        SettingsQml.DesktopPage {
            width: 508
            height: 1600
        }
    }

    Component {
        id: sheetComponent
        SettingsQml.ScreenCornersSheet {
            anchors.fill: parent
        }
    }

    function make() {
        const store = createTemporaryObject(storeComponent, testCase);
        const page = createTemporaryObject(pageComponent, testCase, {store: store});
        verify(page);
        return {store: store, page: page};
    }

    function find(item, pred) {
        if (!item)
            return null;
        if (pred(item))
            return item;
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++) {
            const hit = find(kids[i], pred);
            if (hit)
                return hit;
        }
        if (item.contentItem && item.contentItem !== item) {
            const hit = find(item.contentItem, pred);
            if (hit)
                return hit;
        }
        return null;
    }

    function named(root, name) {
        return find(root, i => i.accessibleName === name);
    }

    function last(store) {
        return store.writes[store.writes.length - 1];
    }

    function test_slidersSideBySide() {
        const t = make();
        waitForRendering(t.page);
        const size = named(t.page.contentItem, "Size");
        const magnification = named(t.page.contentItem, "Magnification");
        verify(size && magnification);
        const group = size.parent.parent.parent;
        compare(group.height, Tokens.settingsDockSlidersHeight);
        compare(size.parent.x, Tokens.settingsRowInset);
        compare(size.width, Tokens.settingsDockSizeSliderWidth);
        compare(magnification.parent.x, Tokens.settingsDockMagnificationX);
        compare(magnification.width, 468 - Tokens.settingsDockMagnificationX - Tokens.settingsRowInset);
        compare(size.y + size.height / 2, Tokens.settingsDockSliderCenter);
        // Ticks at the knob's two extremes for Size; at Small and Large for Magnification.
        compare(size.dots, [0, 1]);
        compare(magnification.dots, [Tokens.settingsDockMagnificationSmallAt, 1]);
    }

    function test_sizeWritesWholePixels() {
        const t = make();
        const size = named(t.page.contentItem, "Size");
        compare(size.value, 48);
        size.moved(61.4);
        compare(last(t.store), {"dock.size": 61});
    }

    function test_magnificationOffSmallLarge() {
        const t = make();
        const m = named(t.page.contentItem, "Magnification");
        // Off by default: the knob at the start.
        compare(m.value, 0);
        m.moved(1);
        compare(last(t.store), {"dock.magnificationEnabled": true, "dock.magnification": 2.5});
        compare(m.value, 1);
        // Between Off and Small: the nearer of the two.
        m.moved(Tokens.settingsDockMagnificationSmallAt * 0.6);
        compare(last(t.store), {"dock.magnificationEnabled": true, "dock.magnification": Tokens.settingsDockMagnificationSmall});
        compare(m.value, Tokens.settingsDockMagnificationSmallAt);
        m.moved(Tokens.settingsDockMagnificationSmallAt * 0.4);
        compare(last(t.store), {"dock.magnificationEnabled": false});
        compare(m.value, 0);
        // A stored magnification is shown on the Small-Large stretch (the default 1.6 included).
        t.store.setMany({"dock.magnificationEnabled": true, "dock.magnification": 1.6});
        const small = Tokens.settingsDockMagnificationSmall;
        fuzzyCompare(m.value, Tokens.settingsDockMagnificationSmallAt + (1 - Tokens.settingsDockMagnificationSmallAt) * (1.6 - small) / (2.5 - small), 1e-9);
    }

    function test_dockRows() {
        const t = make();
        const position = named(t.page.contentItem, "Dock position on screen");
        verify(position.inline);
        position.picked("left");
        compare(last(t.store), {"dock.position": "left"});
        named(t.page.contentItem, "Minimized window animation").picked("shrink");
        compare(last(t.store), {"dock.minimizeEffect": "shrink"});
        named(t.page.contentItem, "Window title bar double-click action").picked("minimize");
        compare(last(t.store), {"windows.titlebarDoubleClick": "minimize"});
        const toggles = [["Minimize windows into application icon", "dock.minimizeIntoApp"], ["Automatically hide and show the Dock", "dock.autohide"], ["Click an open app’s icon to minimize its windows", "dock.clickMinimizes"], ["Animate opening applications", "dock.animateOpening"], ["Show indicators for open applications", "dock.showIndicators"], ["Show recent apps in Dock", "dock.showRecents"], ["Show End Task in Dock menus", "dock.endTask"]];
        for (const [name, key] of toggles) {
            const toggle = named(t.page.contentItem, name);
            verify(toggle, name);
            toggle.toggled(!toggle.checked);
            compare(last(t.store)[key], t.store.value(key), name);
        }
    }

    // The owner's question (2026-11-07): whether apps stay in the Dock after they quit. The macOS switch answers it; its row says
    // so under the title, and turning it off writes dock.showRecents false (the Dock drops the recent section at once).
    function test_recentAppsRowSaysAppsStayAfterTheyQuit() {
        const t = make();
        const row = find(t.page.contentItem, i => i.title === "Show recent apps in Dock" && i.subtitle !== undefined);
        verify(row, "the row");
        compare(row.subtitle, "Apps you quit that are not kept in the Dock stay in their own section until newer ones replace them.");
        const toggle = named(t.page.contentItem, "Show recent apps in Dock");
        verify(toggle.checked, "on by default, as macOS");
        toggle.toggled(false);
        compare(last(t.store), {"dock.showRecents": false});
        compare(toggle.checked, false);
    }

    // TL32: the tiling switches in their order, each writing its key, under the compositor extension's footnote; the
    // double-click action offers Fill first.
    function test_windowsRows() {
        const t = make();
        const rows = [["Drag windows to left or right edge of screen to tile", "windows.tilingEdges"], ["Drag windows to menu bar to fill screen", "windows.tilingMenuBar"], ["Hold Alt key while dragging windows to tile", "windows.tilingOptionDrag"], ["Tiled windows have margins", "windows.tilingMargins"], ["Show layouts when hovering over the green button", "windows.tilingLayouts"], ["Suggest windows to fill the rest of a layout", "windows.tilingSuggestions"], ["Bring tile groups forward together", "windows.tilingGroups"], ["Rebuild the compositor extension after Hyprland updates", "windows.rebuildExtension"]];
        let above = -1;
        for (const [name, key] of rows) {
            const toggle = named(t.page.contentItem, name);
            verify(toggle, name);
            const y = toggle.mapToItem(t.page.contentItem, 0, 0).y;
            verify(y > above, name + " comes after the row above it");
            above = y;
            compare(toggle.checked, SettingsContract.ALL_DEFAULTS[key], name);
            toggle.toggled(!toggle.checked);
            const e = {};
            e[key] = !SettingsContract.ALL_DEFAULTS[key];
            compare(last(t.store), e, name);
            compare(toggle.checked, !SettingsContract.ALL_DEFAULTS[key], name + " shows the stored value");
        }
        const group = find(t.page.contentItem, i => i.caption === "Windows" && i.footnote !== undefined);
        verify(group);
        compare(group.footnote, "Needs the Grassfield compositor extension.");
        const action = named(t.page.contentItem, "Window title bar double-click action");
        compare(action.model.map(m => m.id), ["fill", "zoom", "minimize", "none"]);
        compare(action.model.map(m => m.text), ["Fill", "Zoom", "Minimize", "No Action"], "macOS 27's names (parity matrix M40)");
        action.picked("fill");
        compare(last(t.store), {"windows.titlebarDoubleClick": "fill"});
    }

    // M38: the Alt row names the key as the menus do (keyboard.shortcutStyle): its symbol in the macOS style.
    function test_optionDragLabelFollowsShortcutStyle() {
        const before = Appearance.shortcutStyle;
        try {
            const t = make();
            Appearance.shortcutStyle = "mac";
            verify(!named(t.page.contentItem, "Hold Alt key while dragging windows to tile"));
            const mac = named(t.page.contentItem, "Hold ⌥ key while dragging windows to tile");
            verify(mac);
            mac.toggled(false);
            compare(last(t.store), {"windows.tilingOptionDrag": false});
            Appearance.shortcutStyle = "pc";
            verify(named(t.page.contentItem, "Hold Alt key while dragging windows to tile"));
            verify(!named(t.page.contentItem, "Hold ⌥ key while dragging windows to tile"));
        } finally {
            Appearance.shortcutStyle = before;
        }
    }

    // Settings' own search (Main.qml's sections) and the shell's Search (Search.qml's pages) find Desktop & Dock for the tiling
    // words (integrator review of 1c08d6b, MINOR 5): read from the sources, the Desktop & Dock entry of each.
    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    function test_searchWordsFindTiling() {
        const settingsLine = source("apps/settings/qml/Main.qml").split("\n").find(l => l.indexOf('{id: "desktop"') >= 0);
        verify(settingsLine, "Main.qml: the desktop section");
        const words = /keywords: qsTr\("([^"]*)"\)/.exec(settingsLine)[1].split(" ");
        for (const w of ["tile", "tiling", "layouts"])
            verify(words.indexOf(w) >= 0, "Settings' search finds Desktop & Dock for " + w);
        const searchLine = source("shell/search/Search.qml").split("\n").find(l => l.indexOf('{id: "desktop"') >= 0);
        verify(searchLine, "Search.qml: the desktop page");
        for (const w of ["tile", "tiling", "layouts"])
            verify(searchLine.indexOf('qsTr("' + w + '")') >= 0, "the shell's Search finds Desktop & Dock for " + w);
    }

    function test_showItemsOnDesktop() {
        const t = make();
        const box = named(t.page.contentItem, "Show items on the desktop");
        verify(box);
        compare(box.text, "On Desktop");
        verify(box.checked);
        mouseClick(box);
        compare(last(t.store), {"desktop.showIcons": false});
    }

    function test_screenCorners() {
        const t = make();
        const button = find(t.page.contentItem, i => i.text === "Screen Corners…" && i.clicked !== undefined);
        verify(button);
        let asked = 0;
        t.page.screenCornersRequested.connect(() => asked++);
        button.clicked();
        compare(asked, 1);
        const sheet = createTemporaryObject(sheetComponent, testCase, {store: t.store});
        sheet.open();
        const corners = ["Top left corner", "Top right corner", "Bottom left corner", "Bottom right corner"];
        const keys = ["topLeft", "topRight", "bottomLeft", "bottomRight"];
        for (let i = 0; i < corners.length; i++) {
            const box = named(sheet, corners[i]);
            verify(box, corners[i]);
            compare(box.model.map(m => m.id), ["none", "overview", "notifications", "apps", "lock"]);
            box.picked("overview");
            compare(last(t.store), {["hotCorners." + keys[i]]: "overview"});
        }
    }

    Component {
        id: dockSliderComponent
        SettingsQml.DockSlider {
            x: Tokens.settingsDockMagnificationX
            width: 250
            height: Tokens.settingsDockSlidersHeight
            title: "Magnification"
            // French-sized labels: "Désactivé" is wider than the room between its place and Small's.
            labels: [{text: "Désactivé", at: 0}, {text: "Petit", at: Tokens.settingsDockMagnificationSmallAt}, {text: "Grand", at: 1}]
        }
    }

    // The end labels never overlap, whatever the language: each starts after the one before it plus a gap, in a long
    // language as in English.
    function test_sliderLabelsNeverOverlap() {
        const slider = createTemporaryObject(dockSliderComponent, testCase);
        verify(slider);
        waitForRendering(slider);
        const texts = ["Désactivé", "Petit", "Grand"].map(w => find(slider, i => i.text === w && i.baselineOffset !== undefined));
        for (const t of texts)
            verify(t);
        for (let i = 1; i < texts.length; i++)
            verify(texts[i].x >= texts[i - 1].x + texts[i - 1].width + Tokens.settingsDockSliderLabelGap, "label " + i + " starts at " + texts[i].x + " after " + (texts[i - 1].x + texts[i - 1].width));
        verify(texts[2].x + texts[2].width <= slider.width, "the last label stays inside the track's end");
    }

    // Short labels keep their measured places (macOS: Small centred under its tick), at the real 220 as at 250, and after a
    // resize (the slider's travel changes after this item's width).
    function test_sliderLabelsKeepTheirPlaces() {
        const slider = createTemporaryObject(dockSliderComponent, testCase);
        slider.labels = [{text: "Off", at: 0}, {text: "Small", at: Tokens.settingsDockMagnificationSmallAt}, {text: "Large", at: 1}];
        for (const w of [250, 220, 300]) {
            slider.width = w;
            waitForRendering(slider);
            wait(50);
            const small = find(slider, i => i.text === "Small" && i.baselineOffset !== undefined);
            verify(small && small.visible);
            const centre = slider.slider.knobWidth / 2 + Tokens.settingsDockMagnificationSmallAt * slider.slider.travel;
            verify(Math.abs(small.x + small.width / 2 - centre) <= 1, "width " + w + ": English Small stays centred on its place (" + (small.x + small.width / 2) + " vs " + centre + ")");
        }
    }

    // At Settings' minimum window width the slider is only 40 wide: no label leaves the track and none overlaps another (a
    // label that cannot fit whole is left out), in French and English; the real 220 shows them all.
    function test_sliderLabelsInsideTheTrackAtTheMinimumWidth() {
        const sets = [["Désactivé", "Petit", "Grand"], ["Off", "Small", "Large"]];
        for (const names of sets) {
            const slider = createTemporaryObject(dockSliderComponent, testCase);
            slider.labels = [{text: names[0], at: 0}, {text: names[1], at: Tokens.settingsDockMagnificationSmallAt}, {text: names[2], at: 1}];
            for (const w of [40, 220]) {
                slider.width = w;
                waitForRendering(slider);
                wait(50);
                const shown = names.map(n => find(slider, i => i.text === n && i.baselineOffset !== undefined)).filter(t => t && t.visible);
                for (const t of shown)
                    verify(t.x >= 0 && t.x + t.width <= w, names[0] + " at " + w + ": " + t.text + " " + t.x + " to " + (t.x + t.width) + " leaves the track");
                for (let i = 1; i < shown.length; i++)
                    verify(shown[i].x >= shown[i - 1].x + shown[i - 1].width + Tokens.settingsDockSliderLabelGap, names[0] + " at " + w + ": " + shown[i].text + " overlaps " + shown[i - 1].text);
                if (w === 220)
                    compare(shown.length, 3);
            }
        }
    }

    // ---- Default web browser (ADR-0055 D-6) ----------------------------------------------------------------------------
    // A backend on a map of files: the applications folder, the config folder and the state folder.
    Component {
        id: fakeBackendComponent
        QtObject {
            property string xdgConfigDir: "/cfg"
            property string grassfieldStateDir: "/state"
            property var applicationDirs: ["/apps"]
            property var currentDesktops: ["Grassfield", "Hyprland"]
            property var unreadable: []
            property var files: ({})
            property bool failState: false
            property var writes: []
            function desktopEntries(dir: string): var {
                const out = [];
                for (const path of Object.keys(files)) {
                    if (path.indexOf(dir + "/") === 0 && path.slice(dir.length + 1).indexOf("/") < 0 && path.endsWith(".desktop"))
                        out.push(path.slice(dir.length + 1));
                }
                return out.sort();
            }
            function readText(path: string): var {
                if (unreadable.indexOf(path) >= 0)
                    return {exists: true, ok: false, text: ""};
                return files[path] === undefined ? {exists: false, ok: false, text: ""} : {exists: true, ok: true, text: files[path]};
            }
            function writeDefaultAppsFile(path: string, text: string): string {
                if (failState && path.indexOf("/state/") === 0)
                    return "disk full";
                writes.push(path);
                const next = Object.assign({}, files);
                next[path] = text;
                files = next;
                return "";
            }
        }
    }

    function entry(name, exec, extra) {
        return "[Desktop Entry]\nType=Application\nName=" + name + "\nExec=" + exec + "\nCategories=Network;WebBrowser;\n"
            + "MimeType=x-scheme-handler/http;x-scheme-handler/https;text/html;\n" + (extra || "");
    }

    function browserFiles() {
        return {
            "/apps/sanaga.desktop": entry("Sanaga", "sanaga %U"),
            "/apps/chromium.desktop": entry("Chromium", "chromium %U"),
            "/apps/firefox.desktop": entry("Firefox", "firefox %u"),
            "/apps/omarchy-browser.desktop": entry("Browser", "omarchy-launch-browser %U"),
            "/apps/evil.desktop": entry("Evil", "xdg-open %u"),
            "/apps/launcher2.desktop": entry("Launcher", "/usr/bin/omarchy-launch-browser %U"),
            "/apps/hidden.desktop": entry("Hidden", "hidden %U", "NoDisplay=true\n"),
            // Each filter of the offer has its own entry that only it keeps out: a browser that is no WebBrowser, one that does not
            // handle http or https, a quoted launcher, a launcher behind uwsm; and a real browser behind uwsm that stays.
            "/apps/nocat.desktop": "[Desktop Entry]\nType=Application\nName=NoCategory\nExec=nocat %U\nCategories=Network;\nMimeType=x-scheme-handler/http;x-scheme-handler/https;\n",
            "/apps/nohttp.desktop": "[Desktop Entry]\nType=Application\nName=NoHttp\nExec=nohttp %U\nCategories=Network;WebBrowser;\nMimeType=text/html;\n",
            "/apps/quoted.desktop": entry("Quoted", "\"/usr/bin/xdg-open\" %u"),
            "/apps/uwsmlauncher.desktop": entry("UwsmLauncher", "uwsm app -- xdg-open %u"),
            "/apps/uwsmapp.desktop": entry("UwsmApp", "uwsm-app -- omarchy-launch-browser %U"),
            "/apps/zen.desktop": entry("Zen", "uwsm app -- zen-browser %u"),
            "/apps/editor.desktop": "[Desktop Entry]\nType=Application\nName=Editor\nExec=editor %F\nCategories=Utility;\nMimeType=text/plain;\n",
            "/cfg/mimeapps.list": "[Default Applications]\ntext/html=chromium.desktop\nx-scheme-handler/http=chromium.desktop\nx-scheme-handler/https=chromium.desktop\n"
                + "x-scheme-handler/mailto=HEY.desktop\n",
            "/cfg/hyprland-mimeapps.list": "[Default Applications]\nx-scheme-handler/http=omarchy-browser.desktop\nx-scheme-handler/https=omarchy-browser.desktop\n"
        };
    }

    function makeWithBackend(files) {
        const backend = createTemporaryObject(fakeBackendComponent, testCase, {files: files});
        const store = createTemporaryObject(storeComponent, testCase);
        const page = createTemporaryObject(pageComponent, testCase, {store: store, backend: backend});
        verify(page);
        return {backend: backend, page: page};
    }

    // Only the installed browsers are offered, and never Omarchy's routing entry or an entry whose Exec is a launcher that
    // resolves the default again; the current one is read from the lists (the routing entry left out).
    function test_defaultBrowserOffersBrowsersOnly() {
        const t = makeWithBackend(browserFiles());
        compare(t.page.browserChoices.map(b => b.id).join(","), "chromium.desktop,firefox.desktop,sanaga.desktop,zen.desktop");
        compare(t.page.browserCurrent, "chromium.desktop");
        const box = named(t.page.contentItem, "Default web browser");
        verify(box, "the row is there");
    }

    function test_defaultBrowserRowIsHiddenWithoutBackend() {
        const t = make();
        compare(t.page.browserChoices.length, 0);
        verify(!named(t.page.contentItem, "Default web browser") || !named(t.page.contentItem, "Default web browser").visible);
    }

    // The row writes the session's list (the four web types, the other lines kept) and records the choice as the user's.
    function test_defaultBrowserWritesTheListAndTheRecord() {
        const files = browserFiles();
        files["/cfg/grassfield-mimeapps.list"] = "# mine\n[Default Applications]\ninode/directory=org.grassfield.Files.desktop;\ntext/html=old.desktop;\n";
        files["/state/default-apps.state"] = "notes.state=seeded\nnotes.text/markdown=-\n";
        const t = makeWithBackend(files);
        named(t.page.contentItem, "Default web browser").picked("sanaga.desktop");
        const list = t.backend.files["/cfg/grassfield-mimeapps.list"];
        compare(list, "# mine\n[Default Applications]\ninode/directory=org.grassfield.Files.desktop;\ntext/html=sanaga.desktop;\nx-scheme-handler/http=sanaga.desktop;\n"
            + "x-scheme-handler/https=sanaga.desktop;\napplication/xhtml+xml=sanaga.desktop;\n");
        const state = t.backend.files["/state/default-apps.state"];
        verify(state.indexOf("web.state=user\n") >= 0, "recorded as the user's: " + state);
        verify(state.indexOf("web.chosen=sanaga.desktop\n") >= 0, "the choice is recorded: " + state);
        verify(state.indexOf("web.x-scheme-handler/http=chromium.desktop\n") >= 0 && state.indexOf("web.text/html=chromium.desktop\n") >= 0,
               "the baseline is what the user's own lists name (the routing entry left out): " + state);
        verify(state.indexOf("web.application/xhtml+xml=-\n") >= 0, "a type no list names is recorded as nothing: " + state);
        verify(state.indexOf("notes.state=seeded\n") >= 0 && state.indexOf("notes.text/markdown=-\n") >= 0, "the other group's record is kept");
        compare(t.page.browserCurrent, "sanaga.desktop");
        compare(t.backend.files["/cfg/mimeapps.list"], browserFiles()["/cfg/mimeapps.list"], "the user's mimeapps.list is never written");
        // Chromium again (stock Omarchy's browser): written all the same, as the user's choice.
        named(t.page.contentItem, "Default web browser").picked("chromium.desktop");
        verify(t.backend.files["/cfg/grassfield-mimeapps.list"].indexOf("x-scheme-handler/https=chromium.desktop;\n") > 0);
        verify(t.backend.files["/state/default-apps.state"].indexOf("web.state=user\n") >= 0);
    }

    // No launcher is ever chosen, nothing outside the offered list either; a record that cannot be written leaves the list as it was.
    function test_defaultBrowserNeverChoosesALauncherOrFailsHalfWay() {
        const t = makeWithBackend(browserFiles());
        for (const id of ["omarchy-browser.desktop", "evil.desktop", "launcher2.desktop", "hidden.desktop", "editor.desktop", "../x.desktop", "sanaga",
                          "nocat.desktop", "nohttp.desktop", "quoted.desktop", "uwsmlauncher.desktop", "uwsmapp.desktop"])
            verify(!t.page.setBrowser(id), id + " is refused");
        compare(t.backend.writes.length, 0, "nothing was written");
        t.backend.failState = true;
        verify(!t.page.setBrowser("sanaga.desktop"));
        compare(t.backend.writes.length, 0, "the record failed first: the list is untouched");
        compare(t.page.browserCurrent, "chromium.desktop");
    }

    // A failed pick shows a short sentence under the row (Grassfield.Ui row subtitle) and leaves the lists as they were; the next
    // successful pick clears it. A list that is not valid UTF-8 (the backend answers ok false) is never rewritten.
    function test_defaultBrowserShowsAShortErrorOnFailure() {
        const t = makeWithBackend(browserFiles());
        t.backend.failState = true;
        verify(!t.page.setBrowser("sanaga.desktop"));
        verify(t.page.browserError !== "", "the page says it failed");
        const shown = find(t.page.contentItem, i => i.text === t.page.browserError && i.visible === true);
        verify(shown, "and the sentence is on screen");
        t.backend.failState = false;
        verify(t.page.setBrowser("sanaga.desktop"));
        compare(t.page.browserError, "");
        // not UTF-8: refused, no write at all
        const u = makeWithBackend(browserFiles());
        u.backend.unreadable = ["/cfg/mimeapps.list"];
        verify(!u.page.setBrowser("sanaga.desktop"));
        verify(u.page.browserError !== "");
        compare(u.backend.writes.length, 0);
        const v = makeWithBackend(browserFiles());
        v.backend.unreadable = ["/cfg/grassfield-mimeapps.list"];
        verify(!v.page.setBrowser("sanaga.desktop"));
        compare(v.backend.writes.length, 0);
    }
}
