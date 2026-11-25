#!/bin/bash
# What a watched stack folder costs (shell/dock/StackWatch.qml over grassfield-stack-helper, ADR-0025). Post-merge reviews: Qt's
# FolderListModel rescanned the whole folder on every change; one line per event kept the GUI thread busy for seconds in a burst; a
# watcher that read the events in bash cost 1,718 CPU ticks for one burst; round 7 of the counter-review found the bash/awk pipeline
# unable to bound its work (300 files every 5.5 s into 60,000 were a storm each time; a burst took 3 to 5 s at 5,000 names; the popup
# of 100,000 names was blank for 25 to 48 s). The real component and the real helper watch folders of 340 to 100,000 entries while
# files are created, renamed, deleted, streamed and dropped in batches by programs outside the shell.
#  - CPU: the shell, every helper it has finished (cutime, cstime) and the helper still running, in ticks (1/100 s), from 0.5 s
#    after the first window to the end of the case; counted above an idle run (the machine's rate of an idle shell with its helper);
#  - memory: the growth of the shell over the same stretch (a reading that cannot be taken is skipped, never counted as 0); for the
#    memory case the baseline is a warm shell (its helper has run on a small folder), then Kind order on 60,000 names, the pile and the
#    popup, and a gc;
#  - GUI: how late the 5 ms ticks of the GUI thread came (longest wait and total), over the same stretch;
#  - latencies from the guard's "TOP <epoch ms> <names>" lines: 150 files, a burst of 20,000, 300 files dropped every 5.5 s into
#    60,000, the refill after the 30 shown files are deleted, the open popup (300 entries) on a folder of 100,000, and the longest
#    time between two changes of the pile in an endless stream (the tail included);
#  - the pile must be right at the end: the first three of a full sort made here with find and sort, independently of the helper.
# The CPU and latency budgets are the targets of ADR-0025; the timing gates (latency, GUI waits) are load-sensitive: above the number
# of cores, and on a shared CI runner, they are reported (SKIP), not enforced. Plain shell test.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
helper=${GRASSFIELD_STACK_HELPER:-$root/.dev/build/grassfield-stack-helper}
[[ -x $helper ]] || apps/stack-helper/build-direct.sh >/dev/null
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/stack-cost.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runtime" "$tmp/cache" "$tmp/cfg"
chmod 700 "$tmp/runtime" "$tmp/cache"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/stack_watch_cost.d/guard.qml "$tmp/cfg/shell.qml"

fill() { # <entries>: the folder, made once; what an earlier run created is removed
  local dir=$tmp/dir$1
  if [[ ! -d $dir ]]; then
    mkdir -p "$dir"
    (cd "$dir" && seq 1 "$1" | sed 's/^/file/' | xargs touch)
  fi
  find "$dir" -maxdepth 1 \( -name 'new*' -o -name 'burst*' -o -name 'moved*' -o -name '0lat*' -o -name '0p[0-9]*' -o -name '0r[0-9]*' \) -delete
}

# CPU ticks of a process, its reaped children and, recursively, its running descendants
tree_ticks() {
  local p=$1 t c
  t=$(awk '{ print $14 + $15 + $16 + $17 }' "/proc/$p/stat" 2>/dev/null || true)
  t=${t:-0}
  for c in $(pgrep -P "$p" 2>/dev/null || true); do
    t=$((t + $(tree_ticks "$c")))
  done
  echo "$t"
}

# the same, told apart: the shell itself, the helpers it has finished, the helper still running
ticks_parts() {
  local p=$1 self kids live=0 c
  read -r self kids < <(awk '{ print $14 + $15, $16 + $17 }' "/proc/$p/stat" 2>/dev/null || echo "0 0")
  for c in $(pgrep -P "$p" 2>/dev/null || true); do live=$((live + $(tree_ticks "$c"))); done
  echo "shell $self, finished helpers $kids, running helper $live"
}

rss() { awk '/^VmRSS:/ { print $2 }' "/proc/$1/status" 2>/dev/null || true; }
# the RSS (kB) of the helper, the largest child of <pid>
helper_rss() {
  local c r m=0
  for c in $(pgrep -P "$1" 2>/dev/null || true); do
    r=$(rss "$c")
    [[ -n $r ]] && ((r > m)) && m=$r
  done
  echo "$m"
}
now_ms() { echo $(($(date +%s%N) / 1000000)); }
now_epoch_ms() { date +%s%3N; }

# the burst: 20,000 creates, 2,000 renames, 2,000 deletes, as fast as a program can
burst() { # <dir>
  python3 - "$1" <<'PY'
import os, sys
d = sys.argv[1]
for i in range(1, 20001):
    open(os.path.join(d, "burst%d" % i), "w").close()
for i in range(1, 2001):
    os.rename(os.path.join(d, "burst%d" % i), os.path.join(d, "moved%d" % i))
for i in range(2001, 4001):
    os.unlink(os.path.join(d, "burst%d" % i))
PY
}

# a stream: `per` files at once every `step` seconds for `secs` seconds (what a download manager, a build or a sync tool does)
stream() { # <dir> <per> <step> <secs>
  python3 - "$@" <<'PY'
import os, sys, time
d, per, step, secs = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
start = time.time()
nxt = start
i = 0
while time.time() - start < secs:
    for _ in range(per):
        i += 1
        open(os.path.join(d, "burst%d" % i), "w").close()
    nxt += step
    delay = nxt - time.time()
    if delay > 0:
        time.sleep(delay)
PY
}

# the time (epoch ms) of the first change of the pile at or after <ms> whose names match <regex>, or nothing
top_after() { # <log> <ms> <regex>
  { grep -a "TOP " "$1" | sed 's/.*TOP //' | awk -v e="$2" -v p="$3" '$1 >= e && $2 ~ p { print $1; exit }'; } || true
}

# the first three of a full sort of the folder, made here with find and sort, independently of the helper
fullsort_want() { # <entries> <sort> <mode>
  local n=$1 sort=$2 mode=$3 w
  case $sort in
    name | kind) w=$(cd "$tmp/dir$n" && find . -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%f\n' | LC_ALL=C sort -V | sed -n 1,3p | paste -sd,) ;;
    *) w=$(cd "$tmp/dir$n" && find . -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%C@\t%f\n' | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2V | sed -n 1,3p | cut -f2 | paste -sd,) ;;
  esac
  if [[ $mode == creates && ($sort == dateAdded || $sort == dateModified) ]]; then w=new10,new9,new8; fi
  echo "$w"
}

# 300 files every 5.5 s, six times (what a tool that drops files in batches does), then the settle
pulsecase() { # <pid> <entries>
  sleep 0.5
  : >"$tmp/pulses"
  local r
  for r in 1 2 3 4 5 6; do
    echo "$r $(now_epoch_ms)" >>"$tmp/pulses"
    (cd "$tmp/dir$2" && seq 1 300 | sed "s/^/0p${r}_/" | xargs touch)
    sleep 5.5
  done
  t_mid=$(($(tree_ticks "$1") - t0))
  ms_mid=$(($(now_ms) - t_start))
  sleep 6
  touch "$tmp/done"
}

# 150 files at once (lat) or 20,000 (latburst): when does the pile show them?
latcase() { # <pid> <entries> <count>
  sleep 0.5
  lat_start=$(now_epoch_ms)
  (cd "$tmp/dir$2" && seq 1 "$3" | sed 's/^/0lat/' | xargs touch)
  lat_end=$(now_epoch_ms)
  sleep $(($3 > 1000 ? 12 : 6))
  touch "$tmp/done"
}

# the 30 files the pile is made of are deleted (30 new files that come first in every order, shown, then removed): when does the
# pile show the files that follow them?
refillcase() { # <pid> <entries>
  sleep 0.5
  (cd "$tmp/dir$2" && seq -f '0r%02g' 1 30 | xargs touch)
  sleep 4
  ref_start=$(now_epoch_ms)
  (cd "$tmp/dir$2" && seq -f '0r%02g' 1 30 | xargs rm)
  ref_end=$(now_epoch_ms)
  sleep $(($2 >= 100000 ? 12 : 6))
  touch "$tmp/done"
}

# a browser download every 2 s for 60 s: a visible temporary name, then the real one (the case the margin is for: a removal in the window)
dlcase() { # <pid> <entries>
  sleep 0.5
  local i
  for i in $(seq 1 30); do
    (cd "$tmp/dir$2" && : >"dl$i.part" && mv "dl$i.part" "dl$i.bin")
    sleep 2
  done
  t_mid=$(($(tree_ticks "$1") - t0))
  ms_mid=$(($(now_ms) - t_start))
  sleep 6
  touch "$tmp/done"
}

# the shown (newest) file deleted every second for 40 s: each deletion is a removal inside the window
delcase() { # <pid> <entries>
  sleep 0.5
  local i
  for i in $(seq 0 39); do
    rm -f "$tmp/dir$2/file$(($2 - i))"
    sleep 1
  done
  t_mid=$(($(tree_ticks "$1") - t0))
  ms_mid=$(($(now_ms) - t_start))
  sleep 6
  touch "$tmp/done"
}

# the folder is kept between cases: the files delcase deleted are made again once the pile has been checked
delrestore() { # <entries>
  local i
  for i in $(seq 0 39); do : >"$tmp/dir$1/file$(($1 - i))"; done
}

# A stream (`per` files at once every `step` s for `secs` s), then `settle` s: the CPU is read when the stream ends, apart from the
# settle (t_mid, ms_mid since 0.5 s after the first window)
streamcase() { # <pid> <entries> <per> <step> <secs> <settle>
  sleep 0.5
  stream "$tmp/dir$2" "$3" "$4" "$5"
  t_mid=$(($(tree_ticks "$1") - t0))
  ms_mid=$(($(now_ms) - t_start))
  sleep "$6"
  touch "$tmp/done"
}

# run <entries> <sort> <mode: creates|idle|burst|s200|s500|s700|s1000|s2000|sendless|pulse|lat|latburst|refill|popup|mem>
# -> sets t, ms, t_mid, ms_mid (the stream alone), growth, block_max, block_total, hrss, log
run() {
  local n=$1 sort=$2 mode=$3 pid t0 t1 r0 r1 r h t_start t_end gmode=wait
  t_mid=0
  ms_mid=0
  hrss=0
  log=$tmp/log$n$sort$mode
  rm -f "$tmp/done"
  [[ $mode == creates ]] && gmode=creates
  [[ $mode == popup ]] && gmode=popup
  [[ $mode == mem ]] && gmode=mem
  local dir=$tmp/dir$n big=""
  fill "$n"
  if [[ $mode == mem ]]; then
    # the warm baseline: a small folder first, the big one after the baseline was read
    big=$dir
    fill 40
    dir=$tmp/dir40
  fi
  env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_SESSION GRASSFIELD_DEV=1 GRASSFIELD_STACK_HELPER="$helper" GF_STACK_DIR="$dir" GF_BIG_DIR="$big" GF_SORT="$sort" GF_MODE="$gmode" GF_DONE_FILE="$tmp/done" QT_QPA_PLATFORM=offscreen \
    QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
    qs -p "$tmp/cfg" --no-color >"$log" 2>&1 &
  pid=$!
  until grep -q READY "$log" 2>/dev/null; do sleep 0.1; done
  if [[ $mode == mem ]]; then
    until grep -q BASE "$log" 2>/dev/null; do sleep 0.1; done
  fi
  sleep 0.5
  t_start=$(now_ms)
  t_start_ms=$(now_epoch_ms)
  t0=$(tree_ticks "$pid")
  r0=$(rss "$pid")
  r1=$r0
  case $mode in
    burst)
      # one second after the first window, the burst; then the time to settle, whatever the machine's load made the burst last
      sleep 0.5
      burst "$dir"
      sleep 8
      touch "$tmp/done"
      ;;
    s200) streamcase "$pid" "$n" 20 0.1 20 10 ;;
    s500) streamcase "$pid" "$n" 250 0.5 20 12 ;;
    s700) streamcase "$pid" "$n" 70 0.1 20 12 ;;
    s1000) streamcase "$pid" "$n" 100 0.1 20 12 ;;
    s2000) streamcase "$pid" "$n" 200 0.1 30 20 ;;
    sendless) streamcase "$pid" "$n" 200 0.1 40 20 ;;
    pulse) pulsecase "$pid" "$n" ;;
    lat) latcase "$pid" "$n" 150 ;;
    latburst) latcase "$pid" "$n" 20000 ;;
    refill) refillcase "$pid" "$n" ;;
    dl) dlcase "$pid" "$n" ;;
    del) delcase "$pid" "$n" ;;
    popup | mem)
      sleep 16
      touch "$tmp/done"
      ;;
    idle)
      sleep 10
      touch "$tmp/done"
      ;;
  esac
  until grep -q BLOCK "$log" 2>/dev/null; do
    sleep 0.2
    r=$(rss "$pid")
    [[ -n $r ]] && r1=$r
    h=$(helper_rss "$pid")
    ((h > hrss)) && hrss=$h
  done
  sleep 1
  r=$(rss "$pid")
  [[ -n $r ]] && r1=$r
  h=$(helper_rss "$pid")
  ((h > hrss)) && hrss=$h
  t1=$(tree_ticks "$pid")
  parts=$(ticks_parts "$pid")
  t_end=$(now_ms)
  wait "$pid" 2>/dev/null || true
  t=$((t1 - t0))
  ms=$((t_end - t_start))
  growth=$((r1 - r0))
  rss_first=$r0
  rss_last=$r1
  block_max=$(sed -n 's/.*BLOCK max=\([0-9]*\) .*/\1/p' "$log")
  block_total=$(sed -n 's/.*BLOCK max=[0-9]* total=\([0-9]*\).*/\1/p' "$log")
}

# Budgets of the streams, CPU ticks per second above idle DURING the stream (percent of one core; shell and helper). The model: a Dock
# stack is a passive indicator and must stay a small share of a core however the folder is written to. The helper keeps a window of
# 30 names: a name that sorts after it costs one comparison, a removal inside it a scan at most once a second.
SB200=${SB200:-10}
SB500=${SB500:-12}
SB700=${SB700:-12}
SB1000=${SB1000:-12}
SB2000=${SB2000:-15}
SBendless=${SBendless:-15}
SBPULSE=${SBPULSE:-3}
# a browser download every 2 s, a shown file deleted every second: removals inside the window, taken by the margin (the review
# measured 7 ticks/s at 10,000 names and 23/s at 100,000 when each removal was a scan)
SBDL=${SBDL:-3}
# (a scan of 100,000 names is 1.4 CPU seconds, one every 25 deletions of the pile's 30: 4 ticks a second at one deletion a second)
SBDEL=${SBDEL:-5}
# latencies (ms, wall clock): a change of up to 150 files shows within a second (and the time of the script's own work); a burst within
# 2.5 s of its end (8 s for the folder of 100,000 names); during an endless stream the pile is refreshed at least every 15 s; the
# 30 shown files deleted are replaced within 3 s (8 s at 100,000); the open popup shows within the burst target of its folder
LAT150=${LAT150:-1500}
LATBURST=${LATBURST:-2500}
LATBURST100K=${LATBURST100K:-8000}
LATREFILL=${LATREFILL:-3000}
LATREFILL100K=${LATREFILL100K:-8000}
ENDLESSGAP=${ENDLESSGAP:-15000}
# memory kept after Kind order on 60,000 names (the pile and the popup), MB, against a warm baseline (after gc)
MEMKEEP=${MEMKEEP:-20}
# the timing gates (latencies, GUI waits) are load-sensitive: above the number of cores they are reported, not enforced
cores=$(nproc)
load=$(cut -d' ' -f1 /proc/loadavg)
loaded=0
(( ${load%.*} > cores )) && loaded=1
[[ $loaded == 1 ]] && echo "cost: load $load is above the $cores cores: the timing gates (latency, GUI waits) are reported, not enforced (SKIP)"
# A shared CI runner (CI=true, GITHUB_ACTIONS=true and RUNNER_TEMP, all three: docs/testing/README.md) is never a quiet machine:
# a neighbour's stall of a tenth of a second passes under the load average (PR #53 run 45508983190: one 146 ms GUI wait, green on
# the rerun). There the wall-clock gates are reported, not enforced; the CPU-tick budgets and memory still are.
shared_runner=0
[[ ${CI:-} == true && ${GITHUB_ACTIONS:-} == true && -n ${RUNNER_TEMP:-} ]] && shared_runner=1
[[ $shared_runner == 1 ]] && echo "cost: a shared CI runner: the timing gates (latency, GUI waits) are reported, not enforced (SKIP)"
timing_fail() { # <message>: the load is read again, a run of half an hour sees other work start and stop
  local now
  now=$(cut -d' ' -f1 /proc/loadavg)
  if [[ $shared_runner == 1 ]]; then echo "SKIP (shared CI runner): $1"
  elif [[ $loaded == 1 ]] || (( ${now%.*} > cores )); then echo "SKIP (load $now): $1"
  else echo "FAIL: $1"; fail=1; fi
}
# no single wait of the GUI thread above this during any case (ms; LOAD-SENSITIVE, wall clock)
GUIWAIT=${GUIWAIT:-50}
fail=0
# what an idle shell with its helper costs: ticks per second. A reading below 20 ticks is a glitch of the sampling (a child that ended
# between the two readings takes its ticks with it): taken again, up to three times, never below zero
for _ in 1 2 3; do
  run 5000 dateAdded idle
  ((t >= 20)) && break
  echo "cost: idle: $t ticks is not a reading, again"
done
((t < 0)) && t=0
rate_milli=$((t * 1000000 / ms)) # milli-ticks per second
echo "cost: idle: $t ticks in $ms ms (shell, helper and the sampling itself), helper RSS $((hrss / 1024)) MB"
cases=("340 dateAdded creates" "5000 dateAdded creates" "5000 dateModified creates" "5000 name creates" "5000 kind creates" "5000 dateAdded burst" "5000 name burst" "5000 kind burst" "5000 dateAdded s200" "5000 dateAdded s500" "5000 dateAdded s700" "5000 dateAdded s1000" "5000 dateAdded s2000" "5000 name s700" "5000 name s2000" "60000 name pulse" "60000 dateAdded pulse" "5000 dateAdded lat" "100000 name lat" "100000 dateAdded lat" "5000 dateAdded latburst" "5000 name latburst" "5000 kind latburst" "100000 dateAdded latburst" "100000 name latburst" "5000 dateAdded refill" "5000 name refill" "100000 dateAdded refill" "100000 name refill" "5000 name popup" "5000 kind popup" "100000 name popup" "100000 dateAdded popup" "100000 kind popup" "5000 dateAdded sendless" "5000 name sendless" "10000 dateAdded dl" "10000 name dl" "100000 dateAdded del" "60000 kind mem")
# GF_CASES="5000 dateAdded burst;5000 name burst" runs only those (a development shortcut)
[[ -n ${GF_CASES:-} ]] && IFS=";" read -r -a cases <<<"$GF_CASES"
for case in "${cases[@]}"; do
  read -r n sort mode <<<"$case"
  run "$n" "$sort" "$mode"
  base=$((rate_milli * ms / 1000000))
  extra=$((t - base))
  ((extra < 0)) && extra=0
  what="10 creates"
  case $mode in
    burst) what="burst (20,000 creates, 2,000 renames, 2,000 deletes) and 8 s to settle" ;;
    s200) what="stream of 200 creates/s for 20 s (then 10 s to settle)" ;;
    s500) what="stream of 500 creates/s in bursts of 250 every 0.5 s for 20 s (then 12 s)" ;;
    s700) what="stream of 700 creates/s for 20 s (then 12 s)" ;;
    s1000) what="stream of 1,000 creates/s for 20 s (then 12 s)" ;;
    s2000) what="stream of 2,000 creates/s for 30 s (then 20 s)" ;;
    sendless) what="endless stream of 2,000 creates/s for 40 s (then 20 s)" ;;
    pulse) what="300 files every 5.5 s, six times (then 6 s)" ;;
    lat) what="150 files at once" ;;
    latburst) what="a burst of 20,000 files" ;;
    refill) what="the 30 shown files deleted" ;;
    dl) what="a browser download (temporary name, renamed) every 2 s for 60 s" ;;
    del) what="the newest file deleted every second for 40 s" ;;
    popup) what="the popup (300 entries) opened" ;;
    mem) what="Kind order on 60,000 names after a warm baseline" ;;
  esac
  # GF_KEEPLOG=<dir>: keep each case's log (the guard's TOP, POP and WAIT lines) for a look
  [[ -n ${GF_KEEPLOG:-} ]] && cp "$log" "$GF_KEEPLOG/"
  echo "cost: $n entries, $sort, $what -> $t CPU ticks in $ms ms ($extra above idle; shell and helper), RSS +$growth kB, helper RSS $((hrss / 1024)) MB, GUI blocked: longest $block_max ms, total $block_total ms; load $(cut -d' ' -f1 /proc/loadavg); [at the end, since the start of the shell: $parts] $(grep -h COST "$log" | sed 's/.*COST //')"
  # the pile (and, for the popup, its list) at the end is the first of a full sort: a correctness check, never load-sensitive
  want=""
  if [[ $mode != idle ]]; then
    want=$(fullsort_want "$n" "$sort" "$mode")
    if ! grep -q "top=$want\$" "$log"; then
      echo "FAIL: stack_watch_cost $n entries sorted by $sort, $what: the pile is not $want at the end ($(grep -h COST "$log" | sed 's/.*top=//'))"
      fail=1
    fi
  fi
  [[ $mode == del ]] && delrestore "$n"
  case $mode in
    pulse)
      # the CPU of a pulse: a few ticks a second above idle, and every pulse shown within a second
      stream_extra=$((t_mid - rate_milli * ms_mid / 1000000))
      ((stream_extra < 0)) && stream_extra=0
      echo "cost: $what in $n entries by $sort: $((stream_extra * 1000 / ms_mid)) ticks per second above idle during the pulses ($stream_extra in $ms_mid ms)"
      if ((stream_extra > SBPULSE * ms_mid / 1000 + 1)); then echo "FAIL: stack_watch_cost pulses in $n entries by $sort: $stream_extra ticks above idle in $ms_mid ms (limit $SBPULSE a second)"; fail=1; fi
      lim=1
      [[ $sort == dateAdded ]] && lim=6
      for ((r = 1; r <= lim; r++)); do
        st=$(awk -v r=$r '$1 == r { print $2 }' "$tmp/pulses")
        at=$(top_after "$log" "$st" "0p${r}_")
        if [[ -z $at ]]; then
          echo "FAIL: stack_watch_cost pulse $r of 300 files in $n entries by $sort never showed"
          fail=1
        elif ((at - st > LAT150)); then
          timing_fail "stack_watch_cost pulse $r of 300 files in $n entries by $sort shown after $((at - st)) ms (limit $LAT150)"
        else
          echo "cost: pulse $r of 300 files in $n entries by $sort shown after $((at - st)) ms"
        fi
      done
      if ((block_max > GUIWAIT)); then timing_fail "stack_watch_cost $what in $n entries by $sort: the GUI thread waited $block_max ms at once (limit $GUIWAIT)"; fi
      continue
      ;;
    lat | latburst)
      lim=$LAT150
      ref=$lat_start
      if [[ $mode == latburst ]]; then
        ref=$lat_end
        lim=$LATBURST
        ((n >= 100000)) && lim=$LATBURST100K
      fi
      # the pile is final at the LAST change that shows the new files (while a burst lasts the pile changes at every step)
      at=$(grep -a "TOP " "$log" | sed 's/.*TOP //' | awk -v e="$lat_start" '$1 >= e && $2 ~ /0lat/ { t = $1 } END { print t }') || true
      if [[ -z $at ]]; then
        echo "FAIL: stack_watch_cost $what in $n entries by $sort never showed"
        fail=1
      else
        d=$((at - ref))
        ((d < 0)) && [[ $mode == latburst ]] && d=0
        echo "cost: $what in $n entries by $sort shown $d ms after $([[ $mode == lat ]] && echo it began || echo its end) (limit $lim)"
        if ((d > lim)); then timing_fail "stack_watch_cost $what in $n entries by $sort shown after $d ms (limit $lim)"; fi
      fi
      if ((block_max > GUIWAIT)); then timing_fail "stack_watch_cost $what in $n entries by $sort: the GUI thread waited $block_max ms at once (limit $GUIWAIT)"; fi
      continue
      ;;
    refill)
      lim=$LATREFILL
      ((n >= 100000)) && lim=$LATREFILL100K
      at=$(top_after "$log" "$ref_start" "^file")
      if [[ -z $at ]]; then
        echo "FAIL: stack_watch_cost $what in $n entries by $sort: the pile never showed the files that follow"
        fail=1
      else
        d=$((at - ref_end))
        echo "cost: $what in $n entries by $sort: the pile was refilled $d ms after the deletes (limit $lim)"
        if ((d > lim)); then timing_fail "stack_watch_cost $what in $n entries by $sort: refilled after $d ms (limit $lim)"; fi
      fi
      if ((block_max > GUIWAIT)); then timing_fail "stack_watch_cost $what in $n entries by $sort: the GUI thread waited $block_max ms at once (limit $GUIWAIT)"; fi
      continue
      ;;
    popup)
      lim=$LATBURST
      ((n >= 100000)) && lim=$LATBURST100K
      ps=$(sed -n 's/^.*POPSTART \([0-9]*\).*/\1/p' "$log" | head -1) || true
      pa=$({ grep -a "POP " "$log" | grep -a -v POPSTART | sed 's/.*POP \([0-9]*\) \([0-9]*\).*/\1 \2/' | awk '$2 >= 300 { print $1; exit }'; } || true)
      # the last window the popup was given: its first three are the first of a full sort, and it holds 300 entries
      plast=$({ grep -a "POP " "$log" | grep -a -v POPSTART | tail -1 | sed 's/.*POP [0-9]* \([0-9]*\) \(.*\)/\1 \2/'; } || true)
      if [[ $plast != "300 $want" ]]; then
        echo "FAIL: stack_watch_cost $what in $n entries by $sort: the popup's last window is [$plast], not 300 entries starting $want"
        fail=1
      fi
      if [[ -z $ps || -z $pa ]]; then
        echo "FAIL: stack_watch_cost $what in $n entries by $sort: no window of 300 entries ever arrived"
        fail=1
      else
        d=$((pa - ps))
        echo "cost: $what in $n entries by $sort: shown $d ms after it was opened (limit $lim)"
        if ((d > lim)); then timing_fail "stack_watch_cost $what in $n entries by $sort shown after $d ms (limit $lim)"; fi
      fi
      if ((block_max > GUIWAIT)); then timing_fail "stack_watch_cost $what in $n entries by $sort: the GUI thread waited $block_max ms at once (limit $GUIWAIT)"; fi
      continue
      ;;
    mem)
      echo "cost: $what: the shell kept $((growth / 1024)) MB (limit $MEMKEEP MB; $((rss_first / 1024)) MB resident at the warm baseline, $((rss_last / 1024)) MB at the end), the helper $((hrss / 1024)) MB"
      if ((growth > MEMKEEP * 1024)); then echo "FAIL: stack_watch_cost $what: the shell kept $((growth / 1024)) MB (limit $MEMKEEP)"; fail=1; fi
      if ((hrss > 51200)); then echo "FAIL: stack_watch_cost $what: the helper holds $((hrss / 1024)) MB (limit 50)"; fail=1; fi
      continue
      ;;
  esac
  limit=60
  [[ $mode == burst ]] && limit=200
  if [[ $mode == s* ]]; then
    # a stream is budgeted per second of the stream alone; the settle after it is told apart
    sb=SB${mode#s}
    stream_extra=$((t_mid - rate_milli * ms_mid / 1000000))
    ((stream_extra < 0)) && stream_extra=0
    settle_extra=$((extra - stream_extra))
    ((settle_extra < 0)) && settle_extra=0
    srate=$((stream_extra * 1000 / ms_mid))
    echo "cost: $what: $srate ticks per second above idle during the stream ($stream_extra in $ms_mid ms), then $settle_extra ticks in the settle ($((ms - ms_mid)) ms)"
    limit=$((${!sb} * ms_mid / 1000 + 1))
    extra=$stream_extra
  fi
  if [[ $mode == dl || $mode == del ]]; then
    stream_extra=$((t_mid - rate_milli * ms_mid / 1000000))
    ((stream_extra < 0)) && stream_extra=0
    echo "cost: $what: $((stream_extra * 1000 / ms_mid)) ticks per second above idle ($stream_extra in $ms_mid ms)"
    limit=$((SBDL * ms_mid / 1000 + 1))
    [[ $mode == del ]] && limit=$((SBDEL * ms_mid / 1000 + 1))
    extra=$stream_extra
  fi
  if ((extra > limit)); then echo "FAIL: stack_watch_cost $n entries sorted by $sort, $what: $extra CPU ticks above idle with the helper (limit $limit)"; fail=1; fi
  # (a stream makes strings and objects for a minute before the collector runs: 11 MB after 40 s of 500 files a second, with no
  # trend: the same stretch with a quarter of the files grew by 0.1 MB)
  gmax=3072
  [[ $mode == s* ]] && gmax=24576
  if ((growth > gmax)); then echo "FAIL: stack_watch_cost the shell grew by $growth kB ($n entries, $sort, $what; limit $((gmax / 1024)) MB)"; fail=1; fi
  if [[ $mode == burst || $mode == s* ]]; then
    if ((block_max > GUIWAIT || block_total > 200)); then
      timing_fail "stack_watch_cost $what: the GUI thread was blocked $block_total ms in total, $block_max ms at most (limits 200 and $GUIWAIT; LOAD-SENSITIVE: wall clock)"
    fi
  fi
  if [[ $mode == sendless && $sort == dateAdded ]]; then
    # the pile must keep up with the stream: the longest time between two changes of it, from 3 s after the start to the end of the
    # stream, the tail (the last change to the end) and the head (the start to the first change) included
    gap=$(grep -a "TOP " "$log" | sed 's/.*TOP //' | awk -v a="$((t_start_ms + 3000))" -v b="$((t_start_ms + ms_mid))" 'BEGIN { p = a; m = 0 } $1 >= a && $1 <= b { if ($1 - p > m) m = $1 - p; p = $1 } END { if (b - p > m) m = b - p; print m }')
    echo "cost: $what: the pile changed at least every $gap ms, the tail included (limit $ENDLESSGAP)"
    if ((gap > ENDLESSGAP)); then timing_fail "stack_watch_cost $what: the pile was not refreshed for $gap ms (limit $ENDLESSGAP)"; fi
  fi
done
((fail == 0)) && echo "PASS: stack_watch_cost"
exit $fail
