pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Shortcuts.js" as Logic

// The shell's keys and trackpad gestures, in-process (CIO-01; ADR "keys reach the shell in-process"). bindings.lua sends each
// shell request as Hyprland's `event` dispatcher: socket2 carries `custom>>gfkey/1 <target> <function> [argument...]`, read
// here from the connection the shell already has (Quickshell.Hyprland), and the request goes to the IpcHandler of that
// target, as `qs ipc call` would reach it: no process is started per key, and the order of the keys is kept (a held
// volume key no longer starts 40 processes a second that can arrive in any order).
//
// Every IpcHandler a binding calls attaches itself (`Component.onCompleted: Shortcuts.attach(this)`); the requests are the
// ones Shortcuts.js lists, with their arguments checked. A target whose handler has not attached (a file that does not do it
// yet) is still served, by `qs ipc` as before, once logged. The lock key alone stays a `qs ipc` call to the security process
// with its stand-in (bindings.lua): it must lock with the UI process dead.
//
// The Overview and Apps gestures follow the fingers: `custom>>gfgesture/1 <kind> <phase> <progress>`, kind overview-open,
// overview-close, apps-open or apps-close, phase begin, update, end (with "commit" or "back") or cancel. A surface that
// follows the progress sets `tracking` for its kinds and listens to `gesture`; when none does, a committed end performs
// the discrete request (open or close), as the gesture did before.
Singleton {
    id: root

    // target -> [IpcHandler]: the handlers that attached, in order.
    property var handlers: ({})
    // kind -> true: a surface follows that gesture's progress itself (its `gesture` handler opens or closes on "end").
    property var tracking: ({})
    // Targets already reported as served through `qs ipc` (logged once each).
    property var reported: ({})

    // One step of a finger-tracked gesture; progress 0..1, `commit` on "end" when the gesture completes.
    signal gesture(string kind, string phase, real progress, bool commit)

    // An IpcHandler that a key binding calls: its target is reachable by key from now on.
    function attach(handler: IpcHandler): void {
        if (!handler || typeof handler.target !== "string" || handler.target === "")
            return;
        const next = Object.assign({}, root.handlers);
        next[handler.target] = Logic.attached(next[handler.target], handler);
        root.handlers = next;
    }

    // A surface follows (or stops following) the progress of gesture `kind` itself.
    function follow(kind: string, on: bool): void {
        const next = Object.assign({}, root.tracking);
        if (on)
            next[kind] = true;
        else
            delete next[kind];
        root.tracking = next;
    }

    // Performs a key request ({target, fn, args}); false when it was not a known request.
    function deliver(request: var): bool {
        if (!request)
            return false;
        const handler = Logic.pick(root.handlers[request.target]);
        if (handler && typeof handler[request.fn] === "function") {
            handler[request.fn](...request.args);
            return true;
        }
        // Not attached (yet): the request still reaches the shell, by the process it took before.
        if (!root.reported[request.target]) {
            root.reported = Object.assign({}, root.reported, {[request.target]: true});
            console.warn("grassfield-shell: key target", request.target, "has no attached handler: served through qs ipc");
        }
        Quickshell.execDetached(["env", "-u", "QS_CONFIG_PATH", "-u", "QS_CONFIG_NAME", "-u", "QS_MANIFEST", "qs", "ipc", "-p", Quickshell.shellDir, "call", request.target, request.fn].concat(request.args.map(a => String(a))));
        return true;
    }

    function receive(data: string): void {
        const key = Logic.parseKey(data);
        if (key) {
            root.deliver(key);
            return;
        }
        const step = Logic.parseGesture(data);
        if (!step)
            return;
        root.gesture(step.kind, step.phase, step.progress, step.commit);
        if (!root.tracking[step.kind]) {
            const discrete = Logic.gestureFallback(step);
            if (discrete)
                root.deliver({target: discrete.target, fn: discrete.fn, args: []});
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "custom")
                root.receive(event.data);
        }
    }
}
