.pragma library

// The text a person or a script author can make look like something else: one rule for every name, title, placeholder and
// label the palette shows (ScriptMeta.js, CommandsFile.js). Pure.
//
// HIDDEN is the set the security prompts use (shell/security/secret/Prompter.js removedCodePoint, which tests/unit/
// tst_scriptmeta.qml ties to this one) joined with the one of ui/Grassfield/Ui/WallpaperConfig.js HIDDEN: controls, DEL, C1,
// soft hyphen, combining grapheme joiner, Hangul and other fillers, the Mongolian vowel separator and free variation
// selectors, zero-width characters, bidirectional marks, embeddings, overrides and isolates, line and paragraph separators,
// the invisible operators, the braille blank, variation selectors, the byte order mark, the specials, the interlinear
// annotation marks, the non-characters and the tag characters (U+E0000 to U+E007F, a surrogate pair in JavaScript).
const HIDDEN = new RegExp("[\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u034f\\u061c\\u115f\\u1160\\u17b4\\u17b5\\u180b-\\u180f\\u200b-\\u200f"
    + "\\u2028-\\u202e\\u2060-\\u206f\\u2800\\u3164\\ufdd0-\\ufdef\\ufe00-\\ufe0f\\ufeff\\uffa0\\ufff0-\\uffff]|\\udb40[\\udc00-\\udc7f]");

// True when `s` holds a character that draws nothing or reorders text.
function hasHidden(s) {
    return HIDDEN.test(s);
}

// True when `s` is a string of min..max UTF-16 units with no hidden character, at least one character that is no white space
// (a name of spaces alone, no-break spaces or ideographic spaces is empty), and no space or tab at either end.
function isLabel(s, min, max) {
    if (typeof s !== "string" || s.length < min || s.length > max || HIDDEN.test(s))
        return false;
    if (s !== s.replace(/^\s+|\s+$/g, ""))
        return false;
    return min === 0 && s === "" ? true : /\S/.test(s);
}
