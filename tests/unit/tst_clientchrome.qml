import QtQuick
import QtTest
import "../../shell/overview/ClientChrome.js" as ClientChrome
import "../../shell/platform/CapabilitiesFile.js" as CapabilitiesFile

// ADR-0015, shell side: the Overview band above a window that draws its own chrome (H1), and the capabilities file the
// shell writes for the apps (Q4b).
TestCase {
    name: "ClientChrome"

    // H1 ---------------------------------------------------------------------------------------------------------------

    function test_tagNameIsTheOneOfTheSessionRuleAndTheSpec() {
        compare(ClientChrome.TAG, "grassfield-client-chrome");
        compare(ClientChrome.FEATURE, "client-chrome");
    }

    function test_hyprlandPrintsRuleTagsWithAStar() {
        verify(ClientChrome.hasClientChrome(["grassfield-client-chrome*"]));
        verify(ClientChrome.hasClientChrome(["other", "grassfield-client-chrome"]));
        verify(!ClientChrome.hasClientChrome(["grassfield-client-chrome-x*"]));
        verify(!ClientChrome.hasClientChrome([]));
        verify(!ClientChrome.hasClientChrome(undefined));
        verify(!ClientChrome.hasClientChrome("grassfield-client-chrome"));
        verify(!ClientChrome.hasClientChrome([5, null]));
    }

    function test_bandIsZeroOnlyWhenTheWindowDrawsItsOwnChromeAndThePluginStepsAside() {
        const own = {tags: ["grassfield-client-chrome*"]};
        const other = {tags: []};
        compare(ClientChrome.band(own, true, 32), 0);
        compare(ClientChrome.band(other, true, 32), 32);
        // The plugin does not advertise the feature (older plugin, no plugin): it still draws its strip, the band stays.
        compare(ClientChrome.band(own, false, 32), 32);
        compare(ClientChrome.band(null, true, 32), 32);
        compare(ClientChrome.band({}, true, 32), 32);
    }

    // Tiling step 6e (ADR-0036 D73): a Split View window whose titlebar the plugin keeps away has no band either.
    function test_noBandAboveAWindowWhoseTitlebarIsAway() {
        const own = {tags: ["grassfield-client-chrome*"]};
        const other = {tags: []};
        compare(ClientChrome.band(other, true, 32, true), 0);
        compare(ClientChrome.band(other, false, 32, true), 0, "whatever the client-chrome feature says");
        compare(ClientChrome.band(own, false, 32, true), 0);
        compare(ClientChrome.band(other, true, 32, false), 32);
        compare(ClientChrome.band(other, true, 32, 1), 32, "only true counts");
        compare(ClientChrome.band(own, true, 32, false), 0, "client chrome as before");
    }

    // Q4b --------------------------------------------------------------------------------------------------------------

    function test_capabilitiesFileLocation() {
        compare(CapabilitiesFile.path("/dev/state", "/run/user/1000"), "/dev/state/capabilities.json");
        compare(CapabilitiesFile.path("", "/run/user/1000"), "/run/user/1000/grassfield/capabilities.json");
        compare(CapabilitiesFile.path(undefined, "/run/user/1000"), "/run/user/1000/grassfield/capabilities.json");
        compare(CapabilitiesFile.path("", ""), "");
        // Grassfield's own runtime folder, made private by the shell before its first write; none in a dev session.
        compare(CapabilitiesFile.runtimeFolder("", "/run/user/1000"), "/run/user/1000/grassfield");
        compare(CapabilitiesFile.runtimeFolder("/dev/state", "/run/user/1000"), "");
        compare(CapabilitiesFile.runtimeFolder("", ""), "");
    }

    function test_capabilitiesPayload() {
        const present = JSON.parse(CapabilitiesFile.payload(true, ["decorations", "minimize", 7]));
        compare(present.v, 1);
        compare(present.pluginPresent, true);
        compare(present.features.join(","), "decorations,minimize");
        const absent = JSON.parse(CapabilitiesFile.payload(false, ["minimize"]));
        compare(absent.pluginPresent, false);
        compare(absent.features.length, 0, "an absent plugin offers nothing");
        compare(JSON.parse(CapabilitiesFile.payload(true, undefined)).features.length, 0);
        verify(CapabilitiesFile.payload(true, []).endsWith("\n"));
    }
}
