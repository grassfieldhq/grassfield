#pragma once

#include <QDeadlineTimer>
#include <QHash>
#include <QObject>
#include <QString>
#include <QStringList>

#include <functional>

// What a folder's file system lets Files read on the GUI thread (audit F2). A file: URL is not a local disk: NFS, SMB, sshfs
// and other FUSE mounts are file: URLs too, and one that hangs froze the whole app (and every Open and Save panel, which
// share the listing code) as soon as a row read a file's content type, its tags or its folder look, or the listing resolved
// its path. So the kind of a folder's file system is found once per folder, off the GUI thread (statfs and realpath on a
// worker), and only a local disk file system (Kind::Disk) is read from the GUI thread: content sniffing of a type the name
// leaves open, tags (user.xdg.tags) and folder looks (lgetxattr), the inotify watch of the shown folder. Every other kind,
// and a folder whose probe has not answered yet, shows what the listing (KIO, out of process) knows: the type from the name,
// no tags, no folder look. A probe stuck on a dead mount holds one worker; at most kMaxProbes run at once and the others wait.
namespace FsKind
{
enum class Kind {
    Unknown, // not probed yet, or the probe failed: treated as Other
    Disk, // a local disk file system (ext4, btrfs, xfs, tmpfs, vfat, exfat, ntfs3…): reads are short
    Other, // network, FUSE, pseudo file systems (proc, sysfs) and any type not known as a local disk
};

// The kind of a statfs f_type value (an allowlist of local disk file systems; anything else is Other).
Kind classify(qint64 type);

struct Probe {
    Kind kind = Kind::Unknown;
    QString canonical; // realpath of the folder ("" when it can't be resolved)
};

// Blocking: statfs and realpath of `dir`. Only ever called on a worker (FsKindCache).
Probe probe(const QString &dir);
} // namespace FsKind

class FsKindCache : public QObject
{
    Q_OBJECT

public:
    // At most this many probes at once (a probe stuck on a dead mount keeps its worker); an answer stays fresh this long
    // (a later ask starts a new probe but keeps answering the known kind meanwhile).
    static constexpr int kMaxProbes = 8;
    static constexpr int kFreshMs = 15000;

    // The one cache of the process (GUI thread).
    static FsKindCache *instance();

    // The kind known for the absolute local folder `dir` (Unknown when none yet); asks for a probe when the answer is missing
    // or stale. known(dir) follows each probe's answer.
    FsKind::Kind kindOf(const QString &dir);
    // The folder's canonical path as the last probe found it ("" when unknown).
    QString canonicalOf(const QString &dir) const;

    // Tests: what probe() does (null: the real one); the probes still running.
    static void setProbeForTest(std::function<FsKind::Probe(const QString &)> probe);
    int pending() const { return int(m_running.size() + m_queue.size()); }
    void forgetForTest() { m_entries.clear(); }

signals:
    void known(const QString &dir);

private:
    using QObject::QObject;
    void startNext();

    struct Entry {
        FsKind::Probe probe;
        QDeadlineTimer fresh;
        bool answered = false;
    };
    QHash<QString, Entry> m_entries;
    QStringList m_queue;
    QStringList m_running;
};
