// TimeZones (ui/i18n/timezones.h): the city table, lookup, and DST-correct conversions. Every instant is fixed: nothing here
// reads the clock (but one smoke test of now()) or depends on the machine's zone (the process zone is forced to a distant one).
#include <gtest/gtest.h>

#include <QCoreApplication>
#include <QDateTime>

#include "timezones.h"

#ifndef GF_FIXTURE_TAB
#error "GF_FIXTURE_TAB must name tests/fixtures/zone1970-small.tab"
#endif

namespace {

qint64 utcMs(int y, int mo, int d, int h, int mi, int s = 0)
{
    return QDateTime(QDate(y, mo, d), QTime(h, mi, s), QTimeZone::UTC).toMSecsSinceEpoch();
}

TimeZones &zones()
{
    static TimeZones z{QStringLiteral(GF_FIXTURE_TAB)};
    return z;
}

QString str(const QVariantMap &m, const char *k) { return m.value(QLatin1String(k)).toString(); }
int num(const QVariantMap &m, const char *k) { return m.value(QLatin1String(k)).toInt(); }
bool flag(const QVariantMap &m, const char *k) { return m.value(QLatin1String(k)).toBool(); }
qint64 epoch(const QVariantMap &m) { return m.value(QStringLiteral("epochMs")).toLongLong(); }

QString lookupId(const char *query, const char *locale = "en")
{
    return str(zones().lookup(QString::fromUtf8(query), QString::fromLatin1(locale)), "id");
}

} // namespace

TEST(TimeZonesTable, ReadsTheFixtureAndSkipsBadRows)
{
    EXPECT_TRUE(zones().hasCityTable());
    EXPECT_TRUE(zones().find(QStringLiteral("not a zone")).isEmpty());
    EXPECT_TRUE(zones().find(QStringLiteral("AZone")).isEmpty()); // an id QTimeZone does not know is not a city
    EXPECT_EQ(lookupId("tokyo"), "Asia/Tokyo");
}

TEST(TimeZonesTable, MissingOrBrokenFileGivesTheQtZonesOnly)
{
    TimeZones none{QStringLiteral("/nonexistent/zone1970.tab")};
    EXPECT_FALSE(none.hasCityTable());
    EXPECT_EQ(str(none.lookup(QStringLiteral("Tokyo")), "id"), "Asia/Tokyo");
    TimeZones dir{QStringLiteral("/usr")}; // a directory: unreadable as a file
    EXPECT_FALSE(dir.hasCityTable());
    EXPECT_EQ(str(dir.lookup(QStringLiteral("Paris")), "id"), "Europe/Paris");
    TimeZones empty{QString()};
    EXPECT_FALSE(empty.hasCityTable());
    EXPECT_GE(empty.find(QStringLiteral("london")).size(), 1);
}

TEST(TimeZonesFind, CitiesByNameIdCaseAndAccents)
{
    EXPECT_EQ(lookupId("New York"), "America/New_York");
    EXPECT_EQ(lookupId("  new_york "), "America/New_York");
    EXPECT_EQ(lookupId("america/new_york"), "America/New_York");
    EXPECT_EQ(lookupId("São Paulo"), "America/Sao_Paulo");
    EXPECT_EQ(str(zones().lookup(QStringLiteral("LONDON")), "city"), "London");
    EXPECT_EQ(str(zones().lookup(QStringLiteral("london")), "kind"), "city");
}

TEST(TimeZonesFind, MergedZonesComeFromQt)
{
    // Amsterdam is not in zone1970.tab (it merged into Brussels); QTimeZone knows it.
    EXPECT_EQ(lookupId("Amsterdam"), "Europe/Amsterdam");
}

TEST(TimeZonesFind, CountriesInEnglishAndFrench)
{
    const QVariantMap fr = zones().lookup(QStringLiteral("france"), QStringLiteral("en"));
    EXPECT_EQ(str(fr, "id"), "Europe/Paris");
    EXPECT_EQ(str(fr, "kind"), "country");
    EXPECT_EQ(str(fr, "country"), "France");
    EXPECT_EQ(lookupId("japon", "fr"), "Asia/Tokyo");
    EXPECT_EQ(lookupId("japan", "fr"), "Asia/Tokyo");
    EXPECT_EQ(str(zones().lookup(QStringLiteral("allemagne"), QStringLiteral("fr")), "country"), "Allemagne");
    // A country with two rows is flagged; the first row (New York) is the answer.
    const QVariantMap us = zones().lookup(QStringLiteral("US"));
    EXPECT_EQ(str(us, "id"), "America/New_York");
    EXPECT_TRUE(flag(us, "ambiguous"));
    EXPECT_FALSE(flag(fr, "ambiguous"));
    // Liechtenstein is only ever a secondary code of Zurich's row in the fixture; Qt's own Vaduz zone answers.
    EXPECT_EQ(lookupId("liechtenstein"), "Europe/Vaduz");
    // French spellings of cities match in any locale and show in a French one.
    EXPECT_EQ(lookupId("londres", "en"), "Europe/London");
    EXPECT_EQ(str(zones().lookup(QStringLiteral("londres"), QStringLiteral("fr")), "cityLocal"), "Londres");
    EXPECT_EQ(str(zones().lookup(QStringLiteral("london"), QStringLiteral("en")), "cityLocal"), "London");
    EXPECT_EQ(str(zones().info(QStringLiteral("Europe/London"), 0, QStringLiteral("fr")), "cityLocal"), "Londres");
}

TEST(TimeZonesFind, UtcOrderAndLimits)
{
    EXPECT_EQ(lookupId("utc"), "UTC");
    EXPECT_EQ(str(zones().lookup(QStringLiteral("GMT")), "kind"), "utc");
    EXPECT_EQ(str(zones().find(QStringLiteral("paris")).value(0).toMap(), "id"), "Europe/Paris");
    EXPECT_LE(zones().find(QStringLiteral("a"), 3).size(), 3);
    EXPECT_TRUE(zones().find(QStringLiteral("tokyo"), 0).isEmpty());
    EXPECT_TRUE(zones().find(QString()).isEmpty());
    EXPECT_TRUE(zones().find(QString(500, QLatin1Char('x'))).isEmpty());
    EXPECT_TRUE(zones().lookup(QStringLiteral("zzzzqqq")).isEmpty());
}

TEST(TimeZonesIds, NormalizeRefusesOddIds)
{
    EXPECT_EQ(zones().normalizeId(QStringLiteral("Europe/Paris")), "Europe/Paris");
    EXPECT_EQ(zones().normalizeId(QStringLiteral("UTC")), "UTC");
    EXPECT_TRUE(zones().normalizeId(QStringLiteral("../../etc/passwd")).isEmpty());
    EXPECT_TRUE(zones().normalizeId(QStringLiteral("/etc/passwd")).isEmpty());
    EXPECT_TRUE(zones().normalizeId(QStringLiteral("Europe/Par is")).isEmpty());
    EXPECT_TRUE(zones().normalizeId(QString()).isEmpty());
    EXPECT_TRUE(zones().normalizeId(QString(100, QLatin1Char('A'))).isEmpty());
    EXPECT_FALSE(flag(zones().info(QStringLiteral("Nope/Nowhere"), 0), "valid"));
}

TEST(TimeZonesInfo, ParisAcrossTheSpringForward2026)
{
    // 2026-03-29: Europe/Paris goes from +01:00 to +02:00 at 01:00:00 UTC.
    const QVariantMap before = zones().info(QStringLiteral("Europe/Paris"), utcMs(2026, 3, 29, 0, 59, 59), QStringLiteral("en"));
    EXPECT_EQ(str(before, "iso"), "2026-03-29T01:59:59+01:00");
    EXPECT_FALSE(flag(before, "isDst"));
    EXPECT_EQ(num(before, "offsetSeconds"), 3600);
    const QVariantMap after = zones().info(QStringLiteral("Europe/Paris"), utcMs(2026, 3, 29, 1, 0, 0), QStringLiteral("en"));
    EXPECT_EQ(str(after, "iso"), "2026-03-29T03:00:00+02:00");
    EXPECT_TRUE(flag(after, "isDst"));
    EXPECT_EQ(num(after, "weekday"), 7); // Sunday
    EXPECT_EQ(num(after, "hour"), 3);
    EXPECT_EQ(str(after, "city"), "Paris");
}

TEST(TimeZonesInfo, FixedOffsetsIncludingHalfHours)
{
    EXPECT_EQ(num(zones().info(QStringLiteral("Asia/Kolkata"), utcMs(2026, 6, 1, 0, 0)), "offsetSeconds"), 19800);
    EXPECT_EQ(num(zones().info(QStringLiteral("Asia/Kathmandu"), utcMs(2026, 6, 1, 0, 0)), "offsetSeconds"), 20700);
    EXPECT_EQ(str(zones().info(QStringLiteral("Asia/Kathmandu"), utcMs(2026, 6, 1, 0, 0)), "iso"), "2026-06-01T05:45:00+05:45");
    EXPECT_EQ(str(zones().info(QStringLiteral("America/St_Johns"), utcMs(2026, 1, 1, 12, 0)), "iso"), "2026-01-01T08:30:00-03:30");
    EXPECT_EQ(str(zones().info(QStringLiteral("UTC"), utcMs(2026, 1, 1, 12, 0)), "iso"), "2026-01-01T12:00:00+00:00");
    EXPECT_EQ(str(zones().info(QStringLiteral("Asia/Tokyo"), utcMs(2026, 12, 31, 20, 0)), "iso"), "2027-01-01T05:00:00+09:00");
}

TEST(TimeZonesInfo, ZoneNameIsLocalized)
{
    const QString en = str(zones().info(QStringLiteral("Asia/Tokyo"), utcMs(2026, 6, 1, 0, 0), QStringLiteral("en")), "name");
    const QString fr = str(zones().info(QStringLiteral("Asia/Tokyo"), utcMs(2026, 6, 1, 0, 0), QStringLiteral("fr")), "name");
    EXPECT_FALSE(en.isEmpty());
    EXPECT_FALSE(fr.isEmpty());
    EXPECT_NE(en, fr);
}

TEST(TimeZonesConvert, ParisToTokyoWinterAndSummer)
{
    // 15:00 CET = 14:00Z = 23:00 JST; 15:00 CEST = 13:00Z = 22:00 JST.
    EXPECT_EQ(str(zones().convert(QStringLiteral("Europe/Paris"), 2026, 1, 15, 15, 0, 0, QStringLiteral("Asia/Tokyo")), "iso"), "2026-01-15T23:00:00+09:00");
    EXPECT_EQ(str(zones().convert(QStringLiteral("Europe/Paris"), 2026, 7, 15, 15, 0, 0, QStringLiteral("Asia/Tokyo")), "iso"), "2026-07-15T22:00:00+09:00");
    EXPECT_EQ(num(zones().convert(QStringLiteral("Europe/Paris"), 2026, 1, 15, 15, 0, 0, QStringLiteral("Asia/Tokyo")), "offsetDifferenceSeconds"), 8 * 3600);
    EXPECT_EQ(num(zones().convert(QStringLiteral("Europe/Paris"), 2026, 7, 15, 15, 0, 0, QStringLiteral("Asia/Tokyo")), "offsetDifferenceSeconds"), 7 * 3600);
}

TEST(TimeZonesConvert, UsAndEuropeDisagreeBetweenTheTwoChanges)
{
    // New York changed on 2026-03-08, Paris on 2026-03-29: 12:00 in New York is 17:00 in Paris on the 20th, 18:00 on the 30th.
    const QVariantMap a = zones().convert(QStringLiteral("America/New_York"), 2026, 3, 20, 12, 0, 0, QStringLiteral("Europe/Paris"));
    EXPECT_EQ(num(a, "hour"), 17);
    EXPECT_EQ(num(a, "offsetDifferenceSeconds"), 5 * 3600);
    const QVariantMap b = zones().convert(QStringLiteral("America/New_York"), 2026, 3, 30, 12, 0, 0, QStringLiteral("Europe/Paris"));
    EXPECT_EQ(num(b, "hour"), 18);
    EXPECT_EQ(num(b, "offsetDifferenceSeconds"), 6 * 3600);
    // A day crossing: 23:30 in Paris (summer) is the next day in Tokyo.
    EXPECT_EQ(str(zones().convert(QStringLiteral("Europe/Paris"), 2026, 7, 1, 23, 30, 0, QStringLiteral("Asia/Tokyo")), "iso"), "2026-07-02T06:30:00+09:00");
}

TEST(TimeZonesConvert, SpringForwardGapIsReported)
{
    // 2026-03-08 02:30 does not exist in New York (clocks jump from 02:00 EST to 03:00 EDT).
    const QVariantMap in = zones().instant(QStringLiteral("America/New_York"), 2026, 3, 8, 2, 30, 0);
    EXPECT_TRUE(flag(in, "valid"));
    EXPECT_TRUE(flag(in, "gap"));
    EXPECT_FALSE(flag(in, "ambiguous"));
    // The instant after the gap: 02:30 read with the offset from before it (-05:00) = 07:30Z = 03:30 EDT.
    EXPECT_EQ(epoch(in), utcMs(2026, 3, 8, 7, 30));
    const QVariantMap ok = zones().instant(QStringLiteral("America/New_York"), 2026, 3, 8, 3, 30, 0);
    EXPECT_FALSE(flag(ok, "gap"));
    EXPECT_EQ(epoch(ok), utcMs(2026, 3, 8, 7, 30));
    const QVariantMap before = zones().instant(QStringLiteral("America/New_York"), 2026, 3, 8, 1, 59, 59);
    EXPECT_FALSE(flag(before, "gap"));
    EXPECT_EQ(epoch(before), utcMs(2026, 3, 8, 6, 59, 59));
    EXPECT_TRUE(flag(zones().convert(QStringLiteral("America/New_York"), 2026, 3, 8, 2, 30, 0, QStringLiteral("UTC")), "gap"));
}

TEST(TimeZonesConvert, FallBackRepeatsAnHourAndTakesTheFirst)
{
    // 2026-10-25: Paris goes back at 01:00 UTC; 02:30 happens twice (00:30Z in summer time, 01:30Z in winter time).
    const QVariantMap rep = zones().instant(QStringLiteral("Europe/Paris"), 2026, 10, 25, 2, 30, 0);
    EXPECT_TRUE(flag(rep, "ambiguous"));
    EXPECT_FALSE(flag(rep, "gap"));
    EXPECT_EQ(epoch(rep), utcMs(2026, 10, 25, 0, 30));
    EXPECT_FALSE(flag(zones().instant(QStringLiteral("Europe/Paris"), 2026, 10, 25, 1, 59, 59), "ambiguous"));
    EXPECT_FALSE(flag(zones().instant(QStringLiteral("Europe/Paris"), 2026, 10, 25, 3, 0, 0), "ambiguous"));
    // The next day's 02:30 is plain winter time: 01:30Z.
    EXPECT_EQ(epoch(zones().instant(QStringLiteral("Europe/Paris"), 2026, 10, 26, 2, 30, 0)), utcMs(2026, 10, 26, 1, 30));
}

TEST(TimeZonesConvert, InvalidInputs)
{
    EXPECT_FALSE(flag(zones().convert(QStringLiteral("Nope"), 2026, 1, 1, 0, 0, 0, QStringLiteral("UTC")), "valid"));
    EXPECT_FALSE(flag(zones().convert(QStringLiteral("UTC"), 2026, 1, 1, 0, 0, 0, QStringLiteral("Nope")), "valid"));
    EXPECT_FALSE(flag(zones().convert(QStringLiteral("UTC"), 2026, 2, 30, 0, 0, 0, QStringLiteral("UTC")), "valid"));
    EXPECT_FALSE(flag(zones().convert(QStringLiteral("UTC"), 2026, 1, 1, 24, 0, 0, QStringLiteral("UTC")), "valid"));
    EXPECT_FALSE(flag(zones().instant(QStringLiteral("UTC"), 2026, 13, 1, 0, 0), "valid"));
    // A leap day exists in 2028 and not in 2026.
    EXPECT_TRUE(flag(zones().convert(QStringLiteral("UTC"), 2028, 2, 29, 12, 0, 0, QStringLiteral("Asia/Tokyo")), "valid"));
    EXPECT_FALSE(flag(zones().convert(QStringLiteral("UTC"), 2026, 2, 29, 12, 0, 0, QStringLiteral("Asia/Tokyo")), "valid"));
}

TEST(TimeZonesNow, SmokeOnly)
{
    const QVariantMap n = zones().now(QStringLiteral("UTC"));
    EXPECT_TRUE(flag(n, "valid"));
    EXPECT_GT(epoch(n), utcMs(2026, 1, 1, 0, 0));
}

int main(int argc, char **argv)
{
    // The machine's own zone must not matter: a distant one.
    qputenv("TZ", "Pacific/Kiritimati");
    QCoreApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
