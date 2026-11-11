// Unit tests for apps/files/src/programlaunch.{h,cpp} (gtest; the Gatekeeper model of the ADR-0011 amendment of 2026-11-08):
// the failure a program's first second shows (classify), the approval Files keeps after the user's Open (execute bit through
// one descriptor, bound to the file's identity), the Applications folder and its free names. Real files under
// GRASSFIELD_TEST_TMP when set. The start itself, through FilesApp::open, is tests/unit/files/tst_fileslaunch.cpp.
#include "launchguard.h"
#include "programlaunch.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <cerrno>
#include <sys/stat.h>
#include <sys/xattr.h>

using namespace ProgramLaunch;

namespace
{
QString scratchBase()
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    return base.isEmpty() ? QDir::tempPath() : base;
}

Start exited(int code, const QByteArray &errors = {}, bool appImage = false)
{
    Start s;
    s.exited = true;
    s.exitCode = code;
    s.errors = errors;
    s.appImage = appImage;
    return s;
}

Start notStarted(int error, const QString &interpreter = {})
{
    Start s;
    s.spawned = false;
    s.spawnErrno = error;
    s.interpreter = interpreter;
    return s;
}

unsigned modeOf(const QString &path)
{
    struct stat st{};
    return ::stat(QFile::encodeName(path).constData(), &st) == 0 ? unsigned(st.st_mode & 07777) : 0xffffffffu;
}

QByteArray approvalOf(const QString &path)
{
    char value[256];
    const ssize_t n = ::getxattr(QFile::encodeName(path).constData(), "user.grassfield.approved", value, sizeof value);
    return n > 0 ? QByteArray(value, int(n)) : QByteArray();
}
} // namespace

TEST(ProgramLaunchClassify, AStartTheKernelRefusesSaysWhy)
{
    EXPECT_EQ(classify(notStarted(ENOEXEC)).failure, Failure::ExecFormat) << "another computer's program";
    EXPECT_EQ(classify(notStarted(EACCES)).failure, Failure::CannotRunHere) << "noexec or no permission";
    EXPECT_EQ(classify(notStarted(EPERM)).failure, Failure::CannotRunHere);
    const Outcome loader = classify(notStarted(ENOENT, QStringLiteral("/lib/ld-linux-gf-missing.so.2")));
    EXPECT_EQ(loader.failure, Failure::MissingLibrary) << "the program is there: its loader is not";
    EXPECT_EQ(loader.library, QStringLiteral("ld-linux-gf-missing.so.2"));
    EXPECT_EQ(classify(notStarted(ENOENT, QStringLiteral("/proc/self/exe"))).failure, Failure::StartFailed);
    EXPECT_EQ(classify(notStarted(ENOMEM)).failure, Failure::StartFailed);
}

TEST(ProgramLaunchClassify, TheFirstSecondsErrorsNameTheProblem)
{
    const Outcome library = classify(exited(127, "./tool: error while loading shared libraries: libwebkit2gtk-4.0.so.37: cannot open shared object file: No such file or directory\n"));
    EXPECT_EQ(library.failure, Failure::MissingLibrary);
    EXPECT_EQ(library.library, QStringLiteral("libwebkit2gtk-4.0.so.37"));
    // The old AppImage runtime without FUSE 2, and the static one without fusermount.
    EXPECT_EQ(classify(exited(1, "dlopen(): error loading libfuse.so.2\n\nAppImages require FUSE to run.\n", true)).failure, Failure::Fuse);
    EXPECT_EQ(classify(exited(1, "dlopen(): error loading libfuse.so.2\n")).failure, Failure::Fuse) << "the library's name is enough";
    EXPECT_EQ(classify(exited(1, "fuse: failed to exec fusermount3: No such file or directory\nCannot mount AppImage, please check your FUSE setup.\n", true)).failure,
              Failure::Fuse);
    EXPECT_EQ(classify(exited(1, "fusermount: option -o not allowed\n", false)).failure, Failure::QuitAtOnce) << "not an AppImage: its own business";
    // Through uwsm-app (a real session) the start is systemd-run's.
    EXPECT_EQ(classify(exited(1, "Failed to execute /home/u/tool: Exec format error\n")).failure, Failure::ExecFormat);
    EXPECT_EQ(classify(exited(1, "Failed to execute /media/k/tool: Permission denied\n")).failure, Failure::CannotRunHere);
    Start viaScope = exited(1, "Failed to execute /home/u/tool: No such file or directory\n");
    viaScope.interpreter = QStringLiteral("/lib/ld-linux-gf-missing.so.2");
    EXPECT_EQ(classify(viaScope).failure, Failure::MissingLibrary);
    EXPECT_EQ(classify(exited(1, "Failed to execute /home/u/tool: Bad message\n")).failure, Failure::StartFailed);
}

TEST(ProgramLaunchClassify, OnlyAnErrorCodeIsAQuickQuit)
{
    const Outcome quit = classify(exited(3, "usage: tool FILE\n"));
    EXPECT_EQ(quit.failure, Failure::QuitAtOnce);
    EXPECT_EQ(quit.exitCode, 3);
    EXPECT_EQ(classify(exited(0)).failure, Failure::None) << "a program that did its work and ended";
    Start crashed = exited(0);
    crashed.signal = 11;
    EXPECT_EQ(classify(crashed).failure, Failure::None) << "a crash is grassfield-crash-watch's to tell";
    EXPECT_EQ(classify(Start{}).failure, Failure::None) << "still running after the first second";
}

TEST(ProgramLaunchClassify, MissingLibraryReadsOnlyAPlainName)
{
    EXPECT_EQ(missingLibrary("x: error while loading shared libraries: libfoo.so.1: cannot open shared object file"), QStringLiteral("libfoo.so.1"));
    EXPECT_TRUE(missingLibrary("x: error while loading shared libraries: lib foo.so: cannot open shared object file").isEmpty());
    EXPECT_TRUE(missingLibrary("x: error while loading shared libraries: /tmp/libfoo.so: cannot open shared object file").isEmpty());
    EXPECT_TRUE(missingLibrary("nothing to see").isEmpty());
}

class Approve : public ::testing::Test
{
protected:
    QTemporaryDir dir{QDir(scratchBase()).filePath(QStringLiteral("programlaunch-XXXXXX"))};

    QString file(const QString &name, unsigned mode)
    {
        const QString path = dir.filePath(name);
        QFile f(path);
        EXPECT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("\x7f" "ELF payload");
        f.close();
        EXPECT_EQ(::chmod(QFile::encodeName(path).constData(), mode), 0);
        return path;
    }
};

TEST_F(Approve, OpenSetsOnlyTheUsersExecuteBitAndRecordsTheIdentity)
{
    ASSERT_TRUE(dir.isValid());
    const QString path = file(QStringLiteral("Tool.AppImage"), 04640);
    const LaunchGuard::Facts f = LaunchGuard::inspect(QUrl::fromLocalFile(path));
    ASSERT_EQ(approve(f.path, f.inode, f.mtimeNs, f.size, true), Approval::Approved);
    EXPECT_EQ(modeOf(path), 0740u) << "u+x added, setuid dropped, group and others unchanged";
    const QByteArray approval = approvalOf(path);
    if (approval.isEmpty() && errno == ENOTSUP)
        GTEST_SKIP() << "no user extended attributes here";
    EXPECT_EQ(approval, LaunchGuard::approvalValue(f.inode, f.mtimeNs, f.size)) << "chmod changes no part of the identity";
    EXPECT_TRUE(LaunchGuard::inspect(QUrl::fromLocalFile(path)).approved);
}

TEST_F(Approve, ADifferentFileOrALinkIsNeverApproved)
{
    ASSERT_TRUE(dir.isValid());
    const QString path = file(QStringLiteral("tool"), 0644);
    const LaunchGuard::Facts f = LaunchGuard::inspect(QUrl::fromLocalFile(path));
    EXPECT_EQ(approve(f.path, f.inode, f.mtimeNs, f.size + 1, true), Approval::Changed);
    EXPECT_EQ(approve(f.path, f.inode + 1, f.mtimeNs, f.size, true), Approval::Changed);
    EXPECT_EQ(modeOf(path), 0644u) << "nothing changed on a file the user did not decide on";
    EXPECT_TRUE(approvalOf(path).isEmpty());
    const QString link = dir.filePath(QStringLiteral("link"));
    ASSERT_TRUE(QFile::link(path, link));
    EXPECT_EQ(approve(link, f.inode, f.mtimeNs, f.size, true), Approval::Failed) << "O_NOFOLLOW: a link is not the file";
    EXPECT_EQ(modeOf(path), 0644u);
    // Approval only (a script run in Terminal): no permission change.
    ASSERT_EQ(approve(f.path, f.inode, f.mtimeNs, f.size, false), Approval::Approved);
    EXPECT_EQ(modeOf(path), 0644u);
}

TEST_F(Approve, TheApplicationsFolderAndItsFreeNames)
{
    ASSERT_TRUE(dir.isValid());
    const QByteArray home = qgetenv("HOME");
    qputenv("HOME", QFile::encodeName(dir.path()));
    const QString folder = applicationsFolder();
    qputenv("HOME", home);
    EXPECT_EQ(folder, dir.filePath(QStringLiteral("Applications")));
    EXPECT_TRUE(QFileInfo(folder).isDir()) << "made when missing";
    auto touch = [](const QString &path) {
        QFile f(path);
        EXPECT_TRUE(f.open(QIODevice::WriteOnly)) << path.toStdString();
    };
    EXPECT_EQ(freeName(folder, QStringLiteral("Tool.AppImage")), QStringLiteral("Tool.AppImage"));
    touch(QDir(folder).filePath(QStringLiteral("Tool.AppImage")));
    EXPECT_EQ(freeName(folder, QStringLiteral("Tool.AppImage")), QStringLiteral("Tool 2.AppImage"));
    touch(QDir(folder).filePath(QStringLiteral("Tool 2.AppImage")));
    EXPECT_EQ(freeName(folder, QStringLiteral("Tool.AppImage")), QStringLiteral("Tool 3.AppImage"));
    touch(QDir(folder).filePath(QStringLiteral("tool")));
    EXPECT_EQ(freeName(folder, QStringLiteral("tool")), QStringLiteral("tool 2"));
    // A file named Applications in the way: no folder (never replaced).
    const QString other = dir.filePath(QStringLiteral("other"));
    QDir().mkpath(other);
    touch(QDir(other).filePath(QStringLiteral("Applications")));
    qputenv("HOME", QFile::encodeName(other));
    EXPECT_TRUE(applicationsFolder().isEmpty());
    qputenv("HOME", home);
}

TEST(ProgramLaunchRun, TheCommandIsTheDocksLaunchPath)
{
    // Outside a real session (the tests): the program itself, no scope, no shell.
    const QByteArray session = qgetenv("GRASSFIELD_SESSION");
    qunsetenv("GRASSFIELD_SESSION");
    EXPECT_EQ(Run::command(QStringLiteral("/home/u/Tool.AppImage"), {}), QStringList{QStringLiteral("/home/u/Tool.AppImage")});
    EXPECT_EQ(Run::command(QStringLiteral("java"), {QStringLiteral("-jar"), QStringLiteral("/home/u/a b.jar")}),
              (QStringList{QStringLiteral("java"), QStringLiteral("-jar"), QStringLiteral("/home/u/a b.jar")}));
    if (!session.isNull())
        qputenv("GRASSFIELD_SESSION", session);
}
