#pragma once

#include <QByteArray>
#include <QSize>
#include <QString>
#include <QStringList>

// Pure logic of the Screenshot app (ADR-0066 D-3; docs/specs/capture-suite.md §3.3): argument validation and the caps on the
// picture it opens. Everything the editor opens is untrusted input: only a local regular PNG file, within bounded sizes.
// The rules of the local path are Preview's (apps/preview/src/previewlogic.cpp), kept in step by tests/unit/screenshot.
namespace screenshot {

constexpr int kMaxImageSide = 16384;     // px per side
constexpr int kAllocationLimitMb = 256;  // QImageReader allocation limit (every decoder of the process)
constexpr qint64 kMaxImageBytes = qint64(kAllocationLimitMb) * 1024 * 1024; // a PNG file larger than the decoded limit is refused

// Local path for a command line argument (a path or a file: URL), empty with `error` set when the argument is rejected
// (other schemes, remote file hosts, a query or fragment, empty). A relative path is taken against `cwd`.
QString localPathFromArgument(const QString &arg, const QString &cwd, QString *error = nullptr);

// Canonical (symlink-resolved) path under /proc, /sys or /dev: never opened.
bool isSystemPath(const QString &canonical);

// An image of this size (4 bytes per pixel) fits the per-side and allocation caps.
bool imageSizeAllowed(const QSize &size);

// Dimensions from the first bytes of a PNG file (IHDR), invalid when the bytes are not a PNG start. The editor refuses a
// picture by this header before any decoder runs.
QSize pngSize(const QByteArray &head);

// Command line: the one file to edit (canonical path, so that Done replaces the file itself and never a link to it), or an
// error message per rejected argument. Exactly one regular, readable PNG file is accepted.
struct Arguments {
    QString path;
    QStringList errors;
};
Arguments resolveArguments(const QStringList &args, const QString &cwd);

} // namespace screenshot
