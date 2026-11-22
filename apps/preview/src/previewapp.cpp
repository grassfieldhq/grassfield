#include "previewapp.h"

#include "previewlogic.h"
#include "appscope.h"
#include "runmode.h"
#include "chromecaps.h"
#include "autoappearance.h"

#include <QBuffer>
#include <QClipboard>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QMutexLocker>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QMimeData>
#include <QMimeDatabase>
#include <QPainter>
#include <QProcess>
#include <QStandardPaths>

#include <memory>

#include <sys/resource.h>

namespace {

QString configFile()
{
    return grassfield::apps::runmode::configDir() + QStringLiteral("/grassfield.json");
}

QString sizeText(qint64 bytes)
{
    return QLocale().formattedDataSize(bytes, 1, QLocale::DataSizeIecFormat);
}

// Size of the image as displayed (EXIF rotation by 90 degrees swaps the sides); invalid when unknown.
QSize displaySize(const QImageReader &reader)
{
    QSize size = reader.size();
    if (size.isValid() && (reader.transformation() & QImageIOHandler::TransformationRotate90))
        size.transpose();
    return size;
}

// The picture a recognition hands to its tool (preview::recognitionCommand): the first frame decoded by Qt with the caps of
// the viewer, EXIF orientation applied (the boxes are then in the pixels Preview shows), scaled down to
// preview::kRecognitionMaxSide, flattened on white (a transparent pixel's colour is often black, under black text), grey,
// as a binary PGM, which tesseract (leptonica) and zbarimg read on their standard input. Empty when it cannot be decoded.
QByteArray recognitionImage(const QString &path)
{
    QImageReader reader(path);
    reader.setAutoTransform(true);
    const QSize native = displaySize(reader);
    if (native.isValid() && !preview::imageSizeAllowed(native))
        return {};
    // Decoded at the tools' size where the format can (JPEG scales while decoding: a 48 MP photo costs a fraction of its
    // full decode, P5). The box is square: the rotation applied after it changes nothing.
    const QSize raw = reader.size();
    if (raw.isValid() && !reader.supportsAnimation()
        && (raw.width() > preview::kRecognitionMaxSide || raw.height() > preview::kRecognitionMaxSide))
        reader.setScaledSize(raw.scaled(preview::kRecognitionMaxSide, preview::kRecognitionMaxSide, Qt::KeepAspectRatio));
    QImage image = reader.read();
    if (image.isNull() || !preview::imageSizeAllowed(image.size()))
        return {};
    if (image.width() > preview::kRecognitionMaxSide || image.height() > preview::kRecognitionMaxSide)
        image = image.scaled(preview::kRecognitionMaxSide, preview::kRecognitionMaxSide, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    QImage flat(image.size(), QImage::Format_RGB32);
    flat.fill(Qt::white);
    {
        QPainter painter(&flat);
        painter.drawImage(0, 0, image);
    }
    QByteArray out;
    QBuffer buffer(&out);
    if (!buffer.open(QIODevice::WriteOnly) || !flat.convertToFormat(QImage::Format_Grayscale8).save(&buffer, "pgm"))
        return {};
    return out;
}

QVariantList filesFor(const QStringList &paths, const PreviewApp *app)
{
    QVariantList files;
    for (const QString &p : paths) {
        const QFileInfo info(p);
        files.append(QVariantMap{{QStringLiteral("path"), p},
                                 {QStringLiteral("name"), info.fileName()},
                                 {QStringLiteral("url"), QUrl::fromLocalFile(p)},
                                 {QStringLiteral("kind"), preview::kindName(preview::classify(p))},
                                 {QStringLiteral("token"), app->tokenFor(p)}});
    }
    return files;
}

} // namespace

PreviewApp::PreviewApp(const QStringList &paths, const QStringList &errors, bool glance, int startIndex, bool browsing, QObject *parent)
    : QObject(parent)
    , m_paths(paths)
    , m_errors(errors)
    , m_glance(glance)
    , m_browsing(browsing)
    , m_startIndex(qBound(0, startIndex, qMax(0, paths.size() - 1)))
{
    m_files = filesFor(paths, this);
    m_firstPath = paths.value(m_startIndex);
    m_inspectPool.setMaxThreadCount(1);
    m_snippetPool.setMaxThreadCount(1);
    readPower();
    // Appearance follows grassfield.json (read only), like every Grassfield surface.
    const QString file = configFile();
    const QString dir = QFileInfo(file).absolutePath();
    if (QFileInfo(dir).isDir())
        m_watcher.addPath(dir);
    if (QFileInfo::exists(file))
        m_watcher.addPath(file);
    // The shell's capabilities file (chromecaps.h, ADR-0015 Q4b) is watched the same way: it may not exist yet, so its directory too.
    const auto watchCapabilities = [this] {
        const QString caps = grassfield::apps::capabilitiesFile();
        if (caps.isEmpty())
            return;
        const QString capsDir = QFileInfo(caps).absolutePath();
        if (QFileInfo(capsDir).isDir() && !m_watcher.directories().contains(capsDir))
            m_watcher.addPath(capsDir);
        if (QFileInfo::exists(caps) && !m_watcher.files().contains(caps))
            m_watcher.addPath(caps);
    };
    watchCapabilities();
    const auto reread = [this, watchCapabilities] {
        const QString f = configFile();
        if (QFileInfo::exists(f) && !m_watcher.files().contains(f))
            m_watcher.addPath(f);
        watchCapabilities();
        readAppearance();
    };
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, reread);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, reread);
    readAppearance();
    // Auto appearance: the schedule is re-evaluated each minute while the setting is "auto".
    m_autoTimer.setInterval(grassfield::apps::kAutoRecheckMs);
    connect(&m_autoTimer, &QTimer::timeout, this, [this] {
        if (m_autoAppearance)
            readAppearance();
    });
    m_autoTimer.start();
}

PreviewApp::~PreviewApp()
{
    // The inspections and snippets still queued start nothing; the one running ends (its answer is dropped with this).
    m_inspectPool.clear();
    m_snippetPool.clear();
    m_inspectPool.waitForDone();
    m_snippetPool.waitForDone();
    cancelBrowse();
    // No recognition answers once the backend goes: the tools are killed, the decoders joined (each finishes its one image).
    m_decoding.clear();
    for (QProcess *process : std::as_const(m_tools)) {
        process->disconnect(this);
        process->kill();
        process->waitForFinished(1000);
        delete process;
    }
    m_tools.clear();
    for (QThread *decoder : std::as_const(m_decoders)) {
        decoder->wait();
        delete decoder;
    }
    m_decoders.clear();
}

QString PreviewApp::pathAt(int index) const
{
    const QMutexLocker lock(&m_lock);
    return index >= 0 && index < m_paths.size() ? m_paths.at(index) : QString();
}

int PreviewApp::tokenFor(const QString &path) const
{
    const QMutexLocker lock(&m_lock);
    const auto it = m_tokens.constFind(path);
    if (it != m_tokens.constEnd())
        return it.value();
    const int token = m_tokenPaths.size();
    m_tokenPaths.append(path);
    m_tokens.insert(path, token);
    return token;
}

QString PreviewApp::pathForToken(int token) const
{
    const QMutexLocker lock(&m_lock);
    return token >= 0 && token < m_tokenPaths.size() ? m_tokenPaths.at(token) : QString();
}

void PreviewApp::cancelBrowse()
{
    m_cancel = true;
    if (m_worker) {
        // The listing checks the flag per directory entry: this returns within moments.
        m_worker->wait();
        delete m_worker;
        m_worker = nullptr;
    }
}

void PreviewApp::startBrowse(preview::BrowseKinds kinds)
{
    if (m_worker || m_paths.size() != 1)
        return;
    const QString path = m_paths.constFirst();
    m_listing = true;
    emit listingChanged();
    // Decided before the window closes: no result is applied after the application started to quit.
    connect(qApp, &QCoreApplication::aboutToQuit, this, &PreviewApp::cancelBrowse, Qt::DirectConnection);
    m_worker = QThread::create([this, path, kinds] {
        const preview::Browse browse = preview::browseFolder(path, kinds, preview::filesSortSpec(), &m_cancel);
        // The per-file kind (content sniffing) is also off the GUI thread.
        const QVariantList files = m_cancel ? QVariantList() : filesFor(browse.paths, this);
        if (!m_cancel)
            QMetaObject::invokeMethod(this, [this, browse, files] { applyBrowse(browse, files); }, Qt::QueuedConnection);
    });
    m_worker->start();
}

void PreviewApp::applyBrowse(const preview::Browse &browse, const QVariantList &files)
{
    m_listing = false;
    if (browse.paths.size() > 1) {
        {
            const QMutexLocker lock(&m_lock);
            m_paths = browse.paths;
        }
        m_files = files;
        m_startIndex = browse.index;
        emit filesChanged();
    }
    emit listingChanged();
}

void PreviewApp::readAppearance()
{
    bool dark = true;
    bool reduce = false;
    bool contrast = false;
    qreal scale = 1;
    QString accent = QStringLiteral("multicolor");
    QString highlight = QStringLiteral("automatic");
    QString doubleClick = QStringLiteral("zoom");
    QString shortcutSetting;
    bool selectText = true;
    QFile f(configFile());
    if (f.open(QIODevice::ReadOnly) && f.size() < 1024 * 1024) {
        const QJsonObject root = QJsonDocument::fromJson(f.readAll()).object();
        const QString setting = root.value(QStringLiteral("appearance")).toString();
        m_autoAppearance = setting == QLatin1String("auto");
        dark = grassfield::apps::isDarkAppearance(setting, QTime::currentTime());
        const QJsonObject a11y = root.value(QStringLiteral("accessibility")).toObject();
        reduce = a11y.value(QStringLiteral("reduceMotion")).toBool(false);
        contrast = a11y.value(QStringLiteral("increaseContrast")).toBool(false);
        scale = qBound(1.0, a11y.value(QStringLiteral("textSize")).toDouble(1), 1.3);
        // Same rule as the compositor plugin: anything but "minimize" and "none" is the default, "zoom".
        const QString d = root.value(QStringLiteral("windows")).toObject().value(QStringLiteral("titlebarDoubleClick")).toString();
        if (d == QLatin1String("minimize") || d == QLatin1String("none"))
            doubleClick = d;
        // Accent colour: same names as ui/Grassfield/Ui/Accent.js; anything else reads as the default.
        const QString a = root.value(QStringLiteral("accent")).toObject().value(QStringLiteral("color")).toString();
        if (QStringList{QStringLiteral("blue"), QStringLiteral("purple"), QStringLiteral("pink"), QStringLiteral("red"), QStringLiteral("orange"),
                        QStringLiteral("yellow"), QStringLiteral("green"), QStringLiteral("graphite")}.contains(a))
            accent = a;
        // Text highlight colour: "automatic" or one of the same names (ui/Grassfield/Ui/Accent.js highlight).
        const QString h = root.value(QStringLiteral("accent")).toObject().value(QStringLiteral("highlight")).toString();
        if (QStringList{QStringLiteral("blue"), QStringLiteral("purple"), QStringLiteral("pink"), QStringLiteral("red"), QStringLiteral("orange"),
                        QStringLiteral("yellow"), QStringLiteral("green"), QStringLiteral("graphite")}.contains(h))
            highlight = h;
        shortcutSetting = root.value(QStringLiteral("keyboard")).toObject().value(QStringLiteral("shortcutStyle")).toString();
        // Select Text in Images: only an explicit false turns it off (a missing or malformed value is the default, on).
        selectText = root.value(QStringLiteral("preview")).toObject().value(QStringLiteral("textInImages")).toBool(true);
    }
    const QString shortcuts = grassfield::apps::shortcutStyle(shortcutSetting, m_macDevice);
    const bool canMinimize = grassfield::apps::minimizeAvailableInFile();
    if (dark != m_dark || reduce != m_reduceMotion || contrast != m_increaseContrast || scale != m_textScale || accent != m_accentColor
        || highlight != m_accentHighlight || doubleClick != m_titlebarDoubleClick || canMinimize != m_canMinimize || shortcuts != m_shortcutStyle
        || selectText != m_textInImages) {
        m_textInImages = selectText;
        m_accentHighlight = highlight;
        m_shortcutStyle = shortcuts;
        m_canMinimize = canMinimize;
        m_titlebarDoubleClick = doubleClick;
        m_accentColor = accent;
        m_dark = dark;
        m_reduceMotion = reduce;
        m_increaseContrast = contrast;
        m_textScale = scale;
        emit appearanceChanged();
    }
}

QVariantMap PreviewApp::inspect(int index) const
{
    return inspectPath(pathAt(index));
}

int PreviewApp::requestInspect(int index)
{
    const int request = ++m_lastInspect;
    const QString path = pathAt(index);
    m_inspectPool.start([this, request, path] {
        if (request != m_lastInspect.load())
            return; // the arrow keys went on: a newer file is asked, this one is not read
        const QVariantMap info = inspectPath(path);
        QMetaObject::invokeMethod(this, [this, request, info] { emit inspected(request, info); }, Qt::QueuedConnection);
    });
    return request;
}

QString PreviewApp::snippetFor(int index)
{
    const QString path = pathAt(index);
    if (path.isEmpty())
        return {};
    const int token = tokenFor(path);
    const auto it = m_snippets.constFind(token);
    if (it != m_snippets.constEnd())
        return *it;
    if (!m_snippetsAsked.contains(token)) {
        m_snippetsAsked.insert(token);
        m_snippetPool.start([this, token, path] {
            const QString text = preview::classify(path) == preview::Kind::Text ? preview::textSnippetOf(path) : QString();
            QMetaObject::invokeMethod(this, [this, token, text] {
                m_snippets.insert(token, text);
                m_snippetsAsked.remove(token);
                emit snippetsChanged();
            }, Qt::QueuedConnection);
        });
    }
    return {};
}

QString PreviewApp::textSnippet(int index) const
{
    const QString path = pathAt(index);
    if (path.isEmpty() || preview::classify(path) != preview::Kind::Text)
        return {};
    return preview::textSnippetOf(path);
}

QVariantMap PreviewApp::inspectFirst() const
{
    return inspectPath(m_firstPath);
}

QVariantMap PreviewApp::inspectPath(const QString &path) const
{
    QVariantMap out{{QStringLiteral("ok"), false}};
    if (path.isEmpty()) {
        out[QStringLiteral("error")] = tr("There is no file to show.");
        return out;
    }
    const QFileInfo info(path);
    const preview::Kind kind = preview::classify(path);
    out[QStringLiteral("name")] = info.fileName();
    out[QStringLiteral("kind")] = preview::kindName(kind);
    out[QStringLiteral("url")] = QUrl::fromLocalFile(path);
    out[QStringLiteral("token")] = tokenFor(path);
    out[QStringLiteral("size")] = sizeText(info.size());
    out[QStringLiteral("frames")] = 1;
    out[QStringLiteral("animated")] = false;
    out[QStringLiteral("type")] = QMimeDatabase().mimeTypeForFile(path, QMimeDatabase::MatchExtension).comment();
    out[QStringLiteral("modified")] = QLocale().toString(info.lastModified(), QLocale::ShortFormat);
    out[QStringLiteral("folder")] = info.absolutePath();
    if (!info.isFile() || !info.isReadable()) {
        out[QStringLiteral("error")] = tr("This file cannot be read.");
        return out;
    }
    switch (kind) {
    case preview::Kind::Image: {
        // A vector picture's size is known only by parsing the whole document: a huge one is refused before (P4).
        if (preview::vectorTooLarge(path, info.size())) {
            out[QStringLiteral("error")] = tr("This file is too large to preview.");
            return out;
        }
        QImageReader reader(path);
        reader.setAutoTransform(true);
        if (!reader.canRead()) {
            out[QStringLiteral("error")] = tr("This image cannot be decoded.");
            return out;
        }
        QSize size = displaySize(reader);
        if (!size.isValid()) {
            // Decoders refuse images over the allocation limit before they report a size: say why for PNG.
            QFile head(path);
            const QSize sniffed = head.open(QIODevice::ReadOnly) ? preview::pngSize(head.read(32)) : QSize();
            if (sniffed.isValid() && !preview::imageSizeAllowed(sniffed))
                size = sniffed;
        }
        if (!size.isValid()) {
            // A few formats only know their size after decoding; the allocation limit still applies.
            const QImage probe = reader.read();
            if (probe.isNull()) {
                out[QStringLiteral("error")] = tr("This image cannot be decoded: %1").arg(reader.errorString());
                return out;
            }
            size = probe.size();
        }
        if (!preview::imageSizeAllowed(size)) {
            out[QStringLiteral("error")] = tr("This image is too large to preview (%1 × %2 pixels; limit %3 per side and %4 MB in memory).")
                                               .arg(size.width()).arg(size.height()).arg(preview::kMaxImageSide).arg(preview::kAllocationLimitMb);
            return out;
        }
        // QTiffHandler only knows the number of directories after the first query: ask twice.
        const int firstCount = reader.imageCount();
        const int frames = qMax(1, qMax(firstCount, reader.imageCount()));
        out[QStringLiteral("width")] = size.width();
        out[QStringLiteral("height")] = size.height();
        out[QStringLiteral("frames")] = frames;
        out[QStringLiteral("animated")] = frames > 1 && reader.supportsAnimation();
        out[QStringLiteral("ok")] = true;
        return out;
    }
    case preview::Kind::Text: {
        if (!preview::textSizeAllowed(info.size())) {
            out[QStringLiteral("error")] = tr("This file is too large to preview (%1; limit %2).")
                                               .arg(sizeText(info.size()), sizeText(preview::kMaxTextBytes));
            return out;
        }
        QFile f(path);
        if (!f.open(QIODevice::ReadOnly)) {
            out[QStringLiteral("error")] = tr("This file cannot be read.");
            return out;
        }
        const QByteArray data = f.read(preview::kMaxTextBytes + 1);
        if (!preview::textSizeAllowed(data.size())) {
            out[QStringLiteral("error")] = tr("This file is too large to preview.");
            return out;
        }
        if (preview::looksBinary(data.left(8192))) {
            out[QStringLiteral("error")] = tr("This file is not text.");
            return out;
        }
        const QString text = QString::fromUtf8(data);
        out[QStringLiteral("text")] = text;
        // A Markdown document shows rendered (Quick Look), its pictures checked here and served by the image provider
        // under a token, like the files of the list; one past kMaxMarkdownChars shows its source.
        if (preview::isMarkdown(path)) {
            out[QStringLiteral("markdown")] = true;
            if (text.size() <= preview::kMaxMarkdownChars) {
                const QString folder = info.absolutePath();
                out[QStringLiteral("html")] = preview::markdownHtml(text, [this, &folder](const QString &target, QSize *size) {
                    const QString picture = preview::markdownImagePath(target, folder, size);
                    return picture.isEmpty() ? QString() : QStringLiteral("image://preview/0/%1").arg(tokenFor(picture));
                });
            }
        }
        // A long text in pieces of whole lines: the view lays out only those on screen (P7).
        if (text.size() > preview::kTextChunkChars)
            out[QStringLiteral("chunks")] = preview::textChunks(text, preview::kTextChunkChars);
        out[QStringLiteral("ok")] = true;
        return out;
    }
    case preview::Kind::Pdf:
    case preview::Kind::Audio:
    case preview::Kind::Video:
        out[QStringLiteral("ok")] = true;
        return out;
    case preview::Kind::Unsupported:
        break;
    }
    out[QStringLiteral("error")] = tr("There is no preview for this kind of file.");
    return out;
}

void PreviewApp::openInPreview(int current) const
{
    const QStringList paths = [this] {
        const QMutexLocker lock(&m_lock);
        return m_paths;
    }();
    if (paths.isEmpty())
        return;
    current = qBound(0, current, paths.size() - 1);
    // GRASSFIELD_PREVIEW_CMD (dev plumbing: honoured only in a dev session, runmode.h) may carry a --glance flag; the full
    // viewer never gets it.
    QStringList prefix = grassfield::apps::runmode::devValue("PREVIEW_CMD").split(QLatin1Char(' '), Qt::SkipEmptyParts);
    if (prefix.isEmpty())
        prefix << QCoreApplication::applicationFilePath();
    const QString program = prefix.takeFirst();
    prefix.removeAll(QStringLiteral("--glance"));
    // The folder of one file is browsed again by the viewer; several named files keep their order and the position.
    QStringList args = prefix;
    QStringList files;
    if (m_browsing) {
        files << paths.at(current);
    } else {
        files = paths;
        if (current > 0)
            args << QStringLiteral("--start") << QString::number(current);
    }
    grassfield::apps::startApplication(program, args + QStringList{QStringLiteral("--")} + files);
}

int PreviewApp::recognize(const QString &tool, int index, const QString &languages)
{
    const preview::Recognition command = preview::recognitionCommand(tool, languages);
    if (command.program.isEmpty())
        return 0;
    // Looked up at use time (ADR-0045 OC-0.3): tesseract and zbar are Omarchy base packages, either may be removed.
    const QString program = QStandardPaths::findExecutable(command.program);
    if (program.isEmpty()) {
        if (!m_missingTools.contains(command.program)) {
            m_missingTools.insert(command.program);
            qInfo("grassfield-preview: %s is not installed: no %s in images", qPrintable(command.program),
                  command.program == QLatin1String("zbarimg") ? "QR codes" : "text selection");
        }
        return 0;
    }
    preview::Recognition found = command;
    found.program = program;
    if (!command.image) {
        const int request = ++m_lastRequest;
        startTool(request, tool, found, {});
        return request;
    }
    // Only an image of the list, as a regular local file (it may have changed since the list was made).
    const QString path = pathAt(index);
    const QFileInfo info(path);
    if (path.isEmpty() || !info.isAbsolute() || !info.isFile() || preview::isSystemPath(info.canonicalFilePath())
        || preview::classify(path) != preview::Kind::Image)
        return 0;
    readPower();
    const int request = ++m_lastRequest;
    m_decoding.insert(request);
    // One decode per image for both its recognitions (P5): a picture decoded already is handed out again, and a request
    // that comes while the decode runs waits for the same one.
    for (const auto &[decodedPath, image] : std::as_const(m_decodedImages)) {
        if (decodedPath != path)
            continue;
        QMetaObject::invokeMethod(this, [this, request, tool, found, image = image] {
            if (m_decoding.remove(request))
                startTool(request, tool, found, image);
        }, Qt::QueuedConnection);
        return request;
    }
    QList<Waiting> &waiting = m_waiting[path];
    waiting.append(Waiting{request, tool, found});
    if (waiting.size() > 1)
        return request;
    // Decoding a large photograph takes a moment: never on the GUI thread. The answer is applied there, unless the requests
    // were cancelled meanwhile (or the backend went: the destructor joins this thread first).
    ++m_recognitionDecodes;
    QThread *decoder = QThread::create([this, path] {
        const QByteArray image = recognitionImage(path);
        QMetaObject::invokeMethod(this, [this, path, image] { decoded(path, image); }, Qt::QueuedConnection);
    });
    m_decoders.append(decoder);
    connect(decoder, &QThread::finished, this, [this, decoder] {
        m_decoders.removeOne(decoder);
        decoder->deleteLater();
    });
    decoder->start(QThread::LowPriority);
    return request;
}

void PreviewApp::decoded(const QString &path, const QByteArray &image)
{
    const QList<Waiting> waiting = m_waiting.take(path);
    if (!image.isEmpty()) {
        // Kept for the image shown only (its other recognition, a second look): one picture.
        m_decodedImages = {qMakePair(path, image)};
    }
    for (const Waiting &w : waiting) {
        if (!m_decoding.remove(w.request))
            continue; // cancelled meanwhile
        if (image.isEmpty())
            emit recognized(w.request, w.tool, -1, QString());
        else
            startTool(w.request, w.tool, w.command, image);
    }
}

void PreviewApp::readPower()
{
    const bool battery = preview::onBatteryIn(QStringLiteral("/sys/class/power_supply"));
    if (battery != m_onBattery) {
        m_onBattery = battery;
        emit powerChanged();
    }
}

void PreviewApp::startTool(int request, const QString &tool, const preview::Recognition &command, const QByteArray &image)
{
    auto *process = new QProcess(this);
    m_tools.insert(request, process);
    process->setProgram(command.program);
    process->setArguments(command.arguments);
    // In the background for real (P5): the lowest CPU priority, and one OpenMP thread (tesseract otherwise takes every
    // core for one page while the viewer decodes the next picture).
    QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
    environment.insert(QStringLiteral("OMP_THREAD_LIMIT"), QStringLiteral("1"));
    process->setProcessEnvironment(environment);
    process->setChildProcessModifier([] { ::setpriority(PRIO_PROCESS, 0, 19); });
    process->setStandardErrorFile(QProcess::nullDevice());
    if (!command.image)
        process->setStandardInputFile(QProcess::nullDevice());
    auto output = std::make_shared<QByteArray>();
    // Answers once: the first of the end, a failure to start, the output cap and the timeout; the process is then dropped.
    const auto answer = [this, request, tool, process, output](int exitCode) {
        if (m_tools.value(request) != process)
            return;
        m_tools.remove(request);
        process->disconnect(this);
        if (process->state() != QProcess::NotRunning)
            process->kill();
        process->deleteLater();
        emit recognized(request, tool, exitCode, exitCode == -1 ? QString() : QString::fromUtf8(*output));
    };
    connect(process, &QProcess::readyReadStandardOutput, this, [process, output, answer] {
        *output += process->readAllStandardOutput();
        if (output->size() > preview::kRecognitionOutputMax)
            answer(-1);
    });
    connect(process, &QProcess::finished, this, [process, output, answer](int code, QProcess::ExitStatus status) {
        *output += process->readAllStandardOutput();
        answer(status == QProcess::NormalExit && output->size() <= preview::kRecognitionOutputMax ? code : -1);
    });
    connect(process, &QProcess::errorOccurred, this, [answer](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            answer(-1);
    });
    QTimer::singleShot(preview::kRecognitionTimeoutMs, process, [answer] { answer(-1); });
    process->start();
    // Unless it already failed to start (answered above): the picture, then the end of the input.
    if (command.image && m_tools.value(request) == process) {
        process->write(image);
        process->closeWriteChannel();
    }
}

void PreviewApp::cancelRecognition(int request)
{
    m_decoding.remove(request);
    QProcess *process = m_tools.take(request);
    if (!process)
        return;
    process->disconnect(this);
    process->kill();
    process->deleteLater();
}

// A concealed copy (a QR code's content) carries the password manager's secret marker, as Omarchy 4.0.6's omarchy-capture-qr
// copies with `wl-copy --sensitive` (pinned in docs/upstream/omarchy.lock): clipboard history does not record it.
void PreviewApp::copyText(const QString &text, bool concealed) const
{
    if (text.isEmpty())
        return;
    auto *data = new QMimeData;
    data->setText(text);
    if (concealed)
        data->setData(QStringLiteral("x-kde-passwordManagerHint"), QByteArrayLiteral("secret"));
    QGuiApplication::clipboard()->setMimeData(data);
}

bool PreviewApp::openLink(const QString &link) const
{
    if (!preview::isOpenableLink(link) || grassfield::apps::runmode::dev())
        return false;
    return grassfield::apps::startApplication(QStringLiteral("xdg-open"), {link});
}

PreviewImageProvider::PreviewImageProvider(const PreviewApp *app)
    : QQuickImageProvider(QQuickImageProvider::Image)
    , m_app(app)
{
}

QImage PreviewImageProvider::requestImage(const QString &id, QSize *size, const QSize &requestedSize)
{
    const int slash = id.indexOf(QLatin1Char('/'));
    const bool thumbnail = id.startsWith(QLatin1String("thumb/"));
    bool okFrame = false;
    bool okIndex = false;
    const int frame = thumbnail ? 0 : id.left(slash).toInt(&okFrame);
    // The last part is the file's token, not its place in the list: the folder listing moves the opened file to another
    // index, and the same file must keep the same URL (no second decode, no cached picture under another file's name).
    const int token = id.mid(slash + 1).toInt(&okIndex);
    if (slash < 0 || (!thumbnail && !okFrame) || !okIndex || frame < 0 || token < 0)
        return {};
    const QString path = m_app->pathForToken(token);
    if (path.isEmpty() || preview::vectorTooLarge(path, QFileInfo(path).size()))
        return {};
    QImageReader reader(path);
    reader.setAutoTransform(true);
    if (!reader.canRead() || (frame > 0 && !reader.jumpToImage(frame)))
        return {};
    const QSize native = displaySize(reader);
    if (native.isValid() && !preview::imageSizeAllowed(native))
        return {};
    // A thumbnail is decoded at its size where the format can (JPEG scales while decoding): a folder of large photos
    // stays cheap. The scaled size is for the stored (not yet rotated) image; the rotation keeps the aspect ratio.
    if (thumbnail && requestedSize.isValid() && !reader.supportsAnimation()) {
        const QSize raw = reader.size();
        if (raw.isValid() && (raw.width() > requestedSize.width() || raw.height() > requestedSize.height())) {
            const bool turned = reader.transformation() & QImageIOHandler::TransformationRotate90;
            QSize box = requestedSize;
            if (turned)
                box.transpose();
            reader.setScaledSize(raw.scaled(box, Qt::KeepAspectRatio));
        }
    }
    QImage image = reader.read();
    if (image.isNull() || !preview::imageSizeAllowed(image.size()))
        return {};
    if (size)
        *size = thumbnail && native.isValid() ? native : image.size();
    if (requestedSize.isValid() && (requestedSize.width() < image.width() || requestedSize.height() < image.height()))
        image = image.scaled(requestedSize, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    return image;
}
