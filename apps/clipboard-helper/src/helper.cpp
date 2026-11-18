#include "helper.h"
#include "thumbnail.h"

#include <QDateTime>
#include <QElapsedTimer>
#include <QFile>
#include <QRandomGenerator>
#include <QSaveFile>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <ctime>

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

using namespace ClipLogic;

namespace
{
constexpr int kReadDeadlineMs = 2000;
constexpr int kExpiryMs = 60 * 1000;
constexpr int kMaxWriters = 16;
constexpr int kPreviewTextChars = 64 * 1024;
// New copies' images waiting for the worker (each up to 16 MiB in memory): past this, a new image is not recorded.
constexpr int kMaxWaitingImages = 4;
// A stored image whose worker failed (late under load, failed to start) keeps its item without a thumbnail and is tried again
// this many times in a run, a minute apart; the next start tries again.
constexpr int kThumbnailAttempts = 3;
constexpr int kThumbnailRetryMs = 60 * 1000;

QByteArray readBootId()
{
    QFile f(QStringLiteral("/proc/sys/kernel/random/boot_id"));
    if (!f.open(QIODevice::ReadOnly))
        return {};
    return f.read(64).trimmed();
}

QByteArray number(qint64 n)
{
    return QByteArray::number(n);
}
} // namespace

// The offer being decided or read.
struct Helper::Pending {
    WaylandClipboard::Offer *offer = nullptr;
    quint64 seq = 0;
    Plan plan;
    bool approved = false;
    QString app;
    QList<QByteArray> reads;
    int index = -1;
    QHash<QByteArray, ReadResult> results;
    int fd = -1;
    QSocketNotifier *notifier = nullptr;
    QTimer deadline;
    QElapsedTimer age; // of the read of the current type
    QByteArray buffer;
    qint64 cap = 0;
};

// One answer to a `send` of our source: the bytes go out as the reader takes them, never blocking the helper; closed when the
// reader takes nothing for 2 s, and after 60 s in all (writerWaitMs).
struct Helper::Writer {
    int fd = -1;
    QByteArray bytes;
    qint64 written = 0;
    QSocketNotifier *notifier = nullptr;
    QTimer *deadline = nullptr;
    QElapsedTimer age;
};

Helper::Helper(Options options, Output output, Quit quit, QObject *parent)
    : QObject(parent)
    , m_options(std::move(options))
    , m_output(std::move(output))
    , m_quit(std::move(quit))
    , m_pinnedDisk(m_options.stateDir + QStringLiteral("/pinned"))
    , m_historyDisk(m_options.stateDir + QStringLiteral("/history"))
    , m_bootId(readBootId())
{
    m_options.retentionMs = clampRetention(m_options.retentionMs);
    m_expiry.setInterval(kExpiryMs);
    connect(&m_expiry, &QTimer::timeout, this, [this] { expire(); });
}

Helper::~Helper()
{
    abortPending();
    for (Writer *w : std::as_const(m_writers)) {
        ::close(w->fd);
        delete w; // its notifier and timer are children of this object
    }
}

qint64 Helper::nowWall()
{
    return QDateTime::currentMSecsSinceEpoch();
}

qint64 Helper::nowBoot()
{
    timespec ts {};
    ::clock_gettime(CLOCK_BOOTTIME, &ts);
    return qint64(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

QByteArray Helper::newId() const
{
    for (;;) {
        const QByteArray id = QByteArray::number(QRandomGenerator::system()->generate64(), 16).rightJustified(16, '0');
        if (!m_store.find(id))
            return id;
    }
}

void Helper::log(const char *what)
{
    // Reasons only: never text, names, URLs, titles or hashes (ADR-0034 §2, PV-6).
    std::fprintf(stderr, "grassfield-clipboard: %s\n", what);
}

void Helper::emitLine(const QList<QByteArray> &fields)
{
    QByteArray line;
    for (qsizetype i = 0; i < fields.size(); ++i) {
        if (i)
            line += '\x1f';
        line += escape(fields.at(i));
    }
    line += '\n';
    m_output(line);
}

void Helper::emitItem(const QByteArray &id)
{
    const Item *it = m_store.find(id);
    if (!it)
        return;
    QByteArrayList mimes;
    if (it->kind == Kind::Text)
        mimes << "text/plain";
    for (const Part &p : it->parts)
        mimes << p.mime;
    emitLine({"I", it->id, kindName(it->kind), mimes.join(','), number(it->size()), number(it->copiedAtMs), number(it->pinnedAtMs),
              it->formatted() ? "1" : "0", number(it->files.size()), it->title.toUtf8(), it->excerpt.toUtf8(),
              QFile::encodeName(m_thumbs.value(id)), it->app.toUtf8()});
}

void Helper::emitRemoved(const QList<QByteArray> &ids)
{
    for (const QByteArray &id : ids) {
        forgetFiles(id);
        emitLine({"X", id});
    }
}

// --- Start ------------------------------------------------------------------------------------------------------------------

int Helper::start()
{
    // The runtime directory is this helper's own (one per display): files of an earlier run are gone, links never followed.
    const QByteArray runtime = QFile::encodeName(m_options.runtimeDir);
    ::mkdir(QFile::encodeName(m_options.runtimeDir.section(QLatin1Char('/'), 0, -2)).constData(), 0700);
    struct stat st {};
    if (::lstat(runtime.constData(), &st) == 0 && S_ISLNK(st.st_mode))
        ::unlink(runtime.constData());
    ::mkdir(runtime.constData(), 0700);
    if (::lstat(runtime.constData(), &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != ::getuid() || ::chmod(runtime.constData(), 0700) != 0) {
        emitLine({"S", "error", "runtime directory"});
        return 1;
    }
    cleanup();
    ::mkdir(runtime.constData(), 0700);

    // Clears asked in the settings while no helper ran: carried out before anything is loaded, shown or recorded (review of
    // f7cd664).
    m_clears = applyClears(m_options.stateDir, m_options.clearedAtMs, m_options.pinnedClearedAtMs);

    // The pinned items always (Q5), the history only with the opt-in store (Q2).
    const DiskStore::Loaded pinned = m_pinnedDisk.load();
    if (pinned.status == DiskStore::Status::Deleted)
        log("the pinned store broke a rule and was deleted");
    if (pinned.dropped)
        log("pinned items whose files broke a rule were deleted");
    if (pinned.orphans)
        log("files of the pinned store that its index did not name were deleted");
    m_store.loadPinned(pinned.items);
    if (!m_options.historyStore)
        m_historyDisk.deleteAll(); // a store left from when the switch was on: never read, deleted
    if (m_options.historyStore) {
        const DiskStore::Loaded history = m_historyDisk.load();
        if (history.status == DiskStore::Status::Deleted)
            log("the history store broke a rule and was deleted");
        if (history.orphans)
            log("files of the history store that its index did not name were deleted");
        m_store.loadHistory(history.items);
        expire();
    }
    for (const Item *it : m_store.ordered()) {
        if (it->kind == Kind::Image)
            queueThumbnail(it->id);
        else
            emitItem(it->id);
    }

    QString error;
    const int fd = WaylandClipboard::connectSocket(m_options.display, &error);
    if (fd < 0) {
        log("cannot reach the display it was given");
        emitLine({"S", "error", error.toUtf8()});
        return 1;
    }
    WaylandClipboard::Callbacks callbacks;
    callbacks.lockChanged = [this] {
        emitLine({"L", m_wl->compositorLocked() ? "1" : "0"});
        updateCapture();
    };
    callbacks.selection = [this](WaylandClipboard::Offer *offer, bool first) { selection(offer, first); };
    callbacks.send = [this](const QByteArray &mime, int fd) { send(mime, fd); };
    callbacks.sourceCancelled = [this] {
        m_owned = Item();
        emitLine({"A", ""});
    };
    callbacks.fatal = [this](const QString &why) {
        log("the compositor connection ended");
        emitLine({"S", "error", why.toUtf8()});
        m_quit(1);
    };
    m_wl = new WaylandClipboard(callbacks, this);
    if (!m_wl->start(fd, &error)) {
        emitLine({"S", "error", error.toUtf8()});
        return 1;
    }
    if (!m_wl->supported()) {
        log("the compositor has no ext-data-control-v1 or hyprland_lock_notifier_v1: nothing is captured");
        emitLine({"S", "unsupported"});
        return 3;
    }
    emitLine({"L", m_wl->compositorLocked() ? "1" : "0"});
    emitLine({"S", "ok"});
    m_expiry.start();
    updateCapture();
    return 0;
}

int Helper::clearPinned(const QString &stateDir)
{
    DiskStore store(stateDir + QStringLiteral("/pinned"));
    store.deleteAll();
    return 0;
}

int Helper::clearHistoryStore(const QString &stateDir)
{
    DiskStore store(stateDir + QStringLiteral("/history"));
    store.deleteAll();
    return 0;
}

DiskStore::Clears Helper::applyClears(const QString &stateDir, qint64 clearedAtMs, qint64 pinnedClearedAtMs)
{
    const DiskStore::Clears record = DiskStore::readClears(stateDir);
    DiskStore::Clears next = record;
    next.known = true;
    const auto carryOut = [&](const char *name, qint64 asked, qint64 applied, bool pinned, qint64 *slot) {
        DiskStore store(stateDir + QLatin1Char('/') + QLatin1String(name));
        switch (ClipLogic::clearAction(asked, applied, record.known)) {
        case ClipLogic::ClearAction::Keep:
            break;
        case ClipLogic::ClearAction::DeleteAll:
            store.deleteAll();
            std::fprintf(stderr, "grassfield-clipboard: a clear asked while no helper ran was carried out (the %s store)\n", name);
            break;
        case ClipLogic::ClearAction::DropOlder: {
            // No record: only what was there when the clear was asked goes.
            const DiskStore::Loaded loaded = store.load();
            if (loaded.status != DiskStore::Status::Loaded || store.readOnly())
                break;
            const QList<ClipLogic::Item> kept = ClipLogic::keptAfterClear(loaded.items, asked, pinned);
            if (kept.size() == loaded.items.size())
                break;
            if (kept.isEmpty()) {
                store.deleteAll();
            } else {
                for (const ClipLogic::Item &it : loaded.items) {
                    if (!std::any_of(kept.cbegin(), kept.cend(), [&](const ClipLogic::Item &k) { return k.id == it.id; }))
                        store.removeItem(it.id, kept);
                }
            }
            std::fprintf(stderr, "grassfield-clipboard: a clear asked before the record existed was carried out (the %s store)\n", name);
            break;
        }
        }
        if (asked > 0)
            *slot = asked;
    };
    carryOut("history", clearedAtMs, record.history, false, &next.history);
    carryOut("pinned", pinnedClearedAtMs, record.pinned, true, &next.pinned);
    if (!record.known || next.history != record.history || next.pinned != record.pinned)
        DiskStore::writeClears(stateDir, next);
    return next;
}

void Helper::cleanup()
{
    const QByteArray runtime = QFile::encodeName(m_options.runtimeDir);
    const int dirfd = ::open(runtime.constData(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dirfd < 0)
        return;
    if (DIR *d = ::fdopendir(dirfd)) {
        QList<QByteArray> names;
        while (const dirent *e = ::readdir(d)) {
            const QByteArray name(e->d_name);
            if (name.endsWith(".png"))
                names << name;
        }
        for (const QByteArray &name : std::as_const(names))
            ::unlinkat(dirfd, name.constData(), 0);
        ::closedir(d);
    } else {
        ::close(dirfd);
    }
    ::rmdir(runtime.constData());
    m_thumbs.clear();
}

// --- Capture ----------------------------------------------------------------------------------------------------------------

void Helper::updateCapture()
{
    if (!m_wl || !m_wl->supported())
        return;
    // Both lock sources say unlocked (the compositor's notifier and the shell's resume), or there is no device at all.
    const bool on = !m_wl->compositorLocked() && m_shellResumed;
    if (!on)
        abortPending();
    m_wl->setCapturing(on);
}

void Helper::selection(WaylandClipboard::Offer *offer, bool first)
{
    abortPending(); // a newer selection replaces the one being decided or read
    if (!offer)
        return;
    if (first) {
        // It may have been copied during a lock, or before the history was on: never recorded.
        m_wl->release(offer);
        return;
    }
    const Plan p = plan(offer->types, offer->tooMany);
    if (p.hasMarker && m_wl->ownsSelection()) {
        m_wl->release(offer);
        ownSelectionConfirmed();
        return;
    }
    if (p.refusal != Refusal::None) {
        m_wl->release(offer);
        if (p.refusal == Refusal::Secret)
            log("skipped a copy: a password-manager hint (its data was never requested)");
        else if (p.refusal == Refusal::TooManyTypes)
            log("skipped a copy: too many types");
        return;
    }
    m_pending = std::make_unique<Pending>();
    m_pending->offer = offer;
    m_pending->seq = ++m_seq;
    m_pending->plan = p;
    m_pending->deadline.setSingleShot(true);
    m_pending->deadline.setInterval(kReadDeadlineMs);
    connect(&m_pending->deadline, &QTimer::timeout, this, [this] { readDone(ReadResult::Failed); });
    emitLine({"O", number(qint64(m_pending->seq)), kindName(p.kind)});
}

void Helper::abortPending()
{
    if (!m_pending)
        return;
    std::unique_ptr<Pending> p = std::move(m_pending);
    p->deadline.stop();
    if (p->notifier) {
        p->notifier->setEnabled(false);
        delete p->notifier;
    }
    if (p->fd >= 0)
        ::close(p->fd);
    if (m_wl)
        m_wl->release(p->offer);
}

void Helper::answer(quint64 seq, bool yes, const QString &app)
{
    if (!m_pending || m_pending->seq != seq || m_pending->approved)
        return;
    if (!yes) {
        abortPending();
        return;
    }
    m_pending->approved = true;
    m_pending->app = app.left(255);
    m_pending->reads = m_pending->plan.reads();
    readNext();
}

void Helper::readNext()
{
    Pending *p = m_pending.get();
    if (!p)
        return;
    ++p->index;
    if (p->index >= p->reads.size()) {
        finishRead();
        return;
    }
    const QByteArray type = p->reads.at(p->index);
    p->buffer.clear();
    p->cap = p->plan.cap(type);
    p->fd = m_wl->receive(p->offer, type);
    if (p->fd < 0) {
        p->results.insert(type, ReadResult{ReadResult::Failed, {}});
        readNext();
        return;
    }
    p->notifier = new QSocketNotifier(p->fd, QSocketNotifier::Read, this);
    connect(p->notifier, &QSocketNotifier::activated, this, [this] { readable(); });
    p->age.start();
    p->deadline.start(kReadDeadlineMs);
}

void Helper::readable()
{
    Pending *p = m_pending.get();
    if (!p || p->fd < 0)
        return;
    char chunk[65536];
    bool progressed = false;
    for (;;) {
        const ssize_t n = ::read(p->fd, chunk, sizeof chunk);
        if (n > 0) {
            p->buffer.append(chunk, n);
            if (p->buffer.size() > p->cap) {
                readDone(ReadResult::OverCap); // never truncated: over the cap is not recorded
                return;
            }
            progressed = true;
            continue;
        }
        if (n == 0) {
            readDone(ReadResult::Ok);
            return;
        }
        if (errno == EINTR)
            continue;
        if (errno != EAGAIN)
            readDone(ReadResult::Failed);
        else if (progressed) // a source that keeps sending (a large image encoded as it goes) is given the answers' limits
            p->deadline.start(int(writerWaitMs(p->age.elapsed())));
        return;
    }
}

void Helper::readDone(ReadResult::Status status)
{
    Pending *p = m_pending.get();
    if (!p || p->fd < 0)
        return;
    p->deadline.stop();
    if (p->notifier) {
        p->notifier->setEnabled(false);
        p->notifier->deleteLater();
        p->notifier = nullptr;
    }
    ::close(p->fd);
    p->fd = -1;
    const QByteArray type = p->reads.at(p->index);
    p->results.insert(type, ReadResult{status, status == ReadResult::Ok ? p->buffer : QByteArray()});
    p->buffer.clear();
    readNext();
}

void Helper::finishRead()
{
    std::unique_ptr<Pending> p = std::move(m_pending);
    m_wl->release(p->offer);
    Built built = build(p->plan, p->results);
    if (!built.ok) {
        const QByteArray why = "not recorded: " + built.error;
        log(why.constData());
        return;
    }
    Item item = built.item;
    item.id = newId();
    item.copiedAtMs = nowWall();
    item.bootAtMs = nowBoot();
    item.bootId = m_bootId;
    item.app = p->app;
    if (item.kind != Kind::Image) {
        addItem(item, {});
        return;
    }
    // An image is recorded only once the worker made its thumbnail (ADR-0034 §1f).
    queueNewImage(item);
}

void Helper::addItem(Item item, const QByteArray &thumbnail)
{
    const Store::AddResult r = m_store.add(std::move(item));
    if (r.added && !thumbnail.isEmpty() && writeRuntimeFile(thumbPath(r.id), thumbnail))
        m_thumbs.insert(r.id, thumbPath(r.id));
    if (m_options.historyStore) {
        if (const Item *it = m_store.find(r.id); it && !it->pinned())
            m_historyDisk.save(*it, m_store.history());
        for (const QByteArray &id : r.evicted)
            m_historyDisk.removeItem(id, m_store.history());
    }
    emitRemoved(r.evicted);
    emitItem(r.id);
}

// --- Thumbnails of stored images --------------------------------------------------------------------------------------------

void Helper::queueNewImage(const Item &item)
{
    qsizetype waiting = m_thumbJob && m_thumbJobFresh ? 1 : 0;
    for (const ImageJob &job : std::as_const(m_imageQueue))
        waiting += job.fresh ? 1 : 0;
    if (waiting >= kMaxWaitingImages) {
        log("not recorded: too many images waiting for the image worker");
        return;
    }
    // A new copy goes before every stored thumbnail (up to 150 of them at start), after the new copies already waiting.
    const auto firstStored = std::find_if(m_imageQueue.begin(), m_imageQueue.end(), [](const ImageJob &job) { return !job.fresh; });
    const auto at = m_imageQueue.insert(firstStored, ImageJob{item.id, true, item});
    // Counts only (PV-6): where it waits, for tests/shell/clipboard_helper.sh.
    const auto pos = std::distance(m_imageQueue.begin(), at);
    qsizetype storedAhead = 0;
    for (qsizetype i = 0; i < pos; ++i)
        storedAhead += m_imageQueue.at(i).fresh ? 0 : 1;
    const qsizetype storedBehind = std::count_if(m_imageQueue.begin(), m_imageQueue.end(), [](const ImageJob &job) { return !job.fresh; }) - storedAhead;
    const QByteArray line = "a new image waits for the worker: " + QByteArray::number(qint64(pos - storedAhead)) + " new and "
        + QByteArray::number(qint64(storedAhead)) + " stored ahead, " + QByteArray::number(qint64(storedBehind)) + " stored behind";
    log(line.constData());
    nextThumbnail();
}

void Helper::queueThumbnail(const QByteArray &id)
{
    m_imageQueue << ImageJob{id, false, {}};
    nextThumbnail();
}

void Helper::nextThumbnail()
{
    while (!m_thumbJob && !m_imageQueue.isEmpty()) {
        const ImageJob job = m_imageQueue.takeFirst();
        const Item *stored = job.fresh ? nullptr : m_store.find(job.id);
        if (!job.fresh && (!stored || stored->kind != Kind::Image))
            continue; // removed or cleared while it waited
        const Item &image = job.fresh ? job.item : *stored;
        const quint64 generation = m_imageGeneration;
        auto holder = std::make_shared<ThumbnailJob *>(nullptr);
        m_thumbJob = new ThumbnailJob(m_options.program, image.imageFormat, kThumbnailPx, image.parts.first().data,
                                      [this, job, generation, holder](const QByteArray &png) {
                                          (*holder)->deleteLater();
                                          if (m_thumbJob == *holder)
                                              m_thumbJob = nullptr;
                                          // A new copy's image that a clear cancelled while the worker ran is never added.
                                          if (!job.fresh || generation == m_imageGeneration)
                                              imageDone(job, png);
                                          nextThumbnail();
                                      },
                                      this);
        m_thumbJobFresh = job.fresh;
        *holder = m_thumbJob;
        m_thumbJob->start();
    }
}

void Helper::imageDone(const ImageJob &job, const QByteArray &png)
{
    if (job.fresh) {
        if (png.isEmpty())
            log("not recorded: the image worker failed");
        else
            addItem(job.item, png);
        return;
    }
    if (!m_store.find(job.id))
        return; // removed or cleared while the worker ran
    if (!png.isEmpty() && writeRuntimeFile(thumbPath(job.id), png)) {
        m_thumbAttempts.remove(job.id);
        m_thumbs.insert(job.id, thumbPath(job.id));
        emitItem(job.id);
        return;
    }
    // Never delete what the user kept on a worker's failure (it may be late under load): the item stays, shown without a
    // thumbnail, and its thumbnail is tried again later.
    log("a stored image's thumbnail failed: the item is kept without one");
    emitItem(job.id);
    const int attempts = m_thumbAttempts.value(job.id) + 1;
    m_thumbAttempts.insert(job.id, attempts);
    if (attempts < kThumbnailAttempts) {
        const QByteArray id = job.id;
        QTimer::singleShot(kThumbnailRetryMs, this, [this, id] { queueThumbnail(id); });
    }
}

void Helper::cancelNewImages()
{
    // The clears drop every new copy's image not yet recorded: waiting ones now, the running one when its worker answers.
    ++m_imageGeneration;
    m_imageQueue.removeIf([](const ImageJob &job) { return job.fresh; });
}

// --- Commands ---------------------------------------------------------------------------------------------------------------

void Helper::command(const QByteArray &line)
{
    const QList<QByteArray> f = splitLine(line);
    if (f.isEmpty())
        return;
    const QByteArray &verb = f.first();
    const QByteArray arg = f.value(1);
    if (verb == "R" || verb == "P") {
        m_shellResumed = verb == "R";
        updateCapture();
    } else if (verb == "Y" || verb == "N") {
        answer(arg.toULongLong(), verb == "Y", QString::fromUtf8(f.value(2)));
    } else if (verb == "T") {
        m_options.retentionMs = clampRetention(arg.toLongLong());
        expire();
    } else if (verb == "D") {
        setHistoryStore(arg == "1");
    } else if (verb == "E") {
        expire();
    } else if (verb == "CH" || verb == "CP") {
        // `CH <ms>` / `CP <ms>`: Settings asked the clear at that time; it is recorded, so the next start does not carry it out
        // again. Without a time (Search's Clear History) only the clear.
        if (verb == "CH")
            clearHistory();
        else
            clearPinnedItems();
        bool ok = false;
        const qint64 at = arg.toLongLong(&ok);
        if (ok && at > 0) {
            (verb == "CH" ? m_clears.history : m_clears.pinned) = at;
            m_clears.known = true;
            DiskStore::writeClears(m_options.stateDir, m_clears);
        }
    } else if (verb == "X") {
        remove(arg);
    } else if (verb == "PIN") {
        pin(arg);
    } else if (verb == "UNPIN") {
        unpin(arg);
    } else if (verb == "C") {
        copy(arg, f.value(2) == "1");
    } else if (verb == "Q") {
        QList<QByteArray> out = {"R", arg};
        out += m_store.search(QString::fromUtf8(f.value(2)));
        emitLine(out);
    } else if (verb == "V") {
        preview(arg);
    } else if (verb == "VD") {
        dropPreview(arg);
    } else if (verb == "QUIT") {
        m_quit(0);
    }
}

void Helper::expire()
{
    const QList<QByteArray> gone = m_store.expire(nowWall(), nowBoot(), m_bootId, m_options.retentionMs);
    if (gone.isEmpty())
        return;
    if (m_options.historyStore)
        m_historyDisk.saveIndex(m_store.history());
    for (const QByteArray &id : gone)
        ::unlink(QFile::encodeName(m_historyDisk.dir() + QLatin1Char('/') + QString::fromLatin1(id) + QStringLiteral(".item")).constData());
    emitRemoved(gone);
}

void Helper::pin(const QByteArray &id)
{
    switch (m_store.pin(id, nowWall())) {
    case Store::PinResult::Pinned:
        if (const Item *it = m_store.find(id)) {
            if (!m_pinnedDisk.save(*it, m_store.pinnedItems()))
                log("the pinned item could not be written");
        }
        if (m_options.historyStore)
            m_historyDisk.removeItem(id, m_store.history());
        emitItem(id);
        break;
    case Store::PinResult::Full:
        emitLine({"N", "pin-full", id});
        break;
    case Store::PinResult::AlreadyPinned:
    case Store::PinResult::NotFound:
        break;
    }
}

void Helper::unpin(const QByteArray &id)
{
    bool found = false;
    const QList<QByteArray> evicted = m_store.unpin(id, &found);
    if (!found)
        return;
    m_pinnedDisk.removeItem(id, m_store.pinnedItems());
    if (m_options.historyStore) {
        if (const Item *it = m_store.find(id))
            m_historyDisk.save(*it, m_store.history());
        for (const QByteArray &gone : evicted)
            m_historyDisk.removeItem(gone, m_store.history());
    }
    emitRemoved(evicted);
    emitItem(id);
    expire(); // an old item that comes back from the pins may be past the retention
}

void Helper::remove(const QByteArray &id)
{
    const Item *it = m_store.find(id);
    if (!it)
        return;
    const bool wasPinned = it->pinned();
    m_store.remove(id);
    if (wasPinned)
        m_pinnedDisk.removeItem(id, m_store.pinnedItems());
    else if (m_options.historyStore)
        m_historyDisk.removeItem(id, m_store.history());
    emitRemoved({id});
}

void Helper::clearHistory()
{
    cancelNewImages();
    const QList<QByteArray> ids = m_store.clearHistory();
    m_historyDisk.deleteAll();
    emitRemoved(ids);
}

void Helper::clearPinnedItems()
{
    cancelNewImages();
    const QList<QByteArray> ids = m_store.clearPinned();
    m_pinnedDisk.deleteAll();
    emitRemoved(ids);
}

void Helper::setHistoryStore(bool on)
{
    if (on == m_options.historyStore)
        return;
    m_options.historyStore = on;
    if (!on) {
        m_historyDisk.deleteAll();
        return;
    }
    for (const Item &it : m_store.history())
        m_historyDisk.save(it, m_store.history());
}

// --- Serving an item --------------------------------------------------------------------------------------------------------

void Helper::copy(const QByteArray &id, bool plainOnly)
{
    const Item *it = m_store.find(id);
    if (!it || !m_wl) {
        emitLine({"A", ""});
        return;
    }
    QList<QByteArray> types;
    if (it->kind == Kind::Text) {
        types = plainTypes();
        if (!plainOnly)
            for (const Part &p : it->parts)
                types << p.mime;
    } else if (it->kind == Kind::Image) {
        types << it->parts.first().mime;
    } else {
        types << "text/uri-list" << "x-special/gnome-copied-files" << "text/plain;charset=utf-8" << "text/plain";
    }
    types << kMarkerType;
    const Item previous = m_owned;
    m_owned = *it;
    m_ownedPlainOnly = plainOnly;
    m_requestedId = id;
    if (!m_wl->setSelection(types)) {
        m_owned = previous;
        m_requestedId.clear();
        emitLine({"A", ""}); // paused (locked): nothing is set
    }
}

void Helper::ownSelectionConfirmed()
{
    if (m_owned.id.isEmpty())
        return;
    if (m_store.touch(m_owned.id, nowWall(), nowBoot(), m_bootId)) {
        if (m_options.historyStore)
            m_historyDisk.saveIndex(m_store.history());
        emitItem(m_owned.id);
    }
    m_requestedId.clear();
    emitLine({"A", m_owned.id});
}

void Helper::send(const QByteArray &mime, int fd)
{
    QByteArray bytes;
    const QByteArray type = normalizeType(mime);
    const Item &it = m_owned;
    bool known = !it.id.isEmpty();
    if (!known) {
    } else if (type == normalizeType(kMarkerType)) {
        bytes = it.id;
    } else if (it.kind == Kind::Text && plainTypes().contains(mime)) {
        bytes = servePlain(it.plain, mime);
    } else if (it.kind == Kind::Files && (type == "text/plain;charset=utf-8" || type == "text/plain")) {
        bytes = it.plain.toUtf8();
    } else if (it.kind == Kind::Files && type == "text/uri-list") {
        bytes = uriList(it.files);
    } else if (it.kind == Kind::Files && type == "x-special/gnome-copied-files") {
        bytes = gnomeCopiedFiles(it.files);
    } else {
        known = false;
        if (!(m_ownedPlainOnly && it.kind == Kind::Text)) {
            for (const Part &p : it.parts) {
                if (p.mime == type) {
                    bytes = p.data;
                    known = true;
                }
            }
        }
    }
    if (!known || m_writers.size() >= kMaxWriters) {
        ::close(fd);
        return;
    }
    ::fcntl(fd, F_SETFL, ::fcntl(fd, F_GETFL) | O_NONBLOCK);
    ::fcntl(fd, F_SETFD, FD_CLOEXEC);
    auto *w = new Writer;
    w->fd = fd;
    w->bytes = bytes;
    w->notifier = new QSocketNotifier(fd, QSocketNotifier::Write, this);
    w->deadline = new QTimer(this);
    w->deadline->setSingleShot(true);
    m_writers << w;
    // A reader that stops reading never holds a writer (one of kMaxWriters): 2 s without progress, or 60 s in all, closes it.
    connect(w->deadline, &QTimer::timeout, this, [this, w] { closeWriter(w); });
    connect(w->notifier, &QSocketNotifier::activated, this, [this, w] {
        bool progressed = false;
        while (w->written < w->bytes.size()) {
            const ssize_t n = ::write(w->fd, w->bytes.constData() + w->written, size_t(w->bytes.size() - w->written));
            if (n > 0) {
                w->written += n;
                progressed = true;
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno == EAGAIN) {
                if (progressed)
                    w->deadline->start(int(writerWaitMs(w->age.elapsed())));
                return;
            }
            break; // the reader went away
        }
        closeWriter(w);
    });
    w->age.start();
    w->deadline->start(int(writerWaitMs(0)));
}

void Helper::closeWriter(Writer *w)
{
    if (!m_writers.removeOne(w))
        return;
    w->notifier->setEnabled(false);
    w->notifier->deleteLater();
    w->deadline->stop();
    w->deadline->deleteLater();
    ::close(w->fd);
    delete w;
}

// --- Previews ---------------------------------------------------------------------------------------------------------------

void Helper::preview(const QByteArray &id)
{
    const Item *it = m_store.find(id);
    if (!it) {
        emitLine({"V", id, "", ""});
        return;
    }
    if (it->kind != Kind::Image) {
        emitLine({"V", id, "", it->plain.left(kPreviewTextChars).toUtf8()});
        return;
    }
    if (m_previewJob) {
        ThumbnailJob *old = m_previewJob; // its answer, if it still comes, is ignored
        m_previewJob = nullptr;
        old->deleteLater();
    }
    auto holder = std::make_shared<ThumbnailJob *>(nullptr);
    m_previewJob = new ThumbnailJob(m_options.program, it->imageFormat, kPreviewPx, it->parts.first().data,
                                    [this, id, holder](const QByteArray &png) {
                                        (*holder)->deleteLater();
                                        if (m_previewJob != *holder)
                                            return;
                                        m_previewJob = nullptr;
                                        const QString path = previewPath(id);
                                        if (!png.isEmpty() && m_store.find(id) && writeRuntimeFile(path, png))
                                            emitLine({"V", id, QFile::encodeName(path), ""});
                                        else
                                            emitLine({"V", id, "", ""});
                                    },
                                    this);
    *holder = m_previewJob;
    m_previewJob->start();
}

void Helper::dropPreview(const QByteArray &id)
{
    if (DiskStore::validId(id))
        ::unlink(QFile::encodeName(previewPath(id)).constData());
}

QString Helper::thumbPath(const QByteArray &id) const
{
    return m_options.runtimeDir + QLatin1Char('/') + QString::fromLatin1(id) + QStringLiteral(".png");
}

QString Helper::previewPath(const QByteArray &id) const
{
    return m_options.runtimeDir + QLatin1Char('/') + QString::fromLatin1(id) + QStringLiteral("-preview.png");
}

bool Helper::writeRuntimeFile(const QString &path, const QByteArray &bytes)
{
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) || !file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner)
        || file.write(bytes) != bytes.size()) {
        file.cancelWriting();
        return false;
    }
    return file.commit();
}

void Helper::forgetFiles(const QByteArray &id)
{
    if (!DiskStore::validId(id))
        return;
    ::unlink(QFile::encodeName(thumbPath(id)).constData());
    ::unlink(QFile::encodeName(previewPath(id)).constData());
    m_thumbs.remove(id);
    m_thumbAttempts.remove(id);
}
