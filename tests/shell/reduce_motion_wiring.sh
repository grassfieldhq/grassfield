#!/usr/bin/env bash
# Reduce Motion replaces motion with fades on the shell's free surfaces (ADR-0039 step 5, G10; macOS: slides become fades),
# checked statically: these surfaces need Quickshell and a compositor (the controls, Settings' spinner and Preview's animated
# images are tests/unit/tst_reducemotion.qml; the look is the nested pass). Fails when one of these is reverted:
#  * in the banners, the Notification Center, the Overview, Search, the stack popup, the OSD and the saver, every Behavior that
#    moves or resizes (any property but opacity, colour and the fades below) is off under Reduce Motion
#    (`enabled: ... !Appearance.reduceMotion`); the Overview's `progress` is exempt (under Reduce Motion it is the crossfade:
#    zoom 1, tiles at their opacity);
#  * a banner and the Notification Center fade in where they stand under Reduce Motion instead of sliding in;
#  * the stack fan's items stand at their places and only fade in;
#  * a banner dropped short of dismissing is back in place at once;
#  * the saver's slide crossfade stays a whole dissolve (not motion; macOS keeps its dissolves).
set -uo pipefail
root=${WIRING_ROOT:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}
cd "$root" || exit 2
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

surfaces=(shell/notifications/Banner.qml shell/notifications/Banners.qml shell/notifications/BannerStack.qml shell/notifications/NotificationCenter.qml
  shell/notifications/NotificationList.qml
  shell/overview/OverviewWindow.qml shell/search/SearchPanel.qml shell/overlay/StackPopup.qml shell/osd/OsdWindow.qml
  shell/saver/SaverView.qml)

# Prints "file:line property" for each moving Behavior whose first lines carry no Reduce Motion gate.
ungated() {
  awk -v f="$1" '
    /^[[:space:]]*Behavior on [A-Za-z]+ \{/ { prop = $3; start = FNR; gated = 0; n = 0; open = 1; next }
    open { n++; if ($0 ~ /enabled:.*!Appearance\.reduceMotion/) gated = 1
           if (n >= 3) { open = 0
             if (!gated && prop != "opacity" && prop != "color" && prop != "progress" && prop != "entrance") print f ":" start " " prop } }
  ' "$1"
}

for f in "${surfaces[@]}"; do
  out=$(ungated "$f")
  desc="$f: every Behavior that moves or resizes is off under Reduce Motion${out:+ (ungated: $out)}"
  check test -z "$out"
done

desc="Banner: under Reduce Motion it starts in place and fades in (entrance), its slide is off"
check bash -c 'grep -q "property real slide: Appearance.reduceMotion ? 0 : Tokens.notificationBannerWidth" "$0" \
  && grep -q "property real entrance: Appearance.reduceMotion ? 0 : 1" "$0" \
  && grep -q "opacity: root.entrance \* (1 - " "$0" \
  && awk "/Behavior on entrance \\{/{getline; print}" "$0" | grep -q "enabled: Appearance.reduceMotion"' shell/notifications/Banner.qml

desc="Notification Center: under Reduce Motion the column fades in at its place instead of sliding"
check bash -c 'grep -q "property real slideOffset: hostItem.shown || Appearance.reduceMotion ? 0 : " "$0" \
  && grep -q "opacity: hostItem.shown || !Appearance.reduceMotion ? 1 : 0" "$0" \
  && awk "/Behavior on opacity \\{/{getline; print}" "$0" | grep -q "enabled: Appearance.reduceMotion"' shell/notifications/NotificationCenter.qml

desc="Stack fan: its items stand at their places under Reduce Motion and fade in"
check bash -c 'grep -q "readonly property real spread: Appearance.reduceMotion ? 1 : progress" "$0" \
  && grep -q "readonly property real out: at.out \* root.spread" "$0" \
  && grep -q "readonly property real side: at.side \* root.spread" "$0" \
  && grep -q "opacity: root.progress" "$0"' shell/overlay/StackPopup.qml

desc="Banner: dropped short of dismissing, it is back in place at once under Reduce Motion"
check bash -c 'grep -B1 -A1 "else if (Appearance.reduceMotion)" "$0" | grep -q "card.dragX = 0;"' shell/notifications/Banner.qml

desc="Saver: the slides' crossfade stays a whole dissolve under Reduce Motion"
check grep -q "duration: Tokens.saverSlideFadeMs$" shell/saver/SaverView.qml

exit $fail
