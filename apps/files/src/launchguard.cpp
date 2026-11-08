#include "launchguard.h"

#include <QFile>
#include <QFileInfo>
#include <QMimeDatabase>
#include <QMimeType>
#include <QRegularExpression>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/xattr.h>
#include <unistd.h>

namespace LaunchGuard
{
namespace
{
constexpr qint64 kMaxDesktopBytes = 64 * 1024;
constexpr qint64 kMaxDynamicBytes = 64 * 1024;
constexpr int kMaxProgramHeaders = 256;
constexpr qint64 kMaxAttributeBytes = 4096;

// e_type, p_type and d_tag values of the ELF specification (elf.h).
constexpr int kEtExec = 2;
constexpr int kEtDyn = 3;
constexpr quint32 kPtDynamic = 2;
constexpr quint32 kPtInterp = 3;
constexpr quint64 kDtFlags1 = 0x6ffffffb;
constexpr quint64 kDf1Pie = 0x08000000;
constexpr int kEm386 = 3;
constexpr int kEmX86_64 = 62;

bool isOrInherits(const Facts &f, std::initializer_list<const char *> types)
{
    for (const char *t : types) {
        const QString name = QLatin1String(t);
        if (f.mimeType == name || f.mimeAncestors.contains(name))
            return true;
    }
    return false;
}

bool nameEndsWith(const QString &name, std::initializer_list<const char *> extensions)
{
    for (const char *e : extensions) {
        if (name.endsWith(QLatin1String(e), Qt::CaseInsensitive))
            return true;
    }
    return false;
}

// Windows programs and scripts (Wine, a script host) and registry files: their handler runs them whatever their permission
// bits, so opening one is running it. By type and by name (KIO's handler can follow either).
bool windowsType(const Facts &f)
{
    return isOrInherits(f, {"application/x-ms-dos-executable", "application/x-msdownload", "application/x-ms-ne-executable",
                            "application/vnd.microsoft.portable-executable", "application/x-dosexec", "application/x-lx-executable",
                            "application/x-msi", "application/x-ms-shortcut", "application/x-msdos-program", "application/x-bat",
                            "application/x-powershell", "text/vbscript", "text/vbscript.encode", "text/x-ms-regedit", "application/hta"});
}

bool windowsName(const QString &name)
{
    return nameEndsWith(name, {".exe", ".com", ".scr", ".cpl", ".msi", ".lnk", ".bat", ".cmd", ".ps1", ".vbs", ".vbe", ".wsf", ".hta", ".reg"});
}

bool javaType(const Facts &f)
{
    return isOrInherits(f, {"application/java-archive", "application/x-java-archive", "application/x-java-jnlp-file"});
}

bool javaName(const QString &name)
{
    return nameEndsWith(name, {".jar", ".jnlp"});
}

bool appImageType(const Facts &f)
{
    return isOrInherits(f, {"application/vnd.appimage", "application/x-iso9660-appimage"});
}

bool appImageName(const QString &name)
{
    return nameEndsWith(name, {".appimage"});
}

// Disk images and installer packages of another system's apps (Apple's .dmg and .pkg; the UI never names the system).
bool foreignAppName(const QString &name)
{
    return nameEndsWith(name, {".dmg", ".pkg", ".mpkg"});
}

bool foreignApp(const Facts &f)
{
    return f.mimeType == QLatin1String("application/x-apple-diskimage") || foreignAppName(f.fileName);
}

// Scripts: shared-mime-info makes them (shell, Python, Perl, Ruby, Lua, ...) sub-classes of application/x-executable.
bool scriptType(const Facts &f)
{
    return isOrInherits(f, {"application/x-executable", "application/x-pie-executable", "application/x-sharedlib", "application/x-shellscript",
                            "text/x-shellscript"});
}

// The kinds Files shows for a native program honestly (Executable, Shared library, AppImage, or no known kind). Any other kind
// (an image, a PDF, a shell script, a Windows program) on ELF program content is a disguise.
bool showsAsProgram(const QString &mimeType)
{
    static const char *const kTypes[] = {"application/x-executable", "application/x-pie-executable", "application/x-sharedlib",
                                         "application/vnd.appimage", "application/x-iso9660-appimage", "application/octet-stream"};
    for (const char *t : kTypes) {
        if (mimeType == QLatin1String(t))
            return true;
    }
    return mimeType.isEmpty();
}

bool desktopName(const QString &name)
{
    return name.endsWith(QLatin1String(".desktop"), Qt::CaseInsensitive) || name.endsWith(QLatin1String(".kdelnk"), Qt::CaseInsensitive)
        || name == QLatin1String(".directory");
}

quint64 readUnsigned(const QByteArray &bytes, qint64 offset, int size, bool bigEndian)
{
    if (offset < 0 || offset + size > bytes.size())
        return 0;
    quint64 value = 0;
    for (int i = 0; i < size; ++i) {
        const quint64 byte = quint8(bytes.at(offset + (bigEndian ? i : size - 1 - i)));
        value = (value << 8) | byte;
    }
    return value;
}

struct HostElf {
    int elfClass = 0;
    int byteOrder = 0;
    int machine = 0;
};

const HostElf &host()
{
    static const HostElf h = [] {
        HostElf out;
        QFile self(QStringLiteral("/proc/self/exe"));
        if (!self.open(QIODevice::ReadOnly))
            return out;
        const QByteArray head = self.read(20);
        if (head.size() < 20 || !head.startsWith("\x7f" "ELF"))
            return out;
        out.elfClass = quint8(head.at(4));
        out.byteOrder = quint8(head.at(5));
        out.machine = int(readUnsigned(head, 18, 2, out.byteOrder == 2));
        return out;
    }();
    return h;
}

// One extended attribute of the open file, "" when absent or longer than kMaxAttributeBytes.
QByteArray attribute(int fd, const char *name)
{
    QByteArray value(kMaxAttributeBytes, Qt::Uninitialized);
    const ssize_t n = ::fgetxattr(fd, name, value.data(), size_t(value.size()));
    if (n <= 0)
        return {};
    value.truncate(n);
    return value;
}

// A URL a browser wrote: printable, one line.
QString cleanUrl(const QByteArray &value)
{
    QString s = QString::fromUtf8(value).trimmed();
    for (const QChar ch : std::as_const(s)) {
        if (ch.unicode() < 0x20 || ch.unicode() == 0x7f)
            return {};
    }
    return s;
}
} // namespace

bool ElfHeader::program() const
{
    return valid && (type == kEtExec || (type == kEtDyn && (interpreter || pie)) || appImage);
}

ElfHeader parseElf(const std::function<QByteArray(qint64, qint64)> &readAt)
{
    ElfHeader h;
    const QByteArray head = readAt(0, 64);
    if (head.size() < 52 || !head.startsWith("\x7f" "ELF"))
        return h;
    h.elfClass = quint8(head.at(4));
    h.byteOrder = quint8(head.at(5));
    if ((h.elfClass != 1 && h.elfClass != 2) || (h.byteOrder != 1 && h.byteOrder != 2))
        return h;
    const bool big = h.byteOrder == 2;
    const bool wide = h.elfClass == 2;
    if (wide && head.size() < 64)
        return h;
    h.valid = true;
    h.appImage = head.at(8) == 'A' && head.at(9) == 'I' && (head.at(10) == 1 || head.at(10) == 2);
    h.type = int(readUnsigned(head, 16, 2, big));
    h.machine = int(readUnsigned(head, 18, 2, big));
    const quint64 phoff = wide ? readUnsigned(head, 32, 8, big) : readUnsigned(head, 28, 4, big);
    const int phentsize = int(readUnsigned(head, wide ? 54 : 42, 2, big));
    const int phnum = qMin(int(readUnsigned(head, wide ? 56 : 44, 2, big)), kMaxProgramHeaders);
    const int minimum = wide ? 56 : 32;
    if (phentsize < minimum || phoff == 0 || phoff > quint64(1) << 40)
        return h;
    qint64 dynamicOffset = -1;
    qint64 dynamicSize = 0;
    const QByteArray table = readAt(qint64(phoff), qint64(phentsize) * phnum);
    for (int i = 0; i < phnum; ++i) {
        const qint64 base = qint64(i) * phentsize;
        if (base + minimum > table.size())
            break;
        const quint32 ptype = quint32(readUnsigned(table, base, 4, big));
        const quint64 offset = wide ? readUnsigned(table, base + 8, 8, big) : readUnsigned(table, base + 4, 4, big);
        const quint64 filesz = wide ? readUnsigned(table, base + 32, 8, big) : readUnsigned(table, base + 16, 4, big);
        if (ptype == kPtInterp) {
            h.interpreter = true;
            if (filesz > 0 && filesz <= 4096 && offset < quint64(1) << 40) {
                QByteArray path = readAt(qint64(offset), qint64(filesz));
                const qsizetype nul = path.indexOf('\0');
                if (nul >= 0)
                    path.truncate(nul);
                h.interpreterPath = QString::fromLocal8Bit(path);
            }
        } else if (ptype == kPtDynamic && offset < quint64(1) << 40) {
            dynamicOffset = qint64(offset);
            dynamicSize = qint64(qMin<quint64>(filesz, kMaxDynamicBytes));
        }
    }
    // A position-independent executable without an interpreter (static-pie) says so in DT_FLAGS_1; a shared library does not.
    if (h.type == kEtDyn && !h.interpreter && dynamicOffset >= 0 && dynamicSize > 0) {
        const QByteArray dynamic = readAt(dynamicOffset, dynamicSize);
        const int entry = wide ? 16 : 8;
        for (qint64 at = 0; at + entry <= dynamic.size(); at += entry) {
            const quint64 tag = readUnsigned(dynamic, at, entry / 2, big);
            const quint64 value = readUnsigned(dynamic, at + entry / 2, entry / 2, big);
            if (tag == 0)
                break;
            if (tag == kDtFlags1 && (value & kDf1Pie))
                h.pie = true;
        }
    }
    return h;
}

bool runsHere(const ElfHeader &header)
{
    const HostElf &h = host();
    if (!header.valid || h.machine == 0)
        return false;
    if (header.elfClass == h.elfClass && header.byteOrder == h.byteOrder && header.machine == h.machine)
        return true;
    // IA-32 programs run on x86-64 (the kernel's compatibility mode; their libraries are another matter, said after a failure).
    return h.machine == kEmX86_64 && header.machine == kEm386 && header.elfClass == 1 && header.byteOrder == 1;
}

DesktopKeys parseDesktopEntry(const QByteArray &text)
{
    DesktopKeys keys;
    bool inEntry = false;
    int types = 0;
    int urls = 0;
    for (const QByteArray &raw : text.split('\n')) {
        const QByteArray line = raw.trimmed();
        if (line.isEmpty() || line.startsWith('#'))
            continue;
        if (line.startsWith('[')) {
            inEntry = line == "[Desktop Entry]" || line == "[KDE Desktop Entry]";
            continue;
        }
        if (!inEntry)
            continue;
        const int eq = line.indexOf('=');
        if (eq <= 0)
            continue;
        const QByteArray key = line.left(eq).trimmed();
        const QString value = QString::fromUtf8(line.mid(eq + 1).trimmed());
        // KConfig keeps the LAST value of a repeated key, and "URL[$e]" is KDE's shell-expanded URL: a key given twice
        // (in one group or across repeated groups), or URL with URL[$e], is ambiguous, and the caller refuses it.
        if (key == "Type") {
            ++types;
            keys.type = value;
        } else if (key == "URL" || key.startsWith("URL[")) {
            ++urls;
            keys.url = value;
        }
    }
    keys.ambiguous = types > 1 || urls > 1;
    return keys;
}

QUrl webLink(const Facts &f)
{
    if (f.desktopAmbiguous || f.desktopType != QLatin1String("Link"))
        return {};
    const QUrl target(f.desktopUrl, QUrl::StrictMode);
    const QString scheme = target.scheme().toLower();
    if (!target.isValid() || (scheme != QLatin1String("http") && scheme != QLatin1String("https")) || target.host().isEmpty())
        return {};
    return target;
}

Verdict verdict(const Facts &f)
{
    // Remote items (a share, sftp, a phone, the Trash): KIO never runs a remote executable, but it downloads a remote file and
    // runs the handler of its type, so what runs when opened is refused by name; desktop entries too (never handed to KIO).
    // Nothing is run from there: the user copies it to this computer first (Gatekeeper's rule for apps it can't check).
    if (!f.local) {
        if (desktopName(f.fileName))
            return Verdict::RefuseLauncher;
        if (foreignAppName(f.fileName))
            return Verdict::ForeignApp;
        if (windowsName(f.fileName) || javaName(f.fileName) || appImageName(f.fileName))
            return Verdict::RefuseRemoteProgram;
        return Verdict::Open;
    }
    if (!f.regularFile)
        return Verdict::Open;
    // Desktop entries are never handed to KIO, a web link included: KIO downloads a link's target and runs the handler of
    // the type the server announces, or the application named in X-KDE-LastOpenedWith (review of a5646b8). A web link
    // (a .webloc on macOS) opens its address in the default web browser only (FilesApp::open); everything else is refused.
    if (f.desktopEntry || f.mimeType == QLatin1String("application/x-desktop") || f.mimeAncestors.contains(QLatin1String("application/x-desktop"))
        || desktopName(f.fileName))
        return webLink(f).isValid() ? Verdict::OpenWebLinkInBrowser : Verdict::RefuseLauncher;
    // A native program or AppImage, by its ELF header (not its name, not its permission bit). Its kind must say so: program
    // content shown as a document ("photo.jpg", "notes.txt", "run.sh", "setup.exe") is never run.
    if (f.elf && f.elfProgram) {
        if (!showsAsProgram(f.mimeType))
            return Verdict::RefuseDisguised;
        if (!f.elfCompatible)
            return Verdict::RefuseIncompatible;
        // Files never starts anything with rights other than the user's own.
        if (f.elevated)
            return Verdict::RefuseElevated;
        return Verdict::RunProgram;
    }
    if (foreignApp(f))
        return Verdict::ForeignApp;
    if (javaType(f) || javaName(f.fileName))
        return Verdict::JavaProgram;
    if (windowsType(f) || windowsName(f.fileName))
        return Verdict::WindowsFile;
    // An executable script opens in the text editor, as on macOS (a .sh or .py opens in its editor; Open With > Terminal runs
    // it). Without the permission bit it is a document for KIO, which opens it in its type's application. An ELF file is never
    // a script (a shared library or an object with the bit is a document below).
    if (f.executable && !f.elf && (f.shebang || scriptType(f)))
        return Verdict::OpenScript;
    // Named or typed as an AppImage, but not an ELF program: nothing to run (an AppImage launcher would try).
    if (appImageType(f) || appImageName(f.fileName))
        return Verdict::RefuseNotAnApp;
    // Documents, also with the permission bit (every file of a FAT or NTFS volume has it), open in their app; so do ELF shared
    // libraries and objects (KIO's job never runs an executable: setRunExecutables(false)).
    return Verdict::Open;
}

RunPlan plan(const Facts &f)
{
    RunPlan p;
    p.downloaded = !f.originUrl.isEmpty() || !f.referrerUrl.isEmpty();
    const bool needsExec = !f.executable;
    // It cannot run from where it is: a noexec mount, or the execute bit is missing and can't be set here (a read-only disk, a
    // file of another user). Open then copies it to ~/Applications (macOS: an app is copied to /Applications from its disk image).
    p.copy = f.noexecMount || (needsExec && (f.readOnlyMount || !f.ownedByUser));
    p.allowRun = needsExec && !p.copy;
    p.ask = (p.downloaded && !f.approved) || needsExec || p.copy;
    return p;
}

QString originHost(const Facts &f)
{
    for (const QString &raw : {f.originUrl, f.referrerUrl}) {
        if (raw.isEmpty())
            continue;
        QUrl url(raw, QUrl::StrictMode);
        // blob: and similar addresses carry the page's address after the scheme.
        if (url.host().isEmpty() && !url.path().isEmpty())
            url = QUrl(url.path(), QUrl::StrictMode);
        const QString host = url.host(QUrl::FullyDecoded).toLower();
        static const QRegularExpression valid(QStringLiteral(R"(\A[\p{L}\p{N}.:\[\]-]{1,253}\z)"));
        if (!host.isEmpty() && valid.match(host).hasMatch())
            return host;
    }
    return {};
}

QByteArray approvalValue(quint64 inode, qint64 mtimeNs, qint64 size)
{
    return "1 " + QByteArray::number(inode) + ' ' + QByteArray::number(mtimeNs) + ' ' + QByteArray::number(size);
}

QString storeSearchTerm(const QString &fileName)
{
    QString base = fileName;
    const qsizetype dot = base.lastIndexOf(QLatin1Char('.'));
    if (dot > 0)
        base.truncate(dot);
    static const QRegularExpression separators(QStringLiteral(R"([\s_.+-]+)"));
    static const QStringList platform = {QStringLiteral("mac"),     QStringLiteral("macos"),     QStringLiteral("osx"),
                                         QStringLiteral("darwin"),  QStringLiteral("universal"), QStringLiteral("arm64"),
                                         QStringLiteral("aarch64"), QStringLiteral("x64"),       QStringLiteral("x86"),
                                         QStringLiteral("intel"),   QStringLiteral("apple"),     QStringLiteral("silicon"),
                                         QStringLiteral("setup"),   QStringLiteral("installer"), QStringLiteral("install"),
                                         QStringLiteral("dmg"),     QStringLiteral("pkg"),       QStringLiteral("latest")};
    QStringList words;
    for (const QString &word : base.split(separators, Qt::SkipEmptyParts)) {
        bool digit = false;
        for (const QChar ch : word)
            digit = digit || ch.isDigit();
        if (!digit && !platform.contains(word.toLower()))
            words << word;
    }
    QString term = words.join(QLatin1Char(' '));
    if (term.isEmpty())
        term = base;
    return term.left(80);
}

QString logName(const QString &name)
{
    QString out = name.left(120);
    for (QChar &ch : out) {
        if (ch.unicode() < 0x20 || ch.unicode() == 0x7f || ch == QLatin1Char('"'))
            ch = QLatin1Char('?');
    }
    return out;
}

Facts inspect(const QUrl &url)
{
    Facts f;
    f.local = url.isLocalFile();
    if (!f.local) {
        f.fileName = url.fileName();
        return f;
    }
    const QString itemPath = url.toLocalFile();
    const QFileInfo item(itemPath);
    f.fileName = item.fileName();
    f.symlink = item.isSymLink();
    f.regularFile = item.isFile();
    f.executable = f.regularFile && item.isExecutable();
    if (!f.regularFile)
        return f;
    // A link's final target decides (its trust, its permission bits, its folder); the name stays the link's (what the user sees).
    f.path = item.canonicalFilePath();
    if (f.path.isEmpty())
        f.path = item.absoluteFilePath();
    const QMimeType mime = QMimeDatabase().mimeTypeForFile(item);
    f.mimeType = mime.name();
    f.mimeAncestors = mime.allAncestors();
    f.desktopEntry = desktopName(f.fileName) || f.mimeType == QLatin1String("application/x-desktop")
        || f.mimeAncestors.contains(QLatin1String("application/x-desktop"));

    const QByteArray native = QFile::encodeName(f.path);
    const int fd = ::open(native.constData(), O_RDONLY | O_CLOEXEC | O_NOCTTY | O_NONBLOCK);
    if (fd < 0)
        return f; // unreadable: a desktop entry without a Type is refused; anything else falls back to its type
    struct stat st{};
    if (::fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        ::close(fd);
        return f;
    }
    f.inode = quint64(st.st_ino);
    f.mtimeNs = qint64(st.st_mtim.tv_sec) * 1000000000 + st.st_mtim.tv_nsec;
    f.size = qint64(st.st_size);
    f.ownedByUser = st.st_uid == ::geteuid();
    f.elevated = (st.st_mode & (S_ISUID | S_ISGID)) || ::geteuid() == 0 || ::fgetxattr(fd, "security.capability", nullptr, 0) > 0;
    struct statvfs vfs{};
    if (::fstatvfs(fd, &vfs) == 0) {
        f.noexecMount = vfs.f_flag & ST_NOEXEC;
        f.readOnlyMount = vfs.f_flag & ST_RDONLY;
    }
    auto readAt = [fd](qint64 offset, qint64 length) -> QByteArray {
        if (offset < 0 || length <= 0 || length > 1024 * 1024)
            return {};
        QByteArray bytes(length, Qt::Uninitialized);
        const ssize_t n = ::pread(fd, bytes.data(), size_t(length), off_t(offset));
        if (n <= 0)
            return {};
        bytes.truncate(n);
        return bytes;
    };
    const QByteArray head = readAt(0, f.desktopEntry ? kMaxDesktopBytes + 1 : 64);
    f.shebang = head.startsWith("#!");
    f.elf = head.startsWith("\x7f" "ELF");
    if (f.desktopEntry) {
        const DesktopKeys keys = parseDesktopEntry(head.left(kMaxDesktopBytes));
        f.desktopType = keys.type;
        f.desktopUrl = keys.url;
        // Longer than what was read: keys past the end are unknown (KConfig would read them), so it is ambiguous.
        f.desktopAmbiguous = keys.ambiguous || head.size() > kMaxDesktopBytes;
    }
    if (f.elf) {
        const ElfHeader elf = parseElf(readAt);
        f.elfProgram = elf.program();
        f.elfCompatible = runsHere(elf);
        f.elfInterpreter = elf.interpreterPath;
        f.appImage = elf.appImage;
    }
    // The browsers' download marks and Files' own approval, read on the target's descriptor (a link follows its target's trust).
    f.originUrl = cleanUrl(attribute(fd, "user.xdg.origin.url"));
    f.referrerUrl = cleanUrl(attribute(fd, "user.xdg.referrer.url"));
    const QByteArray approval = attribute(fd, "user.grassfield.approved");
    ::close(fd);
    f.approved = !approval.isEmpty() && approval == approvalValue(f.inode, f.mtimeNs, f.size);
    return f;
}

} // namespace LaunchGuard
