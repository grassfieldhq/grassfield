// grassfield-security root (ADR-0041 step 1, S2; ADR-0010 "Separate security process", the owner's SQ-1 B of 2026-10-29).
// A second Quickshell process of the Grassfield session, `qs -n -p /usr/share/grassfield/shell/security.qml`
// (grassfield-security.service), beside the UI (`qs -n -p /usr/share/grassfield/shell`, grassfield-shell.service). The
// file is a root of its own next to shell.qml, so `qs.*` resolves from the same directory as the UI's root and the
// security modules keep their place. Since S2 it hosts everything that locks (security/host/SecurityHost.qml: the lock, idle
// and the sleep inhibitor, with the publisher of the state the UI reads); S3 adds the polkit agent, S4 safe mode. The UI
// keeps no lock: every lock request reaches this process over IPC (`lock lock`, `lock lid` on this instance).
// GF-115: loaded by path from the system tree only (the unit); R12: never reloaded on a file change.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.security.host

ShellRoot {
    id: root

    // A reload is a security event (shell/security/lock/Lock.qml): never on a file change. Re-applied by every reload
    // (Quickshell resets it to true), as the UI's root does.
    settings.watchFiles: false

    // The lock, idle and the sleep inhibitor (and nothing else).
    SecurityHost {
        id: host
    }

    IpcHandler {
        target: "security"

        // What the process hosts ("lock idle" since S2). Never private state.
        function state(): string {
            return host.hosted;
        }

        // The lock's public state and the publisher's sequence number ("locked 42"): a sequence that stops moving is the
        // stopped or hung process the UI reads as locked. Never private state.
        function heartbeat(): string {
            return host.heartbeat();
        }
    }
}
