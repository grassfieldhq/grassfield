import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.security.lock

// tests/security/lock_palette_render.sh: the REAL lock surface content (shell/security/lock/LockView.qml with its real
// children: the artwork backdrop, the scrim, the date and clock, the initials disc, the name, the password field with a
// password typed, the error line; the caret, which blinks, taken off; the text shadow, a shader effect the offscreen renderer
// does not draw, turned off so the date, the clock and the name are drawn) offscreen in a window, with every input the same but the appearance. Saved under
// $LOCK_RENDER_OUT:
//   dark.png, light.png     a view built with Appearance.dark true, then one built with it false
//   flip-before.png, flip-light.png, flip-back.png   one view built dark, the appearance flipped to light while it is shown,
//                           then back
//   control-dark.png, control-light.png              a rectangle in Appearance.colors.text (must differ: the grab sees the
//                           appearance)
// and next to each PNG a .colours file: the colour inputs of every visible item (shader-drawn parts included: the offscreen
// renderer draws no shader effect, so an Icon's tint is compared by its input).
// Reduce Motion is on, nothing is mid-fade (a wait after each change), and the grabs run within one minute of the clock
// (else the run is done once more). Prints "lock-render: DONE" or "lock-render: ERROR <why>", and exits.
ShellRoot {
    id: root

    readonly property string out: Quickshell.env("LOCK_RENDER_OUT") || ""
    property var view: null
    property var control: null
    property int step: 0
    property int attempt: 0
    property int minute: -1

    function deepWith(item, prop) {
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

    function make(dark: bool): void {
        Appearance.dark = dark;
        if (root.view)
            root.view.destroy();
        root.view = viewComponent.createObject(host);
        const input = root.deepWith(root.view, "echoMode");
        if (input)
            input.text = "correct horse";
        root.view.message = "Incorrect password";
        // The caret blinks (time, not the appearance): the keyboard is taken off the field so the grabs compare. The caret's
        // colour is the field's text colour, the dots' (LockView's dark palette), which the grabs do compare.
        host.forceActiveFocus();
        // The texts drawn through the lock's text shadow (a shader effect: the date, the clock, the name, the lock message)
        // draw nothing in the offscreen renderer: their layers are turned off, so the texts themselves are drawn and
        // compared. The shadow's own colour is Appearance.darkColors.shadow (tests/security/lock_palette.py).
        root.shadowed = 0;
        root.unshadow(root.view);
    }

    property int shadowed: 0
    function unshadow(item): void {
        if (!item)
            return;
        if (item.layer && item.layer.enabled && item.layer.effect) {
            item.layer.enabled = false;
            root.shadowed++;
        }
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++)
            root.unshadow(kids[i]);
    }

    function finish(why: string): void {
        console.log(why === "" ? "lock-render: DONE" : "lock-render: ERROR " + why);
        Qt.exit(why === "" ? 0 : 1);
    }

    // The colour inputs of every visible item under `item`, one line each (`<path> <type> <property> <value>`), shader-drawn
    // parts included: the offscreen renderer is Qt's software scene graph, which draws no shader effect (an Icon's tint, a
    // MultiEffect's colorization or shadow), so what such a part WOULD draw is compared by its colour inputs.
    readonly property var colourProps: ["color", "colorizationColor", "shadowColor", "textColor", "placeholderColor", "fillColor", "selectionColor",
        "selectedTextColor", "styleColor", "linkColor", "tintColor", "borderColor", "glyphColor", "labelColor"]
    function colours(item, path: string, lines: var): void {
        if (!item || (item.visible !== undefined && !item.visible))
            return;
        const type = String(item).replace(/\(0x[0-9a-f]+.*$/, "").replace(/_QML_\d+$/, "");
        for (const name of root.colourProps) {
            if (name in item && item[name] !== undefined && item[name] !== null && typeof item[name] === "object" && "r" in item[name])
                lines.push(path + " " + type + " " + name + " " + String(item[name]));
        }
        if (item.border && item.border.color !== undefined && item.border.width > 0)
            lines.push(path + " " + type + " border.color " + String(item.border.color));
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++)
            root.colours(kids[i], path + "/" + i, lines);
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

    function save(item, name: string, next): void {
        const lines = [];
        root.colours(item, "", lines);
        const writer = writerComponent.createObject(root, {path: root.out + "/" + name.replace(/\.png$/, ".colours")});
        writer.setText(lines.join("\n") + "\n");
        item.grabToImage(result => {
            if (!result.saveToFile(root.out + "/" + name)) {
                root.finish("cannot save " + name);
                return;
            }
            next();
        });
    }

    // [what to do, then the wait before the next step in ms]
    readonly property var steps: [
        [() => {
            if (root.out === "")
                return root.finish("LOCK_RENDER_OUT unset");
            Appearance.reduceMotion = true;
            root.minute = new Date().getMinutes();
            root.make(true);
        }, 700],
        [() => {
            if (root.shadowed < 3)
                return root.finish("the shadowed texts were not found (" + root.shadowed + ")");
            root.save(root.view, "dark.png", root.advance);
        }, -1],
        [() => root.make(false), 700],
        [() => root.save(root.view, "light.png", root.advance), -1],
        [() => root.make(true), 700],
        [() => root.save(root.view, "flip-before.png", root.advance), -1],
        [() => {
            Appearance.dark = false;
        }, 500],
        [() => root.save(root.view, "flip-light.png", root.advance), -1],
        [() => {
            Appearance.dark = true;
        }, 500],
        [() => root.save(root.view, "flip-back.png", root.advance), -1],
        [() => {
            root.control = controlComponent.createObject(host);
            Appearance.dark = true;
        }, 300],
        [() => root.save(root.control, "control-dark.png", root.advance), -1],
        [() => {
            Appearance.dark = false;
        }, 300],
        [() => root.save(root.control, "control-light.png", root.advance), -1],
        [() => {
            if (new Date().getMinutes() !== root.minute && root.attempt === 0) {
                // The clock moved during the grabs: once more from the start.
                root.attempt = 1;
                root.step = -1;
                return;
            }
            root.finish("");
        }, 0]
    ]

    function advance(): void {
        root.step++;
        if (root.step >= root.steps.length)
            return;
        const s = root.steps[root.step];
        try {
            s[0]();
        } catch (e) {
            root.finish("the probe stopped: " + e);
            return;
        }
        if (s[1] >= 0) {
            stepper.interval = Math.max(1, s[1]);
            stepper.restart();
        }
    }

    Timer {
        id: stepper
        onTriggered: root.advance()
    }

    Component.onCompleted: {
        root.step = -1;
        Qt.callLater(root.advance);
    }

    Component {
        id: viewComponent

        LockView {
            width: 860
            height: 600
            shown: true
            userName: "Robin Example"
            frozenName: "Robin Example"
            showUser: true
            backdrop: ({kind: "art", artwork: "grassfield", variant: "evening.dark"})
            offeredBackdrop: ({kind: "art", artwork: "grassfield", variant: "evening.dark"})
        }
    }

    Component {
        id: controlComponent

        Rectangle {
            y: 610
            width: 40
            height: 20
            color: Appearance.colors.text
        }
    }

    FloatingWindow {
        implicitWidth: 880
        implicitHeight: 640
        visible: true
        color: "black"

        Item {
            id: host
            anchors.fill: parent
        }
    }
}
