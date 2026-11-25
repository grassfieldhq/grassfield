#!/usr/bin/env bash
# Static wiring check of the Quick Settings, Search and Notifications fixes (docs/specs/controlcenter.md, notifications.md): the
# pure logic has unit tests, this proves the components still CALL it (reverting one call site must fail a check;
# tests/shell/qs_wiring_mutants.sh does exactly that).
#   qs_wiring.sh [ROOT]        (ROOT holds shell/, default: the repository)
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
root=${1:-$here}
exec python3 -I - "$root" <<'PY'
import re
import sys

root = sys.argv[1]
fail = False


def read(rel):
    text = open(root + "/" + rel, encoding="utf-8").read()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def need(name, text, pattern):
    global fail
    if re.search(pattern, text, re.S):
        print("PASS " + name)
    else:
        print("FAIL " + name)
        fail = True


def func(text, name):
    m = re.search(r"function " + name + r"\(.*?\n    }\n", text, re.S)
    return m.group(0) if m else ""


# Notifications: every preview-hidden rule runs through the policy of the app.
n = read("shell/notifications/Notifications.qml")
need("Notifications.previewShown resolves the per-app policy", func(n, "previewShown"), r"NotificationPrefs\.effective\(Settings\.notificationsAppPreviews, appName, Settings\.notificationsPreviews\)")
need("Notifications.summaryFor hides the title", func(n, "summaryFor"), r"NotificationPrefs\.display\(previewShown\(appName\)")
need("Notifications.bodyFor hides the text", func(n, "bodyFor"), r"NotificationPrefs\.display\(previewShown\(appName\)")
need("Notifications.imageFor hides the sender's image", func(n, "imageFor"), r"NotificationPrefs\.imageShown\(previewShown\(appName\)")
need("Notifications.appIconFor drops a path app_icon", func(n, "appIconFor"), r"NotificationPrefs\.appIconShown\(previewShown\(appName\)")
need("Notifications.actionsFor hides the sender's actions", func(n, "actionsFor"), r"NotificationPrefs\.actionsShown\(previewShown\(appName\)")

# Banner and Notification Center rows use them for title, text, image, app icon and actions.
for rel, who, app in (("shell/notifications/Banner.qml", "Banner", "root.appName"), ("shell/notifications/NotificationList.qml", "NotificationList", "item.appName")):
    t = read(rel)
    for f in ("summaryFor", "bodyFor", "imageFor", "appIconFor", "actionsFor"):
        need("%s calls Notifications.%s with the app" % (who, f), t, r"Notifications\." + f + r"\([^()]*" + re.escape(app) + r"\)")

# Popups: a centred popup resolves its display through ScreenChoice.
p = read("shell/services/Popups.qml")
need("Popups.openCentered resolves through ScreenChoice.centered with the asker's screen", func(p, "openCentered"), r"ScreenChoice\.centered\(active, screenName, Compositor\.activeScreenName, screen\)")
need("Popups.confirm passes the asker's screen on", func(p, "confirm"), r"openCentered\(\"confirm\".*?, screen\)")

# Search: Restart, Shut Down and Log Out (and the palette's Empty Trash) confirm on the display Search is shown on. A confirm is
# a statement (`...);`) or a command table entry (`name: () => Popups.confirm(...),`), one per line.
s = read("shell/search/Search.qml")
confirm_re = r"Popups\.confirm\((.*)\)\s*[;,]?\s*$"
confirms = re.findall(confirm_re, s, re.M)
need("Search has its three power confirms", "\n".join(confirms), r"\"restart\".*\"shutdown\".*\"logout\"")
confirms += re.findall(confirm_re, read("shell/search/BuiltinCommands.qml"), re.M)
need("the palette's Empty Trash confirms", "\n".join(confirms), r"\"emptytrash\"")
if confirms and all(c.rstrip().endswith("screenName") for c in confirms):
    print("PASS every Search confirm passes screenName")
else:
    print("FAIL every Search confirm passes screenName")
    fail = True

# Connectivity: the persisted Airplane state is settled and written privately.
c = read("shell/services/Connectivity.qml")
need("Connectivity settles on every radio change", c, r"onRadiosNowChanged:\s*settleAirplane\(\)")
need("Connectivity.settleAirplane erases a stale state", func(c, "settleAirplane"), r"Airplane\.shouldClear\(airplaneState, radiosNow\).*saveAirplane\(Airplane\.end\(\)\)")
need("Connectivity settles when the grace period ends", c, r"id: airplaneSettle[^{}]*onTriggered:\s*\{[^}]*settleAirplane\(\)")
need("Connectivity settles after the saved state is loaded", c, r"id: airplaneReader[^{}]*onLoaded:\s*\{[^}]*settleAirplane\(\)")
need("Connectivity writes the state through write-private.sh", func(c, "saveAirplane"), r"services/write-private\.sh")
sys.exit(1 if fail else 0)
PY
