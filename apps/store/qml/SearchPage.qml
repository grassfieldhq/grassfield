import QtQuick
import Grassfield.Ui

// The search results (spec SR6): local, while typing, best first; "No Results for “…”" when there are none. While the AUR is
// on (SR7), Return also asks the AUR: its results come in their own section, "From the AUR (not reviewed)", with their votes
// and the out-of-date flag; until then a line says Return searches it.
ScrollPage {
    id: root

    property string query: ""
    property var results: []
    // Its query asked of the backend's worker, not answered yet (Main.qml requestSearch): "No Results" waits for the answer.
    property bool searching: false
    property bool aurOn: false
    // "" (not asked for this query), asking, done, or why there is none: offline, short, tooMany, unavailable.
    property string aurState: ""
    property var aurResults: []

    signal opened(string id)

    readonly property bool anyResult: root.results.length > 0 || root.aurResults.length > 0
    title: root.anyResult ? qsTr("Results for “%1”").arg(root.query) : ""
    Accessible.role: Accessible.Pane
    Accessible.name: root.anyResult || root.searching ? root.title : empty.text

    function focusFirst(): void {
        if (root.results.length > 0)
            grid.focusItem(0);
        else if (root.aurResults.length > 0)
            aurGrid.focusItem(0);
    }

    function aurLine(): string {
        switch (root.aurState) {
        case "":
            return qsTr("Press Return to search the AUR too.");
        case "asking":
            return qsTr("Searching the AUR…");
        case "offline":
            return qsTr("The AUR can't be searched while you're offline.");
        case "short":
            return qsTr("Type at least two characters to search the AUR.");
        case "tooMany":
            return qsTr("The AUR has too many results for “%1”: type more of the name.").arg(root.query);
        case "unavailable":
            return qsTr("The AUR could not be searched. Try again later.");
        case "done":
            return root.aurResults.length === 0 ? qsTr("The AUR has nothing for “%1”.").arg(root.query) : "";
        }
        return "";
    }

    AppGrid {
        id: grid
        width: root.contentWidth
        apps: root.results
        onOpened: id => root.opened(id)
    }

    Text {
        id: empty
        visible: !root.anyResult && !root.searching
        width: root.contentWidth
        topPadding: Tokens.storeEmptyTop
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: qsTr("No Results for “%1”").arg(root.query)
        wrapMode: Text.Wrap
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        Accessible.role: Accessible.AlertMessage
        Accessible.name: text
    }

    // The AUR's section (SR7): only while its source is on.
    Column {
        visible: root.aurOn
        width: root.contentWidth
        spacing: Tokens.storeProductLineGap

        SectionHeading {
            visible: root.aurResults.length > 0
            text: qsTr("From the AUR (not reviewed)")
        }

        AppGrid {
            id: aurGrid
            width: parent.width
            apps: root.aurResults
            onOpened: id => root.opened(id)
        }

        Text {
            width: parent.width
            visible: text !== ""
            horizontalAlignment: root.anyResult ? Text.AlignLeft : Text.AlignHCenter
            textFormat: Text.PlainText
            text: root.aurLine()
            wrapMode: Text.Wrap
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.storeBadgeSize
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }
    }
}
