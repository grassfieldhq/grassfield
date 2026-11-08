// Unit tests for bridges/menu-bridge/src/ScreenSaver.{h,cpp} and the menu/1 "screensaver" line (gtest; GF-AUDIT-001
// GF-016 residual). Linked into menu-bridge-unit-tests (main() is in tst_menubridge.cpp). The bus path (owning the name,
// a sender leaving the bus, the shell line) is tests/integration/screensaver_inhibit.sh (private bus, bare).
#include "DBusObjects.h"
#include "Protocol.h"
#include "ScreenSaver.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>

#include <optional>

#include <gtest/gtest.h>

using namespace gf::menubridge;
using namespace gf::menubridge::screensaver;

namespace {
    const QString kA = QStringLiteral(":1.10");
    const QString kB = QStringLiteral(":1.11");

    Answer call(Book& book, const QString& member, const QString& sig, const QVariantList& args, const QString& sender = kA) {
        return handle(book, member, sig, args, sender);
    }

    quint32 inhibit(Book& book, const QString& sender, const QString& app = QStringLiteral("VLC")) {
        const Answer a = call(book, QStringLiteral("Inhibit"), QStringLiteral("ss"), {app, QStringLiteral("video")}, sender);
        EXPECT_EQ(a.kind, Answer::Kind::Reply) << a.error.toStdString();
        return a.values.isEmpty() ? 0 : a.values.at(0).toUInt();
    }
} // namespace

TEST(ScreenSaverBook, InhibitGivesDistinctNonZeroCookiesAndActivates) {
    Book book;
    EXPECT_FALSE(book.active());
    QSet<quint32> seen;
    for (int i = 0; i < 10; ++i) {
        const quint32 c = inhibit(book, kA);
        EXPECT_NE(c, 0u);
        EXPECT_FALSE(seen.contains(c));
        seen.insert(c);
    }
    EXPECT_TRUE(book.active());
    EXPECT_EQ(book.count(), 10);
}

TEST(ScreenSaverBook, OnlyTheOwnerReleasesItsCookie) {
    Book          book;
    const quint32 a = inhibit(book, kA);
    const quint32 b = inhibit(book, kB, QStringLiteral("Chromium"));
    EXPECT_FALSE(book.uninhibit(kB, a)) << "another connection's cookie";
    EXPECT_FALSE(book.uninhibit(kA, 0x12345u)) << "an unknown cookie";
    EXPECT_EQ(book.count(), 2);
    EXPECT_TRUE(book.uninhibit(kA, a));
    EXPECT_FALSE(book.uninhibit(kA, a)) << "released once";
    EXPECT_TRUE(book.active());
    EXPECT_TRUE(book.uninhibit(kB, b));
    EXPECT_FALSE(book.active());
}

TEST(ScreenSaverBook, ASenderThatLeavesDropsAllItsCookies) {
    Book book;
    inhibit(book, kA);
    inhibit(book, kA);
    inhibit(book, kB, QStringLiteral("Steam"));
    EXPECT_TRUE(book.senderGone(kA));
    EXPECT_FALSE(book.senderGone(kA));
    EXPECT_EQ(book.count(), 1);
    EXPECT_EQ(book.applications(), QStringList{QStringLiteral("Steam")});
    EXPECT_TRUE(book.senderGone(kB));
    EXPECT_FALSE(book.active());
}

TEST(ScreenSaverBook, LimitsPerSenderAndSenders) {
    Book book;
    for (int i = 0; i < kMaxPerSender; ++i)
        inhibit(book, kA);
    const Answer over = call(book, QStringLiteral("Inhibit"), QStringLiteral("ss"), {QStringLiteral("x"), QStringLiteral("y")}, kA);
    EXPECT_EQ(over.kind, Answer::Kind::Error);
    EXPECT_EQ(over.error, QStringLiteral("org.freedesktop.DBus.Error.LimitsExceeded"));
    Book many;
    for (int i = 0; i < kMaxSenders; ++i)
        EXPECT_TRUE(many.inhibit(QStringLiteral(":2.%1").arg(i), QStringLiteral("a")).ok);
    EXPECT_FALSE(many.inhibit(QStringLiteral(":3.0"), QStringLiteral("a")).ok) << "one sender too many";
    EXPECT_TRUE(many.inhibit(QStringLiteral(":2.0"), QStringLiteral("a")).ok) << "a known sender may take another";
}

TEST(ScreenSaverBook, ApplicationNamesAreCleanAndBounded) {
    Book book;
    book.inhibit(kA, QStringLiteral("VLC\nmedia\x01player"));
    book.inhibit(kB, QString(500, u'x'));
    book.inhibit(QStringLiteral(":1.12"), QString());
    const QStringList apps = book.applications();
    ASSERT_EQ(apps.size(), 3);
    EXPECT_TRUE(apps.contains(QStringLiteral("an application")));
    for (const QString& a : apps) {
        EXPECT_LE(a.size(), kMaxText);
        for (const QChar c : a)
            EXPECT_TRUE(c.isPrint()) << a.toStdString();
    }
}

TEST(ScreenSaverHandle, OnlyInhibitAndUnInhibitAreServed) {
    Book book;
    for (const char* m : {"Lock", "SetActive", "GetActive", "GetActiveTime", "GetSessionIdleTime", "SimulateUserActivity", "Throttle"}) {
        const Answer a = call(book, QLatin1String(m), QString(), {});
        EXPECT_EQ(a.kind, Answer::Kind::Error) << m;
        EXPECT_EQ(a.error, QStringLiteral("org.freedesktop.DBus.Error.NotSupported")) << m;
    }
    const Answer setActive = call(book, QStringLiteral("SetActive"), QStringLiteral("b"), {false});
    EXPECT_EQ(setActive.error, QStringLiteral("org.freedesktop.DBus.Error.NotSupported")) << "never unlocks or hides anything";
    EXPECT_FALSE(book.active());
}

TEST(ScreenSaverHandle, WrongSignaturesAreInvalidArgs) {
    Book book;
    EXPECT_EQ(call(book, QStringLiteral("Inhibit"), QStringLiteral("s"), {QStringLiteral("x")}).error, QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs"));
    EXPECT_EQ(call(book, QStringLiteral("Inhibit"), QStringLiteral("su"), {QStringLiteral("x"), 1u}).error, QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs"));
    EXPECT_EQ(call(book, QStringLiteral("UnInhibit"), QStringLiteral("s"), {QStringLiteral("1")}).error, QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs"));
    EXPECT_FALSE(book.active());
}

TEST(ScreenSaverHandle, UnInhibitAnswersAlikeForEveryCookie) {
    Book          book;
    const quint32 c = inhibit(book, kA);
    const Answer  other = call(book, QStringLiteral("UnInhibit"), QStringLiteral("u"), {c}, kB);
    EXPECT_EQ(other.kind, Answer::Kind::Reply);
    EXPECT_FALSE(other.changed);
    const Answer own = call(book, QStringLiteral("UnInhibit"), QStringLiteral("u"), {c}, kA);
    EXPECT_EQ(own.kind, Answer::Kind::Reply);
    EXPECT_TRUE(own.changed);
    EXPECT_FALSE(book.active());
}

TEST(ScreenSaverProtocol, Line) {
    const QByteArray line = screensaverMessage(true, 3);
    ASSERT_TRUE(line.endsWith('\n'));
    const QJsonObject o = QJsonDocument::fromJson(line.trimmed()).object();
    EXPECT_EQ(o.value(QStringLiteral("type")).toString(), QStringLiteral("screensaver"));
    EXPECT_TRUE(o.value(QStringLiteral("inhibited")).toBool());
    EXPECT_EQ(o.value(QStringLiteral("count")).toInt(), 3);
    EXPECT_EQ(QJsonDocument::fromJson(screensaverMessage(false, 99999).trimmed()).object().value(QStringLiteral("count")).toInt(), 1024);
    EXPECT_EQ(QJsonDocument::fromJson(screensaverMessage(false, -1).trimmed()).object().value(QStringLiteral("count")).toInt(), 0);
}

TEST(ScreenSaverIntrospection, TwoMethodsOnly) {
    const QString xml = interfaceXml();
    EXPECT_TRUE(xml.contains(QStringLiteral("name=\"Inhibit\"")));
    EXPECT_TRUE(xml.contains(QStringLiteral("name=\"UnInhibit\"")));
    EXPECT_EQ(xml.count(QStringLiteral("<method")), 2);
}

// ADR-0041 I-4: xdg-desktop-portal-gtk's ScreenSaver proxy (gdbus-codegen) calls Properties.GetAll; the bridge dropped the
// call and the portal's startup waited out D-Bus's 25 s method timeout. Every call is answered (NoReplyExpected ones aside:
// sendReply and sendError check isReplyRequired, proven on a bus in tests/integration/screensaver_inhibit.sh).
namespace {
    const QString kOwn   = QStringLiteral("org.freedesktop.ScreenSaver");
    const QString kProps = QStringLiteral("org.freedesktop.DBus.Properties");
    const QString kUnknownProperty  = QStringLiteral("org.freedesktop.DBus.Error.UnknownProperty");
    const QString kUnknownInterface = QStringLiteral("org.freedesktop.DBus.Error.UnknownInterface");
    const QString kUnknownMethod    = QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod");
    const QString kInvalidArgs      = QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs");
    std::optional<ForeignAnswer> foreign(const QString& iface, const QString& member, const QString& sig, const QVariantList& args) {
        return answerForeign(iface, member, sig, args, kOwn);
    }
} // namespace

TEST(ScreenSaverEveryCallAnswered, GetAllIsAnEmptyDictionary) {
    const auto a = foreign(kProps, QStringLiteral("GetAll"), QStringLiteral("s"), {kOwn});
    ASSERT_TRUE(a.has_value());
    EXPECT_TRUE(a->reply);
    ASSERT_EQ(a->values.size(), 1);
    EXPECT_TRUE(a->values.at(0).toMap().isEmpty());
    ASSERT_TRUE(foreign(kProps, QStringLiteral("GetAll"), QStringLiteral("s"), {QString()}).has_value());
    EXPECT_TRUE(foreign(kProps, QStringLiteral("GetAll"), QStringLiteral("s"), {QString()})->reply);
    EXPECT_EQ(foreign(kProps, QStringLiteral("GetAll"), QStringLiteral("s"), {QStringLiteral("org.other.Thing")})->error, kUnknownInterface);
    EXPECT_EQ(foreign(kProps, QStringLiteral("GetAll"), QString(), {})->error, kInvalidArgs);
}

TEST(ScreenSaverEveryCallAnswered, GetAndSetAreUnknownProperty) {
    EXPECT_EQ(foreign(kProps, QStringLiteral("Get"), QStringLiteral("ss"), {kOwn, QStringLiteral("X")})->error, kUnknownProperty);
    EXPECT_EQ(foreign(kProps, QStringLiteral("Set"), QStringLiteral("ssv"), {kOwn, QStringLiteral("X"), 1})->error, kUnknownProperty);
    EXPECT_EQ(foreign(kProps, QStringLiteral("Get"), QStringLiteral("s"), {kOwn})->error, kInvalidArgs);
    EXPECT_EQ(foreign(kProps, QStringLiteral("Frobnicate"), QString(), {})->error, kUnknownMethod);
}

TEST(ScreenSaverEveryCallAnswered, UnknownInterfaceAndMember) {
    const auto a = foreign(QStringLiteral("org.example.Other"), QStringLiteral("Anything"), QString(), {});
    ASSERT_TRUE(a.has_value());
    EXPECT_FALSE(a->reply);
    EXPECT_EQ(a->error, kUnknownInterface);
    EXPECT_FALSE(foreign(kOwn, QStringLiteral("Inhibit"), QStringLiteral("ss"), {}).has_value()) << "the object's own interface is not foreign";
    EXPECT_FALSE(foreign(QString(), QStringLiteral("Inhibit"), QStringLiteral("ss"), {}).has_value()) << "no interface: the object's own";
    Book book;
    EXPECT_EQ(call(book, QStringLiteral("Frobnicate"), QString(), {}).error, kUnknownMethod);
}

TEST(ScreenSaverEveryCallAnswered, ANonUniqueSenderIsRefusedNotDropped) {
    Book         book;
    const Answer a = call(book, QStringLiteral("Inhibit"), QStringLiteral("ss"), {QStringLiteral("x"), QStringLiteral("y")}, QStringLiteral("org.example.Wellknown"));
    EXPECT_EQ(a.kind, Answer::Kind::Error);
    EXPECT_EQ(a.error, QStringLiteral("org.freedesktop.DBus.Error.AccessDenied"));
    EXPECT_FALSE(book.active()) << "no cookie for it";
}
