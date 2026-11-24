#include "timezones.h"

#include <QFile>
#include <QSet>
#include <algorithm>

namespace {

constexpr qint64 kMaxTabBytes = 1 << 20; // the real file is about 20 KiB

// Lowercase, accents dropped, "_" "-" "/" "." as spaces, runs of spaces collapsed.
QString normalize(const QString &text)
{
    const QString decomposed = text.normalized(QString::NormalizationForm_D);
    QString out;
    out.reserve(decomposed.size());
    for (const QChar ch : decomposed) {
        if (ch.category() == QChar::Mark_NonSpacing)
            continue;
        const QChar lower = ch.toLower();
        out.append(lower == u'_' || lower == u'-' || lower == u'/' || lower == u'.' ? QChar(u' ') : lower);
    }
    return out.simplified();
}

QString cityOf(const QString &id)
{
    QString last = id.mid(id.lastIndexOf(u'/') + 1);
    last.replace(u'_', u' ');
    return last;
}

QLocale localeFor(const QString &name)
{
    return name.isEmpty() ? QLocale() : QLocale(name);
}

// Qt names a territory in English only (QLocale::territoryToString is static) and has no city names at all, so the French
// spellings people type are a small table: IANA id or ISO code, then the French name (UTF-8). Another language gets English.
struct NamePair { const char *key; const char *name; };

constexpr NamePair kFrenchCities[] = {
    {"Europe/London", "Londres"}, {"Europe/Moscow", "Moscou"}, {"Europe/Brussels", "Bruxelles"}, {"Europe/Lisbon", "Lisbonne"},
    {"Europe/Vienna", "Vienne"}, {"Europe/Warsaw", "Varsovie"}, {"Europe/Athens", "Athènes"}, {"Europe/Copenhagen", "Copenhague"},
    {"Europe/Kyiv", "Kiev"}, {"Europe/Bucharest", "Bucarest"}, {"Europe/Geneva", "Genève"}, {"Asia/Shanghai", "Pékin"},
    {"Asia/Kolkata", "Calcutta"}, {"Asia/Dubai", "Dubaï"}, {"Asia/Seoul", "Séoul"}, {"Asia/Singapore", "Singapour"},
    {"Asia/Jerusalem", "Jérusalem"}, {"Asia/Tehran", "Téhéran"}, {"Asia/Baghdad", "Bagdad"},
    {"America/Montreal", "Montréal"}, {"America/Havana", "La Havane"}, {"America/Mexico_City", "Mexico"},
    {"Africa/Cairo", "Le Caire"}, {"Africa/Algiers", "Alger"},
};

constexpr NamePair kFrenchCountries[] = {
    {"FR", "France"}, {"GB", "Royaume-Uni"}, {"DE", "Allemagne"}, {"ES", "Espagne"}, {"IT", "Italie"}, {"PT", "Portugal"},
    {"BE", "Belgique"}, {"NL", "Pays-Bas"}, {"CH", "Suisse"}, {"AT", "Autriche"}, {"GR", "Grèce"}, {"PL", "Pologne"},
    {"SE", "Suède"}, {"NO", "Norvège"}, {"DK", "Danemark"}, {"FI", "Finlande"}, {"IE", "Irlande"}, {"RU", "Russie"},
    {"TR", "Turquie"}, {"US", "États-Unis"}, {"MX", "Mexique"}, {"BR", "Brésil"}, {"AR", "Argentine"}, {"CL", "Chili"},
    {"JP", "Japon"}, {"CN", "Chine"}, {"IN", "Inde"}, {"KR", "Corée du Sud"}, {"AU", "Australie"},
    {"NZ", "Nouvelle-Zélande"}, {"EG", "Égypte"}, {"MA", "Maroc"}, {"DZ", "Algérie"}, {"TN", "Tunisie"},
    {"ZA", "Afrique du Sud"}, {"CM", "Cameroun"}, {"CI", "Côte d’Ivoire"}, {"SN", "Sénégal"},
    {"AE", "Émirats arabes unis"}, {"SA", "Arabie saoudite"}, {"IL", "Israël"},
};

template<size_t N>
QString tableName(const NamePair (&table)[N], const QString &key)
{
    for (const NamePair &p : table)
        if (key == QLatin1String(p.key))
            return QString::fromUtf8(p.name);
    return QString();
}

bool isFrench(const QLocale &loc) { return loc.language() == QLocale::French; }

// A city's name: the French spelling when the locale is French and the table has one, else tzdata's name.
QString cityName(const QString &id, const QLocale &loc)
{
    const QString fr = isFrench(loc) ? tableName(kFrenchCities, id) : QString();
    return fr.isEmpty() ? cityOf(id) : fr;
}

// A country's name: English, or French when the locale is French and the table has it.
QString countryName(const QString &code, const QLocale &loc)
{
    const QString fr = isFrench(loc) ? tableName(kFrenchCountries, code) : QString();
    if (!fr.isEmpty())
        return fr;
    const QLocale::Territory t = QLocale::codeToTerritory(code);
    return t == QLocale::AnyTerritory ? code : QLocale::territoryToString(t);
}

// A path-like or odd id never reaches QTimeZone's file lookup: letters, digits and "_+-/" only, no "..", at most 64 bytes.
QTimeZone zoneOf(const QString &id)
{
    const QByteArray raw = id.toUtf8();
    if (raw.isEmpty() || raw.size() > 64 || raw.contains("..") || raw.startsWith('/'))
        return QTimeZone();
    for (const char c : raw)
        if (!(QChar::fromLatin1(c).isLetterOrNumber() || c == '_' || c == '+' || c == '-' || c == '/'))
            return QTimeZone();
    return QTimeZone::isTimeZoneIdAvailable(raw) ? QTimeZone(raw) : QTimeZone();
}

QString isoOffset(int seconds)
{
    const QChar sign = seconds < 0 ? u'-' : u'+';
    const int a = qAbs(seconds);
    QString out = QStringLiteral("%1%2:%3").arg(sign).arg(a / 3600, 2, 10, QLatin1Char('0')).arg(a / 60 % 60, 2, 10, QLatin1Char('0'));
    if (a % 60)
        out += QStringLiteral(":%1").arg(a % 60, 2, 10, QLatin1Char('0'));
    return out;
}

struct Resolution
{
    bool valid = false;
    bool gap = false;
    bool ambiguous = false;
    qint64 epochMs = 0;
};

int offsetAt(const QTimeZone &zone, qint64 epochMs)
{
    return zone.offsetFromUtc(QDateTime::fromMSecsSinceEpoch(epochMs, QTimeZone::UTC));
}

// A wall time read as UTC, then moved by the offset a day before and a day after it (no zone has two transitions within a day):
// each candidate instant holds when the zone really has that offset there. Both hold: a fall-back repeated the time (the earlier
// instant wins). None: a spring-forward gap (the offset from before it: an instant after the gap).
Resolution resolve(const QTimeZone &zone, const QDate &date, const QTime &time)
{
    Resolution r;
    const qint64 asUtcMs = QDateTime(date, time, QTimeZone::UTC).toMSecsSinceEpoch();
    const int before = offsetAt(zone, asUtcMs - 86400000LL);
    const int after = offsetAt(zone, asUtcMs + 86400000LL);
    const qint64 e1 = asUtcMs - qint64(before) * 1000;
    const qint64 e2 = asUtcMs - qint64(after) * 1000;
    const bool ok1 = offsetAt(zone, e1) == before;
    const bool ok2 = offsetAt(zone, e2) == after;
    r.valid = true;
    if (ok1 && ok2) {
        r.epochMs = std::min(e1, e2);
        r.ambiguous = e1 != e2;
    } else if (ok1) {
        r.epochMs = e1;
    } else if (ok2) {
        r.epochMs = e2;
    } else {
        r.gap = true;
        r.epochMs = e1;
    }
    return r;
}

} // namespace

TimeZones::TimeZones(QObject *parent)
    : QObject(parent), m_tabPath(QStringLiteral("/usr/share/zoneinfo/zone1970.tab"))
{
}

TimeZones::TimeZones(const QString &tabPath, QObject *parent)
    : QObject(parent), m_tabPath(tabPath)
{
}

void TimeZones::ensureLoaded() const
{
    if (m_loaded)
        return;
    m_loaded = true;
    QSet<QString> seen;
    QFile file(m_tabPath);
    if (!m_tabPath.isEmpty() && file.open(QIODevice::ReadOnly)) {
        const QByteArray data = file.read(kMaxTabBytes);
        for (const QByteArray &rawLine : data.split('\n')) {
            if (rawLine.isEmpty() || rawLine.startsWith('#'))
                continue;
            const QList<QByteArray> cols = rawLine.split('\t');
            if (cols.size() < 3)
                continue;
            const QString id = QString::fromUtf8(cols[2]).trimmed();
            if (id.isEmpty() || seen.contains(id) || !zoneOf(id).isValid())
                continue;
            seen.insert(id);
            City c;
            c.id = id;
            c.city = cityOf(id);
            c.comment = cols.size() > 3 ? QString::fromUtf8(cols[3]).trimmed() : QString();
            for (const QByteArray &cc : cols[0].split(','))
                if (!cc.trimmed().isEmpty())
                    c.countries << QString::fromLatin1(cc.trimmed());
            c.key = normalize(c.city);
            c.idKey = normalize(c.id);
            m_cities.append(c);
            m_hasTable = true;
        }
    }
    // zone1970.tab leaves out the zones that tzdata merged since 1970 (Amsterdam, Oslo, Stockholm...): the zones QTimeZone knows
    // add their city, after the table's own, with the country QTimeZone reports.
    static const QSet<QString> areas = {QStringLiteral("Africa"), QStringLiteral("America"), QStringLiteral("Antarctica"),
                                        QStringLiteral("Asia"), QStringLiteral("Atlantic"), QStringLiteral("Australia"),
                                        QStringLiteral("Europe"), QStringLiteral("Indian"), QStringLiteral("Pacific")};
    QStringList extra;
    for (const QByteArray &raw : QTimeZone::availableTimeZoneIds()) {
        const QString id = QString::fromUtf8(raw);
        const int slash = id.indexOf(u'/');
        if (slash > 0 && !seen.contains(id) && areas.contains(id.left(slash)))
            extra << id;
    }
    std::sort(extra.begin(), extra.end());
    for (const QString &id : std::as_const(extra)) {
        City c;
        c.id = id;
        c.city = cityOf(id);
        const QLocale::Territory t = QTimeZone(id.toUtf8()).territory();
        if (t != QLocale::AnyTerritory)
            c.countries << QLocale::territoryToCode(t);
        c.key = normalize(c.city);
        c.idKey = normalize(c.id);
        m_cities.append(c);
    }
}

bool TimeZones::hasCityTable() const
{
    ensureLoaded();
    return m_hasTable;
}

QString TimeZones::normalizeId(const QString &id) const
{
    const QTimeZone zone = zoneOf(id);
    return zone.isValid() ? QString::fromUtf8(zone.id()) : QString();
}

QVariantMap TimeZones::entryFor(const City &c, const QString &kind, bool ambiguous, const QLocale &loc) const
{
    QVariantMap m;
    m[QStringLiteral("id")] = c.id;
    m[QStringLiteral("city")] = c.city;
    m[QStringLiteral("cityLocal")] = cityName(c.id, loc);
    m[QStringLiteral("countryCode")] = c.countries.value(0);
    m[QStringLiteral("country")] = c.countries.isEmpty() ? QString() : countryName(c.countries.value(0), loc);
    m[QStringLiteral("comment")] = c.comment;
    m[QStringLiteral("name")] = QTimeZone(c.id.toUtf8()).displayName(QDateTime(QDate(2000, 1, 1), QTime(12, 0), QTimeZone::UTC),
                                                                     QTimeZone::LongName, loc);
    m[QStringLiteral("kind")] = kind;
    m[QStringLiteral("ambiguous")] = ambiguous;
    return m;
}

QVariantList TimeZones::find(const QString &query, int limit, const QString &localeName) const
{
    QVariantList out;
    const QString q = normalize(query);
    if (q.isEmpty() || q.size() > 80 || limit <= 0)
        return out;
    ensureLoaded();
    const QLocale loc = localeFor(localeName);

    struct Hit { int rank; int order; QVariantMap entry; };
    QList<Hit> hits;
    QSet<QString> used;
    auto add = [&](int rank, int order, const QVariantMap &entry) {
        const QString id = entry.value(QStringLiteral("id")).toString();
        if (used.contains(id))
            return;
        used.insert(id);
        hits.append({rank, order, entry});
    };

    if (q == u"utc" || q == u"gmt" || q == u"zulu") {
        City utc;
        utc.id = QStringLiteral("UTC");
        utc.city = QStringLiteral("UTC");
        add(0, -1, entryFor(utc, QStringLiteral("utc"), false, loc));
    }

    for (int i = 0; i < m_cities.size(); ++i) {
        const City &c = m_cities.at(i);
        int rank = -1;
        // The French spelling matches in every locale: "Londres" is typed by someone whose language is French.
        const QString fr = normalize(tableName(kFrenchCities, c.id));
        if (c.key == q || c.idKey == q || fr == q)
            rank = 0;
        else if (c.key.startsWith(q) || fr.startsWith(q))
            rank = 2;
        else if (c.key.contains(u' ' + q) || fr.contains(u' ' + q))
            rank = 3;
        if (rank >= 0)
            add(rank, i, entryFor(c, QStringLiteral("city"), false, loc));
    }

    // Countries, by the localized name, the English name or the ISO code: the first row that lists the country first.
    QHash<QString, QList<int>> byCountry;
    for (int i = 0; i < m_cities.size(); ++i)
        if (!m_cities.at(i).countries.isEmpty())
            byCountry[m_cities.at(i).countries.value(0)].append(i);
    auto countryRank = [&](const QString &code) {
        const QString localized = normalize(countryName(code, loc));
        const QString english = normalize(countryName(code, QLocale::c()));
        const QString french = normalize(tableName(kFrenchCountries, code));
        if (localized == q || english == q || french == q || normalize(code) == q)
            return 1;
        if (q.size() >= 3 && (localized.startsWith(q) || english.startsWith(q) || french.startsWith(q)))
            return 4;
        return -1;
    };
    for (auto it = byCountry.cbegin(); it != byCountry.cend(); ++it) {
        const int rank = countryRank(it.key());
        if (rank < 0)
            continue;
        const int first = it.value().first();
        add(rank, first, entryFor(m_cities.at(first), QStringLiteral("country"), it.value().size() > 1, loc));
    }
    // A country that is never a row's first code (Liechtenstein shares Zurich): its first row.
    for (int i = 0; i < m_cities.size(); ++i) {
        const City &c = m_cities.at(i);
        for (int k = 1; k < c.countries.size(); ++k) {
            if (byCountry.contains(c.countries.at(k)))
                continue;
            const int rank = countryRank(c.countries.at(k));
            if (rank >= 0)
                add(rank, i, entryFor(c, QStringLiteral("country"), false, loc));
        }
    }

    std::stable_sort(hits.begin(), hits.end(), [](const Hit &a, const Hit &b) {
        return a.rank != b.rank ? a.rank < b.rank : a.order < b.order;
    });
    for (const Hit &h : std::as_const(hits)) {
        if (out.size() >= limit)
            break;
        out.append(h.entry);
    }
    return out;
}

QVariantMap TimeZones::lookup(const QString &query, const QString &localeName) const
{
    const QVariantList hits = find(query, 1, localeName);
    return hits.isEmpty() ? QVariantMap() : hits.first().toMap();
}

QVariantMap TimeZones::info(const QString &zoneId, qint64 epochMs, const QString &localeName) const
{
    QVariantMap m;
    const QTimeZone zone = zoneOf(zoneId);
    const QDateTime utc = QDateTime::fromMSecsSinceEpoch(epochMs, QTimeZone::UTC);
    if (!zone.isValid() || !utc.isValid()) {
        m[QStringLiteral("valid")] = false;
        return m;
    }
    const QLocale loc = localeFor(localeName);
    const QDateTime local = utc.toTimeZone(zone);
    const int offset = local.offsetFromUtc();
    m[QStringLiteral("valid")] = true;
    m[QStringLiteral("id")] = QString::fromUtf8(zone.id());
    m[QStringLiteral("city")] = cityOf(QString::fromUtf8(zone.id()));
    m[QStringLiteral("cityLocal")] = cityName(QString::fromUtf8(zone.id()), loc);
    m[QStringLiteral("offsetSeconds")] = offset;
    m[QStringLiteral("abbreviation")] = zone.abbreviation(utc);
    m[QStringLiteral("isDst")] = zone.isDaylightTime(utc);
    m[QStringLiteral("name")] = zone.displayName(utc, QTimeZone::LongName, loc);
    m[QStringLiteral("year")] = local.date().year();
    m[QStringLiteral("month")] = local.date().month();
    m[QStringLiteral("day")] = local.date().day();
    m[QStringLiteral("hour")] = local.time().hour();
    m[QStringLiteral("minute")] = local.time().minute();
    m[QStringLiteral("second")] = local.time().second();
    m[QStringLiteral("weekday")] = local.date().dayOfWeek();
    m[QStringLiteral("epochMs")] = epochMs;
    m[QStringLiteral("iso")] = local.toString(QStringLiteral("yyyy-MM-dd'T'HH:mm:ss")) + isoOffset(offset);
    return m;
}

QVariantMap TimeZones::now(const QString &zoneId, const QString &localeName) const
{
    return info(zoneId, QDateTime::currentMSecsSinceEpoch(), localeName);
}

QVariantMap TimeZones::instant(const QString &zoneId, int year, int month, int day, int hour, int minute, int second) const
{
    QVariantMap m;
    const QTimeZone zone = zoneOf(zoneId);
    const QDate date(year, month, day);
    const QTime time(hour, minute, second);
    if (!zone.isValid() || !date.isValid() || !time.isValid()) {
        m[QStringLiteral("valid")] = false;
        return m;
    }
    const Resolution r = resolve(zone, date, time);
    m[QStringLiteral("valid")] = r.valid;
    m[QStringLiteral("epochMs")] = r.epochMs;
    m[QStringLiteral("gap")] = r.gap;
    m[QStringLiteral("ambiguous")] = r.ambiguous;
    return m;
}

QVariantMap TimeZones::convert(const QString &fromZone, int year, int month, int day, int hour, int minute, int second,
                               const QString &toZone, const QString &localeName) const
{
    const QVariantMap at = instant(fromZone, year, month, day, hour, minute, second);
    if (!at.value(QStringLiteral("valid")).toBool())
        return at;
    const qint64 epochMs = at.value(QStringLiteral("epochMs")).toLongLong();
    QVariantMap m = info(toZone, epochMs, localeName);
    if (!m.value(QStringLiteral("valid")).toBool())
        return m;
    const int fromOffset = info(fromZone, epochMs, localeName).value(QStringLiteral("offsetSeconds")).toInt();
    m[QStringLiteral("gap")] = at.value(QStringLiteral("gap"));
    m[QStringLiteral("ambiguous")] = at.value(QStringLiteral("ambiguous"));
    m[QStringLiteral("fromOffsetSeconds")] = fromOffset;
    m[QStringLiteral("offsetDifferenceSeconds")] = m.value(QStringLiteral("offsetSeconds")).toInt() - fromOffset;
    return m;
}
