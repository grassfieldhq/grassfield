// Unit tests of grassfield-menu-bridge's pure logic (bridges/menu-bridge/src): menu/1 message validation, DBusMenu
// layout reading and mapping, mnemonic handling, start-up guards, the diagnostics XML. The DBusMenu wire format is
// exercised over an in-process peer-to-peer D-Bus connection (no bus daemon, nothing on any session bus).

#include "DBusObjects.h"
#include "Launcher.h"
#include "Layout.h"
#include "MenuClient.h"
#include "Penalties.h"
#include "Protocol.h"
#include "Registrations.h"
#include "Safety.h"

#include <QCoreApplication>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusServer>
#include <QDBusVariant>
#include <QDBusVirtualObject>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <memory>

#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

using namespace gf::menubridge;

namespace {
    std::optional<ShellMessage> parse(const char* json, QString* error = nullptr) {
        return parseShellMessage(QByteArray(json), error);
    }

    QString errorOf(const char* json) {
        QString error;
        EXPECT_FALSE(parse(json, &error).has_value()) << json;
        return error;
    }

    RawItem item(int id, QVariantMap props, QList<RawItem> children = {}) {
        return RawItem{.id = id, .properties = std::move(props), .children = std::move(children)};
    }

    QJsonArray mapped(const RawItem& root) {
        LayoutBudget budget;
        return mapChildren(root, budget);
    }

    QVariant shortcut(const QList<QStringList>& keys) {
        QVariantList out;
        for (const auto& k : keys)
            out.append(QVariant(k));
        return out;
    }
} // namespace

// ---- menu/1: shell -> bridge ---------------------------------------------------------------------------------------

TEST(ShellMessages, ValidMessagesParse) {
    auto hello = parse(R"({"type":"hello","v":"menu/1","appmenu":true})");
    ASSERT_TRUE(hello.has_value());
    EXPECT_EQ(hello->type, ShellMessage::Type::Hello);
    EXPECT_TRUE(hello->appmenu);

    auto open = parse(R"({"type":"open","window":"55D3C2A0B1F0","service":":1.42","path":"/MenuBar/1","pid":4242,"extra":"ignored"})");
    ASSERT_TRUE(open.has_value());
    EXPECT_EQ(open->type, ShellMessage::Type::Open);
    EXPECT_EQ(open->window, QStringLiteral("55d3c2a0b1f0")); // normalized to lowercase
    EXPECT_EQ(open->service, QStringLiteral(":1.42"));
    EXPECT_EQ(open->path, QStringLiteral("/MenuBar/1"));
    EXPECT_EQ(open->pid, 4242);

    auto show = parse(R"({"type":"about-to-show","window":"1a","id":0})");
    ASSERT_TRUE(show.has_value());
    EXPECT_EQ(show->type, ShellMessage::Type::AboutToShow);
    EXPECT_EQ(show->id, 0);

    auto activate = parse(R"({"type":"activate","window":"1a","id":2147483647})");
    ASSERT_TRUE(activate.has_value());
    EXPECT_EQ(activate->id, 2147483647);

    auto close = parse(R"({"type":"close","window":"ffffffffffffffff"})");
    ASSERT_TRUE(close.has_value());
    EXPECT_EQ(close->type, ShellMessage::Type::Close);
}

// ADR-0008 amendment 2026-10-25: a window without a set_address registration, its Wayland client pid N: the menu that
// process registered with com.canonical.AppMenu.Registrar.
TEST(ShellMessages, OpenRegisteredParses) {
    auto open = parse(R"({"type":"open-registered","window":"55D3C2A0B1F0","pid":4242})");
    ASSERT_TRUE(open.has_value());
    EXPECT_EQ(open->type, ShellMessage::Type::OpenRegistered);
    EXPECT_EQ(open->window, QStringLiteral("55d3c2a0b1f0"));
    EXPECT_EQ(open->pid, 4242);
    EXPECT_TRUE(open->service.isEmpty()) << "nothing the shell sends names a bus name here";
    EXPECT_EQ(errorOf(R"({"type":"open-registered","window":"1a"})"), QStringLiteral("field:pid"));
    EXPECT_EQ(errorOf(R"({"type":"open-registered","window":"1a","pid":0})"), QStringLiteral("field:pid"));
    EXPECT_EQ(errorOf(R"({"type":"open-registered","window":"1a","pid":-4})"), QStringLiteral("field:pid"));
    EXPECT_EQ(errorOf(R"({"type":"open-registered","window":"1a","pid":"4242"})"), QStringLiteral("field:pid"));
    EXPECT_EQ(errorOf(R"({"type":"open-registered","window":"zz","pid":42})"), QStringLiteral("field:window"));
}

TEST(ShellMessages, MalformedInputIsRefused) {
    EXPECT_EQ(errorOf("not json"), QStringLiteral("parse"));
    EXPECT_EQ(errorOf("[1,2]"), QStringLiteral("parse"));
    EXPECT_EQ(errorOf(""), QStringLiteral("parse"));
    EXPECT_EQ(errorOf(R"({"type":"run","window":"1a"})"), QStringLiteral("type"));
    EXPECT_EQ(errorOf(R"({"window":"1a"})"), QStringLiteral("type"));
    EXPECT_EQ(errorOf(R"({"type":"hello","v":"menu/2","appmenu":true})"), QStringLiteral("version"));
    EXPECT_EQ(errorOf(R"({"type":"hello","v":"menu/1","appmenu":"yes"})"), QStringLiteral("field:appmenu"));
    EXPECT_EQ(errorOf(R"({"type":"hello","v":"menu/1"})"), QStringLiteral("field:appmenu"));
}

TEST(ShellMessages, WindowMustBeShortHex) {
    for (const char* json : {R"({"type":"close","window":"0x1a"})", R"({"type":"close","window":""})", R"({"type":"close","window":"12345678901234567"})",
                             R"({"type":"close","window":"1g"})", R"({"type":"close","window":17})", R"({"type":"close"})", R"({"type":"close","window":"1a\n"})"})
        EXPECT_EQ(errorOf(json), QStringLiteral("field:window")) << json;
}

TEST(ShellMessages, OpenFieldsAreValidated) {
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":"org","path":"/m","pid":1})"), QStringLiteral("field:service"));
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":"org.foo bar","path":"/m","pid":1})"), QStringLiteral("field:service"));
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":5,"path":"/m","pid":1})"), QStringLiteral("field:service"));
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":":1.2","path":"m","pid":1})"), QStringLiteral("field:path"));
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":":1.2","path":"/m/","pid":1})"), QStringLiteral("field:path"));
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":":1.2","path":"/a/../b","pid":1})"), QStringLiteral("field:path"));
    for (const char* pid : {"0", "-5", "1.5", "\"42\"", "null", "2147483648", "1e300"}) {
        const QByteArray json = QByteArray(R"({"type":"open","window":"1a","service":":1.2","path":"/m","pid":)") + pid + "}";
        QString          error;
        EXPECT_FALSE(parseShellMessage(json, &error).has_value()) << pid;
        EXPECT_EQ(error, QStringLiteral("field:pid")) << pid;
    }
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":":1.2","path":"/m"})"), QStringLiteral("field:pid"));
}

TEST(ShellMessages, ItemIdsAreNonNegativeInt32) {
    for (const char* id : {"-1", "0.5", "\"3\"", "2147483648", "true"}) {
        const QByteArray json = QByteArray(R"({"type":"activate","window":"1a","id":)") + id + "}";
        QString          error;
        EXPECT_FALSE(parseShellMessage(json, &error).has_value()) << id;
        EXPECT_EQ(error, QStringLiteral("field:id")) << id;
    }
    EXPECT_EQ(errorOf(R"({"type":"about-to-show","window":"1a"})"), QStringLiteral("field:id"));
}

TEST(ShellMessages, LineLengthIsCapped) {
    QByteArray json = R"({"type":"close","window":"1a","pad":")";
    json += QByteArray(limits::kShellLine, 'x');
    json += "\"}";
    QString error;
    EXPECT_FALSE(parseShellMessage(json, &error).has_value());
    EXPECT_EQ(error, QStringLiteral("too-long"));
}

// ---- menu/1: bridge -> shell ---------------------------------------------------------------------------------------

TEST(BridgeMessages, ExactWireFormat) {
    EXPECT_EQ(statusMessage(QStringLiteral("active"), true), QByteArray(R"({"registrar":true,"state":"active","type":"status","v":"menu/1"})" "\n"));
    EXPECT_EQ(errorMessage(QStringLiteral("1a"), QStringLiteral("pid-mismatch"), QStringLiteral("no")),
              QByteArray(R"({"code":"pid-mismatch","message":"no","type":"error","window":"1a"})" "\n"));
    EXPECT_EQ(menuMessage(QStringLiteral("1a"), 3, QJsonArray{}), QByteArray(R"({"items":[],"revision":3,"type":"menu","window":"1a"})" "\n"));
}

TEST(BridgeMessages, ApplicationTextCannotBreakTheLine) {
    // Labels come from applications: JSON escaping keeps them inside their string, newlines included.
    const QJsonArray items{QJsonObject{{QStringLiteral("label"), QStringLiteral("a\"}\n{\"type\":\"evil")}}};
    const QByteArray line = menuMessage(QStringLiteral("1a"), 1, items);
    EXPECT_EQ(line.count('\n'), 1);
    EXPECT_TRUE(line.endsWith('\n'));
    EXPECT_TRUE(QJsonDocument::fromJson(line).isObject());
}

// ---- names -----------------------------------------------------------------------------------------------------

TEST(Names, BusNamesAndPathsFollowTheDBusRules) {
    for (const char* name : {":1.42", "org.kde.Foo", "a.b", "org._x.y-z"})
        EXPECT_TRUE(isValidBusName(QString::fromLatin1(name))) << name;
    for (const char* name : {"", ":", ":1", "org", ".org.foo", "org..foo", "org.1foo", "org.foo/bar", "org.f\xc3\xa9"})
        EXPECT_FALSE(isValidBusName(QString::fromUtf8(name))) << name;
    EXPECT_FALSE(isValidBusName(QStringLiteral("a.") + QString(254, u'b')));
    for (const char* path : {"/", "/MenuBar/1", "/com/canonical/menu/1A2B"})
        EXPECT_TRUE(isValidObjectPath(QString::fromLatin1(path))) << path;
    for (const char* path : {"", "MenuBar", "//", "/a/", "/a-b", "/a//b", "/a b"})
        EXPECT_FALSE(isValidObjectPath(QString::fromLatin1(path))) << path;
}

// ---- labels ----------------------------------------------------------------------------------------------------

TEST(Labels, MnemonicMarkersAreRemoved) {
    EXPECT_EQ(plainLabel(QStringLiteral("_File")), QStringLiteral("File"));
    EXPECT_EQ(plainLabel(QStringLiteral("Save _As…")), QStringLiteral("Save As…"));
    EXPECT_EQ(plainLabel(QStringLiteral("Open __recent")), QStringLiteral("Open _recent"));
    EXPECT_EQ(plainLabel(QStringLiteral("a___b")), QStringLiteral("a_b"));
    EXPECT_EQ(plainLabel(QStringLiteral("trailing_")), QStringLiteral("trailing"));
    EXPECT_EQ(plainLabel(QStringLiteral("Bookmarks & Lists")), QStringLiteral("Bookmarks & Lists"));
    EXPECT_EQ(plainLabel(QString()), QString());
}

TEST(Labels, ControlAndBidiCharactersAreRemoved) {
    EXPECT_EQ(plainLabel(QStringLiteral("New\nWindow\t\r ")), QStringLiteral("New Window"));
    EXPECT_EQ(plainLabel(QStringLiteral("  lead")), QStringLiteral("lead"));
    EXPECT_EQ(plainLabel(QString::fromUtf8("a\x01" "b\x7f" "c")), QStringLiteral("abc"));
    // Bidirectional overrides and isolates (built from code points: no such characters in this source file).
    EXPECT_EQ(plainLabel(QStringLiteral("pay") + QChar(0x202E) + QStringLiteral("gnp.exe")), QStringLiteral("paygnp.exe"));
    EXPECT_EQ(plainLabel(QChar(0x2066) + QStringLiteral("x") + QChar(0x2069)), QStringLiteral("x"));
    EXPECT_EQ(plainLabel(QStringLiteral("<b>bold</b>")), QStringLiteral("<b>bold</b>")); // plain text: the shell renders it literally
}

TEST(Labels, LengthIsCappedWithoutSplittingSurrogates) {
    EXPECT_EQ(plainLabel(QString(1000, u'x')).size(), limits::kLabel);
    QString emoji = QString(limits::kLabel - 1, u'x') + QString::fromUtf16(u"\U0001F600");
    const QString out = plainLabel(emoji);
    EXPECT_LE(out.size(), limits::kLabel);
    EXPECT_FALSE(out.back().isHighSurrogate());
}

// ---- layout mapping --------------------------------------------------------------------------------------------

TEST(Layout, MapsAQtStyleMenu) {
    const RawItem root = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}},
                              {item(1, {{QStringLiteral("label"), QStringLiteral("_File")}, {QStringLiteral("children-display"), QStringLiteral("submenu")}},
                                    {
                                        item(2, {{QStringLiteral("label"), QStringLiteral("_New")}, {QStringLiteral("shortcut"), shortcut({{QStringLiteral("Control"), QStringLiteral("N")}})}}),
                                        item(3, {{QStringLiteral("type"), QStringLiteral("separator")}, {QStringLiteral("label"), QStringLiteral("ignored")}}),
                                        item(4, {{QStringLiteral("label"), QStringLiteral("_Redo")}, {QStringLiteral("enabled"), false}}),
                                        item(5, {{QStringLiteral("label"), QStringLiteral("Hidden")}, {QStringLiteral("visible"), false}}),
                                        item(6, {{QStringLiteral("label"), QStringLiteral("_Word Wrap")}, {QStringLiteral("toggle-type"), QStringLiteral("checkmark")}, {QStringLiteral("toggle-state"), 1}}),
                                        item(7, {{QStringLiteral("label"), QStringLiteral("_Theme")}, {QStringLiteral("children-display"), QStringLiteral("submenu")}},
                                             {item(8, {{QStringLiteral("label"), QStringLiteral("Dark")}, {QStringLiteral("toggle-type"), QStringLiteral("radio")}, {QStringLiteral("toggle-state"), 0}})}),
                                    })});
    const QJsonArray items = mapped(root);
    ASSERT_EQ(items.size(), 1);
    const QJsonObject file = items.at(0).toObject();
    EXPECT_EQ(file.value(QStringLiteral("label")).toString(), QStringLiteral("File"));
    EXPECT_TRUE(file.value(QStringLiteral("submenu")).toBool());
    const QJsonArray children = file.value(QStringLiteral("children")).toArray();
    ASSERT_EQ(children.size(), 6);

    const QJsonObject newItem = children.at(0).toObject();
    EXPECT_EQ(QJsonDocument(newItem).toJson(QJsonDocument::Compact),
              QByteArray(R"({"children":[],"enabled":true,"icon-name":"","id":2,"label":"New","shortcut":[["Control","N"]],"submenu":false,"toggle-state":-1,"toggle-type":"","type":"standard","visible":true})"));
    const QJsonObject sep = children.at(1).toObject();
    EXPECT_EQ(sep.value(QStringLiteral("type")).toString(), QStringLiteral("separator"));
    EXPECT_EQ(sep.value(QStringLiteral("label")).toString(), QString());
    EXPECT_FALSE(children.at(2).toObject().value(QStringLiteral("enabled")).toBool());
    EXPECT_FALSE(children.at(3).toObject().value(QStringLiteral("visible")).toBool());
    const QJsonObject wrap = children.at(4).toObject();
    EXPECT_EQ(wrap.value(QStringLiteral("toggle-type")).toString(), QStringLiteral("checkmark"));
    EXPECT_EQ(wrap.value(QStringLiteral("toggle-state")).toInt(), 1);
    const QJsonObject dark = children.at(5).toObject().value(QStringLiteral("children")).toArray().at(0).toObject();
    EXPECT_EQ(dark.value(QStringLiteral("toggle-type")).toString(), QStringLiteral("radio"));
    EXPECT_EQ(dark.value(QStringLiteral("toggle-state")).toInt(), 0);

    const ItemIndex index = indexItems(items);
    EXPECT_EQ(index.activatable, (QSet<int>{2, 6, 8}));  // not the separator, disabled, hidden or submenu items
    EXPECT_EQ(index.submenus, (QSet<int>{0, 1, 7}));
}

TEST(Layout, WrongTypesFallBackToDefaults) {
    const RawItem root = item(0, {}, {item(1, {{QStringLiteral("label"), 42}, {QStringLiteral("enabled"), QStringLiteral("no")}, {QStringLiteral("visible"), 0},
                                               {QStringLiteral("toggle-type"), QStringLiteral("switch")}, {QStringLiteral("toggle-state"), 1},
                                               {QStringLiteral("icon-name"), QStringLiteral("../../etc/passwd")}, {QStringLiteral("shortcut"), QStringLiteral("Ctrl+N")}}),
                                      item(-3, {{QStringLiteral("label"), QStringLiteral("negative id")}})});
    const QJsonArray items = mapped(root);
    ASSERT_EQ(items.size(), 1); // the negative id is skipped
    const QJsonObject o = items.at(0).toObject();
    EXPECT_EQ(o.value(QStringLiteral("label")).toString(), QString());
    EXPECT_TRUE(o.value(QStringLiteral("enabled")).toBool());
    EXPECT_TRUE(o.value(QStringLiteral("visible")).toBool());
    EXPECT_EQ(o.value(QStringLiteral("toggle-type")).toString(), QString());
    EXPECT_EQ(o.value(QStringLiteral("toggle-state")).toInt(), -1);
    EXPECT_EQ(o.value(QStringLiteral("icon-name")).toString(), QString());
    EXPECT_TRUE(o.value(QStringLiteral("shortcut")).toArray().isEmpty());
}

TEST(Layout, ShortcutsAreSanitized) {
    const QList<QStringList> many = {{QStringLiteral("Control"), QStringLiteral("A")}, {QStringLiteral("Control"), QStringLiteral("B")}, {QStringLiteral("Control"), QStringLiteral("C")},
                                     {QStringLiteral("Control"), QStringLiteral("D")}, {QStringLiteral("Control"), QStringLiteral("E")}};
    const RawItem root = item(0, {}, {item(1, {{QStringLiteral("shortcut"), shortcut(many)}}),
                                      item(2, {{QStringLiteral("shortcut"), shortcut({{QStringLiteral("Control"), QStringLiteral("bad key")}, {QStringLiteral("Shift"), QStringLiteral("plus")}})}}),
                                      item(3, {{QStringLiteral("shortcut"), shortcut({QStringList(7, QStringLiteral("Alt"))})}})});
    const QJsonArray items = mapped(root);
    EXPECT_EQ(items.at(0).toObject().value(QStringLiteral("shortcut")).toArray().size(), limits::kShortcuts);
    EXPECT_EQ(QJsonDocument(items.at(1).toObject().value(QStringLiteral("shortcut")).toArray()).toJson(QJsonDocument::Compact), QByteArray(R"([["Shift","plus"]])"));
    EXPECT_TRUE(items.at(2).toObject().value(QStringLiteral("shortcut")).toArray().isEmpty());
}

TEST(Layout, DepthIsCapped) {
    RawItem leaf = item(100, {{QStringLiteral("label"), QStringLiteral("deep")}});
    for (int i = 20; i >= 1; --i)
        leaf = item(i, {{QStringLiteral("children-display"), QStringLiteral("submenu")}}, {leaf});
    LayoutBudget     budget;
    const QJsonArray items = mapChildren(item(0, {}, {leaf}), budget);
    EXPECT_TRUE(budget.truncated);
    int        depth = 0;
    QJsonArray level = items;
    while (!level.isEmpty()) {
        ++depth;
        level = level.at(0).toObject().value(QStringLiteral("children")).toArray();
    }
    EXPECT_EQ(depth, limits::kDepth);
}

TEST(Layout, ItemCountIsCapped) {
    QList<RawItem> many;
    for (int i = 1; i <= limits::kItems + 500; ++i)
        many.append(item(i, {{QStringLiteral("label"), QStringLiteral("x")}}));
    LayoutBudget     budget;
    const QJsonArray items = mapChildren(item(0, {}, many), budget);
    EXPECT_EQ(items.size(), limits::kItems);
    EXPECT_TRUE(budget.truncated);
}

// ---- DBusMenu over a real (peer-to-peer) D-Bus connection ------------------------------------------------------

namespace {
    QDBusArgument marshal(const RawItem& node) {
        QDBusArgument arg;
        arg.beginStructure();
        arg << node.id << node.properties;
        arg.beginArray(qMetaTypeId<QDBusVariant>());
        for (const RawItem& child : node.children)
            arg << QDBusVariant(QVariant::fromValue(marshal(child)));
        arg.endArray();
        arg.endStructure();
        return arg;
    }

    // A minimal com.canonical.dbusmenu that records the signatures of the calls it gets.
    class FakeMenu : public QDBusVirtualObject {
      public:
        QStringList calls;
        RawItem     layout;
        // GetLayout calls still to answer with an error (an application busy past the timeout: NoReply).
        int         busyGetLayouts = 0;
        // GetLayout answered with a reply of the wrong signature (a string).
        bool        wrongSignature = false;
        // When each GetLayout came (ms on one clock).
        QList<qint64>  getLayoutTimes;
        QElapsedTimer  clock;

        QString     introspect(const QString&) const override {
            return {};
        }

        bool handleMessage(const QDBusMessage& msg, const QDBusConnection& conn) override {
            calls << msg.member() + u':' + msg.signature();
            if (msg.member() == QLatin1String("GetLayout")) {
                if (!clock.isValid())
                    clock.start();
                getLayoutTimes << clock.elapsed();
            }
            if (msg.member() == QLatin1String("GetLayout") && wrongSignature) {
                conn.send(msg.createReply(QVariant(QStringLiteral("not a layout"))));
            } else if (msg.member() == QLatin1String("GetLayout") && busyGetLayouts > 0) {
                --busyGetLayouts;
                conn.send(msg.createErrorReply(QStringLiteral("org.freedesktop.DBus.Error.NoReply"), QStringLiteral("busy")));
            } else if (msg.member() == QLatin1String("GetLayout"))
                conn.send(msg.createReply(QVariantList{QVariant::fromValue<uint>(7), QVariant::fromValue(marshal(layout))}));
            else if (msg.member() == QLatin1String("AboutToShow"))
                conn.send(msg.createReply(QVariant(false)));
            else
                conn.send(msg.createReply());
            return true;
        }
    };

    QDBusMessage callAndWait(QDBusConnection& conn, const QDBusMessage& msg) {
        QDBusPendingCallWatcher watcher(conn.asyncCall(msg, 3000));
        QElapsedTimer           timer;
        timer.start();
        while (!watcher.isFinished() && timer.elapsed() < 5000)
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        return watcher.reply();
    }
} // namespace

TEST(DBusMenuWire, ExplicitSignaturesAndLayoutRoundTrip) {
    qDBusRegisterMetaType<QList<QStringList>>();
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    QDBusServer server(QStringLiteral("unix:dir=") + dir.path());
    if (!server.isConnected()) // e.g. a sandbox that forbids creating Unix sockets
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here: " << qPrintable(server.lastError().message());
    server.setAnonymousAuthenticationAllowed(true);

    FakeMenu menu;
    menu.layout = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}},
                       {item(1, {{QStringLiteral("label"), QStringLiteral("_File")}, {QStringLiteral("children-display"), QStringLiteral("submenu")}},
                             {item(2, {{QStringLiteral("label"), QStringLiteral("_New")},
                                       {QStringLiteral("shortcut"), QVariant::fromValue(QList<QStringList>{{QStringLiteral("Control"), QStringLiteral("N")}})},
                                       {QStringLiteral("icon-data"), QByteArray("ignored")}})})});
    bool registered = false;
    QObject::connect(&server, &QDBusServer::newConnection, [&](const QDBusConnection& peer) {
        QDBusConnection c(peer);
        registered = c.registerVirtualObject(QStringLiteral("/MenuBar/1"), &menu, QDBusConnection::SingleNode);
    });
    QDBusConnection client = QDBusConnection::connectToPeer(server.address(), QStringLiteral("menu-bridge-test"));
    ASSERT_TRUE(client.isConnected()) << qPrintable(client.lastError().message());
    QElapsedTimer timer;
    timer.start();
    while (!registered && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
    ASSERT_TRUE(registered);

    const QDBusMessage reply = callAndWait(client, getLayoutCall(QString(), QStringLiteral("/MenuBar/1")));
    ASSERT_EQ(reply.type(), QDBusMessage::ReplyMessage) << qPrintable(reply.errorMessage());
    EXPECT_EQ(reply.signature(), QStringLiteral("u(ia{sv}av)"));
    RawItem      root;
    LayoutBudget budget;
    ASSERT_TRUE(readLayout(qvariant_cast<QDBusArgument>(reply.arguments().at(1)), root, 0, budget));
    EXPECT_FALSE(root.properties.contains(QStringLiteral("icon-data")) || root.children.value(0).children.value(0).properties.contains(QStringLiteral("icon-data")));
    const QJsonArray items = mapped(root);
    ASSERT_EQ(items.size(), 1);
    const QJsonObject newItem = items.at(0).toObject().value(QStringLiteral("children")).toArray().at(0).toObject();
    EXPECT_EQ(newItem.value(QStringLiteral("label")).toString(), QStringLiteral("New"));
    EXPECT_EQ(QJsonDocument(newItem.value(QStringLiteral("shortcut")).toArray()).toJson(QJsonDocument::Compact), QByteArray(R"([["Control","N"]])"));

    EXPECT_EQ(callAndWait(client, aboutToShowCall(QString(), QStringLiteral("/MenuBar/1"), 1)).type(), QDBusMessage::ReplyMessage);
    EXPECT_EQ(callAndWait(client, eventCall(QString(), QStringLiteral("/MenuBar/1"), 2)).type(), QDBusMessage::ReplyMessage);
    // Chromium accepts only these exact types (it has no introspection data to coerce untyped arguments).
    EXPECT_EQ(menu.calls, (QStringList{QStringLiteral("GetLayout:iias"), QStringLiteral("AboutToShow:i"), QStringLiteral("Event:isvu")}));
    QDBusConnection::disconnectFromPeer(QStringLiteral("menu-bridge-test"));
}

namespace {
    // A private peer-to-peer connection serving `menu` at /MenuBar/1 (no bus daemon).
    struct PeerMenu {
        QTemporaryDir dir;
        QDBusServer*  server = nullptr;
        FakeMenu      menu;
        bool          registered = false;
        QDBusConnection client{QStringLiteral("unconnected")};
        QString       name;

        explicit PeerMenu(const QString& connectionName) : name(connectionName) {
            server = new QDBusServer(QStringLiteral("unix:dir=") + dir.path());
            if (!server->isConnected())
                return;
            server->setAnonymousAuthenticationAllowed(true);
            QObject::connect(server, &QDBusServer::newConnection, [this](const QDBusConnection& peer) {
                QDBusConnection c(peer);
                registered = c.registerVirtualObject(QStringLiteral("/MenuBar/1"), &menu, QDBusConnection::SingleNode);
            });
            client = QDBusConnection::connectToPeer(server->address(), name);
            QElapsedTimer timer;
            timer.start();
            while (!registered && timer.elapsed() < 5000)
                QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        }
        ~PeerMenu() {
            QDBusConnection::disconnectFromPeer(name);
            delete server;
        }
        bool ok() const {
            return server && server->isConnected() && registered;
        }
        int getLayoutCalls() const {
            return static_cast<int>(menu.calls.filter(QStringLiteral("GetLayout:")).size());
        }
    };

    void pump(int ms) {
        QElapsedTimer timer;
        timer.start();
        while (timer.elapsed() < ms)
            QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    }
} // namespace

// A burst of LayoutUpdated signals less than the 40 ms coalescing delay apart must not starve the refetch (the timer
// used to restart on every signal: 1 ms spam gave one GetLayout in 10 s).
TEST(MenuClientRefetch, BurstOfSignalsStillRefetchesEveryCoalescingInterval) {
    PeerMenu peer(QStringLiteral("menu-bridge-test-burst"));
    if (!peer.ok())
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here";
    peer.menu.layout = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}}, {item(1, {{QStringLiteral("label"), QStringLiteral("File")}})});
    MenuClient client(peer.client, QStringLiteral("1"), QString(), QStringLiteral("/MenuBar/1"));
    client.start();
    QElapsedTimer timer;
    timer.start();
    while (!client.ready() && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    ASSERT_TRUE(client.ready());
    ASSERT_EQ(peer.getLayoutCalls(), 1);

    // 1 ms spam for 600 ms: with the restarting timer this would stay at 1; with a pending timer it is about 600/40.
    QTimer spam;
    spam.setInterval(1);
    QObject::connect(&spam, &QTimer::timeout, [&] { QMetaObject::invokeMethod(&client, "onMenuSignal", Q_ARG(QDBusMessage, QDBusMessage())); });
    spam.start();
    pump(600);
    spam.stop();
    pump(150);
    const int calls = peer.getLayoutCalls() - 1;
    EXPECT_GE(calls, 6) << "refetch starved by the signal burst";
    EXPECT_LE(calls, 18) << "refetch not coalesced";
}

// More items than any real menu has: refused, no menu, and not a single GetLayout more however many signals follow.
TEST(MenuClientRefetch, OversizedLayoutIsRefusedAndNeverReread) {
    PeerMenu peer(QStringLiteral("menu-bridge-test-huge"));
    if (!peer.ok())
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here";
    QList<RawItem> many;
    for (int i = 1; i <= limits::kItems + 500; ++i)
        many.append(item(i, {{QStringLiteral("label"), QStringLiteral("x")}}));
    peer.menu.layout = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}}, many);
    MenuClient client(peer.client, QStringLiteral("2"), QString(), QStringLiteral("/MenuBar/1"));
    QString    code;
    int        menus = 0;
    QObject::connect(&client, &MenuClient::failed, [&](const QString&, const QString& c, const QString&) { code = c; });
    QObject::connect(&client, &MenuClient::menuChanged, [&](const QString&) { ++menus; });
    client.start();
    QElapsedTimer timer;
    timer.start();
    while (code.isEmpty() && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    EXPECT_EQ(code, QStringLiteral("oversized"));
    EXPECT_EQ(menus, 0);
    for (int i = 0; i < 20; ++i)
        QMetaObject::invokeMethod(&client, "onMenuSignal", Q_ARG(QDBusMessage, QDBusMessage()));
    pump(200);
    EXPECT_EQ(peer.getLayoutCalls(), 1);
}

// The first read of a menu fails while its application is busy past the call timeout (Files drawing the Applications location
// on a loaded machine: GetLayout NoReply, and the bar kept the T0 menus "Files Window" until the window's next focus): it is
// read again, and the menu comes once the application answers; nothing is reported as failed meanwhile.
TEST(MenuClientRetry, AFirstReadThatFailsIsTriedAgain) {
    PeerMenu peer(QStringLiteral("menu-bridge-test-busy"));
    if (!peer.ok())
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here";
    peer.menu.layout = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}}, {item(1, {{QStringLiteral("label"), QStringLiteral("File")}})});
    peer.menu.busyGetLayouts = 2;
    MenuClient client(peer.client, QStringLiteral("4"), QString(), QStringLiteral("/MenuBar/1"));
    QString    code;
    int        menus = 0;
    QObject::connect(&client, &MenuClient::failed, [&](const QString&, const QString& c, const QString&) { code = c; });
    QObject::connect(&client, &MenuClient::menuChanged, [&](const QString&) { ++menus; });
    client.start();
    QElapsedTimer timer;
    timer.start();
    while (!client.ready() && code.isEmpty() && timer.elapsed() < 6000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    EXPECT_TRUE(client.ready()) << "the menu arrives once the application answers";
    EXPECT_EQ(code, QString()) << "no failure reported while it is retried";
    EXPECT_EQ(menus, 1);
    EXPECT_EQ(peer.getLayoutCalls(), 3);
    ASSERT_EQ(client.items().size(), 1);
    EXPECT_EQ(client.items().at(0).toObject().value(QStringLiteral("label")).toString(), QStringLiteral("File"));
}

// A first read that keeps failing is given up after four tries (layout-failed: the Bridge's short back-off), and nothing is
// read after that however many signals come.
TEST(MenuClientRetry, AFirstReadThatKeepsFailingIsGivenUpAfterFourTries) {
    PeerMenu peer(QStringLiteral("menu-bridge-test-failing"));
    if (!peer.ok())
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here";
    peer.menu.layout = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}}, {item(1, {{QStringLiteral("label"), QStringLiteral("File")}})});
    peer.menu.busyGetLayouts = 1000;
    MenuClient client(peer.client, QStringLiteral("5"), QString(), QStringLiteral("/MenuBar/1"));
    QString    code;
    QObject::connect(&client, &MenuClient::failed, [&](const QString&, const QString& c, const QString&) { code = c; });
    client.start();
    QElapsedTimer timer;
    timer.start();
    while (code.isEmpty() && timer.elapsed() < 8000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    EXPECT_EQ(code, QStringLiteral("layout-failed"));
    EXPECT_EQ(peer.getLayoutCalls(), 4) << "the first read and three tries again";
    EXPECT_FALSE(client.ready());
    for (int i = 0; i < 20; ++i)
        QMetaObject::invokeMethod(&client, "onMenuSignal", Q_ARG(QDBusMessage, QDBusMessage()));
    pump(300);
    EXPECT_EQ(peer.getLayoutCalls(), 4) << "nothing is read after it was given up";
}

// A menu shown before keeps its last good layout when a re-read fails (an application busy past the timeout after a
// LayoutUpdated: a long filter in GIMP; macOS keeps a busy app's menus): the bridge reads it again by itself never, the
// application's next signal does, and only three failed re-reads in a row give it up (review of fac5bff3: the retries had
// dropped a shown menu to T0 after 15 s of a busy app).
TEST(MenuClientRetry, AShownMenuKeepsItsLayoutWhenARefreshFails) {
    PeerMenu peer(QStringLiteral("menu-bridge-test-refresh"));
    if (!peer.ok())
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here";
    peer.menu.layout = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}}, {item(1, {{QStringLiteral("label"), QStringLiteral("File")}})});
    MenuClient client(peer.client, QStringLiteral("6"), QString(), QStringLiteral("/MenuBar/1"));
    QString    code;
    QObject::connect(&client, &MenuClient::failed, [&](const QString&, const QString& c, const QString&) { code = c; });
    client.start();
    QElapsedTimer timer;
    timer.start();
    while (!client.ready() && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    ASSERT_TRUE(client.ready());
    peer.menu.busyGetLayouts = 1000;
    QMetaObject::invokeMethod(&client, "onMenuSignal", Q_ARG(QDBusMessage, QDBusMessage()));
    pump(4000);
    EXPECT_EQ(code, QString()) << "the menu stays";
    EXPECT_EQ(peer.getLayoutCalls(), 2) << "no read of the bridge's own after a failed refresh";
    ASSERT_EQ(client.items().size(), 1);
    EXPECT_EQ(client.items().at(0).toObject().value(QStringLiteral("label")).toString(), QStringLiteral("File"));
    QMetaObject::invokeMethod(&client, "onMenuSignal", Q_ARG(QDBusMessage, QDBusMessage()));
    pump(300);
    EXPECT_EQ(code, QString()) << "two failed re-reads keep it too";
    QMetaObject::invokeMethod(&client, "onMenuSignal", Q_ARG(QDBusMessage, QDBusMessage()));
    pump(300);
    EXPECT_EQ(code, QStringLiteral("layout-failed")) << "the third failed re-read in a row gives it up";
    EXPECT_EQ(peer.getLayoutCalls(), 4);
}

// A first read answered with a reply of the wrong shape is not tried again (review of fac5bff3, NIT): only a read the
// application did not answer may succeed later.
TEST(MenuClientRetry, AFirstReadOfTheWrongShapeIsNotTriedAgain) {
    PeerMenu peer(QStringLiteral("menu-bridge-test-shape"));
    if (!peer.ok())
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here";
    peer.menu.wrongSignature = true;
    MenuClient client(peer.client, QStringLiteral("7"), QString(), QStringLiteral("/MenuBar/1"));
    QString    code;
    QObject::connect(&client, &MenuClient::failed, [&](const QString&, const QString& c, const QString&) { code = c; });
    client.start();
    QElapsedTimer timer;
    timer.start();
    while (code.isEmpty() && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    EXPECT_EQ(code, QStringLiteral("layout-failed"));
    pump(1200);
    EXPECT_EQ(peer.getLayoutCalls(), 1) << "read once";
}

// The tries of a first read wait longer each time (0.5, 1, 2 s): a busy application is not asked again and again (review
// of fac5bff3, NIT: a constant delay survived the tests).
TEST(MenuClientRetry, TheTriesOfAFirstReadWaitLongerEachTime) {
    PeerMenu peer(QStringLiteral("menu-bridge-test-backoff"));
    if (!peer.ok())
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here";
    peer.menu.layout = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}}, {item(1, {{QStringLiteral("label"), QStringLiteral("File")}})});
    peer.menu.busyGetLayouts = 3;
    MenuClient client(peer.client, QStringLiteral("8"), QString(), QStringLiteral("/MenuBar/1"));
    client.start();
    QElapsedTimer timer;
    timer.start();
    while (!client.ready() && timer.elapsed() < 8000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    ASSERT_TRUE(client.ready());
    const QList<qint64>& t = peer.menu.getLayoutTimes;
    ASSERT_EQ(t.size(), 4);
    const qint64 g1 = t[1] - t[0], g2 = t[2] - t[1], g3 = t[3] - t[2];
    EXPECT_GE(g1, 400) << "the first wait is about 0.5 s";
    EXPECT_GE(g2 * 10, g1 * 16) << "then about twice as long: " << g1 << " then " << g2 << " ms";
    EXPECT_GE(g3 * 10, g2 * 16) << "and twice again: " << g2 << " then " << g3 << " ms";
}

// The failures of a first read do not count against the menu once it is shown (review of fac5bff3, NIT: a mutant without
// the reset survived): two tries before the first layout, then two failed re-reads, and the menu stays.
TEST(MenuClientRetry, AShownMenuCountsOnlyItsOwnFailedReReads) {
    PeerMenu peer(QStringLiteral("menu-bridge-test-reset"));
    if (!peer.ok())
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here";
    peer.menu.layout = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}}, {item(1, {{QStringLiteral("label"), QStringLiteral("File")}})});
    peer.menu.busyGetLayouts = 2;
    MenuClient client(peer.client, QStringLiteral("9"), QString(), QStringLiteral("/MenuBar/1"));
    QString    code;
    QObject::connect(&client, &MenuClient::failed, [&](const QString&, const QString& c, const QString&) { code = c; });
    client.start();
    QElapsedTimer timer;
    timer.start();
    while (!client.ready() && timer.elapsed() < 6000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    ASSERT_TRUE(client.ready());
    peer.menu.busyGetLayouts = 2;
    QMetaObject::invokeMethod(&client, "onMenuSignal", Q_ARG(QDBusMessage, QDBusMessage()));
    pump(300);
    QMetaObject::invokeMethod(&client, "onMenuSignal", Q_ARG(QDBusMessage, QDBusMessage()));
    pump(300);
    EXPECT_EQ(code, QString()) << "two failed re-reads keep the menu";
    EXPECT_EQ(client.items().size(), 1);
    QMetaObject::invokeMethod(&client, "onMenuSignal", Q_ARG(QDBusMessage, QDBusMessage()));
    pump(300);
    EXPECT_EQ(code, QString()) << "and a successful one starts the count again";
    EXPECT_EQ(peer.getLayoutCalls(), 6);
}

TEST(DBusMenuWire, NonLayoutArgumentsAreRefused) {
    QDBusArgument notAStruct;
    notAStruct << QStringLiteral("x");
    RawItem      root;
    LayoutBudget budget;
    EXPECT_FALSE(readLayout(notAStruct, root, 0, budget));
}

// Every outbound call is announced (callBegun) before it is sent and ended (callEnded) when its reply was handled:
// the crash attribution of the bridge relies on it (GetLayout, the re-read after LayoutUpdated, AboutToShow, Event).
TEST(MenuClientCalls, EveryOutboundCallIsAnnouncedAndEnded) {
    PeerMenu peer(QStringLiteral("menu-bridge-test-calls"));
    if (!peer.ok())
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here";
    peer.menu.layout = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}},
                            {item(1, {{QStringLiteral("label"), QStringLiteral("File")}, {QStringLiteral("children-display"), QStringLiteral("submenu")}}, {item(2, {{QStringLiteral("label"), QStringLiteral("New")}})})});
    MenuClient client(peer.client, QStringLiteral("3"), QString(), QStringLiteral("/MenuBar/1"));
    int        begun = 0;
    int        ended = 0;
    int        seenAtSend = -1;
    QObject::connect(&client, &MenuClient::callBegun, [&] {
        ++begun;
        seenAtSend = static_cast<int>(peer.menu.calls.size()); // nothing of this call has reached the application yet
    });
    QObject::connect(&client, &MenuClient::callEnded, [&] { ++ended; });
    client.start();
    EXPECT_EQ(begun, 1);
    EXPECT_EQ(seenAtSend, 0);
    QElapsedTimer timer;
    timer.start();
    while (ended < 1 && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    EXPECT_EQ(ended, 1);
    EXPECT_EQ(client.outstanding(), 0);

    // The re-read after a LayoutUpdated signal is announced as well (it used to be unmarked).
    QMetaObject::invokeMethod(&client, "onMenuSignal", Q_ARG(QDBusMessage, QDBusMessage()));
    timer.restart();
    while (ended < 2 && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    EXPECT_EQ(begun, 2);
    EXPECT_EQ(ended, 2);

    ASSERT_TRUE(client.aboutToShow(1));
    EXPECT_EQ(begun, 3);
    EXPECT_EQ(client.outstanding(), 1);
    ASSERT_TRUE(client.activate(2));
    EXPECT_EQ(begun, 4);
    EXPECT_EQ(client.outstanding(), 2);
    timer.restart();
    while (client.outstanding() > 0 && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    EXPECT_EQ(ended, 4);
}

// ---- penalties and the state file --------------------------------------------------------------------------------

namespace {
    struct Clock {
        qint64 now = 1000;
    };
    PenaltyBook book(Clock& c) {
        return PenaltyBook([&c] { return c.now; });
    }
    const QString kApp   = QStringLiteral("id:exe=/usr/bin/evil");
    const QString kOther = QStringLiteral("id:exe=/usr/bin/calc");
    const QString kBoot  = QStringLiteral("boot-1");

    QString cgroupOf(const QString& path) {
        return QStringLiteral("0::") + path + u'\n';
    }
    // A state file as the previous run left it.
    QByteArray previousRun(Clock& c, const QList<InflightCall>& inflight, bool running = true) {
        PenaltyBook before = book(c);
        return before.serialize(inflight, kBoot, running);
    }
    CrashOutcome crashOutcome(Clock&, PenaltyBook& after, const QByteArray& data) {
        QString      why;
        CrashOutcome out;
        EXPECT_TRUE(after.load(data, kBoot, &why, &out)) << qPrintable(why);
        return out;
    }
} // namespace

// ---- identity -----------------------------------------------------------------------------------------------------

TEST(Identity, OfThisProcessSurvivesANewPidAndIsNeverAPid) {
    const QString me = appIdentity(::getpid());
    EXPECT_TRUE(me.startsWith(QStringLiteral("id:")) && me.contains(QStringLiteral("exe=/"))) << qPrintable(me);
    EXPECT_TRUE(validIdentity(me));
    const pid_t child = ::fork();
    if (child == 0)
        ::_exit(appIdentity(::getpid()) == appIdentity(::getppid()) ? 0 : 1);
    ASSERT_GT(child, 0);
    int status = 0;
    ASSERT_EQ(::waitpid(child, &status, 0), child);
    EXPECT_TRUE(WIFEXITED(status) && WEXITSTATUS(status) == 0) << "a forked child must have the parent's identity";
    EXPECT_EQ(appIdentity(2147483000), kUnknownIdentity) << "no such process: the shared bucket, never pid:<n>";
}

TEST(Identity, AppScopeOfCgroupSamples) {
    // systemd app scopes: the instance suffix is stripped.
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/app-Hyprland-foot-12345.scope"))), QStringLiteral("app-Hyprland-foot"));
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/app-Hyprland-foot-99999.scope"))), QStringLiteral("app-Hyprland-foot"))
        << "another instance of the same application has the same scope";
    // flatpak: the id is part of the scope, the instance is not.
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/app-flatpak-org.mozilla.firefox-4242.scope"))), QStringLiteral("app-flatpak-org.mozilla.firefox"));
    // a process in a sub-cgroup of the scope
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/app-gnome-code-7.scope/sandbox"))), QStringLiteral("app-gnome-code"));
    // a template service: the instance after '@' is stripped
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/app-org.kde.kalk@autostart.service"))), QStringLiteral("app-org.kde.kalk"));
    // hybrid hierarchies: the v2 line wins
    EXPECT_EQ(appScopeOf(QStringLiteral("1:name=systemd:/other.scope\n0::/app.slice/app-x-y-1.scope\n")), QStringLiteral("app-x-y"));
    // not in an app scope: none
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/user.slice/user-1000.slice/session-3.scope"))), QString());
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/"))), QString());
    EXPECT_EQ(appScopeOf(QString()), QString());
    EXPECT_EQ(appScopeOf(QStringLiteral("garbage")), QString());
    // uwsm: app-<launcher>-<app>-<8 hex>.scope, '-' of the app name escaped as \x2d (as seen in /proc/<pid>/cgroup)
    const QString uwsm = QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/app-Hyprland-gtk\\x2dlaunch-2616d5ca.scope");
    EXPECT_EQ(appScopeOf(cgroupOf(uwsm)), QStringLiteral("app-Hyprland-gtk\\x2dlaunch")) << "the canonical key keeps the escape";
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/app.slice/app-Hyprland-gtk\\x2dlaunch-9f00ba17.scope"))), appScopeOf(cgroupOf(uwsm))) << "a relaunch is the same identity";
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/app.slice/app-Hyprland-foot-0a1b2c3d.scope"))), QStringLiteral("app-Hyprland-foot"));
    // uwsm with a numeric instance, and the other launchers' numeric suffixes
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/app.slice/app-Hyprland-firefox-12345678.scope"))), QStringLiteral("app-Hyprland-firefox"));
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/app.slice/app-kde-org.kde.dolphin-8123.scope"))), QStringLiteral("app-kde-org.kde.dolphin"));
    // KIO (KF6 6.29, ApplicationLauncherJob): app-<name>-<QUuid::toString(Id128)>.scope, 32 hex digits.
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/app.slice/app-org.kde.dolphin-0f8e2b7c4d1a4e5f9a6b3c2d1e0f9a8b.scope"))), QStringLiteral("app-org.kde.dolphin"));
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/app.slice/app-org.kde.dolphin-5e6f7a8b9c0d4e1f8a2b3c4d5e6f7a8b.scope"))),
              appScopeOf(cgroupOf(QStringLiteral("/app.slice/app-org.kde.dolphin-0f8e2b7c4d1a4e5f9a6b3c2d1e0f9a8b.scope")))) << "a KIO relaunch is the same identity";
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/app.slice/app-gnome-org.gnome.Nautilus-3456.scope"))), QStringLiteral("app-gnome-org.gnome.Nautilus"));
    EXPECT_EQ(displayIdentity(QStringLiteral("id:scope=app-Hyprland-gtk\\x2dlaunch|exe=/usr/bin/x")), QStringLiteral("id:scope=app-Hyprland-gtk-launch|exe=/usr/bin/x"));
    // a unit name carrying a separator or control character is not trusted
    EXPECT_EQ(appScopeOf(cgroupOf(QStringLiteral("/app.slice/app-a|b-1.scope"))), QString());
}

TEST(Identity, ScriptOfInterpreters) {
    const auto cmd = [](std::initializer_list<const char*> args) {
        QByteArray out;
        for (const char* a : args)
            out += QByteArray(a) + '\0';
        return out;
    };
    EXPECT_EQ(scriptOf(QStringLiteral("/usr/bin/python3.14"), cmd({"python3", "/home/u/app.py", "--x"})), QStringLiteral("/home/u/app.py"));
    EXPECT_EQ(scriptOf(QStringLiteral("/usr/bin/bash"), cmd({"bash", "/opt/run.sh"})), QStringLiteral("/opt/run.sh"));
    EXPECT_EQ(scriptOf(QStringLiteral("/usr/lib/jvm/default/bin/java"), cmd({"java", "-jar", "app.jar"})), QStringLiteral("app.jar"));
    EXPECT_EQ(scriptOf(QStringLiteral("/usr/bin/python3"), cmd({"python3", "--", "x.py"})), QStringLiteral("x.py"));
    // Any interpreter option before the script goes to the shared bucket: an option's value is never taken for the
    // script (review cases: python -W/-X, node --trace-event-categories, perl -C / ruby -F attached values, -m, -c/-e).
    for (const auto& c : {cmd({"python3", "-W", "/usr/bin/victim-app", "evil.py"}), cmd({"python3", "-X", "dev", "a.py"}),
                          cmd({"python3", "-I", "/home/u/app.py"}), cmd({"python3", "-m", "http.server"}), cmd({"python3", "-c", "print(1)"})})
        EXPECT_EQ(scriptOf(QStringLiteral("/usr/bin/python3"), c), kScriptUnknown);
    EXPECT_EQ(scriptOf(QStringLiteral("/usr/bin/node"), cmd({"node", "--trace-event-categories", "/opt/victim/app.js", "hostile.js"})), kScriptUnknown);
    EXPECT_EQ(scriptOf(QStringLiteral("/usr/bin/node"), cmd({"node", "--inspect", "server.js"})), kScriptUnknown);
    EXPECT_EQ(scriptOf(QStringLiteral("/usr/bin/perl"), cmd({"perl", "-C", "x.pl", "arg1"})), kScriptUnknown);
    EXPECT_EQ(scriptOf(QStringLiteral("/usr/bin/ruby"), cmd({"ruby", "-F", "x.rb", "arg1"})), kScriptUnknown);
    EXPECT_EQ(scriptOf(QStringLiteral("/usr/bin/perl"), cmd({"perl", "-m", "strict", "a.pl"})), kScriptUnknown);
    EXPECT_EQ(identityFrom({QString(), QStringLiteral("/usr/bin/python3"), cmd({"python3", "--made-up", "a", "b.py"})}), kUnknownIdentity);
    EXPECT_EQ(scriptOf(QStringLiteral("/usr/bin/python3"), QByteArray()), QString()) << "unreadable cmdline";
    EXPECT_EQ(scriptOf(QStringLiteral("/usr/bin/foot"), cmd({"foot", "something"})), QString()) << "not an interpreter";
    EXPECT_EQ(scriptOf(QStringLiteral("/usr/bin/python3"), cmd({"python3", "a|b\x01.py"})), QStringLiteral("a?b?.py"));
}

TEST(Identity, FromFacts) {
    PeerFacts f;
    f.exe    = QStringLiteral("/usr/bin/foot");
    f.cgroup = cgroupOf(QStringLiteral("/user.slice/user@1000.service/app.slice/app-Hyprland-foot-5.scope"));
    EXPECT_EQ(identityFrom(f), QStringLiteral("id:scope=app-Hyprland-foot|exe=/usr/bin/foot"));
    // Same application, another instance and another pid: same identity.
    f.cgroup = cgroupOf(QStringLiteral("/user.slice/user@1000.service/app.slice/app-Hyprland-foot-77.scope"));
    EXPECT_EQ(identityFrom(f), QStringLiteral("id:scope=app-Hyprland-foot|exe=/usr/bin/foot"));
    // No app scope: executable only.
    f.cgroup = cgroupOf(QStringLiteral("/user.slice/session-2.scope"));
    EXPECT_EQ(identityFrom(f), QStringLiteral("id:exe=/usr/bin/foot"));
    // An interpreter adds the script: two python applications are not one identity.
    PeerFacts a, b;
    a.exe     = b.exe = QStringLiteral("/usr/bin/python3.14");
    a.cmdline = QByteArrayLiteral("python3\0/opt/one.py\0");
    b.cmdline = QByteArrayLiteral("python3\0/opt/two.py\0");
    EXPECT_NE(identityFrom(a), identityFrom(b));
    EXPECT_TRUE(identityFrom(a).endsWith(QStringLiteral("|script=/opt/one.py")));
    // The same python script from two scopes is two applications as well (a distro-shared runtime).
    a.cgroup = cgroupOf(QStringLiteral("/app.slice/app-x-one-1.scope"));
    b.cmdline = a.cmdline;
    b.cgroup  = cgroupOf(QStringLiteral("/app.slice/app-x-two-1.scope"));
    EXPECT_NE(identityFrom(a), identityFrom(b));
    // A replaced binary keeps its identity.
    PeerFacts g;
    g.exe = QStringLiteral("/usr/bin/foot (deleted)");
    EXPECT_EQ(identityFrom(g), QStringLiteral("id:exe=/usr/bin/foot"));
    // Unreadable (empty or not absolute): the one shared bucket, whatever else is known.
    PeerFacts u;
    u.cgroup  = cgroupOf(QStringLiteral("/app.slice/app-x-y-1.scope"));
    u.cmdline = QByteArrayLiteral("whatever\0");
    EXPECT_EQ(identityFrom(u), kUnknownIdentity);
    u.exe = QStringLiteral("relative");
    EXPECT_EQ(identityFrom(u), kUnknownIdentity);
    EXPECT_TRUE(validIdentity(kUnknownIdentity));
}

TEST(Identity, Validation) {
    EXPECT_TRUE(validIdentity(QStringLiteral("id:exe=/usr/bin/foo bar")));
    EXPECT_TRUE(validIdentity(QStringLiteral("id:scope=app-x|exe=/usr/bin/foo|script=a.py")));
    EXPECT_TRUE(validIdentity(QStringLiteral("unknown")));
    EXPECT_FALSE(validIdentity(QString()));
    EXPECT_FALSE(validIdentity(QStringLiteral("pid:4242"))) << "a pid is never an identity";
    EXPECT_FALSE(validIdentity(QStringLiteral("exe:/usr/bin/foo")));
    EXPECT_FALSE(validIdentity(QStringLiteral("id:exe=relative")));
    EXPECT_FALSE(validIdentity(QStringLiteral("id:exe=/a\nb")));
    EXPECT_FALSE(validIdentity(QStringLiteral("id:exe=/") + QString(penalty::kMaxIdentity, u'a')));
    EXPECT_FALSE(validIdentity(QStringLiteral("window 1")));
}

// ---- refusals, doubling, eviction ----------------------------------------------------------------------------------

TEST(Penalties, CrashRefusesForTheBaseSpanThenDoubles) {
    Clock       c;
    PenaltyBook b = book(c);
    QString     why;
    EXPECT_FALSE(b.refused(kApp, &why));
    b.record(kApp, Offence::Crash);
    EXPECT_TRUE(b.refused(kApp, &why));
    EXPECT_FALSE(b.refused(kOther, &why)) << "another application is not affected";
    c.now += penalty::kDenyBaseSec - 1;
    EXPECT_TRUE(b.refused(kApp, &why));
    c.now += 1;
    EXPECT_FALSE(b.refused(kApp, &why));
    b.record(kApp, Offence::Crash); // second strike: twice as long
    c.now += penalty::kDenyBaseSec * 2 - 1;
    EXPECT_TRUE(b.refused(kApp, &why));
    c.now += 1;
    EXPECT_FALSE(b.refused(kApp, &why));
    for (int i = 0; i < 20; ++i)
        b.record(kApp, Offence::Oversized);
    c.now += penalty::kDenyMaxSec - 1;
    EXPECT_TRUE(b.refused(kApp, &why)) << "capped, never overflows";
    c.now += 1;
    EXPECT_FALSE(b.refused(kApp, &why));
}

TEST(Penalties, UnknownBucketIsRefusedBrieflyNeverDoublesNeverPermanent) {
    Clock       c;
    PenaltyBook b = book(c);
    QString     why;
    for (int i = 0; i < 10; ++i)
        b.record(kUnknownIdentity, Offence::Crash);
    EXPECT_TRUE(b.refused(kUnknownIdentity, &why));
    c.now += penalty::kUnknownDenySec - 1;
    EXPECT_TRUE(b.refused(kUnknownIdentity, &why));
    c.now += 1;
    EXPECT_FALSE(b.refused(kUnknownIdentity, &why)) << "ten strikes, still only the short refusal";
    // A forged state file cannot make the bucket long-refused.
    PenaltyBook forged = book(c);
    const QByteArray data = QByteArray("grassfield-menu-bridge-state 3\nboot boot-1\nrun 0\ndeny 5 ") + QByteArray::number(c.now + penalty::kDenyMaxSec) + " 0 unknown\n";
    ASSERT_TRUE(forged.load(data, kBoot, &why, nullptr)) << qPrintable(why);
    EXPECT_TRUE(forged.refused(kUnknownIdentity, &why));
    c.now += penalty::kUnknownDenySec;
    EXPECT_FALSE(forged.refused(kUnknownIdentity, &why));
}

TEST(Penalties, LayoutFailureBacksOffShortlyAndDeliveryEndsIt) {
    Clock       c;
    PenaltyBook b = book(c);
    QString     why;
    b.record(kApp, Offence::LayoutFailed);
    EXPECT_TRUE(b.refused(kApp, &why));
    c.now += 2;
    EXPECT_FALSE(b.refused(kApp, &why));
    for (int i = 0; i < 20; ++i)
        b.record(kApp, Offence::LayoutFailed);
    c.now += penalty::kLayoutMaxSec - 1;
    EXPECT_TRUE(b.refused(kApp, &why));
    c.now += 1;
    EXPECT_FALSE(b.refused(kApp, &why));
    b.record(kApp, Offence::LayoutFailed);
    b.delivered(kApp);
    EXPECT_FALSE(b.refused(kApp, &why));
}

TEST(Penalties, CleanExitDoesNotResetTheDoublingInsideTheDecayWindow) {
    Clock       c;
    PenaltyBook b = book(c);
    QString     why;
    b.record(kApp, Offence::Crash);
    c.now += penalty::kDenyBaseSec;
    EXPECT_FALSE(b.refused(kApp, &why));
    // Leaving the bus cleanly right after the refusal does not forget the strike: the next one doubles.
    b.leftCleanly(kApp);
    EXPECT_TRUE(b.has(kApp));
    b.record(kApp, Offence::Crash);
    c.now += penalty::kDenyBaseSec * 2 - 1;
    EXPECT_TRUE(b.refused(kApp, &why)) << "the second strike doubled although the app exited cleanly in between";
    // A refused application's exit does not clear its refusal either.
    b.leftCleanly(kApp);
    EXPECT_TRUE(b.refused(kApp, &why));
}

TEST(Penalties, EntriesDecay) {
    Clock       c;
    PenaltyBook b = book(c);
    QString     why;
    b.record(kApp, Offence::Crash);
    c.now += penalty::kForgiveSec;
    // A clean exit after the decay window forgives the strike.
    b.leftCleanly(kApp);
    EXPECT_FALSE(b.has(kApp));
    // Without a new strike for kForgiveSec the entry is dropped when asked about.
    b.record(kApp, Offence::Crash);
    c.now += penalty::kForgiveSec;
    EXPECT_FALSE(b.refused(kApp, &why));
    EXPECT_FALSE(b.has(kApp));
}

TEST(Penalties, FreshIdentitiesNeverEvictARefusalBeforeItExpires) {
    Clock       c;
    PenaltyBook b = book(c);
    QString     why;
    b.record(kApp, Offence::Crash); // refused: kept while idle entries are evicted
    for (int i = 0; i < penalty::kMaxIdle * 3; ++i)
        b.record(QStringLiteral("id:exe=/tmp/copy-%1").arg(i + 1), Offence::LayoutFailed);
    EXPECT_LE(b.size(), penalty::kMaxIdle + 1);
    EXPECT_TRUE(b.refused(kApp, &why)) << "128+ cheap identities did not evict the refusal";
    EXPECT_TRUE(b.has(QStringLiteral("id:exe=/tmp/copy-%1").arg(penalty::kMaxIdle * 3)));
    EXPECT_FALSE(b.has(QStringLiteral("id:exe=/tmp/copy-1"))) << "the least recently used idle entry went first";
    // Once the refusal has expired the entry is idle and evictable.
    c.now += penalty::kDenyBaseSec;
    for (int i = 0; i < penalty::kMaxIdle * 2; ++i)
        b.record(QStringLiteral("id:exe=/tmp/more-%1").arg(i + 1), Offence::LayoutFailed);
    EXPECT_FALSE(b.has(kApp));
}

TEST(Penalties, RefusedEntriesAreCappedSeparatelyAndTheSoonestToExpireGoes) {
    Clock       c;
    PenaltyBook b = book(c);
    for (int i = 0; i < penalty::kMaxRefused + 10; ++i) {
        b.record(QStringLiteral("id:exe=/tmp/bad-%1").arg(i + 1), Offence::Crash);
        c.now += 1; // later refusals expire later
    }
    EXPECT_EQ(b.refusedCount(), penalty::kMaxRefused);
    QString why;
    EXPECT_TRUE(b.refused(QStringLiteral("id:exe=/tmp/bad-%1").arg(penalty::kMaxRefused + 10), &why));
    EXPECT_FALSE(b.has(QStringLiteral("id:exe=/tmp/bad-1")));
}

// ---- crash attribution --------------------------------------------------------------------------------------------

TEST(Attribution, ExactlyOneFreshCallIsBlamed) {
    Clock            c;
    const QByteArray data = previousRun(c, {{kApp, 1, 120}});
    PenaltyBook      after = book(c);
    const CrashOutcome out  = crashOutcome(c, after, data);
    QString          why;
    EXPECT_TRUE(out.crashed);
    EXPECT_EQ(out.culprit, kApp);
    EXPECT_EQ(out.crashes, 1) << "a blamed crash counts toward the degradation budget too";
    EXPECT_TRUE(after.refused(kApp, &why));
    EXPECT_FALSE(after.refused(kOther, &why));
    EXPECT_EQ(after.crashes(), 1);
}

TEST(Attribution, SeveralCallsInFlightBlameNobody) {
    Clock c;
    QString why;
    for (const auto& calls : {QList<InflightCall>{{kApp, 1, 10}, {kOther, 1, 10}},  // two peers
                              QList<InflightCall>{{kApp, 2, 10}},                   // two calls to one identity
                              QList<InflightCall>{{kApp, 1, 10}, {kApp + QStringLiteral("2"), 1, 10}}}) {
        PenaltyBook  after = book(c);
        const CrashOutcome out = crashOutcome(c, after, previousRun(c, calls));
        EXPECT_TRUE(out.crashed);
        EXPECT_TRUE(out.culprit.isEmpty());
        EXPECT_EQ(out.crashes, 1);
        for (const InflightCall& ic : calls)
            EXPECT_FALSE(after.refused(ic.id, &why)) << "an innocent was refused: " << qPrintable(ic.id);
    }
}

TEST(Attribution, NothingInFlightIsAnUnattributedCrash) {
    Clock              c;
    PenaltyBook        after = book(c);
    const CrashOutcome out   = crashOutcome(c, after, previousRun(c, {}));
    EXPECT_TRUE(out.crashed);
    EXPECT_TRUE(out.culprit.isEmpty());
    EXPECT_EQ(after.crashes(), 1);
    EXPECT_EQ(after.refusedCount(), 0);
}

TEST(Attribution, AStaleSingleCallIsNotBlamed) {
    // A slow application's call open when someone else's message kills the bridge.
    Clock              c;
    PenaltyBook        after = book(c);
    const CrashOutcome out   = crashOutcome(c, after, previousRun(c, {{kApp, 1, penalty::kFreshCallMs + 1}}));
    QString            why;
    EXPECT_TRUE(out.culprit.isEmpty());
    EXPECT_FALSE(after.refused(kApp, &why));
    EXPECT_EQ(after.crashes(), 1);
    PenaltyBook edge = book(c);
    EXPECT_EQ(crashOutcome(c, edge, previousRun(c, {{kApp, 1, penalty::kFreshCallMs}})).culprit, kApp) << "exactly at the limit is still fresh";
}

TEST(Attribution, ACleanStopIsNoCrashAndIgnoresStaleInflightLines) {
    Clock              c;
    PenaltyBook        after = book(c);
    const CrashOutcome out   = crashOutcome(c, after, previousRun(c, {{kApp, 1, 5}}, /*running=*/false));
    QString            why;
    EXPECT_FALSE(out.crashed);
    EXPECT_FALSE(after.refused(kApp, &why));
    EXPECT_EQ(after.crashes(), 0);
}

TEST(Attribution, RotatingCopiesAreBlamedAndStillDegradeTheBridge) {
    // Each run dies with one fresh call to a new identity (a copy of the binary): every copy is refused, and the
    // crashes still add up to the budget.
    Clock       c;
    QByteArray  data = previousRun(c, {{QStringLiteral("id:exe=/tmp/copy-0"), 1, 10}});
    PenaltyBook after = book(c);
    for (int i = 1; i <= penalty::kMaxCrashes; ++i) {
        after = book(c);
        crashOutcome(c, after, data);
        EXPECT_EQ(after.crashes(), i);
        EXPECT_EQ(after.degraded(), i >= penalty::kMaxCrashes) << i;
        data = after.serialize({{QStringLiteral("id:exe=/tmp/copy-%1").arg(i), 1, 10}}, kBoot, true);
        c.now += 60;
    }
    QString why;
    EXPECT_TRUE(after.refused(QStringLiteral("id:exe=/tmp/copy-0"), &why));
}

TEST(Attribution, TheCrashWindowSlides) {
    // 5 crashes spread over 59 minutes still degrade (a window that restarts at its first crash would not).
    Clock      c;
    QByteArray data = previousRun(c, {});
    PenaltyBook after = book(c);
    for (int i = 1; i <= penalty::kMaxCrashes; ++i) {
        if (i > 1)
            c.now += (59 * 60) / (penalty::kMaxCrashes - 1) - 1;
        after = book(c);
        crashOutcome(c, after, data);
        data = after.serialize({}, kBoot, true);
    }
    EXPECT_TRUE(after.degraded());
    // The first crash (at 1000) leaves the window: four are left.
    const QByteArray stopped = after.serialize({}, kBoot, false);
    c.now                    = 1000 + penalty::kCrashWindowSec;
    PenaltyBook reread       = book(c);
    QString     why;
    ASSERT_TRUE(reread.load(stopped, kBoot, &why, nullptr)) << qPrintable(why);
    EXPECT_FALSE(reread.degraded());
    EXPECT_EQ(reread.crashes(), penalty::kMaxCrashes - 1);
}

TEST(Attribution, EveryCrashIsCountedPersistedAndMakesTheBridgeGiveUp) {
    Clock c;
    QByteArray data = previousRun(c, {});
    for (int i = 1; i <= penalty::kMaxCrashes; ++i) {
        PenaltyBook after = book(c);
        crashOutcome(c, after, data);
        EXPECT_EQ(after.crashes(), i);
        EXPECT_EQ(after.degraded(), i >= penalty::kMaxCrashes) << i;
        data = after.serialize({}, kBoot, true); // this run crashes too, unexplained
        c.now += 30;
    }
    // The count decays after the window: a bridge that restarts much later starts fresh.
    c.now += penalty::kCrashWindowSec;
    PenaltyBook later = book(c);
    crashOutcome(c, later, data);
    EXPECT_EQ(later.crashes(), 1);
    EXPECT_FALSE(later.degraded());
    // A clean stop keeps the count (the file still says what happened) but is no new crash.
    PenaltyBook clean = book(c);
    crashOutcome(c, clean, later.serialize({}, kBoot, false));
    EXPECT_EQ(clean.crashes(), 1);
}

TEST(PenaltyState, RefusalsAndStrikesSurviveARestart) {
    Clock       c;
    PenaltyBook first = book(c);
    first.record(kApp, Offence::Crash);
    const QByteArray data = first.serialize({}, kBoot, false);
    PenaltyBook      third = book(c);
    QString          why;
    ASSERT_TRUE(third.load(data, kBoot, &why, nullptr)) << qPrintable(why);
    EXPECT_TRUE(third.refused(kApp, &why));
    EXPECT_FALSE(third.refused(kOther, &why));
    c.now += penalty::kDenyBaseSec;
    EXPECT_FALSE(third.refused(kApp, &why));
    third.record(kApp, Offence::Crash);
    c.now += penalty::kDenyBaseSec * 2 - 1;
    EXPECT_TRUE(third.refused(kApp, &why)) << "the second strike doubled (strike count restored)";
    // The identity with spaces and separators round-trips.
    PenaltyBook      sp = book(c);
    const QString    odd = QStringLiteral("id:scope=app-x|exe=/opt/with space/app|script=a b.py");
    sp.record(odd, Offence::Crash);
    PenaltyBook back = book(c);
    ASSERT_TRUE(back.load(sp.serialize({}, kBoot, false), kBoot, &why, nullptr)) << qPrintable(why);
    EXPECT_TRUE(back.refused(odd, &why));
}

TEST(PenaltyState, ForgedOrDamagedContentIsRefusedWhole) {
    Clock         c;
    QString       why;
    const QString boot = kBoot;
    const auto    valid = [&](const QByteArray& body, const char* run = "run 1\n") {
        PenaltyBook b = book(c);
        return b.load(QByteArray("grassfield-menu-bridge-state 3\nboot boot-1\n") + run + body, boot, &why, nullptr);
    };
    EXPECT_TRUE(valid("inflight 1 5 id:exe=/usr/bin/x\n"));
    EXPECT_TRUE(valid("inflight 1 5 unknown\n"));
    EXPECT_FALSE(valid("inflight 1 5 id:exe=relative\n"));
    EXPECT_FALSE(valid("inflight 1 5 id:exe=/a%0Ab\n")) << "control characters";
    EXPECT_FALSE(valid("inflight 1 5 pid:12\n")) << "a pid is not an identity";
    EXPECT_FALSE(valid("inflight 0 5 id:exe=/x\n")) << "zero calls";
    EXPECT_FALSE(valid("inflight 1 -5 id:exe=/x\n")) << "negative age";
    EXPECT_FALSE(valid("inflight a b\n"));
    EXPECT_TRUE(valid("crash 5\n"));
    EXPECT_FALSE(valid("crash -5\n"));
    EXPECT_FALSE(valid("crash 99999\n")) << "in the future";
    EXPECT_FALSE(valid("crash 1 2\n"));
    EXPECT_FALSE(valid("unattributed 1 5\n")) << "the old format";
    EXPECT_FALSE(valid("deny 0 1 1 id:exe=/x\n")) << "zero strikes";
    EXPECT_FALSE(valid("deny 1 99999999999 1 id:exe=/x\n")) << "deny far in the future";
    EXPECT_FALSE(valid("deny 1 5 99999 id:exe=/x\n")) << "last strike in the future";
    EXPECT_FALSE(valid("deny 1 5 5 id:exe=/x extra\n"));
    EXPECT_FALSE(valid("unknown line\n"));
    EXPECT_FALSE(valid("", "run 2\n"));
    EXPECT_FALSE(valid("run 0\n")) << "two run lines";
    {
        PenaltyBook b = book(c);
        EXPECT_FALSE(b.load("grassfield-menu-bridge-state 1\nboot boot-1\nrun 0\n", boot, &why, nullptr)) << "old format";
        EXPECT_FALSE(b.load("grassfield-menu-bridge-state 3\nboot other\nrun 0\n", boot, &why, nullptr)) << "another boot";
        EXPECT_FALSE(b.load("grassfield-menu-bridge-state 3\nboot boot-1\n", boot, &why, nullptr)) << "no run line";
        EXPECT_FALSE(b.load("", boot, &why, nullptr));
        EXPECT_EQ(b.size(), 0) << "nothing merged from a refused file";
    }
    QByteArray many;
    for (int i = 0; i < (penalty::kMaxIdle + penalty::kMaxRefused) * 2 + 1; ++i)
        many += "inflight 1 1 id:exe=/x" + QByteArray::number(i + 1) + "\n";
    EXPECT_FALSE(valid(many)) << "entry count is bounded";
    // One bad line among good ones: nothing at all is merged (an attacker cannot smuggle entries in).
    PenaltyBook b = book(c);
    EXPECT_FALSE(b.load("grassfield-menu-bridge-state 3\nboot boot-1\nrun 1\ndeny 1 5000 5 id:exe=/usr/bin/x\ndeny bad\n", boot, &why, nullptr));
    EXPECT_FALSE(b.has(QStringLiteral("id:exe=/usr/bin/x")));
}

TEST(PenaltyState, FileIsReadWithoutFollowingSymlinksAndBounded) {
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString path = dir.path() + QStringLiteral("/s.state");
    QByteArray    data;
    QString       why;
    EXPECT_FALSE(readStateFile(path, &data, &why));
    EXPECT_TRUE(why.isEmpty()) << "a missing file is not an error";

    ASSERT_TRUE(writeStateFile(path, QByteArray("hello\n")));
    EXPECT_TRUE(readStateFile(path, &data, &why));
    EXPECT_EQ(data, QByteArray("hello\n"));
    EXPECT_EQ(QFile::permissions(path) & (QFile::ReadGroup | QFile::WriteGroup | QFile::ReadOther | QFile::WriteOther), QFile::Permissions());

    // A symlink (even to a valid file) is refused.
    const QString link = dir.path() + QStringLiteral("/l.state");
    ASSERT_TRUE(QFile::link(path, link));
    EXPECT_FALSE(readStateFile(link, &data, &why));
    EXPECT_FALSE(why.isEmpty());

    // Writing over a symlink replaces the link, it does not write through it.
    ASSERT_TRUE(writeStateFile(link, QByteArray("replaced\n")));
    EXPECT_FALSE(QFileInfo(link).isSymLink());
    ASSERT_TRUE(readStateFile(path, &data, &why));
    EXPECT_EQ(data, QByteArray("hello\n")) << "the symlink's target was not written";

    // Oversized files are refused.
    QFile big(dir.path() + QStringLiteral("/big.state"));
    ASSERT_TRUE(big.open(QIODevice::WriteOnly));
    big.write(QByteArray(penalty::kMaxStateBytes + 1, 'x'));
    big.close();
    EXPECT_FALSE(readStateFile(big.fileName(), &data, &why));
    EXPECT_FALSE(why.isEmpty());
    // A FIFO is not a regular file (and must not block the bridge).
    const QString fifo = dir.path() + QStringLiteral("/f.state");
    ASSERT_EQ(::mkfifo(QFile::encodeName(fifo).constData(), 0600), 0);
    EXPECT_FALSE(readStateFile(fifo, &data, &why));
    EXPECT_FALSE(why.isEmpty());
}

// ---- com.canonical.AppMenu.Registrar registrations (ADR-0008 amendment 2026-10-25) -------------------------------

namespace {
    registrar::Answer call(registrar::Book& book, const char* member, const char* signature, const QVariantList& args, const char* sender = ":1.98") {
        return registrar::handle(book, QLatin1String(member), QLatin1String(signature), args, QLatin1String(sender));
    }

    QVariantList registerArgs(quint32 windowId, const char* path) {
        return {QVariant::fromValue(windowId), QVariant::fromValue(QDBusObjectPath(QLatin1String(path)))};
    }

    // A registration kept and settled (what the registrar object does registrar::kSettleMs after it arrived).
    void addSettled(registrar::Book& book, const char* sender, quint32 windowId, const char* path) {
        const quint64 seq = book.add(QLatin1String(sender), windowId, QLatin1String(path));
        ASSERT_GT(seq, 0U);
        ASSERT_TRUE(book.settle(QLatin1String(sender), windowId, seq));
    }
} // namespace

// What Electron does on window Show and Hide (global_menu_bar_registrar_x11.cc): kept, then forgotten.
TEST(Registrar, ElectronsRegisterAndUnregisterAreKept) {
    registrar::Book book;
    const auto      kept = call(book, "RegisterWindow", "uo", registerArgs(1, "/com/canonical/menu/1"));
    EXPECT_EQ(kept.kind, registrar::Answer::Kind::Reply);
    EXPECT_TRUE(kept.added);
    EXPECT_EQ(kept.windowId, 1U);
    EXPECT_GT(kept.seq, 0U) << "what the registrar object settles later";
    EXPECT_EQ(book.count(), 1);
    EXPECT_TRUE(book.holds(QStringLiteral(":1.98")));
    const auto gone = call(book, "UnregisterWindow", "u", {QVariant::fromValue(quint32{1})});
    EXPECT_EQ(gone.kind, registrar::Answer::Kind::Reply);
    EXPECT_TRUE(gone.removed);
    EXPECT_EQ(book.count(), 0);
    const auto again = call(book, "UnregisterWindow", "u", {QVariant::fromValue(quint32{1})});
    EXPECT_EQ(again.kind, registrar::Answer::Kind::Reply) << "unregistering an unknown window is harmless";
    EXPECT_FALSE(again.removed);
}

TEST(Registrar, MalformedCallsAndOtherMethods) {
    registrar::Book book;
    EXPECT_EQ(call(book, "RegisterWindow", "u", {QVariant::fromValue(quint32{1})}).error, QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs"));
    EXPECT_EQ(call(book, "RegisterWindow", "us", {QVariant::fromValue(quint32{1}), QStringLiteral("/a")}).error, QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs"));
    EXPECT_EQ(call(book, "RegisterWindow", "uo", registerArgs(1, "/a"), "org.example.Wellknown").error, QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs"))
        << "only a unique name can register: it is the connection the menu is read from";
    EXPECT_EQ(call(book, "GetMenuForWindow", "u", {QVariant::fromValue(quint32{1})}).error, QStringLiteral("com.canonical.AppMenu.Registrar.Error.NotFound"));
    EXPECT_EQ(call(book, "GetMenus", "", {}).error, QStringLiteral("org.freedesktop.DBus.Error.NotSupported"));
    EXPECT_EQ(call(book, "Frobnicate", "", {}).error, QStringLiteral("org.freedesktop.DBus.Error.UnknownMethod")) << "every call is answered";
    EXPECT_EQ(book.count(), 0);
}

TEST(Registrar, TheBookIsCappedWithoutEviction) {
    registrar::Book book;
    for (quint32 id = 1; id <= registrar::kMaxPerSender; ++id)
        EXPECT_TRUE(book.add(QStringLiteral(":1.5"), id, QStringLiteral("/m/%1").arg(id)));
    EXPECT_FALSE(book.add(QStringLiteral(":1.5"), 99, QStringLiteral("/m/99"))) << "16 per sender";
    EXPECT_TRUE(book.add(QStringLiteral(":1.5"), 3, QStringLiteral("/m/3b"))) << "re-registering the same window replaces it";
    EXPECT_EQ(call(book, "RegisterWindow", "uo", registerArgs(99, "/m/99"), ":1.5").error, QStringLiteral("org.freedesktop.DBus.Error.LimitsExceeded"));
    for (int s = 0; book.count() < registrar::kMaxTotal; ++s) {
        for (quint32 id = 1; id <= registrar::kMaxPerSender && book.count() < registrar::kMaxTotal; ++id)
            ASSERT_TRUE(book.add(QStringLiteral(":2.%1").arg(s), id, QStringLiteral("/m")));
    }
    EXPECT_FALSE(book.add(QStringLiteral(":3.1"), 1, QStringLiteral("/m"))) << "128 in all";
    EXPECT_EQ(book.count(), registrar::kMaxTotal);
    EXPECT_TRUE(book.senderGone(QStringLiteral(":1.5")));
    EXPECT_TRUE(book.add(QStringLiteral(":3.1"), 1, QStringLiteral("/m"))) << "a sender that left frees room";
}

// The PID -> windows link: a window is served the newest registration of a sender of its own process.
TEST(Registrar, TheNewestRegistrationOfTheWindowsProcessIsServed) {
    registrar::Book book;
    addSettled(book, ":1.98", 1, "/com/canonical/menu/1");
    EXPECT_FALSE(book.latestFor(4242).has_value()) << "the sender's process is not known yet: nothing is served";
    book.setPid(QStringLiteral(":1.98"), 4242);
    auto served = book.latestFor(4242);
    ASSERT_TRUE(served.has_value());
    EXPECT_EQ(served->sender, QStringLiteral(":1.98"));
    EXPECT_EQ(served->path, QStringLiteral("/com/canonical/menu/1"));
    addSettled(book, ":1.98", 2, "/com/canonical/menu/2");
    EXPECT_EQ(book.latestFor(4242)->path, QStringLiteral("/com/canonical/menu/2")) << "several menus of one process: the latest";
    addSettled(book, ":1.98", 1, "/com/canonical/menu/1");
    EXPECT_EQ(book.latestFor(4242)->path, QStringLiteral("/com/canonical/menu/1")) << "registered again: newest again";
    EXPECT_FALSE(book.latestFor(4243).has_value()) << "another process's window gets nothing";
    EXPECT_FALSE(book.latestFor(0).has_value());
    addSettled(book, ":1.120", 1, "/other");
    book.setPid(QStringLiteral(":1.120"), 5000);
    EXPECT_EQ(book.latestFor(4242)->sender, QStringLiteral(":1.98")) << "a registration of another process never serves this one";
    book.setPid(QStringLiteral(":9.9"), 4242);
    EXPECT_EQ(book.pidOf(QStringLiteral(":9.9")), 0) << "no pid is kept for a sender without registrations";
}

// Electron registers a window before its menu object answers (a GetLayout then fails with UnknownMethod and backs the app
// off): a registration is served once settled, the window keeping the previous settled menu of its process meanwhile.
TEST(Registrar, ARegistrationIsServedOnceSettled) {
    registrar::Book book;
    const quint64   first = book.add(QStringLiteral(":1.98"), 1, QStringLiteral("/com/canonical/menu/1"));
    book.setPid(QStringLiteral(":1.98"), 4242);
    EXPECT_FALSE(book.latestFor(4242).has_value()) << "kept, not settled: nothing is served yet";
    EXPECT_FALSE(book.settle(QStringLiteral(":1.98"), 2, first)) << "another window id";
    EXPECT_FALSE(book.settle(QStringLiteral(":1.99"), 1, first)) << "another sender";
    EXPECT_TRUE(book.settle(QStringLiteral(":1.98"), 1, first));
    EXPECT_FALSE(book.settle(QStringLiteral(":1.98"), 1, first)) << "settled once";
    ASSERT_TRUE(book.latestFor(4242).has_value());
    const quint64 second = book.add(QStringLiteral(":1.98"), 2, QStringLiteral("/com/canonical/menu/2"));
    EXPECT_EQ(book.latestFor(4242)->path, QStringLiteral("/com/canonical/menu/1")) << "a newer registration not settled yet: the previous one stays";
    const quint64 again = book.add(QStringLiteral(":1.98"), 2, QStringLiteral("/com/canonical/menu/2"));
    EXPECT_FALSE(book.settle(QStringLiteral(":1.98"), 2, second)) << "registered again meanwhile: the older settle is stale";
    EXPECT_TRUE(book.settle(QStringLiteral(":1.98"), 2, again));
    EXPECT_EQ(book.latestFor(4242)->path, QStringLiteral("/com/canonical/menu/2"));
    const quint64 replaced = book.add(QStringLiteral(":1.98"), 1, QStringLiteral("/com/canonical/menu/1"));
    EXPECT_GT(replaced, again);
    EXPECT_EQ(book.latestFor(4242)->path, QStringLiteral("/com/canonical/menu/2")) << "re-registering unsettles that registration";
    EXPECT_TRUE(book.remove(QStringLiteral(":1.98"), 1));
    EXPECT_FALSE(book.settle(QStringLiteral(":1.98"), 1, replaced)) << "gone before it settled";
}

// A pid can be reused by a new process after the registering one exited: its sender left the bus, its registrations
// are gone, and the new process's window is served nothing until it registers itself (the bridge also re-checks the
// sender's process at every open: the same check as open's spoofing rule).
TEST(Registrar, APidReusedAfterTheSenderLeftGetsNothing) {
    registrar::Book book;
    addSettled(book, ":1.98", 1, "/com/canonical/menu/1");
    book.setPid(QStringLiteral(":1.98"), 4242);
    ASSERT_TRUE(book.latestFor(4242).has_value());
    EXPECT_TRUE(book.senderGone(QStringLiteral(":1.98")));
    EXPECT_FALSE(book.latestFor(4242).has_value());
    EXPECT_EQ(book.pidOf(QStringLiteral(":1.98")), 0);
    EXPECT_FALSE(book.senderGone(QStringLiteral(":1.98")));
}

// A process in another pid namespace (a Flatpak app, a nested sandbox) is never served a registrar menu.
// Review of 9ba1d40: the same namespace, not one as deep (two sandboxes side by side have the same depth).
TEST(Registrar, PidNamespaceIdentityFromTheNsLink) {
    EXPECT_EQ(pidNamespaceInode("pid:[4026531836]"), 4026531836ULL);
    EXPECT_EQ(pidNamespaceInode("pid:[1]"), 1ULL);
    EXPECT_EQ(pidNamespaceInode("pid:[]"), 0ULL);
    EXPECT_EQ(pidNamespaceInode("pid:[12x]"), 0ULL) << "malformed: refused";
    EXPECT_EQ(pidNamespaceInode("net:[4026531840]"), 0ULL) << "another namespace type";
    EXPECT_EQ(pidNamespaceInode("pid:[4026531836"), 0ULL);
    EXPECT_EQ(pidNamespaceInode("pid:[-4]"), 0ULL);
    EXPECT_EQ(pidNamespaceInode(""), 0ULL);
    EXPECT_TRUE(inBridgePidNamespace(::getpid())) << "this process is in its own namespace";
    EXPECT_FALSE(inBridgePidNamespace(0));
    EXPECT_FALSE(inBridgePidNamespace(-1));
    EXPECT_FALSE(inBridgePidNamespace(2147483646)) << "no such process: refused";
}

// ---- start-up guards -------------------------------------------------------------------------------------------

// The run mode (ADR-0019) against the vectors the shell (shell/lib/RunMode.js), the apps and the compositor plugin are
// held to (tests/fixtures/run-mode-vectors.json; a key missing from "env" is an unset variable, read as empty).
TEST(Safety, RunModeFollowsTheSharedVectors) {
    QFile file(QStringLiteral(GRASSFIELD_RUN_MODE_VECTORS));
    ASSERT_TRUE(file.open(QIODevice::ReadOnly)) << GRASSFIELD_RUN_MODE_VECTORS;
    QJsonParseError error{};
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &error);
    ASSERT_EQ(error.error, QJsonParseError::NoError) << error.errorString().toStdString();
    const QJsonArray modes = doc.object().value(QStringLiteral("modes")).toArray();
    ASSERT_GE(modes.size(), 10) << "the vectors look truncated";
    for (const QJsonValue& value : modes) {
        const QJsonObject mode = value.toObject();
        const QJsonObject env  = mode.value(QStringLiteral("env")).toObject();
        const std::string name = mode.value(QStringLiteral("name")).toString().toStdString();
        ASSERT_TRUE(mode.value(QStringLiteral("dev")).isBool() && mode.value(QStringLiteral("session")).isBool()) << name;
        const QByteArray dev     = env.value(QStringLiteral("GRASSFIELD_DEV")).toString().toUtf8();
        const QByteArray session = env.value(QStringLiteral("GRASSFIELD_SESSION")).toString().toUtf8();
        EXPECT_EQ(devRun(dev, session), mode.value(QStringLiteral("dev")).toBool()) << name;
        EXPECT_EQ(sessionRun(session), mode.value(QStringLiteral("session")).toBool()) << name;
    }
}

// The real-session defect M7 fixes: a GRASSFIELD_DEV=1 that leaked into the Grassfield session made the bridge take the
// development branch, refuse the session's default bus, and global menus stopped. It is a session run now.
TEST(Safety, ALeakedDevInAGrassfieldSessionIsASessionRun) {
    EXPECT_FALSE(devRun("1", "1"));
    EXPECT_TRUE(sessionRun("1"));
    EXPECT_TRUE(devRun("1", QByteArray())) << "a development run: GRASSFIELD_SESSION unset (devenv.sh unsets it)";
    EXPECT_TRUE(devRun("1", "0"));
    EXPECT_FALSE(devRun(QByteArray(), QByteArray()));
    EXPECT_FALSE(devRun("true", QByteArray())) << "only the exact string \"1\"";
    EXPECT_FALSE(sessionRun("true"));
}

TEST(Safety, DefaultSessionBusIsDetected) {
    EXPECT_TRUE(isDefaultSessionBus(QString(), 1000));
    EXPECT_TRUE(isDefaultSessionBus(QStringLiteral("unix:path=/run/user/1000/bus"), 1000));
    EXPECT_TRUE(isDefaultSessionBus(QStringLiteral("unix:path=/run/user/1000//bus,guid=0123"), 1000));
    EXPECT_TRUE(isDefaultSessionBus(QStringLiteral("unix:runtime=yes"), 1000));
    EXPECT_TRUE(isDefaultSessionBus(QStringLiteral("unix:tmpdir=/tmp;unix:path=/run/user/1000/bus"), 1000));
    EXPECT_TRUE(isDefaultSessionBus(QStringLiteral("autolaunch:"), 1000));
    EXPECT_TRUE(isDefaultSessionBus(QStringLiteral("garbage"), 1000));
    EXPECT_FALSE(isDefaultSessionBus(QStringLiteral("unix:path=/tmp/dbus-AbCdEf,guid=0123"), 1000));
    EXPECT_FALSE(isDefaultSessionBus(QStringLiteral("unix:abstract=/tmp/dbus-XYZ,guid=1"), 1000));
    EXPECT_FALSE(isDefaultSessionBus(QStringLiteral("unix:path=/run/user/1001/bus"), 1000)); // another user's path is not ours
}

TEST(Safety, SocketPath) {
    EXPECT_EQ(socketPath(QString(), QStringLiteral("/run/user/1000")), QStringLiteral("/run/user/1000/grassfield/menu-bridge.sock"));
    EXPECT_EQ(socketPath(QStringLiteral("/x/.dev/run/menu-bridge.sock"), QStringLiteral("/run/user/1000")), QStringLiteral("/x/.dev/run/menu-bridge.sock"));
    EXPECT_EQ(socketPath(QStringLiteral("relative.sock"), QStringLiteral("/run/user/1000")), QString());
    EXPECT_EQ(socketPath(QString(), QString()), QString());
    EXPECT_TRUE(fitsSocketPath(QStringLiteral("/run/user/1000/grassfield/menu-bridge.sock")));
    EXPECT_FALSE(fitsSocketPath(QStringLiteral("/") + QString(120, u'a')));
    EXPECT_FALSE(fitsSocketPath(QString()));
}

TEST(Safety, SocketDirectoryIsPrivate) {
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString sock = dir.path() + QStringLiteral("/grassfield/menu-bridge.sock");
    EXPECT_EQ(prepareSocketDirectory(sock), QString());
    EXPECT_EQ(QFile::permissions(dir.path() + QStringLiteral("/grassfield")) & (QFile::ReadGroup | QFile::WriteGroup | QFile::ExeGroup | QFile::ReadOther | QFile::WriteOther | QFile::ExeOther),
              QFile::Permissions());
    // A symlink in place of the directory is refused.
    const QString linked = dir.path() + QStringLiteral("/link");
    ASSERT_TRUE(QFile::link(dir.path() + QStringLiteral("/grassfield"), linked));
    EXPECT_NE(prepareSocketDirectory(linked + QStringLiteral("/menu-bridge.sock")), QString());
}

// ---- LauncherEntry (ADR-0018): validation, limits, coalescing, sender cleanup ------------------------------------

namespace {
    using namespace gf::menubridge::launcher;

    QVariantMap props(std::initializer_list<std::pair<QString, QVariant>> list) {
        QVariantMap m;
        for (const auto& [k, v] : list)
            m.insert(k, v);
        return m;
    }

    QString uri(const QString& id) {
        return QStringLiteral("application://") + id + QStringLiteral(".desktop");
    }

    QString K(const char* name) {
        return QString::fromLatin1(name);
    }

    const QString kA = QStringLiteral(":1.10");
    const QString kB = QStringLiteral(":1.11");
} // namespace

TEST(LauncherUri, AcceptsADesktopId) {
    EXPECT_EQ(appFromUri(QStringLiteral("application://firefox.desktop")), QStringLiteral("firefox"));
    EXPECT_EQ(appFromUri(QStringLiteral("application://org.mozilla.Firefox-esr_2.desktop")), QStringLiteral("org.mozilla.Firefox-esr_2"));
    EXPECT_EQ(appFromUri(uri(QString(255, u'a'))), QString(255, u'a'));
}

TEST(LauncherUri, RefusesEverythingElse) {
    for (const char* bad : {"", "firefox.desktop", "application://.desktop", "application://firefox", "application:/firefox.desktop", "Application://firefox.desktop",
                            "application://fire fox.desktop", "application://a/b.desktop", "application://a:b.desktop", "application://fire\nfox.desktop",
                            "application://f\xc3\xa9.desktop", "application://firefox.desktop ", "application://%66irefox.desktop", "file://firefox.desktop",
                            "application://x.desktop.bak", "application://"})
        EXPECT_FALSE(appFromUri(QString::fromUtf8(bad)).has_value()) << bad;
    EXPECT_FALSE(appFromUri(uri(QString(256, u'a'))).has_value());
    QString withNul = uri(QStringLiteral("a"));
    withNul.insert(14, QChar(0));
    EXPECT_FALSE(appFromUri(withNul).has_value());
}

TEST(LauncherParse, CountIsClampedAndTypedStrictly) {
    EXPECT_EQ(parse(uri(K("a")), props({{K("count"), qlonglong(7)}})).properties.count, 7);
    EXPECT_EQ(parse(uri(K("a")), props({{K("count"), qlonglong(-5)}})).properties.count, 0);
    EXPECT_EQ(parse(uri(K("a")), props({{K("count"), qlonglong(1) << 40}})).properties.count, kMaxCount);
    for (const QVariant& wrong : {QVariant(5), QVariant(5.0), QVariant(QStringLiteral("5")), QVariant(true), QVariant(quint64(5))}) {
        const Parsed p = parse(uri(K("a")), props({{K("count"), wrong}}));
        EXPECT_TRUE(p.valid);
        EXPECT_FALSE(p.properties.count.has_value());
        EXPECT_TRUE(p.dropped);
    }
}

TEST(LauncherParse, ProgressMustBeFiniteAndIsClamped) {
    auto progress = [](QVariant v) { return parse(uri(K("a")), props({{K("progress"), std::move(v)}})); };
    EXPECT_DOUBLE_EQ(*progress(0.25).properties.progress, 0.25);
    EXPECT_DOUBLE_EQ(*progress(7.0).properties.progress, 1.0);
    EXPECT_DOUBLE_EQ(*progress(-3.0).properties.progress, 0.0);
    for (const QVariant& bad : {QVariant(std::numeric_limits<double>::quiet_NaN()), QVariant(std::numeric_limits<double>::infinity()), QVariant(-std::numeric_limits<double>::infinity()),
                                QVariant(1), QVariant(qlonglong(1)), QVariant(QStringLiteral("0.5"))}) {
        const Parsed p = progress(bad);
        EXPECT_FALSE(p.properties.progress.has_value());
        EXPECT_TRUE(p.dropped);
    }
}

TEST(LauncherParse, BooleansAndUnknownProperties) {
    const Parsed p = parse(uri(K("a")), props({{K("urgent"), true},
                                               {K("count-visible"), false},
                                               {K("progress-visible"), true},
                                               {K("quicklist"), QStringLiteral("/com/x/Menu")},
                                               {K("whatever"), 1}}));
    EXPECT_TRUE(p.valid);
    EXPECT_FALSE(p.dropped);
    EXPECT_EQ(p.properties.urgent, true);
    EXPECT_EQ(p.properties.countVisible, false);
    EXPECT_EQ(p.properties.progressVisible, true);
    const Parsed wrong = parse(uri(K("a")), props({{K("urgent"), 1}, {K("count-visible"), QStringLiteral("no")}}));
    EXPECT_TRUE(wrong.dropped);
    EXPECT_TRUE(wrong.properties.empty());
}

TEST(LauncherParse, AnAbsurdMapIsNotRead) {
    QVariantMap big;
    for (int i = 0; i <= kMaxProperties; ++i)
        big.insert(QStringLiteral("k%1").arg(i), i);
    big.insert(K("count"), qlonglong(3));
    const Parsed p = parse(uri(K("a")), big);
    EXPECT_TRUE(p.valid);
    EXPECT_TRUE(p.dropped);
    EXPECT_TRUE(p.properties.empty());
}

TEST(LauncherBook, ForwardsCountProgressUrgent) {
    Book b;
    auto r = b.submit(kA, uri(K("app")), props({{K("count"), qlonglong(5)}, {K("count-visible"), true}}), 0);
    ASSERT_EQ(r.forward.size(), 1u);
    EXPECT_EQ(r.forward[0], (Update{.app = K("app"), .count = 5, .progress = std::nullopt, .urgent = std::nullopt}));
    EXPECT_FALSE(r.malformed);
    r = b.submit(kA, uri(K("app")), props({{K("progress"), 0.5}, {K("progress-visible"), true}, {K("urgent"), true}}), 10);
    ASSERT_EQ(r.forward.size(), 1u);
    EXPECT_EQ(r.forward[0], (Update{.app = K("app"), .count = std::nullopt, .progress = 0.5, .urgent = true}));
}

TEST(LauncherBook, HiddenValuesAreForwardedAsZeroAndMinusOne) {
    Book b;
    b.submit(kA, uri(K("app")), props({{K("count"), qlonglong(5)}, {K("progress"), 0.2}}), 0);
    auto r = b.submit(kA, uri(K("app")), props({{K("count-visible"), false}}), 10);
    ASSERT_EQ(r.forward.size(), 1u);
    EXPECT_EQ(r.forward[0].count, 0);
    EXPECT_FALSE(r.forward[0].progress.has_value());
    r = b.submit(kA, uri(K("app")), props({{K("progress-visible"), false}}), 20);
    ASSERT_EQ(r.forward.size(), 1u);
    EXPECT_EQ(r.forward[0].progress, -1.0);
    // Visible again: the value the app sent before comes back.
    r = b.submit(kA, uri(K("app")), props({{K("count-visible"), true}, {K("progress-visible"), true}}), 30);
    ASSERT_EQ(r.forward.size(), 1u);
    EXPECT_EQ(r.forward[0].count, 5);
    EXPECT_EQ(r.forward[0].progress, 0.2);
    // count-visible:false in the same update as a count wins.
    r = b.submit(kA, uri(K("other")), props({{K("count"), qlonglong(9)}, {K("count-visible"), false}}), 40);
    EXPECT_EQ(r.forward.at(0).count, 0);
}

TEST(LauncherBook, NothingToSayIsNotForwardedNorTracked) {
    Book b;
    EXPECT_TRUE(b.submit(kA, uri(K("app")), props({{K("quicklist"), QStringLiteral("x")}}), 0).forward.empty());
    EXPECT_TRUE(b.submit(kA, uri(K("app")), props({{K("count-visible"), true}}), 1).forward.empty());
    EXPECT_EQ(b.apps(), 0);
}

TEST(LauncherBook, MalformedInputIsReportedAndNotForwarded) {
    Book b;
    auto r = b.submit(kA, QStringLiteral("application://bad/app.desktop"), props({{K("count"), qlonglong(5)}}), 0);
    EXPECT_TRUE(r.malformed);
    EXPECT_TRUE(r.forward.empty());
    r = b.submit(kA, QString(), {}, 1); // a signal with the wrong signature reaches the Book with no uri
    EXPECT_TRUE(r.malformed);
    // A wrong type is dropped and punished, the rest of the update goes through.
    r = b.submit(kA, uri(K("app")), props({{K("count"), QStringLiteral("5")}, {K("urgent"), true}}), 2);
    EXPECT_TRUE(r.malformed);
    ASSERT_EQ(r.forward.size(), 1u);
    EXPECT_EQ(r.forward[0].urgent, true);
    EXPECT_FALSE(r.forward[0].count.has_value());
    EXPECT_EQ(b.apps(), 1);
}

TEST(LauncherBook, AtMost64Apps) {
    Book b;
    for (int i = 0; i < kMaxApps; ++i)
        EXPECT_EQ(b.submit(QStringLiteral(":1.%1").arg(100 + i / 5), uri(QStringLiteral("app%1").arg(i)), props({{K("count"), qlonglong(1)}}), i * 1000LL).forward.size(), 1u);
    EXPECT_EQ(b.apps(), kMaxApps);
    const auto r = b.submit(kA, uri(K("one-too-many")), props({{K("count"), qlonglong(1)}}), 70000);
    EXPECT_TRUE(r.dropped);
    EXPECT_TRUE(r.forward.empty());
    EXPECT_EQ(b.apps(), kMaxApps);
    // A tracked app still updates.
    EXPECT_EQ(b.submit(kA, uri(K("app0")), props({{K("count"), qlonglong(2)}}), 80000).forward.size(), 1u);
}

TEST(LauncherBook, AtMost64Senders) {
    Book b;
    for (int i = 0; i < kMaxSenders; ++i)
        EXPECT_FALSE(b.submit(QStringLiteral(":1.%1").arg(i), uri(QStringLiteral("a%1").arg(i % 8)), props({{K("count"), qlonglong(1)}}), 0).dropped);
    EXPECT_EQ(b.senders(), kMaxSenders);
    EXPECT_TRUE(b.submit(QStringLiteral(":1.999"), uri(K("x")), props({{K("count"), qlonglong(1)}}), 0).dropped);
}

TEST(LauncherBook, TwentyUpdatesPerSecondPerSenderThenCoalescing) {
    Book b;
    int  forwarded = 0;
    for (int i = 0; i < 100; ++i)
        forwarded += static_cast<int>(b.submit(kA, uri(K("app")), props({{K("count"), qlonglong(i)}}), i /* ms */).forward.size());
    EXPECT_EQ(forwarded, kMaxPerSecond);
    EXPECT_TRUE(b.hasPending());
    // Nothing goes out while the budget is used up, the last state per app goes out once it is back.
    EXPECT_TRUE(b.flush(500).empty());
    const auto out = b.flush(1000 + 19);
    ASSERT_EQ(out.size(), 1u);
    EXPECT_EQ(out[0].app, K("app"));
    EXPECT_EQ(out[0].count, 99);
    EXPECT_FALSE(b.hasPending());
    // Another sender is not slowed down by the flood.
    EXPECT_EQ(b.submit(kB, uri(K("calm")), props({{K("count"), qlonglong(1)}}), 50).forward.size(), 1u);
}

TEST(LauncherBook, CoalescingMergesPropertiesLastWins) {
    Book b;
    for (int i = 0; i < kMaxPerSecond; ++i)
        b.submit(kA, uri(K("app")), props({{K("count"), qlonglong(i)}}), 0);
    b.submit(kA, uri(K("app")), props({{K("count"), qlonglong(50)}, {K("urgent"), true}}), 10);
    b.submit(kA, uri(K("app")), props({{K("progress"), 0.5}}), 20);
    b.submit(kA, uri(K("app")), props({{K("count"), qlonglong(60)}}), 30);
    const auto out = b.flush(1000);
    ASSERT_EQ(out.size(), 1u);
    EXPECT_EQ(out[0], (Update{.app = K("app"), .count = 60, .progress = 0.5, .urgent = true}));
}

TEST(LauncherBook, ExcessMalformedInputIsNotKept) {
    Book b;
    for (int i = 0; i < kMaxPerSecond; ++i)
        b.submit(kA, uri(K("app")), props({{K("count"), qlonglong(1)}}), 0);
    const auto r = b.submit(kA, QStringLiteral("junk"), {}, 5);
    EXPECT_TRUE(r.throttled);
    EXPECT_FALSE(r.malformed);
    EXPECT_FALSE(b.hasPending());
}

TEST(LauncherBook, ASenderThatLeavesClearsItsApps) {
    Book b;
    b.submit(kA, uri(K("one")), props({{K("count"), qlonglong(1)}}), 0);
    b.submit(kA, uri(K("two")), props({{K("progress"), 0.5}}), 0);
    b.submit(kB, uri(K("three")), props({{K("count"), qlonglong(3)}}), 0);
    const auto gone = b.senderGone(kA);
    ASSERT_EQ(gone.size(), 2u);
    EXPECT_EQ(gone[0].app, K("one"));
    EXPECT_EQ(gone[1].app, K("two"));
    for (const Update& u : gone)
        EXPECT_TRUE(u.forget());
    EXPECT_EQ(b.apps(), 1);
    EXPECT_EQ(b.senders(), 1);
    EXPECT_TRUE(b.senderGone(kA).empty());
    // The state of the survivor is still there, and a late flush sends nothing for the departed sender's apps.
    ASSERT_EQ(b.snapshot().size(), 1u);
    EXPECT_EQ(b.snapshot()[0].app, K("three"));
    EXPECT_TRUE(b.flush(5000).empty());
}

TEST(LauncherBook, PendingStateOfADepartedSenderIsDropped) {
    Book b;
    for (int i = 0; i < kMaxPerSecond; ++i)
        b.submit(kA, uri(K("app")), props({{K("count"), qlonglong(i)}}), 0);
    b.submit(kA, uri(K("app")), props({{K("count"), qlonglong(77)}}), 1);
    ASSERT_TRUE(b.hasPending());
    b.senderGone(kA);
    EXPECT_FALSE(b.hasPending());
    EXPECT_TRUE(b.flush(5000).empty());
}

TEST(LauncherBook, SnapshotReplaysTheCurrentState) {
    Book b;
    b.submit(kA, uri(K("b")), props({{K("count"), qlonglong(4)}, {K("progress"), 0.3}, {K("urgent"), true}}), 0);
    b.submit(kA, uri(K("a")), props({{K("count"), qlonglong(4)}, {K("count-visible"), false}}), 1);
    const auto snap = b.snapshot();
    ASSERT_EQ(snap.size(), 2u);
    EXPECT_EQ(snap[0], (Update{.app = K("a"), .count = 0, .progress = std::nullopt, .urgent = std::nullopt}));
    EXPECT_EQ(snap[1], (Update{.app = K("b"), .count = 4, .progress = 0.3, .urgent = true}));
}

TEST(LauncherProtocol, MessageShape) {
    const QJsonObject full = QJsonDocument::fromJson(launcherMessage(K("app"), 5, 0.5, true)).object();
    EXPECT_EQ(full.value(K("type")).toString(), K("launcher"));
    EXPECT_EQ(full.value(K("app")).toString(), K("app"));
    EXPECT_EQ(full.value(K("count")).toInt(), 5);
    EXPECT_DOUBLE_EQ(full.value(K("progress")).toDouble(), 0.5);
    EXPECT_TRUE(full.value(K("urgent")).toBool());
    const QByteArray raw = launcherMessage(K("app"), std::nullopt, -1.0, false);
    EXPECT_TRUE(raw.endsWith('\n'));
    EXPECT_EQ(raw.count('\n'), 1);
    const QJsonObject partial = QJsonDocument::fromJson(raw).object();
    EXPECT_TRUE(partial.value(K("count")).isNull());
    EXPECT_TRUE(partial.contains(K("count")));
    EXPECT_DOUBLE_EQ(partial.value(K("progress")).toDouble(), -1.0);
    EXPECT_FALSE(partial.value(K("urgent")).toBool(true));
}

// ---- diagnostics interface -------------------------------------------------------------------------------------

TEST(Diagnostics, CodeMatchesTheVersionedXml) {
    QFile file(QStringLiteral(GRASSFIELD_MENU_BRIDGE_DBUS_XML));
    ASSERT_TRUE(file.open(QIODevice::ReadOnly));
    const QString xml = QString::fromUtf8(file.readAll());
    EXPECT_TRUE(xml.contains(diagnosticsInterfaceXml())) << "update DBusObjects.cpp and dbus/org.grassfield.MenuBridge1.xml together";
    EXPECT_TRUE(xml.contains(QStringLiteral("org.grassfield.MenuBridge1")));
}

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
