// grassfield-portal's permission alerts (ADR-0035 D-5; docs/specs/system-dialogs.md section 2, AC1-AC3): what the alert is
// given (Access::toQml), and org.freedesktop.impl.portal.Access on the run's private bus (tst_filechooser.cpp's main) with a
// fake frontend and a fake x-d-p-gtk: the answer, Close, the bounds and the forward.
#include <gtest/gtest.h>

#include <QDir>

#include <QFile>

#include <QTemporaryDir>

#include "access.h"
#include "chooserlogic.h"

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDeadlineTimer>
#include <QTest>
#include <QTranslator>
#include <QWindow>

#include <functional>
#include <limits>
#include <memory>

using namespace grassfield::portal;
using namespace grassfield::portal::chooser;

extern QString g_address;

namespace {

constexpr auto kService = "org.freedesktop.impl.portal.desktop.grassfield";
constexpr auto kFakeGtk = "org.test.fakegtk.access";
constexpr int kDeadlineMs = 1500;

// x-d-p-gtk's Access as the forward sees it: answers every call with what the test set.
class FakeGtkAccess : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.Access")
public:
    QStringList calls;
    uint response = 0;
    QVariantMap answer;
    bool hold = false; // keep the call open (until a Close)
    QDBusMessage held;

public Q_SLOTS:
    uint AccessDialog(const QDBusObjectPath &handle, const QString &, const QString &, const QString &title, const QString &,
                      const QString &, const QVariantMap &, const QDBusMessage &message, QVariantMap &results)
    {
        calls << QStringLiteral("AccessDialog %1 %2").arg(handle.path(), title);
        if (hold) {
            message.setDelayedReply(true);
            held = message;
            return 0;
        }
        results = answer;
        return response;
    }
};

// x-d-p-gtk's Request object of a forwarded call.
class FakeGtkRequest : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.Request")
public:
    std::function<void()> onClose;
public Q_SLOTS:
    Q_SCRIPTABLE void Close()
    {
        if (onClose)
            onClose();
    }
};

struct Reply {
    bool done = false;
    bool error = false;
    uint response = 99;
    QVariantMap results;
};

// A language's catalog for the frontend's texts (the alert's context): each known English text has its own translation.
class FakeCatalog : public QTranslator
{
public:
    QHash<QString, QString> texts;
    bool isEmpty() const override { return false; }
    QString translate(const char *context, const char *source, const char *, int) const override
    {
        return qstrcmp(context, "AccessAlert") == 0 ? texts.value(QString::fromUtf8(source)) : QString();
    }
};

QList<Choice> twoChoices()
{
    return {Choice{QStringLiteral("remember"), QStringLiteral("_Remember"), {}, QStringLiteral("true")},
            Choice{QStringLiteral("level"), QStringLiteral("Accuracy"),
                   {Pair{QStringLiteral("city"), QStringLiteral("_City")}, Pair{QStringLiteral("exact"), QStringLiteral("Exact")}},
                   QStringLiteral("nope")}};
}

class AccessTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        static int n = 0;
        const QString suffix = QString::number(++n);
        backendBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("access-backend") + suffix));
        frontendBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("access-frontend") + suffix));
        gtkBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("access-gtk") + suffix));
        ASSERT_TRUE(backendBus->isConnected() && frontendBus->isConnected() && gtkBus->isConnected());
        make();
        ASSERT_TRUE(gtkBus->registerObject(QStringLiteral("/org/freedesktop/portal/desktop"), &gtk, QDBusConnection::ExportAllSlots));
        ASSERT_TRUE(gtkBus->registerService(QString::fromLatin1(kFakeGtk)));
    }

    // The backend under test, exported as main.cpp does it: the adaptor on the exported object.
    void make(int maxPending = 16)
    {
        Access::Options options;
        options.gtkService = QString::fromLatin1(kFakeGtk);
        options.uiDeadlineMs = kDeadlineMs;
        options.idleQuitMs = 200;
        options.maxPending = maxPending;
        access = std::make_unique<Access>(*backendBus, options);
        exported = std::make_unique<QObject>();
        new AccessAdaptor(exported.get(), access.get());
        ASSERT_TRUE(backendBus->registerObject(QStringLiteral("/org/freedesktop/portal/desktop"), exported.get(), QDBusConnection::ExportAdaptors));
        ASSERT_TRUE(backendBus->registerService(QString::fromLatin1(kService)));
        QObject::connect(access.get(), &Access::opened, access.get(), [this](int id, const QVariantMap &alert) { opened.append({id, alert}); });
        QObject::connect(access.get(), &Access::closed, access.get(), [this](int id) { closed.append(id); });
    }

    void TearDown() override
    {
        backendBus->unregisterService(QString::fromLatin1(kService));
        backendBus->unregisterObject(QStringLiteral("/org/freedesktop/portal/desktop"));
        gtkBus->unregisterService(QString::fromLatin1(kFakeGtk));
        access.reset();
        exported.reset();
        QDBusConnection::disconnectFromBus(backendBus->name());
        QDBusConnection::disconnectFromBus(frontendBus->name());
        QDBusConnection::disconnectFromBus(gtkBus->name());
    }

    // The frontend's call (src/camera.c and the others): AccessDialog on the backend's name, no timeout.
    std::shared_ptr<Reply> call(const QString &handle, const QVariantMap &options, const QString &appId = QStringLiteral("org.example.App"))
    {
        QDBusMessage m = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                        QStringLiteral("org.freedesktop.impl.portal.Access"), QStringLiteral("AccessDialog"));
        m << QVariant::fromValue(QDBusObjectPath(handle)) << appId << QString() << QStringLiteral("Allow Example to Use the Camera?")
          << QStringLiteral("Example wants to access the camera") << QStringLiteral("This permission can be changed at any time from the privacy settings")
          << options;
        auto reply = std::make_shared<Reply>();
        auto *w = new QDBusPendingCallWatcher(frontendBus->asyncCall(m, std::numeric_limits<int>::max()));
        QObject::connect(w, &QDBusPendingCallWatcher::finished, w, [reply](QDBusPendingCallWatcher *watcher) {
            watcher->deleteLater();
            const QDBusMessage r = watcher->reply();
            reply->done = true;
            reply->error = r.type() != QDBusMessage::ReplyMessage;
            if (!reply->error && r.arguments().size() == 2) {
                reply->response = r.arguments().at(0).toUInt();
                reply->results = qdbus_cast<QVariantMap>(r.arguments().at(1));
            }
        });
        return reply;
    }

    bool waitFor(const std::function<bool()> &condition, int ms = 3000)
    {
        QDeadlineTimer deadline(ms);
        while (!condition() && !deadline.hasExpired())
            QTest::qWait(10);
        return condition();
    }

    static QList<Pair> choicesOf(const QVariantMap &results)
    {
        const QVariant v = results.value(QStringLiteral("choices"));
        if (v.metaType() == QMetaType::fromType<QDBusArgument>())
            return qdbus_cast<QList<Pair>>(v.value<QDBusArgument>());
        return v.value<QList<Pair>>();
    }

    std::unique_ptr<QDBusConnection> backendBus, frontendBus, gtkBus;
    std::unique_ptr<Access> access;
    std::unique_ptr<QObject> exported;
    FakeGtkAccess gtk;
    QList<QPair<int, QVariantMap>> opened;
    QList<int> closed;
};

} // namespace

// What the alert is given: the frontend's strings as one plain line each, its labels without GTK's mnemonics, a symbolic icon
// name or none, and no default button for the camera and screen capture (AC2).
TEST(AccessToQml, ChecksWhatTheFrontendGives)
{
    registerTypes();
    const QVariantMap camera = Access::toQml(QStringLiteral("org.example.App"), QStringLiteral("wayland:abc"),
                                             QStringLiteral("Allow Example\nto Use the Camera?") + QChar(0x202E), QStringLiteral("sub"), QString(),
                                             {{QStringLiteral("icon"), QStringLiteral("camera-web-symbolic")},
                                              {QStringLiteral("deny_label"), QStringLiteral("_Not Now")},
                                              {QStringLiteral("grant_label"), QStringLiteral("Grant __Access")},
                                              {QStringLiteral("modal"), false},
                                              {QStringLiteral("choices"), QVariant::fromValue(twoChoices())}});
    EXPECT_EQ(camera.value("title").toString(), QStringLiteral("Allow Example to Use the Camera?"));
    EXPECT_EQ(camera.value("denyLabel").toString(), QStringLiteral("Not Now"));
    EXPECT_EQ(camera.value("grantLabel").toString(), QStringLiteral("Grant _Access"));
    EXPECT_EQ(camera.value("icon").toString(), QStringLiteral("camera-web-symbolic"));
    EXPECT_TRUE(camera.value("noDefault").toBool());
    EXPECT_FALSE(camera.value("modal").toBool());
    EXPECT_TRUE(camera.value("parented").toBool());
    const QVariantList choices = camera.value("choices").toList();
    ASSERT_EQ(choices.size(), 2);
    EXPECT_EQ(choices.at(0).toMap().value("label").toString(), QStringLiteral("Remember"));
    EXPECT_EQ(choices.at(1).toMap().value("initial").toString(), QStringLiteral("city")) << "an initial value it does not offer";

    EXPECT_TRUE(Access::toQml({}, {}, {}, {}, {}, {{QStringLiteral("icon"), QStringLiteral("applets-screenshooter-symbolic")}}).value("noDefault").toBool());
    const QVariantMap location = Access::toQml({}, QStringLiteral("x11:12"), {}, {}, {}, {{QStringLiteral("icon"), QStringLiteral("find-location-symbolic")}});
    EXPECT_FALSE(location.value("noDefault").toBool()) << "the grant button is the default";
    EXPECT_FALSE(location.value("parented").toBool()) << "only a wayland: handle";
    EXPECT_TRUE(location.value("modal").toBool()) << "modal by default";
    EXPECT_EQ(Access::toQml({}, {}, {}, {}, {}, {{QStringLiteral("icon"), QStringLiteral("../../etc/passwd")}}).value("icon").toString(), QString());
    EXPECT_EQ(Access::toQml({}, {}, QString(2000, u'x'), {}, {}, {}).value("title").toString().size(), kMaxTextLength);
}

// Any process on the session bus can call the backend: an option of the wrong type is no option (never a crash).
TEST(AccessToQml, OptionsOfTheWrongTypeAreNoOptions)
{
    registerTypes();
    const QVariantMap alert = Access::toQml({}, {}, QStringLiteral("t"), {}, {},
                                            {{QStringLiteral("icon"), 7},
                                             {QStringLiteral("deny_label"), QStringList{QStringLiteral("x")}},
                                             {QStringLiteral("modal"), QStringLiteral("false")},
                                             {QStringLiteral("choices"), QStringLiteral("a(ssa(ss)s)")}});
    EXPECT_EQ(alert.value("icon").toString(), QString());
    EXPECT_EQ(alert.value("denyLabel").toString(), QString());
    EXPECT_TRUE(alert.value("modal").toBool());
    EXPECT_TRUE(alert.value("choices").toList().isEmpty());
}

// The alert's answer goes back as response 0 (grant) or 1 (deny), with every choice: the alert's value when the choice allows
// it, else its initial value.
// xdg-desktop-portal 1.22.1's own wording comes in English whatever the language (its French catalog is empty): the alert gives
// it in Grassfield's language with the application's name kept, a wording it does not know as it came, and the frontend's own
// button labels as the alert's "Don't Allow" and "Allow" (integrator nested pass of 1745c0c, MINOR 6; ADR-0035 5a-9).
TEST(AccessToQml, TheFrontendsOwnWordingIsInGrassfieldsLanguage)
{
    registerTypes();
    FakeCatalog french;
    french.texts = {{QStringLiteral("Allow %1 to Use the Camera?"), QStringLiteral("Autoriser %1 à utiliser la caméra ?")},
                    {QStringLiteral("Allow Apps to Use the Camera?"), QStringLiteral("Autoriser les apps à utiliser la caméra ?")},
                    {QStringLiteral("%1 wants to use your location"), QStringLiteral("%1 souhaite utiliser votre position")},
                    {QStringLiteral("This permission can be changed at any time from the privacy settings"), QStringLiteral("Modifiable dans les réglages")},
                    {QStringLiteral("The \u2018run in background\u2019 permission can be changed at any time from the app settings"), QStringLiteral("Arrière-plan")}};
    ASSERT_TRUE(QCoreApplication::installTranslator(&french));
    const auto title = [](const QString &text) { return Access::toQml({}, {}, text, {}, {}, {}).value("title").toString(); };
    EXPECT_EQ(title(QStringLiteral("Allow Foot to Use the Camera?")), QStringLiteral("Autoriser Foot à utiliser la caméra ?"));
    EXPECT_EQ(title(QStringLiteral("Allow Apps to Use the Camera?")), QStringLiteral("Autoriser les apps à utiliser la caméra ?"))
        << "the wording without a name, not \"Apps\" as a name";
    EXPECT_EQ(title(QStringLiteral("Allow Foot to Fly?")), QStringLiteral("Allow Foot to Fly?")) << "a wording it does not know";
    const QVariantMap location = Access::toQml({}, {}, {}, QStringLiteral("Map Café wants to use your location"),
                                               QStringLiteral("This permission can be changed at any time from the privacy settings"),
                                               {{QStringLiteral("deny_label"), QStringLiteral("Deny Access")}, {QStringLiteral("grant_label"), QStringLiteral("Grant _Access")}});
    EXPECT_EQ(location.value("subtitle").toString(), QStringLiteral("Map Café souhaite utiliser votre position"));
    EXPECT_EQ(location.value("body").toString(), QStringLiteral("Modifiable dans les réglages"));
    EXPECT_EQ(location.value("denyLabel").toString(), QString()) << "the frontend's own label: the alert's own";
    EXPECT_EQ(location.value("grantLabel").toString(), QString()) << "the frontend's own label, its mnemonic gone";
    EXPECT_EQ(Access::toQml({}, {}, {}, {}, QString::fromUtf8("The \u2018run in background\u2019 permission can be changed at any time from the app settings"), {})
                  .value("body").toString(), QStringLiteral("Arrière-plan"));
    for (const char *known : {"Deny", "Allow", "Don't allow", "_Deny"})
        EXPECT_EQ(Access::toQml({}, {}, {}, {}, {}, {{QStringLiteral("deny_label"), QString::fromLatin1(known)}}).value("denyLabel").toString(), QString()) << known;
    QCoreApplication::removeTranslator(&french);
    EXPECT_EQ(title(QStringLiteral("Allow Foot to Use the Camera?")), QStringLiteral("Allow Foot to Use the Camera?")) << "English: as it came";
}

// SP-18: the application's entry (its name and icon) is read on a worker, never on the GUI thread (a stale ksycoca is
// rebuilt there): the alert comes once it is known, with the entry's icon, and appName answers from what was read.
TEST_F(AccessTest, TheApplicationsEntryIsReadOffTheGuiThread)
{
    QTemporaryDir home;
    ASSERT_TRUE(home.isValid());
    const QByteArray dataHome = qgetenv("XDG_DATA_HOME"), cacheHome = qgetenv("XDG_CACHE_HOME");
    qputenv("XDG_DATA_HOME", QFile::encodeName(home.filePath(QStringLiteral("data"))));
    qputenv("XDG_CACHE_HOME", QFile::encodeName(home.filePath(QStringLiteral("cache"))));
    QDir().mkpath(home.filePath(QStringLiteral("data/applications")));
    QFile entry(home.filePath(QStringLiteral("data/applications/org.example.Booth.desktop")));
    ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
    entry.write("[Desktop Entry]\nType=Application\nName=Booth Camera\nIcon=booth-camera\nExec=booth\n");
    entry.close();
    access->setUiLoader([] { return true; });
    EXPECT_EQ(access->appName(QStringLiteral("org.example.Booth")), QString()) << "nothing read on the GUI thread";
    auto reply = call(QStringLiteral("/r/booth"), {}, QStringLiteral("org.example.Booth"));
    ASSERT_TRUE(waitFor([&] { return opened.size() == 1; }, 20000));
    EXPECT_EQ(opened.first().second.value("appIcon").toString(), QStringLiteral("booth-camera"));
    EXPECT_EQ(access->appName(QStringLiteral("org.example.Booth")), QStringLiteral("Booth Camera"));
    access->answer(opened.first().first, false);
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    qputenv("XDG_DATA_HOME", dataHome);
    qputenv("XDG_CACHE_HOME", cacheHome);
}

TEST_F(AccessTest, TheAlertsAnswerGoesBack)
{
    access->setUiLoader([] { return true; });
    auto granted = call(QStringLiteral("/r/a1"), {{QStringLiteral("icon"), QStringLiteral("camera-web-symbolic")},
                                                  {QStringLiteral("choices"), QVariant::fromValue(twoChoices())}});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 1; }));
    const QVariantMap alert = opened.first().second;
    EXPECT_EQ(alert.value("title").toString(), QStringLiteral("Allow Example to Use the Camera?"));
    EXPECT_EQ(alert.value("subtitle").toString(), QStringLiteral("Example wants to access the camera"));
    EXPECT_TRUE(alert.value("noDefault").toBool());
    EXPECT_TRUE(alert.contains("appIcon"));
    access->answer(opened.first().first, true,
                   {QVariantMap{{QStringLiteral("id"), QStringLiteral("remember")}, {QStringLiteral("value"), QStringLiteral("false")}},
                    QVariantMap{{QStringLiteral("id"), QStringLiteral("level")}, {QStringLiteral("value"), QStringLiteral("anything")}}});
    ASSERT_TRUE(waitFor([&] { return granted->done; }));
    EXPECT_FALSE(granted->error);
    EXPECT_EQ(granted->response, 0u);
    const QList<Pair> choices = choicesOf(granted->results);
    ASSERT_EQ(choices.size(), 2);
    EXPECT_EQ(choices.at(0), (Pair{QStringLiteral("remember"), QStringLiteral("false")}));
    EXPECT_EQ(choices.at(1), (Pair{QStringLiteral("level"), QStringLiteral("city")})) << "a value the choice does not allow";

    auto denied = call(QStringLiteral("/r/a2"), {});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 2; }));
    access->answer(opened.last().first, false);
    ASSERT_TRUE(waitFor([&] { return denied->done; }));
    EXPECT_EQ(denied->response, 1u);
    EXPECT_FALSE(denied->results.contains("choices")) << "no choices asked, none answered";
    EXPECT_TRUE(waitFor([&] { return access->pending() == 0; }));
}

// Close takes the alert away and ends the call with a D-Bus error, never a response: the frontend keeps any response but 0
// as "no" for a permission not decided yet, and nothing after an error (ADR-0035 5a-3, review of step 5a, MINOR 1). An answer
// after it is ignored.
TEST_F(AccessTest, CloseEndsTheRequestWithoutAnAnswer)
{
    access->setUiLoader([] { return true; });
    auto reply = call(QStringLiteral("/r/c1"), {});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 1; }));
    const int id = opened.first().first;
    frontendBus->asyncCall(QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/r/c1"),
                                                          QStringLiteral("org.freedesktop.impl.portal.Request"), QStringLiteral("Close")));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_TRUE(reply->error) << "an error, not response " << reply->response;
    EXPECT_TRUE(closed.contains(id));
    access->answer(id, true);
    EXPECT_EQ(access->pending(), 0);
}

// A backend that goes with an alert open, and a forward x-d-p-gtk never answers, end the call with an error too.
TEST_F(AccessTest, NoAnswerIsNeverAResponse)
{
    access->setUiLoader([] { return true; });
    auto open = call(QStringLiteral("/r/n1"), {});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 1; }));
    backendBus->unregisterObject(QStringLiteral("/org/freedesktop/portal/desktop"));
    access.reset();
    ASSERT_TRUE(waitFor([&] { return open->done; }));
    EXPECT_TRUE(open->error) << "response " << open->response;

    make();
    gtkBus->unregisterService(QString::fromLatin1(kFakeGtk));
    access->setUiLoader([] { return false; });
    auto lost = call(QStringLiteral("/r/n2"), {});
    ASSERT_TRUE(waitFor([&] { return lost->done; }));
    EXPECT_TRUE(lost->error) << "response " << lost->response;
}

// The process quits only once every interface has had no request for the idle time: an interface that has just ended its last
// request holds the other's quit (review of step 5a, MINOR 3).
TEST_F(AccessTest, QuietOnlyWhenEveryInterfaceIs)
{
    Access::Options options;
    options.idleQuitMs = 200;
    Access other(*backendBus, options);
    access->setUiLoader([] { return true; });
    auto reply = call(QStringLiteral("/r/q1"), {});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 1; }));
    QTest::qWait(250);
    EXPECT_FALSE(RequestHost::quiet({access.get(), &other}, 200)) << "a request open";
    access->answer(opened.first().first, false);
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_FALSE(RequestHost::quiet({access.get(), &other}, 200)) << "one just ended its last request";
    EXPECT_TRUE(waitFor([&] { return RequestHost::quiet({access.get(), &other}, 200); }, 1000));
    Access late(*backendBus, options);
    EXPECT_FALSE(RequestHost::quiet({access.get(), &other, &late}, 200)) << "a host quiet for less than the idle time";
}

// Without a UI every call goes to x-d-p-gtk's Access, and its answer comes back with the choices (a(ss)) only.
TEST_F(AccessTest, WithoutAUiTheCallGoesToGtk)
{
    access->setUiLoader([] { return false; });
    gtk.response = 1;
    gtk.answer = {{QStringLiteral("choices"), QVariant::fromValue(QList<Pair>{Pair{QStringLiteral("remember"), QStringLiteral("true")}})},
                  {QStringLiteral("uris"), QStringList{QStringLiteral("file:///x")}}};
    auto reply = call(QStringLiteral("/r/g1"), {{QStringLiteral("choices"), QVariant::fromValue(twoChoices())}});
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_TRUE(opened.isEmpty());
    ASSERT_EQ(gtk.calls.size(), 1);
    EXPECT_EQ(gtk.calls.first(), QStringLiteral("AccessDialog /r/g1 Allow Example to Use the Camera?"));
    EXPECT_EQ(reply->response, 1u);
    EXPECT_EQ(choicesOf(reply->results), (QList<Pair>{Pair{QStringLiteral("remember"), QStringLiteral("true")}}));
    EXPECT_FALSE(reply->results.contains("uris")) << "only what the interface defines";
}

// Close of a forwarded request reaches x-d-p-gtk, and its closed dialog's answer is no answer of the user's: the call ends
// with an error (counter-review of step 5a, MINOR).
TEST_F(AccessTest, CloseOfAForwardedRequestIsNoAnswer)
{
    access->setUiLoader([] { return false; });
    gtk.hold = true;
    FakeGtkRequest gtkRequest;
    gtkRequest.onClose = [&] { gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(2u), QVariantMap()})); };
    ASSERT_TRUE(gtkBus->registerObject(QStringLiteral("/r/f1"), &gtkRequest, QDBusConnection::ExportScriptableSlots));
    auto reply = call(QStringLiteral("/r/f1"), {});
    ASSERT_TRUE(waitFor([&] { return gtk.held.type() == QDBusMessage::MethodCallMessage; }));
    frontendBus->asyncCall(QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/r/f1"),
                                                          QStringLiteral("org.freedesktop.impl.portal.Request"), QStringLiteral("Close")));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_TRUE(reply->error) << "an error, not response " << reply->response;
    gtkBus->unregisterObject(QStringLiteral("/r/f1"));
}

// An alert that has not drawn its first frame within the deadline is dropped and the call goes to x-d-p-gtk (FC7).
TEST_F(AccessTest, AnAlertWithoutAFrameInTimeGoesToGtk)
{
    access->setUiLoader([] { return true; });
    gtk.response = 0;
    auto reply = call(QStringLiteral("/r/d1"), {});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 1; }));
    QTest::qWait(kDeadlineMs / 2);
    EXPECT_FALSE(reply->done) << "well before the deadline";
    ASSERT_TRUE(waitFor([&] { return reply->done; }, 3 * kDeadlineMs));
    EXPECT_EQ(gtk.calls.size(), 1);
    EXPECT_EQ(reply->response, 0u);
    EXPECT_TRUE(closed.contains(opened.first().first)) << "its alert goes";
}

// Once the call has gone to x-d-p-gtk, a late answer of the alert (its window was still there) is ignored: the application
// gets x-d-p-gtk's answer (integrator review of e24ea5c, NIT 2).
TEST_F(AccessTest, AnAnswerAfterTheForwardIsIgnored)
{
    access->setUiLoader([] { return true; });
    gtk.hold = true;
    auto reply = call(QStringLiteral("/r/l1"), {});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 1; }));
    ASSERT_TRUE(waitFor([&] { return gtk.held.type() == QDBusMessage::MethodCallMessage; }, 3 * kDeadlineMs));
    access->answer(opened.first().first, true);
    QTest::qWait(200);
    EXPECT_FALSE(reply->done) << "the alert answered after the forward: response " << reply->response;
    gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(1u), QVariantMap()}));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_FALSE(reply->error);
    EXPECT_EQ(reply->response, 1u) << "x-d-p-gtk's answer";
    EXPECT_EQ(access->pending(), 0);
}

// One alert at a time: an alert waiting for another to go has no deadline (it is not sent to x-d-p-gtk for waiting), and has
// the whole deadline again once its window is presented (integrator nested pass of 1745c0c, MINOR 5).
TEST_F(AccessTest, AnAlertWaitingItsTurnHasNoDeadline)
{
    access->setUiLoader([] { return true; });
    gtk.response = 0;
    auto first = call(QStringLiteral("/r/q1"), {});
    auto second = call(QStringLiteral("/r/q2"), {});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 2; }));
    const int waiting = opened.at(1).first;
    access->queue(waiting);
    ASSERT_TRUE(waitFor([&] { return first->done; }, 3 * kDeadlineMs)) << "the first, never drawn, goes to x-d-p-gtk";
    QTest::qWait(kDeadlineMs);
    EXPECT_FALSE(second->done) << "the waiting one is not sent on";
    EXPECT_EQ(gtk.calls.size(), 1);
    // Its turn: a window that never draws a frame, and the deadline counts from now.
    QWindow window;
    access->present(waiting, &window);
    QTest::qWait(kDeadlineMs / 2);
    EXPECT_FALSE(second->done) << "well before its deadline";
    ASSERT_TRUE(waitFor([&] { return second->done; }, 3 * kDeadlineMs));
    EXPECT_EQ(gtk.calls.size(), 2);
    EXPECT_TRUE(closed.contains(waiting));
}

// At most maxPending requests at once, one request per handle: the others end at once, with an error (no answer).
TEST_F(AccessTest, RequestsAreBounded)
{
    TearDown();
    backendBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("access-backend-bound")));
    frontendBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("access-frontend-bound")));
    gtkBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("access-gtk-bound")));
    make(2);
    access->setUiLoader([] { return true; });
    auto first = call(QStringLiteral("/r/b1"), {});
    auto twin = call(QStringLiteral("/r/b1"), {});
    auto second = call(QStringLiteral("/r/b2"), {});
    auto third = call(QStringLiteral("/r/b3"), {});
    ASSERT_TRUE(waitFor([&] { return twin->done && third->done; }));
    EXPECT_TRUE(twin->error) << "the same handle twice";
    EXPECT_TRUE(third->error) << "past the bound";
    EXPECT_FALSE(first->done);
    EXPECT_FALSE(second->done);
    EXPECT_EQ(access->pending(), 2);
    for (const auto &o : std::as_const(opened))
        access->answer(o.first, false);
    ASSERT_TRUE(waitFor([&] { return first->done && second->done; }));
}

#include "tst_access.moc"
