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
    // The picture is the card (macOS 27: no plate around it), so a picture card has no inset; a Capture Text card is as tall as its
    // title and its first lines (the same fonts the card sets them in).
    readonly property var metrics: ({
            width: Tokens.captureThumbnailWidth,
            pictureHeight: Tokens.captureThumbnailPictureHeight,
            inset: 0,
            minPictureWidth: Thumbs.leastPictureWidth(Tokens.captureThumbnailButtonSize, Tokens.spacingXs, Tokens.captureThumbnailInset),
            gap: Tokens.captureThumbnailGap,
            textPad: Tokens.captureThumbnailInset + Tokens.spacingXs,
            titleHeight: titleMetrics.height,
            textGap: Tokens.spacingXs,
            lineHeight: bodyMetrics.height,
            charsPerLine: Math.floor((Tokens.captureThumbnailWidth - 2 * (Tokens.captureThumbnailInset + Tokens.spacingXs)) / Math.max(1, bodyMetrics.averageCharacterWidth)),
            maxLines: Tokens.captureThumbnailTextLines,
            lines: root.textLines
        })
    readonly property real textPad: root.metrics.textPad
    // The lines each Capture Text card's own Text measured (id -> lines), reassigned on every change.
    property var textLines: ({})

    function setTextLines(id: string, n: int): void {
        if (root.textLines[id] === n)
            return;
        root.textLines = Object.assign({}, root.textLines, {[id]: n});
    }

    FontMetrics {
        id: titleMetrics
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        font.weight: Tokens.typographyTitleWeight
    }

    FontMetrics {
        id: bodyMetrics
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    // Each card's size and the room under it, by id, on whole device pixels of the display it is on.
    readonly property var entries: {
        const out = {};
        for (const s of Quickshell.screens)
            for (const e of Thumbs.layout(root.cards, s.name, Object.assign({}, root.metrics, {
                    scale: s.devicePixelRatio
                })))
                out[e.id] = e;
        return out;
    }

    function cardById(id: string): var {
        return root.cards.find(c => c.id === id) ?? null;
    }

    // The card goes at once (a file that did not pass, a card that is not mapped): no exit animation.
    function remove(id: string): void {
        root.cards = Thumbs.remove(root.cards, id);
        if (root.leaving[id] !== undefined) {
            const next = Object.assign({}, root.leaving);
            delete next[id];
            root.leaving = next;
        }
    }

    // The card goes the way macOS's thumbnail does: it slides out toward its screen edge (CaptureThumbnailCard, which then calls
    // `remove`; a card that is not mapped is removed at once). Timeout, Close, a swipe, a drop, Move to Trash and an opened file.
    function dismiss(id: string): void {
        if (root.cardById(id) === null || root.leaving[id] === true)
            return;
        root.leaving = Object.assign({}, root.leaving, {[id]: true});
    }

    // Cards on their way out, by id.
    property var leaving: ({})

    // The pictures the cards show: the shell decodes only PNGs it made itself (services/image-copy.py `file`, as the lock
    // screen's avatar and the notifications' images: docs/specs/security-images.md), never the capture file. id ->
    // {state: "pending" | "ok" | "no", path}; reassigned on every change. A card is mapped once its picture is ready or refused
    // (then it shows its glyph).
    property var copies: ({})
    // The folder is ready (made 0700 and emptied), and the first preparation has ended (a refusal leaves no picture).
    property bool cleaned: false
    property bool cleanerDone: false
    property int counter: 0
    readonly property string copyHelper: Quickshell.shellPath("services/image-copy.py")
    // A source file at most this large (CaptureThumbs.COPY_CAP: an 8K picture); the copy is at most 256 x 256 pixels.
    readonly property real copyCap: Thumbs.COPY_CAP
    // The pictures' private folder ($XDG_RUNTIME_DIR/grassfield/capture-thumbs, 0700), made and emptied by capture-thumb-dir.sh.
    readonly property string copyFolder: Thumbs.copyFolder(CaptureState.folder)

    function copyState(id: string): string {
        const entry = root.copies[id];
        return entry === undefined ? "" : entry.state;
    }

    function copyUrl(id: string): string {
        const entry = root.copies[id];
        return entry !== undefined && entry.state === "ok" ? "file://" + entry.path : "";
    }

    function setCopy(id: string, entry: var): void {
        root.copies = Object.assign({}, root.copies, {[id]: entry});
    }

    // Makes the card's picture, once its file passed the check. One try per card.
    function makeCopy(id: string): void {
        const card = root.cardById(id);
        if (card === null || card.kind !== "shot" || root.copies[id] !== undefined)
            return;
        const out = Thumbs.copyPath(root.copyFolder, Quickshell.processId, ++root.counter);
        if (out === "") {
            root.setCopy(id, {state: "no", path: ""});
            return;
        }
        root.setCopy(id, {state: "pending", path: out});
        const start = ready => {
            if (!ready) {
                root.setCopy(id, {state: "no", path: ""});
                return;
            }
            root.job(Thumbs.copyArgv(root.copyHelper, card.path, root.copyCap, out), ({}), ok => {
                const still = root.cardById(id) !== null;
                root.setCopy(id, {state: ok && still ? "ok" : "no", path: out});
                if (!still)
                    root.deleteCopy(out);
            });
        };
        if (root.cleanerDone)
            start(root.cleaned);
        else
            root.waiting = root.waiting.concat([start]);
    }

    property var waiting: []

    function deleteCopy(path: string): void {
        if (path !== "" && root.copyFolder !== "" && path.indexOf(root.copyFolder + "/") === 0)
            root.job(["rm", "-f", "--", path], ({}), () => {});
    }

    // A card that left takes its picture with it.
    onCardsChanged: {
        const keep = {};
        for (const c of root.cards)
            keep[c.id] = true;
        const next = {};
        let changed = false;
        for (const id in root.copies) {
            if (keep[id] === true) {
                next[id] = root.copies[id];
            } else {
                changed = true;
                if (root.copies[id].state !== "pending")
                    root.deleteCopy(root.copies[id].path);
            }
        }
        if (changed)
            root.copies = next;
        // The last card has left: the folder is emptied (a picture whose copy was still being made is deleted when it ends).
        if (root.cards.length === 0 && root.cleanerDone && !cleaner.running)
            cleaner.running = true;
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
            root.remove(id);
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
        // The script prints the path it checked, links resolved; that is what is opened.
        root.job(plan.check, ({}), (ok, output) => {
            const argv = ok ? Thumbs.opened(action, card, output) : null;
            if (argv === null) {
                root.remove(id);
                return;
            }
            Apps.openDetached(argv);
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

    // Runs argv; `done(ok, output)` when it ends.
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

    // The folder is made (0700, no link) and emptied when the shell starts, before the first picture, and again when the last card
    // leaves. Without it (a refusal, no runtime folder) no picture is made: the cards show their glyph.
    Process {
        id: cleaner
        running: root.copyFolder !== ""
        command: ["sh", Quickshell.shellPath("services/capture-thumb-dir.sh"), root.copyFolder]
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            root.cleaned = code === 0;
            root.cleanerDone = true;
            const queued = root.waiting;
            root.waiting = [];
            for (const start of queued)
                start(root.cleaned);
        }
    }

    Component {
        id: runner

        Process {
            id: proc
            property var done: null
            stdout: StdioCollector {
                id: out
            }
            // qmllint disable signal-handler-parameters
            onExited: exitCode => {
                // qmllint enable signal-handler-parameters
                if (proc.done)
                    proc.done(exitCode === 0, out.text);
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
