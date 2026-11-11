pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui
import qs.security
import qs.services
import "../LockMachine.js" as Machine

// Content of one lock surface (one per screen): the output's wallpaper, sharp, under a banded scrim, date and clock at
// the top centre, avatar, user name and password field near the bottom centre. Nothing else is
// rendered here on purpose: no notifications, no window thumbnails, no media (gate L4).
// Display only: authentication, lock state and crash recovery live in Lock.qml and LockController.
//
// Ready before it is needed (ADR-0040 step 4a, ID-7): the backdrop (LockStill.qml: the wallpaper's prepared still, decoded
// while the session was unlocked, else the colour or the artwork the output shows), the account's name and picture are
// taken once, when the surface is created (the backdrop when it is first decided, at most wallpaper.firstShowTimeoutMs
// later: the ground shows until then); once the lock shows, nothing on it changes but the clock (and, with
// wallpaper.moving, the artwork's clouds: see "the moving Grassfield artwork" below). The clock is refreshed on resume from
// sleep (`resumes`). Engaging the lock waits for none of it.
//
// Contrast (gate A2, both appearances, any wallpaper): as on macOS, white text with a soft shadow over the wallpaper
// darkened by a shadow-colour scrim (lock.dimOpacity) under the two text bands (the date and clock, the account column),
// lighter between them (lock.scrimClearOpacity, IQ-W4 A), and a dark frosted password field (lock.fieldFillOpacity). The
// band edges (lock.scrimFeather) lie outside every text line at every text scale: they follow the two columns' geometry.
// The scrim alone carries the contrast (the shadow is decoration): every role is computed
// in tests/visual/test_contrast_tokens.py ("lock ..." roles) and measured by tests/visual/contrast.sh (surface lock).
// A missing colour, scrim or shadow token, or a failed colour binding, only loses that colour or the shadow: the
// password field's geometry, focus and input never depend on them; the field and the error/notice lines have no layer or
// effect (a failed effect would hide them).
Item {
    id: root

    property bool authenticating: false
    // ADR-0040 step 4b (IQ-T2 A): the fade after a PAM success; the session is still locked until it ends (LockController).
    property bool releasing: false
    property bool inputEnabled: true
    property string message: ""
    // Persistent warning under the error line (e.g. crash recovery unavailable); never replaced.
    property string notice: ""
    property string userName: ""
    // What is drawn for the account name (display only; authentication never reads it). Fixed fake name in the
    // visual-test fixture (GRASSFIELD_DEV and GRASSFIELD_VISUAL_FIXTURES), else the account's own, as it was when the
    // surface was created.
    readonly property string shownName: VisualFixtures.active ? VisualFixtures.user : frozenName
    property string frozenName: ""
    // file:// URL of the account picture, already decoded (Lock.qml), or "" for the initials disc; taken at creation.
    property string avatarSource: ""
    property string frozenAvatar: ""
    // The backdrop Lock.qml offers for this output (LockStill.backdrop: null while undecided); `backdrop` is the one drawn,
    // adopted once.
    property var offeredBackdrop: null
    property var backdrop: null
    // Counts the resumes from sleep (Lock.qml): each refreshes the clock before anything else changes.
    property int resumes: 0
    // lock.showUser: the account's picture and name (the password field stays).
    property bool showUser: true
    // lock.showMessage + lock.message: the user's message above them, plain text ("" for none).
    property string lockMessage: ""
    // The password field holds no text (read by Lock.qml for the dev L2 check only; never the text or its length).
    readonly property bool fieldEmpty: field.empty

    signal submitted(string password)
    // Typing started after an error: the error line gives way (e.g. to the Caps Lock hint).
    signal edited

    // Always the dark palette (white text on the dimmed image, both appearances). Read through Appearance so that the
    // dev-only glyph mask of the contrast run recolours the lock text too; outside dev it is Tokens.colorDark.
    readonly property var colors: Appearance.darkColors

    function clear(): void {
        field.clear();
    }

    function shake(): void {
        shakeAnimation.restart();
    }

    function focusField(): void {
        field.forceActiveFocus();
    }

    // The content (the scrim, the date and clock, the account column) fades in once the surface shows and out while
    // releasing (lock.fadeInMs, lock.fadeOutMs; Reduce Motion caps them). The wallpaper does not fade (P-4). Display only:
    // the field takes input from the first frame whatever this opacity is (opacity stops no input), and nothing waits for
    // the animation (the release is the controller's timer).
    property bool shown: false
    // ADR-0040 ID-8 (step 5): when the lock follows the idle dim, its content starts at the dim's level: a shadow layer at the
    // dim's opacity over the wallpaper gives way to the scrim and the text as they fade in. Taken at creation.
    property real startDim: 0
    property real frozenDim: 0
    property real contentOpacity: root.shown && !root.releasing ? 1 : 0
    Behavior on contentOpacity {
        NumberAnimation {
            duration: Appearance.duration(root.releasing ? Tokens.lockFadeOutMs : Tokens.lockFadeInMs)
        }
    }

    function adopt(b: var): void {
        if (root.backdrop === null && b !== null && b !== undefined)
            root.backdrop = b;
    }

    onOfferedBackdropChanged: root.adopt(root.offeredBackdrop)
    onResumesChanged: clock.refresh()

    // ---- the moving Grassfield artwork (ADR-0040 step 9, as the integrator decided in the review of e067f26f) ----
    // Display only, like the rest of this view. With wallpaper.moving (`moving`, taken at creation like the name), the
    // artwork's clouds move here and nowhere else, as macOS's moving wallpapers do: from where the desktop's still picture left
    // them (`motionStart`, taken until they first move: a surface whose output is known only after its creation starts from
    // that output's clouds), while the backdrop is the artwork, not under Reduce Motion and not while `motionHeld` (Lock.qml:
    // the displays are off, or the session is unlocked; they hold where they are), by the artwork's own Timer
    // (wallpaper.movingFrameMs steps). When the release fade starts they slow down linearly to a stop within it (Easing.OutQuad from the running speed,
    // WallpaperConfig.lockMotionRest) at `motionRest`, which Lock.qml gives the desktop at once as its still picture: the
    // desktop under the lock is the frame the lock comes to rest on. Nothing waits for it (the release is the controller's
    // timer), and a lock request during the fade lets them move on from there.
    property bool moving: false
    property real motionStart: 0
    property bool motionHeld: false
    property bool frozenMoving: false
    // The clouds have moved (or the release started): `motionStart` is no longer taken.
    property bool motionTaken: false
    // -1 until a release fade starts.
    property real motionRest: -1
    readonly property bool motionPlays: root.frozenMoving && root.backdrop !== null && root.backdrop.kind === "art" && !root.releasing && !Appearance.reduceMotion && !root.motionHeld

    // Taken once they play, a turn later: a screen name that arrives after creation changes the backdrop and `motionStart` in
    // the same notification, the backdrop first (counter-review of 7db57a7d, NIT); the first step is wallpaper.movingFrameMs
    // away, so nothing moves before the start is taken.
    onMotionPlaysChanged: {
        if (root.motionPlays)
            Qt.callLater(() => {
                root.motionTaken = true;
            });
    }
    onMotionStartChanged: {
        if (root.frozenMoving && !root.motionTaken)
            lockArt.motionMs = root.motionStart;
    }

    onReleasingChanged: {
        motionStop.stop();
        if (!root.releasing || !root.frozenMoving)
            return;
        root.motionTaken = true;
        const fade = Appearance.duration(Tokens.lockFadeOutMs);
        const rest = WallpaperConfig.lockMotionRest(lockArt.motionMs, lockArt.movingOn && root.backdrop !== null && root.backdrop.kind === "art" && !Appearance.reduceMotion, fade);
        root.motionRest = rest;
        if (rest > lockArt.motionMs) {
            motionStop.to = rest;
            motionStop.duration = fade;
            motionStop.start();
        }
    }

    NumberAnimation {
        id: motionStop
        target: lockArt
        property: "motionMs"
        easing.type: Easing.OutQuad
    }

    Component.onCompleted: {
        // Focus first, then the content's fade-in: no display statement ever comes before them (opus review of f66cf08e).
        focusField();
        root.shown = true;
        root.frozenDim = root.startDim;
        root.frozenName = root.userName;
        root.frozenAvatar = root.avatarSource;
        root.frozenMoving = root.moving;
        lockArt.motionMs = root.motionStart;
        root.adopt(root.offeredBackdrop);
    }

    // Nothing decided in time (a still that is still being checked, an output that showed no wallpaper yet): the artwork.
    Timer {
        interval: Tokens.wallpaperFirstShowTimeoutMs
        running: root.backdrop === null
        onTriggered: root.adopt({kind: "art", still: "", color: "", artwork: "", variant: ""})
    }

    // Created with each lock surface, so it shows the right time as the lock appears (WallClock.refresh at completion);
    // not SystemClock, which spins in the repeated hour of a daylight saving fall-back (WallClock.qml).
    WallClock {
        id: clock
    }

    // Soft drop shadow under the white text (decoration only, see the header).
    component TextShadow: MultiEffect {
        shadowEnabled: true
        shadowColor: Appearance.darkColors.shadow
        shadowOpacity: Tokens.lockTextShadowOpacity
        shadowBlur: Tokens.lockTextShadowBlur
        shadowVerticalOffset: Tokens.lockTextShadowOffsetY
    }

    // The backdrop, sharp (IQ-W4 A), once decided; until then the surface's own colour, the ground, shows (Lock.qml).
    Item {
        anchors.fill: parent
        visible: root.backdrop !== null

        Rectangle {
            anchors.fill: parent
            visible: root.backdrop !== null && root.backdrop.kind === "color"
            color: root.backdrop !== null && root.backdrop.kind === "color" ? root.backdrop.color : "transparent"
        }

        // The artwork the output shows, and the picture's fallback (drawn until the still is Ready, and if it fails).
        GrassfieldArtwork {
            id: lockArt
            anchors.fill: parent
            visible: root.backdrop !== null && root.backdrop.kind !== "color" && still.status !== Image.Ready
            artwork: root.backdrop !== null ? root.backdrop.artwork : ""
            variant: root.backdrop !== null ? root.backdrop.variant : ""
            moving: root.frozenMoving
            playing: root.motionPlays
        }

        // The wallpaper's still: the url LockStill checked and decoded, so the pixmap cache gives it at once. Same options as
        // there (no sourceSize, Stretch): the cache key must match.
        Image {
            id: still
            anchors.fill: parent
            source: root.backdrop !== null && root.backdrop.kind === "picture" ? root.backdrop.still : ""
            fillMode: Image.Stretch
            asynchronous: true
            cache: true
            retainWhileLoading: false
        }
    }

    // Dev-only: the wallpaper override of the contrast run (VisualFixtures.wallpaperFile, always "" outside dev), so that the
    // lock is measured over the same worst-case wallpapers as the desktop; an empty source draws nothing.
    Image {
        anchors.fill: parent
        source: VisualFixtures.wallpaperFile !== "" ? "file://" + VisualFixtures.wallpaperFile : ""
        fillMode: Image.Stretch
        sourceSize: Qt.size(width, height)
        asynchronous: true
        cache: false
        smooth: false
    }

    // The idle dim carried over (ID-8): from the dim's level to nothing as the content fades in.
    Rectangle {
        anchors.fill: parent
        visible: root.frozenDim > 0
        color: root.colors.shadow
        // Only on the way in: the unlock fade does not bring the dim back (opus review of 9a417967, NIT).
        opacity: root.releasing ? 0 : root.frozenDim * (1 - root.contentOpacity)
    }

    // The banded scrim (IQ-W4 A): lock.dimOpacity from the top to the bottom of the date and clock and from the top of the
    // account column to the bottom, lock.scrimClearOpacity between them, each edge a lock.scrimFeather ramp on the clear
    // side, so that every text line lies on lock.dimOpacity. Without room for a clear band (a short screen, a large text
    // scale), the whole surface stays at lock.dimOpacity.
    Rectangle {
        id: scrim
        anchors.fill: parent
        opacity: root.contentOpacity
        readonly property color dim: Appearance.withAlpha(root.colors.shadow, Tokens.lockDimOpacity)
        readonly property color clear: Appearance.withAlpha(root.colors.shadow, Tokens.lockScrimClearOpacity)
        readonly property real upperEdge: (dateClock.y + dateClock.height) / Math.max(1, height)
        readonly property real lowerEdge: account.y / Math.max(1, height)
        readonly property real feather: Tokens.lockScrimFeather / Math.max(1, height)
        readonly property bool banded: lowerEdge - upperEdge > 2 * feather
        gradient: Gradient {
            GradientStop {
                position: 0
                color: scrim.dim
            }
            GradientStop {
                position: scrim.banded ? scrim.upperEdge : 0
                color: scrim.dim
            }
            GradientStop {
                position: scrim.banded ? scrim.upperEdge + scrim.feather : 0
                color: scrim.banded ? scrim.clear : scrim.dim
            }
            GradientStop {
                position: scrim.banded ? scrim.lowerEdge - scrim.feather : 1
                color: scrim.banded ? scrim.clear : scrim.dim
            }
            GradientStop {
                position: scrim.banded ? scrim.lowerEdge : 1
                color: scrim.dim
            }
            GradientStop {
                position: 1
                color: scrim.dim
            }
        }
    }

    // Any click focuses the password field.
    MouseArea {
        anchors.fill: parent
        onPressed: root.focusField()
    }

    Column {
        id: dateClock
        anchors.horizontalCenter: parent.horizontalCenter
        y: Tokens.lockTopMargin
        opacity: root.contentOpacity
        layer.enabled: true
        layer.effect: TextShadow {}

        Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            // The region's order: "Wednesday, November 5" where the month comes first (LockMachine.datePattern).
            text: Qt.locale().toString(FixedTime.date(clock.date), Machine.datePattern(qsTr("dddd d MMMM"), Qt.locale().dateFormat(Locale.ShortFormat)))
            color: root.colors.text
            // Inter Display at display sizes, with its tracking, as every display text (Appearance.fontFamilyFor; U24).
            font.family: Appearance.fontFamilyFor(Tokens.lockDateSize)
            font.pixelSize: Tokens.lockDateSize
            font.weight: Tokens.lockDateWeight
            font.letterSpacing: Appearance.trackingFor(Tokens.lockDateSize)
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatTime(FixedTime.date(clock.date), Machine.clockFormat(Qt.locale().timeFormat(Locale.ShortFormat)))
            color: root.colors.text
            font.family: Appearance.fontFamilyFor(Tokens.lockClockSize)
            font.pixelSize: Tokens.lockClockSize
            font.weight: Tokens.lockClockWeight
            font.letterSpacing: Appearance.trackingFor(Tokens.lockClockSize)
            Accessible.role: Accessible.StaticText
            Accessible.name: qsTr("Time: %1").arg(text)
        }
    }

    Column {
        id: account
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: parent.bottom
            bottomMargin: Tokens.lockBottomMargin
        }
        opacity: root.contentOpacity
        spacing: Tokens.spacingSm

        // The user's message (Settings > Lock Screen > Show message when locked): plain text, at most two lines.
        Text {
            visible: root.lockMessage !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, Tokens.lockMessageMaxWidth)
            textFormat: Text.PlainText
            text: root.lockMessage
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            color: root.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            layer.enabled: true
            layer.effect: TextShadow {}
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        // Avatar: the account picture (resolved by Lock), else the initials on a disc.
        Item {
            id: avatar

            visible: root.showUser
            anchors.horizontalCenter: parent.horizontalCenter
            width: Tokens.lockAvatarSize
            height: Tokens.lockAvatarSize
            Accessible.role: Accessible.Graphic
            Accessible.name: qsTr("Picture of %1").arg(root.shownName)

            Rectangle {
                id: disc
                anchors.fill: parent
                radius: width / 2
                color: Appearance.withAlpha(root.colors.fill, Tokens.lockAvatarFillOpacity)
                visible: picture.status !== Image.Ready

                Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: Machine.initials(root.shownName)
                    color: root.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.lockInitialsSize
                    font.weight: Tokens.lockNameWeight
                }
            }

            Image {
                id: picture
                anchors.fill: parent
                visible: false
                // Decoded already (Lock.qml's avatarPreload, same options: the pixmap cache key must match): no sourceSize, the
                // picture is the shell's own copy of at most 256 x 256 pixels (services/image-copy.py).
                source: VisualFixtures.active ? "" : root.frozenAvatar
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
            }

            Rectangle {
                id: circleMask
                anchors.fill: parent
                radius: width / 2
                visible: false
                layer.enabled: true
            }

            MultiEffect {
                anchors.fill: parent
                source: picture
                visible: picture.status === Image.Ready
                maskEnabled: true
                maskSource: circleMask
                autoPaddingEnabled: false
            }
        }

        Text {
            visible: root.showUser
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.shownName
            color: root.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.lockNameWeight
            layer.enabled: true
            layer.effect: TextShadow {}
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Tokens.lockFieldWidth
            height: Tokens.lockFieldHeight

            PasswordField {
                id: field
                x: 0
                width: parent.width
                height: parent.height
                enabled: root.inputEnabled
                busy: root.authenticating
                showSubmit: true
                radius: height / 2
                fontSize: Tokens.typographyBodySize
                // Dark frosted capsule: white dots and caret, secondary placeholder centred, no focus ring (the field always
                // has the focus here; macOS draws none: UI audit 2026-11-05 U23). No layer or effect on the field: it renders
                // and takes input whatever happens to the decoration.
                textColor: root.colors.text
                placeholderColor: root.colors.textSecondary
                placeholderAlignment: Text.AlignHCenter
                fillColor: Appearance.withAlpha(root.colors.shadow, Tokens.lockFieldFillOpacity)
                focusRing: false
                // Selection: the dark palette's accent behind dark accent-text dots (was the focus ring colour behind
                // white dots, 1.7-2.1:1).
                selectionColor: root.colors.accent
                selectedTextColor: root.colors.accentText
                onSubmitted: password => root.submitted(password)
                onEdited: root.edited()
            }

            SequentialAnimation {
                id: shakeAnimation

                readonly property int leg: Appearance.reduceMotion ? 0 : Tokens.lockShakeDuration

                NumberAnimation {
                    target: field
                    property: "x"
                    to: -Tokens.lockShakeDistance
                    duration: shakeAnimation.leg / 2
                    easing.type: Easing.OutQuad
                }
                NumberAnimation {
                    target: field
                    property: "x"
                    to: Tokens.lockShakeDistance
                    duration: shakeAnimation.leg
                    easing.type: Easing.InOutQuad
                }
                NumberAnimation {
                    target: field
                    property: "x"
                    to: -Tokens.lockShakeDistance / 2
                    duration: shakeAnimation.leg
                    easing.type: Easing.InOutQuad
                }
                NumberAnimation {
                    target: field
                    property: "x"
                    to: 0
                    duration: shakeAnimation.leg / 2
                    easing.type: Easing.OutQuad
                }
            }
        }

        // One line under the field: the last error, else the Caps Lock hint.
        Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.max(Tokens.lockFieldWidth, implicitWidth)
            horizontalAlignment: Text.AlignHCenter
            text: root.message !== "" ? root.message : (field.capsLock ? qsTr("Caps Lock is on") : " ")
            color: root.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            font.weight: Tokens.typographyMenuWeight
            // No layer/effect: a failed shadow effect must never hide an error (R12 review); the scrim carries A2.
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }

        Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.max(Tokens.lockFieldWidth, implicitWidth)
            horizontalAlignment: Text.AlignHCenter
            visible: root.notice !== ""
            text: root.notice
            color: root.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            font.weight: Tokens.typographyMenuWeight
            // No layer/effect: a failed shadow effect must never hide a notice such as "Crash recovery unavailable".
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }
    }
}
