import QtQuick
import QtTest

// ADR-0040 step 4a (ID-7, ID-2, ID-15; ADR-0016 section 6, W8): the lock's backdrop and data, ready before they are needed.
// The modules need Quickshell, so their contract is read from the sources (the pure parts, WallpaperConfig.lockBackdropOf and
// withShown, run in tests/unit/tst_wallpaper.qml). Invariants for the security review:
//   - the lock decodes only the helper's own picture, checked again by absolute path and argument vector, never a shell, and
//     no video decoder enters the module;
//   - the lock surface asks for exactly what was decoded before, with the same options (the pixmap cache key);
//   - what a surface shows is taken once (backdrop, name, picture); the clock is refreshed on resume;
//   - engaging the lock reads none of it.
TestCase {
    name: "LockBackdrop"

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        // Comments out: a rule must hold in the code, not in a sentence about it.
        return xhr.responseText.split("\n").map(l => l.replace(/^\s*\/\/.*$/, "")).join("\n");
    }

    function block(text, start) {
        const i = text.indexOf(start);
        verify(i >= 0, start);
        let depth = 0;
        for (let j = text.indexOf("{", i); j < text.length; j++) {
            if (text[j] === "{")
                depth++;
            else if (text[j] === "}" && --depth === 0)
                return text.substring(i, j + 1);
        }
        fail("unbalanced " + start);
        return "";
    }

    function test_theStillIsCheckedBeforeItIsDecoded() {
        const s = source("shell/security/lock/LockStill.qml");
        // Absolute paths, an argument vector, `--` before the path; nothing else is run.
        // The two cache folders' own real paths with the file's (a cache behind a symbolic link), and the raw mode, which no
        // locale translates (review of cbd6ef05).
        // ADR-0041 S2: the folders come from the security process's own reader of wallpaper.json (LockWallpaper), never the
        // desktop's WallpaperState.
        verify(s.indexOf('root.run("real", ["/usr/bin/realpath", "-m", "--", root.wallpaper.preparedDir, root.wallpaper.videoDir, w.file]);') >= 0);
        verify(!/WallpaperState/.test(s), "no WallpaperState in the security process");
        verify(/readonly property var wanted: root\.wallpaper \? root\.wallpaper\.lockBackdrop\(root\.output\) : null/.test(s));
        // The reader: bounded (head -c, a timeout), watched without reading (preload: false), the pure lockBackdropOf.
        const r = source("shell/security/lock/LockWallpaper.qml");
        verify(r.indexOf('command: ["/usr/bin/timeout", "-k", "1", "5", "/usr/bin/head", "-c", String(root.maxBytes + 1), "--", root.stateFile]') >= 0);
        verify(/watchChanges: true\s*preload: false/.test(r) && /return WallpaperConfig\.lockBackdropOf\(root\.saved, output, root\.preparedDir, root\.videoDir\);/.test(r));
        verify(!/setText|atomicWrites|WallpaperState|execDetached/.test(r), "it writes nothing and starts nothing else");
        verify(s.indexOf('root.run("stat", ["/usr/bin/stat", "--printf", "%f|%s", "--", real]);') >= 0);
        compare((s.match(/root\.run\(/g) || []).length, 2);
        verify(!/"(sh|bash)"|execDetached|Quickshell\.exec/.test(s), "no shell");
        // The real path must still be a plain cache name of one of the two folders, and the file regular and bounded.
        verify(/const real = WallpaperConfig\.lockStillReal\(text\);\s*if \(real === ""\) \{\s*root\.fail\(/.test(s));
        verify(/if \(!WallpaperConfig\.lockStillStatOk\(text, Tokens\.wallpaperLockStillMaxBytes\)\) \{\s*root\.fail\(/.test(s));
        // The decode is only ever of the checked real path.
        // Set to the checked path, cleared on a new request and on a failure (a late decode is not kept).
        compare((s.match(/image\.source = /g) || []).length, 3);
        verify(s.indexOf('image.source = "file://" + root.pending;') >= 0 && s.indexOf('image.source = "";') >= 0);
        // An answer of a superseded request is dropped.
        verify(/function realChecked\(text: string, gen: int\): void \{\s*if \(gen !== root\.generation\)\s*return;/.test(s));
        verify(/function statChecked\(text: string, gen: int\): void \{\s*if \(gen !== root\.generation\)\s*return;/.test(s));
        // A check that never answers gives the artwork.
        verify(/interval: Tokens\.wallpaperToolTimeoutMs/.test(s));
    }

    function test_theLockAsksForWhatWasDecoded() {
        const still = block(source("shell/security/lock/LockStill.qml"), "Image {");
        const viewText = source("shell/security/lock/LockView.qml");
        const view = block(viewText, "Image {\n            id: still");
        for (const b of [still, view]) {
            verify(/cache: true/.test(b), b);
            verify(/fillMode: Image\.Stretch/.test(b), b);
            verify(!/sourceSize/.test(b), "no sourceSize: the cache key must not depend on the window's scale");
        }
        verify(/source: root\.backdrop !== null && root\.backdrop\.kind === "picture" \? root\.backdrop\.still : ""/.test(view));
        // The account picture: the same options as LockStills.qml's preload, and only once it is decoded.
        const lock = source("shell/security/lock/Lock.qml");
        const holder = source("shell/security/lock/LockStills.qml");
        const preload = block(holder, "Image {\n        id: avatarPreload");
        const picture = block(viewText, "Image {\n                id: picture");
        for (const b of [preload, picture]) {
            verify(/cache: true/.test(b) && /fillMode: Image\.PreserveAspectCrop/.test(b) && !/sourceSize/.test(b), b);
        }
        verify(/source: VisualFixtures\.active \? "" : root\.frozenAvatar/.test(picture));
        verify(/readonly property string avatarReady: avatarPreload\.status === Image\.Ready \? String\(avatarPreload\.source\) : ""/.test(holder));
        verify(/readonly property string avatarReady: root\.stills \? root\.stills\.avatarReady : ""/.test(lock));
        verify(/avatarSource: root\.avatarReady/.test(lock));
        // No video decoder in the security modules (ADR-0016 section 6).
        for (const f of ["shell/security/lock/Lock.qml", "shell/security/lock/LockView.qml", "shell/security/lock/LockStill.qml", "shell/security/lock/LockStills.qml"])
            verify(!/QtMultimedia|MediaPlayer|VideoOutput/.test(source(f)), f);
    }

    function test_whatTheLockShowsIsTakenOnce() {
        const v = source("shell/security/lock/LockView.qml");
        verify(/function adopt\(b: var\): void \{\s*if \(root\.backdrop === null && b !== null && b !== undefined\)\s*root\.backdrop = b;\s*\}/.test(v));
        compare((v.match(/root\.backdrop = /g) || []).length, 1, "adopt() is the only writer");
        verify(/root\.frozenName = root\.userName;/.test(v) && /root\.frozenAvatar = root\.avatarSource;/.test(v));
        verify(/readonly property string shownName: VisualFixtures\.active \? VisualFixtures\.user : frozenName/.test(v));
        // Bounded: nothing decided in time gives the artwork.
        verify(/interval: Tokens\.wallpaperFirstShowTimeoutMs\s*running: root\.backdrop === null/.test(v));
        // Sharp: no blur left on the lock (IQ-W4 A).
        verify(!/blurEnabled|blurMax/.test(v));
        // The clock on resume.
        verify(/onResumesChanged: clock\.refresh\(\)/.test(v));
        const inhibitor = source("shell/security/idle/SleepInhibitor.qml");
        verify(/function afterResume\(\): void \{[\s\S]*?Lock\.resumed\(\);[\s\S]*?\n    \}/.test(inhibitor));
        // The surface's own colour is the ground (ID-2, ID-15), taken once.
        const lockSrc = source("shell/security/lock/Lock.qml");
        verify(/function takeGround\(\): void \{\s*if \(surface\.groundTaken \|\| !surface\.screen\)\s*return;\s*surface\.groundTaken = true;\s*surface\.color = root\.groundOf\(surface\.screen\.name\);/.test(lockSrc));
        // ADR-0041 S2: the ground the compositor was last given, from the lock's own reader (the UI's Ground is not here).
        verify(/function groundOf\(output: string\): string \{\s*return root\.stills \? root\.stills\.ground : Tokens\.sessionGround;\s*\}/.test(lockSrc));
        verify(/onScreenChanged: surface\.takeGround\(\)/.test(lockSrc) && /Component\.onCompleted: surface\.takeGround\(\)/.test(lockSrc));
        // Focus first in the view (review of cbd6ef05).
        verify(/Component\.onCompleted: \{\s*focusField\(\);/.test(v));
    }

    // Review of cbd6ef05 (MAJOR 3): the display data is created at run time, last, never declared in the singleton that owns
    // WlSessionLock: a file of it that fails to load cannot keep the lock from existing.
    function test_theDisplayDataCannotBreakTheLock() {
        const lock = source("shell/security/lock/Lock.qml");
        verify(!/\bLockStills?\s*\{/.test(lock), "no LockStill or LockStills declared in Lock.qml");
        verify(!/\bVariants\s*\{/.test(lock) && !/\bImage\s*\{/.test(lock));
        verify(/Qt\.createComponent\(Qt\.resolvedUrl\("LockStills\.qml"\)\)/.test(lock));
        verify(/function prepareStills\(\): void \{\s*try \{/.test(lock), "every failure is caught and logged");
        verify(/strandedProbe\.start\(\);\s*\}\s*\/\/[^\n]*\n\s*prepareStills\(\);\s*\}/.test(source("shell/security/lock/Lock.qml").replace(/\r/g, "")) || /prepareStills\(\);\s*\}\s*$/m.test(lock), "last in Component.onCompleted");
    }

    // ADR-0040 step 4b (IQ-T2 A): the content fades in and out; the release follows the controller's timer (the machine's
    // "releasing", tst_lockmachine and tst_lockcontroller), never the view's animation; a lock request during it keeps the
    // lock; no input while releasing; the wallpaper does not fade.
    function test_theReleaseWaitsForTheFade() {
        const lock = source("shell/security/lock/Lock.qml");
        verify(/releaseMs: Appearance\.duration\(Tokens\.lockFadeOutMs\)/.test(lock));
        verify(/inputEnabled: controller\.pamAvailable && !controller\.releasing/.test(lock));
        verify(/function lock\(reason: string\): string \{\s*(\/\/[^\n]*\n\s*)*if \(controller\.interruptRelease\(\)\)/.test(lock), "a lock request interrupts a release first");
        verify(/if \(controller\.authenticating\) \{[^}]*controller\.abort\(\);\s*\}/.test(lock), "and abandons a check in flight");
        verify(/readonly property bool holding: Machine\.isHolding\(controller\.lockState\) && sessionLock\.secure/.test(lock));
        // The lock is released only from the controller's unlockRequested (after the fade), as before.
        compare((lock.match(/root\.release\(\)/g) || []).length, 1);
        verify(/onUnlockRequested: root\.release\(\)/.test(lock));
        const v = source("shell/security/lock/LockView.qml");
        compare((v.match(/opacity: root\.contentOpacity/g) || []).length, 3, "the scrim, the date and clock, the account column");
        const at = v.indexOf("visible: root.backdrop !== null\n");
        verify(at > 0);
        const backdrop = block(v.substring(v.lastIndexOf("Item {", at)), "Item {");
        verify(/id: still/.test(backdrop) && /GrassfieldArtwork \{/.test(backdrop), "the backdrop's block");
        verify(!/contentOpacity/.test(backdrop), "the wallpaper does not fade");
        verify(/duration: Appearance\.duration\(root\.releasing \? Tokens\.lockFadeOutMs : Tokens\.lockFadeInMs\)/.test(v));
        // The view knows nothing of the release: no signal, no call back into the lock.
        verify(!/signal\s+released|unlockRequested|controller\./.test(v));
    }

    // ADR-0040 step 5 (ID-8, IQ-T4 A, IQ-T5 A): the order of idle, the saver and display-off.
    function test_theIdleOrder() {
        const idle = source("shell/security/idle/Idle.qml");
        // The idle lock is requested at once; the dim stays until it holds (bounded); a failed request lifts it at once.
        const lockTimer = block(idle, "Timer {\n        id: lockTimer");
        // The dim is held before the request: Lock.lock() flips `locked` synchronously and update() runs inside it.
        verify(/Lock\.fromDim = true;\s*root\.dimUntilLock = true;\s*dimUntilLockBound\.restart\(\);\s*const result = Lock\.lock\("idle"\);/.test(lockTimer));
        verify(/if \(result !== "ok"\) \{\s*root\.dimUntilLock = false;\s*dimUntilLockBound\.stop\(\);\s*Lock\.fromDim = false;\s*root\.dimmed = false;/.test(lockTimer));
        verify(/interval: IdleModel\.DIM_UNTIL_LOCK_MAX_MS\s*onTriggered: root\.endDimUntilLock\(\)/.test(idle));
        verify(/if \(Lock\.holding\) \{\s*root\.endDimUntilLock\(\);\s*root\.dimmed = false;/.test(idle));
        // A display that turns off for inactivity locks: at once, after the delay, or never.
        verify(/readonly property int requireAfterMs: IdleModel\.requireAfterDisplayOffMs\(Settings\.lockRequirePasswordAfterDisplayOff\)/.test(idle));
        verify(/if \(root\.offForInactivity && !Lock\.locked\) \{\s*if \(root\.requireAfterMs === 0\)\s*root\.displayOffLock\(\);\s*else if \(root\.requireAfterMs > 0\)\s*displayOffLockTimer\.restart\(\);/.test(idle));
        verify(/const result = Lock\.lock\("display-off"\);/.test(idle));
        // The displays stay on until a lock holds (unchanged rule): the lock is drawn before they go off.
        verify(/return inactiveOff === true && \(locked !== true \|\| holding === true\);/.test(source("shell/security/idle/IdleModel.js")));
        // The saver stays until the lock holds, bounded.
        // ADR-0041 S2: from the state the security process publishes ("locking" = locked, not held yet).
        const saver = source("shell/saver/Saver.qml");
        verify(/readonly property bool lockStarting: SessionState\.lockStarting/.test(saver));
        verify(/readonly property bool shown: \(root\.lockStarting && root\.wasShown\) \|\| \(!SessionState\.locked && /.test(saver));
        verify(/interval: SaverModel\.UNTIL_LOCK_MAX_MS\s*onTriggered: root\.wasShown = false/.test(saver));
        // The lock's content starts at the dim's level.
        const lock = source("shell/security/lock/Lock.qml");
        verify(/startDim: root\.fromDim \? Tokens\.idleDimOpacity : 0/.test(lock));
        verify(/opacity: root\.releasing \? 0 : root\.frozenDim \* \(1 - root\.contentOpacity\)/.test(source("shell/security/lock/LockView.qml")));
        // IQ-T5 A: the red "lock screen died" screen waits past a normal restart (1 to 2 s), not for ever.
        const m = /^\s*lockdead_screen_delay = (\d+),/m.exec(source("config/hypr/grassfield/looknfeel.lua"));
        verify(m !== null);
        verify(Number(m[1]) >= 3000 && Number(m[1]) <= 10000, m[1]);
    }

    // ADR-0040 step 9, as the integrator decided in the review of e067f26f: the moving artwork's clouds move on the lock only.
    // Display only: the setting taken at creation like the name, the start until they first move, never on the lock path,
    // played by the artwork's own Timer while the backdrop is the artwork (not while releasing, not under Reduce Motion, not
    // while held: the displays off or the session unlocked), slowed to a stop within the release fade without anything
    // waiting for it; where they rest goes back to the desktop through the stills, any failure caught. (Opus review of
    // bdc11b2d: the handlers are checked whole or to their end, MINOR 2.)
    function test_theCloudsMoveOnTheLockOnly() {
        const v = source("shell/security/lock/LockView.qml");
        verify(/Component\.onCompleted: \{\s*focusField\(\);/.test(v), "focus still first");
        verify(/root\.frozenMoving = root\.moving;\s*lockArt\.motionMs = root\.motionStart;/.test(v), "taken at creation");
        compare((v.match(/root\.frozenMoving = /g) || []).length, 1);
        compare((v.match(/lockArt\.motionMs = /g) || []).length, 2, "at creation, and the start until they first move");
        verify(/readonly property bool motionPlays: root\.frozenMoving && root\.backdrop !== null && root\.backdrop\.kind === "art" && !root\.releasing && !Appearance\.reduceMotion && !root\.motionHeld\n/.test(v));
        compare(block(v, "onMotionPlaysChanged: {").replace(/\s+/g, " "), "onMotionPlaysChanged: { if (root.motionPlays) Qt.callLater(() => { root.motionTaken = true; }); }");
        compare(block(v, "onMotionStartChanged: {").replace(/\s+/g, " "), "onMotionStartChanged: { if (root.frozenMoving && !root.motionTaken) lockArt.motionMs = root.motionStart; }");
        const art = block(v, "GrassfieldArtwork {");
        verify(/id: lockArt/.test(art) && /moving: root\.frozenMoving/.test(art) && /playing: root\.motionPlays/.test(art), art);
        // The slow-down: within the fade (the controller's releaseMs), from where they are, and stopped when a lock request
        // interrupts the release. The whole handler, so that nothing else (input, focus, the controller) can be added to it.
        compare(block(v, "onReleasingChanged: {").replace(/\s+/g, " "), "onReleasingChanged: { motionStop.stop(); if (!root.releasing || !root.frozenMoving) return; root.motionTaken = true; const fade = Appearance.duration(Tokens.lockFadeOutMs); const rest = WallpaperConfig.lockMotionRest(lockArt.motionMs, lockArt.movingOn && root.backdrop !== null && root.backdrop.kind === \"art\" && !Appearance.reduceMotion, fade); root.motionRest = rest; if (rest > lockArt.motionMs) { motionStop.to = rest; motionStop.duration = fade; motionStop.start(); } }");
        compare((v.match(/root\.motionRest = /g) || []).length, 1, "written only when the fade starts");
        const anim = block(v, "NumberAnimation {\n        id: motionStop");
        verify(/target: lockArt/.test(anim) && /property: "motionMs"/.test(anim) && /easing\.type: Easing\.OutQuad/.test(anim), anim);
        // The view still only offers data: no signal but the two it had, each emitted from one place.
        compare((v.match(/^\s*signal\s/gm) || []).length, 2);
        verify(/signal submitted\(string password\)/.test(v) && /signal edited/.test(v));
        compare((v.match(/root\.submitted\(/g) || []).length, 1);
        compare((v.match(/root\.edited\(/g) || []).length, 1);
        // Counter-review of 7db57a7d (MINOR): no handler can be added unnoticed, in the view or on its instance in Lock.qml
        // (a handler there could submit a password, end the release or unlock).
        const handlers = text => (text.match(/^\s*((?:\w+\.)?on[A-Z]\w*)\s*:/gm) || []).map(h => h.trim().replace(/\s*:$/, "")).sort();
        compare(handlers(v), ["Component.onCompleted", "onEdited", "onMotionPlaysChanged", "onMotionStartChanged", "onOfferedBackdropChanged", "onPressed",
            "onReleasingChanged", "onResumesChanged", "onSubmitted", "onTriggered"]);
        // Lock.qml: the setting through the stills, frozen by the view; where they rest is the lock's own map (ADR-0041 S2),
        // published with the lock state (LockPublisher) for the desktop, set in a try.
        const lock = source("shell/security/lock/Lock.qml");
        verify(/readonly property bool moving: root\.stills \? root\.stills\.moving : false/.test(lock));
        verify(/function motionOf\(output: string\): real \{\s*return WallpaperConfig\.motionIn\(root\.motion, output\);\s*\}/.test(lock));
        verify(/function restMotion\(output: string, at: real\): void \{\s*try \{\s*if \(output !== "" && at >= 0\)\s*root\.motion = WallpaperConfig\.withMotion\(root\.motion, output, at\);\s*\} catch \(e\) \{/.test(lock));
        verify(/LockPublisher \{\s*id: publisher\s*state: root\.publicState\s*displaysOff: root\.displaysOff\s*motion: root\.motion\s*\}/.test(lock));
        verify(/^\s*moving: root\.moving\n\s*motionHeld: root\.displaysOff \|\| !controller\.locked\n\s*motionStart: root\.motionOf\(surface\.screen \? surface\.screen\.name : ""\)\n\s*onMotionRestChanged: root\.restMotion\(surface\.screen \? surface\.screen\.name : "", view\.motionRest\)\n/m.test(lock), "each line to its end");
        compare((lock.match(/onMotionRestChanged/g) || []).length, 1);
        const instance = block(lock, "sourceComponent: LockView {");
        compare(handlers(instance), ["Component.onDestruction", "onEdited", "onFieldEmptyChanged", "onMotionRestChanged", "onSubmitted"]);
        compare(instance.match(/controller\.\w+\(/g), ["controller.submit(", "controller.clearMessage("], "the instance calls the controller twice: a password, a cleared message");
        verify(!/WallpaperState/.test(lock), "Lock.qml itself reads no wallpaper state");
        verify(/property bool displaysOff: false/.test(lock));
        // Idle tells it the displays are off, outside its own display logic (setDisplays unchanged).
        const idle = source("shell/security/idle/Idle.qml");
        verify(/onDisplayOffChanged: Lock\.displaysOff = root\.displayOff/.test(idle));
        compare((idle.match(/Lock\.displaysOff/g) || []).length, 1);
        verify(!/displaysOff/.test(block(idle, "function setDisplays(on: bool): void {")));
        const stills = source("shell/security/lock/LockStills.qml");
        verify(/readonly property bool moving: reader\.moving/.test(stills));
        verify(!/WallpaperState/.test(stills) && !/restMotion/.test(stills), "the stills read wallpaper.json through LockWallpaper and give nothing back");
        verify(/readonly property bool moving: WallpaperConfig\.normalize\(Settings\.wallpaper\)\.moving/.test(source("shell/security/lock/LockWallpaper.qml")));
    }

    function test_engagingTheLockReadsNoneOfIt() {
        const lock = source("shell/security/lock/Lock.qml");
        for (const fn of ["function lock(reason: string): string {", "function engage(): void {", "function release(): void {", "function restore(intent: bool, when: string): void {"]) {
            const b = block(lock, fn);
            verify(!/backdrop|stills|Stills|avatarPreload|avatarReady|resumes|motion|moving|displaysOff|fromDim/i.test(b), fn);
        }
        // The backdrops only feed the view.
        compare((lock.match(/root\.backdropOf\(/g) || []).length, 1);
    }

    // The integrator's nested run of 122f8d67 (sleep-desync): Hyprland confirms the lock once every lock surface drew a frame.
    // The surface's first frame is its opaque ground; LockView, its one view, is incubated after it by an asynchronous Loader,
    // so the confirmation never waits for the view's creation or its effects.
    function test_theConfirmationWaitsForTheGroundOnly() {
        const lock = source("shell/security/lock/Lock.qml").replace(/\r/g, "");
        verify(/WlSessionLockSurface \{\s*id: surface\s*color: Tokens\.colorDark\.shadow/.test(lock), "the surface has its own opaque colour");
        verify(/\n\s*Loader \{\n\s*id: content\n\s*anchors\.fill: parent\n\s*asynchronous: true\n\s*sourceComponent: LockView \{\n\s*id: view\n/.test(lock), "LockView is loaded asynchronously");
        compare((lock.match(/\bLockView \{/g) || []).length, 1, "one LockView, inside the Loader");
        // The controller's shake and clear reach the view from inside it (no reference to an item that may not exist yet).
        verify(/sourceComponent: LockView \{[^]*Connections \{\s*target: controller\s*function onFailed\(\): void \{\s*view\.shake\(\);/.test(lock));
    }
}
