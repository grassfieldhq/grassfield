#pragma once

#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

#include <functional>

// The Wi-Fi and Bluetooth sections over D-Bus (GF-049): NetworkManager (org.freedesktop.NetworkManager) and BlueZ (org.bluez), both
// on the system bus, instead of scraping `nmcli` and `bluetoothctl`. The logic here talks to a BusCaller, so the unit tests
// (tests/unit/settings/tst_systembus.cpp) run it against a canned one with no bus at all, and the integration tests
// (tests/integration/settings_dbus.sh) run it on a PRIVATE bus against fake services. The audio section stays on `wpctl`:
// PipeWire and WirePlumber have no D-Bus interface (see docs/specs/settings.md).
//
// Every call goes through one door, `guardedCall`: in a dev session (GRASSFIELD_DEV=1, a nested Hyprland on the owner's
// machine) only the read-only methods of `isReadOnlyCall` are sent, whatever asks; nothing can change the owner's network or
// Bluetooth from there. Qt Core, Qt DBus types only.
namespace grassfield::settings {

struct BusReply {
    bool ok = false;
    QVariantList args; // the reply's arguments as the bus gave them (QDBusArgument inside) or canned (plain values)
    QString error;     // "<error name>: <message>" when !ok
};

class BusCaller
{
public:
    virtual ~BusCaller() = default;
    virtual BusReply call(const QString &service, const QString &path, const QString &iface, const QString &member, const QVariantList &args,
                          int timeoutMs) = 0;
    // Signals (fprintd's enrolment, ADR-0045 OC-0.7): from now on, keep the `member` signals of `iface` that `service` sends
    // from `path`, for nextSignal. One listen per caller; false when it cannot (no bus, or a second listen).
    virtual bool listen(const QString & /*service*/, const QString & /*path*/, const QString & /*iface*/, const QString & /*member*/) { return false; }
    // The arguments of the oldest signal kept by listen, waiting at most timeoutMs for one; !ok when none came in that time.
    virtual BusReply nextSignal(int /*timeoutMs*/)
    {
        return {false, {}, QStringLiteral("org.freedesktop.DBus.Error.Timeout: no signal")}; // i18n-ignore: an error name, mapped to text by reasonOf
    }
};

// The only methods a dev session may send (they read: properties, object lists, connection settings without secrets).
bool isReadOnlyCall(const QString &service, const QString &iface, const QString &member, const QVariantList &args);

// A caller that refuses, in `dev`, every call that is not read-only (BusReply{ok=false, error="dev guard: ..."}).
class GuardedCaller : public BusCaller
{
public:
    GuardedCaller(BusCaller &inner, bool dev)
        : m_inner(inner)
        , m_dev(dev)
    {
    }
    BusReply call(const QString &service, const QString &path, const QString &iface, const QString &member, const QVariantList &args, int timeoutMs) override;
    // Receiving signals changes nothing: passed through in every session.
    bool listen(const QString &service, const QString &path, const QString &iface, const QString &member) override
    {
        return m_inner.listen(service, path, iface, member);
    }
    BusReply nextSignal(int timeoutMs) override { return m_inner.nextSignal(timeoutMs); }

private:
    BusCaller &m_inner;
    bool m_dev;
};

// Registers the container types the readers demarshal (once per process; harmless to repeat).
void registerBusTypes();

// A short single-line reason (at most 160 characters, no control characters) for a failed call: "NetworkManager is not running",
// the service's own message, "timed out".
QString reasonOf(const QString &error);

// State for the pages, as JSON the QML parses (qml/System.js):
//   wifiState: {"radio": bool, "device": {"name", "connected"} | null,
//               "aps": [{"hex" (SSID bytes, upper-case hex), "strength" 0-100, "flags", "wpa", "rsn", "active"}],
//               "profiles": [{"uuid", "hex"}]}      (saved Wi-Fi profiles with their SSID)
//   bluetoothState: {"present": bool, "powered": bool, "discovering": bool, "discoverable": bool, "alias" (the adapter's name),
//                    "devices": [{"mac", "name", "connected", "icon" (BlueZ's Icon), "battery" (percent, -1 unknown)}] (paired),
//                    "nearby": [{"mac", "name", "icon", "rssi"}] (not paired, in range: an RSSI, and a name to show)}
// `ok` false: the service did not answer (error holds the reason); the JSON is then empty.
struct StateResult {
    bool ok = false;
    QString error;
    QJsonObject json;
};
StateResult wifiState(BusCaller &bus);
StateResult bluetoothState(BusCaller &bus);

// The Hardware group's network panes (Wi-Fi details, Network, VPN), NetworkManager read in one go:
//   networkState: {"devices": [{"name", "type" ("ethernet" | "wifi"), "state" ("connected" | "connecting" | "disconnected" |
//                  "unavailable"), "mac", "connection" (the active profile's name), "uuid", "ip4": ["a.b.c.d/n"], "router",
//                  "dns": [...], "ip6": [...], "router6", "bitrate" (kbit/s, Wi-Fi), "frequency" (MHz, Wi-Fi), "ssid" (hex),
//                  "speed" (Mbit/s, Ethernet)}],
//                  "vpns": [{"uuid", "name", "kind" ("vpn" | "wireguard"), "state" ("connected" | "connecting" |
//                  "disconnected")}],
//                  "firewall": {"name" ("ufw" | "firewalld" | ""), "active" (its systemd unit is active)}}
// Ethernet and Wi-Fi devices only (loopback, bridges, tun and the like are not services the person chose). The firewall is
// read from systemd (Properties only: a dev session reads it too).
StateResult networkState(BusCaller &bus);

// Battery, UPower read in one go:
//   powerState: {"present" (a laptop battery), "onBattery", "percent", "state" (UPower's: 1 charging, 2 discharging, 4 full, ...),
//                "timeToEmpty", "timeToFull" (s), "capacity" (% of the design capacity), "cycles" (-1 unknown), "limitSupported",
//                "limitEnabled", "limitEnd" (%), "history24" / "history10" ([[time, percent, state]], the last 24 hours in 96
//                points, the last 10 days in 240; only when UPower keeps a history)}
StateResult powerState(BusCaller &bus);

// The General pane's system services (PR #6, ADR-0030), on the system bus:
//   hostState: hostname1  {"pretty", "static", "hostname", "chassis", "vendor", "model"}       (About)
//   timeState: timedate1 and timesync1  {"zone", "ntp", "canNtp", "synced", "usec" (microseconds since the epoch, as a string),
//              "localRtc", "server" (the server in use, "" when none), "servers": [the configured ones, link then system then fallback]}
//   timeZones: timedate1  {"zones": [...]}   (ListTimezones)
//   localeState: locale1  {"locale": ["LANG=...", ...]}
// and on the SESSION bus (the user's own service manager, no privilege):
//   userUnits: systemd  {"units": [{"unit", "path", "state"}]}: the user's own services (unit files under the user's config or data
//              directory, given as `ownDirs`), enabled or disabled; nothing of the system's or a package's
StateResult hostState(BusCaller &bus);
StateResult timeState(BusCaller &bus);
StateResult timeZones(BusCaller &bus);
StateResult localeState(BusCaller &bus);
StateResult userUnits(BusCaller &bus, const QStringList &ownDirs);

// Privacy & Security (ADR-0030 amendment 2026-10-26): the xdg-desktop-portal permission store on the SESSION bus
// (org.freedesktop.impl.portal.PermissionStore; no privilege: it is the user's own grants):
//   privacyState  {"location": [...], "camera": [...], "background": [...]: one {"app", "allowed"} per application the store
//                  holds a grant for (location: allowed unless its accuracy is NONE or unknown; camera and background: only
//                  "yes"; "ask" reads as not allowed), "screencast": [...], "remoteDesktop": [...]: one {"app", "token"} per
//                  saved screen-sharing or remote-desktop selection (not a grant: it lets the app skip the picker next time)}.
//                 A table the store does not have yet reads as empty; unsandboxed applications without an id ("") are left out.
//                 "portals": {"background", "remoteDesktop"}: whether org.freedesktop.portal.Desktop exports those portals (its
//                 Background or RemoteDesktop "version"; false when it has no such interface, left out when unknown). Asked
//                 only when the portal already runs (NameHasOwner): Settings never starts it.
StateResult privacyState(BusCaller &bus);

// ADR-0045 (OC-0.7), on the system bus, read in a dev session too:
//   sharingState  General > Sharing > Remote Login: systemd's sshd.service (ListUnitFilesByPatterns, read from the disk at each
//                 call, and the unit's Properties) {"installed" (its unit file exists), "unitFileState" ("enabled",
//                 "disabled", ... "" when not installed), "active" (ActiveState "active")}
//   diskState     Privacy & Security > Disk Encryption: UDisks2's objects (GetManagedObjects) {"encrypted" (the root file
//                 system lies directly on a LUKS device UDisks2 knows), "device" (that LUKS device's /dev name, "" when none)}.
//                 UDisks2 not answering is a failure (the page then offers Omarchy's terminal).
//   fingerprintState  Fingerprint & Security Key: fprintd's default reader (GetDefaultDevice, its Properties) and the user's
//                 enrolled fingers (ListEnrolledFingers "", the caller's own: polkit net.reactivated.fprint.device.verify,
//                 which the active session holds without a password) {"present" (a reader), "name", "stages" (touches an
//                 enrolment takes, num-enroll-stages), "scanType" ("press" | "swipe"), "fingers": [fprintd's finger names]}
StateResult sharingState(BusCaller &bus);
StateResult diskState(BusCaller &bus);
StateResult fingerprintState(BusCaller &bus);

// fprintd's finger names (EnrollStart's argument): "left-thumb" ... "right-little-finger".
bool isFingerName(const QString &s);

// The enrolment of one finger through fprintd (ADR-0045 OC-0.7): GetDefaultDevice, listen to the device's EnrollStatus, Claim
// (the caller's own user), EnrollStart(finger) (fprintd asks polkit, net.reactivated.fprint.device.enroll), then every status
// fprintd sends goes to `progress` (on the job's thread) until one says done; EnrollStop and Release always follow a
// successful EnrollStart and Claim. `stopped` is asked every quarter of a second: true ends the enrolment ("enroll-stopped").
// No status for `idleMs` ends it too ("timed out"), and so does `totalMs` after EnrollStart answered whatever the reader sends
// (someone else's touches cannot keep a forgotten enrolment going; security review of ADR-0045, L-5). Returns "" when fprintd
// said enroll-completed, else fprintd's final status (enroll-failed, enroll-data-full, enroll-disconnected,
// enroll-unknown-error, enroll-duplicate) or the reason of a failed call.
QString enrollFinger(BusCaller &bus, const QString &finger, const std::function<void(const QString &)> &progress, const std::function<bool()> &stopped,
                     int idleMs, int totalMs = 300000);

// One action as the pages ask for it: {"op": "...", ...}; returns "" on success, else the reason. Invalid values are refused
// here (mac, uuid and SSID shapes, booleans), whatever the QML sent. Ops:
//   wifi.radio {on}, wifi.disconnect {}, wifi.scan {},
//   wifi.connectKnown {uuid}       a saved network, followed until it is up or failed (awaitActivation; the profile stays);
//   wifi.connectOpen {hex}         an open network: a new profile, kept only once the connection is up (awaitActivation);
//   wifi.connectSecure {hex, psk}  a WPA/WPA3 personal network with its passphrase (8 to 63 printable ASCII characters or 64
//                                  hex digits): a new profile, kept only once the connection is up (awaitJoin);
//   bt.power {on}, bt.connect {mac, connect},
//   bt.discover {on}            Adapter1 StartDiscovery / StopDiscovery (already running or stopped is fine)
//   bt.pair {mac}               Device1 Pair (no agent: Just Works; it may wait for the device, kPrivilegedMs), Trusted, Connect
//   bt.forget {mac}             Adapter1 RemoveDevice
//   power.chargeLimit {on}      UPower EnableChargeThreshold on the battery (its polkit action, kPrivilegedMs)
//   wifi.forget {uuid}          the saved Wi-Fi profile's Delete (NetworkManager may ask polkit: kPrivilegedMs, ADR-0030)
//   vpn.connect {uuid, on}      a VPN or WireGuard profile: ActivateConnection on no device, followed until it is up or failed
//                               (awaitActivation), or its DeactivateConnection
//   printer.add {name, uri, info}   cups-pk-helper PrinterAdd (model "everywhere": cupsd builds the queue from the printer's IPP
//                               attributes), then PrinterSetEnabled and PrinterSetAcceptJobs (polkit, kPrivilegedMs each, ADR-0030)
//   printer.delete {name}       cups-pk-helper PrinterDelete (polkit, kPrivilegedMs)
//   printer.resume {name}       cups-pk-helper PrinterSetEnabled and PrinterSetAcceptJobs (a stopped queue, or one an add left
//                               stopped when its second dialog was refused; polkit, kPrivilegedMs each)
// and the General pane's (ADR-0030): the system service asks the session's polkit agent itself (interactive), so these calls wait
// for the user's answer (kPrivilegedMs):
//   host.setName {name}         hostname1 SetPrettyHostname, then SetStaticHostname with the name made a valid host name
//   time.ntp {on}               timedate1 SetNTP
//   time.zone {zone}            timedate1 SetTimezone
//   time.set {usec}             timedate1 SetTime: the time the clock is to read (microseconds since the epoch as a string), sent
//                               as the step from the clock now (relative), which timedated adds after the polkit dialog
//   user.enable {unit, on}      systemd (session bus) EnableUnitFiles / DisableUnitFiles, then Reload: no privilege
// and Privacy & Security's, on the session bus, no privilege:
//   privacy.allow {category, app, on}   the permission store's SetPermission for one application: location ["EXACT","0"] or
//                               ["NONE","0"] (two elements: one would read as no entry and the app would be asked again),
//                               camera and background ["yes"] or ["no"]
//   privacy.forget {kind, token}        Delete of one saved screencast or remoteDesktop selection
// and ADR-0045's (OC-0.7), on the system bus, each service asking polkit itself (interactive, kPrivilegedMs per call; ADR-0030
// amendment of 2026-11-04):
//   ssh.enable {on}             systemd's EnableUnitFiles ["sshd.service"] then StartUnit "sshd.service" (on), StopUnit then
//                               DisableUnitFiles (off): that one unit, its name never taken from the page
//                               (org.freedesktop.systemd1.manage-unit-files, manage-units). On is refused unless `sshSetUpFile`
//                               (Omarchy's /etc/ssh/sshd_config.d/10-omarchy-hardening.conf, a test's file in the tests) is a file
//   disk.passphrase {old, new}  UDisks2's Encrypted.ChangePassphrase(old, new, {}) on the LUKS device that holds the root file
//                               system, found here again (diskState), never named by the page; each passphrase 1 to 512
//                               characters without NUL (org.freedesktop.udisks2.encrypted-change-passphrase-system). The
//                               passphrases are never logged and never part of an answer; no answer in time is "the disk did
//                               not answer in time" (it may have changed), never a refusal
//   fprint.enroll {finger}      enrollFinger without progress (the Backend runs it with its progress and stop)
//   fprint.delete {finger}      fprintd's Claim, DeleteEnrolledFinger(finger), Release (net.reactivated.fprint.device.enroll)
// `ownDirs`: the user's unit directories (user.enable acts only on a unit listed there, userUnits).
QString runAction(BusCaller &bus, const QVariantMap &op, const QStringList &ownDirs = {},
                  const QString &sshSetUpFile = QStringLiteral("/etc/ssh/sshd_config.d/10-omarchy-hardening.conf"));

// The wait of a join (wifi.connectKnown, wifi.connectOpen, wifi.connectSecure) or a VPN switched on for the connection
// NetworkManager activates: `active` (the active connection it answered with), on `device` (the Wi-Fi device; "" for a VPN), with
// `newProfile` made for this join ("" for a saved profile, which always stays). Its State is read every `pollMs`: "" once it is
// up (2). One that went down (3, 4) or went away failed: the reason NetworkManager's device gives is said ("the password was not
// accepted", "the network gave this computer no address", ...), and a new profile is deleted (kPrivilegedMs: NetworkManager may
// ask polkit; a Delete that fails is said too). While NetworkManager asks for secrets (the device in need-auth, a VPN in
// NEED_AUTH: the session's secret agent shows its password sheet, SP-04) the user is answering: `deadlineMs` does not run then and
// counts again from the answer, and only `secretsWaitMs` in a row ends the wait. Still activating at the deadline: failed. A
// State that cannot be read leaves the state unknown, never a failure: still unknown at the deadline, nothing is deleted and the
// answer says the state could not be read. runAction waits 30 s, polling every 250 ms.
struct Activation {
    QString active;
    QString device;
    QString newProfile;
    bool vpn = false;
};
QString awaitActivation(BusCaller &bus, const Activation &activation, int deadlineMs, int pollMs, int secretsWaitMs = 150000);

// Whether an op follows the activation it starts (awaitActivation): it may wait for the user's password, and it is one change
// at a time on its page (the Backend runs it under its tag's latch, with room for that wait).
bool followsActivation(const QVariantMap &op);

// awaitActivation for a new profile `profile` and its active connection `active`, without a device to read (the tests' door to
// the plain wait).
QString awaitJoin(BusCaller &bus, const QString &profile, const QString &active, int deadlineMs, int pollMs);

// Whether an op goes to the session bus (user.*, privacy.*) rather than the system bus.
bool sessionAction(const QVariantMap &op);

// Whether an op asks for the user's authorization (it may wait for the polkit dialog).
bool privilegedAction(const QVariantMap &op);

// The host name derived from a computer name (hostname1's rules: lower case ASCII letters, digits and '-', at most 63, no
// leading or trailing '-'); "" when nothing usable is left.
QString hostNameFor(const QString &name);

// Whether an action map is well formed (what runAction checks first, without touching the bus).
bool validAction(const QVariantMap &op);

} // namespace grassfield::settings
