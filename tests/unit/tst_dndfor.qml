import QtQuick
import QtTest
import "../../shell/notifications/DndFor.js" as DndFor

// Do Not Disturb for a while (docs/specs/command-palette.md B7): the deadline, the check, and the file that lets a shell restart
// keep it. The durations are the notification.dnd* tokens (the tests pass the token values).
TestCase {
    name: "DndFor"

    readonly property real hourMs: 3600000
    readonly property int tomorrowHour: 8
    readonly property real checkMs: 60000

    function dl(kind, now) {
        return DndFor.deadline(kind, now, hourMs, tomorrowHour);
    }

    function test_deadlines() {
        const now = new Date(2026, 10, 23, 22, 30, 0).getTime();
        compare(dl("hour", now), now + hourMs);
        compare(dl("tomorrow", now), new Date(2026, 10, 24, 8, 0, 0).getTime());
        // The next 08:00: this morning when it is still ahead (00:05 and 07:00), else tomorrow's (exactly 08:00 too).
        compare(dl("tomorrow", new Date(2026, 10, 24, 0, 5, 0).getTime()), new Date(2026, 10, 24, 8, 0, 0).getTime());
        compare(dl("tomorrow", new Date(2026, 10, 24, 7, 0, 0).getTime()), new Date(2026, 10, 24, 8, 0, 0).getTime());
        compare(dl("tomorrow", new Date(2026, 10, 24, 8, 0, 0).getTime()), new Date(2026, 10, 25, 8, 0, 0).getTime());
        compare(dl("never", now), 0);
    }

    function test_step() {
        const now = 1000000;
        const until = now + hourMs;
        compare(DndFor.step(0, true, now), "none");
        compare(DndFor.step(until, true, now), "wait");
        compare(DndFor.step(until, true, until), "expire");
        compare(DndFor.step(until, true, until + 5 * hourMs), "expire");   // a resume long after the deadline
        compare(DndFor.step(until, false, now), "clear");                  // turned off another way: forgotten
    }

    function test_nextCheck() {
        compare(DndFor.nextCheckMs(1000000 + 5000, 1000000, checkMs), 5000);
        compare(DndFor.nextCheckMs(1000000 + hourMs, 1000000, checkMs), checkMs);
        compare(DndFor.nextCheckMs(1000000 + 10, 1000000, checkMs), 1000);   // never a busy loop
        compare(DndFor.nextCheckMs(1000000 - 10, 1000000, checkMs), 1000);
    }

    function test_fileRoundTripAndDamage() {
        compare(DndFor.parse(DndFor.serialize(1234567890123), 1234567890123 - 1000), 1234567890123);
        compare(DndFor.parse(DndFor.serialize(0), 5), 0);
        for (const bad of ["", "nope", "[]", "null", '{"until":"x"}', '{"until":-5}', '{"until":1e999}', '{"until":null}', '{}'])
            compare(DndFor.parse(bad, 5), 0, bad);
    }

    // What Notifications does around a restart: the file is read back, then decided against the switch once the settings are in.
    function test_restartMidPeriodKeepsAndExpiresAtTheDeadline() {
        const start = new Date(2026, 10, 23, 22, 30, 0).getTime();
        const until = dl("hour", start);
        const back = DndFor.parse(DndFor.serialize(until), start + 20 * 60000);
        compare(back, until);
        compare(DndFor.step(back, true, start + 20 * 60000), "wait");   // restarted 20 minutes in: kept
        compare(DndFor.step(back, true, until - 1), "wait");
        compare(DndFor.step(back, true, until), "expire");              // ends at the deadline
    }

    function test_restartAfterTheDeadlineTurnsItOff() {
        const start = new Date(2026, 10, 23, 22, 30, 0).getTime();
        const back = DndFor.parse(DndFor.serialize(dl("hour", start)), start + 3 * hourMs);
        compare(DndFor.step(back, true, start + 3 * hourMs), "expire");
    }

    function test_restartAfterItWasTurnedOffForgetsTheDeadline() {
        const start = new Date(2026, 10, 23, 22, 30, 0).getTime();
        const back = DndFor.parse(DndFor.serialize(dl("hour", start)), start + 60000);
        compare(DndFor.step(back, false, start + 60000), "clear");
    }

    // A damaged or hand-edited file never sets a far deadline: DND stays as the person set it.
    function test_farOrNonFiniteDeadlinesAreNoDeadline() {
        const now = 1000000000000;
        compare(DndFor.parse('{"until":1e300}', now), 0);
        compare(DndFor.parse('{"until":' + (now + 49 * hourMs) + '}', now), 0);
        compare(DndFor.parse('{"until":' + (now + 47 * hourMs) + '}', now), now + 47 * hourMs);
        compare(DndFor.parse('{"until":' + (now - hourMs) + '}', now), now - hourMs);   // past: still ends DND at start
    }
}
