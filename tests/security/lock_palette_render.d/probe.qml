import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.services

// tests/security/lock_palette_render.sh: the REAL lock surface (ProbeLockSurface.qml, generated next to this file by
// lock_palette_render.d/surface.py from Lock.qml's WlSessionLockSurface block and its groundOf(): the ground colour, the
// view's loader and every binding given to the LockView it creates) offscreen in a window, with every input the same but the
// appearance. A scene holds three surfaces:
//   - the main one (860 x 600, its screen known): the ground from groundOf(), and the LockView with its real children, all
//     shown: the artwork backdrop, the scrim, the date and clock, the user's lock message (from the settings file), the
//     initials disc, the name, the password field holding a typed password and the keyboard focus (its caret hidden: it
//     blinks, which is time, not the appearance), the error line and the notice line;
//   - two grounds alone (the view's loader stopped: the surface's first frame), one whose screen is not known yet (the
//     surface's own colour) and one whose screen is (groundOf()).
// Saved under $LOCK_RENDER_OUT:
//   dark.png, light.png     the scene built with Appearance.dark true, then one built with it false
//   flip-before.png, flip-light.png, flip-back.png   one scene built dark, the appearance flipped to light while it is shown,
//                           then back
//   control-dark.png, control-light.png              a rectangle in Appearance.colors.text (must differ: the grab sees the
//                           appearance)
// and next to each PNG a .colours file: every colour and every URL among the properties of every visible item of the scene
// (see inputs()), the shader-drawn parts included: the offscreen renderer is Qt's software scene graph, which draws no shader
// effect, so the text shadows' layers are turned on for the walk (their MultiEffects exist and are walked) and off for the
// grab (the texts themselves are drawn).
// Before each save the scene must be fully shown (see shownWhy()). Reduce Motion is on, nothing is mid-fade (a wait after each
// change), and the grabs run within one minute of the clock (else the run is done once more). Prints "lock-render: DONE" or
// "lock-render: ERROR <why>", and exits.
ShellRoot {
    id: root

    readonly property string out: Quickshell.env("LOCK_RENDER_OUT") || ""
    readonly property string lockMessage: "Back after lunch"
    readonly property string password: "correct horse"
    property var surfaceComponent: null
    property var scene: null
    property var view: null
    property var input: null
    property var layered: []
    property var control: null
    property int step: 0
    property int attempt: 0
    property int minute: -1
    property bool finished: false

    function deepWith(item, prop: string): var {
        if (!item)
            return null;
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++) {
            const f = root.deepWith(kids[i], prop);
            if (f)
                return f;
        }
        return prop in item ? item : null;
    }

    function loaderOf(surface): var {
        const loader = root.deepWith(surface, "fallbackMs");
        return loader && "sourceComponent" in loader ? loader : null;
    }

    function finish(why: string): void {
        if (root.finished)
            return;
        root.finished = true;
        console.log(why === "" ? "lock-render: DONE" : "lock-render: ERROR " + why);
        Qt.exit(why === "" ? 0 : 1);
    }

    // The items whose layer draws an effect (the lock's text shadows), found while the layers are on.
    function layersOf(item, found: var): void {
        if (!item)
            return;
        if (item.layer && item.layer.enabled && item.layer.effect)
            found.push(item);
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++)
            root.layersOf(kids[i], found);
    }

    function setLayers(on: bool): void {
        for (const item of root.layered)
            item.layer.enabled = on;
    }

    // ---- the walk: every property of every visible item ----
    // inputs() of an item: each of its properties (for...in over the QObject: its meta-object's properties, declared ones
    // included, e.g. a ShaderEffect's own `property color tint`) whose value is a colour (a color value, or a string that
    // Qt.color reads), or a URL (an Image's source, a shader's file); the QObjects it holds (border, gradient and its stops,
    // palette and its colour groups, layer, anchors, its non-visual resources: Timers, Bindings, animations) and its lists,
    // arrays and plain objects (a `var` palette) the same way, each once. Items are reached through the tree, never through a
    // reference (parent, anchors.fill, a MultiEffect's source); a Component is not an instance (a layer's effect is walked as
    // the item it makes, while the layers are on); a Date is time, not the appearance.
    readonly property var skipped: ["children", "visibleChildren", "data", "parent"]
    function isItem(v): bool {
        return "childrenRect" in v && "visibleChildren" in v;
    }
    function isColour(v): bool {
        return "r" in v && "g" in v && "b" in v && "a" in v && "hslHue" in v;
    }
    function colourString(s: string): bool {
        if (s === "" || s.length > 40 || /\s/.test(s))
            return false;
        try {
            Qt.color(s);
            return true;
        } catch (e) {
            return false;
        }
    }
    function value(v, at: string, lines: var, seen: var, depth: int): void {
        if (v === null || v === undefined)
            return;
        const t = typeof v;
        if (t === "string") {
            if (root.colourString(v))
                lines.push(at + " " + v);
            return;
        }
        if (t !== "object")
            return;
        if (v instanceof Date)
            return;
        if (root.isColour(v)) {
            lines.push(at + " " + String(v));
            return;
        }
        if (root.isItem(v) || ("createObject" in v && "status" in v))
            return;
        if (depth >= 4 || seen.has(v))
            return;
        if ("objectName" in v) {
            seen.add(v);
            root.inputs(v, at, lines, seen, depth + 1);
            return;
        }
        if (typeof v.length === "number") {
            seen.add(v);
            for (let i = 0; i < v.length; i++)
                root.value(v[i], at + "[" + i + "]", lines, seen, depth + 1);
            return;
        }
        const s = String(v);
        if (s === "[object Object]") {
            seen.add(v);
            for (const k in v)
                root.value(v[k], at + "." + k, lines, seen, depth + 1);
            return;
        }
        // A value type: a URL prints as itself; the others print as their type (QFont(...), QRectF(...), ...).
        if (!/^Q\w*\(/.test(s))
            lines.push(at + " " + s);
    }
    function inputs(o, at: string, lines: var, seen: var, depth: int): void {
        for (const k in o) {
            if (root.skipped.indexOf(k) >= 0)
                continue;
            let v;
            try {
                v = o[k];
            } catch (e) {
                continue;
            }
            if (typeof v === "function")
                continue;
            root.value(v, at + "." + k, lines, seen, depth);
        }
    }
    function walk(item, path: string, lines: var, seen: var): void {
        if (!item || !item.visible)
            return;
        const type = String(item).replace(/\(0x[0-9a-f]+.*$/, "").replace(/_QML(TYPE)?_\d+$/, "");
        root.inputs(item, path + " " + type, lines, seen, 0);
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++)
            root.walk(kids[i], path + "/" + i, lines, seen);
    }

    // ---- the scene must be fully shown before a save ----
    function opacityOf(item): real {
        let o = 1;
        for (let p = item; p && p !== root.scene; p = p.parent)
            o *= p.opacity;
        return o;
    }
    function textsOf(item, found: var): void {
        if (!item || !item.visible)
            return;
        if ("textFormat" in item && "text" in item && !("echoMode" in item) && root.opacityOf(item) === 1)
            found.push(item.text);
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++)
            root.textsOf(kids[i], found);
    }
    // "" when the main view shows everything, fully (nothing mid-fade), with the password typed and the focus in the field;
    // else why not.
    function shownWhy(): string {
        const v = root.view;
        if (!v || !v.shown || v.contentOpacity !== 1)
            return "the view is not fully shown (contentOpacity " + (v ? v.contentOpacity : "none") + ")";
        if (!v.backdrop || v.backdrop.kind !== "art")
            return "the view has not taken its backdrop";
        const f = root.input;
        if (!f || f.length !== root.password.length || v.fieldEmpty || f.echoMode !== TextInput.Password)
            return "the password was not typed into the field (length " + (f ? f.length : "none") + ")";
        if (!f.activeFocus)
            return "the field does not have the keyboard focus (the focus ring path is not drawn)";
        if (f.cursorVisible)
            return "the caret shows (it blinks)";
        if (v.notice === "")
            return "the view has no notice";
        const texts = [];
        root.textsOf(v, texts);
        for (const want of [root.lockMessage, "Robin Example", "RE", "Incorrect password", v.notice])
            if (texts.indexOf(want) < 0)
                return "the text '" + want + "' is not fully shown (shown: " + JSON.stringify(texts) + ")";
        if (texts.length < 7)
            return "only " + texts.length + " texts shown (the date, the clock and five lines expected): " + JSON.stringify(texts);
        for (const g of [root.scene.groundUnknown, root.scene.groundKnown]) {
            const l = root.loaderOf(g);
            if (!l || l.active || l.item)
                return "a ground surface shows more than its ground";
        }
        if (root.deepWith(root.scene.groundUnknown, "groundTaken").groundTaken || !root.deepWith(root.scene.groundKnown, "groundTaken").groundTaken)
            return "the grounds are not one before and one after the screen is known";
        return "";
    }

    // One writer per file (a FileView whose path changes between two writes can drop one).
    Component {
        id: writerComponent

        FileView {
            preload: false
            blockWrites: true
            printErrors: false
        }
    }

    function save(item, name: string, check: bool): void {
        if (check) {
            root.input.cursorVisible = false;
            const why = root.shownWhy();
            if (why !== "")
                return root.finish(why);
        }
        const lines = [];
        // The shadows' effects exist while the layers are on: walked then, turned off again before the grab.
        root.setLayers(true);
        try {
            root.walk(item, "", lines, new Set());
        } finally {
            root.setLayers(false);
        }
        if (check) {
            const shadows = lines.filter(l => /\.shadowColor /.test(l)).length;
            if (shadows < root.layered.length)
                return root.finish("the walk saw " + shadows + " shadow colours for " + root.layered.length + " shadowed texts");
        }
        const writer = writerComponent.createObject(root, {path: root.out + "/" + name.replace(/\.png$/, ".colours")}) as FileView;
        writer.setText(lines.join("\n") + "\n");
        item.grabToImage(result => {
            if (!result.saveToFile(root.out + "/" + name))
                return root.finish("cannot save " + name);
            root.advance();
        });
    }

    // Builds the scene in the given appearance; advance() once the main view is loaded, typed into and settled.
    function build(dark: bool): void {
        Appearance.dark = dark;
        if (root.scene)
            root.scene.destroy();
        root.view = null;
        root.input = null;
        root.scene = sceneComponent.createObject(host);
        const s = root.scene;
        // Made at run time: ProbeLockSurface.qml exists only in the script's scratch tree. The grounds' view loaders are
        // stopped as soon as they are made, before they make anything (the surface's first frame).
        s.main = root.surfaceComponent.createObject(s, {width: 860, height: 600, screen: {name: "GF-PROBE-1"}});
        s.groundUnknown = root.surfaceComponent.createObject(s, {y: 610, width: 200, height: 100});
        s.groundKnown = root.surfaceComponent.createObject(s, {x: 210, y: 610, width: 200, height: 100, screen: {name: "GF-PROBE-2"}});
        for (const g of [s.groundUnknown, s.groundKnown]) {
            const l = g ? root.loaderOf(g) : null;
            if (!l)
                return root.finish("a ground surface has no view loader");
            l.active = false;
        }
        if (!s.main)
            return root.finish("the main surface was not made");
        root.until(() => {
            const l = root.loaderOf(root.scene.main);
            return l !== null && l.status === Loader.Ready && l.item !== null;
        }, 10000, "the main surface's view did not load", () => {
            root.view = root.loaderOf(root.scene.main).item;
            root.input = root.deepWith(root.view, "echoMode");
            if (!root.input)
                return root.finish("the password field's input was not found");
            root.input.text = root.password;
            // The text shadows: their layers found (on, as LockView sets them), then turned off for the grabs.
            const found = [];
            root.layersOf(root.view, found);
            root.layered = found;
            if (found.length < 3)
                return root.finish("the shadowed texts were not found (" + found.length + ")");
            root.setLayers(false);
            root.input.cursorVisible = false;
            root.wait(700);
        });
    }

    function flip(dark: bool): void {
        Appearance.dark = dark;
        root.wait(500);
    }

    // ---- the steps: each one ends by calling advance(), at once or later ----
    property var pending: null
    function wait(ms: int): void {
        stepper.interval = Math.max(1, ms);
        stepper.restart();
    }
    function until(cond, ms: int, why: string, then): void {
        const started = Date.now();
        root.pending = () => {
            let ok = false;
            try {
                ok = cond();
            } catch (e) {
                ok = false;
            }
            if (ok) {
                poller.stop();
                root.pending = null;
                then();
            } else if (Date.now() - started > ms) {
                poller.stop();
                root.pending = null;
                root.finish(why);
            }
        };
        poller.restart();
    }

    readonly property var steps: [
        () => {
            if (root.out === "")
                return root.finish("LOCK_RENDER_OUT unset");
            root.surfaceComponent = Qt.createComponent(Qt.resolvedUrl("ProbeLockSurface.qml"));
            if (root.surfaceComponent.status !== Component.Ready)
                return root.finish("ProbeLockSurface.qml: " + root.surfaceComponent.errorString());
            Appearance.reduceMotion = true;
            root.minute = new Date().getMinutes();
            // The user's lock message comes from the settings file the script wrote (Settings > Lock Screen).
            root.until(() => Settings.lockShowMessage === true && Settings.lockMessage === root.lockMessage, 10000, "the settings file was not read (lock.showMessage " + Settings.lockShowMessage + ")", root.advance);
        },
        () => root.build(true),
        () => root.save(root.scene, "dark.png", true),
        () => root.build(false),
        () => root.save(root.scene, "light.png", true),
        () => root.build(true),
        () => root.save(root.scene, "flip-before.png", true),
        () => root.flip(false),
        () => root.save(root.scene, "flip-light.png", true),
        () => root.flip(true),
        () => root.save(root.scene, "flip-back.png", true),
        () => {
            root.control = controlComponent.createObject(host);
            root.flip(true);
        },
        () => root.save(root.control, "control-dark.png", false),
        () => root.flip(false),
        () => root.save(root.control, "control-light.png", false),
        () => {
            if (new Date().getMinutes() !== root.minute && root.attempt === 0) {
                // The clock moved during the grabs: once more from the start.
                root.attempt = 1;
                if (root.control)
                    root.control.destroy();
                root.control = null;
                root.step = -1;
                Qt.callLater(root.advance);
                return;
            }
            root.finish("");
        }
    ]

    function advance(): void {
        if (root.finished)
            return;
        root.step++;
        if (root.step >= root.steps.length)
            return;
        try {
            root.steps[root.step]();
        } catch (e) {
            root.finish("the probe stopped: " + e);
        }
    }

    Timer {
        id: stepper
        onTriggered: root.advance()
    }

    Timer {
        id: poller
        interval: 50
        repeat: true
        onTriggered: {
            if (root.pending)
                root.pending();
        }
    }

    Timer {
        interval: 100000
        running: true
        onTriggered: root.finish("the probe did not finish within 100 s (step " + root.step + ")")
    }

    Component.onCompleted: {
        root.step = -1;
        Qt.callLater(root.advance);
    }

    Component {
        id: sceneComponent

        Item {
            property var main: null
            property var groundUnknown: null
            property var groundKnown: null

            width: 860
            height: 720
        }
    }

    Component {
        id: controlComponent

        Rectangle {
            y: 730
            width: 40
            height: 20
            color: Appearance.colors.text
        }
    }

    FloatingWindow {
        implicitWidth: 880
        implicitHeight: 760
        visible: true
        color: "black"

        Item {
            id: host
            anchors.fill: parent
        }
    }
}
