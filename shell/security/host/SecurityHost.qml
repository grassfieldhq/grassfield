pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.I18n
import Grassfield.Ui
import qs.services
import qs.security.idle
import qs.security.lock

// What the security process hosts (ADR-0041 step 1, S2; ADR-0010 "Separate security process", the owner's SQ-1 B):
// everything that locks, together: the lock (Lock, with its crash-recovery marker, the stranded-lock takeover and the
// publisher of the state the UI reads), idle (dim, lock, display off, the automatic sleep) and the sleep inhibitor with its
// PrepareForSleep watcher (inside Idle). Instantiated by shell/security.qml only; the UI (shell/shell.qml) never
// instantiates this file, Lock or Idle, and reaches them over IPC on the security instance (`lock lock`, `lock lid`,
// `idle inhibit`). S3 adds the polkit agent here, S4 safe mode.
// What this process takes from the UI's world is read-only: grassfield.json through Settings (no setter is ever called
// here, so it writes nothing), the language and the region formats, wallpaper.json (LockWallpaper). It opens no request
// socket and owns no bus name.
Scope {
    id: root

    // What the process hosts, for `security state` (S1 answered "starting").
    readonly property string hosted: "lock idle"

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

    // The state and the beat for `security heartbeat` (shell/security.qml): "<public state> <sequence>".
    function heartbeat(): string {
        return Lock.publicState + " " + Lock.beat;
    }

    // Referencing Lock instantiates the session lock (its IPC target `lock`, the crash-recovery restore, the stranded-lock
    // check, the publisher). The start-time measurement reads this line in the journal (the unit's "Started" line is the start).
    Component.onCompleted: console.info("grassfield-security: ready (hosting " + root.hosted + ", lock " + Lock.publicState + ", language " + root.language + ")")
}
