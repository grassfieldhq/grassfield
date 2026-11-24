#pragma once

#include <QDateTime>
#include <QHash>
#include <QLocale>
#include <QObject>
#include <QQmlEngine>
#include <QString>
#include <QStringList>
#include <QTimeZone>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

// Singleton `TimeZones` of the QML module Grassfield.I18n: zones and cities from the system tzdata through QTimeZone, the city
// table from zone1970.tab, and DST-correct conversions of a wall time between zones. Offline, read-only, no state apart from the
// table parsed once on first use. Used by the command palette's date and time calculator (docs/specs/command-palette.md, C3/C4).
//
// Qt has no localized city or country names (QLocale::territoryToString is English only; QTimeZone::displayName localizes the
// time zone's own name), so a city is its tzdata name with spaces ("Buenos Aires") and `cityLocal` / `country` carry a small
// built-in French table (Londres, Japon...) when the locale is French; every other language gets English. A missing or
// unreadable zone1970.tab leaves the table to the zones QTimeZone itself lists; nothing throws.
//
// Every function takes the time as numbers, never a Date: the QML side owns "now" (the tests never read the clock).
class TimeZones : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit TimeZones(QObject *parent = nullptr);
    // For tests: another zone1970.tab (a missing path gives the QTimeZone-only table).
    explicit TimeZones(const QString &tabPath, QObject *parent = nullptr);

    // IANA id of a valid zone ("Europe/Paris", "UTC"), else "".
    Q_INVOKABLE QString normalizeId(const QString &id) const;

    // Cities and countries matching `query` (case, accents, "_" and "-" ignored): a city by its name or by its id, a country by its
    // localized or English name or ISO code, "utc" and "gmt". Best first: exact before prefix before word prefix, then the
    // table's order. At most `limit` entries:
    //   {id, city, cityLocal, country (localized), countryCode, comment, name (localized zone name), kind: "city"|"country"|"utc",
    //    ambiguous (a country with several zones: its first row in zone1970.tab's order)}
    Q_INVOKABLE QVariantList find(const QString &query, int limit = 8, const QString &localeName = QString()) const;
    // The single best match of find(), or an empty map.
    Q_INVOKABLE QVariantMap lookup(const QString &query, const QString &localeName = QString()) const;

    // What the zone shows at the instant `epochMs` (ms since the epoch, UTC):
    //   {valid, id, city, cityLocal, offsetSeconds, abbreviation, isDst, name (localized), year, month, day, hour, minute, second,
    //    weekday (1 Monday .. 7 Sunday), epochMs, iso ("2026-03-29T03:30:00+02:00")}
    // An unknown zone gives {valid: false}.
    Q_INVOKABLE QVariantMap info(const QString &zoneId, qint64 epochMs, const QString &localeName = QString()) const;
    // info() at the machine's clock now (the only function that reads it).
    Q_INVOKABLE QVariantMap now(const QString &zoneId, const QString &localeName = QString()) const;

    // The instant of a wall time in `zoneId`: {valid, epochMs, gap, ambiguous}. A time inside a spring-forward gap does not
    // exist: gap is true and the instant is the one after the gap (the same wall time with the offset from before it); a time
    // repeated by a fall-back has ambiguous true and the first (summer time) instant.
    Q_INVOKABLE QVariantMap instant(const QString &zoneId, int year, int month, int day, int hour, int minute, int second = 0) const;
    // The wall time in `fromZone` shown in `toZone`: info(toZone) of the instant, plus {gap, ambiguous, fromOffsetSeconds,
    // offsetDifferenceSeconds (to minus from, at that instant)}. {valid: false} when a zone or the date is invalid.
    Q_INVOKABLE QVariantMap convert(const QString &fromZone, int year, int month, int day, int hour, int minute, int second,
                                    const QString &toZone, const QString &localeName = QString()) const;

    // True when zone1970.tab was read (for diagnostics).
    Q_INVOKABLE bool hasCityTable() const;

private:
    struct City
    {
        QString id;          // IANA id
        QString city;        // "Buenos Aires"
        QString comment;
        QStringList countries;
        QString key;         // normalized city
        QString idKey;       // normalized id
    };
    void ensureLoaded() const;
    QVariantMap entryFor(const City &c, const QString &kind, bool ambiguous, const QLocale &loc) const;

    QString m_tabPath;
    mutable bool m_loaded = false;
    mutable bool m_hasTable = false;
    mutable QList<City> m_cities;
};
