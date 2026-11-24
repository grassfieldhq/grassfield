#pragma once

#include <QFileSystemWatcher>
#include <QObject>
#include <QString>
#include <QTimer>

// What the Screenshot window takes from the user's settings (grassfield.json, read only), as every Grassfield app reads it
// (Preview's PreviewApp::readAppearance): appearance, accessibility, accent, the title bar's double click and the menu
// shortcut style. The values reach the shared Grassfield.Ui through Theme.qml.
class AppearanceSettings : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool dark READ dark NOTIFY appearanceChanged)
    Q_PROPERTY(bool reduceMotion READ reduceMotion NOTIFY appearanceChanged)
    // accessibility.increaseContrast and accessibility.textSize (1 to 1.3).
    Q_PROPERTY(bool increaseContrast READ increaseContrast NOTIFY appearanceChanged)
    Q_PROPERTY(qreal textScale READ textScale NOTIFY appearanceChanged)
    // windows.titlebarDoubleClick: zoom (default), minimize or none.
    Q_PROPERTY(QString titlebarDoubleClick READ titlebarDoubleClick NOTIFY appearanceChanged)
    // False when the shell says the compositor plugin is absent: the minimize light is greyed (ADR-0015 Q4b).
    Q_PROPERTY(bool canMinimize READ canMinimize NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentColor READ accentColor NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentHighlight READ accentHighlight NOTIFY appearanceChanged)
    // "mac" or "pc", keyboard.shortcutStyle resolved for this device (shortcutstyle.h).
    Q_PROPERTY(QString shortcutStyle READ shortcutStyle NOTIFY appearanceChanged)

public:
    explicit AppearanceSettings(QObject *parent = nullptr);

    bool dark() const { return m_dark; }
    bool reduceMotion() const { return m_reduceMotion; }
    bool increaseContrast() const { return m_increaseContrast; }
    qreal textScale() const { return m_textScale; }
    QString titlebarDoubleClick() const { return m_titlebarDoubleClick; }
    bool canMinimize() const { return m_canMinimize; }
    QString accentColor() const { return m_accentColor; }
    QString accentHighlight() const { return m_accentHighlight; }
    QString shortcutStyle() const { return m_shortcutStyle; }

    // Reads grassfield.json again; emits appearanceChanged() only when a value changed. The file is the one of
    // grassfield::apps::runmode::configDir(), or `file` when given (tests).
    void readAppearance(const QString &file = QString());

signals:
    void appearanceChanged();

private:
    QFileSystemWatcher m_watcher;
    QTimer m_autoTimer;
    bool m_macDevice = false;
    bool m_autoAppearance = false;
    bool m_dark = true;
    bool m_reduceMotion = false;
    bool m_increaseContrast = false;
    qreal m_textScale = 1;
    QString m_titlebarDoubleClick = QStringLiteral("zoom");
    bool m_canMinimize = true;
    QString m_accentColor = QStringLiteral("multicolor");
    QString m_accentHighlight = QStringLiteral("automatic");
    QString m_shortcutStyle;
};
