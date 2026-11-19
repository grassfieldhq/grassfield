pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Grassfield.Ui

// The banner stack, everything inside the banner window (Banners.qml): a single view, so there is exactly one set of banner
// delegates (hover state and expiry belong to the one visible banner). Banners exist only for the rows that are shown (the
// rest of the queue is just model rows with an empty slot). While the OSD pill is visible the stack sits below it, so the
// two never overlap.
// Nothing pops (UI audit 2026-11-05 U1): the view is not a ListView over the notification model. `rows` mirrors the model
// (see sync) and keeps a banner that left it, flagged `gone`, until its own exit has finished; only then is the row removed,
// at a slot height of 0. A Column stacks the slots, so the heights are the only thing that moves anything: a leaving banner
// slides out to the right while it fades (a swiped banner carries on from where the drag left it) and its slot closes, so
// the banners below rise with it; a new banner's slot opens the same way, so the ones below glide down. No view drops a
// delegate and re-lays out afterwards (the ListView did, one or two frames after the exit: the stack jumped). Under Reduce
// Motion nothing moves: the leaving banner fades where it stands and the gap closes at once, the others jump (ADR-0039
// step 5). The model itself drops a banner at once (timers, hover holds and keys stay exactly as before).
// A banner pushed back into the queue by a newer one leaves the same way before its slot empties (audit B-11).
// The window (a layer surface) is Banners.qml; this item runs in a plain window as well (tests/shell/banner_stack, offscreen).
Item {
    id: win

    // The width of the output the window is anchored on (the stack's backdrop rect is in output coordinates).
    property real screenWidth: 0
    // Space taken by the OSD pill (plus its gap) while it is on this screen.
    property real osdOffset: 0
    readonly property int pad: Tokens.spacingLg
    // The close button stands out of the card's top-left corner by a third of its size, on whole device pixels (LOW,
    // UI audit 2026-11-05); the input region takes it in.
    readonly property real closeOverhang: Math.round(Tokens.notificationCloseSize / 3 * stack.dpr) / stack.dpr
    // Rows in the stack (shown, queued and leaving): the window is mapped while there is one.
    readonly property int rowCount: rows.count
    // The window's input region (Banners.qml's mask).
    readonly property Item inputItem: inputArea
    // The stack at rest: where the glass of every banner is judged (audit B-02).
    readonly property real restHeight: stack.restHeight
    // The rows and the column of slots (for tests: tests/shell/banner_stack).
    readonly property ListModel rowModel: rows
    readonly property Item column: stack
    // The slots whose card is drawn now, leaving ones included: each has a blur region until its delegate is gone.
    // A Region that follows an Item only hears the item's own geometry: a card carried by its slot in the Column moved
    // without a word, and a region made in the frame a gap closed (Reduce Motion: the exit's end) stayed at the old place,
    // a faint band under the stack. The regions are therefore explicit rects (slot.blurX...), built from the properties
    // that do change: the stack's and the slot's place and the card's offset.
    property var cards: []
    // Ids for the rows below.
    property int nextUid: 1
    readonly property var fields: ["nid", "appName", "appIcon", "image", "summary", "bodyHtml", "time", "urgency", "actionsJson"]

    // Brings `rows` in line with the model. Rows that left it start their exit (an empty queued slot just goes); rows that
    // are new are inserted in the model's order; the others take the model's new field values (an update in place).
    function sync(): void {
        const src = Notifications.bannerModel;
        const keys = [];
        const inModel = Object.create(null);
        for (let i = 0; i < src.count; i++) {
            const k = src.get(i).key;
            keys.push(k);
            inModel[k] = true;
        }
        // At most notificationBannerMaxVisible banners play an exit at once; past that (a flood) a banner leaves at once.
        let leaving = 0;
        for (let i = 0; i < rows.count; i++) {
            if (rows.get(i).gone || rows.get(i).demoting)
                leaving++;
        }
        for (let i = rows.count - 1; i >= 0; i--) {
            const r = rows.get(i);
            if (r.gone || inModel[r.key] === true)
                continue;
            if ((r.queued && !r.demoting) || (!r.demoting && leaving >= Tokens.notificationBannerMaxVisible)) {
                rows.remove(i);
            } else {
                if (!r.demoting)
                    leaving++;
                rows.setProperty(i, "gone", true);
            }
        }
        // The live row of each key, indexed once (a flood made this a scan of every row per key: O(rows x keys)); an insert
        // shifts the rows below it.
        const live = Object.create(null);
        for (let i = 0; i < rows.count; i++) {
            const r = rows.get(i);
            if (!r.gone)
                live[r.key] = i;
        }
        for (let k = 0; k < keys.length; k++) {
            const row = src.get(k);
            const at = live[keys[k]];
            if (at !== undefined) {
                const cur = rows.get(at);
                for (const f of win.fields) {
                    if (cur[f] !== row[f])
                        rows.setProperty(at, f, row[f]);
                }
                continue;
            }
            let before = rows.count;
            for (let n = k + 1; n < keys.length; n++) {
                const i = live[keys[n]];
                if (i !== undefined) {
                    before = i;
                    break;
                }
            }
            for (const key in live) {
                if (live[key] >= before)
                    live[key]++;
            }
            live[keys[k]] = before;
            const entry = {
                uid: win.nextUid++,
                key: keys[k],
                queued: true,
                demoting: false,
                gone: false
            };
            for (const f of win.fields)
                entry[f] = row[f];
            rows.insert(before, entry);
        }
        let rank = 0;
        for (let i = 0; i < rows.count; i++) {
            if (rows.get(i).gone)
                continue;
            const q = rank++ >= Tokens.notificationBannerMaxVisible;
            if (rows.get(i).queued === q)
                continue;
            // A shown banner pushed back into the queue leaves as a banner does (audit B-11): `demoting` keeps its slot
            // shown until that exit is over, and is set first so the banner is never unloaded in between.
            if (q && leaving < Tokens.notificationBannerMaxVisible) {
                leaving++;
                rows.setProperty(i, "demoting", true);
            }
            rows.setProperty(i, "queued", q);
        }
    }

    // A demotion's exit is over (or a demoted banner came back first): the slot is an empty queued one, or shown again.
    function endDemotion(uid: int): void {
        for (let i = 0; i < rows.count; i++) {
            if (rows.get(i).uid === uid) {
                rows.setProperty(i, "demoting", false);
                return;
            }
        }
    }

    // A finished exit takes its row out, at a slot height of 0.
    function dropRow(uid: int): void {
        for (let i = 0; i < rows.count; i++) {
            if (rows.get(i).uid === uid) {
                rows.remove(i);
                return;
            }
        }
    }

    // One row per banner of the model, plus the ones still playing their exit. Roles: the model's fields, uid, queued
    // (beyond the visible count: an empty slot), demoting (queued, still playing the exit of its demotion) and gone.
    ListModel {
        id: rows
        dynamicRoles: true
    }

    Connections {
        target: Notifications.bannerModel

        // Once per event-loop turn, whatever the number of changes in it: a burst of notifications (a flood, a Clear All)
        // is one pass over the final model, and only the banners still there at its end are made.
        function onRowsInserted(): void {
            Qt.callLater(win.sync);
        }
        function onRowsRemoved(): void {
            Qt.callLater(win.sync);
        }
        function onDataChanged(): void {
            Qt.callLater(win.sync);
        }
        function onModelReset(): void {
            Qt.callLater(win.sync);
        }
        function onRowsMoved(): void {
            Qt.callLater(win.sync);
        }
    }

    Component.onCompleted: sync()

    // The window's input region: the shown banners (not a leaving one) and their close buttons' overhang.
    Item {
        id: inputArea
        x: stack.x - win.closeOverhang
        y: stack.y - win.closeOverhang
        width: stack.width + win.closeOverhang
        height: stack.stackHeight > 0 ? stack.stackHeight + win.closeOverhang : 0
    }

    Column {
        id: stack

        readonly property real dpr: Math.max(1, Screen.devicePixelRatio)
        readonly property bool still: Appearance.reduceMotion
        readonly property int moveDuration: still ? 0 : Appearance.duration(Tokens.motionNormal)
        readonly property int fadeDuration: Appearance.duration(Tokens.motionNormal)
        // The height of the shown banners (the gap lives under each banner, inside its slot).
        readonly property real stackHeight: Math.max(0, height - Tokens.notificationBannerGap)

        // Where the stack rests: `y` glides to it (the Behavior below), the glass is judged over it at once.
        readonly property real restY: Tokens.menubarHeight + Tokens.notificationCenterInset + win.osdOffset
        // The height of the shown banners once every slot has opened or closed (stackHeight animates with them): the glass
        // is judged over the stack at rest, so an arrival or an exit does not re-judge every banner on each frame (audit B-02).
        property real restHeight: 0
        // Each slot's height at rest, by uid (written by the slots, summed once per turn).
        property var restHeights: ({})

        function setRest(uid: int, h: real): void {
            if (h > 0)
                stack.restHeights[uid] = h;
            else
                delete stack.restHeights[uid];
            Qt.callLater(stack.measureRest);
        }

        function measureRest(): void {
            let h = 0;
            for (const uid in stack.restHeights)
                h += stack.restHeights[uid];
            stack.restHeight = Math.max(0, h - Tokens.notificationBannerGap);
        }

        x: win.pad
        // macOS: banners start where the Notifications column starts.
        y: restY
        width: Tokens.notificationBannerWidth
        spacing: 0

        // The banners make room for the OSD; under Reduce Motion they jump (ADR-0039 step 5).
        Behavior on y {
            enabled: !Appearance.reduceMotion
            NumberAnimation {
                duration: Appearance.duration(Tokens.motionNormal)
                // A move: the move curve (ADR-0039 step 20).
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }
        }

        Repeater {
            model: rows

            delegate: Item {
                id: slot

                required property int uid
                required property string key
                required property int nid
                required property string appName
                required property string appIcon
                required property string image
                required property string summary
                required property string bodyHtml
                required property real time
                required property int urgency
                required property string actionsJson
                required property bool queued
                required property bool demoting
                required property bool gone

                // Queued banners (beyond the visible count) are empty slots: no banner, no height; a new banner and the one
                // that moves up from the queue slide in on their own (Banner's entrance) while their slot opens.
                readonly property bool shown: !queued || demoting
                readonly property bool leaving: gone || demoting
                // The slot's height once its opening or closing is over (Banners.stack.restHeight).
                readonly property real restHeight: !queued && !gone && banner.item ? (banner.item as Item).height + Tokens.notificationBannerGap : 0
                onRestHeightChanged: stack.setRest(slot.uid, slot.restHeight)
                // The exit (UI audit 2026-11-05 U1): the card slides out to the right (the card itself moves, so its blur
                // region follows it as on the way in) while the slot fades and its height closes up, so the banners below
                // rise with it; the row goes at the end, at a height of 0. Under Reduce Motion it fades where it stands,
                // then the gap closes at once. `grow` opens the slot of a new banner the same way.
                property real slide: 0
                property real collapse: 0
                property real grow: 0
                property Item card: null
                readonly property int blurX: card ? Math.round(stack.x + slot.x + card.x) : 0
                readonly property int blurY: card ? Math.round(stack.y + slot.y + card.y) : 0
                readonly property int blurW: card ? Math.round(card.width) : 0
                readonly property int blurH: card ? Math.round(card.height) : 0

                width: stack.width
                height: shown && banner.item ? ((banner.item as Item).height + Tokens.notificationBannerGap) * grow * (1 - collapse) : 0
                visible: shown

                onShownChanged: {
                    if (shown)
                        slot.open();
                }
                Component.onCompleted: {
                    if (shown)
                        slot.open();
                    stack.setRest(slot.uid, slot.restHeight);
                }
                onGoneChanged: {
                    if (!gone)
                        return;
                    demote.stop();
                    exit.start();
                }
                // Pushed into the queue by a newer banner: the exit of a dismissal, then the slot empties (the banner's hover
                // no longer holds its timer; it stays in the model). Back out of the queue before that exit is over: the exit
                // stops and the banner stands where it is again.
                onQueuedChanged: {
                    if (queued && demoting && !gone) {
                        Notifications.holdBanner(slot.key, false);
                        demote.restart();
                    } else if (!queued && demoting) {
                        demote.stop();
                        slot.settle();
                        win.endDemotion(slot.uid);
                    }
                }

                function settle(): void {
                    slide = 0;
                    collapse = 0;
                    opacity = 1;
                }
                Component.onDestruction: {
                    win.cards = win.cards.filter(c => c && c !== slot);
                    stack.setRest(slot.uid, 0);
                }

                function open(): void {
                    grow = 0;
                    enter.restart();
                }

                NumberAnimation {
                    id: enter

                    target: slot
                    property: "grow"
                    from: 0
                    to: 1
                    duration: stack.moveDuration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Appearance.curve
                }

                SequentialAnimation {
                    id: exit

                    ParallelAnimation {
                        NumberAnimation {
                            target: slot
                            property: "slide"
                            to: stack.still ? 0 : Tokens.notificationBannerWidth + win.pad
                            duration: stack.moveDuration
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.curve
                        }

                        NumberAnimation {
                            target: slot
                            property: "opacity"
                            to: 0
                            duration: stack.fadeDuration
                        }

                        SequentialAnimation {
                            PauseAnimation {
                                duration: stack.still ? stack.fadeDuration : 0
                            }

                            NumberAnimation {
                                target: slot
                                property: "collapse"
                                to: 1
                                duration: stack.moveDuration
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: Appearance.curve
                            }
                        }
                    }

                    ScriptAction {
                        script: win.dropRow(slot.uid)
                    }
                }

                // The demotion's exit: the same slide, fade and close as `exit`, then the banner is unloaded (its slot empties)
                // and the slot is made ready for the banner's return from the queue, which slides in again.
                SequentialAnimation {
                    id: demote

                    ParallelAnimation {
                        NumberAnimation {
                            target: slot
                            property: "slide"
                            to: stack.still ? 0 : Tokens.notificationBannerWidth + win.pad
                            duration: stack.moveDuration
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.curve
                        }

                        NumberAnimation {
                            target: slot
                            property: "opacity"
                            to: 0
                            duration: stack.fadeDuration
                        }

                        SequentialAnimation {
                            PauseAnimation {
                                duration: stack.still ? stack.fadeDuration : 0
                            }

                            NumberAnimation {
                                target: slot
                                property: "collapse"
                                to: 1
                                duration: stack.moveDuration
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: Appearance.curve
                            }
                        }
                    }

                    ScriptAction {
                        script: {
                            win.endDemotion(slot.uid);
                            slot.settle();
                        }
                    }
                }

                Loader {
                    id: banner
                    active: slot.shown
                    onLoaded: {
                        slot.card = (item as Banner).cardItem;
                        win.cards = win.cards.concat([slot]);
                    }
                    onActiveChanged: {
                        if (!active && slot.card !== null) {
                            win.cards = win.cards.filter(c => c && c !== slot);
                            slot.card = null;
                        }
                    }

                    sourceComponent: Banner {
                        // The stack's area on the output (the window is anchored top-right): the backdrop of the glass (G-3).
                        // From where the stack rests, not its gliding `y` nor its opening height: the tint is not judged again on
                        // each frame of a move, an arrival or an exit (audit B-02).
                        backdropRect: Qt.rect(win.screenWidth - win.pad - Tokens.notificationBannerWidth, stack.restY, Tokens.notificationBannerWidth, stack.restHeight)
                        closeOverhang: win.closeOverhang
                        leaving: slot.leaving
                        exitSlide: slot.slide
                        key: slot.key
                        nid: slot.nid
                        appName: slot.appName
                        appIcon: slot.appIcon
                        image: slot.image
                        summary: slot.summary
                        bodyHtml: slot.bodyHtml
                        time: slot.time
                        urgency: slot.urgency
                        actionsJson: slot.actionsJson
                    }
                }
            }
        }
    }
}
