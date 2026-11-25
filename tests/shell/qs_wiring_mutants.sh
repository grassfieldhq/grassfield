#!/usr/bin/env bash
# Mutation check of tests/shell/qs_wiring.sh: reverting any one call site of the Quick Settings, Search and Notifications fixes in
# a COPY of the files must make the wiring check fail, and the untouched copy must pass.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 -I - "$root" <<'PY'
import os
import shutil
import subprocess
import sys
import tempfile

root = sys.argv[1]
files = [
    "shell/notifications/Notifications.qml", "shell/notifications/Banner.qml", "shell/notifications/NotificationList.qml",
    "shell/services/Popups.qml", "shell/search/Search.qml", "shell/services/Connectivity.qml",
    "shell/search/BuiltinCommands.qml",
]
mutants = [
    ("Banner.qml: the image is no longer hidden", "shell/notifications/Banner.qml", "Notifications.imageFor(root.image, root.appName)", "root.image"),
    ("Banner.qml: the app icon path is no longer dropped", "shell/notifications/Banner.qml", "Notifications.appIconFor(root.appIcon, root.appName)", "root.appIcon"),
    ("Banner.qml: the actions are no longer hidden", "shell/notifications/Banner.qml", "Notifications.actionsFor(root.actionsJson, root.appName)", "root.actionsJson"),
    ("Banner.qml: the title is no longer hidden", "shell/notifications/Banner.qml", "summary: Notifications.summaryFor(root.summary, root.appName)", "summary: root.summary"),
    ("NotificationList.qml: the image is no longer hidden", "shell/notifications/NotificationList.qml", "Notifications.imageFor(item.image, item.appName)", "item.image"),
    ("NotificationList.qml: the body is no longer hidden", "shell/notifications/NotificationList.qml", "Notifications.bodyFor(item.bodyHtml, item.appName)", "item.bodyHtml"),
    ("Notifications.qml: imageFor ignores the policy", "shell/notifications/Notifications.qml", "NotificationPrefs.imageShown(previewShown(appName), image)", "image"),
    ("Popups.qml: openCentered uses the stale screen again", "shell/services/Popups.qml", "ScreenChoice.centered(active, screenName, Compositor.activeScreenName, screen)", "(screenName !== \"\" ? screenName : Compositor.activeScreenName)"),
    ("Search.qml: Restart confirm loses the screen", "shell/search/Search.qml", '"restart", {}, true, screenName)', '"restart", {}, true)'),
    ("Search.qml: Log Out confirm loses the screen", "shell/search/Search.qml", '"logout", {}, true, screenName)', '"logout", {}, true)'),
    ("BuiltinCommands.qml: Empty Trash confirm loses the screen", "shell/search/BuiltinCommands.qml", '"emptytrash", {}, true, root.screenName)', '"emptytrash", {}, true)'),
    ("Connectivity.qml: no settle on radio changes", "shell/services/Connectivity.qml", "onRadiosNowChanged: settleAirplane()", ""),
    ("Connectivity.qml: the stale state is only hidden, not erased", "shell/services/Connectivity.qml", "saveAirplane(Airplane.end());\n    }\n    onRadios", "}\n    onRadios"),
    ("Connectivity.qml: no settle after the grace period", "shell/services/Connectivity.qml", "root.airplaneSettling = false;\n            root.settleAirplane();", "root.airplaneSettling = false;"),
    ("Connectivity.qml: no settle after load", "shell/services/Connectivity.qml", "root.airplaneState = Airplane.parse(text());\n            root.settleAirplane();", "root.airplaneState = Airplane.parse(text());"),
    ("Connectivity.qml: the state is written without write-private.sh", "shell/services/Connectivity.qml", 'Quickshell.shellPath("services/write-private.sh")', 'Quickshell.shellPath("services/other.sh")'),
]


def check(tree):
    p = subprocess.run([root + "/tests/shell/qs_wiring.sh", tree], capture_output=True, text=True)
    return p.returncode


bad = False
for name, rel, old, new in mutants:
    tree = tempfile.mkdtemp()
    for f in files:
        os.makedirs(os.path.dirname(os.path.join(tree, f)), exist_ok=True)
        shutil.copy(os.path.join(root, f), os.path.join(tree, f))
    path = os.path.join(tree, rel)
    text = open(path, encoding="utf-8").read()
    if old not in text:
        print("FAIL mutant %r: the text to revert is gone; update this test" % name)
        bad = True
    else:
        open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
        if check(tree) == 0:
            print("FAIL mutant %r was not caught" % name)
            bad = True
        else:
            print("PASS mutant %r fails the wiring check" % name)
    shutil.rmtree(tree)
tree = tempfile.mkdtemp()
for f in files:
    os.makedirs(os.path.dirname(os.path.join(tree, f)), exist_ok=True)
    shutil.copy(os.path.join(root, f), os.path.join(tree, f))
if check(tree) != 0:
    print("FAIL the untouched copy does not pass")
    bad = True
else:
    print("PASS the untouched copy passes")
shutil.rmtree(tree)
sys.exit(1 if bad else 0)
PY
