// Part of tests/compositor/forward_keys.sh (NESTED only): an ordinary toplevel window (not a terminal class) with a text field that logs every key
// it receives as "[fk-fixture] key=<Qt key code> mods=<Qt modifier mask> text=<text>", and "[fk-fixture] mapped" once visible.
// Qt codes: Left 16777234, Right 16777236, Up 16777235, BackSpace 16777219, Delete 16777223, digits their ASCII code;
// modifiers Shift 33554432, Ctrl 67108864, Alt 134217728, Meta 268435456.
// Run: WAYLAND_DISPLAY=<nested> qs -p <this dir>
import QtQuick
import Quickshell

ShellRoot {
    FloatingWindow {
        id: win

        visible: true
        implicitWidth: 300
        implicitHeight: 200
        title: "forward-keys-fixture"
        color: "#335577"

        // A real text field (Qt's own Ctrl+A/C/X/V/Z handling) that logs each key before it handles it, and its text when it
        // changes as "[fk-fixture] edit=<text>": Command+A/C/X/V/Z are checked end to end, not only as the chord that arrives.
        TextInput {
            id: field

            anchors.fill: parent
            anchors.margins: 8
            focus: true
            color: "white"
            text: "grass field"
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: event => {
                console.log("[fk-fixture] key=" + event.key + " mods=" + event.modifiers + " text=" + JSON.stringify(event.text));
                event.accepted = false;
            }
            onTextChanged: console.log("[fk-fixture] edit=" + JSON.stringify(text))
        }

        Component.onCompleted: console.log("[fk-fixture] mapped")
    }
}
