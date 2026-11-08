# shellcheck shell=bash
# The bounds of grassfield-hold (ADR-0041 step 2a, SQ-3 option A), computed from the build's own record and never typed.
# Sourced by packaging/arch/PKGBUILD (package_grassfield-hold) and installed as /usr/lib/grassfield/grassfield-hold-bounds.sh
# (not executable) for grassfield-channel-set's `hold-state`. Nothing here runs as root and nothing writes.
#
# The record is BUILD-DEPS (ADR-0033 s3.4): one `<name> <version>` per line, written by PKGBUILD's prepare() from
# `pacman -Q`. The hold bounds exactly two of its packages, with the same rule as the update helper's compatibility check
# (docs/specs/updates.md U27, compare_key in packaging/pacman/grassfield-update-helper):
#   quickshell   the whole version, without its pkgrel:  quickshell=<version>
#   qt6-base     major.minor:                            qt6-base>=<major>.<minor> and qt6-base<<major>.<minor + 1>
# Never hyprland (ADR-0009: degraded mode and the rebuild) and never kcoreaddons (KF6 releases monthly with a public ABI).
# An epoch is kept (`1:6.12` and `1:6.13`). A record that lacks one of the two, or whose version this cannot read, gives no
# bound at all (return 1): the build fails, it never ships a hold that holds nothing.

GF_HOLD_NAME_RE='^[a-z0-9@_+][a-z0-9@._+-]*$'
GF_HOLD_VERSION_RE='^[A-Za-z0-9:._+~-]+$'

# The record's version of package $2 in the file $1 (the last line naming it); fails when there is none or it is malformed.
gf_hold_recorded() {
  local file=$1 want=$2 name version extra found=''
  [[ -f $file && ! -L $file ]] || return 1
  while read -r name version extra; do
    [[ $name == "$want" && $name =~ $GF_HOLD_NAME_RE && $version =~ $GF_HOLD_VERSION_RE && -z $extra ]] && found=$version
  done < <(head -c 4096 -- "$file")
  [[ -n $found ]] || return 1
  printf '%s\n' "$found"
}

# [epoch:]MAJOR.MINOR of a version (U27's key for Qt); fails when it has no major.minor.
gf_hold_minor() {
  [[ ${1%-*} =~ ^([0-9]+:)?([0-9]+)\.([0-9]+) ]] || return 1
  printf '%s%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$((10#${BASH_REMATCH[3]}))"
}

# The same, one minor later (the first Qt that is out of bounds).
gf_hold_next_minor() {
  [[ ${1%-*} =~ ^([0-9]+:)?([0-9]+)\.([0-9]+) ]] || return 1
  printf '%s%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$((10#${BASH_REMATCH[3]} + 1))"
}

# quickshell's version without its pkgrel (U27: Quickshell by its whole version).
gf_hold_quickshell() {
  local v=${1%-*}
  [[ -n $v && $v =~ $GF_HOLD_VERSION_RE ]] || return 1
  printf '%s\n' "$v"
}

# The three `depends` entries of grassfield-hold, one per line, from the record file $1.
gf_hold_depends() {
  local qs qt min next
  qs=$(gf_hold_recorded "$1" quickshell) && qs=$(gf_hold_quickshell "$qs") || return 1
  qt=$(gf_hold_recorded "$1" qt6-base) && min=$(gf_hold_minor "$qt") && next=$(gf_hold_next_minor "$qt") || return 1
  printf '%s\n' "quickshell=$qs" "qt6-base>=$min" "qt6-base<$next"
}

# Whether installed quickshell $2 and qt6-base $3 are inside the bounds of the record file $1 (0 yes, 1 no or unreadable).
gf_hold_allows() {
  local want_qs want_qt have_qs have_qt
  want_qs=$(gf_hold_recorded "$1" quickshell) && want_qs=$(gf_hold_quickshell "$want_qs") || return 1
  want_qt=$(gf_hold_recorded "$1" qt6-base) && want_qt=$(gf_hold_minor "$want_qt") || return 1
  have_qs=$(gf_hold_quickshell "$2") && have_qt=$(gf_hold_minor "$3") || return 1
  [[ $have_qs == "$want_qs" && $have_qt == "$want_qt" ]]
}
