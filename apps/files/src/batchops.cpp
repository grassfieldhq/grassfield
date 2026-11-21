#include "batchops.h"

#include <QFile>

#include <cerrno>
#include <cstdio>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace BatchOps
{
namespace
{
bool g_forceFallback = false;
bool g_caseInsensitiveForTest = false;
std::function<void(int)> g_stepHook;

int plainRename(const QByteArray &from, const QByteArray &to)
{
    if (!g_forceFallback) {
        if (::renameat2(AT_FDCWD, from.constData(), AT_FDCWD, to.constData(), RENAME_NOREPLACE) == 0)
            return 0;
        if (errno != EINVAL && errno != ENOSYS)
            return errno;
    }
    // A filesystem without RENAME_NOREPLACE: look first, then rename. The window between the two is a few
    // microseconds in the user's own folder, and it is what gnulib's renameatu does too; the look is what keeps a name
    // that exists from being replaced in every other case.
    struct stat st;
    if (::lstat(to.constData(), &st) == 0)
        return EEXIST;
    return ::rename(from.constData(), to.constData()) == 0 ? 0 : errno;
}

QByteArray folderOf(const QByteArray &path)
{
    const qsizetype slash = path.lastIndexOf('/');
    return slash <= 0 ? QByteArray("/") : path.left(slash);
}

QByteArray nameOf(const QByteArray &path)
{
    return path.mid(path.lastIndexOf('/') + 1);
}

// Whether the folder has an entry named exactly `name` (bytes), and an entry matching it ignoring ASCII case (the test's
// stand-in for a file system that ignores case).
void lookFor(const QByteArray &folder, const QByteArray &name, bool *exact, QByteArray *folded)
{
    *exact = false;
    DIR *dir = ::opendir(folder.constData());
    if (!dir)
        return;
    while (struct dirent *entry = ::readdir(dir)) {
        const QByteArray n(entry->d_name);
        if (n == name)
            *exact = true;
        else if (folded && folded->isEmpty() && n.compare(name, Qt::CaseInsensitive) == 0)
            *folded = n;
    }
    ::closedir(dir);
}

// The new name "is taken" by the item itself (audit F19): on a file system that ignores case (FAT, exFAT, a casefolded
// folder) "Photo.JPG" is found when "photo.jpg" is asked for, and a case-only change met EEXIST. It is a rename in place
// only when all of this holds: both names are in the same folder, the new name resolves to the very item being renamed (same
// device and inode), and the folder has no entry spelt exactly as the new name (a hard link of the item under that name is
// another entry: refused, as any taken name is). The item then goes through a free hidden name of the same folder (Linux's
// FAT and exFAT ignore a rename between two spellings of one entry), each step without replacing anything; a second step
// that fails puts the first back.
int caseOnlyRename(const QByteArray &from, const QByteArray &to)
{
    const QByteArray folder = folderOf(from);
    if (folderOf(to) != folder)
        return EEXIST;
    bool exact = false;
    QByteArray folded;
    lookFor(folder, nameOf(to), &exact, g_caseInsensitiveForTest ? &folded : nullptr);
    if (exact)
        return EEXIST;
    struct stat a;
    struct stat b;
    if (::lstat(from.constData(), &a) != 0)
        return errno;
    // The test's stand-in resolves the new name as a case-insensitive lookup would.
    const QByteArray resolved = g_caseInsensitiveForTest ? (folded.isEmpty() ? to : folder + '/' + folded) : to;
    if (::lstat(resolved.constData(), &b) != 0)
        return EEXIST;
    if (a.st_dev != b.st_dev || a.st_ino != b.st_ino)
        return EEXIST;
    QByteArray hidden;
    int error = EEXIST;
    for (int attempt = 0; attempt < 16 && error == EEXIST; ++attempt) {
        hidden = folder + "/.grassfield-rename-" + QByteArray::number(qint64(::getpid())) + '-' + QByteArray::number(attempt);
        error = plainRename(from, hidden);
    }
    if (error != 0)
        return error;
    error = plainRename(hidden, to);
    if (error != 0)
        plainRename(hidden, from);
    return error;
}

// 0 or errno.
int run(const Step &step)
{
    const QByteArray from = QFile::encodeName(step.from);
    const QByteArray to = QFile::encodeName(step.to);
    switch (step.kind) {
    case Step::Kind::Rename: {
        int error = 0;
        if (g_caseInsensitiveForTest) {
            bool exact = false;
            QByteArray folded;
            lookFor(folderOf(to), nameOf(to), &exact, &folded);
            error = exact || !folded.isEmpty() ? EEXIST : plainRename(from, to);
        } else {
            error = plainRename(from, to);
        }
        return error == EEXIST ? caseOnlyRename(from, to) : error;
    }
    case Step::Kind::Link:
        return ::symlink(from.constData(), to.constData()) == 0 ? 0 : errno;
    case Step::Kind::Unlink: {
        char buffer[4096];
        const ssize_t n = ::readlink(to.constData(), buffer, sizeof buffer - 1);
        if (n < 0)
            return errno == EINVAL ? EEXIST : errno; // not a link any more: it is not ours to remove
        if (QByteArray(buffer, int(n)) != from)
            return EEXIST;
        return ::unlink(to.constData()) == 0 ? 0 : errno;
    }
    case Step::Kind::Mkdir:
        return ::mkdir(to.constData(), 0777) == 0 ? 0 : errno;
    case Step::Kind::Rmdir:
        return ::rmdir(to.constData()) == 0 ? 0 : errno;
    }
    return EINVAL;
}

Step inverted(const Step &step)
{
    switch (step.kind) {
    case Step::Kind::Rename:
        return {Step::Kind::Rename, step.to, step.from};
    case Step::Kind::Link:
        return {Step::Kind::Unlink, step.from, step.to};
    case Step::Kind::Unlink:
        return {Step::Kind::Link, step.from, step.to};
    case Step::Kind::Mkdir:
        return {Step::Kind::Rmdir, step.from, step.to};
    case Step::Kind::Rmdir:
        return {Step::Kind::Mkdir, step.from, step.to};
    }
    return step;
}

// The item a step is about, for a message: what it makes or removes (a rename: its source).
QString itemOf(const Step &step)
{
    return step.kind == Step::Kind::Rename ? step.from : step.to;
}
} // namespace

Steps inverse(const Steps &steps)
{
    Steps out;
    out.reserve(steps.size());
    for (auto it = steps.crbegin(); it != steps.crend(); ++it)
        out.append(inverted(*it));
    return out;
}

void forceNoReplaceFallback(bool on)
{
    g_forceFallback = on;
}

void actCaseInsensitive(bool on)
{
    g_caseInsensitiveForTest = on;
}

void setStepHook(const std::function<void(int)> &hook)
{
    g_stepHook = hook;
}

bool apply(const Steps &steps, Failure *failure)
{
    for (int i = 0; i < steps.size(); ++i) {
        const int error = run(steps.at(i));
        if (error == 0) {
            if (g_stepHook)
                g_stepHook(i);
            continue;
        }
        // Revert what was done, newest first; a revert that fails stops there (nothing is forced) and what is still in
        // effect is reported.
        int stillDone = i; // steps [0, stillDone) are in effect
        while (stillDone > 0 && run(inverted(steps.at(stillDone - 1))) == 0)
            --stillDone;
        if (failure) {
            *failure = {i, itemOf(steps.at(i)), error, steps.mid(0, stillDone)};
        }
        return false;
    }
    return true;
}

} // namespace BatchOps
