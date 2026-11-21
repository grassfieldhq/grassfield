import QtQuick
import QtQuick.Controls
import QtTest
import Grassfield.Ui as Ui

// Run by tests/shell/controls_style.sh with QT_QUICK_CONTROLS_STYLE=Grassfield: the stock Controls resolve to the Grassfield
// style (ui/Grassfield), i.e. to Grassfield.Ui controls, which carry properties the stock ones do not have.
TestCase {
    name: "ControlsStyle"
    width: 300
    height: 200
    visible: true
    when: windowShown

    Column {
        Button {
            id: button
            text: "Go"
        }

        ToolButton {
            id: tool
        }

        ComboBox {
            id: combo
        }

        CheckBox {
            id: check
        }

        TextField {
            id: field
        }

        Slider {
            id: slider
        }
    }

    // Untyped view of a control: the stock type has no such property, the lint must not know it.
    function dyn(item: var): var {
        return item;
    }

    function test_stockControlsAreGrassfields() {
        verify(dyn(button).primary !== undefined, "Button is Ui.Button (has `primary`)");
        verify(dyn(tool).radio !== undefined, "ToolButton is Ui.ToolButton");
        verify(dyn(combo).accessibleName !== undefined, "ComboBox is Ui.ComboBox");
        verify(dyn(check).accessibleName !== undefined, "CheckBox is Ui.CheckBox");
        verify(dyn(field).accessibleName !== undefined, "TextField is Ui.TextField");
        compare(button.height, Ui.Tokens.controlButtonHeight, "Ui.Button default height (the push button token, 24 since the UI audit of 2026-11-05)");
    }

    function test_uncoveredControlsFallBack() {
        verify(slider.value !== undefined, "Slider falls back to the fallback style and still works");
        verify(dyn(slider).primary === undefined);
    }
}
