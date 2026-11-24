.pragma library
.import "ScriptMeta.js" as ScriptMeta
.import "PlainText.js" as PlainText
.import "CommandsFile.js" as CommandsFile

// The script commands in Search (ADR-0067 D-3, command-palette.md slice X2). Pure: no file, no process, no QML. script-scan.py
// judges the file system's side (owner, mode, size, links, folders); this turns its report into palette entries: the header goes
// through ScriptMeta.parse, the names through PlainText. Nothing here runs a script: the runner (X3) and the approval gate (X7)
// do, and until X7 lands an entry's `run` hands the request to `onRun` (Scripts.qml leaves it unconnected).

const MAX_FOLDERS = 13;             // the default folder and at most 12 of the person's own (search.scriptFolders)
const DEFAULT_SUBPATH = "/grassfield/script-commands";

function trimSlash(p) {
    return p.length > 1 ? p.replace(/\/+$/, "") : p;
}

// The folders to read: the default one first, then the person's (a leading "~/" is the home folder); a path the commands file's
// path rule refuses (relative, a parent step, a control character, a network path) is left out; no duplicates.
function folders(settingsFolders, home, dataHome) {
    const out = [];
    const add = p => {
        if (p === "" || out.indexOf(p) >= 0 || out.length >= MAX_FOLDERS)
            return;
        out.push(p);
    };
    add(trimSlash(dataHome) + DEFAULT_SUBPATH);
    for (const raw of Array.isArray(settingsFolders) ? settingsFolders : []) {
        if (typeof raw !== "string" || !CommandsFile.checkPath(raw))
            continue;
        add(trimSlash(raw.slice(0, 2) === "~/" ? trimSlash(home) + raw.slice(1) : raw));
    }
    return out;
}

// A file name that may reach a row or a prompt: plain text, no hidden or bidirectional character, no lone surrogate.
function nameOk(name) {
    return typeof name === "string" && PlainText.isLabel(name, 1, 255) && !/[\ud800-\udbff](?![\udc00-\udfff])|(?:[^\ud800-\udbff]|^)[\udc00-\udfff]/.test(name);
}

// The report of script-scan.py ({v: 1, folders: [...]}) or null when it is not that.
function parseScan(text) {
    let doc;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!doc || doc.v !== 1 || !Array.isArray(doc.folders))
        return null;
    return doc;
}

// What a report holds: {scripts: [{id, path, folder, name, link, real, meta}], problems: [{path, folder, reason}]}. A script
// whose `platform` lists only windows is hidden (parsed, not listed); a malformed header is a problem, not a row.
function listing(report) {
    const scripts = [];
    const problems = [];
    const seen = {};
    for (const f of (report && Array.isArray(report.folders)) ? report.folders : []) {
        if (!f || typeof f.path !== "string")
            continue;
        if (f.status === "refused-folder")
            problems.push({path: f.path, folder: f.path, reason: "refused-folder"});
        for (const s of Array.isArray(f.scripts) ? f.scripts : []) {
            if (!s || typeof s.path !== "string" || typeof s.name !== "string")
                continue;
            if (ScriptMeta.isTemplateName(s.name))
                continue;
            if (s.ok !== true) {
                problems.push({path: s.path, folder: f.path, reason: String(s.reason || "refused")});
                continue;
            }
            if (!nameOk(s.name) || typeof s.id !== "string" || !/^script\.[0-9a-f]{20}$/.test(s.id) || typeof s.head !== "string") {
                problems.push({path: s.path, folder: f.path, reason: "name"});
                continue;
            }
            if (seen[s.id])
                continue;
            const parsed = ScriptMeta.parse(s.head);
            if (!parsed.ok) {
                problems.push({path: s.path, folder: f.path, reason: "header:" + parsed.key + ":" + parsed.reason});
                continue;
            }
            if (parsed.hidden)
                continue;
            seen[s.id] = true;
            scripts.push({id: s.id, path: s.path, folder: f.path, name: s.name, link: s.link === true, real: typeof s.real === "string" ? s.real : "",
                meta: parsed.meta});
        }
    }
    return {scripts: scripts, problems: problems};
}

// Palette entries (Commands.js) for a listing. `t`: {subtitle (a script without a package name), keywordScript}; `refuses`: a
// function true while the session is locked; `onRun(script, args, origin)`: where a run request goes (the approval gate, X7).
function entries(scripts, t, refuses, onRun) {
    return scripts.map(s => ({
        id: s.id,
        title: s.meta.title,
        subtitle: s.meta.packageName !== "" && s.meta.packageName !== undefined ? s.meta.packageName : t.subtitle,
        keywords: [t.keywordScript].concat(s.meta.description ? [s.meta.description] : []),
        keywordsEn: ["script"],
        glyph: "document",
        kind: "script",
        provider: "scripts",
        script: s,
        available: true,
        run: (args, origin) => {
            if (refuses())
                return;
            onRun(s, args || [], origin || "row");
        }
    }));
}

// The message for a script run that did not happen or did not succeed. `code`: the runner's exit status, or a negative number when
// no runner took the request. `t`: {notRun, refused, noSandbox, failed ("%1" = the code)}. 70 is a refused frame, 71 a runner whose
// sandbox stage is not installed (grassfield-script-run); never an empty string.
function failureText(code, t) {
    if (typeof code !== "number" || !isFinite(code) || code < 0)
        return t.notRun;
    if (code === 70)
        return t.refused;
    if (code === 71)
        return t.noSandbox;
    return t.failed.replace("%1", String(code));
}
