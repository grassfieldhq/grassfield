pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.platform

// What lies behind the shell's glass on each output (ADR-0024 section 2 point 3, G-3; owner decision 2026-10-26: the adaptive
// tint first). An output is known only while it shows the bare desktop (no window on its active workspace,
// Compositor.bareOutputs) over a wallpaper whose luminance range is known (reported by shell/desktop/Wallpaper.qml).
// Appearance.backdrops gets {output: {lumMin, lumMax}} for those; every other glass takes the worst case (black to white).
Singleton {
    id: root

    // {output name: {lumMin, lumMax}} of the wallpaper on screen; no entry: unknown (a video, a picture prepared before the
    // helper wrote its image statistics, the dev image override).
    property var wallpapers: ({})
    // {output name: luminance grid} of what the output shows (GlassTint.gridOf, reported by Wallpaper.qml with the range): it
    // narrows the range to the part of the output under each surface (GlassTint.gridRange). No entry: the whole range.
    property var grids: ({})

    readonly property var known: {
        const out = {};
        const bare = Compositor.bareOutputs;
        for (let i = 0; i < bare.length; i++) {
            const range = root.wallpapers[bare[i]];
            if (range)
                out[bare[i]] = root.grids[bare[i]] ? Object.assign({grid: root.grids[bare[i]]}, range) : range;
        }
        return out;
    }

    // The wallpaper under `rect` (output px) of an output, known whether or not windows are open on it (GlassTint.wallpaperUnder):
    // for a surface that always lies on the wallpaper, the menu bar's band while the bar keeps its strip. `known` above is only for
    // surfaces that can lie over windows. null when the wallpaper's range is unknown.
    function wallpaperUnder(output: string, rect: rect): var {
        return GlassTint.wallpaperUnder(root.wallpapers[output] ?? null, root.grids[output] ?? null, rect, Tokens.glassBackdropPad);
    }

    function reportGrid(output: string, grid: var): void {
        const next = Object.assign({}, root.grids);
        if (grid)
            next[output] = grid;
        else
            delete next[output];
        root.grids = next;
    }

    function reportWallpaper(output: string, range: var): void {
        const next = Object.assign({}, root.wallpapers);
        if (range)
            next[output] = range;
        else
            delete next[output];
        root.wallpapers = next;
    }

    // The luminance range of a wallpaper display (WallpaperFeed's `display`): a colour exactly, the artwork over its whole
    // palette (sky, sun, hills: a conservative range), a still picture from the helper's 5th to 95th percentile of the whole
    // picture; null for a video or a picture without those statistics.
    function rangeOf(desc: var, art: var): var {
        if (!desc)
            return null;
        if (desc.kind === "color" && typeof desc.color === "string" && desc.color !== "") {
            const l = GlassTint.luminance(GlassTint.channels(desc.color));
            return {lumMin: l, lumMax: l};
        }
        if (desc.kind === "art" && art) {
            const lums = Object.keys(art).map(k => GlassTint.luminance(GlassTint.channels(String(art[k]))));
            return {lumMin: Math.min(...lums), lumMax: Math.max(...lums)};
        }
        if (desc.kind === "picture" && !desc.video && desc.image && typeof desc.image.p5 === "number" && typeof desc.image.p95 === "number")
            return {lumMin: desc.image.p5, lumMax: desc.image.p95};
        return null;
    }

    // Test hook: qs ipc call backdrop status -> JSON {wallpapers, grids (cells rounded to 0.001), bare, known (output names)}
    // (read-only; dev session only, SEC-04).
    IpcHandler {
        target: "backdrop"

        function status(): string {
            if (!VisualFixtures.dev)
                return "refused";
            const grids = {};
            for (const name of Object.keys(root.grids)) {
                const g = root.grids[name];
                const r3 = v => Math.round(v * 1000) / 1000;
                grids[name] = {width: g.width, height: g.height, cols: g.cols, rows: g.rows, min: g.min.map(r3), max: g.max.map(r3)};
            }
            return JSON.stringify({wallpapers: root.wallpapers, grids: grids, bare: Compositor.bareOutputs, known: Object.keys(root.known)});
        }
    }
}
