.pragma library

// Settings > Desktop & Dock > Default web browser (ADR-0055 D-6; macOS 27 has the popup in that pane). Pure functions: the page
// reads the files through the backend and gives their text. The choice goes to the session's own list,
// $XDG_CONFIG_HOME/grassfield-mimeapps.list (read first by the specification's lookup in this session, the Omarchy session never
// reads it), and is recorded as the user's in Grassfield's state folder, default-apps.state ("web.state=user"), which keeps the
// session-start seed of Files (applicationslogic.cpp seedBundledApps) from ever writing the web types again.

var WEB_TYPES = ["x-scheme-handler/http", "x-scheme-handler/https", "text/html", "application/xhtml+xml"];
var LIST_NAME = "grassfield-mimeapps.list";
var STATE_NAME = "default-apps.state";
var GROUP = "[Default Applications]";
// Omarchy's routing entry: it runs omarchy-launch-browser, which reads the default browser again. Never a browser to choose.
var ROUTING = "omarchy-browser.desktop";

// The words of an Exec= line as the desktop entry specification quotes them (double quotes with backslash escapes, and the single
// quotes a careless writer uses), as DefaultApps::isLauncherExec in apps/files reads them.
function execWords(exec) {
    const words = [];
    let cur = "";
    let have = false;
    let quote = "";
    const text = String(exec);
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (quote !== "") {
            if (c === quote)
                quote = "";
            else if (c === "\\" && quote === "\"" && i + 1 < text.length)
                cur += text[++i];
            else
                cur += c;
        } else if (c === "\"" || c === "'") {
            quote = c;
            have = true;
        } else if (/\s/.test(c)) {
            if (have)
                words.push(cur);
            cur = "";
            have = false;
        } else {
            if (c === "\\" && i + 1 < text.length)
                cur += text[++i];
            else
                cur += c;
            have = true;
        }
    }
    if (have)
        words.push(cur);
    return words;
}

function launcherWords(words, depth) {
    if (words.length === 0 || depth > 3)
        return true;
    const program = words[0].split("/").pop();
    let rest = null;
    if (program === "uwsm-app")
        rest = words.slice(1);
    else if (program === "uwsm" && words[1] === "app")
        rest = words.slice(2);
    if (rest === null) {
        const launchers = ["gio", "gtk-launch", "sh", "bash", "dash", "zsh", "fish", "env", "uwsm", "systemd-run", "kde-open", "gnome-open", "exo-open",
                           "sensible-browser", "x-www-browser"];
        return program === "" || program.indexOf("omarchy-") === 0 || program.indexOf("xdg-") === 0 || launchers.indexOf(program) >= 0;
    }
    // uwsm-app and `uwsm app` only start the program they are given: judge that one.
    const dashes = rest.indexOf("--");
    if (dashes >= 0)
        return launcherWords(rest.slice(dashes + 1), depth + 1);
    for (let i = 0; i < rest.length; i++) {
        if (rest[i].indexOf("-") !== 0)
            return launcherWords(rest.slice(i), depth + 1);
    }
    return true;
}

// Whether an Exec= line runs a launcher that resolves the default again (the fork storm of 2026-10-30): omarchy-*, xdg-*, gio, a
// shell, env..., an empty line; the program uwsm-app or `uwsm app --` starts is the one judged.
function launcherExec(exec) {
    return launcherWords(execWords(exec), 0);
}

function validId(id) {
    return typeof id === "string" && /^[A-Za-z0-9._+-]{1,200}\.desktop$/.test(id);
}

// One entry's fields: name (localised), exec, icon, categories, mimeTypes, hidden, noDisplay, type.
function parseEntry(text, lang) {
    const e = {name: "", exec: "", icon: "", categories: [], mimeTypes: [], hidden: false, noDisplay: false, type: ""};
    const short = String(lang).split(/[_.@]/)[0];
    let inGroup = false;
    let localised = "";
    for (const raw of String(text).split("\n")) {
        const line = raw.trim();
        if (line.startsWith("[")) {
            inGroup = line === "[Desktop Entry]";
            continue;
        }
        if (!inGroup || line === "" || line.startsWith("#"))
            continue;
        const eq = line.indexOf("=");
        if (eq <= 0)
            continue;
        const key = line.slice(0, eq).trim();
        const value = line.slice(eq + 1).trim();
        if (key === "Name")
            e.name = value;
        else if ((key === "Name[" + lang + "]" || key === "Name[" + short + "]") && localised === "")
            localised = value;
        else if (key === "Exec" && e.exec === "")
            e.exec = value;
        else if (key === "Icon")
            e.icon = value;
        else if (key === "Type")
            e.type = value;
        else if (key === "Categories")
            e.categories = value.split(";").filter(s => s !== "");
        else if (key === "MimeType")
            e.mimeTypes = value.split(";").filter(s => s !== "");
        else if (key === "Hidden")
            e.hidden = value === "true";
        else if (key === "NoDisplay")
            e.noDisplay = value === "true";
    }
    if (localised !== "")
        e.name = localised;
    return e;
}

// The browsers one can choose: [{id, name, icon}] sorted by name, from [{file, text}] (the first file of a name wins, as the
// lookup does). A browser has WebBrowser in its Categories, is shown, handles http or https, and its Exec is no launcher.
function browsers(entries, lang) {
    const seen = {};
    const out = [];
    for (const a of entries) {
        if (!a || seen[a.file] || !validId(a.file))
            continue;
        seen[a.file] = true;
        if (a.file === ROUTING)
            continue;
        const e = parseEntry(a.text, lang);
        if (e.type !== "Application" || e.hidden || e.noDisplay || e.name === "" || launcherExec(e.exec))
            continue;
        if (e.categories.indexOf("WebBrowser") < 0)
            continue;
        if (e.mimeTypes.indexOf("x-scheme-handler/http") < 0 && e.mimeTypes.indexOf("x-scheme-handler/https") < 0)
            continue;
        out.push({id: a.file, name: e.name, icon: e.icon});
    }
    out.sort((x, y) => x.name.localeCompare(y.name));
    return out;
}

// The first application of `type` in a list's [Default Applications], "" when none.
function defaultOf(listText, type) {
    let inGroup = false;
    for (const raw of String(listText).split("\n")) {
        const line = raw.trim();
        if (line.startsWith("[")) {
            inGroup = line === GROUP;
            continue;
        }
        if (!inGroup || line.startsWith("#"))
            continue;
        const eq = line.indexOf("=");
        if (eq > 0 && line.slice(0, eq).trim() === type)
            return line.slice(eq + 1).split(";").map(s => s.trim()).filter(s => s !== "")[0] || "";
    }
    return "";
}

// The first application the lists (text, in lookup order) name for a type, "" when none; Omarchy's routing entry is left out, as
// omarchy-cmd-default-browser does.
function lookedUp(texts, type) {
    for (const t of texts) {
        const id = defaultOf(t, type);
        if (id !== "" && id !== ROUTING)
            return id;
    }
    return "";
}

// The browser the session opens links with: the session's list first, then the user's lists in the lookup's order, as Omarchy's
// omarchy-cmd-default-browser reads them. `texts`: the lists' text in that order, the session's first.
function current(texts) {
    return lookedUp(texts, "x-scheme-handler/http");
}

// The names of the user's own lists in the configuration folder, in lookup order: a desktop list for each item of
// XDG_CURRENT_DESKTOP (lowercased; the session's own grassfield-mimeapps.list is not one of them), then mimeapps.list.
function ownListNames(desktops) {
    const out = [];
    for (const d of desktops) {
        const name = String(d).toLowerCase();
        if (/^[a-z0-9._+-]+$/.test(name) && name !== "grassfield" && out.indexOf(name + "-mimeapps.list") < 0)
            out.push(name + "-mimeapps.list");
    }
    out.push("mimeapps.list");
    return out;
}

// What the user's own lists name for each web type now: {type: id or ""}. The record keeps it as the baseline against which a later
// change (xdg-settings, omarchy default browser, a browser's own check) is seen.
function baseline(ownTexts) {
    const out = {};
    for (const t of WEB_TYPES)
        out[t] = lookedUp(ownTexts, t);
    return out;
}

// The list text with `type` set to `id` in [Default Applications] (the group added when missing); every other line kept, a
// repeated key of the group dropped.
function withDefault(listText, type, id) {
    let lines = String(listText) === "" ? [] : String(listText).split("\n");
    if (lines.length > 0 && lines[lines.length - 1] === "")
        lines.pop();
    const entry = type + "=" + id + ";";
    let group = -1;
    let end = lines.length;
    for (let i = 0; i < lines.length; i++) {
        if (!lines[i].trim().startsWith("["))
            continue;
        if (group >= 0) {
            end = i;
            break;
        }
        if (lines[i].trim() === GROUP)
            group = i;
    }
    if (group < 0) {
        if (lines.length > 0 && lines[lines.length - 1].trim() !== "")
            lines.push("");
        lines.push(GROUP, entry);
        return lines.join("\n") + "\n";
    }
    let at = -1;
    const keep = [];
    for (let i = 0; i < lines.length; i++) {
        const inside = i > group && i < end;
        const eq = lines[i].indexOf("=");
        const isKey = inside && eq > 0 && !lines[i].trim().startsWith("#") && lines[i].slice(0, eq).trim() === type;
        if (isKey) {
            if (at < 0) {
                at = keep.length;
                keep.push(entry);
            }
            continue;
        }
        keep.push(lines[i]);
    }
    if (at < 0) {
        let last = group;
        for (let i = group + 1; i < keep.length && !keep[i].trim().startsWith("["); i++) {
            if (keep[i].trim() !== "")
                last = i;
        }
        keep.splice(last + 1, 0, entry);
    }
    return keep.join("\n") + "\n";
}

// The session's list with the four web types set to `id`; null when `id` is not a desktop id.
function withBrowser(listText, id) {
    if (!validId(id) || id === ROUTING)
        return null;
    let text = String(listText);
    for (const type of WEB_TYPES)
        text = withDefault(text, type, id);
    return text;
}

// The record's text for a choice of the user's: web.state=user, web.chosen=<id> and web.<type> = the baseline ("-" for nothing); the
// other lines of a readable record are kept, a line that is no key=value is dropped. Sorted, as the other two writers do.
function stateWithUser(stateText, chosen, base) {
    const own = {"web.state": "user", "web.chosen": chosen};
    for (const t of WEB_TYPES)
        own["web." + t] = base && base[t] ? base[t] : "-";
    const keep = [];
    for (const raw of String(stateText).split("\n")) {
        const line = raw.trim();
        if (line === "" || line.startsWith("#") || line.indexOf("=") <= 0)
            continue;
        if (own[line.slice(0, line.indexOf("="))] !== undefined)
            continue;
        keep.push(line);
    }
    for (const k of Object.keys(own))
        keep.push(k + "=" + own[k]);
    keep.sort();
    return "# Written by grassfield-files --seed-default-apps, the xdg-settings stand-in and Settings > Desktop & Dock (ADR-0055 D-6)\n" + keep.join("\n") + "\n";
}
