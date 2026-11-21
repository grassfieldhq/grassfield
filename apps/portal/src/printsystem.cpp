#include "printsystem.h"

#include <QDeadlineTimer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRandomGenerator>
#include <QThread>
#include <QTimer>

#include <cups/cups.h>

#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstring>

namespace grassfield::portal {

using print::Capabilities;
using print::Destination;
using print::Media;

struct CupsPrintSystem::Call {
    // Set by the deadline, the destructor or a stop (submit's Stop); libcups reads it (cupsEnumDests, cupsConnectDest) and the
    // workers between steps. An atomic int (SP-17: written on the GUI thread, read on the worker): libcups takes an int *, which
    // cancelFlag() gives it, the atomic having exactly an int's representation (checked below); a worker that reads it late
    // does one more step, bounded by its own limits.
    std::atomic<int> cancel{0};
    std::atomic<bool> answered{false};
    QThread *thread = nullptr;
    QList<Destination> destinations;
    bool ok = false;
    Capabilities capabilities;
    QString error;
};

namespace {

static_assert(sizeof(std::atomic<int>) == sizeof(int) && alignof(std::atomic<int>) == alignof(int) && std::atomic<int>::is_always_lock_free,
              "libcups reads the cancel flag through an int *");

// The cancel flag as libcups' API takes it.
int *cancelFlag(std::atomic<int> &cancel)
{
    return reinterpret_cast<int *>(&cancel);
}

QString fromUtf8(const char *s)
{
    return s ? QString::fromUtf8(s) : QString();
}

// The destination named `name`, from the scheduler and the printers it knows (a copy the caller frees), or null.
cups_dest_t *findDestination(const QString &name, int msec, int *cancel)
{
    struct Found {
        QByteArray name;
        cups_dest_t *dest = nullptr;
        int count = 0;
    } found{name.toUtf8(), nullptr, 0};
    cupsEnumDests(
        CUPS_DEST_FLAGS_NONE, msec, cancel, 0, 0,
        [](void *data, unsigned flags, cups_dest_t *dest) -> int {
            auto *f = static_cast<Found *>(data);
            if (flags & CUPS_DEST_FLAGS_REMOVED)
                return 1;
            if (!dest->instance && f->name == dest->name) {
                f->count = cupsCopyDest(dest, f->count, &f->dest);
                return 0; // found: stop
            }
            return 1;
        },
        &found);
    return found.dest;
}

// Stops a request that waits longer than its limit (httpSetTimeout's callback: 0 stops).
int stopWaiting(http_t *, void *)
{
    return 0;
}

Media mediaOf(http_t *http, cups_dest_t *dest, cups_dinfo_t *info, cups_size_t &size)
{
    Media m;
    m.name = fromUtf8(size.media);
    m.displayName = fromUtf8(cupsLocalizeDestMedia(http, dest, info, CUPS_MEDIA_FLAGS_DEFAULT, &size));
    if (m.displayName.isEmpty() || m.displayName == m.name)
        m.displayName = print::mediaDisplayName(m.name);
    m.widthMm = size.width / 100.0;
    m.heightMm = size.length / 100.0;
    m.topMm = size.top / 100.0;
    m.bottomMm = size.bottom / 100.0;
    m.leftMm = size.left / 100.0;
    m.rightMm = size.right / 100.0;
    return m;
}

// A value of an IPP attribute as CUPS takes it back in an option: a keyword as it is, an enum as its number.
QString optionValue(ipp_attribute_t *attribute, int index)
{
    const ipp_tag_t tag = ippGetValueTag(attribute);
    if (tag == IPP_TAG_ENUM || tag == IPP_TAG_INTEGER)
        return QString::number(ippGetInteger(attribute, index));
    if (tag == IPP_TAG_KEYWORD)
        return fromUtf8(ippGetString(attribute, index, nullptr));
    return {};
}

// The printer's own options the sheet shows (print::printerOptionNames), each with two values or more (step 6b): the values it
// lists, as CUPS names them (CUPS localizes a queue's own names; an enum CUPS does not name gets its keyword in words), the one
// shown first (the user's own, lpoptions, else the queue's, else the first), and the queue's own default apart (<name>-default,
// or for the paper's source and type media-col-default's): only a value that differs from it goes with a job (the
// counter-review of step 6b, MINOR 1: the user's lpoptions value must go, libcups does not add it).
QList<print::PrinterOption> printerOptions(http_t *http, cups_dest_t *dest, cups_dinfo_t *info, const std::atomic<int> &cancel)
{
    QList<print::PrinterOption> out;
    for (const QString &name : print::printerOptionNames()) {
        if (cancel.load())
            break;
        const QByteArray n = name.toLatin1();
        ipp_attribute_t *supported = cupsFindDestSupported(http, dest, info, n.constData());
        if (!supported)
            continue;
        const ipp_tag_t tag = ippGetValueTag(supported);
        print::PrinterOption option;
        option.name = name;
        for (int i = 0; i < ippGetCount(supported) && i < 64; ++i) {
            const QString value = optionValue(supported, i);
            if (!print::validOptionValue(value) || option.lists(value))
                continue;
            const QByteArray v = value.toUtf8();
            const QString keyword = tag == IPP_TAG_ENUM ? fromUtf8(ippEnumString(n.constData(), ippGetInteger(supported, i))) : value;
            QString label = fromUtf8(cupsLocalizeDestValue(http, dest, info, n.constData(), v.constData())).simplified();
            if (label.isEmpty() || label == value)
                label = print::keywordLabel(keyword);
            option.values.append({value, label.left(100), print::validOptionValue(keyword) ? keyword : QString()});
        }
        if (option.values.size() < 2)
            continue;
        QString own = fromUtf8(cupsGetOption(n.constData(), dest->num_options, dest->options));
        if (!option.lists(own))
            own.clear();
        QString queue;
        if (ipp_attribute_t *given = cupsFindDestDefault(http, dest, info, n.constData()))
            queue = optionValue(given, 0);
        else if (name == QLatin1String("media-source") || name == QLatin1String("media-type")) {
            ipp_attribute_t *media = cupsFindDestDefault(http, dest, info, "media-col");
            ipp_t *collection = media && ippGetValueTag(media) == IPP_TAG_BEGIN_COLLECTION ? ippGetCollection(media, 0) : nullptr;
            if (ipp_attribute_t *member = collection ? ippFindAttribute(collection, n.constData(), IPP_TAG_ZERO) : nullptr)
                queue = optionValue(member, 0);
        }
        if (!option.lists(queue))
            queue.clear();
        option.defaultValue = !own.isEmpty() ? own : !queue.isEmpty() ? queue : option.values.first().value;
        // What the queue does with no value: its own default; with none reported, the first value when the user named none (the
        // sheet shows it and it goes unsent), else nothing (the user's value goes).
        option.queueDefault = !queue.isEmpty() ? queue : own.isEmpty() ? option.values.first().value : QString();
        out.append(option);
    }
    return out;
}

// The document's first bytes, until there are enough to tell its type (five) or it ends.
QByteArray readHead(int fd, int idleMs, const std::function<bool()> &stopped, QString *error)
{
    QByteArray head;
    char buffer[65536];
    while (head.size() < 5) {
        const ssize_t n = readChunk(fd, buffer, sizeof buffer, idleMs, stopped, error);
        if (n <= 0)
            break;
        head.append(buffer, qsizetype(n));
    }
    return head;
}

bool writeAll(int fd, const char *data, size_t size)
{
    while (size > 0) {
        const ssize_t n = ::write(fd, data, size);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return false;
        data += n;
        size -= size_t(n);
    }
    return true;
}

QString errnoText(int error)
{
    return QString::fromLocal8Bit(std::strerror(error));
}

// The folder at `path` (absolute, its links resolved when the user chose it) opened one folder at a time from "/", never
// following a link: a link put since then in place of the folder or of one above it fails the open (ELOOP, ENOTDIR) instead of
// leading the file elsewhere (integrator security review of step 6a, MAJOR 1). -1 and `error` set when it cannot be opened.
int openFolder(const QString &path, QString *error)
{
    const QByteArray encoded = QFile::encodeName(path);
    if (!encoded.startsWith('/')) {
        *error = QStringLiteral("the folder “%1” is not an absolute path").arg(path);
        return -1;
    }
    QList<QByteArray> parts = encoded.split('/');
    parts.removeAll(QByteArray());
    int dir = ::open("/", O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (dir < 0) {
        *error = QStringLiteral("cannot open the folder “/”: %1").arg(errnoText(errno));
        return -1;
    }
    for (qsizetype i = 0; i < parts.size(); ++i) {
        if (parts.at(i) == "." || parts.at(i) == "..") {
            ::close(dir);
            *error = QStringLiteral("the folder “%1” is not a plain path").arg(path);
            return -1;
        }
        // Only as places (O_PATH): a folder one may write in but not list (0300, a drop box) is written in as before.
        const int next = ::openat(dir, parts.at(i).constData(), O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        const int saved = errno;
        ::close(dir);
        if (next < 0) {
            *error = saved == ELOOP || saved == ENOTDIR ? QStringLiteral("the folder “%1” changed since it was chosen").arg(path)
                                                         : QStringLiteral("cannot open the folder “%1”: %2").arg(path, errnoText(saved));
            return -1;
        }
        struct stat st;
        if (::fstat(next, &st) != 0 || !S_ISDIR(st.st_mode)) {
            ::close(next);
            *error = QStringLiteral("the folder “%1” changed since it was chosen").arg(path);
            return -1;
        }
        dir = next;
    }
    return dir;
}

} // namespace

ssize_t readChunk(int fd, char *into, size_t size, int idleMs, const std::function<bool()> &stopped, QString *error)
{
    QDeadlineTimer silence(idleMs);
    for (;;) {
        if (stopped && stopped()) {
            *error = QStringLiteral("cancelled");
            return -1;
        }
        pollfd p{fd, POLLIN, 0};
        const int ready = ::poll(&p, 1, int(std::min<qint64>(200, std::max<qint64>(0, silence.remainingTime()))));
        if (ready < 0 && errno == EINTR)
            continue;
        if (ready == 0 && !silence.hasExpired())
            continue;
        if (ready <= 0) {
            *error = QStringLiteral("the document stopped coming");
            return -1;
        }
        const ssize_t n = ::read(fd, into, size);
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0) {
            *error = QStringLiteral("cannot read the document");
            return -1;
        }
        return n;
    }
}

CupsPrintSystem::CupsPrintSystem(QObject *parent)
    : CupsPrintSystem(Limits{}, parent)
{
}

CupsPrintSystem::CupsPrintSystem(const Limits &limits, QObject *parent)
    : PrintSystem(parent)
    , m_limits(limits)
{
}

CupsPrintSystem::~CupsPrintSystem()
{
    for (const auto &call : std::as_const(m_calls))
        call->cancel.store(1);
    QDeadlineTimer deadline(3500);
    for (const auto &call : std::as_const(m_calls)) {
        if (call->thread && !call->thread->wait(deadline)) {
            // Still inside libcups: it ends on its own (its limits bound it); its QThread is left, never destroyed running.
            call->thread->setParent(nullptr);
            call->thread = nullptr;
        }
    }
}

std::shared_ptr<CupsPrintSystem::Call> CupsPrintSystem::run(int deadlineMs, std::function<void(Call &)> work, std::function<void(Call &)> deliver,
                                                            std::function<void()> timeout)
{
    auto call = std::make_shared<Call>();
    // The worker holds the call (its result and cancel flag) as long as it runs, whatever happens to this object.
    call->thread = QThread::create([call, work] { work(*call); });
    call->thread->setParent(this);
    m_calls.append(call);
    connect(call->thread, &QThread::finished, this, [this, call, deliver] {
        m_calls.removeOne(call);
        if (call->thread) {
            call->thread->deleteLater();
            call->thread = nullptr;
        }
        if (!call->answered.exchange(true))
            deliver(*call);
    });
    if (deadlineMs > 0) {
        QTimer::singleShot(deadlineMs, this, [call, timeout] {
            call->cancel.store(1);
            if (!call->answered.exchange(true))
                timeout();
        });
    }
    call->thread->start();
    return call;
}

void CupsPrintSystem::destinations(QObject *context, DestinationsDone done)
{
    const QPointer<QObject> guard(context);
    const int msec = m_limits.listMs;
    run(
        msec + 2000,
        [msec](Call &call) {
            struct List {
                QList<Destination> out;
            } list;
            // Local queues come at once; a printer CUPS finds on the network within msec.
            const int ok = cupsEnumDests(
                CUPS_DEST_FLAGS_NONE, msec, cancelFlag(call.cancel), 0, 0,
                [](void *data, unsigned flags, cups_dest_t *dest) -> int {
                    auto *l = static_cast<List *>(data);
                    if (dest->instance)
                        return 1; // lpoptions' instances are one printer's settings, not printers
                    const QString name = fromUtf8(dest->name);
                    for (qsizetype i = 0; i < l->out.size(); ++i) {
                        if (l->out.at(i).name == name) {
                            if (flags & CUPS_DEST_FLAGS_REMOVED)
                                l->out.removeAt(i);
                            return 1;
                        }
                    }
                    if (flags & CUPS_DEST_FLAGS_REMOVED)
                        return 1;
                    Destination d;
                    d.name = name;
                    d.displayName = fromUtf8(cupsGetOption("printer-info", dest->num_options, dest->options)).simplified();
                    if (d.displayName.isEmpty())
                        d.displayName = name;
                    d.location = fromUtf8(cupsGetOption("printer-location", dest->num_options, dest->options)).simplified();
                    d.isDefault = dest->is_default != 0;
                    l->out.append(d);
                    return l->out.size() < 256 ? 1 : 0;
                },
                &list);
            call.destinations = list.out;
            call.ok = ok != 0 || !list.out.isEmpty();
        },
        [guard, done](Call &call) {
            if (guard)
                done(call.destinations, call.ok);
        },
        [guard, done] {
            if (guard)
                done({}, false);
        });
}

void CupsPrintSystem::capabilities(const QString &printer, QObject *context, CapabilitiesDone done)
{
    const QPointer<QObject> guard(context);
    const int msec = m_limits.capabilitiesMs;
    run(
        msec + 2000,
        [printer, msec](Call &call) {
            cups_dest_t *dest = findDestination(printer, msec / 2, cancelFlag(call.cancel));
            if (!dest || call.cancel.load())
                return cupsFreeDests(dest ? 1 : 0, dest);
            char resource[1024] = {};
            http_t *http = cupsConnectDest(dest, CUPS_DEST_FLAGS_NONE, msec / 2, cancelFlag(call.cancel), resource, sizeof resource, nullptr, nullptr);
            if (!http) {
                cupsFreeDests(1, dest);
                return;
            }
            httpSetTimeout(http, msec / 1000.0, stopWaiting, nullptr);
            if (cups_dinfo_t *info = call.cancel.load() ? nullptr : cupsCopyDestInfo(http, dest)) {
                Capabilities caps;
                const int count = cupsGetDestMediaCount(http, dest, info, CUPS_MEDIA_FLAGS_DEFAULT);
                for (int i = 0; i < count && i < 200 && !call.cancel.load(); ++i) {
                    cups_size_t size;
                    if (cupsGetDestMediaByIndex(http, dest, info, i, CUPS_MEDIA_FLAGS_DEFAULT, &size) && size.width > 0 && size.length > 0) {
                        const Media m = mediaOf(http, dest, info, size);
                        if (!print::findMedia(caps.media, m.name).name.isEmpty())
                            continue;
                        caps.media.append(m);
                    }
                }
                // The user's own default for this printer (lpoptions), else the printer's (media-default): libcups 2.4's
                // cupsGetDestMediaDefault reads only the first and falls back to US Letter, whatever the printer says.
                if (const char *own = cupsGetOption(CUPS_MEDIA, dest->num_options, dest->options))
                    caps.defaultMedia = fromUtf8(own);
                if (caps.defaultMedia.isEmpty()) {
                    if (ipp_attribute_t *given = cupsFindDestDefault(http, dest, info, CUPS_MEDIA))
                        caps.defaultMedia = fromUtf8(ippGetString(given, 0, nullptr));
                }
                cups_size_t size;
                if (caps.defaultMedia.isEmpty() && cupsGetDestMediaDefault(http, dest, info, CUPS_MEDIA_FLAGS_DEFAULT, &size))
                    caps.defaultMedia = fromUtf8(size.media);
                caps.twoSided = cupsCheckDestSupported(http, dest, info, CUPS_SIDES, CUPS_SIDES_TWO_SIDED_PORTRAIT) != 0;
                caps.color = cupsCheckDestSupported(http, dest, info, CUPS_PRINT_COLOR_MODE, CUPS_PRINT_COLOR_MODE_COLOR) != 0;
                if (ipp_attribute_t *copies = cupsFindDestSupported(http, dest, info, CUPS_COPIES);
                    copies && ippGetValueTag(copies) == IPP_TAG_RANGE) {
                    int upper = 0;
                    ippGetRange(copies, 0, &upper);
                    caps.maxCopies = std::clamp(upper, 1, print::kMaxCopies);
                } else {
                    caps.maxCopies = 1;
                }
                caps.options = printerOptions(http, dest, info, call.cancel);
                caps.known = !call.cancel.load();
                call.capabilities = caps;
                cupsFreeDestInfo(info);
            }
            httpClose(http);
            cupsFreeDests(1, dest);
        },
        [guard, done](Call &call) {
            if (guard)
                done(call.capabilities);
        },
        [guard, done] {
            if (guard)
                done(Capabilities{});
        });
}

PrintSystem::Stop CupsPrintSystem::submit(const QString &printer, const QString &title, const Options &options, int fd, QObject *context, JobDone done)
{
    const QPointer<QObject> guard(context);
    const Limits limits = m_limits;
    // No deadline over the whole job (a long document takes the time it takes): its steps have theirs (connectMs, idleMs).
    const std::shared_ptr<Call> call = run(
        0,
        [printer, title, options, fd, limits](Call &call) {
            const auto fail = [&call](const QString &why) { call.error = why; };
            // Only a PDF reaches the printer, sent as one (never CUPS_FORMAT_AUTO, which takes raw printer languages too;
            // integrator security review of step 6a, MINOR 2, and its counter-review: PostScript can program a PostScript
            // printer, and GTK always sends a PDF here).
            const auto stopped = [&call] { return call.cancel.load() != 0; };
            QString headError;
            const QByteArray head = readHead(fd, limits.idleMs, stopped, &headError);
            const QByteArray format = print::documentFormat(head).toLatin1();
            if (!headError.isEmpty() || format.isEmpty()) {
                ::close(fd);
                return fail(!headError.isEmpty() ? headError : QStringLiteral("the document is not a PDF"));
            }
            if (head.size() > limits.maxDocumentBytes) {
                ::close(fd);
                return fail(QStringLiteral("the document is too large"));
            }
            cups_dest_t *dest = findDestination(printer, limits.connectMs / 2, cancelFlag(call.cancel));
            if (!dest) {
                ::close(fd);
                return fail(QStringLiteral("the printer “%1” is not known to CUPS").arg(printer));
            }
            char resource[1024] = {};
            http_t *http = cupsConnectDest(dest, CUPS_DEST_FLAGS_NONE, limits.connectMs, cancelFlag(call.cancel), resource, sizeof resource, nullptr, nullptr);
            // The limit before the first request on the connection (a printer that takes the connection and never answers;
            // review of step 6a, MINOR 3).
            if (http)
                httpSetTimeout(http, limits.idleMs / 1000.0, stopWaiting, nullptr);
            cups_dinfo_t *info = http ? cupsCopyDestInfo(http, dest) : nullptr;
            if (!http || !info) {
                ::close(fd);
                if (http)
                    httpClose(http);
                cupsFreeDests(1, dest);
                return fail(QStringLiteral("cannot reach the printer: %1").arg(fromUtf8(cupsLastErrorString())));
            }
            // Stopped meanwhile (the request closed): no job is created.
            if (stopped()) {
                ::close(fd);
                cupsFreeDestInfo(info);
                httpClose(http);
                cupsFreeDests(1, dest);
                return fail(QStringLiteral("cancelled"));
            }
            int numOptions = 0;
            cups_option_t *cupsOptions = nullptr;
            for (const auto &o : options)
                numOptions = cupsAddOption(o.first.toUtf8().constData(), o.second.toUtf8().constData(), numOptions, &cupsOptions);
            const QByteArray name = print::jobName(title);
            int job = 0;
            const ipp_status_t created = cupsCreateDestJob(http, dest, info, &job, name.constData(), numOptions, cupsOptions);
            cupsFreeOptions(numOptions, cupsOptions);
            bool sent = false;
            if (created <= IPP_STATUS_OK_CONFLICTING && job > 0
                && cupsStartDestDocument(http, dest, info, job, name.constData(), format.constData(), 0, nullptr, 1) == HTTP_STATUS_CONTINUE) {
                char buffer[65536];
                bool reading = true;
                qint64 total = head.size();
                if (cupsWriteRequestData(http, head.constData(), size_t(head.size())) != HTTP_STATUS_CONTINUE)
                    call.error = QStringLiteral("the printer stopped taking the document");
                while (call.error.isEmpty()) {
                    const ssize_t n = readChunk(fd, buffer, sizeof buffer, limits.idleMs, stopped, &call.error);
                    if (n < 0)
                        break;
                    if (n == 0) {
                        reading = false;
                        break;
                    }
                    total += n;
                    if (total > limits.maxDocumentBytes) {
                        call.error = QStringLiteral("the document is too large");
                        break;
                    }
                    if (cupsWriteRequestData(http, buffer, size_t(n)) != HTTP_STATUS_CONTINUE) {
                        call.error = QStringLiteral("the printer stopped taking the document");
                        break;
                    }
                }
                const ipp_status_t finished = cupsFinishDestDocument(http, dest, info);
                sent = call.error.isEmpty() && !reading && finished <= IPP_STATUS_OK_CONFLICTING;
            }
            if (!sent) {
                if (call.error.isEmpty())
                    call.error = QStringLiteral("the printer refused the job: %1").arg(fromUtf8(cupsLastErrorString()));
                if (job > 0)
                    cupsCancelDestJob(http, dest, job);
            }
            ::close(fd);
            cupsFreeDestInfo(info);
            httpClose(http);
            cupsFreeDests(1, dest);
        },
        [guard, done](Call &call) {
            if (guard)
                done(call.error);
        },
        [] {});
    // The request closed: the worker stops at its next read or write, and a job it created is cancelled in the queue.
    const std::weak_ptr<Call> weak = call;
    return [weak] {
        if (const auto c = weak.lock())
            c->cancel.store(1);
    };
}

QString writePdf(int fd, const QString &folder, const QString &name, int idleMs, qint64 maxBytes, const std::function<bool()> &stopped)
{
    const QString target = QDir(folder).filePath(name);
    QString error;
    // Only a PDF: nothing is made in the folder before its first bytes say so.
    QByteArray head = readHead(fd, idleMs, stopped, &error);
    if (error.isEmpty() && !head.startsWith("%PDF-"))
        error = QStringLiteral("the document is not a PDF");
    const QByteArray file = QFile::encodeName(name);
    if (error.isEmpty() && (file.isEmpty() || file.contains('/') || file == "." || file == ".."))
        error = QStringLiteral("cannot write “%1”: not a file name").arg(target);
    const int dir = error.isEmpty() ? openFolder(folder, &error) : -1;
    if (dir < 0) {
        ::close(fd);
        return error;
    }
    // A regular file there that may not be written stays (as QSaveFile refused it); one that may keeps its permissions (read off
    // the file itself, never off what a link points to).
    struct stat existing;
    const bool replacing = ::fstatat(dir, file.constData(), &existing, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(existing.st_mode);
    if (replacing && ::faccessat(dir, file.constData(), W_OK, AT_EACCESS | AT_SYMLINK_NOFOLLOW) != 0 && errno != EINVAL && errno != ENOSYS) {
        error = QStringLiteral("cannot write “%1”: %2").arg(target, errnoText(errno));
        ::close(dir);
        ::close(fd);
        return error;
    }
    // A temporary file of its own in the folder, made here (O_EXCL) and never through a link (O_NOFOLLOW).
    QByteArray temporary;
    int out = -1;
    for (int tries = 0; tries < 8 && out < 0; ++tries) {
        temporary = ".grassfield-print-" + QByteArray::number(QRandomGenerator::system()->generate64(), 16) + ".part";
        out = ::openat(dir, temporary.constData(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0666);
        if (out < 0 && errno != EEXIST)
            break;
    }
    if (out < 0) {
        error = QStringLiteral("cannot write “%1”: %2").arg(target, errnoText(errno));
        ::close(dir);
        ::close(fd);
        return error;
    }
    if (replacing)
        ::fchmod(out, existing.st_mode & 0777);
    qint64 total = head.size();
    if (total > maxBytes)
        error = QStringLiteral("the document is too large");
    else if (!writeAll(out, head.constData(), size_t(head.size())))
        error = QStringLiteral("cannot write “%1”: %2").arg(target, errnoText(errno));
    char buffer[65536];
    while (error.isEmpty()) {
        const ssize_t n = readChunk(fd, buffer, sizeof buffer, idleMs, stopped, &error);
        if (n <= 0)
            break;
        total += n;
        if (total > maxBytes) {
            error = QStringLiteral("the document is too large");
            break;
        }
        if (!writeAll(out, buffer, size_t(n)))
            error = QStringLiteral("cannot write “%1”: %2").arg(target, errnoText(errno));
    }
    ::close(fd);
    if (error.isEmpty() && ::fsync(out) != 0)
        error = QStringLiteral("cannot write “%1”: %2").arg(target, errnoText(errno));
    if (::close(out) != 0 && error.isEmpty())
        error = QStringLiteral("cannot write “%1”: %2").arg(target, errnoText(errno));
    // The rename puts the file in the name's place: a link there is replaced, never followed.
    if (error.isEmpty() && ::renameat(dir, temporary.constData(), dir, file.constData()) != 0)
        error = QStringLiteral("cannot write “%1”: %2").arg(target, errnoText(errno));
    if (error.isEmpty()) {
        // The rename made durable where the folder can be read (an O_PATH descriptor cannot be synced).
        const int sync = ::openat(dir, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (sync >= 0) {
            ::fsync(sync);
            ::close(sync);
        }
    } else {
        ::unlinkat(dir, temporary.constData(), 0);
    }
    ::close(dir);
    return error;
}

} // namespace grassfield::portal
