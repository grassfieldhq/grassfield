// The Go menu's logic (NavLogic): Go to Folder's completion, Connect to Server's addresses, recent lists, shortcuts.
#include "navlogic.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include <memory>

#include <gtest/gtest.h>

using namespace NavLogic;

namespace
{
// Real files for goToTarget, under GRASSFIELD_TEST_TMP (a directory inside .dev/).
std::unique_ptr<QTemporaryDir> sandbox(QString *why)
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    if (base.isEmpty() || !QDir::cleanPath(base).contains(QLatin1String("/.dev/"))) {
        *why = QStringLiteral("GRASSFIELD_TEST_TMP (a directory under .dev/) is not set");
        return nullptr;
    }
    QDir().mkpath(base);
    auto dir = std::make_unique<QTemporaryDir>(base + QStringLiteral("/navlogic-XXXXXX"));
    if (!dir->isValid()) {
        *why = QStringLiteral("cannot create a directory in ") + base;
        return nullptr;
    }
    return dir;
}
} // namespace

TEST(GoToFolder, TargetsOfWhatIsTyped)
{
    const QString home = QStringLiteral("/home/u");
    const QString base = QStringLiteral("/home/u/Documents");
    auto t = completionTarget(QStringLiteral("~/D"), base, home);
    EXPECT_EQ(t.folder, home);
    EXPECT_EQ(t.prefix, QStringLiteral("D"));
    EXPECT_EQ(t.typedFolder, QStringLiteral("~/"));
    EXPECT_EQ(completedText(t, QStringLiteral("Downloads")), QStringLiteral("~/Downloads/")) << "kept as typed";

    t = completionTarget(QStringLiteral("/usr/sh"), base, home);
    EXPECT_EQ(t.folder, QStringLiteral("/usr"));
    EXPECT_EQ(t.prefix, QStringLiteral("sh"));

    t = completionTarget(QStringLiteral("/usr/share/"), base, home);
    EXPECT_EQ(t.folder, QStringLiteral("/usr/share"));
    EXPECT_TRUE(t.prefix.isEmpty()) << "after a slash: the whole folder";

    t = completionTarget(QStringLiteral("Proj"), base, home);
    EXPECT_EQ(t.folder, base) << "a bare name is in the shown folder";
    EXPECT_EQ(t.prefix, QStringLiteral("Proj"));
    t = completionTarget(QStringLiteral("Projects/../a"), base, home);
    EXPECT_EQ(t.folder, base) << "cleaned";

    EXPECT_TRUE(completionTarget(QStringLiteral("Proj"), QString(), home).folder.isEmpty()) << "no local folder shown";
    EXPECT_TRUE(completionTarget(QStringLiteral("smb://nas/sh"), base, home).folder.isEmpty()) << "remote: no completion";
    EXPECT_TRUE(completionTarget(QStringLiteral("~"), base, home).folder.isEmpty());
    EXPECT_TRUE(completionTarget(QString(), base, home).folder.isEmpty());
    t = completionTarget(QStringLiteral("file:///etc/sys"), base, home);
    EXPECT_EQ(t.folder, QStringLiteral("/etc"));
    EXPECT_EQ(t.prefix, QStringLiteral("sys"));
}

TEST(GoToFolder, MatchesBeginWithThePrefix)
{
    const QStringList names = {QStringLiteral("Downloads"), QStringLiteral("desktop"), QStringLiteral("Documents"), QStringLiteral(".dotfiles"),
                               QStringLiteral("Music"), QStringLiteral("."), QStringLiteral("..")};
    EXPECT_EQ(folderMatches(names, QStringLiteral("d"), false, 10),
              (QStringList{QStringLiteral("desktop"), QStringLiteral("Documents"), QStringLiteral("Downloads")}))
        << "case-insensitive, sorted, no hidden";
    EXPECT_EQ(folderMatches(names, QStringLiteral("."), false, 10), QStringList{QStringLiteral(".dotfiles")}) << "a dot asks for hidden ones";
    EXPECT_EQ(folderMatches(names, QString(), true, 10).size(), 5) << "never . or ..";
    EXPECT_EQ(folderMatches(names, QString(), false, 2).size(), 2) << "bounded";
}

TEST(ConnectToServer, AddressesAndRefusals)
{
    EXPECT_EQ(serverUrl(QStringLiteral("nas.local")).toString(), QStringLiteral("smb://nas.local/")) << "SMB by default";
    EXPECT_EQ(serverUrl(QStringLiteral(" nas/share ")).toString(), QStringLiteral("smb://nas/share"));
    EXPECT_EQ(serverUrl(QStringLiteral("sftp://me@host:2222/srv")).toString(), QStringLiteral("sftp://me@host:2222/srv"));
    EXPECT_EQ(serverUrl(QStringLiteral("https://dav.example.org/files")).scheme(), QStringLiteral("webdavs"));
    EXPECT_EQ(serverUrl(QStringLiteral("http://dav.example.org")).scheme(), QStringLiteral("webdav"));
    EXPECT_EQ(serverUrl(QStringLiteral("FTP://host")).scheme(), QStringLiteral("ftp"));
    const QUrl withPassword = serverUrl(QStringLiteral("smb://me:secret@nas/share"));
    EXPECT_TRUE(withPassword.password().isEmpty()) << "a password is never kept";
    EXPECT_FALSE(withPassword.toString().contains(QStringLiteral("secret")));
    EXPECT_FALSE(serverUrl(QStringLiteral("file:///etc")).isValid());
    EXPECT_FALSE(serverUrl(QStringLiteral("trash:/")).isValid());
    EXPECT_FALSE(serverUrl(QStringLiteral("file:/etc")).isValid());
    EXPECT_EQ(serverUrl(QStringLiteral("nas:445/share")).toString(), QStringLiteral("smb://nas:445/share")) << "a host and its port";
    EXPECT_FALSE(serverUrl(QStringLiteral("smb://")).isValid()) << "no host";
    EXPECT_FALSE(serverUrl(QStringLiteral("")).isValid());
    EXPECT_FALSE(serverUrl(QStringLiteral("my nas")).isValid()) << "a space in the host";
}

TEST(GoMenu, RecentListsAndShortcuts)
{
    QStringList recent = {QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c")};
    EXPECT_EQ(pushRecent(recent, QStringLiteral("b"), 3), (QStringList{QStringLiteral("b"), QStringLiteral("a"), QStringLiteral("c")}));
    EXPECT_EQ(pushRecent(recent, QStringLiteral("d"), 3), (QStringList{QStringLiteral("d"), QStringLiteral("a"), QStringLiteral("b")}));
    EXPECT_EQ(pushRecent(recent, QString(), 3), recent);

    const QString home = QStringLiteral("/home/u");
    const QStringList xdg = {QStringLiteral("/home/u/Desktop"), QStringLiteral("/home/u/Documents"), QStringLiteral("/home/u/Downloads")};
    EXPECT_EQ(placeShortcut(QStringLiteral("folder"), QStringLiteral("/home/u/Documents/"), home, xdg), QStringLiteral("Ctrl+Shift+O"));
    EXPECT_EQ(placeShortcut(QStringLiteral("folder"), QStringLiteral("/home/u/Desktop"), home, xdg), QStringLiteral("Ctrl+Shift+D"));
    EXPECT_EQ(placeShortcut(QStringLiteral("folder"), QStringLiteral("/home/u/Downloads"), home, xdg), QStringLiteral("Ctrl+Alt+L"));
    EXPECT_EQ(placeShortcut(QStringLiteral("folder"), home, home, xdg), QStringLiteral("Ctrl+Shift+H"));
    EXPECT_EQ(placeShortcut(QStringLiteral("volume"), QStringLiteral("/"), home, xdg), QStringLiteral("Ctrl+Shift+C"));
    EXPECT_EQ(placeShortcut(QStringLiteral("network"), QString(), home, xdg), QStringLiteral("Ctrl+Shift+K"));
    EXPECT_EQ(placeShortcut(QStringLiteral("recents"), QString(), home, xdg), QStringLiteral("Ctrl+Shift+F"));
    EXPECT_TRUE(placeShortcut(QStringLiteral("folder"), QStringLiteral("/home/u/Music"), home, xdg).isEmpty());
    // No Desktop folder: xdg-user-dirs gives the home folder, which keeps its own shortcut only.
    const QStringList noDesktop = {home, QStringLiteral("/home/u/Documents"), QStringLiteral("/home/u/Downloads")};
    EXPECT_EQ(placeShortcut(QStringLiteral("folder"), home, home, noDesktop), QStringLiteral("Ctrl+Shift+H"));
}

TEST(GoToFolder, AFileOpensItsFolderWithTheFileSelected)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString root = dir->path();
    QDir().mkpath(root + QStringLiteral("/Folder"));
    {
        QFile f(root + QStringLiteral("/Folder/notes.txt"));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("x");
    }
    ASSERT_TRUE(QFile::link(root + QStringLiteral("/gone"), root + QStringLiteral("/Folder/broken")));

    GoToTarget t = goToTarget(QUrl::fromLocalFile(root + QStringLiteral("/Folder")));
    EXPECT_EQ(t.folder, QUrl::fromLocalFile(root + QStringLiteral("/Folder"))) << "a folder opens";
    EXPECT_TRUE(t.select.isEmpty());

    t = goToTarget(QUrl::fromLocalFile(root + QStringLiteral("/Folder/notes.txt")));
    EXPECT_EQ(t.folder, QUrl::fromLocalFile(root + QStringLiteral("/Folder"))) << "a file opens its folder";
    EXPECT_EQ(t.select, QUrl::fromLocalFile(root + QStringLiteral("/Folder/notes.txt"))) << "with the file selected";

    t = goToTarget(QUrl::fromLocalFile(root + QStringLiteral("/Folder/broken")));
    EXPECT_EQ(t.select, QUrl::fromLocalFile(root + QStringLiteral("/Folder/broken"))) << "a link leading nowhere is still shown";

    t = goToTarget(QUrl::fromLocalFile(root + QStringLiteral("/missing")));
    EXPECT_TRUE(t.folder.isEmpty()) << "nothing there";

    t = goToTarget(QUrl(QStringLiteral("smb://nas/share")));
    EXPECT_EQ(t.folder, QUrl(QStringLiteral("smb://nas/share"))) << "a remote location is left to KIO";
    EXPECT_TRUE(t.select.isEmpty());
    EXPECT_TRUE(goToTarget(QUrl()).folder.isEmpty());
}

// Sidebar Favorites editing (FP-27; owner report 2026-11-07: "there is no way to pin a folder in the sidebar"): the stored
// list, adding at the insertion line, moving and the locations that are never Favorites folders.
TEST(SidebarFavorites, TheStoredListIsCleanedAndBounded)
{
    const QList<QUrl> list = NavLogic::sidebarList({QStringLiteral("file:///home/u/Projects/"), QStringLiteral("file:///home/u/Projects"),
                                                    QStringLiteral("file:///home/u/a/../Work"), QStringLiteral("sftp://host/srv/share/"),
                                                    QStringLiteral("grassfield-search:/?q=x"), QStringLiteral("trash:/"), QStringLiteral("remote:/"),
                                                    QStringLiteral("grassfield-apps:/"), QStringLiteral("relative/path"), QString()});
    EXPECT_EQ(list, (QList<QUrl>{QUrl(QStringLiteral("file:///home/u/Projects")), QUrl(QStringLiteral("file:///home/u/Work")),
                                 QUrl(QStringLiteral("sftp://host/srv/share"))}));
    EXPECT_EQ(NavLogic::sidebarList(NavLogic::sidebarStored(list)), list) << "a round trip through the settings";
    QStringList many;
    for (int i = 0; i < 100; ++i)
        many << QStringLiteral("file:///f%1").arg(i);
    EXPECT_EQ(NavLogic::sidebarList(many).size(), NavLogic::kMaxSidebarFavorites);
}

TEST(SidebarFavorites, FoldersGoWhereTheLineIsAndMove)
{
    const QUrl a(QStringLiteral("file:///a")), b(QStringLiteral("file:///b")), c(QStringLiteral("file:///c")), d(QStringLiteral("file:///d"));
    EXPECT_EQ(NavLogic::withSidebarFolders({a, b}, {c}, 1), (QList<QUrl>{a, c, b}));
    EXPECT_EQ(NavLogic::withSidebarFolders({a, b}, {c, d}, 0), (QList<QUrl>{c, d, a, b})) << "several in their order";
    EXPECT_EQ(NavLogic::withSidebarFolders({a, b}, {c}, -1), (QList<QUrl>{a, b, c})) << "no line: at the end";
    EXPECT_EQ(NavLogic::withSidebarFolders({a, b}, {QUrl(QStringLiteral("file:///a/")), c}, 0), (QList<QUrl>{c, a, b})) << "one already listed stays where it is";
    EXPECT_EQ(NavLogic::withSidebarFolders({a}, {QUrl(QStringLiteral("grassfield-tag:/Red")), QUrl(QStringLiteral("trash:/"))}, 0), QList<QUrl>{a});
    EXPECT_EQ(NavLogic::movedInSidebar({a, b, c, d}, a, 3), (QList<QUrl>{b, c, a, d})) << "down: to the gap before d";
    EXPECT_EQ(NavLogic::movedInSidebar({a, b, c, d}, d, 0), (QList<QUrl>{d, a, b, c})) << "up: to the top";
    EXPECT_EQ(NavLogic::movedInSidebar({a, b, c, d}, b, 4), (QList<QUrl>{a, c, d, b})) << "after the last";
    EXPECT_EQ(NavLogic::movedInSidebar({a, b, c, d}, b, 1), (QList<QUrl>{a, b, c, d})) << "its own gap: unchanged";
    EXPECT_EQ(NavLogic::movedInSidebar({a, b}, c, 0), (QList<QUrl>{a, b})) << "not listed: unchanged";
}
