#include "screenshotapp.h"

#include <QFileInfo>
#include <QMutexLocker>
#include <QPointF>
#include <QRegularExpression>

#include "exporter.h"

using screenshot::CaptureHistory;

ScreenshotApp::ScreenshotApp(const QString &path, const QStringList &errors, const QString &historyRoot, QObject *parent)
    : AppearanceSettings(parent)
    , m_errors(errors)
    , m_history(historyRoot.isEmpty() ? CaptureHistory::defaultRoot() : historyRoot)
    , m_document(&m_history)
    , m_tools(&m_undo)
{
    if (!path.isEmpty()) {
        QString why;
        if (m_document.open(path, &why))
            publish();
        else
            m_errors << QStringLiteral("%1: %2").arg(path, why);
    }
}

QString ScreenshotApp::fileName() const
{
    return m_document.isOpen() ? QFileInfo(m_document.path()).fileName() : QString();
}

QString ScreenshotApp::imageSource() const
{
    return m_document.isOpen() ? QStringLiteral("image://screenshot/%1").arg(m_revision) : QString();
}

QImage ScreenshotApp::currentImage() const
{
    const QMutexLocker lock(&m_imageLock);
    return m_image;
}

void ScreenshotApp::publish()
{
    {
        const QMutexLocker lock(&m_imageLock);
        m_image = m_document.original();
    }
    ++m_revision;
    // A new document or a revert: the layers are the document's own, and nothing is left to undo.
    m_tools.cancel();
    m_undo.reset(m_document.layers());
    m_tools.select(0);
    layersEdited();
    emit documentChanged();
}

void ScreenshotApp::layersEdited()
{
    m_tools.syncSelection();
    m_document.setLayers(m_undo.layers());
    {
        const QMutexLocker lock(&m_imageLock);
        m_overlayLayers = m_undo.layers();
    }
    ++m_layersRevision;
    emit layersChanged();
    emit documentChanged(); // dirty
}

QString ScreenshotApp::overlaySource() const
{
    return m_document.isOpen() ? QStringLiteral("image://screenshot/overlay/%1").arg(m_layersRevision) : QString();
}

QImage ScreenshotApp::overlayImage(const QRectF &region, const QSize &target) const
{
    QList<screenshot::Layer> layers;
    QSize natural;
    {
        const QMutexLocker lock(&m_imageLock);
        layers = m_overlayLayers;
        natural = m_image.size();
    }
    const QRectF area = region.isEmpty() ? QRectF(QPointF(0, 0), QSizeF(natural)) : region;
    return screenshot::renderOverlayRegion(layers, area, target.isEmpty() ? natural : target);
}

qreal ScreenshotApp::captureScale() const
{
    // The capture's scale as the capture helper wrote it into the PNG ("Grassfield-Scale"); 0 when the file has none.
    bool ok = false;
    const qreal scale = m_document.original().text(QStringLiteral("Grassfield-Scale")).toDouble(&ok);
    return ok && scale >= 0.5 && scale <= 8 ? scale : 0;
}

void ScreenshotApp::setTool(const QString &tool)
{
    if (tool != m_tools.tool() && m_tools.setTool(tool)) {
        layersEdited();
        emit toolChanged();
    }
}

void ScreenshotApp::setToolColor(const QString &color)
{
    static const QRegularExpression form(QStringLiteral("^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"));
    if (color != m_tools.style().color && form.match(color).hasMatch()) {
        m_tools.style().color = color;
        emit toolChanged();
    }
}

void ScreenshotApp::setToolWidth(qreal width)
{
    if (width != m_tools.style().width && width >= screenshot::kMinStrokeWidth && width <= screenshot::kMaxStrokeWidth) {
        m_tools.style().width = width;
        emit toolChanged();
    }
}

void ScreenshotApp::setToolFill(bool fill)
{
    if (fill != m_tools.style().fill) {
        m_tools.style().fill = fill;
        emit toolChanged();
    }
}

void ScreenshotApp::setArrowStyle(const QString &style)
{
    const bool known = style == QLatin1String("straight") || style == QLatin1String("curved") || style == QLatin1String("double");
    if (known && style != m_tools.style().arrow) {
        m_tools.style().arrow = style;
        emit toolChanged();
    }
}

QVariantList ScreenshotApp::handles() const
{
    QVariantList list;
    for (const screenshot::Handle &handle : m_tools.selectionHandles())
        list.append(QVariantMap{{QStringLiteral("x"), handle.pos.x()}, {QStringLiteral("y"), handle.pos.y()}});
    return list;
}

bool ScreenshotApp::toolPress(qreal x, qreal y, qreal tolerance)
{
    if (!m_document.isOpen())
        return false;
    if (m_tools.tool() != QLatin1String("select") && m_tools.style().color.isEmpty())
        return false; // no colour set: a shape would draw nothing
    const bool started = m_tools.press(QPointF(x, y), tolerance);
    layersEdited(); // the selection may have changed
    return started;
}

void ScreenshotApp::toolMove(qreal x, qreal y, bool constrain)
{
    if (!m_tools.busy())
        return;
    m_tools.move(QPointF(x, y), constrain);
    layersEdited();
}

void ScreenshotApp::toolRelease(qreal x, qreal y, bool constrain)
{
    if (!m_tools.busy())
        return;
    m_tools.release(QPointF(x, y), constrain);
    layersEdited();
}

void ScreenshotApp::toolCancel()
{
    m_tools.cancel();
    layersEdited();
}

void ScreenshotApp::undo()
{
    m_tools.cancel();
    if (m_undo.undo())
        layersEdited();
}

void ScreenshotApp::redo()
{
    m_tools.cancel();
    if (m_undo.redo())
        layersEdited();
}

void ScreenshotApp::deleteSelected()
{
    if (m_tools.deleteSelected())
        layersEdited();
}

void ScreenshotApp::nudgeSelected(qreal dx, qreal dy)
{
    if (m_tools.nudgeSelected(QPointF(dx, dy)))
        layersEdited();
}

void ScreenshotApp::selectNone()
{
    m_tools.select(0);
    layersEdited();
}

void ScreenshotApp::setLastError(const QString &error)
{
    if (error != m_lastError) {
        m_lastError = error;
        emit lastErrorChanged();
    }
}

bool ScreenshotApp::done()
{
    QString why;
    const bool ok = m_document.done(&why);
    setLastError(ok ? QString() : why);
    emit documentChanged();
    return ok;
}

bool ScreenshotApp::revert()
{
    QString why;
    const bool ok = m_document.revert(&why);
    setLastError(ok ? QString() : why);
    if (ok)
        publish();
    else
        emit documentChanged();
    return ok;
}

ScreenshotImageProvider::ScreenshotImageProvider(ScreenshotApp *app)
    : QQuickImageProvider(QQuickImageProvider::Image)
    , m_app(app)
{
}

QImage ScreenshotImageProvider::requestImage(const QString &id, QSize *size, const QSize &requestedSize)
{
    if (id.startsWith(QLatin1String("overlay/"))) {
        // overlay/<revision>/<x>/<y>/<w>/<h>/<target w>/<target h>: the part of the picture the view shows (picture pixels) and
        // the pixels it covers; without the numbers, the whole picture at the requested size.
        const QStringList parts = id.split(QLatin1Char('/'));
        QRectF region;
        QSize target = requestedSize;
        if (parts.size() == 8) {
            bool ok[6];
            const QRectF r(parts[2].toDouble(&ok[0]), parts[3].toDouble(&ok[1]), parts[4].toDouble(&ok[2]), parts[5].toDouble(&ok[3]));
            const QSize t(parts[6].toInt(&ok[4]), parts[7].toInt(&ok[5]));
            if (ok[0] && ok[1] && ok[2] && ok[3] && ok[4] && ok[5]) {
                region = r;
                target = t;
            }
        }
        const QImage overlay = m_app->overlayImage(region, target);
        if (size)
            *size = overlay.size();
        return overlay;
    }
    const QImage image = m_app->currentImage();
    if (size)
        *size = image.size();
    return image;
}
