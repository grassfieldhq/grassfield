#pragma once

#include <QByteArray>
#include <QSize>
#include <QString>
#include <QStringList>

#include <atomic>
#include <functional>

class QTextDocument;

// Pure logic of Grassfield Preview (no GUI): argument validation, file-type routing and size caps.
// Everything the viewer opens is untrusted: only local regular files, bounded sizes.
namespace preview {

enum class Kind { Image, Pdf, Text, Audio, Video, Unsupported };

// Caps (docs/specs/preview.md).
constexpr int kMaxImageSide = 16384;               // px per side
constexpr int kAllocationLimitMb = 256;            // QImageReader allocation limit
constexpr qint64 kMaxImageBytes = qint64(kAllocationLimitMb) * 1024 * 1024;
constexpr qint64 kMaxTextBytes = 2 * 1024 * 1024; // plain text / code
constexpr qint64 kMaxVectorBytes = 8 * 1024 * 1024; // an SVG (svgz) file: its size is known only by parsing it whole (P4)
constexpr int kTextChunkChars = 64 * 1024;         // a longer text is shown in pieces of whole lines of about this many characters (P7)
constexpr int kMaxFiles = 200;                     // files accepted on one command line

// Local path for a command line argument (a path or a file: URL), empty with `error` set when the
// argument is rejected (other schemes, remote file hosts, empty). Relative paths use `cwd`.
QString localPathFromArgument(const QString &arg, const QString &cwd, QString *error = nullptr);

// Routing by MIME type: images, PDF, text and code, audio, video.
Kind classify(const QString &path);

// Markdown (the owner's report on 1.0.0-rc9: a .md file showed its source): a file whose type is text/markdown (or a type
// inheriting it) is shown rendered, as Quick Look does, up to kMaxMarkdownChars characters (a longer one shows its source in
// pieces, P5). Decided by the type Preview already detects (the .md, .markdown, .mkd suffixes of shared-mime-info).
constexpr int kMaxMarkdownChars = 512 * 1024;
constexpr int kMaxMarkdownImages = 64; // pictures of one document shown; the rest show their alternative text
bool isMarkdown(const QString &path);
// A picture a Markdown document names, resolved for display: `target` as written in the document (a relative path against
// `baseDir`, an absolute path or a file: URL; percent-encoding decoded). Only a local, readable regular file (symlinks
// followed) that Preview shows as an image, outside /proc, /sys and /dev, within the image caps (a vector picture within
// kMaxVectorBytes) gives its canonical path and its displayed size; anything else (http, data:, a missing file, a FIFO, a
// text file, a picture too large) gives "": the document never makes Preview fetch anything or open a device.
QString markdownImagePath(const QString &target, const QString &baseDir, QSize *size = nullptr);
// A picture of a document is served at most this many pixels per side (shrunk with its aspect ratio, never enlarged): the
// decode follows the size it is shown at, not the file's (review 2026-11-22: a 16384 x 4096 PNG decoded whole per picture).
constexpr int kMarkdownImageMaxSide = 2048;
// The pixels (4 bytes each, at the served size) all the pictures of one document may take; a picture past it shows its
// alternative text (64 highly compressible 16384 x 4096 PNGs would otherwise have been 16 GiB).
constexpr qint64 kMarkdownImageBudgetBytes = 256LL * 1024 * 1024;
// The size a picture of `natural` size is served at (kMarkdownImageMaxSide box, aspect ratio kept, at least 1 x 1).
QSize markdownServedSize(const QSize &natural);
// The HTML of a rendered Markdown document for a read-only rich text view: Qt's own reader (QTextDocument::setMarkdown, the
// GitHub dialect: tables, task lists, strikethrough, autolinks) with raw HTML off, so the document's own tags stay text.
// Every picture goes through `image(target, &size)`, which answers an id of the picture for Preview's image provider (its
// file token) and its natural size, or "" to show its alternative text instead; at most kMaxMarkdownImages are asked and
// at most kMarkdownImageBudgetBytes of served pixels are shown. A shown picture points at
// `image://preview/fit/<w>x<h>/<id>` with its served size (the provider decodes it at that size). Links keep their target
// (the view decides what a click does) and take the view's link colour (no colour of their own). The body carries no font,
// so the view's font (family, size, zoom) applies.
using MarkdownImageResolver = std::function<QString(const QString &target, QSize *size)>;
QString markdownHtml(const QString &markdown, const MarkdownImageResolver &image);
// Fits the pictures of a rendered document (those served by `image://preview/fit/<w>x<h>/...`) to `maxWidth`: each one is
// laid out at its served size or narrower, aspect ratio kept. Only the picture formats change (no new parse of the text,
// so the view keeps its selection and its scroll). Returns how many pictures changed size.
int fitMarkdownImages(QTextDocument *document, qreal maxWidth);

// The first lines of a text file for a sidebar thumbnail: at most 12 lines of 40 characters, control characters and tabs
// replaced by spaces; "" for an empty or unreadable file. Only a regular file is read (a FIFO or a device would block or
// never end: it is opened without blocking and checked with fstat on the descriptor, so a swap after the check does not
// matter), and one larger than `maxSize` bytes gives "" (a thumbnail of a huge log is not worth the disk).
QString textSnippetOf(const QString &path, qint64 maxSize = 16 * 1024 * 1024);
QString kindName(Kind kind);

// A vector picture (.svg, .svgz) larger than kMaxVectorBytes: refused before any parse (its size alone needs the whole
// document parsed).
bool vectorTooLarge(const QString &path, qint64 bytes);
// `text` in pieces of whole lines of about `chars` characters each (a piece holds at least one line, however long); the
// pieces joined give the text back.
QStringList textChunks(const QString &text, int chars);
// Whether the computer runs on its battery: under `powerSupplyRoot` (/sys/class/power_supply) a system battery is there
// and no power adapter (type Mains, USB or USB_C) is online. False when nothing can be read.
bool onBatteryIn(const QString &powerSupplyRoot);

// An image of this size (4 bytes per pixel) fits the per-side and allocation caps.
bool imageSizeAllowed(const QSize &size);
// Dimensions from the first bytes of a PNG file (IHDR), invalid when it is not a PNG. Used to say
// "too large" for images the decoder refuses before reporting their size.
QSize pngSize(const QByteArray &head);
// "File too large" check for text.
bool textSizeAllowed(qint64 bytes);
// NUL bytes in the sample: not text.
bool looksBinary(const QByteArray &sample);

// Canonical (symlink-resolved) path under /proc, /sys or /dev: never previewed.
bool isSystemPath(const QString &canonical);

// Select Text in Images (ADR-0045 OC-2, docs/specs/preview.md P13). One recognition runs one allowlisted tool, found on the
// PATH at use time, with fixed arguments, never through a shell; the image reaches it on its standard input as a grey PGM
// that Preview decoded itself (EXIF orientation applied, at most kRecognitionMaxSide per side), never as a path: the tool
// never parses the file, and the boxes it answers are in the pixels Preview shows.
constexpr int kRecognitionMaxSide = 4096;                 // px per side of the picture handed to the tools (P5: 8192 kept
                                                          // tesseract on a 64 MP page for seconds; 4096 still reads body text)
constexpr int kRecognitionTimeoutMs = 60000;              // a tool still running then is killed
constexpr qint64 kRecognitionOutputMax = 4 * 1024 * 1024; // bytes of standard output; more is a failure
struct Recognition {
    QString program;       // empty: the request is refused
    QStringList arguments;
    bool image = false;    // the tool reads the image on its standard input
};
// "languages": `tesseract --list-langs`. "text": tesseract's TSV word boxes (Omarchy's omarchy-capture-text options --oem 1
// and --dpi 300, a whole page's segmentation --psm 3) in `languages`, tesseract's -l value: one to four language names
// ([A-Za-z0-9_], at most 32 characters each) joined by '+'. "qr": zbarimg with QR codes only (omarchy-capture-qr's -q
// -Sdisable -Sqrcode.enable: the other symbologies false-positive on screen content), each code as "QR-Code:<data>".
// Anything else is refused.
Recognition recognitionCommand(const QString &tool, const QString &languages);
// A link a QR code chip may hand to xdg-open: one http or https URL (valid in strict mode, with a host, without user
// information, at most 2048 characters, no space, control or format character, not starting with '-'). The same rule as
// the chip's (apps/preview/qml/TextInImages.js isLink).
bool isOpenableLink(const QString &link);

// Command line: accepted local paths (at most kMaxFiles, regular files only, duplicates removed) and
// one message per rejected argument.
struct Arguments {
    QStringList paths;
    QStringList errors;
};
Arguments resolveArguments(const QStringList &args, const QString &cwd);

// The other files of the folder of `path`, in the order Grassfield Files shows them (same comparison: numeric,
// case-insensitive names; the Files view settings decide key and direction). Only regular, readable, visible files
// of the wanted kind (by file name: images only, or every kind Preview can show). `path` itself is always in the list
// at its sorted position, hidden or unreadable or not (the macOS model: the opened file is shown, an unreadable one with
// an error); unreadable siblings are skipped. At most kMaxFiles entries (a window around `path`). Read only. Meant for
// a worker thread: `cancel` (when set to true) stops the listing early and gives just `path`.
struct SortSpec {
    int key = 0; // 0 name, 1 kind, 2 date, 3 size (FileLogic::SortKey)
    bool descending = false;
    bool foldersFirst = true; // folders are not listed: kept for the shared comparison
};
struct Browse {
    QStringList paths;
    int index = 0; // position of the opened file in `paths`
};
enum class BrowseKinds { ImagesOnly, Previewable };
Browse browseFolder(const QString &path, BrowseKinds kinds, const SortSpec &sort, const std::atomic_bool *cancel = nullptr);
// View sort settings of Grassfield Files (QSettings Grassfield/Files, read only; defaults when absent).
SortSpec filesSortSpec();

} // namespace preview
