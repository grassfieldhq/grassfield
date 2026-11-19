pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui

// Icon from the current freedesktop icon theme (image://icon, see src/imageproviders.cpp).
// `tint` recolors monochrome "-symbolic" icons with a token color; full-color icons stay as they are.
Item {
    id: root

    property string name: ""
    property int size: Tokens.filesListIconSize
    property bool tint: root.name.endsWith("-symbolic")
    property color color: Appearance.glyphTint(root)

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    Image {
        id: image
        anchors.fill: parent
        source: root.name !== "" ? "image://icon/" + root.name : ""
        sourceSize: Qt.size(root.size * Tokens.filesThumbnailOversample, root.size * Tokens.filesThumbnailOversample)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        visible: !root.tint
    }

    // Made only for a tinted icon: an untinted one (the emblems of every row) carries no effect.
    Loader {
        active: root.tint
        anchors.fill: parent
        sourceComponent: MultiEffect {
            source: image
            autoPaddingEnabled: false
            brightness: 1.0
            colorization: 1.0
            // Full alpha, the colour's alpha as the opacity (see Icon.qml).
            colorizationColor: Qt.rgba(root.color.r, root.color.g, root.color.b, 1)
            opacity: root.color.a
        }
    }
}
