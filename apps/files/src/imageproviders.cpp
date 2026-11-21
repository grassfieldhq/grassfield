#include "imageproviders.h"

#include "appicons.h"
#include "applicationslogic.h"

#include <QAtomicInt>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QList>
#include <QMutex>
#include <QIcon>
#include <QMutexLocker>
#include <QPixmap>
#include <QPointer>
#include <QThreadPool>

#include <cstdlib>
#include <memory>

QMutex ThumbnailStore::s_mutex;
QHash<QString, QImage> ThumbnailStore::s_images;
quint64 ThumbnailStore::s_serial = 0;

QString ThumbnailStore::insert(const QImage &image)
{
    QMutexLocker lock(&s_mutex);
    const QString key = QString::number(++s_serial);
    s_images.insert(key, image);
    return key;
}

QImage ThumbnailStore::value(const QString &key)
{
    QMutexLocker lock(&s_mutex);
    return s_images.value(key);
}

void ThumbnailStore::remove(const QString &key)
{
    QMutexLocker lock(&s_mutex);
    s_images.remove(key);
}

int ThumbnailStore::size()
{
    QMutexLocker lock(&s_mutex);
    return int(s_images.size());
}

ThumbnailProvider::ThumbnailProvider()
    : QQuickImageProvider(QQuickImageProvider::Image)
{
}

QImage ThumbnailProvider::requestImage(const QString &id, QSize *size, const QSize &requestedSize)
{
    QImage image = ThumbnailStore::value(id);
    if (!image.isNull() && requestedSize.isValid() && (image.width() > requestedSize.width() || image.height() > requestedSize.height()))
        image = image.scaled(requestedSize, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    if (size)
        *size = image.size();
    return image;
}

namespace
{
// Finished from the GUI thread. Qt requires finished() after cancel() too, so a cancelled response is still finished (empty).
class IconResponse : public QQuickImageResponse
{
public:
    QQuickTextureFactory *textureFactory() const override { return QQuickTextureFactory::textureFactoryForImage(m_image); }
    void cancel() override { m_cancelled->storeRelaxed(1); }
    // Shared with the worker, which must not touch the response itself (the engine may delete it at any time).
    std::shared_ptr<QAtomicInt> cancelFlag() const { return m_cancelled; }
    bool cancelled() const { return m_cancelled->loadRelaxed() != 0; }
    void done(const QImage &image)
    {
        m_image = image;
        emit finished();
    }

private:
    QImage m_image;
    std::shared_ptr<QAtomicInt> m_cancelled = std::make_shared<QAtomicInt>(0);
};

// The decodes run on a pool of their own that is never destroyed (no join at exit); a worker only waits for its decoder child,
// which has a deadline and is killed at quit (AppIconProvider::shutdown), so the workers are idle or ending when Qt shuts down.
QThreadPool *decodePool()
{
    static QThreadPool *pool = [] {
        auto *p = new QThreadPool;
        p->setMaxThreadCount(3);
        return p;
    }();
    return pool;
}
} // namespace

namespace
{
// The theme icons asked for, rendered on the GUI thread a few at a time (IconProvider).
struct IconRequest {
    QPointer<IconResponse> response;
    std::shared_ptr<QAtomicInt> cancelled;
    QString id;
    QSize size;
};

class IconRenderQueue : public QObject
{
public:
    static IconRenderQueue *instance()
    {
        // Made on the GUI thread (the first IconProvider request comes from Qt's loader thread: moved there at once).
        static IconRenderQueue *queue = [] {
            auto *q = new IconRenderQueue;
            q->moveToThread(QCoreApplication::instance()->thread());
            return q;
        }();
        return queue;
    }

    void push(IconRequest request)
    {
        bool schedule = false;
        {
            QMutexLocker lock(&m_mutex);
            m_requests.append(std::move(request));
            schedule = !m_scheduled;
            m_scheduled = true;
        }
        if (schedule)
            QMetaObject::invokeMethod(this, &IconRenderQueue::run, Qt::QueuedConnection);
    }

private:
    void run()
    {
        QElapsedTimer clock;
        clock.start();
        for (;;) {
            IconRequest request;
            {
                QMutexLocker lock(&m_mutex);
                if (m_requests.isEmpty()) {
                    m_scheduled = false;
                    return;
                }
                if (clock.elapsed() >= IconProvider::kBudgetMs) {
                    // The rest on a later turn: the frame goes first.
                    QMetaObject::invokeMethod(this, &IconRenderQueue::run, Qt::QueuedConnection);
                    return;
                }
                request = m_requests.takeFirst();
            }
            if (!request.response)
                continue;
            if (request.cancelled->loadRelaxed() != 0) {
                request.response->done(QImage());
                continue;
            }
            request.response->done(IconProvider::render(request.id, request.size));
        }
    }

    QMutex m_mutex;
    QList<IconRequest> m_requests;
    bool m_scheduled = false;
};
} // namespace

QImage IconProvider::render(const QString &id, const QSize &requestedSize)
{
    const QSize want = requestedSize.isValid() && !requestedSize.isEmpty() ? requestedSize : QSize(64, 64);
    QIcon icon = QIcon::fromTheme(id);
    if (icon.isNull())
        icon = QIcon::fromTheme(id.endsWith(QLatin1String("-symbolic")) ? QStringLiteral("folder-symbolic") : QStringLiteral("text-x-generic"));
    return icon.pixmap(want).toImage();
}

QQuickImageResponse *IconProvider::requestImageResponse(const QString &id, const QSize &requestedSize)
{
    auto *response = new IconResponse;
    IconRenderQueue::instance()->push({QPointer<IconResponse>(response), response->cancelFlag(), id, requestedSize});
    return response;
}

void AppIconProvider::shutdown()
{
    // Quit: no new decode, the running children are killed (their workers return within milliseconds), then a bounded wait
    // so no worker is still inside Qt when the static destruction starts. A worker that has not yet seen the quit can still be
    // in waitForStarted (2 s) and, after the kill, in waitForFinished (1 s, appicons.cpp loadIsolated): the wait covers both.
    AppIcons::shutdown();
    decodePool()->waitForDone(3500);
}

QQuickImageResponse *AppIconProvider::requestImageResponse(const QString &id, const QSize &requestedSize)
{
    // However the process ends (aboutToQuit, or exit() from anywhere), the decoders are killed and the workers are gone before
    // Qt's static teardown: a worker still inside Qt at that point crashed Files on quit (round 4 review, SIGSEGV).
    static const bool atExit = [] {
        AppIcons::setExitHook([] { AppIconProvider::shutdown(); });
        std::atexit([] { AppIconProvider::shutdown(); });
        return true;
    }();
    Q_UNUSED(atExit)
    auto *response = new IconResponse;
    const QSize want = requestedSize.isValid() && !requestedSize.isEmpty() ? requestedSize : QSize(64, 64);
    // The roots are computed here (QStandardPaths), on the thread Qt calls the provider from, once.
    static const QStringList roots = ApplicationsLogic::iconRoots();
    QPointer<IconResponse> guard(response);
    const std::shared_ptr<QAtomicInt> cancelled = response->cancelFlag();
    decodePool()->start([guard, cancelled, id, want] {
        QImage image;
        if (cancelled->loadRelaxed() == 0)
            image = AppIcons::loadIsolated(id, roots, want);
        // Done on the GUI thread, always (also after cancel): the fallback needs the icon theme, and QIcon is only used there.
        QMetaObject::invokeMethod(
            QCoreApplication::instance(),
            [guard, image, want] {
                if (!guard)
                    return;
                if (guard->cancelled() || !image.isNull()) {
                    guard->done(image);
                    return;
                }
                QIcon icon = QIcon::fromTheme(QStringLiteral("application-x-executable"));
                if (icon.isNull())
                    icon = QIcon::fromTheme(QStringLiteral("text-x-generic"));
                guard->done(icon.pixmap(want).toImage());
            },
            Qt::QueuedConnection);
    });
    return response;
}
