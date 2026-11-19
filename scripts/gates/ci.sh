#!/usr/bin/env bash
# The CI job (.github/workflows/ci.yml): one throwaway `archlinux:latest` container per run, set up as the audit's toolchain
# (current Arch, so Qt and KF6 move with it; the Hyprland 0.56.2 stack the project targets, from the Arch archive; Omarchy's own
# Quickshell build, what Omarchy users run) with the PKGBUILD's makedepends and the desktop package's depends; then the offline
# checks and the offline test layers as an unprivileged user. The same commands run anywhere for a local replay (scope,
# check, test, deps, pins); only the steps that install software refuse outside a CI runner's container.
#
#   scripts/gates/ci.sh deps                  the packages the job installs from the repositories (one per line)
#   scripts/gates/ci.sh pins                  the pinned packages: "<name> <version> <sha256> <url>" per line
#   scripts/gates/ci.sh scope [BASE]          "full" when compositor/ changed since BASE (or BASE is unknown), else "quick"
#   scripts/gates/ci.sh setup [--tidy] [USER] (root, CI only) pacman set up, the packages (with clang for --tidy), USER (default
#                                             builder) created and given the checkout
#   scripts/gates/ci.sh toolkit               (root, CI only) the pinned packages, each checked against its sha256, installed
#                                             (the Hyprland stack with -dd, as on the chroot) and held (IgnorePkg)
#   scripts/gates/ci.sh check [BASE] [DIR]    `just check` when scope is full (clang-tidy over the compositor), else
#                                             `just check-quick`; log in DIR (default .dev/ci)
#   scripts/gates/ci.sh test [DIR]            `just test`; DIR/test.log and DIR/test-summary.txt (the run's summary lines)
#   scripts/gates/ci.sh --selftest            the pure parts on fixtures
#
# CI only (docs/testing/README.md, the rule update_migrate.sh uses too): CI=true, GITHUB_ACTIONS=true and RUNNER_TEMP, all three
# (CI=true alone is not enough), as root, inside a container (/.dockerenv or /run/.containerenv). There is no override: a
# machine someone works on never gets its packages changed by this script.
# Exit: the command's (check and test: just's), 2 usage or a refusal.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

# The packages pinned to the audit's toolchain (2026-11-19): the Hyprland 0.56.2 stack from the Arch archive of 2026-10-20
# (Hyprland 0.57 is not the target, docs/compat.md) and Omarchy's Quickshell 0.3.2.r7 (stable channel; the WlSessionLock fix
# of 18c95fae that the PKGBUILD's quickshell!=0.3.2 is about is in it). Each file is checked against its sha256 before pacman
# sees it; a moved or rebuilt file fails the job instead of changing the toolkit under it.
ARCHIVE=https://archive.archlinux.org/repos/2026/10/20/extra/os/x86_64
PINS=(
  "hyprutils 0.14.2-1 177dfe5d64dba65ef2f1274d84d647b12cc1bc0b808394fd556f135ac8d7e65e $ARCHIVE/hyprutils-0.14.2-1-x86_64.pkg.tar.zst"
  "hyprgraphics 0.5.1-4 c916b1fb9d7ad0e78fab2d94b0066dcdc8be0a2810be7e72df57ddf5b639fea3 $ARCHIVE/hyprgraphics-0.5.1-4-x86_64.pkg.tar.zst"
  "aquamarine 0.15.1-1 ac96995cceea132e32cafd9bf63fd6cbe3d0599ab175e82bcee85b0c7da9706c $ARCHIVE/aquamarine-0.15.1-1-x86_64.pkg.tar.zst"
  "hyprland 0.56.2-4 163bc740241880192d90027fad39ddb809b1705b04800a1f0185a58f3ce0884a $ARCHIVE/hyprland-0.56.2-4-x86_64.pkg.tar.zst"
  "quickshell 0.3.2.r7.g2b4501a-1 f9f813213597d1ee25e16860ed326e810857810460c09ee87d06bc3b655c2da1 https://pkgs.omarchy.org/stable/x86_64/quickshell-0.3.2.r7.g2b4501a-1-x86_64.pkg.tar.zst"
)
# Besides the PKGBUILD's: the toolchain (base-devel), the task runner, the secret scan (gate S1), the gate tooling (jq), the
# workflow test's YAML parser, the suites' private buses and PyGObject fakes, fonts for offscreen text, Xvfb and the image
# plugins some suites load, kio-extras (Files' thumbnails and network places), shellcheck, and a headless weston for the P3
# probe's live test (with wayland-protocols for the probe's build). The pinned Quickshell's depends come from the repositories
# (cpptrace, jemalloc, ...), as the Hyprland stack's do (installed at their current versions first, then replaced by the pins).
EXTRA=(base-devel git just gitleaks jq python python-gobject python-yaml dbus ttf-dejavu inter-font xorg-server-xvfb qt6-imageformats
  kimageformats kio-extras shellcheck weston wayland-protocols
  cpptrace jemalloc libpipewire libxcb libdrm mesa pam polkit qt6-base qt6-declarative qt6-svg qt6-wayland)

# The PKGBUILD's global makedepends and package_grassfield-desktop()'s depends, version constraints off, Grassfield's own
# packages out (built from this tree), quickshell out (pinned): the reader of scripts/gates/rc-toolkit.sh.
pkgbuild_deps() { # <PKGBUILD>
  python3 -I - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()

def array(body):
    names = []
    for line in body.splitlines():
        line = line.split("#", 1)[0]
        for word in line.split():
            name = re.split(r"[<>=!]", word.strip("'\""), maxsplit=1)[0].strip("'\"")
            if name and not name.startswith("grassfield-") and name != "quickshell" and "$" not in name:
                names.append(name)
    return names

def arrays(scope, key):
    return [array(m.group(1)) for m in re.finditer(r"^\s*%s=\((.*?)\)" % key, scope, re.S | re.M)]

first_function = re.search(r"^[A-Za-z_][A-Za-z0-9_-]*\(\)\s*\{", text, re.M)
global_scope = text[:first_function.start()] if first_function else text
desktop = re.search(r"^package_grassfield-desktop\(\)\s*\{(.*?)^\}", text, re.S | re.M)
names = set()
for found in arrays(global_scope, "makedepends"):
    names.update(found)
if desktop:
    for found in arrays(desktop.group(1), "depends"):
        names.update(found)
print("\n".join(sorted(names)))
PY
}

pins() { printf '%s\n' "${PINS[@]}"; }

deps() { { pkgbuild_deps "$root/packaging/arch/PKGBUILD" && printf '%s\n' "${EXTRA[@]}"; } | sort -u; }

# "full" when a file under compositor/ differs between BASE and HEAD, or BASE is empty, all zeros (a new branch) or unknown.
scope() { # [BASE] [repository]
  local base=${1:-} repo=${2:-$root} changed
  [[ -n $base && ! $base =~ ^0+$ ]] || { echo full; return; }
  git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null || { echo full; return; }
  changed=$(git -C "$repo" diff --name-only "$base" HEAD -- compositor/) || { echo full; return; }
  [[ -n $changed ]] && echo full || echo quick
}

# The refusal of the installing steps: a CI runner (the three markers), root, a container.
ci_only() { # <what>
  local why=""
  [[ ${CI:-} == true && ${GITHUB_ACTIONS:-} == true && -n ${RUNNER_TEMP:-} ]] || why="not a CI runner (CI=true, GITHUB_ACTIONS=true and RUNNER_TEMP, all three)"
  [[ -z $why && $(id -u) != 0 ]] && why="not root"
  [[ -z $why && ! -e /.dockerenv && ! -e /run/.containerenv ]] && why="not inside a container"
  [[ -z $why ]] && return 0
  echo "ci.sh $1: refused: $why; it installs software and runs only in the CI job's throwaway container" >&2
  return 2
}

setup() { # [--tidy] [user]
  local tidy=0 user=builder pkgs
  [[ ${1:-} == --tidy ]] && { tidy=1; shift; }
  user=${1:-builder}
  ci_only setup || return 2
  # The container has no user namespace for pacman's download sandbox (scripts/gates/rc-toolkit.sh does the same).
  grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
  pacman-key --init >/dev/null && pacman-key --populate archlinux >/dev/null || { echo "ci.sh setup: pacman-key failed" >&2; return 1; }
  mapfile -t pkgs < <(deps)
  ((tidy)) && pkgs+=(clang)
  echo "ci.sh setup: ${#pkgs[@]} packages$( ((tidy)) && echo ', clang for clang-tidy')"
  pacman -Syu --noconfirm --needed "${pkgs[@]}" || { echo "ci.sh setup: pacman -Syu failed" >&2; return 1; }
  id -u "$user" >/dev/null 2>&1 || useradd -m "$user" || return 1
  chown -R "$user:$user" "$root" || return 1
  pacman -Q qt6-base qt6-declarative kcoreaddons
}

# The pinned packages: downloaded, checked, installed, held. The Hyprland stack goes in with -dd (its current depends are
# already there from setup; Arch's newer hyprland would otherwise be refused as a downgrade's dependency), Quickshell with its
# depends resolved. IgnorePkg keeps a later -Syu from moving them.
toolkit() {
  local dir line name ver sum url files=() names=() f
  ci_only toolkit || return 2
  dir=$(mktemp -d)
  for line in "${PINS[@]}"; do
    read -r name ver sum url <<<"$line"
    f=$dir/${url##*/}
    curl -fsSL --retry 3 -o "$f" "$url" || { echo "ci.sh toolkit: cannot download $url" >&2; return 1; }
    [[ $(sha256sum "$f" | cut -d' ' -f1) == "$sum" ]] || { echo "ci.sh toolkit: $name $ver: sha256 differs from the pin: refused" >&2; return 1; }
    names+=("$name")
    [[ $name == quickshell ]] || files+=("$f")
  done
  pacman -Udd --noconfirm "${files[@]}" || return 1
  pacman -U --noconfirm "$dir"/quickshell-*.pkg.tar.zst || return 1
  sed -i "/^\[options\]/a IgnorePkg = ${names[*]}" /etc/pacman.conf
  rm -rf "$dir"
  for line in "${PINS[@]}"; do
    read -r name ver _ <<<"$line"
    [[ $(pacman -Q "$name" 2>/dev/null) == "$name $ver" ]] || { echo "ci.sh toolkit: $name is $(pacman -Q "$name" 2>&1), not $ver" >&2; return 1; }
  done
  pacman -Q qt6-base "${names[@]}"
  qs --version
}

# The environment of the checks and tests: a UTF-8 locale (Qt warns under C/POSIX, and a warning fails the suites), a runtime
# directory of the user's own.
user_env() {
  export LANG=${LANG:-C.UTF-8}
  [[ $LANG == C || $LANG == POSIX ]] && export LANG=C.UTF-8
  if [[ -z ${XDG_RUNTIME_DIR:-} ]]; then
    XDG_RUNTIME_DIR=/tmp/runtime-$(id -u)
    export XDG_RUNTIME_DIR
    mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
  fi
}

check() { # [base] [dir]
  local s dir=${2:-$root/.dev/ci} rc
  s=$(scope "${1:-}")
  mkdir -p "$dir" || return 2
  user_env
  cd "$root" || return 2
  if [[ $s == full ]]; then
    echo "ci.sh check: compositor/ changed (or no base to compare with): just check (with clang-tidy)"
    just check 2>&1 | tee "$dir/check.log"
  else
    echo "ci.sh check: compositor/ unchanged: just check-quick"
    just check-quick 2>&1 | tee "$dir/check.log"
  fi
  rc=${PIPESTATUS[0]}
  echo "check ($s): exit $rc" >"$dir/check-summary.txt"
  return "$rc"
}

test_run() { # [dir]
  local dir=${1:-$root/.dev/ci} rc
  mkdir -p "$dir" || return 2
  user_env
  cd "$root" || return 2
  just test 2>&1 | tee "$dir/test.log"
  rc=${PIPESTATUS[0]}
  summarize "$dir/test.log" "$rc" >"$dir/test-summary.txt"
  return "$rc"
}

# The summary of a `just test` log: its FAIL lines, the "summary:" block to the end (skips, the per-layer table, the inventory
# gate), and the exit code.
summarize() { # <log> <rc>
  echo "just test: exit $2"
  echo
  echo "Failures:"
  grep -a -E '^(FAIL|  FAIL)[: ]' "$1" | sed 's/^/  /' || echo "  none"
  echo
  sed -n '/^summary: /,$p' "$1"
}

selftest() {
  local fails=0 w
  expect() { if [[ $2 == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }
  w=$(mktemp -d)
  # The dependency reader on a PKGBUILD of the same shape.
  cat >"$w/PKGBUILD" <<'EOF'
pkgname=(grassfield-desktop grassfield-compositor)
makedepends=(cmake ninja  # a comment
             quickshell 'qt6-tools' grassfield-icons "lua")
package_grassfield-desktop() {
  depends=(hyprland 'quickshell!=0.3.2' kio>=6 grassfield-hold
           libcups)
}
package_grassfield-compositor() {
  depends=(not-this-one)
}
EOF
  expect "deps: makedepends and the desktop's depends; quickshell, grassfield-* and constraints out" \
    "$(pkgbuild_deps "$w/PKGBUILD" | tr '\n' ' ')" "cmake hyprland kio libcups lua ninja qt6-tools "
  expect "deps of this tree: the PKGBUILD's packages are there, quickshell is not" \
    "$(deps | grep -c -x -E 'cmake|qt6-declarative|kio|gtest|just|gitleaks|quickshell')" 6
  # The scope: a throwaway repository, one commit outside compositor/, one inside.
  git -C "$w" init -q -b main repo && git -C "$w/repo" -c user.name=t -c user.email=t@localhost commit -q --allow-empty -m a
  local a b c
  a=$(git -C "$w/repo" rev-parse HEAD)
  mkdir -p "$w/repo/apps" "$w/repo/compositor"
  echo x >"$w/repo/apps/f" && git -C "$w/repo" add -A && git -C "$w/repo" -c user.name=t -c user.email=t@localhost commit -q -m b
  b=$(git -C "$w/repo" rev-parse HEAD)
  expect "scope: only apps/ changed: quick" "$(scope "$a" "$w/repo")" quick
  echo y >"$w/repo/compositor/g" && git -C "$w/repo" add -A && git -C "$w/repo" -c user.name=t -c user.email=t@localhost commit -q -m c
  c=$(git -C "$w/repo" rev-parse HEAD)
  expect "scope: compositor/ changed: full" "$(scope "$b" "$w/repo")" full
  expect "scope: compositor/ changed earlier in the range: full" "$(scope "$a" "$w/repo")" full
  expect "scope: nothing changed: quick" "$(scope "$c" "$w/repo")" quick
  expect "scope: no base: full" "$(scope "" "$w/repo")" full
  expect "scope: a new branch (all zeros): full" "$(scope 0000000000000000000000000000000000000000 "$w/repo")" full
  expect "scope: an unknown base: full" "$(scope 1234567890123456789012345678901234567890 "$w/repo")" full
  # The installing steps refuse outside the CI container, whatever else is set.
  expect "setup refuses on a bare machine" "$(env -u CI -u GITHUB_ACTIONS -u RUNNER_TEMP bash "$0" setup 2>&1; echo "rc $?")" \
    "ci.sh setup: refused: not a CI runner (CI=true, GITHUB_ACTIONS=true and RUNNER_TEMP, all three); it installs software and runs only in the CI job's throwaway container"$'\n'"rc 2"
  expect "setup refuses CI=true alone" "$(env -u GITHUB_ACTIONS -u RUNNER_TEMP CI=true bash "$0" setup >/dev/null 2>&1; echo $?)" 2
  expect "setup refuses CI and GITHUB_ACTIONS without RUNNER_TEMP" "$(env -u RUNNER_TEMP CI=true GITHUB_ACTIONS=true bash "$0" setup >/dev/null 2>&1; echo $?)" 2
  if [[ $(id -u) != 0 ]]; then
    expect "setup refuses a CI runner's markers without root" "$(CI=true GITHUB_ACTIONS=true RUNNER_TEMP=/tmp bash "$0" setup 2>&1 | grep -c 'refused: not root')" 1
  fi
  expect "pins: the Hyprland 0.56.2 stack and Omarchy's Quickshell, each with a sha256 and an https address" \
    "$(pins | awk '$3 ~ /^[0-9a-f]{64}$/ && $4 ~ /^https:\/\/[^ ]+\.pkg\.tar\.zst$/ { print $1, $2 }' | tr '\n' ';')" \
    "hyprutils 0.14.2-1;hyprgraphics 0.5.1-4;aquamarine 0.15.1-1;hyprland 0.56.2-4;quickshell 0.3.2.r7.g2b4501a-1;"
  expect "pins: Quickshell is not the refused 0.3.2 tag" "$(pins | awk '$1 == "quickshell" && $2 !~ /^0\.3\.2-/ { print "ok" }')" ok
  expect "toolkit refuses on a bare machine" "$(env -u CI bash "$0" toolkit >/dev/null 2>&1; echo $?)" 2
  # The summary of a test log.
  printf 'x\nFAIL: tests/shell/a.sh\n  FAIL inner\nsummary: 1 check(s) SKIPPED\n  SKIP: y\nlayer pass\nlogic 3\n' >"$w/test.log"
  expect "summary: the failures, then the summary block to the end" "$(summarize "$w/test.log" 1 | tr '\n' '|')" \
    "just test: exit 1||Failures:|  FAIL: tests/shell/a.sh|    FAIL inner||summary: 1 check(s) SKIPPED|  SKIP: y|layer pass|logic 3|"
  rm -rf "$w"
  if ((fails == 0)); then echo "ci.sh selftest: PASS"; else echo "ci.sh selftest: $fails failure(s)"; return 1; fi
}

cmd=${1:-}
shift || true
case $cmd in
  deps) deps ;;
  pins) pins ;;
  scope) scope "${1:-}" ;;
  setup) setup "$@" ;;
  toolkit) toolkit ;;
  check) check "$@" ;;
  test) test_run "$@" ;;
  --selftest) selftest ;;
  -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d;s/^# \{0,1\}//' ;;
  *) echo "usage: ci.sh deps|pins|scope|setup|toolkit|check|test|--selftest (--help)" >&2; exit 2 ;;
esac
