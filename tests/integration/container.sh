# shellcheck shell=bash
# The ONLY file in the repository that runs docker or podman for a test or a gate (sourced, never run). Every integration test
# and gate builds its container through the functions below. Three boundaries, and what each one is:
#   1. THIS FILE, at run time: it refuses anything dangerous it is handed, before docker is called (the image must be pinned by
#      digest and is the first argument, exec runs only in the container this file started, every mount source is checked
#      against a short list, the network and the capabilities are fixed). tests/shell/container_wrapper.sh calls it with a stub
#      docker and shows each refusal firing first.
#   2. tests/integration/update_migrate.sh fails closed outside a VM and beside any graphical session.
#   3. The VM (`scripts/gates/vm-drill.sh update-migrate`).
# tests/ci/no_privileged_containers.py is a lint against ACCIDENTAL reintroduction by people or agents (a docker call written
# somewhere else), not a sandbox against deliberate code: no static scan of shell can be complete.
# Why: on 2026-11-11 a `docker run --privileged` with systemd as PID 1 shared the host's /dev, the container's systemd ran
# vconsole-setup and udev on it, and the owner's live session ended three times (16:47, 19:13, 20:28).
#
# What a container gets, and nothing else:
#   - gf_mount <source> <target> ro|rw: a bind mount whose source is the repository (and, for a git worktree, its common git
#     folder, read-only, so the worktree's .git file resolves), the repository's .dev/ folder, an Omarchy tree registered by
#     omarchy_mounts (and its staged bin/), one regular file of the repository, a CA bundle (a .crt, .pem or .cer under the
#     repository's .dev/ or in the system CA folders), and, for rw only, a folder of the caller's own under /tmp or .dev/.
#     Never /, /dev, /proc, /sys, /run, /boot, nor ~/.ssh, ~/.gnupg, ~/.config.
#   - gf_network auto|none: the default network, or `--network host` ONLY when HTTP(S)_PROXY names the host's loopback (a
#     proxy there is unreachable otherwise; NO_PROXY never counts), or no network;
#   - gf_proxy_env: the proxy variables, by name;
#   - gf_container_run: `docker run --rm` (a throwaway container);
#   - gf_container_systemd_start / gf_container_exec: update_migrate.sh's container with systemd as PID 1 (CAP_SYS_ADMIN
#     minus MKNOD, a private cgroup, a tmpfs /run, no device, every unit that touches a tty or /dev masked).
# Never: --privileged, --device*, a host /dev, /run, /sys, /proc or / mount, a host namespace, --cap-add other than SYS_ADMIN.

if [[ $(readonly -p 2>/dev/null) != *" GF_ROOT="* ]]; then
  # The repository root comes from where THIS file is, never from the environment (an exported GF_ROOT=/ would mount the host).
  GF_SELF=$(realpath -e -- "${BASH_SOURCE[0]}") && GF_ROOT=$(realpath -e -- "${GF_SELF%/*}/../..") || return 1
  readonly GF_SELF GF_ROOT
  readonly -a GF_PROXY_VARS=(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy)
  readonly -a GF_PROXY_HOST_VARS=(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy)
  # The images a test may use that are not pinned by digest: none (a local image built by a test would be listed here by exact name).
  readonly -a GF_LOCAL_IMAGES=()
  readonly -a GF_CA_DIRS=(/etc/ssl/certs /etc/ca-certificates /usr/share/ca-certificates /usr/local/share/ca-certificates /etc/pki)
fi
gf_args=()
gf_trees=()
gf_stages=()
gf_cid=''

gf_have_docker() { command -v docker >/dev/null && docker info >/dev/null 2>&1; }

gf_container_init() { # <repository root>: must be the repository this file is in
  [[ $(realpath -e -- "${1:-/nonexistent}" 2>/dev/null) == "$GF_ROOT" && -d $GF_ROOT/tests/integration ]] ||
    { echo "container.sh: ${1:-?} is not the repository of this wrapper ($GF_ROOT)" >&2; return 1; }
  mkdir -p -- "$GF_ROOT/.dev" || return 1
  gf_args=() gf_trees=() gf_stages=() gf_cid=''
}

gf_under() { # <path> <base>...: the path is a base or inside one (both resolved)
  local p=$1 b
  shift
  for b in "$@"; do
    b=$(realpath -m -- "$b")
    [[ $p == "$b" || $p == "$b"/* ]] && return 0
  done
  return 1
}

# Places no test container may get a mount from, whatever else is said.
gf_forbidden() { # <resolved path>
  local p=$1 h
  [[ $p == / ]] && return 0
  gf_under "$p" /dev /proc /sys /run /boot /root && return 0
  for h in .ssh .gnupg .config .local/share/keyrings .password-store; do
    gf_under "$p" "${HOME:-/nonexistent}/$h" && return 0
  done
  return 1
}

gf_mount() { # <source> <target in the container> <ro|rw>
  local src mode=$3 t ok=0
  src=$(realpath -e -- "$1" 2>/dev/null) || { echo "container.sh: no such source: $1" >&2; return 1; }
  [[ $2 == /?* && ($mode == ro || $mode == rw) ]] || { echo "container.sh: bad mount $2 ($mode)" >&2; return 1; }
  if gf_forbidden "$src"; then echo "container.sh: a test container may not mount $src" >&2; return 1; fi
  if [[ $mode == rw ]]; then
    # An output folder of the caller's own, under /tmp or the repository's .dev/, never a link, never the whole of either.
    [[ -d $src && ! -L $1 && $(stat -c %u -- "$src") == "$(id -u)" ]] && gf_under "$src" "$GF_ROOT/.dev" /tmp &&
      [[ $src != /tmp && $src != "$GF_ROOT/.dev" ]] ||
      { echo "container.sh: a writable mount must be the caller's own folder under /tmp or .dev/: $1" >&2; return 1; }
  else
    [[ $src == "$GF_ROOT" ]] && ok=1
    gf_under "$src" "$GF_ROOT/.dev" && ok=1
    for t in "${gf_trees[@]}"; do [[ $src == "$t" ]] && ok=1; done
    # One regular file: of the repository (the gate's own script), or a CA bundle in .dev/ or the system's CA folders.
    if [[ -f $src ]]; then
      gf_under "$src" "$GF_ROOT" && ok=1
      if [[ $src == *.crt || $src == *.pem || $src == *.cer ]]; then gf_under "$src" "$GF_ROOT/.dev" "${GF_CA_DIRS[@]}" && ok=1; fi
    fi
    ((ok)) || { echo "container.sh: not a source a test container may mount: $1 (a CA bundle goes under .dev/ or the system CA folders)" >&2; return 1; }
  fi
  gf_args+=(-v "$src:$2:$mode")
}

# `host` when one of the proxy URLs names this machine's loopback (localhost, ::1, 127.x.y.z: unreachable from a container on the
# default network), else `default`. scripts/gates/rc-toolkit.sh answers its own questions with this function.
gf_proxy_network() { # <proxy URL>...
  local url host
  for url in "$@"; do
    [[ -n $url ]] || continue
    host=${url#*://}
    host=${host#*@}
    host=${host%%/*}
    if [[ $host == \[* ]]; then host=${host#\[}; host=${host%%]*}; else host=${host%%:*}; fi
    host=${host,,}
    if [[ $host == localhost || $host == ::1 || $host =~ ^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      echo host
      return 0
    fi
  done
  echo default
}

gf_network() { # <auto|none>
  case ${1:-auto} in
    none) gf_args+=(--network none) ;;
    auto)
      # The host's network namespace ONLY for a proxy on the host's loopback (HTTP(S)_PROXY; NO_PROXY never counts).
      local v urls=()
      for v in "${GF_PROXY_HOST_VARS[@]}"; do urls+=("${!v:-}"); done
      if [[ $(gf_proxy_network "${urls[@]}") == host ]]; then gf_args+=(--network host); fi ;;
    *) echo "container.sh: gf_network auto|none" >&2; return 1 ;;
  esac
}

gf_proxy_env() {
  local v
  for v in "${GF_PROXY_VARS[@]}"; do
    [[ -n ${!v:-} ]] && gf_args+=(-e "$v")
  done
  return 0
}

# The repository is a git worktree: its .git FILE names a folder (<main checkout>/.git/worktrees/<name>) the container does not
# have, so every `git` call in a copy of the tree fails ("gitfile does not point to a valid repository"). The repository's own
# common git folder is mounted read-only at the SAME absolute path. Why not a `git archive` copy: the tests copy /src and run git
# on the copy (a build that reads the revision, a bench that clones it); an archive has no .git at all, so they would
# break differently, and a copy hides the very revision under test. Read-only, it can show history, never change it.
gf_git_worktree() {
  [[ -f $GF_ROOT/.git ]] || return 0
  local common gitdir
  common=$(git -C "$GF_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && common=$(realpath -e -- "$common") ||
    { echo "container.sh: cannot resolve the git folder of this worktree" >&2; return 1; }
  gitdir=$(sed -n 's/^gitdir: //p' "$GF_ROOT/.git" | head -n 1)
  gitdir=$(realpath -e -- "$gitdir" 2>/dev/null) || gitdir=''
  [[ -d $common/objects && -f $common/HEAD && $gitdir == "$common"/worktrees/* ]] ||
    { echo "container.sh: this worktree's .git file does not lead into the common git folder $common" >&2; return 1; }
  if gf_under "$common" /usr /etc /bin /sbin /lib /var /opt/omarchy; then echo "container.sh: the git folder $common is in a system folder" >&2; return 1; fi
  gf_trees+=("$common")
  gf_mount "$common" "$common" ro
}

# The usual options of a throwaway test container: the repository at /src (read-only; a worktree's git folder with it), the CA
# bundle when GRASSFIELD_TEST_CA is set, the proxy variables, the network. <ca target> defaults to the system bundle.
gf_standard() { # <auto|none> [ca target]
  gf_mount "$GF_ROOT" /src ro || return 1
  gf_git_worktree || return 1
  if [[ -n ${GRASSFIELD_TEST_CA:-} ]]; then
    gf_mount "$GRASSFIELD_TEST_CA" "${2:-/etc/ssl/certs/ca-certificates.crt}" ro || return 1
  fi
  gf_proxy_env
  gf_network "${1:-auto}"
}

# An Omarchy tree: read-only as it is, with its bin/ staged and mounted over it. From Omarchy 4.0.6 on the tree's bin/ holds
# absolute links to /usr/bin, which do not resolve inside a container (the 2026-11-08 runs on Omarchy 4.5.0-3). The stage is a
# folder of its own for this run under <repository>/.dev (concurrent runs never touch each other's; an EXIT trap removes it when
# the caller has none of its own), made of regular files only: a link is followed only when it ends in the tree itself or in
# /usr/{bin,lib,share}, and anything that is not a regular file (a device, a FIFO, a folder, a link elsewhere) is refused. A
# dangling link is left out.
omarchy_mounts() { # <tree> <mount point>
  local tree point=$2 stage f t
  tree=$(realpath -e -- "$1" 2>/dev/null) && [[ -d $tree/bin && $point == /?* ]] || { echo "omarchy_mounts: no bin/ in ${1:-?}" >&2; return 1; }
  if gf_forbidden "$tree"; then echo "omarchy_mounts: a test container may not mount $tree" >&2; return 1; fi
  stage=$(mktemp -d "$GF_ROOT/.dev/omarchy-stage.XXXXXX") || return 1
  gf_stages+=("$stage")
  [[ -n $(trap -p EXIT) ]] || trap gf_container_cleanup EXIT
  chmod 755 "$stage" && mkdir -p "$stage/bin" || return 1
  for f in "$tree"/bin/*; do
    [[ -e $f || -L $f ]] || continue
    t=$(realpath -e -- "$f" 2>/dev/null) || { echo "omarchy_mounts: $f is a dangling link: left out" >&2; continue; }
    case $t in "$tree"/* | /usr/bin/* | /usr/lib/* | /usr/share/*) ;; *) echo "omarchy_mounts: $f ends in $t, outside the tree and /usr: refused" >&2; return 1 ;; esac
    [[ -f $t ]] || { echo "omarchy_mounts: $f is not a regular file: refused" >&2; return 1; }
    cp --preserve=mode -- "$t" "$stage/bin/${f##*/}" || { echo "omarchy_mounts: cannot copy $f" >&2; return 1; }
  done
  gf_trees+=("$tree" "$stage/bin")
  gf_mount "$tree" "$point" ro && gf_mount "$stage/bin" "$point/bin" ro
}

gf_container_cleanup() {
  local s
  if [[ -n $gf_cid ]]; then docker rm -f "$gf_cid" >/dev/null 2>&1; fi
  gf_cid=''
  for s in "${gf_stages[@]}"; do
    gf_under "$s" "$GF_ROOT/.dev" && rm -rf -- "$s"
  done
  gf_stages=()
  return 0
}

# The image: the first argument, never an option, pinned by digest (or one of GF_LOCAL_IMAGES by exact name). Checked before docker.
gf_check_image() { # <image>
  local i
  for i in "${GF_LOCAL_IMAGES[@]}"; do [[ ${1-} == "$i" ]] && return 0; done
  [[ ${1-} =~ ^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]] ||
    { echo "container.sh: the image must be the first argument and pinned by digest (name@sha256:<64 hex>), got '${1-}'" >&2; return 1; }
}

# A throwaway container (--rm) with the options collected above; the stages are removed afterwards. Returns docker's status
# (2 when an argument was refused: docker was not called).
gf_container_run() { # <image> <command...>
  local rc
  gf_check_image "${1-}" || { gf_container_cleanup; return 2; }
  docker run --rm "${gf_args[@]}" "$@"
  rc=$?
  gf_container_cleanup
  return "$rc"
}

# update_migrate.sh's container: systemd as PID 1, detached; its id is kept in gf_cid (and printed). Granted: CAP_SYS_ADMIN (the
# cgroup2 mount and the units' own mount namespaces) minus MKNOD, a private cgroup namespace, tmpfs /run, /run/lock and /tmp.
# No device, no host path. <mask> is a list of unit names, masked before systemd starts.
gf_container_systemd_start() { # <image> <units to mask>
  local image=${1-} mask=${2-} script
  gf_check_image "$image" || return 2
  read -r -d '' script <<'EOS' || true
umount -l /sys/fs/cgroup 2>/dev/null
mount -t cgroup2 none /sys/fs/cgroup || exit 1
mkdir -p /etc/systemd/system
for u in $0; do ln -sf /dev/null "/etc/systemd/system/$u"; done
exec /usr/lib/systemd/systemd
EOS
  gf_args+=(-d --cap-add SYS_ADMIN --cap-drop MKNOD --cgroupns=private --tmpfs /run --tmpfs /run/lock --tmpfs /tmp -e container=docker)
  gf_cid=$(docker run "${gf_args[@]}" "$image" bash -c "$script" "$mask") || return 1
  printf '%s\n' "$gf_cid"
}

# Only in the container this wrapper started (gf_cid): never another one, never an id the caller made up.
gf_container_exec() { # <id> <command...>
  [[ -n $gf_cid && ${1-} == "$gf_cid" ]] || { echo "container.sh: exec runs only in the container this wrapper started" >&2; return 2; }
  local id=$1 envs=() v
  shift
  for v in "${GF_PROXY_VARS[@]}"; do
    [[ -n ${!v:-} ]] && envs+=(-e "$v")
  done
  docker exec "${envs[@]}" "$id" "$@"
}
