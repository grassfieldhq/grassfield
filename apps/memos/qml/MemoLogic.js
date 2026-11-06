.pragma library

// Grassfield Memos' window rules (ADR-0051, docs/specs/memos.md), pure: the colours, the collapsed and expanded heights, the
// close rule, the strip's title and the front memo. Tokens are passed in (a library has no QML singletons).

// The six paper colours in Color menu order (Ctrl+1 to Ctrl+6); the first is the default. The same list as the store's
// (apps/memos/src/memostore.cpp colorNames).
var colors = ["yellow", "blue", "green", "pink", "purple", "grey"];

function validColor(name) {
    return colors.indexOf(name) >= 0 ? name : colors[0];
}

function tokenName(name, part) {
    const c = validColor(name);
    return "memos" + c.charAt(0).toUpperCase() + c.slice(1) + part;
}

// The paper and strip colours of a memo colour, from the Tokens singleton.
function paper(tokens, name) {
    return tokens[tokenName(name, "Paper")];
}

function strip(tokens, name) {
    return tokens[tokenName(name, "Strip")];
}

// The colour of a Color menu key (1 to 6), "" for any other.
function colorForKey(key) {
    return key >= 1 && key <= colors.length ? colors[key - 1] : "";
}

// The window's height: the strip alone while collapsed, else the stored height (never under the minimum).
function windowHeight(collapsed, expandedHeight, stripHeight, minHeight) {
    return collapsed ? stripHeight : Math.max(expandedHeight, minHeight);
}

// The memo's tag with the size the compositor's rule gives its window (config/hypr/grassfield/placement.lua memo_resize):
// "memo:<id>[@x,y]!<w>x<h>"; a size already on the tag is replaced.
function sizedTag(tag, width, height) {
    return String(tag ?? "").replace(/![0-9]+x[0-9]+$/, "") + "!" + Math.round(width) + "x" + Math.round(height);
}

// Whether a height the window reports is the memo's own (kept and stored): not while collapsed, not the strip's height a
// collapse is moving through.
function keepsHeight(collapsed, height, stripHeight) {
    return !collapsed && height > stripHeight;
}

// Close: an empty memo goes at once; one with text asks first (macOS asks before a note with text is deleted).
function closeNeedsConfirm(plainText) {
    return String(plainText ?? "").trim() !== "";
}

// The window's title (Dock, Window menu, Overview): the memo's first line, or "Memo" (`fallback`) when it has none.
function title(firstLine, fallback) {
    const t = String(firstLine ?? "").trim();
    return t !== "" ? t : fallback;
}

// The memo a new memo opens near: the last active one if it is still open, else the newest.
function frontMemo(windows, lastActive) {
    if (lastActive && windows.indexOf(lastActive) >= 0)
        return lastActive;
    return windows.length > 0 ? windows[windows.length - 1] : null;
}

// A key the in-window shortcuts give the Color menu: "Ctrl+1" to "Ctrl+6".
function colorShortcut(index) {
    return "Ctrl+" + (index + 1);
}
