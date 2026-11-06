#pragma once

#include <QByteArray>
#include <QList>
#include <QString>
#include <QStringList>

// Dev guard of the system sections (Wi-Fi, Bluetooth, Sound, Displays). In a dev session (GRASSFIELD_DEV=1, a nested
// Hyprland on the owner's machine) nothing may change the owner's network, Bluetooth, audio or monitors: only the
// read-only queries below may run. Kept free of QML and QObject so the rule is easy to read and to test.
namespace grassfield::settings {

// The run-mode rule (apps/runmode.h, the same as shell/lib/RunMode.js): GRASSFIELD_DEV "1" and GRASSFIELD_SESSION not "1".
bool devSession();

// Exactly the read-only commands the pages issue (qml/System.js builds the same argument vectors; tst_settingssystem
// checks that every System.QUERY entry is accepted here). Anything else, also a variation of these, is not a query:
//   wpctl      2 fixed (status, status -n), the Sound page; Wi-Fi and Bluetooth are read over D-Bus (systembus.h), not by commands
//   pacman -Q (hyprland, quickshell, quickshell-git) and lspci      => 4 more, About pane
//   pacman -Qi (the installed packages' sizes) and du -s -x --block-size=1 -- <1-16 folders of the home>   Storage pane
//   /usr/lib/grassfield/grassfield-channel-set (no argument: it prints the channel)            Software Update pane
//   omarchy-hw-fingerprint, omarchy-hibernation-available (no argument): Omarchy's read-only checks (ADR-0045 OC-6, OC-9)
//   lsblk -J -o NAME,TYPE,FSTYPE,MOUNTPOINTS                                                    Privacy & Security > Disk Encryption
// Never omarchy-language (Language & Region runs it only in a real session where it is installed: ADR-0030), never
// timeout -k 2 12 omarchy-brightness-display-ddc <connector> (Displays reads an external display's level only in a real session: a dev session
// never asks the owner's displays; it writes Omarchy's cache under $XDG_RUNTIME_DIR and probes the i2c buses, ADR-0045 OC-4),
// never omarchy-network-qr (isPrivateQuery). Backend::query and Backend::run both use it.
bool isReadOnlyQuery(const QStringList &argv);

// A query that writes nothing but answers with a secret, run only in a real session (Backend::readOnlyQuery, never in a dev
// session, never by run()): exactly `omarchy-network-qr --meta`, Wi-Fi > Details > Share Network… (ADR-0045 OC-10), whose matrix
// encodes the Wi-Fi password. A dev session's Wi-Fi pane reads the owner's real NetworkManager, and its screenshots are
// committed as evidence: it never draws the owner's password (security review of ADR-0045, M-2).
bool isPrivateQuery(const QStringList &argv);

// The du arguments of the Storage pane: exactly -s -x --block-size=1 --, then 1 to 16 clean absolute paths inside the home.
bool isFolderSizeQuery(const QStringList &args);

// A language code of Omarchy's list ("fr", "pt-BR", "zh-CN").
bool isLanguageCode(const QString &code);

// The wallpaper helper (ADR-0016) as the Settings > Wallpaper page runs it. Only the helper at its exact path (installed
// /usr/lib/grassfield/grassfield-wallpaper, or the dev build next to the dev binary), only these argument vectors:
//   <tool> formats
//   <tool> list --max <1..500> -- <folder>
//   <tool> thumb --width <16..1024> --out <cacheDir>/thumbs -- <picture>
// `folder` and `picture` are absolute paths without control characters (at most 4096 bytes); in a dev session they must lie
// under <devRoot>/.dev. `--out` is exactly the thumbnail folder of the wallpaper cache: no other value, no traversal.
// `prepare` is never run by Settings (the shell does). Anything else, also another program called grassfield-wallpaper, is refused.
struct WallpaperContext {
    QString tool;     // the helper's absolute path
    QString cacheDir; // the wallpaper cache root (thumbnails go to <cacheDir>/thumbs)
    QString devRoot;  // the worktree in a dev session, "" otherwise
};
bool isWallpaperQuery(const QStringList &argv, const WallpaperContext &ctx);
// A program that names the helper (its file name), whatever its directory: such a command is judged by isWallpaperQuery only.
bool namesWallpaperTool(const QString &program);

// Programs the pages may run as actions in a real session (wpctl for Sound, xdg-open for links, omarchy-language for Language
// & Region, omarchy-powerprofiles-set for Battery, brightnessctl and timeout (around omarchy-brightness-display-ddc only) for Displays, lpoptions for
// Printers: the user's own CUPS defaults; /usr/lib/grassfield/grassfield-channel-set for Software Update; pw-play for Sound's alert previews). Anything else is refused: Wi-Fi, Bluetooth, the General pane's system
// changes and adding or removing a printer are D-Bus calls (Backend::busAct).
bool isActionProgram(const QString &program);

// Settings > Sound's alert preview (ADR-0047 B-4), exactly ui/Grassfield/Ui/SoundEffects.js previewArgv's form:
//   pw-play --media-role Notification --volume <0.000-1.000> [--target <PipeWire node name>] --
//       /usr/share/sounds/grassfield/stereo/grassfield-alert-<one of the six ids>.wav
bool isSoundPreview(const QStringList &argv);

// A backlight's name under /sys/class/backlight ("intel_backlight", "amdgpu_bl1"): 1 to 64 of [A-Za-z0-9_.:-], not starting with "-".
bool isBacklightName(const QString &name);

// A Hyprland output name as the kernel names a connector ("DP-1", "HDMI-A-1", "eDP-1", "DVI-D-2"): a letter, up to 23 letters and
// hyphens, then "-" and 1 to 4 digits. Never an option, a path or a space (shell/services/BrightnessLogic.js isConnector and
// qml/System.js validConnector take the same rule).
bool isConnectorName(const QString &name);

// Settings > Displays (ADR-0031): one line of displays.conf or of a display trial, the rule config/hypr/grassfield/displays.lua
// applies: v1 <TAB> desc:<1 to 160 bytes, no control character> <TAB> <W>x<H>@<Hz> (1-16384, 1-1000 Hz) <TAB> <X>x<Y>
// (-32768 to 32768) <TAB> <scale> (0.5 to 4) <TAB> <transform> (0 to 7).
bool isDisplayLine(const QString &line);
// A trial's id: 1 to 32 ASCII letters and digits.
bool isDisplayTrialId(const QString &id);

// Settings > Printers (ADR-0030): a CUPS queue name as Settings takes it, 1 to 127 of [A-Za-z0-9_.+@-], not starting with "-"
// (CUPS allows more; a queue named otherwise is shown but cannot be chosen); a PPD paper size keyword ("A4", "Letter",
// "Custom.WIDTHxHEIGHT" is not one), 1 to 40 of [A-Za-z0-9._-] starting with a letter or a digit; a URI cupsd turns into an
// IPP Everywhere queue (dnssd, ipp, ipps or ippusb), at most 1024 characters, without spaces or control characters.
bool isPrinterName(const QString &name);
bool isPaperKeyword(const QString &keyword);
bool isPrinterUri(const QString &uri);

// A whole action command line: an allowed program, for xdg-open exactly one clean https link (xdg-open hands anything else, a
// local file or a .desktop entry, to whatever handler claims it), for omarchy-language exactly one language code, for brightnessctl
// exactly `-q -d <backlight> set <0-100>%`, for timeout exactly `-k 2 12 omarchy-brightness-display-ddc <connector> <0-100>%`
// (Omarchy's DDC/CI command, an external display's brightness, ADR-0045 OC-4, which keeps the level within 1..100; coreutils'
// timeout ends its whole process group, ddcutil included, within 14 s: security review LOW 3), for wpctl exactly `set-default <id>`, `set-volume <id> <0.00-1.00>` or
// `set-mute <id> 0|1`, for lpoptions exactly `-d <queue>` or `-p <queue> -o PageSize=<keyword>` (the user's
// ~/.cups/lpoptions; Settings never runs as root, where CUPS would write /etc/cups/lpoptions), for grassfield-channel-set (the
// installed /usr/lib/grassfield/grassfield-channel-set, never one found on PATH) exactly one of `stable`, `beta`, `repair`,
// `off` (ADR-0033 c.3; docs/specs/updates.md U12, U13: it runs as the user and asks for the administrator's password itself,
// through pkexec and the polkit action org.grassfield.packages.set-channel), for /usr/lib/grassfield/grassfield-report (About >
// Create Diagnostic Report…, ADR-0053: read-only commands, one private file in the user's Downloads folder) no argument at all.
bool isAllowedAction(const QStringList &argv);

// An allowed action that may wait for a password (omarchy-language: Omarchy's own pkexec prompt; grassfield-channel-set: the
// polkit dialog of its helper). Backend::act runs one per tag at a time (busjobs.h InFlight), as busAct does for the polkit
// actions of ADR-0030 (privilegedAction).
bool asksForPassword(const QStringList &argv);

// How long an allowed action may run: `requested`, or 130 s for an action that asks for a password (asksForPassword), which may
// wait for its prompt as long as a polkit call of ADR-0030 waits for the user; at least 90 s for the diagnostic report.
int actionTimeoutMs(const QStringList &argv, int requested);

// About > Create Diagnostic Report… shows the report in Files (ADR-0053; Backend::launch, in the session's own language):
// exactly `/usr/bin/grassfield-files -- <folder>` with <folder> a clean absolute path (QDir::cleanPath leaves it unchanged: no
// "..", no "//", no trailing "/"), at most 4096 characters, without control or format characters, that is `home` or lies
// inside it. Files opens a folder there (a file would open its folder); nothing else is started.
bool isRevealInFiles(const QStringList &argv, const QString &home);

// A program Settings starts and leaves running (Backend::launch: detached, never stopped by a timeout or by Settings closing):
//   /usr/lib/grassfield/grassfield-update-run                            Software Update > Update Now (U24, owner decision
//                                                                       SU-M1): the user's runner of the update without a
//                                                                       terminal, which asks for the password through pkexec
//   omarchy-launch-floating-terminal-with-presentation omarchy-update   Software Update > Update in Terminal… (U11, U28): Omarchy's
//                                                                       update in its floating terminal, where Omarchy asks first
//   omarchy-launch-floating-terminal-with-presentation omarchy-migrate  Software Update > Finish in Terminal… (U28): Omarchy's
//                                                                       migrations a run could not finish
//   /usr/lib/grassfield/grassfield-session-end logout|restart            Software Update > Log Out…, Restart… (U14), after the
//                                                                       pane's own confirmation: the path of the Grassfield menu
//   omarchy-launch-floating-terminal-with-presentation <command>        ADR-0045 OC-0.4 and OC-0.7: the setups no system service
//                                                                       offers, behind the pane's sheet that says why a terminal
//                                                                       opens; <command> is exactly one of
//                                                                       omarchy-setup-security-fingerprint, omarchy-remove-security-
//                                                                       fingerprint, omarchy-setup-security-fido2, omarchy-remove-
//                                                                       security-fido2, omarchy-setup-security-sshd, omarchy-drive-
//                                                                       password, omarchy-hibernation-setup, omarchy-hibernation-
//                                                                       remove, omarchy-voxtype-install, omarchy-voxtype-remove
//                                                                       (4.0.6) or omarchy-install-dictation-voxtype, omarchy-
//                                                                       remove-dictation-voxtype (4.5)
//   omarchy-voxtype-model                                               Keyboard > Dictation > Language Model… (it opens Omarchy's
//                                                                       floating terminal itself)
// Exactly these argument vectors, nothing else.
bool isLaunch(const QStringList &argv);

// The one file Login Items may write or remove (Backend::writeAutostart, removeAutostart): <autostartDir>/<plain name>.desktop
// that is not a symbolic link (a write would go through the link to the file it names: a dotfile manager's file, or one outside
// .dev; removing it would break that setup), and in a dev session only when the folder's real location lies under
// <devRoot>/.dev (the isolated XDG_CONFIG_HOME), never the owner's ~/.config/autostart.
bool isAutostartWrite(const QString &path, const QString &autostartDir, const QString &devRoot, bool dev);

// An Icon= that is an absolute path (Login Items, image://icon): a clean path to a regular file (stat follows a link: never a
// FIFO, a device or a directory, which would stall the GUI thread), at most 1 MiB, named as a raster picture (PNG, XPM, JPEG).
// The name alone does not make it one: iconprovider.h decodes it only in the format its extension names, so an SVG (whose
// references QtSvg follows) named .png is refused there. Anything else shows the page's own tile.
bool isIconFile(const QString &path);

// The XDG Base Directory rule (Login Items, the user's services, the applications): a variable that is unset, empty or not an
// absolute path counts as not set (an empty XDG_CONFIG_HOME must not make ~/.config/autostart "/autostart", or the user's units
// "/systemd/user"). xdgHome: one folder, `value` when absolute, else `fallback`. xdgDirs: the absolute entries of a ':' list,
// else those of `fallback`.
QString xdgHome(const QString &value, const QString &fallback);
QStringList xdgDirs(const QString &value, const QString &fallback);

// Storage and About read the volumes on the GUI thread, so only local ones (integrator review of PR #6): the statfs of a
// network or FUSE mount blocks while its server or daemon does not answer, and the window with it.
// One line of /proc/self/mounts (reading that file stats nothing), its octal escapes (\040 for a space) decoded.
struct Mount {
    QString device;
    QString mountPoint;
    QString type;
};
QList<Mount> parseMounts(const QByteArray &text);
// A volume that may be stat'ed: a local block device's file system (or ZFS, whose "device" is its dataset), never a network
// file system (nfs, cifs, ceph, 9p: their device is not under /dev), never FUSE (fuse, fuseblk, fuse.sshfs...), never a
// virtual one (tmpfs, overlay, squashfs...).
bool isLocalVolume(const QString &device, const QString &type);
// The mount point that holds `path` (the longest one that is `path` or one of its parents), "" when none does: which volume
// holds the home, without a statfs of the home.
QString mountPointOf(const QList<Mount> &mounts, const QString &path);

// A NetworkManager connection UUID.
bool isUuid(const QString &s);

// Privacy & Security (the portal permission store, ADR-0030 amendment): an application id as the store keys a grant (a
// Flatpak id such as org.example.App, snap.<name>, or a host application's desktop id), never "" (unsandboxed applications
// without an id share that key) and never a path; and a saved screen-sharing or remote-desktop selection's restore token, as
// the portal makes and accepts them ([A-Za-z0-9_], at most 128 here, or a legacy UUID).
bool isPortalAppId(const QString &s);
bool isPortalToken(const QString &s);

} // namespace grassfield::settings
