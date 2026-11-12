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
  out=$(env -i PATH="$W/bin:$PATH" HOME="$W/home" GF_STUB="$W" TMPDIR="${TMPDIR:-/tmp}" "${@:2}" bash -c ". '$root/tests/integration/container.sh' && gf_container_init '$root' && $1" 2>&1)
  rc=$?
  calls=$(cat "$W/calls")
}

# --- the image: the first argument, pinned, before docker ---
t "gf_container_run --privileged '$IMG' true"
expect 'an option in place of the image: refused (2)' "$rc" 2
expect 'an option in place of the image: the engine was not called' "$calls" ''
t "gf_container_run -v/dev:/dev '$IMG' true"
expect 'a mount in place of the image: refused' "$rc" 2
expect 'a mount in place of the image: the engine was not called' "$calls" ''
t "gf_container_run archlinux:base true"
expect 'an image without a digest: refused' "$rc" 2
expect 'an image without a digest: the engine was not called' "$calls" ''
t "gf_container_run archlinux@sha256:abc true"
expect 'a short digest: refused' "$rc" 2
expect 'a short digest: the engine was not called' "$calls" ''
t "gf_container_run '' true"
expect 'no image: refused' "$rc" 2
expect 'no image: the engine was not called' "$calls" ''
t "gf_container_run 'img@sha256:$(printf 'a%.0s' {1..64}) --privileged' true"
expect 'an image with an option glued on: refused' "$rc" 2
expect 'an image with an option glued on: the engine was not called' "$calls" ''
t "gf_standard none && gf_container_run '$IMG' echo hi"
expect 'a pinned image: runs (0)' "$rc" 0
has 'a pinned image: run --rm' "$calls" 'run --rm'
has 'a pinned image: the repository read-only at /src' "$calls" "-v $root:/src:ro"
has 'a pinned image: no network' "$calls" '--network none'
hasnt 'a pinned image: no --privileged' "$calls" '--privileged'
hasnt 'a pinned image: no device' "$calls" '--device'
expect 'a pinned image: the engine was called once' "$(wc -l <"$W/calls")" 1
t "gf_container_systemd_start --privileged 'a b'"
expect 'systemd start: an option as the image: refused' "$rc" 2
expect 'systemd start: an option as the image: the engine was not called' "$calls" ''
t "gf_container_systemd_start archlinux:base 'a b'"
expect 'systemd start: an unpinned image: refused' "$rc" 2
expect 'systemd start: an unpinned image: the engine was not called' "$calls" ''
t "gf_container_systemd_start '$IMG' 'a.service b.mount' >/dev/null && echo \"cid=\$gf_cid\""
has 'systemd start: the container id is kept' "$out" 'cid=abc123'
has 'systemd start: CAP_SYS_ADMIN minus MKNOD' "$calls" '--cap-add SYS_ADMIN --cap-drop MKNOD'
has 'systemd start: a private cgroup namespace' "$calls" '--cgroupns=private'
hasnt 'systemd start: no --privileged' "$calls" '--privileged'
hasnt 'systemd start: no device' "$calls" '--device'
hasnt 'systemd start: no host path' "$calls" '-v /'

# SYS_ADMIN belongs to the systemd container alone: gf_args is cleared right after its run, so a later run never carries it
t "gf_container_systemd_start '$IMG' x >/dev/null; echo \"left=\${#gf_args[@]}\"; : >'$W/calls'; gf_standard none && gf_container_run '$IMG' true"
has 'after the systemd start the options are empty' "$out" 'left=0'
hasnt 'a later run does not carry SYS_ADMIN' "$calls" 'SYS_ADMIN'

# --- exec: only in the container the wrapper started ---
t "gf_container_exec abc123 ls"
expect 'exec before any start: refused' "$rc" 2
expect 'exec before any start: the engine was not called' "$calls" ''
t "gf_container_systemd_start '$IMG' x >/dev/null; : >'$W/calls'; gf_container_exec someone-elses-container ls"
expect 'exec in another container: refused' "$rc" 2
expect 'exec in another container: no exec call' "$calls" ''
t "gf_container_systemd_start '$IMG' x >/dev/null; : >'$W/calls'; gf_container_exec abc123 ls -l"
expect 'exec in the started container: runs (0)' "$rc" 0
has 'exec in the started container: exec' "$calls" 'exec abc123 ls -l'
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
# the caller's temporary folder ($TMPDIR, inside /tmp in an agent's sandbox; /tmp otherwise): one level only
rw=$(mktemp -d "${TMPDIR:-/tmp}/container-wrapper.XXXXXX")
t "gf_mount '$rw' /out rw && echo \"args=\${gf_args[*]}\""
has 'a folder of the caller own directly under the temporary folder, read-write: accepted' "$out" "-v $rw:/out:rw"
mkdir "$rw/sub"
t "gf_mount '$rw/sub' /out rw; echo \"args=\${gf_args[*]}\""
hasnt 'a folder two levels under the temporary folder, read-write: refused' "$out" "-v $rw/sub"
t "gf_mount '$rw' /out rw; echo \"args=\${gf_args[*]}\"" TMPDIR=/run/user
expect 'TMPDIR=/run/user does not become the base of the one-level rule (a folder under it is still not accepted)' "$(grep -c -- "-v $rw:/out:rw" <<<"$out")" "$([[ $(dirname "$rw") == /tmp ]] && echo 1 || echo 0)"
rm -rf "$rw"
t "gf_mount '$root' /x ro" TMPDIR=/run/user
expect 'TMPDIR=/run/user changes nothing (the repository is still fine)' "$rc" 0
mkdir -p "$root/.dev" && cp "$W/outside/ca.pem" "$root/.dev/container-wrapper-test-ca.pem"
t "gf_mount '$root/.dev/container-wrapper-test-ca.pem' /ca ro && echo \"args=\${gf_args[*]}\""
has 'a CA bundle under .dev/: accepted' "$out" '/ca:ro'
rm -f "$root/.dev/container-wrapper-test-ca.pem"

t "gf_standard none && echo \"args=\${gf_args[*]}\""
has 'a tree owned by another user: git is told by its own variables' "$out" 'GIT_CONFIG_KEY_0=safe.directory'

# a source that CONTAINS a forbidden folder is refused too (a mount of ~ or ~/.local would carry ~/.ssh or the keyrings along).
# The fake home is under the repository's .dev/, which the allowlist ACCEPTS: so each refusal below comes from gf_forbidden.
fh="$root/.dev/wrapper-test-home.$$"
mkdir -p "$fh/.ssh" "$fh/.local/share/keyrings" "$fh/.local/bin" "$fh/plain/inner"
t "gf_mount '$fh/plain' /x ro && echo accepted-control" HOME="$fh"
has 'control: a folder under .dev/ with no secret folder is accepted by the allowlist' "$out" 'accepted-control'
for src in "$fh" "$fh/.local" "$fh/.local/share" "$fh/.ssh" "$fh/.local/share/keyrings"; do
  t "gf_mount '$src' /x ro; echo \"args=\${gf_args[*]}\"" HOME="$fh"
  has "mount ${src#$root/} (is, is inside or contains a secret folder): refused by gf_forbidden" "$out" 'may not mount'
done
t "gf_mount '/home' /x ro; echo \"args=\${gf_args[*]}\"" HOME="$fh"
hasnt 'mount /home: nothing added' "$out" '-v '
t "omarchy_mounts '$fh/.local' /omarchy; echo \"rc=\$?\"" HOME="$fh"
has 'an Omarchy tree that is ~/.local (it has a bin/): refused by gf_forbidden' "$out" 'may not mount'
rm -rf "$fh"
# a .dev that links out of the repository widens nothing: the wrapper (a copy in a fake repository) refuses to start
mkdir -p "$W/fake/tests/integration" "$W/etc-like"
cp "$root/tests/integration/container.sh" "$W/fake/tests/integration/container.sh"
ln -s "$W/etc-like" "$W/fake/.dev"
fout=$(env -i PATH="$W/bin:$PATH" HOME="$W/home" bash -c ". '$W/fake/tests/integration/container.sh' && gf_container_init '$W/fake'; echo rc=\$?" 2>&1)
has 'a .dev that is a link out of the repository: init refuses' "$fout" 'rc=1'
t "gf_container_init '$root'; gf_mount '$root/.dev' /dev-stage ro && echo ok-mounted"
has 'the real .dev is accepted' "$out" 'ok-mounted'
# every docker run line carries NET_RAW's drop itself, a second run without init included
t "gf_standard none && gf_container_run '$IMG' true"
has 'a run drops NET_RAW' "$calls" '--cap-drop NET_RAW'
t "gf_standard none && gf_container_run '$IMG' true; : >'$W/calls'; gf_standard none && gf_container_run '$IMG' true"
has 'a second run without gf_container_init still drops NET_RAW' "$calls" '--cap-drop NET_RAW'
t "gf_standard none && gf_container_run '$IMG' true; : >'$W/calls'; gf_container_run '$IMG' true"
has 'a run with no options at all still drops NET_RAW' "$calls" '--cap-drop NET_RAW'
t "gf_container_systemd_start '$IMG' x >/dev/null; : >'$W/calls'; gf_container_systemd_start '$IMG' y >/dev/null"
has 'a second systemd start without init still drops NET_RAW' "$calls" '--cap-drop NET_RAW'
t "gf_standard none && gf_container_run '$IMG' true; echo \"after=\${#gf_args[@]}\""
has 'the options are emptied after a run' "$out" 'after=0'

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
