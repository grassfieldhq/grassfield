#include "tagsearch.h"

#include "taglogic.h"

#include <QElapsedTimer>
#include <QFile>

#include <algorithm>
#include <cerrno>
#include <deque>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/xattr.h>

namespace
{
// Batches reach the view at least this often while matches come in, and at most this large.
constexpr int kBatchMs = 100;
constexpr int kBatchSize = 64;
} // namespace

TagSearch::TagSearch(quint64 generation, const QString &root, const QString &tag, bool showHidden)
    : m_generation(generation)
    , m_root(QFile::encodeName(root))
    , m_tag(tag)
    , m_showHidden(showHidden)
{
    connect(this, &QThread::finished, this, &QObject::deleteLater);
}

bool TagSearch::tagged(const QByteArray &path) const
{
    char value[4096];
    ssize_t n = ::lgetxattr(path.constData(), TagLogic::attributeName(), value, sizeof value);
    if (n >= 0)
        return TagLogic::hasTag(TagLogic::parse(QByteArray(value, int(n))), m_tag);
    if (errno != ERANGE)
        return false;
    const ssize_t size = ::lgetxattr(path.constData(), TagLogic::attributeName(), nullptr, 0);
    if (size <= 0 || size > 64 * 1024)
        return false;
    QByteArray big(int(size), Qt::Uninitialized);
    n = ::lgetxattr(path.constData(), TagLogic::attributeName(), big.data(), size_t(big.size()));
    return n >= 0 && TagLogic::hasTag(TagLogic::parse(big.left(int(n))), m_tag);
}

void TagSearch::run()
{
    struct stat rootStat;
    if (m_root.isEmpty() || ::lstat(m_root.constData(), &rootStat) != 0 || !S_ISDIR(rootStat.st_mode)) {
        if (!cancelled())
            emit done(m_generation, false, 0);
        return;
    }
    struct Folder {
        QByteArray path;
        int depth;
    };
    std::deque<Folder> queue{{m_root, 0}};
    QStringList batch;
    QElapsedTimer sinceFlush;
    sinceFlush.start();
    int visited = 0;
    int matches = 0;
    bool limited = false;

    while (!queue.empty() && !limited && !cancelled()) {
        const Folder folder = queue.front();
        queue.pop_front();
        DIR *dir = ::opendir(folder.path.constData());
        if (!dir)
            continue;
        while (const dirent *entry = ::readdir(dir)) {
            if (cancelled())
                break;
            const char *name = entry->d_name;
            if (name[0] == '.' && (name[1] == 0 || (name[1] == '.' && name[2] == 0)))
                continue;
            if (name[0] == '.' && !m_showHidden)
                continue;
            if (++visited > kMaxVisited) {
                limited = true;
                break;
            }
            const QByteArray path = folder.path.endsWith('/') ? folder.path + name : folder.path + '/' + name;
            unsigned char type = entry->d_type;
            struct stat st;
            if (type == DT_UNKNOWN) {
                if (::lstat(path.constData(), &st) != 0)
                    continue;
                type = S_ISDIR(st.st_mode) ? DT_DIR : S_ISLNK(st.st_mode) ? DT_LNK : DT_REG;
            }
            // Links carry no user attributes on Linux and are never followed (no loops, no walk outside the tree).
            if (type == DT_LNK)
                continue;
            if (tagged(path)) {
                batch.append(QFile::decodeName(path));
                if (++matches >= kMaxResults)
                    limited = true;
            }
            if (type == DT_DIR && folder.depth < kMaxDepth && !limited) {
                if (::lstat(path.constData(), &st) == 0 && st.st_dev == rootStat.st_dev)
                    queue.push_back({path, folder.depth + 1});
            }
            if (!batch.isEmpty() && (batch.size() >= kBatchSize || sinceFlush.elapsed() >= kBatchMs)) {
                emit found(m_generation, batch);
                batch.clear();
                sinceFlush.restart();
            }
            if (limited)
                break;
        }
        ::closedir(dir);
    }
    if (cancelled())
        return;
    if (!batch.isEmpty())
        emit found(m_generation, batch);
    emit done(m_generation, limited, std::min(visited, kMaxVisited));
}

SearchRunner::SearchRunner(QObject *parent)
    : QObject(parent)
{
}

SearchRunner::~SearchRunner()
{
    stop();
}

void SearchRunner::start(const QString &root, const QString &tag, bool showHidden)
{
    stop();
    auto *search = new TagSearch(m_generation, root, tag, showHidden);
    m_search = search;
    connect(search, &TagSearch::found, this, &SearchRunner::onFound);
    connect(search, &TagSearch::done, this, &SearchRunner::onDone);
    Workers::track(search); // joined, bounded, at quit
    search->start(QThread::LowPriority);
}

void SearchRunner::stop()
{
    // A new generation first: calls from the old worker that are already queued carry the old number.
    ++m_generation;
    TagSearch *search = m_search.data();
    m_search.clear();
    if (!search)
        return;
    disconnect(search, nullptr, this, nullptr);
    search->cancel();
    // Never waited for here (as FileSearchRunner::stop): this runs on the GUI thread, and a walk stuck in a slow system
    // call held the navigation back. The walk checks the flag at every entry, emits nothing more (no connection is left)
    // and deletes itself when its thread has finished (the connection of its constructor).
}

void SearchRunner::onFound(quint64 generation, const QStringList &paths)
{
    if (generation == m_generation)
        emit found(paths);
}

void SearchRunner::onDone(quint64 generation, bool limited, int visited)
{
    if (generation != m_generation)
        return;
    m_search.clear();
    emit done(limited, visited);
}
