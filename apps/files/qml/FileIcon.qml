pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "IconSource.js" as IconSource

// A file's picture: its KIO thumbnail when one exists, else the theme icon for its type, plus the
// symbolic-link emblem.
Item {
    id: root
    // A rule or frame: one point (apps.borderWidth, ADR-0039 D5) in whole device pixels, 1 px at 1.25 where 1 pt drew a soft
    // 1.25 px (UI audit 2026-11-05 U37); 1 px at 1x and 2 px at 2x as before.
    readonly property real hairline: Math.max(1, Math.round(Tokens.appsBorderWidth * Screen.devicePixelRatio)) / Math.max(1, Screen.devicePixelRatio)

    property string iconName: ""
    property string thumbnail: ""
    property string emblem: ""
    property int size: Tokens.filesIconSize
    // A folder: its own colour setting ("" = the global folder colour) and symbol (FolderIcon).
    property bool isDir: false
    property string folderColor: ""
    property string folderGlyph: ""
    // Drawn over the accent fill of a selected, focused row (the plate and ink are then the opposite of the fill).
    property bool overAccent: false

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    // The type icon follows the icon appearance mode (ADR-0014); thumbnails are content and are never tinted.
    // A folder icon follows the folder colour and shows its symbol; any other file the plain icon.
    Loader {
        anchors.fill: parent
        visible: thumb.status !== Image.Ready
        sourceComponent: root.isDir ? folderIcon : fileIcon
    }

    Component {
        id: fileIcon

        TintedIcon {
            size: root.size
            oversample: Tokens.filesThumbnailOversample
            overAccent: root.overAccent
            solidMaterial: true
            source: root.iconName !== "" ? IconSource.url(root.iconName) : ""
        }
    }

    Component {
        id: folderIcon

        FolderIcon {
            size: root.size
            oversample: Tokens.filesThumbnailOversample
            source: root.iconName !== "" ? IconSource.url(root.iconName) : ""
            folderColor: root.folderColor
            folderGlyph: root.folderGlyph
            overAccent: root.overAccent
        }
    }

    Image {
        id: thumb
        anchors.centerIn: parent
        width: Math.min(root.size, implicitWidth)
        height: Math.min(root.size, implicitHeight)
        source: root.thumbnail
        sourceSize: Qt.size(root.size * Tokens.filesThumbnailOversample, root.size * Tokens.filesThumbnailOversample)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
        visible: status === Image.Ready

        // Thin frame so light thumbnails stay distinct from the window background.
        Rectangle {
            anchors.centerIn: parent
            width: thumb.paintedWidth + 2 * root.hairline
            height: thumb.paintedHeight + 2 * root.hairline
            color: "transparent"
            border.width: root.hairline
            border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }
    }

    ThemeIcon {
        visible: root.emblem !== ""
        name: root.emblem
        size: Math.max(Tokens.filesListIconSize / 2, Math.min(Tokens.filesEmblemSize, root.size / 2))
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        tint: false
    }
}
