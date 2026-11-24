#include "screenshotapp.h"

#include <QFileInfo>
#include <QMutexLocker>
#include <QPointF>
#include <QRegularExpression>

#include <cmath>


using screenshot::applyFrame;
using screenshot::CaptureHistory;
using screenshot::Frame;
using screenshot::frameOf;

ScreenshotApp::ScreenshotApp(const QString &path, const QStringList &errors, const QString &historyRoot, QObject *parent)
    : AppearanceSettings(parent)
    , m_errors(errors)
    , m_history(historyRoot.isEmpty() ? CaptureHistory::defaultRoot() : historyRoot)
    , m_document(&m_history)
    , m_tools(&m_undo)
{
    // A stroke is previewed once a frame, not at every sample of the pointer (a move then costs the same however long the stroke is).
    m_tools.setDeferPreview(true);
    m_flushTimer.setSingleShot(true);
    m_flushTimer.setInterval(16);
    connect(&m_flushTimer, &QTimer::timeout, this, [this] {
        if (m_tools.previewPending()) {
            m_tools.flushPreview();
            layersEdited();
        }
    });
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

namespace {

bool validColor(const QString &color)
{
    static const QRegularExpression form(QStringLiteral("^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"));
    return form.match(color).hasMatch();
}

} // namespace

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
    m_frame = frameOf(m_document.layers());
    {
        const QMutexLocker lock(&m_imageLock);
        m_image = applyFrame(m_document.original(), m_frame);
    }
    ++m_revision;
    // A new document or a revert: the layers are the document's own, and nothing is left to undo.
    m_tools.cancel();
    m_crop.cancel();
    m_crop.reset(m_image.size());
    m_picking = false;
    if (m_textEditing) {
        m_textEditing = false;
        emit textEditChanged();
    }
    m_undo.reset(m_document.layers());
    m_tools.select(0);
    layersEdited();
    emit cropChanged();
    emit pictureChanged();
    emit documentChanged();
}

void ScreenshotApp::refreshPicture()
{
    {
        const QMutexLocker lock(&m_imageLock);
        m_image = applyFrame(m_document.original(), m_frame);
    }
    ++m_revision;
    m_crop.reset(m_image.size());
    emit cropChanged();
    emit pictureChanged();
}

void ScreenshotApp::layersEdited()
{
    m_tools.syncSelection();
    // The frame layer (crop, rotation, flip) decides the picture: an edit of it, or its undo, shows another.
    const Frame frame = frameOf(m_undo.layers());
    if (frame != m_frame) {
        m_frame = frame;
        refreshPicture();
    }
    if (m_tools.selected() != m_lastSelected) {
        m_lastSelected = m_tools.selected();
        if (m_lastSelected != 0)
            adoptStyle(m_tools.selectedLayer());
    }
    m_document.setLayers(m_undo.layers());
    m_layerModel.setLayers(m_undo.layers());
    emit layersChanged();
    // A move changes geometry only: documentChanged (dirty, and everything that hangs on the document) only when the state does.
    if (m_document.dirty() != m_lastDirty) {
        m_lastDirty = m_document.dirty();
        emit documentChanged();
    }
}

qreal ScreenshotApp::captureScale() const
{
    // The capture's scale as the capture helper wrote it into the PNG ("Grassfield-Scale"); 0 when the file has none.
    bool ok = false;
    const qreal scale = m_document.original().text(QStringLiteral("Grassfield-Scale")).toDouble(&ok);
    return ok && scale >= 0.5 && scale <= 8 ? scale : 0;
}

void ScreenshotApp::adoptStyle(const screenshot::Layer &layer)
{
    screenshot::ShapeStyle &style = m_tools.style();
    const screenshot::ShapeStyle before = style;
    const QColor color = screenshot::layerColor(layer);
    if (color.isValid())
        style.color = color.name(); // the colour without its alpha: a highlighter's see-through is the tool's
    if (screenshot::isTextType(layer.type)) {
        qreal size = layer.fields.value(QStringLiteral("size")).toDouble();
        if (size >= screenshot::kMinTextSize && size <= screenshot::kMaxTextSize)
            (layer.type == QLatin1String("text") ? style.textSize : style.counterSize) = size;
        if (layer.type == QLatin1String("text"))
            style.textStyle = layer.fields.value(QStringLiteral("style")).toString() == QLatin1String("outlined") ? QStringLiteral("outlined")
                : layer.fields.value(QStringLiteral("style")).toString() == QLatin1String("pill") ? QStringLiteral("pill") : QStringLiteral("plain");
    } else if (screenshot::layerWidth(layer) > 0) {
        style.width = screenshot::layerWidth(layer) / (layer.type == QLatin1String("highlighter") ? std::max(1.0, style.highlightFactor) : 1.0);
        if (layer.type == QLatin1String("rectangle") || layer.type == QLatin1String("ellipse"))
            style.fill = screenshot::layerFill(layer);
        if (layer.type == QLatin1String("arrow"))
            style.arrow = screenshot::arrowStyle(layer);
    }
    if (style.color != before.color || style.width != before.width || style.fill != before.fill || style.arrow != before.arrow
        || style.textSize != before.textSize || style.counterSize != before.counterSize || style.textStyle != before.textStyle)
        emit toolChanged();
}

void ScreenshotApp::setTool(const QString &tool)
{
    if (tool != m_tools.tool()) {
        finishText();
        m_flushTimer.stop();
    }
    if (tool != m_tools.tool() && m_tools.setTool(tool)) {
        m_picking = false;
        m_crop.cancel();
        m_crop.reset(m_image.size()); // a pending crop is given up with the tool
        layersEdited();
        emit toolChanged();
        emit cropChanged();
    }
}

void ScreenshotApp::setTextStyle(const QString &style)
{
    const bool known = style == QLatin1String("plain") || style == QLatin1String("outlined") || style == QLatin1String("pill");
    if (known && style != m_tools.style().textStyle) {
        m_tools.style().textStyle = style;
        emit toolChanged();
    }
}

void ScreenshotApp::setTextSize(qreal size)
{
    if (size != m_tools.style().textSize && size >= screenshot::kMinTextSize && size <= screenshot::kMaxTextSize) {
        m_tools.style().textSize = size;
        emit toolChanged();
    }
}

void ScreenshotApp::setTextFamily(const QString &family)
{
    if (!family.isEmpty() && family != m_tools.style().family) {
        m_tools.style().family = family;
        emit toolChanged();
    }
}

void ScreenshotApp::setCounterSize(qreal size)
{
    if (size != m_tools.style().counterSize && size >= screenshot::kMinTextSize && size <= screenshot::kMaxTextSize) {
        m_tools.style().counterSize = size;
        emit toolChanged();
    }
}

void ScreenshotApp::setHighlightFactor(qreal factor)
{
    if (factor != m_tools.style().highlightFactor && factor >= 1 && factor <= 20) {
        m_tools.style().highlightFactor = factor;
        emit toolChanged();
    }
}

void ScreenshotApp::setHighlightOpacity(qreal opacity)
{
    if (opacity != m_tools.style().highlightOpacity && opacity >= 0.05 && opacity <= 1) {
        m_tools.style().highlightOpacity = opacity;
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
    finishText(); // a press anywhere puts in the text being typed (the editor's own click-away does it too)
    const QString tool = m_tools.tool();
    if (tool == QLatin1String("eyedropper")) {
        const QString color = pixelColorAt(x, y);
        if (color.isEmpty())
            return false;
        m_picking = true;
        previewPick(color);
        return true;
    }
    if (tool == QLatin1String("crop")) {
        const bool started = m_crop.press(QPointF(x, y), tolerance);
        emit cropChanged();
        return started;
    }
    if (tool == QLatin1String("text")) {
        if (m_tools.style().color.isEmpty())
            return false;
        // A press on a text edits it; anywhere else a new one starts there.
        const screenshot::Layers &layers = m_undo.layers();
        for (int i = layers.size() - 1; i >= 0; --i) {
            if (layers[i].type == QLatin1String("text") && screenshot::hitLayer(layers[i], QPointF(x, y), tolerance)) {
                m_tools.select(layers[i].id);
                layersEdited();
                beginText(layers[i].id, screenshot::layerBounds(layers[i]).topLeft(), screenshot::layerText(layers[i]));
                return true;
            }
        }
        beginText(0, QPointF(x, y), QString());
        return true;
    }
    if (tool != QLatin1String("select") && m_tools.style().color.isEmpty())
        return false; // no colour set: a shape would draw nothing
    const bool started = m_tools.press(QPointF(x, y), tolerance);
    layersEdited(); // the selection may have changed
    return started;
}

void ScreenshotApp::toolMove(qreal x, qreal y, bool constrain)
{
    if (m_picking) {
        const QString color = pixelColorAt(x, y);
        if (!color.isEmpty())
            previewPick(color);
        return;
    }
    if (m_crop.busy()) {
        m_crop.move(QPointF(x, y));
        emit cropChanged();
        return;
    }
    if (!m_tools.busy())
        return;
    m_tools.move(QPointF(x, y), constrain);
    if (m_tools.previewPending()) {
        if (!m_flushTimer.isActive())
            m_flushTimer.start();
        return;
    }
    layersEdited();
}

void ScreenshotApp::toolRelease(qreal x, qreal y, bool constrain)
{
    if (m_picking) {
        const QString color = pixelColorAt(x, y);
        if (!color.isEmpty())
            previewPick(color);
        m_picking = false;
        m_undo.commitGesture(); // one step for the whole drag, none when the colour did not change
        layersEdited();
        return;
    }
    if (m_crop.busy()) {
        m_crop.release(QPointF(x, y));
        emit cropChanged();
        return;
    }
    if (!m_tools.busy())
        return;
    m_flushTimer.stop();
    m_tools.release(QPointF(x, y), constrain);
    layersEdited();
}

void ScreenshotApp::toolCancel()
{
    m_flushTimer.stop();
    m_picking = false;
    if (m_crop.busy()) {
        m_crop.cancel();
        emit cropChanged();
    }
    m_tools.cancel();
    layersEdited();
}

void ScreenshotApp::undo()
{
    finishText();
    m_tools.cancel();
    if (m_undo.undo())
        layersEdited();
}

void ScreenshotApp::redo()
{
    finishText();
    m_tools.cancel();
    if (m_undo.redo())
        layersEdited();
}

void ScreenshotApp::deleteSelected()
{
    finishText(); // from the menu: the text is put in, then the selection (which is that text) goes; the key is the editor's while typing
    if (m_tools.deleteSelected())
        layersEdited();
}

void ScreenshotApp::nudgeSelected(qreal dx, qreal dy)
{
    finishText();
    if (m_tools.nudgeSelected(QPointF(dx, dy)))
        layersEdited();
}

void ScreenshotApp::selectNone()
{
    finishText();
    m_tools.select(0);
    layersEdited();
}

void ScreenshotApp::restyleSelection(const std::function<screenshot::Layer(const screenshot::Layer &)> &edit)
{
    if (m_textEditing) {
        // While a text is typed a style change is the text's, part of the same edit (macOS: the controls act on what is being typed): it
        // goes in the preview, never into a step of its own, and never on another layer.
        m_textRestyles.append(edit);
        previewText(m_textPreview);
        return;
    }
    const screenshot::Layer layer = m_tools.selectedLayer();
    if (layer.id == 0 || m_tools.busy())
        return;
    const screenshot::Layer out = edit(layer);
    if (out != layer && m_tools.replaceSelected(out))
        layersEdited();
}

void ScreenshotApp::applyColor(const QString &color)
{
    if (!validColor(color))
        return;
    setToolColor(color);
    restyleSelection([color](const screenshot::Layer &layer) { return screenshot::withColor(layer, color); });
}

void ScreenshotApp::applyWidth(qreal width)
{
    if (!(width >= screenshot::kMinStrokeWidth && width <= screenshot::kMaxStrokeWidth))
        return;
    setToolWidth(width);
    const qreal factor = m_tools.style().highlightFactor;
    restyleSelection([width, factor](const screenshot::Layer &layer) {
        return screenshot::withWidth(layer, layer.type == QLatin1String("highlighter") ? width * factor : width);
    });
}

void ScreenshotApp::applyFill(bool fill)
{
    setToolFill(fill);
    restyleSelection([fill](const screenshot::Layer &layer) { return screenshot::withFill(layer, fill); });
}

void ScreenshotApp::applyTextStyle(const QString &style)
{
    if (style != QLatin1String("plain") && style != QLatin1String("outlined") && style != QLatin1String("pill"))
        return; // not a style: neither the next text's nor the selection's
    setTextStyle(style);
    restyleSelection([style](const screenshot::Layer &layer) { return screenshot::withTextStyle(layer, style); });
}

void ScreenshotApp::applyTextSize(qreal size)
{
    if (!(size >= screenshot::kMinTextSize && size <= screenshot::kMaxTextSize))
        return;
    setTextSize(size);
    restyleSelection([size](const screenshot::Layer &layer) { return layer.type == QLatin1String("text") ? screenshot::withTextSize(layer, size) : layer; });
}

void ScreenshotApp::applyCounterSize(qreal size)
{
    if (!(size >= screenshot::kMinTextSize && size <= screenshot::kMaxTextSize))
        return;
    setCounterSize(size);
    restyleSelection([size](const screenshot::Layer &layer) { return layer.type == QLatin1String("counter") ? screenshot::withTextSize(layer, size) : layer; });
}

QString ScreenshotApp::pixelColorAt(qreal x, qreal y) const
{
    if (!std::isfinite(x) || !std::isfinite(y))
        return {};
    const QImage image = m_image;
    // The pixel the point is in: a picture's pixel i spans [i, i + 1) whatever the scale of the display it was taken on.
    const double fx = std::floor(x), fy = std::floor(y);
    if (image.isNull() || fx < 0 || fy < 0 || fx >= image.width() || fy >= image.height())
        return {};
    const QColor pixel = image.pixelColor(int(fx), int(fy));
    return QColor(pixel.red(), pixel.green(), pixel.blue()).name();
}

void ScreenshotApp::previewPick(const QString &color)
{
    setToolColor(color);
    const screenshot::Layer selected = m_tools.selectedLayer();
    if (selected.id == 0)
        return;
    screenshot::Layers next = m_undo.gestureBase();
    for (screenshot::Layer &layer : next) {
        if (layer.id == selected.id)
            layer = screenshot::withColor(layer, color);
    }
    if (next != m_undo.layers()) {
        m_undo.preview(next);
        layersEdited();
    }
}

QString ScreenshotApp::pickColor(qreal x, qreal y)
{
    const QString color = pixelColorAt(x, y);
    if (color.isEmpty())
        return {};
    previewPick(color);
    if (!m_picking) {
        m_undo.commitGesture();
        layersEdited();
    }
    return color;
}

void ScreenshotApp::beginText(int id, const QPointF &pos, const QString &text)
{
    finishText(); // another text being typed is put in first: one gesture at a time
    m_tools.cancel();
    m_textRestyles.clear();
    m_textAnchor = pos;
    m_textEditing = true;
    m_textEditId = id;
    m_textEditPos = pos;
    m_textEditText = text;
    m_textPreview = text;
    emit textEditChanged();
}

void ScreenshotApp::editSelectedText()
{
    const screenshot::Layer layer = m_tools.selectedLayer();
    if (layer.type == QLatin1String("text") && !m_tools.busy())
        beginText(layer.id, screenshot::layerBounds(layer).topLeft(), screenshot::layerText(layer));
}

void ScreenshotApp::previewText(const QString &typed)
{
    if (!m_textEditing)
        return;
    const QString text = typed.left(screenshot::kMaxTextLength);
    m_textPreview = text;
    const screenshot::Layers base = m_undo.gestureBase();
    screenshot::Layers next = base;
    screenshot::Layer shown;
    if (m_textEditId == 0) {
        const int id = screenshot::nextLayerId(base);
        shown = screenshot::makeText(id, m_textAnchor, text, m_tools.style());
        if (shown.id != 0) {
            // The click is where the text begins, not its middle.
            shown = screenshot::translated(shown, m_textAnchor - screenshot::layerBounds(shown).topLeft());
            if (next.size() < screenshot::kMaxLayers)
                next.append(shown);
        }
    } else {
        for (int i = 0; i < next.size(); ++i) {
            if (next[i].id != m_textEditId)
                continue;
            const screenshot::Layer before = next[i];
            if (text.trimmed().isEmpty()) {
                next.removeAt(i); // erasing all of a text takes it away
            } else {
                screenshot::Layer styled = before;
                for (const auto &restyle : std::as_const(m_textRestyles))
                    styled = restyle(styled);
                shown = screenshot::withText(styled, text);
                if (before.fields.value(QStringLiteral("rot")).toInt() == 0) // the text stays where it began
                    shown = screenshot::translated(shown, screenshot::layerBounds(before).topLeft() - screenshot::layerBounds(shown).topLeft());
                next[i] = shown;
            }
            break;
        }
    }
    if (next != m_undo.layers() || m_undo.inGesture()) {
        m_undo.preview(next);
        layersEdited();
    }
    if (shown.id != 0) {
        // The editor goes where the lettering is (a pill's text starts inside its plate).
        const QPointF at = screenshot::shapeGeometry(shown).layoutBox.topLeft();
        if (at != m_textEditPos) {
            m_textEditPos = at;
            emit textEditChanged();
        }
    }
}

void ScreenshotApp::finishText()
{
    if (m_textEditing)
        commitText(m_textPreview);
}

void ScreenshotApp::commitText(const QString &text)
{
    if (!m_textEditing)
        return;
    previewText(text);
    const int id = m_textEditId;
    m_textEditing = false;
    emit textEditChanged();
    const bool changed = m_undo.commitGesture(); // the whole edit is one step
    if (changed) {
        const screenshot::Layers &layers = m_undo.layers();
        m_tools.select(id != 0 ? id : (layers.isEmpty() ? 0 : layers.last().id));
    }
    layersEdited();
}

void ScreenshotApp::cancelText()
{
    if (!m_textEditing)
        return;
    m_textEditing = false;
    emit textEditChanged();
    m_undo.cancelGesture();
    layersEdited();
}

void ScreenshotApp::commitFrame(const screenshot::Layers &next)
{
    finishText();
    if (!m_document.isOpen() || m_tools.busy() || next == m_undo.layers())
        return;
    m_tools.cancel();
    if (m_undo.commit(next))
        layersEdited();
}

void ScreenshotApp::setCropAspect(const QString &name)
{
    if (m_crop.setAspect(name))
        emit cropChanged();
}

void ScreenshotApp::applyCrop()
{
    if (m_tools.tool() != QLatin1String("crop") || !m_crop.changes())
        return;
    commitFrame(screenshot::croppedLayers(m_undo.layers(), m_document.original().size(), m_crop.pixelRect()));
}

void ScreenshotApp::cancelCrop()
{
    m_crop.cancel();
    m_crop.reset(m_image.size());
    emit cropChanged();
}

void ScreenshotApp::rotateLeft()
{
    commitFrame(screenshot::rotatedLayers(m_undo.layers(), m_document.original().size(), 3));
}

void ScreenshotApp::rotateRight()
{
    commitFrame(screenshot::rotatedLayers(m_undo.layers(), m_document.original().size(), 1));
}

void ScreenshotApp::flipHorizontal()
{
    commitFrame(screenshot::flippedLayers(m_undo.layers(), m_document.original().size(), true));
}

void ScreenshotApp::flipVertical()
{
    commitFrame(screenshot::flippedLayers(m_undo.layers(), m_document.original().size(), false));
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
    finishText(); // the text being typed is part of what Done writes
    QString why;
    const bool ok = m_document.done(&why);
    setLastError(ok ? QString() : why);
    m_lastDirty = m_document.dirty();
    emit documentChanged();
    return ok;
}

bool ScreenshotApp::revert()
{
    QString why;
    const bool ok = m_document.revert(&why);
    setLastError(ok ? QString() : why);
    m_lastDirty = m_document.dirty();
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

QImage ScreenshotImageProvider::requestImage(const QString &, QSize *size, const QSize &)
{
    const QImage image = m_app->currentImage();
    if (size)
        *size = image.size();
    return image;
}
