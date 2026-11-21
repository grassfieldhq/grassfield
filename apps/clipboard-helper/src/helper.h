// grassfield-clipboard-helper's work (ADR-0034): the offers the compositor announces, the shell's answer to each, the reads, the
// history and the pinned items, their stores, the thumbnails, serving an item back. main.cpp wires stdin and stdout.
#pragma once

#include "cliplogic.h"
#include "diskstore.h"
#include "wlclient.h"

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QObject>
#include <QSocketNotifier>
#include <QString>
#include <QTimer>

#include <functional>
#include <memory>

class ThumbnailJob;

class Helper : public QObject
{
public:
    struct Options {
        QByteArray display;   // absolute socket path (--display)
        QString stateDir;     // .../grassfield/clipboard (--state)
        QString runtimeDir;   // tmpfs directory of thumbnails and previews (--runtime)
        qint64 retentionMs = ClipLogic::kDefaultRetentionMs;
        bool historyStore = false;
        // The settings' clears (search.clipboard.clearedAt, .pinnedClearedAt; ms) as the shell read them: carried out at start
        // when they differ from the ones recorded beside the stores (applyClears). -1: not given.
        qint64 clearedAtMs = -1;
        qint64 pinnedClearedAtMs = -1;
        QString program;      // this binary, for the thumbnail worker
    };
    using Output = std::function<void(const QByteArray &line)>;
    // Called when the helper must end (the shell asked, or the compositor connection failed); `code` is the exit code.
    using Quit = std::function<void(int code)>;

    Helper(Options options, Output output, Quit quit, QObject *parent = nullptr);
    ~Helper() override;

    // Loads the stores, connects to the display and reports the state. Capture waits for the shell's resume (`R`). Returns 0
    // when the helper runs, else the exit code (1: the display or the runtime directory failed, 3: an unsupported compositor).
    int start();
    void command(const QByteArray &line);
    // Removes the runtime directory's files (thumbnails, previews) and the directory; writes a history index still owed.
    void cleanup();
    // The shell is gone (its process ended, or it closed our stdin or stdout). When the helper serves the clipboard (an item
    // the user copied from the history), it keeps serving it: the clipboard survives a shell restart. It then forgets the
    // history, records nothing, says nothing, and ends when another client takes the clipboard, the compositor connection
    // ends, or after kKeepMs. False (and nothing changes) when it serves nothing: the caller ends the helper.
    bool keepSelection();
    bool keeping() const { return m_keeping; }
    static constexpr int kKeepMs = 8 * 3600 * 1000;
    // Leaves the shell's systemd unit for a scope of its own (StartTransientUnit through busctl, on the user's bus), so that a
    // restart of the shell's unit does not end a helper that keeps the clipboard. Nothing happens without a user manager.
    void leaveShellUnit();

    static int clearPinned(const QString &stateDir);
    static int clearHistoryStore(const QString &stateDir);
    // Carries out the clears asked in the settings that were not carried out yet (written while no helper ran), then records
    // them beside the stores (<stateDir>/clears). Run at start before anything is loaded, and alone (--apply-clears) by the
    // shell while the history is off. Returns the record as it now stands.
    static DiskStore::Clears applyClears(const QString &stateDir, qint64 clearedAtMs, qint64 pinnedClearedAtMs);

private:
    struct Pending;
    struct Writer;
    // One worker run waiting its turn: a new copy's image (recorded only with its thumbnail) or a stored image's thumbnail.
    struct ImageJob {
        QByteArray id;
        bool fresh = false;
        ClipLogic::Item item; // a fresh image only
    };

    void emitLine(const QList<QByteArray> &fields);
    void emitItem(const QByteArray &id);
    void emitRemoved(const QList<QByteArray> &ids);
    void log(const char *what);
    void updateCapture();
    void selection(WaylandClipboard::Offer *offer, bool first);
    void abortPending();
    void answer(quint64 seq, bool yes, const QString &app);
    void readNext();
    void readable();
    void readDone(ClipLogic::ReadResult::Status status);
    void finishRead();
    void addItem(ClipLogic::Item item, const QByteArray &thumbnail);
    void queueNewImage(const ClipLogic::Item &item);
    void queueThumbnail(const QByteArray &id);
    void nextThumbnail();
    void imageDone(const ImageJob &job, const QByteArray &png);
    void cancelNewImages();
    void closeWriter(Writer *w);
    void expire();
    void pin(const QByteArray &id);
    void unpin(const QByteArray &id);
    void remove(const QByteArray &id);
    void clearHistory();
    void clearPinnedItems();
    void setHistoryStore(bool on);
    // The history store's index is written once per change, however many item files it touched (historyChanged schedules
    // it, flushHistoryIndex writes it now).
    void historyChanged();
    void flushHistoryIndex();
    // B-10: the clipboard was cleared (or replaced by blank text) by its source: a copy recorded less than kClearedSoonMs
    // before may have been a password; the shell is told (`K <id>`) and decides.
    void clearedSoon();
    void copy(const QByteArray &id, bool plainOnly);
    void ownSelectionConfirmed();
    void send(const QByteArray &mime, int fd);
    void preview(const QByteArray &id);
    void dropPreview(const QByteArray &id);
    QString thumbPath(const QByteArray &id) const;
    QString previewPath(const QByteArray &id) const;
    bool writeRuntimeFile(const QString &path, const QByteArray &bytes);
    void forgetFiles(const QByteArray &id);
    QByteArray newId() const;
    static qint64 nowWall();
    static qint64 nowBoot();

    Options m_options;
    Output m_output;
    Quit m_quit;
    WaylandClipboard *m_wl = nullptr;
    ClipLogic::Store m_store;
    DiskStore m_pinnedDisk;
    DiskStore m_historyDisk;
    // The clears carried out (applyClears at start, then the shell's CH and CP with the setting's time).
    DiskStore::Clears m_clears;
    QByteArray m_bootId;
    bool m_shellResumed = false;
    quint64 m_seq = 0;
    std::unique_ptr<Pending> m_pending;
    QHash<QByteArray, QString> m_thumbs;
    // One worker at a time for every image (ADR-0034 §1f); the clears cancel the new copies' images, waiting or running.
    QList<ImageJob> m_imageQueue;
    ThumbnailJob *m_thumbJob = nullptr;
    bool m_thumbJobFresh = false;
    quint64 m_imageGeneration = 0;
    QHash<QByteArray, int> m_thumbAttempts;
    ThumbnailJob *m_previewJob = nullptr;
    QTimer m_expiry;
    // The item we serve (a copy: it stays on the clipboard when the history drops it), and whether only its plain text is offered.
    ClipLogic::Item m_owned;
    bool m_ownedPlainOnly = false;
    QByteArray m_requestedId;
    QList<Writer *> m_writers;
    QTimer m_indexTimer;
    bool m_historyIndexDirty = false;
    // The last copy recorded and when (boot clock), while a clear of the clipboard could still be its source's (B-10).
    QByteArray m_recentId;
    qint64 m_recentBootMs = 0;
    bool m_keeping = false;
};
