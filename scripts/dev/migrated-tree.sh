#!/usr/bin/env bash
# The packaged form of the UI tree for a development run (ADR-0056): scripts/dev/migrate-qs-imports.py applied to a copy of
# <root>/shell, made once per content of the sources and of the script.
#
#   scripts/dev/migrated-tree.sh ROOT DEV      prints the tree stamp (16 hex digits) and leaves DEV/migrated -> DEV/migrated-<stamp>
#
# Rules (review of #37, MEDIUM-1):
#   * a tree a process may be using is NEVER deleted or rewritten: a new content is built in a fresh directory
#     (DEV/migrated-<stamp>, made under a temporary name and moved into place) and DEV/migrated is pointed at it with one atomic
#     rename; the previous tree stays, older ones are removed;
#   * the stamp names the content, so the caller can compare it with the one a long-lived process (the security process) was
#     started with, and restart that process on purpose when it differs;
#   * a made tree is verified against the source (--verify) before it is used; a failure leaves nothing behind.
# The parents of shell/ that dev code reaches (../VERSION, ../packaging, ../branding, ../.dev) are links to ROOT inside it.
set -euo pipefail
root=${1:?root}
dev=${2:?dev dir}
mkdir -p "$dev"
tool=$root/scripts/dev/migrate-qs-imports.py
stamp=$({ (cd "$root/shell" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum); sha256sum "$tool" | cut -d' ' -f1; } | sha256sum | cut -c1-16)
real=$dev/migrated-$stamp
if [[ ! -f $real/.stamp ]]; then
  tmpb=$dev/.migrated-build.$$
  rm -rf "$tmpb"
  mkdir -p "$tmpb"
  if ! python3 -I "$tool" --src "$root/shell" --out "$tmpb/shell" >&2 || ! python3 -I "$tool" --src "$root/shell" --verify "$tmpb/shell" >&2; then
    rm -rf "$tmpb"
    echo "migrated-tree: the migrated tree did not build or is not the source apart from its imports" >&2
    exit 1
  fi
  for e in "$root"/* "$root"/.dev; do
    [[ $(basename "$e") == shell ]] && continue
    [[ -e $e ]] && ln -s "$e" "$tmpb/$(basename "$e")"
  done
  touch "$tmpb/.stamp"
  rm -rf "$real" # only a leftover without a stamp (a build that was cut short), never a tree that has one
  mv "$tmpb" "$real"
fi
prev=""
[[ -L $dev/migrated ]] && prev=$(readlink "$dev/migrated")
# A real directory from the first version of this script is moved aside, not deleted (a process may still run from it).
if [[ -d $dev/migrated && ! -L $dev/migrated ]]; then
  mv "$dev/migrated" "$dev/migrated-legacy"
fi
ln -sfn "$real" "$dev/migrated.new.$$"
mv -T "$dev/migrated.new.$$" "$dev/migrated"
# Keep the new tree and the one before it; remove the others.
for d in "$dev"/migrated-*; do
  [[ -d $d ]] || continue
  [[ $d == "$real" || $d == "$prev" || $d == "$dev/migrated-legacy" ]] && continue
  rm -rf "$d"
done
printf '%s\n' "$stamp"
