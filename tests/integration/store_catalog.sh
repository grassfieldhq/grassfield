#!/usr/bin/env bash
# Grassfield Store, step 1: the catalog's signature checked by the real gpgv against throwaway keys (ADR-0037 g; spec
# acceptance A1), with the whole backend's unit tests, in a throwaway Arch container. Never on a real machine: outside a
# container it starts one; inside, it refuses unless it is root in a container with the repository at /src.
#
#   tests/integration/store_catalog.sh
#   Runs `docker run --rm --network host` on archlinux:base (digest pinned below) with the repository mounted read-only;
#   HTTPS_PROXY/HTTP_PROXY/NO_PROXY are passed through and GRASSFIELD_TEST_CA, when set, is mounted as the container's CA
#   bundle (for a proxied network). Exit 0 all PASS (or SKIP without docker), 1 a FAIL, 2 usage.
#
# Inside: qt6-base, gtest, gcc, gnupg and python from Arch; three throwaway ed25519 keys made in a temporary GnuPG home
# (good, revoked, rogue) and gone with the container; a keyring folder laid out as grassfield-keyring's private folder
# (grassfield.gpg with the three public keys, grassfield-trusted listing good and revoked, grassfield-revoked listing
# revoked); the fixture catalog signed by each key, a copy with one byte changed, and the catalog signed as a message of
# its own (inline.sig). Then pacman's own keyring (the container's /etc/pacman.d/gnupg, pacman-key --init) with a fourth
# throwaway key, a packager's, copied at three moments: added but not locally signed, locally signed, disabled; a file and
# an AppStream-like package signed by it (S19). Then a local https server with a throwaway certificate the container
# trusts. Then the unit tests (plain and ASan) with STORE_TEST_REAL_GPGV, STORE_TEST_PACMAN_KEYRINGS and STORE_TEST_HTTPS;
# a skipped test is a failure here.
set -uo pipefail

IMAGE=archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0

if [[ ! -f /.dockerenv && ! -f /run/.containerenv ]]; then
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
  . "$root/tests/integration/container.sh" || exit 2
  if ! gf_have_docker; then
    echo "SKIP: store_catalog (no docker)"
    exit 0
  fi
  gf_container_init "$root" || exit 2
  gf_standard auto /test-ca.crt || exit 2
  gf_container_run "$IMAGE" bash /src/tests/integration/store_catalog.sh
  exit $?
fi

[[ $(id -u) == 0 && -d /src/apps/store ]] || { echo "refused: run as root in a container with the repository at /src"; exit 2; }
if [[ -f /test-ca.crt ]]; then
  cp /test-ca.crt /etc/ca-certificates/trust-source/anchors/test-ca.crt && update-ca-trust
fi
fail=0
step() { printf '\n== %s\n' "$*"; }

step "tools (a whole upgrade, never -Sy alone)"
pacman -Syu --noconfirm --needed qt6-base gtest gcc pkgconf gnupg zlib git python openssl libarchive >/tmp/pacman.log 2>&1 || { tail -5 /tmp/pacman.log; exit 1; }
pacman -Q qt6-base gtest gnupg pacman libarchive | sed 's/^/  /'
cp -r /src /work && cd /work

step "throwaway keys (a temporary GnuPG home, gone with the container)"
export GNUPGHOME=$(mktemp -d)
keys=/tmp/keyring
mkdir -p "$keys"
fpr() { gpg --batch --with-colons --list-keys "$1" | awk -F: '$1 == "fpr" {print $10; exit}'; }
for name in good revoked rogue; do
  gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key "Store test $name <$name@grassfield.invalid>" ed25519 sign 1d 2>/dev/null
done
good=$(fpr good@grassfield.invalid) revoked=$(fpr revoked@grassfield.invalid) rogue=$(fpr rogue@grassfield.invalid)
gpg --batch --export "$good" "$revoked" "$rogue" >"$keys/grassfield.gpg"
printf '%s:4:\n%s:4:\n' "$good" "$revoked" >"$keys/grassfield-trusted"
printf '%s\n' "$revoked" >"$keys/grassfield-revoked"
cp tests/fixtures/store/catalog-good.json "$keys/catalog.json"
sed 's/Discover/Discovrr/' "$keys/catalog.json" >"$keys/changed.json"
for name in good revoked rogue; do
  gpg --batch --yes --local-user "$(fpr "$name@grassfield.invalid")!" --detach-sign --output "$keys/$name.sig" "$keys/catalog.json"
done
gpg --batch --yes --local-user "$good!" --sign --output "$keys/inline.sig" "$keys/catalog.json"
echo "  good $good, revoked $revoked, rogue $rogue (rogue in the keyring, not trusted)"

step "pacman's keyring with a throwaway packager key (S19)"
pac=/tmp/pacman-keyrings
mkdir -p "$pac"
pacman-key --init >/dev/null 2>&1
gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key "Store test packager <packager@grassfield.invalid>" ed25519 sign 1d 2>/dev/null
packager=$(fpr packager@grassfield.invalid)
echo "data of a package" >"$pac/pkg"
cp "$pac/pkg" "$pac/changed" && echo x >>"$pac/changed"
gpg --batch --yes --local-user "$packager!" --detach-sign --output "$pac/pkg.sig" "$pac/pkg"
gpg --batch --yes --local-user "$packager!" --sign --output "$pac/inline.sig" "$pac/pkg"
# An AppStream-like package: the swcatalog tree, pacman's metadata, and members outside the tree (../escaped included).
tree=$(mktemp -d)
mkdir -p "$tree/root/usr/share/swcatalog/xml" "$tree/root/usr/bin"
gzip -c tests/fixtures/store/appstream-extra.xml >"$tree/root/usr/share/swcatalog/xml/extra.xml.gz"
echo "pkgname = archlinux-appstream-data" >"$tree/root/.PKGINFO"
echo "not app data" >"$tree/root/usr/bin/other"
echo "outside" >"$tree/escaped"
(cd "$tree/root" && bsdtar --zstd -cf "$pac/appstream.pkg.tar.zst" .PKGINFO usr ../escaped)
bsdtar -tf "$pac/appstream.pkg.tar.zst" | sed 's/^/  member: /'
gpg --batch --yes --local-user "$packager!" --detach-sign --output "$pac/appstream.pkg.tar.zst.sig" "$pac/appstream.pkg.tar.zst"
gpg --batch --armor --export "$packager" >"$pac/packager.asc"
snapshot() { mkdir -p "$pac/$1" && cp /etc/pacman.d/gnupg/pubring.* /etc/pacman.d/gnupg/trustdb.gpg "$pac/$1/" 2>/dev/null; }
pacman-key --add "$pac/packager.asc" >/dev/null 2>&1 && snapshot untrusted
pacman-key --verify "$pac/pkg.sig" "$pac/pkg" >/dev/null 2>&1
echo "  pacman-key --verify with the key added, not locally signed: exit $? (S19: 0, so its exit code proves nothing)"
pacman-key --lsign-key "$packager" >/dev/null 2>&1 && snapshot trusted
gpg --homedir /etc/pacman.d/gnupg --batch --no-tty --command-fd 0 --edit-key "$packager" disable quit </dev/null >/dev/null 2>&1
snapshot disabled
for k in untrusted trusted disabled; do
  gpg --homedir "$pac/$k" --batch --no-autostart --with-colons --list-keys "$packager" 2>/dev/null |
    awk -F: -v k="$k" '$1 == "pub" {print "  " k ": validity " $2 ", capabilities " $12}'
done

step "a local https server with a throwaway certificate the container trusts"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost -keyout /tmp/https.key -out /tmp/https.crt >/dev/null 2>&1
cp /tmp/https.crt /etc/ca-certificates/trust-source/anchors/store-test-https.crt && update-ca-trust
cat >/tmp/https.py <<'SERVER'
import http.server, json, socketserver, ssl, time


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, code, body=b"", headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path
        if p == "/cookie":
            self.send(302, headers=[("Set-Cookie", "probe=1; Path=/"), ("Location", "/echo")])
        elif p == "/echo":
            self.send(200, json.dumps({k.lower(): v for k, v in self.headers.items()}).encode())
        elif p == "/to-http":
            self.send(302, headers=[("Location", "http://localhost:8080/echo")])
        elif p.startswith("/chain/"):
            n = int(p.split("/")[2])
            if n > 0:
                self.send(302, headers=[("Location", f"/chain/{n - 1}")])
            else:
                self.send(200, b"end")
        elif p == "/big":
            self.send(200, b"x" * 100000)
        elif p == "/big-chunked":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for _ in range(50):
                self.wfile.write(b"7d0\r\n" + b"x" * 2000 + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        else:
            self.send(404)

    # A plan's HEADs (fetch.h headStatuses): /slow/<n> answers after a second, /hang after 30 s, /to-http redirects to http.
    def do_HEAD(self):
        p = self.path
        if p.startswith("/slow/"):
            time.sleep(1)
            self.head(200)
        elif p == "/hang":
            time.sleep(30)
            self.head(200)
        elif p == "/to-http":
            self.send_response(302)
            self.send_header("Location", "http://localhost:8080/echo")
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.head(404)

    def head(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "1000")
        self.end_headers()


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass  # the Store aborting an over-cap body resets the connection: expected


server = Server(("127.0.0.1", 8443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/tmp/https.crt", "/tmp/https.key")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
SERVER
python3 -I /tmp/https.py &
https_pid=$!
export NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1
for _ in $(seq 1 50); do curl -s --cacert /tmp/https.crt https://localhost:8443/echo >/dev/null && break; sleep 0.2; done
echo "  https://localhost:8443 (pid $https_pid)"

for variant in "" --asan; do
  step "the backend's unit tests${variant:+ ($variant)}, the real gpgv included"
  if apps/store/build-direct.sh --tests $variant >/tmp/build.log 2>&1; then
    bin=.dev/build/store-unit-tests${variant:+-asan}
    if STORE_TEST_REAL_GPGV=$keys STORE_TEST_PACMAN_KEYRINGS=$pac STORE_TEST_HTTPS=https://localhost:8443 \
        "$bin" --gtest_brief=1 >/tmp/tests.log 2>&1; then
      grep -E '^\[  (PASSED|SKIPPED|FAILED) ' /tmp/tests.log | sed 's/^/  /'
      if grep -q 'SKIPPED' /tmp/tests.log; then
        echo "FAIL: a test was skipped although the real gpgv is here"; fail=1
      else
        echo "PASS: unit tests${variant:+ ($variant)}, RealGpgv, RealPacmanKeyring, RealPackage, RealHttpsServer and RealSignedCatalog included"
      fi
    else
      tail -30 /tmp/tests.log; echo "FAIL: unit tests${variant:+ ($variant)}"; fail=1
    fi
  else
    tail -20 /tmp/build.log; echo "FAIL: build${variant:+ ($variant)}"; fail=1
  fi
done
kill "$https_pid" 2>/dev/null
rm -rf "$GNUPGHOME"
exit $fail
