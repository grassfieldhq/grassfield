#include "applicationslogic.h"
#include <QStringDecoder>
#include <QSaveFile>

#include <QCollator>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QLocale>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QThread>

#include <algorithm>
#include <memory>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace ApplicationsLogic
{

namespace
{
constexpr qint64 kMaxEntryBytes = 256 * 1024;
constexpr int kMaxDepth = 32; // Quickshell has no limit; loops are cut by the visited set, this only bounds a hostile tree
constexpr int kMaxEntries = 20000;
// Folders walked in one directory tree: a link to /usr under an applications folder took 33 s (every folder is read, and
// each one is canonicalised). Quickshell has no such limit (a documented difference); 5000 covers any real share/applications.
constexpr int kMaxFolders = 5000;

bool hasDesktop(const QString &list, const QStringList &current)
{
    for (const QString &name : list.split(QLatin1Char(';'), Qt::SkipEmptyParts)) {
        if (current.contains(name))
            return true;
    }
    return false;
}

// hidden-entries.sh's terminalHelper(): the Categories value is searched as ";value" for ";TerminalEmulator;" (so a list that
// ends without ';' after it does not count), the Exec value is split on blanks.
bool terminalHelper(const QString &categories, const QString &exec)
{
    if (!(QLatin1Char(';') + categories).contains(QLatin1String(";TerminalEmulator;")))
        return false;
    const QStringList words = exec.split(QRegularExpression(QStringLiteral("[ \t]+")));
    if (words.isEmpty())
        return false;
    QString program = words.first();
    program = program.mid(program.lastIndexOf(QLatin1Char('/')) + 1);
    if (program.endsWith(QLatin1String("client")))
        return true;
    for (int i = 1; i < words.size(); ++i) {
        if (words.at(i) == QLatin1String("--server") || words.at(i) == QLatin1String("--daemon"))
            return true;
    }
    return false;
}

// What Quickshell's DesktopEntries reads. See applicationslogic.h: nothing is trimmed, the first [Desktop Entry] group only.
struct Fields {
    QString type, icon, exec, categories, noDisplay, hidden;
    QString name, genericName, comment;
    QHash<QString, QString> names, genericNames, comments; // by locale suffix
    QStringList nameOrder;                                  // the Name[...] suffixes in file order
};

Fields readFields(QByteArray text)
{
    Fields f;
    if (text.startsWith("\xEF\xBB\xBF"))
        text.remove(0, 3);
    bool inEntry = false, seen = false;
    for (const QByteArray &raw : text.split('\n')) {
        const QString line = QString::fromUtf8(raw);
        if (line.startsWith(QLatin1Char('['))) {
            inEntry = !seen && line == QLatin1String("[Desktop Entry]");
            seen = seen || inEntry;
            continue;
        }
        if (!inEntry || line.isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        const int eq = line.indexOf(QLatin1Char('='));
        if (eq <= 0)
            continue;
        const QString key = line.left(eq);
        const QString value = line.mid(eq + 1);
        auto localized = [&](const QString &base, QString &plain, QHash<QString, QString> &byLocale, QStringList *order) {
            if (key == base) {
                plain = value;
            } else if (key.startsWith(base + QLatin1Char('[')) && key.endsWith(QLatin1Char(']'))) {
                const QString suffix = key.mid(base.size() + 1, key.size() - base.size() - 2);
                if (order && !byLocale.contains(suffix))
                    order->append(suffix);
                byLocale.insert(suffix, value);
            }
        };
        if (key == QLatin1String("Type"))
            f.type = value;
        else if (key == QLatin1String("Icon"))
            f.icon = value;
        else if (key == QLatin1String("Exec"))
            f.exec = value;
        else if (key == QLatin1String("Categories"))
            f.categories = value;
        else if (key == QLatin1String("NoDisplay"))
            f.noDisplay = value;
        else if (key == QLatin1String("Hidden"))
            f.hidden = value;
        else {
            localized(QStringLiteral("Name"), f.name, f.names, &f.nameOrder);
            localized(QStringLiteral("GenericName"), f.genericName, f.genericNames, nullptr);
            localized(QStringLiteral("Comment"), f.comment, f.comments, nullptr);
        }
    }
    return f;
}

// What hidden-entries.sh reads, with its own rules: a trailing blank and CR cut, "Key = value" accepted (but no blank before the
// key), the last of a repeated key wins, every [Desktop Entry] group counts.
struct ScriptFields {
    QString onlyShowIn, notShowIn, categories, exec;
};

ScriptFields readScriptFields(const QByteArray &text)
{
    ScriptFields s;
    static const QRegularExpression only(QStringLiteral("^OnlyShowIn[ \t]*="));
    static const QRegularExpression notIn(QStringLiteral("^NotShowIn[ \t]*="));
    static const QRegularExpression cats(QStringLiteral("^Categories[ \t]*="));
    static const QRegularExpression exec(QStringLiteral("^Exec[ \t]*="));
    static const QRegularExpression afterEquals(QStringLiteral("^[^=]*=[ \t]*"));
    QString group;
    for (const QByteArray &raw : text.split('\n')) {
        QString line = QString::fromUtf8(raw);
        while (line.endsWith(QLatin1Char(' ')) || line.endsWith(QLatin1Char('\t')) || line.endsWith(QLatin1Char('\r')))
            line.chop(1);
        if (line.startsWith(QLatin1Char('['))) {
            group = line;
            continue;
        }
        if (group != QLatin1String("[Desktop Entry]"))
            continue;
        const QString value = QString(line).remove(afterEquals);
        if (only.match(line).hasMatch())
            s.onlyShowIn = value;
        else if (notIn.match(line).hasMatch())
            s.notShowIn = value;
        else if (cats.match(line).hasMatch())
            s.categories = value;
        else if (exec.match(line).hasMatch())
            s.exec = value;
    }
    return s;
}

QString pick(const QString &plain, const QHash<QString, QString> &byLocale, const QStringList &locales)
{
    for (const QString &l : locales) {
        const auto it = byLocale.constFind(l);
        if (it != byLocale.cend() && !it->isEmpty())
            return *it;
    }
    return plain;
}

// The Name the grid shows: Name[fr_FR], Name[fr], Name, else the first Name[...] of the file; empty when there is none.
QString nameOf(const Fields &f, const QStringList &locales)
{
    QString name = pick(f.name, f.names, locales);
    if (name.isEmpty()) {
        for (const QString &suffix : f.nameOrder) {
            if (!f.names.value(suffix).isEmpty())
                return f.names.value(suffix);
        }
    }
    return name;
}

// The text of a desktop file, or a null array: opened without blocking and only when it is a regular file, checked on the
// descriptor itself (a FIFO swapped in after the listing froze the GUI thread). Links are followed, as Quickshell does.
QByteArray readDesktopFile(const QString &path)
{
    const int fd = ::open(QFile::encodeName(path).constData(), O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
    if (fd < 0)
        return {};
    struct stat info;
    if (::fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) {
        ::close(fd);
        return {};
    }
    QByteArray data;
    data.resize(kMaxEntryBytes);
    qsizetype got = 0;
    while (got < data.size()) {
        const ssize_t n = ::read(fd, data.data() + got, size_t(data.size() - got));
        if (n <= 0)
            break;
        got += n;
    }
    ::close(fd);
    data.resize(got);
    return data.isNull() ? QByteArray("") : data;
}

// The ids and paths of every desktop file below `dir` (symlinked folders followed, loops cut), in Quickshell's order: each
// folder's entries sorted by name, case-insensitively, files and folders mixed.
void collect(const QDir &base, const QDir &dir, int depth, QSet<QString> &visited, QList<QPair<QString, QString>> &out, int &folders)
{
    if (depth > kMaxDepth || out.size() >= kMaxEntries || folders >= kMaxFolders)
        return;
    folders++;
    const QString canonical = QFileInfo(dir.absolutePath()).canonicalFilePath();
    if (canonical.isEmpty() || visited.contains(canonical))
        return;
    visited.insert(canonical);
    const QFileInfoList entries =
        dir.entryInfoList(QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot | QDir::Readable, QDir::Name | QDir::IgnoreCase);
    for (const QFileInfo &info : entries) {
        if (info.fileName().contains(QLatin1Char('\n')))
            continue;
        if (info.isDir()) {
            collect(base, QDir(info.absoluteFilePath()), depth + 1, visited, out, folders);
        } else if (info.fileName().endsWith(QLatin1String(".desktop")) && info.isFile()) {
            // isFile(): a regular file (or a link to one); a FIFO, a socket or a device named x.desktop is no entry.
            QString id = base.relativeFilePath(info.absoluteFilePath());
            id.chop(8);
            id.replace(QLatin1Char('/'), QLatin1Char('-'));
            out.append({id, info.absoluteFilePath()});
        }
    }
    visited.remove(canonical);
}

// Model.vendorOf: a reverse-DNS id names its vendor in its second label.
QString vendorOf(const QString &id)
{
    static const QRegularExpression re(QStringLiteral("^[a-z]+\\.([A-Za-z0-9_-]+)\\.[A-Za-z0-9_.-]+$"));
    const QRegularExpressionMatch m = re.match(id);
    if (!m.hasMatch())
        return {};
    static const QHash<QString, QString> known = {{QStringLiteral("gnome"), QStringLiteral("GNOME")}, {QStringLiteral("kde"), QStringLiteral("KDE")},
                                                  {QStringLiteral("xfce"), QStringLiteral("Xfce")}, {QStringLiteral("gimp"), QStringLiteral("GIMP")},
                                                  {QStringLiteral("mozilla"), QStringLiteral("Mozilla")},
                                                  {QStringLiteral("libreoffice"), QStringLiteral("LibreOffice")}};
    const QString v = m.captured(1);
    const auto it = known.constFind(v.toLower());
    return it != known.cend() ? *it : v.left(1).toUpper() + v.mid(1);
}
} // namespace

QStringList defaultHelperIds()
{
    return {QStringLiteral("avahi-discover"), QStringLiteral("bssh"), QStringLiteral("bvnc"), QStringLiteral("lstopo"),
            QStringLiteral("org.fcitx.Fcitx5"), QStringLiteral("org.fcitx.fcitx5-qt5-gui-wrapper"),
            QStringLiteral("org.fcitx.fcitx5-qt6-gui-wrapper"), QStringLiteral("fcitx5-migrator")};
}

QStringList localeCandidates(const QString &localeName)
{
    QString name = localeName;
    const int dot = name.indexOf(QLatin1Char('.'));
    if (dot >= 0)
        name = name.left(dot);
    const int at = name.indexOf(QLatin1Char('@'));
    if (at >= 0)
        name = name.left(at);
    QStringList out;
    if (name.isEmpty() || name == QLatin1String("C") || name == QLatin1String("POSIX"))
        return out;
    out << name;
    const int underscore = name.indexOf(QLatin1Char('_'));
    if (underscore > 0)
        out << name.left(underscore);
    return out;
}

Environment processEnvironment()
{
    Environment env;
    const QString home = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
    if (!home.isEmpty())
        env.applicationDirs << home + QStringLiteral("/applications");
    for (const QString &dir : QStandardPaths::standardLocations(QStandardPaths::GenericDataLocation)) {
        const QString apps = dir + QStringLiteral("/applications");
        if (!env.applicationDirs.contains(apps))
            env.applicationDirs << apps;
    }
    env.currentDesktop = qEnvironmentVariable("XDG_CURRENT_DESKTOP").split(QLatin1Char(':'), Qt::SkipEmptyParts);
    env.locales = localeCandidates(QLocale().name());
    const QStringList helpers = defaultHelperIds();
    env.helperIds = QSet<QString>(helpers.cbegin(), helpers.cend());
    return env;
}

bool parseEntry(const QByteArray &text, const QString &id, const QString &path, const Environment &env, Entry *out)
{
    const Fields f = readFields(text);
    if (f.type != QLatin1String("Application"))
        return false;
    // Asked for by a Choose Application panel: listed whatever the grid's display rules say (Environment::alsoListed).
    const bool asked = env.alsoListed.contains(id);
    if ((f.noDisplay == QLatin1String("true") && !asked) || f.hidden == QLatin1String("true"))
        return false;
    const QString name = nameOf(f, env.locales);
    if (name.isEmpty())
        return false;
    if (!asked) {
        const ScriptFields s = readScriptFields(text);
        if (!s.onlyShowIn.isEmpty() && !hasDesktop(s.onlyShowIn, env.currentDesktop))
            return false;
        if (!s.notShowIn.isEmpty() && hasDesktop(s.notShowIn, env.currentDesktop))
            return false;
        if (terminalHelper(s.categories, s.exec))
            return false;
    }
    Entry e;
    e.id = id;
    e.path = path;
    e.name = e.baseName = name;
    e.genericName = pick(f.genericName, f.genericNames, env.locales);
    e.comment = pick(f.comment, f.comments, env.locales);
    e.icon = f.icon;
    e.exec = f.exec;
    e.categories = f.categories.split(QLatin1Char(';'), Qt::SkipEmptyParts);
    *out = e;
    return true;
}

// String.prototype.trim of the grid: the white space of ECMAScript (U+FEFF is one; U+0085 is not) instead of QString::trimmed's.
static QString jsTrim(const QString &text)
{
    auto space = [](QChar c) { return c.unicode() == 0xFEFF || (c.isSpace() && c.unicode() != 0x85); };
    int from = 0;
    int to = int(text.size());
    while (from < to && space(text.at(from)))
        ++from;
    while (to > from && space(text.at(to - 1)))
        --to;
    return text.mid(from, to - from);
}

void disambiguate(QList<Entry> &entries)
{
    QHash<QString, QList<int>> groups;
    for (int i = 0; i < entries.size(); ++i) {
        entries[i].baseName = entries.at(i).name;
        groups[jsTrim(entries.at(i).name).toLower()].append(i);
    }
    for (auto it = groups.cbegin(); it != groups.cend(); ++it) {
        if (it.key().isEmpty() || it.value().size() < 2)
            continue;
        for (const int i : it.value()) {
            Entry &e = entries[i];
            if (e.id.startsWith(QLatin1String("org.grassfield.")))
                continue;
            const QString vendor = vendorOf(e.id);
            const QString generic = jsTrim(e.genericName);
            const QString qualifier = !vendor.isEmpty() ? vendor : (!generic.isEmpty() && generic.toLower() != it.key() ? generic : e.id);
            e.name = e.baseName + QStringLiteral(" (") + qualifier + QLatin1Char(')');
        }
        QHash<QString, int> counts;
        for (const int i : it.value())
            counts[entries.at(i).name]++;
        for (const int i : it.value()) {
            if (counts.value(entries.at(i).name) > 1)
                entries[i].name = entries.at(i).baseName + QStringLiteral(" (") + entries.at(i).id + QLatin1Char(')');
        }
    }
}

QList<Entry> listApplications(const Environment &env)
{
    QSet<QString> seen;
    QList<Entry> result;
    for (const QString &dirPath : env.applicationDirs) {
        const QDir dir(dirPath);
        if (!dir.exists())
            continue;
        QList<QPair<QString, QString>> files;
        QSet<QString> visited;
        int folders = 0;
        collect(dir, dir, 0, visited, files, folders);
        // A file that is not an application with a Name (a Link, a Directory, no Name) does not exist for Quickshell: it masks
        // nothing. A valid one does, also when it is then not listed (Hidden=true, NoDisplay=true, OnlyShowIn elsewhere), and
        // of two valid files of one id in this directory the later one in the sorted walk wins.
        struct Candidate {
            QString path;
            QByteArray text;
        };
        QHash<QString, Candidate> winner;
        QStringList order;
        for (const auto &file : std::as_const(files)) {
            if (seen.contains(file.first))
                continue;
            const QByteArray text = readDesktopFile(file.second);
            if (text.isNull())
                continue;
            const Fields fields = readFields(text);
            if (fields.type != QLatin1String("Application") || nameOf(fields, env.locales).isEmpty())
                continue;
            if (!winner.contains(file.first))
                order << file.first;
            winner.insert(file.first, {file.second, text});
        }
        for (const QString &id : std::as_const(order)) {
            // The highest-priority directory that has an id counts.
            seen.insert(id);
            if (env.helperIds.contains(id) && !env.alsoListed.contains(id))
                continue;
            Entry entry;
            if (parseEntry(winner.value(id).text, id, winner.value(id).path, env, &entry))
                result.append(entry);
        }
    }
    disambiguate(result);
    QCollator collator;
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    collator.setNumericMode(true);
    std::sort(result.begin(), result.end(), [&collator](const Entry &a, const Entry &b) {
        const int c = collator.compare(a.name, b.name);
        return c != 0 ? c < 0 : a.id < b.id;
    });
    return result;
}

QStringList execArguments(const QString &exec)
{
    QStringList raw;
    QString current;
    bool inArg = false;
    bool quoted = false;
    for (qsizetype i = 0; i < exec.size(); i++) {
        const QChar c = exec.at(i);
        if (quoted) {
            if (c == QLatin1Char('\\') && i + 1 < exec.size() && QStringLiteral("\"$`\\").contains(exec.at(i + 1))) {
                current += exec.at(++i);
            } else if (c == QLatin1Char('"')) {
                quoted = false;
            } else {
                current += c;
            }
        } else if (c == QLatin1Char('"')) {
            quoted = true;
            inArg = true;
        } else if (c == QLatin1Char(' ') || c == QLatin1Char('\t')) {
            if (inArg)
                raw << current;
            current.clear();
            inArg = false;
        } else {
            current += c;
            inArg = true;
        }
    }
    if (inArg)
        raw << current;
    static const QRegularExpression whole(QStringLiteral("^%[a-zA-Z]$"));
    static const QRegularExpression code(QStringLiteral("%(.)"));
    QStringList out;
    for (const QString &arg : std::as_const(raw)) {
        if (whole.match(arg).hasMatch())
            continue;
        QString a = arg;
        QString cleaned;
        qsizetype last = 0;
        QRegularExpressionMatchIterator it = code.globalMatch(a);
        while (it.hasNext()) {
            const QRegularExpressionMatch m = it.next();
            cleaned += a.mid(last, m.capturedStart() - last);
            if (m.captured(1) == QLatin1String("%"))
                cleaned += QLatin1Char('%');
            last = m.capturedEnd();
        }
        cleaned += a.mid(last);
        out << cleaned;
    }
    return out;
}

QStringList launchCommand(const QString &exec, bool runInTerminal)
{
    QStringList command = execArguments(exec);
    if (command.isEmpty())
        return {};
    if (runInTerminal)
        command.prepend(QStringLiteral("xdg-terminal-exec"));
    return command;
}

namespace
{
// Only touched on the GUI thread.
QList<QThread *> g_listings;
void forgetListing(QThread *thread)
{
    g_listings.removeAll(thread);
}
} // namespace

void startListing(const Environment &env, ListingDone done)
{
    auto result = std::make_shared<QList<Entry>>();
    QThread *thread = QThread::create([env, result] { *result = listApplications(env); });
    g_listings.append(thread);
    // finished() comes from the worker; the thread object lives here, so the handler runs on the GUI thread.
    QObject::connect(thread, &QThread::finished, thread, [thread, result, done] {
        if (!g_listings.contains(thread))
            return; // waited for at quit (the queued call was already posted): nobody wants the answer, the waiter deletes it
        forgetListing(thread);
        thread->deleteLater();
        if (done)
            done(*result);
    });
    thread->start();
}

bool waitForListings(int ms)
{
    QElapsedTimer clock;
    clock.start();
    const QList<QThread *> running = g_listings;
    bool all = true;
    for (QThread *thread : running) {
        const qint64 left = qMax<qint64>(0, ms - clock.elapsed());
        if (thread->wait(left)) {
            forgetListing(thread); // finished and waited for: no answer is wanted
            thread->deleteLater();
        } else {
            all = false;
        }
    }
    return all;
}

int runningListings()
{
    return int(g_listings.size());
}

QStringList iconRoots()
{
    QStringList candidates = {qEnvironmentVariable("HOME"), QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)};
    candidates << QStandardPaths::standardLocations(QStandardPaths::GenericDataLocation);
    candidates << QStringLiteral("/usr") << QStringLiteral("/opt") << QStringLiteral("/var/lib/flatpak") << QStringLiteral("/var/lib/snapd/desktop")
               << QStringLiteral("/var/lib/AccountsService/icons") << QStringLiteral("/tmp") << QStringLiteral("/var/tmp")
               << qEnvironmentVariable("XDG_RUNTIME_DIR") << QStringLiteral("/media") << QStringLiteral("/mnt") << QStringLiteral("/run/media")
               << QStringLiteral("/srv");
    QStringList roots;
    for (const QString &c : std::as_const(candidates)) {
        if (!c.startsWith(QLatin1Char('/')))
            continue;
        const QString real = QFileInfo(c).canonicalFilePath();
        if (!real.isEmpty() && real != QLatin1String("/") && !roots.contains(real))
            roots << real;
    }
    return roots;
}

// Opens an Icon= file by the shell's rules (see safeIconFile): the descriptor, or -1. *realPath gets the real path.
static int openIconFile(const QString &path, const QStringList &roots, qint64 cap, QString *realPath)
{
    auto under = [&roots](const QString &p) {
        for (const QString &r : roots) {
            if (p == r || p.startsWith(r + QLatin1Char('/')))
                return true;
        }
        return false;
    };
    static const QRegularExpression control(QStringLiteral("[\\x00-\\x1f\\x7f]"));
    if (!path.startsWith(QLatin1Char('/')) || path.size() > 4096 || path.contains(control))
        return -1;
    const QString real = QFileInfo(path).canonicalFilePath();
    if (real.isEmpty() || !under(real))
        return -1;
    const QByteArray native = QFile::encodeName(real);
    struct stat info;
    if (::lstat(native.constData(), &info) != 0 || !S_ISREG(info.st_mode))
        return -1;
    const int fd = ::open(native.constData(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    bool ok = ::fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0 && info.st_size <= cap;
    if (ok) {
        char link[4097];
        const QByteArray self = "/proc/self/fd/" + QByteArray::number(fd);
        const ssize_t n = ::readlink(self.constData(), link, sizeof(link) - 1);
        ok = n > 0 && under(QString::fromLocal8Bit(link, static_cast<int>(n)));
    }
    if (!ok) {
        ::close(fd);
        return -1;
    }
    if (realPath)
        *realPath = real;
    return fd;
}

QString safeIconFile(const QString &path, const QStringList &roots, qint64 cap)
{
    QString real;
    const int fd = openIconFile(path, roots, cap, &real);
    if (fd < 0)
        return {};
    ::close(fd);
    return real;
}

QByteArray readIconFile(const QString &path, const QStringList &roots, qint64 cap)
{
    const int fd = openIconFile(path, roots, cap, nullptr);
    if (fd < 0)
        return {};
    // The size was checked on this descriptor; read at most that much (the file may be growing).
    struct stat info;
    QByteArray data;
    if (::fstat(fd, &info) == 0 && info.st_size > 0 && info.st_size <= cap) {
        data.resize(qsizetype(info.st_size));
        qsizetype got = 0;
        while (got < data.size()) {
            const ssize_t n = ::read(fd, data.data() + got, size_t(data.size() - got));
            if (n <= 0)
                break;
            got += n;
        }
        data.resize(got);
    }
    ::close(fd);
    return data;
}

QUrl locationUrl()
{
    return QUrl(QStringLiteral("grassfield-apps:/"));
}

bool isLocationUrl(const QUrl &url)
{
    return url.scheme() == QLatin1String("grassfield-apps");
}

QUrl entryUrl(const QString &id)
{
    QUrl url;
    url.setScheme(QStringLiteral("grassfield-app"));
    url.setPath(QLatin1Char('/') + id);
    return url;
}

QString entryId(const QUrl &url)
{
    if (url.scheme() != QLatin1String("grassfield-app"))
        return {};
    return url.path().mid(1);
}

} // namespace ApplicationsLogic

namespace DefaultApps
{
namespace
{
const QString kGroup = QStringLiteral("[Default Applications]");

bool isGroupLine(const QString &line)
{
    const QString t = line.trimmed();
    return t.startsWith(QLatin1Char('[')) && t.endsWith(QLatin1Char(']'));
}

// The key of an entry line ("image/png=a.desktop;" -> "image/png"), "" for a comment, a blank or a group line.
QString keyOf(const QString &line)
{
    const QString t = line.trimmed();
    if (t.isEmpty() || t.startsWith(QLatin1Char('#')) || isGroupLine(t))
        return {};
    const int eq = t.indexOf(QLatin1Char('='));
    return eq > 0 ? t.left(eq).trimmed() : QString();
}

QString valueOf(const QString &line)
{
    const int eq = line.indexOf(QLatin1Char('='));
    return eq < 0 ? QString() : line.mid(eq + 1).trimmed();
}

// A MIME type as written in a list: "type/subtype", printable ASCII, no '=' or ';'.
bool validType(const QString &type)
{
    static const QRegularExpression re(QStringLiteral("^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$"));
    return re.match(type).hasMatch();
}

// A desktop id: a file name ending in .desktop, no path, no '=' or ';'.
bool validId(const QString &id)
{
    static const QRegularExpression re(QStringLiteral("^[A-Za-z0-9_.-]+\\.desktop$"));
    return re.match(id).hasMatch();
}
} // namespace

bool grassfieldDesktop(const QString &currentDesktop)
{
    for (const QString &name : currentDesktop.split(QLatin1Char(':'), Qt::SkipEmptyParts)) {
        if (name.trimmed().compare(QLatin1String("Grassfield"), Qt::CaseInsensitive) == 0)
            return true;
    }
    return false;
}

QHash<QString, QString> defaults(const QString &listText)
{
    QHash<QString, QString> out;
    bool in = false;
    for (const QString &line : listText.split(QLatin1Char('\n'))) {
        if (isGroupLine(line)) {
            in = line.trimmed() == kGroup;
            continue;
        }
        const QString key = in ? keyOf(line) : QString();
        if (key.isEmpty() || out.contains(key))
            continue;
        const QString first = valueOf(line).split(QLatin1Char(';'), Qt::SkipEmptyParts).value(0).trimmed();
        if (!first.isEmpty())
            out.insert(key, first);
    }
    return out;
}

QString withDefault(const QString &listText, const QString &type, const QString &desktopId)
{
    if (!validType(type) || !validId(desktopId))
        return listText;
    QStringList lines = listText.isEmpty() ? QStringList() : listText.split(QLatin1Char('\n'));
    if (!lines.isEmpty() && lines.last().isEmpty())
        lines.removeLast();
    const QString entry = type + QLatin1Char('=') + desktopId + QLatin1Char(';');
    int group = -1;
    int end = int(lines.size());
    for (int i = 0; i < lines.size(); ++i) {
        if (!isGroupLine(lines.at(i)))
            continue;
        if (group >= 0) {
            end = i;
            break;
        }
        if (lines.at(i).trimmed() == kGroup)
            group = i;
    }
    if (group < 0) {
        if (!lines.isEmpty() && !lines.last().trimmed().isEmpty())
            lines << QString();
        lines << kGroup << entry;
        return lines.join(QLatin1Char('\n')) + QLatin1Char('\n');
    }
    for (int i = group + 1; i < end; ++i) {
        if (keyOf(lines.at(i)) == type) {
            lines[i] = entry;
            // A repeated key of the same group goes: the first one counts.
            for (int k = end - 1; k > i; --k) {
                if (keyOf(lines.at(k)) == type)
                    lines.removeAt(k);
            }
            return lines.join(QLatin1Char('\n')) + QLatin1Char('\n');
        }
    }
    // After the group's last entry (blank lines before the next group stay there).
    int at = end;
    while (at > group + 1 && lines.at(at - 1).trimmed().isEmpty())
        --at;
    lines.insert(at, entry);
    return lines.join(QLatin1Char('\n')) + QLatin1Char('\n');
}

QString withSeeds(const QString &listText, const QList<QPair<QString, QString>> &seeds)
{
    const QHash<QString, QString> have = defaults(listText);
    QString text = listText;
    for (const auto &seed : seeds) {
        if (!have.contains(seed.first) && !defaults(text).contains(seed.first))
            text = withDefault(text, seed.first, seed.second);
    }
    return text;
}

QStringList desktopMimeTypes(const QString &desktopText)
{
    bool in = false;
    for (const QString &line : desktopText.split(QLatin1Char('\n'))) {
        if (isGroupLine(line)) {
            if (in)
                break;
            in = line.trimmed() == QLatin1String("[Desktop Entry]");
            continue;
        }
        if (in && keyOf(line) == QLatin1String("MimeType"))
            return valueOf(line).split(QLatin1Char(';'), Qt::SkipEmptyParts);
    }
    return {};
}

QStringList seededTypes(const QString &desktopId, const QStringList &mimeTypes)
{
    QStringList out;
    for (const QString &raw : mimeTypes) {
        const QString type = raw.trimmed();
        if (!validType(type))
            continue;
        const bool take = desktopId == QLatin1String("org.grassfield.Preview.desktop") ? type.startsWith(QLatin1String("image/")) || type == QLatin1String("application/pdf")
                          : desktopId == QLatin1String("org.grassfield.Files.desktop") ? type == QLatin1String("inode/directory")
                                                                                       : false;
        if (take && !out.contains(type))
            out << type;
    }
    return out;
}

QHash<QString, QString> mergedDefaults(const QStringList &listTexts)
{
    QHash<QString, QString> out;
    for (const QString &text : listTexts) {
        const QHash<QString, QString> one = defaults(text);
        for (auto it = one.cbegin(); it != one.cend(); ++it) {
            if (!out.contains(it.key()))
                out.insert(it.key(), it.value());
        }
    }
    return out;
}

QList<QPair<QString, QString>> seedsAllowed(const QList<QPair<QString, QString>> &seeds, const QHash<QString, QString> &userDefaults,
                                            const QHash<QString, QString> &stockDefaults)
{
    QList<QPair<QString, QString>> out;
    for (const auto &seed : seeds) {
        const auto mine = userDefaults.constFind(seed.first);
        if (mine == userDefaults.constEnd() || (stockDefaults.contains(seed.first) && stockDefaults.value(seed.first) == mine.value()))
            out.append(seed);
    }
    return out;
}

bool readListFile(const QString &path, bool refuseLink, QString *text)
{
    text->clear();
    const QFileInfo info(path);
    if (!info.exists() && !info.isSymLink())
        return true;
    if (!info.isFile() || (refuseLink && info.isSymLink()) || info.size() > 1024 * 1024)
        return false;
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return false;
    const QByteArray bytes = file.read(1024 * 1024 + 1);
    if (bytes.size() > 1024 * 1024)
        return false;
    QStringDecoder utf8(QStringDecoder::Utf8);
    const QString decoded = utf8(bytes);
    if (utf8.hasError())
        return false;
    *text = decoded;
    return true;
}

bool seedSessionDefaults(const QString &configDir, const QStringList &applicationDirs, const QString &omarchyDir)
{
    if (configDir.isEmpty() || !QDir::isAbsolutePath(configDir))
        return false;
    QList<QPair<QString, QString>> seeds;
    for (const QString id : {QStringLiteral("org.grassfield.Files.desktop"), QStringLiteral("org.grassfield.Preview.desktop")}) {
        for (const QString &dir : applicationDirs) {
            QFile file(dir + QLatin1Char('/') + id);
            // A regular file of a sane size only (never a FIFO or a device).
            const QFileInfo info(file);
            if (!info.isFile() || info.size() > 256 * 1024)
                continue;
            if (!file.open(QIODevice::ReadOnly))
                continue;
            for (const QString &type : seededTypes(id, desktopMimeTypes(QString::fromUtf8(file.readAll()))))
                seeds.append({type, id});
            break; // the first file of an id is the one the lookup uses
        }
    }
    // An explicit choice in the user's own lists keeps its application; Omarchy's stock default does not (seedsAllowed). A list
    // that cannot be read counts as one that names nothing (Omarchy's) or as a choice for every type (the user's: nothing is
    // seeded then).
    QStringList user;
    for (const char *name : {"hyprland-mimeapps.list", "mimeapps.list"}) {
        QString text;
        if (!readListFile(configDir + QLatin1Char('/') + QLatin1String(name), false, &text))
            return false;
        user << text;
    }
    QStringList stock;
    if (!omarchyDir.isEmpty()) {
        for (const char *rel : {"config/hyprland-mimeapps.list", "default/applications/mimeapps.list"}) {
            QString text;
            if (readListFile(omarchyDir + QLatin1Char('/') + QLatin1String(rel), false, &text))
                stock << text;
        }
    }
    seeds = seedsAllowed(seeds, mergedDefaults(user), mergedDefaults(stock));
    if (seeds.isEmpty())
        return false;
    const QString path = configDir + QLatin1Char('/') + QLatin1String(kListName);
    // The session's own file: a regular file of a sane size in UTF-8, never through a link (readListFile).
    QString text;
    if (!readListFile(path, true, &text))
        return false;
    const QString next = withSeeds(text, seeds);
    if (next == text)
        return false;
    if (!QDir().mkpath(configDir))
        return false;
    QSaveFile out(path);
    if (!out.open(QIODevice::WriteOnly))
        return false;
    out.write(next.toUtf8());
    return out.commit();
}
} // namespace DefaultApps
