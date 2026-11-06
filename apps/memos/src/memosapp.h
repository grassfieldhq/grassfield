// Grassfield Memos' backend (ADR-0051): the store, the debounced saves, the frames read from Hyprland, the text formatter
// and the appearance of grassfield.json (read only, as every app). QML (qml/Main.qml) owns the windows; it pushes each
// change here and reads the memos once, at open().
#pragma once

#include "hyprframes.h"
#include "memoformatter.h"
#include "memostore.h"

#include <QFileSystemWatcher>
#include <QHash>
#include <QObject>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

#include <functional>

class QWindow;

namespace memos {

class MemosApp : public QObject
{
    Q_OBJECT
    // "" (writable), "newer" (a newer schema) or "unreadable" (an I/O error): the store is read only, no memo opens.
    Q_PROPERTY(QString refusal READ refusal NOTIFY openedChanged)
    Q_PROPERTY(QObject *formatter READ formatter CONSTANT)
    Q_PROPERTY(bool dark READ dark NOTIFY appearanceChanged)
    Q_PROPERTY(bool reduceMotion READ reduceMotion NOTIFY appearanceChanged)
    Q_PROPERTY(bool increaseContrast READ increaseContrast NOTIFY appearanceChanged)
    Q_PROPERTY(qreal textScale READ textScale NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentColor READ accentColor NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentHighlight READ accentHighlight NOTIFY appearanceChanged)
    Q_PROPERTY(QString shortcutStyle READ shortcutStyle NOTIFY appearanceChanged)

public:
    // `frames` reads where this process's memo windows are (currentFrames() in the app; a fake in tests).
    explicit MemosApp(const QString &storeDir, std::function<QHash<QString, Frame>()> frames, QObject *parent = nullptr);
    ~MemosApp() override;

    // Opens the store with these default sides (the tokens memos.windowWidth and windowHeight) and returns the memos to show,
    // oldest first, as maps {id, color, html (cleaned), width, height, collapsed, translucent, tag}. Empty when
    // the store is read only (refusal()).
    Q_INVOKABLE QVariantList open(int defaultWidth, int defaultHeight);
    // A new memo near `frontId`'s window (down and to the right by `step`) when its frame is known; appended and saved.
    Q_INVOKABLE QVariantMap createMemo(const QString &frontId, int width, int height, int step);
    // Any of html, color, width, height, collapsed, translucent; saved after the debounce.
    Q_INVOKABLE void update(const QString &id, const QVariantMap &changes);
    Q_INVOKABLE void remove(const QString &id);
    // The memo window's xdg-toplevel tag now (memo:<id>[@x,y], hyprframes.h).
    Q_INVOKABLE QString tagFor(const QString &id) const;
    // The same after reading the window frames from Hyprland now (a collapse or an expand sends the corner it had before).
    Q_INVOKABLE QString freshTagFor(const QString &id);
    // Sends `window`'s tag again (the memo collapsed or expanded: the tag names the size the compositor gives the window);
    // main.cpp does it (windowchrome.h).
    Q_INVOKABLE void retag(QObject *window, const QString &tag);
    // Positions read now and every change written now (Quit, the last memo closed, SIGTERM).
    Q_INVOKABLE bool saveNow();
    // The clipboard's text, or the primary selection's (the middle button on Linux).
    Q_INVOKABLE QString clipboardText(bool selection) const;
    // Every memo as open() gives them (the windows the compositor closed open again on activation).
    Q_INVOKABLE QVariantList current() const;
    Q_INVOKABLE QString firstLine(const QString &html) const;
    Q_INVOKABLE int count() const { return m_memos.size(); }

    QString refusal() const { return m_refusal; }
    QObject *formatter() { return &m_formatter; }
    bool dark() const { return m_dark; }
    bool reduceMotion() const { return m_reduceMotion; }
    bool increaseContrast() const { return m_increaseContrast; }
    qreal textScale() const { return m_textScale; }
    QString accentColor() const { return m_accentColor; }
    QString accentHighlight() const { return m_accentHighlight; }
    QString shortcutStyle() const { return m_shortcutStyle; }

    // How long a change waits before it is written, and how often the windows' positions are read.
    static constexpr int kSaveDelayMs = 800;
    static constexpr int kFrameCheckMs = 15000;

    // The memos as they would be written now (tests).
    const QList<Memo> &memos() const { return m_memos; }

signals:
    void openedChanged();
    void appearanceChanged();
    // Emitted by saveNow() before it writes: each window pushes the text it still holds (MemoWindow.flush, Main.qml), through
    // a direct call, so the write that follows has it (Quit, SIGTERM, a window deactivated).
    void aboutToSave();
    void retagRequested(QWindow *window, const QString &tag);
    // Saved, or failed (no memo text in `message`).
    void saved(bool ok);

private:
    void scheduleSave();
    bool applyFrames();
    int indexOf(const QString &id) const;
    QVariantMap toMap(const Memo &m) const;
    void readAppearance();

    MemoStore m_store;
    std::function<QHash<QString, Frame>()> m_frames;
    MemoFormatter m_formatter;
    QList<Memo> m_memos;
    QString m_refusal;
    bool m_opened = false;
    bool m_dirty = false;
    QTimer m_saveTimer;
    QTimer m_frameTimer;

    QFileSystemWatcher m_watcher;
    QTimer m_autoTimer;
    bool m_autoAppearance = false;
    bool m_macDevice = false;
    bool m_dark = true;
    bool m_reduceMotion = false;
    bool m_increaseContrast = false;
    qreal m_textScale = 1;
    QString m_accentColor = QStringLiteral("multicolor");
    QString m_accentHighlight = QStringLiteral("automatic");
    QString m_shortcutStyle = QStringLiteral("pc");
};

} // namespace memos
