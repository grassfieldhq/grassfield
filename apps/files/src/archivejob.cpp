#include "archivejob.h"

#include "archivelogic.h"
#include "filelogic.h"
#include "launchguard.h"
#include "runmode.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRandomGenerator>
#include <QStorageInfo>
#include <QThread>

#include <fcntl.h>
#include <functional>
#include <sys/file.h>
#include <unistd.h>

namespace
{
QString hiddenName(const QString &folder, const QString &prefix, const QString &suffix)
{
    for (int attempt = 0; attempt < 100; ++attempt) {
        const QString name = QStringLiteral(".grassfield-%1-%2%3").arg(prefix).arg(QRandomGenerator::global()->generate(), 8, 16, QLatin1Char('0')).arg(suffix);
        if (!QFileInfo::exists(folder + QLatin1Char('/') + name))
            return folder + QLatin1Char('/') + name;
    }
    return {};
}

qint64 freeSpace(const QString &folder)
{
    QStorageInfo info(folder);
    info.refresh();
    return info.isValid() ? info.bytesAvailable() : -1;
}

// The staging registry (ArchiveJob::stagingRegistry): who holds a staging name. A holder is this boot, a process id and that
// process's start time (field 22 of /proc/<pid>/stat), so that a process id used again by another program is no holder.
constexpr qint64 kMaxRegistry = 1024 * 1024;

QByteArray bootId()
{
    QFile f(QStringLiteral("/proc/sys/kernel/random/boot_id"));
    return f.open(QIODevice::ReadOnly) ? f.read(64).trimmed() : QByteArray();
}

QByteArray startTime(qint64 pid)
{
    QFile f(QStringLiteral("/proc/%1/stat").arg(pid));
    if (!f.open(QIODevice::ReadOnly))
        return {};
    const QByteArray stat = f.read(4096);
    const qsizetype close = stat.lastIndexOf(')');
    if (close < 0)
        return {};
    // After the command's closing parenthesis and a space: field 3 (the state) first, so field 22 is the 20th.
    const QList<QByteArray> fields = stat.mid(close + 2).split(' ');
    return fields.size() > 19 ? fields.at(19) : QByteArray();
}

QByteArray holderLine(const QString &path)
{
    static const QByteArray self = bootId() + ' ' + QByteArray::number(qint64(::getpid())) + ' ' + startTime(::getpid());
    return self + ' ' + QFile::encodeName(path).toPercentEncoding();
}

// The registry's lines, changed by `edit` under an exclusive lock (flock: Files' processes and threads in turn), written back.
bool editRegistry(const QString &file, const std::function<void(QList<QByteArray> &)> &edit)
{
    if (!QDir().mkpath(QFileInfo(file).absolutePath()))
        return false;
    const int fd = ::open(QFile::encodeName(file).constData(), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0)
        return false;
    if (::flock(fd, LOCK_EX) != 0) {
        ::close(fd);
        return false;
    }
    QByteArray content;
    char buffer[4096];
    ssize_t n = 0;
    while (content.size() < kMaxRegistry && (n = ::read(fd, buffer, sizeof buffer)) > 0)
        content.append(buffer, n);
    QList<QByteArray> lines;
    for (const QByteArray &line : content.split('\n')) {
        if (!line.isEmpty())
            lines << line;
    }
    edit(lines);
    QByteArray out;
    for (const QByteArray &line : std::as_const(lines))
        out += line + '\n';
    const bool ok = ::ftruncate(fd, 0) == 0 && ::pwrite(fd, out.constData(), size_t(out.size()), 0) == ssize_t(out.size());
    ::close(fd); // and the lock with it
    return ok;
}
} // namespace

ArchiveJob::ArchiveJob(Kind kind, const QString &bsdtar, QObject *parent)
    : QObject(parent)
    , m_kind(kind)
    , m_bsdtar(bsdtar)
{
    m_poll.setInterval(kPollMs);
    connect(&m_poll, &QTimer::timeout, this, [this] {
        const qint64 free = freeSpace(m_folder);
        if (free >= 0 && free < kFreeMargin)
            fail(tr("There isn’t enough space on the disk: “%1” was stopped.").arg(FileLogic::displayName(subject())));
    });
}

ArchiveJob *ArchiveJob::compress(const QString &bsdtar, const QString &folder, const QStringList &names, QObject *parent)
{
    auto *job = new ArchiveJob(Kind::Compress, bsdtar, parent);
    job->m_folder = folder;
    job->m_names = names;
    return job;
}

ArchiveJob *ArchiveJob::expand(const QString &bsdtar, const QString &archive, QObject *parent)
{
    auto *job = new ArchiveJob(Kind::Expand, bsdtar, parent);
    job->m_archive = archive;
    job->m_folder = QFileInfo(archive).absolutePath();
    return job;
}

ArchiveJob::~ArchiveJob()
{
    stopMarking();
    if (!m_done) {
        m_done = true;
        if (m_process) {
            m_process->disconnect(this);
            m_process->kill();
            m_process->waitForFinished(1000);
        }
        cleanUp();
    }
}

QString ArchiveJob::stagingRegistry()
{
    return grassfield::apps::runmode::stateDir() + QStringLiteral("/files-staging");
}

int ArchiveJob::sweepStaleStaging(const QString &registry)
{
    const QString file = registry.isEmpty() ? stagingRegistry() : registry;
    if (!QFileInfo::exists(file))
        return 0;
    const QByteArray boot = bootId();
    QStringList stale;
    editRegistry(file, [&boot, &stale](QList<QByteArray> &lines) {
        for (auto it = lines.begin(); it != lines.end();) {
            const QList<QByteArray> fields = it->split(' ');
            bool held = false;
            if (fields.size() == 4 && !boot.isEmpty() && fields.at(0) == boot && !fields.at(2).isEmpty()) {
                bool ok = false;
                const qint64 pid = fields.at(1).toLongLong(&ok);
                held = ok && pid > 0 && startTime(pid) == fields.at(2);
            }
            if (held) {
                ++it;
                continue;
            }
            if (fields.size() == 4)
                stale << QFile::decodeName(QByteArray::fromPercentEncoding(fields.at(3)));
            it = lines.erase(it);
        }
    });
    int removed = 0;
    for (const QString &path : std::as_const(stale)) {
        if (!QDir::isAbsolutePath(path) || !LaunchGuard::insideStaging(QFileInfo(path).fileName()))
            continue;
        if (LaunchGuard::removeTree(path))
            ++removed;
        else
            qInfo("grassfield-files: a staging item left by an earlier Files could not be removed entirely");
    }
    return removed;
}

void ArchiveJob::setTemp(const QString &path)
{
    m_temp = path;
    const QByteArray line = holderLine(path);
    editRegistry(stagingRegistry(), [&line](QList<QByteArray> &lines) {
        lines << line;
    });
}

void ArchiveJob::forgetTemp()
{
    if (m_temp.isEmpty())
        return;
    const QByteArray line = holderLine(m_temp);
    editRegistry(stagingRegistry(), [&line](QList<QByteArray> &lines) {
        lines.removeAll(line);
    });
    m_temp.clear();
}

QString ArchiveJob::subject() const
{
    if (m_kind == Kind::Expand)
        return QFileInfo(m_archive).fileName();
    return m_names.size() == 1 ? m_names.first() + QStringLiteral(".zip") : QStringLiteral("Archive.zip");
}

void ArchiveJob::start()
{
    if (m_bsdtar.isEmpty()) {
        fail(tr("Compress and Expand need bsdtar (libarchive), which isn’t installed."));
        return;
    }
    if (m_kind == Kind::Compress) {
        const QString temp = hiddenName(m_folder, QStringLiteral("compress"), QStringLiteral(".zip"));
        if (temp.isEmpty()) {
            fail(tr("“%1” can’t be created here.").arg(FileLogic::displayName(subject())));
            return;
        }
        setTemp(temp);
        m_poll.start();
        run(ArchiveLogic::compressArgs(m_temp, m_folder, m_names));
        return;
    }
    m_listing = true;
    run(ArchiveLogic::listArgs(m_archive));
    QTimer::singleShot(kListMs, this, [this] {
        if (m_listing && !m_done)
            fail(tr("“%1” takes too long to read.").arg(FileLogic::displayName(subject())));
    });
}

void ArchiveJob::run(const QStringList &args)
{
    m_output.clear();
    m_errors.clear();
    m_process = new QProcess(this);
    m_process->setProgram(m_bsdtar);
    m_process->setArguments(args);
    m_process->setWorkingDirectory(m_folder);
    m_process->setStandardInputFile(QProcess::nullDevice());
    connect(m_process, &QProcess::readyReadStandardOutput, this, [this] {
        m_output += m_process->readAllStandardOutput();
        if (m_output.size() > kMaxListing)
            fail(tr("“%1” lists too many items.").arg(FileLogic::displayName(subject())));
    });
    connect(m_process, &QProcess::readyReadStandardError, this, [this] {
        // Only the start matters (the failure's reason).
        if (m_errors.size() < 64 * 1024)
            m_errors += m_process->readAllStandardError();
    });
    connect(m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            fail(tr("Compress and Expand need bsdtar (libarchive), which can’t be started."));
    });
    connect(m_process, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) {
        if (m_done)
            return;
        m_output += m_process->readAllStandardOutput();
        if (status != QProcess::NormalExit || code != 0) {
            fail(failureText(m_kind == Kind::Compress ? tr("“%1” couldn’t be created.").arg(FileLogic::displayName(subject()))
                                                      : tr("“%1” couldn’t be expanded.").arg(FileLogic::displayName(subject()))));
            return;
        }
        m_process->deleteLater();
        m_process = nullptr;
        if (m_kind == Kind::Compress)
            compressed();
        else if (m_listing)
            listed();
        else
            extracted();
    });
    m_process->start();
}

QString ArchiveJob::failureText(const QString &fallback) const
{
    const QString errors = QString::fromLocal8Bit(m_errors).trimmed();
    if (ArchiveLogic::failureOf(errors) == ArchiveLogic::Failure::Encrypted)
        return tr("“%1” is protected by a password: Files can’t expand it.").arg(FileLogic::displayName(subject()));
    const QString first = errors.section(QLatin1Char('\n'), 0, 0).left(200);
    return first.isEmpty() ? fallback : fallback + QLatin1Char(' ') + first;
}

void ArchiveJob::listed()
{
    m_listing = false;
    const auto size = ArchiveLogic::listedSize(QString::fromLocal8Bit(m_output));
    const qint64 free = freeSpace(m_folder);
    if (size && free >= 0 && *size > free - kFreeMargin) {
        fail(tr("There isn’t enough space on the disk to expand “%1”.").arg(FileLogic::displayName(subject())));
        return;
    }
    const QString temp = hiddenName(m_folder, QStringLiteral("expand"), QString());
    if (!temp.isEmpty())
        setTemp(temp); // recorded before it exists: a Files killed right after the mkdir leaves a line for the next sweep
    if (temp.isEmpty() || !QDir().mkdir(m_temp)) {
        forgetTemp();
        fail(tr("“%1” can’t be expanded here.").arg(FileLogic::displayName(subject())));
        return;
    }
    m_poll.start();
    run(ArchiveLogic::expandArgs(m_archive, m_temp));
}

void ArchiveJob::extracted()
{
    m_poll.stop();
    const QStringList top = QDir(m_temp).entryList(QDir::AllEntries | QDir::Hidden | QDir::System | QDir::NoDotAndDotDot, QDir::Name);
    if (top.isEmpty()) {
        fail(tr("“%1” holds nothing to expand.").arg(FileLogic::displayName(subject())));
        return;
    }
    // The Archive Utility model: what came from the Internet inside an archive still did. bsdtar drops the archive's
    // extended attributes (--no-xattrs) but keeps its members' execute bits, so the archive's download marks are copied onto
    // every extracted regular file in the private staging folder, before anything gets a real name, on a worker thread (a
    // large tree takes seconds). Fail closed: one file left without them and nothing is kept (finishExpand).
    const LaunchGuard::DownloadMarks marks = LaunchGuard::downloadMarks(m_archive);
    if (!marks.any()) {
        finishExpand(top);
        return;
    }
    const QString temp = m_temp;
    const qint64 cap = s_markCap;
    const std::shared_ptr<std::atomic_bool> stop = m_stop;
    const auto result = std::make_shared<LaunchGuard::TreeMarks>();
    m_marking = QThread::create([temp, marks, cap, stop, result] {
        *result = LaunchGuard::markTree(temp, marks, cap, [stop](qint64) { return !stop->load(); });
    });
    m_marking->setParent(this); // destroyed with the job, after stopMarking() waited for it
    connect(m_marking, &QThread::finished, this, [this, top, result] {
        m_marking->deleteLater();
        m_marking = nullptr;
        if (m_done)
            return; // canceled meanwhile (fail() waited for the worker and cleaned up)
        if (!result->complete) {
            qInfo("grassfield-files: expand refused: the download marks could not be copied onto every file (%lld marked, %lld entries)",
                  static_cast<long long>(result->files), static_cast<long long>(result->entries));
            m_unsafe = true;
            fail(tr("“%1” couldn’t be expanded safely.").arg(FileLogic::displayName(subject())));
            return;
        }
        finishExpand(top);
    });
    m_marking->start();
}

void ArchiveJob::finishExpand(const QStringList &top)
{
    const auto exists = [this](const QString &name) { return QFileInfo::exists(m_folder + QLatin1Char('/') + name) || QFileInfo(m_folder + QLatin1Char('/') + name).isSymLink(); };
    const QString name = ArchiveLogic::expandName(QFileInfo(m_archive).fileName(), top, exists);
    const QString target = m_folder + QLatin1Char('/') + name;
    bool ok;
    if (top.size() == 1) {
        ok = QDir().rename(m_temp + QLatin1Char('/') + top.first(), target);
        if (ok)
            QDir().rmdir(m_temp);
    } else {
        ok = QDir().rename(m_temp, target);
    }
    if (!ok) {
        fail(tr("“%1” couldn’t be expanded.").arg(FileLogic::displayName(subject())));
        return;
    }
    forgetTemp();
    m_done = true;
    emit finished(true, QString(), target);
}

void ArchiveJob::compressed()
{
    m_poll.stop();
    const QString name = ArchiveLogic::compressName(m_names, [this](const QString &n) { return QFileInfo::exists(m_folder + QLatin1Char('/') + n); });
    const QString target = m_folder + QLatin1Char('/') + name;
    if (!QDir().rename(m_temp, target)) {
        fail(tr("“%1” couldn’t be created.").arg(FileLogic::displayName(name)));
        return;
    }
    forgetTemp();
    m_done = true;
    emit finished(true, QString(), target);
}

void ArchiveJob::stopMarking()
{
    // The marking worker stops at its next entry; the staging folder is only removed once it has.
    if (!m_marking)
        return;
    m_stop->store(true);
    m_marking->wait();
}

void ArchiveJob::cancel()
{
    if (m_done)
        return;
    fail(QString());
}

void ArchiveJob::fail(const QString &error)
{
    if (m_done)
        return;
    m_done = true;
    m_poll.stop();
    stopMarking();
    if (m_process) {
        m_process->disconnect(this);
        m_process->kill();
        m_process->waitForFinished(1000);
        m_process->deleteLater();
        m_process = nullptr;
    }
    cleanUp();
    emit finished(false, error, QString());
}

void ArchiveJob::cleanUp()
{
    if (m_temp.isEmpty())
        return;
    // Only the job's own hidden temporary name (".grassfield-compress-…" or ".grassfield-expand-…" in the folder).
    const QFileInfo info(m_temp);
    if (info.fileName().startsWith(QStringLiteral(".grassfield-")) && QFileInfo(info.absolutePath()) == QFileInfo(m_folder)
        && !LaunchGuard::removeTree(m_temp)) {
        // By descriptor, no link followed, each folder opened up first (an archive's 0100 or 0500 folders), a tree deeper
        // than PATH_MAX too. What stays keeps its line: the next Files to start tries again (sweepStaleStaging).
        qInfo("grassfield-files: a staging item could not be removed entirely");
        m_temp.clear();
        return;
    }
    forgetTemp();
}
