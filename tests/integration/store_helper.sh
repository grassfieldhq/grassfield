#!/usr/bin/env bash
# Grassfield Store, step 3: grassfield-store-helper and its polkit action in a throwaway Arch container (ADR-0037 b.1, SD1,
# SD2; docs/specs/store.md acceptance A6b and the helper's part of A8). Never on a real machine: inside, it refuses to run
# unless it is root in a container with the repository mounted at /src and an Omarchy 4.0.4 tree at /omarchy.
#
#   tests/integration/store_helper.sh [--omarchy DIR]
#     DIR  an Omarchy 4.0.4 tree (default /usr/share/omarchy): its two package lists are the helper's deny list's
#   Runs `docker run --rm --network host` on archlinux:base (digest pinned below) with the repository and the tree mounted
#   read-only; HTTPS_PROXY/HTTP_PROXY/NO_PROXY are passed through and GRASSFIELD_TEST_CA, when set, is mounted as the
#   container's CA bundle (for a proxied network). Exit 0 all PASS (or SKIP without docker), 1 a FAIL, 2 usage.
#
# Inside the container (Arch's mirrors, the system brought up to date first, DisableSandbox added because Docker refuses
# Landlock, ADR-0033 R5): the REAL helper and policy installed at the PKGBUILD's paths; a local repository [gstest]
# (file://, made here with makepkg and repo-add) of small packages for each case of the rule; users `builder` (makepkg),
# `alice` (wheel, a throwaway password: polkit asks her for it, auth_admin) and `bob` (no permission). Real polkitd and
# pkexec run the helper; most cases run it as root directly, the way pkexec leaves it (an environment of its own, which
# the helper drops). One real app from Arch's mirror (xterm) is installed and removed through pkexec. Last, the Store's own
# plan check and queue (apps/store/src) drive it all as a user (`carol`), with Omarchy's own web app commands
# (tests/integration/store_e2e.cpp, built here against the repository's sources), and an Omarchy setup of the catalog
# (`omarchy-install-browser firefox` and `omarchy-remove-browser firefox` from the mounted tree, unchanged) through the
# Store's terminal path and the real grassfield-store-run (step 3b1, ADR-0037 b.2): a container has no terminal, so a
# stand-in runs the launcher's command with `bash -c`, detached; carol's sudo asks no password here (the prompt in Omarchy's
# terminal is the owner's check, A12); the `firefox` it installs is a small test package of a local repository listed
# before Arch's. Then an AUR package the same way (step 3b2): Omarchy's own omarchy-pkg-aur-add and omarchy-pkg-drop, the
# Store's AUR plan from a folder of answers in the AUR's format; yay is a stand-in here (yay's binary comes from GitHub, which
# this network refuses) that does what yay does for `-S --noconfirm --needed`: makepkg as the user from a folder of
# PKGBUILDs, its AUR dependencies first, then sudo pacman -U (the dependencies --asdeps). Last, Get Flatpak… (step 3c part
# 3): the real flatpak package from Arch's mirror, through Omarchy's own omarchy-pkg-add and grassfield-store-run.
set -uo pipefail

IMAGE=archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0

if [[ ${1:-} != --inside ]]; then
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
  omarchy=/usr/share/omarchy
  while (($#)); do
    case $1 in
      --omarchy) omarchy=${2:?}; shift ;;
      *) echo "usage: store_helper.sh [--omarchy DIR]" >&2; exit 2 ;;
    esac
    shift
  done
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo "SKIP: no docker daemon (this test runs only in a throwaway container)"; exit 0; }
  [[ -f $omarchy/install/omarchy-base.packages && -f $omarchy/install/omarchy-other.packages ]] ||
    { echo "SKIP: no Omarchy 4.0.4 tree at $omarchy (--omarchy DIR)"; exit 0; }
  # shellcheck source=omarchy-tree.sh
  . "$root/tests/integration/omarchy-tree.sh" || exit 2
  args=(--rm --network host -v "$root:/src:ro")
  omarchy_mounts "$omarchy" "$root/.dev/store-helper-omarchy" /omarchy args || exit 2
  [[ -n ${GRASSFIELD_TEST_CA:-} ]] && args+=(-v "$(realpath "$GRASSFIELD_TEST_CA"):/etc/ssl/certs/ca-certificates.crt:ro")
  for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy; do [[ -n ${!v:-} ]] && args+=(-e "$v"); done
  exec docker run "${args[@]}" "$IMAGE" bash /src/tests/integration/store_helper.sh --inside
fi

[[ -f /.dockerenv && $(id -u) == 0 && -f /src/packaging/store/grassfield-store-helper && -d /omarchy/install ]] ||
  { echo "refused: runs only as root inside a throwaway container (/src, /omarchy)"; exit 2; }

W=/work
mkdir -p "$W" && chmod 1777 "$W"
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
expect() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
say() { printf '\n== %s\n' "$*"; }
as() { local u=$1; shift; runuser -u "$u" -- env HOME="/home/$u" "$@"; }
quiet() { "$@" >>"$W/log" 2>&1; }
H=/usr/lib/grassfield/grassfield-store-helper
D=/run/grassfield-store
# A fresh operation id (random: $(newop) runs in a subshell).
newop() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
# The helper as pkexec leaves it: root, an environment of pkexec's (which it drops), no terminal, stdin and stdout a pipe.
helper() { env -i PATH=/usr/sbin:/usr/bin SHELL=/bin/bash USER=root LOGNAME=root HOME=/root PKEXEC_UID=1001 "$H" "$@" </dev/null 2>&1 | cat; return "${PIPESTATUS[0]}"; }
installed() { pacman -Q "$1" >/dev/null 2>&1; }
exitfile() { cat "$D/$1.exit" 2>/dev/null; }

say "setup: Arch's mirrors, the system up to date, polkit; the real helper and policy"
sed -i 's/^#\?DisableSandbox.*//; /^\[options\]/a DisableSandbox' /etc/pacman.conf
quiet pacman-key --init
quiet pacman-key --populate archlinux
quiet pacman -Syu --noconfirm || { echo "FAIL: pacman -Syu (see $W/log)"; tail -5 "$W/log"; exit 1; }
quiet pacman -S --noconfirm --needed polkit fakeroot binutils python || { echo "FAIL: tools"; tail -5 "$W/log"; exit 1; }
pacman -Q pacman polkit | tr '\n' ' '; echo
install -Dm755 /src/packaging/store/grassfield-store-helper "$H"
install -Dm644 /src/packaging/store/org.grassfield.store.policy /usr/share/polkit-1/actions/org.grassfield.store.policy
install -d /usr/share/omarchy/install
cp /omarchy/install/omarchy-base.packages /omarchy/install/omarchy-other.packages /usr/share/omarchy/install/
echo "gs-omarchy-app # a test app in Omarchy's list" >>/usr/share/omarchy/install/omarchy-other.packages
sed -i 's/^#\?HoldPkg.*/HoldPkg = pacman glibc gs-held/' /etc/pacman.conf
useradd -m builder && useradd -m alice && useradd -m bob
usermod -aG wheel alice && echo 'alice:test-only-password' | chpasswd
mkdir -p /run/dbus && dbus-daemon --system --fork
/usr/lib/polkit-1/polkitd --no-debug >"$W/polkitd.log" 2>&1 &
# A container has no logind session, so polkit would apply allow_any (no) to everyone: this rule gives alice what an
# active local session gets from the policy (an administrator's password), and nothing to bob.
cat >/etc/polkit-1/rules.d/50-grassfield-test.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id == "org.grassfield.store.manage-packages" && subject.user == "alice") return polkit.Result.AUTH_ADMIN;
});
EOF
sleep 2

say "the test repository [gstest]: one small package per case of the rule"
mkpkg() { # name version deps(space separated) entry(yes|no) [install-scriptlet body]
  local name=$1 ver=$2 deps=$3 entry=$4 scriptlet=${5:-} dir="/home/builder/pkg/$1-$2"
  mkdir -p "$dir"
  {
    echo "pkgname=$name"; echo "pkgver=$ver"; echo "pkgrel=1"; echo "pkgdesc='Store helper test package'"; echo "arch=(any)"
    echo "license=(MIT)"; echo "depends=($deps)"; echo "options=(!strip !debug)"
    [[ -n $scriptlet ]] && echo "install=$name.install"
    echo "package() {"
    echo "  install -Dm644 /dev/null \"\$pkgdir/usr/share/doc/$name/README\""
    [[ $entry == yes ]] && printf '  printf "[Desktop Entry]\\nType=Application\\nName=%s\\nExec=true\\n" >"$srcdir/%s.desktop"\n  install -Dm644 "$srcdir/%s.desktop" "$pkgdir/usr/share/applications/%s.desktop"\n' "$name" "$name" "$name" "$name"
    echo "}"
  } >"$dir/PKGBUILD"
  [[ -n $scriptlet ]] && printf 'post_install() {\n%s\n}\n' "$scriptlet" >"$dir/$name.install"
  chown -R builder: /home/builder/pkg
  (cd "$dir" && as builder makepkg -d >>"$W/makepkg.log" 2>&1) || { echo "FAIL: makepkg $name"; tail -5 "$W/makepkg.log"; exit 1; }
}
mkpkg gs-app 1 "gs-dep" yes
mkpkg gs-dep 1 "" no
mkpkg gs-tool 1 "" no
mkpkg gs-lib 1 "" yes
mkpkg gs-app2 1 "gs-lib" yes
mkpkg gs-firmware 1 "" no
mkpkg gs-app-fw 1 "gs-firmware" yes
mkpkg grassfield-gs 1 "" yes
mkpkg gs-omarchy-app 1 "" yes
mkpkg gs-held 1 "" yes
mkpkg gs-slow 1 "" yes "  sleep 8"
mkpkg gs-loud 1 "" yes "  head -c 10485760 /dev/zero | tr '\\0' x | fold -w 100"
mkpkg gs-local 1 "" yes
mkpkg gs-orphan 1 "" yes
mkpkg gs-newer 1 "'gs-app>=2'" yes
mkpkg gs-pinned 1 "" no
mkpkg gs-pinned 2 "" no
mkpkg gs-wants-old 1 "'gs-pinned<2'" yes
mkpkg gs-daemon 1 "" yes "  setsid sleep 30 </dev/null >/dev/null 2>&1 &"
mkdir -p /srv/gstest
for f in /home/builder/pkg/*/*.pkg.tar.zst; do
  [[ $f == */gs-local-* || $f == */gs-pinned-2/* ]] || cp "$f" /srv/gstest/
done
quiet repo-add /srv/gstest/gstest.db.tar.gz /srv/gstest/*.pkg.tar.zst
printf '\n[gstest]\nSigLevel = Optional TrustAll\nServer = file:///srv/gstest\n' >>/etc/pacman.conf
quiet pacman -Sy
expect "[gstest] lists the test packages" test "$(pacman -Slq gstest | wc -l)" -ge 17

say "A6b policy: auth_admin for an active session, nothing for any other; the message names the command line"
pk=$(pkaction --verbose --action-id org.grassfield.store.manage-packages 2>&1)
expect "pkaction: implicit any no, inactive no, active auth_admin" bash -c "grep -q 'implicit any: *no' <<<\"\$1\" && grep -q 'implicit inactive: *no' <<<\"\$1\" && grep -q 'implicit active: *auth_admin\$' <<<\"\$1\"" _ "$pk"
expect "pkaction: the program is the helper" grep -q "org.freedesktop.policykit.exec.path -> $H" <<<"$pk"
expect "the policy's message ends with \$(command_line), in English and French" test "$(grep -c '\$(command_line)</message>' /usr/share/polkit-1/actions/org.grassfield.store.policy)" == 2

say "A6b usage: the argument vector only"
helper >/dev/null; rc=$?; expect "no argument -> exit 2" test "$rc" == 2
helper upgrade "$(newop)" gs-app >/dev/null; rc=$?; expect "an unknown verb -> exit 2" test "$rc" == 2
helper install 0123 gs-app >/dev/null; rc=$?; expect "a short operation id -> exit 2" test "$rc" == 2
helper install "$(newop | tr a-f A-F)" gs-app >/dev/null; rc=$?; expect "an upper-case operation id -> exit 2" test "$rc" == 2
for bad in -gs-app Gs-app 'gs app' '../gs-app' 'gs-app;id' "$(printf 'gs-app\nx')" "$(printf 'a%.0s' {1..129})"; do
  helper install "$(newop)" "$bad" >/dev/null; rc=$?; expect "a bad package name ($(printf '%q' "$bad" | cut -c1-30)) -> exit 2" test "$rc" == 2
done
names=(); for i in $(seq 65); do names+=("gs-app$i"); done
helper install "$(newop)" "${names[@]}" >/dev/null; rc=$?; expect "65 names -> exit 2" test "$rc" == 2
before=$(ls "$D" 2>/dev/null | wc -l)
expect "a refused argument vector writes nothing" test "$before" == 0
out=$(as alice "$H" install "$(newop)" gs-app 2>&1); rc=$?
expect "the helper run by a user without pkexec -> exit 2, no message on its pipe" test "$rc:$out" == "2:"

say "A6b install: an app from a repository (SD1), its status files"
op=$(newop)
out=$(helper install "$op" gs-app); rc=$?
expect "install gs-app -> exit 0, gs-app and its dependency installed" bash -c "test $rc == 0 && pacman -Q gs-app gs-dep >/dev/null"
expect "nothing reached the pipe it was started with" test -z "$out"
expect "$D is root's, 0755; the log 0644; started, log and exit there" test "$(stat -c %u:%a "$D"):$(stat -c %a "$D/$op.log"):$(exitfile "$op")" == "0:755:644:0"
expect "the started file: a pid and a start time" grep -Eq '^[0-9]+ [0-9]+$' "$D/$op.started"
expect "the log holds the command and pacman's output" bash -c "grep -q 'pacman -S --needed --noconfirm --noprogressbar -- gs-app' $D/$op.log && grep -q 'installing gs-app' $D/$op.log"
expect "gs-app was installed explicitly, gs-dep as a dependency" bash -c "pacman -Qqe gs-app >/dev/null && ! pacman -Qqe gs-dep >/dev/null"
helper install "$op" gs-app >/dev/null; rc=$?
expect "the same operation id again -> exit 2, its files unchanged" test "$rc:$(exitfile "$op")" == "2:0"
op=$(newop); helper install "$op" gs-tool >/dev/null; rc=$?
expect "install gs-tool (no application entry) -> exit 7, not installed (SD1)" bash -c "test $rc:$(exitfile "$op") == 7:7 && ! pacman -Q gs-tool >/dev/null 2>&1"
op=$(newop); helper install "$op" gs-app gs-tool >/dev/null; rc=$?
expect "install gs-app and gs-tool together -> exit 7, nothing installed" bash -c "test $rc == 7 && ! pacman -Q gs-tool >/dev/null 2>&1"
op=$(newop); helper install "$op" gs-app >/dev/null; rc=$?
expect "install gs-app again (installed: its database read, --needed) -> exit 0" test "$rc" == 0
op=$(newop); helper install "$op" no-such-package-gs >/dev/null; rc=$?
expect "a name no repository has -> exit 5" test "$rc:$(exitfile "$op")" == "5:5"
op=$(newop); helper install "$op" sh >/dev/null; rc=$?
expect "a name only provided by a package (sh) -> exit 5, never resolved to its provider" test "$rc" == 5

say "A6b refusals before pacman: busy, db.lck, an update that did not finish"
exec 8<"$D/helper.lock"; flock -n 8
op=$(newop); helper install "$op" gs-lib >/dev/null; rc=$?
expect "another run holds the helper's lock -> exit 3, nothing installed" bash -c "test $rc == 3 && ! pacman -Q gs-lib >/dev/null 2>&1"
exec 8<&-
expect "helper.lock is root's, 0600" test "$(stat -c %u:%a "$D/helper.lock")" == "0:600"
touch /var/lib/pacman/db.lck
op=$(newop); helper install "$op" gs-lib >/dev/null; rc=$?
rm -f /var/lib/pacman/db.lck
expect "pacman's db.lck present -> exit 3" test "$rc" == 3
# gs-app 2 published: the database is newer than the system (pacman -Qu lists gs-app).
mkpkg gs-app 2 "gs-dep" yes
cp /home/builder/pkg/gs-app-2/gs-app-2-1-any.pkg.tar.zst /srv/gstest/
quiet repo-add /srv/gstest/gstest.db.tar.gz /srv/gstest/gs-app-2-1-any.pkg.tar.zst
quiet pacman -Sy
op=$(newop); helper install "$op" gs-lib >/dev/null; rc=$?
expect "pacman -Qu lists gs-app 1 -> 2 -> exit 4, nothing installed" bash -c "test $rc == 4 && ! pacman -Q gs-lib >/dev/null 2>&1"
sed -i 's/^\[options\]$/[options]\nIgnorePkg = gs-app/' /etc/pacman.conf
op=$(newop); helper install "$op" gs-lib gs-app2 >/dev/null; rc=$?
expect "the same with gs-app held by IgnorePkg ([ignored]) -> install gs-lib gs-app2 exit 0" bash -c "test $rc == 0 && pacman -Q gs-lib gs-app2 >/dev/null"
# gs-newer needs gs-app 2, which IgnorePkg holds back: under --noconfirm pacman would update gs-app alone (a partial
# upgrade). The plan is read first, without --noconfirm: pacman's question gets no answer and the plan fails.
op=$(newop); helper install "$op" gs-newer >/dev/null; rc=$?
expect "install gs-newer, whose plan updates the held gs-app -> exit 5, gs-app stays 1, gs-newer not installed" \
  bash -c "test $rc == 5 && test \"\$(pacman -Q gs-app)\" == 'gs-app 1-1' && ! pacman -Q gs-newer >/dev/null 2>&1"
tail -n 2 "$D/$op.log" | sed 's/^/    /'
# gs-wants-old needs a gs-pinned older than the one installed (2, from a file; the repository has 1): pacman would put 1
# back, with no question. The plan names gs-pinned, which is installed: refused before anything is downloaded.
quiet pacman -U --noconfirm /home/builder/pkg/gs-pinned-2/gs-pinned-2-1-any.pkg.tar.zst
op=$(newop); helper install "$op" gs-wants-old >/dev/null; rc=$?
expect "install gs-wants-old, whose plan puts gs-pinned 1 back over 2 -> exit 5, gs-pinned stays 2" \
  bash -c "test $rc == 5 && test \"\$(pacman -Q gs-pinned)\" == 'gs-pinned 2-1' && ! pacman -Q gs-wants-old >/dev/null 2>&1"
tail -n 1 "$D/$op.log" | sed 's/^/    /'
expect "  the log names the installed package" grep -q 'would replace the installed gs-pinned with 1-1 alone' "$D/$op.log"
# gs-app itself, asked for by name while IgnorePkg holds it back (installed 1, the repository has 2): pacman -S --noconfirm
# would update it. Refused by its "[ignored]" line in pacman -Qu, before the plan (which, its question reading /dev/null,
# lists gs-app 2-1: the installed-package check would refuse it too).
op=$(newop); helper install "$op" gs-app >/dev/null; rc=$?
expect "install gs-app by name (1 installed, held by IgnorePkg, 2 in the repository) -> exit 5, gs-app stays 1" \
  bash -c "test $rc == 5 && test \"\$(pacman -Q gs-app)\" == 'gs-app 1-1' && grep -q 'held back by IgnorePkg' $D/$op.log"
printf '    exit %s, %s; %s\n' "$rc" "$(pacman -Q gs-app)" "$(tail -n 1 "$D/$op.log")"

say "A6b remove: apps the user installed, never the system's (S16)"
quiet pacman -S --noconfirm gs-app-fw grassfield-gs gs-omarchy-app gs-held
quiet pacman -U --noconfirm /home/builder/pkg/gs-local-1/gs-local-1-1-any.pkg.tar.zst
op=$(newop); helper remove "$op" gs-dep >/dev/null; rc=$?
expect "remove gs-dep (installed as a dependency) -> exit 6" bash -c "test $rc == 6 && pacman -Q gs-dep >/dev/null"
# The explicit-only rule alone: gs-orphan owns an application entry, nothing needs it, its plan is itself.
quiet pacman -S --noconfirm --asdeps gs-orphan
op=$(newop); helper remove "$op" gs-orphan >/dev/null; rc=$?
expect "remove gs-orphan (an app installed as a dependency, needed by nothing) -> exit 6, stays" \
  bash -c "test $rc == 6 && pacman -Q gs-orphan >/dev/null && grep -q 'was not installed as an app' $D/$op.log"
op=$(newop); helper remove "$op" grassfield-gs >/dev/null; rc=$?
expect "remove grassfield-gs (Grassfield's name) -> exit 6" bash -c "test $rc == 6 && pacman -Q grassfield-gs >/dev/null"
op=$(newop); helper remove "$op" gs-omarchy-app >/dev/null; rc=$?
expect "remove gs-omarchy-app (in Omarchy's list) -> exit 6" bash -c "test $rc == 6 && pacman -Q gs-omarchy-app >/dev/null"
op=$(newop); helper remove "$op" gs-held >/dev/null; rc=$?
expect "remove gs-held (pacman's HoldPkg) -> exit 6" bash -c "test $rc == 6 && pacman -Q gs-held >/dev/null"
op=$(newop); helper remove "$op" gs-app-fw >/dev/null; rc=$?
expect "remove gs-app-fw, whose plan takes gs-firmware along -> exit 6, both stay" bash -c "test $rc == 6 && pacman -Q gs-app-fw gs-firmware >/dev/null"
expect "  and the log says which package" grep -q 'would also remove gs-firmware' "$D/$op.log"
op=$(newop); helper remove "$op" gs-local >/dev/null; rc=$?
expect "remove gs-local (no repository has it: the terminal's path) -> exit 5" bash -c "test $rc == 5 && pacman -Q gs-local >/dev/null"
op=$(newop); helper remove "$op" gs-lib >/dev/null; rc=$?
expect "remove gs-lib, which gs-app2 needs -> exit 5 (the plan does not resolve), stays" bash -c "test $rc == 5 && pacman -Q gs-lib >/dev/null"
quiet pacman -S --noconfirm --asexplicit gs-tool
op=$(newop); helper remove "$op" gs-tool >/dev/null; rc=$?
expect "remove gs-tool (explicit, no application entry) -> exit 6" bash -c "test $rc == 6 && pacman -Q gs-tool >/dev/null"
mv /usr/share/omarchy/install /usr/share/omarchy/install.away
op=$(newop); helper remove "$op" gs-app2 >/dev/null; rc=$?
mv /usr/share/omarchy/install.away /usr/share/omarchy/install
expect "Omarchy's lists missing -> every remove refused (exit 6)" bash -c "test $rc == 6 && pacman -Q gs-app2 >/dev/null"
op=$(newop); helper remove "$op" gs-app2 gs-lib >/dev/null; rc=$?
expect "remove gs-app2 and gs-lib together -> exit 0, both gone" bash -c "test $rc == 0 && ! pacman -Q gs-app2 >/dev/null 2>&1 && ! pacman -Q gs-lib >/dev/null 2>&1"
expect "  pacman -Rns ran, as the log says" grep -q 'pacman -Rns --noconfirm --noprogressbar -- gs-app2 gs-lib' "$D/$op.log"

say "A6b the deny list over its vectors (tests/fixtures/store/removal-vectors.json, shared with the Store's C++ rule)"
# The helper's own denied() and its arrays, cut out of the installed file and run alone: the same answers as the Store's
# rule (apps/store/src/removal.cpp, tests/unit/store/tst_removal.cpp) on every vector.
sed -n '/^denied() {/,/^}/p' "$H" >"$W/denied.sh"
expect "denied() found in the helper" test -s "$W/denied.sh"
python3 -I - "$W/denied.sh" /src/tests/fixtures/store/removal-vectors.json >"$W/vectors.out" 2>&1 <<'PY'
import json, subprocess, sys
fn, vec = sys.argv[1], json.load(open(sys.argv[2]))
script = "declare -A omarchy=() hold=() gfopt=()\n"
script += "".join("gfopt[%s]=1\n" % n for n in vec["gfOptional"])
script += "".join("omarchy[%s]=1\n" % n for n in vec["omarchyLists"])
script += "".join("hold[%s]=1\n" % n for n in vec["holdPkg"])
script += open(fn).read()
script += 'while IFS= read -r n; do if denied "$n"; then echo "$n denied"; else echo "$n allowed"; fi; done\n'
names = [c["name"] for c in vec["cases"]]
out = subprocess.run(["bash", "-c", script], input="\n".join(names) + "\n", capture_output=True, text=True).stdout.split("\n")
bad = 0
for c, line in zip(vec["cases"], out):
    want = "allowed" if c["protection"] == "none" else "denied"
    if line != "%s %s" % (c["name"], want):
        print("MISMATCH %s: helper says %r, vectors say %s" % (c["name"], line, c["protection"]))
        bad += 1
print("%d vectors, %d mismatches" % (len(names), bad))
PY
expect "every vector: $(tail -1 "$W/vectors.out")" grep -q ' 0 mismatches$' "$W/vectors.out"
grep MISMATCH "$W/vectors.out" | head -5

say "A6b descriptors and signals: the caller going away does not stop pacman (S6)"
op=$(newop)
( env -i PATH=/usr/bin "$H" install "$op" gs-slow </dev/null 2>&1 | cat >"$W/slow.pipe" ) &
caller=$!
for _ in $(seq 40); do [[ -f $D/$op.started ]] && grep -q 'gs-slow' "$D/$op.log" 2>/dev/null && break; sleep 0.25; done
sleep 2
hpid=$(cut -d' ' -f1 "$D/$op.started")
holders=$(find /proc/[0-9]*/fd -lname "$D/helper.lock" 2>/dev/null | cut -d/ -f3 | sort -u | tr '\n' ' ')
expect "while pacman and gs-slow's scriptlet run, only the helper holds its lock ($holders)" test "$holders" == "$hpid "
fds=$(for fd in 0 1 2; do readlink "/proc/$hpid/fd/$fd"; done | tr '\n' ' ')
expect "its stdin is /dev/null, stdout and stderr the log ($fds)" test "$fds" == "/dev/null $D/$op.log $D/$op.log "
ign=$(awk '/^SigIgn:/{print $2}' "/proc/$hpid/status")
expect "SIGHUP and SIGPIPE ignored (SigIgn $ign)" python3 -I -c "import sys; m=int(sys.argv[1],16); sys.exit(0 if m & (1<<0) and m & (1<<12) else 1)" "$ign"
expect "the start time in the started file is the process's" test "$(cut -d' ' -f2 "$D/$op.started")" == "$(awk '{sub(/.*\) /,""); print $20}' "/proc/$hpid/stat")"
kill -HUP "$hpid" 2>/dev/null
kill "$caller" 2>/dev/null; pkill -P "$caller" cat 2>/dev/null
for _ in $(seq 60); do [[ -f $D/$op.exit ]] && break; sleep 0.5; done
expect "after SIGHUP and its caller gone: exit file 0, gs-slow installed" bash -c "test '$(exitfile "$op")' == 0 && pacman -Q gs-slow >/dev/null"
expect "nothing was written to the caller's pipe" test ! -s "$W/slow.pipe"
# A scriptlet that leaves a process running (a daemon started at install): it must not keep the helper's lock.
op=$(newop); helper install "$op" gs-daemon >/dev/null; rc=$?
holders=$(find /proc/[0-9]*/fd -lname "$D/helper.lock" 2>/dev/null | cut -d/ -f3 | sort -u | tr '\n' ' ')
expect "install gs-daemon (its scriptlet leaves sleep running) -> exit 0, nothing holds the lock after ($holders)" \
  bash -c "test $rc == 0 && test -z '$holders' && pgrep -x sleep >/dev/null"
op=$(newop); helper remove "$op" gs-daemon >/dev/null; rc=$?
expect "  the next run is not busy: remove gs-daemon -> exit 0" test "$rc" == 0
pkill -x sleep 2>/dev/null

say "A6b the log's cap (8 MiB), the environment dropped, the 16 newest operations kept"
op=$(newop); helper install "$op" gs-loud >/dev/null; rc=$?
size=$(stat -c %s "$D/$op.log")
expect "a scriptlet printing 10 MiB: exit 0, the log $size bytes (at most 8 MiB)" bash -c "test $rc == 0 && test $size -le 8388608 && test $size -gt 8000000"
mkdir -p /tmp/evil && printf '#!/bin/sh\necho evil >/tmp/evil/ran\nexit 0\n' >/tmp/evil/pacman && chmod 755 /tmp/evil/pacman
echo 'echo evil >/tmp/evil/bashenv' >/tmp/evil/env.sh
op=$(newop)
env -i PATH=/tmp/evil:/usr/bin BASH_ENV=/tmp/evil/env.sh ENV=/tmp/evil/env.sh 'BASH_FUNC_pacman%%=() { echo evil >/tmp/evil/func; }' \
  LC_ALL=C.UTF-8 "$H" remove "$op" gs-dep </dev/null >/dev/null 2>&1; rc=$?
expect "a poisoned PATH, BASH_ENV and an exported function reach nothing (exit 6, nothing ran)" bash -c "test $rc == 6 && ! ls /tmp/evil/ran /tmp/evil/bashenv /tmp/evil/func 2>/dev/null"
for _ in $(seq 18); do helper remove "$(newop)" gs-dep >/dev/null; done
expect "16 operations' files kept (newest)" test "$(ls "$D"/*.started | wc -l)" == 16

say "A6b and A8 through pkexec: alice's password at every operation (auth_admin, never kept), bob refused"
cat >"$W/drive.py" <<'PY'
# Runs one command in a pseudo-terminal as the user; answers each "Password:" prompt; prints the transcript and the count.
import os, pty, sys, time, select
user, password, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("runuser", ["runuser", "-u", user, "--", "bash", "-c", cmd])
out, prompts, deadline = b"", 0, time.time() + 600
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1)
    if not r:
        continue
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
    if out.count(b"Password:") > prompts:
        prompts = out.count(b"Password:")
        os.write(fd, password.encode() + b"\n")
_, status = os.waitpid(pid, 0)
print(out.decode(errors="replace").replace("\r", ""))
print("password prompts: %d, exit %d" % (prompts, os.waitstatus_to_exitcode(status)))
PY
# On an Omarchy machine the packages of Omarchy's lists are installed explicitly; in this small container xterm would pull
# some of them in as its dependencies (fontconfig), and its removal plan would then take them along: the helper refuses that
# (S16). They are installed first, explicitly, as on the owner's machine.
mapfile -t listed < <(pacman -Sp --print-format '%n' xterm 2>/dev/null | grep -Fxf <(sed 's/#.*//' /usr/share/omarchy/install/omarchy-*.packages | tr -s ' \t' '\n' | grep -v '^$'))
((${#listed[@]})) && quiet pacman -S --noconfirm --needed --asexplicit "${listed[@]}"
echo "  Omarchy's packages xterm needs, installed first: ${listed[*]:-none}"
op1=$(newop) op2=$(newop)
python3 -I "$W/drive.py" alice test-only-password "pkexec $H install $op1 xterm; echo rc=\$?; pkexec $H remove $op2 xterm; echo rc=\$?" >"$W/pk.out" 2>&1
sed -n '/AUTHENTICATING/,+1p' "$W/pk.out" | sed 's/\x1b\[[0-9;]*m//g' | head -4 | sed 's/^/    /'
expect "two operations, two password prompts (auth_admin)" grep -q '^password prompts: 2,' "$W/pk.out"
expect "the dialog's message names the helper, the verb, the operation and the package (SD2's source)" grep -q "install or remove apps: $H install $op1 xterm" "$W/pk.out"
# The password is not echoed, so what follows it shares its line: the codes are read anywhere on a line.
codes=$(grep -o 'rc=[0-9]*' "$W/pk.out" | tr '\n' ' ')
expect "xterm from Arch's mirror installed then removed ($codes; exit files $(exitfile "$op1") $(exitfile "$op2"))" bash -c "test '$codes' == 'rc=0 rc=0 ' && test '$(exitfile "$op1"):$(exitfile "$op2")' == 0:0 && ! pacman -Q xterm >/dev/null 2>&1"
[[ $codes == 'rc=0 rc=0 ' ]] || for f in "$D/$op1.log" "$D/$op2.log"; do tail -n 5 "$f" 2>&1 | sed 's/^/    /'; done
python3 -I "$W/drive.py" alice wrong-password "pkexec $H install $(newop) gs-lib; echo rc=\$?" >"$W/pk-wrong.out" 2>&1
expect "a wrong password -> pkexec exit 127, nothing installed" bash -c "grep -q 'rc=127' $W/pk-wrong.out && ! pacman -Q gs-lib >/dev/null 2>&1"
out=$(as bob pkexec "$H" install "$(newop)" gs-lib </dev/null 2>&1); rc=$?
expect "bob (no rule, no session) -> pkexec refuses (exit $rc: $out), nothing installed" bash -c "test $rc == 126 -o $rc == 127 && ! pacman -Q gs-lib >/dev/null 2>&1"

say "A8 the Store's own plan check and queue end to end (apps/store/src, tests/integration/store_e2e.cpp), as carol"
# The real pkexec, helper, polkit and pacman, and Omarchy's own web app commands (from the mounted tree), driven by the
# Store's code as a user would through its window. carol may run the action without a password (a test rule): what is
# tested here is the Store's side, the password path is the section above.
quiet pacman -S --noconfirm --needed qt6-base gcc pkgconf desktop-file-utils gtk-update-icon-cache sudo ||
  { echo "FAIL: build tools"; tail -5 "$W/log"; exit 1; }
src=/src/apps/store/src
/usr/lib/qt6/moc "$src/operations.h" -o "$W/moc_operations.cpp"
e2e_sources=()
for f in "$src"/*.cpp; do case ${f##*/} in main.cpp | screenshotprovider.cpp | storebackend.cpp) ;; *) e2e_sources+=("$f") ;; esac; done
# -fPIC: Qt's libraries are built with reduced relocations, which CMake's Qt targets ask for.
# shellcheck disable=SC2046
g++ -std=c++17 -O1 -fPIC -I"$src" -I/src/apps -I/src/ui/i18n $(pkg-config --cflags Qt6Core Qt6Gui Qt6Network zlib) \
  "${e2e_sources[@]}" "$W/moc_operations.cpp" /src/tests/integration/store_e2e.cpp \
  $(pkg-config --libs Qt6Core Qt6Gui Qt6Network zlib) -o "$W/store_e2e" >"$W/e2e-build.log" 2>&1
if [[ ! -x $W/store_e2e ]]; then
  fail "the driver builds against the Store's sources"
  tail -5 "$W/e2e-build.log"
  printf '\n== result\n%s FAIL\n' "$fails"
  exit 1
fi
pass "the driver builds against the Store's sources"
useradd -m carol
cuid=$(id -u carol)
mkdir -p "/run/user/$cuid" && chown carol: "/run/user/$cuid" && chmod 700 "/run/user/$cuid"
printf '%s\n' 'polkit.addRule(function(action, subject) {' \
  '  if (action.id == "org.grassfield.store.manage-packages" && subject.user == "carol") return polkit.Result.YES;' \
  '});' >/etc/polkit-1/rules.d/49-grassfield-e2e.rules
sleep 2
e2e() { runuser -u carol -- env -i HOME=/home/carol USER=carol PATH=/usr/bin XDG_RUNTIME_DIR="/run/user/$cuid" OMARCHY_PATH=/omarchy \
  QT_QPA_PLATFORM=offscreen "$W/store_e2e" "$@" 2>>"$W/e2e.err"; }
has() { grep -qx -- "$2" <<<"$1"; } # output line
out=$(e2e install gs-lib)
sed 's/^/    /' <<<"$out"
expect "install gs-lib: the plan names it, the operation is done (exit code 0 and the state)" \
  eval 'has "$out" "plan=none packages=gs-lib" && has "$out" "result=done" && pacman -Q gs-lib >/dev/null'
expect "  Omarchy's update lock was the Store's while it ran, and free after" \
  eval 'has "$out" "lock-while-running=1" && has "$out" "lock-after=0"'
out=$(e2e remove gs-lib)
sed 's/^/    /' <<<"$out"
expect "remove gs-lib: the plan names it, the operation is done, it is gone" \
  eval 'has "$out" "plan=none packages=gs-lib dependents=" && has "$out" "result=done" && ! pacman -Q gs-lib >/dev/null 2>&1'
quiet pacman -S --noconfirm gs-app2
out=$(e2e remove gs-lib)
sed 's/^/    /' <<<"$out"
expect "remove gs-lib while gs-app2 needs it: the plan names the app that needs it, nothing runs" \
  eval 'has "$out" "plan=dependency packages= dependents=gs-app2" && pacman -Q gs-lib >/dev/null'
quiet pacman -Rns --noconfirm gs-app2
touch /var/lib/pacman/db.lck
out=$(e2e install gs-lib)
rm -f /var/lib/pacman/db.lck
expect "pacman's lock there: the plan says busy, nothing runs" eval 'has "$out" "plan=busy packages=" && ! pacman -Q gs-lib >/dev/null 2>&1'
out=$(e2e install gs-not-in-a-repository)
expect "a name no repository has: refused by the plan (pacman cannot resolve it)" eval 'has "$out" "plan=outdated packages="'
# A tiny PNG for the web app's icon (Omarchy copies a local icon file, S9).
python3 -I -c 'import struct, sys, zlib
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
raw = b"".join(b"\x00" + b"\x40\x80\xc0\xff" * 4 for _ in range(4))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))' "$W/gs-icon.png"
chmod 644 "$W/gs-icon.png"
out=$(e2e webapp-install "GS Web" https://example.org/ "$W/gs-icon.png")
sed 's/^/    /' <<<"$out"
entry="/home/carol/.local/share/applications/GS Web.desktop"
# shellcheck disable=SC2034 # read by the eval below
icon=/home/carol/.local/share/icons/hicolor/256x256/apps/gs-web.png
expect "a web app through Omarchy's omarchy-webapp-install: done, its launcher and icon in carol's files" \
  eval 'has "$out" "result=done" && grep -qxF "Exec=omarchy-launch-webapp \"https://example.org/\"" "$entry" && test -f "$icon"'
out=$(e2e webapp-remove "GS Web" https://example.org/)
expect "removed through omarchy-webapp-remove (no notification asked): done, launcher and icon gone" \
  eval 'has "$out" "result=done" && test ! -e "$entry" && test ! -e "$icon"'
# SR20: what store.json's record says against the system after a crash: an exit file 0 and everything there; no exit file
# and a part there.
quiet pacman -S --noconfirm gs-lib
ver=$(pacman -Q gs-lib | cut -d' ' -f2)
record() { # operation id, plan (JSON)
  runuser -u carol -- mkdir -p /home/carol/.local/state/grassfield
  python3 -I -c 'import json, sys
op = {"id": sys.argv[1], "kind": "install", "path": "helper", "app": "gs-lib", "name": "gs-lib", "packages": ["gs-lib"],
      "plan": json.loads(sys.argv[2]), "startedAt": "2026-10-27T10:00:00Z"}
json.dump({"version": 1, "operation": op}, open(sys.argv[3], "w"))' "$1" "$2" /home/carol/.local/state/grassfield/store.json
  chown carol: /home/carol/.local/state/grassfield/store.json
}
op=$(newop)
record "$op" "[{\"name\": \"gs-lib\", \"version\": \"$ver\"}]"
printf '0\n' >"$D/$op.exit"
out=$(e2e recover)
expect "recovery: the exit file 0 and gs-lib there -> done, nothing said" eval 'has "$out" "recovered=done"'
op=$(newop)
record "$op" "[{\"name\": \"gs-lib\", \"version\": \"$ver\"}, {\"name\": \"gs-missing\", \"version\": \"1-1\"}]"
out=$(e2e recover)
expect "recovery: no exit file, no helper running, one of two there -> interrupted, 1 of 2" \
  eval 'has "$out" "recovered=interrupted" && has "$out" "present=1/2"'
expect "  the record is gone once read" eval '! grep -q operation /home/carol/.local/state/grassfield/store.json'

say "A8 an Omarchy setup through the Store's terminal path and grassfield-store-run (step 3b1), as carol"
install -Dm755 /src/packaging/store/grassfield-store-run /usr/lib/grassfield/grassfield-store-run
# The test `firefox`, from a repository listed before Arch's own (the recipe asks pacman for that name).
mkpkg firefox 1 "" yes
mkdir -p /srv/gssetup && cp /home/builder/pkg/firefox-1/*.pkg.tar.zst /srv/gssetup/
quiet repo-add /srv/gssetup/gssetup.db.tar.gz /srv/gssetup/*.pkg.tar.zst
sed -i '/^\[core\]/i [gssetup]\nSigLevel = Optional TrustAll\nServer = file:///srv/gssetup\n' /etc/pacman.conf
quiet pacman -Sy
expect "pacman would take firefox from the test repository" test "$(pacman -Sp --print-format %r firefox 2>/dev/null)" == gssetup
printf 'carol ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/90-store-e2e && chmod 440 /etc/sudoers.d/90-store-e2e
# Omarchy's terminal, without a terminal: its command as its own bash -c, detached (the launcher's `setsid`), its output
# kept for the log.
printf '%s\n' '#!/bin/bash' 'setsid bash -c "$1" </dev/null >>/work/terminal.log 2>&1 &' >"$W/terminal" && chmod 755 "$W/terminal"
# The pins the catalog would carry: here every file of the tree's bin/ and install/helpers/ (the catalog pins only what its
# setups reach), as the Store writes them for the script.
(cd /omarchy && find bin install/helpers -type f -print0 | sort -z | xargs -0 sha256sum) >"$W/pins" && chmod 644 "$W/pins"
sed '1s/^[0-9a-f]\{8\}/00000000/' "$W/pins" >"$W/pins-changed"
setup() { runuser -u carol -- env -i HOME=/home/carol USER=carol PATH=/omarchy/bin:/usr/bin XDG_RUNTIME_DIR="/run/user/$cuid" \
  OMARCHY_PATH=/omarchy STORE_E2E_TERMINAL="$W/terminal" QT_QPA_PLATFORM=offscreen "$W/store_e2e" "$@" 2>>"$W/e2e.err"; }
out=$(setup setup-install org.mozilla.firefox omarchy-install-browser firefox firefox "$W/pins-changed")
sed 's/^/    /' <<<"$out"
expect "pins that differ from the installed Omarchy: refused by the plan, naming the file, nothing run" \
  eval 'grep -q "^plan=omarchyChanged packages= detail=$(head -1 "$W/pins" | cut -c67-)\$" <<<"$out" && ! pacman -Q firefox >/dev/null 2>&1'
out=$(setup setup-install org.mozilla.firefox omarchy-install-browser firefox firefox "$W/pins")
sed 's/^/    /' <<<"$out"
expect "omarchy-install-browser firefox: the plan names it, the recipe ran in the terminal's place, done (exit 0 and the state)" \
  eval 'has "$out" "plan=none packages=firefox detail=" && has "$out" "result=done" && test "$(pacman -Q firefox)" == "firefox 1-1"'
expect "  the recipe's own changes: Omarchy's Firefox policy as root, the Wayland setting in carol's files" \
  eval 'test -f /usr/lib/firefox/distribution/policies.json && grep -qx MOZ_ENABLE_WAYLAND=1 /home/carol/.config/environment.d/omarchy-firefox-wayland.conf'
expect "  Omarchy's update lock was held while it ran (by the script), and free after" \
  eval 'has "$out" "lock-while-running=1" && has "$out" "lock-after=0"'
expect "  the script's files are gone once the Store read them" eval 'test -z "$(ls -A /run/user/$cuid/grassfield/store)"'
out=$(setup setup-remove org.mozilla.firefox omarchy-remove-browser firefox firefox "$W/pins")
sed 's/^/    /' <<<"$out"
expect "omarchy-remove-browser firefox: the plan names it, done, firefox gone" \
  eval 'has "$out" "plan=none packages=firefox detail=" && has "$out" "result=done" && ! pacman -Q firefox >/dev/null 2>&1'
[[ -s $W/terminal.log ]] && { echo "  the terminal's last lines:"; tail -4 "$W/terminal.log" | sed 's/^/    /'; }
[[ -s $W/e2e.err ]] && { echo "  the driver's messages:"; head -5 "$W/e2e.err" | sed 's/^/    /'; }

say "A8 an AUR package through the Store's terminal path and grassfield-store-run (step 3b2), as carol"
# Two made-up AUR packages: gs-aur-app (an app; it needs gs-aur-lib from the AUR and gs-lib from [gstest]) and gs-aur-lib.
aurpkg() { # name deps entry(yes|no)
  local dir=/srv/gsaur/$1
  mkdir -p "$dir"
  {
    echo "pkgname=$1"; echo "pkgver=1.0"; echo "pkgrel=1"; echo "pkgdesc='Store AUR test package'"; echo "arch=(any)"
    echo "license=(MIT)"; echo "depends=($2)"; echo "options=(!strip !debug)"
    echo "package() {"
    echo "  install -Dm644 /dev/null \"\$pkgdir/usr/share/doc/$1/README\""
    [[ $3 == yes ]] && printf '  printf "[Desktop Entry]\\nType=Application\\nName=%s\\nExec=true\\n" >"$srcdir/%s.desktop"\n  install -Dm644 "$srcdir/%s.desktop" "$pkgdir/usr/share/applications/%s.desktop"\n' "$1" "$1" "$1" "$1"
    echo "}"
  } >"$dir/PKGBUILD"
}
aurpkg gs-aur-app "gs-aur-lib gs-lib" yes
aurpkg gs-aur-lib "" no
chmod -R a+rX /srv/gsaur
# The AUR's answers for them (RPC v5 multiinfo), as the dev plumbing's folder holds them.
mkdir -p /srv/gsaur-rpc
printf '%s' '{"version":5,"type":"multiinfo","resultcount":2,"results":[
  {"Name":"gs-aur-app","PackageBase":"gs-aur-app","Version":"1.0-1","Description":"A test app","Maintainer":"tester","NumVotes":3,
   "Popularity":0.1,"OutOfDate":null,"LastModified":1790000000,"FirstSubmitted":1700000000,"License":["MIT"],"Depends":["gs-aur-lib","gs-lib"]},
  {"Name":"gs-aur-lib","PackageBase":"gs-aur-lib","Version":"1.0-1","Description":"Its library","Maintainer":null,"NumVotes":0,
   "Popularity":0,"OutOfDate":null,"LastModified":1790000000,"FirstSubmitted":1700000000,"License":["MIT"]}]}' >/srv/gsaur-rpc/info.json
chmod -R a+rX /srv/gsaur-rpc
# yay's stand-in (above): only `-S --noconfirm --needed <names>`.
cat >/usr/bin/yay <<'YAY'
#!/bin/bash
set -euo pipefail
[[ ${1-} == -S ]] || { echo "yay (stand-in): only -S" >&2; exit 2; }
shift
names=()
for a in "$@"; do
  case $a in --noconfirm | --needed) ;; -*) echo "yay (stand-in): $a" >&2; exit 2 ;; *) names+=("$a") ;; esac
done
build() { # name asdeps
  local n=$1 dir d
  pacman -Q "$n" >/dev/null 2>&1 && return 0
  [[ -d /srv/gsaur/$n ]] || { echo "yay (stand-in): no AUR package $n" >&2; return 1; }
  # shellcheck disable=SC1090,SC1091
  for d in $(source "/srv/gsaur/$n/PKGBUILD" && echo "${depends[@]-}"); do
    [[ -d /srv/gsaur/$d ]] && build "$d" yes
  done
  dir=$(mktemp -d)
  cp -r "/srv/gsaur/$n/." "$dir/"
  (cd "$dir" && makepkg -s --noconfirm --needed)
  if [[ $2 == yes ]]; then sudo pacman -U --noconfirm --asdeps "$dir"/*.pkg.tar.zst; else sudo pacman -U --noconfirm "$dir"/*.pkg.tar.zst; fi
}
for n in "${names[@]}"; do build "$n" no; done
YAY
chmod 755 /usr/bin/yay
quiet pacman -Rns --noconfirm gs-lib 2>/dev/null
aur() { runuser -u carol -- env -i HOME=/home/carol USER=carol PATH=/omarchy/bin:/usr/bin XDG_RUNTIME_DIR="/run/user/$cuid" \
  OMARCHY_PATH=/omarchy STORE_E2E_TERMINAL="$W/terminal" QT_QPA_PLATFORM=offscreen "$W/store_e2e" "$@" 2>>"$W/e2e.err"; }
out=$(aur aur-install gs-aur-app "$W/pins-changed" /srv/gsaur-rpc)
expect "pins that differ: refused by the plan, nothing built" eval 'grep -q "^plan=omarchyChanged " <<<"$out" && ! pacman -Q gs-aur-app >/dev/null 2>&1'
out=$(aur aur-install gs-lib "$W/pins" /srv/gsaur-rpc)
expect "a name a repository has (gs-lib, [gstest]): refused by the plan (repository)" eval 'grep -q "^plan=repository " <<<"$out"'
out=$(aur aur-install gs-aur-gone "$W/pins" /srv/gsaur-rpc)
expect "a name the AUR does not know: refused by the plan (notOnAur)" eval 'grep -q "^plan=notOnAur .*detail=gs-aur-gone$" <<<"$out"'
out=$(aur aur-install omarchy-gs-theme "$W/pins" /srv/gsaur-rpc)
expect "a name with Omarchy's prefix (anyone can name an AUR package so): refused by the plan (protected), nothing built" \
  eval 'grep -q "^plan=protected " <<<"$out" && ! pacman -Q omarchy-gs-theme >/dev/null 2>&1'
out=$(aur aur-install gs-aur-app "$W/pins" /srv/gsaur-rpc)
sed 's/^/    /' <<<"$out"
expect "aur-install gs-aur-app: built gs-aur-app and gs-aur-lib, gs-lib from the repository, done (exit 0 and the state)" \
  eval 'has "$out" "plan=none built=gs-aur-app,gs-aur-lib packages=gs-lib detail=" && has "$out" "result=done" && pacman -Q gs-aur-app gs-aur-lib gs-lib >/dev/null'
expect "  gs-aur-app installed explicitly from outside the repositories, its library and gs-lib as dependencies" \
  eval 'pacman -Qqem | grep -qx gs-aur-app && pacman -Qqdm | grep -qx gs-aur-lib && pacman -Qqd | grep -qx gs-lib'
expect "  Omarchy's update lock was held while it ran (by the script), and free after" \
  eval 'has "$out" "lock-while-running=1" && has "$out" "lock-after=0"'
expect "  Omarchy's own omarchy-pkg-aur-add ran (the terminal's output)" grep -q "Grassfield Store runs Omarchy's omarchy-pkg-aur-add gs-aur-app" "$W/terminal.log"
out=$(aur aur-remove gs-aur-lib "$W/pins")
expect "aur-remove gs-aur-lib while gs-aur-app needs it: the plan names it, nothing runs" \
  eval 'grep -q "^plan=dependency packages= dependents=gs-aur-app" <<<"$out" && pacman -Q gs-aur-lib >/dev/null'
out=$(aur aur-remove gs-aur-app "$W/pins")
sed 's/^/    /' <<<"$out"
expect "aur-remove gs-aur-app: the whole plan (the app, its library, gs-lib), done through omarchy-pkg-drop, all gone" \
  eval 'has "$out" "result=done" && grep -qE "^plan=none packages=gs-aur-app,(gs-lib,gs-aur-lib|gs-aur-lib,gs-lib) " <<<"$out" && ! pacman -Q gs-aur-app >/dev/null 2>&1 && ! pacman -Q gs-aur-lib >/dev/null 2>&1'
[[ -s $W/terminal.log ]] && { echo "  the terminal's last lines:"; tail -4 "$W/terminal.log" | sed 's/^/    /'; }

say "A8 Get Flatpak through the Store's terminal path and grassfield-store-run (step 3c part 3, SD24), as carol"
# The real flatpak package from Arch's mirror, through Omarchy's own omarchy-pkg-add (the mounted tree, unchanged).
out=$(aur flatpak-get "$W/pins-changed")
expect "pins that differ: refused by the plan, nothing installed" eval 'grep -q "^plan=omarchyChanged " <<<"$out" && ! pacman -Q flatpak >/dev/null 2>&1'
out=$(aur flatpak-get "$W/pins")
sed 's/^/    /' <<<"$out"
expect "flatpak-get: the plan names flatpak and what pacman adds with it, done (exit 0 and the state)" \
  eval 'grep -qE "^plan=none packages=(.*,)?flatpak(,.*)? detail=$" <<<"$out" && has "$out" "result=done" && pacman -Q flatpak >/dev/null'
expect "  installed explicitly, as Omarchy's omarchy-pkg-add does" eval 'pacman -Qqe | grep -qx flatpak'
expect "  Omarchy's own omarchy-pkg-add ran (the terminal's output)" grep -q "Grassfield Store runs Omarchy's omarchy-pkg-add flatpak" "$W/terminal.log"
expect "  Omarchy's update lock was held while it ran (by the script), and free after" \
  eval 'has "$out" "lock-while-running=1" && has "$out" "lock-after=0"'
expect "  carol's own installation answers at once, before any new login (flatpak remotes --user)" \
  runuser -u carol -- env -i HOME=/home/carol PATH=/usr/bin flatpak remotes --user
[[ -s $W/terminal.log ]] && { echo "  the terminal's last lines:"; tail -4 "$W/terminal.log" | sed 's/^/    /'; }

say "result"
if ((fails)); then echo "$fails FAIL"; exit 1; fi
echo "all PASS"
