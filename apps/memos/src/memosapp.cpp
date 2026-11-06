#include "memosapp.h"

#include "autoappearance.h"
#include "runmode.h"
#include "shortcutstyle.h"

#include <QClipboard>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTime>
#include <QWindow>

namespace memos {

namespace {

QString configFile()
{
    return grassfield::apps::runmode::configDir() + QStringLiteral("/grassfield.json");
}

} // namespace

MemosApp::MemosApp(const QString &storeDir, std::function<QHash<QString, Frame>()> frames, QObject *parent)
    : QObject(parent)
    , m_store(storeDir)
    , m_frames(std::move(frames))
    , m_macDevice(grassfield::apps::macDeviceHere())
{
    m_saveTimer.setSingleShot(true);
    m_saveTimer.setInterval(kSaveDelayMs);
    connect(&m_saveTimer, &QTimer::timeout, this, [this] { saveNow(); });
    // Moving a window tells the client nothing on Wayland: its position is read now and then, and written when it changed.
    m_frameTimer.setInterval(kFrameCheckMs);
    connect(&m_frameTimer, &QTimer::timeout, this, [this] {
        if (applyFrames())
            scheduleSave();
    });

    // Appearance follows grassfield.json (read only), like every Grassfield surface (Preview's rule).
    const QString file = configFile();
    const QString dir = QFileInfo(file).absolutePath();
    if (QFileInfo(dir).isDir())
        m_watcher.addPath(dir);
    if (QFileInfo::exists(file))
        m_watcher.addPath(file);
    const auto reread = [this] {
        const QString f = configFile();
        if (QFileInfo::exists(f) && !m_watcher.files().contains(f))
            m_watcher.addPath(f);
        readAppearance();
    };
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, reread);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, reread);
    readAppearance();
    m_autoTimer.setInterval(grassfield::apps::kAutoRecheckMs);
    connect(&m_autoTimer, &QTimer::timeout, this, [this] {
        if (m_autoAppearance)
            readAppearance();
    });
    m_autoTimer.start();
}

MemosApp::~MemosApp()
{
    if (m_dirty)
        saveNow();
}

QVariantList MemosApp::open(int defaultWidth, int defaultHeight)
{
    QVariantList out;
    const OpenState state = m_store.open(defaultWidth, defaultHeight);
    m_opened = true;
    m_refusal = state == OpenState::Newer ? QStringLiteral("newer") : state == OpenState::Unreadable ? QStringLiteral("unreadable") : QString();
    emit openedChanged();
    if (m_store.readOnly())
        return out;
    m_memos = m_store.memos();
    for (Memo &m : m_memos)
        m.html = cleanHtml(m.html);
    for (const Memo &m : std::as_const(m_memos))
        out.append(toMap(m));
    m_frameTimer.start();
    return out;
}

QVariantMap MemosApp::createMemo(const QString &frontId, int width, int height, int step)
{
    if (!m_opened || m_store.readOnly())
        return {};
    Memo m;
    m.id = newId();
    m.color = defaultColor();
    m.width = qBound(kMinSide, width, kMaxSide);
    m.height = qBound(kMinSide, height, kMaxSide);
    m.created = m.modified = QDateTime::currentDateTimeUtc();
    // Near the memo in front, as Hyprland sees it now (its stored position when the compositor does not answer).
    applyFrames();
    const int front = indexOf(frontId);
    if (front >= 0 && m_memos.at(front).hasPosition) {
        m.hasPosition = true;
        m.x = m_memos.at(front).x + step;
        m.y = m_memos.at(front).y + step;
    }
    m_memos.append(m);
    scheduleSave();
    return toMap(m);
}

void MemosApp::update(const QString &id, const QVariantMap &changes)
{
    const int i = indexOf(id);
    if (i < 0 || m_store.readOnly())
        return;
    Memo &m = m_memos[i];
    bool changed = false;
    const auto setBool = [&](const char *key, bool &field) {
        const auto it = changes.constFind(QLatin1String(key));
        if (it != changes.constEnd() && it->toBool() != field) {
            field = it->toBool();
            changed = true;
        }
    };
    const auto setSide = [&](const char *key, int &field) {
        const auto it = changes.constFind(QLatin1String(key));
        if (it == changes.constEnd())
            return;
        const int v = qBound(kMinSide, it->toInt(), kMaxSide);
        if (v != field) {
            field = v;
            changed = true;
        }
    };
    if (const auto it = changes.constFind(QStringLiteral("html")); it != changes.constEnd() && it->toString() != m.html) {
        m.html = it->toString();
        m.modified = QDateTime::currentDateTimeUtc();
        changed = true;
    }
    if (const auto it = changes.constFind(QStringLiteral("color")); it != changes.constEnd() && isColorName(it->toString())
        && it->toString() != m.color) {
        m.color = it->toString();
        changed = true;
    }
    setSide("width", m.width);
    setSide("height", m.height);
    setBool("collapsed", m.collapsed);
    setBool("translucent", m.translucent);
    if (changed)
        scheduleSave();
}

void MemosApp::remove(const QString &id)
{
    const int i = indexOf(id);
    if (i < 0)
        return;
    m_memos.removeAt(i);
    scheduleSave();
}

QString MemosApp::tagFor(const QString &id) const
{
    const int i = indexOf(id);
    if (i < 0)
        return {};
    const Memo &m = m_memos.at(i);
    return memoTag(m.id, m.hasPosition, m.x, m.y);
}

QString MemosApp::freshTagFor(const QString &id)
{
    applyFrames();
    return tagFor(id);
}

void MemosApp::retag(QObject *window, const QString &tag)
{
    if (auto *w = qobject_cast<QWindow *>(window)) {
        w->setProperty("gfChromeRole", tag);
        emit retagRequested(w, tag);
    }
}

bool MemosApp::applyFrames()
{
    if (!m_frames)
        return false;
    const QHash<QString, Frame> frames = m_frames();
    bool changed = false;
    for (Memo &m : m_memos) {
        const auto it = frames.constFind(m.id);
        if (it == frames.constEnd())
            continue; // not mapped now, or the compositor did not answer: the stored position stays
        if (!m.hasPosition || m.x != it->x || m.y != it->y) {
            m.hasPosition = true;
            m.x = it->x;
            m.y = it->y;
            changed = true;
        }
    }
    return changed;
}

bool MemosApp::saveNow()
{
    m_saveTimer.stop();
    if (!m_opened || m_store.readOnly())
        return false;
    // The windows push the text they still hold (their short pause), synchronously: the write below has it.
    emit aboutToSave();
    m_saveTimer.stop();
    applyFrames();
    const bool ok = m_store.save(m_memos);
    m_dirty = !ok;
    emit saved(ok);
    return ok;
}

void MemosApp::scheduleSave()
{
    m_dirty = true;
    m_saveTimer.start();
}

QString MemosApp::clipboardText(bool selection) const
{
    const QClipboard *clipboard = QGuiApplication::clipboard();
    if (!clipboard || (selection && !clipboard->supportsSelection()))
        return {};
    return clipboard->text(selection ? QClipboard::Selection : QClipboard::Clipboard);
}

QVariantList MemosApp::current() const
{
    QVariantList out;
    for (const Memo &m : m_memos)
        out.append(toMap(m));
    return out;
}

QString MemosApp::firstLine(const QString &html) const
{
    return memos::firstLine(html);
}

int MemosApp::indexOf(const QString &id) const
{
    for (int i = 0; i < m_memos.size(); ++i) {
        if (m_memos.at(i).id == id)
            return i;
    }
    return -1;
}

QVariantMap MemosApp::toMap(const Memo &m) const
{
    return {{QStringLiteral("id"), m.id},
            {QStringLiteral("color"), m.color},
            {QStringLiteral("html"), m.html},
            {QStringLiteral("width"), m.width},
            {QStringLiteral("height"), m.height},
            {QStringLiteral("collapsed"), m.collapsed},
            {QStringLiteral("translucent"), m.translucent},
            {QStringLiteral("tag"), memoTag(m.id, m.hasPosition, m.x, m.y)}};
}

void MemosApp::readAppearance()
{
    bool dark = true;
    bool reduce = false;
    bool contrast = false;
    qreal scale = 1;
    QString accent = QStringLiteral("multicolor");
    QString highlight = QStringLiteral("automatic");
    QString shortcutSetting;
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
        // Same names as ui/Grassfield/Ui/Accent.js; anything else reads as the default.
        const QStringList names{QStringLiteral("blue"), QStringLiteral("purple"), QStringLiteral("pink"), QStringLiteral("red"),
                                QStringLiteral("orange"), QStringLiteral("yellow"), QStringLiteral("green"), QStringLiteral("graphite")};
        const QJsonObject accentObject = root.value(QStringLiteral("accent")).toObject();
        if (names.contains(accentObject.value(QStringLiteral("color")).toString()))
            accent = accentObject.value(QStringLiteral("color")).toString();
        if (names.contains(accentObject.value(QStringLiteral("highlight")).toString()))
            highlight = accentObject.value(QStringLiteral("highlight")).toString();
        shortcutSetting = root.value(QStringLiteral("keyboard")).toObject().value(QStringLiteral("shortcutStyle")).toString();
    }
    const QString shortcuts = grassfield::apps::shortcutStyle(shortcutSetting, m_macDevice);
    if (dark != m_dark || reduce != m_reduceMotion || contrast != m_increaseContrast || scale != m_textScale || accent != m_accentColor
        || highlight != m_accentHighlight || shortcuts != m_shortcutStyle) {
        m_dark = dark;
        m_reduceMotion = reduce;
        m_increaseContrast = contrast;
        m_textScale = scale;
        m_accentColor = accent;
        m_accentHighlight = highlight;
        m_shortcutStyle = shortcuts;
        emit appearanceChanged();
    }
}

} // namespace memos
