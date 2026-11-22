.pragma library

// The rendered Markdown of TextView.qml. The backend gives the HTML of the document (previewlogic markdownHtml: Qt's own
// Markdown reader with raw HTML off, so every tag in it is Qt's and the document's own text is escaped; pictures already
// point at Preview's image provider with their size). This file only fits it to the view: the theme's colours for links and
// code blocks, and pictures no wider than the column (shrunk, never enlarged, aspect ratio kept), as Quick Look shows them.
// Pure functions, unit-tested in tests/unit/tst_previewmarkdown.qml.

// A QML colour as a CSS colour Qt's rich text reads ("#rrggbb" or "rgba(r, g, b, a)").
function cssColor(c) {
    if (c === undefined || c === null)
        return "";
    if (typeof c === "string")
        return c;
    const r = Math.round(c.r * 255);
    const g = Math.round(c.g * 255);
    const b = Math.round(c.b * 255);
    if (c.a >= 1)
        return "#" + [r, g, b].map(v => (v < 16 ? "0" : "") + v.toString(16)).join("");
    return "rgba(" + r + ", " + g + ", " + b + ", " + Math.round(c.a * 1000) / 1000 + ")";
}

// Every <img> no wider than `maxWidth` (its height scaled with it). Only the width and height attributes the backend wrote
// are read; the document's text cannot hold a tag (it is escaped).
function fitImages(html, maxWidth) {
    if (typeof html !== "string" || !(maxWidth > 0))
        return typeof html === "string" ? html : "";
    return html.replace(/<img ([^>]*?)width="(\d+)" height="(\d+)"/g, (whole, before, w, h) => {
        const width = Number(w);
        const height = Number(h);
        if (width <= maxWidth || width <= 0)
            return whole;
        const scaled = Math.max(1, Math.round(height * maxWidth / width));
        return "<img " + before + "width=\"" + Math.floor(maxWidth) + "\" height=\"" + scaled + "\"";
    });
}

// The HTML the view shows: the theme's link colour and code block fill, then the pictures fitted to `width`.
function styled(html, width, colors) {
    if (typeof html !== "string" || html === "")
        return "";
    const link = cssColor(colors ? colors.link : undefined);
    const code = cssColor(colors ? colors.code : undefined);
    let css = "";
    if (link !== "")
        css += "a { color: " + link + "; }\n";
    if (code !== "")
        css += "pre { background-color: " + code + "; }\n";
    const out = css !== "" && html.indexOf("</style>") >= 0 ? html.replace("</style>", css + "</style>") : html;
    return fitImages(out, width);
}

// A link a click may hand to the browser: http or https only (PreviewApp.openLink checks it again, strictly).
function isWebLink(link) {
    return typeof link === "string" && /^https?:\/\/[^\s]+$/i.test(link);
}
