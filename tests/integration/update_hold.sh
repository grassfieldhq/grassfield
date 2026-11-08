#!/usr/bin/env bash
# The update hold in a throwaway Arch container (ADR-0041 step 2a, SQ-3 option A; docs/specs/updates.md U39): the pair
# grassfield-hold / grassfield-unhold, the root channel helper's `hold` and `unhold` verbs, and the update helper's reading of
# pacman's refusal. Never on a real machine: inside, it refuses to run unless it is root in a container with the repository
# mounted at /src.
#
#   tests/integration/update_hold.sh
#   Runs `docker run --rm --network host` on archlinux:base (digest pinned below) with the repository mounted read-only.
#   HTTPS_PROXY/HTTP_PROXY/NO_PROXY are passed through and GRASSFIELD_TEST_CA, when set, is mounted as the container's CA
#   bundle. Exit 0 all PASS (or SKIP without docker), 1 a FAIL, 2 usage.
#
# What it shows, on a local [grassfield] repository of small packages (file://; the toolkit at three versions; the hold,
# its twin and grassfield-desktop built the way PKGBUILD builds them: the hold's `depends` from packaging/arch/hold-bounds.sh
# applied to a BUILD-DEPS record, the twin `provides` and `conflicts` the hold's name):
#   - a first install of grassfield-desktop pulls grassfield-hold (the literal name), never the twin;
#   - a system upgrade that moves Qt or Quickshell is REFUSED by pacman, naming grassfield-hold, with nothing installed;
#   - the REAL grassfield-update-helper, given the same update, exits 6 (`incompatible grassfield-hold`), not 8;
#   - the same upgrade with the matching grassfield-desktop, hold and twin in the repository goes through in one transaction;
#   - the REAL grassfield-channel-helper's `unhold` swaps the hold for its twin in ONE pacman transaction (--ask 4: if pacman
#     does not answer its conflict question that way, the case "unhold replaces the hold" fails and ADR-0041 2a's fallback,
#     `pacman -Rdd grassfield-hold` then the install, is what the verb must do instead), the upgrade then goes through,
#     grassfield-desktop stays installed;
#   - `hold` with the toolkit past the bounds is refused with nothing changed, and grassfield-channel-set's `hold-state`
#     says allowed-moved; after the next Grassfield build it says allowed and `hold` swaps back;
#   - the helper's refusals: no [grassfield] section, an unknown verb, extra arguments, a package not in the list.
# Not covered here (the owner's L2 or the integrator's nested session): polkit and pkexec around the helper (the action is
# the existing org.grassfield.packages.set-channel), Settings' buttons, the shell's notice.
set -uo pipefail

IMAGE=archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0

if [[ ${1:-} != --inside ]]; then
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
  (($# == 0)) || { echo "usage: update_hold.sh" >&2; exit 2; }
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo "SKIP: no docker daemon (this test runs only in a throwaway container)"; exit 0; }
  args=(--rm --network host -v "$root:/src:ro")
  [[ -n ${GRASSFIELD_TEST_CA:-} ]] && args+=(-v "$(realpath "$GRASSFIELD_TEST_CA"):/etc/ssl/certs/ca-certificates.crt:ro")
  for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy; do [[ -n ${!v:-} ]] && args+=(-e "$v"); done
  exec docker run "${args[@]}" "$IMAGE" bash /src/tests/integration/update_hold.sh --inside
fi

[[ -f /.dockerenv && $(id -u) == 0 && -f /src/packaging/pacman/grassfield-channel-helper && -f /src/packaging/arch/hold-bounds.sh ]] ||
  { echo "refused: runs only as root inside a throwaway container (/src)"; exit 2; }

W=/work
mkdir -p "$W" && chmod 1777 "$W"
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
expect() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
say() { printf '\n== %s\n' "$*"; }
quiet() { "$@" >>"$W/log" 2>&1; }
ver() { pacman -Q "$1" 2>/dev/null | cut -d' ' -f2; }
has() { pacman -Q "$1" >/dev/null 2>&1; }
newop() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
CH=/usr/lib/grassfield/grassfield-channel-helper
UH=/usr/lib/grassfield/grassfield-update-helper
D=/run/grassfield-update
# The helpers as pkexec leaves them: root, no terminal, stdin and stdout a pipe.
chelper() { env -i PATH=/usr/sbin:/usr/bin "$CH" "$@" </dev/null 2>&1 | cat; return "${PIPESTATUS[0]}"; }
uhelper() { env -i PATH=/usr/sbin:/usr/bin "$UH" "$@" </dev/null 2>&1 | cat; return "${PIPESTATUS[0]}"; }

say "setup: the real helpers, the bounds library, a local [grassfield] repository"
sed -i 's/^#\?DisableSandbox.*//; /^\[options\]/a DisableSandbox' /etc/pacman.conf
quiet pacman-key --init
quiet pacman-key --populate archlinux
quiet pacman -Syu --noconfirm python || { echo "FAIL: pacman -Syu (see $W/log)"; tail -5 "$W/log"; exit 1; }
install -Dm755 /src/packaging/pacman/grassfield-channel-helper "$CH"
install -Dm755 /src/packaging/pacman/grassfield-update-helper "$UH"
install -Dm644 /src/packaging/pacman/grassfield-channel.sh /usr/lib/grassfield/grassfield-channel.sh
install -Dm644 /src/packaging/arch/hold-bounds.sh /usr/lib/grassfield/grassfield-hold-bounds.sh
install -Dm755 /src/packaging/bin/grassfield-channel-set /usr/lib/grassfield/grassfield-channel-set
install -d /usr/share/grassfield/pacman
printf 'GRASSFIELD_REPO_BASE=file:///work/repo\nGRASSFIELD_REPO_MIRRORS=\nGRASSFIELD_REPO_BASE_PREVIOUS=\nGRASSFIELD_SIGNING_FINGERPRINT=\n' >/usr/share/grassfield/pacman/repository.conf
# shellcheck source=packaging/arch/hold-bounds.sh
. /src/packaging/arch/hold-bounds.sh

mkdir -p "$W/pkgs" "$W/repo"
# mkpkg name version [.PKGINFO line | path=content]...
mkpkg() {
  local name=$1 version=$2 dir="$W/build/$1-$2" arg path
  shift 2
  rm -rf "$dir" && mkdir -p "$dir/usr/share/doc/$name"
  echo "$name $version" >"$dir/usr/share/doc/$name/README"
  {
    printf 'pkgname = %s\npkgbase = %s\npkgver = %s-1\npkgdesc = update hold test\nurl = https://example.invalid\n' "$name" "$name" "$version"
    printf 'builddate = 1700000000\npackager = test\nsize = 1\narch = any\nlicense = MIT\n'
    for arg in "$@"; do [[ $arg == *' = '* ]] && printf '%s\n' "$arg"; done
  } >"$dir/.PKGINFO"
  for arg in "$@"; do
    [[ $arg == *' = '* ]] && continue
    path=${arg%%=*}
    mkdir -p "$dir/${path%/*}"
    printf '%s\n' "${arg#*=}" >"$dir/$path"
  done
  chmod -R a+rX "$dir"
  (cd "$dir" && bsdtar --zstd -cf "$W/pkgs/$name-$version-1-any.pkg.tar.zst" .PKGINFO usr) || { echo "FAIL: mkpkg $name"; exit 1; }
}
# A Grassfield build for the toolkit qt6-base $1 and quickshell $2: BUILD-DEPS, then the hold's depends computed from it
# by the library PKGBUILD uses, the twin, and a desktop that depends on `grassfield-hold` (and on nothing else of the set).
mkgrassfield() { # build-number qt quickshell
  local n=$1 rec="$W/BUILD-DEPS.$1" line deps=()
  printf 'qt6-base %s-1\nquickshell %s-1\nhyprland 0.56.2-4\naquamarine 0.10.0-1\nkcoreaddons 6.29.0-1\n' "$2" "$3" >"$rec"
  while IFS= read -r line; do deps+=("depend = $line"); done < <(gf_hold_depends "$rec")
  mkpkg grassfield-hold "$n" "${deps[@]}"
  mkpkg grassfield-unhold "$n" "provides = grassfield-hold" "conflict = grassfield-hold"
  mkpkg grassfield-desktop "$n" "depend = grassfield-hold" "usr/share/grassfield/BUILD-DEPS=$(cat "$rec")"
}
mkpkg qt6-base 6.11.0
mkpkg qt6-base 6.12.0
mkpkg qt6-base 6.13.0
mkpkg quickshell 0.3.1
mkpkg quickshell 0.3.2.r7
mkpkg quickshell 0.3.3
mkgrassfield 1 6.11.0 0.3.1
mkgrassfield 2 6.12.0 0.3.2.r7
mkgrassfield 3 6.13.0 0.3.3
info=$(pacman -Qip "$W/pkgs/grassfield-hold-1-1-any.pkg.tar.zst")
expect "the bounds of build 1 come from its record (quickshell=0.3.1, qt6-base>=6.11, qt6-base<6.12)" bash -c 'tr -s " \n" " " <<<"$1" | grep -q "quickshell=0.3.1" && grep -q "qt6-base>=6.11" <<<"$1" && grep -q "qt6-base<6.12" <<<"$1"' _ "$info"

publish() { # package-file...: [grassfield] holds exactly these
  rm -f "$W/repo"/*
  local p
  for p in "$@"; do cp "$W/pkgs/$p-1-any.pkg.tar.zst" "$W/repo/"; done
  quiet repo-add -q "$W/repo/grassfield.db.tar.gz" "$W/repo"/*.pkg.tar.zst
  touch -d "@$(( $(date +%s) + ${publish_n:=0} ))" "$W/repo/grassfield.db.tar.gz" "$W/repo/grassfield.db"
  publish_n=$((publish_n + 1))
  quiet pacman -Syy
}
cat >/etc/pacman.conf <<EOF
[options]
Architecture = auto
CheckSpace
DownloadUser = alpm
DisableSandbox
HoldPkg = pacman glibc
[grassfield]
SigLevel = Optional TrustAll
Server = file://$W/repo
EOF
mkdir -p /etc/pacman.d && printf 'Server = file:///work/repo\n' >/etc/pacman.d/grassfield.conf

say "a first install pulls the real hold, never the twin"
publish grassfield-hold-1 grassfield-unhold-1 grassfield-desktop-1 qt6-base-6.11.0 quickshell-0.3.1
quiet pacman -S --noconfirm grassfield-desktop || { echo "FAIL: installing grassfield-desktop (see $W/log)"; tail -5 "$W/log"; exit 1; }
expect "grassfield-desktop 1 and grassfield-hold 1 installed, the twin not" test "$(ver grassfield-desktop):$(ver grassfield-hold):$(has grassfield-unhold && echo yes || echo no)" == "1-1:1-1:no"
expect "the toolkit came with it (qt6-base 6.11.0, quickshell 0.3.1)" test "$(ver qt6-base):$(ver quickshell)" == "6.11.0-1:0.3.1-1"

say "an upgrade that moves Qt and Quickshell is refused on every path, naming the hold"
publish grassfield-hold-1 grassfield-unhold-1 grassfield-desktop-1 qt6-base-6.12.0 quickshell-0.3.2.r7
pacman -Su --noconfirm >"$W/upgrade.out" 2>&1; rc=$?
expect "pacman -Su refuses (exit non-zero)" test "$rc" != 0
expect "  its error names grassfield-hold" grep -Eq 'required by grassfield-hold( |$)' "$W/upgrade.out"
expect "  nothing was installed (qt6-base 6.11.0, quickshell 0.3.1)" test "$(ver qt6-base):$(ver quickshell)" == "6.11.0-1:0.3.1-1"
op=$(newop); uhelper run "$op" >/dev/null; rc=$?
expect "the update helper reads it as exit 6 (needs a newer Grassfield), not 8" test "$rc" == 6
expect "  the exit file says incompatible grassfield-hold" grep -qx 'incompatible grassfield-hold' "$D/$op.exit"
expect "  nothing was installed" test "$(ver qt6-base):$(ver quickshell)" == "6.11.0-1:0.3.1-1"
expect "  the system's sync databases are the same files (it planned on a copy)" test -f /var/lib/pacman/sync/grassfield.db

say "the matching Grassfield build joins the same transaction"
publish grassfield-hold-2 grassfield-unhold-2 grassfield-desktop-2 qt6-base-6.12.0 quickshell-0.3.2.r7
op=$(newop); uhelper run "$op" >/dev/null; rc=$?
expect "the update helper installs it (exit 0)" test "$rc" == 0
expect "  desktop 2, hold 2, qt6-base 6.12.0, quickshell 0.3.2.r7, still no twin" test "$(ver grassfield-desktop):$(ver grassfield-hold):$(ver qt6-base):$(ver quickshell):$(has grassfield-unhold && echo yes || echo no)" == "2-1:2-1:6.12.0-1:0.3.2.r7-1:no"

say "the helper's refusals leave everything as it was"
chelper hold >/dev/null; expect "hold while held: exit 0, nothing to change" test "$?" == 0
for args in "" "unhold now" "Unhold" "hold-state" "-S grassfield-unhold" "unhold hold"; do
  # shellcheck disable=SC2086
  chelper $args >/dev/null; rc=$?
  expect "'$args' -> exit 2 (usage)" test "$rc" == 2
done
expect "  still held, nothing changed" test "$(ver grassfield-hold):$(has grassfield-unhold && echo yes || echo no)" == "2-1:no"
cp /etc/pacman.conf "$W/pacman.conf.keep"
sed -i '/^\[grassfield\]/,$d' /etc/pacman.conf
chelper unhold >/dev/null; rc=$?
expect "no [grassfield] section -> exit 1, hold kept" test "$rc:$(ver grassfield-hold)" == "1:2-1"
cp "$W/pacman.conf.keep" /etc/pacman.conf
touch /var/lib/pacman/db.lck
chelper unhold >/dev/null; rc=$?
rm -f /var/lib/pacman/db.lck
expect "pacman running (db.lck) -> exit 1, hold kept" test "$rc:$(ver grassfield-hold)" == "1:2-1"
expect "hold-state as a user: held" test "$(runuser -u nobody -- /usr/lib/grassfield/grassfield-channel-set hold-state)" == held

say "Allow system updates Grassfield hasn't tested: unhold replaces the hold in ONE transaction"
publish grassfield-hold-2 grassfield-unhold-2 grassfield-desktop-2 qt6-base-6.13.0 quickshell-0.3.3
pacman -Su --noconfirm >"$W/upgrade.out" 2>&1; rc=$?
expect "before: the upgrade to Qt 6.13 is refused" test "$rc" != 0
expect "  naming the hold" grep -Eq 'required by grassfield-hold( |$)' "$W/upgrade.out"
out=$(chelper unhold); rc=$?
expect "unhold -> exit 0 ($out)" test "$rc" == 0
expect "  the twin replaces the hold; grassfield-desktop is still installed" test "$(ver grassfield-unhold):$(has grassfield-hold && echo yes || echo no):$(ver grassfield-desktop)" == "2-1:no:2-1"
expect "  hold-state: the toolkit is still the one this build was made for -> allowed" test "$(runuser -u nobody -- /usr/lib/grassfield/grassfield-channel-set hold-state)" == allowed
chelper unhold >/dev/null; expect "unhold again: exit 0, nothing to change" test "$?" == 0
op=$(newop); uhelper run "$op" >/dev/null; rc=$?
expect "the update helper now installs the toolkit that was refused (exit 0)" test "$rc:$(ver qt6-base):$(ver quickshell)" == "0:6.13.0-1:0.3.3-1"
expect "  and still names no hold in its exit file" bash -c '! grep -q grassfield-hold "$1"' _ "$D/$op.exit"

say "Hold Again: impossible past the bounds, possible after the next Grassfield build"
expect "hold-state: the toolkit moved past what this Grassfield was built for -> allowed-moved" test "$(runuser -u nobody -- /usr/lib/grassfield/grassfield-channel-set hold-state)" == allowed-moved
out=$(chelper hold); rc=$?
expect "hold -> exit 1 (pacman cannot satisfy the bounds), nothing changed ($out)" test "$rc:$(ver grassfield-unhold):$(has grassfield-hold && echo yes || echo no)" == "1:2-1:no"
expect "  Qt was not downgraded by it" test "$(ver qt6-base):$(ver quickshell)" == "6.13.0-1:0.3.3-1"
publish grassfield-hold-3 grassfield-unhold-3 grassfield-desktop-3 qt6-base-6.13.0 quickshell-0.3.3
op=$(newop); uhelper run "$op" >/dev/null; rc=$?
expect "the next Grassfield build installs (exit 0); the twin was upgraded, not replaced" test "$rc:$(ver grassfield-desktop):$(ver grassfield-unhold):$(has grassfield-hold && echo yes || echo no)" == "0:3-1:3-1:no"
expect "hold-state: the new build's record matches the toolkit -> allowed" test "$(runuser -u nobody -- /usr/lib/grassfield/grassfield-channel-set hold-state)" == allowed
out=$(chelper hold); rc=$?
expect "hold -> exit 0 ($out)" test "$rc" == 0
expect "  the hold 3 replaces the twin; grassfield-desktop is still installed" test "$(ver grassfield-hold):$(has grassfield-unhold && echo yes || echo no):$(ver grassfield-desktop)" == "3-1:no:3-1"
expect "hold-state: held" test "$(runuser -u nobody -- /usr/lib/grassfield/grassfield-channel-set hold-state)" == held

say "the hold is refused by name only: a package of another repository is never taken"
quiet pacman -R --noconfirm -dd grassfield-hold
quiet pacman -S --noconfirm grassfield-unhold
expect "setup: the twin installed alone" test "$(has grassfield-hold && echo yes || echo no):$(ver grassfield-unhold)" == "no:3-1"
cat >>/etc/pacman.conf <<EOF
[other]
SigLevel = Optional TrustAll
Server = file://$W/other
EOF
mkdir -p "$W/other"
mkpkg grassfield-hold 99 "depend = nonexistent-package"
cp "$W/pkgs/grassfield-hold-99-1-any.pkg.tar.zst" "$W/other/"
quiet repo-add -q "$W/other/other.db.tar.gz" "$W/other/grassfield-hold-99-1-any.pkg.tar.zst"
quiet pacman -Syy
chelper hold >/dev/null; rc=$?
expect "hold installs grassfield/grassfield-hold 3, not the other repository's 99" test "$rc:$(ver grassfield-hold)" == "0:3-1"

echo
echo "update_hold: $fails failure(s)"
((fails == 0))
