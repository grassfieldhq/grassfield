# shellcheck shell=bash
# Shared code of Grassfield's two root programs (ADR-0033 c.1; docs/specs/updates.md U16). OPUS SECURITY REVIEW REQUIRED.
#   /usr/lib/grassfield/grassfield-channel-helper     run by pkexec (polkit action org.grassfield.packages.set-channel)
#   /usr/lib/grassfield/grassfield-channel-scriptlet  run by grassfield-desktop's pacman scriptlets
# Installed as /usr/lib/grassfield/grassfield-channel.sh (not executable) and sourced only by them, after they replaced
# their environment (gf_start). The only input is the argument vector they checked.
#
# What it writes, and nothing else:
#   - the two lines at the end of /etc/pacman.conf: "[grassfield]" and "Include = /etc/pacman.d/grassfield.conf";
#   - /etc/pacman.d/grassfield.conf, copied from a root-owned packaged template (/usr/share/grassfield/pacman/
#     grassfield-<channel>.conf, generated at build time from packaging/pacman/repository.conf);
#   - pacman's synced [grassfield] files (<DBPath>/sync/grassfield.{db,files}{,.sig}): removed by the helper's verbs, only
#     their time set to the epoch by the package scriptlet (ADR-0050 2: never deleted inside a transaction);
#   - the staged rollout's wariness, /var/lib/grassfield/rollout-wariness (ADR-0050 1);
#   - the Grassfield keys in pacman's keyring (pacman-key --add/--lsign-key of the pinned key, --populate-from the
#     private keyring folder of grassfield-keyring, --delete).
# The lines go last, after the last repository of Omarchy's channel templates (default/pacman/pacman-stable.conf ends
# with [omarchy] in 4.0.4 and [multilib] in 4.0.6; ADR-0033 a.1-a.2, Q4), so [grassfield] never shadows a package of theirs.
# Every write to /etc goes through a temporary file in the same folder and a rename (mode and owner kept), so pacman never
# reads a half-written file. The lines are added after the file exists and removed before the file goes: pacman never
# sees an Include whose file is missing (P2: that stops every pacman command). No network, no package installed,
# nothing written in a user's home.

GF_PACMAN_CONF=/etc/pacman.conf
GF_CONF=/etc/pacman.d/grassfield.conf
GF_INCLUDE="Include = $GF_CONF"
GF_DATA=/usr/share/grassfield/pacman
GF_KEYRING=/usr/share/grassfield/pacman-keyring
GF_VERSION_FILE=/usr/share/grassfield/VERSION

gf_fail() {
  echo "${GF_PROG:-grassfield-channel}: $*" >&2
  exit 1
}

# Called first by both programs (their environment is already empty): a fixed PATH, locale, umask and directory.
gf_start() {
  export PATH=/usr/bin LC_ALL=C
  IFS=$' \t\n'
  umask 022
  set -uo pipefail
  cd / || exit 1
  ((EUID == 0)) || gf_fail "must run as root"
  gf_load
  gf_paths
}

# One change at a time: the helper can start just before a pacman transaction whose scriptlet runs the other program, and
# two rewrites of pacman.conf could lose one another (lines left without their file). Both take a lock only root can
# open: flock needs no write access, so a lock others can read could be held by any local user and would block
# "Turn Off…" and the removal (review of 0338116, MAJOR 1). /run/grassfield (root, 0700) and its channel.lock (root,
# 0600) are made under umask 077 and checked before use. The kernel drops the lock when its holder dies. The helper
# refuses when it is held; the scriptlet waits (pacman's transaction must not fail for it). A root without /run (a
# chroot) has no other program to race with: the scriptlet then goes on unlocked. Once the lock is held, temporary files
# a killed run left in /etc are removed.
GF_LOCK_DIR=/run/grassfield
GF_LOCK=$GF_LOCK_DIR/channel.lock
gf_lock() { # seconds to wait (0: refuse at once)
  if [[ ! -d /run ]]; then
    (($1 > 0)) || gf_fail "no /run: cannot take $GF_LOCK"
  else
    (umask 077 && mkdir -p -- "$GF_LOCK_DIR" && : >>"$GF_LOCK") || gf_fail "cannot create $GF_LOCK"
    [[ -d $GF_LOCK_DIR && ! -L $GF_LOCK_DIR && $(stat -c %u:%a -- "$GF_LOCK_DIR") == 0:700 && -f $GF_LOCK &&
      ! -L $GF_LOCK && $(stat -c %u:%a -- "$GF_LOCK") == 0:600 ]] ||
      gf_fail "$GF_LOCK_DIR (0700) or $GF_LOCK (0600) is not root's own: refused"
    exec 9<"$GF_LOCK" || gf_fail "cannot open $GF_LOCK"
    if (($1 == 0)); then
      flock -n 9 || gf_fail "another change of Grassfield's update channel is running: try again when it has finished"
    else
      flock -w "$1" 9 || gf_fail "another change of Grassfield's update channel did not finish within $1 s"
    fi
  fi
  rm -f -- /etc/.pacman.conf.grassfield.* /etc/pacman.d/.grassfield.conf.*
}

# The packaged repository.conf: KEY=value lines checked by generate.py at build time, read here, never sourced.
gf_load() {
  local line key value file=$GF_DATA/repository.conf
  GF_BASE='' GF_FPR=''
  GF_PREVIOUS=()
  [[ -f $file ]] || gf_fail "missing $file"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || gf_fail "malformed line in $file"
    key=${line%%=*} value=${line#*=}
    case $key in
      GRASSFIELD_REPO_BASE) GF_BASE=$value ;;
      GRASSFIELD_REPO_MIRRORS) ;;
      GRASSFIELD_REPO_BASE_PREVIOUS) read -r -a GF_PREVIOUS <<<"$value" ;;
      GRASSFIELD_SIGNING_FINGERPRINT) GF_FPR=$value ;;
      *) gf_fail "unknown key $key in $file" ;;
    esac
  done <"$file"
  [[ $GF_BASE =~ ^(https://|file:///)[A-Za-z0-9./:~+-]+$ ]] || gf_fail "malformed GRASSFIELD_REPO_BASE in $file"
  [[ $GF_FPR =~ ^([0-9A-F]{40})?$ ]] || gf_fail "malformed GRASSFIELD_SIGNING_FINGERPRINT in $file"
}

# pacman's DBPath and GPGDir. While pacman's configuration cannot be read (only when an Include's file is missing, the
# state gf_heal repairs) the defaults are used.
gf_paths() {
  GF_DBPATH=$(pacman-conf DBPath 2>/dev/null) || GF_DBPATH=/var/lib/pacman/
  GF_GPGDIR=$(pacman-conf GPGDir 2>/dev/null) || GF_GPGDIR=/etc/pacman.d/gnupg/
  [[ $GF_DBPATH == /* && $GF_GPGDIR == /* ]] || gf_fail "pacman's DBPath or GPGDir is not an absolute path"
  GF_DBPATH=${GF_DBPATH%/}
}

# A build that can set Grassfield updates up: a pinned key and a real host (ADR-0033 b.3, spec "Refusals").
gf_require_build() {
  local host=${GF_BASE#https://}
  host=${host%%/*}
  host=${host%%:*}
  [[ -n $GF_FPR ]] || gf_fail "no signing key in this build"
  [[ $GF_BASE == file://* || ($host != *.invalid && $host != invalid) ]] || gf_fail "no package repository in this build"
}

# pacman holds <DBPath>/db.lck while it runs (the helper's verbs wait for it; pacman's own scriptlets run under it).
gf_require_unlocked() {
  [[ ! -e $GF_DBPATH/db.lck ]] || gf_fail "pacman is running ($GF_DBPATH/db.lck exists): try again when it has finished"
}

# The number of [grassfield] sections of pacman.conf: lines that are [grassfield] once comments and blanks are removed.
gf_sections() {
  [[ -f $GF_PACMAN_CONF ]] || { echo 0; return; }
  awk '{ l = $0; sub(/#.*/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l); if (l == "[grassfield]") n++ } END { print n + 0 }' \
    "$GF_PACMAN_CONF"
}

gf_has_section() {
  (($(gf_sections) > 0))
}

# The first Server value of the included file ("" when none).
gf_primary() {
  awk '{ l = $0; sub(/#.*/, "", l)
         if (match(l, /^[ \t]*Server[ \t]*=[ \t]*/)) { v = substr(l, RLENGTH + 1); gsub(/[ \t]+$/, "", v); print v; exit } }' \
    "$GF_CONF"
}

# Replace /etc/pacman.conf with the output of the function named $1 (given the current file), through a temporary file
# in /etc and a rename that keeps its mode and owner. A symbolic link or another kind of file is refused.
gf_rewrite_pacman_conf() {
  local tmp
  [[ -f $GF_PACMAN_CONF && ! -L $GF_PACMAN_CONF ]] || gf_fail "$GF_PACMAN_CONF is not a regular file"
  tmp=$(mktemp /etc/.pacman.conf.grassfield.XXXXXX) || gf_fail "cannot create a temporary file in /etc"
  if "$1" <"$GF_PACMAN_CONF" >"$tmp" && chmod --reference="$GF_PACMAN_CONF" -- "$tmp" &&
    chown --reference="$GF_PACMAN_CONF" -- "$tmp" && sync -- "$tmp" && mv -fT -- "$tmp" "$GF_PACMAN_CONF"; then
    return 0
  fi
  rm -f -- "$tmp"
  gf_fail "cannot write $GF_PACMAN_CONF (it is unchanged)"
}

gf_with_lines() {
  local text
  text=$(cat && echo x) || return 1 # keeps the trailing newlines; the x is dropped below
  text=${text%x}
  printf '%s' "$text"
  [[ -z $text || $text == *$'\n' ]] || echo
  printf '\n[grassfield]\n%s\n' "$GF_INCLUDE"
}

# Every [grassfield] section goes (its header up to the next header), with one blank line right before it.
gf_without_lines() {
  awk '
    function flush(n) { while (n-- > 0) print "" }
    {
      l = $0; sub(/#.*/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l)
      if (l ~ /^\[.*\]$/) {
        if (l == "[grassfield]") { if (blank > 0) flush(blank - 1); blank = 0; skip = 1; next }
        skip = 0
      }
      if (skip) next
      if ($0 ~ /^[ \t]*$/) { blank++; next }
      flush(blank); blank = 0; print
    }
    END { flush(blank) }'
}

# Exactly one section: added when missing; when there are several (the hook appending between this program's read and
# its rename, pacman then refuses "already registered"), they are replaced by one.
gf_add_lines() {
  case $(gf_sections) in
    1) return 0 ;;
    0) gf_rewrite_pacman_conf gf_with_lines ;;
    *) gf_rewrite_pacman_conf gf_one_section ;;
  esac
}

gf_one_section() {
  gf_without_lines | gf_with_lines
}

gf_remove_lines() {
  gf_has_section || return 0
  gf_rewrite_pacman_conf gf_without_lines
}

# /etc/pacman.d/grassfield.conf from the packaged template of a channel, through a temporary file and a rename.
gf_write_file() {
  local tpl=$GF_DATA/grassfield-$1.conf tmp
  [[ -f $tpl ]] || gf_fail "missing $tpl"
  tmp=$(mktemp /etc/pacman.d/.grassfield.conf.XXXXXX) || gf_fail "cannot create a temporary file in /etc/pacman.d"
  if cat -- "$tpl" >"$tmp" && chmod 0644 -- "$tmp" && sync -- "$tmp" && mv -fT -- "$tmp" "$GF_CONF"; then
    return 0
  fi
  rm -f -- "$tmp"
  gf_fail "cannot write $GF_CONF"
}

# pacman's synced copy of [grassfield]: after a Server change it would keep the other channel's database (P7).
gf_drop_synced() {
  local s=$GF_DBPATH/sync
  rm -f -- "$s/grassfield.db" "$s/grassfield.db.sig" "$s/grassfield.files" "$s/grassfield.files.sig" ||
    gf_fail "cannot remove pacman's synced [grassfield] files in $s"
}

# The package scriptlet's way after a Server change (ADR-0050 2, security review of the staged rollout, HIGH 1): it runs
# inside `omarchy update`, whose later step `omarchy-update-aur-pkgs` runs `yay -Sua --noconfirm` on the packages no sync
# database lists (pacman -Qm). Deleting the [grassfield] database there would make every grassfield-* package foreign for
# the rest of that run, so an AUR package of the same name and a higher version would be built and installed (GF-045). The
# files stay, listing the packages; their time goes to the epoch: a download condition on a file dated the epoch is always
# met (libalpm gives the file's time to libcurl, which may send If-Modified-Since for time 0; the server's copy is newer than
# 1970, so the answer is a 200 either way), so the next sync downloads the database and its signature (200 for both: never
# a new .sig beside a kept .db, P7). A link or another kind of file is left alone (pacman's own folder; nothing else writes there),
# and touch -h never follows one even if it appeared between the test and the touch.
gf_refetch_synced() {
  local s=$GF_DBPATH/sync f
  for f in grassfield.db grassfield.db.sig grassfield.files grassfield.files.sig; do
    [[ -f $s/$f && ! -L $s/$f ]] || continue
    touch -h -c -d @0 -- "$s/$f" || gf_fail "cannot mark $s/$f to be downloaded again"
  done
}

# Lines without their file (pacman cannot run at all then): the lines go first, whatever the verb does next.
gf_heal() {
  if [[ ! -e $GF_CONF ]] && gf_has_section; then
    gf_remove_lines
    gf_paths
  fi
}

# The validity of a key in pacman's keyring ("" when it is absent; f or u when trusted).
gf_validity() {
  gpg --homedir "$GF_GPGDIR" --batch --no-tty --no-permission-warning --with-colons --list-keys -- "$1" 2>/dev/null |
    awk -F: '$1 == "pub" { print $2; exit }'
}

# ADR-0033 b.3 (owner decision O17): when the pinned key is not trusted (its validity, not its presence: pacman may have
# imported it untrusted), the shipped key file must hold exactly that key, which is then added and locally signed.
gf_bootstrap() {
  local key=$GF_DATA/grassfield-signing-key.asc listing
  [[ $(gf_validity "$GF_FPR") == [fu] ]] && return 0
  [[ -s $key ]] || gf_fail "no signing key in this build"
  listing=$(gpg --homedir "$GF_GPGDIR" --batch --no-tty --no-permission-warning --with-colons --show-keys -- "$key" 2>/dev/null) ||
    gf_fail "cannot read $key"
  [[ $(awk -F: '$1 == "sec" { s = 1 } END { print s + 0 }' <<<"$listing") == 0 &&
    $(awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10 } { p = 0 }' <<<"$listing") == "$GF_FPR" ]] ||
    gf_fail "$key is not the pinned key $GF_FPR: refused"
  pacman-key --add "$key" >/dev/null || gf_fail "pacman-key --add failed"
  pacman-key --lsign-key "$GF_FPR" >/dev/null || gf_fail "pacman-key --lsign-key failed"
  [[ $(gf_validity "$GF_FPR") == [fu] ]] || gf_fail "the pinned key $GF_FPR is still not trusted"
}

# Every key of the installed grassfield-keyring trusted again and every revoked one disabled (R3). A keyless keyring
# (ADR-0033 b.2, U23: until the owner's key exists) has nothing to populate.
gf_populate() {
  [[ -s $GF_KEYRING/grassfield.gpg ]] || return 0
  pacman-key --populate-from "$GF_KEYRING" --populate grassfield >/dev/null || gf_fail "pacman-key --populate-from failed"
}

# ADR-0033 b.8: every key of grassfield-trusted and the pinned key leave pacman's keyring; empty fingerprints are skipped.
gf_delete_keys() {
  local fpr failed=0
  local -a keys=()
  [[ -n $GF_FPR ]] && keys+=("$GF_FPR")
  if [[ -f $GF_KEYRING/grassfield-trusted ]]; then
    while IFS=: read -r fpr _ || [[ -n $fpr ]]; do
      [[ $fpr =~ ^[0-9A-Fa-f]{40}$ ]] && keys+=("${fpr^^}")
    done <"$GF_KEYRING/grassfield-trusted"
  fi
  ((${#keys[@]})) || return 0
  while IFS= read -r fpr; do
    [[ -n $(gf_validity "$fpr") ]] || continue
    pacman-key --delete "$fpr" >/dev/null || { echo "${GF_PROG}: pacman-key --delete $fpr failed" >&2; failed=1; }
  done < <(printf '%s\n' "${keys[@]}" | sort -u)
  ((failed == 0)) || gf_fail "a Grassfield key is still in pacman's keyring"
}

# The channel rule (ADR-0033 O15b, owner decision of 2026-11-04, the macOS model): an installed VERSION that is a prerelease
# (-betaN, -rcN), or missing, empty, unreadable or malformed, can only follow beta; beta carries every release, a plain version
# goes to stable and to beta when it is newer. Once a plain X.Y.Z is installed, stable is available. Strict: the whole file,
# trimmed, must be X.Y.Z (one line).
gf_stable_allowed() {
  local v
  [[ -f "$GF_VERSION_FILE" && -r "$GF_VERSION_FILE" ]] || return 1
  v=$(<"$GF_VERSION_FILE") || return 1
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# set stable|beta (U16 order): trust, populate, the file, the lines, the synced files.
gf_set() {
  gf_require_build
  [[ $1 != stable ]] || gf_stable_allowed ||
    gf_fail "beta updates stay on while a beta version of Grassfield is installed (stable has no release yet): you can turn them off once the release is installed"
  gf_heal
  gf_bootstrap
  gf_populate
  gf_write_file "$1"
  gf_add_lines
  gf_drop_synced
}

# restore ("Repair…" in the repair state): the two lines, only when the file exists.
gf_restore() {
  gf_heal
  [[ -f $GF_CONF ]] || gf_fail "Grassfield updates are not set up ($GF_CONF is missing)"
  gf_add_lines
}

# off ("Turn Off…") and the scriptlet's remove: the lines, the file, the synced files, the keys.
gf_off() {
  gf_remove_lines
  rm -f -- "$GF_CONF" || gf_fail "cannot remove $GF_CONF"
  gf_paths
  gf_drop_synced
  gf_delete_keys
}

# The scriptlet's upgrade (ADR-0033 h.3, O19): a file whose primary Server is <previous base>/<channel>/$arch (or that base's
# cohort form, ADR-0050) is written again from this build's template of that channel; any other content is left alone. It
# runs inside pacman's transaction: the synced files are kept and marked to be downloaded again (gf_refetch_synced).
gf_migrate() {
  local primary base channel
  [[ -f $GF_CONF ]] || return 0
  primary=$(gf_primary) || return 0
  for base in "${GF_PREVIOUS[@]}"; do
    for channel in stable beta; do
      if [[ $primary == "$base/$channel/\$arch" ]] || gf_cohort_of "$primary" "$base/$channel" >/dev/null; then
        gf_write_file "$channel"
        gf_refetch_synced
        return 0
      fi
    done
  done
}

# --- Staged rollout (ADR-0050; OPUS SECURITY REVIEW REQUIRED) ----------------------------------------------------------
# The machine's wariness: 32 random bits drawn once, kept by root (pacman reads the Server line it decides as root), never
# sent anywhere. Its cohort (00-19) names the path of the cohort form: Server = <base>/<channel>/cohort/<NN>/$arch, then the
# plain lines. Only the scriptlet's upgrade enrolls, and only when the verified [grassfield] database lists the marker
# package grassfield-rollout 1-<rel> (ADR-0050 g.2): the signal has the database's trust and needs no network.
GF_STATE_DIR=/var/lib/grassfield
GF_WARINESS=$GF_STATE_DIR/rollout-wariness
GF_COHORTS=20

# The two digits of a cohort-form Server value for <prefix> (<base>/<channel>), printed; 1 when it is not one.
gf_cohort_of() {
  local rest=${1#"$2/cohort/"}
  [[ $rest != "$1" && $rest =~ ^([0-9]{2})/\$arch$ ]] || return 1
  ((10#${BASH_REMATCH[1]} < GF_COHORTS)) || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# /var/lib/grassfield is root's own folder, never a link (checked before every read and write in it; only root writes
# /var/lib, so anything else is damage and is refused).
gf_state_dir_ok() {
  [[ -d $GF_STATE_DIR && ! -L $GF_STATE_DIR && $(stat -c %u -- "$GF_STATE_DIR") == "$EUID" ]] && return 0
  echo "${GF_PROG}: $GF_STATE_DIR is not root's own folder" >&2
  return 1
}

# The stored wariness (an integer below 2^32), drawn and stored on first use; 1 when it can be neither read nor made. A link,
# another kind of file or a folder that is not root's own is refused, never followed.
gf_wariness() {
  local w='' tmp
  if [[ -e $GF_STATE_DIR || -L $GF_STATE_DIR ]]; then
    gf_state_dir_ok || return 1
  fi
  if [[ -e $GF_WARINESS || -L $GF_WARINESS ]]; then
    [[ -f $GF_WARINESS && ! -L $GF_WARINESS ]] || { echo "${GF_PROG}: $GF_WARINESS is not a regular file" >&2; return 1; }
    w=$(head -c 16 -- "$GF_WARINESS") || w=''
    w=${w%$'\n'}
    if [[ $w =~ ^[0-9]{1,10}$ ]] && ((10#$w < 4294967296)); then
      printf '%s\n' "$((10#$w))"
      return 0
    fi
  fi
  w=$(od -An -N4 -tu4 /dev/urandom) || return 1
  w=${w//[[:space:]]/}
  [[ $w =~ ^[0-9]{1,10}$ ]] && ((10#$w < 4294967296)) || return 1
  if [[ ! -e $GF_STATE_DIR && ! -L $GF_STATE_DIR ]]; then
    mkdir -m 0755 -- "$GF_STATE_DIR" 2>/dev/null || return 1
  fi
  gf_state_dir_ok || return 1
  tmp=$(umask 077 && mktemp "$GF_STATE_DIR/.rollout-wariness.XXXXXX") || return 1
  if printf '%s\n' "$((10#$w))" >"$tmp" && sync -- "$tmp" && mv -fT -- "$tmp" "$GF_WARINESS"; then
    printf '%s\n' "$((10#$w))"
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# The machine's cohort, two digits (floor(w * 20 / 2^32)).
gf_cohort() {
  local w
  w=$(gf_wariness) || return 1
  printf '%02d\n' "$((w * GF_COHORTS / 4294967296))"
}

# The scriptlet's remove: the wariness leaves with Grassfield (ADR-0033 b.8). Turn Off… keeps it (the same cohort later).
# A folder that is not root's own is refused (nothing is deleted through a link).
gf_forget_wariness() {
  [[ -e $GF_STATE_DIR || -L $GF_STATE_DIR ]] || return 0
  gf_state_dir_ok || return 1
  rm -f -- "$GF_WARINESS" "$GF_STATE_DIR"/.rollout-wariness.* || return 1
  rmdir -- "$GF_STATE_DIR" 2>/dev/null || true
}

# Whether the verified [grassfield] database lists the marker of this scheme (grassfield-rollout 1-<rel>): 0 it does, 1 the
# listing was read and does not (the marker withdrawn), 2 no listing: pacman failing, or an empty answer. A missing synced
# grassfield.db is not a pacman failure (libalpm reads it as a missing database, -Sl prints nothing and exits 0), and a real
# [grassfield] listing always names grassfield-desktop, so an empty one means no synced database yet. The caller then
# changes nothing (ADR-0050 2, security reviews MEDIUM 2 and LOW 1). pacman -Sl loads the synced database pacman verified
# (SigLevel = Required) and takes no lock. The listing is read whole first, then searched through a pipe (no here-string:
# bash may write one to /tmp, ADR-0033 s3.2), so no early exit can turn into a SIGPIPE failure.
gf_rollout_advertised() {
  local out
  out=$(pacman -Sl grassfield 2>/dev/null) || return 2
  [[ -n $out ]] || return 2
  printf '%s\n' "$out" | grep -E '^grassfield grassfield-rollout 1-[1-9][0-9]*( |$)' >/dev/null
}

# /etc/pacman.d/grassfield.conf in the cohort form of a channel: the packaged template with @COHORT@ replaced by the two
# digits, through a temporary file and a rename (gf_write_file's way).
gf_write_cohort() {
  local tpl=$GF_DATA/grassfield-$1-cohort.conf tmp text
  [[ $2 =~ ^[0-9]{2}$ ]] && ((10#$2 < GF_COHORTS)) || gf_fail "malformed cohort '$2'"
  [[ -f $tpl ]] || gf_fail "missing $tpl"
  text=$(<"$tpl") || gf_fail "cannot read $tpl"
  tmp=$(mktemp /etc/pacman.d/.grassfield.conf.XXXXXX) || gf_fail "cannot create a temporary file in /etc/pacman.d"
  if printf '%s\n' "${text//@COHORT@/$2}" >"$tmp" && chmod 0644 -- "$tmp" && sync -- "$tmp" && mv -fT -- "$tmp" "$GF_CONF"; then
    return 0
  fi
  rm -f -- "$tmp"
  gf_fail "cannot write $GF_CONF"
}

# The lines pacman reads from a section file (stdin): comments removed, blanks trimmed, empty lines dropped.
gf_effective() {
  awk '{ l = $0; sub(/#.*/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l); if (l != "") print l }'
}

# The effective lines of this build's template of a channel in a form: plain, or a cohort's two digits.
gf_form_text() {
  local text
  if [[ $2 == plain ]]; then
    gf_effective <"$GF_DATA/grassfield-$1.conf"
    return
  fi
  text=$(<"$GF_DATA/grassfield-$1-cohort.conf") || return 1
  printf '%s\n' "${text//@COHORT@/$2}" | gf_effective
}

# The scriptlet's upgrade, after gf_migrate (ADR-0050 2): a file that is exactly one of this build's forms of stable or beta
# (its plain template, or its cohort template for some cohort, once comments and blanks are removed) takes the cohort form
# when the database advertises cohorts, the plain form when the listing says it does not. Anything else is left alone: a
# custom file, one an administrator added a Server line to or changed, no file. A listing that cannot be read, or a wariness
# that cannot be read or made, leaves the file as it is. The synced files are never deleted here; every change of form or
# cohort marks them to be downloaded again (gf_refetch_synced), plain -> cohort included: even though a cohort path never
# serves an older snapshot than the plain path (ADR-0050 g.4), the hosts' Last-Modified times are not trusted to order them
# (a 304 for the database beside a newer .sig is R4's failure; security review LOW 3).
gf_rollout() {
  local primary channel current='' want actual expected
  [[ -f $GF_CONF ]] || return 0
  primary=$(gf_primary) || return 0
  for channel in stable beta; do
    if [[ $primary == "$GF_BASE/$channel/\$arch" ]]; then
      current=plain
      break
    fi
    if current=$(gf_cohort_of "$primary" "$GF_BASE/$channel"); then
      break
    fi
    current=''
  done
  [[ -n $current ]] || return 0
  actual=$(gf_effective <"$GF_CONF") || return 0
  expected=$(gf_form_text "$channel" "$current") || return 0
  [[ -n $expected && $actual == "$expected" ]] || return 0
  gf_rollout_advertised
  case $? in
    0)
      want=$(gf_cohort) || return 0
      [[ $current != "$want" ]] || return 0
      gf_write_cohort "$channel" "$want"
      gf_refetch_synced
      ;;
    1)
      [[ $current != plain ]] || return 0
      gf_write_file "$channel"
      gf_refetch_synced
      ;;
  esac
  return 0
}
