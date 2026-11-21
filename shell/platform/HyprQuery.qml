import QtQuick
import Quickshell.Io

// One request on Hyprland's request socket and its whole answer, in-process (audit fluidity note: `hyprctl grassfield-tiling`
// and `hyprctl grassfield-stages` forked a process for every notice of the plugin, every tile, move or Stages change). Created
// per request (TilingLink, StagesLink): it sends `line` (what hyprctl would send: a plugin's command is answered by its
// name), adds up the answer as it arrives (in pieces, no newline at its end) until Hyprland closes the connection, then
// signals `answered` once and destroys itself. An error, or no answer within `answerMs`, answers ok = false with what came.
// The error is judged after Quickshell's own error handler has returned (Compositor's requestSocket: closing the socket
// from inside that signal crashed Quickshell 0.3.2).
Socket {
    id: sock

    property string line: ""
    property int answerMs: 2000
    property string reply: ""
    property bool judged: false

    signal answered(string reply, bool ok)

    function finish(ok: bool): void {
        if (sock.judged)
            return;
        sock.judged = true;
        sock.answerTimer.stop();
        sock.answered(sock.reply, ok);
        sock.connected = false;
        Qt.callLater(() => sock.destroy());
    }

    parser: SplitParser {
        splitMarker: ""
        onRead: data => sock.reply += data
    }

    onConnectedChanged: {
        if (connected) {
            write(sock.line);
            flush();
            sock.answerTimer.start();
        } else {
            sock.finish(sock.reply !== "");
        }
    }

    readonly property Timer answerTimer: Timer {
        interval: sock.answerMs
        onTriggered: sock.finish(false)
    }

    Component.onCompleted: {
        sock.error.connect(() => Qt.callLater(() => sock.finish(false)));
        sock.connected = true;
    }
}
