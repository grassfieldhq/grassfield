#include "atomicfile.h"

#include <QByteArray>
#include <QFile>
#include <QFileInfo>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace screenshot {

namespace {

QString errnoText(const char *what)
{
    return QStringLiteral("%1: %2").arg(QString::fromLatin1(what), QString::fromLocal8Bit(std::strerror(errno)));
}

} // namespace

bool atomicWrite(const QString &path, const QByteArray &bytes, int mode, QString *error, const BeforeRename &beforeRename)
{
    const auto fail = [error](const QString &why) {
        if (error)
            *error = why;
        return false;
    };
    const QFileInfo info(path);
    const QByteArray dir = QFile::encodeName(info.absolutePath());
    const QByteArray target = QFile::encodeName(info.absoluteFilePath());

    if (mode < 0) {
        struct stat st;
        mode = ::stat(target.constData(), &st) == 0 ? int(st.st_mode & 07777) : 0600;
    }

    // mkstemp: exclusive, 0600, never a name that exists (or a link planted at it).
    QByteArray hidden = dir + "/." + QFile::encodeName(info.fileName()) + ".XXXXXX";
    const int fd = ::mkstemp(hidden.data());
    if (fd < 0)
        return fail(errnoText("cannot create the temporary file"));
    const QString hiddenPath = QFile::decodeName(hidden);
    const auto abort = [&](const QString &why) {
        ::close(fd);
        ::unlink(hidden.constData());
        return fail(why);
    };

    qint64 done = 0;
    while (done < bytes.size()) {
        const ssize_t n = ::write(fd, bytes.constData() + done, size_t(bytes.size() - done));
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return abort(errnoText("cannot write the temporary file"));
        done += n;
    }
    if (::fchmod(fd, mode_t(mode)) != 0)
        return abort(errnoText("cannot set the file's mode"));
    if (::fsync(fd) != 0)
        return abort(errnoText("cannot sync the temporary file"));
    if (::close(fd) != 0) {
        ::unlink(hidden.constData());
        return fail(errnoText("cannot close the temporary file"));
    }
    if (beforeRename && !beforeRename(hiddenPath)) {
        ::unlink(hidden.constData());
        return fail(QStringLiteral("the replacement was refused"));
    }
    if (::rename(hidden.constData(), target.constData()) != 0) {
        const QString why = errnoText("cannot replace the file");
        ::unlink(hidden.constData());
        return fail(why);
    }
    // The rename is durable once its directory is synced; a failure here leaves the new file in place (reported nowhere:
    // the file is already replaced whole).
    const int dirFd = ::open(dir.constData(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dirFd >= 0) {
        ::fsync(dirFd);
        ::close(dirFd);
    }
    return true;
}

bool readPrivateFile(const QString &path, qint64 maxBytes, QByteArray *out)
{
    out->clear();
    const int fd = ::open(QFile::encodeName(path).constData(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0)
        return false;
    struct stat st;
    if (::fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != ::getuid() || (st.st_mode & 077) != 0 || st.st_size > maxBytes) {
        ::close(fd);
        return false;
    }
    QByteArray data;
    data.resize(qsizetype(st.st_size));
    qint64 done = 0;
    while (done < st.st_size) {
        const ssize_t n = ::read(fd, data.data() + done, size_t(st.st_size - done));
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            break;
        done += n;
    }
    ::close(fd);
    if (done != st.st_size)
        return false;
    *out = data;
    return true;
}

} // namespace screenshot
