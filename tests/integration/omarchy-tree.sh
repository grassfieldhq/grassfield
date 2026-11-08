# shellcheck shell=bash
# Docker mounts of an Omarchy tree for the throwaway-container tests (software_update, store_helper, update_helper,
# update_migrate). From Omarchy 4.0.6 on, the tree's bin/ holds absolute links to /usr/bin, which do not resolve inside a
# container (the 2026-11-08 runs on Omarchy 4.5.0-3: "cp: cannot stat '/omarchy/bin/omarchy-migrate'"). The tree is
# mounted read-only as it is, and bin/ is staged with its links followed and mounted over it.
#
# omarchy_mounts <tree> <stage dir> <mount point> <array name>: appends the two -v arguments to the named array.
# Returns 1 when the tree has no bin/ or a file cannot be copied; a dangling link is left out.
omarchy_mounts() {
  local tree stage=$2 point=$3 f
  local -n omarchy_mounts_args=$4
  tree=$(realpath "$1") && [[ -d $tree/bin ]] || { echo "omarchy_mounts: no bin/ in ${1:-?}" >&2; return 1; }
  case $stage in */.dev/*) ;; *) echo "omarchy_mounts: the stage must be under a .dev/ folder ($stage)" >&2; return 1 ;; esac
  rm -rf "$stage" && mkdir -p "$stage/bin" || return 1
  for f in "$tree"/bin/*; do
    [[ -e $f ]] || continue
    cp -L --preserve=mode "$f" "$stage/bin/" || { echo "omarchy_mounts: cannot copy $f" >&2; return 1; }
  done
  omarchy_mounts_args+=(-v "$tree:$point:ro" -v "$stage/bin:$point/bin:ro")
}
