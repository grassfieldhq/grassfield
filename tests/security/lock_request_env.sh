#!/usr/bin/env bash
# Re-review of bf9e280 (M1): a lock request is not defeatable by the session's environment. A stray QS_MANIFEST or
# QS_CONFIG_NAME made every `qs <subcommand> -p` exit 108 ("--path excludes --manifest"), so the lock key, the lid and
# the sleep-lock fallback asked for nothing. Every Quickshell option variable (the "Env:" entries of `qs --help`:
# QS_CONFIG_PATH, QS_CONFIG_NAME, QS_MANIFEST today) is set to a stray value, and each installed caller must still send
# its request with none of them:
#   the lock key        config/hypr/grassfield/bindings.lua (SUPER+CTRL+Q), run by a plain Lua interpreter against a stub
#                       of Hyprland's hl table; the command it would exec runs under /bin/sh as Hyprland runs it
#   the lid             packaging/bin/grassfield-lid closed (its default lock command; fake /proc and /sys)
#   the fallback        packaging/shims/omarchy-shell lock lock (Omarchy's sleep-lock calls it in this session)
# A lock request always ends in a locked session (ADR-0041 S2, the opus review of 77a0ceb3, MAJOR-1): when the security
# process fails `lock lock` or hangs past 5 s, the lock key hands the request to the stand-in (its installed path replaced by
# a recorder here), which starts the unit; an answer (ok, already-locked, refused:*) is final; a dev session has no
# fallback (the installed stand-in would act on the owner's units).
# A stub qs records each call and the QS_* variables it received, and decides as the real qs would: it runs the REAL
# qs's option parsing (`qs list -p` on a scratch directory, a private runtime directory: nothing can reach a running
# shell) in the environment the caller gave it; exit 108 there is the failure guarded against. Control: the stub with the
# variables set, as the callers ran it before, exits 108. Also: every qs ipc command bindings.lua builds (binds and
# gestures) clears every option variable.
# Dev plumbing leaked into a real session (follow-up of the same review): the callers' test hooks are honoured only in a
# dev session (GRASSFIELD_DEV exactly "1", GRASSFIELD_SESSION not "1", ADR-0019). With GRASSFIELD_SESSION=1 and a leaked
# GRASSFIELD_DEV=1, and with no run-mode variable at all, hostile values of GRASSFIELD_LID_LOCK, GRASSFIELD_LID_FALLBACK,
# GRASSFIELD_DRM, GRASSFIELD_LID_PROC (grassfield-lid), GRASSFIELD_LID_TOOL (the clamshell stand-in, run from a copy whose
# installed lid path points at a recorder) and GRASSFIELD_SHELL_DIR (bindings.lua) change nothing: the real request is
# sent, no hostile command runs. Controls: in a dev session each hook is honoured. session.lua reads neither
# GRASSFIELD_CONFIG_DIR nor GRASSFIELD_SHIM_DIR (`Hyprland --verify-config` of the tree with a stray GRASSFIELD_CONFIG_DIR
# still parses; SKIP without Hyprland). SKIP without qs or lua. Plain shell test: PASS/FAIL, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
if ! command -v qs >/dev/null || ! command -v lua >/dev/null; then
  echo "SKIP: lock request env: qs or lua missing: NOT VERIFIED"
  exit 0
fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/lock-request-env.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "PASS: lock request env $*"; }
bad() { echo "FAIL: lock request env $*"; fail=1; }

mapfile -t opts < <(QT_QPA_PLATFORM=offscreen qs --help 2>&1 | grep -o '(Env:[A-Z0-9_]*)' | sed 's/^(Env:\(.*\))$/\1/' | sort -u)
if ((${#opts[@]} == 0)); then
  bad "qs --help names no option variable (Env:) here"
  exit 1
fi
stray=()
for v in "${opts[@]}"; do stray+=("$v=/stray/$v"); done

mkdir -p "$tmp/bin" "$tmp/cfg" "$tmp/home" "$tmp/run" "$tmp/proc/LID0" "$tmp/drm/card1-eDP-1"
mkdir -m 700 "$tmp/qsrt"
printf 'import Quickshell\nShellRoot {}\n' >"$tmp/cfg/shell.qml"
cat >"$tmp/bin/qs" <<'SH'
#!/bin/sh
echo "qs $*" >>"$STUB_LOG"
env | grep '^QS_' | sed 's/^/env /' >>"$STUB_LOG"
QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR="$STUB_QSRT" HOME="$STUB_HOME" /usr/bin/qs list -p "$STUB_CFG" >/dev/null 2>&1
[ $? = 108 ] && { echo "parse 108" >>"$STUB_LOG"; exit 108; }
case "$*" in
  "ipc -p /usr/share/grassfield/shell/security.qml call lock lock")
    case ${STUB_LOCK:-ok} in
      fail) exit 1 ;;
      hang) exec sleep 30 ;;
      refused) echo "refused: no outputs" ;;
      *) echo ok ;;
    esac ;;
  "ipc -p /usr/share/grassfield/shell/security.qml call lock lid") [ "${STUB_LID:-ok}" = fail ] && exit 1; echo ok ;;
  *) exit 9 ;;
esac
SH
printf '#!/bin/sh\necho "systemctl $*" >>"$STUB_LOG"\ncase "$*" in *ActiveState*) echo active ;; esac\nexit 0\n' >"$tmp/bin/systemctl"
printf '#!/bin/sh\necho "hyprctl $*" >>"$STUB_LOG"\n' >"$tmp/bin/hyprctl"
printf '#!/bin/sh\necho "fallback $*" >>"$STUB_LOG"\n' >"$tmp/bin/fallback"
for h in lock fallback lid; do printf '#!/bin/sh\necho "hijacked %s $*" >>"$STUB_LOG"\necho ok\n' "$h" >"$tmp/bin/hostile-$h"; done
printf '#!/bin/sh\necho "real-lid $*" >>"$STUB_LOG"\n' >"$tmp/bin/real-lid"
chmod +x "$tmp/bin/qs" "$tmp/bin/systemctl" "$tmp/bin/hyprctl" "$tmp/bin/fallback" "$tmp/bin/hostile-lock" "$tmp/bin/hostile-fallback" \
  "$tmp/bin/hostile-lid" "$tmp/bin/real-lid"
base=(PATH="$tmp/bin:/usr/bin:/bin" STUB_LOG="$tmp/log" STUB_QSRT="$tmp/qsrt" STUB_HOME="$tmp/home" STUB_CFG="$tmp/cfg" XDG_RUNTIME_DIR="$tmp/run")

# Control: the stub with the variables set (what the callers did before) is the real failure.
for v in QS_MANIFEST QS_CONFIG_NAME; do
  [[ " ${opts[*]} " == *" $v "* ]] || continue
  : >"$tmp/log"
  rc=0
  env -i "${base[@]}" "$v=/stray/$v" "$tmp/bin/qs" ipc -p /usr/share/grassfield/shell/security.qml call lock lock >/dev/null 2>&1 || rc=$?
  [[ $rc == 108 ]] && grep -qx "parse 108" "$tmp/log" && pass "control: with $v set, qs's own option parsing refuses the request (exit 108)" \
    || bad "control: with $v set the stub did not reproduce the failure (rc $rc)"
done

# verdict <label> <stdout> <rc> <expected call>: sent, answered, and no option variable reached qs.
verdict() {
  if [[ $3 == 0 && $2 == ok ]] && grep -qx "qs $4" "$tmp/log" && ! grep -q "^env QS_\|^parse 108" "$tmp/log"; then
    pass "$1 still sends '$4' with ${opts[*]} set in the session, and qs gets none of them"
  else
    bad "$1 with ${opts[*]} set: rc $3, answer '$2', calls: $(tr '\n' ';' <"$tmp/log")"
  fi
}

# --- the lock key (bindings.lua) ---
cat >"$tmp/binds.lua" <<'LUA'
local repo = arg[1]
local binds, gestures, execs = {}, {}, {}
local function proxy(path)
  return setmetatable({}, { __index = function(_, k) return proxy(path .. "." .. k) end,
                            __call = function(_, ...) return { dsp = path, args = { ... } } end })
end
hl = setmetatable({
  bind = function(keys, d) binds[#binds + 1] = { keys = keys, d = d } end,
  gesture = function(g) gestures[#gestures + 1] = g end,
  exec_cmd = function(c) execs[#execs + 1] = c end,
}, { __index = function() return function() end end })
hl.dsp = proxy("dsp")
dofile(repo .. "/config/hypr/grassfield/bindings.lua")
for _, b in ipairs(binds) do
  if type(b.d) == "table" and b.d.dsp == "dsp.exec_cmd" then
    print((b.keys == "SUPER + CTRL + Q" and "lock\t" or "bind\t") .. b.d.args[1])
  end
end
for _, g in ipairs(gestures) do if type(g.action) == "function" then g.action() end end
for _, c in ipairs(execs) do print("gesture\t" .. c) end
LUA
binds() { env -i PATH=/usr/bin:/bin "$@" lua "$tmp/binds.lua" "$root" 2>&1; }
lua_out=$(binds GRASSFIELD_SESSION=1) || bad "bindings.lua did not load in the Lua stub: $lua_out"
lock_cmd=$(awk -F'\t' '$1 == "lock" {print $2; exit}' <<<"$lua_out")
if [[ -z $lock_cmd ]]; then
  bad "the lock key: no exec command for SUPER + CTRL + Q"
else
  : >"$tmp/log"
  rc=0
  standin=/usr/lib/grassfield/omarchy-shims/omarchy-shell
  key_cmd=${lock_cmd//"$standin"/"$tmp/bin/fallback"}
  out=$(env -i "${base[@]}" "${stray[@]}" /bin/sh -c "$key_cmd" 2>/dev/null) || rc=$?
  verdict "the lock key (SUPER+CTRL+Q)" "$out" "$rc" "ipc -p /usr/share/grassfield/shell/security.qml call lock lock"
  ! grep -q "^fallback" "$tmp/log" && pass "the lock key: an answered request goes no further (no fallback)" \
    || bad "the lock key ran the fallback after an answer: $(tr '\n' ';' <"$tmp/log")"
  if [[ $key_cmd == "$lock_cmd" ]]; then
    bad "the lock key of a real session names no fallback ($standin): '$lock_cmd'"
  fi
  for answer in fail hang refused; do
    : >"$tmp/log"
    start=$SECONDS
    out=$(env -i "${base[@]}" "${stray[@]}" STUB_LOCK=$answer timeout 20 /bin/sh -c "$key_cmd" 2>/dev/null) || true
    took=$((SECONDS - start))
    case $answer in
      refused)
        [[ $out == "refused: no outputs" ]] && ! grep -q "^fallback" "$tmp/log" \
          && pass "the lock key: a refusal of the security process is its answer (no fallback)" \
          || bad "the lock key, refused: '$out', calls: $(tr '\n' ';' <"$tmp/log")" ;;
      *)
        if grep -qx "qs ipc -p /usr/share/grassfield/shell/security.qml call lock lock" "$tmp/log" && grep -qx "fallback lock lock" "$tmp/log" \
          && ! grep -q "^env QS_\|^parse 108" "$tmp/log" && ((took <= 8)); then
          pass "the lock key: a security process that ${answer}s (${took} s) hands the request to the stand-in ('lock lock'), which starts the unit"
        else
          bad "the lock key, security process ${answer}s: ${took} s, calls: $(tr '\n' ';' <"$tmp/log")"
        fi ;;
    esac
  done
fi
dev_key=$(binds GRASSFIELD_DEV=1 | awk -F'\t' '$1 == "lock" {print $2; exit}')
[[ -n $dev_key && $dev_key != *omarchy-shims* && $dev_key != *timeout* ]] \
  && pass "control: the lock key of a dev session has no fallback to the installed stand-in" || bad "the dev lock key: '$dev_key'"
uncleared=()
n=0
while IFS=$'\t' read -r _ cmd; do
  [[ $cmd == *"qs ipc"* ]] || continue
  n=$((n + 1))
  prefix=${cmd%%qs ipc*}
  for v in "${opts[@]}"; do [[ $prefix == *"-u $v "* ]] || uncleared+=("$v in: $cmd"); done
done <<<"$lua_out"
((n > 0 && ${#uncleared[@]} == 0)) && pass "every qs ipc command bindings.lua builds ($n, binds and gestures) clears ${opts[*]}" \
  || bad "bindings.lua: $n qs ipc commands; not cleared: ${uncleared[*]:-none found}"
[[ $(grep -c '"qs ipc' config/hypr/grassfield/bindings.lua) == 0 ]] && pass "bindings.lua has no other qs ipc command text" \
  || bad "bindings.lua builds a qs ipc command outside qs_ipc: $(grep -n '"qs ipc' config/hypr/grassfield/bindings.lua | tr '\n' ' ')"

# --- the lid (grassfield-lid closed, no external display: the shell is asked to lock) ---
printf 'state:      closed\n' >"$tmp/proc/LID0/state"
printf 'connected\n' >"$tmp/drm/card1-eDP-1/status"
: >"$tmp/log"
rc=0
env -i "${base[@]}" "${stray[@]}" GRASSFIELD_SESSION=1 bash packaging/bin/grassfield-lid closed >/dev/null 2>&1 || rc=$?
sleep 0.5 # the fallback would run detached
if [[ $rc == 0 ]] && grep -qx "qs ipc -p /usr/share/grassfield/shell/security.qml call lock lid" "$tmp/log" && ! grep -q "^env QS_\|^parse 108\|^fallback" "$tmp/log"; then
  pass "the lid (grassfield-lid closed) still sends 'ipc -p /usr/share/grassfield/shell/security.qml call lock lid' with ${opts[*]} set, qs gets none of them, no fallback needed"
else
  bad "the lid with ${opts[*]} set: rc $rc, calls: $(tr '\n' ';' <"$tmp/log")"
fi

# --- the sleep-lock fallback (the omarchy-shell stand-in) ---
: >"$tmp/log"
rc=0
out=$(env -i "${base[@]}" "${stray[@]}" HYPRLAND_INSTANCE_SIGNATURE=sig sh packaging/shims/omarchy-shell lock lock 2>/dev/null) || rc=$?
verdict "the sleep-lock fallback (omarchy-shell lock lock)" "$out" "$rc" "ipc -p /usr/share/grassfield/shell/security.qml call lock lock"

# --- dev plumbing leaked into a real session ---
mkdir -p "$tmp/hproc/LID0" "$tmp/hdrm/card9-eDP-9" "$tmp/hdrm/card9-DP-9"
printf 'state:      closed\n' >"$tmp/hproc/LID0/state"
printf 'connected\n' >"$tmp/hdrm/card9-eDP-9/status"
printf 'connected\n' >"$tmp/hdrm/card9-DP-9/status"
lid_hooks=(GRASSFIELD_LID_LOCK="$tmp/bin/hostile-lock" GRASSFIELD_LID_FALLBACK="$tmp/bin/hostile-fallback" GRASSFIELD_DRM="$tmp/hdrm" GRASSFIELD_LID_PROC="$tmp/hproc")
lidrun() { # <answer of lock lid: ok|fail> <subcommand> <run-mode assignments...>
  local answer=$1 sub=$2
  shift 2
  : >"$tmp/log"
  rm -f "$tmp/run/grassfield-lid-internal-off" # each run starts with the laptop panel on
  env -i "${base[@]}" "${lid_hooks[@]}" STUB_LID="$answer" "$@" bash packaging/bin/grassfield-lid "$sub" >/dev/null 2>&1 || true
  sleep 1 # a fallback would run detached
}
for mode in "GRASSFIELD_SESSION=1 GRASSFIELD_DEV=1" "-"; do
  label="a real session (GRASSFIELD_SESSION=1, a leaked GRASSFIELD_DEV=1)"
  [[ $mode == - ]] && label="no run-mode variable at all"
  read -r -a assign <<<"${mode/#-/}"
  lidrun ok closed "${assign[@]}"
  grep -qx "qs ipc -p /usr/share/grassfield/shell/security.qml call lock lid" "$tmp/log" && ! grep -q "^hijacked" "$tmp/log" \
    && pass "the lid in $label ignores GRASSFIELD_LID_LOCK: the installed shell is asked" || bad "the lid in $label: $(tr '\n' ';' <"$tmp/log")"
  lidrun fail closed "${assign[@]}" GRASSFIELD_DRM="$tmp/drm" # no external display there: a fallback would run
  ! grep -q "^hijacked" "$tmp/log" && pass "the lid in $label, shell down: GRASSFIELD_LID_FALLBACK is ignored" \
    || bad "the lid in $label, shell down: $(tr '\n' ';' <"$tmp/log")"
  lidrun ok reconcile "${assign[@]}"
  ! grep -q "eDP-9" "$tmp/log" && pass "the lid in $label ignores GRASSFIELD_LID_PROC and GRASSFIELD_DRM (no panel switch for their fake lid and displays)" \
    || bad "the lid in $label used the hostile lid and display state: $(tr '\n' ';' <"$tmp/log")"
done
lidrun ok closed GRASSFIELD_DEV=1
grep -q "^hijacked lock" "$tmp/log" && pass "control: a dev session honours GRASSFIELD_LID_LOCK" || bad "control: dev session did not use GRASSFIELD_LID_LOCK: $(tr '\n' ';' <"$tmp/log")"
lidrun fail closed GRASSFIELD_DEV=1 GRASSFIELD_DRM="$tmp/drm" GRASSFIELD_LID_LOCK=false # a lock command that fails
grep -q "^hijacked fallback lock lock" "$tmp/log" && pass "control: a dev session honours GRASSFIELD_LID_FALLBACK" || bad "control: dev session did not use GRASSFIELD_LID_FALLBACK: $(tr '\n' ';' <"$tmp/log")"
lidrun ok reconcile GRASSFIELD_DEV=1
grep -q "eDP-9" "$tmp/log" && pass "control: a dev session honours GRASSFIELD_LID_PROC and GRASSFIELD_DRM" || bad "control: dev session ignored the lid and display hooks: $(tr '\n' ';' <"$tmp/log")"

# The clamshell stand-in, from a copy whose installed grassfield-lid path is a recorder (the real one must never run here).
clam=packaging/shims/omarchy-hyprland-monitor-clamshell
if [[ $(grep -cx 'lid=/usr/lib/grassfield/grassfield-lid' "$clam") == 1 ]]; then
  sed "s|^lid=/usr/lib/grassfield/grassfield-lid$|lid=$tmp/bin/real-lid|" "$clam" >"$tmp/clamshell"
  for mode in "GRASSFIELD_SESSION=1 GRASSFIELD_DEV=1" "-"; do
    label="a real session (GRASSFIELD_SESSION=1, a leaked GRASSFIELD_DEV=1)"
    [[ $mode == - ]] && label="no run-mode variable at all"
    read -r -a assign <<<"${mode/#-/}"
    : >"$tmp/log"
    env -i "${base[@]}" GRASSFIELD_LID_TOOL="$tmp/bin/hostile-lid" "${assign[@]}" sh "$tmp/clamshell" >/dev/null 2>&1 || true
    [[ $(cat "$tmp/log") == "real-lid reconcile" ]] && pass "the clamshell stand-in in $label ignores GRASSFIELD_LID_TOOL" \
      || bad "the clamshell stand-in in $label: $(tr '\n' ';' <"$tmp/log")"
  done
  : >"$tmp/log"
  env -i "${base[@]}" GRASSFIELD_LID_TOOL="$tmp/bin/hostile-lid" GRASSFIELD_DEV=1 sh "$tmp/clamshell" >/dev/null 2>&1 || true
  grep -q "^hijacked lid reconcile" "$tmp/log" && pass "control: a dev session honours GRASSFIELD_LID_TOOL" || bad "control: dev session ignored GRASSFIELD_LID_TOOL: $(tr '\n' ';' <"$tmp/log")"
else
  bad "the clamshell stand-in has no single line lid=/usr/lib/grassfield/grassfield-lid"
fi

# bindings.lua: GRASSFIELD_SHELL_DIR only in a dev session.
for mode in "GRASSFIELD_SESSION=1 GRASSFIELD_DEV=1" "-"; do
  label="a real session (GRASSFIELD_SESSION=1, a leaked GRASSFIELD_DEV=1)"
  [[ $mode == - ]] && label="no run-mode variable at all"
  read -r -a assign <<<"${mode/#-/}"
  cmd=$(binds GRASSFIELD_SHELL_DIR=/hostile/shell "${assign[@]}" | awk -F'\t' '$1 == "lock" && !done {print $2; done = 1}')
  [[ $cmd == *"-p '/usr/share/grassfield/shell/security.qml' call lock lock "* && $cmd != *hostile* ]] \
    && pass "the lock key in $label ignores GRASSFIELD_SHELL_DIR: it asks the installed shell" || bad "the lock key in $label: '$cmd'"
done
cmd=$(binds GRASSFIELD_SHELL_DIR=/dev/shell GRASSFIELD_DEV=1 | awk -F'\t' '$1 == "lock" && !done {print $2; done = 1}')
[[ $cmd == *"-p '/dev/shell/security.qml' call lock lock" ]] && pass "control: a dev session sends the lock key to the security root in GRASSFIELD_SHELL_DIR" || bad "control: dev lock key '$cmd'"

# session.lua: its modules from its own directory, the stand-ins from the fixed one.
if grep -v '^[[:space:]]*--' config/hypr/session.lua | grep -q 'GRASSFIELD_CONFIG_DIR\|GRASSFIELD_SHIM_DIR'; then
  bad "session.lua reads GRASSFIELD_CONFIG_DIR or GRASSFIELD_SHIM_DIR: $(grep -n 'GRASSFIELD_CONFIG_DIR\|GRASSFIELD_SHIM_DIR' config/hypr/session.lua | grep -v -- '--' | tr '\n' ' ')"
else
  pass "session.lua reads neither GRASSFIELD_CONFIG_DIR nor GRASSFIELD_SHIM_DIR"
fi
if hypr=$(command -v Hyprland); then
  mkdir -m 700 "$tmp/hyprrt"
  vout=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$tmp/hyprrt" GRASSFIELD_CONFIG_DIR=/nonexistent/hypr \
    GRASSFIELD_SHIM_DIR=/nonexistent/shims timeout 60 "$hypr" --verify-config --config "$root/config/hypr/session.lua" 2>&1 || true)
  grep -qx 'config ok' <<<"$(sed -n '/Config parsing result/,$p' <<<"$vout")" \
    && pass "Hyprland --verify-config of session.lua with a stray GRASSFIELD_CONFIG_DIR still loads the tree's modules (config ok)" \
    || bad "session.lua with a stray GRASSFIELD_CONFIG_DIR: $(grep -m 3 -i 'error\|failed' <<<"$vout" | tr '\n' ' ' | cut -c1-300)"
else
  echo "SKIP: lock request env: no Hyprland binary: session.lua with a stray GRASSFIELD_CONFIG_DIR NOT VERIFIED"
fi
exit $fail
