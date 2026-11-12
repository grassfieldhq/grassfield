#!/usr/bin/env bash
# Offscreen tests (L0): QML TestCase files under tests/unit/, tests/shell, tests/security, gtest suites, compositor unit tests.
#
#   scripts/dev/test.sh [--layer data|logic|headless|nested|visual[,...]]
#
# The layer of every test is in tests/inventory.json (docs/testing/README.md). Without --layer the run is what it always
# was: data, logic and headless, plus the tests/shell scripts of the nested layer (they SKIP themselves without a nested
# session). `--layer nested` runs only those scripts; nested and visual tests that are bare commands (just visual,
# tests/compositor/*.sh, ...) are never started here, they are counted as "manual" in the summary.
# A per-layer summary of pass, fail, skip and manual is printed at the end, and the run fails when a layer it covered
# reported no result (tests/ci/inventory.py --results).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
# Inside the owner's real Grassfield session (GRASSFIELD_SESSION=1 in every terminal there) the suite runs at a low
# priority and builds on two jobs, so it never makes the session stall (2026-10-25: load 32 on 8 threads).
if [[ ${GRASSFIELD_SESSION:-} == 1 ]]; then
  renice -n 15 -p $$ >/dev/null 2>&1 || true
  export CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL:-2}
fi

layers_all=(data logic headless nested visual)
requested=()
explicit=0
while (($#)); do
  case $1 in
    --layer)
      [[ -n ${2:-} ]] || { echo "test.sh: --layer needs a value" >&2; exit 2; }
      IFS=, read -r -a more <<<"$2"
      requested+=("${more[@]}")
      explicit=1
      shift 2
      ;;
    --layer=*)
      IFS=, read -r -a more <<<"${1#--layer=}"
      requested+=("${more[@]}")
      explicit=1
      shift
      ;;
    -h | --help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "test.sh: unknown argument $1 (try --help)" >&2
      exit 2
      ;;
  esac
done
((explicit)) || requested=(data logic headless nested)
declare -A selected=()
for l in "${requested[@]}"; do
  [[ " ${layers_all[*]} " == *" $l "* ]] || { echo "test.sh: unknown layer '$l' (${layers_all[*]})" >&2; exit 2; }
  selected[$l]=1
done
want() { [[ -n ${selected[$1]:-} ]]; }

status=0
# Skipped checks are reported on their own (a SKIP line is never a pass): every line with "SKIP" printed by a test or
# by this script is collected here and repeated in the summary at the end.
skips=()
collect_skips() { local line; while IFS= read -r line; do [[ $line == *SKIP* ]] && skips+=("$line"); done <<<"$1"; return 0; }
skip() { echo "SKIP: $1"; skips+=("SKIP: $1"); }
load_above_cores() { awk -v n="$(nproc)" '{ exit !($1 > n) }' /proc/loadavg; }
# Offscreen tests must not load the desktop's platform theme (QT_QPA_PLATFORMTHEME=gtk3 calls gtk_init, which
# needs a display and fails inside the Claude Code sandbox).
unset QT_QPA_PLATFORMTHEME
# Scratch dir for tests that write files (removed on exit).
export GRASSFIELD_TEST_TMP="$root/.dev/test-tmp.$$"
mkdir -p "$GRASSFIELD_TEST_TMP"
trap 'rm -rf "$GRASSFIELD_TEST_TMP"' EXIT

# The inventory: layer and runner of every test, and the gate (static part) before anything runs.
python3 -I tests/ci/inventory.py || exit 1
declare -A inv_layer=() inv_runner=()
declare -A manual=()
while IFS=$'\t' read -r p l r; do
  inv_layer[$p]=$l
  inv_runner[$p]=$r
  [[ $r == bare ]] && manual[$l]=$((${manual[$l]:-0} + 1))
done < <(python3 -I tests/ci/inventory.py --map)

# One record per check: layer, id, pass|fail|skip (tests/ci/inventory.py --results reads it).
results="$GRASSFIELD_TEST_TMP/results.tsv"
: >"$results"
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$results"; }
# The layer of a registered path; an unregistered path is a failure (the static gate reports it too).
layer_of() {
  if [[ -z ${inv_layer[$1]:-} ]]; then echo "FAIL: $1 is not in tests/inventory.json" >&2; return 1; fi
  echo "${inv_layer[$1]}"
}
# Ran with exit code $3 and output $4: record pass, fail or skip (a SKIP line and no PASS line means nothing was verified).
record_run() {
  local layer=$1 id=$2 rc=$3 out=${4:-}
  if ((rc != 0)); then record "$layer" "$id" fail
  elif [[ $out == *SKIP* && $out != *PASS* ]]; then record "$layer" "$id" skip
  else record "$layer" "$id" pass
  fi
}

# --- headless: QML TestCase files under tests/unit -------------------------------------------------------------
if want headless && compgen -G "tests/unit/tst_*.qml" >/dev/null; then
  rc=0
  unit_out=$(QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import ui -input tests/unit 2>&1) || rc=1
  echo "$unit_out"
  # A failing case fails the run even if the runner exited 0.
  if grep -qE '^FAIL' <<<"$unit_out"; then rc=1; fi
  # Gate Q2: a QML runtime error of a product file (TypeError, binding loop, ...) fails the run even when every case passed.
  python3 -I tests/ci/qml_warnings.py <<<"$unit_out" || rc=1
  ((rc == 0)) || status=1
  record_run headless "tests/unit (qmltestrunner)" "$rc" "PASS"
fi
# Security module logic (lock state machine and controller, polkit dialog model, idle timings).
# `import qs.<dir>` resolves through a temporary import root holding a `qs` -> shell symlink.
if want headless && compgen -G "tests/security/tst_*.qml" >/dev/null; then
  qs_root=$(mktemp -d)
  ln -s "$root/shell" "$qs_root/qs"
  rc=0
  # QML_XHR_ALLOW_FILE_READ: tst_lockbackdrop.qml reads the module's sources (as tests/unit does).
  QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import ui -import "$qs_root" -input tests/security || rc=1
  rm -rf "$qs_root"
  ((rc == 0)) || status=1
  record_run headless "tests/security (qmltestrunner)" "$rc" "PASS"
fi
# Quickshell-level tests (real stores and files, reloads, hostile files): each tests/shell/<name>/shell.qml and
# tests/security/<name>/shell.qml prints PASS/FAIL. Run offscreen and detached from any compositor session.
# The i18n tests import the Grassfield.I18n plugin and read the compiled catalogs.
if want headless; then
  ui/i18n/build-direct.sh >/dev/null
  scripts/dev/i18n-build.sh >/dev/null
fi
for dir in tests/shell/*/ tests/security/*/; do
  [[ -f ${dir}shell.qml ]] || continue
  layer=$(layer_of "${dir}shell.qml") || { status=1; continue; }
  want "$layer" || continue
  # Private runtime/cache dirs: works inside the Claude Code sandbox (no writes to /run/user or ~/.cache).
  mkdir -p -m 700 "$GRASSFIELD_TEST_TMP/runtime" "$GRASSFIELD_TEST_TMP/cache"
  # A test that loads the real notification singleton carries a `dev-session` marker file: it runs as a dev session
  # (GRASSFIELD_DEV=1: no D-Bus server on the owner's bus) with its state and config under the scratch dir, its own
  # (a settings file one test writes, e.g. notif_image_files, made the next one start on it: search_clipboard failed).
  dev_env=()
  scratch=${dir%/}
  scratch=${scratch//\//_}
  mkdir -p -m 700 "$GRASSFIELD_TEST_TMP/state" "$GRASSFIELD_TEST_TMP/config"
  # A test that runs real, heavy work (the cursor builder) names its own limit in a `timeout` marker file (seconds).
  limit=60
  if [[ -f ${dir}timeout ]]; then
    limit=$(<"${dir}timeout")
    [[ $limit =~ ^[0-9]+$ ]] || { echo "FAIL: ${dir}timeout is not a number of seconds"; status=1; record "$layer" "${dir}shell.qml" fail; continue; }
  fi
  [[ -f ${dir}dev-session ]] && dev_env=(-u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$GRASSFIELD_TEST_TMP/state/$scratch" GRASSFIELD_CONFIG_HOME="$GRASSFIELD_TEST_TMP/config/$scratch")
  out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE "${dev_env[@]}" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" GRASSFIELD_LANG=en \
    XDG_RUNTIME_DIR="$GRASSFIELD_TEST_TMP/runtime" XDG_CACHE_HOME="$GRASSFIELD_TEST_TMP/cache" \
    timeout "$limit" qs -p "$dir" --no-color 2>&1) || { echo "$out"; echo "FAIL: $dir"; status=1; record "$layer" "${dir}shell.qml" fail; continue; }
  echo "$out" | grep -E "PASS|FAIL|SKIP" || { echo "$out"; status=1; }
  collect_skips "$out"
  # Gate Q2 (see the unit run above).
  python3 -I tests/ci/qml_warnings.py <<<"$out" || { status=1; record "$layer" "${dir}shell.qml" fail; continue; }
  if grep -q "FAIL" <<<"$out"; then
    # A timing budget measured on a saturated machine says nothing about the code: a test with a `load-sensitive`
    # marker that fails while the 1-minute load is above the core count is reported as not judged (a SKIP, never a
    # pass). The budget itself is a gate measurement for a quiet machine (just gate).
    if [[ -f ${dir}load-sensitive ]] && load_above_cores; then
      skip "${dir}: timing budget not judged at load $(cut -d' ' -f1 /proc/loadavg) (above $(nproc) cores)"
      record "$layer" "${dir}shell.qml" skip
      continue
    fi
    status=1; record "$layer" "${dir}shell.qml" fail; continue
  fi
  if grep -q "PASS" <<<"$out"; then record "$layer" "${dir}shell.qml" pass; elif grep -q SKIP <<<"$out"; then record "$layer" "${dir}shell.qml" skip; else status=1; record "$layer" "${dir}shell.qml" fail; fi
done
# The CMake build of ui/i18n (packaging/arch/PKGBUILD) installs a loadable plugin: i18n_live runs against it.
if want headless; then
  if command -v cmake >/dev/null && command -v ninja >/dev/null; then
    if scripts/dev/i18n-cmake-check.sh; then record headless scripts/dev/i18n-cmake-check.sh pass
    else echo "FAIL: scripts/dev/i18n-cmake-check.sh"; status=1; record headless scripts/dev/i18n-cmake-check.sh fail; fi
  else
    skip "i18n CMake check (cmake/ninja not installed)"
    record headless scripts/dev/i18n-cmake-check.sh skip
  fi
fi
# Plain shell tests: tests/shell/*.sh print PASS/FAIL and exit non-zero on failure. tests/security/*.sh and tests/integration/*.sh
# run here only when registered with the test.sh runner (the nested ones are bare commands; helpers are not registered).
# tests/integration/settings_dbus.sh is one: a private bus and fake services, SKIP where Unix sockets are not available.
for script in tests/shell/*.sh tests/security/*.sh tests/integration/*.sh tests/fuzz/*.sh; do
  [[ -f $script ]] || continue
  [[ $script == tests/security/* || $script == tests/integration/* ]] && [[ ${inv_runner[$script]:-} != test.sh ]] && continue
  layer=$(layer_of "$script") || { status=1; continue; }
  want "$layer" || continue
  script_out=$(bash "$script" 2>&1) && script_rc=0 || script_rc=$?
  [[ -n $script_out ]] && echo "$script_out"
  collect_skips "$script_out"
  ((script_rc == 0)) || { echo "FAIL: $script"; status=1; }
  record_run "$layer" "$script" "$script_rc" "$script_out"
done
# gtest suites: logic. One step per binary, built here (the sources are listed in tests/inventory.json).
# gtest_suite LABEL GTEST_HEADER_NEEDED_NOTE BUILD_CMD BINARY...: builds, runs every binary, records one result.
gtest_suite() {
  local label=$1 build=$2
  shift 2
  want logic || return 0
  if [[ ! -f /usr/include/gtest/gtest.h ]]; then
    skip "$label (gtest not installed)"
    record logic "$label" skip
    return 0
  fi
  local rc=0
  if eval "$build" >/dev/null; then
    local bin
    for bin in "$@"; do
      eval "$bin" || rc=1
    done
  else
    echo "FAIL: building $label"
    rc=1
  fi
  ((rc == 0)) || status=1
  record logic "$label" "$([[ $rc == 0 ]] && echo pass || echo fail)"
}
# Grassfield Files pure logic (sort keys, sizes, dates, path segments, names), and its KIO dialogs (ADR-0035 D-12 a: the
# logic, and real KIO jobs answered as the sheets answer, in a scratch home).
# The ASan and UBSan run leaves out MenuShortcuts.*: those tests drive Qt.labs.platform menus with QTest's key events, and the
# sanitized build stops in Qt's own header (a UBSan downcast in qtestkeyboard.h), and the leak report that follows is the
# sanitizer's own report of that stopped run: findings about Qt's test code and not about ours. The same tests run
# unsanitized in the first run. files-kio-tests is not built sanitized.
gtest_suite tests/unit/files "apps/files/build-direct.sh --tests >/dev/null && apps/files/build-direct.sh --tests --asan" \
  ".dev/build/files-unit-tests --gtest_brief=1" ".dev/build/files-kio-tests --gtest_brief=1" ".dev/build/files-unit-tests-asan --gtest_brief=1 --gtest_filter=-MenuShortcuts.*"
# Grassfield Preview pure logic (URL validation, size caps, file-type routing).
gtest_suite tests/unit/preview "apps/preview/build-direct.sh --tests" ".dev/build/preview-unit-tests --gtest_brief=1"
# grassfield-wallpaper (ADR-0016) logic: untrusted pictures (huge, corrupt, EXIF, FIFO, fit modes), listing, cache: built
# here, then again with ASan and UBSan.
gtest_suite tests/unit/wallpaper-tool "apps/wallpaper-tool/build-direct.sh --tests >/dev/null && apps/wallpaper-tool/build-direct.sh --tests --asan" \
  "QT_QPA_PLATFORM=offscreen .dev/build/wallpaper-unit-tests --gtest_brief=1" "QT_QPA_PLATFORM=offscreen .dev/build/wallpaper-unit-tests-asan --gtest_brief=1"
# grassfield-stack-helper (ADR-0025) logic: the orders, the window, the scan, the race of a vanishing file, the escaping: built
# here, then again with ASan and UBSan. The process itself is tests/shell/stack_helper.sh.
gtest_suite tests/unit/stack-helper "apps/stack-helper/build-direct.sh --tests >/dev/null && apps/stack-helper/build-direct.sh --tests --asan" \
  ".dev/build/stack-helper-unit-tests --gtest_brief=1" ".dev/build/stack-helper-unit-tests-asan --gtest_brief=1"
# grassfield-clipboard-helper (ADR-0034) logic: the offer types and the hint refusal, the reads' caps, the history and the pins
# with their limits and retention, the stores' modes and bounds, the image decoding with the format given: built here, then again
# with ASan and UBSan. The process, against a fake compositor, is tests/shell/clipboard_helper.sh.
gtest_suite tests/unit/clipboard-helper "apps/clipboard-helper/build-direct.sh --tests >/dev/null && apps/clipboard-helper/build-direct.sh --tests --asan" \
  "QT_QPA_PLATFORM=offscreen .dev/build/clipboard-helper-unit-tests --gtest_brief=1" "QT_QPA_PLATFORM=offscreen .dev/build/clipboard-helper-unit-tests-asan --gtest_brief=1"
# grassfield-secrets-handover (ADR-0035 D-12) logic: which items move, the marker, which executables are trusted: built here,
# then again with ASan and UBSan. The process against fake peers on a private bus is tests/integration/secrets_handover.sh.
gtest_suite tests/unit/secrets-handover "apps/secrets-handover/build-direct.sh --tests >/dev/null && apps/secrets-handover/build-direct.sh --tests --asan" \
  ".dev/build/secrets-handover-unit-tests --gtest_brief=1" ".dev/build/secrets-handover-unit-tests-asan --gtest_brief=1"
# grassfield-portal-settings (ADR-0035 D-8): the values it publishes, the namespace filter, the backend on a scratch settings
# file (changes, atomic replace, the auto schedule, the announcement at start): built here, then again with ASan and UBSan. With the real portal frontend
# on a private bus: tests/integration/portal_settings.sh.
gtest_suite tests/unit/portal-settings "apps/portal-settings/build-direct.sh --tests >/dev/null && apps/portal-settings/build-direct.sh --tests --asan" \
  ".dev/build/portal-settings-unit-tests --gtest_brief=1" ".dev/build/portal-settings-unit-tests-asan --gtest_brief=1"
# grassfield-portal's FileChooser (ADR-0035 D-4): the option mapping in and the results out, the panels' memory, and the
# backend on a private dbus-daemon with a fake frontend and a fake x-d-p-gtk (the forward, Close, the bounds, idle). With the
# real binary and the real frontend: tests/integration/portal_filechooser.sh.
gtest_suite tests/unit/portal "apps/portal/build-direct.sh --tests >/dev/null && apps/portal/build-direct.sh --tests --asan" \
  ".dev/build/portal-unit-tests --gtest_brief=1" ".dev/build/portal-unit-tests-asan --gtest_brief=1"
# grassfield-settings dev guard, the wallpaper helper door (exact tool path, exact argument vectors) and the Backend's glue
# (one answer per query unless shared, one password action per tag; fake commands on a scratch PATH).
gtest_suite tests/unit/settings "apps/settings/build-direct.sh --tests >/dev/null && apps/settings/build-direct.sh --tests --asan" \
  ".dev/build/settings-unit-tests --gtest_brief=1" ".dev/build/settings-unit-tests-asan --gtest_brief=1"
# Grassfield Store's read-only backend (ADR-0037 step 1): the catalog's rules, its signature (a fake gpgv here; the real one in
# tests/integration/store_catalog.sh), cache and serial, the channel and its URLs, AppStream and pacman readers (fakes on
# scratch paths), the merged model and search, the child-process limits. Built twice: plain, then with ASan and UBSan.
gtest_suite tests/unit/store "apps/store/build-direct.sh --tests >/dev/null && apps/store/build-direct.sh --tests --asan" \
  ".dev/build/store-unit-tests --gtest_brief=1" ".dev/build/store-unit-tests-asan --gtest_brief=1"
# The activity monitor's sampler (ADR-0038 step 1): the /proc and /sys parsers on fixtures, the owners and kinds, the per-tab
# reads and their turns, the kept descriptors, the TCP counters through sock_diag (the real kernel, loopback sockets of the
# test), the names made safe to show. Its window's backend (step 2): the values, the columns, the table's views, search,
# sort and selection, activity.json, and sampling only while the window is shown; the window itself with that backend on
# a fixture tree, always offscreen (A-W1). Built twice: plain, then with ASan and UBSan (the window's case plain only).
# Other owners through the real kernel: tests/integration/activity_owners.sh; the cost per tab: tests/apps/activity_cost.sh.
gtest_suite tests/unit/activity "apps/activity/build-direct.sh --tests >/dev/null && apps/activity/build-direct.sh --tests --asan" \
  ".dev/build/activity-unit-tests --gtest_brief=1" ".dev/build/activity-unit-tests-asan --gtest_brief=1" \
  ".dev/build/activity-window-tests --gtest_brief=1" ".dev/build/activity-window-tests-asan --gtest_brief=1" \
  ".dev/build/activity-window-qml-tests --gtest_brief=1"
# Grassfield Memos (ADR-0051): the store (round trip, 0700/0600 re-asserted, atomic writes, forward-only migration, a newer
# schema refused untouched, an unreadable file set aside, no memo text in a log), the text helpers (cleaned HTML, Font menu,
# plain paste), the frames read from Hyprland (a fake socket) and the backend. Built twice: plain, then with ASan and UBSan.
gtest_suite tests/unit/memos "apps/memos/build-direct.sh --tests >/dev/null && apps/memos/build-direct.sh --tests --asan" \
  ".dev/build/memos-unit-tests --gtest_brief=1" ".dev/build/memos-unit-tests-asan --gtest_brief=1"
# grassfield-menu-bridge logic (menu/1 validation, DBusMenu layout mapping, mnemonics, guards). The peer-to-peer D-Bus
# case skips itself inside the sandbox (no Unix sockets).
# Built twice: plain, then with ASan and UBSan.
gtest_suite tests/unit/menu-bridge "bridges/menu-bridge/build-direct.sh --tests >/dev/null && bridges/menu-bridge/build-direct.sh --tests --asan" \
  ".dev/build/menu-bridge-unit-tests --gtest_brief=1" ".dev/build/menu-bridge-unit-tests-asan --gtest_brief=1"
# grassfield-prompter (ADR-0035 D-9) logic: the caller's text made plain, the prompter/1 parser and messages, the bound of 8,
# the shell's cgroup and the socket peer, the trusted requesters (temporary trees), the bus filter, the GcrPrompt object.
# Built twice: plain, then with ASan and UBSan. The process on a private bus: tests/security/prompter_bridge.sh.
gtest_suite tests/unit/prompter "bridges/prompter/build-direct.sh --tests >/dev/null && bridges/prompter/build-direct.sh --tests --asan" \
  ".dev/build/prompter-unit-tests --gtest_brief=1" ".dev/build/prompter-unit-tests-asan --gtest_brief=1"
# Isolation: no test or dev script may start an app (grassfield-settings/files/preview, foot, ...) without
# scripts/dev/isolated.sh (nothing may be written to the owner's home), and the checker itself is tested.
if want logic; then
  rc=0
  python3 -I tests/tools/check-isolation.py --selftest || rc=1
  python3 -I tests/tools/check-isolation.py || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/tools/check-isolation.py "$rc" PASS
  # Visual suite tooling: contrast pixel reading and glyph-mask measurement on synthetic images.
  rc=0
  python3 -I tests/visual/test_contrast.py || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/visual/test_contrast.py "$rc" PASS
  # Gate P3's frame statistics (tests/visual/frame-stats.py) on synthetic frame streams.
  rc=0
  python3 -I tests/visual/test_frame_stats.py >/dev/null || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/visual/test_frame_stats.py "$rc" PASS
  # Gate A2, exact token calculation (primary evidence): every text role over the worst-case wallpapers, both appearances, transparency 0..0.6.
  rc=0
  python3 -I tests/visual/test_contrast_tokens.py || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/visual/test_contrast_tokens.py "$rc" PASS
  # Gate Q2's filter on fixed samples.
  rc=0
  python3 -I tests/ci/qml_warnings.py --selftest || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/qml_warnings.py "$rc" PASS
  # Sibling QML types a module's qmldir does not list (the shell would not load), on fixed samples; the tree itself is
  # checked by `just check-shell`.
  rc=0
  python3 -I tests/ci/qmldir_types.py --selftest || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/qmldir_types.py "$rc" PASS
  # Shell layering (ADR-0021, GF-087): the rules on synthetic trees; the tree itself is checked by `just check-shell`.
  rc=0
  python3 -I tests/ci/import_graph.py --selftest || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/import_graph.py "$rc" PASS
  # Only shell/lib reads GRASSFIELD_* (ADR-0019): the rule on synthetic trees; the tree is checked by `just check-shell`.
  rc=0
  python3 -I tests/ci/run_mode.py --selftest || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/run_mode.py "$rc" PASS
  # A Quickshell Socket's error handler acts only after the signal (the Quickshell 0.3.2 crash loop): the rule on samples;
  # the tree is checked by `just check-shell`.
  rc=0
  python3 -I tests/ci/socket_errors.py --selftest || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/socket_errors.py "$rc" PASS
  # No test or script hands the host to a container (--privileged, --device, host /dev or /run/systemd): the 2026-11-11 session
  # losses. The tree is checked by `just check-containers` (part of check-quick).
  rc=0
  python3 -I tests/ci/no_privileged_containers.py --selftest || rc=1
  python3 -I tests/ci/no_privileged_containers.py || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/no_privileged_containers.py "$rc" PASS
  # The generated GTK themes (ADR-0035 D-8): 36, each importing GTK's own theme, no colour function, the pairs' contrast. Their
  # rendering under Xvfb is tests/integration/gtk_themes.sh.
  rc=0
  python3 -I tests/ci/gtk_themes.py || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/gtk_themes.py "$rc" PASS
  # Symbolic glyph stroke width (ADR-0003, audit GF-124): the scanner on samples, then every shipped glyph.
  rc=0
  python3 -I tests/ci/icon_strokes.py --selftest || rc=1
  python3 -I tests/ci/icon_strokes.py || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/icon_strokes.py "$rc" PASS
  # The Grassfield mark's places (ADR-0040 IQ-B1 B): the scanner on samples, then the tree (no dialog draws it; every notice
  # names its subject's symbol).
  rc=0
  python3 -I tests/ci/mark_places.py --selftest || rc=1
  python3 -I tests/ci/mark_places.py || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/mark_places.py "$rc" PASS
  # The shipped wallpaper photographs (ADR-0040 step 2c): their one list, the pins, the PKGBUILD and the legal texts agree.
  rc=0
  python3 -I tests/ci/wallpaper_photos.py --selftest || rc=1
  python3 -I tests/ci/wallpaper_photos.py || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/wallpaper_photos.py "$rc" PASS
  # The login and boot themes (ADR-0042): the checks on planted mutants, then the themes and their package (draw only, the
  # password only to sddm.login, two-step images on the ground, nothing activated by the package).
  rc=0
  python3 -I tests/ci/login_themes.py --selftest || rc=1
  python3 -I tests/ci/login_themes.py || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/login_themes.py "$rc" PASS
  # Token source pointers (GF-095): the lint on samples, then every token of tokens.json.
  rc=0
  python3 -I tests/ci/token_sources.py || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/token_sources.py "$rc" PASS
  # Contract drift (docs vs code vs shell, qmldir vs changelog): the extractors on fixtures; the tree is `just check-contracts`.
  rc=0
  python3 -I tests/ci/gfc_parity.py --selftest || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/gfc_parity.py "$rc" PASS
  rc=0
  python3 -I tests/ci/ui_api.py --selftest || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/ui_api.py "$rc" PASS
  # The inventory gate on temporary fixtures.
  rc=0
  python3 -I tests/ci/inventory.py --selftest || rc=1
  ((rc == 0)) || status=1
  record_run logic tests/ci/inventory.py "$rc" PASS
  if [[ -x compositor/build/grassfield-compositor-tests ]]; then
    rc=0
    compositor/build/grassfield-compositor-tests || rc=1
    ((rc == 0)) || status=1
    record_run logic "compositor/tests (grassfield-compositor-tests)" "$rc" PASS
  else
    record logic "compositor/tests (grassfield-compositor-tests)" skip
  fi
  # The same suite under ASan and UBSan when it was built (compositor/build-direct.sh tests-asan; ADR-0041 step 5: the
  # mutation-fuzzed parsers run inside the compositor).
  if [[ -x compositor/build/grassfield-compositor-tests-asan ]]; then
    rc=0
    compositor/build/grassfield-compositor-tests-asan || rc=1
    ((rc == 0)) || status=1
    record_run logic "compositor/tests (grassfield-compositor-tests-asan)" "$rc" PASS
  else
    record logic "compositor/tests (grassfield-compositor-tests-asan)" skip
  fi
fi
if ((${#skips[@]})); then
  echo "summary: ${#skips[@]} check(s) SKIPPED (nothing was verified by them):"
  printf '  %s\n' "${skips[@]}"
else
  echo "summary: no check skipped"
fi

# Per-layer summary. "manual" = registered bare commands of the layer (nested session, captures), never run here.
echo "layer      pass  fail  skip  manual"
gate_layers=()
for l in "${layers_all[@]}"; do
  want "$l" || continue
  read -r p f s < <(awk -F'\t' -v l="$l" '$1 == l { c[$3]++ } END { print c["pass"] + 0, c["fail"] + 0, c["skip"] + 0 }' "$results")
  printf '%-10s %4d  %4d  %4d  %6d\n' "$l" "$p" "$f" "$s" "${manual[$l]:-0}"
  # A layer is gated only when this script can run something of it.
  runnable=0
  for k in "${!inv_runner[@]}"; do [[ ${inv_layer[$k]} == "$l" && ${inv_runner[$k]} == test.sh ]] && runnable=1; done
  # The default run only opportunistically runs the nested layer's tests/shell scripts (they SKIP without a session): not gated.
  if ((!explicit)) && [[ $l == nested ]]; then runnable=0; fi
  if ((runnable)); then gate_layers+=("$l"); else echo "note: layer $l is not gated in this run (${manual[$l]:-0} manual entries: docs/testing/README.md)"; fi
done
if ((${#gate_layers[@]})); then
  gate_csv=$(IFS=,; echo "${gate_layers[*]}")
  python3 -I tests/ci/inventory.py --results "$results" --layers "$gate_csv" || status=1
fi
exit $status
