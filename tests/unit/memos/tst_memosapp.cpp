// Grassfield Memos' backend (ADR-0051): the memos handed to the windows, a new memo near the front one, changes saved after
// the debounce with the positions Hyprland reports (a fake here), the tag, the refusal of a newer store.
#include "memosapp.h"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>

#include <gtest/gtest.h>

using namespace memos;

namespace {

struct Fixture
{
    QTemporaryDir config;
    QTemporaryDir data;
    QHash<QString, Frame> frames;
    int reads = 0;
    Fixture() { qputenv("GRASSFIELD_CONFIG_HOME", config.path().toUtf8()); }
    std::function<QHash<QString, Frame>()> reader()
    {
        return [this] {
            ++reads;
            return frames;
        };
    }
    QJsonArray written() const
    {
        QFile f(data.path() + QStringLiteral("/memos.json"));
        return f.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(f.readAll()).object().value(QStringLiteral("memos")).toArray() : QJsonArray();
    }
};

bool waitFor(const std::function<bool()> &done, int ms = 3000)
{
    QElapsedTimer t;
    t.start();
    while (!done() && t.elapsed() < ms)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    return done();
}

} // namespace

TEST(MemosApp, OpensCreatesNearTheFrontMemoAndSavesAfterTheDebounce)
{
    Fixture fx;
    MemosApp app(fx.data.path(), fx.reader());
    EXPECT_TRUE(app.open(240, 200).isEmpty());
    EXPECT_EQ(app.refusal(), QString());

    const QVariantMap first = app.createMemo(QString(), 240, 200, 22);
    const QString a = first.value(QStringLiteral("id")).toString();
    EXPECT_TRUE(isId(a));
    EXPECT_EQ(first.value(QStringLiteral("color")).toString(), QStringLiteral("yellow"));
    EXPECT_EQ(first.value(QStringLiteral("tag")).toString(), QStringLiteral("memo:") + a); // no position known yet

    // Hyprland reports where the first one is: the next one opens down and to the right of it.
    fx.frames.insert(a, Frame{300, 120, 240, 200});
    const QVariantMap second = app.createMemo(a, 240, 200, 22);
    const QString b = second.value(QStringLiteral("id")).toString();
    EXPECT_EQ(second.value(QStringLiteral("tag")).toString(), QStringLiteral("memo:%1@322,142").arg(b));

    app.update(a, {{QStringLiteral("html"), QStringLiteral("<p>milk</p>")}, {QStringLiteral("color"), QStringLiteral("green")},
                   {QStringLiteral("width"), 10}, {QStringLiteral("floating"), true}, {QStringLiteral("unknown"), 1}});
    app.update(b, {{QStringLiteral("color"), QStringLiteral("magenta")}});
    EXPECT_EQ(app.tagFor(a), QStringLiteral("memo:%1@300,120").arg(a));
    // Nothing written before the debounce...
    EXPECT_TRUE(fx.written().isEmpty());
    int saved = 0;
    QObject::connect(&app, &MemosApp::saved, [&saved](bool ok) { saved += ok ? 1 : 0; });
    ASSERT_TRUE(waitFor([&] { return saved > 0; }));
    const QJsonArray list = fx.written();
    ASSERT_EQ(list.size(), 2);
    const QJsonObject wa = list.at(0).toObject();
    EXPECT_EQ(wa.value(QStringLiteral("id")).toString(), a);
    EXPECT_EQ(wa.value(QStringLiteral("color")).toString(), QStringLiteral("green"));
    EXPECT_EQ(wa.value(QStringLiteral("html")).toString(), QStringLiteral("<p>milk</p>"));
    EXPECT_EQ(wa.value(QStringLiteral("width")).toInt(), kMinSide);
    EXPECT_FALSE(wa.contains(QStringLiteral("floating"))); // Float on Top is gone (ADR-0051 D-6): the key is ignored and not written
    EXPECT_EQ(wa.value(QStringLiteral("x")).toInt(), 300);
    EXPECT_FALSE(wa.contains(QStringLiteral("unknown")));
    EXPECT_EQ(list.at(1).toObject().value(QStringLiteral("color")).toString(), QStringLiteral("yellow")); // magenta refused

    // Moved, then quit: the save reads the positions again.
    fx.frames.insert(a, Frame{10, 20, 240, 200});
    fx.frames.insert(b, Frame{-5, 900, 240, 200});
    ASSERT_TRUE(app.saveNow());
    EXPECT_EQ(fx.written().at(0).toObject().value(QStringLiteral("y")).toInt(), 20);
    EXPECT_EQ(fx.written().at(1).toObject().value(QStringLiteral("x")).toInt(), -5);

    // A window the compositor does not report (minimized elsewhere, no answer) keeps its last position.
    fx.frames.clear();
    app.remove(b);
    ASSERT_TRUE(app.saveNow());
    ASSERT_EQ(fx.written().size(), 1);
    EXPECT_EQ(fx.written().at(0).toObject().value(QStringLiteral("x")).toInt(), 10);
}

TEST(MemosApp, StoredMemosComeBackCleanedInOrder)
{
    Fixture fx;
    {
        MemosApp app(fx.data.path(), fx.reader());
        app.open(240, 200);
        const QString a = app.createMemo(QString(), 250, 210, 22).value(QStringLiteral("id")).toString();
        app.createMemo(QString(), 240, 200, 22);
        app.update(a, {{QStringLiteral("html"), QStringLiteral("<p>hi <img src=\"http://x.invalid/p.png\"></p>")},
                       {QStringLiteral("collapsed"), true}, {QStringLiteral("translucent"), true}});
        ASSERT_TRUE(app.saveNow());
    }
    MemosApp again(fx.data.path(), fx.reader());
    const QVariantList memos = again.open(240, 200);
    ASSERT_EQ(memos.size(), 2);
    const QVariantMap first = memos.at(0).toMap();
    EXPECT_EQ(first.value(QStringLiteral("width")).toInt(), 250);
    EXPECT_TRUE(first.value(QStringLiteral("collapsed")).toBool());
    EXPECT_TRUE(first.value(QStringLiteral("translucent")).toBool());
    EXPECT_FALSE(first.value(QStringLiteral("html")).toString().contains(QStringLiteral("<img")));
    EXPECT_EQ(again.firstLine(first.value(QStringLiteral("html")).toString()), QStringLiteral("hi"));
}

TEST(MemosApp, ANewerStoreOpensNothingAndWritesNothing)
{
    Fixture fx;
    const QByteArray newer = QByteArrayLiteral("{\"schema\": 5, \"memos\": []}");
    {
        QFile f(fx.data.path() + QStringLiteral("/memos.json"));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(newer);
    }
    MemosApp app(fx.data.path(), fx.reader());
    EXPECT_TRUE(app.open(240, 200).isEmpty());
    EXPECT_EQ(app.refusal(), QStringLiteral("newer"));
    EXPECT_TRUE(app.createMemo(QString(), 240, 200, 22).isEmpty());
    EXPECT_FALSE(app.saveNow());
    QFile f(fx.data.path() + QStringLiteral("/memos.json"));
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    EXPECT_EQ(f.readAll(), newer);
}

TEST(MemosApp, RemoveIsSavedAfterTheDebounce)
{
    Fixture fx;
    MemosApp app(fx.data.path(), fx.reader());
    app.open(240, 200);
    const QString a = app.createMemo(QString(), 240, 200, 22).value(QStringLiteral("id")).toString();
    ASSERT_TRUE(app.saveNow());
    ASSERT_EQ(fx.written().size(), 1);
    int saved = 0;
    QObject::connect(&app, &MemosApp::saved, [&saved](bool ok) { saved += ok ? 1 : 0; });
    app.remove(a);
    ASSERT_TRUE(waitFor([&] { return saved > 0; }));
    EXPECT_TRUE(fx.written().isEmpty());
}

TEST(MemosApp, PendingChangesAreWrittenWhenTheAppGoes)
{
    Fixture fx;
    {
        MemosApp app(fx.data.path(), fx.reader());
        app.open(240, 200);
        app.createMemo(QString(), 240, 200, 22);
        // Destroyed before the debounce: the destructor writes.
    }
    EXPECT_EQ(fx.written().size(), 1);
}

TEST(MemosApp, SaveNowLetsTheWindowsPushTheirTextFirst)
{
    // Review of the memos slice: text typed in the window's last 300 ms was still in the window when Quit or SIGTERM saved.
    // saveNow() asks the windows first (aboutToSave, a direct call), then writes what they pushed.
    Fixture fx;
    MemosApp app(fx.data.path(), fx.reader());
    app.open(240, 200);
    const QString a = app.createMemo(QString(), 240, 200, 22).value(QStringLiteral("id")).toString();
    QObject::connect(&app, &MemosApp::aboutToSave, [&] { app.update(a, {{QStringLiteral("html"), QStringLiteral("<p>late</p>")}}); });
    ASSERT_TRUE(app.saveNow());
    EXPECT_EQ(fx.written().at(0).toObject().value(QStringLiteral("html")).toString(), QStringLiteral("<p>late</p>"));
}
