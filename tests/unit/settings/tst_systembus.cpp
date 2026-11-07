// Unit tests of apps/settings/src/systembus.h: the Wi-Fi and Bluetooth logic over D-Bus, against a canned bus (no bus, no
// session, nothing of the machine's network or Bluetooth can be reached from here). What is asserted is what the pages show
// (the state JSON) and exactly which calls an action makes, with which arguments, and which it must never make.
#include <gtest/gtest.h>

#include <QDBusObjectPath>
#include <QDBusVariant>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMap>
#include <QTemporaryFile>

#include <algorithm>
#include <functional>
#include <memory>

#include "systembus.h"

using namespace grassfield::settings;

namespace
{
using ConnectionSettings = QMap<QString, QVariantMap>;
using ManagedObjects = QMap<QDBusObjectPath, ConnectionSettings>;

struct Call {
    QString service, path, iface, member;
    QVariantList args;
    int timeoutMs = 0;
};

// A bus that answers from a table and remembers every call.
class FakeBus : public BusCaller
{
public:
    std::function<BusReply(const Call &)> handler;
    QList<Call> calls;

    BusReply call(const QString &service, const QString &path, const QString &iface, const QString &member, const QVariantList &args, int timeoutMs) override
    {
        const Call c{service, path, iface, member, args, timeoutMs};
        calls.append(c);
        return handler ? handler(c) : BusReply{false, {}, QStringLiteral("org.freedesktop.DBus.Error.ServiceUnknown: nobody")};
    }

    QStringList members() const
    {
        QStringList out;
        for (const Call &c : calls)
            out << c.iface.section(QLatin1Char('.'), -1) + QLatin1Char('.') + c.member;
        return out;
    }

    // Signals (fprintd's EnrollStatus): what listen was asked (in the order of the calls: "listen" in members()), then the
    // scripted signals one by one; none left (or no listen) is a wait that ended without one.
    QList<QVariantList> scripted;
    bool listen(const QString &service, const QString &path, const QString &iface, const QString &member) override
    {
        calls.append({service, path, iface, QStringLiteral("listen:") + member, {}, 0});
        return true;
    }
    BusReply nextSignal(int) override
    {
        if (scripted.isEmpty())
            return BusReply{false, {}, QStringLiteral("org.freedesktop.DBus.Error.Timeout: no signal")};
        return BusReply{true, scripted.takeFirst(), {}};
    }
};

BusReply ok(const QVariantList &args = {})
{
    return {true, args, {}};
}

BusReply err(const QString &error)
{
    return {false, {}, error};
}

QVariant path(const QString &p)
{
    return QVariant::fromValue(QDBusObjectPath(p));
}

QVariant paths(const QStringList &list)
{
    QList<QDBusObjectPath> out;
    for (const QString &p : list)
        out.append(QDBusObjectPath(p));
    return QVariant::fromValue(out);
}

QVariant variant(const QVariant &v)
{
    return QVariant::fromValue(QDBusVariant(v));
}

QVariant u8(int v)
{
    return QVariant::fromValue<uchar>(static_cast<uchar>(v));
}

QVariant u32(uint v)
{
    return QVariant::fromValue<uint>(v);
}

const QString kNm = QStringLiteral("/org/freedesktop/NetworkManager");

// A NetworkManager with an Ethernet and a Wi-Fi device, three access points (two of them "Home", the stronger one
// connected), an open "Cafe" and a profile for "Home" and one that is not Wi-Fi.
struct NmFixture {
    bool radio = true;
    uint wifiState = 100;
    QString activeAp = QStringLiteral("/ap/1");
    FakeBus bus;
    QMap<QString, QVariantMap> apProps;

    NmFixture()
    {
        apProps[QStringLiteral("/ap/1")] = {{"Ssid", QByteArray("Home")}, {"Strength", u8(71)}, {"Flags", u32(1)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0x188)}};
        apProps[QStringLiteral("/ap/2")] = {{"Ssid", QByteArray("Home")}, {"Strength", u8(40)}, {"Flags", u32(1)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0x188)}};
        apProps[QStringLiteral("/ap/3")] = {{"Ssid", QByteArray("Cafe")}, {"Strength", u8(55)}, {"Flags", u32(0)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0)}};
        bus.handler = [this](const Call &c) { return answer(c); };
    }

    BusReply answer(const Call &c)
    {
        const QString m = c.member;
        if (c.iface == QLatin1String("org.freedesktop.DBus.Properties")) {
            const QString target = c.args.value(0).toString();
            if (m == QLatin1String("Get")) {
                const QString name = c.args.value(1).toString();
                if (name == QLatin1String("WirelessEnabled"))
                    return ok({variant(radio)});
                if (name == QLatin1String("ActiveAccessPoint"))
                    return ok({variant(path(activeAp))});
            }
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.Device")) {
                if (c.path == QLatin1String("/dev/eth0"))
                    return ok({QVariant::fromValue(QVariantMap{{"DeviceType", u32(1)}, {"Interface", QStringLiteral("eth0")}, {"State", u32(100)}})});
                return ok({QVariant::fromValue(QVariantMap{{"DeviceType", u32(2)}, {"Interface", QStringLiteral("wlan0")}, {"State", u32(wifiState)}})});
            }
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.AccessPoint")) {
                if (apProps.contains(c.path))
                    return ok({QVariant::fromValue(apProps.value(c.path))});
                return err(QStringLiteral("org.freedesktop.DBus.Error.UnknownObject: gone"));
            }
            if (m == QLatin1String("Set"))
                return ok();
        }
        if (m == QLatin1String("GetDevices"))
            return ok({paths({QStringLiteral("/dev/eth0"), QStringLiteral("/dev/wlan0")})});
        if (m == QLatin1String("GetAllAccessPoints"))
            return ok({paths({QStringLiteral("/ap/1"), QStringLiteral("/ap/2"), QStringLiteral("/ap/3"), QStringLiteral("/ap/gone")})});
        if (m == QLatin1String("ListConnections"))
            return ok({paths({QStringLiteral("/conn/1"), QStringLiteral("/conn/2")})});
        if (m == QLatin1String("GetSettings")) {
            ConnectionSettings s;
            if (c.path == QLatin1String("/conn/1")) {
                s[QStringLiteral("connection")] = {{"type", QStringLiteral("802-11-wireless")}, {"uuid", QStringLiteral("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")}};
                s[QStringLiteral("802-11-wireless")] = {{"ssid", QByteArray("Home")}};
            } else {
                s[QStringLiteral("connection")] = {{"type", QStringLiteral("802-3-ethernet")}, {"uuid", QStringLiteral("11111111-2222-3333-4444-555555555555")}};
            }
            return ok({QVariant::fromValue(s)});
        }
        if (m == QLatin1String("ActivateConnection") || m == QLatin1String("Disconnect") || m == QLatin1String("RequestScan"))
            return ok();
        if (m == QLatin1String("AddAndActivateConnection"))
            return ok({path(QStringLiteral("/conn/new")), path(QStringLiteral("/active/1"))});
        return err(QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod: ") + m);
    }
};

QJsonObject stateOf(const StateResult &r)
{
    return r.json;
}
} // namespace

TEST(SystemBusWifi, StateListsRadioDeviceAccessPointsAndProfiles)
{
    NmFixture f;
    const StateResult r = wifiState(f.bus);
    ASSERT_TRUE(r.ok) << r.error.toStdString();
    const QJsonObject j = stateOf(r);
    EXPECT_TRUE(j["radio"].toBool());
    EXPECT_EQ(j["device"]["name"].toString(), QStringLiteral("wlan0"));
    EXPECT_TRUE(j["device"]["connected"].toBool());
    const QJsonArray aps = j["aps"].toArray();
    ASSERT_EQ(aps.size(), 3); // the access point that went away between the two calls is skipped
    EXPECT_EQ(aps[0]["hex"].toString(), QStringLiteral("486F6D65")); // "Home"
    EXPECT_EQ(aps[0]["strength"].toInt(), 71);
    EXPECT_TRUE(aps[0]["active"].toBool());
    EXPECT_FALSE(aps[1]["active"].toBool());
    EXPECT_EQ(aps[0]["rsn"].toInt(), 0x188);
    EXPECT_EQ(aps[2]["hex"].toString(), QStringLiteral("43616665"));  // "Cafe"
    const QJsonArray profiles = j["profiles"].toArray();
    ASSERT_EQ(profiles.size(), 1); // the Ethernet profile is not a Wi-Fi one
    EXPECT_EQ(profiles[0]["uuid"].toString(), QStringLiteral("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"));
    EXPECT_EQ(profiles[0]["hex"].toString(), QStringLiteral("486F6D65"));
}

TEST(SystemBusWifi, ReadsOnlyReadMethods)
{
    NmFixture f;
    ASSERT_TRUE(wifiState(f.bus).ok);
    for (const Call &c : f.bus.calls)
        EXPECT_TRUE(isReadOnlyCall(c.service, c.iface, c.member, c.args)) << (c.iface + "." + c.member).toStdString();
}

TEST(SystemBusWifi, RadioOffListsNoAccessPointsAndNoDeviceIsNull)
{
    NmFixture f;
    f.radio = false;
    const StateResult r = wifiState(f.bus);
    ASSERT_TRUE(r.ok);
    EXPECT_FALSE(r.json["radio"].toBool());
    EXPECT_EQ(r.json["aps"].toArray().size(), 0);

    FakeBus none;
    none.handler = [](const Call &c) {
        if (c.member == QLatin1String("Get"))
            return ok({variant(true)});
        if (c.member == QLatin1String("GetDevices"))
            return ok({paths({})});
        return ok({paths({})});
    };
    const StateResult n = wifiState(none);
    ASSERT_TRUE(n.ok);
    EXPECT_TRUE(n.json["device"].isNull());
}

TEST(SystemBusWifi, ANetworkManagerThatIsNotRunningIsAReasonNotAnEmptyList)
{
    FakeBus bus;
    const StateResult r = wifiState(bus);
    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.error, QStringLiteral("the service is not running"));
    bus.handler = [](const Call &) { return err(QStringLiteral("org.freedesktop.DBus.Error.NoReply: Did not receive a reply")); };
    EXPECT_EQ(wifiState(bus).error, QStringLiteral("timed out"));
}

TEST(SystemBusWifi, ActionsMakeExactlyTheirCalls)
{
    {
        NmFixture f;
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.radio"}, {"on", false}}), QString());
        ASSERT_EQ(f.bus.calls.size(), 1);
        const Call &c = f.bus.calls[0];
        EXPECT_EQ(c.member, QStringLiteral("Set"));
        EXPECT_EQ(c.path, kNm);
        EXPECT_EQ(c.args[0].toString(), QStringLiteral("org.freedesktop.NetworkManager"));
        EXPECT_EQ(c.args[1].toString(), QStringLiteral("WirelessEnabled"));
        EXPECT_FALSE(qvariant_cast<QDBusVariant>(c.args[2]).variant().toBool());
    }
    {
        NmFixture f;
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectKnown"}, {"uuid", "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"}}), QString());
        const Call c = f.bus.calls.last();
        EXPECT_EQ(c.member, QStringLiteral("ActivateConnection"));
        EXPECT_EQ(qvariant_cast<QDBusObjectPath>(c.args[0]).path(), QStringLiteral("/conn/1"));
        EXPECT_EQ(qvariant_cast<QDBusObjectPath>(c.args[1]).path(), QStringLiteral("/dev/wlan0"));
        EXPECT_EQ(qvariant_cast<QDBusObjectPath>(c.args[2]).path(), QStringLiteral("/"));
    }
    {
        NmFixture f;
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.disconnect"}}), QString());
        EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("Disconnect"));
        EXPECT_EQ(f.bus.calls.last().path, QStringLiteral("/dev/wlan0"));
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.scan"}}), QString());
        EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("RequestScan"));
    }
    {
        NmFixture f;
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectOpen"}, {"hex", "43616665"}}), QString());
        const Call c = f.bus.calls.last();
        ASSERT_EQ(c.member, QStringLiteral("AddAndActivateConnection"));
        ASSERT_GE(c.args.size(), 3);
        const ConnectionSettings s = qvariant_cast<ConnectionSettings>(c.args[0]);
        EXPECT_EQ(s["connection"]["id"].toString(), QStringLiteral("Cafe"));
        EXPECT_EQ(s["connection"]["type"].toString(), QStringLiteral("802-11-wireless"));
        EXPECT_EQ(s["802-11-wireless"]["ssid"].toByteArray(), QByteArray("Cafe"));
        EXPECT_FALSE(s.contains(QStringLiteral("802-11-wireless-security")));
        EXPECT_EQ(qvariant_cast<QDBusObjectPath>(c.args[2]).path(), QStringLiteral("/ap/3"));
    }
}

TEST(SystemBusWifi, ASecuredOrMissingNetworkIsNotJoinedAndSaysWhy)
{
    NmFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectOpen"}, {"hex", "486F6D65"}}), QStringLiteral("that network needs a password"));
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectOpen"}, {"hex", "4E6F7065"}}), QStringLiteral("that network is no longer in range"));
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectKnown"}, {"uuid", "22222222-2222-2222-2222-222222222222"}}), QStringLiteral("that network is no longer saved"));
    for (const Call &c : f.bus.calls)
        EXPECT_TRUE(c.member != QLatin1String("AddAndActivateConnection") && c.member != QLatin1String("ActivateConnection"));
}

TEST(SystemBusWifi, AnOpenAndASecuredNetworkOfTheSameNameAreToldApartBySecurity)
{
    // "Home" is secured on /ap/1 and /ap/2 (listed first); an open "Home" (/ap/gone, the page's open row) is joined by ITS access
    // point, not refused for the secured neighbours; the strongest of several open ones is chosen.
    NmFixture f;
    f.apProps[QStringLiteral("/ap/gone")] = {{"Ssid", QByteArray("Home")}, {"Strength", u8(20)}, {"Flags", u32(0)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0)}};
    f.apProps[QStringLiteral("/ap/2")] = {{"Ssid", QByteArray("Home")}, {"Strength", u8(60)}, {"Flags", u32(0)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0)}};
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectOpen"}, {"hex", "486F6D65"}}), QString());
    const Call c = f.bus.calls.last();
    ASSERT_EQ(c.member, QStringLiteral("AddAndActivateConnection"));
    ASSERT_GE(c.args.size(), 3);
    EXPECT_EQ(qvariant_cast<QDBusObjectPath>(c.args[2]).path(), QStringLiteral("/ap/2"));
    EXPECT_FALSE(qvariant_cast<ConnectionSettings>(c.args[0]).contains(QStringLiteral("802-11-wireless-security")));
    // Only the secured ones left: refused with the password reason, never joined.
    NmFixture g;
    EXPECT_EQ(runAction(g.bus, {{"op", "wifi.connectOpen"}, {"hex", "486F6D65"}}), QStringLiteral("that network needs a password"));
}

TEST(SystemBusWifi, ASecuredNetworkIsJoinedWithItsPassphraseAndKeptOnlyOnceUp)
{
    NmFixture f;
    QList<uint> states{1, 1, 2}; // activating twice, then activated
    f.bus.handler = [&f, &states](const Call &c) {
        if (c.member == QLatin1String("Get") && c.path == QLatin1String("/active/1") && c.args.value(1).toString() == QLatin1String("State"))
            return ok({variant(u32(states.isEmpty() ? 2 : states.takeFirst()))});
        return f.answer(c);
    };
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", "correct horse"}}), QString());
    const auto add = std::find_if(f.bus.calls.cbegin(), f.bus.calls.cend(), [](const Call &c) { return c.member == QLatin1String("AddAndActivateConnection"); });
    ASSERT_NE(add, f.bus.calls.cend());
    const ConnectionSettings s = qvariant_cast<ConnectionSettings>(add->args[0]);
    EXPECT_EQ(s["802-11-wireless"]["ssid"].toByteArray(), QByteArray("Home"));
    EXPECT_EQ(s["802-11-wireless-security"]["key-mgmt"].toString(), QStringLiteral("wpa-psk"));
    EXPECT_EQ(s["802-11-wireless-security"]["psk"].toString(), QStringLiteral("correct horse"));
    EXPECT_EQ(qvariant_cast<QDBusObjectPath>(add->args[2]).path(), QStringLiteral("/ap/1")); // the stronger "Home"
    EXPECT_EQ(add->timeoutMs, 120000); // a profile of the whole system: NetworkManager may ask polkit
    EXPECT_FALSE(f.bus.members().contains(QStringLiteral("Connection.Delete")));
    EXPECT_TRUE(states.isEmpty());
    EXPECT_TRUE(privilegedAction({{"op", "wifi.connectSecure"}}));
    EXPECT_TRUE(privilegedAction({{"op", "wifi.connectOpen"}}));

    // WPA3 only (SAE, no PSK): key-mgmt sae.
    NmFixture w;
    w.apProps[QStringLiteral("/ap/1")][QStringLiteral("RsnFlags")] = u32(0x488);
    w.bus.handler = [&w](const Call &c) {
        if (c.member == QLatin1String("Get") && c.args.value(1).toString() == QLatin1String("State"))
            return ok({variant(u32(2))});
        return w.answer(c);
    };
    EXPECT_EQ(runAction(w.bus, {{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", "correct horse"}}), QString());
    const auto sae = std::find_if(w.bus.calls.cbegin(), w.bus.calls.cend(), [](const Call &c) { return c.member == QLatin1String("AddAndActivateConnection"); });
    ASSERT_NE(sae, w.bus.calls.cend());
    EXPECT_EQ(qvariant_cast<QDBusObjectPath>(sae->args[2]).path(), QStringLiteral("/ap/1"));
    EXPECT_EQ(qvariant_cast<ConnectionSettings>(sae->args[0])["802-11-wireless-security"]["key-mgmt"].toString(), QStringLiteral("sae"));
}

TEST(SystemBusWifi, AFailedJoinDeletesItsNewProfileAndSaysSo)
{
    // The connection went down (a wrong password), or went away: the new profile is deleted.
    for (const bool gone : {false, true}) {
        NmFixture f;
        f.bus.handler = [&f, gone](const Call &c) {
            if (c.member == QLatin1String("Get") && c.path == QLatin1String("/active/1") && c.args.value(1).toString() == QLatin1String("State"))
                return gone ? err(QStringLiteral("org.freedesktop.DBus.Error.UnknownObject: gone")) : ok({variant(u32(4))});
            if (c.member == QLatin1String("Delete"))
                return ok();
            return f.answer(c);
        };
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", "wrong horse"}}), QStringLiteral("the network could not be joined"));
        EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("Delete"));
        EXPECT_EQ(f.bus.calls.last().path, QStringLiteral("/conn/new"));
        // The profile is one of the whole system: its Delete may wait for the polkit dialog.
        EXPECT_EQ(f.bus.calls.last().timeoutMs, 120000);
    }
    // An open network takes no password, a missing one is not joined at all.
    NmFixture o;
    EXPECT_EQ(runAction(o.bus, {{"op", "wifi.connectSecure"}, {"hex", "43616665"}, {"psk", "correct horse"}}), QStringLiteral("that network does not take a password"));
    EXPECT_EQ(runAction(o.bus, {{"op", "wifi.connectSecure"}, {"hex", "4E6F7065"}, {"psk", "correct horse"}}), QStringLiteral("that network is no longer in range"));
    EXPECT_FALSE(o.bus.members().contains(QStringLiteral("NetworkManager.AddAndActivateConnection")));
}

TEST(SystemBusWifi, AJoinWhoseStateCannotBeReadIsNoFailure)
{
    // A State read that fails for another reason (no reply, the service restarting) is not a failure: the next read decides.
    const auto reads = [](QList<BusReply> answers, bool deleteOk = true) {
        auto bus = std::make_shared<FakeBus>();
        auto left = std::make_shared<QList<BusReply>>(std::move(answers));
        bus->handler = [left, deleteOk](const Call &c) {
            if (c.member == QLatin1String("Get") && c.path == QLatin1String("/active/1") && c.args.value(1).toString() == QLatin1String("State"))
                return left->isEmpty() ? err(QStringLiteral("org.freedesktop.DBus.Error.NoReply: no answer")) : left->takeFirst();
            if (c.member == QLatin1String("Delete"))
                return deleteOk ? ok() : err(QStringLiteral("org.freedesktop.NetworkManager.Settings.Connection.PermissionDenied: Insufficient privileges"));
            return err(QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod: ") + c.member);
        };
        return bus;
    };
    const BusReply noReply = err(QStringLiteral("org.freedesktop.DBus.Error.NoReply: no answer"));
    const BusReply restarting = err(QStringLiteral("org.freedesktop.DBus.Error.ServiceUnknown: restarting"));
    auto up = reads({noReply, restarting, ok({variant(u32(1))}), ok({variant(u32(2))})});
    EXPECT_EQ(awaitJoin(*up, QStringLiteral("/conn/new"), QStringLiteral("/active/1"), 5000, 1), QString());
    EXPECT_FALSE(up->members().contains(QStringLiteral("Connection.Delete")));

    // Unknown, then down: the join failed and its profile is deleted.
    auto down = reads({noReply, ok({variant(u32(4))})});
    EXPECT_EQ(awaitJoin(*down, QStringLiteral("/conn/new"), QStringLiteral("/active/1"), 5000, 1), QStringLiteral("the network could not be joined"));
    EXPECT_EQ(down->calls.last().member, QStringLiteral("Delete"));

    // Gone as GDBus says it too (no such interface on that path): failed.
    auto gone = reads({noReply, err(QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod: No such interface"))});
    EXPECT_EQ(awaitJoin(*gone, QStringLiteral("/conn/new"), QStringLiteral("/active/1"), 5000, 1), QStringLiteral("the network could not be joined"));
    EXPECT_EQ(gone->calls.last().member, QStringLiteral("Delete"));

    // Never readable until the deadline: the profile stays (it may still come up), and the answer says what is known.
    auto unknown = reads({});
    EXPECT_EQ(awaitJoin(*unknown, QStringLiteral("/conn/new"), QStringLiteral("/active/1"), 30, 1),
              QStringLiteral("the network's state could not be read: it may still be joining"));
    EXPECT_FALSE(unknown->members().contains(QStringLiteral("Connection.Delete")));
    EXPECT_GE(unknown->calls.size(), 2);

    // Still activating at the deadline: the join failed.
    QList<BusReply> activating;
    for (int i = 0; i < 1000; ++i)
        activating.append(ok({variant(u32(1))}));
    auto slow = reads(activating);
    EXPECT_EQ(awaitJoin(*slow, QStringLiteral("/conn/new"), QStringLiteral("/active/1"), 30, 1), QStringLiteral("the network could not be joined"));
    EXPECT_EQ(slow->calls.last().member, QStringLiteral("Delete"));

    // A cleanup Delete that fails is said, with its reason.
    auto refused = reads({ok({variant(u32(4))})}, false);
    EXPECT_EQ(awaitJoin(*refused, QStringLiteral("/conn/new"), QStringLiteral("/active/1"), 5000, 1),
              QStringLiteral("the network could not be joined, and its new settings could not be removed: not allowed: the system refused the request"));
    EXPECT_EQ(refused->calls.last().member, QStringLiteral("Delete"));
    EXPECT_EQ(refused->calls.last().timeoutMs, 120000);
}

TEST(SystemBusWifi, APassphraseIsEightToSixtyThreePrintableCharactersOrSixtyFourHexDigits)
{
    NmFixture f;
    const QString hex64(64, QLatin1Char('a'));
    EXPECT_TRUE(validAction({{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", "12345678"}}));
    EXPECT_TRUE(validAction({{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", QString(63, QLatin1Char('~'))}}));
    EXPECT_TRUE(validAction({{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", hex64}}));
    for (const QVariant &psk : {QVariant(QStringLiteral("1234567")), QVariant(QString(64, QLatin1Char('g'))), QVariant(QString(65, QLatin1Char('a'))),
                                QVariant(QStringLiteral("line\nbreak")), QVariant(QStringLiteral("caf\u00e9 au lait")), QVariant(12345678), QVariant()}) {
        f.bus.calls.clear();
        EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", psk}}), QStringLiteral("invalid request")) << qPrintable(psk.toString());
        EXPECT_TRUE(f.bus.calls.isEmpty());
    }
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectSecure"}, {"hex", "zz"}, {"psk", "12345678"}}), QStringLiteral("invalid request"));
    GuardedCaller dev(f.bus, true);
    f.bus.calls.clear();
    EXPECT_TRUE(runAction(dev, {{"op", "wifi.connectSecure"}, {"hex", "486F6D65"}, {"psk", "12345678"}}).startsWith(QStringLiteral("dev guard")));
    EXPECT_FALSE(f.bus.members().contains(QStringLiteral("NetworkManager.AddAndActivateConnection")));
}

TEST(SystemBusWifi, EnhancedOpenIsJoinedWithoutAPasswordAndWithKeyMgmtOwe)
{
    // OWE (rsn 0x888: OWE key management, CCMP; the privacy flag is set) needs no password: joined like an open network, but
    // NetworkManager needs key-mgmt owe in the profile. One that also offers SAE or PSK needs a password.
    NmFixture f;
    f.apProps[QStringLiteral("/ap/gone")] = {{"Ssid", QByteArray("Owe")}, {"Strength", u8(50)}, {"Flags", u32(1)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0x888)}};
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.connectOpen"}, {"hex", "4F7765"}}), QString());
    const Call c = f.bus.calls.last();
    ASSERT_EQ(c.member, QStringLiteral("AddAndActivateConnection"));
    ASSERT_GE(c.args.size(), 3);
    const ConnectionSettings settings = qvariant_cast<ConnectionSettings>(c.args[0]);
    EXPECT_EQ(settings["802-11-wireless-security"]["key-mgmt"].toString(), QStringLiteral("owe"));
    EXPECT_EQ(settings["802-11-wireless-security"].size(), 1) << "no secret in the profile";
    EXPECT_EQ(qvariant_cast<QDBusObjectPath>(c.args[2]).path(), QStringLiteral("/ap/gone"));
    // Not OWE alone: needs a password, never joined.
    for (uint rsn : {0x888u | 0x400u, 0x888u | 0x100u, 0x888u | 0x200u}) {
        NmFixture g;
        g.apProps[QStringLiteral("/ap/gone")] = {{"Ssid", QByteArray("Owe")}, {"Strength", u8(50)}, {"Flags", u32(1)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(rsn)}};
        EXPECT_EQ(runAction(g.bus, {{"op", "wifi.connectOpen"}, {"hex", "4F7765"}}), QStringLiteral("that network needs a password")) << rsn;
    }
    // OWE transition (rsn 0x1000 only, with or without the privacy flag): the open side is joined as open, no security section.
    for (uint flags : {0u, 1u}) {
        NmFixture t;
        t.apProps[QStringLiteral("/ap/gone")] = {{"Ssid", QByteArray("Owe")}, {"Strength", u8(50)}, {"Flags", u32(flags)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0x1000)}};
        EXPECT_EQ(runAction(t.bus, {{"op", "wifi.connectOpen"}, {"hex", "4F7765"}}), QString()) << flags;
        const Call tc = t.bus.calls.last();
        ASSERT_EQ(tc.member, QStringLiteral("AddAndActivateConnection"));
        ASSERT_GE(tc.args.size(), 3);
        EXPECT_FALSE(qvariant_cast<ConnectionSettings>(tc.args[0]).contains(QStringLiteral("802-11-wireless-security")));
        EXPECT_EQ(qvariant_cast<QDBusObjectPath>(tc.args[2]).path(), QStringLiteral("/ap/gone"));
    }
    // A cipher-only RSN element (no key management we know) is still a secured network, as the label says ("WPA").
    NmFixture u;
    u.apProps[QStringLiteral("/ap/gone")] = {{"Ssid", QByteArray("Owe")}, {"Strength", u8(50)}, {"Flags", u32(1)}, {"WpaFlags", u32(0)}, {"RsnFlags", u32(0x8)}};
    EXPECT_EQ(runAction(u.bus, {{"op", "wifi.connectOpen"}, {"hex", "4F7765"}}), QStringLiteral("that network needs a password"));
    // A plain open network has no security section.
    NmFixture h;
    EXPECT_EQ(runAction(h.bus, {{"op", "wifi.connectOpen"}, {"hex", "43616665"}}), QString());
    EXPECT_FALSE(qvariant_cast<ConnectionSettings>(h.bus.calls.last().args[0]).contains(QStringLiteral("802-11-wireless-security")));
}

TEST(SystemBusWifi, AFailedCallGivesTheServicesOwnShortReason)
{
    NmFixture f;
    const auto inner = f.bus.handler;
    f.bus.handler = [inner](const Call &c) {
        if (c.member == QLatin1String("ActivateConnection"))
            return err(QStringLiteral("org.freedesktop.NetworkManager.Device.NotActive: Connection\n activation failed: (3) the secrets were\x01 not provided"));
        if (c.member == QLatin1String("Set"))
            return err(QStringLiteral("org.freedesktop.NetworkManager.PermissionDenied: Not authorized to control networking."));
        return inner(c);
    };
    const QString r = runAction(f.bus, {{"op", "wifi.connectKnown"}, {"uuid", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}});
    EXPECT_EQ(r, QStringLiteral("Connection activation failed: (3) the secrets were not provided"));
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.radio"}, {"on", true}}), QStringLiteral("not allowed: the system refused the request"));
}

TEST(SystemBusActions, BadValuesNeverReachTheBus)
{
    FakeBus bus;
    const QList<QVariantMap> bad = {
        {},
        {{"op", "wifi.radio"}},
        {{"op", "wifi.radio"}, {"on", "yes"}},
        {{"op", "wifi.radio"}, {"on", 1}},
        {{"op", "wifi.connectKnown"}, {"uuid", "-x"}},
        {{"op", "wifi.connectKnown"}, {"uuid", "Home"}},
        {{"op", "wifi.connectOpen"}, {"hex", ""}},
        {{"op", "wifi.connectOpen"}, {"hex", "XYZ"}},
        {{"op", "wifi.connectOpen"}, {"hex", QString(66, QLatin1Char('A'))}}, // 33 bytes: no SSID is longer than 32
        {{"op", "bt.power"}, {"on", QVariant()}},
        {{"op", "bt.connect"}, {"mac", "not-a-mac"}, {"connect", true}},
        {{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF; ls"}, {"connect", true}},
        {{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF"}},
        {{"op", "wifi.forget"}},
        {{"op", "Properties.Set"}},
    };
    for (const QVariantMap &op : bad) {
        EXPECT_FALSE(validAction(op));
        EXPECT_EQ(runAction(bus, op), QStringLiteral("invalid request"));
    }
    EXPECT_TRUE(bus.calls.isEmpty());
    EXPECT_TRUE(validAction({{"op", "bt.connect"}, {"mac", "aa:bb:cc:dd:ee:ff"}, {"connect", false}}));
}

namespace
{
ManagedObjects bluez(bool powered = true, bool withAdapter = true)
{
    ManagedObjects o;
    if (withAdapter)
        o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0"))][QStringLiteral("org.bluez.Adapter1")] = {{"Address", QStringLiteral("00:11:22:33:44:55")}, {"Powered", powered},
                                                                                              {"Alias", QStringLiteral("gf-ref")}, {"Discovering", true}, {"Discoverable", false}};
    o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"))][QStringLiteral("org.bluez.Device1")] =
        {{"Address", QStringLiteral("aa:bb:cc:dd:ee:ff")}, {"Alias", QStringLiteral("Headphones")}, {"Name", QStringLiteral("WH-1000")}, {"Paired", true}, {"Connected", true},
         {"Icon", QStringLiteral("audio-headphones")}};
    o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"))][QStringLiteral("org.bluez.Battery1")] = {{"Percentage", QVariant::fromValue<uchar>(80)}};
    // In range and not paired: nearby, by its name; one with only an address-like alias and no name is not shown.
    o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0/dev_33_33_33_33_33_33"))][QStringLiteral("org.bluez.Device1")] =
        {{"Address", QStringLiteral("33:33:33:33:33:33")}, {"Alias", QStringLiteral("Keyboard K3")}, {"Name", QStringLiteral("Keyboard K3")}, {"Paired", false},
         {"Connected", false}, {"RSSI", QVariant::fromValue<short>(-48)}, {"Icon", QStringLiteral("input-keyboard")}};
    o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0/dev_44_44_44_44_44_44"))][QStringLiteral("org.bluez.Device1")] =
        {{"Address", QStringLiteral("44:44:44:44:44:44")}, {"Alias", QStringLiteral("44-44-44-44-44-44")}, {"Paired", false}, {"RSSI", QVariant::fromValue<short>(-70)}};
    o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0/dev_11_22_33_44_55_66"))][QStringLiteral("org.bluez.Device1")] =
        {{"Address", QStringLiteral("11:22:33:44:55:66")}, {"Name", QStringLiteral("Mouse")}, {"Paired", true}, {"Connected", false}};
    o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0/dev_66_66_66_66_66_66"))][QStringLiteral("org.bluez.Device1")] =
        {{"Address", QStringLiteral("66:66:66:66:66:66")}, {"Name", QStringLiteral("Seen only")}, {"Paired", false}, {"Connected", false}};
    o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0/dev_77_77_77_77_77_77"))][QStringLiteral("org.bluez.Device1")] =
        {{"Address", QStringLiteral("77:77:77:77:77:77")}, {"Paired", true}, {"Connected", false}};
    o[QDBusObjectPath(QStringLiteral("/org/bluez/hci0/dev_bad"))][QStringLiteral("org.bluez.Device1")] = {{"Address", QStringLiteral("not a mac")}, {"Paired", true}};
    return o;
}

struct BtFixture {
    FakeBus bus;
    ManagedObjects objects = bluez();
    BtFixture()
    {
        bus.handler = [this](const Call &c) {
            if (c.member == QLatin1String("GetManagedObjects"))
                return ok({QVariant::fromValue(objects)});
            if (c.member == QLatin1String("Set") || c.member == QLatin1String("Connect") || c.member == QLatin1String("Disconnect") || c.member == QLatin1String("Pair")
                || c.member == QLatin1String("RemoveDevice") || c.member == QLatin1String("StartDiscovery") || c.member == QLatin1String("StopDiscovery"))
                return ok();
            return err(QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod: ") + c.member);
        };
    }
};
} // namespace

TEST(SystemBusBluetooth, StateListsThePairedDevicesOnly)
{
    BtFixture f;
    const StateResult r = bluetoothState(f.bus);
    ASSERT_TRUE(r.ok);
    EXPECT_TRUE(r.json["present"].toBool());
    EXPECT_TRUE(r.json["powered"].toBool());
    QMap<QString, QString> names;
    QMap<QString, bool> connected;
    for (const QJsonValue v : r.json["devices"].toArray()) {
        names[v["mac"].toString()] = v["name"].toString();
        connected[v["mac"].toString()] = v["connected"].toBool();
    }
    EXPECT_EQ(names.size(), 3); // not the unpaired one, not the one with a bad address
    EXPECT_EQ(names["AA:BB:CC:DD:EE:FF"], QStringLiteral("Headphones")); // the alias wins
    EXPECT_EQ(names["11:22:33:44:55:66"], QStringLiteral("Mouse"));      // else the name
    EXPECT_EQ(names["77:77:77:77:77:77"], QStringLiteral("77:77:77:77:77:77")); // else the address
    EXPECT_TRUE(connected["AA:BB:CC:DD:EE:FF"]);
    EXPECT_FALSE(connected["11:22:33:44:55:66"]);
    // The adapter's name and discovery; a device's icon and battery (-1 when BlueZ has none).
    EXPECT_EQ(r.json["alias"].toString(), QStringLiteral("gf-ref"));
    EXPECT_TRUE(r.json["discovering"].toBool());
    EXPECT_FALSE(r.json["discoverable"].toBool());
    for (const QJsonValue v : r.json["devices"].toArray()) {
        if (v["mac"].toString() == QLatin1String("AA:BB:CC:DD:EE:FF")) {
            EXPECT_EQ(v["icon"].toString(), QStringLiteral("audio-headphones"));
            EXPECT_EQ(v["battery"].toInt(), 80);
        } else {
            EXPECT_EQ(v["battery"].toInt(), -1);
        }
    }
    // Nearby: the unpaired device in range with a name; not the one seen earlier (no RSSI), not the nameless one.
    const QJsonArray nearby = r.json["nearby"].toArray();
    ASSERT_EQ(nearby.size(), 1);
    EXPECT_EQ(nearby[0]["mac"].toString(), QStringLiteral("33:33:33:33:33:33"));
    EXPECT_EQ(nearby[0]["name"].toString(), QStringLiteral("Keyboard K3"));
    EXPECT_EQ(nearby[0]["icon"].toString(), QStringLiteral("input-keyboard"));
    EXPECT_EQ(nearby[0]["rssi"].toInt(), -48);
    for (const Call &c : f.bus.calls)
        EXPECT_TRUE(isReadOnlyCall(c.service, c.iface, c.member, c.args));
}

TEST(SystemBusBluetooth, PairingTrustsAndConnectsTheNearbyDevice)
{
    BtFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.pair"}, {"mac", "33:33:33:33:33:33"}}), QString());
    QStringList members;
    for (const Call &c : f.bus.calls) {
        if (c.member != QLatin1String("GetManagedObjects"))
            members << c.member + QLatin1Char(' ') + c.path.section(QLatin1Char('/'), -1);
    }
    EXPECT_EQ(members, (QStringList{QStringLiteral("Pair dev_33_33_33_33_33_33"), QStringLiteral("Set dev_33_33_33_33_33_33"), QStringLiteral("Connect dev_33_33_33_33_33_33")}));
    const auto pair = std::find_if(f.bus.calls.cbegin(), f.bus.calls.cend(), [](const Call &c) { return c.member == QLatin1String("Pair"); });
    EXPECT_EQ(pair->timeoutMs, 120000); // the device may ask its user first
    const auto trust = std::find_if(f.bus.calls.cbegin(), f.bus.calls.cend(), [](const Call &c) { return c.member == QLatin1String("Set"); });
    EXPECT_EQ(trust->args[1].toString(), QStringLiteral("Trusted"));
    EXPECT_TRUE(qvariant_cast<QDBusVariant>(trust->args[2]).variant().toBool());
    EXPECT_TRUE(privilegedAction({{"op", "bt.pair"}}));
    // Already paired: trusted and connected, no second Pair.
    f.bus.calls.clear();
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.pair"}, {"mac", "11:22:33:44:55:66"}}), QString());
    for (const Call &c : f.bus.calls)
        EXPECT_NE(c.member, QStringLiteral("Pair"));
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.pair"}, {"mac", "01:02:03:04:05:06"}}), QStringLiteral("that device is no longer nearby"));
    // A refusal (a device that wants a PIN) gives BlueZ's reason and connects nothing.
    BtFixture g;
    g.bus.handler = [&g](const Call &c) {
        if (c.member == QLatin1String("GetManagedObjects"))
            return ok({QVariant::fromValue(g.objects)});
        return err(QStringLiteral("org.bluez.Error.AuthenticationFailed: Authentication Failed"));
    };
    EXPECT_EQ(runAction(g.bus, {{"op", "bt.pair"}, {"mac", "33:33:33:33:33:33"}}), QStringLiteral("Authentication Failed"));
    for (const Call &c : g.bus.calls)
        EXPECT_NE(c.member, QStringLiteral("Connect"));
}

TEST(SystemBusBluetooth, DiscoveryAndForgetMakeExactlyTheirCalls)
{
    BtFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.discover"}, {"on", true}}), QString());
    EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("StartDiscovery"));
    EXPECT_EQ(f.bus.calls.last().path, QStringLiteral("/org/bluez/hci0"));
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.discover"}, {"on", false}}), QString());
    EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("StopDiscovery"));
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.forget"}, {"mac", "11:22:33:44:55:66"}}), QString());
    EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("RemoveDevice"));
    EXPECT_EQ(f.bus.calls.last().path, QStringLiteral("/org/bluez/hci0"));
    EXPECT_EQ(qvariant_cast<QDBusObjectPath>(f.bus.calls.last().args[0]).path(), QStringLiteral("/org/bluez/hci0/dev_11_22_33_44_55_66"));
    // A discovery that already runs (or already stopped) is not a failure.
    BtFixture g;
    g.bus.handler = [&g](const Call &c) {
        if (c.member == QLatin1String("GetManagedObjects"))
            return ok({QVariant::fromValue(g.objects)});
        return err(QStringLiteral("org.bluez.Error.InProgress: Operation already in progress"));
    };
    EXPECT_EQ(runAction(g.bus, {{"op", "bt.discover"}, {"on", true}}), QString());
    // Bad values never reach the bus; a dev session sends none of these.
    for (const QVariantMap &op : {QVariantMap{{"op", "bt.pair"}, {"mac", "nope"}}, QVariantMap{{"op", "bt.forget"}, {"mac", "11:22:33:44:55"}},
                                  QVariantMap{{"op", "bt.discover"}, {"on", "yes"}}}) {
        f.bus.calls.clear();
        EXPECT_EQ(runAction(f.bus, op), QStringLiteral("invalid request"));
        EXPECT_TRUE(f.bus.calls.isEmpty());
    }
    GuardedCaller dev(f.bus, true);
    f.bus.calls.clear();
    for (const QVariantMap &op : {QVariantMap{{"op", "bt.pair"}, {"mac", "33:33:33:33:33:33"}}, QVariantMap{{"op", "bt.forget"}, {"mac", "11:22:33:44:55:66"}},
                                  QVariantMap{{"op", "bt.discover"}, {"on", true}}})
        EXPECT_TRUE(runAction(dev, op).startsWith(QStringLiteral("dev guard"))) << qPrintable(op.value("op").toString());
    for (const Call &c : f.bus.calls)
        EXPECT_EQ(c.member, QStringLiteral("GetManagedObjects"));
}

TEST(SystemBusBluetooth, NoAdapterAndAStoppedServiceAreTold)
{
    BtFixture f;
    f.objects = bluez(true, false);
    const StateResult none = bluetoothState(f.bus);
    ASSERT_TRUE(none.ok);
    EXPECT_FALSE(none.json["present"].toBool());
    EXPECT_EQ(none.json["devices"].toArray().size(), 0);
    FakeBus off;
    const StateResult stopped = bluetoothState(off);
    EXPECT_FALSE(stopped.ok);
    EXPECT_EQ(stopped.error, QStringLiteral("the service is not running"));
}

TEST(SystemBusBluetooth, ActionsMakeExactlyTheirCalls)
{
    BtFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.power"}, {"on", false}}), QString());
    Call c = f.bus.calls.last();
    EXPECT_EQ(c.member, QStringLiteral("Set"));
    EXPECT_EQ(c.path, QStringLiteral("/org/bluez/hci0"));
    EXPECT_EQ(c.args[0].toString(), QStringLiteral("org.bluez.Adapter1"));
    EXPECT_EQ(c.args[1].toString(), QStringLiteral("Powered"));
    EXPECT_FALSE(qvariant_cast<QDBusVariant>(c.args[2]).variant().toBool());
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF"}, {"connect", false}}), QString());
    c = f.bus.calls.last();
    EXPECT_EQ(c.member, QStringLiteral("Disconnect"));
    EXPECT_EQ(c.path, QStringLiteral("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"));
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.connect"}, {"mac", "11:22:33:44:55:66"}, {"connect", true}}), QString());
    EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("Connect"));
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.connect"}, {"mac", "01:02:03:04:05:06"}, {"connect", true}}), QStringLiteral("that device is no longer paired"));
    f.objects = bluez(true, false);
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.power"}, {"on", true}}), QStringLiteral("no Bluetooth adapter"));
}

TEST(SystemBusBluetooth, ADeviceThatIsNotPairedIsNeverConnected)
{
    // macOS pairs first; Settings has no pairing agent: a seen-but-unpaired device is refused with a reason, and no Connect is sent.
    BtFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.connect"}, {"mac", "66:66:66:66:66:66"}, {"connect", true}}), QStringLiteral("that device is not paired yet"));
    for (const Call &c : f.bus.calls)
        EXPECT_NE(c.member, QStringLiteral("Connect"));
}

TEST(SystemBusBluetooth, AFailedConnectGivesTheServicesReason)
{
    BtFixture f;
    f.bus.handler = [&f](const Call &c) {
        if (c.member == QLatin1String("GetManagedObjects"))
            return ok({QVariant::fromValue(f.objects)});
        return err(QStringLiteral("org.bluez.Error.Failed: Software caused connection abort"));
    };
    EXPECT_EQ(runAction(f.bus, {{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF"}, {"connect", true}}), QStringLiteral("Software caused connection abort"));
}

TEST(SystemBusGuard, ADevSessionSendsReadsAndNothingElse)
{
    NmFixture f;
    GuardedCaller dev(f.bus, true);
    EXPECT_TRUE(wifiState(dev).ok);
    const int reads = f.bus.calls.size();
    for (const QVariantMap &op : QList<QVariantMap>{{{"op", "wifi.radio"}, {"on", false}},
                                                     {{"op", "wifi.connectKnown"}, {"uuid", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}},
                                                     {{"op", "wifi.connectOpen"}, {"hex", "43616665"}},
                                                     {{"op", "wifi.disconnect"}},
                                                     {{"op", "wifi.scan"}}}) {
        const QString reason = runAction(dev, op);
        EXPECT_FALSE(reason.isEmpty()) << op.value("op").toString().toStdString();
    }
    BtFixture b;
    GuardedCaller devBt(b.bus, true);
    EXPECT_TRUE(bluetoothState(devBt).ok);
    for (const QVariantMap &op : QList<QVariantMap>{{{"op", "bt.power"}, {"on", false}}, {{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF"}, {"connect", true}}})
        EXPECT_FALSE(runAction(devBt, op).isEmpty());
    // Nothing but reads reached either bus.
    for (int i = reads; i < f.bus.calls.size(); ++i)
        EXPECT_TRUE(isReadOnlyCall(f.bus.calls[i].service, f.bus.calls[i].iface, f.bus.calls[i].member, f.bus.calls[i].args)) << f.bus.calls[i].member.toStdString();
    for (const Call &c : b.bus.calls)
        EXPECT_TRUE(isReadOnlyCall(c.service, c.iface, c.member, c.args)) << c.member.toStdString();
    // A real session passes the actions through.
    NmFixture real;
    GuardedCaller session(real.bus, false);
    EXPECT_EQ(runAction(session, {{"op", "wifi.disconnect"}}), QString());
}

TEST(SystemBusGuard, TheReadOnlyListIsExact)
{
    const QString nm = QStringLiteral("org.freedesktop.NetworkManager");
    const QString props = QStringLiteral("org.freedesktop.DBus.Properties");
    EXPECT_TRUE(isReadOnlyCall(nm, props, QStringLiteral("Get"), {}));
    EXPECT_TRUE(isReadOnlyCall(nm, props, QStringLiteral("GetAll"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, props, QStringLiteral("Set"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, nm, QStringLiteral("ActivateConnection"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, nm, QStringLiteral("AddAndActivateConnection"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, QStringLiteral("org.freedesktop.NetworkManager.Device"), QStringLiteral("Disconnect"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, QStringLiteral("org.freedesktop.NetworkManager.Device.Wireless"), QStringLiteral("RequestScan"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, QStringLiteral("org.freedesktop.NetworkManager.Settings.Connection"), QStringLiteral("Delete"), {}));
    EXPECT_FALSE(isReadOnlyCall(nm, QStringLiteral("org.freedesktop.NetworkManager.Settings.Connection"), QStringLiteral("GetSecrets"), {}));
    EXPECT_TRUE(isReadOnlyCall(nm, QStringLiteral("org.freedesktop.NetworkManager.Settings.Connection"), QStringLiteral("GetSettings"), {}));
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.bluez"), QStringLiteral("org.bluez.Device1"), QStringLiteral("Connect"), {}));
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.bluez"), QStringLiteral("org.bluez.Adapter1"), QStringLiteral("RemoveDevice"), {}));
    EXPECT_TRUE(isReadOnlyCall(QStringLiteral("org.bluez"), QStringLiteral("org.freedesktop.DBus.ObjectManager"), QStringLiteral("GetManagedObjects"), {}));
    // Another service is never a read of ours.
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.freedesktop.login1"), props, QStringLiteral("Get"), {}));
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.freedesktop.systemd1"), QStringLiteral("org.freedesktop.systemd1.Manager"), QStringLiteral("Reboot"), {}));
}

TEST(SystemBusReason, IsShortOneLineAndPlain)
{
    EXPECT_EQ(reasonOf(QStringLiteral("org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable")), QStringLiteral("the service is not running"));
    EXPECT_EQ(reasonOf(QStringLiteral("org.freedesktop.DBus.Error.NameHasNoOwner: x")), QStringLiteral("the service is not running"));
    EXPECT_EQ(reasonOf(QStringLiteral("org.freedesktop.DBus.Error.AccessDenied: no")), QStringLiteral("not allowed: the system refused the request"));
    EXPECT_EQ(reasonOf(QStringLiteral("org.bluez.Error.Failed: line one\nline two")), QStringLiteral("line one line two"));
    EXPECT_LE(reasonOf(QStringLiteral("org.x.Error: ") + QString(500, QLatin1Char('a'))).size(), 160);
    EXPECT_EQ(reasonOf(QString()), QString());
}

// ---- General (PR #6, ADR-0030): hostname1, timedate1 / timesync1, locale1 on the system bus; the user's services on the session bus.

namespace
{
const QString kHost = QStringLiteral("org.freedesktop.hostname1");
const QString kTime = QStringLiteral("org.freedesktop.timedate1");
const QString kSync = QStringLiteral("org.freedesktop.timesync1");
const QString kSystemdName = QStringLiteral("org.freedesktop.systemd1");

// hostname1, timedate1 and timesync1 answering GetAll; every other call succeeds with no value.
struct GeneralFixture {
    FakeBus bus;
    bool timesync = true;
    GeneralFixture()
    {
        bus.handler = [this](const Call &c) -> BusReply {
            if (c.member == QLatin1String("GetAll") && c.service == kHost)
                return ok({QVariantMap{{"PrettyHostname", "Alex\x01's Laptop"}, {"StaticHostname", "alexs-laptop"}, {"Hostname", "alexs-laptop"},
                                       {"Chassis", "laptop"}, {"HardwareVendor", "LENOVO"}, {"HardwareModel", "ThinkPad X1 Carbon Gen 11"}}});
            if (c.member == QLatin1String("GetAll") && c.service == kTime)
                return ok({QVariantMap{{"Timezone", "Europe/Paris"}, {"NTP", true}, {"CanNTP", true}, {"NTPSynchronized", true}, {"LocalRTC", false},
                                       {"TimeUSec", QVariant::fromValue<qulonglong>(1792832460123456ULL)}}});
            if (c.member == QLatin1String("GetAll") && c.service == kSync)
                return timesync ? ok({QVariantMap{{"LinkNTPServers", QStringList{}}, {"SystemNTPServers", QStringList{"time.example.org"}},
                                                  {"FallbackNTPServers", QStringList{"0.arch.pool.ntp.org", "time.example.org"}}, {"ServerName", "time.example.org"}}})
                                : err(QStringLiteral("org.freedesktop.DBus.Error.ServiceUnknown: not activatable"));
            if (c.member == QLatin1String("ListTimezones"))
                return ok({QStringList{"Europe/Paris", "America/New_York", "../etc/passwd", "UTC"}});
            if (c.member == QLatin1String("ListUnitFilesByPatterns"))
                // One argument, the a(ss) array (QVariantList{QVariant(...)}: a braced QVariantList alone would be copied, not wrapped).
                return ok(QVariantList{QVariant(QVariantList{QVariantList{"/home/u/.config/systemd/user/sync.service", "enabled"},
                                        QVariantList{"/home/u/.config/systemd/user/backup.service", "disabled"},
                                        QVariantList{"/home/u/.config/systemd/user/sub/x.service", "enabled"},
                                        QVariantList{"/usr/lib/systemd/user/pipewire.service", "enabled"},
                                        QVariantList{"/home/u/.local/share/systemd/user/mine.service", "enabled"}})});
            return ok();
        };
    }
};

const QStringList kOwn{QStringLiteral("/home/u/.config/systemd/user"), QStringLiteral("/home/u/.local/share/systemd/user")};
} // namespace

TEST(SystemBusGeneral, HostStateIsHostname1sNamesAndHardware)
{
    GeneralFixture f;
    const StateResult r = hostState(f.bus);
    ASSERT_TRUE(r.ok);
    EXPECT_EQ(r.json.value("pretty").toString(), QStringLiteral("Alex's Laptop")); // the control character is dropped
    EXPECT_EQ(r.json.value("static").toString(), QStringLiteral("alexs-laptop"));
    EXPECT_EQ(r.json.value("chassis").toString(), QStringLiteral("laptop"));
    EXPECT_EQ(r.json.value("vendor").toString(), QStringLiteral("LENOVO"));
    EXPECT_EQ(r.json.value("model").toString(), QStringLiteral("ThinkPad X1 Carbon Gen 11"));
}

TEST(SystemBusGeneral, RenamingSetsThePrettyThenTheStaticNameInteractively)
{
    GeneralFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "host.setName"}, {"name", QStringLiteral("  Alex’s ThinkPad X1  ")}}), QString());
    ASSERT_EQ(f.bus.calls.size(), 2);
    EXPECT_EQ(f.bus.calls[0].member, QStringLiteral("SetPrettyHostname"));
    EXPECT_EQ(f.bus.calls[0].args, (QVariantList{QStringLiteral("Alex’s ThinkPad X1"), true}));
    EXPECT_EQ(f.bus.calls[1].member, QStringLiteral("SetStaticHostname"));
    EXPECT_EQ(f.bus.calls[1].args, (QVariantList{QStringLiteral("alex-s-thinkpad-x1"), true}));
    // A name with nothing usable for a host name sets the pretty name only.
    GeneralFixture g;
    EXPECT_EQ(runAction(g.bus, {{"op", "host.setName"}, {"name", QStringLiteral("☃☃")}}), QString());
    EXPECT_EQ(g.bus.members(), QStringList{QStringLiteral("hostname1.SetPrettyHostname")});
}

TEST(SystemBusGeneral, HostNamesFollowHostname1sRules)
{
    EXPECT_EQ(hostNameFor(QStringLiteral("Grassfield Reference")), QStringLiteral("grassfield-reference"));
    EXPECT_EQ(hostNameFor(QStringLiteral("--Été 2026!!--")), QStringLiteral("t-2026"));
    EXPECT_EQ(hostNameFor(QString(100, QLatin1Char('a'))).size(), 63);
    EXPECT_EQ(hostNameFor(QString(62, QLatin1Char('a')) + QStringLiteral(" b")), QString(62, QLatin1Char('a')));
    EXPECT_EQ(hostNameFor(QStringLiteral("!!!")), QString());
}

TEST(SystemBusGeneral, TimeStateReadsTimedate1AndTheServers)
{
    GeneralFixture f;
    const StateResult r = timeState(f.bus);
    ASSERT_TRUE(r.ok);
    EXPECT_EQ(r.json.value("zone").toString(), QStringLiteral("Europe/Paris"));
    EXPECT_TRUE(r.json.value("ntp").toBool());
    EXPECT_TRUE(r.json.value("synced").toBool());
    EXPECT_EQ(r.json.value("usec").toString(), QStringLiteral("1792832460123456"));
    EXPECT_EQ(r.json.value("server").toString(), QStringLiteral("time.example.org"));
    EXPECT_EQ(r.json.value("servers").toArray().size(), 2); // without duplicates
    // Without timesyncd the time still reads; the source is unknown.
    GeneralFixture g;
    g.timesync = false;
    const StateResult s = timeState(g.bus);
    ASSERT_TRUE(s.ok);
    EXPECT_EQ(s.json.value("servers").toArray().size(), 0);
    // The zone list keeps only zone names.
    const StateResult z = timeZones(f.bus);
    ASSERT_TRUE(z.ok);
    EXPECT_EQ(z.json.value("zones").toArray().size(), 3);
}

TEST(SystemBusGeneral, TimeActionsAreInteractiveTimedate1Calls)
{
    GeneralFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "time.ntp"}, {"on", false}}), QString());
    EXPECT_EQ(runAction(f.bus, {{"op", "time.zone"}, {"zone", "America/New_York"}}), QString());
    EXPECT_EQ(runAction(f.bus, {{"op", "time.set"}, {"usec", "1792832460000000"}}), QString());
    ASSERT_EQ(f.bus.calls.size(), 3);
    EXPECT_EQ(f.bus.calls[0].member, QStringLiteral("SetNTP"));
    EXPECT_EQ(f.bus.calls[0].args, (QVariantList{false, true}));
    EXPECT_EQ(f.bus.calls[1].member, QStringLiteral("SetTimezone"));
    EXPECT_EQ(f.bus.calls[1].args, (QVariantList{QStringLiteral("America/New_York"), true}));
    EXPECT_EQ(f.bus.calls[2].member, QStringLiteral("SetTime"));
    EXPECT_EQ(f.bus.calls[2].args, (QVariantList{QVariant::fromValue<qint64>(1792832460000000LL), false, true}));
    for (const Call &c : f.bus.calls)
        EXPECT_EQ(c.service, kTime);
    EXPECT_TRUE(privilegedAction({{"op", "time.zone"}}));
    EXPECT_TRUE(privilegedAction({{"op", "host.setName"}}));
    EXPECT_FALSE(privilegedAction({{"op", "user.enable"}}));
    EXPECT_TRUE(sessionAction({{"op", "user.enable"}}));
    EXPECT_FALSE(sessionAction({{"op", "time.ntp"}}));
}

TEST(SystemBusGeneral, BadValuesNeverReachTheBus)
{
    GeneralFixture f;
    const QList<QVariantMap> bad{
        {{"op", "host.setName"}, {"name", QString()}},
        {{"op", "host.setName"}, {"name", QStringLiteral("   ")}},
        {{"op", "host.setName"}, {"name", QString(65, QLatin1Char('x'))}},
        {{"op", "host.setName"}, {"name", QStringLiteral("two\nlines")}},
        {{"op", "host.setName"}, {"name", 42}},
        {{"op", "time.ntp"}, {"on", "true"}},
        {{"op", "time.zone"}, {"zone", "../../etc/passwd"}},
        {{"op", "time.zone"}, {"zone", "Europe/Paris\n"}},
        {{"op", "time.zone"}, {"zone", QString(65, QLatin1Char('a'))}},
        {{"op", "time.set"}, {"usec", "123"}},
        {{"op", "time.set"}, {"usec", "99999999999999999"}},
        {{"op", "time.set"}, {"usec", QVariant::fromValue<qlonglong>(1792832460000000LL)}},
        {{"op", "time.set"}, {"usec", "1792832460000000; reboot"}},
        {{"op", "user.enable"}, {"unit", "../x.service"}, {"on", true}},
        {{"op", "user.enable"}, {"unit", "x.timer"}, {"on", true}},
        {{"op", "user.enable"}, {"unit", "x.service"}, {"on", 1}},
        {{"op", "user.enable"}, {"unit", "x.service\n"}, {"on", true}},
        {{"op", "time.set"}, {"usec", "1792832460000000\n"}},
    };
    for (const QVariantMap &op : bad) {
        EXPECT_FALSE(validAction(op)) << op.value("op").toString().toStdString();
        EXPECT_FALSE(runAction(f.bus, op).isEmpty());
    }
    EXPECT_TRUE(f.bus.calls.isEmpty());
    // The older shapes are anchored as well: a final newline is not part of a MAC, an SSID or a UUID.
    EXPECT_FALSE(validAction({{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF\n"}, {"connect", true}}));
    EXPECT_FALSE(validAction({{"op", "wifi.connectOpen"}, {"hex", "43616665\n"}}));
    EXPECT_FALSE(validAction({{"op", "wifi.connectKnown"}, {"uuid", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0\n"}}));
    EXPECT_TRUE(validAction({{"op", "bt.connect"}, {"mac", "AA:BB:CC:DD:EE:FF"}, {"connect", true}}));
}

TEST(SystemBusGeneral, OnlyTheUsersOwnServicesAreListedAndSwitched)
{
    GeneralFixture f;
    const StateResult r = userUnits(f.bus, kOwn);
    ASSERT_TRUE(r.ok);
    QStringList units;
    for (const QJsonValue &u : r.json.value("units").toArray())
        units << u.toObject().value("unit").toString();
    EXPECT_EQ(units, (QStringList{"sync.service", "backup.service", "mine.service"})); // not a package's, not a sub-folder's
    f.bus.calls.clear();
    EXPECT_EQ(runAction(f.bus, {{"op", "user.enable"}, {"unit", "backup.service"}, {"on", true}}, kOwn), QString());
    EXPECT_EQ(f.bus.members(), (QStringList{"Manager.ListUnitFilesByPatterns", "Manager.EnableUnitFiles", "Manager.Reload"}));
    EXPECT_EQ(f.bus.calls[1].args, (QVariantList{QStringList{"backup.service"}, false, false}));
    f.bus.calls.clear();
    EXPECT_EQ(runAction(f.bus, {{"op", "user.enable"}, {"unit", "sync.service"}, {"on", false}}, kOwn), QString());
    EXPECT_EQ(f.bus.calls[1].member, QStringLiteral("DisableUnitFiles"));
    EXPECT_EQ(f.bus.calls[1].args, (QVariantList{QStringList{"sync.service"}, false}));
    // A unit a package ships is never switched, nor one that is not there.
    f.bus.calls.clear();
    EXPECT_FALSE(runAction(f.bus, {{"op", "user.enable"}, {"unit", "pipewire.service"}, {"on", false}}, kOwn).isEmpty());
    EXPECT_FALSE(runAction(f.bus, {{"op", "user.enable"}, {"unit", "x.service"}, {"on", false}}, kOwn).isEmpty());
    EXPECT_EQ(f.bus.members(), (QStringList{"Manager.ListUnitFilesByPatterns", "Manager.ListUnitFilesByPatterns"}));
}

TEST(SystemBusGeneral, ADevSessionReadsButNeverChangesTheSystem)
{
    GeneralFixture f;
    GuardedCaller dev(f.bus, true);
    EXPECT_TRUE(hostState(dev).ok);
    EXPECT_TRUE(timeState(dev).ok);
    EXPECT_TRUE(timeZones(dev).ok);
    EXPECT_TRUE(userUnits(dev, kOwn).ok);
    for (const QVariantMap &op : QList<QVariantMap>{{{"op", "host.setName"}, {"name", "x"}},
                                                     {{"op", "time.ntp"}, {"on", false}},
                                                     {{"op", "time.zone"}, {"zone", "UTC"}},
                                                     {{"op", "time.set"}, {"usec", "1792832460000000"}},
                                                     {{"op", "user.enable"}, {"unit", "sync.service"}, {"on", false}}})
        EXPECT_FALSE(runAction(dev, op, kOwn).isEmpty()) << op.value("op").toString().toStdString();
    for (const Call &c : f.bus.calls)
        EXPECT_TRUE(isReadOnlyCall(c.service, c.iface, c.member, c.args)) << c.member.toStdString();
    const QString props = QStringLiteral("org.freedesktop.DBus.Properties");
    EXPECT_FALSE(isReadOnlyCall(kHost, kHost, QStringLiteral("SetStaticHostname"), {}));
    EXPECT_FALSE(isReadOnlyCall(kTime, kTime, QStringLiteral("SetTimezone"), {}));
    EXPECT_FALSE(isReadOnlyCall(kTime, props, QStringLiteral("Set"), {}));
    EXPECT_FALSE(isReadOnlyCall(kSystemdName, QStringLiteral("org.freedesktop.systemd1.Manager"), QStringLiteral("EnableUnitFiles"), {}));
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.freedesktop.locale1"), QStringLiteral("org.freedesktop.locale1"), QStringLiteral("SetLocale"), {}));
    EXPECT_TRUE(isReadOnlyCall(kTime, kTime, QStringLiteral("ListTimezones"), {}));
}

// ---- Network (the Hardware group): devices with their addresses, VPN profiles, Forget, VPN on and off ----
namespace
{
// A NetworkManager with a connected Wi-Fi device (addresses, router, DNS, bitrate, the access point's frequency), a disconnected
// Ethernet device, a loopback that is not listed, a saved Wi-Fi profile, a WireGuard profile that is up and an OpenVPN one that
// is down.
struct NetFixture {
    FakeBus bus;
    NetFixture()
    {
        bus.handler = [](const Call &c) -> BusReply {
            const QString m = c.member, target = c.args.value(0).toString();
            if (m == QLatin1String("GetDevices"))
                return ok({paths({QStringLiteral("/dev/wlan0"), QStringLiteral("/dev/eth0"), QStringLiteral("/dev/lo")})});
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.Device")) {
                if (c.path == QLatin1String("/dev/wlan0"))
                    return ok({QVariant::fromValue(QVariantMap{{"DeviceType", u32(2)}, {"Interface", QStringLiteral("wlan0")}, {"State", u32(100)},
                                                               {"HwAddress", QStringLiteral("AA:BB:CC:00:11:22")}, {"ActiveConnection", path(QStringLiteral("/active/1"))},
                                                               {"Ip4Config", path(QStringLiteral("/ip4/1"))}, {"Ip6Config", path(QStringLiteral("/ip6/1"))}})});
                if (c.path == QLatin1String("/dev/eth0"))
                    return ok({QVariant::fromValue(QVariantMap{{"DeviceType", u32(1)}, {"Interface", QStringLiteral("eth0")}, {"State", u32(30)},
                                                               {"HwAddress", QStringLiteral("AA:BB:CC:00:11:33")}, {"ActiveConnection", path(QStringLiteral("/"))}})});
                return ok({QVariantMap{{"DeviceType", u32(32)}, {"Interface", QStringLiteral("lo")}, {"State", u32(100)}}});
            }
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.IP4Config"))
                return ok({QVariant::fromValue(QVariantMap{{"AddressData", QVariantList{QVariantMap{{"address", QStringLiteral("192.168.1.42")}, {"prefix", u32(24)}}}},
                                                           {"Gateway", QStringLiteral("192.168.1.1")},
                                                           {"NameserverData", QVariantList{QVariantMap{{"address", QStringLiteral("192.168.1.1")}}, QVariantMap{{"address", QStringLiteral("9.9.9.9")}}}}})});
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.IP6Config"))
                return ok({QVariant::fromValue(QVariantMap{{"AddressData", QVariantList{QVariantMap{{"address", QStringLiteral("fe80::1")}, {"prefix", u32(64)}}}},
                                                           {"Gateway", QString()}})});
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.Device.Wireless"))
                return ok({QVariant::fromValue(QVariantMap{{"Bitrate", u32(866700)}, {"ActiveAccessPoint", path(QStringLiteral("/ap/1"))}})});
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.AccessPoint"))
                return ok({QVariant::fromValue(QVariantMap{{"Frequency", u32(5180)}, {"Ssid", QByteArray("Home")}})});
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.NetworkManager.Connection.Active")) {
                if (c.path == QLatin1String("/active/1"))
                    return ok({QVariant::fromValue(QVariantMap{{"Id", QStringLiteral("Home")}, {"Uuid", QStringLiteral("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")}, {"State", u32(2)}})});
                return ok({QVariant::fromValue(QVariantMap{{"Id", QStringLiteral("Office")}, {"Uuid", QStringLiteral("AAAAAAAA-0000-0000-0000-000000000001")}, {"State", u32(2)}})});
            }
            if (m == QLatin1String("Get") && c.args.value(1).toString() == QLatin1String("Speed"))
                return ok({variant(u32(1000))});
            // systemd: ufw is not installed, firewalld is (and active).
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.systemd1.Unit")) {
                if (c.path.endsWith(QLatin1String("/ufw_2eservice")))
                    return ok({QVariant::fromValue(QVariantMap{{"LoadState", QStringLiteral("not-found")}, {"ActiveState", QStringLiteral("inactive")}})});
                return ok({QVariant::fromValue(QVariantMap{{"LoadState", QStringLiteral("loaded")}, {"ActiveState", QStringLiteral("active")}})});
            }
            if (m == QLatin1String("Get") && c.args.value(1).toString() == QLatin1String("ActiveConnections"))
                return ok({variant(QVariant::fromValue(QList<QDBusObjectPath>{QDBusObjectPath(QStringLiteral("/active/1")), QDBusObjectPath(QStringLiteral("/active/2"))}))});
            if (m == QLatin1String("ListConnections"))
                return ok({paths({QStringLiteral("/conn/1"), QStringLiteral("/conn/2"), QStringLiteral("/conn/3")})});
            if (m == QLatin1String("GetSettings")) {
                ConnectionSettings s;
                if (c.path == QLatin1String("/conn/1"))
                    s[QStringLiteral("connection")] = {{"type", QStringLiteral("802-11-wireless")}, {"uuid", QStringLiteral("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")}, {"id", QStringLiteral("Home")}};
                else if (c.path == QLatin1String("/conn/2"))
                    s[QStringLiteral("connection")] = {{"type", QStringLiteral("wireguard")}, {"uuid", QStringLiteral("aaaaaaaa-0000-0000-0000-000000000001")}, {"id", QStringLiteral("Office")}};
                else
                    s[QStringLiteral("connection")] = {{"type", QStringLiteral("vpn")}, {"uuid", QStringLiteral("bbbbbbbb-0000-0000-0000-000000000002")}, {"id", QStringLiteral("Travel")}};
                return ok({QVariant::fromValue(s)});
            }
            if (m == QLatin1String("Delete") || m == QLatin1String("ActivateConnection") || m == QLatin1String("DeactivateConnection"))
                return ok();
            return err(QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod: ") + m);
        };
    }
};
} // namespace

TEST(SystemBusNetwork, StateListsEthernetAndWifiWithTheirAddressesAndTheVpns)
{
    NetFixture f;
    const StateResult r = networkState(f.bus);
    ASSERT_TRUE(r.ok) << r.error.toStdString();
    const QJsonArray devices = r.json["devices"].toArray();
    ASSERT_EQ(devices.size(), 2); // not the loopback
    const QJsonObject wifi = devices[0].toObject();
    EXPECT_EQ(wifi["type"].toString(), QStringLiteral("wifi"));
    EXPECT_EQ(wifi["state"].toString(), QStringLiteral("connected"));
    EXPECT_EQ(wifi["mac"].toString(), QStringLiteral("AA:BB:CC:00:11:22"));
    EXPECT_EQ(wifi["connection"].toString(), QStringLiteral("Home"));
    EXPECT_EQ(wifi["ip4"].toArray(), QJsonArray({QStringLiteral("192.168.1.42/24")}));
    EXPECT_EQ(wifi["router"].toString(), QStringLiteral("192.168.1.1"));
    EXPECT_EQ(wifi["dns"].toArray(), QJsonArray({QStringLiteral("192.168.1.1"), QStringLiteral("9.9.9.9")}));
    EXPECT_EQ(wifi["ip6"].toArray(), QJsonArray({QStringLiteral("fe80::1/64")}));
    EXPECT_EQ(wifi["bitrate"].toInt(), 866700);
    EXPECT_EQ(wifi["frequency"].toInt(), 5180);
    EXPECT_EQ(wifi["ssid"].toString(), QStringLiteral("486F6D65"));
    const QJsonObject eth = devices[1].toObject();
    EXPECT_EQ(eth["speed"].toInt(), 1000);
    EXPECT_FALSE(wifi.contains(QStringLiteral("speed")));
    // The firewall systemd has loaded, read through Properties only.
    EXPECT_EQ(r.json["firewall"].toObject()["name"].toString(), QStringLiteral("firewalld"));
    EXPECT_TRUE(r.json["firewall"].toObject()["active"].toBool());
    for (const Call &c : f.bus.calls) {
        if (c.service == QLatin1String("org.freedesktop.systemd1")) {
            EXPECT_EQ(c.iface, QStringLiteral("org.freedesktop.DBus.Properties")) << qPrintable(c.member);
        }
    }
    EXPECT_EQ(eth["state"].toString(), QStringLiteral("disconnected"));
    EXPECT_FALSE(eth.contains(QStringLiteral("ip4"))); // no addresses read for a device that is not connected
    const QJsonArray vpns = r.json["vpns"].toArray();
    ASSERT_EQ(vpns.size(), 2);
    EXPECT_EQ(vpns[0]["name"].toString(), QStringLiteral("Office"));
    EXPECT_EQ(vpns[0]["kind"].toString(), QStringLiteral("wireguard"));
    EXPECT_EQ(vpns[0]["state"].toString(), QStringLiteral("connected")); // the active uuid matched case-insensitively
    EXPECT_EQ(vpns[1]["state"].toString(), QStringLiteral("disconnected"));
}

TEST(SystemBusNetwork, ForgetAndVpnActionsMakeExactlyTheirCalls)
{
    NetFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.forget"}, {"uuid", "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"}}), QString());
    EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("Delete"));
    EXPECT_EQ(f.bus.calls.last().path, QStringLiteral("/conn/1"));
    // NetworkManager may ask polkit first: the call waits for the dialog, and so does the job.
    EXPECT_EQ(f.bus.calls.last().timeoutMs, 120000);
    EXPECT_TRUE(privilegedAction({{"op", "wifi.forget"}}));
    EXPECT_FALSE(privilegedAction({{"op", "vpn.connect"}}));
    // A VPN uuid is not a Wi-Fi network to forget, and the reverse.
    f.bus.calls.clear();
    EXPECT_EQ(runAction(f.bus, {{"op", "wifi.forget"}, {"uuid", "bbbbbbbb-0000-0000-0000-000000000002"}}), QStringLiteral("that network is no longer saved"));
    EXPECT_FALSE(f.bus.members().contains(QStringLiteral("Connection.Delete")));
    EXPECT_EQ(runAction(f.bus, {{"op", "vpn.connect"}, {"uuid", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}, {"on", true}}), QStringLiteral("that VPN is no longer saved"));
    EXPECT_EQ(runAction(f.bus, {{"op", "vpn.connect"}, {"uuid", "bbbbbbbb-0000-0000-0000-000000000002"}, {"on", true}}), QString());
    EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("ActivateConnection"));
    EXPECT_EQ(f.bus.calls.last().args.value(0).value<QDBusObjectPath>().path(), QStringLiteral("/conn/3"));
    EXPECT_EQ(f.bus.calls.last().args.value(1).value<QDBusObjectPath>().path(), QStringLiteral("/"));
    EXPECT_EQ(runAction(f.bus, {{"op", "vpn.connect"}, {"uuid", "aaaaaaaa-0000-0000-0000-000000000001"}, {"on", false}}), QString());
    EXPECT_EQ(f.bus.calls.last().member, QStringLiteral("DeactivateConnection"));
    EXPECT_EQ(f.bus.calls.last().args.value(0).value<QDBusObjectPath>().path(), QStringLiteral("/active/2"));
    // A VPN that is already off: nothing is deactivated.
    f.bus.calls.clear();
    EXPECT_EQ(runAction(f.bus, {{"op", "vpn.connect"}, {"uuid", "bbbbbbbb-0000-0000-0000-000000000002"}, {"on", false}}), QString());
    EXPECT_FALSE(f.bus.members().contains(QStringLiteral("NetworkManager.DeactivateConnection")));
}

TEST(SystemBusNetwork, BadValuesNeverReachTheBusAndADevSessionOnlyReads)
{
    NetFixture f;
    for (const QVariantMap &op : {QVariantMap{{"op", "wifi.forget"}, {"uuid", "not-a-uuid"}}, QVariantMap{{"op", "wifi.forget"}, {"uuid", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0\n"}},
                                  QVariantMap{{"op", "vpn.connect"}, {"uuid", "bbbbbbbb-0000-0000-0000-000000000002"}, {"on", "yes"}},
                                  QVariantMap{{"op", "vpn.connect"}, {"uuid", "bbbbbbbb-0000-0000-0000-000000000002"}}}) {
        f.bus.calls.clear();
        EXPECT_EQ(runAction(f.bus, op), QStringLiteral("invalid request"));
        EXPECT_TRUE(f.bus.calls.isEmpty());
    }
    GuardedCaller dev(f.bus, true);
    f.bus.calls.clear();
    EXPECT_TRUE(networkState(dev).ok);
    EXPECT_TRUE(runAction(dev, {{"op", "wifi.forget"}, {"uuid", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}}).startsWith(QStringLiteral("dev guard")));
    EXPECT_TRUE(runAction(dev, {{"op", "vpn.connect"}, {"uuid", "bbbbbbbb-0000-0000-0000-000000000002"}, {"on", true}}).startsWith(QStringLiteral("dev guard")));
    for (const QString &m : f.bus.members())
        EXPECT_FALSE(m.endsWith(QLatin1String(".Delete")) || m.endsWith(QLatin1String("ActivateConnection"))) << qPrintable(m);
}

namespace
{
// UPower: on battery, a laptop battery (and a mouse's, which does not power the computer), the display device, a history.
struct PowerFixture {
    FakeBus bus;
    bool historyKept = true;
    PowerFixture()
    {
        bus.handler = [this](const Call &c) -> BusReply {
            const QString m = c.member, target = c.args.value(0).toString();
            if (m == QLatin1String("Get") && c.args.value(1).toString() == QLatin1String("OnBattery"))
                return ok({variant(true)});
            if (m == QLatin1String("EnumerateDevices"))
                return ok({paths({QStringLiteral("/upower/mouse"), QStringLiteral("/upower/bat0")})});
            if (m == QLatin1String("GetAll") && target == QLatin1String("org.freedesktop.UPower.Device")) {
                if (c.path == QLatin1String("/upower/mouse"))
                    return ok({QVariant::fromValue(QVariantMap{{"Type", u32(2)}, {"PowerSupply", false}, {"Percentage", 50.0}})});
                if (c.path == QLatin1String("/upower/bat0"))
                    return ok({QVariant::fromValue(QVariantMap{{"Type", u32(2)}, {"PowerSupply", true}, {"IsPresent", true}, {"Capacity", 91.5},
                                                               {"ChargeCycles", 212}, {"ChargeThresholdSupported", true}, {"ChargeThresholdEnabled", false},
                                                               {"ChargeEndThreshold", u32(80)}, {"HasHistory", historyKept}, {"Percentage", 70.0}})});
                return ok({QVariant::fromValue(QVariantMap{{"Percentage", 71.0}, {"State", u32(2)}, {"TimeToEmpty", qlonglong(7200)}, {"TimeToFull", qlonglong(0)}})});
            }
            if (m == QLatin1String("GetHistory"))
                return ok({QVariant::fromValue(QVariantList{QVariantList{1792800000u, 80.0, 2u}, QVariantList{1792803600u, 75.5, 2u}})});
            if (m == QLatin1String("EnableChargeThreshold"))
                return ok();
            return err(QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod: ") + m);
        };
    }
};
} // namespace

TEST(SystemBusPower, StateIsTheLaptopBatteryWithItsHistory)
{
    PowerFixture f;
    const StateResult r = powerState(f.bus);
    ASSERT_TRUE(r.ok) << r.error.toStdString();
    EXPECT_TRUE(r.json["present"].toBool());
    EXPECT_TRUE(r.json["onBattery"].toBool());
    EXPECT_DOUBLE_EQ(r.json["percent"].toDouble(), 71.0); // the display device's
    EXPECT_EQ(r.json["state"].toInt(), 2);
    EXPECT_EQ(r.json["timeToEmpty"].toInt(), 7200);
    EXPECT_DOUBLE_EQ(r.json["capacity"].toDouble(), 91.5);
    EXPECT_EQ(r.json["cycles"].toInt(), 212);
    EXPECT_TRUE(r.json["limitSupported"].toBool());
    EXPECT_FALSE(r.json["limitEnabled"].toBool());
    EXPECT_EQ(r.json["limitEnd"].toInt(), 80);
    const QJsonArray h = r.json["history24"].toArray();
    ASSERT_EQ(h.size(), 2);
    EXPECT_EQ(h[1].toArray()[0].toInteger(), 1792803600);
    EXPECT_DOUBLE_EQ(h[1].toArray()[1].toDouble(), 75.5);
    // The history asked for: the last 24 hours in 96 points and the last 10 days in 240, of the laptop battery only.
    QStringList asked;
    for (const Call &c : f.bus.calls) {
        if (c.member == QLatin1String("GetHistory"))
            asked << QStringLiteral("%1 %2 %3 %4").arg(c.path, c.args[0].toString()).arg(c.args[1].toUInt()).arg(c.args[2].toUInt());
        EXPECT_TRUE(isReadOnlyCall(c.service, c.iface, c.member, c.args)) << qPrintable(c.member);
    }
    EXPECT_EQ(asked, (QStringList{QStringLiteral("/upower/bat0 charge 86400 96"), QStringLiteral("/upower/bat0 charge 864000 240")}));
    // No history kept: none asked for.
    PowerFixture g;
    g.historyKept = false;
    EXPECT_FALSE(powerState(g.bus).json.contains(QStringLiteral("history24")));
    for (const Call &c : g.bus.calls)
        EXPECT_NE(c.member, QStringLiteral("GetHistory"));
}

TEST(SystemBusPower, NoBatteryAndNoUPowerAreTold)
{
    PowerFixture f;
    f.bus.handler = [](const Call &c) -> BusReply {
        if (c.member == QLatin1String("Get"))
            return ok({variant(false)});
        if (c.member == QLatin1String("EnumerateDevices"))
            return ok({paths({})});
        return err(QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod: x"));
    };
    const StateResult desktop = powerState(f.bus);
    ASSERT_TRUE(desktop.ok);
    EXPECT_FALSE(desktop.json["present"].toBool());
    EXPECT_EQ(runAction(f.bus, {{"op", "power.chargeLimit"}, {"on", true}}), QStringLiteral("no battery"));
    FakeBus none;
    const StateResult gone = powerState(none);
    EXPECT_FALSE(gone.ok);
    EXPECT_EQ(gone.error, QStringLiteral("the service is not running"));
}

TEST(SystemBusPower, TheChargeLimitIsUPowersOwnMethod)
{
    PowerFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "power.chargeLimit"}, {"on", true}}), QString());
    const Call c = f.bus.calls.last();
    EXPECT_EQ(c.member, QStringLiteral("EnableChargeThreshold"));
    EXPECT_EQ(c.path, QStringLiteral("/upower/bat0"));
    EXPECT_EQ(c.iface, QStringLiteral("org.freedesktop.UPower.Device"));
    EXPECT_EQ(c.args, (QVariantList{true}));
    EXPECT_EQ(c.timeoutMs, 120000);
    EXPECT_TRUE(privilegedAction({{"op", "power.chargeLimit"}}));
    f.bus.calls.clear();
    EXPECT_EQ(runAction(f.bus, {{"op", "power.chargeLimit"}, {"on", "yes"}}), QStringLiteral("invalid request"));
    EXPECT_TRUE(f.bus.calls.isEmpty());
    GuardedCaller dev(f.bus, true);
    EXPECT_TRUE(powerState(dev).ok);
    EXPECT_TRUE(runAction(dev, {{"op", "power.chargeLimit"}, {"on", true}}).startsWith(QStringLiteral("dev guard")));
    for (const Call &call : f.bus.calls)
        EXPECT_NE(call.member, QStringLiteral("EnableChargeThreshold"));
}

// Printers (ADR-0030): cups-pk-helper, which asks polkit and then cupsd; each method answers with CUPS's message, "" when it worked.
TEST(SystemBusPrinters, AddingMakesAnEverywhereQueueEnablesItAndAcceptsJobs)
{
    FakeBus bus;
    bus.handler = [](const Call &) { return ok({QString()}); };
    const QVariantMap add{{"op", "printer.add"}, {"name", "GF_Office"}, {"uri", "dnssd://GF%20Office._ipp._tcp.local/?uuid=1234"}, {"info", "GF Office"}};
    EXPECT_TRUE(privilegedAction(add));
    EXPECT_EQ(runAction(bus, add), QString());
    ASSERT_EQ(bus.calls.size(), 3);
    for (const Call &c : bus.calls) {
        EXPECT_EQ(c.service, QStringLiteral("org.opensuse.CupsPkHelper.Mechanism"));
        EXPECT_EQ(c.path, QStringLiteral("/"));
        EXPECT_EQ(c.iface, QStringLiteral("org.opensuse.CupsPkHelper.Mechanism"));
        EXPECT_EQ(c.timeoutMs, 120000);
    }
    EXPECT_EQ(bus.calls[0].member, QStringLiteral("PrinterAdd"));
    EXPECT_EQ(bus.calls[0].args, (QVariantList{QStringLiteral("GF_Office"), QStringLiteral("dnssd://GF%20Office._ipp._tcp.local/?uuid=1234"),
                                               QStringLiteral("everywhere"), QStringLiteral("GF Office"), QString()}));
    EXPECT_EQ(bus.calls[1].member, QStringLiteral("PrinterSetEnabled"));
    EXPECT_EQ(bus.calls[1].args, (QVariantList{QStringLiteral("GF_Office"), true}));
    EXPECT_EQ(bus.calls[2].member, QStringLiteral("PrinterSetAcceptJobs"));
    EXPECT_EQ(bus.calls[2].args, (QVariantList{QStringLiteral("GF_Office"), true, QString()}));
}

TEST(SystemBusPrinters, CupsMessagesAndRefusalsAreTheReasonAndStopTheAdd)
{
    FakeBus bus;
    bus.handler = [](const Call &c) { return c.member == QLatin1String("PrinterAdd") ? ok({QStringLiteral("client-error-not-possible")}) : ok({QString()}); };
    const QVariantMap add{{"op", "printer.add"}, {"name", "GF_Office"}, {"uri", "ipp://192.0.2.7/ipp/print"}, {"info", "GF Office"}};
    EXPECT_EQ(runAction(bus, add), QStringLiteral("client-error-not-possible"));
    EXPECT_EQ(bus.members(), (QStringList{QStringLiteral("Mechanism.PrinterAdd")}));
    FakeBus refused;
    refused.handler = [](const Call &) { return err(QStringLiteral("org.opensuse.CupsPkHelper.Mechanism.NotPrivileged: Not authorized")); };
    EXPECT_EQ(runAction(refused, add), QStringLiteral("not allowed: the system refused the request"));
    EXPECT_EQ(refused.calls.size(), 1);
    FakeBus none;
    EXPECT_EQ(runAction(none, {{"op", "printer.delete"}, {"name", "GF_Office"}}), QStringLiteral("the service is not running"));
}

TEST(SystemBusPrinters, AnAddWhoseSwitchesAreRefusedLeavesTheQueueToResume)
{
    FakeBus bus;
    bus.handler = [](const Call &c) {
        return c.member == QLatin1String("PrinterSetEnabled") ? err(QStringLiteral("org.opensuse.CupsPkHelper.Mechanism.NotPrivileged: Not Authorized")) : ok({QString()});
    };
    const QVariantMap add{{"op", "printer.add"}, {"name", "GF_Office"}, {"uri", "ipp://192.0.2.7/ipp/print"}, {"info", "GF Office"}};
    EXPECT_EQ(runAction(bus, add), QStringLiteral("not allowed: the system refused the request"));
    EXPECT_EQ(bus.members(), (QStringList{QStringLiteral("Mechanism.PrinterAdd"), QStringLiteral("Mechanism.PrinterSetEnabled")}));
    // Resume: the same two switches, nothing else.
    FakeBus later;
    later.handler = [](const Call &) { return ok({QString()}); };
    const QVariantMap resume{{"op", "printer.resume"}, {"name", "GF_Office"}};
    EXPECT_TRUE(privilegedAction(resume));
    EXPECT_EQ(runAction(later, resume), QString());
    ASSERT_EQ(later.calls.size(), 2);
    EXPECT_EQ(later.calls[0].member, QStringLiteral("PrinterSetEnabled"));
    EXPECT_EQ(later.calls[0].args, (QVariantList{QStringLiteral("GF_Office"), true}));
    EXPECT_EQ(later.calls[1].member, QStringLiteral("PrinterSetAcceptJobs"));
    EXPECT_EQ(later.calls[1].args, (QVariantList{QStringLiteral("GF_Office"), true, QString()}));
    later.calls.clear();
    EXPECT_EQ(runAction(later, {{"op", "printer.resume"}, {"name", "-x"}}), QStringLiteral("invalid request"));
    EXPECT_TRUE(later.calls.isEmpty());
    GuardedCaller dev(later, true);
    EXPECT_TRUE(runAction(dev, resume).startsWith(QStringLiteral("dev guard")));
    EXPECT_TRUE(later.calls.isEmpty());
}

TEST(SystemBusPrinters, RemovingIsPrinterDelete)
{
    FakeBus bus;
    bus.handler = [](const Call &) { return ok({QString()}); };
    EXPECT_EQ(runAction(bus, {{"op", "printer.delete"}, {"name", "GF_Office"}}), QString());
    ASSERT_EQ(bus.calls.size(), 1);
    EXPECT_EQ(bus.calls[0].member, QStringLiteral("PrinterDelete"));
    EXPECT_EQ(bus.calls[0].args, (QVariantList{QStringLiteral("GF_Office")}));
    EXPECT_TRUE(privilegedAction({{"op", "printer.delete"}}));
}

TEST(SystemBusPrinters, BadValuesNeverReachTheBusAndADevSessionSendsNothing)
{
    FakeBus bus;
    bus.handler = [](const Call &) { return ok({QString()}); };
    const QString uri = QStringLiteral("ipps://printer.local:631/ipp/print");
    for (const QVariantMap &op : QList<QVariantMap>{
             {{"op", "printer.add"}, {"name", "-x"}, {"uri", uri}, {"info", "X"}},
             {{"op", "printer.add"}, {"name", "a b"}, {"uri", uri}, {"info", "X"}},
             {{"op", "printer.add"}, {"name", "a/b"}, {"uri", uri}, {"info", "X"}},
             {{"op", "printer.add"}, {"name", QString(128, QLatin1Char('a'))}, {"uri", uri}, {"info", "X"}},
             {{"op", "printer.add"}, {"name", "Ok"}, {"uri", "usb://Brother/HL?serial=1"}, {"info", "X"}},
             {{"op", "printer.add"}, {"name", "Ok"}, {"uri", "file:///dev/null"}, {"info", "X"}},
             {{"op", "printer.add"}, {"name", "Ok"}, {"uri", "ipp://host/ipp print"}, {"info", "X"}},
             {{"op", "printer.add"}, {"name", "Ok"}, {"uri", "ipp:///x"}, {"info", "X"}},
             {{"op", "printer.add"}, {"name", "Ok"}, {"uri", uri}, {"info", "line\nbreak"}},
             {{"op", "printer.add"}, {"name", "Ok"}, {"uri", uri}, {"info", ""}},
             {{"op", "printer.add"}, {"name", "Ok"}, {"uri", uri}, {"info", 7}},
             {{"op", "printer.add"}, {"name", "Ok"}, {"uri", uri}},
             {{"op", "printer.delete"}, {"name", ""}},
             {{"op", "printer.delete"}, {"name", "x;y"}},
             {{"op", "printer.setDefault"}, {"name", "Ok"}}})
        EXPECT_EQ(runAction(bus, op), QStringLiteral("invalid request")) << op.value("name").toString().toStdString() << " " << op.value("uri").toString().toStdString();
    EXPECT_TRUE(bus.calls.isEmpty());
    GuardedCaller dev(bus, true);
    EXPECT_TRUE(runAction(dev, {{"op", "printer.add"}, {"name", "Ok"}, {"uri", uri}, {"info", "Ok"}}).startsWith(QStringLiteral("dev guard")));
    EXPECT_TRUE(runAction(dev, {{"op", "printer.delete"}, {"name", "Ok"}}).startsWith(QStringLiteral("dev guard")));
    EXPECT_TRUE(bus.calls.isEmpty());
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.opensuse.CupsPkHelper.Mechanism"), QStringLiteral("org.opensuse.CupsPkHelper.Mechanism"), QStringLiteral("DevicesGet"), {}));
}

// ---- Privacy & Security: the portal permission store (session bus, ADR-0030 amendment 2026-10-26) ----

namespace
{
using PermissionTable = QMap<QString, QStringList>;
const QString kStore = QStringLiteral("org.freedesktop.impl.portal.PermissionStore");
const QString kNotFound = QStringLiteral("org.freedesktop.portal.Error.NotFound: No entry for camera");

// A store with a location table (one app allowed, one refused, one with a bad one-element value, a host app with no id), a
// camera entry ("yes", "no", "ask"), no background table yet, and saved screen-sharing selections.
struct PrivacyFixture {
    FakeBus bus;
    PrivacyFixture()
    {
        bus.handler = [](const Call &c) -> BusReply {
            // The desktop portal runs and exports Background, not RemoteDesktop (a backend that implements only the first).
            if (c.service == QLatin1String("org.freedesktop.DBus") && c.member == QLatin1String("NameHasOwner"))
                return ok({c.args.value(0).toString() == QLatin1String("org.freedesktop.portal.Desktop")});
            if (c.service == QLatin1String("org.freedesktop.portal.Desktop") && c.member == QLatin1String("Get")) {
                if (c.args.value(0).toString() == QLatin1String("org.freedesktop.portal.Background"))
                    return ok({variant(2u)});
                return err(QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs: No such interface"));
            }
            if (c.service != kStore || c.iface != kStore)
                return err(QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod: no"));
            const QString table = c.args.value(0).toString();
            if (c.member == QLatin1String("Lookup")) {
                const QString id = c.args.value(1).toString();
                if (table == QLatin1String("location") && id == QLatin1String("location"))
                    return ok({QVariant::fromValue(PermissionTable{{"org.example.Maps", {"EXACT", "1234"}}, {"org.example.Weather", {"NONE", "0"}},
                                                                   {"org.example.Broken", {"EXACT"}}, {"", {"EXACT", "1"}}}),
                               variant(QVariant())});
                if (table == QLatin1String("devices") && id == QLatin1String("camera"))
                    return ok({QVariant::fromValue(PermissionTable{{"org.example.Meet", {"yes"}}, {"org.example.Photo", {"no"}}, {"org.example.Ask", {"ask"}}}),
                               variant(QVariant())});
                if (table == QLatin1String("screencast") && id == QLatin1String("00000000-1111-2222-3333-444444444444"))
                    return ok({QVariant::fromValue(PermissionTable{{"org.example.Meet", {"yes"}}}), variant(QVariant())});
                if (table == QLatin1String("screencast") && id == QLatin1String("_0000_fake_0000_0000_"))
                    return ok({QVariant::fromValue(PermissionTable{{"org.example.Studio", {"yes"}}}), variant(QVariant())});
                // A host app the portal could not name (xdg-desktop-portal 1.22 xdp-app-info-host.c: no app-*.scope with a
                // desktop entry gives ""), and a key no portal writes.
                if (table == QLatin1String("screencast") && id == QLatin1String("hostToken_without_id"))
                    return ok({QVariant::fromValue(PermissionTable{{"", {"yes"}}}), variant(QVariant())});
                if (table == QLatin1String("screencast") && id == QLatin1String("odd_key_token"))
                    return ok({QVariant::fromValue(PermissionTable{{"../evil\nname", {"yes"}}}), variant(QVariant())});
                return err(kNotFound);
            }
            if (c.member == QLatin1String("List")) {
                if (table == QLatin1String("screencast"))
                    return ok({QStringList{"../not/a/token", "00000000-1111-2222-3333-444444444444", "_0000_fake_0000_0000_", "hostToken_without_id",
                                           "odd_key_token"}});
                return err(kNotFound);
            }
            if (c.member == QLatin1String("SetPermission") || c.member == QLatin1String("Delete"))
                return ok();
            return err(QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod: no"));
        };
    }
};

QList<QPair<QString, bool>> appsOf(const QJsonArray &a)
{
    QList<QPair<QString, bool>> out;
    for (const QJsonValue &v : a)
        out.append({v.toObject().value("app").toString(), v.toObject().value("allowed").toBool()});
    return out;
}
} // namespace

TEST(SystemBusPrivacy, TheStoreIsReadAsThePortalsReadIt)
{
    PrivacyFixture f;
    const StateResult r = privacyState(f.bus);
    ASSERT_TRUE(r.ok) << r.error.toStdString();
    // Location: allowed unless NONE; a one-element value is not a grant (the portal asks again); the host apps' "" is left out.
    const auto location = appsOf(r.json.value("location").toArray());
    EXPECT_EQ(location, (QList<QPair<QString, bool>>{{"org.example.Broken", false}, {"org.example.Maps", true}, {"org.example.Weather", false}}));
    // Camera: only "yes" allows; "ask" asks every time.
    const auto camera = appsOf(r.json.value("camera").toArray());
    EXPECT_EQ(camera, (QList<QPair<QString, bool>>{{"org.example.Ask", false}, {"org.example.Meet", true}, {"org.example.Photo", false}}));
    // No background table yet: empty, not an error.
    EXPECT_TRUE(r.json.value("background").toArray().isEmpty());
    // Saved selections: one per app and token, a legacy UUID and a current token (one beginning with _, as one in 32 does); a
    // malformed token is never looked up.
    const QJsonArray shared = r.json.value("screencast").toArray();
    ASSERT_EQ(shared.size(), 4);
    EXPECT_EQ(shared[0].toObject().value("app").toString(), QStringLiteral("org.example.Meet"));
    EXPECT_EQ(shared[0].toObject().value("token").toString(), QStringLiteral("00000000-1111-2222-3333-444444444444"));
    EXPECT_EQ(shared[1].toObject().value("app").toString(), QStringLiteral("org.example.Studio"));
    EXPECT_EQ(shared[1].toObject().value("token").toString(), QStringLiteral("_0000_fake_0000_0000_"));
    // A grant of an app the portal could not name stays listed (and removable: privacy.forget goes by token) under "", and so
    // does one under a key no portal writes: its raw text is never passed on.
    EXPECT_EQ(shared[2].toObject(), (QJsonObject{{"app", ""}, {"token", "hostToken_without_id"}}));
    EXPECT_EQ(shared[3].toObject(), (QJsonObject{{"app", ""}, {"token", "odd_key_token"}}));
    EXPECT_TRUE(r.json.value("remoteDesktop").toArray().isEmpty());
    // The portals: Background exported, RemoteDesktop not; both asked with a read the dev guard lets through.
    EXPECT_EQ(r.json.value("portals").toObject(), (QJsonObject{{"background", true}, {"remoteDesktop", false}}));
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.freedesktop.portal.Desktop"), QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("Get"),
                                {QStringLiteral("org.freedesktop.portal.Camera"), QStringLiteral("version")}));
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.freedesktop.portal.Desktop"), QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("Set"),
                                {QStringLiteral("org.freedesktop.portal.Background"), QStringLiteral("version"), 3u}));
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.freedesktop.portal.Desktop"), QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("GetAll"),
                                {QStringLiteral("org.freedesktop.portal.Background")}));
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.freedesktop.DBus"), QStringLiteral("org.freedesktop.DBus"), QStringLiteral("NameHasOwner"),
                                {QStringLiteral("org.freedesktop.NetworkManager")}));
    EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.freedesktop.DBus"), QStringLiteral("org.freedesktop.DBus"), QStringLiteral("StartServiceByName"),
                                {QStringLiteral("org.freedesktop.portal.Desktop"), 0u}));
    for (const Call &c : f.bus.calls) {
        EXPECT_NE(c.args.value(1).toString(), QStringLiteral("../not/a/token"));
        EXPECT_TRUE(isReadOnlyCall(c.service, c.iface, c.member, c.args)) << c.member.toStdString();
    }
}

// No portal service, or no answer: the portals are left out (not known), and after a silence the second is not asked.
TEST(SystemBusPrivacy, PortalsNotKnownAreLeftOut)
{
    PrivacyFixture f;
    const auto store = f.bus.handler;
    int portalCalls = 0;
    f.bus.handler = [&](const Call &c) -> BusReply {
        if (c.service == QLatin1String("org.freedesktop.portal.Desktop")) {
            ++portalCalls;
            return err(QStringLiteral("org.freedesktop.DBus.Error.NoReply: Did not receive a reply"));
        }
        return store(c);
    };
    const StateResult r = privacyState(f.bus);
    ASSERT_TRUE(r.ok) << r.error.toStdString();
    EXPECT_TRUE(r.json.value("portals").toObject().isEmpty());
    EXPECT_EQ(portalCalls, 1);
    // Each of the names the bus gives a missing interface, property or object reads as missing.
    for (const char *name : {"org.freedesktop.DBus.Error.InvalidArgs", "org.freedesktop.DBus.Error.UnknownInterface",
                             "org.freedesktop.DBus.Error.UnknownProperty", "org.freedesktop.DBus.Error.UnknownObject"}) {
        f.bus.handler = [&, name](const Call &c) -> BusReply {
            if (c.service == QLatin1String("org.freedesktop.portal.Desktop"))
                return err(QString::fromLatin1(name) + QStringLiteral(": no"));
            return store(c);
        };
        EXPECT_EQ(privacyState(f.bus).json.value("portals").toObject(), (QJsonObject{{"background", false}, {"remoteDesktop", false}})) << name;
    }
}

// The portal not running: it is never asked (asking would start it), and the portals are not known.
TEST(SystemBusPrivacy, APortalNotRunningIsNotStarted)
{
    PrivacyFixture f;
    const auto store = f.bus.handler;
    int portalCalls = 0;
    f.bus.handler = [&](const Call &c) -> BusReply {
        if (c.service == QLatin1String("org.freedesktop.DBus") && c.member == QLatin1String("NameHasOwner"))
            return ok({false});
        if (c.service == QLatin1String("org.freedesktop.portal.Desktop"))
            ++portalCalls;
        return store(c);
    };
    const StateResult r = privacyState(f.bus);
    ASSERT_TRUE(r.ok);
    EXPECT_EQ(portalCalls, 0);
    EXPECT_TRUE(r.json.value("portals").toObject().isEmpty());
}

TEST(SystemBusPrivacy, NoStoreIsAReason)
{
    FakeBus bus; // nothing answers: the store is not installed
    const StateResult r = privacyState(bus);
    EXPECT_FALSE(r.ok);
    EXPECT_FALSE(r.error.isEmpty());
}

TEST(SystemBusPrivacy, ASwitchSetsExactlyThatAppsGrant)
{
    PrivacyFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "privacy.allow"}, {"category", "location"}, {"app", "org.example.Maps"}, {"on", false}}), QString());
    EXPECT_EQ(runAction(f.bus, {{"op", "privacy.allow"}, {"category", "location"}, {"app", "org.example.Weather"}, {"on", true}}), QString());
    EXPECT_EQ(runAction(f.bus, {{"op", "privacy.allow"}, {"category", "camera"}, {"app", "org.example.Meet"}, {"on", false}}), QString());
    EXPECT_EQ(runAction(f.bus, {{"op", "privacy.allow"}, {"category", "background"}, {"app", "org.example.Sync"}, {"on", true}}), QString());
    ASSERT_EQ(f.bus.calls.size(), 4);
    for (const Call &c : f.bus.calls) {
        EXPECT_EQ(c.service, kStore);
        EXPECT_EQ(c.member, QStringLiteral("SetPermission"));
    }
    // Location keeps two elements: one would read as no entry and the app would be asked again.
    EXPECT_EQ(f.bus.calls[0].args, (QVariantList{"location", true, "location", "org.example.Maps", QStringList{"NONE", "0"}}));
    EXPECT_EQ(f.bus.calls[1].args, (QVariantList{"location", true, "location", "org.example.Weather", QStringList{"EXACT", "0"}}));
    EXPECT_EQ(f.bus.calls[2].args, (QVariantList{"devices", true, "camera", "org.example.Meet", QStringList{"no"}}));
    EXPECT_EQ(f.bus.calls[3].args, (QVariantList{"background", true, "background", "org.example.Sync", QStringList{"yes"}}));
    // Forgetting a saved selection deletes that entry only; one already gone is fine.
    f.bus.calls.clear();
    EXPECT_EQ(runAction(f.bus, {{"op", "privacy.forget"}, {"kind", "screencast"}, {"token", "00000000-1111-2222-3333-444444444444"}}), QString());
    EXPECT_EQ(f.bus.calls[0].member, QStringLiteral("Delete"));
    EXPECT_EQ(f.bus.calls[0].args, (QVariantList{"screencast", "00000000-1111-2222-3333-444444444444"}));
    f.bus.handler = [](const Call &) { return err(kNotFound); };
    EXPECT_EQ(runAction(f.bus, {{"op", "privacy.forget"}, {"kind", "remoteDesktop"}, {"token", "abc"}}), QString());
    EXPECT_EQ(runAction(f.bus, {{"op", "privacy.forget"}, {"kind", "screencast"}, {"token", "_0000_fake_0000_0000_"}}), QString());
    EXPECT_EQ(f.bus.calls.last().args, (QVariantList{"screencast", "_0000_fake_0000_0000_"}));
    EXPECT_EQ(f.bus.calls[1].args.value(0).toString(), QStringLiteral("remote-desktop"));
    EXPECT_TRUE(sessionAction({{"op", "privacy.allow"}}));
    EXPECT_FALSE(privilegedAction({{"op", "privacy.allow"}}));
    EXPECT_FALSE(isReadOnlyCall(kStore, kStore, QStringLiteral("SetPermission"), {}));
    EXPECT_FALSE(isReadOnlyCall(kStore, kStore, QStringLiteral("Delete"), {}));
    EXPECT_FALSE(isReadOnlyCall(kStore, kStore, QStringLiteral("DeletePermission"), {}));
}

TEST(SystemBusPrivacy, BadValuesNeverReachTheStore)
{
    PrivacyFixture f;
    const QList<QVariantMap> bad{
        {{"op", "privacy.allow"}, {"category", "microphone"}, {"app", "org.example.Meet"}, {"on", true}},
        {{"op", "privacy.allow"}, {"category", "camera"}, {"app", ""}, {"on", true}},
        {{"op", "privacy.allow"}, {"category", "camera"}, {"app", "../x"}, {"on", true}},
        {{"op", "privacy.allow"}, {"category", "camera"}, {"app", "org.example.Meet\n"}, {"on", true}},
        {{"op", "privacy.allow"}, {"category", "camera"}, {"app", "org.example.Meet"}, {"on", "true"}},
        {{"op", "privacy.allow"}, {"category", "camera"}, {"app", 7}, {"on", true}},
        {{"op", "privacy.forget"}, {"kind", "documents"}, {"token", "abc"}},
        {{"op", "privacy.forget"}, {"kind", "screencast"}, {"token", "../abc"}},
        {{"op", "privacy.forget"}, {"kind", "screencast"}, {"token", ""}},
    };
    for (const QVariantMap &op : bad) {
        EXPECT_FALSE(validAction(op)) << op.value("category").toString().toStdString() << op.value("kind").toString().toStdString();
        EXPECT_FALSE(runAction(f.bus, op).isEmpty());
    }
    EXPECT_TRUE(f.bus.calls.isEmpty());
}

TEST(SystemBusPrivacy, ADevSessionReadsButNeverChangesAGrant)
{
    PrivacyFixture f;
    GuardedCaller dev(f.bus, true);
    EXPECT_TRUE(privacyState(dev).ok);
    const int reads = f.bus.calls.size();
    EXPECT_FALSE(runAction(dev, {{"op", "privacy.allow"}, {"category", "camera"}, {"app", "org.example.Meet"}, {"on", false}}).isEmpty());
    EXPECT_FALSE(runAction(dev, {{"op", "privacy.forget"}, {"kind", "screencast"}, {"token", "abc"}}).isEmpty());
    EXPECT_EQ(f.bus.calls.size(), reads);
}

// ---- ADR-0045 (OC-0.7): Remote Login (systemd's sshd.service), Disk Encryption (UDisks2), Fingerprint (fprintd).

namespace
{
const QString kUDisksName = QStringLiteral("org.freedesktop.UDisks2");
const QString kFprintName = QStringLiteral("net.reactivated.Fprint");
const QString kReader = QStringLiteral("/net/reactivated/Fprint/Device/0");
const QString kLuks = QStringLiteral("/org/freedesktop/UDisks2/block_devices/nvme0n1p2");
const QString kCrypt = QStringLiteral("/org/freedesktop/UDisks2/block_devices/dm_2d0");

// systemd with sshd.service installed (enabled, running) or not; every other call succeeds with no value.
struct SharingFixture {
    FakeBus bus;
    bool installed = true;
    SharingFixture()
    {
        bus.handler = [this](const Call &c) -> BusReply {
            if (c.member == QLatin1String("ListUnitFilesByPatterns"))
                return ok(QVariantList{QVariant(installed ? QVariantList{QVariant(QVariantList{"/usr/lib/systemd/system/sshd.service", "enabled"})} : QVariantList{})});
            if (c.member == QLatin1String("GetAll") && c.path == QLatin1String("/org/freedesktop/systemd1/unit/sshd_2eservice"))
                return ok({QVariantMap{{"ActiveState", "active"}, {"LoadState", "loaded"}}});
            return ok();
        };
    }
};

// UDisks2: the root file system on dm-0, whose crypto backing device is the LUKS partition nvme0n1p2 (or, `encrypted` false, a
// plain partition with no backing device).
struct DiskFixture {
    FakeBus bus;
    bool encrypted = true;
    QString passphraseError;
    DiskFixture()
    {
        bus.handler = [this](const Call &c) -> BusReply {
            if (c.member == QLatin1String("GetManagedObjects")) {
                ManagedObjects objects;
                objects.insert(QDBusObjectPath(kCrypt),
                               ConnectionSettings{{"org.freedesktop.UDisks2.Filesystem", {{"MountPoints", QVariant::fromValue(QList<QByteArray>{QByteArray("/\0", 2)})}}},
                                                  {"org.freedesktop.UDisks2.Block",
                                                   {{"CryptoBackingDevice", path(encrypted ? kLuks : QStringLiteral("/"))},
                                                    {"PreferredDevice", QByteArray("/dev/dm-0\0", 10)}}}});
                objects.insert(QDBusObjectPath(kLuks), ConnectionSettings{{"org.freedesktop.UDisks2.Encrypted", {{"HintEncryptionType", "LUKS2"}}},
                                                                          {"org.freedesktop.UDisks2.Block", {{"PreferredDevice", QByteArray("/dev/nvme0n1p2\0", 15)}}}});
                objects.insert(QDBusObjectPath(QStringLiteral("/org/freedesktop/UDisks2/block_devices/sda1")),
                               ConnectionSettings{{"org.freedesktop.UDisks2.Filesystem", {{"MountPoints", QVariant::fromValue(QList<QByteArray>{QByteArray("/mnt/usb\0", 9)})}}}});
                return ok({QVariant::fromValue(objects)});
            }
            if (c.member == QLatin1String("ChangePassphrase") && !passphraseError.isEmpty())
                return err(passphraseError);
            return ok();
        };
    }
};

// fprintd with one reader, the right index finger enrolled (or none), and the statuses an enrolment sends.
struct FprintFixture {
    FakeBus bus;
    bool reader = true;
    QStringList enrolled{QStringLiteral("right-index-finger"), QStringLiteral("bogus-finger")};
    QString claimError, startError;
    FprintFixture()
    {
        bus.handler = [this](const Call &c) -> BusReply {
            if (c.member == QLatin1String("GetDefaultDevice"))
                return reader ? ok({path(kReader)}) : err(QStringLiteral("net.reactivated.Fprint.Error.NoSuchDevice: No devices available"));
            if (c.member == QLatin1String("GetAll"))
                return ok({QVariantMap{{"name", "Goodix MOC Fingerprint Sensor"}, {"num-enroll-stages", 10}, {"scan-type", "press"}}});
            if (c.member == QLatin1String("ListEnrolledFingers"))
                return enrolled.isEmpty() ? err(QStringLiteral("net.reactivated.Fprint.Error.NoEnrolledPrints: none")) : ok({enrolled});
            if (c.member == QLatin1String("Claim") && !claimError.isEmpty())
                return err(claimError);
            if (c.member == QLatin1String("EnrollStart") && !startError.isEmpty())
                return err(startError);
            return ok();
        };
    }
};
} // namespace

TEST(SystemBusSharing, RemoteLoginIsSshdsUnitFileStateAndActiveState)
{
    SharingFixture f;
    const StateResult r = sharingState(f.bus);
    ASSERT_TRUE(r.ok);
    EXPECT_TRUE(r.json.value("installed").toBool());
    EXPECT_EQ(r.json.value("unitFileState").toString(), QStringLiteral("enabled"));
    EXPECT_TRUE(r.json.value("active").toBool());
    // Every state and that one unit's name: read from the disk, whatever systemd has loaded.
    EXPECT_EQ(f.bus.calls[0].args, (QVariantList{QStringList(), QStringList{QStringLiteral("sshd.service")}}));
    SharingFixture none;
    none.installed = false;
    const StateResult n = sharingState(none.bus);
    ASSERT_TRUE(n.ok);
    EXPECT_FALSE(n.json.value("installed").toBool());
    EXPECT_FALSE(n.json.value("active").toBool());
    EXPECT_EQ(none.bus.members(), QStringList{QStringLiteral("Manager.ListUnitFilesByPatterns")});
}

TEST(SystemBusSharing, TheSwitchEnablesAndStartsSshdOnlyAndStopsItTheOtherWay)
{
    // Omarchy's setup has run: its hardening file is there (a file of the test in its place).
    QTemporaryFile marker;
    ASSERT_TRUE(marker.open());
    const QString setUp = marker.fileName();
    SharingFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "ssh.enable"}, {"on", true}}, {}, setUp), QString());
    EXPECT_EQ(f.bus.members(), (QStringList{QStringLiteral("Manager.EnableUnitFiles"), QStringLiteral("Manager.StartUnit")}));
    EXPECT_EQ(f.bus.calls[0].args, (QVariantList{QStringList{QStringLiteral("sshd.service")}, false, false}));
    EXPECT_EQ(f.bus.calls[1].args, (QVariantList{QStringLiteral("sshd.service"), QStringLiteral("replace")}));
    EXPECT_EQ(f.bus.calls[1].timeoutMs, 120000);
    f.bus.calls.clear();
    EXPECT_EQ(runAction(f.bus, {{"op", "ssh.enable"}, {"on", false}}, {}, setUp), QString());
    EXPECT_EQ(f.bus.members(), (QStringList{QStringLiteral("Manager.StopUnit"), QStringLiteral("Manager.DisableUnitFiles")}));
    EXPECT_EQ(f.bus.calls[1].args, (QVariantList{QStringList{QStringLiteral("sshd.service")}, false}));
    EXPECT_TRUE(privilegedAction({{"op", "ssh.enable"}}));
    // A refused first call stops there, with polkit's reason.
    FakeBus refused;
    refused.handler = [](const Call &) { return err(QStringLiteral("org.freedesktop.DBus.Error.InteractiveAuthorizationRequired: no")); };
    EXPECT_FALSE(runAction(refused, {{"op", "ssh.enable"}, {"on", true}}, {}, setUp).isEmpty());
    EXPECT_EQ(refused.members(), QStringList{QStringLiteral("Manager.EnableUnitFiles")});
    // The page names no unit and sends no other value.
    f.bus.calls.clear();
    for (const QVariantMap &op : QList<QVariantMap>{{{"op", "ssh.enable"}, {"on", "true"}},
                                                     {{"op", "ssh.enable"}},
                                                     {{"op", "ssh.enable"}, {"on", true}, {"unit", "getty@tty1.service"}}}) {
        EXPECT_FALSE(validAction(op));
        EXPECT_EQ(runAction(f.bus, op, {}, setUp), QStringLiteral("invalid request"));
    }
    EXPECT_TRUE(f.bus.calls.isEmpty());
}

// Defence in depth (security review of ADR-0045, L-4): turning Remote Login on before Omarchy's setup ran (no hardening file:
// no key authorized, Omarchy's firewall closed) is refused before any call; turning it off is not.
TEST(SystemBusSharing, OnBeforeOmarchysSetupIsRefusedOffIsNot)
{
    SharingFixture f;
    const QString missing = QStringLiteral("/nonexistent/gf-test/10-omarchy-hardening.conf");
    EXPECT_EQ(runAction(f.bus, {{"op", "ssh.enable"}, {"on", true}}, {}, missing), QStringLiteral("Omarchy's SSH setup has not run"));
    EXPECT_TRUE(f.bus.calls.isEmpty());
    // A folder in its place is no setup either; the default is Omarchy's own path.
    EXPECT_EQ(runAction(f.bus, {{"op", "ssh.enable"}, {"on", true}}, {}, QStringLiteral("/")), QStringLiteral("Omarchy's SSH setup has not run"));
    EXPECT_TRUE(f.bus.calls.isEmpty());
    EXPECT_EQ(runAction(f.bus, {{"op", "ssh.enable"}, {"on", false}}, {}, missing), QString());
    EXPECT_EQ(f.bus.members(), (QStringList{QStringLiteral("Manager.StopUnit"), QStringLiteral("Manager.DisableUnitFiles")}));
}

TEST(SystemBusDisk, TheRootFileSystemsLuksDeviceIsFoundThroughUDisks2)
{
    DiskFixture f;
    const StateResult r = diskState(f.bus);
    ASSERT_TRUE(r.ok);
    EXPECT_TRUE(r.json.value("encrypted").toBool());
    EXPECT_EQ(r.json.value("device").toString(), QStringLiteral("/dev/nvme0n1p2"));
    DiskFixture plain;
    plain.encrypted = false;
    const StateResult p = diskState(plain.bus);
    ASSERT_TRUE(p.ok);
    EXPECT_FALSE(p.json.value("encrypted").toBool());
    EXPECT_EQ(p.json.value("device").toString(), QString());
    // UDisks2 not answering is a failure: the page then offers Omarchy's terminal.
    FakeBus none;
    EXPECT_FALSE(diskState(none).ok);
}

TEST(SystemBusDisk, ThePasswordChangeGoesToThatDeviceOnlyWithBothPassphrases)
{
    DiskFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "disk.passphrase"}, {"old", QStringLiteral("old pass")}, {"new", QStringLiteral("néw;pass")}}), QString());
    const Call c = f.bus.calls.last();
    EXPECT_EQ(c.service, kUDisksName);
    EXPECT_EQ(c.path, kLuks);
    EXPECT_EQ(c.iface, QStringLiteral("org.freedesktop.UDisks2.Encrypted"));
    EXPECT_EQ(c.member, QStringLiteral("ChangePassphrase"));
    ASSERT_EQ(c.args.size(), 3);
    EXPECT_EQ(c.args[0].toString(), QStringLiteral("old pass"));
    EXPECT_EQ(c.args[1].toString(), QStringLiteral("néw;pass"));
    EXPECT_TRUE(c.args[2].toMap().isEmpty());
    EXPECT_EQ(c.timeoutMs, 120000);
    EXPECT_TRUE(privilegedAction({{"op", "disk.passphrase"}}));
    // A current passphrase that opens no key slot is said plainly; the passphrases are never part of a reason.
    DiskFixture wrong;
    wrong.passphraseError = QStringLiteral("org.freedesktop.UDisks2.Error.Failed: Error changing passphrase on device /dev/nvme0n1p2: Failed to unlock: No key available with this passphrase");
    EXPECT_EQ(runAction(wrong.bus, {{"op", "disk.passphrase"}, {"old", QStringLiteral("x")}, {"new", QStringLiteral("y")}}), QStringLiteral("the current password is not correct"));
    // No answer in time is not a refusal: the password may have changed (security review of ADR-0045, L-1).
    DiskFixture late;
    late.passphraseError = QStringLiteral("org.freedesktop.DBus.Error.NoReply: Did not receive a reply.");
    EXPECT_EQ(runAction(late.bus, {{"op", "disk.passphrase"}, {"old", QStringLiteral("x")}, {"new", QStringLiteral("y")}}), QStringLiteral("the disk did not answer in time"));
    // Not encrypted: nothing is asked of UDisks2 but its objects.
    DiskFixture plain;
    plain.encrypted = false;
    EXPECT_EQ(runAction(plain.bus, {{"op", "disk.passphrase"}, {"old", QStringLiteral("x")}, {"new", QStringLiteral("y")}}), QStringLiteral("the start-up disk is not encrypted"));
    EXPECT_EQ(plain.bus.members(), QStringList{QStringLiteral("ObjectManager.GetManagedObjects")});
}

TEST(SystemBusDisk, BadPassphrasesAndANamedDeviceNeverReachTheBus)
{
    DiskFixture f;
    const QList<QVariantMap> bad{
        {{"op", "disk.passphrase"}, {"old", QString()}, {"new", QStringLiteral("y")}},
        {{"op", "disk.passphrase"}, {"old", QStringLiteral("x")}, {"new", QString(513, QLatin1Char('a'))}},
        {{"op", "disk.passphrase"}, {"old", QStringLiteral("x")}, {"new", QStringLiteral("a") + QChar(0) + QStringLiteral("b")}},
        {{"op", "disk.passphrase"}, {"old", 1234}, {"new", QStringLiteral("y")}},
        {{"op", "disk.passphrase"}, {"new", QStringLiteral("y")}},
        {{"op", "disk.passphrase"}, {"old", QStringLiteral("x")}, {"new", QStringLiteral("y")}, {"device", "/org/freedesktop/UDisks2/block_devices/sda1"}},
    };
    for (const QVariantMap &op : bad) {
        EXPECT_FALSE(validAction(op));
        EXPECT_EQ(runAction(f.bus, op), QStringLiteral("invalid request"));
    }
    EXPECT_TRUE(f.bus.calls.isEmpty());
    EXPECT_TRUE(validAction({{"op", "disk.passphrase"}, {"old", QString(512, QLatin1Char('a'))}, {"new", QStringLiteral("\t ;'\"$(x)")}}));
}

TEST(SystemBusFingerprint, StateIsTheReaderAndTheKnownFingersOnly)
{
    FprintFixture f;
    const StateResult r = fingerprintState(f.bus);
    ASSERT_TRUE(r.ok);
    EXPECT_TRUE(r.json.value("present").toBool());
    EXPECT_EQ(r.json.value("name").toString(), QStringLiteral("Goodix MOC Fingerprint Sensor"));
    EXPECT_EQ(r.json.value("stages").toInt(), 10);
    EXPECT_EQ(r.json.value("scanType").toString(), QStringLiteral("press"));
    EXPECT_EQ(r.json.value("fingers").toArray(), (QJsonArray{QStringLiteral("right-index-finger")}));
    // The caller's own fingers ("": fprintd's current user).
    EXPECT_EQ(f.bus.calls.last().args, (QVariantList{QString()}));
    FprintFixture none;
    none.enrolled.clear();
    const StateResult n = fingerprintState(none.bus);
    ASSERT_TRUE(n.ok);
    EXPECT_TRUE(n.json.value("fingers").toArray().isEmpty());
    FprintFixture noReader;
    noReader.reader = false;
    const StateResult z = fingerprintState(noReader.bus);
    ASSERT_TRUE(z.ok);
    EXPECT_FALSE(z.json.value("present").toBool());
    FakeBus stopped;
    EXPECT_FALSE(fingerprintState(stopped).ok);
}

TEST(SystemBusFingerprint, AnEnrolmentListensFirstPassesEachStatusOnAndAlwaysReleases)
{
    FprintFixture f;
    f.bus.scripted = {{QStringLiteral("enroll-stage-passed"), false}, {QStringLiteral("enroll-retry-scan"), false}, {QStringLiteral("enroll-completed"), true}};
    QStringList seen;
    EXPECT_EQ(enrollFinger(f.bus, QStringLiteral("right-index-finger"), [&seen](const QString &s) { seen << s; }, [] { return false; }, 60000), QString());
    EXPECT_EQ(seen, (QStringList{QStringLiteral("enroll-stage-passed"), QStringLiteral("enroll-retry-scan"), QStringLiteral("enroll-completed")}));
    EXPECT_EQ(f.bus.members(), (QStringList{QStringLiteral("Manager.GetDefaultDevice"), QStringLiteral("Device.listen:EnrollStatus"), QStringLiteral("Device.Claim"),
                                            QStringLiteral("Device.EnrollStart"), QStringLiteral("Device.EnrollStop"), QStringLiteral("Device.Release")}));
    EXPECT_EQ(f.bus.calls[1].path, kReader);
    EXPECT_EQ(f.bus.calls[2].args, (QVariantList{QString()}));
    EXPECT_EQ(f.bus.calls[3].args, (QVariantList{QStringLiteral("right-index-finger")}));
    // fprintd's final failure is the answer, as fprintd names it.
    FprintFixture full;
    full.bus.scripted = {{QStringLiteral("enroll-data-full"), true}};
    EXPECT_EQ(enrollFinger(full.bus, QStringLiteral("left-thumb"), {}, {}, 60000), QStringLiteral("enroll-data-full"));
    EXPECT_EQ(full.bus.members().mid(4), (QStringList{QStringLiteral("Device.EnrollStop"), QStringLiteral("Device.Release")}));
}

TEST(SystemBusFingerprint, StoppingOrSilenceEndsItAndARefusalReleasesWhatWasClaimed)
{
    FprintFixture f;
    EXPECT_EQ(enrollFinger(f.bus, QStringLiteral("right-thumb"), {}, [] { return true; }, 60000), QStringLiteral("enroll-stopped"));
    EXPECT_EQ(f.bus.members().mid(4), (QStringList{QStringLiteral("Device.EnrollStop"), QStringLiteral("Device.Release")}));
    FprintFixture quiet;
    EXPECT_EQ(enrollFinger(quiet.bus, QStringLiteral("right-thumb"), {}, [] { return false; }, 5), QStringLiteral("timed out"));
    EXPECT_EQ(quiet.bus.members().mid(4), (QStringList{QStringLiteral("Device.EnrollStop"), QStringLiteral("Device.Release")}));
    // Touches that keep coming (someone else's) do not keep it going past its overall limit (security review of ADR-0045, L-5).
    FprintFixture busyReader;
    for (int i = 0; i < 50; ++i)
        busyReader.bus.scripted.append({QStringLiteral("enroll-retry-scan"), false});
    int statuses = 0;
    EXPECT_EQ(enrollFinger(busyReader.bus, QStringLiteral("right-thumb"), [&statuses](const QString &) { ++statuses; }, [] { return false; }, 60000, 1),
              QStringLiteral("timed out"));
    EXPECT_GT(statuses, 0);
    EXPECT_EQ(busyReader.bus.members().mid(busyReader.bus.members().size() - 2),
              (QStringList{QStringLiteral("Device.EnrollStop"), QStringLiteral("Device.Release")}));
    // polkit refused EnrollStart: no EnrollStop (nothing started), the claim released.
    FprintFixture refused;
    refused.startError = QStringLiteral("net.reactivated.Fprint.Error.PermissionDenied: Not Authorized: net.reactivated.fprint.device.enroll");
    EXPECT_EQ(enrollFinger(refused.bus, QStringLiteral("right-thumb"), {}, {}, 60000), QStringLiteral("not allowed: the system refused the request"));
    EXPECT_EQ(refused.bus.members().mid(3), (QStringList{QStringLiteral("Device.EnrollStart"), QStringLiteral("Device.Release")}));
    // Another program holds the reader: nothing was claimed, nothing to release.
    FprintFixture busy;
    busy.claimError = QStringLiteral("net.reactivated.Fprint.Error.AlreadyInUse: Device was already claimed");
    EXPECT_EQ(enrollFinger(busy.bus, QStringLiteral("right-thumb"), {}, {}, 60000), QStringLiteral("Device was already claimed"));
    EXPECT_EQ(busy.bus.members().last(), QStringLiteral("Device.Claim"));
    // A finger fprintd does not name is never sent.
    FprintFixture bad;
    EXPECT_EQ(enrollFinger(bad.bus, QStringLiteral("any"), {}, {}, 60000), QStringLiteral("invalid request"));
    EXPECT_TRUE(bad.bus.calls.isEmpty());
}

TEST(SystemBusFingerprint, DeletingOneFingerClaimsDeletesAndReleases)
{
    FprintFixture f;
    EXPECT_EQ(runAction(f.bus, {{"op", "fprint.delete"}, {"finger", "right-index-finger"}}), QString());
    EXPECT_EQ(f.bus.members(), (QStringList{QStringLiteral("Manager.GetDefaultDevice"), QStringLiteral("Device.Claim"), QStringLiteral("Device.DeleteEnrolledFinger"),
                                            QStringLiteral("Device.Release")}));
    EXPECT_EQ(f.bus.calls[2].args, (QVariantList{QStringLiteral("right-index-finger")}));
    EXPECT_TRUE(privilegedAction({{"op", "fprint.delete"}}));
    EXPECT_TRUE(privilegedAction({{"op", "fprint.enroll"}}));
    f.bus.calls.clear();
    for (const QVariantMap &op : QList<QVariantMap>{{{"op", "fprint.delete"}, {"finger", "any"}},
                                                     {{"op", "fprint.delete"}, {"finger", "right-index-finger"}, {"user", "root"}},
                                                     {{"op", "fprint.enroll"}, {"finger", 3}},
                                                     {{"op", "fprint.enroll"}}}) {
        EXPECT_FALSE(validAction(op));
        EXPECT_EQ(runAction(f.bus, op), QStringLiteral("invalid request"));
    }
    EXPECT_TRUE(f.bus.calls.isEmpty());
    EXPECT_TRUE(isFingerName(QStringLiteral("left-little-finger")));
    EXPECT_FALSE(isFingerName(QStringLiteral("left-little")));
}

TEST(SystemBusGuard, ADevSessionReadsSharingDiskAndFingersButChangesNothing)
{
    SharingFixture s;
    DiskFixture d;
    FprintFixture p;
    GuardedCaller devS(s.bus, true);
    GuardedCaller devD(d.bus, true);
    GuardedCaller devP(p.bus, true);
    EXPECT_TRUE(sharingState(devS).ok);
    EXPECT_TRUE(diskState(devD).ok);
    EXPECT_TRUE(fingerprintState(devP).ok);
    EXPECT_FALSE(runAction(devS, {{"op", "ssh.enable"}, {"on", true}}).isEmpty());
    EXPECT_FALSE(runAction(devD, {{"op", "disk.passphrase"}, {"old", QStringLiteral("x")}, {"new", QStringLiteral("y")}}).isEmpty());
    EXPECT_FALSE(runAction(devP, {{"op", "fprint.delete"}, {"finger", "right-index-finger"}}).isEmpty());
    EXPECT_FALSE(enrollFinger(devP, QStringLiteral("right-index-finger"), {}, {}, 60000).isEmpty());
    for (FakeBus *bus : {&s.bus, &d.bus, &p.bus}) {
        for (const Call &c : bus->calls) {
            if (!c.member.startsWith(QLatin1String("listen:"))) {
                EXPECT_TRUE(isReadOnlyCall(c.service, c.iface, c.member, c.args)) << c.member.toStdString();
            }
        }
    }
    const QString props = QStringLiteral("org.freedesktop.DBus.Properties");
    EXPECT_TRUE(isReadOnlyCall(kUDisksName, QStringLiteral("org.freedesktop.DBus.ObjectManager"), QStringLiteral("GetManagedObjects"), {}));
    EXPECT_FALSE(isReadOnlyCall(kUDisksName, QStringLiteral("org.freedesktop.UDisks2.Encrypted"), QStringLiteral("ChangePassphrase"), {}));
    EXPECT_FALSE(isReadOnlyCall(kUDisksName, QStringLiteral("org.freedesktop.UDisks2.Encrypted"), QStringLiteral("Unlock"), {}));
    EXPECT_FALSE(isReadOnlyCall(kUDisksName, props, QStringLiteral("Get"), {}));
    EXPECT_TRUE(isReadOnlyCall(kFprintName, QStringLiteral("net.reactivated.Fprint.Manager"), QStringLiteral("GetDefaultDevice"), {}));
    EXPECT_TRUE(isReadOnlyCall(kFprintName, QStringLiteral("net.reactivated.Fprint.Device"), QStringLiteral("ListEnrolledFingers"), {}));
    EXPECT_TRUE(isReadOnlyCall(kFprintName, props, QStringLiteral("GetAll"), {}));
    for (const char *m : {"Claim", "EnrollStart", "EnrollStop", "Release", "DeleteEnrolledFinger", "DeleteEnrolledFingers2", "VerifyStart"})
        EXPECT_FALSE(isReadOnlyCall(kFprintName, QStringLiteral("net.reactivated.Fprint.Device"), QString::fromLatin1(m), {})) << m;
    for (const char *m : {"EnableUnitFiles", "DisableUnitFiles", "StartUnit", "StopUnit", "Reload"})
        EXPECT_FALSE(isReadOnlyCall(QStringLiteral("org.freedesktop.systemd1"), QStringLiteral("org.freedesktop.systemd1.Manager"), QString::fromLatin1(m), {})) << m;
}
