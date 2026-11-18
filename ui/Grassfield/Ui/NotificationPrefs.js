.pragma library

// Per-app notification previews (ADR-0004, C-NOTIF-2; macOS: System Settings > Notifications > <app> > Show previews).
// The global `notifications.previews` (always | unlocked | never) is the default; `notifications.appPreviews` lists the apps
// that override it: [{app, previews}], `app` being the sender's name (Notification.appName, the key the Notifications
// column groups by). Pure functions, no I/O; shared by the shell store, the Settings app and the notification service.

const VALUES = ["always", "unlocked", "never"];
const MAX_APPS = 200;
const MAX_NAME = 128;

function validPreviews(value) {
    return VALUES.indexOf(value) >= 0;
}

// Same app, whatever the case or the surrounding blanks.
function keyOf(app) {
    return typeof app === "string" ? app.trim().toLowerCase() : "";
}

// The tables keyed by an app's name below have no prototype: an app may be named "constructor" or "__proto__".
function validApp(app) {
    return typeof app === "string" && app.trim() !== "" && app.length <= MAX_NAME && !/[\u0000-\u001f\u007f]/.test(app);
}

// "" when `list` is a valid appPreviews array (at most MAX_APPS valid entries, no app twice), else the reason.
function problem(list) {
    if (!Array.isArray(list))
        return "expected a list";
    if (list.length > MAX_APPS)
        return "at most " + MAX_APPS + " apps";
    const seen = Object.create(null);
    for (const e of list) {
        if (e === null || typeof e !== "object" || Array.isArray(e))
            return "each entry must be an object {app, previews}";
        if (!validApp(e.app))
            return "app: expected a name of 1 to " + MAX_NAME + " characters without control characters";
        if (!validPreviews(e.previews))
            return "previews: expected one of " + VALUES.join(", ");
        const k = keyOf(e.app);
        if (seen[k])
            return "app " + e.app + " appears twice";
        seen[k] = true;
    }
    return "";
}

// A list as a plain array: the shell's JSON adapter hands lists over as array-likes (a length and indexes), not as
// JavaScript arrays. Anything else, strings included, gives [].
function asArray(raw) {
    if (Array.isArray(raw))
        return raw;
    if (raw === null || typeof raw !== "object" || typeof raw.length !== "number")
        return [];
    const out = [];
    for (let i = 0; i < raw.length && i < MAX_APPS * 2; i++)
        out.push(raw[i]);
    return out;
}

// The valid entries of a stored value, without repeats and at most MAX_APPS; anything else gives [].
function normalize(raw) {
    const out = [];
    const seen = Object.create(null);
    for (const e of asArray(raw)) {
        if (e === null || typeof e !== "object" || !validApp(e.app) || !validPreviews(e.previews))
            continue;
        const k = keyOf(e.app);
        if (seen[k] || out.length >= MAX_APPS)
            continue;
        seen[k] = true;
        out.push({app: e.app, previews: e.previews});
    }
    return out;
}

// The app's own setting, or "default" when it follows the global one.
function valueFor(list, app) {
    const k = keyOf(app);
    for (const e of normalize(list)) {
        if (keyOf(e.app) === k)
            return e.previews;
    }
    return "default";
}

// The policy that applies to `app`: its own, else `globalValue` (an invalid global reads as "unlocked", the default).
function effective(list, app, globalValue) {
    const own = valueFor(list, app);
    if (own !== "default")
        return own;
    return validPreviews(globalValue) ? globalValue : "unlocked";
}

// A new list with `app` set to `value` (always, unlocked, never) or back to the default ("default" removes it).
function withValue(list, app, value) {
    const k = keyOf(app);
    const rest = normalize(list).filter(e => keyOf(e.app) !== k);
    if (!validApp(app) || !validPreviews(value))
        return rest;
    return rest.concat([{app: app, previews: value}]).slice(0, MAX_APPS);
}

// Whether the body of a notification is shown: "always" yes, "never" no, "unlocked" only while the session is not locked.
function bodyShown(policy, locked) {
    if (policy === "never")
        return false;
    if (policy === "unlocked")
        return !locked;
    return true;
}

// The apps the Settings page lists: the senders seen so far plus the apps with a setting, once each (first spelling kept),
// sorted by name.
function appsToList(seen, list) {
    const names = Object.create(null);
    const out = [];
    const add = name => {
        if (!validApp(name))
            return;
        const k = keyOf(name);
        if (names[k])
            return;
        names[k] = true;
        out.push(name);
    };
    for (const e of normalize(list))
        add(e.app);
    if (Array.isArray(seen))
        seen.forEach(add);
    return out.sort((a, b) => a.localeCompare(b));
}

// ---- alert style per app (GF-107; macOS: System Settings > Notifications > <app> > Banners / Alerts / None) ----------
// `notifications.appStyles` lists the apps that do not use the default style: [{app, style}]. "banners" (the default)
// disappear after a few seconds, "alerts" stay until they are dismissed, "none" shows no banner at all (the
// notification still collects in the Notifications panel).

const STYLES = ["banners", "alerts", "none"];

function validStyle(value) {
    return STYLES.indexOf(value) >= 0;
}

// "" when `list` is a valid appStyles array (at most MAX_APPS valid entries, no app twice), else the reason.
function problemStyles(list) {
    if (!Array.isArray(list))
        return "expected a list";
    if (list.length > MAX_APPS)
        return "at most " + MAX_APPS + " apps";
    const seen = Object.create(null);
    for (const e of list) {
        if (e === null || typeof e !== "object" || Array.isArray(e))
            return "each entry must be an object {app, style}";
        if (!validApp(e.app))
            return "app: expected a name of 1 to " + MAX_NAME + " characters without control characters";
        if (!validStyle(e.style))
            return "style: expected one of " + STYLES.join(", ");
        const k = keyOf(e.app);
        if (seen[k])
            return "app " + e.app + " appears twice";
        seen[k] = true;
    }
    return "";
}

// The valid entries of a stored value, without repeats and at most MAX_APPS; anything else gives [].
function normalizeStyles(raw) {
    const out = [];
    const seen = Object.create(null);
    for (const e of asArray(raw)) {
        if (e === null || typeof e !== "object" || !validApp(e.app) || !validStyle(e.style))
            continue;
        const k = keyOf(e.app);
        if (seen[k] || out.length >= MAX_APPS)
            continue;
        seen[k] = true;
        out.push({app: e.app, style: e.style});
    }
    return out;
}

// The style that applies to `app`: its own, else "banners".
function styleFor(list, app) {
    const k = keyOf(app);
    for (const e of normalizeStyles(list)) {
        if (keyOf(e.app) === k)
            return e.style;
    }
    return "banners";
}

// A new list with `app` set to `style`; "banners" (the default) removes the entry.
function withStyle(list, app, style) {
    const k = keyOf(app);
    const rest = normalizeStyles(list).filter(e => keyOf(e.app) !== k);
    if (!validApp(app) || !validStyle(style) || style === "banners")
        return rest;
    return rest.concat([{app: app, style: style}]).slice(0, MAX_APPS);
}

// Banner timeout for a new notification under `style`, from the timeout the sender and urgency would give (0 = stays):
// null when no banner is shown ("none"), 0 for an alert (stays until dismissed), else `timeoutMs` unchanged.
function bannerTimeoutFor(style, timeoutMs) {
    if (style === "none")
        return null;
    if (style === "alerts")
        return 0;
    return timeoutMs;
}

// ---- history (GF-113) -----------------------------------------------------------------------------------------------
// `notifications.history`: how long the notification history is kept on disk: "week" (default, as before), "day", or
// "never" (nothing is written; the Notifications panel still lists the session's notifications).

const HISTORY = ["week", "day", "never"];

function validHistory(value) {
    return HISTORY.indexOf(value) >= 0;
}

// Retention in ms for the setting; 0 when nothing is kept on disk. An invalid value reads as "week".
function historyMaxAge(value) {
    const day = 24 * 3600 * 1000;
    if (value === "never")
        return 0;
    return value === "day" ? day : 7 * day;
}

// What a notification shows: with previews hidden the app name is the title (`generic` when the sender has no name) and
// `generic` is the only line of text, never the sender's title or body (macOS); otherwise title and body as sent.
function display(shown, summary, body, appName, generic) {
    if (shown)
        return {title: summary, body: body};
    return {title: typeof appName === "string" && appName !== "" ? appName : generic, body: generic};
}

// The sender's picture (contact photo, attachment): with previews hidden only the app icon shows, so no image.
function imageShown(shown, image) {
    return shown ? image : "";
}

// The one test of a notification app icon NAME, used everywhere such a name reaches the icon theme (the shell's
// History.safeIconName calls it: intake, history load, iconSource; appIconShown below; and the polkit sheet's
// AuthDialogModel.iconName): 1-128 letters, digits, ".",
// "_", "-", starting with a letter or digit, no "..". So no "/", "\", ":", NUL, control characters or spaces: Qt also
// searches its fallback directory /usr/share/pixmaps, where "../../../dir/evil" named any file (review of 6e24d36).
// Returns the name, else "".
function safeIconName(name) {
    const s = typeof name === "string" ? name : "";
    return /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(s) && s.indexOf("..") < 0 ? s : "";
}

// The app icon: with previews hidden only a plain theme name stays (safeIconName: no path, URL or `..`;
// `notify-send -i /path/photo.jpg` is a picture of the sender's choosing, so the icon falls back to the generic one);
// shown as sent otherwise (the shell still applies safeIconName to a name, and shows a path only as its private copy).
function appIconShown(shown, appIcon) {
    if (shown)
        return appIcon;
    return safeIconName(appIcon);
}

// The sender's action buttons: shown once the content may be shown (macOS), none while previews are hidden.
function actionsShown(shown, actionsJson) {
    return shown ? actionsJson : "[]";
}
