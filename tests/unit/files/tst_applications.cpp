// Unit tests for apps/files/src/applicationslogic.h (the Applications location of Files). Fixture desktop entries in a
// temporary tree; nothing is launched. These tests pin the rules one by one, with hidden-entries.sh as the reference for the
// ones it owns. The claim that Files lists what the Apps grid lists is held by tests/shell/apps_grid_vs_files.sh, which runs
// Quickshell's own DesktopEntries, hidden-entries.sh and Model.disambiguate on ~130 fixture entries and compares the lists.
#include <gtest/gtest.h>

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QRegularExpression>
#include <QSet>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QTemporaryDir>

#include <sys/stat.h>
#include <unistd.h>

#include "applicationslogic.h"

using namespace ApplicationsLogic;

namespace
{
void write(const QString &path, const QByteArray &text)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly)) << path.toStdString();
    f.write(text);
}

QByteArray app(const QString &extra = QString(), const QString &name = QStringLiteral("x"))
{
    return QStringLiteral("[Desktop Entry]\nType=Application\nName=%1\nExec=%1\n%2\n[Desktop Action a]\nOnlyShowIn=Never;\n").arg(name, extra).toUtf8();
}

Environment envFor(const QString &home, const QString &sys)
{
    Environment env = processEnvironment();
    env.applicationDirs = {home + QStringLiteral("/applications"), sys + QStringLiteral("/applications")};
    env.currentDesktop = {QStringLiteral("Hyprland")};
    env.locales.clear();
    return env;
}

QSet<QString> ids(const QList<Entry> &list)
{
    QSet<QString> s;
    for (const Entry &e : list)
        s.insert(e.id);
    return s;
}
} // namespace

// The visibility rules of the shell's Apps grid, run on the same tree: an id the script hides is not listed, any other is.
TEST(Applications, AgreesWithTheShellsHiddenEntriesScript)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString sys = tmp.filePath(QStringLiteral("sys")), home = tmp.filePath(QStringLiteral("home"));
    const QString sa = sys + QStringLiteral("/applications/"), ha = home + QStringLiteral("/applications/");
    QStringList all;
    auto put = [&](const QString &dir, const QString &id, const QByteArray &text, bool count = true) {
        write(dir + id + QStringLiteral(".desktop"), text);
        if (count)
            all << id;
    };
    put(sa, QStringLiteral("only-hypr"), app(QStringLiteral("OnlyShowIn=Hyprland;")));
    put(sa, QStringLiteral("only-kde"), app(QStringLiteral("OnlyShowIn=KDE;")));
    put(sa, QStringLiteral("only-multi"), app(QStringLiteral("OnlyShowIn=KDE;Hyprland;")));
    put(sa, QStringLiteral("not-hypr"), app(QStringLiteral("NotShowIn=Hyprland;")));
    put(sa, QStringLiteral("not-kde"), app(QStringLiteral("NotShowIn=KDE;")));
    put(sa, QStringLiteral("plain"), app());
    put(sa, QStringLiteral("sub/nested"), app(QStringLiteral("OnlyShowIn=KDE;")), false);
    all << QStringLiteral("sub-nested");
    put(sa, QStringLiteral("shadow-a"), app(QStringLiteral("OnlyShowIn=KDE;")));
    put(ha, QStringLiteral("shadow-a"), app(), false);
    put(sa, QStringLiteral("shadow-b"), app());
    put(ha, QStringLiteral("shadow-b"), app(QStringLiteral("NotShowIn=Hyprland;")), false);
    write(sa + QStringLiteral("crlf-kde.desktop"), "[Desktop Entry]\r\nType=Application\r\nName=x\r\nOnlyShowIn=KDE;\r\n");
    write(sa + QStringLiteral("crlf-hypr.desktop"), "[Desktop Entry]\r\nType=Application\r\nName=x\r\nOnlyShowIn=Hyprland;\r\n");
    // The script reads CRLF files; Quickshell does not (such a file is not an application with a Name), so the grid does not list
    // them whatever the script says: the script's verdict only counts for entries Quickshell reads.
    write(sa + QStringLiteral("spaced-kde.desktop"), "[Desktop Entry]\nType=Application\nName=x\nOnlyShowIn = KDE;\n");
    write(sa + QStringLiteral("spaced-not.desktop"), "[Desktop Entry]\nType=Application\nName=x\nNotShowIn\t=\tHyprland;\n");
    all << QStringLiteral("spaced-kde") << QStringLiteral("spaced-not");
    write(tmp.filePath(QStringLiteral("linked/deep/x.desktop")), app(QStringLiteral("OnlyShowIn=KDE;")));
    ASSERT_TRUE(QFile::link(tmp.filePath(QStringLiteral("linked")), sa + QStringLiteral("link")));
    all << QStringLiteral("link-deep-x");
    for (const char *h : {"avahi-discover", "bssh", "bvnc", "lstopo", "org.fcitx.fcitx5-qt6-gui-wrapper"})
        put(sa, QString::fromLatin1(h), app(QStringLiteral("Categories=System;")));
    put(sa, QStringLiteral("fcitx5-configtool"), app(QStringLiteral("Categories=Settings;")));
    write(sa + QStringLiteral("foot.desktop"), "[Desktop Entry]\nType=Application\nName=Foot\nExec=foot\nCategories=System;TerminalEmulator;\n");
    write(sa + QStringLiteral("footclient.desktop"), "[Desktop Entry]\nType=Application\nName=Foot Client\nExec=footclient\nCategories=System;TerminalEmulator;\n");
    write(sa + QStringLiteral("foot-server.desktop"), "[Desktop Entry]\nType=Application\nName=Foot Server\nExec=foot --server\nCategories=System;TerminalEmulator;\n");
    write(sa + QStringLiteral("kitty.desktop"), "[Desktop Entry]\nType=Application\nName=Kitty\nExec=/usr/bin/kitty --single-instance\nCategories=System;TerminalEmulator;\n");
    write(sa + QStringLiteral("mailclient.desktop"), "[Desktop Entry]\nType=Application\nName=Mail Client\nExec=mailclient\nCategories=Network;Email;\n");
    all << QStringLiteral("foot") << QStringLiteral("footclient") << QStringLiteral("foot-server") << QStringLiteral("kitty") << QStringLiteral("mailclient");

    const QString script = QDir::cleanPath(QFileInfo(QStringLiteral(__FILE__)).absoluteDir().filePath(QStringLiteral("../../../shell/launchpad/hidden-entries.sh")));
    ASSERT_TRUE(QFileInfo::exists(script)) << script.toStdString();
    QProcess sh;
    QProcessEnvironment penv;
    penv.insert(QStringLiteral("XDG_DATA_HOME"), home);
    penv.insert(QStringLiteral("XDG_DATA_DIRS"), sys);
    penv.insert(QStringLiteral("XDG_CURRENT_DESKTOP"), QStringLiteral("Hyprland"));
    penv.insert(QStringLiteral("PATH"), QStringLiteral("/usr/bin:/bin"));
    sh.setProcessEnvironment(penv);
    sh.start(QStringLiteral("sh"), {script});
    ASSERT_TRUE(sh.waitForFinished(20000));
    QSet<QString> hidden;
    for (const QString &line : QString::fromUtf8(sh.readAllStandardOutput()).split(QLatin1Char('\n'), Qt::SkipEmptyParts))
        hidden.insert(line);
    ASSERT_GT(hidden.size(), 10);

    const QSet<QString> listed = ids(listApplications(envFor(home, sys)));
    for (const QString &id : std::as_const(all)) {
        EXPECT_EQ(listed.contains(id), !hidden.contains(id)) << id.toStdString() << (hidden.contains(id) ? " (hidden by the script)" : " (shown by the script)");
    }
    // Nothing is listed that the fixture does not hold, and a CRLF file is not read (Quickshell).
    for (const QString &id : listed)
        EXPECT_TRUE(all.contains(id)) << id.toStdString();
    EXPECT_FALSE(listed.contains(QStringLiteral("crlf-hypr")));
}

TEST(Applications, DefaultHelperIdsAreTheScriptsDefaults)
{
    const QString script = QDir::cleanPath(QFileInfo(QStringLiteral(__FILE__)).absoluteDir().filePath(QStringLiteral("../../../shell/launchpad/hidden-entries.sh")));
    QFile f(script);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    const QRegularExpressionMatch m = QRegularExpression(QStringLiteral("GRASSFIELD_HELPER_IDS-([^}]*)\\}")).match(QString::fromUtf8(f.readAll()));
    ASSERT_TRUE(m.hasMatch());
    QStringList fromScript = m.captured(1).split(QLatin1Char(' '), Qt::SkipEmptyParts);
    QStringList ours = defaultHelperIds();
    fromScript.sort();
    ours.sort();
    EXPECT_EQ(ours, fromScript);
}

TEST(Applications, OnlyApplicationsThatAreShownAreListedAndTryExecIsNotRead)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString sys = tmp.filePath(QStringLiteral("sys")), home = tmp.filePath(QStringLiteral("home"));
    const QString sa = sys + QStringLiteral("/applications/");
    write(sa + QStringLiteral("ok.desktop"), app());
    write(sa + QStringLiteral("notype.desktop"), "[Desktop Entry]\nName=x\nExec=x\n");
    write(sa + QStringLiteral("link.desktop"), "[Desktop Entry]\nType=Link\nName=x\nURL=https://example.org/\n");
    write(sa + QStringLiteral("dir.desktop"), "[Desktop Entry]\nType=Directory\nName=x\n");
    write(sa + QStringLiteral("nodisplay.desktop"), app(QStringLiteral("NoDisplay=true")));
    write(sa + QStringLiteral("nodisplay-false.desktop"), app(QStringLiteral("NoDisplay=false")));
    write(sa + QStringLiteral("hidden.desktop"), app(QStringLiteral("Hidden=true")));
    write(sa + QStringLiteral("tryexec-missing.desktop"), app(QStringLiteral("TryExec=/nonexistent/grassfield-test-program")));
    write(sa + QStringLiteral("tryexec-present.desktop"), app(QStringLiteral("TryExec=/bin/sh")));
    write(sa + QStringLiteral("tryexec-path.desktop"), app(QStringLiteral("TryExec=sh")));
    write(sa + QStringLiteral("tryexec-path-missing.desktop"), app(QStringLiteral("TryExec=grassfield-test-no-such-program")));
    write(sa + QStringLiteral("action-only.desktop"), "[Desktop Entry]\nType=Application\nName=y\n[Desktop Action x]\nNoDisplay=true\nType=Link\n");
    write(sa + QStringLiteral("readme.txt"), "not a desktop entry");
    const QSet<QString> got = ids(listApplications(envFor(home, sys)));
    // Quickshell does not read TryExec, so the grid lists an entry whose program is missing and so does Files (the desktop entry
    // specification says to hide it: a difference in the grid, reported, not copied away here).
    const QSet<QString> want = {QStringLiteral("ok"), QStringLiteral("nodisplay-false"), QStringLiteral("tryexec-missing"),
                                QStringLiteral("tryexec-present"), QStringLiteral("tryexec-path"),
                                QStringLiteral("tryexec-path-missing"), QStringLiteral("action-only")};
    EXPECT_EQ(got, want);
}

// A Choose Application panel's candidates (Environment::alsoListed) are listed whatever the grid's display rules say: KDE's
// associations offer them and the Open With submenu shows them (imv, Omarchy's image viewer, is NoDisplay=true). An entry
// that is no application with a Name, or Hidden=true (deleted), is still never listed; ids not asked for keep the grid's rules.
TEST(Applications, ACandidateIsListedWhateverTheGridsDisplayRules)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString sys = tmp.filePath(QStringLiteral("sys")), home = tmp.filePath(QStringLiteral("home"));
    const QString sa = sys + QStringLiteral("/applications/");
    write(sa + QStringLiteral("imv.desktop"), app(QStringLiteral("NoDisplay=true"), QStringLiteral("imv")));
    write(sa + QStringLiteral("other-nodisplay.desktop"), app(QStringLiteral("NoDisplay=true")));
    write(sa + QStringLiteral("elsewhere.desktop"), app(QStringLiteral("OnlyShowIn=KDE;")));
    write(sa + QStringLiteral("not-here.desktop"), app(QStringLiteral("NotShowIn=Hyprland;")));
    write(sa + QStringLiteral("deleted.desktop"), app(QStringLiteral("Hidden=true")));
    write(sa + QStringLiteral("nameless.desktop"), "[Desktop Entry]\nType=Application\nExec=x\nNoDisplay=true\n");
    write(sa + QStringLiteral("link.desktop"), "[Desktop Entry]\nType=Link\nName=x\nURL=https://example.org/\n");
    Environment env = envFor(home, sys);
    ASSERT_FALSE(env.helperIds.isEmpty());
    const QString helper = *env.helperIds.cbegin();
    write(sa + helper + QStringLiteral(".desktop"), app());
    EXPECT_EQ(ids(listApplications(env)), QSet<QString>()) << "the grid's rules: none of them is listed";
    env.alsoListed = {QStringLiteral("imv"), QStringLiteral("elsewhere"), QStringLiteral("not-here"), QStringLiteral("deleted"),
                      QStringLiteral("nameless"), QStringLiteral("link"), helper};
    const QList<Entry> got = listApplications(env);
    EXPECT_EQ(ids(got), (QSet<QString>{QStringLiteral("imv"), QStringLiteral("elsewhere"), QStringLiteral("not-here"), helper}));
    for (const Entry &e : got) {
        if (e.id == QLatin1String("imv"))
            EXPECT_EQ(e.name, QStringLiteral("imv")) << "named as its entry names it";
    }
}

TEST(Applications, SortedByNameThenIdWithNumbersByValue)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString sa = tmp.filePath(QStringLiteral("sys/applications/"));
    write(sa + QStringLiteral("b.desktop"), app(QString(), QStringLiteral("banana")));
    write(sa + QStringLiteral("a.desktop"), app(QString(), QStringLiteral("Apple")));
    write(sa + QStringLiteral("c10.desktop"), app(QString(), QStringLiteral("App 10")));
    write(sa + QStringLiteral("c2.desktop"), app(QString(), QStringLiteral("App 2")));
    write(sa + QStringLiteral("z-same.desktop"), app(QString(), QStringLiteral("Same")));
    write(sa + QStringLiteral("a-same.desktop"), app(QString(), QStringLiteral("Same")));
    const QList<Entry> list = listApplications(envFor(tmp.filePath(QStringLiteral("home")), tmp.filePath(QStringLiteral("sys"))));
    QStringList order;
    for (const Entry &e : list)
        order << e.id;
    EXPECT_EQ(order, (QStringList{QStringLiteral("c2"), QStringLiteral("c10"), QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("a-same"), QStringLiteral("z-same")}));
}

TEST(Applications, NamesAndDetailsFollowTheLocale)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString sa = tmp.filePath(QStringLiteral("sys/applications/"));
    write(sa + QStringLiteral("calc.desktop"),
          "[Desktop Entry]\nType=Application\nName=Calculator\nName[fr]=Calculatrice\nName[fr_CA]=Calculatrice canadienne\nGenericName=Calculator\n"
          "GenericName[fr]=Calculatrice de bureau\nComment=Do sums\nComment[fr]=Faire des calculs\nIcon=accessories-calculator\nExec=calc %U\nCategories=Utility;Calculator;\n");
    write(sa + QStringLiteral("pic.desktop"), "[Desktop Entry]\nType=Application\nName=Pic\nIcon=/usr/share/pixmaps/pic.png\nExec=pic\n");
    write(sa + QStringLiteral("noname.desktop"), "[Desktop Entry]\nType=Application\nExec=x\n");
    Environment env = envFor(tmp.filePath(QStringLiteral("home")), tmp.filePath(QStringLiteral("sys")));
    auto find = [](const QList<Entry> &list, const QString &id) {
        for (const Entry &e : list) {
            if (e.id == id)
                return e;
        }
        return Entry();
    };
    Entry c = find(listApplications(env), QStringLiteral("calc"));
    EXPECT_EQ(c.name, QStringLiteral("Calculator"));
    EXPECT_EQ(c.icon, QStringLiteral("accessories-calculator"));
    EXPECT_EQ(c.categories, (QStringList{QStringLiteral("Utility"), QStringLiteral("Calculator")}));
    EXPECT_EQ(c.exec, QStringLiteral("calc %U"));
    env.locales = localeCandidates(QStringLiteral("fr_FR.UTF-8"));
    EXPECT_EQ(env.locales, (QStringList{QStringLiteral("fr_FR"), QStringLiteral("fr")}));
    c = find(listApplications(env), QStringLiteral("calc"));
    EXPECT_EQ(c.name, QStringLiteral("Calculatrice"));
    EXPECT_EQ(c.genericName, QStringLiteral("Calculatrice de bureau"));
    EXPECT_EQ(c.comment, QStringLiteral("Faire des calculs"));
    env.locales = localeCandidates(QStringLiteral("fr_CA"));
    EXPECT_EQ(find(listApplications(env), QStringLiteral("calc")).name, QStringLiteral("Calculatrice canadienne"));
    // An absolute icon path is kept as written; an entry without a Name is not an application of the grid.
    EXPECT_EQ(find(listApplications(env), QStringLiteral("pic")).icon, QStringLiteral("/usr/share/pixmaps/pic.png"));
    EXPECT_TRUE(find(listApplications(env), QStringLiteral("noname")).id.isEmpty());
    EXPECT_TRUE(localeCandidates(QStringLiteral("C")).isEmpty());
    EXPECT_EQ(localeCandidates(QStringLiteral("de_DE@euro")), (QStringList{QStringLiteral("de_DE"), QStringLiteral("de")}));
}

TEST(Applications, TheUserDirectoryShadowsTheSystemOne)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    write(tmp.filePath(QStringLiteral("sys/applications/tool.desktop")), app(QString(), QStringLiteral("System tool")));
    write(tmp.filePath(QStringLiteral("home/applications/tool.desktop")), app(QString(), QStringLiteral("My tool")));
    const QList<Entry> list = listApplications(envFor(tmp.filePath(QStringLiteral("home")), tmp.filePath(QStringLiteral("sys"))));
    ASSERT_EQ(list.size(), 1);
    EXPECT_EQ(list.first().name, QStringLiteral("My tool"));
    EXPECT_EQ(list.first().path, tmp.filePath(QStringLiteral("home/applications/tool.desktop")));
}

// Model.disambiguate: Grassfield's own keeps the plain name, a reverse-DNS id names its vendor, else the generic name, else the id.
TEST(Applications, AppsOfOneNameAreToldApartLikeTheGrid)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString sa = tmp.filePath(QStringLiteral("sys/applications/"));
    write(sa + QStringLiteral("org.grassfield.Files.desktop"), app(QString(), QStringLiteral("Files")));
    write(sa + QStringLiteral("org.gnome.Nautilus.desktop"), app(QString(), QStringLiteral("Files")));
    write(sa + QStringLiteral("viewer.desktop"), app(QStringLiteral("GenericName=File viewer"), QStringLiteral("files")));
    write(sa + QStringLiteral("plain-a.desktop"), app(QString(), QStringLiteral("Twin")));
    write(sa + QStringLiteral("plain-b.desktop"), app(QString(), QStringLiteral("Twin")));
    write(sa + QStringLiteral("alone.desktop"), app(QString(), QStringLiteral("Alone")));
    QHash<QString, QString> names;
    for (const Entry &e : listApplications(envFor(tmp.filePath(QStringLiteral("home")), tmp.filePath(QStringLiteral("sys")))))
        names.insert(e.id, e.name);
    EXPECT_EQ(names.value(QStringLiteral("org.grassfield.Files")), QStringLiteral("Files"));
    EXPECT_EQ(names.value(QStringLiteral("org.gnome.Nautilus")), QStringLiteral("Files (GNOME)"));
    EXPECT_EQ(names.value(QStringLiteral("viewer")), QStringLiteral("files (File viewer)"));
    EXPECT_EQ(names.value(QStringLiteral("plain-a")), QStringLiteral("Twin (plain-a)"));
    EXPECT_EQ(names.value(QStringLiteral("plain-b")), QStringLiteral("Twin (plain-b)"));
    EXPECT_EQ(names.value(QStringLiteral("alone")), QStringLiteral("Alone"));
}

// The grid compares names with String.trim: U+FEFF is white space there (not for QString::trimmed), U+0085 is not.
TEST(Applications, NamesAreComparedWithTheGridsTrim)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString sa = tmp.filePath(QStringLiteral("sys/applications/"));
    write(sa + QStringLiteral("bom-a.desktop"), app(QString(), QStringLiteral("Twin")));
    write(sa + QStringLiteral("bom-b.desktop"), app(QString(), QString(QStringLiteral("Twin")) + QChar(0xFEFF)));
    write(sa + QStringLiteral("nel-a.desktop"), app(QString(), QStringLiteral("Pair")));
    write(sa + QStringLiteral("nel-b.desktop"), app(QString(), QString(QStringLiteral("Pair")) + QChar(0x85)));
    QHash<QString, QString> names;
    for (const Entry &e : listApplications(envFor(tmp.filePath(QStringLiteral("home")), tmp.filePath(QStringLiteral("sys")))))
        names.insert(e.id, e.name);
    EXPECT_EQ(names.value(QStringLiteral("bom-a")), QStringLiteral("Twin (bom-a)"));
    EXPECT_TRUE(names.value(QStringLiteral("bom-b")).endsWith(QStringLiteral(" (bom-b)")));
    EXPECT_EQ(names.value(QStringLiteral("nel-a")), QStringLiteral("Pair"));
    EXPECT_EQ(names.value(QStringLiteral("nel-b")), QString(QStringLiteral("Pair")) + QChar(0x85));
}

// The file is read the way Quickshell reads it (measured): nothing trimmed, the first [Desktop Entry] group, an invalid file
// masks nothing, a valid one masks the lower directory even when it is not listed.
TEST(Applications, TheFileIsReadAsQuickshellReadsIt)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString sa = tmp.filePath(QStringLiteral("sys/applications/")), ha = tmp.filePath(QStringLiteral("home/applications/"));
    write(sa + QStringLiteral("spaced-name.desktop"), "[Desktop Entry]\nType=Application\nName = x\nExec=x\n");
    write(sa + QStringLiteral("spaced-type.desktop"), "[Desktop Entry]\nType = Application\nName=x\nExec=x\n");
    write(sa + QStringLiteral("lead-nodisplay.desktop"), "[Desktop Entry]\nType=Application\nName=x\nExec=x\n  NoDisplay=true\n");
    write(sa + QStringLiteral("crlf.desktop"), "[Desktop Entry]\r\nType=Application\r\nName=x\r\nExec=x\r\n");
    write(sa + QStringLiteral("bom.desktop"), "\xEF\xBB\xBF[Desktop Entry]\nType=Application\nName=Bom\nExec=x\n");
    write(sa + QStringLiteral("twice.desktop"), "[Desktop Entry]\nType=Application\nName=Twice\n[Desktop Entry]\nNoDisplay=true\n");
    write(sa + QStringLiteral("last-wins.desktop"), "[Desktop Entry]\nType=Link\nType=Application\nName=First\nName=Second\nNoDisplay=true\nNoDisplay=false\n");
    write(sa + QStringLiteral("only-localized.desktop"), "[Desktop Entry]\nType=Application\nName[fr]=Un\nName[de]=Zwei\n");
    write(sa + QStringLiteral("trail.desktop"), "[Desktop Entry]\nType=Application\nName=Trail  \n");
    write(sa + QStringLiteral("masked.desktop"), app(QString(), QStringLiteral("System")));
    write(ha + QStringLiteral("masked.desktop"), "[Desktop Entry]\nType=Link\nName=Not an app\n");
    write(sa + QStringLiteral("hidden-mask.desktop"), app(QString(), QStringLiteral("System")));
    write(ha + QStringLiteral("hidden-mask.desktop"), app(QStringLiteral("Hidden=true")));
    write(sa + QStringLiteral(".dot.desktop"), app());
    write(sa + QStringLiteral("UPPER.DESKTOP"), app());
    write(sa + QStringLiteral("kde/foo.desktop"), app(QString(), QStringLiteral("nested")));
    write(sa + QStringLiteral("kde-foo.desktop"), app(QString(), QStringLiteral("flat")));
    QHash<QString, QString> names;
    for (const Entry &e : listApplications(envFor(tmp.filePath(QStringLiteral("home")), tmp.filePath(QStringLiteral("sys")))))
        names.insert(e.id, e.name);
    for (const char *absent : {"spaced-name", "spaced-type", "crlf", ".dot", "UPPER", "hidden-mask"})
        EXPECT_FALSE(names.contains(QString::fromLatin1(absent))) << absent;
    EXPECT_TRUE(names.contains(QStringLiteral("lead-nodisplay"))); // the key with a blank before it is not understood
    EXPECT_EQ(names.value(QStringLiteral("bom")), QStringLiteral("Bom"));
    EXPECT_EQ(names.value(QStringLiteral("twice")), QStringLiteral("Twice"));
    EXPECT_EQ(names.value(QStringLiteral("last-wins")), QStringLiteral("Second"));
    EXPECT_EQ(names.value(QStringLiteral("only-localized")), QStringLiteral("Un"));
    EXPECT_EQ(names.value(QStringLiteral("trail")), QStringLiteral("Trail  "));
    EXPECT_EQ(names.value(QStringLiteral("masked")), QStringLiteral("System"));
    EXPECT_EQ(names.value(QStringLiteral("kde-foo")), QStringLiteral("flat"));
}

// An absolute Icon= goes to the image provider only through the shell's rules: a FIFO planted as an icon hung the GUI thread.
TEST(Applications, AnIconFileMustBeASmallRegularFileUnderTheAllowedRoots)
{
    QTemporaryDir tmp, outside;
    ASSERT_TRUE(tmp.isValid() && outside.isValid());
    const QString root = QFileInfo(tmp.path()).canonicalFilePath();
    const QStringList roots = {root};
    write(tmp.filePath(QStringLiteral("ok.png")), "x");
    write(tmp.filePath(QStringLiteral("empty.png")), "");
    write(tmp.filePath(QStringLiteral("big.png")), QByteArray(2000, 'x'));
    write(outside.filePath(QStringLiteral("elsewhere.png")), "x");
    ASSERT_EQ(::mkfifo(QFile::encodeName(tmp.filePath(QStringLiteral("fifo.png"))).constData(), 0600), 0);
    ASSERT_TRUE(QFile::link(outside.filePath(QStringLiteral("elsewhere.png")), tmp.filePath(QStringLiteral("link-out.png"))));
    ASSERT_TRUE(QFile::link(tmp.filePath(QStringLiteral("ok.png")), tmp.filePath(QStringLiteral("link-in.png"))));
    EXPECT_EQ(safeIconFile(tmp.filePath(QStringLiteral("ok.png")), roots, 1000), root + QStringLiteral("/ok.png"));
    EXPECT_EQ(safeIconFile(tmp.filePath(QStringLiteral("link-in.png")), roots, 1000), root + QStringLiteral("/ok.png"));
    for (const char *refused : {"empty.png", "big.png", "fifo.png", "link-out.png", "missing.png"})
        EXPECT_EQ(safeIconFile(tmp.filePath(QString::fromLatin1(refused)), roots, 1000), QString()) << refused;
    EXPECT_EQ(safeIconFile(QStringLiteral("relative.png"), roots), QString());
    EXPECT_EQ(safeIconFile(tmp.filePath(QStringLiteral("ok.png")) + QStringLiteral("\n"), roots), QString());
    EXPECT_EQ(safeIconFile(QStringLiteral("/proc/self/environ"), roots), QString());
    EXPECT_EQ(safeIconFile(QStringLiteral("/dev/zero"), QStringList{QStringLiteral("/dev")}), QString()); // a device is no regular file
    EXPECT_TRUE(iconRoots().contains(QFileInfo(QStringLiteral("/usr")).canonicalFilePath()));
    EXPECT_FALSE(iconRoots().contains(QStringLiteral("/proc")));
}

TEST(Applications, UrlsRoundTrip)
{
    EXPECT_TRUE(isLocationUrl(locationUrl()));
    EXPECT_FALSE(isLocationUrl(QUrl::fromLocalFile(QStringLiteral("/tmp"))));
    EXPECT_FALSE(isLocationUrl(QUrl(QStringLiteral("trash:/"))));
    for (const QString &id : {QStringLiteral("firefox"), QStringLiteral("org.gnome.Calculator"), QStringLiteral("kde-foo bar"), QStringLiteral("a+b%c")})
        EXPECT_EQ(entryId(entryUrl(id)), id);
    EXPECT_EQ(entryId(QUrl::fromLocalFile(QStringLiteral("/tmp/x"))), QString());
    EXPECT_EQ(entryId(locationUrl()), QString());
}

// The Exec line as the shell's Apps.launchNow runs it: AppLaunch.stripFieldCodes on the split line, xdg-terminal-exec in front
// of a Terminal=true entry (KIO's own terminal lookup finds konsole, which Omarchy does not have: btop, nvim, cliamp failed).
TEST(Applications, TheExecLineIsSplitAndItsFieldCodesDropped)
{
    EXPECT_EQ(execArguments(QStringLiteral("btop")), QStringList{QStringLiteral("btop")});
    EXPECT_EQ(execArguments(QStringLiteral("nvim %F")), QStringList{QStringLiteral("nvim")});
    EXPECT_EQ(execArguments(QStringLiteral("env FOO=1 app --flag=%u %i x%%y")),
              (QStringList{QStringLiteral("env"), QStringLiteral("FOO=1"), QStringLiteral("app"), QStringLiteral("--flag="), QStringLiteral("x%y")}));
    EXPECT_EQ(execArguments(QStringLiteral("sh -c \"echo \\\"a b\\\" \\$HOME\"")),
              (QStringList{QStringLiteral("sh"), QStringLiteral("-c"), QStringLiteral("echo \"a b\" $HOME")}));
    EXPECT_TRUE(execArguments(QStringLiteral("")).isEmpty());
    EXPECT_TRUE(execArguments(QStringLiteral("%U")).isEmpty());
    EXPECT_EQ(execArguments(QStringLiteral("a \"\" b")), (QStringList{QStringLiteral("a"), QString(), QStringLiteral("b")}));
}

TEST(Applications, ATerminalEntryRunsBehindXdgTerminalExec)
{
    EXPECT_EQ(launchCommand(QStringLiteral("btop"), true), (QStringList{QStringLiteral("xdg-terminal-exec"), QStringLiteral("btop")}));
    EXPECT_EQ(launchCommand(QStringLiteral("cliamp %U"), true), (QStringList{QStringLiteral("xdg-terminal-exec"), QStringLiteral("cliamp")}));
    EXPECT_EQ(launchCommand(QStringLiteral("nvim %F"), false), QStringList{QStringLiteral("nvim")});
    EXPECT_TRUE(launchCommand(QStringLiteral("%f"), true).isEmpty()) << "no command, nothing to put behind the terminal";
}

// A .desktop that is a FIFO (or a link to one) froze the GUI thread in a blocking open until a timeout: it is no entry, and
// the others are listed at once.
TEST(Applications, AFifoNamedDesktopNeverBlocksTheListing)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString home = tmp.filePath(QStringLiteral("home")), sys = tmp.filePath(QStringLiteral("sys"));
    const QString ha = home + QStringLiteral("/applications/");
    write(ha + QStringLiteral("good.desktop"), app());
    ASSERT_EQ(::mkfifo(QFile::encodeName(ha + QStringLiteral("fifo.desktop")).constData(), 0600), 0);
    ASSERT_TRUE(QFile::link(ha + QStringLiteral("fifo.desktop"), ha + QStringLiteral("link.desktop")));
    QDir().mkpath(sys + QStringLiteral("/applications"));
    QElapsedTimer timer;
    timer.start();
    const QList<Entry> list = listApplications(envFor(home, sys));
    EXPECT_LT(timer.elapsed(), 3000);
    EXPECT_EQ(ids(list), QSet<QString>{QStringLiteral("good")});
}

// A folder link to a huge tree (a link to /usr took 33 s): the folders walked are counted, the walk ends at the limit.
TEST(Applications, AFolderLinkToAHugeTreeEndsAtTheFolderLimit)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString home = tmp.filePath(QStringLiteral("home")), sys = tmp.filePath(QStringLiteral("sys"));
    const QString wide = tmp.filePath(QStringLiteral("wide"));
    for (int i = 0; i < 6000; i++)
        ASSERT_TRUE(QDir().mkpath(wide + QStringLiteral("/d%1").arg(i, 5, 10, QLatin1Char('0'))));
    write(wide + QStringLiteral("/d00000/first.desktop"), app());
    write(wide + QStringLiteral("/d05999/last.desktop"), app());
    QDir().mkpath(home + QStringLiteral("/applications"));
    ASSERT_TRUE(QFile::link(wide, home + QStringLiteral("/applications/deep")));
    QDir().mkpath(sys + QStringLiteral("/applications"));
    QElapsedTimer timer;
    timer.start();
    const QList<Entry> list = listApplications(envFor(home, sys));
    EXPECT_LT(timer.elapsed(), 10000);
    EXPECT_TRUE(ids(list).contains(QStringLiteral("deep-d00000-first")));
    EXPECT_FALSE(ids(list).contains(QStringLiteral("deep-d05999-last"))) << "folders past the limit are not walked";
}

namespace
{
// A tree whose walk takes a while: 6000 folders under a link in an applications folder (what a link to / does, smaller).
Environment slowEnvironment(const QTemporaryDir &tmp)
{
    const QString home = tmp.filePath(QStringLiteral("home")), sys = tmp.filePath(QStringLiteral("sys")), wide = tmp.filePath(QStringLiteral("wide"));
    for (int i = 0; i < 6000; i++)
        QDir().mkpath(wide + QStringLiteral("/d%1").arg(i, 5, 10, QLatin1Char('0')));
    write(wide + QStringLiteral("/d00000/first.desktop"), app());
    QDir().mkpath(home + QStringLiteral("/applications"));
    QFile::link(wide, home + QStringLiteral("/applications/deep"));
    QDir().mkpath(sys + QStringLiteral("/applications"));
    return envFor(home, sys);
}
} // namespace

// The list is built on a thread and handed to the caller on the GUI thread.
TEST(Applications, TheListBuiltOnAThreadReachesTheCaller)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const Environment env = slowEnvironment(tmp);
    QSet<QString> got;
    bool called = false;
    startListing(env, [&](const QList<Entry> &list) {
        got = ids(list);
        called = true;
    });
    QElapsedTimer timer;
    timer.start();
    while (!called && timer.elapsed() < 20000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
    ASSERT_TRUE(called);
    EXPECT_TRUE(got.contains(QStringLiteral("deep-d00000-first")));
    EXPECT_EQ(runningListings(), 0);
}

// Quit during a slow walk is clean: waitForListings (aboutToQuit) returns once the thread has ended, no thread is left, and the
// answer, which nobody wants any more, is not delivered afterwards.
TEST(Applications, QuitDuringASlowWalkWaitsForItAndIsClean)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const Environment env = slowEnvironment(tmp);
    bool called = false;
    startListing(env, [&](const QList<Entry> &) { called = true; });
    EXPECT_EQ(runningListings(), 1);
    EXPECT_TRUE(waitForListings(20000));
    EXPECT_EQ(runningListings(), 0);
    QCoreApplication::processEvents(QEventLoop::AllEvents, 100);
    EXPECT_FALSE(called);
    // Nothing running: an immediate, true answer.
    EXPECT_TRUE(waitForListings(0));
}

// Default applications (owner report 2026-11-07): the Grassfield session's own list, grassfield-mimeapps.list, which the XDG MIME
// applications specification reads before mimeapps.list in a session whose XDG_CURRENT_DESKTOP names Grassfield.
TEST(DefaultApps, TheSessionIsToldByItsDesktopNames)
{
    EXPECT_TRUE(DefaultApps::grassfieldDesktop(QStringLiteral("Grassfield:Hyprland")));
    EXPECT_TRUE(DefaultApps::grassfieldDesktop(QStringLiteral("Hyprland:grassfield")));
    EXPECT_FALSE(DefaultApps::grassfieldDesktop(QStringLiteral("Hyprland")));
    EXPECT_FALSE(DefaultApps::grassfieldDesktop(QStringLiteral("GrassfieldDev")));
    EXPECT_FALSE(DefaultApps::grassfieldDesktop(QString()));
}

TEST(DefaultApps, AChoiceIsWrittenInItsGroupAndEveryOtherLineStays)
{
    const QString user = QStringLiteral("# mine\n[Added Associations]\nimage/png=gimp.desktop;\n\n[Default Applications]\ntext/plain=nvim.desktop;\nimage/png=imv.desktop;other.desktop;\nimage/png=late.desktop\n\n[Removed Associations]\nimage/gif=x.desktop;\n");
    EXPECT_EQ(DefaultApps::defaults(user).value(QStringLiteral("image/png")), QStringLiteral("imv.desktop")) << "the first of the list, the first key";
    EXPECT_FALSE(DefaultApps::defaults(user).contains(QStringLiteral("image/gif"))) << "another group";
    const QString changed = DefaultApps::withDefault(user, QStringLiteral("image/png"), QStringLiteral("org.grassfield.Preview.desktop"));
    EXPECT_EQ(changed, QStringLiteral("# mine\n[Added Associations]\nimage/png=gimp.desktop;\n\n[Default Applications]\ntext/plain=nvim.desktop;\nimage/png=org.grassfield.Preview.desktop;\n\n[Removed Associations]\nimage/gif=x.desktop;\n"));
    const QString added = DefaultApps::withDefault(user, QStringLiteral("application/pdf"), QStringLiteral("org.grassfield.Preview.desktop"));
    EXPECT_TRUE(added.contains(QStringLiteral("image/png=late.desktop\napplication/pdf=org.grassfield.Preview.desktop;\n\n[Removed Associations]")));
    EXPECT_EQ(DefaultApps::withDefault(QString(), QStringLiteral("image/png"), QStringLiteral("a.desktop")), QStringLiteral("[Default Applications]\nimage/png=a.desktop;\n"));
    EXPECT_EQ(DefaultApps::withDefault(QStringLiteral("[Added Associations]\nx/y=b.desktop;"), QStringLiteral("image/png"), QStringLiteral("a.desktop")),
              QStringLiteral("[Added Associations]\nx/y=b.desktop;\n\n[Default Applications]\nimage/png=a.desktop;\n"));
    // Nothing that is not a type or a desktop id is ever written.
    for (const auto &bad : {qMakePair(QStringLiteral("image/png\n[x]"), QStringLiteral("a.desktop")), qMakePair(QStringLiteral("image/png"), QStringLiteral("a.desktop\nimage/gif=b.desktop")),
                            qMakePair(QStringLiteral("image"), QStringLiteral("a.desktop")), qMakePair(QStringLiteral("image/png"), QStringLiteral("../a.desktop"))})
        EXPECT_EQ(DefaultApps::withDefault(user, bad.first, bad.second), user);
}

TEST(DefaultApps, SeedsNeverReplaceTheUsersOwnChoices)
{
    const QList<QPair<QString, QString>> seeds = {{QStringLiteral("image/png"), QStringLiteral("org.grassfield.Preview.desktop")},
                                                  {QStringLiteral("inode/directory"), QStringLiteral("org.grassfield.Files.desktop")}};
    const QString mine = QStringLiteral("[Default Applications]\nimage/png=gimp.desktop;\n");
    EXPECT_EQ(DefaultApps::withSeeds(mine, seeds), QStringLiteral("[Default Applications]\nimage/png=gimp.desktop;\ninode/directory=org.grassfield.Files.desktop;\n"));
    const QString seeded = DefaultApps::withSeeds(QString(), seeds);
    EXPECT_EQ(DefaultApps::withSeeds(seeded, seeds), seeded) << "a second run changes nothing";
}

TEST(DefaultApps, PreviewIsThePicturesAndPdfDefaultAndFilesTheFoldersOne)
{
    const QString preview = QStringLiteral("[Desktop Entry]\nType=Application\nName=Preview\nMimeType=image/png;image/jpeg;application/pdf;text/plain;text/html;video/mp4;audio/flac;\n[Desktop Action x]\nMimeType=image/gif;\n");
    EXPECT_EQ(DefaultApps::desktopMimeTypes(preview).size(), 7);
    EXPECT_EQ(DefaultApps::seededTypes(QStringLiteral("org.grassfield.Preview.desktop"), DefaultApps::desktopMimeTypes(preview)),
              (QStringList{QStringLiteral("image/png"), QStringLiteral("image/jpeg"), QStringLiteral("application/pdf")}));
    EXPECT_EQ(DefaultApps::seededTypes(QStringLiteral("org.grassfield.Files.desktop"), {QStringLiteral("inode/directory")}), QStringList{QStringLiteral("inode/directory")});
    EXPECT_TRUE(DefaultApps::seededTypes(QStringLiteral("org.grassfield.Memos.desktop"), {QStringLiteral("text/plain")}).isEmpty());
}

// The session start's seeding on a scratch tree: the Grassfield apps' types are added to the session's list where it has no
// entry, the user's entries and the Omarchy session's mimeapps.list are left alone, and a second run writes nothing.
TEST(DefaultApps, TheSessionStartSeedsItsOwnListOnly)
{
    QTemporaryDir dir(QDir(qEnvironmentVariableIsEmpty("GRASSFIELD_TEST_TMP") ? QDir::tempPath() : qEnvironmentVariable("GRASSFIELD_TEST_TMP")).filePath(QStringLiteral("seed-XXXXXX")));
    ASSERT_TRUE(dir.isValid());
    const QString config = dir.filePath(QStringLiteral("config"));
    const QString user = dir.filePath(QStringLiteral("data/applications"));
    const QString system = dir.filePath(QStringLiteral("usr/applications"));
    ASSERT_TRUE(QDir().mkpath(config) && QDir().mkpath(user) && QDir().mkpath(system));
    const auto write = [](const QString &path, const QByteArray &text) {
        QFile f(path);
        return f.open(QIODevice::WriteOnly) && f.write(text) == text.size();
    };
    ASSERT_TRUE(write(system + QStringLiteral("/org.grassfield.Preview.desktop"), "[Desktop Entry]\nType=Application\nMimeType=image/png;application/pdf;text/plain;\n"));
    ASSERT_TRUE(write(system + QStringLiteral("/org.grassfield.Files.desktop"), "[Desktop Entry]\nType=Application\nMimeType=inode/directory;\n"));
    // A user's own copy of Files' entry comes first in the lookup: it is the one read.
    ASSERT_TRUE(write(user + QStringLiteral("/org.grassfield.Files.desktop"), "[Desktop Entry]\nType=Application\nMimeType=x-test/none;\n"));
    const QByteArray omarchy = "[Default Applications]\nimage/png=imv.desktop;\ninode/directory=org.gnome.Nautilus.desktop;\n";
    ASSERT_TRUE(write(config + QStringLiteral("/mimeapps.list"), omarchy));
    ASSERT_TRUE(write(config + QStringLiteral("/grassfield-mimeapps.list"), "[Default Applications]\napplication/pdf=okular.desktop;\n"));

    EXPECT_TRUE(DefaultApps::seedSessionDefaults(config, {user, system}));
    QFile list(config + QStringLiteral("/grassfield-mimeapps.list"));
    ASSERT_TRUE(list.open(QIODevice::ReadOnly));
    EXPECT_EQ(list.readAll(), QByteArray("[Default Applications]\napplication/pdf=okular.desktop;\nimage/png=org.grassfield.Preview.desktop;\n"));
    list.close();
    QFile generic(config + QStringLiteral("/mimeapps.list"));
    ASSERT_TRUE(generic.open(QIODevice::ReadOnly));
    EXPECT_EQ(generic.readAll(), omarchy) << "the Omarchy session's list is never touched";
    EXPECT_FALSE(DefaultApps::seedSessionDefaults(config, {user, system})) << "nothing new: not written again";
    EXPECT_FALSE(DefaultApps::seedSessionDefaults(QStringLiteral("relative"), {user, system}));
}
