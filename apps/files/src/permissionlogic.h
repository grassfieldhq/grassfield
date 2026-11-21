#pragma once

#include <QString>

// Get Info's Sharing & Permissions (ADR-0028, docs/specs/files.md FP-60, FP-61): the Finder's privileges over Linux mode
// bits. Pure (FilesApp applies the changes, by descriptor, for "Apply to enclosed items" too);
// unit-tested in tests/unit/files/tst_permissionlogic.cpp.
namespace PermissionLogic
{

// The Finder's privilege pop-up.
enum class Access { NoAccess = 0, ReadOnly = 1, WriteOnly = 2, ReadWrite = 3 };
// The rows: the owner, the group, everyone else.
enum class Who { Owner = 0, Group = 1, Others = 2 };

// The privilege a mode gives `who` (its read and write bits; execute is not shown).
Access accessOf(unsigned mode, Who who);

// `mode` with `who` given `access`. A folder's Read means r-x (the Finder lists access to a folder, not its execute
// bit); a file keeps its execute bit as it is. The special bits (setuid, setgid, sticky) are kept and never added.
unsigned withAccess(unsigned mode, Who who, Access access, bool isDir);

// chmod's symbolic operators for "Apply to enclosed items" (probe 12 of ADR-0028): per class, Read & Write `+rwX`, Read
// only `+rX,-w`, Write only `+wX,-r`, No Access `-rwx` ("u+rwX,g+rX,g-w,o-rwx"). `+` and `-` keep the special bits (`=`
// would clear setuid); `X` gives execute to folders and to files some class can already execute.
QString recursiveOperators(Access owner, Access group, Access others);

// What those operators make of one item's mode (chmod's rules: owner, then group, then others, each `X` judged on the mode
// as the classes before it left it). Files applies it itself, deepest items first, a folder's own mode last (audit F20:
// chmod -R took the owner's read or execute away from the top folder first, could no longer enter it, and nothing inside
// changed).
unsigned recursiveMode(unsigned mode, bool isDir, Access owner, Access group, Access others);

// The mode as "rwxr-x---", with s, S, t, T for the special bits (ls's spelling).
QString modeText(unsigned mode);

} // namespace PermissionLogic
