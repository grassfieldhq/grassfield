#include "filesearch.h"

#include "launchguard.h"
#include "taglogic.h"

#include <QDateTime>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QMimeDatabase>
#include <QProcess>
#include <QRegularExpression>
#include <QSet>
#include <QUrl>

#include <algorithm>
#include <cerrno>
#include <deque>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/xattr.h>

namespace
{
// Batches reach the view at least this often while matches come in, and at most this large (as the tag search).
constexpr int kBatchMs = 100;
constexpr int kBatchSize = 64;
// How often a wait on an index program looks at the cancel flag.
constexpr int kPollMs = 50;

QStringList readTags(const QByteArray &path)
{
    char value[4096];
    ssize_t n = ::lgetxattr(path.constData(), TagLogic::attributeName(), value, sizeof value);
    if (n >= 0)
        return TagLogic::parse(QByteArray(value, int(n)));
    if (errno != ERANGE)
        return {};
    const ssize_t size = ::lgetxattr(path.constData(), TagLogic::attributeName(), nullptr, 0);
    if (size <= 0 || size > 64 * 1024)
        return {};
    QByteArray big(int(size), Qt::Uninitialized);
    n = ::lgetxattr(path.constData(), TagLogic::attributeName(), big.data(), size_t(big.size()));
    return n >= 0 ? TagLogic::parse(big.left(int(n))) : QStringList();
}

QDateTime fromStatx(const struct statx_timestamp &ts)
{
    return QDateTime::fromMSecsSinceEpoch(qint64(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000);
}
} // namespace

FileSearch::FileSearch(quint64 generation, const Settings &settings)
    : m_generation(generation)
    , m_settings(settings)
{
    connect(this, &QThread::finished, this, &QObject::deleteLater);
}

std::optional<QStringList> FileSearch::runProgram(const QString &program, const QStringList &arguments, bool uris)
{
    if (program.isEmpty())
        return std::nullopt;
    QProcess process;
    process.setProgram(program);
    process.setArguments(arguments);
    process.setStandardInputFile(QProcess::nullDevice());
    process.start(QIODevice::ReadOnly);
    if (!process.waitForStarted(kProgramMs))
        return std::nullopt;
    QByteArray output;
    QByteArray errors;
    QElapsedTimer clock;
    clock.start();
    while (process.state() != QProcess::NotRunning) {
        if (cancelled() || clock.elapsed() > kProgramMs || output.size() > kMaxOutput) {
            process.kill();
            process.waitForFinished(kPollMs);
            return std::nullopt;
        }
        process.waitForReadyRead(kPollMs);
        output += process.readAllStandardOutput();
        errors += process.readAllStandardError().left(4096);
    }
    output += process.readAllStandardOutput();
    errors += process.readAllStandardError().left(4096);
    // plocate and localsearch end with 1 when nothing matched; an error (no database, no index service) says why on stderr.
    if (process.exitStatus() != QProcess::NormalExit || process.exitCode() > 1 || (process.exitCode() == 1 && !errors.trimmed().isEmpty()))
        return std::nullopt;
    QStringList paths;
    static const QRegularExpression uri(QStringLiteral("(file://\\S+)"));
    static const QRegularExpression color(QStringLiteral("\\x1b\\[[0-9;]*m"));
    for (QString line : QString::fromUtf8(output).split(QLatin1Char('\n'))) {
        if (uris) {
            line.remove(color);
            const auto m = uri.match(line);
            if (!m.hasMatch())
                continue;
            const QUrl url = QUrl::fromEncoded(m.captured(1).toUtf8());
            if (url.isLocalFile())
                paths.append(url.toLocalFile());
        } else if (line.startsWith(QLatin1Char('/'))) {
            paths.append(line);
        }
        if (paths.size() >= kMaxResults)
            break;
    }
    return paths;
}

bool FileSearch::inScope(const QString &path, const QString &base) const
{
    const QString clean = QDir::cleanPath(path);
    const QString root = QDir::cleanPath(base);
    if (!clean.startsWith(root + QLatin1Char('/')))
        return false;
    // Never what an Expand or Compress is still writing (".grassfield-expand-…": not marked yet), hidden items shown or not.
    if (LaunchGuard::insideStaging(clean.mid(root.size() + 1)))
        return false;
    if (m_settings.showHidden)
        return true;
    const QStringList segments = clean.mid(root.size() + 1).split(QLatin1Char('/'));
    return std::none_of(segments.cbegin(), segments.cend(), [](const QString &s) { return s.startsWith(QLatin1Char('.')); });
}

bool FileSearch::facts(const QByteArray &path, SearchLogic::Facts *out) const
{
    struct statx st;
    if (::statx(AT_FDCWD, path.constData(), AT_SYMLINK_NOFOLLOW, STATX_TYPE | STATX_SIZE | STATX_MTIME | STATX_ATIME | STATX_BTIME, &st) != 0)
        return false;
    // Symbolic links are never followed, and never results (the walk does not enter them either).
    if (S_ISLNK(st.stx_mode))
        return false;
    const int slash = path.lastIndexOf('/');
    out->name = QFile::decodeName(path.mid(slash + 1));
    out->isDir = S_ISDIR(st.stx_mode);
    out->size = out->isDir ? -1 : qint64(st.stx_size);
    out->modified = fromStatx(st.stx_mtime);
    out->opened = fromStatx(st.stx_atime);
    // A file system without birth times leaves Created unknown (a Created row then never holds).
    out->created = (st.stx_mask & STATX_BTIME) ? fromStatx(st.stx_btime) : QDateTime();
    if (out->isDir) {
        out->kind = FileLogic::KindCategory::Folder;
    } else {
        // The type from the name only (no read of the file): the same answer the listing gives before it looks inside.
        static thread_local QMimeDatabase mimes;
        const QMimeType type = mimes.mimeTypeForFile(out->name, QMimeDatabase::MatchExtension);
        out->kind = FileLogic::kindCategoryOf(QStringList{type.name()} + type.allAncestors(), false);
    }
    out->tags = readTags(path);
    return true;
}

void FileSearch::keep(const QString &path)
{
    m_batch.append(path);
    if (++m_matches >= kMaxResults)
        m_limited = true;
    flush(false);
}

void FileSearch::flush(bool force)
{
    if (m_batch.isEmpty())
        return;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (force || m_batch.size() >= kBatchSize || now - m_lastFlush >= kBatchMs) {
        emit found(m_generation, m_batch);
        m_batch.clear();
        m_lastFlush = now;
    }
}

void FileSearch::walk(const QString &base, const QSet<QString> *contents)
{
    const QByteArray root = QFile::encodeName(QDir::cleanPath(base));
    struct stat rootStat;
    if (root.isEmpty() || ::lstat(root.constData(), &rootStat) != 0 || !S_ISDIR(rootStat.st_mode))
        return;
    const SearchLogic::Query &query = m_settings.query;
    const bool needFacts = SearchLogic::needsFacts(query);
    const QDateTime now = QDateTime::currentDateTime();
    struct Folder {
        QByteArray path;
        int depth;
    };
    std::deque<Folder> queue{{root, 0}};
    int visited = 0;
    while (!queue.empty() && !m_limited && !cancelled()) {
        const Folder folder = queue.front();
        queue.pop_front();
        DIR *dir = ::opendir(folder.path.constData());
        if (!dir)
            continue;
        while (const dirent *entry = ::readdir(dir)) {
            if (cancelled() || m_limited)
                break;
            const char *name = entry->d_name;
            if (name[0] == '.' && (name[1] == 0 || (name[1] == '.' && name[2] == 0)))
                continue;
            if (name[0] == '.' && (!m_settings.showHidden || LaunchGuard::insideStaging(QFile::decodeName(name))))
                continue;
            if (++visited > kMaxVisited) {
                m_limited = true;
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
            if (type == DT_LNK)
                continue;
            const QString decoded = QFile::decodeName(name);
            // The name first: most entries end there without a stat.
            if (SearchLogic::textMatchesName(query.text, decoded) && (!contents || contents->contains(QFile::decodeName(path)))) {
                SearchLogic::Facts f;
                if (!needFacts || facts(path, &f)) {
                    if (!needFacts)
                        f.name = decoded;
                    if (SearchLogic::matchesCriteria(query, f, now))
                        keep(QFile::decodeName(path));
                }
            }
            if (type == DT_DIR && folder.depth < kMaxDepth && !m_limited) {
                if (::lstat(path.constData(), &st) == 0 && st.st_dev == rootStat.st_dev)
                    queue.push_back({path, folder.depth + 1});
            }
        }
        ::closedir(dir);
    }
}

void FileSearch::run()
{
    const SearchLogic::Query &query = m_settings.query;
    const QString base = query.inComputer() ? m_settings.root : query.folder.toLocalFile();
    Backend backend = Walk;

    // Contents rows: the files the index matched; without the index nothing can answer them.
    std::optional<QSet<QString>> contents;
    const QString contentsText = SearchLogic::contentsText(query);
    if (!contentsText.isEmpty()) {
        const auto matched = runProgram(m_settings.localsearch,
                                        {QStringLiteral("search"), QStringLiteral("-f"), QStringLiteral("-l"), QString::number(kMaxResults), QStringLiteral("--"), contentsText},
                                        true);
        if (cancelled())
            return;
        if (!matched) {
            emit done(m_generation, Index, false, true);
            return;
        }
        contents = QSet<QString>(matched->cbegin(), matched->cend());
        backend = Index;
    }

    if (query.inComputer()) {
        const QString term = SearchLogic::nameTerm(query);
        std::optional<QStringList> candidates;
        if (!term.isEmpty()) {
            candidates = runProgram(m_settings.localsearch,
                                    {QStringLiteral("search"), QStringLiteral("-f"), QStringLiteral("-l"), QString::number(kMaxResults), QStringLiteral("--"), term},
                                    true);
            if (candidates && !candidates->isEmpty()) {
                backend = Index;
            } else if (!cancelled()) {
                QStringList args{QStringLiteral("-i"), QStringLiteral("-b"), QStringLiteral("-l"), QString::number(kMaxResults)};
                if (!m_settings.plocateDb.isEmpty())
                    args << QStringLiteral("-d") << m_settings.plocateDb;
                args << QStringLiteral("--") << term;
                candidates = runProgram(m_settings.plocate, args, false);
                if (candidates)
                    backend = Names;
            }
        } else if (contents) {
            candidates = QStringList(contents->cbegin(), contents->cend());
        }
        if (cancelled())
            return;
        if (candidates) {
            const QDateTime now = QDateTime::currentDateTime();
            for (const QString &path : std::as_const(*candidates)) {
                if (cancelled() || m_limited)
                    break;
                if (!inScope(path, base) || (contents && !contents->contains(path)))
                    continue;
                SearchLogic::Facts f;
                if (!facts(QFile::encodeName(path), &f))
                    continue;
                // The index matched the text in the name or the contents; plocate only matched one word of it.
                if (backend == Names && !SearchLogic::textMatchesName(query.text, f.name))
                    continue;
                if (SearchLogic::matchesCriteria(query, f, now))
                    keep(path);
            }
        } else {
            backend = contents ? Index : Walk;
            walk(base, contents ? &*contents : nullptr);
        }
    } else {
        walk(base, contents ? &*contents : nullptr);
        if (!contents)
            backend = Walk;
    }
    if (cancelled())
        return;
    flush(true);
    emit done(m_generation, backend, m_limited, false);
}

FileSearchRunner::FileSearchRunner(QObject *parent)
    : QObject(parent)
{
}

FileSearchRunner::~FileSearchRunner()
{
    // The runner's owner is going away: the one place a short wait is fine (stop() never waits).
    FileSearch *search = m_search.data();
    stop();
    if (search)
        search->wait(kShutdownWaitMs);
}

void FileSearchRunner::start(const FileSearch::Settings &settings)
{
    stop();
    auto *search = new FileSearch(m_generation, settings);
    m_search = search;
    connect(search, &FileSearch::found, this, [this](quint64 generation, const QStringList &paths) {
        if (generation == m_generation)
            emit found(paths);
    });
    connect(search, &FileSearch::done, this, [this](quint64 generation, int backend, bool limited, bool contentsUnavailable) {
        if (generation != m_generation)
            return;
        m_search.clear();
        emit done(backend, limited, contentsUnavailable);
    });
    search->start(QThread::LowPriority);
}

void FileSearchRunner::stop()
{
    ++m_generation;
    FileSearch *search = m_search.data();
    m_search.clear();
    if (!search)
        return;
    disconnect(search, nullptr, this, nullptr);
    search->cancel();
    // Never waited for here: a new search starts on the GUI thread, and a walk in a slow system call (or a program poll)
    // can take longer than a frame to notice the flag. The superseded search ends by itself (it checks the flag at every
    // entry and every kPollMs), emits nothing (no connection is left) and deletes itself when its thread has finished
    // (the connection of its constructor).
}
