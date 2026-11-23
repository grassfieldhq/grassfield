#pragma once

#include "atomicfile.h"
#include "capturehistory.h"
#include "layers.h"

#include <QImage>
#include <QString>

#include <functional>
#include <optional>

// The document of the Screenshot app: the original picture (never changed in memory), the layers over it, and the two actions
// that write (ADR-0066 D-5):
//   Done    replaces the file with the exported picture, atomically (atomicfile.h), and keeps the picture as captured and the
//           layers in the history entry, so that Revert and a later reopening find them;
//   Revert  puts the original back in the file, atomically, and clears the layers.
// A file that changed on disk since it was opened is never replaced (it was edited elsewhere): both actions refuse.
// Not thread-safe: the app calls it from the GUI thread.
namespace screenshot {

class Document
{
public:
    // `history` is not owned and outlives the document.
    explicit Document(CaptureHistory *history);

    // The picture the file holds once the layers are drawn on `original`; the default draws none (slice B3 plugs in the QPainter
    // exporter).
    using Exporter = std::function<QImage(const QImage &original, const Layers &layers)>;
    void setExporter(const Exporter &exporter) { m_exporter = exporter; }
    // Seam for tests: see atomicfile.h BeforeRename; applies to the picture's replacement (Done and Revert).
    void setBeforeRename(const BeforeRename &hook) { m_beforeRename = hook; }

    // Opens a PNG file (read whole, at most kMaxImageBytes, the header and the decode checked against the caps). A file that is
    // the edited result of an earlier Done (its digest is the history entry's `cur`) opens as its original with its layers, so
    // that editing goes on from the capture. False with `error` set when the file cannot be opened.
    bool open(const QString &path, QString *error = nullptr);

    bool isOpen() const { return !m_path.isEmpty(); }
    const QString &path() const { return m_path; }
    // The picture as captured (the history's original for an edited file).
    const QImage &original() const { return m_original; }
    const Layers &layers() const { return m_layers; }
    // Replaces the layers (the tools' commands go through this); the document is then dirty unless they equal the saved ones.
    void setLayers(const Layers &layers);
    bool dirty() const { return m_dirty; }
    // The file holds an edited result and the history still has its original.
    bool canRevert() const { return m_entry && !m_entry->current.isEmpty() && m_fileDigest == m_entry->current; }
    // The history entry of this picture, once there is one.
    const std::optional<HistoryEntry> &entry() const { return m_entry; }

    // Without changes Done writes nothing and succeeds. False with `error`: the file keeps its old bytes whole. One case
    // reports "saved, but ..." (the file was replaced, the history index could not be updated): the document then follows the
    // new file, so that a retry does not refuse.
    bool done(QString *error = nullptr);
    bool revert(QString *error = nullptr);

private:
    bool readFile(QByteArray *bytes, QString *error) const;
    bool fileUnchanged(QString *error) const;

    CaptureHistory *m_history;
    Exporter m_exporter;
    BeforeRename m_beforeRename;
    QString m_path;
    QImage m_original;
    QByteArray m_originalBytes; // the original as PNG bytes, as the file or the history held them
    Layers m_layers;
    Layers m_savedLayers;
    std::optional<HistoryEntry> m_entry;
    QString m_fileDigest; // the file's bytes when opened or last written by this document
    bool m_dirty = false;
};

} // namespace screenshot
