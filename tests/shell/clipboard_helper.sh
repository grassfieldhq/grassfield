#!/bin/bash
# grassfield-clipboard-helper (ADR-0034) as a process, against tests/fixtures/fake-clipboard-server: never the owner's clipboard or
# session. Every helper runs under `env -i` with a mktemp -d runtime directory, and is given the fake server's socket as --display
# (a path inside that directory, checked here). Prints PASS or FAIL lines; exits 1 on any FAIL; SKIPs where Unix sockets cannot be
# created (a sandbox). Builds the helper and the fake server with apps/clipboard-helper/build-direct.sh.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
build=$root/.dev/build
helper=${GRASSFIELD_CLIPBOARD_HELPER_TEST_BIN:-$build/grassfield-clipboard-helper}
server=$build/fake-clipboard-server
"$root/apps/clipboard-helper/build-direct.sh" >/dev/null 2>&1 || { echo "FAIL clipboard_helper: the helper does not build"; exit 1; }
"$root/apps/clipboard-helper/build-direct.sh" --fake-server >/dev/null 2>&1 || { echo "FAIL clipboard_helper: the fake server does not build"; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gf-clip.XXXXXX")
if ! python3 -I -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$tmp/probe" 2>/dev/null; then
  echo "SKIP clipboard_helper: Unix sockets cannot be created here"
  rm -rf "$tmp"
  exit 0
fi
rm -f "$tmp/probe"
umask 022 # the helper must make its files 0600 whatever umask it inherits
fail=0
pids=()
cleanup() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

pass() { echo "PASS clipboard_helper: $1"; }
bad() { echo "FAIL clipboard_helper: $1"; fail=1; }
check() { # <what> <want> <got>
  if [[ $2 == "$3" ]]; then pass "$1"; else bad "$1: wanted [$2], got [$3]"; fi
}
US=$'\037'

# start_server <name> [args...]: fd for commands in srv_<name>, output in $tmp/<name>.out
start_server() {
  local name=$1
  shift
  mkfifo "$tmp/$name.in"
  env -i PATH=/usr/bin:/bin "$server" --socket "$tmp/$name.sock" "$@" <"$tmp/$name.in" >"$tmp/$name.out" 2>"$tmp/$name.err" &
  pids+=($!)
  exec {fd}>"$tmp/$name.in"
  printf -v "srv_$name" '%s' "$fd"
  waitline "$tmp/$name.out" '^READY$' 5 >/dev/null
}
srv() { # <name> <command line>
  local v="srv_$1"
  printf '%s\n' "$2" >&"${!v}"
}
# start_helper <name> <display socket> [args...]: commands through hlp_<name>, output $tmp/<name>.out, log $tmp/<name>.err
start_helper() {
  local name=$1 display=$2
  shift 2
  mkfifo "$tmp/$name.in"
  env -i PATH=/usr/bin:/bin "$helper" --display "$display" --state "$tmp/state" --runtime "$tmp/run/clipboard" "$@" \
    <"$tmp/$name.in" >"$tmp/$name.out" 2>"$tmp/$name.err" &
  pids+=($!)
  printf -v "pid_$name" '%s' "$!"
  exec {fd}>"$tmp/$name.in"
  printf -v "hlp_$name" '%s' "$fd"
}
hlp() { # <name> <field>...: one line, fields joined by US
  local v="hlp_$1"
  shift
  local IFS=$US
  printf '%s\n' "$*" >&"${!v}"
}
stop_helper() { # QUIT, then the helper must end by itself with exit 0 (never a crash, whatever is running)
  local v="hlp_$1" p="pid_$1" rc
  hlp "$1" QUIT
  local f=${!v}
  exec {f}>&-
  wait "${!p}" 2>/dev/null
  rc=$?
  check "helper $1 ends on QUIT with exit 0" 0 "$rc"
}
# waitline <file> <regex> <seconds>: prints the first matching line (US shown as |), returns 1 when none came
waitline() {
  local file=$1 re=$2 limit=$3 i line
  for ((i = 0; i < limit * 50; i++)); do
    line=$(tr "$US" '|' <"$file" 2>/dev/null | grep -a -m1 -E -- "$re") && { echo "$line"; return 0; }
    sleep 0.02
  done
  return 1
}
count() { tr "$US" '|' <"$1" 2>/dev/null | grep -a -c -E -- "$2"; }
field() { # <line with |> <n>
  awk -F'|' -v n="$2" '{ print $n }' <<<"$1"
}
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

# answers the next offer of helper <name> with Y; prints the item line
approve() { # <helper> <offers seen before> <app>
  local name=$1 before=$2 o seq
  o=$(waitline_nth "$tmp/$name.out" '^O\|' $((before + 1)) 5) || return 1
  seq=$(field "$o" 2)
  hlp "$name" Y "$seq" "$3"
}
waitline_nth() { # <file> <regex> <n> <seconds>: the n-th matching line
  local file=$1 re=$2 n=$3 limit=$4 i line
  for ((i = 0; i < limit * 50; i++)); do
    line=$(tr "$US" '|' <"$file" 2>/dev/null | grep -a -E -- "$re" | sed -n "${n}p")
    [[ -n $line ]] && { echo "$line"; return 0; }
    sleep 0.02
  done
  return 1
}
mode() { stat -c '%a' "$1" 2>/dev/null; }

# --- 1. The display: only --display, an absolute path to this user's socket ---------------------------------------------------
start_server main
start_server decoy
env -i PATH=/usr/bin "$helper" --state "$tmp/state" --runtime "$tmp/run/clipboard" </dev/null >/dev/null 2>&1
check "refused without --display (no default display)" 2 $?
env -i PATH=/usr/bin "$helper" --display main.sock --state "$tmp/state" --runtime "$tmp/run/clipboard" </dev/null >/dev/null 2>&1
check "refused with a relative display" 2 $?
: >"$tmp/not-a-socket"
out=$(env -i PATH=/usr/bin "$helper" --display "$tmp/not-a-socket" --state "$tmp/state" --runtime "$tmp/run/clipboard" </dev/null 2>/dev/null)
rc=$?
check "refused with a path that is not a socket" "1 S|error" "$rc $(tr "$US" '|' <<<"$out" | cut -d'|' -f1-2)"
# A decoy WAYLAND_SOCKET (a descriptor connected to a second server) and a decoy WAYLAND_DISPLAY: the helper must use neither.
mkfifo "$tmp/decoyhelper.in"
python3 -I -c '
import os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
fd = s.detach()
os.set_inheritable(fd, True)
env = {"PATH": "/usr/bin:/bin", "WAYLAND_SOCKET": str(fd), "WAYLAND_DISPLAY": sys.argv[1]}
os.execve(sys.argv[2], [sys.argv[2]] + sys.argv[3:], env)' "$tmp/decoy.sock" "$helper" --display "$tmp/main.sock" --state "$tmp/state" \
  --runtime "$tmp/run/clipboard" <"$tmp/decoyhelper.in" >"$tmp/decoyhelper.out" 2>"$tmp/decoyhelper.err" &
decoy_pid=$!
pids+=("$decoy_pid")
exec {decoy_fd}>"$tmp/decoyhelper.in"
waitline "$tmp/decoyhelper.out" '^S\|ok' 5 >/dev/null
check "the helper talked to the --display server" 1 "$(count "$tmp/main.out" '^BIND data-control$')"
sleep 0.3
check "the decoy WAYLAND_SOCKET server was never used (no global bound)" 0 "$(count "$tmp/decoy.out" '^BIND')"
case "$tmp/main.sock" in "$tmp"/*) pass "the --display socket lies in the test's own directory" ;; *) bad "socket outside the test directory" ;; esac
printf 'QUIT\n' >&"$decoy_fd"
exec {decoy_fd}>&-
wait "$decoy_pid" 2>/dev/null

# --- 2. Paused until the shell resumes; the first selection after a (re)start is never recorded --------------------------------
srv main "SELECT text/plain;charset=utf-8|hex:$(hex 'before the start')"
start_helper a "$tmp/main.sock" --retention 600000
waitline "$tmp/a.out" '^S\|ok' 5 >/dev/null || bad "the helper did not start"
check "lock state reported at start" "L|0" "$(waitline "$tmp/a.out" '^L\|' 2)"
sleep 0.3
check "no data-control device before the shell resumes" 0 "$(count "$tmp/main.out" '^DEVICE$')"
hlp a R
waitline_nth "$tmp/main.out" '^DEVICE$' 1 5 >/dev/null || bad "no device after resume"
sleep 0.3
check "the selection present at the start is not offered" 0 "$(count "$tmp/a.out" '^O\|')"
check "...and its data never requested" 0 "$(count "$tmp/main.out" '^RECEIVE')"

# --- 3. A copy: offered, read only after Y, recorded with its formatted part ----------------------------------------------------
canary="canary-$RANDOM-$RANDOM-text"
srv main "SELECT text/plain;charset=utf-8|hex:$(hex "Hello $canary") text/html|hex:$(hex "<b>Hello $canary</b>")"
o=$(waitline "$tmp/a.out" '^O\|' 5) || bad "no offer"
check "the offer says its kind" text "$(field "$o" 3)"
sleep 0.3
check "nothing read before the shell's answer" 0 "$(count "$tmp/main.out" '^RECEIVE')"
hlp a Y "$(field "$o" 2)" org.example.Editor
item=$(waitline "$tmp/a.out" '^I\|' 5) || bad "no item"
text_id=$(field "$item" 2)
check "the item's title" "Hello $canary" "$(field "$item" 10)"
check "the item keeps its HTML (formatted)" "1 text/plain,text/html" "$(field "$item" 8) $(field "$item" 4)"
check "the item's source app" org.example.Editor "$(field "$item" 13)"

# --- 4. N: the copy is never read -------------------------------------------------------------------------------------------
before=$(count "$tmp/main.out" '^RECEIVE')
srv main "SELECT text/plain;charset=utf-8|hex:$(hex 'refused by the shell')"
o=$(waitline_nth "$tmp/a.out" '^O\|' 2 5) || bad "no second offer"
hlp a N "$(field "$o" 2)"
sleep 0.4
check "N: no data requested" "$before" "$(count "$tmp/main.out" '^RECEIVE')"
check "N: no item" 1 "$(count "$tmp/a.out" '^I\|')"

# --- 5. Password-manager hints: no offer, no data requested -------------------------------------------------------------------
for hint in x-kde-passwordManagerHint org.nspasteboard.ConcealedType org.nspasteboard.TransientType; do
  srv main "SELECT text/plain;charset=utf-8|hex:$(hex hunter2) $hint|hex:$(hex secret)"
  sleep 0.3
done
check "hinted copies: no offer to the shell" 2 "$(count "$tmp/a.out" '^O\|')"
check "hinted copies: their data never requested" "$before" "$(count "$tmp/main.out" '^RECEIVE')"
grep -a -q 'password-manager hint' "$tmp/a.err" && pass "hinted copies logged by reason" || bad "no log line for the hint"

# --- 6. Never truncated: a copy over its cap, or one whose source never answers, is not recorded --------------------------------
srv main "SELECT text/plain;charset=utf-8|big:300000"
approve a 2 x >/dev/null
sleep 0.6 # the read ends (over its cap) before the next copy replaces it
srv main "SELECT text/plain;charset=utf-8|hang"
sleep 0.4
approve a 3 x >/dev/null
sleep 2.6
check "over the cap and late copies: no item" 1 "$(count "$tmp/a.out" '^I\|')"
grep -a -q 'over its limit' "$tmp/a.err" && pass "over the cap logged" || bad "no over-cap log"
srv main "SELECT text/plain;charset=utf-8|hex:$(hex 'after the hang')"
approve a 4 x >/dev/null
waitline "$tmp/a.out" '^I\|[0-9a-f]+\|text\|.*\|after the hang\|' 5 >/dev/null && pass "capture goes on after a source that hangs" || bad "capture stuck after a hang"

# --- 7. Images: the worker decodes only the format given ------------------------------------------------------------------------
python3 -I -c '
import struct, sys, zlib
w, h = 600, 300
raw = b"".join(b"\x00" + bytes([200, 30, 30]) * w for _ in range(h))
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)' "$tmp/red.png"
srv main "SELECT image/png|file:$tmp/red.png text/html|hex:$(hex '<img src=x>')"
approve a 5 org.example.Viewer >/dev/null
img=$(waitline "$tmp/a.out" '^I\|[0-9a-f]+\|image\|' 5) || bad "no image item"
thumb=$(field "$img" 12)
img_id=$(field "$img" 2)
[[ -f $thumb ]] && pass "the image has a thumbnail" || bad "no thumbnail file"
check "the thumbnail is 0600" 600 "$(mode "$thumb")"
python3 -I -c 'import struct,sys; d=open(sys.argv[1],"rb").read(); print(*struct.unpack(">II", d[16:24]))' "$thumb" >"$tmp/dims" 2>/dev/null
check "the thumbnail is at most 256 px" "256 128" "$(cat "$tmp/dims")"
printf '%%PDF-1.7\n1 0 obj\n<< >>\nendobj\n' >"$tmp/fake.png"
srv main "SELECT image/png|file:$tmp/fake.png"
approve a 6 x >/dev/null
sleep 2.5
check "a PDF offered as PNG is not recorded" 1 "$(count "$tmp/a.out" '^I\|[0-9a-f]+\|image\|')"
# SVG and TIFF bytes behind a PNG offer: the worker reads PNG only (no other image plugin is reached), nothing is recorded.
printf '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64"/></svg>' >"$tmp/fake.svg"
printf 'II*\000\010\000\000\000\000\000' >"$tmp/fake.tiff"
for f in svg tiff; do
  offers=$(count "$tmp/a.out" '^O\|')
  srv main "SELECT image/png|file:$tmp/fake.$f"
  approve a "$offers" x >/dev/null
  sleep 1
done
check "SVG and TIFF offered as PNG are not recorded" 1 "$(count "$tmp/a.out" '^I\|[0-9a-f]+\|image\|')"
offers=$(count "$tmp/a.out" '^O\|')
srv main "SELECT image/gif|hex:47494638"
sleep 0.3
check "GIF is not offered" "$offers" "$(count "$tmp/a.out" '^O\|')"

# --- 8. Locks: the compositor's lock (any locker), the shell's pause --------------------------------------------------------
# A lock while an approved copy is being read: the read is dropped at once, and the copy is not recorded although its source
# answers in full 0.8 s after the request (a read that ran on would end well within its 2 s deadline).
items=$(count "$tmp/a.out" '^I\|')
offers=$(count "$tmp/a.out" '^O\|')
receives=$(count "$tmp/main.out" '^RECEIVE')
srv main "SELECT text/plain;charset=utf-8|slow:800:hex:$(hex 'read across a lock')"
approve a "$offers" x >/dev/null
waitline_nth "$tmp/main.out" '^RECEIVE' $((receives + 1)) 3 >/dev/null || bad "the slow copy was not read"
srv main LOCK
check "the compositor's lock is reported" "L|1" "$(waitline "$tmp/a.out" '^L\|1' 3)"
waitline "$tmp/main.out" '^DEVICE_GONE$' 3 >/dev/null && pass "no device while locked" || bad "device kept while locked"
sleep 1.2
check "a lock during a read: the copy is not recorded" "$items" "$(count "$tmp/a.out" '^I\|')"
before_o=$(count "$tmp/a.out" '^O\|')
before_r=$(count "$tmp/main.out" '^RECEIVE')
srv main "SELECT text/plain;charset=utf-8|hex:$(hex 'copied under the lock')"
sleep 0.4
check "a copy under the lock: no offer" "$before_o" "$(count "$tmp/a.out" '^O\|')"
check "a copy under the lock: no data requested" "$before_r" "$(count "$tmp/main.out" '^RECEIVE')"
# A second helper started while the session is locked: paused from its first event.
start_helper b "$tmp/main.sock"
waitline "$tmp/b.out" '^S\|ok' 5 >/dev/null
check "a helper started under a lock knows it at once" "L|1" "$(waitline "$tmp/b.out" '^L\|' 2)"
hlp b R
sleep 0.4
devices=$(count "$tmp/main.out" '^DEVICE$')
stop_helper b
srv main UNLOCK
waitline "$tmp/a.out" '^L\|0' 3 >/dev/null || bad "no unlock reported"
waitline_nth "$tmp/main.out" '^DEVICE$' $((devices + 1)) 3 >/dev/null && pass "a device again after the unlock" || bad "no device after unlock"
sleep 0.4
check "the selection copied under the lock is skipped after the unlock" "$before_o" "$(count "$tmp/a.out" '^O\|')"
gone=$(count "$tmp/main.out" '^DEVICE_GONE$')
hlp a P
waitline_nth "$tmp/main.out" '^DEVICE_GONE$' $((gone + 1)) 3 >/dev/null && pass "the shell's pause removes the device" || bad "pause kept the device"
srv main "SELECT text/plain;charset=utf-8|hex:$(hex 'copied while paused')"
sleep 0.3
check "paused: no offer" "$before_o" "$(count "$tmp/a.out" '^O\|')"
hlp a R
sleep 0.3

# --- 9. Serving an item back: every type, the marker, plain only -------------------------------------------------------------
hlp a C "$text_id" 0
waitline "$tmp/a.out" "^A\|$text_id" 3 >/dev/null && pass "the clipboard holds the item (A)" || bad "no A after C"
sel=$(waitline "$tmp/main.out" '^SELECTION .*application/x-grassfield-clipboard-item' 3)
[[ $sel == *text/html* && $sel == *UTF8_STRING* ]] && pass "served with its plain types, its HTML and the marker" || bad "served types: $sel"
srv main "PASTE text/plain;charset=utf-8 $tmp/pasted.txt"
waitline "$tmp/main.out" '^PASTED text/plain;charset=utf-8' 5 >/dev/null
check "pasted text" "Hello $canary" "$(cat "$tmp/pasted.txt")"
# Its own selection comes back as an update of the same item (moved to the top), never as a new one.
check "its own selection is not recorded again" 1 "$(tr "$US" '|' <"$tmp/a.out" | awk -F'|' -v t="Hello $canary" '$1 == "I" && $10 == t { print $2 }' | sort -u | wc -l)"
hlp a C "$text_id" 1
sleep 0.4
last=$(grep -a '^SELECTION' "$tmp/main.out" | tail -1)
[[ $last != *text/html* ]] && pass "Paste as Plain Text offers no HTML" || bad "plain only still offers HTML: $last"
# A reader that stops reading never holds a writer: 200,000 bytes fill the pipe, and the helper closes its end after 2 s.
offers=$(count "$tmp/a.out" '^O\|')
srv main "SELECT text/plain;charset=utf-8|big:200000"
approve a "$offers" x >/dev/null
big=$(waitline "$tmp/a.out" '^I\|[0-9a-f]+\|text\|.*\|a{200}\|' 5) || bad "no 200,000-byte item"
big_id=$(field "$big" 2)
hlp a C "$big_id" 1
waitline "$tmp/a.out" "^A\\|$big_id" 3 >/dev/null || bad "the large item is not on the clipboard"
srv main "STALL text/plain;charset=utf-8"
closed=$(waitline "$tmp/main.out" '^STALL_' 8)
ms=${closed#STALL_CLOSED }
if [[ $closed == STALL_CLOSED* ]] && ((ms >= 1500 && ms <= 4000)); then
  pass "a writer whose reader stops reading is closed after 2 s ($ms ms)"
else
  bad "stalled writer: [$closed]"
fi
# A reader that keeps reading, however slowly, gets the whole answer: the 2 s limit counts time without progress, not the total.
# 8 KiB every 250 ms: the helper is still writing about 4 s after the request (the pipe holds 64 KiB of the 200,000 bytes).
start_ms=$(date +%s%3N)
srv main "PASTE text/plain;charset=utf-8 $tmp/slow.txt 8192 250"
waitline "$tmp/main.out" '^PASTED text/plain;charset=utf-8 200000$' 15 >/dev/null
took=$(($(date +%s%3N) - start_ms))
check "a slow reader that keeps reading gets all 200,000 bytes" 200000 "$(stat -c %s "$tmp/slow.txt" 2>/dev/null)"
if ((took > 4000)); then pass "...with the helper writing well past 2 s ($took ms in all)"; else bad "the slow paste took $took ms: the case needs the writes to last past 2 s"; fi

# --- 10. Search, pins, stores, clearing ------------------------------------------------------------------------------------
hlp a Q 7 "hello"
check "search finds the text" "R|7|$text_id" "$(waitline "$tmp/a.out" '^R\|7' 3)"
hlp a PIN "$text_id"
waitline "$tmp/a.out" "^I\\|$text_id\\|text\\|[^|]*\\|[0-9]+\\|[0-9]+\\|[1-9]" 3 >/dev/null && pass "pinned" || bad "pin not reported"
check "the pinned store directory is 0700" 700 "$(mode "$tmp/state/pinned")"
check "the pinned index is 0600" 600 "$(mode "$tmp/state/pinned/index.json")"
check "the pinned item file is 0600" 600 "$(mode "$tmp/state/pinned/$text_id.item")"
[[ ! -e $tmp/state/history ]] && pass "no history store without the opt-in" || bad "history written without the opt-in"
hlp a CH
sleep 0.3
check "Clear History spares the pin" 0 "$(count "$tmp/a.out" "^X\\|$text_id")"
grep -a -q "^X${US}$img_id" "$tmp/a.out" && pass "Clear History removes the rest" || bad "image not cleared"
[[ ! -e $thumb ]] && pass "the cleared image's thumbnail is gone" || bad "thumbnail left"
stop_helper a
[[ ! -e $tmp/run/clipboard ]] && pass "the runtime directory is removed at exit" || bad "runtime directory left"
# A pinned image that the worker cannot turn into a thumbnail (here: bytes that are no PNG) is kept, shown without a thumbnail:
# a worker's failure (late under load, failed to start) never deletes what the user kept.
bad_id=00000000000badd0
python3 -I - "$tmp/state/pinned" "$bad_id" <<'PY'
import json, os, sys
d, iid = sys.argv[1], sys.argv[2]
data = b"\x89PNG\r\n\x1a\n" + b"no image here" * 8
fd = os.open(os.path.join(d, iid + ".item"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.write(fd, b"GFCLIP1\n1\nimage/png\n" + str(len(data)).encode() + b"\n" + data)
os.close(fd)
path = os.path.join(d, "index.json")
index = json.load(open(path))
index["items"].append({"id": iid, "kind": "image", "mimes": ["image/png"], "size": len(data), "copiedAt": 1, "bootId": "",
                       "bootAt": 0, "pinnedAt": 2, "title": "", "app": ""})
fd = os.open(path, os.O_WRONLY | os.O_TRUNC)
os.write(fd, json.dumps(index).encode())
os.close(fd)
PY
start_helper c "$tmp/main.sock" --history-store 1
waitline "$tmp/c.out" "^I\\|$text_id\\|" 5 >/dev/null && pass "the pin survives a restart" || bad "pin lost at restart"
kept=$(waitline "$tmp/c.out" "^I\\|$bad_id\\|image\\|" 5) || bad "the pinned image whose worker failed is not shown"
check "a pinned image whose worker fails is kept, without a thumbnail" "" "$(field "$kept" 12)"
sleep 0.5
check "...and never removed" "0 yes" "$(count "$tmp/c.out" "^X\\|$bad_id") $([[ -f $tmp/state/pinned/$bad_id.item ]] && echo yes || echo no)"
grep -a -q "thumbnail failed: the item is kept" "$tmp/c.err" && pass "the failed thumbnail is logged by reason" || bad "no log for the failed thumbnail"
hlp c R
sleep 0.3
srv main "SELECT text/plain;charset=utf-8|hex:$(hex 'kept on disk')"
approve c 0 x >/dev/null
waitline "$tmp/c.out" '^I\|[0-9a-f]+\|text\|.*\|kept on disk\|' 3 >/dev/null
sleep 0.4 # the history's index is written once per change, a moment after it
check "the opt-in history store is 0600" 600 "$(mode "$tmp/state/history/index.json")"
stop_helper c
# The one-shot clears the shell runs while the history is off: each deletes its own store only.
cp -a "$tmp/state" "$tmp/state2"
env -i PATH=/usr/bin:/bin "$helper" --clear-pinned --state "$tmp/state2" </dev/null >/dev/null 2>&1
check "--clear-pinned: exit 0, the pinned store gone, the history store kept" "0 no yes" \
  "$? $([[ -e $tmp/state2/pinned ]] && echo yes || echo no) $([[ -e $tmp/state2/history/index.json ]] && echo yes || echo no)"
env -i PATH=/usr/bin:/bin "$helper" --clear-history --state "$tmp/state2" </dev/null >/dev/null 2>&1
check "--clear-history: exit 0, the history store gone" "0 no" "$? $([[ -e $tmp/state2/history ]] && echo yes || echo no)"
# Expiry at load: an item older than the retention, and one from another boot dated in the future, are deleted before anything
# is shown (memory and disk).
cp -a "$tmp/state" "$tmp/state3"
cp -a "$tmp/state" "$tmp/state4"
python3 -I - "$tmp/state4/history/index.json" <<'PY'
import json, os, sys, time
path = sys.argv[1]
index = json.load(open(path))
for it in index["items"]:
    it["copiedAt"] = time.time() * 1000 + 86400000
    it["bootId"] = "another-boot"
fd = os.open(path, os.O_WRONLY | os.O_TRUNC)
os.write(fd, json.dumps(index).encode())
os.close(fd)
PY
sleep 1.1
env -i PATH=/usr/bin:/bin "$helper" --display "$tmp/main.sock" --state "$tmp/state3" --runtime "$tmp/run/clipboard" \
  --retention 1000 --history-store 1 </dev/null >"$tmp/expired.out" 2>/dev/null
check "expiry at load: an item past the retention is never shown and its store is deleted (exit 0 at once)" "0 0 no" \
  "$? $(count "$tmp/expired.out" '^I\|[0-9a-f]+\|text\|.*\|kept on disk\|') $([[ -e $tmp/state3/history ]] && echo yes || echo no)"
env -i PATH=/usr/bin:/bin "$helper" --display "$tmp/main.sock" --state "$tmp/state4" --runtime "$tmp/run/clipboard" \
  --history-store 1 </dev/null >"$tmp/future.out" 2>/dev/null
check "expiry at load: an item of another boot dated in the future is deleted (exit 0 at once)" "0 0 no" \
  "$? $(count "$tmp/future.out" '^I\|[0-9a-f]+\|text\|.*\|kept on disk\|') $([[ -e $tmp/state4/history ]] && echo yes || echo no)"
start_helper d "$tmp/main.sock" --history-store 1
waitline "$tmp/d.out" '^I\|[0-9a-f]+\|text\|.*\|kept on disk\|' 5 >/dev/null && pass "the history store is read back" || bad "history store not read"
hlp d D 0
sleep 0.3
[[ ! -e $tmp/state/history ]] && pass "switching the store off deletes it" || bad "history store left after D 0"
hlp d T 1000
sleep 1.3
hlp d E
waitline "$tmp/d.out" '^X\|' 3 >/dev/null && pass "retention removes old items" || bad "nothing expired"
check "retention spares the pin" 0 "$(count "$tmp/d.out" "^X\\|$text_id")"
hlp d CP
waitline "$tmp/d.out" "^X\\|$text_id" 3 >/dev/null && pass "clearing the pins removes them" || bad "pins not cleared"
sleep 0.2
[[ ! -e $tmp/state/pinned ]] && pass "the pinned store is deleted with them" || bad "pinned store left"
stop_helper d

# --- 10b. A new copy's image goes before the stored thumbnails -----------------------------------------------------------------
# 16 pinned images of 3,000 x 3,000 px wait for their thumbnails at start; an image copied once the helper runs goes before
# those still waiting (it used to wait behind all of them).
python3 -I - "$tmp/state5/pinned" <<'PY'
import json, os, struct, sys, zlib
d = sys.argv[1]
os.makedirs(d, mode=0o700)
def chunk(t, data):
    return struct.pack(">I", len(data)) + t + data + struct.pack(">I", zlib.crc32(t + data) & 0xffffffff)
w = h = 3000
head = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
head += chunk(b"IDAT", zlib.compress((b"\x00" + bytes([30, 120, 200]) * w) * h, 1))
items = []
for n in range(16):
    iid = "%016x" % (0xa000 + n)
    png = head + chunk(b"tEXt", b"n\x00" + str(n).encode()) + chunk(b"IEND", b"")
    fd = os.open(os.path.join(d, iid + ".item"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(fd, b"GFCLIP1\n1\nimage/png\n" + str(len(png)).encode() + b"\n" + png)
    os.close(fd)
    items.append({"id": iid, "kind": "image", "mimes": ["image/png"], "size": len(png), "copiedAt": 1, "bootId": "", "bootAt": 0,
                  "pinnedAt": 100 + n, "title": "", "app": ""})
fd = os.open(os.path.join(d, "index.json"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.write(fd, json.dumps({"version": 1, "items": items}).encode())
os.close(fd)
PY
devices=$(count "$tmp/main.out" '^DEVICE$')
start_helper g "$tmp/main.sock" --state "$tmp/state5"
waitline "$tmp/g.out" '^S\|ok' 5 >/dev/null || bad "helper g did not start"
hlp g R
waitline_nth "$tmp/main.out" '^DEVICE$' $((devices + 1)) 3 >/dev/null || bad "helper g has no device"
sleep 0.2
offers=$(count "$tmp/g.out" '^O\|')
srv main "SELECT image/png|file:$tmp/red.png"
approve g "$offers" org.example.New >/dev/null
waitline "$tmp/g.out" '^I\|[0-9a-f]+\|image\|.*\|org\.example\.New$' 15 >/dev/null || bad "the new image was not recorded"
# Where it waited, from the helper's own count (no timing): never behind a stored thumbnail. On a machine fast enough to finish
# the 16 before the copy arrives, nothing was left to jump: the case is reported as not exercised, never as a failure.
queued=$(grep -a -m1 'a new image waits for the worker' "$tmp/g.err")
if [[ $queued =~ ([0-9]+)\ stored\ ahead,\ ([0-9]+)\ stored\ behind ]]; then
  if ((BASH_REMATCH[2] == 0)); then
    echo "SKIP clipboard_helper: new image before stored thumbnails not exercised (all 16 were done before the copy)"
  else
    check "a new image goes before the stored thumbnails still waiting (${BASH_REMATCH[2]} behind it)" 0 "${BASH_REMATCH[1]}"
  fi
else
  bad "no queue line for the new image: [$queued]"
fi
stop_helper g

# --- 10c. Clears asked while no helper ran (review of f7cd664) ----------------------------------------------------------------
# Settings writes search.clipboard.clearedAt and .pinnedClearedAt whether a helper runs or not; the shell passes them at start
# (--cleared-at, --pinned-cleared-at) or, with the history off, runs --apply-clears. The helper records what it carried out in
# <state>/clears and carries out at start, before anything is loaded or shown, any value it has not.
s6=$tmp/state6
copy_in() { # <helper> <offers seen before> <text>: copies <text>, approves it, prints its id
  srv main "SELECT text/plain;charset=utf-8|hex:$(hex "$3")"
  approve "$1" "$2" x >/dev/null
  field "$(waitline "$tmp/$1.out" "^I\\|[0-9a-f]+\\|text\\|.*\\|$3\\|" 3)" 2
}
start_helper k "$tmp/main.sock" --state "$s6" --history-store 1 --cleared-at 0 --pinned-cleared-at 0
waitline "$tmp/k.out" '^S\|ok' 5 >/dev/null || bad "helper k did not start"
hlp k R
sleep 0.3
copy_in k 0 'cleared while stopped' >/dev/null
pin6=$(copy_in k 1 'pinned before')
hlp k PIN "$pin6"
waitline "$tmp/k.out" "^I\\|$pin6\\|text\\|[^|]*\\|[0-9]+\\|[0-9]+\\|[1-9]" 3 >/dev/null || bad "the pin was not reported"
stop_helper k
check "the clears record: 0600, the values carried out" "600 GFCLEARS1 0 0" "$(mode "$s6/clears") $(cat "$s6/clears" 2>/dev/null)"
# Clear Clipboard History written while no helper ran: the next start never shows the history; the pin stays.
start_helper m "$tmp/main.sock" --state "$s6" --history-store 1 --cleared-at 5000 --pinned-cleared-at 0
waitline "$tmp/m.out" "^I\\|$pin6\\|" 5 >/dev/null && pass "a history clear asked while stopped spares the pin" || bad "the pin is gone"
waitline "$tmp/m.out" '^S\|ok' 5 >/dev/null || bad "helper m did not start"
check "a history clear asked while stopped: the history is never shown" 0 "$(count "$tmp/m.out" '\|cleared while stopped\|')"
check "...the record says it was carried out" "GFCLEARS1 5000 0" "$(cat "$s6/clears" 2>/dev/null)"
grep -a -q "a clear asked while no helper ran was carried out (the history store)" "$tmp/m.err" && pass "...logged by reason" || bad "the clear at start is not logged"
stop_helper m
# Also delete pinned items, written while the history is off (the shell runs --apply-clears).
env -i PATH=/usr/bin:/bin "$helper" --apply-clears --state "$s6" --cleared-at 5000 --pinned-cleared-at 6000 </dev/null >/dev/null 2>&1
check "--apply-clears: exit 0, the pins gone, the record updated" "0 no GFCLEARS1 5000 6000" \
  "$? $([[ -e $s6/pinned ]] && echo yes || echo no) $(cat "$s6/clears" 2>/dev/null)"
env -i PATH=/usr/bin:/bin "$helper" --apply-clears --state "$s6" --cleared-at 5x00 </dev/null >/dev/null 2>&1
check "--apply-clears refuses a time that is not digits" 2 "$?"
# The same values again (the shell restarting): nothing is cleared again.
start_helper n "$tmp/main.sock" --state "$s6" --history-store 1 --cleared-at 5000 --pinned-cleared-at 6000
waitline "$tmp/n.out" '^S\|ok' 5 >/dev/null || bad "helper n did not start"
hlp n R
sleep 0.3
pin7=$(copy_in n 0 'pinned after')
hlp n PIN "$pin7"
waitline "$tmp/n.out" "^I\\|$pin7\\|text\\|[^|]*\\|[0-9]+\\|[0-9]+\\|[1-9]" 3 >/dev/null || bad "the new pin was not reported"
copy_in n 1 'history after' >/dev/null
stop_helper n
start_helper p "$tmp/main.sock" --state "$s6" --history-store 1 --cleared-at 5000 --pinned-cleared-at 6000
waitline "$tmp/p.out" '\|history after\|' 5 >/dev/null && pass "clears already carried out are not carried out again (history kept)" || bad "history cleared again"
check "...nor the pins" 1 "$(count "$tmp/p.out" "^I\\|$pin7\\|")"
# Settings' Clear while the helper runs: CH with its time clears and is recorded, so the next start keeps what came after.
hlp p R
sleep 0.3
hlp p CH 7000
waitline "$tmp/p.out" '^X\|' 3 >/dev/null || bad "CH 7000 cleared nothing"
sleep 0.2
check "CH with the setting's time is recorded" "GFCLEARS1 7000 6000" "$(cat "$s6/clears" 2>/dev/null)"
copy_in p 0 'after the clear' >/dev/null
hlp p CH
sleep 0.2
check "CH without a time (Search's Clear History) leaves the record" "GFCLEARS1 7000 6000" "$(cat "$s6/clears" 2>/dev/null)"
copy_in p 1 'after search clear' >/dev/null
stop_helper p
start_helper q "$tmp/main.sock" --state "$s6" --history-store 1 --cleared-at 7000 --pinned-cleared-at 6000
waitline "$tmp/q.out" '\|after search clear\|' 5 >/dev/null && pass "a clear carried out while running is not carried out again" || bad "history cleared again at start"
stop_helper q
# No record (a store from before it existed): only what came before the clear goes. The pin (pinned now) is after a pinned clear
# at 1 ms; the history item (copied now) is before a clear an hour ahead.
rm -f "$s6/clears"
later=$(($(date +%s) * 1000 + 3600000))
start_helper r "$tmp/main.sock" --state "$s6" --history-store 1 --cleared-at "$later" --pinned-cleared-at 1
waitline "$tmp/r.out" "^I\\|$pin7\\|" 5 >/dev/null && pass "no record: a pin made after the pinned clear stays" || bad "no record: the pin went"
waitline "$tmp/r.out" '^S\|ok' 5 >/dev/null || bad "helper r did not start"
check "no record: the history from before the clear goes" 0 "$(count "$tmp/r.out" '\|after search clear\|')"
check "...and the record is written" "GFCLEARS1 $later 1" "$(cat "$s6/clears" 2>/dev/null)"
stop_helper r

# --- 10d. Audit round 2: a clear right after a copy (B-10), a pin that cannot be written (B-09), a device the compositor ends
# (B-15), a shell that does not read (B-14), the clipboard kept when the shell goes ------------------------------------------
s7=$tmp/state7
offers_of() { count "$tmp/$1.out" '^O\|'; }
devices=$(count "$tmp/main.out" '^DEVICE$')
start_helper t "$tmp/main.sock" --state "$s7"
waitline "$tmp/t.out" '^S\|ok' 5 >/dev/null || bad "helper t did not start"
hlp t R
waitline_nth "$tmp/main.out" '^DEVICE$' $((devices + 1)) 3 >/dev/null || bad "helper t has no device"
sleep 0.2
k1=$(copy_in t "$(offers_of t)" 'copied by a password manager')
srv main CLEAR
waitline "$tmp/t.out" "^K\\|$k1\$" 3 >/dev/null && pass "a clear within a minute of a copy is reported (K) for the shell to decide" || bad "no K line after a clear"
srv main CLEAR
sleep 0.3
check "...once only" 1 "$(count "$tmp/t.out" '^K\|')"
k2=$(copy_in t "$(offers_of t)" 'replaced by a blank copy')
o=$(offers_of t)
srv main "SELECT text/plain;charset=utf-8|hex:$(hex '   ')"
approve t "$o" x >/dev/null
waitline "$tmp/t.out" "^K\\|$k2\$" 3 >/dev/null && pass "a blank copy right after one counts as a clear" || bad "no K line after a blank copy"
k3=$(copy_in t "$(offers_of t)" 'pinned, never reported')
hlp t PIN "$k3"
waitline "$tmp/t.out" "^I\\|$k3\\|text\\|[^|]*\\|[0-9]+\\|[0-9]+\\|[1-9]" 3 >/dev/null || bad "the pin was not reported"
srv main CLEAR
sleep 0.3
check "a pinned copy is never reported by a clear" 0 "$(count "$tmp/t.out" "^K\\|$k3")"
# B-09: the pinned item's file cannot be written (a directory in its place): the shell is told, the item stays in the history.
k4=$(copy_in t "$(offers_of t)" 'a pin that cannot be written')
mkdir "$s7/pinned/$k4.item"
hlp t PIN "$k4"
waitline "$tmp/t.out" "^N\\|pin-failed\\|$k4\$" 3 >/dev/null && pass "a pin that cannot be written is reported (N pin-failed)" || bad "no pin-failed line"
last=$(tr "$US" '|' <"$tmp/t.out" | grep -a -E "^I\\|$k4\\|" | tail -n 1)
check "...and the item stays unpinned" 0 "$(field "$last" 7)"
rmdir "$s7/pinned/$k4.item"
# B-15: the compositor ends the device: a new one is made, and copies are recorded again.
devices=$(count "$tmp/main.out" '^DEVICE$')
srv main FINISH
waitline_nth "$tmp/main.out" '^DEVICE$' $((devices + 1)) 3 >/dev/null && pass "a device the compositor ends is made again" || bad "no new device after finished"
sleep 0.3
copy_in t "$(offers_of t)" 'after the device came back' >/dev/null && pass "...and copies are recorded again" || bad "nothing recorded after the new device"
stop_helper t
# B-14: a shell that reads nothing for a while (its thread busy): the helper's lines wait, and it goes on serving pastes.
mkfifo "$tmp/u.in" "$tmp/u.pipe"
exec {upipe}<>"$tmp/u.pipe"
env -i PATH=/usr/bin:/bin "$helper" --display "$tmp/main.sock" --state "$s7" --runtime "$tmp/run/clipboard-u" \
  <"$tmp/u.in" >"$tmp/u.pipe" 2>"$tmp/u.err" &
pid_u=$!
pids+=("$pid_u")
exec {ufd}>"$tmp/u.in"
selections=$(count "$tmp/main.out" '^SELECTION ')
( # in the background: with a helper that blocks on its output, these writes block too
  printf 'R\n'
  for ((i = 1; i <= 12000; i++)); do printf 'Q\037%d\037zz\n' "$i"; done
  printf 'C\037%s\0370\n' "$k3"
) >&"$ufd" &
writer=$!
if waitline_nth "$tmp/main.out" '^SELECTION ' $((selections + 1)) 5 >/dev/null; then
  pasted=$(count "$tmp/main.out" '^PASTED ')
  srv main "PASTE text/plain;charset=utf-8 $tmp/u.paste"
  waitline_nth "$tmp/main.out" '^PASTED ' $((pasted + 1)) 3 >/dev/null && check "a helper whose shell reads nothing still serves a paste" \
    "pinned, never reported" "$(cat "$tmp/u.paste" 2>/dev/null)" || bad "no paste while the shell read nothing"
else
  bad "a helper whose shell reads nothing stopped (its output blocked it)"
fi
wait "$writer" 2>/dev/null
timeout 3 cat <&"$upipe" >"$tmp/u.out"
check "...and every line waited for the shell, in order" "12000 1" "$(count "$tmp/u.out" '^R\|') $(count "$tmp/u.out" "^A\\|$k3\$")"
# The shell goes (its stdin closed) while the helper serves the clipboard: it keeps serving it until another client takes it.
exec {ufd}>&-
sleep 0.5
if kill -0 "$pid_u" 2>/dev/null; then
  pass "the helper that serves the clipboard outlives its shell"
  pasted=$(count "$tmp/main.out" '^PASTED ')
  rm -f "$tmp/u.paste"
  srv main "PASTE text/plain;charset=utf-8 $tmp/u.paste"
  waitline_nth "$tmp/main.out" '^PASTED ' $((pasted + 1)) 3 >/dev/null
  check "...and still serves its item" "pinned, never reported" "$(cat "$tmp/u.paste" 2>/dev/null)"
  srv main "SELECT text/plain;charset=utf-8|hex:$(hex 'another app')"
  for _ in $(seq 1 50); do kill -0 "$pid_u" 2>/dev/null || break; sleep 0.05; done
  wait "$pid_u" 2>/dev/null
  check "...until another client takes the clipboard (exit 0)" 0 "$?"
  grep -a -q "the shell is gone: the clipboard's item is kept" "$tmp/u.err" && pass "...logged by reason" || bad "the kept clipboard is not logged"
else
  wait "$pid_u" 2>/dev/null
  bad "the helper ended with its shell although it served the clipboard"
fi
exec {upipe}<&-
# Without a clipboard to serve, the helper ends with its shell (exit 0).
start_helper w "$tmp/main.sock" --state "$s7"
waitline "$tmp/w.out" '^S\|ok' 5 >/dev/null || bad "helper w did not start"
v="hlp_w"
f=${!v}
exec {f}>&-
# shellcheck disable=SC2154 # set by start_helper (printf -v)
wait "$pid_w" 2>/dev/null
check "a helper that serves nothing ends with its shell (exit 0)" 0 "$?"

# --- 11. No content in the logs, unsupported compositors -----------------------------------------------------------------
if grep -a -q -- "$canary" "$tmp"/*.err; then bad "a copied text reached a log"; else pass "no copied text in any log"; fi
start_server nolock --no-lock-notifier
start_helper e "$tmp/nolock.sock"
# shellcheck disable=SC2154 # set by start_helper (printf -v)
wait "$pid_e" 2>/dev/null
check "a compositor without the lock notifier: unsupported, exit 3" "3 S|unsupported" "$? $(waitline "$tmp/e.out" '^S\|' 1)"

if ((fail)); then exit 1; fi
echo "PASS clipboard_helper: all"
