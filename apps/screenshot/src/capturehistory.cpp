#include "capturehistory.h"

#include "atomicfile.h"
#include "layers.h"
#include "runmode.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QRegularExpression>

namespace screenshot {

namespace {

constexpr QFileDevice::Permissions kDirPerms = QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner;
constexpr QFileDevice::Permissions kFilePerms = QFileDevice::ReadOwner | QFileDevice::WriteOwner;
constexpr qint64 kMaxPictureBytes = 256LL * 1024 * 1024;

QString indexPath(const QString &root)
{
    return root + QStringLiteral("/index.json");
}

bool validDigest(const QString &s)
{
    static const QRegularExpression re(QStringLiteral("^[0-9a-f]{64}$"));
    return s.isEmpty() || re.match(s).hasMatch();
}

QJsonObject toJson(const HistoryEntry &e)
{
    return {{QStringLiteral("id"), e.id},       {QStringLiteral("kind"), e.kind},   {QStringLiteral("path"), e.path},
            {QStringLiteral("time"), e.time},   {QStringLiteral("w"), e.width},     {QStringLiteral("h"), e.height},
            {QStringLiteral("orig"), e.original}, {QStringLiteral("cur"), e.current}};
}

bool fromJson(const QJsonObject &o, HistoryEntry *e)
{
    const auto text = [&o](const char *key, QString *out) {
        const QJsonValue v = o.value(QLatin1String(key));
        if (!v.isString())
            return false;
        *out = v.toString();
        return true;
    };
    const auto whole = [&o](const char *key, qint64 *out) {
        const QJsonValue v = o.value(QLatin1String(key));
        const double d = v.toDouble(-1);
        if (!v.isDouble() || d < 0 || d > 9e15 || d != double(qint64(d)))
            return false;
        *out = qint64(d);
        return true;
    };
    HistoryEntry r;
    qint64 w = 0;
    qint64 h = 0;
    if (!text("id", &r.id) || !CaptureHistory::validId(r.id) || !text("kind", &r.kind) || !text("path", &r.path) || r.path.isEmpty()
        || !whole("time", &r.time) || !whole("w", &w) || !whole("h", &h) || w > 100000 || h > 100000 || !text("orig", &r.original)
        || !text("cur", &r.current) || !validDigest(r.original) || !validDigest(r.current) || r.original.isEmpty())
        return false;
    r.width = int(w);
    r.height = int(h);
    *e = r;
    return true;
}

QString newId()
{
    QString id;
    for (int i = 0; i < 2; ++i)
        id += QStringLiteral("%1").arg(QRandomGenerator::system()->generate(), 8, 16, QLatin1Char('0'));
    return id;
}

} // namespace

CaptureHistory::CaptureHistory(const QString &root)
    : m_root(root)
{
}

QString CaptureHistory::defaultRoot()
{
    return grassfield::apps::runmode::stateDir() + QStringLiteral("/capture-history");
}

QString CaptureHistory::sha256(const QByteArray &bytes)
{
    return QString::fromLatin1(QCryptographicHash::hash(bytes, QCryptographicHash::Sha256).toHex());
}

bool CaptureHistory::validId(const QString &id)
{
    static const QRegularExpression re(QStringLiteral("^[0-9a-f]{16}$"));
    return re.match(id).hasMatch();
}

QString CaptureHistory::originalPath(const QString &id) const
{
    return validId(id) ? m_root + QLatin1Char('/') + id + QStringLiteral("/original.png") : QString();
}

QString CaptureHistory::layersPath(const QString &id) const
{
    return validId(id) ? m_root + QLatin1Char('/') + id + QStringLiteral("/layers.json") : QString();
}

bool CaptureHistory::ensureRoot(QString *error) const
{
    if (!QDir().mkpath(m_root) || !QFile::setPermissions(m_root, kDirPerms)) {
        if (error)
            *error = QStringLiteral("cannot make the history folder");
        return false;
    }
    return true;
}

QList<HistoryEntry> CaptureHistory::entries() const
{
    QByteArray bytes;
    if (!readPrivateFile(indexPath(m_root), kMaxIndexBytes, &bytes))
        return {};
    const QJsonDocument doc = QJsonDocument::fromJson(bytes);
    if (!doc.isObject() || doc.object().value(QStringLiteral("v")).toDouble() != 1 || !doc.object().value(QStringLiteral("entries")).isArray())
        return {};
    QList<HistoryEntry> out;
    for (const QJsonValue &v : doc.object().value(QStringLiteral("entries")).toArray()) {
        HistoryEntry e;
        if (v.isObject() && fromJson(v.toObject(), &e) && out.size() < kMaxHistoryEntries)
            out.append(e);
    }
    return out;
}

std::optional<HistoryEntry> CaptureHistory::find(const QString &path, const QString &digest) const
{
    for (const HistoryEntry &e : entries()) {
        if (e.path == path && (e.original == digest || (!e.current.isEmpty() && e.current == digest)))
            return e;
    }
    return std::nullopt;
}

bool CaptureHistory::writeIndex(const QList<HistoryEntry> &entries, QString *error) const
{
    QJsonArray array;
    for (const HistoryEntry &e : entries)
        array.append(toJson(e));
    const QJsonObject root{{QStringLiteral("v"), 1}, {QStringLiteral("entries"), array}};
    return atomicWrite(indexPath(m_root), QJsonDocument(root).toJson(QJsonDocument::Compact), 0600, error);
}

bool CaptureHistory::add(const QString &path, const QByteArray &originalBytes, const QSize &pixels, HistoryEntry *entry, QString *error)
{
    if (!ensureRoot(error))
        return false;
    HistoryEntry e;
    e.id = newId();
    e.kind = QStringLiteral("shot");
    e.path = path;
    e.time = QDateTime::currentSecsSinceEpoch();
    e.width = pixels.width();
    e.height = pixels.height();
    e.original = sha256(originalBytes);

    const QString dir = m_root + QLatin1Char('/') + e.id;
    if (!QDir().mkdir(dir) || !QFile::setPermissions(dir, kDirPerms)) {
        if (error)
            *error = QStringLiteral("cannot make the entry's folder");
        QDir(dir).removeRecursively();
        return false;
    }
    if (!atomicWrite(originalPath(e.id), originalBytes, 0600, error) || !atomicWrite(layersPath(e.id), layersToJson({}), 0600, error)) {
        QDir(dir).removeRecursively();
        return false;
    }
    // Older entries of the same path name a file that is gone: they go, folders included, once this one is in the index.
    QList<HistoryEntry> all = entries();
    QList<HistoryEntry> stale;
    QList<HistoryEntry> kept;
    for (const HistoryEntry &old : all)
        (old.path == path ? stale : kept).append(old);
    kept.append(e);
    if (!writeIndex(kept, error)) {
        QDir(dir).removeRecursively();
        return false;
    }
    for (const HistoryEntry &old : std::as_const(stale))
        if (validId(old.id))
            QDir(m_root + QLatin1Char('/') + old.id).removeRecursively();
    if (entry)
        *entry = e;
    return true;
}

bool CaptureHistory::writeLayers(const QString &id, const QByteArray &layers, QString *error)
{
    if (!validId(id)) {
        if (error)
            *error = QStringLiteral("not an entry id");
        return false;
    }
    if (layers.size() > kMaxLayersBytes) {
        // The reader refuses more than this: a file written past it could never be opened again.
        if (error)
            *error = QStringLiteral("layers file too large");
        return false;
    }
    return atomicWrite(layersPath(id), layers, 0600, error);
}

bool CaptureHistory::setCurrent(const QString &id, const QString &digest, QString *error)
{
    QList<HistoryEntry> all = entries();
    for (HistoryEntry &e : all) {
        if (e.id == id) {
            e.current = digest;
            return validDigest(digest) && writeIndex(all, error);
        }
    }
    if (error)
        *error = QStringLiteral("no such history entry");
    return false;
}

QByteArray CaptureHistory::readOriginal(const QString &id) const
{
    QByteArray out;
    if (!validId(id) || !readPrivateFile(originalPath(id), kMaxPictureBytes, &out))
        return {};
    return out;
}

QByteArray CaptureHistory::readLayers(const QString &id) const
{
    QByteArray out;
    if (!validId(id) || !readPrivateFile(layersPath(id), kMaxLayersBytes, &out))
        return {};
    return out;
}

} // namespace screenshot
