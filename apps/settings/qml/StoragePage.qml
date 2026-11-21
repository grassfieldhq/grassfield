pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "General.js" as General

// General > Storage (the structure of the macOS 15 capture, docs/audits/settings-parity-2026-10-26.md § Storage): the start-up
// volume ("X of Y used", a bar of what uses it, a legend, All Volumes…), then one row per category with its size. Read-only:
// the volume from QStorageInfo, the installed packages from `pacman -Qi`, the user's folders from `du` (both read-only queries
// of systemguard.cpp, in the background for up to settings.storageCountMs); "Other" is the rest of what is used.
// Not built (docs/specs/settings.md): Recommendations, the per-category detail sheets.
SettingsPage {
    id: root

    required property var backend

    // All Volumes…: Main.qml opens VolumesSheet.
    signal allVolumesRequested

    title: qsTr("Storage")

    readonly property var volume: root.backend ? General.startupVolume(root.backend.volumes()) : null
    property var folderBytes: ({})
    property real packageBytes: 0
    // The counts still running (du, pacman).
    property int counting: 2

    readonly property var categories: root.backend ? General.categories(root.volume, root.folderBytes, root.packageBytes, root.backend.homeDir)
        .filter(c => c.bytes > 0) : []

    // Decimal units, as macOS shows disks ("210.39 GB").
    function sizeText(bytes: real): string {
        return Qt.locale().formattedDataSize(bytes, 2, Locale.DataSizeSIFormat);
    }

    function label(id: string): string {
        switch (id) {
        case "applications":
            return qsTr("Installed Software");
        case "documents":
            return qsTr("Documents");
        case "downloads":
            return qsTr("Downloads");
        case "desktop":
            return qsTr("Desktop");
        case "pictures":
            return qsTr("Pictures");
        case "music":
            return qsTr("Music");
        case "videos":
            return qsTr("Videos");
        case "trash":
            return qsTr("Trash");
        }
        return qsTr("Other");
    }

    function glyph(id: string): string {
        return ({applications: "apps", documents: "document", downloads: "download", desktop: "display", pictures: "wallpaper",
                music: "now-playing", videos: "media-play", trash: "trash"})[id] || "drive";
    }

    // The category's colour, the same in the bar, the legend and the row's tile (the vivid color.tile
    // colours, the bottom of each gradient; no yellow: a white glyph sits on them).
    function tile(id: string): string {
        return ({applications: "orange", documents: "blue", downloads: "green", desktop: "blue", pictures: "pink", music: "red",
                videos: "purple"})[id] || "graphite";
    }

    // "used": what is used while the counts run.
    function tileColor(id: string): color {
        return id === "used" ? Appearance.withAlpha(Appearance.colors.text, 2 * Tokens.settingsStorageFreeOpacity) : Tokens.colorTile[root.tile(id)];
    }

    // Shared: the page shown again while the counts run gets their answers instead of starting them again (Backend.query).
    Component.onCompleted: {
        root.backend.query(General.duArgv(root.backend.homeDir), "storage.du", Tokens.settingsStorageCountMs, true);
        // The Backend adds the sizes up itself (installedSize: the page gets a number, not pacman's megabyte of text); a
        // backend without it (a test's) answers pacman's text.
        if (typeof root.backend.installedSize === "function")
            root.backend.installedSize("storage.packages", Tokens.settingsStorageCountMs);
        else
            root.backend.query(["pacman", "-Qi"], "storage.packages", Tokens.settingsStorageCountMs, true);
    }

    Connections {
        target: root.backend

        // du exits non-zero when it cannot read a folder of the home: what it counted still holds.
        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "storage.du") {
                root.folderBytes = General.parseDu(output);
                root.counting--;
            } else if (tag === "storage.packages") {
                root.packageBytes = General.packagesBytes(output);
                root.counting--;
            }
        }
    }

    SettingsGroup {
        visible: root.volume !== null

        Item {
            id: card
            width: parent.width
            // A legend of many categories wraps: the card grows by its extra lines.
            height: Math.max(Tokens.settingsStorageCardHeight, Math.ceil(legend.y + legend.height + Tokens.settingsStorageCardHeight
                - Tokens.settingsStorageLegendBaseline - legendMetrics.descent))
            readonly property real used: root.volume ? Math.max(0, root.volume.total - root.volume.available) : 0
            // While the counts run, one segment for what is used (macOS: "Calculating…").
            readonly property var parts: root.counting > 0 ? [{id: "used", bytes: card.used}] : root.categories
            readonly property var widths: General.barWidths(card.parts.map(p => p.bytes).concat([root.volume ? root.volume.available : 0]),
                bar.width, Tokens.settingsStorageSegmentGap, Tokens.settingsStorageSegmentMin)

            Accessible.role: Accessible.StaticText
            Accessible.name: name.text + ", " + usedText.text

            Text {
                id: name
                textFormat: Text.PlainText
                x: Tokens.settingsRowInset
                y: Tokens.settingsStorageNameBaseline - baselineOffset
                width: Math.min(implicitWidth, usedText.x - x - Tokens.spacingLg)
                elide: Text.ElideRight
                text: root.volume && root.volume.name !== "" ? root.volume.name : qsTr("Startup Disk")
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
            Text {
                id: usedText
                textFormat: Text.PlainText
                x: allVolumes.x - Tokens.spacingSm - width
                y: Tokens.settingsStorageNameBaseline - baselineOffset
                text: qsTr("%1 of %2 used").arg(root.sizeText(card.used)).arg(root.sizeText(root.volume ? root.volume.total : 0))
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
            Button {
                id: allVolumes
                x: parent.width - Tokens.settingsRowInset - width
                y: Tokens.settingsStorageButtonTop
                push: true
                text: qsTr("All Volumes…")
                onClicked: root.allVolumesRequested()
            }

            // The bar: the categories, then the free space with its size.
            Rectangle {
                id: bar
                x: Tokens.settingsRowInset
                y: Tokens.settingsStorageBarTop
                width: parent.width - 2 * Tokens.settingsRowInset
                height: Tokens.settingsStorageBarHeight
                radius: Tokens.settingsStorageBarRadius
                // The gaps between the segments.
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                clip: true
                layer.enabled: true

                Row {
                    spacing: Tokens.settingsStorageSegmentGap

                    Repeater {
                        model: card.parts

                        Rectangle {
                            required property var modelData
                            required property int index
                            width: card.widths[index] ?? 0
                            height: bar.height
                            color: root.tileColor(modelData.id)
                        }
                    }
                    Rectangle {
                        id: free
                        width: card.widths[card.parts.length] ?? 0
                        height: bar.height
                        color: Qt.tint(Appearance.colors.groupFill, Appearance.withAlpha(Appearance.colors.text, Tokens.settingsStorageFreeOpacity))

                        Text {
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            visible: implicitWidth + 2 * Tokens.spacingSm <= parent.width
                            text: root.sizeText(root.volume ? root.volume.available : 0)
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyCaptionSize
                        }
                    }
                }
            }

            // The legend: a dot and a name per category in the bar.
            Flow {
                id: legend
                x: Tokens.settingsRowInset
                y: Tokens.settingsStorageLegendBaseline - legendMetrics.ascent
                width: bar.width
                spacing: Tokens.settingsStorageLegendItemGap

                FontMetrics {
                    id: legendMetrics
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.settingsStorageLegendSize
                }

                Text {
                    textFormat: Text.PlainText
                    visible: root.counting > 0
                    text: qsTr("Calculating…")
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.settingsStorageLegendSize
                }
                Repeater {
                    model: root.counting > 0 ? [] : root.categories

                    Row {
                        id: entry
                        required property var modelData
                        spacing: Tokens.settingsStorageLegendDotGap

                        Rectangle {
                            y: Math.round((legendLabel.height - height) / 2)
                            width: Tokens.settingsStorageLegendDot
                            height: width
                            radius: width / 2
                            color: root.tileColor(entry.modelData.id)
                        }
                        Text {
                            id: legendLabel
                            textFormat: Text.PlainText
                            text: root.label(entry.modelData.id)
                            color: Appearance.windowSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.settingsStorageLegendSize
                        }
                    }
                }
            }
        }
    }

    // One row per category, largest first ("Other" last).
    SettingsGroup {
        visible: root.volume !== null && root.counting === 0

        Repeater {
            model: root.categories

            SettingsRow {
                required property var modelData
                title: root.label(modelData.id)
                glyph: root.glyph(modelData.id)
                tileColor: root.tile(modelData.id)
                valueText: root.sizeText(modelData.bytes)
            }
        }
    }
}
