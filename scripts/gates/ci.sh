#!/usr/bin/env bash
# The CI job (.github/workflows/ci.yml): one throwaway `archlinux:latest` container per run, set up as the audit's toolchain
# (current Arch, so Qt and KF6 move with it; the Hyprland 0.56.2 stack the project targets, from the Arch archive; Omarchy's own
# Quickshell build, what Omarchy users run) with the PKGBUILD's makedepends and the desktop package's depends; then the offline
# checks and the offline test layers as an unprivileged user. The same commands run anywhere for a local replay (scope,
# check, test, deps, pins); only the steps that install software refuse outside a CI runner's container.
#
#   scripts/gates/ci.sh deps                  the packages the job installs from the repositories (one per line)
#   scripts/gates/ci.sh pins                  the pinned packages: "<name> <version> <sha256> <url>" per line
#   scripts/gates/ci.sh compat                the shared objects of an older package added beside the installed one (libjxl 0.12 for
#                                             Hyprland): "<name> <version> <sha256> <url> <members>" per line
#   scripts/gates/ci.sh scope [BASE]         "full" when compositor/ changed since BASE (or BASE is unknown), else "quick"
#   scripts/gates/ci.sh setup [--tidy] [USER] (root, CI only) pacman set up, the packages (with clang for --tidy), USER (default
#                                             builder) created and given the checkout
#   scripts/gates/ci.sh toolkit               (root, CI only) the pinned packages, each checked against its sha256, installed
#                                             (the Hyprland stack with -dd, as on the chroot) and held (IgnorePkg)
#   scripts/gates/ci.sh check [BASE] [DIR]    `just check` when scope is full (clang-tidy over the compositor), else
#                                             `just check-quick`; log in DIR (default .dev/ci)
#   scripts/gates/ci.sh test [DIR [ARGS...]]  `just test ARGS` (scripts/dev/test.sh: --layer, --skip-gtest, --gtest-shard I/N);
#                                             DIR/test.log and DIR/test-summary.txt (the run's summary lines)
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
# The snapshot's index lists only the databases; the package files are under /packages/<initial>/<name>/.
PKGS=https://archive.archlinux.org/packages
# Hyprland 0.56.2-4 and hyprgraphics 0.5.1-4 were built against libjxl.so.0.12 (the snapshot's libjxl 0.12.0-1) and the rolling
# repositories moved on to 0.13.0-1 (libjxl.so.0.13): without 0.12 Hyprland does not start ("error while loading shared
# libraries: libjxl.so.0.12", main CI run 45378817729). The package itself is NOT downgraded: current ffmpeg, glycin, sdl2_image,
# opencv and webkit are built against 0.13 and need it. Only the 0.12 shared objects are added beside it (COMPAT: the files
# usr/lib/libjxl*.so.0.12*, whose names do not clash with 0.13's), checked against the package's sha256. Nothing else of the
# stack had drifted (checked against the 2026-11-24 extra.files: glslang 16, re2 11, display-info 3, lua 5.5 ... are current);
# the toolkit step compares the unresolved libraries of every executable and shared object before and after the pins and
# fails by name on a new one, so a later drift fails there and not in seven tests.
COMPAT=(
  "libjxl 0.12.0-1 a4e0f65e8ba3a2da1cc348aad4f7f8aee1b504b824a64838fb3d9b2f75cc9449 $PKGS/l/libjxl/libjxl-0.12.0-1-x86_64.pkg.tar.zst usr/lib/libjxl*.so.0.12*"
)
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
# The suites' own needs: node (the desktop clipboard probe), foot (the terminal entries and theme), and an Omarchy machine's
# fonts for the session fontconfig test (Noto with its emoji and CJK fonts, Liberation and the URW fonts of the metric aliases,
# JetBrains Mono Nerd Font, Omarchy's monospace).
EXTRA=(base-devel git just gitleaks jq python python-gobject python-yaml dbus ttf-dejavu inter-font xorg-server-xvfb qt6-imageformats
  kimageformats kio-extras shellcheck weston wayland-protocols nodejs foot
  noto-fonts noto-fonts-emoji noto-fonts-cjk ttf-liberation gsfonts ttf-jetbrains-mono-nerd
  cpptrace jemalloc libpipewire libxcb libdrm mesa pam polkit qt6-base qt6-declarative qt6-svg qt6-wayland)
# The locales the suites sort and translate with: en_US (the collation the expectations are written in, the owner's) and fr_FR
# (the French runs).
LOCALES=(en_US.UTF-8 fr_FR.UTF-8)

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
compat() { printf '%s\n' "${COMPAT[@]}"; }

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
  # The archlinux image leaves out the locale sources and the translations (NoExtract): the packages go in whole, as on a
  # machine, and glibc once more for its locale sources.
  sed -i '/^NoExtract/d' /etc/pacman.conf
  { pacman-key --init >/dev/null && pacman-key --populate archlinux >/dev/null; } || { echo "ci.sh setup: pacman-key failed" >&2; return 1; }
  mapfile -t pkgs < <(deps)
  ((tidy)) && pkgs+=(clang)
  echo "ci.sh setup: ${#pkgs[@]} packages$( ((tidy)) && echo ', clang for clang-tidy')"
  pacman -Syu --noconfirm --needed "${pkgs[@]}" || { echo "ci.sh setup: pacman -Syu failed" >&2; return 1; }
  pacman -S --noconfirm glibc || { echo "ci.sh setup: glibc reinstall failed" >&2; return 1; }
  locales || return 1
  # A machine has an identity (D-Bus and the suites' private buses read it); the image's is empty.
  if ! grep -qxE '[0-9a-f]{32}' /etc/machine-id 2>/dev/null; then
    { dbus-uuidgen >/etc/machine-id.new && mv /etc/machine-id.new /etc/machine-id; } || { echo "ci.sh setup: no machine-id" >&2; return 1; }
  fi
  id -u "$user" >/dev/null 2>&1 || useradd -m "$user" || return 1
  chown -R "$user:$user" "$root" || return 1
  workdir_copy "$user" || return 1
  pacman -Q qt6-base qt6-declarative kcoreaddons
}

# The locales of LOCALES generated (/etc/locale.gen lists them commented out).
locales() {
  local l
  for l in "${LOCALES[@]}"; do
    grep -qx "$l UTF-8" /etc/locale.gen || sed -i "s/^#${l/./\\.} UTF-8/$l UTF-8/" /etc/locale.gen
    grep -qx "$l UTF-8" /etc/locale.gen || echo "$l UTF-8" >>/etc/locale.gen
  done
  locale-gen >/dev/null || { echo "ci.sh setup: locale-gen failed" >&2; return 1; }
  for l in "${LOCALES[@]}"; do
    locale -a | grep -qix "${l%.UTF-8}.utf8" || { echo "ci.sh setup: locale $l missing after locale-gen" >&2; return 1; }
  done
}

# The checks and tests run from a copy of the checkout in the user's home, as on a machine: the suites' scratch directories
# are below the checkout (.dev/test-tmp.*), and the shell reads images and icons only below the home and the data
# directories (notification images, theme icon files: shell/services/image-copy.py). The runner's workspace keeps the logs
# (ci.sh check and test take it as DIR).
workdir_of() { # <user>: <home>/grassfield
  local home
  home=$(getent passwd "$1" | cut -d: -f6)
  [[ $home == /* ]] || return 1
  echo "$home/grassfield"
}
workdir_copy() { # <user>
  local dest
  dest=$(workdir_of "$1") || { echo "ci.sh setup: $1 has no home" >&2; return 1; }
  [[ $(cd "$root" && pwd -P) != "$dest" ]] || return 0
  rm -rf -- "$dest" && mkdir -p "$dest" && cp -a -- "$root/." "$dest/" && chown -R "$1:$1" "$dest" || return 1
  echo "ci.sh setup: the checkout copied to $dest (the checks and tests run there)"
}

# The pinned packages: downloaded, checked, installed, held. The Hyprland stack goes in with -dd (its current depends are
# already there from setup; Arch's newer hyprland would otherwise be refused as a downgrade's dependency), Quickshell with its
# depends resolved. IgnorePkg keeps a later -Syu from moving them.
toolkit() {
  local dir line name ver sum url files=() names=() f
  ci_only toolkit || return 2
  dir=$(mktemp -d)
  unresolved_libs >"$dir/unresolved.before"
  for line in "${COMPAT[@]}"; do
    read -r name ver sum url members <<<"$line"
    f=$dir/${url##*/}
    curl -fsSL --retry 3 -o "$f" "$url" || { echo "ci.sh toolkit: cannot download $url" >&2; return 1; }
    [[ $(sha256sum "$f" | cut -d' ' -f1) == "$sum" ]] || { echo "ci.sh toolkit: $name $ver: sha256 differs from the pin: refused" >&2; return 1; }
    # shellcheck disable=SC2086
    tar --zstd -xf "$f" -C / --wildcards $members || { echo "ci.sh toolkit: cannot extract $members from $name $ver" >&2; return 1; }
    echo "ci.sh toolkit: $name $ver: $members added beside the installed $(pacman -Q "$name")"
  done
  ldconfig || return 1
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
  for line in "${PINS[@]}"; do
    read -r name ver _ <<<"$line"
    [[ $(pacman -Q "$name" 2>/dev/null) == "$name $ver" ]] || { echo "ci.sh toolkit: $name is $(pacman -Q "$name" 2>&1), not $ver" >&2; return 1; }
  done
  pacman -Q qt6-base "${names[@]}"
  qs --version
  # The pins and the compat objects leave nothing unresolved that was not before (a repository can move a soname under the
  # pinned stack, or a pin can take one from a package), and the compositor itself has none.
  local after new
  after=$(unresolved_libs)
  new=$(comm -13 "$dir/unresolved.before" <(printf '%s\n' "$after" | sed '/^$/d'))
  [[ -z $new ]] || { echo "ci.sh toolkit: unresolved libraries the pins brought (path: library):" >&2; echo "$new" >&2; return 1; }
  if grep -E '^/usr/(s?bin/Hyprland|lib/libhypr|lib/libaquamarine)' <<<"$after"; then
    echo "ci.sh toolkit: the Hyprland stack has unresolved libraries" >&2
    return 1
  fi
  /usr/bin/Hyprland --version | head -1
  rm -rf "$dir"
}

# "<path>: <library>" for each library an ELF file under /usr/bin, /usr/sbin and /usr/lib cannot resolve (ldd), sorted. A plugin
# that needs an optional library is the same before and after the pins, which is what toolkit compares.
unresolved_libs() {
  python3 -I -c '
import os, re, subprocess
from concurrent.futures import ThreadPoolExecutor
files = []
for top in ("/usr/bin", "/usr/sbin", "/usr/lib"):
    for base, _dirs, names in os.walk(top):
        for n in names:
            p = os.path.join(base, n)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            try:
                with open(p, "rb") as f:
                    if f.read(4) != b"\x7fELF":
                        continue
            except OSError:
                continue
            files.append(p)
def check(p):
    r = subprocess.run(["ldd", p], capture_output=True, text=True)
    return ["%s: %s" % (p, m.group(1)) for m in re.finditer(r"^\s*(\S+) => not found", r.stdout, re.M)]
with ThreadPoolExecutor(8) as ex:
    out = sorted({line for lines in ex.map(check, files) for line in lines})
print("\n".join(out))
'
}

# The environment of the checks and tests: the owner's locale, en_US.UTF-8 (the suites' sorted expectations are written in its
# collation; Qt warns under C/POSIX, and a warning fails the suites), C.UTF-8 only where en_US is not generated (with a
# warning), and a runtime directory of the user's own.
user_env() {
  unset LC_ALL LC_COLLATE LC_CTYPE LC_MESSAGES LANGUAGE
  if locale -a 2>/dev/null | grep -qix 'en_US.utf8'; then
    export LANG=en_US.UTF-8
  else
    echo "ci.sh: en_US.UTF-8 is not generated here: C.UTF-8 (sorted expectations may differ)" >&2
    export LANG=C.UTF-8
  fi
  if [[ -z ${XDG_RUNTIME_DIR:-} ]]; then
    XDG_RUNTIME_DIR=/tmp/runtime-$(id -u)
    export XDG_RUNTIME_DIR
    mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
  fi
}

# The container's PID 1 is the runner's idle process, which never reaps: a process whose parent died is handed to it and stays a
# zombie (it keeps a /proc entry and `kill -0` still succeeds), so the suites' "it died with its parent" checks (stack_helper,
# capture, terminal_theme, the Store's terminal helper) read a dead process as alive for ever. On a machine systemd reaps. The
# command runs as the child of a subreaper (PR_SET_CHILD_SUBREAPER) that adopts and reaps the orphans; its exit status is the
# command's (128+N when a signal N ended it), SIGINT and SIGTERM are passed on.
reaped() { # <command> [args...]
  python3 -I -c '
import ctypes, os, signal, sys
if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
    sys.exit("ci.sh: PR_SET_CHILD_SUBREAPER refused")
main = os.fork()
if main == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
for sig in (signal.SIGINT, signal.SIGTERM):
    signal.signal(sig, lambda s, _frame: os.kill(main, s))
code = 1
while True:
    try:
        pid, status = os.waitpid(-1, 0)
    except InterruptedError:
        continue
    except ChildProcessError:
        break
    if pid == main:
        code = os.waitstatus_to_exitcode(status)
        break
sys.exit(code if code >= 0 else 128 - code)
' "$@"
}

check() { # [base] [dir]
  local s dir=${2:-$root/.dev/ci} rc
  s=$(scope "${1:-}")
  mkdir -p "$dir" || return 2
  user_env
  cd "$root" || return 2
  if [[ $s == full ]]; then
    echo "ci.sh check: compositor/ changed (or no base to compare with): just check (with clang-tidy)"
    reaped just check 2>&1 | tee "$dir/check.log"
  else
    echo "ci.sh check: compositor/ unchanged: just check-quick"
    reaped just check-quick 2>&1 | tee "$dir/check.log"
  fi
  rc=${PIPESTATUS[0]}
  echo "check ($s): exit $rc" >"$dir/check-summary.txt"
  return "$rc"
}

test_run() { # [dir [test.sh arguments...]]
  local dir=${1:-$root/.dev/ci} rc
  shift || true
  mkdir -p "$dir" || return 2
  user_env
  cd "$root" || return 2
  reaped just test "$@" 2>&1 | tee "$dir/test.log"
  rc=${PIPESTATUS[0]}
  summarize "$dir/test.log" "$rc" "$*" >"$dir/test-summary.txt"
  return "$rc"
}

# The summary of a `just test` log: its FAIL lines, the "summary:" block to the end (skips, the per-layer table, the inventory
# gate), and the exit code.
summarize() { # <log> <rc> [test.sh arguments]
  echo "just test${3:+ $3}: exit $2"
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
  expect "compat: libjxl 0.12 objects only, with a sha256, an https address and the 0.12 soname pattern" \
    "$(compat | awk '$3 ~ /^[0-9a-f]{64}$/ && $4 ~ /^https:\/\/[^ ]+\.pkg\.tar\.zst$/ && $5 == "usr/lib/libjxl*.so.0.12*" { print $1, $2 }' | tr '\n' ';')" "libjxl 0.12.0-1;"
  expect "compat: libjxl is not also a pin (the installed 0.13 stays for ffmpeg, glycin, opencv, webkit)" "$(pins | grep -c '^libjxl ')" 0
  expect "toolkit refuses on a bare machine" "$(env -u CI bash "$0" toolkit >/dev/null 2>&1; echo $?)" 2
  # The environment of check and test: en_US.UTF-8 where it is generated (LC_ALL and the other overrides cleared), a runtime
  # directory; the copy of the checkout lives in the user's home.
  local want_lang=C.UTF-8
  locale -a 2>/dev/null | grep -qix 'en_US.utf8' && want_lang=en_US.UTF-8
  expect "user_env: LANG is en_US.UTF-8 where generated, LC_ALL cleared, a runtime directory" \
    "$(LC_ALL=C LANG=fr_FR.UTF-8 XDG_RUNTIME_DIR="$w/rt" bash -c '. "$1" --source-only; user_env 2>/dev/null; echo "$LANG|${LC_ALL-unset}|$XDG_RUNTIME_DIR"' _ "$0")" \
    "$want_lang|unset|$w/rt"
  expect "workdir: <home of the user>/grassfield" "$(workdir_of "$(id -un)")" "$(getent passwd "$(id -un)" | cut -d: -f6)/grassfield"
  # The subreaper: the command's exit status (and 128+N for a signal) comes back, an orphan is adopted by it (its parent is the
  # subreaper, the command's own parent), not left to PID 1.
  expect "reaped: the command's exit status is kept" "$(reaped bash -c 'exit 7' >/dev/null 2>&1; echo $?)" 7
  expect "reaped: a signalled command is 128+N" "$(reaped bash -c 'kill -TERM $$' >/dev/null 2>&1; echo $?)" 143
  expect "reaped: an orphan's new parent is the subreaper" \
    "$(reaped bash -c '(sleep 1 & echo $! >"$1"); sleep 0.3; echo "$(awk "/^PPid/{print \$2}" /proc/$(cat "$1")/status) $PPID"' _ "$w/orphan" | awk '$1 == $2 { print "adopted" }')" adopted
  # The summary of a test log.
  printf 'x\nFAIL: tests/shell/a.sh\n  FAIL inner\nsummary: 1 check(s) SKIPPED\n  SKIP: y\nlayer pass\nlogic 3\n' >"$w/test.log"
  expect "summary: the failures, then the summary block to the end" "$(summarize "$w/test.log" 1 | tr '\n' '|')" \
    "just test: exit 1||Failures:|  FAIL: tests/shell/a.sh|    FAIL inner||summary: 1 check(s) SKIPPED|  SKIP: y|layer pass|logic 3|"
  rm -rf "$w"
  if ((fails == 0)); then echo "ci.sh selftest: PASS"; else echo "ci.sh selftest: $fails failure(s)"; return 1; fi
}

# Sourced by the selftest for its functions only.
[[ ${1:-} == --source-only ]] && return 0
cmd=${1:-}
shift || true
case $cmd in
  deps) deps ;;
  pins) pins ;;
  compat) compat ;;
  scope) scope "${1:-}" ;;
  setup) setup "$@" ;;
  toolkit) toolkit ;;
  check) check "$@" ;;
  test) test_run "$@" ;;
  --selftest) selftest ;;
  -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d;s/^# \{0,1\}//' ;;
  *) echo "usage: ci.sh deps|pins|compat|scope|setup|toolkit|check|test|--selftest (--help)" >&2; exit 2 ;;
esac
