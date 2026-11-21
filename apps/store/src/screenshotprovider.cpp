#include "screenshotprovider.h"

#include "catalog.h"
#include "fetch.h"

#include <QBuffer>
#include <QImageReader>
#include <QRunnable>
#include <QUrl>

#include <utility>

namespace grassfield::store {

namespace {

constexpr qint64 kScreenshotMax = 8 * 1024 * 1024;
constexpr int kScreenshotMs = 15000;
constexpr int kMaxSide = 8192;

class ScreenshotResponse : public QQuickImageResponse, public QRunnable
{
public:
    ScreenshotResponse(const QString &url, const QSize &requested, std::shared_ptr<const std::atomic_bool> allowed, QThreadPool *pool)
        : m_url(url)
        , m_requested(requested)
        , m_allowed(std::move(allowed))
        , m_pool(pool)
    {
        setAutoDelete(false); // the engine deletes the response once it has `finished`
    }

    QQuickTextureFactory *textureFactory() const override { return QQuickTextureFactory::textureFactoryForImage(m_image); }
    QString errorString() const override { return m_error; }

    // The image is no longer wanted (its page went, or the source changed): one still waiting for a thread leaves the queue at
    // once, so the pages shown next never wait behind it; one being fetched aborts its transfer (FetchCancelScope). Either way
    // `finished` follows, as the engine needs to delete it.
    void cancel() override
    {
        *m_cancel = true;
        if (m_pool && m_pool->tryTake(this)) {
            m_error = QStringLiteral("cancelled");
            emit finished();
        }
    }

    void run() override
    {
        {
            const FetchCancelScope scope(m_cancel);
            if (m_cancel->load())
                m_error = QStringLiteral("cancelled");
            else
                load();
        }
        emit finished(); // from this thread: QQuickImageResponse allows it
    }

private:
    void load()
    {
        if (!m_allowed || !m_allowed->load()) {
            m_error = QStringLiteral("screenshots are off or the Store is offline");
            return;
        }
        if (!isHttpsUrl(m_url)) {
            m_error = QStringLiteral("not an https address");
            return;
        }
        FetchResult r = fetch(QUrl(m_url), FetchLimits{kScreenshotMax, kScreenshotMs});
        if (m_cancel->load()) {
            m_error = QStringLiteral("cancelled");
            return;
        }
        if (r.status != FetchResult::Status::Ok) {
            m_error = r.error.isEmpty() ? QStringLiteral("not fetched") : r.error;
            return;
        }
        QBuffer buffer(&r.body);
        buffer.open(QIODevice::ReadOnly);
        QImageReader reader(&buffer);
        static const QList<QByteArray> formats{"png", "jpeg", "jpg", "webp"};
        const QSize size = reader.size();
        if (!formats.contains(reader.format()) || !size.isValid() || size.width() > kMaxSide || size.height() > kMaxSide) {
            m_error = QStringLiteral("not a picture the Store shows");
            return;
        }
        if (m_requested.isValid() && (m_requested.width() < size.width() || m_requested.height() < size.height()))
            reader.setScaledSize(size.scaled(m_requested.width() > 0 ? m_requested.width() : size.width(),
                                             m_requested.height() > 0 ? m_requested.height() : size.height(), Qt::KeepAspectRatio));
        m_image = reader.read();
        if (m_image.isNull())
            m_error = reader.errorString();
    }

    QString m_url;
    QSize m_requested;
    std::shared_ptr<const std::atomic_bool> m_allowed;
    QThreadPool *m_pool = nullptr;
    std::shared_ptr<std::atomic_bool> m_cancel = std::make_shared<std::atomic_bool>(false);
    QImage m_image;
    QString m_error;
};

} // namespace

ScreenshotProvider::ScreenshotProvider(std::shared_ptr<const std::atomic_bool> allowed)
    : m_allowed(std::move(allowed))
{
    m_pool.setMaxThreadCount(2);
}

QQuickImageResponse *ScreenshotProvider::requestImageResponse(const QString &id, const QSize &requestedSize)
{
    auto *response = new ScreenshotResponse(QUrl::fromPercentEncoding(id.toLatin1()), requestedSize, m_allowed, &m_pool);
    m_pool.start(response);
    return response;
}

} // namespace grassfield::store
