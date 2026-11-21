// The pure part of grassfield-clipboard-helper (ADR-0034): what a copy may become from its MIME types alone, what its data makes
// of it, the history and the pinned items with their limits and retention, the search, and the escaping of the line protocol. No
// Wayland, no files, no clock: everything that decides is here and under tests/unit/clipboard-helper.
#pragma once

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>

namespace ClipLogic
{
// Limits (ADR-0034 §1).
constexpr int kMaxTypes = 64;
constexpr int kMaxTypeLength = 255;
constexpr qint64 kPlainCap = 256 * 1024;
constexpr qint64 kHtmlCap = 1024 * 1024;
constexpr qint64 kRtfCap = 1024 * 1024;
constexpr qint64 kFilesCap = 64 * 1024;
constexpr int kMaxFiles = 1000;
constexpr qint64 kImageCap = 16 * 1024 * 1024;
constexpr int kHistoryItems = 100;
constexpr qint64 kHistoryBytes = 64LL * 1024 * 1024;
constexpr int kPinnedItems = 50;
constexpr qint64 kPinnedBytes = 32LL * 1024 * 1024;
constexpr int kTitleChars = 200;
constexpr int kExcerptChars = 400;
constexpr int kThumbnailPx = 256;
constexpr int kPreviewPx = 1024;
constexpr int kMaxImageSide = 8192;
constexpr qint64 kMaxImagePixels = 64LL * 1000 * 1000;
constexpr qint64 kThumbnailBytes = 1024 * 1024;
// The retention the helper accepts (the shell sends 30 minutes, 8 hours or 7 days; tests a few seconds).
constexpr qint64 kMinRetentionMs = 1000;
constexpr qint64 kMaxRetentionMs = 7LL * 24 * 3600 * 1000;
// A paste answer: closed after this long without progress (the reader stopped), and after this long in all (a reader that
// trickles forever never holds one of the helper's writers).
constexpr qint64 kWriterIdleMs = 2000;
constexpr qint64 kWriterMaxMs = 60 * 1000;
constexpr qint64 kDefaultRetentionMs = 8LL * 3600 * 1000;
// Reading a copy: the source may take this long before its first byte (an application that encodes a large image only when
// asked, B-13); then the answers' limits (kWriterIdleMs without progress, kWriterMaxMs in all).
constexpr qint64 kReadFirstByteMs = 10 * 1000;
// A copy whose source clears the clipboard within this long may have been a password (B-10): the shell is told (K line).
constexpr qint64 kClearedSoonMs = 60 * 1000;

// The type the helper adds to what it serves, holding the item id: its own selection is known by it.
extern const char kMarkerType[];

enum class Kind { None, Text, Image, Files };
// Why an offer is not read. Secret: a password-manager or nspasteboard.org hint (the data is never requested).
enum class Refusal { None, TooManyTypes, Secret, Unsupported };

QByteArray kindName(Kind kind);
Kind kindFromName(const QByteArray &name);

// What to read from an offer, decided from its types alone.
struct Plan {
    Kind kind = Kind::None;
    Refusal refusal = Refusal::Unsupported;
    bool hasMarker = false;
    QByteArray plainType; // text: the plain type to read ("" when the plain text is made from the HTML); files: a fallback
    QByteArray htmlType;
    QByteArray rtfType;
    QByteArray imageType;
    QByteArray filesType;
    // The types to request, in order.
    QList<QByteArray> reads() const;
    // The most bytes a read of `type` may bring (more: see ReadResult::OverCap).
    qint64 cap(const QByteArray &type) const;
};

// `types`: the offer's types as the compositor sent them (the caller stops collecting past kMaxTypes and sets `tooMany`).
Plan plan(const QList<QByteArray> &types, bool tooMany);
// A MIME type as compared here: lower case, no spaces ("text/plain; charset=UTF-8" -> "text/plain;charset=utf-8").
QByteArray normalizeType(const QByteArray &type);

struct Part {
    QByteArray mime;
    QByteArray data;
};

struct Item {
    QByteArray id;
    Kind kind = Kind::None;
    // What is served back besides the plain types: the formatted parts of a text, the image, the file list.
    QList<Part> parts;
    // Text: the plain text. Files: the local paths, one per line.
    QString plain;
    QStringList files;
    QString title;
    QString excerpt;
    QByteArray hash;
    qint64 copiedAtMs = 0;
    qint64 bootAtMs = 0;
    QByteArray bootId;
    qint64 pinnedAtMs = 0; // 0: not pinned
    QString app;
    QByteArray imageFormat; // png, jpeg or webp for an image
    // searchKey() of the plain text and the title, made once when the item enters the store (a search never normalizes 25 MB).
    QString searchText;

    qint64 size() const;
    // The bytes it holds in memory, for the stores' caps (size() is what the shell is told).
    qint64 memory() const;
    bool formatted() const;
    bool pinned() const { return pinnedAtMs > 0; }
};

// The result of reading one type.
struct ReadResult {
    enum Status { Ok, OverCap, Failed } status = Failed;
    QByteArray data;
};

// Builds the item from what was read (`results` by type), or explains why there is none (`error`, never content). The id,
// times and app are the caller's.
struct Built {
    bool ok = false;
    QByteArray error;
    Item item;
};
Built build(const Plan &plan, const QHash<QByteArray, ReadResult> &results);

// Text helpers (exposed for tests).
bool decodePlain(const QByteArray &type, const QByteArray &data, QString *out);
QString stripHtml(const QByteArray &html, bool *ok);
bool parseUriList(const QByteArray &data, QStringList *paths);
QString titleOf(const QString &text);
QString excerptOf(const QString &text);
QString searchKey(const QString &text);
void indexItem(Item &item);
QByteArray hashOf(Kind kind, const QByteArray &data);

// What a plain type is served as (UTF-8, or Latin-1 for STRING and TEXT).
QList<QByteArray> plainTypes();
QByteArray servePlain(const QString &text, const QByteArray &type);
// `x-special/gnome-copied-files` for local paths ("copy", never "cut").
QByteArray gnomeCopiedFiles(const QStringList &paths);
QByteArray uriList(const QStringList &paths);

// Age of an item: the larger of the wall-clock and boot-clock differences on the same boot, the wall-clock one otherwise.
// Negative (dated in the future) counts as expired.
qint64 ageMs(const Item &item, qint64 nowWallMs, qint64 nowBootMs, const QByteArray &bootId);
qint64 clampRetention(qint64 ms);
// How long a paste answer that has run `elapsedMs` may wait for its next progress: the idle limit, never past the overall
// limit; 0 means close it now.
qint64 writerWaitMs(qint64 elapsedMs);
// How long a read of a copy may wait for its next bytes: kReadFirstByteMs before the first one (`started` false), then as an
// answer; never past kWriterMaxMs in all; 0 means give up now.
qint64 readWaitMs(qint64 elapsedMs, bool started);

// The clears asked in the settings (search.clipboard.clearedAt and .pinnedClearedAt, ms; 0 never) against the ones this helper
// last carried out, which it keeps beside its stores (ADR-0034 §6): Settings writes the keys whether a helper runs or not, so a
// clear written while none ran is carried out at the next start, before anything is loaded, shown or recorded.
enum class ClearAction { Keep, DeleteAll, DropOlder };
// asked: the setting (-1 not given, 0 never cleared, left as recorded); applied: the record's value; recordKnown: a record was
// read. Another value than the one carried out deletes the whole store (also after a clock set back: never fewer deletions);
// with no record (a store from before it existed, or a record that broke a rule) only the items from before the clear go.
ClearAction clearAction(qint64 asked, qint64 applied, bool recordKnown);
// The items a clear at `clearedAtMs` leaves when it is carried out without a record: those whose time (the pin's for the pinned
// store, the copy's for the history) is after it.
QList<Item> keptAfterClear(const QList<Item> &items, qint64 clearedAtMs, bool pinned);

// The history (unpinned, newest copy first) and the pinned items (newest pin first).
class Store
{
public:
    struct AddResult {
        QByteArray id;           // the item now holding this content
        bool added = false;      // false: an equal item was moved (unpinned: its formats replaced by the new copy's) or kept (pinned)
        QList<QByteArray> evicted;
    };
    AddResult add(Item item);
    enum class PinResult { Pinned, AlreadyPinned, Full, NotFound };
    PinResult pin(const QByteArray &id, qint64 nowMs);
    // Back to the history at its copy time; returns the ids the history limits then pushed out (maybe the item itself).
    QList<QByteArray> unpin(const QByteArray &id, bool *found);
    bool remove(const QByteArray &id);
    QList<QByteArray> clearHistory();
    QList<QByteArray> clearPinned();
    QList<QByteArray> expire(qint64 nowWallMs, qint64 nowBootMs, const QByteArray &bootId, qint64 retentionMs);
    // Moves an unpinned item to the top with new times (its own copy came back); false when unknown or pinned.
    bool touch(const QByteArray &id, qint64 copiedAtMs, qint64 bootAtMs, const QByteArray &bootId);
    // Pinned first, then the history; every item when the query is blank.
    QList<QByteArray> search(const QString &query) const;
    const Item *find(const QByteArray &id) const;
    QList<const Item *> ordered() const;
    const QList<Item> &history() const { return m_history; }
    const QList<Item> &pinnedItems() const { return m_pinned; }
    qint64 historyBytes() const;
    qint64 pinnedBytes() const;
    // Loading a store from disk: items are taken as they are, limits applied after.
    QList<QByteArray> loadPinned(QList<Item> items);
    QList<QByteArray> loadHistory(QList<Item> items);

private:
    QList<QByteArray> enforceHistoryLimits();
    void insertHistory(Item item);
    QList<Item> m_history;
    QList<Item> m_pinned;
};

// Line protocol: fields separated by US (0x1f); backslash, line break, return and US escaped as \\, \n, \r and \u.
QByteArray escape(const QByteArray &utf8);
QByteArray escape(const QString &text);
QByteArray unescape(const QByteArray &field);
QList<QByteArray> splitLine(const QByteArray &line);
} // namespace ClipLogic
