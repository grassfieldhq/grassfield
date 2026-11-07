// A plain Qt Quick window, or a frameless one (Qt.FramelessWindowHint: what Telegram Desktop and other apps that draw their
// own title bar use), for tests/compositor/decorations.sh. The title is the last argument; a title containing "frameless"
// makes the window frameless. Qt's Wayland plugin asks for server-side decorations through xdg-decoration for a plain window
// and negotiates nothing for a frameless one.
import QtQuick
import QtQuick.Window

Window {
    readonly property string name: Qt.application.arguments[Qt.application.arguments.length - 1]

    width: 420
    height: 260
    visible: true
    title: name
    flags: name.indexOf("frameless") >= 0 ? (Qt.Window | Qt.FramelessWindowHint) : Qt.Window
    color: "#3a6ea5"
}
