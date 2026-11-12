#!/usr/bin/env bash
# The RUN-TIME boundary of tests/integration/container.sh, with a STUB docker: every refusal must fire before docker is called.
# The image is the first argument and pinned by digest, exec runs only in the container the wrapper started, a mount source is
# checked against a short list, the globals cannot be changed from the environment or reassigned, the network is the default one
# unless a proxy sits on the host's loopback, an Omarchy tree is staged as regular files only and its stage is removed.
# docker is a stub that records its arguments: no container starts, anywhere. Layer: logic (no root, no session, no docker).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
W=$(mktemp -d)
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
expect() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1: got '$2', want '$3'"; fi; }
has() { if [[ $2 == *"$3"* ]]; then pass "$1"; else fail "$1: '$3' not in '$2'"; fi; }
hasnt() { if [[ $2 == *"$3"* ]]; then fail "$1: '$3' found in '$2'"; else pass "$1"; fi; }

mkdir -p "$W/bin" "$W/home"
cat >"$W/bin/docker" <<'EOF'
#!/bin/bash
echo "call: $*" >>"$GF_STUB/calls"
[[ $1 == run && " $* " == *" -d "* ]] && echo abc123
exit 0
EOF
chmod +x "$W/bin/docker"
IMG=archlinux:base@sha256:$(printf 'a%.0s' {1..64})

# t <snippet> [env assignments...]: the wrapper sourced in a fresh shell with the stub docker; prints the snippet's output,
# then sets rc and calls (what docker was asked)
t() {
  : >"$W/calls"
  out=$(env -i PATH="$W/bin:$PATH" HOME="$W/home" GF_STUB="$W" TMPDIR=/tmp "${@:2}" bash -c ". '$root/tests/integration/container.sh' && gf_container_init '$root' && $1" 2>&1)
  rc=$?
  calls=$(cat "$W/calls")
}

# --- the image: the first argument, pinned, before docker ---
t "gf_container_run --privileged '$IMG' true"
expect 'an option in place of the image: refused (2)' "$rc" 2
expect 'an option in place of the image: docker not called' "$calls" ''
t "gf_container_run -v/dev:/dev '$IMG' true"
expect 'a mount in place of the image: refused' "$rc" 2
expect 'a mount in place of the image: docker not called' "$calls" ''
t "gf_container_run archlinux:base true"
expect 'an image without a digest: refused' "$rc" 2
expect 'an image without a digest: docker not called' "$calls" ''
t "gf_container_run archlinux@sha256:abc true"
expect 'a short digest: refused' "$rc" 2
expect 'a short digest: docker not called' "$calls" ''
t "gf_container_run '' true"
expect 'no image: refused' "$rc" 2
expect 'no image: docker not called' "$calls" ''
t "gf_container_run 'img@sha256:$(printf 'a%.0s' {1..64}) --privileged' true"
expect 'an image with an option glued on: refused' "$rc" 2
expect 'an image with an option glued on: docker not called' "$calls" ''
t "gf_standard none && gf_container_run '$IMG' echo hi"
expect 'a pinned image: runs (0)' "$rc" 0
has 'a pinned image: docker run --rm' "$calls" 'run --rm'
has 'a pinned image: the repository read-only at /src' "$calls" "-v $root:/src:ro"
has 'a pinned image: no network' "$calls" '--network none'
hasnt 'a pinned image: no --privileged' "$calls" '--privileged'
hasnt 'a pinned image: no device' "$calls" '--device'
expect 'a pinned image: docker was called once' "$(wc -l <"$W/calls")" 1
t "gf_container_systemd_start --privileged 'a b'"
expect 'systemd start: an option as the image: refused' "$rc" 2
expect 'systemd start: an option as the image: docker not called' "$calls" ''
t "gf_container_systemd_start archlinux:base 'a b'"
expect 'systemd start: an unpinned image: refused' "$rc" 2
expect 'systemd start: an unpinned image: docker not called' "$calls" ''
t "gf_container_systemd_start '$IMG' 'a.service b.mount' >/dev/null && echo \"cid=\$gf_cid\""
has 'systemd start: the container id is kept' "$out" 'cid=abc123'
has 'systemd start: CAP_SYS_ADMIN minus MKNOD' "$calls" '--cap-add SYS_ADMIN --cap-drop MKNOD'
has 'systemd start: a private cgroup namespace' "$calls" '--cgroupns=private'
hasnt 'systemd start: no --privileged' "$calls" '--privileged'
hasnt 'systemd start: no device' "$calls" '--device'
hasnt 'systemd start: no host path' "$calls" '-v /'

# --- exec: only in the container the wrapper started ---
t "gf_container_exec abc123 ls"
expect 'exec before any start: refused' "$rc" 2
expect 'exec before any start: docker not called' "$calls" ''
t "gf_container_systemd_start '$IMG' x >/dev/null; : >'$W/calls'; gf_container_exec someone-elses-container ls"
expect 'exec in another container: refused' "$rc" 2
expect 'exec in another container: no exec call' "$calls" ''
t "gf_container_systemd_start '$IMG' x >/dev/null; : >'$W/calls'; gf_container_exec abc123 ls -l"
expect 'exec in the started container: runs (0)' "$rc" 0
has 'exec in the started container: docker exec' "$calls" 'exec abc123 ls -l'
t "gf_container_systemd_start '$IMG' x >/dev/null; : >'$W/calls'; gf_container_exec --privileged ls"
expect 'exec with an option as the id: refused' "$rc" 2
expect 'exec with an option as the id: no call' "$calls" ''

# --- mounts: refused before they reach a docker argument ---
mkdir -p "$W/home/.ssh" "$W/outside"
: >"$W/home/.ssh/id.pem"
: >"$W/outside/ca.pem"
for src in / /dev /proc /sys /run /boot /root "$W/home/.ssh/id.pem" /etc/passwd "$W/outside/ca.pem" /usr; do
  t "gf_mount '$src' /x ro; echo \"args=\${gf_args[*]}\""
  has "mount $src read-only: refused" "$out" 'args='
  hasnt "mount $src read-only: nothing added" "$out" '-v '
done
for src in / /tmp /run /run/user "$root/.dev" /dev "$W/home/.ssh" "$root"; do
  t "gf_mount '$src' /x rw; echo \"args=\${gf_args[*]}\""
  hasnt "mount $src read-write: nothing added" "$out" '-v '
done
t "gf_mount '$root' /src ro && gf_mount '$root/.dev' /dev-stage ro && echo \"args=\${gf_args[*]}\""
has 'the repository and its .dev/ read-only: accepted' "$out" "-v $root:/src:ro"
rw=$(mktemp -d /tmp/container-wrapper.XXXXXX)
t "gf_mount '$rw' /out rw && echo \"args=\${gf_args[*]}\""
has 'a folder of the caller own under /tmp read-write: accepted' "$out" "-v $rw:/out:rw"
rm -rf "$rw"
t "gf_mount '$root' /x ro" TMPDIR=/run/user
expect 'TMPDIR=/run/user changes nothing (the repository is still fine)' "$rc" 0
mkdir -p "$root/.dev" && cp "$W/outside/ca.pem" "$root/.dev/container-wrapper-test-ca.pem"
t "gf_mount '$root/.dev/container-wrapper-test-ca.pem' /ca ro && echo \"args=\${gf_args[*]}\""
has 'a CA bundle under .dev/: accepted' "$out" '/ca:ro'
rm -f "$root/.dev/container-wrapper-test-ca.pem"

t "gf_standard none && echo \"args=\${gf_args[*]}\""
has 'a tree owned by another user: git is told by its own variables' "$out" 'GIT_CONFIG_KEY_0=safe.directory'

# --- the globals ---
t 'echo "root=$GF_ROOT"' GF_ROOT=/
has 'GF_ROOT=/ in the environment is ignored' "$out" "root=$root"
t '(GF_ROOT=/) 2>&1; echo "after=$GF_ROOT"'
has 'GF_ROOT cannot be reassigned' "$out" "after=$root"
t '(GF_PROXY_VARS=()) 2>&1; echo "n=${#GF_PROXY_VARS[@]}"'
has 'GF_PROXY_VARS cannot be reassigned' "$out" 'n=6'
t "gf_container_init /"
expect 'init for another repository: refused' "$rc" 1

# --- the network ---
t 'gf_network auto; echo "args=${gf_args[*]}"' NO_PROXY=example.com no_proxy=example.com
hasnt 'NO_PROXY alone does not choose the host network' "$out" '--network host'
t 'gf_network auto; echo "args=${gf_args[*]}"' HTTPS_PROXY=http://proxy.example:3128
hasnt 'a proxy on another host: the default network' "$out" '--network host'
t 'gf_network auto; echo "args=${gf_args[*]}"' HTTPS_PROXY=http://127.0.0.1:3128
has 'a proxy on the loopback: the host network' "$out" '--network host'
t 'gf_network auto; echo "args=${gf_args[*]}"' http_proxy=http://localhost:8080
has 'a lower-case proxy on localhost: the host network' "$out" '--network host'
t 'gf_network auto; echo "args=${gf_args[*]}"'
hasnt 'no proxy: the default network' "$out" '--network'
t 'gf_network host'
expect 'a network mode that is not auto or none: refused' "$rc" 1

# --- an Omarchy tree: regular files only, a stage of its own, removed afterwards ---
mkdir -p "$W/tree/bin" "$W/tree/migrations"
echo '#!/bin/sh' >"$W/tree/bin/omarchy-ok"
chmod +x "$W/tree/bin/omarchy-ok"
ln -s /etc/passwd "$W/tree/bin/omarchy-link-out"
before=$(ls -d "$root"/.dev/omarchy-stage.* 2>/dev/null | wc -l)
t "omarchy_mounts '$W/tree' /omarchy; echo \"rc=\$? args=\${gf_args[*]}\""
has 'a link that ends outside the tree and /usr: refused' "$out" 'ends in /etc/passwd'
hasnt 'a refused tree adds no mount' "$out" '-v '
expect 'the stage of a refused tree is removed at exit' "$(ls -d "$root"/.dev/omarchy-stage.* 2>/dev/null | wc -l)" "$before"
rm "$W/tree/bin/omarchy-link-out"
mkfifo "$W/tree/bin/omarchy-fifo"
t "omarchy_mounts '$W/tree' /omarchy; echo \"rc=\$?\""
has 'a FIFO in bin/: refused' "$out" 'not a regular file'
rm "$W/tree/bin/omarchy-fifo"
ln -s /usr/bin/true "$W/tree/bin/omarchy-usr"
ln -s /nonexistent/x "$W/tree/bin/omarchy-dangling"
t "omarchy_mounts '$W/tree' /omarchy && echo \"args=\${gf_args[*]}\""
has 'regular files and a link into /usr/bin: accepted, the tree read-only' "$out" "-v $W/tree:/omarchy:ro"
has 'the staged bin/ is mounted over the tree' "$out" ":/omarchy/bin:ro"
has 'a dangling link is left out, with a word' "$out" 'dangling'
expect 'the stage is removed at exit' "$(ls -d "$root"/.dev/omarchy-stage.* 2>/dev/null | wc -l)" "$before"
t "omarchy_mounts / /omarchy"
expect 'a tree that is the whole machine: refused' "$rc" 1

# --- a git worktree: the common git folder, read-only, at the same path ---
if [[ -f $root/.git ]]; then
  common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)
  t "gf_standard none && echo \"args=\${gf_args[*]}\""
  has 'a worktree: its common git folder read-only at the same path' "$out" "-v $common:$common:ro"
else
  echo "  note this checkout is not a worktree: the git-folder mount is not exercised"
fi

((fails == 0)) && echo "PASS: container wrapper run-time boundary" || { echo "FAIL: container wrapper run-time boundary ($fails)"; exit 1; }
