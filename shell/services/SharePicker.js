.pragma library

// The screen-sharing picker's decisions (ADR-0035 D-6, step 7a; spec system-dialogs.md section 3), kept out of
// SharePicker.qml so that tests/unit/tst_sharepicker.qml reads them without Quickshell. The stand-in
// (packaging/session-bin/hyprland-share-picker) asks with `picker request <id> <socket>`; the shell connects to that socket,
// reads the window list xdph gave the stand-in, and answers one line in xdph's own grammar. The stand-in checks the answer
// again before xdph reads it: nothing here is trusted by it.

const ID = /^[0-9a-f]{32}$/;
const SOCKET = /^[0-9a-f]{32}\.sock$/;
const OUTPUT = /^[A-Za-z0-9._-]{1,64}$/;
const HANDLE = /^[0-9]{1,10}$/;
const ADDRESS = /^0x([0-9a-f]{1,16})$/;
const MAX_WINDOWS = 256;
const MAX_TEXT = 256;

// A request the shell takes: a 128-bit hex id, and a socket the stand-in made in this user's runtime directory
// ($XDG_RUNTIME_DIR/grassfield/picker/<128-bit hex>.sock). Any other path is refused: the shell connects to nothing else.
function validRequest(id, path, runtimeDir) {
    if (typeof id !== "string" || typeof path !== "string" || typeof runtimeDir !== "string")
        return false;
    if (!ID.test(id) || runtimeDir === "" || runtimeDir[0] !== "/")
        return false;
    const folder = runtimeDir.replace(/\/+$/, "") + "/grassfield/picker/";
    return path.startsWith(folder) && SOCKET.test(path.slice(folder.length));
}

// The stand-in's first line, `<id> list <json>`: the windows xdph listed, or null when the line is not that request's list.
// Each window keeps its handle (what the answer names), its app id and title (plain text, capped) and Hyprland's address
// as Compositor.toplevelByAddress takes it, lower-case hex without "0x" (the live thumbnail's source; "" when xdph had none).
function parseList(line, id) {
    const head = id + " list ";
    if (typeof line !== "string" || !line.startsWith(head))
        return null;
    let listed;
    try {
        listed = JSON.parse(line.slice(head.length));
    } catch (e) {
        return null;
    }
    if (!Array.isArray(listed))
        return null;
    const out = [];
    for (const w of listed) {
        if (out.length >= MAX_WINDOWS)
            break;
        if (!w || typeof w !== "object" || typeof w.handle !== "string" || !HANDLE.test(w.handle) || Number(w.handle) > 4294967295)
            continue;
        if (out.some(o => o.handle === w.handle))
            continue;
        out.push({
            handle: w.handle,
            appId: typeof w["class"] === "string" ? w["class"].slice(0, MAX_TEXT) : "",
            title: typeof w.title === "string" ? w.title.slice(0, MAX_TEXT) : "",
            address: typeof w.address === "string" && ADDRESS.test(w.address) ? ADDRESS.exec(w.address)[1] : ""
        });
    }
    return out;
}

// The stand-in's options line, sent before the list: `<id> options {"allowToken": true|false}`, allowToken true when xdph
// passed --allow-token (allow_token_by_default in xdph.conf; Omarchy's sets it). {allowToken} or null when the line is not
// that request's options. Only true allows the token. A shell without this line (an older stand-in) keeps the default: no
// token.
function parseOptions(line, id) {
    const head = id + " options ";
    if (typeof line !== "string" || !line.startsWith(head))
        return null;
    let given;
    try {
        given = JSON.parse(line.slice(head.length));
    } catch (e) {
        return null;
    }
    if (given === null || typeof given !== "object" || Array.isArray(given))
        return null;
    return {
        allowToken: given.allowToken === true
    };
}

// The windows in the order the Window tab shows them: grouped by app (its name), then by title.
function ordered(windows, nameFor) {
    return windows.slice().sort((a, b) => {
        const byApp = nameFor(a.appId).localeCompare(nameFor(b.appId));
        return byApp !== 0 ? byApp : a.title.localeCompare(b.title);
    });
}

// The answer line for xdph's grammar: `<flags>/screen:<output>`, `<flags>/window:<handle>` or
// `<flags>/region:<output>@x,y,w,h`, flag "r" when Remember this choice is ticked (it opens unticked, or as xdph's --allow-token says
// once SharePickerPanel.followAllowToken is true). "" for anything that is not a listed choice: a display that is not there, a window xdph did not list or that
// hides itself from capture (`blocked`, step 7b), an area that is not inside its display's logical size (`sizes`: name ->
// {width, height}). `blocked` null: Hyprland has not said yet which windows hide from capture, so no window is answered.
function selection(kind, value, remember, outputs, windows, sizes, blocked) {
    const flags = remember === true ? "r" : "";
    if (kind === "screen" && typeof value === "string" && OUTPUT.test(value) && outputs.indexOf(value) >= 0)
        return flags + "/screen:" + value;
    if (kind === "window" && typeof value === "string" && windows.some(w => w.handle === value) && Array.isArray(blocked) && !blocked.includes(value))
        return flags + "/window:" + value;
    if (kind === "region") {
        const r = parseRegion(value);
        const size = r && sizes ? sizes[r.output] : undefined;
        if (r && outputs.indexOf(r.output) >= 0 && size && r.x + r.w <= size.width && r.y + r.h <= size.height)
            return flags + "/region:" + value;
    }
    return "";
}

// An area as the panel keeps it and xdph reads it: `<output>@x,y,w,h`, logical pixels relative to that display.
function regionKey(output, r) {
    return output + "@" + r.x + "," + r.y + "," + r.w + "," + r.h;
}

// {output, x, y, w, h} from `<output>@x,y,w,h`, or null: a display's name, whole numbers, a width and height of at least 1.
function parseRegion(value) {
    const m = /^([A-Za-z0-9._-]{1,64})@([0-9]{1,5}),([0-9]{1,5}),([0-9]{1,5}),([0-9]{1,5})$/.exec(String(value));
    if (!m)
        return null;
    const r = {output: m[1], x: Number(m[2]), y: Number(m[3]), w: Number(m[4]), h: Number(m[5])};
    return r.w >= 1 && r.h >= 1 ? r : null;
}

// The area dragged on a display's preview (`drag`: a start and an end point in the preview's pixels, in any direction), in
// that display's logical pixels: kept inside the preview, scaled to the display, whole numbers. null when it is smaller than
// `minSize` logical pixels either way (a click, not an area).
function regionFor(drag, preview, logical, minSize) {
    if (!drag || preview.width <= 0 || preview.height <= 0 || logical.width <= 0 || logical.height <= 0)
        return null;
    const clamp = (v, hi) => Math.max(0, Math.min(hi, v));
    const x0 = clamp(Math.min(drag.x1, drag.x2), preview.width), x1 = clamp(Math.max(drag.x1, drag.x2), preview.width);
    const y0 = clamp(Math.min(drag.y1, drag.y2), preview.height), y1 = clamp(Math.max(drag.y1, drag.y2), preview.height);
    const sx = logical.width / preview.width, sy = logical.height / preview.height;
    const x = Math.round(x0 * sx), y = Math.round(y0 * sy);
    const w = Math.min(Math.round(x1 * sx), logical.width) - x, h = Math.min(Math.round(y1 * sy), logical.height) - y;
    return w >= minSize && h >= minSize ? {x: x, y: y, w: w, h: h} : null;
}

// The windows that hide themselves from capture (step 7b): `answers` holds one line per window asked, in any order,
// `<address> <hyprctl -j getprop address:0x<address> no_screen_share>` (`<address> {"no_screen_share": true}`). Lines are
// matched by address, never by place, so an answer meant for another request's windows marks none of these. A line that does
// not read (the window is gone, an older Hyprland) counts as not hidden: Hyprland still leaves such a window out of every
// capture, so the greying only tells the user beforehand.
function blockedHandles(windows, answers) {
    const hidden = {};
    for (const line of String(answers).split("\n")) {
        const m = /^([0-9a-f]{1,16}) (.*)$/.exec(line);
        if (!m)
            continue;
        let v = null;
        try {
            v = JSON.parse(m[2]);
        } catch (e) {
            v = null;
        }
        if (v && typeof v === "object" && v.no_screen_share === true)
            hidden[m[1]] = true;
    }
    return windows.filter(w => w.address !== "" && hidden[w.address] === true).map(w => w.handle);
}

// xdph's screen-sharing streams among PipeWire's nodes (step 7b, the recording indicator): video nodes whose node.name is
// xdph's program name. xdph names each stream "xdph-streaming-<random>" (xdph 1.4.1 src/portals/Screencopy.cpp:1015), but
// PipeWire keeps that in media.name, which a node's registry entry does not carry, and takes node.name from the program
// (application.name: "xdg-desktop-portal-hyprland"; review of step 7b, BLOCKER 1, measured with a stream made as xdph makes
// it). Hyprland's own `screencast` event cannot say this: every capture, the shell's own thumbnails too, raises it (Hyprland
// 0.56.2 ScreenshareFrame.cpp:170). `nodes`: {id, name, video}. Their ids.
function sharingStreams(nodes) {
    const out = [];
    for (const n of nodes || []) {
        if (n && n.name === "xdg-desktop-portal-hyprland" && n.video === true)
            out.push(n.id);
    }
    return out;
}

// What each stream shares, for the indicator's menu, best effort: a stream that appears takes the choice the picker answered
// within `maxAgeMs` (SharePicker: 3 s; an app starts its stream as soon as the portal answers it) only when it is the one new
// stream and that the one choice waiting; anything else is no label ("Screen or window") (review of step 7b, MINOR 2). The
// portal does not say which app a stream is for: an app that restores a share with its token (no picker) within those 3 s,
// while the app the picker answered has not started its own, takes that answer's label (decision 7-12). `labels`: stream id
// -> {kind, value, title} or null.
function streamLabels(labels, streams, pending, now, maxAgeMs) {
    const kept = {};
    let left = pending.filter(g => now - g.at <= maxAgeMs);
    const fresh = streams.filter(id => labels[id] === undefined);
    for (const id of streams) {
        if (labels[id] !== undefined)
            kept[id] = labels[id];
        else if (fresh.length === 1 && left.length === 1) {
            kept[id] = left[0].what;
            left = [];
        } else
            kept[id] = null;
    }
    return {labels: kept, pending: left};
}

// What a tile stands for, kept as the selection so that it never moves to another tile when the list changes under it (a
// display plugged in, the windows sorted again once app names arrive): a display's name, a window's handle.
function keyOf(tab, tile) {
    if (!tile)
        return "";
    return tab === "window" ? String(tile.handle) : String(tile.name);
}

// The tile of `key` in `tiles`, or -1 when it is gone (the selection then clears: Share is dimmed again).
function indexOfKey(tab, tiles, key) {
    if (key === "")
        return -1;
    for (let i = 0; i < tiles.length; i++) {
        if (keyOf(tab, tiles[i]) === key)
            return i;
    }
    return -1;
}

// The tile the arrow keys move to in a grid of `count` tiles, `columns` wide: Left/Right step, Up/Down move by a row; the
// selection stays when there is nothing that way. -1 (nothing selected) goes to the first tile.
function moved(index, key, count, columns) {
    if (count <= 0)
        return -1;
    if (index < 0 || index >= count)
        return 0;
    const cols = Math.max(1, columns);
    const to = key === "left" ? index - 1 : key === "right" ? index + 1 : key === "up" ? index - cols : key === "down" ? index + cols : index;
    return to >= 0 && to < count ? to : index;
}

// Columns that fit `width` with tiles of `tile` and gaps of `gap`, at least one.
function columnsFor(width, tile, gap) {
    return Math.max(1, Math.floor((width + gap) / (tile + gap)));
}
