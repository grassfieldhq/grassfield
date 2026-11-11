import QtQuick
import QtTest

// Mutual exclusion of Overview, Apps and Search (shell/overlay/ExclusiveSurfaces.qml): opening one closes the
// others, so the keyboard always belongs to the visible top surface.
TestCase {
    id: testCase
    name: "ExclusiveSurfaces"

    component Fake: QtObject {
        property bool open: false
        property int closes: 0
        function dismiss(): void {
            closes++;
            open = false;
        }
    }

    property var coordinator: null

    Fake {
        id: overview
    }

    Fake {
        id: apps
    }

    Fake {
        id: search
    }

    function init() {
        for (const f of [overview, apps, search]) {
            f.open = false;
            f.closes = 0;
        }
        const c = Qt.createComponent(Qt.resolvedUrl("../../shell/overlay/ExclusiveSurfaces.qml"));
        compare(c.status, Component.Ready, c.errorString());
        coordinator = c.createObject(testCase, {surfaces: [
                {target: overview, close: () => overview.dismiss()},
                {target: apps, close: () => apps.dismiss()},
                {target: search, close: () => search.dismiss()}
            ]});
        verify(coordinator !== null);
    }

    function cleanup() {
        coordinator.destroy();
    }

    function test_openingOverviewClosesApps() {
        apps.open = true;
        overview.open = true;
        verify(overview.open);
        verify(!apps.open);
        compare(apps.closes, 1);
    }

    function test_openingAppsClosesOverviewAndSearch() {
        overview.open = true;
        apps.open = true;
        verify(apps.open);
        verify(!overview.open);
        search.open = true;
        verify(search.open);
        verify(!apps.open);
        overview.open = true;
        verify(overview.open);
        verify(!search.open);
    }

    function test_closingASurfaceClosesNothingElse() {
        apps.open = true;
        apps.open = false;
        compare(overview.closes, 0);
        compare(search.closes, 0);
        compare(apps.closes, 0);
    }

    function test_onlyOneSurfaceIsOpenAfterAnySequence() {
        const all = [overview, apps, search];
        for (let i = 0; i < 12; i++) {
            all[(i * 7) % 3].open = true;
            compare(all.filter(f => f.open).length, 1);
        }
    }

    // A surface built late can appear already open (an early request performed on its arrival, shell.qml): it closes the others.
    function test_aTargetThatAppearsOpenClosesTheOthers() {
        coordinator.surfaces = [
            {target: null, close: () => overview.dismiss()},
            {target: apps, close: () => apps.dismiss()},
            {target: search, close: () => search.dismiss()}
        ];
        overview.open = true;
        apps.open = true;
        verify(apps.open);
        verify(!search.open);
        coordinator.surfaces = [
            {target: overview, close: () => overview.dismiss()},
            {target: apps, close: () => apps.dismiss()},
            {target: search, close: () => search.dismiss()}
        ];
        verify(overview.open !== apps.open);
        verify(!search.open);
    }
}
