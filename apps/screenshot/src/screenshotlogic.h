#pragma once

#include <QByteArray>
#include <QSize>
#include <QString>
#include <QStringList>

#include <functional>

// Pure logic of the Screenshot app (ADR-0066 D-3; docs/specs/capture-suite.md §3.3): argument validation and the caps on the
// picture it opens. Everything the editor opens is untrusted input: only a local regular PNG file, within bounded sizes.
// The rules of the local path are Preview's (apps/preview/src/previewlogic.cpp); tests/unit/screenshot/tst_pathparity.cpp runs both
// functions over the same cases, so a change to one without the other fails.
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

// The clipboard after a redacted export (ADR-0066 D-9): the arguments of the command that puts the exported PNG (on its stdin) on the clipboard,
// the automatic copy's own (type image/png, --sensitive: clipboard history does not record it), and the one that empties it when that fails.
QStringList clipboardArguments();
QStringList clipboardClearArguments();

// Started with no file (the Apps entry): macOS's Screenshot app opens the capture toolbar, so this one asks the running shell to.
// `shellIpc` is grassfield::apps::runmode::shellIpcArgs() (the arguments after `qs`: ipc -p <dir> call), empty when there is no
// shell to call. The target is "capture" and the function "toggle", the one the Shift-Super-5 key calls: "open" answers only in a
// fixture session (shell/capture/Capture.qml), so a click on the entry would do nothing. Returns the arguments of `qs`, or an
// empty list when there is no shell.
QStringList openToolbarArguments(const QStringList &shellIpc);

// Runs the call through `run` (the arguments after `qs`; true when it succeeded within its bound): 0 when it did, 2 with `error` set
// when there is no shell to call or the call failed (nothing opened). `run` is a seam: main.cpp starts a bounded `qs`, the tests a fake.
int openToolbar(const QStringList &shellIpc, const std::function<bool(const QStringList &)> &run, QString *error);

} // namespace screenshot
