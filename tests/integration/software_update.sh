#!/usr/bin/env bash
# Software Update, step 1: the client in a throwaway Arch container (ADR-0033; docs/specs/updates.md acceptance A1-A7,
# A6b, A7b-A7e, A7g, and A8 with real gpgv signatures). Never on a real machine: inside, it refuses to run unless it is
# root in a container with the repository mounted at /src and an Omarchy 4.0.4 tree at /omarchy.
#
#   tests/integration/software_update.sh [--omarchy DIR] [--omarchy-next DIR]
#     DIR       an Omarchy 4.0.4 tree (default /usr/share/omarchy): its stable template, omarchy-refresh-pacman, omarchy-hook,
#               the 3.x->4 upgrade's awk and migrations 1787589206 and 1788112314 run as they are
#     --omarchy-next  an Omarchy 4.0.6 tree for migration 1791403252 (that case is SKIPPED without it)
#   Runs `docker run --rm --network host` on archlinux:base (digest pinned below) with the repository and the trees mounted
#   read-only; HTTPS_PROXY/HTTP_PROXY/NO_PROXY are passed through and GRASSFIELD_TEST_CA, when set, is mounted as the
#   container's CA bundle (for a proxied network). Exit 0 all PASS (or SKIP without docker), 1 a FAIL, 2 usage.
#
# Inside the container (an Omarchy stable machine: Omarchy's pacman.conf and mirrorlist, DisableSandbox added because
# Docker refuses Landlock, ADR-0033 R5): users `builder` (makepkg, keys), `alice` (passwordless sudo, standing for the warm
# sudo cache of Omarchy's hook; polkit allows her the Grassfield action and nothing else) and `bob` (no permission);
# throwaway keys K1 (pinned, with a signing subkey for the notes), K2 (a newer key) and KR (rogue), made here and gone with
# the container; fake grassfield-desktop packages carrying the REAL Software Update files (generate.py, the helper, the
# scriptlet, their library, the policy, the hook, grassfield-channel-set, grassfield-update-check) at the paths the
# PKGBUILD installs, with the real grassfield-desktop.install; a test grassfield-keyring with ADR-0033 b.2's layout (the
# real one is grassfieldhq/grassfield-packages'); signed file:// repositories (primary, mirror, new host). Real polkitd and
# pkexec run grassfield-channel-helper through the real policy.
set -uo pipefail

IMAGE=archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0

if [[ ${1:-} != --inside ]]; then
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
  omarchy=/usr/share/omarchy next=""
  while (($#)); do
    case $1 in
      --omarchy) omarchy=${2:?}; shift ;;
      --omarchy-next) next=${2:?}; shift ;;
      *) echo "usage: software_update.sh [--omarchy DIR] [--omarchy-next DIR]" >&2; exit 2 ;;
    esac
    shift
  done
  . "$root/tests/integration/container.sh" || exit 2
  gf_have_docker || { echo "SKIP: no docker daemon (this test runs only in a throwaway container)"; exit 0; }
  [[ -x $omarchy/bin/omarchy-refresh-pacman && -f $omarchy/migrations/1787589206.sh ]] ||
    { echo "SKIP: no Omarchy 4.0.4 tree at $omarchy (--omarchy DIR)"; exit 0; }
  if [[ -n $next ]]; then
    [[ -d $next/bin && -f $next/migrations/1791403252.sh ]] ||
      { echo "refused: --omarchy-next $next is not an Omarchy 4.0.6 tree (no bin/, no migrations/1791403252.sh)" >&2; exit 2; }
  fi
  gf_container_init "$root" || exit 2
  gf_standard auto || exit 2
  omarchy_mounts "$omarchy" /omarchy || exit 2
  if [[ -n $next ]]; then omarchy_mounts "$next" /omarchy-next || exit 2; fi
  gf_container_run "$IMAGE" bash /src/tests/integration/software_update.sh --inside
  exit $?
fi

[[ -f /.dockerenv && $(id -u) == 0 && -d /src/packaging/pacman && -d /omarchy/bin ]] ||
  { echo "refused: runs only as root inside a throwaway container (/src, /omarchy)"; exit 2; }

W=/work
mkdir -p "$W" && chmod 1777 "$W"   # builder writes package signatures here
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
expect() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; [[ -s $W/check.json ]] && sed 's/^/   last checker answer: /' "$W/check.json" "$W/check.err"; fi; }
say() { printf '\n== %s\n' "$*"; }
as() { local u=$1; shift; runuser -u "$u" -- env HOME="/home/$u" XDG_RUNTIME_DIR="/run/user/$(id -u "$u")" "$@"; }
quiet() { "$@" >>"$W/log" 2>&1; }
sha() { sha256sum "$@" 2>/dev/null | awk '{print $1}' | tr '\n' ' '; }
lastlines() { tail -n 2 /etc/pacman.conf | tr '\n' '|'; }
LINES='[grassfield]|Include = /etc/pacman.d/grassfield.conf|'
validity() { gpg --homedir /etc/pacman.d/gnupg --batch --no-tty --with-colons --list-keys "$1" 2>/dev/null | awk -F: '$1=="pub"{print $2; exit}'; }
nkeys() { gpg --homedir /etc/pacman.d/gnupg --batch --no-tty --with-colons --list-keys 2>/dev/null | grep -c '^pub:'; }
installed() { pacman -Q grassfield-desktop 2>/dev/null | awk '{print $2}'; }
# The checker as alice; prints selected fields of its JSON answer.
check_as() { # user fields...
  local u=$1; shift
  as "$u" /usr/lib/grassfield/grassfield-update-check >"$W/check.json" 2>"$W/check.err"
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
def get(path):
    v = d
    for k in path.split("."):
        v = v.get(k) if isinstance(v, dict) else None
    return v
print(" ".join(str(get(p)) for p in sys.argv[2:]))' "$W/check.json" "$@"
}
chset() { as "$1" grassfield-channel-set "${@:2}"; }
trusted() { [[ $(validity "$1") == [fu] ]]; }
export W
export -f as check_as chset validity trusted

say "setup: an Omarchy 4.0.4 stable machine"
cp /omarchy/default/pacman/pacman-stable.conf /etc/pacman.conf
cp /omarchy/default/pacman/mirrorlist-stable /etc/pacman.d/mirrorlist
sed -i 's/^DownloadUser = alpm$/DownloadUser = alpm\nDisableSandbox/' /etc/pacman.conf
quiet pacman-key --init
quiet pacman-key --populate archlinux
quiet pacman -Syu --noconfirm || { echo "FAIL: pacman -Syu on Omarchy's stable mirror (see $W/log)"; tail -5 "$W/log"; exit 1; }
quiet pacman -S --noconfirm --needed pacman-contrib sudo fakeroot binutils python polkit git diffutils || { echo "FAIL: tools"; exit 1; }
pacman -Q pacman pacman-contrib gnupg polkit | tr '\n' ' '; echo
useradd -m builder && useradd -m alice && useradd -m bob
for u in alice bob; do d=/run/user/$(id -u $u); mkdir -p "$d" && chown $u: "$d" && chmod 700 "$d"; done
# sudo keeps the proxy variables passed in, so that Omarchy's `sudo pacman` (A5, A7b) reaches the network the way root's
# pacman does; without a proxy they are unset and this changes nothing.
printf '%s\n' 'Defaults env_keep += "HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy"' 'alice ALL=(ALL) NOPASSWD: ALL' \
  >/etc/sudoers.d/90-alice && chmod 440 /etc/sudoers.d/90-alice
mkdir -p /run/dbus && dbus-daemon --system --fork
/usr/lib/polkit-1/polkitd --no-debug >"$W/polkitd.log" 2>&1 &
cat >/etc/polkit-1/rules.d/50-grassfield-test.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id == "org.grassfield.packages.set-channel" && subject.user == "alice") return polkit.Result.YES;
});
EOF

say "throwaway keys K1 (pinned; a signing subkey for the notes), K2, KR"
mkkey() { # name -> fingerprint
  as builder mkdir -p -m 700 "/home/builder/$1"
  as builder gpg --homedir "/home/builder/$1" --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "Grassfield $1 (throwaway) <$1@grassfield.invalid>" ed25519 sign 1d 2>/dev/null
  as builder gpg --homedir "/home/builder/$1" --with-colons --list-keys | awk -F: '$1=="fpr"{print $10; exit}'
}
K1=$(mkkey k1) K2=$(mkkey k2) KR=$(mkkey kr)
as builder gpg --homedir /home/builder/k1 --batch --pinentry-mode loopback --passphrase '' --quick-add-key "$K1" ed25519 sign 1d 2>/dev/null
K1SUB=$(as builder gpg --homedir /home/builder/k1 --with-colons --list-keys "$K1" | awk -F: '$1=="fpr"{n++} $1=="fpr" && n==2 {print $10}')
for k in k1 k2 kr; do as builder gpg --homedir "/home/builder/$k" --export >"$W/$k.gpg"; done
as builder gpg --homedir /home/builder/k1 --armor --export "$K1" >"$W/k1.asc"
echo "K1 $K1 (signing subkey $K1SUB)"; echo "K2 $K2"; echo "KR $KR"

say "T0 the build files: generate.py checks, and the paths the fake package installs are the PKGBUILD's"
G=/src/packaging/pacman/generate.py
conf() { printf 'GRASSFIELD_REPO_BASE=%s\nGRASSFIELD_REPO_MIRRORS=%s\nGRASSFIELD_REPO_BASE_PREVIOUS=%s\nGRASSFIELD_SIGNING_FINGERPRINT=%s\n' "$@"; }
gen() { rm -rf "$W/gen" && python3 -I "$G" --conf "$1" --key "$2" --out "$W/gen" 2>>"$W/log"; }
conf file:///srv/primary file:///srv/mirror file:///srv/old "$K1" >"$W/test.conf"
conf file:///srv/newhost "" file:///srv/primary "$K1" >"$W/newhost.conf"
expect "generate.py: the shipped repository.conf (packages.grassfield.site, the owner's key E4921A38, activated 2026-11-04) is a valid keyed build" gen /src/packaging/pacman/repository.conf /src/packaging/pacman/grassfield-signing-key.asc
expect "generate.py: the test build (file:// base, mirror, previous base, K1)" gen "$W/test.conf" "$W/k1.asc"
expect "templates: SigLevel = Required, the primary then the mirror, \$arch kept" bash -c "grep -v '^#' $W/gen/grassfield-beta.conf | tr '\n' '|' | grep -qxF 'SigLevel = Required|Server = file:///srv/primary/beta/\$arch|Server = file:///srv/mirror/beta/\$arch|'"
conf file:///srv/primary "" "" "$KR" >"$W/bad.conf"
expect "generate.py refuses a key file that is not the pinned fingerprint" bash -c "! python3 -I $G --conf $W/bad.conf --key $W/k1.asc --out $W/x 2>/dev/null"
conf file:///srv/primary "" "" "" >"$W/bad.conf"
expect "generate.py refuses a key file without a fingerprint" bash -c "! python3 -I $G --conf $W/bad.conf --key $W/k1.asc --out $W/x 2>/dev/null"
conf http://packages.example "" "" "$K1" >"$W/bad.conf"
expect "generate.py refuses an http:// base" bash -c "! python3 -I $G --conf $W/bad.conf --key $W/k1.asc --out $W/x 2>/dev/null"
as builder gpg --homedir /home/builder/k1 --batch --pinentry-mode loopback --passphrase '' --armor --export-secret-keys "$K1" >"$W/k1-secret.asc"
conf file:///srv/primary "" "" "$K1" >"$W/bad.conf"
expect "generate.py refuses a key file holding a secret key" bash -c "! python3 -I $G --conf $W/bad.conf --key $W/k1-secret.asc --out $W/x 2>/dev/null"
rm -f "$W/k1-secret.asc"
DEST=(usr/lib/grassfield/grassfield-channel-helper usr/lib/grassfield/grassfield-channel-scriptlet usr/lib/grassfield/grassfield-channel.sh
  usr/share/polkit-1/actions/org.grassfield.packages.policy usr/share/grassfield/pacman/ usr/share/grassfield/omarchy-hooks/pre-refresh-pacman)
missing=""
for d in "${DEST[@]}"; do grep -qF "\$pkgdir/$d" /src/packaging/arch/PKGBUILD || grep -qF "\$pkgdir/${d%/*}/" /src/packaging/arch/PKGBUILD || missing+=" $d"; done
grep -qE 'grassfield-channel-set( [a-z-]+)*; do' /src/packaging/arch/PKGBUILD || missing+=" usr/bin/grassfield-channel-set"
deps=" $(sed -n '/^package_grassfield-desktop()/,/^}/s/^  depends=(\(.*\))$/\1/p' /src/packaging/arch/PKGBUILD) "
for p in grassfield-keyring pacman-contrib fakeroot; do [[ $deps == *" $p "* ]] || missing+=" depends:$p"; done
expect "the PKGBUILD installs every path used here and grassfield-desktop depends on grassfield-keyring, pacman-contrib and fakeroot${missing:+ (missing:$missing)}" test -z "$missing"

say "packages (makepkg as builder) and repositories"
B=/home/builder/build
as builder mkdir -p "$B" /home/builder/pkgs
# grassfield-keyring with ADR-0033 b.2's layout: a private folder, populate only with keys and only while set up, pre_remove.
mk_keyring() { # pkgver keys...
  local v=$1 d=$B/keyring-$1 k
  shift
  as builder mkdir -p "$d"
  : >"$d/grassfield.gpg"; : >"$d/grassfield-trusted"; : >"$d/grassfield-revoked"
  for k in "$@"; do cat "$W/$k.gpg" >>"$d/grassfield.gpg"; done
  for k in "$@"; do case $k in k1) echo "$K1:4:" ;; k2) echo "$K2:4:" ;; esac; done >>"$d/grassfield-trusted"
  cat >"$d/grassfield-keyring.install" <<'EOF'
post_upgrade() {
	if [ -s usr/share/grassfield/pacman-keyring/grassfield.gpg ] && [ -e etc/pacman.d/grassfield.conf ]; then
		usr/bin/pacman-key --populate-from /usr/share/grassfield/pacman-keyring --populate grassfield
	fi
}
post_install() {
	post_upgrade
}
pre_remove() {
	while IFS=: read -r fpr _; do
		[ -n "$fpr" ] && usr/bin/pacman-key --list-keys "$fpr" >/dev/null 2>&1 && usr/bin/pacman-key --delete "$fpr" >/dev/null
	done <usr/share/grassfield/pacman-keyring/grassfield-trusted
	return 0
}
EOF
  cat >"$d/PKGBUILD" <<EOF
pkgname=grassfield-keyring
pkgver=$v
pkgrel=1
pkgdesc="test keyring"
arch=(any)
license=(MIT)
install=grassfield-keyring.install
source=(grassfield.gpg grassfield-trusted grassfield-revoked)
sha256sums=(SKIP SKIP SKIP)
options=(!debug !strip)
package() { install -Dm644 -t "\$pkgdir/usr/share/grassfield/pacman-keyring" grassfield.gpg grassfield-trusted grassfield-revoked; }
EOF
  chown -R builder: "$d"
  (cd "$d" && as builder makepkg -f --nodeps --noconfirm >>"$W/log" 2>&1) && cp "$d"/grassfield-keyring-"$v"-1-any.pkg.tar.zst "$W/"
}
# grassfield-desktop carrying the real Software Update files (generate.py's output for the given repository.conf).
mk_desktop() { # pkgver repository.conf
  local v=$1 d=$B/desktop-$1
  as builder mkdir -p "$d/files"
  gen "$2" "$W/k1.asc" || { fail "generate.py for $v"; return 1; }
  cp /src/packaging/pacman/{grassfield-channel-helper,grassfield-channel-scriptlet,grassfield-channel.sh,org.grassfield.packages.policy,pre-refresh-pacman} \
    /src/packaging/bin/{grassfield-channel-set,grassfield-update-check} "$W"/gen/* "$d/files/"
  cp /src/packaging/arch/grassfield-desktop.install "$d/"
  echo 1.0.0 >"$d/files/VERSION" # a plain version: stable is allowed (ADR-0033 O15b); the rule's cases below change the installed file
  cat >"$d/PKGBUILD" <<EOF
pkgname=grassfield-desktop
pkgver=$v
pkgrel=1
pkgdesc="test package carrying Grassfield's Software Update files"
arch=(any)
license=(MIT)
depends=(grassfield-keyring pacman-contrib fakeroot)
install=grassfield-desktop.install
options=(!debug !strip)
package() {
  local f=\$startdir/files
  install -Dm755 -t "\$pkgdir/usr/lib/grassfield/" "\$f/grassfield-channel-helper" "\$f/grassfield-channel-scriptlet" "\$f/grassfield-channel-set" "\$f/grassfield-update-check"
  install -Dm644 -t "\$pkgdir/usr/lib/grassfield/" "\$f/grassfield-channel.sh"
  install -d "\$pkgdir/usr/bin" && ln -s ../lib/grassfield/grassfield-channel-set "\$pkgdir/usr/bin/grassfield-channel-set"
  install -Dm644 "\$f/org.grassfield.packages.policy" "\$pkgdir/usr/share/polkit-1/actions/org.grassfield.packages.policy"
  install -Dm644 -t "\$pkgdir/usr/share/grassfield/pacman/" "\$f/repository.conf" "\$f/grassfield-stable.conf" "\$f/grassfield-beta.conf" "\$f/grassfield-signing-key.asc"
  install -Dm755 "\$f/pre-refresh-pacman" "\$pkgdir/usr/share/grassfield/omarchy-hooks/pre-refresh-pacman"
  install -Dm644 "\$f/VERSION" "\$pkgdir/usr/share/grassfield/VERSION"
}
EOF
  chown -R builder: "$d"
  (cd "$d" && as builder makepkg -f --nodeps --noconfirm >>"$W/log" 2>&1) && cp "$d/grassfield-desktop-$v-1-any.pkg.tar.zst" "$W/"
}
pkgsign() { # key package-file
  as builder gpg --homedir "/home/builder/$1" --batch --pinentry-mode loopback --passphrase '' --detach-sign --no-armor --yes \
    -o "$2.sig" "$2" 2>>"$W/log"
}
for v in 1.0.0 1.0.1 1.1.0beta1 1.1.0 1.1.1; do mk_desktop "$v" "$W/test.conf"; done
mk_desktop 2.0.0 "$W/newhost.conf"
mk_keyring 20261026 && mk_keyring 20261027 k1 && mk_keyring 20261028 k1 k2
chmod 644 "$W"/*.pkg.tar.zst
for v in 1.0.0 1.0.1 1.1.0beta1 1.1.0 1.1.1 2.0.0; do pkgsign k1 "$W/grassfield-desktop-$v-1-any.pkg.tar.zst"; done
for v in 20261027 20261028; do pkgsign k1 "$W/grassfield-keyring-$v-1-any.pkg.tar.zst"; done
# "Changed after signing": 1.1.1 built again (another build date, other bytes), kept beside the signed one.
mkdir -p "$W/signed" && mv "$W"/grassfield-desktop-1.1.1-1-any.pkg.tar.zst{,.sig} "$W/signed/"
sleep 1 && mk_desktop 1.1.1 "$W/test.conf" && mv "$W/grassfield-desktop-1.1.1-1-any.pkg.tar.zst" "$W/changed-1.1.1.pkg.tar.zst"
mv "$W"/signed/* "$W/" && chmod 644 "$W"/*.pkg.tar.zst
ls "$W"/*.pkg.tar.zst | wc -l | sed 's/^/packages built: /'
# A channel snapshot: <dir> <db-key> <notes-key|none> <channel> <package versions...> (packages signed by K1 unless set)
snapshot() {
  local dir=$1 dbkey=$2 notekey=$3 channel=$4 v rel=""
  shift 4
  rm -rf "$dir" && mkdir -p "$dir"
  for v in "$@"; do cp "$W/grassfield-desktop-$v-1-any.pkg.tar.zst"{,.sig} "$dir/" 2>/dev/null || cp "$W/grassfield-desktop-$v-1-any.pkg.tar.zst" "$dir/"; done
  cp "$W"/grassfield-keyring-20261027-1-any.pkg.tar.zst{,.sig} "$dir/"
  chown -R builder: "$dir"
  as builder env GNUPGHOME="/home/builder/$dbkey" repo-add --sign --prevent-downgrade "$dir/grassfield.db.tar.gz" "$dir"/*.pkg.tar.zst >>"$W/log" 2>&1
  for v in "$@"; do rel+="{\"version\":\"$v-1\",\"date\":\"2026-11-02\",\"notes\":{\"en\":\"Grassfield $v.\",\"fr\":\"Grassfield $v (fr).\"}},"; done
  printf '{"version":1,"channel":"%s","releases":[%s]}' "$channel" "${rel%,}" >"$dir/grassfield-notes.json"
  case $notekey in
    none) ;;
    k1sub) as builder gpg --homedir /home/builder/k1 --batch --pinentry-mode loopback --passphrase '' -u "$K1SUB!" --detach-sign --no-armor -o "$dir/grassfield-notes.json.sig" "$dir/grassfield-notes.json" 2>>"$W/log" ;;
    *) as builder gpg --homedir "/home/builder/$notekey" --batch --pinentry-mode loopback --passphrase '' --detach-sign --no-armor -o "$dir/grassfield-notes.json.sig" "$dir/grassfield-notes.json" 2>>"$W/log" ;;
  esac
  chmod -R a+rX "$dir"
}
mirror() { rm -rf /srv/mirror && cp -a /srv/primary /srv/mirror; }
snapshot /srv/primary/stable/x86_64 k1 k1sub stable 1.0.0
snapshot /srv/primary/beta/x86_64 k1 k1sub beta 1.0.0
mirror

say "A7g keyless keyring, then the first installation (pacman -U here: the verified path is ADR-0033 b.3a)"
before=$(nkeys)
quiet pacman -U --noconfirm "$W/grassfield-keyring-20261026-1-any.pkg.tar.zst"
expect "a keyless grassfield-keyring installs and trusts nothing ($before keys before and after)" test "$(nkeys)" == "$before"
# Copies without their .sig: pacman -U checks a signature that is present, and K1 is not trusted before Set Up.
mkdir -p "$W/first" && cp "$W/grassfield-keyring-20261027-1-any.pkg.tar.zst" "$W/grassfield-desktop-1.0.0-1-any.pkg.tar.zst" "$W/first/"
quiet pacman -U --noconfirm "$W"/first/*.pkg.tar.zst || fail "pacman -U of the first packages (see $W/log)"
expect "grassfield-keyring with K1 while updates are off: no populate, K1 not in pacman's keyring" test -z "$(validity "$K1")"
expect "grassfield-channel-set prints off" test "$(chset alice)" == off
expect "the checker says not-set-up" test "$(check_as alice state)" == not-set-up
pkaction --action-id org.grassfield.packages.set-channel --verbose | grep -E 'implicit|exec.path' | sed 's/^/   /'

say "A6b the helper and the scriptlet program: refusals, environment, atomic writes"
H=/usr/lib/grassfield/grassfield-channel-helper SC=/usr/lib/grassfield/grassfield-channel-scriptlet
state0=$(sha /etc/pacman.conf; ls -a /etc /etc/pacman.d | sha256sum)
as alice "$H" set stable >/dev/null 2>"$W/err"; rc=$?
expect "the helper run without root (alice, no pkexec) -> exit 1 'must run as root'" test "$rc:$(cat "$W/err")" == "1:grassfield-channel-helper: must run as root"
for a in "" "set" "set testing" "set beta extra" "remove" "upgrade" "restore now" "--help"; do
  # shellcheck disable=SC2086
  "$H" $a >/dev/null 2>&1; rc=$?
  expect "helper '${a}' -> usage, exit 2" test "$rc" == 2
done
for a in "" "off" "set stable" "restore" "remove now"; do
  # shellcheck disable=SC2086
  "$SC" $a >/dev/null 2>&1; rc=$?
  expect "scriptlet program '${a}' -> usage, exit 2" test "$rc" == 2
done
touch /var/lib/pacman/db.lck
"$H" set stable >/dev/null 2>"$W/err"; rc=$?
rm -f /var/lib/pacman/db.lck
expect "pacman's db.lck present -> set refused, exit 1" test "$rc:$(grep -c 'pacman is running' "$W/err")" == 1:1
cp /usr/share/grassfield/pacman/grassfield-signing-key.asc "$W/key.bak"
as builder gpg --homedir /home/builder/kr --armor --export "$KR" >/usr/share/grassfield/pacman/grassfield-signing-key.asc
"$H" set stable >/dev/null 2>"$W/err"; rc=$?
expect "the shipped key file is not the pinned fingerprint -> refused before pacman-key, KR not added" \
  test "$rc:$(validity "$KR"):$(grep -c 'is not the pinned key' "$W/err")" == "1::1"
cp "$W/key.bak" /usr/share/grassfield/pacman/grassfield-signing-key.asc
L=/run/grassfield/channel.lock
expect "the channel lock is root's own: /run/grassfield 0700, channel.lock 0600" test "$(stat -c %U:%a /run/grassfield $L | tr '\n' ' ')" == "root:700 root:600 "
out=$(runuser -u bob -- flock -n "$L" true 2>&1); rc=$?
expect "another user cannot open the lock, so cannot hold it (review of 0338116, MAJOR 1: '$out')" test "$rc" != 0
flock "$L" sleep 3 &
holder=$!
sleep 0.5
"$H" set stable >/dev/null 2>"$W/err"; rc=$?
wait "$holder"
expect "another change holds the channel lock -> the helper refuses at once, exit 1" test "$rc:$(grep -c 'another change' "$W/err")" == 1:1
(flock "$L" sleep 2 &) ; sleep 0.5
start=$(date +%s); "$SC" upgrade >/dev/null 2>&1; rc=$?
expect "... the scriptlet program waits for it instead (pacman's transaction must not fail)" test "$rc:$(( $(date +%s) - start >= 1 ))" == 0:1
chmod 0644 "$L"
"$H" restore >/dev/null 2>"$W/err"; rc=$?
chmod 0600 "$L"
expect "a lock that is not root's 0600 -> refused" test "$rc:$(grep -c "is not root's own" "$W/err")" == 1:1
touch /etc/.pacman.conf.grassfield.stale /etc/pacman.d/.grassfield.conf.stale
"$SC" upgrade >/dev/null 2>&1
expect "temporary files a killed run left in /etc are removed under the lock" bash -c '! ls /etc/.pacman.conf.grassfield.* /etc/pacman.d/.grassfield.conf.* 2>/dev/null'
# The environment of a running root program is empty: it runs itself again under env -i (review of 0338116, minor 2).
flock "$L" sleep 3 &
holder=$!
sleep 0.5
env 'BASH_FUNC_gpg%%=() { touch /work/pwned-child; }' FOO=bar "$SC" upgrade >/dev/null 2>&1 &
prog=$!
sleep 1
envbytes=$(wc -c </proc/$prog/environ)
cmd=$(tr '\0' ' ' </proc/$prog/cmdline)
wait "$holder"; wait "$prog"
expect "a root program waiting on the lock has an empty environment ($envbytes bytes; $cmd)" test "$envbytes" == 0
expect "nothing changed by the refusals (pacman.conf, /etc and /etc/pacman.d listings)" test "$(sha /etc/pacman.conf; ls -a /etc /etc/pacman.d | sha256sum)" == "$state0"
# The environment is not an input: BASH_ENV, an exported function shadowing awk, a PATH with a rogue pacman-conf.
mkdir -p "$W/evil" && printf '#!/bin/sh\ntouch %s/pwned-path\nexec /usr/bin/pacman-conf "$@"\n' "$W" >"$W/evil/pacman-conf" && chmod 755 "$W/evil/pacman-conf"
printf 'touch %s/pwned-bashenv\n' "$W" >"$W/evil/bashenv"
env BASH_ENV="$W/evil/bashenv" PATH="$W/evil:$PATH" SHELLOPTS=xtrace 'BASH_FUNC_awk%%=() { touch /work/pwned-fn; /usr/bin/awk "$@"; }' "$H" restore >/dev/null 2>&1
expect "BASH_ENV, an exported function and PATH are ignored (no marker written)" bash -c "! ls $W/pwned-* 2>/dev/null"
cp -a /usr/share/grassfield/pacman "$W/pacman.real"
gen /src/packaging/pacman/repository.conf /src/packaging/pacman/grassfield-signing-key.asc && cp "$W"/gen/* /usr/share/grassfield/pacman/
expect "the shipped build names the owner's key (E4921A382C349308BAA50D2F44C31B5D862EBEFA) and the real host" bash -c "grep -qx 'GRASSFIELD_SIGNING_FINGERPRINT=E4921A382C349308BAA50D2F44C31B5D862EBEFA' /usr/share/grassfield/pacman/repository.conf && grep -qx 'GRASSFIELD_REPO_BASE=https://packages.grassfield.site' /usr/share/grassfield/pacman/repository.conf"
# A build made without a key (the shipped files with the fingerprint blanked) still refuses.
sed -i "s/^GRASSFIELD_SIGNING_FINGERPRINT=.*/GRASSFIELD_SIGNING_FINGERPRINT=/" /usr/share/grassfield/pacman/repository.conf
out=$(chset alice stable 2>&1); rc=$?
expect "a keyless build: grassfield-channel-set stable refused 'no signing key in this build'" test "$rc:$(grep -c 'no signing key in this build' <<<"$out")" == 1:1
out=$("$H" set stable 2>&1); rc=$?
expect "... and the helper itself refuses the same" test "$rc:$(grep -c 'no signing key in this build' <<<"$out")" == 1:1
sed -i "s/^GRASSFIELD_SIGNING_FINGERPRINT=.*/GRASSFIELD_SIGNING_FINGERPRINT=$K1/" /usr/share/grassfield/pacman/repository.conf
sed -i "s|^GRASSFIELD_REPO_BASE=.*|GRASSFIELD_REPO_BASE=https://packages.grassfield.invalid|" /usr/share/grassfield/pacman/repository.conf
out=$(chset alice stable 2>&1); rc=$?
expect "a build whose base is the .invalid placeholder: refused 'no package repository in this build'" test "$rc:$(grep -c 'no package repository in this build' <<<"$out")" == 1:1
rm -rf /usr/share/grassfield/pacman && cp -a "$W/pacman.real" /usr/share/grassfield/pacman
# The channel rule (ADR-0033 O15b): stable is refused by the user's command and by the root helper, called directly, while the
# installed VERSION is a prerelease, missing or malformed; beta is not (tests/shell/channel_set_rule.sh covers the cases).
cp /usr/share/grassfield/VERSION "$W/VERSION.bak"
for v in 1.0.0-rc2 junk; do
  echo "$v" >/usr/share/grassfield/VERSION
  out=$(chset alice stable 2>&1); rc=$?
  expect "VERSION $v: grassfield-channel-set stable refused 'beta updates stay on'" test "$rc:$(grep -c 'beta updates stay on' <<<"$out")" == 1:1
  out=$("$H" set stable 2>&1); rc=$?
  expect "VERSION $v: the root helper refuses stable itself" test "$rc:$(grep -c 'beta updates stay on' <<<"$out")" == 1:1
done
rm -f /usr/share/grassfield/VERSION
out=$("$H" set stable 2>&1); rc=$?
expect "no VERSION: the root helper refuses stable" test "$rc:$(grep -c 'beta updates stay on' <<<"$out")" == 1:1
cp "$W/VERSION.bak" /usr/share/grassfield/VERSION
out=$(as alice sudo grassfield-channel-set stable 2>&1); rc=$?
expect "grassfield-channel-set as root -> refused 'run it as your user'" test "$rc:$(grep -c 'run it as your user' <<<"$out")" == 1:1
out=$(chset bob beta 2>&1); rc=$?
expect "bob, whom polkit does not allow -> 'not allowed', exit 1, nothing changed" test "$rc:$(chset bob):$(grep -c 'not allowed' <<<"$out")" == "1:off:1"

say "A1 Set Up through pkexec, then 1.0.1 published, found and installed"
chmod 0644 /etc/pacman.conf
out=$(chset alice stable 2>&1); rc=$?
expect "alice: grassfield-channel-set stable -> exit 0 (pkexec, the polkit action, the helper)" test "$rc" == 0 || echo "$out"
expect "pacman.conf ends with the two lines" test "$(lastlines)" == "$LINES"
expect "grassfield.conf is the packaged stable template" cmp -s /etc/pacman.d/grassfield.conf /usr/share/grassfield/pacman/grassfield-stable.conf
expect "the pinned key K1 is trusted (bootstrap: validity full or ultimate)" trusted "$K1"
expect "pacman.conf keeps its mode and owner (0644 root:root); no temporary file left in /etc or /etc/pacman.d" \
  test "$(stat -c '%a %U:%G' /etc/pacman.conf):$(ls -a /etc /etc/pacman.d | grep -cE '^\.(grassfield|pacman\.conf\.grassfield)')" == "644 root:root:0"
expect "the Omarchy hook link: ~/.config/omarchy/hooks/pre-refresh-pacman.d/50-grassfield" \
  test "$(readlink /home/alice/.config/omarchy/hooks/pre-refresh-pacman.d/50-grassfield)" == /usr/share/grassfield/omarchy-hooks/pre-refresh-pacman
expect "grassfield-channel-set prints stable; the checker: up-to-date on stable" test "$(chset alice) $(check_as alice state channel)" == "stable up-to-date stable"
pac_before=$(sha /var/lib/pacman/sync/* ; find /var/lib/pacman/local | sort | sha256sum)
snapshot /srv/primary/stable/x86_64 k1 k1sub stable 1.0.0 1.0.1 && mirror
expect "the checker finds Grassfield 1.0.0-1 -> 1.0.1-1 with its notes (signed by K1's subkey: VALIDSIG argument 10)" \
  test "$(check_as alice state grassfield.installed grassfield.available grassfield.notesError)" == "available 1.0.0-1 1.0.1-1 None"
python3 -I -c 'import json;n=json.load(open("/work/check.json"))["grassfield"]["notes"];print("   notes:", n)'
expect "the checker never touched pacman's own databases" test "$(sha /var/lib/pacman/sync/* ; find /var/lib/pacman/local | sort | sha256sum)" == "$pac_before"
cp /srv/primary/stable/x86_64/grassfield-notes.json.sig "$W/notes.sig"
as builder gpg --homedir /home/builder/kr --batch --pinentry-mode loopback --passphrase '' --detach-sign --no-armor --yes \
  -o /srv/primary/stable/x86_64/grassfield-notes.json.sig /srv/primary/stable/x86_64/grassfield-notes.json 2>>"$W/log"
expect "notes signed by the rogue key -> not shown, the update still offered (real gpgv)" test "$(check_as alice state grassfield.notesError)" == "available unavailable"
cp "$W/notes.sig" /srv/primary/stable/x86_64/grassfield-notes.json.sig
sed -i 's/Grassfield 1.0.1\./Grassfield 1.0.1 changed./' /srv/primary/stable/x86_64/grassfield-notes.json
expect "notes changed after signing -> not shown" test "$(check_as alice state grassfield.notesError)" == "available unavailable"
snapshot /srv/primary/stable/x86_64 k1 k1sub stable 1.0.0 1.0.1 && mirror
quiet pacman -Syu --noconfirm
expect "pacman -Syu installs 1.0.1-1 (A1)" test "$(installed)" == 1.0.1-1
expect "the checker: up-to-date" test "$(check_as alice state)" == up-to-date

say "A2/A7 beta, then back to stable without a downgrade"
snapshot /srv/primary/beta/x86_64 k1 k1sub beta 1.0.1 1.1.0beta1 && mirror
quiet pacman -Sy
expect "pacman's synced [grassfield] exists before the switch" test -f /var/lib/pacman/sync/grassfield.db
expect "grassfield-channel-set beta -> exit 0" chset alice beta
expect "the switch dropped pacman's synced [grassfield] files (A7, P7)" bash -c '! ls /var/lib/pacman/sync/grassfield.* 2>/dev/null'
expect "grassfield.conf is the beta template; the channel reads beta" test "$(cmp -s /etc/pacman.d/grassfield.conf /usr/share/grassfield/pacman/grassfield-beta.conf && echo same) $(chset alice)" == "same beta"
expect "the checker: 1.1.0beta1-1 available on beta" test "$(check_as alice state channel grassfield.available)" == "available beta 1.1.0beta1-1"
quiet pacman -Syu --noconfirm
expect "pacman -Syu installs 1.1.0beta1-1" test "$(installed)" == 1.1.0beta1-1
expect "grassfield-channel-set stable -> exit 0" chset alice stable
expect "back on stable: the checker lists nothing (no downgrade offered)" test "$(check_as alice state grassfield.available)" == "up-to-date None"
pacman -Syu --noconfirm >"$W/syu.log" 2>&1
expect "pacman -Syu keeps 1.1.0beta1-1 ('is newer than grassfield')" test "$(installed):$(grep -c 'is newer than grassfield' "$W/syu.log")" == 1.1.0beta1-1:1
snapshot /srv/primary/stable/x86_64 k1 k1sub stable 1.0.0 1.0.1 1.1.0 && mirror
expect "1.1.0 on stable: found" test "$(check_as alice state grassfield.available)" == "available 1.1.0-1"
quiet pacman -Syu --noconfirm
expect "pacman -Syu installs 1.1.0-1, past the beta" test "$(installed)" == 1.1.0-1

say "A3 bad packages are refused, nothing upgraded"
good=/srv/primary/stable/x86_64
cp -a "$good" "$W/good-stable"
bad_case() { # description, then the change to the 1.1.1 package in the snapshot
  local desc=$1
  snapshot "$good" k1 k1 stable 1.1.0 1.1.1
  "${@:2}"
  as builder env GNUPGHOME=/home/builder/k1 repo-add --sign "$good/grassfield.db.tar.gz" "$good/grassfield-desktop-1.1.1-1-any.pkg.tar.zst" >>"$W/log" 2>&1
  mirror
  rm -f /var/cache/pacman/pkg/grassfield-desktop-1.1.1-1-any.pkg.tar.zst*   # no copy left by the previous case
  pacman -Syu --noconfirm >"$W/bad.log" 2>&1; rc=$?
  expect "$desc -> pacman -Syu exit 1, still 1.1.0-1 ($(grep -m1 '^error:' "$W/bad.log"))" \
    test "$rc:$(installed)" == "1:1.1.0-1"
}
unsigned() { rm -f "$good/grassfield-desktop-1.1.1-1-any.pkg.tar.zst.sig"; }
rogue() { pkgsign kr "$good/grassfield-desktop-1.1.1-1-any.pkg.tar.zst"; }
changed() { cp "$W/changed-1.1.1.pkg.tar.zst" "$good/grassfield-desktop-1.1.1-1-any.pkg.tar.zst"; }
bad_case "an unsigned package" unsigned
bad_case "a package signed by the rogue key" rogue
bad_case "a package changed after signing" changed
rm -rf "$good" && cp -a "$W/good-stable" "$good" && mirror
quiet pacman -Sy

say "A4/A7c a corrupt or unreachable [grassfield]: the checker fails cleanly, blocking after two failures, Turn Off, mirrors"
pac_before=$(sha /var/lib/pacman/sync/* ; find /var/lib/pacman/local | sort | sha256sum)
cp "$good/grassfield.db.tar.gz" "$W/db.bak"
head -c 4096 /dev/urandom >"$good/grassfield.db.tar.gz"; cp -a "$good/grassfield.db.tar.gz" /srv/mirror/stable/x86_64/
r=$(check_as alice state error retryAt)
expect "a corrupt database: the checker answers failed/unavailable with a retry in 15 minutes, no crash ($r)" bash -c "[[ '$r' == 'failed unavailable 20'* ]]"
expect "pacman's own databases untouched by the checker" test "$(sha /var/lib/pacman/sync/* ; find /var/lib/pacman/local | sort | sha256sum)" == "$pac_before"
python3 -I -c 'import json,time;p="/home/alice/.cache/grassfield/health-db/failures";d=json.load(open(p));d["first"]-=1000;json.dump(d,open(p,"w"))'
chown alice: /home/alice/.cache/grassfield/health-db/failures
expect "a second failure 15 minutes after the first -> blocking (fake clock: the first failure moved back)" test "$(check_as alice state)" == blocking
pacman -Syu --noconfirm >/dev/null 2>&1; rc=$?
expect "while blocking, every system update fails (pacman -Syu exit 1)" test "$rc" == 1
out=$(chset alice off 2>&1); rc=$?
expect "Turn Off: grassfield-channel-set off -> exit 0" test "$rc" == 0 || echo "$out"
pacman -Syu --noconfirm >/dev/null 2>&1; rc=$?
expect "after Turn Off pacman -Syu works again (exit 0), no [grassfield] (A7c, U22)" test "$rc:$(pacman-conf --repo-list | grep -c grassfield)" == "0:0"
cp "$W/db.bak" "$good/grassfield.db.tar.gz" && mirror
expect "Set Up again (the keys were deleted by off: bootstrap again)" chset alice stable
mv /srv/primary "$W/primary.away"
expect "primary offline, the mirror answers: pacman -Sy exit 0 and the checker is not failed (A7c)" \
  bash -c "pacman -Sy >/dev/null 2>&1 && [[ \$(check_as alice state) == up-to-date ]]"
mv /srv/mirror "$W/mirror.away"
expect "primary and mirror offline: the checker answers failed (no crash)" test "$(check_as alice state)" == failed
mv "$W/primary.away" /srv/primary && mv "$W/mirror.away" /srv/mirror
expect "back online: up-to-date (the failure count cleared)" bash -c "[[ \$(check_as alice state) == up-to-date ]] && [[ ! -e /home/alice/.cache/grassfield/health-db/failures ]]"

say "A5 Omarchy's omarchy-refresh-pacman (4.0.4) rewrites pacman.conf: the hook keeps [grassfield]; without it, repair"
cp -a /omarchy "$W/omarchy"
sed -i 's/^DownloadUser = alpm$/DownloadUser = alpm\nDisableSandbox/' "$W/omarchy/default/pacman/pacman-stable.conf"   # Docker (R5)
refresh() { as alice env OMARCHY_PATH="$W/omarchy" PATH="$W/omarchy/bin:$PATH" bash "$W/omarchy/bin/omarchy-refresh-pacman" stable >"$W/refresh.log" 2>&1; }
rm -f /var/lib/pacman/sync/grassfield.*
refresh; rc=$?
expect "with the hook link: omarchy-refresh-pacman exit 0, [grassfield] last again, and synced by its -Syyuu" \
  test "$rc:$(lastlines):$(test -f /var/lib/pacman/sync/grassfield.db && echo synced)" == "0:$LINES:synced"
grep -q "Hook failed" "$W/refresh.log" && fail "omarchy-hook reported 'Hook failed'"
mv /home/alice/.config/omarchy/hooks/pre-refresh-pacman.d/50-grassfield "$W/hook.away"
refresh
expect "without the hook (another user's channel change): [grassfield] gone, the file kept" \
  test "$(pacman-conf --repo-list | grep -c grassfield):$(test -f /etc/pacman.d/grassfield.conf && echo kept)" == "0:kept"
expect "grassfield-channel-set and the checker say repair" test "$(chset alice) $(check_as alice state)" == "repair repair"
expect "grassfield-channel-set repair -> exit 0: the lines back, the hook linked again" bash -c \
  "runuser -u alice -- env HOME=/home/alice XDG_RUNTIME_DIR=/run/user/$(id -u alice) grassfield-channel-set repair >/dev/null && [[ \$(tail -n 2 /etc/pacman.conf | tr '\n' '|') == '$LINES' && -L /home/alice/.config/omarchy/hooks/pre-refresh-pacman.d/50-grassfield ]]"
expect "the checker: up-to-date on stable" test "$(check_as alice state channel)" == "up-to-date stable"
printf '\n[grassfield]\nInclude = /etc/pacman.d/grassfield.conf\n' >>/etc/pacman.conf
dup=$(pacman -Qq pacman 2>&1 | grep -m1 -iE 'error|warning' || true)
expect "[grassfield] twice (the hook racing the helper; pacman: '$dup'): the command and the checker say repair" \
  test "$(chset alice) $(check_as alice state)" == "repair repair"
expect "grassfield-channel-set repair leaves exactly one section, last; pacman works" bash -c \
  "runuser -u alice -- env HOME=/home/alice XDG_RUNTIME_DIR=/run/user/$(id -u alice) grassfield-channel-set repair >/dev/null && [[ \$(grep -c '^\[grassfield\]' /etc/pacman.conf) == 1 && \$(tail -n 2 /etc/pacman.conf | tr '\n' '|') == '$LINES' ]] && pacman -Qq pacman >/dev/null"
mkdir -p "$W/dangle" && ln -s /nonexistent/pre-refresh-pacman "$W/dangle/50-x"
cp -a "$W/dangle/50-x" /home/alice/.config/omarchy/hooks/pre-refresh-pacman.d/ && chown -h alice: /home/alice/.config/omarchy/hooks/pre-refresh-pacman.d/50-x
refresh; rc=$?
expect "a dangling link next to ours is skipped by omarchy-hook (exit 0, no 'Hook failed')" test "$rc:$(grep -c 'Hook failed' "$W/refresh.log")" == 0:0
rm -f /home/alice/.config/omarchy/hooks/pre-refresh-pacman.d/50-x

say "A7b the layout against Omarchy's other rewrites of pacman.conf"
cp /etc/pacman.conf "$W/pacman.conf.good"
sed -n "/BEGIN { in_omarchy = 0; wrote = 0 }/,/^  ' \/etc\/pacman.conf/p" /omarchy/bin/omarchy-upgrade-to-quattro | sed '$d' >"$W/quattro.awk"
awk -v server='https://pkgs.omarchy.org/stable/$arch' -f "$W/quattro.awk" /etc/pacman.conf >"$W/quattro.conf"
expect "the 3.x->4 upgrade's awk keeps [grassfield], last" test "$(pacman-conf --config "$W/quattro.conf" --repo-list | tail -n 1)" == grassfield
mkdir -p "$W/stub" && printf '#!/bin/sh\nexit 0\n' >"$W/stub/omarchy-pkg-missing" && printf '#!/bin/sh\nexit 0\n' >"$W/stub/omarchy-update-keyring" && chmod 755 "$W"/stub/*
sed -i 's|^\[omarchy\]$|[omarchy]\nSigLevel = Optional TrustAll|' /etc/pacman.conf
as alice env OMARCHY_PATH=/omarchy PATH="$W/stub:/omarchy/bin:$PATH" bash /omarchy/migrations/1787589206.sh >/dev/null 2>&1
expect "migration 1787589206 (TrustAll dropped; its keyring step stubbed) keeps [grassfield] last" \
  test "$(grep -c TrustAll /etc/pacman.conf):$(lastlines)" == "0:$LINES"
cp /etc/pacman.d/mirrorlist "$W/mirrorlist.good"
echo 'Server = https://rc-mirror.omarchy.org/$repo/os/$arch' >/etc/pacman.d/mirrorlist
sed -i 's|^Server = https://pkgs.omarchy.org/stable/|Server = https://pkgs.omarchy.org/edge/|' /etc/pacman.conf
as alice env OMARCHY_PATH=/omarchy PATH="/omarchy/bin:$PATH" bash /omarchy/migrations/1788112314.sh >/dev/null 2>&1
expect "migration 1788112314 (an rc machine's [omarchy] moved to rc) keeps [grassfield] last" \
  test "$(grep -c 'pkgs.omarchy.org/rc/' /etc/pacman.conf):$(lastlines)" == "1:$LINES"
cp "$W/mirrorlist.good" /etc/pacman.d/mirrorlist && cp "$W/pacman.conf.good" /etc/pacman.conf
if [[ -f /omarchy-next/migrations/1791403252.sh ]]; then
  as alice env OMARCHY_PATH=/omarchy-next PATH="/omarchy-next/bin:$PATH" bash /omarchy-next/migrations/1791403252.sh >"$W/m.log" 2>&1; rc=$?
  expect "4.0.6's migration 1791403252 ([omarchy] moved first, then its pacman -Syu): exit 0, [grassfield] last" \
    test "$rc:$(pacman-conf --repo-list | head -n 1):$(lastlines)" == "0:omarchy:$LINES"
  cp "$W/pacman.conf.good" /etc/pacman.conf
else
  echo "SKIP: migration 1791403252 (no --omarchy-next 4.0.6 tree)"
fi

say "A7e a host change: post_upgrade migrates a configuration on the previous base; a custom one stays; Repair rewrites it"
snapshot /srv/primary/stable/x86_64 k1 k1sub stable 1.1.0 2.0.0 && mirror
snapshot /srv/newhost/stable/x86_64 k1 k1sub stable 1.1.0 2.0.0
quiet pacman -Syu --noconfirm
expect "2.0.0 (built for the new host, the old one as previous) installed from the old host" test "$(installed)" == 2.0.0-1
# Inside the transaction the synced [grassfield] files are kept (deleting them would make every grassfield-* package foreign
# for the rest of omarchy update, whose omarchy-update-aur-pkgs runs yay -Sua: GF-045, ADR-0050 security review HIGH 1);
# their time goes to the epoch, so the next sync downloads the database and its signature again.
expect "its post_upgrade rewrote grassfield.conf for the new host (stable); the synced database and signature kept, their time the epoch" \
  test "$(grep -v '^#' /etc/pacman.d/grassfield.conf | tr '\n' '|'):$(stat -c %Y /var/lib/pacman/sync/grassfield.db /var/lib/pacman/sync/grassfield.db.sig 2>/dev/null | tr '\n' ' ')" == 'SigLevel = Required|Server = file:///srv/newhost/stable/$arch|:0 0 '
expect "pacman -Qm lists no grassfield-* package after the migration (yay -Sua would see them as foreign)" \
  bash -c "! pacman -Qmq 2>/dev/null | grep -q '^grassfield-'"
# ADR-0050 (A17), to add with a snapshot that carries the marker package grassfield-rollout 1-1 (NOT VERIFIED, not run here):
#   1. publish the marker in /srv/primary/stable/x86_64 and serve the 20 cohort paths /srv/primary/stable/cohort/NN/x86_64 as
#      copies of that snapshot; pacman -Syu installing a newer grassfield-desktop: its post_upgrade (pacman holding db.lck)
#      runs `pacman -Sl grassfield`, gets the marker and writes the cohort form; the synced files keep their time (plain ->
#      cohort: their time the epoch); pacman -Qmq lists no grassfield-*; the next pacman -Sy from the cohort path exits 0
#      with a 200 for the database and its signature;
#   2. a cohort path missing (404): pacman falls back to the plain lines for the database and its signature, -Sy exits 0;
#   3. the marker withdrawn: the next Grassfield upgrade writes the plain form, the synced files' time the epoch, -Sy exits 0
#      with a 200 for both files (no "signature ... is invalid");
#   4. /var/lib/pacman/sync/grassfield.db removed before an upgrade: post_upgrade's pacman -Sl prints nothing and exits 0
#      (a missing database is no error to libalpm); the scriptlet reads that as no listing and the form is unchanged.
expect "pacman -Sy from the new host; channel stable" bash -c "pacman -Sy >/dev/null 2>&1 && [[ \$(runuser -u alice -- env HOME=/home/alice grassfield-channel-set) == stable ]]"
printf 'SigLevel = Required\nServer = file:///srv/custom/beta/$arch\n' >/etc/pacman.d/grassfield.conf
expect "a file naming neither the base nor a previous one: the scriptlet's upgrade leaves it alone; the channel reads custom" \
  bash -c "/usr/lib/grassfield/grassfield-channel-scriptlet upgrade && grep -q 'srv/custom/beta' /etc/pacman.d/grassfield.conf && [[ \$(chset alice) == custom ]]"
expect "Repair in custom rewrites it from the template, keeping beta (the channel the path names)" \
  bash -c "runuser -u alice -- env HOME=/home/alice XDG_RUNTIME_DIR=/run/user/$(id -u alice) grassfield-channel-set repair >/dev/null && cmp -s /etc/pacman.d/grassfield.conf /usr/share/grassfield/pacman/grassfield-beta.conf"
chset alice stable >/dev/null

say "A7g set populates a newer key; A6/A7d off and pacman -Rns take the section and the keys away"
quiet pacman -U --noconfirm "$W/grassfield-keyring-20261028-1-any.pkg.tar.zst"
expect "a keyring upgrade while set up populates K2 too" trusted "$K2"
expect "off -> exit 0" chset alice off
expect "off: no lines, no file, no synced files, K1 and K2 gone, the hook link gone, pacman works" test \
  "$(grep -c grassfield /etc/pacman.conf):$(ls /etc/pacman.d/grassfield.conf /var/lib/pacman/sync/grassfield.* 2>/dev/null | wc -l):$(validity "$K1")$(validity "$K2"):$(ls /home/alice/.config/omarchy/hooks/pre-refresh-pacman.d | wc -l):$(pacman -Qq pacman)" \
  == "0:0::0:pacman"
quiet pacman-key --populate
expect "after off, a plain pacman-key --populate trusts no Grassfield key (the private keyring folder, R2)" test -z "$(validity "$K1")$(validity "$K2")"
snapshot /srv/newhost/stable/x86_64 k2 k1sub stable 2.0.0
expect "Set Up again with K1+K2 installed: the bootstrap trusts K1, populate trusts K2; a database signed by K2 syncs (R3)" \
  bash -c "runuser -u alice -- env HOME=/home/alice XDG_RUNTIME_DIR=/run/user/$(id -u alice) grassfield-channel-set stable >/dev/null && pacman -Sy >/dev/null 2>&1"
pacman -Rns --noconfirm grassfield-desktop grassfield-keyring >"$W/rns.log" 2>&1; rc=$?
expect "pacman -Rns grassfield-desktop grassfield-keyring: exit 0; no [grassfield] line, no file, no Grassfield key; pacman works (A7d)" \
  test "$rc:$(grep -c grassfield /etc/pacman.conf):$(ls /etc/pacman.d/grassfield.conf 2>/dev/null | wc -l):$(validity "$K1")$(validity "$K2"):$(pacman -Qq pacman)" == "0:0:0::pacman"
expect "the hook link left behind dangles and omarchy-hook skips it silently" bash -c "refresh() { runuser -u alice -- env HOME=/home/alice OMARCHY_PATH=$W/omarchy PATH=$W/omarchy/bin:\$PATH bash $W/omarchy/bin/omarchy-refresh-pacman stable; }; out=\$(refresh 2>&1); ! grep -q 'Hook failed' <<<\"\$out\""

say "A7f/A7h/A8 the checker's own tests as a user (its lock, Omarchy's update lock and the waiter need one)"
git config --system --add safe.directory '*'
as alice env TMPDIR=/tmp bash /src/tests/shell/update_check.sh >"$W/unit.log" 2>&1; rc=$?
grep -E '^(FAIL|SKIP)' "$W/unit.log"
((rc == 0)) || tail -n 12 "$W/unit.log" | sed 's/^/   unit.log: /'
expect "tests/shell/update_check.sh as alice: $(grep -c '^PASS' "$W/unit.log") PASS" test "$rc:$(grep -c '^FAIL' "$W/unit.log")" == 0:0

say "done: $fails failure(s)"
((fails == 0))
