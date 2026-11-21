// ADR-0035 D-4, docs/specs/system-dialogs.md section 1 (FC1-FC3, FC7; A-FC1, A-FC4): grassfield-portal's FileChooser on a
// private dbus-daemon, called by a fake frontend the way xdg-desktop-portal 1.22.1 calls it, with a fake x-d-p-gtk for the
// forward. The panels are stood in for by the test (the `opened` signal and the QML API); a QQuickWindow stands in for a
// panel's window. Its own main: offscreen Qt, the private bus started and stopped here.
#include <gtest/gtest.h>

#include "chooserlogic.h"
#include "filechooser.h"
#include "panelstate.h"
#include "printpreview.h"

#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCall>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDeadlineTimer>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QGuiApplication>
#include <QMutex>
#include <QProcess>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QThread>

#include <atomic>
#include <QTest>

#include <functional>

using namespace grassfield::portal;
using namespace grassfield::portal::chooser;

// The private bus of the whole run (main below); tst_access.cpp's tests use it too.
QString g_address;

namespace {

constexpr auto kService = "org.freedesktop.impl.portal.desktop.grassfield";
constexpr auto kFakeGtk = "org.test.fakegtk";

// x-d-p-gtk as the forward sees it: answers every call with what the test set, and records Close.
class FakeGtk : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.FileChooser")
public:
    QStringList calls;
    QVariantMap answer;
    bool hold = false; // keep the call open (until a Close)
    QDBusMessage held;
    QDBusConnection *bus = nullptr;

public Q_SLOTS:
    uint OpenFile(const QDBusObjectPath &handle, const QString &, const QString &, const QString &title, const QVariantMap &,
                  const QDBusMessage &message, QVariantMap &results)
    {
        calls << QStringLiteral("OpenFile %1 %2").arg(handle.path(), title);
        if (hold) {
            message.setDelayedReply(true);
            held = message;
            return 0;
        }
        results = answer;
        return 0;
    }
    uint SaveFile(const QDBusObjectPath &handle, const QString &, const QString &, const QString &, const QVariantMap &,
                  QVariantMap &results)
    {
        calls << QStringLiteral("SaveFile %1").arg(handle.path());
        results = answer;
        return 0;
    }
};

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

// A hung mount, as the fixture's backend sees it: reading a path under /slowmnt takes kSlowMs (the probe's deadline is far
// shorter); kSlowReads counts the reads.
constexpr int kSlowMs = 2500;
constexpr int kProbeMs = 400;
std::atomic<int> kSlowReads{0};

// A share that is slow but answering: each read under /slowish takes kSlowishMs, under the probe's deadline.
constexpr int kSlowishMs = 250;

int slowStat(const QString &path)
{
    if (path.startsWith(QLatin1String("/slowmnt"))) {
        ++kSlowReads;
        QThread::msleep(kSlowMs);
        return 2;
    }
    if (path.startsWith(QLatin1String("/slowish"))) {
        QThread::msleep(kSlowishMs);
        return 2;
    }
    return DiskProbe::kindOf(path);
}

// The waits of the fixture's backend: the deadline far above a loaded machine's latency between the call and opened(), the
// "well before the deadline" waits half of it (review of step 4b, NIT 12).
constexpr int kDeadlineMs = 1500;
constexpr int kIdleMs = 200;

class FileChooserTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        static int n = 0;
        const QString suffix = QString::number(++n);
        backendBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("backend") + suffix));
        frontendBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("frontend") + suffix));
        gtkBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("gtk") + suffix));
        ASSERT_TRUE(backendBus->isConnected() && frontendBus->isConnected() && gtkBus->isConnected());
        registerTypes();

        FileChooser::Options options;
        options.gtkService = QString::fromLatin1(kFakeGtk);
        options.uiDeadlineMs = kDeadlineMs;
        options.idleQuitMs = kIdleMs;
        options.probeDeadlineMs = kProbeMs;
        options.statPath = slowStat;
        options.state = &state;
        chooser = std::make_unique<FileChooser>(*backendBus, options);
        new FileChooserAdaptor(chooser.get());
        ASSERT_TRUE(backendBus->registerObject(QStringLiteral("/org/freedesktop/portal/desktop"), chooser.get(), QDBusConnection::ExportAdaptors));
        ASSERT_TRUE(backendBus->registerService(QString::fromLatin1(kService)));
        gtk.bus = gtkBus.get();
        ASSERT_TRUE(gtkBus->registerObject(QStringLiteral("/org/freedesktop/portal/desktop"), &gtk, QDBusConnection::ExportAllSlots));
        ASSERT_TRUE(gtkBus->registerService(QString::fromLatin1(kFakeGtk)));
        QObject::connect(chooser.get(), &FileChooser::opened, chooser.get(), [this](int id, const QVariantMap &request) {
            opened.append({id, request});
        });
        QObject::connect(chooser.get(), &FileChooser::closed, chooser.get(), [this](int id) { closed.append(id); });
    }

    void TearDown() override
    {
        backendBus->unregisterService(QString::fromLatin1(kService));
        gtkBus->unregisterService(QString::fromLatin1(kFakeGtk));
        chooser.reset();
        QDBusConnection::disconnectFromBus(backendBus->name());
        QDBusConnection::disconnectFromBus(frontendBus->name());
        QDBusConnection::disconnectFromBus(gtkBus->name());
    }

    // The frontend's call (src/file-chooser.c): the impl method on the backend's name, no timeout.
    std::shared_ptr<Reply> call(const QString &method, const QString &handle, const QVariantMap &options, const QString &title = QStringLiteral("Open"))
    {
        QDBusMessage m = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                        QStringLiteral("org.freedesktop.impl.portal.FileChooser"), method);
        m << QVariant::fromValue(QDBusObjectPath(handle)) << QStringLiteral("org.example.App") << QStringLiteral("wayland:token") << title
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

    void closeRequest(const QString &handle)
    {
        // Not a blocking call: the backend answers it from this thread's event loop.
        frontendBus->asyncCall(QDBusMessage::createMethodCall(QString::fromLatin1(kService), handle, QStringLiteral("org.freedesktop.impl.portal.Request"),
                                                              QStringLiteral("Close")));
    }

    QTemporaryDir dir;
    PanelState state{dir.filePath(QStringLiteral("portal-filechooser.json"))};
    std::unique_ptr<QDBusConnection> backendBus, frontendBus, gtkBus;
    std::unique_ptr<FileChooser> chooser;
    FakeGtk gtk;
    QList<QPair<int, QVariantMap>> opened;
    QList<int> closed;
};

QList<Filter> filters()
{
    return {Filter{QStringLiteral("Images"), {{0, QStringLiteral("*.png")}}}, Filter{QStringLiteral("Text"), {{1, QStringLiteral("text/plain")}}}};
}

} // namespace

TEST_F(FileChooserTest, OpenFileOverTheBusGivesThePanelsAnswer)
{
    chooser->setUiLoader([] { return true; });
    const QVariantMap options{{QStringLiteral("multiple"), true},
                              {QStringLiteral("filters"), QVariant::fromValue(filters())},
                              {QStringLiteral("current_filter"), QVariant::fromValue(filters().at(1))},
                              {QStringLiteral("choices"), QVariant::fromValue(QList<Choice>{{QStringLiteral("ro"), QStringLiteral("Read only"), {}, QStringLiteral("true")}})},
                              {QStringLiteral("current_folder"), QByteArray("/tmp\0", 5)}};
    auto reply = call(QStringLiteral("OpenFile"), QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/t1"), options);
    ASSERT_TRUE(waitFor([&] { return !opened.isEmpty(); }));
    // The panel got the options in the bus's own form (QDBusArgument), read.
    const QVariantMap request = opened.first().second;
    EXPECT_EQ(request.value("kind").toString(), QStringLiteral("open"));
    EXPECT_TRUE(request.value("multiple").toBool());
    EXPECT_EQ(request.value("currentFilter").toInt(), 1);
    EXPECT_EQ(request.value("filters").toList().size(), 2);
    EXPECT_EQ(request.value("choices").toList().size(), 1);
    EXPECT_EQ(request.value("currentFolder").toString(), QStringLiteral("file:///tmp"));
    EXPECT_EQ(chooser->pending(), 1);

    chooser->answer(opened.first().first, 0,
                    {{QStringLiteral("uris"), QVariantList{QStringLiteral("file:///tmp/a.txt"), QStringLiteral("file:///tmp/b.txt")}},
                     {QStringLiteral("choices"), QVariantList{QVariantMap{{"id", "ro"}, {"value", "false"}}}},
                     {QStringLiteral("filter"), 1}});
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_FALSE(reply->error);
    EXPECT_EQ(reply->response, 0u);
    EXPECT_EQ(reply->results.value("uris").toStringList(), (QStringList{QStringLiteral("file:///tmp/a.txt"), QStringLiteral("file:///tmp/b.txt")}));
    EXPECT_EQ(qdbus_cast<QList<Pair>>(reply->results.value("choices")), (QList<Pair>{{QStringLiteral("ro"), QStringLiteral("false")}}));
    EXPECT_EQ(qdbus_cast<Filter>(reply->results.value("current_filter")), filters().at(1));
    EXPECT_TRUE(reply->results.value("writable").toBool()); // 4b-17
    EXPECT_EQ(closed, QList<int>{opened.first().first});
    EXPECT_EQ(chooser->pending(), 0);
    // The request object is gone with the request.
    EXPECT_FALSE(backendBus->objectRegisteredAt(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/t1")));
}

// Options of the wrong D-Bus type, as any process on the session bus can send them to the backend's name (the frontend checks
// types, a direct caller does not): no option, never a crash; the backend goes on (review of step 4b, MINOR 3).
TEST_F(FileChooserTest, OptionsOfTheWrongTypeAreNoOptions)
{
    chooser->setUiLoader([] { return true; });
    const QList<Pair> pairs{{QStringLiteral("a"), QStringLiteral("b")}};
    const QVariantMap options{{QStringLiteral("filters"), QVariant::fromValue(pairs)},
                              {QStringLiteral("current_filter"), QVariant::fromValue(QList<Choice>{{QStringLiteral("c"), QStringLiteral("C"), {}, {}}})},
                              {QStringLiteral("choices"), QVariant::fromValue(filters())},
                              {QStringLiteral("current_folder"), QStringLiteral("/tmp")},
                              {QStringLiteral("multiple"), QStringLiteral("yes")}};
    auto reply = call(QStringLiteral("OpenFile"), QStringLiteral("/r/w1"), options);
    ASSERT_TRUE(waitFor([&] { return !opened.isEmpty(); }));
    const QVariantMap request = opened.first().second;
    EXPECT_TRUE(request.value("filters").toList().isEmpty());
    EXPECT_TRUE(request.value("choices").toList().isEmpty());
    chooser->answer(opened.first().first, 1);
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 1u);

    // SaveFiles' names as pairs: no names, so the request ends at once.
    auto names = call(QStringLiteral("SaveFiles"), QStringLiteral("/r/w2"), {{QStringLiteral("files"), QVariant::fromValue(pairs)}});
    ASSERT_TRUE(waitFor([&] { return names->done; }));
    EXPECT_FALSE(names->error);
    EXPECT_EQ(names->response, 2u);
    EXPECT_EQ(opened.size(), 1);
}

TEST_F(FileChooserTest, CancelAndCloseEndTheRequest)
{
    chooser->setUiLoader([] { return true; });
    auto cancelled = call(QStringLiteral("SaveFile"), QStringLiteral("/r/1"), {{QStringLiteral("current_name"), QStringLiteral("a.txt")}});
    auto closedByApp = call(QStringLiteral("SaveFiles"), QStringLiteral("/r/2"), {{QStringLiteral("files"), QVariant::fromValue(QByteArrayList{"a.txt"})}});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 2; }));
    // Each panel opens once its own folders are probed: in either order.
    const auto& save = opened.at(0).second.value("kind").toString() == QLatin1String("save") ? opened.at(0) : opened.at(1);
    const auto& saveFiles = &save == &opened.at(0) ? opened.at(1) : opened.at(0);
    EXPECT_EQ(save.second.value("currentName").toString(), QStringLiteral("a.txt"));
    EXPECT_EQ(saveFiles.second.value("files").toStringList(), QStringList{QStringLiteral("a.txt")});
    chooser->answer(save.first, 1);
    closeRequest(QStringLiteral("/r/2"));
    ASSERT_TRUE(waitFor([&] { return cancelled->done && closedByApp->done; }));
    EXPECT_EQ(cancelled->response, 1u);
    EXPECT_EQ(closedByApp->response, 2u);
    EXPECT_EQ(closed.size(), 2);
    // An answer after the end changes nothing.
    chooser->answer(saveFiles.first, 0, {{QStringLiteral("uris"), QVariantList{QStringLiteral("file:///tmp/a.txt")}}});
    EXPECT_EQ(chooser->pending(), 0);
}

TEST_F(FileChooserTest, AnAnswerThatBreaksTheInterfaceIsAnError)
{
    chooser->setUiLoader([] { return true; });
    auto reply = call(QStringLiteral("OpenFile"), QStringLiteral("/r/3"), {});
    ASSERT_TRUE(waitFor([&] { return !opened.isEmpty(); }));
    chooser->answer(opened.first().first, 0, {{QStringLiteral("uris"), QVariantList{QStringLiteral("sftp://host/a.txt")}}});
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 2u);
    EXPECT_FALSE(reply->results.contains("uris"));
}

TEST_F(FileChooserTest, WithoutAUiEveryCallGoesToGtkAndItsAnswerIsRelayed)
{
    chooser->setUiLoader([] { return false; });
    gtk.answer = {{QStringLiteral("uris"), QStringList{QStringLiteral("file:///tmp/from-gtk.txt")}},
                  {QStringLiteral("choices"), QVariant::fromValue(QList<Pair>{{QStringLiteral("ro"), QStringLiteral("true")}})},
                  {QStringLiteral("writable"), false}};
    auto reply = call(QStringLiteral("OpenFile"), QStringLiteral("/r/4"), {{QStringLiteral("multiple"), true}}, QStringLiteral("Pick"));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_TRUE(opened.isEmpty());
    EXPECT_EQ(gtk.calls, QStringList{QStringLiteral("OpenFile /r/4 Pick")}); // the same handle and arguments
    EXPECT_EQ(reply->response, 0u);
    EXPECT_EQ(reply->results.value("uris").toStringList(), QStringList{QStringLiteral("file:///tmp/from-gtk.txt")});
    EXPECT_EQ(qdbus_cast<QList<Pair>>(reply->results.value("choices")), (QList<Pair>{{QStringLiteral("ro"), QStringLiteral("true")}}));
    // x-d-p-gtk's read-only answer stays read-only (re-review of 6b26afc, C21).
    ASSERT_TRUE(reply->results.contains("writable"));
    EXPECT_FALSE(reply->results.value("writable").toBool());
}

TEST_F(FileChooserTest, APanelWithoutAFrameInTimeGoesToGtk)
{
    chooser->setUiLoader([] { return true; });
    gtk.answer = {{QStringLiteral("uris"), QStringList{QStringLiteral("file:///tmp/late.txt")}}};
    auto reply = call(QStringLiteral("SaveFile"), QStringLiteral("/r/5"), {});
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(opened.size(), 1);
    EXPECT_EQ(closed.size(), 1); // the panel that never showed is told to go
    EXPECT_EQ(gtk.calls, QStringList{QStringLiteral("SaveFile /r/5")});
    EXPECT_EQ(reply->results.value("uris").toStringList(), QStringList{QStringLiteral("file:///tmp/late.txt")});
    // The panel's late answer is ignored.
    chooser->answer(opened.first().first, 1);
    EXPECT_EQ(reply->response, 0u);
}

TEST_F(FileChooserTest, APanelThatShowsIsNotForwarded)
{
    chooser->setUiLoader([] { return true; });
    auto reply = call(QStringLiteral("OpenFile"), QStringLiteral("/r/6"), {});
    ASSERT_TRUE(waitFor([&] { return !opened.isEmpty(); }));
    QQuickWindow window;
    window.resize(200, 100);
    chooser->present(opened.first().first, &window);
    EXPECT_TRUE(window.isVisible());
    QTest::qWait(kDeadlineMs + 500); // past the deadline
    EXPECT_TRUE(gtk.calls.isEmpty());
    EXPECT_FALSE(reply->done);
    chooser->answer(opened.first().first, 1);
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 1u);
}

TEST_F(FileChooserTest, APanelThatCannotBeMadeGoesToGtkAtOnce)
{
    chooser->setUiLoader([] { return true; });
    gtk.answer = {{QStringLiteral("uris"), QStringList{QStringLiteral("file:///tmp/x")}}};
    auto reply = call(QStringLiteral("OpenFile"), QStringLiteral("/r/7"), {});
    ASSERT_TRUE(waitFor([&] { return !opened.isEmpty(); }));
    chooser->fail(opened.first().first);
    ASSERT_TRUE(waitFor([&] { return reply->done; }, kDeadlineMs / 2)); // well before the deadline
    EXPECT_EQ(reply->response, 0u);
}

TEST_F(FileChooserTest, CloseOfAForwardedRequestReachesGtk)
{
    chooser->setUiLoader([] { return false; });
    gtk.hold = true;
    FakeGtkRequest gtkRequest;
    gtkRequest.onClose = [&] {
        gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(uint(2)), QVariantMap()}));
    };
    ASSERT_TRUE(gtkBus->registerObject(QStringLiteral("/r/8"), &gtkRequest, QDBusConnection::ExportScriptableSlots));
    auto reply = call(QStringLiteral("OpenFile"), QStringLiteral("/r/8"), {});
    ASSERT_TRUE(waitFor([&] { return gtk.held.type() == QDBusMessage::MethodCallMessage; }));
    closeRequest(QStringLiteral("/r/8"));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 2u);
}

// The app's Close can reach x-d-p-gtk before x-d-p-gtk has exported the Request object of the call forwarded just before
// (GDBus routes a call when it reads it): the Close is sent again until it finds the object (counter-review of step 4b, NIT-4).
TEST_F(FileChooserTest, ACloseBeforeGtkExportsItsRequestIsSentAgain)
{
    chooser->setUiLoader([] { return false; });
    gtk.hold = true;
    FakeGtkRequest gtkRequest;
    int closes = 0;
    gtkRequest.onClose = [&] {
        ++closes;
        gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(uint(2)), QVariantMap()}));
    };
    auto reply = call(QStringLiteral("OpenFile"), QStringLiteral("/r/8b"), {});
    ASSERT_TRUE(waitFor([&] { return gtk.held.type() == QDBusMessage::MethodCallMessage; }));
    closeRequest(QStringLiteral("/r/8b"));
    QTest::qWait(350); // the first Closes find nothing
    EXPECT_FALSE(reply->done);
    ASSERT_TRUE(gtkBus->registerObject(QStringLiteral("/r/8b"), &gtkRequest, QDBusConnection::ExportScriptableSlots));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 2u);
    EXPECT_EQ(closes, 1);
}

// A hung mount never stalls the backend (FC7; integrator review of bd78424, MAJOR 1): the panels' questions to the disk are
// read off the GUI thread. A panel whose folder does not answer opens after the probe's deadline, passed over to the next
// folder; another application's request sent meanwhile opens at once; the stuck path is read once, however often asked.
TEST_F(FileChooserTest, AHungFolderStallsNoOtherRequest)
{
    chooser->setUiLoader([] { return true; });
    const int readsBefore = kSlowReads;
    QElapsedTimer clock;
    clock.start();
    auto slow = call(QStringLiteral("OpenFile"), QStringLiteral("/r/h1"), {{QStringLiteral("current_folder"), QByteArray("/slowmnt/share\0", 15)}});
    auto quick = call(QStringLiteral("OpenFile"), QStringLiteral("/r/h2"), {{QStringLiteral("current_folder"), QByteArray("/tmp\0", 5)}});
    QHash<int, qint64> at;
    QHash<int, QVariantMap> shown;
    QObject::connect(chooser.get(), &FileChooser::opened, chooser.get(), [&](int id, const QVariantMap &request) {
        at.insert(id, clock.elapsed());
        shown.insert(id, request);
    });
    ASSERT_TRUE(waitFor([&] { return at.size() == 2; }, kSlowMs));
    const int slowId = shown.constBegin().value().value("currentFolder").toString().contains("slowmnt") ? shown.constBegin().key() : std::next(shown.constBegin()).key();
    const int quickId = slowId == shown.constBegin().key() ? std::next(shown.constBegin()).key() : shown.constBegin().key();
    EXPECT_LT(at.value(quickId), kProbeMs) << "the other request opened at once";
    EXPECT_GE(at.value(slowId), kProbeMs - 50) << "the hung one after the probe's deadline";
    EXPECT_LT(at.value(slowId), kSlowMs) << "never after the hung read";
    EXPECT_EQ(shown.value(slowId).value("folderKinds").toMap().value("file:///slowmnt/share").toInt(), FileChooser::kNotResponding);
    EXPECT_EQ(shown.value(quickId).value("folderKinds").toMap().value("file:///tmp").toInt(), 2);
    EXPECT_FALSE(shown.value(slowId).value("places").toMap().value("home").toString().isEmpty());

    // probe(): the stuck path again (not read twice), a folder, a remote URL.
    QSignalSpy probed(chooser.get(), &FileChooser::probed);
    const int token = chooser->probe({QStringLiteral("file:///slowmnt/share"), QStringLiteral("file:///tmp"), QStringLiteral("smb://host/share")});
    EXPECT_EQ(probed.count(), 0) << "never answered from inside the call";
    ASSERT_TRUE(probed.wait(kSlowMs));
    EXPECT_EQ(probed.at(0).at(0).toInt(), token);
    const QVariantMap kinds = probed.at(0).at(1).toMap();
    EXPECT_EQ(kinds.value("file:///slowmnt/share").toInt(), FileChooser::kNotResponding);
    EXPECT_EQ(kinds.value("file:///tmp").toInt(), 2);
    EXPECT_EQ(kinds.value("smb://host/share").toInt(), -1);
    EXPECT_EQ(kSlowReads - readsBefore, 1) << "a stuck path is read once";

    chooser->answer(quickId, 1);
    chooser->answer(slowId, 1);
    ASSERT_TRUE(waitFor([&] { return slow->done && quick->done; }));
}

// The folders a panel may start in are a call each, all at once (re-review of 65311e0, MAJOR 1): a hung remembered folder
// never hides the application's healthy folder, and the panel opens once the remembered one has had its deadline.
TEST_F(FileChooserTest, AHungRememberedFolderHidesNotTheApplicationsFolder)
{
    chooser->setUiLoader([] { return true; });
    chooser->remember(QStringLiteral("org.example.App"), {{QStringLiteral("folder"), QStringLiteral("file:///slowmnt/remembered")}});
    auto reply = call(QStringLiteral("OpenFile"), QStringLiteral("/r/m1"), {{QStringLiteral("current_folder"), QByteArray("/tmp\0", 5)}});
    ASSERT_TRUE(waitFor([&] { return !opened.isEmpty(); }, kSlowMs));
    const QVariantMap kinds = opened.first().second.value("folderKinds").toMap();
    EXPECT_EQ(kinds.value("file:///tmp").toInt(), 2) << "the application's folder answered";
    EXPECT_EQ(kinds.value("file:///slowmnt/remembered").toInt(), FileChooser::kNotResponding);
    chooser->answer(opened.first().first, 1);
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
}

// A hung place hides not the application's folder either (re-review of 24bdf58, MAJOR 1: with ~/Documents hung, a browser's
// ~/Downloads opened Home): each place is a call of its own, and a real answer wins when the calls merge. Every request is
// checked, the first (Documents read and hung) and the next (Documents stuck), for Downloads and Desktop.
TEST_F(FileChooserTest, AHungPlaceHidesNotTheApplicationsFolder)
{
    QTemporaryDir config;
    ASSERT_TRUE(config.isValid());
    const QString downloads = dir.filePath(QStringLiteral("Downloads"));
    const QString desktop = dir.filePath(QStringLiteral("Desktop"));
    ASSERT_TRUE(QDir().mkpath(downloads) && QDir().mkpath(desktop));
    QFile dirs(config.filePath(QStringLiteral("user-dirs.dirs")));
    ASSERT_TRUE(dirs.open(QIODevice::WriteOnly));
    dirs.write(QStringLiteral("XDG_DOCUMENTS_DIR=\"/slowmnt/Documents\"\nXDG_DOWNLOAD_DIR=\"%1\"\nXDG_DESKTOP_DIR=\"%2\"\n").arg(downloads, desktop).toUtf8());
    dirs.close();
    struct ConfigHome {
        QByteArray saved = qgetenv("XDG_CONFIG_HOME");
        bool had = qEnvironmentVariableIsSet("XDG_CONFIG_HOME");
        ~ConfigHome() { had ? qputenv("XDG_CONFIG_HOME", saved) : qunsetenv("XDG_CONFIG_HOME"); }
    } restore;
    qputenv("XDG_CONFIG_HOME", config.path().toUtf8());
    ASSERT_EQ(QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation), QStringLiteral("/slowmnt/Documents"));
    chooser->setUiLoader([] { return true; });
    int n = 0;
    for (const QString &start : {downloads, desktop}) {
        for (int i = 0; i < 2; ++i) {
            opened.clear();
            QByteArray folder = start.toUtf8();
            folder.append('\0');
            auto reply = call(QStringLiteral("OpenFile"), QStringLiteral("/r/p%1").arg(++n), {{QStringLiteral("current_folder"), folder}});
            ASSERT_TRUE(waitFor([&] { return !opened.isEmpty(); }, kSlowMs));
            const QVariantMap request = opened.first().second;
            EXPECT_EQ(request.value("folderKinds").toMap().value(QUrl::fromLocalFile(start).toString(QUrl::FullyEncoded)).toInt(), 2)
                << qPrintable(start) << ", request " << n;
            EXPECT_EQ(request.value("places").toMap().value("documents").toString(), QString()) << "request " << n;
            EXPECT_EQ(request.value("places").toMap().value("downloads").toString(), QUrl::fromLocalFile(downloads).toString(QUrl::FullyEncoded))
                << "request " << n;
            EXPECT_EQ(request.value("places").toMap().value("desktop").toString(), QUrl::fromLocalFile(desktop).toString(QUrl::FullyEncoded))
                << "request " << n;
            chooser->answer(opened.first().first, 1);
            ASSERT_TRUE(waitFor([&] { return reply->done; }));
        }
    }
}

// The disk is asked about the URLs in the order given (re-review of 24bdf58, MAJOR 1: a hash's order, which changes from one
// process to the next).
TEST_F(FileChooserTest, TheDiskIsAskedInTheOrderGiven)
{
    auto mutex = std::make_shared<QMutex>();
    auto order = std::make_shared<QStringList>();
    FileChooser::Options options;
    options.gtkService = QString::fromLatin1(kFakeGtk);
    options.probeDeadlineMs = kProbeMs;
    options.statPath = [mutex, order](const QString &path) {
        const QMutexLocker lock(mutex.get());
        order->append(path);
        return 0;
    };
    FileChooser ordered(*backendBus, options);
    QStringList urls, paths;
    for (const char *name : {"h", "c", "a", "f", "b", "g", "e", "d"}) {
        paths << QStringLiteral("/order/") + QLatin1String(name);
        urls << QStringLiteral("file:///order/") + QLatin1String(name);
    }
    QSignalSpy probed(&ordered, &FileChooser::probed);
    ordered.probe(urls);
    ASSERT_TRUE(probed.wait(kSlowMs));
    const QMutexLocker lock(mutex.get());
    EXPECT_EQ(*order, paths);
}

// SaveFiles' names, as many as a panel takes, are one job: 17 names (past the job bound) and 4096 (the interface's bound)
// are all answered on a healthy disk (re-review of 6b26afc, MAJOR 1: 17 names were never answered).
TEST_F(FileChooserTest, ManyNamesAreOneJob)
{
    QDir().mkpath(dir.filePath(QStringLiteral("out")));
    QFile taken(dir.filePath(QStringLiteral("out/name-3.txt")));
    ASSERT_TRUE(taken.open(QIODevice::WriteOnly));
    taken.close();
    for (int count : {17, 4096}) {
        QStringList urls;
        for (int i = 0; i < count; ++i)
            urls << QUrl::fromLocalFile(dir.filePath(QStringLiteral("out/name-%1.txt").arg(i))).toString();
        QSignalSpy probed(chooser.get(), &FileChooser::probed);
        chooser->probe(urls);
        ASSERT_TRUE(probed.wait(kSlowMs)) << count;
        const QVariantMap kinds = probed.at(0).at(1).toMap();
        ASSERT_EQ(kinds.size(), count);
        int existing = 0;
        for (const QString &u : urls) {
            const int kind = kinds.value(u).toInt();
            EXPECT_TRUE(kind == 0 || kind == 1) << qPrintable(u) << " " << kind;
            existing += kind == 1;
        }
        EXPECT_EQ(existing, 1) << count;
    }
}

// The deadline counts from the last answer: a share that is slow but answering (3 reads of 250 ms, 750 ms in all, past the
// 400-ms deadline) is waited for.
TEST_F(FileChooserTest, ASlowButAnsweringShareIsWaitedFor)
{
    QSignalSpy probed(chooser.get(), &FileChooser::probed);
    const QStringList urls{QStringLiteral("file:///slowish/a"), QStringLiteral("file:///slowish/b"), QStringLiteral("file:///slowish/c")};
    chooser->probe(urls);
    ASSERT_TRUE(probed.wait(kSlowMs));
    for (const QString &u : urls)
        EXPECT_EQ(probed.at(0).at(1).toMap().value(u).toInt(), 2) << qPrintable(u);
}

// A backend that goes while a read hangs: the read ends later and posts nothing to it (the shared mutex and the receiver it
// clears; re-review of 6b26afc, MINOR 2, C18). The sanitized build (portal-unit-tests-asan) catches a use after free.
TEST_F(FileChooserTest, ABackendThatGoesLeavesItsReadsHarmless)
{
    FileChooser::Options options;
    options.gtkService = QString::fromLatin1(kFakeGtk);
    options.probeDeadlineMs = kProbeMs;
    options.statPath = [](const QString &) {
        QThread::msleep(200);
        return 0;
    };
    {
        FileChooser gone(*backendBus, options);
        gone.probe({QStringLiteral("file:///anything/at/all"), QStringLiteral("file:///and/another")});
    }
    QTest::qWait(600); // both reads end after it went
    QCoreApplication::processEvents();
    SUCCEED();
}

// A request forwarded to x-d-p-gtk while its folders are being probed never gets a panel (re-review of 6b26afc, C19). A
// second backend, its UI deadline shorter than the probe, on a connection and a name of its own.
TEST_F(FileChooserTest, AForwardedRequestGetsNoPanel)
{
    QDBusConnection bus2 = QDBusConnection::connectToBus(g_address, QStringLiteral("early"));
    ASSERT_TRUE(bus2.isConnected());
    FileChooser::Options options;
    options.gtkService = QString::fromLatin1(kFakeGtk);
    options.uiDeadlineMs = 100; // the forward comes before the probe's answer
    options.probeDeadlineMs = kProbeMs;
    options.statPath = slowStat;
    {
        FileChooser early(bus2, options);
        new FileChooserAdaptor(&early);
        ASSERT_TRUE(bus2.registerObject(QStringLiteral("/org/freedesktop/portal/desktop"), &early, QDBusConnection::ExportAdaptors));
        ASSERT_TRUE(bus2.registerService(QStringLiteral("org.test.early")));
        early.setUiLoader([] { return true; });
        gtk.hold = true; // the request stays forwarded while the probe answers
        QSignalSpy opened(&early, &FileChooser::opened);
        QDBusMessage m = QDBusMessage::createMethodCall(QStringLiteral("org.test.early"), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                        QStringLiteral("org.freedesktop.impl.portal.FileChooser"), QStringLiteral("OpenFile"));
        m << QVariant::fromValue(QDBusObjectPath(QStringLiteral("/r/c19"))) << QStringLiteral("org.example.App") << QString() << QStringLiteral("Open")
          << QVariantMap{{QStringLiteral("current_folder"), QByteArray("/slowmnt/c19\0", 13)}};
        auto reply = std::make_shared<Reply>();
        auto *w = new QDBusPendingCallWatcher(frontendBus->asyncCall(m, std::numeric_limits<int>::max()));
        QObject::connect(w, &QDBusPendingCallWatcher::finished, w, [reply](QDBusPendingCallWatcher *watcher) {
            watcher->deleteLater();
            reply->done = true;
        });
        ASSERT_TRUE(waitFor([&] { return gtk.calls.contains(QStringLiteral("OpenFile /r/c19 Open")); }));
        QTest::qWait(kProbeMs + 300);
        EXPECT_EQ(opened.count(), 0) << "no panel for a forwarded request";
        gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(uint(1)), QVariantMap()}));
        EXPECT_TRUE(waitFor([&] { return reply->done; })) << "x-d-p-gtk's answer relayed";
        bus2.unregisterService(QStringLiteral("org.test.early"));
        bus2.unregisterObject(QStringLiteral("/org/freedesktop/portal/desktop"));
    }
    QDBusConnection::disconnectFromBus(QStringLiteral("early"));
}

TEST_F(FileChooserTest, GtkMissingEndsTheRequestWithAnError)
{
    chooser->setUiLoader([] { return false; });
    gtkBus->unregisterService(QString::fromLatin1(kFakeGtk));
    auto reply = call(QStringLiteral("OpenFile"), QStringLiteral("/r/9"), {});
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_FALSE(reply->error);
    EXPECT_EQ(reply->response, 2u);
}

TEST_F(FileChooserTest, RequestsAreBounded)
{
    chooser->setUiLoader([] { return true; });
    gtk.hold = true; // the panels that never show go to x-d-p-gtk, which keeps them open
    QList<std::shared_ptr<Reply>> replies;
    for (int i = 0; i < 17; ++i)
        replies << call(QStringLiteral("OpenFile"), QStringLiteral("/r/b%1").arg(i), {});
    ASSERT_TRUE(waitFor([&] { return replies.last()->done; }));
    EXPECT_EQ(replies.last()->response, 2u);
    // A panel opens once its application's entry is read on a worker (whenAppKnown): the 16 may come after the refusal.
    waitFor([&] { return opened.size() >= 16; });
    EXPECT_EQ(opened.size(), 16);
    // The same handle twice: the second is refused, the first goes on.
    auto again = call(QStringLiteral("OpenFile"), QStringLiteral("/r/b0"), {});
    ASSERT_TRUE(waitFor([&] { return again->done; }));
    EXPECT_EQ(again->response, 2u);
    EXPECT_FALSE(replies.first()->done);
}

TEST_F(FileChooserTest, IdleOnlyWithoutRequests)
{
    QSignalSpy idle(chooser.get(), &FileChooser::idle);
    chooser->setUiLoader([] { return true; });
    auto reply = call(QStringLiteral("OpenFile"), QStringLiteral("/r/10"), {});
    ASSERT_TRUE(waitFor([&] { return !opened.isEmpty(); }));
    QQuickWindow window;
    chooser->present(opened.first().first, &window);
    QTest::qWait(kDeadlineMs + 300); // past the idle time and the deadline, a panel open: no idle, no forward
    EXPECT_EQ(idle.count(), 0);
    EXPECT_TRUE(gtk.calls.isEmpty());
    chooser->answer(opened.first().first, 1);
    ASSERT_TRUE(idle.wait(kIdleMs + 1000));
    EXPECT_TRUE(reply->done || waitFor([&] { return reply->done; }));
}

TEST_F(FileChooserTest, ThePanelsMemoryGoesThroughTheState)
{
    chooser->remember(QStringLiteral("org.example.App"),
                      {{"folder", "file:///home/u/Documents"}, {"view", "columns"}, {"expanded", true}});
    const QVariantMap m = chooser->memory(QStringLiteral("org.example.App"));
    EXPECT_EQ(m.value("folder").toString(), QStringLiteral("file:///home/u/Documents"));
    EXPECT_EQ(m.value("view").toString(), QStringLiteral("columns"));
    EXPECT_TRUE(m.value("expanded").toBool());
}

// Answers about the same URLs from several calls: a real answer wins over "not responding", whichever comes first.
TEST(FileChooserMerge, ARealAnswerWins)
{
    QVariantMap kinds{{QStringLiteral("a"), 2}, {QStringLiteral("b"), FileChooser::kNotResponding}};
    FileChooser::mergeKinds(kinds, {{QStringLiteral("a"), FileChooser::kNotResponding},
                                    {QStringLiteral("b"), 0},
                                    {QStringLiteral("c"), FileChooser::kNotResponding},
                                    {QStringLiteral("d"), -1}});
    EXPECT_EQ(kinds.value(QStringLiteral("a")).toInt(), 2);
    EXPECT_EQ(kinds.value(QStringLiteral("b")).toInt(), 0);
    EXPECT_EQ(kinds.value(QStringLiteral("c")).toInt(), FileChooser::kNotResponding);
    EXPECT_EQ(kinds.value(QStringLiteral("d")).toInt(), -1);
    FileChooser::mergeKinds(kinds, {{QStringLiteral("c"), 1}});
    EXPECT_EQ(kinds.value(QStringLiteral("c")).toInt(), 1);
}

TEST(FileChooserIds, APanelCountsAsTheApplicationsWindow)
{
    EXPECT_EQ(FileChooser::windowAppId(QStringLiteral("org.mozilla.firefox")), QStringLiteral("org.mozilla.firefox"));
    EXPECT_EQ(FileChooser::windowAppId(QStringLiteral("chromium.desktop")), QStringLiteral("chromium"));
    EXPECT_EQ(FileChooser::windowAppId(QString()), QStringLiteral("org.grassfield.Files"));
    EXPECT_EQ(FileChooser::windowAppId(QStringLiteral("snap.app/../x")), QStringLiteral("org.grassfield.Files"));
    EXPECT_EQ(FileChooser::windowAppId(QStringLiteral(".hidden")), QStringLiteral("org.grassfield.Files"));
}

int main(int argc, char **argv)
{
    // The print preview's child, as grassfield-portal runs it (tst_print.cpp draws pages through this binary).
    if (grassfield::portal::isPreviewChildInvocation(argc, argv))
        return grassfield::portal::previewChildMain(argc, argv);
    qputenv("QT_QPA_PLATFORM", "offscreen");
    // No input method: a desktop's (QT_IM_MODULE=fcitx) loads a plugin that leaks at exit, which the sanitized run reports
    // as a failure (re-review of 65311e0, MINOR 4); the tests type nothing.
    qunsetenv("QT_IM_MODULE");
    QGuiApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    // A private bus for the whole run (never the user's).
    QTemporaryDir busDir;
    QProcess daemon;
    daemon.start(QStringLiteral("dbus-daemon"), {QStringLiteral("--session"), QStringLiteral("--nofork"), QStringLiteral("--print-address"),
                                                 QStringLiteral("--address=unix:dir=%1").arg(busDir.path())});
    if (!daemon.waitForStarted() || !daemon.waitForReadyRead(5000)) {
        std::fputs("tst_filechooser: dbus-daemon did not start\n", stderr);
        return 1;
    }
    g_address = QString::fromUtf8(daemon.readLine()).trimmed();
    const int code = RUN_ALL_TESTS();
    daemon.terminate();
    daemon.waitForFinished();
    return code;
}

#include "tst_filechooser.moc"
