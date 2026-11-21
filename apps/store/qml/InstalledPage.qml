pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Store.js" as Store

// Installed (spec SR23, read only in step 2): the apps installed from the Store's sources, grouped by source, by name. The
// local user's row at the bottom of the sidebar opens it (macOS 27's account page, without an account).
ScrollPage {
    id: root

    property var groups: []

    signal opened(string id)

    // The groups by name, their list kept in step in place (SU-06): a new snapshot changes each group's apps, never the
    // groups' items.
    readonly property var byGroup: {
        const map = {};
        for (const g of root.groups || [])
            map[g.group] = g;
        return map;
    }
    onGroupsChanged: groupKeys.sync((root.groups || []).map(g => g.group))
    Component.onCompleted: groupKeys.sync((root.groups || []).map(g => g.group))

    KeyedModel {
        id: groupKeys
    }

    title: qsTr("Installed")
    Accessible.role: Accessible.Pane
    Accessible.name: root.title

    Repeater {
        model: groupKeys

        delegate: Column {
            id: group
            required property string key
            readonly property var modelData: root.byGroup[group.key] || ({group: group.key, apps: []})
            width: root.contentWidth
            spacing: Tokens.storeShelfTitleGap

            SectionHeading {
                width: parent.width
                text: Store.groupTitle(group.modelData.group)
            }

            AppGrid {
                width: parent.width
                apps: group.modelData.apps
                onOpened: id => root.opened(id)
            }
        }
    }

    Text {
        visible: root.groups.length === 0
        width: root.contentWidth
        topPadding: Tokens.storeEmptyTop
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: qsTr("No apps from the Store's sources are installed.")
        wrapMode: Text.Wrap
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }
}
