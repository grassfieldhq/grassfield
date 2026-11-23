#pragma once

#include <QByteArray>
#include <QList>
#include <QSize>
#include <QString>

#include <optional>

// The capture history, the part the editor needs (ADR-0066 D-5): "$XDG_STATE_HOME/grassfield/capture-history/" (0700, files
// 0600) with
//   index.json                          {"v": 1, "entries": [{id, kind, path, time, w, h, orig, cur}]}
//   <id>/original.png, <id>/layers.json  one folder per entry (id: 16 lower-case hex digits)
// The index holds no recognised text. `orig` and `cur` are the SHA-256 (hex) of the picture file as captured and as Done last
// wrote it ("" before the first Done): an entry names a file only while the file's bytes are one of the two, so a later capture
// that reuses the path never gets another picture's original back. Retention, pruning and Clear History are slice B14.
namespace screenshot {

struct HistoryEntry {
    QString id;
    QString kind;     // "shot"
    QString path;     // the picture file
    qint64 time = 0;  // seconds since the epoch, when the entry was made
    int width = 0;    // device pixels of the original
    int height = 0;
    QString original; // SHA-256 of the file as captured
    QString current;  // SHA-256 of the file as Done last wrote it, "" before
};

constexpr int kMaxHistoryEntries = 5000;
constexpr qint64 kMaxIndexBytes = 8 * 1024 * 1024;

class CaptureHistory
{
public:
    explicit CaptureHistory(const QString &root);

    // runmode::stateDir() + "/capture-history".
    static QString defaultRoot();
    static QString sha256(const QByteArray &bytes);
    static bool validId(const QString &id);

    const QString &root() const { return m_root; }
    QString originalPath(const QString &id) const;
    QString layersPath(const QString &id) const;

    // The entries of the index; empty when it is missing, unreadable or invalid (history then starts empty). Entries with an
    // invalid id or a field out of its type are dropped.
    QList<HistoryEntry> entries() const;

    // The entry of the picture at `path` whose original or edited digest is `digest`.
    std::optional<HistoryEntry> find(const QString &path, const QString &digest) const;

    // Makes the entry of a picture: its folder with original.png (the file's own bytes) and an empty layers.json, and its
    // line in the index. An older entry of the same path goes (its folder too). False with `error` when anything failed; nothing
    // stays half made (the folder is removed).
    bool add(const QString &path, const QByteArray &originalBytes, const QSize &pixels, HistoryEntry *entry, QString *error = nullptr);

    // layers.json of an entry (atomic), and the digest of the file as Done wrote it ("" after a Revert).
    bool writeLayers(const QString &id, const QByteArray &layers, QString *error = nullptr);
    bool setCurrent(const QString &id, const QString &digest, QString *error = nullptr);

    // original.png and layers.json of an entry; empty when absent or unreadable (or larger than the caps).
    QByteArray readOriginal(const QString &id) const;
    QByteArray readLayers(const QString &id) const;

private:
    bool ensureRoot(QString *error) const;
    bool writeIndex(const QList<HistoryEntry> &entries, QString *error) const;
    QString m_root;
};

} // namespace screenshot
