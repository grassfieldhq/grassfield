#!/usr/bin/env bash
# The packaged form of the UI tree for a development run (ADR-0056): scripts/dev/migrate-qs-imports.py applied to a copy of
# <root>/shell, made once per content of the sources and of the script.
#
#   scripts/dev/migrated-tree.sh ROOT DEV      prints the tree stamp (16 hex digits); DEV/migrated -> DEV/migrated-<stamp>
#
# Rules (reviews of #37):
#   * Start and address a process through the REAL path of the tree (DEV/migrated-<stamp>, from the stamp this script prints),
#     never through the link: Quickshell keeps the literal path it was given (shellDir, the Path ID, every relative load), so a
#     process started through the link would load a file it opens late (a Loader, a createComponent) from whatever tree the link
#     points to by then. A process started on the real path of tree A keeps loading from A after the link moves to B
#     (tests/shell/migrated_tree.sh shows it). The link is for humans and for finding the current tree.
#   * A tree is never deleted or rewritten once it has a `.stamp`: a new content is built in a fresh directory, made under a
#     temporary name and moved into place, and the link is repointed with one atomic rename. The previous tree stays, older
#     ones go; a process that outlives two swaps has lost its tree, so a changed stamp restarts the security process on purpose
#     (security_sig in shell-run.sh).
#   * The stamp is computed from a SNAPSHOT of the sources taken first, and the tree is built from that snapshot, so an edit made
#     while this runs cannot mislabel a tree. The script that runs is the snapshot's copy.
#   * Runs are serialised with flock (two concurrent runs build once and never delete each other's tree).
#   * A tree that is reused is verified against the source again (--verify), a made one before it is used; a source with a
#     symlink is refused (migrate-qs-imports.py).
# The parents of shell/ that dev code reaches (../VERSION, ../packaging, ../branding, ../.dev) are links to ROOT inside it.
set -euo pipefail
root=${1:?root}
dev=${2:?dev dir}
mkdir -p "$dev"
exec 9>"$dev/.migrated-tree.lock"
flock 9

snap=$dev/.migrated-snap.$$
tmpb=$dev/.migrated-build.$$
trap 'rm -rf "$snap" "$tmpb"' EXIT
rm -rf "$snap" "$tmpb"
mkdir -p "$snap/scripts/dev"
cp -a "$root/shell" "$snap/shell"
cp -a "$root/scripts/dev/migrate-qs-imports.py" "$snap/scripts/dev/migrate-qs-imports.py"
tool=$snap/scripts/dev/migrate-qs-imports.py
stamp=$({ (cd "$snap/shell" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum); sha256sum "$tool" | cut -d' ' -f1; } | sha256sum | cut -c1-16)
real=$dev/migrated-$stamp

if [[ -f $real/.stamp ]]; then
  # A tree that is already there is never touched; it is checked against the snapshot, cheaply.
  python3 -I "$tool" --src "$snap/shell" --verify "$real/shell" >&2 \
    || { echo "migrated-tree: $real is not the source apart from its imports (remove it by hand once no process uses it)" >&2; exit 1; }
else
  mkdir -p "$tmpb"
  if ! python3 -I "$tool" --src "$snap/shell" --out "$tmpb/shell" >&2 || ! python3 -I "$tool" --src "$snap/shell" --verify "$tmpb/shell" >&2; then
    echo "migrated-tree: the migrated tree did not build or is not the source apart from its imports" >&2
    exit 1
  fi
  for e in "$root"/* "$root"/.dev; do
    [[ $(basename "$e") == shell ]] && continue
    [[ -e $e ]] && ln -s "$e" "$tmpb/$(basename "$e")"
  done
  touch "$tmpb/.stamp"
  # Only a leftover without a stamp (a build cut short) may be replaced; a directory that has a stamp is never deleted.
  [[ -e $real && ! -f $real/.stamp ]] && rm -rf "$real"
  mv "$tmpb" "$real"
fi

prev=""
[[ -L $dev/migrated ]] && prev=$(readlink "$dev/migrated")
if [[ $prev == "$real" ]]; then
  # Nothing to swap: a run on the content that is already current changes and prunes nothing (it must not make the tree before
  # it, which a process may still run from, the "older one" of a later cleanup).
  printf '%s\n' "$stamp"
  exit 0
fi
# A real directory from the first version of this script is moved aside, not deleted (a process may still run from it).
if [[ -d $dev/migrated && ! -L $dev/migrated ]]; then
  mv "$dev/migrated" "$dev/migrated-legacy"
fi
ln -sfn "$real" "$dev/migrated.new.$$"
mv -T "$dev/migrated.new.$$" "$dev/migrated"
# Keep the new tree and the one before it; remove the others, never one that is not stamped-and-old: a directory without a
# stamp is another run's build in progress or a leftover (the lock makes the first impossible here), and legacy is kept.
for d in "$dev"/migrated-*; do
  [[ -d $d ]] || continue
  [[ $d == "$real" || $d == "$prev" || $d == "$dev/migrated-legacy" ]] && continue
  [[ -f $d/.stamp ]] || continue
  rm -rf "$d"
done
printf '%s\n' "$stamp"
