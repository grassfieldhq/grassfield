.pragma library

// A file name as shown in a label (GF-105, like Finder): the one helper every view of Files and Preview, and every message that
// names a file, goes through. Line breaks become a return symbol (U+23CE), and the bidirectional override, embedding and
// isolate controls (U+202A to U+202E, U+2066 to U+2069) and the line and paragraph separators (U+2028, U+2029) are written
// out as "<U+202E>" so a name cannot reorder the text around it or break the line; so are the marks LRM, RLM and ALM (U+200E,
// U+200F, U+061C: "pdf." + RLM + "Invoice" after an RLM was drawn "Invoice.pdf"; Files' fifth security check, V1). The code
// points are numbers on purpose: this source never holds a bidi control itself. The C++ twin is FileLogic::displayName
// (apps/files/src/filelogic.cpp). tests/shell/display_names.sh fails when a view shows a raw name.

const RETURN_SYMBOL = String.fromCharCode(0x23CE);

function escaped(code) {
    return (code >= 0x202A && code <= 0x202E) || (code >= 0x2066 && code <= 0x2069) || code === 0x2028 || code === 0x2029
        || code === 0x200E || code === 0x200F || code === 0x061C;
}

function text(name) {
    const s = String(name === undefined || name === null ? "" : name);
    let out = "";
    let inBreak = false;
    for (let i = 0; i < s.length; i++) {
        const code = s.charCodeAt(i);
        if (code === 10 || code === 13) {
            if (!inBreak)
                out += RETURN_SYMBOL;
            inBreak = true;
            continue;
        }
        inBreak = false;
        out += escaped(code) ? "<U+" + ("0000" + code.toString(16).toUpperCase()).slice(-4) + ">" : s[i];
    }
    return out;
}
