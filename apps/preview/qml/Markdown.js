.pragma library

// The rendered Markdown of TextView.qml. The backend gives the HTML of the document (previewlogic markdownHtml: Qt's own
// Markdown reader with raw HTML off, so every tag in it is Qt's and the document's own text is escaped; pictures already
// point at Preview's image provider with their served size). This file only adds the theme's colours for links and code
// blocks; the pictures are fitted to the column by the backend (PreviewApp.fitMarkdownImages), without a new parse.
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

// The HTML the view shows: the theme's link colour and code block fill in the document's style sheet. It depends on the
// document and the theme only (never on the view's width), so a resize keeps the parsed text and its selection.
function styled(html, colors) {
    if (typeof html !== "string" || html === "")
        return "";
    const link = cssColor(colors ? colors.link : undefined);
    const code = cssColor(colors ? colors.code : undefined);
    let css = "";
    if (link !== "")
        css += "a { color: " + link + "; }\n";
    if (code !== "")
        css += "pre { background-color: " + code + "; }\n";
    return css !== "" && html.indexOf("</style>") >= 0 ? html.replace("</style>", css + "</style>") : html;
}

// A link a click may hand to the browser: http or https only (PreviewApp.openLink checks it again, strictly).
function isWebLink(link) {
    return typeof link === "string" && /^https?:\/\/[^\s]+$/i.test(link);
}
