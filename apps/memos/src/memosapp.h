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
#include <QThread>
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
    // "" while the memos are written, else why the last write failed, as one short sentence (M1 of the 2026-11 audit): every
    // memo shows it until a write passes (each window's "Not saved" band), and Quit waits for a write that passes.
    Q_PROPERTY(QString saveError READ saveError NOTIFY saveStateChanged)
    // Changes not written yet (pending, in flight or failed).
    Q_PROPERTY(bool dirty READ dirty NOTIFY saveStateChanged)

public:
    // `frames` reads where this process's memo windows are (currentFrames() in the app; a fake in tests).
    explicit MemosApp(const QString &storeDir, std::function<QHash<QString, Frame>()> frames, QObject *parent = nullptr);
    ~MemosApp() override;

    // Opens the store with these default sides (the tokens memos.windowWidth and windowHeight) and returns the memos to show,
    // oldest first, as maps {id, color, html (cleaned), width, height, collapsed, translucent, tag}. Empty when
    // the store is read only (refusal()).
    Q_INVOKABLE QVariantList open(int defaultWidth, int defaultHeight);
    // A new memo near `frontId`'s window (down and to the right by `step`) when its frame is known (the frames read last:
    // call refreshFrames() first for the current ones); appended and saved.
    Q_INVOKABLE QVariantMap createMemo(const QString &frontId, int width, int height, int step);
    // Any of html, color, width, height, collapsed, translucent; saved after the debounce.
    Q_INVOKABLE void update(const QString &id, const QVariantMap &changes);
    Q_INVOKABLE void remove(const QString &id);
    // The memo window's xdg-toplevel tag now (memo:<id>[@x,y], hyprframes.h), from the frames read last.
    Q_INVOKABLE QString tagFor(const QString &id) const;
    // Reads the window frames from Hyprland on the worker thread; framesRead() follows once they are applied (always, also
    // when the compositor does not answer). A collapse and a New Memo wait for it (the corner the memo has now).
    Q_INVOKABLE void refreshFrames();
    // Sends `window`'s tag again (the memo collapsed or expanded: the tag names the size the compositor gives the window);
    // main.cpp does it (windowchrome.h).
    Q_INVOKABLE void retag(QObject *window, const QString &tag);
    // Positions read and every change written on the worker thread, without waiting (a memo left, the debounce); saved()
    // follows.
    Q_INVOKABLE void save();
    // The same, waiting for the write (Quit, the last memo closed, SIGTERM): true once it passed.
    Q_INVOKABLE bool saveNow();
    // Ends the app (Main.qml, once Quit may go on): the memos are written once more on the way out (main.cpp, aboutToQuit).
    Q_INVOKABLE void quit();
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
    QString saveError() const { return m_saveError; }
    bool dirty() const { return m_changeGen != m_savedGen; }

    // How long a change waits before it is written, and how often the windows' positions are read.
    static constexpr int kSaveDelayMs = 800;
    static constexpr int kFrameCheckMs = 15000;
    // A failed write is tried again after this long, then twice as long each time, up to the maximum.
    static constexpr int kRetryMinMs = 2000;
    static constexpr int kRetryMaxMs = 60000;

    // The memos as they would be written now (tests).
    const QList<Memo> &memos() const { return m_memos; }
    // Tests only: every write fails while set (MemoStore::injectWriteFault), applied on the worker between two writes.
    void injectWriteFault(bool fault);
    // Tests only: MemoStore::setBeforeCommitHook, run on the worker at each write.
    void setWriteHook(std::function<bool()> hook);
    // The sentence saveError() shows for a failure (tests).
    static QString failureText(WriteFailure failure);

signals:
    void openedChanged();
    void appearanceChanged();
    // Emitted by saveNow() before it writes: each window pushes the text it still holds (MemoWindow.flush, Main.qml), through
    // a direct call, so the write that follows has it (Quit, SIGTERM, a window deactivated).
    void aboutToSave();
    void retagRequested(QWindow *window, const QString &tag);
    // Saved, or failed (saveError() says why).
    void saved(bool ok);
    void saveStateChanged();
    // The frames refreshFrames() asked for are read and applied (tagFor() has them).
    void framesRead();

private:
    // What the worker sends back after a write.
    struct WriteResult
    {
        quint64 generation = 0;
        bool ok = false;
        WriteFailure failure = WriteFailure::None;
        QHash<QString, Frame> frames;
    };
    void scheduleSave();
    bool applyFrames(const QHash<QString, Frame> &frames);
    // Runs on the worker thread: reads the frames, puts them on the snapshot, writes it.
    WriteResult write(QList<Memo> snapshot, quint64 generation);
    void finishWrite(const WriteResult &result, quint64 sequence);
    int indexOf(const QString &id) const;
    QVariantMap toMap(const Memo &m) const;
    void readAppearance();

    MemoStore m_store;
    std::function<QHash<QString, Frame>()> m_frames;
    MemoFormatter m_formatter;
    QList<Memo> m_memos;
    QString m_refusal;
    bool m_opened = false;
    // Every change counts one; the count the last passed write held. Dirty while they differ.
    quint64 m_changeGen = 0;
    quint64 m_savedGen = 0;
    // A write is on the worker; another save asked meanwhile waits for it (then writes the memos as they are then).
    bool m_writing = false;
    bool m_saveAgain = false;
    bool m_readingFrames = false;
    // Each write's number, and the last one reported.
    quint64 m_writeSeq = 0;
    quint64 m_handledSeq = 0;
    QString m_saveError;
    // The store is written, and the frames read, on this thread (M3 of the 2026-11 audit: the fsync and the Hyprland round
    // trip stalled typing). m_worker lives there; the store is only touched there once open() has run.
    QThread m_thread;
    QObject *m_worker = nullptr;
    QTimer m_saveTimer;
    QTimer m_retryTimer;
    int m_retryMs = kRetryMinMs;
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
