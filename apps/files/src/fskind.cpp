#include "fskind.h"

#include "workers.h"

#include <QCoreApplication>
#include <QFile>
#include <QMutex>
#include <QPointer>

#include <climits>
#include <cstdlib>
#include <memory>
#include <sys/vfs.h>

namespace
{
QMutex g_probeMutex;
std::function<FsKind::Probe(const QString &)> g_probe; // under g_probeMutex
} // namespace

namespace FsKind
{
Kind classify(qint64 type)
{
    switch (quint32(type)) {
    case 0xEF53: // ext2, ext3, ext4
    case 0x9123683E: // btrfs
    case 0x58465342: // xfs
    case 0x01021994: // tmpfs (and devtmpfs)
    case 0x858458F6: // ramfs
    case 0xF2F52010: // f2fs
    case 0x4D44: // vfat, msdos
    case 0x2011BAB0: // exfat
    case 0x7366746E: // ntfs3
    case 0x5346544E: // ntfs (the old driver)
    case 0x2FC12FC1: // zfs
    case 0xCA451A4E: // bcachefs
    case 0x3153464A: // jfs
    case 0x52654973: // reiserfs
    case 0x4244: // hfs
    case 0x482B: // hfsplus
    case 0x9660: // iso9660
    case 0x15013346: // udf
    case 0x73717368: // squashfs
    case 0x794C7630: // overlayfs
    case 0xE0F5E1E2: // erofs
    case 0x3434: // nilfs2
    case 0xF15F: // ecryptfs
    case 0x00011954: // ufs
        return Kind::Disk;
    default:
        return Kind::Other;
    }
}

Probe probe(const QString &dir)
{
    {
        QMutexLocker lock(&g_probeMutex);
        if (g_probe)
            return g_probe(dir);
    }
    Probe p;
    const QByteArray path = QFile::encodeName(dir);
    struct statfs fs;
    if (::statfs(path.constData(), &fs) == 0)
        p.kind = classify(qint64(fs.f_type));
    char resolved[PATH_MAX];
    if (::realpath(path.constData(), resolved))
        p.canonical = QFile::decodeName(resolved);
    return p;
}
} // namespace FsKind

FsKindCache *FsKindCache::instance()
{
    static QPointer<FsKindCache> cache;
    if (!cache)
        cache = new FsKindCache(QCoreApplication::instance());
    return cache;
}

FsKind::Kind FsKindCache::kindOf(const QString &dir)
{
    if (dir.isEmpty())
        return FsKind::Kind::Unknown;
    auto it = m_entries.find(dir);
    if (it == m_entries.end())
        it = m_entries.insert(dir, Entry());
    if ((!it->answered || it->fresh.hasExpired()) && !m_running.contains(dir) && !m_queue.contains(dir)) {
        // A cache of folders seen, bounded: the oldest answers go when it grows past a few thousand.
        if (m_entries.size() > 4096) {
            for (auto e = m_entries.begin(); e != m_entries.end();) {
                if (e.key() != dir && e->answered && e->fresh.hasExpired())
                    e = m_entries.erase(e);
                else
                    ++e;
            }
            it = m_entries.find(dir);
        }
        m_queue.append(dir);
        startNext();
    }
    return it->answered ? it->probe.kind : FsKind::Kind::Unknown;
}

QString FsKindCache::canonicalOf(const QString &dir) const
{
    const auto it = m_entries.constFind(dir);
    return it != m_entries.cend() && it->answered ? it->probe.canonical : QString();
}

void FsKindCache::setProbeForTest(std::function<FsKind::Probe(const QString &)> probe)
{
    QMutexLocker lock(&g_probeMutex);
    g_probe = std::move(probe);
}

void FsKindCache::startNext()
{
    while (!m_queue.isEmpty() && m_running.size() < kMaxProbes) {
        const QString dir = m_queue.takeFirst();
        m_running.append(dir);
        auto result = std::make_shared<FsKind::Probe>();
        Workers::run(
            this, [dir, result] { *result = FsKind::probe(dir); },
            [this, dir, result] {
                m_running.removeAll(dir);
                Entry &e = m_entries[dir];
                e.probe = *result;
                e.answered = true;
                e.fresh = QDeadlineTimer(kFreshMs);
                emit known(dir);
                startNext();
            });
    }
}
