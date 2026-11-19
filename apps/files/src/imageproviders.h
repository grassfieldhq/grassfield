#pragma once

#include <QHash>
#include <QImage>
#include <QMutex>
#include <QQuickAsyncImageProvider>
#include <QQuickImageProvider>
#include <QString>

// Thumbnails produced by KIO::PreviewJob, keyed by an opaque id. Written on the GUI thread by
// FolderModel, read by ThumbnailProvider (possibly on the QML image thread), hence the mutex.
class ThumbnailStore
{
public:
    static QString insert(const QImage &image);
    static QImage value(const QString &key);
    static void remove(const QString &key);
    static int size();

private:
    static QMutex s_mutex;
    static QHash<QString, QImage> s_images;
    static quint64 s_serial;
};

// image://thumbnail/<key>
class ThumbnailProvider : public QQuickImageProvider
{
public:
    ThumbnailProvider();
    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;
};

// image://icon/<freedesktop icon name>: the current icon theme through QIcon. Asynchronous for QML (an icon never rasterises on
// the frame that creates its delegate: the first appearance of each type was a hitch when scrolling), but QIcon is only ever
// touched on the GUI thread: QIcon's theme cache has no lock, and a provider that rendered on Qt's image-loader thread raced
// the GUI thread's QIcon::hasThemeIcon (FolderModel, PlacesModel): a segfault in an earlier review's stress run. Requests are
// queued to the GUI thread and rendered there a few milliseconds per event loop turn (kBudgetMs), oldest first; a cancelled
// one is finished empty. tst_imageproviders.cpp pins both.
class IconProvider : public QQuickAsyncImageProvider
{
public:
    static constexpr int kBudgetMs = 4;
    QQuickImageResponse *requestImageResponse(const QString &id, const QSize &requestedSize) override;
    // The rendering itself (GUI thread only).
    static QImage render(const QString &id, const QSize &requestedSize);
};

// image://appicon/<absolute path of an application's Icon= file>: validated and decoded off the GUI thread by AppIcons::load
// (PNG, or SVG that refers to nothing else; sizes capped; never a FIFO, device or other format) in a child process with a
// deadline (AppIcons::loadIsolated), never touching QIcon there. What is refused answers the generic application icon (taken from the theme on the GUI thread, where QIcon is safe).
class AppIconProvider : public QQuickAsyncImageProvider
{
public:
    QQuickImageResponse *requestImageResponse(const QString &id, const QSize &requestedSize) override;
    // Connect to aboutToQuit: kills the decoder children and waits (at most 1.5 s) for the workers, so a quit never races them.
    static void shutdown();
};
