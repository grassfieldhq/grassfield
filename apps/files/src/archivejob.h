#pragma once

#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QTimer>

#include <atomic>
#include <memory>

class QThread;

// One Compress or Expand (ADR-0029): bsdtar in a child process (ArchiveLogic's command lines), into a hidden temporary
// name next to the items, then renamed to the Finder's name. A cancel, a failure or a disk that fills up kills the child
// and removes the temporary file or folder; nothing half-written is ever left under a real name. Expand first lists the
// archive and refuses one larger than the free space less kFreeMargin, then stops the child if the free space falls
// under the margin while it writes (a listing can lie). Messages are translated (FilesApp shows them).
class ArchiveJob : public QObject
{
    Q_OBJECT

public:
    // Free space always kept on the destination's disk.
    static constexpr qint64 kFreeMargin = qint64(64) * 1024 * 1024;
    static constexpr int kPollMs = 500;
    // The listing (Expand's first step) is short: an archive that takes longer to list is refused.
    static constexpr int kListMs = 30000;
    static constexpr qint64 kMaxListing = qint64(16) * 1024 * 1024;

    enum class Kind { Compress, Expand };

    // Compress `names` (items of `folder`) into a zip in `folder`; Expand `archive` next to itself. `bsdtar`: the
    // program's path ("" when it is missing: the job fails at once with that message).
    static ArchiveJob *compress(const QString &bsdtar, const QString &folder, const QStringList &names, QObject *parent = nullptr);
    static ArchiveJob *expand(const QString &bsdtar, const QString &archive, QObject *parent = nullptr);
    ~ArchiveJob() override;

    void start();
    void cancel();
    Kind kind() const { return m_kind; }
    // The item it names in the user's words ("Archive.zip" being made, "photos.zip" being expanded).
    QString subject() const;
    // The Expand failed because the archive's download marks could not be copied onto every extracted file: nothing was kept
    // (the Archive Utility model, fail closed). FilesApp says so in a sheet.
    bool unsafe() const { return m_unsafe; }

    // Staging names still in use are recorded, one line each, in stagingRegistry() (<state>/files-staging, ADR-0020): the
    // boot, the Files process and its start time, the percent-encoded path. A Files that was killed during a Compress or an
    // Expand leaves its lines; sweepStaleStaging() (FilesApp, at start, off the GUI thread) removes the items of lines whose
    // process is gone, by descriptor (LaunchGuard::removeTree), and only an absolute path whose last name is a staging name
    // (".grassfield-expand-<8 hex>", ".grassfield-compress-<8 hex>.zip") of the user's own. Returns the items removed.
    static QString stagingRegistry();
    static int sweepStaleStaging(const QString &registry = QString());

signals:
    // `error` is "" on success and on a cancel; `result` the new archive or the expanded item.
    void finished(bool ok, const QString &error, const QString &result);

private:
    ArchiveJob(Kind kind, const QString &bsdtar, QObject *parent);
    void run(const QStringList &args);
    void listed();
    void extracted();
    void finishExpand(const QStringList &top);
    void stopMarking();
    void compressed();
    void fail(const QString &error);
    void cleanUp();
    void setTemp(const QString &path);
    void forgetTemp();
    QString failureText(const QString &fallback) const;

    Kind m_kind;
    QString m_bsdtar;
    QString m_folder;
    QStringList m_names;
    QString m_archive;
    QString m_temp;
    QProcess *m_process = nullptr;
    QTimer m_poll;
    bool m_listing = false;
    bool m_done = false;
    QByteArray m_output;
    QByteArray m_errors;
    // Expand of a downloaded archive: the worker that copies its marks onto the staging tree, and its stop flag.
    QThread *m_marking = nullptr;
    std::shared_ptr<std::atomic_bool> m_stop = std::make_shared<std::atomic_bool>(false);
    bool m_unsafe = false;
    // Entries the marking may walk (0: no cap); only a test changes it (ArchiveJobTestAccess, tst_fileslaunch.cpp).
    static inline qint64 s_markCap = 0;
    friend class ArchiveJobTestAccess;
};
