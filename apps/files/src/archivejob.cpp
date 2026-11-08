#include "archivejob.h"

#include "archivelogic.h"
#include "filelogic.h"
#include "launchguard.h"

#include <QDir>
#include <QFileInfo>
#include <QRandomGenerator>
#include <QStorageInfo>

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
        m_temp = hiddenName(m_folder, QStringLiteral("compress"), QStringLiteral(".zip"));
        if (m_temp.isEmpty()) {
            fail(tr("“%1” can’t be created here.").arg(FileLogic::displayName(subject())));
            return;
        }
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
    m_temp = hiddenName(m_folder, QStringLiteral("expand"), QString());
    if (m_temp.isEmpty() || !QDir().mkdir(m_temp)) {
        m_temp.clear();
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
    // every extracted regular file (O_NOFOLLOW, no link followed) before anything gets a real name; LaunchGuard then asks.
    const LaunchGuard::DownloadMarks marks = LaunchGuard::downloadMarks(m_archive);
    if (marks.any())
        LaunchGuard::markTree(m_temp, marks);
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
    m_temp.clear();
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
    m_temp.clear();
    m_done = true;
    emit finished(true, QString(), target);
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
    if (info.fileName().startsWith(QStringLiteral(".grassfield-")) && QFileInfo(info.absolutePath()) == QFileInfo(m_folder)) {
        if (info.isDir() && !info.isSymLink())
            QDir(m_temp).removeRecursively();
        else
            QFile::remove(m_temp);
    }
    m_temp.clear();
}
