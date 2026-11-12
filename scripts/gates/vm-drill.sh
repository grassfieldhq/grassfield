#!/usr/bin/env bash
# Gate H / GF-010 (MS-M3-7): the clean install and uninstall drill on a stock Omarchy 4 VM, re-runnable.
#
#   scripts/gates/vm-drill.sh <phase> [options]
#   phases (run them one by one, or `all`):
#     stock-install  stock Omarchy 4 from the official ISO (checksum verified), driven through QMP keys and screendumps,
#                    SSH enabled for the VM's root with a generated key
#     snapshot       record the stock state (packages, /etc and user dirs with hashes, enabled units, session screendump),
#                    then a qcow2 snapshot named "stock" (+ a copy of the OVMF vars)
#     install        restore "stock" (unless --no-restore), install Grassfield with the documented command, reboot
#     check          first-login checks: session, menu bar and Dock screendump, journal markers, units, failed units
#     uninstall      grassfield-install.sh --uninstall + docs/owner-setup/real-session.md section 9, reboot
#     compare        stock record against the state now: packages, files, units, session; every leftover in a table
#     all            the six phases in order
#   update-migrate  run tests/integration/update_migrate.sh INSIDE the VM (never on a host with a session: it runs systemd in a
#                   container); ships `git archive HEAD` of --repo DIR (default: this repository) and prints the VM's console log
#   helpers: vm-up, vm-start [disk|iso], vm-stop, shot NAME, key QCODE..., type TEXT, ssh CMD..., compare-canary (adds a group on purpose: compare must flag it)
#
#   options: --vm-dir DIR      (default: <main checkout>/.claude/integrator/vm; never /tmp: it is a tmpfs)
#            --installer FILE  use this grassfield-install.sh instead of downloading the published one
#            --branch-installer  render packaging/install/grassfield-install.sh.in of this checkout and use that
#            --no-restore      `install` continues from the current disk instead of restoring "stock"
#            --force           `stock-install` replaces an existing disk
#            --repo DIR        `update-migrate`: the repository whose HEAD is run in the VM (default: this one)
#            --reuse-stock     `all` skips stock-install and starts from the existing qcow2 snapshot "stock"
#            --max-load N      refuse to start the VM above this 1-minute load (default 8)
#
# Every phase prints PASS/FAIL lines carrying their evidence and exits 1 on any FAIL (2: usage or environment error).
# Nothing runs as root on the host: qemu runs as the user, user-mode networking only (SSH forwarded on 127.0.0.1),
# the VM's root is reached over SSH with a key generated in the VM directory. The credentials are throwaway and live in
# <vm-dir>/keys; the host's own accounts, session and network are never touched.
set -uo pipefail

# ---- configuration ---------------------------------------------------------------------------------------------------
repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
VM_DIR=${GF_VM_DIR:-$(dirname "$common")/.claude/integrator/vm}
SSH_PORT=${GF_VM_SSH_PORT:-2222}
MAX_LOAD=8
INSTALLER=''
BRANCH_INSTALLER=0
REUSE_STOCK=0
UM_REPO=''
RESTORE=1
FORCE=0
VCPUS=4
RAM_MB=6144
DISK_GB=40
ISO_NAME=${GF_VM_ISO:-omarchy-4.5.0-x86.iso}
ISO_BASE=https://iso.omarchy.org
OVMF_DIR=/usr/share/edk2/x64
VM_USER=gfdrill
GF_INSTALL_URL=https://packages.grassfield.site/install/grassfield-install.sh
FAILS=0

# ---- output ----------------------------------------------------------------------------------------------------------
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
info() { printf 'INFO %s\n' "$*"; }
die() { printf 'drill: %s\n' "$*" >&2; exit 2; }
# check <label> <command...>: PASS when the command exits 0, FAIL otherwise (output excerpt on FAIL)
check() {
  local label=$1 out rc
  shift
  out=$("$@" 2>&1)
  rc=$?
  if ((rc == 0)); then pass "$label"; else fail "$label (exit $rc): ${out:0:300}"; fi
}

# ---- paths -----------------------------------------------------------------------------------------------------------
d() { printf '%s/%s' "$VM_DIR" "$1"; }
DISK() { d disk.qcow2; }
QMP_SOCK() { d qmp.sock; }
KEY() { d keys/id_drill; }
SHOTS() { d shots; }
REC() { d "records/$1"; }

# ---- QMP: one small client, python only for the socket (python3 is already the repo's tooling language) ---------------
read -r -d '' QMP_PY <<'PY'
import json, socket, sys, time
# argv: socket cmd args...   cmds: raw JSON | key QCODE... | type TEXT | shot FILE | status
sock, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
s = socket.socket(socket.AF_UNIX)
s.settimeout(30)
s.connect(sock)
f = s.makefile("rw")
f.readline()
def call(name, **a):
    f.write(json.dumps({"execute": name, "arguments": a}) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r:
            return r
call("qmp_capabilities")
PLAIN = {c: c for c in "abcdefghijklmnopqrstuvwxyz0123456789"}
PLAIN.update({" ": "spc", "-": "minus", "=": "equal", ".": "dot", ",": "comma", "/": "slash", ";": "semicolon",
              "'": "apostrophe", "\\": "backslash", "[": "bracket_left", "]": "bracket_right", "`": "grave_accent",
              "\n": "ret", "\t": "tab"})
SHIFT = {"!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
         "_": "minus", "+": "equal", ":": "semicolon", '"': "apostrophe", "|": "backslash", "<": "comma",
         ">": "dot", "?": "slash", "{": "bracket_left", "}": "bracket_right", "~": "grave_accent"}
def keys_for(ch):
    if ch in PLAIN: return [PLAIN[ch]]
    if ch.isupper() and ch.lower() in PLAIN: return ["shift", ch.lower()]
    if ch in SHIFT: return ["shift", SHIFT[ch]]
    sys.exit("no key for %r" % ch)
def send(qs, hold=80):
    r = call("send-key", keys=[{"type": "qcode", "data": q} for q in qs], **{"hold-time": hold})
    if "error" in r: sys.exit(json.dumps(r))
if cmd == "raw":
    print(json.dumps(call(*([json.loads(args[0])["execute"]]), **json.loads(args[0]).get("arguments", {}))))
elif cmd == "key":
    for k in args:
        send(k.split("+")); time.sleep(0.15)
elif cmd in ("type", "type-stdin"):
    for ch in (sys.stdin.read().rstrip("\n") if cmd == "type-stdin" else " ".join(args)):
        send(keys_for(ch)); time.sleep(0.08)
elif cmd == "shot":
    r = call("screendump", filename=args[0], format="png")
    if "error" in r: sys.exit(json.dumps(r))
elif cmd == "status":
    print(call("query-status")["return"]["status"])
else:
    sys.exit("unknown qmp command " + cmd)
PY
qmp() { python3 -I -c "$QMP_PY" "$(QMP_SOCK)" "$@"; }

# ---- the VM ----------------------------------------------------------------------------------------------------------
vm_running() { [[ -S $(QMP_SOCK) ]] && qmp status >/dev/null 2>&1; }

load_ok() {
  local l i
  for i in {1..120}; do # waits up to 10 minutes for the host to calm down
    l=$(cut -d' ' -f1 /proc/loadavg)
    awk -v l="$l" -v m="$MAX_LOAD" 'BEGIN { exit !(l <= m) }' && break
    sleep 5
  done
  awk -v l="$l" -v m="$MAX_LOAD" 'BEGIN { exit !(l <= m) }' || { fail "host 1-minute load $l is above $MAX_LOAD for 10 minutes: not starting the VM"; return 1; }
  info "host 1-minute load $l (limit $MAX_LOAD)"
}

# vm_start disk|iso: 4 vCPUs, 6 GB, KVM, OVMF, virtio disk, user networking with an SSH forward, no display, QMP socket
vm_start() {
  local mode=${1:-disk}
  vm_running && { info "VM already running"; return 0; }
  load_ok || return 1
  [[ -r /dev/kvm && -w /dev/kvm ]] || { fail "/dev/kvm is not usable"; return 1; }
  rm -f "$(QMP_SOCK)"
  local -a args=(-name gfdrill -machine q35,accel=kvm -cpu host -smp "$VCPUS" -m "$RAM_MB"
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_DIR/OVMF_CODE.4m.fd"
    -drive "if=pflash,format=raw,file=$(d OVMF_VARS.4m.fd)"
    -drive "file=$(DISK),if=virtio,format=qcow2,discard=unmap"
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=n0
    -device virtio-vga -device qemu-xhci -device usb-tablet
    -display none -qmp "unix:$(QMP_SOCK),server=on,wait=off" -pidfile "$(d qemu.pid)" -daemonize)
  if [[ $mode == iso ]]; then
    args+=(-drive "file=$(d iso/$ISO_NAME),media=cdrom,if=none,id=cd0,readonly=on" -device usb-storage,drive=cd0,bootindex=1)
  fi
  qemu-system-x86_64 "${args[@]}" >>"$(d logs/qemu.log)" 2>&1 || { fail "qemu did not start (see $(d logs/qemu.log))"; return 1; }
  local i
  for i in {1..30}; do vm_running && { info "VM started ($mode)"; return 0; }; sleep 1; done
  fail "QMP socket never answered"
  return 1
}

vm_stop() { # graceful powerdown, then quit
  vm_running || return 0
  qmp raw '{"execute":"system_powerdown"}' >/dev/null 2>&1
  local i
  for i in {1..60}; do vm_running || return 0; sleep 2; done
  qmp raw '{"execute":"quit"}' >/dev/null 2>&1
  sleep 2
}

shot() { # shot NAME -> shots/NAME.png
  mkdir -p "$(SHOTS)"
  qmp shot "$(SHOTS)/$1.png" && info "screendump $(SHOTS)/$1.png"
}

ssh_opts=()
vm_ssh() { # as the VM's root, over the forwarded port
  ssh -i "$(KEY)" -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$(d known_hosts)" \
    -o LogLevel=ERROR -o ConnectTimeout=40 -o IdentitiesOnly=yes root@127.0.0.1 "$@"
}
wait_ssh() { # wait_ssh SECONDS
  local t=${1:-300} i
  for ((i = 0; i < t; i += 5)); do vm_ssh true 2>/dev/null && return 0; sleep 5; done
  return 1
}
creds() { # sets VM_PASS (throwaway, generated once, kept in the VM directory only)
  local f
  f=$(d keys/creds)
  if [[ ! -s $f ]]; then
    mkdir -p "$(d keys)"
    (umask 077; head -c 12 /dev/urandom | base64 | tr -d '/+=' >"$f")
  fi
  VM_PASS=$(<"$f")
}

# ---- phase: stock-install --------------------------------------------------------------------------------------------
verify_iso() {
  local iso sum
  iso=$(d iso/$ISO_NAME)
  [[ -f $iso ]] || { info "downloading $ISO_BASE/$ISO_NAME"; mkdir -p "$(d iso)"; curl -fsS -C - -o "$iso" "$ISO_BASE/$ISO_NAME" || return 1; }
  curl -fsS -o "$iso.sha256" "$ISO_BASE/$ISO_NAME.sha256" || return 1
  sum=$(sha256sum "$iso" | cut -d' ' -f1)
  [[ $sum == "$(cut -d' ' -f1 "$iso.sha256")" ]] || { fail "ISO sha256 $sum does not match the published $(cut -d' ' -f1 "$iso.sha256")"; return 1; }
  pass "ISO $ISO_NAME sha256 $sum matches the published checksum"
}

# The installer's key script is in the drive_installer function of the next section (filled from the observed screens).
prepare_vm_files() {
  creds
  mkdir -p "$(d keys)"
  [[ -f $(KEY) ]] || ssh-keygen -q -t ed25519 -N '' -C gfdrill -f "$(KEY)" || return 1
  if [[ -e $(DISK) ]] && ((!FORCE)); then
    fail "$(DISK) exists: --force replaces it (the stock snapshot inside it is lost)"
    return 1
  fi
  vm_stop
  rm -f "$(DISK)" "$(d OVMF_VARS.4m.fd)" "$(d OVMF_VARS.stock.fd)" "$(d known_hosts)" # a new install has new host keys
  qemu-img create -q -f qcow2 "$(DISK)" "${DISK_GB}G" || return 1
  cp "$OVMF_DIR/OVMF_VARS.4m.fd" "$(d OVMF_VARS.4m.fd)" || return 1
}

# The installer (Omarchy 4.5.0 ISO: a gum TUI) is driven blind by timing, one screendump per screen in shots/inst-*.png:
# start screen, language, keyboard, timezone, username, password, confirm, hostname, summary, disk, overwrite (the
# default is an encrypted install: the password is the LUKS passphrase too), progress, "Reboot Now".
drive_installer() {
  info "waiting for the ISO's start screen"
  sleep 120
  shot inst-start
  qmp key ret; sleep 3 # start
  qmp key ret; sleep 3 # language: English
  qmp key ret; sleep 4 # keyboard: English (US)
  shot inst-timezone
  qmp key ret; sleep 3 # timezone: the detected one
  qmp type "$VM_USER"; qmp key ret; sleep 2
  printf "%s" "$VM_PASS" | qmp type-stdin; qmp key ret; sleep 2
  printf "%s" "$VM_PASS" | qmp type-stdin; qmp key ret; sleep 2
  qmp key ret; sleep 2 # hostname: omarchy
  shot inst-summary
  qmp key ret; sleep 4 # "Does this look right?" Yes
  shot inst-disk
  qmp key ret; sleep 3 # /dev/vda
  shot inst-overwrite
  qmp key ret # Yes, install
  local i
  for ((i = 0; i < 300; i += 10)); do sleep 10; done
  shot inst-done
}

# first boot of the installed disk: type the LUKS passphrase at the prompt (~25 s after power-on)
luks_unlock() {
  sleep 28
  shot luks-prompt
  printf "%s" "$VM_PASS" | qmp type-stdin
  qmp key ret
}

# SSH for the VM's root, typed into a terminal of the stock session (Super+Return). The password is the throwaway one.
enable_ssh() {
  local pub
  pub=$(<"$(KEY).pub")
  # A text console (Ctrl+Alt+F3), not a terminal of the session: the compositor's key repeat misfires under the VM's
  # input lag (stuck keys); the console's repeat is the kernel's. The installer's password is the root password too.
  qmp key ctrl+alt+f3
  sleep 5
  qmp type "root"; qmp key ret; sleep 2
  printf "%s" "$VM_PASS" | qmp type-stdin; qmp key ret; sleep 4
  qmp type "systemctl enable --now sshd; install -d -m 700 /root/.ssh; echo \"$pub\" >/root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; systemctl restart sshd; ufw allow from 10.0.2.2 to any port 22 proto tcp"
  qmp key ret
  sleep 25 # the guest takes the typed keys slowly
  shot ssh-enabled
  qmp key ctrl+alt+f1 # back to the session's VT
}

phase_stock_install() {
  verify_iso || return 1
  prepare_vm_files || return 1
  vm_start iso || return 1
  drive_installer
  vm_stop_hard
  vm_start disk || return 1
  luks_unlock
  sleep 150
  shot stock-first-boot
  enable_ssh
  if wait_ssh 60; then
    pass "stock Omarchy installed; SSH as the VM's root works: $(vm_ssh 'pacman -Q omarchy')"
  else
    fail "no SSH after enabling it (see $(SHOTS)/ssh-enabled.png)"
  fi
}

vm_stop_hard() { qmp raw '{"execute":"quit"}' >/dev/null 2>&1; sleep 3; }

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d;s/^# \{0,1\}//'; }


# ---- records: what the VM looks like, written to <vm-dir>/records/<name>/ ---------------------------------------------
# files.tsv: path<TAB>kind<TAB>value (F: sha256, L: link target, D: directory) for /etc and the user's ~/.config and
# ~/.local/share; packages.txt: pacman -Q; units-*.txt: enabled unit files; extra.txt: Grassfield-named paths elsewhere.
collect() { # collect NAME
  local r
  r=$(REC "$1")
  rm -rf "$r"
  mkdir -p "$r"
  vm_ssh 'pacman -Q | sort' >"$r/packages.txt" || return 1
  vm_ssh "bash -s -- $VM_USER" >"$r/files.tsv" <<'EOS' || return 1
u=$1 h=/home/$1
roots=(/etc "$h/.config" "$h/.local/share")
{
  find "${roots[@]}" -xdev -type f -exec sha256sum {} + 2>/dev/null | sed 's/^\([0-9a-f]\{64\}\)  \(.*\)$/\2\tF\t\1/'
  find "${roots[@]}" -xdev -type l -printf '%p\tL\t%l\n' 2>/dev/null
  find "${roots[@]}" -xdev -type d -printf '%p\tD\t-\n' 2>/dev/null
} | LC_ALL=C sort -t$'\t' -k1,1
EOS
  vm_ssh "bash -s -- $VM_USER" >"$r/units-system.txt" <<'EOS' || return 1
systemctl list-unit-files --state=enabled,enabled-runtime --no-legend --no-pager | awk '{print $1}' | sort
echo "# global user units"
systemctl --global list-unit-files --state=enabled --no-legend --no-pager | awk '{print $1}' | sort
EOS
  vm_ssh "bash -s -- $VM_USER" >"$r/units-user.txt" <<'EOS'
u=$1
uid=$(id -u "$u")
if [[ -S /run/user/$uid/bus ]]; then
  runuser -u "$u" -- env XDG_RUNTIME_DIR=/run/user/$uid systemctl --user list-unit-files --state=enabled --no-legend --no-pager | awk '{print $1}' | sort
else
  echo "# no user manager running"
fi
EOS
  # Grassfield-named paths outside the hashed scope: system folders, and the user's state and cache (session churn there is not recorded)
  vm_ssh "find /usr /opt /var/lib /var/cache /boot /home/$VM_USER/.cache /home/$VM_USER/.local/state -xdev -iname '*grassfield*' 2>/dev/null | sort" >"$r/extra.txt" || return 1
  # Groups: name:gid:members of /etc/group, and only the NAMES of /etc/gshadow (no hash, no password, ever in a record)
  vm_ssh "cut -d: -f1,3,4 /etc/group | LC_ALL=C sort" >"$r/groups.txt" || return 1
  vm_ssh "cut -d: -f1 /etc/gshadow | LC_ALL=C sort" >"$r/gshadow-names.txt" || return 1
  vm_ssh 'loginctl list-sessions --no-legend; echo; ps -eo comm= | sort | uniq -c | sort -rn | head -40' >"$r/session.txt" || true
  info "record $1: $(wc -l <"$r/packages.txt") packages, $(wc -l <"$r/files.tsv") paths, $(wc -l <"$r/units-system.txt") system unit lines"
}

# ---- LUKS and the first boot -----------------------------------------------------------------------------------------
# boot_installed: start from the disk, type the disk passphrase at the prompt (~28 s after power-on), wait for SSH.
boot_installed() { # boot_installed SHOTNAME
  vm_start disk || return 1
  luks_unlock
  wait_ssh 420 || { shot "$1-nossh"; fail "VM did not answer SSH after boot"; return 1; }
}

reboot_vm() { # reboot from inside, type the passphrase, wait for SSH again
  vm_ssh 'systemctl reboot' 2>/dev/null
  local i
  for i in {1..60}; do vm_ssh true 2>/dev/null || break; sleep 2; done
  sleep 20
  luks_unlock
  wait_ssh 420
}

# ---- phases ----------------------------------------------------------------------------------------------------------
as_user() { # as_user CMD: a login shell of the VM user (user manager and bus reachable), run by the VM's root
  local uid
  uid=$(vm_ssh "id -u $VM_USER") || return 1
  vm_ssh "runuser -u $VM_USER -- env HOME=/home/$VM_USER XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus bash -lc $(printf '%q' "$1")"
}

# A freshly installed ISO is days behind the mirrors, and grassfield-install.sh refuses ("the system has pending
# updates") until Omarchy's own update has run: that is the first thing a user does, so "stock" is the updated system.
# The password-less sudo this needs is a drill file, removed again right after.
stock_update() {
  local n
  n=$(as_user 'checkupdates 2>/dev/null | wc -l')
  info "pending updates on the fresh install: $n"
  if ((n > 0)); then
    vm_ssh "printf '%s\\n' '$VM_USER ALL=(ALL) NOPASSWD: ALL' 'Defaults:$VM_USER verifypw=any' >/etc/sudoers.d/99-gfdrill && chmod 440 /etc/sudoers.d/99-gfdrill" || return 1
    as_user 'omarchy update -y' >"$(d logs/stock-update.log)" 2>&1
    local rc=$?
    vm_ssh 'rm -f /etc/sudoers.d/99-gfdrill'
    ((rc == 0)) && pass "Omarchy's own update ran (log $(d logs/stock-update.log))" || { fail "the Omarchy update exited $rc (log $(d logs/stock-update.log))"; return 1; }
    reboot_vm || { fail "reboot after the update"; return 1; }
  fi
  n=$(as_user 'checkupdates 2>/dev/null | wc -l')
  [[ $n == 0 ]] && pass "no pending update left on the stock system" || fail "$n updates still pending after the update"
}

# restore_stock: back to the qcow2 snapshot "stock" (the fresh install) and its OVMF variables, VM stopped
restore_stock() {
  vm_stop
  check "restore qcow2 snapshot 'stock'" qemu-img snapshot -a stock "$(DISK)" || return 1
  cp -f "$(d OVMF_VARS.stock.fd)" "$(d OVMF_VARS.4m.fd)"
}

# The snapshot "stock" is the FRESH install (updates pending, as the ISO leaves it): the installer's own update step is part of
# what the drill exercises. The baseline the end state is compared with is that same system after Omarchy's update ("stock"
# record). Run again, the phase starts from the existing snapshot.
phase_snapshot() {
  creds
  if qemu-img snapshot -l "$(DISK)" 2>/dev/null | grep -q ' stock '; then
    restore_stock || return 1
    boot_installed snapshot || return 1
  else
    vm_running || boot_installed snapshot || return 1
  fi
  vm_ssh true || { fail "no SSH to the VM: run stock-install first"; return 1; }
  vm_ssh 'pacman -Q omarchy' | sed 's/^/INFO fresh install: /'
  collect fresh || { fail "collecting the fresh record"; return 1; }
  vm_stop
  vm_running && { fail "VM did not stop"; return 1; }
  qemu-img snapshot -d stock "$(DISK)" >/dev/null 2>&1
  check "qcow2 snapshot 'stock' (the fresh install)" qemu-img snapshot -c stock "$(DISK)" || return 1
  cp -f "$(d OVMF_VARS.4m.fd)" "$(d OVMF_VARS.stock.fd)"
  qemu-img snapshot -l "$(DISK)" | sed 's/^/INFO /'
  boot_installed snapshot || return 1
  stock_update || return 1
  vm_ssh 'pacman -Q omarchy' | sed 's/^/INFO stock /'
  collect stock || { fail "collecting the stock record"; return 1; }
  pass "stock record (the fresh install after Omarchy's update) written to $(REC stock)"
  sleep 20
  shot stock-session
  vm_ssh 'loginctl list-sessions --no-legend' | sed 's/^/INFO /'
  vm_stop
  if vm_running; then fail "VM did not stop"; return 1; fi
}

phase_install() {
  creds
  if ((RESTORE)); then restore_stock || return 1; fi
  boot_installed install || return 1
  local script
  script=$(d logs/grassfield-install.sh)
  if ((BRANCH_INSTALLER)); then
    python3 -I "$repo/packaging/install/render.py" --conf "$repo/packaging/pacman/repository.conf" \
      --template "$repo/packaging/install/grassfield-install.sh.in" --out "$(d logs/rendered)" >/dev/null || { fail "cannot render the installer of this checkout"; return 1; }
    INSTALLER=$(d logs/rendered/grassfield-install.sh)
  fi
  if [[ -n $INSTALLER ]]; then
    cp -f "$INSTALLER" "$script"
    info "installer: $INSTALLER (a local file, not the published script)"
  else
    curl -fsSL "$GF_INSTALL_URL" -o "$script" || { fail "cannot download $GF_INSTALL_URL"; return 1; }
    info "installer: $GF_INSTALL_URL sha256 $(sha256sum "$script" | cut -c1-64)"
  fi
  # The drill's only change besides SSH: the user may run privileged commands without a typed password (removed by `uninstall`).
  vm_ssh "printf '%s\\n' '$VM_USER ALL=(ALL) NOPASSWD: ALL' 'Defaults:$VM_USER verifypw=any' >/etc/sudoers.d/99-gfdrill && chmod 440 /etc/sudoers.d/99-gfdrill" || return 1
  # No authentication agent answers an SSH run, so grassfield-channel-set's privileged call would be refused: a drill rule
  # lets the drill user through (removed by `uninstall`). The password prompt a user sees there is NOT exercised here.
  vm_ssh "cat >/etc/polkit-1/rules.d/99-gfdrill.rules" <<EOF || return 1
polkit.addRule(function (action, subject) { if (subject.user == "$VM_USER") return polkit.Result.YES; });
EOF
  vm_ssh "cat >/home/$VM_USER/grassfield-install.sh && chown $VM_USER: /home/$VM_USER/grassfield-install.sh" <"$script" || return 1
  local log rc
  log=$(d logs/install-run.log)
  as_user "bash ~/grassfield-install.sh --help" | head -5 | sed 's/^/INFO help: /'
  as_user "bash ~/grassfield-install.sh --dry-run --yes" >"$(d logs/install-dry-run.log)" 2>&1
  rc=$?
  ((rc == 0)) && pass "grassfield-install.sh --dry-run exits 0" || fail "grassfield-install.sh --dry-run exit $rc: $(tail -3 "$(d logs/install-dry-run.log)")"
  as_user "bash ~/grassfield-install.sh --yes" >"$log" 2>&1
  rc=$?
  if ((rc != 0)) && grep -qE 'failed retrieving file|checkupdates failed' "$log"; then
    sleep 20 # a mirror or the network dropped (the script changed nothing or rolled back): once more, as it says
    info "a mirror dropped a download (the script rolled back): running it again, as it says"
    cp "$log" "$log.attempt1"
    as_user "bash ~/grassfield-install.sh --yes" >"$log" 2>&1
    rc=$?
  fi
  tail -15 "$log" | sed 's/^/INFO install: /'
  ((rc == 0)) && pass "grassfield-install.sh --yes exits 0" || { fail "grassfield-install.sh --yes exit $rc (log $log)"; return 1; }
  vm_ssh "pacman -Q grassfield-desktop grassfield-compositor grassfield-store" | sed 's/^/INFO version: /'
  vm_ssh "pacman -Q omarchy" | sed 's/^/INFO version: /'
  reboot_vm || { fail "reboot after the install"; return 1; }
}

# journal_has <pattern>: the user journal of this boot
journal_has() {
  as_user "journalctl --user -b --no-pager | grep -q -F -- $(printf '%q' "$1")"
}

phase_check() {
  creds
  vm_running || boot_installed check || return 1
  local i
  # the session starts on its own: wait for the shell's markers
  for ((i = 0; i < 180; i += 5)); do journal_has "grassfield-shell: usable" 2>/dev/null && break; sleep 5; done
  sleep 5
  shot login-session
  vm_ssh 'cat /etc/sddm.conf.d/*.conf 2>/dev/null' | sed 's/^/INFO sddm: /'
  vm_ssh 'loginctl list-sessions --no-legend' | sed 's/^/INFO /'
  as_user 'journalctl --user -b --no-pager | grep -E "grassfield-shell: (started|usable)"' | sed 's/^/INFO journal: /'
  check "journal: grassfield-shell: started" journal_has "grassfield-shell: started"
  check "journal: grassfield-shell: usable" journal_has "grassfield-shell: usable"
  check "grassfield-shell.service active" as_user 'systemctl --user is-active --quiet grassfield-shell.service'
  check "grassfield-security.service active" as_user 'systemctl --user is-active --quiet grassfield-security.service'
  local failed
  failed=$(as_user 'systemctl --user --failed --no-legend --no-pager' 2>&1)
  [[ -z $failed ]] && pass "no failed user unit" || fail "failed user units: $failed"
  failed=$(vm_ssh 'systemctl --failed --no-legend --no-pager' 2>&1)
  [[ -z $failed ]] && pass "no failed system unit" || info "failed system units: $failed"
  as_user 'pgrep -a Hyprland | head -2; pgrep -a quickshell | head -2' | sed 's/^/INFO /'
  info "the menu bar and the Dock are judged on $(SHOTS)/login-session.png (a person looks at it)"
}

phase_uninstall() {
  creds
  vm_running || boot_installed uninstall || return 1
  local log rc pk
  log=$(d logs/uninstall-run.log)
  as_user "bash ~/grassfield-install.sh --uninstall --yes" >"$log" 2>&1
  rc=$?
  tail -15 "$log" | sed 's/^/INFO uninstall: /'
  ((rc == 0)) && pass "grassfield-install.sh --uninstall --yes exits 0" || fail "grassfield-install.sh --uninstall exit $rc (log $log)"
  # docs/owner-setup/real-session.md section 9: after --uninstall nothing of it is left to do by hand except the settings
  # the uninstall keeps by design (it prints where they are and the one command that deletes them).
  pk=$(vm_ssh "pacman -Q | awk '/^grassfield-/{print \$1}'" | tr '\n' ' ')
  [[ -z $pk ]] && pass "no grassfield package left after --uninstall (GF-046)" || fail "packages left after --uninstall: $pk"
  grep -q "/home/$VM_USER/.config/grassfield" "$log" && grep -q 'rm -rf' "$log" &&
    pass "--uninstall prints where the kept settings and state are and the command that removes them" ||
    fail "--uninstall does not print the kept folders and the removal command"
  vm_ssh "rm -f /etc/sudoers.d/99-gfdrill /etc/polkit-1/rules.d/99-gfdrill.rules /home/$VM_USER/grassfield-install.sh"
  reboot_vm || { fail "reboot after the uninstall"; return 1; }
  sleep 45
  shot uninstall-session
}

# compare: stock record against the state now; every leftover with its path and origin
phase_compare() {
  creds
  vm_running || boot_installed compare || return 1
  collect after || { fail "collecting the post-uninstall record"; return 1; }
  local s a out n line pkg
  s=$(REC stock) a=$(REC after) out=$(d records/leftovers.tsv)
  : >"$out"
  while read -r line; do
    pkg=${line%% *}
    printf 'package\t%s\t%s\n' "$line" "$(vm_ssh "pacman -Qi $pkg | awk -F': *' '/^(Install Reason|Required By)/{printf \"%s=%s; \", \$1, \$2}'" </dev/null)" >>"$out"
  done < <(comm -13 "$s/packages.txt" "$a/packages.txt")
  comm -23 "$s/packages.txt" "$a/packages.txt" | sed 's/^/package-missing\t/; s/$/\tpresent in stock, absent now/' >>"$out"
  # Scope: /etc, ~/.config, ~/.local/share (a record that also holds ~/.cache or ~/.local/state is cut to the same scope)
  LC_ALL=C sort -t$'\t' -k1,1 "$s/files.tsv" | grep -vE "^/home/[^/]+/(\.cache|\.local/state)/" >"$s/files.sorted"
  LC_ALL=C sort -t$'\t' -k1,1 "$a/files.tsv" | grep -vE "^/home/[^/]+/(\.cache|\.local/state)/" >"$a/files.sorted"
  LC_ALL=C join -t$'\t' -a1 -a2 -e '-' -o 0,1.2,1.3,2.2,2.3 "$s/files.sorted" "$a/files.sorted" |
    awk -F'\t' '$1 != "/etc/group" && $1 != "/etc/gshadow" && (($2 != $4) || ($3 != $5)) { k = ($2 == "-") ? "file-added" : ($4 == "-") ? "file-removed" : "file-changed"; print k "\t" $1 "\t" $3 " -> " $5 }' >>"$out"
  diff "$s/units-system.txt" "$a/units-system.txt" | sed -n 's/^< \(.*\)/unit-removed\t\1\t-/p;s/^> \(.*\)/unit-added\t\1\t-/p' >>"$out"
  diff "$s/units-user.txt" "$a/units-user.txt" | sed -n 's/^< \(.*\)/user-unit-removed\t\1\t-/p;s/^> \(.*\)/user-unit-added\t\1\t-/p' >>"$out"
  sed 's/^/extra\t/;s/$/\t-/' "$a/extra.txt" >>"$out"
  # /etc/group and /etc/gshadow are compared by content, line by line (the file hashes above skip them): every difference is a row
  diff "$s/groups.txt" "$a/groups.txt" | sed -n 's/^< \(.*\)/group-removed\t\/etc\/group\t\1/p;s/^> \(.*\)/group-added\t\/etc\/group\t\1/p' >>"$out"
  diff "$s/gshadow-names.txt" "$a/gshadow-names.txt" | sed -n 's/^< \(.*\)/gshadow-removed\t\/etc\/gshadow\t\1/p;s/^> \(.*\)/gshadow-added\t\/etc\/gshadow\t\1/p' >>"$out"
  local kind path note origin
  while IFS=$'\t' read -r kind path note; do
    if [[ $kind == file-added || $kind == file-changed ]]; then
      origin=$(vm_ssh "pacman -Qoq '$path' 2>/dev/null || echo 'no package owns it'" </dev/null)
      printf '%s\t%s\t%s\n' "$kind" "$path" "${origin//$'\n'/ }"
    else
      printf '%s\t%s\t%s\n' "$kind" "$path" "$note"
    fi
  done <"$out" >"$out.tmp" && mv "$out.tmp" "$out"
  # Anything not matched below is a leftover. Each rule is "extended regex of the path<TAB>reason".
  local h=/home/$VM_USER
  local -a noise=(
    $'^/etc/\\.updated$\tpacman'"'"'s ConditionNeedsUpdate marker, rewritten by every package transaction (the update step of the drill already ran them)'
    $'^/etc/pacman\\.d/gnupg/(trustdb\\.gpg|pubring\\.gpg~)$\tpacman keyring: adding and deleting a key rewrites the trust database and the keyring backup'
    $'^/etc/(group|gshadow)-$\tshadow-utils backup copies, written at every account or group change (a sysusers file of the package creates the group)'
    "^$h/\\.config/dconf/user\$"$'\tGNOME settings database, rewritten by the session at every start'
    "^$h/\\.config/ibus/bus/"$'\tIBus socket files named after the machine id and the display, new at every session start'
    "^$h/\\.config/herdr/"$'\tlog of the terminal multiplexer that Omarchy starts, appended at every session'
    "^$h/\\.local/share/gvfs-metadata/"$'\tGVfs metadata journal, rolled over by the session'
  )
  # The user's own Grassfield settings and state: kept by design, documented (docs/install.md, docs/owner-setup/real-session.md section 9)
  # The grassfield-update system group (created by a package's sysusers file): Arch never removes a system group, a reused gid
  # would give access to what it left behind. Its lines in the group and shadow databases stay.
  local kept="^$h/\\.(config|local/state)/grassfield(/|\$)|^$h/\\.config/grassfield-mimeapps\\.list\$"
  local rules="" r
  for r in "${noise[@]}"; do rules+="$r"$'\n'; done
  printf '%s' "$rules" >"$(d records/allowlist.tsv)"
  n=0
  local kind path origin why
  printf '\n%-14s %-70s %s\n' KIND PATH ORIGIN
  while IFS=$'\t' read -r kind path origin; do
    why=$(awk -F'\t' -v p="$path" 'p ~ $1 { print $2; exit }' "$(d records/allowlist.tsv)")
    # The only accepted group difference: our sysusers file's group, as created (name, gid, no member), and its gshadow name.
    if { [[ $kind == group-added && $origin =~ ^grassfield-update:[0-9]+:$ ]] || [[ $kind == gshadow-added && $origin == grassfield-update ]]; }; then
      printf '%-14s %-70s %s  [kept by design (Arch convention for system groups)]\n' "$kind" "$path" "$origin"
    elif [[ -n $why ]]; then
      printf '%-14s %-70s %s  [system noise: %s]\n' "$kind" "$path" "$origin" "$why"
    elif [[ $path =~ $kept ]]; then
      printf '%-14s %-70s %s  [kept by design (documented)]\n' "$kind" "$path" "$origin"
    else
      printf '%-14s %-70s %s  [LEFTOVER]\n' "$kind" "$path" "$origin"
      n=$((n + 1))
    fi
  done <"$out"
  echo
  if ((n == 0)); then pass "no leftover: packages, files, units equal the stock record"; else fail "$n leftover(s) against the stock record (table above, saved to $out)"; fi
  shot compare-session
}

# compare-canary: a group added on purpose must be caught as a leftover, and gone again it must not be
phase_compare_canary() {
  creds
  vm_running || boot_installed canary || return 1
  local before=$FAILS
  vm_ssh 'groupadd gf-canary' || { fail "cannot add the canary group"; return 1; }
  phase_compare >"$(d logs/compare-canary.log)" 2>&1 # not in a pipeline: FAILS must survive
  grep 'gf-canary\|^PASS\|^FAIL' "$(d logs/compare-canary.log)"
  if grep -q 'group-added.*gf-canary.*\[LEFTOVER\]' "$(d logs/compare-canary.log)" && grep -q 'gshadow-added.*gf-canary.*\[LEFTOVER\]' "$(d logs/compare-canary.log)" && ((FAILS > before)); then
    FAILS=$before
    pass "a group added on purpose is caught as a leftover (group and gshadow rows)"
  else
    fail "the canary group was NOT caught as a leftover"
  fi
  vm_ssh 'groupdel gf-canary'
  phase_compare
}

# update-migrate: tests/integration/update_migrate.sh runs systemd as PID 1 in a container, which once ended a live session:
# it runs ONLY here, in the VM. The repository's committed HEAD is shipped, the in-VM runner prints the VM's own console log.
phase_update_migrate() {
  creds
  local src log rc
  src=$(git -C "${UM_REPO:-$repo}" rev-parse --show-toplevel 2>/dev/null) || { fail "no repository at ${UM_REPO:-$repo}"; return 1; }
  [[ -f $src/tests/integration/update_migrate_in_vm.sh ]] || { fail "no tests/integration/update_migrate_in_vm.sh in $src"; return 1; }
  vm_running || boot_installed update-migrate || return 1
  git -C "$src" archive HEAD | vm_ssh 'rm -rf /opt/update-migrate-repo && mkdir -p /opt/update-migrate-repo && tar -x -C /opt/update-migrate-repo' ||
    { fail "cannot ship the repository to the VM"; return 1; }
  log=$(d logs/update-migrate.log)
  vm_ssh 'bash /opt/update-migrate-repo/tests/integration/update_migrate_in_vm.sh /opt/update-migrate-repo' >"$log" 2>&1
  rc=$?
  grep -E '^(== |\(none\)|\(identical\)|FAIL|PASS: update_migrate|update_migrate)' "$log" | tail -20
  if ((rc == 0)); then pass "update_migrate.sh in the VM: $(grep '== update_migrate:' "$log")"; else fail "update_migrate.sh in the VM exited $rc (log $log)"; fi
  local k j
  k=$(sed -n '/== kernel log lines/,/== journal lines/p' "$log" | grep -v '^==')
  j=$(sed -n '/== journal lines/,/== console before/p' "$log" | grep -v '^==')
  [[ $k == '(none)' ]] && pass "the VM's kernel log shows nothing about its console during the run" || fail "kernel log lines about the console: $k"
  [[ $j == '(none)' ]] && pass "the VM's journal shows no vconsole, getty, udev or SIGHUP line during the run" || fail "journal lines: $j"
  grep -q '^(identical)$' "$log" && pass "the console binding is the same before and after" || fail "the console binding changed"
}

main() {
  local phase=${1:-}
  [[ -n $phase ]] || { usage; exit 2; }
  shift || true
  local -a rest=()
  while (($#)); do
    case $1 in
      --vm-dir) VM_DIR=$2; shift ;;
      --installer) INSTALLER=$2; shift ;;
      --branch-installer) BRANCH_INSTALLER=1 ;;
      --no-restore) RESTORE=0 ;;
      --force) FORCE=1 ;;
      --reuse-stock) REUSE_STOCK=1 ;;
      --repo) UM_REPO=$2; shift ;;
      --max-load) MAX_LOAD=$2; shift ;;
      -h | --help) usage; exit 0 ;;
      *) rest+=("$1") ;;
    esac
    shift
  done
  mkdir -p "$VM_DIR"/{iso,shots,logs,keys,records}
  case $phase in
    vm-up) creds; boot_installed vm-up; exit $? ;;
    update-migrate) phase_update_migrate ;;
    vm-start) vm_start "${rest[0]:-disk}"; exit $? ;;
    vm-stop) vm_stop; exit 0 ;;
    shot) shot "${rest[0]:?name}"; exit $? ;;
    key) qmp key "${rest[@]}"; exit $? ;;
    type) qmp type "${rest[@]}"; exit $? ;;
    enable-ssh) creds; enable_ssh; exit $? ;;
    type-pass) creds; printf "%s" "$VM_PASS" | qmp type-stdin; exit $? ;;
    ssh) vm_ssh "${rest[@]}"; exit $? ;;
    stock-install) phase_stock_install ;;
    snapshot) phase_snapshot ;;
    install) phase_install ;;
    check) phase_check ;;
    uninstall) phase_uninstall ;;
    compare) phase_compare ;;
    compare-canary) phase_compare_canary ;;
    all)
      local seq=(stock_install snapshot install check uninstall compare)
      ((REUSE_STOCK)) && seq=(snapshot install check uninstall compare)
      for p in "${seq[@]}"; do
        printf '== phase %s ==\n' "${p//_/-}"
        "phase_$p" || fail "phase ${p//_/-} failed"
        ((FAILS == 0)) || break
      done ;;
    -h | --help | help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  ((FAILS == 0))
}
main "$@"
