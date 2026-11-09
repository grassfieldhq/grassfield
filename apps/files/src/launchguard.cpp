#include "launchguard.h"

#include <QFile>
#include <QFileInfo>
#include <QMimeDatabase>
#include <QMimeType>
#include <QRegularExpression>

#include <cerrno>
#include <cstring>
#include <dirent.h>
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
    return f.mimeType == QLatin1String("application/x-apple-diskimage");
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

// The (cleaned) name alone says nothing, or only a program's kind: every type its patterns give must be one.
bool nameShowsAsProgram(const QString &name)
{
    const QList<QMimeType> types = QMimeDatabase().mimeTypesForFileName(name);
    for (const QMimeType &t : types) {
        if (!showsAsProgram(t.name()))
            return false;
    }
    return true;
}

// Unicode's Default_Ignorable_Code_Point ranges (DerivedCoreProperties.txt, Unicode 15) that are not format characters (Cf).
bool defaultIgnorable(char32_t c)
{
    return c == 0x034F || c == 0x115F || c == 0x1160 || c == 0x17B4 || c == 0x17B5 || (c >= 0x180B && c <= 0x180F) || c == 0x3164
        || (c >= 0xFE00 && c <= 0xFE0F) || c == 0xFFA0 || (c >= 0xFFF0 && c <= 0xFFF8) || (c >= 0x1BCA0 && c <= 0x1BCA3)
        || (c >= 0x1D173 && c <= 0x1D17A) || (c >= 0xE0000 && c <= 0xE0FFF) || (c >= 0x2060 && c <= 0x206F) || (c >= 0x200B && c <= 0x200F)
        || (c >= 0x202A && c <= 0x202E) || c == 0x00AD || c == 0x061C || c == 0xFEFF;
}

// Characters drawn as nothing at all that are neither format characters nor default-ignorable: the braille blank and the
// Hangul fillers (U+3164 and U+FFA0 are also in defaultIgnorable()).
bool blankGlyph(char32_t c)
{
    return c == 0x2800 || c == 0x115F || c == 0x1160 || c == 0x3164 || c == 0xFFA0;
}

// Characters drawn as a full stop on the baseline or near it, the ones NFKC leaves alone (UTS #39 confusables of "." and the
// other scripts' full stops): read as "." before the extension is taken.
bool dotLookalike(char32_t c)
{
    static const char32_t kDots[] = {0x00B7, 0x0387, 0x0589, 0x0660, 0x06D4, 0x06F0, 0x0701, 0x0702, 0x1362, 0x2024, 0x2027, 0x2219, 0x22C5,
                                     0x2E31, 0x2E33, 0x3002, 0x30FB, 0xA4F8, 0xA60E, 0xFE12, 0xFE52, 0xFF0E, 0xFF61, 0xFF65, 0x10A50, 0x1D16D};
    for (const char32_t d : kDots) {
        if (c == d)
            return true;
    }
    return false;
}

// The extension the eye reads (after the cleaned name's last dot) is plain ASCII. A program's always is: an extension with
// any other character is a lookalike ("pdf" with a Cyrillic er U+0440, "exe" in Cyrillic ie and ha, "pdf" with a Greek rho).
bool asciiExtension(const QString &cleanedName)
{
    const qsizetype dot = cleanedName.lastIndexOf(QLatin1Char('.'));
    if (dot < 0)
        return true;
    for (qsizetype i = dot + 1; i < cleanedName.size(); ++i) {
        if (cleanedName.at(i).unicode() > 0x7F)
            return false;
    }
    return true;
}

// Characters a journal line never carries as they are: C0, DEL, C1, the quote and the bidirectional controls.
bool unloggable(char16_t c)
{
    return c < 0x20 || (c >= 0x7F && c <= 0x9F) || c == u'"' || c == 0x061C || c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E)
        || (c >= 0x2066 && c <= 0x2069);
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
    // Every name check is made on the cleaned name: "Invoice.pdf " or "Invoice.pdf<U+200B>" is a PDF's name to the eye.
    const QString name = cleanName(f.fileName);
    // Remote items (a share, sftp, a phone, the Trash): KIO never runs a remote executable, but it downloads a remote file and
    // runs the handler of its type, so what runs when opened is refused by name; desktop entries too (never handed to KIO).
    // Nothing is run from there: the user copies it to this computer first (Gatekeeper's rule for apps it can't check).
    if (!f.local) {
        if (desktopName(name) || desktopName(f.fileName))
            return Verdict::RefuseLauncher;
        if (foreignAppName(name))
            return Verdict::ForeignApp;
        if (windowsName(name) || javaName(name) || appImageName(name))
            return Verdict::RefuseRemoteProgram;
        return Verdict::Open;
    }
    // An Expand or Compress staging name: its files are not marked yet (security review of fd5823de, m2).
    if (f.staging)
        return Verdict::RefuseStaging;
    if (!f.regularFile)
        return Verdict::Open;
    // Desktop entries are never handed to KIO, a web link included: KIO downloads a link's target and runs the handler of
    // the type the server announces, or the application named in X-KDE-LastOpenedWith (review of a5646b8). A web link
    // (a .webloc on macOS) opens its address in the default web browser only (FilesApp::open); everything else is refused.
    if (f.desktopEntry || f.mimeType == QLatin1String("application/x-desktop") || f.mimeAncestors.contains(QLatin1String("application/x-desktop"))
        || desktopName(name) || desktopName(f.fileName))
        return webLink(f).isValid() ? Verdict::OpenWebLinkInBrowser : Verdict::RefuseLauncher;
    // A native program or AppImage, by its ELF header (not its name, not its permission bit). Its kind must say so: program
    // content shown as a document ("photo.jpg", "notes.txt", "run.sh", "setup.exe", and the same names with invisible
    // characters or trailing spaces) is never run.
    if (f.elf && f.elfProgram) {
        if (!showsAsProgram(f.mimeType) || !nameShowsAsProgram(name) || !asciiExtension(name) || documentTailAfterOtherThanDot(f.fileName))
            return Verdict::RefuseDisguised;
        // uwsm would start a desktop entry instead of the program (a launcher's way round the refusal above).
        if (uwsmReadsAsEntry(f.path) || uwsmReadsAsEntry(name))
            return Verdict::RefuseLauncher;
        if (!f.elfCompatible)
            return Verdict::RefuseIncompatible;
        // Files never starts anything with rights other than the user's own.
        if (f.elevated)
            return Verdict::RefuseElevated;
        return Verdict::RunProgram;
    }
    if (foreignApp(f) || foreignAppName(name))
        return Verdict::ForeignApp;
    if (javaType(f) || javaName(name))
        return Verdict::JavaProgram;
    if (windowsType(f) || windowsName(name))
        return Verdict::WindowsFile;
    // An executable script opens in the text editor, as on macOS (a .sh or .py opens in its editor; Open With > Terminal runs
    // it). Without the permission bit it is a document for KIO, which opens it in its type's application. An ELF file is never
    // a script (a shared library or an object with the bit is a document below).
    if (f.executable && !f.elf && (f.shebang || scriptType(f)))
        return Verdict::OpenScript;
    // Named or typed as an AppImage, but not an ELF program: nothing to run (an AppImage launcher would try).
    if (appImageType(f) || appImageName(name))
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
        if (host.isEmpty() || !valid.match(host).hasMatch())
            continue;
        // A label that mixes scripts (a homograph: a Cyrillic a, U+0430, among Latin letters) is shown as the browsers show it, in ASCII.
        for (const QString &label : host.split(QLatin1Char('.'))) {
            QChar::Script seen = QChar::Script_Unknown;
            for (const char32_t c : label.toUcs4()) {
                const QChar::Script s = QChar::script(c);
                if (s == QChar::Script_Common || s == QChar::Script_Inherited || s == QChar::Script_Unknown)
                    continue;
                if (seen != QChar::Script_Unknown && s != seen)
                    return QString::fromLatin1(QUrl::toAce(host));
                seen = s;
            }
        }
        return host;
    }
    return {};
}

QString cleanName(const QString &name)
{
    // Compatibility forms folded first (NFKC: fullwidth letters, and the dots U+2024, U+FE52, U+FF0E become "."), then
    // decomposed (NFKD) so that combining marks can be dropped: "pdf" with an acute or a dot below is "pdf" to the eye.
    const QString folded = name.normalized(QString::NormalizationForm_KC).normalized(QString::NormalizationForm_KD);
    QString out;
    out.reserve(folded.size());
    for (const char32_t c : folded.toUcs4()) {
        const QChar::Category category = QChar::category(c);
        if (category == QChar::Other_Format || category == QChar::Mark_NonSpacing || category == QChar::Mark_Enclosing || defaultIgnorable(c)
            || blankGlyph(c))
            continue;
        if (dotLookalike(c)) {
            out += QLatin1Char('.');
            continue;
        }
        out += QString::fromUcs4(&c, 1);
    }
    // Trailing spaces (any space separator) and dots are not seen in a list and do not change the kind to the eye.
    while (!out.isEmpty() && (out.back().isSpace() || out.back() == QLatin1Char('.')))
        out.chop(1);
    return out.normalized(QString::NormalizationForm_C);
}

bool uwsmReadsAsEntry(const QString &argument)
{
    // uwsm's MainArg (uwsm 0.27, /usr/share/uwsm/modules/uwsm/main.py): arg.endswith(".desktop") or ".desktop:" in arg.
    return argument.endsWith(QLatin1String(".desktop")) || argument.contains(QLatin1String(".desktop:"));
}

DownloadMarks downloadMarks(const QString &path)
{
    DownloadMarks marks;
    const int fd = ::open(QFile::encodeName(path).constData(), O_RDONLY | O_CLOEXEC | O_NOCTTY | O_NONBLOCK);
    if (fd < 0)
        return marks;
    marks.origin = attribute(fd, "user.xdg.origin.url");
    marks.referrer = attribute(fd, "user.xdg.referrer.url");
    ::close(fd);
    return marks;
}

namespace
{
constexpr int kMaxTreeDepth = 256;

bool setMarks(int fd, const DownloadMarks &marks)
{
    bool ok = true;
    if (!marks.origin.isEmpty())
        ok = ::fsetxattr(fd, "user.xdg.origin.url", marks.origin.constData(), size_t(marks.origin.size()), 0) == 0 && ok;
    if (!marks.referrer.isEmpty())
        ok = ::fsetxattr(fd, "user.xdg.referrer.url", marks.referrer.constData(), size_t(marks.referrer.size()), 0) == 0 && ok;
    return ok;
}

// A regular file pinned by an O_PATH descriptor (no link followed): the marks are written through a descriptor opened from its
// /proc/self/fd entry (the same inode, never a path looked up again). Writing a user attribute needs read and write access:
// when the user's bits lack one (an archive member of mode 0500, 0555 or 0100), the user's own file gets u+rw for the moment
// of the write, then its mode back. False when the marks are not both written (fail closed).
bool markPinnedFile(int pinned, const struct stat &st, const DownloadMarks &marks)
{
    const QByteArray self = "/proc/self/fd/" + QByteArray::number(pinned);
    const mode_t mode = st.st_mode & 07777;
    const bool opened = (mode & (S_IRUSR | S_IWUSR)) == (S_IRUSR | S_IWUSR);
    if (!opened && (st.st_uid != ::geteuid() || ::chmod(self.constData(), mode | S_IRUSR | S_IWUSR) != 0))
        return false;
    bool ok = false;
    const int fd = ::open(self.constData(), O_RDONLY | O_CLOEXEC | O_NOCTTY | O_NONBLOCK);
    if (fd >= 0) {
        ok = setMarks(fd, marks);
        ::close(fd);
    }
    if (!opened)
        ok = ::chmod(self.constData(), mode) == 0 && ok;
    return ok;
}

struct TreeWalk {
    const DownloadMarks &marks;
    qint64 cap;
    const std::function<bool(qint64)> &keepGoing;
    TreeMarks result;
};

// A folder pinned by an O_PATH descriptor: listed through a descriptor opened from its /proc/self/fd entry. A folder the user
// may not list or enter (mode 0100, 0300) gets u+rx while its entries are walked, then its mode back. Entries are reached with
// openat(O_PATH | O_NOFOLLOW): links are never followed and nothing is looked up by path twice.
bool walkPinnedFolder(int pinned, const struct stat &st, TreeWalk &w, int depth)
{
    if (depth > kMaxTreeDepth)
        return false;
    const QByteArray self = "/proc/self/fd/" + QByteArray::number(pinned);
    const mode_t mode = st.st_mode & 07777;
    const bool opened = (mode & (S_IRUSR | S_IXUSR)) == (S_IRUSR | S_IXUSR);
    if (!opened && (st.st_uid != ::geteuid() || ::chmod(self.constData(), mode | S_IRUSR | S_IXUSR) != 0))
        return false;
    bool ok = true;
    const int listing = ::open(self.constData(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    DIR *dir = listing >= 0 ? ::fdopendir(listing) : nullptr;
    if (!dir) {
        if (listing >= 0)
            ::close(listing);
        ok = false;
    }
    while (ok) {
        errno = 0;
        const dirent *entry = ::readdir(dir);
        if (!entry) {
            ok = errno == 0;
            break;
        }
        if (std::strcmp(entry->d_name, ".") == 0 || std::strcmp(entry->d_name, "..") == 0)
            continue;
        ++w.result.entries;
        if ((w.cap > 0 && w.result.entries > w.cap) || (w.keepGoing && !w.keepGoing(w.result.entries))) {
            ok = false;
            break;
        }
        const int child = ::openat(::dirfd(dir), entry->d_name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
        struct stat cs{};
        if (child < 0 || ::fstat(child, &cs) != 0) {
            ok = false;
        } else if (S_ISDIR(cs.st_mode)) {
            ok = walkPinnedFolder(child, cs, w, depth + 1);
        } else if (S_ISREG(cs.st_mode)) {
            ok = markPinnedFile(child, cs, w.marks);
            if (ok)
                ++w.result.files;
        }
        if (child >= 0)
            ::close(child);
    }
    if (dir)
        ::closedir(dir);
    if (!opened)
        ok = ::chmod(self.constData(), mode) == 0 && ok;
    return ok;
}
} // namespace

bool markFile(const QString &path, const DownloadMarks &marks)
{
    if (!marks.any())
        return false;
    const int pinned = ::open(QFile::encodeName(path).constData(), O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (pinned < 0)
        return false;
    struct stat st{};
    const bool ok = ::fstat(pinned, &st) == 0 && S_ISREG(st.st_mode) && markPinnedFile(pinned, st, marks);
    ::close(pinned);
    return ok;
}

TreeMarks markTree(const QString &root, const DownloadMarks &marks, qint64 cap, const std::function<bool(qint64)> &keepGoing)
{
    TreeWalk w{marks, cap, keepGoing, TreeMarks{}};
    if (!marks.any()) {
        w.result.complete = true;
        return w.result;
    }
    const int pinned = ::open(QFile::encodeName(root).constData(), O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (pinned < 0)
        return w.result;
    struct stat st{};
    if (::fstat(pinned, &st) == 0) {
        if (S_ISDIR(st.st_mode)) {
            w.result.complete = walkPinnedFolder(pinned, st, w, 0);
        } else if (S_ISREG(st.st_mode)) {
            w.result.complete = markPinnedFile(pinned, st, marks);
            w.result.files = w.result.complete ? 1 : 0;
        } else {
            w.result.complete = true; // a link or a special file: nothing to run, nothing to mark
        }
    }
    ::close(pinned);
    return w.result;
}

bool openTree(const QString &root)
{
    // Every folder under root (the root included) gets u+rwx, so that a staging tree with folders of mode 0100 or 0500 can be
    // removed; files are left as they are. No link is followed.
    std::function<bool(int, int)> walk = [&walk](int pinned, int depth) -> bool {
        if (depth > kMaxTreeDepth)
            return false;
        struct stat st{};
        if (::fstat(pinned, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != ::geteuid())
            return false;
        const QByteArray self = "/proc/self/fd/" + QByteArray::number(pinned);
        if ((st.st_mode & S_IRWXU) != S_IRWXU && ::chmod(self.constData(), (st.st_mode & 07777) | S_IRWXU) != 0)
            return false;
        const int listing = ::open(self.constData(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        DIR *dir = listing >= 0 ? ::fdopendir(listing) : nullptr;
        if (!dir) {
            if (listing >= 0)
                ::close(listing);
            return false;
        }
        bool ok = true;
        while (const dirent *entry = ::readdir(dir)) {
            if (std::strcmp(entry->d_name, ".") == 0 || std::strcmp(entry->d_name, "..") == 0)
                continue;
            const int child = ::openat(::dirfd(dir), entry->d_name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
            if (child < 0)
                continue;
            struct stat cs{};
            if (::fstat(child, &cs) == 0 && S_ISDIR(cs.st_mode))
                ok = walk(child, depth + 1) && ok;
            ::close(child);
        }
        ::closedir(dir);
        return ok;
    };
    const int pinned = ::open(QFile::encodeName(root).constData(), O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (pinned < 0)
        return false;
    const bool ok = walk(pinned, 0);
    ::close(pinned);
    return ok;
}

namespace
{
// A folder of the user's own pinned by `pinned` (O_PATH, no link followed): u+rwx given through its /proc/self/fd entry when
// it lacks them (the same inode, never a path looked up again), then opened for listing from that entry. -1 when it is not a
// folder of the user's own or can't be opened; `identity` gets its status.
int openOwnFolder(int pinned, struct stat *identity)
{
    struct stat st{};
    if (::fstat(pinned, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != ::geteuid())
        return -1;
    const QByteArray self = "/proc/self/fd/" + QByteArray::number(pinned);
    if ((st.st_mode & S_IRWXU) != S_IRWXU && ::chmod(self.constData(), (st.st_mode & 07777) | S_IRWXU) != 0)
        return -1;
    const int fd = ::open(self.constData(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd >= 0)
        *identity = st;
    return fd;
}
} // namespace

bool removeTree(const QString &root)
{
    // The root, pinned without following a link: a folder of the user's own, or a single file or link of theirs (its name goes,
    // never a link's target).
    const QByteArray native = QFile::encodeName(root);
    const int pinnedRoot = ::open(native.constData(), O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (pinnedRoot < 0)
        return errno == ENOENT;
    struct stat rootStat{};
    if (::fstat(pinnedRoot, &rootStat) != 0 || rootStat.st_uid != ::geteuid()) {
        ::close(pinnedRoot);
        return false;
    }
    if (!S_ISDIR(rootStat.st_mode)) {
        ::close(pinnedRoot);
        return ::unlink(native.constData()) == 0;
    }
    int current = openOwnFolder(pinnedRoot, &rootStat);
    ::close(pinnedRoot);
    if (current < 0)
        return false;
    // One folder descriptor at a time: down into the first subfolder found, back up through ".." once a folder is empty, and
    // only into the very folder it was entered from (device and inode recorded on the way down): a folder moved elsewhere
    // during the walk has another parent there, and the walk stops instead of emptying it (third counter-review of fd5823de,
    // m-a). The names and identities on the way down are the only state kept.
    struct Level {
        QByteArray name;
        dev_t device;
        ino_t inode;
    };
    QList<Level> levels;
    bool ok = true;
    while (current >= 0) {
        DIR *dir = ::fdopendir(::dup(current));
        if (!dir) {
            ok = false;
            break;
        }
        ::rewinddir(dir); // the duplicate shares its offset with `current`: always read the folder from its start
        QByteArray down;
        bool failed = false;
        while (const dirent *entry = ::readdir(dir)) {
            if (std::strcmp(entry->d_name, ".") == 0 || std::strcmp(entry->d_name, "..") == 0)
                continue;
            struct stat es{};
            if (::fstatat(current, entry->d_name, &es, AT_SYMLINK_NOFOLLOW) != 0) {
                failed = true;
                continue;
            }
            if (S_ISDIR(es.st_mode)) {
                down = entry->d_name;
                break;
            }
            if (::unlinkat(current, entry->d_name, 0) != 0)
                failed = true;
        }
        ::closedir(dir);
        if (failed) {
            ok = false;
            break;
        }
        if (!down.isEmpty()) {
            // Pinned without following a link; opened up and listed through that pin (openOwnFolder).
            const int pinned = ::openat(current, down.constData(), O_PATH | O_NOFOLLOW | O_CLOEXEC);
            struct stat cs{};
            const int child = pinned >= 0 ? openOwnFolder(pinned, &cs) : -1;
            if (pinned >= 0)
                ::close(pinned);
            if (child < 0) {
                ok = false;
                break;
            }
            ::close(current);
            current = child;
            levels.append({down, cs.st_dev, cs.st_ino});
            continue;
        }
        // Empty: back up and remove it by name, or, at the root, remove the root itself.
        if (RemoveTreeHooks::s_folderEmptied)
            RemoveTreeHooks::s_folderEmptied(int(levels.size()));
        if (levels.isEmpty()) {
            ::close(current);
            current = -1;
            ok = ::rmdir(native.constData()) == 0;
            break;
        }
        const int parent = ::openat(current, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        ::close(current);
        current = parent;
        const Level left = levels.takeLast();
        const dev_t device = levels.isEmpty() ? rootStat.st_dev : levels.last().device;
        const ino_t inode = levels.isEmpty() ? rootStat.st_ino : levels.last().inode;
        struct stat ps{};
        if (current < 0 || ::fstat(current, &ps) != 0 || ps.st_dev != device || ps.st_ino != inode) {
            ok = false; // moved meanwhile: nothing outside the tree as it was entered is touched
            break;
        }
        if (::unlinkat(current, left.name.constData(), AT_REMOVEDIR) != 0) {
            ok = false;
            break;
        }
    }
    if (current >= 0)
        ::close(current);
    return ok;
}

bool insideStaging(const QString &path)
{
    static const QRegularExpression staging(QStringLiteral(R"(\A\.grassfield-(?:expand-[0-9a-f]{8}|compress-[0-9a-f]{8}\.zip)\z)"));
    for (const QString &component : path.split(QLatin1Char('/'), Qt::SkipEmptyParts)) {
        if (staging.match(component).hasMatch())
            return true;
    }
    return false;
}

namespace
{
// Document and archive extensions of 6 letters or more (the MIME rule below covers 1 to 5): a program's name never ends in one
// of them after anything but a dot (third counter-review of fd5823de, m-b: "Movie" + a lookalike + "torrent" ran).
bool longDocumentExtension(const QString &tail)
{
    static const char *const kLong[] = {"torrent", "sqlite", "sqlite3", "numbers", "markdown", "keynote", "sketch", "drawio",
                                        "gnumeric", "kdenlive", "parquet", "webarchive", "flatpakref", "flatpakrepo"};
    for (const char *e : kLong) {
        if (tail.compare(QLatin1String(e), Qt::CaseInsensitive) == 0)
            return true;
    }
    return false;
}

// `name` ends (after its trailing spaces and dots) in ASCII letters or digits, one letter at least, right after a character
// that is not an ASCII dot, and they name a document or an archive: 1 to 5 of them that "x." plus them gives such a type (no
// type of a program's own), or a longer extension of longDocumentExtension().
bool documentTail(QString name)
{
    while (!name.isEmpty() && (name.back().isSpace() || name.back() == QLatin1Char('.')))
        name.chop(1);
    qsizetype start = name.size();
    bool letter = false;
    while (start > 0) {
        const QChar c = name.at(start - 1);
        if (c.unicode() > 0x7F || !c.isLetterOrNumber())
            break;
        letter = letter || c.isLetter();
        --start;
    }
    const qsizetype length = name.size() - start;
    if (length < 1 || !letter || start == 0 || name.at(start - 1) == QLatin1Char('.'))
        return false;
    const QString tail = name.mid(start);
    if (length > 5)
        return longDocumentExtension(tail);
    const QList<QMimeType> types = QMimeDatabase().mimeTypesForFileName(QStringLiteral("x.") + tail);
    if (types.isEmpty())
        return false;
    for (const QMimeType &t : types) {
        if (showsAsProgram(t.name()))
            return false;
    }
    return true;
}
} // namespace

bool documentTailAfterOtherThanDot(const QString &name)
{
    // Read the way Files judges names (cleanName: lookalike dots folded, accents dropped, fullwidth letters made plain)...
    if (documentTail(cleanName(name)))
        return true;
    // ... and the way it is drawn: invisible characters dropped, blank glyphs as spaces, nothing folded or decomposed, every
    // combining mark kept. A "TM" sign stays a sign, never the letters T and M joined to what follows, and any mark right before
    // the letters (a dot below, a nukta, a Thai sara u, a dot above, an accent) is a character other than a dot (third
    // counter-review of fd5823de, m-b: marks outside combining class 220 were dropped and ran).
    QString drawn;
    for (const char32_t c : name.toUcs4()) {
        if (QChar::category(c) == QChar::Other_Format || defaultIgnorable(c))
            continue;
        if (blankGlyph(c)) {
            drawn += QLatin1Char(' ');
            continue;
        }
        drawn += QString::fromUcs4(&c, 1);
    }
    return documentTail(drawn);
}

QByteArray remoteOrigin(const QUrl &source)
{
    static const QStringList local = {QStringLiteral("file"),        QStringLiteral("trash"),         QStringLiteral("desktop"),
                                      QStringLiteral("recentlyused"), QStringLiteral("tags"),          QStringLiteral("filenamesearch"),
                                      QStringLiteral("baloosearch"), QStringLiteral("timeline"),      QStringLiteral("grassfield-apps"),
                                      QStringLiteral("grassfield-app")};
    if (!source.isValid() || source.scheme().isEmpty() || local.contains(source.scheme().toLower()))
        return {};
    return source.adjusted(QUrl::RemoveUserInfo).toEncoded();
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
        if (unloggable(ch.unicode()))
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
    f.staging = insideStaging(itemPath);
    f.regularFile = item.isFile();
    f.executable = f.regularFile && item.isExecutable();
    if (!f.regularFile) {
        f.staging = f.staging || insideStaging(item.canonicalFilePath()); // a link to a staging folder too
        return f;
    }
    // A link's final target decides (its trust, its permission bits, its folder); the name stays the link's (what the user sees).
    f.path = item.canonicalFilePath();
    if (f.path.isEmpty())
        f.path = item.absoluteFilePath();
    f.staging = f.staging || insideStaging(f.path);
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
    f.ctimeNs = qint64(st.st_ctim.tv_sec) * 1000000000 + st.st_ctim.tv_nsec;
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
