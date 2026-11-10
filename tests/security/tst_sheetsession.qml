import QtQuick
import QtTest
import "../../shell/security" as Security

// ADR-0041 S3 (the opus review of S3, NIT M3): SheetSession, what the polkit and secret sheets know of the session, fails
// closed until the security process's host binds it: the session counts as locked and the displays as off (no sheet is
// mapped, given the keyboard or answerable by a device); the saver counts as not shown (true would only hold a request).
// Nothing in this test file sets it: the defaults of a fresh engine are read.
TestCase {
    name: "SheetSession"

    function test_failsClosedUntilBound() {
        compare(Security.SheetSession.locked, true, "locked until the host binds Lock.locked");
        compare(Security.SheetSession.displaysOff, true, "displays off until the host binds Idle.displayOff");
        compare(Security.SheetSession.saverShown, false);
        compare(Security.SheetSession.starting, false, "the held notice's words only (the delta review of S3, LOW)");
    }
}
