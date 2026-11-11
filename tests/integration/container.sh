# shellcheck shell=bash
# The ONLY file in the repository that runs docker or podman for a test or a gate (sourced, never run). Every integration test
# and gate builds its container through the functions below; tests/ci/no_privileged_containers.py (`just check-containers`,
# part of `just check-quick`) refuses a docker or podman call anywhere else except `docker info`, and holds THIS file to
# a short list of options, so a test can never hand the host to a container. Why: on 2026-11-11 a `docker run --privileged`
# with systemd as PID 1 shared the host's /dev, the container's systemd ran vconsole-setup and udev on it, and the owner's
# live session ended three times (16:47, 19:13, 20:28).
#
# What a container gets, and nothing else:
#   - gf_mount <source> <target> ro|rw: a bind mount whose source is the repository, its .dev/ folder, an Omarchy tree
#     registered by omarchy_mounts (and its staged bin/), a single regular file (a CA bundle, the gate's own script), and,
#     for rw only, a directory of the caller's own under .dev/ or $TMPDIR. Any other source is refused at run time;
#   - gf_network auto|none: the default network, or `--network host` ONLY when a proxy variable is set (a proxy on the host's
#     loopback is unreachable otherwise), or no network;
#   - gf_proxy_env: the proxy variables, by name;
#   - gf_container_run: `docker run --rm` (a throwaway container);
#   - gf_container_systemd_start / gf_container_exec: update_migrate.sh's container with systemd as PID 1 (CAP_SYS_ADMIN
#     minus MKNOD, a private cgroup, a tmpfs /run, no device, every unit that touches a tty or /dev masked). Only
#     tests/integration/update_migrate.sh may call gf_container_systemd_start (checked by the guard).
# Never: --privileged, --device*, a host /dev, /run, /sys, /proc or / mount, a host namespace, --cap-add other than SYS_ADMIN.

GF_ROOT=''
gf_args=()
gf_trees=()
gf_stages=()
gf_cid=''
GF_PROXY_VARS=(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy)

gf_have_docker() { command -v docker >/dev/null && docker info >/dev/null 2>&1; }

gf_container_init() { # <repository root>
  GF_ROOT=$(realpath -e -- "$1" 2>/dev/null) && [[ -d $GF_ROOT/tests/integration ]] || { echo "container.sh: not a repository root: ${1:-?}" >&2; return 1; }
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

gf_mount() { # <source> <target in the container> <ro|rw>
  local src mode=$3 t
  src=$(realpath -e -- "$1" 2>/dev/null) || { echo "container.sh: no such source: $1" >&2; return 1; }
  [[ $2 == /?* && ($mode == ro || $mode == rw) ]] || { echo "container.sh: bad mount $2 ($mode)" >&2; return 1; }
  if [[ $mode == rw ]]; then
    # An output folder of the caller's own, in .dev/ or under $TMPDIR, never a link.
    [[ -d $src && ! -L $1 && $(stat -c %u -- "$src") == "$(id -u)" ]] && gf_under "$src" "$GF_ROOT/.dev" "${TMPDIR:-/tmp}" ||
      { echo "container.sh: a writable mount must be the caller's own folder under .dev/ or \$TMPDIR: $1" >&2; return 1; }
    [[ $src != "$(realpath -m -- "${TMPDIR:-/tmp}")" && $src != "$GF_ROOT/.dev" ]] || { echo "container.sh: not the whole of $src" >&2; return 1; }
  else
    local ok=0
    [[ $src == "$GF_ROOT" ]] && ok=1
    gf_under "$src" "$GF_ROOT/.dev" && ok=1
    for t in "${gf_trees[@]}"; do [[ $src == "$t" ]] && ok=1; done
    # One regular file: a CA bundle, or a file of the repository (the gate's own script).
    if [[ -f $src ]] && { gf_under "$src" "$GF_ROOT" || [[ $src == *.crt || $src == *.pem || $src == *.cer ]]; }; then ok=1; fi
    ((ok)) || { echo "container.sh: not a source a test container may mount: $1" >&2; return 1; }
  fi
  gf_args+=(-v "$src:$2:$mode")
}

gf_network() { # <auto|none>
  case ${1:-auto} in
    none) gf_args+=(--network none) ;;
    auto)
      local v
      for v in "${GF_PROXY_VARS[@]}"; do
        # A proxy is usually on the host's loopback: only then does the container share the host's network namespace.
        if [[ -n ${!v:-} ]]; then gf_args+=(--network host); return 0; fi
      done ;;
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

# The usual options of a throwaway test container: the repository at /src (read-only), the CA bundle when
# GRASSFIELD_TEST_CA is set, the proxy variables, the network. <ca target> defaults to the system bundle.
gf_standard() { # <auto|none> [ca target]
  gf_mount "$GF_ROOT" /src ro || return 1
  if [[ -n ${GRASSFIELD_TEST_CA:-} ]]; then
    gf_mount "$GRASSFIELD_TEST_CA" "${2:-/etc/ssl/certs/ca-certificates.crt}" ro || return 1
  fi
  gf_proxy_env
  gf_network "${1:-auto}"
}

# An Omarchy tree: read-only as it is, with its bin/ staged and mounted over it. From Omarchy 4.0.6 on the tree's bin/ holds
# absolute links to /usr/bin, which do not resolve inside a container (the 2026-11-08 runs on Omarchy 4.5.0-3). The stage is a
# folder of its own for this run under <repository>/.dev (concurrent runs never touch each other's), made of regular files only:
# a link is followed only when it ends in the tree itself or in /usr/{bin,lib,share}, and anything that is not a regular
# file (a device, a FIFO, a folder, a link elsewhere) is refused. A dangling link is left out.
omarchy_mounts() { # <tree> <mount point>
  local tree point=$2 stage f t
  tree=$(realpath -e -- "$1" 2>/dev/null) && [[ -d $tree/bin && $point == /?* ]] || { echo "omarchy_mounts: no bin/ in ${1:-?}" >&2; return 1; }
  stage=$(mktemp -d "$GF_ROOT/.dev/omarchy-stage.XXXXXX") || return 1
  gf_stages+=("$stage")
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

# A throwaway container (--rm) with the options collected above; the stages are removed afterwards. Returns docker's status.
gf_container_run() { # <image> <command...>
  local rc
  docker run --rm "${gf_args[@]}" "$@"
  rc=$?
  gf_container_cleanup
  return "$rc"
}

# update_migrate.sh's container: systemd as PID 1, detached; prints its id (kept for gf_container_exec and cleanup).
# Granted: CAP_SYS_ADMIN (the cgroup2 mount and the units' own mount namespaces) minus MKNOD, a private cgroup namespace,
# tmpfs /run, /run/lock and /tmp. No device, no host path. <mask> is a list of unit names, masked before systemd starts.
gf_container_systemd_start() { # <image> <units to mask>
  local image=$1 mask=$2 script
  read -r -d '' script <<'EOS'
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

gf_container_exec() { # <id> <command...>: in a container made by gf_container_systemd_start, with the proxy variables
  local id=$1 envs=() v
  shift
  for v in "${GF_PROXY_VARS[@]}"; do
    [[ -n ${!v:-} ]] && envs+=(-e "$v")
  done
  docker exec "${envs[@]}" "$id" "$@"
}
