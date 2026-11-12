#!/usr/bin/env bash
# Activity Monitor, step 1: other owners' processes through the real kernel (ADR-0038 c, AD25; docs/specs/activity.md AM17,
# AM28, acceptance A-S2b), in a throwaway Arch container with two users. What alice's sampler shows of bob's processes:
# their CPU and memory, the kernel's short name, nothing of their command line (an argv[0] title included), io or
# descriptors; and of her own: her command line, her io, her descriptors. The actions refused on bob's rows join this test
# with step 2. Never on a real machine: inside, it refuses to run unless it is root in a container with the repository at /src.
#
#   tests/integration/activity_owners.sh
#   Runs `docker run --rm --network host` on archlinux:base (digest pinned below) with the repository mounted read-only;
#   HTTPS_PROXY/HTTP_PROXY/NO_PROXY are passed through and GRASSFIELD_TEST_CA, when set, is mounted as the container's CA
#   bundle (for a proxied network). Exit 0 all PASS (or SKIP without docker), 1 a FAIL, 2 usage or a refused run.
set -uo pipefail

IMAGE=archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0

if [[ ${1:-} != --inside ]]; then
  [[ $# == 0 ]] || { echo "usage: tests/integration/activity_owners.sh" >&2; exit 2; }
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
  . "$root/tests/integration/container.sh" || exit 2
  gf_have_docker || { echo "SKIP: no docker daemon (this test runs only in a throwaway container)"; exit 0; }
  gf_container_init "$root" || exit 2
  gf_standard auto || exit 2
  gf_container_run "$IMAGE" bash /src/tests/integration/activity_owners.sh --inside
  exit $?
fi

[[ -f /.dockerenv && $(id -u) == 0 && -d /src/apps/activity ]] || { echo "refused: runs only as root inside its throwaway container"; exit 2; }
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

W=/work
mkdir -p "$W"
quiet() { "$@" >>"$W/log" 2>&1; }
sed -i 's/^#\?DisableSandbox.*//; /^\[options\]/a DisableSandbox' /etc/pacman.conf
quiet pacman-key --init
quiet pacman-key --populate archlinux
quiet pacman -Syu --noconfirm --needed gcc git || { echo "FAIL: pacman -Syu gcc git (see $W/log)"; tail -5 "$W/log"; exit 1; }
useradd -m alice
useradd -m bob
as() { local u=$1; shift; setpriv --reuid="$u" --regid="$u" --init-groups -- env HOME="/home/$u" "$@"; } # exec, no parent left

cp -r /src /home/alice/repo && chown -R alice:alice /home/alice/repo
as alice git config --global --add safe.directory '*'
as alice bash -c 'cd /home/alice/repo && apps/activity/build-direct.sh --bench' >>"$W/log" 2>&1 || { echo "FAIL: building the bench (see $W/log)"; tail -5 "$W/log"; exit 1; }
bench=/home/alice/repo/.dev/build/activity-sampler-bench

# bob: a process whose argv[0] is a title, as an SSH server writes one; alice: one of her own with arguments, its argv[0]
# rewritten to a path that is not its executable.
as bob bash -c 'exec -a "sshd: bob@pts/0 secret-host" sleep 600' &
as alice bash -c 'exec -a /usr/bin/alicetool sleep 600 1s' &
sleep 1
bob_pid=$(pgrep -u bob -x sleep | head -1)
alice_pid=$(pgrep -u alice -x sleep | head -1)
[[ -n $bob_pid && -n $alice_pid ]] || { echo "FAIL: the fixture processes did not start"; exit 1; }

dump=$(as alice "$bench" dump --tab cpu --samples 2 --interval-ms 300)
row() { awk -F'\t' -v p="$1" '$1 == p' <<<"$dump"; }
field() { awk -F'\t' -v p="$1" -v f="$2" 'NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next } $1 == p { print $col[f] }' <<<"$dump"; }

[[ -n $(row "$bob_pid") ]] && pass "bob's process is listed in alice's sampler" || fail "bob's process is missing"
[[ $(field "$bob_pid" own) == 0 ]] && pass "bob's row is not alice's own" || fail "bob's row: own=$(field "$bob_pid" own)"
[[ $(field "$bob_pid" uid) == "$(id -u bob)" ]] && pass "bob's row names bob's uid" || fail "bob's row: uid=$(field "$bob_pid" uid)"
[[ $(field "$bob_pid" kind) == other ]] && pass "bob's row is Other Users (uid at or above UID_MIN)" || fail "bob's row: kind=$(field "$bob_pid" kind)"
[[ $(field "$bob_pid" name) == sleep ]] && pass "bob's name is the kernel's short name" || fail "bob's row: name=$(field "$bob_pid" name)"
[[ -z $(field "$bob_pid" command) ]] && pass "bob's command line is not shown" || fail "bob's row: command=$(field "$bob_pid" command)"
grep -q "secret-host\|bob@pts" <<<"$dump" && fail "bob's argv[0] title reached the output" || pass "bob's argv[0] title appears nowhere (AD25)"
[[ $(field "$bob_pid" memory) -gt 0 ]] && pass "bob's memory is read (status)" || fail "bob's row: memory=$(field "$bob_pid" memory)"
[[ $(field "$bob_pid" hasIo) == 0 ]] && pass "bob's io is not read" || fail "bob's row: hasIo=$(field "$bob_pid" hasIo)"
[[ $(field "$bob_pid" openFiles) == -1 ]] && pass "bob's descriptors are not read" || fail "bob's row: openFiles=$(field "$bob_pid" openFiles)"

[[ $(field "$alice_pid" own) == 1 ]] && pass "alice's process is her own" || fail "alice's row: own=$(field "$alice_pid" own)"
# An argv[0] that is neither the executable nor the invoked name names nothing: the executable does (AM17, review of 949fc98).
[[ $(field "$alice_pid" name) == sleep ]] && pass "alice's rewritten argv[0] gives way to her executable's name" || fail "alice's row: name=$(field "$alice_pid" name)"
[[ $(field "$alice_pid" command) == "/usr/bin/alicetool 600 1s" ]] && pass "alice's command line is shown" || fail "alice's row: command=$(field "$alice_pid" command)"
[[ $(field "$alice_pid" hasIo) == 1 ]] && pass "alice's io is read" || fail "alice's row: hasIo=$(field "$alice_pid" hasIo)"
[[ $(field "$alice_pid" openFiles) -ge 0 ]] && pass "alice's descriptors are read" || fail "alice's row: openFiles=$(field "$alice_pid" openFiles)"
[[ $(awk -F'\t' '$1 == "kernel"' <<<"$dump" | cut -f6) == Kernel ]] && pass "the Kernel row is there" || fail "no Kernel row"

pkill -u bob sleep
pkill -u alice sleep
echo "activity_owners: $fails failure(s)"
((fails == 0))
