#!/usr/bin/env bash
# Software Update, step 5 (ADR-0033 s5, owner decision SU-M2: one password for Update Now and its migrations' sudo
# commands): grassfield-update-helper, grassfield-update-run, the migrations' sudo (/usr/lib/grassfield/update-sudo/sudo)
# and the polkit rule 49-grassfield-update.rules, with systemd as the container's manager (privileged, a cgroup2 mount),
# real dbus-broker, polkitd and pkexec. Never on a real machine: inside, it refuses to run unless it is root in a container
# with the repository mounted at /src and an Omarchy tree at /omarchy.
#
#   tests/integration/update_migrate.sh [--omarchy DIR]
#     DIR  an Omarchy 4.x tree (default /usr/share/omarchy): its omarchy-migrate goes into the test's omarchy package
#   Runs `docker run --privileged` on archlinux:base (digest pinned below) with systemd as PID 1, then the cases through
#   `docker exec`; HTTPS_PROXY/HTTP_PROXY/NO_PROXY are passed through and GRASSFIELD_TEST_CA, when set, is mounted as the
#   container's CA bundle. Exit 0 all PASS (or SKIP without docker), 1 a FAIL, 2 usage.
#
# What it shows:
#   - the channel: in grassfield-update-migrate.service (as carol, under the group grassfield-update, NoNewPrivileges, its
#     own /tmp) the sudo runs commands as root with standard input, output, working folder, exit status, arguments and the
#     unit's temporary files passed through, looks a name up in root's folders only, accepts Omarchy's sudo options and
#     refuses the others; from the unit, another unit name, a root unit name without its 32 hex digits, another verb on a
#     root unit and any other unit operation are refused; the real sudo cannot run there; nothing of the unit is left;
#   - carol's other processes cannot open the unit's pipe, environment, folder or temporary files (the step 5 review's
#     MAJOR: /proc/<pid>/fd), and outside that unit (a plain process of carol's, another unit, the unit without
#     NoNewPrivileges) systemd refuses, with no dialog;
#   - the REAL helper from a user's runner through pkexec: dave, not an administrator, goes to Omarchy's terminal (the
#     review's BLOCKER); so does a run while the unit's group has a member, or while a migration from before the update is
#     pending, or with a rule that grants nothing or none; carol, an administrator: the update installed, the migration run
#     as carol with its sudo as root and its own /tmp, `migrations ran`, its output root's alone; a failing sudo leaves the
#     migration pending; a migration that needs a person (gum, or sudo and gum) goes to the terminal; so does one that
#     needs root and would run code the person can change (sudo and omarchy-hook, rc7 audit R7-SEC-01), its sudo never run;
#     root without pkexec's user has no person; the unit's own form is refused outside the unit.
set -uo pipefail

IMAGE=archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0

if [[ ${1:-} != --inside ]]; then
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
  omarchy=/usr/share/omarchy
  while (($#)); do
    case $1 in
      --omarchy) omarchy=${2:?}; shift ;;
      *) echo "usage: update_migrate.sh [--omarchy DIR]" >&2; exit 2 ;;
    esac
    shift
  done
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo "SKIP: no docker daemon (this test runs only in a throwaway container)"; exit 0; }
  [[ -f $omarchy/bin/omarchy-migrate ]] || { echo "SKIP: no Omarchy tree at $omarchy (--omarchy DIR)"; exit 0; }
  args=(-d --privileged --cgroupns=private --tmpfs /run --tmpfs /tmp --network host -e container=docker
    -v "$root:/src:ro" -v "$(realpath "$omarchy"):/omarchy:ro")
  [[ -n ${GRASSFIELD_TEST_CA:-} ]] && args+=(-v "$(realpath "$GRASSFIELD_TEST_CA"):/etc/ssl/certs/ca-certificates.crt:ro")
  envs=()
  for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy; do [[ -n ${!v:-} ]] && envs+=(-e "$v"); done
  cid=$(docker run "${args[@]}" "$IMAGE" bash -c 'umount -l /sys/fs/cgroup 2>/dev/null; mount -t cgroup2 none /sys/fs/cgroup && exec /usr/lib/systemd/systemd') ||
    { echo "FAIL: the container did not start"; exit 1; }
  trap 'docker rm -f "$cid" >/dev/null 2>&1' EXIT
  for _ in $(seq 1 60); do
    state=$(docker exec "$cid" systemctl is-system-running 2>/dev/null)
    [[ $state == running || $state == degraded ]] && break
    sleep 1
  done
  [[ $state == running || $state == degraded ]] || { echo "FAIL: systemd did not come up in the container ($state)"; exit 1; }
  docker exec "${envs[@]}" "$cid" bash /src/tests/integration/update_migrate.sh --inside
  exit $?
fi

[[ -f /.dockerenv && $(id -u) == 0 && -f /src/packaging/pacman/grassfield-update-sudo && -d /omarchy/bin && -d /run/systemd/system ]] ||
  { echo "refused: runs only as root inside a throwaway container run by systemd (/src, /omarchy)"; exit 2; }

# docker exec runs with umask 0000 in a container run by systemd: the test packages would then carry world-writable
# folders, which the helper rightly refuses (the integrator's MINOR 2). A real package's folders are 0755.
umask 022
W=/work
mkdir -p "$W" && chmod 1777 "$W"
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
expect() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
say() { printf '\n== %s\n' "$*"; }
quiet() { "$@" >>"$W/log" 2>&1; }
H=/usr/lib/grassfield/grassfield-update-helper
R=/usr/lib/grassfield/grassfield-update-run
SUDO=/usr/lib/grassfield/update-sudo/sudo
RULE=/usr/share/polkit-1/rules.d/49-grassfield-update.rules
D=/run/grassfield-update
FPR=40DFB630FF42BCFFB047046CF0134EE680CAC571
ver() { pacman -Q "$1" 2>/dev/null | cut -d' ' -f2; }
exitfile() { tr '\n' '|' <"$D/$1.exit" 2>/dev/null; }

say "setup: Arch's mirrors, polkit and sudo; Omarchy's key; the real helper, runner, policy, sudo for migrations and rule"
sed -i 's/^#\?DisableSandbox.*//; /^\[options\]/a DisableSandbox' /etc/pacman.conf
quiet pacman-key --init
quiet pacman-key --populate archlinux
quiet pacman -Syu --noconfirm polkit sudo python diffutils || { echo "FAIL: pacman -Syu polkit sudo python (see $W/log)"; tail -5 "$W/log"; exit 1; }
quiet pacman -Sw --noconfirm archlinux-keyring || { echo "FAIL: the Arch keyring's package file"; exit 1; }
pacman -Q pacman polkit systemd dbus-broker sudo | tr '\n' ' '; echo
curl -fsS "https://keys.openpgp.org/vks/v1/by-fingerprint/$FPR" -o "$W/omarchy.asc" && quiet pacman-key --add "$W/omarchy.asc" &&
  quiet pacman-key --lsign-key "$FPR" || { echo "FAIL: Omarchy's public key from keys.openpgp.org (see $W/log)"; exit 1; }
install -Dm755 /src/packaging/pacman/grassfield-update-helper "$H"
install -Dm755 /src/packaging/bin/grassfield-update-run "$R"
install -Dm644 /src/packaging/pacman/org.grassfield.packages.policy /usr/share/polkit-1/actions/org.grassfield.packages.policy
install -Dm755 /src/packaging/pacman/grassfield-update-sudo "$SUDO"
install -Dm644 /src/packaging/pacman/49-grassfield-update.rules "$RULE"
install -Dm644 /src/packaging/pacman/grassfield-update.sysusers /usr/lib/sysusers.d/grassfield-update.conf
quiet systemd-sysusers
expect "the migrations' unit's group exists, with no member" bash -c 'getent group grassfield-update | grep -qE "^grassfield-update:x:[0-9]+:$"'
# carol is an administrator (wheel, as Omarchy's user is); dave is not.
useradd -m -G wheel carol
useradd -m dave
# erin is an administrator whose own group is the unit's (the helper refuses that).
useradd -m -g grassfield-update -G wheel erin
uid=$(id -u carol) duid=$(id -u dave) euid=$(id -u erin)
# The runners have no agent to ask the password through in a container: polkit lets carol's and dave's through (an
# administrator's password, typed for dave's in a real session; the dialog is the owner's L2); the rule under test is the
# packaged one.
cat >/etc/polkit-1/rules.d/50-grassfield-test.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id == "org.grassfield.packages.update-system" && (subject.user == "carol" || subject.user == "dave" || subject.user == "erin")) return polkit.Result.YES;
  return polkit.Result.NOT_HANDLED;
});
EOF
systemctl restart polkit
cp /var/cache/pacman/pkg/archlinux-keyring-"$(ver archlinux-keyring)"-any.pkg.tar.zst "$W/keyring.pkg.tar.zst" ||
  { echo "FAIL: the installed archlinux-keyring's package file is not in the cache"; exit 1; }
mkdir -p "/run/user/$uid" "/run/user/$duid" "/run/user/$euid" && chown carol: "/run/user/$uid" && chown dave: "/run/user/$duid" &&
  chown erin: "/run/user/$euid" && chmod 700 "/run/user/$uid" "/run/user/$duid" "/run/user/$euid"
# A command in a root-owned folder that others can write: the migrations' sudo refuses it.
install -d -m 775 /usr/local/gu-gw && printf '#!/bin/sh\necho group-writable\n' >/usr/local/gu-gw/gu-x && chmod 755 /usr/local/gu-gw/gu-x
# A link to a root-alone program, kept in that folder: the link could be swapped (the integrator's follow-up 1).
ln -s /usr/bin/true /usr/local/gu-gw/true-link

say "the channel: the migrations' sudo inside grassfield-update-migrate.service (the helper's properties)"
# The unit as the helper's migrate_unit makes it.
in_migrate() { # [--no-nnp] [--no-wait] -- program [argument...]
  local props=(-p NoNewPrivileges=yes) wait=(--wait --pipe)
  if [[ ${1-} == --no-nnp ]]; then props=(); shift; fi
  if [[ ${1-} == --no-wait ]]; then wait=(); shift; fi
  systemd-run --unit=grassfield-update-migrate --collect --quiet "${wait[@]}" --service-type=exec --expand-environment=no \
    --uid=carol --gid=grassfield-update -p SupplementaryGroups=carol "${props[@]}" -p RestrictNamespaces=yes \
    -p LockPersonality=yes -p RestrictSUIDSGID=yes -p PrivateTmp=yes -p LimitFSIZE=64M -p TimeoutStopSec=5s \
    -p 'WorkingDirectory=~' --setenv=PATH="/usr/lib/grassfield/update-sudo:/usr/share/omarchy/bin:/usr/bin" "$@"
}
cat >"$W/channel.sh" <<'EOF'
#!/bin/bash
set -u
r() { printf '%s=%s\n' "$1" "$2"; }
r whoami "$(id -un):$(id -gn)"
r root "$(sudo id -u)"
echo through-stdin | sudo tee /root/tee-test >/dev/null; r tee "$?"
cd /tmp && r pwd "$(sudo pwd)"
sudo sh -c 'exit 7'; r status "$?"
r as-root "$(sudo -u root id -u):$(sudo -u '#0' id -u)"
sudo -u carol id -un >/dev/null 2>&1; r as-carol "$?"
sudo -u "#$(id -u)" id -un >/dev/null 2>&1; r as-carol-hash "$?"
sudo -v; r validate "$?"
sudo -n true; r nontty "$?"
sudo -nH true; r cluster "$?"
sudo -n -l -l /usr/bin/true >/dev/null 2>&1; r list "$?"
sudo -E true 2>/dev/null; r preserve-env "$?"
sudo -i 2>/dev/null; r login-shell "$?"
sudo FOO=1 true 2>/dev/null; r assignment "$?"
r env-command "$(sudo env GU_A=1 sh -c 'echo $GU_A')"
r sudo-user "$(sudo printenv SUDO_USER)"
r root-home "$(sudo printenv HOME)"
r literal "$(sudo echo '$HOME' '%n')"
mkdir -p "$HOME/bin" && printf '#!/bin/sh\necho pwned\n' >"$HOME/bin/gu-evil" && chmod 755 "$HOME/bin/gu-evil"
PATH=$HOME/bin:$PATH sudo gu-evil >/dev/null 2>&1; r lookup "$?"
tmp=$(mktemp) && echo private-tmp >"$tmp" && r tmp-root "$(sudo cat "$tmp")"
systemd-run --quiet --wait --no-ask-password --unit=run-gu-x.service true 2>/dev/null; r other-name "$?"
systemd-run --quiet --wait --no-ask-password --unit=grassfield-update-root-x.service true 2>/dev/null; r short-name "$?"
sudo sleep 6 &
sleep 2
root_unit=$(systemctl list-units --plain --no-legend 'grassfield-update-root-*' | awk 'NR == 1 { print $1 }')
systemctl --no-ask-password stop "$root_unit" 2>/dev/null; r stop-root "$?:${root_unit:+named}"
wait
systemctl --no-ask-password stop polkit 2>/dev/null; r stop-polkit "$?"
/usr/bin/sudo -n true 2>/dev/null; r real-sudo "$?"
if unshare -U true 2>/dev/null; then r userns allowed; else r userns refused; fi
sudo -nHE true 2>/dev/null; r c-E "$?"
sudo -nHs true 2>/dev/null; r c-s "$?"
sudo -nHunobody id -u 2>/dev/null; r c-u "$?"
sudo "$HOME/bin/gu-evil" >/dev/null 2>&1; r user-path "$?"
sudo /usr/local/gu-gw/gu-x >/dev/null 2>&1; r gw-path "$?"
sudo /usr/local/gu-gw/true-link >/dev/null 2>&1; r gw-link "$?"
r root-env "$(LD_PRELOAD=/nonexistent.so LD_LIBRARY_PATH=/x PYTHONPATH=/x PYTHONSTARTUP=/x PERL5LIB=/x BASH_ENV=/x ENV=/x GU_CALLER=leak sudo env 2>/dev/null | cut -d= -f1 | sort | tr '\n' ' ')"
EOF
chmod 755 "$W/channel.sh"
out=$(in_migrate -- "$W/channel.sh" 2>&1)
get() { sed -n "s/^$1=//p" <<<"$out"; }
expect "the unit's processes are carol's, under the group grassfield-update" test "$(get whoami)" == carol:grassfield-update
expect "sudo id -u -> 0" test "$(get root)" == 0
expect "standard input reaches the command (tee as root)" test "$(get tee):$(cat /root/tee-test 2>/dev/null):$(stat -c %U /root/tee-test 2>/dev/null)" == "0:through-stdin:root"
expect "the working folder is the caller's" test "$(get pwd)" == /tmp
expect "the command's exit status is sudo's" test "$(get status)" == 7
expect "sudo -u root, sudo -u #0 -> root" test "$(get as-root)" == "0:0"
expect "sudo -u carol, sudo -u #uid -> refused (another target would leave the unit's group; the re-review's MINOR 1)" \
  test "$(get as-carol):$(get as-carol-hash)" == "1:1"
expect "sudo -v, sudo -n, sudo -nH -> 0" test "$(get validate):$(get nontty):$(get cluster)" == "0:0:0"
expect "sudo -l lists nothing -> 1" test "$(get list)" == 1
expect "sudo -E, sudo -i, a variable before the command -> refused (1)" test "$(get preserve-env):$(get login-shell):$(get assignment)" == "1:1:1"
expect "sudo env VAR=... command works (Omarchy's form)" test "$(get env-command)" == 1
expect "SUDO_USER carol, HOME /root" test "$(get sudo-user):$(get root-home)" == "carol:/root"
expect "arguments reach the command unexpanded" test "$(get literal)" == '$HOME %n'
expect "a name is not looked up in the caller's PATH (command not found)" test "$(get lookup)" == 1
expect "a file of the unit's own /tmp reaches its root command" test "$(get tmp-root)" == private-tmp
expect "another unit name from the unit -> refused" test "$(get other-name)" != 0
expect "a root unit name without its 32 hex digits -> refused" test "$(get short-name)" != 0
expect "stopping a root unit from the unit (another verb) -> refused" bash -c '[[ $1 == [1-9]*:named ]]' _ "$(get stop-root)"
expect "any other unit operation from the unit -> refused (polkit still active)" test "$(get stop-polkit)" != 0 -a "$(systemctl is-active polkit)" == active
expect "the real sudo cannot run in the unit (NoNewPrivileges)" test "$(get real-sudo)" != 0
expect "no user namespace in the unit (RestrictNamespaces; the integrator's MINOR 1)" test "$(get userns)" == refused
expect "an unknown letter in a cluster is refused (-nHE, -nHs, -nHunobody)" test "$(get c-E):$(get c-s):$(get c-u)" == "1:1:1"
expect "a command that is not root's alone is refused (the person's file; a folder others can write; a link kept there)" \
  test "$(get user-path):$(get gw-path):$(get gw-link)" == "1:1:1"
# The root unit's environment: systemd's own for a root service, and SUDO_*; nothing of the caller's (LD_*, PYTHON*,
# PERL5LIB, BASH_ENV, ENV, any other variable).
allowed=" HOME INVOCATION_ID LANG LANGUAGE LC_ALL LOGNAME MEMORY_PRESSURE_WATCH MEMORY_PRESSURE_WRITE PATH SHELL SUDO_GID SUDO_UID SUDO_USER SYSTEMD_EXEC_PID USER "
expect "the root unit's environment is the fixed set (no LD_PRELOAD, PYTHON*, PERL5LIB, BASH_ENV or the caller's own; got: $(get root-env))" \
  bash -c 'env=$1 allowed=$2; [[ -n $env && $env == *SUDO_USER* ]] || exit 1; for k in $env; do [[ $allowed == *" $k "* || $k == LC_* ]] || exit 1; done' _ "$(get root-env)" "$allowed"
expect "nothing of the unit is left" bash -c '! systemctl is-active --quiet grassfield-update-migrate.service && test -z "$(systemctl list-units --all --plain --no-legend "grassfield-update-migrate*" "grassfield-update-root-*")"'

say "carol's other processes cannot reach into the unit (the step 5 review's MAJOR)"
cat >"$W/holder.sh" <<'EOF'
#!/bin/bash
exec 3< <(sleep 40)
echo held >/tmp/gu-held
sleep 30
EOF
chmod 755 "$W/holder.sh"
in_migrate --no-wait -- "$W/holder.sh"
sleep 2
pid=$(systemctl show -p MainPID --value grassfield-update-migrate.service)
probe=$(runuser -u carol -- bash -c "exec 9>/proc/$pid/fd/3 && echo fd-opened; cat /proc/$pid/environ >/dev/null 2>&1 && echo environ-read; readlink /proc/$pid/cwd >/dev/null 2>&1 && echo cwd-read; ls /tmp/gu-held 2>/dev/null && echo tmp-seen; echo done" 2>/dev/null)
expect "a process of carol's cannot open the unit's pipe, environment, folder or temporary files ($pid)" test "${pid:-0}:$probe" == "$pid:done" -a "${pid:-0}" != 0
systemctl stop grassfield-update-migrate.service

say "the channel refuses everything else"
out=$(runuser -u carol -- "$SUDO" id -u 2>&1); rc=$?
expect "carol outside the unit: sudo -> refused, no dialog ($rc)" test "$rc:$(grep -c '^0$' <<<"$out")" == "1:0"
out=$(systemd-run --unit=gu-other --collect --quiet --wait --pipe --uid=carol -p NoNewPrivileges=yes "$SUDO" id -u 2>&1); rc=$?
expect "carol in another unit -> refused" test "$rc" != 0
out=$(in_migrate --no-nnp -- "$SUDO" id -u 2>&1); rc=$?
expect "the unit's name without NoNewPrivileges -> refused" test "$rc" != 0
rm -f /root/tee-test

say "the test packages"
mkdir -p "$W/pkgs" "$W/repo"
# mkpkg name version [.PKGINFO line | path=content | path:<file to copy> | path-><link target>]... (update_helper.sh's)
mkpkg() {
  local name=$1 ver=$2 dir="$W/build/$1-$2" arg path
  shift 2
  rm -rf "$dir" && mkdir -p "$dir/usr/share/doc/$name"
  echo "$name $ver" >"$dir/usr/share/doc/$name/README"
  {
    printf 'pkgname = %s\npkgbase = %s\npkgver = %s-1\npkgdesc = update migrate test\nurl = https://example.invalid\n' "$name" "$name" "$ver"
    printf 'builddate = 1700000000\npackager = test\nsize = 1\narch = any\nlicense = MIT\n'
    for arg in "$@"; do [[ $arg == *' = '* ]] && printf '%s\n' "$arg"; done
  } >"$dir/.PKGINFO"
  for arg in "$@"; do
    [[ $arg == *' = '* ]] && continue
    if [[ $arg == *'->'* && $arg != *=* ]]; then
      path=${arg%%->*}; mkdir -p "$dir/${path%/*}"; ln -s "${arg#*->}" "$dir/$path"
    elif [[ $arg == *:* && $arg != *=* ]]; then
      path=${arg%%:*}; mkdir -p "$dir/${path%/*}"; cp "${arg#*:}" "$dir/$path"
    else
      path=${arg%%=*}; mkdir -p "$dir/${path%/*}"; printf '%s\n' "${arg#*=}" >"$dir/$path"
    fi
  done
  chmod -R a+rX "$dir"
  [[ -n ${GU_WORLD_WRITABLE-} ]] && chmod 666 "$dir/$GU_WORLD_WRITABLE"   # one file the package leaves writable by all
  find "$dir/usr/share/omarchy/bin" "$dir/usr/bin" -type f -exec chmod 755 {} + 2>/dev/null
  (cd "$dir" && bsdtar --zstd -cf "$W/pkgs/$name-$ver-1-any.pkg.tar.zst" .PKGINFO usr) || { echo "FAIL: mkpkg $name"; exit 1; }
}
mkpkg grassfield-desktop 1 "usr/share/grassfield/BUILD-DEPS=qt6-base 6.11.0-1"
mkpkg qt6-base 6.11.0
mkpkg omarchy-keyring 1
omarchy_commands=()
printf '#!/bin/bash\nsudo true\n' >"$W/omarchy-gu-sudo"
printf '#!/bin/bash\nomarchy-gu-sudo\n' >"$W/omarchy-gu-indirect"
printf '#!/bin/bash\ntrue\n' >"$W/omarchy-notification-dismiss"
for command in omarchy-gu-sudo omarchy-gu-indirect omarchy-notification-dismiss; do
  omarchy_commands+=("usr/bin/$command:$W/$command" "usr/share/omarchy/bin/$command->/usr/bin/$command")
done
omarchy_commands+=("usr/bin/omarchy-migrate:/omarchy/bin/omarchy-migrate" "usr/share/omarchy/bin/omarchy-migrate->/usr/bin/omarchy-migrate")
base_files=("usr/share/omarchy/version=4.0.4" "${omarchy_commands[@]}" "usr/share/omarchy/migrations/100.sh=echo 100 >>\"\$HOME/migrations.log\"")
# 700 needs root (sudo, and a command that calls it): it writes on both sides, hands a temporary file to a root command (as
# 4.0.6's 1791403252 does with mktemp and sudo install), and records its session and group.
m700='echo 700 >>"$HOME/migrations.log"; echo carol-side >"$HOME/su-m2-user"; echo root-side | sudo tee /root/su-m2-root >/dev/null; sudo install -m 644 /dev/null /etc/su-m2-marker; omarchy-gu-indirect; t=$(mktemp); echo from-tmp >"$t"; sudo install -m 644 "$t" /root/su-m2-tmp; echo "$t" >"$HOME/su-m2-tmppath"; if unshare -U true 2>/dev/null; then echo allowed; else echo refused; fi >"$HOME/su-m2-userns"; echo "${WAYLAND_DISPLAY-} ${HYPRLAND_INSTANCE_SIGNATURE-}" >"$HOME/su-m2-session"; exec 3< <(sleep 12); touch "$HOME/su-m2-holding"; sleep 8'
m700f="usr/share/omarchy/migrations/700.sh=$m700"
mkpkg omarchy 1 "${base_files[@]}"
mkpkg omarchy 2 "${base_files[@]}" "$m700f"
mkpkg omarchy 3 "${base_files[@]}" "$m700f" "usr/share/omarchy/migrations/750.sh=sudo false"
mkpkg omarchy 4 "${base_files[@]}" "$m700f" "usr/share/omarchy/migrations/750.sh=sudo false" \
  "usr/share/omarchy/migrations/800.sh=gum confirm 'Continue?'" "usr/share/omarchy/migrations/810.sh=sudo true; gum confirm 'Sure?'"
mkpkg omarchy 5 "${base_files[@]}" "$m700f" "usr/share/omarchy/migrations/750.sh=sudo false" \
  "usr/share/omarchy/migrations/900.sh=sudo touch /root/su-m2-900"
mkpkg omarchy 6 "${base_files[@]}" "$m700f" "usr/share/omarchy/migrations/750.sh=sudo false" \
  "usr/share/omarchy/migrations/900.sh=sudo touch /root/su-m2-900" "usr/share/omarchy/migrations/950.sh=sudo touch /root/su-m2-950"
GU_WORLD_WRITABLE=usr/share/omarchy/migrations/980.sh mkpkg omarchy 7 "${base_files[@]}" "$m700f" \
  "usr/share/omarchy/migrations/750.sh=sudo false" "usr/share/omarchy/migrations/900.sh=sudo touch /root/su-m2-900" \
  "usr/share/omarchy/migrations/950.sh=sudo touch /root/su-m2-950" "usr/share/omarchy/migrations/980.sh=sudo touch /root/su-m2-980"
# 990 needs root and runs the person's hooks (R7-SEC-01): in the unit, a hook would get root through its sudo.
mkpkg omarchy 8 "${base_files[@]}" "$m700f" \
  "usr/share/omarchy/migrations/750.sh=sudo false" "usr/share/omarchy/migrations/900.sh=sudo touch /root/su-m2-900" \
  "usr/share/omarchy/migrations/950.sh=sudo touch /root/su-m2-950" "usr/share/omarchy/migrations/980.sh=sudo touch /root/su-m2-980" \
  "usr/share/omarchy/migrations/990.sh=sudo touch /root/su-m2-990; omarchy-hook post-update"
publish() {
  rm -f "$W/repo"/*
  cp "$W/keyring.pkg.tar.zst" "$W/repo/archlinux-keyring-$(ver archlinux-keyring)-any.pkg.tar.zst"
  local p
  for p in "$@"; do cp "$W/pkgs/$p-1-any.pkg.tar.zst" "$W/repo/"; done
  quiet repo-add -q "$W/repo/gutest.db.tar.gz" "$W/repo"/*.pkg.tar.zst
  touch -d "@$(( $(date +%s) + ${publish_n:=0} ))" "$W/repo/gutest.db.tar.gz" "$W/repo/gutest.db"
  publish_n=$((publish_n + 1))
}
base=(grassfield-desktop-1 qt6-base-6.11.0 omarchy-keyring-1 omarchy-1)
publish "${base[@]}"
cat >/etc/pacman.conf <<EOF
[options]
Architecture = auto
CheckSpace
DownloadUser = alpm
DisableSandbox
HoldPkg = pacman glibc
[gutest]
SigLevel = Optional TrustAll
Server = file://$W/repo
EOF
quiet pacman -Syy
quiet pacman -S --noconfirm grassfield-desktop qt6-base omarchy-keyring omarchy || { echo "FAIL: installing the base set (see $W/log)"; exit 1; }
# carol and dave have run 100 already (Omarchy's marker).
for u in carol dave; do
  mkdir -p "/home/$u/.local/state/omarchy/migrations" && touch "/home/$u/.local/state/omarchy/migrations/100.sh"
  chown -R "$u:" "/home/$u/.local"
done
expect "the base set installed (omarchy 1)" test "$(ver omarchy)" == 1-1

say "the REAL helper, from a runner (pkexec, the unit grassfield-update.service)"
runner() { # user
  local u=$1 i
  i=$(id -u "$u")
  runuser -u "$u" -- env -i HOME="/home/$u" USER="$u" XDG_RUNTIME_DIR="/run/user/$i" PATH=/usr/bin LANG=C.UTF-8 \
    WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=gu_test_123 "$R" </dev/null >/dev/null 2>&1
}
# phase, result, and whether migrations are deferred (a container has no running kernel's package and only test
# repositories: the restart and `aur` that follow from that are not this test's).
state() { python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s["phase"], s["result"], "migrations" if "migrations" in s["deferred"] else "-")' \
  "/run/user/$(id -u "$1")/grassfield/software-update-run.json" 2>/dev/null; }
last() { cat "$D/last" 2>/dev/null; }
logsays() { grep -q -- "$2" "$D/$1.log"; }

publish grassfield-desktop-1 qt6-base-6.11.0 omarchy-keyring-1 omarchy-2
runner dave; op=$(last)
expect "dave, not an administrator: 700 needs root -> done terminal, needs migration 700, omarchy stays 1 ($(state dave))" \
  test "$(state dave):$(exitfile "$op"):$(ver omarchy)" == "done terminal -:7|needs migration 700|:1-1"
expect "  its log says why (the step 5 review's BLOCKER)" logsays "$op" "dave is not an administrator (wheel)"
gpasswd -a dave grassfield-update >/dev/null
runner carol; op=$(last)
expect "the unit's group with a member -> done terminal, omarchy stays 1 ($(state carol))" \
  test "$(state carol):$(ver omarchy)" == "done terminal -:1-1"
expect "  its log says why" logsays "$op" "grassfield-update is missing, has members"
gpasswd -d dave grassfield-update >/dev/null
cp /etc/gshadow "$W/gshadow.saved"
sed -i 's|^grassfield-update:[^:]*:|grassfield-update:$6$gu$NotARealHashButAPassword:|' /etc/gshadow
runner carol; op=$(last)
expect "the unit's group with a password (newgrp would take it) -> done terminal, omarchy stays 1 ($(state carol))" \
  test "$(state carol):$(ver omarchy)" == "done terminal -:1-1"
expect "  its log says why" logsays "$op" "has members or a password"
cp "$W/gshadow.saved" /etc/gshadow
mkdir -p /home/erin/.local/state/omarchy/migrations && touch /home/erin/.local/state/omarchy/migrations/100.sh && chown -R erin: /home/erin/.local
runner erin; op=$(last)
expect "erin, whose own group is the unit's -> done terminal, omarchy stays 1 ($(state erin))" \
  test "$(state erin):$(ver omarchy)" == "done terminal -:1-1"
expect "  its log says why" logsays "$op" "or is the person's own"
chmod 775 /usr/share/omarchy/migrations
runner carol; op=$(last)
expect "Omarchy's migrations folder writable by its group -> done terminal, omarchy stays 1 ($(state carol))" \
  test "$(state carol):$(ver omarchy)" == "done terminal -:1-1"
expect "  its log says why (the integrator's MINOR 2)" logsays "$op" "migrations or commands folder, or Grassfield's sudo, is not root's alone"
chmod 755 /usr/share/omarchy/migrations
chmod 775 /usr/share/omarchy/bin
runner carol; op=$(last)
expect "Omarchy's commands folder writable by its group -> done terminal, omarchy stays 1 ($(state carol); follow-up 2)" \
  test "$(state carol):$(ver omarchy)" == "done terminal -:1-1"
chmod 755 /usr/share/omarchy/bin
chmod 775 /usr/lib/grassfield/update-sudo
runner carol; op=$(last)
expect "Grassfield's sudo in a folder others can write -> done terminal, omarchy stays 1 ($(state carol); follow-up 4)" \
  test "$(state carol):$(ver omarchy)" == "done terminal -:1-1"
expect "  its log says why" logsays "$op" "or Grassfield's sudo, is not root's alone"
chmod 755 /usr/lib/grassfield/update-sudo
# The run in the background: while 700 holds a pipe, a process of carol's outside the unit tries the unit's processes.
cat >"$W/attacker.sh" <<'EOF'
#!/bin/bash
# Every process of the migrations' unit: its descriptors' targets, environment, folder and /tmp; the host's /tmp.
for p in "$@"; do
  for f in /proc/$p/fd/*; do { exec 9<"$f" && echo "opened $f"; exec 9<&-; } 2>/dev/null; done
  cat "/proc/$p/environ" >/dev/null 2>&1 && echo "environ $p"
  readlink "/proc/$p/cwd" >/dev/null 2>&1 && echo "cwd $p"
  ls "/proc/$p/root/tmp" >/dev/null 2>&1 && echo "root/tmp $p"
done
echo checked
EOF
chmod 755 "$W/attacker.sh"
runner carol &
runner_pid=$!
for _ in $(seq 1 600); do [[ -e /home/carol/su-m2-holding ]] && break; sleep 0.2; done
cg=$(systemctl show -p ControlGroup --value grassfield-update-migrate.service 2>/dev/null)
pids=$(cat "/sys/fs/cgroup$cg/cgroup.procs" 2>/dev/null | tr '\n' ' ')
attack=$(runuser -u carol -- "$W/attacker.sh" $pids 2>/dev/null)
wait "$runner_pid"
op=$(last)
[[ $(state carol) == "done done -" ]] || { echo "   (diagnostics: state '$(state carol)', the run's log and exit file)"; tail -n 12 "$D/$op.log" | sed 's/^/   /'; cat "$D/$op.exit" 2>/dev/null | sed 's/^/   exit: /'; tail -n 5 "/run/user/$uid/grassfield/software-update-run.log" 2>/dev/null | sed 's/^/   runner: /'; }
expect "the helper's own unit: carol's other processes get none of its processes' descriptors, environment, folder or /tmp ($(wc -w <<<"$pids") processes)" \
  test "$(wc -w <<<"$pids"):$attack" != "0:checked" -a "$attack" == checked
expect "  the migration's temporary file was in the unit's own /tmp, not the shared one" \
  bash -c 't=$(cat /home/carol/su-m2-tmppath 2>/dev/null); [[ $t == /tmp/* && ! -e $t ]]'
expect "carol, an administrator: done done, omarchy 2 installed, migrations ran ($(state carol))" \
  test "$(state carol):$(ver omarchy):$(grep -cx 'migrations ran' "$D/$op.exit")" == "done done -:2-1:1"
expect "  700's sudo commands ran as root (tee, install, a file of its own /tmp)" \
  test "$(cat /root/su-m2-root 2>/dev/null):$(stat -c %U /etc/su-m2-marker 2>/dev/null):$(cat /root/su-m2-tmp 2>/dev/null)" == "root-side:root:from-tmp"
expect "  700 ran as carol (its file carol's, group grassfield-update), once, marked done in carol's state" \
  test "$(stat -c %U:%G /home/carol/su-m2-user 2>/dev/null):$(grep -c 700 /home/carol/migrations.log):$(test -f /home/carol/.local/state/omarchy/migrations/700.sh && echo marked)" == "carol:grassfield-update:1:marked"
expect "  700 could not make a user namespace (the helper's unit, RestrictNamespaces)" test "$(cat /home/carol/su-m2-userns 2>/dev/null)" == refused
expect "  700 had carol's session values (Wayland display, Hyprland instance)" test "$(cat /home/carol/su-m2-session 2>/dev/null)" == "wayland-1 gu_test_123"
expect "  the migrations' output is root's alone (0600), not in the 0644 log" \
  bash -c "test \"\$(stat -c %U:%a '$D/$op.migrations')\" == root:600 && grep -q 'Running migration (700)' '$D/$op.migrations' && ! grep -q 'Running migration' '$D/$op.log'"
expect "  the log names the migrations it ran (SU-M2)" logsays "$op" "SU-M2): 700.sh"
expect "  nothing of the migrations' unit or its root units is left" \
  test -z "$(systemctl list-units --all --plain --no-legend 'grassfield-update-migrate*' 'grassfield-update-root-*')"

publish grassfield-desktop-1 qt6-base-6.11.0 omarchy-keyring-1 omarchy-3
runner carol; op=$(last)
expect "omarchy 3 (750: sudo false) -> done done with deferred migrations, omarchy 3 installed ($(state carol))" \
  test "$(state carol):$(ver omarchy):$(grep -cx 'migrations ran' "$D/$op.exit")" == "done done migrations:3-1:1"
expect "  750 stays pending for carol" test ! -f /home/carol/.local/state/omarchy/migrations/750.sh
touch /home/carol/.local/state/omarchy/migrations/750.sh   # Omarchy's terminal finished it

publish grassfield-desktop-1 qt6-base-6.11.0 omarchy-keyring-1 omarchy-4
runner carol; op=$(last)
expect "omarchy 4 (800 asks with gum; 810 calls sudo and gum) -> done terminal, both need a person, omarchy stays 3 ($(state carol))" \
  bash -c '[[ $1 == "done terminal -:3-1" ]] && grep -qx "needs migration 800" "$2" && grep -qx "needs migration 810" "$2"' _ "$(state carol):$(ver omarchy)" "$D/$op.exit"

publish grassfield-desktop-1 qt6-base-6.11.0 omarchy-keyring-1 omarchy-5
rm /home/carol/.local/state/omarchy/migrations/100.sh
runner carol; op=$(last)
expect "a migration from before this update pending (100), 900 needs root -> done terminal, omarchy stays 3 ($(state carol))" \
  test "$(state carol):$(ver omarchy)" == "done terminal -:3-1"
expect "  its log says why (the unit runs this update's own migrations only)" logsays "$op" "migrations from before this update are pending"
touch /home/carol/.local/state/omarchy/migrations/100.sh && chown carol: /home/carol/.local/state/omarchy/migrations/100.sh

cp "$RULE" "$W/rule.saved"
echo '// emptied by the test' >"$RULE"
sleep 2   # polkitd reloads its rules when a file changes
runner carol; op=$(last)
expect "a rule that grants nothing: the trial sudo fails -> done terminal, needs migration 900, omarchy stays 3 ($(state carol))" \
  test "$(state carol):$(ver omarchy):$(exitfile "$op")" == "done terminal -:3-1:7|needs migration 900|"
expect "  its log says the trial failed; 900 did not run" bash -c "grep -q 'the trial sudo through the migrations. unit failed' '$D/$op.log' && test ! -e /root/su-m2-900"
rm -f "$RULE"
runner carol; op=$(last)
expect "no rule installed -> done terminal, omarchy stays 3 ($(state carol))" test "$(state carol):$(ver omarchy)" == "done terminal -:3-1"
expect "  its log says the sudo for migrations is not installed" logsays "$op" "sudo for migrations is not installed"
cp "$W/rule.saved" "$RULE"
sleep 2
runner carol; op=$(last)
expect "the rule back: omarchy 5 installed, 900's sudo ran ($(state carol))" \
  test "$(state carol):$(ver omarchy):$(test -e /root/su-m2-900 && echo ran)" == "done done -:5-1:ran"

say "the helper's own inputs"
publish grassfield-desktop-1 qt6-base-6.11.0 omarchy-keyring-1 omarchy-6
op=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
env -i PATH=/usr/bin "$H" run "$op" </dev/null >/dev/null 2>&1; rc=$?
expect "root itself, without pkexec's user (no person): 950 needs root -> exit 7, needs migration 950, omarchy stays 5" \
  test "$rc:$(exitfile "$op"):$(ver omarchy)" == "7:7|needs migration 950|:5-1"
expect "  its log says why" logsays "$op" "no person to run them as"
env -i PATH=/usr/bin "$H" unit "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" "$uid" - - </dev/null >/dev/null 2>&1; rc=$?
expect "the unit form outside grassfield-update.service -> usage (2)" test "$rc" == 2

say "a migration the transaction leaves writable by all (the integrator's follow-up 4)"
publish grassfield-desktop-1 qt6-base-6.11.0 omarchy-keyring-1 omarchy-7
runner carol; op=$(last)
expect "omarchy 7 (950 needs root, 980 installed writable by all) -> done done with deferred migrations, omarchy 7 installed ($(state carol))" \
  test "$(state carol):$(ver omarchy):$(grep -cx 'migrations ran' "$D/$op.exit")" == "done done migrations:7-1:0"
expect "  no migration ran with root (950's sudo did not run), and the log says why" \
  bash -c "test ! -e /root/su-m2-950 && grep -q '980.sh is not root.s alone: no migration runs with root' '$D/$op.log'"

say "a migration that needs root and would run code the person can change (rc7 audit R7-SEC-01)"
for m in 950 980; do   # Omarchy's terminal finished them: no migration from before the update is pending
  touch "/home/carol/.local/state/omarchy/migrations/$m.sh" && chown carol: "/home/carol/.local/state/omarchy/migrations/$m.sh"
done
publish grassfield-desktop-1 qt6-base-6.11.0 omarchy-keyring-1 omarchy-8
runner carol; op=$(last)
expect "omarchy 8 (990: sudo and omarchy-hook) -> done terminal, needs migration 990, omarchy stays 7 ($(state carol))" \
  bash -c '[[ $1 == "done terminal -:7-1" ]] && grep -qx "needs migration 990" "$2"' _ "$(state carol):$(ver omarchy)" "$D/$op.exit"
expect "  its log says why, and 990's sudo never ran" \
  bash -c "grep -q '990.sh would run code the person can change' '$D/$op.log' && test ! -e /root/su-m2-990"

echo
if ((fails)); then echo "update_migrate: $fails FAIL"; exit 1; fi
echo "update_migrate: all PASS"
