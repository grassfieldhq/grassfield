#include "previewlogic.h"

#include "filelogic.h"

#include <QCollator>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QLocale>
#include <QMimeDatabase>
#include <QRegularExpression>
#include <QImageReader>
#include <QSettings>
#include <QTextBlock>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextFragment>
#include <QTextImageFormat>
#include <QUrl>
#include <QtMath>

#include <algorithm>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace preview {

QString textSnippetOf(const QString &path, qint64 maxSize)
{
    const int fd = ::open(QFile::encodeName(path).constData(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return {};
    struct stat st;
    if (::fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size > maxSize) {
        ::close(fd);
        return {};
    }
    QFile file;
    if (!file.open(fd, QIODevice::ReadOnly, QFileDevice::AutoCloseHandle)) {
        ::close(fd);
        return {};
    }
    const QString head = QString::fromUtf8(file.read(2048));
    QStringList lines;
    for (const QString &raw : head.split(QLatin1Char('\n'))) {
        QString line = raw.left(40);
        for (QChar &c : line) {
            if (c.unicode() < 0x20)
                c = QLatin1Char(' ');
        }
        lines << line;
        if (lines.size() >= 12)
            break;
    }
    const QString out = lines.join(QLatin1Char('\n'));
    return out.trimmed().isEmpty() ? QString() : out;
}

QString localPathFromArgument(const QString &arg, const QString &cwd, QString *error)
{
    const auto fail = [error](const QString &message) {
        if (error)
            *error = message;
        return QString();
    };
    if (arg.trimmed().isEmpty())
        return fail(QStringLiteral("empty argument"));
    // Something that looks like "scheme:" and is not an existing relative file name is a URL.
    static const QRegularExpression scheme(QStringLiteral("^[A-Za-z][A-Za-z0-9+.-]+:"));
    const bool urlLike = scheme.match(arg).hasMatch() && !QFileInfo::exists(QDir(cwd).absoluteFilePath(arg));
    if (urlLike) {
        const QUrl url(arg, QUrl::StrictMode);
        if (!url.isValid() || url.scheme().toLower() != QLatin1String("file"))
            return fail(QStringLiteral("only local files are supported: %1").arg(arg));
        if (!url.host().isEmpty() && url.host() != QLatin1String("localhost"))
            return fail(QStringLiteral("remote file hosts are not supported: %1").arg(arg));
        if (url.hasQuery() || url.hasFragment())
            return fail(QStringLiteral("not a plain file URL: %1").arg(arg));
        const QString local = url.host().isEmpty() ? url.toLocalFile() : url.path();
        return local.isEmpty() ? fail(QStringLiteral("not a local file: %1").arg(arg)) : QDir::cleanPath(local);
    }
    return QDir::cleanPath(QDir(cwd).absoluteFilePath(arg));
}

// Playlist formats can reference network URLs: they are shown as text, never handed to the player and
// never followed or fetched. Decided from the file's start (extensionless files), the canonical MIME
// type, its aliases and parents, and the suffix.
static bool looksLikePlaylist(const QString &path)
{
    QFile file(path);
    if (!QFileInfo(path).isFile() || !file.open(QIODevice::ReadOnly))
        return false;
    QByteArray head = file.read(512);
    // UTF-8 BOM, then leading white space.
    if (head.startsWith("\xEF\xBB\xBF"))
        head.remove(0, 3);
    head = head.trimmed().toLower();
    if (head.startsWith("#extm3u") || head.startsWith("[playlist]") || head.startsWith("<asx") || head.startsWith("<?wpl")
        || head.startsWith("ffconcat")) // FFmpeg's concat script ("ffconcat version 1.0"): a list of files to play
        return true;
    // XML playlists (ASX with a declaration, WPL, XSPF, a DASH manifest): the root element follows the declaration.
    if (head.startsWith("<?xml") || head.startsWith("<")) {
        static const QByteArrayList roots = {"<asx", "<smil", "<playlist", "<mpd"};
        for (const QByteArray &root : roots)
            if (head.contains(root))
                return true;
    }
    return false;
}

static bool isPlaylist(const QMimeType &mime, const QString &path)
{
    static const QStringList playlistTypes = {
        QStringLiteral("audio/x-mpegurl"), QStringLiteral("audio/mpegurl"), QStringLiteral("application/vnd.apple.mpegurl"),
        QStringLiteral("application/x-mpegurl"), QStringLiteral("application/mpegurl"), QStringLiteral("video/vnd.mpegurl"),
        QStringLiteral("audio/x-scpls"), QStringLiteral("audio/scpls"), QStringLiteral("application/pls"),
        QStringLiteral("application/xspf+xml"), QStringLiteral("application/x-xspf+xml"),
        QStringLiteral("application/vnd.apple.mpegurl.audio"), QStringLiteral("application/vnd.ms-wpl"),
        QStringLiteral("application/x-ms-asx"), QStringLiteral("audio/x-ms-asx"),
        QStringLiteral("video/x-ms-wax"), QStringLiteral("video/x-ms-wmx"), QStringLiteral("video/x-ms-wvx"),
        QStringLiteral("application/smil"), QStringLiteral("application/smil+xml")};
    // Suffixes decide where the MIME type is a media container (a real .asf stays a video).
    static const QStringList playlistSuffixes = {QStringLiteral("m3u"), QStringLiteral("m3u8"), QStringLiteral("pls"),
                                                 QStringLiteral("vlc"), QStringLiteral("xspf"), QStringLiteral("asx"),
                                                 QStringLiteral("wax"), QStringLiteral("wvx"), QStringLiteral("wmx"),
                                                 QStringLiteral("wpl")};
    QStringList names = mime.aliases();
    names << mime.name() << mime.allAncestors();
    for (const QString &n : names)
        if (playlistTypes.contains(n))
            return true;
    if (playlistSuffixes.contains(QFileInfo(path).suffix().toLower()))
        return true;
    return looksLikePlaylist(path);
}

Kind classify(const QString &path)
{
    const QMimeDatabase db;
    const QMimeType mime = db.mimeTypeForFile(path, QMimeDatabase::MatchDefault);
    const QString name = mime.name();
    if (name == QLatin1String("application/pdf"))
        return Kind::Pdf;
    if (isPlaylist(mime, path))
        return Kind::Text;
    if (name.startsWith(QLatin1String("image/")))
        return Kind::Image;
    if (name.startsWith(QLatin1String("video/")))
        return Kind::Video;
    if (name.startsWith(QLatin1String("audio/")))
        return Kind::Audio;
    // Ogg is audio for the player whatever the sniffed container says.
    if (name == QLatin1String("application/ogg"))
        return Kind::Audio;
    if (mime.inherits(QStringLiteral("text/plain")) || name.startsWith(QLatin1String("text/")))
        return Kind::Text;
    return Kind::Unsupported;
}

bool isMarkdown(const QString &path)
{
    const QMimeType mime = QMimeDatabase().mimeTypeForFile(path, QMimeDatabase::MatchDefault);
    return mime.name() == QLatin1String("text/markdown") || mime.inherits(QStringLiteral("text/markdown"));
}

QString markdownImagePath(const QString &target, const QString &baseDir, QSize *size)
{
    const QString t = target.trimmed();
    if (t.isEmpty() || baseDir.isEmpty())
        return {};
    QString local;
    static const QRegularExpression scheme(QStringLiteral("^[A-Za-z][A-Za-z0-9+.-]*:"));
    if (scheme.match(t).hasMatch()) {
        // Only a local file: URL (empty host or localhost); http, https, data:, ftp... are never fetched.
        const QUrl url(t, QUrl::StrictMode);
        if (!url.isValid() || url.scheme().toLower() != QLatin1String("file") || url.hasQuery() || url.hasFragment()
            || !(url.host().isEmpty() || url.host() == QLatin1String("localhost")))
            return {};
        local = url.path();
    } else {
        // A path as Markdown writes it: relative to the document's folder, a query or fragment after it ("?raw=true") left
        // out, then percent-decoded ("my%20picture.png"; "%23" is a '#' of the name).
        static const QRegularExpression tail(QStringLiteral("[?#].*$"));
        QString raw = t;
        raw.remove(tail);
        local = QUrl::fromPercentEncoding(raw.toUtf8());
        if (local.isEmpty())
            return {};
        local = QDir(baseDir).absoluteFilePath(local);
    }
    if (local.isEmpty())
        return {};
    const QFileInfo info(QDir::cleanPath(local));
    const QString canonical = info.canonicalFilePath();
    // isFile() follows symlinks and refuses directories, devices, FIFOs and sockets.
    if (canonical.isEmpty() || isSystemPath(canonical) || !info.isFile() || !info.isReadable() || classify(canonical) != Kind::Image
        || vectorTooLarge(canonical, info.size()))
        return {};
    QImageReader reader(canonical);
    reader.setAutoTransform(true);
    if (!reader.canRead())
        return {};
    QSize s = reader.size();
    if (s.isValid() && (reader.transformation() & QImageIOHandler::TransformationRotate90))
        s.transpose();
    if (!imageSizeAllowed(s))
        return {};
    if (size)
        *size = s;
    return canonical;
}

QString markdownHtml(const QString &markdown, const MarkdownImageResolver &image)
{
    QTextDocument doc;
    doc.setMarkdown(markdown, QTextDocument::MarkdownFeatures(QTextDocument::MarkdownDialectGitHub | QTextDocument::MarkdownNoHTML));
    // Collected first, applied after the walk (a change while the fragments are walked would invalidate them): pictures get
    // their URL and size or become their alternative text, links lose their own colour.
    struct Change {
        int position = 0;
        int length = 0;
        QTextCharFormat format;
        QString text; // set: the fragment becomes this text (a picture that is not shown)
        bool replace = false;
    };
    QList<Change> changes;
    int asked = 0;
    qint64 spent = 0; // bytes of served pixels shown so far
    for (QTextBlock block = doc.begin(); block.isValid(); block = block.next()) {
        for (QTextBlock::iterator it = block.begin(); !it.atEnd(); ++it) {
            const QTextFragment fragment = it.fragment();
            if (!fragment.isValid())
                continue;
            QTextCharFormat format = fragment.charFormat();
            if (format.isImageFormat()) {
                QTextImageFormat picture = format.toImageFormat();
                QSize size;
                QString id = asked < kMaxMarkdownImages && image ? image(picture.name(), &size) : QString();
                ++asked;
                const QSize served = size.isValid() ? markdownServedSize(size) : QSize();
                const qint64 cost = qint64(served.width()) * served.height() * 4;
                if (!id.isEmpty() && served.isValid() && spent + cost <= kMarkdownImageBudgetBytes)
                    spent += cost;
                else
                    id.clear();
                Change c;
                c.position = fragment.position();
                c.length = fragment.length();
                if (!id.isEmpty()) {
                    picture.setName(QStringLiteral("image://preview/fit/%1x%2/%3").arg(served.width()).arg(served.height()).arg(id));
                    picture.setWidth(served.width());
                    picture.setHeight(served.height());
                    picture.setProperty(QTextFormat::ImageTitle, QVariant());
                    c.format = picture;
                } else {
                    QTextCharFormat plain = format;
                    plain.setObjectType(QTextFormat::NoObject);
                    plain.clearProperty(QTextFormat::ImageName);
                    plain.clearProperty(QTextFormat::ImageWidth);
                    plain.clearProperty(QTextFormat::ImageHeight);
                    plain.clearProperty(QTextFormat::ImageTitle);
                    plain.clearProperty(QTextFormat::ImageAltText);
                    c.format = plain;
                    c.text = format.property(QTextFormat::ImageAltText).toString();
                    c.replace = true;
                }
                changes.append(c);
            } else if (format.isAnchor() && format.hasProperty(QTextFormat::ForegroundBrush)) {
                format.clearForeground();
                changes.append({fragment.position(), fragment.length(), format, {}, false});
            }
        }
    }
    // From the end: a replaced picture changes the positions after it only.
    for (auto it = changes.crbegin(); it != changes.crend(); ++it) {
        QTextCursor cursor(&doc);
        cursor.setPosition(it->position);
        cursor.setPosition(it->position + it->length, QTextCursor::KeepAnchor);
        if (it->replace)
            cursor.insertText(it->text, it->format);
        else
            cursor.setCharFormat(it->format);
    }
    QString html = doc.toHtml();
    // The document's default font is the toolkit's: the view's own font (family, size, zoom) must apply instead.
    static const QRegularExpression body(QStringLiteral("<body style=\"[^\"]*\">"));
    html.replace(body, QStringLiteral("<body>"));
    return html;
}

QSize markdownServedSize(const QSize &natural)
{
    if (natural.width() <= 0 || natural.height() <= 0)
        return {};
    if (natural.width() <= kMarkdownImageMaxSide && natural.height() <= kMarkdownImageMaxSide)
        return natural;
    const QSize s = natural.scaled(kMarkdownImageMaxSide, kMarkdownImageMaxSide, Qt::KeepAspectRatio);
    return QSize(qMax(1, s.width()), qMax(1, s.height()));
}

int fitMarkdownImages(QTextDocument *document, qreal maxWidth)
{
    if (!document || maxWidth <= 0)
        return 0;
    // The view is read only: nothing to undo, and every resize would otherwise add an undo step (re-review 2026-11-22).
    document->setUndoRedoEnabled(false);
    static const QRegularExpression served(QStringLiteral("^image://preview/fit/(\\d+)x(\\d+)/"));
    struct Change {
        int position;
        int length;
        QTextImageFormat format;
    };
    QList<Change> changes;
    for (QTextBlock block = document->begin(); block.isValid(); block = block.next()) {
        for (QTextBlock::iterator it = block.begin(); !it.atEnd(); ++it) {
            const QTextFragment fragment = it.fragment();
            if (!fragment.isValid() || !fragment.charFormat().isImageFormat())
                continue;
            QTextImageFormat picture = fragment.charFormat().toImageFormat();
            const QRegularExpressionMatch m = served.match(picture.name());
            if (!m.hasMatch())
                continue;
            const qreal w = m.captured(1).toDouble();
            const qreal h = m.captured(2).toDouble();
            if (w <= 0 || h <= 0)
                continue;
            const qreal width = qMin<qreal>(w, qFloor(maxWidth));
            const qreal height = qMax<qreal>(1, qRound(h * width / w));
            if (qAbs(picture.width() - width) < 0.5 && qAbs(picture.height() - height) < 0.5)
                continue;
            picture.setWidth(width);
            picture.setHeight(height);
            changes.append({fragment.position(), fragment.length(), picture});
        }
    }
    for (const Change &c : changes) {
        QTextCursor cursor(document);
        cursor.setPosition(c.position);
        cursor.setPosition(c.position + c.length, QTextCursor::KeepAnchor);
        cursor.setCharFormat(c.format);
    }
    return int(changes.size());
}

QString kindName(Kind kind)
{
    switch (kind) {
    case Kind::Image: return QStringLiteral("image");
    case Kind::Pdf: return QStringLiteral("pdf");
    case Kind::Text: return QStringLiteral("text");
    case Kind::Audio: return QStringLiteral("audio");
    case Kind::Video: return QStringLiteral("video");
    case Kind::Unsupported: break;
    }
    return QStringLiteral("unsupported");
}

bool imageSizeAllowed(const QSize &size)
{
    if (size.width() <= 0 || size.height() <= 0)
        return false;
    if (size.width() > kMaxImageSide || size.height() > kMaxImageSide)
        return false;
    return qint64(size.width()) * size.height() * 4 <= kMaxImageBytes;
}

QSize pngSize(const QByteArray &head)
{
    static const char signature[] = "\x89PNG\r\n\x1a\n";
    // 8 bytes signature, 4 length, "IHDR", 4 width, 4 height.
    if (head.size() < 24 || !head.startsWith(QByteArray(signature, 8)) || head.mid(12, 4) != "IHDR")
        return {};
    const auto be32 = [&head](int offset) {
        const auto *p = reinterpret_cast<const uchar *>(head.constData()) + offset;
        return (quint32(p[0]) << 24) | (quint32(p[1]) << 16) | (quint32(p[2]) << 8) | quint32(p[3]);
    };
    const quint32 w = be32(16);
    const quint32 h = be32(20);
    if (w == 0 || h == 0 || w > 0x7FFFFFFF || h > 0x7FFFFFFF)
        return {};
    return QSize(int(w), int(h));
}

bool textSizeAllowed(qint64 bytes)
{
    return bytes >= 0 && bytes <= kMaxTextBytes;
}

bool looksBinary(const QByteArray &sample)
{
    return sample.contains('\0');
}

bool isSystemPath(const QString &canonical)
{
    for (const char *root : {"/proc", "/sys", "/dev"}) {
        const QString r = QString::fromLatin1(root);
        if (canonical == r || canonical.startsWith(r + QLatin1Char('/')))
            return true;
    }
    return false;
}

// The tools' options follow Omarchy 4.0.6 (basecamp/omarchy@237f1b4, MIT, Copyright (c) David Heinemeier Hansson; pinned in
// docs/upstream/omarchy.lock): omarchy-capture-text's tesseract `--oem 1 --dpi 300`, omarchy-capture-qr's zbarimg
// `-q -Sdisable -Sqrcode.enable` reading standard input (QR only: other symbologies false-positive on screen content).
Recognition recognitionCommand(const QString &tool, const QString &languages)
{
    Recognition out;
    if (tool == QLatin1String("languages")) {
        out.program = QStringLiteral("tesseract");
        out.arguments = {QStringLiteral("--list-langs")};
    } else if (tool == QLatin1String("text")) {
        static const QRegularExpression names(QStringLiteral("^[A-Za-z0-9_]{1,32}(\\+[A-Za-z0-9_]{1,32}){0,3}$"));
        if (!names.match(languages).hasMatch())
            return {};
        out.program = QStringLiteral("tesseract");
        // `stdin stdout`: the image on the standard input, the answer on the standard output; `tsv` is tesseract's own
        // configuration file that writes the word boxes.
        out.arguments = {QStringLiteral("stdin"), QStringLiteral("stdout"), QStringLiteral("--oem"), QStringLiteral("1"),
                         QStringLiteral("--psm"), QStringLiteral("3"), QStringLiteral("--dpi"), QStringLiteral("300"),
                         QStringLiteral("-l"), languages, QStringLiteral("tsv")};
        out.image = true;
    } else if (tool == QLatin1String("qr")) {
        out.program = QStringLiteral("zbarimg");
        out.arguments = {QStringLiteral("-q"), QStringLiteral("-Sdisable"), QStringLiteral("-Sqrcode.enable"), QStringLiteral("-")};
        out.image = true;
    }
    return out;
}

bool isOpenableLink(const QString &link)
{
    if (link.isEmpty() || link.size() > 2048 || link.startsWith(QLatin1Char('-')))
        return false;
    for (const QChar c : link) {
        if (c.isSpace() || c.category() == QChar::Other_Control || c.category() == QChar::Other_Format)
            return false;
    }
    const QUrl url(link, QUrl::StrictMode);
    return url.isValid() && (url.scheme() == QLatin1String("http") || url.scheme() == QLatin1String("https")) && !url.host().isEmpty()
        && url.userInfo().isEmpty();
}

Arguments resolveArguments(const QStringList &args, const QString &cwd)
{
    Arguments out;
    for (const QString &arg : args) {
        QString why;
        const QString path = localPathFromArgument(arg, cwd, &why);
        if (path.isEmpty()) {
            out.errors << why;
            continue;
        }
        const QFileInfo info(path);
        if (isSystemPath(info.canonicalFilePath())) {
            out.errors << QStringLiteral("not a user file: %1").arg(path);
            continue;
        }
        if (!info.isFile()) { // follows symlinks; rejects directories, devices, FIFOs, sockets
            out.errors << QStringLiteral("not a regular file: %1").arg(path);
            continue;
        }
        if (out.paths.contains(path))
            continue;
        if (out.paths.size() >= kMaxFiles) {
            out.errors << QStringLiteral("too many files (limit %1)").arg(kMaxFiles);
            break;
        }
        out.paths << path;
    }
    return out;
}

// Quick, name-based test (no file contents are read for the other files of a folder).
static bool wantedByName(const QFileInfo &info, BrowseKinds kinds)
{
    const QMimeDatabase db;
    const QMimeType mime = db.mimeTypeForFile(info, QMimeDatabase::MatchExtension);
    const QString name = mime.name();
    if (name.startsWith(QLatin1String("image/")))
        return true;
    if (kinds == BrowseKinds::ImagesOnly)
        return false;
    return name == QLatin1String("application/pdf") || name.startsWith(QLatin1String("video/")) || name.startsWith(QLatin1String("audio/"))
        || name == QLatin1String("application/ogg") || name.startsWith(QLatin1String("text/")) || mime.inherits(QStringLiteral("text/plain"));
}

Browse browseFolder(const QString &path, BrowseKinds kinds, const SortSpec &sort, const std::atomic_bool *cancel)
{
    Browse out;
    out.paths << path;
    const QFileInfo self(path);
    if (!self.isFile())
        return out;
    const QString selfPath = self.absoluteFilePath();
    QLocale locale;
    if (locale.language() == QLocale::C)
        locale = QLocale(QLocale::English, QLocale::UnitedStates);
    QCollator collator(locale);
    collator.setNumericMode(true);
    collator.setCaseSensitivity(Qt::CaseInsensitive);

    struct Item {
        QString path;
        FileLogic::SortEntry entry;
    };
    const QMimeDatabase db;
    const auto makeItem = [&db](const QFileInfo &info) {
        FileLogic::SortEntry e;
        e.name = info.fileName();
        e.kind = db.mimeTypeForFile(info, QMimeDatabase::MatchExtension).comment();
        e.modified = info.lastModified();
        e.size = info.size();
        return Item{info.absoluteFilePath(), e};
    };
    // The opened file is always part of the list at its sorted position, hidden or unreadable or not (an unreadable one
    // shows its error in place); the other files must be regular (symlinks followed), readable, visible and of a wanted kind.
    QList<Item> items;
    items.append(makeItem(self));
    // A folder of tens of thousands of files is not browsed whole: the first entries are enough for a window.
    constexpr int kMaxScanned = 20000;
    QDirIterator it(self.absolutePath(), QDir::Files | QDir::NoDotAndDotDot);
    while (it.hasNext() && items.size() < kMaxScanned) {
        if (cancel && cancel->load(std::memory_order_relaxed))
            return out;
        it.next();
        const QFileInfo info = it.fileInfo();
        if (info.absoluteFilePath() == selfPath || info.fileName().startsWith(QLatin1Char('.')) || !wantedByName(info, kinds) || !info.isReadable())
            continue;
        items.append(makeItem(info));
    }
    if (items.size() < 2)
        return out;
    const auto key = FileLogic::SortKey(qBound(0, sort.key, 3));
    std::stable_sort(items.begin(), items.end(), [&](const Item &a, const Item &b) {
        return FileLogic::compareEntries(a.entry, b.entry, key, sort.descending, sort.foldersFirst, collator) < 0;
    });
    int at = 0;
    for (int i = 0; i < items.size(); ++i)
        if (items.at(i).path == selfPath)
            at = i;
    int first = 0;
    int count = items.size();
    if (count > kMaxFiles) {
        first = qBound(0, at - kMaxFiles / 2, count - kMaxFiles);
        count = kMaxFiles;
    }
    out.paths.clear();
    for (int i = first; i < first + count; ++i)
        out.paths << items.at(i).path;
    out.index = at - first;
    // Keep the caller's spelling of the opened path (the caller already resolved it).
    out.paths[out.index] = path;
    return out;
}

SortSpec filesSortSpec()
{
    QSettings settings(QStringLiteral("Grassfield"), QStringLiteral("Files"));
    SortSpec spec;
    spec.key = qBound(0, settings.value(QStringLiteral("view/sortKey"), 0).toInt(), 3);
    spec.descending = settings.value(QStringLiteral("view/sortDescending"), false).toBool();
    spec.foldersFirst = settings.value(QStringLiteral("view/foldersFirst"), true).toBool();
    return spec;
}


bool vectorTooLarge(const QString &path, qint64 bytes)
{
    const QString suffix = QFileInfo(path).suffix().toLower();
    return (suffix == QLatin1String("svg") || suffix == QLatin1String("svgz")) && bytes > kMaxVectorBytes;
}

QStringList textChunks(const QString &text, int chars)
{
    QStringList out;
    qsizetype from = 0;
    while (from < text.size()) {
        qsizetype end = from + chars;
        if (end >= text.size()) {
            out.append(text.mid(from));
            break;
        }
        // At the end of the line the piece reaches (the newline stays with it); a line longer than the piece ends it.
        const qsizetype newline = text.indexOf(QLatin1Char('\n'), end - 1);
        end = newline < 0 ? text.size() : newline + 1;
        out.append(text.mid(from, end - from));
        from = end;
    }
    return out;
}

bool onBatteryIn(const QString &powerSupplyRoot)
{
    const auto read = [](const QString &file) {
        QFile f(file);
        return f.open(QIODevice::ReadOnly) ? QString::fromLatin1(f.read(64)).trimmed() : QString();
    };
    bool battery = false;
    const QStringList supplies = QDir(powerSupplyRoot).entryList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::System);
    for (const QString &name : supplies) {
        const QString dir = powerSupplyRoot + QLatin1Char('/') + name + QLatin1Char('/');
        const QString type = read(dir + QStringLiteral("type"));
        if (type == QLatin1String("Mains") || type.startsWith(QLatin1String("USB"))) {
            if (read(dir + QStringLiteral("online")) == QLatin1String("1"))
                return false;
        } else if (type == QLatin1String("Battery") && read(dir + QStringLiteral("scope")) != QLatin1String("Device")) {
            battery = true;
        }
    }
    return battery;
}

} // namespace preview
