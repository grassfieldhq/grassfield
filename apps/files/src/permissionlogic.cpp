#include "permissionlogic.h"

namespace PermissionLogic
{
namespace
{
// The shift of a class's three bits.
int shift(Who who)
{
    switch (who) {
    case Who::Owner:
        return 6;
    case Who::Group:
        return 3;
    case Who::Others:
        return 0;
    }
    return 0;
}

constexpr unsigned kRead = 4;
constexpr unsigned kWrite = 2;
constexpr unsigned kExec = 1;
} // namespace

Access accessOf(unsigned mode, Who who)
{
    const unsigned bits = (mode >> shift(who)) & 7u;
    const bool r = bits & kRead;
    const bool w = bits & kWrite;
    return r && w ? Access::ReadWrite : r ? Access::ReadOnly : w ? Access::WriteOnly : Access::NoAccess;
}

unsigned withAccess(unsigned mode, Who who, Access access, bool isDir)
{
    const int s = shift(who);
    const unsigned old = (mode >> s) & 7u;
    unsigned bits = 0;
    if (access == Access::ReadOnly || access == Access::ReadWrite)
        bits |= kRead;
    if (access == Access::WriteOnly || access == Access::ReadWrite)
        bits |= kWrite;
    if (isDir)
        bits |= access == Access::NoAccess ? 0u : kExec; // a folder one can read or write into is one can enter
    else
        bits |= old & kExec;
    return (mode & ~(7u << s)) | (bits << s);
}

QString recursiveOperators(Access owner, Access group, Access others)
{
    auto ops = [](QChar who, Access access) -> QString {
        switch (access) {
        case Access::ReadWrite:
            return QString(who) + QStringLiteral("+rwX");
        case Access::ReadOnly:
            return QString(who) + QStringLiteral("+rX,") + who + QStringLiteral("-w");
        case Access::WriteOnly:
            return QString(who) + QStringLiteral("+wX,") + who + QStringLiteral("-r");
        case Access::NoAccess:
            return QString(who) + QStringLiteral("-rwx");
        }
        return {};
    };
    return ops(QLatin1Char('u'), owner) + QLatin1Char(',') + ops(QLatin1Char('g'), group) + QLatin1Char(',') + ops(QLatin1Char('o'), others);
}

unsigned recursiveMode(unsigned mode, bool isDir, Access owner, Access group, Access others)
{
    const Access accesses[3] = {owner, group, others};
    for (int c = 0; c < 3; ++c) {
        const int s = shift(Who(c));
        const Access access = accesses[c];
        const bool add = access != Access::NoAccess;
        // `X`: a folder, or a file some class can execute as the mode stands now.
        const bool execute = add && (isDir || (mode & 0111u));
        unsigned plus = 0;
        unsigned minus = 0;
        switch (access) {
        case Access::ReadWrite:
            plus = kRead | kWrite;
            break;
        case Access::ReadOnly:
            plus = kRead;
            minus = kWrite;
            break;
        case Access::WriteOnly:
            plus = kWrite;
            minus = kRead;
            break;
        case Access::NoAccess:
            minus = kRead | kWrite | kExec;
            break;
        }
        if (execute)
            plus |= kExec;
        mode = (mode | (plus << s)) & ~(minus << s);
    }
    return mode;
}

QString modeText(unsigned mode)
{
    QString out(9, QLatin1Char('-'));
    const char *letters = "rwxrwxrwx";
    for (int i = 0; i < 9; ++i) {
        if (mode & (1u << (8 - i)))
            out[i] = QLatin1Char(letters[i]);
    }
    auto special = [&out](int index, bool on, char withExec, char withoutExec) {
        if (on)
            out[index] = QLatin1Char(out.at(index) == QLatin1Char('x') ? withExec : withoutExec);
    };
    special(2, mode & 04000, 's', 'S');
    special(5, mode & 02000, 's', 'S');
    special(8, mode & 01000, 't', 'T');
    return out;
}

} // namespace PermissionLogic
