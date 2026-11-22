.pragma library
.import "DefaultBrowser.js" as DefaultBrowser

// Settings > Desktop & Dock > Default Apps (owner report 2026-11-22: "set the default application per file type, as on Windows";
// "choose the default terminal"). macOS 27 keeps one popup, Default web browser, in that pane and the per-type choice in Get
// Info > Open with > Change All…; Grassfield keeps both and adds, under the browser, Mail, Terminal and one row per kind of
// document. Pure functions: the page reads the files through the backend and gives their text. Every choice of a type goes to
// the session's own list ($XDG_CONFIG_HOME/grassfield-mimeapps.list) through the backend's setDefaultApps, which is Files' Change
// All… writer (DefaultApps::writeSessionDefaults); the terminal goes to grassfield-xdg-terminals.list (setDefaultTerminal), which
// xdg-terminal-exec reads first in this session only.

// "Other…" in a row's popup: the application picker, every installed application (macOS: Other… in Open with).
var OTHER = "grassfield:other";

// The kinds of documents, in the order the page shows them, each with the types it sets. The first type is the one the row
// shows the application of.
var KINDS = [
    // Word processing: Word (and its macro-enabled and template forms), OpenDocument text and its template, RTF.
    {id: "documents", types: ["application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/msword",
                              "application/vnd.ms-word.document.macroEnabled.12", "application/vnd.openxmlformats-officedocument.wordprocessingml.template",
                              "application/vnd.oasis.opendocument.text", "application/vnd.oasis.opendocument.text-template", "application/rtf", "text/rtf"]},
    {id: "spreadsheets", types: ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/vnd.ms-excel",
                                 "application/vnd.ms-excel.sheet.macroEnabled.12", "application/vnd.openxmlformats-officedocument.spreadsheetml.template",
                                 "application/vnd.oasis.opendocument.spreadsheet", "application/vnd.oasis.opendocument.spreadsheet-template", "text/csv"]},
    {id: "presentations", types: ["application/vnd.openxmlformats-officedocument.presentationml.presentation", "application/vnd.ms-powerpoint",
                                  "application/vnd.ms-powerpoint.presentation.macroEnabled.12", "application/vnd.openxmlformats-officedocument.presentationml.template",
                                  "application/vnd.oasis.opendocument.presentation", "application/vnd.oasis.opendocument.presentation-template"]},
    {id: "pdf", types: ["application/pdf"]},
    {id: "pictures", types: ["image/jpeg", "image/png", "image/gif", "image/webp", "image/heif", "image/heic", "image/avif", "image/tiff", "image/bmp", "image/svg+xml"]},
    {id: "music", types: ["audio/mpeg", "audio/flac", "audio/mp4", "audio/x-m4a", "audio/ogg", "audio/x-vorbis+ogg", "audio/opus", "audio/vnd.wave", "audio/x-wav",
                          "audio/wav", "audio/aac"]},
    {id: "videos", types: ["video/mp4", "video/x-matroska", "video/webm", "video/quicktime", "video/x-msvideo", "video/mpeg", "video/ogg"]},
    {id: "archives", types: ["application/zip", "application/x-tar", "application/x-compressed-tar", "application/gzip", "application/x-xz",
                             "application/x-xz-compressed-tar", "application/x-bzip2", "application/x-bzip", "application/x-bzip2-compressed-tar",
                             "application/zstd", "application/x-zstd-compressed-tar", "application/x-7z-compressed", "application/vnd.rar",
                             "application/x-rar"]},
    {id: "text", types: ["text/plain", "text/markdown", "application/json", "application/xml", "text/x-python", "text/x-python3", "application/x-shellscript",
                         "text/x-csrc", "text/x-c++src", "text/x-chdr", "text/css", "text/javascript", "application/javascript", "text/x-rust",
                         "text/x-go", "text/x-java", "application/x-yaml", "application/toml"]}
];
var MAIL_TYPES = ["x-scheme-handler/mailto"];

// A choosable application: a shown Application entry with one Exec, TryExec and Type, whose Exec starts a program that exists
// (`exists`, the backend's programExists) and is no launcher that resolves the default again (DefaultBrowser.startedProgram).
// Returns the parsed entry, or null.
function usable(a, lang, exists) {
    if (!a || !DefaultBrowser.validId(a.file) || a.file === DefaultBrowser.ROUTING)
        return null;
    const e = DefaultBrowser.parseEntry(a.text, lang);
    if (e.duplicate || e.type !== "Application" || e.hidden || e.noDisplay || e.name === "")
        return null;
    const program = DefaultBrowser.startedProgram(DefaultBrowser.execWords(e.exec), 0);
    if (program === null)
        return null;
    if (typeof exists === "function" && (!exists(program) || (e.tryExec !== "" && !exists(e.tryExec))))
        return null;
    return e;
}

// Every choosable application of [{file, text}] (the first file of a name wins, as the lookup does): [{id, name, icon, mimeTypes,
// categories, exec}] sorted by name.
function applications(entries, lang, exists) {
    const seen = {};
    const out = [];
    for (const a of entries) {
        if (!a || seen[a.file])
            continue;
        seen[a.file] = true;
        const e = usable(a, lang, exists);
        if (e !== null)
            out.push({id: a.file, name: e.name, icon: e.icon, mimeTypes: e.mimeTypes, categories: e.categories, exec: e.exec});
    }
    out.sort((x, y) => x.name.localeCompare(y.name));
    return out;
}

// The applications that list one of `types` (the capable ones, macOS's "Recommended Applications").
function capable(apps, types) {
    return apps.filter(a => a.mimeTypes.some(t => types.indexOf(t) >= 0));
}

// A terminal emulator's launcher of a terminal emulator; not its server or client launcher (the Apps grid's rule,
// ApplicationsLogic terminalHelper: an Exec whose program ends in "client", or with --server or --daemon).
function terminals(apps) {
    return apps.filter(a => {
        if (a.categories.indexOf("TerminalEmulator") < 0)
            return false;
        const words = DefaultBrowser.execWords(a.exec);
        const program = words.length > 0 ? words[0].split("/").pop() : "";
        return !program.endsWith("client") && words.indexOf("--server") < 0 && words.indexOf("--daemon") < 0;
    });
}

// The types an application chosen for a kind gets: picked with Other… (`other`), every type of the kind (the person said so, as
// Change All… after Other… in Get Info; review of the Default Apps change); picked in the popup, the kind's types it lists, or all
// of them for one that lists none.
function typesFor(app, types, other) {
    if (other)
        return types.slice();
    const listed = app && app.mimeTypes ? types.filter(t => app.mimeTypes.indexOf(t) >= 0) : [];
    return listed.length > 0 ? listed : types.slice();
}

// The application the lists (text, in lookup order: the session's list first) name for the first of `types` that one of them
// names, "" when none.
function current(texts, types) {
    for (const type of types) {
        const id = DefaultBrowser.lookedUp(texts, type);
        if (id !== "")
            return id;
    }
    return "";
}

// The application that opens the first of `types` when no list names a default (review of the Default Apps change: the row
// shows what really opens, macOS-style, never "None" while an app would open it): GLib and xdg-mime then take the first
// application of the type's line in each applications folder's mimeinfo.cache, in the folders' order (`caches`: their text, the
// user's first); only an application of `apps` (installed and runnable) counts. "" when none.
function opener(caches, types, apps) {
    for (const type of types) {
        for (const text of caches) {
            let inGroup = false;
            for (const raw of String(text).split("\n")) {
                const line = raw.trim();
                if (line.startsWith("[")) {
                    inGroup = line === "[MIME Cache]";
                    continue;
                }
                if (!inGroup || line.indexOf(type + "=") !== 0)
                    continue;
                for (const id of line.slice(type.length + 1).split(";")) {
                    if (id !== "" && apps.some(a => a.id === id))
                        return id;
                }
            }
        }
    }
    return "";
}

// What a row shows: the default the lists name, else the application that opens the type anyway (opener), else "".
function shown(texts, caches, types, apps) {
    const named = current(texts, types);
    return named !== "" ? named : opener(caches, types, apps);
}

// A row's popup: the capable applications, the current one when it is not among them (an application chosen with Other…; its
// name from `apps`, else its id), "None" when nothing is set (shown, never written), then Other…. [{id, text}].
function choices(capableApps, apps, currentId, noneText, otherText) {
    const out = capableApps.map(a => ({id: a.id, text: a.name}));
    if (currentId !== "" && !out.some(c => c.id === currentId)) {
        const known = apps.find(a => a.id === currentId);
        out.push({id: currentId, text: known ? known.name : currentId.replace(/\.desktop$/, "")});
    }
    if (currentId === "")
        out.unshift({id: "", text: noneText});
    out.push({id: OTHER, text: otherText});
    return out;
}

// The session's terminal list, in the configuration folder.
var TERMINAL_LIST = "grassfield-xdg-terminals.list";

// The terminal xdg-terminal-exec --print-id printed ("<id>" or "<id>:<action>"), "" for anything else.
function printedTerminal(output) {
    const id = String(output).split("\n")[0].trim().split(":")[0];
    return DefaultBrowser.validId(id) ? id : "";
}

// The first entry of a terminal list (xdg-terminal-exec's format: '#' comments, '+'/'-' directives, "<id>[:<action>]"), as
// DefaultApps::terminalOf in apps/files reads it; "" when none.
function listedTerminal(text) {
    for (const raw of String(text).split("\n")) {
        const line = raw.trim();
        if (line === "" || line.startsWith("#") || line.startsWith("+") || line.startsWith("-"))
            continue;
        return printedTerminal(line);
    }
    return "";
}

// The user's lists after the session's own one, in lookup order (the configuration folder's, then each applications folder's),
// for the rows' current application: <desktop>-mimeapps.list for each item of XDG_CURRENT_DESKTOP, then mimeapps.list.
function lookupPaths(configDir, applicationDirs, desktops) {
    const names = DefaultBrowser.ownListNames(desktops);
    const out = names.map(n => configDir + "/" + n);
    for (const dir of applicationDirs) {
        for (const n of names)
            out.push(dir + "/" + n);
    }
    return out;
}
