#include "document.h"

#include "exporter.h"
#include "screenshotlogic.h"

#include <QBuffer>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>

namespace screenshot {

namespace {

// A PNG's bytes as a picture within the caps; null when they are not one.
QImage decodePng(const QByteArray &bytes)
{
    if (!imageSizeAllowed(pngSize(bytes.left(32))))
        return {};
    QBuffer buffer;
    buffer.setData(bytes);
    if (!buffer.open(QIODevice::ReadOnly))
        return {};
    QImageReader reader(&buffer, "png");
    reader.setAutoTransform(false);
    const QImage image = reader.read();
    return imageSizeAllowed(image.size()) ? image : QImage();
}

} // namespace

Document::Document(CaptureHistory *history)
    : m_history(history)
    , m_exporter(exportLayers)
{
}

bool Document::readFile(QByteArray *bytes, QString *error) const
{
    QFile file(m_path);
    if (!file.open(QIODevice::ReadOnly) || file.size() > kMaxImageBytes) {
        if (error)
            *error = QStringLiteral("cannot read the picture file");
        return false;
    }
    *bytes = file.readAll();
    return true;
}

bool Document::fileUnchanged(QString *error) const
{
    QByteArray bytes;
    if (!readFile(&bytes, error))
        return false;
    if (CaptureHistory::sha256(bytes) != m_fileDigest) {
        if (error)
            *error = QStringLiteral("the picture file changed since it was opened");
        return false;
    }
    return true;
}

bool Document::open(const QString &path, QString *error)
{
    const auto fail = [error](const QString &why) {
        if (error)
            *error = why;
        return false;
    };
    const QString previousPath = m_path;
    m_path = path;
    QByteArray bytes;
    if (!readFile(&bytes, error)) {
        m_path = previousPath;
        return false;
    }
    const QImage image = decodePng(bytes);
    if (image.isNull()) {
        m_path = previousPath;
        return fail(QStringLiteral("not a PNG picture within the size limits"));
    }
    m_original = image;
    m_originalBytes = bytes;
    m_layers.clear();
    m_savedLayers.clear();
    m_dirty = false;
    m_fileDigest = CaptureHistory::sha256(bytes);
    m_entry = m_history->find(path, m_fileDigest);
    if (m_entry && m_entry->current == m_fileDigest) {
        // The file is the result of an earlier Done: editing goes on from the capture and its layers.
        const QByteArray original = m_history->readOriginal(m_entry->id);
        const QImage originalImage = decodePng(original);
        if (!originalImage.isNull() && CaptureHistory::sha256(original) == m_entry->original) {
            m_original = originalImage;
            m_originalBytes = original;
            Layers layers;
            if (layersFromJson(m_history->readLayers(m_entry->id), &layers))
                m_layers = layers;
            m_savedLayers = m_layers;
        } else {
            m_entry.reset(); // the history lost the original: the file is all there is
        }
    }
    return true;
}

void Document::setLayers(const Layers &layers)
{
    m_layers = layers;
    m_dirty = m_layers != m_savedLayers;
}

bool Document::done(QString *error)
{
    const auto fail = [error](const QString &why) {
        if (error)
            *error = why;
        return false;
    };
    if (!isOpen())
        return fail(QStringLiteral("no picture is open"));
    if (!m_dirty)
        return true;
    QString why;
    if (!fileUnchanged(&why))
        return fail(why);

    // The original goes to the history first: whatever fails after this, Revert has it.
    if (!m_entry) {
        HistoryEntry entry;
        if (!m_history->add(m_path, m_originalBytes, m_original.size(), &entry, &why))
            return fail(why);
        m_entry = entry;
    }
    if (!m_history->writeLayers(m_entry->id, layersToJson(m_layers), &why))
        return fail(why);

    const QImage exported = m_exporter ? m_exporter(m_original, m_layers) : m_original;
    QByteArray png;
    QBuffer buffer(&png);
    if (exported.isNull() || !buffer.open(QIODevice::WriteOnly) || !exported.save(&buffer, "PNG") || png.isEmpty() || png.size() > kMaxImageBytes)
        return fail(QStringLiteral("cannot encode the picture"));
    if (!atomicWrite(m_path, png, -1, &why, m_beforeRename))
        return fail(why);

    const QString digest = CaptureHistory::sha256(png);
    m_fileDigest = digest;
    m_savedLayers = m_layers;
    m_dirty = false;
    m_entry->current = digest;
    if (!m_history->setCurrent(m_entry->id, digest, &why))
        return fail(QStringLiteral("saved, but the history entry could not be updated: %1").arg(why));
    return true;
}

bool Document::revert(QString *error)
{
    const auto fail = [error](const QString &why) {
        if (error)
            *error = why;
        return false;
    };
    if (!isOpen() || !canRevert())
        return fail(QStringLiteral("nothing to revert"));
    QString why;
    if (!fileUnchanged(&why))
        return fail(why);
    const QByteArray original = m_history->readOriginal(m_entry->id);
    if (decodePng(original).isNull() || CaptureHistory::sha256(original) != m_entry->original)
        return fail(QStringLiteral("the original picture is missing from the history"));
    if (!atomicWrite(m_path, original, -1, &why, m_beforeRename))
        return fail(why);

    m_fileDigest = m_entry->original;
    m_layers.clear();
    m_savedLayers.clear();
    m_dirty = false;
    m_entry->current.clear();
    if (!m_history->writeLayers(m_entry->id, layersToJson({}), &why) || !m_history->setCurrent(m_entry->id, QString(), &why))
        return fail(QStringLiteral("reverted, but the history entry could not be updated: %1").arg(why));
    return true;
}

} // namespace screenshot
