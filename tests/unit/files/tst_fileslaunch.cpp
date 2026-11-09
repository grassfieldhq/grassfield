// Files opens apps the Gatekeeper way (ADR-0011 amendment 2026-11-08; the owner's report "impossible de lancer une AppImage";
// the security review of 0c51550e): real programs opened through FilesApp::open in a scratch home, offscreen, with the sheets
// answered by a responder (KioPrompts::setResponder) and no real download (the browsers' mark is written here). The programs
// are tests/unit/files/launch_fixture.cpp, built by apps/files/build-direct.sh --tests into FILES_LAUNCH_FIXTURES: a tiny ELF
// that leaves "<its name>.launched" in its working folder (the home folder: Files starts programs there), the same as a fake
// AppImage (the AppImage magic written into its header), one that fails as an AppImage without FUSE 2 does, one whose library
// is missing. java, xdg-terminal-exec, pacman and a Windows handler are scripts of the test that record what they were given.
// Part of files-kio-tests (its main makes the home).
#include "archivejob.h"
#include "filesapp.h"
#include "foldermodel.h"
#include "kioprompts.h"
#include "launchguard.h"
#include "programlaunch.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QStandardPaths>
#include <QSysInfo>
#include <QTemporaryDir>
#include <QThread>
#include <QVariantMap>

#include <KService>
#include <KSycoca>

#include <gtest/gtest.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

// The tests' own access to hooks the app never sets (friends of FilesApp, ArchiveJob and ProgramLaunch::ApproveHooks): the run
// plan, the number of entries Expand may mark, and approvals that report ExecIgnored as a FAT mount does.
class FilesAppTestAccess
{
public:
    static void adjustRunPlan(FilesApp &app, const std::function<void(LaunchGuard::RunPlan &)> &adjust) { app.m_runPlanAdjuster = adjust; }
};

class ArchiveJobTestAccess
{
public:
    static void setMarkCap(qint64 cap) { ArchiveJob::s_markCap = cap; }
};

class ProgramLaunchTestAccess
{
public:
    static void reportExecIgnored(int times) { ProgramLaunch::ApproveHooks::s_execIgnored = times; }
};

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

QByteArray attributeOf(const QString &path, const char *name)
{
    char value[4096];
    const ssize_t n = ::getxattr(QFile::encodeName(path).constData(), name, value, sizeof value);
    return n > 0 ? QByteArray(value, int(n)) : QByteArray();
}

// The mark a fixture leaves in the home folder (its working folder) when it runs.
QString mark(const QString &programName)
{
    return QDir(QDir::homePath()).filePath(programName + QStringLiteral(".launched"));
}

QStringList lines(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return {};
    return QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'), Qt::SkipEmptyParts);
}

// What Files asked (the sheets) and told (the banner), and how the sheets are answered. `before` runs before each answer (a
// file that changes while its sheet is open).
struct Session {
    explicit Session(FilesApp &app)
    {
        auto *prompts = qobject_cast<KioPrompts *>(app.prompts());
        prompts->setResponder([this](const QVariantMap &request) {
            asked << request;
            if (before)
                before(request);
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
    std::function<void(const QVariantMap &)> before;
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
        m_path = qgetenv("PATH");
        qunsetenv("GRASSFIELD_SESSION"); // no uwsm-app scope from a scratch runtime folder
        qunsetenv("GRASSFIELD_FILES_NO_LAUNCH");
    }
    void TearDown() override
    {
        ArchiveJobTestAccess::setMarkCap(0);
        ProgramLaunchTestAccess::reportExecIgnored(0);
        // Folders of mode 0100 or 0300 from an archive: opened up so that the scratch folder can go.
        LaunchGuard::openTree(m_dir.path());
        qunsetenv("GRASSFIELD_FILES_NO_LAUNCH");
        qputenv("PATH", m_path);
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
        QFile::remove(mark(QFileInfo(path).fileName()));
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
    // A script named `name` in the test's own bin folder (first on PATH) that writes its working folder and its arguments,
    // one per line, to `<name>.args` next to it. Returns that file.
    QString recorder(const QString &name)
    {
        const QString bin = d(QStringLiteral("bin"));
        QDir().mkpath(bin);
        const QString out = QDir(bin).filePath(name + QStringLiteral(".args"));
        QFile::remove(out);
        QFile f(QDir(bin).filePath(name));
        EXPECT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(QStringLiteral("#!/bin/sh\n{ pwd; for a in \"$@\"; do printf '%s\\n' \"$a\"; done; } > '%1'\n").arg(out).toUtf8());
        f.close();
        EXPECT_EQ(::chmod(QFile::encodeName(f.fileName()).constData(), 0755), 0);
        if (!qgetenv("PATH").startsWith(QFile::encodeName(bin)))
            qputenv("PATH", QFile::encodeName(bin) + ':' + qgetenv("PATH"));
        return out;
    }
    static QList<QUrl> urls(const QString &path) { return {QUrl::fromLocalFile(path)}; }

    QTemporaryDir m_dir{QDir(qEnvironmentVariableIsEmpty("GRASSFIELD_TEST_TMP") ? QDir::tempPath() : qEnvironmentVariable("GRASSFIELD_TEST_TMP"))
                            .filePath(QStringLiteral("fileslaunch-XXXXXX"))};
    QByteArray m_session;
    QByteArray m_path;
};
} // namespace

// The owner's report: a native program opens, without a sheet when it was made here, in the home folder (never the folder
// it was opened from).
TEST_F(FilesLaunch, ANativeProgramRunsInTheHomeFolder)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString tool = place("probe", QStringLiteral("Games/tool"), 0755);
    app.open(urls(tool));
    EXPECT_TRUE(waitFor([&] { return QFileInfo::exists(mark(QStringLiteral("tool"))); })) << "it ran, in the home folder";
    EXPECT_FALSE(QFileInfo::exists(d(QStringLiteral("Games/tool.launched")))) << "not in its own folder";
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
    const QString ran = mark(QStringLiteral("Tool.AppImage"));

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
    EXPECT_FALSE(QFileInfo::exists(ran)) << "Cancel: nothing ran";
    EXPECT_EQ(modeOf(path), 0644u) << "Cancel: nothing changed";

    s.answer = QStringLiteral("open");
    app.open(urls(path));
    EXPECT_TRUE(waitFor([&] { return QFileInfo::exists(ran); })) << "Open: it runs";
    EXPECT_EQ(modeOf(path), 0744u) << "Open allowed it to run (u+x only)";
    EXPECT_TRUE(LaunchGuard::inspect(QUrl::fromLocalFile(path)).approved);
    EXPECT_EQ(s.ofKind(QStringLiteral("openProgram")).size(), 2);

    // Approved and unchanged: no sheet.
    QFile::remove(ran);
    app.open(urls(path));
    EXPECT_TRUE(waitFor([&] { return QFileInfo::exists(ran); }));
    EXPECT_EQ(s.ofKind(QStringLiteral("openProgram")).size(), 2) << "never asked again for an approved, unchanged file";

    // Changed: asked again (and canceled here).
    QFile::remove(ran);
    {
        // ETXTBSY while the last run has not ended yet (it leaves its mark just before it ends). waitFor asks once more after
        // its loop: the open is remembered, never repeated on an open file.
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
    EXPECT_FALSE(QFileInfo::exists(ran));
}

// A program that changes while its sheet is open is not run: Files decides again on what it is now.
TEST_F(FilesLaunch, AProgramChangedWhileItsSheetIsOpenDoesNotRun)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString path = place("probe", QStringLiteral("Downloads/Swap"), 0644);
    s.answer = QStringLiteral("open");
    s.before = [&path](const QVariantMap &request) {
        if (request.value(QStringLiteral("kind")).toString() != QLatin1String("openProgram"))
            return;
        QFile f(path);
        if (f.open(QIODevice::WriteOnly | QIODevice::Append))
            f.write("swapped while the sheet was open");
    };
    app.open(urls(path));
    ASSERT_TRUE(waitFor([&] { return !s.ofKind(QStringLiteral("notice")).isEmpty(); }));
    const QVariantMap notice = s.ofKind(QStringLiteral("notice")).first();
    EXPECT_EQ(notice.value(QStringLiteral("title")).toString(), QStringLiteral("“Swap” wasn’t opened."));
    EXPECT_EQ(notice.value(QStringLiteral("text")).toString(), QStringLiteral("It changed while you were deciding. Open it again to decide on it as it is now."));
    settle(1200);
    EXPECT_FALSE(QFileInfo::exists(mark(QStringLiteral("Swap"))));
    EXPECT_EQ(modeOf(path), 0644u) << "no execute bit for a file nobody approved";
}

// The Archive Utility model (review of 0c51550e, BLOCKER): a program inside a downloaded archive keeps the archive's download
// marks after Expand, so opening it asks, as opening the downloaded program itself does.
TEST_F(FilesLaunch, AProgramFromADownloadedArchiveAsksAfterExpand)
{
    const QString bsdtar = QStandardPaths::findExecutable(QStringLiteral("bsdtar"));
    if (bsdtar.isEmpty())
        GTEST_SKIP() << "bsdtar is not installed";
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString staging = d(QStringLiteral("staging"));
    place("probe", QStringLiteral("staging/Tool"), 0755);
    QDir().mkpath(d(QStringLiteral("Downloads")));
    for (const QString &archive : {QStringLiteral("Tool.zip"), QStringLiteral("Tool.tar.gz")}) {
        const QString path = d(QStringLiteral("Downloads/") + archive);
        ASSERT_EQ(QProcess::execute(bsdtar, {QStringLiteral("-a"), QStringLiteral("-cf"), path, QStringLiteral("-C"), staging, QStringLiteral("Tool")}), 0);
        if (!markDownloaded(path))
            GTEST_SKIP() << "no user extended attributes in " << m_dir.path().toStdString();
        const int before = int(s.ofKind(QStringLiteral("openProgram")).size());
        // Opening an archive expands it next to itself (one item keeps its name; "Tool 2" the second time).
        app.open(urls(path));
        const QString extracted = d(archive == QLatin1String("Tool.zip") ? QStringLiteral("Downloads/Tool") : QStringLiteral("Downloads/Tool 2"));
        ASSERT_TRUE(waitFor([&] { return QFileInfo(extracted).isFile(); }, 15000)) << archive.toStdString();
        EXPECT_TRUE(QFileInfo(extracted).isExecutable()) << "bsdtar keeps the members' execute bits";
        EXPECT_EQ(attributeOf(extracted, "user.xdg.origin.url"), QByteArray("https://downloads.example.org/files/Tool.AppImage?token=secret"));
        EXPECT_EQ(attributeOf(extracted, "user.xdg.referrer.url"), QByteArray("https://www.example.org/download"));
        s.answer = QStringLiteral("cancel");
        app.open(urls(extracted));
        ASSERT_TRUE(waitFor([&] { return int(s.ofKind(QStringLiteral("openProgram")).size()) == before + 1; })) << archive.toStdString();
        const QVariantMap sheet = s.ofKind(QStringLiteral("openProgram")).last();
        EXPECT_TRUE(sheet.value(QStringLiteral("downloaded")).toBool());
        EXPECT_EQ(sheet.value(QStringLiteral("host")).toString(), QStringLiteral("downloads.example.org"));
    }
    settle(1200);
    EXPECT_FALSE(QFileInfo::exists(mark(QStringLiteral("Tool"))));
    EXPECT_FALSE(QFileInfo::exists(mark(QStringLiteral("Tool 2"))));
}

// A program that can't run where it is is copied to ~/Applications, approved there and run from there; the original is not
// touched.
TEST_F(FilesLaunch, AProgramThatCantRunWhereItIsRunsFromACopyInApplications)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    // The copy is what a noexec or read-only disk gets (no such disk in a test).
    FilesAppTestAccess::adjustRunPlan(app, [](LaunchGuard::RunPlan &plan) {
        plan.copy = true;
        plan.allowRun = false;
        plan.ask = true;
    });
    const QString source = place("probe", QStringLiteral("Stick/Copied"), 0644);
    const QString applications = QDir(QDir::homePath()).filePath(QStringLiteral("Applications"));
    QFile::remove(QDir(applications).filePath(QStringLiteral("Copied")));
    s.answer = QStringLiteral("open");
    app.open(urls(source));
    ASSERT_TRUE(waitFor([&] { return !s.ofKind(QStringLiteral("openProgram")).isEmpty(); }));
    EXPECT_TRUE(s.ofKind(QStringLiteral("openProgram")).first().value(QStringLiteral("copy")).toBool());
    EXPECT_TRUE(waitFor([&] { return QFileInfo::exists(mark(QStringLiteral("Copied"))); }, 10000)) << "the copy ran";
    const QString copy = QDir(applications).filePath(QStringLiteral("Copied"));
    EXPECT_TRUE(QFileInfo(copy).isExecutable());
    EXPECT_TRUE(LaunchGuard::inspect(QUrl::fromLocalFile(copy)).approved);
    EXPECT_EQ(modeOf(source), 0644u) << "the original is left as it was";
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
    for (const QString &disguise : {QStringLiteral("Desktop/Invoice.pdf"), QStringLiteral("Desktop/Invoice.pdf "), QStringLiteral("Desktop/Invoice.pdf\u200b")}) {
        const QString disguised = d(disguise);
        ASSERT_TRUE(QFile::link(target, disguised));
        const int told = int(s.told.size());
        app.open(urls(disguised));
        ASSERT_EQ(int(s.told.size()), told + 1) << disguise.toStdString();
        EXPECT_TRUE(s.told.last().contains(QStringLiteral("look like a document"))) << s.told.last().toStdString();
    }
    settle(1200);
    EXPECT_FALSE(QFileInfo::exists(mark(QStringLiteral("Tool.AppImage"))));
    EXPECT_EQ(s.ofKind(QStringLiteral("openProgram")).size(), 1) << "the disguised links are refused before any sheet";
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
    qputenv("PATH", QFile::encodeName(bin) + ':' + m_path);

    app.open(urls(place("fuse", QStringLiteral("Old.AppImage"), 0755, true)));
    ASSERT_TRUE(waitFor([&] { return !s.ofKind(QStringLiteral("notice")).isEmpty(); }));
    EXPECT_EQ(s.ofKind(QStringLiteral("notice")).last().value(QStringLiteral("title")).toString(), QStringLiteral("This AppImage needs a system component (fuse2)."));
    EXPECT_TRUE(s.ofKind(QStringLiteral("notice")).last().value(QStringLiteral("text")).toString().contains(QStringLiteral("“Old.AppImage”")));

    app.open(urls(place("needs-library", QStringLiteral("Needy"), 0755)));
    ASSERT_TRUE(waitFor([&] { return s.ofKind(QStringLiteral("notice")).size() == 2; }));
    const QVariantMap missing = s.ofKind(QStringLiteral("notice")).last();
    EXPECT_EQ(missing.value(QStringLiteral("title")).toString(), QStringLiteral("“Needy” can’t be opened."));
    EXPECT_TRUE(missing.value(QStringLiteral("text")).toString().contains(QStringLiteral("libgflaunchmissing.so"))) << missing.value(QStringLiteral("text")).toString().toStdString();
    EXPECT_FALSE(QFileInfo::exists(mark(QStringLiteral("Needy")))) << "the loader stopped it before main";

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

    // uwsm would read this program as the desktop entry "Tool.desktop" with its action "run": refused as a launcher.
    const QString entryLike = place("probe", QStringLiteral("Tool.desktop:run"), 0755);
    app.open(urls(entryLike));
    EXPECT_TRUE(s.told.last().contains(QStringLiteral("app launcher"))) << s.told.last().toStdString();

    // A program that keeps running past the first second: no alert.
    const int notices = int(s.ofKind(QStringLiteral("notice")).size());
    app.open(urls(place("stay", QStringLiteral("Stays/stay"), 0755)));
    EXPECT_TRUE(waitFor([&] { return QFileInfo::exists(mark(QStringLiteral("stay"))); }));
    settle(2500);
    EXPECT_EQ(int(s.ofKind(QStringLiteral("notice")).size()), notices);
    EXPECT_FALSE(QFileInfo::exists(mark(QStringLiteral("Tool.desktop:run"))));
}

// A script opens in the text editor (blocked here by the test switch, so nothing starts) and never runs by opening; Open With
// lists Terminal for an executable script only; a downloaded one asks first, and after Open the session's terminal gets the
// script as an argument of bash, never as command text, in the script's folder.
TEST_F(FilesLaunch, ScriptsOpenInTheEditorAndRunOnlyInTerminal)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString script = d(QStringLiteral("Scripts/run me.sh"));
    QDir().mkpath(d(QStringLiteral("Scripts")));
    {
        QFile f(script);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("#!/bin/sh\ntouch \"$(dirname \"$0\")/script-ran\"\n");
    }
    ASSERT_EQ(::chmod(QFile::encodeName(script).constData(), 0755), 0);
    qputenv("GRASSFIELD_FILES_NO_LAUNCH", "1");
    app.open(urls(script));
    settle(1500);
    EXPECT_FALSE(QFileInfo::exists(d(QStringLiteral("Scripts/script-ran")))) << "opening a script never runs it";
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

    if (!markDownloaded(script))
        GTEST_SKIP() << "no user extended attributes in " << m_dir.path().toStdString();
    qunsetenv("GRASSFIELD_FILES_NO_LAUNCH");
    const QString record = recorder(QStringLiteral("xdg-terminal-exec"));
    s.answer = QStringLiteral("cancel");
    app.openWith(QStringLiteral("grassfield:terminal"), urls(script));
    ASSERT_TRUE(waitFor([&] { return !s.ofKind(QStringLiteral("openProgram")).isEmpty(); }));
    EXPECT_EQ(s.ofKind(QStringLiteral("openProgram")).first().value(QStringLiteral("what")).toString(), QStringLiteral("script"));
    settle(500);
    EXPECT_FALSE(QFileInfo::exists(record)) << "Cancel: no terminal";

    s.answer = QStringLiteral("open");
    app.openWith(QStringLiteral("grassfield:terminal"), urls(script));
    ASSERT_TRUE(waitFor([&] { return lines(record).size() >= 7; }));
    const QStringList args = lines(record);
    EXPECT_EQ(args.at(0), d(QStringLiteral("Scripts"))) << "the script's folder";
    EXPECT_EQ(args.mid(1, 3), (QStringList{QStringLiteral("--"), QStringLiteral("/bin/bash"), QStringLiteral("-c")}));
    EXPECT_TRUE(args.at(4).startsWith(QStringLiteral("\"$1\";"))) << args.at(4).toStdString();
    EXPECT_EQ(args.at(5), QStringLiteral("grassfield-files"));
    EXPECT_EQ(args.at(6), QFileInfo(script).canonicalFilePath()) << "the path is an argument, never command text";
    EXPECT_FALSE(QFileInfo::exists(d(QStringLiteral("Scripts/script-ran")))) << "the recorder stands for the terminal";
}

// Nothing runs from a server; Windows and Java programs and another system's app are explained in a sheet, never run by
// opening; Open in the sheet runs them with their own application (java -jar, the Windows handler), from the file as checked.
TEST_F(FilesLaunch, RemoteAndForeignItemsAreExplainedAndRunOnlyAfterOpen)
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

    // Java: the sheet offers "Open with Java" when java is on the PATH; Cancel runs nothing, Open runs java -jar <the file>.
    const QString java = recorder(QStringLiteral("java"));
    const QString jar = d(QStringLiteral("tool.jar"));
    {
        QFile f(jar);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(QByteArray("PK\x03\x04", 4) + QByteArray(60, '\0'));
    }
    s.answer = QStringLiteral("cancel");
    app.open(urls(jar));
    ASSERT_TRUE(waitFor([&] { return s.ofKind(QStringLiteral("foreignProgram")).size() == 1; }));
    EXPECT_EQ(s.ofKind(QStringLiteral("foreignProgram")).last().value(QStringLiteral("platform")).toString(), QStringLiteral("java"));
    EXPECT_EQ(s.ofKind(QStringLiteral("foreignProgram")).last().value(QStringLiteral("handler")).toString(), QStringLiteral("Java"));
    settle(500);
    EXPECT_FALSE(QFileInfo::exists(java));
    s.answer = QStringLiteral("open");
    app.open(urls(jar));
    ASSERT_TRUE(waitFor([&] { return lines(java).size() >= 3; }));
    EXPECT_EQ(lines(java), (QStringList{QDir::homePath(), QStringLiteral("-jar"), QFileInfo(jar).canonicalFilePath()}));

    // Windows: a handler that names the type itself (Wine, Bottles: here a recorder) is offered; Open opens the file with it.
    const QString wine = recorder(QStringLiteral("gf-wine"));
    const QString apps = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    QDir().mkpath(apps);
    {
        QFile entry(apps + QStringLiteral("/org.example.GfWine.desktop"));
        ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
        entry.write(QStringLiteral("[Desktop Entry]\nType=Application\nName=GfWine\nExec=\"%1\" %f\nMimeType=application/x-msdownload;application/x-ms-dos-executable;\n")
                        .arg(QDir(d(QStringLiteral("bin"))).filePath(QStringLiteral("gf-wine")))
                        .toUtf8());
    }
    QDeadlineTimer cache(15000);
    while (!KService::serviceByMenuId(QStringLiteral("org.example.GfWine.desktop")) && !cache.hasExpired()) {
        settle(200);
        KSycoca::self()->ensureCacheValid();
    }
    ASSERT_TRUE(KService::serviceByMenuId(QStringLiteral("org.example.GfWine.desktop"))) << "KDE's service cache did not see the handler";
    const QString exe = d(QStringLiteral("setup.exe"));
    {
        QFile f(exe);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(QByteArray("MZ\x90\x00", 4) + QByteArray(200, '\0'));
    }
    s.answer = QStringLiteral("cancel");
    app.open(urls(exe));
    ASSERT_TRUE(waitFor([&] { return s.ofKind(QStringLiteral("foreignProgram")).size() == 3; }));
    EXPECT_EQ(s.ofKind(QStringLiteral("foreignProgram")).last().value(QStringLiteral("platform")).toString(), QStringLiteral("windows"));
    EXPECT_EQ(s.ofKind(QStringLiteral("foreignProgram")).last().value(QStringLiteral("handler")).toString(), QStringLiteral("GfWine"));
    settle(500);
    EXPECT_FALSE(QFileInfo::exists(wine)) << "Cancel: the handler never ran";
    s.answer = QStringLiteral("open");
    app.open(urls(exe));
    ASSERT_TRUE(waitFor([&] { return lines(wine).size() >= 2; }, 10000));
    EXPECT_EQ(lines(wine).last(), exe);
    QFile::remove(apps + QStringLiteral("/org.example.GfWine.desktop"));
    EXPECT_TRUE(s.ofKind(QStringLiteral("openProgram")).isEmpty());
}

// A copy from a remote location (here a data: address, KIO's own worker) lands with the address as its download mark (no
// user name or password), so a program among such copies asks before it runs.
TEST_F(FilesLaunch, ARemoteCopyGetsADownloadMark)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString folder = d(QStringLiteral("Incoming"));
    QDir().mkpath(folder);
    const QUrl source(QStringLiteral("data:application/octet-stream;base64,f0VMRg=="));
    app.drop({source}, QUrl::fromLocalFile(folder), nullptr);
    QString copied;
    waitFor([&] {
        const QStringList names = QDir(folder).entryList(QDir::Files | QDir::Hidden);
        if (!names.isEmpty())
            copied = QDir(folder).filePath(names.first());
        return !copied.isEmpty() && !attributeOf(copied, "user.xdg.origin.url").isEmpty();
    }, 10000);
    if (copied.isEmpty())
        GTEST_SKIP() << "KIO did not copy the data: address here (" << s.told.join(QLatin1Char('|')).toStdString() << ")";
    EXPECT_EQ(attributeOf(copied, "user.xdg.origin.url"), source.toEncoded());
}

namespace
{
// A downloaded tar.gz whose members have the modes bsdtar keeps (counter-review of 48475cf6, B1): programs of mode 0500 and
// 0555, and programs inside folders of mode 0100 and 0300. Python's tarfile writes the modes; `program` is the bytes of each.
bool writeLockedArchive(const QString &archive, const QString &program)
{
    static const char kScript[] = R"(import io, sys, tarfile
out, prog = sys.argv[1], open(sys.argv[2], "rb").read()
with tarfile.open(out, "w:gz") as t:
    def add(name, mode, data=None):
        info = tarfile.TarInfo(name)
        info.mode = mode
        if data is None:
            info.type = tarfile.DIRTYPE
            t.addfile(info)
        else:
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
    add("Kit", 0o755)
    add("Kit/readonly", 0o500, prog)
    add("Kit/everyone", 0o555, prog)
    add("Kit/locked", 0o100)
    add("Kit/locked/prog", 0o755, prog)
    add("Kit/blind", 0o300)
    add("Kit/blind/prog", 0o755, prog)
)";
    return QProcess::execute(QStringLiteral("python3"), {QStringLiteral("-I"), QStringLiteral("-c"), QString::fromLatin1(kScript), archive, program}) == 0;
}
} // namespace

// Counter-review of 48475cf6 (B1): every regular file of a downloaded archive keeps its marks, whatever its mode or its
// folder's, and opening any of its programs asks.
TEST_F(FilesLaunch, EveryProgramOfADownloadedArchiveAsksWhateverItsMode)
{
    if (QStandardPaths::findExecutable(QStringLiteral("bsdtar")).isEmpty() || QStandardPaths::findExecutable(QStringLiteral("python3")).isEmpty())
        GTEST_SKIP() << "bsdtar or python3 is not installed";
    FilesApp app(QList<QUrl>{});
    Session s(app);
    QDir().mkpath(d(QStringLiteral("Downloads")));
    const QString archive = d(QStringLiteral("Downloads/Kit.tar.gz"));
    ASSERT_TRUE(writeLockedArchive(archive, fixture("probe")));
    if (!markDownloaded(archive))
        GTEST_SKIP() << "no user extended attributes in " << m_dir.path().toStdString();
    app.open(urls(archive));
    const QString kit = d(QStringLiteral("Downloads/Kit"));
    ASSERT_TRUE(waitFor([&] { return QFileInfo(kit + QStringLiteral("/blind/prog")).isFile(); }, 15000)) << s.told.join(QLatin1Char('|')).toStdString();
    // bsdtar gave the folders their modes back: 0100 and 0300 (the folder 0300 can't be listed, its program is still reached).
    EXPECT_EQ(modeOf(kit + QStringLiteral("/locked")), 0100u);
    EXPECT_EQ(modeOf(kit + QStringLiteral("/blind")), 0300u);
    s.answer = QStringLiteral("cancel");
    int asked = 0;
    for (const QString &program : {QStringLiteral("readonly"), QStringLiteral("everyone"), QStringLiteral("locked/prog"), QStringLiteral("blind/prog")}) {
        const QString path = kit + QLatin1Char('/') + program;
        EXPECT_EQ(attributeOf(path, "user.xdg.origin.url"), QByteArray("https://downloads.example.org/files/Tool.AppImage?token=secret")) << program.toStdString();
        app.open(urls(path));
        ++asked;
        ASSERT_TRUE(waitFor([&] { return int(s.ofKind(QStringLiteral("openProgram")).size()) == asked; })) << program.toStdString();
        EXPECT_TRUE(s.ofKind(QStringLiteral("openProgram")).last().value(QStringLiteral("downloaded")).toBool()) << program.toStdString();
    }
    EXPECT_EQ(modeOf(kit + QStringLiteral("/readonly")), 0500u) << "the marks were written, the mode given back";
    EXPECT_EQ(modeOf(kit + QStringLiteral("/everyone")), 0555u);
}

// Fail closed: an Expand of a downloaded archive whose files can't all be marked keeps nothing and says so in a sheet (here the
// test's cap of 2 entries; in the app there is no cap, and a file that can't be marked does the same).
TEST_F(FilesLaunch, ADownloadedArchiveThatCantBeMarkedEverywhereIsNotExpanded)
{
    const QString bsdtar = QStandardPaths::findExecutable(QStringLiteral("bsdtar"));
    if (bsdtar.isEmpty())
        GTEST_SKIP() << "bsdtar is not installed";
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString staging = d(QStringLiteral("staging"));
    place("probe", QStringLiteral("staging/Pack/tool"), 0755);
    place("probe", QStringLiteral("staging/Pack/other"), 0755);
    place("probe", QStringLiteral("staging/Pack/third"), 0755);
    QDir().mkpath(d(QStringLiteral("Downloads")));
    const QString archive = d(QStringLiteral("Downloads/Pack.zip"));
    ASSERT_EQ(QProcess::execute(bsdtar, {QStringLiteral("-a"), QStringLiteral("-cf"), archive, QStringLiteral("-C"), staging, QStringLiteral("Pack")}), 0);
    if (!markDownloaded(archive))
        GTEST_SKIP() << "no user extended attributes in " << m_dir.path().toStdString();
    ArchiveJobTestAccess::setMarkCap(2);
    app.open(urls(archive));
    ASSERT_TRUE(waitFor([&] { return !s.ofKind(QStringLiteral("notice")).isEmpty(); }, 15000)) << s.told.join(QLatin1Char('|')).toStdString();
    const QVariantMap notice = s.ofKind(QStringLiteral("notice")).first();
    EXPECT_EQ(notice.value(QStringLiteral("title")).toString(), QStringLiteral("“Pack.zip” couldn’t be expanded safely."));
    EXPECT_TRUE(notice.value(QStringLiteral("text")).toString().contains(QStringLiteral("nothing was expanded")));
    settle(500);
    const QStringList left = QDir(d(QStringLiteral("Downloads"))).entryList(QDir::AllEntries | QDir::Hidden | QDir::NoDotAndDotDot);
    EXPECT_EQ(left, QStringList{QStringLiteral("Pack.zip")}) << "no expanded item, no staging folder: " << left.join(QLatin1Char('|')).toStdString();
}

// Counter-review of 48475cf6 (m1): Open With > Wine or Java runs the program it is given, so a downloaded .exe or .jar asks
// first there too (and never as root); Cancel runs nothing, Open runs it, approved it does not ask again.
TEST_F(FilesLaunch, OpenWithAWindowsOrJavaHandlerAsksForADownloadedProgram)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString wine = recorder(QStringLiteral("gf-wine2"));
    const QString java = recorder(QStringLiteral("gf-java2"));
    const QString apps = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    QDir().mkpath(apps);
    const QList<QPair<QString, QString>> handlers = {{QStringLiteral("org.example.GfWineTwo"), QStringLiteral("gf-wine2|application/x-msdownload;application/x-ms-dos-executable;")},
                                                     {QStringLiteral("org.example.GfJavaTwo"), QStringLiteral("gf-java2|application/x-java-archive;application/java-archive;")}};
    for (const auto &h : handlers) {
        QFile entry(apps + QLatin1Char('/') + h.first + QStringLiteral(".desktop"));
        ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
        entry.write(QStringLiteral("[Desktop Entry]\nType=Application\nName=%1\nExec=\"%2\" %f\nMimeType=%3\n")
                        .arg(h.first, QDir(d(QStringLiteral("bin"))).filePath(h.second.section(QLatin1Char('|'), 0, 0)), h.second.section(QLatin1Char('|'), 1))
                        .toUtf8());
    }
    QDeadlineTimer cache(15000);
    while ((!KService::serviceByMenuId(QStringLiteral("org.example.GfWineTwo.desktop")) || !KService::serviceByMenuId(QStringLiteral("org.example.GfJavaTwo.desktop")))
           && !cache.hasExpired()) {
        settle(200);
        KSycoca::self()->ensureCacheValid();
    }
    ASSERT_TRUE(KService::serviceByMenuId(QStringLiteral("org.example.GfWineTwo.desktop")));
    ASSERT_TRUE(KService::serviceByMenuId(QStringLiteral("org.example.GfJavaTwo.desktop")));

    const QString exe = d(QStringLiteral("Downloads/setup.exe"));
    const QString jar = d(QStringLiteral("Downloads/tool.jar"));
    QDir().mkpath(d(QStringLiteral("Downloads")));
    {
        QFile f(exe);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(QByteArray("MZ\x90\x00", 4) + QByteArray(200, '\0'));
        QFile g(jar);
        ASSERT_TRUE(g.open(QIODevice::WriteOnly));
        g.write(QByteArray("PK\x03\x04", 4) + QByteArray(60, '\0'));
    }
    if (!markDownloaded(exe) || !markDownloaded(jar))
        GTEST_SKIP() << "no user extended attributes in " << m_dir.path().toStdString();
    const QList<QPair<QString, QString>> cases = {{QStringLiteral("org.example.GfWineTwo.desktop"), exe}, {QStringLiteral("org.example.GfJavaTwo.desktop"), jar}};
    const QStringList records = {wine, java};
    for (int i = 0; i < cases.size(); ++i) {
        const int before = int(s.ofKind(QStringLiteral("foreignProgram")).size());
        s.answer = QStringLiteral("cancel");
        app.openWith(cases.at(i).first, urls(cases.at(i).second));
        ASSERT_TRUE(waitFor([&] { return int(s.ofKind(QStringLiteral("foreignProgram")).size()) == before + 1; })) << cases.at(i).first.toStdString();
        EXPECT_TRUE(s.ofKind(QStringLiteral("foreignProgram")).last().value(QStringLiteral("downloaded")).toBool());
        settle(500);
        EXPECT_FALSE(QFileInfo::exists(records.at(i))) << "Cancel: the handler never ran";
        s.answer = QStringLiteral("open");
        app.openWith(cases.at(i).first, urls(cases.at(i).second));
        ASSERT_TRUE(waitFor([&] { return !lines(records.at(i)).isEmpty() && lines(records.at(i)).last() == cases.at(i).second; }, 10000))
            << cases.at(i).first.toStdString();
        // Approved as it is now: no second sheet.
        QFile::remove(records.at(i));
        const int asked = int(s.ofKind(QStringLiteral("foreignProgram")).size());
        app.openWith(cases.at(i).first, urls(cases.at(i).second));
        ASSERT_TRUE(waitFor([&] { return !lines(records.at(i)).isEmpty(); }, 10000));
        EXPECT_EQ(int(s.ofKind(QStringLiteral("foreignProgram")).size()), asked) << "approved: no second sheet";
    }
    for (const auto &h : handlers)
        QFile::remove(apps + QLatin1Char('/') + h.first + QStringLiteral(".desktop"));
}

// Second counter-review of fd5823de (R1): on a disk that ignores the execute bit (FAT, exFAT), approve() reports ExecIgnored
// after its chmod, which moved the file's status time; the program still runs, from a copy in ~/Applications checked against
// the file as it is after that write (here a real chmod, then ExecIgnored as a FAT mount reports it).
TEST_F(FilesLaunch, AProgramOnADiskThatIgnoresTheExecuteBitRunsFromACopy)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString source = place("probe", QStringLiteral("Stick/FatTool"), 0644);
    const QString applications = QDir(QDir::homePath()).filePath(QStringLiteral("Applications"));
    const QString copy = QDir(applications).filePath(QStringLiteral("FatTool"));
    QFile::remove(copy);
    ProgramLaunchTestAccess::reportExecIgnored(1);
    s.answer = QStringLiteral("open");
    app.open(urls(source));
    ASSERT_TRUE(waitFor([&] { return !s.ofKind(QStringLiteral("openProgram")).isEmpty(); }));
    const QVariantMap sheet = s.ofKind(QStringLiteral("openProgram")).first();
    EXPECT_TRUE(sheet.value(QStringLiteral("allowRun")).toBool()) << "Open sets the execute bit where the disk keeps it";
    EXPECT_FALSE(sheet.value(QStringLiteral("copy")).toBool());
    EXPECT_TRUE(waitFor([&] { return QFileInfo::exists(mark(QStringLiteral("FatTool"))); }, 10000))
        << "the copy ran; notices: " << s.ofKind(QStringLiteral("notice")).size();
    EXPECT_TRUE(s.ofKind(QStringLiteral("notice")).isEmpty()) << "never “It changed while you were deciding”";
    EXPECT_TRUE(QFileInfo(copy).isExecutable());
    EXPECT_TRUE(LaunchGuard::inspect(QUrl::fromLocalFile(copy)).approved);
}

namespace
{
// This process as the staging registry names a holder: the boot, the process id, its start time.
QByteArray selfHolder()
{
    QFile boot(QStringLiteral("/proc/sys/kernel/random/boot_id"));
    QFile stat(QStringLiteral("/proc/self/stat"));
    if (!boot.open(QIODevice::ReadOnly) || !stat.open(QIODevice::ReadOnly))
        return {};
    const QByteArray text = stat.readAll();
    const QList<QByteArray> fields = text.mid(text.lastIndexOf(')') + 2).split(' ');
    return boot.readAll().trimmed() + ' ' + QByteArray::number(qint64(::getpid())) + ' ' + fields.value(19);
}

QByteArray registryLine(const QByteArray &holder, const QString &path)
{
    return holder + ' ' + QFile::encodeName(path).toPercentEncoding();
}

// A downloaded tar.gz whose program lies deeper than PATH_MAX (25 folders of 200-character names), with two more programs
// beside the chain.
bool writeDeepArchive(const QString &archive, const QString &program)
{
    static const char kScript[] = R"(import io, sys, tarfile
out, prog = sys.argv[1], open(sys.argv[2], "rb").read()
with tarfile.open(out, "w:gz", format=tarfile.PAX_FORMAT) as t:
    def add(name, mode, data=None):
        info = tarfile.TarInfo(name)
        info.mode = mode
        if data is None:
            info.type = tarfile.DIRTYPE
            t.addfile(info)
        else:
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
    path = "Deep"
    add(path, 0o755)
    add("Deep/one", 0o755, prog)
    add("Deep/two", 0o755, prog)
    for i in range(25):
        path += "/" + "d" * 200
        add(path, 0o755)
    add(path + "/prog", 0o755, prog)
)";
    return QProcess::execute(QStringLiteral("python3"), {QStringLiteral("-I"), QStringLiteral("-c"), QString::fromLatin1(kScript), archive, program}) == 0;
}
} // namespace

// Second counter-review of fd5823de (m2): what an Expand is still writing is never opened, run, listed or searched from Files,
// a link to it included.
TEST_F(FilesLaunch, NothingUnderAStagingNameIsOpenedOrListed)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString staging = d(QStringLiteral("Downloads/.grassfield-expand-0a1b2c3d"));
    const QString staged = place("probe", QStringLiteral("Downloads/.grassfield-expand-0a1b2c3d/Staged"), 0755);
    const QString link = d(QStringLiteral("Downloads/Staged link"));
    ASSERT_TRUE(QFile::link(staged, link));
    app.open(urls(staged));
    app.open(urls(link));
    app.open(urls(staging));
    settle(1200);
    EXPECT_FALSE(QFileInfo::exists(mark(QStringLiteral("Staged"))));
    EXPECT_FALSE(QFileInfo::exists(mark(QStringLiteral("Staged link"))));
    EXPECT_TRUE(s.asked.isEmpty()) << "refused, not asked";
    ASSERT_EQ(s.told.size(), 3) << s.told.join(QLatin1Char('|')).toStdString();
    EXPECT_EQ(s.told.at(0), QStringLiteral("“Staged” can’t be opened while Files is still expanding or compressing it."));
    EXPECT_EQ(s.told.at(1), QStringLiteral("“Staged link” can’t be opened while Files is still expanding or compressing it."));

    FolderModel model;
    model.setUrl(QUrl::fromLocalFile(staging));
    settle(500);
    EXPECT_EQ(model.rowCount(), 0) << "nothing listed";
    EXPECT_FALSE(model.error().isEmpty());
    model.reload();
    settle(500);
    EXPECT_EQ(model.rowCount(), 0) << "nor after a refresh";
    model.setUrl(QUrl::fromLocalFile(d(QStringLiteral("Downloads"))));
    EXPECT_TRUE(waitFor([&] { return model.rowCount() > 0; })) << "an ordinary folder lists";
    EXPECT_TRUE(model.error().isEmpty());
}

// m2: a Files killed during an Expand leaves its staging folder and its line in the registry; the next start removes the
// folder (by descriptor, its 0100 and 0500 folders opened up first), and nothing else: a line still held, a name that is not
// a staging name, a relative path.
TEST_F(FilesLaunch, StagingLeftByAKilledFilesIsSweptAtStart)
{
    const QByteArray self = selfHolder();
    ASSERT_FALSE(self.isEmpty());
    const QString registry = d(QStringLiteral("state/files-staging"));
    QDir().mkpath(d(QStringLiteral("state")));
    const QString left = d(QStringLiteral("Work/.grassfield-expand-00c0ffee"));
    place("probe", QStringLiteral("Work/.grassfield-expand-00c0ffee/Kit/locked/prog"), 0755);
    place("probe", QStringLiteral("Work/.grassfield-expand-00c0ffee/Kit/readonly"), 0500);
    ASSERT_EQ(::chmod(QFile::encodeName(left + QStringLiteral("/Kit/locked")).constData(), 0100), 0);
    ASSERT_EQ(::chmod(QFile::encodeName(left + QStringLiteral("/Kit")).constData(), 0500), 0);
    const QString compressLeft = place("probe", QStringLiteral("Work/.grassfield-compress-0badf00d.zip"), 0644);
    const QString held = d(QStringLiteral("Work/.grassfield-expand-0000beef"));
    place("probe", QStringLiteral("Work/.grassfield-expand-0000beef/inside"), 0644);
    const QString notStaging = d(QStringLiteral("Work/Documents"));
    place("probe", QStringLiteral("Work/Documents/keep"), 0644);
    {
        QFile f(registry);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(registryLine("another-boot 4242 777", left) + '\n');
        f.write(registryLine(self.left(self.lastIndexOf(' ')) + " 1", compressLeft) + '\n'); // this process id, another start time
        f.write(registryLine(self, held) + '\n');
        f.write(registryLine("another-boot 4243 778", notStaging) + '\n');
        f.write(registryLine("another-boot 4244 779", QStringLiteral(".grassfield-expand-0a0a0a0a")) + '\n');
        f.write("a line that is not one\n");
    }
    EXPECT_EQ(ArchiveJob::sweepStaleStaging(registry), 2);
    EXPECT_FALSE(QFileInfo::exists(left)) << "the killed Files' staging folder went";
    EXPECT_FALSE(QFileInfo::exists(compressLeft)) << "a process id used again is no holder";
    EXPECT_TRUE(QFileInfo::exists(held + QStringLiteral("/inside"))) << "a staging folder still held stays";
    EXPECT_TRUE(QFileInfo::exists(notStaging + QStringLiteral("/keep"))) << "never anything but a staging name";
    EXPECT_EQ(lines(registry), QStringList{QString::fromLatin1(registryLine(self, held))}) << "only the held line stays";
    EXPECT_EQ(ArchiveJob::sweepStaleStaging(d(QStringLiteral("state/none"))), 0) << "no registry: nothing to do";
    EXPECT_FALSE(QFileInfo::exists(d(QStringLiteral("state/none"))));
}

// m2: an Expand forgets its staging folder at the end (ArchiveJob::stagingRegistry); a refused one removes its tree by
// descriptor, a program deeper than PATH_MAX included (openTree's depth and removeRecursively's paths kept it before).
TEST_F(FilesLaunch, ARefusedExpandLeavesNothingEvenDeeperThanPathMax)
{
    if (QStandardPaths::findExecutable(QStringLiteral("bsdtar")).isEmpty() || QStandardPaths::findExecutable(QStringLiteral("python3")).isEmpty())
        GTEST_SKIP() << "bsdtar or python3 is not installed";
    FilesApp app(QList<QUrl>{});
    Session s(app);
    QDir().mkpath(d(QStringLiteral("Downloads")));
    const QString archive = d(QStringLiteral("Downloads/Deep.tar.gz"));
    ASSERT_TRUE(writeDeepArchive(archive, fixture("probe")));
    if (!markDownloaded(archive))
        GTEST_SKIP() << "no user extended attributes in " << m_dir.path().toStdString();
    ArchiveJobTestAccess::setMarkCap(2);
    app.open(urls(archive));
    ASSERT_TRUE(waitFor([&] { return !s.ofKind(QStringLiteral("notice")).isEmpty(); }, 30000)) << s.told.join(QLatin1Char('|')).toStdString();
    EXPECT_EQ(s.ofKind(QStringLiteral("notice")).first().value(QStringLiteral("title")).toString(), QStringLiteral("“Deep.tar.gz” couldn’t be expanded safely."));
    settle(500);
    const QStringList kept = QDir(d(QStringLiteral("Downloads"))).entryList(QDir::AllEntries | QDir::Hidden | QDir::NoDotAndDotDot);
    EXPECT_EQ(kept, QStringList{QStringLiteral("Deep.tar.gz")}) << kept.join(QLatin1Char('|')).toStdString();
    EXPECT_FALSE(lines(ArchiveJob::stagingRegistry()).join(QLatin1Char('\n')).contains(QStringLiteral(".grassfield-expand-"))) << "and forgotten";
}

// Second counter-review of fd5823de (m3): every application that opens a program, an AppImage or a script may run it (an
// AppImage helper, a terminal registered for scripts): a downloaded one asks first, naming the application; Cancel runs
// nothing; Open covers that open only (no execute bit, no approval: the next open asks again). A file made here does not ask.
// Nothing under a staging name is handed to an application.
TEST_F(FilesLaunch, OpenWithAnyHandlerOfAProgramOrScriptAsksForADownloadedOne)
{
    FilesApp app(QList<QUrl>{});
    Session s(app);
    const QString helper = recorder(QStringLiteral("gf-appimage-helper"));
    const QString runner = recorder(QStringLiteral("gf-script-runner"));
    const QString apps = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    QDir().mkpath(apps);
    const QList<QPair<QString, QString>> handlers = {
        {QStringLiteral("org.example.GfAppImageHelper"), QStringLiteral("gf-appimage-helper|application/vnd.appimage;application/x-executable;")},
        {QStringLiteral("org.example.GfScriptRunner"), QStringLiteral("gf-script-runner|application/x-shellscript;")}};
    for (const auto &h : handlers) {
        QFile entry(apps + QLatin1Char('/') + h.first + QStringLiteral(".desktop"));
        ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
        entry.write(QStringLiteral("[Desktop Entry]\nType=Application\nName=%1\nExec=\"%2\" %f\nMimeType=%3\n")
                        .arg(h.first, QDir(d(QStringLiteral("bin"))).filePath(h.second.section(QLatin1Char('|'), 0, 0)), h.second.section(QLatin1Char('|'), 1))
                        .toUtf8());
    }
    QDeadlineTimer cache(15000);
    while ((!KService::serviceByMenuId(QStringLiteral("org.example.GfAppImageHelper.desktop")) || !KService::serviceByMenuId(QStringLiteral("org.example.GfScriptRunner.desktop")))
           && !cache.hasExpired()) {
        settle(200);
        KSycoca::self()->ensureCacheValid();
    }
    ASSERT_TRUE(KService::serviceByMenuId(QStringLiteral("org.example.GfAppImageHelper.desktop")));
    ASSERT_TRUE(KService::serviceByMenuId(QStringLiteral("org.example.GfScriptRunner.desktop")));

    const QString appImage = place("probe", QStringLiteral("Downloads/Helped.AppImage"), 0644, true);
    const QString script = d(QStringLiteral("Downloads/install.sh"));
    {
        QFile f(script);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("#!/bin/sh\necho installed\n");
    }
    ASSERT_EQ(::chmod(QFile::encodeName(script).constData(), 0755), 0);
    if (!markDownloaded(appImage) || !markDownloaded(script))
        GTEST_SKIP() << "no user extended attributes in " << m_dir.path().toStdString();
    ASSERT_EQ(LaunchGuard::verdict(LaunchGuard::inspect(QUrl::fromLocalFile(appImage))), LaunchGuard::Verdict::RunProgram);
    ASSERT_EQ(LaunchGuard::verdict(LaunchGuard::inspect(QUrl::fromLocalFile(script))), LaunchGuard::Verdict::OpenScript);

    struct Case {
        QString id, name, file, record, what;
    };
    const QList<Case> cases = {{QStringLiteral("org.example.GfAppImageHelper.desktop"), QStringLiteral("org.example.GfAppImageHelper"), appImage, helper, QStringLiteral("app")},
                               {QStringLiteral("org.example.GfScriptRunner.desktop"), QStringLiteral("org.example.GfScriptRunner"), script, runner, QStringLiteral("script")}};
    for (const Case &c : cases) {
        const int before = int(s.ofKind(QStringLiteral("openProgram")).size());
        s.answer = QStringLiteral("cancel");
        app.openWith(c.id, urls(c.file));
        ASSERT_TRUE(waitFor([&] { return int(s.ofKind(QStringLiteral("openProgram")).size()) == before + 1; })) << c.id.toStdString();
        const QVariantMap sheet = s.ofKind(QStringLiteral("openProgram")).last();
        EXPECT_EQ(sheet.value(QStringLiteral("handler")).toString(), c.name);
        EXPECT_EQ(sheet.value(QStringLiteral("what")).toString(), c.what);
        EXPECT_TRUE(sheet.value(QStringLiteral("downloaded")).toBool());
        EXPECT_EQ(sheet.value(QStringLiteral("host")).toString(), QStringLiteral("downloads.example.org"));
        EXPECT_FALSE(sheet.value(QStringLiteral("allowRun")).toBool());
        settle(500);
        EXPECT_FALSE(QFileInfo::exists(c.record)) << "Cancel: the application never ran";
        s.answer = QStringLiteral("open");
        app.openWith(c.id, urls(c.file));
        ASSERT_TRUE(waitFor([&] { return !lines(c.record).isEmpty() && lines(c.record).last() == c.file; }, 10000)) << c.id.toStdString();
        EXPECT_FALSE(LaunchGuard::inspect(QUrl::fromLocalFile(c.file)).approved) << "Open covered that open only";
        // The next open with it asks again.
        QFile::remove(c.record);
        s.answer = QStringLiteral("cancel");
        app.openWith(c.id, urls(c.file));
        ASSERT_TRUE(waitFor([&] { return int(s.ofKind(QStringLiteral("openProgram")).size()) == before + 3; })) << c.id.toStdString();
    }
    EXPECT_EQ(modeOf(appImage), 0644u) << "no execute bit from Open With";

    // Made here (no download mark): no sheet.
    const QString local = d(QStringLiteral("Work/local.sh"));
    QDir().mkpath(d(QStringLiteral("Work")));
    {
        QFile f(local);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("#!/bin/sh\necho local\n");
    }
    ASSERT_EQ(::chmod(QFile::encodeName(local).constData(), 0755), 0);
    QFile::remove(runner);
    const int asked = int(s.ofKind(QStringLiteral("openProgram")).size());
    app.openWith(QStringLiteral("org.example.GfScriptRunner.desktop"), urls(local));
    ASSERT_TRUE(waitFor([&] { return !lines(runner).isEmpty() && lines(runner).last() == local; }, 10000));
    EXPECT_EQ(int(s.ofKind(QStringLiteral("openProgram")).size()), asked);

    // Under a staging name: refused, never handed to the application.
    const QString staged = place("probe", QStringLiteral("Downloads/.grassfield-expand-0a1b2c3d/Staged.AppImage"), 0755, true);
    QFile::remove(helper);
    s.told.clear();
    app.openWith(QStringLiteral("org.example.GfAppImageHelper.desktop"), urls(staged));
    settle(800);
    EXPECT_FALSE(QFileInfo::exists(helper));
    EXPECT_EQ(s.told, QStringList{QStringLiteral("“Staged.AppImage” can’t be opened while Files is still expanding or compressing it.")});
    for (const auto &h : handlers)
        QFile::remove(apps + QLatin1Char('/') + h.first + QStringLiteral(".desktop"));
}
