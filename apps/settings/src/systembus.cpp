#include "systembus.h"

#include "systemguard.h"

#include <QByteArray>
#include <QCoreApplication>
#include <QDBusArgument>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusVariant>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QJsonArray>
#include <QMap>
#include <QRegularExpression>
#include <QThread>

#include <algorithm>

namespace grassfield::settings {

namespace {
using ConnectionSettings = QMap<QString, QVariantMap>;
using ManagedObjects = QMap<QDBusObjectPath, ConnectionSettings>;
// The permission store's grants of one entry: application id -> its values (a{sas}).
using PermissionTable = QMap<QString, QStringList>;

constexpr int kReadMs = 3000;
constexpr int kActMs = 30000; // a Bluetooth connect or a Wi-Fi association can take a while
constexpr int kPrivilegedMs = 120000; // the service asks the polkit agent first: the user reads the dialog and types a password
constexpr int kMaxReason = 160;

const QString kProps = QStringLiteral("org.freedesktop.DBus.Properties");
const QString kNmService = QStringLiteral("org.freedesktop.NetworkManager");
const QString kNmPath = QStringLiteral("/org/freedesktop/NetworkManager");
const QString kNmIface = QStringLiteral("org.freedesktop.NetworkManager");
const QString kNmDevice = QStringLiteral("org.freedesktop.NetworkManager.Device");
const QString kNmWireless = QStringLiteral("org.freedesktop.NetworkManager.Device.Wireless");
const QString kNmAp = QStringLiteral("org.freedesktop.NetworkManager.AccessPoint");
const QString kNmSettingsPath = QStringLiteral("/org/freedesktop/NetworkManager/Settings");
const QString kNmSettings = QStringLiteral("org.freedesktop.NetworkManager.Settings");
const QString kNmConnection = QStringLiteral("org.freedesktop.NetworkManager.Settings.Connection");
const QString kNmIp4 = QStringLiteral("org.freedesktop.NetworkManager.IP4Config");
const QString kNmIp6 = QStringLiteral("org.freedesktop.NetworkManager.IP6Config");
const QString kNmActive = QStringLiteral("org.freedesktop.NetworkManager.Connection.Active");
const QString kBluez = QStringLiteral("org.bluez");
const QString kObjectManager = QStringLiteral("org.freedesktop.DBus.ObjectManager");
const QString kAdapter = QStringLiteral("org.bluez.Adapter1");
const QString kDevice1 = QStringLiteral("org.bluez.Device1");
const QString kBattery1 = QStringLiteral("org.bluez.Battery1");
const QString kUPower = QStringLiteral("org.freedesktop.UPower");
const QString kUPowerPath = QStringLiteral("/org/freedesktop/UPower");
const QString kUPowerDevice = QStringLiteral("org.freedesktop.UPower.Device");
const QString kUPowerDisplay = QStringLiteral("/org/freedesktop/UPower/devices/DisplayDevice");
// cups-pk-helper (ADR-0030): its bus name is also its interface; one object, "/".
const QString kCupsPk = QStringLiteral("org.opensuse.CupsPkHelper.Mechanism");
const QString kCupsPkPath = QStringLiteral("/");
// The General pane's services (ADR-0030).
const QString kHostService = QStringLiteral("org.freedesktop.hostname1");
const QString kHostPath = QStringLiteral("/org/freedesktop/hostname1");
const QString kTimeService = QStringLiteral("org.freedesktop.timedate1");
const QString kTimePath = QStringLiteral("/org/freedesktop/timedate1");
const QString kSyncService = QStringLiteral("org.freedesktop.timesync1");
const QString kSyncPath = QStringLiteral("/org/freedesktop/timesync1");
const QString kSyncManager = QStringLiteral("org.freedesktop.timesync1.Manager");
const QString kLocaleService = QStringLiteral("org.freedesktop.locale1");
const QString kLocalePath = QStringLiteral("/org/freedesktop/locale1");
const QString kSystemd = QStringLiteral("org.freedesktop.systemd1");
const QString kSystemdPath = QStringLiteral("/org/freedesktop/systemd1");
const QString kSystemdManager = QStringLiteral("org.freedesktop.systemd1.Manager");
const QString kSystemdUnit = QStringLiteral("org.freedesktop.systemd1.Unit");
const QString kNmWired = QStringLiteral("org.freedesktop.NetworkManager.Device.Wired");
// ADR-0045 (OC-0.7): Remote Login is systemd's sshd.service and nothing else; Disk Encryption's password is UDisks2's; the
// fingerprints are fprintd's. All on the system bus, each service asking polkit itself.
const QString kSshdUnit = QStringLiteral("sshd.service");
const QString kSshdPath = QStringLiteral("/org/freedesktop/systemd1/unit/sshd_2eservice");
const QString kUDisks = QStringLiteral("org.freedesktop.UDisks2");
const QString kUDisksPath = QStringLiteral("/org/freedesktop/UDisks2");
const QString kUDisksBlock = QStringLiteral("org.freedesktop.UDisks2.Block");
const QString kUDisksFilesystem = QStringLiteral("org.freedesktop.UDisks2.Filesystem");
const QString kUDisksEncrypted = QStringLiteral("org.freedesktop.UDisks2.Encrypted");
const QString kFprint = QStringLiteral("net.reactivated.Fprint");
const QString kFprintManagerPath = QStringLiteral("/net/reactivated/Fprint/Manager");
const QString kFprintManager = QStringLiteral("net.reactivated.Fprint.Manager");
const QString kFprintDevice = QStringLiteral("net.reactivated.Fprint.Device");
// An enrolment waits for fprintd's statuses in slices this long, asking between two whether the sheet was closed.
constexpr int kEnrollSliceMs = 250;
// The xdg-desktop-portal permission store (session bus; its bus name is also its interface).
const QString kPermStore = QStringLiteral("org.freedesktop.impl.portal.PermissionStore");
const QString kPermStorePath = QStringLiteral("/org/freedesktop/impl/portal/PermissionStore");
// At most this many saved selections are read per table (each is one Lookup), counted after the malformed ones are dropped.
constexpr int kMaxSavedSelections = 128;

// Privacy & Security's switches: the table and id each portal keeps its grant under, and the values the store holds for
// allowed and not allowed (xdg-desktop-portal: camera.c, location.c, background.c; location keeps [accuracy, timestamp]).
struct PrivacyGrant {
    QString category, table, id;
    QStringList allow, deny;
};
const QList<PrivacyGrant> &privacyGrants()
{
    static const QList<PrivacyGrant> grants{
        {QStringLiteral("location"), QStringLiteral("location"), QStringLiteral("location"), {QStringLiteral("EXACT"), QStringLiteral("0")},
         {QStringLiteral("NONE"), QStringLiteral("0")}},
        {QStringLiteral("camera"), QStringLiteral("devices"), QStringLiteral("camera"), {QStringLiteral("yes")}, {QStringLiteral("no")}},
        {QStringLiteral("background"), QStringLiteral("background"), QStringLiteral("background"), {QStringLiteral("yes")}, {QStringLiteral("no")}},
    };
    return grants;
}
// The desktop portal (session bus): whether it exports the portals the background and remote desktop grants are for. A
// portal that no backend implements is not exported at all (xdg-desktop-portal background.c, remote-desktop.c), and
// Omarchy's backends may implement neither (ADR-0030).
const QString kPortal = QStringLiteral("org.freedesktop.portal.Desktop");
const QString kPortalPath = QStringLiteral("/org/freedesktop/portal/desktop");
// The bus itself: whether the portal already runs. privacyState never starts it: on a dev session's private bus that would
// start xdg-desktop-portal and with it the document portal, which remounts $XDG_RUNTIME_DIR/doc, the owner's (review of
// 4ca0246, M1); QtBusCaller does not auto-start it either. Qt's own platform theme (gtk3, gnome, xdgdesktopportal) asks it
// when the app starts: the dev bus blocks both portals for that (scripts/dev/shell-run.sh, ADR-0011, re-check of 06da80f,
// MEDIUM-1). In a real session it runs (the session's Qt apps register with it).
const QString kDBusName = QStringLiteral("org.freedesktop.DBus");
const QString kDBusPath = QStringLiteral("/org/freedesktop/DBus");
// A portal that does not answer costs this much, once per read (review of 4ca0246, L4).
constexpr int kPortalReadMs = 1000;
const QList<QPair<QString, QString>> &privacyPortals()
{
    static const QList<QPair<QString, QString>> portals{{QStringLiteral("background"), QStringLiteral("org.freedesktop.portal.Background")},
                                                        {QStringLiteral("remoteDesktop"), QStringLiteral("org.freedesktop.portal.RemoteDesktop")}};
    return portals;
}
// The saved selections of screen sharing and remote desktop: page key -> store table.
const QList<QPair<QString, QString>> &privacySelections()
{
    static const QList<QPair<QString, QString>> tables{{QStringLiteral("screencast"), QStringLiteral("screencast")},
                                                       {QStringLiteral("remoteDesktop"), QStringLiteral("remote-desktop")}};
    return tables;
}

constexpr uint kDeviceTypeWifi = 2;
constexpr uint kDeviceStateActivated = 100;

// A value as the bus gives it (a QDBusArgument inside the variant: read by streaming) or as a canned reply has it (the value).
template<typename T>
T cast(const QVariant &v)
{
    if (v.metaType() == QMetaType::fromType<QDBusArgument>())
        return qdbus_cast<T>(qvariant_cast<QDBusArgument>(v));
    return qvariant_cast<T>(v);
}

// A property value as the bus gives it (a QDBusVariant) or as a canned reply has it (the value itself).
QVariant unwrap(const QVariant &v)
{
    if (v.metaType() == QMetaType::fromType<QDBusVariant>())
        return qvariant_cast<QDBusVariant>(v).variant();
    return v;
}

struct Result {
    bool ok = false;
    QVariant value;
    QString error;
};

Result property(BusCaller &bus, const QString &service, const QString &path, const QString &iface, const QString &name)
{
    const BusReply r = bus.call(service, path, kProps, QStringLiteral("Get"), {iface, name}, kReadMs);
    if (!r.ok || r.args.isEmpty())
        return {false, {}, r.ok ? QCoreApplication::translate("SystemBus", "empty reply") : r.error};
    return {true, unwrap(r.args.first()), {}};
}

struct Props {
    bool ok = false;
    QVariantMap map;
    QString error;
};

Props allProperties(BusCaller &bus, const QString &service, const QString &path, const QString &iface)
{
    const BusReply r = bus.call(service, path, kProps, QStringLiteral("GetAll"), {iface}, kReadMs);
    if (!r.ok || r.args.isEmpty())
        return {false, {}, r.ok ? QCoreApplication::translate("SystemBus", "empty reply") : r.error};
    return {true, cast<QVariantMap>(r.args.first()), {}};
}

QList<QDBusObjectPath> paths(const BusReply &r)
{
    return r.ok && !r.args.isEmpty() ? cast<QList<QDBusObjectPath>>(r.args.first()) : QList<QDBusObjectPath>();
}

QString upperHex(const QByteArray &bytes)
{
    return QString::fromLatin1(bytes.toHex().toUpper());
}

// The first Wi-Fi device: its path, and its Device properties.
struct WifiDevice {
    bool found = false;
    QString path;
    QVariantMap props;
};

WifiDevice firstWifiDevice(BusCaller &bus, QString *error)
{
    const BusReply r = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("GetDevices"), {}, kReadMs);
    if (!r.ok) {
        *error = r.error;
        return {};
    }
    for (const QDBusObjectPath &p : paths(r)) {
        const Props props = allProperties(bus, kNmService, p.path(), kNmDevice);
        if (props.ok && props.map.value(QStringLiteral("DeviceType")).toUInt() == kDeviceTypeWifi)
            return {true, p.path(), props.map};
    }
    return {};
}

struct AccessPoint {
    QString path;
    QByteArray ssid;
    int strength = 0;
    uint flags = 0, wpa = 0, rsn = 0;
};

QList<AccessPoint> accessPoints(BusCaller &bus, const QString &devicePath)
{
    QList<AccessPoint> out;
    for (const QDBusObjectPath &p : paths(bus.call(kNmService, devicePath, kNmWireless, QStringLiteral("GetAllAccessPoints"), {}, kReadMs))) {
        const Props props = allProperties(bus, kNmService, p.path(), kNmAp);
        if (!props.ok)
            continue; // the access point went away between the two calls
        AccessPoint ap;
        ap.path = p.path();
        ap.ssid = cast<QByteArray>(props.map.value(QStringLiteral("Ssid")));
        ap.strength = props.map.value(QStringLiteral("Strength")).toInt();
        ap.flags = props.map.value(QStringLiteral("Flags")).toUInt();
        ap.wpa = props.map.value(QStringLiteral("WpaFlags")).toUInt();
        ap.rsn = props.map.value(QStringLiteral("RsnFlags")).toUInt();
        out.append(ap);
    }
    return out;
}

// NM_802_11_AP_SEC_KEY_MGMT_*: PSK 0x100, 802.1X 0x200, SAE 0x400, OWE 0x800, OWE transition 0x1000, Suite-B 0x2000.
constexpr uint kKeyMgmtNeedsCredentials = 0x100 | 0x200 | 0x400 | 0x2000;
constexpr uint kKeyMgmtOwe = 0x800;

// Enhanced Open (OWE): encrypted without a password, like an open network for the person joining it (Apple's platform security
// guide calls it improved security "on open networks", "unauthenticated networks"). The access point offers OWE and nothing
// that asks for a key or an account.
bool isOwe(const AccessPoint &ap)
{
    return ap.wpa == 0 && (ap.rsn & kKeyMgmtOwe) != 0 && (ap.rsn & kKeyMgmtNeedsCredentials) == 0;
}

constexpr uint kKeyMgmtOweTransition = 0x1000;

// Whether joining needs a password or an account: WPA/WPA2/WPA3/802.1X (or any other key management), or WEP (privacy flag with
// no WPA/RSN information at all). Enhanced Open does not, and neither does the open side of OWE transition mode (RsnFlags 0x1000
// only). This is the rule of System.wifiSecurity: the label ("" or "OWE" = no lock, joins with a click) and the join agree.
bool needsCredentials(const AccessPoint &ap)
{
    if (isOwe(ap))
        return false;
    return ap.wpa != 0 || (ap.rsn & ~kKeyMgmtOweTransition) != 0 || ((ap.flags & 1) != 0 && ap.rsn == 0);
}

struct Profile {
    QString path;
    QString uuid;
    QByteArray ssid;
};

QList<Profile> wifiProfiles(BusCaller &bus)
{
    QList<Profile> out;
    for (const QDBusObjectPath &p : paths(bus.call(kNmService, kNmSettingsPath, kNmSettings, QStringLiteral("ListConnections"), {}, kReadMs))) {
        const BusReply r = bus.call(kNmService, p.path(), kNmConnection, QStringLiteral("GetSettings"), {}, kReadMs);
        if (!r.ok || r.args.isEmpty())
            continue;
        const ConnectionSettings s = cast<ConnectionSettings>(r.args.first());
        if (s.value(QStringLiteral("connection")).value(QStringLiteral("type")).toString() != QLatin1String("802-11-wireless"))
            continue;
        Profile profile;
        profile.path = p.path();
        profile.uuid = s.value(QStringLiteral("connection")).value(QStringLiteral("uuid")).toString();
        profile.ssid = cast<QByteArray>(s.value(QStringLiteral("802-11-wireless")).value(QStringLiteral("ssid")));
        out.append(profile);
    }
    return out;
}

ManagedObjects bluezObjects(BusCaller &bus, QString *error)
{
    const BusReply r = bus.call(kBluez, QStringLiteral("/"), kObjectManager, QStringLiteral("GetManagedObjects"), {}, kReadMs);
    if (!r.ok || r.args.isEmpty()) {
        *error = r.ok ? QCoreApplication::translate("SystemBus", "empty reply") : r.error;
        return {};
    }
    return cast<ManagedObjects>(r.args.first());
}

QString firstAdapterPath(const ManagedObjects &objects)
{
    for (auto it = objects.cbegin(); it != objects.cend(); ++it) {
        if (it.value().contains(kAdapter))
            return it.key().path();
    }
    return {};
}

bool isMac(const QString &s)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}")));
    return re.match(s).hasMatch();
}

bool isSsidHex(const QString &s)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("([0-9A-Fa-f]{2}){1,32}")));
    return re.match(s).hasMatch();
}

// A WPA/WPA3 personal passphrase as NetworkManager takes it: 8 to 63 printable ASCII characters, or the 64 hex digits of a
// raw key.
bool isPassphrase(const QVariant &v)
{
    if (v.metaType() != QMetaType::fromType<QString>())
        return false;
    static const QRegularExpression ascii(QRegularExpression::anchoredPattern(QStringLiteral("[\\x20-\\x7E]{8,63}")));
    static const QRegularExpression raw(QRegularExpression::anchoredPattern(QStringLiteral("[0-9A-Fa-f]{64}")));
    const QString s = v.toString();
    return ascii.match(s).hasMatch() || raw.match(s).hasMatch();
}

bool isBool(const QVariant &v)
{
    return v.metaType() == QMetaType::fromType<bool>();
}

QString fail(const QString &error)
{
    const QString r = reasonOf(error);
    return r.isEmpty() ? QCoreApplication::translate("SystemBus", "failed") : r;
}

QString setProperty(BusCaller &bus, const QString &service, const QString &path, const QString &iface, const QString &name, const QVariant &value)
{
    const BusReply r = bus.call(service, path, kProps, QStringLiteral("Set"), {iface, name, QVariant::fromValue(QDBusVariant(value))}, kActMs);
    return r.ok ? QString() : fail(r.error);
}

// A string a service gave, for showing: control characters dropped, at most 256 characters.
QString clean(const QVariant &v)
{
    QString t = unwrap(v).toString();
    t.remove(QRegularExpression(QStringLiteral("[\\x00-\\x1f\\x7f]")));
    return t.left(256);
}

QStringList strings(const QVariant &v)
{
    const QVariant u = unwrap(v);
    QStringList out;
    for (const QString &t : cast<QStringList>(u))
        out << clean(t);
    return out;
}

QJsonArray jsonStrings(const QStringList &list)
{
    QJsonArray a;
    for (const QString &t : list)
        a.append(t);
    return a;
}

// systemd's a(ss) of ListUnitFilesByPatterns: (path, state), from the bus (a QDBusArgument) or canned ([[path, state], ...]).
QList<QPair<QString, QString>> unitFiles(const QVariant &v)
{
    QList<QPair<QString, QString>> out;
    if (v.metaType() == QMetaType::fromType<QDBusArgument>()) {
        const QDBusArgument arg = qvariant_cast<QDBusArgument>(v);
        arg.beginArray();
        while (!arg.atEnd()) {
            QString path, state;
            arg.beginStructure();
            arg >> path >> state;
            arg.endStructure();
            out.append({path, state});
        }
        arg.endArray();
        return out;
    }
    for (const QVariant &e : v.toList()) {
        const QVariantList pair = e.toList();
        if (pair.size() == 2)
            out.append({pair.at(0).toString(), pair.at(1).toString()});
    }
    return out;
}

// A time zone name as timedate1 takes it: Area/Location (letters, digits, '_', '-', '+'), at most 64 characters.
bool isZone(const QString &s)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,3}"))); // anchored: "$" alone would let a final newline through
    return s.size() <= 64 && re.match(s).hasMatch();
}

// A computer name: 1 to 64 characters, none of them a control character.
bool isComputerName(const QString &s)
{
    static const QRegularExpression control(QStringLiteral("[\\x00-\\x1f\\x7f]"));
    return !s.trimmed().isEmpty() && s.size() <= 64 && !control.match(s).hasMatch();
}

// A printer's description (CUPS printer-info): 1 to 127 characters, no control character.
bool isPrinterInfo(const QVariant &v)
{
    static const QRegularExpression control(QStringLiteral("[\\x00-\\x1f\\x7f]"));
    const QString s = v.toString();
    return v.metaType() == QMetaType::fromType<QString>() && !s.trimmed().isEmpty() && s.size() <= 127 && !control.match(s).hasMatch();
}

// Microseconds since the epoch, as a decimal string, between 2000-01-01 and 2200-01-01.
bool isUsec(const QVariant &v, qint64 *out)
{
    const QString t = v.toString();
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[0-9]{15,17}")));
    if (v.metaType() != QMetaType::fromType<QString>() || !re.match(t).hasMatch())
        return false;
    bool ok = false;
    const qint64 value = t.toLongLong(&ok);
    if (!ok || value < 946684800000000LL || value > 7258118400000000LL)
        return false;
    if (out)
        *out = value;
    return true;
}

// A user service's unit name: letters, digits, ':', '_', '.', '@', '-', ending in ".service"; at most 200 characters.
bool isUserUnit(const QString &s)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9:_.@-]+\\.service")));
    return s.size() <= 200 && re.match(s).hasMatch();
}

QString privileged(BusCaller &bus, const QString &service, const QString &path, const QString &member, const QVariantList &args)
{
    const BusReply r = bus.call(service, path, service, member, args, kPrivilegedMs);
    return r.ok ? QString() : fail(r.error);
}

// A disk passphrase as Settings passes it to UDisks2: a string of 1 to 512 characters without NUL (cryptsetup's own limit for a
// typed passphrase is 512). Nothing else is checked: any character may be part of a passphrase.
bool isDiskPassphrase(const QVariant &v)
{
    if (v.metaType() != QMetaType::fromType<QString>())
        return false;
    const QString s = v.toString();
    return !s.isEmpty() && s.size() <= 512 && !s.contains(QChar(0));
}

// A byte string of UDisks2 (MountPoints, PreferredDevice): NUL-terminated on the bus.
QByteArray unterminated(QByteArray bytes)
{
    while (bytes.endsWith('\0'))
        bytes.chop(1);
    return bytes;
}

// The LUKS device under the root file system, as UDisks2 has it: the object path of the block whose Encrypted interface opens
// the block that the file system mounted at "/" lies on (Block.CryptoBackingDevice), and its /dev name in `device`. "" when
// the root file system is not directly on a LUKS device (or UDisks2 does not know it: no error then), or when UDisks2 did not
// answer (`error` holds why). LVM or another layer between the two is not followed.
QString rootLuksDevice(BusCaller &bus, QString *error, QString *device)
{
    const BusReply r = bus.call(kUDisks, kUDisksPath, kObjectManager, QStringLiteral("GetManagedObjects"), {}, kReadMs);
    if (!r.ok || r.args.isEmpty()) {
        *error = r.ok ? QCoreApplication::translate("SystemBus", "empty reply") : r.error;
        return QString();
    }
    const ManagedObjects objects = cast<ManagedObjects>(r.args.first());
    for (auto it = objects.cbegin(); it != objects.cend(); ++it) {
        if (!it.value().contains(kUDisksFilesystem))
            continue;
        bool root = false;
        for (const QByteArray &mount : cast<QList<QByteArray>>(it.value().value(kUDisksFilesystem).value(QStringLiteral("MountPoints"))))
            root = root || unterminated(mount) == QByteArray("/");
        if (!root)
            continue;
        const QString backing = cast<QDBusObjectPath>(it.value().value(kUDisksBlock).value(QStringLiteral("CryptoBackingDevice"))).path();
        if (backing.isEmpty() || backing == QLatin1String("/"))
            return QString();
        const auto luks = objects.constFind(QDBusObjectPath(backing));
        if (luks == objects.cend() || !luks.value().contains(kUDisksEncrypted))
            return QString();
        *device = clean(QString::fromUtf8(unterminated(cast<QByteArray>(luks.value().value(kUDisksBlock).value(QStringLiteral("PreferredDevice"))))));
        return backing;
    }
    return QString();
}

// What UDisks2 answers when the current passphrase opens no key slot (libblockdev: "No key available with this passphrase"),
// said plainly; any other failure as the service gave it.
QString passphraseFailure(const QString &error)
{
    if (error.contains(QLatin1String("No key available"), Qt::CaseInsensitive)) // i18n-ignore: libblockdev's message, matched
        return QCoreApplication::translate("SystemBus", "the current password is not correct");
    // No answer in time is not a refusal: UDisks2 may have changed it meanwhile (security review of ADR-0045, L-1). The sheet
    // words this reason on its own (DiskPasswordSheet.qml), never as "not changed".
    if (fail(error) == QCoreApplication::translate("SystemBus", "timed out"))
        return QCoreApplication::translate("SystemBus", "the disk did not answer in time");
    return fail(error);
}
} // namespace

void registerBusTypes()
{
    static const bool once = [] {
        qDBusRegisterMetaType<ConnectionSettings>();
        qDBusRegisterMetaType<ManagedObjects>();
        qDBusRegisterMetaType<PermissionTable>();
        return true;
    }();
    Q_UNUSED(once)
}

bool isReadOnlyCall(const QString &service, const QString &iface, const QString &member, const QVariantList &args)
{
    // The General pane's services: their properties, the list of time zones and the user's unit files.
    if (service == kHostService || service == kTimeService || service == kSyncService || service == kLocaleService) {
        if (iface == kProps)
            return member == QLatin1String("Get") || member == QLatin1String("GetAll");
        return service == kTimeService && iface == kTimeService && member == QLatin1String("ListTimezones");
    }
    // UPower: its properties, its devices and their history.
    if (service == kUPower)
        return (iface == kProps && (member == QLatin1String("Get") || member == QLatin1String("GetAll")))
            || (iface == kUPower && (member == QLatin1String("EnumerateDevices") || member == QLatin1String("GetDisplayDevice")))
            || (iface == kUPowerDevice && member == QLatin1String("GetHistory"));
    if (service == kSystemd)
        return (iface == kProps && (member == QLatin1String("Get") || member == QLatin1String("GetAll")))
            || (iface == kSystemdManager && member == QLatin1String("ListUnitFilesByPatterns"));
    // The bus: only whether the desktop portal runs.
    if (service == kDBusName)
        return iface == kDBusName && member == QLatin1String("NameHasOwner") && args.size() == 1 && args.at(0).toString() == kPortal;
    // The desktop portal: only the version of the two portals Privacy & Security asks about.
    if (service == kPortal)
        return iface == kProps && member == QLatin1String("Get") && args.size() == 2 && args.at(1).toString() == QLatin1String("version")
            && std::any_of(privacyPortals().cbegin(), privacyPortals().cend(), [&](const QPair<QString, QString> &p) { return args.at(0).toString() == p.second; });
    // The permission store: its tables and entries.
    if (service == kPermStore)
        return iface == kPermStore
            && (member == QLatin1String("Lookup") || member == QLatin1String("List") || member == QLatin1String("GetPermission"));
    // Disk Encryption (ADR-0045): UDisks2's objects, to find the LUKS device under the root file system.
    if (service == kUDisks)
        return iface == kObjectManager && member == QLatin1String("GetManagedObjects");
    // Fingerprint (ADR-0045): fprintd's reader and the user's enrolled fingers. Claim, an enrolment and a deletion are actions.
    if (service == kFprint)
        return (iface == kProps && (member == QLatin1String("Get") || member == QLatin1String("GetAll")))
            || (iface == kFprintManager && member == QLatin1String("GetDefaultDevice"))
            || (iface == kFprintDevice && member == QLatin1String("ListEnrolledFingers"));
    if (service != kNmService && service != kBluez)
        return false;
    if (iface == kProps)
        return member == QLatin1String("Get") || member == QLatin1String("GetAll");
    if (service == kBluez)
        return iface == kObjectManager && member == QLatin1String("GetManagedObjects");
    return (iface == kNmIface && member == QLatin1String("GetDevices")) || (iface == kNmWireless && member == QLatin1String("GetAllAccessPoints"))
        || (iface == kNmSettings && member == QLatin1String("ListConnections")) || (iface == kNmConnection && member == QLatin1String("GetSettings"));
}

BusReply GuardedCaller::call(const QString &service, const QString &path, const QString &iface, const QString &member, const QVariantList &args, int timeoutMs)
{
    if (m_dev && !isReadOnlyCall(service, iface, member, args)) {
        BusReply r;
        r.error = QStringLiteral("dev guard: %1.%2 suppressed").arg(iface, member); // i18n-ignore: a log line
        return r;
    }
    return m_inner.call(service, path, iface, member, args, timeoutMs);
}

QString reasonOf(const QString &error)
{
    if (error.contains(QLatin1String("ServiceUnknown")) || error.contains(QLatin1String("NameHasNoOwner")))
        return QCoreApplication::translate("SystemBus", "the service is not running");
    if (error.contains(QLatin1String("NoReply")) || error.contains(QLatin1String("Timeout")) || error.contains(QLatin1String("timed out"))) // i18n-ignore: a match on the error text
        return QCoreApplication::translate("SystemBus", "timed out");
    if (error.contains(QLatin1String("AccessDenied")) || error.contains(QLatin1String("NotAuthorized")) || error.contains(QLatin1String("PermissionDenied"))
        || error.contains(QLatin1String("NotPrivileged")))
        return QCoreApplication::translate("SystemBus", "not allowed: the system refused the request");
    if (error.contains(QLatin1String("NoServer")))
        return QCoreApplication::translate("SystemBus", "no connection to the system bus");
    QString t = error;
    const int colon = t.indexOf(QLatin1String(": "));
    if (colon >= 0 && t.left(colon).contains(QLatin1Char('.')))
        t = t.mid(colon + 2);
    t = t.simplified();
    t.remove(QRegularExpression(QStringLiteral("[\\x00-\\x1f\\x7f]")));
    return t.left(kMaxReason);
}

StateResult wifiState(BusCaller &bus)
{
    StateResult r;
    const Result radio = property(bus, kNmService, kNmPath, kNmIface, QStringLiteral("WirelessEnabled"));
    if (!radio.ok) {
        r.error = reasonOf(radio.error);
        return r;
    }
    QString error;
    const WifiDevice dev = firstWifiDevice(bus, &error);
    QJsonObject out;
    out.insert(QStringLiteral("radio"), radio.value.toBool());
    QJsonArray aps;
    if (dev.found) {
        out.insert(QStringLiteral("device"), QJsonObject{{QStringLiteral("name"), dev.props.value(QStringLiteral("Interface")).toString()},
                                                         {QStringLiteral("connected"), dev.props.value(QStringLiteral("State")).toUInt() == kDeviceStateActivated}});
        if (radio.value.toBool()) {
            const Result active = property(bus, kNmService, dev.path, kNmWireless, QStringLiteral("ActiveAccessPoint"));
            const QString activePath = active.ok ? cast<QDBusObjectPath>(active.value).path() : QString();
            for (const AccessPoint &ap : accessPoints(bus, dev.path)) {
                aps.append(QJsonObject{{QStringLiteral("hex"), upperHex(ap.ssid)},
                                       {QStringLiteral("strength"), ap.strength},
                                       {QStringLiteral("flags"), static_cast<qint64>(ap.flags)},
                                       {QStringLiteral("wpa"), static_cast<qint64>(ap.wpa)},
                                       {QStringLiteral("rsn"), static_cast<qint64>(ap.rsn)},
                                       {QStringLiteral("active"), ap.path == activePath && activePath != QLatin1String("/")}});
            }
        }
    } else {
        out.insert(QStringLiteral("device"), QJsonValue::Null);
    }
    out.insert(QStringLiteral("aps"), aps);
    QJsonArray profiles;
    for (const Profile &p : wifiProfiles(bus))
        profiles.append(QJsonObject{{QStringLiteral("uuid"), p.uuid}, {QStringLiteral("hex"), upperHex(p.ssid)}});
    out.insert(QStringLiteral("profiles"), profiles);
    r.ok = true;
    r.json = out;
    return r;
}

namespace {
constexpr uint kDeviceTypeEthernet = 1;

// An aa{sv} property (IP4Config AddressData, NameserverData) from the bus (a QDBusArgument) or canned (a list of maps).
QList<QVariantMap> mapList(const QVariant &v)
{
    const QVariant u = unwrap(v);
    QList<QVariantMap> out;
    if (u.metaType() == QMetaType::fromType<QDBusArgument>()) {
        const QDBusArgument arg = qvariant_cast<QDBusArgument>(u);
        arg.beginArray();
        while (!arg.atEnd()) {
            QVariantMap m;
            arg >> m;
            out.append(m);
        }
        arg.endArray();
        return out;
    }
    for (const QVariant &e : u.toList())
        out.append(e.toMap());
    return out;
}

// "connected", "connecting", "disconnected" or "unavailable" from NM_DEVICE_STATE (10 unmanaged, 20 unavailable, 30
// disconnected, 40-90 on the way, 100 activated, 110 deactivating, 120 failed).
QString deviceState(uint state)
{
    if (state == kDeviceStateActivated)
        return QStringLiteral("connected"); // i18n-ignore: a state the page reads, not shown
    if (state >= 40 && state < 100)
        return QStringLiteral("connecting"); // i18n-ignore: a state the page reads, not shown
    if (state <= 20)
        return QStringLiteral("unavailable"); // i18n-ignore: a state the page reads, not shown
    return QStringLiteral("disconnected"); // i18n-ignore: a state the page reads, not shown
}

// An IP4Config or IP6Config object: its addresses ("a/n"), its gateway and (IPv4) its name servers.
void addIpConfig(BusCaller &bus, const QString &path, bool v6, QJsonObject *out)
{
    if (path.isEmpty() || path == QLatin1String("/"))
        return;
    const Props p = allProperties(bus, kNmService, path, v6 ? kNmIp6 : kNmIp4);
    if (!p.ok)
        return;
    QStringList addresses;
    for (const QVariantMap &a : mapList(p.map.value(QStringLiteral("AddressData")))) {
        const QString address = clean(a.value(QStringLiteral("address")));
        if (!address.isEmpty())
            addresses << address + QLatin1Char('/') + QString::number(unwrap(a.value(QStringLiteral("prefix"))).toUInt());
    }
    out->insert(v6 ? QStringLiteral("ip6") : QStringLiteral("ip4"), jsonStrings(addresses));
    out->insert(v6 ? QStringLiteral("router6") : QStringLiteral("router"), clean(p.map.value(QStringLiteral("Gateway")))); // i18n-ignore: JSON keys of net.state
    if (!v6) {
        QStringList dns;
        for (const QVariantMap &n : mapList(p.map.value(QStringLiteral("NameserverData")))) {
            const QString address = clean(n.value(QStringLiteral("address")));
            if (!address.isEmpty())
                dns << address;
        }
        out->insert(QStringLiteral("dns"), jsonStrings(dns));
    }
}

QString connectionState(uint state)
{
    // NM_ACTIVE_CONNECTION_STATE: 1 activating, 2 activated, 3 deactivating, 4 deactivated.
    return state == 2 ? QStringLiteral("connected") : state == 1 ? QStringLiteral("connecting") : QStringLiteral("disconnected"); // i18n-ignore: states the page reads, not shown
}

// A saved profile of any type: its object path, uuid, name and type.
struct AnyProfile {
    QString path, uuid, id, type;
};

QList<AnyProfile> allProfiles(BusCaller &bus)
{
    QList<AnyProfile> out;
    for (const QDBusObjectPath &p : paths(bus.call(kNmService, kNmSettingsPath, kNmSettings, QStringLiteral("ListConnections"), {}, kReadMs))) {
        const BusReply r = bus.call(kNmService, p.path(), kNmConnection, QStringLiteral("GetSettings"), {}, kReadMs);
        if (!r.ok || r.args.isEmpty())
            continue;
        const QVariantMap c = cast<ConnectionSettings>(r.args.first()).value(QStringLiteral("connection"));
        out.append({p.path(), c.value(QStringLiteral("uuid")).toString(), clean(c.value(QStringLiteral("id"))), c.value(QStringLiteral("type")).toString()});
    }
    return out;
}

// The active connections: uuid -> {object path, NM_ACTIVE_CONNECTION_STATE}.
QMap<QString, QPair<QString, uint>> activeConnections(BusCaller &bus)
{
    QMap<QString, QPair<QString, uint>> out;
    const Result active = property(bus, kNmService, kNmPath, kNmIface, QStringLiteral("ActiveConnections"));
    if (!active.ok)
        return out;
    for (const QDBusObjectPath &p : cast<QList<QDBusObjectPath>>(active.value)) {
        const Props a = allProperties(bus, kNmService, p.path(), kNmActive);
        if (a.ok)
            out.insert(a.map.value(QStringLiteral("Uuid")).toString().toLower(), {p.path(), a.map.value(QStringLiteral("State")).toUInt()});
    }
    return out;
}
} // namespace

namespace {
// The firewall: ufw (Omarchy's) or firewalld, whichever systemd has loaded, and whether its unit is active. systemd serves a
// unit's object at its escaped name even before it is loaded; a unit that is not installed reads LoadState "not-found".
QJsonObject firewallState(BusCaller &bus)
{
    static const QList<QPair<QString, QString>> units{{QStringLiteral("ufw"), QStringLiteral("/org/freedesktop/systemd1/unit/ufw_2eservice")},
                                                      {QStringLiteral("firewalld"), QStringLiteral("/org/freedesktop/systemd1/unit/firewalld_2eservice")}};
    for (const auto &unit : units) {
        const Props p = allProperties(bus, kSystemd, unit.second, kSystemdUnit);
        if (p.ok && p.map.value(QStringLiteral("LoadState")).toString() == QLatin1String("loaded")) // i18n-ignore: a systemd state
            return {{QStringLiteral("name"), unit.first}, {QStringLiteral("active"), p.map.value(QStringLiteral("ActiveState")).toString() == QLatin1String("active")}}; // i18n-ignore: a systemd state
    }
    return {{QStringLiteral("name"), QString()}, {QStringLiteral("active"), false}};
}
} // namespace

StateResult networkState(BusCaller &bus)
{
    StateResult r;
    const BusReply list = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("GetDevices"), {}, kReadMs);
    if (!list.ok) {
        r.error = reasonOf(list.error);
        return r;
    }
    QJsonArray devices;
    for (const QDBusObjectPath &p : paths(list)) {
        const Props d = allProperties(bus, kNmService, p.path(), kNmDevice);
        const uint type = d.map.value(QStringLiteral("DeviceType")).toUInt();
        if (!d.ok || (type != kDeviceTypeEthernet && type != kDeviceTypeWifi))
            continue;
        const uint state = d.map.value(QStringLiteral("State")).toUInt();
        QJsonObject dev{{QStringLiteral("name"), clean(d.map.value(QStringLiteral("Interface")))},
                        {QStringLiteral("type"), type == kDeviceTypeWifi ? QStringLiteral("wifi") : QStringLiteral("ethernet")}, // i18n-ignore: device types the page reads
                        {QStringLiteral("state"), deviceState(state)},
                        {QStringLiteral("mac"), clean(d.map.value(QStringLiteral("HwAddress")))}};
        const QString activePath = cast<QDBusObjectPath>(d.map.value(QStringLiteral("ActiveConnection"))).path();
        if (!activePath.isEmpty() && activePath != QLatin1String("/")) {
            const Props a = allProperties(bus, kNmService, activePath, kNmActive);
            if (a.ok) {
                dev.insert(QStringLiteral("connection"), clean(a.map.value(QStringLiteral("Id"))));
                dev.insert(QStringLiteral("uuid"), clean(a.map.value(QStringLiteral("Uuid"))));
            }
        }
        if (type == kDeviceTypeEthernet) {
            const Result speed = property(bus, kNmService, p.path(), kNmWired, QStringLiteral("Speed"));
            dev.insert(QStringLiteral("speed"), static_cast<qint64>(speed.ok ? speed.value.toUInt() : 0));
        }
        if (state == kDeviceStateActivated) {
            addIpConfig(bus, cast<QDBusObjectPath>(d.map.value(QStringLiteral("Ip4Config"))).path(), false, &dev);
            addIpConfig(bus, cast<QDBusObjectPath>(d.map.value(QStringLiteral("Ip6Config"))).path(), true, &dev);
            if (type == kDeviceTypeWifi) {
                const Props w = allProperties(bus, kNmService, p.path(), kNmWireless);
                if (w.ok) {
                    dev.insert(QStringLiteral("bitrate"), static_cast<qint64>(w.map.value(QStringLiteral("Bitrate")).toUInt()));
                    const QString ap = cast<QDBusObjectPath>(w.map.value(QStringLiteral("ActiveAccessPoint"))).path();
                    const Props a = ap.isEmpty() || ap == QLatin1String("/") ? Props() : allProperties(bus, kNmService, ap, kNmAp);
                    if (a.ok) {
                        dev.insert(QStringLiteral("frequency"), static_cast<qint64>(a.map.value(QStringLiteral("Frequency")).toUInt()));
                        dev.insert(QStringLiteral("ssid"), upperHex(cast<QByteArray>(a.map.value(QStringLiteral("Ssid")))));
                    }
                }
            }
        }
        devices.append(dev);
    }
    QJsonArray vpns;
    const QMap<QString, QPair<QString, uint>> active = activeConnections(bus);
    for (const AnyProfile &p : allProfiles(bus)) {
        if (p.type != QLatin1String("vpn") && p.type != QLatin1String("wireguard"))
            continue;
        const auto a = active.constFind(p.uuid.toLower());
        vpns.append(QJsonObject{{QStringLiteral("uuid"), p.uuid}, {QStringLiteral("name"), p.id},
                                {QStringLiteral("kind"), p.type}, {QStringLiteral("state"), a == active.cend() ? QStringLiteral("disconnected") : connectionState(a->second)}}); // i18n-ignore: a state the page reads
    }
    r.json = QJsonObject{{QStringLiteral("devices"), devices}, {QStringLiteral("vpns"), vpns}, {QStringLiteral("firewall"), firewallState(bus)}};
    r.ok = true;
    return r;
}

namespace {
constexpr uint kUPowerTypeBattery = 2;

// The laptop battery among UPower's devices (a battery that powers the computer), "" when there is none.
QString upowerBattery(BusCaller &bus, QString *error)
{
    const BusReply r = bus.call(kUPower, kUPowerPath, kUPower, QStringLiteral("EnumerateDevices"), {}, kReadMs);
    if (!r.ok) {
        *error = r.error;
        return {};
    }
    for (const QDBusObjectPath &p : paths(r)) {
        const Props d = allProperties(bus, kUPower, p.path(), kUPowerDevice);
        if (d.ok && d.map.value(QStringLiteral("Type")).toUInt() == kUPowerTypeBattery && d.map.value(QStringLiteral("PowerSupply")).toBool())
            return p.path();
    }
    return {};
}

// GetHistory("charge", timespan, resolution): [[time (s since the epoch), percent, state]], oldest first; [] when UPower keeps
// none.
QJsonArray chargeHistory(BusCaller &bus, const QString &battery, uint timespan, uint resolution)
{
    QJsonArray out;
    const BusReply r = bus.call(kUPower, battery, kUPowerDevice, QStringLiteral("GetHistory"), {QStringLiteral("charge"), timespan, resolution}, kReadMs);
    if (!r.ok || r.args.isEmpty())
        return out;
    const QVariant v = unwrap(r.args.first());
    if (v.metaType() == QMetaType::fromType<QDBusArgument>()) {
        const QDBusArgument arg = qvariant_cast<QDBusArgument>(v);
        arg.beginArray();
        while (!arg.atEnd()) {
            uint time = 0, state = 0;
            double value = 0;
            arg.beginStructure();
            arg >> time >> value >> state;
            arg.endStructure();
            out.append(QJsonArray{static_cast<qint64>(time), value, static_cast<qint64>(state)});
        }
        arg.endArray();
        return out;
    }
    for (const QVariant &e : v.toList()) { // canned: a list of [time, value, state]
        const QVariantList t = e.toList();
        if (t.size() == 3)
            out.append(QJsonArray{t.at(0).toLongLong(), t.at(1).toDouble(), t.at(2).toLongLong()});
    }
    return out;
}
} // namespace

StateResult powerState(BusCaller &bus)
{
    StateResult r;
    const Result onBattery = property(bus, kUPower, kUPowerPath, kUPower, QStringLiteral("OnBattery"));
    if (!onBattery.ok) {
        r.error = reasonOf(onBattery.error);
        return r;
    }
    QString error;
    const QString battery = upowerBattery(bus, &error);
    QJsonObject out{{QStringLiteral("present"), false}, {QStringLiteral("onBattery"), onBattery.value.toBool()}};
    if (!battery.isEmpty()) {
        const Props display = allProperties(bus, kUPower, kUPowerDisplay, kUPowerDevice);
        const Props b = allProperties(bus, kUPower, battery, kUPowerDevice);
        const QVariantMap &d = display.ok ? display.map : b.map;
        out.insert(QStringLiteral("present"), b.ok && b.map.value(QStringLiteral("IsPresent")).toBool());
        out.insert(QStringLiteral("percent"), d.value(QStringLiteral("Percentage")).toDouble());
        out.insert(QStringLiteral("state"), static_cast<qint64>(d.value(QStringLiteral("State")).toUInt()));
        out.insert(QStringLiteral("timeToEmpty"), d.value(QStringLiteral("TimeToEmpty")).toLongLong());
        out.insert(QStringLiteral("timeToFull"), d.value(QStringLiteral("TimeToFull")).toLongLong());
        out.insert(QStringLiteral("capacity"), b.map.value(QStringLiteral("Capacity")).toDouble());
        out.insert(QStringLiteral("cycles"), b.map.contains(QStringLiteral("ChargeCycles")) ? b.map.value(QStringLiteral("ChargeCycles")).toInt() : -1);
        out.insert(QStringLiteral("limitSupported"), b.map.value(QStringLiteral("ChargeThresholdSupported")).toBool());
        out.insert(QStringLiteral("limitEnabled"), b.map.value(QStringLiteral("ChargeThresholdEnabled")).toBool());
        out.insert(QStringLiteral("limitEnd"), static_cast<qint64>(b.map.value(QStringLiteral("ChargeEndThreshold")).toUInt()));
        if (b.map.value(QStringLiteral("HasHistory")).toBool()) {
            out.insert(QStringLiteral("history24"), chargeHistory(bus, battery, 24 * 3600, 96));
            out.insert(QStringLiteral("history10"), chargeHistory(bus, battery, 10 * 24 * 3600, 240));
        }
    }
    r.json = out;
    r.ok = true;
    return r;
}

StateResult bluetoothState(BusCaller &bus)
{
    StateResult r;
    QString error;
    const ManagedObjects objects = bluezObjects(bus, &error);
    if (!error.isEmpty()) {
        r.error = reasonOf(error);
        return r;
    }
    const QString adapter = firstAdapterPath(objects);
    QJsonObject out{{QStringLiteral("present"), !adapter.isEmpty()}, {QStringLiteral("powered"), false}};
    QJsonArray devices;
    QJsonArray nearby;
    if (!adapter.isEmpty()) {
        const QVariantMap a = objects.value(QDBusObjectPath(adapter)).value(kAdapter);
        out.insert(QStringLiteral("powered"), a.value(QStringLiteral("Powered")).toBool());
        out.insert(QStringLiteral("discovering"), a.value(QStringLiteral("Discovering")).toBool());
        out.insert(QStringLiteral("discoverable"), a.value(QStringLiteral("Discoverable")).toBool());
        out.insert(QStringLiteral("alias"), clean(a.value(QStringLiteral("Alias"))));
        for (auto it = objects.cbegin(); it != objects.cend(); ++it) {
            const QVariantMap d = it.value().value(kDevice1);
            if (d.isEmpty())
                continue;
            const QString mac = d.value(QStringLiteral("Address")).toString().toUpper();
            if (!isMac(mac))
                continue;
            // BlueZ's Alias is the Name when the device gave one, else the address with '-' for ':' (no name to show).
            QString name = clean(d.value(QStringLiteral("Alias"))).trimmed();
            if (name.isEmpty() || name.compare(QString(mac).replace(QLatin1Char(':'), QLatin1Char('-')), Qt::CaseInsensitive) == 0)
                name = clean(d.value(QStringLiteral("Name"))).trimmed();
            const QString icon = clean(d.value(QStringLiteral("Icon")));
            if (d.value(QStringLiteral("Paired")).toBool()) {
                const QVariantMap battery = it.value().value(kBattery1);
                devices.append(QJsonObject{{QStringLiteral("mac"), mac},
                                           {QStringLiteral("name"), name.isEmpty() ? mac : name},
                                           {QStringLiteral("connected"), d.value(QStringLiteral("Connected")).toBool()},
                                           {QStringLiteral("icon"), icon},
                                           {QStringLiteral("battery"), battery.contains(QStringLiteral("Percentage")) ? static_cast<int>(battery.value(QStringLiteral("Percentage")).toUInt()) : -1}});
            } else if (!name.isEmpty() && d.contains(QStringLiteral("RSSI"))) {
                // Nearby: seen by this discovery (BlueZ keeps RSSI only for devices in range) and with a name to show.
                nearby.append(QJsonObject{{QStringLiteral("mac"), mac}, {QStringLiteral("name"), name}, {QStringLiteral("icon"), icon},
                                          {QStringLiteral("rssi"), d.value(QStringLiteral("RSSI")).toInt()}});
            }
        }
    }
    out.insert(QStringLiteral("devices"), devices);
    out.insert(QStringLiteral("nearby"), nearby);
    r.ok = true;
    r.json = out;
    return r;
}

StateResult hostState(BusCaller &bus)
{
    StateResult r;
    const Props p = allProperties(bus, kHostService, kHostPath, kHostService);
    if (!p.ok) {
        r.error = reasonOf(p.error);
        return r;
    }
    r.json = QJsonObject{{QStringLiteral("pretty"), clean(p.map.value(QStringLiteral("PrettyHostname")))},
                         {QStringLiteral("static"), clean(p.map.value(QStringLiteral("StaticHostname")))},
                         {QStringLiteral("hostname"), clean(p.map.value(QStringLiteral("Hostname")))},
                         {QStringLiteral("chassis"), clean(p.map.value(QStringLiteral("Chassis")))},
                         {QStringLiteral("vendor"), clean(p.map.value(QStringLiteral("HardwareVendor")))},
                         {QStringLiteral("model"), clean(p.map.value(QStringLiteral("HardwareModel")))}};
    r.ok = true;
    return r;
}

StateResult timeState(BusCaller &bus)
{
    StateResult r;
    const Props p = allProperties(bus, kTimeService, kTimePath, kTimeService);
    if (!p.ok) {
        r.error = reasonOf(p.error);
        return r;
    }
    QJsonObject out{{QStringLiteral("zone"), clean(p.map.value(QStringLiteral("Timezone")))},
                    {QStringLiteral("ntp"), unwrap(p.map.value(QStringLiteral("NTP"))).toBool()},
                    {QStringLiteral("canNtp"), unwrap(p.map.value(QStringLiteral("CanNTP"))).toBool()},
                    {QStringLiteral("synced"), unwrap(p.map.value(QStringLiteral("NTPSynchronized"))).toBool()},
                    {QStringLiteral("localRtc"), unwrap(p.map.value(QStringLiteral("LocalRTC"))).toBool()},
                    {QStringLiteral("usec"), QString::number(unwrap(p.map.value(QStringLiteral("TimeUSec"))).toULongLong())}};
    // The time servers, when timesyncd runs (its absence is no error: the source then reads as unknown).
    const Props sync = allProperties(bus, kSyncService, kSyncPath, kSyncManager);
    QStringList servers;
    if (sync.ok) {
        for (const char *key : {"LinkNTPServers", "SystemNTPServers", "FallbackNTPServers"}) {
            for (const QString &server : strings(sync.map.value(QLatin1String(key)))) {
                if (!server.isEmpty() && !servers.contains(server))
                    servers << server;
            }
        }
    }
    out.insert(QStringLiteral("server"), sync.ok ? clean(sync.map.value(QStringLiteral("ServerName"))) : QString());
    out.insert(QStringLiteral("servers"), jsonStrings(servers));
    r.json = out;
    r.ok = true;
    return r;
}

StateResult timeZones(BusCaller &bus)
{
    StateResult r;
    const BusReply reply = bus.call(kTimeService, kTimePath, kTimeService, QStringLiteral("ListTimezones"), {}, kReadMs);
    if (!reply.ok || reply.args.isEmpty()) {
        r.error = reasonOf(reply.ok ? QCoreApplication::translate("SystemBus", "empty reply") : reply.error);
        return r;
    }
    QStringList zones;
    for (const QString &z : strings(reply.args.first())) {
        if (isZone(z))
            zones << z;
    }
    r.json = QJsonObject{{QStringLiteral("zones"), jsonStrings(zones)}};
    r.ok = true;
    return r;
}

StateResult localeState(BusCaller &bus)
{
    StateResult r;
    const Result locale = property(bus, kLocaleService, kLocalePath, kLocaleService, QStringLiteral("Locale"));
    if (!locale.ok) {
        r.error = reasonOf(locale.error);
        return r;
    }
    r.json = QJsonObject{{QStringLiteral("locale"), jsonStrings(strings(locale.value))}};
    r.ok = true;
    return r;
}

StateResult userUnits(BusCaller &bus, const QStringList &ownDirs)
{
    StateResult r;
    const BusReply reply = bus.call(kSystemd, kSystemdPath, kSystemdManager, QStringLiteral("ListUnitFilesByPatterns"),
                                    {QStringList{QStringLiteral("enabled"), QStringLiteral("disabled")}, QStringList{QStringLiteral("*.service")}}, kReadMs);
    if (!reply.ok || reply.args.isEmpty()) {
        r.error = reasonOf(reply.ok ? QCoreApplication::translate("SystemBus", "empty reply") : reply.error);
        return r;
    }
    QJsonArray units;
    for (const auto &[path, state] : unitFiles(reply.args.first())) {
        bool own = false;
        for (const QString &dir : ownDirs)
            own = own || (!dir.isEmpty() && path.startsWith(dir + QLatin1Char('/')) && !path.mid(dir.size() + 1).contains(QLatin1Char('/')));
        const QString unit = path.section(QLatin1Char('/'), -1);
        if (own && isUserUnit(unit))
            units.append(QJsonObject{{QStringLiteral("unit"), unit}, {QStringLiteral("path"), path}, {QStringLiteral("state"), state}});
    }
    r.json = QJsonObject{{QStringLiteral("units"), units}};
    r.ok = true;
    return r;
}

namespace {
// A missing table or entry: the store has nothing for it yet.
bool notFound(const BusReply &r)
{
    return !r.ok && r.error.startsWith(QLatin1String("org.freedesktop.portal.Error.NotFound"));
}

// Whether a stored value allows: location keeps [accuracy, timestamp] and an accuracy other than NONE allows (an unknown one
// counts as NONE, as the portal reads it); the others allow only on "yes" ("ask" asks every time: not allowed here).
bool privacyAllowed(const QString &category, const QStringList &value)
{
    if (category == QLatin1String("location")) {
        static const QStringList allowing{QStringLiteral("COUNTRY"), QStringLiteral("CITY"), QStringLiteral("NEIGHBORHOOD"), QStringLiteral("STREET"),
                                          QStringLiteral("EXACT")};
        return value.size() >= 2 && allowing.contains(value.first());
    }
    return value == QStringList{QStringLiteral("yes")};
}
} // namespace

StateResult privacyState(BusCaller &bus)
{
    StateResult r;
    QJsonObject json;
    for (const PrivacyGrant &g : privacyGrants()) {
        const BusReply reply = bus.call(kPermStore, kPermStorePath, kPermStore, QStringLiteral("Lookup"), {g.table, g.id}, kReadMs);
        if (!reply.ok && !notFound(reply)) {
            r.error = reasonOf(reply.error);
            return r;
        }
        QJsonArray apps;
        const PermissionTable table = reply.ok ? cast<PermissionTable>(reply.args.value(0)) : PermissionTable{};
        for (auto it = table.cbegin(); it != table.cend(); ++it) {
            if (isPortalAppId(it.key()))
                apps.append(QJsonObject{{QStringLiteral("app"), it.key()}, {QStringLiteral("allowed"), privacyAllowed(g.category, it.value())}});
        }
        json.insert(g.category, apps);
    }
    for (const auto &[key, tableName] : privacySelections()) {
        QJsonArray saved;
        const BusReply list = bus.call(kPermStore, kPermStorePath, kPermStore, QStringLiteral("List"), {tableName}, kReadMs);
        if (!list.ok && !notFound(list)) {
            r.error = reasonOf(list.error);
            return r;
        }
        QStringList tokens = list.ok ? cast<QStringList>(list.args.value(0)) : QStringList{};
        tokens.removeIf([](const QString &t) { return !isPortalToken(t); });
        for (const QString &token : tokens.mid(0, kMaxSavedSelections)) {
            const BusReply entry = bus.call(kPermStore, kPermStorePath, kPermStore, QStringLiteral("Lookup"), {tableName, token}, kReadMs);
            if (!entry.ok)
                continue;
            const PermissionTable apps = cast<PermissionTable>(entry.args.value(0));
            for (auto it = apps.cbegin(); it != apps.cend(); ++it) {
                // A host app the portal could not name keeps its grant under "" (xdg-desktop-portal 1.22, xdp-app-info-host.c:
                // no app-*.scope with a desktop entry), and a lasting one must stay removable (privacy.forget goes by token):
                // listed under "", as is a key no portal writes, whose raw text is never passed on.
                saved.append(QJsonObject{{QStringLiteral("app"), isPortalAppId(it.key()) ? it.key() : QString()}, {QStringLiteral("token"), token}});
            }
        }
        json.insert(key, saved);
    }
    // Whether the portals for the background and remote desktop exist: true, false (the portal answers that it has no such
    // interface), or left out when it is not known (the portal not running, no answer: the second is then not asked).
    QJsonObject portals;
    const BusReply owned = bus.call(kDBusName, kDBusPath, kDBusName, QStringLiteral("NameHasOwner"), {kPortal}, kPortalReadMs);
    const bool running = owned.ok && !owned.args.isEmpty() && owned.args.first().toBool();
    for (const auto &[key, iface] : running ? privacyPortals() : QList<QPair<QString, QString>>{}) {
        const BusReply v = bus.call(kPortal, kPortalPath, kProps, QStringLiteral("Get"), {iface, QStringLiteral("version")}, kPortalReadMs);
        if (v.ok) {
            portals.insert(key, true);
        } else if (v.error.contains(QLatin1String("InvalidArgs")) || v.error.contains(QLatin1String("UnknownInterface"))
                   || v.error.contains(QLatin1String("UnknownProperty")) || v.error.contains(QLatin1String("UnknownObject"))) {
            portals.insert(key, false);
        } else {
            break;
        }
    }
    json.insert(QStringLiteral("portals"), portals);
    r.json = json;
    r.ok = true;
    return r;
}

QString hostNameFor(const QString &name)
{
    QString out;
    for (const QChar c : name.toLower()) {
        if ((c >= QLatin1Char('a') && c <= QLatin1Char('z')) || (c >= QLatin1Char('0') && c <= QLatin1Char('9')))
            out += c;
        else if (!out.isEmpty() && !out.endsWith(QLatin1Char('-')))
            out += QLatin1Char('-');
    }
    while (out.endsWith(QLatin1Char('-')))
        out.chop(1);
    out = out.left(63);
    while (out.endsWith(QLatin1Char('-')))
        out.chop(1);
    return out;
}

StateResult sharingState(BusCaller &bus)
{
    StateResult r;
    // Read from the disk at each call (systemd does not cache it): the state right after an EnableUnitFiles, without a Reload.
    const BusReply files = bus.call(kSystemd, kSystemdPath, kSystemdManager, QStringLiteral("ListUnitFilesByPatterns"),
                                    {QStringList(), QStringList{kSshdUnit}}, kReadMs);
    if (!files.ok || files.args.isEmpty()) {
        r.error = reasonOf(files.ok ? QCoreApplication::translate("SystemBus", "empty reply") : files.error);
        return r;
    }
    QString state;
    for (const auto &[path, fileState] : unitFiles(files.args.first())) {
        if (path.section(QLatin1Char('/'), -1) == kSshdUnit)
            state = clean(fileState);
    }
    const Props unit = state.isEmpty() ? Props() : allProperties(bus, kSystemd, kSshdPath, kSystemdUnit);
    r.json = QJsonObject{{QStringLiteral("installed"), !state.isEmpty()},
                         {QStringLiteral("unitFileState"), state},
                         {QStringLiteral("active"), unit.ok && unit.map.value(QStringLiteral("ActiveState")).toString() == QLatin1String("active")}}; // i18n-ignore: a systemd state
    r.ok = true;
    return r;
}

StateResult diskState(BusCaller &bus)
{
    StateResult r;
    QString error;
    QString device;
    const QString luks = rootLuksDevice(bus, &error, &device);
    if (!error.isEmpty()) {
        r.error = reasonOf(error);
        return r;
    }
    r.json = QJsonObject{{QStringLiteral("encrypted"), !luks.isEmpty()}, {QStringLiteral("device"), device}};
    r.ok = true;
    return r;
}

bool isFingerName(const QString &s)
{
    static const QStringList names{QStringLiteral("left-thumb"),         QStringLiteral("left-index-finger"),  QStringLiteral("left-middle-finger"),
                                   QStringLiteral("left-ring-finger"),   QStringLiteral("left-little-finger"), QStringLiteral("right-thumb"),
                                   QStringLiteral("right-index-finger"), QStringLiteral("right-middle-finger"), QStringLiteral("right-ring-finger"),
                                   QStringLiteral("right-little-finger")};
    return names.contains(s);
}

StateResult fingerprintState(BusCaller &bus)
{
    StateResult r;
    const BusReply device = bus.call(kFprint, kFprintManagerPath, kFprintManager, QStringLiteral("GetDefaultDevice"), {}, kReadMs);
    if (!device.ok && device.error.startsWith(QLatin1String("net.reactivated.Fprint.Error.NoSuchDevice"))) {
        r.json = QJsonObject{{QStringLiteral("present"), false}, {QStringLiteral("fingers"), QJsonArray()}};
        r.ok = true;
        return r;
    }
    if (!device.ok || device.args.isEmpty()) {
        r.error = reasonOf(device.ok ? QCoreApplication::translate("SystemBus", "empty reply") : device.error);
        return r;
    }
    const QString path = cast<QDBusObjectPath>(device.args.first()).path();
    const Props p = allProperties(bus, kFprint, path, kFprintDevice);
    const BusReply enrolled = bus.call(kFprint, path, kFprintDevice, QStringLiteral("ListEnrolledFingers"), {QString()}, kReadMs);
    QJsonArray fingers;
    if (enrolled.ok && !enrolled.args.isEmpty()) {
        for (const QString &f : cast<QStringList>(enrolled.args.first())) {
            if (isFingerName(f) && !fingers.contains(f))
                fingers.append(f);
        }
    } else if (!enrolled.ok && !enrolled.error.startsWith(QLatin1String("net.reactivated.Fprint.Error.NoEnrolledPrints"))) {
        r.error = reasonOf(enrolled.error);
        return r;
    }
    r.json = QJsonObject{{QStringLiteral("present"), true},
                         {QStringLiteral("name"), clean(p.map.value(QStringLiteral("name")))},
                         {QStringLiteral("stages"), p.map.value(QStringLiteral("num-enroll-stages")).toInt()},
                         {QStringLiteral("scanType"), clean(p.map.value(QStringLiteral("scan-type")))},
                         {QStringLiteral("fingers"), fingers}};
    r.ok = true;
    return r;
}

QString enrollFinger(BusCaller &bus, const QString &finger, const std::function<void(const QString &)> &progress, const std::function<bool()> &stopped,
                     int idleMs, int totalMs)
{
    if (!isFingerName(finger))
        return QCoreApplication::translate("SystemBus", "invalid request");
    const BusReply device = bus.call(kFprint, kFprintManagerPath, kFprintManager, QStringLiteral("GetDefaultDevice"), {}, kReadMs);
    if (!device.ok || device.args.isEmpty())
        return device.ok ? QCoreApplication::translate("SystemBus", "empty reply") : fail(device.error);
    const QString path = cast<QDBusObjectPath>(device.args.first()).path();
    // Listening first: the first status may come right after EnrollStart answers.
    if (!bus.listen(kFprint, path, kFprintDevice, QStringLiteral("EnrollStatus")))
        return QCoreApplication::translate("SystemBus", "the fingerprint reader cannot be followed");
    const BusReply claim = bus.call(kFprint, path, kFprintDevice, QStringLiteral("Claim"), {QString()}, kPrivilegedMs);
    if (!claim.ok)
        return fail(claim.error);
    QString result;
    const BusReply start = bus.call(kFprint, path, kFprintDevice, QStringLiteral("EnrollStart"), {finger}, kPrivilegedMs);
    if (!start.ok) {
        result = fail(start.error);
    } else {
        QElapsedTimer idle;
        idle.start();
        QElapsedTimer total;
        total.start();
        while (true) {
            if (stopped && stopped()) {
                result = QStringLiteral("enroll-stopped"); // i18n-ignore: a status code the page words (Fingerprint.js)
                break;
            }
            if (idle.elapsed() > idleMs || total.elapsed() > totalMs) {
                result = QCoreApplication::translate("SystemBus", "timed out");
                break;
            }
            const BusReply s = bus.nextSignal(kEnrollSliceMs);
            if (!s.ok || s.args.size() < 2)
                continue;
            // EnrollStatus(s result, b done): fprintd's own status names, passed on as they are (the page words them).
            const QString status = clean(s.args.at(0)).left(64);
            const bool done = s.args.at(1).toBool();
            if (progress)
                progress(status);
            idle.restart();
            if (done) {
                result = status == QLatin1String("enroll-completed") ? QString() : status;
                break;
            }
        }
        // fprintd wants EnrollStop after the last status too; its own failure changes nothing for the person.
        bus.call(kFprint, path, kFprintDevice, QStringLiteral("EnrollStop"), {}, kActMs);
    }
    bus.call(kFprint, path, kFprintDevice, QStringLiteral("Release"), {}, kActMs);
    return result;
}

bool sessionAction(const QVariantMap &op)
{
    const QString name = op.value(QStringLiteral("op")).toString();
    return name.startsWith(QLatin1String("user.")) || name.startsWith(QLatin1String("privacy."));
}

bool privilegedAction(const QVariantMap &op)
{
    const QString name = op.value(QStringLiteral("op")).toString();
    return name.startsWith(QLatin1String("host.")) || name.startsWith(QLatin1String("time.")) || name == QLatin1String("wifi.forget")
        || name == QLatin1String("wifi.connectOpen") || name == QLatin1String("wifi.connectSecure") || name == QLatin1String("bt.pair")
        || name == QLatin1String("power.chargeLimit") || name.startsWith(QLatin1String("printer.")) || name == QLatin1String("ssh.enable")
        || name == QLatin1String("disk.passphrase") || name.startsWith(QLatin1String("fprint."));
}

bool validAction(const QVariantMap &op)
{
    const QString name = op.value(QStringLiteral("op")).toString();
    if (name == QLatin1String("host.setName"))
        return op.value(QStringLiteral("name")).metaType() == QMetaType::fromType<QString>() && isComputerName(op.value(QStringLiteral("name")).toString());
    if (name == QLatin1String("time.ntp"))
        return isBool(op.value(QStringLiteral("on")));
    if (name == QLatin1String("time.zone"))
        return op.value(QStringLiteral("zone")).metaType() == QMetaType::fromType<QString>() && isZone(op.value(QStringLiteral("zone")).toString());
    if (name == QLatin1String("time.set"))
        return isUsec(op.value(QStringLiteral("usec")), nullptr);
    if (name == QLatin1String("user.enable"))
        return isUserUnit(op.value(QStringLiteral("unit")).toString()) && isBool(op.value(QStringLiteral("on")));
    if (name == QLatin1String("wifi.radio") || name == QLatin1String("bt.power"))
        return isBool(op.value(QStringLiteral("on")));
    if (name == QLatin1String("wifi.connectKnown"))
        return isUuid(op.value(QStringLiteral("uuid")).toString());
    if (name == QLatin1String("wifi.connectOpen"))
        return isSsidHex(op.value(QStringLiteral("hex")).toString());
    if (name == QLatin1String("wifi.disconnect") || name == QLatin1String("wifi.scan"))
        return true;
    if (name == QLatin1String("wifi.connectSecure"))
        return isSsidHex(op.value(QStringLiteral("hex")).toString()) && isPassphrase(op.value(QStringLiteral("psk")));
    if (name == QLatin1String("wifi.forget"))
        return isUuid(op.value(QStringLiteral("uuid")).toString());
    if (name == QLatin1String("vpn.connect"))
        return isUuid(op.value(QStringLiteral("uuid")).toString()) && isBool(op.value(QStringLiteral("on")));
    if (name == QLatin1String("bt.connect"))
        return isMac(op.value(QStringLiteral("mac")).toString()) && isBool(op.value(QStringLiteral("connect")));
    if (name == QLatin1String("bt.discover") || name == QLatin1String("power.chargeLimit"))
        return isBool(op.value(QStringLiteral("on")));
    if (name == QLatin1String("bt.pair") || name == QLatin1String("bt.forget"))
        return isMac(op.value(QStringLiteral("mac")).toString());
    if (name == QLatin1String("printer.add"))
        return isPrinterName(op.value(QStringLiteral("name")).toString()) && isPrinterUri(op.value(QStringLiteral("uri")).toString())
            && isPrinterInfo(op.value(QStringLiteral("info")));
    if (name == QLatin1String("printer.delete") || name == QLatin1String("printer.resume"))
        return isPrinterName(op.value(QStringLiteral("name")).toString());
    if (name == QLatin1String("privacy.allow")) {
        const QString category = op.value(QStringLiteral("category")).toString();
        const bool known = std::any_of(privacyGrants().cbegin(), privacyGrants().cend(), [&](const PrivacyGrant &g) { return g.category == category; });
        return known && op.value(QStringLiteral("app")).metaType() == QMetaType::fromType<QString>() && isPortalAppId(op.value(QStringLiteral("app")).toString())
            && isBool(op.value(QStringLiteral("on")));
    }
    if (name == QLatin1String("privacy.forget")) {
        const QString kind = op.value(QStringLiteral("kind")).toString();
        const bool known = std::any_of(privacySelections().cbegin(), privacySelections().cend(), [&](const QPair<QString, QString> &t) { return t.first == kind; });
        return known && op.value(QStringLiteral("token")).metaType() == QMetaType::fromType<QString>() && isPortalToken(op.value(QStringLiteral("token")).toString());
    }
    // ADR-0045: the unit, the disk and the reader are never the page's to name; nothing else may ride along.
    if (name == QLatin1String("ssh.enable"))
        return isBool(op.value(QStringLiteral("on"))) && op.size() == 2;
    if (name == QLatin1String("disk.passphrase"))
        return isDiskPassphrase(op.value(QStringLiteral("old"))) && isDiskPassphrase(op.value(QStringLiteral("new"))) && op.size() == 3;
    if (name == QLatin1String("fprint.enroll") || name == QLatin1String("fprint.delete"))
        return op.value(QStringLiteral("finger")).metaType() == QMetaType::fromType<QString>() && isFingerName(op.value(QStringLiteral("finger")).toString())
            && op.size() == 2;
    return false;
}

namespace {
// One cups-pk-helper method: it asks polkit (with the dialog), then cupsd, and answers with CUPS's own message, "" when it worked.
QString cupsPk(BusCaller &bus, const QString &member, const QVariantList &args)
{
    const BusReply r = bus.call(kCupsPk, kCupsPkPath, kCupsPk, member, args, kPrivilegedMs);
    if (!r.ok)
        return fail(r.error);
    return clean(r.args.value(0)).left(kMaxReason);
}

constexpr uint kKeyMgmtPsk = 0x100;
constexpr uint kKeyMgmtSae = 0x400;
constexpr int kJoinPollMs = 250;

// Whether a call's error says the object is gone (NetworkManager removes an active connection once it went down).
bool objectGone(const QString &error)
{
    return error.startsWith(QLatin1String("org.freedesktop.DBus.Error.UnknownObject"))
        || error.startsWith(QLatin1String("org.freedesktop.DBus.Error.UnknownMethod"))
        || error.startsWith(QLatin1String("org.freedesktop.DBus.Error.UnknownInterface"));
}

// A join that failed (a wrong password: no agent gives NetworkManager another one) leaves no saved network behind, as nmcli
// does: its new profile, one of the whole system, is deleted (NetworkManager may ask polkit first), and a Delete that fails is said.
QString dropFailedJoin(BusCaller &bus, const QString &profile)
{
    const BusReply r = bus.call(kNmService, profile, kNmConnection, QStringLiteral("Delete"), {}, kPrivilegedMs);
    if (!r.ok)
        return QCoreApplication::translate("SystemBus", "the network could not be joined, and its new settings could not be removed: %1").arg(fail(r.error));
    return QCoreApplication::translate("SystemBus", "the network could not be joined");
}
} // namespace

QString awaitJoin(BusCaller &bus, const QString &profile, const QString &active, int deadlineMs, int pollMs)
{
    QElapsedTimer clock;
    clock.start();
    bool known = false;
    while (true) {
        const Result state = property(bus, kNmService, active, kNmActive, QStringLiteral("State"));
        if (state.ok) {
            known = true;
            const uint value = state.value.toUInt();
            if (value == 2)
                return QString();
            if (value >= 3)
                return dropFailedJoin(bus, profile);
        } else if (objectGone(state.error)) {
            return dropFailedJoin(bus, profile);
        }
        if (clock.elapsed() + pollMs > deadlineMs)
            break;
        QThread::msleep(static_cast<unsigned long>(pollMs));
    }
    if (known)
        return dropFailedJoin(bus, profile);
    return QCoreApplication::translate("SystemBus", "the network's state could not be read: it may still be joining");
}

namespace {

// Joins a WPA/WPA2/WPA3 personal network with its passphrase: the strongest access point of that SSID that takes one (PSK or
// SAE), with a new profile of the whole system (NetworkManager may ask polkit, ADR-0030). WPA3-only access points get
// key-mgmt sae, the others wpa-psk (which NetworkManager also uses for WPA2/WPA3 transition). An enterprise (802.1X), WEP or
// open network is not joined this way.
QString joinWithPassphrase(BusCaller &bus, const QString &devicePath, const QByteArray &ssid, const QString &psk)
{
    bool seen = false;
    bool found = false;
    AccessPoint ap;
    for (const AccessPoint &candidate : accessPoints(bus, devicePath)) {
        if (candidate.ssid != ssid)
            continue;
        seen = true;
        if (((candidate.wpa | candidate.rsn) & (kKeyMgmtPsk | kKeyMgmtSae)) != 0 && (!found || candidate.strength > ap.strength)) {
            ap = candidate;
            found = true;
        }
    }
    if (!found)
        return seen ? QCoreApplication::translate("SystemBus", "that network does not take a password") : QCoreApplication::translate("SystemBus", "that network is no longer in range");
    const bool saeOnly = ((ap.wpa | ap.rsn) & kKeyMgmtPsk) == 0;
    ConnectionSettings settings;
    settings.insert(QStringLiteral("connection"), QVariantMap{{QStringLiteral("id"), QString::fromUtf8(ssid)}, {QStringLiteral("type"), QStringLiteral("802-11-wireless")}});
    settings.insert(QStringLiteral("802-11-wireless"), QVariantMap{{QStringLiteral("ssid"), ssid}, {QStringLiteral("mode"), QStringLiteral("infrastructure")}});
    settings.insert(QStringLiteral("802-11-wireless-security"),
                    QVariantMap{{QStringLiteral("key-mgmt"), saeOnly ? QStringLiteral("sae") : QStringLiteral("wpa-psk")}, {QStringLiteral("psk"), psk}}); // i18n-ignore: NetworkManager key-mgmt values
    const BusReply r = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("AddAndActivateConnection"),
                                {QVariant::fromValue(settings), QVariant::fromValue(QDBusObjectPath(devicePath)), QVariant::fromValue(QDBusObjectPath(ap.path))}, kPrivilegedMs);
    if (!r.ok)
        return fail(r.error);
    if (r.args.size() < 2)
        return QString();
    return awaitJoin(bus, cast<QDBusObjectPath>(r.args.value(0)).path(), cast<QDBusObjectPath>(r.args.value(1)).path(), kActMs, kJoinPollMs);
}
} // namespace

QString runAction(BusCaller &bus, const QVariantMap &op, const QStringList &ownDirs, const QString &sshSetUpFile)
{
    if (!validAction(op))
        return QCoreApplication::translate("SystemBus", "invalid request");
    const QString name = op.value(QStringLiteral("op")).toString();

    // General (ADR-0030): the service asks the polkit agent (interactive = true) and answers once the user did.
    if (name == QLatin1String("host.setName")) {
        const QString pretty = op.value(QStringLiteral("name")).toString().trimmed();
        const QString error = privileged(bus, kHostService, kHostPath, QStringLiteral("SetPrettyHostname"), {pretty, true});
        if (!error.isEmpty())
            return error;
        const QString host = hostNameFor(pretty);
        return host.isEmpty() ? QString() : privileged(bus, kHostService, kHostPath, QStringLiteral("SetStaticHostname"), {host, true}); // i18n-ignore: a D-Bus method name
    }
    if (name == QLatin1String("time.ntp"))
        return privileged(bus, kTimeService, kTimePath, QStringLiteral("SetNTP"), {op.value(QStringLiteral("on")).toBool(), true});
    if (name == QLatin1String("time.zone"))
        return privileged(bus, kTimeService, kTimePath, QStringLiteral("SetTimezone"), {op.value(QStringLiteral("zone")).toString(), true});
    if (name == QLatin1String("time.set")) {
        qint64 usec = 0;
        isUsec(op.value(QStringLiteral("usec")), &usec);
        return privileged(bus, kTimeService, kTimePath, QStringLiteral("SetTime"), {QVariant::fromValue(usec), false, true});
    }
    if (name == QLatin1String("user.enable")) {
        // Only one of the user's own services (userUnits): never a unit a package or the system ships.
        const QString unit = op.value(QStringLiteral("unit")).toString();
        const StateResult own = userUnits(bus, ownDirs);
        if (!own.ok)
            return own.error;
        bool listed = false;
        for (const QJsonValue &u : own.json.value(QStringLiteral("units")).toArray())
            listed = listed || u.toObject().value(QStringLiteral("unit")).toString() == unit;
        if (!listed)
            return QCoreApplication::translate("SystemBus", "that item is not one of your own");
        const bool on = op.value(QStringLiteral("on")).toBool();
        const BusReply r = on ? bus.call(kSystemd, kSystemdPath, kSystemdManager, QStringLiteral("EnableUnitFiles"), {QStringList{unit}, false, false}, kActMs)
                              : bus.call(kSystemd, kSystemdPath, kSystemdManager, QStringLiteral("DisableUnitFiles"), {QStringList{unit}, false}, kActMs);
        if (!r.ok)
            return fail(r.error);
        const BusReply reload = bus.call(kSystemd, kSystemdPath, kSystemdManager, QStringLiteral("Reload"), {}, kActMs);
        return reload.ok ? QString() : fail(reload.error);
    }
    // Privacy & Security (session bus, the user's own grants): one application's switch, or one saved selection forgotten.
    if (name == QLatin1String("privacy.allow")) {
        const QString category = op.value(QStringLiteral("category")).toString();
        for (const PrivacyGrant &g : privacyGrants()) {
            if (g.category != category)
                continue;
            const QStringList value = op.value(QStringLiteral("on")).toBool() ? g.allow : g.deny;
            const BusReply r = bus.call(kPermStore, kPermStorePath, kPermStore, QStringLiteral("SetPermission"),
                                        {g.table, true, g.id, op.value(QStringLiteral("app")).toString(), value}, kActMs);
            return r.ok ? QString() : fail(r.error);
        }
    }
    if (name == QLatin1String("privacy.forget")) {
        const QString kind = op.value(QStringLiteral("kind")).toString();
        for (const auto &[key, table] : privacySelections()) {
            if (key != kind)
                continue;
            const BusReply r = bus.call(kPermStore, kPermStorePath, kPermStore, QStringLiteral("Delete"), {table, op.value(QStringLiteral("token")).toString()}, kActMs);
            // Already gone (used and saved again under a new token meanwhile): nothing left to forget.
            return r.ok || r.error.startsWith(QLatin1String("org.freedesktop.portal.Error.NotFound")) ? QString() : fail(r.error);
        }
    }
    // Remote Login (ADR-0045 OC-7, OC-0.7): systemd's sshd.service, enabled and started, or stopped and disabled. systemd asks
    // polkit for each call (manage-unit-files, then manage-units: two dialogs unless polkit keeps the first answer); no Reload
    // (a third action): the unit file state is read from the disk (sharingState), and StartUnit starts the unit at once.
    if (name == QLatin1String("ssh.enable")) {
        const QStringList units{kSshdUnit};
        if (op.value(QStringLiteral("on")).toBool()) {
            // Only once Omarchy's own setup has run (the page asks it first; security review of ADR-0045, L-4): before it, no key
            // is authorized and Omarchy's firewall denies incoming connections.
            if (!QFileInfo(sshSetUpFile).isFile())
                return QCoreApplication::translate("SystemBus", "Omarchy's SSH setup has not run");
            const BusReply enable = bus.call(kSystemd, kSystemdPath, kSystemdManager, QStringLiteral("EnableUnitFiles"), {units, false, false}, kPrivilegedMs);
            if (!enable.ok)
                return fail(enable.error);
            const BusReply start = bus.call(kSystemd, kSystemdPath, kSystemdManager, QStringLiteral("StartUnit"), {kSshdUnit, QStringLiteral("replace")}, kPrivilegedMs);
            return start.ok ? QString() : fail(start.error);
        }
        const BusReply stop = bus.call(kSystemd, kSystemdPath, kSystemdManager, QStringLiteral("StopUnit"), {kSshdUnit, QStringLiteral("replace")}, kPrivilegedMs);
        if (!stop.ok)
            return fail(stop.error);
        const BusReply disable = bus.call(kSystemd, kSystemdPath, kSystemdManager, QStringLiteral("DisableUnitFiles"), {units, false}, kPrivilegedMs);
        return disable.ok ? QString() : fail(disable.error);
    }
    // Disk Encryption > Change Password… (ADR-0045 OC-8, OC-0.7): UDisks2 on the root file system's LUKS device, found here
    // again; UDisks2 asks polkit (encrypted-change-passphrase-system) and needs the current passphrase to open a key slot.
    if (name == QLatin1String("disk.passphrase")) {
        QString error;
        QString device;
        const QString luks = rootLuksDevice(bus, &error, &device);
        if (luks.isEmpty())
            return error.isEmpty() ? QCoreApplication::translate("SystemBus", "the start-up disk is not encrypted") : fail(error);
        const BusReply r = bus.call(kUDisks, luks, kUDisksEncrypted, QStringLiteral("ChangePassphrase"),
                                    {op.value(QStringLiteral("old")).toString(), op.value(QStringLiteral("new")).toString(), QVariant::fromValue(QVariantMap())},
                                    kPrivilegedMs);
        return r.ok ? QString() : passphraseFailure(r.error);
    }
    // Fingerprint (ADR-0045 OC-6, OC-0.7): one enrolled finger deleted, the reader claimed for the call and released after.
    if (name == QLatin1String("fprint.delete")) {
        const BusReply device = bus.call(kFprint, kFprintManagerPath, kFprintManager, QStringLiteral("GetDefaultDevice"), {}, kReadMs);
        if (!device.ok || device.args.isEmpty())
            return device.ok ? QCoreApplication::translate("SystemBus", "empty reply") : fail(device.error);
        const QString path = cast<QDBusObjectPath>(device.args.first()).path();
        const BusReply claim = bus.call(kFprint, path, kFprintDevice, QStringLiteral("Claim"), {QString()}, kPrivilegedMs);
        if (!claim.ok)
            return fail(claim.error);
        const BusReply r = bus.call(kFprint, path, kFprintDevice, QStringLiteral("DeleteEnrolledFinger"), {op.value(QStringLiteral("finger")).toString()}, kPrivilegedMs);
        bus.call(kFprint, path, kFprintDevice, QStringLiteral("Release"), {}, kActMs);
        return r.ok ? QString() : fail(r.error);
    }
    // Without the Backend's progress and stop (it runs enrollFinger itself): a status-less run, ended after kActMs of silence.
    if (name == QLatin1String("fprint.enroll"))
        return enrollFinger(bus, op.value(QStringLiteral("finger")).toString(), {}, {}, kActMs);

    if (name == QLatin1String("wifi.radio"))
        return setProperty(bus, kNmService, kNmPath, kNmIface, QStringLiteral("WirelessEnabled"), op.value(QStringLiteral("on")).toBool());

    // Battery > Charging: UPower's charge limit (EnableChargeThreshold on the battery; its polkit action
    // org.freedesktop.UPower.enable-charging-limit lets the active session by default, ADR-0030).
    if (name == QLatin1String("power.chargeLimit")) {
        QString error;
        const QString battery = upowerBattery(bus, &error);
        if (battery.isEmpty())
            return error.isEmpty() ? QCoreApplication::translate("SystemBus", "no battery") : fail(error);
        const BusReply r = bus.call(kUPower, battery, kUPowerDevice, QStringLiteral("EnableChargeThreshold"), {op.value(QStringLiteral("on")).toBool()}, kPrivilegedMs);
        return r.ok ? QString() : fail(r.error);
    }
    // Printers (ADR-0030). A new queue for a driverless printer: cupsd builds its PPD from the printer's IPP attributes
    // ("everywhere"), then the queue is enabled and accepts jobs (it starts stopped, as lpadmin without -E). The helper checks
    // other polkit actions for the two switches, so it may ask again; refused there, the queue stays, stopped: the page shows it
    // and its sheet offers Resume (printer.resume, the same two calls) and Remove Printer….
    const auto resume = [&bus](const QString &printer) {
        QString error = cupsPk(bus, QStringLiteral("PrinterSetEnabled"), {printer, true});
        if (error.isEmpty())
            error = cupsPk(bus, QStringLiteral("PrinterSetAcceptJobs"), {printer, true, QString()});
        return error;
    };
    if (name == QLatin1String("printer.add")) {
        const QString printer = op.value(QStringLiteral("name")).toString();
        const QString error = cupsPk(bus, QStringLiteral("PrinterAdd"),
                                     {printer, op.value(QStringLiteral("uri")).toString(), QStringLiteral("everywhere"), op.value(QStringLiteral("info")).toString(), QString()}); // i18n-ignore: CUPS's model name
        return error.isEmpty() ? resume(printer) : error;
    }
    if (name == QLatin1String("printer.resume"))
        return resume(op.value(QStringLiteral("name")).toString());
    if (name == QLatin1String("printer.delete"))
        return cupsPk(bus, QStringLiteral("PrinterDelete"), {op.value(QStringLiteral("name")).toString()});

    // Forget This Network: the saved Wi-Fi profile with that uuid goes. NetworkManager asks polkit itself for a profile of the
    // whole system (settings.modify.system, ADR-0030), so the call waits for the user's answer.
    if (name == QLatin1String("wifi.forget")) {
        const QString uuid = op.value(QStringLiteral("uuid")).toString();
        for (const AnyProfile &p : allProfiles(bus)) {
            if (p.type != QLatin1String("802-11-wireless") || p.uuid.compare(uuid, Qt::CaseInsensitive) != 0)
                continue;
            const BusReply r = bus.call(kNmService, p.path, kNmConnection, QStringLiteral("Delete"), {}, kPrivilegedMs);
            return r.ok ? QString() : fail(r.error);
        }
        return QCoreApplication::translate("SystemBus", "that network is no longer saved");
    }
    // A VPN or WireGuard profile switched on (activated on no particular device) or off (its active connection deactivated).
    if (name == QLatin1String("vpn.connect")) {
        const QString uuid = op.value(QStringLiteral("uuid")).toString();
        for (const AnyProfile &p : allProfiles(bus)) {
            if ((p.type != QLatin1String("vpn") && p.type != QLatin1String("wireguard")) || p.uuid.compare(uuid, Qt::CaseInsensitive) != 0)
                continue;
            if (op.value(QStringLiteral("on")).toBool()) {
                const BusReply r = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("ActivateConnection"),
                                            {QVariant::fromValue(QDBusObjectPath(p.path)), QVariant::fromValue(QDBusObjectPath(QStringLiteral("/"))),
                                             QVariant::fromValue(QDBusObjectPath(QStringLiteral("/")))},
                                            kActMs);
                return r.ok ? QString() : fail(r.error);
            }
            const QString activePath = activeConnections(bus).value(p.uuid.toLower()).first;
            if (activePath.isEmpty())
                return QString(); // already off
            const BusReply r = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("DeactivateConnection"),
                                        {QVariant::fromValue(QDBusObjectPath(activePath))}, kActMs);
            return r.ok ? QString() : fail(r.error);
        }
        return QCoreApplication::translate("SystemBus", "that VPN is no longer saved");
    }

    if (name.startsWith(QLatin1String("wifi."))) {
        QString error;
        const WifiDevice dev = firstWifiDevice(bus, &error);
        if (!dev.found)
            return error.isEmpty() ? QCoreApplication::translate("SystemBus", "no Wi-Fi adapter") : fail(error);
        if (name == QLatin1String("wifi.scan")) {
            const BusReply r = bus.call(kNmService, dev.path, kNmWireless, QStringLiteral("RequestScan"), {QVariant::fromValue(QVariantMap())}, kActMs);
            return r.ok ? QString() : fail(r.error);
        }
        if (name == QLatin1String("wifi.disconnect")) {
            const BusReply r = bus.call(kNmService, dev.path, kNmDevice, QStringLiteral("Disconnect"), {}, kActMs);
            return r.ok ? QString() : fail(r.error);
        }
        if (name == QLatin1String("wifi.connectKnown")) {
            const QString uuid = op.value(QStringLiteral("uuid")).toString();
            for (const Profile &p : wifiProfiles(bus)) {
                if (p.uuid.compare(uuid, Qt::CaseInsensitive) != 0)
                    continue;
                const BusReply r = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("ActivateConnection"),
                                            {QVariant::fromValue(QDBusObjectPath(p.path)), QVariant::fromValue(QDBusObjectPath(dev.path)),
                                             QVariant::fromValue(QDBusObjectPath(QStringLiteral("/")))},
                                            kActMs);
                return r.ok ? QString() : fail(r.error);
            }
            return QCoreApplication::translate("SystemBus", "that network is no longer saved");
        }
        if (name == QLatin1String("wifi.connectSecure"))
            return joinWithPassphrase(bus, dev.path, QByteArray::fromHex(op.value(QStringLiteral("hex")).toString().toLatin1()),
                                      op.value(QStringLiteral("psk")).toString());
        // wifi.connectOpen: only an access point that needs no password (wifi.connectSecure joins the others).
        // The page asks for the row it shows, a network without a password: an access point with the same SSID that is secured is
        // another row. So the choice is made on the security of the access point: the strongest one that needs no password (open
        // or Enhanced Open); only secured ones: refused.
        const QByteArray ssid = QByteArray::fromHex(op.value(QStringLiteral("hex")).toString().toLatin1());
        bool seen = false;
        AccessPoint ap;
        bool haveOpen = false;
        for (const AccessPoint &candidate : accessPoints(bus, dev.path)) {
            if (candidate.ssid != ssid)
                continue;
            seen = true;
            if (!needsCredentials(candidate) && (!haveOpen || candidate.strength > ap.strength)) {
                ap = candidate;
                haveOpen = true;
            }
        }
        if (seen && !haveOpen)
            return QCoreApplication::translate("SystemBus", "that network needs a password");
        if (haveOpen) {
            ConnectionSettings settings;
            settings.insert(QStringLiteral("connection"), QVariantMap{{QStringLiteral("id"), QString::fromUtf8(ssid)}, {QStringLiteral("type"), QStringLiteral("802-11-wireless")}});
            settings.insert(QStringLiteral("802-11-wireless"), QVariantMap{{QStringLiteral("ssid"), ssid}, {QStringLiteral("mode"), QStringLiteral("infrastructure")}});
            if (isOwe(ap)) // NetworkManager joins an OWE access point only with key-mgmt owe (no secret: there is none)
                settings.insert(QStringLiteral("802-11-wireless-security"), QVariantMap{{QStringLiteral("key-mgmt"), QStringLiteral("owe")}});
            // A new profile of the whole system: NetworkManager may ask polkit (settings.modify.system, ADR-0030).
            const BusReply r = bus.call(kNmService, kNmPath, kNmIface, QStringLiteral("AddAndActivateConnection"),
                                        {QVariant::fromValue(settings), QVariant::fromValue(QDBusObjectPath(dev.path)), QVariant::fromValue(QDBusObjectPath(ap.path))}, kPrivilegedMs);
            return r.ok ? QString() : fail(r.error);
        }
        return QCoreApplication::translate("SystemBus", "that network is no longer in range");
    }

    // Bluetooth.
    QString error;
    const ManagedObjects objects = bluezObjects(bus, &error);
    if (!error.isEmpty())
        return fail(error);
    const QString adapter = firstAdapterPath(objects);
    if (name == QLatin1String("bt.power")) {
        return adapter.isEmpty() ? QCoreApplication::translate("SystemBus", "no Bluetooth adapter") : setProperty(bus, kBluez, adapter, kAdapter, QStringLiteral("Powered"), op.value(QStringLiteral("on")).toBool());
    }
    // Looking for nearby devices while the pane is open. BlueZ ends a discovery when its client leaves the bus, so a window that
    // closes without StopDiscovery stops it too. Already running or already stopped is not a failure.
    if (name == QLatin1String("bt.discover")) {
        if (adapter.isEmpty())
            return QCoreApplication::translate("SystemBus", "no Bluetooth adapter");
        const bool on = op.value(QStringLiteral("on")).toBool();
        const BusReply r = bus.call(kBluez, adapter, kAdapter, on ? QStringLiteral("StartDiscovery") : QStringLiteral("StopDiscovery"), {}, kActMs); // i18n-ignore: D-Bus method names
        if (r.ok || r.error.startsWith(QLatin1String("org.bluez.Error.InProgress")) || r.error.startsWith(QLatin1String("org.bluez.Error.NotReady"))
            || (!on && r.error.startsWith(QLatin1String("org.bluez.Error.Failed"))))
            return QString();
        return fail(r.error);
    }
    const QString mac = op.value(QStringLiteral("mac")).toString().toUpper();
    for (auto it = objects.cbegin(); it != objects.cend(); ++it) {
        const QVariantMap d = it.value().value(kDevice1);
        if (d.isEmpty() || d.value(QStringLiteral("Address")).toString().toUpper() != mac)
            continue;
        const QString path = it.key().path();
        // Pair a nearby device, trust it (it may connect again on its own) and connect it. Settings registers no pairing agent:
        // BlueZ asks the session's default agent (in the Grassfield session the shell's pairing sheet, ADR-0035 step 10), and
        // without one pairs as a device without input or output (Just Works), which most mice, keyboards and headphones accept;
        // one that needs a code is then refused and its reason shown. The pairing can wait for the device (kPrivilegedMs).
        if (name == QLatin1String("bt.pair")) {
            if (!d.value(QStringLiteral("Paired")).toBool()) {
                const BusReply r = bus.call(kBluez, path, kDevice1, QStringLiteral("Pair"), {}, kPrivilegedMs);
                if (!r.ok && !r.error.startsWith(QLatin1String("org.bluez.Error.AlreadyExists")))
                    return fail(r.error);
            }
            const QString trust = setProperty(bus, kBluez, path, kDevice1, QStringLiteral("Trusted"), true);
            if (!trust.isEmpty())
                return trust;
            const BusReply c = bus.call(kBluez, path, kDevice1, QStringLiteral("Connect"), {}, kActMs);
            return c.ok ? QString() : fail(c.error);
        }
        // Forget This Device: BlueZ removes the device and its keys.
        if (name == QLatin1String("bt.forget")) {
            if (adapter.isEmpty())
                return QCoreApplication::translate("SystemBus", "no Bluetooth adapter");
            const BusReply r = bus.call(kBluez, adapter, kAdapter, QStringLiteral("RemoveDevice"), {QVariant::fromValue(QDBusObjectPath(path))}, kActMs);
            return r.ok ? QString() : fail(r.error);
        }
        // Connect or disconnect a paired device (macOS pairs first).
        if (op.value(QStringLiteral("connect")).toBool() && !d.value(QStringLiteral("Paired")).toBool())
            return QCoreApplication::translate("SystemBus", "that device is not paired yet");
        const BusReply r = bus.call(kBluez, path, kDevice1, op.value(QStringLiteral("connect")).toBool() ? QStringLiteral("Connect") : QStringLiteral("Disconnect"), {}, kActMs); // i18n-ignore: D-Bus method names
        return r.ok ? QString() : fail(r.error);
    }
    if (name == QLatin1String("bt.pair"))
        return QCoreApplication::translate("SystemBus", "that device is no longer nearby");
    return QCoreApplication::translate("SystemBus", "that device is no longer paired");
}

} // namespace grassfield::settings
