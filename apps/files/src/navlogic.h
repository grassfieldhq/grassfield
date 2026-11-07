#pragma once

#include <QList>
#include <QString>
#include <QStringList>
#include <QUrl>

// The Go menu's logic (docs/specs/files.md FP-75..FP-77), free of Qt Quick and KIO so the unit tests run it: Go to
// Folder's completion, Connect to Server's addresses, and the recent lists both keep.
namespace NavLogic
{

// Go to Folder completion (FP-76): what `text` (as typed: "~/Doc", "/usr/sh", "Projects/a", "~/") asks to list.
struct CompletionTarget {
    // The local folder to list (absolute, cleaned); empty when the text names no local folder (a URL, "").
    QString folder;
    // The start of the folder name being typed ("" after a '/').
    QString prefix;
    // The text up to and including its last '/' (kept as typed when a match completes it: "~/D" -> "~/Downloads/").
    QString typedFolder;
};
// `base`: the shown local folder (relative text starts there; "" when it is no local folder), `home`: the home folder.
CompletionTarget completionTarget(const QString &text, const QString &base, const QString &home);

// The names of `names` (the folders of CompletionTarget::folder) that begin with `prefix` without regard to case,
// sorted without regard to case, at most `max`. Hidden names (a leading '.') only when the prefix starts with '.' or
// `showHidden`.
QStringList folderMatches(QStringList names, const QString &prefix, bool showHidden, int max);

// The text once a match completes it: its folder part, the match, a '/' ("~/D" and "Downloads" -> "~/Downloads/").
QString completedText(const CompletionTarget &target, const QString &match);

// Connect to Server (FP-77): the URL of an address as typed. A bare host or "host/share" is SMB (the Finder's
// default); smb, sftp, fish, ftp, ftps, webdav, webdavs and nfs are taken as they are; "http(s)://" is WebDAV (KIO's
// webdav(s)). Anything else (file:, trash:, a URL without a host, spaces in the host) gives an invalid URL. A password
// typed in the address is dropped: Files never keeps one (decision F-9: kiod's password server asks for it).
QUrl serverUrl(const QString &text);

// `item` first in `list` (an equal entry moved there), at most `max` entries.
QStringList pushRecent(QStringList list, const QString &item, int max);

// The Go menu's own shortcuts for the places it lists (Finder): "" for the others. `kind` is the PlacesModel kind,
// `path` a local folder's path, `xdg` the user's Desktop, Documents and Downloads folders in that order.
QString placeShortcut(const QString &kind, const QString &path, const QString &home, const QStringList &xdg);

// Go to Folder on a location already resolved (FilesApp::locationUrl): a folder opens; a file (or a link that leads
// nowhere) opens its folder with the item selected, as the Finder does; anything missing gives an empty folder. A remote
// URL is left to KIO as it is (it is listed, never looked at here).
struct GoToTarget {
    QUrl folder;
    QUrl select;
};
GoToTarget goToTarget(const QUrl &location);

// Sidebar Favorites editing (FP-27; owner report 2026-11-07: "there is no way to pin a folder in the sidebar"). The user's
// own folders are a list of URLs in display order (QSettings sidebar/favorites), after the standard places; the standard
// places the user removed are a list of their URLs (sidebar/hidden).
constexpr int kMaxSidebarFavorites = 64;
// The URL as the sidebar keeps it: no trailing slash, normalized path segments.
QUrl sidebarUrl(const QUrl &url);
// A location that can be a Favorites folder: a valid absolute URL of a folder location, never one of Files' own lists
// (a search, a tag search, Recents, Applications) nor a Locations place (the Trash, Network).
bool sidebarCandidate(const QUrl &url);
// The stored list read back: cleaned, candidates only, no repeat, at most kMaxSidebarFavorites.
QList<QUrl> sidebarList(const QStringList &stored);
QStringList sidebarStored(const QList<QUrl> &list);
// `added` put at `position` (0..list size; anything else: the end), in their order, those already listed left where they
// are; at most kMaxSidebarFavorites (the last ones added beyond are not kept).
QList<QUrl> withSidebarFolders(QList<QUrl> list, const QList<QUrl> &added, int position);
// `url` moved to the gap `position` of the list as it is shown (0: before the first, size: after the last).
QList<QUrl> movedInSidebar(QList<QUrl> list, const QUrl &url, int position);

} // namespace NavLogic
