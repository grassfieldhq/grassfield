import QtQuick
import QtTest
import "../../shell/notifications/CenterLogic.js" as CenterLogic

// Focus choice after a card leaves the displayed rows and hover counting of the Notifications column (shell/notifications/CenterLogic.js).
TestCase {
    name: "NotificationCenterLogic"

    // Displayed rows from "app:key" words.
    function rows(spec) {
        return spec.split(" ").filter(w => w !== "").map(w => ({appName: w.split(":")[0], key: w.split(":")[1]}));
    }

    // The card `key` was displayed in `before` and is no longer displayed in `after`: where the focus goes (CenterLogic.focusAfterGone,
    // fed the way the list feeds it: the card's group and rank, the old keys, the rows now).
    function gone(before, after, key) {
        const old = rows(before);
        const at = old.findIndex(r => r.key === key);
        let rank = 0;
        for (let i = 0; i < at; i++) {
            if (old[i].appName === old[at].appName)
                rank++;
        }
        return CenterLogic.focusAfterGone({key: key, app: old[at].appName, rank: rank}, old.map(r => r.key), rows(after));
    }

    // Clear of a collapsed group's card: the card revealed into its slot, not another group's.
    function test_collapsedGroupRevealedCardTakesFocus() {
        compare(gone("mail:m1 mail:m2 mail:m3 cal:c1", "mail:m1 mail:m2 mail:m4 cal:c1", "m3"), "m4");
        compare(gone("mail:m1 mail:m2 mail:m4 cal:c1", "mail:m1 mail:m2 mail:m5 cal:c1", "m4"), "m5");
    }

    // Nothing left to reveal: the group's new last card.
    function test_lastCardOfGroupFocusesTheGroupsNewLastCard() {
        compare(gone("mail:m1 mail:m2 mail:m3 cal:c1", "mail:m1 mail:m2 cal:c1", "m3"), "m2");
        compare(gone("mail:m1 mail:m2 mail:m3 cal:c1 chat:h1", "mail:m1 mail:m2 cal:c1 chat:h1", "m3"), "m2");
    }

    // Middle of a group: the card that moved up takes the slot.
    function test_middleCardOfGroupFocusesTheNextOfTheGroup() {
        compare(gone("mail:m1 mail:m2 mail:m3 cal:c1", "mail:m1 mail:m3 cal:c1", "m2"), "m3");
        compare(gone("mail:m1 mail:m2 mail:m3 cal:c1", "mail:m2 mail:m3 cal:c1", "m1"), "m2");
    }

    // A group's only card (or a whole group): the next group's first card, else the previous.
    function test_goneGroupFocusesNextThenPrevious() {
        compare(gone("mail:m1 chat:h1 cal:c1 cal:c2", "mail:m1 cal:c1 cal:c2", "h1"), "c1");
        compare(gone("mail:m1 mail:m2 cal:c1", "mail:m1 mail:m2", "c1"), "m2");
        compare(gone("mail:m1 mail:m2 cal:c1 cal:c2", "cal:c1 cal:c2", "m2"), "c1");
        compare(gone("mail:m1 cal:c1 cal:c2", "mail:m1 cal:c2", "c1"), "c2");
        compare(gone("mail:m1 cal:c1", "mail:m1", "c1"), "m1");
    }

    function test_nothingLeftFocusesNothing() {
        compare(gone("mail:m1", "", "m1"), "");
    }

    // The focused card left the displayed rows by an arrival.
    function test_goneArrivalPushedTheThirdCardOut() {
        // mail m3 m2 m1 collapsed (3 shown), a new mail m4 arrives: m1 is pushed out; the card in its slot (rank 2) is m2
        compare(gone("mail:m3 mail:m2 mail:m1 cal:c1", "mail:m4 mail:m3 mail:m2 cal:c1", "m1"), "m2");
        // the group moved to the top: same rank, not the same absolute slot
        compare(gone("cal:c1 mail:m3 mail:m2 mail:m1", "mail:m4 mail:m3 mail:m2 cal:c1", "m1"), "m2");
    }

    function test_goneShowLessOnTheFifthCardFocusesTheLastDisplayed() {
        const before = "mail:m6 mail:m5 mail:m4 mail:m3 mail:m2 mail:m1 cal:c1";
        const after = "mail:m6 mail:m5 mail:m4 cal:c1";
        compare(gone(before, after, "m2"), "m4");
        compare(gone(before, after, "m1"), "m4");
    }

    // Several changes in one turn: only the settled rows before and the rows now count, nothing is read from in between.
    function test_goneAfterTwoChangesInOneTurn() {
        // two arrivals: the 3rd card is pushed to the 5th place and out; the card in its slot is the 3rd now
        compare(gone("mail:m3 mail:m2 mail:m1 cal:c1", "mail:m5 mail:m4 mail:m3 cal:c1", "m1"), "m3");
        // the focused card and its neighbour closed together: the group's slot is clamped to its last card
        compare(gone("mail:m4 mail:m3 mail:m2 cal:c1", "mail:m4 cal:c1", "m2"), "m4");
        // the focused card's whole group went with an arrival of another app
        compare(gone("mail:m2 mail:m1 cal:c1", "chat:h1 cal:c1", "m2"), "c1");
    }

    // The card was never in the settled rows (focused and removed within one turn): a card that exists, else nothing.
    function test_goneUnknownCardFocusesTheFirstRow() {
        compare(CenterLogic.focusAfterGone({key: "zz", app: "mail", rank: 0}, [], rows("cal:c1 cal:c2")), "c1");
        compare(CenterLogic.focusAfterGone({key: "zz", app: "mail", rank: 0}, [], []), "");
    }

    // The x sticks out of the card: the pointer can enter it before it leaves the card, or after; the group stays hot.
    function test_hoverCountsKeepTheGroupWhileAnyPartIsHovered() {
        let c = {};
        c = CenterLogic.hoverStep(c, "mail", true);   // card
        verify(CenterLogic.isHovered(c, "mail"));
        c = CenterLogic.hoverStep(c, "mail", true);   // x entered first or second: both orders
        c = CenterLogic.hoverStep(c, "mail", false);  // card left
        verify(CenterLogic.isHovered(c, "mail"));
        c = CenterLogic.hoverStep(c, "mail", false);  // x left
        verify(!CenterLogic.isHovered(c, "mail"));
        // An app named like a member of Object.prototype counts like any other.
        ["constructor", "__proto__"].forEach(app => {
            let d = {};
            verify(!CenterLogic.isHovered(d, app));
            d = CenterLogic.hoverStep(d, app, true);
            verify(CenterLogic.isHovered(d, app));
            d = CenterLogic.hoverStep(d, app, false);
            verify(!CenterLogic.isHovered(d, app));
        });
    }

    function test_hoverCountsAreNeverNegativeAndIndependentPerApp() {
        let c = CenterLogic.hoverStep({}, "mail", false);
        compare(c.mail, 0);
        c = CenterLogic.hoverStep(c, "cal", true);
        verify(!CenterLogic.isHovered(c, "mail"));
        verify(CenterLogic.isHovered(c, "cal"));
        const frozen = {mail: 1};
        CenterLogic.hoverStep(frozen, "mail", true);
        compare(frozen.mail, 1);
    }

    // The widget gallery keeps clear of the Dock on every edge (capture defect 1: it covered the left of a bottom Dock).
    readonly property var galleryTokens: ({menubar: 24, inset: 16, insetLeft: 41, width: 360, maxHeight: 720, fraction: 0.62})

    function test_galleryClearsABottomDock() {
        const r = CenterLogic.galleryRect(1920, 1080, galleryTokens, {left: 0, right: 0, bottom: 80});
        compare(r.x, 41);
        compare(r.width, 360);
        verify(r.y + r.height + 80 <= 1080, "the panel ends above the Dock");
        compare(r.y + r.height, 1080 - 16 - 80);
        verify(r.y >= 24, "and stays under the menu bar");
    }

    function test_galleryClearsASideDockAndIgnoresAnAbsentOne() {
        const left = CenterLogic.galleryRect(1920, 1080, galleryTokens, {left: 80, right: 0, bottom: 0});
        compare(left.x, 41 + 80);
        compare(left.y + left.height, 1080 - 16);
        const none = CenterLogic.galleryRect(1920, 1080, galleryTokens, {left: 0, right: 0, bottom: 0});
        compare(none.x, 41);
        compare(none.height, Math.min(720, (1080 - 24) * 0.62));
        const right = CenterLogic.galleryRect(1920, 1080, galleryTokens, {left: 0, right: 80, bottom: 0});
        compare(right.x, 41);
    }

    function test_galleryNeverGoesNegativeOnATinyOutput() {
        const r = CenterLogic.galleryRect(300, 90, galleryTokens, {left: 0, right: 0, bottom: 80});
        compare(r.height, 0);
    }

    // Clear All is the Tab stop before the cards (ADR-0039 step 7; the review of #88: it was checked by grep only).
    function test_clearAllIsTheTabStopBeforeTheCards() {
        compare(CenterLogic.headStep("close", true, true), "head", "Tab from the close disc: Clear All");
        compare(CenterLogic.headStep("panel", true, true), "head", "the first Tab: Clear All");
        compare(CenterLogic.headStep("head", true, true), "firstCard", "Tab from Clear All: the top card");
        compare(CenterLogic.headStep("head", false, true), "close", "Shift+Tab from Clear All: the close disc");
        compare(CenterLogic.headStep("cardsStart", false, true), "head", "Shift+Tab out of the top card: Clear All");
        compare(CenterLogic.headStep("cardsEnd", true, true), "edit", "Tab out of the last card: the edit button");
        // Hidden or disabled (no notification to clear): the order skips it.
        compare(CenterLogic.headStep("close", true, false), "firstCard");
        compare(CenterLogic.headStep("panel", true, false), "firstCard");
        compare(CenterLogic.headStep("cardsStart", false, false), "close");
        compare(CenterLogic.headStep("panel", false, true), "close", "the first Shift+Tab: the last control");
        compare(CenterLogic.headStep("close", false, true), "", "Shift+Tab from the close disc: Qt's own chain");
    }
}
