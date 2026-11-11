# Grassfield task runner (master-prompt Appendix A "Commands").
# Graphical recipes only ever target the nested instance recorded in .dev/.

set shell := ["bash", "-euo", "pipefail", "-c"]

qtbin := "/usr/lib/qt6/bin"

default:
    @just --list

# All offline checks (L0).
check: check-config check-schema check-cmake check-shell check-shaders check-i18n check-scripts check-containers check-inventory check-contracts check-contrast check-literals check-upstream check-version check-licenses check-tidy check-secrets

# Every offline check except clang-tidy, for a tree that leaves compositor/ unchanged (`just check` runs them all). One
# recipe on purpose: `just check-schema check-shell` would pass check-shell to check-schema as a file argument.
check-quick: check-config check-schema check-cmake check-shell check-shaders check-i18n check-scripts check-containers check-inventory check-contracts check-contrast check-literals check-upstream check-version check-licenses check-secrets

# clang-tidy over the compositor with the project's config (gate Q1); a passing full run is stamped, an unchanged tree is "up to date" (--force: scripts/dev/tidy.sh --force).
check-tidy:
    scripts/dev/tidy.sh

# One version source: every consumer agrees with the VERSION file (D-11).
check-version:
    scripts/dev/check-version.sh

# Licence notices: Omarchy's LICENSE verbatim, license= arrays, shipped notices (GF-014).
check-licenses:
    scripts/dev/check-licenses.sh

# Validate the Grassfield Hyprland Lua config with the installed Hyprland. Verify mode inherits this environment, a
# running Hyprland's signature included: it runs with a scratch runtime directory and a signature of the installed
# Hyprland's commit that no instance has, and fails if the session's loader wrote a runtime note there (it must not in
# verify mode, config/hypr/grassfield/compositor.lua verifying()). session.lua is checked a second time without Omarchy
# (OMARCHY_PATH=/nonexistent): when the Omarchy include fails, Grassfield's defaults must still load (ADR-0001).
check-config:
    rt=$(mktemp -d); trap 'rm -rf "$rt"' EXIT; \
    [[ -r /usr/include/hyprland/src/version.h ]] || { echo "check-config: no Hyprland headers (/usr/include/hyprland/src/version.h): install hyprland" >&2; exit 1; }; \
    commit=$(sed -n 's/^#define[[:space:]]*GIT_COMMIT_HASH[[:space:]]*"\([0-9a-f]*\)".*/\1/p' /usr/include/hyprland/src/version.h); \
    for run in dev session session:/nonexistent; do \
      cfg=${run%%:*}; omarchy=; [[ $run == *:* ]] && omarchy=${run#*:}; \
      out=$(env ${omarchy:+OMARCHY_PATH=$omarchy} XDG_RUNTIME_DIR=$rt HYPRLAND_INSTANCE_SIGNATURE=${commit:-0000000}_0_verify \
        GRASSFIELD_CONFIG_DIR={{justfile_directory()}}/config/hypr Hyprland --verify-config --config config/hypr/$cfg.lua 2>&1 \
        | sed -n '/Config parsing result/,$p' || true); \
      printf '%s\n' "$out"; \
      printf '%s\n' "$out" | grep -qx 'config ok' || { echo "check-config: $cfg.lua${omarchy:+ with OMARCHY_PATH=$omarchy}: no 'config ok'" >&2; exit 1; }; \
    done; \
    if compgen -G "$rt/grassfield-compositor-*" >/dev/null; then \
      echo "check-config: verify mode wrote a compositor runtime note" >&2; exit 1; \
    fi

# Validate the default grassfield.json (and any given files) against the versioned schema.
check-schema *files:
    python3 -I scripts/dev/check-schema.py {{files}}

# The apps' CMake definitions configure as the PKGBUILD configures them (scripts/dev/check-cmake.sh; --build builds them).
check-cmake:
    scripts/dev/check-cmake.sh

# The same, and every target is built (minutes; run it before a release or after changing a CMakeLists.txt or a Qt module request).
check-cmake-build:
    scripts/dev/check-cmake.sh --build

# Lint QML (0 warnings required in changed files, gate Q1).
check-shell:
    scripts/dev/qmllint.sh
    python3 -I tests/ci/qmldir_types.py --selftest
    python3 -I tests/ci/qmldir_types.py
    python3 -I tests/ci/ui_names.py --selftest
    python3 -I tests/ci/ui_names.py
    python3 -I tests/ci/desktop_names.py --selftest
    python3 -I tests/ci/desktop_names.py
    python3 -I tests/ci/import_graph.py --selftest
    python3 -I tests/ci/import_graph.py
    python3 -I tests/ci/run_mode.py --selftest
    python3 -I tests/ci/run_mode.py
    python3 -I tests/ci/socket_errors.py --selftest
    python3 -I tests/ci/socket_errors.py

# The committed .qsb shaders are current with their .frag sources (rebuild: scripts/dev/build-shaders.sh).
check-shaders:
    scripts/dev/build-shaders.sh --check

# Gate I1: every visible string is in qsTr(); the fr catalog is current and complete.
check-i18n:
    python3 -I scripts/dev/check-i18n.py

# Regenerate translations/grassfield_fr.ts after adding or changing qsTr() strings.
i18n-update:
    scripts/dev/i18n-update.sh

# Every test is registered in tests/inventory.json with exactly one layer (static, cheap; docs/testing/README.md).
check-inventory:
    python3 -I tests/ci/inventory.py

# The gfc/1 table in ADR-0007 = the compositor code = what the shell reads; every qmldir change of Grassfield.Ui has a changelog line.
check-contracts:
    python3 -I tests/ci/gfc_parity.py --selftest
    python3 -I tests/ci/gfc_parity.py
    python3 -I tests/ci/ui_api.py --selftest
    python3 -I tests/ci/ui_api.py

# A new secondary, danger, derived or faded text colour without a role in tests/visual/contrast-roles.json fails here, not
# only in scripts/dev/test.sh (ADR-0039 step 0b).
# Gate A2 from the tokens: every contrast role meets its threshold and the role table matches the QML.
check-contrast:
    python3 -I tests/visual/test_contrast_tokens.py

# Rule 6 of ADR-0039 (steps 2 to 5): a radius, font size, opacity, scale, geometry value, animation duration or colour written
# as a literal in the QML fails, also as a ternary's branch, an offset to a token, a literal alpha or a named colour (Timer
# intervals are logic; reviewed exceptions: the allowlist in the script or `// literal-ok <kind>: <reason>`).
# Tokens only: no literal design value in the QML of ui/Grassfield, shell (security included) and apps.
check-literals:
    python3 -I tests/ci/qml_literals.py --selftest
    python3 -I tests/ci/qml_literals.py

# The upstream Omarchy files the security forks derive from are unchanged (docs/upstream/omarchy.lock, GF-031); after a
# review of an upstream change: scripts/dev/upstream-drift.sh --update.
check-upstream:
    scripts/dev/upstream-drift.sh

# Secret scan of the whole history (gate S1).
check-secrets:
    gitleaks detect --source . --no-banner --redact

# Syntax-check shell scripts.
check-scripts:
    for f in scripts/dev/*.sh scripts/gates/*.sh tests/*/*.sh tests/visual/scenarios/*.sh packaging/install/*.sh.in; do bash -n "$f"; done

# No test or script hands the host to a container: no --privileged, --device, host /dev or /run/systemd mount (the 2026-11-10 session losses).
check-containers:
    python3 -I tests/ci/no_privileged_containers.py --selftest
    python3 -I tests/ci/no_privileged_containers.py

# Render the public installation script and its checksum into DIR (ADR-0043). Refuses while repository.conf holds the
# placeholder host or an empty fingerprint (O8, O11): nothing is published by this recipe.
render-install dir="build/install":
    python3 -I packaging/install/render.py --conf packaging/pacman/repository.conf --template packaging/install/grassfield-install.sh.in --out {{dir}}

# Run any gate command and keep a dated report (commit, build id, exit code, log path) in .dev/gate-runs/ (GF-036), e.g.
# `just gate check just check`, `just gate nested-overview tests/compositor/overview.sh`. Exits with the command's code.
gate name *cmd:
    scripts/dev/gate-run.sh {{name}} -- {{cmd}}

# Copy the gate reports of .dev/gate-runs/ into docs/testing/runs/ (the repository keeps them); review, then commit.
gate-archive:
    scripts/dev/gate-run.sh --archive

# Omarchy private paths, commands and units Grassfield relies on (docs/compat.md); --require fails without Omarchy.
check-omarchy *args:
    scripts/dev/omarchy-compat.sh {{args}}

# Offscreen unit tests (QML TestCase) and compositor unit tests when built.
test:
    scripts/dev/test.sh

# Security gates L1 (+ DT-21 graceful exit) and L4 (+ DT-05 screen share, D-4 lid and display off), each on a fresh
# nested session (ask). Bare, outside the sandbox only: inside it the scripts refuse (PID namespace). Every nested session
# it opens ends locked and is stopped. L2 (tests/security/l2_wrong_password.sh) and L5 stay owner steps.
test-security-nested:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    scripts/dev/nested-up.sh || exit 2
    tests/security/reload_locked.sh || rc=1
    scripts/dev/nested-down.sh
    scripts/dev/nested-up.sh || exit 2
    tests/security/lock_privacy.sh || rc=1
    scripts/dev/nested-down.sh
    exit $rc

# Gate A2 for the icon modes on a GPU scene graph, as a client of the nested session (ask).
test-icons:
    tests/visual/icon-a2.sh

# Nested dev session (ask).
nested-up:
    scripts/dev/nested-up.sh

nested-down:
    scripts/dev/nested-down.sh

# Restart grassfield-shell inside the nested instance (ask).
shell-run:
    scripts/dev/shell-run.sh

# Screenshot of the nested output → .dev/shots/<name>.png (ask).
shot name:
    scripts/dev/shot.sh {{name}}

# Visual regression on GF-REF vs tests/visual/baselines (reference machine, nested session; ask). Flags: --update --determinism --only a,b --lang en|fr|both
visual *args:
    tests/visual/run.sh {{args}}

# Gate A2 contrast table on 5 worst-case wallpapers x light/dark x transparency 0.25/0.6 (nested session; ask).
contrast *args:
    tests/visual/contrast.sh {{args}}

# Nested smoke set (about 20 s) on the running nested session of this tree; skips without one.
smoke-nested:
    tests/shell/smoke_nested.sh

# Scripted nested scenario → tests/visual/scenarios/<name>.sh (ask).
scenario name:
    tests/visual/scenarios/{{name}}.sh

# Scripted pointer in the nested instance, e.g. `just pointer output GF-REF abs 960 1050 click` (ask).
pointer *args:
    scripts/dev/pointer.sh {{args}}

# Compose the grassfield-icons theme (pinned MacTahoe + Pebble, GitHub) into .dev/share/icons (dev sessions only).
icons *args:
    scripts/dev/icons.sh {{args}}

# Build the Grassfield cursor theme into .dev/share/icons/grassfield-cursors (hyprcursor + XCursor).
cursors *args:
    branding/cursors/build.sh {{args}}

# Build the compositor plugin against the installed Hyprland headers.
plugin-build:
    cmake -S compositor -B compositor/build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
    cmake --build compositor/build

# The local CI equivalent (D-6): a clean build of a `git archive` of HEAD with `just check` (incl. tidy), `just test`, coverage, gitleaks and the plugin build. Bare command. Flags: --rc-headers ROOT --rc --keep --only steps
release-check *args:
    scripts/gates/release-check.sh {{args}}

# Gate Q3: gcov line coverage of the compositor core and the menu bridge logic (>= 70 %).
coverage *args:
    scripts/gates/coverage.sh {{args}}

# Gate P1: idle CPU of grassfield-shell + menu bridge from /proc, e.g. `just gate-idle --nested` or `just gate-idle --real` (read only; bare command).
gate-idle *args:
    scripts/gates/idle-cpu.sh {{args}}

# Gate P2: resident memory against the omarchy-shell baseline, e.g. `just gate-rss --real --baseline-mb 458` (bare command).
gate-rss *args:
    scripts/gates/rss.sh {{args}}

# Gate P3: frame pacing while the Dock magnifies, the Overview and Apps open/close, in the nested session (reference machine; bare command).
gate-frames *args:
    scripts/gates/frame-pacing.sh {{args}}

# Gate P5: session start to "grassfield-shell: usable", from the user journal (read only; bare command).
gate-startup *args:
    scripts/gates/session-start.sh {{args}}

# GF-013: About, pacman, the plugin (`hyprctl grassfield`) and the menu bridge report the VERSION file's version: `just gate-version --nested` or `--installed` (bare command).
gate-version *args:
    scripts/gates/version-agreement.sh {{args}}

# The rc-channel gate (ADR-0041 step 2c; T-5, T-10, C3): the tree's QML lint, offscreen suites and plugin build on Omarchy's rc toolkit in a throwaway container (bare; docker). Flags: --only lint,test,plugin --channel rc|stable --logs DIR
gate-rc *args:
    scripts/gates/rc-toolkit.sh {{args}}

# Off-machine copy: a verified git bundle of the whole repository into DIR (an external disk; GF-034).
backup dir:
    scripts/dev/backup.sh {{dir}}

# Load/unload the plugin in the NESTED instance via scripts/nestctl (ask).
plugin-load:
    scripts/nestctl plugin load {{justfile_directory()}}/compositor/build/grassfield-compositor.so

plugin-unload:
    scripts/nestctl plugin unload {{justfile_directory()}}/compositor/build/grassfield-compositor.so
