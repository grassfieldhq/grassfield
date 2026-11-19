pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Storage > All Volumes… (macOS: a sheet listing every volume with its size and what is free). Read-only, from QStorageInfo
// (Backend.volumes: the mounted volumes with a real file system, the start-up volume first). Done closes it.
Sheet {
    id: root

    required property var backend

    property var volumes: []

    title: qsTr("All Volumes")
    confirmText: qsTr("Done")
    showCancel: false

    onShownChanged: {
        if (root.shown)
            root.volumes = root.backend.volumes();
    }

    // Decimal units, as macOS shows disks.
    function sizeText(bytes: real): string {
        return Qt.locale().formattedDataSize(bytes, 2, Locale.DataSizeSIFormat);
    }

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            SettingsGroup {
                Repeater {
                    model: root.volumes

                    SettingsRow {
                        required property var modelData
                        title: modelData.isRoot ? qsTr("Startup Disk") : (modelData.name !== "" ? modelData.name : modelData.root)
                        // The mount point, the device and the file system ("/home · /dev/nvme0n1p3 · btrfs"); read-only when it is.
                        subtitle: [modelData.root, modelData.device, modelData.type].concat(modelData.readOnly ? [qsTr("read-only")] : []).join(" · ")
                        glyph: "drive"
                        valueText: qsTr("%1 available of %2").arg(root.sizeText(modelData.available)).arg(root.sizeText(modelData.total))
                    }
                }
            }
        }
    }
}
