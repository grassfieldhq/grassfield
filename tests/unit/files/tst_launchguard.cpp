// Unit tests for apps/files/src/launchguard.{h,cpp} (gtest; GF-AUDIT-001 GF-070, DT-10 as amended on 2026-11-08: the Gatekeeper
// model of the ADR-0011 amendment). Built and run by scripts/dev/test.sh. The inspect() cases use real files (under
// GRASSFIELD_TEST_TMP when set) and the installed shared-mime-info database, as Files does. The rule they hold: a program runs
// by opening, a downloaded one only after the user's Open (and again after it changed), a script opens in the editor, Windows
// and Java programs, other systems' apps and app launchers never run by opening, and no name decides alone.
#include "launchguard.h"
#include "programlaunch.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSysInfo>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

using namespace LaunchGuard;

namespace
{
Facts localFile(const QString &name, const QString &mime, QStringList ancestors = {}, bool executable = false)
{
    Facts f;
    f.local = true;
    f.regularFile = true;
    f.fileName = name;
    f.path = QStringLiteral("/home/u/") + name;
    f.mimeType = mime;
    f.mimeAncestors = std::move(ancestors);
    f.executable = executable;
    f.ownedByUser = true;
    return f;
}

// A native program for this computer, as inspect() describes one.
Facts program(const QString &name, const QString &mime = QStringLiteral("application/x-executable"), bool executable = true)
{
    Facts f = localFile(name, mime, {QStringLiteral("application/octet-stream")}, executable);
    f.elf = true;
    f.elfProgram = true;
    f.elfCompatible = true;
    return f;
}

Facts desktop(const QString &name, const QString &type, const QString &url = {})
{
    Facts f = localFile(name, QStringLiteral("application/x-desktop"), {QStringLiteral("text/plain")});
    f.desktopEntry = true;
    f.desktopType = type;
    f.desktopUrl = url;
    return f;
}

QString scratchBase()
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    return base.isEmpty() ? QDir::tempPath() : base;
}

class Files : public ::testing::Test
{
protected:
    QTemporaryDir dir{QDir(scratchBase()).filePath(QStringLiteral("launchguard-XXXXXX"))};

    QString write(const QString &name, const QByteArray &bytes, bool executable)
    {
        const QString path = dir.filePath(name);
        QFile f(path);
        EXPECT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(bytes);
        f.close();
        QFile::Permissions p = QFile::ReadOwner | QFile::WriteOwner;
        if (executable)
            p |= QFile::ExeOwner;
        EXPECT_TRUE(QFile::setPermissions(path, p));
        return path;
    }

    // A copy of /usr/bin/true (a native program of this computer) named `name`; "" when there is none.
    QString nativeProgram(const QString &name, bool executable)
    {
        QFile truebin(QStringLiteral("/usr/bin/true"));
        if (!truebin.exists())
            return {};
        const QString path = dir.filePath(name);
        QFile::remove(path);
        EXPECT_TRUE(QFile::copy(truebin.fileName(), path));
        QFile::Permissions p = QFile::ReadOwner | QFile::WriteOwner;
        if (executable)
            p |= QFile::ExeOwner;
        EXPECT_TRUE(QFile::setPermissions(path, p));
        return path;
    }

    // The AppImage magic at offset 8 of an ELF header ("AI" 2: a type 2 AppImage).
    static void markAppImage(const QString &path)
    {
        QFile f(path);
        ASSERT_TRUE(f.open(QIODevice::ReadWrite));
        ASSERT_TRUE(f.seek(8));
        f.write("AI\x02", 3);
    }

    // A browser's download mark; false when this file system keeps no user extended attributes.
    static bool markDownloaded(const QString &path, const QByteArray &origin)
    {
        return ::setxattr(QFile::encodeName(path).constData(), "user.xdg.origin.url", origin.constData(), size_t(origin.size()), 0) == 0;
    }

    Verdict of(const QString &path) { return verdict(inspect(QUrl::fromLocalFile(path))); }
};

const QByteArray kApp = "[Desktop Entry]\nType=Application\nName=Invoice\nExec=touch /tmp/gf-dt10\n";

// A minimal ELF header with its program headers (64-bit little endian unless said otherwise), for parseElf.
QByteArray elfImage(int type, bool interp, bool pieFlag, int machine = 62, bool wide = true, bool big = false)
{
    QByteArray b(4096, '\0');
    auto put = [&b, big](int at, quint64 value, int size) {
        for (int i = 0; i < size; ++i)
            b[at + (big ? size - 1 - i : i)] = char((value >> (8 * i)) & 0xff);
    };
    b[0] = 0x7f;
    b[1] = 'E';
    b[2] = 'L';
    b[3] = 'F';
    b[4] = char(wide ? 2 : 1);
    b[5] = char(big ? 2 : 1);
    b[6] = 1;
    put(16, quint64(type), 2);
    put(18, quint64(machine), 2);
    const int phoff = wide ? 64 : 52;
    const int phentsize = wide ? 56 : 32;
    const int phnum = 2;
    if (wide) {
        put(32, quint64(phoff), 8);
        put(54, quint64(phentsize), 2);
        put(56, quint64(phnum), 2);
    } else {
        put(28, quint64(phoff), 4);
        put(42, quint64(phentsize), 2);
        put(44, quint64(phnum), 2);
    }
    // Header 0: PT_INTERP (3) or PT_NULL; header 1: PT_DYNAMIC (2) at 1024 with DT_FLAGS_1.
    const int interpAt = 512;
    const char path[] = "/lib64/ld-linux-x86-64.so.2";
    if (interp) {
        put(phoff, 3, 4);
        if (wide) {
            put(phoff + 8, interpAt, 8);
            put(phoff + 32, sizeof path, 8);
        } else {
            put(phoff + 4, interpAt, 4);
            put(phoff + 16, sizeof path, 4);
        }
        b.replace(interpAt, int(sizeof path), path, int(sizeof path));
    }
    const int dynAt = 1024;
    const int second = phoff + phentsize;
    put(second, 2, 4);
    const int entry = wide ? 16 : 8;
    if (wide) {
        put(second + 8, dynAt, 8);
        put(second + 32, 2 * entry, 8);
    } else {
        put(second + 4, dynAt, 4);
        put(second + 16, 2 * entry, 4);
    }
    if (pieFlag) {
        put(dynAt, 0x6ffffffb, entry / 2);
        put(dynAt + entry / 2, 0x08000000, entry / 2);
    }
    return b;
}

ElfHeader parseBytes(const QByteArray &bytes)
{
    return parseElf([&bytes](qint64 offset, qint64 length) {
        return offset < bytes.size() ? bytes.mid(offset, length) : QByteArray();
    });
}
} // namespace

TEST(LaunchGuardVerdict, LaunchersAreRefused)
{
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Application"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Service"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QString())), Verdict::RefuseLauncher) << "no Type: fail closed";
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Unknown"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Link"), QStringLiteral("file:///usr/bin/foot"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Link"), QStringLiteral("/home/u/run.sh"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Link"), QStringLiteral("smb://host/x"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Link"), QStringLiteral("https://"))), Verdict::RefuseLauncher) << "no host";
    // A launcher is refused even when it came with an approval or is executable: desktop entries never run from a folder.
    Facts approved = desktop(QStringLiteral("t.desktop"), QStringLiteral("Application"));
    approved.executable = true;
    approved.approved = true;
    EXPECT_EQ(verdict(approved), Verdict::RefuseLauncher);
}

// Review of a5646b8: a web link handed to KIO is downloaded and run by the handler of the type the server announces (or
// X-KDE-LastOpenedWith). A desktop entry never goes to KIO: a web link's address goes to the default web browser only.
TEST(LaunchGuardVerdict, WebLinksGoToTheBrowserNeverToKio)
{
    const Facts site = desktop(QStringLiteral("site.desktop"), QStringLiteral("Link"), QStringLiteral("https://example.org/"));
    EXPECT_EQ(verdict(site), Verdict::OpenWebLinkInBrowser);
    EXPECT_EQ(webLink(site), QUrl(QStringLiteral("https://example.org/")));
    EXPECT_EQ(verdict(desktop(QStringLiteral("site.desktop"), QStringLiteral("Link"), QStringLiteral("HTTP://example.org/a"))), Verdict::OpenWebLinkInBrowser);
    EXPECT_EQ(verdict(desktop(QStringLiteral("invoice.desktop"), QStringLiteral("Link"), QStringLiteral("http://127.0.0.1:8000/payload.msi"))),
              Verdict::OpenWebLinkInBrowser);
    Facts ambiguous = site;
    ambiguous.desktopAmbiguous = true;
    EXPECT_EQ(verdict(ambiguous), Verdict::RefuseLauncher) << "a repeated key (KConfig keeps the last one): refused";
    EXPECT_FALSE(webLink(ambiguous).isValid());
    EXPECT_EQ(verdict(desktop(QStringLiteral(".directory"), QStringLiteral("Directory"))), Verdict::RefuseLauncher) << "never handed to KIO";
    EXPECT_EQ(verdict(desktop(QStringLiteral("ftp.desktop"), QStringLiteral("Link"), QStringLiteral("ftp://example.org/x"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("js.desktop"), QStringLiteral("Link"), QStringLiteral("javascript:alert(1)"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("bad.desktop"), QStringLiteral("Link"), QStringLiteral("https://exa mple.org/"))), Verdict::RefuseLauncher);
}

TEST(LaunchGuardVerdict, ADesktopNameIsALauncherWhateverTheType)
{
    Facts f = localFile(QStringLiteral("Invoice.pdf.desktop"), QStringLiteral("text/plain"));
    EXPECT_EQ(verdict(f), Verdict::RefuseLauncher);
    f.fileName = QStringLiteral("OLD.KDELNK");
    EXPECT_EQ(verdict(f), Verdict::RefuseLauncher);
}

// The owner's report (2026-11-08): opening a program runs it, by its ELF header, with or without the execute bit (plan() says
// what Open does first).
TEST(LaunchGuardVerdict, NativeProgramsAndAppImagesRunByTheirContent)
{
    EXPECT_EQ(verdict(program(QStringLiteral("tool"))), Verdict::RunProgram);
    EXPECT_EQ(verdict(program(QStringLiteral("tool"), QStringLiteral("application/x-executable"), false)), Verdict::RunProgram);
    EXPECT_EQ(verdict(program(QStringLiteral("libtool.so"), QStringLiteral("application/x-sharedlib"))), Verdict::RunProgram) << "a PIE named .so";
    Facts appImage = program(QStringLiteral("Tool.AppImage"), QStringLiteral("application/vnd.appimage"), false);
    appImage.appImage = true;
    EXPECT_EQ(verdict(appImage), Verdict::RunProgram);
    appImage.fileName = QStringLiteral("Tool-x86_64");
    appImage.mimeType = QStringLiteral("application/octet-stream");
    EXPECT_EQ(verdict(appImage), Verdict::RunProgram) << "no name needed";
    // A shared library or an object is no program: KIO's job (which never runs executables) gets it.
    Facts library = program(QStringLiteral("libz.so.1"), QStringLiteral("application/x-sharedlib"));
    library.elfProgram = false;
    EXPECT_EQ(verdict(library), Verdict::Open);
}

// No name trick: program content shown as a document is never run, whatever the permission bit or the download marks.
TEST(LaunchGuardVerdict, ProgramContentUnderADocumentNameIsRefused)
{
    for (const char *mime : {"image/jpeg", "application/pdf", "text/plain", "text/x-shellscript", "application/x-msdownload", "application/x-troff-man"}) {
        Facts f = program(QStringLiteral("photo.jpg"), QLatin1String(mime));
        EXPECT_EQ(verdict(f), Verdict::RefuseDisguised) << mime;
        f.approved = true;
        EXPECT_EQ(verdict(f), Verdict::RefuseDisguised) << mime << " approved";
    }
}

TEST(LaunchGuardVerdict, ProgramsForAnotherComputerAndElevatedOnesAreRefused)
{
    Facts arm = program(QStringLiteral("tool"));
    arm.elfCompatible = false;
    EXPECT_EQ(verdict(arm), Verdict::RefuseIncompatible);
    Facts setuid = program(QStringLiteral("tool"));
    setuid.elevated = true;
    EXPECT_EQ(verdict(setuid), Verdict::RefuseElevated) << "Files never starts anything with other rights";
}

TEST(LaunchGuardVerdict, ScriptsOpenInTheEditorNeverRun)
{
    const QString exe = QStringLiteral("application/x-executable");
    EXPECT_EQ(verdict(localFile(QStringLiteral("run.sh"), QStringLiteral("application/x-shellscript"), {exe, QStringLiteral("text/plain")}, true)), Verdict::OpenScript);
    EXPECT_EQ(verdict(localFile(QStringLiteral("run.py"), QStringLiteral("text/x-python3"), {QStringLiteral("text/x-python"), exe}, true)), Verdict::OpenScript);
    // Without the permission bit a script is text: KIO opens it in its type's application (KIO and macOS do the same).
    EXPECT_EQ(verdict(localFile(QStringLiteral("run.sh"), QStringLiteral("application/x-shellscript"), {exe, QStringLiteral("text/plain")}, false)), Verdict::Open);
    // Every file of a FAT or NTFS volume has the permission bit: documents still open.
    EXPECT_EQ(verdict(localFile(QStringLiteral("report.pdf"), QStringLiteral("application/pdf"), {}, true)), Verdict::Open);
    EXPECT_EQ(verdict(localFile(QStringLiteral("notes.txt"), QStringLiteral("text/plain"), {}, true)), Verdict::Open);
    // ... and an executable text that starts with "#!" is a script whatever its name: the editor (never a run).
    Facts shebang = localFile(QStringLiteral("notes.txt"), QStringLiteral("text/plain"), {}, true);
    shebang.shebang = true;
    EXPECT_EQ(verdict(shebang), Verdict::OpenScript);
    shebang.fileName = QStringLiteral("Tool.AppImage");
    shebang.mimeType = QStringLiteral("application/vnd.appimage");
    EXPECT_EQ(verdict(shebang), Verdict::OpenScript) << "a script named as an AppImage: still the editor";
}

TEST(LaunchGuardVerdict, AnAppImageThatIsNoProgramIsRefused)
{
    EXPECT_EQ(verdict(localFile(QStringLiteral("Tool.AppImage"), QStringLiteral("application/vnd.appimage"))), Verdict::RefuseNotAnApp);
    EXPECT_EQ(verdict(localFile(QStringLiteral("Tool.appimage"), QStringLiteral("text/plain"))), Verdict::RefuseNotAnApp);
    Facts magicOnly = localFile(QStringLiteral("Tool.AppImage"), QStringLiteral("application/vnd.appimage"), {}, true);
    magicOnly.elf = true; // the ELF magic on a header that is no program
    EXPECT_EQ(verdict(magicOnly), Verdict::RefuseNotAnApp);
}

TEST(LaunchGuardVerdict, WindowsAndJavaProgramsAreExplainedNeverRun)
{
    for (const char *mime : {"application/x-ms-dos-executable", "application/x-msdownload", "application/x-msi", "application/x-powershell", "text/vbscript",
                             "text/vbscript.encode", "text/x-ms-regedit", "application/hta", "application/x-dosexec", "application/x-bat"}) {
        EXPECT_EQ(verdict(localFile(QStringLiteral("item"), QLatin1String(mime))), Verdict::WindowsFile) << mime;
        EXPECT_EQ(verdict(localFile(QStringLiteral("item"), QLatin1String(mime), {}, true)), Verdict::WindowsFile) << mime << " +x";
    }
    for (const char *name : {"fix.ps1", "a.VBS", "a.vbe", "keys.reg", "setup.MSI", "x.exe", "x.com", "x.scr", "x.lnk", "x.bat", "x.cmd", "x.wsf", "x.hta", "x.cpl"})
        EXPECT_EQ(verdict(localFile(QLatin1String(name), QStringLiteral("text/plain"))), Verdict::WindowsFile) << name;
    for (const char *mime : {"application/java-archive", "application/x-java-archive", "application/x-java-jnlp-file"})
        EXPECT_EQ(verdict(localFile(QStringLiteral("item"), QLatin1String(mime))), Verdict::JavaProgram) << mime;
    EXPECT_EQ(verdict(localFile(QStringLiteral("tool.jar"), QStringLiteral("application/zip"))), Verdict::JavaProgram);
    EXPECT_EQ(verdict(localFile(QStringLiteral("start.jnlp"), QStringLiteral("text/plain"))), Verdict::JavaProgram);
}

TEST(LaunchGuardVerdict, AnotherSystemsAppIsExplained)
{
    EXPECT_EQ(verdict(localFile(QStringLiteral("Slack.dmg"), QStringLiteral("application/x-apple-diskimage"))), Verdict::ForeignApp);
    EXPECT_EQ(verdict(localFile(QStringLiteral("Tool.pkg"), QStringLiteral("application/x-xar"))), Verdict::ForeignApp);
    EXPECT_EQ(verdict(localFile(QStringLiteral("Tool.mpkg"), QStringLiteral("application/octet-stream"))), Verdict::ForeignApp);
    EXPECT_EQ(verdict(localFile(QStringLiteral("disk"), QStringLiteral("application/x-apple-diskimage"))), Verdict::ForeignApp);
    EXPECT_EQ(verdict(localFile(QStringLiteral("glibc.pkg.tar.zst"), QStringLiteral("application/zstd"))), Verdict::Open) << "an Arch package is not one";
}

// Nothing runs from a server, a phone or the Trash: the user copies it here first (Files never downloads and runs it).
TEST(LaunchGuardVerdict, RemoteItemsAreJudgedByNameAndNeverRun)
{
    Facts remote;
    remote.fileName = QStringLiteral("t.desktop");
    EXPECT_EQ(verdict(remote), Verdict::RefuseLauncher) << "a desktop entry on a share is never handed to KIO";
    for (const char *name : {"setup.msi", "Tool.AppImage", "tool.jar", "x.exe", "keys.reg"}) {
        remote.fileName = QLatin1String(name);
        EXPECT_EQ(verdict(remote), Verdict::RefuseRemoteProgram) << name;
    }
    remote.fileName = QStringLiteral("Slack.dmg");
    EXPECT_EQ(verdict(remote), Verdict::ForeignApp) << "explained, nothing runs";
    remote.fileName = QStringLiteral("report.pdf");
    EXPECT_EQ(verdict(remote), Verdict::Open);
    Facts folder = localFile(QStringLiteral("bin"), QStringLiteral("inode/directory"), {}, true);
    folder.regularFile = false;
    EXPECT_EQ(verdict(folder), Verdict::Open);
}

// DT-10 as amended: a downloaded program runs only after the user's Open; an approved, unchanged one runs at once.
TEST(LaunchGuardPlan, ADownloadedProgramAsksUntilApproved)
{
    Facts f = program(QStringLiteral("Tool.AppImage"), QStringLiteral("application/vnd.appimage"));
    RunPlan p = plan(f);
    EXPECT_FALSE(p.ask) << "made here (no download mark) and executable: it runs, as from a terminal";
    EXPECT_FALSE(p.downloaded);
    f.originUrl = QStringLiteral("https://downloads.example.org/Tool.AppImage");
    p = plan(f);
    EXPECT_TRUE(p.ask);
    EXPECT_TRUE(p.downloaded);
    EXPECT_FALSE(p.allowRun);
    EXPECT_FALSE(p.copy);
    f.approved = true;
    EXPECT_FALSE(plan(f).ask) << "approved and unchanged: never asked again";
    f.approved = false;
    f.originUrl.clear();
    f.referrerUrl = QStringLiteral("https://example.org/page");
    EXPECT_TRUE(plan(f).ask) << "a referrer alone is a download mark too";
}

TEST(LaunchGuardPlan, OpenAllowsItToRunOrCopiesIt)
{
    Facts f = program(QStringLiteral("Tool.AppImage"), QStringLiteral("application/vnd.appimage"), false);
    RunPlan p = plan(f);
    EXPECT_TRUE(p.ask) << "not executable: the sheet says it will be allowed to run";
    EXPECT_TRUE(p.allowRun);
    EXPECT_FALSE(p.copy);
    f.approved = true;
    EXPECT_TRUE(plan(f).ask) << "approved but the execute bit is gone: asked again";
    f.approved = false;
    f.readOnlyMount = true;
    p = plan(f);
    EXPECT_TRUE(p.copy) << "a read-only disk: copied to ~/Applications";
    EXPECT_FALSE(p.allowRun);
    f.readOnlyMount = false;
    f.ownedByUser = false;
    EXPECT_TRUE(plan(f).copy) << "another user's file can't be made executable here";
    Facts noexec = program(QStringLiteral("Tool"));
    noexec.noexecMount = true;
    p = plan(noexec);
    EXPECT_TRUE(p.ask);
    EXPECT_TRUE(p.copy) << "a noexec mount: nothing runs from there";
}

TEST(LaunchGuardText, OriginHostIsAHostOnly)
{
    Facts f;
    f.originUrl = QStringLiteral("https://user:secret@Downloads.Example.org:8443/a/Tool.AppImage?token=abc#x");
    EXPECT_EQ(originHost(f), QStringLiteral("downloads.example.org"));
    f.originUrl = QStringLiteral("blob:https://example.org/0c7d1a4e-2f3b");
    EXPECT_EQ(originHost(f), QStringLiteral("example.org"));
    f.originUrl = QStringLiteral("data:application/octet-stream;base64,AAAA");
    f.referrerUrl = QStringLiteral("https://www.example.net/download");
    EXPECT_EQ(originHost(f), QStringLiteral("www.example.net")) << "no host in the origin: the referrer's";
    f.referrerUrl.clear();
    EXPECT_TRUE(originHost(f).isEmpty());
    EXPECT_EQ(logName(QStringLiteral("a\nb\x01\"c")), QStringLiteral("a?b??c"));
    EXPECT_EQ(logName(QString::fromUtf8("x\u202Eexe.pdf\u0085y\u2066z")), QStringLiteral("x?exe.pdf?y?z")) << "bidi controls and C1 too";
    EXPECT_EQ(logName(QString(300, QLatin1Char('x'))).size(), 120);
    EXPECT_EQ(approvalValue(42, 1700000000123456789, 4096), QByteArray("1 42 1700000000123456789 4096"));
}

TEST(LaunchGuardText, StoreSearchTermIsTheAppsName)
{
    EXPECT_EQ(storeSearchTerm(QStringLiteral("Slack-4.36.140-macOS.dmg")), QStringLiteral("Slack"));
    EXPECT_EQ(storeSearchTerm(QStringLiteral("Visual Studio Code.dmg")), QStringLiteral("Visual Studio Code"));
    EXPECT_EQ(storeSearchTerm(QStringLiteral("Firefox 133.0.dmg")), QStringLiteral("Firefox"));
    EXPECT_EQ(storeSearchTerm(QStringLiteral("Install_Spotify-universal.pkg")), QStringLiteral("Spotify"));
    EXPECT_EQ(storeSearchTerm(QStringLiteral("1234.dmg")), QStringLiteral("1234")) << "nothing but a number: the name";
}

TEST(LaunchGuardElf, HeadersSayWhatIsAProgram)
{
    ElfHeader h = parseBytes(elfImage(3, true, false));
    EXPECT_TRUE(h.valid);
    EXPECT_TRUE(h.interpreter);
    EXPECT_EQ(h.interpreterPath, QStringLiteral("/lib64/ld-linux-x86-64.so.2"));
    EXPECT_TRUE(h.program()) << "a PIE with an interpreter";
    EXPECT_FALSE(parseBytes(elfImage(3, false, false)).program()) << "a shared library";
    EXPECT_TRUE(parseBytes(elfImage(3, false, true)).program()) << "a static PIE (DF_1_PIE)";
    EXPECT_TRUE(parseBytes(elfImage(2, false, false)).program()) << "ET_EXEC";
    EXPECT_FALSE(parseBytes(elfImage(1, false, false)).program()) << "an object file";
    EXPECT_FALSE(parseBytes(elfImage(4, false, false)).program()) << "a core dump";
    QByteArray appImage = elfImage(2, false, false);
    appImage.replace(8, 3, QByteArray("AI\x02", 3));
    EXPECT_TRUE(parseBytes(appImage).appImage);
    const ElfHeader narrow = parseBytes(elfImage(2, true, false, 3, false));
    EXPECT_TRUE(narrow.program());
    EXPECT_EQ(narrow.elfClass, 1);
    EXPECT_EQ(narrow.machine, 3);
    const ElfHeader big = parseBytes(elfImage(3, true, false, 21, true, true));
    EXPECT_TRUE(big.program());
    EXPECT_EQ(big.byteOrder, 2);
    EXPECT_EQ(big.machine, 21);
    EXPECT_FALSE(parseBytes(QByteArray("\x7f" "ELF", 4) + QByteArray(60, '\0')).valid) << "the magic alone is no header";
    EXPECT_FALSE(parseBytes(QByteArray("\x7f" "ELF\x02\x01", 6)).valid) << "truncated";
    EXPECT_FALSE(parseBytes(QByteArray("MZ") + QByteArray(100, '\0')).valid);
}

TEST(LaunchGuardElf, OnlyThisComputersProgramsRunHere)
{
    QFile self(QStringLiteral("/proc/self/exe"));
    ASSERT_TRUE(self.open(QIODevice::ReadOnly));
    const QByteArray bytes = self.read(64 * 1024);
    const ElfHeader mine = parseBytes(bytes);
    ASSERT_TRUE(mine.valid);
    EXPECT_TRUE(runsHere(mine));
    ElfHeader other = mine;
    other.machine = mine.machine == 183 ? 62 : 183; // aarch64 on x86-64, x86-64 on aarch64
    EXPECT_FALSE(runsHere(other));
    other = mine;
    other.byteOrder = 2;
    EXPECT_FALSE(runsHere(other));
}

TEST(LaunchGuardParse, DesktopEntryGroupOnlyAndRepeatedKeysAreAmbiguous)
{
    DesktopKeys k = parseDesktopEntry("# c\n[Other]\nType=Link\n[Desktop Entry]\n Type = Link \nURL=https://example.org\n[Desktop Action a]\nURL=y\n");
    EXPECT_EQ(k.type, QStringLiteral("Link"));
    EXPECT_EQ(k.url, QStringLiteral("https://example.org"));
    EXPECT_FALSE(k.ambiguous) << "keys of other groups do not count";
    EXPECT_TRUE(parseDesktopEntry("[Desktop Entry]\nType=Link\nURL=https://example.org\nType=Application\n").ambiguous);
    EXPECT_TRUE(parseDesktopEntry("[Desktop Entry]\nType=Link\nURL=https://a.example\n[Desktop Entry]\nURL=https://b.example\n").ambiguous);
    EXPECT_TRUE(parseDesktopEntry("[Desktop Entry]\nType=Link\nURL=https://a.example\nURL[$e]=https://b.example\n").ambiguous);
    k = parseDesktopEntry("[KDE Desktop Entry]\nType=Link\nURL[$e]=https://example.org\n");
    EXPECT_EQ(k.url, QStringLiteral("https://example.org"));
    EXPECT_FALSE(k.ambiguous);
    k = parseDesktopEntry("Type=Link\nURL=https://example.org\n");
    EXPECT_TRUE(k.type.isEmpty()) << "keys outside the group do not count";
    EXPECT_TRUE(k.url.isEmpty());
}

// DT-10 on real files: t.desktop (Type=Application, Exec=touch …), once executable, once not, never opens.
TEST_F(Files, Dt10LauncherRefusedWithAndWithoutPermission)
{
    ASSERT_TRUE(dir.isValid());
    EXPECT_EQ(of(write(QStringLiteral("t.desktop"), kApp, true)), Verdict::RefuseLauncher);
    EXPECT_EQ(of(write(QStringLiteral("u.desktop"), kApp, false)), Verdict::RefuseLauncher);
    EXPECT_EQ(of(write(QStringLiteral("Invoice.pdf.desktop"), kApp, false)), Verdict::RefuseLauncher);
    const Facts renamed = inspect(QUrl::fromLocalFile(write(QStringLiteral("readme.txt"), kApp, false)));
    EXPECT_EQ(verdict(renamed), Verdict::Open) << renamed.mimeType.toStdString();
    EXPECT_EQ(of(write(QStringLiteral("site.desktop"), "[Desktop Entry]\nType=Link\nURL=https://example.org/\n", false)), Verdict::OpenWebLinkInBrowser);
    const Facts lastOpened = inspect(QUrl::fromLocalFile(write(QStringLiteral("payload.desktop"),
        "[Desktop Entry]\nType=Link\nURL=http://127.0.0.1:8000/payload.msi\nX-KDE-LastOpenedWith=attacker-chosen-app\n", false)));
    EXPECT_EQ(verdict(lastOpened), Verdict::OpenWebLinkInBrowser);
    EXPECT_EQ(webLink(lastOpened), QUrl(QStringLiteral("http://127.0.0.1:8000/payload.msi")));
    EXPECT_EQ(of(write(QStringLiteral("twice.desktop"), "[Desktop Entry]\nType=Link\nURL=https://example.org/\nURL=file:///usr/bin/true\n", false)),
              Verdict::RefuseLauncher) << "KConfig would use the last URL";
    EXPECT_EQ(of(write(QStringLiteral("big.desktop"), "[Desktop Entry]\nType=Link\nURL=https://example.org/\n#" + QByteArray(70 * 1024, 'x') + "\n", false)),
              Verdict::RefuseLauncher) << "longer than what is read: keys past the end are unknown";
    EXPECT_EQ(of(write(QStringLiteral(".directory"), "[Desktop Entry]\nIcon=folder-red\n", false)), Verdict::RefuseLauncher);
    EXPECT_EQ(of(write(QStringLiteral("file.desktop"), "[Desktop Entry]\nType=Link\nURL=file:///usr/bin/true\n", false)), Verdict::RefuseLauncher);
    const QString unreadable = write(QStringLiteral("locked.desktop"), "[Desktop Entry]\nType=Link\nURL=https://example.org/\n", false);
    ASSERT_TRUE(QFile::setPermissions(unreadable, QFileDevice::Permissions()));
    EXPECT_EQ(of(unreadable), Verdict::RefuseLauncher) << "an unreadable entry has no known Type: refused";
    QFile::setPermissions(unreadable, QFile::ReadOwner | QFile::WriteOwner);
}

TEST_F(Files, ScriptsWindowsJavaAndFakeAppsOnDisk)
{
    ASSERT_TRUE(dir.isValid());
    EXPECT_EQ(of(write(QStringLiteral("run.sh"), "#!/bin/sh\ntouch /tmp/gf-dt10\n", true)), Verdict::OpenScript);
    EXPECT_EQ(of(write(QStringLiteral("run2.sh"), "#!/bin/sh\ntouch /tmp/gf-dt10\n", false)), Verdict::Open);
    EXPECT_EQ(of(write(QStringLiteral("noext"), "#!/usr/bin/env python3\nprint(1)\n", true)), Verdict::OpenScript);
    EXPECT_EQ(of(write(QStringLiteral("notes.txt"), "just text\n", true)), Verdict::Open);
    EXPECT_EQ(of(write(QStringLiteral("setup.exe"), QByteArray("MZ\x90\x00", 4) + QByteArray(60, '\0'), false)), Verdict::WindowsFile);
    EXPECT_EQ(of(write(QStringLiteral("setup"), QByteArray("MZ\x90\x00", 4) + QByteArray(200, '\0'), true)), Verdict::WindowsFile)
        << "a Windows program without its extension: by content";
    EXPECT_EQ(of(write(QStringLiteral("tool.jar"), QByteArray("PK\x03\x04", 4) + QByteArray(60, '\0'), false)), Verdict::JavaProgram);
    EXPECT_EQ(of(write(QStringLiteral("App.AppImage"), QByteArray("\x7f" "ELF", 4) + QByteArray(60, '\0'), false)), Verdict::RefuseNotAnApp)
        << "the ELF magic on no ELF header is no app";
    EXPECT_EQ(of(write(QStringLiteral("fix.ps1"), "Remove-Item x\n", false)), Verdict::WindowsFile);
    EXPECT_EQ(of(write(QStringLiteral("a.vbs"), "MsgBox 1\n", false)), Verdict::WindowsFile);
    EXPECT_EQ(of(write(QStringLiteral("keys.reg"), "Windows Registry Editor Version 5.00\n", false)), Verdict::WindowsFile);
    EXPECT_EQ(of(write(QStringLiteral("start.jnlp"), "<jnlp/>\n", false)), Verdict::JavaProgram);
    EXPECT_EQ(of(write(QStringLiteral("Slack-4.36.dmg"), QByteArray(512, 'x'), false)), Verdict::ForeignApp);
    EXPECT_EQ(of(dir.path()), Verdict::Open) << "a folder navigates";
}

TEST_F(Files, NativeProgramsByContentAndThroughLinks)
{
    ASSERT_TRUE(dir.isValid());
    const QString tool = nativeProgram(QStringLiteral("tool"), true);
    if (tool.isEmpty())
        GTEST_SKIP() << "no /usr/bin/true";
    const Facts facts = inspect(QUrl::fromLocalFile(tool));
    EXPECT_EQ(verdict(facts), Verdict::RunProgram);
    EXPECT_TRUE(facts.elfProgram);
    EXPECT_TRUE(facts.elfCompatible);
    EXPECT_FALSE(facts.elevated);
    EXPECT_EQ(facts.path, QFileInfo(tool).canonicalFilePath());
    EXPECT_FALSE(plan(facts).ask) << "made here, executable: runs at once";
    // Without the permission bit (a download): it runs after the sheet, which allows it.
    const QString plain = nativeProgram(QStringLiteral("tool2"), false);
    const Facts plainFacts = inspect(QUrl::fromLocalFile(plain));
    EXPECT_EQ(verdict(plainFacts), Verdict::RunProgram);
    EXPECT_TRUE(plan(plainFacts).allowRun);
    // The same program named as a document: refused, executable or not.
    EXPECT_EQ(of(nativeProgram(QStringLiteral("photo.jpg"), true)), Verdict::RefuseDisguised);
    EXPECT_EQ(of(nativeProgram(QStringLiteral("notes.txt"), false)), Verdict::RefuseDisguised);
    EXPECT_EQ(of(nativeProgram(QStringLiteral("run.sh"), true)), Verdict::RefuseDisguised) << "a program shown as a shell script";
    EXPECT_EQ(of(nativeProgram(QStringLiteral("setup.exe"), true)), Verdict::RefuseDisguised) << "a program shown as a Windows one";
    // Through a symbolic link: the target decides what it is and where it runs; the link's name is what the user sees.
    const QString link = dir.filePath(QStringLiteral("report"));
    ASSERT_TRUE(QFile::link(tool, link));
    const Facts linked = inspect(QUrl::fromLocalFile(link));
    EXPECT_EQ(verdict(linked), Verdict::RunProgram);
    EXPECT_EQ(linked.fileName, QStringLiteral("report"));
    EXPECT_EQ(linked.path, QFileInfo(tool).canonicalFilePath());
    const QString disguisedLink = dir.filePath(QStringLiteral("report.pdf"));
    ASSERT_TRUE(QFile::link(tool, disguisedLink));
    EXPECT_EQ(of(disguisedLink), Verdict::RefuseDisguised) << "a link named as a document to a program";
    // A program for another computer: its machine changed in the header.
    const QString foreign = nativeProgram(QStringLiteral("arm-tool"), true);
    {
        QFile f(foreign);
        ASSERT_TRUE(f.open(QIODevice::ReadWrite));
        ASSERT_TRUE(f.seek(18));
        // aarch64 (183) on any other computer, x86-64 (62) on an aarch64 one.
        f.write(QSysInfo::currentCpuArchitecture() == QLatin1String("arm64") ? QByteArray("\x3e\x00", 2) : QByteArray("\xb7\x00", 2));
    }
    EXPECT_EQ(of(foreign), Verdict::RefuseIncompatible);
    // setuid: never started by Files.
    const QString setuid = nativeProgram(QStringLiteral("elevated"), true);
    ASSERT_EQ(::chmod(QFile::encodeName(setuid).constData(), 04755), 0);
    EXPECT_EQ(of(setuid), Verdict::RefuseElevated);
}

// DT-10 as amended, on real files: a downloaded program (a browser's user.xdg.origin.url) is asked about until the user's
// Open; Files' approval then lets it run without a sheet, until the file changes.
TEST_F(Files, Dt10DownloadedProgramRunsOnlyAfterConsentAndAsksAgainWhenChanged)
{
    ASSERT_TRUE(dir.isValid());
    const QString path = nativeProgram(QStringLiteral("Tool.AppImage"), false);
    if (path.isEmpty())
        GTEST_SKIP() << "no /usr/bin/true";
    markAppImage(path);
    if (!markDownloaded(path, "https://downloads.example.org/Tool.AppImage"))
        GTEST_SKIP() << "no user extended attributes on " << dir.path().toStdString();
    Facts f = inspect(QUrl::fromLocalFile(path));
    EXPECT_EQ(verdict(f), Verdict::RunProgram);
    EXPECT_TRUE(f.appImage);
    EXPECT_EQ(originHost(f), QStringLiteral("downloads.example.org"));
    RunPlan p = plan(f);
    EXPECT_TRUE(p.ask);
    EXPECT_TRUE(p.downloaded);
    EXPECT_TRUE(p.allowRun);
    EXPECT_FALSE(f.approved);
    // A forged approval of another identity changes nothing.
    const QByteArray forged = approvalValue(f.inode + 1, f.mtimeNs, f.size);
    ASSERT_EQ(::setxattr(QFile::encodeName(path).constData(), "user.grassfield.approved", forged.constData(), size_t(forged.size()), 0), 0);
    EXPECT_FALSE(inspect(QUrl::fromLocalFile(path)).approved);
    // The user's Open: execute bit and approval.
    ASSERT_EQ(ProgramLaunch::approve(f.path, f.inode, f.mtimeNs, f.size, p.allowRun), ProgramLaunch::Approval::Approved);
    f = inspect(QUrl::fromLocalFile(path));
    EXPECT_TRUE(f.executable);
    EXPECT_TRUE(f.approved);
    EXPECT_FALSE(plan(f).ask) << "approved and unchanged: never asked again";
    // Changed in place: asked again.
    {
        QFile file(path);
        ASSERT_TRUE(file.open(QIODevice::Append));
        file.write("x");
    }
    f = inspect(QUrl::fromLocalFile(path));
    EXPECT_FALSE(f.approved);
    EXPECT_TRUE(plan(f).ask);
    // A link to it follows its trust (the download mark and the approval are the target's).
    const QString link = dir.filePath(QStringLiteral("Tool"));
    ASSERT_TRUE(QFile::link(path, link));
    const Facts linked = inspect(QUrl::fromLocalFile(link));
    EXPECT_EQ(originHost(linked), QStringLiteral("downloads.example.org"));
    EXPECT_TRUE(plan(linked).ask);
}

// Review of 0c51550e (MAJOR): invisible characters never get round the disguise refusal. Names are decided on cleanName():
// trailing spaces and dots go, format and default-ignorable characters go, NFC.
TEST(LaunchGuardNames, CleanNameDropsWhatTheEyeDoesNotSee)
{
    EXPECT_EQ(cleanName(QStringLiteral("Invoice.pdf ")), QStringLiteral("Invoice.pdf"));
    EXPECT_EQ(cleanName(QStringLiteral("Invoice.pdf. . ")), QStringLiteral("Invoice.pdf"));
    EXPECT_EQ(cleanName(QStringLiteral("Invoice.pdf\u00a0")), QStringLiteral("Invoice.pdf")) << "a no-break space";
    EXPECT_EQ(cleanName(QStringLiteral("Invoice.pdf\u3000")), QStringLiteral("Invoice.pdf")) << "an ideographic space";
    EXPECT_EQ(cleanName(QStringLiteral("Invoice.pdf\u200b")), QStringLiteral("Invoice.pdf")) << "a zero-width space";
    EXPECT_EQ(cleanName(QStringLiteral("Inv\u200doice.p\u00addf\ufeff")), QStringLiteral("Invoice.pdf")) << "joiner, soft hyphen, BOM";
    EXPECT_EQ(cleanName(QStringLiteral("Invoice.pd\u034ff\u2060")), QStringLiteral("Invoice.pdf")) << "grapheme joiner, word joiner";
    EXPECT_EQ(cleanName(QStringLiteral("Invoice\u202efdp.exe")), QStringLiteral("Invoicefdp.exe")) << "RLO: the real name is an .exe";
    EXPECT_EQ(cleanName(QStringLiteral("Invoice\u2066.pdf\u2069")), QStringLiteral("Invoice.pdf"));
    EXPECT_EQ(cleanName(QString::fromUcs4(U"Invoice.pdf\U000E0001", -1)), QStringLiteral("Invoice.pdf")) << "a tag character";
    EXPECT_EQ(cleanName(QStringLiteral("Cafe\u0301.pdf")), QStringLiteral("Cafe.pdf")) << "combining marks are dropped";
    EXPECT_EQ(cleanName(QStringLiteral("Caf\u00e9.pdf")), QStringLiteral("Cafe.pdf")) << "also from a precomposed letter (NFKD)";
    EXPECT_EQ(cleanName(QStringLiteral("Tool")), QStringLiteral("Tool"));
}

TEST(LaunchGuardNames, InvisibleCharactersDoNotHideADisguise)
{
    for (const QString &name : {QStringLiteral("Invoice.pdf"), QStringLiteral("Invoice.pdf "), QStringLiteral("Invoice.pdf\u200b"), QStringLiteral("Invoice.pdf\u00a0"),
                                QStringLiteral("Invoice.pdf."), QStringLiteral("Invoice\u202efdp.exe"), QStringLiteral("photo.jpg\u2060"), QStringLiteral("run.sh\ufeff")}) {
        // The kind Files shows may already be a program's (the name's pattern no longer matches): the cleaned name decides.
        Facts f = program(name, QStringLiteral("application/x-executable"));
        EXPECT_EQ(verdict(f), Verdict::RefuseDisguised) << name.toStdString();
        f.originUrl = QStringLiteral("https://example.org/");
        f.approved = true;
        EXPECT_EQ(verdict(f), Verdict::RefuseDisguised) << name.toStdString() << " approved";
    }
    EXPECT_EQ(verdict(program(QStringLiteral("Tool "))), Verdict::RunProgram) << "no kind behind the space: a program";
    EXPECT_EQ(verdict(program(QStringLiteral("Tool.AppImage "), QStringLiteral("application/octet-stream"))), Verdict::RunProgram);
    // Not a program: the cleaned name still decides what it is.
    EXPECT_EQ(verdict(localFile(QStringLiteral("setup.exe "), QStringLiteral("application/octet-stream"))), Verdict::WindowsFile);
    EXPECT_EQ(verdict(localFile(QStringLiteral("t.desktop\u200b"), QStringLiteral("application/octet-stream"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(localFile(QStringLiteral("Slack.dmg\u200b"), QStringLiteral("application/octet-stream"))), Verdict::ForeignApp);
    Facts remote;
    remote.fileName = QStringLiteral("Tool.AppImage\u200b");
    EXPECT_EQ(verdict(remote), Verdict::RefuseRemoteProgram);
}

// Review of 0c51550e (MINOR 1): uwsm reads "…/Tool.desktop:run" as the desktop entry Tool.desktop with its action "run".
TEST(LaunchGuardNames, WhatUwsmReadsAsADesktopEntryIsNeverRun)
{
    EXPECT_TRUE(uwsmReadsAsEntry(QStringLiteral("/home/u/Tool.desktop:run")));
    EXPECT_TRUE(uwsmReadsAsEntry(QStringLiteral("/home/u/a.desktop:x/tool")));
    EXPECT_TRUE(uwsmReadsAsEntry(QStringLiteral("/home/u/Tool.desktop")));
    EXPECT_FALSE(uwsmReadsAsEntry(QStringLiteral("/home/u/Tool.AppImage")));
    EXPECT_FALSE(uwsmReadsAsEntry(QStringLiteral("/home/u/desktop/tool")));
    Facts f = program(QStringLiteral("Tool.desktop:run"));
    f.path = QStringLiteral("/home/u/Tool.desktop:run");
    EXPECT_EQ(verdict(f), Verdict::RefuseLauncher);
    f = program(QStringLiteral("tool"));
    f.path = QStringLiteral("/home/u/apps.desktop:x/tool");
    EXPECT_EQ(verdict(f), Verdict::RefuseLauncher) << "the whole path is uwsm's main argument";
    EXPECT_FALSE(ProgramLaunch::Run::allowed({QStringLiteral("uwsm-app"), QStringLiteral("--"), QStringLiteral("/home/u/Tool.desktop:run")}));
    EXPECT_FALSE(ProgramLaunch::Run::allowed({QStringLiteral("/usr/bin/uwsm-app"), QStringLiteral("--"), QStringLiteral("/home/u/x.desktop")}));
    EXPECT_TRUE(ProgramLaunch::Run::allowed({QStringLiteral("uwsm-app"), QStringLiteral("--"), QStringLiteral("/home/u/Tool.AppImage")}));
    EXPECT_TRUE(ProgramLaunch::Run::allowed({QStringLiteral("/home/u/Tool.desktop:run")})) << "without uwsm the path is only a path";
    EXPECT_FALSE(ProgramLaunch::Run::allowed({}));
}

TEST(LaunchGuardText, AHostThatMixesScriptsIsShownInAscii)
{
    Facts f;
    f.originUrl = QStringLiteral("https://p\u0430ypal.example/"); // a Cyrillic "a" among Latin letters
    EXPECT_EQ(originHost(f), QString::fromLatin1(QUrl::toAce(QStringLiteral("p\u0430ypal.example"))));
    EXPECT_TRUE(originHost(f).startsWith(QStringLiteral("xn--")));
    for (const char *tld : {"example", "com", "de"}) {
        f.originUrl = QStringLiteral("https://p\u0430ypal.") + QLatin1String(tld) + QStringLiteral("/");
        EXPECT_TRUE(originHost(f).startsWith(QStringLiteral("xn--"))) << tld << ": " << originHost(f).toStdString();
    }
    // One script per label: Qt's own form (Unicode for the TLDs it trusts with IDN, ASCII for the others), unchanged.
    for (const QString &host : {QStringLiteral("b\u00fccher.de"), QStringLiteral("\u043f\u0440\u0438\u043c\u0435\u0440.com"), QStringLiteral("b\u00fccher.example")}) {
        f.originUrl = QStringLiteral("https://") + host + QStringLiteral("/");
        EXPECT_EQ(originHost(f), QUrl(f.originUrl).host(QUrl::FullyDecoded).toLower()) << host.toStdString();
    }
}

// Review of 0c51550e (BLOCKER and MINOR 5): the download marks follow a file out of an archive and from a server.
TEST_F(Files, DownloadMarksAreCopiedOntoEveryFileButNeverThroughALink)
{
    ASSERT_TRUE(dir.isValid());
    const QString archive = write(QStringLiteral("Tool.zip"), "PK", false);
    const DownloadMarks marks{"https://downloads.example.org/Tool.zip", "https://www.example.org/"};
    if (::setxattr(QFile::encodeName(archive).constData(), "user.xdg.origin.url", marks.origin.constData(), size_t(marks.origin.size()), 0) != 0)
        GTEST_SKIP() << "no user extended attributes on " << dir.path().toStdString();
    ::setxattr(QFile::encodeName(archive).constData(), "user.xdg.referrer.url", marks.referrer.constData(), size_t(marks.referrer.size()), 0);
    const DownloadMarks read = downloadMarks(archive);
    EXPECT_EQ(read.origin, marks.origin);
    EXPECT_EQ(read.referrer, marks.referrer);
    EXPECT_FALSE(downloadMarks(dir.filePath(QStringLiteral("missing"))).any());

    // An extracted tree as bsdtar leaves it (counter-review of 48475cf6, B1): files of mode 0100, 0500 and 0555, folders of mode
    // 0100 and 0300 with programs inside, and a link to a file outside the tree.
    QDir().mkpath(dir.filePath(QStringLiteral("tree/bin")));
    QDir().mkpath(dir.filePath(QStringLiteral("tree/locked")));
    QDir().mkpath(dir.filePath(QStringLiteral("tree/blind")));
    struct Item {
        QString path;
        unsigned mode;
    };
    const QList<Item> files = {{write(QStringLiteral("tree/README"), "x", false), 0600},
                               {write(QStringLiteral("tree/bin/tool"), "\x7f" "ELF", true), 0700},
                               {write(QStringLiteral("tree/bin/locked"), "\x7f" "ELF", false), 0100},
                               {write(QStringLiteral("tree/bin/readonly"), "\x7f" "ELF", false), 0500},
                               {write(QStringLiteral("tree/bin/everyone"), "\x7f" "ELF", false), 0555},
                               {write(QStringLiteral("tree/locked/prog"), "\x7f" "ELF", true), 0755},
                               {write(QStringLiteral("tree/blind/prog"), "\x7f" "ELF", true), 0755}};
    for (const Item &item : files)
        ASSERT_EQ(::chmod(QFile::encodeName(item.path).constData(), item.mode), 0) << item.path.toStdString();
    const QString outside = write(QStringLiteral("outside"), "y", false);
    ASSERT_TRUE(QFile::link(outside, dir.filePath(QStringLiteral("tree/link"))));
    ASSERT_EQ(::chmod(QFile::encodeName(dir.filePath(QStringLiteral("tree/locked"))).constData(), 0100), 0);
    ASSERT_EQ(::chmod(QFile::encodeName(dir.filePath(QStringLiteral("tree/blind"))).constData(), 0300), 0);

    const TreeMarks result = markTree(dir.filePath(QStringLiteral("tree")), read);
    EXPECT_TRUE(result.complete);
    EXPECT_EQ(result.files, 7);
    // Modes are given back, folders included.
    auto modeOf = [](const QString &path) {
        struct stat st{};
        return ::lstat(QFile::encodeName(path).constData(), &st) == 0 ? unsigned(st.st_mode & 07777) : 0xffffffffu;
    };
    for (const Item &item : files)
        EXPECT_EQ(modeOf(item.path), item.mode) << item.path.toStdString();
    EXPECT_EQ(modeOf(dir.filePath(QStringLiteral("tree/locked"))), 0100u);
    EXPECT_EQ(modeOf(dir.filePath(QStringLiteral("tree/blind"))), 0300u);
    // Every file carries the marks (opened up here only to read them).
    EXPECT_TRUE(openTree(dir.filePath(QStringLiteral("tree"))));
    for (const Item &item : files) {
        ::chmod(QFile::encodeName(item.path).constData(), 0600);
        EXPECT_EQ(downloadMarks(item.path).origin, marks.origin) << item.path.toStdString();
        EXPECT_EQ(downloadMarks(item.path).referrer, marks.referrer) << item.path.toStdString();
    }
    EXPECT_FALSE(downloadMarks(outside).any()) << "a link is never followed";
    EXPECT_TRUE(markTree(dir.filePath(QStringLiteral("tree")), DownloadMarks{}).complete) << "nothing to copy: nothing to fail";
    EXPECT_EQ(markTree(dir.filePath(QStringLiteral("tree")), DownloadMarks{}).files, 0);
}

// Fail closed: past the cap, a refused walk or a tree deeper than 256 folders, the marking is not complete (and Expand keeps
// nothing).
TEST_F(Files, MarkTreeFailsClosed)
{
    ASSERT_TRUE(dir.isValid());
    const DownloadMarks marks{"https://downloads.example.org/Kit.zip", QByteArray()};
    QDir().mkpath(dir.filePath(QStringLiteral("kit")));
    for (int i = 0; i < 5; ++i)
        write(QStringLiteral("kit/f%1").arg(i), "x", false);
    if (!markFile(dir.filePath(QStringLiteral("kit/f0")), marks))
        GTEST_SKIP() << "no user extended attributes on " << dir.path().toStdString();
    EXPECT_TRUE(markTree(dir.filePath(QStringLiteral("kit")), marks, 5).complete) << "five entries, a cap of five";
    const TreeMarks capped = markTree(dir.filePath(QStringLiteral("kit")), marks, 4);
    EXPECT_FALSE(capped.complete) << "past the cap";
    EXPECT_EQ(capped.entries, 5);
    EXPECT_FALSE(markTree(dir.filePath(QStringLiteral("kit")), marks, 0, [](qint64) { return false; }).complete) << "stopped (a cancel)";
    // 257 folders deep.
    QString deep = dir.filePath(QStringLiteral("deep"));
    for (int i = 0; i < 257; ++i)
        deep += QStringLiteral("/d");
    ASSERT_TRUE(QDir().mkpath(deep));
    write(QStringLiteral("deep") + QString(257, QLatin1Char('/')).replace(QLatin1Char('/'), QStringLiteral("/d")).mid(0) + QStringLiteral("/tool"), "\x7f" "ELF", true);
    EXPECT_FALSE(markTree(dir.filePath(QStringLiteral("deep")), marks).complete) << "deeper than 256 folders";
    EXPECT_FALSE(markTree(dir.filePath(QStringLiteral("missing")), marks).complete) << "no tree";
}

TEST(LaunchGuardMarks, RemoteSourcesGiveTheirAddressWithoutCredentials)
{
    EXPECT_EQ(remoteOrigin(QUrl(QStringLiteral("sftp://user:secret@host.example/home/u/Tool.AppImage"))), QByteArray("sftp://host.example/home/u/Tool.AppImage"));
    EXPECT_EQ(remoteOrigin(QUrl(QStringLiteral("smb://nas/share/setup.exe"))), QByteArray("smb://nas/share/setup.exe"));
    EXPECT_EQ(remoteOrigin(QUrl(QStringLiteral("https://example.org/a"))), QByteArray("https://example.org/a"));
    EXPECT_EQ(remoteOrigin(QUrl(QStringLiteral("mtp:/Phone/Download/tool"))), QByteArray("mtp:/Phone/Download/tool"));
    for (const char *local : {"file:///home/u/tool", "trash:/0-tool", "recentlyused:/files", "tags:/red", "desktop:/tool"})
        EXPECT_TRUE(remoteOrigin(QUrl(QLatin1String(local))).isEmpty()) << local;
    EXPECT_TRUE(remoteOrigin(QUrl()).isEmpty());
}

// Counter-review of 48475cf6 (M1): no lookalike dot, blank glyph, combining mark or lookalike letter hides a document's name on
// a program. The UTS #39 skeleton is not used (it would need ICU's i18n library directly): a program whose cleaned name's
// extension is not plain ASCII is refused, which covers every lookalike letter.
TEST(LaunchGuardNames, LookalikesNeverHideADocumentsName)
{
    // Folded to the plain name.
    EXPECT_EQ(cleanName(QStringLiteral("Invoice.pdf\u2800")), QStringLiteral("Invoice.pdf")) << "a braille blank";
    EXPECT_EQ(cleanName(QStringLiteral("Invoice\u2024pdf")), QStringLiteral("Invoice.pdf")) << "one dot leader";
    EXPECT_EQ(cleanName(QStringLiteral("photo\uff0ejpg")), QStringLiteral("photo.jpg")) << "a fullwidth full stop";
    EXPECT_EQ(cleanName(QStringLiteral("photo\ufe52jpg")), QStringLiteral("photo.jpg")) << "a small full stop";
    EXPECT_EQ(cleanName(QStringLiteral("Invoice\u3002pdf")), QStringLiteral("Invoice.pdf")) << "an ideographic full stop";
    EXPECT_EQ(cleanName(QStringLiteral("Invoice\u0701pdf")), QStringLiteral("Invoice.pdf")) << "a Syriac supralinear full stop";
    EXPECT_EQ(cleanName(QStringLiteral("Invoice\u00b7pdf")), QStringLiteral("Invoice.pdf")) << "a middle dot";
    EXPECT_EQ(cleanName(QStringLiteral("Invoice.pdf\u0301")), QStringLiteral("Invoice.pdf")) << "a combining acute";
    EXPECT_EQ(cleanName(QStringLiteral("Invoice.pdf\u0323\u0301")), QStringLiteral("Invoice.pdf")) << "combining marks";
    EXPECT_EQ(cleanName(QStringLiteral("\uff29nvoice.pdf")), QStringLiteral("Invoice.pdf")) << "a fullwidth letter";
    EXPECT_EQ(cleanName(QStringLiteral("Invoice\u115f\u1160.pdf\uffa0")), QStringLiteral("Invoice.pdf")) << "Hangul fillers";

    // On program content, each is refused as a disguise, approved or not.
    for (const QString &name : {QStringLiteral("Invoice.pdf\u2800"), QStringLiteral("Invoice\u2024pdf"), QStringLiteral("photo\uff0ejpg"),
                                QStringLiteral("photo\ufe52jpg"), QStringLiteral("Invoice\u3002pdf"), QStringLiteral("Invoice\u0701pdf"),
                                QStringLiteral("Invoice.pdf\u0301"), QStringLiteral("Invoice.pdf\u0323"),
                                // Lookalike letters: Cyrillic er in "pdf", Greek rho in "pdf", Cyrillic ie and ha in "exe", Greek epsilon in
                                // "exe", Cyrillic je and er in "jpg", Greek omicron-free "jpg" with a Cyrillic er.
                                QStringLiteral("Invoice.\u0440df"), QStringLiteral("Invoice.\u03c1df"), QStringLiteral("setup.\u0435x\u0435"),
                                QStringLiteral("setup.\u0435\u0445\u0435"), QStringLiteral("setup.\u03b5x\u03b5"), QStringLiteral("photo.\u0458pg"),
                                QStringLiteral("photo.j\u0440g"), QStringLiteral("Invoice\u2024\u0440df")}) {
        Facts f = program(name, QStringLiteral("application/x-executable"));
        EXPECT_EQ(verdict(f), Verdict::RefuseDisguised) << name.toStdString();
        f.originUrl = QStringLiteral("https://example.org/");
        f.approved = true;
        EXPECT_EQ(verdict(f), Verdict::RefuseDisguised) << name.toStdString() << " approved";
    }

    // A program's own names still run: no extension, an ASCII one, letters with accents before the extension.
    for (const QString &name : {QStringLiteral("Tool"), QStringLiteral("\u00c9diteur"), QStringLiteral("Cr\u00e9ateur"), QStringLiteral("Spiel.x86_64"),
                                QStringLiteral("Lecteur-vid\u00e9o.AppImage"), QStringLiteral("\u65e5\u672c")}) {
        Facts f = program(name, QStringLiteral("application/x-executable"));
        EXPECT_EQ(verdict(f), Verdict::RunProgram) << name.toStdString();
    }
}

// Second counter-review of fd5823de (m1): the list of dot lookalikes can't be complete, so a program whose name ends in a
// document's or an archive's letters right after anything but an ASCII dot is refused as a disguise, whatever that character
// is: the four UTS #39 lookalikes of the middle dot (U+A78F, U+16EB, U+1427, U+10101), the others the review found, a
// combining dot below, and every punctuation and symbol character of Unicode.
TEST(LaunchGuardNames, ADocumentsLettersAfterAnythingButADotAreADisguise)
{
    const QList<QString> separators = {QStringLiteral("\ua78f"), QStringLiteral("\u16eb"), QStringLiteral("\u1427"), QString::fromUcs4(U"\U00010101"),
                                       QStringLiteral("\u2022"), QStringLiteral("\u2981"), QStringLiteral("\u02d9"), QStringLiteral("\u0f0b"),
                                       QStringLiteral("\u2e30"), QStringLiteral("\u2e3c"), QStringLiteral("\u1803"), QStringLiteral("\u0323"),
                                       QStringLiteral("e\u0323"), QStringLiteral("\u1eb9"), QStringLiteral("\u2122"), QStringLiteral("-"),
                                       QStringLiteral("_"), QStringLiteral(" "), QStringLiteral(","), QStringLiteral("\u2800")};
    for (const QString &x : separators) {
        for (const QString &name : {QStringLiteral("Invoice") + x + QStringLiteral("pdf"), QStringLiteral("photo") + x + QStringLiteral("jpg"),
                                    QStringLiteral("setup") + x + QStringLiteral("exe"), QStringLiteral("Invoice") + x + QStringLiteral("pdf "),
                                    QStringLiteral("backup") + x + QStringLiteral("zip")}) {
            Facts f = program(name, QStringLiteral("application/x-executable"));
            EXPECT_TRUE(documentTailAfterOtherThanDot(name)) << name.toStdString();
            EXPECT_EQ(verdict(f), Verdict::RefuseDisguised) << name.toStdString();
            f.approved = true;
            EXPECT_EQ(verdict(f), Verdict::RefuseDisguised) << name.toStdString() << " approved";
        }
    }
    // Every punctuation and symbol character of Unicode (the categories P and S) before "pdf".
    int checked = 0;
    for (char32_t c = 0x21; c <= 0x10FFFF; ++c) {
        if (c >= 0xD800 && c <= 0xDFFF)
            continue;
        const QChar::Category category = QChar::category(c);
        const bool punctuationOrSymbol = (category >= QChar::Punctuation_Connector && category <= QChar::Punctuation_Other)
            || (category >= QChar::Symbol_Math && category <= QChar::Symbol_Other);
        if (!punctuationOrSymbol)
            continue;
        const QString name = QStringLiteral("Invoice") + QString::fromUcs4(&c, 1) + QStringLiteral("pdf");
        EXPECT_EQ(verdict(program(name)), Verdict::RefuseDisguised) << "U+" << std::hex << unsigned(c);
        ++checked;
    }
    EXPECT_GT(checked, 7000) << "the punctuation and symbol characters of Qt's Unicode tables";
}

// The same rule leaves a program's own names alone: no document's letters at the end, digits only, accents in a word (also
// decomposed, as another system may write them), an ASCII extension of a program.
TEST(LaunchGuardNames, AProgramsOwnNamesStillRun)
{
    for (const QString &name : {QStringLiteral("Tool"), QStringLiteral("nvim-linux64"), QStringLiteral("Spiel.x86_64"), QStringLiteral("code-1.95"),
                                QStringLiteral("Godot_v4.3-stable_linux.x86_64"), QStringLiteral("Cr\u00e9ateur"), QStringLiteral("Cre\u0301ateur"),
                                QStringLiteral("my-tool"), QStringLiteral("Tool-1.0-x86_64.AppImage"), QStringLiteral("\u00c9diteur"), QStringLiteral("Th\u00e9"),
                                QStringLiteral("signal-desktop"), QStringLiteral("obs-studio"), QStringLiteral("steam-runtime"), QStringLiteral("my-program")}) {
        EXPECT_FALSE(documentTailAfterOtherThanDot(name)) << name.toStdString();
        EXPECT_EQ(verdict(program(name)), Verdict::RunProgram) << name.toStdString();
    }
}

// m2: an Expand's or a Compress's staging name, anywhere in the path, is refused, whatever is in it.
TEST(LaunchGuardStaging, AStagingNameAnywhereInThePathIsRefused)
{
    EXPECT_TRUE(insideStaging(QStringLiteral("/home/u/Downloads/.grassfield-expand-0a1b2c3d/Tool")));
    EXPECT_TRUE(insideStaging(QStringLiteral("/home/u/Downloads/.grassfield-expand-0a1b2c3d")));
    EXPECT_TRUE(insideStaging(QStringLiteral(".grassfield-expand-0a1b2c3d")));
    EXPECT_TRUE(insideStaging(QStringLiteral("/home/u/.grassfield-compress-deadbeef.zip")));
    EXPECT_TRUE(insideStaging(QStringLiteral("/a/.grassfield-expand-00000000/b/c/d")));
    EXPECT_FALSE(insideStaging(QStringLiteral("/home/u/Downloads/.grassfield-expand-0a1b2c3/Tool"))) << "seven digits";
    EXPECT_FALSE(insideStaging(QStringLiteral("/home/u/.grassfield-expand-0A1B2C3D/Tool"))) << "Files writes lowercase hex";
    EXPECT_FALSE(insideStaging(QStringLiteral("/home/u/grassfield-expand-0a1b2c3d/Tool")));
    EXPECT_FALSE(insideStaging(QStringLiteral("/home/u/.grassfield-expand-0a1b2c3d.old/Tool")));
    EXPECT_FALSE(insideStaging(QStringLiteral("/home/u/.grassfield-compress-deadbeef")));
    EXPECT_FALSE(insideStaging(QStringLiteral("/home/u/Downloads/Tool")));
    for (Facts f : {program(QStringLiteral("tool")), localFile(QStringLiteral("notes.txt"), QStringLiteral("text/plain")),
                    localFile(QStringLiteral("setup.exe"), QStringLiteral("application/x-msdownload"))}) {
        f.staging = true;
        EXPECT_EQ(verdict(f), Verdict::RefuseStaging) << f.fileName.toStdString();
    }
}

namespace
{
// A chain of `levels` folders of 200-character names under `root` (deeper than PATH_MAX past about 20 levels), made by
// descriptor only, with a program at the bottom; every folder of the chain but the last is then made 0500 (no write: the
// removal must open each up first). False when it could not be made.
bool deepChain(const QString &root, int levels)
{
    int fd = ::open(QFile::encodeName(root).constData(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0)
        return false;
    const QByteArray name(200, 'd');
    QList<int> chain;
    bool ok = true;
    for (int i = 0; i < levels && ok; ++i) {
        ok = ::mkdirat(fd, name.constData(), 0700) == 0;
        const int child = ok ? ::openat(fd, name.constData(), O_RDONLY | O_DIRECTORY | O_CLOEXEC) : -1;
        ok = ok && child >= 0;
        chain << fd;
        fd = child;
    }
    if (ok) {
        const int file = ::openat(fd, "prog", O_WRONLY | O_CREAT | O_CLOEXEC, 0755);
        ok = file >= 0 && ::write(file, "\x7f" "ELF", 4) == 4;
        if (file >= 0)
            ::close(file);
    }
    if (fd >= 0)
        ::close(fd);
    for (qsizetype i = 0; i < chain.size(); ++i) {
        if (i > 0 && ok)
            ok = ::fchmod(chain.at(i), 0500) == 0;
        ::close(chain.at(i));
    }
    return ok;
}
} // namespace

// m2: a refused tree is removed by descriptor, deeper than PATH_MAX too, its folders opened up first; a link inside is removed,
// never what it points to; a link given as the root is removed, never its target.
TEST_F(Files, RemoveTreeGoesDeeperThanPathMaxAndNeverThroughALink)
{
    ASSERT_TRUE(dir.isValid());
    const QString outside = write(QStringLiteral("outside.txt"), "keep", false);
    const QString root = dir.filePath(QStringLiteral(".grassfield-expand-0a1b2c3d"));
    ASSERT_TRUE(QDir().mkpath(root + QStringLiteral("/Kit/locked")));
    ASSERT_TRUE(QFile::link(outside, root + QStringLiteral("/Kit/link")));
    ASSERT_TRUE(QFile::link(dir.path(), root + QStringLiteral("/Kit/folder link")));
    ASSERT_TRUE(deepChain(root + QStringLiteral("/Kit"), 25));
    ASSERT_EQ(::chmod(QFile::encodeName(root + QStringLiteral("/Kit/locked")).constData(), 0100), 0);
    ASSERT_EQ(::chmod(QFile::encodeName(root + QStringLiteral("/Kit")).constData(), 0500), 0);
    ASSERT_EQ(::chmod(QFile::encodeName(root).constData(), 0500), 0);
    EXPECT_TRUE(removeTree(root));
    EXPECT_FALSE(QFileInfo::exists(root));
    EXPECT_FALSE(QFileInfo(root).isSymLink());
    EXPECT_TRUE(QFileInfo::exists(outside)) << "a link's target stays";
    EXPECT_TRUE(QFileInfo(dir.path()).isDir()) << "a link to a folder is removed, not followed";
    // A link as the root: the link goes, its target stays.
    const QString target = dir.filePath(QStringLiteral("target"));
    ASSERT_TRUE(QDir().mkpath(target + QStringLiteral("/inside")));
    const QString rootLink = dir.filePath(QStringLiteral("root link"));
    ASSERT_TRUE(QFile::link(target, rootLink));
    EXPECT_TRUE(removeTree(rootLink));
    EXPECT_FALSE(QFileInfo(rootLink).isSymLink());
    EXPECT_TRUE(QFileInfo(target + QStringLiteral("/inside")).isDir());
    EXPECT_TRUE(removeTree(dir.filePath(QStringLiteral("gone")))) << "nothing there: nothing left";
}

// m2 on real files: an item under a staging name, or a link to one, is refused by inspect() and verdict().
TEST_F(Files, AnItemUnderAStagingNameOrALinkToOneIsRefused)
{
    ASSERT_TRUE(dir.isValid());
    ASSERT_TRUE(QDir().mkpath(dir.filePath(QStringLiteral(".grassfield-expand-0a1b2c3d"))));
    const QString tool = nativeProgram(QStringLiteral(".grassfield-expand-0a1b2c3d/tool"), true);
    if (tool.isEmpty())
        GTEST_SKIP() << "no /usr/bin/true";
    const QString notes = write(QStringLiteral(".grassfield-expand-0a1b2c3d/notes.txt"), "text", false);
    const QString link = dir.filePath(QStringLiteral("tool link"));
    ASSERT_TRUE(QFile::link(tool, link));
    EXPECT_EQ(of(tool), Verdict::RefuseStaging);
    EXPECT_EQ(of(notes), Verdict::RefuseStaging) << "a document too: nothing there is marked yet";
    EXPECT_EQ(of(link), Verdict::RefuseStaging) << "the link's target decides";
    EXPECT_EQ(of(dir.filePath(QStringLiteral(".grassfield-expand-0a1b2c3d"))), Verdict::RefuseStaging) << "the folder itself";
}

// Third counter-review of fd5823de (m-b): a combining mark right before a document's letters (a nukta, a Myanmar dot below, a
// Hebrew hiriq, an Arabic kasra, a Thai sara u, a dot above) never hides them, and longer document extensions count too
// ("torrent", "sqlite", "numbers", "markdown").
TEST(LaunchGuardNames, AnyMarkOrALongDocumentExtensionIsADisguise)
{
    for (const QString &mark : {QStringLiteral("\u093c"), QStringLiteral("\u09bc"), QStringLiteral("\u1037"), QStringLiteral("\u05b4"),
                                QStringLiteral("\u0650"), QStringLiteral("\u0e38"), QStringLiteral("\u0307"), QStringLiteral("\u0358"),
                                QStringLiteral("\u0301"), QStringLiteral("\u20dd")}) {
        for (const QString &name : {QStringLiteral("Invoice") + mark + QStringLiteral("pdf"), QStringLiteral("Invoice") + mark + QStringLiteral("pdf "),
                                    QStringLiteral("photo") + mark + QStringLiteral("jpg"), QStringLiteral("setup") + mark + QStringLiteral("exe")}) {
            EXPECT_TRUE(documentTailAfterOtherThanDot(name)) << name.toStdString();
            EXPECT_EQ(verdict(program(name)), Verdict::RefuseDisguised) << name.toStdString();
        }
    }
    for (const QString &x : {QStringLiteral("\ua78f"), QStringLiteral("-"), QStringLiteral(" "), QStringLiteral("\u093c")}) {
        for (const QString &name : {QStringLiteral("Movie") + x + QStringLiteral("torrent"), QStringLiteral("Budget") + x + QStringLiteral("numbers"),
                                    QStringLiteral("Notes") + x + QStringLiteral("markdown"), QStringLiteral("db") + x + QStringLiteral("sqlite"),
                                    QStringLiteral("db") + x + QStringLiteral("sqlite3"), QStringLiteral("Talk") + x + QStringLiteral("Keynote"),
                                    QStringLiteral("App") + x + QStringLiteral("flatpakref")}) {
            EXPECT_TRUE(documentTailAfterOtherThanDot(name)) << name.toStdString();
            EXPECT_EQ(verdict(program(name)), Verdict::RefuseDisguised) << name.toStdString();
        }
    }
}

class LaunchGuardTestAccess
{
public:
    static void onFolderEmptied(std::function<void(int)> hook) { LaunchGuard::RemoveTreeHooks::s_folderEmptied = std::move(hook); }
};

// Third counter-review of fd5823de (m-a): a part of the tree moved elsewhere while removeTree walks it is never followed: the
// walk climbs back only into the folder it came down from, so the folder that now holds the moved part keeps its files.
TEST_F(Files, RemoveTreeNeverEmptiesAFolderItDidNotComeFrom)
{
    ASSERT_TRUE(dir.isValid());
    const QString root = dir.filePath(QStringLiteral(".grassfield-expand-0000cccc"));
    ASSERT_TRUE(QDir().mkpath(root + QStringLiteral("/a/b/c")));
    for (int i = 0; i < 3; ++i)
        write(QStringLiteral(".grassfield-expand-0000cccc/a/b/c/file%1").arg(i), "staged", false);
    write(QStringLiteral(".grassfield-expand-0000cccc/a/b/beside"), "staged", false);
    const QString victim = dir.filePath(QStringLiteral("victim"));
    ASSERT_TRUE(QDir().mkpath(victim + QStringLiteral("/keep")));
    write(QStringLiteral("victim/precious1"), "keep me", false);
    write(QStringLiteral("victim/keep/precious2"), "keep me too", false);
    // When "c" (depth 3) has been emptied, "a/b" (with "c" in it) is moved into the victim folder.
    bool moved = false;
    LaunchGuardTestAccess::onFolderEmptied([&](int depth) {
        if (depth == 3 && !moved)
            moved = QDir().rename(root + QStringLiteral("/a/b"), victim + QStringLiteral("/b"));
    });
    const bool removed = removeTree(root);
    LaunchGuardTestAccess::onFolderEmptied({});
    ASSERT_TRUE(moved);
    EXPECT_FALSE(removed) << "the walk stops where the moved part now is";
    EXPECT_TRUE(QFileInfo::exists(victim + QStringLiteral("/precious1")));
    EXPECT_TRUE(QFileInfo::exists(victim + QStringLiteral("/keep/precious2")));
    EXPECT_TRUE(QFileInfo(root + QStringLiteral("/a")).isDir()) << "what stays is left for a later removal";
    // Unmoved, the same tree goes entirely.
    EXPECT_TRUE(removeTree(root));
    EXPECT_FALSE(QFileInfo::exists(root));
}

// Fourth check of fd5823de (m-b'): after a letter of any script (U+A78F, a precomposed or decomposed dot below, an accented
// letter) only a lure extension of 2 letters or more makes a disguise, so French and Vietnamese names run ("Vidéo", "Météo",
// "Démo", "Mémo", "Lecteur-vidéo", "Tiếng-Việt", precomposed or decomposed); after anything else the rule stays whole
// ("nvim-qt", "qemu-img" are still refused).
TEST(LaunchGuardNames, AfterALetterOnlyALureExtensionIsADisguise)
{
    for (const QString &name : {QStringLiteral("Invoice\ua78fpdf"), QStringLiteral("Invoic\u1eb9pdf"), QStringLiteral("Invoice\u0323pdf"),
                                QStringLiteral("photo\ua78fjpg"), QStringLiteral("Movie\ua78ftorrent"), QStringLiteral("Repor\u1e0ddocx"),
                                QStringLiteral("Report\u00e9pdf"), QStringLiteral("Clip\u00e9mp4"), QStringLiteral("Backup\ua78fzip"),
                                QStringLiteral("Disk\u00e9iso"), QStringLiteral("Book\ua78fepub"), QStringLiteral("Sheet\ua78fxlsx"),
                                QStringLiteral("Image\ua78fpng"), QStringLiteral("App\ua78fdesktop"), QStringLiteral("App\u2981desktop"),
                                QStringLiteral("Tool\ua78fflatpak"), QStringLiteral("Tool\ua78fflatpakref"), QStringLiteral("Data\ua78fbackup"),
                                QStringLiteral("Invoice\ua78fpdf ")}) {
        EXPECT_TRUE(documentTailAfterOtherThanDot(name)) << name.toStdString();
        EXPECT_EQ(verdict(program(name)), Verdict::RefuseDisguised) << name.toStdString();
    }
    for (const QString &name : {QStringLiteral("Vid\u00e9o"), QStringLiteral("M\u00e9t\u00e9o"), QStringLiteral("D\u00e9mo"), QStringLiteral("M\u00e9mo"),
                                QStringLiteral("Lecteur-vid\u00e9o"), QStringLiteral("Ti\u1ebfng-Vi\u1ec7t"), QStringLiteral("Vide\u0301o"),
                                QStringLiteral("Me\u0301te\u0301o"), QStringLiteral("Lecteur-vide\u0301o"), QStringLiteral("Tie\u0302\u0301ng-Vie\u0323\u0302t"),
                                QStringLiteral("Pok\u00e9mon"), QStringLiteral("M\u00fasica"), QStringLiteral("signal-desktop"), QStringLiteral("timeshift-backup")}) {
        EXPECT_FALSE(documentTailAfterOtherThanDot(name)) << name.toStdString();
        EXPECT_EQ(verdict(program(name)), Verdict::RunProgram) << name.toStdString();
    }
    for (const QString &name : {QStringLiteral("nvim-qt"), QStringLiteral("qemu-img"), QStringLiteral("Tool-flatpak")})
        EXPECT_EQ(verdict(program(name)), Verdict::RefuseDisguised) << name.toStdString() << ": after a hyphen, the whole rule";
    // A lookalike Files already reads as a dot: "App" + U+2027 + "desktop" is the name of a launcher, refused as one.
    EXPECT_TRUE(documentTailAfterOtherThanDot(QStringLiteral("App\u2027desktop")));
    EXPECT_EQ(verdict(program(QStringLiteral("App\u2027desktop"))), Verdict::RefuseLauncher);
}

// Fifth check of fd5823de (V1): a name that can be drawn in another order is not trusted as drawn. RLM + "pdf." + RLM +
// "Invoice" is drawn "Invoice.pdf" (ALM the same, "Holiday.jpg" too): such a program always gets the sheet, approved and
// executable or not; an ordinary Arabic or Hebrew program name gets the sheet too, never a refusal.
TEST(LaunchGuardNames, ANameDrawnInAnotherOrderAlwaysAsks)
{
    for (const QString &name : {QStringLiteral("\u200fpdf.\u200fInvoice"), QStringLiteral("\u061cpdf.\u061cInvoice"),
                                QStringLiteral("\u200fjpg.\u200fHoliday"), QStringLiteral("\u061cjpg.\u061cHoliday"),
                                QStringLiteral("\u200eTool"), QStringLiteral("Tool\u202bx"), QStringLiteral("Tool\u2067x"),
                                QStringLiteral("\u0628\u0631\u0646\u0627\u0645\u062c"), QStringLiteral("\u05ea\u05d5\u05db\u05e0\u05d4"),
                                QStringLiteral("Tool-\u05d0")}) {
        EXPECT_TRUE(bidiName(name)) << name.toStdString();
        Facts f = program(name);
        EXPECT_EQ(verdict(f), Verdict::RunProgram) << name.toStdString() << ": the sheet, not a refusal";
        f.approved = true;
        const RunPlan p = plan(f);
        EXPECT_TRUE(p.nameUntrusted) << name.toStdString();
        EXPECT_TRUE(p.ask) << name.toStdString() << ": always, approved and executable";
        EXPECT_FALSE(p.downloaded);
    }
    for (const QString &name : {QStringLiteral("Tool"), QStringLiteral("\u00c9diteur"), QStringLiteral("Ti\u1ebfng-Vi\u1ec7t"), QStringLiteral("\u65e5\u672c")}) {
        EXPECT_FALSE(bidiName(name)) << name.toStdString();
        EXPECT_FALSE(plan(program(name)).ask) << name.toStdString();
    }
}

// Fifth check of fd5823de (v2): after a letter, 3 letters or more of any user type are a disguise again (pictures, sounds,
// films, fonts, archives, office files and ebooks, scripts, text documents), and the short ones the review found are lures.
// Developer types and two-letter collisions with ordinary words stay allowed.
TEST(LaunchGuardNames, AfterALetterAUserTypeIsADisguise)
{
    const QStringList tails = {QStringLiteral("Photo|jfif"), QStringLiteral("Report|xps"), QStringLiteral("Logo|eps"), QStringLiteral("Logo|ai"),
                               QStringLiteral("Photo|jxl"), QStringLiteral("Photo|dng"), QStringLiteral("Photo|cr2"), QStringLiteral("install|sh"),
                               QStringLiteral("script|py"), QStringLiteral("Passwords|kdbx"), QStringLiteral("Bank|ofx"), QStringLiteral("Dump|sql"),
                               QStringLiteral("Notes|log"), QStringLiteral("Config|yml"), QStringLiteral("Comic|cbz"), QStringLiteral("Movie|srt"),
                               QStringLiteral("Clip|flv"), QStringLiteral("Clip|3gp"), QStringLiteral("Song|aiff"), QStringLiteral("Song|mid"),
                               QStringLiteral("Font|ttf"), QStringLiteral("Book|fb2"), QStringLiteral("Diagram|vsdx"), QStringLiteral("Flyer|pub"),
                               QStringLiteral("Letter|wps"), QStringLiteral("Setup|cab"), QStringLiteral("Slides|potx"), QStringLiteral("Sheet|xlsb")};
    for (const QString &letter : {QStringLiteral("\ua78f"), QStringLiteral("\u1427"), QStringLiteral("\u02d1"), QStringLiteral("\u1e6d")}) {
        for (const QString &pair : tails) {
            const QString name = pair.section(QLatin1Char('|'), 0, 0) + letter + pair.section(QLatin1Char('|'), 1, 1);
            EXPECT_TRUE(documentTailAfterOtherThanDot(name)) << name.toStdString();
            EXPECT_EQ(verdict(program(name)), Verdict::RefuseDisguised) << name.toStdString();
        }
    }
    for (const QString &name : {QStringLiteral("D\u00e9mo"), QStringLiteral("M\u00e9mo"), QStringLiteral("Vid\u00e9o"), QStringLiteral("Ti\u1ebfng-Vi\u1ec7t"),
                                QStringLiteral("Cam\u00e9ra"), QStringLiteral("Op\u00e9ra"), QStringLiteral("Pr\u00e9au"), QStringLiteral("Di\u00e9go"),
                                QStringLiteral("Syst\u00e8me"), QStringLiteral("Donn\u00e9es"), QStringLiteral("R\u00e9el"), QStringLiteral("Pok\u00e9mon"),
                                QStringLiteral("M\u00fasica"), QStringLiteral("\u00c9diteur"), QStringLiteral("Cr\u00e9ateur"), QStringLiteral("Lecteur-vid\u00e9o")}) {
        EXPECT_FALSE(documentTailAfterOtherThanDot(name)) << name.toStdString();
        EXPECT_EQ(verdict(program(name)), Verdict::RunProgram) << name.toStdString();
    }
}

// Fifth check of fd5823de (nit): the Hangul fillers are drawn as a space, so "Invoice" + U+3164 + "pdf" reads "Invoice pdf",
// refused like a plain space before "pdf".
TEST(LaunchGuardNames, AHangulFillerIsDrawnAsASpace)
{
    for (const QString &name : {QStringLiteral("Invoice\u3164pdf"), QStringLiteral("Invoice\uffa0pdf"), QStringLiteral("Invoice\u115fpdf"),
                                QStringLiteral("Invoice\u1160pdf"), QStringLiteral("photo\u3164jpg"), QStringLiteral("Invoice pdf")}) {
        EXPECT_TRUE(documentTailAfterOtherThanDot(name)) << name.toStdString();
        EXPECT_EQ(verdict(program(name)), Verdict::RefuseDisguised) << name.toStdString();
    }
}

// Sixth check of fd5823de (nits): after a dot-like letter, the 2-letter media lures (ts, qt, rm) and certificates, VPN profiles,
// internet shortcuts, maps and mailboxes are disguises; the accented names stay allowed.
TEST(LaunchGuardNames, MediaCertificateMapAndMailLuresAfterALetter)
{
    for (const QString &pair : {QStringLiteral("Recording|ts"), QStringLiteral("Movie|qt"), QStringLiteral("Movie|rm"), QStringLiteral("Bank|crt"),
                                QStringLiteral("Server|pem"), QStringLiteral("Identity|p12"), QStringLiteral("Office|ovpn"), QStringLiteral("Bank|url"),
                                QStringLiteral("Route|kml"), QStringLiteral("Hike|gpx"), QStringLiteral("Archive|mbox")}) {
        for (const QString &letter : {QStringLiteral("\ua78f"), QStringLiteral("\u1427")}) {
            const QString name = pair.section(QLatin1Char('|'), 0, 0) + letter + pair.section(QLatin1Char('|'), 1, 1);
            EXPECT_TRUE(documentTailAfterOtherThanDot(name)) << name.toStdString();
            EXPECT_EQ(verdict(program(name)), Verdict::RefuseDisguised) << name.toStdString();
        }
    }
    for (const QString &name : {QStringLiteral("Cam\u00e9ra"), QStringLiteral("D\u00e9mo"), QStringLiteral("Di\u00e9go"), QStringLiteral("Syst\u00e8me"),
                                QStringLiteral("Vid\u00e9o"), QStringLiteral("M\u00e9mo")}) {
        EXPECT_FALSE(documentTailAfterOtherThanDot(name)) << name.toStdString();
        EXPECT_EQ(verdict(program(name)), Verdict::RunProgram) << name.toStdString();
    }
}
