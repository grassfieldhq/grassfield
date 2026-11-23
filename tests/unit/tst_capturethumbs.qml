import QtQuick
import QtTest
import "../../shell/capture/CaptureThumbs.js" as Thumbs
import "../../shell/services/CaptureFile.js" as CaptureFile

// The floating thumbnail (spec docs/specs/capture-suite.md § 3.2, ADR-0066 D-1 and D-9; slices A2 and A3): the helper's result
// file as the shell reads it, the cards (the stack, the layout, what hides them), and the checks and argument vectors of each
// action. A result path is data: one that is a folder, outside every Save to folder or the folder itself is refused.
TestCase {
    name: "CaptureThumbs"

    readonly property var dirs: Thumbs.userDirs("/home/u/Desktop\n/home/u/Documents\n/home/u/Pictures\n/home/u/Videos\n", "/home/u")
    readonly property var screens: [
        {name: "DP-1", x: 0, y: 0, width: 1920, height: 1080},
        {name: "HDMI-A-1", x: 1920, y: 0, width: 1920, height: 1080}
    ]
    readonly property var metrics: ({width: 216, pictureHeight: 135, inset: 6, minPictureWidth: 56, gap: 10})
    readonly property string shots: "/home/u/Pictures/Screenshots"
    readonly property string script: "/shell/services/capture-thumb.sh"

    function result(over) {
        const base = {v: 1, id: "0123456789abcdef", kind: "shot", paths: [shots + "/Screenshot.png"], primary: shots + "/Screenshot.png",
            output: "DP-1", rect: {x: 0, y: 0, w: 1920, h: 1080}, scale: 1.25, pixels: {w: 2400, h: 1350}, time: 1793800000000, text: ""};
        return JSON.stringify(Object.assign(base, over || {}));
    }

    function card(over) {
        const c = Thumbs.accept(CaptureFile.parseResult(result(over)), dirs, screens);
        verify(c !== null, "the result makes a card");
        return c;
    }

    // ---- the result file ----

    function test_resultPath() {
        compare(CaptureFile.resultPath("", "/run/user/1000"), "/run/user/1000/grassfield/capture-result.json");
        compare(CaptureFile.resultPath("/repo/.dev/state", "/run/user/1000"), "/repo/.dev/state/capture-result.json");
        compare(CaptureFile.resultPath("", ""), "");
    }

    function test_parseResult() {
        const r = CaptureFile.parseResult(result());
        compare(r.id, "0123456789abcdef");
        compare(r.kind, "shot");
        compare(r.primary, shots + "/Screenshot.png");
        compare(r.output, "DP-1");
        compare(r.pixels, {w: 2400, h: 1350});
        compare(r.scale, 1.25);
    }

    function test_parseResultRefused() {
        for (const text of ["", "{", "[]", "null", "1", result({v: 2}), result({id: "xyz"}), result({id: ""}), result({kind: "text"}),
                 result({paths: []}), result({paths: "x"}), result({paths: [5], primary: 5}), result({primary: "/other.png"}),
                 result({paths: [""], primary: ""}), result({paths: new Array(17).fill("/a.png"), primary: "/a.png"})])
            compare(CaptureFile.parseResult(text), null, text);
        // A field that does not read is dropped; the result still reads.
        const r = CaptureFile.parseResult(result({output: "../x", scale: -3, pixels: {w: 0, h: 5}, time: "now", text: 5}));
        compare(r.output, "");
        compare(r.scale, 1);
        compare(r.pixels, null);
        compare(r.time, 0);
        compare(r.text, "");
    }

    function test_resultFresh() {
        const r = CaptureFile.parseResult(result({time: 1000000}));
        verify(CaptureFile.resultFresh(r, 1000000 + 29000, 30000));
        verify(!CaptureFile.resultFresh(r, 1000000 + 31000, 30000), "a file left from before the shell started");
        verify(!CaptureFile.resultFresh(CaptureFile.parseResult(result({time: 0})), 1000, 30000), "no time, no card");
        verify(!CaptureFile.resultFresh(null, 1000, 30000));
    }

    // Capture Text (slice C3): no file, so no path; "" is never taken for one.
    function test_textResult() {
        const text = result({kind: "text", paths: [], primary: "", text: "Hello\nworld"});
        const r = CaptureFile.parseResult(text);
        compare(r.kind, "text");
        compare(r.paths, []);
        compare(r.primary, "");
        const c = Thumbs.accept(r, dirs, screens);
        compare(c.kind, "text");
        compare(c.path, "");
        compare(c.text, "Hello\nworld");
        compare(c.screen, "DP-1");
        for (const action of ["verify", "copy", "trash", "open", "annotate", "reveal"])
            compare(Thumbs.plan(action, c, dirs, script), null, "a text card runs nothing: " + action);
        verify(!c.qr, "recognised text is not a QR code");
        const q = Thumbs.accept(CaptureFile.parseResult(result({kind: "text", paths: [], primary: "", text: "", qr: true})), dirs, screens);
        verify(q.qr, "a result with the flag is a QR card");
        compare(q.text, "", "never the data");
        verify(!CaptureFile.parseResult(result({kind: "shot", qr: true})).qr, "the flag is for text results only");
        verify(!CaptureFile.parseResult(result({kind: "text", paths: [], primary: "", qr: "yes"})).qr, "a flag that is not true is not set");
        compare(CaptureFile.parseResult(result({kind: "text", paths: [shots + "/a.png"], primary: shots + "/a.png"})), null, "text with a file is not a result");
        compare(CaptureFile.parseResult(result({kind: "text", paths: [], primary: "/etc/passwd"})), null);
        compare(CaptureFile.parseResult(result({kind: "shot", paths: [], primary: ""})), null, "a picture needs its path");
        compare(CaptureFile.parseResult(result({kind: "text", paths: [], primary: "", text: ""})).text, "", "a QR result carries no text");
    }

    // ---- the Save to folders ----

    function test_userDirs() {
        compare(dirs.desktop, "/home/u/Desktop");
        compare(dirs.pictures, "/home/u/Pictures");
        const d = Thumbs.userDirs("/data/Bureau/\n\n/home/u\n/", "/home/u");
        compare(d.desktop, "/data/Bureau", "a trailing slash is dropped");
        compare(d.documents, "/home/u/Documents", "an empty answer is the folder of that name in the home folder");
        compare(d.pictures, "/home/u/Pictures", "the home folder itself is never a Save to folder");
        compare(d.videos, "/home/u/Videos", "nor the root");
        compare(Thumbs.userDirs("relative\nbad\n\x01x", "/home/u").desktop, "/home/u/Desktop");
    }

    function test_roots() {
        const s = Thumbs.roots("shot", dirs);
        verify(s.indexOf(shots) >= 0);
        verify(s.indexOf("/home/u/Pictures/Captures d’écran") >= 0, "the translated Screenshots folder");
        verify(s.indexOf("/home/u/Desktop") >= 0 && s.indexOf("/home/u/Documents") >= 0);
        verify(s.indexOf("/home/u/Pictures") >= 0, "the Pictures folder: the helper's fallback when Screenshots cannot be had");
        verify(s.indexOf("/home/u") < 0, "never the home folder");
        verify(s.indexOf("/home/u/Videos") < 0, "a screenshot is never in Videos");
        const r = Thumbs.roots("recording", dirs);
        compare(r.sort(), ["/home/u/Desktop", "/home/u/Documents", "/home/u/Videos"]);
    }

    // ---- the paths a card may name (A3) ----

    function test_pathAccepted() {
        compare(Thumbs.pathProblem("shot", shots + "/Screenshot 2026-11-23 at 10.00.00.png", dirs), "");
        compare(Thumbs.pathProblem("shot", "/home/u/Desktop/Capture.PNG", dirs), "", "the extension in any case");
        compare(Thumbs.pathProblem("shot", "/home/u/Documents/a.webp", dirs), "");
        compare(Thumbs.pathProblem("shot", "/home/u/Pictures/Screenshot.png", dirs), "", "the helper's fallback folder");
        compare(Thumbs.pathProblem("recording", "/home/u/Videos/Screen Recording.mp4", dirs), "");
    }

    function test_pathRefused() {
        const cases = [
            ["shot", "/etc/passwd.png", "a picture outside every Save to folder"],
            ["shot", "/home/u/Pictures/sub/a.png", "a folder below the Pictures folder"],
            ["recording", "/home/u/Pictures/a.mp4", "a recording is never in Pictures"],
            ["shot", "/home/u/a.png", "the home folder is not a Save to folder"],
            ["shot", shots + "/sub/a.png", "a folder below a Save to folder"],
            ["shot", shots + "/../a.png", "dot dot"],
            ["shot", shots + "/./a.png", "dot"],
            ["shot", shots + "//a.png", "a doubled slash"],
            ["shot", shots + "/a.png/", "a trailing slash"],
            ["shot", shots + "/.hidden.png", "a hidden name, the helper's file being written"],
            ["shot", shots + "/notes.txt", "not a picture"],
            ["shot", shots + "/a", "no extension"],
            ["shot", shots + "/Screen Recording.mp4", "a movie as a screenshot"],
            ["recording", shots + "/a.mp4", "a recording outside the recordings' folders"],
            ["recording", "/home/u/Videos/a.png", "a picture as a recording"],
            ["shot", "relative/a.png", "not absolute"],
            ["shot", "", "empty"],
            ["shot", "/a.png", "no folder"],
            ["shot", shots + "/a\nb.png", "a newline"],
            ["shot", shots + "/a\u0000.png", "a NUL"],
            ["video", shots + "/a.png", "an unknown kind"],
            ["shot", 5, "not text"]
        ];
        for (const c of cases)
            verify(Thumbs.pathProblem(c[0], c[1], dirs) !== "", c[2]);
    }

    // A forged result that names a Save to folder itself (or something above or beside it) as its file.
    function test_forgedFolder() {
        for (const forged of [shots, shots + "/", "/home/u/Pictures", "/home/u/Desktop", "/home/u/Documents", "/home/u", "/"]) {
            const r = CaptureFile.parseResult(result({paths: [forged], primary: forged}));
            if (r === null)
                continue;
            compare(Thumbs.accept(r, dirs, screens), null, forged);
        }
        // Another path of the result is as bad as the first: the whole result is refused.
        const two = CaptureFile.parseResult(result({paths: [shots + "/a.png", "/etc/shadow.png"], primary: shots + "/a.png"}));
        compare(Thumbs.accept(two, dirs, screens), null);
        // A folder that has a picture name is refused by the file system check: capture-thumb.sh (tests/shell/capture_thumb.sh).
    }

    function test_nothingActsOnARefusedPath() {
        const bad = {id: "ab", kind: "shot", path: "/etc/passwd.png", folder: "/etc", name: "passwd.png", pixels: null, screen: "DP-1", time: 0};
        for (const action of ["verify", "copy", "trash", "open", "annotate", "reveal"])
            compare(Thumbs.plan(action, bad, dirs, script), null, action);
        compare(Thumbs.plan("trash", null, dirs, script), null);
    }

    // ---- what each action runs (A3) ----

    function test_actionsAreArgvVectors() {
        const c = card();
        const folders = Thumbs.roots("shot", dirs);
        const guarded = verb => ["sh", script, verb, "shot", c.path].concat(folders);
        compare(Thumbs.plan("verify", c, dirs, script), {check: null, run: guarded("check")});
        compare(Thumbs.plan("copy", c, dirs, script), {check: null, run: guarded("copy")});
        compare(Thumbs.plan("trash", c, dirs, script), {check: null, run: guarded("trash")});
        compare(Thumbs.plan("open", c, dirs, script), {check: guarded("check"), run: ["gio", "open", c.path]});
        compare(Thumbs.plan("reveal", c, dirs, script), {check: guarded("check"), run: ["gio", "open", shots]});
        compare(Thumbs.plan("delete", c, dirs, script), null, "no action deletes");
        compare(Thumbs.plan("", c, dirs, script), null);
    }

    function test_argvHoldsEveryPathAsOneArgument() {
        const name = shots + "/a b'c; rm -rf x $(id).png";
        const c = card({paths: [name], primary: name});
        const plan = Thumbs.plan("trash", c, dirs, script);
        verify(plan.run.indexOf(name) === 4, "one argument, never joined into a shell string");
        compare(plan.run[0], "sh");
    }

    function test_recordingIsNotCopied() {
        const name = "/home/u/Videos/Screen Recording.mp4";
        const c = card({kind: "recording", paths: [name], primary: name, pixels: null});
        compare(Thumbs.plan("copy", c, dirs, script), null);
        compare(Thumbs.plan("trash", c, dirs, script).run.slice(0, 4), ["sh", script, "trash", "recording"]);
    }

    // The path the script checked is what is opened: its first line, an absolute path of the card's own name.
    function test_openedTakesTheCheckedPath() {
        const c = card();
        compare(Thumbs.opened("open", c, "/real/Pictures/Screenshots/Screenshot.png\n"), ["gio", "open", "/real/Pictures/Screenshots/Screenshot.png"]);
        compare(Thumbs.opened("annotate", c, "/real/Pictures/Screenshots/Screenshot.png\n"), ["grassfield-screenshot", "/real/Pictures/Screenshots/Screenshot.png"]);
        compare(Thumbs.opened("reveal", c, "/real/Pictures/Screenshots/Screenshot.png\n"), ["gio", "open", "/real/Pictures/Screenshots"]);
        const jpg = card({paths: [shots + "/a.jpg"], primary: shots + "/a.jpg"});
        compare(Thumbs.opened("annotate", jpg, "/r/a.jpg\n"), ["gio", "open", "/r/a.jpg"], "the editor opens PNG files");
        const name = "/home/u/Videos/Screen Recording.mp4";
        const rec = card({kind: "recording", paths: [name], primary: name, pixels: null});
        compare(Thumbs.opened("annotate", rec, "/r/Screen Recording.mp4\n"), ["gio", "open", "/r/Screen Recording.mp4"], "a recording is not edited");
        for (const bad of ["", "\n", "relative/Screenshot.png", "/real/other.png", "/Screenshot.png", "/real/Screenshot.png\u0001"])
            compare(Thumbs.opened("open", c, bad), null, JSON.stringify(bad));
        compare(Thumbs.opened("delete", c, "/real/Screenshot.png"), null);
        compare(Thumbs.clickAction(c), "annotate");
        compare(Thumbs.clickAction(rec), "open");
        compare(Thumbs.plan("annotate", c, dirs, script).run, [Thumbs.EDITOR, c.path]);
    }

    // The shell decodes only the PNG image-copy.py made, never the capture file.
    function test_pictureIsMadeByTheHelper() {
        const c = card();
        compare(Thumbs.copyArgv("/s/image-copy.py", c.path, 1000, "/run/u/x-1-1.png"),
            ["/usr/bin/timeout", "-k", "2", "20", "/usr/bin/setpriv", "--pdeathsig", "KILL", "--", "/usr/bin/python3", "-I", "/s/image-copy.py", "file", c.path, "1000", "/run/u/x-1-1.png"]);
        compare(Thumbs.copyPath("/run/user/1000", "wayland-1", 42, 3), "/run/user/1000/grassfield-capture-thumb-wayland-1-42-3.png");
        compare(Thumbs.copyPath("/run/user/1000", "a/../b", 1, 1), "/run/user/1000/grassfield-capture-thumb-a_.._b-1-1.png");
        compare(Thumbs.copyPath("", "wayland-1", 1, 1), "");
        compare(Thumbs.copyPath("relative", "wayland-1", 1, 1), "");
    }

    // A source file that is not a capture the shell may show never reaches a decoder of its own: the card's Image reads only the
    // copy's URL (a static guard on the card), and the helper refuses a FIFO (tests/shell/capture_thumb_copy.sh).
    function test_cardImageReadsOnlyTheCopy() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../shell/capture/CaptureThumbnailCard.qml"), false);
        xhr.send();
        verify(xhr.responseText.indexOf("controller.copyUrl(") > 0);
        verify(xhr.responseText.indexOf("fileUrl(") < 0, "the card never builds a URL of the capture file");
        verify(xhr.responseText.indexOf("card.path") < 0 || xhr.responseText.indexOf("source: win.verified") > 0);
        const lines = xhr.responseText.split("\n").filter(l => l.indexOf("source:") >= 0 && l.indexOf("card.path") >= 0);
        compare(lines.length, 0, "no Image source names the capture's path");
    }

    function test_uriList() {
        compare(Thumbs.uriList("/home/u/Pictures/Screenshots/a b#1.png"), "file:///home/u/Pictures/Screenshots/a%20b%231.png\r\n");
        compare(Thumbs.fileUrl("/x/a?b.png"), "file:///x/a%3Fb.png");
    }

    // ---- the card, the stack and the layout (A2) ----

    function test_accept() {
        const c = card();
        compare(c.id, "0123456789abcdef");
        compare(c.path, shots + "/Screenshot.png");
        compare(c.folder, shots);
        compare(c.name, "Screenshot.png");
        compare(c.screen, "DP-1");
    }

    function test_cardGoesOnTheCapturesDisplay() {
        compare(card({output: "HDMI-A-1"}).screen, "HDMI-A-1");
        compare(card({output: "", rect: {x: 2000, y: 100, w: 400, h: 300}}).screen, "HDMI-A-1", "by the area's centre");
        compare(card({output: "GONE-1", rect: null}).screen, "DP-1", "the first display when none says");
        compare(Thumbs.accept(CaptureFile.parseResult(result()), dirs, []), null, "no display, no card");
    }

    function test_stackOfThree() {
        let cards = [];
        for (const id of ["a1", "a2", "a3", "a4"])
            cards = Thumbs.push(cards, Object.assign({}, card(), {id: id}), 3);
        compare(cards.map(c => c.id), ["a4", "a3", "a2"], "newest first, the oldest leaves");
        cards = Thumbs.push(cards, Object.assign({}, card({output: "HDMI-A-1"}), {id: "b1"}), 3);
        compare(cards.map(c => c.id), ["b1", "a4", "a3", "a2"], "three per display");
        cards = Thumbs.push(cards, Object.assign({}, card(), {id: "a3"}), 3);
        compare(cards.map(c => c.id), ["a3", "b1", "a4", "a2"], "a result seen twice is one card");
        compare(Thumbs.remove(cards, "a4").map(c => c.id), ["a3", "b1", "a2"]);
    }

    function test_cardShapeFollowsThePicture() {
        const wide = Thumbs.cardSize({kind: "shot", pixels: {w: 1600, h: 900}}, metrics);
        compare(wide.pictureWidth, 204);
        compare(wide.pictureHeight, 115);
        compare(wide.width, 216);
        compare(wide.height, 127);
        const tall = Thumbs.cardSize({kind: "shot", pixels: {w: 500, h: 1000}}, metrics);
        compare(tall.pictureHeight, 135, "never taller than the limit");
        compare(tall.pictureWidth, 68, "narrower then");
        const slim = Thumbs.cardSize({kind: "shot", pixels: {w: 10, h: 4000}}, metrics);
        compare(slim.pictureWidth, 56, "never narrower than the least");
        compare(Thumbs.cardSize({kind: "recording", pixels: null}, metrics).pictureHeight, 115);
        compare(Thumbs.cardSize({kind: "shot", pixels: null}, metrics).pictureHeight, 115, "a size not known: 16 by 9");
    }

    // The Close disc and the action capsule fit side by side whatever the capture's shape (a portrait capture used to squeeze them
    // over each other and out of the card).
    function test_cardNeverNarrowerThanItsButtons() {
        const least = Thumbs.leastPictureWidth(28, 4, 6);
        compare(least, 3 * 6 + (28 + 8) + (3 * 28 + 8), "the disc, the capsule and the room around and between them");
        const m = Object.assign({}, metrics, {minPictureWidth: least});
        const portrait = Thumbs.cardSize({kind: "shot", pixels: {w: 600, h: 1200}}, m);
        verify(portrait.pictureWidth >= least, "a portrait capture: " + portrait.pictureWidth);
        compare(portrait.pictureHeight, 135);
        const slim = Thumbs.cardSize({kind: "shot", pixels: {w: 10, h: 4000}}, m);
        compare(slim.pictureWidth, least);
        const wide = Thumbs.cardSize({kind: "shot", pixels: {w: 6000, h: 400}}, m);
        compare(wide.pictureWidth, 204, "a very wide capture keeps the card's width");
        verify(wide.pictureHeight >= 1 && wide.pictureHeight < 135);
        verify(wide.pictureWidth >= least);
    }

    // The folder names are the helper's: its SCREENSHOTS and every translation in its CATALOG. One list in two places must not drift.
    function test_screenshotFolderNamesAreTheHelpers() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../packaging/bin/grassfield-capture"), false);
        xhr.send();
        const text = xhr.responseText;
        verify(text.length > 1000, "the helper was read");
        const base = /^SCREENSHOTS = "([^"]+)"$/m.exec(text);
        verify(base !== null);
        const names = [base[1]];
        const re = /^\s+SCREENSHOTS: "([^"]+)",$/gm;
        let m;
        while ((m = re.exec(text)) !== null)
            names.push(m[1]);
        compare(names.length >= 2, true, "the catalog names the folder in French");
        compare(Thumbs.SCREENSHOT_FOLDERS.slice().sort(), names.slice().sort());
    }

    function test_layoutNewestOnTopOldestAtTheBottom() {
        const mk = (id, screen) => ({id: id, kind: "shot", pixels: {w: 1600, h: 900}, screen: screen});
        const out = Thumbs.layout([mk("c", "DP-1"), mk("x", "HDMI-A-1"), mk("b", "DP-1"), mk("a", "DP-1")], "DP-1", metrics);
        compare(out.map(e => e.id), ["c", "b", "a"]);
        compare(out.map(e => e.below), [2 * (127 + 10), 127 + 10, 0], "the oldest sits at the corner, a new card above");
        compare(Thumbs.layout([mk("x", "HDMI-A-1")], "DP-1", metrics), []);
    }

    // ---- what hides the cards (A2) ----

    function test_hiddenNow() {
        verify(!Thumbs.hiddenNow("idle", false, false));
        verify(!Thumbs.hiddenNow("countdown", false, false), "the countdown does not hide them: the picture is not taken yet");
        verify(!Thumbs.hiddenNow("selecting", false, false));
        verify(Thumbs.hiddenNow("shooting", false, false), "a card is never in a picture");
        verify(Thumbs.hiddenNow("frozen", false, false));
        verify(Thumbs.hiddenNow("starting", false, false), "nor in a recording");
        verify(Thumbs.hiddenNow("recording", false, false));
        verify(Thumbs.hiddenNow("idle", true, false), "the lock");
        verify(Thumbs.hiddenNow("idle", false, true), "a full-attention surface");
        verify(Thumbs.hiddenNow("idle", "yes", false) === false, "only a real lock state");
    }

    // The acknowledgement of a shooting state waits for the cards: replay what CaptureState does with `thumbnailsHidden`.
    function test_acknowledgementWaitsForTheCards() {
        const shooting = CaptureFile.parse('{"v": 1, "phase": "shooting", "kind": "shot", "seq": "0011223344556677"}');
        compare(CaptureFile.ackNeeded(shooting, false, ""), "", "cards still mapped: no acknowledgement");
        compare(CaptureFile.ackNeeded(shooting, true, ""), "0011223344556677", "unmapped and a frame passed: acknowledged");
        compare(CaptureFile.ackNeeded(shooting, true, "0011223344556677"), "", "once");
    }

    // A new capture unmaps the older cards for its shooting phase: they come back where they were, not sliding in again, with the
    // time they had left.
    function test_cardsKeepTheirStateAcrossAnUnmap() {
        verify(Thumbs.slidesIn(false, true), "the first time it maps");
        verify(!Thumbs.slidesIn(true, true), "mapped again after a capture: already in");
        verify(!Thumbs.slidesIn(false, false), "not mapped: nothing slides");
        compare(Thumbs.remainingAfter(5000, 1000, 3000), 3000, "paused after 2 s of 5: 3 s left");
        compare(Thumbs.remainingAfter(3000, 9000, 9500), 2500, "and again after half a second more");
        compare(Thumbs.remainingAfter(1000, 0, 5000), 1, "never zero: it does not close the instant it is shown");
        compare(Thumbs.remainingAfter(1000, 5000, 4000), 1000, "a clock that went back loses nothing");
    }

    function test_sideAndSeconds() {
        compare(Thumbs.sideOf("left"), "left");
        compare(Thumbs.sideOf("right"), "right");
        compare(Thumbs.sideOf("top"), "right");
        compare(Thumbs.secondsOf(5), 5);
        compare(Thumbs.secondsOf(30), 30);
        compare(Thumbs.secondsOf(1), 0);
        compare(Thumbs.secondsOf(2.5), 0);
        compare(Thumbs.secondsOf("5"), 0);
    }

    function test_dragIntent() {
        compare(Thumbs.dragIntent("right", 12, 3), "swipe", "toward the right edge");
        compare(Thumbs.dragIntent("right", -12, 3), "out", "away from the edge: the file");
        compare(Thumbs.dragIntent("right", 3, -12), "out", "up: the file");
        compare(Thumbs.dragIntent("left", -12, 3), "swipe");
        compare(Thumbs.dragIntent("left", 12, 0), "out");
        verify(Thumbs.dismissed("right", 48, 48));
        verify(!Thumbs.dismissed("right", 47, 48));
        verify(Thumbs.dismissed("left", -60, 48));
        verify(!Thumbs.dismissed("left", 60, 48));
    }
}
