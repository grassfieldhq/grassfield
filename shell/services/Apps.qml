pragma Singleton
import QtQuick
import Quickshell
import qs.lib
import Quickshell.Io
import Grassfield.I18n
import qs.platform
import "../launchpad/Model.js" as Model // layering-exception: GF-087
import "AppLaunch.js" as AppLaunch
import "../dock/DockModel.js" as DockModel // layering-exception: GF-087

// Desktop entry resolution shared by the menu bar and the Dock, and the list of entries that
// Search and Apps may show. Apps are identified by their foreign-toplevel app id mapped to a
// desktop entry, never by window title.
Singleton {
    id: root

    // Bumped when the desktop entry list changes so that bindings calling lookup()/nameFor()
    // re-evaluate (entries load asynchronously after the shell starts).
    property int revision: 0

    // Desktop entry ids hidden by OnlyShowIn / NotShowIn for $XDG_CURRENT_DESKTOP (Quickshell's
    // DesktopEntry exposes NoDisplay only). Built by launchpad/hidden-entries.sh at startup and
    // rebuilt (debounced) whenever DesktopEntries changes, so new entries are filtered without
    // a restart. `hiddenReady` is false until the first run has finished.
    property var hiddenIds: ({})
    property bool hiddenReady: false

    // Emitted when the listed apps may have changed: entries changed and the hidden list is
    // current again. Search and Apps rebuild their records on it.
    signal listChanged
    // A desktop entry was launched through launch() (not one of its actions): Recent Items (macOS Apple menu).
    signal launched(string appId)

    // Entry a launcher may show: not NoDisplay, not hidden by OnlyShowIn / NotShowIn.
    function isListed(entry: var): bool {
        return !entry.noDisplay && !Model.isHidden(root.hiddenIds, entry.id);
    }

    // Icon sources of the listed apps in alphabetical order, as the Apps panel and Search ask the icon theme for them: the shape
    // of those files is read ahead of time (Grassfield.Ui IconShapePrewarm, hosted by the menu bar) so that opening the panel does not.
    property var listedIconSources: []

    function refreshIconSources(): void {
        const list = [];
        for (const e of DesktopEntries.applications.values) {
            if (root.isListed(e))
                list.push({name: root.displayName(e).toLowerCase(), src: ThemeIcons.appIcon(e.icon, "application-x-executable")});
        }
        list.sort((a, b) => a.name.localeCompare(b.name));
        root.listedIconSources = list.map(x => x.src);
    }

    onListChanged: root.refreshIconSources()

    // A user icon copied (ThemeIcons): the prewarmed sources follow what the Apps panel now shows.
    readonly property Connections iconChecks: Connections {
        target: ThemeIcons

        function onCopiesChanged(): void {
            root.refreshIconSources();
        }
    }

    function refreshHidden(): void {
        if (scan.running)
            scan.again = true;
        else
            scan.running = true;
    }

    // Each entry's Name, GenericName, Comment and Keywords in the shell's language (Translator.language), for every surface
    // that shows an app's name: the menu bar, Apps, the Dock, Search, the switcher, Overview, the menus. Quickshell picks a
    // desktop entry's localized values from LC_MESSAGES or LANG alone, once (desktopentry.cpp Locale::system), while the
    // shell's language can come from LANGUAGE, LC_ALL or GRASSFIELD_LANG (ui/i18n systemLanguage): a French session showed
    // "Files" and "Grassfield Settings". The values come from launchpad/entry-names.sh, as the Desktop Entry Specification
    // picks them (Quickshell's properties cannot be written from QML). id -> {name, genericName, comment, keywords}, no
    // prototype; an entry that localizes nothing is not in it, and Quickshell's values are its own.
    property var localized: Object.create(null)

    // An entry's name in the shell's language ("" without an entry); the same for its generic name, comment and keywords.
    function displayName(entry: var): string {
        if (!entry)
            return "";
        const v = root.localized[entry.id];
        return v ? v.name : String(entry.name);
    }

    function displayGenericName(entry: var): string {
        if (!entry)
            return "";
        const v = root.localized[entry.id];
        return v ? v.genericName : String(entry.genericName);
    }

    function displayComment(entry: var): string {
        if (!entry)
            return "";
        const v = root.localized[entry.id];
        return v ? v.comment : String(entry.comment);
    }

    function displayKeywords(entry: var): var {
        if (!entry)
            return [];
        const v = root.localized[entry.id];
        return v ? v.keywords : Array.from(entry.keywords);
    }

    function refreshNames(): void {
        if (names.running)
            names.again = true;
        else
            names.running = true;
    }

    Connections {
        target: DesktopEntries

        function onApplicationsChanged(): void {
            root.revision++;
            debounce.restart();
        }
    }

    Connections {
        target: Translator

        function onLanguageChanged(): void {
            root.refreshNames();
        }
    }

    Timer {
        id: debounce
        interval: 250
        onTriggered: {
            root.refreshHidden();
            root.refreshNames();
        }
    }

    // In-place edits of an existing .desktop file (not reported by DesktopEntries.applicationsChanged):
    // watched with inotifywait when it is installed, one line per change. Without it the list is
    // refreshed only when an entry is added or removed (documented limitation, docs/specs/apps.md).
    Process {
        id: watch
        running: true
        command: ["sh", Quickshell.shellPath("launchpad/watch-applications.sh")]
        stdout: SplitParser {
            onRead: debounce.restart()
        }
    }

    Process {
        id: scan
        // Set when entries changed while the script was running: run it once more.
        property bool again: false
        command: ["sh", Quickshell.shellPath("launchpad/hidden-entries.sh")]
        stdout: StdioCollector {
            onStreamFinished: {
                root.hiddenIds = Model.parseHidden(text);
                root.hiddenReady = true;
                root.listChanged();
            }
        }
        onRunningChanged: {
            if (!running && again) {
                again = false;
                running = true;
            }
        }
    }

    Process {
        id: names
        // Set when entries or the language changed while the script was running: run it once more.
        property bool again: false
        command: ["sh", Quickshell.shellPath("launchpad/entry-names.sh"), Translator.language]
        stdout: StdioCollector {
            onStreamFinished: {
                const next = Model.parseLocalized(text);
                if (JSON.stringify(next) === JSON.stringify(root.localized))
                    return;
                root.localized = next;
                root.revision++;
                if (root.hiddenReady)
                    root.listChanged();
            }
        }
        onRunningChanged: {
            if (!running && again) {
                again = false;
                running = true;
            }
        }
    }

    Component.onCompleted: {
        scan.running = true;
        names.running = true;
    }

    function lookup(id: string): var {
        void revision;
        if (!id)
            return null;
        const byId = DesktopEntries.byId(id);
        return byId ? byId : DesktopEntries.heuristicLookup(id);
    }

    // ---- launching ------------------------------------------------------------------------------

    // A GRASSFIELD_DEV session (nested, on the owner's machine) must never start an app with the
    // owner's profiles: apps launched by the shell get their own XDG config, cache, state and data homes
    // (docs/specs/dock.md, dev notes). Production launches keep the user's environment (and get a scope of their own,
    // scopedLaunch).
    readonly property bool devSession: Mode.dev
    readonly property string appsHome: AppLaunch.appsHomeFor(Mode.stateHome, Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")
    // Root of Search's file results and recent documents: GRASSFIELD_SEARCH_ROOT, else the dev apps-home's files folder in a dev session, else $HOME.
    readonly property string searchRoot: AppLaunch.searchRoot(devSession, Mode.devValue("SEARCH_ROOT"), appsHome, Quickshell.env("HOME"))
    // XDG data home the shell reads recent documents from: the dev apps-home in a dev session, never the owner's.
    readonly property string dataHome: AppLaunch.dataHome(devSession, appsHome, Quickshell.env("XDG_DATA_HOME"), Quickshell.env("HOME"))

    // A real Grassfield session (uwsm, GRASSFIELD_SESSION=1, not a dev session) with uwsm's app launcher: every
    // application the shell starts gets a scope of its own (AppLaunch.scopedArgv), never the shell's unit.
    readonly property bool realSession: Mode.session && !devSession
    // GTK_USE_PORTAL=1 for the apps the shell starts when the session routes GTK to the portal (launchEnvironment).
    readonly property var portalEnvironment: AppLaunch.portalEnvironment(Mode.appsGtkPortal)
    // QT_QPA_PLATFORMTHEME of the session for the apps the shell starts (ADR-0054; the shell's unit pins gtk3 for itself).
    readonly property var themeEnvironment: AppLaunch.themeEnvironment(Mode.appsQtTheme)
    property bool uwsmApp: false
    readonly property bool scopedLaunch: realSession && uwsmApp

    // The detection of uwsm-app is asynchronous (a Process), so an application started in the first moments of the shell
    // would escape its scope. Every application start therefore goes through whenScopeKnown(): it runs at once when the
    // answer is known (always in a dev session) and is queued until the answer arrives otherwise.
    property bool scopeKnown: !realSession
    property var scopeWaiting: []

    function whenScopeKnown(fn: var): void {
        if (scopeKnown)
            fn();
        else
            scopeWaiting = scopeWaiting.concat([fn]);
    }

    function settleScope(): void {
        if (scopeKnown)
            return;
        scopeKnown = true;
        const waiting = scopeWaiting;
        scopeWaiting = [];
        for (const fn of waiting)
            fn();
    }

    Process {
        id: uwsmProbe
        // Set by started: a run that ends without it never started (see onRunningChanged).
        property bool didStart: false
        running: root.realSession
        command: ["sh", "-c", "command -v uwsm-app"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.uwsmApp = text.trim() !== "";
                root.settleScope();
            }
        }
        onStarted: didStart = true
        // sh could not even start: launches must not wait for ever (they start unscoped). Quickshell sends no
        // `exited` when a start fails, only running going back to false without a `started`.
        onRunningChanged: {
            if (!running && !didStart) {
                console.warn("Apps: could not start sh to detect uwsm-app; applications start without a scope");
                root.settleScope();
            }
        }
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: root.settleScope()
        // qmllint enable signal-handler-parameters
    }

    // argv of an application start: in its own scope in a real session (AppLaunch.scopedArgv).
    function scoped(argv: var): var {
        return AppLaunch.scopedArgv(argv, scopedLaunch);
    }

    // Starts a desktop entry or one of its actions. The one launch path of the Dock, Apps, Search and the
    // menus.
    function launch(target: var): void {
        if (!target)
            return;
        // A desktop entry has a list of actions; an action has none.
        if (target.actions !== undefined && typeof target.id === "string")
            root.launched(target.id);
        whenScopeKnown(() => root.launchNow(target));
    }

    function launchNow(target: var): void {
        const environment = launchEnvironment();
        // Nothing to add to the environment of the shell and no scope to start: Quickshell's own execute().
        if (Object.keys(environment).length === 0 && !scopedLaunch) {
            target.execute();
            return;
        }
        let command = AppLaunch.stripFieldCodes(target.command);
        if (command.length === 0)
            return;
        // Entries that run in a terminal: the default terminal wrapper, as Quickshell's execute() does.
        if (target.runInTerminal === true)
            command = ["xdg-terminal-exec"].concat(command);
        const context = {
            "command": scoped(command),
            "environment": environment
        };
        if (target.workingDirectory)
            context.workingDirectory = target.workingDirectory;
        Quickshell.execDetached(context);
    }

    // MimeType keys of the desktop entries and the shared MIME database (dock/mime-data.sh), rebuilt with the entry list.
    // Until it has loaded nothing accepts a drop.
    property var mimeData: DockModel.parseMimeData("")

    Process {
        id: mimeScan
        property bool again: false
        command: ["sh", Quickshell.shellPath("dock/mime-data.sh")]
        stdout: StdioCollector {
            onStreamFinished: root.mimeData = DockModel.parseMimeData(text)
        }
        onRunningChanged: {
            if (!running && again) {
                again = false;
                running = true;
            }
        }
    }

    Connections {
        target: root

        function onListChanged(): void {
            if (mimeScan.running)
                mimeScan.again = true;
            else
                mimeScan.running = true;
        }
    }

    // Real types ({path: type}) of the paths hovered by a drag, looked up off the UI path with dock/file-types.sh (a folder
    // may carry an extension, so every path is looked at) and cached for the drag: cleared a moment after the last tile is left.
    property var hoverTypes: ({})
    property var hoverWanted: []

    Process {
        id: hoverScan
        property var paths: []
        stdout: StdioCollector {
            onStreamFinished: {
                const found = DockModel.parseResolved(hoverScan.paths, text);
                root.hoverTypes = Object.assign({}, root.hoverTypes, found);
            }
        }
        onRunningChanged: {
            if (!running)
                root.scanHover();
        }
    }

    function scanHover(): void {
        if (hoverScan.running)
            return;
        const todo = DockModel.unknownPaths(hoverWanted, hoverTypes).slice(0, 32);
        hoverWanted = [];
        if (todo.length === 0)
            return;
        hoverScan.paths = todo;
        hoverScan.command = ["timeout", "10", "sh", Quickshell.shellPath("dock/file-types.sh")].concat(todo);
        hoverScan.running = true;
    }

    Timer {
        id: hoverClear
        interval: 1500
        onTriggered: root.hoverTypes = ({})
    }

    // A drag entered a tile: start resolving the real types of its paths (nothing runs for a tile that opens nothing).
    function hoverEnter(entry: var, paths: var): void {
        hoverClear.stop();
        if (DockModel.dropVerdict(entry, paths, mimeData, null) === "no")
            return;
        hoverWanted = hoverWanted.concat(DockModel.unknownPaths(paths, hoverTypes));
        scanHover();
    }

    // A drag of folders entered the Dock's shelf: look up the real types of its paths (Stacks.folderVerdict reads hoverTypes).
    function hoverFolders(paths: var): void {
        hoverClear.stop();
        hoverWanted = hoverWanted.concat(DockModel.unknownPaths(paths, hoverTypes));
        scanHover();
    }

    // The real types of dropped `paths` ({path: type}), looked up once (dock/file-types.sh), handed to `done`. A busy lookup
    // is not queued: `done` gets an empty map then (nothing is added).
    function dirsOf(paths: var, done: var): void {
        const list = Array.from(paths || []).slice(0, 32);
        if (list.length === 0 || dirScan.running) {
            done({});
            return;
        }
        dirScan.paths = list;
        dirScan.done = done;
        dirScan.command = ["timeout", "10", "sh", Quickshell.shellPath("dock/file-types.sh")].concat(list);
        dirScan.running = true;
    }

    Process {
        id: dirScan
        property var paths: []
        property var done: null
        stdout: StdioCollector {
            onStreamFinished: {
                const callback = dirScan.done;
                dirScan.done = null;
                if (callback)
                    callback(DockModel.parseResolved(dirScan.paths, text));
            }
        }
    }

    // A drag left a tile or was dropped: forget the cached types shortly after (a drag over the next tile reuses them).
    function hoverLeave(): void {
        hoverClear.restart();
    }

    // "yes" / "no" / "pending" for the tile of `entry` and the hovered `paths` (reads hoverTypes: bindings update when
    // the lookup finishes).
    function hoverVerdict(entry: var, paths: var): string {
        return DockModel.dropVerdict(entry, paths, mimeData, hoverTypes);
    }

    // Drop jobs waiting for the real types of the paths ({entry, paths}), only when the drop came before the lookup finished.
    property var typeJobs: []
    property var typeJob: null

    Process {
        id: typeScan
        stdout: StdioCollector {
            onStreamFinished: {
                const job = root.typeJob;
                root.typeJob = null;
                if (job)
                    root.openWith(job.entry, job.paths, DockModel.parseResolved(job.paths, text));
                root.nextTypeJob();
            }
        }
    }

    function nextTypeJob(): void {
        if (typeScan.running || typeJobs.length === 0)
            return;
        typeJob = typeJobs[0];
        typeJobs = typeJobs.slice(1);
        typeScan.command = ["timeout", "10", "sh", Quickshell.shellPath("dock/file-types.sh")].concat(typeJob.paths);
        typeScan.running = true;
    }

    // Files dropped on an app tile. The real types looked up while hovering decide at once: "yes" opens, "no" refuses (the
    // drag source gets a cancel). Only a drop that came before the lookup finished (or from a source that hands its data over
    // at the drop) is accepted and resolved afterwards. True when the drop is accepted.
    function dropOnApp(entry: var, paths: var): bool {
        if (!entry || !paths || paths.length === 0)
            return false;
        const verdict = DockModel.dropVerdict(entry, paths, mimeData, hoverTypes);
        hoverLeave();
        if (verdict === "yes")
            return openWith(entry, paths, hoverTypes);
        if (verdict === "no" || typeJobs.length >= 4)
            return false;
        typeJobs = typeJobs.concat([{entry: entry, paths: Array.from(paths)}]);
        nextTypeJob();
        return true;
    }

    // Opens files with a desktop entry (files dropped on a Dock tile): the entry command with its file field codes
    // filled in per the Desktop Entry spec (DockModel.commandsForFiles; a command without one never gets the files
    // appended), the launch environment (isolated in a dev session, pointer size). Refused unless the app can open every
    // file.
    function openWith(entry: var, files: var, resolved: var): bool {
        if (!entry || !DockModel.acceptsFiles(entry, files, mimeData, resolved))
            return false;
        return runCommands(entry, DockModel.commandsForFiles(DockModel.entryArgs(entry), files));
    }

    // Opens one document (the Dock menu's recent documents) with the app that used it: the same command building as a drop,
    // without the MIME check (the app registered the document itself). Refused for a relative path or an app whose Exec has
    // no file field code.
    function openDocument(entry: var, path: string): bool {
        if (!entry || typeof path !== "string" || !path.startsWith("/"))
            return false;
        return runCommands(entry, DockModel.commandsForFiles(DockModel.entryArgs(entry), [path]));
    }

    function runCommands(entry: var, commands: var): bool {
        const environment = launchEnvironment();
        whenScopeKnown(() => {
            for (const c of commands) {
                if (c.length === 0)
                    continue;
                const context = {"command": root.scoped(entry.runInTerminal === true ? ["xdg-terminal-exec"].concat(c) : c)};
                if (Object.keys(environment).length > 0)
                    context.environment = environment;
                if (entry.workingDirectory)
                    context.workingDirectory = entry.workingDirectory;
                Quickshell.execDetached(context);
            }
        });
        return commands.length > 0;
    }

    // Work started by a popup menu that closes at once (the popup, and any Process it owns, is destroyed when it closes):
    // owned by this singleton, or detached, so that it survives the menu (Dock menu: Open at Login, Show in Files).
    function writeAutostart(path: string, text: string): void {        Quickshell.execDetached(["sh", Quickshell.shellPath("overlay/write-autostart.sh"), path, text]);
    }

    function removeAutostart(path: string): void {
        Quickshell.execDetached(["rm", "-f", "--", path]);
    }

    // Opens the folder of an executable (`command -v`, `readlink -f`) in Files (through the dev open policy in a dev session).
    function revealExecutable(program: string): void {
        if (program === "" || reveal.running)
            return;
        reveal.program = program;
        reveal.running = true;
    }

    Process {
        id: reveal
        property string program: ""
        command: ["sh", "-c", 'p=$(command -v -- "$1") && dirname -- "$(readlink -f -- "$p")"', "sh", program]
        stdout: StdioCollector {
            onStreamFinished: {
                const dir = text.trim();
                if (dir !== "")
                    root.openDetached(["gio", "open", dir]);
            }
        }
    }

    // Dev open policy (ADR-0011, scripts/dev/open-policy.sh): folders open in Grassfield Files, files Preview can show
    // in Grassfield Preview, both started directly with the isolated environment; everything else is refused. Set by
    // scripts/dev/shell-run.sh. Without it a dev session opens nothing.
    readonly property string openPolicy: Mode.devValue("OPEN_POLICY")

    // A real Grassfield session opens every folder in Grassfield Files, whatever the user's default handler is (macOS: the
    // Finder is the file manager of the system). `gio open` and `xdg-open` argv become services/open-real.sh calls there;
    // a dev session keeps the open policy and gets the argv back unchanged.
    function folderAware(argv: var): var {
        return AppLaunch.folderAwareArgv(argv, Quickshell.shellPath("services/open-real.sh"), realSession);
    }

    // Runs a helper command. Helpers that open a file in an application (gio open, xdg-open, gtk-launch) follow the
    // dev open policy in a dev session: GIO never starts an app there (a D-Bus activatable default handler such as
    // Nautilus would run in the owner's session with the owner's profile). Other helpers (gio trash) get the isolated
    // environment. A real session runs the command unchanged, in a scope of its own (the application it opens lives there).
    function openDetached(argv: var): void {
        if (!devSession) {
            const environment = launchEnvironment();
            const open = folderAware(argv);
            whenScopeKnown(() => {
                if (Object.keys(environment).length === 0)
                    Quickshell.execDetached(root.scoped(open));
                else
                    Quickshell.execDetached({
                        "command": root.scoped(open),
                        "environment": environment
                    });
            });
            return;
        }
        devOpen(argv);
    }

    // A short helper that is not an application (gio trash): never in a scope of its own, only an application is. Same
    // isolated environment and dev policy as openDetached.
    function runHelper(argv: var): void {
        if (devSession) {
            devOpen(argv);
            return;
        }
        const environment = launchEnvironment();
        if (Object.keys(environment).length === 0)
            Quickshell.execDetached(argv);
        else
            Quickshell.execDetached({
                "command": argv,
                "environment": environment
            });
    }

    function devOpen(argv: var): void {
        const request = AppLaunch.openRequest(argv);
        if (request === null) {
            Quickshell.execDetached({
                "command": argv,
                "environment": launchEnvironment()
            });
            return;
        }
        if (request.refuse !== undefined || openPolicy === "") {
            console.warn("open refused in dev: " + (request.refuse !== undefined ? request.refuse : "no open policy helper"));
            return;
        }
        Quickshell.execDetached({
            "command": [openPolicy].concat(request.targets),
            "environment": launchEnvironment()
        });
    }

    // Environment of a Process that runs a helper opening files (gio open, gio trash): the isolated homes in a dev
    // session. Such a Process still resolves `gio` on the shell's own PATH, where scripts/dev/shell-run.sh puts the
    // open shims first (a dev `gio open` follows the open policy even in code that does not call openDetached).
    function openEnvironment(): var {
        return launchEnvironment();
    }

    // Environment added to every application the shell starts: the isolated homes in a dev session, GTK_USE_PORTAL=1 when
    // the session routes GTK to the portal (the shell's own unit clears it; ADR-0035 D-8), and the pointer size the user
    // chose when it differs from the session's (XCURSOR_SIZE and HYPRCURSOR_SIZE; applications read them when they start,
    // so open ones keep their size). Never the owner's systemd or uwsm environment.
    function launchEnvironment(): var {
        const session = AppLaunch.mergeEnvironment(portalEnvironment, themeEnvironment);
        const base = AppLaunch.mergeEnvironment(devSession ? AppLaunch.isolatedEnvironment(appsHome) : ({}), session);
        return AppLaunch.mergeEnvironment(base, Pointer.launchEnvironment());
    }

    // Environment of Grassfield's own apps (Settings, Glance): launchEnvironment() without the dev isolation, which they
    // apply themselves.
    function ownAppEnvironment(): var {
        return AppLaunch.mergeEnvironment(AppLaunch.mergeEnvironment(portalEnvironment, themeEnvironment), Pointer.launchEnvironment());
    }

    // Open With (desktop menu): the shown apps that can open every one of `paths` (`resolved`: path -> real type, from
    // dock/file-types.sh), by name, with `first` (the default handler's entry id) leading. One row per app name.
    function appsFor(paths: var, resolved: var, first: string): var {
        const out = [];
        const seen = {};
        for (const id of Object.keys(mimeData.entries)) {
            const entry = lookup(id);
            const name = root.displayName(entry);
            if (!entry || entry.noDisplay || seen[name] || !DockModel.acceptsFiles(entry, paths, mimeData, resolved))
                continue;
            seen[name] = true;
            out.push({
                id: id,
                name: name
            });
        }
        return out.sort((a, b) => (b.id === first) - (a.id === first) || a.name.localeCompare(b.name));
    }

    function nameFor(appId: string): string {
        const entry = lookup(appId);
        return entry ? root.displayName(entry) : appId;
    }
}
