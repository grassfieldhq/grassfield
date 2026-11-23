pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.services
import "CaptureThumbs.js" as Thumbs

// The floating thumbnail (spec docs/specs/capture-suite.md § 3.2, ADR-0066 D-1 and D-9; slices A2 and A3): after a capture the
// helper's result file (CaptureState.resultArrived) becomes a glass card at the bottom corner of the display the capture came
// from, above the Dock's band, on the side capture.thumbnailSide names; up to three per display, the newest on top. A card closes
// after capture.thumbnailSeconds (hovering pauses it) and has Copy, Show in Files, Move to Trash and Close on hover; a click opens
// it, dragging it toward the screen edge dismisses it and dragging it anywhere else drags the file out (CaptureThumbnailCard).
//
// What hides the cards: the capture's `shooting` phase, a recording, a frozen choice, the lock and the full-attention surfaces
// (`held`). They are unmapped then (not made transparent), and CaptureState.thumbnailsHidden says so one settle time later:
// the helper's acknowledgement waits for it, so a card is never in a picture.
//
// The paths in a result are data: a card exists only for a path that CaptureThumbs.accept allows (a direct child of a Save to
// folder, a picture or movie by its name) and services/capture-thumb.sh then confirms (a regular file, not a link). Every
// action goes through the script or through the same check (CaptureThumbs.plan), never the folder the result file names.
Scope {
    id: root

    // A full-attention surface is open (shell.qml binds the exclusive surfaces): the cards step aside.
    property bool held: false

    readonly property string side: Thumbs.sideOf(Settings.captureThumbnailSide)
    readonly property int seconds: Thumbs.secondsOf(Settings.captureThumbnailSeconds)
    readonly property bool hidden: Thumbs.hiddenNow(CaptureState.phase, SessionState.locked, root.held)
    // The stack, newest first; the folders a capture may be in; the results waiting for them.
    property var cards: []
    property var dirs: null
    property var pending: []
    // Whether the cards are (or are about to be) mapped. Conservative: a card whose file is not confirmed yet counts, so that
    // the acknowledgement is late rather than early.
    readonly property bool mapped: root.cards.length > 0 && !root.hidden
    readonly property string script: Quickshell.shellPath("services/capture-thumb.sh")
    readonly property var metrics: ({
            width: Tokens.captureThumbnailWidth,
            pictureHeight: Tokens.captureThumbnailPictureHeight,
            inset: Tokens.captureThumbnailInset,
            minPictureWidth: 2 * Tokens.captureThumbnailButtonSize,
            gap: Tokens.captureThumbnailGap
        })
    // Each card's size and the room under it, by id.
    readonly property var entries: {
        const out = {};
        for (const s of Quickshell.screens)
            for (const e of Thumbs.layout(root.cards, s.name, root.metrics))
                out[e.id] = e;
        return out;
    }

    function cardById(id: string): var {
        return root.cards.find(c => c.id === id) ?? null;
    }

    function dismiss(id: string): void {
        root.cards = Thumbs.remove(root.cards, id);
    }

    // The helper's result: the Save to folders are asked again (they can change), then the card is made.
    function ingest(result: var): void {
        if (!Settings.captureShowThumbnail)
            return;
        root.pending = root.pending.concat([result]);
        if (!resolver.running)
            resolver.running = true;
    }

    function takePending(): void {
        const screens = Quickshell.screens.map(s => ({
                    name: s.name,
                    x: s.x,
                    y: s.y,
                    width: s.width,
                    height: s.height
                }));
        const results = root.pending;
        root.pending = [];
        for (const result of results) {
            const card = Thumbs.accept(result, root.dirs, screens);
            if (card === null) {
                console.warn("grassfield: capture result refused (a path outside the Save to folders, or no display)");
                continue;
            }
            root.cards = Thumbs.push(root.cards, card, Tokens.captureThumbnailMax);
        }
    }

    // Runs an action of a card. Copy and Move to Trash go through the script, which checks the file itself. Open and Show in
    // Files check first, then open with the application's own helper (the dev open policy in a dev session).
    function act(action: string, id: string): void {
        const card = root.cardById(id);
        const plan = card === null ? null : Thumbs.plan(action, card, root.dirs, root.script);
        if (plan === null) {
            // Refused (the path no longer passes, or a recording copy): the card goes, nothing runs.
            root.dismiss(id);
            return;
        }
        const environment = action === "trash" ? Apps.openEnvironment() : ({});
        if (plan.check === null) {
            root.job(plan.run, environment, ok => {
                if (!ok)
                    console.warn("grassfield: capture thumbnail " + action + " failed");
                if (ok && action === "trash")
                    root.dismiss(id);
            });
            return;
        }
        root.job(plan.check, ({}), ok => {
            if (!ok) {
                root.dismiss(id);
                return;
            }
            Apps.openDetached(plan.run);
            root.dismiss(id);
        });
    }

    // The check of a card's file alone: `done(ok)`.
    function verify(id: string, done: var): void {
        const card = root.cardById(id);
        const plan = card === null ? null : Thumbs.plan("verify", card, root.dirs, root.script);
        if (plan === null) {
            done(false);
            return;
        }
        root.job(plan.run, ({}), done);
    }

    function job(argv: var, environment: var, done: var): void {
        // qmllint disable missing-property
        const proc = runner.createObject(root, {
            command: argv,
            environment: environment,
            done: done
        });
        proc.running = true;
        // qmllint enable missing-property
    }

    Connections {
        target: CaptureState

        function onResultArrived(result: var): void {
            root.ingest(result);
        }
    }

    // The cards are hidden: the helper may go on once they are unmapped and a few frames have passed. Mapped again: not hidden.
    onMappedChanged: {
        if (root.mapped) {
            settle.stop();
            CaptureState.thumbnailsHidden = false;
        } else {
            settle.restart();
        }
    }

    Timer {
        id: settle
        interval: Tokens.captureThumbnailSettleMs
        onTriggered: CaptureState.thumbnailsHidden = true
    }

    // xdg-user-dir as the helper's user_dir() asks it (the shell's own environment, as the helper runs in).
    Process {
        id: resolver
        command: ["sh", "-c", "for k in DESKTOP DOCUMENTS PICTURES VIDEOS; do xdg-user-dir \"$k\" 2>/dev/null || echo; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.dirs = Thumbs.userDirs(text, Quickshell.env("HOME"));
                root.takePending();
            }
        }
    }

    Component {
        id: runner

        Process {
            id: proc
            property var done: null
            // qmllint disable signal-handler-parameters
            onExited: exitCode => {
                // qmllint enable signal-handler-parameters
                if (proc.done)
                    proc.done(exitCode === 0);
                proc.destroy();
            }
        }
    }

    Variants {
        model: root.cards.map(c => c.id)

        CaptureThumbnailCard {
            required property string modelData

            controller: root
            cardId: modelData
        }
    }
}
