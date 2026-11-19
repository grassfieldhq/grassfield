// Unit tests for apps/files/src/imageproviders.h: the threading contract of the two icon providers (round 3 review of the
// Applications location). image://icon (theme names) must be a synchronous Pixmap provider: an asynchronous one is called on
// Qt's image-loader thread for EVERY request and its QIcon use raced with the GUI thread's QIcon::hasThemeIcon (FolderModel,
// PlacesModel) - a segfault in 4 of 4 stress runs. Only image://appicon (absolute paths) may be asynchronous, and it never
// uses QIcon off the GUI thread. Run with QT_QPA_PLATFORM=offscreen (tst_appicons.cpp's environment sets it).
#include <gtest/gtest.h>

#include <QBuffer>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QIcon>
#include <QImage>
#include <QQuickImageProvider>
#include <QEventLoop>
#include <QTimer>
#include <QTemporaryDir>

#include <QProcess>
#include <QThread>

#include <functional>
#include <memory>
#include <sys/stat.h>
#include <unistd.h>

#include "appicons.h"
#include "imageproviders.h"

namespace
{
// The icon decoder child is this very binary (AppIcons::loadIsolated runs QCoreApplication::applicationFilePath() with
// "--decode-icon <w> <h>"): answer it before gtest's main starts.
const int decodeChildHook = [] {
    QFile cmdline(QStringLiteral("/proc/self/cmdline"));
    if (!cmdline.open(QIODevice::ReadOnly))
        return 0;
    QList<QByteArray> parts = cmdline.readAll().split('\0');
    if (!parts.isEmpty() && parts.last().isEmpty())
        parts.removeLast();
    std::vector<char *> argv;
    for (QByteArray &a : parts)
        argv.push_back(a.data());
    argv.push_back(nullptr);
    if (!AppIcons::isDecodeChildInvocation(int(parts.size()), argv.data()))
        return 0;
    ::_exit(AppIcons::decodeChildMain(int(parts.size()), argv.data()));
}();

QString writePng(const QString &path)
{
    QImage image(16, 16, QImage::Format_ARGB32);
    image.fill(Qt::green);
    image.save(path, "PNG");
    return path;
}

// Records finished() from the moment it is made (the signal must not be missed while other events are processed).
class Spy
{
public:
    explicit Spy(QQuickImageResponse *response)
    {
        QObject::connect(response, &QQuickImageResponse::finished, response, [this] {
            m_done = true;
            m_loop.quit();
        });
    }
    bool wait(int ms = 5000)
    {
        if (!m_done) {
            QTimer::singleShot(ms, &m_loop, &QEventLoop::quit);
            m_loop.exec();
        }
        return m_done;
    }

private:
    bool m_done = false;
    QEventLoop m_loop;
};
} // namespace

// The theme icons: asynchronous for QML (no rasterising on the frame that creates a delegate), but QIcon is only touched on the
// GUI thread (its theme cache has no lock): requests made from another thread, as Qt's image loader makes them, are rendered
// on the GUI thread, a few milliseconds per turn, and every one is finished, a cancelled one too.
TEST(ImageProviders, TheThemeProviderRendersOnTheGuiThreadOnly)
{
    IconProvider theme;
    EXPECT_EQ(theme.imageType(), QQuickImageProvider::ImageResponse);
    AppIconProvider files;
    EXPECT_EQ(files.imageType(), QQuickImageProvider::ImageResponse);

    // Asked from another thread with an event loop of its own, as QQuickPixmapReader asks (the responses live there).
    QThread loader;
    auto *context = new QObject;
    context->moveToThread(&loader);
    loader.start();
    std::vector<QQuickImageResponse *> responses;
    std::vector<std::unique_ptr<Spy>> spies;
    QMetaObject::invokeMethod(
        context,
        [&] {
            for (int i = 0; i < 40; ++i)
                responses.push_back(theme.requestImageResponse(i % 2 ? QStringLiteral("text-x-generic") : QStringLiteral("folder"), QSize(32, 32)));
            responses.back()->cancel();
        },
        Qt::BlockingQueuedConnection);
    // Made here, before any event is processed (the renders run on this thread's event loop).
    for (QQuickImageResponse *r : responses)
        spies.emplace_back(new Spy(r));
    // What FolderModel and PlacesModel do on the GUI thread meanwhile.
    for (int i = 0; i < 50; ++i) {
        QIcon::hasThemeIcon(QStringLiteral("text-x-generic"));
        QCoreApplication::processEvents();
    }
    for (const auto &spy : spies)
        EXPECT_TRUE(spy->wait());
    QMetaObject::invokeMethod(
        context,
        [&] {
            qDeleteAll(responses);
            delete context;
        },
        Qt::BlockingQueuedConnection);
    loader.quit();
    loader.wait();
}

TEST(ImageProviders, AnIconFileIsDecodedAndEveryRequestIsFinished)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString root = QFileInfo(tmp.path()).canonicalFilePath();
    const QString good = writePng(root + QStringLiteral("/good.png"));
    const QString fifo = root + QStringLiteral("/icon.fifo");
    ASSERT_EQ(::mkfifo(QFile::encodeName(fifo).constData(), 0600), 0);
    QFile evil(root + QStringLiteral("/evil.svg"));
    ASSERT_TRUE(evil.open(QIODevice::WriteOnly));
    evil.write("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"8\" height=\"8\">"
               "<image width=\"8\" height=\"8\" xlink:href=\"#icon.fifo\"/></svg>");
    evil.close();

    AppIconProvider provider;
    std::unique_ptr<QQuickImageResponse> ok(provider.requestImageResponse(good, QSize(32, 32)));
    Spy okSpy(ok.get());
    ASSERT_TRUE(okSpy.wait());
    std::unique_ptr<QQuickTextureFactory> factory(ok->textureFactory());
    ASSERT_TRUE(factory);
    EXPECT_EQ(factory->image().size(), QSize(16, 16));

    // A refused file (a FIFO, an SVG naming one) is still answered, at once, with no blocked worker.
    QElapsedTimer timer;
    timer.start();
    std::unique_ptr<QQuickImageResponse> a(provider.requestImageResponse(fifo, QSize(32, 32)));
    std::unique_ptr<QQuickImageResponse> b(provider.requestImageResponse(evil.fileName(), QSize(32, 32)));
    Spy aSpy(a.get()), bSpy(b.get());
    EXPECT_TRUE(aSpy.wait());
    EXPECT_TRUE(bSpy.wait());
    EXPECT_LT(timer.elapsed(), 3000);

    // A cancelled response is finished too (Qt requires it).
    std::unique_ptr<QQuickImageResponse> c(provider.requestImageResponse(good, QSize(32, 32)));
    Spy cSpy(c.get());
    c->cancel();
    EXPECT_TRUE(cSpy.wait());
}

TEST(ImageProviders, TheGuiThreadsThemeLookupsRunBesideManyIconRequests)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString root = QFileInfo(tmp.path()).canonicalFilePath();
    const QString good = writePng(root + QStringLiteral("/good.png"));
    AppIconProvider provider;
    std::vector<std::unique_ptr<QQuickImageResponse>> responses;
    std::vector<std::unique_ptr<Spy>> spies; // made before any event is processed: finished() must not be missed
    for (int i = 0; i < 60; ++i) {
        responses.emplace_back(provider.requestImageResponse(i % 3 ? good : root + QStringLiteral("/missing.png"), QSize(32, 32)));
        spies.emplace_back(new Spy(responses.back().get()));
    }
    // What FolderModel and PlacesModel do on the GUI thread while the workers decode.
    for (int i = 0; i < 200; ++i) {
        QIcon::hasThemeIcon(QStringLiteral("text-x-generic"));
        QIcon::hasThemeIcon(QStringLiteral("folder"));
        QCoreApplication::processEvents();
    }
    for (const auto &spy : spies)
        EXPECT_TRUE(spy->wait());
}

namespace
{
bool waitUntil(const std::function<bool()> &condition, int ms = 5000)
{
    QElapsedTimer t;
    t.start();
    while (!condition() && t.elapsed() < ms)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    return condition();
}
} // namespace

TEST(ImageProviders, ASlowDecodeIsKilledAtItsDeadlineAndDoesNotStarveTheOthers)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString root = QFileInfo(tmp.path()).canonicalFilePath();
    const QString good = writePng(root + QStringLiteral("/good.png"));
    // "sleep 30 <w> <h>": a decoder that never answers in time.
    AppIcons::setDecoderForTests(QStringLiteral("/usr/bin/sleep"), {QStringLiteral("30")}, 400);
    AppIconProvider provider;
    std::vector<std::unique_ptr<QQuickImageResponse>> slow;
    std::vector<std::unique_ptr<Spy>> spies;
    QElapsedTimer timer;
    timer.start();
    for (int i = 0; i < 6; ++i) { // more than the pool has threads
        const QString path = root + QStringLiteral("/s%1.png").arg(i);
        writePng(path);
        slow.emplace_back(provider.requestImageResponse(path, QSize(32, 32)));
        spies.emplace_back(new Spy(slow.back().get()));
    }
    for (const auto &spy : spies)
        EXPECT_TRUE(spy->wait(10000));
    EXPECT_LT(timer.elapsed(), 6000); // 6 icons x 0.4 s on 3 threads, not 6 x 30 s
    EXPECT_TRUE(waitUntil([] { return AppIcons::runningDecodes() == 0; }));
    // The real decoder again: a good icon decodes at once after the slow ones.
    AppIcons::setDecoderForTests(QString(), {}, 0);
    std::unique_ptr<QQuickImageResponse> ok(provider.requestImageResponse(good, QSize(32, 32)));
    Spy okSpy(ok.get());
    ASSERT_TRUE(okSpy.wait());
    std::unique_ptr<QQuickTextureFactory> factory(ok->textureFactory());
    EXPECT_EQ(factory->image().size(), QSize(16, 16));
}

TEST(ImageProviders, ShutdownKillsTheRunningDecoders)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString root = QFileInfo(tmp.path()).canonicalFilePath();
    const QString path = writePng(root + QStringLiteral("/a.png"));
    AppIcons::setDecoderForTests(QStringLiteral("/usr/bin/sleep"), {QStringLiteral("60")}, 60000);
    AppIconProvider provider;
    std::unique_ptr<QQuickImageResponse> r(provider.requestImageResponse(path, QSize(32, 32)));
    Spy spy(r.get());
    ASSERT_TRUE(waitUntil([] { return AppIcons::runningDecodes() == 1; }));
    QElapsedTimer timer;
    timer.start();
    AppIconProvider::shutdown();
    EXPECT_LT(timer.elapsed(), 2500);
    EXPECT_EQ(AppIcons::runningDecodes(), 0);
    EXPECT_TRUE(spy.wait());
    AppIcons::setDecoderForTests(QString(), {}, 0);
}

// Re-run by the test below as a child process: quit while decodes are running, as Files does (aboutToQuit ->
// AppIconProvider::shutdown), then leave through exit() with static destruction. A crash (SIGSEGV as Qt is torn down: the
// round 4 review) would show as a signal, not as the exit code.
TEST(ImageProviders, ExitHelper)
{
    const QByteArray mode = qgetenv("GF_EXIT_HELPER");
    if (mode.isEmpty())
        GTEST_SKIP() << "run by QuitDuringADecodeIsClean";
    QTemporaryDir tmp;
    const QString root = QFileInfo(tmp.path()).canonicalFilePath();
    const QString path = writePng(root + QStringLiteral("/a.png"));
    // "sleep" holds the decoder busy the same way a slow document does, for the whole of the exit.
    AppIcons::setDecoderForTests(QStringLiteral("/usr/bin/sleep"), {QStringLiteral("60")}, 60000);
    AppIconProvider provider;
    std::vector<std::unique_ptr<QQuickImageResponse>> r;
    for (int i = 0; i < 4; ++i)
        r.emplace_back(provider.requestImageResponse(path, QSize(32 + i, 32)));
    waitUntil([] { return AppIcons::runningDecodes() >= 1; });
    if (mode == "shutdown")
        AppIconProvider::shutdown();
    std::exit(mode == "shutdown" ? 7 : 8);
}

TEST(ImageProviders, QuitDuringADecodeIsClean)
{
    for (const char *mode : {"shutdown", "plain"}) {
        QProcess p;
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("GF_EXIT_HELPER"), QString::fromLatin1(mode));
        env.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("offscreen"));
        env.insert(QStringLiteral("QT_QPA_PLATFORMTHEME"), QStringLiteral("none"));
        p.setProcessEnvironment(env);
        p.start(QCoreApplication::applicationFilePath(), {QStringLiteral("--gtest_filter=ImageProviders.ExitHelper")});
        ASSERT_TRUE(p.waitForStarted());
        ASSERT_TRUE(p.waitForFinished(30000)) << mode;
        EXPECT_EQ(p.exitStatus(), QProcess::NormalExit) << mode << " ended by a signal"; // a SIGSEGV is CrashExit
        EXPECT_EQ(p.exitCode(), std::string(mode) == "shutdown" ? 7 : 8) << mode;
    }
}

// A big icon is written to the decoder child in pieces (a pipe holds 64 KiB): the child must read to EOF. One read() returned
// only the first piece, so every icon over ~64 KiB (aether.png 352 KB, an OBS icon of 130 KB) showed the generic icon.
namespace
{
QByteArray noisePng(int w, int h)
{
    QImage image(w, h, QImage::Format_RGB32);
    quint32 x = 12345;
    for (int y = 0; y < h; ++y)
        for (int i = 0; i < w; ++i) {
            x = x * 1664525u + 1013904223u;
            image.setPixel(i, y, 0xff000000u | (x >> 8));
        }
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    image.save(&buffer, "PNG");
    return bytes;
}

QByteArray bigSvg(int rects)
{
    QByteArray s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\" viewBox=\"0 0 64 64\">";
    for (int i = 0; i < rects; ++i)
        s += "<rect x=\"" + QByteArray::number(i % 60) + "\" y=\"" + QByteArray::number((i * 7) % 60) +
             "\" width=\"3\" height=\"3\" fill=\"#" + QByteArray::number(100000 + (i * 37) % 899999) + "\" opacity=\"0.5\"/>\n";
    return s + "</svg>";
}

// Runs the decoder child by hand; `chunk` bytes per write with a pause so that the child sees them one by one.
int runChild(const QByteArray &data, int chunk, QByteArray *out)
{
    QProcess p;
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("offscreen"));
    env.insert(QStringLiteral("QT_QPA_PLATFORMTHEME"), QStringLiteral("none"));
    p.setProcessEnvironment(env);
    p.start(QCoreApplication::applicationFilePath(), {QStringLiteral("--decode-icon"), QStringLiteral("64"), QStringLiteral("64")});
    if (!p.waitForStarted())
        return -1;
    for (qsizetype at = 0; at < data.size() && p.state() == QProcess::Running; at += chunk) {
        p.write(data.mid(at, chunk));
        p.waitForBytesWritten(2000);
        QThread::msleep(20);
    }
    p.closeWriteChannel();
    if (!p.waitForFinished(20000))
        return -2;
    if (out)
        *out = p.readAllStandardOutput();
    return p.exitStatus() == QProcess::NormalExit ? p.exitCode() : -3;
}
} // namespace

TEST(ImageProviders, TheDecoderChildReadsAnIconWrittenInPiecesToTheEnd)
{
    const QByteArray png = noisePng(300, 300);
    ASSERT_GT(png.size(), 200 * 1024);
    const QByteArray svg = bigSvg(1800);
    ASSERT_GT(svg.size(), 100 * 1024);
    ASSERT_LE(svg.size(), AppIcons::kMaxSvgBytes);
    for (const QByteArray *icon : {&png, &svg}) {
        for (const int chunk : {int(icon->size()), 16 * 1024, 5000}) {
            QByteArray out;
            EXPECT_EQ(runChild(*icon, chunk, &out), 0) << icon->size() << " bytes in pieces of " << chunk;
            const QImage image = QImage::fromData(out, "PNG");
            EXPECT_FALSE(image.isNull()) << icon->size() << " bytes in pieces of " << chunk;
            EXPECT_LE(image.width(), 64);
        }
    }
}

TEST(ImageProviders, AnIconOverTheCapIsRefusedByTheChild)
{
    // PNG magic and then more than the cap: refused, and the child does not wait for more than cap + 1 bytes.
    QByteArray big = QByteArray("\x89PNG\r\n\x1a\n", 8) + QByteArray(AppIcons::kMaxPngBytes + 100, 'x');
    EXPECT_EQ(runChild(big, 256 * 1024, nullptr), 1);
}

TEST(ImageProviders, ABigIconFileGoesThroughLoadIsolated)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString root = QFileInfo(tmp.path()).canonicalFilePath();
    QFile f(root + QStringLiteral("/big.png"));
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(noisePng(300, 300));
    f.close();
    QFile g(root + QStringLiteral("/big.svg"));
    ASSERT_TRUE(g.open(QIODevice::WriteOnly));
    g.write(bigSvg(1800));
    g.close();
    AppIcons::setDecoderForTests(QString(), {}, 0);
    for (const char *name : {"big.png", "big.svg"}) {
        const QImage image = AppIcons::loadIsolated(root + QLatin1Char('/') + QLatin1String(name), {root}, QSize(64, 64));
        EXPECT_FALSE(image.isNull()) << name;
        EXPECT_LE(image.width(), 64) << name;
    }
}
