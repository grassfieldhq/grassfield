// Screenshots of a product page (spec SR10, owner ST6): image://screenshot/<the https URL, percent-encoded>. Each one is
// fetched with the Store's own request (fetch.h: https only, no cookie, no Referer, at most 8 MiB in 15 s), decoded off the
// GUI thread with Qt's decoders under the app's allocation limit, and scaled to the size asked for. Never cached on disk.
// The window asks for one only through StoreBackend::screenshotSource, which is "" while screenshots are off or offline;
// the provider checks the backend's gate again right before each fetch, so a page opened earlier fetches nothing once the
// Store is offline. A screenshot the page no longer wants (cancel: the page went, SU-06 note) leaves the queue, or aborts
// its transfer: flipping through product pages never queues their downloads ahead of the page shown.
#pragma once

#include <QQuickAsyncImageProvider>
#include <QThreadPool>

#include <atomic>
#include <memory>

namespace grassfield::store {

class ScreenshotProvider : public QQuickAsyncImageProvider
{
public:
    explicit ScreenshotProvider(std::shared_ptr<const std::atomic_bool> allowed);
    QQuickImageResponse *requestImageResponse(const QString &id, const QSize &requestedSize) override;

private:
    std::shared_ptr<const std::atomic_bool> m_allowed;
    QThreadPool m_pool;
};

} // namespace grassfield::store
