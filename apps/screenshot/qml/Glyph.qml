import QtQuick
import Grassfield.Ui

// Line glyphs of the Screenshot toolbar: the app's own monochrome SVGs (24 x 24 grid, stroke 2, round caps, the style of the
// Grassfield symbolic icons), recoloured by the shared Icon. `kind` is the file name in icons/.
Icon {
    property string kind: "fit"

    name: kind
    directory: Qt.resolvedUrl("icons/")
    size: Tokens.screenshotToolbarIconSize
}
