#include "memostore.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>

namespace memos {

namespace {

constexpr QFileDevice::Permissions kFilePerms = QFileDevice::ReadOwner | QFileDevice::WriteOwner;
constexpr QFileDevice::Permissions kDirPerms = QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner;

QString stamp(const QDateTime &t)
{
    return t.toUTC().toString(Qt::ISODate);
}

QDateTime parseStamp(const QJsonValue &v)
{
    QDateTime t = QDateTime::fromString(v.toString(), Qt::ISODate);
    return t.isValid() ? t.toUTC() : QDateTime::currentDateTimeUtc();
}

int side(const QJsonValue &v, int fallback)
{
    const int n = v.isDouble() ? v.toInt(fallback) : fallback;
    return qBound(kMinSide, n, kMaxSide);
}

} // namespace

QStringList colorNames()
{
    return {QStringLiteral("yellow"), QStringLiteral("blue"), QStringLiteral("green"), QStringLiteral("pink"), QStringLiteral("purple"),
            QStringLiteral("grey")};
}

bool isColorName(const QString &name)
{
    return colorNames().contains(name);
}

QString defaultColor()
{
    return colorNames().constFirst();
}

QString newId()
{
    QString id;
    id.reserve(32);
    for (int i = 0; i < 4; ++i)
        id += QStringLiteral("%1").arg(QRandomGenerator::system()->generate(), 8, 16, QLatin1Char('0'));
    return id;
}

bool isId(const QString &id)
{
    static const QRegularExpression re(QStringLiteral("^[0-9a-f]{32}$"));
    return re.match(id).hasMatch();
}

QJsonObject Memo::toJson() const
{
    QJsonObject o{{QStringLiteral("id"), id},
                  {QStringLiteral("color"), color},
                  {QStringLiteral("html"), html},
                  {QStringLiteral("width"), width},
                  {QStringLiteral("height"), height},
                  {QStringLiteral("collapsed"), collapsed},
                  {QStringLiteral("translucent"), translucent},
                  {QStringLiteral("created"), stamp(created)},
                  {QStringLiteral("modified"), stamp(modified)}};
    if (hasPosition) {
        o.insert(QStringLiteral("x"), x);
        o.insert(QStringLiteral("y"), y);
    }
    return o;
}

Memo Memo::fromJson(const QJsonObject &o, int defaultWidth, int defaultHeight)
{
    Memo m;
    m.id = o.value(QStringLiteral("id")).toString();
    if (!isId(m.id))
        m.id = newId();
    m.color = o.value(QStringLiteral("color")).toString();
    if (!isColorName(m.color))
        m.color = defaultColor();
    m.html = o.value(QStringLiteral("html")).toString();
    m.width = side(o.value(QStringLiteral("width")), defaultWidth);
    m.height = side(o.value(QStringLiteral("height")), defaultHeight);
    const QJsonValue x = o.value(QStringLiteral("x"));
    const QJsonValue y = o.value(QStringLiteral("y"));
    // A position only when both are integers within the sides' range (layout coordinates may be negative).
    const auto coordinate = [](const QJsonValue &v) {
        return v.isDouble() && v.toDouble() == double(qint64(v.toDouble())) && qAbs(v.toDouble()) <= 1000000;
    };
    if (coordinate(x) && coordinate(y)) {
        m.hasPosition = true;
        m.x = x.toInt();
        m.y = y.toInt();
    }
    m.collapsed = o.value(QStringLiteral("collapsed")).toBool(false);
    m.translucent = o.value(QStringLiteral("translucent")).toBool(false);
    m.created = parseStamp(o.value(QStringLiteral("created")));
    m.modified = o.contains(QStringLiteral("modified")) ? parseStamp(o.value(QStringLiteral("modified"))) : m.created;
    return m;
}

bool Memo::operator==(const Memo &other) const
{
    return id == other.id && color == other.color && html == other.html && width == other.width && height == other.height
        && hasPosition == other.hasPosition && (!hasPosition || (x == other.x && y == other.y)) && collapsed == other.collapsed
        && translucent == other.translucent && stamp(created) == stamp(other.created)
        && stamp(modified) == stamp(other.modified);
}

const Migrations &migrations()
{
    static const Migrations steps; // schema 1 is the first: nothing to migrate yet
    return steps;
}

MemoStore::MemoStore(const QString &dir, int schema, const Migrations &steps)
    : m_dir(dir)
    , m_schema(schema)
    , m_steps(steps)
{
}

QString MemoStore::dataDir(const QString &xdgDataHome, const QString &home)
{
    const QString base = !xdgDataHome.isEmpty() && QDir::isAbsolutePath(xdgDataHome) ? xdgDataHome : home + QStringLiteral("/.local/share");
    return base + QStringLiteral("/grassfield/memos");
}

QString MemoStore::dataDir()
{
    return dataDir(qEnvironmentVariable("XDG_DATA_HOME"), QDir::homePath());
}

QString MemoStore::filePath() const
{
    return m_dir + QStringLiteral("/memos.json");
}

void MemoStore::assertPrivate() const
{
    QDir().mkpath(m_dir);
    // mkpath applies no mode of its own, and a directory made by an older build or restored from a backup keeps its mode:
    // private at every launch, not only at the first.
    QFile::setPermissions(m_dir, kDirPerms);
    if (QFileInfo::exists(filePath()))
        QFile::setPermissions(filePath(), kFilePerms);
}

OpenState MemoStore::open(int defaultWidth, int defaultHeight)
{
    m_memos.clear();
    m_error.clear();
    m_foundSchema = 0;
    assertPrivate();
    QFileInfo info(filePath());
    if (!info.exists()) {
        m_foundSchema = m_schema;
        return m_state = OpenState::Ok;
    }
    QFile f(filePath());
    if (!info.isFile() || info.size() > kMaxFileBytes || !f.open(QIODevice::ReadOnly)) {
        m_error = info.size() > kMaxFileBytes ? QStringLiteral("%1 is larger than %2 bytes").arg(filePath()).arg(kMaxFileBytes)
                                               : QStringLiteral("cannot read %1: %2").arg(filePath(), f.errorString());
        qWarning("grassfield-memos: %s; the memos stay read only", qUtf8Printable(m_error));
        return m_state = OpenState::Unreadable;
    }
    const QByteArray bytes = f.readAll();
    f.close();
    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(bytes, &parseError);
    const QJsonValue schemaValue = doc.object().value(QStringLiteral("schema"));
    const bool shaped = parseError.error == QJsonParseError::NoError && doc.isObject() && schemaValue.isDouble()
        && schemaValue.toDouble() == double(schemaValue.toInt());
    if (!shaped) {
        // Kept, never deleted: the user (or a newer tool) may still read it. The parser's message names an offset only.
        const QString aside = filePath() + QStringLiteral(".unreadable-")
            + QDateTime::currentDateTimeUtc().toString(QStringLiteral("yyyyMMdd'T'HHmmss'Z'"));
        if (!QFile::rename(filePath(), aside)) {
            m_error = QStringLiteral("%1 is not a memos file and cannot be set aside").arg(filePath());
            qWarning("grassfield-memos: %s; the memos stay read only", qUtf8Printable(m_error));
            return m_state = OpenState::Unreadable;
        }
        QFile::setPermissions(aside, kFilePerms);
        qWarning("grassfield-memos: %s is not a memos file (%s); kept as %s, starting with no memo", qUtf8Printable(filePath()),
                 qUtf8Printable(parseError.error == QJsonParseError::NoError ? QStringLiteral("no schema")
                                                                             : QStringLiteral("JSON error at offset %1").arg(parseError.offset)),
                 qUtf8Printable(QFileInfo(aside).fileName()));
        m_foundSchema = m_schema;
        return m_state = OpenState::SetAside;
    }
    QJsonObject root = doc.object();
    m_foundSchema = schemaValue.toInt();
    if (m_foundSchema > m_schema) {
        m_error = QStringLiteral("%1 has schema %2, newer than this Memos reads (%3)").arg(filePath()).arg(m_foundSchema).arg(m_schema);
        qWarning("grassfield-memos: %s; the memos stay read only and the file is not rewritten", qUtf8Printable(m_error));
        return m_state = OpenState::Newer;
    }
    bool migrated = false;
    for (int version = m_foundSchema; version < m_schema; ++version) {
        const auto step = m_steps.find(version);
        if (step == m_steps.end() || !step->second(root)) {
            m_error = QStringLiteral("%1 has schema %2, which this Memos cannot migrate").arg(filePath()).arg(m_foundSchema);
            qWarning("grassfield-memos: %s; the memos stay read only", qUtf8Printable(m_error));
            return m_state = OpenState::Unreadable;
        }
        root.insert(QStringLiteral("schema"), version + 1);
        migrated = true;
    }
    const QJsonArray list = root.value(QStringLiteral("memos")).toArray();
    QSet<QString> seen;
    int skipped = 0;
    for (const QJsonValue &v : list) {
        if (!v.isObject()) {
            ++skipped;
            continue;
        }
        Memo m = Memo::fromJson(v.toObject(), defaultWidth, defaultHeight);
        while (seen.contains(m.id))
            m.id = newId();
        seen.insert(m.id);
        m_memos.append(m);
    }
    const QJsonValue listValue = root.value(QStringLiteral("memos"));
    const bool notAList = !listValue.isUndefined() && !listValue.isArray();
    if (skipped > 0 || notAList) {
        // The next save would write the file without them: the original is kept beside it first (a migration keeps its own
        // copy, below), and the store stays read only when it cannot be kept.
        const QString what = notAList ? QStringLiteral("its memos are not a list") : QStringLiteral("%1 entries are not memos").arg(skipped);
        qWarning("grassfield-memos: %s: %s; dropped at the next save, the original kept beside it", qUtf8Printable(filePath()),
                 qUtf8Printable(what));
        if (!migrated
            && !keepCopy(QStringLiteral(".dropped-") + QDateTime::currentDateTimeUtc().toString(QStringLiteral("yyyyMMdd'T'HHmmss'Z'")), bytes)) {
            m_error = QStringLiteral("cannot keep a copy of %1 before dropping what is not a memo").arg(filePath());
            qWarning("grassfield-memos: %s; the memos stay read only", qUtf8Printable(m_error));
            m_memos.clear();
            return m_state = OpenState::Unreadable;
        }
    }
    if (migrated) {
        // The original, once, beside the file; then the migrated document replaces it.
        if (!keepCopy(QStringLiteral(".schema-%1").arg(m_foundSchema), bytes)) {
            qWarning("grassfield-memos: cannot keep a copy of %s before migrating it; the memos stay read only", qUtf8Printable(filePath()));
            return m_state = OpenState::Unreadable;
        }
        QJsonArray out;
        for (const Memo &m : std::as_const(m_memos))
            out.append(m.toJson());
        root.insert(QStringLiteral("memos"), out);
        if (!writeDocument(root)) {
            qWarning("grassfield-memos: %s; the memos stay read only", qUtf8Printable(m_error));
            return m_state = OpenState::Unreadable;
        }
        qInfo("grassfield-memos: %s migrated from schema %d to %d", qUtf8Printable(filePath()), m_foundSchema, m_schema);
        return m_state = OpenState::Migrated;
    }
    return m_state = OpenState::Ok;
}

bool MemoStore::save(const QList<Memo> &memos)
{
    m_error.clear();
    if (readOnly()) {
        m_error = QStringLiteral("the memos are read only (%1)").arg(filePath());
        return false;
    }
    QJsonArray list;
    for (const Memo &m : memos)
        list.append(m.toJson());
    if (!writeDocument(QJsonObject{{QStringLiteral("schema"), m_schema}, {QStringLiteral("memos"), list}})) {
        qWarning("grassfield-memos: %s", qUtf8Printable(m_error));
        return false;
    }
    return true;
}

bool MemoStore::writeDocument(const QJsonObject &doc)
{
    assertPrivate();
    QSaveFile f(filePath());
    if (!f.open(QIODevice::WriteOnly)) {
        m_error = QStringLiteral("cannot write %1: %2").arg(filePath(), f.errorString());
        return false;
    }
    // The temporary file is private before any byte is in it (the directory is too).
    f.setPermissions(kFilePerms);
    const QByteArray bytes = QJsonDocument(doc).toJson(QJsonDocument::Indented);
    if (f.write(bytes) != bytes.size() || !f.flush() || (m_beforeCommit && !m_beforeCommit())) {
        m_error = QStringLiteral("cannot write %1: %2").arg(filePath(), f.error() == QFileDevice::NoError ? QStringLiteral("write fault") : f.errorString());
        f.cancelWriting();
        f.commit();
        return false;
    }
    if (!f.commit()) {
        m_error = QStringLiteral("cannot write %1: %2").arg(filePath(), f.errorString());
        return false;
    }
    QFile::setPermissions(filePath(), kFilePerms);
    return true;
}

bool MemoStore::keepCopy(const QString &suffix, const QByteArray &bytes)
{
    const QString path = filePath() + suffix;
    if (QFileInfo::exists(path))
        return true;
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly))
        return false;
    f.setPermissions(kFilePerms);
    if (f.write(bytes) != bytes.size()) {
        f.cancelWriting();
        f.commit();
        return false;
    }
    if (!f.commit())
        return false;
    QFile::setPermissions(path, kFilePerms);
    return true;
}

} // namespace memos
