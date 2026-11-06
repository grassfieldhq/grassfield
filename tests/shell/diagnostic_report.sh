#!/usr/bin/env bash
# ADR-0053: packaging/bin/grassfield-report, the diagnostic report for beta testers, against fakes of every command it runs
# (pacman, hyprctl, wpctl, coredumpctl, journalctl on PATH) and a fake home. Checks: one file in the user's own Downloads
# folder (user-dirs.dirs), mode 0600, never overwritten; every section; the displays without their serial; the home, the user
# name and secret-looking values removed (configuration and journal); bounded size; a missing tool is a line, not a failure;
# never as root; no sudo and no network in the source; the test hook only in a dev session. Nothing here reads the session:
# the commands are stubs and HOME is a scratch folder. Run as root (a container), the script runs as nobody (setpriv).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/diag-report.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
script=$root/packaging/bin/grassfield-report
py=$(command -v python3)

home=$tmp/home/alice
dl="$home/Téléchargements"
mkdir -p "$tmp/nobin" "$tmp/log" "$tmp/bin" "$tmp/root/usr/share/grassfield" "$tmp/root/etc" "$home/.config/grassfield" "$dl" "$tmp/out"
printf '0.9.0-beta.3\n' >"$tmp/root/usr/share/grassfield/VERSION"
printf 'NAME="Omarchy"\nVERSION_ID=4.5.0\nBUILD_ID=rolling\nHOME_URL=x\n' >"$tmp/root/etc/os-release"
printf 'XDG_DESKTOP_DIR="$HOME/Bureau"\nXDG_DOWNLOAD_DIR="$HOME/T\303\251l\303\251chargements"\n' >"$home/.config/user-dirs.dirs"
cat >"$home/.config/grassfield/grassfield.json" <<EOF
{"version": 1, "wallpaper": {"source": "picture", "path": "$home/Pictures/a.jpg"},
 "online": {"apiKey": "SECRET-ONE", "token": "SECRET-TWO", "enabled": true},
 "keyboard": {"repeatRate": 30}, "password": "SECRET-THREE", "privateKey": "SECRET-SIX",
 "sshKey": "SECRET-EIGHT", "network": {"session_key": "SECRET-NINE"},
 "displays": {"main": [{"set": ["m:BOE|NE135|eDP-1", "s:Dell Inc.|U2723QE|SERIAL-MAIN-1"], "main": "s:Dell Inc.|U2723QE|SERIAL-MAIN-1"}]},
 "wallpaperOutputs": {"outputs": [{"display": {"name": "DP-3", "model": "U2723QE", "serial": "SERIAL-WP-2"}, "key": "s:U2723QE|SERIAL-WP-3"}]},
 "lock": {"idleMinutes": 5, "showMessage": true, "message": "If found call FREE-TEXT-LOCK 0612345678"}}
EOF
printf '{"version": 1, "serial": 7, "folders": {"%s/Secret Plans/Divorce": {"color": "red"}, "%s/Photos/Trip": {"glyph": "star"}}}\n' "$home" "$home" >"$home/.config/grassfield/folder-styles.json"
printf '{"version": 1, "outputs": {"DP-3": {"file": "%s/Pictures/Private/beach.jpg"}}}\n' "$home" >"$home/.config/grassfield/wallpaper-state.json"
printf 'theme = dark\npassword = SECRET-FOUR\nauth_token: SECRET-FIVE\npsk '"'"'SECRET-SEVEN'"'"'\npass=SECRET-TEN\n' >"$home/.config/grassfield/notes.conf"
ln -s /etc/hostname "$home/.config/grassfield/linked.json"

cat >"$tmp/bin/pacman" <<'SH'
#!/bin/sh
[ "$1" = "-Q" ] || exit 1
printf 'firefox 140.0-1\ngrassfield-desktop 0.9.0-1\ngrassfield-compositor 0.9.0-1\nhyprland 0.56.2-1\nomarchy 4.5.0-1\nqt6-base 6.10.1-1\nquickshell 0.3.2-1\nzsh 5.9-1\n'
SH
cat >"$tmp/bin/hyprctl" <<'SH'
#!/bin/sh
case "$*" in
  "-j monitors") printf '[{"id":0,"name":"DP-3","description":"Dell Inc. U2723QE SERIAL-XYZ-123","make":"Dell Inc.","model":"U2723QE","serial":"SERIAL-XYZ-123","width":3840,"height":2160,"refreshRate":60.0,"x":0,"y":0,"scale":1.5,"transform":0,"focused":true,"dpmsStatus":true,"vrr":false,"disabled":false},{"name":"eDP-1","make":"BOE","model":"NE135","serial":"","width":2256,"height":1504}]\n' ;;
  "version") echo "Hyprland 0.56.2 built from branch at commit abc" ;;
  "grassfield") if [ "${FAKE_PLUGIN:-on}" = on ]; then echo "grassfield 0.9.0 gfc/1 ready"; else echo "unknown request"; fi ;;
  *) echo "unexpected hyprctl $*" >&2; exit 3 ;;
esac
SH
cat >"$tmp/bin/wpctl" <<'SH'
#!/bin/sh
[ "$1" = status ] || exit 1
printf 'Audio\n ├─ Sinks:\n │  *   52. Built-in Audio Analog Stereo [vol: 0.40]\n │      61. Marie’s AirPods [vol: 0.50]\n │      62. Paul'"'"'s Headphones [vol: 0.50]\n'
SH
cat >"$tmp/bin/coredumpctl" <<SH
#!/bin/sh
echo "Thu 2026-11-05 10:00:00 UTC 4242 1000 1000 SIGSEGV present $home/bin/tool 1.2M"
SH
cat >"$tmp/bin/journalctl" <<SH
#!/bin/sh
echo "journalctl \$*" >"$tmp/log/journal-args"
if [ -n "\${FAKE_BIG:-}" ]; then i=0; while [ \$i -lt 40000 ]; do echo "2026-11-05T10:00:00+0000 vm grassfield-shell[1]: line \$i padding padding padding padding"; i=\$((i+1)); done; exit 0; fi
echo "2026-11-05T10:00:00+0000 vm grassfield-shell[1]: loaded $home/.config/grassfield/grassfield.json for alice"
echo "2026-11-05T10:00:01+0000 vm grassfield-shell[1]: request token=abcd1234zz Authorization: Bearer abcdefghijklmnopqrstu"
echo "2026-11-05T10:00:02+0000 vm grassfield-shell[1]: Alice opened Settings"
echo "2026-11-05T10:00:03+0000 vm grassfield-shell[1]: audio: default sink bluez_output.A0:B1:C2:D3:E4:F5.1"
echo "2026-11-05T10:00:04+0000 vm grassfield-shell[1]: audio: default output is now Marie’s AirPods"
echo "2026-11-05T10:00:05+0000 vm grassfield-shell[1]: the Dock's tile moved; Wayland's socket is back; Activity Monitor's list refreshed"
echo "2026-11-05T10:00:06+0000 vm grassfield-shell[1]: helper login pass=SECRET-ELEVEN pwd=SECRET-TWELVE"
SH
chmod 755 "$tmp/bin"/*

# As root (a container), the script runs as nobody: it refuses root by design.
as=()
if [[ $(id -u) == 0 ]]; then
  chown -R 65534:65534 "$tmp/home" "$tmp/out" "$tmp/log"
  chmod 755 "$tmp" "$tmp/bin" "$tmp/root"
  as=("$(command -v setpriv)" --reuid=65534 --regid=65534 --clear-groups)
fi
report() { # report [env...] -- args: prints the path; FAKE_PATH replaces PATH
  local envs=()
  while [[ $# -gt 0 && $1 != -- ]]; do envs+=("$1"); shift; done
  shift || true
  env -i HOME="$home" USER=alice LOGNAME=alice PATH="$tmp/bin:/usr/bin:/bin" GRASSFIELD_DEV=1 GRASSFIELD_REPORT_ROOT="$tmp/root" \
    XDG_CURRENT_DESKTOP=Hyprland "${envs[@]}" "${as[@]}" "$py" -I "$script" "$@"
}

out=$(report --) && rc=0 || rc=$?
desc="it writes one file in the user's Downloads folder (from user-dirs.dirs, in the user's language) and prints its path"
check test "$rc" = 0 -a -f "$out" -a "$(dirname "$out")" = "$dl"
case $(basename "$out") in grassfield-report-[0-9]*-[0-9]*.txt) named=1 ;; *) named=0 ;; esac
desc="it is named grassfield-report-<date>-<time>.txt"
check test "$named" = 1
desc="the file is private: mode 0600"
check test "$(stat -c %a "$out")" = 600
r=$(cat "$out")

desc="every section is there"
check bash -c 'for s in "Packages" "Omarchy" "Compositor" "Compositor plugin" "Displays" "Audio devices" "Crashes (last 7 days)" "Journal of the Grassfield units (this boot)" "Configuration"; do grep -qF "== $s" "$1" || { echo "missing $s"; exit 1; }; done' _ "$out"
desc="versions: Grassfield's VERSION, the Grassfield, Omarchy, Hyprland, Quickshell and Qt packages, not the others"
check bash -c 'grep -q "Grassfield version: 0.9.0-beta.3" "$1" && grep -q "^grassfield-desktop 0.9.0-1" "$1" && grep -q "^grassfield-compositor" "$1" && grep -q "^hyprland 0.56.2-1" "$1" && grep -q "^omarchy 4.5.0-1" "$1" && grep -q "^qt6-base" "$1" && grep -q "^quickshell" "$1" && ! grep -q "firefox\|zsh" "$1"' _ "$out"
desc="Omarchy's version from os-release"
check bash -c 'grep -q "^VERSION_ID=4.5.0" "$1" && grep -q "^NAME=Omarchy" "$1" && ! grep -q HOME_URL "$1"' _ "$out"
desc="the plugin is reported loaded with its own reply; the compositor's version is there"
check bash -c 'grep -A1 "== Compositor plugin" "$1" | grep -q "^loaded" && grep -q "Hyprland 0.56.2" "$1"' _ "$out"
desc="displays: make, model and mode kept, the serial replaced by whether there is one, no description"
check bash -c 'grep -q "U2723QE" "$1" && grep -q "\"serial\": \"present\"" "$1" && grep -q "\"serial\": \"none\"" "$1" && ! grep -q "SERIAL-XYZ" "$1" && ! grep -q description "$1"' _ "$out"
desc="audio devices from wpctl status, crashes from coredumpctl"
check bash -c 'grep -q "Built-in Audio Analog Stereo" "$1" && grep -q "SIGSEGV" "$1"' _ "$out"
desc="the journal is this boot's, of the Grassfield user units, bounded in lines"
check bash -c 'grep -q -- "--user -b 0 -u grassfield-\* --no-pager -o short-iso -n 3000" "$1"' _ "$tmp/log/journal-args"
desc="the home path is never in the report (shown as ~)"
check bash -c '! grep -qF "$2" "$1" && grep -qF "~/bin/tool" "$1" && grep -qF "~/.config/grassfield/grassfield.json" "$1"' _ "$out" "$home"
desc="the user name is never in the report, whatever its case"
check bash -c '! grep -qi "alice" "$1" && grep -q "<user> opened Settings" "$1"' _ "$out"
host=$(hostname 2>/dev/null || true)
if [[ ${#host} -ge 3 ]]; then
  desc="the host name is never in the report"
  check bash -c '! grep -qiw "$2" "$1"' _ "$out" "$host"
else
  echo "SKIP: the host name is too short to be replaced ($host)"
fi
desc="secret-looking values are removed from the configuration (JSON and key = value) and the journal; the rest is kept"
check bash -c '! grep -q "SECRET-\|abcd1234zz\|abcdefghijklmnopqrstu" "$1" && grep -q "\[redacted\]" "$1" && grep -q "\"repeatRate\": 30" "$1" && grep -q "^theme = dark" "$1" && grep -q "\"enabled\": true" "$1"' _ "$out"
desc="folder-styles.json is counted (2 entries), its folder paths are left out; a wallpaper path keeps only its file name"
check bash -c '! grep -q "Secret Plans\|Divorce\|Photos/Trip" "$1" && grep -q "2 entries" "$1" && ! grep -q "Pictures/Private\|Pictures/a.jpg" "$1" && grep -q "\"beach.jpg\"" "$1" && grep -q "\"a.jpg\"" "$1"' _ "$out"
desc="a symbolic link in the configuration folder is not followed"
check bash -c '! grep -q -- "--- linked.json" "$1"' _ "$out"
desc="monitor serials never leave through the configuration (displays.main keys, wallpaper outputs): replaced by present"
check bash -c '! grep -q "SERIAL-" "$1" && grep -qF "\"s:Dell Inc.|U2723QE|present\"" "$1" && grep -qF "\"m:BOE|NE135|eDP-1\"" "$1" && grep -qF "\"s:U2723QE|present\"" "$1" && grep -q "\"serial\": \"present\"" "$1"' _ "$out"
desc="the lock screen message (free text) is redacted, the lock settings are kept"
check bash -c '! grep -q "FREE-TEXT-LOCK\|0612345678" "$1" && grep -q "\"showMessage\": true" "$1" && grep -q "\"idleMinutes\": 5" "$1"' _ "$out"
desc="interface possessives in the journal keep their words (the Dock's tile, Wayland's socket, Activity Monitor's list); an audio line still loses the person's name"
check bash -c 'grep -qF "the Dock'"'"'s tile moved; Wayland'"'"'s socket is back; Activity Monitor'"'"'s list refreshed" "$1" && grep -qF "default output is now <name>’s AirPods" "$1"' _ "$out"
desc="people's names in device names (Marie’s AirPods, Paul's Headphones) and Bluetooth addresses are removed; the device kind stays"
check bash -c '! grep -q "Marie\|Paul" "$1" && grep -q "<name>’s AirPods" "$1" && grep -q "<name>'"'"'s Headphones" "$1" && ! grep -qi "A0:B1:C2:D3:E4:F5" "$1" && grep -q "bluez_output\." "$1"' _ "$out"
desc="the real name (GECOS) is replaced whole and word by word (3 characters or more, not generic); its other fields are not names"
check env -i PATH=/usr/bin:/bin "$py" -I -c '
import importlib.machinery, importlib.util, sys
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("report", sys.argv[1])
spec = importlib.util.spec_from_loader("report", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
names = m.identity_words("jdupont", "Jean Dupont,Room 4,555", "box")
words = [w for w, _ in names]
assert "Jean Dupont" in words and "Jean" in words and "Dupont" in words and "jdupont" in words, words
assert words.index("Jean Dupont") < words.index("Jean"), words  # the whole name first
assert "Room" not in words and "555" not in words, words
assert m.identity_words("user", "Al,Admin,,", "vm") == [], m.identity_words("user", "Al,Admin,,", "vm")
t = m.redact_identity("Jean’s AirPods; jean dupont; Jeanne stays; /h/x", "/h", names)
assert t == "<name>’s AirPods; <name>; Jeanne stays; ~/x", t
' "$script"

sleep 1.1
out2=$(report --)
desc="a second report is a new file; the first is untouched"
check test "$out2" != "$out" -a -f "$out2" -a "$(cat "$out")" = "$r"

target=$tmp/out/mine.txt
out3=$(report -- --output "$target")
out4=$(report -- --output "$target")
desc="--output names the file; an existing one is never overwritten (-2), both 0600"
check test "$out3" = "$target" -a "$out4" = "$tmp/out/mine-2.txt" -a "$(stat -c %a "$out3")" = 600 -a "$(stat -c %a "$out4")" = 600
out5=$(report -- --output "$tmp/out")
desc="--output may name a folder"
check test "$(dirname "$out5")" = "$tmp/out"
nowhere=$(report -- --output /proc/nowhere/x.txt 2>/dev/null) && rc=0 || rc=$?
desc="a folder that cannot be written: exit 1, nothing printed"
check test "$rc" = 1 -a -z "$nowhere"
report -- --bogus >/dev/null 2>&1 && rc=0 || rc=$?
desc="an unknown argument is a usage error (exit 2)"
check test "$rc" = 2

out6=$(report FAKE_PLUGIN=off --)
desc="a plugin that is not loaded is said so"
check bash -c 'grep -A1 "== Compositor plugin" "$1" | grep -q "^not loaded"' _ "$out6"

out7=$(report PATH="$tmp/nobin" --)
desc="missing tools are one line each, never a failure"
check bash -c 'for t in pacman hyprctl wpctl coredumpctl journalctl; do grep -qF "(not available: $t is not installed)" "$1" || exit 1; done' _ "$out7"

out8=$(report FAKE_BIG=1 --)
desc="a long journal is cut to its last 512 KiB (the report stays under 1 MiB)"
check bash -c '[[ $(stat -c %s "$1") -lt 1048576 ]] && grep -q "bytes left out" "$1" && grep -q "line 39999" "$1"' _ "$out8"

out9=$(env -i HOME="$home" USER=alice PATH="$tmp/bin:/usr/bin:/bin" GRASSFIELD_REPORT_ROOT="$tmp/root" "${as[@]}" "$py" -I "$script")
desc="the file-root hook is a dev-session hook only (ADR-0019): ignored in any other session"
check bash -c '! grep -q "0.9.0-beta.3" "$1"' _ "$out9"
out10=$(env -i HOME="$home" USER=alice PATH="$tmp/bin:/usr/bin:/bin" GRASSFIELD_DEV=1 GRASSFIELD_SESSION=1 GRASSFIELD_REPORT_ROOT="$tmp/root" "${as[@]}" "$py" -I "$script")
check bash -c '! grep -q "0.9.0-beta.3" "$1"' _ "$out10"

if [[ $(id -u) == 0 ]]; then
  desc="run as root it refuses (exit 2) and writes nothing"
  before=$(find "$tmp" -name 'grassfield-report-*' | wc -l)
  check bash -c 'env -i HOME="$2" PATH="$3" "$4" -I "$1" >/dev/null 2>&1; rc=$?; [[ $rc == 2 ]]' _ "$script" "$home" "$tmp/bin:/usr/bin:/bin" "$py"
  check test "$(find "$tmp" -name 'grassfield-report-*' | wc -l)" = "$before"
else
  desc="it refuses root (source)"
  check grep -q "os.geteuid() == 0" "$script"
fi
# The source is read as a syntax tree: every call that starts a process (the report's run(), subprocess.*, os.system/popen,
# os.exec*, os.spawn*, os.posix_spawn*) is rejected when any string in its arguments (lists and tuples included, and every word
# of a command string) names a privilege or network tool; network modules are rejected outright. Negative controls prove that
# each form is caught.
cat >"$tmp/nocmd.py" <<'PY'
import ast, os, sys
BANNED = {"sudo", "su", "pkexec", "run0", "doas", "curl", "wget", "nc", "ncat", "netcat", "socat", "ssh", "scp", "sftp", "rsync",
          "ftp", "telnet", "aria2c", "busctl", "systemctl", "pactl", "pw-play", "pw-record", "pw-cat", "arecord", "aplay", "paplay",
          "parecord", "nmcli", "bluetoothctl", "hyprctl-dispatch"}
SPAWN = {"run", "call", "check_call", "check_output", "Popen", "getoutput", "getstatusoutput", "system", "popen"}
NET_MODULES = {"urllib", "http", "requests", "ftplib", "smtplib", "telnetlib", "xmlrpc", "asyncio"}

def name_of(func):
    if isinstance(func, ast.Name):
        return func.id
    if isinstance(func, ast.Attribute):
        return func.attr
    return ""

def strings(node):
    for n in ast.walk(node):
        if isinstance(n, ast.Constant) and isinstance(n.value, str):
            yield n.value

def problems(source):
    out = []
    tree = ast.parse(source)
    for n in ast.walk(tree):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            mods = [a.name for a in n.names] if isinstance(n, ast.Import) else [n.module or ""]
            out += ["import %s" % m for m in mods if m.split(".")[0] in NET_MODULES]
        if isinstance(n, ast.Attribute) and n.attr in ("connect", "create_connection"):
            out.append("socket %s" % n.attr)
        if not isinstance(n, ast.Call):
            continue
        f = name_of(n.func)
        if not (f in SPAWN or f.startswith("exec") or f.startswith("spawn") or f.startswith("posix_spawn")):
            continue
        for s in (s for a in list(n.args) + [k.value for k in n.keywords] for s in strings(a)):
            for word in s.split():
                if os.path.basename(word) in BANNED:
                    out.append("%s(...%s...) line %d" % (f, word, n.lineno))
    return out

if sys.argv[1] == "--controls":
    bad = ['run(("sudo", "-n", "true"))', 'run(["timeout", "2", "curl", "https://x"])', 'os.system("curl https://x")',
           'subprocess.Popen(["/usr/bin/wget", "x"])', 'os.execvp("ssh", ["ssh", "h"])', 'os.spawnlp(os.P_WAIT, "scp", "scp", "a", "b")',
           'subprocess.check_output(args=["pkexec", "x"])', 'subprocess.run(["sh", "-c", "doas true"])', 'import urllib.request',
           'from http import client', 's.connect(("h", 1))', 'os.popen("nc -l 1")', 'os.posix_spawnp("su", ["su"], {})']
    missed = [b for b in bad if not problems(b)]
    clean = problems('run(["hyprctl", "version"]); run(["pacman", "-Q"]); x = {"ssh", "session"}; print("sudo is never used")')
    if missed or clean:
        print("missed:", missed, "false alarms:", clean)
        sys.exit(1)
    sys.exit(0)
found = problems(open(sys.argv[1], encoding="utf-8").read())
if found:
    print("\n".join(found))
sys.exit(1 if found else 0)
PY
desc="the no-privilege/no-network check catches every spawning form (negative controls: tuples, wrapped argv, shell strings, exec, spawn, network imports) and nothing harmless"
check "$py" -I "$tmp/nocmd.py" --controls
desc="the source runs no sudo, pkexec, network, recording or playback tool and opens no connection (syntax tree)"
check "$py" -I "$tmp/nocmd.py" "$script"
desc="the PKGBUILD installs it from packaging/bin and puts it on PATH"
check bash -c 'grep -qF "find \"\$root/packaging/bin\" -maxdepth 1 -type f -exec install -m755" "$1" && grep -qE "for tool in .*grassfield-report" "$1"' _ "$root/packaging/arch/PKGBUILD"
desc="no __pycache__ left in packaging/bin"
check test ! -e "$root/packaging/bin/__pycache__"

exit $fail
