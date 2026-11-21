pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../apps/files/qml"

// grassfield-files inline rename field (apps/files/qml/RenameField.qml, audit F15): a name is committed only on an explicit
// action (Return, Tab, a click elsewhere: the keyboard going to another item of the active window); a field taken out of the
// window (its row scrolled out of the view) cancels instead of committing a half-typed name.
TestCase {
    id: test
    name: "FilesRename"
    when: windowShown
    visible: true
    width: 400
    height: 200

    property var committed: []
    property int canceled: 0

    Item {
        id: host
        width: 300
        height: 40
    }

    // Something else in the window that takes the keyboard (a click elsewhere gives it to the view).
    Rectangle {
        id: elsewhere
        y: 100
        width: 100
        height: 40
        focus: false
        activeFocusOnTab: true
    }

    Component {
        id: fieldComponent
        RenameField {
            width: 200
            originalName: "report.txt"
            baseLength: 6
            onCommitted: name => test.committed = test.committed.concat([name])
            onCanceled: test.canceled++
        }
    }

    function init(): void {
        test.committed = [];
        test.canceled = 0;
    }

    function makeField(): Item {
        const field = createTemporaryObject(fieldComponent, host);
        verify(field !== null);
        tryVerify(() => field.activeFocus || field.children[0].activeFocus);
        return field;
    }

    function test_returnCommits(): void {
        makeField();
        keyClick(Qt.Key_N);
        keyClick(Qt.Key_Return);
        compare(test.committed, ["n.txt"]);
        compare(test.canceled, 0);
    }

    function test_escapeCancels(): void {
        makeField();
        keyClick(Qt.Key_N);
        keyClick(Qt.Key_Escape);
        compare(test.committed, []);
        compare(test.canceled, 1);
    }

    function test_aClickElsewhereCommits(): void {
        makeField();
        keyClick(Qt.Key_N);
        elsewhere.forceActiveFocus();
        tryCompare(test, "committed", ["n.txt"], 1000, "the keyboard went to another item of the window");
    }

    function test_aFieldTakenOutOfTheWindowCancels(): void {
        const field = makeField();
        keyClick(Qt.Key_N);
        // What a view does with a row scrolled out of its cache: the delegate leaves the window.
        field.parent = null;
        tryCompare(test, "canceled", 1, 1000);
        compare(test.committed, [], "a half-typed name is never committed");
    }
}
