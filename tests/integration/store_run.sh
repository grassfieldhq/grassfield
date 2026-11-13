#!/usr/bin/env bash
# Grassfield Store, steps 3b1, 3b2 and 3c part 3: grassfield-store-run, the script the Store starts in Omarchy's terminal
# (ADR-0037 b.2; spec A6b's grassfield-store-run part): Omarchy's setups, the AUR's two commands with their plan checked
# again, and Get Flatpak's omarchy-pkg-add flatpak (SD24). Never on a real machine: inside, it refuses to run unless it is root in a container with
# the repository mounted at /src.
#
#   tests/integration/store_run.sh
#   Runs `docker run --rm --network none` on archlinux:base (digest pinned below) with the repository mounted read-only.
#   Exit 0 all PASS (or SKIP without docker), 1 a FAIL, 2 usage.
#
# Inside the container: a user (`carol`) with an XDG_RUNTIME_DIR, a made-up Omarchy folder (recipes that write a marker,
# fail, sleep or leave a process running) and the Store's pins for it, the real pacman-conf and pacman (no sync database:
# pacman -Qu lists nothing) behind a wrapper at /usr/bin/pacman whose -Qu answers as /run/test/qu says (lines, a failure,
# a pause) and whose -Slq, -Qqe, -Qqm and -Rs plan answer the AUR cases from /run/test (the repositories' names, the
# explicit and foreign packages, a removal plan), and pacman's real db.lck. The script fixes its own PATH, so a program first in carol's PATH is never used (a
# case checks it). The script runs as carol through setpriv (one process: no watching parent between it and the test),
# with no terminal (stdin /dev/null).
set -uo pipefail

IMAGE=archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0

if [[ ${1:-} != --inside ]]; then
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
  (($# == 0)) || { echo "usage: store_run.sh" >&2; exit 2; }
  . "$root/tests/integration/container.sh" || exit 2
  gf_have_docker || { echo "SKIP: no docker daemon (this test runs only in a throwaway container)"; exit 0; }
  gf_container_init "$root" || exit 2
  gf_standard none || exit 2
  gf_container_run "$IMAGE" bash /src/tests/integration/store_run.sh --inside
  exit $?
fi

[[ -f /.dockerenv && $(id -u) == 0 && -f /src/packaging/store/grassfield-store-run ]] ||
  { echo "refused: runs only as root inside a throwaway container (/src)"; exit 2; }

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
expect() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
say() { printf '\n== %s\n' "$*"; }
newop() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

R=/usr/lib/grassfield/grassfield-store-run
install -Dm755 /src/packaging/store/grassfield-store-run "$R"
# A UTF-8 locale for the cases where bash's ranges would follow it (made from glibc's own sources: no network).
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen >/dev/null 2>&1
useradd -m carol
as_carol() { setpriv --reuid=carol --regid=carol --init-groups -- "$@"; }
cuid=$(id -u carol)
RT=/run/user/$cuid
mkdir -p "$RT" && chown carol: "$RT" && chmod 700 "$RT"
D=$RT/grassfield/store
O=/home/carol/omarchy # the made-up Omarchy folder (OMARCHY_PATH)
M=/home/carol/marks   # what the recipes did
E=/home/carol/evil    # programs of carol's own, first in her PATH when a case asks
as_carol mkdir -p "$O/bin" "$O/install/helpers" "$M" "$E"
# pacman's -Qu as /run/test/qu says: "list" (the lines of /run/test/qu-lines, exit 0), "fail" (exit 2), "slow" (a pause in
# which the test presses Ctrl+C); anything else the real pacman.
T=/run/test
mkdir -p "$T" && chmod 755 "$T"
mv /usr/bin/pacman /usr/bin/pacman.real
cat >/usr/bin/pacman <<'PACMAN'
#!/bin/bash
if [[ ${1-} == -Qu && -s /run/test/qu ]]; then
  case $(cat /run/test/qu) in
    list) cat /run/test/qu-lines; exit 0 ;;
    fail) echo "error: failed to init transaction" >&2; exit 2 ;;
    slow) : >/run/test/qu-asked; sleep 20; exit 1 ;;
  esac
fi
case ${1-} in
  -Slq) [[ -e /run/test/sl ]] && { cat /run/test/sl; exit 0; } ;;
  -Sp) # what pacman resolves: a repository's package (/run/test/sl) or one that provides the name (/run/test/provides)
    [[ -e /run/test/sl ]] && {
      [[ -e /run/test/sp-fail ]] && { echo "error: failed to init transaction (unable to lock database)" >&2; exit 1; }
      [[ -e /run/test/sp-other ]] && { echo "error: target not found: $(cat /run/test/sp-other)" >&2; exit 1; }
      name=${!#}
      grep -qx -- "$name" /run/test/sl && { echo "$name"; exit 0; }
      provider=$(awk -v n="$name" '$1 == n {print $2}' /run/test/provides 2>/dev/null)
      [[ -n $provider ]] && { echo "$provider"; exit 0; }
      echo "error: target not found: $name" >&2
      exit 1
    } ;;
  -Qqe) [[ -e /run/test/qe ]] && { cat /run/test/qe; exit 0; } ;;
  -Qqm) [[ -e /run/test/qm ]] && { cat /run/test/qm; exit 0; } ;;
  -Qq) [[ -e /run/test/gf ]] && { echo grassfield-desktop; exit 0; } ;; # a Grassfield package is installed (ADR-0046 D3)
  -Qi) [[ -e /run/test/gf-fail ]] && { echo "error: database corrupt" >&2; exit 1; }
    [[ -e /run/test/gf ]] && { printf '%s\n' "Name            : grassfield-desktop" "Optional Deps   : cmake: rebuild" "                  ninja>=1.11: faster" \
      "Required By     : None"; exit 0; } ;;
  -Rs) [[ -e /run/test/rs ]] && { cat /run/test/rs; [[ ! -e /run/test/rs-fail ]]; exit; } ;;
esac
exec /usr/bin/pacman.real "$@"
PACMAN
chmod 755 /usr/bin/pacman
qu() { printf '%s\n' "$1" >"$T/qu"; }
recipe() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$O/bin/$1"
  chmod 755 "$O/bin/$1"
  chown carol: "$O/bin/$1"
}
recipe omarchy-install-game 'source "$OMARCHY_PATH/install/helpers/game.sh"; echo "installed $*" >>"$HOME/marks/game"'
recipe omarchy-remove-game 'echo removed >>"$HOME/marks/game"'
recipe omarchy-install-broken 'echo half >>"$HOME/marks/broken"; exit 7'
recipe omarchy-install-slow 'echo started >"$HOME/marks/slow"; sleep 20; echo finished >>"$HOME/marks/slow"'
recipe omarchy-install-daemon 'setsid sleep 30 </dev/null >/dev/null 2>&1 & echo started >"$HOME/marks/daemon"'
recipe omarchy-install-unpinned 'echo ran >"$HOME/marks/unpinned"'
recipe omarchy-install-path 'omarchy-game-helper; echo ran >>"$HOME/marks/path"'
recipe omarchy-game-helper 'echo pinned >>"$HOME/marks/helper"'
printf 'true\n' >"$O/install/helpers/game.sh" && chown carol: "$O/install/helpers/game.sh"
# The Store's pins of an operation: every pinned file, "<sha256>  <path>" (the catalog's pins, ADR-0037 g).
pins() { # op [extra lines]
  (cd "$O" && sha256sum bin/omarchy-install-game bin/omarchy-remove-game bin/omarchy-install-broken bin/omarchy-install-slow \
    bin/omarchy-install-daemon bin/omarchy-install-path bin/omarchy-game-helper install/helpers/game.sh) >"$D/$1.pins"
  (($# > 1)) && printf '%s\n' "${@:2}" >>"$D/$1.pins"
  chown carol: "$D/$1.pins" && chmod 600 "$D/$1.pins"
}
as_carol mkdir -p "$D"
# The script as carol, as in her terminal: her environment, OMARCHY_PATH, her PATH ($cpath) and what $extra adds.
cpath=/usr/bin
extra=()
run() { # op deadline kind recipe [args]
  as_carol env -i HOME=/home/carol USER=carol PATH="$cpath" XDG_RUNTIME_DIR="$RT" OMARCHY_PATH="$O" "${extra[@]}" \
    "$R" "$@" </dev/null >>/tmp/run.out 2>&1
}
soon() { echo $(($(date +%s) + 60)); }
exitfile() { cat "$D/$1.exit" 2>/dev/null; }
# Who holds Omarchy's update lock, read as carol (the container's root may not read another user's descriptors).
holders() { as_carol find /proc/[0-9]*/fd -lname "$RT/omarchy-update.lock" 2>/dev/null | cut -d/ -f3 | sort -u | tr '\n' ' '; }

say "usage: the tokens of ADR-0037 e.5 only"
for args in "" "x" "$(newop) $(soon) setup" "0123 $(soon) setup omarchy-install-game" "$(newop) soon setup omarchy-install-game" \
  "$(newop) $(soon) aur omarchy-install-game" "$(newop) $(soon) setup omarchy-game" "$(newop) $(soon) setup omarchy-install-Game" \
  "$(newop) $(soon) setup omarchy-install-game A" "$(newop) $(soon) setup omarchy-install-game -x" \
  "$(newop) $(soon) setup omarchy-install-game a b c d e" "$(newop) $(soon) setup /tmp/omarchy-install-game"; do
  # shellcheck disable=SC2086 # the cases are word lists
  run $args; rc=$?
  expect "refused: '${args:0:60}' -> exit 2" test "$rc" == 2
done
op=$(newop)
run "$op" "$(soon)" setup "omarchy-install-game;id"; rc=$?
expect "a recipe with a shell character -> exit 2" test "$rc" == 2
run "$op" "$(soon)" setup omarchy-install-game "$(printf 'one\nid')"; rc=$?
expect "an argument with a line feed -> exit 2" test "$rc" == 2
rc=$(as_carol env -i HOME=/home/carol PATH=/usr/bin OMARCHY_PATH="$O" "$R" "$op" "$(soon)" setup omarchy-install-game </dev/null >/dev/null 2>&1; echo $?)
expect "no XDG_RUNTIME_DIR -> exit 2" test "$rc" == 2
rc=$(env -i HOME=/root PATH=/usr/bin XDG_RUNTIME_DIR=/run/user/0 OMARCHY_PATH="$O" "$R" "$op" "$(soon)" setup omarchy-install-game \
  </dev/null 2>/tmp/root.err; echo $?)
expect "run as root -> exit 2, says why" bash -c "test $rc == 2 && grep -q 'never as root' /tmp/root.err"
expect "nothing ran, no file written" bash -c "test ! -e $M/game && test -z \"\$(ls $D)\" && test ! -e /run/user/0/grassfield"

say "a run: the recipe, its files, the lock held while it runs"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-game one two; rc=$?
expect "install omarchy-install-game one two -> exit 0, the recipe ran with its arguments" bash -c "test $rc == 0 && grep -qx 'installed one two' $M/game"
expect "  the exit file says 0; the started file a pid and a start time" bash -c "test '$(exitfile "$op")' == 0 && grep -Eq '^[0-9]+ [0-9]+$' $D/$op.started"
expect "  $D is carol's, 0700; its files 0600" test "$(stat -c %U:%a "$D"):$(stat -c %a "$D/$op.exit")" == "carol:700:600"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "the same operation id again -> exit 2, nothing ran again" bash -c "test $rc == 2 && test \$(wc -l <$M/game) == 1"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-remove-game; rc=$?
expect "a removal recipe -> exit 0" bash -c "test $rc == 0 && tail -1 $M/game | grep -qx removed"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-broken; rc=$?
expect "the recipe fails (exit 7) -> exit 1, the exit file says 1" test "$rc:$(exitfile "$op")" == "1:1"
op=$(newop); pins "$op"
# Its own process group, as a terminal's foreground job: with job control off, a background job would ignore SIGINT.
set -m
run "$op" "$(soon)" setup omarchy-install-slow &
set +m
for _ in $(seq 40); do grep -q started "$M/slow" 2>/dev/null && break; sleep 0.25; done
spid=$(cut -d' ' -f1 "$D/$op.started" 2>/dev/null)
held=yes
as_carol flock -n "$RT/omarchy-update.lock" true && held=no
expect "while the recipe runs, Omarchy's update lock is held, by the script only ($(holders))" test "$held:$(holders)" == "yes:$spid "
op2=$(newop); pins "$op2"
run "$op2" "$(soon)" setup omarchy-install-game; rc=$?
expect "  another run meanwhile -> exit 3 (busy), its recipe not run" test "$rc:$(exitfile "$op2")" == "3:3"
# Ctrl+C in the terminal: SIGINT to its foreground process group (the script and the recipe).
kill -INT -- "-$(ps -o pgid= "$spid" | tr -d ' ')"
wait
expect "Ctrl+C -> exit file 130, the recipe stopped" bash -c "test '$(exitfile "$op")' == 130 && ! grep -q finished $M/slow"
expect "  the lock is free once it ended" as_carol flock -n "$RT/omarchy-update.lock" true
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-daemon; rc=$?
sleep 0.5
expect "a recipe that leaves a process running -> exit 0, the process holds no lock ($(holders))" \
  bash -c "test $rc == 0 && pgrep -u carol -x sleep >/dev/null && test -z '$(holders)'"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "  the next run is not busy -> exit 0" test "$rc" == 0
pkill -u carol -x sleep

say "refusals before the recipe"
op=$(newop); pins "$op"
run "$op" $(($(date +%s) - 1)) setup omarchy-install-game; rc=$?
expect "past the deadline -> exit 6, exit file 6, no started file" bash -c "test $rc:$(exitfile "$op") == 6:6 && test ! -e $D/$op.started"
op=$(newop); pins "$op"
as_carol flock "$RT/omarchy-update.lock" sleep 5 &
sleep 0.5
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
wait
expect "Omarchy's update lock held (omarchy update running) -> exit 3" test "$rc:$(exitfile "$op")" == "3:3"
touch /var/lib/pacman/db.lck
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "pacman's db.lck there -> exit 3" test "$rc:$(exitfile "$op")" == "3:3"
rm -f /var/lib/pacman/db.lck
qu list
printf 'linux 6.17.1-1 -> 6.17.4-1\ngame-data 1-1 -> 2-1 [ignored]\n' >"$T/qu-lines"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "pacman -Qu lists linux -> exit 4" test "$rc:$(exitfile "$op")" == "4:4"
printf 'game-data 1-1 -> 2-1 [ignored]\n' >"$T/qu-lines"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "pacman -Qu lists only an [ignored] package -> exit 0" test "$rc" == 0
lines_before=$(wc -l <"$M/game")
qu fail
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "pacman -Qu fails (exit 2) -> exit 1, not run" bash -c "test $rc:$(exitfile "$op") == 1:1 && test \$(wc -l <$M/game) == $lines_before"
# Ctrl+C while pacman -Qu runs (the second checks): the script's group, as above.
qu slow
op=$(newop); pins "$op"
set -m
run "$op" "$(soon)" setup omarchy-install-game &
set +m
for _ in $(seq 40); do [[ -e $T/qu-asked ]] && break; sleep 0.25; done
spid=$(cut -d' ' -f1 "$D/$op.started" 2>/dev/null)
kill -INT -- "-$(ps -o pgid= "$spid" | tr -d ' ')"
wait
expect "Ctrl+C during the checks -> exit file 130, the recipe not run" \
  bash -c "test '$(exitfile "$op")' == 130 && test \$(wc -l <$M/game) == $lines_before && grep -q 'Stopped: nothing was run' /tmp/run.out"
rm -f "$T/qu" "$T/qu-asked"
op=$(newop)
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "no pins file -> exit 5" test "$rc:$(exitfile "$op")" == "5:5"
op=$(newop); pins "$op" "not a pin line"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "a pins line that does not parse -> exit 5" test "$rc" == 5
op=$(newop); pins "$op" "$(cd "$O" && sha256sum bin/omarchy-install-game | cut -d' ' -f1)  bin/../bin/omarchy-install-game"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "a pinned path with '..' (its hash right) -> exit 5" test "$rc" == 5
op=$(newop); pins "$op"
echo '# changed by an update' >>"$O/install/helpers/game.sh"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "a file the recipe sources differs from its pin -> exit 5, the message names it" \
  bash -c "test $rc == 5 && grep -q 'install/helpers/game.sh differs' /tmp/run.out"
sed -i '$d' "$O/install/helpers/game.sh"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-unpinned; rc=$?
expect "a recipe the pins do not name -> exit 5, not run" bash -c "test $rc == 5 && test ! -e $M/unpinned"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-missing; rc=$?
expect "a recipe Omarchy does not have -> exit 5" test "$rc" == 5
op=$(newop) other=$(newop); pins "$other"
ln -s "$D/$other.pins" "$D/$op.pins" && chown -h carol: "$D/$op.pins"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "a pins file that is a link (to good pins) -> exit 5" test "$rc" == 5
op=$(newop); pins "$op"
chown root: "$D/$op.pins" && chmod 644 "$D/$op.pins"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "a pins file someone else owns -> exit 5" test "$rc" == 5
op=$(newop); pins "$op" "$(printf '%064d' 0)  install/helpers/gone.sh"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "a pinned file Omarchy does not have -> exit 5, the message names it" \
  bash -c "test $rc == 5 && grep -q 'install/helpers/gone.sh differs' /tmp/run.out"
expect "none of the refused runs ran the recipe" test "$(wc -l <"$M/game")" == "$lines_before"

say "the caller's environment does not choose the programs"
# carol's own programs first in her PATH: a helper the recipe calls by name, and a sha256sum that answers game.sh's
# pinned hash whatever game.sh holds (the real one for any other file).
printf '#!/bin/bash\necho evil >>"$HOME/marks/helper"\n' >"$E/omarchy-game-helper"
good=$(sha256sum "$O/install/helpers/game.sh" | cut -d' ' -f1)
printf '#!/bin/bash\n/usr/bin/sha256sum "$@" | sed -E "s|^[0-9a-f]{64}(  .*/game\\.sh)$|%s\\1|"\n' "$good" >"$E/sha256sum"
printf 'echo sourced >>"$HOME/marks/bashenv"\n' >"$E/env.sh"
chmod 755 "$E"/* && chown carol: "$E"/*
cpath=$E:/usr/bin
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-path; rc=$?
expect "a command the recipe names is Omarchy's, not the one first in the caller's PATH" \
  bash -c "test $rc == 0 && test \"\$(cat $M/helper)\" == pinned"
op=$(newop); pins "$op"
echo '# changed by an update' >>"$O/install/helpers/game.sh"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "the script's own sha256sum is the system's: a changed file is still refused -> exit 5" test "$rc" == 5
sed -i '$d' "$O/install/helpers/game.sh"
cpath=/usr/bin
extra=(BASH_ENV="$E/env.sh" "BASH_FUNC_omarchy-game-helper%%=() { echo function >>\"\$HOME/marks/helper\"; }")
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-path; rc=$?
extra=()
expect "BASH_ENV and an exported function do not reach the recipe" \
  bash -c "test $rc == 0 && test ! -e $M/bashenv && test \"\$(sort -u $M/helper)\" == pinned"
# Its folder a link to another of carol's folders: refused before chmod reaches that folder.
mv "$D" "$D.kept"
as_carol mkdir -m 755 /home/carol/elsewhere
as_carol ln -s /home/carol/elsewhere "$D"
op=$(newop)
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "its folder a link -> exit 2, the linked folder's mode unchanged" test "$rc:$(stat -c %a /home/carol/elsewhere)" == "2:755"
rm "$D" && mv "$D.kept" "$D"

say "the AUR (step 3b2): its two commands, their names and their plan checked again"
recipe omarchy-pkg-aur-add 'echo "aur-add $*" >>"$HOME/marks/aur"; echo "${LC_ALL-unset}" >"$HOME/marks/locale"'
recipe omarchy-pkg-drop 'echo "aur-drop $*" >>"$HOME/marks/aur"'
recipe omarchy-pkg-missing 'exit 0'
printf 'btop\nchromium\ngs-omarchy-app # a comment\n' >"$O/install/omarchy-base.packages"
chown carol: "$O/install/omarchy-base.packages"
aurpins() { # op [extra lines]
  (cd "$O" && sha256sum bin/omarchy-pkg-aur-add bin/omarchy-pkg-drop bin/omarchy-pkg-missing) >"$D/$1.pins"
  (($# > 1)) && printf '%s\n' "${@:2}" >>"$D/$1.pins"
  chown carol: "$D/$1.pins" && chmod 600 "$D/$1.pins"
}
printf 'gimp\nfirefox\nbtop\n' >"$T/sl"
for args in "aur omarchy-pkg-aur-add" "aur omarchy-pkg-aur-add -rf" "aur omarchy-pkg-aur-add Foo" "aur omarchy-pkg-aur-add a b c d e" \
  "aur omarchy-install-game x" "aur yay x" "aur omarchy-pkg-drop ../x" "setup omarchy-pkg-aur-add x"; do
  # shellcheck disable=SC2086 # the cases are word lists
  run "$(newop)" "$(soon)" $args; rc=$?
  expect "refused: '$args' -> exit 2" test "$rc" == 2
done
run "$(newop)" "$(soon)" aur omarchy-pkg-aur-add "a b"; rc=$?
expect "a name with a space -> exit 2" test "$rc" == 2
op=$(newop); aurpins "$op"
run "$op" "$(soon)" aur omarchy-pkg-aur-add example-app-bin; rc=$?
expect "aur omarchy-pkg-aur-add example-app-bin -> exit 0, the command ran with the name" \
  bash -c "test $rc:$(exitfile "$op") == 0:0 && grep -qx 'aur-add example-app-bin' $M/aur"
op=$(newop); aurpins "$op"
run "$op" "$(soon)" aur omarchy-pkg-aur-add example-app-bin gimp; rc=$?
expect "a name a repository has (gimp) -> exit 7, not run, says why" \
  bash -c "test $rc:$(exitfile "$op") == 7:7 && test \$(wc -l <$M/aur) == 1 && grep -q 'A repository has gimp' /tmp/run.out"
# What pacman resolves is what yay installs: a package that provides the name (zathura provides pdf-viewer) is the
# repository's too. pacman that does not answer (its database locked) is no answer.
printf 'pdf-viewer zathura\n' >"$T/provides"
op=$(newop); aurpins "$op"
run "$op" "$(soon)" aur omarchy-pkg-aur-add pdf-viewer; rc=$?
expect "a name a repository's package provides (pdf-viewer) -> exit 7, not run, says why" \
  bash -c "test $rc:$(exitfile "$op") == 7:7 && test \$(wc -l <$M/aur) == 1 && grep -q 'A repository has pdf-viewer, or a package that provides it' /tmp/run.out"
touch "$T/sp-fail"
op=$(newop); aurpins "$op"
run "$op" "$(soon)" aur omarchy-pkg-aur-add example-app-bin; rc=$?
expect "pacman -Sp fails otherwise (its database locked) -> exit 1, not run" bash -c "test $rc == 1 && test \$(wc -l <$M/aur) == 1"
rm -f "$T/sp-fail"
# pacman's whole line for the name asked: a longer name's "target not found" (example-app-bin-extra for example-app-bin)
# is no answer about it.
printf 'example-app-bin-extra' >"$T/sp-other"
op=$(newop); aurpins "$op"
run "$op" "$(soon)" aur omarchy-pkg-aur-add example-app-bin; rc=$?
expect "pacman's 'target not found' for a longer name only -> exit 1, not run" bash -c "test $rc == 1 && test \$(wc -l <$M/aur) == 1"
rm -f "$T/sp-other"
# Never a name of the deny list (the helper's): an AUR package with the name of Omarchy's, Grassfield's or the system's.
add_refused() { # description name... : exit 7, the command not run
  local desc=$1 op rc
  shift
  op=$(newop); aurpins "$op"
  run "$op" "$(soon)" aur omarchy-pkg-aur-add "$@"; rc=$?
  expect "$desc -> exit 7, not run" bash -c "test $rc:$(exitfile "$op") == 7:7 && test \$(wc -l <$M/aur) == 1"
}
add_refused "omarchy-theme-example (Omarchy's prefix)" omarchy-theme-example
expect "  the message says why" grep -q 'omarchy-theme-example is a name the system, Omarchy or Grassfield uses' /tmp/run.out
add_refused "grassfield-shell-git (Grassfield's prefix)" grassfield-shell-git
add_refused "linux-example (the kernels' prefix)" linux-example
add_refused "example-app-bin, then btop (in Omarchy's package list, before any repository is asked)" example-app-bin btop
expect "  the message names btop" grep -q 'btop is a name the system, Omarchy or Grassfield uses' /tmp/run.out
add_refused "example-app-bin, then glibc (the system's)" example-app-bin glibc
mv "$O/install/omarchy-base.packages" "$O/install/base.away"
add_refused "Omarchy's package lists missing" example-app-bin
mv "$O/install/base.away" "$O/install/omarchy-base.packages"
mv "$T/sl" "$T/sl.kept" && : >"$T/sl"
op=$(newop); aurpins "$op"
run "$op" "$(soon)" aur omarchy-pkg-aur-add example-app-bin; rc=$?
expect "pacman lists no repository at all -> exit 1, not run" bash -c "test $rc == 1 && test \$(wc -l <$M/aur) == 1"
mv "$T/sl.kept" "$T/sl"
op=$(newop); pins "$op"
run "$op" "$(soon)" aur omarchy-pkg-aur-add example-app-bin; rc=$?
expect "the pins do not name the AUR's command -> exit 5, says so" \
  bash -c "test $rc == 5 && test \$(wc -l <$M/aur) == 1 && grep -q 'do not name omarchy-pkg-aur-add' /tmp/run.out"
op=$(newop)
(cd "$O" && sha256sum bin/omarchy-pkg-aur-add bin/omarchy-pkg-drop) >"$D/$op.pins" && chown carol: "$D/$op.pins" && chmod 600 "$D/$op.pins"
run "$op" "$(soon)" aur omarchy-pkg-aur-add example-app-bin; rc=$?
expect "the pins name the command but not the omarchy-pkg-missing it calls -> exit 5, not run" \
  bash -c "test $rc == 5 && test \$(wc -l <$M/aur) == 1 && grep -q 'do not name omarchy-pkg-aur-add (or what it calls)' /tmp/run.out"
# The checks read bytes, whatever the user's locale: under en_US.UTF-8 bash's [a-z] would also take ä, ﬁ or ², and [0-9a-f]
# an á. The recipe still runs in the user's locale.
extra=(LC_ALL=en_US.UTF-8)
for name in exämple ﬁle ab²; do
  run "$(newop)" "$(soon)" aur omarchy-pkg-aur-add "$name"; rc=$?
  expect "under en_US.UTF-8, the name '$name' -> exit 2" test "$rc" == 2
done
op="á$(newop | cut -c 2-)"
run "$op" "$(soon)" aur omarchy-pkg-aur-add example-app-bin; rc=$?
expect "under en_US.UTF-8, an operation id with á -> exit 2" test "$rc" == 2
op=$(newop); aurpins "$op"
run "$op" "$(soon)" aur omarchy-pkg-aur-add example-app-bin; rc=$?
expect "under en_US.UTF-8, a good name -> exit 0, the recipe in the user's locale" \
  bash -c "test $rc == 0 && test \"\$(cat $M/locale)\" == en_US.UTF-8"
extra=()
op=$(newop); aurpins "$op"
run "$op" "$(soon)" aur omarchy-pkg-aur-add example-app-bin; rc=$?
expect "without a locale of the user's, none is given to the recipe (not the checks' C)" \
  bash -c "test $rc == 0 && test \"\$(cat $M/locale)\" == unset"
op=$(newop); aurpins "$op"
echo '# changed' >>"$O/bin/omarchy-pkg-aur-add"
run "$op" "$(soon)" aur omarchy-pkg-aur-add example-app-bin; rc=$?
expect "the AUR's command differs from its pin -> exit 5, the AUR named" \
  bash -c "test $rc == 5 && grep -q 'Installing from the AUR was checked against another version of Omarchy (bin/omarchy-pkg-aur-add differs)' /tmp/run.out"
sed -i '$d' "$O/bin/omarchy-pkg-aur-add"
qu list
printf 'linux 6.17.1-1 -> 6.17.4-1\n' >"$T/qu-lines"
op=$(newop); aurpins "$op"
run "$op" "$(soon)" aur omarchy-pkg-aur-add example-app-bin; rc=$?
expect "pacman -Qu lists linux -> exit 4 for the AUR too" test "$rc:$(exitfile "$op")" == "4:4"
rm -f "$T/qu"

# Removal: installed explicitly, from outside the repositories, not denied, and a whole plan with nothing denied.
printf 'example-app-bin\nexample-tool\nbtop\nyay\ngimp\n' >"$T/qe"
printf 'example-app-bin\nexample-lib\nexample-tool\nbtop\nyay\n' >"$T/qm"
printf 'example-app-bin\nexample-lib\n' >"$T/rs"
op=$(newop); aurpins "$op"
run "$op" "$(soon)" aur omarchy-pkg-drop example-app-bin; rc=$?
expect "aur omarchy-pkg-drop example-app-bin -> exit 0, the command ran" \
  bash -c "test $rc == 0 && tail -1 $M/aur | grep -qx 'aur-drop example-app-bin'"
drop_refused() { # description name... : exit 7, the command not run, the message
  local desc=$1 before op rc
  shift
  before=$(wc -l <"$M/aur")
  op=$(newop); aurpins "$op"
  run "$op" "$(soon)" aur omarchy-pkg-drop "$@"; rc=$?
  expect "$desc -> exit 7, not run" bash -c "test $rc:$(exitfile "$op") == 7:7 && test \$(wc -l <$M/aur) == $before"
}
drop_refused "yay (the system's AUR helper)" yay
drop_refused "btop (in Omarchy's package list)" btop
drop_refused "glibc (pacman's HoldPkg)" glibc
# A package the user holds (HoldPkg in pacman.conf) is refused even when it came from the AUR and was installed explicitly.
sed -i 's/^HoldPkg *=.*/& example-held/' /etc/pacman.conf
printf 'example-held\n' >>"$T/qe"; printf 'example-held\n' >>"$T/qm"
drop_refused "example-held (in pacman's HoldPkg, from the AUR, installed explicitly)" example-held
drop_refused "example-lib (not installed explicitly: another package needs it)" example-lib
drop_refused "gimp (a repository has it: the helper removes it)" gimp
drop_refused "two names, one of them denied" example-tool linux-zen
printf 'example-tool\ngs-omarchy-app\n' >"$T/rs"
drop_refused "a plan that also removes gs-omarchy-app (in Omarchy's list)" example-tool
expect "  the message names it" grep -q 'would also remove gs-omarchy-app' /tmp/run.out
printf 'error: failed to prepare transaction (could not satisfy dependencies)\n:: removing example-tool breaks dependency' >"$T/rs"
touch "$T/rs-fail"
drop_refused "a plan pacman refuses (another package needs it)" example-tool
rm -f "$T/rs-fail"
# What Grassfield's packages list as optional dependencies (ADR-0046 D3) is read from pacman -Qq and -Qi: cmake is one, so it is
# never removed here, even installed explicitly from the AUR; when pacman cannot be read for it, nothing is run (exit 7).
printf 'cmake\n' >>"$T/qe"; printf 'cmake\n' >>"$T/qm"; printf 'cmake\n' >"$T/rs"
touch "$T/gf"
drop_refused "cmake (an optional dependency of a Grassfield package)" cmake
expect "  the message names the system, Omarchy or Grassfield" grep -q 'cmake is part of the system, Omarchy or Grassfield' /tmp/run.out
printf 'example-tool\n' >"$T/rs"
touch "$T/gf-fail"
drop_refused "pacman -Qi fails while a Grassfield package is listed (fail closed)" example-tool
expect "  the message says what could not be read" grep -q "optional dependencies: nothing was run" /tmp/run.out
rm -f "$T/gf" "$T/gf-fail"
sed -i '/^cmake$/d' "$T/qe" "$T/qm"
# A plan line read as a pattern would name the files it matches: "glib?" with a file glibc where the script runs would become
# glibc (HoldPkg) and refuse; read as the word it is, it is no package of the deny list.
printf 'example-tool\nglib?\n' >"$T/rs"
touch "$PWD/glibc"
op=$(newop); aurpins "$op"
run "$op" "$(soon)" aur omarchy-pkg-drop example-tool; rc=$?
rm -f "$PWD/glibc"
expect "a plan line is a word, never a file name pattern (glib? beside a file glibc) -> exit 0" test "$rc" == 0
printf 'example-tool\n' >"$T/rs"
mv "$O/install/omarchy-base.packages" "$O/install/base.away"
drop_refused "Omarchy's package lists missing" example-tool
mv "$O/install/base.away" "$O/install/omarchy-base.packages"
op=$(newop); aurpins "$op"
run "$op" "$(soon)" aur omarchy-pkg-drop example-tool; rc=$?
expect "  and once they are back, example-tool -> exit 0" test "$rc" == 0

say "Get Flatpak (step 3c part 3): omarchy-pkg-add flatpak only, pinned with omarchy-pkg-missing"
recipe omarchy-pkg-add 'echo "pkg-add $*" >>"$HOME/marks/pkgadd"'
flatpakpins() { # op [extra lines]
  (cd "$O" && sha256sum bin/omarchy-pkg-add bin/omarchy-pkg-missing) >"$D/$1.pins"
  (($# > 1)) && printf '%s\n' "${@:2}" >>"$D/$1.pins"
  chown carol: "$D/$1.pins" && chmod 600 "$D/$1.pins"
}
for args in "flatpak omarchy-pkg-add" "flatpak omarchy-pkg-add gimp" "flatpak omarchy-pkg-add flatpak gimp" "flatpak omarchy-pkg-add -flatpak" \
  "flatpak omarchy-pkg-add Flatpak" "flatpak omarchy-pkg-aur-add flatpak" "flatpak omarchy-install-game flatpak" \
  "setup omarchy-pkg-add flatpak" "aur omarchy-pkg-add flatpak"; do
  op=$(newop); flatpakpins "$op"
  # shellcheck disable=SC2086 # the cases are word lists
  run "$op" "$(soon)" $args; rc=$?
  expect "refused: '$args' -> exit 2" test "$rc" == 2
done
expect "  none of them ran omarchy-pkg-add" test ! -e "$M/pkgadd"
op=$(newop); flatpakpins "$op"
run "$op" "$(soon)" flatpak omarchy-pkg-add flatpak; rc=$?
expect "flatpak omarchy-pkg-add flatpak -> exit 0, the command ran with flatpak" \
  bash -c "test $rc:$(exitfile "$op") == 0:0 && grep -qx 'pkg-add flatpak' $M/pkgadd"
op=$(newop); (cd "$O" && sha256sum bin/omarchy-pkg-add) >"$D/$op.pins"; chown carol: "$D/$op.pins"; chmod 600 "$D/$op.pins"
run "$op" "$(soon)" flatpak omarchy-pkg-add flatpak; rc=$?
expect "pins without the omarchy-pkg-missing it calls -> exit 5, not run" bash -c "test $rc == 5 && test \$(wc -l <$M/pkgadd) == 1"
op=$(newop); flatpakpins "$op"
echo '# changed' >>"$O/bin/omarchy-pkg-add"
run "$op" "$(soon)" flatpak omarchy-pkg-add flatpak; rc=$?
expect "omarchy-pkg-add differs from its pin -> exit 5, Get Flatpak named, not run" \
  bash -c "test $rc == 5 && test \$(wc -l <$M/pkgadd) == 1 && grep -q 'Getting Flatpak was checked against another version of Omarchy (bin/omarchy-pkg-add differs)' /tmp/run.out"
sed -i '$d' "$O/bin/omarchy-pkg-add"
qu list
printf 'linux 6.17.1-1 -> 6.17.4-1\n' >"$T/qu-lines"
op=$(newop); flatpakpins "$op"
run "$op" "$(soon)" flatpak omarchy-pkg-add flatpak; rc=$?
expect "pacman -Qu lists linux -> exit 4, not run" bash -c "test $rc:$(exitfile "$op") == 4:4 && test \$(wc -l <$M/pkgadd) == 1"
rm -f "$T/qu"

# The deny list: the helper's case list as it is (only the array of Omarchy's lists named otherwise), and the same answers
# on the vectors the helper and the Store's C++ rule are held to.
sed -n '/^denied() {/,/^}/p' /src/packaging/store/grassfield-store-helper | sed 's/omarchy\[/omarchy_lists[/' >"$T/helper-denied"
sed -n '/^denied() {/,/^}/p' "$R" >"$T/run-denied"
expect "denied() is the helper's" bash -c "test -s $T/run-denied && test \"\$(cat $T/helper-denied)\" == \"\$(cat $T/run-denied)\""
# The vectors file read with grep and sed (this image has no python): Omarchy's lists, Grassfield's optional dependencies
# (gfOptional, ADR-0046 D3), HoldPkg, then each case's name and
# protection, in order.
V=/src/tests/fixtures/store/removal-vectors.json
array() { sed -n "/\"$1\": \[/,/\]/p" "$V" | grep -o '"[^"]*"' | tr -d '"' | grep -vx "$1"; }
mapfile -t vnames < <(sed -n '/"cases"/,$p' "$V" | grep -o '"name": "[^"]*"' | sed 's/.*: "//; s/"$//')
mapfile -t vwants < <(sed -n '/"cases"/,$p' "$V" | grep -o '"protection": "[^"]*"' | sed 's/.*: "//; s/"$//')
{
  echo 'declare -A omarchy_lists=() hold=() gfopt=()'
  for n in $(array gfOptional); do echo "gfopt[$n]=1"; done
  for n in $(array omarchyLists); do echo "omarchy_lists[$n]=1"; done
  for n in $(array holdPkg); do echo "hold[$n]=1"; done
  cat "$T/run-denied"
} >"$T/denied-vectors.sh"
# shellcheck disable=SC1091 # made just above
source "$T/denied-vectors.sh"
mismatches=0
for i in "${!vnames[@]}"; do
  want=denied
  [[ ${vwants[$i]} == none ]] && want=allowed
  if denied "${vnames[$i]}"; then got=denied; else got=allowed; fi
  [[ $got == "$want" ]] || { echo "MISMATCH ${vnames[$i]}: $got, the vectors say ${vwants[$i]}"; mismatches=$((mismatches + 1)); }
done
expect "the vectors (${#vnames[@]} of them, ${#vwants[@]} answers): $mismatches mismatches" \
  test "${#vnames[@]}:${#vwants[@]}:$mismatches" == "${#vwants[@]}:${#vnames[@]}:0"
expect "  every one read (more than 40)" test "${#vnames[@]}" -gt 40

say "result"
if ((fails)); then echo "$fails FAIL"; tail -20 /tmp/run.out; exit 1; fi
echo "all PASS"
