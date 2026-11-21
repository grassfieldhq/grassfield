// Get Info's Sharing & Permissions (PermissionLogic, ADR-0028): the Finder's privileges over mode bits.
#include "permissionlogic.h"

#include <gtest/gtest.h>

using namespace PermissionLogic;

TEST(Permissions, PrivilegesOfAMode)
{
    EXPECT_EQ(accessOf(0754, Who::Owner), Access::ReadWrite);
    EXPECT_EQ(accessOf(0754, Who::Group), Access::ReadOnly);
    EXPECT_EQ(accessOf(0754, Who::Others), Access::ReadOnly);
    EXPECT_EQ(accessOf(0720, Who::Group), Access::WriteOnly);
    EXPECT_EQ(accessOf(0700, Who::Others), Access::NoAccess);
}

TEST(Permissions, ChangingAPrivilege)
{
    // A file keeps its execute bit; nothing else of the class changes.
    EXPECT_EQ(withAccess(0755, Who::Group, Access::ReadWrite, false), 0775u);
    EXPECT_EQ(withAccess(0644, Who::Others, Access::NoAccess, false), 0640u);
    EXPECT_EQ(withAccess(0750, Who::Group, Access::NoAccess, false), 0710u) << "the file's group execute bit stays";
    // A folder: Read is r-x, No Access is ---.
    EXPECT_EQ(withAccess(0700, Who::Group, Access::ReadOnly, true), 0750u);
    EXPECT_EQ(withAccess(0755, Who::Others, Access::NoAccess, true), 0750u);
    EXPECT_EQ(withAccess(0700, Who::Others, Access::WriteOnly, true), 0703u);
    // Special bits are kept, never added.
    EXPECT_EQ(withAccess(04755, Who::Others, Access::NoAccess, false), 04751u);
    EXPECT_EQ(withAccess(02775, Who::Group, Access::ReadOnly, true), 02755u);
    EXPECT_EQ(withAccess(0644, Who::Owner, Access::ReadWrite, false) & 07000u, 0u);
}

TEST(Permissions, RecursiveOperatorsKeepSpecialBits)
{
    EXPECT_EQ(recursiveOperators(Access::ReadWrite, Access::ReadOnly, Access::NoAccess), QStringLiteral("u+rwX,g+rX,g-w,o-rwx"));
    EXPECT_EQ(recursiveOperators(Access::ReadOnly, Access::WriteOnly, Access::ReadWrite), QStringLiteral("u+rX,u-w,g+wX,g-r,o+rwX"));
    EXPECT_FALSE(recursiveOperators(Access::ReadWrite, Access::ReadWrite, Access::ReadWrite).contains(QLatin1Char('='))) << "= would clear setuid";
}

TEST(Permissions, ModeText)
{
    EXPECT_EQ(modeText(0754), QStringLiteral("rwxr-xr--"));
    EXPECT_EQ(modeText(04755), QStringLiteral("rwsr-xr-x"));
    EXPECT_EQ(modeText(02640), QStringLiteral("rw-r-S---"));
    EXPECT_EQ(modeText(01777), QStringLiteral("rwxrwxrwt"));
}

// Audit F20: Files applies "Apply to enclosed items" itself, with chmod's rules for the operators above.
TEST(Permissions, TheRecursiveModeIsWhatTheOperatorsMake)
{
    // u+rwX,g+rX,g-w,o-rwx on a plain file and on a folder.
    EXPECT_EQ(recursiveMode(0666, false, Access::ReadWrite, Access::ReadOnly, Access::NoAccess), 0640u);
    EXPECT_EQ(recursiveMode(0700, true, Access::ReadWrite, Access::ReadOnly, Access::NoAccess), 0750u);
    // X: execute for a file only when some class could already execute it, judged as the classes before left the mode.
    EXPECT_EQ(recursiveMode(0744, false, Access::ReadWrite, Access::ReadOnly, Access::ReadOnly), 0755u);
    EXPECT_EQ(recursiveMode(0100, false, Access::NoAccess, Access::ReadOnly, Access::NoAccess), 0040u) << "the owner's x went first";
    // The owner's No Access and Write Only (the cases chmod -R could not finish).
    EXPECT_EQ(recursiveMode(0755, true, Access::NoAccess, Access::ReadOnly, Access::ReadOnly), 0055u);
    EXPECT_EQ(recursiveMode(0755, true, Access::WriteOnly, Access::ReadOnly, Access::NoAccess), 0350u);
    EXPECT_EQ(recursiveMode(0644, false, Access::WriteOnly, Access::ReadOnly, Access::NoAccess), 0240u);
    // Special bits are kept, never added.
    EXPECT_EQ(recursiveMode(04755, false, Access::ReadWrite, Access::NoAccess, Access::NoAccess), 04700u);
    EXPECT_EQ(recursiveMode(02770, true, Access::ReadWrite, Access::ReadWrite, Access::ReadWrite), 02777u);
}
