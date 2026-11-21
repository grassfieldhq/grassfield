// IconLookup (apps/settings/src/iconlookup.h): the icon theme lookup Settings' image://icon provider runs on Qt Quick's image
// threads (SP-09), against icon themes built in a scratch folder: the theme's directory nearest the size, its parents, the
// fallback and hicolor, the pixmaps folder, nothing outside a plain name; and many threads asking at once.
#include <gtest/gtest.h>

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include <atomic>
#include <thread>
#include <vector>

#include "iconlookup.h"

using grassfield::settings::IconLookup;

namespace {

void put(const QString &path, const QByteArray &text = "x")
{
    QDir().mkpath(path.section(QLatin1Char('/'), 0, -2));
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
    f.write(text);
}

struct Themes {
    QTemporaryDir dir;
    QString icons, pixmaps;
    Themes()
    {
        icons = dir.filePath(QStringLiteral("icons"));
        pixmaps = dir.filePath(QStringLiteral("pixmaps"));
        put(icons + QStringLiteral("/Mine/index.theme"),
            "[Icon Theme]\nName=Mine\nInherits=Parent\nDirectories=16x16/apps,48x48/apps,scalable/apps,48x48@2/apps\n\n"
            "[16x16/apps]\nSize=16\nType=Fixed\n\n[48x48/apps]\nSize=48\nType=Fixed\n\n[48x48@2/apps]\nSize=48\nScale=2\nType=Fixed\n\n"
            "[scalable/apps]\nSize=64\nMinSize=8\nMaxSize=512\nType=Scalable\n");
        put(icons + QStringLiteral("/Mine/16x16/apps/editor.png"));
        put(icons + QStringLiteral("/Mine/48x48/apps/editor.png"));
        put(icons + QStringLiteral("/Mine/scalable/apps/drawing.svg"));
        put(icons + QStringLiteral("/Parent/index.theme"), "[Icon Theme]\nName=Parent\nDirectories=32x32/apps\n\n[32x32/apps]\nSize=32\nType=Threshold\n");
        put(icons + QStringLiteral("/Parent/32x32/apps/terminal.png"));
        put(icons + QStringLiteral("/hicolor/index.theme"), "[Icon Theme]\nName=Hicolor\nDirectories=48x48/apps\n\n[48x48/apps]\nSize=48\nType=Threshold\n");
        put(icons + QStringLiteral("/hicolor/48x48/apps/vendor.png"));
        put(pixmaps + QStringLiteral("/legacy.xpm"));
    }
};

} // namespace

TEST(IconLookup, FindsTheNearestSizeInTheThemeItsParentsHicolorAndPixmaps)
{
    Themes t;
    IconLookup lookup({t.icons}, QStringLiteral("Mine"), QString(), {t.pixmaps});
    EXPECT_EQ(lookup.find(QStringLiteral("editor"), 44), t.icons + QStringLiteral("/Mine/48x48/apps/editor.png"));
    EXPECT_EQ(lookup.find(QStringLiteral("editor"), 18), t.icons + QStringLiteral("/Mine/16x16/apps/editor.png"));
    EXPECT_EQ(lookup.find(QStringLiteral("drawing"), 128), t.icons + QStringLiteral("/Mine/scalable/apps/drawing.svg"));
    EXPECT_EQ(lookup.find(QStringLiteral("terminal"), 32), t.icons + QStringLiteral("/Parent/32x32/apps/terminal.png"));
    EXPECT_EQ(lookup.find(QStringLiteral("vendor"), 64), t.icons + QStringLiteral("/hicolor/48x48/apps/vendor.png"));
    EXPECT_EQ(lookup.find(QStringLiteral("legacy"), 64), t.pixmaps + QStringLiteral("/legacy.xpm"));
    // An extension in the entry's Icon= is dropped; a path or anything but a plain name finds nothing.
    EXPECT_EQ(lookup.find(QStringLiteral("editor.png"), 48), t.icons + QStringLiteral("/Mine/48x48/apps/editor.png"));
    EXPECT_EQ(lookup.find(QStringLiteral("missing"), 48), QString());
    EXPECT_EQ(lookup.find(QStringLiteral("../Mine/48x48/apps/editor"), 48), QString());
    EXPECT_EQ(lookup.find(QStringLiteral("a/b"), 48), QString());
    EXPECT_EQ(lookup.find(QString(), 48), QString());
}

TEST(IconLookup, AThemeThatInheritsItselfEnds)
{
    QTemporaryDir dir;
    const QString icons = dir.filePath(QStringLiteral("icons"));
    put(icons + QStringLiteral("/Loop/index.theme"), "[Icon Theme]\nInherits=Loop,Other\nDirectories=\n");
    put(icons + QStringLiteral("/Other/index.theme"), "[Icon Theme]\nInherits=Loop\nDirectories=\n");
    IconLookup lookup({icons}, QStringLiteral("Loop"), QString(), {});
    EXPECT_EQ(lookup.find(QStringLiteral("anything"), 48), QString());
}

// The provider asks from several image threads at once: every answer is the same file, and nothing breaks.
TEST(IconLookup, ManyThreadsAskAtOnce)
{
    Themes t;
    IconLookup lookup({t.icons}, QStringLiteral("Mine"), QString(), {t.pixmaps});
    std::atomic<int> wrong{0};
    std::vector<std::thread> threads;
    for (int i = 0; i < 8; ++i) {
        threads.emplace_back([&lookup, &t, &wrong, i] {
            for (int n = 0; n < 200; ++n) {
                const int size = 16 + (n + i) % 64;
                if (lookup.find(QStringLiteral("terminal"), size) != t.icons + QStringLiteral("/Parent/32x32/apps/terminal.png"))
                    ++wrong;
            }
        });
    }
    for (std::thread &th : threads)
        th.join();
    EXPECT_EQ(wrong.load(), 0);
}
