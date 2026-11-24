// Argument validation of the Screenshot app (slice B1): local paths only, as Preview's, and exactly one regular PNG file.
#include "screenshotlogic.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <sys/stat.h>
#include <unistd.h>

using namespace screenshot;

namespace {

QString makePng(const QString &dir, const QString &name, int w = 8, int h = 6)
{
    QImage image(w, h, QImage::Format_ARGB32);
    image.fill(Qt::red);
    const QString path = dir + QLatin1Char('/') + name;
    EXPECT_TRUE(image.save(path, "PNG"));
    return path;
}

QString write(const QString &path, const QByteArray &bytes)
{
    QFile f(path);
    EXPECT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(bytes);
    return path;
}

QByteArray be32(quint32 v)
{
    const char b[4] = {char(v >> 24), char(v >> 16), char(v >> 8), char(v)};
    return QByteArray(b, 4);
}

} // namespace

TEST(ScreenshotArguments, OnePngFileIsAccepted)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString png = makePng(dir.path(), "shot.png");
    const Arguments a = resolveArguments({png}, "/");
    EXPECT_TRUE(a.errors.isEmpty()) << a.errors.join("; ").toStdString();
    EXPECT_EQ(a.path, QFileInfo(png).canonicalFilePath());
}

TEST(ScreenshotArguments, RelativePathAndFileUrl)
{
    QTemporaryDir dir;
    makePng(dir.path(), "a.png");
    const QString want = QFileInfo(dir.path() + "/a.png").canonicalFilePath();
    EXPECT_EQ(resolveArguments({"a.png"}, dir.path()).path, want);
    EXPECT_EQ(resolveArguments({"file://" + dir.path() + "/a.png"}, "/").path, want);
    EXPECT_EQ(resolveArguments({"file://localhost" + dir.path() + "/a.png"}, "/").path, want);
}

TEST(ScreenshotArguments, OnlyLocalFilesAreAccepted)
{
    for (const char *url : {"http://example.org/a.png", "https://example.org/a.png", "ftp://host/a.png", "smb://host/share/a.png",
                            "sftp://host/a.png", "data:image/png;base64,AAAA", "file://remote-host/tmp/a.png", "file:///tmp/a.png?x=1",
                            "file:///tmp/a.png#frag"}) {
        const Arguments a = resolveArguments({QString::fromLatin1(url)}, "/");
        EXPECT_TRUE(a.path.isEmpty()) << url;
        EXPECT_EQ(a.errors.size(), 1) << url;
    }
}

TEST(ScreenshotArguments, ExactlyOneFile)
{
    QTemporaryDir dir;
    const QString one = makePng(dir.path(), "1.png");
    const QString two = makePng(dir.path(), "2.png");
    EXPECT_FALSE(resolveArguments({}, "/").errors.isEmpty());
    EXPECT_TRUE(resolveArguments({}, "/").path.isEmpty());
    const Arguments many = resolveArguments({one, two}, "/");
    EXPECT_TRUE(many.path.isEmpty());
    EXPECT_FALSE(many.errors.isEmpty());
    EXPECT_FALSE(resolveArguments({""}, "/").errors.isEmpty());
    EXPECT_FALSE(resolveArguments({"   "}, "/").errors.isEmpty());
}

TEST(ScreenshotArguments, OnlyRegularPngFiles)
{
    QTemporaryDir dir;
    EXPECT_FALSE(resolveArguments({dir.path() + "/missing.png"}, "/").errors.isEmpty());
    EXPECT_FALSE(resolveArguments({dir.path()}, "/").errors.isEmpty()) << "a folder";
    EXPECT_FALSE(resolveArguments({"/dev/null"}, "/").errors.isEmpty()) << "a device";
    EXPECT_FALSE(resolveArguments({"/proc/self/status"}, "/").errors.isEmpty()) << "a system path";
    const QString fifo = dir.path() + "/fifo.png";
    ASSERT_EQ(::mkfifo(QFile::encodeName(fifo).constData(), 0600), 0);
    EXPECT_FALSE(resolveArguments({fifo}, "/").errors.isEmpty()) << "a FIFO is never opened";
    const QString text = write(dir.path() + "/text.png", "not a picture at all, just words");
    EXPECT_FALSE(resolveArguments({text}, "/").errors.isEmpty());
    QImage image(4, 4, QImage::Format_RGB32);
    image.fill(Qt::blue);
    const QString jpg = dir.path() + "/x.jpg";
    ASSERT_TRUE(image.save(jpg, "JPEG"));
    EXPECT_FALSE(resolveArguments({jpg}, "/").errors.isEmpty()) << "PNG only until the settings slice";
}

TEST(ScreenshotArguments, ALinkIsFollowedToItsTarget)
{
    QTemporaryDir dir;
    const QString png = makePng(dir.path(), "real.png");
    const QString link = dir.path() + "/link.png";
    ASSERT_TRUE(QFile::link(png, link));
    EXPECT_EQ(resolveArguments({link}, "/").path, QFileInfo(png).canonicalFilePath()) << "Done must replace the file, never the link";
    const QString dangling = dir.path() + "/dangling.png";
    ASSERT_TRUE(QFile::link(dir.path() + "/nowhere.png", dangling));
    EXPECT_FALSE(resolveArguments({dangling}, "/").errors.isEmpty());
}

TEST(ScreenshotArguments, PictureCaps)
{
    QTemporaryDir dir;
    // A header that claims 20000 x 20000: refused from the IHDR, before any decoder runs.
    const QByteArray head("\x89PNG\r\n\x1a\n\0\0\0\rIHDR", 16);
    const QByteArray huge = head + be32(20000) + be32(20000) + QByteArray("\x08\x06\0\0\0", 5);
    const QString path = write(dir.path() + "/huge.png", huge);
    const Arguments a = resolveArguments({path}, "/");
    EXPECT_TRUE(a.path.isEmpty());
    EXPECT_FALSE(a.errors.isEmpty());
    EXPECT_TRUE(imageSizeAllowed(QSize(16384, 4096)));
    EXPECT_FALSE(imageSizeAllowed(QSize(16385, 10)));
    EXPECT_FALSE(imageSizeAllowed(QSize(16384, 16384))) << "over the allocation limit";
    EXPECT_FALSE(imageSizeAllowed(QSize(0, 5)));
    EXPECT_FALSE(imageSizeAllowed(QSize()));
}

TEST(ScreenshotArguments, PngHeader)
{
    EXPECT_EQ(pngSize(QByteArray()), QSize());
    EXPECT_EQ(pngSize(QByteArray(24, 'x')), QSize());
    QTemporaryDir dir;
    const QString png = makePng(dir.path(), "s.png", 30, 20);
    QFile f(png);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    EXPECT_EQ(pngSize(f.read(32)), QSize(30, 20));
    f.seek(0);
    EXPECT_EQ(pngSize(f.read(23)), QSize()) << "a header cut short";
}

// ---- no file: open the capture toolbar through the shell's IPC (the Apps entry) ----

TEST(ScreenshotOpenToolbar, ArgvIsTheShellIpcPlusCaptureToggle)
{
    const QStringList ipc{"ipc", "-p", "/usr/share/grassfield/shell", "call"};
    EXPECT_EQ(openToolbarArguments(ipc), (QStringList{"ipc", "-p", "/usr/share/grassfield/shell", "call", "capture", "toggle"}));
    EXPECT_TRUE(openToolbarArguments({}).isEmpty());
}

TEST(ScreenshotOpenToolbar, RunsTheCallAndSucceeds)
{
    QStringList seen;
    int calls = 0;
    QString why;
    const int code = openToolbar({"ipc", "-p", "/shell", "call"}, [&](const QStringList &a) {
        seen = a;
        ++calls;
        return true;
    }, &why);
    EXPECT_EQ(code, 0);
    EXPECT_EQ(calls, 1);
    EXPECT_EQ(seen.mid(seen.size() - 2), (QStringList{"capture", "toggle"}));
    EXPECT_TRUE(why.isEmpty());
}

TEST(ScreenshotOpenToolbar, NoShellExitsTwoWithoutRunningAnything)
{
    int calls = 0;
    QString why;
    EXPECT_EQ(openToolbar({}, [&](const QStringList &) { ++calls; return true; }, &why), 2);
    EXPECT_EQ(calls, 0);
    EXPECT_FALSE(why.isEmpty());
}

TEST(ScreenshotOpenToolbar, AFailedCallExitsTwo)
{
    QString why;
    EXPECT_EQ(openToolbar({"ipc", "call"}, [](const QStringList &) { return false; }, &why), 2);
    EXPECT_FALSE(why.isEmpty());
}
