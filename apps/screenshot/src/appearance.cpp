#include "appearance.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStringList>
#include <QTime>

#include "autoappearance.h"
#include "chromecaps.h"
#include "runmode.h"
#include "shortcutstyle.h"

namespace {

QString configFile()
{
    return grassfield::apps::runmode::configDir() + QStringLiteral("/grassfield.json");
}

// Same names as ui/Grassfield/Ui/Accent.js.
const QStringList kAccents{QStringLiteral("blue"),   QStringLiteral("purple"), QStringLiteral("pink"),   QStringLiteral("red"),
                           QStringLiteral("orange"), QStringLiteral("yellow"), QStringLiteral("green"),  QStringLiteral("graphite")};

} // namespace

AppearanceSettings::AppearanceSettings(QObject *parent)
    : QObject(parent)
    , m_macDevice(grassfield::apps::macDeviceHere())
{
    // grassfield.json and the shell's capabilities file are watched through their folders (they may not exist yet, and an
    // atomic write replaces the file).
    const QString file = configFile();
    const QString dir = QFileInfo(file).absolutePath();
    if (QFileInfo(dir).isDir())
        m_watcher.addPath(dir);
    if (QFileInfo::exists(file))
        m_watcher.addPath(file);
    grassfield::apps::watchCapabilities(m_watcher);
    const auto reread = [this] {
        const QString f = configFile();
        if (QFileInfo::exists(f) && !m_watcher.files().contains(f))
            m_watcher.addPath(f);
        grassfield::apps::watchCapabilities(m_watcher);
        readAppearance();
    };
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, reread);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, reread);
    readAppearance();
    // Auto appearance: the schedule is read again each minute while the setting is "auto".
    m_autoTimer.setInterval(grassfield::apps::kAutoRecheckMs);
    connect(&m_autoTimer, &QTimer::timeout, this, [this] {
        if (m_autoAppearance)
            readAppearance();
    });
    m_autoTimer.start();
}

void AppearanceSettings::readAppearance(const QString &fileOverride)
{
    bool dark = true;
    bool reduce = false;
    bool contrast = false;
    qreal scale = 1;
    QString accent = QStringLiteral("multicolor");
    QString highlight = QStringLiteral("automatic");
    QString doubleClick = QStringLiteral("zoom");
    QString shortcutSetting;
    QFile f(fileOverride.isEmpty() ? configFile() : fileOverride);
    m_autoAppearance = false;
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
        const QJsonObject accentObject = root.value(QStringLiteral("accent")).toObject();
        const QString a = accentObject.value(QStringLiteral("color")).toString();
        if (kAccents.contains(a))
            accent = a;
        const QString h = accentObject.value(QStringLiteral("highlight")).toString();
        if (kAccents.contains(h))
            highlight = h;
        shortcutSetting = root.value(QStringLiteral("keyboard")).toObject().value(QStringLiteral("shortcutStyle")).toString();
    }
    const QString shortcuts = grassfield::apps::shortcutStyle(shortcutSetting, m_macDevice);
    const bool canMinimize = grassfield::apps::minimizeAvailableInFile();
    if (dark != m_dark || reduce != m_reduceMotion || contrast != m_increaseContrast || scale != m_textScale || accent != m_accentColor
        || highlight != m_accentHighlight || doubleClick != m_titlebarDoubleClick || canMinimize != m_canMinimize || shortcuts != m_shortcutStyle) {
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
