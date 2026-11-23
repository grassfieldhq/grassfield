import QtQuick
import QtTest
import Grassfield.Ui

// The capture suite's schema keys (ADR-0066 D-11, slice B18): each key's default, enum and description in the schema, and the
// generated contract (ui/Grassfield/Ui/SettingsContract.js) that every reader shares.
TestCase {
    name: "CaptureSettings"

    // key -> [type, default, enum or null]
    readonly property var keys: ({
            "showThumbnail": ["boolean", true, null],
            "thumbnailSeconds": ["integer", 5, null],
            "thumbnailSide": ["string", "right", ["right", "left"]],
            "freeze": ["boolean", false, null],
            "hideDesktopIcons": ["boolean", false, null],
            "systemAudio": ["boolean", false, null],
            "recordDnd": ["boolean", false, null],
            "historyRetention": ["string", "week", ["day", "week", "month"]],
            "format": ["string", "png", ["png", "jpeg", "webp"]],
            "standardResolution": ["boolean", false, null],
            "fps": ["integer", 60, [30, 60]]
        })

    function schemaProperties() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/schema/grassfield.schema.json"), false);
        xhr.send();
        return JSON.parse(xhr.responseText).properties.capture.properties;
    }

    function test_defaultsAndEnums() {
        const props = schemaProperties();
        for (const key in keys) {
            const [type, def, values] = keys[key];
            const leaf = props[key];
            verify(leaf !== undefined, key + " is in the schema");
            compare(leaf.type, type, key);
            compare(leaf.default, def, key + " default");
            if (values)
                compare(leaf.enum, values, key + " enum");
            compare(SettingsContract.DEFAULTS["capture." + key], def, key + " contract default");
            compare(SettingsContract.validate("capture." + key, def), "", key + " default satisfies its rule");
        }
    }

    function test_everyNewKeyIsDescribed() {
        const props = schemaProperties();
        for (const key in keys) {
            const text = props[key].description;
            verify(typeof text === "string" && text.length >= 40, key + " has a real description");
            verify(text.indexOf("TODO") < 0, key + " description is final");
        }
    }

    function test_rangesAndWrongValues() {
        const props = schemaProperties();
        compare(props.thumbnailSeconds.minimum, 2);
        compare(props.thumbnailSeconds.maximum, 30);
        verify(SettingsContract.validate("capture.thumbnailSeconds", 1) !== "");
        verify(SettingsContract.validate("capture.thumbnailSeconds", 31) !== "");
        verify(SettingsContract.validate("capture.thumbnailSeconds", 2.5) !== "", "an integer only");
        verify(SettingsContract.validate("capture.fps", 45) !== "");
        verify(SettingsContract.validate("capture.format", "heic") !== "", "no HEIC (spec C15)");
        verify(SettingsContract.validate("capture.thumbnailSide", "top") !== "");
        verify(SettingsContract.validate("capture.historyRetention", "forever") !== "");
        verify(SettingsContract.validate("capture.freeze", "yes") !== "");
    }

    // The privacy-relevant defaults ADR-0066 states: nothing records the system audio or holds the desktop unless asked.
    function test_privateDefaults() {
        compare(SettingsContract.DEFAULTS["capture.systemAudio"], false);
        compare(SettingsContract.DEFAULTS["capture.recordDnd"], false);
        compare(SettingsContract.DEFAULTS["capture.freeze"], false);
        compare(SettingsContract.DEFAULTS["capture.historyRetention"], "week");
    }
}
