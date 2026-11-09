pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.I18n
import Grassfield.Ui
import qs.services
import qs.security
import qs.security.idle
import qs.security.lock

// What the security process hosts (ADR-0041 step 1, S2 and S3; ADR-0010 "Separate security process", the owner's SQ-1 B):
// everything that locks, together: the lock (Lock, with its crash-recovery marker, the stranded-lock takeover and the
// publisher of the state the UI reads), idle (dim, lock, display off, the automatic sleep) and the sleep inhibitor with its
// PrepareForSleep watcher (inside Idle); since S3 the session's one polkit agent and the secret sheets fed by
// grassfield-prompter (ADR-0035 D-9), with the one queue they share (SheetHost.qml, created at run time below).
// Instantiated by shell/security.qml only; the UI (shell/shell.qml) never instantiates this file, Lock, Idle or the sheets,
// and reaches the lock over IPC on the security instance (`lock lock`, `lock lid`, `idle inhibit`). S4 adds safe mode.
// The sheets read the session from this process alone (SheetSession, bound below from Lock and Idle): nothing the UI
// writes or answers reaches their rules. What the UI knows of them goes out with the lock state (Lock.authorizing,
// Lock.securityKeyboard: booleans).
// What this process takes from the UI's world is read-only: grassfield.json through Settings (no setter is ever called
// here, so it writes nothing), the language and the region formats, wallpaper.json (LockWallpaper), the package's VERSION.
// It opens no request socket and owns no bus name; the polkit agent registers its object with polkitd on the system bus,
// and the secret sheets connect to grassfield-prompter's socket (which accepts this unit's processes only).
Scope {
    id: root

    // What the process hosts, for `security state` (S1 answered "starting", S2 "lock idle"; S3 adds "polkit secrets" once
    // the sheets are made).
    readonly property string hosted: "lock idle" + (root.sheets !== null ? " polkit secrets" : "")

    // Instantiates the Translator first: it installs the catalog (GRASSFIELD_LANG or the system locale) before the lock
    // surfaces evaluate their qsTr() strings (the UI's root does the same).
    readonly property string language: Translator.language

    // The region's formats (the lock's date and time), and the appearance settings the lock surfaces follow (Reduce Motion
    // caps their fades; the text size and contrast settings; the accent of the field's selection). The lock always draws the
    // dark palette.
    Binding {
        target: Translator
        property: "formats"
        value: Settings.regionFormats
    }
    Binding {
        target: Appearance
        property: "reduceMotion"
        value: Settings.reduceMotion
    }
    Binding {
        target: Appearance
        property: "reduceTransparency"
        value: Settings.reduceTransparency
    }
    Binding {
        target: Appearance
        property: "increaseContrast"
        value: Settings.increaseContrast
    }
    Binding {
        target: Appearance
        property: "textScale"
        value: Settings.textSize
    }
    Binding {
        target: Appearance
        property: "accentSetting"
        value: Settings.accentColor
    }
    Binding {
        target: Appearance
        property: "highlightSetting"
        value: Settings.accentHighlight
    }

    // Idle, with the sleep inhibitor inside it. It sets Lock.displaysOff and Lock.fromDim and asks Lock to lock in process.
    Idle {
        id: idle
    }

    // ---- The polkit sheet and the secret sheets (ADR-0041 S3) ----
    // What they read of the session, from this process only (the opus review of 77a0ceb3, MINOR-4): the lock (any state but
    // unlocked, and the start-up probe of a stranded or foreign lock while it runs: the opus review of S3, LOW-4), the
    // displays switched off by idle, and the UI's screen saver as idle counts it (only ever early: MINOR-1 of that review).
    // These three Bindings are SheetSession's only writers (tests/security/security_process_scan.py).
    Binding {
        target: SheetSession
        property: "locked"
        value: Lock.locked || Lock.strandedProbing
    }
    Binding {
        target: SheetSession
        property: "displaysOff"
        value: idle.displayOff
    }
    Binding {
        target: SheetSession
        property: "saverShown"
        value: idle.saverShown
    }

    // The sheets themselves (SheetHost.qml: the one queue, the polkit agent, the secret agent), created at run time at the end
    // of Component.onCompleted, never a declared child (as the lock's LockStills): a sheet module that cannot be loaded or
    // created (a Quickshell without its polkit service, no window backend) leaves the lock, idle and the sleep inhibitor
    // running. Then no polkit agent is registered, so polkitd answers every authorization "not authorized", and
    // grassfield-prompter has no client: it releases its names and the password prompts fall back to the stock prompters, as
    // with no shell before (docs/specs/system-dialogs.md SC6). A failure denies an authorization, never approves one.
    property var sheets: null
    function prepareSheets(): void {
        try {
            const c = Qt.createComponent(Qt.resolvedUrl("SheetHost.qml"));
            if (c.status === Component.Loading) {
                c.statusChanged.connect(() => {
                    if (c.status !== Component.Loading)
                        root.finishSheets(c);
                });
                return;
            }
            root.finishSheets(c);
        } catch (e) {
            console.warn("grassfield-security: the polkit agent and the secret sheets failed (" + e + "); no polkit agent (authorizations are refused) and no secret sheet (password prompts fall back to the stock prompters); the lock is unaffected");
        }
    }
    function finishSheets(c: var): void {
        try {
            if (c.status !== Component.Ready) {
                console.warn("grassfield-security: the polkit agent and the secret sheets cannot be loaded (" + c.errorString() + "); no polkit agent (authorizations are refused) and no secret sheet (password prompts fall back to the stock prompters); the lock is unaffected");
                return;
            }
            const o = c.createObject(root);
            if (o === null) {
                console.warn("grassfield-security: the polkit agent and the secret sheets cannot be created; no polkit agent (authorizations are refused) and no secret sheet (password prompts fall back to the stock prompters); the lock is unaffected");
                return;
            }
            root.sheets = o;
        } catch (e) {
            console.warn("grassfield-security: the polkit agent and the secret sheets failed (" + e + "); no polkit agent (authorizations are refused) and no secret sheet (password prompts fall back to the stock prompters); the lock is unaffected");
        }
    }

    // What the UI knows of the sheets, published with the lock state: a sheet is open (shown or held), and a sheet or its key
    // sink may hold the keyboard (the capture toolbar then maps nothing as Exclusive). No sheets made: none open.
    Binding {
        target: Lock
        property: "authorizing"
        value: root.sheets !== null && root.sheets.authorizing === true
    }
    Binding {
        target: Lock
        property: "securityKeyboard"
        value: root.sheets !== null && root.sheets.securityKeyboard === true
    }

    // The state and the beat for `security heartbeat` (shell/security.qml): "<public state> <sequence>".
    function heartbeat(): string {
        return Lock.publicState + " " + Lock.beat;
    }

    // Referencing Lock instantiates the session lock (its IPC target `lock`, the crash-recovery restore, the stranded-lock
    // check, the publisher). The start-time measurement reads this line in the journal (the unit's "Started" line is the start).
    // The sheets are made first (a failure there is logged and changes nothing of the lock).
    Component.onCompleted: {
        root.prepareSheets();
        console.info("grassfield-security: ready (hosting " + root.hosted + ", lock " + Lock.publicState + ", language " + root.language + ")");
    }
}
