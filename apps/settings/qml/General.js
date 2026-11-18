.pragma library

// Pure logic of the General pane's sub-panes (PR #6): About, Storage, Date & Time, Language & Region and Login Items. The
// pages give it what the Backend read (the D-Bus states as JSON, command output, file text) and get back plain values and
// the action maps the Backend checks again (systembus.cpp, systemguard.cpp). Tested by tests/unit/tst_settingsgeneral.qml.

// A D-Bus state (Backend.busQuery) as an object; null when it is not a JSON object.
function parseJson(text) {
    try {
        const v = JSON.parse(String(text));
        return v !== null && typeof v === "object" && !Array.isArray(v) ? v : null;
    } catch (e) {
        return null;
    }
}

function str(v) {
    return typeof v === "string" ? v : "";
}

// --- About ---------------------------------------------------------------------------------------------------------------

// hostname1's state: {pretty, static, hostname, chassis, vendor, model}, every field a string.
function parseHost(text) {
    const v = parseJson(text);
    if (!v)
        return null;
    return {pretty: str(v.pretty), "static": str(v["static"]), hostname: str(v.hostname), chassis: str(v.chassis), vendor: str(v.vendor), model: str(v.model)};
}

// The picture of the About header: a laptop for portable chassis, a display for everything else.
function deviceKind(chassis) {
    return ["laptop", "convertible", "tablet", "handset"].indexOf(String(chassis)) >= 0 ? "laptop" : "desktop";
}

// Firmware placeholders that are not a product name.
var PLACEHOLDERS = ["to be filled by o.e.m.", "system product name", "system manufacturer", "default string", "not specified", "none",
    "o.e.m.", "oem", "type1productconfigid", "system version", "unknown", "x.x"];

function realName(s) {
    const t = String(s).trim().replace(/\s+/g, " ");
    return t !== "" && PLACEHOLDERS.indexOf(t.toLowerCase()) < 0 ? t : "";
}

// "Lenovo ThinkPad X1 Carbon Gen 11": the model, with the vendor in front unless it already names it; "" when the firmware
// names neither.
function modelName(host) {
    if (!host)
        return "";
    const vendor = realName(host.vendor);
    const model = realName(host.model);
    if (model === "")
        return vendor;
    if (vendor === "" || model.toLowerCase().indexOf(vendor.toLowerCase().split(" ")[0]) === 0)
        return model;
    return vendor + " " + model;
}

// The computer's name as the user gave it: the pretty name, else the static host name, else the transient one.
function computerName(host) {
    if (!host)
        return "";
    return host.pretty !== "" ? host.pretty : (host["static"] !== "" ? host["static"] : host.hostname);
}

// A computer name the Backend accepts: 1 to 64 characters once trimmed, no control character.
function validComputerName(name) {
    const t = String(name).trim();
    return t.length > 0 && t.length <= 64 && !/[\x00-\x1f\x7f]/.test(t);
}

// hostname1 SetPrettyHostname (then SetStaticHostname, systembus.cpp): null for a name that is not valid.
function hostSetName(name) {
    return validComputerName(name) ? {op: "host.setName", name: String(name).trim()} : null;
}

// The diagonal of a panel in inches, to one decimal (13.3), from its size in millimetres; 0 when the output gives none.
function diagonalInches(widthMm, heightMm) {
    const w = Number(widthMm), h = Number(heightMm);
    if (!(w > 0) || !(h > 0))
        return 0;
    return Math.round(Math.sqrt(w * w + h * h) / 25.4 * 10) / 10;
}

// The start-up volume of Backend.volumes() (the first), null when there is none.
function startupVolume(volumes) {
    // Any list (a QVariantList from the Backend need not be a JavaScript Array).
    return volumes && volumes.length > 0 ? volumes[0] : null;
}

// --- Storage -------------------------------------------------------------------------------------------------------------

// `du -s -x --block-size=1 -- <paths>`: {path: bytes}. A folder du could not read is absent.
function parseDu(text) {
    const out = {};
    for (const line of String(text).split("\n")) {
        const m = /^(\d+)\t(\/.*)$/.exec(line);
        if (m)
            out[m[2]] = Number(m[1]);
    }
    return out;
}

var UNITS = {"B": 1, "KiB": 1024, "MiB": 1048576, "GiB": 1073741824, "TiB": 1099511627776};

// The sum of the "Installed Size" lines of `pacman -Qi` (C locale): the size of the installed packages, in bytes.
function packagesBytes(text) {
    let sum = 0;
    for (const line of String(text).split("\n")) {
        const m = /^Installed Size\s*:\s*([0-9.]+)\s*(B|KiB|MiB|GiB|TiB)\s*$/.exec(line);
        if (m)
            sum += Number(m[1]) * UNITS[m[2]];
    }
    return Math.round(sum);
}

// The folders of the home the Storage pane counts, in the order of its list (the Trash last).
function userFolders(home) {
    const h = String(home);
    return [
        {id: "documents", path: h + "/Documents"},
        {id: "downloads", path: h + "/Downloads"},
        {id: "desktop", path: h + "/Desktop"},
        {id: "pictures", path: h + "/Pictures"},
        {id: "music", path: h + "/Music"},
        {id: "videos", path: h + "/Videos"},
        {id: "trash", path: h + "/.local/share/Trash"}
    ];
}

// The du command of the Storage pane (systemguard.cpp isFolderSizeQuery): only folders inside the home.
function duArgv(home) {
    return ["du", "-s", "-x", "--block-size=1", "--"].concat(userFolders(home).map(f => f.path));
}

// The categories of the start-up volume's bar, largest first: the user's folders and Applications (each 0 when unknown),
// then "System" for the rest of what is used (never below 0). [{id, bytes}]
function categories(volume, folderBytes, applicationsBytes, home) {
    if (!volume)
        return [];
    const used = Math.max(0, Number(volume.total) - Number(volume.available));
    const out = [];
    let counted = 0;
    const apps = Math.max(0, Number(applicationsBytes) || 0);
    if (apps > 0) {
        out.push({id: "applications", bytes: apps});
        counted += apps;
    }
    for (const f of userFolders(home)) {
        const b = Math.max(0, Number((folderBytes || {})[f.path]) || 0);
        if (b > 0) {
            out.push({id: f.id, bytes: b});
            counted += b;
        }
    }
    out.sort((a, b) => b.bytes - a.bytes);
    out.push({id: "system", bytes: Math.max(0, used - counted)});
    return out;
}

// The widths of the bar's segments: `sizes` (bytes, the free space last) shared out over `width` less a `gap` between two
// segments, each at least `min` wide; the last segment takes what rounding leaves. Whole points, so the gaps stay sharp.
function barWidths(sizes, width, gap, min) {
    const n = sizes.length;
    if (n === 0)
        return [];
    const room = Math.max(0, width - gap * (n - 1));
    const total = sizes.reduce((a, b) => a + Math.max(0, Number(b) || 0), 0);
    const out = sizes.map(b => total > 0 ? Math.max(min, Math.floor(room * Math.max(0, Number(b) || 0) / total)) : 0);
    const used = out.slice(0, n - 1).reduce((a, b) => a + b, 0);
    out[n - 1] = Math.max(0, room - used);
    return out;
}

// --- Date & Time ---------------------------------------------------------------------------------------------------------

// timedate1 / timesync1: {zone, ntp, canNtp, synced, localRtc, usec (string), server, servers[]}.
function parseTime(text) {
    const v = parseJson(text);
    if (!v)
        return null;
    return {
        zone: str(v.zone), ntp: v.ntp === true, canNtp: v.canNtp === true, synced: v.synced === true, localRtc: v.localRtc === true,
        usec: /^[0-9]{1,17}$/.test(str(v.usec)) ? str(v.usec) : "0", server: str(v.server),
        servers: Array.isArray(v.servers) ? v.servers.filter(s => typeof s === "string") : []
    };
}

// timedate1 ListTimezones: the zone names.
function parseZones(text) {
    const v = parseJson(text);
    return v && Array.isArray(v.zones) ? v.zones.filter(z => typeof z === "string" && validZone(z)) : [];
}

function validZone(zone) {
    return typeof zone === "string" && zone.length <= 64 && /^[A-Za-z0-9_+-]+(\/[A-Za-z0-9_+-]+){0,3}$/.test(zone);
}

// "America/Argentina/Buenos_Aires" -> "Buenos Aires"; "UTC" -> "UTC".
function cityOf(zone) {
    const parts = String(zone).split("/");
    return parts[parts.length - 1].replace(/_/g, " ");
}

// "Europe/Paris" -> "Europe"; "UTC" -> "".
function areaOf(zone) {
    const parts = String(zone).split("/");
    return parts.length > 1 ? parts[0].replace(/_/g, " ") : "";
}

// Lower case without accents, for matching what is typed ("Zürich" and "zurich").
function fold(s) {
    return String(s).normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
}

// The zones whose city starts with what is typed, then those that contain it, at most `limit`.
function cityMatches(zones, typed, limit) {
    const q = fold(String(typed).trim());
    if (q === "")
        return [];
    const starts = [], contains = [];
    for (const z of zones) {
        const c = fold(cityOf(z));
        if (c.indexOf(q) === 0)
            starts.push(z);
        else if (c.indexOf(q) > 0 || fold(z).indexOf(q) >= 0)
            contains.push(z);
    }
    return starts.concat(contains).slice(0, limit);
}

// The time timedate1 reported, in milliseconds since the epoch.
function msOf(time) {
    return time ? Math.floor(Number(time.usec) / 1000) : 0;
}

function timeNtp(on) {
    return typeof on === "boolean" ? {op: "time.ntp", on: on} : null;
}

function timeZone(zone) {
    return validZone(zone) ? {op: "time.zone", zone: zone} : null;
}

// A Date whose local fields read as the wall clock of a zone `offsetSec` east of UTC at `ms` (the page shows the time zone
// timedate1 reports, which this process may not have picked up yet).
function wallClock(ms, offsetSec) {
    const d = new Date(ms);
    return new Date(ms + offsetSec * 1000 + d.getTimezoneOffset() * 60000);
}

// The inverse, for a time the user set as that zone's wall clock.
function fromWallClock(wall, offsetSec) {
    return wall.getTime() - offsetSec * 1000 - wall.getTimezoneOffset() * 60000;
}

// The same when the zone's offset is not the same all year: `offsetAt(ms)` gives the zone's offset at an instant, so a date
// set across a daylight-saving change uses the offset of that date and not today's (January set in July was an hour off).
// Today's offset finds the instant near enough to ask for its own; asked twice for a time next to the change itself.
function fromWallClockAt(wall, offsetSec, offsetAt) {
    let ms = fromWallClock(wall, offsetSec);
    for (let i = 0; i < 2; i++)
        ms = fromWallClock(wall, offsetAt(ms));
    return ms;
}

// Whether the clock reads 24-hour: menubar.clockHours "24", or "auto" in a region whose short time has no AM/PM.
function uses24Hour(setting, shortTimeFormat) {
    if (setting === "24" || setting === "12")
        return setting === "24";
    return !/[aA]/.test(String(shortTimeFormat).replace(/'[^']*'/g, ""));
}

// The Date & Time change still waiting for its answer ("ntp", "set", "zone"; "" for none), from Backend.pendingActions (tag ->
// what). The Backend holds it, so the page shows it again when it is opened while the polkit dialog is still up.
function pendingTimeOp(pending) {
    const what = (pending || {})["time.act"];
    return what === "automatic time" ? "ntp" : what === "date and time" ? "set" : what === "time zone" ? "zone" : "";
}

// SetTime: a date between 2000 and 2200 (systembus.cpp isUsec), as microseconds in a string.
function timeSet(ms) {
    const n = Math.floor(Number(ms));
    if (!(n >= 946684800000 && n <= 7258118400000))
        return null;
    return {op: "time.set", usec: String(n) + "000"};
}

// --- Language & Region ---------------------------------------------------------------------------------------------------

// `omarchy-language list`: one "native name<TAB>code<TAB>English name" line per language.
function parseLanguages(text) {
    const out = [];
    for (const line of String(text).split("\n")) {
        const f = line.split("\t");
        if (f.length >= 3 && validLanguage(f[1].trim()))
            out.push({name: f[0].trim(), code: f[1].trim(), english: f[2].trim()});
    }
    return out;
}

function validLanguage(code) {
    return typeof code === "string" && /^[a-z]{2,3}(-[A-Za-z]{2,4})?$/.test(code);
}

// `omarchy-language` (no argument): the current code.
function currentLanguage(text) {
    const t = String(text).trim();
    return validLanguage(t) ? t : "";
}

// Why Language & Region shows the session's language instead of Omarchy's list: "tool" when the installed Omarchy has no
// `omarchy-language` (4.0.4 has none), "list" when it gave no list in a real session, "" otherwise (the list is there, it is
// still being read, or this is a dev session, which reads nothing from it and whose own note says so).
function languageNote(installed, dev, answered, count) {
    if (!installed)
        return "tool";
    return !dev && answered && count === 0 ? "list" : "";
}

// The session's language as a name ("Français", "American English"), from its locale's own name of it.
function languageName(nativeName, code) {
    const t = String(nativeName || "");
    return t !== "" ? t.charAt(0).toLocaleUpperCase() + t.slice(1) : String(code || "");
}

function languageArgv(code) {
    return validLanguage(code) ? ["omarchy-language", code] : null;
}

// The locale the shell formats with (ui/i18n/translationloader.h formatsLocale, the same rule): "auto" is the language's
// (`uiName`, "fr_FR"); a region ("fr_CH") gives the language in that territory when Qt has the pair, else the region's own.
function formatsLocale(uiName, formats) {
    if (!/^[a-z]{2,3}(_[A-Z][a-z]{3})?_([A-Z]{2}|[0-9]{3})$/.test(String(formats)))
        return Qt.locale(uiName);
    const language = String(uiName).split("_")[0];
    const territory = String(formats).split("_").pop();
    const pair = Qt.locale(language + "_" + territory);
    return pair.name === language + "_" + territory ? pair : Qt.locale(formats);
}

// --- Login Items ---------------------------------------------------------------------------------------------------------

// One desktop entry's [Desktop Entry] group: {name, exec, icon, hidden, noDisplay, onlyShowIn[], notShowIn[], autostartEnabled,
// type}. `lang` ("fr", "fr_FR") picks a localised Name when there is one.
function parseDesktopEntry(text, lang) {
    const e = {name: "", exec: "", icon: "", hidden: false, noDisplay: false, onlyShowIn: [], notShowIn: [], autostartEnabled: true, type: ""};
    let inGroup = false;
    let localised = "";
    const short = String(lang).split(/[_.@]/)[0];
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
        else if (key === "Exec")
            e.exec = value;
        else if (key === "Icon")
            e.icon = value;
        else if (key === "Type")
            e.type = value;
        else if (key === "Hidden")
            e.hidden = value === "true";
        else if (key === "NoDisplay")
            e.noDisplay = value === "true";
        else if (key === "OnlyShowIn")
            e.onlyShowIn = value.split(";").filter(s => s !== "");
        else if (key === "NotShowIn")
            e.notShowIn = value.split(";").filter(s => s !== "");
        else if (key === "X-GNOME-Autostart-enabled")
            e.autostartEnabled = value !== "false";
    }
    if (localised !== "")
        e.name = localised;
    return e;
}

// Whether an autostart entry starts in this session (XDG Autostart: not Hidden, the desktop allowed by OnlyShowIn/NotShowIn).
// `desktops`: XDG_CURRENT_DESKTOP split on ':'.
function startsHere(entry, desktops) {
    if (!entry || entry.hidden || !entry.autostartEnabled)
        return false;
    if (entry.onlyShowIn.length > 0 && !entry.onlyShowIn.some(d => desktops.indexOf(d) >= 0))
        return false;
    return !entry.notShowIn.some(d => desktops.indexOf(d) >= 0);
}

// The login items: the user's folder overrides a system entry of the same file name (XDG Autostart). `user` and `system`:
// [{file, text}] (the system list in priority order). Returns [{file, name, icon, user, enabled}], sorted by name; an entry
// for another desktop is left out.
function loginItems(user, system, desktops, lang) {
    const byFile = {};
    for (const s of system) {
        if (byFile[s.file] === undefined)
            byFile[s.file] = {file: s.file, entry: parseDesktopEntry(s.text, lang), base: null, user: false, system: true};
    }
    for (const u of user) {
        const shipped = byFile[u.file];
        byFile[u.file] = {file: u.file, entry: parseDesktopEntry(u.text, lang), base: shipped ? shipped.entry : null, user: true, system: shipped !== undefined};
    }
    const out = [];
    for (const f in byFile) {
        const it = byFile[f];
        const e = it.entry;
        // A user file that only hides a system one (Hidden=true, often nothing else) keeps the item in the list, switched off,
        // under the system entry's name and icon.
        const shown = it.base ? it.base : e;
        const forDesktop = startsHere(Object.assign({}, shown, {hidden: false, autostartEnabled: true}), desktops);
        const name = e.name !== "" ? e.name : shown.name;
        if (!forDesktop || (name === "" && !it.system))
            continue;
        out.push({file: f, name: name !== "" ? name : f.replace(/\.desktop$/, ""), icon: e.icon !== "" ? e.icon : shown.icon, user: it.user, system: it.system,
            enabled: startsHere(e, desktops)});
    }
    out.sort((a, b) => a.name.localeCompare(b.name));
    return out;
}

// A plain desktop file name the Backend writes (backend.cpp autostartWriteAllowed).
function validEntryFile(file) {
    return typeof file === "string" && /^[A-Za-z0-9._+-]{1,200}\.desktop$/.test(file);
}

// The user file that hides a system login item, or turns it back on (a copy of the system entry without Hidden).
function hiddenEntryText() {
    return "[Desktop Entry]\nType=Application\nHidden=true\n";
}

// A new login item from an application's desktop entry: its own text, with the autostart keys of this desktop removed and
// Hidden left out, so it starts at the next login.
function loginEntryText(appText) {
    const out = [];
    let inGroup = false;
    for (const raw of String(appText).split("\n")) {
        const line = raw.trim();
        if (line.startsWith("["))
            inGroup = line === "[Desktop Entry]";
        if (inGroup && /^(Hidden|X-GNOME-Autostart-enabled|OnlyShowIn|NotShowIn)\s*=/.test(line))
            continue;
        out.push(raw);
    }
    return out.join("\n").replace(/\n*$/, "\n");
}

// A user autostart file with Hidden set or cleared in its [Desktop Entry] group (the rest kept as it is).
function setHidden(text, hidden) {
    const out = [];
    let inGroup = false;
    for (const raw of String(text).split("\n")) {
        const line = raw.trim();
        if (line.startsWith("[")) {
            inGroup = line === "[Desktop Entry]";
            out.push(raw);
            if (inGroup && hidden)
                out.push("Hidden=true");
            continue;
        }
        if (inGroup && /^Hidden\s*=/.test(line))
            continue;
        out.push(raw);
    }
    return out.join("\n").replace(/\n*$/, "\n");
}

// What a user file that only switched a system item off holds once it is switched back on: nothing worth keeping (the file
// goes, and the system entry applies again).
function onlyOverride(text) {
    return /^\[Desktop Entry\]\n(Type=Application\n)?$/.test(setHidden(text, false));
}

// The applications one can add as login items: [{file, text}] from the applications folders (the first folder wins for a file
// name), without the hidden ones and those for another desktop, sorted by name. Returns [{file, name, icon, text}].
function applications(entries, desktops, lang) {
    const seen = {};
    const out = [];
    for (const a of entries) {
        if (seen[a.file] || !validEntryFile(a.file))
            continue;
        seen[a.file] = true;
        const e = parseDesktopEntry(a.text, lang);
        if (e.type !== "Application" || e.noDisplay || e.hidden || e.name === "" || e.exec === "" || !startsHere(e, desktops))
            continue;
        out.push({file: a.file, name: e.name, icon: e.icon, text: a.text});
    }
    out.sort((a, b) => a.name.localeCompare(b.name));
    return out;
}

// systemd (session bus) EnableUnitFiles / DisableUnitFiles of one of the user's own services.
function userEnable(unit, on) {
    if (typeof unit !== "string" || unit.length > 200 || !/^[A-Za-z0-9:_.@-]+\.service$/.test(unit) || typeof on !== "boolean")
        return null;
    return {op: "user.enable", unit: unit, on: on};
}

// A unit file's Description= ([Unit] group), "" when it has none.
function unitDescription(text) {
    let inUnit = false;
    for (const raw of String(text).split("\n")) {
        const line = raw.trim();
        if (line.startsWith("["))
            inUnit = line === "[Unit]";
        else if (inUnit && /^Description\s*=/.test(line))
            return line.slice(line.indexOf("=") + 1).trim();
    }
    return "";
}

// systemd's user units state: [{unit, path, state}].
function parseUnits(text) {
    const v = parseJson(text);
    return v && Array.isArray(v.units) ? v.units.filter(u => u && typeof u.unit === "string" && typeof u.state === "string") : [];
}

// ---- About > Create Diagnostic Report… (ADR-0053) -----------------------------------------------------------------------

// The installed report tool, run with no argument (systemguard.cpp isAllowedAction takes exactly this).
var REPORT_ARGV = ["/usr/lib/grassfield/grassfield-report"];

// The file grassfield-report printed (its last non-empty line): an absolute, clean path to a grassfield-report-*.txt file,
// without control characters; "" for anything else. Anywhere: the user's Downloads folder (XDG_DOWNLOAD_DIR) may lie outside
// the home, and the report was written all the same.
function reportPath(output) {
    if (typeof output !== "string")
        return "";
    const lines = output.split("\n").map(l => l.trim()).filter(l => l !== "");
    const path = lines.length > 0 ? lines[lines.length - 1] : "";
    if (!path.startsWith("/") || /[\u0000-\u001f\u007f]/.test(path) || /(^|\/)\.{1,2}(\/|$)/.test(path) || path.indexOf("//") >= 0)
        return "";
    return /^grassfield-report-[^/]+\.txt$/.test(reportName(path)) ? path : "";
}

// Whether Files may show the report's folder: inside the home only (systemguard.cpp isRevealInFiles holds the same rule).
function revealable(path, home) {
    if (typeof path !== "string" || path === "" || typeof home !== "string" || !home.startsWith("/"))
        return false;
    const h = home.replace(/\/+$/, "");
    return h !== "" && path.startsWith(h + "/");
}

// The file's name.
function reportName(path) {
    return typeof path === "string" ? path.slice(path.lastIndexOf("/") + 1) : "";
}

// The command that shows the report's folder in Files (systemguard.cpp isRevealInFiles).
function revealArgv(path) {
    return ["/usr/bin/grassfield-files", "--", path.slice(0, path.lastIndexOf("/"))];
}
