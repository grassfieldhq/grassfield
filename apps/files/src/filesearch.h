#pragma once

#include "workers.h"

#include "searchlogic.h"

#include <QByteArray>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QThread>

#include <atomic>
#include <optional>

// The Files search (ADR-0027) on its own thread. "This computer": the file index answers when it can (localsearch, then
// plocate for names), each answer checked with one lstat and kept under `root` without a hidden path segment (unless
// `showHidden`); without an index, or with criteria only, a bounded walk of `root`. A folder: a bounded walk of it (breadth
// first, its filesystem only, never through symbolic links, kMaxVisited entries, kMaxResults matches, kMaxDepth levels),
// the text matched against names. Contents rows need localsearch: without it the search ends at once and says so.
// Matches arrive in batches through found(); done() says how. cancel() stops it at the next entry or the next poll of an
// external program (which is killed); a cancelled search emits nothing more. Deletes itself (deleteLater) once finished.
class FileSearch : public QThread
{
    Q_OBJECT

public:
    static constexpr int kMaxVisited = 200000;
    static constexpr int kMaxResults = 2000;
    static constexpr int kMaxDepth = 32;
    // An index program that has not answered in this time is killed (the shell's Search waits 2 s as well).
    static constexpr int kProgramMs = 2000;
    // At most this much of a program's output is read.
    static constexpr qint64 kMaxOutput = 8 * 1024 * 1024;

    // How a search found its results: by the file index, by plocate's name database, or by a walk.
    enum Backend { Index = 0, Names = 1, Walk = 2 };
    Q_ENUM(Backend)

    struct Settings {
        SearchLogic::Query query;
        // "This computer": the home folder, or GRASSFIELD_SEARCH_ROOT in a dev session.
        QString root;
        bool showHidden = false;
        // The index programs found on PATH ("" when absent) and plocate's database (dev only: SEARCH_PLOCATE_DB).
        QString localsearch;
        QString plocate;
        QString plocateDb;
    };

    FileSearch(quint64 generation, const Settings &settings);

    void cancel() { m_cancel.store(true); }
    // Also when the app quits (Workers::waitAll): the walk ends before Qt's shutdown.
    bool cancelled() const { return m_cancel.load() || Workers::stopping(); }

signals:
    void found(quint64 generation, const QStringList &paths);
    // `limited`: a bound stopped it; `contentsUnavailable`: a Contents row could not be served (no localsearch).
    void done(quint64 generation, int backend, bool limited, bool contentsUnavailable);

protected:
    void run() override;

private:
    // The paths an index program prints (localsearch's file:// URIs, plocate's paths), or nullopt when it could not run,
    // failed or timed out.
    std::optional<QStringList> runProgram(const QString &program, const QStringList &arguments, bool uris);
    // Whether `path` is under `base` without a hidden segment below it (unless showHidden): the index answers for the whole
    // disk.
    bool inScope(const QString &path, const QString &base) const;
    bool facts(const QByteArray &path, SearchLogic::Facts *out) const;
    void walk(const QString &base, const QSet<QString> *contents);
    void keep(const QString &path);
    void flush(bool force);

    const quint64 m_generation;
    const Settings m_settings;
    std::atomic_bool m_cancel{false};
    QStringList m_batch;
    qint64 m_lastFlush = 0;
    int m_matches = 0;
    bool m_limited = false;
};

// One search at a time for a listing: start() supersedes the running one, stop() drops it; once either has returned
// nothing of the old search reaches found() or done() (generation numbers, as the tag search's runner).
class FileSearchRunner : public QObject
{
    Q_OBJECT

public:
    explicit FileSearchRunner(QObject *parent = nullptr);
    ~FileSearchRunner() override;

    // Both return at once: a superseded or stopped search finishes on its own thread (see stop()).
    void start(const FileSearch::Settings &settings);
    void stop();

signals:
    void found(const QStringList &paths);
    void done(int backend, bool limited, bool contentsUnavailable);

private:
    // How long the destructor waits for the search it cancelled (shutdown only).
    static constexpr int kShutdownWaitMs = 200;
    QPointer<FileSearch> m_search;
    quint64 m_generation = 0;
};
