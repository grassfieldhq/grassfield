.pragma library

// Launch helpers of Apps.qml (docs/specs/dock.md, "Dev notes: isolated app launches"). Pure functions.

// Environment that isolates the config, cache and state of every app launched from a GRASSFIELD_DEV session
// (XDG_DATA_DIRS stays: system desktop entries and icons must still resolve; XDG_DATA_HOME is isolated too).
function isolatedEnvironment(appsHome) {
    return {
        "XDG_CONFIG_HOME": appsHome + "/config",
        "XDG_CACHE_HOME": appsHome + "/cache",
        "XDG_STATE_HOME": appsHome + "/state",
        "XDG_DATA_HOME": appsHome + "/data",
        // An app's HOME too: file managers, editors and shells otherwise open and write the owner's home.
        "HOME": appsHome + "/home"
    };
}

// What the apps the shell starts get back of the session's portal routing (ADR-0035 D-8): the shell's unit clears
// GTK_USE_PORTAL for the shell itself (its gtk3 platform theme would wait on the portal at start, gate P5), and env-grassfield
// records that the session sets it (Mode.appsGtkPortal). `on` is that answer.
function portalEnvironment(on) {
    return on === true ? {"GTK_USE_PORTAL": "1"} : {};
}

// The Qt platform theme the session chose (ADR-0054), given back to the apps the shell starts: the shell's own unit pins gtk3 (Qt's
// portal theme asks the portal at start, gate P5) and an app inherits the shell's environment (a uwsm-app scope runs the command in
// its caller's environment), so the session's value travels in GRASSFIELD_APPS_QT_QPA_PLATFORMTHEME. Only the one value the session
// sets, exactly; anything else leaves the app with the shell's value.
function themeEnvironment(value) {
    return value === "xdgdesktopportal" ? {"QT_QPA_PLATFORMTHEME": value} : {};
}

// `extra` entries added to `base` (a new object, neither input changes).
function mergeEnvironment(base, extra) {
    const out = {};
    for (const k in base)
        out[k] = base[k];
    for (const k in extra)
        out[k] = extra[k];
    return out;
}

// Directory of the isolated homes: `<dev>/apps-home`, where <dev> is the parent of GRASSFIELD_STATE_HOME
// (scripts/dev/shell-run.sh passes `<dev>/state`); `fallbackBase` (a scratch directory) when it is unset.
function appsHomeFor(stateHome, fallbackBase) {
    const s = String(stateHome || "").replace(/\/+$/, "");
    const i = s.lastIndexOf("/");
    if (i > 0)
        return s.substring(0, i) + "/apps-home";
    return fallbackBase + "/grassfield-dev/apps-home";
}

// argv of an application started in a scope of its own (app-graphical.slice) through uwsm's app launcher, as the Omarchy
// session starts its apps. A process the shell starts otherwise stays in the shell's systemd unit, and a restart or a
// crash of the shell (Restart=on-failure stops the whole control group) takes every such application down with it
// (macOS: the Dock quitting never quits an app). `scoped` false (a dev session, or no uwsm-app): argv unchanged.
function scopedArgv(argv, scoped) {
    const a = Array.from(argv || []);
    return scoped && a.length > 0 ? ["uwsm-app", "--"].concat(a) : a;
}

// argv of a desktop entry or action `command` (QStringList): Exec field codes (%f %F %u %U %i %c %k and
// the deprecated ones) are dropped, "%%" is a literal percent. [] when nothing is left.
function stripFieldCodes(command) {
    const out = [];
    for (const arg of Array.from(command || [])) {
        const a = String(arg);
        if (/^%[a-zA-Z]$/.test(a))
            continue;
        out.push(a.replace(/%(.)/g, (m, c) => c === "%" ? "%" : ""));
    }
    return out;
}

// What an "open this in an application" helper command asks for (dev open policy, ADR-0011).
//   gio open T...   xdg-open T   gtk-launch APP [T...]  -> { targets: [T...] }
//   gio launch ...  gtk-launch APP (no target)          -> { refuse: "application launch" }
//   any other command (gio trash, nm-connection-editor)  -> null: not an open request, runs as given.
function openRequest(argv) {
    const a = Array.from(argv || []).map(String);
    const name = a.length > 0 ? a[0].replace(/^.*\//, "") : "";
    if (name === "gio" && a[1] === "open")
        return a.length > 2 ? {"targets": a.slice(2)} : {"refuse": "nothing to open"};
    if (name === "gio" && a[1] === "launch")
        return {"refuse": "application launch"};
    if (name === "xdg-open")
        return a.length > 1 ? {"targets": a.slice(1)} : {"refuse": "nothing to open"};
    if (name === "gtk-launch")
        return a.length > 2 ? {"targets": a.slice(2)} : {"refuse": "application launch"};
    return null;
}

// Real-session open policy (docs/specs/files.md, "Default file manager"): `gio open T...` and `xdg-open T` become
// `bash <script> <opener> T...`, where the script (services/open-real.sh) opens every folder in Grassfield Files and hands
// the rest to the opener. Any other command (gtk-launch, gio trash, ...) and a dev session (`enabled` false, the dev open
// policy applies) are returned unchanged.
function folderAwareArgv(argv, script, enabled) {
    const a = Array.from(argv || []).map(String);
    if (!enabled)
        return a;
    const name = a.length > 0 ? a[0].replace(/^.*\//, "") : "";
    if (name === "gio" && a[1] === "open" && a.length > 2)
        return ["bash", script, "gio"].concat(a.slice(2));
    if (name === "xdg-open" && a.length > 1)
        return ["bash", script, "xdg-open"].concat(a.slice(1));
    return a;
}

// argv that empties the Trash (Dock Trash menu, after its confirmation). A real session asks gio (every trash of the user). A dev session
// never does: gio's trash:/// is served by the owner's session, so it empties ONLY the isolated trash under the dev apps-home
// (`<appsHome>/data/Trash`, where the shell's own trash actions put files, ADR-0011) with find; null (nothing runs) when `appsHome`
// is not a plain absolute `.../apps-home` path (control characters, `.`/`..`/empty segments, too shallow).
function emptyTrashArgv(devSession, appsHome) {
    if (!devSession)
        return ["gio", "trash", "--empty"];
    const home = String(appsHome || "");
    // eslint-disable-next-line no-control-regex
    if (!/^\/[^\u0000-\u001f\u007f]+\/apps-home$/.test(home))
        return null;
    if (home.split("/").slice(1).some(seg => seg === "" || seg === "." || seg === ".."))
        return null;
    return ["find", home + "/data/Trash/files", home + "/data/Trash/info", "-mindepth", "1", "-delete"];
}

// Directory of the user's autostart entries (XDG): `<appsHome>/config/autostart` in a dev session (never the owner's
// own), else `$XDG_CONFIG_HOME/autostart` or `~/.config/autostart`.
function autostartDir(devSession, appsHome, xdgConfigHome, home) {
    if (devSession)
        return appsHome + "/config/autostart";
    return (xdgConfigHome ? xdgConfigHome : home + "/.config") + "/autostart";
}

// The XDG data home the shell itself reads (recently-used.xbel): `<appsHome>/data` in a dev session (never the owner's
// own recent files; the place isolatedEnvironment gives the apps), else `$XDG_DATA_HOME` or `~/.local/share`.
function dataHome(devSession, appsHome, xdgDataHome, home) {
    if (devSession)
        return appsHome + "/data";
    return xdgDataHome ? xdgDataHome : home + "/.local/share";
}

// Root the file results of Search and the recent documents are limited to: GRASSFIELD_SEARCH_ROOT (`devRoot`, "" outside dev)
// when set; else `<appsHome>/files` in a dev session (never the owner's $HOME: the results are filtered by this prefix, so a
// missing folder just lists nothing); else `home`.
function searchRoot(devSession, devRoot, appsHome, home) {
    if (devRoot)
        return devRoot;
    return devSession ? appsHome + "/files" : home;
}

// A control character (C0, DEL, C1) anywhere in `v`.
function hasControl(v) {
    return /[\u0000-\u001f\u007f-\u009f]/.test(String(v));
}

// Desktop Entry spec "string" value escaping: backslash, newline, tab, carriage return (and a leading space as \s).
function escapeValue(v) {
    return String(v === undefined || v === null ? "" : v).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g, "").replace(/\\/g, "\\\\").replace(/\n/g, "\\n").replace(/\t/g, "\\t").replace(/\r/g, "\\r").replace(/^ /, "\\s");
}

// One Exec argument quoted for a desktop file (the Exec quoting rule: an argument with reserved characters goes inside double
// quotes with `"`, backtick, `$` and `\` escaped by a backslash; % is doubled). The result still goes through escapeValue()
// as part of the Exec value (the spec applies the string escape after the quoting rule).
function execQuote(arg) {
    const a = String(arg).replace(/%/g, "%%");
    if (/^[A-Za-z0-9_\/.,:=+@-]+$/.test(a))
        return a;
    return '"' + a.replace(/(["`$\\])/g, "\\$1") + '"';
}

// File name of the autostart entry of the desktop entry `id` inside `dir`: "" for an id that is not a plain file name
// (separator, leading dot, control character, empty, too long), so that the file can only land directly in `dir`.
function autostartFile(dir, id) {
    const s = String(id === undefined || id === null ? "" : id);
    if (s === "" || s.length > 200 || s[0] === "." || /[\/\\]/.test(s) || hasControl(s) || !dir)
        return "";
    return dir + "/" + s + ".desktop";
}

// Text of an autostart desktop file for an entry (name, icon, command, runInTerminal), values escaped per the Desktop Entry
// spec (a newline in a name cannot add keys). "" (refused) when the command is empty or an Exec argument has a control
// character.
function autostartText(entry) {
    const args = stripFieldCodes(entry.command);
    if (args.length === 0 || args.some(hasControl))
        return "";
    let text = "[Desktop Entry]\nType=Application\nName=" + escapeValue(entry.name) + "\nExec=" + escapeValue(args.map(execQuote).join(" ")) + "\n";
    if (entry.icon)
        text += "Icon=" + escapeValue(entry.icon) + "\n";
    text += "Terminal=" + (entry.runInTerminal === true ? "true" : "false") + "\n";
    return text;
}
