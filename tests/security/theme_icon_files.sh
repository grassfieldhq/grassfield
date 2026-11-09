#!/usr/bin/env bash
# Integrator decisions after the reviews of 5ee6240 and 423766f: Qt never reads a user-writable icon file, and the shell
# only ever decodes images it produced itself. The shell's icon search paths hold only directories the user can neither
# write nor replace (ui/i18n/iconsearchpaths.h); every other icon or picture (a name found only in the user's folders, an
# Icon= path, a tray icon from an app's IconThemePath, a desktop or stack picture, media art, the account picture) is
# shown as a PNG made by shell/services/image-copy.py (safe open, then rsvg-convert fed on stdin). Every run below uses
# the REAL shell modules offscreen in a scratch HOME / XDG_DATA_HOME / XDG_DATA_DIRS / XDG_RUNTIME_DIR and must finish
# (a stalled GUI thread or image loader keeps the process from exiting). FIFOs an SVG names, and the icon FIFOs, have a
# writer waiting on them: any open for reading (the helper, librsvg or Qt) releases it and fails the case. Every file in
# the copy directory must be a PNG of at most 256 x 256 pixels.
#
# Part 1, files for the theme icon name "evil" in the user's icon folders (the notification icon and the polkit sheet's):
#   reg         a regular PNG                                   -> shown, as a PNG the shell made
#   fifo        a FIFO                                          -> the generic icon
#   link        a symlink to a FIFO elsewhere                   -> the generic icon
#   zero        a symlink to /dev/zero                          -> the generic icon
#   devnull     a symlink to /dev/null (.svg)                   -> the generic icon
#   svgfifo     a FIFO evil.svg                                 -> the generic icon
#   svgref      an SVG naming FIFOs (absolute and relative)     -> shown, rendered; the FIFOs never opened
#   gzsvg, u16svg, bompng, commentpng (review of 423766f, major 1: the byte check's bypasses): the same SVG gzip-compressed,
#               in UTF-16, and as evil.png behind a BOM or a comment -> shown, rendered; the FIFOs never opened
#   homefifo    a FIFO under ~/.icons/hicolor                   -> the generic icon
#   swap        shown, then a FIFO named by a new notification  -> its new copy is refused
# Qt must not see any of them (hasThemeIcon false: user folders are not searched).
# Part 2, the review's hostile user index.theme files (escaped sections and Inherits=, continuation lines, an escaped key,
# Inherits=.., Inherits=., a hicolor index in the user's folder with Adwaita as the theme): the shell's lookup never
# reads them, shows the generic icon and never stalls; Qt with a real session's search paths (user folders included,
# theme_icon_files.d/qt_icon_lookup.cpp, built here, SKIP without g++) stalls on each, so each case is real, and the same
# lookup after the shell's policy function (iconsearchpaths.h) finishes without finding the icon.
# Part 3, icons and pictures named by applications, files and players (Launchpad cells, desktop icons and thumbnails,
# the About panel, a flatpak user export symlink, a user icon symlinked outside the allowed roots, media art file: URLs
# naming a FIFO or an SVG that names one, the lock screen's account picture; the other sites' calls checked in the source).
# Part 4, the policy itself: the search paths the shell logs (read back from Qt) contain no directory the user can
# change; a regular icon in a user-writable pixmaps folder (Qt's fallback search path) that Qt finds and reads without
# the policy (a positive control: the same probe without Grassfield.I18n) is neither found nor opened with it (LD_PRELOAD
# open log, theme_icon_files.d/openlog.c), so this part fails when the policy is not applied. User THEME folders: Qt's
# offscreen platform searches none even without the policy (the control shows it), so their own check is reported NOT
# VERIFIED offscreen; part 2 (Qt with a real session's search paths, then the policy function) and the logged search
# paths cover them. The copy helper opens user icon files only with O_NOFOLLOW|O_NONBLOCK; a child process gets the
# environment unchanged. Plus the helper's cost with a user theme of 99k files.
# Part 5, tray icons (review of 423766f, major 2): the REAL TrayButton with items carrying what Quickshell reports for
# the review's hostile StatusNotifierItems (an IconThemePath full of FIFOs, an absolute or traversal IconName, a regular
# file named by path, an SVG naming a FIFO in the app's folder, a regular icon in it, a pixmap, a plain user name); then
# the same items as real StatusNotifierItems on a PRIVATE bus (dbus-daemon in the scratch directory, every process under
# `env -i` with only that address, a guard refusing any other bus; the session bus's default policy, checked first by
# theme_icon_files.d/bus_check.py: a reply and a signal must arrive; SKIP where Unix sockets cannot be created).
# Part 6, media art over https (coordinator, after the review of 80f0f19: macOS shows the artwork apps provide), offline:
# a local HTTPS server on 127.0.0.1 with a throwaway CA (theme_icon_files.d/fake_https.py; no proxy variable, no other
# host), reached as art.test through a test stand-in of the helper that changes only name resolution
# (image-copy-testnet.py). The helper fetches a PNG (from the checked address: --resolve) and an SVG naming a FIFO
# (rendered, the FIFO untouched), refuses text/html, a redirect to http or file:, a fourth redirect, more than 5 MiB
# (announced or chunked), a response slower than 5 s, an http URL and a URL with credentials; IP literals in every
# notation, localhost names, names resolving to loopback, private or mapped-loopback addresses and redirects to them
# never reach the server (review of dce68c2, minor 1); the address rule refuses every non-public range; requests carry
# no cookie, no credentials and only the fixed user agent. The shell (ThemeIcons.artSource) shows the art as a PNG it
# made, starts no fetch while the session is locked (the art already made still shows) and stops a fetch running when it
# locks (minor 3), fetches held URLs after unlocking, fetches only the newest of three URLs asked in one turn, and
# retries a failed URL with backoff, three tries at most (minor 4). Review of 684ed6d: curl always connects where the
# helper pinned (the machine's host name with a trailing dot, several dots, in uppercase, plain, or as a redirect
# Location with a trailing dot never reaches the loopback server the system resolver would give), the IPv6 forms that
# carry an IPv4 address are judged by it, the retry map is bounded and forgets URLs no longer shown, a lock inside the
# change that starts a run sends no request, and no curl outlives the helper (SIGTERM, SIGKILL, a stopped run).
# Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
ui/i18n/build-direct.sh >/dev/null
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/theme-icon-files.XXXXXX")
watchers=()
cleanup() {
  ((${#watchers[@]} == 0)) || kill "${watchers[@]}" 2>/dev/null || true
  [[ -f $tmp/bus.pid ]] && kill "$(cat "$tmp/bus.pid")" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
mkcfg() { # <dir> <probe>
  mkdir -p "$1"
  for entry in shell/*; do
    [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$1/$(basename "$entry")"
  done
  cp "tests/security/theme_icon_files.d/$2" "$1/shell.qml"
}
mkcfg "$tmp/cfg" probe.qml
png=iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
fail=0
pass() { echo "PASS: theme icon files $*"; }
bad() { echo "FAIL: theme icon files $*"; fail=1; }

shellenv() { # <scratch> -> the environment of a probe run
  local s=$1
  printf '%s\n' -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION \
    GRASSFIELD_DEV=1 HOME="$s/home" XDG_DATA_HOME="$s/home/.local/share" XDG_DATA_DIRS="$s/data:/usr/local/share:/usr/share" \
    XDG_CONFIG_HOME="$s/home/.config" XDG_STATE_HOME="$s/home/.local/state" GRASSFIELD_STATE_HOME="$s/state" GRASSFIELD_CONFIG_HOME="$s/config" \
    GRASSFIELD_TEST_TMP="$s" XDG_RUNTIME_DIR="$s/runtime" XDG_CACHE_HOME="$s/cache" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations"
}

scratch() { # <dir>: a fresh scratch tree with the regular user icon "ctl"
  local s=$1
  mkdir -p -m 700 "$s/runtime" "$s/cache"
  mkdir -p "$s/home/.local/share/icons/hicolor/48x48/apps" "$s/home/.icons" "$s/data/pixmaps" "$s/outside" "$s/state" "$s/config" "$s/opened"
  printf '%s' "$png" | base64 -d >"$s/home/.local/share/icons/hicolor/48x48/apps/ctl.png"
}

hostile_svg() { # <file> <absolute FIFO> [gzip|utf16|bom|comment]: an SVG naming the FIFO, and "ref.fifo" beside the file
  local doc
  doc="<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"64\" height=\"32\"><rect width=\"64\" height=\"32\" fill=\"red\"/><image xlink:href=\"$2\" width=\"8\" height=\"8\"/><image xlink:href=\"ref.fifo\" width=\"8\" height=\"8\"/></svg>"
  [[ -p $(dirname "$1")/ref.fifo ]] || mkfifo "$(dirname "$1")/ref.fifo"
  [[ -p $2 ]] || mkfifo "$2"
  case ${3:-} in
    gzip) printf '%s' "$doc" | gzip >"$1" ;;
    utf16) printf '%s' "$doc" | iconv -f UTF-8 -t UTF-16 >"$1" ;;
    bom) printf '\357\273\277%s' "$doc" >"$1" ;;
    comment) printf '<!-- c -->%s' "$doc" >"$1" ;;
    *) printf '%s' "$doc" >"$1" ;;
  esac
}

watch_fifos() { # <scratch> <fifo...>: a writer waits on each FIFO; an open for reading leaves a marker in <scratch>/opened
  local s=$1 f i=0
  shift
  for f in "$@"; do
    i=$((i + 1))
    timeout 300 sh -c 'exec 3>"$1" && echo "$1" >"$2"' sh "$f" "$s/opened/$i" 2>/dev/null &
    watchers+=($!)
  done
}

fifos_untouched() { # <scratch>: no watched FIFO was opened
  local opened
  opened=$(cat "$1"/opened/* 2>/dev/null || true)
  [[ -z $opened ]] || { echo "opened: ${opened//$1/\$S}"; return 1; }
}

copies_are_pngs() { # <scratch>: every file in the copy directory is a PNG of at most 256 x 256 pixels
  python3 -I - "$1"/runtime <<'PY'
import glob, os, sys
files = [f for d in glob.glob(os.path.join(sys.argv[1], "grassfield-icons-*")) for f in glob.glob(os.path.join(d, "*"))]
for f in files:
    head = open(f, "rb").read(24)
    w, h = int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR" or not (0 < w <= 256 and 0 < h <= 256):
        print("not a PNG the shell made:", os.path.basename(f))
        sys.exit(1)
PY
}

probe() { # <scratch> <kind> [VAR=value...]: one run of probe.qml; prints its line, sets rc
  local s=$1 kind=$2
  shift 2
  local -a e
  mapfile -t e < <(shellenv "$s")
  rc=0
  out=$(env "${e[@]}" PROBE_KIND="$kind" PROBE_USER_ICON="$s/home/.local/share/icons/hicolor/48x48/apps/evil.png" "$@" \
    timeout -k 3 60 qs -p "$tmp/cfg" --no-color 2>&1) || rc=$?
  line=$(grep -o "probe: .*" <<<"$out" | head -n 1 || true)
}

# ---- Part 1 ----
for kind in reg fifo link zero devnull svgfifo svgref gzsvg u16svg bompng commentpng homefifo swap; do
  s=$tmp/p1-$kind
  scratch "$s"
  A=$s/home/.local/share/icons/hicolor/48x48/apps
  case $kind in
    reg | swap) printf '%s' "$png" | base64 -d >"$A/evil.png" ;;
    fifo) mkfifo "$A/evil.png" ;;
    link) mkfifo "$s/outside/f" && ln -s "$s/outside/f" "$A/evil.png" ;;
    zero) ln -s /dev/zero "$A/evil.png" ;;
    devnull) ln -s /dev/null "$A/evil.svg" ;;
    svgfifo) mkdir -p "$s/home/.local/share/icons/hicolor/scalable/apps" && mkfifo "$s/home/.local/share/icons/hicolor/scalable/apps/evil.svg" ;;
    svgref) hostile_svg "$A/evil.svg" "$s/outside/f" ;;
    gzsvg) hostile_svg "$A/evil.svg" "$s/outside/f" gzip ;;
    u16svg) hostile_svg "$A/evil.svg" "$s/outside/f" utf16 ;;
    bompng) hostile_svg "$A/evil.png" "$s/outside/f" bom ;;
    commentpng) hostile_svg "$A/evil.png" "$s/outside/f" comment ;;
    homefifo) mkdir -p "$s/home/.icons/hicolor/48x48/apps" && mkfifo "$s/home/.icons/hicolor/48x48/apps/evil.png" ;;
  esac
  mapfile -t fifos < <(find "$s" -type p)
  watch_fifos "$s" "${fifos[@]}"
  probe "$s" "$kind"
  ok=1 note=
  ((rc == 0)) || ok=0
  [[ $line == *" has=false "* && $line == *" ctl=1"* ]] || ok=0
  case $kind in
    reg | svgref | gzsvg | u16svg | bompng | commentpng) [[ $line == *" state=ok notif=copy polkit=copy evil=1 "* ]] || ok=0 ;;
    swap) [[ $line == *" before=ok:shown state=no notif=none polkit=none evil=0 "* ]] || ok=0 ;;
    *) [[ $line == *" state=no notif=none polkit=none evil=0 "* ]] || ok=0 ;;
  esac
  note=$(fifos_untouched "$s") || ok=0
  copies_are_pngs "$s" >/dev/null || { ok=0; note="$note $(copies_are_pngs "$s" || true)"; }
  if ((ok)); then pass "$kind ($line)"; else bad "$kind: rc $rc, ${line:-no probe line} $note $(grep -E 'TypeError|ReferenceError' <<<"$out" | head -n 2)"; fi
done

# ---- Part 2 ----
qprobe=$tmp/qt_icon_lookup
if command -v g++ >/dev/null && [[ -f /usr/include/qt6/QtGui/QIcon ]]; then
  g++ -std=c++20 -fPIC -O1 -o "$qprobe" tests/security/theme_icon_files.d/qt_icon_lookup.cpp -Iui/i18n -I/usr/include/qt6 -I/usr/include/qt6/QtGui -I/usr/include/qt6/QtCore -lQt6Gui -lQt6Core
else
  qprobe=
  echo "SKIP: theme icon files, part 2 controls (Qt alone with user search paths): g++ or Qt headers missing"
fi
hostile() { # <case> <theme> <setup> [nostall]: the shell shows the generic icon without a stall; Qt alone stalls
  # (unless "nostall": a case the review asked to confirm irrelevant, slow rather than stuck for Qt alone)
  local name=$1 theme=$2 mode=${4:-} s=$tmp/p2-$1 U H qrc
  scratch "$s"
  H=$s/home; U=$H/.local/share/icons
  mkdir -p "$U/mytheme/48x48/apps"
  printf '[Icon Theme]\nName=mytheme\nInherits=hicolor\nDirectories=48x48/apps\n\n[48x48/apps]\nSize=48\nType=Fixed\n' >"$U/mytheme/index.theme"
  mkfifo "$s/outside/evil.png" "$s/outside/index.theme"
  eval "$3"
  probe "$s" "hostile-$name" QS_ICON_THEME="$theme"
  local ok=1 note=
  [[ $rc == 0 && $line == *" has=false "* && $line == *" state=no notif=none polkit=none evil=0 "* && $line == *" ctl=1"* ]] || { ok=0; note="shell: rc $rc ${line:-no probe line}"; }
  if [[ -n $qprobe ]]; then
    qrc=0
    env -i PATH="$PATH" HOME="$H" XDG_DATA_HOME="$H/.local/share" XDG_DATA_DIRS="$s/data:/usr/local/share:/usr/share" XDG_RUNTIME_DIR="$s/runtime" \
      QT_QPA_PLATFORM=offscreen timeout -k 1 4 "$qprobe" "$theme" evil >/dev/null 2>&1 || qrc=$?
    [[ $mode == nostall || $qrc == 124 ]] || { ok=0; note="$note; Qt alone did not stall (rc $qrc): the case proves nothing"; }
    # The same lookup after the shell's policy function (the offscreen shell above never had user search paths).
    qrc=0
    pout=$(env -i PATH="$PATH" HOME="$H" XDG_DATA_HOME="$H/.local/share" XDG_DATA_DIRS="$s/data:/usr/local/share:/usr/share" XDG_RUNTIME_DIR="$s/runtime" \
      QT_QPA_PLATFORM=offscreen timeout -k 1 8 "$qprobe" --policy "$theme" evil 2>/dev/null) || qrc=$?
    [[ $qrc == 0 && $pout == *"has evil=0"* && $pout == *done* ]] || { ok=0; note="$note; with the policy Qt still stalled or found it (rc $qrc)"; }
  fi
  local said="Qt alone stalls, Qt under the policy does not"
  [[ $mode == nostall ]] && said="Qt under the policy finishes"
  if ((ok)); then pass "hostile index.theme: $name (generic icon, no stall${qprobe:+; $said})"; else bad "hostile index.theme: $name: $note"; fi
}
hostile esc-section-backslash mytheme 'printf "\n[..\\\\..\\\\..\\\\..\\\\..\\\\outside]\nSize=48\nType=Fixed\n" >>"$U/mytheme/index.theme"; sed -i "s|^Directories=48x48/apps|Directories=48x48/apps,..\\\\\\\\..\\\\\\\\..\\\\\\\\..\\\\\\\\..\\\\\\\\outside|" "$U/mytheme/index.theme"'
hostile esc-section-percent mytheme 'printf "\n[%%2E%%2E/%%2E%%2E/%%2E%%2E/%%2E%%2E/%%2E%%2E/outside]\nSize=48\nType=Fixed\n" >>"$U/mytheme/index.theme"; sed -i "s|^Directories=48x48/apps|Directories=48x48/apps,%2E%2E/%2E%2E/%2E%2E/%2E%2E/%2E%2E/outside|" "$U/mytheme/index.theme"'
hostile inherits-hex-slash mytheme 'sed -i "s|^Inherits=hicolor|Inherits=..\\\\x2f..\\\\x2f..\\\\x2f..\\\\x2foutside|" "$U/mytheme/index.theme"'
hostile inherits-octal-slash mytheme 'sed -i "s|^Inherits=hicolor|Inherits=..\\\\57..\\\\57..\\\\57..\\\\57outside|" "$U/mytheme/index.theme"'
hostile inherits-escaped-key mytheme 'sed -i "s|^Inherits=hicolor|Inherit%73=../../../../outside|" "$U/mytheme/index.theme"'
hostile inherits-continuation mytheme 'sed -i "s|^Inherits=hicolor|Inherits=hicolor,\\\\\n../../../../outside|" "$U/mytheme/index.theme"'
hostile inherits-dotdot mytheme 'sed -i "s|^Inherits=hicolor|Inherits=..|" "$U/mytheme/index.theme"; mkfifo "$H/.local/share/index.theme"'
hostile inherits-dot mytheme 'sed -i "s|^Inherits=hicolor|Inherits=.|" "$U/mytheme/index.theme"; mkfifo "$U/index.theme"'
hostile user-hicolor-under-adwaita Adwaita 'printf "[Icon Theme]\nName=hicolor\nInherit%%73=../../../../outside\nDirectories=48x48/apps\n\n[48x48/apps]\nSize=48\nType=Fixed\n" >"$U/hicolor/index.theme"'
hostile fifo-index-and-cache mytheme 'rm "$U/mytheme/index.theme"; mkfifo "$U/mytheme/index.theme" "$U/mytheme/icon-theme.cache"'
# The review's minors, confirmed irrelevant once user folders are out of Qt's search paths: a 60 MiB index.theme, a theme
# that is a symlink to /proc/self.
hostile huge-index mytheme 'head -c 62914560 /dev/zero | tr "\\0" "x" >>"$U/mytheme/index.theme"' nostall
hostile proc-symlink-theme mytheme 'rm -r "$U/mytheme"; ln -s /proc/self "$U/mytheme"' nostall

# ---- Part 3: icons and pictures named by applications, files and players ----
mkcfg "$tmp/dcfg" desktop_probe.qml
s=$tmp/desktop
scratch "$s"
mkdir -p "$s/home/.local/share/applications" "$s/home/Desktop" "$s/elsewhere" "$s/data/icons/hicolor/48x48/apps"
printf '%s' "$png" | base64 -d >"$s/data/pixmaps/ctl.png"
printf '%s' "$png" | base64 -d >"$s/elsewhere/good.png"
mkfifo "$s/elsewhere/evil-path.png" "$s/data/pixmaps/evilname.png" "$s/elsewhere/art.fifo" "$s/elsewhere/face.fifo"
# A flatpak user export: the exported icon is a symlink into the user's flatpak tree (allowed: under $HOME).
flat=$s/home/.local/share/flatpak/app/org.example.App/x86_64/stable/0123/export/share/icons/hicolor/48x48/apps
mkdir -p "$flat"
printf '%s' "$png" | base64 -d >"$flat/org.example.App.png"
ln -s "$flat/org.example.App.png" "$s/data/icons/hicolor/48x48/apps/org.example.App.png"
# A user icon that is a symlink to an image outside every allowed root (a PNG of this repository, outside the scratch
# HOME and the system folders): refused. Only meaningful when the checkout itself lies outside the allowed roots.
# sed reads the whole list: `head -n 1` would close the pipe early and, under pipefail, git's SIGPIPE ends the test.
outside_png=$(git ls-files '*.png' | sed -n 1p)
outside_case=0
case $root in /tmp/* | /var/tmp/* | /usr/* | /opt/* | /srv/* | /mnt/* | /media/* | /run/*) ;; *) [[ -n $outside_png ]] && outside_case=1 ;; esac
if ((outside_case)); then
  ln -s "$root/$outside_png" "$s/data/icons/hicolor/48x48/apps/gf-outside.png"
else
  printf 'x' >"$s/data/icons/hicolor/48x48/apps/gf-outside.png"
fi
hostile_svg "$s/elsewhere/art.jpg" "$s/elsewhere/art-ref.fifo"
hostile_svg "$s/home/.face" "$s/elsewhere/face-ref.fifo" gzip
desk() { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=true\nIcon=%s\n' "$1" "$2" >"$s/home/.local/share/applications/$1.desktop"; }
desk gf-fifo-path "$s/elsewhere/evil-path.png"
desk gf-fifo-name evilname
desk gf-ok-path "$s/elsewhere/good.png"
desk gf-ok-name ctl
desk gf-flatpak org.example.App
desk gf-outside gf-outside
cp "$s/home/.local/share/applications/gf-fifo-path.desktop" "$s/home/.local/share/applications/gf-fifo-name.desktop" "$s/home/Desktop/"
mkfifo "$s/home/Desktop/photo.png"
watch_fifos "$s" "$s/elsewhere/art.fifo" "$s/elsewhere/face.fifo" "$s/elsewhere/art-ref.fifo" "$s/elsewhere/ref.fifo" "$s/elsewhere/face-ref.fifo" "$s/home/ref.fifo" \
  "$s/elsewhere/evil-path.png" "$s/data/pixmaps/evilname.png"
mapfile -t e < <(shellenv "$s")
rc=0
out=$(env "${e[@]}" PROBE_DESKTOP="$s/home/Desktop" PROBE_ART_FIFO="$s/elsewhere/art.fifo" PROBE_ART_SVG="$s/elsewhere/art.jpg" \
  PROBE_FACE_SVG="$s/home/.face" PROBE_FACE_FIFO="$s/elsewhere/face.fifo" timeout -k 3 90 qs -p "$tmp/dcfg" --no-color 2>&1) || rc=$?
dline() { grep -o "probe: $1 .*" <<<"$out" | head -n 1 || true; }
dcheck() { # <label> <ok>
  if [[ $2 == 1 ]]; then pass "application icons and pictures: $1"; else bad "application icons and pictures: $1 (rc $rc; $(grep -o 'probe: .*' <<<"$out" | tr '\n' '|' | cut -c1-600))"; fi
}
l=$(dline gf-fifo-path); dcheck "a FIFO Icon= path is refused" "$([[ $l == *" verdict=no source= "* ]] && echo 1)"
l=$(dline gf-fifo-name); dcheck "an Icon= name whose user file is a FIFO is refused" "$([[ $l == *" verdict=no source= "* ]] && echo 1)"
l=$(dline gf-ok-path); dcheck "a regular Icon= path is shown as a copy and prewarmed" "$([[ $l == *" verdict=ok source=copy prewarmed=true"* ]] && echo 1)"
l=$(dline gf-ok-name); dcheck "a user-installed icon name is shown as a copy and prewarmed" "$([[ $l == *" verdict=ok source=copy prewarmed=true"* ]] && echo 1)"
l=$(dline gf-flatpak); dcheck "a flatpak user export (a symlink into ~/.local/share/flatpak) is shown as a copy" "$([[ $l == *" verdict=ok source=copy prewarmed=true"* ]] && echo 1)"
if ((outside_case)); then
  l=$(dline gf-outside); dcheck "a user icon symlinked to an image outside the allowed roots is refused" "$([[ $l == *" verdict=no source= "* ]] && echo 1)"
else
  echo "SKIP: theme icon files, the outside-the-roots symlink case (this checkout lies under an allowed root)"
fi
l=$(dline thumbnail); dcheck "a desktop picture that is a FIFO gets no thumbnail" "$([[ $l == "probe: thumbnail verdict=no source=" ]] && echo 1)"
l=$(dline art-fifo); dcheck "media art: a file: URL naming a FIFO is refused" "$([[ $l == "probe: art-fifo verdict=no source=" ]] && echo 1)"
l=$(dline art-svgref); dcheck "media art: a file: URL naming an SVG that names FIFOs becomes a PNG" "$([[ $l == "probe: art-svgref verdict=ok source=copy" ]] && echo 1)"
l=$(dline face-svgref); dcheck "the account picture: a gzip SVG ~/.face naming FIFOs becomes a PNG" "$([[ $l == "probe: face-svgref verdict=ok source=copy" ]] && echo 1)"
l=$(dline face-fifo); dcheck "the account picture: a FIFO is refused (the initials)" "$([[ $l == "probe: face-fifo verdict=no source=" ]] && echo 1)"
l=$(dline "pictures loaded"); dcheck "the PNGs made from them load" "$([[ $l == "probe: pictures loaded art-svgref=1 face-svgref=1" ]] && echo 1)"
dcheck "Launchpad cells, desktop icons, the About panel, art and the avatar never stalled the loader or the GUI thread" "$([[ $rc == 0 && $(dline done) == "probe: done ctl=1" ]] && echo 1)"
note=$(fifos_untouched "$s") && copies_are_pngs "$s" >/dev/null && dcheck "no FIFO was opened; every copy is a PNG the shell made" 1 || dcheck "no FIFO was opened; every copy is a PNG the shell made: $note" 0
site_ok=1
for site in 'shell/overview/MiniDesktop.qml:ThemeIcons.appIcon(Apps.lookup(card.modelData.appId) ? Apps.lookup(card.modelData.appId).icon' 'shell/overview/OverviewWindow.qml:ThemeIcons.appIcon(mini.entry ? mini.entry.icon' \
  'shell/overview/OverviewWindow.qml:ThemeIcons.appIcon(label.entry ? label.entry.icon' 'shell/overlay/ForceQuitPanel.qml:return ThemeIcons.appIcon(e ? e.icon' \
  'shell/overlay/AppAboutPanel.qml:ThemeIcons.appIcon(root.entry ? root.entry.icon' 'shell/switcher/SwitcherWindow.qml:ThemeIcons.appIcon(tile.modelData.icon' \
  'shell/search/SearchPanel.qml:ThemeIcons.appIcon(row.info.appIcon' 'shell/search/Search.qml:iconSource: "", appIcon: r.app.icon' \
  'shell/dock/Dock.qml:ThemeIcons.appIcon(tile.modelData.icon, "application-x-executable")' 'shell/dock/StackIcon.qml:ThemeIcons.fileSource(root.path)' \
  'shell/dock/StackIcon.qml:ThemeIcons.appIcon(names.length > 0 ? names[0] : ""' 'shell/stages/Stages.qml:ThemeIcons.appIcon(tile.entry ? tile.entry.icon' \
  'shell/desktop/DesktopIcon.qml:ThemeIcons.fileSource(root.filePath)' \
  'shell/widgets/builtin/nowplaying/NowPlaying.qml:source: root.hasTrack ? ThemeIcons.artSource(Media.artShown) : ""' \
  'shell/overlay/controlcenter/NowPlaying.qml:source: ThemeIcons.artSource(Media.artShown)' 'shell/services/Media.qml:onTriggered: root.artShown = root.artUrl' \
  'shell/security/lock/Lock.qml:Machine.avatarSource(facePath, Machine.accountsIconPath(loginName), path => avatar.sourceOf(path), path => avatar.stateOf(path))' \
  'shell/security/lock/LockAvatar.qml:readonly property string helper: Quickshell.shellPath("services/image-copy.py")' \
  'shell/security/lock/LockAvatar.qml:maker.command = ["/usr/bin/timeout", "-k", "2", "20", "/usr/bin/setpriv", "--pdeathsig", "KILL", "--", "/usr/bin/python3", "-I", root.helper, "file", path, String(root.maxBytes), out];' \
  'shell/menubar/TrayButton.qml:readonly property string own: ThemeIcons.trayIcon(root.item ? root.item.icon : "")'; do
  grep -qF -- "${site#*:}" "${site%%:*}" || { echo "missing: $site"; site_ok=0; }
done
for f in shell/overview/OverviewWindow.qml shell/overview/MiniDesktop.qml shell/overlay/ForceQuitPanel.qml shell/overlay/AppAboutPanel.qml shell/switcher/SwitcherWindow.qml shell/search/SearchPanel.qml shell/launchpad/AppsCell.qml shell/desktop/DesktopIcon.qml shell/dock/Dock.qml shell/dock/StackIcon.qml shell/stages/Stages.qml; do
  grep -q 'Quickshell.iconPath(.*\(\.icon\b\|iconTheme\)' "$f" && { echo "unchecked: $f"; site_ok=0; }
done
# Nothing else hands a player's art URL, a tray item's icon URL or the account picture's path to an Image.
if grep -rn 'artUrl\|trackArtUrl' shell --include=*.qml | grep -v '^shell/services/Media.qml:'; then site_ok=0; fi
if grep -rn 'item\.icon\b\|modelData\.icon\b' shell/menubar --include=*.qml | grep -v 'ThemeIcons.trayIcon('; then site_ok=0; fi
if grep -n '\.face\|AccountsService' shell/security/lock/*.qml | grep -v 'facePath: \|^[^:]*:[0-9]*: *//'; then site_ok=0; fi
# ADR-0041 S2: the lock runs in the security process, which makes its one picture with the same helper (image-copy.py file)
# and never uses ThemeIcons (whose start empties the UI's copy directory).
if grep -n 'ThemeIcons' shell/security/lock/*.qml shell/security/idle/*.qml shell/security/host/SecurityHost.qml | grep -v '^[^:]*:[0-9]*: *//'; then site_ok=0; fi
dcheck "Search, the Switcher, the Overview, Stages, Force Quit, About, the Dock, its stacks, the desktop, Now Playing and the tray load such images through ThemeIcons, the lock through the same helper in its own process" "$site_ok"

# ---- Part 4: the policy ----
if ! command -v gcc >/dev/null; then
  echo "SKIP: theme icon files, part 4 open log (gcc missing)"
else
  gcc -shared -fPIC -O1 -o "$tmp/openlog.so" tests/security/theme_icon_files.d/openlog.c -ldl
  mkcfg "$tmp/pcfg" policy_probe.qml
  s=$tmp/policy
  scratch "$s"
  H=$s/home; U=$H/.local/share/icons
  mkdir -p "$H/.icons/hicolor" "$s/data/icons/hicolor/48x48/apps" "$U/mytheme/48x48/apps"
  # Regular files only: without the policy Qt finds these (hasThemeIcon true) and opens them, offscreen too.
  printf '[Icon Theme]\nName=Hicolor\nDirectories=48x48/apps\n\n[48x48/apps]\nSize=48\nType=Fixed\n' | tee "$U/hicolor/index.theme" "$H/.icons/hicolor/index.theme" "$s/data/icons/hicolor/index.theme" >/dev/null
  printf '[Icon Theme]\nName=mytheme\nInherits=hicolor\nDirectories=48x48/apps\n\n[48x48/apps]\nSize=48\nType=Fixed\n' >"$U/mytheme/index.theme"
  printf '%s' "$png" | base64 -d >"$U/hicolor/48x48/apps/useronly.png"
  printf '%s' "$png" | base64 -d >"$U/mytheme/48x48/apps/usertheme.png"
  printf '%s' "$png" | base64 -d >"$s/data/pixmaps/evilpix.png"
  mapfile -t e < <(shellenv "$s")
  user_icon_opens() { # <open log>: opens of files in the scratch's user icon folders
    grep -E "^OPEN [0-9]+ -?[0-9]+ ($s/home/\.local/share/icons|$s/home/\.icons|$s/home/\.local/share/pixmaps|$s/data/icons|$s/data/pixmaps)(/|$)" "$1" || true
  }
  # Positive control: the same probe without Grassfield.I18n (no policy) must find and open the user pixmap.
  mkdir -p "$tmp/pcfg-control"
  for entry in "$tmp"/pcfg/*; do [[ $(basename "$entry") == shell.qml ]] || ln -s "$(readlink "$entry")" "$tmp/pcfg-control/$(basename "$entry")"; done
  grep -v '^import Grassfield.I18n$' "$tmp/pcfg/shell.qml" >"$tmp/pcfg-control/shell.qml"
  crc=0
  cout=$(env "${e[@]}" QS_ICON_THEME=mytheme LD_PRELOAD="$tmp/openlog.so" OPENLOG="$tmp/control-opens.log" timeout -k 3 30 qs -p "$tmp/pcfg-control" --no-color 2>&1) || crc=$?
  control_ok=0
  grep -q "probe: evilpix has=true" <<<"$cout" && user_icon_opens "$tmp/control-opens.log" | grep -q "/data/pixmaps/evilpix.png$" && control_ok=1
  ((control_ok)) && pass "policy: control: without the policy Qt finds and opens the user pixmap (the case is real)" \
    || bad "policy: control: without the policy Qt did not find or open the user pixmap: the case proves nothing (rc $crc $(grep -o 'probe: .*' <<<"$cout" | tr '\n' '|'))"
  rc=0
  out=$(env "${e[@]}" QS_ICON_THEME=mytheme LD_PRELOAD="$tmp/openlog.so" OPENLOG="$tmp/policy-opens.log" timeout -k 3 30 qs -p "$tmp/pcfg" --no-color 2>&1) || rc=$?
  [[ $rc == 0 ]] && grep -q "probe: evilpix has=false" <<<"$out" && pass "policy: with it, Qt does not find the icon that lies only in a user-writable pixmaps folder" \
    || bad "policy: lookups: rc $rc $(grep -o 'probe: .*' <<<"$out" | tr '\n' '|')"
  # User theme folders: meaningful only where Qt searches them without the policy (never offscreen).
  if grep -q "probe: useronly has=true" <<<"$cout" && grep -q "probe: usertheme has=true" <<<"$cout"; then
    grep -q "probe: useronly has=false" <<<"$out" && grep -q "probe: usertheme has=false" <<<"$out" && pass "policy: with it, Qt finds no icon of the user's theme folders" \
      || bad "policy: user theme folders: $(grep -o 'probe: user.*' <<<"$out" | tr '\n' '|')"
  else
    echo "SKIP: theme icon files, policy: user theme folders: Qt's offscreen platform searches none even without the policy (control: $(grep -o 'probe: user[a-z]* has=[a-z]*' <<<"$cout" | tr '\n' ' ')): NOT VERIFIED offscreen; part 2 and the logged search paths cover them"
  fi
  # (Quickshell's provider answers a missing icon with a placeholder image, so the open log below, not the status, is
  # what shows that none of their files was read.)
  grep -q "probe: loaded " <<<"$out" && pass "policy: their image://icon URLs were loaded and the loads finished" || bad "policy: loads did not finish"
  grep -q "probe: child environment same=true" <<<"$out" && pass "policy: a child process gets the shell's environment unchanged" || bad "policy: child environment: $(grep -o 'probe: child.*' <<<"$out")"
  paths=$(grep -o 'grassfield-icons: theme search paths .*' <<<"$out" | head -n 1 || true)
  python3 -I - "$s" "$paths" <<'PY' && pass "policy: Qt's icon search paths are only packaged directories the user cannot change ($(sed "s|$s|\$S|g" <<<"$paths"))" || bad "policy: search paths: $paths"
import os, sys
scratch, line = sys.argv[1], sys.argv[2]
if not line.startswith("grassfield-icons: theme search paths "):
    sys.exit(1)
rest = line[len("grassfield-icons: theme search paths "):]
theme, _, fallback = rest.partition(" fallback ")
dirs = [d for d in theme.split(";") + fallback.split(";") if d and not d.startswith(":")]
def mapped_root():
    if open("/proc/self/uid_map").read().split()[:2] == ["0", "0"]:
        return -1
    return int(open("/proc/sys/kernel/overflowuid").read())
ROOT = mapped_root()
ok = bool(dirs)
for d in dirs:
    p = os.path.realpath(d)
    if p != d or p.startswith(scratch) or p.startswith(os.path.expanduser("~")) or p not in ("/usr/share/icons", "/usr/share/pixmaps"):
        ok = False
    while ok:
        st = os.stat(p)
        if st.st_uid not in (0, ROOT) or st.st_uid == os.geteuid() or os.access(p, os.W_OK):
            ok = False
        if p == "/":
            break
        p = os.path.dirname(p)
sys.exit(0 if ok else 1)
PY
  if [[ -s $tmp/policy-opens.log ]]; then
    user_opens=$(user_icon_opens "$tmp/policy-opens.log")
    [[ -z $user_opens ]] && pass "policy: the shell opened no file in the user's icon folders" || bad "policy: opens in user icon folders: $(head -n 3 <<<"$user_opens" | sed "s|$s|\$S|g")"
  else
    bad "policy: the open log is empty (the shim did not load)"
  fi
  # Review of dce68c2 (minor 2): root-owned is not enough (flatpak and snap system exports are written by app installs).
  # A root-owned icon directory outside /usr/share (found on this machine) named by XDG_DATA_DIRS is not searched by Qt,
  # and the helper looks it up instead.
  extra=
  while read -r d; do
    parent=$(dirname "$d")
    if python3 -I - "$parent" <<'PY'; then extra=$parent; break; fi
import os, sys
def mapped_root():
    if open("/proc/self/uid_map").read().split()[:2] == ["0", "0"]:
        return -1
    return int(open("/proc/sys/kernel/overflowuid").read())
p = os.path.realpath(sys.argv[1])
if p.startswith("/usr/share/"):
    sys.exit(1)
while True:
    st = os.stat(p)
    if st.st_uid not in (0, mapped_root()) or st.st_uid == os.geteuid() or os.access(p, os.W_OK):
        sys.exit(1)
    if p == "/":
        sys.exit(0)
    p = os.path.dirname(p)
PY
  done < <(find /opt /usr/lib /usr/local /var/lib/flatpak /var/lib/snapd -maxdepth 5 -type d -name icons 2>/dev/null | head -n 40)
  if [[ -z $extra ]]; then
    echo "SKIP: theme icon files, policy: no root-owned icon directory outside /usr/share on this machine: NOT VERIFIED here"
  else
    xout=$(env "${e[@]}" XDG_DATA_DIRS="$s/data:$extra:/usr/local/share:/usr/share" timeout -k 3 30 qs -p "$tmp/pcfg" --no-color 2>&1 || true)
    xpaths=$(grep -o 'grassfield-icons: theme search paths .*' <<<"$xout" | head -n 1 || true)
    bases=$(env -i PATH=/usr/bin:/bin HOME="$s/home" XDG_DATA_HOME="$s/home/.local/share" XDG_DATA_DIRS="$s/data:$extra:/usr/local/share:/usr/share" \
      python3 -I - shell/services/image-copy.py <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("imagecopy", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print("\n".join(m.BASES))
PY
)
    [[ -n $xpaths && $xpaths != *"$extra/icons"* ]] && grep -qxF "$extra/icons" <<<"$bases" && ! grep -qxF "/usr/share/icons" <<<"$bases" \
      && pass "policy: a root-owned icon directory outside /usr/share ($extra/icons) is left to the helper, not searched by Qt" \
      || bad "policy: $extra/icons: Qt paths [$xpaths], helper bases [$(tr '\n' ' ' <<<"$bases")]"
  fi
  # The copy helper itself: under the same log, every open of a user icon file carries O_NOFOLLOW|O_NONBLOCK (or is a
  # directory listing).
  s=$tmp/p4-helper
  scratch "$s"
  mkfifo "$s/home/.local/share/icons/hicolor/48x48/apps/evil.png"
  probe "$s" helper-log LD_PRELOAD="$tmp/openlog.so" OPENLOG="$tmp/helper-opens.log"
  python3 -I - "$s" "$tmp/helper-opens.log" <<'PY' && pass "policy: the copy helper opens user icon files only with O_NOFOLLOW|O_NONBLOCK" || bad "policy: unsafe opens of user icon files"
import os, re, sys
scratch = sys.argv[1]
O_NONBLOCK, O_NOFOLLOW, O_DIRECTORY = os.O_NONBLOCK, os.O_NOFOLLOW, os.O_DIRECTORY
seen = bad = 0
for line in open(sys.argv[2], errors="replace"):
    m = re.match(r"OPEN (\d+) (-?\d+) (.*)$", line.rstrip("\n"))
    icon_dirs = [scratch + d for d in ("/home/.local/share/icons", "/home/.icons", "/home/.local/share/pixmaps", "/data/icons", "/data/pixmaps")]
    if not m or not any(m.group(3) == d or m.group(3).startswith(d + "/") for d in icon_dirs):
        continue
    flags = int(m.group(2))
    if flags >= 0 and flags & O_DIRECTORY:
        continue
    seen += 1
    if flags < 0 or not (flags & O_NONBLOCK and flags & O_NOFOLLOW):
        bad += 1
        print("unsafe:", line.strip().replace(scratch, "$S"))
sys.exit(0 if seen > 0 and bad == 0 else 1)
PY

  # Cost: a user theme of 300 folders x 330 files; 24 names not found anywhere (the worst case: every candidate tried).
  s=$tmp/cost; U=$s/home/.local/share/icons/bigtheme
  mkdir -p -m 700 "$s/out"
  for i in $(seq 1 300); do mkdir -p "$U/d$i/apps"; (cd "$U/d$i/apps" && touch $(seq -f "icon%g.png" 1 330)); done
  args=()
  for i in $(seq 1 24); do args+=(name "$i" "missing$i"); done
  start=$(date +%s%N)
  n=$(env -i PATH="$PATH" HOME="$s/home" XDG_DATA_HOME="$s/home/.local/share" python3 -I shell/services/image-copy.py batch "$s/out" 8388608 16777216 134217728 "${args[@]}" | grep -c '^no' || true)
  ms=$((($(date +%s%N) - start) / 1000000))
  if [[ $n == 24 ]] && ((ms < 10000)); then pass "cost: 24 names looked up next to a user theme of 99k files in ${ms} ms"; else bad "cost: $n/24 answered in ${ms} ms"; fi
  # Past its soft time budget (forced to 0 here) the helper still makes the first item, then answers "later" for the rest
  # (ThemeIcons asks for them again first), so a batch of big photos ends before the run's timeout kills it.
  printf '%s' "$png" | base64 -d >"$s/t.png"
  later=$(env -i PATH="$PATH" HOME="$s/home" XDG_RUNTIME_DIR="$s" python3 -I - shell/services/image-copy.py "$s" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("imagecopy", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.SOFT_SECONDS = 0
out = os.path.join(sys.argv[2], "later-out")
os.mkdir(out, 0o700)
png = os.path.join(sys.argv[2], "t.png")
mod.batch([out, "8388608", "16777216", "134217728", "picture", "1", png, "picture", "2", png + "x", "picture", "3", png + "y"])
print("files=" + ",".join(sorted(os.listdir(out))))
PY
)
  [[ $(grep -c '^ok' <<<"$later") == 1 && $(grep -c '^later' <<<"$later") == 2 && $later == *"files=1.png"* ]] && pass "helper: past its soft time budget it makes the first item and answers later for the rest" \
    || bad "helper: soft time budget: $(tr '\n' '|' <<<"$later" | sed "s|$s|\$S|g")"
fi

# ---- Part 5: tray icons ----
tray_expect() { # <probe output> <label> <class>: the item's icon class, and status Ready for a copy
  local l
  l=$(grep -o "probe: $2 class=.*" <<<"$1" | head -n 1 || true)
  case $3 in
    copy) [[ $l == "probe: $2 class=copy status=1" ]] ;;
    *) [[ $l == "probe: $2 class=$3 "* ]] ;;
  esac
}
tray_scratch() { # <dir>: the review's hostile tray folders
  local s=$1
  scratch "$s"
  mkdir -p "$s/outside/hicolor/48x48/apps" "$s/tp/hicolor/22x22/status"
  mkfifo "$s/outside/sni.png" "$s/outside/hicolor/48x48/apps/sni.png" "$s/outside/hicolor/index.theme" "$s/outside/evil.png"
  printf '%s' "$png" | base64 -d >"$s/outside/good.png"
  printf '%s' "$png" | base64 -d >"$s/tp/hicolor/22x22/status/sniok.png"
  printf '%s' "$png" | base64 -d >"$s/home/.local/share/icons/hicolor/48x48/apps/trayctl.png"
  hostile_svg "$s/outside/snisvg.svg" "$s/outside/svg-ref.fifo" gzip
}
mkcfg "$tmp/tcfg" tray_probe.qml
s=$tmp/tray
tray_scratch "$s"
items="themepath-fifo=image://icon/sni?path=$s/outside
themepath-svgref=image://icon/snisvg?path=$s/outside
themepath-reg=image://icon/sniok?path=$s/tp
themepath-dotdot=image://icon/sni?path=$s/tp/../outside
iconname-abs-fifo=image://icon/$s/outside/evil.png
iconname-traversal=image://icon/../../../../../../..$s/outside/evil
iconname-abs-reg=image://icon/$s/outside/good.png
pixmap=image://qspixmap/0/0
plain-user=image://icon/trayctl"
mapfile -t fifos < <(find "$s/outside" -type p)
watch_fifos "$s" "${fifos[@]}"
mapfile -t e < <(shellenv "$s")
rc=0
out=$(env "${e[@]}" PROBE_ITEMS="$items" timeout -k 3 60 qs -p "$tmp/tcfg" --no-color 2>&1) || rc=$?
tcheck() { # <label> <ok>
  if [[ $2 == 1 ]]; then pass "tray: $1"; else bad "tray: $1 (rc $rc; $(grep -o 'probe: .*' <<<"$out" | sed "s|$s|\$S|g" | tr '\n' '|' | cut -c1-700))"; fi
}
for c in themepath-fifo:generic themepath-dotdot:generic iconname-abs-fifo:generic iconname-traversal:generic iconname-abs-reg:generic; do
  tcheck "${c%%:*}: the generic icon shows, nothing of the app's (that no FIFO is opened is checked below)" "$(tray_expect "$out" "${c%%:*}" "${c#*:}" && echo 1)"
done
tcheck "themepath-svgref: a gzip SVG naming FIFOs in the app's folder becomes a PNG the shell made" "$(tray_expect "$out" themepath-svgref copy && echo 1)"
tcheck "themepath-reg: a regular icon in the app's own theme folder is shown as a PNG the shell made" "$(tray_expect "$out" themepath-reg copy && echo 1)"
tcheck "pixmap: the IconPixmap pixels pass as they are" "$(tray_expect "$out" pixmap pixmap && echo 1)"
tcheck "plain-user: a user-installed icon name is shown as a copy" "$(tray_expect "$out" plain-user copy && echo 1)"
tcheck "the image loader and the GUI thread never stalled" "$([[ $rc == 0 && $(grep -o 'probe: done .*' <<<"$out") == "probe: done ctl=1" ]] && echo 1)"
note=$(fifos_untouched "$s") && copies_are_pngs "$s" >/dev/null && tcheck "no FIFO was opened; every copy is a PNG the shell made" 1 || tcheck "no FIFO was opened; every copy is a PNG the shell made: $note" 0

# The same items as real StatusNotifierItems, on a PRIVATE bus only (testing rule after the review of 423766f: a probe
# once reached the owner's session bus). dbus-daemon listens in the scratch directory; its address must name that
# directory, and every process (the fake items, the shell) runs under `env -i` with that address alone.
s=$tmp/traybus
tray_scratch "$s"
mkdir -m 700 "$tmp/bus"
# The session bus's own default policy (/usr/share/dbus-1/session.conf): send to anyone, receive anything (method returns,
# errors and signals included), own any name. With no receive rule (as here before), dbus-daemon drops every reply, the
# Hello reply too: no client could even connect, and this part could never pass where it ran (follow-up of 061f599).
cat >"$tmp/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>session</type><listen>unix:dir=$tmp/bus</listen><auth>EXTERNAL</auth>
<policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy></busconfig>
EOF
addr=$(env -i PATH=/usr/bin:/bin dbus-daemon --config-file="$tmp/bus.conf" --fork --print-address=1 --print-pid=3 3>"$tmp/bus.pid" 2>/dev/null || true)
if [[ -z $addr ]]; then
  rm -f "$tmp/bus.pid"
  echo "SKIP: theme icon files, tray on a private bus: dbus-daemon cannot listen here (no Unix sockets in this environment): NOT VERIFIED"
elif ! { [[ $addr =~ ^unix:path=([^,\;]+)(,guid=[0-9a-f]+)?$ ]] && sock=${BASH_REMATCH[1]} && [[ $sock == "$tmp/bus/"* ]] \
  && [[ ${sock#"$tmp/bus/"} =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ && ${sock#"$tmp/bus/"} != *..* ]]; } \
  || [[ $addr == *"/run/user/"* || ( -n ${DBUS_SESSION_BUS_ADDRESS:-} && $addr == "$DBUS_SESSION_BUS_ADDRESS"* ) ]]; then
  bad "tray on a private bus: refusing a bus address outside the test's directory ($addr)"
elif ! env -i PATH=/usr/bin:/bin python3 -I -c 'import gi; gi.require_version("Gio", "2.0"); from gi.repository import Gio' 2>/dev/null; then
  echo "SKIP: theme icon files, tray on a private bus: python3 gi (PyGObject) missing: NOT VERIFIED"
elif ! check=$(env -i PATH=/usr/bin:/bin GF_PRIVATE_BUS_DIR="$tmp/bus" DBUS_SESSION_BUS_ADDRESS="$addr" \
  timeout -k 2 20 python3 -I tests/security/theme_icon_files.d/bus_check.py 2>&1); then
  bad "tray on a private bus: the bus does not carry a method reply and a signal, so no tray item could work on it ($(grep -o 'bus-check: .*' <<<"$check" || echo "${check:0:200}"))"
else
  pass "tray: private bus: the bus carries a method reply and a signal ($(grep -o 'bus-check: .*' <<<"$check"))"
  mkcfg "$tmp/tbcfg" tray_bus_probe.qml
  n=0
  for c in "themepath-fifo|sni|$s/outside" "themepath-svgref|snisvg|$s/outside" "themepath-reg|sniok|$s/tp" "iconname-abs-fifo|$s/outside/evil.png|" \
    "iconname-traversal|../../../../../../..$s/outside/evil|" "iconname-abs-reg|$s/outside/good.png|"; do
    n=$((n + 1))
    IFS='|' read -r title name tpath <<<"$c"
    env -i PATH=/usr/bin:/bin GF_PRIVATE_BUS_DIR="$tmp/bus" DBUS_SESSION_BUS_ADDRESS="$addr" \
      python3 -I tests/security/theme_icon_files.d/fake_sni.py "$n" "$title" "$name" "$tpath" >>"$tmp/fake-sni.log" 2>&1 &
    watchers+=($!)
  done
  mapfile -t fifos < <(find "$s/outside" -type p)
  watch_fifos "$s" "${fifos[@]}"
  rc=0
  out=$(env -i PATH=/usr/bin:/bin HOME="$s/home" XDG_DATA_HOME="$s/home/.local/share" XDG_DATA_DIRS="$s/data:/usr/local/share:/usr/share" \
    XDG_CONFIG_HOME="$s/home/.config" XDG_STATE_HOME="$s/home/.local/state" XDG_RUNTIME_DIR="$s/runtime" XDG_CACHE_HOME="$s/cache" \
    GRASSFIELD_DEV=1 GRASSFIELD_PRIVATE_BUS=1 GRASSFIELD_STATE_HOME="$s/state" GRASSFIELD_CONFIG_HOME="$s/config" GRASSFIELD_TEST_TMP="$s" \
    DBUS_SESSION_BUS_ADDRESS="$addr" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
    GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" PROBE_COUNT=6 timeout -k 3 60 qs -p "$tmp/tbcfg" --no-color 2>&1) || rc=$?
  tcheck "private bus: six hostile items listed by the real TrayHost" "$(grep -q 'probe: items=6' <<<"$out" && echo 1)"
  for c in themepath-fifo:generic iconname-abs-fifo:generic iconname-traversal:generic iconname-abs-reg:generic themepath-svgref:copy themepath-reg:copy; do
    tcheck "private bus: ${c%%:*} (${c#*:})" "$(tray_expect "$out" "${c%%:*}" "${c#*:}" && echo 1)"
  done
  tcheck "private bus: the image loader and the GUI thread never stalled" "$([[ $rc == 0 && $(grep -o 'probe: done .*' <<<"$out") == "probe: done ctl=1" ]] && echo 1)"
  note=$(fifos_untouched "$s") && tcheck "private bus: no FIFO was opened" 1 || tcheck "private bus: no FIFO was opened: $note" 0
fi

# ---- Part 6: media art over https (offline: a local HTTPS server on 127.0.0.1, a throwaway CA; no network) ----
if ! command -v openssl >/dev/null || ! command -v curl >/dev/null; then
  echo "SKIP: theme icon files, part 6 media art over https: openssl or curl missing: NOT VERIFIED"
else
  h=$tmp/https
  mkdir -p "$h"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$h/key.pem" -out "$h/cert.pem" -days 1 -subj "/CN=art.test" \
    -addext "subjectAltName=DNS:art.test,DNS:loop.test,DNS:private.test,DNS:mapped.test,DNS:localhost,DNS:art.localhost,IP:127.0.0.1" >/dev/null 2>&1
  s=$tmp/art
  scratch "$s"
  mkfifo "$s/outside/art-ref.fifo"
  watch_fifos "$s" "$s/outside/art-ref.fifo"
  env -i PATH=/usr/bin:/bin python3 -I tests/security/theme_icon_files.d/fake_https.py "$h/cert.pem" "$h/key.pem" "$h/requests.log" \
    "$s/outside/art-ref.fifo" >"$h/port" 2>"$h/server.err" &
  watchers+=($!)
  for _ in $(seq 1 50); do [[ -s $h/port ]] && break; sleep 0.1; done
  port=$(head -n 1 "$h/port" 2>/dev/null || true)
  if [[ ! $port =~ ^[0-9]+$ ]]; then
    echo "SKIP: theme icon files, part 6 media art over https: no local HTTPS server here ($(head -c 200 "$h/server.err")): NOT VERIFIED"
  else
    B=https://art.test:$port
    # The helper as ThemeIcons runs it, through the test stand-in (image-copy-testnet.py: only name resolution changes,
    # art.test -> 127.0.0.1); no variable but the throwaway CA's bundle (no proxy: offline).
    helper_url() { # <url>...: one batch of "url" items; prints its answer lines
      local -a a=()
      local n=0 u
      for u in "$@"; do n=$((n + 1)); a+=(url "$n" "$u"); done
      rm -rf "$s/fetch-out" && mkdir -m 700 "$s/fetch-out"
      env -i PATH=/usr/bin:/bin HOME="$s/home" XDG_RUNTIME_DIR="$s/runtime" CURL_CA_BUNDLE="$h/cert.pem" GF_REAL_HELPER="$root/shell/services/image-copy.py" \
        timeout -k 2 120 python3 -I tests/security/theme_icon_files.d/image-copy-testnet.py batch "$s/fetch-out" 8388608 16777216 134217728 "${a[@]}"
    }
    answer() { grep -F -- "	$2" <<<"$1" | grep -E "^(ok|no)	url:" | head -n 1 | cut -f1; }
    requested() { python3 -I -c 'import json, sys; print(sum(1 for l in open(sys.argv[1]) if json.loads(l)["path"] == sys.argv[2]))' "$h/requests.log" "$1"; }
    acheck() { # <label> <ok>
      if [[ $2 == 1 ]]; then pass "https art: $1"; else bad "https art: $1 ($(grep -E 'probe: |^(ok|no|later)	|grassfield-icons' <<<"$out" | tr '\n' '|' | sed "s|$B|\$B|g" | cut -c1-900); requests: $(python3 -I -c 'import json, sys; print(" ".join(json.loads(l)["path"] for l in open(sys.argv[1])))' "$h/requests.log" | tail -c 300)$([[ -s $s/art-trace.log ]] && echo "; helper trace: $(tail -n 6 "$s/art-trace.log" | sed "s|$B|\$B|g" | tr '\n' '|')"))"; fi
    }
    # Precondition for the pinning check: the system resolver does not know art.test.
    pinned=0
    python3 -I -c 'import socket; socket.getaddrinfo("art.test", 443)' 2>/dev/null || pinned=1
    out=$(helper_url "$B/ok.png" "$B/svgref.svg" "$B/html" "$B/redir-http" "$B/redir-file" "$B/redir/3" "$B/redir/4" "$B/cookie" \
      "$B/big-length" "$B/big-chunked" "http://art.test:$port/ok.png" "https://user:pw@art.test:$port/a.png")
    acheck "a PNG is fetched and re-encoded, from the address the helper checked (art.test is unknown to the system resolver: curl --resolve)" \
      "$([[ $pinned == 1 && $(answer "$out" "url:$B/ok.png	") == ok ]] && echo 1)"
    acheck "an SVG naming a FIFO is fetched and rendered (the FIFO is never opened)" "$([[ $(answer "$out" "url:$B/svgref.svg") == ok ]] && fifos_untouched "$s" >/dev/null && echo 1)"
    acheck "text/html is refused (not an image)" "$([[ $(answer "$out" "url:$B/html") == no ]] && echo 1)"
    acheck "a redirect to http is refused (its plain-HTTP target, which would answer, is never asked)" \
      "$([[ $(answer "$out" "url:$B/redir-http") == no ]] && ! grep -q '"scheme": "http"' "$h/requests.log" && echo 1)"
    acheck "a redirect to file: is refused" "$([[ $(answer "$out" "url:$B/redir-file") == no ]] && echo 1)"
    acheck "three redirects are followed, a fourth is refused" "$([[ $(answer "$out" "url:$B/redir/3") == ok && $(answer "$out" "url:$B/redir/4") == no ]] && echo 1)"
    acheck "a response over 5 MiB is refused, announced or chunked" "$([[ $(answer "$out" "url:$B/big-length") == no && $(answer "$out" "url:$B/big-chunked") == no ]] && echo 1)"
    acheck "an http URL and a URL with credentials are refused before any request" \
      "$([[ $(answer "$out" "url:http://art.test:$port/ok.png") == no && $(answer "$out" "url:https://user:pw@") == no && $(requested /a.png) == 0 ]] && echo 1)"
    acheck "every copy is a PNG the shell made" "$(python3 -I - "$s/fetch-out" <<'PY' && echo 1
import os, sys
d = sys.argv[1]
ok = all(open(os.path.join(d, f), "rb").read(8) == b"\x89PNG\r\n\x1a\n" for f in os.listdir(d))
sys.exit(0 if ok and os.listdir(d) else 1)
PY
)"
    # Review of dce68c2, minor 1: no IP literal in any notation, no localhost name, no name that resolves to a private,
    # loopback or mapped-loopback address, and no redirect to one; none of them reaches the server.
    before=$(wc -l <"$h/requests.log")
    out=$(helper_url "https://127.0.0.1:$port/ok.png" "https://2130706433:$port/ok.png" "https://0x7f000001:$port/ok.png" "https://0177.0.0.1:$port/ok.png" \
      "https://127.1:$port/ok.png" "https://localhost:$port/ok.png" "https://art.localhost:$port/ok.png" "https://LOCALHOST.:$port/ok.png" \
      "https://loop.test:$port/ok.png" "https://private.test:$port/ok.png" "https://mapped.test:$port/ok.png" "https://unknown.test:$port/ok.png")
    refused=1
    for u in "https://127.0.0.1:$port/ok.png" "https://2130706433:$port/ok.png" "https://0x7f000001:$port/ok.png" "https://0177.0.0.1:$port/ok.png" \
      "https://127.1:$port/ok.png" "https://localhost:$port/ok.png" "https://art.localhost:$port/ok.png" "https://LOCALHOST.:$port/ok.png" \
      "https://loop.test:$port/ok.png" "https://private.test:$port/ok.png" "https://mapped.test:$port/ok.png" "https://unknown.test:$port/ok.png"; do
      [[ $(answer "$out" "url:$u") == no ]] || { refused=0; echo "not refused: $u"; }
    done
    acheck "IP literals (dotted, decimal, hex, octal, short), localhost names, and names resolving to loopback, private or mapped-loopback addresses are refused before any request" \
      "$([[ $refused == 1 && $(wc -l <"$h/requests.log") == "$before" ]] && echo 1)"
    out=$(helper_url "$B/redir-loop" "$B/redir-numeric")
    acheck "a redirect to a loopback name or to an IP literal is refused (only the first hop reached the server)" \
      "$([[ $(answer "$out" "url:$B/redir-loop") == no && $(answer "$out" "url:$B/redir-numeric") == no ]] && ! grep -q '"host": "loop.test\|"host": "127.0.0.1' "$h/requests.log" && echo 1)"
    # Review of 684ed6d (major): curl must connect where the helper pinned, whatever form the name takes. The machine's
    # own host name resolves to a loopback address through the system (nss-myhostname); a second server listens there.
    # The stand-in pins that name to 127.0.0.3, where nothing listens. A request reaching the second server means curl
    # resolved a name itself: a trailing dot, several dots, an uppercase name, a redirect Location with a trailing dot.
    hn=$(python3 -I -c 'import socket; print(socket.gethostname().lower())')
    la=$(python3 -I - "$hn" <<'PY'
import ipaddress, socket, sys
try:
    addrs = sorted({i[4][0] for i in socket.getaddrinfo(sys.argv[1], 443, type=socket.SOCK_STREAM)})
except OSError:
    addrs = []
v4 = [a for a in addrs if ":" not in a and ipaddress.ip_address(a).is_loopback and a != "127.0.0.3"]
print(v4[0] if v4 and all(ipaddress.ip_address(a).is_loopback for a in addrs) else "")
PY
)
    if [[ -z $la || ! $hn =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
      echo "SKIP: theme icon files, https art: the pin leak cases need a host name the system resolves to loopback only (${hn:-none}: ${la:-not loopback}): NOT VERIFIED"
    else
      openssl req -x509 -newkey rsa:2048 -nodes -keyout "$h/leak-key.pem" -out "$h/leak-cert.pem" -days 1 -subj "/CN=$hn" \
        -addext "subjectAltName=DNS:$hn" >/dev/null 2>&1
      cat "$h/cert.pem" "$h/leak-cert.pem" >"$h/both.pem"
      env -i PATH=/usr/bin:/bin python3 -I tests/security/theme_icon_files.d/fake_https.py "$h/leak-cert.pem" "$h/leak-key.pem" "$h/leak.log" \
        "$s/outside/art-ref.fifo" "$la" >"$h/leak-port" 2>"$h/leak.err" &
      watchers+=($!)
      for _ in $(seq 1 50); do [[ -s $h/leak-port ]] && break; sleep 0.1; done
      lp=$(head -n 1 "$h/leak-port" 2>/dev/null || true)
      # A second main server whose /redir-dot sends the trailing-dot name of the leak server.
      env -i PATH=/usr/bin:/bin python3 -I tests/security/theme_icon_files.d/fake_https.py "$h/cert.pem" "$h/key.pem" "$h/requests2.log" \
        "$s/outside/art-ref.fifo" 127.0.0.1 "$hn:$lp" >"$h/port2" 2>/dev/null &
      watchers+=($!)
      for _ in $(seq 1 50); do [[ -s $h/port2 ]] && break; sleep 0.1; done
      p2=$(head -n 1 "$h/port2" 2>/dev/null || true)
      leaks() { [[ -f $h/leak.log ]] && wc -l <"$h/leak.log" || echo 0; }
      # Positive control: by name, without the helper, curl does reach the second server (so the cases below are real).
      env -i PATH=/usr/bin:/bin curl -q -s --noproxy '*' --cacert "$h/leak-cert.pem" --max-time 5 -o /dev/null "https://$hn:$lp/ok.png" || true
      acheck "control: the machine's host name reaches the loopback server through the system resolver ($hn -> $la)" "$([[ $(leaks) == 1 ]] && echo 1)"
      HN=$(tr '[:lower:]' '[:upper:]' <<<"$hn")
      out=$(env -i PATH=/usr/bin:/bin HOME="$s/home" XDG_RUNTIME_DIR="$s/runtime" CURL_CA_BUNDLE="$h/both.pem" GF_REAL_HELPER="$root/shell/services/image-copy.py" \
        GF_TEST_PIN="$hn=127.0.0.3" timeout -k 2 120 python3 -I tests/security/theme_icon_files.d/image-copy-testnet.py batch "$s/fetch-out" 8388608 16777216 134217728 \
        url 1 "https://$hn.:$lp/ok.png" url 2 "https://$hn..:$lp/ok.png" url 3 "https://$HN:$lp/ok.png" url 4 "https://$hn:$lp/ok.png" \
        url 5 "https://art.test:$p2/redir-dot")
      lout=$out
      acheck "a trailing dot, several dots, an uppercase name, the plain name and a redirect Location with a trailing dot never reach the loopback server (curl connects where the helper pinned)" \
        "$([[ $(grep -c '^no	' <<<"$lout") == 5 && $(leaks) == 1 ]] && echo 1)"
      acheck "the redirect case reached its first hop (so its refusal was the trailing-dot hop)" "$(grep -q '"path": "/redir-dot"' "$h/requests2.log" && echo 1)"
    fi
    out=$(env -i PATH=/usr/bin:/bin HOME="$s/home" XDG_RUNTIME_DIR="$s/runtime" python3 -I - "$root/shell/services/image-copy.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("imagecopy", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
cases = {"8.8.8.8": True, "2606:4700:4700::1111": True, "127.0.0.1": False, "10.1.2.3": False, "172.16.0.1": False,
         "192.168.1.1": False, "169.254.169.254": False, "100.64.0.1": False, "0.0.0.0": False, "224.0.0.1": False,
         "255.255.255.255": False, "192.0.2.1": False, "::1": False, "fe80::1": False, "fc00::1": False, "::": False,
         "::ffff:127.0.0.1": False, "::ffff:10.0.0.1": False, "2002:7f00:1::1": False, "2002:a00:1::1": False,
         "2001:0:4136:e378:8000:63bf:80ff:fffe": False, "ff02::1": False, "not an address": False,
         # Review of 684ed6d (minor 2): IPv4-compatible, NAT64 (well-known with a private or public IPv4, local-use),
         # IPv4-translated and site-local forms.
         "::7f00:1": False, "::808:808": False, "64:ff9b::a00:1": False, "64:ff9b::7f00:1": False, "64:ff9b::808:808": True,
         "64:ff9b:1::808:808": False, "::ffff:0:a00:1": False, "fec0::1": False, "::ffff:8.8.8.8": True}
bad = [ip for ip, want in cases.items() if m.public_address(ip) != want]
urls = {"https://cdn.example.com/a.png": ("cdn.example.com", 443, "/a.png"), "https://art.test:8443/x": ("art.test", 8443, "/x"),
        "https://1.example.com/a.png": ("1.example.com", 443, "/a.png"), "https://art.test": ("art.test", 443, "/"),
        "https://ART.Test:00443/a": ("art.test", 443, "/a"), "https://xn--kmerxe-wxa.example/a": ("xn--kmerxe-wxa.example", 443, "/a"),
        "https://127.0.0.1/a": None, "https://2130706433/a": None,
        "https://0x7f000001/a": None, "https://0x7f.0.0.1/a": None, "https://0177.0.0.1/a": None, "https://127.1/a": None,
        "https://10.0.0.1./a": None, "https://localhost/a": None, "https://LOCALHOST./a": None, "https://a.localhost/a": None,
        "https://[::1]/a": None, "https://u:p@cdn.example.com/a": None, "http://cdn.example.com/a": None, "https://x:0/a": None,
        # Review of 684ed6d (major): no empty label (trailing, several, leading or doubled dots), LDH labels only.
        "https://cdn.example.com./a": None, "https://cdn.example.com../a": None, "https://.cdn.example.com/a": None,
        "https://cdn..example.com/a": None, "https://-cdn.example.com/a": None, "https://cdn-.example.com/a": None,
        "https://-/a": None, "https://k\u00f6merxe.example/a": None}
bad += [u for u, want in urls.items() if m.url_target(u) != want]
# The URL curl is given is rebuilt from the checked parts: the checked (lowercased) host, the port only when not 443.
rebuilt = {"https://ART.Test:00443/a": "https://art.test/a", "https://art.test:8443/x?y=1": "https://art.test:8443/x?y=1",
           "https://art.test": "https://art.test/"}
bad += [u for u, want in rebuilt.items() if m.rebuilt_url(*m.url_target(u)) != want]
# fetch(): every curl call names exactly the host it pins (also on a redirect hop), and a hop to a name with a trailing
# dot is refused before any call (curl_once and resolve_host stubbed: no network).
calls = []
script = {}
m.resolve_host = lambda host, port: {"pub.test": ["8.8.8.8"], "hop.test": ["8.8.4.4"]}.get(host, [])
def fake_curl(url, host, port, addresses, seconds):
    calls.append((url, host, port, tuple(addresses)))
    return script.get(url, (200, b"data", ""))
m.curl_once = fake_curl
def run(url, redirects):
    calls.clear()
    script.clear()
    script.update(redirects)
    return m.fetch(url), list(calls)
cases2 = [
    ("trailing dot", run("https://pub.test./a.png", {}), None, []),
    ("uppercase", run("https://PUB.TEST/a.png", {}), b"data", [("https://pub.test/a.png", "pub.test", 443, ("8.8.8.8",))]),
    ("hop with a trailing dot", run("https://pub.test/a.png", {"https://pub.test/a.png": (302, b"", "https://hop.test./b.png")}), None,
     [("https://pub.test/a.png", "pub.test", 443, ("8.8.8.8",))]),
    ("hop uppercase", run("https://pub.test/a.png", {"https://pub.test/a.png": (302, b"", "https://HOP.test:8443/b.png")}), b"data",
     [("https://pub.test/a.png", "pub.test", 443, ("8.8.8.8",)), ("https://hop.test:8443/b.png", "hop.test", 8443, ("8.8.4.4",))]),
]
for label, (got, made), want, want_calls in cases2:
    if got != want or made != want_calls:
        bad.append("fetch:" + label)
print("bad=" + ",".join(bad))
PY
)
    acheck "the URL rule (IP literals in every notation, localhost names, empty labels: trailing, several, leading or doubled dots refused; LDH labels; the URL curl gets rebuilt from the checked parts) and the address rule (public addresses only: private, loopback, link-local, site-local, shared, reserved, multicast, and IPv4-mapped, IPv4-compatible, IPv4-translated, NAT64, 6to4 and Teredo forms carrying such an address refused)" \
      "$([[ $out == "bad=" ]] && echo 1)"
    rows_ok=$(python3 -I - "$h/requests.log" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
print(1 if rows and all(r["cookie"] is None and r["auth"] is None and r["agent"] == "Grassfield-NowPlaying/1.0" for r in rows) else 0)
PY
)
    acheck "requests carry no cookie, no credentials and only the fixed user agent" "$rows_ok"
    start=$(date +%s%N)
    out=$(helper_url "$B/slow")
    ms=$((($(date +%s%N) - start) / 1000000))
    acheck "a response that does not come within 5 s is refused (${ms} ms)" "$([[ $(answer "$out" "url:$B/slow") == no ]] && ((ms < 8000)) && echo 1)"
    # No curl outlives the helper (review of 684ed6d): killed mid-fetch with SIGTERM (its handler kills curl's process
    # group first) or SIGKILL (curl has PR_SET_PDEATHSIG).
    # This test's curl processes only, by its server's unique address (a scan of /proc forked twice per process and, on a
    # busy machine, missed a curl that lives about 5 s; it also counted any other curl -q of the machine).
    curls() { pgrep -c -f -- "^curl -q .*://art\.test:$port/" || true; }
    for sig in TERM KILL; do
      rm -rf "$s/fetch-out" && mkdir -m 700 "$s/fetch-out"
      env -i PATH=/usr/bin:/bin HOME="$s/home" XDG_RUNTIME_DIR="$s/runtime" CURL_CA_BUNDLE="$h/cert.pem" GF_REAL_HELPER="$root/shell/services/image-copy.py" \
        python3 -I tests/security/theme_icon_files.d/image-copy-testnet.py batch "$s/fetch-out" 8388608 16777216 134217728 url 1 "$B/slow" >/dev/null 2>&1 &
      hp=$!
      for _ in $(seq 1 50); do (($(curls) >= 1)) && break; sleep 0.1; done
      running=$(curls)
      kill -s "$sig" "$hp" 2>/dev/null || true
      wait "$hp" 2>/dev/null || true
      sleep 0.5
      acheck "the helper killed with SIG$sig mid-fetch leaves no curl behind (curl processes before: $running, after: $(curls))" "$( ((running >= 1)) && [[ $(curls) == 0 ]] && echo 1)"
    done

    # The shell: ThemeIcons.artSource as the Now Playing views use it, with the stand-in in place of the helper (no proxy
    # variable: offline).
    mkcfg "$tmp/acfg" art_probe.qml
    rm "$tmp/acfg/services"
    mkdir "$tmp/acfg/services"
    for entry in shell/services/*; do
      [[ $(basename "$entry") == image-copy.py ]] || ln -s "$root/$entry" "$tmp/acfg/services/$(basename "$entry")"
    done
    cp tests/security/theme_icon_files.d/image-copy-testnet.py "$tmp/acfg/services/image-copy.py"
    mapfile -t e < <(shellenv "$s")
    rc=0
    # The helper and curl from the system (PATH), trusting only the throwaway CA (no inherited SSL_CERT_FILE or
    # SSL_CERT_DIR reaches curl), as the helper_url runs above; GF_ART_TRACE says where a fetch stopped if one fails.
    out=$(env -u https_proxy -u HTTPS_PROXY -u http_proxy -u HTTP_PROXY -u all_proxy -u ALL_PROXY -u SSL_CERT_FILE -u SSL_CERT_DIR "${e[@]}" \
      PATH=/usr/bin:/bin CURL_CA_BUNDLE="$h/cert.pem" PROBE_BASE="$B" GF_ART_TRACE="$s/art-trace.log" \
      GF_REAL_HELPER="$root/shell/services/image-copy.py" timeout -k 3 120 qs -p "$tmp/acfg" --no-color 2>&1) || rc=$?
    acheck "the shell shows https art as a PNG it made" "$(grep -q 'probe: unlocked class=copy status=1' <<<"$out" && echo 1)"
    acheck "while locked no fetch starts (no request, no entry) and only art already made shows" \
      "$(grep -q 'probe: locked source=none entry=none cached=copy' <<<"$out" && echo 1)"
    acheck "after unlocking the held art is fetched once" "$(grep -q 'probe: after-unlock class=copy status=1' <<<"$out" && [[ $(requested /locked.png) == 1 ]] && echo 1)"
    acheck "three URLs asked in one turn: only the newest is fetched" \
      "$(grep -q 'probe: newest a=none b=none c=ok' <<<"$out" && [[ $(requested /a.png) == 0 && $(requested /b.png) == 0 ]] && echo 1)"
    acheck "a fetch running when the session locks is stopped at once and its URL waits (review of dce68c2, minor 3)" \
      "$(grep -q 'probe: lock-stop running=false entry=pending queued=true' <<<"$out" && grep -q 'probe: lock-stop while-locked entry=pending source=none' <<<"$out" && echo 1)"
    acheck "after unlocking, the stopped URL is fetched again (two requests in all)" \
      "$(grep -q 'probe: lock-stop after-unlock class=copy status=1' <<<"$out" && [[ $(requested /slow3) == 2 ]] && echo 1)"
    acheck "no curl process outlives the stopped run (review of 684ed6d)" "$(grep -q 'probe: lock-stop curls-after-1s=0' <<<"$out" && echo 1)"
    acheck "a lock inside the change that starts a run: the run never starts (or is stopped once started), no request goes out, no curl is left" \
      "$(grep -q 'probe: same-turn run-created=true locked=true running-after-lock=false' <<<"$out" && grep -q 'probe: same-turn while-locked entry=pending curls-after-1s=0' <<<"$out" && echo 1)"
    acheck "after unlocking, that URL is fetched once" "$(grep -q 'probe: same-turn after-unlock entry=ok' <<<"$out" && [[ $(requested /slow3-same) == 1 ]] && echo 1)"
    acheck "a failed URL is retried with backoff while shown: one that works on its third try is shown (review of dce68c2, minor 4)" \
      "$(grep -q 'probe: retry flaky=ok class=copy' <<<"$out" && [[ $(requested /flaky) == 3 ]] && echo 1)"
    acheck "one that always fails is asked exactly three times, then never again" \
      "$(grep -q 'dead=no dead-retry-entry=false' <<<"$out" && [[ $(requested /dead) == 3 ]] && echo 1)"
    acheck "a failed URL no view shows any more is forgotten at its due retry, not fetched again (review of 684ed6d, minor 3)" \
      "$(grep -q 'gone=none gone-retry-entry=false' <<<"$out" && [[ $(requested /dead-gone) == 1 ]] && echo 1)"
    acheck "the retry map keeps at most maxRetries entries, the oldest leaves first" "$(grep -q 'probe: retry bound keys=url:x-two,url:x-three$' <<<"$out" && echo 1)"
    acheck "the shell never stalled" "$([[ $rc == 0 ]] && grep -q 'probe: done' <<<"$out" && echo 1)"
  fi
fi
exit $fail
