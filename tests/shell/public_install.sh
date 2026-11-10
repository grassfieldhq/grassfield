#!/usr/bin/env bash
# Offline test of Grassfield's public installation script (ADR-0043): packaging/install/render.py and the rendered
# grassfield-install.sh, run against STUB commands in a throwaway fake root. It never runs the real pacman, pacman-key, gpg,
# sudo, curl, plymouth or mkinitcpio: the script's PATH holds only the stubs and symlinks to harmless coreutils, so a command
# the script calls that has no stub fails the test instead of reaching the machine. Layer: logic (no session, no root, no
# network). The tested script is the template rendered with --test-hook (a file prefix); the published one differs by exactly
# those marked lines, which section 1 checks.
#
# The same script can run for real inside an Arch container (as tests/integration/update_helper.sh does for the update
# helper): a container with a local repository and the real pacman is the follow-up the grassfield-packages repository owns
# (ADR-0043 g); this test covers the script's logic, order, rollback and idempotence.
# shellcheck disable=SC2015  # `test && pass || fail`: pass never fails
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
expect() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1: got '$2', want '$3'"; fi; }
has() { if grep -Fq -- "$2" "$3"; then pass "$1"; else fail "$1: '$2' not in $3"; fi; }
hasnt() { if grep -Fq -- "$2" "$3"; then fail "$1: '$2' found in $3"; else pass "$1"; fi; }

FPR=0123456789ABCDEF0123456789ABCDEF01234567
BASE=https://packages.example.test
BIN=$W/bin S=$W/state R=$W/root
TPL=$root/packaging/install/grassfield-install.sh.in
mkdir -p "$BIN" "$S" "$W/home" "$W/run" "$W/tmp" "$W/render"

# The channel is decided by VERSION (ADR-0043 h): the scripts under test use a plain version (default stable); section 15 uses a
# prerelease (default beta, stable refused).
echo 1.0.0 >"$W/version-plain"
echo 1.0.0-rc2 >"$W/version-pre"
VPLAIN=(--version-file "$W/version-plain")

# ---- 1. render.py ---------------------------------------------------------------------------------------------------
printf 'GRASSFIELD_REPO_BASE=%s\nGRASSFIELD_REPO_MIRRORS=\nGRASSFIELD_REPO_BASE_PREVIOUS=\nGRASSFIELD_SIGNING_FINGERPRINT=%s\n' \
  "$BASE" "$FPR" >"$W/good.conf"
# The shipped repository.conf names the real host and the owner's key since 2026-11-04 (ADR-0043 g): it renders. The
# placeholder refusal is tested on a conf with the old .invalid base.
python3 -I "$root/packaging/install/render.py" --conf "$root/packaging/pacman/repository.conf" --template "$TPL" \
  --out "$W/render/shipped" --version-file "$W/version-pre" >"$W/o" 2>&1
expect 'render accepts the shipped repository.conf (real host, owner key)' "$?" 0
sed 's#^GRASSFIELD_REPO_BASE=.*#GRASSFIELD_REPO_BASE=https://packages.grassfield.invalid#' "$W/good.conf" >"$W/placeholder.conf"
python3 -I "$root/packaging/install/render.py" --conf "$W/placeholder.conf" --template "$TPL" \
  --out "$W/render/placeholder" >"$W/o" 2>&1
expect 'render refuses the placeholder repository.conf' "$?" 1
has 'render names the placeholder' 'placeholder' "$W/o"
[[ ! -e $W/render/placeholder ]] && pass 'nothing written for a placeholder' || fail 'files written for a placeholder'
sed 's/^GRASSFIELD_SIGNING_FINGERPRINT=.*/GRASSFIELD_SIGNING_FINGERPRINT=/' "$W/good.conf" >"$W/nofpr.conf"
python3 -I "$root/packaging/install/render.py" --conf "$W/nofpr.conf" --template "$TPL" --out "$W/render/nofpr" >"$W/o" 2>&1
expect 'render refuses an empty fingerprint' "$?" 1
sed 's#^GRASSFIELD_REPO_BASE=.*#GRASSFIELD_REPO_BASE=file:///srv/repo#' "$W/good.conf" >"$W/file.conf"
python3 -I "$root/packaging/install/render.py" --conf "$W/file.conf" --template "$TPL" --out "$W/render/file" >"$W/o" 2>&1
expect 'render refuses a non-https base' "$?" 1
python3 -I "$root/packaging/install/render.py" --conf "$W/good.conf" --template "$TPL" --out "$W/render/pub" "${VPLAIN[@]}" >"$W/o" 2>&1
expect 'render (published form) with a real host and key' "$?" 0
PUB=$W/render/pub/grassfield-install.sh
python3 -I "$root/packaging/install/render.py" --conf "$W/good.conf" --template "$TPL" --out "$W/render/ok" --test-hook "${VPLAIN[@]}" >"$W/o" 2>&1
expect 'render (test form)' "$?" 0
SCRIPT=$W/render/ok/grassfield-install.sh
(cd "$W/render/pub" && sha256sum -c grassfield-install.sh.sha256 >/dev/null 2>&1)
expect 'the published checksum matches the script' "$?" 0
bash -n "$PUB"
expect 'published script parses' "$?" 0
bash -n "$SCRIPT"
expect 'test script parses' "$?" 0
grep -q '@GRASSFIELD' "$PUB" && fail 'a marker is left in the rendered script' || pass 'no marker left'
has 'the fingerprint is pinned in the script' "readonly GF_FPR='$FPR'" "$PUB"
has 'the keyserver is hkps' "readonly GF_KEYSERVER=hkps://keys.openpgp.org" "$PUB"
hasnt 'the published script has no test hook' 'GRASSFIELD_INSTALL_ROOT' "$PUB"
hasnt 'the published script has no hook marker' 'TEST-HOOK' "$PUB"
expect 'the test form differs from the published one by the two hook lines only' \
  "$(diff "$SCRIPT" "$PUB" | grep -c '^<')/$(diff "$SCRIPT" "$PUB" | grep -c '^>')" '2/0'

# ---- stubs ----------------------------------------------------------------------------------------------------------
for c in awk grep sed cat tee cp rm mkdir mktemp date cmp sort head tail tr dirname basename env bash timeout vercmp chmod cut wc \
  touch printf true false find install; do
  p=$(command -v "$c") && [[ $p == /* ]] && ln -sf "$p" "$BIN/$c"
done
stub() { cat >"$BIN/$1"; chmod +x "$BIN/$1"; }

mk_sudo() {
  stub sudo <<'EOF'
#!/bin/bash
echo "sudo $*" >>"$GF_STUB/calls"
[[ ${1:-} == -v ]] && exit 0
exec "$@"
EOF
}
mk_sudo
stub id <<'EOF'
#!/bin/bash
cat "$GF_STUB/uid" 2>/dev/null || echo 1000
EOF
stub uname <<'EOF'
#!/bin/bash
echo x86_64
EOF
stub df <<'EOF'
#!/bin/bash
printf 'Avail\n%sM\n' "$(cat "$GF_STUB/free" 2>/dev/null || echo 20000)"
EOF
stub flock <<'EOF'
#!/bin/bash
echo "flock $*" >>"$GF_STUB/calls"
exit 0
EOF
stub checkupdates <<'EOF'
#!/bin/bash
if [[ -s $GF_STUB/checkupdates ]]; then cat "$GF_STUB/checkupdates"; exit 0; fi
exit "$(cat "$GF_STUB/cu_rc" 2>/dev/null || echo 2)"
EOF
stub pacman-conf <<'EOF'
#!/bin/bash
file=$2
case $3 in
  DBPath) echo "$GRASSFIELD_INSTALL_ROOT/var/lib/pacman/"; exit 0 ;;
  GPGDir) echo "$GRASSFIELD_INSTALL_ROOT/etc/pacman.d/gnupg/"; exit 0 ;;
esac
[[ -f $GF_STUB/conf_broken ]] && { awk '/^\[/ { gsub(/[][]/, ""); if ($0 != "options" && $0 != "grassfield") print }' "$file"; exit 0; }
awk '/^\[/ { gsub(/[][]/, ""); if ($0 != "options") print }' "$file"
EOF
stub pacman <<'EOF'
#!/bin/bash
echo "pacman $*" >>"$GF_STUB/calls"
inst=$GF_STUB/installed
rootd=$GRASSFIELD_INSTALL_ROOT
case $1 in
  -Q)
    case $2 in
      omarchy) [[ -f $GF_STUB/omarchy ]] && echo "omarchy $(cat "$GF_STUB/omarchy")" || exit 1 ;;
      quickshell) echo "quickshell $(cat "$GF_STUB/quickshell")" ;;
      hyprland) echo "hyprland 0.56.2-4" ;;
      qt6-base) echo "qt6-base 6.12.0-1" ;;
      *) grep -qx "$2" "$inst" 2>/dev/null && echo "$2 1.0.0-1" || exit 1 ;;
    esac ;;
  -Qq) cat "$inst" 2>/dev/null; exit 0 ;;
  -Qm) cat "$GF_STUB/foreign" 2>/dev/null; exit 0 ;;
  -Qu) cat "$GF_STUB/qu" 2>/dev/null; exit 0 ;;
  -Si)
    # French pacman prints "Depot"; only LC_ALL=C gives the English field the script parses.
    if [[ ${LC_ALL:-} == C ]]; then label=Repository; else label="Dépôt"; fi
    echo "$label      : $(cat "$GF_STUB/qs_repo")"; echo "Name            : $2" ;;
  -Sy)
    mkdir -p "$rootd/var/lib/pacman/sync"; : >"$rootd/var/lib/pacman/sync/grassfield.db"
    [[ -f $GF_STUB/sync_edit ]] && printf '# later edit\n' >>"$rootd/etc/pacman.conf"
    # A real signal sent to the script (this process's parent) in the middle of the sync.
    [[ -f $GF_STUB/sync_signal ]] && { kill -s "$(cat "$GF_STUB/sync_signal")" "$PPID"; exit 0; }
    [[ -f $GF_STUB/sync_fail ]] && exit 1
    exit 0 ;;
  -S)
    shift
    print=0; pk=()
    for a in "$@"; do case $a in --print) print=1 ;; -*) ;; *) pk+=("$a") ;; esac; done
    if ((print)); then [[ -f $GF_STUB/resolve_fail ]] && { echo "error: could not satisfy dependencies" >&2; exit 1; }; exit 0; fi
    [[ -f $GF_STUB/install_fail ]] && { echo "error: failed to commit transaction" >&2; exit 1; }
    [[ -f $GF_STUB/install_partial ]] && { echo "grassfield-desktop" >>"$inst"; echo "error: failed to commit transaction (later package)" >&2; exit 1; }
    printf '%s\n' "${pk[@]}" >>"$inst"
    printf '%s\n' grassfield-icons grassfield-wallpapers grassfield-keyring grassfield-hold >>"$inst"
    for a in "${pk[@]}"; do
      if [[ $a == grassfield-login-themes ]]; then
        mkdir -p "$rootd/usr/share/sddm/themes/grassfield" "$rootd/usr/share/plymouth/themes/grassfield"
      fi
    done ;;
  -Rns)
    shift
    for a in "$@"; do [[ $a == -* ]] || sed -i "/^$a\$/d" "$inst"; done
    "$GF_STUB/offlogic" ;;
esac
EOF
cat >"$W/offlogic" <<'EOF'
#!/bin/bash
# What grassfield-channel-set off / the scriptlet's remove does to the fake machine.
f=$GRASSFIELD_INSTALL_ROOT/etc/pacman.conf
if [[ -f $f ]]; then
  awk '{ l = $0; sub(/#.*/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l) }
       l == "[grassfield]" { skip = 2 }
       skip > 0 { skip--; next } { print }' "$f" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' >"$f.new" && cat "$f.new" >"$f" && rm -f "$f.new"
fi
rm -f "$GRASSFIELD_INSTALL_ROOT/etc/pacman.d/grassfield.conf"
: >"$GF_STUB/keys"
EOF
chmod +x "$W/offlogic"
stub pacman-key <<'EOF'
#!/bin/bash
echo "pacman-key $*" >>"$GF_STUB/calls"
case $1 in
  --list-keys) grep -q "$2" "$GF_STUB/keys" 2>/dev/null ;;
  --add) grep -o '[0-9A-F]\{40\}' "$2" | head -n 1 >>"$GF_STUB/keys" ;;
  --lsign-key) [[ -f $GF_STUB/lsign_fail ]] && exit 1; grep -q "$2" "$GF_STUB/keys" 2>/dev/null ;;
  --delete)
    # A second Ctrl-C while the rollback deletes the key: the script must ignore it and finish.
    [[ -f $GF_STUB/delete_signal ]] && kill -s INT "$PPID"
    sed -i "/$2/d" "$GF_STUB/keys" ;;
esac
EOF
stub curl <<'EOF'
#!/bin/bash
echo "curl $*" >>"$GF_STUB/calls"
[[ -f $GF_STUB/netdown ]] && exit 6
out=''
while (($#)); do [[ $1 == -o ]] && out=$2; shift; done
[[ -n $out ]] && cat "$GF_STUB/keyfile" >"$out"
exit 0
EOF
stub gpg <<'EOF'
#!/bin/bash
echo "gpg $*" >>"$GF_STUB/calls"
home='' prev=''
for a in "$@"; do [[ $prev == --homedir ]] && home=$a; prev=$a; done
render() {
  case $1 in
    SECRETKEY) printf 'sec:u:255:22:AAAA:1::::::::\nfpr:::::::::%s:\n' "$GF_STUB_FPR" ;;
    # an impostor's key: its own primary, the pinned fingerprint only on a SUBKEY
    SUBKEYMATCH) printf 'pub:u:255:22:AAAA:1::::::::\nfpr:::::::::EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE:\nsub:u:255:22:BBBB:1::::::::\nfpr:::::::::%s:\n' "$GF_STUB_FPR" ;;
    *) printf 'pub:u:255:22:AAAA:1::::::::\nfpr:::::::::%s:\n' "$1" ;;
  esac
}
case " $* " in
  *" --recv-keys "*) [[ -f $GF_STUB/keyserver_down ]] && exit 2; cat "$GF_STUB/ksfile" >"$home/ks"; exit 0 ;;
  *" --export "*) cat "$home/ks" ;;
  *" --list-keys "*)
    grep -q "$GF_STUB_FPR" "$GF_STUB/keys" 2>/dev/null || exit 2
    if [[ -f $GF_STUB/keyring_odd ]]; then render SUBKEYMATCH; else render "$GF_STUB_FPR"; fi ;;
  *" --import "*) render "$(cat "${*: -1}")" ;;
esac
EOF
stub omarchy-snapshot <<'EOF'
#!/bin/bash
echo "omarchy-snapshot $*" >>"$GF_STUB/calls"
exit "$(cat "$GF_STUB/snap_rc" 2>/dev/null || echo 0)"
EOF
mk_channel_set() {
  stub grassfield-channel-set <<'EOF'
#!/bin/bash
echo "grassfield-channel-set $*" >>"$GF_STUB/calls"
[[ $1 == off ]] && "$GF_STUB/offlogic"
exit 0
EOF
}
mk_channel_set
stub grassfield-login <<'EOF'
#!/bin/bash
echo "grassfield-login $*" >>"$GF_STUB/calls"
mkdir -p "$HOME/.config/grassfield" && echo "$2" >"$HOME/.config/grassfield/login-session"
EOF
stub plymouth-set-default-theme <<'EOF'
#!/bin/bash
echo "plymouth-set-default-theme $*" >>"$GF_STUB/calls"
# the setter refusing one theme (plymouth_refuse_<theme>)
[[ -n ${1:-} && -f $GF_STUB/plymouth_refuse_$1 ]] && { echo "plymouth-set-default-theme: refused" >&2; exit 1; }
if (($# == 0)); then cat "$GF_STUB/plymouth"; else echo "$1" >"$GF_STUB/plymouth"; fi
# Plymouth's own script leaves plymouthd.confe behind (sed -ie): plymouth_confe makes the stub do the same
if [[ -f $GF_STUB/plymouth_confe && $# -gt 0 ]]; then mkdir -p "$GRASSFIELD_INSTALL_ROOT/etc/plymouth"; [[ -e $GRASSFIELD_INSTALL_ROOT/etc/plymouth/plymouthd.confe ]] || echo "Theme=old" >"$GRASSFIELD_INSTALL_ROOT/etc/plymouth/plymouthd.confe"; fi
EOF
stub omarchy-update <<'EOF'
#!/bin/bash
echo "omarchy-update $*" >>"$GF_STUB/calls"
[[ -f $GF_STUB/update_fail ]] && { echo "update broke" >&2; exit 1; }
[[ -f $GF_STUB/update_leaves_pending ]] || : >"$GF_STUB/checkupdates"
EOF
stub groupdel <<'EOF'
#!/bin/bash
echo "groupdel $*" >>"$GF_STUB/calls"
sed -i "/^$1:/d" "$GRASSFIELD_INSTALL_ROOT/etc/group"
EOF
mk_rebuild() {
  stub limine-mkinitcpio <<'EOF'
#!/bin/bash
echo "limine-mkinitcpio $*" >>"$GF_STUB/calls"
# Two kernels: A (initramfs-linux.img) always rebuilds; B (initramfs-linux-lts.img) rebuilds unless a failure is set.
echo NEW >"$GRASSFIELD_INSTALL_ROOT/boot/initramfs-linux.img"
[[ -f $GF_STUB/rebuild_fail ]] && exit 1
# *_once: the first rebuild fails, the next ones are clean
[[ -f $GF_STUB/rebuild_fail_once ]] && { rm -f "$GF_STUB/rebuild_fail_once"; exit 1; }
# limine-mkinitcpio exits 0 when kernel B's rebuild failed and only says so
[[ -f $GF_STUB/rebuild_soft_fail ]] && { echo "mkinitcpio failed for kernel linux-lts"; exit 0; }
[[ -f $GF_STUB/rebuild_soft_fail_once ]] && { rm -f "$GF_STUB/rebuild_soft_fail_once"; echo "mkinitcpio failed for kernel linux-lts"; exit 0; }
echo NEW >"$GRASSFIELD_INSTALL_ROOT/boot/initramfs-linux-lts.img"
exit 0
EOF
}
mk_rebuild
stub mkinitcpio <<'EOF'
#!/bin/bash
echo "mkinitcpio $*" >>"$GF_STUB/calls"
echo NEW >"$GRASSFIELD_INSTALL_ROOT/boot/initramfs-linux.img"
[[ -f $GF_STUB/rebuild_fail ]] && exit 1
exit 0
EOF
stub gpgconf <<'EOF'
#!/bin/bash
echo "gpgconf $* GNUPGHOME=${GNUPGHOME:-}" >>"$GF_STUB/calls"
EOF
stub systemctl <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$GF_STUB/calls"
EOF

# A stock machine: Omarchy 4.0.6, [omarchy] first, quickshell from [omarchy], Omarchy's boot theme.
fresh() {
  rm -rf "$S" "$R" "$W/home"
  mkdir -p "$S" "$R/etc/pacman.d" "$R/var/lib/pacman/sync" "$R/usr/share/plymouth/themes/omarchy" "$W/home" "$R/boot/EFI/Linux"
  echo OLD >"$R/boot/initramfs-linux.img"; echo OLD >"$R/boot/EFI/Linux/omarchy.efi"
  cp "$W/offlogic" "$S/offlogic"
  cat >"$R/etc/pacman.conf" <<'EOF'
[options]
HoldPkg = pacman glibc

[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/stable/$arch

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
EOF
  printf 'ID=arch\nNAME="Arch Linux"\n' >"$R/etc/os-release"
  echo 4.0.6-1 >"$S/omarchy"
  echo 0.3.2.r7-1 >"$S/quickshell"
  echo omarchy >"$S/qs_repo"
  echo omarchy >"$S/plymouth"
  : >"$S/keys"
  : >"$S/installed"
  echo "$FPR" >"$S/keyfile"
  echo "$FPR" >"$S/ksfile"
  cp "$R/etc/pacman.conf" "$W/pacman.conf.orig"
  mk_sudo
  mk_channel_set
  mk_rebuild
}

# run <stdin> args...: the script on stubs only; output in $W/out, status in $rc.
run() {
  local input=$1
  shift
  : >"$S/calls"
  printf '%s' "$input" | {
    env -i PATH="$BIN" HOME="$W/home" TMPDIR="$W/tmp" LANG="${TLANG:-C}" XDG_RUNTIME_DIR="$W/run" \
      GRASSFIELD_INSTALL_ROOT="$R" GF_STUB="$S" GF_STUB_FPR="$FPR" bash "$SCRIPT" "$@"
    echo $? >"$W/rc"
  } 2>&1 | cat >"$W/out"
  rc=$(<"$W/rc")
}
# The root commands, with the temporary key file and the run's timestamp made stable.
sudo_calls() { grep '^sudo ' "$S/calls" | sed -e 's#[^ ]*/key\.asc#KEY#' -e 's#\.grassfield-install-bak\.[0-9]\{8\}-[0-9]\{6\}#.grassfield-install-bak.STAMP#'; }
conf_unchanged() { cmp -s "$R/etc/pacman.conf" "$W/pacman.conf.orig"; }
LOGDIR=$W/home/.local/state/grassfield
PKGS4='grassfield-desktop grassfield-compositor grassfield-store grassfield-login-themes'

# After a failure inside the repository phase: exactly the state before the run.
rolled_back() { # <name> [expected exit status, default 1]
  expect "$1: exit $((${2:-1}))" "$rc" "${2:-1}"
  has "$1: says it rolled back" 'Rolling back' "$W/out"
  conf_unchanged && pass "$1: pacman.conf is the original" || fail "$1: pacman.conf differs"
  [[ ! -e $R/etc/pacman.d/grassfield.conf ]] && pass "$1: no grassfield.conf" || fail "$1: grassfield.conf left"
  expect "$1: no key left" "$(wc -c <"$S/keys")" 0
  expect "$1: no package" "$(wc -c <"$S/installed")" 0
  [[ ! -e $R/var/lib/pacman/sync/grassfield.db ]] && pass "$1: synced database dropped" || fail "$1: synced database left"
  has "$1: says how to retry" 'Retry' "$W/out"
}

# ---- 2. usage and refusals before anything runs ---------------------------------------------------------------------
fresh
run '' --help
expect '--help exits 0' "$rc" 0
has '--help documents --uninstall' '--uninstall' "$W/out"
has '--help documents --without-login-themes' '--without-login-themes' "$W/out"
run '' --bogus
expect 'an unknown option exits 2' "$rc" 2
run '' --with-login-themes
expect 'the old opt-in flag is gone' "$rc" 2
run '' --channel nightly
expect 'an unknown channel exits 2' "$rc" 2
run '' --session kde
expect 'an unknown session exits 2' "$rc" 2
cp "$TPL" "$W/template.sh"
env -i PATH="$BIN" HOME="$W/home" bash "$W/template.sh" --help >"$W/o" 2>&1 </dev/null
expect 'the unrendered template refuses to run' "$?" 2

# ---- 3. preflight failures: exit 1, the exact fix, no root command, pacman.conf untouched ---------------------------------
preflight_case() { # <name> <expected text> (state already arranged)
  run '' --yes
  expect "$1: exit 1" "$rc" 1
  has "$1: says what is wrong" "$2" "$W/out"
  has "$1: prints a fix" 'Fix:' "$W/out"
  [[ -z $(sudo_calls) ]] && pass "$1: no sudo" || fail "$1: sudo ran: $(sudo_calls)"
  conf_unchanged && pass "$1: pacman.conf untouched" || fail "$1: pacman.conf changed"
  hasnt "$1: no plan shown" '== Plan' "$W/out"
}
fresh; echo 0 >"$S/uid"; preflight_case 'root' 'running as root'
[[ ! -e $W/home/.local ]] && pass 'root: no log was opened' || fail 'root: the log folder was created'
fresh; echo 4.0.5-1 >"$S/omarchy"; preflight_case 'old Omarchy' 'older than 4.0.6'
fresh; rm "$S/omarchy"; preflight_case 'no Omarchy' 'Omarchy is not installed'
fresh
cat >"$R/etc/pacman.conf" <<'EOF'
[options]
HoldPkg = pacman glibc

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/stable/$arch
EOF
cp "$R/etc/pacman.conf" "$W/pacman.conf.orig"
preflight_case '[omarchy] after [extra]' '[omarchy] comes after [extra]'
has 'the order fix says it never reorders itself' 'never reorders' "$W/out"
fresh; echo 0.3.2-1 >"$S/quickshell"; echo extra >"$S/qs_repo"; preflight_case 'quickshell from extra' "extra build"
fresh; echo extra >"$S/qs_repo"; preflight_case 'quickshell offered by extra' 'would come from [extra]'
# The repository field is read with LC_ALL=C: a French pacman ("Depot") must not hide that quickshell comes from [extra].
fresh; echo extra >"$S/qs_repo"; TLANG=fr_FR.UTF-8 run '' --yes
expect 'French locale: quickshell from [extra] is still caught' "$rc" 1
has 'French locale: the French problem text names [extra]' 'viendrait de [extra]' "$W/out"
fresh; touch "$S/netdown"; preflight_case 'no network' 'cannot reach'
fresh; echo 100 >"$S/free"; preflight_case 'low disk' 'MiB free'
# Pending updates are offered, not refused (GF-010): the script says how many, asks, runs Omarchy's update, checks again.
fresh; printf 'firefox 1-1 -> 2-1\nlinux 1-1 -> 2-1\n' >"$S/checkupdates"; run '' --dry-run
expect 'pending updates, dry run: exit 0' "$rc" 0
has 'pending updates, dry run: says how many' '2 update(s) are waiting' "$W/out"
has 'pending updates, dry run: says it would ask' 'Install them now?' "$W/out"
hasnt 'pending updates, dry run: the update is not run' 'omarchy-update -y' "$S/calls"
[[ -z $(sudo_calls) ]] && pass 'pending updates, dry run: no sudo' || fail 'pending updates, dry run: sudo ran'
fresh; echo 'firefox 1-1 -> 2-1' >"$S/checkupdates"; run '' --yes
expect 'pending updates, --yes: the install goes on (exit 0)' "$rc" 0
has 'pending updates, --yes: Omarchy update runs unattended' 'omarchy-update -y' "$S/calls"
expect 'pending updates, --yes: the update runs before any root command' "$(grep -nE '^(omarchy-update|sudo )' "$S/calls" | head -n 1 | cut -d: -f2-)" 'omarchy-update -y'
has 'pending updates, --yes: the packages are installed after it' 'grassfield-desktop' "$S/installed"
fresh; echo 'firefox 1-1 -> 2-1' >"$S/checkupdates"; run $'\ny\n'
expect 'pending updates, Enter means yes (exit 0)' "$rc" 0
has 'pending updates, Enter: the question has [Y/n]' 'Install them now? [Y/n]' "$W/out"
has 'pending updates, Enter: update ran' 'omarchy-update -y' "$S/calls"
fresh; echo 'firefox 1-1 -> 2-1' >"$S/checkupdates"; run $'n\n'
expect 'pending updates, answer no: exit 1' "$rc" 1
has 'pending updates, answer no: the old message' 'the system has pending updates' "$W/out"
hasnt 'pending updates, answer no: no update' 'omarchy-update -y' "$S/calls"
[[ -z $(sudo_calls) ]] && pass 'pending updates, answer no: no sudo' || fail 'pending updates, answer no: sudo ran'
fresh; echo 'firefox 1-1 -> 2-1' >"$S/checkupdates"; touch "$S/update_fail"; run '' --yes
expect 'pending updates, update fails: exit 1' "$rc" 1
has 'pending updates, update fails: says so' 'Omarchy update failed' "$W/out"
[[ -z $(sudo_calls) ]] && pass 'pending updates, update fails: no sudo' || fail 'pending updates, update fails: sudo ran'
fresh; echo 'firefox 1-1 -> 2-1' >"$S/checkupdates"; touch "$S/update_leaves_pending"; run '' --yes
expect 'pending updates, still pending after the update: exit 1' "$rc" 1
has 'pending updates, still pending: the old message' 'the system has pending updates' "$W/out"
[[ -z $(sudo_calls) ]] && pass 'pending updates, still pending: no sudo' || fail 'pending updates, still pending: sudo ran'
fresh; echo 'grassfield-desktop 1-1 -> 1-2' >"$S/checkupdates"; run '' --yes
expect 'only Grassfield updates pending: no update offered (exit 0)' "$rc" 0
hasnt 'only Grassfield updates pending: the Omarchy update is not run' 'omarchy-update -y' "$S/calls"
fresh; echo 1 >"$S/cu_rc"; preflight_case 'checkupdates fails' 'checkupdates failed'
hasnt 'checkupdates fails: never says [ok] up to date' '[ok] the system is up to date' "$W/out"
fresh; rm -f "$BIN/checkupdates"; preflight_case 'checkupdates missing' 'checkupdates (package pacman-contrib) is missing'
stub checkupdates <<'EOF'
#!/bin/bash
if [[ -s $GF_STUB/checkupdates ]]; then cat "$GF_STUB/checkupdates"; exit 0; fi
exit "$(cat "$GF_STUB/cu_rc" 2>/dev/null || echo 2)"
EOF
fresh; touch "$R/var/lib/pacman/db.lck"; preflight_case 'pacman running' 'db.lck'
fresh; rm -f "$BIN/sudo"; preflight_case 'sudo missing' 'sudo is missing'
fresh
printf '\n[grassfield]\nSigLevel = Never\nInclude = /etc/pacman.d/grassfield.conf\n' >>"$R/etc/pacman.conf"
cp "$R/etc/pacman.conf" "$W/pacman.conf.orig"
preflight_case 'a [grassfield] section with its own SigLevel' 'holds more than its Include'
# Several problems are all reported at once.
fresh; echo 4.0.5-1 >"$S/omarchy"; touch "$S/netdown"; run '' --yes
has 'two problems: the first is reported' 'older than 4.0.6' "$W/out"
has 'two problems: the second is reported' 'cannot reach' "$W/out"
has 'the count of problems is said' '2 problem(s)' "$W/out"

# ---- 4. dry run -----------------------------------------------------------------------------------------------------
fresh; run '' --dry-run
expect '--dry-run exits 0' "$rc" 0
has 'dry-run shows the plan' '== Plan' "$W/out"
has 'dry-run says nothing changed' 'Dry run: nothing was changed' "$W/out"
has 'the plan lists the themes' 'themes (root)' "$W/out"
[[ -z $(sudo_calls) ]] && pass 'dry-run: no sudo' || fail 'dry-run ran sudo'
conf_unchanged && pass 'dry-run: pacman.conf untouched' || fail 'dry-run changed pacman.conf'
[[ ! -e $R/etc/pacman.d/grassfield.conf ]] && pass 'dry-run: no grassfield.conf' || fail 'dry-run wrote grassfield.conf'
hasnt 'dry-run: no sync' 'pacman -Sy' "$S/calls"
hasnt 'dry-run: no install' 'pacman -S --needed' "$S/calls"
hasnt 'dry-run: no download of the key' ' -o /' "$S/calls"
hasnt 'dry-run: no keyserver contact' '--recv-keys' "$S/calls"
has 'the plan names the fingerprint' "$FPR" "$W/out"
fresh; TLANG=fr_FR.UTF-8 run '' --dry-run
has 'French locale: French plan' 'Plan : ce qui va changer' "$W/out"
fresh; run '' --uninstall --dry-run
expect 'uninstall --dry-run exits 0' "$rc" 0
has 'uninstall dry-run shows its plan' 'back to stock Omarchy' "$W/out"
hasnt 'uninstall dry-run: no removal' 'pacman -Rns' "$S/calls"

# ---- 5. confirmation ------------------------------------------------------------------------------------------------
fresh; run $'n\n'
expect 'answering no stops' "$rc" 1
has 'no: says nothing changed' 'Nothing was changed' "$W/out"
[[ -z $(sudo_calls) ]] && pass 'no: no sudo' || fail 'no: sudo ran'
conf_unchanged && pass 'no: pacman.conf untouched' || fail 'no: pacman.conf changed'
fresh; run ''
expect 'no answer at all stops' "$rc" 1

# ---- 6. the happy path: the exact commands ---------------------------------------------------------------------------
fresh; run $'y\n'
expect 'happy path (answered yes) exits 0' "$rc" 0
has 'end message: restart' 'Restart the computer once' "$W/out"
has 'end message: how to undo' '--uninstall' "$W/out"
fresh; run '' --yes
expect 'happy path --yes exits 0' "$rc" 0
want="sudo -v
sudo pacman-key --add KEY
sudo pacman-key --lsign-key $FPR
sudo tee $R/etc/pacman.d/grassfield.conf
sudo cp -p -- $R/etc/pacman.conf $R/etc/pacman.conf.grassfield-install-bak.STAMP
sudo tee -a $R/etc/pacman.conf
sudo pacman -Sy
sudo pacman -S --needed --noconfirm $PKGS4
sudo mkdir -p -- $R/etc/sddm.conf.d
sudo tee $R/etc/sddm.conf.d/zz-grassfield-theme.conf
sudo plymouth-set-default-theme grassfield
sudo limine-mkinitcpio"
expect 'the root commands, exactly and in order' "$(sudo_calls)" "$want"
expect 'the boot images were rebuilt by Omarchy'"'"'s command (new)' "$(cat "$R/boot/initramfs-linux.img")" NEW
[[ ! -e $R/var/lib/grassfield ]] && pass 'no boot image copy folder is ever made' || fail 'a boot image copy folder exists'
has 'the temporary keyring agents are stopped' 'gpgconf --kill all GNUPGHOME=' "$S/calls"
expect 'the update lock is taken again after the hand-over' \
  "$(awk '/^grassfield-channel-set stable/ { on = 1; next } /^plymouth-set-default-theme grassfield/ { on = 0 } on && /^flock -n 8/ { n++ } END { print n + 0 }' "$S/calls")" 1
expect 'the update lock is taken twice in all' "$(grep -c '^flock -n 8' "$S/calls")" 2
expect 'the user commands, in order' "$(grep -E '^(omarchy-snapshot|grassfield-)' "$S/calls")" \
  "omarchy-snapshot create
grassfield-channel-set stable
grassfield-login set grassfield"
has 'the key came from the keyserver over hkps into a temporary keyring' '--keyserver hkps://keys.openpgp.org --recv-keys' "$S/calls"
hasnt 'no key file was downloaded' ' -o /' "$S/calls"
expect 'grassfield.conf is the b.3a file' "$(cat "$R/etc/pacman.d/grassfield.conf")" \
  "SigLevel = Required
Server = $BASE/stable/\$arch"
expect 'pacman.conf: the original, then the two lines' "$(cat "$R/etc/pacman.conf")" \
  "$(cat "$W/pacman.conf.orig")

[grassfield]
Include = /etc/pacman.d/grassfield.conf"
expect 'the login theme drop-in' "$(cat "$R/etc/sddm.conf.d/zz-grassfield-theme.conf")" "[Theme]
Current=grassfield"
expect 'the boot theme is Grassfield' "$(cat "$S/plymouth")" grassfield
expect 'the previous boot theme is remembered' "$(cat "$LOGDIR/plymouth-previous")" omarchy
hasnt 'no service is touched' 'systemctl' "$S/calls"
expect 'no repository order edit: [omarchy] stays second, [grassfield] last' \
  "$(grep '^\[' "$R/etc/pacman.conf" | tr -d '[]\n' | tr -s ' ')" 'optionsomarchycoreextragrassfield'
expect 'the log exists (mode 600)' "$(stat -c %a "$LOGDIR/install.log")" 600
has 'the log holds the root commands' 'sudo pacman -Sy' "$LOGDIR/install.log"
has 'the Omarchy update lock is taken' 'flock -n 8' "$S/calls"
cp "$R/etc/pacman.conf" "$W/after1.conf"
cp "$R/etc/pacman.d/grassfield.conf" "$W/after1.grassfield"

# ---- 7. idempotent rerun: repairs and updates, never duplicates ------------------------------------------------------
run '' --yes
expect 'rerun exits 0' "$rc" 0
cmp -s "$R/etc/pacman.conf" "$W/after1.conf" && pass 'rerun: pacman.conf identical (no duplicated line)' || fail 'rerun changed pacman.conf'
cmp -s "$R/etc/pacman.d/grassfield.conf" "$W/after1.grassfield" && pass 'rerun: grassfield.conf identical' || fail 'rerun changed grassfield.conf'
expect 'rerun: sections' "$(grep -c '^\[grassfield\]' "$R/etc/pacman.conf")" 1
expect 'rerun: the key is checked again, no file write, themes already active' "$(sudo_calls)" \
  "sudo -v
sudo pacman-key --add KEY
sudo pacman-key --lsign-key $FPR
sudo pacman -Sy
sudo pacman -S --needed --noconfirm $PKGS4"
expect 'rerun: still one copy of pacman.conf from the first run' "$(ls "$R"/etc/pacman.conf.grassfield-install-bak.* | wc -l)" 1
expect 'rerun: the remembered boot theme is still the original' "$(cat "$LOGDIR/plymouth-previous")" omarchy
# A rerun after a half-done install: section there, file missing.
rm -f "$R/etc/pacman.d/grassfield.conf"; run '' --yes
expect 'repair: rewrites the missing file' "$(cat "$R/etc/pacman.d/grassfield.conf")" "SigLevel = Required
Server = $BASE/stable/\$arch"
cmp -s "$R/etc/pacman.conf" "$W/after1.conf" && pass 'repair: pacman.conf still identical' || fail 'repair changed pacman.conf'
# A file naming another host is replaced, the old one kept (timestamped).
printf 'SigLevel = Required\nServer = https://old.example.test/stable/$arch\n' >"$R/etc/pacman.d/grassfield.conf"
run '' --yes
has 'foreign file: ours written' "$BASE/stable" "$R/etc/pacman.d/grassfield.conf"
has 'foreign file: copy kept' 'old.example.test' "$(ls "$R"/etc/pacman.d/grassfield.conf.grassfield-install-bak.* | head -n 1)"
# Our host with SigLevel = Never is NOT kept: the plan says signatures are required.
printf 'SigLevel = Never\nServer = %s/stable/$arch\n' "$BASE" >"$R/etc/pacman.d/grassfield.conf"
run '' --yes
expect 'SigLevel = Never is rewritten' "$(cat "$R/etc/pacman.d/grassfield.conf")" "SigLevel = Required
Server = $BASE/stable/\$arch"
# The channel's own file (mirrors, comments) is kept.
printf '# written by grassfield-channel-set\nSigLevel = Required\nServer = %s/stable/$arch\nServer = https://mirror.example.test/stable/$arch\n' "$BASE" >"$R/etc/pacman.d/grassfield.conf"
cp "$R/etc/pacman.d/grassfield.conf" "$W/channel.conf"
run '' --yes
cmp -s "$R/etc/pacman.d/grassfield.conf" "$W/channel.conf" && pass 'the channel helper file with mirrors is kept' || fail 'the channel helper file was rewritten'

# ---- 8. options -----------------------------------------------------------------------------------------------------
fresh; run '' --yes --channel beta --session omarchy --no-snapshot
expect 'beta + omarchy session exits 0' "$rc" 0
has 'beta file' "$BASE/beta/\$arch" "$R/etc/pacman.d/grassfield.conf"
has 'themes package installed by default' 'grassfield-store grassfield-login-themes' "$S/calls"
has 'channel hand-over is beta' 'grassfield-channel-set beta' "$S/calls"
has 'session omarchy' 'grassfield-login set omarchy' "$S/calls"
hasnt 'no snapshot with --no-snapshot' 'omarchy-snapshot' "$S/calls"
has 'end message for the omarchy session' 'still starts Omarchy' "$W/out"
fresh; run '' --yes --without-login-themes
expect '--without-login-themes exits 0' "$rc" 0
hasnt 'no theme package' 'store grassfield-login-themes' "$S/calls"
hasnt 'no drop-in' 'zz-grassfield-theme' "$S/calls"
hasnt 'no plymouth call' 'plymouth-set-default-theme' "$S/calls"
hasnt 'no boot image rebuild' 'mkinitcpio' "$S/calls"
fresh; rm -f "$BIN/limine-mkinitcpio"; run '' --yes
expect 'without limine: mkinitcpio -P, Omarchy'"'"'s other way' "$rc" 0
has 'mkinitcpio -P was run' 'sudo mkinitcpio -P' "$S/calls"
# Two kernels, A rebuilt and B failing (limine-mkinitcpio exits 0 and only prints it): the output is checked, the previous
# theme is set back, Omarchy's rebuild runs AGAIN (it re-records the checksums), and no image is ever copied to or from /boot.
fresh; touch "$S/rebuild_soft_fail_once"; run '' --yes
expect 'a rebuild that exits 0 but reports a failed kernel: ends non-zero' "$rc" 1
hasnt 'soft failure: never says the boot theme is active' 'boot theme active' "$W/out"
has 'soft failure: says the theme was NOT changed' 'boot theme was NOT changed' "$W/out"
expect 'soft failure: the previous boot theme is set back' "$(cat "$S/plymouth")" omarchy
expect 'soft failure: the theme is set, then the old one, with a rebuild after each' \
  "$(grep -E '^(plymouth-set-default-theme .|limine-mkinitcpio)' "$S/calls" | tr '\n' ',')" \
  'plymouth-set-default-theme grassfield,limine-mkinitcpio ,plymouth-set-default-theme omarchy,limine-mkinitcpio ,'
hasnt 'soft failure: no file is copied into /boot' "$R/boot" "$S/calls"
hasnt 'soft failure: no find over /boot' 'sudo find' "$S/calls"
expect 'soft failure: Omarchy'"'"'s rebuild is what wrote the images (nothing was copied back)' "$(cat "$R/boot/initramfs-linux.img")" NEW
has 'soft failure: Grassfield itself stays installed' 'grassfield-desktop' "$S/installed"
[[ -f $R/etc/pacman.d/grassfield.conf ]] && pass 'a theme failure does not roll the repository back' || fail 'the repository was rolled back for a theme failure'
# The exit status of the first rebuild is checked too.
fresh; touch "$S/rebuild_fail_once"; run '' --yes
expect 'a failing rebuild then a clean one: ends non-zero, theme unchanged' "$rc" 1
expect 'a failing rebuild then a clean one: the previous theme is set back' "$(cat "$S/plymouth")" omarchy
expect 'a failing rebuild then a clean one: the rebuild ran twice' "$(grep -c '^limine-mkinitcpio' "$S/calls")" 2
# The second rebuild fails too: stop, say what failed and the exact retry command; never claim it is back to normal.
fresh; touch "$S/rebuild_fail"; run '' --yes
expect 'both rebuilds fail: stops with exit 1' "$rc" 1
has 'both rebuilds fail: the stop message' 'failed twice' "$W/out"
has 'both rebuilds fail: Limine menu advice' "Limine's menu" "$W/out"
has 'both rebuilds fail: the exact retry command' 'sudo limine-mkinitcpio' "$W/out"
hasnt 'both rebuilds fail: never claims it is back to normal' 'boot theme active' "$W/out"
hasnt 'both rebuilds fail: no end message of a good install' '== Done ==' "$W/out"
expect 'both rebuilds fail: the previous theme is set' "$(cat "$S/plymouth")" omarchy
expect 'both rebuilds fail: the rebuild ran twice, no more' "$(grep -c '^limine-mkinitcpio' "$S/calls")" 2
has 'both rebuilds fail: Grassfield stays installed' 'grassfield-desktop' "$S/installed"
has 'both rebuilds fail: says Grassfield is installed and starts at the next login' 'Grassfield is installed and starts at your next login' "$W/out"
fresh; rm -f "$BIN/limine-mkinitcpio"; touch "$S/rebuild_fail"; run '' --yes
has 'both rebuilds fail (mkinitcpio -P): the retry command is the right one' 'sudo mkinitcpio -P' "$W/out"
has 'both rebuilds fail (mkinitcpio -P): names the boot menu generically' 'your boot menu' "$W/out"
hasnt 'both rebuilds fail (mkinitcpio -P): the stop message does not name Limine' "snapshot entry in Limine's menu" "$W/out"
mk_rebuild
# P1: the theme setter refuses grassfield (install): honest message, nothing rebuilt, never "active".
fresh; touch "$S/plymouth_refuse_grassfield"; run '' --yes
expect 'the setter refusing the Grassfield theme: exit 1' "$rc" 1
has 'setter refused: the honest message' 'plymouth-set-default-theme grassfield failed' "$W/out"
has 'setter refused: the boot theme was not changed' 'the boot theme was not changed' "$W/out"
hasnt 'setter refused: never says the boot theme is active' 'boot theme active' "$W/out"
expect 'setter refused: no rebuild was run' "$(grep -c '^limine-mkinitcpio' "$S/calls")" 0
expect 'setter refused: the theme is still the previous one' "$(cat "$S/plymouth")" omarchy
has 'setter refused: Grassfield stays installed' 'grassfield-desktop' "$S/installed"
# The rebuild fails, then the previous theme cannot be set back: stop, saying so.
fresh; touch "$S/rebuild_fail_once" "$S/plymouth_refuse_omarchy"; run '' --yes
expect 'rebuild failed and the previous theme refused: exit 1' "$rc" 1
has 'that case says the previous theme could NOT be set back' 'could NOT be set back' "$W/out"
hasnt 'that case never says the boot theme is active' 'boot theme active' "$W/out"
expect 'that case ran one rebuild only' "$(grep -c '^limine-mkinitcpio' "$S/calls")" 1

# ---- 9. snapshot ---------------------------------------------------------------------------------------------------
fresh; echo 1 >"$S/snap_rc"; run '' --yes
expect 'a failing snapshot stops' "$rc" 1
has 'snapshot failure says why' 'snapshot failed' "$W/out"
conf_unchanged && pass 'snapshot failure: pacman.conf untouched' || fail 'snapshot failure: pacman.conf changed'
hasnt 'snapshot failure: no key step' 'pacman-key' "$S/calls"
fresh; echo 127 >"$S/snap_rc"; run '' --yes
expect 'no snapper: goes on' "$rc" 0
fresh; echo 1 >"$S/snap_rc"; run '' --yes --no-snapshot
expect '--no-snapshot goes on after a snapshot problem' "$rc" 0

# ---- 10. the key: primary fingerprint, never a subkey, on both paths --------------------------------------------------
fresh; touch "$S/keyserver_down"; run '' --yes
expect 'keyserver down: falls back to the host file' "$rc" 0
has 'fallback downloads the key file' "$BASE/grassfield-signing-key.asc" "$S/calls"
has 'fallback adds the verified file' 'pacman-key --add' "$S/calls"
fresh; echo SUBKEYMATCH >"$S/ksfile"; run '' --yes
expect 'a keyserver key that only holds F as a SUBKEY is ignored, the host file is used' "$rc" 0
has 'it says so' 'ignored' "$W/out"
has 'it fell back to the host file' "$BASE/grassfield-signing-key.asc" "$S/calls"
fresh; echo SUBKEYMATCH >"$S/ksfile"; echo SUBKEYMATCH >"$S/keyfile"; run '' --yes
expect 'subkey on the keyserver path and on the host path: refused' "$rc" 1
hasnt 'subkey: the key is never added to pacman' 'pacman-key --add' "$S/calls"
hasnt 'subkey: nothing is signed' 'lsign-key' "$S/calls"
conf_unchanged && pass 'subkey: pacman.conf untouched' || fail 'subkey: pacman.conf changed'
fresh; touch "$S/keyserver_down"; echo SUBKEYMATCH >"$S/keyfile"; run '' --yes
expect 'subkey on the host file path (keyserver down): refused' "$rc" 1
has 'the refusal names the primary key rule' 'not exactly the primary key' "$W/out"
hasnt 'host subkey: the key is never added' 'pacman-key --add' "$S/calls"
fresh; touch "$S/keyserver_down"; echo 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF' >"$S/keyfile"; run '' --yes
expect 'a substituted key file is refused' "$rc" 1
hasnt 'substituted: the key is never added' 'pacman-key --add' "$S/calls"
fresh; touch "$S/keyserver_down"; echo SECRETKEY >"$S/keyfile"; run '' --yes
expect 'a host key file with a secret key is refused' "$rc" 1
hasnt 'secret (host): refused BEFORE pacman sees it' 'pacman-key --add' "$S/calls"
has 'secret (host): refused for this reason' 'not exactly the primary key' "$W/out"
fresh; echo SECRETKEY >"$S/ksfile"; echo SECRETKEY >"$S/keyfile"; run '' --yes
expect 'a secret key on the keyserver path and the host path is refused' "$rc" 1
hasnt 'secret (keyserver): refused BEFORE pacman sees it' 'pacman-key --add' "$S/calls"
conf_unchanged && pass 'secret: pacman.conf untouched' || fail 'secret: pacman.conf changed'
fresh; echo SECRETKEY >"$S/ksfile"; run '' --yes
expect 'a secret key from the keyserver falls back to the good host file' "$rc" 0
# After the add, pacman's keyring must show exactly that primary key.
fresh; touch "$S/keyring_odd"; run '' --yes
rolled_back 'keyring holds another primary for F'
hasnt 'an impostor holding F as a subkey: nothing is signed' 'lsign-key' "$S/calls"
fresh; touch "$S/keyring_odd"; echo "$FPR" >"$S/keys"; run '' --yes
expect 'an impostor already in the keyring (matches F by a subkey): the run stops' "$rc" 1
# "Already present" is primary-only: a subkey match is not "our key was there", so the rollback removes what matched F.
expect 'a subkey-only match is not treated as a pre-existing key (rollback deletes it)' "$(wc -c <"$S/keys")" 0
has 'the rollback ran the key deletion' 'pacman-key --delete' "$S/calls"
hasnt 'an impostor already in the keyring: still nothing is signed' 'lsign-key' "$S/calls"
has 'an impostor already in the keyring: says nothing was signed' 'nothing was signed' "$W/out"
fresh; touch "$S/lsign_fail"; run '' --yes
rolled_back 'lsign fails'

# ---- 11. after the repository is added: every failure puts everything back ---------------------------------------------
fresh; touch "$S/sync_fail"; run '' --yes
rolled_back 'pacman -Sy fails'
has 'pacman -Sy fails: a Stopped line is printed' 'Stopped:' "$W/out"
fresh; touch "$S/resolve_fail"; run '' --yes
rolled_back 'unresolvable packages'
has 'unresolvable: says nothing was installed' 'nothing was installed' "$W/out"
fresh; touch "$S/install_fail"; run '' --yes
rolled_back 'the install transaction fails'
fresh; echo 'qt6-base 6.12.0-1 -> 6.12.1-1' >"$S/qu"; run '' --yes
rolled_back 'pending updates after the sync'
has 'partial upgrade: says why' 'partial upgrade' "$W/out"
has 'partial upgrade: warns that the lists were synced' 'BEFORE any pacman -S' "$W/out"
fresh; touch "$S/conf_broken"; run '' --yes
rolled_back 'pacman cannot read the new section'
# The install transaction fails after some packages went in: nothing is rolled back, and the message says so.
fresh; touch "$S/install_partial"; run '' --yes
expect 'a partial install: exit 1' "$rc" 1
has 'a partial install: says so' 'PARTLY INSTALLED' "$W/out"
hasnt 'a partial install: does not claim a rollback' 'Rolling back' "$W/out"
hasnt 'a partial install: does not claim nothing was installed' 'Nothing new was installed' "$W/out"
grep -q grassfield-desktop "$S/installed" && pass 'a partial install: the package stays' || fail 'a partial install: package missing'
[[ -f $R/etc/pacman.d/grassfield.conf ]] && grep -q '^\[grassfield\]' "$R/etc/pacman.conf" && pass 'a partial install: the repository stays' || fail 'a partial install: the repository was removed'
grep -q "$FPR" "$S/keys" && pass 'a partial install: the key stays' || fail 'a partial install: the key was removed'
# A rerun that fails at the sync never deletes the database that was there before it.
fresh; run '' --yes
touch "$S/sync_fail"; run '' --yes
expect 'rerun with a failing sync: exit 1' "$rc" 1
[[ -e $R/var/lib/pacman/sync/grassfield.db ]] && pass 'a rollback on a rerun keeps the sync database from before' || fail 'a rollback on a rerun deleted the earlier sync database'
grep -q grassfield-desktop "$S/installed" && pass 'a failed rerun leaves the earlier install alone' || fail 'a failed rerun removed the install'
# A real SIGINT / SIGTERM / SIGHUP in the middle of the sync: the same full rollback, status 130.
for sig in INT TERM HUP; do
  fresh; echo "$sig" >"$S/sync_signal"; run '' --yes
  rolled_back "SIG$sig during the sync" 130
done
# A second Ctrl-C while the rollback deletes the key does not stop the rollback (the key never stays trusted).
fresh; echo INT >"$S/sync_signal"; touch "$S/delete_signal"; run '' --yes
rolled_back 'a second SIGINT during the rollback' 130
# The key was already in pacman before the run: a rollback does not delete it.
fresh; echo "$FPR" >"$S/keys"; touch "$S/sync_fail"; run '' --yes
grep -q "$FPR" "$S/keys" && pass 'a key that was there before is kept by a rollback' || fail 'a pre-existing key was deleted by the rollback'
conf_unchanged && pass 'pre-existing key: pacman.conf restored' || fail 'pre-existing key: pacman.conf not restored'
# A grassfield.conf that was there before comes back as it was.
fresh; printf 'SigLevel = Required\nServer = https://old.example.test/stable/$arch\n' >"$R/etc/pacman.d/grassfield.conf"
cp "$R/etc/pacman.d/grassfield.conf" "$W/old.grassfield"; touch "$S/sync_fail"; run '' --yes
cmp -s "$R/etc/pacman.d/grassfield.conf" "$W/old.grassfield" && pass 'a replaced grassfield.conf is restored by the rollback' || fail 'the old grassfield.conf was not restored'
# The user changes pacman.conf during the run: the rollback never undoes that; it says what to do.
fresh; touch "$S/sync_fail" "$S/sync_edit"; run '' --yes
expect 'a concurrent edit: exit 1' "$rc" 1
has 'a concurrent edit is kept' '# later edit' "$R/etc/pacman.conf"
has 'a concurrent edit: manual fix is printed' 'COULD NOT roll back' "$W/out"
[[ -f $R/etc/pacman.d/grassfield.conf ]] && pass 'a concurrent edit: the file the Include names is not removed' || fail 'the Include file was removed under a live Include'
# Ctrl-C style exit during the phase is handled by the same trap (the status is kept).
fresh; touch "$S/sync_fail"; run '' --yes
expect 'the exit status of the failure is kept (1)' "$rc" 1

# ---- 12. uninstall --------------------------------------------------------------------------------------------------
fresh; run '' --yes
run '' --uninstall --yes
expect 'uninstall exits 0' "$rc" 0
conf_unchanged && pass 'uninstall: pacman.conf is the original' || fail 'uninstall: pacman.conf differs'
[[ ! -e $R/etc/pacman.d/grassfield.conf ]] && pass 'uninstall: no grassfield.conf' || fail 'uninstall: grassfield.conf left'
expect 'uninstall: no key left' "$(wc -c <"$S/keys")" 0
expect 'uninstall: no package left' "$(wc -c <"$S/installed")" 0
[[ ! -e $W/home/.config/grassfield/login-session ]] && pass 'uninstall: no session choice left' || fail 'uninstall: session file left'
[[ ! -e $R/etc/sddm.conf.d/zz-grassfield-theme.conf ]] && pass 'uninstall: login theme drop-in removed' || fail 'uninstall: drop-in left'
expect 'uninstall: boot theme back to the remembered one' "$(cat "$S/plymouth")" omarchy
ls "$R"/etc/pacman.conf.grassfield-install-bak.* >/dev/null 2>&1 && fail 'uninstall: a pacman.conf copy is left' || pass 'uninstall: the script copies are removed'
[[ ! -e $LOGDIR/plymouth-previous ]] && pass 'uninstall: the remembered theme record is gone' || fail 'uninstall: the record is left'
expect 'uninstall: the existing Turn Off, then the session' \
  "$(grep -E '^(omarchy-snapshot|grassfield-)' "$S/calls")" \
  "omarchy-snapshot create
grassfield-channel-set off
grassfield-login set omarchy"
expect 'uninstall: root commands in order (themes before the packages)' "$(sudo_calls)" \
  "sudo -v
sudo rm -f -- $R/etc/sddm.conf.d/zz-grassfield-theme.conf
sudo plymouth-set-default-theme omarchy
sudo limine-mkinitcpio
sudo pacman -Rns --noconfirm grassfield-login-themes grassfield-store grassfield-compositor grassfield-desktop grassfield-icons grassfield-wallpapers grassfield-keyring grassfield-hold
sudo rm -f -- $R/etc/pacman.conf.grassfield-install-bak.STAMP"
has 'uninstall end message' 'stock Omarchy' "$W/out"
has 'uninstall let go of the update lock around Turn Off' 'flock -n 8' "$S/calls"
run '' --uninstall --yes
expect 'uninstall twice exits 0' "$rc" 0

# GF-010: session-only files go, settings and state stay, the update group goes when nothing uses it, plymouthd.confe is cleaned.
fresh; touch "$S/plymouth_confe"; run '' --yes
[[ ! -e $R/etc/plymouth/plymouthd.confe ]] && pass 'install: plymouthd.confe made by the theme setter is removed' || fail 'install: plymouthd.confe left'
mkdir -p "$W/home/.config/xdg-desktop-portal" "$W/home/.local/share/icons/grassfield-cursors-custom" "$W/home/.cache/grassfield" "$W/home/.config/grassfield" "$W/home/.local/state/grassfield"
echo x >"$W/home/.config/grassfield-mimeapps.list"; echo x >"$W/home/.config/xdg-desktop-portal/grassfield-portals.conf"
echo keep >"$W/home/.config/grassfield/settings.json"; echo keep >"$W/home/.config/mimeapps.list"
mkdir -p "$R/etc"; printf 'root:x:0:\ngrassfield-update:x:960:\nwheel:x:998:\n' >"$R/etc/group"; printf 'root:x:0:0::/root:/bin/bash\n' >"$R/etc/passwd"
mkdir -p "$R/usr/lib/sysusers.d"
run '' --uninstall --yes
expect 'uninstall (GF-010 files): exit 0' "$rc" 0
[[ ! -e $R/etc/plymouth/plymouthd.confe ]] && pass 'uninstall: plymouthd.confe made by the theme setter is removed' || fail 'uninstall: plymouthd.confe left'
for f in .config/grassfield-mimeapps.list .config/xdg-desktop-portal/grassfield-portals.conf .local/share/icons/grassfield-cursors-custom .cache/grassfield; do
  [[ ! -e $W/home/$f ]] && pass "uninstall: $f removed" || fail "uninstall: $f left"
done
[[ -f $W/home/.config/grassfield/settings.json && -d $W/home/.local/state/grassfield ]] && pass 'uninstall: settings and state are kept' || fail 'uninstall: settings or state removed'
[[ -f $W/home/.config/mimeapps.list ]] && pass "uninstall: the user's own mimeapps.list is untouched" || fail "uninstall: the user's mimeapps.list was removed"
has 'uninstall: prints where the kept folders are' "$W/home/.config/grassfield" "$W/out"
has 'uninstall: prints the one command that deletes them' 'rm -rf' "$W/out"
has 'uninstall: the update group is removed' 'groupdel grassfield-update' "$S/calls"
hasnt 'uninstall: the group file no longer names it' 'grassfield-update' "$R/etc/group"
has 'uninstall: other groups stay' 'wheel:x:998:' "$R/etc/group"
# a plymouthd.confe that was already there is never touched
fresh; touch "$S/plymouth_confe"; mkdir -p "$R/etc/plymouth"; echo "mine" >"$R/etc/plymouth/plymouthd.confe"; run '' --yes
expect 'a pre-existing plymouthd.confe is kept' "$(cat "$R/etc/plymouth/plymouthd.confe")" mine
run '' --uninstall --yes
expect 'a pre-existing plymouthd.confe is kept by the uninstall too' "$(cat "$R/etc/plymouth/plymouthd.confe")" mine
# the group stays when something uses it
for why in members passwd sysusers file; do
  fresh; run '' --yes
  mkdir -p "$R/etc" "$R/usr/lib/sysusers.d" "$R/usr/lib"
  printf 'grassfield-update:x:960:%s\n' "$([[ $why == members ]] && echo bob)" >"$R/etc/group"
  printf 'bob:x:1000:%s::/home/bob:/bin/bash\n' "$([[ $why == passwd ]] && echo 960 || echo 1000)" >"$R/etc/passwd"
  [[ $why == sysusers ]] && echo 'g grassfield-update - -' >"$R/usr/lib/sysusers.d/other.conf"
  [[ $why == file ]] && echo 'Group=grassfield-update' >"$R/etc/other.service"
  run '' --uninstall --yes
  expect "the group is kept ($why): exit 0" "$rc" 0
  hasnt "the group is kept ($why): no groupdel" 'groupdel' "$S/calls"
  has "the group is kept ($why): says why" 'is kept' "$W/out"
done
# Uninstall when the rebuild fails twice: stops before removing anything, with the retry command.
fresh; run '' --yes
touch "$S/rebuild_fail"; run '' --uninstall --yes
expect 'uninstall with a boot rebuild failing twice stops' "$rc" 1
has 'uninstall: the stop message' 'failed twice' "$W/out"
has 'uninstall: the packages are still there to retry' 'grassfield-desktop' "$S/installed"
hasnt 'uninstall: no package removal happened' 'pacman -Rns' "$S/calls"
rm -f "$S/rebuild_fail"
# P2: the setter refuses omarchy on uninstall: stop BEFORE any package removal, never claim the theme is back, keep the record.
fresh; run '' --yes
touch "$S/plymouth_refuse_omarchy"; run '' --uninstall --yes
expect 'uninstall with the setter refusing the previous theme: exit 1' "$rc" 1
has 'P2: the honest message' 'plymouth-set-default-theme omarchy failed' "$W/out"
has 'P2: nothing was removed' 'Nothing was removed' "$W/out"
hasnt 'P2: no package removal' 'pacman -Rns' "$S/calls"
hasnt 'P2: never says the boot theme is back' 'boot theme back' "$W/out"
[[ -f $LOGDIR/plymouth-previous ]] && pass 'P2: the remembered theme is kept' || fail 'P2: the remembered theme was deleted'
expect 'P2: the boot theme is still Grassfield'"'"'s' "$(cat "$S/plymouth")" grassfield
has 'P2: Grassfield stays installed' 'grassfield-desktop' "$S/installed"
rm -f "$S/plymouth_refuse_omarchy"
# Packages gone but [grassfield] left (removed by hand): the script's own copy from THIS install puts pacman.conf back.
fresh; run '' --yes
: >"$S/installed"
rm -f "$BIN/grassfield-channel-set"
run '' --uninstall --yes
expect 'uninstall with leftovers exits 0' "$rc" 0
conf_unchanged && pass 'leftovers then uninstall: pacman.conf is the original' || fail 'leftovers then uninstall: differs'
expect 'leftovers then uninstall: no key' "$(wc -c <"$S/keys")" 0
# pacman.conf edited since: the script does not guess.
fresh; run '' --yes
: >"$S/installed"
printf '\n# my edit\n' >>"$R/etc/pacman.conf"
rm -f "$BIN/grassfield-channel-set"
run '' --uninstall --yes
expect 'uninstall with an edited pacman.conf stops' "$rc" 1
has 'it prints the manual fix' 'delete the two lines' "$W/out"
has 'the manual fix leaves the key for after' 'pacman-key --delete' "$W/out"
has 'the user edit is untouched' '# my edit' "$R/etc/pacman.conf"
mk_channel_set
# Without themes installed: uninstall touches no theme.
fresh; run '' --yes --without-login-themes
run '' --uninstall --yes
expect 'uninstall after --without-login-themes exits 0' "$rc" 0
hasnt 'no boot image rebuild when no theme was active' 'limine-mkinitcpio' "$S/calls"

# ---- 13. the log ---------------------------------------------------------------------------------------------------
fresh; mkdir -p "$LOGDIR"; : >"$W/elsewhere"; ln -s "$W/elsewhere" "$LOGDIR/install.log"
run '' --yes
expect 'a symlinked log is refused' "$rc" 1
has 'the refusal says so' 'not your own plain file' "$W/out"
expect 'the symlink target was not written' "$(wc -c <"$W/elsewhere")" 0
conf_unchanged && pass 'symlinked log: nothing changed' || fail 'symlinked log: pacman.conf changed'
fresh; mkdir -p "$LOGDIR"; echo old >"$LOGDIR/install.log"; chmod 644 "$LOGDIR/install.log"; run '' --dry-run
expect 'an existing log is appended to and its mode is left alone' "$(stat -c %a "$LOGDIR/install.log")" 644
has 'old log lines kept' old "$LOGDIR/install.log"

# ---- 15. the default channel follows VERSION; stable is refused early while it is empty ----------------------------------
echo 1.0.0-beta2 >"$W/version-beta"
echo 1.0 >"$W/version-bad"
python3 -I "$root/packaging/install/render.py" --conf "$W/good.conf" --template "$TPL" --out "$W/render/bad" --version-file "$W/version-bad" >"$W/o" 2>&1
expect 'render refuses a VERSION that is not X.Y.Z or a -betaN / -rcN' "$?" 1
python3 -I "$root/packaging/install/render.py" --conf "$W/good.conf" --template "$TPL" --out "$W/render/pre" --test-hook --version-file "$W/version-pre" >"$W/o" 2>&1
expect 'render (prerelease VERSION)' "$?" 0
python3 -I "$root/packaging/install/render.py" --conf "$W/good.conf" --template "$TPL" --out "$W/render/beta" --version-file "$W/version-beta" >"$W/o" 2>&1
expect 'render (-betaN VERSION)' "$?" 0
has 'a -betaN build defaults to beta' 'CHANNEL=beta SESSION=grassfield' "$W/render/beta/grassfield-install.sh"
has 'the plain build defaults to stable' 'CHANNEL=stable SESSION=grassfield' "$PUB"
has 'the plain build has a stable channel' 'readonly GF_STABLE_EMPTY=0' "$PUB"
has 'the prerelease build knows stable is empty' 'readonly GF_STABLE_EMPTY=1' "$W/render/beta/grassfield-install.sh"
SAVED=$SCRIPT
SCRIPT=$W/render/pre/grassfield-install.sh
fresh; run '' --yes
expect 'prerelease: the default install exits 0' "$rc" 0
has 'prerelease: the default channel is beta' 'grassfield-channel-set beta' "$S/calls"
has 'prerelease: the repository points at beta' "Server = $BASE/beta/" "$R/etc/pacman.d/grassfield.conf"
fresh; run '' --yes --channel stable
expect 'prerelease: --channel stable exits 2' "$rc" 2
has 'prerelease: it says the stable channel is empty' 'the stable channel is empty' "$W/out"
has 'prerelease: and answers in French too' 'le canal stable est vide' "$W/out"
expect 'prerelease: --channel stable runs nothing (no command at all)' "$(wc -c <"$S/calls")" 0
conf_unchanged && pass 'prerelease: --channel stable leaves pacman.conf alone' || fail 'prerelease: --channel stable changed pacman.conf'
[[ ! -e $LOGDIR/install.log ]] && pass 'prerelease: --channel stable writes no log' || fail 'prerelease: --channel stable wrote a log'
fresh; run '' --dry-run --channel stable
expect 'prerelease: --dry-run --channel stable is refused too' "$rc" 2
fresh; run '' --yes --channel beta
expect 'prerelease: --channel beta exits 0' "$rc" 0
run '' --uninstall --yes --channel stable
expect 'prerelease: --uninstall is not blocked by the channel' "$rc" 0
SCRIPT=$SAVED

# ---- 14. shellcheck (when installed) ----------------------------------------------------------------------------------
if command -v shellcheck >/dev/null; then
  shellcheck -s bash "$PUB" "$SCRIPT" "$0"
  expect 'shellcheck: the rendered scripts and this test' "$?" 0
else
  echo "  note shellcheck NOT VERIFIED: it is not installed here; run it in CI (the Arch container installs it)"
fi

((fails == 0)) && echo "PASS: public install script" || echo "FAIL: public install script ($fails)"
exit $((fails > 0))
