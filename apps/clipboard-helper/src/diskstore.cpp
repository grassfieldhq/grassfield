#include "diskstore.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>

#include <cerrno>

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

using namespace ClipLogic;

namespace
{
constexpr int kIndexVersion = 1;
constexpr int kMaxIndexItems = 200;
const char kItemMagic[] = "GFCLIP1\n";
const QByteArray kPlainPart = "text/plain;charset=utf-8";

enum class Read { Missing, Bad, Later, Ok };

// An open that failed for a reason that says nothing about the store (no descriptor or memory left, an I/O error): the store
// broke no rule, so it is not deleted for it.
bool transientError(int error)
{
    return error == EMFILE || error == ENFILE || error == ENOMEM || error == EIO || error == EINTR;
}

// Reads <name> in the directory <dirfd>: a regular file of the user, mode 0600, at most `max` bytes, read whole.
Read readBounded(int dirfd, const char *name, qint64 max, QByteArray *out)
{
    const int fd = ::openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0)
        return errno == ENOENT ? Read::Missing : transientError(errno) ? Read::Later : Read::Bad;
    struct stat st {};
    if (::fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != ::getuid() || (st.st_mode & 07777) != 0600 || st.st_size > max) {
        ::close(fd);
        return Read::Bad;
    }
    QByteArray bytes(qsizetype(st.st_size), Qt::Uninitialized);
    qint64 got = 0;
    while (got < st.st_size) {
        const ssize_t n = ::read(fd, bytes.data() + got, size_t(st.st_size - got));
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            break;
        got += n;
    }
    char extra;
    const bool more = ::read(fd, &extra, 1) > 0;
    ::close(fd);
    if (got != st.st_size || more)
        return Read::Bad;
    *out = bytes;
    return Read::Ok;
}

bool ownFileName(const QString &name)
{
    static const QRegularExpression re(QStringLiteral("^(index\\.json|[0-9a-f]{16}\\.item)(\\..*)?$"));
    return re.match(name).hasMatch();
}

// Unlinks the store's own files (ownFileName) in <dirfd> that are not in `keep`; never what a link points to. Returns how many.
int removeOthers(int dirfd, const QSet<QByteArray> &keep)
{
    const int fd = ::dup(dirfd); // fdopendir takes the descriptor it is given
    if (fd < 0)
        return 0;
    DIR *d = ::fdopendir(fd);
    if (!d) {
        ::close(fd);
        return 0;
    }
    QList<QByteArray> names;
    while (const dirent *e = ::readdir(d)) {
        const QByteArray name(e->d_name);
        if (!keep.contains(name) && ownFileName(QFile::decodeName(name)))
            names << name;
    }
    ::closedir(d);
    int removed = 0;
    for (const QByteArray &name : std::as_const(names)) {
        struct stat st {};
        if (::fstatat(dirfd, name.constData(), &st, AT_SYMLINK_NOFOLLOW) == 0 && (S_ISREG(st.st_mode) || S_ISLNK(st.st_mode))
            && ::unlinkat(dirfd, name.constData(), 0) == 0)
            ++removed;
    }
    return removed;
}
} // namespace

DiskStore::DiskStore(const QString &dir)
    : m_dir(dir)
{
}

bool DiskStore::validId(const QByteArray &id)
{
    if (id.size() != 16)
        return false;
    for (const char c : id)
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            return false;
    return true;
}

QByteArray DiskStore::encodeItem(const Item &item)
{
    QList<Part> parts;
    if (item.kind == Kind::Text)
        parts << Part{kPlainPart, item.plain.toUtf8()};
    parts += item.parts;
    QByteArray out = kItemMagic;
    out += QByteArray::number(parts.size()) + '\n';
    for (const Part &p : parts)
        out += p.mime + '\n' + QByteArray::number(p.data.size()) + '\n' + p.data;
    return out;
}

bool DiskStore::decodeItem(const QByteArray &bytes, Kind kind, Item *item)
{
    if (!bytes.startsWith(kItemMagic))
        return false;
    qsizetype at = qsizetype(sizeof kItemMagic) - 1;
    auto line = [&bytes, &at](QByteArray *out, int max) {
        const qsizetype nl = bytes.indexOf('\n', at);
        if (nl < 0 || nl - at > max)
            return false;
        *out = bytes.mid(at, nl - at);
        at = nl + 1;
        return true;
    };
    QByteArray field;
    if (!line(&field, 4))
        return false;
    bool ok = false;
    const int count = field.toInt(&ok);
    if (!ok || count < 1 || count > 3)
        return false;
    QHash<QByteArray, QByteArray> parts;
    for (int i = 0; i < count; ++i) {
        QByteArray mime, length;
        if (!line(&mime, kMaxTypeLength) || !line(&length, 10))
            return false;
        const qint64 n = length.toLongLong(&ok);
        if (!ok || n < 0 || n > kImageCap || at + n > bytes.size() || parts.contains(mime))
            return false;
        parts.insert(mime, bytes.mid(at, qsizetype(n)));
        at += qsizetype(n);
    }
    if (at != bytes.size())
        return false;
    Item it;
    it.kind = kind;
    if (kind == Kind::Text) {
        const QByteArray plain = parts.take(kPlainPart);
        if (plain.isEmpty() || plain.size() > kPlainCap || !decodePlain(kPlainPart, plain, &it.plain) || it.plain.trimmed().isEmpty())
            return false;
        for (auto p = parts.cbegin(); p != parts.cend(); ++p) {
            const bool html = p.key() == "text/html";
            const bool rtf = p.key() == "text/rtf" || p.key() == "application/rtf";
            if ((!html && !rtf) || p.value().isEmpty() || p.value().size() > (html ? kHtmlCap : kRtfCap))
                return false;
            it.parts << Part{p.key(), p.value()};
        }
        std::sort(it.parts.begin(), it.parts.end(), [](const Part &a, const Part &b) { return a.mime < b.mime; });
        it.title = titleOf(it.plain);
        it.excerpt = excerptOf(it.plain);
        it.hash = hashOf(Kind::Text, it.plain.toUtf8());
    } else if (kind == Kind::Files) {
        const QByteArray list = parts.value("text/uri-list");
        if (parts.size() != 1 || list.size() > kFilesCap || !parseUriList(list, &it.files))
            return false;
        it.plain = it.files.join(QLatin1Char('\n'));
        it.parts = {{"text/uri-list", uriList(it.files)}};
        QStringList names;
        for (const QString &p : std::as_const(it.files))
            names << p.section(QLatin1Char('/'), -1);
        it.title = titleOf(names.first());
        it.excerpt = excerptOf(names.join(QLatin1Char('\n')));
        it.hash = hashOf(Kind::Files, it.plain.toUtf8());
    } else if (kind == Kind::Image) {
        if (parts.size() != 1)
            return false;
        const QByteArray mime = parts.cbegin().key();
        const QByteArray data = parts.cbegin().value();
        if (data.isEmpty() || data.size() > kImageCap)
            return false;
        if (mime == "image/png")
            it.imageFormat = "png";
        else if (mime == "image/jpeg")
            it.imageFormat = "jpeg";
        else if (mime == "image/webp")
            it.imageFormat = "webp";
        else
            return false;
        it.parts = {{mime, data}};
        it.hash = hashOf(Kind::Image, data);
    } else {
        return false;
    }
    *item = it;
    return true;
}

DiskStore::Loaded DiskStore::load()
{
    Loaded result;
    const QByteArray path = QFile::encodeName(m_dir);
    struct stat st {};
    if (::lstat(path.constData(), &st) != 0)
        return result; // no store
    if (!S_ISDIR(st.st_mode) || st.st_uid != ::getuid() || (st.st_mode & 07777) != 0700) {
        deleteAll();
        result.status = Status::Deleted;
        return result;
    }
    const int dirfd = ::open(path.constData(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dirfd < 0) {
        if (transientError(errno)) {
            // Not read this time: left as it is and never written in this run (as a newer index), read at the next start.
            m_readOnly = true;
            return result;
        }
        deleteAll();
        result.status = Status::Deleted;
        return result;
    }
    QByteArray indexBytes;
    const Read index = readBounded(dirfd, "index.json", kMaxIndexBytes, &indexBytes);
    if (index != Read::Ok) {
        ::close(dirfd);
        if (index == Read::Later) {
            m_readOnly = true; // as above
            return result;
        }
        deleteAll();
        result.status = index == Read::Missing ? Status::Empty : Status::Deleted;
        return result;
    }
    QJsonParseError error{};
    const QJsonDocument doc = QJsonDocument::fromJson(indexBytes, &error);
    const QJsonObject root = doc.object();
    const QJsonValue version = root.value(QStringLiteral("version"));
    if (error.error != QJsonParseError::NoError || !doc.isObject() || !version.isDouble() || version.toDouble() != double(version.toInt())) {
        ::close(dirfd);
        deleteAll();
        result.status = Status::Deleted;
        return result;
    }
    if (version.toInt() > kIndexVersion) {
        ::close(dirfd);
        m_readOnly = true;
        result.status = Status::Newer;
        return result;
    }
    const QJsonArray items = root.value(QStringLiteral("items")).toArray();
    if (version.toInt() != kIndexVersion || !root.value(QStringLiteral("items")).isArray() || items.size() > kMaxIndexItems) {
        ::close(dirfd);
        deleteAll();
        result.status = Status::Deleted;
        return result;
    }
    for (const QJsonValue &value : items) {
        const QJsonObject o = value.toObject();
        const QByteArray id = o.value(QStringLiteral("id")).toString().toLatin1();
        const Kind kind = kindFromName(o.value(QStringLiteral("kind")).toString().toLatin1());
        const QByteArray file = id + ".item";
        Item item;
        QByteArray bytes;
        const Read read = validId(id) && kind != Kind::None ? readBounded(dirfd, file.constData(), kMaxItemBytes, &bytes) : Read::Bad;
        if (read == Read::Later) {
            ::close(dirfd);
            m_readOnly = true; // as above: no item is dropped from the index for an open that may work at the next start
            return Loaded{};
        }
        const bool good = read == Read::Ok && decodeItem(bytes, kind, &item);
        if (!good) {
            if (validId(id))
                ::unlinkat(dirfd, file.constData(), 0);
            ++result.dropped;
            continue;
        }
        item.id = id;
        item.copiedAtMs = qint64(o.value(QStringLiteral("copiedAt")).toDouble());
        item.bootAtMs = qint64(o.value(QStringLiteral("bootAt")).toDouble());
        item.bootId = o.value(QStringLiteral("bootId")).toString().toLatin1().left(64);
        item.pinnedAtMs = qint64(o.value(QStringLiteral("pinnedAt")).toDouble());
        item.app = o.value(QStringLiteral("app")).toString().left(255);
        result.items << item;
    }
    // What the index does not name: the file of an item removed or expired that a crash left behind (the index is written
    // first), the temporary of an interrupted write. Nothing would ever show or delete it, so it does not stay on disk.
    QSet<QByteArray> keep{QByteArrayLiteral("index.json")};
    for (const Item &it : std::as_const(result.items))
        keep.insert(it.id + ".item");
    result.orphans = removeOthers(dirfd, keep);
    ::close(dirfd);
    result.status = Status::Loaded;
    if (result.dropped > 0)
        saveIndex(result.items);
    return result;
}

DiskStore::Clears DiskStore::readClears(const QString &stateDir)
{
    Clears clears;
    const int dirfd = ::open(QFile::encodeName(stateDir).constData(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dirfd < 0)
        return clears;
    struct stat st {};
    if (::fstat(dirfd, &st) != 0 || st.st_uid != ::getuid()) {
        ::close(dirfd);
        return clears;
    }
    QByteArray bytes;
    const Read read = readBounded(dirfd, "clears", 64, &bytes);
    const QList<QByteArray> f = read == Read::Ok && bytes.endsWith('\n') ? bytes.chopped(1).split(' ') : QList<QByteArray>();
    bool okHistory = false;
    bool okPinned = false;
    const qint64 history = f.size() == 3 ? f.at(1).toLongLong(&okHistory) : -1;
    const qint64 pinned = f.size() == 3 ? f.at(2).toLongLong(&okPinned) : -1;
    const bool valid = f.size() == 3 && f.first() == "GFCLEARS1" && okHistory && okPinned && history >= 0 && pinned >= 0;
    // A record that breaks a rule is deleted and read as missing: the clears asked are then carried out again.
    if (read == Read::Bad || (read == Read::Ok && !valid))
        ::unlinkat(dirfd, "clears", 0);
    ::close(dirfd);
    if (!valid)
        return clears;
    clears.history = history;
    clears.pinned = pinned;
    clears.known = true;
    return clears;
}

bool DiskStore::writeClears(const QString &stateDir, const Clears &clears)
{
    DiskStore dir(stateDir);
    if (!dir.ensureDir())
        return false;
    return dir.writeFile(QStringLiteral("clears"), "GFCLEARS1 " + QByteArray::number(clears.history) + ' '
                                                       + QByteArray::number(clears.pinned) + '\n');
}

bool DiskStore::ensureDir()
{
    const QByteArray path = QFile::encodeName(m_dir);
    const QByteArray parent = QFile::encodeName(m_dir.section(QLatin1Char('/'), 0, -2));
    ::mkdir(parent.constData(), 0700);
    ::mkdir(path.constData(), 0700);
    struct stat st {};
    if (::lstat(path.constData(), &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != ::getuid())
        return false;
    if ((st.st_mode & 07777) != 0700 && ::chmod(path.constData(), 0700) != 0)
        return false;
    return true;
}

bool DiskStore::writeFile(const QString &name, const QByteArray &bytes)
{
    const QString path = m_dir + QLatin1Char('/') + name;
    struct stat st {};
    // QSaveFile writes through a link; what is in the way and is not a regular file goes first.
    if (::lstat(QFile::encodeName(path).constData(), &st) == 0 && !S_ISREG(st.st_mode))
        ::unlink(QFile::encodeName(path).constData());
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return false;
    // QSaveFile creates its file 0666 minus the umask: set 0600 whatever the umask was.
    if (!file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner)) {
        file.cancelWriting();
        return false;
    }
    if (file.write(bytes) != bytes.size()) {
        file.cancelWriting();
        return false;
    }
    return file.commit();
}

bool DiskStore::saveIndex(const QList<Item> &items)
{
    if (m_readOnly)
        return false;
    if (items.isEmpty()) {
        deleteAll(); // no empty store is left behind
        return true;
    }
    if (!ensureDir())
        return false;
    QJsonArray list;
    for (const Item &it : items) {
        QJsonArray mimes;
        if (it.kind == Kind::Text)
            mimes.append(QString::fromLatin1(kPlainPart));
        for (const Part &p : it.parts)
            mimes.append(QString::fromLatin1(p.mime));
        list.append(QJsonObject{
            {QStringLiteral("id"), QString::fromLatin1(it.id)},
            {QStringLiteral("kind"), QString::fromLatin1(kindName(it.kind))},
            {QStringLiteral("mimes"), mimes},
            {QStringLiteral("size"), double(it.size())},
            {QStringLiteral("copiedAt"), double(it.copiedAtMs)},
            {QStringLiteral("bootId"), QString::fromLatin1(it.bootId)},
            {QStringLiteral("bootAt"), double(it.bootAtMs)},
            {QStringLiteral("pinnedAt"), double(it.pinnedAtMs)},
            {QStringLiteral("title"), it.title},
            {QStringLiteral("app"), it.app},
        });
    }
    const QJsonObject root{{QStringLiteral("version"), kIndexVersion}, {QStringLiteral("items"), list}};
    return writeFile(QStringLiteral("index.json"), QJsonDocument(root).toJson(QJsonDocument::Compact));
}

bool DiskStore::saveItemFile(const Item &item, bool rewrite)
{
    if (m_readOnly || !validId(item.id) || !ensureDir())
        return false;
    const QString name = QString::fromLatin1(item.id) + QStringLiteral(".item");
    struct stat st {};
    if (rewrite || ::lstat(QFile::encodeName(m_dir + QLatin1Char('/') + name).constData(), &st) != 0 || !S_ISREG(st.st_mode))
        return writeFile(name, encodeItem(item));
    return true;
}

bool DiskStore::removeItemFile(const QByteArray &id)
{
    if (m_readOnly || !validId(id))
        return false;
    ::unlink(QFile::encodeName(m_dir + QLatin1Char('/') + QString::fromLatin1(id) + QStringLiteral(".item")).constData());
    return true;
}

bool DiskStore::save(const Item &item, const QList<Item> &items)
{
    return saveItemFile(item) && saveIndex(items);
}

bool DiskStore::removeItem(const QByteArray &id, const QList<Item> &items)
{
    return removeItemFile(id) && saveIndex(items);
}

void DiskStore::deleteAll()
{
    if (m_readOnly)
        return;
    const QByteArray path = QFile::encodeName(m_dir);
    struct stat st {};
    if (::lstat(path.constData(), &st) != 0)
        return;
    if (S_ISLNK(st.st_mode)) {
        ::unlink(path.constData()); // the link, never what it points to
        return;
    }
    if (!S_ISDIR(st.st_mode))
        return;
    const int dirfd = ::open(path.constData(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dirfd < 0)
        return;
    DIR *d = ::fdopendir(dirfd);
    if (!d) {
        ::close(dirfd);
        return;
    }
    QList<QByteArray> names;
    while (const dirent *e = ::readdir(d)) {
        const QString name = QFile::decodeName(e->d_name);
        if (ownFileName(name))
            names << QByteArray(e->d_name);
    }
    for (const QByteArray &name : std::as_const(names)) {
        struct stat fst {};
        if (::fstatat(dirfd, name.constData(), &fst, AT_SYMLINK_NOFOLLOW) == 0 && (S_ISREG(fst.st_mode) || S_ISLNK(fst.st_mode)))
            ::unlinkat(dirfd, name.constData(), 0);
    }
    ::closedir(d);
    ::rmdir(path.constData());
}
