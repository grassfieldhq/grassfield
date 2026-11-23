import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/search/Actions.js" as Actions
import "../../shell/search/Commands.js" as Commands

// The filter field of the Actions panel (palette P3b review): the first Esc clears the typed words, the second closes. SearchField
// accepts Esc when it clears; the panel's own handler (the one in SearchPanel.qml) closes only an Esc the field left alone and
// empty, whatever the order of the two handlers.
Item {
    id: host

    width: 300
    height: 100

    property int closed: 0

    SearchField {
        id: field
        width: 200
        // The same handler as SearchPanel.qml's filter field.
        Keys.onEscapePressed: event => {
            if (!event.accepted && field.text === "") {
                host.closed++;
                event.accepted = true;
            }
        }
    }

    TestCase {
        name: "SearchActionsField"
        when: windowShown

        readonly property var words: ({open: "Open", run: "Run", copy: "Copy", reveal: "Show in Files"})

        function init() {
            host.closed = 0;
            field.text = "";
            field.forceActiveFocus();
        }

        function test_firstEscClearsSecondCloses() {
            field.text = "abc";
            keyClick(Qt.Key_Escape);
            compare(field.text, "");
            compare(host.closed, 0, "the first Esc only clears");
            keyClick(Qt.Key_Escape);
            compare(host.closed, 1, "the second Esc closes");
        }

        function test_escOnAnEmptyFieldCloses() {
            keyClick(Qt.Key_Escape);
            compare(host.closed, 1);
        }

        // A command entry with more than seven actions (a mock registry) gets the filter field, and the filter narrows it.
        function test_manyActionsGetTheFilter() {
            const acts = [];
            for (let i = 0; i < 8; i++)
                acts.push({id: "act" + i, title: i === 5 ? "Archive" : "Action " + i, run: () => {}});
            const reg = Commands.build([[{id: "mock.many", title: "Many", subtitle: "", keywords: [], kind: "system", actions: acts, run: () => {}}]]);
            const entry = reg.byId["mock.many"];
            const list = Actions.forItem({kind: "command", command: entry.id, actions: entry.actions}, words);
            compare(list.length, 9, "Run and the eight");
            verify(Actions.needsFilter(list));
            compare(Actions.filter(list, "arch").map(a => a.id), ["x:act5"]);
        }
    }
}
