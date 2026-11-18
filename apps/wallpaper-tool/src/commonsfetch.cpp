#include "commonsfetch.h"

#include <QBuffer>
#include <QDate>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QImageWriter>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonValue>
#include <QPainter>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>

#include <algorithm>
#include <map>
#include <vector>

#include <csignal>
#include <sys/prctl.h>
#include <unistd.h>

namespace wallpaper::commons {

namespace {

// The project contact required by Wikimedia's User-Agent policy (ADR-0016): the project's public repository, where an
// operator can open an issue (no person's address in every request). The version is the build's (GRASSFIELD_VERSION,
// from the VERSION file, as every app).
const char kContact[] = "https://github.com/grassfieldhq/grassfield";

const QStringList kHosts = {QStringLiteral("commons.wikimedia.org"), QStringLiteral("thumb.wikimedia.org"), QStringLiteral("upload.wikimedia.org")};
// NASA APOD: the API and the picture host. science.nasa.gov (where the logo answer pointed) is deliberately not listed.
const QStringList kApodHosts = {QStringLiteral("api.nasa.gov"), QStringLiteral("apod.nasa.gov")};

QString site(const QString &baseUrl)
{
    return baseUrl.isEmpty() ? QStringLiteral("https://commons.wikimedia.org") : baseUrl;
}

bool isWhitespace(char32_t c)
{
    return c <= 0x20 || (c >= 0x7f && c <= 0xa0) || c == 0x1680 || (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x2800 || c == 0x3000;
}

// Invisible and direction-changing characters, noncharacters and the replacement character. Also the characters that draw
// nothing but are not white space: the combining grapheme joiner, the Hangul fillers, the Khmer inherent vowels, the Mongolian
// free variation selectors and vowel separator, the variation selectors supplement and the musical formatting characters.
bool isRemoved(char32_t c)
{
    return c == 0x00ad || c == 0x034f || c == 0x061c || c == 0x115f || c == 0x1160 || c == 0x17b4 || c == 0x17b5 || (c >= 0x180b && c <= 0x180f) || c == 0x3164 || c == 0xffa0
        || (c >= 0x1d173 && c <= 0x1d17a) || (c >= 0xe0100 && c <= 0xe01ef) || (c >= 0x200b && c <= 0x200f) || (c >= 0x202a && c <= 0x202e) || (c >= 0x2060 && c <= 0x206f) || c == 0xfeff || (c >= 0xfff9 && c <= 0xfffd)
        || (c >= 0xfdd0 && c <= 0xfdef) || (c & 0xfffe) == 0xfffe || (c >= 0xe0000 && c <= 0xe007f) || (c >= 0xd800 && c <= 0xdfff);
}

// Control and bidi characters removed, white space collapsed, at most `maxChars` code points.
QString cleanChars(const QString &raw, int maxChars)
{
    const QList<uint> ucs = raw.toUcs4();
    QList<uint> out;
    bool pendingSpace = false;
    for (const uint c : ucs) {
        if (isWhitespace(c)) {
            pendingSpace = !out.isEmpty();
            continue;
        }
        if (isRemoved(c))
            continue;
        if (pendingSpace)
            out.append(0x20);
        pendingSpace = false;
        out.append(c);
    }
    if (out.size() > maxChars) {
        out = out.mid(0, std::max(0, maxChars - 1));
        out.append(0x2026);
    }
    return QString::fromUcs4(reinterpret_cast<const char32_t *>(out.constData()), out.size());
}

QString decodeEntities(const QString &s)
{
    static const QRegularExpression re(QStringLiteral("&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});"));
    static const QHash<QString, QString> named = {{QStringLiteral("amp"), QStringLiteral("&")}, {QStringLiteral("lt"), QStringLiteral("<")}, {QStringLiteral("gt"), QStringLiteral(">")},
                                                  {QStringLiteral("quot"), QStringLiteral("\"")}, {QStringLiteral("apos"), QStringLiteral("'")}, {QStringLiteral("nbsp"), QStringLiteral(" ")},
                                                  {QStringLiteral("ndash"), QStringLiteral("-")}, {QStringLiteral("mdash"), QStringLiteral("-")}, {QStringLiteral("hellip"), QStringLiteral("...")}};
    QString out;
    int last = 0;
    QRegularExpressionMatchIterator it = re.globalMatch(s);
    while (it.hasNext()) {
        const QRegularExpressionMatch m = it.next();
        out += QStringView(s).mid(last, m.capturedStart() - last);
        last = m.capturedEnd();
        const QString body = m.captured(1);
        QString rep;
        const bool numeric = body.startsWith(QLatin1Char('#'));
        if (numeric) {
            bool ok = false;
            const uint cp = (body.size() > 1 && (body[1] == QLatin1Char('x') || body[1] == QLatin1Char('X'))) ? body.mid(2).toUInt(&ok, 16) : body.mid(1).toUInt(&ok, 10);
            if (ok && cp != 0 && cp <= 0x10ffff && !(cp >= 0xd800 && cp <= 0xdfff))
                rep = QString::fromUcs4(reinterpret_cast<const char32_t *>(&cp), 1);
        } else {
            rep = named.value(body);
        }
        // An invalid number (NUL, a surrogate, beyond U+10FFFF) is dropped; an unknown name stays as written (it is only text).
        out += rep.isEmpty() && !numeric ? m.captured(0) : rep;
    }
    out += QStringView(s).mid(last);
    return out;
}

QString safeHttpsUrl(const QString &raw, int maxChars)
{
    QString s = raw.trimmed();
    if (s.startsWith(QStringLiteral("//")))
        s = QStringLiteral("https:") + s;
    if (s.size() > maxChars || s.isEmpty())
        return {};
    for (const QChar ch : s) {
        if (ch.unicode() <= 0x20 || ch.unicode() >= 0x7f)
            return {};
    }
    const QUrl u(s, QUrl::StrictMode);
    if (!u.isValid() || u.scheme() != QLatin1String("https") || u.host().isEmpty() || !u.userInfo().isEmpty())
        return {};
    return s;
}

QJsonObject object(const QByteArray &json)
{
    QJsonParseError err;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &err);
    return err.error == QJsonParseError::NoError && doc.isObject() ? doc.object() : QJsonObject();
}

QString wikitextOf(const QByteArray &json)
{
    const QJsonObject root = object(json);
    const QJsonObject e = root.value(QStringLiteral("expandtemplates")).toObject();
    QString wt = e.value(QStringLiteral("wikitext")).toString();
    if (wt.isEmpty())
        wt = e.value(QStringLiteral("*")).toString();
    return wt;
}

QString metaValue(const QJsonObject &ext, const QString &key)
{
    const QJsonValue v = ext.value(key).toObject().value(QStringLiteral("value"));
    return v.isString() ? v.toString() : QString();
}

QString enc(const QString &s)
{
    return QString::fromLatin1(QUrl::toPercentEncoding(s));
}

QDate dateOfName(const QString &name)
{
    return QDate::fromString(name.left(10), QStringLiteral("yyyy-MM-dd"));
}

} // namespace

QString userAgent()
{
    return QStringLiteral("Grassfield/%1 (%2)").arg(QStringLiteral(GRASSFIELD_VERSION), QString::fromLatin1(kContact));
}

bool validDate(const QString &date)
{
    static const QRegularExpression re(QStringLiteral("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\z"));
    if (!re.match(date).hasMatch())
        return false;
    const QDate d = QDate::fromString(date, QStringLiteral("yyyy-MM-dd"));
    return d.isValid() && d.year() >= 2004 && d.year() <= 2100;
}

bool baseUrlAllowed(const QString &base, bool dev)
{
    if (!dev)
        return false;
    static const QRegularExpression re(QStringLiteral("\\Ahttp://127\\.0\\.0\\.1:([0-9]{1,5})\\z"));
    const QRegularExpressionMatch m = re.match(base);
    if (!m.hasMatch())
        return false;
    const int port = m.captured(1).toInt();
    return port >= 1 && port <= 65535;
}

bool providerKnown(const QString &provider)
{
    return provider == QLatin1String("commons") || provider == QLatin1String("apod");
}

bool hostAllowed(const QUrl &url, const QString &baseUrl)
{
    return hostAllowedFor(QStringLiteral("commons"), url, baseUrl);
}

bool hostAllowedFor(const QString &provider, const QUrl &url, const QString &baseUrl)
{
    if (!providerKnown(provider))
        return false;
    if (!url.isValid() || url.isRelative() || !url.userInfo().isEmpty() || !url.fragment().isEmpty())
        return false;
    if (!baseUrl.isEmpty()) {
        const QUrl b(baseUrl, QUrl::StrictMode);
        return url.scheme() == b.scheme() && url.host() == b.host() && url.port() == b.port();
    }
    return url.scheme() == QLatin1String("https") && (url.port() == -1 || url.port() == 443) && (provider == QLatin1String("apod") ? kApodHosts : kHosts).contains(url.host());
}

QUrl withoutQuery(const QUrl &url)
{
    QUrl u = url;
    u.setQuery(QString());
    u.setFragment(QString());
    return u;
}

bool licenseAllowed(const QString &key)
{
    // Public-domain marks (pd, pd-old, pd-usgov, ...), CC0, CC BY and CC BY-SA with a version; nothing with NC or ND, no GFDL.
    // The real Commons keys of the ported and migrated versions are accepted: "cc-by-sa-3.0-de", "cc-by-sa-3.0-migrated",
    // "cc-by-3.0-us-migrated" (an optional two-letter country, which is never "nc" or "nd", then an optional "migrated").
    static const QRegularExpression re(QStringLiteral("\\A(pd|pd-[a-z0-9-]{1,40}|cc0|cc0-[0-9.]{1,6}|cc-zero|cc-by(-sa)?-[1-4]\\.[0-9](-(?!nc|nd)[a-z]{2})?(-migrated)?)\\z"));
    return re.match(key.toLower()).hasMatch();
}

QString plainText(const QString &raw, int maxChars)
{
    static const QRegularExpression scripts(QStringLiteral("<(script|style)\\b.*?</\\1\\s*>"), QRegularExpression::CaseInsensitiveOption | QRegularExpression::DotMatchesEverythingOption);
    static const QRegularExpression comments(QStringLiteral("<!--.*?-->"), QRegularExpression::DotMatchesEverythingOption);
    static const QRegularExpression breaks(QStringLiteral("<br\\b[^>]*>|</(p|div|li|tr)\\s*>"), QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression tags(QStringLiteral("<[^>]*>"));
    static const QRegularExpression templates(QStringLiteral("\\{\\{[^{}]*\\}\\}"));
    static const QRegularExpression media(QStringLiteral("\\[\\[(?:File|Image|Category|Datei|Fichier):[^\\]]*\\]\\]"), QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression wikilink(QStringLiteral("\\[\\[(?:[^\\[\\]|]*\\|)?([^\\[\\]|]*)\\]\\]"));
    static const QRegularExpression extLabel(QStringLiteral("\\[(?:https?:)?//[^\\s\\]]*\\s+([^\\]]*)\\]"));
    static const QRegularExpression extBare(QStringLiteral("\\[(?:https?:)?//[^\\s\\]]*\\]"));
    static const QRegularExpression quotes(QStringLiteral("'{2,5}"));
    static const QRegularExpression stray(QStringLiteral("\\[\\[|\\]\\]|\\{\\{|\\}\\}"));

    // Input is bounded before any regular expression runs (a hostile field cannot make this slow).
    QString s = raw.left(32 * 1024);
    s.remove(scripts);
    s.remove(comments);
    s.replace(breaks, QStringLiteral(" "));
    s.remove(tags);
    for (int i = 0; i < 8 && s.contains(templates); ++i)
        s.remove(templates);
    s.remove(media);
    for (int i = 0; i < 3; ++i)
        s.replace(wikilink, QStringLiteral("\\1"));
    s.replace(extLabel, QStringLiteral("\\1"));
    s.remove(extBare);
    s.remove(quotes);
    s.remove(stray);
    // Entities last, in one pass: a decoded character is never read as markup, and the character filter below sees it.
    s = decodeEntities(s);
    return cleanChars(s, maxChars);
}

QString fileNameFromWikitext(const QString &wikitext)
{
    QString s = wikitext.trimmed();
    for (const QString &prefix : {QStringLiteral("File:"), QStringLiteral("Image:")}) {
        if (s.startsWith(prefix, Qt::CaseInsensitive))
            s = s.mid(prefix.size()).trimmed();
    }
    if (s.isEmpty() || s.size() > 240)
        return {};
    for (const QChar ch : s) {
        const ushort c = ch.unicode();
        if (c < 0x20 || (c >= 0x7f && c <= 0x9f) || QStringLiteral("{}[]<>|#/\\").contains(ch))
            return {};
    }
    if (cleanChars(s, 1000) != s || !s.contains(QLatin1Char('.')))
        return {};
    return s;
}

bool imageSignatureOk(const QString &contentType, const QByteArray &head)
{
    const QString type = contentType.section(QLatin1Char(';'), 0, 0).trimmed().toLower();
    if (type == QLatin1String("image/jpeg"))
        return head.startsWith(QByteArray("\xff\xd8\xff", 3));
    if (type == QLatin1String("image/png"))
        return head.startsWith(QByteArray("\x89PNG\r\n\x1a\n", 8));
    if (type == QLatin1String("image/webp"))
        return head.size() >= 12 && head.startsWith("RIFF") && head.mid(8, 4) == "WEBP";
    return false;
}

bool outDirAllowed(const QString &out)
{
    return outDirAllowedFor(QStringLiteral("commons"), out);
}

bool outDirAllowedFor(const QString &provider, const QString &out)
{
    if (!providerKnown(provider) || !out.startsWith(QLatin1Char('/')))
        return false;
    const QStringList parts = out.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    if (parts.contains(QStringLiteral("..")) || parts.contains(QStringLiteral(".")) || parts.size() < 5)
        return false;
    const int n = parts.size();
    return parts[n - 1] == provider && parts[n - 2] == QLatin1String("online") && parts[n - 3] == QLatin1String("wallpapers")
        && (parts[n - 4] == QLatin1String("grassfield") || parts[n - 4] == QLatin1String("cache"));
}

bool isOnlineCacheName(const QString &name)
{
    static const QRegularExpression re(QStringLiteral("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\.(jpg|json)\\z"));
    return re.match(name).hasMatch() && dateOfName(name).isValid();
}

QString parseFileName(const QByteArray &json)
{
    return fileNameFromWikitext(wikitextOf(json));
}

QString parseCaption(const QByteArray &json)
{
    return plainText(wikitextOf(json), kMaxCaptionChars);
}

ExitCode parseImageInfo(const QByteArray &json, const QString &fileName, const QString &baseUrl, Parsed *out, QString *reason)
{
    auto bad = [&](const char *why) {
        if (reason)
            *reason = QString::fromLatin1(why);
        return BadResponse;
    };
    auto skip = [&](const char *why) {
        if (reason)
            *reason = QString::fromLatin1(why);
        return Skipped;
    };
    const QJsonObject root = object(json);
    const QJsonValue pagesValue = root.value(QStringLiteral("query")).toObject().value(QStringLiteral("pages"));
    QJsonObject page;
    if (pagesValue.isArray()) {
        const QJsonArray a = pagesValue.toArray();
        if (a.isEmpty())
            return bad("no pages");
        page = a.at(0).toObject();
    } else if (pagesValue.isObject()) {
        const QJsonObject o = pagesValue.toObject();
        if (o.isEmpty())
            return bad("no pages");
        page = o.begin().value().toObject();
    } else {
        return bad("no pages");
    }
    const QJsonArray infos = page.value(QStringLiteral("imageinfo")).toArray();
    if (page.value(QStringLiteral("missing")).toBool() || infos.isEmpty())
        return skip("no such file");
    const QJsonObject info = infos.at(0).toObject();
    if (!info.value(QStringLiteral("mime")).toString().startsWith(QStringLiteral("image/")))
        return skip("not a picture");
    const QJsonObject ext = info.value(QStringLiteral("extmetadata")).toObject();
    const QString key = metaValue(ext, QStringLiteral("License"));
    if (!licenseAllowed(key))
        return skip("licence not allowed");
    const QUrl thumb(info.value(QStringLiteral("thumburl")).toString(), QUrl::StrictMode);
    if (!thumb.isValid() || thumb.isRelative())
        return bad("no thumbnail");
    if (!hostAllowed(thumb, baseUrl))
        return bad("thumbnail host not allowed");

    Parsed p;
    p.fileName = fileName;
    p.thumbUrl = withoutQuery(thumb);
    QString base = fileName;
    base.truncate(base.lastIndexOf(QLatin1Char('.')) > 0 ? base.lastIndexOf(QLatin1Char('.')) : base.size());
    p.title = plainText(metaValue(ext, QStringLiteral("ObjectName")), kMaxTitleChars);
    if (p.title.isEmpty())
        p.title = plainText(QString(base).replace(QLatin1Char('_'), QLatin1Char(' ')), kMaxTitleChars);
    p.author = plainText(metaValue(ext, QStringLiteral("Artist")), kMaxCreditChars);
    p.credit = plainText(metaValue(ext, QStringLiteral("Credit")), kMaxCreditChars);
    p.licenseShort = plainText(metaValue(ext, QStringLiteral("LicenseShortName")), 64);
    p.licenseUrl = safeHttpsUrl(metaValue(ext, QStringLiteral("LicenseUrl")), 300);
    // The source page is built from the validated file name, never taken from the answer.
    QString title = QStringLiteral("File:") + QString(fileName).replace(QLatin1Char(' '), QLatin1Char('_'));
    p.sourceUrl = site(baseUrl) + QStringLiteral("/wiki/") + enc(title);
    *out = p;
    return Ok;
}

QJsonObject sidecarOf(const Parsed &p, const QString &caption, const QString &date, const QString &fetchedAtIso, int width, int height, const QString &provider)
{
    return {{QStringLiteral("provider"), provider}, {QStringLiteral("date"), date},       {QStringLiteral("title"), p.title},
            {QStringLiteral("author"), p.author},                    {QStringLiteral("credit"), p.credit},  {QStringLiteral("caption"), caption},
            {QStringLiteral("licenseShort"), p.licenseShort},        {QStringLiteral("licenseUrl"), p.licenseUrl}, {QStringLiteral("sourceUrl"), p.sourceUrl},
            {QStringLiteral("fetchedAt"), fetchedAtIso},             {QStringLiteral("width"), width},      {QStringLiteral("height"), height}};
}

QUrl apodUrl(const QString &baseUrl, const QString &date)
{
    const QString origin = baseUrl.isEmpty() ? QStringLiteral("https://api.nasa.gov") : baseUrl;
    QUrl url(origin + QStringLiteral("/planetary/apod"), QUrl::StrictMode);
    url.setQuery(QStringLiteral("api_key=") + enc(QString::fromLatin1(kApodKey)) + QStringLiteral("&date=") + enc(date) + QStringLiteral("&thumbs=false"), QUrl::StrictMode);
    return url;
}

namespace {

// An image address of an APOD answer to the https URL to fetch, or an empty URL. The picture must be on apod.nasa.gov (with a
// dev base URL: on that origin), under /apod/image/; a plain http address of apod.nasa.gov is upgraded to https; the query
// string and fragment are dropped. Anything else (the NASA Science logo of the broken answers, another host) is refused.
QUrl apodImage(const QString &raw, const QString &baseUrl)
{
    QUrl u(raw.trimmed(), QUrl::StrictMode);
    if (!u.isValid() || u.isRelative() || !u.userInfo().isEmpty())
        return {};
    if (baseUrl.isEmpty()) {
        if (u.scheme() == QLatin1String("http") && u.host() == QLatin1String("apod.nasa.gov") && (u.port() == -1 || u.port() == 80)) {
            u.setScheme(QStringLiteral("https"));
            u.setPort(-1);
        }
    }
    u = withoutQuery(u);
    if (!hostAllowedFor(QStringLiteral("apod"), u, baseUrl) || (baseUrl.isEmpty() && u.host() != QLatin1String("apod.nasa.gov")))
        return {};
    const QString path = u.path();
    if (!path.startsWith(QStringLiteral("/apod/image/")) || path.contains(QLatin1String("..")) || path.size() > 200)
        return {};
    return u;
}

} // namespace

ExitCode parseApod(const QByteArray &json, const QString &date, const QString &baseUrl, Parsed *out, QString *caption, QString *reason)
{
    auto fail = [&](ExitCode c, const char *why) {
        if (reason)
            *reason = QString::fromLatin1(why);
        return c;
    };
    const QJsonObject o = object(json);
    if (o.isEmpty() || !o.value(QStringLiteral("date")).isString())
        return fail(BadResponse, "malformed answer");
    if (o.value(QStringLiteral("date")).toString() != date)
        return fail(BadResponse, "the answer is for another date");
    if (o.value(QStringLiteral("media_type")).toString() != QLatin1String("image"))
        return fail(Skipped, "today's entry is not a picture");
    // hdurl first (the larger picture; the helper scales it down), then url.
    QUrl image = apodImage(o.value(QStringLiteral("hdurl")).toString(), baseUrl);
    if (!image.isValid() || image.isEmpty())
        image = apodImage(o.value(QStringLiteral("url")).toString(), baseUrl);
    if (!image.isValid() || image.isEmpty())
        return fail(Skipped, "no picture on apod.nasa.gov");
    Parsed p;
    p.thumbUrl = image;
    p.fileName = image.fileName();
    p.title = plainText(o.value(QStringLiteral("title")).toString(), kMaxTitleChars);
    if (p.title.isEmpty())
        return fail(Skipped, "no title");
    // Copyrighted days are shown with the credit (owner decision, ADR-0016): the holder is the author. A public entry has none.
    const QString holder = plainText(o.value(QStringLiteral("copyright")).toString(), kMaxCreditChars);
    p.author = holder;
    p.credit = holder;
    p.licenseShort = holder.isEmpty() ? QStringLiteral("Public domain (NASA)") : QStringLiteral("© ") + holder.left(60);
    p.licenseUrl = QString();
    const QDate d = QDate::fromString(date, QStringLiteral("yyyy-MM-dd"));
    p.sourceUrl = (baseUrl.isEmpty() ? QStringLiteral("https://apod.nasa.gov") : baseUrl) + QStringLiteral("/apod/ap") + d.toString(QStringLiteral("yyMMdd")) + QStringLiteral(".html");
    *caption = plainText(o.value(QStringLiteral("explanation")).toString(), kMaxCaptionChars);
    *out = p;
    return Ok;
}

QUrl apiUrl(const QString &baseUrl, const QList<QPair<QString, QString>> &query)
{
    QStringList parts;
    for (const auto &kv : query)
        parts << enc(kv.first) + QLatin1Char('=') + enc(kv.second);
    QUrl url(site(baseUrl) + QStringLiteral("/w/api.php"), QUrl::StrictMode);
    url.setQuery(parts.join(QLatin1Char('&')), QUrl::StrictMode);
    return url;
}

QStringList curlArgs(const QUrl &url, const QString &outFile, qint64 maxBytes, const QString &baseUrl)
{
    const QString proto = baseUrl.isEmpty() ? QStringLiteral("=https") : QStringLiteral("=http");
    QStringList a = {
        QStringLiteral("-q"), // first: no ~/.curlrc
        QStringLiteral("--silent"), QStringLiteral("--show-error"),
        QStringLiteral("--proto"), proto, QStringLiteral("--proto-redir"), proto, QStringLiteral("--max-redirs"), QString::number(kMaxRedirects),
        QStringLiteral("--connect-timeout"), QStringLiteral("10"), QStringLiteral("--max-time"), QStringLiteral("60"),
        QStringLiteral("--max-filesize"), QString::number(maxBytes),
        QStringLiteral("--tlsv1.2"), QStringLiteral("--globoff"),
        // No Accept-Encoding: the size limits count what is on the wire and what is stored, nothing is inflated. No cookie
        // jar, no Referer, no netrc, no credentials: curl sends none of them unless asked.
        QStringLiteral("--user-agent"), userAgent(),
        QStringLiteral("--no-clobber"), QStringLiteral("--output"), outFile,
        QStringLiteral("--write-out"), QStringLiteral("%{http_code}\\n%{content_type}\\n%{redirect_url}\\n"),
    };
    if (!baseUrl.isEmpty())
        a << QStringLiteral("--noproxy") << QStringLiteral("*"); // a loopback server is never reached through a proxy
    a << QStringLiteral("--url") << QString::fromLatin1(url.toEncoded());
    return a;
}

void pruneOnline(const QString &dirPath, const QString &newest, int keepDays, qint64 maxBytes)
{
    QDir dir(dirPath);
    const QDate newestDate = QDate::fromString(newest, QStringLiteral("yyyy-MM-dd"));
    std::map<QDate, qint64> sizes; // per date, ascending
    std::map<QDate, QStringList> files;
    const QFileInfoList all = dir.entryInfoList(QDir::Files | QDir::NoSymLinks | QDir::NoDotAndDotDot | QDir::Hidden);
    const QDateTime stale = QDateTime::currentDateTime().addSecs(-3600);
    for (const QFileInfo &f : all) {
        // A leftover of an interrupted download.
        if (f.fileName().startsWith(QStringLiteral(".dl-")) && f.fileName().endsWith(QStringLiteral(".part")) && f.lastModified() < stale) {
            QFile::remove(f.absoluteFilePath());
            continue;
        }
        if (!isOnlineCacheName(f.fileName()))
            continue;
        const QDate d = dateOfName(f.fileName());
        sizes[d] += f.size();
        files[d] << f.absoluteFilePath();
    }
    qint64 total = 0;
    for (const auto &kv : sizes)
        total += kv.second;
    auto drop = [&](const QDate &d) {
        for (const QString &path : files[d]) {
            QFile::remove(path);
        }
        total -= sizes[d];
        sizes[d] = 0;
        files[d].clear();
    };
    for (auto &kv : sizes) {
        if (newestDate.isValid() && kv.first <= newestDate.addDays(-keepDays) && kv.first != newestDate)
            drop(kv.first);
    }
    for (auto &kv : sizes) {
        if (total <= maxBytes)
            break;
        if (kv.first == newestDate || files[kv.first].isEmpty())
            continue;
        drop(kv.first);
    }
}

namespace {

// One curl run; the answer is the HTTP status and the headers curl was asked to print.
struct Hop {
    int status = 0;
    QString contentType;
    QString redirect;
};

ExitCode runCurl(const Options &o, const QUrl &url, const QString &outFile, qint64 maxBytes, Hop *hop, QString *reason)
{
    QFile::remove(outFile);
    QProcess p;
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.remove(QStringLiteral("SSLKEYLOGFILE"));
    p.setProcessEnvironment(env);
    // curl dies with the helper: a superseded fetch (SIGTERM, whose default action ends the helper) must not leave a transfer
    // running for up to --max-time.
    p.setChildProcessModifier([] { ::prctl(PR_SET_PDEATHSIG, SIGKILL); });
    p.setProgram(o.curl);
    p.setArguments(curlArgs(url, outFile, maxBytes, o.baseUrl));
    p.start();
    if (!p.waitForStarted(5000)) {
        *reason = QStringLiteral("curl cannot start");
        return Network;
    }
    p.closeWriteChannel();
    if (!p.waitForFinished(75000)) {
        p.kill();
        p.waitForFinished(2000);
        QFile::remove(outFile);
        *reason = QStringLiteral("timeout");
        return Timeout;
    }
    const int code = p.exitStatus() == QProcess::NormalExit ? p.exitCode() : -1;
    if (code != 0) {
        QFile::remove(outFile);
        *reason = QStringLiteral("curl exit %1: %2").arg(code).arg(cleanChars(QString::fromUtf8(p.readAllStandardError().left(2000)), 200));
        if (code == 28)
            return Timeout;
        if (code == 63)
            return TooLargeFile;
        return Network;
    }
    const QStringList lines = QString::fromUtf8(p.readAllStandardOutput().left(4096)).split(QLatin1Char('\n'));
    hop->status = lines.value(0).trimmed().toInt();
    hop->contentType = lines.value(1).trimmed();
    hop->redirect = lines.value(2).trimmed();
    return Ok;
}

// GET with every hop checked against the allow-list (curl itself does not follow redirects here: one redirect to another
// host is refused before any request is made to it).
// `pathRule`: when not empty, every hop (the first URL and each redirect) must have exactly that path (a rule ending in "/" is a
// prefix: the path starts with it, no ".." in it). APOD uses it so that a redirect cannot lead from the API or an
// /apod/image/ picture to another page of an allowed host (the NASA logo lives elsewhere on the site).
bool pathAllowed(const QUrl &url, const QString &rule)
{
    if (rule.isEmpty())
        return true;
    const QString path = url.path();
    if (path.contains(QLatin1String("..")))
        return false;
    return rule.endsWith(QLatin1Char('/')) ? path.startsWith(rule) : path == rule;
}

ExitCode httpGet(const Options &o, QUrl url, const QString &outFile, qint64 maxBytes, QString *contentType, QString *reason, const QString &pathRule = QString())
{
    for (int hops = 0; hops <= kMaxRedirects; ++hops) {
        if (!hostAllowedFor(o.provider, url, o.baseUrl) || !pathAllowed(url, pathRule)) {
            *reason = QStringLiteral("host not allowed");
            return Network;
        }
        Hop hop;
        if (const ExitCode c = runCurl(o, url, outFile, maxBytes, &hop, reason))
            return c;
        if (hop.status == 200) {
            qint64 bytes = 0;
            if (const ExitCode c = checkFile(outFile, maxBytes, &bytes)) {
                QFile::remove(outFile);
                *reason = QStringLiteral("bad download");
                return c == TooLargeFile ? TooLargeFile : Network;
            }
            *contentType = hop.contentType;
            return Ok;
        }
        if (hop.status >= 300 && hop.status < 400 && !hop.redirect.isEmpty()) {
            url = url.resolved(QUrl(hop.redirect, QUrl::StrictMode));
            continue;
        }
        QFile::remove(outFile);
        *reason = QStringLiteral("http %1").arg(hop.status);
        return Network;
    }
    *reason = QStringLiteral("too many redirects");
    return Network;
}

// A JSON answer: size-limited, regular file, a JSON content type.
ExitCode getJson(const Options &o, const QUrl &url, const QString &tmp, QByteArray *body, QString *reason, const QString &pathRule = QString())
{
    QString type;
    if (const ExitCode c = httpGet(o, url, tmp, kMaxJsonBytes, &type, reason, pathRule))
        return c == TooLargeFile ? BadResponse : c;
    QFile f(tmp);
    const bool ok = type.contains(QStringLiteral("json"), Qt::CaseInsensitive) && f.open(QIODevice::ReadOnly);
    if (ok)
        *body = f.read(kMaxJsonBytes + 1);
    f.close();
    QFile::remove(tmp);
    if (!ok || body->size() > kMaxJsonBytes) {
        *reason = QStringLiteral("the answer is not JSON or is too large");
        return BadResponse;
    }
    return Ok;
}

QImage flattened(const QImage &img)
{
    if (!img.hasAlphaChannel())
        return img.convertToFormat(QImage::Format_RGB32);
    QImage canvas(img.size(), QImage::Format_RGB32);
    canvas.fill(Qt::white);
    QPainter p(&canvas);
    p.drawImage(0, 0, img);
    return canvas;
}

// Removes the temporary files of one run on every way out.
struct Cleanup {
    QStringList paths;
    ~Cleanup()
    {
        for (const QString &p : std::as_const(paths))
            QFile::remove(p);
    }
};

} // namespace

namespace {

// Step 4 of every fetch: download the picture (Content-Type, magic bytes, size), decode it with the step 1 loader (header
// limits, allocation limit), re-encode it (metadata and profile gone, sRGB, at most 3840 on a side), write it and its sidecar,
// prune the folder.
ExitCode storePicture(const Options &opts, const Parsed &parsed, const QString &caption, const QString &download, const QString &image, const QString &sidecar, QJsonObject *result, QString *reason)
{
        QString type;
    if (const ExitCode c = httpGet(opts, parsed.thumbUrl, download, kMaxImageBytes, &type, reason, opts.provider == QLatin1String("apod") ? QStringLiteral("/apod/image/") : QString()))
        return c;
    QFile f(download);
    if (!f.open(QIODevice::ReadOnly)) {
        *reason = QStringLiteral("cannot read the download");
        return Unreadable;
    }
    const QByteArray head = f.read(16);
    f.close();
    if (!imageSignatureOk(type, head)) {
        *reason = QStringLiteral("not a jpeg, png or webp picture");
        return Skipped;
    }
    QImage img;
    if (const ExitCode c = loadPicture(download, QSize(kDefaultWidth, kDefaultWidth), Fit::Fit, &img)) {
        *reason = QStringLiteral("the picture cannot be used");
        return c;
    }
    // Re-encoded: metadata and profile gone, sRGB, at most 3840 on a side.
    QImage rgb = flattened(img);
    if (rgb.width() > kDefaultWidth || rgb.height() > kDefaultWidth)
        rgb = rgb.scaled(QSize(kDefaultWidth, kDefaultWidth), Qt::KeepAspectRatio, Qt::SmoothTransformation);
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    QImageWriter w(&buffer, "jpg");
    w.setQuality(92);
    if (!w.write(rgb) || bytes.isEmpty() || !writeAtomic(image, bytes)) {
        *reason = QStringLiteral("cannot write the picture");
        return WriteFailed;
    }
    QFile::setPermissions(image, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    QJsonObject meta = sidecarOf(parsed, caption, opts.date, QDateTime::currentDateTimeUtc().toString(Qt::ISODate), rgb.width(), rgb.height(), opts.provider);
    meta.insert(QStringLiteral("mean"), meanColor(rgb));
    if (!writeAtomic(sidecar, QJsonDocument(meta).toJson(QJsonDocument::Compact))) {
        QFile::remove(image);
        *reason = QStringLiteral("cannot write the sidecar");
        return WriteFailed;
    }
    QFile::setPermissions(sidecar, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    pruneOnline(opts.out, opts.date, kKeepDays, kKeepBytes);
    QJsonObject l = latestCached(opts.out, opts.date, opts.provider);
    l.insert(QStringLiteral("cached"), false);
    *result = l;
    return Ok;
}

} // namespace

QJsonObject latestCached(const QString &dirPath, const QString &onlyDate, const QString &provider)
{
    QDir dir(dirPath);
    QStringList names = dir.entryList({QStringLiteral("*.json")}, QDir::Files | QDir::NoSymLinks, QDir::Name);
    std::reverse(names.begin(), names.end());
    int tried = 0;
    for (const QString &name : std::as_const(names)) {
        if (++tried > 30)
            break;
        if (!isOnlineCacheName(name))
            continue;
        const QString date = name.left(10);
        if (!onlyDate.isEmpty() && date != onlyDate)
            continue;
        const QString image = dirPath + QLatin1Char('/') + date + QStringLiteral(".jpg");
        const QFileInfo ii(image);
        if (!ii.isFile() || ii.isSymLink())
            continue;
        QFile f(dirPath + QLatin1Char('/') + name);
        if (!f.open(QIODevice::ReadOnly) || f.size() > 64 * 1024)
            continue;
        const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
        if (o.value(QStringLiteral("provider")).toString() != provider || o.value(QStringLiteral("date")).toString() != date)
            continue;
        // What is handed on is a whitelist of text fields, cleaned again (the file is ours, but it is only a file).
        QJsonObject r{{QStringLiteral("ok"), true}, {QStringLiteral("found"), true}, {QStringLiteral("date"), date}, {QStringLiteral("file"), image}};
        const std::vector<std::pair<const char *, int>> fields = {{"title", kMaxTitleChars}, {"author", kMaxCreditChars}, {"credit", kMaxCreditChars}, {"caption", kMaxCaptionChars},
                                                                   {"licenseShort", 64},   {"fetchedAt", 40}};
        for (const auto &fld : fields)
            r.insert(QString::fromLatin1(fld.first), cleanChars(o.value(QString::fromLatin1(fld.first)).toString(), fld.second));
        r.insert(QStringLiteral("licenseUrl"), safeHttpsUrl(o.value(QStringLiteral("licenseUrl")).toString(), 300));
        const QString src = o.value(QStringLiteral("sourceUrl")).toString();
        r.insert(QStringLiteral("sourceUrl"), src.startsWith(QStringLiteral("http://127.0.0.1:")) ? cleanChars(src, 400) : safeHttpsUrl(src, 400));
        // The picture's mean colour ("#rrggbb"), the backdrop of a Fit (the aspect rule of ADR-0016 step 2).
        static const QRegularExpression colour(QStringLiteral("\\A#[0-9a-f]{6}\\z"));
        const QString mean = o.value(QStringLiteral("mean")).toString().toLower();
        r.insert(QStringLiteral("mean"), colour.match(mean).hasMatch() ? mean : QStringLiteral("#000000"));
        r.insert(QStringLiteral("provider"), provider);
        r.insert(QStringLiteral("width"), o.value(QStringLiteral("width")).toInt());
        r.insert(QStringLiteral("height"), o.value(QStringLiteral("height")).toInt());
        return r;
    }
    return {{QStringLiteral("ok"), true}, {QStringLiteral("found"), false}};
}

ExitCode fetchCommons(const Options &opts, QJsonObject *result, QString *reason)
{
    // The loopback origin is a test door: only for a dev session, only 127.0.0.1 (main() checks it too; this is the library's own rule).
    if (!opts.baseUrl.isEmpty() && !baseUrlAllowed(opts.baseUrl, opts.dev)) {
        *reason = QStringLiteral("the base URL is only for a dev session and only http://127.0.0.1:<port>");
        return Usage;
    }
    if (!validDate(opts.date) || !outDirAllowed(opts.out)) {
        *reason = QStringLiteral("bad date or output folder");
        return Usage;
    }
    // A day's picture is fetched once: both files there means nothing to do (no request at all).
    const QString image = opts.out + QLatin1Char('/') + opts.date + QStringLiteral(".jpg");
    const QString sidecar = opts.out + QLatin1Char('/') + opts.date + QStringLiteral(".json");
    // The folder above (online/) is created 0700 as well, so that the whole online cache is private.
    if (!ensureCacheDir(QFileInfo(opts.out).absolutePath()) || !ensureCacheDir(opts.out)) {
        *reason = QStringLiteral("cannot create the output folder");
        return WriteFailed;
    }
    if (QFileInfo(image).isFile() && QFileInfo(sidecar).isFile()) {
        QJsonObject l = latestCached(opts.out, opts.date);
        if (l.value(QStringLiteral("found")).toBool()) {
            l.insert(QStringLiteral("cached"), true);
            *result = l;
            return Ok;
        }
    }

    Cleanup cleanup;
    const QString stem = opts.out + QStringLiteral("/.dl-") + QString::number(::getpid()) + QLatin1Char('-');
    auto tmp = [&](const char *n) {
        const QString path = stem + QString::fromLatin1(n) + QStringLiteral(".part");
        cleanup.paths << path;
        return path;
    };

    // 1. the file name of the day, 2. its caption in the UI language (a missing caption is not an error).
    QByteArray body;
    const QString day = opts.date;
    if (const ExitCode c = getJson(opts, apiUrl(opts.baseUrl, {{QStringLiteral("action"), QStringLiteral("expandtemplates")}, {QStringLiteral("format"), QStringLiteral("json")}, {QStringLiteral("formatversion"), QStringLiteral("2")}, {QStringLiteral("prop"), QStringLiteral("wikitext")}, {QStringLiteral("text"), QStringLiteral("{{Potd/") + day + QStringLiteral("}}")}}), tmp("a"), &body, reason))
        return c;
    const QString fileName = parseFileName(body);
    if (fileName.isEmpty()) {
        *reason = QStringLiteral("no picture of the day");
        return Skipped;
    }
    QString caption;
    body.clear();
    QString captionReason;
    if (getJson(opts, apiUrl(opts.baseUrl, {{QStringLiteral("action"), QStringLiteral("expandtemplates")}, {QStringLiteral("format"), QStringLiteral("json")}, {QStringLiteral("formatversion"), QStringLiteral("2")}, {QStringLiteral("prop"), QStringLiteral("wikitext")}, {QStringLiteral("text"), QStringLiteral("{{Potd/") + day + QStringLiteral(" (") + opts.lang + QStringLiteral(")}}")}}), tmp("b"), &body, &captionReason) == Ok)
        caption = parseCaption(body);

    // 3. the file's data: licence, attribution, the server-scaled thumbnail.
    body.clear();
    if (const ExitCode c = getJson(opts,
                                   apiUrl(opts.baseUrl, {{QStringLiteral("action"), QStringLiteral("query")},
                                                         {QStringLiteral("format"), QStringLiteral("json")},
                                                         {QStringLiteral("formatversion"), QStringLiteral("2")},
                                                         {QStringLiteral("prop"), QStringLiteral("imageinfo")},
                                                         {QStringLiteral("titles"), QStringLiteral("File:") + fileName},
                                                         {QStringLiteral("iiprop"), QStringLiteral("url|size|mime|sha1|extmetadata")},
                                                         {QStringLiteral("iiurlwidth"), QString::number(opts.width)}}),
                                   tmp("c"), &body, reason))
        return c;
    Parsed parsed;
    if (const ExitCode c = parseImageInfo(body, fileName, opts.baseUrl, &parsed, reason))
        return c;

    return storePicture(opts, parsed, caption, tmp("d"), image, sidecar, result, reason);
}

ExitCode fetchApod(const Options &opts, QJsonObject *result, QString *reason)
{
    if (!opts.baseUrl.isEmpty() && !baseUrlAllowed(opts.baseUrl, opts.dev)) {
        *reason = QStringLiteral("the base URL is only for a dev session and only http://127.0.0.1:<port>");
        return Usage;
    }
    if (opts.provider != QLatin1String("apod") || !validDate(opts.date) || !outDirAllowedFor(QStringLiteral("apod"), opts.out)) {
        *reason = QStringLiteral("bad date or output folder");
        return Usage;
    }
    const QString image = opts.out + QLatin1Char('/') + opts.date + QStringLiteral(".jpg");
    const QString sidecar = opts.out + QLatin1Char('/') + opts.date + QStringLiteral(".json");
    if (!ensureCacheDir(QFileInfo(opts.out).absolutePath()) || !ensureCacheDir(opts.out)) {
        *reason = QStringLiteral("cannot create the output folder");
        return WriteFailed;
    }
    if (QFileInfo(image).isFile() && QFileInfo(sidecar).isFile()) {
        QJsonObject l = latestCached(opts.out, opts.date, QStringLiteral("apod"));
        if (l.value(QStringLiteral("found")).toBool()) {
            l.insert(QStringLiteral("cached"), true);
            *result = l;
            return Ok;
        }
    }
    Cleanup cleanup;
    const QString stem = opts.out + QStringLiteral("/.dl-") + QString::number(::getpid()) + QLatin1Char('-');
    auto tmp = [&](const char *n) {
        const QString path = stem + QString::fromLatin1(n) + QStringLiteral(".part");
        cleanup.paths << path;
        return path;
    };
    QByteArray body;
    if (const ExitCode c = getJson(opts, apodUrl(opts.baseUrl, opts.date), tmp("a"), &body, reason, QStringLiteral("/planetary/apod")))
        return c;
    Parsed parsed;
    QString caption;
    if (const ExitCode c = parseApod(body, opts.date, opts.baseUrl, &parsed, &caption, reason))
        return c;
    return storePicture(opts, parsed, caption, tmp("d"), image, sidecar, result, reason);
}

} // namespace wallpaper::commons
