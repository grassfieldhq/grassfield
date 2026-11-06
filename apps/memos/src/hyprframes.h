// Where the memo windows are (ADR-0051 D-6). A Wayland client cannot read or set its own window's position, so Memos asks
// Hyprland's request socket for its window list (`j/clients`: read only, never a dispatch) and keeps the frames of its own
// windows, found by pid and by their xdg-toplevel tag, `memo:<id>[@<x>,<y>]`. The tag carries the position the memo
// had, which config/hypr/grassfield/placement.lua applies when the window opens.
// Plain Qt Core and POSIX: the unit tests link it (tests/unit/memos/tst_hyprframes.cpp).
#pragma once

#include <QByteArray>
#include <QHash>
#include <QString>

namespace memos {

struct Frame
{
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
};

// The tag of a memo window: `memo:<id>`, then `@<x>,<y>` when its position is known.
QString memoTag(const QString &id, bool hasPosition, int x, int y);
// The memo id of a tag (`memo:<32 hex>` and an optional tail), "" for any other tag.
QString memoIdOfTag(const QString &tag);

// The frames of the memo windows of process `pid` in Hyprland's `j/clients` answer, by memo id. Anything malformed is
// skipped; an answer that is not a JSON array gives none.
QHash<QString, Frame> parseClientFrames(const QByteArray &json, qint64 pid);

// The request socket of the Hyprland instance this process runs in ("" when there is none: no HYPRLAND_INSTANCE_SIGNATURE,
// or one that is not a plain name).
QString hyprlandSocketPath(const QString &runtimeDir, const QString &signature);
QString hyprlandSocketPath();

// Sends `request` and returns the whole answer ("" on any error or after `timeoutMs` per read). At most 4 MiB.
QByteArray hyprlandRequest(const QString &socketPath, const QByteArray &request, int timeoutMs = 300);

// This process's memo windows as Hyprland sees them now (empty without Hyprland).
QHash<QString, Frame> currentFrames();

} // namespace memos
