#include "timezones.h"

#include <QFile>
#include <QSet>
#include <algorithm>

namespace {

constexpr qint64 kMaxTabBytes = 1 << 20; // the real file is about 20 KiB

// Lowercase, accents dropped, apostrophes (straight and typographic) and periods removed, other punctuation ("_" "-" "/" ","
// brackets) as spaces, runs of spaces collapsed.
QString normalize(const QString &text)
{
    const QString decomposed = text.normalized(QString::NormalizationForm_D);
    QString out;
    out.reserve(decomposed.size());
    for (const QChar ch : decomposed) {
        if (ch.category() == QChar::Mark_NonSpacing)
            continue;
        const QChar lower = ch.toLower();
        // Periods and apostrophes join ("U.K." is "uk", "d'Ivoire" and "d’Ivoire" are "divoire"); other punctuation separates.
        if (lower == u'.' || lower == u'\'' || lower == u'’' || lower == u'‘' || lower == u'ʼ' || lower == u'`'
            || lower == u'´')
            continue;
        const bool punct = lower.isPunct() || lower.isSymbol() || lower == u'_';
        out.append(punct ? QChar(u' ') : lower);
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
    {"Europe/Bucharest", "Bucarest"},
    {"Asia/Dubai", "Dubaï"}, {"Asia/Seoul", "Séoul"}, {"Asia/Singapore", "Singapour"},
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

// Names that are not a tzdata city but that people type: they resolve to the zone of the city they belong to, and the answer
// shows the alias' own name (en, fr), never the zone city's ("Beijing" is Asia/Shanghai's zone, Shanghai stays Shanghai).
struct AliasRow { const char *alias; const char *id; const char *en; const char *fr; };

constexpr AliasRow kCityAliases[] = {
    {"Beijing", "Asia/Shanghai", "Beijing", "Pékin"}, {"Peking", "Asia/Shanghai", "Beijing", "Pékin"},
    {"Pékin", "Asia/Shanghai", "Beijing", "Pékin"}, {"Kiev", "Europe/Kyiv", "Kyiv", "Kyiv"},
    {"Genève", "Europe/Zurich", "Geneva", "Genève"}, {"Geneva", "Europe/Zurich", "Geneva", "Genève"},
    {"Calcutta", "Asia/Kolkata", "Kolkata", "Calcutta"}, {"Bombay", "Asia/Kolkata", "Mumbai", "Bombay"},
    {"Mumbai", "Asia/Kolkata", "Mumbai", "Bombay"}, {"New Delhi", "Asia/Kolkata", "New Delhi", "New Delhi"},
    {"Delhi", "Asia/Kolkata", "Delhi", "Delhi"}, {"Saigon", "Asia/Ho_Chi_Minh", "Saigon", "Saïgon"},
    {"Washington", "America/New_York", "Washington", "Washington"}, {"Boston", "America/New_York", "Boston", "Boston"},
    {"Miami", "America/New_York", "Miami", "Miami"}, {"Atlanta", "America/New_York", "Atlanta", "Atlanta"},
    {"Houston", "America/Chicago", "Houston", "Houston"}, {"Dallas", "America/Chicago", "Dallas", "Dallas"},
    {"San Francisco", "America/Los_Angeles", "San Francisco", "San Francisco"},
    {"Seattle", "America/Los_Angeles", "Seattle", "Seattle"}, {"Las Vegas", "America/Los_Angeles", "Las Vegas", "Las Vegas"},
    {"Ottawa", "America/Toronto", "Ottawa", "Ottawa"}, {"Brasilia", "America/Sao_Paulo", "Brasília", "Brasilia"},
    {"Canberra", "Australia/Sydney", "Canberra", "Canberra"}, {"Tel Aviv", "Asia/Jerusalem", "Tel Aviv", "Tel Aviv"},
    {"Bangalore", "Asia/Kolkata", "Bengaluru", "Bangalore"}, {"Bengaluru", "Asia/Kolkata", "Bengaluru", "Bangalore"},
    {"Saint Petersburg", "Europe/Moscow", "Saint Petersburg", "Saint-Pétersbourg"},
    {"Saint-Pétersbourg", "Europe/Moscow", "Saint Petersburg", "Saint-Pétersbourg"},
};

// English names and short forms of countries that Qt spells differently or not at all: alias, ISO code.
constexpr NamePair kCountryAliases[] = {
    {"UK", "GB"}, {"Great Britain", "GB"}, {"England", "GB"}, {"Scotland", "GB"}, {"Wales", "GB"}, {"Britain", "GB"},
    {"USA", "US"}, {"America", "US"}, {"United States of America", "US"}, {"U.S.", "US"}, {"U.S.A.", "US"},
    {"UAE", "AE"}, {"Emirates", "AE"}, {"Ivory Coast", "CI"}, {"Côte d'Ivoire", "CI"}, {"Cote d'Ivoire", "CI"},
    {"Holland", "NL"}, {"Czech Republic", "CZ"}, {"Czechia", "CZ"}, {"Korea", "KR"}, {"South Korea", "KR"},
    {"Burma", "MM"}, {"Swaziland", "SZ"}, {"Turkey", "TR"}, {"Türkiye", "TR"}, {"Russia", "RU"}, {"Vietnam", "VN"},
    {"Royaume Uni", "GB"}, {"Etats Unis", "US"}, {"Pays Bas", "NL"}, {"Corée", "KR"}, {"Tchéquie", "CZ"},
};

// The zone of the capital for a country with several zones (a country answers with its capital's time, as the system clock
// apps do, not with the first row of zone1970.tab). A single-zone country needs no entry.
constexpr NamePair kCapitalZones[] = {
    {"US", "America/New_York"}, {"CA", "America/Toronto"}, {"AU", "Australia/Sydney"}, {"BR", "America/Sao_Paulo"},
    {"RU", "Europe/Moscow"}, {"MX", "America/Mexico_City"}, {"CN", "Asia/Shanghai"}, {"ID", "Asia/Jakarta"},
    {"KZ", "Asia/Almaty"}, {"AR", "America/Argentina/Buenos_Aires"}, {"CL", "America/Santiago"}, {"ES", "Europe/Madrid"},
    {"PT", "Europe/Lisbon"}, {"CD", "Africa/Kinshasa"}, {"EC", "America/Guayaquil"}, {"MN", "Asia/Ulaanbaatar"},
    {"GL", "America/Nuuk"}, {"PF", "Pacific/Tahiti"}, {"NZ", "Pacific/Auckland"}, {"FM", "Pacific/Pohnpei"},
    {"UA", "Europe/Kyiv"}, {"MY", "Asia/Kuala_Lumpur"}, {"PG", "Pacific/Port_Moresby"}, {"FR", "Europe/Paris"},
    {"GB", "Europe/London"}, {"UZ", "Asia/Tashkent"}, {"KI", "Pacific/Tarawa"}, {"DE", "Europe/Berlin"},
    {"NL", "Europe/Amsterdam"}, {"ZA", "Africa/Johannesburg"}, {"IN", "Asia/Kolkata"}, {"JP", "Asia/Tokyo"},
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
// Only an id QTimeZone lists as available is accepted (no offset ids such as "UTC+02:00", no POSIX strings), compared by
// exact bytes; "UTC" is always accepted.
const QSet<QByteArray> &availableIds()
{
    static const QSet<QByteArray> ids = [] {
        QSet<QByteArray> s;
        for (const QByteArray &raw : QTimeZone::availableTimeZoneIds())
            s.insert(raw);
        s.insert(QByteArray("UTC"));
        return s;
    }();
    return ids;
}

QTimeZone zoneOf(const QString &id)
{
    const QByteArray raw = id.toUtf8();
    if (raw.isEmpty() || raw.size() > 64 || raw.contains("..") || raw.startsWith('/'))
        return QTimeZone();
    for (const char c : raw)
        if (!(QChar::fromLatin1(c).isLetterOrNumber() || c == '_' || c == '+' || c == '-' || c == '/'))
            return QTimeZone();
    if (!availableIds().contains(raw))
        return QTimeZone();
    if (raw == "UTC")
        return QTimeZone::UTC;
    return QTimeZone(raw);
}

// Years the answers cover: a wall time outside them is invalid, not clamped to 1970.
constexpr int kMinYear = 1;
constexpr int kMaxYear = 9999;
bool yearOk(int year) { return year >= kMinYear && year <= kMaxYear; }

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

void TimeZones::warmUp() const
{
    ensureLoaded();
}

void TimeZones::ensureLoaded() const
{
    if (m_loaded)
        return;
    m_loaded = true;
    QHash<QString, int> byId;
    auto addCity = [&](const QString &id, const QString &comment, const QStringList &countries) {
        City c;
        c.id = id;
        c.city = cityOf(id);
        c.comment = comment;
        c.countries = countries;
        c.key = normalize(c.city);
        c.idKey = normalize(c.id);
        c.frKey = normalize(tableName(kFrenchCities, id));
        byId.insert(id, int(m_cities.size()));
        m_cities.append(c);
    };

    // The table's own rows first (their order is the table's: geographic within a country).
    int tableRows = 0;
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
            if (id.isEmpty() || byId.contains(id) || !availableIds().contains(id.toUtf8()))
                continue;
            QStringList countries;
            for (const QByteArray &cc : cols[0].split(','))
                if (!cc.trimmed().isEmpty())
                    countries << QString::fromLatin1(cc.trimmed());
            addCity(id, cols.size() > 3 ? QString::fromUtf8(cols[3]).trimmed() : QString(), countries);
            ++tableRows;
        }
    }
    m_hasTable = tableRows > 0;

    // Aliases: only those whose zone exists. Their keys shadow the zones tzdata keeps as backward links ("Kiev", "Calcutta").
    QSet<QString> aliasKeys;
    for (const AliasRow &a : kCityAliases)
        aliasKeys.insert(normalize(QString::fromUtf8(a.alias)));

    // zone1970.tab leaves out the zones that tzdata merged since 1970 (Amsterdam, Oslo, Vaduz...): the zones QTimeZone knows add
    // their city, after the table's own, with the country QTimeZone reports.
    static const QSet<QString> areas = {QStringLiteral("Africa"), QStringLiteral("America"), QStringLiteral("Antarctica"),
                                        QStringLiteral("Asia"), QStringLiteral("Atlantic"), QStringLiteral("Australia"),
                                        QStringLiteral("Europe"), QStringLiteral("Indian"), QStringLiteral("Pacific")};
    QStringList extra;
    for (const QByteArray &raw : availableIds()) {
        const QString id = QString::fromUtf8(raw);
        const int slash = id.indexOf(u'/');
        if (slash > 0 && !byId.contains(id) && areas.contains(id.left(slash)) && !aliasKeys.contains(normalize(cityOf(id))))
            extra << id;
    }
    std::sort(extra.begin(), extra.end());
    const int firstExtra = int(m_cities.size());
    for (const QString &id : std::as_const(extra)) {
        QStringList countries;
        const QLocale::Territory t = QTimeZone(id.toUtf8()).territory();
        if (t != QLocale::AnyTerritory)
            countries << QLocale::territoryToCode(t);
        addCity(id, QString(), countries);
    }

    for (const AliasRow &a : kCityAliases) {
        const int city = byId.value(QString::fromLatin1(a.id), -1);
        if (city < 0)
            continue;
        Alias al;
        al.key = normalize(QString::fromUtf8(a.alias));
        al.city = city;
        al.en = QString::fromUtf8(a.en);
        al.fr = QString::fromUtf8(a.fr);
        m_aliases.append(al);
    }

    // Countries. A table row counts for every code it lists (the first as the row's own, the others as shared); a merged zone from
    // Qt only for a country the table gives no row of its own (Netherlands, Norway, Liechtenstein).
    QHash<QString, int> countryIndex;
    auto countryAt = [&](const QString &code) -> Country & {
        auto it = countryIndex.find(code);
        if (it == countryIndex.end()) {
            it = countryIndex.insert(code, int(m_countries.size()));
            Country c;
            c.code = code;
            m_countries.append(c);
        }
        return m_countries[it.value()];
    };
    for (int i = 0; i < firstExtra; ++i) {
        const QStringList &cs = m_cities.at(i).countries;
        for (int k = 0; k < cs.size(); ++k) {
            Country &c = countryAt(cs.at(k));
            if (k == 0)
                c.rows.append(i);
            else if (c.secondary < 0)
                c.secondary = i;
        }
    }
    for (int i = firstExtra; i < m_cities.size(); ++i) {
        const QStringList &cs = m_cities.at(i).countries;
        if (cs.isEmpty())
            continue;
        Country &c = countryAt(cs.first());
        if (c.rows.isEmpty() || !m_hasTable)
            c.rows.append(i);
    }
    for (Country &c : m_countries) {
        const QLocale::Territory t = QLocale::codeToTerritory(c.code);
        if (t != QLocale::AnyTerritory)
            c.keys << normalize(QLocale::territoryToString(t));
        const QString fr = normalize(tableName(kFrenchCountries, c.code));
        if (!fr.isEmpty())
            c.keys << fr;
        c.keys << normalize(c.code);
        for (const NamePair &p : kCountryAliases)
            if (c.code == QLatin1String(p.name))
                c.keys << normalize(QString::fromUtf8(p.key));
        const QString capitalId = tableName(kCapitalZones, c.code);
        const int capital = capitalId.isEmpty() ? -1 : byId.value(capitalId, -1);
        if (capital >= 0 && c.rows.contains(capital))
            c.capital = capital;
        else if (!c.rows.isEmpty())
            c.capital = c.rows.first();
        else
            c.capital = c.secondary;
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

QVariantMap TimeZones::entryFor(int cityIndex, const QString &kind, bool ambiguous, const QLocale &loc, const Alias *alias) const
{
    const City &c = m_cities.at(cityIndex);
    QVariantMap m;
    m[QStringLiteral("id")] = c.id;
    if (alias) {
        m[QStringLiteral("city")] = alias->en;
        m[QStringLiteral("cityLocal")] = isFrench(loc) ? alias->fr : alias->en;
    } else {
        m[QStringLiteral("city")] = c.city;
        m[QStringLiteral("cityLocal")] = cityName(c.id, loc);
    }
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

    // Hits are cheap records; the maps (with the zone's localized name) are built for the few that are returned.
    enum Kind { CityHit, AliasHit, CountryHit, UtcHit };
    struct Hit { int rank; int group; int sub; Kind kind; int city; int alias; bool ambiguous; };
    QList<Hit> hits;

    if (q == u"utc" || q == u"gmt" || q == u"zulu")
        hits.append({0, -1, 0, UtcHit, -1, -1, false});

    const int cityCount = int(m_cities.size());
    for (int i = 0; i < cityCount; ++i) {
        const City &c = m_cities.at(i);
        int rank = -1;
        if (c.key == q || c.idKey == q || (!c.frKey.isEmpty() && c.frKey == q))
            rank = 0;
        else if (c.key.startsWith(q) || (!c.frKey.isEmpty() && c.frKey.startsWith(q)))
            rank = 2;
        else if (c.key.contains(u' ' + q) || (!c.frKey.isEmpty() && c.frKey.contains(u' ' + q)))
            rank = 3;
        if (rank >= 0)
            hits.append({rank, i, 0, CityHit, i, -1, false});
    }
    for (int a = 0; a < m_aliases.size(); ++a) {
        const Alias &al = m_aliases.at(a);
        int rank = -1;
        if (al.key == q)
            rank = 0;
        else if (al.key.startsWith(q))
            rank = 2;
        else if (al.key.contains(u' ' + q))
            rank = 3;
        if (rank >= 0)
            hits.append({rank, cityCount + a, 0, AliasHit, al.city, a, false});
    }
    // Countries: the capital's zone first, then the country's other zones in the table's order.
    for (const Country &c : std::as_const(m_countries)) {
        int rank = -1;
        for (const QString &key : c.keys) {
            if (key == q) {
                rank = 1;
                break;
            }
            if (q.size() >= 3 && key.startsWith(q))
                rank = 4;
        }
        if (rank < 0 || c.capital < 0)
            continue;
        const bool many = c.rows.size() > 1;
        hits.append({rank, c.capital, 0, CountryHit, c.capital, -1, many});
        int sub = 1;
        for (const int row : c.rows)
            if (row != c.capital)
                hits.append({rank, c.capital, sub++, CountryHit, row, -1, many});
    }

    std::stable_sort(hits.begin(), hits.end(), [](const Hit &a, const Hit &b) {
        if (a.rank != b.rank)
            return a.rank < b.rank;
        return a.group != b.group ? a.group < b.group : a.sub < b.sub;
    });
    QSet<int> used;
    for (const Hit &h : std::as_const(hits)) {
        if (out.size() >= limit)
            break;
        if (h.kind == UtcHit) {
            QVariantMap m;
            m[QStringLiteral("id")] = QStringLiteral("UTC");
            m[QStringLiteral("city")] = QStringLiteral("UTC");
            m[QStringLiteral("cityLocal")] = QStringLiteral("UTC");
            m[QStringLiteral("countryCode")] = QString();
            m[QStringLiteral("country")] = QString();
            m[QStringLiteral("comment")] = QString();
            m[QStringLiteral("name")] = QTimeZone(QTimeZone::UTC).displayName(QDateTime(QDate(2000, 1, 1), QTime(12, 0), QTimeZone::UTC),
                                                                              QTimeZone::LongName, loc);
            m[QStringLiteral("kind")] = QStringLiteral("utc");
            m[QStringLiteral("ambiguous")] = false;
            out.append(m);
            continue;
        }
        if (used.contains(h.city))
            continue;
        used.insert(h.city);
        const QString kind = h.kind == CountryHit ? QStringLiteral("country") : QStringLiteral("city");
        out.append(entryFor(h.city, kind, h.ambiguous, loc, h.kind == AliasHit ? &m_aliases.at(h.alias) : nullptr));
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
    if (!zone.isValid() || !utc.isValid() || !yearOk(utc.date().year())) {
        m[QStringLiteral("valid")] = false;
        return m;
    }
    const QLocale loc = localeFor(localeName);
    const QDateTime local = utc.toTimeZone(zone);
    if (!yearOk(local.date().year())) {
        m[QStringLiteral("valid")] = false;
        return m;
    }
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
    if (!zone.isValid() || !yearOk(year) || !date.isValid() || !time.isValid()) {
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
