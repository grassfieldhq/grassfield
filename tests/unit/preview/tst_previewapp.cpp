// Grassfield Preview's backend off the window's thread (2026-11 audit, round 2): a file is inspected on a worker (P4) and a
// huge vector picture refused before it is parsed, a long text comes in pieces (P7), the sidebar's snippets are read on a
// worker, and the two recognitions of an image share one decode and run at the lowest priority with one OpenMP thread (P5).
#include "previewapp.h"
#include "previewlogic.h"

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QTemporaryDir>

#include <gtest/gtest.h>

namespace {

void ensureApp()
{
    static int argc = 1;
    static char name[] = "preview-unit-tests";
    static char *argv[] = {name, nullptr};
    if (!QCoreApplication::instance()) {
        qputenv("QT_QPA_PLATFORM", "offscreen");
        new QGuiApplication(argc, argv);
    }
}

bool waitFor(const std::function<bool()> &done, int ms = 5000)
{
    QElapsedTimer t;
    t.start();
    while (!done() && t.elapsed() < ms)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    return done();
}

void write(const QString &path, const QByteArray &bytes)
{
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(bytes);
}

} // namespace

TEST(PreviewApp, InspectsOnAWorkerAndKeepsTheNewestAnswer)
{
    ensureApp();
    QTemporaryDir dir;
    QByteArray text;
    for (int i = 0; i < 6000; ++i)
        text += "line " + QByteArray::number(i) + " of a long log file, with a few words\n";
    write(dir.filePath(QStringLiteral("long.txt")), text);
    write(dir.filePath(QStringLiteral("short.txt")), "hello\n");
    // A vector picture over the bound: refused from its size alone, never parsed (a 50 MB SVG froze the window).
    write(dir.filePath(QStringLiteral("huge.svg")), "<svg xmlns=\"http://www.w3.org/2000/svg\">" + QByteArray(int(preview::kMaxVectorBytes) + 10, ' ') + "</svg>");
    PreviewApp app({dir.filePath(QStringLiteral("long.txt")), dir.filePath(QStringLiteral("short.txt")), dir.filePath(QStringLiteral("huge.svg"))},
                   {}, false);
    QHash<int, QVariantMap> answers;
    QObject::connect(&app, &PreviewApp::inspected, [&answers](int request, const QVariantMap &info) { answers.insert(request, info); });

    const int first = app.requestInspect(1);
    const int last = app.requestInspect(0);
    EXPECT_GT(last, first);
    EXPECT_TRUE(answers.isEmpty()) << "answered on the caller's thread";
    ASSERT_TRUE(waitFor([&] { return answers.contains(last); }));
    const QVariantMap info = answers.value(last);
    EXPECT_TRUE(info.value(QStringLiteral("ok")).toBool());
    EXPECT_EQ(info.value(QStringLiteral("kind")).toString(), QStringLiteral("text"));
    // P7: the long text in pieces of whole lines, which give it back whole.
    const QStringList chunks = info.value(QStringLiteral("chunks")).toStringList();
    EXPECT_GT(chunks.size(), 2);
    EXPECT_EQ(chunks.join(QString()), QString::fromUtf8(text));
    for (const QString &c : chunks)
        EXPECT_TRUE(c.endsWith(QLatin1Char('\n')));
    EXPECT_FALSE(app.inspect(1).contains(QStringLiteral("chunks"))) << "a short text stays whole";

    const int svg = app.requestInspect(2);
    ASSERT_TRUE(waitFor([&] { return answers.contains(svg); }));
    EXPECT_FALSE(answers.value(svg).value(QStringLiteral("ok")).toBool());
    EXPECT_FALSE(answers.value(svg).value(QStringLiteral("error")).toString().isEmpty());
}

TEST(PreviewApp, SidebarSnippetsAreReadOnAWorker)
{
    ensureApp();
    QTemporaryDir dir;
    write(dir.filePath(QStringLiteral("notes.txt")), "first line\nsecond line\n");
    PreviewApp app({dir.filePath(QStringLiteral("notes.txt"))}, {}, false);
    int changes = 0;
    QObject::connect(&app, &PreviewApp::snippetsChanged, [&changes] { ++changes; });
    EXPECT_EQ(app.snippetFor(0), QString()) << "nothing read on the window's thread";
    EXPECT_EQ(app.snippetRevision(), 0);
    ASSERT_TRUE(waitFor([&] { return changes > 0; }));
    EXPECT_TRUE(app.snippetFor(0).startsWith(QStringLiteral("first line")));
    EXPECT_EQ(app.snippetRevision(), 1);
    EXPECT_EQ(app.snippetFor(0), app.textSnippet(0));
}

TEST(PreviewApp, RecognitionsShareOneDecodeAndRunInTheBackground)
{
    ensureApp();
    QTemporaryDir dir;
    QImage image(600, 400, QImage::Format_RGB32);
    image.fill(Qt::white);
    ASSERT_TRUE(image.save(dir.filePath(QStringLiteral("photo.png"))));
    // A zbarimg that tells its niceness and its OpenMP limit, and how many bytes of picture it got.
    QDir().mkpath(dir.filePath(QStringLiteral("bin")));
    const QString tool = dir.filePath(QStringLiteral("bin/zbarimg"));
    write(tool, "#!/bin/sh\nbytes=$(wc -c)\nnice=$(cut -d' ' -f19 /proc/$$/stat)\necho \"$nice $OMP_THREAD_LIMIT $bytes\"\n");
    QFile::setPermissions(tool, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
    const QByteArray oldPath = qgetenv("PATH");
    qputenv("PATH", dir.filePath(QStringLiteral("bin")).toUtf8() + ":" + oldPath);
    {
        PreviewApp app({dir.filePath(QStringLiteral("photo.png"))}, {}, false);
        QHash<int, QString> answers;
        QObject::connect(&app, &PreviewApp::recognized, [&answers](int request, const QString &, int code, const QString &out) {
            answers.insert(request, code == 0 ? out.trimmed() : QStringLiteral("failed"));
        });
        const int a = app.recognize(QStringLiteral("qr"), 0);
        const int b = app.recognize(QStringLiteral("qr"), 0);
        ASSERT_GT(a, 0);
        ASSERT_GT(b, 0);
        ASSERT_TRUE(waitFor([&] { return answers.size() == 2; }, 10000));
        EXPECT_EQ(app.recognitionDecodes(), 1) << "one decode for both";
        for (const QString &out : answers) {
            const QStringList f = out.split(QLatin1Char(' '));
            ASSERT_EQ(f.size(), 3) << out.toStdString();
            EXPECT_EQ(f[0], QStringLiteral("19")) << "the lowest CPU priority";
            EXPECT_EQ(f[1], QStringLiteral("1")) << "one OpenMP thread";
            EXPECT_GT(f[2].toInt(), 600 * 400) << "the decoded picture on its input";
        }
        // A third look at the same image: the picture kept is handed out again.
        const int c = app.recognize(QStringLiteral("qr"), 0);
        ASSERT_TRUE(waitFor([&] { return answers.contains(c); }, 10000));
        EXPECT_EQ(app.recognitionDecodes(), 1);
    }
    qputenv("PATH", oldPath);
}

// Owner report on 1.0.0-rc9: a Markdown file is inspected as text with its rendered HTML; its picture is served by the image
// provider under a token (never by its path), and a document past the bound shows its source only.
TEST(PreviewApp, MarkdownIsRenderedWithItsPicturesFromTheProvider)
{
    ensureApp();
    QTemporaryDir dir;
    ASSERT_TRUE(QImage(30, 10, QImage::Format_RGB32).save(dir.filePath(QStringLiteral("pic.png"))));
    write(dir.filePath(QStringLiteral("doc.md")), "# Hello\n\n![a picture](pic.png) ![web](https://example.com/w.png)\n");
    QByteArray big = "# Big\n\n";
    for (int i = 0; i < preview::kMaxMarkdownChars / 50 + 10; ++i)
        big += "a line of a long Markdown document, to be shown as source.\n";
    write(dir.filePath(QStringLiteral("big.md")), big);
    write(dir.filePath(QStringLiteral("plain.txt")), "# not markdown\n");
    PreviewApp app({dir.filePath(QStringLiteral("doc.md")), dir.filePath(QStringLiteral("big.md")), dir.filePath(QStringLiteral("plain.txt"))}, {}, false);
    const QVariantMap doc = app.inspect(0);
    EXPECT_TRUE(doc.value(QStringLiteral("ok")).toBool());
    EXPECT_EQ(doc.value(QStringLiteral("kind")).toString(), QStringLiteral("text"));
    EXPECT_TRUE(doc.value(QStringLiteral("markdown")).toBool());
    EXPECT_EQ(doc.value(QStringLiteral("text")).toString().left(7), QStringLiteral("# Hello"));
    const QString html = doc.value(QStringLiteral("html")).toString();
    const int token = app.tokenFor(QFileInfo(dir.filePath(QStringLiteral("pic.png"))).canonicalFilePath());
    EXPECT_TRUE(html.contains(QStringLiteral("<img src=\"image://preview/fit/30x10/%1\"").arg(token))) << qPrintable(html);
    EXPECT_FALSE(html.contains(QStringLiteral("example.com")));
    const QVariantMap large = app.inspect(1);
    EXPECT_TRUE(large.value(QStringLiteral("ok")).toBool());
    EXPECT_TRUE(large.value(QStringLiteral("markdown")).toBool());
    EXPECT_FALSE(large.contains(QStringLiteral("html")));
    EXPECT_FALSE(large.value(QStringLiteral("chunks")).toStringList().isEmpty());
    const QVariantMap plain = app.inspect(2);
    EXPECT_FALSE(plain.contains(QStringLiteral("markdown")));
    EXPECT_FALSE(plain.contains(QStringLiteral("html")));
}

// Review 2026-11-22 (MEDIUM): a document's picture is decoded at its served size ("fit/<w>x<h>/<token>"), never at the
// file's; a size past kMarkdownImageMaxSide or an unknown token gives nothing.
TEST(PreviewApp, MarkdownPicturesAreDecodedAtTheirServedSize)
{
    ensureApp();
    QTemporaryDir dir;
    ASSERT_TRUE(QImage(3000, 1000, QImage::Format_RGB32).save(dir.filePath(QStringLiteral("wide.png"))));
    PreviewApp app({dir.filePath(QStringLiteral("wide.png"))}, {}, false);
    const int token = app.tokenFor(dir.filePath(QStringLiteral("wide.png")));
    PreviewImageProvider provider(&app);
    QSize size;
    const QImage image = provider.requestImage(QStringLiteral("fit/600x200/%1").arg(token), &size, QSize());
    EXPECT_EQ(image.size(), QSize(600, 200));
    EXPECT_EQ(size, QSize(600, 200));
    // Whatever the rich text asks for, the served size bounds it.
    EXPECT_EQ(provider.requestImage(QStringLiteral("fit/600x200/%1").arg(token), &size, QSize(3000, 1000)).size(), QSize(600, 200));
    EXPECT_TRUE(provider.requestImage(QStringLiteral("fit/%1x10/%2").arg(preview::kMarkdownImageMaxSide + 1).arg(token), &size, QSize()).isNull());
    EXPECT_TRUE(provider.requestImage(QStringLiteral("fit/600x200/999"), &size, QSize()).isNull());
    EXPECT_TRUE(provider.requestImage(QStringLiteral("fit/0x200/%1").arg(token), &size, QSize()).isNull());
    EXPECT_TRUE(provider.requestImage(QStringLiteral("fit/600x200/%1/x").arg(token), &size, QSize()).isNull());
}

// Review 2026-11-22 (LOW-MEDIUM): the Glance sized its window from inspectFirst(), on the window's thread, which read the
// whole first text and rendered its Markdown (pictures probed). It now gives the kind (and a picture's size) only.
TEST(PreviewApp, InspectFirstReadsNoTextAndRendersNoMarkdown)
{
    ensureApp();
    QTemporaryDir dir;
    write(dir.filePath(QStringLiteral("doc.md")), "# Hello\n\n![p](pic.png)\n");
    ASSERT_TRUE(QImage(30, 10, QImage::Format_RGB32).save(dir.filePath(QStringLiteral("pic.png"))));
    PreviewApp md({dir.filePath(QStringLiteral("doc.md"))}, {}, true);
    const QVariantMap first = md.inspectFirst();
    EXPECT_TRUE(first.value(QStringLiteral("ok")).toBool());
    EXPECT_EQ(first.value(QStringLiteral("kind")).toString(), QStringLiteral("text"));
    EXPECT_FALSE(first.contains(QStringLiteral("text")));
    EXPECT_FALSE(first.contains(QStringLiteral("html")));
    EXPECT_EQ(md.tokenFor(QStringLiteral("/a/new/path")), 1) << "no picture of the document was given a token";
    PreviewApp picture({dir.filePath(QStringLiteral("pic.png"))}, {}, true);
    const QVariantMap p = picture.inspectFirst();
    EXPECT_TRUE(p.value(QStringLiteral("ok")).toBool());
    EXPECT_EQ(p.value(QStringLiteral("width")).toInt(), 30);
    EXPECT_EQ(p.value(QStringLiteral("height")).toInt(), 10);
}
