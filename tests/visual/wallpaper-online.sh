#!/usr/bin/env bash
# The online daily wallpaper end to end in the nested session (ADR-0016 step 2, Wikimedia Commons), against the loopback
# stand-in server (tests/unit/wallpaper-tool/fixtures/commons/server.py): the real network is never used, and the shell refuses
# any other base URL (dev session: loopback only).
#   1. The online source fetches (3 API requests and the bare thumbnail with the fixed User-Agent), prepares the picture and
#      shows it (nothing was cached: the artwork shows until the picture is ready, then the picture crossfades in).
#   2. Settings state: ready, the sanitized attribution, the cache folder 0700.
#   3. A new shell the same day makes no request (one fetch per UTC day) and still shows the cached picture.
#   4. A failed fetch (server error) keeps the previous picture on screen; the failure and the backoff are recorded.
#   5. The next day's picture replaces it through the two-slot crossfade: a capture inside the fade lies on the line between the
#      old and the new colour (fade_mid.py), which a hard cut would not.
#   6. Leaving the online source stops everything (no request).
# Usage (bare command): tests/visual/wallpaper-online.sh        Captures: $VS_SHOTS/wallpaper-online-*.en.png
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/online-lib.sh"

pics=$VS_DEV/wallpapers-e2e
mkdir -p "$pics/solid"
[[ -f $pics/solid/1.png ]] || magick -size 1920x1080 "xc:#ff0000" "$pics/solid/1.png"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

online_start
export GRASSFIELD_PICTURES_DIR=$pics
vs_session
vs_reset
vs_ipc controlcenter reduceMotion false >/dev/null
vs_ipc wallpaper fadeLength 1000 >/dev/null
cfg=$VS_DEV/config/grassfield.json
rm -rf "$VS_DEV/cache/wallpapers/online"

progress() { vs_ipc wallpaper progress "$VS_OUTPUT" | tr -d '[:space:]'; }
rgb_now() { # "r,g,b" of the middle of the desktop right now
  "$VS_ROOT/scripts/dev/shot.sh" online-frame "$VS_OUTPUT" >/dev/null
  magick "$VS_DEV/shots/online-frame.png" -crop 300x300+300+300 +repage -resize 1x1! -format '%[fx:int(255*r)],%[fx:int(255*g)],%[fx:int(255*b)]' info:
}
near() { # "r,g,b" "r,g,b" tolerance
  python3 -I -c 'import sys,math; a=[int(v) for v in sys.argv[1].split(",")]; b=[int(v) for v in sys.argv[2].split(",")]; sys.exit(0 if math.dist(a,b) < float(sys.argv[3]) else 1)' "$1" "$2" "$3"
}
idle() { # waits for no fade running; fails after about 60 s
  local i p
  for i in $(seq 1 300); do
    p=$(progress)
    [[ $p == -1 ]] && return 0
    sleep 0.2
  done
  return 1
}
wait_color() { # "r,g,b" nominal colour: polls until it is on screen and the fade is over, at most 90 s
  local i now
  for i in $(seq 1 90); do
    now=$(rgb_now)
    if near "$now" "$1" 40 && [[ $(progress) == -1 ]]; then
      return 0
    fi
    sleep 1
  done
  echo "the colour $1 never settled (last $now)" >&2
  return 1
}
# mid_fade OLD NEW: takes a capture while a fade is 15 to 45 % done and checks it lies between the two colours.
mid_fade() {
  local old=$1 new=$2 i p p0 p1 rgb
  for i in $(seq 1 600); do
    p=$(progress)
    if awk -v p="$p" 'BEGIN {exit !(p >= 0.15 && p <= 0.45)}'; then
      p0=$p
      rgb=$(rgb_now)
      p1=$(progress)
      if awk -v p="$p1" 'BEGIN {exit !(p > 0 && p < 1)}'; then
        check "a capture inside the crossfade lies between the old and the new colour (progress $p0..$p1, colour $rgb)" python3 -I "$VS_HERE/fade_mid.py" "$old" "$new" "$rgb" "$p0" "$p1"
        return 0
      fi
    fi
    sleep 0.1
  done
  echo "FAIL: no capture could be taken inside the fade"
  fail=1
}
st() { jq -r "$1" "$online_status_file" 2>/dev/null || echo none; }
ost() { vs_ipc wallpaper onlineStatus | jq -r "$1"; }

# --- 0. a red picture is the starting point (a file source)
printf '{"version":1,"accessibility":{"reduceMotion":false},"wallpaper":{"source":"file","path":"%s/solid/1.png","fit":"fill"}}\n' "$pics" > "$cfg.new"
mv "$cfg.new" "$cfg"
wait_color "255,0,0" || { echo "FAIL: the red start picture never showed"; exit 1; }
vs_capture wallpaper-online-0-start >/dev/null

# --- 1. switch to the online source: fetch, prepare, show
req0=$(online_requests)
printf '{"version":1,"accessibility":{"reduceMotion":false},"wallpaper":{"source":"online","online":{"provider":"commons"},"fit":"fill"}}\n' > "$cfg.new"
mv "$cfg.new" "$cfg"
# Nothing is cached: the artwork shows while the helper fetches and prepares, then the picture comes in.
wait_color "30,100,210" || fail=1
vs_capture wallpaper-online-1-picture >/dev/null
check "the settled desktop shows the downloaded picture ($(rgb_now))" near "$(rgb_now)" "30,100,210" 40
n=$(( $(online_requests) - req0 ))
check "the first fetch made 4 requests (3 API, 1 picture) (made $n)" test "$n" = 4
check "the picture request has no utm_ query string" bash -c "! grep -q utm_ '$online_fix/requests.log'"
# The build's version (VERSION) and the project's repository as the contact (commonsfetch.cpp userAgent()).
ua="Grassfield/$(tr -d '[:space:]' <"$VS_ROOT/VERSION") (https://github.com/grassfieldhq/grassfield)"
check "every request carried the fixed User-Agent, no Referer, no cookie" bash -c "! grep -vq '| ua=$ua | referer= | cookie=\$' '$online_fix/requests.log'"
check "no request went anywhere but the loopback server (every logged path is an API or picture path)" bash -c "! grep -vqE '^(/w/api.php\\?|/thumb/)' '$online_fix/requests.log'"

# --- 2. what Settings is told
check "the shell reports ready, source online (state=$(st '.outputs["GF-REF"].state') source=$(st '.outputs["GF-REF"].source'))" test "$(st '.outputs["GF-REF"].state')|$(st '.outputs["GF-REF"].source')" = "ready|online"
check "the attribution is the sanitized one (title, author without the bidi mark and HTML, licence)" test "$(st '[.online.entry.title, .online.entry.author, .online.entry.licenseShort, .online.entry.caption] | join(" | ")')" = "Example lake at dawn | Jane & John Doe | CC BY-SA 4.0 | A calm lake near the city at dawn."
check "the online cache folder is 0700 and holds the day's picture and sidecar" bash -c "[[ \$(stat -c %a '$online_cache') == 700 ]] && [[ \$(ls '$online_cache' | wc -l) == 2 ]]"
check "the cached picture and sidecar are 0600" bash -c "[[ \$(stat -c %a '$online_cache'/*.jpg '$online_cache'/*.json | sort -u) == 600 ]]"

# --- 3. one fetch per day: a new shell makes no request and still shows the picture
vs_ipc wallpaper fadeLength 0 >/dev/null
before=$(online_requests)
vs_kill_clients
"$VS_ROOT/scripts/dev/shell-run.sh" --private-bus --lang "$VS_LANG" --desktop-dir "$VS_STATE/desktop" >/dev/null
for i in $(seq 1 60); do vs_ipc lock status >/dev/null 2>&1 && break; sleep 0.5; done
wait_color "30,100,210" || fail=1
sleep 3
check "a new shell the same day makes no request (before $before, after $(online_requests))" test "$(online_requests)" = "$before"
check "...and shows the cached picture ($(rgb_now))" near "$(rgb_now)" "30,100,210" 40
check "...its state says one fetch was done today" test "$(jq -r '.done' "$VS_DEV/state/wallpaper-online.json")" = "$(date -u -d '-10 minutes' +%F)"

# --- 4. a failed fetch keeps the picture. The scheduler's clock is moved one day ahead (dev hook, loopback only): a new UTC
# day, so a fetch is due; the server answers 500.
vs_ipc wallpaper fadeLength 0 >/dev/null
online_mode fail
fc=$(ost .fetchCount)
r=$(vs_ipc wallpaper onlineClock 24)
check "the dev clock moves one day ahead ($r)" test "$r" = ok
for i in $(seq 1 60); do
  [[ $(ost .fetchCount) -gt $fc && $(ost .phase) != fetching ]] && break
  sleep 0.5
done
sleep 2
check "the failure is recorded (failure=$(ost .failure))" test "$(ost .failure)" = network
check "one failure is counted with a retry time one hour on (failures=$(jq -r .failures "$VS_DEV/state/wallpaper-online.json"))" test "$(jq -r '[.failures, ((.retryAt - (now * 1000 + 86400000)) | . > 3000000 and . < 3700000)] | join(",")' "$VS_DEV/state/wallpaper-online.json")" = "1,true"
check "no second attempt while the backoff runs (fetches: $(ost .fetchCount), before $fc)" test "$(ost .fetchCount)" = "$((fc + 1))"
vs_capture wallpaper-online-4-after-failure >/dev/null
check "the previous picture stays on screen after the failed fetch ($(rgb_now))" near "$(rgb_now)" "30,100,210" 40
check "the state is still ready (state=$(st '.outputs["GF-REF"].state'))" test "$(st '.outputs["GF-REF"].state')" = ready

# --- 5. the next day's picture crossfades in
online_mode ""
online_picture day2 "#28b450"
d_next=$(date -u -d '+26 hours -10 minutes' +%F)
vs_ipc wallpaper fadeLength 6000 >/dev/null
# One hour and a bit later the first retry is due: the server is fine again.
r=$(vs_ipc wallpaper onlineClock 26)
check "the clock reaches the retry time ($r)" test "$r" = ok
mid_fade 30,100,210 40,180,80
wait_color "40,180,80" || fail=1
vs_capture wallpaper-online-5-next-day >/dev/null
check "the next day's picture is on screen ($(rgb_now))" near "$(rgb_now)" "40,180,80" 40
check "its attribution is reported (date=$(st '.online.entry.date'), expected $d_next)" test "$(st '.online.entry.date')" = "$d_next"
check "the success cleared the failure count (failures=$(jq -r .failures "$VS_DEV/state/wallpaper-online.json"), done=$(jq -r .done "$VS_DEV/state/wallpaper-online.json"))" test "$(jq -r '[.failures, .done] | join(",")' "$VS_DEV/state/wallpaper-online.json")" = "0,$d_next"
check "the cache holds both days (and only those)" bash -c "[[ \$(ls '$online_cache' | wc -l) == 4 ]]"

# --- 6. leaving the online source: nothing more is requested
before=$(online_requests)
jq '.wallpaper = {source: "builtin"}' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"
sleep 6
check "the artwork shows again and the scheduler is idle (phase=$(ost .phase))" test "$(ost .phase)" = idle
check "no request after leaving the online source" test "$(online_requests)" = "$before"
check "no QML error in the shell log" test "$(grep -E 'ERROR|TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log" | grep -vc 'PointerTheme')" = 0
echo "requests seen by the loopback server: $(online_requests)"

vs_kill_clients
exit $fail
