#pragma once

#include <QByteArray>
#include <QString>

#include <functional>

// Replaces a file in one step (ADR-0066 D-5: "Done replaces the file atomically (hidden file, then rename)"). The bytes go to a
// hidden file next to the target (".<name>.XXXXXX", mode 0600, created exclusively), are synced, take the target's mode, and
// replace the target with rename(2). Whatever fails, the target keeps its old bytes whole and the hidden file is removed: a
// reader sees the old file or the new one, never a part of either.
namespace screenshot {

// Called once the hidden file is complete and before the rename; false aborts the replacement (a test's forced failure, and
// the seam where a future caller can refuse a replacement after seeing the finished file). Receives the hidden file's path.
using BeforeRename = std::function<bool(const QString &hiddenPath)>;

// `mode`: the permission bits of the new file, or -1 to keep the target's (0600 when there is no target yet).
// False with `error` set when anything failed.
bool atomicWrite(const QString &path, const QByteArray &bytes, int mode = -1, QString *error = nullptr, const BeforeRename &beforeRename = {});

} // namespace screenshot

namespace screenshot {

// Reads a file of the history (D-9): opened with O_NOFOLLOW, then checked on the descriptor: a regular file, owned by the
// user, with no permission bit for group or others, at most `maxBytes`. False (and `out` empty) otherwise.
bool readPrivateFile(const QString &path, qint64 maxBytes, QByteArray *out);

} // namespace screenshot
