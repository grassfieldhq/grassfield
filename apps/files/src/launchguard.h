#pragma once

#include <QByteArray>
#include <QString>
#include <QStringList>
#include <QUrl>

#include <functional>

// What opening an item from Grassfield Files may do (GF-AUDIT-001 GF-070, SEC-12, DT-10; amended 2026-11-08 by the owner's
// report "impossible de lancer une AppImage", ADR-0011 amendment "Files opens apps the Gatekeeper way"). macOS model
// (Gatekeeper): opening a program runs it, and a program that came from the Internet runs only after the user said Open in a
// sheet that names where it came from; a script opens in the text editor (Open With > Terminal runs it); a Windows or Java
// program, a disk image of another system's app and an app launcher are never run by opening. Files decides by content (the
// ELF header, a "#!" line, the MIME type) and by the execute bit, never by the name alone, before KIO sees the item, and never
// hands KIO a desktop entry (KIO runs a Link's downloaded target with the handler the server's type selects, or
// X-KDE-LastOpenedWith). Qt Core and POSIX only: unit-tested in tests/unit/files/tst_launchguard.cpp.
namespace LaunchGuard
{

enum class Verdict {
    Open,                 // hand it to KIO (folders, documents, scripts without the permission bit, remote documents)
    OpenWebLinkInBrowser, // a desktop entry that is only a web link: its http(s) address goes to the default web browser
    RefuseLauncher,       // any other desktop entry (Type=Application, Service, Link to a file, unknown, ambiguous)
    RunProgram,           // a native program or an AppImage made for this computer: run it, after a sheet when plan() asks
    OpenScript,           // an executable script: it opens in the default text editor (Open With > Terminal runs it)
    WindowsFile,          // a Windows program, script or registry file: explained, never run; its own handler after a sheet
    JavaProgram,          // a Java archive or Web Start file: explained, never run; java after a sheet
    ForeignApp,           // a disk image or installer of another system's app (.dmg, .pkg): explained, Search the Store
    RefuseIncompatible,   // a program for another kind of computer (ELF class, byte order or machine)
    RefuseDisguised,      // program content under a document's name ("photo.jpg" that is a program): never run
    RefuseNotAnApp,       // a name that says app (x.AppImage) on content that is not a program
    RefuseRemoteProgram,  // a program, Windows or Java file on a server or in the Trash: never run from there
    RefuseElevated,       // a program that would run with other rights (setuid, setgid, file capabilities), or Files as root
};

// What inspect() learned about an item. For a symbolic link, the facts are its final target's (the target's trust, its
// permission bits, its folder), except fileName, which stays the name the user sees.
struct Facts {
    bool local = false;        // a file: URL
    bool regularFile = false;  // a regular file (symlinks followed)
    bool executable = false;   // the user may execute it (symlinks followed)
    bool symlink = false;      // the item itself is a symbolic link
    QString fileName;          // the item's own name (a link's name, not its target's)
    QString path;              // the file decided on: the item, or its link's final target (absolute, canonical)
    QString mimeType;          // QMimeDatabase::mimeTypeForFile (name, then content): the kind Files shows for it
    QStringList mimeAncestors; // every ancestor of mimeType
    bool shebang = false;      // starts with "#!"
    bool elf = false;          // starts with the ELF magic
    // ELF header (elf only)
    bool elfProgram = false;    // ET_EXEC, or ET_DYN with an interpreter or DF_1_PIE (a shared library is not a program)
    bool elfCompatible = false; // class, byte order and machine this computer runs
    QString elfInterpreter;     // PT_INTERP ("" when static)
    bool appImage = false;      // the AppImage magic ("AI" and 1 or 2 at offset 8 of the ELF header)
    bool elevated = false;      // setuid or setgid bit, a security.capability attribute, or Files itself runs as root
    // Where it came from (Facts of local regular files only)
    QString originUrl;   // user.xdg.origin.url (Chromium, Firefox: the address it was downloaded from)
    QString referrerUrl; // user.xdg.referrer.url (the page that linked it)
    bool approved = false; // user.grassfield.approved names this file as it is now (approvalValue())
    // The file's identity, for approvals and for the check after a sheet (inode, modification time in ns, size)
    quint64 inode = 0;
    qint64 mtimeNs = 0;
    qint64 size = 0;
    // Where it is
    bool ownedByUser = false; // st_uid is the user's
    bool noexecMount = false; // its file system is mounted noexec
    bool readOnlyMount = false;
    // Desktop entries
    bool desktopEntry = false; // named *.desktop / *.kdelnk / .directory, or of type application/x-desktop
    QString desktopType;       // [Desktop Entry] Type= ("" when absent or unreadable)
    QString desktopUrl;        // [Desktop Entry] URL= (Type=Link)
    bool desktopAmbiguous = false; // a key given twice, URL with URL[$e], or longer than what was read
};

struct DesktopKeys {
    QString type;
    QString url;
    bool ambiguous = false; // Type or URL given more than once (KConfig keeps the last one): refuse
};

// What running a RunProgram item needs before it starts (pure, on the facts).
struct RunPlan {
    bool downloaded = false; // it carries a browser's download mark (origin or referrer)
    bool ask = false;        // a sheet first: downloaded and not approved, or the execute bit or a copy is needed
    bool allowRun = false;   // the user's execute bit is set on Open (chmod u+x), the file stays where it is
    bool copy = false;       // it cannot run from where it is (noexec, or not executable on a read-only disk or another
                             // user's file): Open copies it to ~/Applications and runs the copy
};

// The ELF header facts of a file (parseElf).
struct ElfHeader {
    bool valid = false;
    int elfClass = 0;  // 1: 32-bit, 2: 64-bit
    int byteOrder = 0; // 1: little endian, 2: big endian
    int type = 0;      // e_type
    int machine = 0;   // e_machine
    bool interpreter = false;
    QString interpreterPath;
    bool pie = false; // DF_1_PIE in DT_FLAGS_1
    bool appImage = false;
    bool program() const;
};

// Pure decision on the facts. Fail closed: a desktop entry that cannot be read, has no Type or is ambiguous is refused.
Verdict verdict(const Facts &facts);
RunPlan plan(const Facts &facts);

// The address of a desktop entry that is only a web link (Type=Link, one http(s) URL with a host), else an invalid URL.
QUrl webLink(const Facts &facts);

// The host a downloaded file came from (the origin's, else the referrer's), "" when unknown. Only a host: no path, query or
// user name ever reaches the sheet or the journal.
QString originHost(const Facts &facts);

// The value of user.grassfield.approved for a file of this identity ("1 <inode> <mtime ns> <size>").
QByteArray approvalValue(quint64 inode, qint64 mtimeNs, qint64 size);

// The words to search the Store for, for another system's app ("Slack-4.36.140-macOS.dmg" -> "Slack").
QString storeSearchTerm(const QString &fileName);

// One line for the journal: control characters replaced, at most 120 characters.
QString logName(const QString &name);

// The ELF header of a file: `readAt(offset, length)` returns the bytes there (fewer at the end of the file). Bounded: at most
// 256 program headers and 64 KiB of the dynamic section are read.
ElfHeader parseElf(const std::function<QByteArray(qint64 offset, qint64 length)> &readAt);

// This computer's ELF class, byte order and machine (read once from /proc/self/exe), and whether a header runs here (a 32-bit
// x86 program runs on x86-64).
bool runsHere(const ElfHeader &header);

// Reads what verdict() needs (bounded: the first 64 KiB of a desktop entry, the ELF header and program headers, three
// extended attributes of 4 KiB at most, one statvfs).
Facts inspect(const QUrl &url);

// The Type and URL keys of the [Desktop Entry] group (KDE's legacy [KDE Desktop Entry] too); other groups are ignored.
DesktopKeys parseDesktopEntry(const QByteArray &text);

} // namespace LaunchGuard
