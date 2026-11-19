pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Date & Time > Set… (macOS: a sheet with the date and the time as stepper fields, shown while the automatic time is off).
// The fields hold the time zone's wall clock; Set hands it back (`chosen`) and the page sends it to timedate1 through polkit
// (ADR-0030). Cancel and Escape change nothing.
Sheet {
    id: root

    // The day, month and year, the hour, minute and second being edited.
    property var fields: [1, 1, 2026, 0, 0, 0]
    // When the sheet opened (Date.now()), and whether the hour, minute or second was changed since. A time left as it was
    // goes on running while the sheet is up: Set then means "this date, the clock as it runs", not the time of the opening
    // (the clock was set back by the time spent in the sheet). A time the user typed is taken as typed.
    property real openedAt: 0
    property bool timeTouched: false

    signal chosen(var wall)

    title: qsTr("Set the date and time")
    confirmText: qsTr("Set")

    function openAt(wall: var): void {
        root.fields = [wall.getDate(), wall.getMonth() + 1, wall.getFullYear(), wall.getHours(), wall.getMinutes(), wall.getSeconds()];
        root.openedAt = Date.now();
        root.timeTouched = false;
        root.open();
    }

    function daysIn(month: int, year: int): int {
        return new Date(year, month, 0).getDate();
    }

    function setField(i: int, v: int): void {
        const f = root.fields.slice();
        f[i] = v;
        if (i >= 3)
            root.timeTouched = true;
        // A day the new month does not have becomes its last.
        f[0] = Math.min(f[0], root.daysIn(f[1], f[2]));
        root.fields = f;
    }

    onAccepted: {
        const f = root.fields;
        const set = new Date(f[2], f[1] - 1, f[0], f[3], f[4], f[5]);
        root.chosen(root.timeTouched || root.openedAt <= 0 ? set : new Date(set.getTime() + Math.max(0, Date.now() - root.openedAt)));
    }

    // Built the first time the sheet opens, and kept (Sheet.bodyComponent).
    bodyComponent: Component {
        Column {
            spacing: Tokens.spacingMd

            SettingsGroup {
                SettingsRow {
                    title: qsTr("Date")
                    SpinBox {
                        accessibleName: qsTr("Day")
                        from: 1
                        to: root.daysIn(root.fields[1], root.fields[2])
                        value: root.fields[0]
                        onValueModified: root.setField(0, value)
                    }
                    SpinBox {
                        accessibleName: qsTr("Month")
                        from: 1
                        to: 12
                        value: root.fields[1]
                        onValueModified: root.setField(1, value)
                    }
                    SpinBox {
                        accessibleName: qsTr("Year")
                        from: 2000
                        to: 2199
                        value: root.fields[2]
                        textFromValue: (v, locale) => String(v)
                        onValueModified: root.setField(2, value)
                    }
                }
                SettingsRow {
                    title: qsTr("Time")
                    SpinBox {
                        accessibleName: qsTr("Hour")
                        from: 0
                        to: 23
                        value: root.fields[3]
                        onValueModified: root.setField(3, value)
                    }
                    SpinBox {
                        accessibleName: qsTr("Minute")
                        from: 0
                        to: 59
                        value: root.fields[4]
                        textFromValue: (v, locale) => String(v).padStart(2, "0")
                        onValueModified: root.setField(4, value)
                    }
                    SpinBox {
                        accessibleName: qsTr("Second")
                        from: 0
                        to: 59
                        value: root.fields[5]
                        textFromValue: (v, locale) => String(v).padStart(2, "0")
                        onValueModified: root.setField(5, value)
                    }
                }
            }
        }
    }
}
