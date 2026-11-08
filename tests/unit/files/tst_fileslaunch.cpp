// Files opens apps the Gatekeeper way (ADR-0011 amendment 2026-11-08; the owner's report "impossible de lancer une AppImage"):
// real programs opened through FilesApp::open in a scratch home, offscreen, with the sheets answered by a responder
// (KioPrompts::setResponder) and no real download (the browsers' mark is written here). The programs are
// tests/unit/files/launch_fixture.cpp, built by apps/files/build-direct.sh --tests into FILES_LAUNCH_FIXTURES: a tiny ELF that
// leaves "launched" in its working folder, the same as a fake AppImage (the AppImage magic written into its header), one that
// fails as an AppImage without FUSE 2 does, one whose library is missing. Part of files-kio-tests (its main makes the home).
#include "filesapp.h"
#include "kioprompts.h"
#include "launchguard.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSysInfo>
#include <QTemporaryDir>
#include <QThread>
#include <QVariantMap>

#include <gtest/gtest.h>

#include <sys/stat.h>
#include <sys/xattr.h>

namespace
{
bool waitFor(const std::function<bool()> &done, int ms = 5000)
{
    QDeadlineTimer deadline(ms);
    while (!done() && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(5);
    }
    return done();
}

void settle(int ms)
{
    waitFor([] { return false; }, ms);
}

QString fixture(const char *name)
{
    return QDir(QStringLiteral(FILES_LAUNCH_FIXTURES)).filePath(QLatin1String(name));
}

unsigned modeOf(const QString &path)
{
    struct stat st{};
    return ::stat(QFile::encodeName(path).constData(), &st) == 0 ? unsigned(st.st_mode & 07777) : 0xffffffffu;
}

// What Files asked (the sheets) and told (the banner), and how the sheets are answered.
struct Session {
    explicit Session(FilesApp &app)
    {
        auto *prompts = qobject_cast<KioPrompts *>(app.prompts());
        prompts->setResponder([this](const QVariantMap &request) {
            asked << request;
            return QVariantMap{{QStringLiteral("button"), answer}};
        });
        QObject::connect(&app, &FilesApp::operationFailed, &app, [this](const QString &m) {
            told << m;
        });
    }
    QList<QVariantMap> ofKind(const QString &kind) const
    {
        QList<QVariantMap> out;
        for (const QVariantMap &r : asked) {
            if (r.value(QStringLiteral("kind")).toString() == kind)
                out << r;
        }
        return out;
    }
    QList<QVariantMap> asked;
    QStringList told;
    QString answer = QStringLiteral("cancel");
};

class FilesLaunch : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        if (!QFileInfo(fixture("probe")).isExecutable())
            GTEST_SKIP() << "the launch fixtures are missing (apps/files/build-direct.sh --tests)";
        m_session = qgetenv("GRASSFIELD_SESSION");
        qunsetenv("GRASSFIELD_SESSION"); // no uwsm-app scope from a scratch runtime folder
        qunsetenv("GRASSFIELD_FILES_NO_LAUNCH");
    }
    void TearDown() override
    {
        qunsetenv("GRASSFIELD_FILES_NO_LAUNCH");
        if (!m_session.isNull())
            qputenv("GRASSFIELD_SESSION", m_session);
        // A program that stays a moment ends before the folder goes.
        settle(100);
    }
    QString d(const QString &name) const { return m_dir.filePath(name); }

    // A copy of a fixture at `name` with `mode`; `appImage` writes the AppImage magic at offset 8 of its ELF header.
    QString place(const char *fixtureName, const QString &name, unsigned mode, bool appImage = false)
    {
        const QString path = d(name);
        QDir().mkpath(QFileInfo(path).absolutePath());
        QFile::remove(path);
        EXPECT_TRUE(QFile::copy(fixture(fixtureName), path));
        if (appImage) {
            QFile f(path);
            EXPECT_TRUE(f.open(QIODevice::ReadWrite));
            f.seek(8);
            f.write("AI\x02", 3);
        }
        EXPECT_EQ(::chmod(QFile::encodeName(path).constData(), mode), 0);
        return path;
    }
    // A browser's download mark (Chromium and Firefox write both); false without user extended attributes here.
    static bool markDownloaded(const QString &path)
    {
        const QByteArray origin = "https://downloads.example.org/files/Tool.AppImage?token=secret";
        const QByteArray referrer = "https://www.example.org/download";
        const QByteArray p = QFile::encodeName(path);
        return ::setxattr(p.constData(), "user.xdg.origin.url", origin.constData(), size_t(origin.size()), 0) == 0
            && ::setxattr(p.constData(), "user.xdg.referrer.url", referrer.constData(), size_t(referrer.size()), 0) == 0;
    }
    static QList<QUrl> urls(const QString &path) { return {QUrl::fromLocalFile(path)}; }

    QTemporaryDir m_dir{QDir(qEnvironmentVariableIsEmpty("GRASSFIELD_TEST_TMP") ? QDir::tempPath() : qEnvironmentVariable("GRASSFIELD_TEST_TMP"))
                            .filePath(QStringLiteral("fileslaunch-XXXXXX"))};
    QByteArray m_session;
};
} // namespace

// The owner's report: a native program opens, without a sheet when it was made here, in its own folder.
TEST_F(FilesLaunch, ANativeProgramRunsInItsFolder)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString tool = place("probe", QStringLiteral("Games/tool"), 0755);
    app.open(urls(tool));
    EXPECT_TRUE(waitFor([&] { return QFileInfo::exists(d(QStringLiteral("Games/launched"))); })) << "it ran, in its own folder";
    settle(1200);
    EXPECT_TRUE(s.asked.isEmpty()) << "made here and executable: no sheet, no alert";
    EXPECT_TRUE(s.told.isEmpty()) << s.told.join(QLatin1Char('|')).toStdString();
}

// DT-10 as amended: a downloaded AppImage that is not executable runs only after Open in the sheet, which allows it to run;
// approved and unchanged it runs without a sheet; changed, it asks again.
TEST_F(FilesLaunch, Dt10ADownloadedAppImageRunsOnlyAfterOpen)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString path = place("probe", QStringLiteral("Downloads/Tool.AppImage"), 0644, true);
    if (!markDownloaded(path))
        GTEST_SKIP() << "no user extended attributes in " << m_dir.path().toStdString();
    const QString mark = d(QStringLiteral("Downloads/launched"));

    s.answer = QStringLiteral("cancel");
    app.open(urls(path));
    ASSERT_TRUE(waitFor([&] { return !s.ofKind(QStringLiteral("openProgram")).isEmpty(); }));
    const QVariantMap sheet = s.ofKind(QStringLiteral("openProgram")).first();
    EXPECT_EQ(sheet.value(QStringLiteral("name")).toString(), QStringLiteral("Tool.AppImage"));
    EXPECT_EQ(sheet.value(QStringLiteral("what")).toString(), QStringLiteral("app"));
    EXPECT_TRUE(sheet.value(QStringLiteral("downloaded")).toBool());
    EXPECT_EQ(sheet.value(QStringLiteral("host")).toString(), QStringLiteral("downloads.example.org")) << "a host only: no path, no token";
    EXPECT_TRUE(sheet.value(QStringLiteral("allowRun")).toBool());
    EXPECT_FALSE(sheet.value(QStringLiteral("copy")).toBool());
    settle(1500);
    EXPECT_FALSE(QFileInfo::exists(mark)) << "Cancel: nothing ran";
    EXPECT_EQ(modeOf(path), 0644u) << "Cancel: nothing changed";

    s.answer = QStringLiteral("open");
    app.open(urls(path));
    EXPECT_TRUE(waitFor([&] { return QFileInfo::exists(mark); })) << "Open: it runs";
    EXPECT_EQ(modeOf(path), 0744u) << "Open allowed it to run (u+x only)";
    EXPECT_TRUE(LaunchGuard::inspect(QUrl::fromLocalFile(path)).approved);
    EXPECT_EQ(s.ofKind(QStringLiteral("openProgram")).size(), 2);

    // Approved and unchanged: no sheet.
    QFile::remove(mark);
    app.open(urls(path));
    EXPECT_TRUE(waitFor([&] { return QFileInfo::exists(mark); }));
    EXPECT_EQ(s.ofKind(QStringLiteral("openProgram")).size(), 2) << "never asked again for an approved, unchanged file";

    // Changed: asked again (and canceled here).
    QFile::remove(mark);
    {
        // ETXTBSY while the last run has not ended yet (it leaves its mark just before it ends).
        // (waitFor asks once more after the loop: the open is remembered, never repeated on an open file.)
        QFile f(path);
        bool opened = false;
        ASSERT_TRUE(waitFor([&f, &opened] { return opened || (opened = f.open(QIODevice::WriteOnly | QIODevice::Append)); }))
            << f.errorString().toStdString();
        f.write("changed");
    }
    s.answer = QStringLiteral("cancel");
    app.open(urls(path));
    EXPECT_TRUE(waitFor([&] { return s.ofKind(QStringLiteral("openProgram")).size() == 3; }));
    settle(1200);
    EXPECT_FALSE(QFileInfo::exists(mark));
    settle(1200);
}

// A symbolic link follows its target's trust: a link to a downloaded program asks; one named as a document is refused.
TEST_F(FilesLaunch, ALinkFollowsItsTargetsTrust)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString target = place("probe", QStringLiteral("Downloads/Tool.AppImage"), 0755, true);
    if (!markDownloaded(target))
        GTEST_SKIP() << "no user extended attributes in " << m_dir.path().toStdString();
    const QString link = d(QStringLiteral("Desktop/Tool"));
    QDir().mkpath(d(QStringLiteral("Desktop")));
    ASSERT_TRUE(QFile::link(target, link));
    app.open(urls(link));
    ASSERT_TRUE(waitFor([&] { return !s.ofKind(QStringLiteral("openProgram")).isEmpty(); }));
    EXPECT_TRUE(s.ofKind(QStringLiteral("openProgram")).first().value(QStringLiteral("downloaded")).toBool());
    EXPECT_EQ(s.ofKind(QStringLiteral("openProgram")).first().value(QStringLiteral("name")).toString(), QStringLiteral("Tool"));
    const QString disguised = d(QStringLiteral("Desktop/Invoice.pdf"));
    ASSERT_TRUE(QFile::link(target, disguised));
    app.open(urls(disguised));
    settle(1200);
    EXPECT_FALSE(QFileInfo::exists(d(QStringLiteral("Downloads/launched"))));
    ASSERT_FALSE(s.told.isEmpty());
    EXPECT_TRUE(s.told.last().contains(QStringLiteral("look like a document"))) << s.told.last().toStdString();
    EXPECT_EQ(s.ofKind(QStringLiteral("openProgram")).size(), 1) << "the disguised link is refused before any sheet";
}

// A start that fails gets a plain alert (a sheet with OK): FUSE 2 missing, a missing library; another computer's program is
// refused before it starts. A program that keeps running past the first second gets nothing.
TEST_F(FilesLaunch, AStartThatFailsGetsAPlainAlert)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    // pacman as the test sets it: fuse2 is not installed (pacman -Qq exits 1).
    const QString bin = d(QStringLiteral("bin"));
    QDir().mkpath(bin);
    {
        QFile pacman(QDir(bin).filePath(QStringLiteral("pacman")));
        ASSERT_TRUE(pacman.open(QIODevice::WriteOnly));
        pacman.write("#!/bin/sh\nexit 1\n");
    }
    ASSERT_EQ(::chmod(QFile::encodeName(QDir(bin).filePath(QStringLiteral("pacman"))).constData(), 0755), 0);
    const QByteArray path = qgetenv("PATH");
    qputenv("PATH", QFile::encodeName(bin) + ':' + path);

    app.open(urls(place("fuse", QStringLiteral("Old.AppImage"), 0755, true)));
    ASSERT_TRUE(waitFor([&] { return !s.ofKind(QStringLiteral("notice")).isEmpty(); }));
    EXPECT_EQ(s.ofKind(QStringLiteral("notice")).last().value(QStringLiteral("title")).toString(), QStringLiteral("This AppImage needs a system component (fuse2)."));
    EXPECT_TRUE(s.ofKind(QStringLiteral("notice")).last().value(QStringLiteral("text")).toString().contains(QStringLiteral("“Old.AppImage”")));
    qputenv("PATH", path);

    app.open(urls(place("needs-library", QStringLiteral("Needy"), 0755)));
    ASSERT_TRUE(waitFor([&] { return s.ofKind(QStringLiteral("notice")).size() == 2; }));
    const QVariantMap missing = s.ofKind(QStringLiteral("notice")).last();
    EXPECT_EQ(missing.value(QStringLiteral("title")).toString(), QStringLiteral("“Needy” can’t be opened."));
    EXPECT_TRUE(missing.value(QStringLiteral("text")).toString().contains(QStringLiteral("libgflaunchmissing.so"))) << missing.value(QStringLiteral("text")).toString().toStdString();
    EXPECT_FALSE(QFileInfo::exists(d(QStringLiteral("launched")))) << "the loader stopped it before main";

    // Another computer's program: refused before it starts (its header's machine).
    const QString foreign = place("probe", QStringLiteral("arm-tool"), 0755);
    {
        QFile f(foreign);
        ASSERT_TRUE(f.open(QIODevice::ReadWrite));
        f.seek(18);
        f.write(QSysInfo::currentCpuArchitecture() == QLatin1String("arm64") ? QByteArray("\x3e\x00", 2) : QByteArray("\xb7\x00", 2));
    }
    app.open(urls(foreign));
    ASSERT_FALSE(s.told.isEmpty());
    EXPECT_EQ(s.told.last(), QStringLiteral("“arm-tool” can’t be opened because it isn’t made for this computer."));

    // A program that keeps running past the first second: no alert.
    const int notices = int(s.ofKind(QStringLiteral("notice")).size());
    app.open(urls(place("stay", QStringLiteral("Stays/stay"), 0755)));
    EXPECT_TRUE(waitFor([&] { return QFileInfo::exists(d(QStringLiteral("Stays/launched"))); }));
    settle(2500);
    EXPECT_EQ(int(s.ofKind(QStringLiteral("notice")).size()), notices);
}

// A script opens in the text editor (blocked here by the test switch, so nothing starts) and never runs by opening; Open With
// lists Terminal for an executable script only, and a downloaded one asks before it runs there.
TEST_F(FilesLaunch, ScriptsOpenInTheEditorAndRunOnlyInTerminal)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString script = d(QStringLiteral("run.sh"));
    {
        QFile f(script);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("#!/bin/sh\ntouch \"$(dirname \"$0\")/script-ran\"\n");
    }
    ASSERT_EQ(::chmod(QFile::encodeName(script).constData(), 0755), 0);
    qputenv("GRASSFIELD_FILES_NO_LAUNCH", "1");
    app.open(urls(script));
    settle(1500);
    EXPECT_FALSE(QFileInfo::exists(d(QStringLiteral("script-ran")))) << "opening a script never runs it";
    EXPECT_TRUE(s.ofKind(QStringLiteral("openProgram")).isEmpty());

    auto lastEntry = [&app](const QString &path, bool withTerminal) {
        const QVariantList apps = app.applicationsFor(urls(path), withTerminal);
        return apps.isEmpty() ? QVariantMap() : apps.last().toMap();
    };
    EXPECT_EQ(lastEntry(script, true).value(QStringLiteral("id")).toString(), QStringLiteral("grassfield:terminal"));
    EXPECT_TRUE(lastEntry(script, true).value(QStringLiteral("terminal")).toBool());
    EXPECT_NE(lastEntry(script, false).value(QStringLiteral("id")).toString(), QStringLiteral("grassfield:terminal")) << "not in Get Info's list";
    ASSERT_EQ(::chmod(QFile::encodeName(script).constData(), 0644), 0);
    EXPECT_NE(lastEntry(script, true).value(QStringLiteral("id")).toString(), QStringLiteral("grassfield:terminal")) << "only an executable script";
    ASSERT_EQ(::chmod(QFile::encodeName(script).constData(), 0755), 0);

    // Downloaded: Open With > Terminal asks first (the switch blocks it before the sheet; without it the sheet comes first).
    if (!markDownloaded(script))
        GTEST_SKIP() << "no user extended attributes in " << m_dir.path().toStdString();
    qunsetenv("GRASSFIELD_FILES_NO_LAUNCH");
    s.answer = QStringLiteral("cancel");
    app.openWith(QStringLiteral("grassfield:terminal"), urls(script));
    ASSERT_TRUE(waitFor([&] { return !s.ofKind(QStringLiteral("openProgram")).isEmpty(); }));
    EXPECT_EQ(s.ofKind(QStringLiteral("openProgram")).first().value(QStringLiteral("what")).toString(), QStringLiteral("script"));
    settle(500);
    EXPECT_FALSE(QFileInfo::exists(d(QStringLiteral("script-ran"))));
}

// Nothing runs from a server; Windows and Java programs and another system's app are explained in a sheet, never run.
TEST_F(FilesLaunch, RemoteAndForeignItemsAreExplainedNeverRun)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    app.open({QUrl(QStringLiteral("sftp://files.example.invalid/home/u/Tool.AppImage"))});
    ASSERT_FALSE(s.told.isEmpty());
    EXPECT_EQ(s.told.last(), QStringLiteral("“Tool.AppImage” can’t be opened from here. Copy it to a folder on this computer first."));

    const QString dmg = d(QStringLiteral("Slack-4.36.140-macOS.dmg"));
    {
        QFile f(dmg);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    }
    app.open(urls(dmg));
    ASSERT_TRUE(waitFor([&] { return !s.ofKind(QStringLiteral("foreignApp")).isEmpty(); }));
    EXPECT_EQ(s.ofKind(QStringLiteral("foreignApp")).first().value(QStringLiteral("name")).toString(), QStringLiteral("Slack-4.36.140-macOS.dmg"));

    const QString exe = d(QStringLiteral("setup.exe"));
    {
        QFile f(exe);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(QByteArray("MZ\x90\x00", 4) + QByteArray(200, '\0'));
    }
    app.open(urls(exe));
    ASSERT_TRUE(waitFor([&] { return !s.ofKind(QStringLiteral("foreignProgram")).isEmpty(); }));
    EXPECT_EQ(s.ofKind(QStringLiteral("foreignProgram")).first().value(QStringLiteral("platform")).toString(), QStringLiteral("windows"));

    const QString jar = d(QStringLiteral("tool.jar"));
    {
        QFile f(jar);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(QByteArray("PK\x03\x04", 4) + QByteArray(60, '\0'));
    }
    app.open(urls(jar));
    ASSERT_TRUE(waitFor([&] { return s.ofKind(QStringLiteral("foreignProgram")).size() == 2; }));
    EXPECT_EQ(s.ofKind(QStringLiteral("foreignProgram")).last().value(QStringLiteral("platform")).toString(), QStringLiteral("java"));
    EXPECT_TRUE(s.ofKind(QStringLiteral("openProgram")).isEmpty());
}
