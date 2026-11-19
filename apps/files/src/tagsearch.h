#pragma once

#include "workers.h"

#include <QByteArray>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QStringList>
#include <QThread>

#include <atomic>

// Finds the local files and folders tagged `tag` (user.xdg.tags, see TagLogic) in `root` and below, on its own
// thread, without any index: breadth first (nearer items first), on the root's filesystem only (like find -xdev, so
// network and removable mounts are not walked), never through symbolic links, hidden entries only when `showHidden`,
// and bounded (kMaxVisited entries, kMaxResults matches, kMaxDepth levels). Matches arrive in batches through found();
// done() tells whether a bound stopped the walk. cancel() stops it at the next entry; a cancelled search emits nothing
// more. The object belongs to the thread that created it and deletes itself (deleteLater) once finished.
class TagSearch : public QThread
{
    Q_OBJECT

public:
    static constexpr int kMaxVisited = 50000;
    static constexpr int kMaxResults = 2000;
    static constexpr int kMaxDepth = 32;

    TagSearch(quint64 generation, const QString &root, const QString &tag, bool showHidden);

    void cancel() { m_cancel.store(true); }
    // Also when the app quits (Workers::waitAll): the walk ends before Qt's shutdown.
    bool cancelled() const { return m_cancel.load() || Workers::stopping(); }

signals:
    // Every signal carries the generation the search was started with (SearchRunner drops superseded ones).
    void found(quint64 generation, const QStringList &paths);
    void done(quint64 generation, bool limited, int visited);

protected:
    void run() override;

private:
    bool tagged(const QByteArray &path) const;

    const quint64 m_generation;
    const QByteArray m_root;
    const QString m_tag;
    const bool m_showHidden;
    std::atomic_bool m_cancel{false};
};

// One tag search at a time for a view. start() supersedes the running search (cancelling it) and stop() drops it; once
// either has returned, nothing of the old search reaches found() or done(): disconnecting a signal does not cancel
// calls already queued from the worker thread, so every batch carries a generation number and only the current
// generation passes. done() comes once per start() that was not superseded.
class SearchRunner : public QObject
{
    Q_OBJECT

public:
    explicit SearchRunner(QObject *parent = nullptr);
    ~SearchRunner() override;

    void start(const QString &root, const QString &tag, bool showHidden);
    void stop();
    bool running() const { return !m_search.isNull(); }

signals:
    void found(const QStringList &paths);
    void done(bool limited, int visited);

private:
    void onFound(quint64 generation, const QStringList &paths);
    void onDone(quint64 generation, bool limited, int visited);

    QPointer<TagSearch> m_search;
    quint64 m_generation = 0;
};
