#include "folderviews.h"

#include "filelogic.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLockFile>
#include <QSaveFile>
#include <QSet>

#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace
{
const QStringList kModes = {QStringLiteral("icons"), QStringLiteral("list"), QStringLiteral("columns"), QStringLiteral("gallery")};

// A whole number in [0, count).
bool isIndex(const QJsonValue &value, int count)
{
    return value.isDouble() && value.toDouble() == double(value.toInt()) && value.toInt() >= 0 && value.toInt() < count;
}

FolderViews::Signature signatureFrom(const struct stat &st)
{
    FolderViews::Signature s;
    s.error = 0;
    s.device = quint64(st.st_dev);
    s.inode = quint64(st.st_ino);
    s.size = qint64(st.st_size);
    s.mtimeSec = qint64(st.st_mtim.tv_sec);
    s.mtimeNsec = qint64(st.st_mtim.tv_nsec);
    s.mode = quint32(st.st_mode);
    return s;
}

FolderViews::Signature signatureError(int error)
{
    FolderViews::Signature s;
    s.error = error;
    return s;
}

class FdCloser
{
public:
    explicit FdCloser(int fd)
        : m_fd(fd)
    {
    }
    ~FdCloser()
    {
        if (m_fd >= 0)
            ::close(m_fd);
    }
    FdCloser(const FdCloser &) = delete;
    FdCloser &operator=(const FdCloser &) = delete;

private:
    int m_fd;
};
} // namespace

FolderViews::FolderViews(const QString &file)
    : m_file(file)
{
}

QString FolderViews::keyFor(const QUrl &url)
{
    if (!url.isValid() || url.isEmpty())
        return QString();
    return url.adjusted(QUrl::StripTrailingSlash | QUrl::NormalizePathSegments).toString(QUrl::FullyEncoded);
}

FolderViews::Entry FolderViews::parse(const QJsonObject &object)
{
    Entry e;
    const QString mode = object.value(QStringLiteral("mode")).toString();
    if (kModes.contains(mode))
        e.mode = mode;
    const QJsonValue key = object.value(QStringLiteral("sortKey"));
    if (isIndex(key, FileLogic::kSortKeyCount))
        e.sortKey = key.toInt();
    const QJsonValue descending = object.value(QStringLiteral("descending"));
    if (descending.isBool())
        e.descending = descending.toBool() ? 1 : 0;
    const QJsonValue group = object.value(QStringLiteral("groupBy"));
    if (isIndex(group, FileLogic::kGroupByCount))
        e.groupBy = group.toInt();
    return e;
}

QJsonObject FolderViews::serialize(const QString &key, const Entry &entry)
{
    QJsonObject o;
    o.insert(QStringLiteral("url"), key);
    if (!entry.mode.isEmpty())
        o.insert(QStringLiteral("mode"), entry.mode);
    if (entry.sortKey >= 0)
        o.insert(QStringLiteral("sortKey"), entry.sortKey);
    if (entry.descending >= 0)
        o.insert(QStringLiteral("descending"), entry.descending == 1);
    if (entry.groupBy >= 0)
        o.insert(QStringLiteral("groupBy"), entry.groupBy);
    return o;
}

FolderViews::Entry FolderViews::merged(const Entry &base, const Entry &fields)
{
    Entry e = base;
    if (kModes.contains(fields.mode))
        e.mode = fields.mode;
    if (fields.sortKey >= 0 && fields.sortKey < FileLogic::kSortKeyCount)
        e.sortKey = fields.sortKey;
    if (fields.descending == 0 || fields.descending == 1)
        e.descending = fields.descending;
    if (fields.groupBy >= 0 && fields.groupBy < FileLogic::kGroupByCount)
        e.groupBy = fields.groupBy;
    return e;
}

FolderViews::Signature FolderViews::signatureOf(const QString &path)
{
    const QByteArray p = QFile::encodeName(path);
    struct stat st{};
    if (p.isEmpty() || ::stat(p.constData(), &st) != 0)
        return signatureError(p.isEmpty() ? ENOENT : errno);
    return signatureFrom(st);
}

FolderViews::ReadStatus FolderViews::readFile(const QString &path, QByteArray *bytes, Signature *signature)
{
    bytes->clear();
    *signature = signatureOf(path);
    if (signature->error == ENOENT || signature->error == ENOTDIR)
        return ReadStatus::Missing;
    if (signature->error != 0)
        return ReadStatus::Unreadable;
    // Never opened unless it is a regular file: open() on a FIFO blocks until a writer comes, a device may act on open.
    if (!S_ISREG(signature->mode))
        return ReadStatus::NotRegular;
    if (signature->size > kMaxFileSize)
        return ReadStatus::TooLarge;
    // O_NONBLOCK: the path may have been replaced by a FIFO since the stat; the open then returns at once (fstat refuses it).
    const int fd = ::open(QFile::encodeName(path).constData(), O_RDONLY | O_CLOEXEC | O_NOCTTY | O_NONBLOCK);
    if (fd < 0)
        return errno == ENOENT ? ReadStatus::Missing : ReadStatus::Unreadable;
    const FdCloser closer(fd);
    struct stat opened{};
    if (::fstat(fd, &opened) != 0)
        return ReadStatus::Unreadable;
    // What was opened is judged, not what the path led to a moment before.
    *signature = signatureFrom(opened);
    if (!S_ISREG(opened.st_mode))
        return ReadStatus::NotRegular;
    if (opened.st_size > kMaxFileSize)
        return ReadStatus::TooLarge;
    // One byte more than the size the file has (so at most kMaxFileSize + 1): a file that grew while it was read, or a
    // regular file whose size says nothing of its contents (/proc), returns more than its size.
    const qint64 limit = qint64(opened.st_size) + 1;
    QByteArray buffer(int(limit), Qt::Uninitialized);
    qint64 total = 0;
    while (total < limit) {
        const ssize_t n = ::read(fd, buffer.data() + total, size_t(limit - total));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return ReadStatus::Unreadable;
        }
        if (n == 0)
            break;
        total += n;
    }
    if (total > kMaxFileSize)
        return ReadStatus::TooLarge;
    // Complete: exactly the size the file had when it was opened, and it did not change while it was read (a writer
    // changing it in place; Files' own writers replace the file, which leaves the opened one whole).
    struct stat after{};
    if (::fstat(fd, &after) != 0)
        return ReadStatus::Unreadable;
    if (total != qint64(opened.st_size) || signatureFrom(after) != *signature)
        return ReadStatus::Incomplete;
    buffer.truncate(int(total));
    *bytes = buffer;
    return ReadStatus::Ok;
}

void FolderViews::refresh()
{
    if (!m_loaded || signatureOf(m_file) != m_signature)
        load();
}

void FolderViews::load()
{
    m_entries.clear();
    m_order.clear();
    m_readOnly = false;
    m_loaded = true;
    QByteArray bytes;
    m_status = readFile(m_file, &bytes, &m_signature);
    if (m_status == ReadStatus::Missing)
        return;
    if (m_status != ReadStatus::Ok) {
        m_readOnly = true;
        return;
    }
    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(bytes, &err);
    bytes.clear();
    const QJsonObject root = doc.object();
    const QJsonValue version = root.value(QStringLiteral("version"));
    const QJsonValue folders = root.value(QStringLiteral("folders"));
    // ADR-0020: a missing version reads as 1; a newer one makes the file read-only. Anything this version cannot read
    // back the same way is never overwritten.
    if (err.error != QJsonParseError::NoError || !doc.isObject() || (!version.isUndefined() && (!version.isDouble() || version.toInt() < 1))
        || (!folders.isUndefined() && !folders.isArray()) || version.toInt(1) > kVersion) {
        m_status = ReadStatus::Invalid;
        m_readOnly = true;
        return;
    }
    // From the most recent entry back, in linear time: a key listed twice keeps its last (most recent) place, and only
    // the kMaxEntries most recent folders are kept (the file may list many more).
    const QJsonArray list = folders.toArray();
    QSet<QString> seen;
    QStringList newestFirst;
    for (qsizetype i = list.size() - 1; i >= 0 && newestFirst.size() < kMaxEntries; i--) {
        const QJsonObject o = list.at(i).toObject();
        const QString key = o.value(QStringLiteral("url")).toString();
        if (key.isEmpty() || seen.contains(key) || parse(o).isEmpty())
            continue;
        seen.insert(key);
        newestFirst.append(key);
        m_entries.insert(key, o);
    }
    m_order.reserve(newestFirst.size());
    for (qsizetype i = newestFirst.size() - 1; i >= 0; i--)
        m_order.append(newestFirst.at(i));
}

FolderViews::Entry FolderViews::entry(const QString &key) const
{
    const Entry stored = parse(m_entries.value(key));
    const auto pending = m_pending.constFind(key);
    return pending == m_pending.constEnd() ? stored : merged(stored, *pending);
}

FolderViews::WriteResult FolderViews::set(const QString &key, const Entry &fields, QString *error)
{
    const Entry valid = merged(Entry(), fields);
    if (key.isEmpty() || valid.isEmpty())
        return hasPending() ? flush(error) : WriteResult::Written;
    keep(key, valid);
    return flush(error);
}

void FolderViews::keep(const QString &key, const Entry &fields)
{
    const Entry valid = merged(Entry(), fields);
    if (key.isEmpty() || valid.isEmpty())
        return;
    m_pending.insert(key, merged(m_pending.value(key), valid));
    m_pendingOrder.removeOne(key);
    m_pendingOrder.append(key);
    // The pending folders are bounded like the file: the oldest would be dropped from it anyway.
    while (m_pendingOrder.size() > kMaxEntries)
        m_pending.remove(m_pendingOrder.takeFirst());
}

FolderViews::WriteResult FolderViews::flush(QString *error, int waitMs)
{
    if (!hasPending())
        return WriteResult::Written;
    QDir().mkpath(QFileInfo(m_file).absolutePath());
    const QString lockPath = m_file + QStringLiteral(".lock");
    // QLockFile only ever makes a regular file there. Anything else (a directory, a FIFO, a socket, a link) is not a lock
    // another Files holds: QLockFile would report it as taken for good (Busy: a retry every 5 s for the session), or, to
    // check a FIFO for staleness, open it and wait for a writer on the UI thread. Refused, without touching it.
    struct stat lockStat {};
    if (::lstat(QFile::encodeName(lockPath).constData(), &lockStat) == 0 && !S_ISREG(lockStat.st_mode)) {
        if (error)
            *error = QCoreApplication::translate("FolderViews", "the view settings lock file is not a regular file");
        return WriteResult::Refused;
    }
    QLockFile lock(lockPath);
    // A lock left by a process that died is taken over by QLockFile (its process is gone); a live holder only writes for
    // a moment, so the pending changes wait for the next flush instead of blocking the UI thread.
    if (!lock.tryLock(waitMs)) {
        if (lock.error() == QLockFile::LockFailedError) {
            if (error)
                *error = QCoreApplication::translate("FolderViews", "another Files window is saving its view settings");
            return WriteResult::Busy;
        }
        if (error)
            *error = QCoreApplication::translate("FolderViews", "the view settings lock file can't be created");
        return WriteResult::Refused;
    }
    // Under the lock, the file on disk is the truth: another process's latest entries are merged, never dropped. It is
    // read again only when its signature changed since this store last read or wrote it (every writer replaces the file).
    refresh();
    if (m_readOnly) {
        if (error)
            *error = QCoreApplication::translate("FolderViews", "the view settings file can't be read, so it is left as it is");
        return WriteResult::Refused;
    }
    for (const QString &key : std::as_const(m_pendingOrder)) {
        QJsonObject stored = m_entries.value(key);
        const Entry next = merged(parse(stored), m_pending.value(key));
        const QJsonObject known = serialize(key, next);
        for (auto it = known.begin(); it != known.end(); ++it)
            stored.insert(it.key(), it.value());
        // The folder becomes the most recently set (already last: nothing moves).
        if (m_order.isEmpty() || m_order.constLast() != key) {
            if (m_entries.contains(key))
                m_order.removeOne(key);
            m_order.append(key);
        }
        m_entries.insert(key, stored);
    }
    if (m_order.size() > kMaxEntries)
        dropOldest(m_order.size() - kMaxEntries);
    if (!save(error)) {
        // The store no longer matches the file: the next access reads it again.
        m_loaded = false;
        return WriteResult::Refused;
    }
    m_pending.clear();
    m_pendingOrder.clear();
    return WriteResult::Written;
}

void FolderViews::dropOldest(qsizetype count)
{
    count = qMin(count, m_order.size());
    for (qsizetype i = 0; i < count; i++)
        m_entries.remove(m_order.at(i));
    m_order.remove(0, count);
}

QByteArray FolderViews::serialized() const
{
    QJsonArray folders;
    for (const QString &key : std::as_const(m_order))
        folders.append(m_entries.value(key));
    QJsonObject root;
    root.insert(QStringLiteral("version"), kVersion);
    root.insert(QStringLiteral("folders"), folders);
    return QJsonDocument(root).toJson(QJsonDocument::Compact);
}

bool FolderViews::save(QString *error)
{
    QByteArray bytes = serialized();
    // Over the size limit (long paths), the oldest folders go until the file fits; the folder just set always stays.
    while (bytes.size() > kMaxFileSize && m_order.size() > 1) {
        dropOldest(qMin(qMax(qsizetype(1), m_order.size() / 10), m_order.size() - 1));
        bytes = serialized();
    }
    if (bytes.size() > kMaxFileSize) {
        if (error)
            *error = QCoreApplication::translate("FolderViews", "the view settings file would be too large");
        return false;
    }
    QSaveFile f(m_file);
    if (!f.open(QIODevice::WriteOnly)) {
        if (error)
            *error = f.errorString();
        return false;
    }
    f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    f.write(bytes);
    if (!f.commit()) {
        if (error)
            *error = f.errorString();
        return false;
    }
    m_signature = signatureOf(m_file);
    m_status = ReadStatus::Ok;
    return true;
}
