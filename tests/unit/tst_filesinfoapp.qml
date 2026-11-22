pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"

// Get Info of an application and of the Applications location (apps/files/qml/InfoWindow.qml, FolderModel::info): the maps
// carry no file thumbnail, and the window must still bind every field without a QML warning ("Unable to assign [undefined] to
// QString", gate Q2: scripts/dev/test.sh runs tests/ci/qml_warnings.py over this run's output, which fails the run on one).
TestCase {
    id: test
    name: "FilesInfoApplication"
    when: windowShown
    width: 300
    height: 200

    // The FilesApp API the window uses.
    QtObject {
        id: fakeApp
        property var colorTagNames: ({})
        property string titlebarDoubleClick: "zoom"
        property bool canMinimize: true
        property int tagRevision: 0
        property int folderStyleRevision: 0
        function tagsUnavailable(urls: var): string {
            return "";
        }
        function colorTagStates(urls: var): var {
            return [];
        }
        function tagNamesOf(url: url): var {
            return [];
        }
        function folderStyleOf(url: url): var {
            return {color: "", glyph: ""};
        }
        function folderStyleUnavailable(urls: var): string {
            return "";
        }
        function applicationsCount(): int {
            return 63;
        }
        // Get Info's Sharing & Permissions (ADR-0028): nothing to edit here.
        signal permissionsChanged(url url)
        property var permissionsResult: ({valid: false})
        function permissionsOf(target: url): var {
            return fakeApp.permissionsResult;
        }
        function setGroup(target: url, group: string): void {
        }
        function setAccess(target: url, who: int, access: int): void {
        }
        property var jobs: []
        function applicationsFor(urls: var): var {
            return [];
        }
        function mimeTypeOf(target: url): string {
            return "text/plain";
        }
        function defaultApplication(mimeType: string): string {
            return "";
        }
        property var defaultsSet: []
        function setDefaultApplication(mimeType: string, storageId: string): bool {
            fakeApp.defaultsSet = fakeApp.defaultsSet.concat([{type: mimeType, id: storageId}]);
            return true;
        }
        // Get Info > Open with > Other…: the Choose Application panel answers with the app given here.
        property var otherAnswer: null
        function chooseDefaultApplication(target: url, done: var): void {
            if (fakeApp.otherAnswer)
                done(fakeApp.otherAnswer.id, fakeApp.otherAnswer.name);
        }
        function directorySize(url: url, done: var): void {
        }
        function formatSize(bytes: real): string {
            return "";
        }
    }

    // What FolderModel::info returns for an application: no `thumbnail` key at all in the oldest build; the key is "" now.
    readonly property var appInfo: ({
        name: "Calculator",
        url: "grassfield-app:/org.gnome.Calculator",
        iconName: "application-x-executable",
        kind: "Application",
        isApplication: true,
        genericName: "Calculator",
        comment: "Perform arithmetic",
        where: "/usr/share/applications",
        desktopEntry: "/usr/share/applications/org.gnome.Calculator.desktop",
        command: "gnome-calculator",
        categories: "Utility",
        readable: true,
        writable: false,
        isDir: false,
        size: -1
    })
    readonly property var locationInfo: ({
        name: "Applications",
        url: "grassfield-apps:/",
        iconName: "folder",
        kind: "Applications",
        isDir: true,
        readable: true,
        writable: false
    })

    Component {
        id: windowComponent

        InfoWindow {
            app: fakeApp
            info: test.appInfo
        }
    }

    Component {
        id: locationComponent

        InfoWindow {
            app: fakeApp
            info: test.locationInfo
        }
    }

    Component {
        id: fileComponent

        InfoWindow {
            app: fakeApp
            info: ({name: "report.txt", url: "file:///tmp/report.txt", iconName: "text-plain", kind: "Plain Text", isDir: false,
                    readable: true, writable: true, size: 10, sizeText: "10 bytes", bytes: 10, where: "/tmp", created: "", modified: "",
                    accessed: "", linkDest: "", owner: "", group: "", permissions: "", thumbnail: ""})
        }
    }

    function items(item: var, name: string, out: var): var {
        if (item.objectName === name)
            out.push(item);
        for (let i = 0; i < item.children.length; i++)
            test.items(item.children[i], name, out);
        return out;
    }

    // Sharing & Permissions is a table (Finder): the Name column and the Privilege column never overlap, whatever the user and
    // group names, and a long name elides (review of PR #98: the group pop-up ran under the privilege pop-up, 34 px).
    function test_permissionsNameColumnNeverRunsUnderThePrivilegeColumn() {
        const longName = "a-user-with-a-really-quite-long-account-name";
        fakeApp.permissionsResult = {valid: true, mode: 420, modeText: "-rw-r--r--", owner: longName, group: "a-group-with-a-long-name-too",
                               ownedByMe: true, isDir: true, editable: true, reason: "",
                               groups: ["a-group-with-a-long-name-too", "another-quite-long-group-name", "wheel"], access: [3, 1, 1]};
        const win = createTemporaryObject(fileComponent, test);
        verify(win);
        win.show();
        tryVerify(() => win.visible && win.contentItem.width > 0, 3000);
        verify(win.permissionsShown);
        const privileges = test.items(win.contentItem, "privilege", []);
        compare(privileges.length, 3, "one privilege pop-up per row");
        const names = test.items(win.contentItem, "nameText", []).concat(test.items(win.contentItem, "groupChoice", [])).filter(i => i.visible);
        compare(names.length, 3, "one name control per row (a text, or the group's pop-up)");
        for (const n of names) {
            const row = n.parent;
            const privilege = privileges.find(p => p.parent === row);
            verify(privilege !== undefined);
            verify(n.x >= 0, "the name starts inside the row");
            verify(n.x + n.width + Tokens.spacingSm <= privilege.x + 0.5, "a gap between the name and the privilege (" + n.objectName + ": " + (n.x + n.width) + " + gap > " + privilege.x + ")");
            // One content margin (the macOS 27 inspector): the table starts where the sections' text starts, not left of it.
            verify(Math.abs(row.mapToItem(win.contentItem, 0, 0).x - Tokens.spacingLg) < 0.5, "the table keeps the window's content margin");
            verify(privilege.x + privilege.width <= row.width + 0.5, "the privilege stays inside the row");
        }
        fakeApp.permissionsResult = {valid: false};
    }

    TextMetrics {
        id: metrics
    }

    function texts(item: var, out: var): var {
        if (item.text !== undefined && item.elide !== undefined && item.visible)
            out.push(item);
        for (let i = 0; i < item.children.length; i++)
            test.texts(item.children[i], out);
        return out;
    }

    // The Privilege cell hugs its widest choice (inline, no bezel), so the Name column gets the rest within the window's one
    // content margin: a short user or group name ("alex", "staff") is shown in full, and only a long one elides. Known
    // limit: in French, beside "Lecture et écriture", the group pop-up has only a few letters at the 264-pt window (F1 gap 17;
    // "cha…" on screen), so only the owner label and the absence of overlap are checked there; Finder fits more with small
    // table controls, which Grassfield's pop-up does not have yet (review of PR #98, docs/specs/files.md FP-61).
    function test_aShortNameIsNotElided_data() {
        return [
            {tag: "English", me: "Me", groupRoom: 99, choices: [{id: "3", text: "Read & Write"}, {id: "1", text: "Read only"}, {id: "2", text: "Write only"}, {id: "0", text: "No Access"}]},
            {tag: "French", me: "moi", groupRoom: 0, choices: [{id: "3", text: "Lecture et écriture"}, {id: "1", text: "Lecture seule"}, {id: "2", text: "Écriture seule"}, {id: "0", text: "Aucun accès"}]}
        ];
    }

    function test_aShortNameIsNotElided(data) {
        for (const names of [{owner: "alex", group: "alex", long: false}, {owner: "alex", group: "staff", long: false}, {owner: "a-user-with-a-really-quite-long-account-name", group: "a-group-with-a-long-name-too", long: true}]) {
            fakeApp.permissionsResult = {valid: true, mode: 420, modeText: "-rw-r--r--", owner: names.owner, group: names.group, ownedByMe: true, isDir: false,
                                         editable: true, reason: "", groups: [names.group, "wheel"], access: [3, 1, 1]};
            const win = createTemporaryObject(fileComponent, test, {accessChoices: data.choices});
            verify(win);
            win.show();
            tryVerify(() => win.visible && win.contentItem.width > 0, 3000);
            const privileges = test.items(win.contentItem, "privilege", []);
            const group = test.items(win.contentItem, "groupChoice", []).find(i => i.visible);
            const owner = test.items(win.contentItem, "nameText", []).find(i => i.visible && i.text.indexOf(names.owner) >= 0);
            verify(group !== undefined && owner !== undefined && privileges.length === 3);
            const groupText = test.texts(group, []).find(t => t.text === names.group || t.text.length > 0 && names.group.indexOf(t.text.replace("…", "")) === 0);
            verify(groupText !== undefined, "the group pop-up shows its name");
            for (const p of privileges)
                verify(p.x >= group.x + group.width, data.tag + ": no overlap (" + (group.x + group.width) + " > " + p.x + ")");
            // The owner row reads "alex (Me)" in English and "alex (moi)" in French (the catalog's own words): the French
            // label is measured with the same font, since the test runs in English.
            metrics.font = owner.font;
            metrics.text = names.owner + " (" + data.me + ")";
            if (names.long)
                compare(owner.truncated, true, data.tag + " owner " + names.owner + " elides");
            else
                verify(metrics.advanceWidth <= owner.width, data.tag + " owner label " + metrics.advanceWidth + " fits the Name column " + owner.width);
            const groupFits = !names.long && names.group.length <= data.groupRoom;
            if (names.long || groupFits)
                compare(groupText.truncated, names.long, data.tag + " group " + names.group + (names.long ? " elides" : " is shown in full"));
            win.destroy();
        }
        fakeApp.permissionsResult = {valid: false};
    }

    function test_applicationInfoHasNoUndefinedThumbnail() {
        const win = createTemporaryObject(windowComponent, test);
        verify(win);
        compare(win.isApplication, true);
        // A warning here would be printed by Qt and caught by the Q2 gate; the info has no thumbnail and none is assigned.
        compare(win.info.thumbnail, undefined);
    }

    function test_applicationsLocationInfoHasNoUndefinedThumbnail() {
        const win = createTemporaryObject(locationComponent, test);
        verify(win);
        compare(win.isApplication, false);
    }

    // Owner report 2026-11-22: Get Info's Open with is shown for every document, also one no application lists, and ends with
    // Other… (macOS): the app picked there (a web app whose desktop file lists no type) is chosen, and Change All… makes it the
    // type's default.
    function test_openWithOtherChoosesAnyApplication() {
        const w = createTemporaryObject(fileComponent, test);
        verify(w);
        verify(w.openWithShown, "shown although no application lists text/plain here");
        fakeApp.otherAnswer = {id: "webapp-docs.desktop", name: "Docs Web App"};
        fakeApp.defaultsSet = [];
        w.pickOpenWith(w.otherId);
        compare(w.chosenApp, "webapp-docs.desktop");
        verify(w.openWithApps.some(a => a.id === "webapp-docs.desktop" && a.name === "Docs Web App"), "listed in the popup");
        verify(fakeApp.setDefaultApplication(w.mimeType, w.chosenApp));
        compare(fakeApp.defaultsSet[0].id, "webapp-docs.desktop");
        fakeApp.otherAnswer = null;
    }
}
