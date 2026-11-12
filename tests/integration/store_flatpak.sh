#!/usr/bin/env bash
# Grassfield Store, step 3c part 2: Flathub's path against the real flatpak (ADR-0037 a, b.3, SD25 to SD27; spec acceptance
# A8), in a throwaway Arch container. Never on a real machine: outside a container it starts one; inside, it refuses unless
# it is root in a container with the repository at /src.
#
#   tests/integration/store_flatpak.sh
#   Runs `docker run --rm --network host` on archlinux:base (digest pinned below) with the repository mounted read-only;
#   HTTPS_PROXY/HTTP_PROXY/NO_PROXY are passed through for pacman, and GRASSFIELD_TEST_CA, when set, is mounted as the
#   container's CA bundle. Exit 0 all PASS (or SKIP without docker), 1 a FAIL, 2 usage.
#
# Inside: flatpak, qt6-base, gtest and gcc from Arch (a whole upgrade, never -Sy alone). A local repository stands for
# Flathub, made with flatpak's own build-export and build-update-repo: a runtime org.example.Platform//1 with a 20 MB file,
# and an app org.example.Hello//stable that reaches the network, the home folder and the sound server, with its AppStream
# (release 1.2, MIT). It is served over http on 127.0.0.1 by a server that sends 64 KiB every 50 ms (so an install can be
# stopped half-way) and added to root's own installation as "flathub" without GPG (no collection id: flatpak 1.18.4's info
# and remote-info print every field, then abort on an assertion, which the Store tolerates, S28). Nothing reaches Flathub.
# Then the Store's unit tests with STORE_TEST_FLATPAK=1: Flatpak.RealFlatpak drives that installation through the Store's
# own code (AppStream, flatpak's plan on a pseudo-terminal, the facts, an install stopped, an install, a removal with
# --unused); a skipped test is a failure here. Then an update (Store step 4, S31): Hello 1.2 installed by flatpak itself, 1.3
# published, and Flatpak.RealUpdate with STORE_TEST_FLATPAK_UPDATE=1 (the Store's check, what the update adds, its command).
set -uo pipefail

IMAGE=archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0

if [[ ! -f /.dockerenv && ! -f /run/.containerenv ]]; then
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
  . "$root/tests/integration/container.sh" || exit 2
  if ! gf_have_docker; then
    echo "SKIP: store_flatpak (no docker)"
    exit 0
  fi
  gf_container_init "$root" || exit 2
  gf_standard auto /test-ca.crt || exit 2
  gf_container_run "$IMAGE" bash /src/tests/integration/store_flatpak.sh
  exit $?
fi

[[ $(id -u) == 0 && -d /src/apps/store ]] || { echo "refused: run as root in a container with the repository at /src"; exit 2; }
if [[ -f /test-ca.crt ]]; then
  cp /test-ca.crt /etc/ca-certificates/trust-source/anchors/test-ca.crt && update-ca-trust
fi
step() { printf '\n== %s\n' "$*"; }

step "tools (a whole upgrade, never -Sy alone)"
pacman -Syu --noconfirm --needed flatpak qt6-base gtest gcc pkgconf zlib git python >/tmp/pacman.log 2>&1 || { tail -5 /tmp/pacman.log; exit 1; }
pacman -Q flatpak qt6-base gtest | sed 's/^/  /'
cp -r /src /work && cd /work || exit 1
# From here on nothing leaves the container: the repository is on 127.0.0.1.
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy NO_PROXY no_proxy

step "a local repository standing for Flathub"
build=/tmp/flathub-build
mkdir -p "$build/runtime/usr/bin" "$build/runtime/files" "$build/app/files/bin" "$build/app/export/share/applications" \
  "$build/app/files/share/app-info/xmls"
cd "$build" || exit 1
printf '[Runtime]\nname=org.example.Platform\nruntime=org.example.Platform/x86_64/1\nsdk=org.example.Platform/x86_64/1\n' >runtime/metadata
printf '#!/bin/sh\n' >runtime/usr/bin/sh
head -c 20000000 /dev/urandom >runtime/usr/blob
flatpak build-export --runtime --arch=x86_64 repo runtime 1 >/dev/null
printf '[Application]\nname=org.example.Hello\nruntime=org.example.Platform/x86_64/1\ncommand=hello\n\n[Context]\nshared=network;\nfilesystems=home;\nsockets=pulseaudio;\n' >app/metadata
printf '#!/bin/sh\necho hello\n' >app/files/bin/hello
chmod +x app/files/bin/hello
printf '[Desktop Entry]\nName=Hello\nExec=hello\nType=Application\n' >app/export/share/applications/org.example.Hello.desktop
cat >app/files/share/app-info/xmls/org.example.Hello.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<components version="0.8" origin="flatpak">
  <component type="desktop-application">
    <id>org.example.Hello</id>
    <name>Hello</name>
    <summary>Says hello</summary>
    <project_license>MIT</project_license>
    <launchable type="desktop-id">org.example.Hello.desktop</launchable>
    <releases><release version="1.2" date="2026-10-01"/></releases>
  </component>
</components>
XML
gzip app/files/share/app-info/xmls/org.example.Hello.xml
flatpak build-export --arch=x86_64 repo app stable >/dev/null
flatpak build-update-repo repo >/dev/null
echo "  refs: $(find repo/refs/heads -type f | sed 's|repo/refs/heads/||' | sort | tr '\n' ' ')"

step "the repository served slowly on 127.0.0.1, added as flathub to root's own installation"
cat >/tmp/slow-server.py <<'PY'
import http.server, os, socketserver, sys, time
class Slow(http.server.SimpleHTTPRequestHandler):
    def copyfile(self, source, out):
        while True:
            chunk = source.read(65536)
            if not chunk:
                return
            out.write(chunk)
            out.flush()
            time.sleep(0.05)
    def log_message(self, *args):
        pass
os.chdir(sys.argv[1])
socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer.daemon_threads = True
with socketserver.ThreadingTCPServer(("127.0.0.1", int(sys.argv[2])), Slow) as server:
    server.serve_forever()
PY
python3 -I /tmp/slow-server.py "$build/repo" 8765 &
server=$!
trap 'kill $server 2>/dev/null' EXIT
sleep 1
flatpak remote-add --user --no-gpg-verify flathub http://127.0.0.1:8765/
echo "  flatpak remote-add -> exit $?"
flatpak remotes --user --columns=name,url | sed 's/^/  /'

step "the Store's unit tests with the real flatpak (STORE_TEST_FLATPAK=1)"
cd /work || exit 1
apps/store/build-direct.sh --tests >/tmp/build.log 2>&1 || { grep -E 'error' /tmp/build.log | head -20; exit 1; }
STORE_TEST_FLATPAK=1 QT_QPA_PLATFORM=offscreen .dev/build/store-unit-tests --gtest_filter='Flatpak.*' >/tmp/tests.log 2>&1
rc=$?
grep -E '^\[ *(RUN|OK|FAILED|SKIPPED|PASSED|INFO) *\]|Failure|Expected|Which is|Value of' /tmp/tests.log | sed 's/^/  /'
if grep -q 'SKIPPED' /tmp/tests.log && grep -q 'Flatpak.RealFlatpak' <(grep SKIPPED /tmp/tests.log); then
  echo "FAIL: Flatpak.RealFlatpak was skipped"
  exit 1
fi

step "an update (step 4, S31): Hello 1.2 installed by flatpak itself, Hello 1.3 published (the same metadata)"
flatpak install --user --noninteractive flathub org.example.Hello >/tmp/install.log 2>&1
echo "  flatpak install -> exit $?"
cd "$build" || exit 1
printf '#!/bin/sh\necho hello 1.3\n' >app/files/bin/hello
gunzip -f app/files/share/app-info/xmls/org.example.Hello.xml.gz
sed -i 's/<release version="1.2"/<release version="1.3"/' app/files/share/app-info/xmls/org.example.Hello.xml
gzip -f app/files/share/app-info/xmls/org.example.Hello.xml
flatpak build-export --arch=x86_64 repo app stable >/dev/null && flatpak build-update-repo repo >/dev/null
echo "  published -> exit $?"
cd /work || exit 1
STORE_TEST_FLATPAK_UPDATE=1 QT_QPA_PLATFORM=offscreen .dev/build/store-unit-tests --gtest_filter='Flatpak.RealUpdate' >/tmp/update.log 2>&1
urc=$?
grep -E '^\[ *(RUN|OK|FAILED|SKIPPED|PASSED) *\]|Failure|Expected|Which is|Value of' /tmp/update.log | sed 's/^/  /'
if grep -q 'SKIPPED' /tmp/update.log; then
  echo "FAIL: Flatpak.RealUpdate was skipped"
  exit 1
fi
[[ $rc == 0 && $urc == 0 ]] && echo "PASS: store_flatpak" || echo "FAIL: store_flatpak"
exit $(( rc == 0 && urc == 0 ? 0 : 1 ))
