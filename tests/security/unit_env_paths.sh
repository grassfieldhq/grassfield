#!/usr/bin/env bash
# Review of 360d6fa (the GF-115 class), runtime counterpart of tests/security/shell_unit_env.sh: a hostile
# `qs/security/lock` module (lockState "EVIL-LOCK") on a QML search path of the calling environment replaces the lock
# screen of a shell started with that environment, and is ignored by a shell started with the environment of
# packaging/systemd/grassfield-shell.service. Offscreen, against the REAL shell modules (dev session, no compositor,
# nothing can lock):
#   control     QML_IMPORT_PATH and, separately, QML2_IMPORT_PATH name the hostile directory   -> the hostile Lock loads
#               (the attack is real)
#   unit env    the same hostile environment, then the unit's UnsetEnvironment= and Environment= applied as systemd does
#               (both read from the unit file), then this tree's own module roots as QML_IMPORT_PATH, standing in for the
#               packaged shell's Qt built-in import path (/usr/lib/qt6/qml), exactly as scripts/dev/shell-run.sh
#               --unit-env does                                                                     -> the real Lock
# Re-review: the packaged command line (qs -n -p <tree>) with each variable `qs --help` maps to an option set to a hostile
# value: QS_MANIFEST alone stops it in the control (exit 108: "--path excludes --manifest", no lock, no polkit agent);
# with the unit's environment every one of them is cleared and the shell starts. And a native GTK module named by
# GTK3_MODULES, or by GTK_PATH and GTK_MODULES, is loaded by the gtk3 platform theme Omarchy's environment selects in the
# control (its constructor leaves a marker; offscreen there is no display, so the process then exits 1 either way) and
# never with the unit's environment (SKIP without gcc or the gtk3 platform theme plugin).
# Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/unit-env.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p -m 700 "$tmp/runtime" "$tmp/cache"
mkdir -p "$tmp/home" "$tmp/state" "$tmp/config" "$tmp/cfg" "$tmp/evil/qs/security/lock"
ui/i18n/build-direct.sh >/dev/null
scripts/dev/i18n-build.sh >/dev/null
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/security/unit_env_paths.d/probe.qml "$tmp/cfg/shell.qml"
printf 'module qs.security.lock\nsingleton Lock 1.0 Lock.qml\n' >"$tmp/evil/qs/security/lock/qmldir"
printf 'pragma Singleton\nimport QtQuick\nimport Quickshell\nSingleton {\n    readonly property string lockState: "EVIL-LOCK"\n}\n' \
  >"$tmp/evil/qs/security/lock/Lock.qml"

unit=packaging/systemd/grassfield-shell.service
mapfile -t unit_unset < <(sed -n 's/^UnsetEnvironment=//p' "$unit" | tr ' ' '\n' | sed '/^$/d')
mapfile -t unit_set < <(sed -n 's/^Environment=//p' "$unit" | tr ' ' '\n' | sed '/^$/d')
# The unit's gtk3 platform theme (Environment=QT_QPA_PLATFORMTHEME=gtk3, #25) needs a display: offscreen with no display,
# GTK fails ("cannot open display") and qs exits 1 before the probe runs. The probe and argument runs below take the
# unit's environment without it (it changes no QML import or qs option); the GTK module runs keep it, it is what they test.
mapfile -t unit_set_offscreen < <(printf '%s\n' "${unit_set[@]}" | grep -v '^QT_QPA_PLATFORMTHEME=')
dev_roots="$root/ui:$root/.dev/build/qml"

fail=0
run() { # <label> <expect hostile|real> <unit|raw> env...: one probe run; the hostile variables come first
  local label=$1 expect=$2 mode=$3 out line
  shift 3
  local -a envs=(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION)
  # The calling environment (hostile values), as the user manager would hold it.
  local -a calling=("$@")
  if [[ $mode == unit ]]; then
    # systemd: Environment= over the manager's environment, then UnsetEnvironment= last. The dev tree's module roots
    # stand in for the packaged Qt built-in import path, which Qt searches AFTER any QML_IMPORT_PATH that survives.
    local -a kept=()
    local kv name drop u surviving=""
    for kv in "${calling[@]}"; do
      name=${kv%%=*}
      drop=0
      for u in "${unit_unset[@]}"; do [[ $name == "$u" ]] && drop=1; done
      if ((drop)); then
        continue
      elif [[ $name == QML_IMPORT_PATH ]]; then
        surviving=${kv#*=}
      else
        kept+=("$kv")
      fi
    done
    calling=("${kept[@]}" "${unit_set_offscreen[@]}" QML_IMPORT_PATH="${surviving:+$surviving:}$dev_roots")
    for u in "${unit_unset[@]}"; do envs+=(-u "$u"); done
  fi
  out=$("${envs[@]}" HOME="$tmp/home" GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" \
    XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" QT_QPA_PLATFORM=offscreen GRASSFIELD_LANG=en \
    GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" "${calling[@]}" timeout 60 qs -p "$tmp/cfg" --no-color 2>&1) || true
  line=$(grep -o "unit-env: .*" <<<"$out" | head -n 1 || true)
  local ok=0
  case $expect in
    hostile) [[ $line == "unit-env: lockState=EVIL-LOCK devHooks=undefined" ]] && ok=1 ;;
    real) [[ $line == "unit-env: lockState=unlocked devHooks=boolean" ]] && ok=1 ;;
  esac
  if ((ok)); then echo "PASS: unit env paths $label ($line)"; else echo "FAIL: unit env paths $label: ${line:-no probe line} $(grep -E 'ERROR|TypeError' <<<"$out" | head -n 2)"; fail=1; fi
}

run "control: a hostile qs/security/lock on QML_IMPORT_PATH replaces the lock" hostile raw QML_IMPORT_PATH="$tmp/evil:$dev_roots"
run "control: on QML2_IMPORT_PATH too" hostile raw QML_IMPORT_PATH="$dev_roots" QML2_IMPORT_PATH="$tmp/evil"
run "with the unit's environment the QML_IMPORT_PATH one is ignored" real unit QML_IMPORT_PATH="$tmp/evil:$dev_roots"
run "with the unit's environment the QML2_IMPORT_PATH one is ignored" real unit QML2_IMPORT_PATH="$tmp/evil" QML_PLUGIN_PATH="$tmp/evil" \
  QT_PLUGIN_PATH="$tmp/evil" QS_CONFIG_PATH="$tmp/evil"

# --- the packaged command line under each qs option variable ---
mkdir -p "$tmp/argcfg"
printf 'import QtQuick\nimport Quickshell\nShellRoot {\n    Timer {\n        running: true\n        interval: 100\n        onTriggered: {\n            console.log("args-ok");\n            Qt.exit(0);\n        }\n    }\n}\n' >"$tmp/argcfg/shell.qml"
without_unit_unset() { # VAR=value...: the arguments whose names the unit clears are dropped
  local kv u name drop
  for kv in "$@"; do
    name=${kv%%=*}
    drop=0
    for u in "${unit_unset[@]}"; do [[ $name == "$u" ]] && drop=1; done
    ((drop)) || printf '%s\n' "$kv"
  done
}
argrun() { # <unit|raw> VAR=value...: the packaged arguments (-n -p <tree>); prints "<exit> <args-ok|->"
  local mode=$1 out rc=0
  shift
  local -a vars=("$@") envs=(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION)
  if [[ $mode == unit ]]; then
    mapfile -t vars < <(without_unit_unset "$@")
    for u in "${unit_unset[@]}"; do envs+=(-u "$u"); done
    vars+=("${unit_set_offscreen[@]}")
  fi
  out=$("${envs[@]}" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" QT_QPA_PLATFORM=offscreen "${vars[@]}" \
    timeout 30 qs -n -p "$tmp/argcfg" --no-color 2>&1) || rc=$?
  printf '%s %s\n' "$rc" "$(grep -q 'args-ok' <<<"$out" && echo args-ok || echo -)"
}
mapfile -t qs_vars < <(QT_QPA_PLATFORM=offscreen qs --help 2>&1 | grep -o '(Env:[A-Z0-9_]*)' | sed 's/^(Env:\(.*\))$/\1/' | sort -u)
if ((${#qs_vars[@]} == 0)); then
  echo "FAIL: unit env paths: qs --help names no option variable (Env:) here"
  fail=1
else
  got=$(argrun raw QS_MANIFEST="$tmp/evil/manifest.conf")
  if [[ $got == "108 -" ]]; then
    echo "PASS: unit env paths control: QS_MANIFEST stops the packaged command line (exit 108, the shell never starts)"
  else
    echo "FAIL: unit env paths control: QS_MANIFEST did not stop the packaged command line ($got): the case proves nothing"
    fail=1
  fi
  hostile=()
  for v in "${qs_vars[@]}"; do
    case $v in
      QS_CONFIG_PATH) hostile+=("$v=$tmp/evil") ;;
      QS_MANIFEST) hostile+=("$v=$tmp/evil/manifest.conf") ;;
      *) hostile+=("$v=evil") ;;
    esac
    got=$(argrun unit "${hostile[-1]}")
    if [[ $got == "0 args-ok" ]]; then
      echo "PASS: unit env paths with the unit's environment the shell starts under $v set"
    else
      echo "FAIL: unit env paths with the unit's environment $v still changes the start ($got)"
      fail=1
    fi
  done
  got=$(argrun unit "${hostile[@]}")
  if [[ $got == "0 args-ok" ]]; then
    echo "PASS: unit env paths with the unit's environment the shell starts with all of ${qs_vars[*]} set"
  else
    echo "FAIL: unit env paths with the unit's environment the shell does not start with all of them set ($got)"
    fail=1
  fi
fi

# --- native GTK modules through the gtk3 platform theme ---
if ! command -v gcc >/dev/null || [[ ! -e /usr/lib/qt6/plugins/platformthemes/libqgtk3.so ]]; then
  echo "SKIP: unit env paths GTK modules: gcc or the gtk3 platform theme plugin missing: NOT VERIFIED"
else
  mkdir -p "$tmp/gtkpath/modules"
  printf '#include <stdio.h>\n#include <stdlib.h>\n__attribute__((constructor)) static void mark(void) {\n    const char *f = getenv("GF_MODULE_MARK");\n    FILE *o = f ? fopen(f, "w") : NULL;\n    if (o) { fputs("loaded\\n", o); fclose(o); }\n}\n' >"$tmp/mod.c"
  gcc -shared -fPIC -o "$tmp/gtkpath/modules/libgfunitmod.so" "$tmp/mod.c"
  modrun() { # <label> <expect loaded|clean> <unit|raw> VAR=value...
    local label=$1 expect=$2 mode=$3 rc=0
    shift 3
    local -a vars=("$@") envs=(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION)
    if [[ $mode == unit ]]; then
      mapfile -t vars < <(without_unit_unset "$@")
      for u in "${unit_unset[@]}"; do envs+=(-u "$u"); done
      vars+=("${unit_set[@]}")
    fi
    rm -f "$tmp/mark"
    "${envs[@]}" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" QT_QPA_PLATFORM=offscreen \
      QT_QPA_PLATFORMTHEME=gtk3 GF_MODULE_MARK="$tmp/mark" "${vars[@]}" timeout 30 qs -n -p "$tmp/argcfg" --no-color >/dev/null 2>&1 || rc=$?
    local got=clean
    [[ -s $tmp/mark ]] && got=loaded
    if [[ $got == "$expect" ]]; then echo "PASS: unit env paths $label (module $got, qs exit $rc)"; else echo "FAIL: unit env paths $label (module $got, qs exit $rc)"; fail=1; fi
  }
  modrun "control: GTK3_MODULES loads native code into the shell" loaded raw GTK3_MODULES="$tmp/gtkpath/modules/libgfunitmod.so"
  modrun "control: GTK_PATH and GTK_MODULES too" loaded raw GTK_PATH="$tmp/gtkpath" GTK_MODULES=gfunitmod
  modrun "with the unit's environment GTK3_MODULES loads nothing" clean unit GTK3_MODULES="$tmp/gtkpath/modules/libgfunitmod.so"
  modrun "with the unit's environment GTK_PATH and GTK_MODULES load nothing" clean unit GTK_PATH="$tmp/gtkpath" GTK_MODULES=gfunitmod
fi
exit $fail
