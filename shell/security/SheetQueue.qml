import QtQuick
import "SheetQueue.js" as Logic

// The one queue of every secret sheet and the polkit sheet (ADR-0035 D-9, master-prompt R12; docs/specs/system-dialogs.md
// SC2): one sheet on screen at a time, in arrival order; a request that arrives while another sheet is on screen never
// takes the keyboard from it and waits until that sheet is gone (SheetQueue.js). The security process's host
// (host/SecurityHost.qml, ADR-0041 S3) makes one and gives it to the
// polkit agent (AuthAgent.queue: its requests are handed to its sheet only when `polkitWaits` is false) and to the secret
// agent (SecretAgent.queue: it shows `secretHead` only). Non-visual and free of Quickshell imports
// (tests/security/tst_sheetqueue.qml).
QtObject {
    id: root

    // The polkit sheet is present: from a polkit request's arrival until its sheet is gone, the key sink's linger included
    // (AuthAgent.queuePresent; the host binds it).
    property bool polkitPresent: false
    // A polkit request must wait: a secret sheet came first (one arriving now comes after every secret request queued).
    readonly property bool polkitWaits: priv.revision >= 0 && Logic.polkitWaits(priv.state)
    // The secret request that may be on screen ("" for none: no secret request, or the polkit sheet came first).
    readonly property string secretHead: priv.revision >= 0 ? Logic.secretHead(priv.state) : ""
    // Secret requests in the queue (shown, waiting, or a sheet's linger).
    readonly property int secretCount: priv.revision >= 0 ? Logic.count(priv.state) : 0

    // A sheet left the queue ("polkit" or "secret"). Emitted before the queue changes, so the other agent notes the end (a
    // request handed to it right after is held, "right after another one") before the next sheet can be shown.
    signal sheetEnded(string kind)

    component Private: QtObject {
        property var state: Logic.create()
        property int revision: 0
    }

    readonly property Private priv: Private {}

    // A secret request takes the last place; false when the id is empty or already queued.
    function addSecret(id: string): bool {
        if (!Logic.addSecret(priv.state, id))
            return false;
        priv.revision++;
        return true;
    }

    // A secret request's sheet is gone (or it never showed): its place is freed.
    function removeSecret(id: string): void {
        if (!Logic.has(priv.state, id))
            return;
        root.sheetEnded("secret");
        Logic.removeSecret(priv.state, id);
        priv.revision++;
    }

    function hasSecret(id: string): bool {
        return priv.revision >= 0 && Logic.has(priv.state, id);
    }

    onPolkitPresentChanged: {
        if (!polkitPresent)
            root.sheetEnded("polkit");
        Logic.setPolkit(priv.state, polkitPresent);
        priv.revision++;
    }
}
