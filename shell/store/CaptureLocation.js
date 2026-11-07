.pragma library

// Options > Save to of the capture toolbar as the shell reads it (capture.location; owner 2026-11-07: screenshots no longer go to
// the Desktop by default). Pure (tests/unit/tst_capturemodel.qml); packaging/bin/grassfield-capture stored_location() is its twin
// for the keys, which run the helper without --save.
//
// `screenshots` is the Screenshots folder in the Pictures folder for a screenshot and the Videos folder for a recording. Before
// capture.location existed the toolbar wrote capture.saveTo (desktop | documents | clipboard | preview, default desktop). Every
// file the shell created held that default, so a stored "desktop" cannot be told from a choice: it moves to the new default,
// while documents, clipboard and preview, which only a choice wrote, stay. Nothing is written back.

var LOCATIONS = ["screenshots", "desktop", "documents", "clipboard", "preview"];
var DEFAULT = "screenshots";
var KEPT_FROM_SAVE_TO = ["documents", "clipboard", "preview"];

// `stored`: capture.location as the file holds it (undefined when absent); `legacy`: capture.saveTo likewise; `unsafe`: the file
// is one the shell reads as its defaults (SettingsStore.unsafeFile).
function effective(stored, legacy, unsafe) {
    if (unsafe === true)
        return DEFAULT;
    if (stored !== undefined)
        return LOCATIONS.indexOf(stored) >= 0 ? stored : DEFAULT;
    return KEPT_FROM_SAVE_TO.indexOf(legacy) >= 0 ? legacy : DEFAULT;
}
