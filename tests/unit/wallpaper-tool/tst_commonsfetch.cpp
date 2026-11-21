// Unit tests of `grassfield-wallpaper fetch commons` (ADR-0016 step 2, slice O1). Pure rules first (text clean-up, licences,
// hosts, curl vector, parsing), then the whole fetch against a loopback server (fixtures/commons/server.py) that stands in for
// Wikimedia. The tests never touch the network: every request goes to 127.0.0.1, and the fixtures are synthetic JSON modelled
// on the real answers recorded in the ADR plus a JPEG generated here (no real picture is committed).
#include <gtest/gtest.h>

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPainter>
#include <QProcess>
#include <QTemporaryDir>

#include <sys/stat.h>

#include "commonsfetch.h"

using namespace wallpaper;
using namespace wallpaper::commons;

namespace {

QString fixtureDir()
{
#ifdef FIXTURE_DIR
    return QStringLiteral(FIXTURE_DIR "/commons");
#else
    return QFileInfo(QStringLiteral(__FILE__)).absolutePath() + QStringLiteral("/fixtures/commons");
#endif
}

QByteArray readFile(const QString &path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

void writeFile(const QString &path, const QByteArray &data)
{
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
    f.write(data);
}

QImage gradient(int w, int h)
{
    QImage img(w, h, QImage::Format_RGB32);
    QPainter p(&img);
    QLinearGradient g(0, 0, w, h);
    g.setColorAt(0, QColor(20, 60, 120));
    g.setColorAt(1, QColor(240, 180, 90));
    p.fillRect(img.rect(), g);
    return img;
}

bool saveJpeg(const QString &path, const QImage &img)
{
    return img.save(path, "JPG", 90);
}

} // namespace

// ---------------------------------------------------------------- pure rules

TEST(CommonsText, TagsLinksAndQuotesBecomePlainText)
{
    EXPECT_EQ(plainText(QStringLiteral("<a href=\"//x\" title=\"User:A\">Jane</a> &amp; <b>John</b>"), 300), QStringLiteral("Jane & John"));
    EXPECT_EQ(plainText(QStringLiteral("A ''calm'' lake near [[Lyon|the city]] and [[Paris]].<br />{{Potd/credit}}"), 300), QStringLiteral("A calm lake near the city and Paris."));
    EXPECT_EQ(plainText(QStringLiteral("'''bold''' [https://example.org a site] [https://example.org] [[File:x.jpg|thumb|cap]]"), 300), QStringLiteral("bold a site"));
    EXPECT_EQ(plainText(QStringLiteral("a<script>alert(1)</script>b<style>p{}</style>c<!-- hidden -->d"), 300), QStringLiteral("abcd"));
    EXPECT_EQ(plainText(QStringLiteral("{{a|{{b|c}}}} text"), 300), QStringLiteral("text"));
}

TEST(CommonsText, ControlAndBidiCharactersAreRemoved)
{
    // U+202E (right-to-left override), U+2066 (isolate), U+200F (mark), U+0007 (bell), NUL, a zero-width space, a tag character.
    const QString raw = QStringLiteral("Do") + QChar(0x202e) + QStringLiteral("e") + QChar(0x2066) + QChar(0x200f) + QChar(7) + QChar(0) + QChar(0x200b) + QStringLiteral("x\ny\tz");
    EXPECT_EQ(plainText(raw, 300), QStringLiteral("Doe x y z"));
    // The same characters written as entities are removed too (decoded first, filtered after).
    EXPECT_EQ(plainText(QStringLiteral("a&#x202E;b&#8238;c&#7;d&#0;e&#xD800;f&#1114112;g"), 300), QStringLiteral("abc defg"));
}

TEST(CommonsText, InvisibleFillersAreRemoved)
{
    // Hangul fillers (U+3164, U+115F, U+1160, U+FFA0), the Mongolian vowel separator (U+180E) and free variation selectors, the combining
    // grapheme joiner (U+034F), the Khmer inherent vowels, a Braille blank, the variation selectors supplement: they draw nothing and
    // must not survive (a title made of them would look empty, or hide text between letters).
    for (const char32_t c : {0x3164u, 0x115fu, 0x1160u, 0xffa0u, 0x180eu, 0x180bu, 0x180fu, 0x034fu, 0x17b4u, 0x17b5u, 0x2800u, 0xe0100u, 0x1d173u}) {
        const QString s = QStringLiteral("a") + QString::fromUcs4(&c, 1) + QStringLiteral("b");
        EXPECT_EQ(plainText(s, 300), c == 0x2800u ? QStringLiteral("a b") : QStringLiteral("ab")) << QString::number(c, 16).toStdString();
        EXPECT_EQ(plainText(QString::fromUcs4(&c, 1), 300), QString()) << QString::number(c, 16).toStdString();
    }
    // As entities too.
    EXPECT_EQ(plainText(QStringLiteral("a&#x3164;b&#4447;c&#x180E;d"), 300), QStringLiteral("abcd"));
    // Ordinary text with accents, CJK and emoji is untouched.
    EXPECT_EQ(plainText(QStringLiteral("Ch\u00e2teau \u5bcc\u58eb \U0001F600"), 300), QStringLiteral("Ch\u00e2teau \u5bcc\u58eb \U0001F600"));
}

TEST(CommonsText, LengthIsBoundedInCodePoints)
{
    const QString long300(300, QLatin1Char('a'));
    const QString t = plainText(long300, kMaxTitleChars);
    EXPECT_EQ(t.size(), kMaxTitleChars);
    EXPECT_TRUE(t.endsWith(QChar(0x2026)));
    // Astral characters count as one: 250 emoji cut at 200 code points, never in the middle of a pair.
    QString emoji;
    for (int i = 0; i < 250; ++i)
        emoji += QStringLiteral("\U0001F600");
    const QString e = plainText(emoji, kMaxTitleChars);
    EXPECT_EQ(e.toUcs4().size(), kMaxTitleChars);
    EXPECT_FALSE(e.at(e.size() - 2).isHighSurrogate());
    // A hostile 1 MiB field costs no more than the cap: it is cut before the expressions run.
    QElapsedTimer t0;
    t0.start();
    const QString big = plainText(QString(1024 * 1024, QLatin1Char('<')), kMaxCreditChars);
    EXPECT_LE(big.size(), kMaxCreditChars);
    EXPECT_LT(t0.elapsed(), 2000);
}

TEST(CommonsLicense, AllowListByMachineKey)
{
    for (const char *ok : {"pd", "pd-old", "pd-usgov-nasa", "pd-self", "cc0", "cc0-1.0", "cc-zero", "cc-by-2.0", "cc-by-4.0", "cc-by-3.0-de", "cc-by-sa-4.0", "cc-by-sa-2.5", "CC-BY-SA-4.0", "cc-by-sa-3.0-migrated", "cc-by-3.0-migrated", "cc-by-sa-3.0-de", "cc-by-3.0-us-migrated", "cc-by-sa-2.0-fr"})
        EXPECT_TRUE(licenseAllowed(QString::fromLatin1(ok))) << ok;
    for (const char *no : {"", "gfdl", "cc-by-nc-4.0", "cc-by-nd-4.0", "cc-by-nc-sa-4.0", "cc-by-sa", "cc-by-", "copyrighted", "fair-use", "attribution", "pd/../x", "pdx", "cc-by-4.0 ", "cc-by-4.0\nx", "fal", "cc-by-4.0-nc", "cc-by-4.0-nd", "cc-by-sa-4.0-nc", "cc-by-sa-3.0-nd-migrated", "cc-by-4.0-ncx", "cc-by-4.0-nc-migrated", "cc-by-sa-3.0-migrated-nc", "cc-by-4.0-de-nc", "cc-by-4.0-migrated-migrated", "cc-by-9.0", "cc-by-sa-10.0", "cc-by-4.0-abc"})
        EXPECT_FALSE(licenseAllowed(QString::fromLatin1(no))) << no;
}

TEST(CommonsHosts, OnlyTheAllowListOverHttps)
{
    auto ok = [](const char *u, const QString &base = QString()) { return hostAllowed(QUrl(QString::fromLatin1(u), QUrl::StrictMode), base); };
    EXPECT_TRUE(ok("https://commons.wikimedia.org/w/api.php?x=1"));
    EXPECT_TRUE(ok("https://thumb.wikimedia.org/thumb/a/a1/x.jpg/3840px-x.jpg"));
    EXPECT_TRUE(ok("https://upload.wikimedia.org/wikipedia/commons/a/a1/x.jpg"));
    EXPECT_TRUE(ok("https://commons.wikimedia.org:443/x"));
    EXPECT_FALSE(ok("http://commons.wikimedia.org/x"));
    EXPECT_FALSE(ok("https://commons.wikimedia.org:8443/x"));
    EXPECT_FALSE(ok("https://commons.wikimedia.org.evil.example/x"));
    EXPECT_FALSE(ok("https://evilcommons.wikimedia.org/x"));
    EXPECT_FALSE(ok("https://commons.wikimedia.org@evil.example/x"));
    EXPECT_FALSE(ok("https://user:pw@commons.wikimedia.org/x"));
    EXPECT_FALSE(ok("https://commons.wikimedia.org./x"));
    EXPECT_FALSE(ok("https://www.wikimedia.org/x"));
    EXPECT_FALSE(ok("https://science.nasa.gov/nasa-logo.png"));
    EXPECT_FALSE(ok("file:///etc/passwd"));
    EXPECT_FALSE(ok("//commons.wikimedia.org/x"));
    EXPECT_FALSE(ok("ftp://upload.wikimedia.org/x"));
    // With a base URL the origin is exactly that one, and no Wikimedia host any more.
    const QString base = QStringLiteral("http://127.0.0.1:8123");
    EXPECT_TRUE(ok("http://127.0.0.1:8123/thumb/p.jpg", base));
    EXPECT_FALSE(ok("http://127.0.0.1:8124/thumb/p.jpg", base));
    EXPECT_FALSE(ok("http://127.0.0.2:8123/thumb/p.jpg", base));
    EXPECT_FALSE(ok("https://127.0.0.1:8123/thumb/p.jpg", base));
    EXPECT_FALSE(ok("https://commons.wikimedia.org/x", base));
}

TEST(CommonsHosts, BaseUrlOnlyInADevSessionAndOnlyLoopback)
{
    EXPECT_TRUE(baseUrlAllowed(QStringLiteral("http://127.0.0.1:8080"), true));
    EXPECT_FALSE(baseUrlAllowed(QStringLiteral("http://127.0.0.1:8080"), false));
    for (const char *no : {"http://localhost:8080", "http://127.0.0.1", "http://127.0.0.1:8080/", "http://127.0.0.1:8080/w", "http://127.0.0.1:0", "http://127.0.0.1:99999", "https://127.0.0.1:8080", "http://127.0.0.1:8080@evil.example", "http://127.0.0.1.evil.example:80", "http://10.0.0.1:80", "http://user@127.0.0.1:80", ""})
        EXPECT_FALSE(baseUrlAllowed(QString::fromLatin1(no), true)) << no;
}

TEST(CommonsHosts, TheQueryStringIsDropped)
{
    EXPECT_EQ(withoutQuery(QUrl(QStringLiteral("https://thumb.wikimedia.org/a/b.jpg?utm_source=x&utm_campaign=y#f"))).toString(), QStringLiteral("https://thumb.wikimedia.org/a/b.jpg"));
}

TEST(CommonsFiles, FileNameFromWikitext)
{
    EXPECT_EQ(fileNameFromWikitext(QStringLiteral("Example_lake_at_dawn.jpg\n")), QStringLiteral("Example_lake_at_dawn.jpg"));
    EXPECT_EQ(fileNameFromWikitext(QStringLiteral("File:Lac d'Annecy (été).JPG")), QStringLiteral("Lac d'Annecy (été).JPG"));
    for (const char *no : {"", "[[:Template:Potd/2099-01-01]]", "{{Potd/x}}", "a|b.jpg", "a/b.jpg", "<b>x</b>.jpg", "no extension", "a\nb.jpg", "x.jpg#frag", "a\\b.jpg"})
        EXPECT_EQ(fileNameFromWikitext(QString::fromUtf8(no)), QString()) << no;
    EXPECT_EQ(fileNameFromWikitext(QString(300, QLatin1Char('a')) + QStringLiteral(".jpg")), QString());
    EXPECT_EQ(fileNameFromWikitext(QStringLiteral("a") + QChar(0x202e) + QStringLiteral("gpj.exe")), QString());
}

TEST(CommonsFiles, SignatureMustMatchTheContentType)
{
    const QByteArray jpg("\xff\xd8\xff\xe0\0\x10JFIF", 10), png("\x89PNG\r\n\x1a\n\0\0\0\rIHDR", 16), webp("RIFF\x10\0\0\0WEBPVP8 ", 16), html("<html><body>hi</body></html>");
    EXPECT_TRUE(imageSignatureOk(QStringLiteral("image/jpeg"), jpg));
    EXPECT_TRUE(imageSignatureOk(QStringLiteral("image/JPEG; charset=binary"), jpg));
    EXPECT_TRUE(imageSignatureOk(QStringLiteral("image/png"), png));
    EXPECT_TRUE(imageSignatureOk(QStringLiteral("image/webp"), webp));
    EXPECT_FALSE(imageSignatureOk(QStringLiteral("image/png"), jpg));
    EXPECT_FALSE(imageSignatureOk(QStringLiteral("image/jpeg"), png));
    EXPECT_FALSE(imageSignatureOk(QStringLiteral("image/webp"), jpg));
    EXPECT_FALSE(imageSignatureOk(QStringLiteral("text/html"), jpg));
    EXPECT_FALSE(imageSignatureOk(QStringLiteral("image/jpeg"), html));
    EXPECT_FALSE(imageSignatureOk(QStringLiteral("image/svg+xml"), html));
    EXPECT_FALSE(imageSignatureOk(QStringLiteral("image/gif"), QByteArray("GIF89a")));
    EXPECT_FALSE(imageSignatureOk(QStringLiteral("image/jpeg"), QByteArray()));
}

TEST(CommonsFiles, OnlineFolderNames)
{
    EXPECT_TRUE(commons::outDirAllowed(QStringLiteral("/home/u/.cache/grassfield/wallpapers/online/commons")));
    EXPECT_TRUE(commons::outDirAllowed(QStringLiteral("/repo/.dev/cache/wallpapers/online/commons")));
    for (const char *no : {"", "relative/grassfield/wallpapers/online/commons", "/home/u/grassfield/wallpapers/online", "/home/u/grassfield/wallpapers/commons", "/home/u/other/wallpapers/online/commons", "/home/u/grassfield/wallpapers/online/commons/..", "/home/u/../grassfield/wallpapers/online/commons", "/grassfield/wallpapers/online/apod", "/home/u/grassfield/wallpapers/prepared"})
        EXPECT_FALSE(commons::outDirAllowed(QString::fromLatin1(no))) << no;
    EXPECT_TRUE(isOnlineCacheName(QStringLiteral("2026-10-22.jpg")));
    EXPECT_TRUE(isOnlineCacheName(QStringLiteral("2026-10-22.json")));
    for (const char *no : {"2026-13-22.jpg", "2026-10-22.png", "x2026-10-22.jpg", "2026-10-22.jpg.part", ".dl-1-a.part", "latest.json", "../2026-10-22.jpg"})
        EXPECT_FALSE(isOnlineCacheName(QString::fromLatin1(no))) << no;
    EXPECT_TRUE(validDate(QStringLiteral("2026-10-22")));
    for (const char *no : {"2026-02-30", "2026-1-2", "26-10-22", "2026-10-22x", "", "1999-01-01", "2026/10/22", "2026-10-22\n"})
        EXPECT_FALSE(validDate(QString::fromLatin1(no))) << no;
}

TEST(CommonsCurl, ArgumentVectorCarriesTheAdrFlags)
{
    const QUrl url(QStringLiteral("https://commons.wikimedia.org/w/api.php?action=query"));
    const QStringList a = curlArgs(url, QStringLiteral("/tmp/x.part"), kMaxImageBytes, QString());
    EXPECT_EQ(a.first(), QStringLiteral("-q"));
    auto value = [&](const char *flag) { const int i = a.indexOf(QString::fromLatin1(flag)); return i >= 0 && i + 1 < a.size() ? a[i + 1] : QString(); };
    EXPECT_EQ(value("--proto"), QStringLiteral("=https"));
    EXPECT_EQ(value("--proto-redir"), QStringLiteral("=https"));
    EXPECT_EQ(value("--max-redirs"), QStringLiteral("3"));
    EXPECT_EQ(value("--connect-timeout"), QStringLiteral("10"));
    EXPECT_EQ(value("--max-time"), QStringLiteral("60"));
    EXPECT_EQ(value("--max-filesize"), QString::number(kMaxImageBytes));
    EXPECT_EQ(value("--user-agent"), userAgent());
    EXPECT_EQ(value("--url"), QStringLiteral("https://commons.wikimedia.org/w/api.php?action=query"));
    EXPECT_EQ(a.last(), QStringLiteral("https://commons.wikimedia.org/w/api.php?action=query"));
    for (const char *never : {"--location", "-L", "--cookie", "-b", "--cookie-jar", "-c", "--referer", "-e", "--netrc", "-n", "--compressed", "--insecure", "-k", "--proxy", "-x", "--noproxy"})
        EXPECT_FALSE(a.contains(QString::fromLatin1(never))) << never;
    EXPECT_FALSE(a.contains(QStringLiteral("--noproxy")));
    // Loopback: http only, and never through a proxy.
    const QStringList l = curlArgs(QUrl(QStringLiteral("http://127.0.0.1:9/x")), QStringLiteral("/tmp/x"), kMaxJsonBytes, QStringLiteral("http://127.0.0.1:9"));
    const int p = l.indexOf(QStringLiteral("--proto"));
    EXPECT_EQ(l[p + 1], QStringLiteral("=http"));
    EXPECT_TRUE(l.contains(QStringLiteral("--noproxy")));
    // The User-Agent is the product and its contact, nothing of this machine.
    // (Audit W1: the build's version, and the project's repository as the contact, not a person's address.)
    EXPECT_EQ(userAgent(), QStringLiteral("Grassfield/" GRASSFIELD_VERSION " (https://github.com/grassfieldhq/grassfield)"));
    EXPECT_FALSE(userAgent().contains(QLatin1Char('@')));
    EXPECT_FALSE(userAgent().contains(QDir::homePath()));
}

TEST(CommonsParse, ImageInfoOfTheRealShape)
{
    const QByteArray json = readFile(fixtureDir() + QStringLiteral("/imageinfo.json")).replace("@BASE@", "https://thumb.wikimedia.org");
    Parsed p;
    QString why;
    ASSERT_EQ(parseImageInfo(json, QStringLiteral("Example_lake_at_dawn.jpg"), QString(), &p, &why), Ok) << why.toStdString();
    EXPECT_EQ(p.title, QStringLiteral("Example lake at dawn"));
    EXPECT_EQ(p.author, QStringLiteral("Jane & John Doe"));
    EXPECT_EQ(p.credit, QStringLiteral("Own work"));
    EXPECT_EQ(p.licenseShort, QStringLiteral("CC BY-SA 4.0"));
    EXPECT_EQ(p.licenseUrl, QStringLiteral("https://creativecommons.org/licenses/by-sa/4.0"));
    EXPECT_EQ(p.sourceUrl, QStringLiteral("https://commons.wikimedia.org/wiki/File%3AExample_lake_at_dawn.jpg"));
    EXPECT_EQ(p.thumbUrl.toString(), QStringLiteral("https://thumb.wikimedia.org/thumb/picture.jpg"));
    EXPECT_TRUE(p.thumbUrl.query().isEmpty());
}

TEST(CommonsParse, RefusalsAreSkipsOrBadResponses)
{
    const QByteArray good = readFile(fixtureDir() + QStringLiteral("/imageinfo.json")).replace("@BASE@", "https://thumb.wikimedia.org");
    auto code = [&](const QByteArray &json) {
        Parsed p;
        QString why;
        return parseImageInfo(json, QStringLiteral("x.jpg"), QString(), &p, &why);
    };
    EXPECT_EQ(code(QByteArray(good).replace("cc-by-sa-4.0", "cc-by-nc-4.0")), Skipped);
    EXPECT_EQ(code(QByteArray(good).replace("cc-by-sa-4.0", "gfdl")), Skipped);
    EXPECT_EQ(code(QByteArray(good).replace("\"mime\":\"image/jpeg\"", "\"mime\":\"video/webm\"")), Skipped);
    // A licence field that is missing or not a string is not an allowed licence.
    EXPECT_EQ(code(QByteArray(good).replace("\"License\":{\"value\":\"cc-by-sa-4.0\"", "\"License\":{\"value\":[\"cc-by-sa-4.0\"]")), Skipped);
    EXPECT_EQ(code(QByteArray(good).replace("\"License\"", "\"Licence\"")), Skipped);
    // A picture host that is not on the list is refused whatever the licence (the NASA logo of the APOD API, for one).
    EXPECT_EQ(code(QByteArray(good).replace("https://thumb.wikimedia.org/thumb/picture.jpg", "https://science.nasa.gov/wp-content/nasa-logo.png")), BadResponse);
    EXPECT_EQ(code(QByteArray(good).replace("https://thumb.wikimedia.org/thumb/picture.jpg", "http://thumb.wikimedia.org/thumb/picture.jpg")), BadResponse);
    EXPECT_EQ(code(QByteArray("[]")), BadResponse);
    EXPECT_EQ(code(QByteArray("not json")), BadResponse);
    EXPECT_EQ(code(QByteArray("{\"query\":{\"pages\":[{\"title\":\"File:x\",\"missing\":true}]}}")), Skipped);
    EXPECT_EQ(code(QByteArray("{\"query\":{\"pages\":[]}}")), BadResponse);
    // The legacy answer shape (pages as an object) is read too.
    QJsonObject doc = QJsonDocument::fromJson(good).object();
    QJsonObject query = doc.value(QStringLiteral("query")).toObject();
    QJsonObject pages;
    pages.insert(QStringLiteral("1234567"), query.value(QStringLiteral("pages")).toArray().at(0));
    query.insert(QStringLiteral("pages"), pages);
    doc.insert(QStringLiteral("query"), query);
    EXPECT_EQ(code(QJsonDocument(doc).toJson()), Ok);
}

TEST(CommonsParse, ExpandTemplatesAnswers)
{
    EXPECT_EQ(parseFileName(QByteArray("{\"expandtemplates\":{\"wikitext\":\"A_b.jpg\"}}")), QStringLiteral("A_b.jpg"));
    EXPECT_EQ(parseFileName(QByteArray("{\"expandtemplates\":{\"*\":\"A_b.jpg\"}}")), QStringLiteral("A_b.jpg"));
    EXPECT_EQ(parseFileName(QByteArray("{\"expandtemplates\":{\"wikitext\":\"[[:Template:Potd/2099-01-01]]\"}}")), QString());
    EXPECT_EQ(parseFileName(QByteArray("{\"error\":{}}")), QString());
    EXPECT_EQ(parseCaption(readFile(fixtureDir() + QStringLiteral("/expand-caption-fr.json"))), QStringLiteral("Un lac calme près de Lyon à l'aube."));
}

TEST(CommonsCache, PruneKeepsFourteenDaysAndTheLimit)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QByteArray pad(1000, 'x');
    for (int day = 1; day <= 28; ++day) {
        const QString d = QStringLiteral("2026-10-%1").arg(day, 2, 10, QLatin1Char('0'));
        writeFile(tmp.filePath(d + QStringLiteral(".jpg")), pad);
        writeFile(tmp.filePath(d + QStringLiteral(".json")), QByteArray("{}"));
    }
    writeFile(tmp.filePath(QStringLiteral("notes.txt")), pad);
    writeFile(tmp.filePath(QStringLiteral("2026-10-03.png")), pad);
    // Older than an hour: an interrupted download, removed. Younger: another run, left alone.
    writeFile(tmp.filePath(QStringLiteral(".dl-1-a.part")), pad);
    writeFile(tmp.filePath(QStringLiteral(".dl-2-a.part")), pad);
    QFile old(tmp.filePath(QStringLiteral(".dl-1-a.part")));
    ASSERT_TRUE(old.open(QIODevice::ReadWrite));
    ASSERT_TRUE(old.setFileTime(QDateTime::currentDateTime().addSecs(-7200), QFileDevice::FileModificationTime));
    old.close();
    pruneOnline(tmp.path(), QStringLiteral("2026-10-28"), 14, kKeepBytes);
    EXPECT_FALSE(QFileInfo::exists(tmp.filePath(QStringLiteral("2026-10-14.jpg")))) << "14 days before the newest goes";
    EXPECT_TRUE(QFileInfo::exists(tmp.filePath(QStringLiteral("2026-10-15.jpg"))));
    EXPECT_TRUE(QFileInfo::exists(tmp.filePath(QStringLiteral("2026-10-15.json"))));
    EXPECT_TRUE(QFileInfo::exists(tmp.filePath(QStringLiteral("2026-10-28.jpg"))));
    EXPECT_TRUE(QFileInfo::exists(tmp.filePath(QStringLiteral("notes.txt")))) << "not the helper's own name";
    EXPECT_TRUE(QFileInfo::exists(tmp.filePath(QStringLiteral("2026-10-03.png")))) << "not the helper's own name";
    EXPECT_FALSE(QFileInfo::exists(tmp.filePath(QStringLiteral(".dl-1-a.part"))));
    EXPECT_TRUE(QFileInfo::exists(tmp.filePath(QStringLiteral(".dl-2-a.part"))));
    // The size limit drops the oldest dates, never the newest.
    pruneOnline(tmp.path(), QStringLiteral("2026-10-28"), 14, 5 * 1002);
    EXPECT_TRUE(QFileInfo::exists(tmp.filePath(QStringLiteral("2026-10-28.jpg"))));
    EXPECT_TRUE(QFileInfo::exists(tmp.filePath(QStringLiteral("2026-10-24.jpg"))));
    EXPECT_FALSE(QFileInfo::exists(tmp.filePath(QStringLiteral("2026-10-23.jpg"))));
    // With a limit below one entry the newest still stays.
    pruneOnline(tmp.path(), QStringLiteral("2026-10-28"), 14, 1);
    EXPECT_TRUE(QFileInfo::exists(tmp.filePath(QStringLiteral("2026-10-28.jpg"))));
    EXPECT_TRUE(QFileInfo::exists(tmp.filePath(QStringLiteral("2026-10-28.json"))));
    EXPECT_FALSE(QFileInfo::exists(tmp.filePath(QStringLiteral("2026-10-27.jpg"))));
}

// ------------------------------------------------------- the loopback server

class CommonsFetch : public ::testing::Test {
protected:
    void SetUp() override
    {
        ASSERT_TRUE(work.isValid());
        fixtures = work.filePath(QStringLiteral("served"));
        ASSERT_TRUE(QDir().mkpath(fixtures));
        for (const char *name : {"expand-file.json", "expand-caption-en.json", "expand-caption-fr.json", "imageinfo.json"})
            ASSERT_TRUE(QFile::copy(fixtureDir() + QLatin1Char('/') + QString::fromLatin1(name), fixtures + QLatin1Char('/') + QString::fromLatin1(name))) << name;
        ASSERT_TRUE(saveJpeg(fixtures + QStringLiteral("/picture.jpg"), gradient(1600, 1000)));
        server.setProgram(QStringLiteral("python3"));
        server.setArguments({QStringLiteral("-I"), fixtureDir() + QStringLiteral("/server.py"), QStringLiteral("--dir"), fixtures});
        server.setProcessChannelMode(QProcess::SeparateChannels);
        server.start();
        ASSERT_TRUE(server.waitForStarted(5000));
        ASSERT_TRUE(server.waitForReadyRead(10000));
        const QByteArray line = server.readLine();
        ASSERT_TRUE(line.startsWith("PORT ")) << line.toStdString();
        base = QStringLiteral("http://127.0.0.1:") + QString::fromLatin1(line.mid(5).trimmed());
        out = work.filePath(QStringLiteral("cache/wallpapers/online/commons"));
        opts.date = QStringLiteral("2026-10-20");
        opts.out = out;
        opts.baseUrl = base;
        opts.dev = true;
        opts.curl = QStringLiteral("/usr/bin/curl");
    }

    void TearDown() override
    {
        server.terminate();
        server.waitForFinished(3000);
    }

    QStringList requests() const
    {
        return QString::fromUtf8(readFile(fixtures + QStringLiteral("/requests.log"))).split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    }

    void mode(const char *m) { writeFile(fixtures + QStringLiteral("/mode"), QByteArray(m)); }

    QStringList online() const { return QDir(out).entryList(QDir::Files | QDir::Hidden | QDir::NoDotAndDotDot, QDir::Name); }

    QTemporaryDir work;
    QProcess server;
    QString fixtures, base, out;
    Options opts;
};

TEST_F(CommonsFetch, FetchesPreparesAndWritesTheSidecar)
{
    QJsonObject r;
    QString why;
    ASSERT_EQ(fetchCommons(opts, &r, &why), Ok) << why.toStdString();
    EXPECT_FALSE(r.value(QStringLiteral("cached")).toBool());
    EXPECT_EQ(r.value(QStringLiteral("date")).toString(), QStringLiteral("2026-10-20"));
    EXPECT_EQ(r.value(QStringLiteral("file")).toString(), out + QStringLiteral("/2026-10-20.jpg"));
    EXPECT_EQ(r.value(QStringLiteral("title")).toString(), QStringLiteral("Example lake at dawn"));
    EXPECT_EQ(r.value(QStringLiteral("author")).toString(), QStringLiteral("Jane & John Doe"));
    EXPECT_EQ(r.value(QStringLiteral("licenseShort")).toString(), QStringLiteral("CC BY-SA 4.0"));
    EXPECT_EQ(r.value(QStringLiteral("licenseUrl")).toString(), QStringLiteral("https://creativecommons.org/licenses/by-sa/4.0"));
    EXPECT_EQ(r.value(QStringLiteral("caption")).toString(), QStringLiteral("A calm lake near the city at dawn."));
    EXPECT_EQ(r.value(QStringLiteral("sourceUrl")).toString(), base + QStringLiteral("/wiki/File%3AExample_lake_at_dawn.jpg"));
    // The picture is a re-encoded JPEG (the generated 1600x1000), and nothing else is left behind.
    const QImage img(out + QStringLiteral("/2026-10-20.jpg"));
    EXPECT_EQ(img.size(), QSize(1600, 1000));
    EXPECT_EQ(online(), (QStringList{QStringLiteral("2026-10-20.jpg"), QStringLiteral("2026-10-20.json")}));
    // The sidecar on disk is the sanitized one, and it round-trips through `latest`.
    const QJsonObject side = QJsonDocument::fromJson(readFile(out + QStringLiteral("/2026-10-20.json"))).object();
    EXPECT_EQ(side.value(QStringLiteral("provider")).toString(), QStringLiteral("commons"));
    EXPECT_EQ(side.value(QStringLiteral("width")).toInt(), 1600);
    const QJsonObject l = latestCached(out);
    EXPECT_TRUE(l.value(QStringLiteral("found")).toBool());
    EXPECT_EQ(l.value(QStringLiteral("title")).toString(), QStringLiteral("Example lake at dawn"));
    // Modes: the folder 0700, the files 0600.
    struct stat st;
    ASSERT_EQ(::stat(QFile::encodeName(out).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 0777, mode_t(0700));
    ASSERT_EQ(::stat(QFile::encodeName(out + QStringLiteral("/2026-10-20.jpg")).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 0777, mode_t(0600));
    ASSERT_EQ(::stat(QFile::encodeName(out + QStringLiteral("/2026-10-20.json")).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 0777, mode_t(0600));
}

TEST_F(CommonsFetch, RequestsAreTheTwoApiCallsAndTheBareThumbnail)
{
    QJsonObject r;
    QString why;
    ASSERT_EQ(fetchCommons(opts, &r, &why), Ok) << why.toStdString();
    const QStringList log = requests();
    ASSERT_EQ(log.size(), 4) << log.join('\n').toStdString();
    EXPECT_TRUE(log[0].contains(QStringLiteral("action=expandtemplates")));
    EXPECT_TRUE(log[0].contains(QStringLiteral("%7B%7BPotd%2F2026-10-20%7D%7D")));
    EXPECT_TRUE(log[1].contains(QStringLiteral("Potd%2F2026-10-20%20%28en%29")));
    EXPECT_TRUE(log[2].contains(QStringLiteral("action=query")));
    EXPECT_TRUE(log[2].contains(QStringLiteral("iiprop=url%7Csize%7Cmime%7Csha1%7Cextmetadata")));
    EXPECT_TRUE(log[2].contains(QStringLiteral("iiurlwidth=3840")));
    EXPECT_TRUE(log[2].contains(QStringLiteral("titles=File%3AExample_lake_at_dawn.jpg")));
    // The thumbnail without its utm_* query string.
    EXPECT_TRUE(log[3].startsWith(QStringLiteral("/thumb/picture.jpg | ")));
    EXPECT_FALSE(log[3].contains(QStringLiteral("utm_")));
    // Every request: the fixed User-Agent, no Referer, no cookie.
    for (const QString &line : log) {
        EXPECT_TRUE(line.contains(QStringLiteral("| ua=") + userAgent() + QStringLiteral(" |"))) << line.toStdString();
        EXPECT_TRUE(line.contains(QStringLiteral("| referer= |"))) << line.toStdString();
        EXPECT_TRUE(line.endsWith(QStringLiteral("| cookie="))) << line.toStdString();
    }
}

TEST_F(CommonsFetch, FrenchCaptionAndWidthAreAsked)
{
    opts.lang = QStringLiteral("fr");
    opts.width = 1920;
    QJsonObject r;
    QString why;
    ASSERT_EQ(fetchCommons(opts, &r, &why), Ok) << why.toStdString();
    EXPECT_EQ(r.value(QStringLiteral("caption")).toString(), QStringLiteral("Un lac calme près de Lyon à l'aube."));
    EXPECT_TRUE(requests()[2].contains(QStringLiteral("iiurlwidth=1920")));
}

TEST_F(CommonsFetch, ADayAlreadyCachedMakesNoRequest)
{
    QJsonObject r;
    QString why;
    ASSERT_EQ(fetchCommons(opts, &r, &why), Ok);
    const int before = requests().size();
    QJsonObject again;
    ASSERT_EQ(fetchCommons(opts, &again, &why), Ok);
    EXPECT_TRUE(again.value(QStringLiteral("cached")).toBool());
    EXPECT_EQ(again.value(QStringLiteral("title")).toString(), QStringLiteral("Example lake at dawn"));
    EXPECT_EQ(requests().size(), before);
}

TEST_F(CommonsFetch, AServerErrorFailsAndLeavesTheCacheAlone)
{
    QJsonObject first;
    QString why;
    opts.date = QStringLiteral("2026-10-19");
    ASSERT_EQ(fetchCommons(opts, &first, &why), Ok);
    mode("fail");
    opts.date = QStringLiteral("2026-10-20");
    QJsonObject r;
    EXPECT_EQ(fetchCommons(opts, &r, &why), Network);
    EXPECT_FALSE(why.isEmpty());
    EXPECT_EQ(online(), (QStringList{QStringLiteral("2026-10-19.jpg"), QStringLiteral("2026-10-19.json")}));
    // `latest` still names the previous picture.
    EXPECT_EQ(latestCached(out).value(QStringLiteral("date")).toString(), QStringLiteral("2026-10-19"));
}

TEST_F(CommonsFetch, ARedirectToAnotherHostIsNeverFollowed)
{
    mode("evil-redirect");
    QJsonObject r;
    QString why;
    EXPECT_EQ(fetchCommons(opts, &r, &why), Network);
    EXPECT_EQ(why, QStringLiteral("host not allowed"));
    EXPECT_TRUE(online().isEmpty());
}

TEST_F(CommonsFetch, AThumbnailHostOutsideTheAllowListIsRefusedBeforeAnyRequestToIt)
{
    QByteArray info = readFile(fixtures + QStringLiteral("/imageinfo.json"));
    info.replace("@BASE@/thumb/picture.jpg", "https://science.nasa.gov/wp-content/nasa-logo.png");
    writeFile(fixtures + QStringLiteral("/imageinfo.json"), info);
    QJsonObject r;
    QString why;
    EXPECT_EQ(fetchCommons(opts, &r, &why), BadResponse);
    EXPECT_EQ(why, QStringLiteral("thumbnail host not allowed"));
    EXPECT_EQ(requests().size(), 3); // no fourth request
    EXPECT_TRUE(online().isEmpty());
}

TEST_F(CommonsFetch, ALicenceOutsideTheListSkipsTheDay)
{
    QByteArray info = readFile(fixtures + QStringLiteral("/imageinfo.json"));
    info.replace("cc-by-sa-4.0", "cc-by-nc-4.0");
    writeFile(fixtures + QStringLiteral("/imageinfo.json"), info);
    QJsonObject r;
    QString why;
    EXPECT_EQ(fetchCommons(opts, &r, &why), Skipped);
    EXPECT_EQ(why, QStringLiteral("licence not allowed"));
    EXPECT_EQ(requests().size(), 3);
    EXPECT_TRUE(online().isEmpty());
}

TEST_F(CommonsFetch, AWrongContentTypeOrWrongBytesAreRefused)
{
    mode("html-picture");
    QJsonObject r;
    QString why;
    EXPECT_EQ(fetchCommons(opts, &r, &why), Skipped);
    EXPECT_TRUE(online().isEmpty());
    mode("");
    // A PNG served as image/jpeg: the signature does not match the type.
    QImage png(64, 64, QImage::Format_RGB32);
    png.fill(Qt::red);
    ASSERT_TRUE(png.save(fixtures + QStringLiteral("/picture.jpg"), "PNG"));
    EXPECT_EQ(fetchCommons(opts, &r, &why), Skipped);
    EXPECT_TRUE(online().isEmpty());
    // Text served as image/jpeg.
    writeFile(fixtures + QStringLiteral("/picture.jpg"), QByteArray("<html>not a picture</html>"));
    EXPECT_EQ(fetchCommons(opts, &r, &why), Skipped);
    EXPECT_TRUE(online().isEmpty());
}

TEST_F(CommonsFetch, ATruncatedPictureIsRefused)
{
    QByteArray jpg = readFile(fixtures + QStringLiteral("/picture.jpg"));
    jpg.truncate(jpg.size() / 2);
    writeFile(fixtures + QStringLiteral("/picture.jpg"), jpg);
    QJsonObject r;
    QString why;
    EXPECT_EQ(fetchCommons(opts, &r, &why), Unreadable);
    EXPECT_TRUE(online().isEmpty());
}

TEST_F(CommonsFetch, ATooLargePictureIsRefusedByTheHeader)
{
    // A real PNG (right type, right signature) that is 17000 pixels wide: over the 16384 side limit of the step 1 loader.
    QImage wide(17000, 16, QImage::Format_Mono);
    wide.fill(0);
    ASSERT_TRUE(wide.save(fixtures + QStringLiteral("/big.png"), "PNG"));
    QByteArray info = readFile(fixtures + QStringLiteral("/imageinfo.json"));
    info.replace("/thumb/picture.jpg", "/thumb/big.png");
    writeFile(fixtures + QStringLiteral("/imageinfo.json"), info);
    QJsonObject r;
    QString why;
    EXPECT_EQ(fetchCommons(opts, &r, &why), TooLargePicture);
    EXPECT_TRUE(online().isEmpty());
}

TEST_F(CommonsFetch, AnOversizedJsonAnswerIsRefused)
{
    mode("big-json");
    QJsonObject r;
    QString why;
    EXPECT_EQ(fetchCommons(opts, &r, &why), BadResponse);
    EXPECT_TRUE(online().isEmpty());
}

TEST_F(CommonsFetch, NoEntryForTheDayIsASkip)
{
    writeFile(fixtures + QStringLiteral("/expand-file.json"), QByteArray("{\"expandtemplates\":{\"wikitext\":\"[[:Template:Potd/2026-10-20]]\"}}"));
    QJsonObject r;
    QString why;
    EXPECT_EQ(fetchCommons(opts, &r, &why), Skipped);
    EXPECT_EQ(requests().size(), 1);
}

TEST_F(CommonsFetch, AMissingCurlIsANetworkFailure)
{
    opts.curl = QStringLiteral("/nonexistent/curl");
    QJsonObject r;
    QString why;
    EXPECT_EQ(fetchCommons(opts, &r, &why), Network);
    EXPECT_EQ(why, QStringLiteral("curl cannot start"));
}

TEST_F(CommonsFetch, ABaseUrlOutsideADevSessionIsRefused)
{
    opts.dev = false;
    QJsonObject r;
    QString why;
    EXPECT_EQ(fetchCommons(opts, &r, &why), Usage);
    EXPECT_TRUE(requests().isEmpty());
    opts.dev = true;
    opts.baseUrl = QStringLiteral("http://localhost:1");
    EXPECT_EQ(fetchCommons(opts, &r, &why), Usage);
}

// ------------------------------------------------------- NASA APOD (ADR-0016 step 2, the second provider)

TEST(ApodRules, HostsAreNasaOnlyAndProviderBound)
{
    const QString none;
    EXPECT_TRUE(hostAllowedFor(QStringLiteral("apod"), QUrl(QStringLiteral("https://api.nasa.gov/planetary/apod")), none));
    EXPECT_TRUE(hostAllowedFor(QStringLiteral("apod"), QUrl(QStringLiteral("https://apod.nasa.gov/apod/image/2610/a.jpg")), none));
    // The site that served the logo answers, other NASA hosts, Commons hosts and look-alikes are refused.
    for (const char *u : {"https://science.nasa.gov/x.jpg", "https://www.nasa.gov/x.jpg", "https://upload.wikimedia.org/x.jpg", "http://apod.nasa.gov/x.jpg", "https://apod.nasa.gov.evil.example/x.jpg", "https://apod.nasa.gov@evil.example/x.jpg", "https://apod.nasa.gov:8443/x.jpg"})
        EXPECT_FALSE(hostAllowedFor(QStringLiteral("apod"), QUrl(QString::fromLatin1(u)), none)) << u;
    EXPECT_FALSE(hostAllowedFor(QStringLiteral("commons"), QUrl(QStringLiteral("https://apod.nasa.gov/x.jpg")), none));
    EXPECT_FALSE(hostAllowedFor(QStringLiteral("nasa"), QUrl(QStringLiteral("https://apod.nasa.gov/x.jpg")), none));
    EXPECT_TRUE(outDirAllowedFor(QStringLiteral("apod"), QStringLiteral("/home/u/.cache/grassfield/wallpapers/online/apod")));
    EXPECT_FALSE(outDirAllowedFor(QStringLiteral("apod"), QStringLiteral("/home/u/.cache/grassfield/wallpapers/online/commons")));
    EXPECT_FALSE(commons::outDirAllowed(QStringLiteral("/home/u/.cache/grassfield/wallpapers/online/apod")));
}

TEST(ApodRules, TheRequestCarriesTheDemoKeyAndTheDate)
{
    const QUrl u = apodUrl(QString(), QStringLiteral("2026-10-20"));
    EXPECT_EQ(u.host(), QStringLiteral("api.nasa.gov"));
    EXPECT_EQ(u.path(), QStringLiteral("/planetary/apod"));
    EXPECT_TRUE(u.query().contains(QStringLiteral("api_key=DEMO_KEY")));
    EXPECT_TRUE(u.query().contains(QStringLiteral("date=2026-10-20")));
    // The curl vector for it: https only, no cookie, no referer.
    const QStringList a = curlArgs(u, QStringLiteral("/tmp/x"), 1000, QString());
    EXPECT_EQ(a[a.indexOf(QStringLiteral("--proto")) + 1], QStringLiteral("=https"));
    EXPECT_FALSE(a.contains(QStringLiteral("--cookie")));
    EXPECT_FALSE(a.contains(QStringLiteral("--referer")));
}

TEST(ApodRules, ParsesARealShapeAndKeepsTheCopyrightHolder)
{
    const QString b = QStringLiteral("http://127.0.0.1:1");
    auto answer = [&](const QByteArray &fields) { return QByteArray("{\"date\":\"2026-10-20\",\"media_type\":\"image\",\"title\":\"T\",") + fields + "}"; };
    Parsed p;
    QString caption, why;
    ASSERT_EQ(parseApod(answer("\"url\":\"http://127.0.0.1:1/apod/image/2610/a.jpg?x=1\",\"explanation\":\"<b>Words</b> here\",\"copyright\":\" Jane\\n Doe \""), QStringLiteral("2026-10-20"), b, &p, &caption, &why), Ok) << why.toStdString();
    EXPECT_EQ(p.thumbUrl.toString(), QStringLiteral("http://127.0.0.1:1/apod/image/2610/a.jpg"));
    EXPECT_EQ(p.author, QStringLiteral("Jane Doe"));
    EXPECT_EQ(p.licenseShort, QStringLiteral("© Jane Doe"));
    EXPECT_EQ(caption, QStringLiteral("Words here"));
    EXPECT_EQ(p.sourceUrl, QStringLiteral("http://127.0.0.1:1/apod/ap261020.html"));
    // No copyright field: public, no holder.
    ASSERT_EQ(parseApod(answer("\"url\":\"http://127.0.0.1:1/apod/image/a.jpg\""), QStringLiteral("2026-10-20"), b, &p, &caption, &why), Ok);
    EXPECT_TRUE(p.author.isEmpty());
    EXPECT_EQ(p.licenseShort, QStringLiteral("Public domain (NASA)"));
    // An http address of apod.nasa.gov is upgraded to https; without a base URL nothing else is accepted.
    ASSERT_EQ(parseApod(answer("\"url\":\"http://apod.nasa.gov/apod/image/2610/a.jpg\""), QStringLiteral("2026-10-20"), QString(), &p, &caption, &why), Ok);
    EXPECT_EQ(p.thumbUrl.toString(), QStringLiteral("https://apod.nasa.gov/apod/image/2610/a.jpg"));
    EXPECT_EQ(p.sourceUrl, QStringLiteral("https://apod.nasa.gov/apod/ap261020.html"));
}

TEST(ApodRules, RefusesLogosVideosForeignHostsAndWrongDates)
{
    auto parse = [&](const QByteArray &json, const QString &date = QStringLiteral("2026-10-20")) {
        Parsed p;
        QString caption, why;
        return parseApod(json, date, QString(), &p, &caption, &why);
    };
    // The NASA logo of the broken answers (ADR-0016 step 2 verification): refused, never shown.
    EXPECT_EQ(parse(R"({"date":"2026-10-20","media_type":"image","title":"NASA Science","url":"https://science.nasa.gov/wp-content/themes/nasa-science/assets/images/nasa-logo@2x.png","hdurl":"https://science.nasa.gov/wp-content/themes/nasa-science/assets/images/nasa-logo@2x.png"})"), Skipped);
    // apod.nasa.gov but outside /apod/image/, another host, a traversal.
    EXPECT_EQ(parse(R"({"date":"2026-10-20","media_type":"image","title":"T","url":"https://apod.nasa.gov/logo.png"})"), Skipped);
    EXPECT_EQ(parse(R"({"date":"2026-10-20","media_type":"image","title":"T","url":"https://evil.example/apod/image/a.jpg"})"), Skipped);
    EXPECT_EQ(parse(R"({"date":"2026-10-20","media_type":"image","title":"T","url":"https://apod.nasa.gov/apod/image/../../x.jpg"})"), Skipped);
    // A bad hdurl falls back to a good url.
    EXPECT_EQ(parse(R"({"date":"2026-10-20","media_type":"image","title":"T","url":"https://apod.nasa.gov/apod/image/a.jpg","hdurl":"https://science.nasa.gov/x.png"})"), Ok);
    EXPECT_EQ(parse(R"({"date":"2026-10-20","media_type":"video","title":"T","url":"https://www.youtube.com/embed/x"})"), Skipped);
    EXPECT_EQ(parse(R"({"date":"2026-10-20","media_type":"other","title":"T"})"), Skipped);
    EXPECT_EQ(parse(R"({"date":"2026-10-19","media_type":"image","title":"T","url":"https://apod.nasa.gov/apod/image/a.jpg"})"), BadResponse);
    EXPECT_EQ(parse("not json"), BadResponse);
    EXPECT_EQ(parse(R"({"date":"2026-10-20","media_type":"image","title":"","url":"https://apod.nasa.gov/apod/image/a.jpg"})"), Skipped);
}

class ApodFetch : public CommonsFetch {
protected:
    void SetUp() override
    {
        CommonsFetch::SetUp();
        for (const char *name : {"apod.json", "apod-2026-10-21.json", "apod-2026-10-22.json", "apod-2026-10-23.json"})
            ASSERT_TRUE(QFile::copy(fixtureDir() + QLatin1Char('/') + QString::fromLatin1(name), fixtures + QLatin1Char('/') + QString::fromLatin1(name))) << name;
        opts.provider = QStringLiteral("apod");
        out = work.filePath(QStringLiteral("cache/wallpapers/online/apod"));
        opts.out = out;
    }
};

TEST_F(ApodFetch, FetchesAPublicEntryAndKeepsItsMeanColour)
{
    QJsonObject r;
    QString why;
    ASSERT_EQ(fetchApod(opts, &r, &why), Ok) << why.toStdString();
    EXPECT_EQ(r.value(QStringLiteral("provider")).toString(), QStringLiteral("apod"));
    EXPECT_EQ(r.value(QStringLiteral("title")).toString(), QStringLiteral("Gradient Over Stars"));
    EXPECT_EQ(r.value(QStringLiteral("licenseShort")).toString(), QStringLiteral("Public domain (NASA)"));
    EXPECT_EQ(r.value(QStringLiteral("sourceUrl")).toString(), base + QStringLiteral("/apod/ap261020.html"));
    EXPECT_TRUE(r.value(QStringLiteral("mean")).toString().startsWith(QLatin1Char('#')));
    EXPECT_EQ(QImage(out + QStringLiteral("/2026-10-20.jpg")).size(), QSize(1600, 1000));
    EXPECT_EQ(online(), (QStringList{QStringLiteral("2026-10-20.jpg"), QStringLiteral("2026-10-20.json")}));
    // Two requests: the API (with the demo key) and the bare picture; the fixed agent, no referer, no cookie.
    const QStringList log = requests();
    ASSERT_EQ(log.size(), 2) << log.join('\n').toStdString();
    EXPECT_TRUE(log[0].startsWith(QStringLiteral("/planetary/apod?api_key=DEMO_KEY&date=2026-10-20")));
    EXPECT_TRUE(log[1].startsWith(QStringLiteral("/apod/image/2610/picture.jpg | ")));
    for (const QString &line : log) {
        EXPECT_TRUE(line.contains(QStringLiteral("| ua=") + userAgent() + QStringLiteral(" |"))) << line.toStdString();
        EXPECT_TRUE(line.contains(QStringLiteral("| referer= |")));
        EXPECT_TRUE(line.endsWith(QStringLiteral("| cookie=")));
    }
    // A day already cached makes no request; `latest apod` reads it, `latest commons` of the same folder does not.
    QJsonObject again;
    ASSERT_EQ(fetchApod(opts, &again, &why), Ok);
    EXPECT_TRUE(again.value(QStringLiteral("cached")).toBool());
    EXPECT_EQ(requests().size(), 2);
    EXPECT_TRUE(latestCached(out, QString(), QStringLiteral("apod")).value(QStringLiteral("found")).toBool());
    EXPECT_FALSE(latestCached(out).value(QStringLiteral("found")).toBool());
}

TEST_F(ApodFetch, ACopyrightedEntryIsShownWithItsCredit)
{
    opts.date = QStringLiteral("2026-10-21");
    QJsonObject r;
    QString why;
    ASSERT_EQ(fetchApod(opts, &r, &why), Ok) << why.toStdString();
    EXPECT_EQ(r.value(QStringLiteral("author")).toString(), QStringLiteral("Jane Q. Public"));
    EXPECT_EQ(r.value(QStringLiteral("credit")).toString(), QStringLiteral("Jane Q. Public"));
    EXPECT_EQ(r.value(QStringLiteral("licenseShort")).toString(), QStringLiteral("© Jane Q. Public"));
}

TEST_F(ApodFetch, AVideoDayAndTheLogoAnswerAreSkippedWithoutAPictureRequest)
{
    for (const char *date : {"2026-10-22", "2026-10-23"}) {
        opts.date = QString::fromLatin1(date);
        QJsonObject r;
        QString why;
        EXPECT_EQ(fetchApod(opts, &r, &why), Skipped) << date << " " << why.toStdString();
    }
    for (const QString &line : requests())
        EXPECT_TRUE(line.startsWith(QStringLiteral("/planetary/apod"))) << "only the API was asked: " << line.toStdString();
    EXPECT_TRUE(online().isEmpty());
}

TEST_F(ApodFetch, AnAnswerForAnotherDateIsABadResponseAndAServerErrorIsANetworkFailure)
{
    opts.date = QStringLiteral("2026-10-19"); // the generic fixture answers 2026-10-20
    QJsonObject r;
    QString why;
    EXPECT_EQ(fetchApod(opts, &r, &why), BadResponse);
    mode("fail");
    opts.date = QStringLiteral("2026-10-20");
    EXPECT_EQ(fetchApod(opts, &r, &why), Network);
}

TEST_F(ApodFetch, TheBaseUrlIsDevOnlyAndTheFolderIsTheProvidersOwn)
{
    opts.dev = false;
    QJsonObject r;
    QString why;
    EXPECT_EQ(fetchApod(opts, &r, &why), Usage);
    opts.dev = true;
    opts.out = work.filePath(QStringLiteral("cache/wallpapers/online/commons"));
    EXPECT_EQ(fetchApod(opts, &r, &why), Usage);
    EXPECT_TRUE(requests().isEmpty());
}

TEST_F(ApodFetch, ARedirectToAnotherPageOfAnAllowedHostIsRefusedAtEveryHop)
{
    mode("apod-path-redirect");
    QJsonObject r;
    QString why;
    EXPECT_EQ(fetchApod(opts, &r, &why), Network);
    EXPECT_EQ(why, QStringLiteral("host not allowed"));
    for (const QString &line : requests())
        EXPECT_FALSE(line.startsWith(QStringLiteral("/thumb/"))) << "the redirect target was requested: " << line.toStdString();
    EXPECT_TRUE(online().isEmpty());
}
