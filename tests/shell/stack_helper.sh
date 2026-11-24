#!/bin/bash
# grassfield-stack-helper (ADR-0025) as a process: the line protocol, the watch, and what the review of round 7 found. Prints PASS or
# FAIL lines; exits 1 on any FAIL. Builds the helper with apps/stack-helper/build-direct.sh when .dev/build has none.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
bin=${GRASSFIELD_STACK_HELPER:-$root/.dev/build/grassfield-stack-helper}
if [[ ! -x $bin ]]; then
  "$root/apps/stack-helper/build-direct.sh" >/dev/null 2>&1 || { echo "FAIL stack_helper: the helper does not build"; exit 1; }
fi
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/stack-helper.XXXXXX")
fail=0
pids=()
cleanup() {
  local p
  for p in "${pids[@]}"; do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  exec 9>&- 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

check() { # <what> <want> <got>
  if [[ $2 == "$3" ]]; then echo "PASS stack_helper: $1"; else echo "FAIL stack_helper: $1: wanted [$2], got [$3]"; fail=1; fi
}
ok() { # <what> <command...>: PASS when the command succeeds
  local what=$1
  shift
  if "$@"; then echo "PASS stack_helper: $what"; else echo "FAIL stack_helper: $what"; fail=1; fi
}

# names of the last W line of <out>, joined by "|"
names() {
  awk 'BEGIN { FS = "\037" } /^W\037/ { last = $0 } END {
    if (last == "") exit
    n = split(last, f, "\037"); c = f[4]; s = ""
    for (i = 0; i < c; i++) s = s (i ? "|" : "") f[5 + i * 5]
    print s }' "$1"
}
total() { awk 'BEGIN { FS = "\037" } /^W\037/ { t = $3 } END { print t }' "$1"; }
count() { awk 'BEGIN { FS = "\037" } /^W\037/ { n = $4 } END { print n + 0 }' "$1"; }
now_ms() { echo $(($(date +%s%N) / 1000000)); }
# waits (at most <seconds>) until <test> is true; prints the milliseconds it took, or "never"
waitfor() { # <seconds> <command...>
  local limit=$1 start i
  shift
  start=$(now_ms)
  for ((i = 0; i < limit * 50; i++)); do
    if "$@" >/dev/null 2>&1; then echo $(($(now_ms) - start)); return; fi
    sleep 0.02
  done
  echo never
}
# conditions for waitfor: read the output again at every look (a $(...) in waitfor's arguments is read once, before it waits)
count_is() { [[ $(count "$1") == "$2" ]]; }
total_is() { [[ $(total "$1") == "$2" ]]; }
first_is() { [[ $(names "$1" | cut -d'|' -f1) == "$2" ]]; }
first_isnt() { [[ $(names "$1" | cut -d'|' -f1) != "$2" ]]; }
names_is() { [[ $(names "$1") == "$2" ]]; }
has_name() { names "$1" | tr '|' '\n' | grep -a -x -q -F -- "$2"; }
no_name() { ! has_name "$1" "$2"; }
has_line() { grep -a -q -x -e "$2" "$1"; }

# starts a helper: <dir> <sort> <K> <label>; sets $out, $hpid; commands go to fd 9
start() {
  local dir=$1 sort=$2 k=$3 label=$4
  out=$tmp/$label.out
  fifo=$tmp/$label.in
  : >"$out"
  rm -f "$fifo"
  mkfifo "$fifo"
  exec 9<>"$fifo"
  "$bin" "$dir" "$sort" "$k" <&9 >"$out" 2>/dev/null &
  hpid=$!
  pids+=("$hpid")
}
stop() { echo QUIT >&9; exec 9>&-; wait "$hpid" 2>/dev/null; }

# ---- the start, the order, the commands ----
d=$tmp/a
mkdir "$d"
for n in file10 file2 File1 Zebra apple Apple 10 9; do : >"$d/$n"; done
: >"$d/.hidden"
start "$d" name 30 a
t=$(waitfor 3 has_line "$out" A)
ok "the watch is armed at the start (A)" test "$t" != never
t=$(waitfor 3 names_is "$out" "9|10|Apple|apple|File1|file2|file10|Zebra")
check "Name order is Files' order, hidden names skipped" "9|10|Apple|apple|File1|file2|file10|Zebra" "$(names "$out")"
check "the total counts the entries" 8 "$(total "$out")"
nice=$(awk '{ print $19 }' "/proc/$hpid/stat")
ok "runs at a lower priority (nice $nice, 10 at least)" test "$nice" -ge 10

: >"$d/0new"
s=$(now_ms)
t=$(waitfor 3 has_name "$out" 0new)
ok "a created name is shown within 1 s (${t} ms)" test "$t" != never -a "${t:-9999}" -lt 1000
check "it is first" "0new" "$(names "$out" | cut -d'|' -f1)"
rm "$d/0new"
t=$(waitfor 3 no_name "$out" 0new)
ok "a removed name leaves the window (${t} ms)" test "$t" != never

echo "K 3" >&9
t=$(waitfor 3 count_is "$out" 3)
check "K 3 shrinks the window" 3 "$(count "$out")"
echo "K 30" >&9
t=$(waitfor 3 count_is "$out" 8)
check "K 30 widens it again from a scan" 8 "$(count "$out")"
echo "SORT kind" >&9
t=$(waitfor 3 first_isnt "$out" 9)
ok "SORT kind re-orders (no extension: by name)" test "$t" != never -o "$(names "$out")" = "9|10|Apple|apple|File1|file2|file10|Zebra"
stop

# ---- names that cannot forge a record, names that are not UTF-8, links, ties ----
d=$tmp/b
mkdir "$d"
printf -v forged 'x\nW\037%s\037%s\037%s' 1 1 evil
: >"$d/$forged"
: >"$d/back\\slash"
: >"$d/$(printf 'caf\xe9.txt')"
: >"$d/plain"
mkdir "$d/Sub"
ln -s Sub "$d/linkto"
ln -s nowhere "$d/broken"
start "$d" name 30 b
t=$(waitfor 3 count_is "$out" 7)
check "all seven entries listed" 7 "$(count "$out")"
bad=$(awk 'BEGIN { FS = "\037" } !/^(A|G)$/ && !/^W\037/ { c++ } END { print c + 0 }' "$out")
check "no line but A, G and W: a name cannot forge a record" 0 "$bad"
fields=$(awk 'BEGIN { FS = "\037" } /^W\037/ { n = NF } END { print n }' "$out")
check "the fields are counted by US only (4 + 5 x 7)" 39 "$fields"
# Its byte that is not UTF-8 is written as \xHH, so the name can be told back byte for byte (audit F22, StackLogic::escapeName).
ok "a name that is not UTF-8 is listed, its byte 0xe9 as \\xe9" grep -a -q -F 'caf\xe9.txt' "$out"
isdir=$(awk 'BEGIN { FS = "\037" } /^W\037/ { last = $0 } END { n = split(last, f, "\037"); for (i = 0; i < f[4]; i++) if (f[5 + i * 5] == "linkto" || f[5 + i * 5] == "broken") printf "%s", f[6 + i * 5] }' "$out")
check "links are not followed (items, not folders)" "00" "$isdir"
stop

d=$tmp/c
mkdir "$d"
for n in c b a; do : >"$d/$n"; touch -d '2020-01-01 00:00:00' "$d/$n"; done
: >"$d/z"
touch -d '2021-01-01 00:00:00' "$d/z"
start "$d" dateModified 30 c
t=$(waitfor 3 count_is "$out" 4)
check "dates newest first, ties by name" "z|a|b|c" "$(names "$out")"
stop

# ---- the race of the review: the window is refilled from the files that are left ----
d=$tmp/d
mkdir "$d"
mapfile -t all < <(seq -f 'f%04g' 1 2010)
(cd "$d" && printf '%s\0' "${all[@]}" | xargs -0 touch)
i=0
for n in $(seq -f 'f%04g' 1981 2010); do touch -d "@$((2000000000 + i))" "$d/$n"; i=$((i + 1)); done
start "$d" dateModified 30 d
t=$(waitfor 5 count_is "$out" 30)
check "2,010 files: a full window" 30 "$(count "$out")"
check "the newest is shown first" f2010 "$(names "$out" | cut -d'|' -f1)"
for n in $(seq -f 'f%04g' 1981 2010); do rm "$d/$n"; done
s=$(now_ms)
t=$(waitfor 8 no_name "$out" f2010)
ok "after deleting the 30 newest the window is refilled (${t} ms)" test "$t" != never -a "${t:-99999}" -lt 4000
check "the refilled window is full" 30 "$(count "$out")"
check "total follows" 1980 "$(total "$out")"
stop

# ---- the review's repro (round 8): files that are created under a temporary name and renamed within one batch ----
# 10 files, 40 downloads (temporary name, then the real one), then the 30 shown files deleted: the helper's count was 10 instead of 50
# and the window stayed empty with 20 files left
d=$tmp/r8
mkdir "$d"
for i in $(seq 0 9); do : >"$d/seed$i.txt"; touch -d "@$((1700000000 + i * 100))" "$d/seed$i.txt"; done
start "$d" dateModified 30 r8
t=$(waitfor 3 count_is "$out" 10)
for i in $(seq 0 39); do : >"$d/dl$i.crdownload"; mv "$d/dl$i.crdownload" "$d/dl$i.bin"; done
t=$(waitfor 8 first_is "$out" dl39.bin)
check "round 8: 50 files after the downloads, a window of 30" 30 "$(count "$out")"
shown=$(names "$out" | tr '|' '\n')
while IFS= read -r n; do rm -f "$d/$n"; done <<<"$shown"
t=$(waitfor 8 count_is "$out" 20)
check "round 8: the 30 shown files deleted, 20 are left and all show" 20 "$(count "$out")"
short=$(awk 'BEGIN { FS = "\037" } /^W\037/ { if ($4 >= 30) full = 1; else if (full && $4 < 7) c++ } END { print c + 0 }' "$out")
check "round 8: no window shorter than 7 (half of low, 15 for K 30: what the margin guarantees) was written once a full one had been" 0 "$short"
stop

# ---- a folder's own date follows what is created in it (round 9): the sub-folders are watched in the date orders ----
d=$tmp/sub
mkdir -p "$d/Projects"
sleep 0.3
for i in $(seq 1 40); do : >"$d/f$i"; done
start "$d" dateModified 30 sub
t=$(waitfor 5 count_is "$out" 30)
first=$(names "$out" | cut -d'|' -f1)
ok "round 9: the old sub-folder is not in the window of the 30 newest" test "$first" != Projects
: >"$d/Projects/new.txt"
t=$(waitfor 5 first_is "$out" Projects)
ok "round 9: a file created in the sub-folder moves it to the top (${t} ms)" test "$t" != never
stop

# ---- the kernel's queue overflows: one scan, not a stale window ----
d=$tmp/e
mkdir "$d"
: >"$d/m1"
start "$d" name 30 e
t=$(waitfor 3 count_is "$out" 1)
kill -STOP "$hpid"
(cd "$d" && seq -f 'zz%06g' 1 24000 | xargs touch)
: >"$d/0first"
kill -CONT "$hpid"
t=$(waitfor 8 has_name "$out" 0first)
ok "after an overflow the window is right (0first in, ${t} ms)" test "$t" != never
t=$(waitfor 5 total_is "$out" 24002)
check "and the total is exact" 24002 "$(total "$out")"
stop

# ---- the folder deleted and made again ----
d=$tmp/f
mkdir "$d"
: >"$d/one"
start "$d" name 30 f
t=$(waitfor 3 count_is "$out" 1)
rm -rf "$d"
t=$(waitfor 4 has_line "$out" G)
ok "a deleted folder is reported (G, ${t} ms)" test "$t" != never
mkdir "$d"
: >"$d/two"
t=$(waitfor 25 has_name "$out" two)
ok "a folder made again is watched and listed again (${t} ms)" test "$t" != never
check "the new content only" "two" "$(names "$out")"
stop

# ---- death with the parent ----
d=$tmp/g
mkdir "$d"
: >"$d/one"
mkfifo "$tmp/g.in"
cat >"$tmp/parent.sh" <<EOF
#!/bin/bash
exec 9<>"$tmp/g.in"
"$bin" "$d" name 30 <&9 >"$tmp/g.out" 2>/dev/null &
echo \$! >"$tmp/g.pid"
wait
EOF
chmod +x "$tmp/parent.sh"
"$tmp/parent.sh" &
parent=$!
pids+=("$parent")
t=$(waitfor 3 test -s "$tmp/g.pid")
child=$(cat "$tmp/g.pid")
pids+=("$child")
t=$(waitfor 3 grep -a -q '^W' "$tmp/g.out")
ok "the helper runs under its parent" kill -0 "$child"
kill -9 "$parent"
wait "$parent" 2>/dev/null
t=$(waitfor 3 bash -c "! kill -0 $child 2>/dev/null")
ok "it dies with its parent (${t} ms)" test "$t" != never
# ... and when the parent is already gone before the helper looks (exec and loading take a moment, and the signal is never sent to a
# process whose parent died first), or dies right after. The orphan is adopted by something that is not PID 1 (a subreaper, a user
# manager, a container's init), so the helper cannot tell by getppid() alone: the shell names itself in
# GRASSFIELD_STACK_HELPER_PARENT. Its stdin is held open explicitly (a pipe whose writer this test keeps; a background command of
# a non-interactive shell would get /dev/null and end on end of file, which proves nothing), so only the parent's death can stop
# it. Four cases, 3 tries each: the parent killed before / after the helper started, under a subreaper (this test's python) and
# without one (the system's adopter). Each helper must be gone within 3 s.
survivors=$(python3 -I - "$bin" "$d" <<'PY'
import ctypes, os, select, signal, sys, time
bin_, folder = sys.argv[1], sys.argv[2]
rfd, wfd = os.pipe()  # the helper's stdin: this test holds the writer, nobody writes
outr, outw = os.pipe()  # its stdout


def alive(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(") ", 1)[1][0] not in "ZX"
    except OSError:
        return False


def one(subreaper, kill):
    go_r, go_w = os.pipe()
    pid_r, pid_w = os.pipe()
    p = os.fork()
    if p == 0:  # the parent: starts the helper's process, names itself
        os.environ["GRASSFIELD_STACK_HELPER_PARENT"] = str(os.getpid())
        c = os.fork()
        if c == 0:
            os.read(go_r, 1)  # the exec happens when the test says so
            os.dup2(rfd, 0)
            os.dup2(outw, 1)
            os.execv(bin_, [bin_, folder, "name", "30"])
        os.write(pid_w, b"%d\n" % c)
        time.sleep(60)
        os._exit(0)
    child = int(os.read(pid_r, 32))
    if kill == "before":
        os.kill(p, signal.SIGKILL)
        os.waitpid(p, 0)
        os.write(go_w, b"x")
    else:
        os.write(go_w, b"x")
        ready, _, _ = select.select([outr], [], [], 5)
        if ready:
            os.read(outr, 4096)  # the helper is running: it armed its watch
        os.kill(p, signal.SIGKILL)
        os.waitpid(p, 0)
    deadline = time.time() + 3
    while time.time() < deadline:
        if subreaper:
            try:
                os.waitpid(child, os.WNOHANG)
            except ChildProcessError:
                pass
        if not alive(child):
            return 0
        time.sleep(0.05)
    os.kill(child, signal.SIGKILL)
    return 1


left = 0
for subreaper in (False, True):
    if subreaper:
        ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER
    for kill in ("before", "after"):
        for _ in range(3):
            left += one(subreaper, kill)
print(left)
PY
)
ok "a helper whose parent ended before or after its start dies too, adopted by a subreaper or not (${survivors} of 12 left running)" test "$survivors" = 0
# ... and when its stdin is closed (the pipe's writer, a sleep, ends after a second)
sleep 1 | "$bin" "$d" name 30 >"$tmp/h.out" 2>/dev/null &
t=$(waitfor 3 grep -a -q '^W' "$tmp/h.out")
hp=$(pgrep -n -f "$bin $d name 30")
t=$(waitfor 4 bash -c "! kill -0 $hp 2>/dev/null")
ok "it ends when the shell closes its stdin (${t} ms)" test "$t" != never

# ---- a file system mounted over the stack folder (round 8): inotify says nothing, the folder's identity does ----
# a bind mount in a private user and mount namespace; the identity of a quiet folder is looked at every 30 s, so this takes up to 35 s
d=$tmp/mnt
mkdir -p "$d/stack" "$d/other"
: >"$d/stack/before1"
: >"$d/other/after1"
: >"$d/other/after2"
cat >"$tmp/mnt.sh" <<EOF
#!/bin/bash
"$bin" "$d/stack" name 30 <&9 >"$tmp/mnt.out" 2>/dev/null &
sleep 1
mount --bind "$d/other" "$d/stack" || exit 3
for i in \$(seq 1 175); do
  grep -a -q after1 "$tmp/mnt.out" && break
  sleep 0.2
done
kill %1 2>/dev/null
EOF
chmod +x "$tmp/mnt.sh"
mkfifo "$tmp/mnt.in"
exec 9<>"$tmp/mnt.in"
if unshare -rm "$tmp/mnt.sh" 2>/dev/null; then
  exec 9>&-
  mnames=$(awk 'BEGIN { FS = "\037" } /^W\037/ { last = $0 } END { n = split(last, f, "\037"); s = ""; for (i = 0; i < f[4]; i++) s = s (i ? "|" : "") f[5 + i * 5]; print s }' "$tmp/mnt.out")
  check "a file system mounted over the folder is listed (within the 30 s identity check)" "after1|after2" "$mnames"
else
  exec 9>&-
  echo "SKIP stack_helper: mount over the folder not run (no user and mount namespaces here)"
fi

# ---- a missing folder and bad arguments ----
"$bin" /nonexistent/stack/helper/folder name 30 </dev/null >"$tmp/m.out" 2>/dev/null &
mp=$!
pids+=("$mp")
t=$(waitfor 3 has_line "$tmp/m.out" G)
ok "a folder that is not there is reported (G)" test "$t" != never
kill "$mp" 2>/dev/null
"$bin" relative name 30 </dev/null >/dev/null 2>&1
check "a relative path is refused" 2 "$?"
"$bin" "$tmp" size 30 </dev/null >/dev/null 2>&1
check "an unknown order is refused" 2 "$?"

exit $fail
