import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings > Wallpaper as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Wallpaper): the preview and the
// group of the current wallpaper's options at the measured places, a line across the pane, then sections of fixed tiles in
// one row with Show All, add tiles first, the chosen tile in its ring, and the choices written to their keys. The backend is a
// fake: nothing runs, nothing is read from the machine.
TestCase {
    id: testCase
    name: "SettingsWallpaper"
    width: 508
    height: 1400
    visible: true
    when: windowShown

    readonly property var pictures: ["Dunes", "Harbour", "Pine", "Glacier", "Lavender", "Market", "Reef", "Fog", "Canyon", "Salt", "Lights", "Terraces"].map(n => "/home/u/Pictures/" + n + ".jpg")

    Component {
        id: backendComponent
        QtObject {
            property bool devSession: false
            property string devRoot: ""
            property string wallpaperTool: "/usr/lib/grassfield/grassfield-wallpaper"
            property string wallpaperCache: "/home/u/.cache/grassfield/wallpapers"
            property string picturesDir: "/home/u/Pictures"
            property string wallpaperPhotosDir: ""
            property string wallpaperStatusFile: "/run/user/1000/grassfield/wallpaper-state.json"
            property string wallpaperRecentFile: "/home/u/.local/state/grassfield/wallpaper-recent.json"
            property var files: ({})
            property var queries: []
            property var screenList: [{name: "eDP-1", model: "Panel", serial: "1", primary: true, pixelWidth: 2560, pixelHeight: 1600}]
            signal finished(string tag, bool ok, string output)
            signal fileChanged(string path)
            function screens(): var {
                return screenList;
            }
            function watch(p: string): bool {
                return true;
            }
            function readText(p: string): var {
                return files[p] !== undefined ? {exists: true, ok: true, text: files[p]} : {exists: false, ok: true, text: ""};
            }
            function writeText(p: string, t: string): string {
                files[p] = t;
                return "";
            }
            function query(argv: var, tag: string, timeout: int): void {
                queries.push({argv: argv, tag: tag});
            }
            function act(what: string, argv: var, tag: string): bool {
                return false;
            }
        }
    }

    Component {
        id: storeComponent
        QtObject {
            property var values: ({
                    "wallpaper.source": "builtin",
                    "wallpaper.path": "",
                    "wallpaper.color": "#1F6FEB",
                    "wallpaper.fit": "fill",
                    "wallpaper.interval": "1h",
                    "wallpaper.shuffle": false,
                    "wallpaper.videoOnBattery": false,
                    "wallpaper.online.provider": "commons",
                    "wallpaper.artwork": "grassfield",
                    "wallpaper.artworkVariant": "timeOfDay",
                    "wallpaper.moving": false,
                    "wallpaper.outputs": []
                })
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
        SettingsQml.WallpaperPage {
            width: 508
            height: 1400
        }
    }

    function make(values, files, backendProps) {
        const backend = createTemporaryObject(backendComponent, testCase, Object.assign({files: files || {}}, backendProps || {}));
        const store = createTemporaryObject(storeComponent, testCase);
        if (values)
            store.values = Object.assign({}, store.values, values);
        const page = createTemporaryObject(pageComponent, testCase, {store: store, backend: backend});
        verify(page);
        return {backend: backend, store: store, page: page};
    }

    // The helper's answer to the listing of the Pictures folder.
    function listPictures(t) {
        t.backend.finished("wp.list", true, JSON.stringify({files: testCase.pictures}));
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
        return null;
    }

    function grid(page, title) {
        return find(page.contentItem, i => i.accessibleName === title && i.columns !== undefined && i.expandRequested !== undefined);
    }

    function last(store) {
        return store.writes[store.writes.length - 1];
    }

    function test_headerGeometry() {
        const t = make({"wallpaper.source": "file", "wallpaper.path": testCase.pictures[0]});
        waitForRendering(t.page);
        const fit = find(t.page.contentItem, i => i.accessibleName === "Fit" && i.picked !== undefined);
        verify(fit);
        verify(fit.visible);
        // The group of the options: its left edge 170 right of the preview, which is 16 from the pane's edge, 4 under the content top.
        let group = fit;
        while (group && group.caption === undefined)
            group = group.parent;
        verify(group);
        const at = group.mapToItem(t.page.contentItem, 0, 0);
        compare(at.x, Tokens.settingsWallpaperHeaderInset + Tokens.settingsWallpaperGroupX);
        compare(at.y, Tokens.settingsContentTop + Tokens.settingsWallpaperHeaderTop);
        compare(group.width, 508 - 2 * Tokens.settingsWallpaperHeaderInset - Tokens.settingsWallpaperGroupX);
        const preview = find(t.page.contentItem, i => i.width === Tokens.settingsWallpaperPreviewWidth && i.height === Tokens.settingsWallpaperPreviewHeight);
        verify(preview);
        compare(preview.mapToItem(t.page.contentItem, 0, 0).x, Tokens.settingsWallpaperHeaderInset);
        // The line across the whole pane, 25 under the preview (the group and its buttons end higher).
        const line = find(t.page.contentItem, i => i.height === 1 && i.width === t.page.width);
        verify(line);
        const lineAt = line.mapToItem(t.page.contentItem, 0, 0);
        compare(lineAt.x, 0);
        compare(lineAt.y, Tokens.settingsContentTop + Tokens.settingsWallpaperHeaderTop + Tokens.settingsWallpaperPreviewHeight + Tokens.settingsWallpaperSeparatorPreviewGap);
        // The name row shows the picture's name without its extension.
        verify(find(group, i => i.text === "Dunes"));
    }

    function test_fitAndColour() {
        const t = make({"wallpaper.source": "file", "wallpaper.path": testCase.pictures[0]});
        const fit = find(t.page.contentItem, i => i.accessibleName === "Fit" && i.picked !== undefined);
        fit.picked("fit");
        compare(last(t.store), {"wallpaper.fit": "fit"});
        // A picture that does not fill the screen: its colour row shows.
        const wells = [];
        find(t.page.contentItem, i => {
            if (i.accessibleName === "Wallpaper colour" && i.edited !== undefined)
                wells.push(i);
            return false;
        });
        compare(wells.length, 2);
        verify(wells.some(w => w.visible && w.parent.parent.visible));
        // A colour: no Fit, its well in the name row.
        t.store.set("wallpaper.source", "color");
        verify(!fit.visible);
        verify(wells[0].visible);
    }

    function test_firstSectionUnderTheLine() {
        const t = make();
        waitForRendering(t.page);
        const art = grid(t.page, "Grassfield");
        verify(art);
        const line = find(t.page.contentItem, i => i.height === 1 && i.width === t.page.width);
        // The tiles: wallpaperTitleBaseline + wallpaperTilesTop under the line's top, at the groups' left edge.
        const at = art.mapToItem(t.page.contentItem, 0, 0);
        compare(at.y - line.mapToItem(t.page.contentItem, 0, 0).y, Tokens.settingsWallpaperTitleBaseline + Tokens.settingsWallpaperTilesTop);
        compare(at.x, Tokens.settingsContentMargin);
        art.activated(0);
        compare(last(t.store), {"wallpaper.source": "builtin", "wallpaper.artwork": "grassfield"});
    }

    // ADR-0040 step 2: the four artworks, each tile in the current appearance; the chosen one's variant beside its name.
    function test_theArtworks() {
        const t = make({"wallpaper.source": "builtin", "wallpaper.artwork": "grassfield", "wallpaper.artworkVariant": "timeOfDay"});
        const art = grid(t.page, "Grassfield");
        compare(art.model.map(m => m.label), ["Grassfield", "Meadow", "Field Rows", "Ridgeline"]);
        compare(art.model.map(m => m.selected), [true, false, false, false]);
        const set = Appearance.dark ? "dark" : "light";
        compare(art.model.map(m => m.variant), [set === "dark" ? "evening.dark" : "day.light", set, set, set]);
        // The variant pop-up: Time of Day for the Grassfield artwork only.
        const pop = find(t.page.contentItem, i => i.accessibleName === "Appearance of the wallpaper" && i.picked !== undefined);
        verify(pop && pop.visible);
        compare(pop.model.map(m => m.id), ["timeOfDay", "automatic", "light", "dark"]);
        compare(pop.value, "timeOfDay");
        pop.picked("dark");
        compare(last(t.store), {"wallpaper.artworkVariant": "dark"});
        // Another artwork: its name heads the group, no Time of Day, and Time of Day reads as Automatic there.
        art.activated(1);
        compare(last(t.store), {"wallpaper.source": "builtin", "wallpaper.artwork": "meadow"});
        t.store.set("wallpaper.artworkVariant", "timeOfDay");
        compare(t.page.headline, "Meadow");
        compare(pop.model.map(m => m.id), ["automatic", "light", "dark"]);
        compare(pop.value, "automatic");
        // A picture: no variant pop-up.
        t.page.usePicture(testCase.pictures[0]);
        verify(!pop.visible);
    }

    // ADR-0040 step 9: the moving clouds, for the Grassfield artwork only, off by default.
    function test_theMovingClouds() {
        const t = make({"wallpaper.source": "builtin", "wallpaper.artwork": "grassfield"});
        const sw = find(t.page.contentItem, i => i.accessibleName === "Moving clouds" && i.toggled !== undefined);
        verify(sw && sw.visible);
        verify(!sw.checked);
        sw.toggled(true);
        compare(last(t.store), {"wallpaper.moving": true});
        verify(sw.checked);
        // Another artwork, or a picture: no switch.
        t.store.set("wallpaper.artwork", "meadow");
        verify(!sw.visible);
        t.store.set("wallpaper.artwork", "grassfield");
        verify(sw.visible);
        t.page.usePicture(testCase.pictures[0]);
        verify(!sw.visible);
    }

    function test_showAllAndThumbnails() {
        const t = make();
        listPictures(t);
        const pics = grid(t.page, "Pictures");
        verify(pics);
        compare(pics.columns, 4);
        verify(pics.overflows);
        // One row: four whole tiles and the one the pane's edge cuts, and only their thumbnails are asked for.
        compare(pics.shown, 5);
        const thumbs = () => t.backend.queries.filter(q => q.tag.indexOf("wp.thumb:") === 0).length + t.page.thumbQueue.length;
        compare(thumbs(), 5);
        const more = find(t.page.contentItem, i => i.text === "Show All (12)");
        verify(more);
        mouseClick(more);
        verify(pics.expanded);
        compare(pics.shown, 12);
        compare(pics.rows, 3);
        compare(more.text, "Show Fewer");
        compare(thumbs(), 12);
        // Each picture is asked for once, the ones already being prepared too.
        const asked = t.backend.queries.filter(q => q.tag.indexOf("wp.thumb:") === 0).map(q => q.tag).concat(t.page.thumbQueue);
        compare(asked.filter((tag, i) => asked.indexOf(tag) !== i).length, 0);
        mouseClick(more);
        verify(!pics.expanded);
    }

    function test_keyboardPastTheRowShowsAll() {
        const t = make();
        listPictures(t);
        const pics = grid(t.page, "Pictures");
        pics.forceActiveFocus();
        compare(pics.currentIndex, 0);
        for (let i = 0; i < 3; i++)
            keyClick(Qt.Key_Right);
        verify(!pics.expanded);
        keyClick(Qt.Key_Right);
        verify(pics.expanded, "the fifth tile is past the row's whole tiles");
        compare(pics.currentIndex, 4);
        keyClick(Qt.Key_Down);
        compare(pics.currentIndex, 8);
        keyClick(Qt.Key_Return);
        compare(last(t.store), {"wallpaper.source": "file", "wallpaper.path": testCase.pictures[8]});
    }

    function test_chosenTileRing() {
        const t = make({"wallpaper.source": "file", "wallpaper.path": testCase.pictures[1]});
        listPictures(t);
        const pics = grid(t.page, "Pictures");
        waitForRendering(pics);
        const rings = [];
        find(pics, i => {
            if (i.border !== undefined && i.border.width === Tokens.settingsWallpaperRingWidth && i.visible)
                rings.push(i);
            return false;
        });
        compare(rings.length, 1);
        const ring = rings[0];
        compare(ring.parent.x, pics.pitch);
        compare(ring.x, -Tokens.settingsWallpaperRingOutset);
        compare(ring.width, Tokens.settingsWallpaperTileWidth + 2 * Tokens.settingsWallpaperRingOutset);
        // The chosen picture sits inside its tile.
        const picture = find(ring.parent, i => i.inset !== undefined);
        compare(picture.inset, Tokens.settingsWallpaperChosenInset);
    }

    function test_addTilesComeFirst() {
        const files = {};
        files["/home/u/.local/state/grassfield/wallpaper-recent.json"] = JSON.stringify([{kind: "file", path: "/home/u/Pictures/Salt.jpg"}, {kind: "folder", path: "/home/u/Pictures/Travel"}, {kind: "video", path: "/home/u/Videos/Waves.mp4"}]);
        const t = make({}, files);
        const added = grid(t.page, "Folders and Pictures");
        compare(added.model.map(m => m.kind), ["add", "add", "image", "folder"]);
        compare(added.model[0].label, "Add Picture…");
        compare(added.model[1].label, "Add Folder…");
        compare(added.model[2].label, "Salt");
        compare(added.model[3].label, "Shuffle Travel");
        verify(added.named);
        added.activated(3);
        compare(last(t.store), {"wallpaper.source": "folder", "wallpaper.path": "/home/u/Pictures/Travel"});
        const videos = grid(t.page, "Videos");
        compare(videos.model.map(m => m.label), ["Add Video…", "Waves"]);
        // A row of add tiles alone has no names under it.
        const t2 = make();
        verify(!grid(t2.page, "Videos").named);
        compare(grid(t2.page, "Videos").height, Tokens.settingsWallpaperTileHeight);
    }

    function test_onlineAsksFirst() {
        const t = make();
        const online = grid(t.page, "Online");
        compare(online.model[0].fullName, "Picture of the Day (Wikimedia Commons)");
        const before = t.store.writes.length;
        online.activated(1);
        verify(t.page.disclosing);
        compare(t.page.disclosedProvider, "apod");
        compare(t.store.writes.length, before, "nothing is turned on before the user agrees");
        const use = find(t.page.contentItem, i => i.text === "Use Picture of the Day" && i.clicked !== undefined);
        verify(use);
        tryVerify(() => use.visible);
        use.clicked();
        compare(last(t.store), {"wallpaper.source": "online", "wallpaper.online.provider": "apod"});
        verify(!t.page.disclosing);
    }

    // ADR-0040 step 2c: the shipped photographs, from the list the package installs beside them (the repository's own here).
    readonly property string photosDir: "/usr/share/grassfield/wallpapers/photos"

    function photoFiles() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../packaging/arch/wallpaper-photos.json"), false);
        xhr.send();
        verify(xhr.responseText.length > 0, "packaging/arch/wallpaper-photos.json");
        const files = {};
        files[testCase.photosDir + "/photos.json"] = xhr.responseText;
        return files;
    }

    function photosSection(page) {
        return find(page.contentItem, i => i.title === "Photographs" && i.grid !== undefined);
    }

    function test_photographsAbsentWithoutTheirList() {
        const t = make({}, {}, {wallpaperPhotosDir: testCase.photosDir});
        const section = photosSection(t.page);
        verify(section);
        verify(!section.visible, "no list beside the pictures: no section");
        compare(t.page.photos.length, 0);
        // A backend without the property (an older one) reads as no photographs too.
        compare(photosSection(make().page).visible, false);
    }

    function test_photographsSection() {
        const t = make({}, photoFiles(), {wallpaperPhotosDir: testCase.photosDir});
        const section = photosSection(t.page);
        verify(section.visible);
        const photos = grid(t.page, "Photographs");
        compare(photos.model.length, 16);
        compare(photos.model[0].label, WallpaperConfig.photoName(t.page.photos[0], t.page.language));
        verify(["Golden Mist", "Brume dorée"].indexOf(photos.model[0].label) >= 0);
        // The Photographs section comes right after the Grassfield artwork.
        waitForRendering(t.page);
        const art = grid(t.page, "Grassfield");
        verify(photos.mapToItem(t.page.contentItem, 0, 0).y > art.mapToItem(t.page.contentItem, 0, 0).y);
        verify(photos.mapToItem(t.page.contentItem, 0, 0).y < grid(t.page, "Folders and Pictures").mapToItem(t.page.contentItem, 0, 0).y);
        // Only the drawn row's thumbnails are asked for, of the installed pictures.
        const asked = t.backend.queries.filter(q => q.tag.indexOf("wp.thumb:" + testCase.photosDir + "/") === 0).length + t.page.thumbQueue.filter(p => p.indexOf(testCase.photosDir + "/") === 0).length;
        compare(asked, photos.shown);
        // Chosen: a picture for the shell, not added to Folders and Pictures.
        photos.activated(2);
        compare(last(t.store), {"wallpaper.source": "file", "wallpaper.path": testCase.photosDir + "/valley-fog.jpg"});
        compare(t.backend.files["/home/u/.local/state/grassfield/wallpaper-recent.json"], undefined);
        verify(photos.model[2].selected);
        compare(t.page.headline, WallpaperConfig.photoName(t.page.photos[2], t.page.language));
        // About This Wallpaper credits it as its licence asks (CC BY 4.0 section 3(a)(1); the integrator's review of e067f26f):
        // the work's own title, the author's attribution line, the source, the licence and Grassfield's changes.
        compare(t.page.aboutEntry.title, "Zamglona dolina w Witowie w powiecie proszowickim, 20241020 0808 6322");
        compare(t.page.aboutEntry.credit, "Jakub Hałun, CC BY 4.0, via Wikimedia Commons");
        compare(t.page.aboutEntry.licenseShort, "CC BY 4.0");
        const about = find(t.page.contentItem, i => i.caption === "About This Wallpaper");
        verify(about);
        tryVerify(() => about.parent.visible);
        verify(find(about, i => i.title === "Title" && i.valueText === "Zamglona dolina w Witowie w powiecie proszowickim, 20241020 0808 6322" && i.visible));
        verify(find(about, i => i.title === "Credit" && i.valueText === "Jakub Hałun, CC BY 4.0, via Wikimedia Commons" && i.visible));
        verify(!find(about, i => i.title === "Author" && i.visible), "a photograph's row is its credit");
        verify(find(about, i => i.text === "CC BY 4.0" && i.target === "https://creativecommons.org/licenses/by/4.0/" && i.visible));
        verify(find(about, i => i.title === "Changes" && i.valueText === "Resized and re-encoded by Grassfield, metadata removed" && i.visible));
        verify(!find(about, i => i.title === "Last updated" && i.visible), "a photograph has no update time");
        // Another picture: no attribution.
        t.page.usePicture(testCase.pictures[0]);
        compare(t.page.aboutEntry, null);
        verify(!about.parent.visible);
    }

    // ---- several displays (owner 2026-11-07: "when I change the wallpaper I can't see it", ADR-0044 D-5) ----
    readonly property var twoScreens: [{name: "eDP-1", model: "Panel", serial: "", primary: true}, {name: "DP-1", model: "DELL U2720Q", serial: ""}]
    readonly property string statusFile: "/run/user/1000/grassfield/wallpaper-state.json"

    function statusOf(outputs) {
        const f = {};
        f[testCase.statusFile] = JSON.stringify({outputs: outputs, online: {}});
        return f;
    }

    function picker(page) {
        return find(page.contentItem, i => i.accessibleName === "Display" && i.picked !== undefined);
    }

    function caption(page) {
        return find(page.contentItem, i => i.objectName === "wallpaperTarget");
    }

    // The displays go by the names Settings > Displays gives them: the laptop's panel is the Built-in Display, another its model;
    // two of one model add their connectors.
    function test_displayNames() {
        const t = make({}, {}, {screenList: testCase.twoScreens});
        compare(picker(t.page).model.map(m => m.text), ["All Displays", "Built-in Display", "DELL U2720Q"]);
        const twins = make({}, {}, {screenList: [{name: "DP-1", model: "DELL U2720Q", serial: ""}, {name: "DP-2", model: "DELL U2720Q", serial: ""}]});
        compare(picker(twins.page).model.map(m => m.text), ["All Displays", "DELL U2720Q (DP-1)", "DELL U2720Q (DP-2)"]);
    }

    // The line under the picker names the displays a choice changes: under All Displays, every display but those with a wallpaper
    // of their own (which a choice there does not change); on one display, that display.
    function test_targetIsNamed() {
        const own = [{display: {name: "eDP-1", model: "Panel", serial: ""}, source: "file", path: testCase.pictures[1]}];
        const t = make({"wallpaper.outputs": own}, {}, {screenList: testCase.twoScreens});
        verify(caption(t.page).visible);
        compare(caption(t.page).text, "Changes apply to every display except Built-in Display, which has a wallpaper of its own.");
        picker(t.page).picked(t.page.displays[1].key);
        compare(caption(t.page).text, "Changes apply to DELL U2720Q only. It follows All Displays until you choose a wallpaper for it.");
        picker(t.page).picked(t.page.displays[0].key);
        compare(caption(t.page).text, "Changes apply to Built-in Display only: it has a wallpaper of its own.");
        const none = make({}, {}, {screenList: testCase.twoScreens});
        compare(caption(none.page).text, "The same wallpaper on every display. Choose a display to give it a wallpaper of its own.");
    }

    // Under All Displays the preview shows the All Displays wallpaper (a display that follows it), never the picture of a
    // display that has its own.
    function test_allDisplaysPreviewShowsAFollower() {
        const own = [{display: {name: "DP-1", model: "DELL U2720Q", serial: ""}, source: "file", path: testCase.pictures[1]}];
        const files = statusOf({
            "eDP-1": {state: "ready", source: "file", path: testCase.pictures[0], file: "/c/edp.png"},
            "DP-1": {state: "ready", source: "file", path: testCase.pictures[1], file: "/c/dp.png"}
        });
        const t = make({"wallpaper.source": "file", "wallpaper.path": testCase.pictures[0], "wallpaper.outputs": own}, files, {screenList: testCase.twoScreens});
        compare(t.page.previewFile, "/c/edp.png");
        picker(t.page).picked(t.page.displays[1].key);
        compare(t.page.previewFile, "/c/dp.png", "the display with its own wallpaper shows it");
    }

    // A picture chosen shows in the preview at once (its thumbnail), before the shell has prepared it for the display; the shell's
    // picture takes over once its report names the choice.
    function test_previewShowsTheChoiceAtOnce() {
        const files = statusOf({"eDP-1": {state: "ready", source: "file", path: testCase.pictures[0], file: "/c/old.png"}});
        const t = make({"wallpaper.source": "file", "wallpaper.path": testCase.pictures[0]}, files);
        compare(t.page.previewFile, "/c/old.png");
        const thumbs = Object.assign({}, t.page.thumbs);
        thumbs[testCase.pictures[3]] = "/home/u/.cache/grassfield/wallpapers/thumbs/glacier.png";
        t.page.thumbs = thumbs;
        t.page.usePicture(testCase.pictures[3]);
        compare(t.page.previewFile, "/home/u/.cache/grassfield/wallpapers/thumbs/glacier.png", "the thumbnail while the shell prepares it");
        t.backend.files[testCase.statusFile] = JSON.stringify({outputs: {"eDP-1": {state: "ready", source: "file", path: testCase.pictures[3], file: "/c/new.png"}}});
        t.backend.fileChanged(testCase.statusFile);
        compare(t.page.previewFile, "/c/new.png", "the shell's picture once it shows the choice");
    }

    function test_photographsUnderTheDevGuard() {
        const t = make({}, photoFiles(), {wallpaperPhotosDir: testCase.photosDir, devSession: true, devRoot: "/w"});
        const before = t.store.writes.length;
        grid(t.page, "Photographs").activated(0);
        compare(t.store.writes.length, before, "outside the worktree's .dev in a dev session: refused");
        verify(t.page.refusal !== "");
    }
}
